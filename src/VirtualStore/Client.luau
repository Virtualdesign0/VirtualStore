--!nonstrict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ROOT_NAME = "_VirtualStoreReplication"

local VirtualStoreClient = {}
local Replica = {}
Replica.__index = Replica

local replicas = {}

local function deepCopy(value: any, seen: {[any]: any}?): any
	if type(value) ~= "table" then
		return value
	end
	local visited = seen or {}
	if visited[value] then
		return visited[value]
	end
	local copy = {}
	visited[value] = copy
	for key, child in value do
		copy[deepCopy(key, visited)] = deepCopy(child, visited)
	end
	return copy
end

local function deepEqual(left: any, right: any): boolean
	if type(left) ~= type(right) then
		return false
	end
	if type(left) ~= "table" then
		return left == right
	end
	for key, value in left do
		if not deepEqual(value, right[key]) then
			return false
		end
	end
	for key in right do
		if left[key] == nil then
			return false
		end
	end
	return true
end

local function readPath(data: any, path: {any}): any
	local current = data
	for _, key in path do
		if type(current) ~= "table" then
			return nil
		end
		current = current[key]
	end
	return current
end

local function applyPatch(data: {[any]: any}, patch: {[string]: any}): {[any]: any}
	if #patch.Path == 0 then
		return deepCopy(patch.Value)
	end
	local parent = data
	for index = 1, #patch.Path - 1 do
		local key = patch.Path[index]
		if type(parent[key]) ~= "table" then
			parent[key] = {}
		end
		parent = parent[key]
	end
	local key = patch.Path[#patch.Path]
	if patch.Remove then
		parent[key] = nil
	else
		parent[key] = deepCopy(patch.Value)
	end
	return data
end

function Replica:_setState(state: string, detail: any?)
	if self._state == state then
		return
	end
	self._state = state
	self._stateEvent:Fire(state, detail)
end

function Replica:_requestSnapshot()
	if self._requesting or self._closed then
		return
	end
	self._requesting = true
	local ok, packet = pcall(self._request.InvokeServer, self._request)
	self._requesting = false
	if ok and packet then
		self:_receive(packet)
	end
end

function Replica:_receive(packet: {[string]: any})
	if self._closed then
		return
	end
	if packet.Kind == "Snapshot" then
		self._data = deepCopy(packet.Data)
		self._revision = packet.Revision
		self:_setState("Ready")
		self._changedEvent:Fire(self:Get(), nil)
	elseif packet.Kind == "Patch" then
		if not self._data or packet.Revision ~= self._revision + 1 then
			task.spawn(function()
				self:_requestSnapshot()
			end)
			return
		end
		for _, patch in packet.Patches do
			self._data = applyPatch(self._data, patch)
		end
		self._revision = packet.Revision
		self._changedEvent:Fire(self:Get(), deepCopy(packet.Patches))
	elseif packet.Kind == "Released" then
		self._data = nil
		self._revision = 0
		self:_setState("Released", packet.Reason)
		self._changedEvent:Fire(nil, nil)
	elseif packet.Kind == "Loading" then
		self:_setState(packet.State or "Loading")
	end
end

function Replica:Get(): {[any]: any}?
	return if self._data then deepCopy(self._data) else nil
end

function Replica:GetPath(...: any): any
	if not self._data then
		return nil
	end
	return deepCopy(readPath(self._data, {...}))
end

function Replica:GetState(): string
	return self._state
end

function Replica:Await(timeout: number?): ({[any]: any}?, string?)
	local deadline = os.clock() + (timeout or 15)
	while not self._closed and self._state ~= "Ready" and os.clock() < deadline do
		task.wait(0.05)
	end
	if self._state == "Ready" then
		return self:Get(), nil
	end
	return nil, self._state
end

function Replica:Observe(path: string | {any}, callback: (any) -> ()): any
	assert(type(callback) == "function", "Observe callback must be a function")
	local keys = if type(path) == "table" then table.clone(path) else {path}
	local previous = if self._data then deepCopy(readPath(self._data, keys)) else nil
	if self._data then
		task.defer(callback, deepCopy(previous))
	end
	return self.Changed:Connect(function()
		local current = if self._data then readPath(self._data, keys) else nil
		if not deepEqual(previous, current) then
			previous = deepCopy(current)
			callback(deepCopy(current))
		end
	end)
end

function Replica:Disconnect()
	if self._closed then
		return
	end
	self._closed = true
	self._connection:Disconnect()
	self._changedEvent:Destroy()
	self._stateEvent:Destroy()
	replicas[self.Name] = nil
end

function VirtualStoreClient.connect(name: string): any
	assert(type(name) == "string" and #name > 0, "VirtualStoreClient.connect expects a replication name")
	if replicas[name] then
		return replicas[name]
	end
	local root = ReplicatedStorage:WaitForChild(ROOT_NAME)
	local channel = root:WaitForChild(name)
	local changedEvent = Instance.new("BindableEvent")
	local stateEvent = Instance.new("BindableEvent")
	local self = setmetatable({
		Name = name,
		Changed = changedEvent.Event,
		StateChanged = stateEvent.Event,
		_changedEvent = changedEvent,
		_stateEvent = stateEvent,
		_request = channel:WaitForChild("RequestSnapshot"),
		_state = "Loading",
		_revision = 0,
		_data = nil,
		_requesting = false,
		_closed = false,
	}, Replica)
	self._connection = channel:WaitForChild("Update").OnClientEvent:Connect(function(packet)
		self:_receive(packet)
	end)
	replicas[name] = self
	task.spawn(function()
		while not self._closed and self._state ~= "Ready" do
			self:_requestSnapshot()
			if self._state ~= "Ready" then
				task.wait(0.5)
			end
		end
	end)
	return self
end

return VirtualStoreClient
