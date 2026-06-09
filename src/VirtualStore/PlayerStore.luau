--!nonstrict

local Players = game:GetService("Players")

local ReplicationServer = require(script.Parent.ReplicationServer)
local Signal = require(script.Parent.Signal)

local PlayerStore = {}
PlayerStore.__index = PlayerStore

local function makeError(code: string, message: string, cause: any?)
	return {
		Code = code,
		Message = message,
		Cause = cause,
	}
end

function PlayerStore.new(config: {[string]: any}, createStore: ({[string]: any}) -> any)
	assert(type(config) == "table", "VirtualStore.players expects a config table")
	assert(config.Key == nil or type(config.Key) == "function", "VirtualStore.players Key must be a function")
	assert(config.KeyPrefix == nil or type(config.KeyPrefix) == "string", "VirtualStore.players KeyPrefix must be a string")
	assert(config.KickMessage == nil or type(config.KickMessage) == "string", "VirtualStore.players KickMessage must be a string")
	assert(config.KickOnLoadFailure == nil or type(config.KickOnLoadFailure) == "boolean", "VirtualStore.players KickOnLoadFailure must be a boolean")

	local self = setmetatable({
		Store = createStore(config),
		Loaded = Signal.new(),
		Released = Signal.new(),
		Failed = Signal.new(),
		StateChanged = Signal.new(),
		_players = config.PlayerService or Players,
		_key = config.Key,
		_keyPrefix = config.KeyPrefix or "Player_",
		_kickMessage = config.KickMessage or "Your data could not be loaded. Please rejoin.",
		_kickOnLoadFailure = config.KickOnLoadFailure ~= false,
		_kickOnUnexpectedRelease = config.KickOnUnexpectedRelease ~= false,
		_addUserId = config.AddUserId ~= false,
		_loadAttempts = config.LoadAttempts or 3,
		_loadRetryDelay = config.LoadRetryDelay or 2,
		_sessions = {},
		_loading = {},
		_failures = {},
		_states = {},
		_leaving = {},
		_connections = {},
		_started = false,
		_closed = false,
		_replication = nil,
	}, PlayerStore)
	assert(type(self._loadAttempts) == "number" and self._loadAttempts >= 1 and self._loadAttempts == math.floor(self._loadAttempts), "LoadAttempts must be a positive integer")
	assert(type(self._loadRetryDelay) == "number" and self._loadRetryDelay >= 0, "LoadRetryDelay must be non-negative")
	if config.Replication then
		self._replication = ReplicationServer.new(self, config.Replication)
	end

	if config.AutoStart ~= false then
		self:Start()
	end
	return self
end

function PlayerStore:_setState(player: Player, state: string, detail: any?)
	self._states[player] = state
	self.StateChanged:Fire(player, state, detail)
end

