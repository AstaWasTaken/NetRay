--!native
--!optimize 2

--[[
    LZ4_Lib

    Pure Luau implementation of LZ4 Block Compression Format (Luau Compliant)
    Includes BinaryEncoder integration and header handling.
]]

local LZ4_Lib = {}

--[[* Dependencies *]]
local BinaryEncoderModule = require(script.Parent.Parent.ThirdParty.BinaryEncoder)
type BinaryEncoder = {
	encode: (data: any) -> string?, -- Returns string on success, nil on error
	decode: (encoded: string) -> any? -- Returns original data on success, nil on error
}

-- Assert dependency exists and has expected methods
assert(BinaryEncoderModule, "LZ4_Lib requires the BinaryEncoder module.")
assert(typeof(BinaryEncoderModule.encode) == "function", "BinaryEncoder module must have an 'encode' function.")
assert(typeof(BinaryEncoderModule.decode) == "function", "BinaryEncoder module must have a 'decode' function.")

-- Assign typed module
local BinaryEncoder: BinaryEncoder = BinaryEncoderModule

--[[* Type Definitions *]]
-- Type for the LZ4_Lib module itself
export type LZ4Module = {
	Compress: (self: LZ4Module, data: any) -> string?, -- Returns header+payload string or nil
	Decompress: (self: LZ4Module, data: string) -> any? -- Returns original data or nil
}

--[[* Constants *]]
-- Header Bytes (Using string constants)
local RAW_STRING_HEADER: string     = string.char(0x01)
local RAW_ENCODED_HEADER: string    = string.char(0x02)
local LZ4_STRING_HEADER: string     = string.char(0x03)
local LZ4_ENCODED_HEADER: string    = string.char(0x04)

-- LZ4 Constants (number types assumed)
local MINMATCH = 4; local KB = 1024; local MB = 1024 * KB; local MAX_INPUT_SIZE = 50 * MB
local HASH_LOG = 12; local HASH_TABLE_SIZE = bit32.lshift(1, HASH_LOG)
local MAX_DISTANCE = bit32.lshift(1, 16) - 1; local ML_BITS = 4
local ML_MASK = bit32.lshift(1, ML_BITS) - 1; local RUN_BITS = 8 - ML_BITS
local RUN_MASK = bit32.lshift(1, RUN_BITS) - 1; local HASH_SEED_32 = 2654435761
local MIN_COMPRESSION_INPUT_LEN = 64; local COMPRESSION_WORTH_RATIO = 0.98

-- Character cache table (type { [number]: string })
local CHARS: {[number]: string} = {}
for i = 0, 255 do CHARS[i] = string.char(i) end

--[[* Helper Functions (LZ4 Core & General) - Typed *]]
local function read_u16_le(input: string, pos: number): (number?, number?) -- Returns value?, newPos?
	local b1 = string.byte(input, pos); local b2 = string.byte(input, pos + 1)
	if not b1 or not b2 then return nil, nil end
	return bit32.bor(b1, bit32.lshift(b2, 8)), pos + 2
end
local function write_u16_le(value: number, chunks: {string})
	table.insert(chunks, CHARS[bit32.band(value, 0xFF)])
	table.insert(chunks, CHARS[bit32.band(bit32.rshift(value, 8), 0xFF)])
end
local function write_lz4_len(len_to_encode: number, baseValue: number, chunks: {string})
	local extra_len = len_to_encode - baseValue
	if extra_len < 0 then extra_len = 0 end
	local val = extra_len
	while val >= 255 do table.insert(chunks, CHARS[0xFF]); val -= 255 end
	table.insert(chunks, CHARS[val])
end
local function read_length(input: string, pos: number, baseLength: number, maskValue: number): (number?, number?) -- Returns length?, newPos?
	local length = baseLength
	if length == maskValue then
		local byteVal; local sum = 0
		repeat
			byteVal = string.byte(input, pos)
			if not byteVal then return nil, pos end -- Check for end of string
			sum += byteVal; pos += 1
		until byteVal ~= 255
		length += sum
	end
	return length, pos
end
local function mul32(a: number, b: number): number -- Internal bit manipulation, returns number
	local aL=bit32.band(a,0xFFFF); local aH=bit32.rshift(a,16); local bL=bit32.band(b,0xFFFF); local bH=bit32.rshift(b,16)
	local p1=aL*bL; local p2=aL*bH; local p3=aH*bL; local rL=bit32.band(p1,0xFFFF); local cy=bit32.rshift(p1,16)
	local mS=cy+bit32.band(p2,0xFFFF)+bit32.band(p3,0xFFFF); local rH=bit32.band(mS,0xFFFF)
	return bit32.bor(bit32.lshift(rH,16),rL)
end
local function hash_sequence(input: string, pos: number): number -- Returns hash number
	local b1=string.byte(input,pos) or 0; local b2=string.byte(input,pos+1) or 0; local b3=string.byte(input,pos+2) or 0; local b4=string.byte(input,pos+3) or 0
	local sequence=bit32.bor(b1,bit32.lshift(b2,8),bit32.lshift(b3,16),bit32.lshift(b4,24))
	local h=mul32(sequence,HASH_SEED_32); return bit32.rshift(h,32-HASH_LOG)
