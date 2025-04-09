--!optimize 2
--!native

--[[
    NetRaySerializer

    Serializes Luau data structures into optimized buffers with type identifiers.
    Implements precise subtype selection for Numbers, Vectors, CFrames, and Booleans.
	Handles Homogeneous Arrays and Dictionaries distinctly.
	
	Only Used in Request function where data send is less frequent and large

	Author: Asta (@TheYusufGamer)
]]

-- Type Imports (assuming these modules export types)
local CursorModule = require(script.Parent.Parent.Types.Cursor)
local TypesModule = require(script.Parent.Parent.Types.Types)

-- Define assumed types for dependencies
type Cursor = CursorModule.Cursor -- Assuming Cursor type with methods/properties
type TypeWriterFunc = (cursor: Cursor, value: any) -> ()
type TypeReaderFunc = (cursor: Cursor) -> any
type TypesRegistry = {
	Writes: { [string]: TypeWriterFunc },
	Reads: { [string]: TypeReaderFunc }
}
-- Use the assumed type for the required module
local Types: TypesRegistry = TypesModule

-- Local function optimizations (standard Lua globals)
local mathFloor = math.floor; local mathAbs = math.abs; local mathMax = math.max
local bufferCreate = buffer.create; local bufferLen = buffer.len
local tableCreate = table.create; local tick = tick; local typeof = typeof
local tostring = tostring; local stringFormat = string.format; local stringByte = string.byte
local pairs = pairs; local ipairs = ipairs; local pcall = pcall
local error = error; local warn = warn

-- Compression Headers (Constants)
local BINARY_HEADER_BYTE: number = 0x02
local UNCOMPRESSED_HEADER_BYTE: number = 0x01

-- Exported Type Definitions
export type TypeName = string -- e.g., "NumberU8", "String", "Dictionary"
export type TypeCode = number -- e.g., 0x00, 0x40, 0xD1
export type SerializedResult = buffer -- The result of Serialize

-- Forward declaration for recursive functions with type annotations
local writeTypedValue: (cursor: Cursor, value: any) -> ()
local readTypedValue: (cursor: Cursor) -> any

-- Module Table Definition
local NetRaySerializer = {}

-- Type for internal metrics structure
type SerializerMetrics = {
	serializeCount: number,
	deserializeCount: number,
	totalSerializeTime: number,
	totalDeserializeTime: number,
	errors: number,
	largestSerialized: number,
	homogeneousArrayCount: number,
	dictionaryCount: number,
	-- Calculated fields from GetMetrics
	averageSerializeTime: number?,
	averageDeserializeTime: number?,
}

-- Type for the main module export
export type NetRaySerializerModule = {
	Serialize: (data: any) -> SerializedResult?, -- Returns buffer on success, nil on error
	Deserialize: (buf: buffer) -> any?, -- Returns deserialized value or nil on error
	EstimateSize: (data: any) -> number, -- Returns estimated byte size
	GetMetrics: () -> SerializerMetrics,
	ResetMetrics: () -> (),
	ClearCache: () -> (), -- Placeholder
}

-- Internal metrics state
local metrics: SerializerMetrics = {
	serializeCount = 0, deserializeCount = 0, totalSerializeTime = 0, totalDeserializeTime = 0,
	errors = 0, largestSerialized = 0, homogeneousArrayCount = 0, dictionaryCount = 0,
}

-- Type Codes Constant Table
local TYPE_CODES: {[string]: TypeCode} = {
	Nil = 0x00,
	NumberU8 = 0x02, NumberU16 = 0x03, NumberU24 = 0x04, NumberU32 = 0x05,
	NumberS8 = 0x10, NumberS16 = 0x11, NumberS24 = 0x12, NumberS32 = 0x13,
	NumberF16 = 0x20, NumberF24 = 0x21, NumberF32 = 0x22, NumberF64 = 0x23,
	Boolean8 = 0x30,
	String = 0x40, Characters = 0x41, Buffer = 0x42, Binary = 0x43,
	Vector2S16 = 0x50, Vector2F24 = 0x51, Vector2F32 = 0x52,
	Vector3S16 = 0x60, Vector3F24 = 0x61, Vector3F32 = 0x62,
	CFrameF24U8 = 0x70, CFrameF32U8 = 0x71, CFrameF32U16 = 0x72,
	Color3 = 0x80, NumberRange = 0x81, NumberSequence = 0x82, ColorSequence = 0x83,
	BrickColor = 0x84, UDim = 0x90, UDim2 = 0x91, Rect = 0x92, Region3 = 0x93,
	EnumItem = 0xA0, Instance = 0xA1,
	HomogeneousArray = 0xD0, Dictionary = 0xD1,
}

