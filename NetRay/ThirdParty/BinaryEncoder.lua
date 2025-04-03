--!optimize 2
--!native

-- BinaryEncoder.lua
-- Author: Asta (@TheYusufGamer) 
-- version v1.2.0

-- Binary type identifiers
local TYPE = {
	NIL = 0,
	BOOLEAN_FALSE = 1,
	BOOLEAN_TRUE = 2,
	NUMBER_INT = 3,
	NUMBER_FLOAT = 4,
	STRING_SHORT = 5,  -- String with length < 255
	STRING_LONG = 6,   -- String with length >= 255
	TABLE_START = 7,
	TABLE_END = 8,
	ARRAY_START = 9,
	ARRAY_END = 10,
	KEY_VALUE_SEPARATOR = 11,
	REFERENCE = 12,    -- For cyclic references
	VECTOR3 = 13,      -- Common Roblox type
	COLOR3 = 14,       -- Common Roblox type
	UDIM2 = 15,        -- Common Roblox type
	CFRAME = 16,       -- Common Roblox type
	VECTOR2 = 17,      -- Additional Roblox type
	RECT = 18,         -- Additional Roblox type
	ENUM = 19,         -- Roblox Enum type
	INSTANCE_REF = 20, -- Reference to an Instance by name/path
	DATETIME = 21,     -- DateTime object
	BRICKCOLOR = 22,   -- BrickColor object
	NUMBERSEQUENCE = 23, -- NumberSequence object
	COLORSEQUENCE = 24,  -- ColorSequence object
	NUMBER_TINY = 25,    -- Tiny integers (0-15) for ultra-compact encoding
	BUFFER = 26,         -- Buffer type
	DICTIONARY = 27,     -- Dictionary-specific optimized format
	ARRAY_HOMOGENEOUS = 28, -- Homogeneous array (all same type) for better compression
}

-- Map type strings to numeric type codes for homogeneous arrays
local TYPE_STRINGS = {
	["number"] = 3,  -- NUMBER_INT
	["string"] = 5,  -- STRING_SHORT
	["Vector3"] = 13, -- VECTOR3
	["Vector2"] = 17, -- VECTOR2
	["Color3"] = 14,  -- COLOR3
	["boolean"] = 1,  -- BOOLEAN_FALSE (will be handled specially)
	["CFrame"] = 16,  -- CFRAME
	["UDim2"] = 15,   -- UDIM2
	["Rect"] = 18,    -- RECT
	["EnumItem"] = 19, -- ENUM
	["BrickColor"] = 22, -- BRICKCOLOR
	["DateTime"] = 21,   -- DATETIME
	["table"] = 7,       -- TABLE_START
	["Buffer"] = 26,     -- BUFFER
}

-- Debug helpers
local function debugPrint(...)
	if _G.DEBUG_BINARY_ENCODER then
		print("[BinaryEncoder]", ...)
	end
end

