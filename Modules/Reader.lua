local bufferReader = {}
bufferReader.__index = bufferReader

function bufferReader.new(sourceBuffer)
	return setmetatable({ buffer = sourceBuffer, position = 0, length = buffer.len(sourceBuffer) }, bufferReader)
end

function bufferReader:reset(sourceBuffer)
	self.buffer = sourceBuffer
	self.position = 0
	self.length = buffer.len(sourceBuffer)
end

function bufferReader:remaining()
	return self.length - self.position
end

function bufferReader:readUInt8()
	local value = buffer.readu8(self.buffer, self.position)
	self.position += 1
	return value
end

function bufferReader:readUInt16()
	local value = buffer.readu16(self.buffer, self.position)
	self.position += 2
	return value
end

function bufferReader:readUInt32()
	local value = buffer.readu32(self.buffer, self.position)
	self.position += 4
	return value
end

function bufferReader:readInt32()
	local value = buffer.readi32(self.buffer, self.position)
	self.position += 4
	return value
end

function bufferReader:readFloat32()
	local value = buffer.readf32(self.buffer, self.position)
	self.position += 4
	return value
end

function bufferReader:readFloat64()
	local value = buffer.readf64(self.buffer, self.position)
	self.position += 8
	return value
end

function bufferReader:readVarUInt()
	local sourceBuffer = self.buffer
	local position = self.position
	local result = 0
	local scale = 1
	for _ = 1, 8 do
		local byteValue = buffer.readu8(sourceBuffer, position)
		position += 1
		if byteValue < 128 then
			self.position = position
			return result + byteValue * scale
		end

		result += (byteValue - 128) * scale
		scale *= 128
	end

	error('varuint too long', 2)
end

function bufferReader:readVarInt()
	local zigzagged = self:readVarUInt()
	if zigzagged % 2 == 0 then
		return zigzagged // 2
	end

	return -(zigzagged + 1) // 2
end

function bufferReader:readString()
	local byteLength = self:readVarUInt()
	if byteLength > self.length - self.position then
		error('string length exceeds buffer', 2)
	end

	local value = buffer.readstring(self.buffer, self.position, byteLength)
	self.position += byteLength
	return value
end

function bufferReader:readBuffer()
	local byteLength = self:readVarUInt()
	if byteLength > self.length - self.position then
		error('buffer length exceeds buffer', 2)
	end

	local result = buffer.create(byteLength)
	buffer.copy(result, 0, self.buffer, self.position, byteLength)
	self.position += byteLength
	return result
end

return bufferReader
