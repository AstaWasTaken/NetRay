--!strict
--!optimize 2
--!native

-- Requires
local Cursor = require(script.Parent.Cursor)

return {
	
	Read = function(cursor: Cursor.Cursor)
		return NumberRange.new(cursor:ReadF4(), cursor:ReadF4())
	end,
	
	Write = function(cursor: Cursor.Cursor, value: NumberRange)
		cursor:Allocate(8)
		cursor:WriteF4(value.Min)
		cursor:WriteF4(value.Max)
	end,
	
}