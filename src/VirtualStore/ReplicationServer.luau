--!nonstrict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Util = require(script.Parent.Util)

local ReplicationServer = {}
ReplicationServer.__index = ReplicationServer

local ROOT_NAME = "_VirtualStoreReplication"
local CLIENT_NAME = "VirtualStoreClient"

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

local function isArray(value: {[any]: any}): boolean
	local count = 0
	local largest = 0
	for key in value do
		if type(key) ~= "number" then
			return false
		end
		count += 1
		largest = math.max(largest, key)
	end
	return count > 0 and count == largest
end

local function appendPath(path: {any}, key: any): {any}
	local result = table.clone(path)
	table.insert(result, key)
	return result
end

local function diff(previous: any, current: any, path: {any}, patches: {any})
	if deepEqual(previous, current) then
		return
	end
	if type(previous) ~= "table" or type(current) ~= "table" or isArray(previous) or isArray(current) then
		table.insert(patches, {
			Path = table.clone(path),
			Value = Util.deepCopy(current),
		})
		return
	end

	for key, value in current do
		diff(previous[key], value, appendPath(path, key), patches)
	end
	for key in previous do
		if current[key] == nil then
			table.insert(patches, {
				Path = appendPath(path, key),
				Remove = true,
			})
		end
	end
end

local function diffPaths(previous: any, current: any, paths: {{any}}, patches: {any})
	for _, path in paths do
		if #path > 0 and path[1] ~= "$metadata" then
			diff(Util.getPath(previous, path), Util.getPath(current, path), path, patches)
		end
	end
end

local function normalizePaths(paths: {any}?): {{any}}?
	if paths == nil then
		return nil
	end
	local normalized = {}
	for index, path in paths do
		local keys = Util.normalizePath(path)
		assert(keys[1] ~= "$metadata", `Replication Paths entry {index} cannot expose metadata`)
		for pathIndex, key in keys do
			assert(type(key) == "string", `Replication Paths entry {index}[{pathIndex}] must be a string`)
		end
		table.insert(normalized, keys)
	end
	return normalized
end

local function pathIsPrefix(prefix: {any}, path: {any}): boolean
	if #prefix > #path then
		return false
	end
	for index, key in prefix do
		if path[index] ~= key then
			return false
		end
	end
	return true
end

local function pathsOverlap(left: {any}, right: {any}): boolean
	return pathIsPrefix(left, right) or pathIsPrefix(right, left)
end

local function projectPaths(data: {[any]: any}, paths: {{any}}): {[any]: any}
	local projected = {}
	for _, path in paths do
		local value = Util.getPath(data, path)
		if value ~= nil then
			Util.setPath(projected, path, Util.deepCopy(value))
		end
	end
	return projected
end

local function selectPublicPaths(changedPaths: {{any}}, publicPaths: {{any}}): {{any}}
	local selected = {}
	local seen = {}
	for _, publicPath in publicPaths do
		for _, changedPath in changedPaths do
			if pathsOverlap(publicPath, changedPath) then
				local key = table.concat(publicPath, "\0")
				if not seen[key] then
					seen[key] = true
					table.insert(selected, publicPath)
				end
				break
			end
		end
	end
	return selected
end

local function applyPatch(data: {[any]: any}, patch: {[string]: any}): {[any]: any}
	if #patch.Path == 0 then
		return Util.deepCopy(patch.Value)
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
		parent[key] = Util.deepCopy(patch.Value)
	end
	return data
end

local function getOrCreate(parent: Instance, className: string, name: string): Instance
	local existing = parent:FindFirstChild(name)
	if existing then
		assert(existing.ClassName == className, `{parent:GetFullName()}.{name} must be a {className}`)
		return existing
	end
	local instance = Instance.new(className)
	instance.Name = name
	instance.Parent = parent
	return instance
end

local function attachSession(self: any, player: Player, session: any)
	local previousConnections = self._sessionConnections[player]
	if previousConnections then
		for _, connection in previousConnections do
			connection:Disconnect()
		end
	end
	self._sessionConnections[player] = {
		session.OnChanged:Connect(function(change)
			self:ReplicateNow(player, false, change and change.Paths)
		end),
		session.OnSaved:Connect(function()
			self:ReplicateNow(player, false)
		end),
	}
	task.defer(function()
		self:ReplicateNow(player, true)
	end)
