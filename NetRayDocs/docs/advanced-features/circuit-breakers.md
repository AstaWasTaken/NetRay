---
title: Circuit Breakers
---

# Circuit Breakers

The Circuit Breaker pattern is a crucial technique for building resilient networked systems. It prevents an application from repeatedly trying to execute an operation that's likely to fail, especially due to downstream service unavailability or errors. NetRay integrates Circuit Breakers to automatically manage the health of event/request endpoints.

## How it Works

A Circuit Breaker acts like an electrical circuit breaker, wrapping a protected function call (like sending a network request). It operates in three states:

1.  **CLOSED:** (Initial State) Requests are allowed to pass through. The breaker counts failures. If the failure count exceeds a threshold within a time window, the breaker trips and transitions to the **OPEN** state. Successes reset the failure count.
2.  **OPEN:** Requests are immediately rejected (or a fallback is executed) *without* attempting the network operation. This prevents overloading a struggling service. After a configured timeout (`resetTimeout`), the breaker transitions to **HALF_OPEN**.
3.  **HALF_OPEN:** A limited number of test requests are allowed through.
    *   If these requests succeed consistently (`halfOpenMaxRequests`), the breaker assumes the underlying issue is resolved and transitions back to **CLOSED**.
    *   If *any* test request fails, the breaker trips again, transitioning back to **OPEN** (often with an increased timeout - adaptive backoff).

## Configuration

Circuit Breaker behavior is configured *per event/request* within the `options` table during registration.

```lua
-- Example Server-Side Request Registration
local externalApiRequest = NetRay:RegisterRequestEvent("CallExternalAPI", {
    circuitBreaker = {
        -- Required settings:
        failureThreshold = 3,  -- Trip to OPEN after 3 consecutive/recent failures
        resetTimeout = 20,    -- Wait 20s in OPEN state before trying HALF_OPEN

        -- Optional settings:
        fallback = function(player, data)
            warn("External API circuit breaker is OPEN. Returning cached/default data for", player.Name)
            -- Return a default response or nil
            return { status = "cached", data = "Default Value" }
        end,
        halfOpenMaxRequests = 2, -- Allow 2 successful requests in HALF_OPEN to close
        adaptiveTimeouts = true, -- Automatically increase resetTimeout on repeated OPEN transitions (default true)
        minimumTimeout = 10,    -- Minimum resetTimeout value (seconds)
        maximumTimeout = 120,   -- Maximum resetTimeout value (seconds)
        -- healthCheckInterval = 0 -- Interval to try HALF_OPEN early (disabled by default)
    }
})
```

### Example Client-Side Event Registration (client making calls)
```lua
local criticalServerAction = NetRay:RegisterEvent("DoCriticalAction", {
    circuitBreaker = {
        failureThreshold = 5,
        resetTimeout = 30,
        fallback = function(data) -- Fallback when Client attempts :FireServer()
            warn("Circuit for 'DoCriticalAction' is OPEN. Action blocked.")
            -- Maybe show UI feedback? Do nothing?
        end
    }
})
```

### Key Configuration Options:

*   `failureThreshold`: Number of failures required to trip the breaker (default: 5).
*   `resetTimeout`: Duration (seconds) the breaker stays OPEN before entering HALF_OPEN (default: 30).
*   `fallback`: (Optional) A function executed *instead* of the network call when the circuit is OPEN. Should match the signature of the intended call (e.g., `fallback(player, data)` for server-side request handler, `fallback(data)` for client event sender). If it returns a value, that value is returned to the caller (useful for requests).
*   `halfOpenMaxRequests`: Number of successful calls required in HALF_OPEN state to fully close the circuit (default: 1).
*   `adaptiveTimeouts`: If true (default), `resetTimeout` increases automatically (up to `maximumTimeout`) if the circuit re-opens quickly after entering HALF_OPEN.
*   `minimumTimeout`, `maximumTimeout`: Clamp the effective `resetTimeout` value (used with adaptive timeouts).

## Monitoring

You can access the Circuit Breaker instance for an event/request and monitor its state changes.

```lua
-- Get the breaker instance
local cb = NetRay:GetCircuitBreaker("CallExternalAPI")

if cb then
    -- Check current state
    print("Current State:", cb.State) -- "CLOSED", "OPEN", "HALF_OPEN"

    -- Connect to state changes
    cb.Signals.StateChanged:Connect(function(oldState, newState)
        warn(("Circuit Breaker 'CallExternalAPI' changed state: %s -> %s"):format(oldState, newState))
    end)

    -- Connect to other signals if needed
    cb.Signals.FailureRecorded:Connect(function() print("CB Failure Recorded!") end)
    cb.Signals.Recovered:Connect(function(recoveryTime) print("CB Recovered in", recoveryTime, "s") end)

    -- Get detailed metrics
    local metrics = cb:GetMetrics()
    print("Total Failures:", metrics.totalFailures)
    print("Open Count:", metrics.openCount)
end
```

## Manual Control

You can force a specific state if needed for testing or administrative purposes.

```lua
-- Get the breaker instance
local cb = NetRay:GetCircuitBreaker("MyEvent")
if cb then
    -- Force open for maintenance/testing
    cb:ForceState(CircuitBreaker.State.OPEN) -- Use the internal State enum constant

    -- Force closed to reset manually
    -- cb:ForceState(CircuitBreaker.State.CLOSED)
end
```

:::info
Note that NetRay's circuit breaker currently tracks failures primarily based on *network-level* or *handler execution* errors (like timeouts in requests, or `error()` calls within request handlers). It doesn't automatically track "logical" failures (e.g., a request completing successfully but returning `{success = false}`). Logical failures need to be handled in your application code.
::: 