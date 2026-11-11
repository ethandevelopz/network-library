local players = game:GetService('Players')
local runService = game:GetService('RunService')
local replicatedStorage = game:GetService('ReplicatedStorage')
local network = replicatedStorage:WaitForChild('Network')
local modules = network:WaitForChild('Modules')
local codec = require(modules:WaitForChild('Codec'))
local packet = require(modules:WaitForChild('Packet'))
local signal = require(modules:WaitForChild('Signal'))
local idl = require(modules:WaitForChild('Idl'))
local enums = require(modules:WaitForChild('Enums'))
local actions = require(modules:WaitForChild('Actions'))
local masterRemote = network:WaitForChild('__Master')
local masterUnreliableRemote = network:WaitForChild('__MasterUnreliable')
local net = {}
local entriesByName = {}
local entriesById = {}
local definitions = {}
local aliases = {}
local playerStates = {}
local dirtyStates = {}
local pendingRequests = {}
local emptyRefs = {}
local stats = { sentBytes = 0, sentMessages = 0, receivedBytes = 0, receivedMessages = 0, droppedMessages = 0 }
local eventMeta = {}
local functionMeta = {}
local middlewares = {}
local actionCounters = {}
local actionRunner = signal.new()
local reasons = actions.reasons
local actionContext = actions.context
local actionSpecEntry = nil
local actionFailedEntry = nil
local actionDebug = runService:IsStudio()
local kindEvent, kindRequest, kindResponse, kindSync = enums.kind.Event, enums.kind.Request, enums.kind.Response, enums.kind.Sync
local dirtyCount = 0
local nextRequestId = 0
local defaultRateLimit = 5
local defaultTimeout = 5
local maxIncomingBytes = 65536
local maxIncomingRefs = 256
local maxBatchRefs = 250
local unreliableBudget = 800
local maxInflightRequests = 16
local maxWaitingRequests = 64
local maxRequestId = 1048575
local strikeWarnThreshold = 10
local globalActionRate = 50
local globalActionBurst = 100
local maxReasonLength = 96
local genericError = 'server error'
local globalActionViolation = 'action rate limit exceeded across all actions'
eventMeta.__index = eventMeta
functionMeta.__index = functionMeta
net.Violation = signal.new()
net.codec = codec
net.types = codec.types
net.validators = actions.validators
net.ActionReason = reasons
actionContext.connected = playerStates

export type ServerEventApi = {
	Name: string,
	FireClient: (self: ServerEventApi, player: Player, ...any) -> (),
	FireAll: (self: ServerEventApi, ...any) -> (),
	FireExcept: (self: ServerEventApi, excludedPlayer: Player, ...any) -> (),
	FireList: (self: ServerEventApi, players: { Player }, ...any) -> (),
	Connect: (self: ServerEventApi, callback: (Player, ...any) -> ()) -> any,
	Once: (self: ServerEventApi, callback: (Player, ...any) -> ()) -> any,
	Wait: (self: ServerEventApi) -> (Player, ...any),
}

export type ServerFunctionApi = {
	Name: string,
	OnInvoke: (self: ServerFunctionApi, callback: (Player, ...any) -> ...any) -> (),
	InvokeClient: (self: ServerFunctionApi, player: Player, ...any) -> (boolean, ...any),
}

export type ActionReason = 'RateLimited' | 'Cooldown' | 'UnknownAction' | 'InvalidArguments' | 'Unavailable' | 'Timeout' | 'Rejected'

export type ActionRate = 'fast' | 'normal' | 'slow' | 'rare' | number

export type ActionValidator = (value: any) -> boolean

export type ActionHandler = (player: Player, ...any) -> (boolean, string?)

export type ActionMiddleware = (player: Player, actionName: string, ...any) -> (boolean, string?)

export type ActionOptions = {
	rate: ActionRate?,
	burst: number?,
	maxArgs: number?,
	validate: ((...any) -> boolean)?,
	args: ({ ActionValidator } | string)?,
	cooldown: number?,
	requires: { string }?,
}

export type ActionStats = {
	calls: number,
	rejects: { [string]: number },
	averageHandlerTime: number,
}

local function markDirty(state)
	if not state.dirty then
		state.dirty = true
		dirtyCount += 1
		dirtyStates[dirtyCount] = state
	end
