--!strict
--!optimize 2
--!native

--[[
    EfficientTable.lua
    
    Optimized table serialization for NetRay
    Provides specialized handling for different table structures
    - Dense arrays (consecutive numeric keys)
    - String key maps (tables with string keys)
    - Mixed tables (optimized format for tables with mixed key types)
    - Homogeneous tables (tables with all values of the same type)
    
    Determines the most efficient encoding strategy based on table contents
    Author: Asta (@TheYusufGamer)
]]

-- Requires
local Cursor = require(script.Parent.Cursor)

-- Constants for encoding types
local ENCODING_TYPES = {
    DENSE_ARRAY = 1,     -- Array with consecutive integer keys
    STRING_KEY_MAP = 2,  -- Table with only string keys
    MIXED = 3,           -- Table with mixed key types
    HOMOGENEOUS = 4      -- Table with values of the same type
}

-- Type checking utilities
local function getValueType(value)
    local valueType = typeof(value)
    if valueType == "table" then
        -- Check if it's an array (all integer keys)
        local isArray = true
        local count = 0
        for k in pairs(value) do
            count += 1
            if type(k) ~= "number" or k % 1 ~= 0 or k < 1 then
                isArray = false
                break
            end
        end
        if isArray then
            return "array"
        end
        return "table"
    end
    return valueType
end

-- Check if a table is a dense array (all integer keys from 1 to n)
local function isDenseArray(tbl)
    local count = 0
    for _ in pairs(tbl) do
        count += 1
    end
    
    -- Quick check if #tbl matches the count
    if #tbl == count then
        -- Verify all keys are sequential
        for i = 1, count do
            if tbl[i] == nil then
                return false
            end
        end
        return true
    end
    return false
end

-- Check if all table values are of the same type
local function isHomogeneousTable(tbl)
    local firstType = nil
    
    for _, v in pairs(tbl) do
        local currentType = typeof(v)
        if firstType == nil then
            firstType = currentType
        elseif firstType ~= currentType then
            return false, nil
        end
    end
    
    return true, firstType
end

-- Check if all keys are strings
local function isStringKeyMap(tbl)
    for k in pairs(tbl) do
        if type(k) ~= "string" then
            return false
        end
    end
    return true
end

-- Get Types module safely (avoid circular dependency)
local function getTypesModule()
    return require(script.Parent.Types)
end

-- Read function for EfficientTable
local function Read(cursor)
    -- Read the encoding type
    local encodingType = cursor:ReadU1()
    
    -- Lazy-load Types module to avoid circular dependency
    local Types = getTypesModule()
    
    -- Handle based on encoding type
    if encodingType == ENCODING_TYPES.DENSE_ARRAY then
        local length = cursor:ReadU2()
        local valueType = cursor:ReadU1()
        local result = table.create(length)
        
        -- Homogeneous array optimization
        if valueType > 0 then
            -- All elements are the same type
            local readFunc = nil
            for typeName, typeId in pairs(Types.Types) do
                if typeId == valueType then
                    readFunc = Types.Reads[typeName]
                    break
                end
            end
            
            if readFunc then
                for i = 1, length do
                    result[i] = readFunc(cursor)
                end
            else
                -- Fallback to Any
                for i = 1, length do
                    result[i] = Types.Reads.Any(cursor)
                end
            end
        else
            -- Mixed types array
            for i = 1, length do
                result[i] = Types.Reads.Any(cursor)
            end
        end
        
        return result
        
    elseif encodingType == ENCODING_TYPES.STRING_KEY_MAP then
        local count = cursor:ReadU2()
        local result = {}
        
        for _ = 1, count do
            -- Read key length and key
            local keyLength = cursor:ReadU1()
            local key = cursor:ReadString(keyLength)
            
            -- Read value
            local value = Types.Reads.Any(cursor)
            result[key] = value
        end
        
        return result
        
    elseif encodingType == ENCODING_TYPES.MIXED then
        local count = cursor:ReadU2()
        local result = {}
        
        for _ = 1, count do
            -- Read key type and value
            local keyType = cursor:ReadU1()
            local key
            
            -- Parse key based on type
            if keyType == 1 then
                -- Number key
                key = cursor:ReadU4()
            elseif keyType == 2 then
                -- String key
                local keyLength = cursor:ReadU1()
                key = cursor:ReadString(keyLength)
            elseif keyType == 3 then
                -- Boolean key
                key = cursor:ReadU1() == 1
            else
                -- Use Any type for other key types
                key = Types.Reads.Any(cursor)
            end
            
            -- Read value
            local value = Types.Reads.Any(cursor)
            result[key] = value
        end
        
        return result
        
    elseif encodingType == ENCODING_TYPES.HOMOGENEOUS then
        local count = cursor:ReadU2()
        local valueType = cursor:ReadU1()
        local result = {}
        
        -- Read key-value pairs
        for _ = 1, count do
            -- Read key (always use Any for keys)
            local key = Types.Reads.Any(cursor)
            
            -- Read value using the specific type
            local value
            local readFunc = nil
            for typeName, typeId in pairs(Types.Types) do
                if typeId == valueType then
                    readFunc = Types.Reads[typeName]
                    break
                end
            end
            
            if readFunc then
                value = readFunc(cursor)
            else
                value = Types.Reads.Any(cursor)
            end
            
            result[key] = value
        end
        
        return result
    end
    
    -- Fallback to empty table if invalid encoding
    return {}