-- Reverse Mapping Constant Table
local BYTE_TO_TYPE_NAME: { [TypeCode]: TypeName } = {}
for name, code in pairs(TYPE_CODES) do BYTE_TO_TYPE_NAME[code] = name end -- Populate dynamically

-- Epsilon Constant
local FLOAT_EPSILON = 1e-5

-- Helper: isInteger
local function isInteger(value: number): boolean
	return mathAbs(value - mathFloor(value)) < FLOAT_EPSILON
end

-- Helper: determineType
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
				if numValue >= -128 then return "NumberS8", TYPE_CODES.NumberS8 end -- S8 range includes -128 to 127
				if numValue >= -32768 then return "NumberS16", TYPE_CODES.NumberS16 end
				if numValue >= -8388608 then return "NumberS24", TYPE_CODES.NumberS24 end
				if numValue >= -2147483648 then return "NumberS32", TYPE_CODES.NumberS32 end
			end
		end
		-- Float (fallback if not integer or exceeds int range)
		local magnitude = mathAbs(numValue)
		-- These checks are simplified heuristics, actual float representation is complex.
		-- Check F16/F24 only if magnitude allows reasonable precision, else default F32/F64
		-- This needs refinement based on actual F16/F24 implementation details if used.
		-- Sticking to F32/F64 based on typical ranges for now.
		if magnitude <= 3.402823e+38 then return "NumberF32", TYPE_CODES.NumberF32 -- Approx Max Single Float
		else return "NumberF64", TYPE_CODES.NumberF64 -- Double Float
		end
		-- Simplified F16/F24 logic removed unless specific implementation exists in Types.Writes/Reads
		-- if magnitude <= 2048 then return "NumberF16", TYPE_CODES.NumberF16 end
		-- if magnitude <= 262144 then return "NumberF24", TYPE_CODES.NumberF24 end
		-- if magnitude <= 16777216 then return "NumberF32", TYPE_CODES.NumberF32 end
		-- return "NumberF64", TYPE_CODES.NumberF64
	end

	if valueType == "boolean" then return "Boolean8", TYPE_CODES.Boolean8 end

	if valueType == "string" then
		local len = #value
		if len > 0 then
			local firstByte = stringByte(value, 1)
			if firstByte == BINARY_HEADER_BYTE or firstByte == UNCOMPRESSED_HEADER_BYTE then
				-- Binary should probably be stored as buffer? If passed as string, handle appropriately.
				return "Binary", TYPE_CODES.Binary -- Requires reader/writer to handle string->binary->string
			else
				if len <= 255 then return "String", TYPE_CODES.String
				elseif len <= 65535 then return "Characters", TYPE_CODES.Characters
				else error("String exceeds 65535 bytes limit", 2) end
			end
		else
			return "String", TYPE_CODES.String -- Empty string uses String type code
		end
	end
	if valueType == "buffer" then
		if bufferLen(value) <= 65535 then return "Buffer", TYPE_CODES.Buffer
		else error("Buffer exceeds 65535 bytes limit", 2) end
	end

	if valueType == "Vector2" then
		local v2 = value :: Vector2
		if isInteger(v2.X) and isInteger(v2.Y) and v2.X >= -32768 and v2.X <= 32767 and v2.Y >= -32768 and v2.Y <= 32767 then return "Vector2S16", TYPE_CODES.Vector2S16 end
		-- Refined float checks based on typical usage (F32 is standard)
		return "Vector2F32", TYPE_CODES.Vector2F32 -- Default to F32, F24 optimization might be complex
		-- local mag = v2.Magnitude; if mag <= 262144 then return "Vector2F24", TYPE_CODES.Vector2F24 else return "Vector2F32", TYPE_CODES.Vector2F32 end
	end

	if valueType == "Vector3" then
		local v3 = value :: Vector3
		if isInteger(v3.X) and isInteger(v3.Y) and isInteger(v3.Z) and v3.X >= -32768 and v3.X <= 32767 and v3.Y >= -32768 and v3.Y <= 32767 and v3.Z >= -32768 and v3.Z <= 32767 then return "Vector3S16", TYPE_CODES.Vector3S16 end
		-- Default to F32
		return "Vector3F32", TYPE_CODES.Vector3F32
		-- local mag = v3.Magnitude; if mag <= 262144 then return "Vector3F24", TYPE_CODES.Vector3F24 else return "Vector3F32", TYPE_CODES.Vector3F32 end
	end

	if valueType == "CFrame" then
		-- Simplified CFrame logic, default to a common precise format unless specific optimizations needed
		return "CFrameF32U8", TYPE_CODES.CFrameF32U8 -- Common format balancing precision/size
		-- local cfValue = value :: CFrame; local posMag = cfValue.Position.Magnitude
		-- if posMag < 262144 then return "CFrameF24U8", TYPE_CODES.CFrameF24U8
		-- elseif posMag < 16777216 then return "CFrameF32U8", TYPE_CODES.CFrameF32U8
		-- else return "CFrameF32U16", TYPE_CODES.CFrameF32U16 end
	end

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

	error(stringFormat("Unsupported type for serialization: %s", valueType), 2)
