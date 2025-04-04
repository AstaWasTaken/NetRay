--!strict
--!optimize 2
--!native
--[[
    NetRay - High Performance Roblox Networking Library
    
    A powerful networking library that extends Roblox's networking capabilities
    with improved performance, type safety, and developer experience.
    
    Author: Asta (@TheYusufGamer)
    Created: 2025-03-22
]]

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SignalPlus = require(script.ThirdParty.SignalPlus)

local NetRay = {}
NetRay.__index = NetRay

-- Constants
NetRay.Priority = {
    CRITICAL = 0,
    HIGH = 1,
    NORMAL = 2,
    LOW = 3,
    BACKGROUND = 4
}

-- Version info
NetRay.Version = "1.0.0"

-- Debug and monitoring signals
NetRay.Debug = {
    -- Global signals
    GlobalEvent = SignalPlus(),  -- Fires for all events across the system
    Error = SignalPlus(),        -- Fires for all errors across the system
    
    -- Performance monitoring
    NetworkTraffic = SignalPlus(), -- Fires with network traffic statistics
    
    -- Utility functions
    EnableMonitoring = function(options)
        options = options or {}
        local isEnabled = options.enabled ~= false
        
        -- Implementation will be set after context initialization
        return isEnabled
    end
}

-- Initialize modules based on client or server context
if RunService:IsServer() then
    -- Server context
    local ServerManager = require(script.Server.ServerManager)
    local ServerEvent = require(script.Server.ServerEvent)
    local RequestServer = require(script.Server.RequestServer)
    
    NetRay.Server = ServerManager.new()
    
    -- Connect server signals to global debug signals
    for signalName, signal in pairs(NetRay.Server.Signals) do
        signal:Connect(function(...)
            NetRay.Debug.GlobalEvent:Fire("Server", signalName, ...)
        end)
    end
    
    -- Special handling for error signals
    NetRay.Server.Signals.Error:Connect(function(...)
        NetRay.Debug.Error:Fire("Server", ...)
    end)
    
    -- Expose server APIs
    NetRay.RegisterEvent = function(self, eventName, options)
        return ServerEvent.new(eventName, options or {}, self.Server)
    end
    
    NetRay.RegisterRequestEvent = function(self, eventName, options)
        return RequestServer.new(eventName, options or {}, self.Server)
    end
    
    NetRay.GetCircuitBreaker = function(self, eventName)
        return self.Server.CircuitBreakers[eventName]
    end
    
    -- Initialize server components
    NetRay.Server:Initialize()
else
    -- Client context
    local ClientManager = require(script.Client.ClientManager)
    local ClientEvent = require(script.Client.ClientEvent)
    local RequestClient = require(script.Client.RequestClient)
    
    NetRay.Client = ClientManager.new()
    
    -- Connect client signals to global debug signals
    for signalName, signal in pairs(NetRay.Client.Signals) do
        signal:Connect(function(...)
            NetRay.Debug.GlobalEvent:Fire("Client", signalName, ...)
        end)
    end
    
    -- Special handling for error signals
    NetRay.Client.Signals.Error:Connect(function(...)
        NetRay.Debug.Error:Fire("Client", ...)
    end)
    
    -- Expose client APIs
    NetRay.RegisterEvent = function(self, eventName, options)
        return ClientEvent.new(eventName, options or {}, self.Client)
    end
    
    NetRay.GetEvent = function(self, eventName)
        -- Get an existing event or create a new one with default options
        local eventInfo = self.Client.Events[eventName]
        if eventInfo and eventInfo.Event then
            return eventInfo.Event
        else
            return self:RegisterEvent(eventName, {})
        end
    end
    
    NetRay.RegisterRequestEvent = function(self, eventName, options)
        return RequestClient.new(eventName, options or {}, self.Client)
    end
    
    NetRay.GetCircuitBreaker = function(self, eventName)
        return self.Client.CircuitBreakers[eventName]
    end
    
    -- Initialize client components
    NetRay.Client:Initialize()
end

-- Shared functionality (available on both client and server)
local Middleware = require(script.Shared.Middleware)

-- Register middleware function (works on both client and server)
function NetRay:RegisterMiddleware(name, middlewareFn, priority)
    if RunService:IsServer() then
        self.Server.Middleware:Register(name, middlewareFn, priority)
    else
        self.Client.Middleware:Register(name, middlewareFn, priority)
    end
end

-- Create folder for RemoteEvents if it doesn't exist
if RunService:IsServer() then
    -- Create the RemoteEvents folder in ReplicatedStorage if it doesn't exist
    local remoteFolder = ReplicatedStorage:FindFirstChild("NetRayRemotes")
    if not remoteFolder then
        remoteFolder = Instance.new("Folder")
        remoteFolder.Name = "NetRayRemotes"
        remoteFolder.Parent = ReplicatedStorage
    end
end

-- Initialize shared utilities
NetRay.Utils = require(script.Shared.Utilities)
NetRay.Errors = require(script.Shared.Errors)
NetRay.Serializer = require(script.Shared.Serializer)
NetRay.TypeChecker = require(script.Shared.TypeChecker)

return NetRay
