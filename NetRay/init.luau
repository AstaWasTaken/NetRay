--!optimize 2

--[[
    NetRay - High Performance Roblox Networking Library (v1.1.5)

    Author: Asta (@TheYusufGamer)
    Created: 2025-03-22
]]

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local PlayersService = game:GetService("Players")

--==============================================================================
-- Type Imports (Shared & Dependencies)
--==============================================================================

-- Third Party
local SignalPlusModule = require(script.ThirdParty.SignalPlus)
local PromiseModule = require(script.ThirdParty.Promise)
type SignalPlusFactory = () -> SignalPlus -- Type for the factory function itself
type SignalPlus = SignalPlusModule.SignalPlus -- Type for the instance returned
type Promise<T> = PromiseModule.Promise<T> -- Assuming Promise exports generic type

-- Shared Modules (Assume these export their Module types)
local UtilitiesModule = require(script.Shared.Utilities)
local ErrorsModule = require(script.Shared.Errors)
local SerializerModule = require(script.Shared.Serializer)
local TypeCheckerModule = require(script.Shared.TypeChecker)
local MiddlewareModule = require(script.Shared.Middleware)
local CircuitBreakerModule = require(script.Shared.CircuitBreaker)
type UtilitiesType = UtilitiesModule.UtilitiesModule
type ErrorsType = ErrorsModule.ErrorsModule
type SerializerType = SerializerModule.NetRaySerializerModule
type TypeCheckerType = TypeCheckerModule.TypeCheckerModule
type Middleware = MiddlewareModule.Middleware
type CircuitBreaker = CircuitBreakerModule.CircuitBreaker

--==============================================================================
-- Core Type Definitions (Needed Globally)
--==============================================================================

type Player = PlayersService.Player

-- Define Unified Event Type for API consistency
export type NetRayEvent = {
	Name: string,
	Options: {[string]: any}?,
	RemoteEvent: RemoteEvent,
	TypeDefinition: any?,
	Priority: number,
	OnEvent: (self: NetRayEvent, callback: ((player: Player, data: any) -> ()) | ((data: any) -> ())) -> NetRayEvent,
	FireServer: ((self: NetRayEvent, data: any) -> ())?,
	FireClient: ((self: NetRayEvent, player: Player, data: any) -> ())?,
	FireAllClients: ((self: NetRayEvent, data: any) -> ())?,
	FireAllClientsExcept: ((self: NetRayEvent, excludedPlayer: Player, data: any) -> ())?,
	FireFilteredClients: ((self: NetRayEvent, filter: (player: Player) -> boolean, data: any) -> ())?,
}

-- Define Debug structure type
type DebugType = {
	GlobalEvent: SignalPlus,
	Error: SignalPlus,
	NetworkTraffic: SignalPlus,
	EnableMonitoring: (options: {enabled: boolean}?) -> boolean,
}

-- Base type only includes shared *data* properties
type NetRayBaseModuleData = {
	Priority: {[string]: number},
	Version: string,
	Debug: DebugType,
	Utils: UtilitiesType,
	Errors: ErrorsType,
	Serializer: SerializerType,
	TypeChecker: TypeCheckerType,
}


--==============================================================================
-- Module Implementation Setup
--==============================================================================

local NetRay: any = {} -- Start as 'any', will be cast to specific type at the end
NetRay.__index = NetRay

local SignalPlusFactory: SignalPlusFactory = SignalPlusModule

-- Assign shared data properties
NetRay.Priority = {
	CRITICAL = 0,
	HIGH = 1,
	NORMAL = 2,
	LOW = 3,
	BACKGROUND = 4
}
NetRay.Version = "1.1.5"

NetRay.Debug = {
	GlobalEvent = SignalPlusFactory(),
	Error = SignalPlusFactory(),
	NetworkTraffic = SignalPlusFactory(),
	EnableMonitoring = function(options: {enabled: boolean}?)
		options = options or {}
		local isEnabled = options.enabled ~= false
		-- TODO: Implement actual manager signaling if needed
		print("[NetRay] Monitoring " .. (isEnabled and "Enabled" or "Disabled"))
		return isEnabled
	end,
} :: DebugType

NetRay.Utils = UtilitiesModule
NetRay.Errors = ErrorsModule
NetRay.Serializer = SerializerModule
NetRay.TypeChecker = TypeCheckerModule

--==============================================================================
-- Context-Specific Initialization & FINAL TYPE DEFINITION
--==============================================================================

