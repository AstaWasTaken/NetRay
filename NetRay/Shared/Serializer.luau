--!strict
--!optimize 2
--!native

--[[
    NetRaySerializer

    Serializes Luau data structures into optimized buffers with type identifiers.
    Implements precise subtype selection for Numbers, Vectors, CFrames, and Booleans.
	Author: Asta (@TheYusufGamer)
]]

local Cursor = require(script.Parent.Parent.Types.Cursor)
local Types = require(script.Parent.Parent.Types.Types)
local HttpService = game:GetService("HttpService") -- For JSON fallback

-- Local function optimizations
local mathFloor = math.floor
local mathAbs = math.abs
local mathMax = math.max
local mathHuge = math.huge
local bufferCreate = buffer.create
local bufferLen = buffer.len
local tableCreate = table.create
local tableInsert = table.insert
local tick = tick
local typeof = typeof
local tostring = tostring
local stringFormat = string.format
local stringSub = string.sub
local pairs = pairs
local ipairs = ipairs
local pcall = pcall
local error = error
local warn = warn

-- Compression Headers
local BINARY_HEADER_BYTE = 0x02
local UNCOMPRESSED_HEADER_BYTE = 0x01

-- Type Definitions
export type TypeName = string
export type TypeCode = number
export type SerializedResult = buffer

-- Forward declaration for recursive functions
local writeTypedValue
local readTypedValue

-- Module Table
local NetRaySerializer = {}

-- Performance metrics
local metrics = {
	serializeCount = 0,
	deserializeCount = 0,
	totalSerializeTime = 0,
	totalDeserializeTime = 0,
	errors = 0,
	largestSerialized = 0,
	homogeneousArrayCount = 0,
	dictionaryCount = 0,
	jsonFallbackCount = 0,
}

--[[ Type Codes - Reflecting specific subtypes ]]
local TYPE_CODES = {
	Nil = 0x00,
	-- Numbers (Unsigned Int)
	NumberU8 = 0x02, NumberU16 = 0x03, NumberU24 = 0x04, NumberU32 = 0x05,
	-- Numbers (Signed Int)
	NumberS8 = 0x10, NumberS16 = 0x11, NumberS24 = 0x12, NumberS32 = 0x13,
	-- Numbers (Float)
	NumberF16 = 0x20, NumberF24 = 0x21, NumberF32 = 0x22, NumberF64 = 0x23,
	-- Boolean (Single type code, actual value written separately)
	Boolean8 = 0x30,
	-- String/Buffer/Binary
	String = 0x40, Characters = 0x41, Buffer = 0x42, Binary = 0x43,
	-- Vector2 Subtypes
	Vector2S16 = 0x50, Vector2F24 = 0x51, Vector2F32 = 0x52,
	-- Vector3 Subtypes
	Vector3S16 = 0x60, Vector3F24 = 0x61, Vector3F32 = 0x62,
	-- CFrame Subtypes
	CFrameF24U8 = 0x70, CFrameF32U8 = 0x71, CFrameF32U16 = 0x72,
	-- Other Roblox Specific Types
	Color3 = 0x80, NumberRange = 0x81, NumberSequence = 0x82, ColorSequence = 0x83,
	BrickColor = 0x84, UDim = 0x90, UDim2 = 0x91, Rect = 0x92, Region3 = 0x93,
	EnumItem = 0xA0, Instance = 0xA1,
	-- Tables
	HomogeneousArray = 0xD0, Dictionary = 0xD1,
	-- Fallback
	JSON = 0xFE,
}

--[[ Reverse Mapping - Matching the specific types above ]]
local BYTE_TO_TYPE_NAME: { [TypeCode]: TypeName } = {
	[0x00] = "Nil",
	[0x02] = "NumberU8", [0x03] = "NumberU16", [0x04] = "NumberU24", [0x05] = "NumberU32",
	[0x10] = "NumberS8", [0x11] = "NumberS16", [0x12] = "NumberS24", [0x13] = "NumberS32",
	[0x20] = "NumberF16", [0x21] = "NumberF24", [0x22] = "NumberF32", [0x23] = "NumberF64",
	[0x30] = "Boolean8",
	[0x40] = "String", [0x41] = "Characters", [0x42] = "Buffer", [0x43] = "Binary",
	[0x50] = "Vector2S16", [0x51] = "Vector2F24", [0x52] = "Vector2F32",
	[0x60] = "Vector3S16", [0x61] = "Vector3F24", [0x62] = "Vector3F32",
	[0x70] = "CFrameF24U8", [0x71] = "CFrameF32U8", [0x72] = "CFrameF32U16",
	[0x80] = "Color3", [0x81] = "NumberRange", [0x82] = "NumberSequence", [0x83] = "ColorSequence",
	[0x84] = "BrickColor", [0x90] = "UDim", [0x91] = "UDim2", [0x92] = "Rect", [0x93] = "Region3",
	[0xA0] = "EnumItem", [0xA1] = "Instance",
	[0xD0] = "HomogeneousArray", [0xD1] = "Dictionary", [0xFE] = "JSON",
}