function PlayerStore:_getKey(player: Player): string
	if self._key then
		local key = self._key(player)
		assert(type(key) == "string" and #key > 0, "VirtualStore.players Key callback must return a non-empty string")
		return key
	end
	return `{self._keyPrefix}{player.UserId}`
end

function PlayerStore:_isPresent(player: Player): boolean
	return player:IsDescendantOf(self._players)
end

function PlayerStore:_fail(player: Player, virtualError: any)
	self._failures[player] = virtualError
	self:_setState(player, "Failed", virtualError)
	self.Failed:Fire(player, virtualError)
	warn(
		`VirtualStore player load failed for {player.Name} ({player.UserId}):`,
		virtualError and virtualError.Code,
		virtualError and virtualError.Message,
		virtualError and virtualError.Cause
	)
	if self._kickOnLoadFailure and not self._closed and self:_isPresent(player) then
		player:Kick(self._kickMessage)
	elseif not self:_isPresent(player) then
		self._failures[player] = nil
		self._leaving[player] = nil
		self._states[player] = nil
	end
end

function PlayerStore:_load(player: Player)
	if self._closed or self._sessions[player] or self._loading[player] then
		return
	end

	self._loading[player] = true
	self._failures[player] = nil
	self:_setState(player, "Loading")
	local keyOk, keyOrCause = pcall(self._getKey, self, player)
	if not keyOk then
		self._loading[player] = nil
		self:_fail(player, makeError("PlayerKeyFailed", "Player key callback failed", tostring(keyOrCause)))
		return
	end

	local session = nil
	local virtualError = nil
	local token = self.Store:CreateId("load")
	for attempt = 1, self._loadAttempts do
		local openOk, sessionOrCause, errorResult = pcall(self.Store.OpenAsync, self.Store, keyOrCause, {
			Token = token,
		})
		if not openOk then
			virtualError = makeError("PlayerOpenFailed", "Player data open raised an error", tostring(sessionOrCause))
			break
		end
		session = sessionOrCause
		virtualError = errorResult
		if session then
			break
		end
		if self._closed or self._leaving[player] or not self:_isPresent(player) then
			break
		end
		if attempt < self._loadAttempts then
			self:_setState(player, "Retrying", {
				Attempt = attempt,
				Error = virtualError,
			})
			task.wait(self._loadRetryDelay)
		end
	end
	self._loading[player] = nil

	if not session then
		self:_fail(player, virtualError or makeError("PlayerDataUnavailable", "Player data loading was cancelled"))
		return
	end

	if self._closed or self._leaving[player] or not self:_isPresent(player) then
		task.spawn(function()
			session:ReleaseAsync("PlayerLeftWhileLoading")
			self._leaving[player] = nil
			self._failures[player] = nil
			self._states[player] = nil
		end)
		return
	end

	if self._addUserId then
		session:AddUserId(player.UserId)
	end
	self._failures[player] = nil
	self._sessions[player] = session
	self:_setState(player, "Ready")

	session.OnReleased:Connect(function(reason)
		if self._sessions[player] == session then
			self._sessions[player] = nil
		end
		self.Released:Fire(player, reason)
		self:_setState(player, "Released", reason)
		if self._kickOnUnexpectedRelease and not self._leaving[player] and self:_isPresent(player) then
			player:Kick(self._kickMessage)
		end
		self._leaving[player] = nil
		self._failures[player] = nil
		if not self:_isPresent(player) then
			self._states[player] = nil
		end
	end)

	self.Loaded:Fire(player, session.Data, session)
end

function PlayerStore:_release(player: Player)
	self._leaving[player] = true
	self._failures[player] = nil
	self:_setState(player, "Releasing")
	local session = self._sessions[player]
	if session then
		local deadline = os.clock() + self.Store.Settings.CloseTimeout
		local lastError = nil
		while os.clock() < deadline do
			local state = session:GetState()
			if state == "Released" or state == "LeaseLost" then
				return
			end
			local released, releaseError = session:ReleaseAsync("PlayerRemoving")
			if released or session:GetState() == "Released" or session:GetState() == "LeaseLost" then
				return
			end
			lastError = releaseError
			task.wait(math.min(self.Store.Settings.CloseRetryInterval, math.max(0, deadline - os.clock())))
		end
		warn(
			`VirtualStore player release did not finish for {player.Name} ({player.UserId}):`,
			lastError and lastError.Code,
			lastError and lastError.Message,
			lastError and lastError.Cause
		)
	elseif not self._loading[player] then
		self._leaving[player] = nil
		self._states[player] = nil
	end
end

function PlayerStore:Start()
	if self._started or self._closed then
		return self
	end
	self._started = true

	table.insert(self._connections, self._players.PlayerAdded:Connect(function(player)
		task.spawn(function()
			self:_load(player)
		end)
	end))
	table.insert(self._connections, self._players.PlayerRemoving:Connect(function(player)
		task.spawn(function()
			self:_release(player)
		end)
	end))

	for _, player in self._players:GetPlayers() do
		task.spawn(function()
			self:_load(player)
		end)
	end
	return self
end

function PlayerStore:GetSession(player: Player): any?
	return self._sessions[player]
end

function PlayerStore:GetState(player: Player): string
	return self._states[player] or "Unknown"
end

function PlayerStore:IsLoaded(player: Player): boolean
	return self._sessions[player] ~= nil
end

function PlayerStore:Get(player: Player, path: any?): any
	local session = self._sessions[player]
	if not session then
		return nil
	end
	return if path == nil then session.Data else session:Get(path)
end

function PlayerStore:Await(player: Player, timeout: number?): ({[any]: any}?, any?)
	local deadline = os.clock() + (timeout or self.Store.Settings.OpenTimeout + 5)
	while not self._closed and self:_isPresent(player) do
		local session = self._sessions[player]
		if session then
			return session.Data, nil
		end
		if self._failures[player] then
			return nil, self._failures[player]
		end
		if not self._loading[player] and os.clock() >= deadline then
			break
		end
		task.wait(0.05)
	end
	return nil, makeError("PlayerDataUnavailable", "Player data did not become available")
end

function PlayerStore:Update(player: Player, callback: ({[any]: any}) -> any, options: {[string]: any}?): (boolean, any?)
	local session = self._sessions[player]
	if not session then
		return false, makeError("PlayerDataUnavailable", "Player data is not loaded")
	end
	return session:Transaction(callback, options)
end

PlayerStore.Wait = PlayerStore.Await
PlayerStore.Edit = PlayerStore.Update

function PlayerStore:GetPath(player: Player, path: any): any
	return self:Get(player, path)
end

function PlayerStore:Set(player: Player, path: any, value: any, options: {[string]: any}?): (boolean, any?)
	local session = self._sessions[player]
	if not session then
		return false, makeError("PlayerDataUnavailable", "Player data is not loaded")
	end
	return session:Set(path, value, options)
end

function PlayerStore:Patch(player: Player, path: any, callback: (any) -> any, options: {[string]: any}?): (boolean, any?)
	local session = self._sessions[player]
	if not session then
		return false, makeError("PlayerDataUnavailable", "Player data is not loaded")
	end
	return session:Patch(path, callback, options)
end

function PlayerStore:Increment(player: Player, path: any, amount: number, options: {[string]: any}?): (boolean, any?)
	local session = self._sessions[player]
	if not session then
		return false, makeError("PlayerDataUnavailable", "Player data is not loaded")
	end
	return session:Increment(path, amount, options)
end

PlayerStore.Add = PlayerStore.Increment

function PlayerStore:Insert(player: Player, path: any, value: any, index: number?, options: {[string]: any}?): (boolean, any?)
	local session = self._sessions[player]
	if not session then
		return false, makeError("PlayerDataUnavailable", "Player data is not loaded")
	end
	return session:Insert(path, value, index, options)
end

function PlayerStore:Remove(player: Player, path: any, valueOrIndex: any?, options: {[string]: any}?): (boolean, any?)
	local session = self._sessions[player]
	if not session then
		return false, makeError("PlayerDataUnavailable", "Player data is not loaded")
	end
	return session:Remove(path, valueOrIndex, options)
end

function PlayerStore:WithLock(player: Player, name: string, callback: (any, any) -> ...any): (boolean, ...any)
	local session = self._sessions[player]
	if not session then
		return false, makeError("PlayerDataUnavailable", "Player data is not loaded")
	end
	return session:WithLock(name, callback)
end

function PlayerStore:WithLockTransaction(player: Player, name: string, callback: ({[any]: any}) -> any): (boolean, any?)
	local session = self._sessions[player]
	if not session then
		return false, makeError("PlayerDataUnavailable", "Player data is not loaded")
	end
	return session:WithLockTransaction(name, callback)
end

function PlayerStore:_getDeliveryKey(target: any): (string?, any?)
	if type(target) == "number" then
		if self._key then
			return nil, makeError(
				"PlayerKeyRequired",
				"A Player instance is required for delivery when a custom Key callback is configured"
			)
		end
		return `{self._keyPrefix}{target}`, nil
	end

	local keyOk, keyOrCause = pcall(self._getKey, self, target)
	if not keyOk then
		return nil, makeError("PlayerKeyFailed", "Player key callback failed", tostring(keyOrCause))
	end
	return keyOrCause, nil
end

function PlayerStore:DeliverAsync(target: any, operationId: string, operationType: string, payload: {[any]: any}): (any?, any?)
	local key, keyError = self:_getDeliveryKey(target)
	if not key then
		return nil, keyError
	end
	return self.Store:QueueOperationAsync(key, operationId, operationType, payload)
end

function PlayerStore:GetDeliveryAsync(target: any, operationId: string): (any?, any?)
	local key, keyError = self:_getDeliveryKey(target)
	if not key then
		return nil, keyError
	end
	return self.Store:GetOperationAsync(key, operationId)
end

function PlayerStore:DeliverAndWaitAsync(
	target: any,
	operationId: string,
	operationType: string,
	payload: {[any]: any},
	timeout: number?
): (any?, any?)
	local queued, queueError = self:DeliverAsync(target, operationId, operationType, payload)
	if not queued then
		return nil, queueError
	end

	local key, keyError = self:_getDeliveryKey(target)
	if not key then
		return nil, keyError
	end
	return self.Store:AwaitOperationAsync(key, operationId, timeout)
end

function PlayerStore:SaveAsync(player: Player): (boolean, any?)
	local session = self._sessions[player]
	if not session then
		return false, makeError("PlayerDataUnavailable", "Player data is not loaded")
	end
	return session:SaveAsync("PlayerStoreManual")
end

function PlayerStore:CheckpointAsync(player: Player, reason: string?): (boolean, any?)
	local session = self._sessions[player]
	if not session then
		return false, makeError("PlayerDataUnavailable", "Player data is not loaded")
	end
	return session:CheckpointAsync(reason or "PlayerCheckpoint")
end

function PlayerStore:ReplicateNow(player: Player): boolean
	if not self._replication then
		return false
	end
	return self._replication:ReplicateNow(player, true)
end

function PlayerStore:ReleaseAsync(player: Player): (boolean, any?)
	self._leaving[player] = true
	local session = self._sessions[player]
	if not session then
		return true, nil
	end
	self._sessions[player] = nil
	return session:ReleaseAsync("PlayerStoreManual")
end

function PlayerStore:GetDiagnostics(): {[string]: any}
	local diagnostics = self.Store:GetDiagnostics()
	local loadedPlayers = 0
	for _ in self._sessions do
		loadedPlayers += 1
	end
	diagnostics.LoadedPlayers = loadedPlayers
	diagnostics.Replication = if self._replication then self._replication:GetDiagnostics() else nil
	return diagnostics
end

function PlayerStore:CloseAsync(): boolean
	if self._closed then
		return self.Store:CloseAsync()
	end
	self._closed = true
	for player in self._sessions do
		self._leaving[player] = true
	end
	for _, connection in self._connections do
		connection:Disconnect()
	end
	table.clear(self._connections)
	local closed = self.Store:CloseAsync()
	if self._replication then
		self._replication:Close()
	end
	return closed
end

return PlayerStore
