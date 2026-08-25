local bufferReader = {}
bufferReader.__index = bufferReader

function bufferReader.new(sourceBuffer)
	return setmetatable({ buffer = sourceBuffer, position = 0 }, bufferReader)
end

function bufferReader:reset(sourceBuffer)
	self.buffer = sourceBuffer
	self.position = 0
end

function bufferReader:readUInt8()
	local value = buffer.readu8(self.buffer, self.position)
	self.position += 1
	return value
end

function bufferReader:readInt32()
	local value = buffer.readi32(self.buffer, self.position)
	self.position += 4
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
	local shift = 0
	while true do
		local byteValue = buffer.readu8(sourceBuffer, position)
		position += 1
		result = bit32.bor(result, bit32.lshift(bit32.band(byteValue, 0x7F), shift))
		if bit32.band(byteValue, 0x80) == 0 then
			break
		end
		shift += 7
	end
	self.position = position
	return result
end

function bufferReader:readVarInt()
	local zigzagged = self:readVarUInt()
	if zigzagged % 2 == 0 then
		return zigzagged / 2
	end
	return -(zigzagged + 1) / 2
end

function bufferReader:readString()
	local byteLength = self:readVarUInt()
	local value = buffer.readstring(self.buffer, self.position, byteLength)
	self.position += byteLength
	return value
end

function bufferReader:readBuffer()
	local byteLength = self:readVarUInt()
	local result = buffer.create(byteLength)
	buffer.copy(result, 0, self.buffer, self.position, byteLength)
	self.position += byteLength
	return result
end

return bufferReader