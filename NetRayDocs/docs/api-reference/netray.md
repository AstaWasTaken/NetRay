---
title: NetRay Module
---

# API: NetRay Module

The main `NetRay` module serves as the entry point for accessing all library features.

## Properties

### `NetRay.Version: string`
Returns the current version string of the NetRay library (e.g., `"1.0.0"`).

### `NetRay.Priority: table<string, number>`
A table containing constants representing priority levels used for client-side event processing. Lower values mean higher priority.
*   `CRITICAL`: 0
*   `HIGH`: 1
*   `NORMAL`: 2 (Default)
*   `LOW`: 3
*   `BACKGROUND`: 4

### `NetRay.Debug: table`
Contains signals and functions for debugging and monitoring.
*   `Debug.GlobalEvent: SignalPlus`
    *   Fires for various internal library events.
    *   Args: `(context: "Server" | "Client", signalName: string, ...)`
*   `Debug.Error: SignalPlus`
    *   Fires when internal errors are caught.
    *   Args: `(context: "Server" | "Client", source: string, ...)`
*   `Debug.NetworkTraffic: SignalPlus`
    *   (Currently Placeholder) Intended for network statistics.
    *   Args: `(stats: table)`
*   `Debug.EnableMonitoring(options: { enabled: boolean }): boolean`
    *   Enables or disables the firing of the `GlobalEvent` and `Error` debug signals. Returns the `enabled` state.

### Server-Only Properties
### `NetRay.Server: ServerManager`
(Available only in a server context) Provides access to the server-side management instance. Internal use primarily.

### Client-Only Properties
### `NetRay.Client: ClientManager`
(Available only in a client context) Provides access to the client-side management instance. Internal use primarily.

### Shared Modules
### `NetRay.Utils: Utilities`
### `NetRay.Errors: Errors`
### `NetRay.Serializer: Serializer`
### `NetRay.TypeChecker: TypeChecker`
Provides access to shared internal utility modules. Their direct use might change between versions; rely on the main NetRay API where possible.

## Methods

### `NetRay:RegisterEvent(eventName: string, options: table?): ServerEvent | ClientEvent`
*Context: Server, Client*
Registers a new unidirectional event endpoint or retrieves an existing one. Returns the corresponding `ServerEvent` or `ClientEvent` instance.
*   `eventName`: A unique string identifier for the event.
*   `options`: (Optional) A table containing configuration for the event. Common options:
    *   `typeDefinition: table?`: Schema for type validation.
    *   `priority: number?`: Client processing priority (using `NetRay.Priority` constants). Default `NORMAL`.
    *   `compression: boolean?`: Hint to attempt compression.
    *   `batchable: boolean?`: Allow server->client batching (default `true`).
    *   `circuitBreaker: table?`: Configuration for a circuit breaker (see CircuitBreaker API).
    *   `rateLimit: table?`: (Server Only - within options) - See ServerManager. `maxRequests`, `timeWindow`, etc.

### `NetRay:RegisterRequestEvent(eventName: string, options: table?): RequestServer | RequestClient`
*Context: Server, Client*
Registers a new bidirectional request/response endpoint or retrieves an existing one. Returns `RequestServer` or `RequestClient`.
*   `eventName`: A unique string identifier for the request.
*   `options`: (Optional) A table containing configuration. Common options:
    *   `requestTypeDefinition: table?`: Schema for the request payload.
    *   `responseTypeDefinition: table?`: Schema for the response payload.
    *   `compression: boolean?`: Hint to attempt compression.
    *   `timeout: number?`: Request timeout in seconds (default 10).
    *   `circuitBreaker: table?`: Configuration for a circuit breaker.
    *   `rateLimit: table?`: (Server Only - within options)

### `NetRay:RegisterMiddleware(name: string, middlewareFn: function, priority: number?)`
*Context: Server, Client*
Registers a global middleware function that intercepts events and requests.
*   `name`: A unique name for the middleware.
*   `middlewareFn`: The handler function `(eventName, player, data) -> data | nil | false`.
*   `priority`: Execution order (lower runs first, default 100).

### `NetRay:GetCircuitBreaker(eventName: string): CircuitBreaker?`
*Context: Server, Client*
Retrieves the Circuit Breaker instance associated with a registered event or request name, if one was configured. Returns `nil` if no breaker exists for that name.

### `NetRay:GetEvent(eventName: string): ClientEvent`
*Context: Client Only*
Convenience method on the client to get or register a `ClientEvent`. Primarily useful for getting a reference to fire events to the server or listen for events from the server.