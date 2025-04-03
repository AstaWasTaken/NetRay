---
title: API Reference - CircuitBreaker
---

# API: CircuitBreaker

Provides fault tolerance for network operations associated with specific NetRay Events or Requests. Obtained via `NetRay:GetCircuitBreaker(eventName)`.

## Properties

### `State: string` (Read Only)
The current state of the circuit breaker:
*   `"CLOSED"`: Normal operation, requests allowed.
*   `"OPEN"`: Tripped due to failures, requests blocked (or fallback used).
*   `"HALF_OPEN"`: Allowing limited test requests after timeout to check recovery.

### `FailureCount: number` (Read Only)
The current count of consecutive or recent failures tracked while in the `CLOSED` state. Reset upon success or transition to `OPEN`.

### `Options: table` (Read Only)
The configuration options table provided during registration (or defaults). Includes `failureThreshold`, `resetTimeout`, `fallback`, etc.

### `Signals: table` (Read Only)
A table containing `SignalPlus` instances for monitoring:
*   `StateChanged`: Fires when the state transitions. Args: `(oldState: string, newState: string)`
*   `FailureRecorded`: Fires each time `:RecordFailure()` is called internally. Args: `()`
*   `SuccessRecorded`: Fires each time `:RecordSuccess()` is called internally. Args: `()`
*   `Recovered`: Fires when transitioning from `HALF_OPEN` back to `CLOSED`. Args: `(recoveryTime: number)`

## Methods

### `:IsAllowed(): boolean`
Checks if a request should be allowed based on the current state.
*   Returns `true` if state is `CLOSED`.
*   Returns `true` if state is `HALF_OPEN` and `HalfOpenRequestCount < Options.halfOpenMaxRequests`.
*   Returns `false` if state is `OPEN` and the timeout hasn't expired.
*   Returns `false` if state is `HALF_OPEN` and the request limit has been reached.
*   *(May transition OPEN -> HALF_OPEN internally if timeout expired)*

### `:Execute(fn: function, ...args): any | nil`
Wraps a function call with circuit breaker protection. Use this if you want the breaker to automatically record success/failure based on the function's execution.
*   If allowed, calls `fn(...args)`.
    *   If `fn` executes successfully, calls `:RecordSuccess()` and returns the result.
    *   If `fn` throws an error, calls `:RecordFailure()` and either re-throws the error or returns the result of the configured `fallback` function (if any).
*   If not allowed (`:IsAllowed()` is false), immediately calls the `fallback` function (if configured) and returns its result, otherwise throws a "Circuit breaker is open" error.

Example:
```lua
local cb = NetRay:GetCircuitBreaker("MyRequest")
local function makeApiCall(param)
    -- Simulate API call that might fail
    if math.random() < 0.3 then error("API Failed") end
    return "API Success: " .. param
end

-- Protected call
local ok, result = pcall(cb.Execute, cb, makeApiCall, "TestData") -- Use pcall to catch fallback errors too
if ok then
    print("Result:", result) -- Might be API success or fallback value
else
    warn("Execution failed or breaker open with no fallback:", result)
end
```

### `:RecordSuccess()`
Manually informs the breaker that an operation succeeded. If in `HALF_OPEN` state, increments consecutive success count, potentially closing the circuit. If in `CLOSED` state, resets `FailureCount`. Typically called internally by NetRay or `:Execute()`.

### `:RecordFailure()`
Manually informs the breaker that an operation failed. If in `CLOSED` state, increments `FailureCount`, potentially tripping to `OPEN`. If in `HALF_OPEN` state, immediately trips back to `OPEN` (possibly with increased timeout). Typically called internally by NetRay or `:Execute()`.

### `:ForceState(state: string)`
Manually sets the circuit breaker's state. Useful for testing or administrative actions.
*   `state`: Must be one of `"CLOSED"`, `"OPEN"`, `"HALF_OPEN"`. (Use `CircuitBreaker.State.X` constants if available/exposed).

### `:GetMetrics(): table`
Returns a table containing various performance and state metrics for the circuit breaker instance, such as `totalFailures`, `totalSuccesses`, `openCount`, `averageRecoveryTime`, `currentState`, etc.