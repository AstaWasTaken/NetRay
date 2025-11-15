--!optimize 2

--[[
    TypeChecker.lua
    Type checking utilities for NetRay's typed events

    Author: Asta (@TheYusufGamer)
    NetRay
]]

local TypeChecker = {}

-- Cache for performance
local typeCache: {[string]: boolean} = {}
-- Define the type for the value stored in the structure cache
type StructureCacheValue = { Success: boolean, ErrorMessage: string? } -- Use a table type instead of tuple

-- Use the defined type, making the *value* in the map optional
local structureCache: {[string]: StructureCacheValue?} = {}
local typeof = typeof -- Cache global function

-- Roblox-specific types recognised by typeof() or IsA()
local robloxTypes: {[string]: boolean} = {
	["Vector2"] = true, ["vector"] = true, -- typeof(Vector3) is "vector"
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
	["buffer"] = true,
	["Instance"] = true
}

-- Type definition for the validation result
export type TypeCheckerResult = {
	success: boolean,
	error: string?
}

-- Type definition for the TypeChecker module itself
export type TypeCheckerModule = {
	isType: (value: any, expectedType: string) -> boolean,
	validateData: (data: any, typeDefinition: {[string]: string}) -> (boolean, string?),
	validateArgs: (args: {any}, typeDefinitions: {string}) -> (boolean, string?),
	clearCache: () -> (),
	createTypeDefinition: (data: any) -> {[string]: string}?,
	isValidEventPayload: (data: any) -> boolean,
	Validate: (data: any, typeDefinition: {[string]: string}) -> TypeCheckerResult, -- Note case difference from internal func
	matchesSchema: (data: any, schema: {[string]: any}) -> boolean,
	getDetailedType: (value: any) -> string,
}

