	--!strict
--!optimize 2
--!native

local RunService = game:GetService("RunService")
local LZ4_Lib = require(script.Parent.Compressor)
local CursorModule = require(script.Parent.Parent.Types.Cursor) 
local TypesModule = require(script.Parent.Parent.Types.Types) 


type Cursor = CursorModule.Cursor
type TypeCode = number
type TypeName = string
type SerializedResult = buffer

type StructFieldInfo = {
	Name: string,
	TypeName: TypeName,
	TypeCode: TypeCode,
	ReadFunc: ((cursor: Cursor) -> any)?,
	WriteFunc: ((cursor: Cursor, value: any) -> ())?,
}

type DynamicSenderConfig = {
	MaxBatchSizeTrigger: number,
	DebugMode: boolean,
	StructArrayAllowNils: boolean,
	StructArrayMaxSize: number,
	StructArrayMaxDepth: number,
}

type DynamicSenderMetrics = {
	serializeCount: number,
	deserializeCount: number,
	totalSerializeTime: number,
	totalDeserializeTime: number,
	errors: number,
	lz4Payloads: number,
	structArrayPayloads: number,
	decodeErrors: number,
	sendErrors: number,
	avgSerializeTime: number,
	avgDeserializeTime: number,
}

type SendOptions = {
	batchable: boolean,
	[string]: any
}

export type DynamicSenderModule = {
	VERSION: string,
	Config: DynamicSenderConfig,
	Send: (self: DynamicSenderModule, remote: RemoteEvent, data: any, target: Player?, options: SendOptions) -> (),
	SendToMany: (self: DynamicSenderModule, remote: RemoteEvent, data: any, targets: { Player }, options: SendOptions) -> (),
	DecodeReceivedData: (self: DynamicSenderModule, rawDataBuffer: buffer, rawInstances: {Instance}?) -> {any},
	GetMetrics: (self: DynamicSenderModule) -> DynamicSenderMetrics,
	ResetMetrics: (self: DynamicSenderModule) -> (),
	FlushBatches: (self: DynamicSenderModule) -> (),
}


local BYTE_TO_TYPE_NAME: { [TypeCode]: TypeName } = {}
local TYPE_CODES: { [TypeName]: TypeCode } = {}

local DynamicSender = {}
DynamicSender.VERSION = "1.2.8"


local STRATEGY_LZ4 = 0xF1
local STRATEGY_STRUCT_ARRAY = 0xF2


DynamicSender.Config = {
	MaxBatchSizeTrigger = 16 * 1024,
	DebugMode = false,
	StructArrayAllowNils = false,
	StructArrayMaxSize = 200,
	StructArrayMaxDepth = 1,
}


local isClient = RunService:IsClient()
local isServer = RunService:IsServer()
local batchState: { [RemoteEvent]: { Cursor: Cursor, Targets: { [Player | string]: boolean } } } = {}
local activeRemotes: { [RemoteEvent]: boolean } = {}
local runServiceConnection: RBXScriptConnection | nil = nil

local metrics = {
	serializeCount = 0, deserializeCount = 0, totalSerializeTime = 0, totalDeserializeTime = 0,
	errors = 0, lz4Payloads = 0, structArrayPayloads = 0, decodeErrors = 0, sendErrors = 0
}


local determineTypeForTarget: (value: any) -> (TypeName, TypeCode)
local writeTargetInfoInternal: (cursor: Cursor, value: any) -> ()
local readTargetInfoInternal: (cursor: Cursor) -> any
local writeStructArrayInternal: (cursor: Cursor, data: { { [string]: any } }, structInfo: { StructFieldInfo }) -> ()
local readStructArrayInternal: (cursor: Cursor) -> { { [string]: any } }
local analyzeMetadata: (data: any) -> ({ [string]: any })
local processFrameBatches: (triggeredRemote: RemoteEvent?) -> ()
local getOrCreateBatchCursor: (remote: RemoteEvent) -> (Cursor, { [Player | string]: boolean })
local writeBinaryPayloadInternal: (cursor: Cursor, payload: string) -> ()
local getBestNumberType: (minVal: number, maxVal: number, isFloat: boolean) -> (TypeName, TypeCode)
local isStructArrayCandidate : (data: any, depth: number, config: typeof(DynamicSender.Config)) -> ({ StructFieldInfo }?, number) 


do
	local function addTypeCode(name: string, code: number)
		local isRequired = name=="Nil" or name:find("Number") or name=="Boolean8" or name=="String" or name=="Binary" or name=="Instance"
		if isRequired and name ~= "Nil" and (not TypesModule.Writes[name] or not TypesModule.Reads[name]) then
			error(`[DynamicSender FATAL] Missing Required Type Handler: '${name}'`)
		end
		TYPE_CODES[name] = code
		BYTE_TO_TYPE_NAME[code] = name
	end

	addTypeCode("Nil", 0x00)
	addTypeCode("Boolean8", 0x01)
	addTypeCode("NumberU8", 0x02)
	addTypeCode("NumberU16", 0x03)
	addTypeCode("NumberU24", 0x04)
	addTypeCode("NumberU32", 0x05)
	addTypeCode("NumberS8", 0x10)
	addTypeCode("NumberS16", 0x11)
	addTypeCode("NumberS24", 0x12)
	addTypeCode("NumberS32", 0x13)
	addTypeCode("NumberF16", 0x20)
	addTypeCode("NumberF24", 0x21)
	addTypeCode("NumberF32", 0x22)
	addTypeCode("NumberF64", 0x23)
	addTypeCode("String", 0x40)
	addTypeCode("Characters", 0x41)
	addTypeCode("Buffer", 0x42)
	addTypeCode("Binary", 0x43)

	addTypeCode("Vector2F32", 0x60)
	addTypeCode("Vector2S16", 0x61)
	addTypeCode("Vector2F24", 0x68)
	addTypeCode("Vector3F32", 0x70)
	addTypeCode("Vector3S16", 0x71)
	addTypeCode("Vector3F24", 0x78)
	addTypeCode("Color3", 0x80)
	addTypeCode("BrickColor", 0x81)
	addTypeCode("ColorSequence", 0x88)
	addTypeCode("CFrameF32U16", 0x90)
	addTypeCode("CFrameF32U8", 0x91)
	addTypeCode("CFrameF24U8", 0x92)
	addTypeCode("UDim", 0xA0)
	addTypeCode("UDim2", 0xA1)
	addTypeCode("Rect", 0xA8)
	addTypeCode("Region3", 0xA9)
	addTypeCode("NumberRange", 0xB0)
	addTypeCode("NumberSequence", 0xB1)
	addTypeCode("EnumItem", 0xC0)
	addTypeCode("Instance", 0xC1)


	local function checkAndAddOptional(name: string, proposedCode: number)
		if TypesModule.Writes[name] and TypesModule.Reads[name] and not TYPE_CODES[name] then
			addTypeCode(name, proposedCode)
		end
	end

	assert(TYPE_CODES.Binary and TypesModule.Writes.Binary and TypesModule.Reads.Binary, "Binary type handler is essential and missing.")
	assert(TYPE_CODES.Instance and TypesModule.Writes.Instance and TypesModule.Reads.Instance, "Instance type handler is essential and missing.")
	assert(TYPE_CODES.Nil and TYPE_CODES.Nil == 0x00, "Nil type must be defined and have code 0x00.")


end

local MAX_SERIALIZE_DEPTH = 32

