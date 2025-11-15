--!optimize 2

--[[
    ServerEvent.lua
    Handles server-side event operations, with type validation and optimized networking
    Author: Asta (@TheYusufGamer)
]]

local Players = game:GetService("Players")

-- Type Imports
local ServerManagerModule = require(script.Parent.Parent.Server.ServerManager)
local TypeChecker = require(script.Parent.Parent.Shared.TypeChecker)
local DynamicSender = require(script.Parent.Parent.Shared.DynamicSender)
local Constants = require(script.Parent.Parent.Shared.Constants)

-- Assume TypeChecker exports its result type
type TypeCheckerResult = TypeChecker.TypeCheckerResult -- e.g., {success: boolean, error: string?}
-- Define Player type alias
type Player = Players.Player
-- Import ServerManager type and options type
type ServerManager = ServerManagerModule.ServerManager
type ServerEventOptions = ServerManagerModule.ServerEventOptions -- Import from ServerManager

export type ServerEventType = {
	-- Properties matching NetRayEvent (for compatibility)
	Name: string,
	Options: ServerEventOptions,
	RemoteEvent: RemoteEvent,
	TypeDefinition: any?,
	Priority: number,

	-- Server-Specific Implementation Details
	ServerManager: ServerManager,
	UseCompression: boolean,
	Batchable: boolean,

	-- Methods matching NetRayEvent (Server-side subset + OnEvent)
	-- Note: Using ServerEventType here for 'self' as it's the internal implementation type
	OnEvent: (self: ServerEventType, callback: (player: Player, data: any) -> ()) -> ServerEventType,
	FireClient: (self: ServerEventType, player: Player, data: any) -> (),
	FireAllClients: (self: ServerEventType, data: any) -> (),
	FireAllClientsExcept: (self: ServerEventType, excludedPlayer: Player, data: any) -> (),
	FireFilteredClients: (self: ServerEventType, filter: (player: Player) -> boolean, data: any) -> (),

	-- Internal Helper Methods
	SetupListeners: (self: ServerEventType) -> (),
}

-- Type for the handlers stored in ServerManager
type ServerEventHandler = (player: Player, data: any) -> ()


-- Define the ServerEvent module table
local ServerEvent = {}
ServerEvent.__index = ServerEvent

-- Constructor
function ServerEvent.new(eventName: string, options: ServerEventOptions?, serverManager: ServerManager): ServerEventType
	options = options or {}
	-- Use ServerEventType for self's type annotation here
	local self: ServerEventType = setmetatable({}, ServerEvent)

	self.Name = eventName
	self.Options = options
	self.ServerManager = serverManager -- No cast needed if serverManager param is already typed

	-- Register with the server manager and get event info
	local eventData = serverManager:RegisterEvent(eventName, self.Options)
	self.RemoteEvent = eventData.Remote :: RemoteEvent 
	
	-- Initialize the Handlers array in the ServerManager's storage if it doesn't exist
	if not eventData.Handlers then
		eventData.Handlers = {} :: {ServerEventHandler}
	end

	-- Determine compression need (internal detail)
	self.UseCompression = options.compression == true

	-- Store type definitions
	self.TypeDefinition = options.typeDefinition

	-- Store priority (Matches NetRayEvent)
	self.Priority = options.priority or Constants.PRIORITY.NORMAL or 2 -- Default to NORMAL

	-- Store batching preference (internal detail)
	self.Batchable = options.batchable or false -- Default to false

	-- Set up listeners *after* all properties are initialized
	self:SetupListeners()

	-- Return the created object. Cast ensures it matches the explicit return type.
	return self :: ServerEventType
end

