--!strict
--!optimize 2
--!native

--[[
    ServerEvent.lua
    Handles server-side event operations, with type validation and optimized networking
    Author: Asta (@TheYusufGamer)
]]

local Players = game:GetService("Players")

local Serializer = require(script.Parent.Parent.Shared.Serializer)
local TypeChecker = require(script.Parent.Parent.Shared.TypeChecker)
local Compressor = require(script.Parent.Parent.Shared.Compressor)
local DynamicSender = require(script.Parent.Parent.Shared.DynamicSender)

local ServerEvent = {}
ServerEvent.__index = ServerEvent

function ServerEvent.new(eventName, options, serverManager)
    local self = setmetatable({}, ServerEvent)
    
    self.Name = eventName
    self.Options = options or {}
    self.ServerManager = serverManager
    
    -- Register with the server manager
    local eventData = serverManager:RegisterEvent(eventName, self.Options)
    self.RemoteEvent = eventData.Remote
    
    -- Set up listeners
    self:SetupListeners()
    
    -- Determine if we need compression
    self.UseCompression = options.compression == true
    
    -- Store type definitions if provided
    self.TypeDefinition = options.typeDefinition
    
    -- Store priority
    self.Priority = options.priority or 2 -- Default to NORMAL priority
    
    -- Store batching preference
    self.Batchable = options.batchable ~= false -- Default to true unless explicitly set to false
    
    return self
end

