--!optimize 2

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

-- Type Imports 
type Middleware = Middleware.Middleware 
type Queue<T> = Queue.Queue<T> 
type CircuitBreaker = CircuitBreaker.CircuitBreaker 
type SignalPlus = SignalPlus.SignalPlus 

type Player = Players.Player

-- Define helper types for configuration and state
type RateLimitConfigOptions = {
	maxRequests: number?,
	timeWindow: number?,
	burstWindow: number?,
	burstLimit: number?
}

type CircuitBreakerConfigOptions = {
	failureThreshold: number?,
	resetTimeout: number?,
	fallback: ((...any) -> (...any))?
}

-- This type represents the options table passed when registering an event
export type ServerEventOptions = {
	rateLimit: RateLimitConfigOptions?,
	circuitBreaker: CircuitBreakerConfigOptions?,
	priority: number?, -- Expected based on queue usage
	typeDefinition: any?, -- Expected based on NetRayEvent type
	[string]: any -- Allow other potential options
}

-- This type represents the actual configuration stored after processing options
type RateLimitConfig = {
	MaxRequests: number,
	TimeWindow: number,
	BurstWindow: number,
	BurstLimit: number
}

-- Type for state stored per player per event for rate limiting
type PlayerEventRateData = {
	WindowStart: number,
	Count: number,
	BurstStart: number,
	BurstCount: number
}

-- Type for the message stored in the queue
type QueuedMessage = {
	callback: (...any) -> (),
	args: {any}
}

-- Type for the options passed to ServerManager.new
type ServerManagerOptions = {
	IncomingLimits: {[number]: number}?, -- UserId -> Limit
	DefaultIncomingLimit: number?,
	DefaultTimeoutDuration: number?
}

-- Type for the ServerManager class itself
export type ServerManager = {
	-- Properties
	RemoteFolder: Folder?, -- Optional until Initialize completes
	Events: {[string]: ServerRegisteredEventInfo}, -- Map eventName to info
	RequestHandlers: {[string]: RequestHandlerInfo}, -- Map requestName to info (define RequestHandlerInfo later)
	RateLimits: {[string]: RateLimitConfig}, -- Map eventName to config
	PlayerRates: {[number]: {[string]: PlayerEventRateData}}, -- Map UserId -> eventName -> data
	Middleware: Middleware,
	MessageQueues: {[number]: Queue<QueuedMessage>}, -- Map priority level to Queue
	CircuitBreakers: {[string]: CircuitBreaker}, -- Map eventName to CircuitBreaker instance
	Signals: ServerManagerSignals,
	IncomingRequests: {
		Limits: {[number]: number}?,
		DefaultLimit: number,
		Counts: {[number]: number},
		ResetTimers: {[number]: number}
	},
	PlayerTimeouts: {
		Timeouts: {[number]: {[string]: number}}, -- Map UserId -> eventName -> timeout timestamp
		DefaultDuration: number
	},
	DebugEnabled: boolean?, -- Added based on usage in SetPlayerTimeout

	-- Methods
	Initialize: (self: ServerManager) -> ServerManager,
	StartQueueProcessing: (self: ServerManager) -> (),
	ProcessMessage: (self: ServerManager, message: QueuedMessage?) -> (),
	CreateRemoteEvent: (self: ServerManager, eventName: string) -> RemoteEvent,
	CreateRemoteFunction: (self: ServerManager, eventName: string) -> RemoteFunction,
	RegisterEvent: (self: ServerManager, eventName: string, options: ServerEventOptions?) -> ServerRegisteredEventInfo,
	CheckRateLimit: (self: ServerManager, player: Player, eventName: string) -> boolean,
	EnqueueMessage: (self: ServerManager, priority: number, callback: (...any) -> (), ...any) -> (),
	InvokeMiddleware: (self: ServerManager, eventName: string, player: Player, data: any) -> (boolean, any?), -- Returns continueProcessing, potentially modifiedData
	CheckPlayerTimeout: (self: ServerManager, eventName: string, userId: number) -> boolean,
	SetPlayerTimeout: (self: ServerManager, eventName: string, userId: number, duration: number?) -> (),
	CheckIncomingThrottle: (self: ServerManager, userId: number) -> boolean,

	-- Constructor (defined separately for clarity)
	new: (options: ServerManagerOptions?) -> ServerManager
}

