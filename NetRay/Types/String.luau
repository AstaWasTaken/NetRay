--!strict
--!optimize 2
--!native

-- Requires
local Cursor = require(script.Parent.Cursor)

return {

	Read = function(cursor: Cursor.Cursor)
		return cursor:ReadString(cursor:ReadU1())
	end,

	Write = function(cursor: Cursor.Cursor, value: string)
		cursor:Allocate(1 + #value)
		cursor:WriteU1(#value)
		cursor:WriteString(value)
	end,

}