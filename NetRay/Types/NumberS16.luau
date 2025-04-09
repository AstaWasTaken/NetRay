--!strict
--!optimize 2
--!native

-- Requires
local Cursor = require(script.Parent.Cursor)

return {

	Read = function(cursor: Cursor.Cursor)
		return cursor:ReadS2()
	end,

	Write = function(cursor: Cursor.Cursor, value: number)
		cursor:Allocate(2)
		cursor:WriteS2(value)
	end,

}