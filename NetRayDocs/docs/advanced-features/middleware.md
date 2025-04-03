---
title: Middleware
---

# Middleware

Middleware provides a powerful way to intercept and process network data as it flows through NetRay. You can use it for logging, validation, rate limiting, data transformation, or even blocking events/requests based on custom logic.

Middleware functions are executed sequentially based on their priority number (lower numbers run earlier).

## Registration

Register middleware globally using `NetRay:RegisterMiddleware()`. This works on both the client and the server.

    name: A unique string identifier for the middleware.
    handlerFn: The function to execute. It receives (eventName, player, data).
    player: nil on the client or when server fires globally.
    priority: A number (optional, default 100). Lower numbers execute first.

### Example: Basic Logger Middleware (runs fairly early)
```lua
NetRay:RegisterMiddleware("GlobalLogger", function(eventName, player, data)
    local context = game:GetService("RunService"):IsServer() and "Server" or "Client"
    local playerName = player and player.Name or "N/A"
    print(`[${context} MW] Event/Request: ${eventName}, Player: ${playerName}`)
    -- print(data) -- Careful: Printing large tables can lag

    -- IMPORTANT: Middleware MUST return something to continue the chain.
    -- Return 'data' (modified or unmodified) to allow processing to continue.
    -- Return 'nil' if you didn't modify the data (equivalent to returning original 'data').
    -- Return 'false' to block the event/request entirely.
    return data
end, 20) -- Priority 20
```

### Example: Input Sanitization Middleware (runs later)
```lua
NetRay:RegisterMiddleware("Sanitizer", function(eventName, player, data)
    if eventName == "PlayerChatMessage" and type(data) == "table" and type(data.message) == "string" then
        -- Basic sanitization example (more robust filtering needed for production)
        data.message = data.message:gsub("[<>]", "") -- Simple tag removal
        print("[MW Sanitizer] Sanitized chat message.")
        return data -- Return the modified data
    end
    -- If no changes, return the original data (or nil)
    return data
end, 150) -- Priority 150
```

### Example: Blocking Middleware (runs very early)
```lua
NetRay:RegisterMiddleware("MaintenanceModeBlocker", function(eventName, player, data)
    if game:GetAttribute("MaintenanceMode") == true then
        -- Don't allow any client -> server communication during maintenance
        if game:GetService("RunService"):IsServer() and player then
            warn("[MW Blocker] Maintenance mode active, blocking event:", eventName, "from", player.Name)
            return false -- Block the event/request
        end
    end
    return data
end, 5) -- Priority 5
```

## Execution Flow

1.  When an event/request is fired or received, NetRay retrieves the list of registered middleware handlers.
2.  Handlers are sorted by priority (lowest to highest).
3.  The initial `data` payload is passed to the first middleware handler.
4.  Each handler executes and can:
    *   Return the `data` (modified or original): This payload is passed to the next middleware in the chain.
    *   Return `nil`: Equivalent to returning the unmodified `data`. The chain continues with the same payload.
    *   Return `false`: Stops the middleware chain *and* blocks the underlying event/request from being processed further (e.g., the `OnEvent` or `OnRequest` handler won't be called, the remote fire won't happen).
5.  If the chain completes without being blocked, the final resulting `data` payload is used for the actual event/request processing.

## Use Cases

*   **Logging:** Record network activity for debugging.
*   **Validation:** Perform complex validation beyond basic type checking.
*   **Authentication/Authorization:** Verify player permissions before processing certain requests (though often better handled in the `OnEvent`/`OnRequest` handler itself for clarity).
*   **Rate Limiting:** Implement custom rate limiting logic per player or globally.
*   **Data Transformation:** Modify data formats between client/server if needed (e.g., changing property names).
*   **Feature Flags:** Enable/disable certain network events based on server configuration.

:::caution Synchronous Execution
Middleware handlers **must execute synchronously**. Avoid yielding (like `wait()`, `task.wait()`, or asynchronous API calls like `DataStoreService:GetAsync`) within a middleware function, as this will halt the entire network processing pipeline for that specific event/request. If complex asynchronous checks are needed, they typically belong in the final `OnEvent` or `OnRequest` handler.
:::