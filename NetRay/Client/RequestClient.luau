--!strict
--!optimize 2
--!native

--[[
    RequestClient.lua
    Implements the client-side of the request/response pattern with promise support
    Updated with fixes for pcall, compressor calls, timeout, deserialization.
	Author: Asta (@TheYusufGamer)
]]

local Promise = require(script.Parent.Parent.ThirdParty.Promise)
local Serializer = require(script.Parent.Parent.Shared.Serializer)
local TypeChecker = require(script.Parent.Parent.Shared.TypeChecker)
local Compressor = require(script.Parent.Parent.Shared.Compressor)
local Errors = require(script.Parent.Parent.Shared.Errors)

local RequestClient = {}
RequestClient.__index = RequestClient

local function logError(eventName: string, message: string, ...)
	warn(("[NetRay RequestClient Error - %s] %s"):format(eventName, message), ...)
end

function RequestClient.new(eventName, options, clientManager)
	local self = setmetatable({}, RequestClient)

	self.Name = eventName
	self.Options = options or {}
	self.ClientManager = clientManager

	self.RemoteFunction = clientManager:GetRemoteFunction(eventName)
	if not self.RemoteFunction then
		error("[NetRay] Failed to create RequestClient: RemoteFunction not found for " .. eventName)
	end

	self.Handler = nil
	self.Timeout = options.timeout or 10
	self.UseCompression = options.compression == true
	self.RequestTypeDefinition = options.requestTypeDefinition
	self.ResponseTypeDefinition = options.responseTypeDefinition

	self:SetupResponseHandler()

	return self
end

function SerializeResponse(payload: any) : buffer?
	local serializeSuccess, serializedResult = pcall(Serializer.Serialize, payload)
	if not serializeSuccess then
		logError("SerializeResponse", "Failed to serialize S2C response payload:", serializedResult)
		local fallbackSuccess, fallbackSerialized = pcall(Serializer.Serialize, {success=false, error="Client internal serialization error"})
		if fallbackSuccess then
			return fallbackSerialized :: buffer?
		else
			warn("[NetRay RequestClient CRITICAL] Failed even to serialize S2C fallback error!")
			return nil
		end
	end
	return serializedResult :: buffer?
end

