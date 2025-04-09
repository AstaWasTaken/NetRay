--!strict
--!optimize 2
--!native

-- Binary data type for handling raw binary data such as compressed data
-- Optimized version
-- Binary Type Handler (U3 Length Prefix for >64KB support)
-- Author: Asta (@TheYusufGamer)

-- Requires
local CursorModule = require(script.Parent.Parent.Types.Cursor) 
type Cursor = CursorModule.Cursor

return {
	Read = function(cursor: Cursor): string
		local length: number = cursor:ReadU3()
		local data: string = cursor:ReadString(length)

		return data
	end,

	Write = function(cursor: Cursor, value: string)
		local length: number = #value

		-- Validate length against U3 maximum if necessary
		if length > 16777215 then
			error(string.format("Binary data length (%d) exceeds 3-byte U24 limit (16777215).", length), 2)
		end

		cursor:WriteU3(length)
		cursor:WriteString(value)
		
	end,
}