-- Check if a value matches the expected type string
-- Type string format supports: basic types, any, array, Dict<k,v>, Array<t>, Instance<ClassName>, ?optional, type1|type2
function TypeChecker.isType(value: any, expectedType: string): boolean
	if not expectedType then
		return true -- No type constraint
	end

	-- Handle optional prefix '?'
	local isOptional = false
	if string.sub(expectedType, 1, 1) == "?" then
		isOptional = true
		expectedType = string.sub(expectedType, 2) -- Check against the actual type
		if value == nil then
			return true -- Optional and nil is okay
		end
	end

	-- Handle 'any'
	if expectedType == "any" then
		return true
	end

	local valueType = typeof(value)

	-- Handle simple nil check after optional handling
	if value == nil then
		-- If we reach here, value is nil but type wasn't optional, or expectedType wasn't 'nil' or a union including 'nil'
		return expectedType == "nil" or string.find(expectedType, "|nil") ~= nil
	end

	-- Check basic types using typeof first (most common case)
	if expectedType == "string" or expectedType == "number" or expectedType == "boolean" or
		expectedType == "function" or expectedType == "userdata" or expectedType == "thread" or expectedType == "table" or
		expectedType == "buffer" or expectedType == "vector" then -- typeof(Vector3) = 'vector'
		return valueType == expectedType
	end

	-- Check Roblox userdata types more specifically
	if robloxTypes[expectedType] then
		-- Some Roblox types have specific 'typeof' results (vector, userdata, EnumItem)
		-- Others might just be 'userdata'. We need IsA for those.
		if valueType == expectedType then return true end -- Handles buffer, vector, EnumItem
		if valueType == "userdata" and rawget(getmetatable(value) or {}, "__type") == expectedType then return true end -- Check __type for things like Color3, UDim2 etc.
		-- Fallback for complex userdata types where typeof isn't specific enough
		if valueType == "userdata" then
			local success, isA = pcall(function() return value:IsA(expectedType) end)
			return success and isA
		end
		return false -- Doesn't match typeof or specific userdata checks
	end

	-- Handle 'Instance' specifically (covers subclasses)
	if expectedType == "Instance" then
		return valueType == "Instance"
	end

	-- Check cache using value type (improves performance for repeated checks on same type)
	local cacheKey = expectedType .. ":" .. valueType
	if typeCache[cacheKey] ~= nil then
		return typeCache[cacheKey]
	end

	local result = false

	-- Handle union types (e.g., "string|number|nil")
	if string.find(expectedType, "|") then
		for unionPart in string.gmatch(expectedType, "([^|]+)") do
			-- Recursively check against each part of the union
			if TypeChecker.isType(value, unionPart:match("^%s*(.-)%s*$")) then -- trim whitespace
				result = true
				break -- Found a match
			end
		end

		-- Handle Instance<ClassName> (e.g., "Instance<Part>")
	elseif string.sub(expectedType, 1, 9) == "Instance<" and string.sub(expectedType, -1) == ">" then
		local className = string.sub(expectedType, 10, -2)
		if type(className) == "string" and valueType == "Instance" then
			-- Use pcall for safety in case IsA is called on destroyed instance
			local success, isA = pcall(value.IsA, value, className)
			result = success and isA
		end

		-- Handle Dict<KeyType,ValueType> (e.g., "Dict<string,number>")
	elseif string.sub(expectedType, 1, 5) == "Dict<" and string.sub(expectedType, -1) == ">" then
		if valueType == "table" then
			local typeStr = string.sub(expectedType, 6, -2)
			local keyType, valueTypeStr = typeStr:match("([^,]+)%s*,%s*(.+)")
			if keyType and valueTypeStr then
				result = true -- Assume true initially
				for k, v in pairs(value) do
					-- Recursively check key and value types
					if not TypeChecker.isType(k, keyType) or not TypeChecker.isType(v, valueTypeStr) then
						result = false
						break -- Mismatch found
					end
				end
			end
		end

		-- Handle Array<ItemType> (e.g., "Array<string>")
	elseif string.sub(expectedType, 1, 6) == "Array<" and string.sub(expectedType, -1) == ">" then
		if valueType == "table" then
			local itemType = string.sub(expectedType, 7, -2)
			-- Check if it's numerically indexed from 1 to #value
			local count = 0
			local maxIndex = 0
			local isProperArray = true
			for k, v in pairs(value) do
				count += 1
				if typeof(k) ~= "number" or k < 1 or k ~= math.floor(k) then
					isProperArray = false
					break
				end
				maxIndex = math.max(maxIndex, k)
			end

			if isProperArray and count == maxIndex then -- Ensure it's dense
				result = true -- Assume true
				for i = 1, count do
					if not TypeChecker.isType(value[i], itemType) then
						result = false
						break -- Item type mismatch
					end
				end
			end
		end
		-- Handle 'array' as a generic type (table with sequential numeric indices)
	elseif expectedType == "array" then
		if valueType == "table" then
			local count = 0
			local maxIndex = 0
			local isProperArray = true
			for k, v in pairs(value) do
				count += 1
				if typeof(k) ~= "number" or k < 1 or k ~= math.floor(k) then
					isProperArray = false
					break
				end
				maxIndex = math.max(maxIndex, k)
			end
			-- Allow empty arrays for generic 'array' type
			result = isProperArray and count == maxIndex
		end
	end

	-- Cache the result
	typeCache[cacheKey] = result
	return result
end

-- Generate a fingerprint for structure cache (simplified)
local function getStructureFingerprint(data, typeDefinition)
	-- Basic fingerprint based on keys in type definition - less precise but faster
	if typeof(data) ~= "table" or typeof(typeDefinition) ~= "table" then
		return nil -- Cannot fingerprint non-tables effectively this way
	end

	local keys = {}
	for k in pairs(typeDefinition) do
		table.insert(keys, k)
	end
	table.sort(keys)
	return table.concat(keys, ";") -- Fingerprint based only on the expected keys
end

