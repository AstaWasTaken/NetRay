--!strict
--!optimize 2
--!native

-- Requires
local Cursor = require(script.Parent.Cursor)

return {
	
	Read = function(cursor: Cursor.Cursor)
		return UDim2.new(cursor:ReadS2() / 1000, cursor:ReadS2(), cursor:ReadS2() / 1000, cursor:ReadS2())
	end,
	
	Write = function(cursor: Cursor.Cursor, value: UDim2)
		cursor:Allocate(8)
		cursor:WriteS2(value.X.Scale * 1000 + 0.5)
		cursor:WriteS2(value.X.Offset)
		cursor:WriteS2(value.Y.Scale * 1000 + 0.5)
		cursor:WriteS2(value.Y.Offset)
	end,
	
}