--[[ Helper: isInteger ]]
local function isInteger(value: number): boolean
	return mathAbs(value - mathFloor(value)) < 0.00001
end

--[[ Helper: determineType ]]
local function determineType(value: any): (TypeName, TypeCode)
	local valueType = typeof(value)

	if value == nil then return "Nil", TYPE_CODES.Nil end

	if valueType == "number" then
		local numValue = value :: number
		if isInteger(numValue) then
			if numValue >= 0 then -- Unsigned
				if numValue <= 255 then return "NumberU8", TYPE_CODES.NumberU8 end
				if numValue <= 65535 then return "NumberU16", TYPE_CODES.NumberU16 end
				if numValue <= 16777215 then return "NumberU24", TYPE_CODES.NumberU24 end
				if numValue <= 4294967295 then return "NumberU32", TYPE_CODES.NumberU32 end
			else -- Signed
				if numValue >= -128 then return "NumberS8", TYPE_CODES.NumberS8 end
				if numValue >= -32768 then return "NumberS16", TYPE_CODES.NumberS16 end
				if numValue >= -8388608 then return "NumberS24", TYPE_CODES.NumberS24 end
				if numValue >= -2147483648 then return "NumberS32", TYPE_CODES.NumberS32 end
			end
		end
		local magnitude = mathAbs(numValue)
		if magnitude <= 2048 then return "NumberF16", TYPE_CODES.NumberF16 end
		if magnitude <= 262144 then return "NumberF24", TYPE_CODES.NumberF24 end
		if magnitude <= 16777216 then return "NumberF32", TYPE_CODES.NumberF32 end
		return "NumberF64", TYPE_CODES.NumberF64
	end

	if valueType == "boolean" then
		return "Boolean8", TYPE_CODES.Boolean8
	end

	if valueType == "string" then
		local len = #value
		if len > 0 then
			local firstByte = string.byte(value, 1)
			if firstByte == BINARY_HEADER_BYTE or firstByte == UNCOMPRESSED_HEADER_BYTE then
				if len <= 65535 then return "Binary", TYPE_CODES.Binary else error("Binary string > 65535 bytes") end
			end
		end
		if len <= 255 then return "String", TYPE_CODES.String end
		if len <= 65535 then return "Characters", TYPE_CODES.Characters end
		error("String > 65535 bytes")
	end

	if valueType == "buffer" then
		if bufferLen(value) <= 65535 then return "Buffer", TYPE_CODES.Buffer else error("Buffer > 65535 bytes") end
	end

	if valueType == "Vector2" then
		local v2 = value :: Vector2
		if isInteger(v2.X) and isInteger(v2.Y) and
			v2.X >= -32768 and v2.X <= 32767 and v2.Y >= -32768 and v2.Y <= 32767 then
			return "Vector2S16", TYPE_CODES.Vector2S16
		end
		local mag = v2.Magnitude
		if mag <= 262144 then return "Vector2F24", TYPE_CODES.Vector2F24 end
		return "Vector2F32", TYPE_CODES.Vector2F32
	end

	if valueType == "Vector3" then
		local v3 = value :: Vector3
		if isInteger(v3.X) and isInteger(v3.Y) and isInteger(v3.Z) and
			v3.X >= -32768 and v3.X <= 32767 and v3.Y >= -32768 and v3.Y <= 32767 and v3.Z >= -32768 and v3.Z <= 32767 then
			return "Vector3S16", TYPE_CODES.Vector3S16
		end
		local mag = v3.Magnitude
		if mag <= 262144 then return "Vector3F24", TYPE_CODES.Vector3F24 end
		return "Vector3F32", TYPE_CODES.Vector3F32
	end

	if valueType == "CFrame" then
		local cfValue = value :: CFrame
		local posMag = cfValue.Position.Magnitude
		if posMag < 262144 then return "CFrameF24U8", TYPE_CODES.CFrameF24U8 end
		if posMag < 16777216 then return "CFrameF32U16", TYPE_CODES.CFrameF32U16 end
		return "CFrameF32U8", TYPE_CODES.CFrameF32U8
	end

	-- Roblox Types without Subtypes
	if valueType == "Color3" then return "Color3", TYPE_CODES.Color3 end
	if valueType == "NumberRange" then return "NumberRange", TYPE_CODES.NumberRange end
	if valueType == "NumberSequence" then return "NumberSequence", TYPE_CODES.NumberSequence end
	if valueType == "ColorSequence" then return "ColorSequence", TYPE_CODES.ColorSequence end
	if valueType == "BrickColor" then return "BrickColor", TYPE_CODES.BrickColor end
	if valueType == "UDim" then return "UDim", TYPE_CODES.UDim end
	if valueType == "UDim2" then return "UDim2", TYPE_CODES.UDim2 end
	if valueType == "Rect" then return "Rect", TYPE_CODES.Rect end
	if valueType == "Region3" then return "Region3", TYPE_CODES.Region3 end
	if valueType == "EnumItem" then return "EnumItem", TYPE_CODES.EnumItem end
	if valueType == "Instance" then return "Instance", TYPE_CODES.Instance end

	if valueType == "table" then return "Table", 0 end -- Placeholder

	error("Unsupported type for serialization: " .. valueType)
