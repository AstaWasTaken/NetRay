--!strict
--!optimize 2
--!native

-- Requires
local Cursor = require(script.Parent.Cursor)

return {

	Read = function(cursor: Cursor.Cursor)
		return cursor:ReadInstance()
	end,

	Write = function(cursor: Cursor.Cursor, value: Instance)
		cursor:WriteInstance(value)
	end,

}