function RequestClient:SetupResponseHandler()
	if not self.RemoteFunction then
		warn("[NetRay] Cannot setup response handler for", self.Name, " - RemoteFunction is nil")
		return
	end

	self.RemoteFunction.OnClientInvoke = function(receivedData) -- This is the payload from server

		local overallSuccess, responseToSend = pcall(function()

			-- 1. Check throttling
			if not self.ClientManager:CheckOutgoingThrottle() then
				return { success = false, error = "Request throttled" }
			end

			-- 2. Circuit breaker check
			local circuitBreaker = self.ClientManager.CircuitBreakers[self.Name]
			if circuitBreaker and not circuitBreaker:IsAllowed() then
				if typeof(circuitBreaker.Options.fallback) == "function" then
					local fallbackSuccess, fallbackResult = pcall(circuitBreaker.Options.fallback, receivedData)
					if fallbackSuccess then
						return { success = true, data = fallbackResult, fromFallback = true }
					else
						logError(self.Name, "Client circuit breaker fallback function errored:", fallbackResult)
						return { success = false, error = "Service fallback failed." }
					end
				else
					return { success = false, error = "Service unavailable (circuit open)" }
				end
			end

			-- 3. Deserialize incoming request wrapper payload
			local deserializeSuccess, requestPayloadWrapper = pcall(Serializer.Deserialize, receivedData)
			if not deserializeSuccess then
				logError(self.Name, "Failed to deserialize S2C request wrapper:", requestPayloadWrapper)
				return { success = false, error = "Failed to process S2C request data format" }
			end
			if requestPayloadWrapper == nil then
				logError(self.Name, "Deserialized S2C request wrapper is nil")
				return { success = false, error = "Received invalid S2C request wrapper" }
			end
			if typeof(requestPayloadWrapper) ~= "table" or requestPayloadWrapper.success == nil then
				logError(self.Name, "Invalid S2C request wrapper structure")
				return { success = false, error = "Invalid S2C request wrapper structure received" }
			end
			if not requestPayloadWrapper.success then -- Check if server sent an initial error
				logError(self.Name, "Received error payload from server:", requestPayloadWrapper.error)
				return { success = false, error = "Server indicated error in request: " .. tostring(requestPayloadWrapper.error)}
			end


			-- 4. Decompress the actual *data* if flagged by server
			local finalRequestData = requestPayloadWrapper.data
			if requestPayloadWrapper.__compressed == true then
				if typeof(finalRequestData) ~= "string" then
					logError(self.Name, "Server flagged compressed S2C data, but payload isn't string/binary.")
					return { success = false, error = "Inconsistent compression flag/payload type"}
				end

				local decompressSuccess, decompressedData = pcall(Compressor.Decompress, Compressor, finalRequestData)
				if not decompressSuccess then
					logError(self.Name, "Failed to decompress S2C request data:", decompressedData)
					return { success = false, error = "Failed to decompress S2C request data" }
				end
				finalRequestData = decompressedData
			end

			-- 5. Type checking for the final request data
			if self.RequestTypeDefinition then
				local typeCheckResult = TypeChecker.Validate(finalRequestData, self.RequestTypeDefinition)
				if not typeCheckResult.success then
					logError(self.Name, "S2C Request type validation failed:", typeCheckResult.error)
					return { success = false, error = "S2C Request type validation failed: " .. (typeCheckResult.error or "Unknown error") }
				end
			end

			-- 6. Run client middleware
			local processedData = self.ClientManager:InvokeMiddleware(self.Name, finalRequestData) -- Player is nil
			if processedData == false then
				return { success = false, error = "S2C Request blocked by client middleware" }
			end
			local dataForHandler = (processedData ~= nil) and processedData or finalRequestData


			-- 7. Check Handler exists
			if not self.Handler then
				logError(self.Name, "No handler registered for S2C request.")
				return { success = false, error = "No S2C request handler registered for " .. self.Name }
			end

			-- 8. Execute the user's Handler
			local resultSuccess, resultOrError = pcall(self.Handler, dataForHandler)

			if not resultSuccess then
				logError(self.Name, "S2C request handler errored:", resultOrError)
				if circuitBreaker then circuitBreaker:RecordFailure() end
				return { success = false, error = "S2C Request handler error: " .. tostring(resultOrError) }
			end

			-- 9. Handler success path
			if circuitBreaker then circuitBreaker:RecordSuccess() end
			local resultData = resultOrError

			-- 10. Type checking for the response data
			if self.ResponseTypeDefinition then
				local typeCheckResult = TypeChecker.Validate(resultData, self.ResponseTypeDefinition)
				if not typeCheckResult.success then
					logError(self.Name, "S2C Response type validation failed:", typeCheckResult.error)
					return { success = false, error = "S2C Response type validation failed: " .. (typeCheckResult.error or "Unknown error") }
				end
			end

			-- 11. Optional: Compress the response *data* if large
			local dataToSend = resultData
			local dataWasCompressed = false
			if self.UseCompression and Serializer.EstimateSize(dataToSend) > 1000 then
				local compressSuccess, compressed = pcall(Compressor.Compress, Compressor, dataToSend)
				if compressSuccess and compressed and Serializer.EstimateSize(compressed) < Serializer.EstimateSize(dataToSend) then
					print("[NetRay Client] Compressing S2C response data for", self.Name)
					dataToSend = compressed
					dataWasCompressed = true
				elseif not compressSuccess then
					logError(self.Name, "Failed to compress S2C response data:", compressed)
				end
			end

			-- 12. Prepare successful response wrapper payload
			local responsePayload = {
				success = true,
				data = dataToSend,
				__compressed = dataWasCompressed -- Flag if data is compressed
			}

			return responsePayload -- Return the wrapper table

		end) -- End of overall pcall

		local finalPayload
		if not overallSuccess then
			logError(self.Name, "CRITICAL Error during OnClientInvoke processing:", responseToSend)
			finalPayload = { success = false, error = "Internal client error during S2C request handling." }
		else
			finalPayload = responseToSend
		end

		-- Final Step: Serialize the determined payload
		local serializedBuffer = SerializeResponse(finalPayload)
		return serializedBuffer
	end
