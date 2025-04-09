--!strict
--!optimize 2
--!native

-- Requires
local Cursor = require(script.Parent.Cursor)

return {
	
	Read = function(cursor: Cursor.Cursor)
		return Vector3.new(cursor:ReadF3(), cursor:ReadF3(), cursor:ReadF3())
	end,
	
	Write = function(cursor: Cursor.Cursor, value: Vector3)
		cursor:Allocate(9)
		cursor:WriteF3(value.X)
		cursor:WriteF3(value.Y)
		cursor:WriteF3(value.Z)
	end,
	
}