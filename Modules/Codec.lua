local bufferWriter = require(script.Parent.Writer)
local bufferReader = require(script.Parent.Reader)
local codec = {}
local tagNil = 0
local tagFalse = 1
local tagTrue = 2
local tagInteger = 3
local tagFloat = 4
local tagString = 5
local tagVector3 = 6
local tagArray = 7
local tagDictionary = 8
local tagBuffer = 9
local tagExtended = 10
local extInstance = 1
local extPlayer = 2
local extCFrame = 3
local extColor3 = 4
local extBrickColor = 5
local extUDim = 6
local extUDim2 = 7
local extVector2 = 8
local extVector2int16 = 9
local extVector3int16 = 10
local extEnumItem = 11
local extNumberRange = 12
local extRect = 13
local extDateTime = 14
local extColorSequence = 15
local extNumberSequence = 16
local players = game:GetService('Players')
local smallIntBase = 11
local schemaBase = 224
local smallIntMax = schemaBase - 1 - smallIntBase
local writeValue
local readValue
local writerPool = {}
local readerPool = {}
codec._globalStringIndexByName = {}
codec._globalStringByIndex = {}
codec._globalStringCount = 0
codec._schemasById = {}
codec._schemasByName = {}
local nextSchemaId = 0

local function acquireWriter()
	local writer = table.remove(writerPool)
	if writer then
		writer:reset()
		return writer
	end
	return bufferWriter.new()
end

local function releaseWriter(writer)
	if #writerPool < 32 then
		table.insert(writerPool, writer)
	end
end

local function acquireReader(sourceBuffer)
	local reader = table.remove(readerPool)
	if reader then
		reader:reset(sourceBuffer)
		return reader
	end
	return bufferReader.new(sourceBuffer)
end

local function releaseReader(reader)
	if #readerPool < 32 then
		table.insert(readerPool, reader)
	end
end

local function zigzagEncode(value)
	if value >= 0 then
		return value * 2
	end
	return (-value) * 2 - 1
end

