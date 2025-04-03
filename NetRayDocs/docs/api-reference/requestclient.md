---
title: API Reference - RequestClient
---

# API: RequestClient

Returned by `NetRay:RegisterRequestEvent` on the client. Handles the client-side logic for request/response communication, primarily for making requests to the server, but also for handling requests initiated *by* the server. Uses Promises for asynchronous results.

## Methods

### `:Request(data: any): Promise`
Initiates a request *from* this client *to* the server endpoint with the same name.
*   `data`: The data payload to send with the request (validated against the *server's* `requestTypeDefinition` if defined).
*   **Returns**: A `Promise` that:
    *   Resolves with the `response` data sent back by the server's `:OnRequest` handler (validated against the server's `responseTypeDefinition`).
    *   Rejects with an `errorMessage: string` if the server handler `error()`s, the request times out, the circuit breaker is open, or a network error occurs.

Example:
```lua
local getServerTime = NetRay:RegisterRequestEvent("GetServerTime", {
    timeout = 5 -- Wait max 5 seconds
})

print("Requesting server time...")
getServerTime:Request({}) -- Send empty table if no request data needed
    :andThen(function(response)
        -- Assuming server returns { timestamp = 12345.67 }
        print("Server time received:", response.timestamp)
    end)
    :catch(function(err)
        warn("Failed to get server time:", err)
    end)
```

### `:OnRequest(callback: function)`
(Less Common Usage) Registers a handler function that executes when a request is received *from* the server for this endpoint. This function **must** return a value (the response) or `error()` to reject the server's Promise.
*   **`callback(data: any) -> response: any`**:
    *   `data`: The request payload sent by the server. Validated against *this* (client's) `requestTypeDefinition` if defined during client registration.
    *   **Return Value**: The data to send back as the response to the server. This value is validated against *this* (client's) `responseTypeDefinition` if defined. If the callback `error()`s, the server's Promise is rejected.

Example:
```lua
local promptClientAction = NetRay:RegisterRequestEvent("PromptAction", {
    requestTypeDefinition = { prompt = "string" },
    responseTypeDefinition = { confirmed = "boolean" }
})

promptClientAction:OnRequest(function(data)
    print("Server requested action:", data.prompt)
    local didConfirm = YourGUIManager:ShowConfirmationPrompt(data.prompt) -- Show UI prompt
    return { confirmed = didConfirm } -- Send response back to server
end)
```

## Properties (Internal)

Holds references to:
*   `Name`: Request name string.
*   `Options`: Registration options.
*   `ClientManager`: Parent manager instance.
*   `RemoteFunction`: Underlying Roblox `RemoteFunction`.

### Example Usage

```lua
-- Example of client-side request registration
local getServerTime = NetRay:RegisterRequestEvent("GetServerTime", {
    timeout = 5 -- Wait max 5 seconds
})

print("Requesting server time...")

local success, serverTime = getServerTime:InvokeServer()
if success then
    print("Server time:", serverTime)
else
    print("Failed to get server time")
end
```