function GetNumberType(n)
	if typeof(n) ~= "number" then return "not a number" end
	return n % 1 == 0 and "integer" or "float"
end


local function isInteger(value: number): boolean
	return GetNumberType(value) == "integer" or (GetNumberType(value) == "float" and math.abs(value - math.floor(value)) < 1e-7 and value > -9007199254740992 and value < 9007199254740992)
end

getBestNumberType = function(minVal: number, maxVal: number, isFloat: boolean): (TypeName, TypeCode)
	if isFloat then
		local maxMagnitude = math.max(math.abs(minVal), math.abs(maxVal))

		if maxMagnitude <= 2048 and TYPE_CODES.NumberF16 then
			return "NumberF16", TYPE_CODES.NumberF16
		elseif maxMagnitude <= 262144 and TYPE_CODES.NumberF24 then
			return "NumberF24", TYPE_CODES.NumberF24
		elseif maxMagnitude <= 16777216 and TYPE_CODES.NumberF32 then
			return "NumberF32", TYPE_CODES.NumberF32
		elseif TYPE_CODES.NumberF64 then
			return "NumberF64", TYPE_CODES.NumberF64
		else
			error("No suitable float handler (F16/F24/F32 missing and F64 missing)")
		end
	end
	-- Integer checks
	if minVal >= 0 then -- Unsigned Candidate
		if maxVal <= 255 and TYPE_CODES.NumberU8 then
			return "NumberU8", TYPE_CODES.NumberU8
		elseif maxVal <= 65535 and TYPE_CODES.NumberU16 then
			return "NumberU16", TYPE_CODES.NumberU16
		elseif maxVal <= 16777215 and TYPE_CODES.NumberU24 then
			return "NumberU24", TYPE_CODES.NumberU24
		elseif maxVal <= 4294967295 and TYPE_CODES.NumberU32 then
			return "NumberU32", TYPE_CODES.NumberU32
		elseif TYPE_CODES.NumberF64 then
			warn("[DynamicSender NumOpt] Value exceeds U32 max for Struct Array field, using F64 fallback.")
			return "NumberF64", TYPE_CODES.NumberF64
		else
			error("F64 handler missing")
		end
	else -- Signed Candidate (minVal < 0)
		if minVal >= -128 and maxVal <= 127 and TYPE_CODES.NumberS8 then
			return "NumberS8", TYPE_CODES.NumberS8
		elseif minVal >= -32768 and maxVal <= 32767 and TYPE_CODES.NumberS16 then
			return "NumberS16", TYPE_CODES.NumberS16
		elseif minVal >= -8388608 and maxVal <= 8388607 and TYPE_CODES.NumberS24 then
			return "NumberS24", TYPE_CODES.NumberS24
		elseif minVal >= -2147483648 and maxVal <= 2147483647 and TYPE_CODES.NumberS32 then
			return "NumberS32", TYPE_CODES.NumberS32
		elseif TYPE_CODES.NumberF64 then
			warn("[DynamicSender NumOpt] Value outside S32 range for Struct Array field, using F64 fallback.")
			return "NumberF64", TYPE_CODES.NumberF64
		else
			error("F64 handler missing")
		end
	end
end

local function getBestVector2Type(stats: {minX:number, maxX:number, minY:number, maxY:number, hasFloat:boolean}): (TypeName?, TypeCode?)
	if stats.hasFloat then
		local maxMagSq = math.max(stats.minX*stats.minX, stats.maxX*stats.maxX, stats.minY*stats.minY, stats.maxY*stats.maxY)
		if maxMagSq <= (262144 * 262144) and TYPE_CODES.Vector2F24 then
			return "Vector2F24", TYPE_CODES.Vector2F24
		elseif TYPE_CODES.Vector2F32 then
			return "Vector2F32", TYPE_CODES.Vector2F32
		end
	else -- Integer
		if stats.minX >= -32768
			and stats.maxX <= 32767
			and stats.minY >= -32768
			and stats.maxY <= 32767
			and TYPE_CODES.Vector2S16
		then
			return "Vector2S16", TYPE_CODES.Vector2S16
		elseif TYPE_CODES.Vector2F32 then
			return "Vector2F32", TYPE_CODES.Vector2F32
		end
	end
	warn("[NetRay StructOpt] Could not find suitable Vector2 handler.")
	return nil, nil
end

local function getBestCFrameType(stats: {
	cfPosMinX:number, cfPosMaxX:number,
	cfPosMinY:number, cfPosMaxY:number,
	cfPosMinZ:number, cfPosMaxZ:number
}): (TypeName?, TypeCode?)

	local maxPosMagSq = math.max(
		stats.cfPosMinX*stats.cfPosMinX, stats.cfPosMaxX*stats.cfPosMaxX,
		stats.cfPosMinY*stats.cfPosMinY, stats.cfPosMaxY*stats.cfPosMaxY,
		stats.cfPosMinZ*stats.cfPosMinZ, stats.cfPosMaxZ*stats.cfPosMaxZ
	)
	local F24_THRESHOLD_SQ = 262144 * 262144
	local F32_THRESHOLD_SQ = 16777216 * 16777216

	if maxPosMagSq < F24_THRESHOLD_SQ and TYPE_CODES.CFrameF24U8 then
		return "CFrameF24U8", TYPE_CODES.CFrameF24U8
	elseif maxPosMagSq < F32_THRESHOLD_SQ and TYPE_CODES.CFrameF32U8 then
		return "CFrameF32U8", TYPE_CODES.CFrameF32U8
	elseif TYPE_CODES.CFrameF32U16 then
		return "CFrameF32U16", TYPE_CODES.CFrameF32U16
	elseif TYPE_CODES.CFrameF32U8 then -- Fallback if F32U16 isn't available but F32U8 is
		return "CFrameF32U8", TYPE_CODES.CFrameF32U8
	elseif TYPE_CODES.CFrameF24U8 then -- Fallback if only F24U8 is available
		return "CFrameF24U8", TYPE_CODES.CFrameF24U8
	end

	warn("[NetRay StructOpt] Could not find any suitable CFrame handler (F24U8/F32U8/F32U16).")
	return nil, nil
end

local function getBestVector3Type(stats: {minX:number,maxX:number,minY:number,maxY:number,minZ:number,maxZ:number, hasFloat:boolean}): (TypeName?, TypeCode?)
	if stats.hasFloat then
		local maxMagSq = math.max(stats.minX*stats.minX, stats.maxX*stats.maxX, stats.minY*stats.minY, stats.maxY*stats.maxY, stats.minZ*stats.minZ, stats.maxZ*stats.maxZ)
		if maxMagSq <= (262144 * 262144) and TYPE_CODES.Vector3F24 then
			return "Vector3F24", TYPE_CODES.Vector3F24
		elseif TYPE_CODES.Vector3F32 then
			return "Vector3F32", TYPE_CODES.Vector3F32
		end
	else -- Integer
		if stats.minX >= -32768
			and stats.maxX <= 32767
			and stats.minY >= -32768
			and stats.maxY <= 32767
			and stats.minZ >= -32768
			and stats.maxZ <= 32767
			and TYPE_CODES.Vector3S16
		then
			return "Vector3S16", TYPE_CODES.Vector3S16
		elseif TYPE_CODES.Vector3F32 then
			return "Vector3F32", TYPE_CODES.Vector3F32
		end
	end
	warn("[NetRay StructOpt] Could not find suitable Vector3 handler.")
	return nil, nil
end