end

-- Helper: analyzeTable
-- Returns: Table Type Code (Dictionary/Homogeneous), Element TypeName?, Element TypeCode?
local function analyzeTable(tbl: {any}): (TypeCode, TypeName?, TypeCode?)
	local count = 0; local maxIndex = 0; local isArray = true
	local firstElementType: TypeName? = nil; local firstElementCode: TypeCode? = nil
	local isHomogeneous = true

	for k, v in pairs(tbl) do
		count += 1
		if typeof(k) == "number" and k == mathFloor(k) and k > 0 then maxIndex = mathMax(maxIndex, k) else isArray = false end
		if isHomogeneous then
			local success, valueTypeNameOrErr, valueTypeCode = pcall(determineType, v)
			if not success then isHomogeneous = false
			else local valueTypeName = valueTypeNameOrErr :: TypeName
				if valueTypeName == "Table" or valueTypeName == "Nil" or valueTypeName == "Instance" or valueTypeName == "Buffer" or valueTypeName == "Binary" then isHomogeneous = false
				elseif firstElementType == nil then firstElementType = valueTypeName; firstElementCode = valueTypeCode
				elseif valueTypeName ~= firstElementType or valueTypeCode ~= firstElementCode then isHomogeneous = false
				end
			end
		end
		if not isArray and not isHomogeneous then break end
	end

	if count == 0 or (isArray and count ~= maxIndex) then isArray = false; isHomogeneous = false end

	if isArray and isHomogeneous then
		metrics.homogeneousArrayCount += 1
		return TYPE_CODES.HomogeneousArray, firstElementType, firstElementCode
	else
		metrics.dictionaryCount += 1
		return TYPE_CODES.Dictionary, nil, nil
	end
end

