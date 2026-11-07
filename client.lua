local runService = game:GetService('RunService')
local network = script.Parent
local modules = network:WaitForChild('Modules')
local codec = require(modules:WaitForChild('Codec'))
local packet = require(modules:WaitForChild('Packet'))
local signal = require(modules:WaitForChild('Signal'))
local idl = require(modules:WaitForChild('Idl'))
local enums = require(modules:WaitForChild('Enums'))
local masterRemote = network:WaitForChild('__Master')
local masterUnreliableRemote = network:WaitForChild('__MasterUnreliable')
local net = {}
local entriesByName = {}
local idByName = {}
local nameById = {}
local definitions = {}
local aliases = {}
local unclaimed = {}
local pendingSends = {}
local pendingRequests = {}
local emptyRefs = {}
local reliableBatch = packet.newBatch()
local unreliableBatch = packet.newBatch()
local stats = { sentBytes = 0, sentMessages = 0, receivedBytes = 0, receivedMessages = 0, droppedMessages = 0 }
local eventMeta = {}
local functionMeta = {}
local kindEvent, kindRequest, kindResponse, kindSync = enums.kind.Event, enums.kind.Request, enums.kind.Response, enums.kind.Sync
local incomingRefs = emptyRefs
local pendingSendCount = 0
local nextRequestId = 0
local dirty = false
local defaultTimeout = 3
local unreliableBudget = 800
local maxBatchRefs = 250
local maxPendingSends = 512
local maxUnclaimedPerName = 64
local maxQueuedEvents = 256
local maxWaitingRequests = 64
local maxRequestId = 1048575
local genericError = 'client error'
eventMeta.__index = eventMeta
functionMeta.__index = functionMeta
net.codec = codec
net.types = codec.types

export type ClientEventApi = {
	Name: string,
	FireServer: (self: ClientEventApi, ...any) -> (),
	Connect: (self: ClientEventApi, callback: (...any) -> ()) -> any,
	Once: (self: ClientEventApi, callback: (...any) -> ()) -> any,
	Wait: (self: ClientEventApi) -> ...any,
}

export type ClientFunctionApi = {
	Name: string,
	OnInvoke: (self: ClientFunctionApi, callback: (...any) -> ...any) -> (),
	InvokeServer: (self: ClientFunctionApi, ...any) -> (boolean, ...any),
}

local function sendBatch(remote, batch)
	local data, refs, refCount, messages = packet.take(batch)
	stats.sentBytes += buffer.len(data)
	stats.sentMessages += messages
	if refCount > 0 then
		remote:FireServer(data, table.unpack(refs, 1, refCount))
	else
		remote:FireServer(data)
	end
end

local function appendRaw(entry, kind, id, extra, payload, length, refs, refCount)
	local batch, remote = reliableBatch, masterRemote
	if entry and entry.unreliable and kind == kindEvent then
		local frame = packet.frameSize(length, refCount)
		if frame <= unreliableBudget then
			batch, remote = unreliableBatch, masterUnreliableRemote
			if batch.length > 0 and batch.length + batch.refCount * 8 + frame > unreliableBudget then
				sendBatch(remote, batch)
			end
		elseif not entry.oversizeWarned then
			entry.oversizeWarned = true
			warn(('network event %s is too large for an unreliable remote (%d bytes), sending it reliably'):format(entry.name, length))
		end
	end

	if batch.length > 0 and batch.refCount + refCount > maxBatchRefs then
		sendBatch(remote, batch)
	end

	packet.append(batch, kind, id, extra, payload, length, refs, refCount)
	dirty = true
end

local function appendMessage(entry, kind, extra, length, refCount)
	local payload, refs = codec.getScratch()
	local id = idByName[entry.name]
	if id then
		appendRaw(entry, kind, id, extra, payload, length, refs, refCount)
		return true
	end

	if pendingSendCount >= maxPendingSends then
		stats.droppedMessages += 1
		warn(('network send queue is full, dropping %s (the server has not registered it)'):format(entry.name))
		return false
	end

	local copy = buffer.create(length)
	buffer.copy(copy, 0, payload, 0, length)
	local queue = pendingSends[entry.name]
	if not queue then
		queue = {}
		pendingSends[entry.name] = queue
	end

	table.insert(queue, {
		kind = kind,
		extra = extra,
		payload = copy,
		length = length,
		refs = if refCount > 0 then table.move(refs, 1, refCount, 1, {}) else emptyRefs,
		refCount = refCount,
	})
	pendingSendCount += 1
	return true
end

local function resolveRequest(requestId, request, ...)
	if pendingRequests[requestId] ~= request then
		return
	end

	pendingRequests[requestId] = nil
	local timeout = request.timeout
	request.timeout = nil
	if timeout then
		task.cancel(timeout)
	end

	task.spawn(request.thread, ...)
