--!optimize 2
--!native

-- BinaryEncoder.lua (Revised for LZ4 Compatibility, Cyclic References, Pack Formats, Recursion Fixes, and Integer Check)
-- Author: Asta (@TheYusufGamer)
-- Version: v1.5.4 (Fixed instance handling)

local BinaryEncoder = {}

-- Binary type identifiers 
local TYPE = {
	NIL = 0, BOOLEAN_FALSE = 1, BOOLEAN_TRUE = 2, NUMBER_INT8 = 3, NUMBER_INT16 = 4,
	NUMBER_INT32 = 5, NUMBER_FLOAT32 = 6, STRING_SHORT = 7, STRING_LONG = 8, TABLE_START = 9,
	TABLE_END = 10, ARRAY_START = 11, ARRAY_END = 12, REFERENCE = 13, VECTOR3 = 14,
	COLOR3 = 15, UDIM2 = 16, CFRAME = 17, VECTOR2 = 18, RECT = 19, ENUM = 20,
	INSTANCE_REF = 21, DATETIME = 22, BRICKCOLOR = 23, NUMBERSEQUENCE = 24, COLORSEQUENCE = 25,
	BUFFER = 26, ARRAY_HOMOGENEOUS = 27, VALUE_TYPE_ID = 28, NUMBER_ZERO = 29, STRING_EMPTY = 30,
}

-- HOMOGENEOUS_TYPE_MAP 
local HOMOGENEOUS_TYPE_MAP = {
	["number"] = TYPE.NUMBER_FLOAT32, ["string"] = TYPE.STRING_SHORT, ["Vector3"] = TYPE.VECTOR3,
	["Vector2"] = TYPE.VECTOR2, ["Color3"] = TYPE.COLOR3, ["boolean"] = TYPE.BOOLEAN_FALSE,
	["CFrame"] = TYPE.CFRAME, ["UDim2"] = TYPE.UDIM2, ["Rect"] = TYPE.RECT, ["EnumItem"] = TYPE.ENUM,
	["BrickColor"] = TYPE.BRICKCOLOR, ["DateTime"] = TYPE.DATETIME, ["buffer"] = TYPE.BUFFER,
}

-- Roblox Globals Cache 
local Vector3_new = Vector3.new; local Vector2_new = Vector2.new; local Color3_new = Color3.new
local UDim2_new = UDim2.new; local Rect_new = Rect.new; local CFrame_new = CFrame.new
local Enum_Type = Enum; local DateTime_FromMillis = DateTime.fromUnixTimestampMillis
local BrickColor_new = BrickColor.new; local NumberSequence_new = NumberSequence.new
local ColorSequence_new = ColorSequence.new; local NumberSequenceKeypoint_new = NumberSequenceKeypoint.new
local ColorSequenceKeypoint_new = ColorSequenceKeypoint.new; local buffer_len = buffer.len
local buffer_tostring = buffer.tostring; local buffer_fromstring = buffer.fromstring
local string_pack = string.pack; local string_unpack = string.unpack; local string_sub = string.sub
local string_byte = string.byte; local string_char = string.char; local table_insert = table.insert
local table_concat = table.concat; local pairs = pairs; local ipairs = ipairs; local type = type
local typeof = typeof; local math_floor = math.floor; local math_max = math.max
local math_abs = math.abs; local pcall = pcall; local warn = warn; local error = error
local tostring = tostring

-- Reuse string characters Cache 
local CHAR_CACHE = {}
for i = 0, 255 do CHAR_CACHE[i] = string_char(i) end

-- Recursion depth limit 
local MAX_DEPTH = 500

-- Error formatting helper 
local function encodingError(msg: string, currentDepth: number): nil error(("[BE Enc Err d%d] %s"):format(currentDepth, msg), 3) return nil end
local function decodingError(msg: string, index: number): nil error(("[BE Dec Err @%d] %s"):format(index, msg), 3) return nil end