-- Recursive Writer Function Implementation
writeTypedValue = function(cursor: Cursor, value: any)
	local initialTypeName, initialTypeCode = determineType(value)

	if initialTypeName == "Table" then
		local tblValue = value :: {any} -- Assert table type
		local specificTableTypeCode, elementTypeName, elementTypeCode = analyzeTable(tblValue)
		cursor:WriteU1(specificTableTypeCode)

		if specificTableTypeCode == TYPE_CODES.HomogeneousArray then
			cursor:WriteU1(elementTypeCode :: TypeCode) -- Element type code
			local len = #tblValue
			cursor:WriteU2(len) -- Array length
			local writerFunc = Types.Writes[elementTypeName :: TypeName]
			if not writerFunc then error("Missing writer for homogeneous element type: " .. (elementTypeName or "nil"), 2) end
			for i = 1, len do writerFunc(cursor, tblValue[i]) end -- Write elements

		elseif specificTableTypeCode == TYPE_CODES.Dictionary then
			local count = 0; for _, _ in pairs(tblValue) do count += 1 end
			cursor:WriteU2(count) -- Number of key-value pairs
			for k, v in pairs(tblValue) do
				writeTypedValue(cursor, k) -- Write key (recursively)
				writeTypedValue(cursor, v) -- Write value (recursively)
			end
		end
	else
		-- Not a table, write type code and use specific writer
		cursor:WriteU1(initialTypeCode)
		if initialTypeName ~= "Nil" then -- Don't write data for Nil
			local writerFunc = Types.Writes[initialTypeName]
			if not writerFunc then error("Missing writer function for type: " .. initialTypeName, 2) end
			writerFunc(cursor, value)
		end
	end
end

-- Recursive Reader Function Implementation
readTypedValue = function(cursor: Cursor): any
	local typeCode = cursor:ReadU1()
	local typeName = BYTE_TO_TYPE_NAME[typeCode]
	if not typeName then error(stringFormat("Unknown type code: 0x%02X at pos %d", typeCode, cursor.Index - 1), 2) end

	if typeName == "Nil" then return nil end

	if typeName == "HomogeneousArray" then
		local elementTypeCode = cursor:ReadU1()
		local len = cursor:ReadU2()
		local elementTypeName = BYTE_TO_TYPE_NAME[elementTypeCode]
		if not elementTypeName then error(stringFormat("Unknown element type code for Array: 0x%02X at pos %d", elementTypeCode, cursor.Index - 1), 2) end
		local readerFunc = Types.Reads[elementTypeName]
		if not readerFunc then error("Missing reader for homogeneous element type: " .. elementTypeName, 2) end
		local resultTable = tableCreate(len)
		for i = 1, len do resultTable[i] = readerFunc(cursor) end
		return resultTable

	elseif typeName == "Dictionary" then
		local count = cursor:ReadU2()
		local resultTable = tableCreate(count) -- Pre-allocate approx size
		for _ = 1, count do
			local key = readTypedValue(cursor)
			local value = readTypedValue(cursor)
			if key ~= nil then resultTable[key] = value
			else warn("NetRaySerializer.Deserialize: Nil key encountered in dictionary, value ignored.") end
		end
		return resultTable
	end

	-- Handle simple types
	local readerFunc = Types.Reads[typeName]
	if not readerFunc then error("Missing reader function for type: " .. typeName, 2) end
	return readerFunc(cursor)
end

-- Serialize Public Method
function NetRaySerializer.Serialize(data: any): SerializedResult?
	metrics.serializeCount += 1
	local startTime = tick()
	local resultBuffer: SerializedResult? = nil

	local estimatedSize = NetRaySerializer.EstimateSize(data)
	local bufferInstance = bufferCreate(mathMax(estimatedSize, 16)) -- Use local name
	local cursor = CursorModule(bufferInstance) -- Assume Cursor constructor

	local success, err = pcall(writeTypedValue, cursor, data)

	if success then
		resultBuffer = cursor:Truncate()
		metrics.largestSerialized = mathMax(metrics.largestSerialized, bufferLen(resultBuffer))
	else
		metrics.errors += 1
		warn(stringFormat("NetRaySerializer.Serialize Error: %s", tostring(err)))
	end

	metrics.totalSerializeTime += (tick() - startTime)
	return resultBuffer
end

