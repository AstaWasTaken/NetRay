--!strict
--!optimize 2
--!native
-- Requires
local Cursor = require(script.Parent.Cursor)

return {
	
	Read = function(cursor: Cursor.Cursor)
		return CFrame.fromEulerAnglesXYZ(
			cursor:ReadU1() / 40.58451048843331,
			cursor:ReadU1() / 40.58451048843331,
			cursor:ReadU1() / 40.58451048843331
		) + Vector3.new(
			cursor:ReadF3(),
			cursor:ReadF3(),
			cursor:ReadF3()
		)
	end,
	
	Write = function(cursor: Cursor.Cursor, value: CFrame)
		cursor:Allocate(12)
		local rx, ry, rz = value:ToEulerAnglesXYZ()
		cursor:WriteU1(rx * 40.58451048843331 + 0.5)
		cursor:WriteU1(ry * 40.58451048843331 + 0.5)
		cursor:WriteU1(rz * 40.58451048843331 + 0.5)
		cursor:WriteF3(value.X)
		cursor:WriteF3(value.Y)
		cursor:WriteF3(value.Z)
	end,
	
}