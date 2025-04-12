---
sidebar_position: 2
title: Getting Started
---

# Getting Started with NetRay

This guide walks you through the basic steps to get NetRay up and running in your Roblox project.

## 1. Installation

1.  Download or clone the `NetRay` ModuleScript source code. Ensure it includes the `Client`, `Server`, `Shared`, and `ThirdParty` folders internally.
2.  Place the complete `NetRay` ModuleScript into `ReplicatedStorage` within your Roblox project hierarchy.

    *Example File Structure in Roblox Studio:*
    ```
    ReplicatedStorage
    └── NetRay [ModuleScript]
        ├── (init script inside)
        ├── Client [Folder]
        │    ├── ClientManager.lua
        │    └── ...
        ├── Server [Folder]
        │    ├── ServerManager.lua
        │    └── ...
        ├── Shared [Folder]
        │    ├── Serializer.lua
        │    └── ...
        ├── ThirdParty [Folder]
        │    ├── SignalPlus.lua
        │    ├── Promise.lua
        │    └── DataCompression.lua
        └── Types [Folder]
            ├── Cursor.lua
            ├── Binary.lua
            └── ... [Other Type Definitions]
    ```

## 2. Basic Script Setup

Require the NetRay module in your relevant server and client scripts.

### Server Script

Place this in a script under `ServerScriptService`.

```lua
-- ServerScriptService/GameManager.server.lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local NetRay = require(ReplicatedStorage.NetRay)

print("✅ NetRay Server Initialized | Version:", NetRay.Version or "N/A")

-- Example: Registering a simple event
local playerJoinEvent = NetRay:RegisterEvent("PlayerJoinedNotification")

-- You can now listen for events fired from clients or fire events to clients
-- See the Events guide for more details.

game:GetService("Players").PlayerAdded:Connect(function(player)
    print(player.Name, "has joined the server.")
    -- Example: Notify all *other* clients that someone joined
    playerJoinEvent:FireAllClientsExcept(player, {
        playerName = player.Name,
        joinTimestamp = tick()
    })
end)
```

### Client Script

Place this in a script under `StarterPlayer > StarterPlayerScripts`.
```lua
-- StarterPlayerScripts/ClientManager.client.lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local NetRay = require(ReplicatedStorage.NetRay)
local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer

print("✅ NetRay Client Initialized | Version:", NetRay.Version or "N/A")

-- Example: Listening for the server's notification event
local playerJoinEvent = NetRay:GetEvent("PlayerJoinedNotification")

playerJoinEvent:OnEvent(function(data)
    print(("%s joined the game!"):format(data.playerName))
    -- Display a notification in the UI, etc.
end)

-- Example: Sending data to the server
local reportLatencyEvent = NetRay:GetEvent("ReportLatency") 
task.delay(10, function()
    -- Ensure GetNetworkPing exists and is appropriate here
    local pingMethod = LocalPlayer.GetNetworkPing or LocalPlayer.GetPing
    if pingMethod then
        local currentPing = pingMethod(LocalPlayer) * 1000 -- ping in ms
        print("Reporting latency to server:", currentPing)
        reportLatencyEvent:FireServer({ latencyMs = currentPing })
    else
        print("Cannot get player ping.")
    end
end)
```
    
## 3. Initial Server Run

The first time your game server starts after adding NetRay, it will automatically create a `Folder` named `NetRayRemotes` inside `ReplicatedStorage`. NetRay uses this folder to manage the underlying `RemoteEvent` and `RemoteFunction` instances required for communication. **Do not delete or modify this folder manually.**

## Next Steps

You're now ready to use NetRay!

*   Learn how to [Configure NetRay](./configuration.md) for debugging and performance tuning.
*   Dive into the core communication patterns: [Events](./core-concepts/events.md) and [Requests](./core-concepts/requests.md).
*   Explore [Advanced Features](./advanced-features/middleware.md) like Middleware, Type Checking, and Circuit Breakers.