end

local function sendBatch(player, remote, batch)
	local data, refs, refCount, messages = packet.take(batch)
	stats.sentBytes += buffer.len(data)
	stats.sentMessages += messages
	if refCount > 0 then
		remote:FireClient(player, data, table.unpack(refs, 1, refCount))
	else
		remote:FireClient(player, data)
	end
end

local function flushState(state)
	state.dirty = false
	if state.reliable.length > 0 then
		sendBatch(state.player, masterRemote, state.reliable)
	end

	if state.unreliable.length > 0 then
		sendBatch(state.player, masterUnreliableRemote, state.unreliable)
	end
end

local function appendMessage(state, entry, kind, id, extra, length, refCount)
	local payload, refs = codec.getScratch()
	local batch, remote = state.reliable, masterRemote
	if entry and entry.unreliable and kind == kindEvent then
		local frame = packet.frameSize(length, refCount)
		if frame <= unreliableBudget then
			batch, remote = state.unreliable, masterUnreliableRemote
			if batch.length > 0 and batch.length + batch.refCount * 8 + frame > unreliableBudget then
				sendBatch(state.player, remote, batch)
			end
		elseif not entry.oversizeWarned then
			entry.oversizeWarned = true
			warn(('network event %s is too large for an unreliable remote (%d bytes), sending it reliably'):format(entry.name, length))
		end
	end

	if batch.length > 0 and batch.refCount + refCount > maxBatchRefs then
		sendBatch(state.player, remote, batch)
	end

	packet.append(batch, kind, id, extra, payload, length, refs, refCount)
	markDirty(state)
end

local function appendSpec(state, entry)
	local length = codec.encodeArgs(actionSpecEntry.tuple, entry.name, entry.spec or '')
	appendMessage(state, actionSpecEntry, kindEvent, actionSpecEntry.id, 0, length, 0)
end

local function appendSync(state, entry)
	if entry.spec then
		appendSpec(state, entry)
	end

	local length = codec.encodeString(entry.name)
	appendMessage(state, nil, kindSync, entry.id, 0, length, 0)
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

local function strike(state, reason)
	state.strikes += 1
	stats.droppedMessages += 1
	if state.strikes == strikeWarnThreshold then
		warn(('network: %s has sent %d invalid or rate-limited messages (latest: %s)'):format(state.player.Name, state.strikes, reason))
	end

	net.Violation:fire(state.player, reason)
end

local function allow(state, id, rate, burst)
	if not rate then
		return true
	end

	local now = os.clock()
	local tokens = state.tokens[id]
	if tokens == nil then
		tokens = burst
	else
		tokens = math.min(burst, tokens + (now - state.stamps[id]) * rate)
	end

	state.stamps[id] = now
	if tokens < 1 then
		state.tokens[id] = tokens
		return false
	end

	state.tokens[id] = tokens - 1
	return true
end

local function getCounters(name)
	local counters = actionCounters[name]
	if not counters then
		counters = { calls = 0, handled = 0, handlerTime = 0, rejects = {} }
		actionCounters[name] = counters
	end

	return counters
end

local function recordReject(state, entry, reason, ...)
	local rejects = getCounters(entry.name).rejects
	rejects[reason] = (rejects[reason] or 0) + 1
	print(('network action %s from %s rejected: %s (%s)'):format(entry.name, state.player.Name, reason, actions.summarize(...)))
end

local function cleanReason(reason, fallback)
	if type(reason) ~= 'string' or reason == '' then
		return fallback
	end

	if #reason > maxReasonLength then
		return string.sub(reason, 1, maxReasonLength)
	end

	return reason
end

local function respondAction(state, requestId, status, reason)
	local length
	if reason == nil then
		length = codec.encodeArgs(nil)
	else
		length = codec.encodeArgs(nil, reason)
	end

	appendMessage(state, nil, kindResponse, requestId, status, length, 0)
end

local function failAction(state, entry, kind, requestId, reason)
	if kind == kindRequest then
		respondAction(state, requestId, 0, reason)
		return
	end

	local length = codec.encodeArgs(actionFailedEntry.tuple, entry.id, reason)
	appendMessage(state, actionFailedEntry, kindEvent, actionFailedEntry.id, 0, length, 0)