-- Internal: Validate table data against a type definition table ({key: typeString})
-- Returns: boolean success, string? error message
function TypeChecker.validateData(data: any, typeDefinition: {[string]: string}): (boolean, string?)
	if typeof(typeDefinition) ~= "table" then return true, nil end -- No definition to check against
	if typeof(data) ~= "table" then
		return false, ("Expected table, got %s"):format(typeof(data))
	end

	-- Use fingerprint for structure cache if applicable
	local fingerprint = getStructureFingerprint(data, typeDefinition)
	local cachedResult
	if fingerprint and structureCache[fingerprint] then
		cachedResult = structureCache[fingerprint]
		return cachedResult[1], cachedResult[2] -- Return cached success/error
	end

	local success = true
	local errorMsg = nil

	-- Check all keys defined in the type definition
	for key, expectedType in pairs(typeDefinition) do
		if not TypeChecker.isType(data[key], expectedType) then
			-- isType handles optional logic internally based on '?' or '|nil' in expectedType
			-- If isType returns false, it's a definite mismatch.
			success = false
			local valType = TypeChecker.getDetailedType(data[key]) -- Use detailed type for error
			errorMsg = ("Field '%s' type mismatch: expected %s, got %s"):format(key, expectedType, valType)
			break -- Stop on first error
		end
	end

	-- Store result in cache
	if fingerprint then
		structureCache[fingerprint] = {success, errorMsg}
	end

	return success, errorMsg
end

-- Validate function arguments ({arg1, arg2}) against type definitions ({typeString1, typeString2})
-- Returns: boolean success, string? error message
function TypeChecker.validateArgs(args: {any}, typeDefinitions: {string}): (boolean, string?)
	if typeof(typeDefinitions) ~= "table" then return true, nil end -- No definition

	for i, expectedType in ipairs(typeDefinitions) do
		if not TypeChecker.isType(args[i], expectedType) then
			-- isType handles optional logic based on '?' or '|nil'
			local argType = TypeChecker.getDetailedType(args[i]) -- Use detailed type
			return false, ("Argument %d type mismatch: expected %s, got %s"):format(i, expectedType, argType)
		end
	end

	return true, nil
end

-- Clear all caches
function TypeChecker.clearCache()
	table.clear(typeCache)
	table.clear(structureCache)
	-- circularReferenceCache is cleared implicitly per-call
end

-- Create a basic type definition from a sample table (infers basic types)
function TypeChecker.createTypeDefinition(data: any): {[string]: string}?
	if typeof(data) ~= "table" then
		return nil
	end

	local definition = {}
	for key, value in pairs(data) do
		-- Use detailed type to potentially infer Array<T> etc.
		definition[key] = TypeChecker.getDetailedType(value)
	end

	return definition
end

-- Detect circular references in a table (internal helper)
local function hasCircularReferences(t, visited)
	if typeof(t) ~= "table" then return false end

	visited = visited or {} -- Table to track visited nodes in *this specific call*

	if visited[t] then
		return true -- Found a cycle
	end

	visited[t] = true -- Mark as visiting

	for k, v in pairs(t) do
		-- Recursively check sub-tables
		if hasCircularReferences(v, visited) then
			visited[t] = nil -- Clean up visited status on way out if cycle found below
			return true
		end
	end

	visited[t] = nil -- Unmark after checking all children (no cycle found down this path)
	return false
end

-- Check if data is suitable for serialization (basic types + non-circular tables)
function TypeChecker.isValidEventPayload(data: any): boolean
	local dataType = typeof(data)

	-- Allow basic serializable types
	if dataType == "string" or dataType == "number" or dataType == "boolean" or dataType == "nil" or dataType == "buffer" then
		return true
	end

	-- Allow Roblox types that are serializable
	if robloxTypes[dataType] then return true end
	-- Special case for Instance - generally not directly serializable in payloads unless specifically handled (e.g., via path)
	if dataType == "Instance" then return false end -- Adjust if instance passing is supported/intended

	-- Check tables for circular references
	if dataType == "table" then
		return not hasCircularReferences(data, nil) -- Start check with fresh visited table
	end

	-- Other types (function, thread, userdata without specific Roblox type match) are not serializable
	return false
end

