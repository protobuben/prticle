--!strict
--!optimize 2


-- Discord - protobuben
-- Roblox - protobuben
-- Connected Discord-Github

-------------------------------------------------------
-- Custom CPU particle simulator with physics
--
-- Manages a fixed-size pool of BasePart instances that are
-- reused across their lifetime to avoid per-frame allocation.
-- Each particle is driven entirely on the CPU: gravity,
-- drag, attractor forces, collision response (bounce / slide /
-- sleep), and optional size/color sequences are all evaluated
-- manually inside a single Heartbeat loop.
--
-- Usage:
--   local emitter = Emitter.new(config)
--   emitter:Start()                          -- begins the Heartbeat loop
--   emitter:Emit(position, velocity)         -- spawns the next pooled particle
--   emitter:Stop()                           -- pauses the loop
-------------------------------------------------------

local RunService = game:GetService("RunService")

-------------------------------------------------------

local Emitter = {}
Emitter.__index = Emitter

-------------------------------------------------------
-- Types

-- Defines a point in space that exerts a force on nearby particles.
-- Strength > 0 pulls particles toward the attractor; Strength < 0 repels them.
-- MaxDistance caps the effective radius - particles beyond it are unaffected.
export type Attractor = {
	Position: Vector3,
	Strength: number,
	MaxDistance: number,
}

-- Represents a single particle in the pool.
-- Instance   : the BasePart rendered in the world
-- Position / Velocity : physics state tracked separately from CFrame so
--                       we avoid reading from the DataModel every frame
-- Bounciness : energy retention coefficient after a bounce (0 = dead stop, 1 = perfect)
-- Radius     : half-extent used for spherecast and for pushing the particle
--              off the hit surface after collision
-- TimePassed : accumulated simulation time since last Emit
-- Lifetime   : total duration before the particle is deactivated
-- Active     : false means the particle is idle in the pool and is skipped
-- Sleeping   : true once the particle comes to rest; skips force / movement
--              updates while still ticking the lifetime and rendering sequences
-- callbacks  : user-supplied hooks keyed by name (e.g. "SpawnCallback", "HitCallback")
export type Particle = {
	Instance : BasePart,

	Position : Vector3,
	Velocity : Vector3,

	Bounciness : number,
	Radius : number,

	TimePassed : number,
	Lifetime : number,
	Active : boolean,
	Sleeping : boolean,

	callbacks : {[string] : (Particle) -> ()}
}

-- Configuration passed to Emitter.new - shared across all particles in the pool.
-- Template       : the BasePart that is cloned to fill the pool
-- Bounciness     : default energy retention on bounce (can be overridden per-particle)
-- Radius         : default collision sphere radius
-- Friction       : velocity multiplier applied while a particle is sliding/resting
--                  (1 = frictionless, 0 = instant stop)
-- SleepThreshold : impact speed (studs/s) below which a particle transitions from
--                  bouncing to the slide/rest phase; defaults to 5 if nil
-- Lifetime       : seconds each particle lives before being returned to the pool
-- PoolSize       : number of particles preallocated; acts as a hard cap on
--                  simultaneous live particles
-- Gravity        : world-space acceleration vector applied every frame
--                  (typically Vector3.new(0, -workspace.Gravity, 0))
-- Drag           : linear drag coefficient; fraction of velocity removed per second
-- SizeSequence   : optional curve that drives the particle's uniform scale over
--                  its normalised lifetime [0, 1]
-- ColorSequence  : optional curve that drives the particle's Color3 over lifetime
-- StrictCollision: true -> spherecast (accurate, more expensive);
--                  false -> raycast (cheaper, tunnelling risk at high speeds)
-- Attractors     : optional list of force-field points evaluated every frame
-- callbacks      : default callback table applied to every particle on creation
export type EmitterConfig = {
	Template : BasePart,
	Bounciness : number,
	Radius : number,
	Friction : number,
	SleepThreshold : number?,
	Lifetime : number,
	PoolSize : number,
	Gravity : Vector3,
	Drag : number,

	SizeSequence : NumberSequence?,
	ColorSequence : ColorSequence?,

	StrictCollision : boolean,
	Attractors : {Attractor}?,
	callbacks : {[string] : (Particle) -> ()}
}

