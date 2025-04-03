---
title: Requests (Request/Response)
---

# Core Concepts: Requests

Requests in NetRay handle two-way communication where a response is expected, replacing the need for `RemoteFunction`. They utilize Promises for cleaner asynchronous code flow.

## Key Features

-   **Asynchronous:** Uses a `Promise` API (`.andThen()`, `.catch()`, `.finally()`) avoiding yields.
-   **Type Safety:** Define expected structures for *both* the request and response using `requestTypeDefinition` and `responseTypeDefinition`.
-   **Timeouts:** Configure maximum wait times for responses (`timeout`).
-   **Reliability:** Integrate with Circuit Breakers (`circuitBreaker` option) to handle failing endpoints gracefully.
-   **Compression:** Automatic compression for large request/response payloads.

## Server-Side Usage

### Registering a Request Event

Define a request endpoint using `NetRay:RegisterRequestEvent(eventName, options?)` on the server.
```lua
-- Server Script
local shopPurchaseRequest = NetRay:RegisterRequestEvent("PurchaseItem", {
    requestTypeDefinition = {
        itemId = "number",
        quantity = "number"
    },
    responseTypeDefinition = {
        success = "boolean",
        message = "?string",       -- Optional message (e.g., error reason)
        newBalance = "?number"    -- Optional updated currency balance
    },
    circuitBreaker = { failureThreshold = 5, resetTimeout = 30 }, -- Example
    timeout = 8 -- Server timeout for server->client invoke (less common)
    })
```

### Handling Client Requests

Use `:OnRequest(callback)` to define the function that processes requests and returns data. The function's return value (or error) resolves/rejects the client's Promise.
```lua
-- Server Script
local PlayerData = require(game.ServerStorage.PlayerData) -- Your player data module
local ShopItems = require(game.ServerStorage.ShopItems)   -- Your shop item definitions

shopPurchaseRequest:OnRequest(function(player, data)
-- 'player' is the client making the request
-- 'data' is the validated request payload

local itemId = data.itemId
-- Validate quantity, default to 1 if invalid/missing from payload
local quantity = (type(data.quantity) == "number" and data.quantity > 0) and math.floor(data.quantity) or 1

local itemInfo = ShopItems:GetInfo(itemId)
if not itemInfo then
    error("Invalid item ID: " .. tostring(itemId)) -- Goes to client .catch()
end

local currentCoins = PlayerData:GetCoins(player.UserId)
local totalCost = itemInfo.Price * quantity

if currentCoins < totalCost then
    -- Returning a table indicates success to the Promise, client must check 'success' field
    return { success = false, message = "Insufficient coins." }
end

-- Attempt purchase transaction
local purchaseOk, failureReason = PlayerData:PurchaseItem(player.UserId, itemId, quantity, totalCost)

if not purchaseOk then
    -- Can return failure status or throw error
    return { success = false, message = "Transaction failed: " .. (failureReason or "Unknown") }
    -- Alternatively: error("Transaction failed: " .. (failureReason or "Unknown"))
end

local newBalance = PlayerData:GetCoins(player.UserId)

-- Purchase successful, goes to client .andThen()
return {
    success = true,
    message = "Purchased " .. quantity .. "x " .. itemInfo.Name,
    newBalance = newBalance
}
end)
```

### Invoking Requests on Clients (Server -> Client)

Server can request information from a specific client.
```lua
-- Server Script
local getClientInputMode = NetRay:RegisterRequestEvent("GetClientInputMode", {
    responseTypeDefinition = { inputMode = "string" } -- e.g., "KeyboardMouse", "Gamepad", "Touch"
})

-- In some server logic:
local function checkInputMode(player)
    print("Requesting input mode from", player.Name)
    getClientInputMode:Request(player, {}) -- Send empty table if no data needed
        :andThen(function(response)
            print(("%s is using: %s"):format(player.Name, response.inputMode))
            -- Use the info...
        end)
        :catch(function(err)
            warn(("Failed to get input mode from %s: %s"):format(player.Name, err))
            -- Handle failure, maybe assume default?
        end)
end
```