determineTypeForTarget = function(value: any): (TypeName, TypeCode)
	if value == nil then
		return "Nil", TYPE_CODES.Nil
	end
	if typeof(value) == "Instance" and value:IsA("Player") and TYPE_CODES.Instance then
		return "Instance", TYPE_CODES.Instance
	end
	error("Invalid Target Type: "..typeof(value), 2)
end

writeBinaryPayloadInternal = function(cursor: Cursor, payload: string)
	local name = "Binary"
	local code = TYPE_CODES[name]
	local writer = TypesModule.Writes[name]
	assert(code and writer, "Binary type handler is missing")
	cursor:WriteU1(code)
	writer(cursor, payload)
end

writeTargetInfoInternal = function(cursor: Cursor, value: any)
	local typeName, typeCode = determineTypeForTarget(value)
	cursor:WriteU1(typeCode)
	if typeName ~= "Nil" then
		local writer = TypesModule.Writes[typeName]
		assert(writer, "Missing Writer for Target Type: " .. typeName)
		writer(cursor, value)
	end
end

readTargetInfoInternal = function(cursor: Cursor): any
	local typeCode = cursor:ReadU1()
	if typeCode == TYPE_CODES.Nil then
		return nil
	elseif typeCode == TYPE_CODES.Instance then
		local reader = TypesModule.Reads.Instance
		assert(reader, "Missing Reader for Instance Type")
		return reader(cursor)
	else
		error("Invalid Type Code for Target Info: " .. typeCode, 2)
	end
end

