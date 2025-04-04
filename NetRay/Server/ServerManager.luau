--!strict
--!optimize 2
--!native

--[[
    ServerManager.lua
    Manages server-side networking operations, event registration, and security
    Author: Asta (@TheYusufGamer)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Middleware = require(script.Parent.Parent.Shared.Middleware)
local Queue = require(script.Parent.Parent.Shared.Queue)
local Errors = require(script.Parent.Parent.Shared.Errors)
local CircuitBreaker = require(script.Parent.Parent.Shared.CircuitBreaker)
local Constants = require(script.Parent.Parent.Shared.Constants)
local SignalPlus = require(script.Parent.Parent.ThirdParty.SignalPlus)

-- Constants for processing limits per cycle
local PROCESS_LIMITS = {
	[0] = math.huge, -- Process all Critical
	[1] = 5,         -- High
	[2] = 3,         -- Normal
	[3] = 2,         -- Low
	[4] = 1          -- Background
}
local MIN_PROCESS_TIME = 0.005 -- Min time slice for lower priorities if higher are busy
local CYCLE_WAIT = 0.01


local ServerManager = {}
ServerManager.__index = ServerManager

function ServerManager.new(options)
	options = options or {}

	local self = setmetatable({}, ServerManager)

	-- Remote events container
	self.RemoteFolder = nil

	-- Registered events and handlers
	self.Events = {}
	self.RequestHandlers = {}

	-- Rate limiting data
	self.RateLimits = {}
	self.PlayerRates = {}

	-- Middleware system
	self.Middleware = Middleware.new()

	-- Message queues for prioritized event handling
	self.MessageQueues = {
		[0] = Queue.new(), -- Critical
		[1] = Queue.new(), -- High
		[2] = Queue.new(), -- Normal
		[3] = Queue.new(), -- Low
		[4] = Queue.new()  -- Background
	}

	-- Circuit breakers for events
	self.CircuitBreakers = {}

	-- Debug signals using SignalPlus
	self.Signals = {
		EventRegistered = SignalPlus(), -- Fires when a new event is registered
		EventFired = SignalPlus(),      -- Fires when an event is fired
		RequestSent = SignalPlus(),     -- Fires when a request is sent
		RequestReceived = SignalPlus(), -- Fires when a request is received
		RateLimitExceeded = SignalPlus(),-- Fires when rate limits are exceeded
		CircuitBroken = SignalPlus(),   -- Fires when a circuit breaker trips
		CircuitReset = SignalPlus(),    -- Fires when a circuit breaker resets
		PlayerJoined = SignalPlus(),    -- Fires when a player joins
		PlayerLeft = SignalPlus(),      -- Fires when a player leaves
		Error = SignalPlus(),            -- Fires when an error occurs
		ThrottleExceeded = SignalPlus() -- Fires when throttle is exceeded
	}

	-- Configure throttling
	self.IncomingRequests = {
		Limits = options.IncomingLimits or {}, -- Map of player UserIds to their limit counts
		DefaultLimit = options.DefaultIncomingLimit or 60, -- Default requests per minute
		Counts = {}, -- Map of player UserIds to their current request counts
		ResetTimers = {} -- Map of player UserIds to their reset timers
	}

	-- Configure timeouts
	self.PlayerTimeouts = {
		Timeouts = {}, -- Map of player UserIds to maps of event names to timeout timestamps
		DefaultDuration = options.DefaultTimeoutDuration or 1 -- Default timeout duration in seconds
	}

	-- Connect player events
	--	Players.PlayerAdded:Connect(function(player)
	--		self.Signals.PlayerJoined:Fire(player)
	--	end)

	Players.PlayerRemoving:Connect(function(player)
		self.Signals.PlayerLeft:Fire(player)
		if player and player.UserId then
			self.PlayerRates[player.UserId] = nil -- Clear rate limit data for leaving player
			self.IncomingRequests.Counts[player.UserId] = nil
			self.IncomingRequests.ResetTimers[player.UserId] = nil
			self.PlayerTimeouts.Timeouts[player.UserId] = nil
		end
	end)

	return self
end

function ServerManager:Initialize()
	-- Create or get the remote events folder
	self.RemoteFolder = ReplicatedStorage:FindFirstChild("NetRayRemotes")
	if not self.RemoteFolder then
		self.RemoteFolder = Instance.new("Folder")
		self.RemoteFolder.Name = "NetRayRemotes"
		self.RemoteFolder.Parent = ReplicatedStorage
	end

	-- Set up player rate tracking
	--	Players.PlayerAdded:Connect(function(player)
	--		self.PlayerRates[player.UserId] = {}
	--	end)

	Players.PlayerRemoving:Connect(function(player)
		self.PlayerRates[player.UserId] = nil
	end)

	-- Initialize queue processing
	self:StartQueueProcessing()

	return self
end

function ServerManager:StartQueueProcessing()
	task.spawn(function()
		while true do
			local cycleStartTime = tick()
			local processedAny = false

			-- Process Critical (all)
			while not self.MessageQueues[0]:IsEmpty() do
				local message = self.MessageQueues[0]:Dequeue()
				self:ProcessMessage(message)
				processedAny = true
			end

			-- Process High, Normal with limits
			for priority = 1, 2 do
				local limit = PROCESS_LIMITS[priority]
				local processedCount = 0
				while not self.MessageQueues[priority]:IsEmpty() and processedCount < limit do
					local message = self.MessageQueues[priority]:Dequeue()
					self:ProcessMessage(message)
					processedCount = processedCount + 1
					processedAny = true
				end
			end

			-- Guarantee *some* processing for Low/Background if time allows or nothing else ran
			local currentTime = tick()
			local timeAvailable = cycleStartTime + CYCLE_WAIT - currentTime
			local guaranteeLower = not processedAny or timeAvailable > MIN_PROCESS_TIME

			if guaranteeLower then
				for priority = 3, 4 do
					local limit = PROCESS_LIMITS[priority]
					local processedCount = 0
					-- Try to process at least one if available, up to the limit
					local processTarget = math.max(1, limit)
					while not self.MessageQueues[priority]:IsEmpty() and processedCount < processTarget do
						local message = self.MessageQueues[priority]:Dequeue()
						self:ProcessMessage(message)
						processedCount = processedCount + 1
						-- No need to set processedAny=true here, doesn't affect higher prio
					end
				end
			end

			task.wait(CYCLE_WAIT) -- Small yield
		end
	end)
end

function ServerManager:ProcessMessage(message)
	if not message then return end

	local fn = message.callback
	local args = message.args

	if typeof(fn) == "function" then
		local success, err = pcall(function()
			fn(unpack(args))
		end)

		if not success then
			warn("[NetRay] Error processing queued message: " .. tostring(err))
			self.Signals.Error:Fire(err)
		end
	end
end

function ServerManager:CreateRemoteEvent(eventName)
	-- Check if the remote event already exists
	local existingRemote = self.RemoteFolder:FindFirstChild(eventName)
	if existingRemote then
		return existingRemote
	end

	-- Create a new remote event
	local remoteEvent = Instance.new("RemoteEvent")
	remoteEvent.Name = eventName
	remoteEvent.Parent = self.RemoteFolder

	return remoteEvent
end

function ServerManager:CreateRemoteFunction(eventName)
	-- Check if the remote function already exists
	local existingRemote = self.RemoteFolder:FindFirstChild(eventName .. "_RF")
	if existingRemote then
		return existingRemote
	end

	-- Create a new remote function
	local remoteFunction = Instance.new("RemoteFunction")
	remoteFunction.Name = eventName .. "_RF"
	remoteFunction.Parent = self.RemoteFolder

	return remoteFunction
end

function ServerManager:RegisterEvent(eventName, options)
	if self.Events[eventName] then
		warn("[NetRay] Event already registered: " .. eventName)
		return self.Events[eventName]
	end

	local remoteEvent = self:CreateRemoteEvent(eventName)
	self.Events[eventName] = {
		Remote = remoteEvent,
		Options = options,
		Handlers = {}
	}

	-- Set up rate limits for this event if specified
	if options.rateLimit then
		self.RateLimits[eventName] = {
			MaxRequests = options.rateLimit.maxRequests or 10,
			TimeWindow = options.rateLimit.timeWindow or 1,
			BurstWindow = options.rateLimit.burstWindow or 0.1,
			BurstLimit = options.rateLimit.burstLimit or 3
		}
	end

	-- Set up circuit breaker if specified
	if options.circuitBreaker then
		self.CircuitBreakers[eventName] = CircuitBreaker.new({
			failureThreshold = options.circuitBreaker.failureThreshold or 5,
			resetTimeout = options.circuitBreaker.resetTimeout or 30,
			fallback = options.circuitBreaker.fallback
		})
	end

	self.Signals.EventRegistered:Fire(eventName)

	return self.Events[eventName]
end

function ServerManager:CheckRateLimit(player, eventName)
	local rateLimitConfig = self.RateLimits[eventName]
	if not rateLimitConfig then return true end -- No limits for this event

	local userId = player.UserId
	if not userId then return false end -- Should not happen, but safe check

	local playerLimits = self.PlayerRates[userId]
	if not playerLimits then
		playerLimits = {}
		self.PlayerRates[userId] = playerLimits
	end

	local eventLimits = playerLimits[eventName]
	local now = tick()

	-- Initialize if first time seeing this player+event
	if not eventLimits then
		eventLimits = {
			WindowStart = now,
			Count = 0,
			BurstStart = now,
			BurstCount = 0
		}
		playerLimits[eventName] = eventLimits
	end

	-- Check and reset windows
	if now >= eventLimits.WindowStart + rateLimitConfig.TimeWindow then
		eventLimits.WindowStart = now
		eventLimits.Count = 0
	end
	if now >= eventLimits.BurstStart + rateLimitConfig.BurstWindow then
		eventLimits.BurstStart = now
		eventLimits.BurstCount = 0
	end

	-- Check limits
	if eventLimits.Count >= rateLimitConfig.MaxRequests then
		self.Signals.RateLimitExceeded:Fire(player, eventName, "window")
		return false
	end
	if eventLimits.BurstCount >= rateLimitConfig.BurstLimit then
		self.Signals.RateLimitExceeded:Fire(player, eventName, "burst")
		return false
	end

	-- Increment counts
	eventLimits.Count += 1
	eventLimits.BurstCount += 1

	return true
end

function ServerManager:EnqueueMessage(priority, callback, ...)
	local args = {...}
	self.MessageQueues[priority]:Enqueue({
		callback = callback,
		args = args
	})
end

function ServerManager:InvokeMiddleware(eventName, player, data)
	return self.Middleware:Execute(eventName, player, data)
end

--[[
    Check if a player is on timeout for a specific event
    @param eventName: The name of the event to check
    @param userId: The player's UserId
    @return: true if the player is allowed, false if on timeout
]]
function ServerManager:CheckPlayerTimeout(eventName, userId)
	-- No timeout map for this player yet
	if not self.PlayerTimeouts.Timeouts[userId] then
		self.PlayerTimeouts.Timeouts[userId] = {}
		return true
	end

	-- No timeout for this event
	if not self.PlayerTimeouts.Timeouts[userId][eventName] then
		return true
	end

	-- Check if timeout has expired
	local now = tick()
	local timeoutUntil = self.PlayerTimeouts.Timeouts[userId][eventName]

	if now >= timeoutUntil then
		-- Timeout expired, remove it
		self.PlayerTimeouts.Timeouts[userId][eventName] = nil
		return true
	end

	-- Player is still on timeout
	return false
end

--[[
    Set a timeout for a player on a specific event
    @param eventName: The name of the event
    @param userId: The player's UserId
    @param duration: (Optional) Duration of the timeout in seconds
]]
function ServerManager:SetPlayerTimeout(eventName, userId, duration)
	duration = duration or self.PlayerTimeouts.DefaultDuration

	-- Initialize timeout map for this player if it doesn't exist
	if not self.PlayerTimeouts.Timeouts[userId] then
		self.PlayerTimeouts.Timeouts[userId] = {}
	end

	-- Set the timeout
	local now = tick()
	self.PlayerTimeouts.Timeouts[userId][eventName] = now + duration

	-- Signal that a timeout was set
	self.Signals.ThrottleExceeded:Fire(eventName, userId, duration)

	if self.DebugEnabled then
		print(("[NetRay] Set timeout for player %d on event %s for %.1f seconds"):format(
			userId, eventName, duration))
	end
end

--[[
    Check if the incoming request count for a player is within limits
    @param userId: The player's UserId
    @return: true if within limits, false if throttled
]]
function ServerManager:CheckIncomingThrottle(userId)
	local now = tick()

	-- Initialize count and reset timer for this player if they don't exist
	if not self.IncomingRequests.Counts[userId] then
		self.IncomingRequests.Counts[userId] = 0
		self.IncomingRequests.ResetTimers[userId] = now + 60 -- Reset after 1 minute
	end

	-- Check if we need to reset the counter
	if now >= self.IncomingRequests.ResetTimers[userId] then
		self.IncomingRequests.Counts[userId] = 0
		self.IncomingRequests.ResetTimers[userId] = now + 60 -- Reset after 1 minute
	end

	-- Increment the counter
	self.IncomingRequests.Counts[userId] = self.IncomingRequests.Counts[userId] + 1

	-- Get the player's limit
	local limit = self.IncomingRequests.Limits[userId] or self.IncomingRequests.DefaultLimit

	-- Check if the count exceeds the limit
	if self.IncomingRequests.Counts[userId] > limit then
		-- Signal that throttle was exceeded
		self.Signals.ThrottleExceeded:Fire("incoming_requests", userId)
		return false
	end

	return true
end

return ServerManager