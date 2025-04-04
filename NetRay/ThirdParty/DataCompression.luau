--!native
--[[
	LZW Module

	Provides functions for compressing and decompressing complex Luau data
	using LZW algorithm after converting the data to a JSON-compatible string format.
	Handles various Roblox datatypes and nested tables. Includes detailed debugging.

	Author: Asta (@TheYusufGamer)
]]

local LZW = {}

-- Services and Constants
local HttpService = game:GetService("HttpService")
local Workspace = game:GetService("Workspace") -- Needed for Instance path resolution

local BINARY_HEADER = string.char(0x02) -- Header for LZW compressed data
local UNCOMPRESSED_HEADER = string.char(0x01) -- Header for data sent uncompressed

-- Debug flag (set to true to enable detailed console output)
local DEBUG_MODE = false -- Set to true for detailed logging


-- Forward declarations for recursive functions
local encodeValue
local decodeValue

--- Encodes various Roblox datatypes into JSON-serializable tables with __type tags.
encodeValue = function(value: any): any
	local vType = typeof(value)

	if DEBUG_MODE then -- Conditional debug print
		local valueSnippet = value
		if vType == "string" then valueSnippet = string.sub(value :: string, 1, 40) .. (#(value :: string) > 40 and "..." or "")
		elseif vType == "table" then valueSnippet = "[table]"
		elseif vType ~= "number" and vType ~= "boolean" and vType ~= "nil" then valueSnippet = "[" .. vType .. "]" end
		-- print("encodeValue processing type:", vType, " snippet:", valueSnippet) -- Can be very verbose
	end

	-- Base Types
	if vType == "string" or vType == "number" or vType == "boolean" or vType == "nil" then
		return value

		-- Roblox Datatypes
	elseif vType == "Vector3" then local v3 = value :: Vector3; return { __type = "Vector3", x = v3.X, y = v3.Y, z = v3.Z }
	elseif vType == "Vector2" then local v2 = value :: Vector2; return { __type = "Vector2", x = v2.X, y = v2.Y }
	elseif vType == "Color3" then local c3 = value :: Color3; return { __type = "Color3", r = c3.R, g = c3.G, b = c3.B }
	elseif vType == "CFrame" then return { __type = "CFrame", components = { (value :: CFrame):GetComponents() } }
	elseif vType == "UDim2" then local u2 = value :: UDim2; return { __type = "UDim2", xs = u2.X.Scale, xo = u2.X.Offset, ys = u2.Y.Scale, yo = u2.Y.Offset }
	elseif vType == "UDim" then local u1 = value :: UDim; return { __type = "UDim", s = u1.Scale, o = u1.Offset }
	elseif vType == "Rect" then local rt = value :: Rect; return { __type = "Rect", minx = rt.Min.X, miny = rt.Min.Y, maxx = rt.Max.X, maxy = rt.Max.Y }
	elseif vType == "EnumItem" then
		local en = value :: EnumItem
		local enumTypeName = string.match(tostring(en.EnumType), "^Enum%.(.*)")
		if enumTypeName then return { __type = "Enum", enumType = enumTypeName, name = en.Name, value = en.Value }
		else warn("LZW Encoder: Could not determine EnumType name for", en); return nil end -- Error: cannot reliably serialize
	elseif vType == "BrickColor" then local bc = value :: BrickColor; return { __type = "BrickColor", num = bc.Number }
	elseif vType == "ColorSequence" then
		local cs = value :: ColorSequence; local keypoints = {}; for _, kp in ipairs(cs.Keypoints) do table.insert(keypoints, { t = kp.Time, r = kp.Value.R, g = kp.Value.G, b = kp.Value.B }) end
		return { __type = "ColorSequence", keypoints = keypoints }
	elseif vType == "NumberSequence" then
		local ns = value :: NumberSequence; local keypoints = {}; for _, kp in ipairs(ns.Keypoints) do table.insert(keypoints, { t = kp.Time, v = kp.Value, e = kp.Envelope }) end
		return { __type = "NumberSequence", keypoints = keypoints }
	elseif vType == "NumberRange" then local nr = value :: NumberRange; return { __type = "NumberRange", min = nr.Min, max = nr.Max }
	elseif vType == "Instance" then
		local inst = value :: Instance; local path = inst:GetPath()
		if string.sub(path, 1, #("Workspace") + 1) == "Workspace." then path = string.sub(path, #("Workspace") + 2); return { __type = "InstancePath", path = path }
		else warn("LZW Enc: Can't get relative Instance path for:", inst:GetFullName(), "- Storing FullName (unreliable)."); return { __type = "InstanceName", name = inst:GetFullName() } end
		-- Implement More Data types in the future

		-- Tables
	elseif vType == "table" then
		local encodedTable
		local isPureArray = true
		local numElements = 0
		for k in pairs(value) do
			numElements += 1
			if typeof(k) ~= 'number' or k <= 0 or k > numElements or math.floor(k) ~= k then isPureArray = false end
		end
		if isPureArray and numElements ~= #value then isPureArray = false end -- Check sparseness

		if isPureArray then
			-- Encode as a JSON array
			encodedTable = {}
			if DEBUG_MODE then print("Encoding table as ARRAY, len:", #value) end
			for i = 1, #value do
				--print("--- Encoding array element at index:", i) -- Inner debug print
				local element = value[i]
				local encodeElementSuccess, encodedElementOrErr = pcall(encodeValue, element)

				if not encodeElementSuccess then
					warn(string.format("!!! FAILED encoding array element at index %d: %s", i, tostring(encodedElementOrErr)))
					-- Option 1: Store error marker (keeps structure, fails later potentially)
					encodedTable[i] = { __error = "Encoding failed: " .. tostring(encodedElementOrErr) }
					-- Option 2: Propagate failure (makes outer pcall fail)
					-- error(string.format("Failed encoding array element at index %d: %s", i, tostring(encodedElementOrErr))) -- This will be caught by pcall in convertDataToString
				elseif encodedElementOrErr == nil and element ~= nil then
					warn(string.format("!!! NIL result encoding non-nil array element at index %d (Original type: %s)", i, typeof(element)))
					encodedTable[i] = nil -- Explicitly insert nil
				else
					encodedTable[i] = encodedElementOrErr
				end
			end
		--	print("--- Reached END of array processing. Returning table. Type:", type(encodedTable))
			return encodedTable 

		else
			-- Encode as a JSON object (dictionary), ensuring string keys
			encodedTable = {}
			if DEBUG_MODE then print("Encoding table as DICTIONARY") end
			for k, v in pairs(value) do
				local keyString: string
				if typeof(k) == "string" then keyString = k
				else keyString = tostring(k) end -- Convert non-string keys
				-- if DEBUG_MODE and keyString ~= k then warn("LZW Encoder: Converted key to string:", k, "->", keyString) end -- Optional warning

				--print("--- Encoding dictionary value for key:", keyString) -- Inner debug print
				local encodeValSuccess, encodedValOrErr = pcall(encodeValue, v)

				if not encodeValSuccess then
					warn(string.format("!!! FAILED encoding dictionary value for key '%s': %s", keyString, tostring(encodedValOrErr)))
					encodedTable[keyString] = { __error = "Encoding failed: " .. tostring(encodedValOrErr) }
					-- error(string.format("Failed encoding dictionary value for key '%s': %s", keyString, tostring(encodedValOrErr))) -- Option 2: Propagate failure
				elseif encodedValOrErr == nil and v ~= nil then
					warn(string.format("!!! NIL result encoding non-nil dictionary value for key '%s' (Original type: %s)", keyString, typeof(v)))
					encodedTable[keyString] = nil
				else
					encodedTable[keyString] = encodedValOrErr
				end
			end
			return encodedTable -- Return dictionary
		end

	else
		-- Type not explicitly handled by any previous block
		-- This indicates a missing type in the 'if/elseif' chain
		warn("LZW Encoder: Unhandled type automatically considered an error: " .. vType .. " for value:", value)
		error("LZW Encoder: Unhandled type reached end of encodeValue: " .. vType) -- Error out
	end
end

--- Decodes JSON-parsed data (with __type tags) back into Roblox objects.
decodeValue = function(value: any): any
	local vType = typeof(value)

	if vType == "table" and value.__type then
		local tag = value.__type
		if tag == "Vector3" then return Vector3.new(value.x, value.y, value.z) end
		if tag == "Vector2" then return Vector2.new(value.x, value.y) end
		if tag == "Color3" then return Color3.new(value.r, value.g, value.b) end
		if tag == "CFrame" then return CFrame.new(unpack(value.components)) end
		if tag == "UDim2" then return UDim2.new(value.xs, value.xo, value.ys, value.yo) end
		if tag == "UDim" then return UDim.new(value.s, value.o) end
		if tag == "Rect" then return Rect.new(value.minx, value.miny, value.maxx, value.maxy) end
		if tag == "Enum" then if Enum[value.enumType] then return Enum[value.enumType][value.name] else warn("LZW Decoder: Unknown EnumType:", value.enumType); return nil end end
		if tag == "BrickColor" then return BrickColor.new(value.num) end
		if tag == "ColorSequence" then local kp = {}; for _, d in ipairs(value.keypoints) do table.insert(kp, ColorSequenceKeypoint.new(d.t, Color3.new(d.r, d.g, d.b))) end; return ColorSequence.new(kp) end
		if tag == "NumberSequence" then local kp = {}; for _, d in ipairs(value.keypoints) do table.insert(kp, NumberSequenceKeypoint.new(d.t, d.v, d.e)) end; return NumberSequence.new(kp) end
		if tag == "NumberRange" then return NumberRange.new(value.min, value.max) end
		if tag == "InstancePath" then local s, f = pcall(Workspace.FindFirstChild, Workspace, value.path, true); if s and f then return f else warn("LZW Decoder: Instance path not found:", value.path); return nil end end
		if tag == "InstanceName" then warn("LZW Decoder: Cannot reconstruct Instance from FullName:", value.name); return nil end

		warn("LZW Decoder: Unhandled __type tag:", tag); return value -- Return table if tag unhandled

	elseif vType == "table" then
		-- Regular table, check if array or dictionary based on keys from JSON
		local isJsonArray = true
		local maxArrayIndex = 0
		local keyCount = 0
		for k in pairs(value) do
			keyCount += 1
			local numKey = tonumber(k)
			if typeof(k) ~= "string" or not numKey or numKey <= 0 or numKey > keyCount or math.floor(numKey) ~= numKey then isJsonArray = false; break end -- Break optimization
			maxArrayIndex = math.max(maxArrayIndex, numKey)
		end
		if keyCount ~= maxArrayIndex then isJsonArray = false end -- Check sequentiality

		local decodedTable = {}
		if isJsonArray then
			for i = 1, keyCount do decodedTable[i] = decodeValue(value[tostring(i)]) end
		else
			for kString, v in pairs(value) do
				local originalKey; local numKey = tonumber(kString)
				if numKey ~= nil and tostring(numKey) == kString then originalKey = numKey else originalKey = kString end
				decodedTable[originalKey] = decodeValue(v)
			end
		end
		return decodedTable
	else
		-- Base type
		return value
	end
end

--- Main serialization function using the custom encoder + JSON
local function convertDataToString(data: any): (string?)
	if DEBUG_MODE then print("--- convertDataToString: Encoding data ---") end
	print(data)
	local encodeSuccess, encodedDataOrErr = pcall(encodeValue, data)
	if not encodeSuccess then
		warn("LZW Serializer: pcall(encodeValue, data) FAILED. Error:", encodedDataOrErr)
		return nil
	elseif encodedDataOrErr == nil and data ~= nil then
		warn("LZW Serializer: encodeValue succeeded but returned nil for non-nil input.")
		return nil -- Treat this as an encoding failure if the input wasn't nil
	end

	local encodedData = encodedDataOrErr

	if DEBUG_MODE then print("--- convertDataToString: Structure type pre-JSON:", type(encodedData)) end

	if DEBUG_MODE then print("--- convertDataToString: Calling JSONEncode ---") end
	local jsonSuccess, jsonStringOrError = pcall(HttpService.JSONEncode, HttpService, encodedData)
	if not jsonSuccess then
		warn("LZW Serializer: HttpService:JSONEncode FAILED - ", jsonStringOrError)
		return nil
	end
	if DEBUG_MODE then print("--- convertDataToString: JSONEncode succeeded, length:", #jsonStringOrError) end
	return jsonStringOrError
end

--- Main deserialization function using JSON + the custom decoder
local function convertStringToData(jsonString: string): (any)
	if not jsonString or #jsonString == 0 then return nil end

	local success, decodedJson = pcall(HttpService.JSONDecode, HttpService, jsonString)
	if not success then
		warn("LZW Deserializer: HttpService:JSONDecode FAILED - ", decodedJson)
		return nil
	end

	local decodeSuccess, originalData = pcall(decodeValue, decodedJson)
	if not decodeSuccess then
		warn("LZW Deserializer: decodeValue FAILED -", originalData)
		return nil
	end

	return originalData
end

local function compressLZW(inputStr: string): {number}
	local dictSize = 256
	local dictionary = {}
	for i = 0, 255 do dictionary[string.char(i)] = i end
	local w = ""
	local result = {}
	local inputLength = #inputStr
	for i = 1, inputLength do
		local c = inputStr:sub(i, i)
		local wc = w .. c
		if dictionary[wc] then
			w = wc
		else
			table.insert(result, dictionary[w])
			dictionary[wc] = dictSize
			dictSize += 1
			w = c
		end
	end
	if w ~= "" then table.insert(result, dictionary[w]) end
	return result
end

local function decompressLZW(compressedCodes: {number}): (string?)
	if #compressedCodes == 0 then return "" end
	local dictSize = 256
	local dictionary = {}
	for i = 0, 255 do dictionary[i] = string.char(i) end
	local w = dictionary[compressedCodes[1]]
	if not w then warn("LZW Decomp: Invalid start code."); return nil end
	local result = {w}
	local entry = ""
	for i = 2, #compressedCodes do
		local k = compressedCodes[i]
		if dictionary[k] then
			entry = dictionary[k]
		elseif k == dictSize then
			entry = w .. w:sub(1, 1)
		else
			warn("LZW Decomp: Invalid code " .. tostring(k) .. " at index " .. i)
			return nil
		end
		table.insert(result, entry)
		dictionary[dictSize] = w .. entry:sub(1, 1)
		dictSize += 1
		w = entry
	end
	return table.concat(result)
end

local function encodeVarint(codes: {number}): string
	local bytes = {}
	for _, code in ipairs(codes) do
		local c = code
		repeat
			local byteValue = c % 128
			c = math.floor(c / 128)
			if c > 0 then byteValue = byteValue + 128 end
			table.insert(bytes, string.char(byteValue))
		until c == 0
	end
	return table.concat(bytes)
end

local function decodeVarint(compressedStr: string): ({number}?)
	local codes = {}
	local currentCode = 0
	local shift = 0
	local strLen = #compressedStr
	for i = 1, strLen do
		local byteValue = string.byte(compressedStr, i)
		if not byteValue then warn("Varint Decode: Bad byte read."); return nil end
		currentCode = currentCode + (byteValue % 128) * (2 ^ (shift * 7))
		shift = shift + 1
		if byteValue < 128 then
			table.insert(codes, currentCode)
			currentCode = 0
			shift = 0
		end
	end
	if shift > 0 then warn("Varint Decode: Truncated sequence."); return nil end
	return codes
end

--- Compresses data using the custom serializer and then LZW.
-- @param data The data to compress.
-- @return string? The compressed binary string (with header), or nil on failure.
function LZW:Compress(data: any): (string?)
	-- 1. Serialize using custom JSON approach
	print(data)
	local serializedStr = convertDataToString(data)
	if not serializedStr then
		warn("LZW Compress: Serialization failed.")
		return nil
	end
	if #serializedStr == 0 then -- Handle empty serialization result
		return UNCOMPRESSED_HEADER .. ""
	end

	-- 2. Perform LZW Compression (use pcall for safety)
	local lzwSuccess, codesOrErr = pcall(compressLZW, serializedStr)
	if not lzwSuccess or not codesOrErr then
		warn("LZW Compress: compressLZW failed - ", codesOrErr)
		return nil
	end
	local codes = codesOrErr :: {number} -- Cast after success check

	-- 3. Encode Varint (use pcall for safety)
	local varintSuccess, compressedVarintStrOrErr = pcall(encodeVarint, codes)
	if not varintSuccess or not compressedVarintStrOrErr then
		warn("LZW Compress: encodeVarint failed - ", compressedVarintStrOrErr)
		return nil
	end
	local compressedVarintStr = compressedVarintStrOrErr :: string -- Cast

	-- 4. Construct final compressed string and compare sizes
	local compressedDataWithHeader = BINARY_HEADER .. compressedVarintStr
	if #compressedDataWithHeader >= #serializedStr + 1 then
		if DEBUG_MODE then print("LZW Compress: Using uncompressed (LZW larger/equal)") end
		return UNCOMPRESSED_HEADER .. serializedStr
	else
		if DEBUG_MODE then print(string.format("LZW Compress: Using compressed (Original: %d, LZW+Hdr: %d)", #serializedStr, #compressedDataWithHeader)) end
		return compressedDataWithHeader
	end
end

--- Decompresses data that was compressed by LZW:Compress.
-- @param compressedString The binary string received (with header).
-- @return any The original data, or nil on failure.
function LZW:Decompress(compressedString: string): (any)
	if not compressedString or #compressedString < 1 then
		warn("LZW Decompress: Nil/Empty input.")
		return nil
	end

	local header = compressedString:sub(1, 1)
	local dataString = compressedString:sub(2)
	local deserializedData: any

	if header == UNCOMPRESSED_HEADER then
		if DEBUG_MODE then print("LZW Decompress: Handling UNCOMPRESSED data") end
		deserializedData = convertStringToData(dataString)

	elseif header == BINARY_HEADER then
		if DEBUG_MODE then print("LZW Decompress: Handling LZW data") end
		-- Decode Varint first
		local decodeSuccess, codesOrErr = pcall(decodeVarint, dataString)
		if not decodeSuccess or not codesOrErr then warn("LZW Decomp: Varint decode failed -", codesOrErr); return nil end
		local codes = codesOrErr :: {number}
		if #codes == 0 and #dataString > 0 then warn("LZW Decomp: Varint produced no codes from non-empty input."); return nil end

		-- Decompress LZW
		local decompSuccess, decompressedStrOrErr = pcall(decompressLZW, codes)
		if not decompSuccess or not decompressedStrOrErr then warn("LZW Decomp: Core LZW decompression failed -", decompressedStrOrErr); return nil end
		local decompressedStr = decompressedStrOrErr :: string

		-- Deserialize the resulting string
		deserializedData = convertStringToData(decompressedStr)
	else
		warn("LZW Decomp: Invalid header byte: " .. tostring(string.byte(header)))
		return nil
	end

	-- Check final result
	if deserializedData == nil and #compressedString > 1 then
		-- Only warn if we expected data but got nil (e.g., internal deserialization error)
		warn("LZW Decomp: Final deserialization resulted in nil.")
	end

	return deserializedData
end

return LZW