end

--[[* Core LZ4 Compression Logic - Typed *]]
-- Takes string, returns (success: boolean, result: string | nil) - result is compressed string or nil on critical failure
local function compressor(input: string): (boolean, string?)
	local inputLen = #input
	if inputLen == 0 then return true, "" end
	if inputLen > MAX_INPUT_SIZE then warn("LZ4 Input too large"); return false, nil end -- Return nil on failure

	local success, result = pcall(function(): string -- Inner function returns compressed string
		local hashTable: {[number]: number} = {} -- hash -> position
		local outputChunks: {string} = {}
		local ip = 1; local anchor = 1; local inputByte = string.byte

		while ip <= inputLen do
			local ref; local matchFound = false
			if ip <= inputLen - MINMATCH + 1 then
				local h = hash_sequence(input, ip); ref = hashTable[h]; hashTable[h] = ip
				if ref and (ip - ref <= MAX_DISTANCE) then
					-- Check 4 bytes match (manually for potential slight speedup vs substring compare)
					if inputByte(input, ref) == inputByte(input, ip) and inputByte(input, ref+1) == inputByte(input, ip+1) and
						inputByte(input, ref+2) == inputByte(input, ip+2) and inputByte(input, ref+3) == inputByte(input, ip+3) then
						local literalLength = ip - anchor; local offset = ip - ref; local matchLen = MINMATCH
						local ipFast = ip + matchLen; local refFast = ref + matchLen
						-- Find full match length
						while ipFast <= inputLen and inputByte(input, ipFast) == inputByte(input, refFast) do matchLen += 1; ipFast += 1; refFast += 1 end
						-- Write token, lengths, literals, offset
						local tokenLitLen = math.min(literalLength, RUN_MASK); local tokenMatchLen = math.min(matchLen - MINMATCH, ML_MASK)
						local token = bit32.bor(bit32.lshift(tokenLitLen, ML_BITS), tokenMatchLen)
						table.insert(outputChunks, CHARS[token])
						if tokenLitLen == RUN_MASK then write_lz4_len(literalLength, RUN_MASK, outputChunks) end
						if literalLength > 0 then table.insert(outputChunks, string.sub(input, anchor, ip - 1)) end
						write_u16_le(offset, outputChunks)
						if tokenMatchLen == ML_MASK then write_lz4_len(matchLen - MINMATCH, ML_MASK, outputChunks) end
						-- Update pointers
						ip += matchLen; anchor = ip; matchFound = true
					end
				end
			end
			if not matchFound then ip += 1 end -- Advance if no match found
		end
		-- Write final literals
		local finalLiteralLength = inputLen - anchor + 1
		if finalLiteralLength > 0 then
			local tokenLiteralLenPart = math.min(finalLiteralLength, RUN_MASK)
			local token = bit32.lshift(tokenLiteralLenPart, ML_BITS)
			table.insert(outputChunks, CHARS[token])
			if tokenLiteralLenPart == RUN_MASK then write_lz4_len(finalLiteralLength, RUN_MASK, outputChunks) end
			table.insert(outputChunks, string.sub(input, anchor, inputLen))
		end
		return table.concat(outputChunks)
	end)

	if success then return true, result :: string? -- result is string or nil if input was empty initially (handled above)
	else warn("LZ4 Compression Internal Error:", result); return false, nil -- Return nil on internal pcall error
	end
end

