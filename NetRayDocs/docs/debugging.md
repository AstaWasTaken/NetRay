---
title: Debugging & Monitoring
---

# Debugging & Monitoring

NetRay provides built-in signals and utilities to help you understand its internal behavior, track down issues, and monitor performance.

## Enabling Debug Mode

To receive detailed logs and events from NetRay's debug signals, you first need to enable monitoring globally:

Do this early in your initialization script (client or server)
```lua
NetRay.Debug.EnableMonitoring({ enabled = true })
```

Optional: You might add logging levels later if needed
```lua
NetRay.Debug.EnableMonitoring({ enabled = true, level = "verbose" })
```
:::info
Simply enabling monitoring makes NetRay *fire* the signals. You still need to connect listeners to these signals to actually see or act upon the information.
:::

## Debug Signals

Access signals under the `NetRay.Debug` table.

### 1. `NetRay.Debug.GlobalEvent`

This signal fires for a wide range of internal library events, providing a trace of operations.

```lua
NetRay.Debug.GlobalEvent:Connect(function(context, signalName, ...)
    -- context: "Server" or "Client"
    -- signalName: Name of the internal signal that fired
    -- ...: Arguments specific to that internal signal

    local args = {...}
    local argsString = ""
    -- Basic serialization of args for printing
    for i, v in ipairs(args) do
        argsString = argsString .. tostring(v) .. (i < #args and ", " or "")
    end

    print(`[NetRay GLOBAL|${context}] ${signalName}(${argsString})`)
end)
```

Example Output:
```lua
[NetRay GLOBAL|Server] EventRegistered(PlayerAction)
[NetRay GLOBAL|Client] RequestSent(GetInventory, {userId=123})
[NetRay GLOBAL|Server] EventFired(PlayerAction, Player1, {...})
[NetRay GLOBAL|Client] ThrottleExceeded(burst, 21, 20)
```

Internal signals proxied through `GlobalEvent` include (but may not be limited to):
*   `EventRegistered`, `EventFired`
*   `RequestSent`, `RequestReceived`
*   `RateLimitExceeded`, `ThrottleExceeded` (Client/Server Manager specific signals)
*   `CircuitBroken`, `CircuitReset` (Circuit Breaker signals)
*   `PlayerJoined`, `PlayerLeft` (Server Manager signals)

### 2. `NetRay.Debug.Error`

This signal fires when errors are caught within NetRay's core operations (e.g., middleware execution, message queue processing, internal pcalls).

```lua
NetRay.Debug.Error:Connect(function(context, source, ...)
    -- context: "Server" or "Client"
    -- source: Where the error originated (e.g., "Middleware", "ProcessMessage", "ServerManager", "ClientManager")
    -- ...: Error message(s) or details

    warn(`[NetRay ERROR|${context}] Source: ${tostring(source)} -`, ...)
end)
```
Example Output:
```
[NetRay ERROR|Client] Source: Middleware - [NetRay] Middleware error in 'BadValidator': attempt to index nil with 'userId'
[NetRay ERROR|Server] Source: ProcessMessage - Error processing queued message: ...
```

### 3. `NetRay.Debug.NetworkTraffic`

:::caution Placeholder
The `NetworkTraffic` signal is currently defined but acts as a **placeholder**. It is not automatically connected to measure actual network bytes sent/received. Implementing this would require deeper hooks into the `RemoteEvent/Function:Fire...` calls or estimates based on serialized data sizes just before sending.
:::

Example *conceptual* connection if traffic stats were implemented:
```lua
NetRay.Debug.NetworkTraffic:Connect(function(stats)
    print("NetRay Traffic - Sent/s:", stats.bytesSentPerSec, "Recv/s:", stats.bytesReceivedPerSec)
end)
```

## Monitoring Specific Components

You can often access internal components for more targeted monitoring.

### Circuit Breaker Signals

Monitor state changes or failures for a specific endpoint.

```lua
local cb = NetRay:GetCircuitBreaker("MyRiskyRequest")
if cb then
    cb.Signals.StateChanged:Connect(function(oldState, newState)
        warn(("Circuit Breaker 'MyRiskyRequest' state: %s -> %s"):format(oldState, newState))
    end)
    cb.Signals.FailureRecorded:Connect(function()
        print("Failure recorded for MyRiskyRequest circuit breaker.")
    end)
end
```

### Middleware Metrics

Access performance metrics for the middleware system. (Accessing `NetRay.Server/Client.Middleware` depends on implementation details, might not be stable public API).

```lua
-- Server side example (Assuming access path is stable)
task.delay(60, function()
    while true do
        if NetRay.Server and NetRay.Server.Middleware then
            local metrics = NetRay.Server.Middleware:GetMetrics()
            print("--- Middleware Metrics (Server) ---")
            print(" Executions:", metrics.totalExecutions)
            print(" Avg Time (ms):", metrics.avgExecutionTime and (metrics.avgExecutionTime * 1000) or "N/A")
            print(" Blocked:", metrics.blocked, " Errors:", metrics.errors)
            print(" Cache Hits:", metrics.cacheHits, " Misses:", metrics.cacheMisses)
            print("----------------------------------")
        end
        task.wait(60) -- Log every minute
    end)
end
```

## Example of Custom Event Handler with Debug Logging

```lua
-- Example of custom event handler with debug logging
local myEvent = NetRay:RegisterEvent("PlayerAction", {
    typeDefinition = { action = "string", data = "table" }
})

myEvent.OnServerEvent:Connect(function(player, action, data)
    -- Basic debug logging
    print("[Event] PlayerAction triggered by", player.Name)
    print("Action:", action)
    print("Data:", data)

    -- More detailed logging
    local args = {...}
    local argsString = ""
    -- Basic serialization of args for printing
    for i, v in ipairs(args) do
        argsString = argsString .. string.format("%s: %s", i, tostring(v))
        if i < #args then
            argsString = argsString .. ", "
        end
    end
    print("[Debug] Event arguments:", argsString)

    -- Process the event
    processPlayerAction(player, action, data)
end) 
```

## Tips for Debugging

1.  **Enable Debug Monitoring:** Start with `NetRay.Debug.EnableMonitoring({ enabled = true })`.
2.  **Use GlobalEvent:** Connect a listener to `GlobalEvent` to see the general flow of registrations, fires, and receives.
3.  **Check for Errors:** Monitor `NetRay.Debug.Error` for any internal issues caught by the library.
4.  **Validate Types:** If using type checking, ensure your definitions match the actual data being sent. Check warnings for validation failures.
5.  **Middleware Issues:** Add `print()` statements within your middleware functions to see the data at each stage and check if any middleware is incorrectly returning `false`.
6.  **Circuit Breakers:** Monitor the `StateChanged` signal of relevant circuit breakers if requests seem blocked unexpectedly. Use `cb:GetMetrics()`.
7.  **Client/Server Context:** Pay attention to the `context` ("Client" or "Server") provided in the debug signals to know where the event originated.