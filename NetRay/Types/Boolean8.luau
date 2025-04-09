--!strict
--!optimize 2
--!native

-- Requires
local Cursor = require(script.Parent.Cursor)

return {
	
	Read = function(cursor: Cursor.Cursor)
		return cursor:ReadU1() == 1
	end,
	
	Write = function(cursor: Cursor.Cursor, value: boolean)
		cursor:Allocate(1)
		cursor:WriteU1(if value then 1 else 0)
	end,
	
}