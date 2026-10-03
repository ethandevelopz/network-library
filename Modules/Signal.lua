local signal = {}
signal.__index = signal

local connectionMeta = {}
connectionMeta.__index = connectionMeta

function connectionMeta:disconnect()
	if not self.connected then
		return
	end
	self.connected = false
	for index, listener in ipairs(self.owner.listeners) do
		if listener == self then
			table.remove(self.owner.listeners, index)
			break
		end
	end
end
connectionMeta.Disconnect = connectionMeta.disconnect

function signal.new()
	return setmetatable({ listeners = {} }, signal)
end

function signal:connect(callback)
	local connection = setmetatable({ callback = callback, connected = true, owner = self }, connectionMeta)
	table.insert(self.listeners, connection)
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
	for _, listener in ipairs(table.clone(self.listeners)) do
		if listener.connected then
			task.spawn(listener.callback, ...)
		end
	end
end

return signal