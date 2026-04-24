--!strict
--!optimize 2

-------------------------------------------------------
-- Custom CPU particle simulator with physics
-------------------------------------------------------

local RunService = game:GetService("RunService")

-------------------------------------------------------

local Emitter = {}
Emitter.__index = Emitter

-------------------------------------------------------
-- Types
export type Attractor = {
	Position: Vector3,
	Strength: number, -- Positive values pull, negative values push
	MaxDistance: number, 
}

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
	
	StrictCollision : boolean, -- whether to use raycast or spherecast
	Attractors : {Attractor}?,
	callbacks : {[string] : (Particle) -> ()}
}

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
local function SafeCallback(particle : Particle, callbackName : string)
	if particle.callbacks == nil then return end
	if not particle.callbacks[callbackName] then return end
	particle.callbacks[callbackName](particle)
end

--------------------------
-- Sequence Evaluators

local function EvaluateNumberSequence(sequence: NumberSequence, timeRatio: number): number
	local keypoints = sequence.Keypoints
	if timeRatio <= 0 then return keypoints[1].Value end
	if timeRatio >= 1 then return keypoints[#keypoints].Value end

	for i = 1, #keypoints - 1 do
		local thisK = keypoints[i]
		local nextK = keypoints[i + 1]

		if timeRatio >= thisK.Time and timeRatio < nextK.Time then
			local alpha = (timeRatio - thisK.Time) / (nextK.Time - thisK.Time)
			-- Linear interpolation 
			return thisK.Value + (nextK.Value - thisK.Value) * alpha
		end
	end

	return keypoints[#keypoints].Value
end

local function EvaluateColorSequence(sequence: ColorSequence, timeRatio: number): Color3
	local keypoints = sequence.Keypoints
	if timeRatio <= 0 then return keypoints[1].Value end
	if timeRatio >= 1 then return keypoints[#keypoints].Value end

	for i = 1, #keypoints - 1 do
		local thisK = keypoints[i]
		local nextK = keypoints[i + 1]

		if timeRatio >= thisK.Time and timeRatio < nextK.Time then
			local alpha = (timeRatio - thisK.Time) / (nextK.Time - thisK.Time)
			-- Color3 has a built-in Lerp method
			return thisK.Value:Lerp(nextK.Value, alpha)
		end
	end

	return keypoints[#keypoints].Value
end

-------------------------------------------------------
-- Constructors

local function createParticle(params : EmitterConfig, folder : Folder) : Particle
	local part = params.Template:Clone()
	
	part.Anchored = true
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	
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

function Emitter.new(config: EmitterConfig) : Emitter
	local self = setmetatable({}, Emitter) :: Emitter
	
	-------- Fields

	self.Config = config
	self.Pool = table.create(config.PoolSize) :: {Particle}
	self._nextIndex = 1
	
	self.Folder = (function() : Folder
		local folder = workspace:FindFirstChild("_ParticleCache")
		if not folder then
			folder = Instance.new("Folder", workspace)
			folder.Name = "_ParticleCache"
		end
		return folder :: Folder
	end)() 
	
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.IgnoreWater = true
	self._rayParams = params
	
	-------- Particles
	
	for i = 1, config.PoolSize do
		self.Pool[i] = createParticle(config, self.Folder)
	end
	
	return self
end

-------------------------------------------------------
-- Methods

function Emitter:Emit(startPos : Vector3, startVel : Vector3)
	local self = self :: Emitter
	
	local particle = self.Pool[self._nextIndex] 
	
	self._nextIndex = (self._nextIndex % self.Config.PoolSize) + 1
	
	particle.Position = startPos
	particle.Velocity = startVel
	particle.TimePassed = 0
	particle.Active = true
	particle.Sleeping = false
	
	SafeCallback(particle, "SpawnCallback")
	
	particle.Instance.Position = startPos
end

function Emitter:Update(dt: number)
	local self = self :: Emitter
	
	local pool = self.Pool
	local poolSize = self.Config.PoolSize

	local gravityStep = self.Config.Gravity * dt

	local dragMult = math.clamp(1 - (self.Config.Drag * dt), 0, 1)
	
	for i = 1, poolSize do
		local particle = pool[i]
		if not particle.Active then continue end
		
		-------- Configuration

		particle.TimePassed += dt
		if particle.TimePassed >= particle.Lifetime then
			particle.Active = false
			-- positioning is less expensive than parenting to nil
			particle.Instance.Position = Vector3.new(0, 1e6, 0)
			continue
		end
		
		local timeRatio = particle.TimePassed / particle.Lifetime

		if self.Config.SizeSequence then
			local currentSize = EvaluateNumberSequence(self.Config.SizeSequence, timeRatio)

			-- Update size
			particle.Instance.Size = Vector3.new(currentSize, currentSize, currentSize)
			particle.Radius = currentSize / 2
		end

		if self.Config.ColorSequence then
			particle.Instance.Color = EvaluateColorSequence(self.Config.ColorSequence, timeRatio)
		end
		
		if particle.Sleeping then continue end

		
		if self.Config.Attractors then
			for _, attractor in self.Config.Attractors do
				local offset = attractor.Position - particle.Position
				local distance = offset.Magnitude

				if distance > 0 and distance <= attractor.MaxDistance then
					local direction = offset.Unit

					---- Inverse-square law
					-- math.max is used to prevent division by zero or black hole infinite velocity 
					-- if the particle gets perfectly centered on the attractor.
					local forceMagnitude = attractor.Strength / math.max(distance * distance, 1)

					particle.Velocity += direction * (forceMagnitude * dt)
				end
			end
		end

		-------- Movement
		
		particle.Velocity = (particle.Velocity + gravityStep) * dragMult
		
		local currentPos = particle.Position
		local step = particle.Velocity * dt
		local nextPos = currentPos + step
		
		-------- Reflection
				
		local hit = if self.Config.StrictCollision 
			then workspace:Spherecast(currentPos, particle.Radius, step, self._rayParams)
			else workspace:Raycast(currentPos, step, self._rayParams)

		if hit then
			local normal = hit.Normal

			local impactSpeed = -particle.Velocity:Dot(normal)

			if impactSpeed > 0 then
				if impactSpeed < (self.Config.SleepThreshold or 5) then
					-- Resting / Sliding
					particle.Velocity += normal * impactSpeed
					particle.Velocity *= self.Config.Friction

					if particle.Velocity.Magnitude < (self.Config.SleepThreshold or 5)/10 then
						particle.Velocity = Vector3.zero
						particle.Sleeping = true 
					end
				else
					-- Bouncing
					particle.Velocity += normal * (2 * impactSpeed)
					particle.Velocity *= particle.Bounciness
				end

				nextPos = hit.Position + (normal * (particle.Radius + 0.005))
			end
			
			SafeCallback(particle, "HitCallback")
	
		end
		
		-------- Appliement
		
		particle.Position = nextPos
		particle.Instance.Position = nextPos
	end
end

---------------------------
-- Controllers

function Emitter:Start()
	local self = self :: Emitter
	if self._connection then return end

	self._connection = RunService.Heartbeat:Connect(function(dt: number)
		self:Update(dt)
	end)
end

function Emitter:Stop()
	local self = self :: Emitter
	if self._connection then
		self._connection:Disconnect()
		self._connection = nil
	end
end

-------------------------------------------------------

return Emitter