-- Public Validate function (wrapper for validateData with standard result format)
function TypeChecker:Validate(data: any, typeDefinition: {[string]: string}): TypeCheckerResult
	-- Use pcall to catch potential errors *within* validateData or isType (e.g., bad type strings)
	local pcallSuccess, isValid, errorMsg = pcall(TypeChecker.validateData, data, typeDefinition)

	if not pcallSuccess then
		-- Error occurred during validation itself
		-- When pcall fails, isValid contains the error message
		return {
			success = false,
			error = "Type validation internal error: " .. tostring(isValid)
		}
	else
		-- validateData returns (boolean, string?)
		return {
			success = isValid,
			error = errorMsg -- Will be nil if isValid is true
		}
	end
end

-- Check if a table matches a simple key-value structure (not type-aware, just presence and basic typeof)
function TypeChecker.matchesSchema(data: any, schema: {[string]: any}): boolean
	if typeof(data) ~= "table" or typeof(schema) ~= "table" then
		return false
	end

	for key, expectedValue in pairs(schema) do
		if data[key] == nil then
			return false -- Key missing in data
		end

		local expectedValueType = typeof(expectedValue)
		if expectedValueType == "table" then
			-- Recursively check sub-tables
			if typeof(data[key]) ~= "table" or not TypeChecker.matchesSchema(data[key], expectedValue) then
				return false
			end
		else
			-- Compare basic types
			if typeof(data[key]) ~= expectedValueType then
				return false
			end
			-- Optional: Compare values for non-table types? Current code only checks type.
			-- if data[key] ~= expectedValue then return false end
		end
	end

	-- All keys in schema exist in data and have matching basic types (or recursively match for tables)
	return true
end

-- Get a detailed type string (e.g., "table", "array", "Array<string>", "dictionary")
function TypeChecker.getDetailedType(value: any): string
	local basicType = typeof(value)

	if basicType == "table" then
		local count = 0
		local maxIndex = 0
		local isProperArray = true
		local firstItemType = nil
		local allItemsSameType = true

		for k, v in pairs(value) do
			count += 1
			if typeof(k) ~= "number" or k < 1 or k ~= math.floor(k) then
				isProperArray = false
				-- Don't break here, continue checking item types for dictionary case
			else
				maxIndex = math.max(maxIndex, k)
			end

			-- Check item types consistency
			if count == 1 then
				firstItemType = typeof(v)
			elseif typeof(v) ~= firstItemType then
				allItemsSameType = false
			end
		end

		if count == 0 then
			return "table<empty>" -- More specific empty table
		elseif isProperArray and count == maxIndex then -- Is a dense array
			if allItemsSameType and firstItemType then
				-- Check if it's a Roblox type array, e.g., Array<Vector3>
				if robloxTypes[firstItemType] then
					-- Find the canonical name if possible (e.g., vector -> Vector3)
					local robloxTypeName = firstItemType
					for name, _ in pairs(robloxTypes) do
						if typeof(value[1]) == name or (typeof(value[1]) == "userdata" and value[1]:IsA(name)) then
							robloxTypeName = name
							break
						end
					end
					return ("Array<%s>"):format(robloxTypeName)
				else
					return ("Array<%s>"):format(firstItemType)
				end
			else
				return "array" -- Array of mixed types
			end
		else
			-- Not a dense array, consider it a dictionary
			-- Could add Dict<k,v> inference but gets complex, stick to 'dictionary'
			return "dictionary"
		end
	elseif robloxTypes[basicType] then
		-- Try to get more specific Roblox type name
		local specificName = basicType
		for name, _ in pairs(robloxTypes) do
			if typeof(value) == name then specificName = name; break end -- e.g. buffer
			if typeof(value) == "userdata" or typeof(value) == "vector" then -- Check IsA for userdata/vector
				local success, isA = pcall(value.IsA, value, name)
				if success and isA then specificName = name; break end
			end
		end
		return specificName
	end

	-- Return basic typeof for other types
	return basicType
end

return TypeChecker :: TypeCheckerModule