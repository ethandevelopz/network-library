local bufferWriter = {}
bufferWriter.__index = bufferWriter

function bufferWriter.new()
	return setmetatable({ buffer = buffer.create(64), length = 0, capacity = 64 }, bufferWriter)
end

function bufferWriter:reset()
	self.length = 0
end

function bufferWriter:reserve(extraBytes)
	local requiredCapacity = self.length + extraBytes
	if requiredCapacity > self.capacity then
		local newCapacity = self.capacity * 2
		while newCapacity < requiredCapacity do
			newCapacity *= 2
		end
		local newBuffer = buffer.create(newCapacity)
		buffer.copy(newBuffer, 0, self.buffer, 0, self.length)
		self.buffer = newBuffer
		self.capacity = newCapacity
	end
end

function bufferWriter:writeUInt8(value)
	self:reserve(1)
	buffer.writeu8(self.buffer, self.length, value)
	self.length += 1
end

function bufferWriter:writeInt32(value)
	self:reserve(4)
	buffer.writei32(self.buffer, self.length, value)
	self.length += 4
end

function bufferWriter:writeUInt16(value)
	self:reserve(2)
	buffer.writeu16(self.buffer, self.length, value)
	self.length += 2
end

function bufferWriter:writeUInt32(value)
	self:reserve(4)
	buffer.writeu32(self.buffer, self.length, value)
	self.length += 4
end

function bufferWriter:writeFloat32(value)
	self:reserve(4)
	buffer.writef32(self.buffer, self.length, value)
	self.length += 4
end

function bufferWriter:writeFloat64(value)
	self:reserve(8)
	buffer.writef64(self.buffer, self.length, value)
	self.length += 8
end

function bufferWriter:writeVarUInt(value)
	local remaining = value
	local byteCount = 1
	while remaining >= 0x80 do
		remaining = bit32.rshift(remaining, 7)
		byteCount += 1
	end
	self:reserve(byteCount)
	local targetBuffer = self.buffer
	local position = self.length
	remaining = value
	for _ = 1, byteCount - 1 do
		buffer.writeu8(targetBuffer, position, bit32.bor(bit32.band(remaining, 0x7F), 0x80))
		remaining = bit32.rshift(remaining, 7)
		position += 1
	end
	buffer.writeu8(targetBuffer, position, remaining)
	self.length = position + 1
end

function bufferWriter:writeVarInt(value)
	local zigzagged = value >= 0 and value * 2 or (-value * 2 - 1)
	self:writeVarUInt(zigzagged)
end

function bufferWriter:writeString(value)
	local byteLength = #value
	self:writeVarUInt(byteLength)
	self:reserve(byteLength)
	buffer.writestring(self.buffer, self.length, value)
	self.length += byteLength
end

function bufferWriter:writeBuffer(sourceBuffer)
	local byteLength = buffer.len(sourceBuffer)
	self:writeVarUInt(byteLength)
	self:reserve(byteLength)
	buffer.copy(self.buffer, self.length, sourceBuffer, 0, byteLength)
	self.length += byteLength
end

function bufferWriter:toBuffer()
	local result = buffer.create(math.max(self.length, 1))
	buffer.copy(result, 0, self.buffer, 0, self.length)
	return result
end

return bufferWriter