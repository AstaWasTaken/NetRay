--!strict
--!optimize 2
--!native

--[[    
    TypeChecker.lua
    Type checking utilities for NetRay's typed events
    
    Author: Asta (@TheYusufGamer)
    NetRay
]]

local TypeChecker = {}

-- Cache for performance
local typeCache = {}
local structureCache = {} -- Cache for complex structure validation
local circularReferenceCache = {} -- Cache for circular reference detection
local typeof = typeof -- Cache this function for better performance

-- Roblox-specific types
local robloxTypes = {
    ["Vector2"] = true,
    ["Vector3"] = true,
    ["CFrame"] = true,
    ["Color3"] = true,
    ["BrickColor"] = true,
    ["UDim"] = true,
    ["UDim2"] = true,
    ["Rect"] = true,
    ["Region3"] = true,
    ["NumberSequence"] = true,
    ["ColorSequence"] = true,
    ["EnumItem"] = true,
    ["buffer"] = true, -- Add buffer type support
    ["Instance"] = true -- Add Instance type support
}

-- Check if a value matches the expected type
function TypeChecker.isType(value: any, expectedType: string): boolean
    if not expectedType then 
        return true -- If no type specified, consider it valid
    end
    
    -- Check cache first for performance
    local valueType = typeof(value)
    local cacheKey = expectedType .. ":" .. valueType
    
    if typeCache[cacheKey] ~= nil then
        return typeCache[cacheKey]
    end
    
    local result = false
    
    -- Handle basic types
    if expectedType == "string" or expectedType == "number" or expectedType == "boolean" or 
        expectedType == "function" or expectedType == "nil" or expectedType == "userdata" or
        expectedType == "thread" or expectedType == "table" then
        result = valueType == expectedType
    
    -- Handle "any" type
    elseif expectedType == "any" then
        result = true
    
    -- Handle array type (table with sequential numeric indices)
    elseif expectedType == "array" then
        if valueType ~= "table" then
            result = false
        else
            local count = 0
            for _ in pairs(value) do
                count += 1
            end
            result = count == #value and count > 0
        end
    
    -- Handle Roblox-specific types
    elseif robloxTypes[expectedType] then
        result = valueType == expectedType
    
    -- Handle union types (e.g., "string|number")
    elseif string.find(expectedType, "|") then
        local unionTypes = {}
        for unionType in string.gmatch(expectedType, "([^|]+)") do
            unionTypes[unionType:match("^%s*(.-)%s*$")] = true -- trim whitespace
        end

        for unionType in pairs(unionTypes) do
            if TypeChecker.isType(value, unionType) then
                result = true
                break
            end
        end
    
    -- Handle instance type checking
    elseif string.sub(expectedType, 1, 9) == "Instance<" then
        local className = string.sub(expectedType, 10, -2) -- Remove "Instance<" and ">"
        
        -- Validate that the class name is a string
        if type(className) ~= "string" then
            result = false
        else
            result = valueType == "Instance" and value:IsA(className)
        end
    
    -- Handle dictionary type (key-value pairs with specific types)
    elseif string.sub(expectedType, 1, 5) == "Dict<" and string.sub(expectedType, -1) == ">" then
        if valueType ~= "table" then
            result = false
        else
            local typeStr = string.sub(expectedType, 6, -2)
            local keyType, valueType = typeStr:match("([^,]+)%s*,%s*(.+)")
            
            if not keyType or not valueType then
                result = false
            else
                result = true
                for k, v in pairs(value) do
                    if not TypeChecker.isType(k, keyType) or not TypeChecker.isType(v, valueType) then
                        result = false
                        break
                    end
                end
            end
        end
    
    -- Handle array of specific type (e.g., "Array<string>")
    elseif string.sub(expectedType, 1, 6) == "Array<" and string.sub(expectedType, -1) == ">" then
        if valueType ~= "table" then
            result = false
        else
            local itemType = string.sub(expectedType, 7, -2) -- Remove "Array<" and ">"
            
            -- Check if it's an array first
            local isArray = true
            local count = 0
            
            for k, _ in pairs(value) do
                count += 1
                if type(k) ~= "number" or k ~= math.floor(k) or k <= 0 or k > count then
                    isArray = false
                    break
                end
            end
            
            if not isArray or count == 0 then
                result = false
            else
                result = true
                for _, v in ipairs(value) do
                    if not TypeChecker.isType(v, itemType) then
                        result = false
                        break
                    end
                end
            end
        end
    
    -- Handle optional types (e.g., "?string")
    elseif string.sub(expectedType, 1, 1) == "?" then
        local actualType = string.sub(expectedType, 2)
        result = value == nil or TypeChecker.isType(value, actualType)
    end
    
    -- Cache the result for future checks
    typeCache[cacheKey] = result
    return result