end

local function rejectAction(state, entry, kind, requestId, reason, ...)
	strike(state, entry.violations[reason])
	if actionDebug then
		recordReject(state, entry, reason, ...)
	end

	if kind == kindRequest then
		respondAction(state, requestId, 0, reason)
	end
end

local function runMiddleware(state, entry, action, ...)
	local requires = action.requires
	local player, name = state.player, entry.name
	for index = 1, #requires do
		local middleware = requires[index]
		local success, ok, reason = pcall(middleware.run, player, name, ...)
		if not success then
			warn(('network action middleware %s errored: %s'):format(middleware.name, tostring(ok)))
			return reasons.Unavailable
		end

		if not ok then
			return cleanReason(reason, reasons.Unavailable)
		end
	end

	return nil
end

local function runAction(state, entry, action, kind, requestId, ...)
	local player = state.player
	local blocked = if action.requires then runMiddleware(state, entry, action, ...) else nil
	if blocked then
		state.inflight -= 1
		if actionDebug then
			recordReject(state, entry, blocked, ...)
		end

		failAction(state, entry, kind, requestId, blocked)
		return
	end

	if action.cooldown then
		state.cooldowns[entry.id] = os.clock()
	end

	local started = if actionDebug then os.clock() else 0
	local success, ok, reason = pcall(action.handler, player, ...)
	state.inflight -= 1
	if actionDebug then
		local counters = getCounters(entry.name)
		counters.handled += 1
		counters.handlerTime += os.clock() - started
	end

	if playerStates[player] ~= state then
		return
	end

	if success and ok ~= false then
		if kind == kindRequest then
			respondAction(state, requestId, 1, cleanReason(reason, nil))
		end

		return
	end

	if success then
		reason = cleanReason(reason, reasons.Rejected)
	else
		warn(('network action %s errored: %s'):format(entry.name, tostring(ok)))
		reason = reasons.Unavailable
	end

	if actionDebug then
		recordReject(state, entry, reason, ...)
	end

	failAction(state, entry, kind, requestId, reason)
end

local function checkAction(state, entry, action, kind, requestId, ...)
	if select('#', ...) > action.maxArgs then
		rejectAction(state, entry, kind, requestId, reasons.InvalidArguments, ...)
		return
	end

	local validate = action.validate
	if validate then
		actionContext.sender = state.player
		local success, valid = pcall(validate, ...)
		actionContext.sender = nil
		if not success and not action.warned then
			action.warned = true
			warn(('network action %s validator errored: %s'):format(entry.name, tostring(valid)))
		end

		if not (success and valid) then
			rejectAction(state, entry, kind, requestId, reasons.InvalidArguments, ...)
			return
		end
	end

	if state.inflight >= maxInflightRequests then
		rejectAction(state, entry, kind, requestId, reasons.Unavailable, ...)
		return
	end

	state.inflight += 1
	actionRunner:fire(state, entry, action, kind, requestId, ...)
end

local function handleAction(state, entry, kind, requestId, source, start, finish, refBase, refCount)
	if actionDebug then
		getCounters(entry.name).calls += 1
	end

	if not allow(state, 0, globalActionRate, globalActionBurst) then
		strike(state, globalActionViolation)
		if actionDebug then
			recordReject(state, entry, reasons.RateLimited)
		end

		return
	end

	local action = entry.action
	if not action then
		rejectAction(state, entry, kind, requestId, reasons.UnknownAction)
		return
	end

	if not allow(state, entry.id, entry.rateLimit, entry.burst) then
		rejectAction(state, entry, kind, requestId, reasons.RateLimited)
		return
	end

	local cooldown = action.cooldown
	local lastRun = state.cooldowns[entry.id]
	if cooldown and lastRun and os.clock() - lastRun < cooldown then
		rejectAction(state, entry, kind, requestId, reasons.Cooldown)
		return
	end

	local success, count, args = pcall(codec.decodeArgs, entry.tuple, source, start, finish, state.incomingRefs, refBase, refCount)
	if not success then
		rejectAction(state, entry, kind, requestId, reasons.InvalidArguments)
		return
	end

	checkAction(state, entry, action, kind, requestId, table.unpack(args, 1, count))
