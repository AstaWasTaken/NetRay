---
title: Event Priorities
---

# Event Priorities

NetRay allows you to assign priorities to events (`RegisterEvent`), influencing the order in which they are processed on the **receiving client**. This helps ensure that critical updates are handled promptly, even under high network load, while less important events (like background logging) can be deferred slightly.

:::info Client-Side Processing Only
Priority affects the **client-side processing queue** when events are *received* from the server. It does not directly affect the order events are sent by the server or processed when received *by* the server from a client.
:::

## Priority Levels

NetRay defines several priority levels available via `NetRay.Priority`:

| Constant         | Value | Description                                                               |
| ---------------- | ----- | ------------------------------------------------------------------------- |
| `CRITICAL`       | `0`   | Highest priority. Processed almost immediately. Use very sparingly.        |
| `HIGH`           | `1`   | Important events (e.g., player state changes, crucial UI updates).        |
| `NORMAL`         | `2`   | Default priority for most events (e.g., chat messages, standard actions). |
| `LOW`            | `3`   | Less important updates (e.g., ambient effects, non-critical stats).     |
| `BACKGROUND`     | `4`   | Lowest priority. Processed when the system has spare capacity (e.g., analytics). |

Lower numerical values indicate higher priority.

## Usage

Specify the priority level in the `options` table when registering an event **on the server**:

Server Script

Register events with different priorities

```lua
local criticalHealthUpdate = NetRay:RegisterEvent("CritHealthSync", {
    priority = NetRay.Priority.CRITICAL,
    typeDefinition = { targetId="number", health="number" }
})

local playerHealth = NetRay:RegisterEvent("PlayerHealthUpdate", {
    priority = NetRay.Priority.CRITICAL,
    typeDefinition = { targetId="number", health="number" }
})

local playerMovement = NetRay:RegisterEvent("PlayerMove", {
    priority = NetRay.Priority.HIGH,
    typeDefinition = { position="Vector3", velocity="Vector3" }
})

local ambientSoundEvent = NetRay:RegisterEvent("AmbientSound", {
    priority = NetRay.Priority.LOW,
    typeDefinition = { soundId="string", position="Vector3" }
})

local analyticsEvent = NetRay:RegisterEvent("LogAction", {
    priority = NetRay.Priority.BACKGROUND,
    typeDefinition = { actionName="string" }
})
```

Later, when firing these events...

```lua
criticalHealthUpdate:FireClient(player, {...})
playerMovement:FireAllClients({...})
ambientSoundEvent:FireFilteredClients(filterFn, {...})
analyticsEvent:FireClient(player, {...})
```

## Client-Side Processing

On the client (`ClientManager`), incoming events are placed into different processing queues based on the priority set during their server-side registration. The `ClientManager` processes these queues, giving preference to higher-priority messages:

-   **Critical (0):** Processed immediately whenever found.
-   **High (1):** A batch is processed frequently.
-   **Normal (2):** A smaller batch is processed frequently.
-   **Low (3) / Background (4):** Processed less frequently, probabilistically, to avoid starving lower-priority tasks completely while ensuring higher-priority tasks are favored.

## When to Use Priorities

-   Use `CRITICAL` *only* for events that absolutely must be processed with minimal delay, where even a few frames of lag are unacceptable (e.g., immediate hit registration feedback, critical state synchronization failure recovery). Overuse will degrade performance.
-   Use `HIGH` for important gameplay events impacting immediate player experience (movement, ability activation feedback, damage notifications).
-   Use `NORMAL` as the default for most standard interactions.
-   Use `LOW` for background visual/audio effects or non-essential updates.
-   Use `BACKGROUND` for telemetry, analytics, or logging that can be delayed significantly without impacting gameplay.

:::note
Prioritization helps manage load on the *client*. It does not guarantee network delivery order or reduce absolute latency. Network conditions can still cause events to arrive out of order, although batching might group related events.
:::