local function zigzagDecode(zigzagged)
	if zigzagged % 2 == 0 then
		return zigzagged // 2
	end
	return -((zigzagged + 1) // 2)
end

local function isSequentialArray(candidateTable)
	local elementCount = 0
	for key in pairs(candidateTable) do
		elementCount += 1
		if type(key) ~= 'number' or key % 1 ~= 0 or key < 1 then
			return false, elementCount
		end
	end
	return elementCount == #candidateTable, elementCount
end


function codec.internStrings(names)
	for _, name in ipairs(names) do
		if not codec._globalStringIndexByName[name] then
			codec._globalStringCount += 1
			codec._globalStringIndexByName[name] = codec._globalStringCount
			codec._globalStringByIndex[codec._globalStringCount] = name
		end
	end
end

local function newWriteContext()
	return {
		localIndexByName = {},
		nextLocalIndex = codec._globalStringCount + 1,
	}
end

local function newReadContext()
	return {
		localByIndex = {},
	}
end

local function writeInternedString(writer, ctx, value)
	local globalIndex = codec._globalStringIndexByName[value]
	if globalIndex then
		writer:writeVarUInt(globalIndex)
		return
	end
	local localIndex = ctx.localIndexByName[value]
	if localIndex then
		writer:writeVarUInt(localIndex)
		return
	end
	writer:writeVarUInt(0)
	writer:writeString(value)
	ctx.localIndexByName[value] = ctx.nextLocalIndex
	ctx.nextLocalIndex += 1
end

local function readInternedString(reader, ctx)
	local marker = reader:readVarUInt()
	if marker == 0 then
		local value = reader:readString()
		local assignedIndex = codec._globalStringCount + 1 + ctx.localCount
		ctx.localByIndex[assignedIndex] = value
		ctx.localCount += 1
		return value
	end
	if marker <= codec._globalStringCount then
		return codec._globalStringByIndex[marker]
	end
	return ctx.localByIndex[marker]
end

local function writeInstancePath(writer, ctx, instance)
	local segments = {}
	local current = instance
	while current and current ~= game do
		table.insert(segments, 1, current.Name)
		current = current.Parent
	end
	writer:writeVarUInt(#segments)
	for _, segment in ipairs(segments) do
		writeInternedString(writer, ctx, segment)
	end
end

local function readInstancePath(reader, ctx)
	local segmentCount = reader:readVarUInt()
	if segmentCount == 0 then
		return nil
	end
	local rootName = readInternedString(reader, ctx)
	local success, current = pcall(game.GetService, game, rootName)
	if not success or not current then
		current = game:FindFirstChild(rootName)
	end
	for index = 2, segmentCount do
		local segmentName = readInternedString(reader, ctx)
		current = current and current:FindFirstChild(segmentName)
	end
	return current
end

local function writeUDimValue(writer, value)
	writer:writeFloat32(value.Scale)
	writer:writeInt32(math.floor(value.Offset + 0.5))
end

local function readUDimValue(reader)
	return UDim.new(reader:readFloat32(), reader:readInt32())
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
	else
		local s = math.sqrt(1 + m22 - m00 - m11) * 2
		return (m02 + m20) / s, (m12 + m21) / s, s / 4, (m10 - m01) / s
	end
end

writeValue = function(writer, ctx, value)
	local valueType = typeof(value)
	if value == nil then
		writer:writeUInt8(tagNil)
	elseif valueType == 'boolean' then
		writer:writeUInt8(value and tagTrue or tagFalse)
	elseif valueType == 'number' then
		if value % 1 == 0 and value >= -2147483648 and value <= 2147483647 then
			local zigzagged = zigzagEncode(value)
			if zigzagged <= smallIntMax then
				writer:writeUInt8(smallIntBase + zigzagged)
			else
				writer:writeUInt8(tagInteger)
				writer:writeVarUInt(zigzagged)
			end
		else
			writer:writeUInt8(tagFloat)
			writer:writeFloat64(value)
		end
	elseif valueType == 'string' then
		writer:writeUInt8(tagString)
		writeInternedString(writer, ctx, value)
	elseif valueType == 'Vector3' then
		writer:writeUInt8(tagVector3)
		writer:writeFloat32(value.X)
		writer:writeFloat32(value.Y)
		writer:writeFloat32(value.Z)
	elseif valueType == 'buffer' then
		writer:writeUInt8(tagBuffer)
		writer:writeBuffer(value)
	elseif valueType == 'Instance' then
		if value:IsA('Player') then
			writer:writeUInt8(tagExtended)
			writer:writeUInt8(extPlayer)
			writer:writeVarUInt(value.UserId)
		else
			writer:writeUInt8(tagExtended)
			writer:writeUInt8(extInstance)
			writeInstancePath(writer, ctx, value)
		end
	elseif valueType == 'CFrame' then
		writer:writeUInt8(tagExtended)
		writer:writeUInt8(extCFrame)
		writer:writeFloat32(value.X)
		writer:writeFloat32(value.Y)
		writer:writeFloat32(value.Z)
		local qx, qy, qz, qw = cframeToQuaternion(value)
		
		writer:writeFloat32(qx)
		writer:writeFloat32(qy)
		writer:writeFloat32(qz)
		writer:writeFloat32(qw)
	elseif valueType == 'Color3' then
		writer:writeUInt8(tagExtended)
		writer:writeUInt8(extColor3)
		writer:writeUInt8(math.floor(value.R * 255 + 0.5))
		writer:writeUInt8(math.floor(value.G * 255 + 0.5))
		writer:writeUInt8(math.floor(value.B * 255 + 0.5))
	elseif valueType == 'BrickColor' then
		writer:writeUInt8(tagExtended)
		writer:writeUInt8(extBrickColor)
		writer:writeVarUInt(value.Number)
	elseif valueType == 'UDim' then
		writer:writeUInt8(tagExtended)
		writer:writeUInt8(extUDim)
		writeUDimValue(writer, value)
	elseif valueType == 'UDim2' then
		writer:writeUInt8(tagExtended)
		writer:writeUInt8(extUDim2)
		writeUDimValue(writer, value.X)
		writeUDimValue(writer, value.Y)
	elseif valueType == 'Vector2' then
		writer:writeUInt8(tagExtended)
		writer:writeUInt8(extVector2)
		writer:writeFloat32(value.X)
		writer:writeFloat32(value.Y)
	elseif valueType == 'Vector2int16' then
		writer:writeUInt8(tagExtended)
		writer:writeUInt8(extVector2int16)
		writer:writeInt32(value.X)
		writer:writeInt32(value.Y)
	elseif valueType == 'Vector3int16' then
		writer:writeUInt8(tagExtended)
		writer:writeUInt8(extVector3int16)
		writer:writeInt32(value.X)
		writer:writeInt32(value.Y)
		writer:writeInt32(value.Z)
	elseif valueType == 'EnumItem' then
		writer:writeUInt8(tagExtended)
		writer:writeUInt8(extEnumItem)
		writeInternedString(writer, ctx, tostring(value.EnumType))
		writeInternedString(writer, ctx, value.Name)
	elseif valueType == 'NumberRange' then
		writer:writeUInt8(tagExtended)
		writer:writeUInt8(extNumberRange)
		writer:writeFloat32(value.Min)
		writer:writeFloat32(value.Max)
	elseif valueType == 'Rect' then
		writer:writeUInt8(tagExtended)
		writer:writeUInt8(extRect)
		writer:writeFloat32(value.Min.X)
		writer:writeFloat32(value.Min.Y)
		writer:writeFloat32(value.Max.X)
		writer:writeFloat32(value.Max.Y)
	elseif valueType == 'DateTime' then
		writer:writeUInt8(tagExtended)
		writer:writeUInt8(extDateTime)
		writer:writeVarUInt(value.UnixTimestampMillis)
	elseif valueType == 'ColorSequence' then
		writer:writeUInt8(tagExtended)
		writer:writeUInt8(extColorSequence)
		writer:writeVarUInt(#value.Keypoints)
		
		for _, keypoint in ipairs(value.Keypoints) do
			writer:writeFloat32(keypoint.Time)
			writer:writeUInt8(math.floor(keypoint.Value.R * 255 + 0.5))
			writer:writeUInt8(math.floor(keypoint.Value.G * 255 + 0.5))
			writer:writeUInt8(math.floor(keypoint.Value.B * 255 + 0.5))
		end
	elseif valueType == 'NumberSequence' then
		writer:writeUInt8(tagExtended)
		writer:writeUInt8(extNumberSequence)
		writer:writeVarUInt(#value.Keypoints)
		
		for _, keypoint in ipairs(value.Keypoints) do
			writer:writeFloat32(keypoint.Time)
			writer:writeFloat32(keypoint.Value)
			writer:writeFloat32(keypoint.Envelope)
		end
	elseif valueType == 'table' then
		local isArray, elementCount = isSequentialArray(value)
		if isArray then
			writer:writeUInt8(tagArray)
			writer:writeVarUInt(elementCount)
			
			for index = 1, elementCount do
				writeValue(writer, ctx, value[index])
			end
		else
			writer:writeUInt8(tagDictionary)
			writer:writeVarUInt(elementCount)
			
			for key, entryValue in pairs(value) do
				writeInternedString(writer, ctx, type(key) == 'string' and key or tostring(key))
				writeValue(writer, ctx, entryValue)
			end
		end
	else
		error('codec unsupported type ' .. valueType, 0)
	end
end

readValue = function(reader, ctx)
	local tag = reader:readUInt8()
	if tag >= smallIntBase and tag < schemaBase then
		return zigzagDecode(tag - smallIntBase)
	elseif tag == tagNil then
		return nil
	elseif tag == tagFalse then
		return false
	elseif tag == tagTrue then
		return true
	elseif tag == tagInteger then
		return zigzagDecode(reader:readVarUInt())
	elseif tag == tagFloat then
		return reader:readFloat64()
	elseif tag == tagString then
		return readInternedString(reader, ctx)
	elseif tag == tagVector3 then
		return Vector3.new(reader:readFloat32(), reader:readFloat32(), reader:readFloat32())
	elseif tag == tagBuffer then
		return reader:readBuffer()
	elseif tag == tagArray then
		local elementCount = reader:readVarUInt()
		local result = table.create(elementCount)
		
		for index = 1, elementCount do
			result[index] = readValue(reader, ctx)
		end
		
		return result
	elseif tag == tagDictionary then
		local elementCount = reader:readVarUInt()
		local result = {}
		
		for _ = 1, elementCount do
			local key = readInternedString(reader, ctx)
			result[key] = readValue(reader, ctx)
		end
		
		return result
	elseif tag == tagExtended then
		local extTag = reader:readUInt8()
		
		if extTag == extInstance then
			return readInstancePath(reader, ctx)
		elseif extTag == extPlayer then
			return players:GetPlayerByUserId(reader:readVarUInt())
		elseif extTag == extCFrame then
			local px, py, pz = reader:readFloat32(), reader:readFloat32(), reader:readFloat32()
			local qx, qy, qz, qw = reader:readFloat32(), reader:readFloat32(), reader:readFloat32(), reader:readFloat32()
			
			return CFrame.new(px, py, pz, qx, qy, qz, qw)
		elseif extTag == extColor3 then
			return Color3.fromRGB(reader:readUInt8(), reader:readUInt8(), reader:readUInt8())
		elseif extTag == extBrickColor then
			return BrickColor.new(reader:readVarUInt())
		elseif extTag == extUDim then
			return readUDimValue(reader)
		elseif extTag == extUDim2 then
			local x = readUDimValue(reader)
			local y = readUDimValue(reader)
			
			return UDim2.new(x.Scale, x.Offset, y.Scale, y.Offset)
		elseif extTag == extVector2 then
			return Vector2.new(reader:readFloat32(), reader:readFloat32())
		elseif extTag == extVector2int16 then
			return Vector2int16.new(reader:readInt32(), reader:readInt32())
		elseif extTag == extVector3int16 then
			return Vector3int16.new(reader:readInt32(), reader:readInt32(), reader:readInt32())
		elseif extTag == extEnumItem then
			local enumTypeName = readInternedString(reader, ctx)
			local itemName = readInternedString(reader, ctx)
			
			return Enum[enumTypeName][itemName]
		elseif extTag == extNumberRange then
			return NumberRange.new(reader:readFloat32(), reader:readFloat32())
		elseif extTag == extRect then
			local minX, minY, maxX, maxY = reader:readFloat32(), reader:readFloat32(), reader:readFloat32(), reader:readFloat32()
			
			return Rect.new(minX, minY, maxX, maxY)
		elseif extTag == extDateTime then
			return DateTime.fromUnixTimestampMillis(reader:readVarUInt())
		elseif extTag == extColorSequence then
			local keypointCount = reader:readVarUInt()
			local keypoints = table.create(keypointCount)
			
			for index = 1, keypointCount do
				local time = reader:readFloat32()
				local color = Color3.fromRGB(reader:readUInt8(), reader:readUInt8(), reader:readUInt8())
				keypoints[index] = ColorSequenceKeypoint.new(time, color)
			end
			
			return ColorSequence.new(keypoints)
		elseif extTag == extNumberSequence then
			local keypointCount = reader:readVarUInt()
			local keypoints = table.create(keypointCount)
			
			for index = 1, keypointCount do
				local time = reader:readFloat32()
				local value = reader:readFloat32()
				local envelope = reader:readFloat32()
				keypoints[index] = NumberSequenceKeypoint.new(time, value, envelope)
			end
			
			return NumberSequence.new(keypoints)
		else
			error('codec unknown extended tag ' .. extTag .. ' while decoding', 0)
		end
	elseif tag >= schemaBase then
		local schema = codec._schemasById[tag - schemaBase]
		
		if not schema then
			error('codec unknown schema id ' .. (tag - schemaBase), 0)
		end
		
		return schema._decodeFields(reader)
	else
		error('codec unknown tag ' .. tag .. ' while decoding', 0)
	end
end

function codec.pack(data)
	local writer = acquireWriter()
	local ctx = newWriteContext()
	local success, result = pcall(writeValue, writer, ctx, data)
	
	if not success then
		releaseWriter(writer)
		error('codec pack failed: ' .. tostring(result), 0)
	end
	
	local packedBuffer = writer:toBuffer()
	releaseWriter(writer)
	return packedBuffer
end

function codec.unpack(sourceBuffer)
	local reader = acquireReader(sourceBuffer)
	local ctx = newReadContext()
	ctx.localCount = 0
	local success, result = pcall(readValue, reader, ctx)
	releaseReader(reader)
	
	if success then
		return result
	end
	
	warn('codec unpack failed: ' .. tostring(result))
	return nil
end

local fieldWriters = {
	int = function(writer, ctx, value)
		writer:writeVarUInt(zigzagEncode(value))
	end,
	
	float = function(writer, ctx, value)
		writer:writeFloat64(value)
	end,
	
	string = function(writer, ctx, value)
		writeInternedString(writer, ctx, value)
	end,
	
	bool = function(writer, ctx, value)
		writer:writeUInt8(value and 1 or 0)
	end,
	
	vector3 = function(writer, ctx, value)
		writer:writeFloat32(value.X)
		writer:writeFloat32(value.Y)
		writer:writeFloat32(value.Z)
	end,
	
	buffer = function(writer, ctx, value)
		writer:writeBuffer(value)
	end,
	
	any = function(writer, ctx, value)
		writeValue(writer, ctx, value)
	end,
	
	instance = function(writer, ctx, value)
		writeInstancePath(writer, ctx, value)
	end,
	
	player = function(writer, ctx, value)
		writer:writeVarUInt(value.UserId)
	end,
	
	cframe = function(writer, ctx, value)
		writer:writeFloat32(value.X)
		writer:writeFloat32(value.Y)
		writer:writeFloat32(value.Z)
		local qx, qy, qz, qw = cframeToQuaternion(value)
		
		writer:writeFloat32(qx)
		writer:writeFloat32(qy)
		writer:writeFloat32(qz)
		writer:writeFloat32(qw)
	end,
	
	color3 = function(writer, ctx, value)
		writer:writeUInt8(math.floor(value.R * 255 + 0.5))
		writer:writeUInt8(math.floor(value.G * 255 + 0.5))
		writer:writeUInt8(math.floor(value.B * 255 + 0.5))
	end,
	
	brickcolor = function(writer, ctx, value)
		writer:writeVarUInt(value.Number)
	end,
	
	udim = function(writer, ctx, value)
		writeUDimValue(writer, value)
	end,
	
	udim2 = function(writer, ctx, value)
		writeUDimValue(writer, value.X)
		writeUDimValue(writer, value.Y)
	end,
	
	vector2 = function(writer, ctx, value)
		writer:writeFloat32(value.X)
		writer:writeFloat32(value.Y)
	end,
	
	vector2int16 = function(writer, ctx, value)
		writer:writeInt32(value.X)
		writer:writeInt32(value.Y)
	end,
	
	vector3int16 = function(writer, ctx, value)
		writer:writeInt32(value.X)
		writer:writeInt32(value.Y)
		writer:writeInt32(value.Z)
	end,
	
	enumitem = function(writer, ctx, value)
		writeInternedString(writer, ctx, tostring(value.EnumType))
		writeInternedString(writer, ctx, value.Name)
	end,
	
	numberrange = function(writer, ctx, value)
		writer:writeFloat32(value.Min)
		writer:writeFloat32(value.Max)
	end,
	
	rect = function(writer, ctx, value)
		writer:writeFloat32(value.Min.X)
		writer:writeFloat32(value.Min.Y)
		writer:writeFloat32(value.Max.X)
		writer:writeFloat32(value.Max.Y)
	end,
	
	datetime = function(writer, ctx, value)
		writer:writeVarUInt(value.UnixTimestampMillis)
	end,
	
	colorsequence = function(writer, ctx, value)
		writer:writeVarUInt(#value.Keypoints)
		
		for _, keypoint in ipairs(value.Keypoints) do
			writer:writeFloat32(keypoint.Time)
			writer:writeUInt8(math.floor(keypoint.Value.R * 255 + 0.5))
			writer:writeUInt8(math.floor(keypoint.Value.G * 255 + 0.5))
			writer:writeUInt8(math.floor(keypoint.Value.B * 255 + 0.5))
		end
	end,
	
	numbersequence = function(writer, ctx, value)
		writer:writeVarUInt(#value.Keypoints)
		
		for _, keypoint in ipairs(value.Keypoints) do
			writer:writeFloat32(keypoint.Time)
			writer:writeFloat32(keypoint.Value)
			writer:writeFloat32(keypoint.Envelope)
		end
	end,
}

local fieldReaders = {
	int = function(reader, ctx)
		return zigzagDecode(reader:readVarUInt())
	end,
	
	float = function(reader, ctx)
		return reader:readFloat64()
	end,
	
	string = function(reader, ctx)
		return readInternedString(reader, ctx)
	end,
	
	bool = function(reader, ctx)
		return reader:readUInt8() == 1
	end,
	
	vector3 = function(reader, ctx)
		return Vector3.new(reader:readFloat32(), reader:readFloat32(), reader:readFloat32())
	end,
	
	buffer = function(reader, ctx)
		return reader:readBuffer()
	end,
	
	any = function(reader, ctx)
		return readValue(reader, ctx)
	end,
	
	instance = function(reader, ctx)
		return readInstancePath(reader, ctx)
	end,
	
	player = function(reader, ctx)
		return players:GetPlayerByUserId(reader:readVarUInt())
	end,
	
	cframe = function(reader, ctx)
		local px, py, pz = reader:readFloat32(), reader:readFloat32(), reader:readFloat32()
		local qx, qy, qz, qw = reader:readFloat32(), reader:readFloat32(), reader:readFloat32(), reader:readFloat32()
		
		return CFrame.new(px, py, pz, qx, qy, qz, qw)
	end,
	
	color3 = function(reader, ctx)
		return Color3.fromRGB(reader:readUInt8(), reader:readUInt8(), reader:readUInt8())
	end,
	
	brickcolor = function(reader, ctx)
		return BrickColor.new(reader:readVarUInt())
	end,
	
	udim = function(reader, ctx)
		return readUDimValue(reader)
	end,
	
	udim2 = function(reader, ctx)
		local x = readUDimValue(reader)
		local y = readUDimValue(reader)
		
		return UDim2.new(x.Scale, x.Offset, y.Scale, y.Offset)
	end,
	
	vector2 = function(reader, ctx)
		return Vector2.new(reader:readFloat32(), reader:readFloat32())
	end,
	
	vector2int16 = function(reader, ctx)
		return Vector2int16.new(reader:readInt32(), reader:readInt32())
	end,
	
	vector3int16 = function(reader, ctx)
		return Vector3int16.new(reader:readInt32(), reader:readInt32(), reader:readInt32())
	end,
	
	enumitem = function(reader, ctx)
		local enumTypeName = readInternedString(reader, ctx)
		local itemName = readInternedString(reader, ctx)
		
		return Enum[enumTypeName][itemName]
	end,
	
	numberrange = function(reader, ctx)
		return NumberRange.new(reader:readFloat32(), reader:readFloat32())
	end,
	
	rect = function(reader, ctx)
		local minX, minY, maxX, maxY = reader:readFloat32(), reader:readFloat32(), reader:readFloat32(), reader:readFloat32()
		
		return Rect.new(minX, minY, maxX, maxY)
	end,
	
	datetime = function(reader, ctx)
		return DateTime.fromUnixTimestampMillis(reader:readVarUInt())
	end,
	
	colorsequence = function(reader, ctx)
		local keypointCount = reader:readVarUInt()
		local keypoints = table.create(keypointCount)
		
		for index = 1, keypointCount do
			local time = reader:readFloat32()
			local color = Color3.fromRGB(reader:readUInt8(), reader:readUInt8(), reader:readUInt8())
			keypoints[index] = ColorSequenceKeypoint.new(time, color)
		end
		
		return ColorSequence.new(keypoints)
	end,
	
	numbersequence = function(reader, ctx)
		local keypointCount = reader:readVarUInt()
		local keypoints = table.create(keypointCount)
		for index = 1, keypointCount do
			local time = reader:readFloat32()
			local value = reader:readFloat32()
			local envelope = reader:readFloat32()
			keypoints[index] = NumberSequenceKeypoint.new(time, value, envelope)
		end
		
		return NumberSequence.new(keypoints)
	end,
}

function codec.defineSchema(name, fields)
	assert(codec._schemasByName[name] == nil, 'codec schema "' .. name .. '" already defined')
	assert(nextSchemaId <= 255 - schemaBase, 'codec ran out of schema ids')
	for _, field in ipairs(fields) do
		assert(fieldWriters[field.type], 'codec unknown schema field type "' .. tostring(field.type) .. '"')
	end

	local schemaId = nextSchemaId
	nextSchemaId += 1
	local tagByte = schemaBase + schemaId
	local schema = {}

	schema._decodeFields = function(reader)
		local ctx = newReadContext()
		ctx.localCount = 0
		local result = {}
		for _, field in ipairs(fields) do
			result[field.name] = fieldReaders[field.type](reader, ctx)
		end
		return result
	end

	function schema.pack(data)
		local writer = acquireWriter()
		local ctx = newWriteContext()
		local success, result = pcall(function()
			writer:writeUInt8(tagByte)
			for _, field in ipairs(fields) do
				fieldWriters[field.type](writer, ctx, data[field.name])
			end
		end)

		if not success then
			releaseWriter(writer)
			error('codec schema pack failed for "' .. name .. '": ' .. tostring(result), 0)
		end

		local packedBuffer = writer:toBuffer()
		releaseWriter(writer)
		return packedBuffer
	end

	function schema.unpack(sourceBuffer)
		local reader = acquireReader(sourceBuffer)
		local success, result = pcall(function()
			local tag = reader:readUInt8()
			assert(tag == tagByte, 'codec schema mismatch decoding "' .. name .. '"')
			return schema._decodeFields(reader)
		end)

		releaseReader(reader)
		if success then
			return result
		end

		warn('codec schema unpack failed for "' .. name .. '": ' .. tostring(result))
		return nil
	end

	codec._schemasById[schemaId] = schema
	codec._schemasByName[name] = schema
	return schema
end

return codec