--!strict
--!optimize 2
--!native

-- Requires
local Cursor = require(script.Parent.Cursor)

return {

	Read = function(cursor: Cursor.Cursor)
		return cursor:ReadS1()
	end,

	Write = function(cursor: Cursor.Cursor, value: number)
		cursor:Allocate(1)
		cursor:WriteS1(value)
	end,

}