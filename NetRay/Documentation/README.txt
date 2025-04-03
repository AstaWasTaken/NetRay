Updated README.md
# NetRay - High Performance Roblox Networking

**Version:** 1.0.0
**Author:** Asta

## Table of Contents
1.  [Overview](#overview)
2.  [Setup](#setup)
3.  [Configuration](#configuration)
4.  [Basic Usage: Events](#basic-usage-events)
5.  [Advanced Usage: Requests](#advanced-usage-requests)
6.  [Advanced Features](#advanced-features)
    *   [Middleware](#middleware)
    *   [Type Checking](#type-checking)
    *   [Circuit Breakers](#circuit-breakers)
    *   [Priorities](#priorities)
    *   [Dynamic Sending](#dynamic-sending)
7.  [Debugging & Monitoring](#debugging--monitoring)
8.  [API Reference](#api-reference)

## Overview

NetRay is a high-performance networking library for Roblox that extends the built-in networking capabilities with improved performance, type safety, and developer experience. It aims to abstract away common networking complexities while providing powerful features for robust communication.

**Key Features:**

*   **Dynamic Data Optimization**: Automatically selects efficient serialization methods (currently binary encoding).
*   **Intelligent Compression**: Applies LZW compression via `DataCompression` module when potentially beneficial (configurable threshold).
*   **Batch Optimization**: Automatically batches outgoing events to reduce `RemoteEvent` calls, improving performance under load.
*   **Type Safety**: Optional validation for event and request payloads using a simple definition syntax.
*   **Circuit Breakers**: Prevents cascading failures by temporarily halting requests to unreliable endpoints.
*   **Middleware**: Intercept and modify incoming/outgoing data or block events/requests.
*   **Priorities**: Prioritize event handling on the client based on importance (`CRITICAL`, `HIGH`, `NORMAL`, `LOW`, `BACKGROUND`).
*   **Promises for Requests**: Modern asynchronous handling for request/response patterns.
*   **Comprehensive Monitoring**: Built-in signals for debugging events, errors, and network traffic.

## Setup

1.  Place the `NetRay` ModuleScript (containing all the sub-modules) into a location accessible by both client and server, typically `ReplicatedStorage`.
2.  Ensure the `ThirdParty` folder (containing `SignalPlus`, `Promise`, `DataCompression`) is inside the main `NetRay` module.
3.  Require the module in your scripts:

    ```lua
    -- Server script (e.g., in ServerScriptService)
    local ReplicatedStorage = game:GetService("ReplicatedStorage")
    local NetRay = require(ReplicatedStorage.NetRay)

    -- Client script (e.g., in StarterPlayerScripts)
    local ReplicatedStorage = game:GetService("ReplicatedStorage")
    local NetRay = require(ReplicatedStorage.NetRay)
    ```
4.  Upon the first server run, NetRay will create a Folder named `NetRayRemotes` in `ReplicatedStorage` to store `RemoteEvent` and `RemoteFunction` instances.

## Configuration

### Debugging

Enable global monitoring to capture events and errors across NetRay.

```lua
NetRay.Debug.EnableMonitoring({ enabled = true })

-- Optionally, listen to specific debug signals (see Debugging section)

Dynamic Sender (Affects Batching & Compression)

You can tweak the parameters used by the internal DynamicSender module. Note: This module is not directly exposed on the NetRay object, but its behavior influences sending.

-- Accessing config requires modifying the DynamicSender script directly
-- Example values within DynamicSender.lua:
-- NetRaySender.Config = {
--     BatchingEnabled = true,        -- Enable/disable event batching
--     BatchInterval = 0.03,          -- Seconds between checking batches (default)
--     MaxBatchSize = 15,             -- Max events per batch before forced flush
--     MaxBatchWait = 0.05,           -- Max seconds to wait before flushing batch
--     CompressionThreshold = 256,    -- Estimated size (bytes) to attempt compression
--     DebugMode = false,             -- Enable verbose sender logging
--     ForceCompressBatches = true,   -- Always try compressing batches
--     ForceCompressSingle = true,    -- Always try compressing single messages
-- }

Basic Usage: Events

Events are fire-and-forget messages.

Server-Side Events
-- Server Script

-- Register a new event with options
local playerAction = NetRay:RegisterEvent("PlayerAction", {
    typeDefinition = { -- Optional: Define expected data structure and types
        action = "string",
        targetId = "?number", -- Optional number
        position = "Vector3"
    },
    compression = true, -- Optional: Hint to attempt compression if data is large
    priority = NetRay.Priority.NORMAL, -- Optional: Client processing priority
    batchable = true -- Optional: Allow this event to be batched (default: true)
})

-- Listen for events fired from clients
playerAction:OnEvent(function(player, data)
    -- Type validation happens automatically if typeDefinition is provided
    print(("%s triggered action '%s' at %s"):format(player.Name, data.action, data.position))
    if data.targetId then
        print("Target ID:", data.targetId)
    end
    -- Handle game logic...
end)

-- Example: Fire an event to a specific client
local targetPlayer = game.Players:GetPlayers()[1]
if targetPlayer then
    playerAction:FireClient(targetPlayer, {
        action = "UpdateUI",
        position = Vector3.new() -- Example dummy data
    })
end

-- Example: Fire an event to all clients
playerAction:FireAllClients({
    action = "WorldEvent",
    position = Vector3.new(10, 5, 10)
})

-- Example: Fire an event to all clients except one
local excludedPlayer = game.Players:GetPlayers()[2]
if excludedPlayer then
    playerAction:FireAllClientsExcept(excludedPlayer, {
        action = "NotifyOthers",
        position = Vector3.new()
    })
end

-- Example: Fire an event to a filtered group of clients
playerAction:FireFilteredClients(function(player)
    return player.TeamColor == BrickColor.Red()
end, {
    action = "TeamObjective",
    position = Vector3.new(100, 0, 0)
})

Client-Side Events
-- Client Script

-- Get a reference to the event (or registers if it doesn't exist locally)
-- Providing options here *might* override defaults if called before first server message
local playerAction = NetRay:GetEvent("PlayerAction")
-- Alternatively:
-- local playerAction = NetRay:RegisterEvent("PlayerAction", { priority = NetRay.Priority.HIGH })

-- Listen for events fired from the server
playerAction:OnEvent(function(data)
    -- Type validation happens automatically if typeDefinition was set
    print(("Received action '%s' from server"):format(data.action))
    -- Update UI, play effects, etc.
end)

-- Example: Fire an event to the server
local character = game.Players.LocalPlayer.Character
local rootPart = character and character:FindFirstChild("HumanoidRootPart")
if rootPart then
    playerAction:FireServer({
        action = "JumpRequest",
        position = rootPart.Position
    })
end

Advanced Usage: Requests

Requests are for two-way communication where a response is expected (like RemoteFunction). NetRay uses Promises for handling asynchronous responses.

Server-Side Requests
-- Server Script

-- Register a new request event with type definitions for request and response
local getItemInfo = NetRay:RegisterRequestEvent("GetItemInfo", {
    requestTypeDefinition = { -- Optional: Validate incoming request data
        itemId = "number"
    },
    responseTypeDefinition = { -- Optional: Validate outgoing response data
        name = "string",
        description = "?string", -- Optional
        value = "number|nil" -- Union type
    },
    timeout = 5 -- Optional: Server-side timeout for *client* responses (if server invokes client)
})

-- Handle requests coming from clients
getItemInfo:OnRequest(function(player, data)
    -- Data is already validated against requestTypeDefinition if provided
    local itemId = data.itemId
    local itemData = YourItemDatabase:GetInfo(itemId)

    if not itemData then
        -- Use Promise.reject equivalent or return an error structure recognized by client
        -- Currently, returning nil or erroring in handler sends a failure back
        error(("Item %d not found"):format(itemId)) -- This will trigger client's .catch
        -- Alternatively, return a specific structure:
        -- return { success = false, error = "Item not found" } -- Requires client handling
    end

    -- Response will be validated against responseTypeDefinition
    return {
        name = itemData.Name,
        description = itemData.Description, -- Can be nil if optional
        value = itemData.Value or nil -- Can be nil if union type allows
    }
end)

-- Example: Server requesting data *from* a client (less common)
local clientConfigRequest = NetRay:RegisterRequestEvent("GetClientConfig", {
    responseTypeDefinition = {
        resolution = "string",
        renderQuality = "number"
    }
})

-- Inside some server logic...
local function askClientForConfig(player)
    clientConfigRequest:Request(player, { requestTime = tick() }) -- Optional data to send
    :andThen(function(response)
        print(("%s Config: Resolution %s, Quality %d"):format(
            player.Name, response.resolution, response.renderQuality
        ))
    end)
    :catch(function(err)
        warn(("Failed to get config from %s: %s"):format(player.Name, err))
    end)
end

Client-Side Requests
-- Client Script

-- Register the request event (needed to send requests or handle server invokes)
local getItemInfo = NetRay:RegisterRequestEvent("GetItemInfo", {
    timeout = 10 -- Optional: Client-side timeout for *server* responses
})

-- Example: Requesting item info from the server
local function fetchItemInfo(itemId)
    print("Requesting info for item", itemId)
    getItemInfo:Request({ itemId = itemId })
    :andThen(function(response)
        -- Response is validated against responseTypeDefinition if provided server-side
        print(("- Item %d: %s"):format(itemId, response.name))
        if response.description then
            print("  Desc:", response.description)
        end
        if response.value then
            print("  Value:", response.value)
        end
    end)
    :catch(function(errorMessage)
        -- Handles errors from server (e.g., if handler errored) or network issues
        warn(("Failed to get item %d info: %s"):format(itemId, errorMessage))
    end)
end

fetchItemInfo(123)
fetchItemInfo(999) -- Example likely to fail

-- Example: Handling a request *from* the server
local clientConfigRequest = NetRay:RegisterRequestEvent("GetClientConfig")

clientConfigRequest:OnRequest(function(dataFromServer)
    -- Handle the server's request, return data
    print("Server requested config. Sent data:", dataFromServer)
    local qualityLevel = UserSettings():GetService("UserGameSettings").SavedQualityLevel.Value
    local screenRes = workspace.CurrentCamera.ViewportSize
    return {
        resolution = ("%dx%d"):format(screenRes.X, screenRes.Y),
        renderQuality = qualityLevel
    }
end)

Advanced Features
Middleware

Middleware allows you to intercept and process network data globally or for specific events.

-- Register middleware (can be done on client or server)
-- Middleware runs in order of priority (lower number = earlier)

-- Example: Logging middleware (runs early)
NetRay:RegisterMiddleware("Logger", function(eventName, player, data)
    local context = RunService:IsServer() and "Server" or "Client"
    print(("[%s MW] Event: %s, Player: %s"):format(
        context, eventName, player and player.Name or "N/A"
    ))
    -- Return nil to pass data through unchanged
    -- Return modified data to change it
    -- Return false to block the event/request entirely
    return data
end, 10) -- Priority 10

-- Example: Input validation middleware (runs after logger)
NetRay:RegisterMiddleware("Validator", function(eventName, player, data)
    if eventName == "PlayerAction" then
        if type(data.action) ~= "string" or #data.action < 1 then
            warn("[MW Validator] Invalid action:", data.action)
            return false -- Block the event
        end
    end
    return data -- Pass through
end, 50) -- Priority 50

-- Removing middleware
-- NetRay.Server.Middleware:Remove("Logger") -- Server
-- NetRay.Client.Middleware:Remove("Logger") -- Client

Note: Direct removal access via NetRay.Server/Client.Middleware assumes internal structure access. A public RemoveMiddleware function on NetRay itself might be safer.

Type Checking

Define the expected structure and types of data for events and requests. NetRay will automatically validate incoming data.

Supported Types:

Basic types: string, number, boolean, table, nil, userdata, function, thread, any

Roblox types: Vector2, Vector3, CFrame, Color3, BrickColor, UDim, UDim2, Rect, Region3, NumberSequence, ColorSequence, EnumItem, buffer, Instance

Unions: type1|type2 (e.g., string|number)

Optional: ?type (e.g., ?string, allows nil)

Instances: Instance<ClassName> (e.g., Instance<Part>)

Arrays: Array<ItemType> (e.g., Array<string>)

Dictionaries: Dict<KeyType, ValueType> (e.g., Dict<string, number>)

-- In RegisterEvent or RegisterRequestEvent options:
local myEvent = NetRay:RegisterEvent("ComplexData", {
    typeDefinition = {
        id = "number",
        name = "string",
        tags = "Array<string>",
        position = "?Vector3", -- Optional Vector3
        config = "Dict<string, boolean|number>", -- Dict with string keys, boolean or number values
        targetPart = "Instance<BasePart>",
        status = "EnumItem"
    }
})

myEvent:OnEvent(function(player, data)
    -- data is guaranteed to match the definition (or the event wouldn't have run)
    print(data.name, data.status.Name)
end)

Circuit Breakers

Automatically prevent calls to events/requests that are consistently failing.

Circuit breakers are configured per-event/request during registration:

-- Server side registration
local riskyRequest = NetRay:RegisterRequestEvent("RiskyOperation", {
    circuitBreaker = {
        failureThreshold = 3, -- Open circuit after 3 failures
        resetTimeout = 15,   -- Try again after 15 seconds
        fallback = function(player, data) -- Optional function when circuit is open
            warn("RiskyOperation circuit is OPEN. Using fallback for player " .. player.Name)
            return { success = false, error = "Service temporarily unavailable" }
        end
    }
})

-- Client side registration
local riskyRequest = NetRay:RegisterRequestEvent("RiskyOperation", {
    circuitBreaker = { -- Can have different settings client-side
        failureThreshold = 5,
        resetTimeout = 20,
        fallback = function(data) -- Fallback for client *sending* the request
            warn("RiskyOperation circuit is OPEN. Request blocked.")
            -- Maybe return default data or cached data
            return nil
        end
    }
})


You can manually inspect a circuit breaker's state:

local cb = NetRay:GetCircuitBreaker("RiskyOperation")
if cb then
    print("Circuit state:", cb.State) -- "CLOSED", "OPEN", "HALF_OPEN"
    print("Failures:", cb.FailureCount)
    local metrics = cb:GetMetrics()
    print("Total failures:", metrics.totalFailures)
end

Priorities

Control the order in which client-side event handlers are processed.

-- Register with different priorities
local criticalEvent = NetRay:RegisterEvent("CriticalUpdate", { priority = NetRay.Priority.CRITICAL })
local uiEvent = NetRay:RegisterEvent("UIUpdate", { priority = NetRay.Priority.HIGH })
local logEvent = NetRay:RegisterEvent("BackgroundLog", { priority = NetRay.Priority.BACKGROUND })

-- Client-side: criticalEvent handlers will generally run before uiEvent, etc.

Priority Levels (Lower value = Higher priority):

CRITICAL = 0

HIGH = 1

NORMAL = 2 (Default)

LOW = 3

BACKGROUND = 4

Dynamic Sending

NetRay automatically optimizes data sending using the internal DynamicSender module. This includes:

Batching: Multiple FireClient calls for the same RemoteEvent within a short interval may be grouped into a single network transmission. This reduces overhead. Controlled by BatchingEnabled, BatchInterval, MaxBatchSize, MaxBatchWait. Set batchable = false in event options to disable batching for that specific event.

Compression: Data exceeding CompressionThreshold is automatically compressed using LZW if compression is likely to reduce the final payload size. Set compression = true/false in event options as a hint.

Serialization: Uses an efficient binary serialization format.

These features work mostly automatically, but awareness helps understand performance characteristics.

Debugging & Monitoring

NetRay provides signals for monitoring internal operations.

-- Make sure monitoring is enabled
NetRay.Debug.EnableMonitoring({ enabled = true })

-- Global Event Signal: Fires for various internal events
NetRay.Debug.GlobalEvent:Connect(function(context, signalName, ...)
    print(("[%s DEBUG] %s"):format(context, signalName), ...)
    -- Context: "Server" or "Client"
    -- SignalName: e.g., "EventRegistered", "EventFired", "RequestSent"
end)

-- Global Error Signal: Fires for errors caught within NetRay
NetRay.Debug.Error:Connect(function(context, source, ...)
    warn(("[%s ERROR] Source: %s"):format(context, source), ...)
    -- Context: "Server" or "Client"
    -- Source: Can be module name or specific error location
end)

-- Network Traffic Signal (Conceptual - Implementation may vary)
--[[
NetRay.Debug.NetworkTraffic:Connect(function(stats)
    -- Example stats structure (depends on implementation)
    print("Traffic:",
        "SentBPS:", stats.sentBPS,
        "RecvBPS:", stats.receivedBPS,
        "QueueSize:", stats.outgoingQueueSize
    )
end)
-- Note: The current NetworkTraffic signal in init.txt is just a placeholder signal.
-- Actual traffic monitoring needs specific implementation hooked into sending/receiving.
]]

-- Monitor Circuit Breaker State Changes
local cb = NetRay:GetCircuitBreaker("SomeEvent")
if cb then
    cb.Signals.StateChanged:Connect(function(oldState, newState)
        print(("Circuit Breaker 'SomeEvent' changed state: %s -> %s"):format(oldState, newState))
    end)
end

API Reference
NetRay (Top Level)

NetRay.Version: (string) Current library version.

NetRay.Priority: (table) Constants for event priorities.

NetRay.Debug: (table) Debugging signals and functions.

Debug.GlobalEvent: SignalPlus - Fires for many internal events. Args: (context: string, signalName: string, ...)

Debug.Error: SignalPlus - Fires for internal errors. Args: (context: string, source: string, ...)

Debug.NetworkTraffic: SignalPlus - Placeholder for network stats. Args: (stats: table)

Debug.EnableMonitoring(options: table): Enables/disables debug signal firing. options = { enabled = true }

NetRay:RegisterMiddleware(name: string, middlewareFn: function, priority: number?): Registers global middleware. middlewareFn(eventName, player, data) -> data | nil | false.

NetRay:RegisterEvent(eventName: string, options: table?): (Server/Client) Registers a RemoteEvent. Returns ServerEvent or ClientEvent.

NetRay:RegisterRequestEvent(eventName: string, options: table?): (Server/Client) Registers a RemoteFunction. Returns RequestServer or RequestClient.

NetRay:GetCircuitBreaker(eventName: string): (Server/Client) Returns the CircuitBreaker instance for an event/request.

NetRay:GetEvent(eventName: string): (Client Only) Gets or registers a ClientEvent.

NetRay.Server: (Server Only) The ServerManager instance.

NetRay.Client: (Client Only) The ClientManager instance.

NetRay.Utils, NetRay.Errors, NetRay.Serializer, NetRay.TypeChecker: Access to shared utility modules.

Event Options (Passed to RegisterEvent/RegisterRequestEvent)

typeDefinition: table?: Type definition for event data (client receives/server receives).

requestTypeDefinition: table?: Type definition for request data (used by RequestEvents).

responseTypeDefinition: table?: Type definition for response data (used by RequestEvents).

compression: boolean?: Hint to attempt compression. Default often depends on DynamicSender config.

priority: number?: Client processing priority (See NetRay.Priority). Default: NORMAL.

batchable: boolean?: (Events Only) Allows server-to-client events to be batched. Default: true.

timeout: number?: (Requests Only) Timeout in seconds. Default: 10.

circuitBreaker: table?: Circuit breaker configuration.

failureThreshold: number? (Default: 5)

resetTimeout: number? (Default: 30)

fallback: function?

(See CircuitBreaker.lua for more options)

ServerEvent Methods

:OnEvent(callback: function): Register handler for events from clients. callback(player: Player, data: any).

:FireClient(player: Player, data: any): Send event to a specific client.

:FireAllClients(data: any): Send event to all connected clients.

:FireAllClientsExcept(excludedPlayer: Player, data: any): Send event to all clients except one.

:FireFilteredClients(filterFn: function, data: any): Send event to clients where filterFn(player) returns true.

ClientEvent Methods

:OnEvent(callback: function): Register handler for events from server. callback(data: any).

:FireServer(data: any): Send event to the server.

RequestServer Methods (Server-Side)

:OnRequest(callback: function): Register handler for requests from clients. callback(player: Player, data: any) -> response: any.

:Request(player: Player, data: any) -> Promise: Send a request to a specific client.

RequestClient Methods (Client-Side)

:OnRequest(callback: function): Register handler for requests from the server. callback(data: any) -> response: any.

:Request(data: any) -> Promise: Send a request to the server.