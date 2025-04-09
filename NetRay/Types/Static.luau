--!strict
--!optimize 2
--!native

-- Requires
local Cursor = require(script.Parent.Cursor)


-- Varables
local indices = {}
local values: {[any]: any} = {
	"DataStore Failed To Load",
	"Another Static String",
	math.pi,
	123456789,
	Vector3.new(1, 2, 3),
	"You can have upto 255 static values of any type"
}


-- Initialize
for index, value in values do indices[value] = index end


return {

	Read = function(cursor: Cursor.Cursor)
		return values[cursor:ReadU1()]
	end,

	Write = function(cursor: Cursor.Cursor, value: any)
		cursor:Allocate(1)
		cursor:WriteU1(indices[value] or 0)
	end,

}