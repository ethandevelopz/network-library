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
local smallIntBase = 10
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
		ctx.localByIndex[#ctx.localByIndex + 1] = value
		return value
	end
	if marker <= codec._globalStringCount then
		return codec._globalStringByIndex[marker]
	end
	return ctx.localByIndex[marker - codec._globalStringCount]
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
		warn('codec unsupported type ' .. valueType .. ', encoding as nil')
		writer:writeUInt8(tagNil)
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
	elseif tag >= schemaBase then
		local schema = codec._schemasById[tag - schemaBase]
		if not schema then
			error('codec unknown schema id ' .. (tag - schemaBase))
		end
		return schema._decodeFields(reader)
	else
		warn('codec unknown tag ' .. tag .. ' while decoding')
		return nil
	end
end

function codec.pack(data)
	local writer = acquireWriter()
	local ctx = newWriteContext()
	local success, result = pcall(writeValue, writer, ctx, data)
	if not success then
		warn('codec pack failed: ' .. tostring(result))
		releaseWriter(writer)
		return buffer.create(1)
	end
	local packedBuffer = writer:toBuffer()
	releaseWriter(writer)
	return packedBuffer
end

function codec.unpack(sourceBuffer)
	local reader = acquireReader(sourceBuffer)
	local ctx = newReadContext()
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
			warn('codec schema pack failed for "' .. name .. '": ' .. tostring(result))
			releaseWriter(writer)
			return buffer.create(1)
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
