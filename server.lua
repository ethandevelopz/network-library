local runService = game:GetService('RunService')
local playersService = game:GetService('Players')
local network = game.ReplicatedStorage.Network
local modules = network.Modules
local codec = require(modules.Codec)
local bufferWriter = require(modules.Writer)
local bufferReader = require(modules.Reader)
local signalModule = require(modules.Signal)
local net = {}
local registeredEvents = {}
local idByName = {}
local nameById = {}
local nextEventId = 1
local nextRequestId = 1
local pendingRequests = {}
local reliableQueueByPlayer = {}
local unreliableQueueByPlayer = {}
local unsyncedIdsByPlayer = {}
local rateLimitState = {}
local statsSent = { bytes = 0, messages = 0 }
local statsReceived = { bytes = 0, messages = 0 }
local kindEvent = 0
local kindRequest = 1
local kindResponse = 2
local reliableFlushThreshold = 24
local unreliableFlushThreshold = 32
local masterRemote = network.__Master
local masterUnreliableRemote = network.__MasterUnreliable

local function initializePlayerState(player)
	reliableQueueByPlayer[player] = {}
	unreliableQueueByPlayer[player] = {}
	local pending = {}
	for eventId in pairs(nameById) do
		table.insert(pending, eventId)
	end
	unsyncedIdsByPlayer[player] = pending
end

for _, player in ipairs(playersService:GetPlayers()) do
	initializePlayerState(player)
end

playersService.PlayerAdded:Connect(initializePlayerState)
playersService.PlayerRemoving:Connect(function(player)
	reliableQueueByPlayer[player] = nil
	unreliableQueueByPlayer[player] = nil
	unsyncedIdsByPlayer[player] = nil
end)

local function getOrCreateEventId(eventName)
	local eventId = idByName[eventName]
	
	if eventId then
		return eventId
	end
	
	eventId = nextEventId
	nextEventId += 1
	idByName[eventName] = eventId
	nameById[eventId] = eventName
	for _, player in ipairs(playersService:GetPlayers()) do
		if unsyncedIdsByPlayer[player] then
			table.insert(unsyncedIdsByPlayer[player], eventId)
		end
	end
	
	return eventId
end

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

