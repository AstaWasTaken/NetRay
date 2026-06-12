--!optimize 2
--!native

-- BinaryEncoder.lua
-- Revised for 64-bit numeric support, cyclic references, robust instance paths,
-- legacy payload decoding, and stricter malformed-input handling.
-- Author: Asta (@TheYusufGamer)
-- Version: v1.6.0

local BinaryEncoder = {}

-- Existing identifiers are intentionally unchanged for backward compatibility.
-- New identifiers are appended so payloads written by older versions remain readable.
local TYPE = {
	NIL = 0,
	BOOLEAN_FALSE = 1,
	BOOLEAN_TRUE = 2,
	NUMBER_INT8 = 3,
	NUMBER_INT16 = 4,
	NUMBER_INT32 = 5,
	NUMBER_FLOAT32 = 6, -- Legacy decoder support. New values use FLOAT64.
	STRING_SHORT = 7,
	STRING_LONG = 8,
	TABLE_START = 9,
	TABLE_END = 10,
	ARRAY_START = 11,
	ARRAY_END = 12,
	REFERENCE = 13,
	VECTOR3 = 14,
	COLOR3 = 15,
	UDIM2 = 16,
	CFRAME = 17,
	VECTOR2 = 18,
	RECT = 19,
	ENUM = 20,
	INSTANCE_REF = 21,
	DATETIME = 22,
	BRICKCOLOR = 23,
	NUMBERSEQUENCE = 24,
	COLORSEQUENCE = 25,
	BUFFER = 26,
	ARRAY_HOMOGENEOUS = 27,
	VALUE_TYPE_ID = 28,
	NUMBER_ZERO = 29,
	STRING_EMPTY = 30,
	NUMBER_INT64 = 31,
	NUMBER_FLOAT64 = 32,
}

local HOMOGENEOUS_TYPE_MAP = {
	number = TYPE.NUMBER_FLOAT64,
	string = TYPE.STRING_SHORT,
	boolean = TYPE.BOOLEAN_FALSE,
	Vector3 = TYPE.VECTOR3,
	Vector2 = TYPE.VECTOR2,
	Color3 = TYPE.COLOR3,
	CFrame = TYPE.CFRAME,
	UDim2 = TYPE.UDIM2,
	Rect = TYPE.RECT,
	EnumItem = TYPE.ENUM,
	BrickColor = TYPE.BRICKCOLOR,
	DateTime = TYPE.DATETIME,
	buffer = TYPE.BUFFER,
}

-- Roblox globals and common functions cached for hot paths.
local Vector3_new = Vector3.new
local Vector2_new = Vector2.new
local Color3_new = Color3.new
local UDim2_new = UDim2.new
local Rect_new = Rect.new
local CFrame_new = CFrame.new
local Enum_Type = Enum
local DateTime_FromMillis = DateTime.fromUnixTimestampMillis
local BrickColor_new = BrickColor.new
local NumberSequence_new = NumberSequence.new
local ColorSequence_new = ColorSequence.new
local NumberSequenceKeypoint_new = NumberSequenceKeypoint.new
local ColorSequenceKeypoint_new = ColorSequenceKeypoint.new

local buffer_len = buffer.len
local buffer_tostring = buffer.tostring
local buffer_fromstring = buffer.fromstring
local string_pack = string.pack
local string_unpack = string.unpack
local string_sub = string.sub
local string_byte = string.byte
local string_char = string.char
local string_gmatch = string.gmatch
local string_match = string.match
local table_insert = table.insert
local table_concat = table.concat
local table_remove = table.remove
local table_unpack = table.unpack
local pairs = pairs
local ipairs = ipairs
local type = type
local typeof = typeof
local math_floor = math.floor
local math_max = math.max
local math_abs = math.abs
local pcall = pcall
local warn = warn
local error = error
local tostring = tostring

local CHAR_CACHE = {}
for i = 0, 255 do
	CHAR_CACHE[i] = string_char(i)
end

local MAX_DEPTH = 500
local MAX_UINT32 = 4294967295
-- Luau numbers are IEEE-754 doubles. Integers are exact only through 2^53 - 1.
local MAX_SAFE_INTEGER = 9007199254740991

local function encodingError(message: string, currentDepth: number?): never
	error(("[BE Enc Err d%d] %s"):format(currentDepth or 0, message), 3)
