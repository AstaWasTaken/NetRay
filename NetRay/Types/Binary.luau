--!strict
-- Binary data type for handling raw binary data such as compressed data
-- Optimized version with buffer copy enhancements
-- Author: Asta (@TheYusufGamer)

-- Requires
local Cursor = require(script.Parent.Cursor)

return {
	Read = function(cursor: Cursor.Cursor)
		-- Read the length using a 3-byte value for supporting much larger binary data
		-- This allows binary data up to 16MB rather than 64KB
		local length = cursor:ReadU3() 
		
		-- For small data, just read from the buffer directly
		if length < 4096 then
			local data = buffer.readstring(cursor.Buffer, cursor.Index, length)
			cursor.Index += length
			return data
		end
		
		-- For larger data, create a new buffer and copy the data
		-- This avoids creating large string objects in memory
		local dataBuf = buffer.create(length)
		for i = 0, length - 1, 4096 do
			local blockSize = math.min(4096, length - i)
			local block = buffer.readstring(cursor.Buffer, cursor.Index + i, blockSize)
			buffer.writestring(dataBuf, i, block)
		end
		
		cursor.Index += length
		return buffer.tostring(dataBuf) -- Convert to string at the end
	end,

	Write = function(cursor: Cursor.Cursor, value: string)
		local length = #value
		
		-- Support for larger binary data with 3-byte length
		cursor:Allocate(3 + length) -- 3 bytes for length + data
		cursor:WriteU3(length)
		
		-- For small data, write directly
		if length < 4096 then
			buffer.writestring(cursor.Buffer, cursor.Index, value)
			cursor.Index += length
			return
		end
		
		-- For larger data, write in blocks to avoid large memory operations
		for i = 1, length, 4096 do
			local blockEnd = math.min(i + 4095, length)
			local blockSize = blockEnd - i + 1
			local block = string.sub(value, i, blockEnd)
			buffer.writestring(cursor.Buffer, cursor.Index, block)
			cursor.Index += blockSize
		end
	end,
}