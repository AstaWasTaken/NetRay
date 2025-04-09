--!optimize 2

--[[
    RequestServer.lua
    Implements the server-side of the request/response pattern with promise support
    Updated with fixes for pcall usage, compressor calls, and clearer logic.
	Author: Asta (@TheYusufGamer)
]]

local Players = game:GetService("Players")

-- Type Imports
local Promise = require(script.Parent.Parent.ThirdParty.Promise)
local Serializer = require(script.Parent.Parent.Shared.Serializer)
local TypeChecker = require(script.Parent.Parent.Shared.TypeChecker)
local Compressor = require(script.Parent.Parent.Shared.Compressor)
local Errors = require(script.Parent.Parent.Shared.Errors)
local ServerManagerModule = require(script.Parent.Parent.Server.ServerManager)
local CircuitBreakerModule = require(script.Parent.Parent.Shared.CircuitBreaker) -- Import for type

-- Assume module types are exported or defined
type Promise<T> = Promise.Promise<T>
type ServerManager = ServerManagerModule.ServerManager
type TypeCheckerResult = TypeChecker.TypeCheckerResult -- e.g., {success: boolean, error: string?}
type NetRayError = Errors.NetRayError 
type CircuitBreaker = CircuitBreakerModule.CircuitBreaker -- Import CircuitBreaker type

-- Define Player type alias
type Player = Players.Player

-- Type for the options passed to RequestServer.new
type RequestServerOptions = {
	timeout: number?,
	compression: boolean?,
	requestTypeDefinition: any?, -- Specific type if using a schema system like 't'
	responseTypeDefinition: any?, -- Specific type if using a schema system like 't'
	-- circuitBreaker options are handled by ServerManager during registration
	-- rateLimit options are handled by ServerManager during registration
	[string]: any -- Allow other potential options
}

-- Type for the user-provided request handler function
type RequestHandler = (player: Player, requestData: any) -> any -- Returns the response data

-- Type for the internal wrapper payload used for communication
-- Used for both C->S response and S->C response/request payload
type CommunicationPayload = {
	success: boolean,
	data: any?,
	error: string?,
	__compressed: boolean?, -- Flag indicates if 'data' field is compressed
	fromFallback: boolean? -- Flag for CB fallback result
}

-- Type for the RequestServer class itself
export type RequestServerType = {
	-- Properties
	Name: string,
	Options: RequestServerOptions,
	ServerManager: ServerManager,
	RemoteFunction: RemoteFunction,
	Handler: RequestHandler?,
	Timeout: number,
	UseCompression: boolean,
	RequestTypeDefinition: any?,
	ResponseTypeDefinition: any?,

	-- Methods
	SetupRequestHandler: (self: RequestServerType) -> (),
	OnRequest: (self: RequestServerType, callback: RequestHandler) -> RequestServerType, -- Returns self for chaining
	Request: <T>(self: RequestServerType, player: Player, data: any?) -> Promise<T>, -- Generic for response type T
}

-- Define the RequestServer module table
local RequestServer = {}
RequestServer.__index = RequestServer

-- Helper for logging errors consistently
local function logError(eventName: string, message: string, ...)
	warn(("[NetRay RequestServer Error - %s] %s"):format(eventName, message), ...)
end

-- Constructor
function RequestServer.new(eventName: string, options: RequestServerOptions?, serverManager: ServerManager): RequestServerType
	options = options or {}
	local self: RequestServerType = setmetatable({}, RequestServer)

	self.Name = eventName
	self.Options = options
	self.ServerManager = serverManager

	local remoteFunction = serverManager:CreateRemoteFunction(eventName)
	self.RemoteFunction = remoteFunction

	-- Ensure Circuit Breaker is created if needed (using options passed to RequestServer.new)
	if options.circuitBreaker and not serverManager.CircuitBreakers[eventName] then
		local cbOpts = options.circuitBreaker
		serverManager.CircuitBreakers[eventName] = CircuitBreakerModule.new({
			failureThreshold = cbOpts.failureThreshold or 5,
			resetTimeout = cbOpts.resetTimeout or 30,
			fallback = cbOpts.fallback
		}) :: CircuitBreaker
	end
	
	self.Handler = nil
	self.Timeout = options.timeout or 10
	self.UseCompression = options.compression == true
	self.RequestTypeDefinition = options.requestTypeDefinition
	self.ResponseTypeDefinition = options.responseTypeDefinition

	self:SetupRequestHandler()

	return self :: RequestServerType -- Cast ensures return type matches annotation
