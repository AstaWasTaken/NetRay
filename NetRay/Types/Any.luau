--!strict

-- Requires
local Cursor = require(script.Parent.Cursor)


-- Varables
local read = {}			:: {[number]: (cursor: Cursor.Cursor) -> any}
local write = {}		:: {[string]: (cursor: Cursor.Cursor, value:any) -> ()}


-- Nil
read[0] = function(cursor: any)
	return nil
end

write["nil"] = function(cursor: any, value: nil)
	cursor:Allocate(1)
	buffer.writeu8(cursor.Buffer, cursor.Index, 0)
	cursor.Index += 1
end


-- Number
read[1] = function(cursor) return -cursor:ReadU1() end
read[2] = function(cursor) return -cursor:ReadU2() end
read[3] = function(cursor) return -cursor:ReadU3() end
read[4] = function(cursor) return -cursor:ReadU4() end
read[5] = function(cursor) return cursor:ReadU1() end
read[6] = function(cursor) return cursor:ReadU2() end
read[7] = function(cursor) return cursor:ReadU3() end
read[8] = function(cursor) return cursor:ReadU4() end
read[9] = function(cursor) return cursor:ReadF4() end

write.number = function(cursor, value: number)
	if value % 1 == 0 then
		if value < 0 then
			if value > -256 then
				cursor:Allocate(2) cursor:WriteU1(1) cursor:WriteU1(-value)
			elseif value > -65536 then
				cursor:Allocate(3) cursor:WriteU1(2) cursor:WriteU2(-value)
			elseif value > -16777216 then
				cursor:Allocate(4) cursor:WriteU1(3) cursor:WriteU3(-value)
			else
				cursor:Allocate(5) cursor:WriteU1(4) cursor:WriteU4(-value)
			end
		else
			if value < 256 then
				cursor:Allocate(2) cursor:WriteU1(5) cursor:WriteU1(value)
			elseif value < 65536 then
				cursor:Allocate(3) cursor:WriteU1(6) cursor:WriteU2(value)
			elseif value < 16777216 then
				cursor:Allocate(4) cursor:WriteU1(7) cursor:WriteU3(value)
			else
				cursor:Allocate(5) cursor:WriteU1(8) cursor:WriteU4(value)
			end
		end
	else
		cursor:Allocate(5) cursor:WriteU1(9) cursor:WriteF4(value)
	end
end


-- Boolean
read[10] = function(cursor)
	return cursor:ReadU1() == 1
end

write.boolean = function(cursor, value: boolean)
	cursor:Allocate(2)
	cursor:WriteU1(10)
	cursor:WriteU1(if value then 1 else 0)
end


-- String
read[11] = function(cursor)
	return cursor:ReadString(cursor:ReadU1())
end