## Client-Side Usage

### Getting/Registering a Request Event

Use `NetRay:RegisterRequestEvent(eventName, options?)` on the client to get a reference for making requests *to* the server or handling requests *from* the server.
```lua
-- Client Script
-- Define reference and potentially client-side timeout for server response
local purchaseItemRequest = NetRay:RegisterRequestEvent("PurchaseItem", {
    timeout = 15 -- Wait max 15s for server to respond
})
```

### Making Requests to Server

Use `:Request(data)`, which returns a `Promise`. Chain `.andThen(successCallback)` and `.catch(errorCallback)`.
```lua
-- Client Script
local ShopInterface = {} -- Your shop UI module
ShopInterface.SetLoadingState = function(self, isLoading) print("Shop loading state:", isLoading) end -- Placeholder

function ShopInterface:TryPurchase(itemId, quantity)
    print(("Attempting purchase: Item %d, Quantity %d"):format(itemId, quantity))
        self:SetLoadingState(true) -- Update UI

        purchaseItemRequest:Request({ itemId = itemId, quantity = quantity })
            :andThen(function(response)
                -- Server's response ('return' value from :OnRequest)
                if response.success then
                    print("Purchase successful!", response.message)
                    -- Update coin display: ShopInterface:UpdateCoinDisplay(response.newBalance)
                else
                    warn("Purchase failed:", response.message or "No reason given.")
                    -- Show failure message in UI
                end
            end)
            :catch(function(errorMessage)
                -- Catches errors from the server (error() call in handler),
                -- network timeouts, circuit breaker blocks, etc.
                warn("Error during purchase request:", errorMessage)
                -- Show a generic error message in UI
            end)
            :finally(function()
                -- Runs whether the request succeeded or failed
                print("Purchase request finished.")
                self:SetLoadingState(false) -- Update UI
            end)
end
```

### Example Usage (e.g., connected to a Buy button)
```lua  
ShopInterface:TryPurchase(101, 1)
ShopInterface:TryPurchase(102, 5)
ShopInterface:TryPurchase(999, 1) -- Example invalid item
```
### Handling Server Requests (Client -> Server Response)

Define a handler using `:OnRequest(callback)` for requests initiated *by* the server.
```lua
-- Client Script
local UserInputService = game:GetService("UserInputService")
local getClientInputMode = NetRay:RegisterRequestEvent("GetClientInputMode")

getClientInputMode:OnRequest(function(dataFromServer)
    print("Server requested client input mode. Data received:", dataFromServer)

    local inputMode = "KeyboardMouse" -- Default
    if UserInputService.TouchEnabled and not UserInputService.MouseEnabled then
        inputMode = "Touch"
    elseif UserInputService.GamepadEnabled then
        local connectedGamepads = UserInputService:GetConnectedGamepads()
        if #connectedGamepads > 0 then
            inputMode = "Gamepad"
        end
    end

    -- Return value is sent back to the server's .andThen()
    return {
        inputMode = inputMode
    }
end)
```
    
### Example Request Registration

```lua
-- Example of request registration
local purchaseRequest = NetRay:RegisterRequestEvent("PurchaseItem", {
    requestTypeDefinition = {
        itemId = "number",
        quantity = "number"
    },
    responseTypeDefinition = {
        success = "boolean",
        message = "string",
        newItemId = "?number" -- Optional return value
    }
})

-- Server-side handler
purchaseRequest.OnServerInvoke = function(player, requestData)
    -- Validate request
    if requestData.quantity <= 0 then
        return { success = false, message = "Quantity must be positive" }
    end

    -- Process purchase
    local success, itemId = processPurchase(player, requestData.itemId, requestData.quantity)
    return {
        success = success,
        message = success and "Purchase successful" or "Purchase failed",
        newItemId = itemId
    }
end
```