isStructArrayCandidate = function(data: any, depth: number, config: typeof(DynamicSender.Config))
	: ({ StructFieldInfo }?, number)

	if depth > config.StructArrayMaxDepth then
		return nil, depth
	end

	if typeof(data) ~= "table" then
		return nil, depth
	end

	local count = #data
	if count == 0 or count > config.StructArrayMaxSize then
		return nil, depth
	end

	local firstElement = data[1]
	if typeof(firstElement) ~= "table" then
		return nil, depth
	end


	local initialFieldInfo: { [string]: {
		Name: string,
		InitialTypeName: TypeName,
		InitialTypeCode: TypeCode?,
		BaseType: string
	} } = {}

	local fieldAnalysis: { [string]: {
		numMin: number?, numMax: number?, numHasNonInt: boolean?,

		v3MinX: number?, v3MaxX: number?,
		v3MinY: number?, v3MaxY: number?,
		v3MinZ: number?, v3MaxZ: number?,
		v3HasFloat: boolean?,

		v2MinX: number?, v2MaxX: number?,
		v2MinY: number?, v2MaxY: number?,
		v2HasFloat: boolean?,

		cfPosMinX: number?, cfPosMaxX: number?,
		cfPosMinY: number?, cfPosMaxY: number?,
		cfPosMinZ: number?, cfPosMaxZ: number?,
	} } = {}

	local keyOrder: { string } = {}

	local maxD = depth

	for key, value in pairs(firstElement) do
		if typeof(key) ~= "string" then
			return nil, maxD
		end

		if value == nil then
			return nil, maxD
		end

		local baseType = typeof(value)
		local initialTypeName: TypeName? = nil
		local initialTypeCode: TypeCode? = nil
		local supported = false
		local analysisData = {}

		if baseType == "number" then
			initialTypeName = "Number"
			supported = true
			local n = value :: number
			analysisData = {
				numMin = n,
				numMax = n,
				numHasNonInt = not isInteger(n)
			}
		elseif baseType == "string" then
			if TYPE_CODES and TYPE_CODES.String then
				initialTypeName, initialTypeCode = "String", TYPE_CODES.String
				supported = true
			else
				supported = false
			end
		elseif baseType == "boolean" then
			if TYPE_CODES and TYPE_CODES.Boolean8 then
				initialTypeName, initialTypeCode = "Boolean8", TYPE_CODES.Boolean8
				supported = true
			else
				supported = false
			end
		elseif baseType == "Vector3" then
			initialTypeName = "Vector3"
			supported = true
			local v = value :: Vector3
			analysisData = {
				v3MinX = v.X, v3MaxX = v.X,
				v3MinY = v.Y, v3MaxY = v.Y,
				v3MinZ = v.Z, v3MaxZ = v.Z,
				v3HasFloat = not (isInteger(v.X) and isInteger(v.Y) and isInteger(v.Z))
			}
		elseif baseType == "Vector2" then
			initialTypeName = "Vector2"
			supported = true
			local v = value :: Vector2
			analysisData = {
				v2MinX = v.X, v2MaxX = v.X,
				v2MinY = v.Y, v2MaxY = v.Y,
				v2HasFloat = not (isInteger(v.X) and isInteger(v.Y))
			}
		elseif baseType == "CFrame" then
			initialTypeName = "CFrame"
			supported = true
			local cf = value :: CFrame
			local p = cf.Position -- Luau knows this is Vector3
			analysisData = {
				cfPosMinX = p.X, cfPosMaxX = p.X,
				cfPosMinY = p.Y, cfPosMaxY = p.Y,
				cfPosMinZ = p.Z, cfPosMaxZ = p.Z,
			}
		elseif baseType == "Color3" then
			if TYPE_CODES and TYPE_CODES.Color3 then
				initialTypeName, initialTypeCode = "Color3", TYPE_CODES.Color3
				supported = true
			else
				supported = false
			end
		elseif baseType == "BrickColor" then
			if TYPE_CODES and TYPE_CODES.BrickColor then
				initialTypeName, initialTypeCode = "BrickColor", TYPE_CODES.BrickColor
				supported = true
			else
				supported = false
			end
		elseif baseType == "UDim" then
			if TYPE_CODES and TYPE_CODES.UDim then
				initialTypeName, initialTypeCode = "UDim", TYPE_CODES.UDim
				supported = true
			else
				supported = false
			end
		elseif baseType == "UDim2" then
			if TYPE_CODES and TYPE_CODES.UDim2 then
				initialTypeName, initialTypeCode = "UDim2", TYPE_CODES.UDim2
				supported = true
			else
				supported = false
			end
		elseif baseType == "Rect" then
			if TYPE_CODES and TYPE_CODES.Rect then
				initialTypeName, initialTypeCode = "Rect", TYPE_CODES.Rect
				supported = true
			else
				supported = false
			end
		elseif baseType == "EnumItem" then
			if TYPE_CODES and TYPE_CODES.EnumItem then
				initialTypeName, initialTypeCode = "EnumItem", TYPE_CODES.EnumItem
				supported = true
			else
				supported = false
			end

		elseif baseType == "Instance" then
			supported = false
		elseif baseType == "buffer" then
			supported = false
		elseif baseType == "NumberRange" then
			supported = false
		elseif baseType == "NumberSequence" then
			supported = false
		elseif baseType == "ColorSequence" then
			supported = false
		elseif baseType == "Region3" then
			supported = false
		elseif baseType == "table" then
			if depth + 1 > config.StructArrayMaxDepth then
				return nil, depth + 1
			end
			supported = false
			maxD = math.max(maxD, depth + 1)
		else
			supported = false
		end

		if not supported then
			return nil, maxD
		end

		table.insert(keyOrder, key)
		initialFieldInfo[key] = {
			Name = key,
			InitialTypeName = initialTypeName :: TypeName,
			InitialTypeCode = initialTypeCode,
			BaseType = baseType
		}
		fieldAnalysis[key] = analysisData
	end

	if #keyOrder == 0 then
		return nil, maxD
	end

	local expectedKeyCount = #keyOrder
	for i = 2, count do
		local element = data[i]

		if typeof(element) ~= "table" then
			return nil, maxD
		end

		local elementKeyCount = 0
		for key, value in pairs(element) do
			elementKeyCount += 1

			local baseInfo = initialFieldInfo[key]
			if not baseInfo then
				return nil, maxD
			end

			if value == nil then
				return nil, maxD
			end

			local valueType = typeof(value)
			if valueType ~= baseInfo.BaseType then
				return nil, maxD
			end

			local analysis = fieldAnalysis[key]
			if not analysis then
				error("Internal Error: Field analysis data missing for key: " .. key)
			end

			if baseInfo.BaseType == "number" then
				local numVal = value :: number
				analysis.numMin = math.min(analysis.numMin or numVal, numVal)
				analysis.numMax = math.max(analysis.numMax or numVal, numVal)
				if not analysis.numHasNonInt and not isInteger(numVal) then
					analysis.numHasNonInt = true
				end
			elseif baseInfo.BaseType == "Vector3" then
				local v = value :: Vector3
				analysis.v3MinX = math.min(analysis.v3MinX or v.X, v.X)
				analysis.v3MaxX = math.max(analysis.v3MaxX or v.X, v.X)
				analysis.v3MinY = math.min(analysis.v3MinY or v.Y, v.Y)
				analysis.v3MaxY = math.max(analysis.v3MaxY or v.Y, v.Y)
				analysis.v3MinZ = math.min(analysis.v3MinZ or v.Z, v.Z)
				analysis.v3MaxZ = math.max(analysis.v3MaxZ or v.Z, v.Z)
				if not analysis.v3HasFloat and not (isInteger(v.X) and isInteger(v.Y) and isInteger(v.Z)) then
					analysis.v3HasFloat = true
				end
			elseif baseInfo.BaseType == "Vector2" then
				local v = value :: Vector2
				analysis.v2MinX = math.min(analysis.v2MinX or v.X, v.X)
				analysis.v2MaxX = math.max(analysis.v2MaxX or v.X, v.X)
				analysis.v2MinY = math.min(analysis.v2MinY or v.Y, v.Y)
				analysis.v2MaxY = math.max(analysis.v2MaxY or v.Y, v.Y)
				if not analysis.v2HasFloat and not (isInteger(v.X) and isInteger(v.Y)) then
					analysis.v2HasFloat = true
				end
			elseif baseInfo.BaseType == "CFrame" then
				local cf = value :: CFrame
				local p = cf.Position :: Vector3
				analysis.cfPosMinX = math.min(analysis.cfPosMinX or p.X, p.X)
				analysis.cfPosMaxX = math.max(analysis.cfPosMaxX or p.X, p.X)
				analysis.cfPosMinY = math.min(analysis.cfPosMinY or p.Y, p.Y)
				analysis.cfPosMaxY = math.max(analysis.cfPosMaxY or p.Y, p.Y)
				analysis.cfPosMinZ = math.min(analysis.cfPosMinZ or p.Z, p.Z)
				analysis.cfPosMaxZ = math.max(analysis.cfPosMaxZ or p.Z, p.Z)
			end
		end

		if elementKeyCount ~= expectedKeyCount then
			return nil, maxD
		end
	end

	local finalStructInfo: { StructFieldInfo } = {}

	for _, key in ipairs(keyOrder) do
		local baseInfo = initialFieldInfo[key]
		local analysis = fieldAnalysis[key]

		local finalTypeName: TypeName = baseInfo.InitialTypeName
		local finalTypeCode: TypeCode? = baseInfo.InitialTypeCode
		local readerFunc
		local writerFunc

		if baseInfo.BaseType == "number" then
			if not analysis or analysis.numMin == nil or analysis.numMax == nil then
				error(string.format("Internal Error: Finalizing number field '%s', but analysis data is incomplete.", key))
			end
			local bestName, bestCode = getBestNumberType(analysis.numMin, analysis.numMax, analysis.numHasNonInt == true)
			if not bestName then
				return nil, maxD
			end
			finalTypeName, finalTypeCode = bestName, bestCode

		elseif baseInfo.BaseType == "Vector3" then
			if not analysis or analysis.v3MinX == nil then
				error(string.format("Internal Error: Finalizing Vector3 field '%s', but analysis data is incomplete.", key))
			end
			local bestName, bestCode = getBestVector3Type(analysis :: any)
			if not bestName then
				return nil, maxD
			end
			finalTypeName, finalTypeCode = bestName, bestCode

		elseif baseInfo.BaseType == "Vector2" then
			if not analysis or analysis.v2MinX == nil then
				error(string.format("Internal Error: Finalizing Vector2 field '%s', but analysis data is incomplete.", key))
			end
			local bestName, bestCode = getBestVector2Type(analysis :: any)
			if not bestName then
				return nil, maxD
			end
			finalTypeName, finalTypeCode = bestName, bestCode

		elseif baseInfo.BaseType == "CFrame" then
			if not analysis or analysis.cfPosMinX == nil then
				error(string.format("Internal Error: Finalizing CFrame field '%s', but analysis data is incomplete.", key))
			end
			local bestName, bestCode = getBestCFrameType(analysis :: any)
			if not bestName then
				return nil, maxD
			end
			finalTypeName, finalTypeCode = bestName, bestCode

		end

		readerFunc = TypesModule.Reads[finalTypeName]
		writerFunc = TypesModule.Writes[finalTypeName]

		-- Validate that handlers and the final type code exist. This is a crucial sanity check.
		if not readerFunc or not writerFunc then
			error(string.format("Struct Array: Read/Write handler missing for finalized type '%s' (Key: %s)", finalTypeName, key))
		end
		if finalTypeCode == nil then
			error(string.format("Struct Array: Final TypeCode is missing for finalized type '%s' (Key: %s)", finalTypeName, key))
		end

		table.insert(finalStructInfo, {
			Name = key,
			TypeName = finalTypeName,
			TypeCode = finalTypeCode :: TypeCode,
			ReadFunc = readerFunc,
			WriteFunc = writerFunc
		})
	end

	table.sort(finalStructInfo, function(a, b)
		return a.Name < b.Name
	end)

	return finalStructInfo, maxD

end -- End of isStructArrayCandidate function

analyzeMetadata = function(data: any): ({ [string]: any })
	local meta = {
		dataType = typeof(data),
		isStructArrayCandidate = false,
		structInfo = nil :: ({ StructFieldInfo }?),
		maxDepth = 0,
	}

	if meta.dataType == "table" then
		meta.structInfo, meta.maxDepth = isStructArrayCandidate(data, 1, DynamicSender.Config)
		meta.isStructArrayCandidate = (meta.structInfo ~= nil)
	else
		meta.maxDepth = 0
	end
	return meta
end

