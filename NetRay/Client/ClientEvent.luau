--!strict
--!optimize 2
--!native

--[[
    ClientEvent.lua
    Handles client-side event operations, with type validation and optimized networking
    Author: Asta (@TheYusufGamer)
]]

local Serializer = require(script.Parent.Parent.Shared.Serializer)
local TypeChecker = require(script.Parent.Parent.Shared.TypeChecker)
local Compressor = require(script.Parent.Parent.Shared.Compressor)
local DynamicSender = require(script.Parent.Parent.Shared.DynamicSender)

local ClientEvent = {}
ClientEvent.__index = ClientEvent

function ClientEvent.new(eventName, options, clientManager)
	local self = setmetatable({}, ClientEvent)

	self.Name = eventName
	self.Options = options or {} 
	self.ClientManager = clientManager

	-- Get the remote event from ClientManager
	local eventData = clientManager:RegisterEvent(eventName, self.Options)
	if not eventData then
		error("[NetRay] Failed to create ClientEvent: " .. eventName)
		return nil
	end

	self.RemoteEvent = eventData.Remote

	-- Set up listeners
	self:SetupListeners()

	-- Store type definitions if provided
	self.TypeDefinition = options.typeDefinition

	-- Store priority
	self.Priority = options.priority or 2 -- Default to NORMAL priority

	return self
end

function ClientEvent:SetupListeners()
	-- Listen for server events
	self.RemoteEvent.OnClientEvent:Connect(function(encodedData)
		local success, data = pcall(function()
			-- Use DynamicSender to decode the raw data
			return DynamicSender:DecodeReceivedData(encodedData)
		end)

		if not success then
			warn("[NetRay] Failed to process data from server: " .. tostring(data))
			return
		end

		-- Debug: Print received data
		if DynamicSender.Config.DebugMode then
			local dataDesc
			if typeof(data) == "table" then
				-- Simple table summary for debugging
				local count = 0
				for _ in pairs(data) do count += 1 end
				dataDesc = "[Table with " .. count .. " items]"

				-- Try to add more details if it's an array-like table
				if #data > 0 then
					dataDesc = "[Array with " .. #data .. " items]"
				end
			else
				dataDesc = tostring(data)
			end
			print("[NetRay] Received data:", self.Name, dataDesc)
		end

		-- Type checking if enabled
		if self.TypeDefinition then
			local typeCheckResult = TypeChecker:Validate(data, self.TypeDefinition)
			if not typeCheckResult.success then
				warn(string.format("[NetRay] Type validation failed for event %s: %s", self.Name, typeCheckResult.error or "Unknown error"))
				return
			end
		end

		-- Run middleware
		local processedData = self.ClientManager:InvokeMiddleware(self.Name, data)
		if processedData == false then
			-- Middleware blocked this event
			return
		end

		-- Circuit breaker check
		local circuitBreaker = self.ClientManager.CircuitBreakers[self.Name]
		if circuitBreaker and not circuitBreaker:IsAllowed() then
			if typeof(circuitBreaker.Options.fallback) == "function" then
				circuitBreaker.Options.fallback(processedData or data)
			end
			return
		end

		-- Dispatch to any registered handlers
		local eventInfo = self.ClientManager.Events[self.Name]
		if eventInfo and eventInfo.Handlers then
			-- Check if we received an array of events from a batch
			if typeof(data) == "table" and #data > 0 then
				-- This looks like an array of events from a batch, process each one individually
				if DynamicSender.Config.DebugMode then
					print("[NetRay] Processing", #data, "batched events for", self.Name)
				end

				for _, eventData in ipairs(data) do
					-- Run individual type checking for each event in the batch
					if self.TypeDefinition then
						local typeCheckResult = TypeChecker:Validate(eventData, self.TypeDefinition)
						if not typeCheckResult.success then
							warn(string.format("[NetRay] Type validation failed for batched event %s: %s", self.Name, typeCheckResult.error or "Unknown error"))
							continue -- Skip this event but process others
						end
					end

					-- Run middleware for each individual event
					local processedEventData = self.ClientManager:InvokeMiddleware(self.Name, eventData)
					if processedEventData == false then
						-- Middleware blocked this specific event
						continue
					end

					-- Dispatch to handlers
					for _, handler in ipairs(eventInfo.Handlers) do
						self.ClientManager:EnqueueMessage(
							self.Priority,
							handler,
							processedEventData or eventData
						)
					end
				end
			else
				-- Standard single event handling
				for _, handler in ipairs(eventInfo.Handlers) do
					self.ClientManager:EnqueueMessage(
						self.Priority,
						handler,
						processedData or data
					)
				end
			end
		end
	end)
end

function ClientEvent:OnEvent(callback)
	if typeof(callback) ~= "function" then
		error("[NetRay] OnEvent expects a function as its argument")
		return self
	end

	-- Add to the event handlers
	local eventInfo = self.ClientManager.Events[self.Name]
	if not eventInfo then
		warn("[NetRay] Event not registered: " .. self.Name)
		return self
	end

	table.insert(eventInfo.Handlers, callback)

	return self
end

function ClientEvent:FireServer(data)
	-- Check throttling
	if not self.ClientManager:CheckOutgoingThrottle() then
		warn("[NetRay] Request throttled: too many outgoing requests")
		return
	end

	-- Type checking if enabled
	if self.TypeDefinition then
		local typeCheckResult = TypeChecker:Validate(data, self.TypeDefinition)
		if not typeCheckResult.success then
			error(string.format("[NetRay] Type validation failed for event %s: %s", self.Name, typeCheckResult.error or "Unknown error"))
			return
		end
	end

	-- Run middleware
	local processedData = self.ClientManager:InvokeMiddleware(self.Name, data)
	if processedData == false then
		-- Middleware blocked this event
		return
	end

	-- Circuit breaker check
	local circuitBreaker = self.ClientManager.CircuitBreakers[self.Name]
	if circuitBreaker and not circuitBreaker:IsAllowed() then
		if typeof(circuitBreaker.Options.fallback) == "function" then
			circuitBreaker.Options.fallback(data)
		end
		return
	end

	-- Let DynamicSender handle the optimization, serialization, and compression
	local method = DynamicSender:Send(self.RemoteEvent, processedData or data)

	-- Log event dispatch if debugging is enabled
	if self.ClientManager.DebugEnabled then
		print(string.format("[NetRay] Event %s fired with method %s", self.Name, method or "DEFAULT"))
	end
end

return ClientEvent
