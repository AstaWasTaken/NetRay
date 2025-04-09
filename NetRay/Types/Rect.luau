--!strict
--!optimize 2
--!native

-- Requires
local Cursor = require(script.Parent.Cursor)

return {
	
	Read = function(cursor: Cursor.Cursor)
		return Rect.new(cursor:ReadF4(), cursor:ReadF4(), cursor:ReadF4(), cursor:ReadF4())
	end,
	
	Write = function(cursor: Cursor.Cursor, value: Rect)
		cursor:Allocate(16)
		cursor:WriteF4(value.Min.X)
		cursor:WriteF4(value.Min.Y)
		cursor:WriteF4(value.Max.X)
		cursor:WriteF4(value.Max.Y)
	end,
	
}