end


--[[ Helper: analyzeTable ]]
local function analyzeTable(tbl: {any}): (TypeCode, TypeName?, TypeCode?)
	local isArray = true
	local count = 0
	local firstElementType: TypeName? = nil
	local firstElementCode: TypeCode? = nil
	local isHomogeneous = true

	for k, v in pairs(tbl) do
		count += 1
		if typeof(k) ~= "number" or k ~= mathFloor(k) or k <= 0 then isArray = false end

		if isHomogeneous then
			local valueTypeName, valueTypeCode = determineType(v)
			if valueTypeName == "Table" or valueTypeName == "Nil" or
				valueTypeName:find("F%d%d?") or valueTypeName:find("Vector") or
				valueTypeName:find("CFrame") or valueTypeName == "Binary" or
				valueTypeName == "Buffer" or valueTypeName == "Instance"
			then
				isHomogeneous = false
			elseif firstElementType == nil then
				firstElementType = valueTypeName
				firstElementCode = valueTypeCode
			elseif valueTypeName ~= firstElementType or valueTypeCode ~= firstElementCode then
				isHomogeneous = false
			end
		end
		if not isArray then isHomogeneous = false end 
	end
	-- Check for sparseness
	if isArray and count ~= #tbl then isArray = false; isHomogeneous = false end

	if isArray and isHomogeneous and count > 0 then
		metrics.homogeneousArrayCount += 1
		return TYPE_CODES.HomogeneousArray, firstElementType, firstElementCode
	else
		metrics.dictionaryCount += 1
		return TYPE_CODES.Dictionary, nil, nil
	end
end

-- [[ Corrected writeTypedValue implementation ]]
writeTypedValue = function(cursor: Cursor.Cursor, value: any)
	local initialTypeName, initialTypeCode = determineType(value)

	if initialTypeName == "Table" then
		-- Analyze table fully before writing any type code
		local specificTableTypeCode, elementTypeName, elementTypeCode = analyzeTable(value :: {any})

		-- Write the correct table type code
		cursor:WriteU1(specificTableTypeCode)

		-- Write table-specific metadata and content
		if specificTableTypeCode == TYPE_CODES.HomogeneousArray then
			cursor:WriteU1(elementTypeCode :: TypeCode)
			local len = #value
			cursor:WriteU2(len)

			local writerFunc = Types.Writes[elementTypeName :: TypeName]
			if not writerFunc then error("Missing writer for homogeneous element type: " .. (elementTypeName or "nil")) end
			for i = 1, len do
				writerFunc(cursor, value[i])
			end
		elseif specificTableTypeCode == TYPE_CODES.Dictionary then
			local count = 0
			for _, _ in pairs(value) do count += 1 end
			cursor:WriteU2(count)

			for k, v in pairs(value) do
				writeTypedValue(cursor, k)
				writeTypedValue(cursor, v)
			end
		end
	else
		-- Not a table: Write the type code
		cursor:WriteU1(initialTypeCode)

		-- Handle data writing or delegation
		if initialTypeName == "Nil" then
			-- No data needed
		else
			-- Delegate ALL other non-Nil, non-Table types
			local writerFunc = Types.Writes[initialTypeName]
			if not writerFunc then error("Missing writer function for type: " .. initialTypeName) end
			writerFunc(cursor, value)
		end
	end
