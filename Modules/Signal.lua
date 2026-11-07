local signal = {}
local connectionMeta = {}
local freeRunner = nil
signal.__index = signal
connectionMeta.__index = connectionMeta

local function acquireRunnerAndCall(callback, ...)
	local runner = freeRunner
	freeRunner = nil
	callback(...)
	freeRunner = runner
end

local function runEventHandlerInFreeThread(...)
	acquireRunnerAndCall(...)
	while true do
		acquireRunnerAndCall(coroutine.yield())
	end
end

function connectionMeta:disconnect()
	if not self.connected then
		return
	end

	self.connected = false
	local owner = self.owner
	local previous, nextConnection = self.previous, self.nextConnection
	if previous then
		previous.nextConnection = nextConnection
	else
		owner.head = nextConnection
	end

	if nextConnection then
		nextConnection.previous = previous
	else
		owner.tail = previous
	end

	owner.count -= 1
end

connectionMeta.Disconnect = connectionMeta.disconnect

function signal.new()
	return setmetatable({ head = nil, tail = nil, count = 0 }, signal)
end

function signal:connect(callback)
	local connection = setmetatable({ callback = callback, connected = true, owner = self, previous = self.tail, nextConnection = nil }, connectionMeta)
	if self.tail then
		self.tail.nextConnection = connection
	else
		self.head = connection
	end

	self.tail = connection
	self.count += 1
	return connection
end

function signal:once(callback)
	local connection
	connection = self:connect(function(...)
		connection:disconnect()
		callback(...)
	end)
	return connection
end

function signal:fire(...)
	local connection = self.head
	while connection do
		if connection.connected then
			if freeRunner then
				task.spawn(freeRunner, connection.callback, ...)
			else
				freeRunner = coroutine.create(runEventHandlerInFreeThread)
				task.spawn(freeRunner, connection.callback, ...)
			end
		end

		connection = connection.nextConnection
	end
end

function signal:wait()
	local thread = coroutine.running()
	self:once(function(...)
		task.spawn(thread, ...)
	end)
	return coroutine.yield()
end

function signal:disconnectAll()
	local connection = self.head
	while connection do
		connection.connected = false
		connection = connection.nextConnection
	end

	self.head = nil
	self.tail = nil
	self.count = 0
end

signal.Connect = signal.connect
signal.Once = signal.once
signal.Fire = signal.fire
signal.Wait = signal.wait
signal.DisconnectAll = signal.disconnectAll
return signal
