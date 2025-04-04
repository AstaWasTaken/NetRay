--!strict
--!optimize 2
--!native

--[[
    RequestServer.lua
    Implements the server-side of the request/response pattern with promise support
    Updated with fixes for pcall usage, compressor calls, and clearer logic.
	Author: Asta (@TheYusufGamer)
]]

local Players = game:GetService("Players")

local Promise = require(script.Parent.Parent.ThirdParty.Promise)
local Serializer = require(script.Parent.Parent.Shared.Serializer)
local TypeChecker = require(script.Parent.Parent.Shared.TypeChecker)
local Compressor = require(script.Parent.Parent.Shared.Compressor)
local Errors = require(script.Parent.Parent.Shared.Errors)

local RequestServer = {}
RequestServer.__index = RequestServer

local function logError(eventName: string, message: string, ...)
	warn(("[NetRay RequestServer Error - %s] %s"):format(eventName, message), ...)
end

function RequestServer.new(eventName, options, serverManager)
	local self = setmetatable({}, RequestServer)

	self.Name = eventName
	self.Options = options or {}
	self.ServerManager = serverManager

	local remoteFunction = serverManager:CreateRemoteFunction(eventName)
	self.RemoteFunction = remoteFunction

	self.Handler = nil
	self.Timeout = options.timeout or 10
	self.UseCompression = options.compression == true
	self.RequestTypeDefinition = options.requestTypeDefinition
	self.ResponseTypeDefinition = options.responseTypeDefinition

	self:SetupRequestHandler()

	return self
end

function SerializeResponse(payload: any) : buffer?
	local serializeSuccess, serializedResult = pcall(Serializer.Serialize, payload)
	if not serializeSuccess then
		logError("SerializeResponse", "Failed to serialize payload:", serializedResult)
		-- Fallback serialization
		local fallbackSuccess, fallbackSerialized = pcall(Serializer.Serialize, {success=false, error="Server internal serialization error"})
		if fallbackSuccess then
			return fallbackSerialized :: buffer?
		else
			warn("[NetRay RequestServer CRITICAL] Failed even to serialize fallback error!")
			return nil
		end
	end
	return serializedResult :: buffer?
end


