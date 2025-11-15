--!optimize 2

--[[
    ClientManager.lua
    Manages client-side networking operations and event registration
    Author: Asta (@TheYusufGamer)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Type Imports
local MiddlewareModule = require(script.Parent.Parent.Shared.Middleware)
local QueueModule = require(script.Parent.Parent.Shared.Queue)
local CircuitBreakerModule = require(script.Parent.Parent.Shared.CircuitBreaker)
local Constants = require(script.Parent.Parent.Shared.Constants) 
local SignalPlusModule = require(script.Parent.Parent.ThirdParty.SignalPlus)

-- Assume modules export types or you define them
type Middleware = MiddlewareModule.Middleware
type Queue<T> = QueueModule.Queue<T>
type CircuitBreaker = CircuitBreakerModule.CircuitBreaker
type SignalPlus = SignalPlusModule.SignalPlus

-- Type for the message stored in the queue (same as server)
type QueuedMessage = {
	callback: (...any) -> (),
	args: {any}
}

-- Type for ClientEvent options (might differ slightly from ServerEventOptions)
-- Primarily used internally when ClientEvent/RequestClient are created/retrieved.
export type ClientEventOptions = {
	-- Client generally doesn't define rate limits, but might have CB config
	circuitBreaker: {
		failureThreshold: number?,
		resetTimeout: number?,
		fallback: ((...any) -> (...any))?
	}?,
	priority: number?, -- For incoming message processing
	typeDefinition: any?, -- For incoming data validation
	[string]: any
}

-- Internal type for storing info about events the client is aware of
-- Populated potentially by ClientEvent/RequestClient initialization
type ClientRegisteredEventInfo = {
	Remote: RemoteEvent?, -- Optional initially until found
	Options: ClientEventOptions,
	Handlers: { (...any) -> () }, -- List of callbacks attached via ClientEvent:OnEvent
	Event: any? -- Placeholder for the actual ClientEvent instance associated
}

-- Internal type for storing info about requests the client can handle/send
type ClientRequestHandlerInfo = {
	Remote: RemoteFunction?, -- Optional initially until found
	Options: any, -- Define RequestClientOptions later
	Handler: ((...any) -> any)?, -- Callback attached via RequestClient:OnRequest
	Request: any? -- Placeholder for RequestClient instance
}

-- Type for the OutgoingRequests state
type OutgoingRequestState = {
	Count: number,
	LastReset: number,
	Limit: number,
	Burst: {
		Count: number,
		LastReset: number,
		Limit: number
	}
}

-- Type definition for the ClientManager Signals table
type ClientManagerSignals = {
	EventRegistered: SignalPlus, -- (eventName: string) - When GetEvent first finds/creates wrapper
	EventFired: SignalPlus,      -- (eventName: string, data: any) - When handler is invoked
	RequestSent: SignalPlus,     -- (requestName: string, data: any) - C->S request sent
	RequestReceived: SignalPlus, -- (requestName: string, data: any) - S->C request received
	ThrottleExceeded: SignalPlus,-- (limitType: "global" | "burst", count: number, limit: number)
	CircuitBroken: SignalPlus,   -- (eventName: string)
	CircuitReset: SignalPlus,    -- (eventName: string)
	Error: SignalPlus            -- (err: any, context: string?)
}

-- Type for the ClientManager class itself
export type ClientManager = {
	-- Properties
	RemoteFolder: Folder?, -- Optional until Initialize/WaitForChild completes
	Events: {[string]: ClientRegisteredEventInfo}, -- Map eventName to info
	RequestHandlers: {[string]: ClientRequestHandlerInfo}, -- Map requestName to info
	Middleware: Middleware,
	OutgoingRequests: OutgoingRequestState,
	MessageQueues: {[number]: Queue<QueuedMessage>}, -- Map priority level to Queue
	CircuitBreakers: {[string]: CircuitBreaker}, -- Map eventName/requestName to CircuitBreaker instance
	Signals: ClientManagerSignals,
	DebugEnabled: boolean?, -- Added based on potential usage

	-- Methods
	Initialize: (self: ClientManager) -> ClientManager,
	StartQueueProcessing: (self: ClientManager) -> (),
	ProcessMessage: (self: ClientManager, message: QueuedMessage?) -> (),
	GetRemoteEvent: (self: ClientManager, eventName: string) -> RemoteEvent?, -- Returns optional RemoteEvent
	GetRemoteFunction: (self: ClientManager, eventName: string) -> RemoteFunction?, -- Returns optional RemoteFunction
	_InternalRegisterEvent: (self: ClientManager, eventName: string, options: ClientEventOptions?) -> ClientRegisteredEventInfo?,
	CheckOutgoingThrottle: (self: ClientManager) -> boolean,
	EnqueueMessage: (self: ClientManager, priority: number, callback: (...any) -> (), ...any) -> (),
	InvokeMiddleware: (self: ClientManager, eventName: string, data: any) -> (boolean, any?), -- Returns continueProcessing, potentially modifiedData

	-- Constructor
	new: () -> ClientManager
}

-- Constants (use values from Constants module if available)
local PROCESS_LIMITS = Constants.PROCESS_LIMITS or {
	[0] = math.huge, [1] = 5, [2] = 3, [3] = 2, [4] = 1
}
local MIN_PROCESS_TIME = Constants.MIN_PROCESS_TIME or 0.005
local CYCLE_WAIT = Constants.CYCLE_WAIT or 0.01

-- Define the ClientManager module table
local ClientManagerImpl = {}
ClientManagerImpl.__index = ClientManagerImpl

-- Constructor
function ClientManagerImpl.new(): ClientManager
	local self = setmetatable({}, ClientManagerImpl)

	self.RemoteFolder = nil
	self.Events = {} :: {[string]: ClientRegisteredEventInfo}
	self.RequestHandlers = {} :: {[string]: ClientRequestHandlerInfo} -- Type assertion needed
	self.Middleware = MiddlewareModule.new() :: Middleware -- Cast if .new isn't typed
	self.OutgoingRequests = {
		Count = 0,
		LastReset = tick(),
		Limit = Constants.RATE_LIMIT.DEFAULT_MAX_REQUESTS or 120, -- Use Constants if defined
		Burst = {
			Count = 0,
			LastReset = tick(),
			Limit = Constants.RATE_LIMIT.DEFAULT_BURST_LIMIT or 20 -- Use Constants if defined
		}
	} :: OutgoingRequestState
	self.MessageQueues = { -- Type hint for the table keys/values
		[0] = QueueModule.new(), 
		[1] = QueueModule.new(), 
		[2] = QueueModule.new(), 
		[3] = QueueModule.new(), 
		[4] = QueueModule.new()
	} :: {[number]: Queue<QueuedMessage>}
	self.CircuitBreakers = {} :: {[string]: CircuitBreaker}
	self.Signals = {
		EventRegistered = SignalPlusModule(),
		EventFired = SignalPlusModule(),
		RequestSent = SignalPlusModule(),
		RequestReceived = SignalPlusModule(),
		ThrottleExceeded = SignalPlusModule(),
		CircuitBroken = SignalPlusModule(),
		CircuitReset = SignalPlusModule(),
		Error = SignalPlusModule()
	} :: ClientManagerSignals
	self.DebugEnabled = false -- Initialize if needed

	return self :: ClientManager
end

function ClientManagerImpl:Initialize(): ClientManager
	-- Get the remote events folder, wait briefly
	local success, remoteFolder = pcall(function()
		return ReplicatedStorage:WaitForChild("NetRayRemotes", 10)
	end)

	if success and remoteFolder and remoteFolder:IsA("Folder") then
		self.RemoteFolder = remoteFolder
	else
		warn("[NetRay ClientManager] Could not find NetRayRemotes Folder in ReplicatedStorage within 10s. Network features might be delayed or fail.")
		self.RemoteFolder = nil -- Ensure it's nil if not found
	end

	-- Initialize queue processing
	self:StartQueueProcessing()

	-- Start request throttling reset loops
	task.spawn(function()
		while true do
			task.wait(1)
			self.OutgoingRequests.Count = 0
			-- Don't reset LastReset here, CheckOutgoingThrottle compares against current time
		end
	end)
	task.spawn(function()
		while true do
			task.wait(0.1) -- 100ms
			self.OutgoingRequests.Burst.Count = 0
			-- Don't reset LastReset here
		end
	end)

	return self
end

function ClientManagerImpl:StartQueueProcessing()
	task.spawn(function()
		while true do

			local cycleStartTime = tick()
			local processedAny = false
		--	print(os.time(), "[Queue] Cycle Start") -- Optional: Keep if needed

			-- Process Critical (all)
			local criticalQueue = self.MessageQueues[0]
			while not criticalQueue:IsEmpty() do
				local message = criticalQueue:Dequeue()
				-- Safer Debug Print
			--	print(os.time(), string.format("[Mgr Proc] Cycle Critical. Dequeued item:"))
			--	print("  ---> Message Content:", message)
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

					-- Corrected / Safer Debug Print:
				--	print(os.time(), string.format("[Mgr Proc] Cycle - Prio %d, ProcCount %d, Limit %d. Dequeued item:", priority, processedCount, limit))
				--	print("  ---> Message Content:", message) -- Print the table directly

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
					local processTarget = math.max(1, limit) -- Try at least 1
					local currentQueue = self.MessageQueues[priority]
					while not currentQueue:IsEmpty() and processedCount < processTarget do
						local message = currentQueue:Dequeue()

						-- Corrected / Safer Debug Print:
				--		print(os.time(), string.format("[Mgr Proc] Cycle Low/BG - Prio %d, ProcCount %d, Limit %d. Dequeued item:", priority, processedCount, limit))
				--		print("  ---> Message Content:", message) -- Print the table directly

						self:ProcessMessage(message)
						processedCount += 1
					end
				end
			end

	--		 print(os.time(), "[Queue] Cycle End") -- Optional: Keep if needed
			task.wait(CYCLE_WAIT)
		end
		 warn("[Queue] Processing Loop EXITED!") -- Should not happen
	end)
end

function ClientManagerImpl:ProcessMessage(message: QueuedMessage?)
	if not message then return end

	local fn = message.callback
	local args = message.args

	if typeof(fn) == "function" then
		local success, err = pcall(function()
			fn(unpack(args))
		end)

		if not success then
			warn("[NetRay ClientManager] Error processing queued message: " .. tostring(err))
			self.Signals.Error:Fire(err, "QueueProcessing", debug.traceback()) -- Add context and traceback
		end
	else
		warn("[NetRay ClientManager] Invalid callback type in message queue:", typeof(fn))
		self.Signals.Error:Fire("Invalid callback type in message queue", message)
	end
end

-- Gets (and waits briefly for) a specific RemoteEvent instance
function ClientManagerImpl:GetRemoteEvent(eventName: string): RemoteEvent?
	if not self.RemoteFolder then
		warn("[NetRay ClientManager] Cannot get RemoteEvent '"..eventName.."': RemoteFolder not found/initialized.")
		return nil
	end

	-- Use FindFirstChild first for efficiency if it already exists
	local remoteEvent = self.RemoteFolder:FindFirstChild(eventName)
	if remoteEvent and remoteEvent:IsA("RemoteEvent") or remoteEvent:IsA("UnreliableRemoteEvent") then
		return remoteEvent
	elseif remoteEvent then
		warn(("[NetRay ClientManager] Instance '%s' exists but is not a RemoteEvent."):format(eventName))
		return nil -- Don't wait if wrong type exists
	end

	-- If not found, wait briefly
	local success, foundEvent = pcall(function()
		return self.RemoteFolder:WaitForChild(eventName, 5) -- Reduced wait time
	end)

	if success and foundEvent and foundEvent:IsA("RemoteEvent") or foundEvent:IsA("UnreliableRemoteEvent") then
		return foundEvent
	elseif success and foundEvent then
		warn(("[NetRay ClientManager] Found '%s' but it is not a RemoteEvent (Type: %s)."):format(eventName, foundEvent.ClassName))
		return nil
	else
		warn(("[NetRay ClientManager] RemoteEvent '%s' not found within timeout."):format(eventName))
		return nil -- Not found or WaitForChild errored
	end
end

-- Gets (and waits briefly for) a specific RemoteFunction instance
function ClientManagerImpl:GetRemoteFunction(eventName: string): RemoteFunction?
	if not self.RemoteFolder then
		warn("[NetRay ClientManager] Cannot get RemoteFunction '"..eventName.."': RemoteFolder not found/initialized.")
		return nil
	end
	local remoteName = eventName .. "_RF"

	-- Use FindFirstChild first
	local remoteFunction = self.RemoteFolder:FindFirstChild(remoteName)
	if remoteFunction and remoteFunction:IsA("RemoteFunction") then
		return remoteFunction
	elseif remoteFunction then
		warn(("[NetRay ClientManager] Instance '%s' exists but is not a RemoteFunction."):format(remoteName))
		return nil
	end

	-- If not found, wait briefly
	local success, foundFunc = pcall(function()
		return self.RemoteFolder:WaitForChild(remoteName, 5) -- Reduced wait time
	end)

	if success and foundFunc and foundFunc:IsA("RemoteFunction") then
		return foundFunc
	elseif success and foundFunc then
		warn(("[NetRay ClientManager] Found '%s' but it is not a RemoteFunction (Type: %s)."):format(remoteName, foundFunc.ClassName))
		return nil
	else
		warn(("[NetRay ClientManager] RemoteFunction '%s' not found within timeout."):format(remoteName))
		return nil -- Not found or WaitForChild errored
	end
end


function ClientManagerImpl:_InternalRegisterEvent(eventName: string, options: ClientEventOptions?): ClientRegisteredEventInfo?
	options = options or {}
	if self.Events[eventName] then
		-- Return existing info if already registered (e.g., multiple GetEvent calls)
		return self.Events[eventName]
	end

	local remoteEvent = self:GetRemoteEvent(eventName)
	if not remoteEvent then
		warn("[NetRay ClientManager] Failed to find RemoteEvent for internal registration: " .. eventName)
		return nil -- Cannot proceed without the remote
	end

	-- Create the info structure
	local eventInfo: ClientRegisteredEventInfo = {
		Remote = remoteEvent,
		Options = options,
		Handlers = {} -- Handlers added by ClientEvent:OnEvent
	}
	self.Events[eventName] = eventInfo

	-- Set up client-side circuit breaker if specified in options
	if options.circuitBreaker and not self.CircuitBreakers[eventName] then
		local cbOpts = options.circuitBreaker
		self.CircuitBreakers[eventName] = CircuitBreakerModule.new({
			failureThreshold = cbOpts.failureThreshold or 3, -- Lower threshold for client
			resetTimeout = cbOpts.resetTimeout or 15, -- Shorter timeout for client
			fallback = cbOpts.fallback
		}) :: CircuitBreaker
	end

	self.Signals.EventRegistered:Fire(eventName)

	return eventInfo
end

-- Checks if an outgoing request would exceed throttle limits
function ClientManagerImpl:CheckOutgoingThrottle(): boolean
	local now = tick()
	local throttleState = self.OutgoingRequests

	-- Check global limit (reset logic moved to background task)
	if throttleState.Count >= throttleState.Limit then
		self.Signals.ThrottleExceeded:Fire("global", throttleState.Count, throttleState.Limit)
		return false
	end

	-- Check burst limit (reset logic moved to background task)
	if throttleState.Burst.Count >= throttleState.Burst.Limit then
		self.Signals.ThrottleExceeded:Fire("burst", throttleState.Burst.Count, throttleState.Burst.Limit)
		return false
	end

	-- Increment counters *after* checks pass
	throttleState.Count += 1
	throttleState.Burst.Count += 1

	return true -- Allowed
end

-- Enqueues a message (callback + args) for prioritized processing
function ClientManagerImpl:EnqueueMessage(priority: number, callback: (...any) -> (), ...)
	-- Validate priority
	priority = math.clamp(priority or Constants.Priority.NORMAL or 2, 0, 4) -- Use Constants
	local queue = self.MessageQueues[priority]
	if not queue then
		warn("[NetRay ClientManager] Invalid priority level for EnqueueMessage:", priority)
		queue = self.MessageQueues[Constants.Priority.NORMAL or 2] -- Fallback
	end

	local args = {...}
	local message: QueuedMessage = {
		callback = callback,
		args = args
	}
	queue:Enqueue(message)
end

-- Executes client-side middleware for a given event/data
function ClientManagerImpl:InvokeMiddleware(eventName: string, data: any): (boolean, any?)
	return self.Middleware:Execute(eventName, nil, data)
end

-- Return the implementation table
return ClientManagerImpl