writeStructArrayInternal = function(cursor: Cursor, data: { { [string]: any } }, structInfo: { StructFieldInfo })
	local count = #data
	if count > 65535 then error("Struct count exceeds 65535") end
	cursor:WriteU2(count)

	local fieldCount = #structInfo
	if fieldCount > 255 then error("Struct field count exceeds 255") end
	cursor:WriteU1(fieldCount)

	local nameTypeCode = TYPE_CODES.String
	local nameWriteFunc = TypesModule.Writes.String
	assert(nameTypeCode and nameWriteFunc, "Required Type Handler Missing: String Writer")

	-- Write Header (Field Names & Type Codes)
	for _, field in ipairs(structInfo) do
		cursor:WriteU1(nameTypeCode)
		nameWriteFunc(cursor, field.Name)
		cursor:WriteU1(field.TypeCode)
	end

	-- Write Data Rows
	for i = 1, count do
		local element = data[i]
		if typeof(element) ~= "table" then error("Invalid struct data: element is not a table at index " .. i) end

		for _, field in ipairs(structInfo) do
			local value = element[field.Name]
			assert(value ~= nil, "INTERNAL ERROR: Nil value encountered writing optimized struct array for field '" .. field.Name .. "' at index " .. i)
			assert(field.WriteFunc, "Missing WriteFunc for type: " .. field.TypeName)
			field.WriteFunc(cursor, value)
		end
	end
end


readStructArrayInternal = function(cursor: Cursor): { { [string]: any } }
	local count = cursor:ReadU2()
	local fieldCount = cursor:ReadU1()
	local structInfo = table.create(fieldCount)

	local nameTypeCodeExpected = TYPE_CODES.String
	local nameReadFunc = TypesModule.Reads.String
	assert(nameTypeCodeExpected and nameReadFunc, "Required Type Handler Missing: String Reader")

	-- Read Header
	for i = 1, fieldCount do
		local readNameCode = cursor:ReadU1()
		if readNameCode ~= nameTypeCodeExpected then error("Invalid type code for field name: Expected " .. nameTypeCodeExpected .. ", got " .. readNameCode) end
		local fieldName = nameReadFunc(cursor)

		local fieldTypeCode = cursor:ReadU1()
		local fieldTypeName = BYTE_TO_TYPE_NAME[fieldTypeCode]
		if not fieldTypeName then error("Invalid type code for field '" .. fieldName .. "': " .. fieldTypeCode) end

		local readerFunc = TypesModule.Reads[fieldTypeName]
		assert(readerFunc, "Missing ReadFunc for type: " .. fieldTypeName)

		structInfo[i] = { Name = fieldName, TypeName = fieldTypeName, TypeCode = fieldTypeCode, ReadFunc = readerFunc }
	end

	-- Read Data Rows
	local resultArray = table.create(count)
	for i = 1, count do
		local element = {}
		for _, field in ipairs(structInfo) do
			assert(field.ReadFunc, "Missing ReadFunc for type: " .. field.TypeName)
			local value = field.ReadFunc(cursor)
			element[field.Name] = value
		end
		resultArray[i] = element
	end
	return resultArray
end

local function _serializeSingleMessage(strategy: number, target: Player?, payload: any, structInfo: { StructFieldInfo }?): (buffer?, {Instance}?)
	-- Capture results directly from pcall
	local success, result_or_err, instances_or_nil

	success, result_or_err, instances_or_nil = pcall(function()
		local tempBuffer = buffer.create(1024) -- Start with a reasonable size
		local instances: {Instance} = {}
		local cursor = CursorModule(tempBuffer, instances)

		cursor:WriteU1(strategy)
		if isServer then
			writeTargetInfoInternal(cursor, target)
		end

		if strategy == STRATEGY_LZ4 then
			writeBinaryPayloadInternal(cursor, payload::string)
		elseif strategy == STRATEGY_STRUCT_ARRAY then
			assert(structInfo, "INTERNAL ERROR: structInfo cannot be nil for STRATEGY_STRUCT_ARRAY")
			writeStructArrayInternal(cursor, payload::{any}, structInfo)
		else
			error("Invalid serialization strategy: " .. strategy, 0)
		end

		return cursor:Truncate(), instances -- Return the final sized buffer and instances
	end)

	if success then
		-- Cast to expected types if needed, pcall returns tuple/any
		return result_or_err :: buffer?, instances_or_nil :: {Instance}?
	else
		warn(`[DynamicSender ERR] Failed to serialize single message: ${result_or_err}`)
		metrics.errors += 1
		return nil, nil
	end
end


getOrCreateBatchCursor = function(remote: RemoteEvent): (Cursor, {[Player|string]: boolean})
	local state = batchState[remote]
	if not state then
		-- if DynamicSender.Config.DebugMode then print(`[DynamicSender DBG] Creating new batch state for ${remote:GetFullName()}`) end
		state = {
			Cursor = CursorModule(buffer.create(4096), {}), -- Initial buffer, can grow
			Targets = {}
		}
		batchState[remote] = state
		activeRemotes[remote] = true -- Mark as active for this frame's processing
	end
	return state.Cursor, state.Targets
end

local function sendServerBatch(remote: RemoteEvent, buffer: buffer, instances: {Instance}, targets: { [Player | string]: boolean })
	if targets["all"] then
		-- If 'all' is present, fire to all clients and ignore specific players in this batch
		if remote.FireAllClients then
			remote:FireAllClients(buffer, instances)
			-- if DynamicSender.Config.DebugMode then print(`[DynamicSender DBG] Fired All Clients on ${remote:GetFullName()}`) end
		else
			warn(`[DynamicSender WARN] Attempted FireAllClients on ${remote:GetFullName()}, but the method doesn't exist.`)
			metrics.sendErrors += 1 -- Consider this a send error if the method is missing
		end
		return -- Don't proceed to individual targets if 'all' was specified
	end

	local playersToSendTo = {}
	for targetOrKey, _ in pairs(targets) do
		if typeof(targetOrKey) == "Instance" and targetOrKey:IsA("Player") then
			table.insert(playersToSendTo, targetOrKey)
		end
	end

	if #playersToSendTo > 0 then
		local successes = 0
		local totalTargets = #playersToSendTo

		if remote.FireClient then
			for _, player in ipairs(playersToSendTo) do
				if player.Parent then -- Check if player is still connected
					-- Potentially wrap FireClient in pcall for more robust error handling per player?
					remote:FireClient(player, buffer, instances)
					successes += 1
				else
					-- Player likely disconnected between queuing and sending
					-- if DynamicSender.Config.DebugMode then print(`[DynamicSender DBG] Skipped sending to disconnected player ${player.Name} on ${remote:GetFullName()}`) end
					metrics.sendErrors += 1 -- Count disconnected player as a send error for this batch
				end
			end
		else
			warn(`[DynamicSender WARN] Attempted FireClient on ${remote:GetFullName()}, but the method doesn't exist. Cannot send to ${totalTargets} specific players.`)
			metrics.sendErrors += totalTargets -- Count all intended targets as send errors
			successes = 0 -- Ensure successes reflects the failure
		end

		if successes < totalTargets then
			warn(`[DynamicSender WARN] Successfully sent to ${successes}/${totalTargets} specific targets on ${remote:GetFullName()}. Others might be disconnected or FireClient missing.`)
		-- elseif DynamicSender.Config.DebugMode then
		-- 	print(`[DynamicSender DBG] Sent batch to ${successes}/${totalTargets} specific targets on ${remote:GetFullName()}`)
		end

	-- else -- No specific player targets found
		-- if DynamicSender.Config.DebugMode then
			-- Only log if 'targets' wasn't *only* the 'all' key which is handled above
			-- local hasOnlyAll = targets["all"] and next(targets, "all") == nil
			-- if not hasOnlyAll then
				-- print(`[DynamicSender DBG] No valid player targets found in batch state for ${remote:GetFullName()} after filtering.`)
			-- end
		-- end
	end
end

