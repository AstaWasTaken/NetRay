---
title: API Reference - ClientEvent
---

# API: ClientEvent

Returned by `NetRay:GetEvent` or `NetRay:RegisterEvent` on the client. Handles client-side logic for unidirectional events.

## Methods

### `:OnEvent(callback: function)`
Registers a handler function to be called when this specific event is received *from* the server. The processing order depends on the `priority` set during the event's *server-side* registration.
*   **`callback(data: any)`**:
    *   `data`: The payload sent by the server (automatically type-checked if `typeDefinition` was provided during registration).

Example:
```lua
local serverMessageEvent = NetRay:GetEvent("ServerMessage")
serverMessageEvent:OnEvent(function(data)
    print("Message from server:", data.text)
    -- Update UI.ShowNotification(data.text)
end)
```

### `:FireServer(data: any)`
Sends the event and associated `data` payload *to* the server.
*   `data`: The data payload to send (will be type-checked against the server's `typeDefinition` upon arrival if defined).

Example:
```lua
local playerInputEvent = NetRay:GetEvent("PlayerInput")
local UserInputService = game:GetService("UserInputService")

UserInputService.InputBegan:Connect(function(input, processed)
    if processed then return end
    if input.KeyCode == Enum.KeyCode.Space then
        playerInputEvent:FireServer({ action = "Jump", pressTime = input.TimePosition })
    end
end)
```

## Properties (Internal)

While not typically accessed directly, a `ClientEvent` instance holds references to:
*   `Name`: The event name string.
*   `Options`: The options table passed during registration (or defaults).
*   `ClientManager`: The parent `ClientManager` instance.
*   `RemoteEvent`: The underlying Roblox `RemoteEvent` instance.