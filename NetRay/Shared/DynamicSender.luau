--!strict
--!optimize 2
--!native

--[[
    DynamicSender Module (v1.3.0 - Refactored Batching & Type Safety)

    Implements dynamic strategy selection (LZ4 or Struct Array) for serialization.
    Handles frame-based batching for network efficiency using per-target queues.
    Requires correctly configured dependencies: Compressor (LZ4_Lib), Cursor, and Types.

    Author: Asta (@TheYusufGamer)
    Refactoring Contributor: AI Assistant
]]

--==============================================================================
-- Dependencies
--==============================================================================

local RunService = game:GetService("RunService")
local LZ4_Lib = require(script.Parent.Compressor)
local CursorModule = require(script.Parent.Parent.Types.Cursor)
local TypesModule = require(script.Parent.Parent.Types.Types)

--==============================================================================
-- Type Imports / Exports
--==============================================================================

type Cursor = CursorModule.Cursor
type TypeCode = number
type TypeName = string
type SerializedResult = buffer
type AnyRemoteEvent = RemoteEvent | UnreliableRemoteEvent -- Type alias for flexibility

-- Struct definition for optimized array serialization
type StructFieldInfo = {
	Name: string,
	TypeName: TypeName, -- Can be "Nil"
	TypeCode: TypeCode,
	ReadFunc: ((cursor: Cursor) -> any)?, -- Nil if TypeName is "Nil"
	WriteFunc: ((cursor: Cursor, value: any) -> ())?, -- Nil if TypeName is "Nil"
}

-- Type for the module's Config table
type DynamicSenderConfig = {
	MaxBatchSizeTrigger: number,
	DebugMode: boolean,
	StructArrayAllowNils: boolean,
	StructArrayMaxSize: number,
	StructArrayMaxDepth: number,
}

-- Type for the module's Metrics table (based on GetMetrics return)
type DynamicSenderMetrics = {
	serializeCount: number,
	deserializeCount: number,
	totalSerializeTime: number,
	totalDeserializeTime: number,
	errors: number,
	lz4Payloads: number,
	structArrayPayloads: number,
	decodeErrors: number,
	sendErrors: number, -- Note: May be less accurate without pcall on Fire methods
	avgSerializeTime: number,
	avgDeserializeTime: number,
}

type SendOptions = {
	batchable: boolean?, -- If false, sends immediately bypassing the batcher (defaults true)
	[string]: any -- Allow other keys
}

-- Type definition for the DynamicSender module export
export type DynamicSenderModule = {
	VERSION: string,
	Config: DynamicSenderConfig,
	Send: (self: DynamicSenderModule, remote: AnyRemoteEvent, data: any, target: Player?, options: SendOptions?) -> (),
	SendToMany: (self: DynamicSenderModule, remote: AnyRemoteEvent, data: any, targets: { Player }, options: SendOptions?) -> (),
	DecodeReceivedData: (self: DynamicSenderModule, rawDataBuffer: buffer, rawInstances: {Instance}?) -> {any},
	GetMetrics: (self: DynamicSenderModule) -> DynamicSenderMetrics,
	ResetMetrics: (self: DynamicSenderModule) -> (),
	FlushBatches: (self: DynamicSenderModule) -> (),
}

--==============================================================================
-- Local Type Mappings & Module Setup
--==============================================================================

local BYTE_TO_TYPE_NAME: { [TypeCode]: TypeName } = {}
local TYPE_CODES: { [TypeName]: TypeCode } = {}

local DynamicSender = {}
DynamicSender.VERSION = "1.3.0"

--==============================================================================
-- Constants
--==============================================================================

-- Strategy markers within the DynamicSender batch buffer
local STRATEGY_LZ4 = 0xF1
local STRATEGY_STRUCT_ARRAY = 0xF2

--==============================================================================
-- Configuration
--==============================================================================

DynamicSender.Config = {
	MaxBatchSizeTrigger = 8 * 1024, -- Flush buffer if total bytes exceeds this threshold
	DebugMode = false,
	StructArrayAllowNils = false,
	StructArrayMaxSize = 200,        -- Max elements allowed for Struct Array strategy
	StructArrayMaxDepth = 1,         -- Max nesting allowed within Struct Array elements (1 = no nested tables)
}

--==============================================================================
-- Internal State
--==============================================================================

local isClient = RunService:IsClient()
local isServer = RunService:IsServer()

-- Refactored Batch State: Holds per-player cursors and a shared 'all' cursor per remote
local batchState: { [AnyRemoteEvent]: { PerPlayerCursors: { [Player]: Cursor }, AllCursor: Cursor? } } = {}
local activeRemotes: { [AnyRemoteEvent]: boolean } = {} -- Tracks remotes with pending data in *any* cursor
local runServiceConnection: RBXScriptConnection | nil = nil

-- Performance Metrics
local metrics = {
	serializeCount = 0, deserializeCount = 0, totalSerializeTime = 0, totalDeserializeTime = 0,
	errors = 0, lz4Payloads = 0, structArrayPayloads = 0, decodeErrors = 0, sendErrors = 0
}

--==============================================================================
-- Forward Declarations
--==============================================================================

-- Note: Removed determineTypeForTarget, writeTargetInfoInternal, readTargetInfoInternal as they are no longer used in the core batching/decode flow
local writeStructArrayInternal: (cursor: Cursor, data: { { [string]: any } }, structInfo: { StructFieldInfo }) -> ()
local readStructArrayInternal: (cursor: Cursor) -> { { [string]: any } }
local analyzeMetadata: (data: any) -> ({ [string]: any })
local processFrameBatches: (triggeredRemote: AnyRemoteEvent?) -> ()
local getOrCreateBatchCursor: (remote: AnyRemoteEvent, target: Player?) -> Cursor
local writeBinaryPayloadInternal: (cursor: Cursor, payload: string) -> ()
local getBestNumberType: (minVal: number, maxVal: number, isFloat: boolean) -> (TypeName, TypeCode)
local isStructArrayCandidate : (data: any, depth: number, config: typeof(DynamicSender.Config)) -> ({ StructFieldInfo }?, number)
local _serializeSingleMessage: (strategy: number, payload: any, structInfo: { StructFieldInfo }?) -> (buffer?, {Instance}?) -- No longer needs target

--==============================================================================
-- Type Mapping Population
--==============================================================================

do
	local function addTypeCode(name: string, code: number)
		local isRequired = name=="Nil" or name:find("Number") or name=="Boolean8" or name=="String" or name=="Binary" or name=="Instance"
		if isRequired and name ~= "Nil" and (not TypesModule.Writes[name] or not TypesModule.Reads[name]) then
			error(`[DynamicSender FATAL] Missing Required Type Handler: '${name}'`)
		end
		TYPE_CODES[name] = code
		BYTE_TO_TYPE_NAME[code] = name
	end

	-- Add required type mappings (Codes loosely based on potential usage frequency)
	addTypeCode("Nil", 0x00)
	addTypeCode("Boolean8", 0x01)
	addTypeCode("NumberU8", 0x02); addTypeCode("NumberU16", 0x03); addTypeCode("NumberU24", 0x04); addTypeCode("NumberU32", 0x05);
	addTypeCode("NumberS8", 0x10); addTypeCode("NumberS16", 0x11); addTypeCode("NumberS24", 0x12); addTypeCode("NumberS32", 0x13);
	addTypeCode("NumberF16", 0x20); addTypeCode("NumberF24", 0x21); addTypeCode("NumberF32", 0x22); addTypeCode("NumberF64", 0x23);
	addTypeCode("String", 0x40)       -- Standard String (U1 Length)
	addTypeCode("Characters", 0x41) -- Compact Character String
	addTypeCode("Buffer", 0x42)     -- Standard Buffer (U1 Length)
	addTypeCode("Binary", 0x43)     -- Binary Payload (U3 Length for LZ4)

	-- Roblox Types (Grouped for readability)
	addTypeCode("Vector2F32", 0x60); addTypeCode("Vector2S16", 0x61); addTypeCode("Vector2F24", 0x68); -- 0x60-0x6F Vector2
	addTypeCode("Vector3F32", 0x70); addTypeCode("Vector3S16", 0x71); addTypeCode("Vector3F24", 0x78); -- 0x70-0x7F Vector3
	addTypeCode("Color3", 0x80)       -- 0x80-0x8F Colors
	addTypeCode("BrickColor", 0x81)
	addTypeCode("ColorSequence", 0x88)
	addTypeCode("CFrameF32U16", 0x90); addTypeCode("CFrameF32U8", 0x91); addTypeCode("CFrameF24U8", 0x92); -- 0x90-0x9F CFrames
	addTypeCode("UDim", 0xA0); addTypeCode("UDim2", 0xA1); -- 0xA0-0xA7 UDim
	addTypeCode("Rect", 0xA8)          -- 0xA8-0xAF Rect/Region
	addTypeCode("Region3", 0xA9)
	addTypeCode("NumberRange", 0xB0); addTypeCode("NumberSequence", 0xB1); -- 0xB0-0xBF Sequences/Ranges
	addTypeCode("EnumItem", 0xC0);     -- 0xC0-0xCF Enums/Instances
	addTypeCode("Instance", 0xC1)      -- Important: Instance is distinct from Nil Player Target


	-- Dynamically add missing optional types if handlers exist
	local function checkAndAddOptional(name: string, proposedCode: number)
		if TypesModule.Writes[name] and TypesModule.Reads[name] and not TYPE_CODES[name] then
			addTypeCode(name, proposedCode)
		end
	end

	-- Note: Ensure Binary (0x43) and Instance (0xC1) handlers are present due to their usage in core logic.
	assert(TYPE_CODES.Binary and TypesModule.Writes.Binary and TypesModule.Reads.Binary, "Binary type handler is essential and missing.")
	assert(TYPE_CODES.Instance and TypesModule.Writes.Instance and TypesModule.Reads.Instance, "Instance type handler is essential and missing.")
	assert(TYPE_CODES.Nil and TYPE_CODES.Nil == 0x00, "Nil type must be defined and have code 0x00.")


