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
    Players.PlayerAdded:Connect(function(player)
        self.Signals.PlayerJoined:Fire(player)
    end)
    
    Players.PlayerRemoving:Connect(function(player)
        self.Signals.PlayerLeft:Fire(player)
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
    Players.PlayerAdded:Connect(function(player)
        self.PlayerRates[player.UserId] = {}
    end)
    
    Players.PlayerRemoving:Connect(function(player)
        self.PlayerRates[player.UserId] = nil
    end)
    
    -- Initialize queue processing
    self:StartQueueProcessing()
    
    return self
end

function ServerManager:StartQueueProcessing()
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
    if not self.RateLimits[eventName] then return true end
    if not player or not player.UserId then return false end
    
    local userId = player.UserId
    local limits = self.RateLimits[eventName]
    local playerRates = self.PlayerRates[userId]
    
    if not playerRates then
        self.PlayerRates[userId] = {}
        playerRates = self.PlayerRates[userId]
    end
    
    if not playerRates[eventName] then
        playerRates[eventName] = {
            Requests = {},
            BurstRequests = {}
        }
    end
    
    local now = tick()
    local eventRates = playerRates[eventName]
    
    -- Clean up old requests
    local i = 1
    while i <= #eventRates.Requests do
        if now - eventRates.Requests[i] > limits.TimeWindow then
            table.remove(eventRates.Requests, i)
        else
            i = i + 1
        end
    end
    
    i = 1
    while i <= #eventRates.BurstRequests do
        if now - eventRates.BurstRequests[i] > limits.BurstWindow then
            table.remove(eventRates.BurstRequests, i)
        else
            i = i + 1
        end
    end
    
    -- Check rate limits
    if #eventRates.Requests >= limits.MaxRequests then
        self.Signals.RateLimitExceeded:Fire(player, eventName)
        return false
    end
    
    if #eventRates.BurstRequests >= limits.BurstLimit then
        self.Signals.RateLimitExceeded:Fire(player, eventName)
        return false
    end
    
    -- Record this request
    table.insert(eventRates.Requests, now)
    table.insert(eventRates.BurstRequests, now)
    
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
