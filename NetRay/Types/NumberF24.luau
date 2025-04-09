--!strict
--!optimize 2
--!native

-- Requires
local Cursor = require(script.Parent.Cursor)

return {

	Read = function(cursor: Cursor.Cursor)
		return cursor:ReadF3()
	end,

	Write = function(cursor: Cursor.Cursor, value: number)
		cursor:Allocate(3)
		cursor:WriteF3(value)
	end,

}