end

-- Helper to serialize the final CommunicationPayload wrapper
function SerializeResponse(payload: CommunicationPayload): buffer?
	local serializeSuccess, serializedResult = pcall(Serializer.Serialize, payload)
	if not serializeSuccess then
		logError("SerializeResponse", "Failed to serialize payload:", serializedResult)
		-- Fallback serialization
		local fallbackPayload: CommunicationPayload = {success=false, error="Server internal serialization error"}
		local fallbackSuccess, fallbackSerialized = pcall(Serializer.Serialize, fallbackPayload)
		if fallbackSuccess then
			return fallbackSerialized :: buffer? -- Type assertion
		else
			warn("[NetRay RequestServer CRITICAL] Failed even to serialize fallback error!")
			return nil -- Indicate critical failure
		end
	end
	return serializedResult :: buffer? -- Type assertion
end

-- Sets up the OnServerInvoke handler for the RemoteFunction
function RequestServer:SetupRequestHandler()
	self.RemoteFunction.OnServerInvoke = function(player: Player, receivedData: buffer?): buffer? -- Explicitly buffer type

		-- Use pcall for the entire processing logic to catch unexpected errors
		local overallSuccess, responseToSend: CommunicationPayload = pcall(function(): CommunicationPayload
			assert(player ~= nil and player:IsA("Player"), "OnServerInvoke called without valid player")
			assert(receivedData ~= nil, "OnServerInvoke called without receivedData")

			-- 1. Rate limiting check (using the request name)
			if not self.ServerManager:CheckRateLimit(player, self.Name) then
				return { success = false, error = "Rate limit exceeded" }
			end

			-- 2. Circuit breaker check
			local circuitBreaker = self.ServerManager.CircuitBreakers[self.Name]
			if circuitBreaker and not circuitBreaker:IsAllowed() then -- Check if CB is open
				-- Attempt fallback if defined
				if typeof(circuitBreaker.Options.fallback) == "function" then
					-- Use pcall for safety as fallback is user code
					local fallbackSuccess, fallbackResultOrError = pcall(circuitBreaker.Options.fallback, player, receivedData)
					if fallbackSuccess then
						-- Fallback succeeded, return its result wrapped
						return { success = true, data = fallbackResultOrError, fromFallback = true }
					else
						logError(self.Name, "Circuit breaker fallback function errored:", fallbackResultOrError)
						return { success = false, error = "Service fallback failed." }
					end
				else
					-- No fallback, circuit is open
					return { success = false, error = "Service unavailable (circuit open)" }
				end
			end
			-- If circuitBreaker exists but IS allowed, we proceed.

			-- 3. Deserialize incoming request data (assuming receivedData is buffer/binary string)
			local deserializeSuccess, requestPayload = pcall(Serializer.Deserialize, receivedData)
			if not deserializeSuccess then
				logError(self.Name, "Failed to deserialize request data:", requestPayload)
				-- Don't record CB failure for client-side data format issues
				return { success = false, error = "Failed to process request data format" }
			end
			if requestPayload == nil then
				logError(self.Name, "Deserialized request data is nil")
				-- Don't record CB failure
				return { success = false, error = "Received invalid request data"}
			end

			-- 4. Decompress *request* if needed 
			-- Request no longer is compressed

			local dataToProcess = requestPayload -- Start with the deserialized data

			-- 5. Type checking for the *actual* request payload
			if self.RequestTypeDefinition then
				local typeCheckResult: TypeCheckerResult = TypeChecker:Validate(requestPayload, self.RequestTypeDefinition)
				if not typeCheckResult.success then
					logError(self.Name, ("Request type validation failed: %s"):format(typeCheckResult.error or "Unknown"))
					-- Don't record CB failure for client type errors
					return { success = false, error = "Request type validation failed: " .. (typeCheckResult.error or "Unknown error") }
				end
			end

			-- 6. Run middleware (Pass the validated request data)
			-- Middleware receives player and the actual request data
			local continueProcessing, processedData = self.ServerManager:InvokeMiddleware(self.Name, player, requestPayload)
			if not continueProcessing then
				if self.ServerManager.DebugEnabled then print(("[NetRay RequestServer] Middleware blocked request '%s'"):format(self.Name)) end
				-- Don't record CB failure for middleware block
				return { success = false, error = "Request blocked by middleware" }
			end
			-- Use middleware result if provided, otherwise original data
			local dataForHandler = if processedData ~= nil then processedData else requestPayload

			-- 7. Check Handler exists
			if not self.Handler then
				logError(self.Name, "No request handler registered.")
				-- This is a server config issue, potentially record CB failure? Or handle as internal error.
				if circuitBreaker then circuitBreaker:RecordFailure() end -- Treat missing handler as service failure
				return { success = false, error = "No request handler registered for " .. self.Name }
			end

			-- 8. Execute the user's Handler (protected by pcall)
			-- Handler receives player and the final data (potentially modified by middleware)
			local resultSuccess, resultOrError = pcall(self.Handler, player, dataForHandler)

			if not resultSuccess then
				-- Handler failed
				logError(self.Name, "Request handler errored:", resultOrError)
				if circuitBreaker then circuitBreaker:RecordFailure() end -- Record failure
				return { success = false, error = "Request handler error: " .. tostring(resultOrError) }
			end

			-- 9. Handler success path
			-- Record success only if the handler executed without error
			if circuitBreaker then circuitBreaker:RecordSuccess() end
			local resultData = resultOrError -- The actual result from the handler

			-- 10. Type checking for the *response* data returned by the handler
			if self.ResponseTypeDefinition then
				local typeCheckResult: TypeCheckerResult = TypeChecker:Validate(resultData, self.ResponseTypeDefinition)
				if not typeCheckResult.success then
					logError(self.Name, "Response type validation failed:", typeCheckResult.error)
					-- Treat response validation failure as a handler/server error? Yes.
					-- Should this record CB failure? Arguably yes, the service didn't produce valid output.
					if circuitBreaker then circuitBreaker:RecordFailure() end
					return { success = false, error = "Response type validation failed: " .. (typeCheckResult.error or "Unknown error") }
				end
			end

			-- 11. Optional: Compress the *actual result data* before wrapping
			local dataToSend = resultData
			local dataWasCompressed = false
			-- Only compress if compression is enabled *and* data is large enough *and* compression helps
			if self.UseCompression then
				local compressSuccess, compressedResult = pcall(function()
					return Compressor:Compress(dataToSend)
				end)
				if compressSuccess and compressedResult then
					-- Estimate sizes *after* successful compression
					local originalSize = Serializer.EstimateSize(dataToSend)
					local compressedSize = Serializer.EstimateSize(compressedResult)
					if compressedSize < originalSize and compressedSize > 0 then -- Ensure compression helped and is valid
						if self.ServerManager.DebugEnabled then print(("[NetRay RequestServer] Compressing response data for '%s' (%d -> %d bytes)"):format(self.Name, originalSize, compressedSize)) end
						dataToSend = compressedResult -- Use the compressed data
						dataWasCompressed = true
					end
				elseif not compressSuccess then
					logError(self.Name, "Failed to compress response data:", compressedResult)
					-- Continue with uncompressed data
				end
			end

			-- 12. Construct final wrapper payload for successful response
			local responsePayload: CommunicationPayload = {
				success = true,
				data = dataToSend,
				__compressed = dataWasCompressed -- Flag if 'data' field itself is compressed
			}

			return responsePayload -- Return the success wrapper

		end) -- End of overall pcall wrapping the main logic

		-- Determine the final payload to serialize based on pcall success
		local finalPayload: CommunicationPayload
		if not overallSuccess then
			-- overallSuccess is false, responseToSend contains the error object/message
			logError(self.Name, "CRITICAL Error during OnServerInvoke processing:", tostring(responseToSend))
			finalPayload = { success = false, error = "Internal server error during request handling." }
		else
			-- overallSuccess is true, responseToSend is the CommunicationPayload wrapper returned by the inner function
			finalPayload = responseToSend
		end

		-- Final Step: Serialize the determined payload and return the buffer
		local serializedBuffer = SerializeResponse(finalPayload)
		return serializedBuffer -- Return buffer or nil (if fallback serialization failed)
	end
