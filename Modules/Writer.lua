local bufferWriter = {}
local maxSafeInteger = 9007199254740991
bufferWriter.__index = bufferWriter

function bufferWriter.new(initialCapacity)
	local size = math.max(initialCapacity or 64, 1)
	return setmetatable({ buffer = buffer.create(size), length = 0, capacity = size }, bufferWriter)
end

function bufferWriter:reset()
	self.length = 0
end

function bufferWriter:reserve(extraBytes)
	local requiredCapacity = self.length + extraBytes
	if requiredCapacity <= self.capacity then
		return
	end

	local newCapacity = self.capacity * 2
	while newCapacity < requiredCapacity do
		newCapacity *= 2
	end

	local newBuffer = buffer.create(newCapacity)
	buffer.copy(newBuffer, 0, self.buffer, 0, self.length)
	self.buffer = newBuffer
	self.capacity = newCapacity
end

function bufferWriter:writeUInt8(value)
	self:reserve(1)
	buffer.writeu8(self.buffer, self.length, value)
	self.length += 1
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

function bufferWriter:writeInt32(value)
	self:reserve(4)
	buffer.writei32(self.buffer, self.length, value)
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
	if not (value >= 0 and value <= maxSafeInteger) then
		error('varuint out of range: ' .. tostring(value), 2)
	end

	self:reserve(8)
	local target = self.buffer
	local position = self.length
	while value >= 128 do
		buffer.writeu8(target, position, value % 128 + 128)
		value //= 128
		position += 1
	end

	buffer.writeu8(target, position, value)
	self.length = position + 1
end

function bufferWriter:writeVarInt(value)
	self:writeVarUInt(if value >= 0 then value * 2 else -value * 2 - 1)
end

function bufferWriter:writeString(value)
	local byteLength = #value
	self:writeVarUInt(byteLength)
	self:reserve(byteLength)
	buffer.writestring(self.buffer, self.length, value, byteLength)
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
	local result = buffer.create(self.length)
	buffer.copy(result, 0, self.buffer, 0, self.length)
	return result
end

return bufferWriter
