local runService = game:GetService('RunService')
local codec = require(script.Parent.Modules.Codec)
local bufferWriter = require(script.Parent.Modules.Writer)
local bufferReader = require(script.Parent.Modules.Reader)
local signalModule = require(script.Parent.Modules.Signal)
local net = {}
local registeredEvents = {}
local nameById = {}
local idByName = {}
local nextRequestId = 1
local pendingRequests = {}
local pendingQueue = {}
local reliableQueue = {}
local unreliableQueue = {}
local statsSent = { bytes = 0, messages = 0 }
local statsReceived = { bytes = 0, messages = 0 }
local kindEvent = 0
local kindRequest = 1
local kindResponse = 2
local reliableFlushThreshold = 24
local unreliableFlushThreshold = 32
local masterRemote = script.Parent.__Master
local masterUnreliableRemote = script.Parent.__MasterUnreliable

local function writeMessageWithId(writer, message)
	writer:writeUInt8(message.kind)
	if message.kind == kindResponse then
		writer:writeVarUInt(message.requestId)
		writer:writeUInt8(message.success and 1 or 0)
		writer:writeBuffer(message.payload)
	elseif message.kind == kindRequest then
		writer:writeVarUInt(message.id)
		writer:writeVarUInt(message.requestId)
		writer:writeBuffer(message.payload)
	else
		writer:writeVarUInt(message.id)
		writer:writeBuffer(message.payload)
	end
end