end

--==============================================================================
-- Serialization / Deserialization Helpers
--==============================================================================

local MAX_SERIALIZE_DEPTH = 32

function GetNumberType(n)
	if typeof(n) ~= "number" then return "not a number" end
	return n % 1 == 0 and "integer" or "float"
end


-- Check if a number is an integer (handles floating point inaccuracies)
local function isInteger(value: number): boolean
	return GetNumberType(value) == "integer" or (GetNumberType(value) == "float" and math.abs(value - math.floor(value)) < 1e-7 and value > -9007199254740992 and value < 9007199254740992)
end

-- Helper to find the best fitting number type based on range and float status
getBestNumberType = function(minVal: number, maxVal: number, isFloat: boolean): (TypeName, TypeCode)
	-- Assumes minVal and maxVal are valid numbers as Nils were filtered
	if isFloat then
		local maxMagnitude = math.max(math.abs(minVal), math.abs(maxVal))

		if maxMagnitude <= 2048 and TYPE_CODES.NumberF16 then
			return "NumberF16", TYPE_CODES.NumberF16
		elseif maxMagnitude <= 262144 and TYPE_CODES.NumberF24 then
			return "NumberF24", TYPE_CODES.NumberF24
		elseif maxMagnitude <= 16777216 and TYPE_CODES.NumberF32 then
			return "NumberF32", TYPE_CODES.NumberF32
		elseif TYPE_CODES.NumberF64 then
			-- Fallback to F64 if magnitude exceeds F32 range or smaller handlers absent
			return "NumberF64", TYPE_CODES.NumberF64
		else
			error("No suitable float handler (F16/F24/F32 missing and F64 missing)")
		end
	end
	-- Integer checks - check MUST be paired with TYPE_CODES existence
	if minVal >= 0 then -- Unsigned Candidate
		if maxVal <= 255 and TYPE_CODES.NumberU8 then return "NumberU8", TYPE_CODES.NumberU8 end
		if maxVal <= 65535 and TYPE_CODES.NumberU16 then return "NumberU16", TYPE_CODES.NumberU16 end
		if maxVal <= 16777215 and TYPE_CODES.NumberU24 then return "NumberU24", TYPE_CODES.NumberU24 end
		if maxVal <= 4294967295 and TYPE_CODES.NumberU32 then return "NumberU32", TYPE_CODES.NumberU32 end
		warn("[DynamicSender NumOpt] Value exceeds U32 max for Struct Array field, using F64 fallback."); if TYPE_CODES.NumberF64 then return "NumberF64", TYPE_CODES.NumberF64 else error("F64 handler missing") end
	else -- Signed Candidate (minVal < 0)
		if minVal >= -128 and maxVal <= 127 and TYPE_CODES.NumberS8 then return "NumberS8", TYPE_CODES.NumberS8 end
		if minVal >= -32768 and maxVal <= 32767 and TYPE_CODES.NumberS16 then return "NumberS16", TYPE_CODES.NumberS16 end
		if minVal >= -8388608 and maxVal <= 8388607 and TYPE_CODES.NumberS24 then return "NumberS24", TYPE_CODES.NumberS24 end
		if minVal >= -2147483648 and maxVal <= 2147483647 and TYPE_CODES.NumberS32 then return "NumberS32", TYPE_CODES.NumberS32 end
		warn("[DynamicSender NumOpt] Value outside S32 range for Struct Array field, using F64 fallback."); if TYPE_CODES.NumberF64 then return "NumberF64", TYPE_CODES.NumberF64 else error("F64 handler missing") end
	end
end

-- Helper function to determine the best Vector2 subtype based on stats
local function getBestVector2Type(stats: {minX:number, maxX:number, minY:number, maxY:number, hasFloat:boolean}): (TypeName?, TypeCode?)
	if stats.hasFloat then
		-- Floating point needed
		-- Use magnitude squared for comparison to avoid sqrt
		local maxMagSq = math.max(stats.minX*stats.minX, stats.maxX*stats.maxX, stats.minY*stats.minY, stats.maxY*stats.maxY)
		-- Heuristic: Small magnitude might fit F24? Else F32. S16 check already failed.
		-- Adjust threshold based on F24 precision/range if available
		if maxMagSq <= (262144*262144) and TYPE_CODES.Vector2F24 then
			return "Vector2F24", TYPE_CODES.Vector2F24
		end
		-- Default float type
		if TYPE_CODES.Vector2F32 then
			return "Vector2F32", TYPE_CODES.Vector2F32
		end
	else
		-- All integer components
		if stats.minX >= -32768 and stats.maxX <= 32767 and
			stats.minY >= -32768 and stats.maxY <= 32767 and TYPE_CODES.Vector2S16 then
			return "Vector2S16", TYPE_CODES.Vector2S16
		end
		-- If S16 fails, fallback to a float type (F32 is safest default)
		if TYPE_CODES.Vector2F32 then
			return "Vector2F32", TYPE_CODES.Vector2F32
		end
	end
	-- If no suitable handler is found (e.g., missing F32 and others fail)
	warn("[NetRay StructOpt] Could not find suitable Vector2 handler.")
	return nil, nil
end

-- Helper function to determine the best CFrame subtype based on stats
-- Note: Optimizing CFrames is complex. This is a simplified heuristic based mainly on position magnitude
-- and assumes rotation components might correlate. More advanced analysis could check rotation matrix components.
-- Stats now only contain position component min/max
local function getBestCFrameType(stats: {
	cfPosMinX:number, cfPosMaxX:number,
	cfPosMinY:number, cfPosMaxY:number,
	cfPosMinZ:number, cfPosMaxZ:number
	}): (TypeName?, TypeCode?)

	-- Calculate max position component magnitude squared from the provided stats
	local maxPosMagSq = math.max(
		stats.cfPosMinX*stats.cfPosMinX, stats.cfPosMaxX*stats.cfPosMaxX,
		stats.cfPosMinY*stats.cfPosMinY, stats.cfPosMaxY*stats.cfPosMaxY,
		stats.cfPosMinZ*stats.cfPosMinZ, stats.cfPosMaxZ*stats.cfPosMaxZ
	)
	-- Avoid square root if possible by comparing against squared thresholds
	-- Thresholds: F24 approx 262144, F32 approx 16777216
	local F24_THRESHOLD_SQ = 262144 * 262144
	local F32_THRESHOLD_SQ = 16777216 * 16777216

	-- Choose subtype based on position magnitude heuristic and available types
	if maxPosMagSq < F24_THRESHOLD_SQ and TYPE_CODES.CFrameF24U8 then
		return "CFrameF24U8", TYPE_CODES.CFrameF24U8
	elseif maxPosMagSq < F32_THRESHOLD_SQ and TYPE_CODES.CFrameF32U8 then
		return "CFrameF32U8", TYPE_CODES.CFrameF32U8
	elseif TYPE_CODES.CFrameF32U16 then
		return "CFrameF32U16", TYPE_CODES.CFrameF32U16
	elseif TYPE_CODES.CFrameF32U8 then
		return "CFrameF32U8", TYPE_CODES.CFrameF32U8
	elseif TYPE_CODES.CFrameF24U8 then
		return "CFrameF24U8", TYPE_CODES.CFrameF24U8
	end

	warn("[NetRay StructOpt] Could not find any suitable CFrame handler (F24U8/F32U8/F32U16).")
	return nil, nil
