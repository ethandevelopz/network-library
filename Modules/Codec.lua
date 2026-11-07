--!native
--!optimize 2
local enums = require(script.Parent.Enums)
local codec = {}
local tag = enums.tag
local smallIntBase = enums.smallIntBase
local smallIntMax = 255 - smallIntBase
local shortStringRefBase = enums.shortStringRefBase
local shortStringRefMax = smallIntBase - shortStringRefBase
local maxSafeInteger = 9007199254740991
local maxDepth = 32
local maxUnboundedCount = 65535
local inf = math.huge
local tagNil, tagFalse, tagTrue, tagUInt, tagNegInt, tagFloat32, tagFloat64 = tag.Nil, tag.False, tag.True, tag.UInt, tag.NegInt, tag.Float32, tag.Float64
local tagString, tagStringRef, tagInternedString, tagArray, tagMap, tagBuffer, tagInstance = tag.String, tag.StringRef, tag.InternedString, tag.Array, tag.Map, tag.Buffer, tag.Instance
local scratch = buffer.create(512)
local capacity = 512
local cursor = 0
local refs = {}
local refCount = 0
local stringIndex = {}
local stringCount = 0
local emptyRefs = {}
local source = scratch
local position = 0
local limit = 0
local sourceRefs = emptyRefs
local sourceRefBase = 0
local sourceRefCount = 0
local sourceStrings = {}
local sourceStringCount = 0
local internedIndex = {}
local internedStrings = {}
local internedCount = 0
local enumLookup = {}
local schemasByName = {}
local types = {}
local dynamicWriters = {}
local dynamicReaders = {}
local writeValue
local readValue
codec.types = types

local function grow(required)
	local size = capacity
	repeat
		size *= 2
	until size >= required
	local nextBuffer = buffer.create(size)
	buffer.copy(nextBuffer, 0, scratch, 0, cursor)
	scratch = nextBuffer
	capacity = size
end

local function writeU8(value)
	if cursor + 1 > capacity then
		grow(cursor + 1)
	end

	buffer.writeu8(scratch, cursor, value)
	cursor += 1
end

local function writeI8(value)
	if cursor + 1 > capacity then
		grow(cursor + 1)
	end

	buffer.writei8(scratch, cursor, value)
	cursor += 1
end

local function writeU16(value)
	if cursor + 2 > capacity then
		grow(cursor + 2)
	end

	buffer.writeu16(scratch, cursor, value)
	cursor += 2
end

local function writeI16(value)
	if cursor + 2 > capacity then
		grow(cursor + 2)
	end

	buffer.writei16(scratch, cursor, value)
	cursor += 2
end

local function writeU32(value)
	if cursor + 4 > capacity then
		grow(cursor + 4)
	end

	buffer.writeu32(scratch, cursor, value)
	cursor += 4
end

local function writeI32(value)
	if cursor + 4 > capacity then
		grow(cursor + 4)
	end

	buffer.writei32(scratch, cursor, value)
	cursor += 4
end

local function writeF32(value)
	if cursor + 4 > capacity then
		grow(cursor + 4)
	end

	buffer.writef32(scratch, cursor, value)
	cursor += 4
end

local function writeF64(value)
	if cursor + 8 > capacity then
		grow(cursor + 8)
	end

	buffer.writef64(scratch, cursor, value)
	cursor += 8
end

local function writeVarUInt(value)
	if not (value >= 0 and value <= maxSafeInteger) then
		error('varuint out of range: ' .. tostring(value), 0)
	end

	if cursor + 8 > capacity then
		grow(cursor + 8)
	end

	while value >= 128 do
		buffer.writeu8(scratch, cursor, value % 128 + 128)
		value //= 128
		cursor += 1
	end

	buffer.writeu8(scratch, cursor, value)
	cursor += 1
end

local function writeVarInt(value)
	writeVarUInt(if value >= 0 then value * 2 else -value * 2 - 1)
end

local function writeRawString(value)
	local length = #value
	writeVarUInt(length)
	if cursor + length > capacity then
		grow(cursor + length)
	end

	buffer.writestring(scratch, cursor, value, length)
	cursor += length
end

local function writeRawBuffer(value)
	local length = buffer.len(value)
	writeVarUInt(length)
	if cursor + length > capacity then
		grow(cursor + length)
	end

	buffer.copy(scratch, cursor, value, 0, length)
	cursor += length