end

local function decodingError(message: string, index: number): never
	error(("[BE Dec Err @%d] %s"):format(index, message), 3)
end

local function isExactInteger(value: number): boolean
	return value == math_floor(value) and math_abs(value) <= MAX_SAFE_INTEGER
end

local function ensureBytes(data: string, index: number, byteCount: number, label: string)
	if index + byteCount - 1 > #data then
		decodingError("EOF " .. label, index)
	end
end

local function writeLength(length: number): string
	if length < 0 or length > MAX_UINT32 or length ~= math_floor(length) then
		encodingError("Length is outside uint32 range: " .. tostring(length), 0)
	end

	if length < 255 then
		return CHAR_CACHE[length]
	end

	return CHAR_CACHE[255] .. string_pack(">I4", length)
end

local function readLength(data: string, index: number): (number, number)
	local firstByte = string_byte(data, index)
	if firstByte == nil then
		decodingError("readLength byte", index)
	end

	index += 1
	if firstByte < 255 then
		return firstByte, index
	end

	ensureBytes(data, index, 4, "readLength uint32")
	local length, nextIndex = string_unpack(">I4", data, index)
	return length, nextIndex
end

local function getInstancePathSegments(instance: Instance): {string}?
	local segments = {}
	local current: Instance? = instance

	while current and current ~= game do
		table_insert(segments, 1, current.Name)
		current = current.Parent
	end

	if current ~= game then
		warn(("[BE Enc] Instance %q is not a descendant of game; encoding nil."):format(tostring(instance)))
		return nil
	end

	return segments
end

local function getInstanceAtSegments(segments: {any}): Instance?
	local current: Instance = game

	for _, segment in ipairs(segments) do
		if type(segment) ~= "string" then
			return nil
		end

		local child = current:FindFirstChild(segment)
		if not child then
			return nil
		end
		current = child
	end

	return current
end

-- Legacy instance payloads used dot-separated strings. New payloads use an array
-- of exact path segments so names containing periods work correctly.
local function getLegacyInstanceAtPath(path: string): Instance?
	local current: Instance = game
	for segment in string_gmatch(path, "[^%.]+") do
		local child = current:FindFirstChild(segment)
		if not child then
			return nil
		end
		current = child
	end
	return current
end

type EncoderState = {
	refs: {[any]: number},
	nextRefId: number,
}

local encodeValue