processFrameBatches = function(triggeredRemote: RemoteEvent?)
	local remotesToActuallyProcess: {[RemoteEvent]: boolean} = {}

	if triggeredRemote then
		remotesToActuallyProcess[triggeredRemote] = true
		activeRemotes[triggeredRemote] = nil -- Remove from the general active list as it's being processed now
		-- if DynamicSender.Config.DebugMode then print(`[DynamicSender DBG] processFrameBatches triggered directly for ${triggeredRemote:GetFullName()}`) end
	end

	-- Process any other remotes that became active during the frame
	if next(activeRemotes) then
		-- if DynamicSender.Config.DebugMode then print(`[DynamicSender DBG] processFrameBatches processing other active remotes`) end
		for remote, _ in pairs(activeRemotes) do
			remotesToActuallyProcess[remote] = true -- Add them to the list to be processed
		end
		activeRemotes = {} -- Clear the general active list for the next frame
	end

	-- If no remotes need processing (neither triggered nor generally active), exit early
	if not next(remotesToActuallyProcess) then
		-- if DynamicSender.Config.DebugMode and not triggeredRemote then print("[DynamicSender DBG] processFrameBatches - No remotes need processing, exiting.") end
		return
	end

	-- local numRemotes = 0; for _ in pairs(remotesToActuallyProcess) do numRemotes+=1 end -- Correct way to count keys
	-- if DynamicSender.Config.DebugMode then print(`[DynamicSender DBG] processFrameBatches - Processing ${numRemotes} remote(s)`) end


	for remote, _ in pairs(remotesToActuallyProcess) do
		if not remote then
			warn("[DynamicSender WARN] Nil remote key found in processing list. Skipping.")
			continue
		end

		local state = batchState[remote]

		-- Skip if state is missing or the buffer is empty
		if not state or state.Cursor.Index == 0 then
			if state then
				state.Targets = {} -- Clear targets just in case
			end
			-- if DynamicSender.Config.DebugMode then print(`[DynamicSender DBG] Skipping ${remote:GetFullName()} - No state or empty buffer.`) end
			continue
		end

		local cursor = state.Cursor
		local targets = state.Targets
		local finalBuffer = cursor:Truncate()
		local finalInstances = cursor.Instances
		local bufferLen = buffer.len(finalBuffer)

		--[[
		if DynamicSender.Config.DebugMode then
			local targetCount = 0; for _ in pairs(targets) do targetCount += 1 end
			print(`[DynamicSender DBG] Processing batch for ${remote:GetFullName()}. Size: ${bufferLen}, Instances: {#finalInstances}, Target Keys: ${targetCount}`)
		end
		--]]

		if isServer then
			sendServerBatch(remote, finalBuffer, finalInstances, targets)
		elseif isClient then
			-- Client sends to Server
			if remote.FireServer then
				-- Potentially wrap in pcall if server errors are frequent/problematic
				remote:FireServer(finalBuffer, finalInstances)
				-- if DynamicSender.Config.DebugMode then print(`[DynamicSender DBG] Fired Server on ${remote:GetFullName()}`) end
			else
				warn(`[DynamicSender WARN] Attempted FireServer on ${remote:GetFullName()}, but the method doesn't exist.`)
				metrics.sendErrors += 1
			end
		end

		-- Reset the batch state for this remote
		cursor:Clear()
		state.Targets = {}
		-- if DynamicSender.Config.DebugMode then print(`[DynamicSender DBG] Cleared batch state for ${remote:GetFullName()}`) end
	end
end


function DynamicSender:Send(remote: RemoteEvent, data: any, target: Player?, options: SendOptions?)
	if not remote then warn("[DynamicSender ERR] Send called with nil RemoteEvent.") return end
	if isClient and target then
		warn("[DynamicSender WARN] Target parameter is ignored when sending from client.")
		target = nil
	end
	if isServer and target and not target:IsA("Player") then
		warn("[DynamicSender ERR] Invalid target provided: Must be a Player instance or nil (for all clients).")
		return
	end
	options = options or {} -- Ensure options table exists

	-- Immediate Send (Non-Batchable)
	if options.batchable == false then
		-- if DynamicSender.Config.DebugMode then print(`[DynamicSender DBG] Send Immediate on ${remote:GetFullName()}, Target: ${target and target.Name or "all/server"}`) end

		local startTime = os.clock()
		local meta = analyzeMetadata(data)
		local strategy: number
		local payload: any
		local structInfo: { StructFieldInfo }? = nil

		if meta.isStructArrayCandidate and meta.structInfo then
			strategy = STRATEGY_STRUCT_ARRAY
			payload = data
			structInfo = meta.structInfo
			metrics.structArrayPayloads += 1
		else
			strategy = STRATEGY_LZ4
			local lz4Ok, lz4Payload = pcall(LZ4_Lib.Compress, LZ4_Lib, data)
			if not lz4Ok or typeof(lz4Payload) ~= "string" then
				warn(`[DynamicSender ERR] Send Immediate LZ4 Compress Failed: ${lz4Payload}. Message cancelled.`)
				metrics.errors += 1
				metrics.totalSerializeTime += (os.clock() - startTime) -- Record time spent even on failure
				return
			end
			payload = lz4Payload :: string
			metrics.lz4Payloads += 1
		end

		metrics.serializeCount += 1
		local messageBuffer, messageInstances = _serializeSingleMessage(strategy, target, payload, structInfo)
		metrics.totalSerializeTime += (os.clock() - startTime)

		if messageBuffer then
			local fireOk, fireErr = pcall(function()
				if isServer then
					if target then
						-- Server sending to specific client
						remote:FireClient(target, messageBuffer, messageInstances)
					else
						-- Server sending to all clients
						remote:FireAllClients(messageBuffer, messageInstances)
					end
				else -- isClient
					-- Client sending to server
					remote:FireServer(messageBuffer, messageInstances)
				end
			end)
			if not fireOk then
				warn(`[DynamicSender ERR] Send Immediate Fire Failed: ${fireErr}`)
				metrics.errors += 1
				metrics.sendErrors += 1
			end
		else
			-- Serialization itself failed (_serializeSingleMessage handles warning and metrics.errors)
			metrics.sendErrors += 1 -- Also count as a send error
		end
		return -- End of immediate send logic
	end


	-- Batched Send (Default)
	local cursor, targets = getOrCreateBatchCursor(remote)
	local meta = analyzeMetadata(data)

	local strategy: number
	local payload: any
	local structInfo: { StructFieldInfo }? = nil

	-- Determine strategy and prepare payload
	if meta.isStructArrayCandidate and meta.structInfo then
		strategy = STRATEGY_STRUCT_ARRAY
		payload = data
		structInfo = meta.structInfo
	else
		strategy = STRATEGY_LZ4
		local lz4Ok, lz4Payload = pcall(LZ4_Lib.Compress, LZ4_Lib, data)
		if not lz4Ok or typeof(lz4Payload) ~= "string" then
			warn(`[DynamicSender ERR] Batched LZ4 Compress Failed: ${lz4Payload}. Message cancelled.`)
			metrics.errors += 1
			return -- Don't add malformed data to batch
		end
		payload = lz4Payload :: string
	end

	-- Attempt to write the message to the batch buffer
	local writeOk, writeErr = pcall(function()
		local startTime = os.clock()
		cursor:WriteU1(strategy)
		if isServer then
			writeTargetInfoInternal(cursor, target) -- Write target info only on server
		end

		if strategy == STRATEGY_LZ4 then
			writeBinaryPayloadInternal(cursor, payload::string)
			metrics.lz4Payloads += 1
		elseif strategy == STRATEGY_STRUCT_ARRAY then
			assert(structInfo, "INTERNAL ERROR: structInfo cannot be nil for batched STRATEGY_STRUCT_ARRAY")
			writeStructArrayInternal(cursor, payload::{any}, structInfo)
			metrics.structArrayPayloads += 1
		else
			error("Invalid serialization strategy for batch write: " .. strategy, 0)
		end

		local duration = os.clock() - startTime
		metrics.serializeCount += 1
		metrics.totalSerializeTime += duration

		--[[if DynamicSender.Config.DebugMode then
			print(`[DynamicSender DBG] Added msg to batch ${remote:GetFullName()}. Strat: ${strategy == STRATEGY_LZ4 and "LZ4" or "StructArr"}, Tgt: ${target and target.Name or "all/server"}, Time: ${string.format("%.5f", duration)}s`)
		end]]

		-- Add target to the batch's target list (server only)
		if isServer then
			targets[target or "all"] = true
		end
	end)

	if not writeOk then
		warn(`[DynamicSender ERR] Failed to write message to batch buffer for ${remote:GetFullName()}: ${writeErr}`)
		metrics.errors += 1
		metrics.sendErrors += 1 -- Count as a send error as it didn't make it into the batch
		return
	end

	-- If data was successfully added, mark the remote as active for end-of-frame processing
	if cursor.Index > 0 then -- Ensure buffer isn't empty before marking active
		activeRemotes[remote] = true
	end

	-- Check if batch size exceeds the trigger threshold and flush if necessary
	if DynamicSender.Config.MaxBatchSizeTrigger > 0 and cursor.Index > DynamicSender.Config.MaxBatchSizeTrigger then
		-- if DynamicSender.Config.DebugMode then print(`[DynamicSender DBG] Batch size ${cursor.Index}/${DynamicSender.Config.MaxBatchSizeTrigger} exceeded for ${remote:GetFullName()}. Triggering flush.`) end
		processFrameBatches(remote) -- Process *only* this remote's batch immediately
	end