-- The Emitter object type, inferred from setmetatable so the type-checker
-- understands every field and method available on instances.
export type Emitter = typeof(setmetatable({} :: {
	Config: EmitterConfig,
	Pool: {Particle},
	Folder : Folder,
	_nextIndex : number,
	_rayParams : RaycastParams,
	_connection : RBXScriptConnection?,
}, Emitter))


-------------------------------------------------------
-- Helpers

-- Invokes a named callback on a particle if one is registered.
-- Guards against nil tables and missing keys so callers need no defensive checks.
local function SafeCallback(particle : Particle, callbackName : string)
	if particle.callbacks == nil then return end
	if not particle.callbacks[callbackName] then return end
	particle.callbacks[callbackName](particle)
end

--------------------------
-- Sequence Evaluators

-- Samples a NumberSequence at a normalised time in [0, 1].
-- Walks the keypoint list to find the surrounding pair and linearly interpolates
-- between them - the same math Roblox uses internally for ParticleEmitter curves.
-- Early-out guards handle the boundary cases (ratio <= 0 or >= 1) cheaply.
local function EvaluateNumberSequence(sequence: NumberSequence, timeRatio: number): number
	local keypoints = sequence.Keypoints
	if timeRatio <= 0 then return keypoints[1].Value end
	if timeRatio >= 1 then return keypoints[#keypoints].Value end

	for i = 1, #keypoints - 1 do
		local thisK = keypoints[i]
		local nextK = keypoints[i + 1]

		if timeRatio >= thisK.Time and timeRatio < nextK.Time then
			-- alpha is how far we are between thisK and nextK (0 -> 1)
			local alpha = (timeRatio - thisK.Time) / (nextK.Time - thisK.Time)
			return thisK.Value + (nextK.Value - thisK.Value) * alpha
		end
	end

	return keypoints[#keypoints].Value
end

-- Same algorithm as EvaluateNumberSequence but for Color3 values.
-- Color3:Lerp() handles perceptual interpolation in linear RGB space.
local function EvaluateColorSequence(sequence: ColorSequence, timeRatio: number): Color3
	local keypoints = sequence.Keypoints
	if timeRatio <= 0 then return keypoints[1].Value end
	if timeRatio >= 1 then return keypoints[#keypoints].Value end

	for i = 1, #keypoints - 1 do
		local thisK = keypoints[i]
		local nextK = keypoints[i + 1]

		if timeRatio >= thisK.Time and timeRatio < nextK.Time then
			local alpha = (timeRatio - thisK.Time) / (nextK.Time - thisK.Time)
			return thisK.Value:Lerp(nextK.Value, alpha)
		end
	end

	return keypoints[#keypoints].Value
end

-------------------------------------------------------
-- Constructors

-- Allocates a single pooled particle: clones the template, configures it so it
-- has no physics or interaction overhead (Anchored, no collision/touch/query),
-- then parks it far above the map until it is activated by Emit.
local function createParticle(params : EmitterConfig, folder : Folder) : Particle
	local part = params.Template:Clone()

	-- Anchor and strip Roblox's built-in physics - we drive position ourselves.
	part.Anchored = true
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false

	-- Park the part out of view at an extreme Y so it is invisible but not destroyed.
	-- This choice was made over parenting to nil due to parenting itself is 
	-- A way more expensive operation than position set. On big call amounts its noticable.
	part.Position = Vector3.new(0, 1e6, 0)

	part.Parent = folder

	return {
		Instance = part,

		Position = Vector3.zero,
		Velocity = Vector3.zero,

		Bounciness = params.Bounciness,
		Radius = params.Radius,

		TimePassed = 0,
		Lifetime = params.Lifetime,
		Active = false,
		Sleeping = false,

		callbacks = params.callbacks
	}
end

-- Creates the Emitter, preallocates the full particle pool, and sets up
-- a shared RaycastParams that excludes the pooled parts folder from collision
-- queries (avoids particles colliding with each other).
function Emitter.new(config: EmitterConfig) : Emitter
	local self = setmetatable({}, Emitter) :: Emitter

	-------- Fields

	self.Config = config
	self.Pool = table.create(config.PoolSize) :: {Particle}
	-- Round-robin index: always points to the next particle to be recycled.
	self._nextIndex = 1

	-- All particle instances live under a single workspace folder so they stay
	-- organised and the folder can easily be added to raycast exclusion lists.
	self.Folder = (function() : Folder
		local folder = workspace:FindFirstChild("_ParticleCache")
		if not folder then
			folder = Instance.new("Folder", workspace)
			folder.Name = "_ParticleCache"
		end
		return folder :: Folder
	end)()

	-- Shared RaycastParams used by every collision query in Update.
	-- IgnoreWater prevents water volumes from interfering with physics.
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.IgnoreWater = true
	self._rayParams = params

	-------- Particles

	-- Fill the pool up-front so no allocations happen during gameplay.
	for i = 1, config.PoolSize do
		self.Pool[i] = createParticle(config, self.Folder)
	end

	return self
end

-------------------------------------------------------
-- Methods

-- Activates the next particle in the pool using a round-robin strategy.
-- If all particles are currently active the oldest one (at _nextIndex) is
-- silently overwritten - this is intentional; no allocation or error is raised.
function Emitter:Emit(startPos : Vector3, startVel : Vector3)
	local self = self :: Emitter

	local particle = self.Pool[self._nextIndex]

	-- Advance the cursor, wrapping back to 1 after reaching PoolSize.
	self._nextIndex = (self._nextIndex % self.Config.PoolSize) + 1

	-- Reset physics and lifetime state before re-use.
	particle.Position = startPos
	particle.Velocity = startVel
	particle.TimePassed = 0
	particle.Active = true
	particle.Sleeping = false

	SafeCallback(particle, "SpawnCallback")

	-- Immediately place the instance at the spawn position so there is no
	-- one-frame flash at its previous location.
	particle.Instance.Position = startPos
end

-- Core simulation step - called once per Heartbeat with the frame delta time.
-- Iterates every slot in the pool; inactive particles are skipped early.
-- For each active particle the order is:
--   1. Lifetime expiry check
--   2. Visual sequence evaluation (size, color)
--   3. Sleep check (skips force/movement if resting)
--   4. Attractor forces
--   5. Gravity + drag integration
--   6. Collision detection and response (bounce / slide / sleep)
--   7. Position commit
function Emitter:Update(dt: number)
	local self = self :: Emitter

	local pool = self.Pool
	local poolSize = self.Config.PoolSize

	-- Pre-compute the per-frame gravity contribution and drag multiplier once
	-- rather than inside the loop to avoid redundant arithmetic each iteration.
	local gravityStep = self.Config.Gravity * dt

	-- Drag is modelled as an exponential decay approximated by clamping the
	-- per-frame multiplier to [0, 1] so it can never accelerate the particle.
	local dragMult = math.clamp(1 - (self.Config.Drag * dt), 0, 1)

	for i = 1, poolSize do
		local particle = pool[i]
		if not particle.Active then continue end

		-------- Lifetime

		particle.TimePassed += dt
		if particle.TimePassed >= particle.Lifetime then
			-- Deactivate by parking so the pool slot is
			-- immediately available for the next Emit call.
			particle.Active = false
			particle.Instance.Position = Vector3.new(0, 1e6, 0)
			continue
		end

		-- timeRatio is 0 at birth and 1 at death; used to sample both sequences.
		local timeRatio = particle.TimePassed / particle.Lifetime

		-------- Visual sequences

		if self.Config.SizeSequence then
			local currentSize = EvaluateNumberSequence(self.Config.SizeSequence, timeRatio)

			-- Uniform scale: all three axes are set to the same value so the
			-- particle remains spherical regardless of the template's shape.
			particle.Instance.Size = Vector3.new(currentSize, currentSize, currentSize)
			-- Keep the physics radius in sync so collision geometry matches visuals.
			particle.Radius = currentSize / 2
		end

		if self.Config.ColorSequence then
			particle.Instance.Color = EvaluateColorSequence(self.Config.ColorSequence, timeRatio)
		end

		-- Sleeping particles still tick their lifetime and run visual sequences
		-- above, but skip all force and movement calculations below.
		if particle.Sleeping then continue end

		-------- Attractor forces

		if self.Config.Attractors then
			for _, attractor in self.Config.Attractors do
				local offset = attractor.Position - particle.Position
				local distance = offset.Magnitude

				if distance > 0 and distance <= attractor.MaxDistance then
					local direction = offset.Unit

					-- Inverse-square law: force falls off with the square of distance,
					-- mimicking gravitational or magnetic field behaviour.
					-- math.max prevents division by zero (or a runaway spike) if the
					-- particle lands exactly on the attractor point.
					local forceMagnitude = attractor.Strength / math.max(distance * distance, 1)

					particle.Velocity += direction * (forceMagnitude * dt)
				end
			end
		end

		-------- Movement (symplectic Euler integration)
		-- Apply gravity then drag to velocity, then derive the displacement step.
		-- Drag is applied after gravity so a terminal velocity naturally emerges
		-- where gravity gain equals the drag loss per frame.
		particle.Velocity = (particle.Velocity + gravityStep) * dragMult

		local currentPos = particle.Position
		local step = particle.Velocity * dt  -- world-space displacement this frame
		local nextPos = currentPos + step

		-------- Collision detection

		-- StrictCollision uses Spherecast to account for the particle's radius,
		-- preventing small fast-moving particles from tunnelling through thin geometry.
		-- Raycast is cheaper but only traces the centre-line of the particle.
		local hit = if self.Config.StrictCollision
			then workspace:Spherecast(currentPos, particle.Radius, step, self._rayParams)
			else workspace:Raycast(currentPos, step, self._rayParams)

		if hit then
			local normal = hit.Normal

			-- Project the current velocity onto the surface normal to get the
			-- component of velocity that is heading into the surface.
			-- Negated because the normal points away from the surface.
			local impactSpeed = -particle.Velocity:Dot(normal)

			-- impactSpeed > 0 means we are genuinely hitting the surface rather
			-- than moving parallel or away from it (can happen on grazing hits).
			if impactSpeed > 0 then
				if impactSpeed < (self.Config.SleepThreshold or 5) then
					-------- Resting / Sliding
					-- Cancel the velocity component into the surface to prevent sinking,
					-- then apply friction to bleed off the remaining tangential velocity.
					particle.Velocity += normal * impactSpeed
					particle.Velocity *= self.Config.Friction

					-- Once the total speed drops below one tenth of the sleep threshold
					-- the particle is effectively stationary; mark it as sleeping so it
					-- stops being processed by the physics loop.
					if particle.Velocity.Magnitude < (self.Config.SleepThreshold or 5)/10 then
						particle.Velocity = Vector3.zero
						particle.Sleeping = true
					end
				else
					-------- Bouncing
					-- Reflect the velocity across the surface normal (law of reflection)
					-- then scale by Bounciness to model energy loss on impact.
					-- The reflection formula is: V' = V + 2 * impactSpeed * N
					particle.Velocity += normal * (2 * impactSpeed)
					particle.Velocity *= particle.Bounciness
				end

				-- Push the resolved position to the hit surface offset by the particle's
				-- radius plus a small epsilon (0.005) to prevent the next frame's cast
				-- from starting exactly on the surface and producing a false hit.
				nextPos = hit.Position + (normal * (particle.Radius + 0.005))
			end

			SafeCallback(particle, "HitCallback")

		end

		-------- Position commit
		-- Write the final position back to both the Lua state and the DataModel.
		-- The Lua-side Position is the authoritative physics state; the Instance
		-- position is purely for rendering.
		particle.Position = nextPos
		particle.Instance.Position = nextPos
	end
end

---------------------------
-- Controllers

-- Begins the per-frame simulation loop. Calling Start a second time while
-- already running is a no-op - the existing connection is reused.
function Emitter:Start()
	local self = self :: Emitter
	if self._connection then return end

	self._connection = RunService.Heartbeat:Connect(function(dt: number)
		self:Update(dt)
	end)
end

-- Pauses the simulation by disconnecting the Heartbeat listener.
-- Existing particle state is preserved; Start can resume the loop later.
function Emitter:Stop()
	local self = self :: Emitter
	if self._connection then
		self._connection:Disconnect()
		self._connection = nil
	end
end

-------------------------------------------------------

return Emitter