end

-- Write function for EfficientTable
local function Write(cursor, value)
    -- Lazy-load Types module to avoid circular dependency
    local Types = getTypesModule()
    
    -- Determine the most efficient encoding strategy
    local isDense = isDenseArray(value)
    local isStringMap = not isDense and isStringKeyMap(value)
    local isHomogeneous, commonType = isHomogeneousTable(value)
    
    -- Get table size
    local size = 0
    for _ in pairs(value) do
        size += 1
    end
    
    -- Choose encoding strategy
    if isDense then
        -- Dense array encoding
        cursor:Allocate(4) -- 1 byte for type, 2 bytes for length, 1 byte for value type
        cursor:WriteU1(ENCODING_TYPES.DENSE_ARRAY)
        cursor:WriteU2(size)
        
        -- Check if all values are of the same type for further optimization
        if isHomogeneous and commonType then
            local valueTypeId = 0
            for typeName, typeId in pairs(Types.Types) do
                if typeName == commonType then
                    valueTypeId = typeId
                    break
                end
            end
            
            cursor:WriteU1(valueTypeId)
            
            -- Write values with specialized writer if available
            local writeFunc = Types.Writes[commonType]
            if writeFunc then
                for i = 1, size do
                    writeFunc(cursor, value[i])
                end
            else
                for i = 1, size do
                    Types.Writes.Any(cursor, value[i])
                end
            end
        else
            -- Mixed types in array
            cursor:WriteU1(0) -- 0 indicates mixed types
            for i = 1, size do
                Types.Writes.Any(cursor, value[i])
            end
        end
        
    elseif isStringMap then
        -- String key map encoding
        cursor:Allocate(3) -- 1 byte for type, 2 bytes for count
        cursor:WriteU1(ENCODING_TYPES.STRING_KEY_MAP)
        cursor:WriteU2(size)
        
        -- Write key-value pairs
        for k, v in pairs(value) do
            -- Write key length and key
            cursor:Allocate(1 + #k)
            cursor:WriteU1(#k)
            cursor:WriteString(k)
            
            -- Write value
            Types.Writes.Any(cursor, v)
        end
        
    elseif isHomogeneous and commonType and size > 0 then
        -- Homogeneous table encoding
        cursor:Allocate(4) -- 1 byte for type, 2 bytes for count, 1 byte for value type
        cursor:WriteU1(ENCODING_TYPES.HOMOGENEOUS)
        cursor:WriteU2(size)
        
        local valueTypeId = 0
        for typeName, typeId in pairs(Types.Types) do
            if typeName == commonType then
                valueTypeId = typeId
                break
            end
        end
        
        cursor:WriteU1(valueTypeId)
        
        -- Get specialized write function if available
        local writeFunc = Types.Writes[commonType]
        
        -- Write key-value pairs
        for k, v in pairs(value) do
            -- Write key (always use Any for keys)
            Types.Writes.Any(cursor, k)
            
            -- Write value with specialized writer if available
            if writeFunc then
                writeFunc(cursor, v)
            else
                Types.Writes.Any(cursor, v)
            end
        end
        
    else
        -- Mixed table encoding (fallback)
        cursor:Allocate(3) -- 1 byte for type, 2 bytes for count
        cursor:WriteU1(ENCODING_TYPES.MIXED)
        cursor:WriteU2(size)
        
        -- Write key-value pairs
        for k, v in pairs(value) do
            local keyType = typeof(k)
            
            if keyType == "number" and k % 1 == 0 and k >= 0 and k <= 4294967295 then
                -- Number key
                cursor:Allocate(5) -- 1 byte for key type, 4 bytes for key value
                cursor:WriteU1(1)
                cursor:WriteU4(k)
                
            elseif keyType == "string" then
                -- String key
                cursor:Allocate(2 + #k) -- 1 byte for key type, 1 byte for length, n bytes for key
                cursor:WriteU1(2)
                cursor:WriteU1(#k)
                cursor:WriteString(k)
                
            elseif keyType == "boolean" then
                -- Boolean key
                cursor:Allocate(2) -- 1 byte for key type, 1 byte for value
                cursor:WriteU1(3)
                cursor:WriteU1(k and 1 or 0)
                
            else
                -- Other key type - use Any
                cursor:Allocate(1) -- 1 byte for key type
                cursor:WriteU1(0)
                Types.Writes.Any(cursor, k)
            end
            
            -- Write value using Any type
            Types.Writes.Any(cursor, v)
        end
    end
end

-- Return the module
return {
    Read = Read,
    Write = Write
}