function ServerEvent:SetupListeners()
    -- Listen for client events
    self.RemoteEvent.OnServerEvent:Connect(function(player, encodedData)
        -- Skip if player ID is on cooldown
        if not self.ServerManager:CheckPlayerTimeout(self.Name, player.UserId) then
            if self.ServerManager.DebugEnabled then
                warn(string.format("[NetRay] Player %s is on timeout for event %s", player.Name, self.Name))
            end
            return
        end
        
        -- Check incoming throttle
        if not self.ServerManager:CheckIncomingThrottle(player.UserId) then
            if self.ServerManager.DebugEnabled then
                warn(string.format("[NetRay] Request throttled for player %s: too many incoming requests", player.Name))
            end
            return
        end
        
        local success, data = pcall(function()
            -- Use DynamicSender to decode the raw data
            return DynamicSender:DecodeReceivedData(encodedData)
        end)
        
        if not success then
            warn(string.format("[NetRay] Failed to process data from client: %s", tostring(data)))
            return
        end
        
        -- Debug info if enabled
        if self.ServerManager.DebugEnabled and typeof(data) ~= "nil" then
            local dataDesc
            if typeof(data) == "table" then
                -- Simple table summary for debugging
                local count = 0
                for _ in pairs(data) do count += 1 end
                dataDesc = "[Table with " .. count .. " items]"
                
                -- Try to add more details if it's an array-like table
                if #data > 0 then
                    dataDesc = "[Array with " .. #data .. " items]"
                end
            else
                dataDesc = tostring(data)
            end
            print(string.format("[NetRay] Received data from %s: %s %s", player.Name, self.Name, dataDesc))
        end
        
        -- Check if we received an array of events from a batch
        if typeof(data) == "table" and #data > 0 and typeof(data[1]) == "table" then
            -- This looks like an array of events from a batch, process each one individually
            if self.ServerManager.DebugEnabled then
                print(string.format("[NetRay] Processing %d batched events for %s from player %s", #data, self.Name, player.Name))
            end
            
            for _, eventData in ipairs(data) do
                -- Type checking for each individual event
                if self.TypeDefinition then
                    local typeCheckResult = TypeChecker:Validate(eventData, self.TypeDefinition)
                    if not typeCheckResult.success then
                        warn(string.format("[NetRay] Type validation failed for batched event %s from player %s: %s", 
                            self.Name, player.Name, typeCheckResult.error or "Unknown error"))
                        continue -- Skip this event but process others
                    end
                end
                
                -- Run middleware for each individual event
                local processedEventData = self.ServerManager:InvokeMiddleware(self.Name, player, eventData)
                if processedEventData == false then
                    -- Middleware blocked this specific event
                    continue
                end
                
                -- Check circuit breaker
                local circuitBreaker = self.ServerManager.CircuitBreakers[self.Name]
                if circuitBreaker and not circuitBreaker:IsAllowed() then
                    if typeof(circuitBreaker.Options.fallback) == "function" then
                        circuitBreaker.Options.fallback(player, processedEventData or eventData)
                    end
                    continue
                end
                
                -- Dispatch to any registered handlers
                local eventInfo = self.ServerManager.Events[self.Name]
                if eventInfo and eventInfo.Handlers then
                    for _, handler in ipairs(eventInfo.Handlers) do
                        task.spawn(handler, player, processedEventData or eventData)
                    end
                end
            end
        else
            -- Type checking if enabled
            if self.TypeDefinition then
                local typeCheckResult = TypeChecker:Validate(data, self.TypeDefinition)
                if not typeCheckResult.success then
                    warn(string.format("[NetRay] Type validation failed for event %s from player %s: %s", 
                        self.Name, player.Name, typeCheckResult.error or "Unknown error"))
                    return
                end
            end
            
            -- Run middleware
            local processedData = self.ServerManager:InvokeMiddleware(self.Name, player, data)
            if processedData == false then
                -- Middleware blocked this event
                return
            end
            
            -- Check circuit breaker
            local circuitBreaker = self.ServerManager.CircuitBreakers[self.Name]
            if circuitBreaker and not circuitBreaker:IsAllowed() then
                if typeof(circuitBreaker.Options.fallback) == "function" then
                    circuitBreaker.Options.fallback(player, processedData or data)
                end
                return
            end
            
            -- Dispatch to any registered handlers
            local eventInfo = self.ServerManager.Events[self.Name]
            if eventInfo and eventInfo.Handlers then
                for _, handler in ipairs(eventInfo.Handlers) do
                    task.spawn(handler, player, processedData or data)
                end
            end
        end
    end)
end

function ServerEvent:OnEvent(callback)
    if typeof(callback) ~= "function" then
        error("[NetRay] OnEvent expects a function as its argument")
        return self
    end
    
    -- Add to the event handlers
    table.insert(self.ServerManager.Events[self.Name].Handlers, callback)
    
    return self
end

function ServerEvent:FireClient(player, data)
    if not player or not player:IsA("Player") or not player:IsDescendantOf(Players) then
        error("[NetRay] FireClient expects a valid Player as the first argument")
        return
    end
    
    -- Type checking if enabled
    if self.TypeDefinition then
        local typeCheckResult = TypeChecker:Validate(data, self.TypeDefinition)
        if not typeCheckResult.success then
            error(string.format("[NetRay] Type validation failed for event %s: %s", 
                self.Name, typeCheckResult.error or "Unknown error"))
            return
        end
    end
    
    -- Run middleware
    local processedData = self.ServerManager:InvokeMiddleware(self.Name, player, data)
    if processedData == false then
        -- Middleware blocked this event
        return
    end
    
    -- Let DynamicSender handle the optimization, serialization, and compression
    DynamicSender:Send(self.RemoteEvent, processedData or data, player, {
        batchable = self.Batchable,
        forceComparison = self.Options.forceComparison
    })
end

function ServerEvent:FireAllClients(data)
    -- Type checking if enabled
    if self.TypeDefinition then
        local typeCheckResult = TypeChecker:Validate(data, self.TypeDefinition)
        if not typeCheckResult.success then
            error(string.format("[NetRay] Type validation failed for event %s: %s", 
                self.Name, typeCheckResult.error or "Unknown error"))
            return
        end
    end
    
    -- Run middleware
    local processedData = self.ServerManager:InvokeMiddleware(self.Name, nil, data)
    if processedData == false then
        -- Middleware blocked this event
        return
    end
    
    -- Use DynamicSender to optimize batch sending
    local sendData = processedData or data
    local allPlayers = Players:GetPlayers()
    
    -- Use SendToMultiple for batch optimization
    local result = DynamicSender:SendToMultiple(self.RemoteEvent, allPlayers, sendData, {
        batchable = self.Batchable,
        forceComparison = self.Options.forceComparison
    })
    
    -- Log the batch send if debugging is enabled
    if self.ServerManager.DebugEnabled then
        print(string.format("[NetRay] Event %s fired to %d clients with batch optimization", 
            self.Name, #allPlayers))
    end
end

function ServerEvent:FireAllClientsExcept(excludedPlayer, data)
    if not excludedPlayer or not excludedPlayer:IsA("Player") then
        error("[NetRay] FireAllClientsExcept expects a valid Player as the first argument")
        return
    end
    
    -- Type checking if enabled
    if self.TypeDefinition then
        local typeCheckResult = TypeChecker:Validate(data, self.TypeDefinition)
        if not typeCheckResult.success then
            error(string.format("[NetRay] Type validation failed for event %s: %s", 
                self.Name, typeCheckResult.error or "Unknown error"))
            return
        end
    end
    
    -- Run middleware
    local processedData = self.ServerManager:InvokeMiddleware(self.Name, nil, data)
    if processedData == false then
        -- Middleware blocked this event
        return
    end
    
    -- Get all players except the excluded one
    local players = {}
    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= excludedPlayer then
            table.insert(players, player)
        end
    end
    
    -- Use DynamicSender to optimize batch sending
    local sendData = processedData or data
    DynamicSender:SendToMultiple(self.RemoteEvent, players, sendData, {
        batchable = self.Batchable,
        forceComparison = self.Options.forceComparison
    })
end

function ServerEvent:FireFilteredClients(filter, data)
    if typeof(filter) ~= "function" then
        error("[NetRay] FireFilteredClients expects a filter function as the first argument")
        return
    end
    
    -- Type checking if enabled
    if self.TypeDefinition then
        local typeCheckResult = TypeChecker:Validate(data, self.TypeDefinition)
        if not typeCheckResult.success then
            error(string.format("[NetRay] Type validation failed for event %s: %s", 
                self.Name, typeCheckResult.error or "Unknown error"))
            return
        end
    end
    
    -- Run middleware
    local processedData = self.ServerManager:InvokeMiddleware(self.Name, nil, data)
    if processedData == false then
        -- Middleware blocked this event
        return
    end
    
    -- Get filtered players
    local players = {}
    for _, player in ipairs(Players:GetPlayers()) do
        if filter(player) then
            table.insert(players, player)
        end
    end
    
    -- Use DynamicSender to optimize batch sending
    local sendData = processedData or data
    DynamicSender:SendToMultiple(self.RemoteEvent, players, sendData, {
        batchable = self.Batchable,
        forceComparison = self.Options.forceComparison
    })
end

return ServerEvent
