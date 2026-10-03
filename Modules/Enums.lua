local enums = {}

local tagNames = {
	'Nil',
	'False',
	'True',
	'Integer',
	'Float',
	'String',
	'Vector3',
	'Array',
	'Dictionary',
	'Buffer',
	'Extended',
}

local extNames = {
	'Instance',
	'Player',
	'CFrame',
	'Color3',
	'BrickColor',
	'UDim',
	'UDim2',
	'Vector2',
	'Vector2int16',
	'Vector3int16',
	'EnumItem',
	'NumberRange',
	'Rect',
	'DateTime',
	'ColorSequence',
	'NumberSequence',
}

local tag = {}
local ext = {}
enums.tag = tag
enums.ext = ext
for index, tagName in ipairs(tagNames) do
	tag[tagName] = index - 1
end

for index, extName in ipairs(extNames) do
	ext[extName] = index
end

return enums