function RequestServer:SetupRequestHandler()
	self.RemoteFunction.OnServerInvoke = function(player, receivedData)

		local overallSuccess, responseToSend = pcall(function()

			-- 1. Rate limiting check
			if not self.ServerManager:CheckRateLimit(player, self.Name) then
				return { success = false, error = "Rate limit exceeded" }
			end

			-- 2. Circuit breaker check
			local circuitBreaker = self.ServerManager.CircuitBreakers[self.Name]
			if circuitBreaker and not circuitBreaker:IsAllowed() then
				if typeof(circuitBreaker.Options.fallback) == "function" then
					local fallbackSuccess, fallbackResult = pcall(circuitBreaker.Options.fallback, player, receivedData)
					if fallbackSuccess then
						return { success = true, data = fallbackResult, fromFallback = true }
					else
						logError(self.Name, "Circuit breaker fallback function errored:", fallbackResult)
						return { success = false, error = "Service fallback failed." }
					end
				else
					return { success = false, error = "Service unavailable (circuit open)" }
				end
			end

			-- 3. Deserialize incoming request data
			local deserializeSuccess, requestPayload = pcall(Serializer.Deserialize, receivedData)
			if not deserializeSuccess then
				logError(self.Name, "Failed to deserialize request data:", requestPayload)
				return { success = false, error = "Failed to process request data format" }
			end
			if requestPayload == nil then
				logError(self.Name, "Deserialized request data is nil")
				return { success = false, error = "Received invalid request data"}
			end

			-- 4. Decompress *request* if needed (check *after* deserializing payload)
			local dataToProcess = requestPayload
			if self.UseCompression and typeof(requestPayload) == "string" then
				local decompressSuccess, decompressed = pcall(Compressor.Decompress, Compressor, requestPayload :: string)
				if decompressSuccess then
					dataToProcess = decompressed
				else
					logError(self.Name, "Failed to decompress request payload string:", decompressed)
					return { success = false, error = "Failed to decompress request payload" }
				end
			end

			-- Now dataToProcess holds the actual intended request data (like the { cause_error=true } table)
			local finalRequestData = dataToProcess

			-- 5. Type checking for request
			if self.RequestTypeDefinition then
				local typeCheckResult = TypeChecker.Validate(finalRequestData, self.RequestTypeDefinition)
				if not typeCheckResult.success then
					logError(self.Name, ("Request type validation failed: %s"):format(typeCheckResult.error or "Unknown"))
					return { success = false, error = "Request type validation failed: " .. (typeCheckResult.error or "Unknown error") }
				end
			end

			-- 6. Run middleware
			-- Assuming InvokeMiddleware is correct and doesn't need pcall here
			local processedData = self.ServerManager:InvokeMiddleware(self.Name, player, finalRequestData)
			if processedData == false then
				return { success = false, error = "Request blocked by middleware" }
			end
			local dataForHandler = (processedData ~= nil) and processedData or finalRequestData

			-- 7. Check Handler exists
			if not self.Handler then
				logError(self.Name, "No request handler registered.")
				return { success = false, error = "No request handler registered for " .. self.Name }
			end

			-- 8. Execute the user's Handler
			local resultSuccess, resultOrError = pcall(self.Handler, player, dataForHandler)

			if not resultSuccess then
				logError(self.Name, "Request handler errored:", resultOrError)
				if circuitBreaker then circuitBreaker:RecordFailure() end
				return { success = false, error = "Request handler error: " .. tostring(resultOrError) }
			end

			-- 9. Handler success path
			if circuitBreaker then circuitBreaker:RecordSuccess() end
			local resultData = resultOrError -- The actual result

			-- 10. Type checking for response data
			if self.ResponseTypeDefinition then
				local typeCheckResult = TypeChecker.Validate(resultData, self.ResponseTypeDefinition)
				if not typeCheckResult.success then
					logError(self.Name, "Response type validation failed:", typeCheckResult.error)
					return { success = false, error = "Response type validation failed: " .. (typeCheckResult.error or "Unknown error") }
				end
			end

			-- 11. Optional: Compress the *actual result data* if large enough
			local dataToSend = resultData
			local dataWasCompressed = false
			if self.UseCompression and Serializer.EstimateSize(dataToSend) > 1000 then
				local compressSuccess, compressed = pcall(Compressor.Compress, Compressor, dataToSend)
				if compressSuccess and compressed and Serializer.EstimateSize(compressed) < Serializer.EstimateSize(dataToSend) then
					print("[NetRay Server] Compressing response data for", self.Name)
					dataToSend = compressed -- Use compressed data
					dataWasCompressed = true
				elseif not compressSuccess then
					logError(self.Name, "Failed to compress response data:", compressed)
					-- Continue with uncompressed
				end
			end

			-- 12. Construct final wrapper payload
			local responsePayload = {
				success = true,
				data = dataToSend,
				__compressed = dataWasCompressed -- Flag if data field is compressed
			}

			return responsePayload -- Return the wrapper table

		end) -- End of overall pcall

		local finalPayload
		if not overallSuccess then
			logError(self.Name, "CRITICAL Error during OnServerInvoke processing:", responseToSend)
			finalPayload = { success = false, error = "Internal server error during request handling." }
		else
			finalPayload = responseToSend -- This is the {success=..., data=...} wrapper
		end

		-- Final Step: Serialize the determined payload
		local serializedBuffer = SerializeResponse(finalPayload)
		return serializedBuffer
	end
end


function RequestServer:OnRequest(callback)
	if typeof(callback) ~= "function" then
		error("[NetRay] OnRequest expects a function as its argument")
	end
	self.Handler = callback
	return self
end

