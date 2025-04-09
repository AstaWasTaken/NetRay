--!strict


--[[
	S8		Minimum: -128			Maximum: 127
	S16		Minimum: -32768			Maximum: 32767
	S24		Minimum: -8388608		Maximum: 8388607
	S32		Minimum: -2147483648	Maximum: 2147483647

	U8		Minimum: 0				Maximum: 255
	U16		Minimum: 0				Maximum: 65535
	U24		Minimum: 0				Maximum: 16777215
	U32		Minimum: 0				Maximum: 4294967295

	F16		±2048					[65520]
	F24		±262144					[4294959104]
	F32		±16777216				[170141183460469231731687303715884105728]
	F64		±9007199254740992		[huge]
]]


-- Types
export type Types = {
	Any:					any,
	Static:					any,
	Nil:					nil,
	NumberS8:				number,
	NumberS16:				number,
	NumberS24:				number,
	NumberS32:				number,
	NumberU4:				{number},
	NumberU8:				number,
	NumberU16:				number,
	NumberU24:				number,
	NumberU32:				number,
	NumberF16:				number,
	NumberF24:				number,
	NumberF32:				number,
	NumberF64:				number,
	Boolean1:				{boolean},
	Boolean8:				boolean,
	Characters:				string,
	Binary:					string,
	String:					string,
	Buffer:					buffer,
	Vector2S16:				Vector2,
	Vector2F24:				Vector2,
	Vector2F32:				Vector2,
	Vector3S16:				Vector3,
	Vector3F24:				Vector3,
	Vector3F32:				Vector3,
	CFrameF24U8:			CFrame,
	CFrameF32U8:			CFrame,
	CFrameF32U16:			CFrame,
	NumberRange:			NumberRange,
	NumberSequence:			NumberSequence,
	Color3:					Color3,
	ColorSequence:			ColorSequence,
	BrickColor:				BrickColor,
	UDim:					UDim,
	UDim2:					UDim2,
	Rect:					Rect,
	Region3:				Region3,
	EnumItem:				EnumItem,
	Instance:				Instance,
}


-- Varables
local names = {}			:: Types
local reads = {}			:: {[string]: (cursor: any) -> any}
local writes = {}			:: {[string]: (cursor: any, value: any) -> ()}
local types = {
	Nil =					"nil",
	NumberS8 =				"number",
	NumberS16 =				"number",
	NumberS24 =				"number",
	NumberS32 =				"number",
	NumberU4 =				"table",
	NumberU8 =				"number",
	NumberU16 =				"number",
	NumberU24 =				"number",
	NumberU32 =				"number",
	NumberF16 =				"number",
	NumberF24 =				"number",
	NumberF32 =				"number",
	NumberF64 =				"number",
	Boolean1 =				"table",
	Boolean8 =				"boolean",
	Characters =			"string",
	Binary = 				"string",
	String =				"string",
	Buffer =				"buffer",
	Vector2S16 =			"Vector2",
	Vector2F24 =			"Vector2",
	Vector2F32 =			"Vector2",
	Vector3S16 =			"Vector3",
	Vector3F24 =			"Vector3",
	Vector3F32 =			"Vector3",
	CFrameF24U8 =			"CFrame",
	CFrameF32U8 =			"CFrame",
	CFrameF32U16 =			"CFrame",
	NumberRange =			"NumberRange",
	NumberSequence =		"NumberSequence",
	Color3 =				"Color3",
	ColorSequence =			"ColorSequence",
	BrickColor =			"BrickColor",
	UDim =					"UDim",
	UDim2 =					"UDim2",
	Rect =					"Rect",
	Region3 =				"Region3",
	EnumItem =				"EnumItem",
	Instance =				"Instance",
}


-- Initialize
for _, moduleScript in script.Parent:GetChildren() do
	if moduleScript == script then continue end
	if moduleScript == script.Parent.Cursor then continue end
	local typeFunctions = require(moduleScript) :: any
	names[moduleScript.Name] = moduleScript.Name
	reads[moduleScript.Name] = typeFunctions.Read
	writes[moduleScript.Name] = typeFunctions.Write
end

return {Names = names, Types = types, Reads = reads, Writes = writes}