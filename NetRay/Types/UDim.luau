--!strict
--!optimize 2
--!native

-- Requires
local Cursor = require(script.Parent.Cursor)

return {
	
	Read = function(cursor: Cursor.Cursor)
		return UDim.new(cursor:ReadS2() / 1000, cursor:ReadS2())
	end,
	
	Write = function(cursor: Cursor.Cursor, value: UDim)
		cursor:Allocate(4)
		cursor:WriteS2(value.Scale * 1000 + 0.5)
		cursor:WriteS2(value.Offset)
	end,
	
}