end

local function writeRef(value)
	refCount += 1
	refs[refCount] = value
	writeVarUInt(refCount - 1)
end

local function readU8()
	local value = buffer.readu8(source, position)
	position += 1
	return value
end

local function readI8()
	local value = buffer.readi8(source, position)
	position += 1
	return value
end

local function readU16()
	local value = buffer.readu16(source, position)
	position += 2
	return value
end

local function readI16()
	local value = buffer.readi16(source, position)
	position += 2
	return value
end

local function readU32()
	local value = buffer.readu32(source, position)
	position += 4
	return value
end

local function readI32()
	local value = buffer.readi32(source, position)
	position += 4
	return value
end

local function readF32()
	local value = buffer.readf32(source, position)
	position += 4
	return value
end

local function readF64()
	local value = buffer.readf64(source, position)
	position += 8
	return value
end

local function readVarUInt()
	local result = 0
	local scale = 1
	for _ = 1, 8 do
		local byte = buffer.readu8(source, position)
		position += 1
		if byte < 128 then
			return result + byte * scale
		end

		result += (byte - 128) * scale
		scale *= 128
	end

	error('varuint too long', 0)
end

local function readVarInt()
	local zigzag = readVarUInt()
	if zigzag % 2 == 0 then
		return zigzag // 2
	end

	return -(zigzag + 1) // 2
end

local function readRawString()
	local length = readVarUInt()
	if length > limit - position then
		error('string length exceeds payload', 0)
	end

	local value = buffer.readstring(source, position, length)
	position += length
	return value
end

local function readRawBuffer()
	local length = readVarUInt()
	if length > limit - position then
		error('buffer length exceeds payload', 0)
	end

	local value = buffer.create(length)
	buffer.copy(value, 0, source, position, length)
	position += length
	return value
end

local function readRef()
	local index = readVarUInt()
	if index >= sourceRefCount then
		error('instance reference out of range', 0)
	end

	return sourceRefs[sourceRefBase + index + 1]
end

local function finite(value)
	if value ~= value or value == inf or value == -inf then
		error('non-finite number', 0)
	end

	return value
end

local function readFiniteF32()
	return finite(readF32())
end

local function readFiniteF64()
	return finite(readF64())
end

local function readCount(minSize, cap)
	local count = readVarUInt()
	if count > cap or count * minSize > limit - position then
		error('collection length exceeds payload', 0)
	end

	return count
end

local function cframeToQuaternion(cframe)
	local _, _, _, m00, m01, m02, m10, m11, m12, m20, m21, m22 = cframe:GetComponents()
	local trace = m00 + m11 + m22
	if trace > 0 then
		local s = math.sqrt(trace + 1) * 2
		return (m21 - m12) / s, (m02 - m20) / s, (m10 - m01) / s, s / 4
	elseif m00 > m11 and m00 > m22 then
		local s = math.sqrt(1 + m00 - m11 - m22) * 2
		return s / 4, (m01 + m10) / s, (m02 + m20) / s, (m21 - m12) / s
	elseif m11 > m22 then
		local s = math.sqrt(1 + m11 - m00 - m22) * 2
		return (m01 + m10) / s, s / 4, (m12 + m21) / s, (m02 - m20) / s
	end

	local s = math.sqrt(1 + m22 - m00 - m11) * 2
	return (m02 + m20) / s, (m12 + m21) / s, s / 4, (m10 - m01) / s
end

local function enumTypeName(enumType)
	local name = tostring(enumType)
	return string.match(name, '^Enum%.(.+)$') or name
end

local function lookupEnumItem(enumName, value)
	local map = enumLookup[enumName]
	if not map then
		local enumType = Enum[enumName]
		map = {}
		for _, item in enumType:GetEnumItems() do
			map[item.Value] = item
		end

		enumLookup[enumName] = map
	end

	local item = map[value]
	if item == nil then
		error('unknown enum value ' .. tostring(value) .. ' for ' .. enumName, 0)
	end

	return item
end

local function quantize(channel)
	return math.clamp(math.round(channel * 255), 0, 255)
end