end

-- Generate a fingerprint for a data structure to use in caching
local function getStructureFingerprint(data, typeDefinition)
    if type(data) ~= "table" or type(typeDefinition) ~= "table" then
        return tostring(data) .. ":" .. tostring(typeDefinition)
    end
    
    local keys = {}
    for k in pairs(typeDefinition) do
        table.insert(keys, k)
    end
    table.sort(keys)
    
    local fingerprint = ""
    for _, k in ipairs(keys) do
        local dataType = typeof(data[k])
        fingerprint = fingerprint .. k .. ":" .. dataType .. ";"
    end
    
    return fingerprint
end

-- Validate a data structure against a type definition
function TypeChecker.validateData(data: any, typeDefinition: {[string]: string}): (boolean, string?)
    if not typeDefinition then
        return true
    end
    
    if type(data) ~= "table" then
        return false, string.format("[NetRay] Expected table, got %s", typeof(data))
    end
    
    -- Check cache for complex structures
    local fingerprint = getStructureFingerprint(data, typeDefinition)
    if structureCache[fingerprint] ~= nil then
        return table.unpack(structureCache[fingerprint])
    end
    
    -- Check if all required fields are present and of correct type
    for key, expectedType in pairs(typeDefinition) do
        -- Handle optional fields (prefixed with ? or suffixed with |nil)
        local isOptional = string.sub(expectedType, 1, 1) == "?" or string.find(expectedType, "|nil") ~= nil
        
        if data[key] == nil and not isOptional then
            local result = {false, string.format("[NetRay] Missing required field: %s", key)}
            structureCache[fingerprint] = result
            return table.unpack(result)
        end
        
        if data[key] ~= nil then
            -- For optional fields with ? prefix, strip the ? for type checking
            local checkType = expectedType
            if string.sub(expectedType, 1, 1) == "?" then
                checkType = string.sub(expectedType, 2)
            end
            
            if not TypeChecker.isType(data[key], checkType) then
                local result = {false, string.format("[NetRay] Field '%s' expected type %s but got %s", 
                    key, checkType, typeof(data[key]))}
                structureCache[fingerprint] = result
                return table.unpack(result)
            end
        end
    end
    
    structureCache[fingerprint] = {true}
    return true
end

-- Validate function arguments against type definitions
function TypeChecker.validateArgs(args: {any}, typeDefinitions: {string}): (boolean, string?)
    if not typeDefinitions then
        return true
    end
    
    for i, expectedType in ipairs(typeDefinitions) do
        -- Handle optional args (prefixed with ? or suffixed with |nil)
        local isOptional = string.sub(expectedType, 1, 1) == "?" or string.find(expectedType, "|nil") ~= nil
        
        if args[i] == nil and not isOptional then
            return false, string.format("[NetRay] Missing argument %d, expected type %s", i, expectedType)
        end
        
        if args[i] ~= nil then
            -- For optional args with ? prefix, strip the ? for type checking
            local checkType = expectedType
            if string.sub(expectedType, 1, 1) == "?" then
                checkType = string.sub(expectedType, 2)
            end
            
            if not TypeChecker.isType(args[i], checkType) then
                return false, string.format("[NetRay] Argument %d expected type %s but got %s", 
                    i, checkType, typeof(args[i]))
            end
        end
    end
    
    return true
