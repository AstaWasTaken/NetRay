--!strict
--!optimize 2
--!native

-- Requires
local Cursor = require(script.Parent.Cursor)

return {
	
	Read = function(cursor: Cursor.Cursor)
		local length = cursor:ReadU1()
		local keypoints = table.create(length)
		for index = 1, cursor:ReadU1() do
			table.insert(keypoints, ColorSequenceKeypoint.new(
				cursor:ReadU1() / 255,
				Color3.fromRGB(cursor:ReadU1(), cursor:ReadU1(), cursor:ReadU1())
			))
		end
		return ColorSequence.new(keypoints)
	end,
	
	Write = function(cursor: Cursor.Cursor, value: ColorSequence)
		local length = #value.Keypoints
		cursor:Allocate(1 + length * 4)
		cursor:WriteU1(length)
		for index, keypoint in value.Keypoints do
			cursor:WriteU1(keypoint.Time * 255 + 0.5)
			cursor:WriteU1(keypoint.Value.R * 255 + 0.5)
			cursor:WriteU1(keypoint.Value.G * 255 + 0.5)
			cursor:WriteU1(keypoint.Value.B * 255 + 0.5)
		end
	end,
	
}