end

local function expireRequest(requestId, request)
	request.timeout = nil
	resolveRequest(requestId, request, false, 'timeout')
end

local function runInvoke(entry, requestId, args)
	local results = table.pack(pcall(entry.handler, table.unpack(args, 1, args.n)))
	local status, length, refCount = 0, 0, 0
	if results[1] then
		local encoded
		encoded, length, refCount = pcall(codec.encodeArgs, entry.rets, table.unpack(results, 2, results.n))
		if encoded then
			status = 1
		else
			warn(('network function %s returned values that could not be sent: %s'):format(entry.name, tostring(length)))
		end
	else
		warn(('network function %s errored: %s'):format(entry.name, tostring(results[2])))
	end

	if status == 0 then
		length, refCount = codec.encodeArgs(nil, genericError)
	end

	local payload, refs = codec.getScratch()
	appendRaw(nil, kindResponse, requestId, status, payload, length, refs, refCount)
end

local function drainQueued(entry)
	local queued = entry.queued
	if #queued == 0 or entry.signal.count == 0 then
		return
	end

	entry.queued = {}
	for _, args in queued do
		entry.signal:fire(table.unpack(args, 1, args.n))
	end
end

local function dispatch(entry, kind, extra, source, start, finish, refs, refBase, refCount)
	local expectedKind = if kind == kindEvent then 'event' elseif kind == kindRequest then 'function' else nil
	if entry.kind ~= expectedKind then
		return
	end

	local success, count, args = pcall(codec.decodeArgs, entry.tuple, source, start, finish, refs, refBase, refCount)
	if not success then
		stats.droppedMessages += 1
		warn(('network failed to decode %s: %s'):format(entry.name, tostring(count)))
		return
	end

	args.n = count
	if kind == kindEvent then
		if entry.signal.count > 0 then
			entry.signal:fire(table.unpack(args, 1, count))
		elseif #entry.queued < maxQueuedEvents then
			table.insert(entry.queued, args)
		else
			stats.droppedMessages += 1
		end
	elseif entry.handler then
		task.spawn(runInvoke, entry, extra, args)
	elseif #entry.waiting < maxWaitingRequests then
		table.insert(entry.waiting, { extra, args })
	end
end

local function handleSync(id, name)
	nameById[id] = name
	idByName[name] = id
	local queue = pendingSends[name]
	if not queue then
		return
	end

	pendingSends[name] = nil
	pendingSendCount -= #queue
	local entry = entriesByName[name]
	for _, message in queue do
		appendRaw(entry, message.kind, id, message.extra, message.payload, message.length, message.refs, message.refCount)
	end
end

local function handleMessage(_, kind, id, extra, source, start, finish, refBase, refCount)
	if kind == kindSync then
		handleSync(id, buffer.readstring(source, start, finish - start))
		return
	end

	if kind == kindResponse then
		local request = pendingRequests[id]
		if not request then
			return
		end

		local tuple = if extra == 1 then request.entry.rets else nil
		local success, count, args = pcall(codec.decodeArgs, tuple, source, start, finish, incomingRefs, refBase, refCount)
		if not success then
			resolveRequest(id, request, false, 'malformed response')
		elseif extra == 1 then
			resolveRequest(id, request, true, table.unpack(args, 1, count))
		else
			resolveRequest(id, request, false, args[1])
		end

		return
	end

	local name = nameById[id]
	if not name then
		stats.droppedMessages += 1
		return
	end

	local entry = entriesByName[name]
	if entry then
		dispatch(entry, kind, extra, source, start, finish, incomingRefs, refBase, refCount)
		return
	end

	local stored = unclaimed[name]
	if not stored then
		stored = {}
		unclaimed[name] = stored
	end

	if #stored >= maxUnclaimedPerName then
		stats.droppedMessages += 1
		return
	end

	local length = finish - start
	local copy = buffer.create(length)
	buffer.copy(copy, 0, source, start, length)
	table.insert(stored, {
		kind = kind,
		extra = extra,
		payload = copy,
		refs = if refCount > 0 then table.move(incomingRefs, refBase + 1, refBase + refCount, 1, {}) else emptyRefs,
		refCount = refCount,
	})
end

local function processIncoming(data, ...)
	if typeof(data) ~= 'buffer' then
		return
	end

	local refTotal = select('#', ...)
	stats.receivedBytes += buffer.len(data)
	incomingRefs = if refTotal > 0 then { ... } else emptyRefs
	local success, result = pcall(packet.read, data, refTotal, handleMessage, nil)
	incomingRefs = emptyRefs
	if success then
		stats.receivedMessages += result
	else
		warn('network failed to read packet: ' .. tostring(result))
	end
end

