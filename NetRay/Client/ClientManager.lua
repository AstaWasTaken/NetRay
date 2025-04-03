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
            -- Process critical messages immediately
            while self.MessageQueues[0]:Size() > 0 do
                local message = self.MessageQueues[0]:Dequeue()
                self:ProcessMessage(message)
            end
            
            -- Process high priority
            for _ = 1, math.min(5, self.MessageQueues[1]:Size()) do
                if self.MessageQueues[1]:Size() > 0 then
                    local message = self.MessageQueues[1]:Dequeue()
                    self:ProcessMessage(message)
                end
            end
            
            -- Process normal priority
            for _ = 1, math.min(3, self.MessageQueues[2]:Size()) do
                if self.MessageQueues[2]:Size() > 0 then
                    local message = self.MessageQueues[2]:Dequeue()
                    self:ProcessMessage(message)
                end
            end
            
            -- Process low and background priority less frequently
            if math.random() < 0.5 then
                if self.MessageQueues[3]:Size() > 0 then
                    local message = self.MessageQueues[3]:Dequeue()
                    self:ProcessMessage(message)
                end
            end
            
            if math.random() < 0.2 then
                if self.MessageQueues[4]:Size() > 0 then
                    local message = self.MessageQueues[4]:Dequeue()
                    self:ProcessMessage(message)
                end
            end
            
            task.wait(0.01) -- Small yield to prevent blocking
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
