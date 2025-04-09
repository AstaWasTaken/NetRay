--!strict
--!optimize 2
--!native


-- Types
export type Cursor = {
	Type:					"Cursor",
	Index:					number,
	InstanceIndex:			number,
	Length:					number,
	Buffer:					buffer,
	Instances:				{Instance},
	Allocate:				(self: Cursor, amount: number) -> (),
	Clear:					(self: Cursor) -> (),
	Truncate:				(self: Cursor) -> buffer,
	ReadS1:					(self: Cursor) -> number,
	WriteS1:				(self: Cursor, value: number) -> (),
	ReadS2:					(self: Cursor) -> number,
	WriteS2:				(self: Cursor, value: number) -> (),
	ReadS3:					(self: Cursor) -> number,
	WriteS3:				(self: Cursor, value: number) -> (),
	ReadS4:					(self: Cursor) -> number,
	WriteS4:				(self: Cursor, value: number) -> (),
	ReadU1:					(self: Cursor) -> number,
	WriteU1:				(self: Cursor, value: number) -> (),
	ReadU2:					(self: Cursor) -> number,
	WriteU2:				(self: Cursor, value: number) -> (),
	ReadU3:					(self: Cursor) -> number,
	WriteU3:				(self: Cursor, value: number) -> (),
	ReadU4:					(self: Cursor) -> number,
	WriteU4:				(self: Cursor, value: number) -> (),
	ReadF2:					(self: Cursor) -> number,
	WriteF2:				(self: Cursor, value: number) -> (),
	ReadF3:					(self: Cursor) -> number,
	WriteF3:				(self: Cursor, value: number) -> (),
	ReadF4:					(self: Cursor) -> number,
	WriteF4:				(self: Cursor, value: number) -> (),
	ReadF8:					(self: Cursor) -> number,
	WriteF8:				(self: Cursor, value: number) -> (),
	ReadString:				(self: Cursor, length: number) -> string,
	WriteString:			(self: Cursor, value: string) -> (),
	ReadBuffer:				(self: Cursor, length: number) -> buffer,
	WriteBuffer:			(self: Cursor, value: buffer) -> (),
	ReadInstance:			(self: Cursor) -> Instance,
	WriteInstance:			(self: Cursor, value: Instance) -> (),
}


-- Varables
local Cursor = {}			:: Cursor
Cursor["__index"] = Cursor
Cursor.Type = "Cursor"


-- Constructor
local function Constructor(initialBuffer: buffer?, instances: {Instance}?)
	local cursor = (setmetatable({}, Cursor) :: any) :: Cursor
	cursor.Index = 0
	cursor.InstanceIndex = 0
	cursor.Buffer = initialBuffer or buffer.create(1024)
	cursor.Length = buffer.len(cursor.Buffer)
	cursor.Instances = instances or {}
	return cursor
end


-- Cursor
function Cursor:Allocate(amount)
	local length = self.Index + amount
	if length <= self.Length then return end
	while self.Length < length do self.Length *= 1.5 end
	local newBuffer = buffer.create(self.Length)
	buffer.copy(newBuffer, 0, self.Buffer, 0, self.Index)
	self.Buffer = newBuffer
end

function Cursor:Clear()
	--buffer.fill(self.Buffer, 0, 0, self.Index)
	self.Index = 0
	self.InstanceIndex = 0
	table.clear(self.Instances)
end

function Cursor:Truncate()
	local truncatedBuffer = buffer.create(self.Index)
	buffer.copy(truncatedBuffer, 0, self.Buffer, 0, self.Index)
	return truncatedBuffer
end


-- Signed Integers
function Cursor:ReadS1()
	local value = buffer.readi8(self.Buffer, self.Index)
	self.Index += 1
	return value
end

function Cursor:WriteS1(value)
	local bytesToWrite = 1
	self:Allocate(bytesToWrite)
	buffer.writei8(self.Buffer, self.Index, value)
	self.Index += bytesToWrite
end

function Cursor:ReadS2()
	local value = buffer.readi16(self.Buffer, self.Index)
	self.Index += 2
	return value
end

