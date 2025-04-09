--!strict
--!optimize 2
--!native

-- Requires
local Cursor = require(script.Parent.Cursor)

return {

	Read = function(cursor: Cursor.Cursor)
		local offset = cursor.Index * 8
		local value1 = buffer.readbits(cursor.Buffer, offset + 0, 4)
		local value2 = buffer.readbits(cursor.Buffer, offset + 4, 4)
		cursor.Index += 1
		return {value1, value2}
	end,

	Write = function(cursor: Cursor.Cursor, value: {number})
		cursor:Allocate(1)
		local offset = cursor.Index * 8
		buffer.writebits(cursor.Buffer, offset + 0, 4, value[1])
		buffer.writebits(cursor.Buffer, offset + 4, 4, value[2])
		cursor.Index += 1
	end,

}