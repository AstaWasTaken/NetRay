--!strict
--!optimize 2
--!native

-- Requires
local Cursor = require(script.Parent.Cursor)

return {

	Read = function(cursor: Cursor.Cursor)
		return cursor:ReadBuffer(cursor:ReadU1())
	end,

	Write = function(cursor: Cursor.Cursor, value: buffer)
		local length = buffer.len(value)
		cursor:Allocate(1 + length)
		cursor:WriteU1(length)
		cursor:WriteBuffer(value)
	end,

}