-- Internal type for storing registered event info
type ServerRegisteredEventInfo = {
	Remote: RemoteEvent,
	Options: ServerEventOptions, -- Store the original options
	Handlers: {[any]: any} -- Placeholder; actual type depends on ServerEvent implementation
}

-- Placeholder for Request Handler Info (needs definition based on RequestServer.lua)
type RequestHandlerInfo = {
	Remote: RemoteFunction,
	Handler: (player: Player, ...any) -> ...any,
	Options: any -- Define RequestOptions later
}


-- Type definition for the Signals table
type ServerManagerSignals = {
	EventRegistered: SignalPlus, -- (eventName: string)
	EventFired: SignalPlus,      -- (eventName: string, player: Player?, data: any) -- Player might be nil for FireAll
	RequestSent: SignalPlus,     -- (requestName: string, player: Player, data: any)
	RequestReceived: SignalPlus, -- (requestName: string, player: Player, data: any)
	RateLimitExceeded: SignalPlus, -- (player: Player, eventName: string, limitType: "window" | "burst")
	CircuitBroken: SignalPlus,   -- (eventName: string)
	CircuitReset: SignalPlus,    -- (eventName: string)
	PlayerJoined: SignalPlus,    -- (player: Player)
	PlayerLeft: SignalPlus,      -- (player: Player)
	Error: SignalPlus,            -- (err: any)
	ThrottleExceeded: SignalPlus -- (throttleType: string, userId: number, duration: number?)
}

-- Constants for processing limits per cycle (already defined, just for context)
local PROCESS_LIMITS = Constants.PROCESS_LIMITS or { -- Use Constants fallback otherwise
	[0] = math.huge, -- Process all Critical
	[1] = 5,         -- High
	[2] = 3,         -- Normal
	[3] = 2,         -- Low
	[4] = 1          -- Background
}
local MIN_PROCESS_TIME = Constants.MIN_PROCESS_TIME or 0.005 -- Min time slice for lower priorities if higher are busy
local CYCLE_WAIT = Constants.CYCLE_WAIT or 0.01


-- ============================================================================
-- ServerManager Implementation 
-- ============================================================================

local ServerManagerImpl = {}
ServerManagerImpl.__index = ServerManagerImpl

-- Constructor
function ServerManagerImpl.new(options: ServerManagerOptions?): ServerManager
	options = options or {}

	local self = setmetatable({}, ServerManagerImpl)

	-- Initialize properties with types where possible
	self.RemoteFolder = nil
	self.Events = {} :: {[string]: ServerRegisteredEventInfo}
	self.RequestHandlers = {} :: {[string]: RequestHandlerInfo} -- Cast needed until RequestHandlerInfo is fully defined
	self.RateLimits = {} :: {[string]: RateLimitConfig}
	self.PlayerRates = {} :: {[number]: {[string]: PlayerEventRateData}}
	self.Middleware = Middleware.new() :: Middleware -- Cast if Middleware.new() isn't typed
	self.MessageQueues = { -- Provide type hint for the table keys/values
		[0] = Queue.new(),
		[1] = Queue.new(),
		[2] = Queue.new(),
		[3] = Queue.new(),
		[4] = Queue.new()
	} :: {[number]: Queue<QueuedMessage>}
	self.CircuitBreakers = {} :: {[string]: CircuitBreaker}
	self.Signals = { -- Initialize signals
		EventRegistered = SignalPlus(),
		EventFired = SignalPlus(),
		RequestSent = SignalPlus(),
		RequestReceived = SignalPlus(),
		RateLimitExceeded = SignalPlus(),
		CircuitBroken = SignalPlus(),
		CircuitReset = SignalPlus(),
		PlayerJoined = SignalPlus(),
		PlayerLeft = SignalPlus(),
		Error = SignalPlus(),
		ThrottleExceeded = SignalPlus()
	} :: ServerManagerSignals
	self.IncomingRequests = {
		Limits = options.IncomingLimits,
		DefaultLimit = options.DefaultIncomingLimit or 60,
		Counts = {} :: {[number]: number},
		ResetTimers = {} :: {[number]: number}
	}
	self.PlayerTimeouts = {
		Timeouts = {} :: {[number]: {[string]: number}},
		DefaultDuration = options.DefaultTimeoutDuration or 1
	}
	self.DebugEnabled = false -- Initialize if needed

	-- Connect player events
	-- Consider adding PlayerAdded connection if needed for PlayerRates initialization
	Players.PlayerAdded:Connect(function(player: Player)
		self.PlayerRates[player.UserId] = {} -- Initialize player rate map on join
		self.Signals.PlayerJoined:Fire(player) -- Fire PlayerJoined signal
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		self.Signals.PlayerLeft:Fire(player)
		if player and player.UserId then
			local userId = player.UserId
			self.PlayerRates[userId] = nil -- Clear rate limit data
			self.IncomingRequests.Counts[userId] = nil -- Clear throttle count
			self.IncomingRequests.ResetTimers[userId] = nil -- Clear throttle timer
			self.PlayerTimeouts.Timeouts[userId] = nil -- Clear timeouts
		end
	end)

	return self :: ServerManager -- Cast the final object to the defined type