end

local function runInvoke(entry, state, requestId, args)
	local player = state.player
	if playerStates[player] ~= state then
		state.inflight -= 1
		return
	end

	local results = table.pack(pcall(entry.handler, player, table.unpack(args, 1, args.n)))
	state.inflight -= 1
	if playerStates[player] ~= state then
		return
	end

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

	appendMessage(state, nil, kindResponse, requestId, status, length, refCount)
end

local function handleResponse(state, requestId, status, source, start, finish, refBase, refCount)
	local request = pendingRequests[requestId]
	if not request or request.state ~= state or status > 1 then
		strike(state, 'unexpected response')
		return
	end

	local tuple = if status == 1 then request.entry.rets else nil
	local success, count, args = pcall(codec.decodeArgs, tuple, source, start, finish, state.incomingRefs, refBase, refCount)
	if not success then
		strike(state, 'malformed response for ' .. request.entry.name)
		resolveRequest(requestId, request, false, 'malformed response')
	elseif status == 1 then
		resolveRequest(requestId, request, true, table.unpack(args, 1, count))
	else
		resolveRequest(requestId, request, false, if type(args[1]) == 'string' then args[1] else 'client error')
	end
end

local function handleMessage(state, kind, id, extra, source, start, finish, refBase, refCount)
	if kind == kindResponse then
		handleResponse(state, id, extra, source, start, finish, refBase, refCount)
		return
	end

	local entry = entriesById[id]
	if not entry or entry.from == 'Server' then
		strike(state, 'unknown or server-only message ' .. id)
		return
	end

	if entry.kind == 'action' and kind ~= kindSync then
		handleAction(state, entry, kind, extra, source, start, finish, refBase, refCount)
		return
	end

	local expectedKind = if kind == kindEvent then 'event' elseif kind == kindRequest then 'function' else nil
	if entry.kind ~= expectedKind then
		strike(state, 'wrong message kind for ' .. entry.name)
		return
	end

	if not allow(state, entry.id, entry.rateLimit, entry.burst) then
		strike(state, 'rate limit exceeded on ' .. entry.name)
		return
	end

	local success, count, args = pcall(codec.decodeArgs, entry.tuple, source, start, finish, state.incomingRefs, refBase, refCount)
	if not success then
		strike(state, 'malformed ' .. entry.name .. ': ' .. tostring(count))
		return
	end

	if kind == kindEvent then
		entry.signal:fire(state.player, table.unpack(args, 1, count))
		return
	end

	if state.inflight >= maxInflightRequests then
		strike(state, 'too many concurrent requests on ' .. entry.name)
		return
	end

	args.n = count
	state.inflight += 1
	if entry.handler then
		task.spawn(runInvoke, entry, state, extra, args)
		return
	end

	local waiting = entry.waiting
	if #waiting >= maxWaitingRequests then
		state.inflight -= 1
		strike(state, 'no handler for ' .. entry.name)
		return
	end

	table.insert(waiting, { state, extra, args })
end

local function processIncoming(player, data, ...)
	local state = playerStates[player]
	if not state then
		return
	end

	if typeof(data) ~= 'buffer' then
		strike(state, 'invalid packet')
		return
	end

	local length = buffer.len(data)
	local refTotal = select('#', ...)
	if length > maxIncomingBytes or refTotal > maxIncomingRefs then
		strike(state, 'packet too large')
		return
	end

	stats.receivedBytes += length
	state.incomingRefs = if refTotal > 0 then { ... } else emptyRefs
	local success, result = pcall(packet.read, data, refTotal, handleMessage, state)
	state.incomingRefs = emptyRefs
	if success then
		stats.receivedMessages += result
	else
		strike(state, 'malformed packet: ' .. tostring(result))
	end
end

local function addPlayer(player)
	if playerStates[player] then
		return
	end

	local state = {
		player = player,
		reliable = packet.newBatch(),
		unreliable = packet.newBatch(),
		tokens = {},
		stamps = {},
		cooldowns = {},
		strikes = 0,
		inflight = 0,
		dirty = false,
		incomingRefs = emptyRefs,
	}
	playerStates[player] = state
	for _, entry in entriesById do
		appendSync(state, entry)
	end
end

