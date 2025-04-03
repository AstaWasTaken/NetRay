---
title: Optimizations (Batching & Compression)
---

# Optimizations: Batching & Compression

NetRay incorporates automatic optimizations to improve network efficiency, primarily managed by the internal `DynamicSender` module.

## 1. Event Batching

### How it Works

When the server sends multiple events to the same client (or group of clients via `FireAllClients`, `FireFilteredClients`) using the same `RemoteEvent` within a short timeframe, NetRay can automatically **batch** these individual events into a single, larger network packet.

Instead of firing the underlying `RemoteEvent` multiple times:

`FireClient(p, data1) -> Network Packet 1`
`FireClient(p, data2) -> Network Packet 2`
`FireClient(p, data3) -> Network Packet 3`

NetRay's `DynamicSender` might do this:

`FireClient(p, data1)` -> *Queued*
`FireClient(p, data2)` -> *Queued*
`FireClient(p, data3)` -> *Queued* -> *Threshold reached or timer expired* -> `InternalFire(p, [data1, data2, data3]) -> Network Packet (Batch)`

### Benefits

-   **Reduces Overhead:** Each `RemoteEvent:FireClient` or `FireAllClients` call has a small network overhead. Batching significantly reduces this overhead when sending many small, frequent updates (like player position).
-   **Improves Throughput:** Sending fewer, larger packets can be more efficient under certain network conditions.

### Configuration

Batching behavior is controlled by:

1.  **`DynamicSender.Config` (Internal - in `Shared/DynamicSender.lua`):**
    *   `BatchingEnabled`: `true` or `false` to globally enable/disable.
    *   `BatchInterval`: How often (seconds) to check pending batches (e.g., `0.03`).
    *   `MaxBatchSize`: Max number of events per remote before sending immediately (e.g., `15`).
    *   `MaxBatchWait`: Max time (seconds) an event can wait before its batch is sent (e.g., `0.05`).
2.  **`RegisterEvent` Option:**
    *   `batchable`: Set to `false` in event options to *prevent* a specific event type from ever being batched (e.g., for critical, must-be-sent-now events). Default is `true`.

This event might be batched with others of the same type
```lua
NetRay:RegisterEvent("FrequentUpdate", { batchable = true })
```

This event will always be sent immediately, never batched
```lua
NetRay:RegisterEvent("CriticalAlert", { batchable = false })
```

## 2. Data Compression

### How it Works

NetRay uses the `DataCompression` module (implementing LZW algorithm) via the `Compressor` wrapper to optionally compress payloads before sending them.

1.  **Estimate Size:** Before sending, `DynamicSender` estimates the size of the data payload.
2.  **Threshold Check:** If the estimated size exceeds `DynamicSender.Config.CompressionThreshold`, compression is attempted. Configuration flags like `ForceCompressBatches` can also trigger this.
3.  **Compression Attempt:** The `Compressor:Compress` function (using `DataCompression`) is called.
4.  **Benefit Check:** The system compares the size of the *final serialized compressed data* against the size of the *final serialized original data*. It chooses whichever results in a smaller final network packet.
5.  **Header Marking:** A special marker byte is prepended to the data indicating whether it's compressed and whether it's a single item or a batch.
6.  **Sending:** The chosen payload (original or compressed, serialized to a buffer) is sent.
7.  **Receiving:** The receiver reads the marker byte, deserializes the payload, and decompresses it if the marker indicates compression was used.

### Benefits

-   **Reduced Bandwidth:** Can significantly decrease the amount of data sent over the network, especially for large text-based data or repetitive structures. This saves server bandwidth and can improve experience for players on slower connections.

### Configuration

-   **`DynamicSender.Config` (Internal - in `Shared/DynamicSender.lua`):**
    *   `CompressionThreshold`: Estimated byte size to trigger compression attempts (e.g., `256`). Set to `0` or `-1` to potentially disable threshold-based compression (but `ForceCompress` flags might still apply).
    *   `ForceCompressBatches`: If `true`, always attempt compression on data marked as a batch.
    *   `ForceCompressSingle`: If `true`, always attempt compression on single-item sends.
-   **`RegisterEvent` / `RegisterRequestEvent` Option:**
    *   `compression`: `true` or `false`. This acts as a *hint*. If `true`, NetRay is more likely to *attempt* compression even if slightly below the threshold (the final size check still applies). If `false`, compression might be skipped even if above the threshold (depending on `ForceCompress` flags).

:::note
Compression adds CPU overhead on both the sender and receiver. NetRay attempts to only compress when the potential bandwidth saving outweighs the CPU cost, but the effectiveness depends heavily on the *type* of data being sent. Binary data or already compressed data often won't compress well further. Text and repetitive table structures usually benefit most.
:::

## 3. Binary Serialization

NetRay utilizes a custom binary serialization format (implemented in `Shared/Serializer.lua` and `Shared/Types/*`) instead of relying solely on Roblox's built-in serialization or JSON.

### Benefits

-   **Efficiency:** Custom binary formats can be significantly more compact than general-purpose formats like JSON for Roblox data types (Vector3, CFrame, Color3, etc.) and common Lua types (small integers, booleans).
-   **Type Information:** The format inherently includes type identifiers, allowing for precise reconstruction of data types on the receiving end without ambiguity.

This optimization is applied automatically whenever data is sent through NetRay events or requests.