function Cursor:WriteS2(value)
	local bytesToWrite = 2
	self:Allocate(bytesToWrite)
	buffer.writei16(self.Buffer, self.Index, value)
	self.Index += bytesToWrite
end

function Cursor:ReadS3()
	local value = buffer.readbits(self.Buffer, self.Index * 8, 24) - 8388608
	self.Index += 3
	return value
end

function Cursor:WriteS3(value)
	local bytesToWrite = 3
	self:Allocate(bytesToWrite)
	buffer.writebits(self.Buffer, self.Index * 8, 24, value + 8388608)
	self.Index += bytesToWrite
end

function Cursor:ReadS4()
	local value = buffer.readi32(self.Buffer, self.Index)
	self.Index += 4
	return value
end

function Cursor:WriteS4(value)
	local bytesToWrite = 4
	self:Allocate(bytesToWrite)
	buffer.writei32(self.Buffer, self.Index, value)
	self.Index += bytesToWrite
end


-- Unsigned Integers
function Cursor:ReadU1()
	local value = buffer.readu8(self.Buffer, self.Index)
	self.Index += 1
	return value
end

function Cursor:WriteU1(value)
	local bytesToWrite = 1
	self:Allocate(bytesToWrite)
	buffer.writeu8(self.Buffer, self.Index, value)
	self.Index += bytesToWrite
end

function Cursor:ReadU2()
	local value = buffer.readu16(self.Buffer, self.Index)
	self.Index += 2
	return value
end

function Cursor:WriteU2(value)
	local bytesToWrite = 2
	self:Allocate(bytesToWrite)
	buffer.writeu16(self.Buffer, self.Index, value)
	self.Index += bytesToWrite
end

function Cursor:ReadU3()
	local value = buffer.readbits(self.Buffer, self.Index * 8, 24)
	self.Index += 3
	return value
end

function Cursor:WriteU3(value)
	local bytesToWrite = 3
	self:Allocate(bytesToWrite)
	buffer.writebits(self.Buffer, self.Index * 8, 24, value)
	self.Index += bytesToWrite
end

function Cursor:ReadU4()
	local value = buffer.readu32(self.Buffer, self.Index)
	self.Index += 4
	return value
end

function Cursor:WriteU4(value)
	local bytesToWrite = 4
	self:Allocate(bytesToWrite)
	buffer.writeu32(self.Buffer, self.Index, value)
	self.Index += bytesToWrite
end


-- Floating Point Numbers
function Cursor:ReadF2()
	local offset = self.Index * 8
	local mantissa = buffer.readbits(self.Buffer, offset + 0, 10)
	local exponent = buffer.readbits(self.Buffer, offset + 10, 5)
	local sign = buffer.readbits(self.Buffer, offset + 15, 1)
	self.Index += 2
	if mantissa == 0b0000000000 then
		if exponent == 0b00000 then return 0 end
		if exponent == 0b11111 then return if sign == 0 then math.huge else -math.huge end
	elseif exponent == 0b11111 then return 0/0 end
	if sign == 0 then
		return (mantissa / 1024 + 1) * 2 ^ (exponent - 15)
	else
		return -(mantissa / 1024 + 1) * 2 ^ (exponent - 15)
	end
end

function Cursor:WriteF2(value)
	local bytesToWrite = 2
	self:Allocate(bytesToWrite)
	local offset = self.Index * 8
	if value == 0 then
		buffer.writebits(self.Buffer, offset, 16, 0b0_00000_0000000000)
	elseif value >= 65520 then
		buffer.writebits(self.Buffer, offset, 16, 0b0_11111_0000000000)
	elseif value <= -65520 then
		buffer.writebits(self.Buffer, offset, 16, 0b1_11111_0000000000)
	elseif value ~= value then
		buffer.writebits(self.Buffer, offset, 16, 0b0_11111_0000000001)
	else
		local sign = 0
		if value < 0 then sign = 1 value = -value end
		local mantissa, exponent = math.frexp(value)
		buffer.writebits(self.Buffer, offset + 0, 10, mantissa * 2048 - 1023.5)
		buffer.writebits(self.Buffer, offset + 10, 5, exponent + 14)
		buffer.writebits(self.Buffer, offset + 15, 1, sign)
	end
	self.Index += bytesToWrite