end


--[[ readTypedValue (Recursive) ]]
readTypedValue = function(cursor: Cursor.Cursor): any
	local typeCode = cursor:ReadU1()
	local typeName = BYTE_TO_TYPE_NAME[typeCode]
	if not typeName then error(stringFormat("Unknown type code: 0x%02X", typeCode)) end

	-- Handle specific structures first
	if typeName == "Nil" then return nil end

	if typeName == "HomogeneousArray" then
		local elementTypeCode = cursor:ReadU1()
		local len = cursor:ReadU2()
		local elementTypeName = BYTE_TO_TYPE_NAME[elementTypeCode]
		if not elementTypeName then error(stringFormat("Unknown element type code: 0x%02X", elementTypeCode)) end

		local readerFunc = Types.Reads[elementTypeName]
		if not readerFunc then error("Missing reader for element type: " .. elementTypeName) end

		local resultTable = tableCreate(len)
		for i = 1, len do
			resultTable[i] = readerFunc(cursor)
		end
		return resultTable
	end

	if typeName == "Dictionary" then
		local count = cursor:ReadU2()
		local resultTable = tableCreate(count)
		for _ = 1, count do
			local key = readTypedValue(cursor)
			local value = readTypedValue(cursor)
			resultTable[key] = value
		end
		return resultTable
	end

	if typeName == "JSON" then
		local readerFunc = Types.Reads[typeName]
		if not readerFunc then error("Missing JSON reader") end
		local jsonString = readerFunc(cursor)
		local success, decoded = pcall(HttpService.JSONDecode, HttpService, jsonString)
		if success then return decoded else error("Failed JSON decode: " .. tostring(decoded)) end -- Include error message
	end

	-- Delegate ALL other simple types
	local readerFunc = Types.Reads[typeName]
	if not readerFunc then error("Missing reader function for type: " .. typeName) end
	return readerFunc(cursor)
end

--[[ Serialize ]]
function NetRaySerializer.Serialize(data: any): SerializedResult?
	metrics.serializeCount += 1
	local startTime = tick()
	local resultBuffer: SerializedResult?
	local estimatedSize = NetRaySerializer.EstimateSize(data)
	local buffer = bufferCreate(estimatedSize)
	local cursor = Cursor(buffer)

	local success, err = pcall(writeTypedValue, cursor, data)

	if success then
		resultBuffer = cursor:Truncate()
		metrics.largestSerialized = mathMax(metrics.largestSerialized, bufferLen(resultBuffer))
	else
		-- Handle fallback
		metrics.errors += 1
		metrics.jsonFallbackCount += 1
		warn("Serialize error: ", err, ". Falling back to JSON.")
		local jsonSuccess, jsonString = pcall(HttpService.JSONEncode, HttpService, data)

		if jsonSuccess then
			local jsonBufferSizeEstimate = 1 + 2 + #jsonString -- TypeCode + Length(U2) + String
			local jsonBuffer = bufferCreate(jsonBufferSizeEstimate)
			local jsonCursor = Cursor(jsonBuffer)
			local jsonWriter = Types.Writes["JSON"]
			if jsonWriter then
				jsonCursor:WriteU1(TYPE_CODES.JSON) -- Write JSON type code
				local writeSuccess, writeErr = pcall(jsonWriter, jsonCursor, jsonString) -- Delegate writing JSON string (incl. length)
				if writeSuccess then
					resultBuffer = jsonCursor:Truncate()
				else
					warn("JSON fallback failed - Writer error: ", writeErr)
					resultBuffer = nil
				end
			else
				warn("JSON fallback failed - No JSON writer function in Types module.")
				resultBuffer = nil
			end
		else
			warn("JSON encoding failed: ", jsonString)
			resultBuffer = nil
		end
	end

	metrics.totalSerializeTime += (tick() - startTime)
	return resultBuffer
end

