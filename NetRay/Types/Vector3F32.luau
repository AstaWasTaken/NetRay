--!strict
--!optimize 2
--!native

-- Requires
local Cursor = require(script.Parent.Cursor)

return {
	
	Read = function(cursor: Cursor.Cursor)
		return Vector3.new(cursor:ReadF4(), cursor:ReadF4(), cursor:ReadF4())
	end,
	
	Write = function(cursor: Cursor.Cursor, value: Vector3)
		cursor:Allocate(12)
		cursor:WriteF4(value.X)
		cursor:WriteF4(value.Y)
		cursor:WriteF4(value.Z)
	end,
	
}