end

function Cursor:ReadF3()
	local offset = self.Index * 8
	local mantissa = buffer.readbits(self.Buffer, offset + 0, 17)
	local exponent = buffer.readbits(self.Buffer, offset + 17, 6)
	local sign = buffer.readbits(self.Buffer, offset + 23, 1)
	self.Index += 3
	if mantissa == 0b00000000000000000 then
		if exponent == 0b000000 then return 0 end
		if exponent == 0b111111 then return if sign == 0 then math.huge else -math.huge end
	elseif exponent == 0b111111 then return 0/0 end
	if sign == 0 then
		return (mantissa / 131072 + 1) * 2 ^ (exponent - 31)
	else
		return -(mantissa / 131072 + 1) * 2 ^ (exponent - 31)
	end
end

function Cursor:WriteF3(value)
	local bytesToWrite = 3
	self:Allocate(bytesToWrite)
	local offset = self.Index * 8
	if value == 0 then
		buffer.writebits(self.Buffer, offset, 24, 0b0_000000_00000000000000000) 
	elseif value >= 4294959104 then
		buffer.writebits(self.Buffer, offset, 24, 0b0_111111_00000000000000000)
	elseif value <= -4294959104 then
		buffer.writebits(self.Buffer, offset, 24, 0b1_111111_00000000000000000)
	elseif value ~= value then
		buffer.writebits(self.Buffer, offset, 24, 0b0_111111_00000000000000001)
	else
		local sign = 0
		if value < 0 then sign = 1 value = -value end
		local mantissa, exponent = math.frexp(value)
		buffer.writebits(self.Buffer, offset + 0, 17, mantissa * 262144 - 131071.5)
		buffer.writebits(self.Buffer, offset + 17, 6, exponent + 30)
		buffer.writebits(self.Buffer, offset + 23, 1, sign)
	end
	self.Index += bytesToWrite
end

function Cursor:ReadF4()
	local value = buffer.readf32(self.Buffer, self.Index)
	self.Index += 4
	return value
end

function Cursor:WriteF4(value)
	local bytesToWrite = 4
	self:Allocate(bytesToWrite)
	buffer.writef32(self.Buffer, self.Index, value)
	self.Index += bytesToWrite
end

function Cursor:ReadF8()
	local value = buffer.readf64(self.Buffer, self.Index)
	self.Index += 8
	return value
end

function Cursor:WriteF8(value)
	local bytesToWrite = 8
	self:Allocate(bytesToWrite)
	buffer.writef64(self.Buffer, self.Index, value)
	self.Index += bytesToWrite
end


-- String
function Cursor:ReadString(length)
	local value = buffer.readstring(self.Buffer, self.Index, length)
	self.Index += length
	return value
end

function Cursor:WriteString(value)
	local bytesToWrite = #value
	self:Allocate(bytesToWrite)
	buffer.writestring(self.Buffer, self.Index, value, bytesToWrite) -- Explicitly add length
	self.Index += bytesToWrite
end


-- Buffer
function Cursor:ReadBuffer(length)
	local value = buffer.create(length)
	buffer.copy(value, 0, self.Buffer, self.Index, length)
	self.Index += length
	return value
end

function Cursor:WriteBuffer(value)
	local bytesToWrite = buffer.len(value)
	self:Allocate(bytesToWrite)
	buffer.copy(self.Buffer, self.Index, value, 0, bytesToWrite) -- Add srcOffset=0 and length
	self.Index += bytesToWrite
end


-- Instance
function Cursor:ReadInstance()
	self.InstanceIndex += 1
	return self.Instances[self.InstanceIndex]
end

function Cursor:WriteInstance(value)
	local bytesToWrite = 0 -- No direct buffer write, but ensure allocation logic is consistent
	self:Allocate(bytesToWrite)
	self.InstanceIndex += 1
	self.Instances[self.InstanceIndex] = value
end

return Constructor