--!strict
--!optimize 2
--!native

-- Requires
local Cursor = require(script.Parent.Cursor)

return {

	Read = function(cursor: Cursor.Cursor)
		return cursor:ReadF4()
	end,

	Write = function(cursor: Cursor.Cursor, value: number)
		cursor:Allocate(4)
		cursor:WriteF4(value)
	end,

}