-- Method to make a request to a specific client (Server -> Client)
function RequestServer:Request(player, data)
	if not player or not player:IsA("Player") or not player:IsDescendantOf(Players) then
		return Promise.reject(Errors.TYPE_ERROR("Invalid player specified for S2C request"))
	end

	-- 1. Type checking for request data
	if self.RequestTypeDefinition and data ~= nil then
		local typeCheckResult = TypeChecker.Validate(data, self.RequestTypeDefinition)
		if not typeCheckResult.success then
			return Promise.reject(Errors.VALIDATION("S2C Request type validation failed: " .. (typeCheckResult.error or "Unknown")))
		end
	end

	-- 2. Prepare request data payload (Compress actual data if needed)
	local dataToSend = data or {}
	local dataWasCompressed = false
	if self.UseCompression and Serializer.EstimateSize(dataToSend) > 1000 then
		local compressSuccess, compressed = pcall(Compressor.Compress, Compressor, dataToSend)
		if compressSuccess and compressed and Serializer.EstimateSize(compressed) < Serializer.EstimateSize(dataToSend) then
			dataToSend = compressed
			dataWasCompressed = true
		elseif not compressSuccess then
			logError(self.Name, "S2C Request compression failed:", compressed)
		end
	end

	local payloadToSend = {
		success = true, -- Indicate this is a request *payload*, not an error
		data = dataToSend,
		__compressed = dataWasCompressed
	}


	-- 3. Serialize the payload
	local serializedData
	local serializeSuccess, serResult = pcall(Serializer.Serialize, payloadToSend)
	if not serializeSuccess then
		logError(self.Name, "Failed to serialize S2C request payload:", serResult)
		return Promise.reject(Errors.SERIALIZATION("Failed to serialize S2C request"))
	end
	serializedData = serResult

	-- Create a promise for the request
	return Promise.new(function(resolve, reject)
		local requestActive = true
		local timeoutCoroutine

		timeoutCoroutine = task.delay(self.Timeout, function()
			if requestActive then
				requestActive = false
				reject(Errors.TIMEOUT("S2C Request timed out after " .. self.Timeout .. " seconds"))
			end
		end)

		task.spawn(function()
			-- 4. Invoke Client
			local invokeSuccess, clientResultBuffer = pcall(self.RemoteFunction.InvokeClient, self.RemoteFunction, player, serializedData)

			if not requestActive then return end

			if not invokeSuccess then
				requestActive = false
				task.cancel(timeoutCoroutine)
				return reject(Errors.NETWORK("Failed to invoke client: " .. tostring(clientResultBuffer)))
			end

			if clientResultBuffer == nil then
				requestActive = false
				task.cancel(timeoutCoroutine)
				return reject(Errors.NETWORK("InvokeClient returned nil response"))
			end

			-- 5. Deserialize the client's response wrapper
			local deserializeSuccess, deserializedPayload = pcall(Serializer.Deserialize, clientResultBuffer)

			if not requestActive then return end

			if not deserializeSuccess then
				requestActive = false
				task.cancel(timeoutCoroutine)
				logError(self.Name, "Failed to deserialize S2C response wrapper:", deserializedPayload)
				return reject(Errors.SERIALIZATION("Failed to deserialize client response: " .. tostring(deserializedPayload)))
			end
			if deserializedPayload == nil then
				requestActive = false
				task.cancel(timeoutCoroutine)
				return reject(Errors.SERIALIZATION("Client response wrapper deserialized to nil"))
			end
			if typeof(deserializedPayload) ~= "table" or deserializedPayload.success == nil then
				requestActive = false
				task.cancel(timeoutCoroutine)
				return reject(Errors.SERIALIZATION("Invalid response wrapper structure received from client."))
			end


			-- 6. Check client-side success flag in wrapper
			if not deserializedPayload.success then
				requestActive = false
				task.cancel(timeoutCoroutine)
				return reject(Errors.INTERNAL("Client handler error: " .. tostring(deserializedPayload.error or "Unknown client error")))
			end

			-- 7. Decompress the actual data payload *if flagged* by client
			local finalClientData = deserializedPayload.data
			if deserializedPayload.__compressed == true then -- Check flag from client wrapper
				if typeof(finalClientData) ~= "string" then -- Assuming compression returns string/binary
					requestActive = false
					task.cancel(timeoutCoroutine)
					return reject(Errors.INTERNAL("Client indicated compressed data, but payload is not string/binary"))
				end

				local decompressSuccess, decompressedData = pcall(Compressor.Decompress, Compressor, finalClientData)
				if not decompressSuccess then
					requestActive = false
					task.cancel(timeoutCoroutine)
					return reject(Errors.INTERNAL("Failed to decompress client response data: " .. tostring(decompressedData)))
				end
				finalClientData = decompressedData
			end

			-- If we get here, client handled request successfully, response received and processed
			requestActive = false
			task.cancel(timeoutCoroutine)

			-- 8. Type checking for the final (potentially decompressed) response data
			if self.ResponseTypeDefinition then
				local typeCheckResult = TypeChecker.Validate(finalClientData, self.ResponseTypeDefinition)
				if not typeCheckResult.success then
					return reject(Errors.VALIDATION("S2C Response type validation failed: " .. (typeCheckResult.error or "Unknown")))
				end
			end

			-- 9. Resolve with the actual data
			resolve(finalClientData)
		end)
	end)
end

return RequestServer