local function removePlayer(player)
	local state = playerStates[player]
	if not state then
		return
	end

	playerStates[player] = nil
	for requestId, request in pendingRequests do
		if request.state == state then
			resolveRequest(requestId, request, false, 'player left')
		end
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
	local rateLimit = options.rateLimit
	if rateLimit == nil then
		rateLimit = defaultRateLimit
	end

	local id = #entriesById + 1
	entry = {
		id = id,
		name = name,
		kind = kind,
		unreliable = options.unreliable == true,
		tuple = idl.resolveTuple(options.data, aliases),
		rets = idl.resolveTuple(options.rets, aliases),
		from = options.from,
		rateLimit = rateLimit or nil,
		burst = options.burst or (if rateLimit then math.max(1, rateLimit) else nil),
		spec = options.spec,
		action = nil,
		violations = nil,
		timeout = options.timeout or defaultTimeout,
		signal = if kind == 'event' then signal.new() else nil,
		waiting = if kind == 'function' then {} else nil,
		handler = nil,
		oversizeWarned = false,
	}
	entriesByName[name] = entry
	entriesById[id] = entry
	entry.api = setmetatable({ entry = entry, Name = name }, if kind == 'event' then eventMeta else functionMeta)
	for _, state in playerStates do
		appendSync(state, entry)
	end

	return entry
end

local function assertServerCanSend(entry)
	if entry.from == 'Client' then
		error(('network %s can only be sent by clients'):format(entry.name), 3)
	end
end

function eventMeta:FireClient(player, ...)
	local entry = self.entry
	assertServerCanSend(entry)
	local state = playerStates[player]
	if not state then
		return
	end

	local length, refCount = codec.encodeArgs(entry.tuple, ...)
	appendMessage(state, entry, kindEvent, entry.id, 0, length, refCount)
end

function eventMeta:FireAll(...)
	local entry = self.entry
	assertServerCanSend(entry)
	local length, refCount = codec.encodeArgs(entry.tuple, ...)
	for _, state in playerStates do
		appendMessage(state, entry, kindEvent, entry.id, 0, length, refCount)
	end
end

function eventMeta:FireExcept(excludedPlayer, ...)
	local entry = self.entry
	assertServerCanSend(entry)
	local length, refCount = codec.encodeArgs(entry.tuple, ...)
	for player, state in playerStates do
		if player ~= excludedPlayer then
			appendMessage(state, entry, kindEvent, entry.id, 0, length, refCount)
		end
	end
end

function eventMeta:FireList(playerList, ...)
	local entry = self.entry
	assertServerCanSend(entry)
	local length, refCount = codec.encodeArgs(entry.tuple, ...)
	for _, player in playerList do
		local state = playerStates[player]
		if state then
			appendMessage(state, entry, kindEvent, entry.id, 0, length, refCount)
		end
	end
end

function eventMeta:Connect(callback)
	return self.entry.signal:connect(callback)
end

function eventMeta:Once(callback)
	return self.entry.signal:once(callback)
end

function eventMeta:Wait()
	return self.entry.signal:wait()
end

function functionMeta:OnInvoke(callback)
	local entry = self.entry
	entry.handler = callback
	if callback and #entry.waiting > 0 then
		local waiting = entry.waiting
		entry.waiting = {}
		for _, request in waiting do
			task.spawn(runInvoke, entry, request[1], request[2], request[3])
		end
	end
end

function functionMeta:InvokeClient(player, ...)
	local entry = self.entry
	assertServerCanSend(entry)
	local state = playerStates[player]
	if not state then
		return false, 'player not connected'
	end

	local length, refCount = codec.encodeArgs(entry.tuple, ...)
	nextRequestId = nextRequestId % maxRequestId + 1
	local requestId = nextRequestId
	local request = { thread = coroutine.running(), state = state, entry = entry, timeout = nil }
	pendingRequests[requestId] = request
	appendMessage(state, entry, kindRequest, entry.id, requestId, length, refCount)
	request.timeout = task.delay(entry.timeout, expireRequest, requestId, request)
	return coroutine.yield()
end

function net.loadEvent(name: string, options: { unreliable: boolean?, rateLimit: (number | false)?, data: any?, from: string? }?): ServerEventApi
	return register(name, 'event', options).api
end

