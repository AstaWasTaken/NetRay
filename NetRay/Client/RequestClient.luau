--!optimize 2

--[[
    RequestClient.lua
    Implements the client-side of the request/response pattern with promise support
    Updated with fixes for pcall, compressor calls, timeout, deserialization.
	Author: Asta (@TheYusufGamer)
]]

-- Type Imports
local Promise = require(script.Parent.Parent.ThirdParty.Promise)
local Serializer = require(script.Parent.Parent.Shared.Serializer)
local TypeChecker = require(script.Parent.Parent.Shared.TypeChecker)
local Compressor = require(script.Parent.Parent.Shared.Compressor)
local Errors = require(script.Parent.Parent.Shared.Errors)
local ClientManagerModule = require(script.Parent.Parent.Client.ClientManager)
local CircuitBreakerModule = require(script.Parent.Parent.Shared.CircuitBreaker)


type Promise<T> = Promise.Promise<T>
type ClientManager = ClientManagerModule.ClientManager
type TypeCheckerResult = TypeChecker.TypeCheckerResult
type NetRayError = Errors.NetRayError 
type CircuitBreaker = CircuitBreakerModule.CircuitBreaker

-- Type for the options passed to RequestClient.new
type RequestClientOptions = {
	timeout: number?,
	compression: boolean?, -- Applies to C->S request payload and S->C response payload?
	requestTypeDefinition: any?, -- For C->S request data / S->C request data
	responseTypeDefinition: any?, -- For C->S response data / S->C response data
	circuitBreaker: { -- Client-side CB options
		failureThreshold: number?,
		resetTimeout: number?,
		fallback: ((...any) -> any)? -- Fallback for C->S request failure
	}?,
	[string]: any -- Allow other potential options
}

-- Type for the user-provided request handler function (for S->C requests)
type RequestHandler = (requestData: any) -> any -- Returns the response data to send back to server

-- Type for the internal wrapper payload used for communication
-- Reusing the definition conceptually from RequestServer
type CommunicationPayload = {
	success: boolean,
	data: any?,
	error: string?,
	__compressed: boolean?, -- Flag indicates if 'data' field is compressed
	fromFallback: boolean? -- Flag for CB fallback result
}

-- Type for the RequestClient class itself
export type RequestClientType = {
	-- Properties
	Name: string,
	Options: RequestClientOptions,
	ClientManager: ClientManager,
	RemoteFunction: RemoteFunction, -- Should exist after successful .new()
	Handler: RequestHandler?, -- For S->C requests
	Timeout: number,
	UseCompression: boolean,
	RequestTypeDefinition: any?,
	ResponseTypeDefinition: any?,

	-- Methods
	SetupResponseHandler: (self: RequestClientType) -> (), -- Sets up OnClientInvoke
	OnRequest: (self: RequestClientType, callback: RequestHandler) -> RequestClientType, -- For S->C requests
	Request: <T>(self: RequestClientType, data: any?) -> Promise<T>, -- For C->S requests
}

-- Define the RequestClient module table
local RequestClient = {}
RequestClient.__index = RequestClient

-- Helper for logging errors consistently
local function logError(eventName: string, message: string, ...)
	warn(("[NetRay RequestClient Error - %s] %s"):format(eventName, message), ...)
end

-- Constructor
function RequestClient.new(eventName: string, options: RequestClientOptions?, clientManager: ClientManager): RequestClientType? -- Return optional
	options = options or {}
	local self: RequestClientType = setmetatable({}, RequestClient)

	self.Name = eventName
	self.Options = options
	self.ClientManager = clientManager

	local remoteFunction = clientManager:GetRemoteFunction(eventName)
	if not remoteFunction then
		warn("[NetRay RequestClient] Failed to find RemoteFunction for '" .. eventName .. "'. Request functionality disabled.")
		return nil -- Cannot operate without the remote
	end
	self.RemoteFunction = remoteFunction

	-- Create client-side circuit breaker if needed
	if options.circuitBreaker and not clientManager.CircuitBreakers[eventName] then
		local cbOpts = options.circuitBreaker
		clientManager.CircuitBreakers[eventName] = CircuitBreakerModule.new({
			failureThreshold = cbOpts.failureThreshold or 3,
			resetTimeout = cbOpts.resetTimeout or 15,
			fallback = cbOpts.fallback
		}) :: CircuitBreaker
	end

	self.Handler = nil -- Set by OnRequest
	self.Timeout = options.timeout or 10
	self.UseCompression = options.compression == true
	self.RequestTypeDefinition = options.requestTypeDefinition
	self.ResponseTypeDefinition = options.responseTypeDefinition

	self:SetupResponseHandler()

	return self :: RequestClientType
