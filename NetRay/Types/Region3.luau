--!strict
--!optimize 2
--!native

-- Requires
local Cursor = require(script.Parent.Cursor)

return {
	
	Read = function(cursor: Cursor.Cursor)
		return Region3.new(
			Vector3.new(cursor:ReadF4(), cursor:ReadF4(), cursor:ReadF4()),
			Vector3.new(cursor:ReadF4(), cursor:ReadF4(), cursor:ReadF4())
		)
	end,
	
	Write = function(cursor: Cursor.Cursor, value: Region3)
		cursor:Allocate(24)
		local halfSize = value.Size / 2
		local minimum = value.CFrame.Position - halfSize
		local maximum = value.CFrame.Position + halfSize
		cursor:WriteF4(minimum.X)
		cursor:WriteF4(minimum.Y)
		cursor:WriteF4(minimum.Z)
		cursor:WriteF4(maximum.X)
		cursor:WriteF4(maximum.Y)
		cursor:WriteF4(maximum.Z)
	end,
	
}