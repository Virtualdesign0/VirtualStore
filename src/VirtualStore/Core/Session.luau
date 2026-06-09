--!nonstrict

local SessionApi = {}

function SessionApi.install(Session: any, dependencies: {
	Util: any,
	VirtualStore: any,
	makeError: any,
	setSessionData: any,
	emitSessionChange: any,
	})
	local Util = dependencies.Util
	local VirtualStore = dependencies.VirtualStore
	local makeError = dependencies.makeError
	local setSessionData = dependencies.setSessionData
	local emitSessionChange = dependencies.emitSessionChange

	function Session:_beginOperation()
		while self._operationRunning do
			self._operationFinished:Wait()
		end
		self._operationRunning = true
	end

	function Session:_endOperation()
		self._operationRunning = false
		self._operationFinished:Fire()
	end

	function Session:IsActive(): boolean
		return self._state == "Active"
	end

	function Session:GetState(): string
		return self._state
	end

	function Session:GetMetadata(): {[string]: any}
		return Util.deepCopy(self._meta)
	end

	function Session:GetData(): any
		return self.Data
	end

	function Session:Get(path: any): any
		return Util.deepCopy(Util.getPath(self._data, Util.normalizePath(path)))
	end

	function Session:GetTag(name: string): any
		assert(type(name) == "string", "Tag name must be a string")
		return Util.deepCopy(self._meta.Tags[name])
	end

	function Session:SetTag(name: string, value: any)
		assert(self:IsActive(), "Cannot change tags on an inactive session")
		assert(type(name) == "string", "Tag name must be a string")

		local valid, message = Util.validateData({
			Value = value,
		})
		assert(valid, message or "Tag value is invalid")
		local oldValue = Util.deepCopy(self._meta.Tags[name])
		if Util.deepEqual(oldValue, value) then
			return
		end
		self._meta.Tags[name] = Util.deepCopy(value)
		self._metadataDirty = true
		emitSessionChange(self, "SetTag", {{
			Path = {"$metadata", "Tags", name},
			Old = oldValue,
			New = Util.deepCopy(value),
		}})
	end

	function Session:AddUserId(userId: number)
		assert(self:IsActive(), "Cannot add a user id to an inactive session")
		assert(type(userId) == "number" and userId > 0 and userId == math.floor(userId), "User id must be a positive integer")
		if not table.find(self._meta.UserIds, userId) then
			table.insert(self._meta.UserIds, userId)
			self._metadataDirty = true
			emitSessionChange(self, "AddUserId", {{
				Path = {"$metadata", "UserIds"},
				Old = nil,
				New = Util.deepCopy(self._meta.UserIds),
			}})
		end
	end

	function Session:RemoveUserId(userId: number): boolean
		assert(self:IsActive(), "Cannot remove a user id from an inactive session")
		local oldUserIds = Util.deepCopy(self._meta.UserIds)
		local removed = Util.removeValue(self._meta.UserIds, userId)
		if removed then
			self._metadataDirty = true
			emitSessionChange(self, "RemoveUserId", {{
				Path = {"$metadata", "UserIds"},
				Old = oldUserIds,
				New = Util.deepCopy(self._meta.UserIds),
			}})
		end
		return removed
	end

	function Session:Reconcile()
		assert(self:IsActive(), "Cannot reconcile an inactive session")
		local workingData = Util.deepCopy(self._data)
		Util.reconcile(workingData, self._store.Template)
		return self:_commitWorkingData(workingData, "Reconcile")
	end

	function Session:_commitWorkingData(workingData: {[any]: any}, reason: string, source: string?): (boolean, any?)
		local validationError = self._store:_validateForSave(workingData, self._meta)
		if validationError then
			validationError.Key = self.Key
			return false, validationError
		end
		local changes = Util.diff(self._data, workingData)
		if #changes == 0 then
			return true, nil
		end
		setSessionData(self, workingData)
		emitSessionChange(self, reason, changes, source)
		return true, nil
	end

	function Session:IsDirty(): boolean
		if not self._dirty and not Util.deepEqual(self._data, self._cleanData) then
			emitSessionChange(self, "DirectMutation", Util.diff(self._cleanData, self._data))
		end
		return self._dirty or self._metadataDirty
	end

	function Session:MarkDirty(reason: string?)
		if self._dirty then
			return
		end
		self._dirty = true
		self._changeRevision += 1
		self.OnChanged:Fire({
			Reason = reason or "ManualDirty",
			At = os.time(),
			Revision = self._changeRevision,
			Paths = {},
		})
	end

	function Session:MarkClean()
		self._cleanData = Util.deepCopy(self._data)
		self._dirty = false
		self._metadataDirty = false
	end

	function Session:GetDiff(): {any}
		return Util.diff(self._cleanData, self._data)
	end

	function Session:GetAuditLog(): {any}
		return Util.deepCopy(self._auditLog)
	end

	function Session:IsLocked(name: string): boolean
		assert(type(name) == "string" and #name > 0, "Lock name must be a non-empty string")
		return self._locks[name] ~= nil
	end

	function Session:WithLock(name: string, callback: (any, any) -> ...any): (boolean, ...any)
		assert(type(name) == "string" and #name > 0, "Lock name must be a non-empty string")
		assert(type(callback) == "function", "Lock callback must be a function")
		if not self:IsActive() then
			return false, makeError("SessionInactive", "Cannot lock an inactive session", self.Key)
		end
		if self._locks[name] then
			return false, makeError("ResourceLocked", `Resource "{name}" is already locked`, self.Key)
		end

		self._locks[name] = true
		local results = table.pack(pcall(callback, self.Data, self))
		self._locks[name] = nil
		if not results[1] then
			return false, makeError("LockCallbackFailed", `Locked callback "{name}" failed`, self.Key, tostring(results[2]))
		end
		return true, table.unpack(results, 2, results.n)
	end

	function Session:WithLockTransaction(name: string, callback: ({[any]: any}) -> any): (boolean, any?)
		assert(type(name) == "string" and #name > 0, "Lock name must be a non-empty string")
		assert(type(callback) == "function", "Lock transaction callback must be a function")
		if not self:IsActive() then
			return false, makeError("SessionInactive", "Cannot lock an inactive session", self.Key)
		end
		if self._locks[name] then
			return false, makeError("ResourceLocked", `Resource "{name}" is already locked`, self.Key)
		end

		self._locks[name] = true
		local ok, virtualError = self:Transaction(callback, {
			Reason = "LockTransaction",
		})
		self._locks[name] = nil
		return ok, virtualError
	end

	function Session:QueueOperationAsync(operationId: string, operationType: string, payload: {[any]: any}): (any?, any?)
		if not self:IsActive() then
			return nil, makeError("SessionInactive", "Cannot queue an operation from an inactive session", self.Key)
		end
		return self._store:QueueOperationAsync(self.Key, operationId, operationType, payload)
	end

	function Session:GetOperationAsync(operationId: string): (any?, any?)
		return self._store:GetOperationAsync(self.Key, operationId)
	end

	function Session:ProcessOperationsAsync(): (boolean, any?)
		if not self:IsActive() then
			return false, makeError("SessionInactive", "Cannot process operations on an inactive session", self.Key)
		end
		return self:SaveAsync("Operations", {
			Force = true,
		})
	end

	function Session:CheckpointAsync(reason: string?): (boolean, any?)
		return self:SaveAsync(reason or "Checkpoint", {
			Force = true,
		})
	end

	function Session:Snapshot(): {[any]: any}
		return Util.deepCopy(self._data)
	end

	function Session:Transaction(callback: ({[any]: any}) -> any, options: {[string]: any}?): (boolean, any?)
		assert(type(callback) == "function", "Transaction callback must be a function")
		local transactionOptions = options or {}
		assert(type(transactionOptions) == "table", "Transaction options must be a table")
		if not self:IsActive() then
			return false, makeError("SessionInactive", "Cannot transact on an inactive session", self.Key)
		end

		self:_beginOperation()
		if not self:IsActive() then
			self:_endOperation()
			return false, makeError("SessionInactive", "Session became inactive before transaction", self.Key)
		end

		local workingData = Util.deepCopy(self._data)
		local ok, result = pcall(callback, workingData)
		if not ok then
			self:_endOperation()
			return false, makeError("TransactionFailed", "Transaction callback failed", self.Key, tostring(result))
		end
		if result == VirtualStore.Cancel then
			self:_endOperation()
			return false, makeError("Cancelled", "Transaction was cancelled", self.Key)
		end
		if result ~= nil then
			if type(result) ~= "table" then
				self:_endOperation()
				return false, makeError("TransactionFailed", "Transaction must return a table, VirtualStore.Cancel, or nil", self.Key)
			end
			workingData = result
		end

		local committed, commitError = self:_commitWorkingData(
			workingData,
			transactionOptions.Reason or "Transaction",
			transactionOptions.Source
		)
		self:_endOperation()
		return committed, commitError
	end

	function Session:Set(path: any, value: any, options: {[string]: any}?): (boolean, any?)
		local normalized = Util.normalizePath(path)
		return self:Transaction(function(data)
			Util.setPath(data, normalized, Util.deepCopy(value))
		end, {
			Reason = (options and options.Reason) or "Set",
			Source = options and options.Source,
		})
	end

	function Session:Patch(path: any, callback: (any) -> any, options: {[string]: any}?): (boolean, any?)
		assert(type(callback) == "function", "Patch callback must be a function")
		local normalized = Util.normalizePath(path)
		return self:Transaction(function(data)
			local result = callback(Util.deepCopy(Util.getPath(data, normalized)))
			if result == VirtualStore.Cancel then
				return VirtualStore.Cancel
			end
			Util.setPath(data, normalized, Util.deepCopy(result))
			return nil
		end, {
			Reason = (options and options.Reason) or "Patch",
			Source = options and options.Source,
		})
	end

	function Session:Increment(path: any, amount: number, options: {[string]: any}?): (boolean, any?)
		assert(type(amount) == "number", "Increment amount must be a number")
		return self:Patch(path, function(value)
			assert(type(value) == "number", "Increment target must be a number")
			return value + amount
		end, {
			Reason = (options and options.Reason) or "Increment",
			Source = options and options.Source,
		})
	end

	function Session:Insert(path: any, value: any, index: number?, options: {[string]: any}?): (boolean, any?)
		local normalized = Util.normalizePath(path)
		return self:Transaction(function(data)
			local target = Util.getPath(data, normalized)
			assert(type(target) == "table", "Insert target must be an array")
			if index then
				table.insert(target, index, Util.deepCopy(value))
			else
				table.insert(target, Util.deepCopy(value))
			end
		end, {
			Reason = (options and options.Reason) or "Insert",
			Source = options and options.Source,
		})
	end

	function Session:Remove(path: any, valueOrIndex: any?, options: {[string]: any}?): (boolean, any?)
		local normalized = Util.normalizePath(path)
		return self:Transaction(function(data)
			if valueOrIndex == nil then
				Util.setPath(data, normalized, nil)
				return
			end
			local target = Util.getPath(data, normalized)
			assert(type(target) == "table", "Remove target must be an array when a value or index is provided")
			local index = if type(valueOrIndex) == "number" then valueOrIndex else table.find(target, valueOrIndex)
			if index then
				table.remove(target, index)
			end
		end, {
			Reason = (options and options.Reason) or "Remove",
			Source = options and options.Source,
		})
	end

	function Session:SaveAsync(reason: string?, options: {[string]: any}?): (boolean, any?, boolean?)
		if not self:IsActive() then
			return false, makeError("SessionInactive", "Cannot save an inactive session", self.Key)
		end
		local saveOptions = options or {}
		assert(type(saveOptions) == "table", "SaveAsync options must be a table")

		self:_beginOperation()
		if not self:IsActive() then
			self:_endOperation()
			return false, makeError("SessionInactive", "Session became inactive before save", self.Key)
		end
		if reason == "AutoSave" and os.clock() < self._nextSaveAt then
			self:_endOperation()
			return true, nil, false
		end
		if reason == "AutoSave"
			and not saveOptions.Force
			and not self:IsDirty()
			and self._meta.PendingOperationCount == 0
			and os.clock() < self._leaseRenewAt
		then
			self._nextSaveAt = math.min(
				os.clock() + self._store.Settings.AutoSaveInterval,
				self._leaseRenewAt
			)
			self._store._metrics.CleanAutoSavesSkipped += 1
			self:_endOperation()
			return true, nil, false
		end

		local ok, virtualError = self._store:_commitSession(self, false, reason or "Manual")
		self:_endOperation()
		return ok, virtualError, ok
	end

	function Session:ReleaseAsync(reason: string?): (boolean, any?)
		if self._state == "Released" then
			return true, nil
		end
		if self._state == "LeaseLost" then
			return false, makeError("LeaseLost", "Session lease was already lost", self.Key)
		end
		if self._state == "Releasing" then
			while self._state == "Releasing" do
				self._stateChanged:Wait()
			end
			return self._state == "Released", nil
		end

		self._state = "Releasing"
		self._stateChanged:Fire(self._state)
		self:_beginOperation()
		local ok, virtualError = self._store:_commitSession(self, true, reason or "ManualRelease")
		if ok and self._state ~= "LeaseLost" then
			self._store:_finishSession(self, reason or "ManualRelease")
		elseif self._state ~= "LeaseLost" then
			self._state = "Active"
			self._stateChanged:Fire(self._state)
		end
		self:_endOperation()
		return ok, virtualError
	end

	function Session:Release(reason: string?)
		task.spawn(function()
			self:ReleaseAsync(reason)
		end)
	end
end

return SessionApi
