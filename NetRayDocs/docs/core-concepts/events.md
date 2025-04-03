---
title: Events (Fire-and-Forget)
---

# Core Concepts: Events

Events in NetRay are unidirectional, "fire-and-forget" messages, analogous to Roblox's `RemoteEvent`. Use them to broadcast information or trigger actions where an immediate response isn't required.

## Key Features

-   **Type Safety:** Optionally define data structures (`typeDefinition`) for automatic validation upon receiving.
-   **Prioritization:** Control client-side processing order using `priority` levels.
-   **Batching:** Server-to-client events are automatically grouped (`batchable = true`) to reduce network calls.
-   **Compression:** Large payloads may be automatically compressed (`compression = true`) by the `DynamicSender`.

## Server-Side Usage

### Registering an Event

Use `NetRay:RegisterEvent(eventName, options?)` on the server.
```lua
-- Server Script
local damageDealtEvent = NetRay:RegisterEvent("DamageDealt", {
    -- Recommended: Define the data structure for clarity and validation
    typeDefinition = {
        targetInstanceId = "number", -- Use a reliable way to identify instances (e.g., custom attribute ID)
        damageAmount = "number",
        damageType = "?string",       -- Optional: e.g., "Fire", "Physical"
        critMultiplier = "number|nil" -- Optional, number or nil
    },
    priority = NetRay.Priority.HIGH, -- Ensure damage events are handled quickly client-side
    batchable = true                 -- Efficient for frequent damage updates
})
```

### Listening for Client Events

Handle events sent *from* clients using `:OnEvent(callback)`.

```lua
-- Server Script
damageDealtEvent:OnEvent(function(player, data)
    -- 'player' is the Player who fired the event
    -- 'data' is the validated payload (if typeDefinition was provided)

    -- You'll need a reliable way to map targetInstanceId back to an Instance
    -- This is game-specific logic. FindFirstChild is unreliable for dynamic objects.
    -- local target = YourGameSpecificInstanceManager:GetInstanceById(data.targetInstanceId)
    local target = game.Workspace:FindFirstChild("Target_" .. data.targetInstanceId) -- Placeholder lookup

    if target and target:FindFirstChildOfClass("Humanoid") then
        local humanoid = target:FindFirstChildOfClass("Humanoid")
        local actualDamage = data.damageAmount * (data.critMultiplier or 1)

        print(("%s dealt %.1f %s damage to %s."):format(
            player.Name,
            actualDamage,
            data.damageType or "Unknown",
            target.Name
        ))
        humanoid:TakeDamage(actualDamage)
    else
        warn("Invalid target or missing Humanoid for damage event from", player.Name, "TargetID:", data.targetInstanceId)
    end
end)
```

### Firing Events to Clients

Send events *to* clients using the `:Fire...()` methods.

```lua
-- Server Script
-- Assuming player references (attackerPlayer, targetPlayer, immunePlayer) exist
if attackerPlayer then
    -- Send to a specific player who landed a critical hit
    damageDealtEvent:FireClient(attackerPlayer, {
        targetInstanceId = 0, -- Use a special ID for UI feedback maybe
        damageAmount = 150,
        damageType = "CritFeedback",
        critMultiplier = 2.5
    })
end

-- Broadcast an area effect damage event
damageDealtEvent:FireAllClients({
    targetInstanceId = -1, -- Use special ID for AoE
    damageAmount = 30,
    damageType = "Explosion"
    -- Might also include position = Vector3...
})

-- Notify everyone except the target about a status effect
if targetPlayer then
    -- Assuming StatusEffectApplied event is registered elsewhere
    local statusEffectEvent = NetRay:RegisterEvent("StatusEffectApplied") -- Register ensures it exists
    statusEffectEvent:FireAllClientsExcept(targetPlayer, {
        targetName = targetPlayer.Name,
        effect = "Slowed",
        duration = 5
    })
end

-- Send event only to players on Team A
local teamUpdateEvent = NetRay:RegisterEvent("TeamUpdate")
    teamUpdateEvent:FireFilteredClients(function(p)
        -- Make sure player.Team and player.Team.Name exist and are valid
        return p.Team and p.Team.Name == "Team A"
    end, {
        message = "Objective captured!",
        points = 100
    })
end
```