end

function ServerManagerImpl:Initialize(): ServerManager
	-- Create or get the remote events folder
	self.RemoteFolder = ReplicatedStorage:FindFirstChild("NetRayRemotes")
	if not self.RemoteFolder then
		self.RemoteFolder = Instance.new("Folder")
		self.RemoteFolder.Name = "NetRayRemotes"
		self.RemoteFolder.Parent = ReplicatedStorage
		assert(self.RemoteFolder:IsA("Folder"), "Failed to create or find RemoteFolder") -- Add assertion
	end

	-- Player rate tracking initialization moved to PlayerAdded connection in .new()

	-- Initialize queue processing
	self:StartQueueProcessing()

	return self
end

function ServerManagerImpl:StartQueueProcessing()
	task.spawn(function()
		while true do
			local cycleStartTime = tick()
			local processedAny = false

			-- Process Critical (all)
			local criticalQueue = self.MessageQueues[0]
			while not criticalQueue:IsEmpty() do
				local message = criticalQueue:Dequeue()
				self:ProcessMessage(message)
				processedAny = true
			end

			-- Process High, Normal with limits
			for priority = 1, 2 do
				local limit = PROCESS_LIMITS[priority]
				local processedCount = 0
				local currentQueue = self.MessageQueues[priority]
				while not currentQueue:IsEmpty() and processedCount < limit do
					local message = currentQueue:Dequeue()
					self:ProcessMessage(message)
					processedCount += 1
					processedAny = true
				end
			end

			-- Guarantee *some* processing for Low/Background
			local currentTime = tick()
			local timeAvailable = cycleStartTime + CYCLE_WAIT - currentTime
			local guaranteeLower = not processedAny or timeAvailable > MIN_PROCESS_TIME

			if guaranteeLower then
				for priority = 3, 4 do
					local limit = PROCESS_LIMITS[priority]
					local processedCount = 0
					local processTarget = math.max(1, limit) -- Ensure at least 1 attempt if queue not empty
					local currentQueue = self.MessageQueues[priority]
					while not currentQueue:IsEmpty() and processedCount < processTarget do
						local message = currentQueue:Dequeue()
						self:ProcessMessage(message)
						processedCount += 1
					end
				end
			end

			task.wait(CYCLE_WAIT)
		end
	end)
end

function ServerManagerImpl:ProcessMessage(message: QueuedMessage?)
	if not message then return end

	local fn = message.callback
	local args = message.args

	-- Check type defensively, although QueuedMessage type ensures it should be a function
	if typeof(fn) == "function" then
		local success, err = pcall(function()
			fn(unpack(args))
		end)

		if not success then
			warn("[NetRay ServerManager] Error processing queued message: " .. tostring(err))
			self.Signals.Error:Fire(err, debug.traceback()) -- Include traceback
		end
	else
		warn("[NetRay ServerManager] Invalid callback type in message queue:", typeof(fn))
		self.Signals.Error:Fire("Invalid callback type in message queue", message)
	end