local function register(name, kind, options)
	assert(type(name) == 'string' and #name > 0, 'network name must be a non-empty string')
	local entry = entriesByName[name]
	if entry then
		if entry.kind ~= kind then
			error(('network %s is already registered as an %s'):format(name, entry.kind), 3)
		end

		return entry
	end

	local definition = definitions[name]
	if definition and definition.kind ~= kind then
		error(('network %s is declared as an %s in the protocol'):format(name, definition.kind), 3)
	end

	options = definition or options or {}
	entry = {
		name = name,
		kind = kind,
		unreliable = options.unreliable == true,
		tuple = idl.resolveTuple(options.data, aliases),
		rets = idl.resolveTuple(options.rets, aliases),
		from = options.from,
		timeout = options.timeout or defaultTimeout,
		signal = if kind == 'event' then signal.new() else nil,
		queued = {},
		waiting = {},
		handler = nil,
		oversizeWarned = false,
	}
	entriesByName[name] = entry
	entry.api = setmetatable({ entry = entry, Name = name }, if kind == 'event' then eventMeta else functionMeta)
	local stored = unclaimed[name]
	if stored then
		unclaimed[name] = nil
		for _, message in stored do
			dispatch(entry, message.kind, message.extra, message.payload, 0, buffer.len(message.payload), message.refs, 0, message.refCount)
		end
	end

	return entry
end

local function assertClientCanSend(entry)
	if entry.from == 'Server' then
		error(('network %s can only be sent by the server'):format(entry.name), 3)
	end
end

function eventMeta:FireServer(...)
	local entry = self.entry
	assertClientCanSend(entry)
	local length, refCount = codec.encodeArgs(entry.tuple, ...)
	appendMessage(entry, kindEvent, 0, length, refCount)
end

function eventMeta:Connect(callback)
	local entry = self.entry
	local connection = entry.signal:connect(callback)
	if #entry.queued > 0 then
		task.defer(drainQueued, entry)
	end

	return connection
end

function eventMeta:Once(callback)
	local entry = self.entry
	local connection = entry.signal:once(callback)
	if #entry.queued > 0 then
		task.defer(drainQueued, entry)
	end

	return connection
end

function eventMeta:Wait()
	local entry = self.entry
	if #entry.queued > 0 then
		local args = table.remove(entry.queued, 1)
		return table.unpack(args, 1, args.n)
	end

	return entry.signal:wait()
end

function functionMeta:OnInvoke(callback)
	local entry = self.entry
	entry.handler = callback
	if callback and #entry.waiting > 0 then
		local waiting = entry.waiting
		entry.waiting = {}
		for _, request in waiting do
			task.spawn(runInvoke, entry, request[1], request[2])
		end
	end
end

function functionMeta:InvokeServer(...)
	local entry = self.entry
	assertClientCanSend(entry)
	local length, refCount = codec.encodeArgs(entry.tuple, ...)
	nextRequestId = nextRequestId % maxRequestId + 1
	local requestId = nextRequestId
	local request = { thread = coroutine.running(), entry = entry, timeout = nil }
	pendingRequests[requestId] = request
	if not appendMessage(entry, kindRequest, requestId, length, refCount) then
		pendingRequests[requestId] = nil
		return false, 'send queue full'
	end

	request.timeout = task.delay(entry.timeout, expireRequest, requestId, request)
	return coroutine.yield()
end

function net.loadEvent(name: string, options: { unreliable: boolean?, data: any?, from: string? }?): ClientEventApi
	return register(name, 'event', options).api
end

function net.loadFunction(name: string, options: { timeout: number?, data: any?, rets: any?, from: string? }?): ClientFunctionApi
	return register(name, 'function', options).api
end

function net.define(source)
	local parsed = if type(source) == 'string' then idl.parse(source) else source
	for name, typeObject in parsed.types or {} do
		aliases[name] = typeObject
	end

	local apis = {}
	for name, definition in parsed.events or {} do
		definition.kind = 'event'
		definitions[name] = definition
	end

	for name, definition in parsed.functions or {} do
		definition.kind = 'function'
		definitions[name] = definition
	end

	for name, definition in definitions do
		apis[name] = register(name, definition.kind, nil).api
	end

	return apis
end

function net.getStats()
	return table.clone(stats)
end

local protocolModule = network:FindFirstChild('Protocol')
if protocolModule then
	net.define(require(protocolModule))
end

masterRemote.OnClientEvent:Connect(processIncoming)
masterUnreliableRemote.OnClientEvent:Connect(processIncoming)
runService.Heartbeat:Connect(function()
	if not dirty then
		return
	end

	dirty = false
	if reliableBatch.length > 0 then
		sendBatch(masterRemote, reliableBatch)
	end

	if unreliableBatch.length > 0 then
		sendBatch(masterUnreliableRemote, unreliableBatch)
	end
end)

return net