--[[* Core LZ4 Decompression Logic - Typed *]]
-- Takes compressed string, returns (success: boolean, result: string | nil) - result is decompressed string or nil on failure
local function decompressor(input: string): (boolean, string?)
	local inputLen = #input
	if inputLen == 0 then return true, "" end

	local success, result = pcall(function(): string -- Inner function returns decompressed string
		local outputBytes: {string} = {}
		local op = 0; local ip = 1; local inputByte = string.byte; local sub = string.sub

		while ip <= inputLen do
			local token = inputByte(input, ip); if not token then error("LZ4 stream end reading token @ "..ip, 0) end; ip += 1
			local literalLengthBase = bit32.rshift(token, ML_BITS)
			local literalLength, newIpLl = read_length(input, ip, literalLengthBase, RUN_MASK); if not literalLength then error("LZ4 stream truncated literal len @ "..ip, 0) end; ip = newIpLl
			if literalLength > 0 then
				local litEnd = ip + literalLength - 1; if litEnd > inputLen then error("LZ4 stream literal OOB", 0) end
				table.insert(outputBytes, sub(input, ip, litEnd)); op += literalLength; ip += literalLength
			end
			if ip > inputLen then break end -- End of stream after literals
			local offset, newIpOff = read_u16_le(input, ip); if not offset then error("LZ4 stream truncated offset @ "..ip, 0) end; if offset == 0 then error("LZ4 stream offset=0 @ "..ip, 0) end; ip = newIpOff
			local matchLengthBase = bit32.band(token, ML_MASK)
			local matchLength, newIpMl = read_length(input, ip, matchLengthBase, ML_MASK); if not matchLength then error("LZ4 stream truncated match len @ "..ip, 0) end; ip = newIpMl
			matchLength += MINMATCH
			local matchSourceStart = op - offset + 1; if matchSourceStart < 1 then error("LZ4 stream invalid offset "..offset.." (op="..op..") @ "..ip, 0) end

			-- Copy match data (Handling overlap)
			local currentOutputStr = table.concat(outputBytes) -- Snapshot current output
			if offset >= matchLength then -- No overlap
				if matchSourceStart + matchLength - 1 > op then error("LZ4 non-overlap OOB", 0) end
				table.insert(outputBytes, sub(currentOutputStr, matchSourceStart, matchSourceStart + matchLength - 1))
			else -- Overlap
				local tempCopyTable = {}; local snapshotLen = #currentOutputStr
				if matchSourceStart > snapshotLen then error("LZ4 overlap source start OOB", 0) end
				for i=1, matchLength do
					local readPos = matchSourceStart + i - 1
					local byteValue: number?
					if readPos <= snapshotLen then byteValue = inputByte(currentOutputStr, readPos)
					else local tempIdx = readPos - snapshotLen; if tempIdx <= 0 or tempIdx > #tempCopyTable then error("LZ4 overlap temp read OOB", 0) end; byteValue = string.byte(tempCopyTable[tempIdx], 1) end
					if not byteValue then error("LZ4 overlap read byte fail", 0) end
					table.insert(tempCopyTable, CHARS[byteValue])
				end
				table.insert(outputBytes, table.concat(tempCopyTable))
			end
			op += matchLength
		end
		-- Return final concatenated string
		return table.concat(outputBytes)
	end)

	if success then return true, result :: string? -- Result is string or nil if empty
	else warn("LZ4 Decompression Internal Error:", result); return false, nil -- Return nil on internal pcall error
	end
end

--[[* Public Interface Methods - Typed *]]

function LZ4_Lib:Compress(data: any): string?
	local payloadData: string
	local isRawString: boolean

	if typeof(data) == "string" then payloadData = data; isRawString = true
	else
		local encodeSuccess, encoded = pcall(BinaryEncoder.encode, data)
		if not encodeSuccess or typeof(encoded) ~= "string" then warn("LZ4 Compress: Encode fail - ", encoded); return nil end
		payloadData = encoded; isRawString = false
	end

	local payloadLen = #payloadData
	if payloadLen < MIN_COMPRESSION_INPUT_LEN then
		return (if isRawString then RAW_STRING_HEADER else RAW_ENCODED_HEADER) .. payloadData
	end

	local compressSuccess, compressedData = compressor(payloadData)
	if not compressSuccess then -- compressor returns nil on failure now
		warn("LZ4 Compress: Compressor fail - sending raw. Size:", payloadLen)
		return (if isRawString then RAW_STRING_HEADER else RAW_ENCODED_HEADER) .. payloadData
	end

	-- Check if compression worthwhile (compressedData is guaranteed string here)
	local compressedStr = compressedData :: string
	if #compressedStr < (payloadLen * COMPRESSION_WORTH_RATIO) then
		return (if isRawString then LZ4_STRING_HEADER else LZ4_ENCODED_HEADER) .. compressedStr
	else -- Not worthwhile
		return (if isRawString then RAW_STRING_HEADER else RAW_ENCODED_HEADER) .. payloadData
	end
end


function LZ4_Lib:Decompress(data: string): any?
	if typeof(data) ~= "string" or #data < 1 then warn("LZ4 Decompress: Invalid input."); return nil end

	local header: string = string.sub(data, 1, 1)
	local payload: string = string.sub(data, 2)
	local needsDecode = false; local isCompressed = false

	if header == RAW_STRING_HEADER then needsDecode=false; isCompressed=false
	elseif header == RAW_ENCODED_HEADER then needsDecode=true; isCompressed=false
	elseif header == LZ4_STRING_HEADER then needsDecode=false; isCompressed=true
	elseif header == LZ4_ENCODED_HEADER then needsDecode=true; isCompressed=true
	else warn("LZ4 Decompress: Unknown header:", string.byte(header,1)); return nil
	end

	local processedPayload: string?
	if isCompressed then
		local decompressSuccess, decompressedData = decompressor(payload)
		if not decompressSuccess then warn("LZ4 Decompress: Decompressor fail. Header:", string.byte(header,1)); return nil end
		processedPayload = decompressedData
	else
		processedPayload = payload
	end

	if processedPayload == nil then warn("LZ4 Decompress: Payload nil post-process. Header:", string.byte(header,1)); return nil end

	if needsDecode then
		local decodeSuccess, originalData = pcall(BinaryEncoder.decode, processedPayload)
		if not decodeSuccess then warn("LZ4 Decompress: Decode fail -", originalData, "- Header:", string.byte(header,1)); return nil end
		return originalData -- Return decoded Luau data
	else
		return processedPayload -- Return raw/decompressed string
	end
end

-- Return the module table, asserting its type
return LZ4_Lib :: LZ4Module