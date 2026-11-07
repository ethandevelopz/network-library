--!native
--!optimize 2
local packet = {}
local kindRequest = 1
local kindResponse = 2

local function ensure(batch, extra)
	local required = batch.length + extra
	local size = batch.capacity
	if required <= size then
		return
	end

	repeat
		size *= 2
	until size >= required
	local nextBuffer = buffer.create(size)
	buffer.copy(nextBuffer, 0, batch.buffer, 0, batch.length)
	batch.buffer = nextBuffer
	batch.capacity = size
end

local function writeVarUInt(target, at, value)
	while value >= 128 do
		buffer.writeu8(target, at, value % 128 + 128)
		value //= 128
		at += 1
	end

	buffer.writeu8(target, at, value)
	return at + 1
end

local function readVarUInt(source, at)
	local result = 0
	local scale = 1
	for _ = 1, 8 do
		local byte = buffer.readu8(source, at)
		at += 1
		if byte < 128 then
			return result + byte * scale, at
		end

		result += (byte - 128) * scale
		scale *= 128
	end

	error('varuint too long', 0)
end

function packet.newBatch()
	return { buffer = buffer.create(256), capacity = 256, length = 0, refs = {}, refCount = 0, messages = 0 }
end

function packet.frameSize(payloadLength, refCount)
	return payloadLength + 16 + refCount * 8
end

function packet.append(batch, kind, id, extra, payload, payloadLength, payloadRefs, payloadRefCount)
	ensure(batch, payloadLength + 32)
	local target = batch.buffer
	local at = writeVarUInt(target, batch.length, id * 8 + kind * 2 + (if payloadRefCount > 0 then 1 else 0))
	if payloadRefCount > 0 then
		at = writeVarUInt(target, at, payloadRefCount)
		table.move(payloadRefs, 1, payloadRefCount, batch.refCount + 1, batch.refs)
		batch.refCount += payloadRefCount
	end

	if kind == kindRequest or kind == kindResponse then
		at = writeVarUInt(target, at, extra)
	end

	at = writeVarUInt(target, at, payloadLength)
	buffer.copy(target, at, payload, 0, payloadLength)
	batch.length = at + payloadLength
	batch.messages += 1
end

function packet.take(batch)
	local length = batch.length
	local result = buffer.create(length)
	buffer.copy(result, 0, batch.buffer, 0, length)
	local refs, refCount, messages = batch.refs, batch.refCount, batch.messages
	if refCount > 0 then
		batch.refs = {}
	end

	batch.length = 0
	batch.refCount = 0
	batch.messages = 0
	return result, refs, refCount, messages
end

function packet.read(source, refTotal, handler, context)
	local length = buffer.len(source)
	local at = 0
	local refBase = 0
	local messages = 0
	while at < length do
		local header, refCount, extra, payloadLength
		header, at = readVarUInt(source, at)
		refCount = 0
		extra = 0
		local kind = header // 2 % 4
		if header % 2 == 1 then
			refCount, at = readVarUInt(source, at)
		end

		if kind == kindRequest or kind == kindResponse then
			extra, at = readVarUInt(source, at)
		end

		payloadLength, at = readVarUInt(source, at)
		local finish = at + payloadLength
		if finish > length or refBase + refCount > refTotal then
			error('malformed packet', 0)
		end

		messages += 1
		handler(context, kind, header // 8, extra, source, at, finish, refBase, refCount)
		at = finish
		refBase += refCount
	end

	return messages
end

return packet
