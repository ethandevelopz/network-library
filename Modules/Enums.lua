local enums = {}
local tagNames = {
	'Nil',
	'False',
	'True',
	'UInt',
	'NegInt',
	'Float32',
	'Float64',
	'String',
	'StringRef',
	'InternedString',
	'Array',
	'Map',
	'Buffer',
	'Instance',
	'Vector3',
	'Vector2',
	'CFrame',
	'Color3',
	'UDim',
	'UDim2',
	'BrickColor',
	'EnumItem',
	'NumberRange',
	'Rect',
	'DateTime',
	'ColorSequence',
	'NumberSequence',
	'Vector2int16',
	'Vector3int16',
}
local kindNames = {
	'Event',
	'Request',
	'Response',
	'Sync',
}
local tag = {}
local kind = {}
enums.tag = tag
enums.kind = kind
enums.shortStringRefBase = 64
enums.smallIntBase = 128
for index, tagName in ipairs(tagNames) do
	tag[tagName] = index - 1
end

for index, kindName in ipairs(kindNames) do
	kind[kindName] = index - 1
end

return enums