end

function DynamicSender:SendToMany(remote: RemoteEvent, data: any, targets: { Player }, options: SendOptions?)
	if not isServer then warn("[DynamicSender SendToMany ERR] SendToMany can only be called from the server.") return end
	if not remote then warn("[DynamicSender SendToMany ERR] RemoteEvent is nil.") return end
	if not targets or #targets == 0 then warn("[DynamicSender SendToMany ERR] Targets list is nil or empty.") return end
	options = options or {} -- Ensure options table exists

	-- SendToMany Immediate (Non-Batchable)
	if options.batchable == false then
		-- if DynamicSender.Config.DebugMode then print(`[DynamicSender DBG] SendToMany Immediate on ${remote:GetFullName()}, Targets: {#targets}`) end
		local successCount = 0
		local meta = analyzeMetadata(data)
		local strategy: number
		local payload: any
		local structInfo: { StructFieldInfo }? = nil

		-- Determine strategy and prepare payload once
		if meta.isStructArrayCandidate and meta.structInfo then
			strategy = STRATEGY_STRUCT_ARRAY
			payload = data
			structInfo = meta.structInfo
			metrics.structArrayPayloads += #targets -- Estimate, could be less if targets invalid
		else
			strategy = STRATEGY_LZ4
			local ok, lzPayload = pcall(LZ4_Lib.Compress, LZ4_Lib, data)
			if not ok or typeof(lzPayload) ~= "string" then
				warn(`[DynamicSender SendToMany ERR] Immediate LZ4 Compress Failed: ${lzPayload}. No messages sent.`)
				metrics.errors += 1
				return
			end
			payload = lzPayload :: string
			metrics.lz4Payloads += #targets -- Estimate
		end

		-- Iterate and send individually
		for _, playerTarget in ipairs(targets) do
			if playerTarget and playerTarget:IsA("Player") and playerTarget.Parent then
				local startTime = os.clock()
				metrics.serializeCount += 1
				local messageBuffer, messageInstances = _serializeSingleMessage(strategy, playerTarget, payload, structInfo)
				metrics.totalSerializeTime += (os.clock() - startTime)

				if messageBuffer then
					local fireOk, fireErr = pcall(remote.FireClient, remote, playerTarget, messageBuffer, messageInstances)
					if fireOk then
						successCount += 1
					else
						warn(`[DynamicSender SendToMany ERR] Immediate FireClient failed for ${playerTarget.Name}: ${fireErr}`)
						metrics.errors += 1
						metrics.sendErrors += 1
					end
				else
					-- Serialization failed for this target, error already warned by _serializeSingleMessage
					metrics.sendErrors += 1
				end
			else
				warn(`[DynamicSender SendToMany WARN] Immediate send skipped invalid/disconnected target: ${tostring(playerTarget)}`)
				metrics.sendErrors += 1
			end
		end

		-- if DynamicSender.Config.DebugMode then print(`[DynamicSender SndM DBG] Immediate send done for ${remote:GetFullName()}. Sent to ${successCount}/${#targets}.`) end
		return -- End of immediate SendToMany logic
	end

	-- SendToMany Batched (Default)
	local successfullyQueued = 0
	local meta = analyzeMetadata(data)
	local strategy: number
	local payloadData: any -- Will hold original data or LZ4 compressed string
	local structInfo: { StructFieldInfo }? = nil

	-- Determine strategy and prepare payload ONCE before the loop
	if meta.isStructArrayCandidate and meta.structInfo then
		strategy = STRATEGY_STRUCT_ARRAY
		payloadData = data -- Keep original table for struct array
		structInfo = meta.structInfo
	else
		strategy = STRATEGY_LZ4
		local lz4Ok, lz4Compressed = pcall(LZ4_Lib.Compress, LZ4_Lib, data)
		if not lz4Ok or typeof(lz4Compressed) ~= "string" then
			warn(`[DynamicSender SendToMany ERR] Batched LZ4 Compress Failed: ${lz4Compressed}. No messages queued.`)
			metrics.errors += 1
			return
		end
		payloadData = lz4Compressed :: string -- Store compressed payload
	end

	-- Loop through targets and add to batch
	for _, playerTarget in ipairs(targets) do
		if playerTarget and playerTarget:IsA("Player") and playerTarget.Parent then
			local cursor, batchTargets = getOrCreateBatchCursor(remote)

			local writeOk, writeErr = pcall(function()
				local startTime = os.clock()
				cursor:WriteU1(strategy)
				writeTargetInfoInternal(cursor, playerTarget) -- Essential for server batching

				if strategy == STRATEGY_LZ4 then
					writeBinaryPayloadInternal(cursor, payloadData::string)
					metrics.lz4Payloads += 1
				elseif strategy == STRATEGY_STRUCT_ARRAY then
					assert(structInfo, "INTERNAL ERROR: structInfo nil for batched SendToMany STRATEGY_STRUCT_ARRAY")
					-- Note: Passing the *original* data table here, NOT compressed payload
					writeStructArrayInternal(cursor, payloadData::{any}, structInfo)
					metrics.structArrayPayloads += 1
				else
					error("Invalid strategy during batched SendToMany write: " .. strategy, 0)
				end

				local duration = os.clock() - startTime
				metrics.serializeCount += 1
				metrics.totalSerializeTime += duration

				--[[if DynamicSender.Config.DebugMode then
					print(`[DynamicSender SndM DBG] Added msg to batch for ${playerTarget.Name} on ${remote:GetFullName()}. Strat: ${strategy == STRATEGY_LZ4 and "LZ4" or "StructArr"}, Time: ${string.format("%.5f", duration)}s`)
				end]]

				batchTargets[playerTarget] = true -- Mark this player as a target for this batch
				successfullyQueued += 1
			end)

			if not writeOk then
				warn(`[DynamicSender SendToMany ERR] Failed to write message to batch for ${playerTarget.Name}: ${writeErr}`)
				metrics.errors += 1
				metrics.sendErrors += 1
				continue -- Skip to next target if write fails for one
			end

			-- After successful write, mark remote active and check flush trigger
			if cursor.Index > 0 then
				activeRemotes[remote] = true
			end

			if DynamicSender.Config.MaxBatchSizeTrigger > 0 and cursor.Index > DynamicSender.Config.MaxBatchSizeTrigger then
				-- if DynamicSender.Config.DebugMode then print(`[DynamicSender SndM DBG] Flush triggered during SendToMany for ${remote:GetFullName()}.`) end
				processFrameBatches(remote)
			end
		else
			warn(`[DynamicSender SendToMany WARN] Batched send skipped invalid/disconnected target: ${tostring(playerTarget)}`)
			metrics.sendErrors += 1 -- Count skipped target as send error
		end
	end

	-- if DynamicSender.Config.DebugMode then print(`[DynamicSender SndM DBG] Batch queuing done for ${remote:GetFullName()}. Queued ${successfullyQueued}/${#targets} messages.`) end