--[[ Helper: isInteger ]]
local function isInteger(value: number): boolean return math_abs(value - math_floor(value)) < 0.00001 end

-- Helper to write/read length 
local function writeLength(len: number): string if len < 255 then return CHAR_CACHE[len] else return CHAR_CACHE[255] .. string_pack(">I4", len) end end
local function readLength(data: string, index: number): (number?, number?) local b=string_byte(data,index); if not b then return decodingError("readLen byte",index) end; index+=1; if b<255 then return b,index else if index+3>#data then return decodingError("readLen data",index) end; local l,ni=string_unpack(">I4",data,index); if not l then return decodingError("readLen unpack",index) end; return l,ni end end

--[[ Helper: Get Instance Path ]]
local function getInstancePath(instance: Instance): string?
	if not instance then return nil end -- Handle nil input gracefully

	local names = {}
	local current: Instance? = instance
	local gameService = game -- Cache the global

	-- Walk up the hierarchy until 'game' or nil is reached
	while current and current ~= gameService do
		-- Check for invalid characters in names if necessary, though usually not an issue
		-- if string.find(current.Name, ".", 1, true) then
		--     warn("[BE Enc] Instance name contains '.' which might break pathfinding:", current:GetFullName())
		-- end
		table_insert(names, 1, current.Name) -- Prepend name
		current = current.Parent
	end

	-- If the loop stopped because we hit 'game', the path is valid relative to game
	if current == gameService then
		return table_concat(names, ".")
	else
		-- Instance is not a descendant of game (e.g., parented to nil, CoreGui, etc.)
		-- These often cannot or should not be reliably serialized by path.
		warn(("[BE Enc] Instance %q is not a descendant of game, cannot create serializable path."):format(tostring(instance)))
		return nil
	end
end

--[[ Helper: Get Instance At Path ]]
function GetInstanceAtPath(path)
	local current = game
	for segment in string.gmatch(path, "[^%.]+") do
		current = current:FindFirstChild(segment)
		if not current then
			return nil
		end
	end
	return current
end