end

-- Registers the function to handle incoming requests from clients
function RequestServer:OnRequest(callback: RequestHandler): RequestServerType
	if typeof(callback) ~= "function" then
		error("[NetRay RequestServer] OnRequest expects a function(player, data) as its argument", 2)
	end
	self.Handler = callback
	return self -- Return self for chaining
end

-- Method to make a request to a specific client (Server -> Client)
-- Use generic <T> for the expected type of the resolved data
function RequestServer:Request<T>(player: Player, data: any?): Promise<T>
	if not player or not player:IsA("Player") or not player:IsDescendantOf(Players) then
		-- Reject with a structured error
		return Promise.reject(Errors.new("TypeError", "Invalid player specified for S2C request", { eventName = self.Name })) :: Promise<T>
	end

	-- Create promise immediately, calculations done inside
	return Promise.new(function(resolve: (T) -> (), reject: (NetRayError) -> ())
		-- Variables needed across async boundaries
		local requestActive = true
		local timeoutCoroutine: thread | nil = nil -- Store the timeout thread

		-- Start timeout timer
		timeoutCoroutine = task.delay(self.Timeout, function()
			if requestActive then
				requestActive = false -- Mark as inactive
				reject(Errors.new("Timeout", ("S2C Request '%s' timed out after %d seconds"):format(self.Name, self.Timeout), { eventName = self.Name }))
			end
		end)

		-- Perform potentially yielding operations in a separate thread
		task.spawn(function()
			local payloadToSend: CommunicationPayload
			local serializedData: buffer | nil = nil

			-- Wrap data preparation and serialization in pcall
			local prepSuccess, prepResult = pcall(function()
				-- 1. Type checking for request data being sent *to* client
				if self.RequestTypeDefinition and data ~= nil then
					local typeCheckResult: TypeCheckerResult = TypeChecker.Validate(data, self.RequestTypeDefinition)
					if not typeCheckResult.success then
						-- Throw error to be caught by pcall
						error(Errors.new("Validation", "S2C Request type validation failed: " .. (typeCheckResult.error or "Unknown"), { eventName = self.Name }))
					end
				end

				-- 2. Prepare request data payload (Compress actual data if needed)
				local dataToSend = data -- Use original data (can be nil)
				local dataWasCompressed = false
				if self.UseCompression then
					-- Only compress if data exists and compression helps
					if dataToSend ~= nil then
						local compressSuccess, compressed = pcall(Compressor.Compress, dataToSend) -- Removed Compressor arg
						if compressSuccess and compressed then
							local originalSize = Serializer.EstimateSize(dataToSend)
							local compressedSize = Serializer.EstimateSize(compressed)
							if compressedSize < originalSize and compressedSize > 0 then
								if self.ServerManager.DebugEnabled then print(("[NetRay RequestServer] Compressing S2C request data for '%s' (%d -> %d bytes)"):format(self.Name, originalSize, compressedSize)) end
								dataToSend = compressed
								dataWasCompressed = true
							end
						elseif not compressSuccess then
							logError(self.Name, "S2C Request compression failed:", compressed)
							-- Continue with uncompressed data
						end
					end
				end

				-- Construct the wrapper payload to send to the client
				payloadToSend = {
					success = true, -- Indicate this is a valid request payload
					data = dataToSend, -- Potentially compressed data, or original data, or nil
					__compressed = dataWasCompressed
				}

				-- 3. Serialize the wrapper payload
				local serSuccess, serResult = pcall(Serializer.Serialize, payloadToSend)
				if not serSuccess then
					logError(self.Name, "Failed to serialize S2C request payload:", serResult)
					error(Errors.new("Serialization", "Failed to serialize S2C request", { eventName = self.Name }))
				end
				-- Assign serialized data if successful
				serializedData = serResult :: buffer?
				if serializedData == nil then
					error(Errors.new("Serialization", "S2C request payload serialized to nil", { eventName = self.Name }))
				end
			end) -- End of pcall for prep/serialization

			-- If prep/serialization failed, reject the promise
			if not prepSuccess then
				if requestActive then -- Check if still active before rejecting
					requestActive = false
					if timeoutCoroutine then task.cancel(timeoutCoroutine) end
					-- prepResult contains the error object thrown
					reject(prepResult :: NetRayError)
				end
				return -- Stop the task.spawn thread
			end

			-- Check activity again before invoking client (could have timed out during prep)
			if not requestActive then return end

			-- Check if serializedData is actually assigned (should be if prepSuccess is true)
			if serializedData == nil then
				if requestActive then
					requestActive = false
					if timeoutCoroutine then task.cancel(timeoutCoroutine) end
					reject(Errors.new("Internal", "S2C request internal error: serialized data is nil despite success", { eventName = self.Name }))
				end
				return
			end

			-- 4. Invoke Client (wrapped in pcall for network errors)
			local invokeSuccess, clientResultBuffer = pcall(self.RemoteFunction.InvokeClient, self.RemoteFunction, player, serializedData)

			if not requestActive then return end -- Check if timed out during InvokeClient

			if not invokeSuccess then
				requestActive = false
				if timeoutCoroutine then task.cancel(timeoutCoroutine) end
				reject(Errors.new("Network", "Failed to invoke client: " .. tostring(clientResultBuffer), { eventName = self.Name }))
				return
			end

			if clientResultBuffer == nil then
				requestActive = false
				if timeoutCoroutine then task.cancel(timeoutCoroutine) end
				reject(Errors.new("Network", "InvokeClient returned nil response", { eventName = self.Name }))
				return
			end

			-- 5. Deserialize the client's response wrapper (wrapped in pcall)
			local deserializeSuccess, deserializedPayload: CommunicationPayload = pcall(Serializer.Deserialize, clientResultBuffer)

			if not requestActive then return end -- Check if timed out during deserialization

			if not deserializeSuccess then
				requestActive = false
				if timeoutCoroutine then task.cancel(timeoutCoroutine) end
				logError(self.Name, "Failed to deserialize S2C response wrapper:", tostring(deserializedPayload))
				reject(Errors.new("Serialization", "Failed to deserialize client response: " .. tostring(deserializedPayload), { eventName = self.Name }))
				return
			end
			-- Check payload structure after successful deserialization
			if deserializedPayload == nil then
				requestActive = false
				if timeoutCoroutine then task.cancel(timeoutCoroutine) end
				reject(Errors.new("Serialization", "Client response wrapper deserialized to nil", { eventName = self.Name }))
				return
			end
			if typeof(deserializedPayload) ~= "table" or deserializedPayload.success == nil then
				requestActive = false
				if timeoutCoroutine then task.cancel(timeoutCoroutine) end
				reject(Errors.new("Serialization", "Invalid response wrapper structure received from client.", { eventName = self.Name }))
				return
			end

			-- 6. Check client-side success flag in the *wrapper*
			if not deserializedPayload.success then
				requestActive = false
				if timeoutCoroutine then task.cancel(timeoutCoroutine) end
				-- Client reported an error in its handler
				reject(Errors.new("Internal", "Client handler error: " .. tostring(deserializedPayload.error or "Unknown client error"), { eventName = self.Name }))
				return
			end

			-- If we reach here, the client successfully handled the request and sent back a success wrapper.
			-- Now process the 'data' field within the wrapper.
			local finalClientData = deserializedPayload.data
			local decompressError: NetRayError | nil = nil

			-- 7. Decompress the actual data payload *if flagged* by client
			if deserializedPayload.__compressed == true then
				if typeof(finalClientData) ~= "string" and typeof(finalClientData) ~= "buffer" then -- Check if data is suitable for decompression
					decompressError = Errors.new("Internal", "Client indicated compressed data, but payload is not string/buffer", { eventName = self.Name })
				else
					local decompressSuccess, decompressedResult = pcall(Compressor.Decompress, finalClientData) -- Removed Compressor arg
					if not decompressSuccess then
						decompressError = Errors.new("Internal", "Failed to decompress client response data: " .. tostring(decompressedResult), { eventName = self.Name })
					else
						finalClientData = decompressedResult -- Update with decompressed data
					end
				end
			end

			-- Check for decompression error after the block
			if decompressError then
				if requestActive then
					requestActive = false
					if timeoutCoroutine then task.cancel(timeoutCoroutine) end
					reject(decompressError)
				end
				return
			end

			-- Request is now fully complete
			requestActive = false
			if timeoutCoroutine then task.cancel(timeoutCoroutine) end -- Cancel timer definitively

			-- 8. Type checking for the final (potentially decompressed) response data
			if self.ResponseTypeDefinition then
				local typeCheckResult: TypeCheckerResult = TypeChecker.Validate(finalClientData, self.ResponseTypeDefinition)
				if not typeCheckResult.success then
					-- Reject if final data doesn't match expected response type
					reject(Errors.new("Validation", "S2C Response type validation failed: " .. (typeCheckResult.error or "Unknown"), { eventName = self.Name }))
					return
				end
			end

			-- 9. Resolve the promise with the final, validated data
			resolve(finalClientData :: T) -- Cast final data to expected generic type T

		end) -- End of task.spawn
	end) -- End of Promise.new
end

return RequestServer