local function flushReliable()
	if #reliableQueue == 0 then
		return
	end
	
	local writer = bufferWriter.new()
	writer:writeVarUInt(#reliableQueue)
	for _, message in ipairs(reliableQueue) do
		writeMessageWithId(writer, message)
	end
	
	statsSent.messages += #reliableQueue
	table.clear(reliableQueue)
	local outgoingBuffer = writer:toBuffer()
	statsSent.bytes += buffer.len(outgoingBuffer)
	masterRemote:FireServer(outgoingBuffer)
end

local function flushUnreliable()
	if #unreliableQueue == 0 then
		return
	end
	
	local writer = bufferWriter.new()
	writer:writeVarUInt(#unreliableQueue)
	for _, message in ipairs(unreliableQueue) do
		writeMessageWithId(writer, message)
	end
	
	statsSent.messages += #unreliableQueue
	table.clear(unreliableQueue)
	local outgoingBuffer = writer:toBuffer()
	statsSent.bytes += buffer.len(outgoingBuffer)
	masterUnreliableRemote:FireServer(outgoingBuffer)
end

local function queueReliable(message)
	table.insert(reliableQueue, message)
	if #reliableQueue >= reliableFlushThreshold then
		flushReliable()
	end
end

local function queueUnreliable(message)
	table.insert(unreliableQueue, message)
	if #unreliableQueue >= unreliableFlushThreshold then
		flushUnreliable()
	end
end

local function dispatchMessage(kind, eventName, payload, unreliable, requestId)
	local eventId = idByName[eventName]
	if not eventId then
		table.insert(pendingQueue, {
			kind = kind,
			name = eventName,
			payload = payload,
			unreliable = unreliable,
			requestId = requestId,
		})
		return
	end
	
	local message = { kind = kind, id = eventId, requestId = requestId, payload = payload }
	if unreliable then
		queueUnreliable(message)
	else
		queueReliable(message)
	end
end

local function resolvePending()
	if #pendingQueue == 0 then
		return
	end
	
	local stillPending = {}
	for _, entry in ipairs(pendingQueue) do
		local eventId = idByName[entry.name]
		if eventId then
			local message = { kind = entry.kind, id = eventId, requestId = entry.requestId, payload = entry.payload }
			if entry.unreliable then
				queueUnreliable(message)
			else
				queueReliable(message)
			end
		else
			table.insert(stillPending, entry)
		end
	end
	pendingQueue = stillPending
end

runService.Heartbeat:Connect(function()
	resolvePending()
	flushReliable()
	flushUnreliable()
end)

local function processIncoming(packedBuffer)
	local reader = bufferReader.new(packedBuffer)
	statsReceived.bytes += buffer.len(packedBuffer)
	local idSyncCount = reader:readVarUInt()
	for _ = 1, idSyncCount do
		local eventId = reader:readVarUInt()
		local eventName = reader:readString()
		nameById[eventId] = eventName
		idByName[eventName] = eventId
	end
	
	local messageCount = reader:readVarUInt()
	statsReceived.messages += messageCount
	for _ = 1, messageCount do
		local kind = reader:readUInt8()
		if kind == kindEvent then
			local eventId = reader:readVarUInt()
			local payload = reader:readBuffer()
			local eventName = nameById[eventId]
			local eventObject = eventName and registeredEvents[eventName]
			if eventObject and eventObject.onClientFire then
				local unpackedPayload = codec.unpack(payload)
				eventObject.onClientFire:fire(table.unpack(unpackedPayload))
			end
		elseif kind == kindRequest then
			local eventId = reader:readVarUInt()
			local requestId = reader:readVarUInt()
			local payload = reader:readBuffer()
			local eventName = nameById[eventId]
			local eventObject = eventName and registeredEvents[eventName]
			if eventObject and eventObject.onClientInvoke then
				task.spawn(function()
					local success, result = pcall(eventObject.onClientInvoke, codec.unpack(payload))
					queueReliable({ kind = kindResponse, requestId = requestId, success = success, payload = codec.pack(result) })
					flushReliable()
				end)
			end
		elseif kind == kindResponse then
			local requestId = reader:readVarUInt()
			local success = reader:readUInt8() == 1
			local payload = reader:readBuffer()
			local thread = pendingRequests[requestId]
			if thread then
				pendingRequests[requestId] = nil
				task.spawn(thread, success, codec.unpack(payload))
			end
		end
	end
end

local function processIncomingUnreliable(packedBuffer)
	local reader = bufferReader.new(packedBuffer)
	statsReceived.bytes += buffer.len(packedBuffer)
	local messageCount = reader:readVarUInt()
	statsReceived.messages += messageCount
	
	for _ = 1, messageCount do
		local kind = reader:readUInt8()
		local eventId = reader:readVarUInt()
		local payload = reader:readBuffer()
		if kind == kindEvent then
			local eventName = nameById[eventId]
			local eventObject = eventName and registeredEvents[eventName]
			if eventObject and eventObject.onClientFire then
				local unpackedPayload = codec.unpack(payload)
				eventObject.onClientFire:fire(codec.unpack(unpackedPayload))
			end
		end
	end
end

export type ClientEventApi = {
	FireServer: (self: ClientEventApi, data: any) -> (),
	Connect: (self: ClientEventApi, callback: (any) -> ()) -> any,
	Once: (self: ClientEventApi, callback: (any) -> ()) -> any,
}

function net.loadEvent(eventName: string, options: { unreliable: boolean? }?): ClientEventApi
	if registeredEvents[eventName] then
		return registeredEvents[eventName]
	end
	
	local unreliable = options and options.unreliable or false
	local eventApi = {} :: any
	eventApi.onClientFire = signalModule.new()
	function eventApi:FireServer(...)
		local data = {...}
		dispatchMessage(kindEvent, eventName, codec.pack(data), unreliable, nil)
	end
	
	function eventApi:Connect(callback)
		return eventApi.onClientFire:connect(callback)
	end
	
	function eventApi:Once(callback)
		return eventApi.onClientFire:once(callback)
	end
	
	registeredEvents[eventName] = eventApi
	return eventApi
end

export type ClientFunctionApi = {
	OnInvoke: (self: ClientFunctionApi, callback: (any) -> any) -> (),
	InvokeServer: (self: ClientFunctionApi, data: any) -> (boolean, any),
}

function net.loadFunction(eventName: string): ClientFunctionApi
	if registeredEvents[eventName] then
		return registeredEvents[eventName]
	end
	
	local eventApi = {} :: any
	function eventApi:OnInvoke(callback)
		eventApi.onClientInvoke = callback
	end
	
	function eventApi:InvokeServer(...)
		local data = {...}
		local timeoutSeconds = 3
		local requestId = nextRequestId
		nextRequestId += 1
		local thread = coroutine.running()
		pendingRequests[requestId] = thread
		dispatchMessage(kindRequest, eventName, codec.pack(data), false, requestId)
		resolvePending()
		flushReliable()
		local timeoutHandle = task.delay(timeoutSeconds or 10, function()
			if pendingRequests[requestId] then
				pendingRequests[requestId] = nil
				task.spawn(thread, false, 'timeout')
			end
		end)
		local success, result = coroutine.yield()
		task.cancel(timeoutHandle)
		return success, result
	end
	
	registeredEvents[eventName] = eventApi
	return eventApi
end

function net.getStats()
	return {
		sentBytes = statsSent.bytes,
		sentMessages = statsSent.messages,
		receivedBytes = statsReceived.bytes,
		receivedMessages = statsReceived.messages,
	}
end

masterRemote.OnClientEvent:Connect(processIncoming)
masterUnreliableRemote.OnClientEvent:Connect(processIncomingUnreliable)
return net