local function writeVector3(value)
	if cursor + 12 > capacity then
		grow(cursor + 12)
	end

	buffer.writef32(scratch, cursor, value.X)
	buffer.writef32(scratch, cursor + 4, value.Y)
	buffer.writef32(scratch, cursor + 8, value.Z)
	cursor += 12
end

local function readVector3()
	local x, y, z = buffer.readf32(source, position), buffer.readf32(source, position + 4), buffer.readf32(source, position + 8)
	position += 12
	return Vector3.new(x, y, z)
end

local function readFiniteVector3()
	local x, y, z = buffer.readf32(source, position), buffer.readf32(source, position + 4), buffer.readf32(source, position + 8)
	position += 12
	return Vector3.new(finite(x), finite(y), finite(z))
end

local function writeVector2(value)
	writeF32(value.X)
	writeF32(value.Y)
end

local function readVector2()
	return Vector2.new(readF32(), readF32())
end

local function readFiniteVector2()
	return Vector2.new(readFiniteF32(), readFiniteF32())
end

local function writeCFrame(value)
	if cursor + 28 > capacity then
		grow(cursor + 28)
	end

	local qx, qy, qz, qw = cframeToQuaternion(value)
	local position3 = value.Position
	buffer.writef32(scratch, cursor, position3.X)
	buffer.writef32(scratch, cursor + 4, position3.Y)
	buffer.writef32(scratch, cursor + 8, position3.Z)
	buffer.writef32(scratch, cursor + 12, qx)
	buffer.writef32(scratch, cursor + 16, qy)
	buffer.writef32(scratch, cursor + 20, qz)
	buffer.writef32(scratch, cursor + 24, qw)
	cursor += 28
end

local function readCFrame()
	local at = position
	position += 28
	return CFrame.new(
		buffer.readf32(source, at),
		buffer.readf32(source, at + 4),
		buffer.readf32(source, at + 8),
		buffer.readf32(source, at + 12),
		buffer.readf32(source, at + 16),
		buffer.readf32(source, at + 20),
		buffer.readf32(source, at + 24)
	)
end

local function readFiniteCFrame()
	local at = position
	position += 28
	return CFrame.new(
		finite(buffer.readf32(source, at)),
		finite(buffer.readf32(source, at + 4)),
		finite(buffer.readf32(source, at + 8)),
		finite(buffer.readf32(source, at + 12)),
		finite(buffer.readf32(source, at + 16)),
		finite(buffer.readf32(source, at + 20)),
		finite(buffer.readf32(source, at + 24))
	)
end

local function writeColor3(value)
	if cursor + 3 > capacity then
		grow(cursor + 3)
	end

	buffer.writeu8(scratch, cursor, quantize(value.R))
	buffer.writeu8(scratch, cursor + 1, quantize(value.G))
	buffer.writeu8(scratch, cursor + 2, quantize(value.B))
	cursor += 3
end

local function readColor3()
	local at = position
	position += 3
	return Color3.fromRGB(buffer.readu8(source, at), buffer.readu8(source, at + 1), buffer.readu8(source, at + 2))
end

local function writeUDim(value)
	writeF32(value.Scale)
	writeI32(value.Offset)
end

local function readUDim()
	return UDim.new(readF32(), readI32())
end

local function writeUDim2(value)
	writeUDim(value.X)
	writeUDim(value.Y)
end

local function readUDim2()
	return UDim2.new(readF32(), readI32(), readF32(), readI32())
end

local function writeBrickColor(value)
	writeVarUInt(value.Number)
end

local function readBrickColor()
	return BrickColor.new(readVarUInt())
end

local function writeNumberRange(value)
	writeF32(value.Min)
	writeF32(value.Max)
end

local function readNumberRange()
	local minimum = readF32()
	return NumberRange.new(minimum, math.max(minimum, readF32()))
end

local function writeRect(value)
	writeF32(value.Min.X)
	writeF32(value.Min.Y)
	writeF32(value.Max.X)
	writeF32(value.Max.Y)
end

local function readRect()
	return Rect.new(readF32(), readF32(), readF32(), readF32())
end

local function writeDateTime(value)
	writeVarInt(value.UnixTimestampMillis)
end

local function readDateTime()
	return DateTime.fromUnixTimestampMillis(readVarInt())
end