end


function DynamicSender:DecodeReceivedData(rawDataBuffer: buffer, rawInstances: {Instance}?): {any}
	if typeof(rawDataBuffer) ~= "buffer" then
		if rawDataBuffer == nil then
			-- Handle potential nil case gracefully (e.g., maybe an immediate send failed before Fire?)
			-- if DynamicSender.Config.DebugMode then print("[DynamicSender DBG] DecodeReceivedData received nil buffer, returning empty table.") end
			return {}
		end
		warn("[DynamicSender ERR] Invalid data type received in DecodeReceivedData: Expected 'buffer', got '" .. typeof(rawDataBuffer) .. "'")
		metrics.decodeErrors += 1
		return {} -- Return empty table on incorrect type
	end

	if buffer.len(rawDataBuffer) == 0 then return {} end -- Empty buffer means no messages

	-- Validate instances or default to empty table
	if rawInstances and typeof(rawInstances) ~= "table" then
		warn("[DynamicSender WARN] Received instances argument is not a table, ignoring.")
		rawInstances = {}
	end

	local decodedMessages = {}
	local startTime = os.clock()
	local cursor = CursorModule(rawDataBuffer, rawInstances or {}) -- Use provided instances or empty table

	while cursor.Index < buffer.len(rawDataBuffer) do
		local messageStartIndex = cursor.Index -- Track start index for error reporting
		local success, messageDataOrError = pcall(function()
			local strategy = cursor:ReadU1()
			if not strategy then error("Failed to read strategy byte", 0) end

			-- Server receives target info, client discards it
			if isClient then
				-- Need to read target info even if not used, to advance cursor correctly
				readTargetInfoInternal(cursor)
			end -- Server logic already handled reading target if present inside _serializeSingleMessage logic if required for batch processing etc. but for incoming general payload we don't use it directly here

			local finalData: any
			if strategy == STRATEGY_LZ4 then
				-- Expect Binary type marker
				local payloadTypeCode = cursor:ReadU1()
				if payloadTypeCode ~= TYPE_CODES.Binary then
					error("Expected Binary type code ("..TYPE_CODES.Binary.."), got "..payloadTypeCode, 0)
				end
				local reader = TypesModule.Reads.Binary
				if not reader then error("Binary type reader is missing", 0) end

				local serializedPayload = reader(cursor)
				if typeof(serializedPayload) ~= "string" then
					error("Binary reader did not return a string", 0)
				end

				local lzOk, lzResult = pcall(LZ4_Lib.Decompress, LZ4_Lib, serializedPayload)
				if not lzOk then
					warn(`[DynamicSender ERR] LZ4 Decompression failed: ${lzResult}`)
					error("LZ4 Decompression failure", 0) -- Propagate error within pcall
				end
				finalData = lzResult

			elseif strategy == STRATEGY_STRUCT_ARRAY then
				finalData = readStructArrayInternal(cursor) -- This function has its own asserts/errors
			else
				error("Unknown serialization strategy marker received: " .. strategy, 0)
			end
			return finalData
		end)

		if success then
			table.insert(decodedMessages, messageDataOrError)
			metrics.deserializeCount += 1
		else
			warn(`[DynamicSender ERR] Failed to decode message starting at index ${messageStartIndex}: ${tostring(messageDataOrError)}`)
			metrics.errors += 1
			metrics.decodeErrors += 1
			warn("[DynamicSender ERR] Halting further decoding of this batch due to error.")
			break -- Stop processing the rest of the buffer if one message fails
		end
	end

	metrics.totalDeserializeTime += (os.clock() - startTime)
	-- if DynamicSender.Config.DebugMode then print(`[DynamicSender DBG] Decode finished. Decoded ${#decodedMessages} messages.`) end
	return decodedMessages
end


function DynamicSender.GetMetrics(): DynamicSenderMetrics
	local metricsCopy = {}
	for k, v in pairs(metrics) do
		metricsCopy[k] = v
	end

	-- Calculate averages safely
	local avgSerializeTime = 0
	if metrics.serializeCount > 0 then
		avgSerializeTime = metrics.totalSerializeTime / metrics.serializeCount
	end
	local avgDeserializeTime = 0
	if metrics.deserializeCount > 0 then
		avgDeserializeTime = metrics.totalDeserializeTime / metrics.deserializeCount
	end

	metricsCopy.avgSerializeTime = avgSerializeTime
	metricsCopy.avgDeserializeTime = avgDeserializeTime

	return metricsCopy
end

function DynamicSender:ResetMetrics()
	for k, _ in pairs(metrics) do
		if typeof(metrics[k]) == "number" then -- Reset only numbers
			metrics[k] = 0
		end
	end
	-- Explicitly reset times as they might not be in the loop if structure changes
	metrics.totalSerializeTime = 0
	metrics.totalDeserializeTime = 0
end

function DynamicSender:FlushBatches()
	-- if DynamicSender.Config.DebugMode then print("[DynamicSender] Manual batch flush initiated.") end
	processFrameBatches() -- Process all active remotes now
end


-- Connect batch processor only once
if not runServiceConnection then
	runServiceConnection = RunService.Heartbeat:Connect(processFrameBatches)
	-- if DynamicSender.Config.DebugMode then print("[DynamicSender] Automatic batch processing connected via Heartbeat.") end
end

-- Server-side shutdown handling
if isServer then
	game:BindToClose(function()
		warn("[DynamicSender] Server closing: Attempting to flush remaining batches...")
		local ok, err = pcall(processFrameBatches) -- Attempt to process any remaining batches
		if not ok then
			warn(`[DynamicSender] Error during shutdown flush: ${err}`)
		end
		-- Small wait might allow network messages to send, but not guaranteed
		task.wait(0.1)
		if runServiceConnection then
			runServiceConnection:Disconnect()
			runServiceConnection = nil
			warn("[DynamicSender] Heartbeat connection disconnected.")
		end
		warn("[DynamicSender] Shutdown processing finished.")
	end)
end

return DynamicSender