if RunService:IsServer() then
	-- Server Context --

	-- Require Server Modules
	local ServerManager_Module = require(script.Server.ServerManager)
	local ServerEvent_Module = require(script.Server.ServerEvent)
	local RequestServer_Module = require(script.Server.RequestServer)

	-- Define Local Aliases for required module types
	type ServerManager = ServerManager_Module.ServerManager
	type ServerEventType = ServerEvent_Module.ServerEventType
	type RequestServerType = RequestServer_Module.RequestServerType
	type ServerEventOptions = ServerEvent_Module.ServerEventOptions -- Import options type
	type RequestServerOptions = RequestServer_Module.RequestServerOptions -- Import options type

	-- Define the COMPLETE Server Module Type HERE, using the specific types
	export type NetRayServerModule = NetRayBaseModuleData & {
		-- Properties
		Server: ServerManager,
		-- Method Signatures
		RegisterMiddleware: (self: NetRayServerModule, name: string, middlewareFn: any, priority: number?) -> (),
		GetCircuitBreaker: (self: NetRayServerModule, eventName: string) -> CircuitBreaker?,
		RegisterEvent: (self: NetRayServerModule, eventName: string, options: ServerEventOptions?) -> ServerEventType, -- Specific Return Type
		RegisterRequestEvent: (self: NetRayServerModule, eventName: string, options: RequestServerOptions?) -> RequestServerType, -- Specific Return Type
	}

	-- Implement Server API Methods on NetRay Table
	local serverManager = ServerManager_Module.new()
	NetRay.Server = serverManager :: ServerManager -- Assign typed manager instance

	-- Connect signals
	for signalName, signal in pairs(serverManager.Signals) do
		if signalName == "Error" then
			signal:Connect(function(...)
				NetRay.Debug.Error:Fire("Server", ...)
			end)
		else
			signal:Connect(function(...)
				NetRay.Debug.GlobalEvent:Fire("Server", signalName, ...)
			end)
		end
	end

	-- Implement shared/server methods
	function NetRay:RegisterMiddleware(name: string, middlewareFn: any, priority: number?) : Middleware?
		-- self.Server is guaranteed defined in this block
		if self.Server and self.Server.Middleware then
			self.Server.Middleware:Register(name, middlewareFn, priority)
		else
			warn("[NetRay S] Middleware registration failed - manager not ready?")
		end
	end

	function NetRay:GetCircuitBreaker(eventName: string): CircuitBreaker?
		return self.Server.CircuitBreakers[eventName]
	end

	function NetRay:RegisterEvent(eventName: string, options: ServerEventOptions?): ServerEventType
		-- Pass ServerManager instance (self.Server)
		return ServerEvent_Module.new(eventName, options, self.Server) :: ServerEventType
	end

	function NetRay:RegisterRequestEvent(eventName: string, options: RequestServerOptions?): RequestServerType
		-- Pass ServerManager instance (self.Server)
		local requestServer = RequestServer_Module.new(eventName, options, self.Server)
		return requestServer :: RequestServerType
	end

	-- Create remotes folder (deferred)
	task.defer(function()
		local remoteFolder = ReplicatedStorage:FindFirstChild("NetRayRemotes")
		if not remoteFolder then
			remoteFolder = Instance.new("Folder")
			remoteFolder.Name = "NetRayRemotes"
			remoteFolder.Parent = ReplicatedStorage
			print("[NetRay] Created NetRayRemotes folder.")
		end
	end)

	-- Initialize Server Manager Components
	serverManager:Initialize()

	-- Return the NetRay table, cast to the type DEFINED WITHIN THIS BLOCK
	return NetRay :: NetRayServerModule

else
	-- Client Context --

	-- Require Client Modules
	local ClientManager_Module = require(script.Client.ClientManager)
	local ClientEvent_Module = require(script.Client.ClientEvent)
	local RequestClient_Module = require(script.Client.RequestClient)

	-- Define Local Aliases for required module types
	type ClientManager = ClientManager_Module.ClientManager
	type ClientEventType = ClientEvent_Module.ClientEventType
	type RequestClientType = RequestClient_Module.RequestClientType
	type ClientEventOptions = ClientManager_Module.ClientEventOptions -- Import options type
	type RequestClientOptions = RequestClient_Module.RequestClientOptions -- Import options type

	-- Define the COMPLETE Client Module Type HERE, using the specific types
	export type NetRayClientModule = NetRayBaseModuleData & {
		-- Properties
		Client: ClientManager,
		-- Method Signatures
		RegisterMiddleware: (self: NetRayClientModule, name: string, middlewareFn: any, priority: number?) -> (),
		GetCircuitBreaker: (self: NetRayClientModule, eventName: string) -> CircuitBreaker?,
		GetEvent: (self: NetRayClientModule, eventName: string) -> NetRayEvent, -- Returns unified type
		RegisterRequestEvent: (self: NetRayClientModule, eventName: string, options: RequestClientOptions?) -> RequestClientType, -- Specific Return Type
	}

	-- Implement Client API Methods on NetRay Table
	local clientManager = ClientManager_Module.new()
	NetRay.Client = clientManager :: ClientManager -- Assign typed manager instance

	-- Connect signals
	for signalName, signal in pairs(clientManager.Signals) do
		if signalName == "Error" then
			signal:Connect(function(...)
				NetRay.Debug.Error:Fire("Client", ...)
			end)
		else
			signal:Connect(function(...)
				NetRay.Debug.GlobalEvent:Fire("Client", signalName, ...)
			end)
		end
	end

	-- Implement shared/client methods
	function NetRay:RegisterMiddleware(name: string, middlewareFn: any, priority: number?) : Middleware?
		if self.Client and self.Client.Middleware then
			self.Client.Middleware:Register(name, middlewareFn, priority)
		else
			warn("[NetRay C] Middleware registration failed - manager not ready?")
		end
	end

	function NetRay:GetCircuitBreaker(eventName: string): CircuitBreaker?
		return self.Client.CircuitBreakers[eventName]
	end

	function NetRay:GetEvent(eventName: string): NetRayEvent?
		local eventInfo = self.Client.Events[eventName]
		if eventInfo and eventInfo.Event then
			return eventInfo.Event :: NetRayEvent
		end

		local newEvent = ClientEvent_Module.new(eventName, nil, self.Client)

		if newEvent then
			return newEvent :: NetRayEvent
		else
			warn(("[NetRay] GetEvent: Failed create/find RemoteEvent for '%s'. Ensure registered on server & replicated."):format(eventName))
			return nil
		end
	end

	function NetRay:RegisterRequestEvent(eventName: string, options: RequestClientOptions?): RequestClientType?
		-- Pass ClientManager instance (self.Client)
		local requestClient = RequestClient_Module.new(eventName, options, self.Client)
		return requestClient :: RequestClientType?
	end

	-- Initialize Client Manager Components
	clientManager:Initialize()

	return NetRay :: NetRayClientModule
end