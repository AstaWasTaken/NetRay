--!strict
--!optimize 2
--!native

-- Requires
local Cursor = require(script.Parent.Cursor)

return {
	
	Read = function(cursor: Cursor.Cursor)
		return Vector2.new(cursor:ReadF4(), cursor:ReadF4())
	end,
	
	Write = function(cursor: Cursor.Cursor, value: Vector2)
		cursor:Allocate(8)
		cursor:WriteF4(value.X)
		cursor:WriteF4(value.Y)
	end,
	
}