encodeValue = function(value: any, state: EncoderState, output: {string}, currentDepth: number)
	if currentDepth > MAX_DEPTH then
		encodingError("Maximum recursion depth exceeded", currentDepth)
	end

	local valueType = typeof(value)
	local rawType = type(value)

	if value == nil then
		table_insert(output, CHAR_CACHE[TYPE.NIL])
	elseif rawType == "boolean" then
		table_insert(output, CHAR_CACHE[value and TYPE.BOOLEAN_TRUE or TYPE.BOOLEAN_FALSE])
	elseif rawType == "number" then
		if value == 0 then
			table_insert(output, CHAR_CACHE[TYPE.NUMBER_ZERO])
		elseif isExactInteger(value) then
			if value >= -128 and value <= 127 then
				table_insert(output, CHAR_CACHE[TYPE.NUMBER_INT8])
				table_insert(output, string_pack("<i1", value))
			elseif value >= -32768 and value <= 32767 then
				table_insert(output, CHAR_CACHE[TYPE.NUMBER_INT16])
				table_insert(output, string_pack("<i2", value))
			elseif value >= -2147483648 and value <= 2147483647 then
				table_insert(output, CHAR_CACHE[TYPE.NUMBER_INT32])
				table_insert(output, string_pack("<i4", value))
			else
				table_insert(output, CHAR_CACHE[TYPE.NUMBER_INT64])
				table_insert(output, string_pack("<i8", value))
			end
		else
			table_insert(output, CHAR_CACHE[TYPE.NUMBER_FLOAT64])
			table_insert(output, string_pack("<d", value))
		end
	elseif rawType == "string" then
		local length = #value
		if length == 0 then
			table_insert(output, CHAR_CACHE[TYPE.STRING_EMPTY])
		else
			local encodedLength = writeLength(length)
			table_insert(output, CHAR_CACHE[#encodedLength == 1 and TYPE.STRING_SHORT or TYPE.STRING_LONG])
			table_insert(output, encodedLength)
			table_insert(output, value)
		end
	elseif rawType == "table" then
		local referenceId = state.refs[value]
		if referenceId ~= nil then
			table_insert(output, CHAR_CACHE[TYPE.REFERENCE])
			encodeValue(referenceId, state, output, currentDepth + 1)
			return
		end

		state.refs[value] = state.nextRefId
		state.nextRefId += 1

		local count = 0
		local maxIndex = 0
		local isDictionary = false

		for key in pairs(value) do
			count += 1
			if type(key) == "number" and key >= 1 and key == math_floor(key) then
				maxIndex = math_max(maxIndex, key)
			else
				isDictionary = true
			end
		end

		if not isDictionary and count > 0 and maxIndex > count * 2 and maxIndex > 10 then
			isDictionary = true
		end

		if not isDictionary and count == maxIndex then
			if count == 0 then
				table_insert(output, CHAR_CACHE[TYPE.ARRAY_START])
				table_insert(output, CHAR_CACHE[TYPE.ARRAY_END])
				return
			end

			local firstValue = value[1]
			local firstValueType = typeof(firstValue)
			local homogeneousTypeId = HOMOGENEOUS_TYPE_MAP[firstValueType]
			local isHomogeneous = count > 1 and homogeneousTypeId ~= nil

			if isHomogeneous then
				for i = 2, count do
					if typeof(value[i]) ~= firstValueType then
						isHomogeneous = false
						break
					end
				end
			end

			if isHomogeneous and homogeneousTypeId then
				table_insert(output, CHAR_CACHE[TYPE.ARRAY_HOMOGENEOUS])
				table_insert(output, CHAR_CACHE[homogeneousTypeId])
				table_insert(output, CHAR_CACHE[TYPE.VALUE_TYPE_ID])
				encodeValue(count, state, output, currentDepth + 1)

				if homogeneousTypeId == TYPE.NUMBER_FLOAT64 then
					-- Fixed-width values avoid the legacy FLOAT32 zero-marker ambiguity.
					for i = 1, count do
						table_insert(output, string_pack("<d", value[i]))
					end
				elseif homogeneousTypeId == TYPE.BOOLEAN_FALSE then
					for i = 1, count do
						table_insert(output, CHAR_CACHE[value[i] and TYPE.BOOLEAN_TRUE or TYPE.BOOLEAN_FALSE])
					end
				else
					for i = 1, count do
						encodeValue(value[i], state, output, currentDepth + 1)
					end
				end
			else
				table_insert(output, CHAR_CACHE[TYPE.ARRAY_START])
				for i = 1, count do
					encodeValue(value[i], state, output, currentDepth + 1)
				end
				table_insert(output, CHAR_CACHE[TYPE.ARRAY_END])
			end
		else
			table_insert(output, CHAR_CACHE[TYPE.TABLE_START])
			for key, childValue in pairs(value) do
				local keyType = type(key)
				if keyType == "string" or keyType == "number" then
					encodeValue(key, state, output, currentDepth + 1)
					encodeValue(childValue, state, output, currentDepth + 1)
				else
					warn("[BE Enc] Skipping unsupported table key:", keyType, key)
				end
			end
			table_insert(output, CHAR_CACHE[TYPE.TABLE_END])
		end
	elseif valueType == "Vector3" then
		table_insert(output, CHAR_CACHE[TYPE.VECTOR3])
		table_insert(output, string_pack("<ddd", value.X, value.Y, value.Z))
	elseif valueType == "Vector2" then
		table_insert(output, CHAR_CACHE[TYPE.VECTOR2])
		table_insert(output, string_pack("<dd", value.X, value.Y))
	elseif valueType == "Color3" then
		table_insert(output, CHAR_CACHE[TYPE.COLOR3])
		table_insert(output, string_pack("<ddd", value.R, value.G, value.B))
	elseif valueType == "UDim2" then
		table_insert(output, CHAR_CACHE[TYPE.UDIM2])
		table_insert(output, string_pack("<dddd", value.X.Scale, value.X.Offset, value.Y.Scale, value.Y.Offset))
	elseif valueType == "Rect" then
		table_insert(output, CHAR_CACHE[TYPE.RECT])
		table_insert(output, string_pack("<dddd", value.Min.X, value.Min.Y, value.Max.X, value.Max.Y))
	elseif valueType == "CFrame" then
		table_insert(output, CHAR_CACHE[TYPE.CFRAME])
		table_insert(output, string_pack("<dddddddddddd", value:GetComponents()))
	elseif valueType == "EnumItem" then
		local enumTypeName = string_match(tostring(value.EnumType), "^Enum%.(.+)$") or tostring(value.EnumType)
		table_insert(output, CHAR_CACHE[TYPE.ENUM])
		encodeValue(enumTypeName, state, output, currentDepth + 1)
		encodeValue(value.Name, state, output, currentDepth + 1)
	elseif valueType == "Instance" then
		local segments = getInstancePathSegments(value)
		if segments then
			table_insert(output, CHAR_CACHE[TYPE.INSTANCE_REF])
			encodeValue(segments, state, output, currentDepth + 1)
		else
			table_insert(output, CHAR_CACHE[TYPE.NIL])
		end
	elseif valueType == "DateTime" then
		table_insert(output, CHAR_CACHE[TYPE.DATETIME])
		table_insert(output, string_pack("<i8", value.UnixTimestampMillis))
	elseif valueType == "BrickColor" then
		table_insert(output, CHAR_CACHE[TYPE.BRICKCOLOR])
		encodeValue(value.Number, state, output, currentDepth + 1)
	elseif valueType == "NumberSequence" then
		local keypoints = value.Keypoints
		table_insert(output, CHAR_CACHE[TYPE.NUMBERSEQUENCE])
		encodeValue(#keypoints, state, output, currentDepth + 1)
		for _, keypoint in ipairs(keypoints) do
			table_insert(output, string_pack("<ddd", keypoint.Time, keypoint.Value, keypoint.Envelope))
		end
	elseif valueType == "ColorSequence" then
		local keypoints = value.Keypoints
		table_insert(output, CHAR_CACHE[TYPE.COLORSEQUENCE])
		encodeValue(#keypoints, state, output, currentDepth + 1)
		for _, keypoint in ipairs(keypoints) do
			table_insert(output, string_pack("<dddd", keypoint.Time, keypoint.Value.R, keypoint.Value.G, keypoint.Value.B))
		end
	elseif valueType == "buffer" then
		local length = buffer_len(value)
		table_insert(output, CHAR_CACHE[TYPE.BUFFER])
		table_insert(output, writeLength(length))
		table_insert(output, buffer_tostring(value))
	else
		warn("[BE Enc] Unsupported value type; encoding nil:", valueType, value)
		table_insert(output, CHAR_CACHE[TYPE.NIL])
	end
end

local decodeValue

decodeValue = function(data: string, indexRef: {number}, refs: {any}, currentDepth: number): any
	if currentDepth > MAX_DEPTH then
		decodingError("Maximum recursion depth exceeded", indexRef[1])
	end

	local index = indexRef[1]
	ensureBytes(data, index, 1, "TypeID")
	local typeId = string_byte(data, index)
	index += 1
	indexRef[1] = index

	if typeId == TYPE.NIL then
		return nil
	elseif typeId == TYPE.BOOLEAN_FALSE then
		return false
	elseif typeId == TYPE.BOOLEAN_TRUE then
		return true
	elseif typeId == TYPE.NUMBER_ZERO then
		return 0
	elseif typeId == TYPE.STRING_EMPTY then
		return ""
	elseif typeId == TYPE.NUMBER_INT8 then
		ensureBytes(data, index, 1, "INT8")
		local value, nextIndex = string_unpack("<i1", data, index)
		indexRef[1] = nextIndex
		return value
	elseif typeId == TYPE.NUMBER_INT16 then
		ensureBytes(data, index, 2, "INT16")
		local value, nextIndex = string_unpack("<i2", data, index)
		indexRef[1] = nextIndex
		return value
	elseif typeId == TYPE.NUMBER_INT32 then
		ensureBytes(data, index, 4, "INT32")
		local value, nextIndex = string_unpack("<i4", data, index)
		indexRef[1] = nextIndex
		return value
	elseif typeId == TYPE.NUMBER_INT64 then
		ensureBytes(data, index, 8, "INT64")
		local value, nextIndex = string_unpack("<i8", data, index)
		if math_abs(value) > MAX_SAFE_INTEGER then
			decodingError("INT64 is outside Luau's exact number range", index)
		end
		indexRef[1] = nextIndex
		return value
	elseif typeId == TYPE.NUMBER_FLOAT32 then
		-- Retained so older payloads can still be decoded.
		ensureBytes(data, index, 4, "FLOAT32")
		local value, nextIndex = string_unpack("<f", data, index)
		indexRef[1] = nextIndex
		return value
	elseif typeId == TYPE.NUMBER_FLOAT64 then
		ensureBytes(data, index, 8, "FLOAT64")
		local value, nextIndex = string_unpack("<d", data, index)
		indexRef[1] = nextIndex
		return value
	elseif typeId == TYPE.STRING_SHORT or typeId == TYPE.STRING_LONG then
		local length, contentIndex = readLength(data, index)
		local endIndex = contentIndex + length
		if endIndex > #data + 1 then
			decodingError("String out of bounds: " .. tostring(length), contentIndex)
		end
		indexRef[1] = endIndex
		return string_sub(data, contentIndex, endIndex - 1)
	elseif typeId == TYPE.REFERENCE then
		local referenceId = decodeValue(data, indexRef, refs, currentDepth + 1)
		if type(referenceId) ~= "number" or referenceId ~= math_floor(referenceId) then
			decodingError("Reference ID must be an integer", indexRef[1])
		end
		local referencedValue = refs[referenceId]
		if referencedValue == nil then
			decodingError("Invalid reference ID: " .. tostring(referenceId), indexRef[1])
		end
		return referencedValue
	elseif typeId == TYPE.TABLE_START then
		local result = {}
		refs[#refs + 1] = result

		while true do
			ensureBytes(data, indexRef[1], 1, "TABLE")
			if string_byte(data, indexRef[1]) == TYPE.TABLE_END then
				indexRef[1] += 1
				break
			end

			local key = decodeValue(data, indexRef, refs, currentDepth + 1)
			if key == nil then
				decodingError("Decoded nil table key", indexRef[1])
			end
			local childValue = decodeValue(data, indexRef, refs, currentDepth + 1)
			result[key] = childValue
		end

		return result
	elseif typeId == TYPE.ARRAY_START then
		local result = {}
		refs[#refs + 1] = result
		local arrayIndex = 1

		while true do
			ensureBytes(data, indexRef[1], 1, "ARRAY")
			if string_byte(data, indexRef[1]) == TYPE.ARRAY_END then
				indexRef[1] += 1
				break
			end

			result[arrayIndex] = decodeValue(data, indexRef, refs, currentDepth + 1)
			arrayIndex += 1
		end

		return result
	elseif typeId == TYPE.ARRAY_HOMOGENEOUS then
		local result = {}
		refs[#refs + 1] = result

		index = indexRef[1]
		ensureBytes(data, index, 2, "Homogeneous array header")
		local valueTypeId = string_byte(data, index)
		local separator = string_byte(data, index + 1)
		indexRef[1] = index + 2

		if separator ~= TYPE.VALUE_TYPE_ID then
			decodingError("Invalid homogeneous-array separator", index + 1)
		end

		local count = decodeValue(data, indexRef, refs, currentDepth + 1)
		if type(count) ~= "number" or count < 0 or count ~= math_floor(count) then
			decodingError("Invalid homogeneous-array count: " .. tostring(count), indexRef[1])
		end

		index = indexRef[1]
		if valueTypeId == TYPE.NUMBER_FLOAT64 then
			ensureBytes(data, index, count * 8, "Homogeneous FLOAT64 array")
			for i = 1, count do
				local value, nextIndex = string_unpack("<d", data, index)
				result[i] = value
				index = nextIndex
			end
		elseif valueTypeId == TYPE.NUMBER_FLOAT32 then
			-- Legacy compatibility only. Older encoders used a one-byte zero marker
			-- mixed with raw FLOAT32 bytes, which is inherently ambiguous.
			for i = 1, count do
				ensureBytes(data, index, 1, "Legacy homogeneous FLOAT32 array")
				if string_byte(data, index) == TYPE.NUMBER_ZERO then
					result[i] = 0
					index += 1
				else
					ensureBytes(data, index, 4, "Legacy homogeneous FLOAT32 value")
					local value, nextIndex = string_unpack("<f", data, index)
					result[i] = value
					index = nextIndex
				end
			end
		elseif valueTypeId == TYPE.BOOLEAN_FALSE or valueTypeId == TYPE.BOOLEAN_TRUE then
			ensureBytes(data, index, count, "Homogeneous boolean array")
			for i = 1, count do
				local booleanTypeId = string_byte(data, index)
				if booleanTypeId ~= TYPE.BOOLEAN_FALSE and booleanTypeId ~= TYPE.BOOLEAN_TRUE then
					decodingError("Invalid homogeneous boolean value", index)
				end
				result[i] = booleanTypeId == TYPE.BOOLEAN_TRUE
				index += 1
			end
		else
			for i = 1, count do
				indexRef[1] = index
				result[i] = decodeValue(data, indexRef, refs, currentDepth + 1)
				index = indexRef[1]
			end
		end

		indexRef[1] = index
		return result
	elseif typeId == TYPE.VECTOR3 then
		ensureBytes(data, index, 24, "Vector3")
		local x, y, z, nextIndex = string_unpack("<ddd", data, index)
		indexRef[1] = nextIndex
		return Vector3_new(x, y, z)
	elseif typeId == TYPE.VECTOR2 then
		ensureBytes(data, index, 16, "Vector2")
		local x, y, nextIndex = string_unpack("<dd", data, index)
		indexRef[1] = nextIndex
		return Vector2_new(x, y)
	elseif typeId == TYPE.COLOR3 then
		ensureBytes(data, index, 24, "Color3")
		local r, g, b, nextIndex = string_unpack("<ddd", data, index)
		indexRef[1] = nextIndex
		return Color3_new(r, g, b)
	elseif typeId == TYPE.UDIM2 then
		ensureBytes(data, index, 32, "UDim2")
		local xScale, xOffset, yScale, yOffset, nextIndex = string_unpack("<dddd", data, index)
		indexRef[1] = nextIndex
		return UDim2_new(xScale, xOffset, yScale, yOffset)
	elseif typeId == TYPE.RECT then
		ensureBytes(data, index, 32, "Rect")
		local minX, minY, maxX, maxY, nextIndex = string_unpack("<dddd", data, index)
		indexRef[1] = nextIndex
		return Rect_new(Vector2_new(minX, minY), Vector2_new(maxX, maxY))
	elseif typeId == TYPE.CFRAME then
		ensureBytes(data, index, 96, "CFrame")
		local components = {string_unpack("<dddddddddddd", data, index)}
		local nextIndex = table_remove(components)
		indexRef[1] = nextIndex
		return CFrame_new(table_unpack(components, 1, 12))
	elseif typeId == TYPE.ENUM then
		local enumTypeName = decodeValue(data, indexRef, refs, currentDepth + 1)
		local enumItemName = decodeValue(data, indexRef, refs, currentDepth + 1)
		if type(enumTypeName) ~= "string" or type(enumItemName) ~= "string" then
			decodingError("Enum names must be strings", indexRef[1])
		end

		enumTypeName = string_match(enumTypeName, "^Enum%.(.+)$") or enumTypeName
		local ok, enumItem = pcall(function()
			local enumType = Enum_Type[enumTypeName]
			return enumType and enumType[enumItemName]
		end)
		if ok and enumItem then
			return enumItem
		end
		warn("[BE Dec] Unable to resolve EnumItem:", enumTypeName, enumItemName)
		return nil
	elseif typeId == TYPE.INSTANCE_REF then
		local encodedPath = decodeValue(data, indexRef, refs, currentDepth + 1)
		local instance

		if type(encodedPath) == "string" then
			instance = getLegacyInstanceAtPath(encodedPath)
		elseif type(encodedPath) == "table" then
			instance = getInstanceAtSegments(encodedPath)
		else
			decodingError("Instance path must be a string or segment array", indexRef[1])
		end

		if instance then
			return instance
		end
		warn("[BE Dec] Unable to resolve instance reference.")
		return nil
	elseif typeId == TYPE.DATETIME then
		ensureBytes(data, index, 8, "DateTime")
		local milliseconds, nextIndex = string_unpack("<i8", data, index)
		indexRef[1] = nextIndex
		local ok, dateTime = pcall(DateTime_FromMillis, milliseconds)
		if ok then
			return dateTime
		end
		warn("[BE Dec] Unable to construct DateTime:", milliseconds)
		return nil
	elseif typeId == TYPE.BRICKCOLOR then
		local number = decodeValue(data, indexRef, refs, currentDepth + 1)
		if type(number) ~= "number" then
			decodingError("BrickColor number expected", indexRef[1])
		end
		local ok, brickColor = pcall(BrickColor_new, number)
		if ok then
			return brickColor
		end
		warn("[BE Dec] Unable to construct BrickColor:", number)
		return nil
	elseif typeId == TYPE.NUMBERSEQUENCE then
		local count = decodeValue(data, indexRef, refs, currentDepth + 1)
		if type(count) ~= "number" or count < 0 or count > 20 or count ~= math_floor(count) then
			decodingError("Invalid NumberSequence keypoint count: " .. tostring(count), indexRef[1])
		end

		index = indexRef[1]
		ensureBytes(data, index, count * 24, "NumberSequence")
		local keypoints = {}
		for i = 1, count do
			local time, value, envelope, nextIndex = string_unpack("<ddd", data, index)
			index = nextIndex
			local ok, keypoint = pcall(NumberSequenceKeypoint_new, time, value, envelope)
			if not ok then
				decodingError("Invalid NumberSequence keypoint", index)
			end
			keypoints[i] = keypoint
		end
		indexRef[1] = index

		local ok, sequence = pcall(NumberSequence_new, keypoints)
		if ok then
			return sequence
		end
		warn("[BE Dec] Unable to construct NumberSequence.")
		return nil
	elseif typeId == TYPE.COLORSEQUENCE then
		local count = decodeValue(data, indexRef, refs, currentDepth + 1)
		if type(count) ~= "number" or count < 0 or count > 20 or count ~= math_floor(count) then
			decodingError("Invalid ColorSequence keypoint count: " .. tostring(count), indexRef[1])
		end

		index = indexRef[1]
		ensureBytes(data, index, count * 32, "ColorSequence")
		local keypoints = {}
		for i = 1, count do
			local time, r, g, b, nextIndex = string_unpack("<dddd", data, index)
			index = nextIndex
			local okColor, color = pcall(Color3_new, r, g, b)
			if not okColor then
				decodingError("Invalid ColorSequence color", index)
			end
			local okKeypoint, keypoint = pcall(ColorSequenceKeypoint_new, time, color)
			if not okKeypoint then
				decodingError("Invalid ColorSequence keypoint", index)
			end
			keypoints[i] = keypoint
		end
		indexRef[1] = index

		local ok, sequence = pcall(ColorSequence_new, keypoints)
		if ok then
			return sequence
		end
		warn("[BE Dec] Unable to construct ColorSequence.")
		return nil
	elseif typeId == TYPE.BUFFER then
		local length, contentIndex = readLength(data, index)
		local endIndex = contentIndex + length
		if endIndex > #data + 1 then
			decodingError("Buffer out of bounds: " .. tostring(length), contentIndex)
		end
		local contents = string_sub(data, contentIndex, endIndex - 1)
		indexRef[1] = endIndex
		local ok, result = pcall(buffer_fromstring, contents)
		if ok then
			return result
		end
		warn("[BE Dec] Unable to construct buffer.")
		return nil
	else
		decodingError("Unknown TypeID: " .. tostring(typeId), index - 1)
	end
end

function BinaryEncoder.encode(value: any): string
	local output = {}
	local state: EncoderState = {
		refs = {},
		nextRefId = 1,
	}

	local ok, result = pcall(encodeValue, value, state, output, 0)
	if not ok then
		error("[BinaryEncoder.encode error] " .. tostring(result), 0)
	end

	return table_concat(output)
end

function BinaryEncoder.decode(data: string): any
	if type(data) ~= "string" then
		error("BinaryEncoder.decode requires a string, got " .. type(data), 2)
	end
	if #data == 0 then
		error("BinaryEncoder.decode requires a non-empty string", 2)
	end

	local indexRef = {1}
	local refs = {}
	local result = decodeValue(data, indexRef, refs, 0)

	if indexRef[1] <= #data then
		warn(("[BE Dec] Extra %d trailing bytes remain (next=%d, total=%d)."):format(#data - indexRef[1] + 1, indexRef[1], #data))
	end

	return result
end

return BinaryEncoder