write.string = function(cursor, value: string)
	cursor:Allocate(2 + #value)
	cursor:WriteU1(11)
	cursor:WriteU1(#value)
	cursor:WriteString(value)
end


-- Buffer
read[12] = function(cursor)
	return cursor:ReadBuffer(cursor:ReadU1())
end

write.buffer = function(cursor, value: buffer)
	local length = buffer.len(value)
	cursor:Allocate(2 + length)
	cursor:WriteU1(12)
	cursor:WriteU1(length)
	cursor:WriteBuffer(value)
end


-- Vector2
read[13] = function(cursor)
	return Vector2.new(cursor:ReadF4(), cursor:ReadF4())
end

write.Vector2 = function(cursor, value: Vector2)
	cursor:Allocate(9)
	cursor:WriteU1(13)
	cursor:WriteF4(value.X)
	cursor:WriteF4(value.Y)
end


-- Vector3
read[14] = function(cursor)
	return Vector3.new(cursor:ReadF4(), cursor:ReadF4(), cursor:ReadF4())
end

write.Vector3 = function(cursor, value: Vector3)
	cursor:Allocate(13)
	cursor:WriteU1(14)
	cursor:WriteF4(value.X)
	cursor:WriteF4(value.Y)
	cursor:WriteF4(value.Z)
end


-- CFrame
read[15] = function(cursor)
	return CFrame.fromEulerAnglesXYZ(
		cursor:ReadU2() / 10430.219195527361,
		cursor:ReadU2() / 10430.219195527361,
		cursor:ReadU2() / 10430.219195527361
	) + Vector3.new(
		cursor:ReadF4(),
		cursor:ReadF4(),
		cursor:ReadF4()
	)
end

write.CFrame = function(cursor, value: CFrame)
	cursor:Allocate(19)
	cursor:WriteU1(15)
	local rx, ry, rz = value:ToEulerAnglesXYZ()
	cursor:WriteU2(rx * 10430.219195527361 + 0.5)
	cursor:WriteU2(ry * 10430.219195527361 + 0.5)
	cursor:WriteU2(rz * 10430.219195527361 + 0.5)
	cursor:WriteF4(value.X)
	cursor:WriteF4(value.Y)
	cursor:WriteF4(value.Z)
end


-- NumberRange
read[16] = function(cursor)
	return NumberRange.new(cursor:ReadF4(), cursor:ReadF4())
end

write.NumberRange = function(cursor, value: NumberRange)
	cursor:Allocate(9)
	cursor:WriteU1(16)
	cursor:WriteF4(value.Min)
	cursor:WriteF4(value.Max)
end


-- NumberSequence
read[17] = function(cursor)
	local length = cursor:ReadU1()
	local keypoints = table.create(length)
	for index = 1, cursor:ReadU1() do
		table.insert(keypoints, NumberSequenceKeypoint.new(
			cursor:ReadU1() / 255,
			cursor:ReadU1() / 255,
			cursor:ReadU1() / 255
			))
	end
	return NumberSequence.new(keypoints)
end

write.NumberSequence = function(cursor, value: NumberSequence)
	local length = #value.Keypoints
	cursor:Allocate(2 + length * 3)
	cursor:WriteU1(17)
	cursor:WriteU1(length)
	for index, keypoint in value.Keypoints do
		cursor:WriteU1(keypoint.Time * 255 + 0.5)
		cursor:WriteU1(keypoint.Value * 255 + 0.5)
		cursor:WriteU1(keypoint.Envelope * 255 + 0.5)
	end
end


-- Color3
read[18] = function(cursor)
	return Color3.fromRGB(cursor:ReadU1(), cursor:ReadU1(), cursor:ReadU1())
end

write.Color3 = function(cursor, value: Color3)
	cursor:Allocate(4)
	cursor:WriteU1(18)
	cursor:WriteU1(value.R * 255 + 0.5)
	cursor:WriteU1(value.G * 255 + 0.5)
	cursor:WriteU1(value.B * 255 + 0.5)
end


-- ColorSequence
read[19] = function(cursor)
	local length = cursor:ReadU1()
	local keypoints = table.create(length)
	for index = 1, cursor:ReadU1() do
		table.insert(keypoints, ColorSequenceKeypoint.new(
			cursor:ReadU1() / 255,
			Color3.fromRGB(cursor:ReadU1(), cursor:ReadU1(), cursor:ReadU1())
			))
	end
	return ColorSequence.new(keypoints)
end

write.ColorSequence = function(cursor, value: ColorSequence)
	local length = #value.Keypoints
	cursor:Allocate(2 + length * 4)
	cursor:WriteU1(19)
	cursor:WriteU1(length)
	for index, keypoint in value.Keypoints do
		cursor:WriteU1(keypoint.Time * 255 + 0.5)
		cursor:WriteU1(keypoint.Value.R * 255 + 0.5)
		cursor:WriteU1(keypoint.Value.G * 255 + 0.5)
		cursor:WriteU1(keypoint.Value.B * 255 + 0.5)
	end
end


-- BrickColor
read[20] = function(cursor)
	return BrickColor.new(cursor:ReadU2())
end

write.BrickColor = function(cursor, value: BrickColor)
	cursor:Allocate(3)
	cursor:WriteU1(20)
	cursor:WriteU2(value.Number)
end


-- UDim
read[21] = function(cursor)
	return UDim.new(cursor:ReadS2() / 1000, cursor:ReadS2())
end

write.UDim = function(cursor, value: UDim)
	cursor:Allocate(5)
	cursor:WriteU1(21)
	cursor:WriteS2(value.Scale * 1000 + 0.5)
	cursor:WriteS2(value.Offset)
end


-- UDim2
read[22] = function(cursor)
	return UDim2.new(cursor:ReadS2() / 1000, cursor:ReadS2(), cursor:ReadS2() / 1000, cursor:ReadS2())
end

write.UDim2 = function(cursor, value: UDim2)
	cursor:Allocate(9)
	cursor:WriteU1(22)
	cursor:WriteS2(value.X.Scale * 1000 + 0.5)
	cursor:WriteS2(value.X.Offset)
	cursor:WriteS2(value.Y.Scale * 1000 + 0.5)
	cursor:WriteS2(value.Y.Offset)
end


-- Rect
read[23] = function(cursor)
	return Rect.new(cursor:ReadF4(), cursor:ReadF4(), cursor:ReadF4(), cursor:ReadF4())
end

write.Rect = function(cursor, value: Rect)
	cursor:Allocate(17)
	cursor:WriteU1(23)
	cursor:WriteF4(value.Min.X)
	cursor:WriteF4(value.Min.Y)
	cursor:WriteF4(value.Max.X)
	cursor:WriteF4(value.Max.Y)
end


-- Region3
read[24] = function(cursor)
	return Region3.new(
		Vector3.new(cursor:ReadF4(), cursor:ReadF4(), cursor:ReadF4()),
		Vector3.new(cursor:ReadF4(), cursor:ReadF4(), cursor:ReadF4())
	)
end

write.Region3 = function(cursor, value: Region3)
	cursor:Allocate(25)
	cursor:WriteU1(24)
	local halfSize = value.Size / 2
	local minimum = value.CFrame.Position - halfSize
	local maximum = value.CFrame.Position + halfSize
	cursor:WriteF4(minimum.X)
	cursor:WriteF4(minimum.Y)
	cursor:WriteF4(minimum.Z)
	cursor:WriteF4(maximum.X)
	cursor:WriteF4(maximum.Y)
	cursor:WriteF4(maximum.Z)
end


-- Instance
read[25] = function(cursor)
	return cursor:ReadInstance()
end

write.Instance = function(cursor, value: Instance)
	cursor:Allocate(1)
	cursor:WriteU1(25)
	cursor:WriteInstance(value)
end


-- Table
read[26] = function(cursor)
	-- Read table size
	local size = cursor:ReadU2()
	
	-- Pre-allocate result table for better performance with larger tables
	local result = table.create(size)
	
	-- Read each key-value pair
	for _ = 1, size do
		-- Read key type and value
		local keyType = cursor:ReadU1()
		local key
		
		-- Handle key based on its type
		if keyType == 0 then -- string key
			-- Inline the string reading for better performance
			local keyLength = cursor:ReadU2()
			key = cursor:ReadString(keyLength)
		elseif keyType == 1 then -- number key
			-- Read number keys directly with appropriate type handler
			key = read[cursor:ReadU1()](cursor)
		elseif keyType == 2 then -- boolean key
			-- Special case for boolean keys (more efficient)
			key = cursor:ReadU1() == 1
		else
			-- Unsupported key type, use a fallback
			key = "__unsupported_key_" .. tostring(keyType)
		end
		
		-- Read the value using the Any.Read function recursively
		local valueType = cursor:ReadU1()
		local value = read[valueType](cursor)
		
		-- Set the key-value pair
		result[key] = value
	end
	
	return result
end

write.table = function(cursor, value: {[any]: any})
	-- First pass: count entries and check if array-like
	local size = 0
	local numericKeys = 0
	local maxKey = 0
	
	for k, _ in pairs(value) do
		size += 1
		if type(k) == "number" and k == math.floor(k) and k > 0 then
			numericKeys += 1
			maxKey = math.max(maxKey, k)
		end
	end
	
	-- Check if this is actually an array (optimize for arrays)
	local isArray = numericKeys == size and numericKeys == maxKey
	
	-- Write table header
	cursor:Allocate(3) -- 1 byte for type, 2 bytes for size
	cursor:WriteU1(26) -- Table type identifier
	cursor:WriteU2(size) -- Number of entries
	
	-- For arrays, optimize serialization order (iterate in order)
	if isArray then
		for i = 1, size do
			-- Write key as number
			cursor:WriteU1(1) -- Number key type
			local k = i
			
			-- Choose the most efficient number encoding
			if k < 256 then
				cursor:WriteU1(5) -- Positive small number
				cursor:WriteU1(k)
			else
				cursor:WriteU1(6) -- Positive medium number
				cursor:WriteU2(k)
			end
			
			-- Write the value
			local v = value[i]
			local vType = typeof(v)
			
			-- Inline common value types for better performance
			if vType == "string" then
				local len = #v
				if len < 256 then
					cursor:WriteU1(11) -- String type
					cursor:WriteU1(len)
					cursor:WriteString(v)
				else
					-- Use standard string writer for longer strings
					write[vType](cursor, v)
				end
			elseif vType == "number" and v == math.floor(v) and v >= 0 and v < 256 then
				-- Optimize for small integers
				cursor:WriteU1(5) -- Type 5 (U8)
				cursor:WriteU1(v)
			else
				-- Fall back to standard handler for other types
				write[vType](cursor, v)
			end
		end
	else
		-- For non-array tables, use general approach
		for k, v in pairs(value) do
			local keyType = typeof(k)
			
			-- Handle key based on type
			if keyType == "string" then
				-- String key
				local keyLength = #k
				cursor:WriteU1(0) -- String key type
				cursor:WriteU2(keyLength)
				cursor:WriteString(k)
			elseif keyType == "number" then
				-- Number key with optimal encoding
				cursor:WriteU1(1) -- Number key type
				write.number(cursor, k)
			elseif keyType == "boolean" then
				-- Boolean key (added support)
				cursor:WriteU1(2) -- Boolean key type
				cursor:WriteU1(k and 1 or 0)
			else
				-- Unsupported key type, convert to string
				local stringKey = "__" .. keyType .. "_" .. tostring(k)
				cursor:WriteU1(0) -- String key type
				cursor:WriteU2(#stringKey)
				cursor:WriteString(stringKey)
			end
			
			-- Write the value
			write[typeof(v)](cursor, v)
		end
	end
end


return {

	Read = function(cursor: Cursor.Cursor)
		return read[cursor:ReadU1()](cursor)
	end,

	Write = function(cursor: Cursor.Cursor, value: any)
		write[typeof(value)](cursor, value)
	end,

}