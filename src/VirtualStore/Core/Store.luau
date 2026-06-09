--!nonstrict

local StoreApi = {}

function StoreApi.install(Store: any, dependencies: {
	FormatVersion: number,
	HttpService: any,
	MessagingService: any,
	Session: any,
	Signal: any,
	Util: any,
	VirtualStore: any,
	copyPublicMetadata: any,
	copySnapshot: any,
	emitSessionChange: any,
	leaseIsActive: any,
	makeError: any,
	setSessionData: any,
	validateKey: any,
	validateOperationId: any,
	validateOperationType: any,
	})
	local FORMAT_VERSION = dependencies.FormatVersion
	local HttpService = dependencies.HttpService
	local MessagingService = dependencies.MessagingService
	local Session = dependencies.Session
	local Signal = dependencies.Signal
	local Util = dependencies.Util
	local VirtualStore = dependencies.VirtualStore
	local copyPublicMetadata = dependencies.copyPublicMetadata
	local copySnapshot = dependencies.copySnapshot
	local emitSessionChange = dependencies.emitSessionChange
	local leaseIsActive = dependencies.leaseIsActive
	local makeError = dependencies.makeError
	local setSessionData = dependencies.setSessionData
	local validateKey = dependencies.validateKey
	local validateOperationId = dependencies.validateOperationId
	local validateOperationType = dependencies.validateOperationType

	function Store:CreateId(prefix: string?): string
		return VirtualStore.id(prefix)
	end

	function Store:_authorizeAdmin(action: string, key: string, context: any): (boolean, any?)
		if type(self.AdminAuthorize) ~= "function" then
			self._metrics.AdminAccessDenied += 1
			return false, makeError(
				"AdminAccessDisabled",
				"Admin APIs are disabled until config.AdminAuthorize is configured",
				key
			)
		end
		local ok, allowed = pcall(self.AdminAuthorize, action, key, context)
		if not ok then
			self._metrics.AdminAccessDenied += 1
			return false, makeError("AdminAuthorizationFailed", "Admin authorization callback failed", key, tostring(allowed))
		end
		if allowed ~= true then
			self._metrics.AdminAccessDenied += 1
			return false, makeError("AdminAccessDenied", `Admin access denied for "{action}"`, key)
		end
		return true, nil
	end

	function Store:_call(operation: string, key: string, requestKind: string, callback: () -> any): (boolean, any)
		local lastCause: any = nil

		for attempt = 1, self.Settings.RetryAttempts do
			if type(self._adapter.WaitForBudgetAsync) == "function" then
				local waitStarted = os.clock()
				local budgetOk, budgetAvailable = pcall(
					self._adapter.WaitForBudgetAsync,
					self._adapter,
					requestKind,
					self.Settings.BudgetTimeout,
					self.Settings.BudgetPollInterval
				)
				local waitTime = os.clock() - waitStarted
				self._metrics.TotalBudgetWait += waitTime
				if waitTime >= self.Settings.BudgetPollInterval then
					self._metrics.BudgetWaits += 1
				end
				if not budgetOk or not budgetAvailable then
					self._metrics.BudgetTimeouts += 1
					local budgetError = makeError(
						"BudgetTimeout",
						`{operation} timed out waiting for {requestKind} request budget`,
						key,
						if budgetOk then nil else tostring(budgetAvailable)
					)
					budgetError.Operation = operation
					self:_emitError(budgetError)
					return false, budgetError
				end
			end

			self._metrics.Requests += 1
			local started = os.clock()
			local ok, result = pcall(callback)
			local elapsed = os.clock() - started
			if ok then
				self:_recordSuccess(operation, elapsed)
				return true, result
			end

			lastCause = result
			if attempt < self.Settings.RetryAttempts then
				self._metrics.Retries += 1
				local delaySeconds = self.Settings.RetryDelay * (self.Settings.RetryBackoff ^ (attempt - 1))
				task.wait(delaySeconds)
			end
		end

		local virtualError = makeError(
			"DataStoreError",
			`{operation} failed after {self.Settings.RetryAttempts} attempts`,
			key,
			tostring(lastCause),
			self.Settings.RetryAttempts
		)
		virtualError.Operation = operation
		self:_emitError(virtualError)
		return false, virtualError
	end

	local function countEntries(map: {[any]: any}): number
		local count = 0
		for _ in map do
			count += 1
		end
		return count
	end

	local function ledgerCounts(meta: {[string]: any}): {[string]: number}
		local operations = meta.Operations
		return {
			PendingOperations = countEntries(operations.Pending),
			OperationReceipts = countEntries(operations.Receipts),
			OperationDedupe = countEntries(operations.Dedupe),
			DeadLetters = countEntries(operations.DeadLetters),
			WriteReceipts = countEntries(meta.WriteReceipts),
		}
	end

	local function ledgerState(meta: {[string]: any}?): any
		if type(meta) ~= "table" then
			return nil
		end
		return {
			Operations = Util.deepCopy(meta.Operations),
			WriteReceipts = Util.deepCopy(meta.WriteReceipts),
			WriteReceiptOrder = Util.deepCopy(meta.WriteReceiptOrder),
		}
	end

	function Store:_createSession(key: string, token: string, record: {[string]: any})
		self._autoSaveSequence += 1
		local phase = (self._autoSaveSequence * 0.61803398875) % 1
		local firstSaveDelay = self.Settings.AutoSaveInterval * (0.5 + phase * 0.5)
		local session = setmetatable({
			Key = key,
			OnSaved = Signal.new(),
			OnChanged = Signal.new(),
			OnReleased = Signal.new(),
			HandoffRequested = Signal.new(),
			_store = self,
			_token = token,
			_meta = copyPublicMetadata(record.Meta),
			_state = "Active",
			_operationRunning = false,
			_operationFinished = Signal.new(),
			_stateChanged = Signal.new(),
			_locks = {},
			_dirty = false,
			_metadataDirty = false,
			_changeRevision = 0,
			_cleanData = Util.deepCopy(record.Data),
			_auditLog = {},
			_autoSaveRunning = false,
			_nextSaveAt = os.clock() + firstSaveDelay,
			_leaseRenewAt = os.clock() + self.Settings.LeaseTimeout / 2,
		}, Session)
		setSessionData(session, Util.deepCopy(record.Data))

		self._sessions[key] = session
		self.SessionOpened:Fire(session)
		return session
	end

	function Store:OpenAsync(key: string, options: {[string]: any}?): (any?, any?)
		validateKey(key)
		if self._closed then
			return nil, makeError("StoreClosed", "Store is closed", key)
		end
		if self._sessions[key] or self._opening[key] then
			return nil, makeError("AlreadyOpen", "This key is already open or opening on this server", key)
		end

		self._opening[key] = true
		local openOptions = options or {}
		local timeout = openOptions.Timeout or self.Settings.OpenTimeout
		local deadline = os.clock() + timeout
		local token = openOptions.Token or HttpService:GenerateGUID(false)
		assert(type(token) == "string" and #token > 0, "OpenAsync Token must be a non-empty string")
		local finalError: any? = nil

		while not self._closed do
			local claimed = false
			local conflictLease: any? = nil
			local decodedError: any? = nil
			local claimedRecord: any? = nil
			local appliedOperations = {}
			local operationFailures = {}

			local ok, callResult = self:_call("OpenAsync", key, "Update", function()
				return self._adapter:UpdateAsync(key, function(rawValue: any)
					claimed = false
					conflictLease = nil
					decodedError = nil
					claimedRecord = nil
					appliedOperations = {}
					operationFailures = {}

					local now = os.time()
					local record, decodeError, decodedDataChanged = self:_decode(rawValue, now)
					if not record then
						decodedError = decodeError
						return nil
					end

					local lease = record.Meta.Lease
					if leaseIsActive(lease, now) and lease.Token ~= token then
						conflictLease = Util.deepCopy(lease)
						return nil
					end

					local operationsChangedData
					record.Data, appliedOperations, operationFailures, operationsChangedData =
						self:_applyPendingOperations(record, record.Data, key)
					local operationValidationError = self:_validateForSave(record.Data, record.Meta)
					if operationValidationError then
						decodedError = operationValidationError
						return nil
					end
					record.Meta.Lease = {
						Token = token,
						PlaceId = game.PlaceId,
						JobId = game.JobId,
						AcquiredAt = now,
						RenewedAt = now,
						ExpiresAt = now + self.Settings.LeaseTimeout,
					}
					record.Meta.UpdatedAt = now
					record.Meta.Revision += 1
					if decodedDataChanged or operationsChangedData then
						record.Meta.DataRevision += 1
					end
					claimed = true
					claimedRecord = Util.deepCopy(record)
					return record, record.Meta.UserIds
				end)
			end)

			if not ok then
				finalError = callResult
				break
			end
			if decodedError then
				finalError = decodedError
				decodedError.Key = key
				self:_emitError(decodedError)
				break
			end
			if claimed and claimedRecord then
				self._opening[key] = nil
				self._metrics.OpenedSessions += 1
				self:_reportOperations(appliedOperations, operationFailures)
				return self:_createSession(key, token, claimedRecord), nil
			end

			if conflictLease then
				self:_requestHandoff(key, conflictLease)
			end
			if os.clock() >= deadline then
				finalError = makeError("LockTimeout", "Timed out waiting for the active session lease", key, conflictLease)
				break
			end

			task.wait(math.min(self.Settings.OpenRetryInterval, math.max(0, deadline - os.clock())))
		end

		self._opening[key] = nil
		return nil, finalError or makeError("StoreClosed", "Store closed while opening the session", key)
	end

	function Store:_commitSession(session: any, releaseLease: boolean, reason: string): (boolean, any?)
		local validationError = self:_validateForSave(session._data, session._meta)
		if validationError then
			validationError.Key = session.Key
			self:_emitError(validationError)
			return false, validationError
		end

		local dataSnapshot = Util.deepCopy(session._data)
		local metaSnapshot = Util.deepCopy(session._meta)
		local accepted = false
		local leaseLost = false
		local decodedError: any? = nil
		local committedRecord: any? = nil
		local appliedOperations = {}
		local operationFailures = {}
		local operationsChangedData = false
		local committedDataChanged = false
		local commitToken = VirtualStore.id("commit")
		local lastTransformedOperations = {}
		local lastTransformedRetries = {}

		local ok, callResult = self:_call("SaveAsync", session.Key, "Update", function()
			return self._adapter:UpdateAsync(session.Key, function(rawValue: any)
				accepted = false
				leaseLost = false
				decodedError = nil
				committedRecord = nil
				appliedOperations = {}
				operationFailures = {}
				operationsChangedData = false
				committedDataChanged = false

				local now = os.time()
				local record, decodeError, decodedDataChanged = self:_decode(rawValue, now)
				if not record then
					decodedError = decodeError
					return nil
				end

				local writeReceipt = record.Meta.WriteReceipts[commitToken]
				if writeReceipt or record.Meta.LastWriteToken == commitToken then
					accepted = true
					committedRecord = Util.deepCopy(record)
					appliedOperations = Util.deepCopy(lastTransformedOperations)
					operationFailures = Util.deepCopy(lastTransformedRetries)
					committedDataChanged = if writeReceipt then writeReceipt.ChangedData else record.Meta.LastWriteChangedData == true
					operationsChangedData = committedDataChanged
					return nil
				end

				local lease = record.Meta.Lease
				if type(lease) ~= "table" or lease.Token ~= session._token then
					leaseLost = true
					return nil
				end

				local storedData = Util.deepCopy(record.Data)
				record.Data, appliedOperations, operationFailures, operationsChangedData =
					self:_applyPendingOperations(record, dataSnapshot, session.Key)
				lastTransformedOperations = Util.deepCopy(appliedOperations)
				lastTransformedRetries = Util.deepCopy(operationFailures)
				local operationValidationError = self:_validateForSave(record.Data, record.Meta)
				if operationValidationError then
					decodedError = operationValidationError
					return nil
				end
				record.SchemaVersion = self.SchemaVersion
				record.Meta.UserIds = Util.deepCopy(metaSnapshot.UserIds)
				record.Meta.Tags = Util.deepCopy(metaSnapshot.Tags)
				record.Meta.UpdatedAt = now
				record.Meta.Revision += 1
				committedDataChanged = decodedDataChanged == true or not Util.deepEqual(storedData, record.Data)
				if committedDataChanged then
					record.Meta.DataRevision += 1
				end
				self:_rememberWrite(record.Meta, commitToken, committedDataChanged, now)

				if releaseLease then
					record.Meta.Lease = nil
				else
					record.Meta.Lease.RenewedAt = now
					record.Meta.Lease.ExpiresAt = now + self.Settings.LeaseTimeout
				end

				accepted = true
				committedRecord = Util.deepCopy(record)
				return record, record.Meta.UserIds
			end)
		end)

		if leaseLost then
			self:_finishSession(session, "LeaseLost")
			local leaseError = makeError("LeaseLost", "Session lease was lost before the save completed", session.Key)
			self._metrics.LeaseLosses += 1
			self:_emitError(leaseError)
			return false, leaseError
		end
		if not ok then
			return false, callResult
		end
		if decodedError then
			decodedError.Key = session.Key
			self:_emitError(decodedError)
			return false, decodedError
		end
		if not accepted or not committedRecord then
			local rejectedError = makeError("SaveRejected", "Save transform was rejected", session.Key)
			self:_emitError(rejectedError)
			return false, rejectedError
		end

		session._meta = copyPublicMetadata(committedRecord.Meta)
		if operationsChangedData then
			local operationChanges = Util.diff(session._data, committedRecord.Data)
			setSessionData(session, Util.deepCopy(committedRecord.Data))
			emitSessionChange(session, "Operation", operationChanges)
		end
		session._cleanData = Util.deepCopy(committedRecord.Data)
		session._dirty = not Util.deepEqual(session._data, session._cleanData)
		session._metadataDirty = false
		session._nextSaveAt = os.clock() + self.Settings.AutoSaveInterval
		session._leaseRenewAt = os.clock() + self.Settings.LeaseTimeout / 2
		self._metrics.Saves += 1
		self:_reportOperations(appliedOperations, operationFailures)
		session.OnSaved:Fire(reason, session._meta.Revision)
		return true
	end

	function Store:_finishSession(session: any, reason: string)
		if session._state == "Released" or session._state == "LeaseLost" then
			return
		end

		session._state = if reason == "LeaseLost" then "LeaseLost" else "Released"
		if self._sessions[session.Key] == session then
			self._sessions[session.Key] = nil
		end
		session._stateChanged:Fire(session._state)
		session.OnReleased:Fire(reason)
		self.SessionClosed:Fire(session, reason)
	end

	function Store:ViewAsync(key: string): (any?, any?)
		validateKey(key)
		local ok, rawOrError = self:_call("ViewAsync", key, "Read", function()
			return self._adapter:GetAsync(key)
		end)
		if not ok then
			return nil, rawOrError
		end

		local record, decodeError = self:_decode(rawOrError, os.time())
		if not record then
			decodeError.Key = key
			self:_emitError(decodeError)
			return nil, decodeError
		end

		return copySnapshot(record), nil
	end

	function Store:InspectMetadataAsync(key: string, adminContext: any): (any?, any?)
		validateKey(key)
		local authorized, authorizationError = self:_authorizeAdmin("InspectMetadata", key, adminContext)
		if not authorized then
			return nil, authorizationError
		end
		local ok, rawOrError = self:_call("InspectMetadataAsync", key, "Read", function()
			return self._adapter:GetAsync(key)
		end)
		if not ok then
			return nil, rawOrError
		end

		local record, decodeError = self:_decode(rawOrError, os.time())
		if not record then
			decodeError.Key = key
			self:_emitError(decodeError)
			return nil, decodeError
		end
		return {
			Key = key,
			IsOpenHere = self:IsOpen(key),
			Metadata = Util.deepCopy(record.Meta),
		}, nil
	end

	function Store:ListPendingOperationsAsync(key: string, adminContext: any): ({any}?, any?)
		validateKey(key)
		local authorized, authorizationError = self:_authorizeAdmin("ListPendingOperations", key, adminContext)
		if not authorized then
			return nil, authorizationError
		end
		local ok, rawOrError = self:_call("ListPendingOperationsAsync", key, "Read", function()
			return self._adapter:GetAsync(key)
		end)
		if not ok then
			return nil, rawOrError
		end

		local record, decodeError = self:_decode(rawOrError, os.time())
		if not record then
			decodeError.Key = key
			self:_emitError(decodeError)
			return nil, decodeError
		end

		local pending = {}
		for _, operation in record.Meta.Operations.Pending do
			table.insert(pending, Util.deepCopy(operation))
		end
		table.sort(pending, function(left, right)
			if left.CreatedAt == right.CreatedAt then
				return left.Id < right.Id
			end
			return left.CreatedAt < right.CreatedAt
		end)
		return pending, nil
	end

	function Store:ListDeadLettersAsync(key: string, adminContext: any): ({any}?, any?)
		validateKey(key)
		local authorized, authorizationError = self:_authorizeAdmin("ListDeadLetters", key, adminContext)
		if not authorized then
			return nil, authorizationError
		end
		local ok, rawOrError = self:_call("ListDeadLettersAsync", key, "Read", function()
			return self._adapter:GetAsync(key)
		end)
		if not ok then
			return nil, rawOrError
		end

		local record, decodeError = self:_decode(rawOrError, os.time())
		if not record then
			decodeError.Key = key
			self:_emitError(decodeError)
			return nil, decodeError
		end

		local deadLetters = {}
		for _, operationId in record.Meta.Operations.DeadLetterOrder do
			local deadLetter = record.Meta.Operations.DeadLetters[operationId]
			if deadLetter then
				table.insert(deadLetters, Util.deepCopy(deadLetter))
			end
		end
		return deadLetters, nil
	end

	function Store:ListVersionsAsync(key: string, options: {[string]: any}?): ({any}?, any?)
		validateKey(key)
		if type(self._adapter.ListVersionsAsync) ~= "function" then
			return nil, makeError("UnsupportedOperation", "This adapter does not support version listing", key)
		end

		local listOptions = options or {}
		assert(type(listOptions) == "table", "ListVersionsAsync options must be a table")
		assert(
			listOptions.MaxCount == nil
				or (type(listOptions.MaxCount) == "number"
					and listOptions.MaxCount >= 1
					and listOptions.MaxCount <= 1000
					and listOptions.MaxCount == math.floor(listOptions.MaxCount)),
			"MaxCount must be an integer from 1 to 1000"
		)

		local ok, versionsOrError = self:_call("ListVersionsAsync", key, "List", function()
			return self._adapter:ListVersionsAsync(key, listOptions)
		end)
		if not ok then
			return nil, versionsOrError
		end
		return versionsOrError, nil
	end

	function Store:ViewVersionAsync(key: string, version: string): (any?, any?)
		validateKey(key)
		assert(type(version) == "string" and #version > 0, "version must be a non-empty string")
		if type(self._adapter.GetVersionAsync) ~= "function" then
			return nil, makeError("UnsupportedOperation", "This adapter does not support version reads", key)
		end

		local ok, rawOrError = self:_call("ViewVersionAsync", key, "Read", function()
			return self._adapter:GetVersionAsync(key, version)
		end)
		if not ok then
			return nil, rawOrError
		end
		if rawOrError == nil then
			return nil, makeError("VersionNotFound", `Version "{version}" was not found`, key)
		end

		local record, decodeError = self:_decode(rawOrError, os.time())
		if not record then
			decodeError.Key = key
			self:_emitError(decodeError)
			return nil, decodeError
		end

		local snapshot = copySnapshot(record)
		snapshot.Version = version
		return snapshot, nil
	end

	function Store:ViewAtTimeAsync(key: string, timestampMillis: number): (any?, any?)
		validateKey(key)
		assert(type(timestampMillis) == "number" and timestampMillis > 0, "timestampMillis must be positive")
		if type(self._adapter.GetVersionAtTimeAsync) ~= "function" then
			return nil, makeError("UnsupportedOperation", "This adapter does not support time-based version reads", key)
		end

		local ok, rawOrError = self:_call("ViewAtTimeAsync", key, "Read", function()
			return self._adapter:GetVersionAtTimeAsync(key, timestampMillis)
		end)
		if not ok then
			return nil, rawOrError
		end
		if rawOrError == nil then
			return nil, makeError("VersionNotFound", "No version was available at that time", key)
		end

		local record, decodeError = self:_decode(rawOrError, os.time())
		if not record then
			decodeError.Key = key
			self:_emitError(decodeError)
			return nil, decodeError
		end
		return copySnapshot(record), nil
	end

	function Store:RestoreVersionAsync(key: string, version: string): (any?, any?)
		validateKey(key)
		assert(type(version) == "string" and #version > 0, "version must be a non-empty string")
		if self._closed then
			return nil, makeError("StoreClosed", "Store is closed", key)
		end
		if self._sessions[key] or self._opening[key] then
			return nil, makeError("AlreadyOpen", "Cannot restore a locally open key", key)
		end
		if type(self._adapter.GetVersionAsync) ~= "function" then
			return nil, makeError("UnsupportedOperation", "This adapter does not support version reads", key)
		end

		self._opening[key] = true
		local readOk, historicalRaw = self:_call("RestoreVersionReadAsync", key, "Read", function()
			return self._adapter:GetVersionAsync(key, version)
		end)
		if not readOk then
			self._opening[key] = nil
			return nil, historicalRaw
		end
		if historicalRaw == nil then
			self._opening[key] = nil
			return nil, makeError("VersionNotFound", `Version "{version}" was not found`, key)
		end

		local historicalRecord, historicalError = self:_decode(historicalRaw, os.time())
		if not historicalRecord then
			self._opening[key] = nil
			historicalError.Key = key
			self:_emitError(historicalError)
			return nil, historicalError
		end

		local lockedBy = nil
		local decodedError = nil
		local restoredRecord = nil
		local restoreToken = VirtualStore.id("restore")
		local ok, callResult = self:_call("RestoreVersionAsync", key, "Update", function()
			return self._adapter:UpdateAsync(key, function(rawValue: any)
				lockedBy = nil
				decodedError = nil
				restoredRecord = nil

				local now = os.time()
				local current, currentError, currentDecodedDataChanged = self:_decode(rawValue, now)
				if not current then
					decodedError = currentError
					return nil
				end
				if current.Meta.WriteReceipts[restoreToken] or current.Meta.LastWriteToken == restoreToken then
					restoredRecord = Util.deepCopy(current)
					return nil
				end
				if leaseIsActive(current.Meta.Lease, now) then
					lockedBy = Util.deepCopy(current.Meta.Lease)
					return nil
				end

				local restored = Util.deepCopy(historicalRecord)
				restored.__virtualStore = FORMAT_VERSION
				restored.SchemaVersion = self.SchemaVersion
				restored.Meta.CreatedAt = current.Meta.CreatedAt
				restored.Meta.UpdatedAt = now
				restored.Meta.Revision = current.Meta.Revision + 1
				local restoredDataChanged = currentDecodedDataChanged or not Util.deepEqual(current.Data, restored.Data)
				restored.Meta.DataRevision = current.Meta.DataRevision + (if restoredDataChanged then 1 else 0)
				restored.Meta.Operations = self:_mergeOperationLedgers(current.Meta.Operations, restored.Meta.Operations)
				restored.Meta.WriteReceipts = Util.deepCopy(current.Meta.WriteReceipts)
				restored.Meta.WriteReceiptOrder = Util.deepCopy(current.Meta.WriteReceiptOrder)
				restored.Meta.LastWriteToken = current.Meta.LastWriteToken
				restored.Meta.LastWriteChangedData = current.Meta.LastWriteChangedData
				self:_rememberWrite(restored.Meta, restoreToken, restoredDataChanged, now)
				restored.Meta.Lease = nil
				local validationError = self:_validateForSave(restored.Data, restored.Meta)
				if validationError then
					decodedError = validationError
					return nil
				end
				restoredRecord = Util.deepCopy(restored)
				return restored, restored.Meta.UserIds
			end)
		end)
		self._opening[key] = nil

		if not ok then
			return nil, callResult
		end
		if decodedError then
			decodedError.Key = key
			self:_emitError(decodedError)
			return nil, decodedError
		end
		if lockedBy then
			return nil, makeError("Locked", "Cannot restore a record with an active session lease", key, lockedBy)
		end
		if not restoredRecord then
			return nil, makeError("RestoreRejected", "Version restore was rejected", key)
		end

		self._metrics.Restores += 1
		local snapshot = copySnapshot(restoredRecord)
		snapshot.RestoredFromVersion = version
		return snapshot, nil
	end

	function Store:GetDeleteConfirmation(key: string): string
		validateKey(key)
		return `DELETE:{self._identity}:{key}`
	end

	function Store:DeleteAsync(key: string, confirmation: string): (boolean, any?)
		validateKey(key)
		if confirmation ~= self:GetDeleteConfirmation(key) then
			return false, makeError("ConfirmationRequired", "Delete confirmation did not match", key)
		end
		if self._closed then
			return false, makeError("StoreClosed", "Store is closed", key)
		end
		if self._sessions[key] or self._opening[key] then
			return false, makeError("AlreadyOpen", "Cannot delete a locally open key", key)
		end

		self._opening[key] = true
		local deleteToken = HttpService:GenerateGUID(false)
		local lockedBy = nil
		local decodedError = nil
		local claimed = false
		local claimOk, claimResult = self:_call("DeleteClaimAsync", key, "Update", function()
			return self._adapter:UpdateAsync(key, function(rawValue: any)
				lockedBy = nil
				decodedError = nil
				claimed = false

				local now = os.time()
				local record, recordError, decodedDataChanged = self:_decode(rawValue, now)
				if not record then
					decodedError = recordError
					return nil
				end
				if leaseIsActive(record.Meta.Lease, now) and record.Meta.Lease.Token ~= deleteToken then
					lockedBy = Util.deepCopy(record.Meta.Lease)
					return nil
				end
				if leaseIsActive(record.Meta.Lease, now) and record.Meta.Lease.Token == deleteToken then
					claimed = true
					return nil
				end

				record.Meta.Lease = {
					Token = deleteToken,
					PlaceId = game.PlaceId,
					JobId = game.JobId,
					AcquiredAt = now,
					RenewedAt = now,
					ExpiresAt = now + self.Settings.LeaseTimeout,
				}
				record.Meta.UpdatedAt = now
				record.Meta.Revision += 1
				if decodedDataChanged then
					record.Meta.DataRevision += 1
				end
				claimed = true
				return record, record.Meta.UserIds
			end)
		end)

		if not claimOk then
			self._opening[key] = nil
			return false, claimResult
		end
		if decodedError then
			self._opening[key] = nil
			decodedError.Key = key
			self:_emitError(decodedError)
			return false, decodedError
		end
		if lockedBy then
			self._opening[key] = nil
			return false, makeError("Locked", "Cannot delete a record with an active session lease", key, lockedBy)
		end
		if not claimed then
			self._opening[key] = nil
			return false, makeError("DeleteRejected", "Delete lease claim was rejected", key)
		end

		local removeOk, removeResult = self:_call("DeleteAsync", key, "Remove", function()
			return self._adapter:RemoveAsync(key)
		end)
		self._opening[key] = nil
		if not removeOk then
			return false, removeResult
		end

		self._metrics.Deletes += 1
		return true, nil
	end

	function Store:ClearPendingOperationAsync(key: string, operationId: string, adminContext: any, reason: string?): (any?, any?)
		validateKey(key)
		validateOperationId(operationId)
		local authorized, authorizationError = self:_authorizeAdmin("ClearPendingOperation", key, adminContext)
		if not authorized then
			return nil, authorizationError
		end
		assert(reason == nil or (type(reason) == "string" and #reason > 0), "reason must be a non-empty string")
		if self._closed then
			return nil, makeError("StoreClosed", "Store is closed", key)
		end

		local adminReason = reason or "Cleared by an administrator"
		local result = nil
		local decodedError = nil
		local ok, callResult = self:_call("ClearPendingOperationAsync", key, "Update", function()
			return self._adapter:UpdateAsync(key, function(rawValue: any)
				result = nil
				decodedError = nil

				local now = os.time()
				local record, recordError, decodedDataChanged = self:_decode(rawValue, now)
				if not record then
					decodedError = recordError
					return nil
				end
				local operations = record.Meta.Operations
				local existing = operations.Receipts[operationId]
					or operations.DeadLetters[operationId]
					or operations.Dedupe[operationId]
				if existing then
					result = {
						Id = operationId,
						Status = existing.Status,
						Changed = false,
						Existing = Util.deepCopy(existing),
					}
					return nil
				end

				local operation = operations.Pending[operationId]
				if not operation then
					result = {
						Id = operationId,
						Status = "Unknown",
						Changed = false,
					}
					return nil
				end
				operation.LastError = adminReason
				local receipt = self:_recordOperationOutcome(
					operations,
					operationId,
					operation,
					"Cancelled",
					now,
					nil,
					makeError("OperationClearedByAdmin", adminReason, key)
				)
				self:_compactOperationLedgers(operations)
				local validationError = self:_validateForSave(record.Data, record.Meta)
				if validationError then
					decodedError = validationError
					return nil
				end

				record.Meta.UpdatedAt = now
				record.Meta.Revision += 1
				if decodedDataChanged then
					record.Meta.DataRevision += 1
				end
				result = {
					Id = operationId,
					Status = "Cancelled",
					Changed = true,
					Receipt = Util.deepCopy(receipt),
				}
				return record, record.Meta.UserIds
			end)
		end)
		if not ok then
			return nil, callResult
		end
		if decodedError then
			decodedError.Key = key
			self:_emitError(decodedError)
			return nil, decodedError
		end
		if not result then
			return nil, makeError("AdminRepairRejected", "Pending operation clear was rejected", key)
		end
		if result.Changed then
			self._metrics.AdminRepairs += 1
		end
		return result, nil
	end

	function Store:ForceFailOperationAsync(key: string, operationId: string, adminContext: any, reason: string?): (any?, any?)
		validateKey(key)
		validateOperationId(operationId)
		local authorized, authorizationError = self:_authorizeAdmin("ForceFailOperation", key, adminContext)
		if not authorized then
			return nil, authorizationError
		end
		assert(reason == nil or (type(reason) == "string" and #reason > 0), "reason must be a non-empty string")
		if self._closed then
			return nil, makeError("StoreClosed", "Store is closed", key)
		end

		local adminReason = reason or "Force-failed by an administrator"
		local result = nil
		local decodedError = nil
		local ok, callResult = self:_call("ForceFailOperationAsync", key, "Update", function()
			return self._adapter:UpdateAsync(key, function(rawValue: any)
				result = nil
				decodedError = nil

				local now = os.time()
				local record, recordError, decodedDataChanged = self:_decode(rawValue, now)
				if not record then
					decodedError = recordError
					return nil
				end
				local operations = record.Meta.Operations
				local existing = operations.Receipts[operationId]
					or operations.DeadLetters[operationId]
					or operations.Dedupe[operationId]
				if existing then
					result = {
						Id = operationId,
						Status = existing.Status,
						Changed = false,
						Existing = Util.deepCopy(existing),
					}
					return nil
				end

				local operation = operations.Pending[operationId]
				if not operation then
					result = {
						Id = operationId,
						Status = "Unknown",
						Changed = false,
					}
					return nil
				end
				operation.LastError = adminReason
				local receipt = self:_recordOperationOutcome(
					operations,
					operationId,
					operation,
					"Failed",
					now,
					nil,
					makeError("OperationForceFailed", adminReason, key)
				)
				self:_compactOperationLedgers(operations)
				local validationError = self:_validateForSave(record.Data, record.Meta)
				if validationError then
					decodedError = validationError
					return nil
				end

				record.Meta.UpdatedAt = now
				record.Meta.Revision += 1
				if decodedDataChanged then
					record.Meta.DataRevision += 1
				end
				result = {
					Id = operationId,
					Status = "Failed",
					Changed = true,
					Receipt = Util.deepCopy(receipt),
				}
				return record, record.Meta.UserIds
			end)
		end)
		if not ok then
			return nil, callResult
		end
		if decodedError then
			decodedError.Key = key
			self:_emitError(decodedError)
			return nil, decodedError
		end
		if not result then
			return nil, makeError("AdminRepairRejected", "Pending operation force-fail was rejected", key)
		end
		if result.Changed then
			self._metrics.AdminRepairs += 1
			self._metrics.OperationFailures += 1
			self._metrics.DeadLettersCreated += 1
			self.OperationFailed:Fire(result.Receipt)
		end
		return result, nil
	end

	function Store:RequeueDeadLetterAsync(
		key: string,
		failedOperationId: string,
		newOperationId: string,
		adminContext: any
	): (any?, any?)
		validateKey(key)
		validateOperationId(failedOperationId)
		validateOperationId(newOperationId)
		assert(failedOperationId ~= newOperationId, "newOperationId must differ from failedOperationId")
		local authorized, authorizationError = self:_authorizeAdmin("RequeueDeadLetter", key, adminContext)
		if not authorized then
			return nil, authorizationError
		end
		if self._closed then
			return nil, makeError("StoreClosed", "Store is closed", key)
		end

		local status = nil
		local result = nil
		local repairError = nil
		local decodedError = nil
		local ok, callResult = self:_call("RequeueDeadLetterAsync", key, "Update", function()
			return self._adapter:UpdateAsync(key, function(rawValue: any)
				status = nil
				result = nil
				repairError = nil
				decodedError = nil

				local now = os.time()
				local record, recordError, decodedDataChanged = self:_decode(rawValue, now)
				if not record then
					decodedError = recordError
					return nil
				end
				local operations = record.Meta.Operations
				local existingPending = operations.Pending[newOperationId]
				if existingPending and existingPending.ReplayedFrom == failedOperationId then
					status = "Pending"
					result = Util.deepCopy(existingPending)
					return nil
				end
				local existingTerminal = operations.Receipts[newOperationId]
					or operations.Dedupe[newOperationId]
					or operations.DeadLetters[newOperationId]
				if existingTerminal and existingTerminal.ReplayedFrom == failedOperationId then
					status = existingTerminal.Status
					result = Util.deepCopy(existingTerminal)
					return nil
				end
				if existingPending
					or existingTerminal
				then
					repairError = makeError(
						"ReplayTargetExists",
						`New operation id "{newOperationId}" is already in use`,
						key
					)
					return nil
				end

				local deadLetter = operations.DeadLetters[failedOperationId]
				if not deadLetter then
					repairError = makeError("DeadLetterNotFound", `Dead letter "{failedOperationId}" was not found`, key)
					return nil
				end
				if deadLetter.PayloadOmitted or type(deadLetter.Payload) ~= "table" then
					repairError = makeError(
						"DeadLetterPayloadUnavailable",
						`Dead letter "{failedOperationId}" does not retain a replayable payload`,
						key
					)
					return nil
				end

				local operation = {
					Id = newOperationId,
					Type = deadLetter.Type,
					Payload = Util.deepCopy(deadLetter.Payload),
					CreatedAt = now,
					Attempts = 0,
					LastAttemptAt = nil,
					LastError = nil,
					ReplayedFrom = failedOperationId,
				}
				operations.Pending[newOperationId] = operation
				local validationError = self:_validateForSave(record.Data, record.Meta)
				if validationError then
					decodedError = validationError
					return nil
				end

				record.Meta.UpdatedAt = now
				record.Meta.Revision += 1
				if decodedDataChanged then
					record.Meta.DataRevision += 1
				end
				status = "Queued"
				result = Util.deepCopy(operation)
				return record, record.Meta.UserIds
			end)
		end)
		if not ok then
			return nil, callResult
		end
		if decodedError then
			decodedError.Key = key
			self:_emitError(decodedError)
			return nil, decodedError
		end
		if repairError then
			return nil, repairError
		end
		if not status then
			return nil, makeError("AdminRepairRejected", "Dead-letter requeue was rejected", key)
		end

		if status == "Queued" then
			self._metrics.AdminRepairs += 1
			self._metrics.OperationsQueued += 1
			self.OperationQueued:Fire(key, result)
			local localSession = self._sessions[key]
			if localSession and localSession:IsActive() then
				task.spawn(function()
					localSession:ProcessOperationsAsync()
				end)
			else
				self:_notifyOperation(key)
			end
		end
		return {
			Id = newOperationId,
			Type = result.Type,
			Status = status,
			Operation = result,
			ReplayedFrom = failedOperationId,
		}, nil
	end

	function Store:ForceReleaseLeaseAsync(key: string, expectedToken: string, adminContext: any): (any?, any?)
		validateKey(key)
		assert(type(expectedToken) == "string" and #expectedToken > 0, "expectedToken must be a non-empty string")
		local authorized, authorizationError = self:_authorizeAdmin("ForceReleaseLease", key, adminContext)
		if not authorized then
			return nil, authorizationError
		end
		if self._closed then
			return nil, makeError("StoreClosed", "Store is closed", key)
		end

		local result = nil
		local decodedError = nil
		local mismatchedLease = nil
		local ok, callResult = self:_call("ForceReleaseLeaseAsync", key, "Update", function()
			return self._adapter:UpdateAsync(key, function(rawValue: any)
				result = nil
				decodedError = nil
				mismatchedLease = nil

				local now = os.time()
				local record, recordError, decodedDataChanged = self:_decode(rawValue, now)
				if not record then
					decodedError = recordError
					return nil
				end
				local lease = record.Meta.Lease
				if lease == nil then
					result = {
						Released = false,
						Status = "NoLease",
					}
					return nil
				end
				if lease.Token ~= expectedToken then
					mismatchedLease = Util.deepCopy(lease)
					return nil
				end

				record.Meta.Lease = nil
				record.Meta.UpdatedAt = now
				record.Meta.Revision += 1
				if decodedDataChanged then
					record.Meta.DataRevision += 1
				end
				local validationError = self:_validateForSave(record.Data, record.Meta)
				if validationError then
					decodedError = validationError
					return nil
				end
				result = {
					Released = true,
					Status = "Released",
					Lease = Util.deepCopy(lease),
				}
				return record, record.Meta.UserIds
			end)
		end)
		if not ok then
			return nil, callResult
		end
		if decodedError then
			decodedError.Key = key
			self:_emitError(decodedError)
			return nil, decodedError
		end
		if mismatchedLease then
			return nil, makeError("LeaseTokenMismatch", "Stored lease token no longer matches the inspected token", key, mismatchedLease)
		end
		if not result then
			return nil, makeError("AdminRepairRejected", "Force lease release was rejected", key)
		end
		if result.Released then
			self._metrics.AdminRepairs += 1
			self._metrics.ForcedLeaseReleases += 1
		end
		local localSession = self._sessions[key]
		if localSession and localSession._token == expectedToken and (result.Released or result.Status == "NoLease") then
			self:_finishSession(localSession, "AdminForceRelease")
		end
		return result, nil
	end

	function Store:CompactLedgersAsync(key: string, adminContext: any): (any?, any?)
		validateKey(key)
		local authorized, authorizationError = self:_authorizeAdmin("CompactLedgers", key, adminContext)
		if not authorized then
			return nil, authorizationError
		end
		if self._closed then
			return nil, makeError("StoreClosed", "Store is closed", key)
		end

		local result = nil
		local decodedError = nil
		local lockedBy = nil
		local ok, callResult = self:_call("CompactLedgersAsync", key, "Update", function()
			return self._adapter:UpdateAsync(key, function(rawValue: any)
				result = nil
				decodedError = nil
				lockedBy = nil

				local now = os.time()
				local beforeDecode = if type(rawValue) == "table" then ledgerState(rawValue.Meta) else nil
				local record, recordError, decodedDataChanged = self:_decode(rawValue, now)
				if not record then
					decodedError = recordError
					return nil
				end
				if rawValue == nil then
					result = {
						Changed = false,
						Before = ledgerCounts(record.Meta),
						After = ledgerCounts(record.Meta),
					}
					return nil
				end
				if leaseIsActive(record.Meta.Lease, now) then
					lockedBy = Util.deepCopy(record.Meta.Lease)
					return nil
				end
				local before = ledgerCounts(record.Meta)
				local changed = self:_compactLedgers(record.Meta)
				local after = ledgerCounts(record.Meta)
				result = {
					Changed = changed or decodedDataChanged == true or not Util.deepEqual(beforeDecode, ledgerState(record.Meta)),
					Before = before,
					After = after,
				}
				if not result.Changed then
					return nil
				end

				local validationError = self:_validateForSave(record.Data, record.Meta)
				if validationError then
					decodedError = validationError
					return nil
				end
				record.Meta.UpdatedAt = now
				record.Meta.Revision += 1
				if decodedDataChanged then
					record.Meta.DataRevision += 1
				end
				return record, record.Meta.UserIds
			end)
		end)
		if not ok then
			return nil, callResult
		end
		if decodedError then
			decodedError.Key = key
			self:_emitError(decodedError)
			return nil, decodedError
		end
		if lockedBy then
			return nil, makeError("Locked", "Cannot compact ledgers while a session lease is active", key, lockedBy)
		end
		if not result then
			return nil, makeError("AdminRepairRejected", "Ledger compaction was rejected", key)
		end
		if result.Changed then
			self._metrics.AdminRepairs += 1
		end
		return result, nil
	end

	function Store:QueueOperationAsync(key: string, operationId: string, operationType: string, payload: {[any]: any}): (any?, any?)
		validateKey(key)
		validateOperationId(operationId)
		validateOperationType(operationType)
		assert(type(payload) == "table", "Operation payload must be a table")
		local validPayload, payloadMessage = Util.validateData(payload)
		if not validPayload then
			return nil, makeError("InvalidOperationPayload", payloadMessage or "Operation payload is invalid", key)
		end
		if self._closed then
			return nil, makeError("StoreClosed", "Store is closed", key)
		end

		local status = nil
		local result = nil
		local decodedError = nil
		local ok, callResult = self:_call("QueueOperationAsync", key, "Update", function()
			return self._adapter:UpdateAsync(key, function(rawValue: any)
				status = nil
				result = nil
				decodedError = nil

				local now = os.time()
				local record, recordError, decodedDataChanged = self:_decode(rawValue, now)
				if not record then
					decodedError = recordError
					return nil
				end

				local operations = record.Meta.Operations
				local receipt = operations.Receipts[operationId]
				if receipt then
					status = receipt.Status
					result = Util.deepCopy(receipt)
					return nil
				end
				local dedupe = operations.Dedupe[operationId]
				if dedupe then
					status = dedupe.Status
					result = Util.deepCopy(dedupe)
					return nil
				end
				local deadLetter = operations.DeadLetters[operationId]
				if deadLetter then
					status = "Failed"
					result = {
						Id = deadLetter.Id,
						Type = deadLetter.Type,
						Status = "Failed",
						CompletedAt = deadLetter.FailedAt,
						DeadLetterAvailable = true,
					}
					return nil
				end
				if operations.Pending[operationId] then
					status = "Pending"
					result = Util.deepCopy(operations.Pending[operationId])
					return nil
				end

				local operation = {
					Id = operationId,
					Type = operationType,
					Payload = Util.deepCopy(payload),
					CreatedAt = now,
					Attempts = 0,
					LastAttemptAt = nil,
					LastError = nil,
				}
				operations.Pending[operationId] = operation
				local validationError = self:_validateForSave(record.Data, record.Meta)
				if validationError then
					decodedError = validationError
					return nil
				end

				record.Meta.UpdatedAt = now
				record.Meta.Revision += 1
				if decodedDataChanged then
					record.Meta.DataRevision += 1
				end
				status = "Queued"
				result = Util.deepCopy(operation)
				return record, record.Meta.UserIds
			end)
		end)

		if not ok then
			return nil, callResult
		end
		if decodedError then
			decodedError.Key = key
			self:_emitError(decodedError)
			return nil, decodedError
		end
		if not status then
			return nil, makeError("OperationQueueRejected", "Operation queue write was rejected", key)
		end

		if status == "Queued" then
			self._metrics.OperationsQueued += 1
			self.OperationQueued:Fire(key, result)
			local localSession = self._sessions[key]
			if localSession and localSession:IsActive() then
				task.spawn(function()
					localSession:ProcessOperationsAsync()
				end)
			else
				self:_notifyOperation(key)
			end
		elseif status == "Pending" or status == "Applied" or status == "Cancelled" or status == "Failed" then
			self._metrics.OperationDuplicates += 1
		end

		return {
			Id = operationId,
			Type = operationType,
			Status = status,
			Operation = result,
		}, nil
	end

	function Store:GetOperationAsync(key: string, operationId: string): (any?, any?)
		validateKey(key)
		validateOperationId(operationId)

		local ok, rawOrError = self:_call("GetOperationAsync", key, "Read", function()
			return self._adapter:GetAsync(key)
		end)
		if not ok then
			return nil, rawOrError
		end

		local record, decodeError = self:_decode(rawOrError, os.time())
		if not record then
			decodeError.Key = key
			self:_emitError(decodeError)
			return nil, decodeError
		end

		local operations = record.Meta.Operations
		local receipt = operations.Receipts[operationId]
		if receipt then
			return {
				Id = operationId,
				Status = receipt.Status,
				Receipt = Util.deepCopy(receipt),
			}, nil
		end
		local dedupe = operations.Dedupe[operationId]
		if dedupe then
			return {
				Id = operationId,
				Status = dedupe.Status,
				Dedupe = Util.deepCopy(dedupe),
				ReceiptPruned = true,
				DeadLetterAvailable = operations.DeadLetters[operationId] ~= nil,
			}, nil
		end
		local deadLetter = operations.DeadLetters[operationId]
		if deadLetter then
			return {
				Id = operationId,
				Status = "Failed",
				ReceiptPruned = true,
				DeadLetterAvailable = true,
			}, nil
		end
		local pending = operations.Pending[operationId]
		if pending then
			return {
				Id = operationId,
				Status = "Pending",
				Operation = Util.deepCopy(pending),
			}, nil
		end
		return {
			Id = operationId,
			Status = "Unknown",
		}, nil
	end

	function Store:AwaitOperationAsync(key: string, operationId: string, timeout: number?, pollInterval: number?): (any?, any?)
		validateKey(key)
		validateOperationId(operationId)
		local waitTimeout = timeout or 15
		local poll = pollInterval or 0.5
		assert(type(waitTimeout) == "number" and waitTimeout >= 0, "Operation wait timeout must be non-negative")
		assert(type(poll) == "number" and poll > 0, "Operation poll interval must be positive")

		local deadline = os.clock() + waitTimeout
		while true do
			local localSession = self._sessions[key]
			if localSession and localSession:IsActive() then
				localSession:ProcessOperationsAsync()
			end

			local operation, virtualError = self:GetOperationAsync(key, operationId)
			if not operation then
				return nil, virtualError
			end
			if operation.Status == "Applied" or operation.Status == "Cancelled" or operation.Status == "Failed" then
				return operation, nil
			end
			if os.clock() >= deadline then
				return nil, makeError("OperationTimeout", `Operation "{operationId}" is still {operation.Status}`, key)
			end
			task.wait(math.min(poll, math.max(0, deadline - os.clock())))
		end
	end

	function Store:UpdateAsync(key: string, transform: ({[any]: any}, {[string]: any}) -> any): (any?, any?)
		validateKey(key)
		assert(type(transform) == "function", "UpdateAsync transform must be a function")
		if self._closed then
			return nil, makeError("StoreClosed", "Store is closed", key)
		end
		if self._sessions[key] or self._opening[key] then
			return nil, makeError("AlreadyOpen", "Cannot atomically update a locally open key", key)
		end

		local lockedBy: any? = nil
		local transformError: any? = nil
		local decodedError: any? = nil
		local updatedRecord: any? = nil
		local cancelled = false
		local updateToken = VirtualStore.id("update")

		local ok, callResult = self:_call("UpdateAsync", key, "Update", function()
			return self._adapter:UpdateAsync(key, function(rawValue: any)
				lockedBy = nil
				transformError = nil
				decodedError = nil
				updatedRecord = nil
				cancelled = false

				local now = os.time()
				local record, decodeError, decodedDataChanged = self:_decode(rawValue, now)
				if not record then
					decodedError = decodeError
					return nil
				end

				if record.Meta.WriteReceipts[updateToken] or record.Meta.LastWriteToken == updateToken then
					updatedRecord = Util.deepCopy(record)
					return nil
				end

				if leaseIsActive(record.Meta.Lease, now) then
					lockedBy = Util.deepCopy(record.Meta.Lease)
					return nil
				end

				local storedData = Util.deepCopy(record.Data)
				local workingData = Util.deepCopy(record.Data)
				local transformOk, result = pcall(transform, workingData, copyPublicMetadata(record.Meta))
				if not transformOk then
					transformError = makeError("TransformFailed", "UpdateAsync transform failed", key, tostring(result))
					return nil
				end
				if result == VirtualStore.Cancel then
					cancelled = true
					return nil
				end
				if result ~= nil then
					workingData = result
				end

				local validationError = self:_validateForSave(workingData, record.Meta)
				if validationError then
					transformError = validationError
					return nil
				end

				record.Data = Util.deepCopy(workingData)
				record.SchemaVersion = self.SchemaVersion
				record.Meta.UpdatedAt = now
				record.Meta.Revision += 1
				local dataChanged = decodedDataChanged or not Util.deepEqual(storedData, record.Data)
				if dataChanged then
					record.Meta.DataRevision += 1
				end
				self:_rememberWrite(record.Meta, updateToken, dataChanged, now)
				record.Meta.Lease = nil
				updatedRecord = Util.deepCopy(record)
				return record, record.Meta.UserIds
			end)
		end)

		if not ok then
			return nil, callResult
		end
		if decodedError then
			decodedError.Key = key
			self:_emitError(decodedError)
			return nil, decodedError
		end
		if transformError then
			transformError.Key = key
			self:_emitError(transformError)
			return nil, transformError
		end
		if lockedBy then
			return nil, makeError("Locked", "Cannot update a record with an active session lease", key, lockedBy)
		end
		if cancelled then
			return nil, makeError("Cancelled", "UpdateAsync was cancelled by its transform", key)
		end
		if not updatedRecord then
			return nil, makeError("UpdateRejected", "UpdateAsync transform was rejected", key)
		end

		return copySnapshot(updatedRecord), nil
	end

	function Store:GetSession(key: string): any?
		return self._sessions[key]
	end

	function Store:IsOpen(key: string): boolean
		local session = self._sessions[key]
		return session ~= nil and session:IsActive()
	end

	function Store:_subscribeToHandoffs()
		local topic = `VirtualStore:{game.GameId}`
		local ok, subscriptionOrError = pcall(function()
			return MessagingService:SubscribeAsync(topic, function(message)
				local packet = message.Data
				if type(packet) ~= "table"
					or packet.Store ~= self._identity
					or packet.FromJobId == game.JobId
				then
					return
				end

				local session = self._sessions[packet.Key]
				if not session or not session:IsActive() then
					return
				end

				if packet.Kind == "Operation" then
					task.spawn(function()
						session:ProcessOperationsAsync()
					end)
					return
				end
				if session._token ~= packet.LeaseToken then
					return
				end

				session.HandoffRequested:Fire(packet)
				if self.Settings.AutoReleaseOnHandoff then
					task.spawn(function()
						session:ReleaseAsync("Handoff")
					end)
				end
			end)
		end)

		if ok then
			self._subscription = subscriptionOrError
		else
			self:_emitError(makeError("MessagingUnavailable", "Could not subscribe to handoff messages", nil, tostring(subscriptionOrError)))
		end
	end

	function Store:_notifyOperation(key: string)
		if not self.Settings.EnableMessaging then
			return
		end

		local ok, publishError = pcall(function()
			MessagingService:PublishAsync(`VirtualStore:{game.GameId}`, {
				Kind = "Operation",
				Store = self._identity,
				Key = key,
				FromJobId = game.JobId,
			})
		end)
		if not ok then
			self:_emitError(makeError("MessagingUnavailable", "Could not publish operation notification", key, tostring(publishError)))
		end
	end

	function Store:_requestHandoff(key: string, lease: {[string]: any})
		if not self.Settings.EnableMessaging then
			return
		end

		local now = os.clock()
		local lastSent = self._handoffSentAt[key] or 0
		if now - lastSent < self.Settings.HandoffMessageCooldown then
			return
		end
		self._handoffSentAt[key] = now

		local ok, publishError = pcall(function()
			MessagingService:PublishAsync(`VirtualStore:{game.GameId}`, {
				Kind = "Handoff",
				Store = self._identity,
				Key = key,
				LeaseToken = lease.Token,
				FromJobId = game.JobId,
			})
		end)
		if not ok then
			self:_emitError(makeError("MessagingUnavailable", "Could not publish handoff request", key, tostring(publishError)))
		end
	end

	function Store:CloseAsync(): boolean
		if self._closed then
			if self._closeResult == nil then
				self._closeFinished:Wait()
			end
			return self._closeResult
		end
		self._closed = true

		local sessions = {}
		for _, session in self._sessions do
			table.insert(sessions, session)
		end

		local remaining = #sessions
		local allReleased = true
		local deadline = os.clock() + self.Settings.CloseTimeout
		if remaining > 0 then
			local finished = Signal.new()
			local nextIndex = 0
			local workerCount = math.min(self.Settings.CloseConcurrency, #sessions)
			for _ = 1, workerCount do
				task.spawn(function()
					self._closeRunning += 1
					self._metrics.PeakConcurrentCloseSaves = math.max(
						self._metrics.PeakConcurrentCloseSaves,
						self._closeRunning
					)

					while true do
						nextIndex += 1
						local session = sessions[nextIndex]
						if not session then
							break
						end

						while os.clock() < deadline do
							local state = session:GetState()
							if state == "Released" or state == "LeaseLost" then
								break
							end
							if state == "Active" then
								session:ReleaseAsync("StoreClosed")
							else
								task.wait(math.min(self.Settings.CloseRetryInterval, math.max(0, deadline - os.clock())))
							end
						end
						local finalState = session:GetState()
						if finalState ~= "Released" and finalState ~= "LeaseLost" then
							allReleased = false
							self._metrics.CloseTimeouts += 1
							self:_emitError(makeError("CloseTimeout", "Session could not be released before close timeout", session.Key))
						end
						remaining -= 1
						finished:Fire()
					end
					self._closeRunning -= 1
				end)
			end
			while remaining > 0 do
				finished:Wait()
			end
			finished:Destroy()
		end

		if self._subscription then
			self._subscription:Disconnect()
			self._subscription = nil
		end
		self._closeResult = allReleased
		self._closeFinished:Fire(allReleased)
		return allReleased
	end
end

return StoreApi
