--!strict
--!optimize 2
--!native

-- Requires
local Cursor = require(script.Parent.Cursor)

return {

	Read = function(cursor: Cursor.Cursor)
		return cursor:ReadS4()
	end,

	Write = function(cursor: Cursor.Cursor, value: number)
		cursor:Allocate(4)
		cursor:WriteS4(value)
	end,

}