---
sidebar_position: 3
title: Configuration
---

# Configuration

Configure NetRay's behavior for debugging, performance, and specific features.

## Global Debug Monitoring

Enable verbose logging of internal NetRay operations by enabling debug monitoring. This helps track event flow and identify issues.

### Enable standard monitoring (e.g., in a shared initialization script or both client/server main scripts)
```lua
NetRay.Debug.EnableMonitoring({ enabled = true })
```

### Connect listeners to see the output (see Debugging guide for examples)
```lua
NetRay.Debug.GlobalEvent:Connect(function(context, signalName, ...)
    print(`[NetRay Debug - ${context}] ${signalName}:`, ...)
end)
```

:::info
Enabling monitoring makes NetRay fire its `Debug` signals. You must still `:Connect()` to these signals (`NetRay.Debug.GlobalEvent`, `NetRay.Debug.Error`) to observe the logs.
:::

## Dynamic Sender (Internal Options)

The `DynamicSender` module manages automatic optimizations like batching and compression. Its configuration parameters are currently located directly within the `Shared/DynamicSender.lua` script file.

To adjust these settings, you would need to modify the `NetRaySender.Config` table inside that file.

```lua
-- Example configuration for NetRaySender
NetRaySender.Config = {
    BatchingEnabled = true,       -- Enable/disable automatic event batching
    BatchInterval = 0.03,         -- Time (seconds) between sending queued batches
    MaxBatchSize = 15,            -- Max events in a batch before forced sending
    MaxBatchWait = 0.05,          -- Max time (seconds) an event waits before batch is sent
    RetryAttempts = 3,            -- Number of times to retry failed sends
    RetryDelay = 0.5,             -- Delay (seconds) between retry attempts
    CompressionEnabled = true      -- Enable/disable data compression
}
```

:::danger Modifying Internals
Directly editing library files makes updating NetRay harder later. A future version might expose these configurations through a top-level API.
:::

## Event and Request Options

Most configurations like type safety schemas, compression hints, priorities, and circuit breakers are specified directly when you register an Event or Request using `NetRay:RegisterEvent` or `NetRay:RegisterRequestEvent`.

### Example Registration with Options
```lua
local playerUpdateEvent = NetRay:RegisterEvent("PlayerPositionUpdate", {
-- Feature Configurations:
    priority = NetRay.Priority.HIGH,           -- Process quickly on client
    batchable = true,                          -- Allow this event to be batched (default)
    compression = true,                        -- Hint to try compressing large payloads
    typeDefinition = {                         -- Enforce data structure
        position = "Vector3",
        rotationY = "number",
        state = "string|nil",
    },
    circuitBreaker = {                         -- Configure fault tolerance
        failureThreshold = 5,
        resetTimeout = 30,
    },
    -- Note: rateLimit is part of ServerManager options, not RegisterEvent directly
    -- Apply rate limits using middleware or modify ServerManager initialization if needed.
})

-- Example: Request with circuit breaker
local apiRequest = NetRay:RegisterRequestEvent("FetchPlayerData", {
    circuitBreaker = {
        failureThreshold = 3,
        resetTimeout = 30
    }
})
```

Refer to the guides on [Events](./core-concepts/events.md), [Requests](./core-concepts/requests.md), and the specific [Advanced Features](./advanced-features/middleware.md) for details on their respective options.
