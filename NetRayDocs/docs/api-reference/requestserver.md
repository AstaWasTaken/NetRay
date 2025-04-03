---
title: API Reference - RequestServer
---

# API: RequestServer

Returned by `NetRay:RegisterRequestEvent` on the server. Handles the server-side logic for request/response communication initiated by clients (or rarely, by the server towards a client).

## Methods

### `:OnRequest(callback: function)`
Registers the primary handler function that executes when a request is received *from* a client for this endpoint. This function **must** return a value (the response) or `error()` to reject the client's Promise.
*   **`callback(player: Player, data: any) -> response: any`**:
    *   `player`: The `Player` instance making the request.
    *   `data`: The request payload sent by the client (validated against `requestTypeDefinition` if provided).
    *   **Return Value**: The data to send back as the response to the client. This value is validated against `responseTypeDefinition` if provided. If the callback `error()`s, the client's Promise is rejected with the error message.

Example:
```lua
local getDataRequest = NetRay:RegisterRequestEvent("GetPlayerData", {
    responseTypeDefinition = { level = "number", xp = "number" }
})

local PlayerDataModule = require(game.ServerStorage.PlayerData)

getDataRequest:OnRequest(function(player, data)
    -- 'data' might be empty or contain specifics like {'field': 'level'}
    local userId = player.UserId
    local level = PlayerDataModule:GetLevel(userId)
    local xp = PlayerDataModule:GetXP(userId)

    if level == nil or xp == nil then
        error("Could not load player data for " .. player.Name) -- Rejects client Promise
    end

    return { level = level, xp = xp } -- Resolves client Promise
end)
```
### `:Request(player: Player, data: any): Promise`
(Less Common Usage) Initiates a request *from* the server *to* a specific client. The client must have registered the same request name and provided an `:OnRequest` handler.
*   `player`: The target `Player` instance to send the request to.
*   `data`: The data payload to send with the request (validated against the *client's* `requestTypeDefinition` if they defined one).
*   **Returns**: A `Promise` that resolves with the client's response or rejects on error/timeout. The response is validated against *this* (server's) `responseTypeDefinition`.

Example:
```lua
local promptClientAction = NetRay:RegisterRequestEvent("PromptAction", {
    responseTypeDefinition = { confirmed = "boolean" } -- Server expects boolean confirmation back
})

local function askPlayerToConfirm(player)
    promptClientAction:Request(player, { prompt = "Accept Quest?" })
        :andThen(function(response) -- Response from client handler
            if response.confirmed then
                print(player.Name, "accepted the quest.")
                -- Grant quest
            else
                print(player.Name, "declined the quest.")
            end
        end)
        :catch(function(err)
            warn("Failed to get confirmation from", player.Name, ":", err)
        end)
end
```
## Properties (Internal)

Holds references to:
*   `Name`: Request name string.
*   `Options`: Registration options.
*   `ServerManager`: Parent manager instance.
*   `RemoteFunction`: Underlying Roblox `RemoteFunction`.

### Example of Server-Side Request Registration

```lua
-- Example of server-side request registration
local getDataRequest = NetRay:RegisterRequestEvent("GetPlayerData", {
    responseTypeDefinition = { level = "number", xp = "number" }
})

local PlayerDataModule = require(game.ServerStorage.PlayerData)

-- Server-side handler
getDataRequest.OnServerInvoke = function(player)
    local data = PlayerDataModule:GetData(player)
    return {
        level = data.level,
        xp = data.xp
    }
end
```