end

-- Helper to serialize the S->C response payload wrapper
function SerializeResponse(payload: CommunicationPayload): buffer?
	local serializeSuccess, serializedResult = pcall(Serializer.Serialize, payload)
	if not serializeSuccess then
		logError("SerializeResponse_Client", "Failed to serialize S2C response payload:", serializedResult)
		-- Fallback serialization
		local fallbackPayload: CommunicationPayload = {success=false, error="Client internal serialization error"}
		local fallbackSuccess, fallbackSerialized = pcall(Serializer.Serialize, fallbackPayload)
		if fallbackSuccess then
			return fallbackSerialized :: buffer?
		else
			warn("[NetRay RequestClient CRITICAL] Failed even to serialize S2C fallback error!")
			return nil
		end
	end
	return serializedResult :: buffer?
end

-- Sets up the OnClientInvoke handler (for Server -> Client requests)
function RequestClient:SetupResponseHandler()
	-- RemoteFunction existence checked in .new
	self.RemoteFunction.OnClientInvoke = function(receivedData: buffer?): buffer? -- Type the incoming buffer

		-- pcall wrap the entire handler logic
		local overallSuccess, responseToSend: CommunicationPayload = pcall(function(): CommunicationPayload
			assert(receivedData ~= nil, "OnClientInvoke called without receivedData")

			-- 1. Check Client Throttling 
			-- No Rate Limit check needed on client for incoming requests

			-- 2. Circuit breaker check (for S->C handler execution)
			-- Use a distinct name if CB applies to handling S->C requests vs making C->S requests
			local circuitBreaker = self.ClientManager.CircuitBreakers[self.Name .. "_S2C_Handler"]
			if circuitBreaker and not circuitBreaker:IsAllowed() then
				if typeof(circuitBreaker.Options.fallback) == "function" then
					local fallbackSuccess, fallbackResult = pcall(circuitBreaker.Options.fallback, receivedData) -- Pass raw data?
					if fallbackSuccess then
						return { success = true, data = fallbackResult, fromFallback = true }
					else
						logError(self.Name, "S2C Client circuit breaker fallback errored:", fallbackResult)
						return { success = false, error = "S2C fallback failed." }
					end
				else
					return { success = false, error = "S2C service unavailable (circuit open)" }
				end
			end

			-- 3. Deserialize incoming request wrapper payload from server
			local deserializeSuccess, requestPayloadWrapper: CommunicationPayload = pcall(Serializer.Deserialize, receivedData)
			if not deserializeSuccess then
				logError(self.Name, "Failed to deserialize S2C request wrapper:", tostring(requestPayloadWrapper))
				-- Cannot record CB failure if we can't even parse the request
				return { success = false, error = "Failed to process S2C request data format" }
			end
			-- Validate wrapper structure
			if requestPayloadWrapper == nil then
				logError(self.Name, "Deserialized S2C request wrapper is nil")
				return { success = false, error = "Received invalid S2C request wrapper" }
			end
			if typeof(requestPayloadWrapper) ~= "table" or requestPayloadWrapper.success == nil then
				logError(self.Name, "Invalid S2C request wrapper structure")
				return { success = false, error = "Invalid S2C request wrapper structure received" }
			end
			-- Check if server sent an initial error payload (shouldn't happen for requests usually)
			if not requestPayloadWrapper.success then
				logError(self.Name, "Received error payload instead of S2C request:", requestPayloadWrapper.error)
				return { success = false, error = "Server indicated error in request: " .. tostring(requestPayloadWrapper.error)}
			end

			-- 4. Decompress the actual request *data* if flagged by server
			local finalRequestData = requestPayloadWrapper.data
			if requestPayloadWrapper.__compressed == true then
				if typeof(finalRequestData) ~= "string" and typeof(finalRequestData) ~= "buffer" then -- Check type before decompress
					logError(self.Name, "Server flagged compressed S2C data, but payload isn't string/buffer.")
					return { success = false, error = "Inconsistent compression flag/payload type"}
				end
				local decompressSuccess, decompressedResult = pcall(function()
					return Compressor:Decompress(finalRequestData)
					end) -- Removed Compressor arg
				if not decompressSuccess then
					logError(self.Name, "Failed to decompress S2C request data:", decompressedResult)
					-- If decompression fails, we can't proceed. Don't record CB failure.
					return { success = false, error = "Failed to decompress S2C request data" }
				end
				finalRequestData = decompressedResult -- Use decompressed data
			end

			-- 5. Type checking for the final S->C request data
			if self.RequestTypeDefinition then
				local typeCheckResult: TypeCheckerResult = TypeChecker:Validate(finalRequestData, self.RequestTypeDefinition)
				if not typeCheckResult.success then
					logError(self.Name, "S2C Request type validation failed:", typeCheckResult.error)
					-- Don't record CB failure for server sending bad types
					return { success = false, error = "S2C Request type validation failed: " .. (typeCheckResult.error or "Unknown error") }
				end
			end

			-- 6. Run client middleware (incoming S->C request)
			local continueProcessing, processedData = self.ClientManager:InvokeMiddleware(self.Name .. "_S2C_Incoming", finalRequestData) -- Use distinct name?
			if not continueProcessing then
				if self.ClientManager.DebugEnabled then print(("[NetRay RequestClient] Middleware blocked S2C request '%s'"):format(self.Name)) end
				-- Don't record CB failure for middleware block
				return { success = false, error = "S2C Request blocked by client middleware" }
			end
			local dataForHandler = if processedData ~= nil then processedData else finalRequestData

			-- 7. Check if Handler exists (registered via OnRequest)
			if not self.Handler then
				logError(self.Name, "No handler registered for incoming S2C request.")
				-- Record CB failure if service exists but handler is missing? Yes.
				if circuitBreaker then circuitBreaker:RecordFailure() end
				return { success = false, error = "No S2C request handler registered for " .. self.Name }
			end

			-- 8. Execute the user's Handler (protected by pcall)
			-- Handler receives the processed request data, returns response data
			local resultSuccess, resultOrError = pcall(self.Handler, dataForHandler)

			if not resultSuccess then
				-- Handler failed
				logError(self.Name, "S2C request handler errored:", resultOrError)
				if circuitBreaker then circuitBreaker:RecordFailure() end -- Record failure
				return { success = false, error = "S2C Request handler error: " .. tostring(resultOrError) }
			end

			-- 9. Handler success path
			if circuitBreaker then circuitBreaker:RecordSuccess() end
			local resultData = resultOrError -- This is the data to send back to server

			-- 10. Type checking for the S->C *response* data generated by the handler
			if self.ResponseTypeDefinition then
				local typeCheckResult: TypeCheckerResult = TypeChecker:Validate(resultData, self.ResponseTypeDefinition)
				if not typeCheckResult.success then
					logError(self.Name, "S2C Response type validation failed:", typeCheckResult.error)
					-- Treat handler producing invalid response type as a failure
					if circuitBreaker then circuitBreaker:RecordFailure() end
					return { success = false, error = "S2C Response type validation failed: " .. (typeCheckResult.error or "Unknown error") }
				end
			end

			-- 11. Optional: Compress the response *data* before wrapping
			local dataToSend = resultData
			local dataWasCompressed = false
			if self.UseCompression then
				-- Only compress if data exists and compression helps
				if dataToSend ~= nil then
					local compressSuccess, compressedResult = pcall(function()
						return Compressor:Compress(dataToSend)
						end) -- Removed Compressor arg
					if compressSuccess and compressedResult then
						local originalSize = Serializer.EstimateSize(dataToSend)
						local compressedSize = Serializer.EstimateSize(compressedResult)
						if compressedSize < originalSize and compressedSize > 0 then
							if self.ClientManager.DebugEnabled then print(("[NetRay RequestClient] Compressing S2C response data for '%s' (%d -> %d bytes)"):format(self.Name, originalSize, compressedSize)) end
							dataToSend = compressedResult
							dataWasCompressed = true
						end
					elseif not compressSuccess then
						logError(self.Name, "Failed to compress S2C response data:", compressedResult)
						-- Continue with uncompressed
					end
				end
			end

			-- 12. Prepare successful response wrapper payload to send back to server
			local responsePayload: CommunicationPayload = {
				success = true,
				data = dataToSend, -- Potentially compressed data
				__compressed = dataWasCompressed -- Flag if data is compressed
			}

			return responsePayload -- Return the success wrapper

		end) -- End of overall pcall

		-- Determine the final payload to serialize based on pcall success
		local finalPayload: CommunicationPayload
		if not overallSuccess then
			-- overallSuccess is false, responseToSend contains the error object/message
			logError(self.Name, "CRITICAL Error during OnClientInvoke processing:", tostring(responseToSend))
			finalPayload = { success = false, error = "Internal client error during S2C request handling." }
		else
			-- overallSuccess is true, responseToSend is the CommunicationPayload wrapper
			finalPayload = responseToSend
		end

		-- Final Step: Serialize the determined payload and return buffer to server
		local serializedBuffer = SerializeResponse(finalPayload)
		return serializedBuffer -- Return buffer or nil
	end
end

-- Registers the function to handle incoming requests from the server (S->C)
function RequestClient:OnRequest(callback: RequestHandler): RequestClientType
	if typeof(callback) ~= "function" then
		error("[NetRay RequestClient] OnRequest expects a function(data) as its argument", 2)
	end
	self.Handler = callback
	return self -- Return self for chaining
end

-- Method to make a request to the server (Client -> Server)
-- Generic <T> for the expected type of the resolved data from the server
function RequestClient:Request<T>(data: any?): Promise<T>

	-- Create promise first
	return Promise.new(function(resolve: (T) -> (), reject: (NetRayError) -> ())
		-- Variables needed across async boundaries
		local requestActive = true
		local timeoutCoroutine: thread | nil = nil
		local circuitBreaker = self.ClientManager.CircuitBreakers[self.Name] -- Get CB instance

		-- Perform checks and potentially yielding operations in a separate thread
		task.spawn(function()
			local payloadToSend: any -- The actual data payload to serialize
			local serializedData: buffer | nil = nil
			local prepError: NetRayError | nil = nil

			-- Wrap preparation steps (checks, processing, serialization) in pcall
			local prepSuccess, prepResult = pcall(function()
				-- 1. Check Throttling *before* anything else
				if not self.ClientManager:CheckOutgoingThrottle() then
					-- Throw specific error type
					error(Errors.new("RateLimit", "Request throttled: too many outgoing requests", { eventName = self.Name }))
				end

				-- 2. Circuit breaker check (Outgoing C->S)
				if circuitBreaker and not circuitBreaker:IsAllowed() then
					-- Attempt fallback if defined
					if typeof(circuitBreaker.Options.fallback) == "function" then
						-- Fallback needs to resolve/reject the *outer* promise.
						-- This direct execution within pcall is tricky.
						-- Let's handle fallback *outside* the pcall after checking CB state.
						error("CircuitBreakerOpen_NeedsFallback") -- Special marker
					else
						error(Errors.new("CircuitOpen", "Service unavailable (circuit open)", { eventName = self.Name }))
					end
				end
				-- If circuitBreaker exists and IS allowed, proceed.

				-- 3. Type checking for C->S request data
				if self.RequestTypeDefinition and data ~= nil then
					local typeCheckResult: TypeCheckerResult = TypeChecker:Validate(data, self.RequestTypeDefinition)
					if not typeCheckResult.success then
						error(Errors.new("Validation", "C2S Request type validation failed: " .. (typeCheckResult.error or "Unknown"), { eventName = self.Name }))
					end
				end

				-- 4. Run client middleware (Outgoing C->S)
				local continueProcessing, processedData = self.ClientManager:InvokeMiddleware(self.Name .. "_C2S_Outgoing", data) -- Use distinct name?
				if not continueProcessing then
					if self.ClientManager.DebugEnabled then print(("[NetRay RequestClient] Middleware blocked C2S request '%s'"):format(self.Name)) end
					error("MiddlewareBlocked") -- Use special marker
				end
				local dataToSend = if processedData ~= nil then processedData else data -- Use original data if middleware didn't change it

				-- 5. Prepare request *data* payload (Compress if needed)
				payloadToSend = dataToSend -- Start with the data itself (can be nil)
				local dataWasCompressed = false 
                -- Compression logic removed for C->S request data - usually done on response
                -- if self.UseCompression then ... payloadToSend = compressed ... end

				-- 6. Serialize the actual data payload
				local serSuccess, serResult = pcall(Serializer.Serialize, payloadToSend)
				if not serSuccess then
					logError(self.Name, "Failed to serialize C2S request data:", serResult)
					error(Errors.new("Serialization", "Failed to serialize C2S request", { eventName = self.Name }))
				end
				serializedData = serResult :: buffer?
				if serializedData == nil then
					error(Errors.new("Serialization", "C2S request data serialized to nil", { eventName = self.Name }))
				end
			end) -- End of pcall for prep/serialization

			-- Handle Circuit Breaker Fallback or Prep Errors *before* timeout starts
			if not prepSuccess then
				if type(prepResult) == "string" and prepResult == "CircuitBreakerOpen_NeedsFallback" then
					-- Execute fallback outside pcall, resolving/rejecting the main promise
					if circuitBreaker and typeof(circuitBreaker.Options.fallback) == "function" then
						local fbSuccess, fbResult = pcall(circuitBreaker.Options.fallback, data)
						if requestActive then -- Check if still active
							requestActive = false
							-- No timeout to cancel yet
							if fbSuccess then resolve(fbResult :: T) else reject(Errors.new("CircuitOpen", "Circuit fallback failed: "..tostring(fbResult), {eventName = self.Name})) end
						end
					else
						-- Should not happen if marker was thrown, but handle defensively
						if requestActive then requestActive = false; reject(Errors.new("CircuitOpen", "Circuit open, no fallback", {eventName=self.Name})) end
					end
				elseif type(prepResult) == "string" and prepResult == "MiddlewareBlocked" then
					-- Middleware block, reject promise
					if requestActive then requestActive = false; reject(Errors.new("Middleware", "Request blocked by client middleware", {eventName=self.Name})) end
				else
					-- Other prep error (Throttle, Validation, Serialization)
					if requestActive then requestActive = false; reject(prepResult :: NetRayError) end -- prepResult is the error object
				end
				return -- Stop task.spawn thread
			end

			-- If prep was successful and CB wasn't open/fallback wasn't needed:
			-- Check if serializedData is valid before proceeding
			if serializedData == nil then
				if requestActive then requestActive = false; reject(Errors.new("Internal", "C2S Prep internal error: serialized data is nil", {eventName=self.Name})) end
				return
			end

			-- Start timeout *after* successful prep and checks
			timeoutCoroutine = task.delay(self.Timeout, function()
				if requestActive then
					requestActive = false -- Mark as inactive first
					if circuitBreaker then circuitBreaker:RecordFailure() end -- Timeout counts as failure
					reject(Errors.new("Timeout", ("Request '%s' timed out after %d seconds"):format(self.Name, self.Timeout), { eventName = self.Name }))
				end
			end)

			-- Check activity again before invoking server (timeout could trigger immediately)
			if not requestActive then return end

			-- 7. Invoke Server (wrapped in pcall)
			local invokeSuccess, serverResultBuffer = pcall(self.RemoteFunction.InvokeServer, self.RemoteFunction, serializedData)

			if not requestActive then return end -- Check if timed out during InvokeServer

			if not invokeSuccess then
				requestActive = false
				if timeoutCoroutine then task.cancel(timeoutCoroutine) end
				if circuitBreaker then circuitBreaker:RecordFailure() end -- Network error counts as failure
				reject(Errors.new("Network", "Failed to invoke server: " .. tostring(serverResultBuffer), { eventName = self.Name }))
				return
			end

			if serverResultBuffer == nil then
				requestActive = false
				if timeoutCoroutine then task.cancel(timeoutCoroutine) end
				if circuitBreaker then circuitBreaker:RecordFailure() end -- Nil response counts as failure
				reject(Errors.new("Network", "Server returned nil response buffer", { eventName = self.Name }))
				return
			end

			-- 8. Deserialize the server's response wrapper (wrapped in pcall)
			local deserializeSuccess, deserializedPayload: CommunicationPayload = pcall(Serializer.Deserialize, serverResultBuffer)

			if not requestActive then return end

			if not deserializeSuccess then
				requestActive = false; if timeoutCoroutine then task.cancel(timeoutCoroutine) end
				if circuitBreaker then circuitBreaker:RecordFailure() end -- Deserialization failure counts as failure
				reject(Errors.new("Serialization", "Failed to deserialize server response: " .. tostring(deserializedPayload), { eventName = self.Name }))
				return
			end
			-- Validate wrapper structure
			if deserializedPayload == nil then
				requestActive = false; if timeoutCoroutine then task.cancel(timeoutCoroutine) end
				if circuitBreaker then circuitBreaker:RecordFailure() end
				reject(Errors.new("Serialization", "Server response wrapper deserialized to nil", { eventName = self.Name }))
				return
			end
			if typeof(deserializedPayload) ~= "table" or deserializedPayload.success == nil then
				requestActive = false; if timeoutCoroutine then task.cancel(timeoutCoroutine) end
				if circuitBreaker then circuitBreaker:RecordFailure() end
				reject(Errors.new("Serialization", "Invalid response wrapper structure received from server.", { eventName = self.Name }))
				return
			end

			-- 9. Check server success flag in wrapper
			if not deserializedPayload.success then
				requestActive = false; if timeoutCoroutine then task.cancel(timeoutCoroutine) end
				if circuitBreaker then circuitBreaker:RecordFailure() end -- Server error counts as failure
				reject(Errors.new("Internal", "Server Error: " .. tostring(deserializedPayload.error or "Unknown server error"), { eventName = self.Name }))
				return
			end

			-- Server reported success, process the 'data' field
			local finalServerData = deserializedPayload.data
			local decompressError: NetRayError | nil = nil

			-- 10. Decompress the *data* payload if flagged by server
			if deserializedPayload.__compressed == true then
				if typeof(finalServerData) ~= "string" and typeof(finalServerData) ~= "buffer" then
					decompressError = Errors.new("Internal", "Server indicated compressed data, but payload is not string/buffer", { eventName = self.Name })
				else
					local decompressSuccess, decompressedResult = pcall(function()
						return Compressor:Decompress(finalServerData)
					end) -- Removed Compressor arg
					if not decompressSuccess then
						decompressError = Errors.new("Internal", "Failed to decompress server response data: " .. tostring(decompressedResult), { eventName = self.Name })
					else
						finalServerData = decompressedResult
					end
				end
			end

			-- Check for decompression error
			if decompressError then
				if requestActive then
					requestActive = false
					if timeoutCoroutine then task.cancel(timeoutCoroutine) end
					if circuitBreaker then circuitBreaker:RecordFailure() end -- Decompression fail counts as failure
					reject(decompressError)
				end
				return
			end

			-- Success path complete
			requestActive = false
			if timeoutCoroutine then task.cancel(timeoutCoroutine) end -- Cancel timer definitively

			-- 11. Type checking for the final response data
			if self.ResponseTypeDefinition then
				local typeCheckResult: TypeCheckerResult = TypeChecker:Validate(finalServerData, self.ResponseTypeDefinition)
				if not typeCheckResult.success then
					if circuitBreaker then circuitBreaker:RecordFailure() end -- Invalid response type counts as failure
					reject(Errors.new("Validation", "Response type validation failed: " .. (typeCheckResult.error or "Unknown"), { eventName = self.Name }))
					return
				end
			end

			-- 12. Record success & Resolve
			if circuitBreaker then circuitBreaker:RecordSuccess() end
			resolve(finalServerData :: T) -- Resolve with the actual, processed data, cast to generic T

		end) -- End of task.spawn
	end) -- End of Promise.new
end

return RequestClient