-- Safely read bytes from data string
local function safeReadBytes(data, index, count)
	-- Make sure we don't read past the end of the string
	if not data or not index or not count then
		error("Invalid arguments to safeReadBytes")
	end

	-- Check bounds
	if index < 1 or index > #data then
		error("Read index out of bounds: " .. tostring(index) .. " (data length: " .. #data .. ")")
	end

	if index + count - 1 > #data then
		error("Cannot read " .. count .. " bytes starting at position " .. index .. " (data length: " .. #data .. ")")
	end

	return string.sub(data, index, index + count - 1), index + count
end

-- Safe string unpacking
local function safeUnpack(format, data, index)
	if index + string.packsize(format) - 1 > #data then
		error("Not enough data to unpack format '" .. format .. "' at position " .. index)
	end

	local value, newIndex = string.unpack(format, data, index)
	return value, newIndex
end

-- Convert a number to a byte string with optimized encoding
local function numberToBytes(num, isInteger)
	-- Optimize for tiny integers (0-15)
	if isInteger or math.floor(num) == num then
		if num >= 0 and num <= 15 then
			-- Ultra compact encoding for tiny integers
			return string.char(TYPE.NUMBER_TINY + num)
		elseif num >= -128 and num <= 127 then
			-- Single byte for small integers (-128 to 127)
			return string.char(TYPE.NUMBER_INT, 1, num >= 0 and num or (256 + num))
		elseif num >= -32768 and num <= 32767 then
			-- Two bytes for medium integers (-32768 to 32767)
			local b1 = math.floor(num / 256) % 256
			local b2 = num % 256
			return string.char(TYPE.NUMBER_INT, 2, b1 >= 0 and b1 or (256 + b1), b2 >= 0 and b2 or (256 + b2))
		else
			-- Four bytes for larger integers
			local b1 = math.floor(num / 16777216) % 256
			local b2 = math.floor(num / 65536) % 256
			local b3 = math.floor(num / 256) % 256
			local b4 = num % 256
			return string.char(TYPE.NUMBER_INT, 4, 
				b1 >= 0 and b1 or (256 + b1),
				b2 >= 0 and b2 or (256 + b2),
				b3 >= 0 and b3 or (256 + b3),
				b4 >= 0 and b4 or (256 + b4))
		end
	else
		-- Float encoding using string.pack
		-- Use float32 for small numbers with limited precision
		if math.abs(num) < 16777216 and math.abs(num - math.floor(num)) < 0.0001 then
			local packedFloat = string.pack("f", num)  -- Single precision
			return string.char(TYPE.NUMBER_FLOAT, 0) .. packedFloat
		else
			local packedFloat = string.pack("d", num)  -- Double precision
			return string.char(TYPE.NUMBER_FLOAT, 1) .. packedFloat
		end
	end
end

-- Convert a string to a byte string with length prefixing
local function stringToBytes(str)
	local length = #str
	if length < 255 then
		-- Short string
		return string.char(TYPE.STRING_SHORT, length) .. str
	else
		-- Long string
		local b1 = math.floor(length / 16777216) % 256
		local b2 = math.floor(length / 65536) % 256
		local b3 = math.floor(length / 256) % 256
		local b4 = length % 256
		return string.char(TYPE.STRING_LONG, b1, b2, b3, b4) .. str
	end
end

-- Check if table is an array (sequential integer keys)
local function isArray(t)
	if type(t) ~= "table" then
		return false
	end

	local count = 0
	for _ in pairs(t) do
		count = count + 1
	end

	-- Check if all integer keys from 1 to count exist
	if count == 0 then
		return true -- Empty tables are considered arrays
	end

	for i = 1, count do
		if t[i] == nil then
			return false
		end
	end

	return count == #t
end

-- Check if array is homogeneous (all elements of same type)
local function isHomogeneousArray(arr)
	if #arr <= 1 then
		return false -- Too small to benefit from homogeneous encoding
	end
	
	local firstType = type(arr[1])
	local firstTypeof = typeof(arr[1])
	
	-- Only optimize for certain types
	if firstType ~= "number" and firstType ~= "string" and 
	   firstTypeof ~= "Vector3" and firstTypeof ~= "Vector2" and
	   firstTypeof ~= "Color3" then
		return false
	end
	
	-- Ensure we have a type mapping for this type
	if not TYPE_STRINGS[firstTypeof] then
		return false
	end
	
	for i = 2, #arr do
		if type(arr[i]) ~= firstType or typeof(arr[i]) ~= firstTypeof then
			return false
		end
	end
	
	return true, firstType, firstTypeof
end

-- Get instance path for serialization
local function getInstancePath(instance)
	if not instance or typeof(instance) ~= "Instance" then
		return nil
	end

	local path = instance.Name
	local current = instance.Parent

	while current and current ~= game do
		path = current.Name .. "." .. path
		current = current.Parent
	end

	return path
end

-- Binary serialization of Roblox data types
local function serializeRobloxTypes(value)
	local typeOf = typeof(value)

	if typeOf == "Vector3" then
		return string.char(TYPE.VECTOR3) .. 
			string.pack("d", value.X) .. 
			string.pack("d", value.Y) .. 
			string.pack("d", value.Z)
	elseif typeOf == "Vector2" then
		return string.char(TYPE.VECTOR2) .. 
			string.pack("d", value.X) .. 
			string.pack("d", value.Y)
	elseif typeOf == "Color3" then
		return string.char(TYPE.COLOR3) .. 
			string.pack("d", value.R) .. 
			string.pack("d", value.G) .. 
			string.pack("d", value.B)
	elseif typeOf == "UDim2" then
		return string.char(TYPE.UDIM2) .. 
			string.pack("d", value.X.Scale) .. 
			string.pack("d", value.X.Offset) .. 
			string.pack("d", value.Y.Scale) .. 
			string.pack("d", value.Y.Offset)
	elseif typeOf == "Rect" then
		return string.char(TYPE.RECT) ..
			string.pack("d", value.Min.X) ..
			string.pack("d", value.Min.Y) ..
			string.pack("d", value.Max.X) ..
			string.pack("d", value.Max.Y)
	elseif typeOf == "CFrame" then
		local x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22 = value:GetComponents()
		return string.char(TYPE.CFRAME) .. 
			string.pack("d", x) .. string.pack("d", y) .. string.pack("d", z) ..
			string.pack("d", r00) .. string.pack("d", r01) .. string.pack("d", r02) ..
			string.pack("d", r10) .. string.pack("d", r11) .. string.pack("d", r12) ..
			string.pack("d", r20) .. string.pack("d", r21) .. string.pack("d", r22)
	elseif typeOf == "EnumItem" then
		return string.char(TYPE.ENUM) .. 
			stringToBytes(tostring(value.EnumType)) .. 
			stringToBytes(tostring(value.Name))
	elseif typeOf == "Instance" then
		local path = getInstancePath(value)
		if path then
			return string.char(TYPE.INSTANCE_REF) .. stringToBytes(path)
		end
		-- If we can't get a path, we'll fall back to just the name
		return stringToBytes(value.Name)
	elseif typeOf == "DateTime" then
		return string.char(TYPE.DATETIME) .. string.pack("d", value.UnixTimestampMillis)
	elseif typeOf == "BrickColor" then
		return string.char(TYPE.BRICKCOLOR) .. numberToBytes(value.Number, true)
	elseif typeOf == "NumberSequence" then
		local keypoints = value.Keypoints
		local result = string.char(TYPE.NUMBERSEQUENCE) .. numberToBytes(#keypoints, true)

		for _, keypoint in ipairs(keypoints) do
			result = result .. 
				string.pack("d", keypoint.Time) ..
				string.pack("d", keypoint.Value) ..
				string.pack("d", keypoint.Envelope or 0)
		end

		return result
	elseif typeOf == "ColorSequence" then
		local keypoints = value.Keypoints
		local result = string.char(TYPE.COLORSEQUENCE) .. numberToBytes(#keypoints, true)

		for _, keypoint in ipairs(keypoints) do
			result = result .. 
				string.pack("d", keypoint.Time) ..
				string.pack("d", keypoint.Value.R) ..
				string.pack("d", keypoint.Value.G) ..
				string.pack("d", keypoint.Value.B)
		end

		return result
	elseif typeOf == "buffer" then
		local bufLen = buffer.len(value)
		local bufStr = buffer.tostring(value)
		return string.char(TYPE.BUFFER) .. numberToBytes(bufLen, true) .. bufStr
	end

	return nil  -- Not a handled Roblox type
end

-- Main binary serialization function with enhanced error handling
local function binaryEncode(value, options)
	options = options or {}
	local references = options.references or {}
	local maxDepth = options.maxDepth or 10000
	local currentDepth = options.currentDepth or 0
	local debugMode = options.debugMode

	-- Check for max recursion depth
	if currentDepth > maxDepth then
		error("Maximum recursion depth exceeded")
	end
	
	-- Update options for nested calls
	options.currentDepth = currentDepth + 1
	options.references = references
	options.debugMode = debugMode
	
	-- Debug output for top-level encoding
	if debugMode and currentDepth == 0 then
		print("[BinaryEncoder] Encoding value of type:", typeof(value))
		if type(value) == "table" then
			print("[BinaryEncoder] Table size:", #value, "with", (function()
				local count = 0
				for _ in pairs(value) do count = count + 1 end
				return count
			end)(), "total keys")
		end
	end
	
	-- Handle nil
	if value == nil then
		return string.char(TYPE.NIL)
	
	-- Handle booleans
	elseif type(value) == "boolean" then
		return string.char(value and TYPE.BOOLEAN_TRUE or TYPE.BOOLEAN_FALSE)
	
	-- Handle numbers
	elseif type(value) == "number" then
		return numberToBytes(value)
	
	-- Handle strings
	elseif type(value) == "string" then
		return stringToBytes(value)
	
	-- Handle Roblox types
	elseif typeof(value) ~= "table" then
		local robloxEncoded = serializeRobloxTypes(value)
		if robloxEncoded then
			return robloxEncoded
		end
	
	-- Handle tables (including arrays)
	elseif type(value) == "table" then
		local result = {}
		local isArrayTable = isArray(value)
		local isHomogeneous, firstType, firstTypeof = isHomogeneousArray(value)
		
		-- Start marker for table or array
		if isHomogeneous then
			table.insert(result, string.char(TYPE.ARRAY_HOMOGENEOUS))
			table.insert(result, string.char(TYPE_STRINGS[firstTypeof]))
		elseif isArrayTable then
			table.insert(result, string.char(TYPE.ARRAY_START))
		else
			table.insert(result, string.char(TYPE.TABLE_START))
		end
		
		if isHomogeneous then
			-- Homogeneous array encoding
			table.insert(result, numberToBytes(#value, true))
			for _, v in ipairs(value) do
				table.insert(result, binaryEncode(v, options))
			end
		elseif isArrayTable then
			-- Array encoding (just values)
			for _, v in ipairs(value) do
				table.insert(result, binaryEncode(v, options))
			end
		else
			-- Dictionary encoding (key-value pairs)
			for k, v in pairs(value) do
				local keyType = type(k)
				-- Only encode valid keys (strings or numbers)
				if keyType == "string" or keyType == "number" then
					table.insert(result, binaryEncode(k, options))
					table.insert(result, string.char(TYPE.KEY_VALUE_SEPARATOR))
					table.insert(result, binaryEncode(v, options))
				end
			end
		end
		
		-- End marker for table or array
		if isHomogeneous then
			table.insert(result, string.char(TYPE.ARRAY_END))
		elseif isArrayTable then
			table.insert(result, string.char(TYPE.ARRAY_END))
		else
			table.insert(result, string.char(TYPE.TABLE_END))
		end
		
		return table.concat(result)
	end
	
	-- Fallback for unsupported types
	return stringToBytes(tostring(value))
end

-- Binary decoding helper functions
local function readByte(data, index)
	if index > #data then
		error("Unexpected end of data at position " .. index)
	end
	return string.byte(string.sub(data, index, index)), index + 1
end

local function readBytes(data, index, count)
	if index + count - 1 > #data then
		error("Unexpected end of data: trying to read " .. count .. " bytes at position " .. index .. " (data length: " .. #data .. ")")
	end
	return string.sub(data, index, index + count - 1), index + count
end

local function readInt(data, index, size)
	local value = 0
	for i = 0, size - 1 do
		local byte
		byte, index = readByte(data, index)
		value = value + byte * (256 ^ (size - i - 1))
	end
	return value, index
end

-- Find instance by path
local function findInstanceByPath(path)
	if not path or type(path) ~= "string" then
		return nil
	end

	local parts = string.split(path, ".")
	local current = game

	for i, part in ipairs(parts) do
		current = current:FindFirstChild(part)
		if not current then
			return nil
		end
	end

	return current
end

-- Main binary deserialization function with improved error handling
local function binaryDecode(data, options)
	if type(data) ~= "string" then
		error("Expected string data to decode, got " .. typeof(data))
	end

	if #data == 0 then
		error("Cannot decode empty data")
	end

	options = type(options) == "table" and options or {}
	local index = options.index or 1
	local references = options.references or {}
	local maxDepth = options.maxDepth or 100
	local currentDepth = options.currentDepth or 0
	local debugMode = options.debugMode
	
	-- Check for max recursion depth
	if currentDepth > maxDepth then
		error("Maximum recursion depth exceeded")
	end

	-- Update options for nested calls
	options.currentDepth = currentDepth + 1
	options.references = references
	options.debugMode = debugMode

	local function decode()
		if index > #data then
			error("Unexpected end of data at position " .. index)
		end

		local typeId
		typeId, index = readByte(data, index)
		
		if debugMode and currentDepth == 0 then
			print("[BinaryEncoder] Decoding type:", typeId, "at position", index - 1)
		end

		if typeId == TYPE.NIL then
			return nil
		elseif typeId == TYPE.BOOLEAN_FALSE then
			return false
		elseif typeId == TYPE.BOOLEAN_TRUE then
			return true
		elseif typeId == TYPE.NUMBER_INT then
			local size
			size, index = readByte(data, index)

			if size == 1 then
				local byte
				byte, index = readByte(data, index)
				return byte <= 127 and byte or (byte - 256)
			elseif size == 2 then
				local b1, b2
				b1, index = readByte(data, index)
				b2, index = readByte(data, index)
				local value = (b1 * 256) + b2
				return value <= 32767 and value or (value - 65536)
			else -- size == 4
				local b1, b2, b3, b4
				b1, index = readByte(data, index)
				b2, index = readByte(data, index)
				b3, index = readByte(data, index)
				b4, index = readByte(data, index)
				local value = (b1 * 16777216) + (b2 * 65536) + (b3 * 256) + b4
				return value <= 2147483647 and value or (value - 4294967296)
			end
		elseif typeId == TYPE.NUMBER_FLOAT then
			-- Use safe unpacking to avoid reading past the end of the string
			if index + 8 - 1 > #data then 
				error("Not enough data to read float at position " .. index)
			end

			local precision
			precision, index = readByte(data, index)
			if precision == 0 then
				-- Single precision
				local value
				value, index = safeUnpack("f", data, index)
				return value
			else
				-- Double precision
				local value
				value, index = safeUnpack("d", data, index)
				return value
			end
		elseif typeId == TYPE.STRING_SHORT then
			local length
			length, index = readByte(data, index)
			local str
			str, index = readBytes(data, index, length)
			return str
		elseif typeId == TYPE.STRING_LONG then
			local b1, b2, b3, b4
			b1, index = readByte(data, index)
			b2, index = readByte(data, index)
			b3, index = readByte(data, index)
			b4, index = readByte(data, index)
			local length = (b1 * 16777216) + (b2 * 65536) + (b3 * 256) + b4

			-- Check reasonable string length to prevent memory issues
			if length > 50000000 then -- 50MB limit
				error("String length too large: " .. length .. " bytes")
			end

			local str
			str, index = readBytes(data, index, length)
			return str
		elseif typeId == TYPE.TABLE_START then
			local tbl = {}
			references[#references + 1] = tbl

			options.index = index

			while true do
				if index > #data then
					error("Unexpected end of data - missing TABLE_END marker")
				end

				local nextByte
				nextByte, index = readByte(data, index)
				if nextByte == TYPE.TABLE_END then
					break
				end

				-- Go back one byte
				index = index - 1

				options.index = index
				local key = decode()
				options.index = index

				local separator
				separator, index = readByte(data, index)
				if separator ~= TYPE.KEY_VALUE_SEPARATOR then
					error("Expected key-value separator (type " .. TYPE.KEY_VALUE_SEPARATOR .. "), got type " .. separator)
				end

				options.index = index
				local value = decode()
				options.index = index

				tbl[key] = value
			end

			return tbl
		elseif typeId == TYPE.ARRAY_START then
			local arr = {}
			references[#references + 1] = arr

			options.index = index

			local i = 1
			while true do
				if index > #data then
					error("Unexpected end of data - missing ARRAY_END marker")
				end

				local nextByte
				nextByte, index = readByte(data, index)
				if nextByte == TYPE.ARRAY_END then
					break
				end

				-- Go back one byte
				index = index - 1

				options.index = index
				arr[i] = decode()
				options.index = index
				i = i + 1
			end

			return arr
		elseif typeId == TYPE.ARRAY_HOMOGENEOUS then
			local typeOf
			typeOf, index = readByte(data, index)
			
			-- Read length using standard number decoding from numberToBytes
			local length
			local sizeTypeId, sizeIndex = readByte(data, index)
			
			-- Handle tiny integers (0-15) specially
			if sizeTypeId >= TYPE.NUMBER_TINY and sizeTypeId <= TYPE.NUMBER_TINY + 15 then
				length = sizeTypeId - TYPE.NUMBER_TINY
				index = sizeIndex
			elseif sizeTypeId == TYPE.NUMBER_INT then
				-- Regular integer format
				local size
				size, index = readByte(data, index)
				
				if size == 1 then
					local byte
					byte, index = readByte(data, index)
					length = byte <= 127 and byte or (byte - 256)
				elseif size == 2 then
					local b1, b2
					b1, index = readByte(data, index)
					b2, index = readByte(data, index)
					length = (b1 * 256) + b2
					length = length <= 32767 and length or (length - 65536)
				else -- size == 4
					local b1, b2, b3, b4
					b1, index = readByte(data, index)
					b2, index = readByte(data, index)
					b3, index = readByte(data, index)
					b4, index = readByte(data, index)
					length = (b1 * 16777216) + (b2 * 65536) + (b3 * 256) + b4
					length = length <= 2147483647 and length or (length - 4294967296)
				end
			else
				error("Invalid number format in homogeneous array length at position " .. index)
			end
			
			local arr = {}
			references[#references + 1] = arr
			
			-- Create a reverse mapping from type codes to type names for debugging
			local typeNames = {}
			for name, code in pairs(TYPE_STRINGS) do
				typeNames[code] = name
			end
			
			if debugMode then
				print("[BinaryEncoder] Decoding homogeneous array of type", typeNames[typeOf] or typeOf, "with length", length)
			end
			
			-- For all types, we read the encoded values directly
			for i = 1, length do
				options.index = index
				arr[i] = decode()  -- Will read the correct type based on the data
				options.index = index
			end
			
			return arr
		elseif typeId == TYPE.REFERENCE then
			options.index = index
			local refId = decode()
			options.index = index

			if not references[refId] then
				error("Invalid reference ID: " .. tostring(refId))
			end
			return references[refId]
		elseif typeId == TYPE.VECTOR3 then
			-- Safe unpacking to avoid out-of-bounds errors
			if index + 24 - 1 > #data then 
				error("Not enough data to read Vector3 at position " .. index)
			end

			local x, y, z
			x, index = safeUnpack("d", data, index)
			y, index = safeUnpack("d", data, index)
			z, index = safeUnpack("d", data, index)
			return Vector3.new(x, y, z)
		elseif typeId == TYPE.VECTOR2 then
			if index + 16 - 1 > #data then
				error("Not enough data to read Vector2 at position " .. index)
			end

			local x, y
			x, index = safeUnpack("d", data, index)
			y, index = safeUnpack("d", data, index)
			return Vector2.new(x, y)
		elseif typeId == TYPE.COLOR3 then
			if index + 24 - 1 > #data then
				error("Not enough data to read Color3 at position " .. index)
			end

			local r, g, b
			r, index = safeUnpack("d", data, index)
			g, index = safeUnpack("d", data, index)
			b, index = safeUnpack("d", data, index)
			return Color3.new(r, g, b)
		elseif typeId == TYPE.UDIM2 then
			if index + 32 - 1 > #data then
				error("Not enough data to read UDim2 at position " .. index)
			end

			local xScale, xOffset, yScale, yOffset
			xScale, index = safeUnpack("d", data, index)
			xOffset, index = safeUnpack("d", data, index)
			yScale, index = safeUnpack("d", data, index)
			yOffset, index = safeUnpack("d", data, index)
			return UDim2.new(xScale, xOffset, yScale, yOffset)
		elseif typeId == TYPE.RECT then
			if index + 32 - 1 > #data then
				error("Not enough data to read Rect at position " .. index)
			end

			local minX, minY, maxX, maxY
			minX, index = safeUnpack("d", data, index)
			minY, index = safeUnpack("d", data, index)
			maxX, index = safeUnpack("d", data, index)
			maxY, index = safeUnpack("d", data, index)
			return Rect.new(Vector2.new(minX, minY), Vector2.new(maxX, maxY))
		elseif typeId == TYPE.CFRAME then
			if index + 96 - 1 > #data then
				error("Not enough data to read CFrame at position " .. index)
			end

			local x, y, z
			local r00, r01, r02, r10, r11, r12, r20, r21, r22

			x, index = safeUnpack("d", data, index)
			y, index = safeUnpack("d", data, index)
			z, index = safeUnpack("d", data, index)

			r00, index = safeUnpack("d", data, index)
			r01, index = safeUnpack("d", data, index)
			r02, index = safeUnpack("d", data, index)
			r10, index = safeUnpack("d", data, index)
			r11, index = safeUnpack("d", data, index)
			r12, index = safeUnpack("d", data, index)
			r20, index = safeUnpack("d", data, index)
			r21, index = safeUnpack("d", data, index)
			r22, index = safeUnpack("d", data, index)

			return CFrame.new(x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22)
		elseif typeId == TYPE.ENUM then
			options.index = index
			local enumTypeName = decode()
			options.index = index
			local enumValueName = decode()
			options.index = index

			-- Try to convert string representations back to Enum
			local success, result = pcall(function()
				return Enum[enumTypeName][enumValueName]
			end)

			if success then
				return result
			else
				-- Fallback if enum can't be found
				return {EnumType = enumTypeName, Name = enumValueName}
			end
		elseif typeId == TYPE.INSTANCE_REF then
			options.index = index
			local path = decode()
			options.index = index

			local instance = findInstanceByPath(path)
			if instance then
				return instance
			else
				-- Return a placeholder with the path if instance can't be found
				return {__InstancePath = path}
			end
		elseif typeId == TYPE.DATETIME then
			if index + 8 - 1 > #data then
				error("Not enough data to read DateTime at position " .. index)
			end

			local timestamp
			timestamp, index = safeUnpack("d", data, index)

			-- Safely create DateTime
			local success, result = pcall(function()
				return DateTime.fromUnixTimestampMillis(timestamp)
			end)

			if success then
				return result
			else
				-- Fallback if DateTime creation fails
				return {__UnixTimestampMillis = timestamp}
			end
		elseif typeId == TYPE.BRICKCOLOR then
			options.index = index
			local number = decode()
			options.index = index

			-- Safely create BrickColor
			local success, result = pcall(function()
				return BrickColor.new(number)
			end)

			if success then
				return result
			else
				-- Fallback if BrickColor creation fails
				return {__BrickColorNumber = number}
			end
		elseif typeId == TYPE.NUMBERSEQUENCE then
			options.index = index
			local numKeypoints = decode()
			options.index = index

			if numKeypoints < 0 or numKeypoints > 10000 then
				error("Invalid number of keypoints: " .. numKeypoints)
			end

			if index + (numKeypoints * 24) - 1 > #data then
				error("Not enough data to read NumberSequence keypoints at position " .. index)
			end

			local keypoints = {}
			for i = 1, numKeypoints do
				local time, value, envelope
				time, index = safeUnpack("d", data, index)
				value, index = safeUnpack("d", data, index)
				envelope, index = safeUnpack("d", data, index)

				-- Validate values
				if time < 0 or time > 1 then
					time = math.clamp(time, 0, 1)
				end

				local success, keypoint = pcall(function()
					return NumberSequenceKeypoint.new(time, value, envelope)
				end)

				if success then
					keypoints[i] = keypoint
				else
					keypoints[i] = {Time = time, Value = value, Envelope = envelope}
				end
			end

			-- Try to create the sequence
			local success, sequence = pcall(function()
				return NumberSequence.new(keypoints)
			end)

			if success then
				return sequence
			else
				-- Return raw keypoints if sequence creation fails
				return {__NumberSequenceKeypoints = keypoints}
			end
		elseif typeId == TYPE.COLORSEQUENCE then
			options.index = index
			local numKeypoints = decode()
			options.index = index

			if numKeypoints < 0 or numKeypoints > 10000 then
				error("Invalid number of keypoints: " .. numKeypoints)
			end

			if index + (numKeypoints * 32) - 1 > #data then
				error("Not enough data to read ColorSequence keypoints at position " .. index)
			end

			local keypoints = {}
			for i = 1, numKeypoints do
				local time, r, g, b
				time, index = safeUnpack("d", data, index)
				r, index = safeUnpack("d", data, index)
				g, index = safeUnpack("d", data, index)
				b, index = safeUnpack("d", data, index)

				-- Validate time
				if time < 0 or time > 1 then
					time = math.clamp(time, 0, 1)
				end

				-- Create color
				local color = Color3.new(
					math.clamp(r, 0, 1),
					math.clamp(g, 0, 1),
					math.clamp(b, 0, 1)
				)

				local success, keypoint = pcall(function()
					return ColorSequenceKeypoint.new(time, color)
				end)

				if success then
					keypoints[i] = keypoint
				else
					keypoints[i] = {Time = time, Color = color}
				end
			end

			-- Try to create the sequence
			local success, sequence = pcall(function()
				return ColorSequence.new(keypoints)
			end)

			if success then
				return sequence
			else
				-- Return raw keypoints if sequence creation fails
				return {__ColorSequenceKeypoints = keypoints}
			end
		elseif typeId == TYPE.BUFFER then
			local length
			length, index = readInt(data, index, 4)
			local bufferStr
			bufferStr, index = readBytes(data, index, length)
			return buffer.fromstring(bufferStr)
		end

		error("Unknown type ID: " .. typeId .. " at position " .. (index - 1))
	end

	-- Try-catch around the entire decoding process
	local success, result = pcall(function()
		-- Start the decoding process
		options.index = index
		local decodedResult = decode()

		-- Update the index in case the caller wants to know the ending position
		options.index = index

		return decodedResult
	end)

	if not success then
		-- Enhanced error reporting
		error("Decoding failed: " .. tostring(result) .. " (at approximate position " .. tostring(options.index) .. ")")
	end

	return result
end

-- Compress encoded data with advanced techniques
local function compress(data)
	-- Apply run-length encoding for repeated nil values (common in sparse tables)
	local compressed = data:gsub(string.rep(string.char(TYPE.NIL), 4), string.char(TYPE.NIL) .. "4")
		:gsub(string.rep(string.char(TYPE.NIL), 3), string.char(TYPE.NIL) .. "3")
		:gsub(string.rep(string.char(TYPE.NIL), 2), string.char(TYPE.NIL) .. "2")
	
	-- Apply run-length encoding for repeated boolean values (common in flag arrays)
	compressed = compressed:gsub(string.rep(string.char(TYPE.BOOLEAN_TRUE), 4), string.char(TYPE.BOOLEAN_TRUE) .. "4")
		:gsub(string.rep(string.char(TYPE.BOOLEAN_TRUE), 3), string.char(TYPE.BOOLEAN_TRUE) .. "3")
		:gsub(string.rep(string.char(TYPE.BOOLEAN_TRUE), 2), string.char(TYPE.BOOLEAN_TRUE) .. "2")
	
	compressed = compressed:gsub(string.rep(string.char(TYPE.BOOLEAN_FALSE), 4), string.char(TYPE.BOOLEAN_FALSE) .. "4")
		:gsub(string.rep(string.char(TYPE.BOOLEAN_FALSE), 3), string.char(TYPE.BOOLEAN_FALSE) .. "3")
		:gsub(string.rep(string.char(TYPE.BOOLEAN_FALSE), 2), string.char(TYPE.BOOLEAN_FALSE) .. "2")
	
	-- Apply dictionary compression for common patterns
	-- This replaces common byte sequences with single byte codes
	local commonPatterns = {
		[string.char(TYPE.TABLE_START) .. string.char(TYPE.TABLE_END)] = string.char(0xE0), -- Empty table
		[string.char(TYPE.ARRAY_START) .. string.char(TYPE.ARRAY_END)] = string.char(0xE1), -- Empty array
		[string.char(TYPE.STRING_SHORT) .. string.char(0)] = string.char(0xE2), -- Empty string
	}
	
	for pattern, replacement in pairs(commonPatterns) do
		compressed = compressed:gsub(pattern, replacement)
	end
	
	return compressed
end

-- Decompress compressed data
local function decompress(data)
	-- First, restore dictionary-compressed patterns
	local decompressed = data:gsub(string.char(0xE0), string.char(TYPE.TABLE_START) .. string.char(TYPE.TABLE_END))
		:gsub(string.char(0xE1), string.char(TYPE.ARRAY_START) .. string.char(TYPE.ARRAY_END))
		:gsub(string.char(0xE2), string.char(TYPE.STRING_SHORT) .. string.char(0))
	
	-- Then apply run-length decoding
	decompressed = decompressed:gsub(string.char(TYPE.NIL) .. "(%d)", function(count)
		return string.rep(string.char(TYPE.NIL), tonumber(count))
	end)
	
	decompressed = decompressed:gsub(string.char(TYPE.BOOLEAN_TRUE) .. "(%d)", function(count)
		return string.rep(string.char(TYPE.BOOLEAN_TRUE), tonumber(count))
	end)
	
	decompressed = decompressed:gsub(string.char(TYPE.BOOLEAN_FALSE) .. "(%d)", function(count)
		return string.rep(string.char(TYPE.BOOLEAN_FALSE), tonumber(count))
	end)
	
	return decompressed
end

-- Calculate estimated compression ratio for a given data string
local function estimateCompressionRatio(data)
	local compressed = compress(data)
	return #data / #compressed
end

-- Expose the module with additional utility functions
return {
	encode = binaryEncode,
	decode = binaryDecode,
	compress = compress,
	decompress = decompress,
	estimateCompressionRatio = estimateCompressionRatio,
	TYPE = TYPE,

	-- Utility functions
	isArray = isArray,
	getInstancePath = getInstancePath,
	findInstanceByPath = findInstanceByPath,
	isHomogeneousArray = isHomogeneousArray
}