## Client-Side Usage

### Getting an Event Reference

Use `NetRay:GetEvent(eventName)` to access an event. Use `NetRay:RegisterEvent(eventName, options?)` if you need to set client-specific options *before* the first event is potentially received or fired (less common).

```lua
-- Client Script
-- Get a reference (most common)
local damageDealtEvent = NetRay:GetEvent("DamageDealt")

-- Or register if you need specific client options (like listener priority)
-- local damageDealtEvent = NetRay:RegisterEvent("DamageDealt", { priority = NetRay.Priority.CRITICAL })
```

### Listening for Server Events

Handle events sent *from* the server using `:OnEvent(callback)`.

```lua
-- Client Script
local LocalPlayer = game:GetService("Players").LocalPlayer
-- Assume some way to get the local player's character unique ID if needed
-- local localCharacterId = LocalPlayer.Character and LocalPlayer.Character:GetAttribute("InstanceId")

damageDealtEvent:OnEvent(function(data)
    -- 'data' is the validated payload from the server

    local localCharacterId = LocalPlayer.Character and LocalPlayer.Character:GetAttribute("InstanceId")

    -- Show damage numbers or effects
    if data.damageType == "CritFeedback" then
        print("CRITICAL HIT UI FEEDBACK!")
        -- TriggerCritUI()
        elseif data.targetInstanceId == localCharacterId then -- Check if this client was the target
            print(("Took %.1f %s damage!"):format(data.damageAmount, data.damageType or "Unknown"))
            -- UpdateHealthBarUI(data.damageAmount)
            -- ShowDamageVignette()
        elseif data.targetInstanceId == -1 and data.damageType == "Explosion" then
            -- Play explosion sound/visual near event source (if position was included in 'data')
            print("Nearby explosion!")
            -- PlayExplosionEffect(data.position)
    end
end)

-- Also listen for the status effect event
local statusEffectEvent = NetRay:GetEvent("StatusEffectApplied")
statusEffectEvent:OnEvent(function(data)
    if data.targetName == LocalPlayer.Name then
        print(("You were afflicted with %s for %d seconds!"):format(data.effect, data.duration))
        -- Apply visual effect on local player?
    elseif data.targetName == LocalPlayer.Name then
        print(("%s was afflicted with %s."):format(data.targetName, data.effect))
        -- Show indicator on other player's nameplate?
    end
end)
```

### Firing Events to Server

Send events *to* the server using `:FireServer(data)`.

```lua
-- Client Script
local userInputService = game:GetService("UserInputService")
local requestDamageEvent = NetRay:GetEvent("DamageDealt") -- Event server listens to for damage reports

local function getTargetInstanceId(target)
    -- Implement your logic to get a *server-known* ID for the target instance
    -- Using attributes is a common method
    return target and target:GetAttribute("InstanceId")
end

userInputService.InputBegan:Connect(function(input, gameProcessed)
    if gameProcessed then return end
    if input.UserInputType == Enum.UserInputType.MouseButton1 then -- Left click
        local player = game:GetService("Players").LocalPlayer
        local mouse = player:GetMouse()
        local targetInstance = mouse.Target
        local targetId = getTargetInstanceId(targetInstance) -- Use helper function

        if targetId then
            print("Attempting to trigger damage event for target ID:", targetId)
            -- Client tells server it *hit* something. Server validates/calculates damage.
            requestDamageEvent:FireServer({
                targetInstanceId = targetId,
                damageAmount = 10, -- Client might suggest base damage or weapon type
                damageType = "MeleeSwing"
            })
        end
    end)
end)
```

### Example Usage

```lua
-- Example of event registration
local damageDealtEvent = NetRay:RegisterEvent("DamageDealt", {
    -- Recommended: Define the data structure for clarity and validation
    typeDefinition = {
        targetInstanceId = "number", -- Use a reliable way to identify instances (e.g., custom attribute ID)
        damageAmount = "number",
        damageType = "string",
        position = "Vector3"
    }
})

-- Example of firing the event
local target = game.Workspace:FindFirstChild("Target")
damageDealtEvent:FireAllClients({
    targetInstanceId = target:GetAttribute("ID"),
    damageAmount = 10,
    damageType = "Physical",
    position = target.Position
})
```