end

function ServerManagerImpl:CreateRemoteEvent(eventName: string, options: ServerEventOptions?): RemoteEvent
	assert(self.RemoteFolder, "RemoteFolder not initialized")
	local existingRemote = self.RemoteFolder:FindFirstChild(eventName)
	if existingRemote and existingRemote:IsA("RemoteEvent") then
		return existingRemote
	elseif existingRemote then
		warn("[NetRay ServerManager] Instance named", eventName, "exists but is not a RemoteEvent. Destroying and recreating.")
		existingRemote:Destroy()
	end

	local remoteEvent 
	if options.UnreliableRemoteEvent == true then
		remoteEvent = Instance.new("UnreliableRemoteEvent")
	else
		remoteEvent = Instance.new("RemoteEvent")
	end
	remoteEvent.Name = eventName
	remoteEvent.Parent = self.RemoteFolder
	return remoteEvent
end

function ServerManagerImpl:CreateRemoteFunction(eventName: string): RemoteFunction
	assert(self.RemoteFolder, "RemoteFolder not initialized")
	local remoteName = eventName .. "_RF"
	local existingRemote = self.RemoteFolder:FindFirstChild(remoteName)
	if existingRemote and existingRemote:IsA("RemoteFunction") then
		return existingRemote
	elseif existingRemote then
		warn("[NetRay ServerManager] Instance named", remoteName, "exists but is not a RemoteFunction. Destroying and recreating.")
		existingRemote:Destroy()
	end

	local remoteFunction = Instance.new("RemoteFunction")
	remoteFunction.Name = remoteName
	remoteFunction.Parent = self.RemoteFolder
	return remoteFunction
end


function ServerManagerImpl:RegisterEvent(eventName: string, options: ServerEventOptions?): ServerRegisteredEventInfo
	options = options or {} -- Ensure options is a table
	if self.Events[eventName] then
		warn("[NetRay ServerManager] Event already registered: " .. eventName .. ". Returning existing registration.")
		return self.Events[eventName]
	end

	local remoteEvent = self:CreateRemoteEvent(eventName, options)
	local eventInfo: ServerRegisteredEventInfo = {
		Remote = remoteEvent,
		Options = options,
		Handlers = {} 
	}
	self.Events[eventName] = eventInfo

	-- Set up rate limits for this event if specified
	if options.rateLimit then
		local rl = options.rateLimit
		self.RateLimits[eventName] = {
			MaxRequests = rl.maxRequests or Constants.RATE_LIMIT.DEFAULT_MAX_REQUESTS,
			TimeWindow = rl.timeWindow or Constants.RATE_LIMIT.DEFAULT_TIME_WINDOW,
			BurstWindow = rl.burstWindow or Constants.RATE_LIMIT.DEFAULT_BURST_WINDOW,
			BurstLimit = rl.burstLimit or Constants.RATE_LIMIT.DEFAULT_BURST_LIMIT
		}
	end

	-- Set up circuit breaker if specified
	if options.circuitBreaker then
		local cbOpts = options.circuitBreaker
		self.CircuitBreakers[eventName] = CircuitBreaker.new({
			failureThreshold = cbOpts.failureThreshold or 5,
			resetTimeout = cbOpts.resetTimeout or 30,
			fallback = cbOpts.fallback
		}) :: CircuitBreaker -- Cast if CircuitBreaker.new isn't typed
	end

	self.Signals.EventRegistered:Fire(eventName)

	return eventInfo
end

