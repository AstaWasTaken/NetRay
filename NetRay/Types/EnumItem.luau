--!strict
--!optimize 2
--!native

-- Requires
local Cursor = require(script.Parent.Cursor)


-- Varables
local indices = {}
local values = Enum:GetEnums() :: {any} -- fix type checking bug


-- Initialize
for index, value in values do indices[value] = index end

return {

	Read = function(cursor: Cursor.Cursor)
		local offset = cursor.Index * 8
		cursor.Index += 3
		return values[buffer.readbits(cursor.Buffer, offset + 0, 12)]:FromValue(buffer.readbits(cursor.Buffer, offset + 12, 12))
	end,

	Write = function(cursor: Cursor.Cursor, value: EnumItem)
		cursor:Allocate(3)
		local offset = cursor.Index * 8
		buffer.writebits(cursor.Buffer, offset + 0, 12, indices[value.EnumType])
		buffer.writebits(cursor.Buffer, offset + 12, 12, value.Value)
		cursor.Index += 3
	end,

}