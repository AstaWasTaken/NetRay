--!strict
--!optimize 2
--!native
-- Recommended character array lengths: 2, 4, 8, 16, 32, 64, 128, 256


-- Requires
local Cursor = require(script.Parent.Cursor)


-- Varables
local indices = {}
local characters = {[0] =
	" ", ".", "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "A", "B", "C", "D",
	"E", "F", "G", "H", "I", "J", "K", "L", "M", "N", "O", "P", "Q", "R", "S", "T",
	"U", "V", "W", "X", "Y", "Z", "a", "b", "c", "d", "e", "f", "g", "h", "i", "j",
	"k", "l", "m", "n", "o", "p", "q", "r", "s", "t", "u", "v", "w", "x", "y", "z",
}


-- Initialize
for index, value in characters do indices[value] = index end
local bits = math.ceil(math.log(#characters + 1, 2))
local bytes = bits / 8

return {

	Read = function(cursor: Cursor.Cursor)
		local length = cursor:ReadU1()
		local bytes = math.ceil(length * bytes)
		local characterArray = table.create(length)
		local offset = cursor.Index * 8
		for index = 1, length do
			table.insert(characterArray, characters[buffer.readbits(cursor.Buffer, offset, bits)])
			offset += bits
		end
		cursor.Index += bytes
		return table.concat(characterArray)
	end,

	Write = function(cursor: Cursor.Cursor, value: string)
		local bytes = math.ceil(#value * bytes)
		cursor:Allocate(1 + bytes)
		cursor:WriteU1(#value)
		local offset = cursor.Index * 8
		for index = 1, #value do
			buffer.writebits(cursor.Buffer, offset, bits, indices[value:sub(index, index)])
			offset += bits
		end
		cursor.Index += bytes
	end,

}