end


function RequestClient:OnRequest(callback)
	if typeof(callback) ~= "function" then
		error("[NetRay] OnRequest expects a function as its argument")
	end
	self.Handler = callback
	return self
end

-- Method to make a request to the server (Client -> Server)
function RequestClient:Request(data)
	-- 1. Check throttling
	if not self.ClientManager:CheckOutgoingThrottle() then
		return Promise.reject(Errors.RATE_LIMIT("Request throttled: too many outgoing requests"))
	end

	-- 2. Circuit breaker check
	local circuitBreaker = self.ClientManager.CircuitBreakers[self.Name]
	if circuitBreaker and not circuitBreaker:IsAllowed() then
		if typeof(circuitBreaker.Options.fallback) == "function" then
			return Promise.new(function(resolve, reject)
				-- Fallback is simple func
				local fbSuccess, fbResult = pcall(circuitBreaker.Options.fallback, data)
				if fbSuccess then resolve(fbResult)
				else reject(Errors.CIRCUIT_OPEN("Circuit fallback failed: " .. tostring(fbResult))) end
			end)
		else
			return Promise.reject(Errors.CIRCUIT_OPEN("Service unavailable (circuit open)"))
		end
	end

	-- 3. Type checking for request
	if self.RequestTypeDefinition and data ~= nil then
		local typeCheckResult = TypeChecker.Validate(data, self.RequestTypeDefinition)
		if not typeCheckResult.success then
			return Promise.reject(Errors.VALIDATION("C2S Request type validation failed: " .. (typeCheckResult.error or "Unknown")))
		end
	end

	-- 4. Run client middleware
	local processedData = self.ClientManager:InvokeMiddleware(self.Name, data) -- Player nil
	if processedData == false then
		return Promise.reject(Errors.MIDDLEWARE("Request blocked by client middleware"))
	end
	local dataToSend = (processedData ~= nil) and processedData or data or {}

	-- 5. Prepare request data payload (Compress actual data if needed)
	local payloadToSend = dataToSend
	local dataWasCompressed = false
	if self.UseCompression and Serializer.EstimateSize(payloadToSend) > 1000 then
		local compressSuccess, compressed = pcall(Compressor.Compress, Compressor, payloadToSend)
		if compressSuccess and compressed and Serializer.EstimateSize(compressed) < Serializer.EstimateSize(payloadToSend) then
			print("[NetRay Client] Compressing C2S request data for", self.Name)
			payloadToSend = compressed
			dataWasCompressed = true
		elseif not compressSuccess then
			logError(self.Name, "C2S Request compression failed:", compressed)
		end
	end

	-- 6. Serialize the payload
	local serializedData
	local serializeSuccess, serResult = pcall(Serializer.Serialize, payloadToSend)
	if not serializeSuccess then
		logError(self.Name, "Failed to serialize C2S request data:", serResult)
		return Promise.reject(Errors.SERIALIZATION("Failed to serialize C2S request"))
	end
	serializedData = serResult

	-- 7. Create the promise and handle the request
	return Promise.new(function(resolve, reject)
		local timedOut = false
		local requestActive = true
		local timeoutCoroutine

		-- Set up timeout
		timeoutCoroutine = task.delay(self.Timeout, function()
			if requestActive then
				timedOut = true
				requestActive = false
				if circuitBreaker then circuitBreaker:RecordFailure() end
				reject(Errors.TIMEOUT("Request timed out after " .. self.Timeout .. " seconds"))
			end
		end)

		-- Spawn the network call
		task.spawn(function()
			if not self.RemoteFunction then
				if requestActive then
					requestActive = false; task.cancel(timeoutCoroutine)
					reject(Errors.INTERNAL("RemoteFunction is nil for " .. self.Name))
				end
				return
			end

			-- InvokeServer is method, needs self
			local invokeSuccess, serverResultBuffer = pcall(self.RemoteFunction.InvokeServer, self.RemoteFunction, serializedData)

			if not requestActive then return end

			if not invokeSuccess then
				requestActive = false
				task.cancel(timeoutCoroutine)
				if circuitBreaker then circuitBreaker:RecordFailure() end
				reject(Errors.NETWORK("Failed to invoke server: " .. tostring(serverResultBuffer)))
				return
			end

			if serverResultBuffer == nil then
				requestActive = false
				task.cancel(timeoutCoroutine)
				if circuitBreaker then circuitBreaker:RecordFailure() end
				return reject(Errors.NETWORK("Server returned nil response buffer"))
			end

			-- 8. Deserialize the server's response wrapper
			local deserializeSuccess, deserializedPayload = pcall(Serializer.Deserialize, serverResultBuffer)

			if not requestActive then return end

			if not deserializeSuccess then
				requestActive = false; task.cancel(timeoutCoroutine)
				if circuitBreaker then circuitBreaker:RecordFailure() end
				reject(Errors.SERIALIZATION("Failed to deserialize server response: " .. tostring(deserializedPayload)))
				return
			end

			if deserializedPayload == nil then
				requestActive = false; task.cancel(timeoutCoroutine)
				if circuitBreaker then circuitBreaker:RecordFailure() end
				reject(Errors.SERIALIZATION("Server response wrapper deserialized to nil"))
				return
			end
			if typeof(deserializedPayload) ~= "table" or deserializedPayload.success == nil then
				requestActive = false; task.cancel(timeoutCoroutine)
				if circuitBreaker then circuitBreaker:RecordFailure() end
				return reject(Errors.SERIALIZATION("Invalid response wrapper structure received from server."))
			end


			-- 9. Check server success flag
			if not deserializedPayload.success then
				requestActive = false; task.cancel(timeoutCoroutine)
				if circuitBreaker then circuitBreaker:RecordFailure() end
				reject(Errors.INTERNAL("Server Error: " .. tostring(deserializedPayload.error or "Unknown server error")))
				return
			end

			-- 10. Decompress the *data* payload if flagged by server
			local finalServerData = deserializedPayload.data
			if deserializedPayload.__compressed == true then
				if typeof(finalServerData) ~= "string" then
					requestActive = false; task.cancel(timeoutCoroutine)
					if circuitBreaker then circuitBreaker:RecordFailure() end
					return reject(Errors.INTERNAL("Server indicated compressed data, but payload is not string/binary"))
				end

				local decompressSuccess, decompressedData = pcall(Compressor.Decompress, Compressor, finalServerData)
				if not decompressSuccess then
					requestActive = false; task.cancel(timeoutCoroutine)
					if circuitBreaker then circuitBreaker:RecordFailure() end
					return reject(Errors.INTERNAL("Failed to decompress server response data: " .. tostring(decompressedData)))
				end
				finalServerData = decompressedData
			end

			-- Success path - cancel timeout, check response type, resolve
			requestActive = false
			task.cancel(timeoutCoroutine)

			-- 11. Type checking for the final response data
			if self.ResponseTypeDefinition then
				local typeCheckResult = TypeChecker.Validate(finalServerData, self.ResponseTypeDefinition)
				if not typeCheckResult.success then
					if circuitBreaker then circuitBreaker:RecordFailure() end
					reject(Errors.VALIDATION("Response type validation failed: " .. (typeCheckResult.error or "Unknown")))
					return
				end
			end

			-- 12. Record success & Resolve
			if circuitBreaker then circuitBreaker:RecordSuccess() end
			resolve(finalServerData) -- Resolve with the actual, processed data

		end) -- End of task.spawn
	end) -- End of Promise.new
end

return RequestClient