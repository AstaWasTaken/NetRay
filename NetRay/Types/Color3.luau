--!strict
--!optimize 2
--!native

-- Requires
local Cursor = require(script.Parent.Cursor)

return {
	
	Read = function(cursor: Cursor.Cursor)
		return Color3.fromRGB(cursor:ReadU1(), cursor:ReadU1(), cursor:ReadU1())
	end,
	
	Write = function(cursor: Cursor.Cursor, value: Color3)
		cursor:Allocate(3)
		cursor:WriteU1(value.R * 255 + 0.5)
		cursor:WriteU1(value.G * 255 + 0.5)
		cursor:WriteU1(value.B * 255 + 0.5)
	end,
	
}