function ServerManagerImpl:CheckRateLimit(player: Player, eventName: string): boolean
	local rateLimitConfig = self.RateLimits[eventName]
	if not rateLimitConfig then return true end

	local userId = player.UserId
	if not userId then
		warn("[NetRay ServerManager] CheckRateLimit called with invalid player:", player)
		return false
	end

	local playerLimits = self.PlayerRates[userId]
	if not playerLimits then
		playerLimits = {}
		self.PlayerRates[userId] = playerLimits
	end

	local eventLimits = playerLimits[eventName]
	local now = tick()

	if not eventLimits then
		eventLimits = { WindowStart = now, Count = 0, BurstStart = now, BurstCount = 0 }
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
	if eventLimits.BurstCount >= rateLimitConfig.BurstLimit then
		self.Signals.RateLimitExceeded:Fire(player, eventName, "burst")
		return false
	end
	if eventLimits.Count >= rateLimitConfig.MaxRequests then
		self.Signals.RateLimitExceeded:Fire(player, eventName, "window")
		return false
	end

	-- Increment counts
	eventLimits.Count += 1
	eventLimits.BurstCount += 1

	return true
end

function ServerManagerImpl:EnqueueMessage(priority: number, callback: (...any) -> (), ...)
	-- Validate priority
	priority = math.clamp(priority or Constants.PRIORITY.NORMAL or 2, 0, 4) -- Use Constants if available
	local queue = self.MessageQueues[priority]
	if not queue then
		warn("[NetRay ServerManager] Invalid priority level for EnqueueMessage:", priority)
		queue = self.MessageQueues[Constants.PRIORITY.NORMAL or 2] -- Fallback to normal
	end

	local args = {...}
	local message: QueuedMessage = {
		callback = callback,
		args = args
	}
	queue:Enqueue(message)
end

function ServerManagerImpl:InvokeMiddleware(eventName: string, player: Player, data: any): (boolean, any?)
	return self.Middleware:Execute(eventName, player, data)
end

function ServerManagerImpl:CheckPlayerTimeout(eventName: string, userId: number): boolean
	local playerTimeoutMap = self.PlayerTimeouts.Timeouts[userId]
	if not playerTimeoutMap then
		return true -- No timeouts recorded for this player
	end

	local timeoutUntil = playerTimeoutMap[eventName]
	if not timeoutUntil then
		return true -- No timeout for this specific event
	end

	if tick() >= timeoutUntil then
		playerTimeoutMap[eventName] = nil -- Timeout expired
		-- Clean up the playerTimeoutMap if it becomes empty
		 if next(playerTimeoutMap) == nil then
		  self.PlayerTimeouts.Timeouts[userId] = nil
		 end
		return true
	end

	return false -- Still on timeout
end

function ServerManagerImpl:SetPlayerTimeout(eventName: string, userId: number, duration: number?)
	duration = duration or self.PlayerTimeouts.DefaultDuration

	local playerTimeoutMap = self.PlayerTimeouts.Timeouts[userId]
	if not playerTimeoutMap then
		playerTimeoutMap = {}
		self.PlayerTimeouts.Timeouts[userId] = playerTimeoutMap
	end

	local timeoutUntil = tick() + duration
	playerTimeoutMap[eventName] = timeoutUntil

	self.Signals.ThrottleExceeded:Fire(eventName, userId, duration) -- Signal uses eventName as type here

	if self.DebugEnabled then -- Check for DebugEnabled flag
		print(("[NetRay ServerManager] Set timeout for player %d on event %s for %.1f seconds"):format(
			userId, eventName, duration))
	end
end

function ServerManagerImpl:CheckIncomingThrottle(userId: number): boolean
	local now = tick()
	local counts = self.IncomingRequests.Counts
	local timers = self.IncomingRequests.ResetTimers

	if not timers[userId] or now >= timers[userId] then
		counts[userId] = 0
		timers[userId] = now + 60 -- Reset window
	end

	counts[userId] = (counts[userId] or 0) + 1
	local limit = self.IncomingRequests.Limits and self.IncomingRequests.Limits[userId] or self.IncomingRequests.DefaultLimit

	if counts[userId] > limit then
		self.Signals.ThrottleExceeded:Fire("incoming_requests", userId) -- Type is "incoming_requests"
		return false
	end

	return true
end


return ServerManagerImpl