local function writeColorSequence(value)
	local keypoints = value.Keypoints
	writeVarUInt(#keypoints)
	for _, keypoint in keypoints do
		writeF32(keypoint.Time)
		writeColor3(keypoint.Value)
	end
end

local function readColorSequence()
	local count = readCount(7, 20)
	local keypoints = table.create(count)
	for index = 1, count do
		keypoints[index] = ColorSequenceKeypoint.new(readF32(), readColor3())
	end

	return ColorSequence.new(keypoints)
end

local function writeNumberSequence(value)
	local keypoints = value.Keypoints
	writeVarUInt(#keypoints)
	for _, keypoint in keypoints do
		writeF32(keypoint.Time)
		writeF32(keypoint.Value)
		writeF32(keypoint.Envelope)
	end
end

local function readNumberSequence()
	local count = readCount(12, 20)
	local keypoints = table.create(count)
	for index = 1, count do
		keypoints[index] = NumberSequenceKeypoint.new(readF32(), readF32(), readF32())
	end

	return NumberSequence.new(keypoints)
end

local function writeVector2int16(value)
	writeI16(value.X)
	writeI16(value.Y)
end

local function readVector2int16()
	return Vector2int16.new(readI16(), readI16())
end

local function writeVector3int16(value)
	writeI16(value.X)
	writeI16(value.Y)
	writeI16(value.Z)
end

local function readVector3int16()
	return Vector3int16.new(readI16(), readI16(), readI16())
end

local function writeStringValue(value)
	local index = stringIndex[value]
	if index then
		if index <= shortStringRefMax then
			writeU8(shortStringRefBase + index - 1)
		else
			writeU8(tagStringRef)
			writeVarUInt(index)
		end

		return
	end

	local interned = internedIndex[value]
	if interned then
		writeU8(tagInternedString)
		writeVarUInt(interned)
		return
	end

	writeU8(tagString)
	writeRawString(value)
	stringCount += 1
	stringIndex[value] = stringCount
end

local function writeEnumItem(value)
	writeStringValue(enumTypeName(value.EnumType))
	writeVarInt(value.Value)
end

local function readEnumItem()
	local enumName = readValue(0)
	if type(enumName) ~= 'string' then
		error('invalid enum type name', 0)
	end

	return lookupEnumItem(enumName, readVarInt())
end

local function writeNumber(value)
	if value % 1 == 0 and value >= -maxSafeInteger and value <= maxSafeInteger and (value ~= 0 or 1 / value > 0) then
		if value < 0 then
			writeU8(tagNegInt)
			writeVarUInt(-value)
		elseif value <= smallIntMax then
			writeU8(smallIntBase + value)
		else
			writeU8(tagUInt)
			writeVarUInt(value)
		end

		return
	end

	if cursor + 9 > capacity then
		grow(cursor + 9)
	end

	buffer.writef32(scratch, cursor + 1, value)
	if buffer.readf32(scratch, cursor + 1) == value then
		buffer.writeu8(scratch, cursor, tagFloat32)
		cursor += 5
	else
		buffer.writeu8(scratch, cursor, tagFloat64)
		buffer.writef64(scratch, cursor + 1, value)
		cursor += 9
	end
end

local function writeTable(value, depth)
	if depth >= maxDepth then
		error('table nesting too deep or cyclic', 0)
	end

	local count = 0
	local maxKey = 0
	local isArray = true
	for key in next, value do
		count += 1
		if isArray then
			if type(key) == 'number' and key >= 1 and key % 1 == 0 then
				if key > maxKey then
					maxKey = key
				end
			else
				isArray = false
			end
		end
	end

	if isArray and maxKey == count then
		writeU8(tagArray)
		writeVarUInt(count)
		for index = 1, count do
			writeValue(value[index], depth + 1)
		end

		return
	end

	writeU8(tagMap)
	writeVarUInt(count)
	for key, entry in next, value do
		writeValue(key, depth + 1)
		writeValue(entry, depth + 1)
	end
end

local function tagged(valueTag, body)
	return function(value)
		writeU8(valueTag)
		body(value)
	end
end

dynamicWriters['nil'] = function()
	writeU8(tagNil)
end
dynamicWriters.boolean = function(value)
	writeU8(if value then tagTrue else tagFalse)
end
dynamicWriters.number = writeNumber
dynamicWriters.string = writeStringValue
dynamicWriters.table = writeTable
dynamicWriters.buffer = tagged(tagBuffer, writeRawBuffer)
dynamicWriters.Instance = tagged(tagInstance, writeRef)
dynamicWriters.Vector3 = tagged(tag.Vector3, writeVector3)
dynamicWriters.Vector2 = tagged(tag.Vector2, writeVector2)
dynamicWriters.CFrame = tagged(tag.CFrame, writeCFrame)
dynamicWriters.Color3 = tagged(tag.Color3, writeColor3)
dynamicWriters.UDim = tagged(tag.UDim, writeUDim)
dynamicWriters.UDim2 = tagged(tag.UDim2, writeUDim2)
dynamicWriters.BrickColor = tagged(tag.BrickColor, writeBrickColor)
dynamicWriters.EnumItem = tagged(tag.EnumItem, writeEnumItem)
dynamicWriters.NumberRange = tagged(tag.NumberRange, writeNumberRange)
dynamicWriters.Rect = tagged(tag.Rect, writeRect)
dynamicWriters.DateTime = tagged(tag.DateTime, writeDateTime)
dynamicWriters.ColorSequence = tagged(tag.ColorSequence, writeColorSequence)
dynamicWriters.NumberSequence = tagged(tag.NumberSequence, writeNumberSequence)
dynamicWriters.Vector2int16 = tagged(tag.Vector2int16, writeVector2int16)
dynamicWriters.Vector3int16 = tagged(tag.Vector3int16, writeVector3int16)

function writeValue(value, depth)
	local valueType = typeof(value)
	local writer = dynamicWriters[valueType]
	if not writer then
		error('cannot send value of type ' .. valueType, 0)
	end

	writer(value, depth)
end

local function setReader(valueTag, reader)
	dynamicReaders[valueTag + 1] = reader
end

setReader(tagNil, function()
	return nil
end)
setReader(tagFalse, function()
	return false
end)
setReader(tagTrue, function()
	return true
end)
setReader(tagUInt, readVarUInt)
setReader(tagNegInt, function()
	return -readVarUInt()
end)
setReader(tagFloat32, readF32)
setReader(tagFloat64, readF64)
setReader(tagString, function()
	local value = readRawString()
	sourceStringCount += 1
	sourceStrings[sourceStringCount] = value
	return value
end)
setReader(tagStringRef, function()
	local index = readVarUInt()
	if index < 1 or index > sourceStringCount then
		error('string reference out of range', 0)
	end

	return sourceStrings[index]
end)
setReader(tagInternedString, function()
	local value = internedStrings[readVarUInt()]
	if value == nil then
		error('unknown interned string', 0)
	end

	return value
end)
setReader(tagArray, function(depth)
	if depth >= maxDepth then
		error('table nesting too deep', 0)
	end

	local count = readCount(1, maxSafeInteger)
	local result = table.create(count)
	for index = 1, count do
		result[index] = readValue(depth + 1)
	end

	return result
end)
setReader(tagMap, function(depth)
	if depth >= maxDepth then
		error('table nesting too deep', 0)
	end

	local count = readCount(2, maxSafeInteger)
	local result = {}
	for _ = 1, count do
		local key = readValue(depth + 1)
		if key == nil or key ~= key then
			error('invalid table key', 0)
		end

		result[key] = readValue(depth + 1)
	end

	return result
end)
setReader(tagBuffer, readRawBuffer)
setReader(tagInstance, readRef)
setReader(tag.Vector3, readVector3)
setReader(tag.Vector2, readVector2)
setReader(tag.CFrame, readCFrame)
setReader(tag.Color3, readColor3)
setReader(tag.UDim, readUDim)
setReader(tag.UDim2, readUDim2)
setReader(tag.BrickColor, readBrickColor)
setReader(tag.EnumItem, readEnumItem)
setReader(tag.NumberRange, readNumberRange)
setReader(tag.Rect, readRect)
setReader(tag.DateTime, readDateTime)
setReader(tag.ColorSequence, readColorSequence)
setReader(tag.NumberSequence, readNumberSequence)
setReader(tag.Vector2int16, readVector2int16)
setReader(tag.Vector3int16, readVector3int16)

function readValue(depth)
	local valueTag = buffer.readu8(source, position)
	position += 1
	if valueTag >= smallIntBase then
		return valueTag - smallIntBase
	elseif valueTag >= shortStringRefBase then
		local index = valueTag - shortStringRefBase + 1
		if index > sourceStringCount then
			error('string reference out of range', 0)
		end

		return sourceStrings[index]
	end

	local reader = dynamicReaders[valueTag + 1]
	if not reader then
		error('unknown value tag ' .. valueTag, 0)
	end

	return reader(depth)
end

local function define(name, minSize, write, read)
	local typeObject = { name = name, minSize = minSize, write = write, read = read }
	types[name] = typeObject
	return typeObject
end

local function readInstance()
	local value = readRef()
	if typeof(value) ~= 'Instance' then
		error('expected Instance', 0)
	end

	return value
end

define('u8', 1, writeU8, readU8)
define('u16', 2, writeU16, readU16)
define('u32', 4, writeU32, readU32)
define('i8', 1, writeI8, readI8)
define('i16', 2, writeI16, readI16)
define('i32', 4, writeI32, readI32)
define('f32', 4, writeF32, readFiniteF32)
define('f64', 8, writeF64, readFiniteF64)
define('uint', 1, writeVarUInt, readVarUInt)
define('int', 1, writeVarInt, readVarInt)
define('bool', 1, function(value)
	writeU8(if value then 1 else 0)
end, function()
	local value = readU8()
	if value > 1 then
		error('invalid boolean', 0)
	end

	return value == 1
end)
define('string', 1, writeRawString, readRawString)
define('buffer', 1, writeRawBuffer, readRawBuffer)
define('vector3', 12, writeVector3, readFiniteVector3)
define('vector2', 8, writeVector2, readFiniteVector2)
define('cframe', 28, writeCFrame, readFiniteCFrame)
define('color3', 3, writeColor3, readColor3)
define('udim', 8, writeUDim, readUDim)
define('udim2', 16, writeUDim2, readUDim2)
define('brickcolor', 1, writeBrickColor, readBrickColor)
define('enumitem', 2, writeEnumItem, readEnumItem)
define('numberrange', 8, writeNumberRange, readNumberRange)
define('rect', 16, writeRect, readRect)
define('datetime', 1, writeDateTime, readDateTime)
define('colorsequence', 1, writeColorSequence, readColorSequence)
define('numbersequence', 1, writeNumberSequence, readNumberSequence)
define('vector2int16', 4, writeVector2int16, readVector2int16)
define('vector3int16', 6, writeVector3int16, readVector3int16)
define('instance', 1, writeRef, readInstance)
define('player', 1, writeRef, function()
	local value = readRef()
	if typeof(value) ~= 'Instance' or not value:IsA('Player') then
		error('expected Player', 0)
	end

	return value
end)
define('any', 1, function(value)
	writeValue(value, 0)
end, function()
	return readValue(0)
end)
types.boolean = types.bool
types.float = types.f64
types.unknown = types.any

function codec.optional(inner)
	local innerWrite, innerRead = inner.write, inner.read
	return {
		name = inner.name .. '?',
		minSize = 1,
		write = function(value)
			if value == nil then
				writeU8(0)
			else
				writeU8(1)
				innerWrite(value)
			end
		end,
		read = function()
			local flag = readU8()
			if flag == 0 then
				return nil
			elseif flag == 1 then
				return innerRead()
			end

			error('invalid optional flag', 0)
		end,
	}
end

function codec.array(inner, maxLength)
	local innerWrite, innerRead, innerSize = inner.write, inner.read, inner.minSize
	local cap = maxLength or (if innerSize > 0 then maxSafeInteger else maxUnboundedCount)
	return {
		name = inner.name .. '[]',
		minSize = 1,
		write = function(value)
			local count = #value
			if count > cap then
				error('array longer than ' .. cap, 0)
			end

			writeVarUInt(count)
			for index = 1, count do
				innerWrite(value[index])
			end
		end,
		read = function()
			local count = readCount(innerSize, cap)
			local result = table.create(count)
			for index = 1, count do
				result[index] = innerRead()
			end

			return result
		end,
	}
end

function codec.map(keyType, valueType, maxCount)
	local keyWrite, keyRead, valueWrite, valueRead = keyType.write, keyType.read, valueType.write, valueType.read
	local entrySize = keyType.minSize + valueType.minSize
	local cap = maxCount or (if entrySize > 0 then maxSafeInteger else maxUnboundedCount)
	return {
		name = 'map',
		minSize = 1,
		write = function(value)
			local count = 0
			for _ in next, value do
				count += 1
			end

			if count > cap then
				error('map larger than ' .. cap, 0)
			end

			writeVarUInt(count)
			for key, entry in next, value do
				keyWrite(key)
				valueWrite(entry)
			end
		end,
		read = function()
			local count = readCount(entrySize, cap)
			local result = {}
			for _ = 1, count do
				local key = keyRead()
				if key == nil or key ~= key then
					error('invalid map key', 0)
				end

				result[key] = valueRead()
			end

			return result
		end,
	}
end

function codec.struct(fields)
	local count = #fields
	local names = table.create(count)
	local writers = table.create(count)
	local readers = table.create(count)
	local minSize = 0
	for index, field in fields do
		names[index] = field[1]
		writers[index] = field[2].write
		readers[index] = field[2].read
		minSize += field[2].minSize
	end

	return {
		name = 'struct',
		minSize = minSize,
		write = function(value)
			for index = 1, count do
				writers[index](value[names[index]])
			end
		end,
		read = function()
			local result = {}
			for index = 1, count do
				result[names[index]] = readers[index]()
			end

			return result
		end,
	}
end

function codec.enum(values)
	assert(#values > 0 and #values <= 256, 'enum needs 1 to 256 values')
	local indexByValue = {}
	for index, value in values do
		indexByValue[value] = index - 1
	end

	return {
		name = 'enum',
		minSize = 1,
		write = function(value)
			local index = indexByValue[value]
			if index == nil then
				error('invalid enum value ' .. tostring(value), 0)
			end

			writeU8(index)
		end,
		read = function()
			local value = values[readU8() + 1]
			if value == nil then
				error('invalid enum index', 0)
			end

			return value
		end,
	}
end

function codec.enumType(enumType)
	local enumName = enumTypeName(enumType)
	return {
		name = 'Enum.' .. enumName,
		minSize = 1,
		write = function(value)
			if typeof(value) ~= 'EnumItem' or value.EnumType ~= enumType then
				error('expected Enum.' .. enumName, 0)
			end

			writeVarInt(value.Value)
		end,
		read = function()
			return lookupEnumItem(enumName, readVarInt())
		end,
	}
end

function codec.boundedString(maxLength)
	return {
		name = 'string',
		minSize = 1,
		write = function(value)
			if #value > maxLength then
				error('string longer than ' .. maxLength, 0)
			end

			writeRawString(value)
		end,
		read = function()
			local length = readVarUInt()
			if length > maxLength or length > limit - position then
				error('string too long', 0)
			end

			local value = buffer.readstring(source, position, length)
			position += length
			return value
		end,
	}
end

function codec.boundedBuffer(maxLength)
	return {
		name = 'buffer',
		minSize = 1,
		write = function(value)
			if buffer.len(value) > maxLength then
				error('buffer longer than ' .. maxLength, 0)
			end

			writeRawBuffer(value)
		end,
		read = function()
			local length = readVarUInt()
			if length > maxLength or length > limit - position then
				error('buffer too long', 0)
			end

			local value = buffer.create(length)
			buffer.copy(value, 0, source, position, length)
			position += length
			return value
		end,
	}
end

function codec.instanceOf(className)
	return {
		name = className,
		minSize = 1,
		write = writeRef,
		read = function()
			local value = readRef()
			if typeof(value) ~= 'Instance' or not value:IsA(className) then
				error('expected ' .. className, 0)
			end

			return value
		end,
	}
end

function codec.tuple(list)
	local count = #list
	local writers = table.create(count)
	local readers = table.create(count)
	for index, typeObject in list do
		writers[index] = typeObject.write
		readers[index] = typeObject.read
	end

	return { count = count, writers = writers, readers = readers }
end

local function beginEncode()
	cursor = 0
	if refCount > 0 then
		table.clear(refs)
		refCount = 0
	end

	if stringCount > 0 then
		table.clear(stringIndex)
		stringCount = 0
	end
end

local function beginDecode(sourceBuffer, start, finish, refList, refBase, refLength)
	source = sourceBuffer
	position = start
	limit = finish
	sourceRefs = refList
	sourceRefBase = refBase
	sourceRefCount = refLength
	sourceStringCount = 0
end

local function endDecode()
	if position ~= limit then
		error('payload length mismatch', 0)
	end

	sourceRefs = emptyRefs
end

function codec.encodeArgs(tuple, ...)
	beginEncode()
	if tuple then
		local writers = tuple.writers
		local count = tuple.count
		if count == 1 then
			writers[1]((...))
		elseif count > 1 then
			local args = { ... }
			for index = 1, count do
				writers[index](args[index])
			end
		end
	else
		local count = select('#', ...)
		writeVarUInt(count)
		if count == 1 then
			writeValue((...), 0)
		elseif count > 1 then
			local args = { ... }
			for index = 1, count do
				writeValue(args[index], 0)
			end
		end
	end

	return cursor, refCount
end

function codec.encodeString(value)
	beginEncode()
	if cursor + #value > capacity then
		grow(#value)
	end

	buffer.writestring(scratch, 0, value)
	cursor = #value
	return cursor, 0
end

function codec.getScratch()
	return scratch, refs
end

function codec.decodeArgs(tuple, sourceBuffer, start, finish, refList, refBase, refLength)
	beginDecode(sourceBuffer, start, finish, refList, refBase, refLength)
	local count, args
	if tuple then
		count = tuple.count
		local readers = tuple.readers
		args = table.create(count)
		for index = 1, count do
			args[index] = readers[index]()
		end
	else
		count = readCount(1, maxSafeInteger)
		args = table.create(count)
		for index = 1, count do
			args[index] = readValue(0)
		end
	end

	endDecode()
	return count, args
end

local function snapshot()
	local result = buffer.create(cursor)
	buffer.copy(result, 0, scratch, 0, cursor)
	return result, if refCount > 0 then table.move(refs, 1, refCount, 1, {}) else nil
end

local function decodeWith(read, sourceBuffer, refList)
	beginDecode(sourceBuffer, 0, buffer.len(sourceBuffer), refList or emptyRefs, 0, if refList then refList.n or #refList else 0)
	local value = read()
	endDecode()
	return value
end

local function readDynamic()
	return readValue(0)
end

function codec.encode(typeObject, value)
	beginEncode()
	typeObject.write(value)
	return snapshot()
end

function codec.decode(typeObject, sourceBuffer, refList)
	if typeof(sourceBuffer) ~= 'buffer' then
		return false, 'expected buffer'
	end

	return pcall(decodeWith, typeObject.read, sourceBuffer, refList)
end

function codec.pack(value)
	beginEncode()
	writeValue(value, 0)
	return snapshot()
end

function codec.unpack(sourceBuffer, refList)
	if typeof(sourceBuffer) ~= 'buffer' then
		warn('codec unpack failed: expected buffer')
		return nil
	end

	local success, result = pcall(decodeWith, readDynamic, sourceBuffer, refList)
	if success then
		return result
	end

	warn('codec unpack failed: ' .. tostring(result))
	return nil
end

function codec.internStrings(names)
	for _, name in names do
		if not internedIndex[name] then
			internedCount += 1
			internedIndex[name] = internedCount
			internedStrings[internedCount] = name
		end
	end
end

function codec.defineSchema(name, fields)
	assert(schemasByName[name] == nil, 'codec schema "' .. name .. '" already defined')
	local structFields = table.create(#fields)
	for index, field in fields do
		local typeObject = types[field.type]
		assert(typeObject, 'codec unknown schema field type "' .. tostring(field.type) .. '"')
		structFields[index] = { field.name, typeObject }
	end

	local structType = codec.struct(structFields)
	local schema = { type = structType }
	function schema.pack(data)
		beginEncode()
		local success, result = pcall(structType.write, data)
		if not success then
			error('codec schema pack failed for "' .. name .. '": ' .. tostring(result), 0)
		end

		return snapshot()
	end

	function schema.unpack(sourceBuffer, refList)
		local success, result = codec.decode(structType, sourceBuffer, refList)
		if success then
			return result
		end

		warn('codec schema unpack failed for "' .. name .. '": ' .. tostring(result))
		return nil
	end

	schemasByName[name] = schema
	return schema
end

return codec
