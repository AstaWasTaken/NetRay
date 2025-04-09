--!strict
--!optimize 2
--!native
-- Requires
local Cursor = require(script.Parent.Cursor)

return {
	
	Read = function(cursor: Cursor.Cursor)
		return CFrame.fromEulerAnglesXYZ(
			cursor:ReadU2() / 10430.219195527361,
			cursor:ReadU2() / 10430.219195527361,
			cursor:ReadU2() / 10430.219195527361
		) + Vector3.new(
			cursor:ReadF4(),
			cursor:ReadF4(),
			cursor:ReadF4()
		)
	end,
	
	Write = function(cursor: Cursor.Cursor, value: CFrame)
		cursor:Allocate(18)
		local rx, ry, rz = value:ToEulerAnglesXYZ()
		cursor:WriteU2(rx * 10430.219195527361 + 0.5)
		cursor:WriteU2(ry * 10430.219195527361 + 0.5)
		cursor:WriteU2(rz * 10430.219195527361 + 0.5)
		cursor:WriteF4(value.X)
		cursor:WriteF4(value.Y)
		cursor:WriteF4(value.Z)
	end,
	
}