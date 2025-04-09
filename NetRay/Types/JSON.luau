--!strict
--!optimize 2
--!native

--[[
	Serializes/Deserializes JSON-compatible Luau values using a Cursor.

	Supports:
	- strings
	- numbers (stored as F8/double)
	- booleans
	- nil
	- tables (arrays: sequential integer keys 1..n)
	- tables (objects: string keys)

	Does NOT support:
	- Luau-specific types (userdata, functions, threads)
	- Mixed key types in tables (will treat as object)
	- Non-sequential integer keys (will treat as object)
	- Cycles/shared references (will duplicate data)

	Format:
	- Type identifier (U1):
		0: Null (nil)
		1: Boolean (false)
		2: Boolean (true)
		3: Number (F8)
		4: String (U4 length + data)
		5: Array (U4 count + elements)
		6: Object (U4 count + key/value pairs)
	- Data (dependent on type)

    Author: Asta (@TheYusufGamer)
]]

-- Requires
local Cursor = require(script.Parent.Cursor) -- Adjust path if needed

-- Type Definitions
type JsonValue = string | number | boolean | nil | JsonArray | JsonObject
type JsonArray = { [number]: JsonValue }
type JsonObject = { [string]: JsonValue }
type Cursor = Cursor.Cursor

-- Constants for Type Identification
local TYPE_NULL = 0
local TYPE_FALSE = 1
local TYPE_TRUE = 2
local TYPE_NUMBER = 3
local TYPE_STRING = 4
local TYPE_ARRAY = 5
local TYPE_OBJECT = 6

-- Forward declaration for recursive functions
local WriteInternal
local ReadInternal

-- Internal Write Function
WriteInternal = function(cursor: Cursor, value: JsonValue)
	local valueType = typeof(value)

	if value == nil then
		cursor:Allocate(1)
		cursor:WriteU1(TYPE_NULL)
	elseif valueType == "boolean" then
		cursor:Allocate(1)
		cursor:WriteU1(if value then TYPE_TRUE else TYPE_FALSE)
	elseif valueType == "number" then
		cursor:Allocate(1 + 8)
		cursor:WriteU1(TYPE_NUMBER)
		cursor:WriteF8(value)
	elseif valueType == "string" then
		local len = #value
		cursor:Allocate(1 + 4 + len)
		cursor:WriteU1(TYPE_STRING)
		cursor:WriteU4(len)
		cursor:WriteString(value)
	elseif valueType == "table" then
		-- Determine if it's an array or object
		local count = 0
		local isArray = true
		for key, _ in pairs(value) do
			count += 1
			if typeof(key) ~= "number" or key < 1 or key % 1 ~= 0 then
				isArray = false
				-- No need to check further if it's already not an array
			end
		end

		-- Check sequential nature for arrays more strictly
		if isArray and count > 0 then
			for i = 1, count do
				if (value :: JsonArray)[i] == nil then
					isArray = false
					break
				end
			end
		elseif count == 0 then
			-- Empty table could be array or object, default to array representation.
			isArray = true
		end


		if isArray then
			-- Treat as Array
			cursor:Allocate(1 + 4)
			cursor:WriteU1(TYPE_ARRAY)
			local arrayLen = #value -- Use # for potentially sparse arrays treated as arrays
			cursor:WriteU4(arrayLen)
			for i = 1, arrayLen do
				WriteInternal(cursor, (value :: JsonArray)[i]) -- Recursive call
			end
		else
			-- Treat as Object
			cursor:Allocate(1 + 4)
			cursor:WriteU1(TYPE_OBJECT)
			cursor:WriteU4(count) -- Use counted pairs for objects
			for key, val in pairs(value) do
				if typeof(key) ~= "string" then
					error(`JSON serialization error: Object keys must be strings. Got type '{typeof(key)}'`)
				end
				-- Write Key (as a string)
				local keyLen = #key
				cursor:Allocate(4 + keyLen)
				cursor:WriteU4(keyLen)
				cursor:WriteString(key)
				-- Write Value (recursive)
				WriteInternal(cursor, val)
			end
		end
	else
		error(`JSON serialization error: Unsupported type '{valueType}'`)
	end
end

-- Internal Read Function
ReadInternal = function(cursor: Cursor): JsonValue
	local typeId = cursor:ReadU1()

	if typeId == TYPE_NULL then
		return nil
	elseif typeId == TYPE_FALSE then
		return false
	elseif typeId == TYPE_TRUE then
		return true
	elseif typeId == TYPE_NUMBER then
		return cursor:ReadF8()
	elseif typeId == TYPE_STRING then
		local len = cursor:ReadU4()
		return cursor:ReadString(len)
	elseif typeId == TYPE_ARRAY then
		local count = cursor:ReadU4()
		local array = table.create(count)
		for i = 1, count do
			array[i] = ReadInternal(cursor) -- Recursive call
		end
		return array
	elseif typeId == TYPE_OBJECT then
		local count = cursor:ReadU4()
		local object = {}
		for _ = 1, count do
			-- Read Key
			local keyLen = cursor:ReadU4()
			local key = cursor:ReadString(keyLen)
			-- Read Value
			local value = ReadInternal(cursor) -- Recursive call
			object[key] = value
		end
		return object
	else
		error(`JSON deserialization error: Invalid type identifier '{typeId}' at index {cursor.Index - 1}`)
	end
end


-- Public Interface
return {
	Read = ReadInternal,
	Write = WriteInternal,
}