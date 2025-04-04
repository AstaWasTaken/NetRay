--!strict
--!optimize 2
--!native
--[[
    ClientManager.lua
    Manages client-side networking operations and event registration
    Author: Asta (@TheYusufGamer)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

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


local ClientManager = {}
ClientManager.__index = ClientManager

function ClientManager.new()
	local self = setmetatable({}, ClientManager)

	-- Remote events container
	self.RemoteFolder = nil

	-- Registered events and handlers
	self.Events = {}
	self.RequestHandlers = {}

	-- Middleware system
	self.Middleware = Middleware.new()

	-- Outgoing requests tracking for throttling
	self.OutgoingRequests = {
		Count = 0,
		LastReset = tick(),
		Limit = 120, -- Maximum of 120 requests per second by default
		Burst = {
			Count = 0,
			LastReset = tick(),
			Limit = 20  -- Maximum of 20 requests per 100ms
		}
	}

	-- Message queues for prioritized event handling
	self.MessageQueues = {
		[0] = Queue.new(), -- Critical
		[1] = Queue.new(), -- High
		[2] = Queue.new(), -- Normal
		[3] = Queue.new(), -- Low
		[4] = Queue.new()  -- Background
	}

	-- Circuit breakers for fault tolerance
	self.CircuitBreakers = {}

	-- Debug signals using SignalPlus
	self.Signals = {
		EventRegistered = SignalPlus(), -- Fires when a new event is registered
		EventFired = SignalPlus(),      -- Fires when an event is fired
		RequestSent = SignalPlus(),     -- Fires when a request is sent
		RequestReceived = SignalPlus(), -- Fires when a request is received
		ThrottleExceeded = SignalPlus(),-- Fires when throttling limits are exceeded
		CircuitBroken = SignalPlus(),   -- Fires when a circuit breaker trips
		CircuitReset = SignalPlus(),    -- Fires when a circuit breaker resets
		Error = SignalPlus()            -- Fires when an error occurs
	}

	return self
end

function ClientManager:Initialize()
	-- Get the remote events folder
	self.RemoteFolder = ReplicatedStorage:WaitForChild("NetRayRemotes", 10)
	if not self.RemoteFolder then
		warn("[NetRay] Could not find NetRayRemotes folder in ReplicatedStorage. Network functionality will be limited.")
		self.RemoteFolder = Instance.new("Folder")
		self.RemoteFolder.Name = "NetRayRemotes"
		self.RemoteFolder.Parent = ReplicatedStorage
	end

	-- Initialize queue processing
	self:StartQueueProcessing()

	-- Start request throttling reset
	task.spawn(function()
		while true do
			task.wait(1)
			self.OutgoingRequests.Count = 0
			self.OutgoingRequests.LastReset = tick()
		end
	end)

	-- Start burst throttling reset
	task.spawn(function()
		while true do
			task.wait(0.1) -- 100ms
			self.OutgoingRequests.Burst.Count = 0
			self.OutgoingRequests.Burst.LastReset = tick()
		end
	end)

	return self
end

function ClientManager:StartQueueProcessing()
	-- Process queues in priority order (critical first)
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

function ClientManager:ProcessMessage(message)
	if not message then return end

	local fn = message.callback
	local args = message.args

	if typeof(fn) == "function" then
		local success, err = pcall(function()
			fn(unpack(args))
		end)

		if not success then
			warn("[NetRay] Error processing queued message: " .. tostring(err))
		end
	end
end

function ClientManager:GetRemoteEvent(eventName)
	if not self.RemoteFolder then
		error("[NetRay] RemoteFolder not initialized")
		return nil
	end

	-- Wait for the remote event to exist
	local remoteEvent = self.RemoteFolder:WaitForChild(eventName, 10)
	if not remoteEvent then
		warn("[NetRay] Remote event not found: " .. eventName)
		return nil
	end

	return remoteEvent
end

function ClientManager:GetRemoteFunction(eventName)
	if not self.RemoteFolder then
		error("[NetRay] RemoteFolder not initialized")
		return nil
	end

	-- Wait for the remote function to exist
	local remoteFunction = self.RemoteFolder:WaitForChild(eventName .. "_RF", 10)
	if not remoteFunction then
		warn("[NetRay] Remote function not found: " .. eventName .. "_RF")
		return nil
	end

	return remoteFunction
end

function ClientManager:RegisterEvent(eventName, options)
	if self.Events[eventName] then
		return self.Events[eventName]
	end

	local remoteEvent = self:GetRemoteEvent(eventName)
	if not remoteEvent then
		warn("[NetRay] Failed to register event: " .. eventName)
		return nil
	end

	self.Events[eventName] = {
		Remote = remoteEvent,
		Options = options or {},
		Handlers = {}
	}

	-- Set up circuit breaker if specified
	if options and options.circuitBreaker then
		self.CircuitBreakers[eventName] = CircuitBreaker.new({
			failureThreshold = options.circuitBreaker.failureThreshold or 5,
			resetTimeout = options.circuitBreaker.resetTimeout or 30,
			fallback = options.circuitBreaker.fallback
		})
	end

	self.Signals.EventRegistered:Fire(eventName)

	return self.Events[eventName]
end

function ClientManager:CheckOutgoingThrottle()
	-- Reset counters if needed
	local currentTime = tick()
	if currentTime - self.OutgoingRequests.LastReset >= 1 then
		self.OutgoingRequests.Count = 0
		self.OutgoingRequests.LastReset = currentTime
	end

	if currentTime - self.OutgoingRequests.Burst.LastReset >= 0.1 then
		self.OutgoingRequests.Burst.Count = 0
		self.OutgoingRequests.Burst.LastReset = currentTime
	end

	-- Check throttling limits
	if self.OutgoingRequests.Count >= self.OutgoingRequests.Limit then
		self.Signals.ThrottleExceeded:Fire("global", self.OutgoingRequests.Count, self.OutgoingRequests.Limit)
		return false
	end

	if self.OutgoingRequests.Burst.Count >= self.OutgoingRequests.Burst.Limit then
		self.Signals.ThrottleExceeded:Fire("burst", self.OutgoingRequests.Burst.Count, self.OutgoingRequests.Burst.Limit)
		return false
	end

	-- Increment counters
	self.OutgoingRequests.Count += 1
	self.OutgoingRequests.Burst.Count += 1

	return true
end

function ClientManager:EnqueueMessage(priority, callback, ...)
	local args = {...}
	self.MessageQueues[priority]:Enqueue({
		callback = callback,
		args = args
	})
end

function ClientManager:InvokeMiddleware(eventName, data)
	return self.Middleware:Execute(eventName, nil, data)
end

return ClientManager