-- Internal method to set up RemoteEvent listeners
function ServerEvent:SetupListeners()
	self.RemoteEvent.OnServerEvent:Connect(function(player: Player, encodedData: any)
		-- Rate Limit Check
		if not self.ServerManager:CheckRateLimit(player, self.Name) then
			warn(("[NetRay ServerEvent] Player %s (%d) rate limited for event %s"):format(player.Name, player.UserId, self.Name))
			return
		end

		local success, decodedData = pcall(function()
			return DynamicSender:DecodeReceivedData(encodedData)
		end)

		if not success then
			local err = decodedData -- pcall returns error message as second arg on failure
			warn(("[NetRay ServerEvent] Failed to decode data for event '%s' from player %s (%d): %s"):format(self.Name, player.Name, player.UserId, tostring(err)))
			self.ServerManager.Signals.Error:Fire("DecodeError", self.Name, player, err)
			return
		end

		local eventInfo = self.ServerManager.Events[self.Name]
		if not eventInfo or not eventInfo.Handlers then
			warn(("[NetRay ServerEvent] Received event '%s' but no handlers registered or event info missing."):format(self.Name))
			return
		end
		local handlers = eventInfo.Handlers :: {ServerEventHandler} -- Assert type

		-- Function to process a single event payload
		local function processSingleEvent(targetPlayer: Player, data: any): boolean -- Added return type annotation
			-- 1. Type Checking
			if self.TypeDefinition then
				local typeCheckResult: TypeCheckerResult = TypeChecker:Validate(data, self.TypeDefinition)
				if not typeCheckResult.success then
					warn(("[NetRay ServerEvent] Type validation failed for event '%s' from player %s (%d): %s"):format(
						self.Name, targetPlayer.Name, targetPlayer.UserId, typeCheckResult.error or "Unknown error"))
					self.ServerManager.Signals.Error:Fire("TypeValidationError", self.Name, targetPlayer, data, typeCheckResult.error)
					return false
				end
			end

			-- 2. Middleware
			local continueProcessing, processedData = self.ServerManager:InvokeMiddleware(self.Name, targetPlayer, data)
			if not continueProcessing then
				if self.ServerManager.DebugEnabled then
					print(("[NetRay ServerEvent] Middleware blocked event '%s' from player %s (%d)"):format(self.Name, targetPlayer.Name, targetPlayer.UserId))
				end
				return false
			end
			local finalData = if processedData ~= nil then processedData else data

			-- 3. Circuit Breaker Check
			local circuitBreaker = self.ServerManager.CircuitBreakers[self.Name]
			if circuitBreaker and not circuitBreaker:IsAllowed() then
				if self.ServerManager.DebugEnabled then
					print(("[NetRay ServerEvent] Circuit breaker tripped for event '%s', blocking request from %s (%d)."):format(self.Name, targetPlayer.Name, targetPlayer.UserId))
				end
				if typeof(circuitBreaker.Options.fallback) == "function" then
					-- Use task.spawn for safety if fallback can error
					task.spawn(circuitBreaker.Options.fallback, targetPlayer, finalData)
				end
				return false 
			end

			-- 4. Dispatch to Handlers
			if #handlers == 0 then
				if self.ServerManager.DebugEnabled then
					print(("[NetRay ServerEvent] Event '%s' received from player %s (%d), but no OnEvent handlers are attached."):format(self.Name, targetPlayer.Name, targetPlayer.UserId))
				end
			else
				self.ServerManager.Signals.EventFired:Fire(self.Name, targetPlayer, finalData)
				for _, handler in ipairs(handlers) do
					task.spawn(handler, targetPlayer, finalData)
				end
			end

			-- 5. Record Circuit Breaker Success (only if CB exists)
			if circuitBreaker then
				circuitBreaker:RecordSuccess()
			end
			return true -- Indicate successful processing
		end -- End of processSingleEvent function

		-- Check if we received an array of events from a batch
		if typeof(decodedData) == "table" and #decodedData > 0 and typeof(decodedData[1]) == "table" then
			if self.ServerManager.DebugEnabled then
				print(("[NetRay ServerEvent] Processing %d batched events for '%s' from player %s (%d)"):format(#decodedData, self.Name, player.Name, player.UserId))
			end

			local allSucceeded = true
			for _, eventData in ipairs(decodedData :: {any}) do
				local success = processSingleEvent(player, eventData) -- Process using the original player context
				if not success then
					allSucceeded = false
					-- If one fails, the CB state might change for subsequent ones.
					-- The failure is recorded within processSingleEvent if it wasn't due to an already open CB.
				end
			end
		else
			-- Process as a single event
			local success = processSingleEvent(player, decodedData)
			-- If the single processing failed *and* it wasn't because the CB was open, record failure.
			if not success then
				local circuitBreaker = self.ServerManager.CircuitBreakers[self.Name]
			end
		end
	end) 
end 

-- Method to register a handler for this event
function ServerEvent:OnEvent(callback: ServerEventHandler): ServerEventType
	if typeof(callback) ~= "function" then
		-- error stops execution, no need to return self after
		error("[NetRay ServerEvent] OnEvent expects a function(player, data) as its argument", 2)
	end

	local eventInfo = self.ServerManager.Events[self.Name]
	if not eventInfo then
		error("[NetRay ServerEvent] Cannot call OnEvent for '"..self.Name.."': Event not properly registered in ServerManager.", 2)
	end
	-- Ensure Handlers array exists (should be guaranteed by .new)
	eventInfo.Handlers = eventInfo.Handlers or {} :: {ServerEventHandler}

	table.insert(eventInfo.Handlers, callback)

	return self -- Return self for chaining
end

-- Method to fire the event to a specific client
function ServerEvent:FireClient(player: Player, data: any)
	if not data then
		self.RemoteEvent:FireClient(player)
	end
	
	if not player or not player:IsA("Player") or not player:IsDescendantOf(Players) then
		error(("[NetRay ServerEvent] FireClient for '%s' expects a valid Player argument, got %s"):format(self.Name, typeof(player)), 2)
		-- Return immediately after error
		return
	end

	-- 1. Type Checking
	if self.TypeDefinition then
		local typeCheckResult: TypeCheckerResult = TypeChecker:Validate(data, self.TypeDefinition)
		if not typeCheckResult.success then
			error(("[NetRay ServerEvent] Outgoing type validation failed for event '%s': %s"):format(
				self.Name, typeCheckResult.error or "Unknown error"), 2)
			return
		end
	end

	-- 2. Middleware (Outgoing)
	local continueProcessing, processedData = self.ServerManager:InvokeMiddleware(self.Name .. "_Outgoing", player, data)
	if not continueProcessing then
		if self.ServerManager.DebugEnabled then
			print(("[NetRay ServerEvent] Outgoing middleware blocked event '%s' to player %s (%d)"):format(self.Name, player.Name, player.UserId))
		end
		return
	end
	local finalData = if processedData ~= nil then processedData else data

	-- 3. Send using DynamicSender
	local dsOptions = {
		batchable = self.Batchable,
		forceComparison = self.Options.forceComparison
	}

	DynamicSender:Send(self.RemoteEvent, finalData, player, dsOptions)

	-- 4. Fire Signal
	self.ServerManager.Signals.EventFired:Fire(self.Name .. "_SentClient", player, finalData)
end

-- Method to fire the event to all connected clients
function ServerEvent:FireAllClients(data: any)	
	-- 1. Type Checking
	if self.TypeDefinition then
		local typeCheckResult: TypeCheckerResult = TypeChecker:Validate(data, self.TypeDefinition)
		if not typeCheckResult.success then
			error(("[NetRay ServerEvent] Outgoing type validation failed for event '%s' (FireAllClients): %s"):format(
				self.Name, typeCheckResult.error or "Unknown error"), 2)
			return
		end
	end
	
	if not data then
		self.RemoteEvent:FireAllClients(data)
		return
	end
	
	-- 2. Middleware (Outgoing)
	local continueProcessing, processedData = self.ServerManager:InvokeMiddleware(self.Name .. "_Outgoing", nil, data)
	if not continueProcessing then
		if self.ServerManager.DebugEnabled then
			print(("[NetRay ServerEvent] Outgoing middleware blocked event '%s' (FireAllClients)"):format(self.Name))
		end
		return
	end
	local finalData = if processedData ~= nil then processedData else data

	-- 3. Send using DynamicSender
	local allPlayers = Players:GetPlayers()
	if #allPlayers == 0 then return end
	
	local dsOptions = {
		batchable = self.Batchable,
		forceComparison = self.Options.forceComparison
	}

	
	DynamicSender:Send(self.RemoteEvent, finalData, nil,dsOptions)

	-- 4. Fire Signal
	self.ServerManager.Signals.EventFired:Fire(self.Name .. "_SentAll", nil, finalData)

	if self.ServerManager.DebugEnabled then
		print(("[NetRay ServerEvent] Event '%s' fired to %d clients (FireAllClients)"):format(
			self.Name, #allPlayers))
	end
end

-- Method to fire to all clients except one
function ServerEvent:FireAllClientsExcept(excludedPlayer: Player, data: any)
	if not excludedPlayer or not excludedPlayer:IsA("Player") then
		error(("[NetRay ServerEvent] FireAllClientsExcept for '%s' expects a valid Player argument, got %s"):format(self.Name, typeof(excludedPlayer)), 2)
		return
	end

	-- 1. Type Checking
	if self.TypeDefinition then
		local typeCheckResult: TypeCheckerResult = TypeChecker:Validate(data, self.TypeDefinition)
		if not typeCheckResult.success then
			error(("[NetRay ServerEvent] Outgoing type validation failed for event '%s' (FireAllClientsExcept): %s"):format(
				self.Name, typeCheckResult.error or "Unknown error"), 2)
			return
		end
	end
	
	-- 2. Filter Players
	local playersToSend = {}
	for _, player in ipairs(Players:GetPlayers()) do
		if player ~= excludedPlayer then
			table.insert(playersToSend, player)
		end
	end
	if #playersToSend == 0 then return end
	
	if not data then
		for _, plr in playersToSend do
			self.RemoteEvent:FireClient(plr)
		end
	end

	-- 3. Middleware (Outgoing)
	local continueProcessing, processedData = self.ServerManager:InvokeMiddleware(self.Name .. "_Outgoing", nil, data)
	if not continueProcessing then
		if self.ServerManager.DebugEnabled then
			print(("[NetRay ServerEvent] Outgoing middleware blocked event '%s' (FireAllClientsExcept)"):format(self.Name))
		end
		return
	end
	local finalData = if processedData ~= nil then processedData else data
	
	-- 4. Send using DynamicSender
	DynamicSender:SendToMany(self.RemoteEvent, finalData, playersToSend)
	local dsOptions = {
		batchable = self.Batchable,
		forceComparison = self.Options.forceComparison
	}

	-- 5. Fire Signal
	self.ServerManager.Signals.EventFired:Fire(self.Name .. "_SentExcept", excludedPlayer, finalData, dsOptions)

	if self.ServerManager.DebugEnabled then
		print(("[NetRay ServerEvent] Event '%s' fired to %d clients (excluding %s)"):format(
			self.Name, #playersToSend, excludedPlayer.Name))
	end
end

-- Method to fire to clients matching a filter function
function ServerEvent:FireFilteredClients(filter: (player: Player) -> boolean, data: any)
	if typeof(filter) ~= "function" then
		error(("[NetRay ServerEvent] FireFilteredClients for '%s' expects a filter function as the first argument"):format(self.Name), 2)
		return
	end

	-- 1. Type Checking
	if self.TypeDefinition then
		local typeCheckResult: TypeCheckerResult = TypeChecker:Validate(data, self.TypeDefinition)
		if not typeCheckResult.success then
			error(("[NetRay ServerEvent] Outgoing type validation failed for event '%s' (FireFilteredClients): %s"):format(
				self.Name, typeCheckResult.error or "Unknown error"), 2)
			return
		end
	end
	
	-- 2. Filter Players
	local playersToSend = {}
	-- Use pcall to safely execute the user-provided filter function
	local successFilter, filterResult = pcall(function()
		for _, player in ipairs(Players:GetPlayers()) do
			if filter(player) then
				table.insert(playersToSend, player)
			end
		end
	end)

	if not successFilter then
		-- filterResult contains the error message here
		warn(("[NetRay ServerEvent] Error executing filter function for event '%s': %s"):format(self.Name, tostring(filterResult)))
		self.ServerManager.Signals.Error:Fire("FilterFunctionError", self.Name, filterResult)
		return -- Don't proceed if filter failed
	end

	if #playersToSend == 0 then return end

	if not data then
		for _, plr in playersToSend do
			self.RemoteEvent:FireClient(plr)
		end
	end
	
	-- 3. Middleware (Outgoing)
	local continueProcessing, processedData = self.ServerManager:InvokeMiddleware(self.Name .. "_Outgoing", nil, data)
	if not continueProcessing then
		if self.ServerManager.DebugEnabled then
			print(("[NetRay ServerEvent] Outgoing middleware blocked event '%s' (FireFilteredClients)"):format(self.Name))
		end
		return
	end
	local finalData = if processedData ~= nil then processedData else data
	
	local dsOptions = {
		batchable = self.Batchable,
		forceComparison = self.Options.forceComparison
	}
	
	-- 4. Send using DynamicSender
	DynamicSender:SendToMany(self.RemoteEvent, finalData, playersToSend,dsOptions)

	-- 5. Fire Signal
	self.ServerManager.Signals.EventFired:Fire(self.Name .. "_SentFiltered", nil, finalData)

	if self.ServerManager.DebugEnabled then
		print(("[NetRay ServerEvent] Event '%s' fired to %d clients (filtered)"):format(
			self.Name, #playersToSend))
	end
end


return ServerEvent