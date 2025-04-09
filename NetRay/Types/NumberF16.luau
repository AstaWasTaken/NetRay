--!strict
--!optimize 2
--!native

-- Requires
local Cursor = require(script.Parent.Cursor)

return {
	
	Read = function(cursor: Cursor.Cursor)
		return cursor:ReadF2()
	end,
	
	Write = function(cursor: Cursor.Cursor, value: number)
		cursor:Allocate(2)
		cursor:WriteF2(value)
	end,
	
}