--!strict

-- Requires
local Cursor = require(script.Parent.Cursor)

return {

	Read = function(cursor: Cursor.Cursor)
		local offset = cursor.Index * 8
		local value1 = buffer.readbits(cursor.Buffer, offset + 0, 1) == 1
		local value2 = buffer.readbits(cursor.Buffer, offset + 1, 1) == 1
		local value3 = buffer.readbits(cursor.Buffer, offset + 2, 1) == 1
		local value4 = buffer.readbits(cursor.Buffer, offset + 3, 1) == 1
		local value5 = buffer.readbits(cursor.Buffer, offset + 4, 1) == 1
		local value6 = buffer.readbits(cursor.Buffer, offset + 5, 1) == 1
		local value7 = buffer.readbits(cursor.Buffer, offset + 6, 1) == 1
		local value8 = buffer.readbits(cursor.Buffer, offset + 7, 1) == 1
		cursor.Index += 1
		return {value1, value2, value3, value4, value5, value6, value7, value8}
	end,

	Write = function(cursor: Cursor.Cursor, value: {boolean})
		cursor:Allocate(1)
		local offset = cursor.Index * 8
		buffer.writebits(cursor.Buffer, offset + 0, 1, if value[1] then 1 else 0)
		buffer.writebits(cursor.Buffer, offset + 1, 1, if value[2] then 1 else 0)
		buffer.writebits(cursor.Buffer, offset + 2, 1, if value[3] then 1 else 0)
		buffer.writebits(cursor.Buffer, offset + 3, 1, if value[4] then 1 else 0)
		buffer.writebits(cursor.Buffer, offset + 4, 1, if value[5] then 1 else 0)
		buffer.writebits(cursor.Buffer, offset + 5, 1, if value[6] then 1 else 0)
		buffer.writebits(cursor.Buffer, offset + 6, 1, if value[7] then 1 else 0)
		buffer.writebits(cursor.Buffer, offset + 7, 1, if value[8] then 1 else 0)
		cursor.Index += 1
	end,

}