function net.loadFunction(name: string, options: { rateLimit: (number | false)?, timeout: number?, data: any?, rets: any?, from: string? }?): ServerFunctionApi
	return register(name, 'function', options).api
end

function net.define(source)
	local parsed = if type(source) == 'string' then idl.parse(source) else source
	for name, typeObject in parsed.types or {} do
		aliases[name] = typeObject
	end

	local names = {}
	for name, definition in parsed.events or {} do
		definition.kind = 'event'
		definitions[name] = definition
		table.insert(names, name)
	end

	for name, definition in parsed.functions or {} do
		definition.kind = 'function'
		definitions[name] = definition
		table.insert(names, name)
	end

	table.sort(names)
	local apis = {}
	for _, name in names do
		apis[name] = register(name, definitions[name].kind, nil).api
	end

	return apis
end

function net.bindAction(name: string, options: ActionOptions?, handler: ActionHandler)
	local entry = entriesByName[name]
	if entry and entry.action then
		error(('network action %s is already bound'):format(name), 2)
	end

	local action = actions.compile(name, options, handler, middlewares, aliases)
	local rebinding = entry ~= nil
	local previousSpec = entry and entry.spec
	entry = register(name, 'action', { rateLimit = action.rate, burst = action.burst, data = action.tuple, spec = action.spec, from = 'Client' })
	if not entry.violations then
		local violations = {}
		for _, reason in reasons do
			violations[reason] = ('action %s: %s'):format(name, reason)
		end

		entry.violations = violations
	end

	entry.rateLimit = action.rate
	entry.burst = action.burst
	entry.tuple = action.tuple
	entry.spec = action.spec
	entry.action = action
	if rebinding and previousSpec ~= action.spec then
		for _, state in playerStates do
			appendSpec(state, entry)
		end
	end
end

function net.bindActions(bindings: { [string]: { any } })
	local names = {}
	for name in bindings do
		table.insert(names, name)
	end

	table.sort(names)
	for _, name in names do
		local binding = bindings[name]
		net.bindAction(name, binding[1], binding[2])
	end
end

function net.unbindAction(name: string): boolean
	local entry = entriesByName[name]
	if not entry or not entry.action then
		return false
	end

	entry.action = nil
	return true
end

function net.useActionMiddleware(name: string, callback: ActionMiddleware)
	assert(type(name) == 'string' and #name > 0, 'network middleware name must be a non-empty string')
	assert(type(callback) == 'function', 'network middleware must be a function')
	local middleware = middlewares[name]
	if middleware then
		middleware.run = callback
	else
		middlewares[name] = { name = name, run = callback }
	end
end

function net.setActionDebug(enabled: boolean)
	actionDebug = enabled == true
end

function net.getStats()
	local result = table.clone(stats)
	local actionStats: { [string]: ActionStats } = {}
	for name, counters in actionCounters do
		actionStats[name] = {
			calls = counters.calls,
			rejects = table.clone(counters.rejects),
			averageHandlerTime = if counters.handled > 0 then counters.handlerTime / counters.handled else 0,
		}
	end

	result.actions = actionStats
	return result
end

actionSpecEntry = register('__ActionSpec', 'event', { from = 'Server', data = '(string, string)' })
actionFailedEntry = register('__ActionFailed', 'event', { from = 'Server', data = '(uint, string)' })
actionRunner:connect(runAction)

for _, player in players:GetPlayers() do
	addPlayer(player)
end

local protocolModule = network:FindFirstChild('Protocol')
if protocolModule then
	net.define(require(protocolModule))
end

players.PlayerAdded:Connect(addPlayer)
players.PlayerRemoving:Connect(removePlayer)
masterRemote.OnServerEvent:Connect(processIncoming)
masterUnreliableRemote.OnServerEvent:Connect(processIncoming)
runService.Heartbeat:Connect(function()
	local count = dirtyCount
	dirtyCount = 0
	for index = 1, count do
		local state = dirtyStates[index]
		dirtyStates[index] = nil
		if playerStates[state.player] == state then
			local success, result = pcall(flushState, state)
			if not success then
				warn('network flush failed for ' .. state.player.Name .. ': ' .. tostring(result))
			end
		else
			state.dirty = false
		end
	end
end)

return net
