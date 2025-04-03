---
title: Type Checking
---

# Type Checking

NetRay includes an optional, built-in type checking system to help ensure the integrity of data sent over the network. By defining the expected structure and types for your events and requests, NetRay can automatically validate incoming payloads, catching potential errors early.

## Defining Types

Type definitions are provided as tables within the `options` argument when registering an event or request.

*   `typeDefinition`: Validates data received by `OnEvent`.
*   `requestTypeDefinition`: Validates data received by `OnRequest`.
*   `responseTypeDefinition`: Validates the data *returned* from an `OnRequest` handler before sending it back.

The keys of the definition table are the expected field names in your data payload. The values are strings defining the expected type.

```lua
-- Example for RegisterEvent or RegisterRequestEvent options
local eventOptions = {
    typeDefinition = {
        id = "number",                     -- Must be a number
        name = "string",                   -- Must be a string
        level = "?number",                 -- Optional number (can be nil or number)
        position = "Vector3",              -- Must be a Vector3
        isActive = "boolean",              -- Must be a boolean
        inventory = "Array<number>",       -- Must be an array where all elements are numbers
        config = "Dict<string, any>",     -- Dictionary with string keys, any value type
        target = "Instance<BasePart>|nil" -- Must be a BasePart instance OR nil
    }
}

local requestOptions = {
    requestTypeDefinition = {
        action = "string"
    },
    responseTypeDefinition = {
        status = "string",
        timestamp = "number"
    }
}
```

## Supported Type Strings

NetRay's `TypeChecker` supports a range of type definitions:

| Type String             | Description                                        | Example Value               |
| ----------------------- | -------------------------------------------------- | --------------------------- |
| `string`                | Standard Lua string                                | `"hello"`                   |
| `number`                | Standard Lua number (integer or float)             | `123`, `3.14`               |
| `boolean`               | Standard Lua boolean                               | `true`, `false`             |
| `nil`                   | Must be `nil`                                      | `nil`                       |
| `table`                 | Any Lua table (use `array`, `Dict` for specifics)  | `{}`                        |
| `function`              | A Lua function (rarely needed over network)        | `function() end`            |
| `userdata`              | Any Roblox userdata (use specific types below)     | `Instance.new("Part")`      |
| `thread`                | A Lua thread/coroutine                             | `coroutine.create(...)`     |
| `any`                   | Allows any type (bypasses checking)                | (Any value)                 |
| `?typeName`             | Optional: Allows `nil` or `typeName`             | `nil`, `"world"` for `?string`|
| `type1\|type2`          | Union: Allows `type1` or `type2`                 | `10` or `"ten"` for `number|string` |
| `Vector2`               | Roblox Vector2                                     | `Vector2.new(1, 2)`         |
| `Vector3`               | Roblox Vector3                                     | `Vector3.new(1, 2, 3)`      |
| `CFrame`                | Roblox CFrame                                      | `CFrame.new()`              |
| `Color3`                | Roblox Color3                                      | `Color3.new(1, 0, 0)`       |
| `BrickColor`            | Roblox BrickColor                                  | `BrickColor.Red()`          |
| `UDim`                  | Roblox UDim                                        | `UDim.new(0, 10)`           |
| `UDim2`                 | Roblox UDim2                                       | `UDim2.new(0, 10, 1, 0)`    |
| `Rect`                  | Roblox Rect                                        | `Rect.new(0, 0, 10, 10)`    |
| `Region3`               | Roblox Region3                                     | `Region3.new(v1, v2)`       |
| `NumberSequence`        | Roblox NumberSequence                              | `NumberSequence.new(0)`     |
| `ColorSequence`         | Roblox ColorSequence                               | `ColorSequence.new(c3)`     |
| `EnumItem`              | Any Roblox EnumItem                                | `Enum.KeyCode.E`            |
| `buffer`                | Roblox buffer type                                 | `buffer.create(10)`         |
| `Instance`              | Any Roblox Instance                                | `Instance.new("Part")`      |
| `Instance<ClassName>`   | Specific Roblox Instance type or descendant      | Part matches `Instance<BasePart>` |
| `Array<ItemType>`       | Table with sequential int keys, all values match `ItemType` | `{1, 2}` for `Array<number>` |
| `Dict<KeyType, ValType>`| Table where all keys match `KeyType`, values match `ValType` | `{ a=1 }` for `Dict<string, number>` |

*Note: Nested types like `Array<Dict<string, ?number>>` are supported.*

## How Validation Works

-   When NetRay receives data associated with a `typeDefinition` (or req/res variants):
    1.  It checks if all non-optional keys defined in the schema are present in the received data.
    2.  For each present key, it verifies the value's type against the corresponding type string in the schema using `TypeChecker.isType`.
-   If validation fails:
    *   An informative warning is printed to the console (by default).
    *   The `OnEvent` or `OnRequest` handler associated with that specific event/request instance **will not execute** for that particular invalid payload. Processing of other valid payloads continues normally.
    *   For `RequestClient`, a validation failure before sending will `reject` the Promise.
    *   For `ClientEvent`, a validation failure before sending will `error`.

## Benefits

-   **Catch Errors Early:** Identify incorrect data structures during development or testing.
-   **Improve Reliability:** Prevent handlers from processing malformed data, reducing runtime errors.
-   **Code Clarity:** Type definitions serve as documentation for your network interfaces.

## Limitations

-   **Performance:** Validation adds a small overhead. While cached, complex validation on very frequent events might be noticeable. Profile if needed.
-   **Strictness:** The default behavior is to warn and drop the message on failure. Currently, there isn't a built-in option to configure strict erroring instead of warnings on receive (though sending errors/rejects). This could potentially be added or implemented via Middleware.
-   **`any` Type:** Use `any` sparingly, as it bypasses type checking for that field.