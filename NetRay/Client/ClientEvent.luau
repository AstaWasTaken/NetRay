--!optimize 2

--[[
    ClientEvent.lua
    Handles client-side event operations, with type validation and optimized networking
    Author: Asta (@TheYusufGamer)
]]

-- Type Imports
local ClientManagerModule = require(script.Parent.Parent.Client.ClientManager)
local TypeChecker = require(script.Parent.Parent.Shared.TypeChecker)
local DynamicSender = require(script.Parent.Parent.Shared.DynamicSender)
local CircuitBreakerModule = require(script.Parent.Parent.Shared.CircuitBreaker)
local Errors = require(script.Parent.Parent.Shared.Errors)
local Constants = require(script.Parent.Parent.Shared.Constants)

-- Assume necessary types are exported or defined
type ClientManager = ClientManagerModule.ClientManager
type ClientEventOptions = ClientManagerModule.ClientEventOptions 
type TypeCheckerResult = TypeChecker.TypeCheckerResult -- e.g., {success: boolean, error: string?}
type CircuitBreaker = CircuitBreakerModule.CircuitBreaker

-- Define the type for the callback used in OnEvent
type ClientEventHandler = (data: any) -> ()

-- Type definition for the ClientEvent *implementation*
-- This aligns with the client-side aspects of the NetRayEvent unified type.
export type ClientEventType = {
	-- Properties matching NetRayEvent
	Name: string,
	Options: ClientEventOptions,
	RemoteEvent: RemoteEvent, -- Should always exist after successful .new()
	TypeDefinition: any?,
	Priority: number, -- Used for queuing incoming events

	-- Client-Specific Implementation Details
	ClientManager: ClientManager,

	-- Methods matching NetRayEvent (Client-side subset + OnEvent)
	-- Note: Using ClientEventType here for 'self' as it's the internal implementation type
	OnEvent: (self: ClientEventType, callback: ClientEventHandler) -> ClientEventType, -- Returns self for chaining
	FireServer: (self: ClientEventType, data: any) -> (),

	-- Internal Helper Methods
	SetupListeners: (self: ClientEventType) -> (),
}

-- Define the ClientEvent module table
local ClientEvent = {}
ClientEvent.__index = ClientEvent

-- Constructor
function ClientEvent.new(eventName: string, options: ClientEventOptions?, clientManager: ClientManager): ClientEventType? -- Return optional as registration might fail
	options = options or {}
	local self: ClientEventType = setmetatable({}, ClientEvent)

	self.Name = eventName
	self.Options = options
	self.ClientManager = clientManager

	-- Register internally with the ClientManager to get RemoteEvent and setup CBs
	-- Using the renamed internal method
	local eventInfo = clientManager:_InternalRegisterEvent(eventName, self.Options)
	if not eventInfo or not eventInfo.Remote then
		warn("[NetRay ClientEvent] Failed to register/find RemoteEvent for: " .. eventName .. ". Event functionality disabled.")
		-- Cannot proceed without RemoteEvent, return nil
		return nil
	end

	self.RemoteEvent = eventInfo.Remote :: RemoteEvent -- Assign the found RemoteEvent

	-- Store a reference to this ClientEvent instance within the manager's info
	-- This allows retrieval via GetEvent without creating a new instance each time.
	eventInfo.Event = self

	-- Store type definitions
	self.TypeDefinition = options.typeDefinition

	-- Store priority for incoming event processing
	self.Priority = options.priority or Constants.PRIORITY.NORMAL or 2 -- Default to NORMAL

	-- Set up listeners *after* all essential properties are set
	self:SetupListeners()

	return self :: ClientEventType -- Cast ensures return type matches annotation
end