local function flushPlayerReliable(player)
	local queue = reliableQueueByPlayer[player]
	local pendingIds = unsyncedIdsByPlayer[player]
	if not queue or not pendingIds then
		return
	end
	
	if #queue == 0 and #pendingIds == 0 then
		return
	end
	
	local writer = bufferWriter.new()
	writer:writeVarUInt(#pendingIds)
	for _, eventId in ipairs(pendingIds) do
		writer:writeVarUInt(eventId)
		writer:writeString(nameById[eventId])
	end
	
	table.clear(pendingIds)
	writer:writeVarUInt(#queue)
	for _, message in ipairs(queue) do
		writeMessageWithId(writer, message)
	end
	
	statsSent.messages += #queue
	table.clear(queue)
	local outgoingBuffer = writer:toBuffer()
	statsSent.bytes += buffer.len(outgoingBuffer)
	masterRemote:FireClient(player, outgoingBuffer)
end

local function flushPlayerUnreliable(player)
	local queue = unreliableQueueByPlayer[player]
	if not queue or #queue == 0 then
		return
	end
	
	local writer = bufferWriter.new()
	writer:writeVarUInt(#queue)
	for _, message in ipairs(queue) do
		writeMessageWithId(writer, message)
	end
	
	statsSent.messages += #queue
	table.clear(queue)
	local outgoingBuffer = writer:toBuffer()
	statsSent.bytes += buffer.len(outgoingBuffer)
	masterUnreliableRemote:FireClient(player, outgoingBuffer)
end

local function queueReliable(player, message)
	local queue = reliableQueueByPlayer[player]
	if not queue then
		initializePlayerState(player)
		queue = reliableQueueByPlayer[player]
	end
	
	table.insert(queue, message)
	if #queue >= reliableFlushThreshold then
		flushPlayerReliable(player)
	end
end

local function queueUnreliable(player, message)
	local queue = unreliableQueueByPlayer[player]
	if not queue then
		initializePlayerState(player)
		queue = unreliableQueueByPlayer[player]
	end
	
	table.insert(queue, message)
	if #queue >= unreliableFlushThreshold then
		flushPlayerUnreliable(player)
	end
end

local function queueForPlayer(player, eventId, payload, unreliable)
	local message = { kind = kindEvent, id = eventId, payload = payload }
	if unreliable then
		queueUnreliable(player, message)
	else
		queueReliable(player, message)
	end
end

local function queueForAll(eventId, payload, unreliable)
	for _, player in ipairs(playersService:GetPlayers()) do
		queueForPlayer(player, eventId, payload, unreliable)
	end
end

local function queueForExcept(excludedPlayer, eventId, payload, unreliable)
	for _, player in ipairs(playersService:GetPlayers()) do
		if player ~= excludedPlayer then
			queueForPlayer(player, eventId, payload, unreliable)
		end
	end
end

local function queueForList(players, eventId, payload, unreliable)
	for _, player in ipairs(players) do
		queueForPlayer(player, eventId, payload, unreliable)
	end
end

runService.Heartbeat:Connect(function()
	for _, player in ipairs(playersService:GetPlayers()) do
		flushPlayerReliable(player)
		flushPlayerUnreliable(player)
	end
end)

local function checkRateLimit(eventName, player, maxPerSecond)
	if not maxPerSecond then
		return true
	end
	
	local perEvent = rateLimitState[eventName]
	if not perEvent then
		perEvent = {}
		rateLimitState[eventName] = perEvent
	end
	
	local state = perEvent[player]
	local now = os.clock()
	if not state or now - state.windowStart >= 1 then
		state = { count = 0, windowStart = now }
		perEvent[player] = state
	end
	
	state.count += 1
	return state.count <= maxPerSecond
end

local function processIncoming(player, packedBuffer)
	local reader = bufferReader.new(packedBuffer)
	statsReceived.bytes += buffer.len(packedBuffer)
	local messageCount = reader:readVarUInt()
	statsReceived.messages += messageCount
	for _ = 1, messageCount do
		local kind = reader:readUInt8()
		if kind == kindEvent then
			local eventId = reader:readVarUInt()
			local payload = reader:readBuffer()
			local eventName = nameById[eventId]
			local eventObject = eventName and registeredEvents[eventName]
			if eventObject and eventObject.onServerFire then
				if checkRateLimit(eventName, player, eventObject.rateLimit) then
					local unpackedPayload = codec.unpack(payload)
					eventObject.onServerFire:fire(player, table.unpack(unpackedPayload))
				end
			end
		elseif kind == kindRequest then
			local eventId = reader:readVarUInt()
			local requestId = reader:readVarUInt()
			local payload = reader:readBuffer()
			local eventName = nameById[eventId]
			local eventObject = eventName and registeredEvents[eventName]
			if eventObject and eventObject.onServerInvoke then
				task.spawn(function()
					local success, result = pcall(eventObject.onServerInvoke, player, codec.unpack(payload))
					queueReliable(player, {
						kind = kindResponse,
						requestId = requestId,
						success = success,
						payload = codec.pack(result),
					})
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

export type ServerEventApi = {
	FireClient: (self: ServerEventApi, player: Player, data: any) -> (),
	FireAll: (self: ServerEventApi, data: any) -> (),
	FireExcept: (self: ServerEventApi, excludedPlayer: Player, data: any) -> (),
	FireList: (self: ServerEventApi, players: { Player }, data: any) -> (),
	Connect: (self: ServerEventApi, callback: (Player, any) -> ()) -> any,
	Once: (self: ServerEventApi, callback: (Player, any) -> ()) -> any,
}

function net.loadEvent(eventName: string, options: { unreliable: boolean?, rateLimit: number? }?): ServerEventApi
	if registeredEvents[eventName] then
		return registeredEvents[eventName]
	end
	local eventId = getOrCreateEventId(eventName)
	local unreliable = options and options.unreliable or false
	local rateLimit = options and options.rateLimit or 5
	local eventApi = {} :: any
	eventApi.onServerFire = signalModule.new()
	eventApi.rateLimit = rateLimit
	function eventApi:FireClient(player, ...)
		local args = {...}
		queueForPlayer(player, eventId, codec.pack(args), unreliable)
	end
	function eventApi:FireAll(...)
		local args = {...}
		queueForAll(eventId, codec.pack(args), unreliable)
	end
	function eventApi:FireExcept(excludedPlayer, ...)
		local args = {...}
		queueForExcept(excludedPlayer, eventId, codec.pack(args), unreliable)
	end
	function eventApi:FireList(players, ...)
		local args = {...}
		queueForList(players, eventId, codec.pack(args), unreliable)
	end
	function eventApi:Connect(callback)
		return eventApi.onServerFire:connect(callback)
	end
	function eventApi:Once(callback)
		return eventApi.onServerFire:once(callback)
	end
	registeredEvents[eventName] = eventApi
	return eventApi
end

export type ServerFunctionApi = {
	OnInvoke: (self: ServerFunctionApi, callback: (Player, any) -> any) -> (),
	InvokeClient: (self: ServerFunctionApi, player: Player, data: any) -> (boolean, any),
}

function net.loadFunction(eventName: string): ServerFunctionApi
	if registeredEvents[eventName] then
		return registeredEvents[eventName]
	end
	
	local eventId = getOrCreateEventId(eventName)
	local eventApi = {} :: any
	
	function eventApi:OnInvoke(callback)
		eventApi.onServerInvoke = callback
	end
	
	function eventApi:InvokeClient(player, ...)
		local args = {...}
		local timeoutSeconds = 5
		local requestId = nextRequestId
		nextRequestId += 1
		local thread = coroutine.running()
		pendingRequests[requestId] = thread
		queueReliable(player, { kind = kindRequest, id = eventId, requestId = requestId, payload = codec.pack(args) })
		flushPlayerReliable(player)
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

masterRemote.OnServerEvent:Connect(processIncoming)
masterUnreliableRemote.OnServerEvent:Connect(processIncoming)
return net