end

local function getBestVector3Type(stats: {minX:number,maxX:number,minY:number,maxY:number,minZ:number,maxZ:number, hasFloat:boolean}): (TypeName?, TypeCode?)
	if stats.hasFloat then
		-- Floating point needed
		local maxMagSq = math.max(stats.minX*stats.minX, stats.maxX*stats.maxX, stats.minY*stats.minY, stats.maxY*stats.maxY, stats.minZ*stats.minZ, stats.maxZ*stats.maxZ)
		-- Simplified check: If components reasonably small, maybe F24? Else F32. S16 check already failed.
		if maxMagSq <= (262144*262144) and TYPE_CODES.Vector3F24 then return "Vector3F24", TYPE_CODES.Vector3F24 end
		if TYPE_CODES.Vector3F32 then return "Vector3F32", TYPE_CODES.Vector3F32 end
	else
		-- All integer components
		if stats.minX >= -32768 and stats.maxX <= 32767 and
			stats.minY >= -32768 and stats.maxY <= 32767 and
			stats.minZ >= -32768 and stats.maxZ <= 32767 and TYPE_CODES.Vector3S16 then
			return "Vector3S16", TYPE_CODES.Vector3S16
		end
		-- If S16 fails, fallback to a float type (F32 is safest default)
		if TYPE_CODES.Vector3F32 then return "Vector3F32", TYPE_CODES.Vector3F32 end
	end
	warn("[NetRay StructOpt] Could not find suitable Vector3 handler.")
	return nil, nil
end

-- Writes a binary string payload (from LZ4_Lib) using the Binary handler
writeBinaryPayloadInternal = function(cursor: Cursor, payload: string)
	local name = "Binary"
	local code = TYPE_CODES[name]
	local writer = TypesModule.Writes[name]
	assert(code and writer, "Binary type handler is missing")
	cursor:WriteU1(code)
	writer(cursor, payload)
end

--==============================================================================
-- Metadata Analysis (Optimized to Single Pass + Finalization)
--==============================================================================

