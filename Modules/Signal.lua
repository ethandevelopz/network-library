local signal = {}
signal.__index = signal

function signal.new()
	return setmetatable({ listeners = {} }, signal)
end

function signal:connect(callback)
	local connection = {}
	connection.callback = callback
	connection.connected = true
	connection.owner = self
	function connection:disconnect()
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
	connection.Disconnect = connection.disconnect
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