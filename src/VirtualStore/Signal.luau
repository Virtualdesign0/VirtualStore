--!strict

local Signal = {}
Signal.__index = Signal

export type Connection = {
	Connected: boolean,
	Disconnect: (self: Connection) -> (),
	_signal: any,
}

export type Signal = typeof(setmetatable({} :: {
	_listeners: {[Connection]: (...any) -> ()},
	_destroyed: boolean,
}, Signal))

function Signal.new(): Signal
	return setmetatable({
		_listeners = {},
		_destroyed = false,
	}, Signal) :: any
end

function Signal:Connect(callback: (...any) -> ()): Connection
	local signal: any = self
	assert(not signal._destroyed, "Cannot connect to a destroyed signal")
	assert(type(callback) == "function", "Signal callback must be a function")

	local connection = {
		Connected = true,
	} :: any

	function connection:Disconnect()
		if not self.Connected then
			return
		end

		self.Connected = false
		Signal._disconnect(self._signal, self)
	end

	connection._signal = signal
	signal._listeners[connection] = callback
	return connection
end

function Signal._disconnect(self: Signal, connection: Connection)
	self._listeners[connection] = nil
end

function Signal:Once(callback: (...any) -> ()): Connection
	local connection: Connection
	connection = self:Connect(function(...)
		connection:Disconnect()
		callback(...)
	end)
	return connection
end

function Signal:Fire(...: any)
	local signal: any = self
	if signal._destroyed then
		return
	end

	local arguments = table.pack(...)
	for connection, callback in signal._listeners do
		if connection.Connected then
			task.spawn(callback, table.unpack(arguments, 1, arguments.n))
		end
	end
end

function Signal:Wait(): ...any
	local waitingThread = coroutine.running()
	local connection: Connection

	connection = self:Connect(function(...)
		connection:Disconnect()
		task.spawn(waitingThread, ...)
	end)

	return coroutine.yield()
end

function Signal:Destroy()
	local signal: any = self
	if signal._destroyed then
		return
	end

	signal._destroyed = true
	for connection in signal._listeners do
		connection.Connected = false
	end
	table.clear(signal._listeners)
end

return Signal