--[[
	Checks if the given 'data' looks like a valid array of uniform structures (structs)
	that can potentially be optimized for network transmission.

	It performs several passes:
	1. Initial validation (type, depth, size).
	2. Analyzes the first element to determine the expected structure (keys and base types)
	   and initializes statistics (min/max for numbers/vectors, etc.).
	3. Verifies that all subsequent elements match the structure of the first element
	   (same keys, same base types) and updates the collected statistics.
	4. Based on the collected statistics (e.g., min/max range, presence of floats),
	   determines the most optimal, compact data type for each field (e.g., Int8 vs Float64).
	5. Builds and returns an array of `StructFieldInfo` objects describing the optimized
	   structure, or nil if the data is not a candidate.

	Args:
		data (any): The data to analyze. Expected to be an array of tables.
		depth (number): The current recursion depth (used to prevent overly nested structures).
		config (typeof(NetRay.Config)): Configuration object containing limits like
		                                 StructArrayMaxDepth and StructArrayMaxSize.

	Returns:
		({ StructFieldInfo }?, number): An array of field information if it's a valid candidate,
		                                otherwise nil. Also returns the maximum depth reached during analysis.
]]
isStructArrayCandidate = function(data: any, depth: number, config: typeof(DynamicSender.Config))
	: ({ StructFieldInfo }?, number) -- Return type annotation

	-- =========================================================================
	-- Pass 0: Initial Checks & Validation
	-- =========================================================================

	-- Prevent excessive recursion or overly nested data structures
	if depth > config.StructArrayMaxDepth then
		return nil, depth -- Exceeded maximum nesting depth for struct arrays
	end

	-- The top-level data must be a table (specifically, an array)
	if typeof(data) ~= "table" then
		return nil, depth -- Input data must be a table
	end

	-- Check array size constraints
	local count = #data
	if count == 0 or count > config.StructArrayMaxSize then
		-- Array must have at least one element to determine structure,
		-- and must not exceed the configured maximum size.
		return nil, depth
	end

	-- Get the first element to analyze its structure
	local firstElement = data[1]
	if typeof(firstElement) ~= "table" then
		-- The elements themselves must be tables (structs)
		return nil, depth
	end

	-- =========================================================================
	-- Data Structures for Analysis
	-- =========================================================================

	-- Stores initial information derived from the first element's fields
	-- Used to ensure subsequent elements have the same keys and base types.
	local initialFieldInfo: { [string]: {
		Name: string,             -- The key of the field
		InitialTypeName: TypeName, -- The initial guess for the type (e.g., "Number", "Vector3")
		InitialTypeCode: TypeCode?, -- The type code if it's a simple, fixed type initially
		BaseType: string          -- The fundamental Lua type (typeof(value))
	} } = {}

	-- Stores detailed statistics collected across all elements for each field.
	-- Used in Pass 3 to determine the optimal final data type.
	local fieldAnalysis: { [string]: {
		-- Stats for 'number' type optimization
		numMin: number?, numMax: number?, numHasNonInt: boolean?, -- Tracks if any number value was not an integer

		-- Stats for 'Vector3' type optimization
		v3MinX: number?, v3MaxX: number?,
		v3MinY: number?, v3MaxY: number?,
		v3MinZ: number?, v3MaxZ: number?,
		v3HasFloat: boolean?, -- Tracks if any Vector3 component was not an integer

		-- Stats for 'Vector2' type optimization
		v2MinX: number?, v2MaxX: number?,
		v2MinY: number?, v2MaxY: number?,
		v2HasFloat: boolean?, -- Tracks if any Vector2 component was not an integer

		-- Stats for 'CFrame' position optimization (Rotation is often handled separately or ignored for simple cases)
		cfPosMinX: number?, cfPosMaxX: number?,
		cfPosMinY: number?, cfPosMaxY: number?,
		cfPosMinZ: number?, cfPosMaxZ: number?,
		-- Note: No CFrame rotation stats collected in this simplified version (as noted in original)
	} } = {}

	-- Maintains the order of keys as found in the first element.
	-- Used later to iterate fields consistently, although the final result is sorted.
	local keyOrder: { string } = {}

	-- Tracks the maximum depth reached during analysis (relevant if nested tables were allowed,
	-- though currently they cause the analysis to fail for the struct array itself).
	local maxD = depth

	-- =========================================================================
	-- Pass 1: Analyze First Element & Initialize Stats
	-- Iterate through the first element to establish the expected structure and baseline stats.
	-- =========================================================================
	for key, value in pairs(firstElement) do
		-- Ensure keys are strings
		if typeof(key) ~= "string" then
			return nil, maxD -- Struct keys must be strings
		end

		-- Assuming struct fields cannot be nil. Handling nils would require specific logic.
		if value == nil then
			-- If nil is meant to be a supported field type, handle it explicitly here.
			-- Otherwise, this rejection is likely correct for simple struct arrays.
			return nil, maxD -- Fields cannot be nil in this implementation
		end

		local baseType = typeof(value)
		local initialTypeName: TypeName? = nil
		local initialTypeCode: TypeCode? = nil
		local supported = false -- Is this type supported *by this struct array system*?
		local analysisData = {} -- Initialize empty stats for this field by default

		-- Check for supported base types and initialize stats accordingly
		if baseType == "number" then
			initialTypeName = "Number" -- Generic starting point, will be refined later in Pass 3
			supported = true
			local n = value :: number
			analysisData = {
				numMin = n,
				numMax = n,
				numHasNonInt = not isInteger(n)
			}
		elseif baseType == "string" then -- Covers Luau 'string' type (used for Characters, Binary, String)
			-- Assuming strings are supported and have a basic type code.
			-- Add length check from config if needed: e.g., and #value <= config.MaxStringLength
			if TYPE_CODES and TYPE_CODES.String then
				initialTypeName, initialTypeCode = "String", TYPE_CODES.String
				supported = true
				-- No specific range/content stats needed for basic strings here
			else
				supported = false -- String type code not defined or strings not supported
			end
		elseif baseType == "boolean" then
			-- Assuming a specific boolean type code exists (like Boolean8 for 1 byte)
			if TYPE_CODES and TYPE_CODES.Boolean8 then
				initialTypeName, initialTypeCode = "Boolean8", TYPE_CODES.Boolean8
				supported = true
				-- No specific stats needed
			else
				supported = false -- Boolean type code not defined
			end
		elseif baseType == "Vector3" then
			initialTypeName = "Vector3" -- Generic starting point, refined in Pass 3
			supported = true
			local v = value :: Vector3
			analysisData = {
				v3MinX = v.X, v3MaxX = v.X,
				v3MinY = v.Y, v3MaxY = v.Y,
				v3MinZ = v.Z, v3MaxZ = v.Z,
				v3HasFloat = not (isInteger(v.X) and isInteger(v.Y) and isInteger(v.Z))
			}
		elseif baseType == "Vector2" then
			initialTypeName = "Vector2" -- Generic starting point, refined in Pass 3
			supported = true
			local v = value :: Vector2
			analysisData = {
				v2MinX = v.X, v2MaxX = v.X,
				v2MinY = v.Y, v2MaxY = v.Y,
				v2HasFloat = not (isInteger(v.X) and isInteger(v.Y))
			}
		elseif baseType == "CFrame" then
			initialTypeName = "CFrame" -- Generic starting point, refined in Pass 3
			supported = true
			local cf = value :: CFrame
			local p = cf.Position -- Luau knows this is Vector3
			analysisData = {
				-- Only tracking position stats for optimization decisions in this version
				cfPosMinX = p.X, cfPosMaxX = p.X,
				cfPosMinY = p.Y, cfPosMaxY = p.Y,
				cfPosMinZ = p.Z, cfPosMaxZ = p.Z,
				-- TODO: Could add flags/stats for rotation if needed for CFrame subtypes
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

			-- Types generally considered UNSUITABLE for this simple struct array optimization:
		elseif baseType == "Instance" then
			-- Instances require specific network handling (replication/referencing)
			supported = false
		elseif baseType == "buffer" then
			-- Buffers are mutable and might be large; usually handled separately.
			supported = false
		elseif baseType == "NumberRange" then
			-- Complex type, usually not part of simple struct optimization.
			supported = false
		elseif baseType == "NumberSequence" then
			-- Variable length sequence, not a fixed struct field.
			supported = false
		elseif baseType == "ColorSequence" then
			-- Variable length sequence, not a fixed struct field.
			supported = false
		elseif baseType == "Region3" then
			-- Complex type, usually not part of simple struct optimization.
			supported = false
			-- Note: 'Any', 'Static', 'Nil' are conceptual or handled elsewhere (nil check above).

			-- Nested tables disqualify the parent from being a *simple* struct array.
		elseif baseType == "table" then
			-- Check depth first
			if depth + 1 > config.StructArrayMaxDepth then
				return nil, depth + 1 -- Nested table exceeds max depth allowed
			end
			-- Mark as unsupported *for this struct array analysis*, update max depth.
			supported = false
			maxD = math.max(maxD, depth + 1)
			-- The `if not supported then return nil...` below will handle this case.
		else
			-- Any other baseType encountered is currently unsupported by this system.
			supported = false
		end

		-- If the type of this field is not supported for struct arrays (based on the logic above),
		-- then the whole data structure isn't a candidate for this optimization.
		if not supported then
			return nil, maxD
		end

		-- Store the information for this valid field found in the first element
		table.insert(keyOrder, key)
		initialFieldInfo[key] = {
			Name = key,
			InitialTypeName = initialTypeName :: TypeName, -- Type assertion ok because supported=true checked above
			InitialTypeCode = initialTypeCode,
			BaseType = baseType
		}
		fieldAnalysis[key] = analysisData -- Store initialized stats for this field (might be {})
	end

	-- If the first element had no valid/supported fields (e.g., it was empty,
	-- or only contained unsupported types like Instances or nested tables),
	-- it's not a valid struct array candidate.
	if #keyOrder == 0 then
		return nil, maxD
	end

	-- =========================================================================
	-- Pass 2: Verify elements 2 through N & Update detailed stats
	-- Ensure all other elements match the structure derived from the first element
	-- and update the min/max/float statistics.
	-- =========================================================================
	local expectedKeyCount = #keyOrder
	for i = 2, count do
		local element = data[i]

		-- Basic check: ensure the element is a table
		if typeof(element) ~= "table" then
			return nil, maxD -- All elements must be tables
		end

		local elementKeyCount = 0
		for key, value in pairs(element) do
			elementKeyCount += 1

			-- Check 1: Does this key exist in the first element's structure?
			local baseInfo = initialFieldInfo[key]
			if not baseInfo then
				-- Element has a key that was not present in the first element. Structure mismatch.
				return nil, maxD
			end

			-- Check 2: Is the value nil? (Still assuming non-nil fields)
			if value == nil then
				-- TODO: Revisit nil handling if necessary
				return nil, maxD -- Fields cannot be nil
			end

			-- Check 3: Does the base type match the first element's field type?
			local valueType = typeof(value)
			if valueType ~= baseInfo.BaseType then
				-- e.g., field 'x' was a number in element 1 but a string in element 'i'. Structure mismatch.
				return nil, maxD
			end

			-- Retrieve analysis data structure for this field to update stats
			local analysis = fieldAnalysis[key]
			if not analysis then
				-- This should technically be impossible if Pass 1 populated correctly for this key
				error("Internal Error: Field analysis data missing for key: " .. key)
			end

			-- Update detailed statistics based on the field's BaseType
			if baseInfo.BaseType == "number" then
				local numVal = value :: number
				-- Update min/max values seen so far
				analysis.numMin = math.min(analysis.numMin or numVal, numVal)
				analysis.numMax = math.max(analysis.numMax or numVal, numVal)
				-- Update flag if we encounter a non-integer value
				if not analysis.numHasNonInt and not isInteger(numVal) then
					analysis.numHasNonInt = true
				end
			elseif baseInfo.BaseType == "Vector3" then
				local v = value :: Vector3
				-- Update min/max for each component
				analysis.v3MinX = math.min(analysis.v3MinX or v.X, v.X)
				analysis.v3MaxX = math.max(analysis.v3MaxX or v.X, v.X)
				analysis.v3MinY = math.min(analysis.v3MinY or v.Y, v.Y)
				analysis.v3MaxY = math.max(analysis.v3MaxY or v.Y, v.Y)
				analysis.v3MinZ = math.min(analysis.v3MinZ or v.Z, v.Z)
				analysis.v3MaxZ = math.max(analysis.v3MaxZ or v.Z, v.Z)
				-- Update float flag if any component is not an integer
				if not analysis.v3HasFloat and not (isInteger(v.X) and isInteger(v.Y) and isInteger(v.Z)) then
					analysis.v3HasFloat = true
				end
			elseif baseInfo.BaseType == "Vector2" then
				local v = value :: Vector2
				-- Update min/max for each component
				analysis.v2MinX = math.min(analysis.v2MinX or v.X, v.X)
				analysis.v2MaxX = math.max(analysis.v2MaxX or v.X, v.X)
				analysis.v2MinY = math.min(analysis.v2MinY or v.Y, v.Y)
				analysis.v2MaxY = math.max(analysis.v2MaxY or v.Y, v.Y)
				-- Update float flag if any component is not an integer
				if not analysis.v2HasFloat and not (isInteger(v.X) and isInteger(v.Y)) then
					analysis.v2HasFloat = true
				end
			elseif baseInfo.BaseType == "CFrame" then
				local cf = value :: CFrame -- Still only tracking position stats
				local p = cf.Position :: Vector3
				-- Update min/max for each position component
				analysis.cfPosMinX = math.min(analysis.cfPosMinX or p.X, p.X)
				analysis.cfPosMaxX = math.max(analysis.cfPosMaxX or p.X, p.X)
				analysis.cfPosMinY = math.min(analysis.cfPosMinY or p.Y, p.Y)
				analysis.cfPosMaxY = math.max(analysis.cfPosMaxY or p.Y, p.Y)
				analysis.cfPosMinZ = math.min(analysis.cfPosMinZ or p.Z, p.Z)
				analysis.cfPosMaxZ = math.max(analysis.cfPosMaxZ or p.Z, p.Z)
				-- elseif baseInfo.BaseType == "string" then -- No stats to update
				-- elseif baseInfo.BaseType == "boolean" then -- No stats to update
				-- elseif baseInfo.BaseType == "Color3" then -- No stats to update (usually fixed size)
				-- ... etc for other simple types that don't require range analysis
			end
		end -- End inner loop (pairs over element's keys)

		-- Check 4: Does this element have the exact same number of keys as the first element?
		-- This catches cases where an element is missing a key found in the first element.
		if elementKeyCount ~= expectedKeyCount then
			return nil, maxD -- Key count mismatch. Structure mismatch.
		end
	end -- End outer loop (elements 2 to count)

	-- =========================================================================
	-- Pass 3: Finalize optimal types and build final struct info array
	-- Use the collected statistics to choose the best (most compact) type for each field.
	-- =========================================================================
	local finalStructInfo: { StructFieldInfo } = {} -- Initialize the result array

	-- Iterate through the keys in the order they were found (though final result is sorted)
	for _, key in ipairs(keyOrder) do
		local baseInfo = initialFieldInfo[key]
		local analysis = fieldAnalysis[key]

		-- Start with the initial type identified in Pass 1
		local finalTypeName: TypeName = baseInfo.InitialTypeName
		local finalTypeCode: TypeCode? = baseInfo.InitialTypeCode
		local readerFunc -- To be looked up based on finalTypeName
		local writerFunc -- To be looked up based on finalTypeName

		-- Refine the type based on collected statistics for optimizable types
		-- Calls helper functions (assumed to exist) that analyze the stats
		-- and return the best TypeName and TypeCode (e.g., "Int8", "Float32", "V3Int16").

		if baseInfo.BaseType == "number" then
			-- Check if analysis data is valid (should always be if logic is correct)
			if not analysis or analysis.numMin == nil or analysis.numMax == nil then
				error(string.format("Internal Error: Finalizing number field '%s', but analysis data is incomplete.", key))
			end
			-- Find the most compact number type that fits the min/max range and integer status
			local bestName, bestCode = getBestNumberType(analysis.numMin, analysis.numMax, analysis.numHasNonInt == true)
			if not bestName then
				-- The helper function determined no suitable compact type could represent the range/type.
				return nil, maxD -- Cannot find a suitable compact number type
			end
			finalTypeName, finalTypeCode = bestName, bestCode

		elseif baseInfo.BaseType == "Vector3" then
			if not analysis or analysis.v3MinX == nil then -- Check one representative stat
				error(string.format("Internal Error: Finalizing Vector3 field '%s', but analysis data is incomplete.", key))
			end
			-- Find the most compact Vector3 representation (e.g., V3Int16, V3Float32) based on component ranges/types
			local bestName, bestCode = getBestVector3Type(analysis :: any) -- Pass the whole analysis struct
			if not bestName then
				return nil, maxD -- Cannot find a suitable compact Vector3 type
			end
			finalTypeName, finalTypeCode = bestName, bestCode

		elseif baseInfo.BaseType == "Vector2" then
			if not analysis or analysis.v2MinX == nil then -- Check one representative stat
				error(string.format("Internal Error: Finalizing Vector2 field '%s', but analysis data is incomplete.", key))
			end
			-- Find the most compact Vector2 representation
			local bestName, bestCode = getBestVector2Type(analysis :: any) -- Pass the whole analysis struct
			if not bestName then
				return nil, maxD -- Cannot find a suitable compact Vector2 type
			end
			finalTypeName, finalTypeCode = bestName, bestCode

		elseif baseInfo.BaseType == "CFrame" then
			if not analysis or analysis.cfPosMinX == nil then -- Check one representative stat
				error(string.format("Internal Error: Finalizing CFrame field '%s', but analysis data is incomplete.", key))
			end
			-- Find the most compact CFrame representation (e.g., CFPosOnly, CFSmall) based on position stats (and possibly other factors not tracked here)
			local bestName, bestCode = getBestCFrameType(analysis :: any) -- Pass the whole analysis struct
			if not bestName then
				return nil, maxD -- Cannot find a suitable compact CFrame type
			end
			finalTypeName, finalTypeCode = bestName, bestCode

			-- Other types (String, Boolean, Color3, BrickColor, etc.) usually don't have
			-- further optimization based on content/range in this context.
			-- Their initial TypeName/TypeCode determined in Pass 1 is typically the final one.
			-- Add `elseif` blocks here ONLY if specific analysis/optimization is needed for them.
		end

		-- Fetch the corresponding serialization/deserialization functions for the *finalized* type
		-- Assuming a 'TypesModule' exists with lookup tables 'Reads' and 'Writes'.
		readerFunc = TypesModule.Reads[finalTypeName]
		writerFunc = TypesModule.Writes[finalTypeName]

		-- Validate that handlers and the final type code exist. This is a crucial sanity check.
		if not readerFunc or not writerFunc then
			error(string.format("Struct Array: Read/Write handler missing for finalized type '%s' (Key: %s)", finalTypeName, key))
		end
		if finalTypeCode == nil then
			-- This should ideally be caught by the getBest...Type functions returning nil type names if no code exists,
			-- but double-check here for safety, especially for types not explicitly optimized above.
			error(string.format("Struct Array: Final TypeCode is missing for finalized type '%s' (Key: %s)", finalTypeName, key))
		end

		-- Add the finalized field information to the result array
		table.insert(finalStructInfo, {
			Name = key,                       -- Name of the field
			TypeName = finalTypeName,         -- The chosen optimal type name
			TypeCode = finalTypeCode :: TypeCode, -- The corresponding type code (assert non-nil based on checks)
			ReadFunc = readerFunc,            -- Function to read this field type from a buffer
			WriteFunc = writerFunc            -- Function to write this field type to a buffer
		})
	end -- End loop through keyOrder

	-- =========================================================================
	-- Final Step: Sort and Return
	-- =========================================================================

	-- Sort the final field info alphabetically by field name.
	-- This ensures a deterministic order for serialization, regardless of
	-- the order keys might appear in `pairs` iterations.
	table.sort(finalStructInfo, function(a, b)
		return a.Name < b.Name
	end)

	-- Success! Return the array of StructFieldInfo and the maximum depth reached.
	return finalStructInfo, maxD

end -- End of isStructArrayCandidate function

-- Analyzes data to provide metadata for strategy selection
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

--==============================================================================
-- Struct Array Serialization (Optimized: No Field Codes Written/Read)
--==============================================================================
writeStructArrayInternal = function(cursor: Cursor, data: { { [string]: any } }, structInfo: { StructFieldInfo })
	local count = #data; if count > 65535 then error("Struct count > 65k") end; cursor:WriteU2(count); -- Element Count
	local fieldCount = #structInfo; if fieldCount > 255 then error("Struct fields > 255") end; cursor:WriteU1(fieldCount); -- Field Count
	local nameTypeCode, nameWriteFunc = TYPE_CODES.String, TypesModule.Writes.String; assert(nameTypeCode and nameWriteFunc, "REQ: String Writer");
	-- Write structure definition (Name + OPTIMIZED TypeCode)
	for _, field in ipairs(structInfo) do
		cursor:WriteU1(nameTypeCode); nameWriteFunc(cursor, field.Name); -- Field Name
		cursor:WriteU1(field.TypeCode) -- Field *optimized* type from analysis
	end
	-- Write element data sequentially without per-field type codes
	for i = 1, count do local element = data[i]; if typeof(element) ~= "table" then error("Bad struct data") end;
		for _, field in ipairs(structInfo) do -- Write fields in definition's sorted order
			local value = element[field.Name];
			-- Runtime assertion that value isn't nil (should be caught by analysis, but good safety)
			assert(value ~= nil, "INTERNAL ERROR: Nil value found writing optimized struct array for field " .. field.Name);
			assert(field.WriteFunc, "Missing WriteFunc: "..field.TypeName);
			field.WriteFunc(cursor, value) -- Directly call the optimized writer for this field type
		end
	end
end


readStructArrayInternal = function(cursor: Cursor): { { [string]: any } }
	local count = cursor:ReadU2(); local fieldCount = cursor:ReadU1();
	local structInfo = table.create(fieldCount); -- Store received structure info in order
	local nameTypeCodeExpected, nameReadFunc = TYPE_CODES.String, TypesModule.Reads.String; assert(nameTypeCodeExpected and nameReadFunc, "REQ: String Reader");
	-- Read structure definition
	for i = 1, fieldCount do
		local readNameCode = cursor:ReadU1(); if readNameCode ~= nameTypeCodeExpected then error("Bad name TC") end;
		local fieldName = nameReadFunc(cursor);
		local fieldTypeCode = cursor:ReadU1(); -- Read the OPTIMIZED TypeCode sent by sender
		local fieldTypeName = BYTE_TO_TYPE_NAME[fieldTypeCode]; if not fieldTypeName then error("Bad field TC "..fieldTypeCode) end;
		local readerFunc = TypesModule.Reads[fieldTypeName]; assert(readerFunc, "Missing Reader:"..fieldTypeName);
		-- Store name, resolved type info, and the mandatory reader function
		structInfo[i] = { Name = fieldName, TypeName = fieldTypeName, TypeCode = fieldTypeCode, ReadFunc = readerFunc } -- No need to store WriteFunc on read side
	end

	-- Read element data (rely entirely on read structure definition)
	local resultArray = table.create(count);
	for i = 1, count do local element = {};
		for _, field in ipairs(structInfo) do -- Read fields in the exact defined order
			-- *** REMOVED Per-Field Type Code READ ***
			assert(field.ReadFunc, "Missing ReadFunc: "..field.TypeName); -- Assert reader exists
			local value = field.ReadFunc(cursor) -- Directly read value using handler from definition
			element[field.Name] = value
		end;
		resultArray[i] = element
	end;
	return resultArray
end

-- Helper Function: Serialize a single message payload for IMMEDIATE sends
_serializeSingleMessage = function(strategy: number, payload: any, structInfo: { StructFieldInfo }?): (buffer?, {Instance}?)
	local success, result_or_err, instances_or_nil
	success, result_or_err, instances_or_nil = pcall(function()
		local tempBuffer = buffer.create(1024)
		local instances: {Instance} = {}
		local cursor = CursorModule(tempBuffer, instances)

		cursor:WriteU1(strategy)
		-- Target info is NOT written here; handled by FireClient/FireAllClients directly

		if strategy == STRATEGY_LZ4 then
			writeBinaryPayloadInternal(cursor, payload::string)
		elseif strategy == STRATEGY_STRUCT_ARRAY then
			assert(structInfo, "SingleMsg sInfo nil")
			writeStructArrayInternal(cursor, payload::{any}, structInfo)
		else
			error("Bad Send Strat:"..strategy, 0)
		end
		return cursor:Truncate(), instances
	end)

	if success then
		return result_or_err :: buffer?, instances_or_nil :: {Instance}?
	else
		warn(`[DynamicSender ERR] Failed to serialize single message: ${result_or_err}`)
		metrics.errors+=1 -- Increment error count on serialization failure
		return nil, nil
	end
end

--==============================================================================
-- Batching Logic (Refactored for Per-Player/All Cursors)
--==============================================================================

-- Gets or creates the appropriate cursor for batching.
-- If target is nil, uses the shared 'AllCursor'.
-- If target is a Player, uses/creates a cursor specific to that player.
getOrCreateBatchCursor = function(remote: AnyRemoteEvent, target: Player?): Cursor
	local remoteState = batchState[remote]
	if not remoteState then
		if DynamicSender.Config.DebugMode then print(`[DynamicSender DBG] Create batch state for ${remote.Name}`) end
		remoteState = { PerPlayerCursors = {} } -- Initialize with empty PerPlayerCursors map
		batchState[remote] = remoteState
	end

	local cursor: Cursor
	if target == nil then
		-- Use/Create the AllCursor for FireAllClients type batches
		if not remoteState.AllCursor then
			if DynamicSender.Config.DebugMode then print(`[DynamicSender DBG] Create AllCursor for ${remote.Name}`) end
			remoteState.AllCursor = CursorModule(buffer.create(1024), {})
		end
		cursor = remoteState.AllCursor
	else
		-- Use/Create a specific cursor for this player
		if not remoteState.PerPlayerCursors[target] then
			if DynamicSender.Config.DebugMode then print(`[DynamicSender DBG] Create PerPlayerCursor for ${target.Name} on ${remote.Name}`) end
			remoteState.PerPlayerCursors[target] = CursorModule(buffer.create(1024), {})
		end
		cursor = remoteState.PerPlayerCursors[target]
	end

	return cursor
end

-- Main batch processing function (Refactored)
processFrameBatches = function(triggeredRemote: AnyRemoteEvent?)
	local remotesToActuallyProcess: {[AnyRemoteEvent]: boolean} = {}
	-- If called by a trigger, add that specific remote
	if triggeredRemote and batchState[triggeredRemote] then
		remotesToActuallyProcess[triggeredRemote] = true
		if activeRemotes[triggeredRemote] then activeRemotes[triggeredRemote] = nil end
		if DynamicSender.Config.DebugMode then print(`[DynamicSender DBG] processFrameBatches triggered directly for ${triggeredRemote.Name}`) end
	end

	-- Also process any remotes added normally via Heartbeat cycle
	if next(activeRemotes) then
		if DynamicSender.Config.DebugMode then print(`[DynamicSender DBG] processFrameBatches processing activeRemotes`) end
		for remote, _ in pairs(activeRemotes) do
			if batchState[remote] then
				remotesToActuallyProcess[remote] = true
			end
		end
		activeRemotes = {} -- Clear the global active list
	end

	-- Early exit if there's nothing to process
	if not next(remotesToActuallyProcess) then
		if DynamicSender.Config.DebugMode and not triggeredRemote then print("[DynamicSender DBG] processFrameBatches - No active remotes with state, exiting.") end
		return
	end

	if DynamicSender.Config.DebugMode then
		local count = 0; for _ in pairs(remotesToActuallyProcess) do count+=1 end
		print(`[DynamicSender DBG] processFrameBatches - Processing ${count} remote(s)`)
	end

	local playersToRemoveFromRemote: {[AnyRemoteEvent]: {Player}} = {} -- Track disconnected players for cleanup

	for remote, _ in pairs(remotesToActuallyProcess) do
		-- ▼▼▼ FIX: Corrected the logical check for the remote type ▼▼▼
		if not remote or not (remote:IsA("RemoteEvent") or remote:IsA("UnreliableRemoteEvent")) then
			warn("[DynamicSender WARN] Invalid remote key found in processing list. Skipping.")
			continue
		end

		local remoteState = batchState[remote]
		if not remoteState then
			if DynamicSender.Config.DebugMode then print(`[DynamicSender DBG] Skipping ${remote.Name} - No state found during processing loop.`) end
			continue
		end

		-- === Network Sending Logic ===
		if isServer then
			-- 1. Process Per-Player Batches
			if remoteState.PerPlayerCursors then
				for player, cursor in pairs(remoteState.PerPlayerCursors) do
					local bufferLen = cursor.Index
					if bufferLen > 0 then
						if player and player.Parent then -- Check if player is valid and connected
							local finalBuffer = cursor:Truncate()
							local finalInstances = cursor.Instances
							if DynamicSender.Config.DebugMode then print(`[DynamicSender DBG] Sending specific batch to ${player.Name} on ${remote.Name}. Size: ${bufferLen}, Instances: {#finalInstances}`) end

							-- Fire without pcall
							remote:FireClient(player, finalBuffer, finalInstances)

							cursor:Clear()
						else -- Player disconnected or invalid
							if DynamicSender.Config.DebugMode then print(`[DynamicSender DBG] Player ${player and player.Name or "INVALID"} disconnected or invalid. Clearing buffer for ${remote.Name}.`) end
							cursor:Clear()
							if player then -- Only mark valid player objects for removal
								if not playersToRemoveFromRemote[remote] then playersToRemoveFromRemote[remote] = {} end
								table.insert(playersToRemoveFromRemote[remote], player)
							end
						end
					elseif not player or not player.Parent then -- Empty buffer AND disconnected
						if DynamicSender.Config.DebugMode then print(`[DynamicSender DBG] Player ${player and player.Name or "INVALID"} disconnected or invalid with empty buffer. Marking for removal on ${remote.Name}.`) end
						if player then
							if not playersToRemoveFromRemote[remote] then playersToRemoveFromRemote[remote] = {} end
							table.insert(playersToRemoveFromRemote[remote], player)
						end
					end
				end
			end

			-- 2. Process "All" Batch (FireAllClients)
			local allCursor = remoteState.AllCursor
			if allCursor and allCursor.Index > 0 then
				local finalBuffer = allCursor:Truncate()
				local finalInstances = allCursor.Instances
				local bufferLen = buffer.len(finalBuffer)
				if DynamicSender.Config.DebugMode then print(`[DynamicSender DBG] Sending 'all' batch on ${remote.Name}. Size: ${bufferLen}, Instances: {#finalInstances}`) end

				-- Fire
				remote:FireAllClients(finalBuffer, finalInstances)

				allCursor:Clear()
			end

		elseif isClient then -- Client Sending Logic (FireServer)
			local allCursor = remoteState.AllCursor -- Clients typically use the 'all' cursor concept for FireServer
			if allCursor and allCursor.Index > 0 then
				local finalBuffer = allCursor:Truncate()
				local finalInstances = allCursor.Instances
				local bufferLen = buffer.len(finalBuffer)
				if DynamicSender.Config.DebugMode then print(`[DynamicSender DBG] Firing Server on ${remote.Name}. Size: ${bufferLen}, Instances: {#finalInstances}`) end

				-- Fire without pcall
				remote:FireServer(finalBuffer, finalInstances)

				allCursor:Clear()
			end
		end
		-- ============================
	end -- End loop through remotesToActuallyProcess

	-- Cleanup disconnected player cursors *after* iterating
	if isServer then
		for remote, players in pairs(playersToRemoveFromRemote) do
			local remoteState = batchState[remote]
			if remoteState and remoteState.PerPlayerCursors then
				for _, player in ipairs(players) do
					if remoteState.PerPlayerCursors[player] then
						if DynamicSender.Config.DebugMode then print(`[DynamicSender DBG] Removing disconnected player cursor state for ${player.Name} on ${remote.Name}`) end
						remoteState.PerPlayerCursors[player] = nil
					end
				end
			end
		end
	end
end

--==============================================================================
-- Public API
--==============================================================================

function DynamicSender:Send(remote: AnyRemoteEvent, data: any, target: Player?, options)
	if not remote then warn("[DynamicSender ERR] RemoteEvent is nil.") return end
	if isClient and target then warn("[DynamicSender WARN] Target parameter ignored from client.") target = nil end
	if isServer and target and not target:IsA("Player") then warn("[DynamicSender ERR] Target must be Player instance or nil.") return end
	options = options or {}
	local batchable = options.batchable or false -- Default to false if nil or not specified

	-- == Direct Send Logic ==
	if not batchable then
		if DynamicSender.Config.DebugMode then print(`[DynamicSender DBG] Send Immediate ${remote.Name} Tgt:${target and target.Name or "all"}`) end
		metrics.serializeCount += 1
		local startTime = os.clock()
		-- 1. Analyze & Select Strategy
		local meta = analyzeMetadata(data)
		local strategy: number
		local payload: any
		local structInfo: { StructFieldInfo }? = nil
		if meta.isStructArrayCandidate and meta.structInfo then
			strategy = STRATEGY_STRUCT_ARRAY; payload = data; structInfo = meta.structInfo; metrics.structArrayPayloads += 1
		else
			strategy = STRATEGY_LZ4
			local lz4Ok, lz4Payload = pcall(LZ4_Lib.Compress, LZ4_Lib, data)
			if not lz4Ok or typeof(lz4Payload) ~= "string" then warn(`[DynamicSender ERR] Send Immediate LZ4 Fail: ${lz4Payload}. Msg Cancelled.`); metrics.errors+=1; return end
			payload = lz4Payload :: string; metrics.lz4Payloads += 1
		end
		-- 2. Serialize the single message payload
		local messageBuffer, messageInstances = _serializeSingleMessage(strategy, payload, structInfo)
		metrics.totalSerializeTime += (os.clock() - startTime)
		-- 3. Fire Immediately if serialization succeeded
		if messageBuffer then
			-- Fire without pcall
			if isServer then
				if target then
					remote:FireClient(target, messageBuffer, messageInstances)
				else
					remote:FireAllClients(messageBuffer, messageInstances)
				end
			else -- isClient
				remote:FireServer(messageBuffer, messageInstances)
			end
		else
			-- Serialization failed, error already warned by _serializeSingleMessage
			-- metrics.errors was already incremented by _serializeSingleMessage
		end
		return -- Exit function, batching bypassed
	end
	-- == End Direct Send Logic ==

	-- == Batched Send Logic ==
	local cursor = getOrCreateBatchCursor(remote, target) -- Get the correct cursor (per-player or 'all')
	local meta = analyzeMetadata(data);

	local strategy: number
	local payload: any
	local structInfo: { StructFieldInfo }? = nil

	-- Select Strategy
	if meta.isStructArrayCandidate and meta.structInfo then
		strategy = STRATEGY_STRUCT_ARRAY; payload = data; structInfo = meta.structInfo;
	else
		strategy = STRATEGY_LZ4
		local lz4Ok, lz4Payload = pcall(LZ4_Lib.Compress, LZ4_Lib, data)
		if not lz4Ok or typeof(lz4Payload) ~= "string" then warn(`[DynamicSender ERR] LZ4 Compress fail: ${lz4Payload}. Msg cancelled.`); metrics.errors+=1; return end
		payload = lz4Payload :: string;
	end

	-- Write message (Strategy + Payload) to the appropriate batch cursor
	local writeOk, writeErr = pcall(function()
		cursor:WriteU1(strategy)
		-- Target info is NOT written into the batch payload

		local startTime = os.clock()
		if strategy == STRATEGY_LZ4 then writeBinaryPayloadInternal(cursor, payload::string); metrics.lz4Payloads += 1;
		elseif strategy == STRATEGY_STRUCT_ARRAY then assert(structInfo, "Send Batch sInfo nil"); writeStructArrayInternal(cursor, payload::{any}, structInfo); metrics.structArrayPayloads += 1;
		else error("Bad Send Strat:"..strategy, 0) end
		local duration = os.clock() - startTime

		metrics.serializeCount += 1; metrics.totalSerializeTime += duration
		if DynamicSender.Config.DebugMode then print(`[DynamicSender DBG] Added msg to batch ${remote.Name}. Strat:${strategy} Tgt:${target and target.Name or "all"} Time:${string.format("%.5f", duration)}`) end;
	end)

	if not writeOk then warn(`[DynamicSender ERR] Write Message fail ${remote.Name}:${writeErr}`); metrics.errors+=1; return end

	if cursor.Index > 0 then -- Only mark active if buffer actually has data
		activeRemotes[remote] = true -- Ensure remote is processed by Heartbeat
	end

	-- Check Flush Trigger (based on the specific cursor written to)
	if DynamicSender.Config.MaxBatchSizeTrigger > 0 and cursor.Index > DynamicSender.Config.MaxBatchSizeTrigger then
		if DynamicSender.Config.DebugMode then print(`[DynamicSender DBG] Size ${cursor.Index}/${DynamicSender.Config.MaxBatchSizeTrigger} -> Flush Trigger for ${target and target.Name or "all"}`) end
		processFrameBatches(remote) -- Pass remote to potentially flush just this one
	end
end

function DynamicSender:SendToMany(remote: AnyRemoteEvent, data: any, targets: { Player }, options: SendOptions?)
	if not isServer then warn("[DynamicSender SndM ERR] Server only.") return end
	if not remote then warn("[DynamicSender SndM ERR] RE nil.") return end
	if not targets or #targets == 0 then warn("[DynamicSender SndM ERR] Targets empty.") return end
	options = options or {}
	local batchable = options.batchable or false -- Default to false

	-- == Direct Send Logic ==
	if not batchable then
		if DynamicSender.Config.DebugMode then print(`[DynamicSender DBG] SendToMany Immediate ${remote.Name} Tgts:{#targets}`) end
		local successCount = 0
		-- Analyze ONCE
		local meta = analyzeMetadata(data)
		local strategy: number; local payload: any; local structInfo: {StructFieldInfo}? = nil
		-- Select Strategy ONCE
		if meta.isStructArrayCandidate and meta.structInfo then strategy=STRATEGY_STRUCT_ARRAY; payload=data; structInfo=meta.structInfo;
		else
			strategy=STRATEGY_LZ4; local ok, lz = pcall(LZ4_Lib.Compress, LZ4_Lib, data)
			if not ok or typeof(lz)~="string" then warn(`SndM Imm LZ4 Fail:${lz}`); metrics.errors+=1; return end -- Fail all if compression fails
			payload=lz::string;
		end
		-- Serialize and Send to each target individually
		for _, playerTarget in ipairs(targets) do
			if playerTarget and playerTarget:IsA("Player") and playerTarget.Parent then
				metrics.serializeCount+=1
				local startTime = os.clock()
				local messageBuffer, messageInstances = _serializeSingleMessage(strategy, payload, structInfo)
				metrics.totalSerializeTime += (os.clock() - startTime)
				if messageBuffer then
					-- Fire without pcall
					remote:FireClient(playerTarget, messageBuffer, messageInstances)
					successCount+=1;
				else
					-- Serialization failed, metrics.errors already incremented
				end
			else warn(`[DynamicSender SndM Imm WARN] Invalid target: {tostring(playerTarget)}`) end
		end
		if DynamicSender.Config.DebugMode then print(`[DynamicSender SndM DBG] Immediate send done. Sent to ${successCount}/${#targets}.`) end
		return -- Exit function, batching bypassed
	end
	-- == End Direct Send Logic ==

	-- == Batched Send Logic ==
	local successfullyQueued = 0
	local meta = analyzeMetadata(data)
	local strategy: number; local payload: any; local structInfo: { StructFieldInfo }? = nil
	local precomputedLz4Payload: string? = nil

	if meta.isStructArrayCandidate and meta.structInfo then
		strategy = STRATEGY_STRUCT_ARRAY; payload = data; structInfo = meta.structInfo;
	else
		strategy = STRATEGY_LZ4
		local lz4Ok, lz4Comp = pcall(LZ4_Lib.Compress, LZ4_Lib, data)
		if not lz4Ok or typeof(lz4Comp) ~= "string" then
			warn(`[DynamicSender SndM ERR] Pre-loop LZ4 Compress fail: ${lz4Comp}. Cannot queue messages.`); metrics.errors+=1; return
		end
		precomputedLz4Payload = lz4Comp :: string
		payload = precomputedLz4Payload
	end

	-- Loop through targets and add to their specific batch buffer
	for _, playerTarget in ipairs(targets) do
		if playerTarget and playerTarget:IsA("Player") and playerTarget.Parent then
			local cursor = getOrCreateBatchCursor(remote, playerTarget) -- Get player's specific cursor

			local writeOk, writeErr = pcall(function()
				cursor:WriteU1(strategy) -- Strategy Marker
				-- Target info is NOT written

				local startTime = os.clock()
				if strategy == STRATEGY_LZ4 then writeBinaryPayloadInternal(cursor, payload::string); metrics.lz4Payloads += 1;
				elseif strategy == STRATEGY_STRUCT_ARRAY then assert(structInfo, "SndM Batch sInfo nil"); writeStructArrayInternal(cursor, payload::{any}, structInfo); metrics.structArrayPayloads += 1;
				else error("SndM Batch Bad strat:"..strategy, 0) end
				local duration = os.clock() - startTime

				metrics.serializeCount += 1; metrics.totalSerializeTime += duration
				if DynamicSender.Config.DebugMode then print(`[DynamicSender SndM DBG] Added msg to batch for ${playerTarget.Name} on ${remote.Name}. Strat:${strategy} Time:${string.format("%.5f", duration)}`) end;
				successfullyQueued += 1
			end)

			if not writeOk then warn(`[DynamicSender SndM ERR] Write fail for ${playerTarget.Name}:${writeErr}`); metrics.errors+=1; continue end

			if cursor.Index > 0 then
				activeRemotes[remote] = true
			end

			if DynamicSender.Config.MaxBatchSizeTrigger > 0 and cursor.Index > DynamicSender.Config.MaxBatchSizeTrigger then
				if DynamicSender.Config.DebugMode then print(`[DynamicSender SndM DBG] Flush Trigger during SendToMany for ${playerTarget.Name}`) end
				processFrameBatches(remote)
			end
		else
			warn(`[DynamicSender SendToMany WARN] Invalid or disconnected target: {tostring(playerTarget)}`)
		end
	end -- End of target loop

	if DynamicSender.Config.DebugMode then print(`[DynamicSender DBG] SendToMany Batch: Queued {successfullyQueued}/{#targets} msgs.`) end
end

function DynamicSender:DecodeReceivedData(rawDataBuffer: buffer, rawInstances: {Instance}?): {any}
	if typeof(rawDataBuffer) ~= "buffer" then
		if rawDataBuffer == nil then
			if DynamicSender.Config.DebugMode then print("[DynamicSender DBG] DecodeReceivedData received nil buffer (likely from nil direct send), returning empty table.") end
			return {}
		end
		warn("[DynamicSender ERR] Buffer expected for DecodeReceivedData"); metrics.decodeErrors+=1; return {}
	end
	if buffer.len(rawDataBuffer) == 0 then return {} end -- Empty buffer means no messages

	if rawInstances and typeof(rawInstances)~="table" then warn("[DynamicSender WARN] Decode instances not table"); rawInstances={} end
	-- print(rawInstances) -- Optional: uncomment for debugging instance mapping

	local decodedMessages = {}
	local startTime = os.clock()
	local cursor = CursorModule(rawDataBuffer, rawInstances or {})

	while cursor.Index < buffer.len(rawDataBuffer) do
		local messageStartIndex = cursor.Index;
		local success, messageDataOrError = pcall(function()
			local strategy = cursor:ReadU1(); if not strategy then error("Read strat fail @ " .. messageStartIndex, 0) end
			-- Target info is NOT read from the buffer anymore

			local finalData: any;
			if strategy == STRATEGY_LZ4 then
				local pTC=cursor:ReadU1(); if pTC ~= TYPE_CODES.Binary then error("Exp Bin TC @ " .. messageStartIndex, 0) end;
				local reader=TypesModule.Reads.Binary; if not reader then error("No Bin Reader @ " .. messageStartIndex, 0) end;
				local sPayload=reader(cursor); if typeof(sPayload)~="string" then error("Bin read !str @ " .. messageStartIndex, 0) end;
				-- Use pcall specifically for LZ4 Decompress as it can fail on bad data
				local lzOk, lzResult = pcall(LZ4_Lib.Decompress, LZ4_Lib, sPayload);
				if not lzOk then warn(`[DS ERR] LZ4 Dec:${lzResult}`); error("LZ4 Dec fail @ " .. messageStartIndex, 0) end;
				finalData=lzResult
			elseif strategy == STRATEGY_STRUCT_ARRAY then
				finalData = readStructArrayInternal(cursor) -- Assume this handles its own errors or asserts
			else error("Unknown strategy marker: "..strategy.." @ " .. messageStartIndex, 0) end
			return finalData
		end)

		if success then
			table.insert(decodedMessages, messageDataOrError); metrics.deserializeCount+=1
		else
			warn(`[DS ERR] Dec fail @${messageStartIndex}: ${tostring(messageDataOrError)}`); metrics.errors+=1; metrics.decodeErrors+=1;
			warn("[DS ERR] Stopping batch decode due to error.");
			break -- Stop processing this buffer if a message fails to decode
		end
	end
	metrics.totalDeserializeTime += (os.clock()-startTime);
	if DynamicSender.Config.DebugMode then print(`[DS DBG] Decode done. Msgs:{#decodedMessages}`) end;
	return decodedMessages
end

--==============================================================================
-- Utilities
--==============================================================================

function DynamicSender.GetMetrics(): DynamicSenderMetrics
	local copy: any = {} -- Start with 'any' for simplicity, will conform to type
	for k, v in pairs(metrics) do copy[k] = v end
	local avgS = 0; if metrics.serializeCount > 0 then avgS = metrics.totalSerializeTime / metrics.serializeCount end
	local avgD = 0; if metrics.deserializeCount > 0 then avgD = metrics.totalDeserializeTime / metrics.deserializeCount end
	copy.avgSerializeTime = avgS
	copy.avgDeserializeTime = avgD
	return copy :: DynamicSenderMetrics -- Cast to expected type
end

function DynamicSender.ResetMetrics()
	for k,_ in pairs(metrics) do metrics[k] = 0 end
	metrics.totalSerializeTime = 0; metrics.totalDeserializeTime = 0;
end

function DynamicSender:FlushBatches()
	if DynamicSender.Config.DebugMode then print("[DynamicSender] Manual flush triggered.") end
	processFrameBatches() -- Process all active remotes
end

--==============================================================================
-- Initialization
--==============================================================================

if not runServiceConnection then
	runServiceConnection = RunService.Heartbeat:Connect(function(dt)
		if next(activeRemotes) then -- Optimization: only call if remotes were marked active
			processFrameBatches()
		end
	end)
	if DynamicSender.Config.DebugMode then print("[DynamicSender] Batch processing connected to Heartbeat.") end
end

if isServer then
	game:BindToClose(function()
		warn("[DynamicSender] Server closing, flushing remaining batches...")
		-- Use pcall here as BindToClose handlers should be resilient
		pcall(processFrameBatches)
		task.wait(0.1) -- Brief wait to allow network packets to potentially send
		if runServiceConnection then runServiceConnection:Disconnect(); runServiceConnection = nil end
		warn("[DynamicSender] Shutdown flush attempt complete.")
	end)
end

return DynamicSender