end

function ReplicationServer.new(playerStore: any, config: any)
	local options = if config == true then {} else config
	assert(type(options) == "table", "Replication must be true or a config table")
	local name = options.Name or playerStore.Store.Name
	local interval = if options.Interval == nil then 0.25 else options.Interval
	local requestCooldown = options.RequestCooldown or 0.5
	assert(type(name) == "string" and #name > 0 and #name <= 80, "Replication Name must be a non-empty string up to 80 characters")
	assert(type(interval) == "number" and interval >= 0, "Replication Interval must be non-negative")
	assert(type(requestCooldown) == "number" and requestCooldown >= 0, "Replication RequestCooldown must be non-negative")
	assert(options.Paths == nil or type(options.Paths) == "table", "Replication Paths must be an array of paths")
	assert(options.Transform == nil or type(options.Transform) == "function", "Replication Transform must be a function")
	local paths = normalizePaths(options.Paths)

	local root = getOrCreate(ReplicatedStorage, "Folder", ROOT_NAME)
	local installedClient = ReplicatedStorage:FindFirstChild(CLIENT_NAME)
	if installedClient then
		assert(installedClient:IsA("ModuleScript"), `{CLIENT_NAME} must be a ModuleScript`)
	else
		local clientModule = script.Parent.Client:Clone()
		clientModule.Name = CLIENT_NAME
		clientModule.Parent = ReplicatedStorage
	end
	assert(not root:FindFirstChild(name), `A VirtualStore replication channel named "{name}" already exists`)
	local channel = Instance.new("Folder")
	channel.Name = name
	channel.Parent = root
	local requestSnapshot = getOrCreate(channel, "RemoteFunction", "RequestSnapshot")
	local update = getOrCreate(channel, "RemoteEvent", "Update")

	local self = setmetatable({
		Name = name,
		_owner = playerStore,
		_interval = interval,
		_requestCooldown = requestCooldown,
		_paths = paths,
		_transform = options.Transform,
		_channel = channel,
		_requestSnapshot = requestSnapshot,
		_update = update,
		_snapshots = {},
		_lastRequestAt = {},
		_sessionConnections = {},
		_connections = {},
		_closed = false,
		_metrics = {
			Snapshots = 0,
			Patches = 0,
			PatchEntries = 0,
			PathScopedDiffs = 0,
			TransformFailures = 0,
			SnapshotRequests = 0,
			ThrottledRequests = 0,
		},
	}, ReplicationServer)

	requestSnapshot.OnServerInvoke = function(player)
		local now = os.clock()
		local lastRequestAt = self._lastRequestAt[player] or -math.huge
		if now - lastRequestAt < self._requestCooldown then
			self._metrics.ThrottledRequests += 1
			return {
				Kind = "Throttled",
			}
		end
		self._lastRequestAt[player] = now
		self._metrics.SnapshotRequests += 1
		return self:_snapshotPacket(player)
	end
	table.insert(self._connections, playerStore.Loaded:Connect(function(player)
		local session = playerStore:GetSession(player)
		if session then
			attachSession(self, player, session)
		end
	end))
	table.insert(self._connections, playerStore.Released:Connect(function(player, reason)
		self._snapshots[player] = nil
		self._lastRequestAt[player] = nil
		if self._sessionConnections[player] then
			for _, connection in self._sessionConnections[player] do
				connection:Disconnect()
			end
			self._sessionConnections[player] = nil
		end
		pcall(update.FireClient, update, player, {
			Kind = "Released",
			Reason = reason,
		})
	end))
	for player, session in playerStore._sessions do
		attachSession(self, player, session)
	end
	if interval > 0 then
		task.spawn(function()
			while not self._closed do
				task.wait(self._interval)
				for player in playerStore._sessions do
					self:ReplicateNow(player, false)
				end
			end
		end)
	end
	return self
end

function ReplicationServer:_project(player: Player, data: {[any]: any}): {[any]: any}?
	local projected
	if self._transform then
		local ok, result = pcall(self._transform, Util.deepCopy(data), player)
		if not ok or type(result) ~= "table" then
			self._metrics.TransformFailures += 1
			warn(`VirtualStore replication transform "{self.Name}" failed: {tostring(result)}`)
			return nil
		end
		projected = result
	elseif self._paths then
		projected = projectPaths(data, self._paths)
	else
		projected = Util.deepCopy(data)
	end
	local valid, message = Util.validateData(projected)
	if not valid then
		self._metrics.TransformFailures += 1
		warn(`VirtualStore replication projection "{self.Name}" is invalid: {message}`)
		return nil
	end
	return projected
end

function ReplicationServer:_current(player: Player): {[any]: any}?
	local session = self._owner:GetSession(player)
	if not session or not session:IsActive() then
		return nil
	end
	return self:_project(player, session:Snapshot())
end

function ReplicationServer:_snapshotPacket(player: Player): {[string]: any}
	local current = self:_current(player)
	if not current then
		return {
			Kind = "Loading",
			State = self._owner:GetState(player),
		}
	end
	local previous = self._snapshots[player]
	local revision = if previous then previous.Revision else 1
	if previous and not deepEqual(previous.Data, current) then
		revision += 1
	end
	self._snapshots[player] = {
		Revision = revision,
		Data = Util.deepCopy(current),
	}
	self._metrics.Snapshots += 1
	return {
		Kind = "Snapshot",
		Revision = revision,
		Data = current,
	}
end

function ReplicationServer:ReplicateNow(player: Player, forceSnapshot: boolean?, changedPaths: {{any}}?): boolean
	if self._closed then
		return false
	end
	local previous = self._snapshots[player]
	if forceSnapshot or not previous then
		local packet = self:_snapshotPacket(player)
		if packet.Kind ~= "Snapshot" then
			return false
		end
		pcall(self._update.FireClient, self._update, player, packet)
		return true
	end

	local current = self:_current(player)
	if not current then
		return false
	end
	local patches = {}
	local pathScoped = false
	if changedPaths and #changedPaths > 0 and not self._transform then
		local publicPaths = if self._paths then selectPublicPaths(changedPaths, self._paths) else changedPaths
		diffPaths(previous.Data, current, publicPaths, patches)
		pathScoped = true
		self._metrics.PathScopedDiffs += 1
	else
		diff(previous.Data, current, {}, patches)
	end
	if #patches == 0 then
		return false
	end
	local revision = previous.Revision + 1
	local nextSnapshot = if pathScoped then Util.deepCopy(previous.Data) else Util.deepCopy(current)
	if pathScoped then
		for _, patch in patches do
			nextSnapshot = applyPatch(nextSnapshot, patch)
		end
	end
	self._snapshots[player] = {
		Revision = revision,
		Data = nextSnapshot,
	}
	self._metrics.Patches += 1
	self._metrics.PatchEntries += #patches
	pcall(self._update.FireClient, self._update, player, {
		Kind = "Patch",
		Revision = revision,
		Patches = patches,
	})
	return true
end

function ReplicationServer:GetDiagnostics(): {[string]: any}
	return {
		Name = self.Name,
		Interval = self._interval,
		RequestCooldown = self._requestCooldown,
		Metrics = Util.deepCopy(self._metrics),
	}
end

function ReplicationServer:Close()
	if self._closed then
		return
	end
	self._closed = true
	for _, connection in self._connections do
		connection:Disconnect()
	end
	table.clear(self._connections)
	for _, connections in self._sessionConnections do
		for _, connection in connections do
			connection:Disconnect()
		end
	end
	table.clear(self._sessionConnections)
	self._requestSnapshot.OnServerInvoke = nil
	self._channel:Destroy()
	table.clear(self._snapshots)
	table.clear(self._lastRequestAt)
end

ReplicationServer._diff = diff
ReplicationServer._diffPaths = diffPaths
ReplicationServer._applyPatch = applyPatch
ReplicationServer._deepEqual = deepEqual
ReplicationServer._normalizePaths = normalizePaths
ReplicationServer._projectPaths = projectPaths
ReplicationServer._selectPublicPaths = selectPublicPaths

return ReplicationServer
