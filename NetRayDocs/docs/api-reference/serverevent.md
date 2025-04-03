---
title: API Reference - ServerEvent
---

# API: ServerEvent

Returned by `NetRay:RegisterEvent` on the server. Handles server-side logic for unidirectional events.

## Methods

### `:OnEvent(callback: function)`
Registers a handler function to be called when this specific event is received *from* a client.
*   **`callback(player: Player, data: any)`**:
    *   `player`: The `Player` instance who sent the event.
    *   `data`: The payload sent by the client (automatically type-checked if `typeDefinition` was provided during registration).

Example:
```lua
local myEvent = NetRay:RegisterEvent("PlayerAction")
myEvent:OnEvent(function(player, data)
    print(player.Name, "sent action:", data)
end)
```

### `:FireClient(player: Player, data: any)`
Sends the event and associated `data` payload to a single specific client.
*   `player`: The target `Player` instance.
*   `data`: The data payload to send.

Example:
```lua
local targetPlayer = Players:FindFirstChild("Roblox")
if targetPlayer then
    myEvent:FireClient(targetPlayer, { message = "Hello!" })
end
```

### `:FireAllClients(data: any)`
Sends the event and `data` payload to all currently connected clients. NetRay optimizes this using `RemoteEvent:FireAllClients` internally when possible.
*   `data`: The data payload to send.

Example:
```lua
myEvent:FireAllClients({ announcement = "Server restarting soon!" })
```

### `:FireAllClientsExcept(excludedPlayer: Player, data: any)`
Sends the event and `data` payload to all connected clients *except* the specified `excludedPlayer`.
*   `excludedPlayer`: The `Player` instance to exclude.
*   `data`: The data payload to send.

Example:
```lua
-- Example of using FireAllClientsExcept
local myEvent = NetRay:RegisterEvent("GameAnnouncement", {
    typeDefinition = { message = "string" }
})

-- Announce to all players except the winner
local playerWhoWon = game.Players:FindFirstChild("Winner")
if playerWhoWon then
    myEvent:FireAllClientsExcept(playerWhoWon, { message = playerWhoWon.Name .. " won the round!" })
end
```

### `:FireFilteredClients(filterFn: function, data: any)`
Sends the event and `data` payload only to clients for whom the `filterFn` function returns `true`.
*   **`filterFn(player: Player) -> boolean`**: A function that takes a player instance and returns `true` if the event should be sent to them, `false` otherwise.
*   `data`: The data payload to send.

Example:
```lua
-- Send only to players on the "Red" team
myEvent:FireFilteredClients(function(plr)
    return plr.Team and plr.Team.Name == "Red"
end, { team_objective = "Capture Point B!" })
```

## Properties (Internal)

While not typically accessed directly, a `ServerEvent` instance holds references to:
*   `Name`: The event name string.
*   `Options`: The options table passed during registration.
*   `ServerManager`: The parent `ServerManager` instance.
*   `RemoteEvent`: The underlying Roblox `RemoteEvent` instance.