end

-- Clear the type cache (useful for testing or if types change at runtime)
function TypeChecker.clearCache()
    table.clear(typeCache)
    table.clear(structureCache)
    table.clear(circularReferenceCache)
end

-- Create a type definition from a sample data structure
function TypeChecker.createTypeDefinition(data: any): {[string]: string}?
    if type(data) ~= "table" then
        return nil
    end
    
    local definition = {}
    for key, value in pairs(data) do
        definition[key] = typeof(value)
    end
    
    return definition
end

-- Detect circular references in a table
local function hasCircularReferences(t, visited, path)
    if type(t) ~= "table" then return false end
    
    visited = visited or {}
    path = path or {}
    
    -- Check cache first
    local pathKey = table.concat(path, ".")
    if circularReferenceCache[pathKey] ~= nil then
        return circularReferenceCache[pathKey]
    end
    
    if visited[t] then 
        circularReferenceCache[pathKey] = true
        return true 
    end
    
    visited[t] = true
    
    for k, v in pairs(t) do
        if type(v) == "table" then
            local newPath = table.clone(path)
            table.insert(newPath, tostring(k))
            if hasCircularReferences(v, visited, newPath) then
                circularReferenceCache[pathKey] = true
                return true
            end
        end
    end
    
    visited[t] = nil
    circularReferenceCache[pathKey] = false
    return false
end

-- Check if a value is a valid NetRay event payload
function TypeChecker.isValidEventPayload(data: any): boolean
    if type(data) ~= "table" and type(data) ~= "string" and type(data) ~= "number" and 
       type(data) ~= "boolean" and type(data) ~= "nil" then
        return false
    end
    
    -- Check for circular references which can't be serialized
    if type(data) == "table" then
        return not hasCircularReferences(data)
    end
    
    return true
end

-- Validate data against a schema (wrapper for validateData with better error handling)
function TypeChecker.Validate(data: any, typeDefinition: {[string]: string})
    if not typeDefinition then
        return {success = true}
    end
    
    local success, errorMessage = pcall(function()
        return TypeChecker.validateData(data, typeDefinition)
    end)
    
    if not success then
        return {
            success = false,
            error = "[NetRay] Type validation error: " .. tostring(errorMessage)
        }
    end
    
    local isValid, validationError = errorMessage
    return {
        success = isValid,
        error = validationError
    }
end

-- Check if a table matches a specific structure (schema)
function TypeChecker.matchesSchema(data: any, schema: {[string]: any}): boolean
    if type(data) ~= "table" or type(schema) ~= "table" then
        return false
    end
    
    for key, expectedValue in pairs(schema) do
        if data[key] == nil then
            return false
        end
        
        local valueType = typeof(expectedValue)
        if valueType == "table" then
            if type(data[key]) ~= "table" or not TypeChecker.matchesSchema(data[key], expectedValue) then
                return false
            end
        else
            if typeof(data[key]) ~= valueType then
                return false
            end
        end
    end
    
    return true
end

-- Get the type of a value as a string, with enhanced detection for arrays and dictionaries
function TypeChecker.getDetailedType(value: any): string
    local basicType = typeof(value)
    
    if basicType == "table" then
        -- Check if it's an array
        local isArray = true
        local count = 0
        local allSameType = true
        local firstType = nil
        
        for k, v in pairs(value) do
            count += 1
            if type(k) ~= "number" or k ~= math.floor(k) or k <= 0 or k > count then
                isArray = false
            end
            
            if firstType == nil then
                firstType = typeof(v)
            elseif typeof(v) ~= firstType then
                allSameType = false
            end
        end
        
        if count == 0 then
            return "table (empty)"
        elseif isArray then
            if allSameType and firstType then
                return string.format("Array<%s>", firstType)
            else
                return "array"
            end
        else
            return "dictionary"
        end
    end
    
    return basicType
end

return TypeChecker