-- Deserialize Public Method
function NetRaySerializer.Deserialize(buf: buffer): any?
	metrics.deserializeCount += 1
	local startTime = tick()
	local result: any = nil

	if typeof(buf) ~= "buffer" or bufferLen(buf) == 0 then
		warn("NetRaySerializer.Deserialize Error: Input must be a non-empty buffer.")
		metrics.totalDeserializeTime += (tick() - startTime); metrics.errors += 1; return nil
	end

	local cursor = CursorModule(buf) -- Assume Cursor constructor
	local success, valueOrError = pcall(readTypedValue, cursor)

	if success then
		if cursor.Index < bufferLen(buf) then
			warn(stringFormat("NetRaySerializer.Deserialize Warning: Buffer not fully consumed (%d / %d bytes).", cursor.Index, bufferLen(buf)))
		elseif cursor.Index > bufferLen(buf) then
			warn(stringFormat("NetRaySerializer.Deserialize Error: Read past end of buffer (%d / %d bytes).", cursor.Index, bufferLen(buf)))
			metrics.errors += 1; result = nil -- Force nil result on over-read
		end
		-- Assign result only if no critical over-read error occurred
		if cursor.Index <= bufferLen(buf) then
			result = valueOrError
		end
	else
		metrics.errors += 1
		warn(stringFormat("NetRaySerializer.Deserialize Error: %s", tostring(valueOrError)))
		result = nil
	end

	metrics.totalDeserializeTime += (tick() - startTime)
	return result
end

-- EstimateSize Public Method
function NetRaySerializer.EstimateSize(data: any): number
	local valueType = typeof(data)
	local size = 1 -- TypeCode

	if data == nil then return size end
	if valueType == "boolean" then return size + 1 end
	if valueType == "number" then return size + 5 end -- Average guess
	if valueType == "string" then local len = #data; return size + (if len <= 255 then 1 else 2) + len end
	if valueType == "buffer" then return size + 2 + bufferLen(data) end
	if valueType == "Vector2" then return size + 6 end
	if valueType == "Vector3" then return size + 10 end
	if valueType == "CFrame" then return size + 18 end
	if valueType == "Instance" then return size + 8 end -- Ref approx
	if valueType == "Color3" then return size + 12 end
	if valueType == "BrickColor" then return size + 2 end
	if valueType == "UDim" then return size + 8 end
	if valueType == "UDim2" then return size + 16 end
	if valueType == "Rect" then return size + 16 end
	if valueType == "Region3" then return size + 24 end
	if valueType == "NumberRange" then return size + 8 end
	if valueType == "EnumItem" then return size + 4 end
	if valueType == "NumberSequence" then local seq = data :: NumberSequence; return size + 2 + #seq.Keypoints * 12 end
	if valueType == "ColorSequence" then local seq = data :: ColorSequence; return size + 2 + #seq.Keypoints * 16 end

	if valueType == "table" then
		local tbl = data :: {any}
		local est = size + 2; local elementSize = 0; local homo = true
		for k, v in pairs(tbl) do
			if typeof(k) ~= "number" then homo = false end
			est += NetRaySerializer.EstimateSize(k) + NetRaySerializer.EstimateSize(v)
			if homo and elementSize == 0 then elementSize = NetRaySerializer.EstimateSize(v) - 1 end
		end
		if homo and #tbl > 0 then local homoEst = size + 1 + 2 + #tbl * elementSize; return mathMax(4, math.min(est * 1.1, homoEst))
		else return mathMax(3, est * 1.1) end
	end

	warn("NetRaySerializer.EstimateSize: Generic fallback estimate for type:", valueType); return size + 16
end

-- GetMetrics Public Method
function NetRaySerializer.GetMetrics(): SerializerMetrics
	local metricsCopy = {}
	for k, v in pairs(metrics) do metricsCopy[k] = v end
	metricsCopy.averageSerializeTime = if metrics.serializeCount > 0 then metrics.totalSerializeTime / metrics.serializeCount else 0
	metricsCopy.averageDeserializeTime = if metrics.deserializeCount > 0 then metrics.totalDeserializeTime / metrics.deserializeCount else 0
	return metricsCopy :: SerializerMetrics -- Assert return type
end

-- ResetMetrics Public Method
function NetRaySerializer.ResetMetrics()
	metrics = {
		serializeCount = 0, deserializeCount = 0, totalSerializeTime = 0, totalDeserializeTime = 0,
		errors = 0, largestSerialized = 0, homogeneousArrayCount = 0, dictionaryCount = 0,
	} :: SerializerMetrics
end

-- ClearCache Public Method
function NetRaySerializer.ClearCache() end -- No cache implemented yet


return NetRaySerializer :: NetRaySerializerModule