--[[ Deserialize ]]
function NetRaySerializer.Deserialize(buf: buffer): any
	metrics.deserializeCount += 1
	local startTime = tick()
	local result: any

	if not buf or typeof(buf) ~= "buffer" or bufferLen(buf) == 0 then
		metrics.totalDeserializeTime += (tick() - startTime)
		warn("Deserialize: Invalid buffer.")
		return nil
	end

	local cursor = Cursor(buf)
	local initialReadOffset = cursor.Index

	local success, valueOrError = pcall(readTypedValue, cursor)

	if success then
		result = valueOrError
	else
		-- Handle fallback
		metrics.errors += 1
		warn("Deserialize error: ", valueOrError, ". Checking for JSON fallback.")
		cursor.Index = initialReadOffset -- Reset cursor

		if bufferLen(buf) > 0 then
			local typeCodeCheckSuccess, typeCode = pcall(cursor.ReadU1, cursor)
			if typeCodeCheckSuccess and typeCode == TYPE_CODES.JSON then
				warn("Detected JSON type code. Attempting JSON read.")
				local jsonReader = Types.Reads.JSON
				if jsonReader then
					local jsonReadSuccess, jsonStringOrErr = pcall(jsonReader, cursor)
					if jsonReadSuccess then
						local decodeSuccess, decodedData = pcall(HttpService.JSONDecode, HttpService, jsonStringOrErr :: string)
						if decodeSuccess then
							result = decodedData
							warn("JSON fallback successfully decoded.")
						else
							warn("Failed to decode JSON fallback string: ", decodedData)
							result = nil
						end
					else
						warn("Failed to read JSON fallback string data from buffer: ", jsonStringOrErr)
						result = nil
					end
				else
					warn("JSON fallback failed - Missing Types.Reads.JSON function.")
					result = nil
				end
			else
				warn("Fallback check - Data is not marked as JSON or failed to read type code.")
				result = nil
			end
		else
			warn("Fallback check - Buffer too small for type code.")
			result = nil
		end
	end

	metrics.totalDeserializeTime += (tick() - startTime)
	return result
end

--[[ EstimateSize ]]
function NetRaySerializer.EstimateSize(data: any): number
	local valueType = typeof(data)
	if data == nil then return 1 end
	if valueType == "boolean" then return 2 end -- Type Code + 1 byte
	if valueType == "number" then return 5 end -- Avg size + TC
	if valueType == "string" then if #data>0 then local fb = string.byte(data, 1); if fb == BINARY_HEADER_BYTE or fb == UNCOMPRESSED_HEADER_BYTE then return 3 + #data end end; return 3 + #data end
	if valueType == "buffer" then return 3 + bufferLen(data) end
	if valueType == "Vector2" then return 1+6 end -- TC + Avg size
	if valueType == "Vector3" then return 1+10 end-- TC + Avg size
	if valueType == "CFrame" then return 1+18 end -- TC + Avg size
	if valueType == "table" then local est = 3; for k,v in pairs(data) do est += NetRaySerializer.EstimateSize(k) + NetRaySerializer.EstimateSize(v) end; return est * 1.1 end
	if valueType == "Instance" then return 1 + 8 end -- TC + Ref Size
	if valueType == "Color3" then return 1+12 end -- TC + 3*F4
	if valueType == "UDim" then return 1+5 end -- TC + F4 + I4 (approx)
	if valueType == "UDim2" then return 1+10 end -- TC + 2*UDim
	if valueType == "Rect" then return 1+16 end -- TC + 4*F4
	return 1 + 16 -- Generic fallback
end


--[[ GetMetrics ]]
function NetRaySerializer.GetMetrics()
	local metricsCopy = {}
	for k, v in pairs(metrics) do metricsCopy[k] = v end
	metricsCopy.averageSerializeTime = if metrics.serializeCount > 0 then metrics.totalSerializeTime / metrics.serializeCount else 0
	metricsCopy.averageDeserializeTime = if metrics.deserializeCount > 0 then metrics.totalDeserializeTime / metrics.deserializeCount else 0
	return metricsCopy
end

--[[ ResetMetrics ]]
function NetRaySerializer.ResetMetrics()
	metrics = {
		serializeCount = 0, deserializeCount = 0, totalSerializeTime = 0,
		totalDeserializeTime = 0, errors = 0, largestSerialized = 0,
		homogeneousArrayCount = 0, dictionaryCount = 0, jsonFallbackCount = 0,
	}
end

--[[ ClearCache ]]
function NetRaySerializer.ClearCache()
	-- cache clearing logic here later
end

return NetRaySerializer