-- Internal method to set up RemoteEvent listener
function ClientEvent:SetupListeners()
	self.RemoteEvent.OnClientEvent:Connect(function(encodedData: any, instances)
		-- 1. Decode incoming data
		local decodeSuccess, decodedData = pcall(function()
			return DynamicSender:DecodeReceivedData(encodedData,instances)
		end)

		if not decodeSuccess then
			-- decodeSuccess is false, decodedData contains the error
			warn(("[NetRay ClientEvent] Failed to decode data for event '%s' from server: %s"):format(self.Name, tostring(decodedData)))
			self.ClientManager.Signals.Error:Fire("DecodeError", self.Name, decodedData)
			return
		end
		-- decodedData now holds the actual payload (or array of payloads)
		
		-- Get event info from manager (should exist)
		local eventInfo = self.ClientManager.Events[self.Name]
		if not eventInfo or not eventInfo.Handlers then
			warn(("[NetRay ClientEvent] Received event '%s' but no info/handlers found in manager."):format(self.Name))
			return -- Should not happen if .new succeeded
		end
		local handlers = eventInfo.Handlers :: {ClientEventHandler} -- Assert type

		-- Function to process a single event payload (handles validation, middleware, CB, enqueueing)
		local function processSingleEvent(data: any): boolean
			-- 2. Type Checking
			if self.TypeDefinition then
				local typeCheckResult: TypeCheckerResult = TypeChecker:Validate(data, self.TypeDefinition)
				if not typeCheckResult.success then
					warn(("[NetRay ClientEvent] Incoming type validation failed for event '%s': %s"):format(
						self.Name, typeCheckResult.error or "Unknown error"))
					self.ClientManager.Signals.Error:Fire("TypeValidationError", self.Name, data, typeCheckResult.error)
					return false -- Stop processing this specific payload
				end
			end

			-- 3. Middleware (Incoming)
			local continueProcessing, processedData = self.ClientManager:InvokeMiddleware(self.Name, data)
			if not continueProcessing then
				if self.ClientManager.DebugEnabled then
					print(("[NetRay ClientEvent] Middleware blocked incoming event '%s'"):format(self.Name))
				end
				return false -- Stop processing this specific payload
			end
			local finalData = if processedData ~= nil then processedData else data

			-- 4. Circuit Breaker Check 
			local circuitBreaker = self.ClientManager.CircuitBreakers[self.Name .. "_Handler"] -- Use distinct name
			if circuitBreaker and not circuitBreaker:IsAllowed() then
				if self.ClientManager.DebugEnabled then
					print(("[NetRay ClientEvent] Circuit breaker '%s' open, preventing handler execution."):format(self.Name .. "_Handler"))
				end
				-- Attempt fallback if defined
				if typeof(circuitBreaker.Options.fallback) == "function" then
					pcall(circuitBreaker.Options.fallback, finalData) -- Safely call fallback
				end
				-- Don't queue the message if CB is open
				return false -- Indicate failure to queue/process
			end
			local finalData = data
			-- 5. Enqueue Handler Execution
			if #handlers == 0 then
				if self.ClientManager.DebugEnabled then
					print(("[NetRay ClientEvent] Event '%s' received, but no OnEvent handlers are attached."):format(self.Name))
				end
				-- Still counts as successful processing up to this point if no handler needed
			else
				self.ClientManager.Signals.EventFired:Fire(self.Name, finalData) -- Fire signal before queueing
				for _, handler in ipairs(handlers) do
					-- Enqueue the actual handler call with the final data
					self.ClientManager:EnqueueMessage(
						self.Priority, -- Use the event's priority for queueing
						function() -- Wrap handler call to manage CB state
							local handlerSuccess = pcall(handler, finalData)
							-- Record CB success/failure *after* handler executes (if CB exists)
							if circuitBreaker then
								if handlerSuccess then
									circuitBreaker:RecordSuccess()
								else
									circuitBreaker:RecordFailure()
								end
							end
						end
						-- No args needed for the wrapper function itself
					)
				end
			end

			-- If CB exists and was allowed, we count this step (enqueueing) as success
			-- The actual handler success/failure updates the CB later.
			return true -- Indicate successful enqueueing/processing step
		end -- End of processSingleEvent

		-- Check if decoded data is likely a batch (array of tables/values)
		-- Relying on DynamicSender's potential batching mechanism.
		if typeof(decodedData) == "table" and #decodedData > 0 and typeof(decodedData[1]) ~= "nil" then
			-- Heuristic: Treat as a batch if it's a non-empty array.
			if self.ClientManager.DebugEnabled then
				print(("[NetRay ClientEvent] Processing %d batched events for '%s'"):format(#decodedData, self.Name))
			end

			for _, eventData in ipairs(decodedData :: {any}) do
				processSingleEvent(eventData) -- Process each item
				-- If one item fails (e.g., type validation), it doesn't stop others
				-- CB state might change mid-batch based on handler execution from previous items.
			end
		else
			-- Treat as a single event
			processSingleEvent(decodedData)
		end
	end)
end

-- Method to register a handler for this event
function ClientEvent:OnEvent(callback: ClientEventHandler): ClientEventType
	if typeof(callback) ~= "function" then
		error("[NetRay ClientEvent] OnEvent expects a function(data) as its argument", 2)
		-- error stops execution, no return needed
	end

	-- Add callback to the Handlers list stored in the ClientManager
	local eventInfo = self.ClientManager.Events[self.Name]
	if not eventInfo then
		-- This should ideally not happen if .new succeeded, means internal state issue.
		error("[NetRay ClientEvent] Cannot call OnEvent for '"..self.Name.."': Event info missing in ClientManager.", 2)
	end
	-- Ensure Handlers array exists (should be guaranteed by _InternalRegisterEvent)
	eventInfo.Handlers = eventInfo.Handlers or {} :: {ClientEventHandler}

	table.insert(eventInfo.Handlers, callback)

	return self -- Return self for chaining
end

-- Method to fire the event to the server
function ClientEvent:FireServer(data: any)
	-- 1. Check Throttling before proceeding
	if not self.ClientManager:CheckOutgoingThrottle() then
		warn(("[NetRay ClientEvent] FireServer throttled for event '%s': too many outgoing requests."):format(self.Name))
		-- Potentially fire a signal or handle differently? For now, just warn and return.
		return
	end

	-- 2. Circuit Breaker Check (Outgoing)
	-- Check if the circuit is open before attempting to send.
	local circuitBreaker = self.ClientManager.CircuitBreakers[self.Name] -- Assuming CB uses event name
	if circuitBreaker and not circuitBreaker:IsAllowed() then
		if self.ClientManager.DebugEnabled then
			print(("[NetRay ClientEvent] Circuit breaker open for '%s', blocking FireServer."):format(self.Name))
		end
		-- Attempt fallback if defined
		if typeof(circuitBreaker.Options.fallback) == "function" then
			pcall(circuitBreaker.Options.fallback, data) -- Safely call fallback
		end
		-- Don't record failure here, the circuit is already open.
		return -- Stop execution
	end
	-- If circuitBreaker exists and IS allowed, we proceed.

	local sendSuccess = false -- Track if the send operation itself succeeds
	local sendError = nil -- Store potential error from type/middleware/send

	local success, err = pcall(function() -- Wrap potentially erroring steps
		-- 3. Type Checking (Outgoing Data)
		if self.TypeDefinition then
			local typeCheckResult: TypeCheckerResult = TypeChecker:Validate(data, self.TypeDefinition)
			if not typeCheckResult.success then
				-- Throw a specific error to be caught by pcall
				error(Errors.new("Validation", ("Outgoing type validation failed for event '%s': %s"):format(
					self.Name, typeCheckResult.error or "Unknown error"), { eventName = self.Name }))
			end
		end
		
		if not data then
			self.RemoteEvent:FireServer()
			return
		end
		
		-- 4. Middleware (Outgoing)
		local continueProcessing, processedData = self.ClientManager:InvokeMiddleware(self.Name, data)
		if not continueProcessing then
			if self.ClientManager.DebugEnabled then
				print(("[NetRay ClientEvent] Middleware blocked outgoing event '%s'"):format(self.Name))
			end
			-- Treat middleware block as a reason not to send, but not necessarily a "failure" for CB
			error("MiddlewareBlocked") -- Special marker
		end
		local finalData = if processedData ~= nil then processedData else data

		-- 5. Send using DynamicSender
		-- DynamicSender handles serialization, compression (if configured), batching.
		-- It doesn't typically throw errors for network issues itself, but might for bad input
		
		DynamicSender:Send(self.RemoteEvent, finalData,nil ,{batchable = false})

		-- If we reach here, the send call itself didn't error immediately.
		sendSuccess = true -- Mark send attempt as successful *within pcall*
	end)

	-- Handle results of the pcall
	if not success then
		sendError = err -- Store the error object/message
		-- Check if it was just a middleware block
		if sendError == "MiddlewareBlocked" then
			-- Don't log an error, it was intentionally blocked
			sendError = nil -- Clear the error
		else
			-- Log actual errors (validation, internal DynamicSender error?)
			warn(("[NetRay ClientEvent] Error during FireServer for event '%s': %s"):format(self.Name, tostring(sendError)))
			self.ClientManager.Signals.Error:Fire(sendError, "FireServerError", self.Name)
		end
	end

	-- 6. Record Circuit Breaker Success/Failure (if CB exists)
	if circuitBreaker then
		if sendSuccess then
			circuitBreaker:RecordSuccess()
		elseif sendError ~= nil then -- Only record failure if there was an actual error (not middleware block)
			circuitBreaker:RecordFailure()
		end
	end

	-- 7. Fire Signal (optional, indicates an attempt was made)
	if sendSuccess then
		self.ClientManager.Signals.RequestSent:Fire(self.Name, data) -- Use RequestSent signal
	end

	-- Debug log (adjust based on what DynamicSender:Send actually returns, if anything)
	if self.ClientManager.DebugEnabled and sendSuccess then
		print(("[NetRay ClientEvent] Event %s fired to server."):format(self.Name))
	elseif self.ClientManager.DebugEnabled and sendError == "MiddlewareBlocked" then
		print(("[NetRay ClientEvent] Event %s blocked by middleware during FireServer."):format(self.Name))
	elseif self.ClientManager.DebugEnabled and sendError then
		print(("[NetRay ClientEvent] Event %s failed to fire: %s"):format(self.Name, tostring(sendError)))
	end
end

return ClientEvent