--[[--- Internal Encoding Logic ---]]
local function encodeValue(value: any, refs_encoding: {}, buffer: {string}, currentDepth: number)

	if currentDepth > MAX_DEPTH then return encodingError("Max depth", currentDepth) end

	local valueType = typeof(value)
	local rawType = type(value)

	if value == nil then table_insert(buffer, CHAR_CACHE[TYPE.NIL])
	elseif rawType == "boolean" then table_insert(buffer, CHAR_CACHE[value and TYPE.BOOLEAN_TRUE or TYPE.BOOLEAN_FALSE])
	elseif rawType == "number" then
		if value == 0 then table_insert(buffer, CHAR_CACHE[TYPE.NUMBER_ZERO])
		elseif isInteger(value) then
			if value >= -128 and value <= 127 then table_insert(buffer, CHAR_CACHE[TYPE.NUMBER_INT8]); table_insert(buffer, string_pack("<i1", value))
			elseif value >= -32768 and value <= 32767 then table_insert(buffer, CHAR_CACHE[TYPE.NUMBER_INT16]); table_insert(buffer, string_pack("<i2", value))
			elseif value >= -2147483648 and value <= 2147483647 then table_insert(buffer, CHAR_CACHE[TYPE.NUMBER_INT32]); table_insert(buffer, string_pack("<i4", value))
			else warn("[BE Enc] Int >32bit->Float32:", value); table_insert(buffer, CHAR_CACHE[TYPE.NUMBER_FLOAT32]); table_insert(buffer, string_pack("<f", value)) end
		else table_insert(buffer, CHAR_CACHE[TYPE.NUMBER_FLOAT32]); table_insert(buffer, string_pack("<f", value)) end
	elseif rawType == "string" then
		local len = #value; if len == 0 then table_insert(buffer, CHAR_CACHE[TYPE.STRING_EMPTY])
		else local lb=writeLength(len); table_insert(buffer, CHAR_CACHE[#lb==1 and TYPE.STRING_SHORT or TYPE.STRING_LONG]); table_insert(buffer,lb); table_insert(buffer, value) end
	elseif rawType == "table" then
		local ref_id = refs_encoding[value]; if ref_id then table_insert(buffer, CHAR_CACHE[TYPE.REFERENCE]); encodeValue(ref_id, refs_encoding, buffer, currentDepth + 1)
		else
			local current_ref_id = #refs_encoding + 1; refs_encoding[value] = current_ref_id
			local count, max_idx, is_dictionary = 0, 0, false
			for k in pairs(value) do count += 1; if type(k) == "number" and k >= 1 and math_floor(k) == k then max_idx = math_max(max_idx, k) else is_dictionary = true end end
			if not is_dictionary and count > 0 and max_idx > count * 2 and max_idx > 10 then is_dictionary = true end -- Sparse check

			if not is_dictionary and count == max_idx then -- Array
				if count == 0 then table_insert(buffer, CHAR_CACHE[TYPE.ARRAY_START]); table_insert(buffer, CHAR_CACHE[TYPE.ARRAY_END])
				else
					local fV, is_homo, fVTI, fVRT, fVTo = value[1], true, nil, nil, nil
					fVRT = type(fV); fVTo = typeof(fV); local tidfc = HOMOGENEOUS_TYPE_MAP[fVTo]
					if count > 1 and tidfc then
						fVTI = tidfc; local isFBool = fVTo=="boolean"
						for i = 2, count do local cV = value[i]; local cVTo = typeof(cV); if cVTo ~= fVTo and not (isFBool and cVTo == "boolean") then is_homo = false; break end; if fVRT == "number" and type(cV) ~= "number" then is_homo = false; break end end
					else is_homo = false end

					if is_homo and fVTI then -- Homo Array
						table_insert(buffer, CHAR_CACHE[TYPE.ARRAY_HOMOGENEOUS]); local ttw = (fVTI==TYPE.BOOLEAN_TRUE or fVTI==TYPE.BOOLEAN_FALSE) and TYPE.BOOLEAN_FALSE or fVTI
						table_insert(buffer, CHAR_CACHE[ttw]); table_insert(buffer, CHAR_CACHE[TYPE.VALUE_TYPE_ID]); encodeValue(count, refs_encoding, buffer, currentDepth + 1)
						if ttw == TYPE.NUMBER_FLOAT32 then for i=1,count do local n=value[i]; if n==0 then table_insert(buffer,CHAR_CACHE[TYPE.NUMBER_ZERO]) else table_insert(buffer,string_pack("<f",n)) end end
						elseif ttw == TYPE.BOOLEAN_FALSE then for i=1,count do table_insert(buffer,CHAR_CACHE[value[i] and TYPE.BOOLEAN_TRUE or TYPE.BOOLEAN_FALSE]) end
						elseif ttw == TYPE.STRING_SHORT then for i=1, count do encodeValue(value[i], refs_encoding, buffer, currentDepth + 1) end
						else for i=1, count do encodeValue(value[i], refs_encoding, buffer, currentDepth + 1) end end
					else -- Regular Array
						table_insert(buffer, CHAR_CACHE[TYPE.ARRAY_START]); for i=1, count do encodeValue(value[i], refs_encoding, buffer, currentDepth + 1) end; table_insert(buffer, CHAR_CACHE[TYPE.ARRAY_END])
					end
				end
			else -- Dictionary
				table_insert(buffer, CHAR_CACHE[TYPE.TABLE_START])
				for k, v in pairs(value) do local kt=type(k); if kt=="string" or kt=="number" then encodeValue(k, refs_encoding, buffer, currentDepth+1); encodeValue(v, refs_encoding, buffer, currentDepth+1) else warn("[BE Enc] Skip table key:", kt, k) end end
				table_insert(buffer, CHAR_CACHE[TYPE.TABLE_END])
			end
		end
		-- Roblox Types (Standardized pack formats)
	elseif valueType == "Vector3" then table_insert(buffer,CHAR_CACHE[TYPE.VECTOR3]); table_insert(buffer, string_pack("<ddd", value.X, value.Y, value.Z)) -- FIX: <ddd
	elseif valueType == "Vector2" then table_insert(buffer,CHAR_CACHE[TYPE.VECTOR2]); table_insert(buffer, string_pack("<dd", value.X, value.Y))             -- FIX: <dd
	elseif valueType == "Color3" then table_insert(buffer,CHAR_CACHE[TYPE.COLOR3]); table_insert(buffer, string_pack("<ddd", value.R, value.G, value.B))   -- FIX: <ddd
	elseif valueType == "UDim2" then table_insert(buffer,CHAR_CACHE[TYPE.UDIM2]); table_insert(buffer, string_pack("<dddd", value.X.Scale, value.X.Offset, value.Y.Scale, value.Y.Offset)) -- FIX: <dddd
	elseif valueType == "Rect" then table_insert(buffer,CHAR_CACHE[TYPE.RECT]); table_insert(buffer, string_pack("<dddd", value.Min.X, value.Min.Y, value.Max.X, value.Max.Y))       -- FIX: <dddd
	elseif valueType == "CFrame" then table_insert(buffer,CHAR_CACHE[TYPE.CFRAME]); table_insert(buffer, string_pack("<dddddddddddd", value:GetComponents())) -- FIX: <d * 12
	elseif valueType == "EnumItem" then table_insert(buffer,CHAR_CACHE[TYPE.ENUM]); encodeValue(tostring(value.EnumType), refs_encoding, buffer, currentDepth+1); encodeValue(tostring(value.Name), refs_encoding, buffer, currentDepth+1)
	elseif valueType == "Instance" then
		-- Use the robust path function (Unchanged)
		local path = getInstancePath(value)
		if path then
			if path == "" then
				warn("[BE Enc] Instance path resulted in empty string for:", value)
				table_insert(buffer, CHAR_CACHE[TYPE.NIL])
			else
				table_insert(buffer, CHAR_CACHE[TYPE.INSTANCE_REF])
				encodeValue(path, refs_encoding, buffer, currentDepth + 1)
			end
		else
			-- getInstancePath already warned if it couldn't generate a path
			table_insert(buffer, CHAR_CACHE[TYPE.NIL]) -- Encode as nil if path generation failed
		end
	elseif valueType == "DateTime" then table_insert(buffer,CHAR_CACHE[TYPE.DATETIME]); table_insert(buffer, string_pack("<q", value.UnixTimestampMillis))
	elseif valueType == "BrickColor" then table_insert(buffer,CHAR_CACHE[TYPE.BRICKCOLOR]); encodeValue(value.Number, refs_encoding, buffer, currentDepth+1)
	elseif valueType == "NumberSequence" then table_insert(buffer,CHAR_CACHE[TYPE.NUMBERSEQUENCE]); local kp=value.Keypoints; encodeValue(#kp, refs_encoding, buffer, currentDepth+1); for _,k in ipairs(kp) do table_insert(buffer, string_pack("<ddd", k.Time, k.Value, k.Envelope)) end -- Kept <ddd
	elseif valueType == "ColorSequence" then table_insert(buffer,CHAR_CACHE[TYPE.COLORSEQUENCE]); local kp=value.Keypoints; encodeValue(#kp, refs_encoding, buffer, currentDepth+1); for _,k in ipairs(kp) do table_insert(buffer, string_pack("<dddd", k.Time, k.Value.R, k.Value.G, k.Value.B)) end -- Kept <dddd
	elseif valueType == "buffer" then table_insert(buffer, CHAR_CACHE[TYPE.BUFFER]); local l=buffer_len(value); local lb=writeLength(l); table_insert(buffer,lb); table_insert(buffer, buffer_tostring(value))
	else warn("[BE Enc] Unsupported:", valueType, value); table_insert(buffer, CHAR_CACHE[TYPE.NIL])
	end
end


--[[--- Internal Decoding Logic ---]]
local function decodeValue(data: string, indexRef: {number}, refs_decoding: {}, currentDepth: number)

	if currentDepth > MAX_DEPTH then return decodingError("Max depth", indexRef[1]) end
	local index = indexRef[1]; if index > #data then return decodingError("EOF start", index) end
	local typeId = string_byte(data, index); if not typeId then return decodingError("EOF TypeID", index) end
	index += 1; indexRef[1] = index

	if typeId == TYPE.NIL then return nil
	elseif typeId == TYPE.BOOLEAN_FALSE then return false
	elseif typeId == TYPE.BOOLEAN_TRUE then return true
	elseif typeId == TYPE.NUMBER_ZERO then return 0
	elseif typeId == TYPE.STRING_EMPTY then return ""
	elseif typeId == TYPE.NUMBER_INT8 then if index>#data then return decodingError("EOF I8",index) end; local v,idx=string_unpack("<i1",data,index); if not idx then return decodingError("Unpk I8",index) end; indexRef[1]=idx; return v
	elseif typeId == TYPE.NUMBER_INT16 then if index+1>#data then return decodingError("EOF I16",index) end; local v,idx=string_unpack("<i2",data,index); if not idx then return decodingError("Unpk I16",index) end; indexRef[1]=idx; return v
	elseif typeId == TYPE.NUMBER_INT32 then if index+3>#data then return decodingError("EOF I32",index) end; local v,idx=string_unpack("<i4",data,index); if not idx then return decodingError("Unpk I32",index) end; indexRef[1]=idx; return v
	elseif typeId == TYPE.NUMBER_FLOAT32 then if index+3>#data then return decodingError("EOF F32",index) end; local v,idx=string_unpack("<f",data,index); if not idx then return decodingError("Unpk F32",index) end; indexRef[1]=idx; return v
	elseif typeId == TYPE.STRING_SHORT or typeId == TYPE.STRING_LONG then local l,il=readLength(data,indexRef[1]); if not l then return nil end; local eos=il+l; if eos>#data+1 then return decodingError("Str OOB "..l,il) end; local s=string_sub(data,il,eos-1); indexRef[1]=eos; return s
	elseif typeId == TYPE.REFERENCE then local rid=decodeValue(data,indexRef,refs_decoding,currentDepth+1); if type(rid)~="number" then return decodingError("RefID type "..type(rid), indexRef[1]) end; local v=refs_decoding[rid]; if v==nil then return decodingError("RefID inv "..rid, indexRef[1]) end; return v
	elseif typeId == TYPE.TABLE_START then local tbl={}; local id=#refs_decoding+1; refs_decoding[id]=tbl; while true do if indexRef[1]>#data then return decodingError("EOF TBL", indexRef[1]) end; local p=string_byte(data,indexRef[1]); if not p then return decodingError("Peek TBL", indexRef[1]) end; if p==TYPE.TABLE_END then indexRef[1]+=1; break end; local k=decodeValue(data,indexRef,refs_decoding,currentDepth+1); if indexRef[1]>#data and string_byte(data, indexRef[1])~=TYPE.TABLE_END then return decodingError("EOF TBL Key", indexRef[1]) end; local v=decodeValue(data,indexRef,refs_decoding,currentDepth+1); tbl[k]=v end; return tbl
	elseif typeId == TYPE.ARRAY_START then local arr={}; local id=#refs_decoding+1; refs_decoding[id]=arr; local i=1; while true do if indexRef[1]>#data then return decodingError("EOF ARR", indexRef[1]) end; local p=string_byte(data,indexRef[1]); if not p then return decodingError("Peek ARR", indexRef[1]) end; if p==TYPE.ARRAY_END then indexRef[1]+=1; break end; arr[i]=decodeValue(data,indexRef,refs_decoding,currentDepth+1); i+=1 end; return arr
	elseif typeId == TYPE.ARRAY_HOMOGENEOUS then local arr={}; local id=#refs_decoding+1; refs_decoding[id]=arr; index=indexRef[1]; if index+1>#data then return decodingError("EOF HomoHdr",index) end; local vtid=string_byte(data,index); index+=1; local sep=string_byte(data,index); index+=1; indexRef[1]=index; if sep~=TYPE.VALUE_TYPE_ID then return decodingError("Homo Sep "..sep,index-1) end; local cnt=decodeValue(data,indexRef,refs_decoding,currentDepth+1); if type(cnt)~="number" or cnt<0 or cnt~=math_floor(cnt) then return decodingError("Homo Cnt "..tostring(cnt), indexRef[1]) end
		if cnt > 0 then index=indexRef[1]; local isBool=vtid==TYPE.BOOLEAN_FALSE or vtid==TYPE.BOOLEAN_TRUE; local evtid=isBool and TYPE.BOOLEAN_FALSE or vtid;
			if evtid == TYPE.NUMBER_FLOAT32 then for i=1,cnt do if index>#data then return decodingError(("HomoNum EOF %d/%d"):format(i,cnt),index) end; local p=string_byte(data,index); if p==TYPE.NUMBER_ZERO then arr[i]=0; index+=1 else if index+3>#data then return decodingError(("HomoFlt EOF %d/%d"):format(i,cnt),index) end; local v,ni=string_unpack("<f",data,index); if not ni then return decodingError(("HomoFlt Unpk %d/%d"):format(i,cnt),index) end; arr[i]=v; index=ni end end
			elseif isBool then if index+cnt>#data+1 then return decodingError(("HomoBool EOF %d/%d"):format(cnt,cnt),index) end; for i=1,cnt do local b=string_byte(data,index); arr[i]=(b==TYPE.BOOLEAN_TRUE); index+=1 end
			elseif evtid == TYPE.STRING_SHORT then for i=1,cnt do indexRef[1]=index; local s=decodeValue(data,indexRef,refs_decoding,currentDepth+1); if type(s)~="string" then return decodingError(("HomoStr Type %d/%d got %s"):format(i,cnt,type(s)),index) end; arr[i]=s; index=indexRef[1] end
			else for i=1, cnt do indexRef[1]=index; arr[i]=decodeValue(data,indexRef,refs_decoding,currentDepth+1); index=indexRef[1] end
			end; indexRef[1]=index
		end; return arr
		-- Roblox Types (Standardized unpack formats)
	elseif typeId == TYPE.VECTOR3 then if indexRef[1]+23>#data then return decodingError("EOF VEC3",indexRef[1]) end; local x,y,z,idx=string_unpack("<ddd",data,indexRef[1]); if not idx then return decodingError("Unpk VEC3",indexRef[1]) end; indexRef[1]=idx; return Vector3_new(x,y,z) -- FIX: <ddd
	elseif typeId == TYPE.VECTOR2 then if indexRef[1]+15>#data then return decodingError("EOF VEC2",indexRef[1]) end; local x,y,idx=string_unpack("<dd",data,indexRef[1]); if not idx then return decodingError("Unpk VEC2",indexRef[1]) end; indexRef[1]=idx; return Vector2_new(x,y)     -- FIX: <dd
	elseif typeId == TYPE.COLOR3 then if indexRef[1]+23>#data then return decodingError("EOF COL3",indexRef[1]) end; local r,g,b,idx=string_unpack("<ddd",data,indexRef[1]); if not idx then return decodingError("Unpk COL3",indexRef[1]) end; indexRef[1]=idx; return Color3_new(r,g,b)    -- FIX: <ddd
	elseif typeId == TYPE.UDIM2 then if indexRef[1]+31>#data then return decodingError("EOF UDIM2",indexRef[1]) end; local xs,xo,ys,yo,idx=string_unpack("<dddd",data,indexRef[1]); if not idx then return decodingError("Unpk UDIM2",indexRef[1]) end; indexRef[1]=idx; return UDim2_new(xs,xo,ys,yo) -- FIX: <dddd
	elseif typeId == TYPE.RECT then if indexRef[1]+31>#data then return decodingError("EOF RECT",indexRef[1]) end; local nx,ny,xx,xy,idx=string_unpack("<dddd",data,indexRef[1]); if not idx then return decodingError("Unpk RECT",indexRef[1]) end; indexRef[1]=idx; return Rect_new(Vector2_new(nx,ny),Vector2_new(xx,xy)) -- FIX: <dddd
	elseif typeId == TYPE.CFRAME then if indexRef[1]+95>#data then return decodingError("EOF CFRAME",indexRef[1]) end; local c={string_unpack("<dddddddddddd",data,indexRef[1])}; local idx=table.remove(c); if not idx then return decodingError("Unpk CFRAME",indexRef[1]) end; indexRef[1]=idx; return CFrame_new(table.unpack(c,1,12)) -- FIX: <d * 12
	elseif typeId == TYPE.ENUM then local etn=decodeValue(data,indexRef,refs_decoding,currentDepth+1); local evn=decodeValue(data,indexRef,refs_decoding,currentDepth+1); if type(etn)~="string" or type(evn)~="string" then return decodingError("Enum str",indexRef[1]) end; local ok,ei=pcall(function()return Enum_Type[etn][evn]end); if ok and ei then return ei else warn("[BE Dec] Enum fail:",etn,evn); return nil end
	elseif typeId == TYPE.INSTANCE_REF then
		local path = decodeValue(data, indexRef, refs_decoding, currentDepth + 1)
		if type(path) ~= "string" then
			return decodingError("Instance reference path must be a string, got " .. type(path), indexRef[1])
		end
		if path == "" then
			warn("[BE Dec] Decoded empty instance path.")
			return nil -- Treat empty path as nil
		end
		
		local instance = GetInstanceAtPath(path)

		if instance then
			-- Found the instance successfully
			return instance
		else
			-- Instance not found (FindFirstChild returned nil)
			warn(("[BE Dec] Instance not found via path %q. (Possible reasons: Not replicated yet, FilteringEnabled issue, destroyed, invalid path)."):format(path))
			return nil -- Return nil as the instance couldn't be resolved
		end
	elseif typeId == TYPE.DATETIME then if indexRef[1]+7>#data then return decodingError("EOF DT",indexRef[1]) end; local ms,idx=string_unpack("<q",data,indexRef[1]); if not idx then return decodingError("Unpk DT",indexRef[1]) end; indexRef[1]=idx; local ok,dt=pcall(DateTime_FromMillis,ms); if ok then return dt else warn("[BE Dec] DT fail:",ms); return nil end
	elseif typeId == TYPE.BRICKCOLOR then local num=decodeValue(data,indexRef,refs_decoding,currentDepth+1); if type(num)~="number" then return decodingError("BC num",indexRef[1]) end; local ok,bc=pcall(BrickColor_new,num); if ok then return bc else warn("[BE Dec] BC fail:",num); return nil end
	elseif typeId == TYPE.NUMBERSEQUENCE then local nk=decodeValue(data,indexRef,refs_decoding,currentDepth+1); if type(nk)~="number" or nk<0 or nk>20 then warn("[BE Dec] NS cnt clamp:",nk); nk=math.max(0,math.min(20,nk)) elseif nk~=math.floor(nk) then return decodingError("NS cnt int",indexRef[1]) end; local kps={}; local idx=indexRef[1]; local bn=nk*24; if idx+bn>#data+1 then return decodingError(("NS EOF %d need %d"):format(nk,bn),idx) end
		for i=1,nk do local t,v,e,ni=string_unpack("<ddd",data,idx); if not ni then return decodingError(("NS Unpk %d/%d"):format(i,nk),idx) end; idx=ni; local ok,kp=pcall(NumberSequenceKeypoint_new,t,v,e); if ok then kps[i]=kp else warn("[BE Dec] NS Key fail:",t,v,e) end end; indexRef[1]=idx; local ok,ns=pcall(NumberSequence_new,kps); if ok then return ns else warn("[BE Dec] NS New fail"); return nil end -- Kept <ddd
	elseif typeId == TYPE.COLORSEQUENCE then local nk=decodeValue(data,indexRef,refs_decoding,currentDepth+1); if type(nk)~="number" or nk<0 or nk>20 then warn("[BE Dec] CS cnt clamp:",nk); nk=math.max(0,math.min(20,nk)) elseif nk~=math.floor(nk) then return decodingError("CS cnt int",indexRef[1]) end; local kps={}; local idx=indexRef[1]; local bn=nk*32; if idx+bn>#data+1 then return decodingError(("CS EOF %d need %d"):format(nk,bn),idx) end
		for i=1,nk do local t,r,g,b,ni=string_unpack("<dddd",data,idx); if not ni then return decodingError(("CS Unpk %d/%d"):format(i,nk),idx) end; idx=ni; local co,cv=pcall(Color3_new,r,g,b); if co then local ok,kp=pcall(ColorSequenceKeypoint_new,t,cv); if ok then kps[i]=kp else warn("[BE Dec] CS Key fail:",t,cv) end else warn("[BE Dec] CS Col3 fail:",r,g,b) end end; indexRef[1]=idx; local ok,cs=pcall(ColorSequence_new,kps); if ok then return cs else warn("[BE Dec] CS New fail"); return nil end -- Kept <dddd
	elseif typeId == TYPE.BUFFER then local l,il=readLength(data,indexRef[1]); if not l then return nil end; local eob=il+l; if eob>#data+1 then return decodingError("Buf OOB "..l,il) end; local bd=string_sub(data,il,eob-1); indexRef[1]=eob; local ok,buf=pcall(buffer_fromstring,bd); if ok then return buf else warn("[BE Dec] Buf fail"); return nil end
	else return decodingError("Unknown TypeID: " .. typeId, indexRef[1] - 1)
	end
end


--[[--- Public Interface ---]]
function BinaryEncoder.encode(value: any): (string?) 
	local buffer = {}
	local refs_encoding = {}
	local ok, err = pcall(encodeValue, value, refs_encoding, buffer, 0)
	if not ok then
		-- Rethrow the error, ensuring it's captured by any outer pcall (like the one around LZ4)
		error("[BinaryEncoder.encode error] " .. tostring(err), 0) -- Use level 0 to preserve stack trace from encodeValue
		-- return nil -- Alternative: return nil instead of erroring
	end
	return table_concat(buffer)
end

function BinaryEncoder.decode(data: string): any
	if type(data) ~= "string" then error("BE decode requires string, got "..type(data), 2) end
	if #data == 0 then error("BE decode requires non-empty string", 2) end
	local refs_decoding = {}
	local indexRef = {1}
	-- Wrap decodeValue in pcall to catch internal errors more gracefully if needed,
	-- though decodeValue already uses decodingError which halts execution.
	local result = decodeValue(data, indexRef, refs_decoding, 0)
	if indexRef[1] <= #data then
		warn(("[BE Dec Warning] Extra %d bytes left. End: %d, Total: %d"):format(#data - indexRef[1] + 1, indexRef[1], #data))
	end
	return result
end

return BinaryEncoder