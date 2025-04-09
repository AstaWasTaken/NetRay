--!strict
--!optimize 2
--!native
-- Requires
local Cursor = require(script.Parent.Cursor)

return {

	Read = function(cursor: Cursor.Cursor)
		return BrickColor.new(cursor:ReadU3())
	end,

	Write = function(cursor: Cursor.Cursor, value: BrickColor)
		cursor:Allocate(3)
		cursor:WriteU3(value.Number)
	end,

}