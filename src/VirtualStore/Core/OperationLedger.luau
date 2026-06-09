--!strict

local OperationLedger = {}

function OperationLedger.install(Store: any, dependencies: {
	Util: any,
	VirtualStore: any,
	makeError: any,
	})
	local Util = dependencies.Util
	local VirtualStore = dependencies.VirtualStore
	local makeError = dependencies.makeError

	local function compactOrderedMap(map: {[any]: any}, order: {any}, limit: number): boolean
		local normalizedOrder = {}
		local seen = {}
		local changed = false
		for _, id in order do
			if type(id) == "string" and map[id] ~= nil and not seen[id] then
				seen[id] = true
				table.insert(normalizedOrder, id)
			else
				changed = true
			end
		end

		local missing = {}
		for id in map do
			if type(id) ~= "string" then
				map[id] = nil
				changed = true
			elseif not seen[id] then
				table.insert(missing, id)
			end
		end
		table.sort(missing)
		for _, id in missing do
			table.insert(normalizedOrder, id)
			changed = true
		end

		while #normalizedOrder > limit do
			local expiredId = table.remove(normalizedOrder, 1)
			map[expiredId] = nil
			changed = true
		end
		if not Util.deepEqual(order, normalizedOrder) then
			table.clear(order)
			for _, id in normalizedOrder do
				table.insert(order, id)
			end
			changed = true
		end
		return changed
	end

	function Store:_compactOperationLedgers(operations: {[string]: any}): boolean
		local changed = false
		changed = compactOrderedMap(operations.Receipts, operations.ReceiptOrder, self.Settings.OperationReceiptLimit) or changed
		changed = compactOrderedMap(operations.Dedupe, operations.DedupeOrder, self.Settings.OperationDedupeLimit) or changed
		changed = compactOrderedMap(operations.DeadLetters, operations.DeadLetterOrder, self.Settings.DeadLetterLimit) or changed
		return changed
	end

	function Store:_compactLedgers(meta: {[string]: any}): boolean
		local changed = self:_compactOperationLedgers(meta.Operations) == true
		changed = compactOrderedMap(meta.WriteReceipts, meta.WriteReceiptOrder, self.Settings.WriteReceiptLimit) or changed
		return changed
	end

	function Store:_copyDeadLetterPayload(payload: any): (any?, number?, boolean)
		if self.Settings.DeadLetterPayloadMaxBytes <= 0 then
			return nil, nil, true
		end
		local encoded, bytes = Util.estimateBytes({
			Payload = payload,
		})
		if not encoded or type(bytes) ~= "number" then
			return nil, nil, true
		end
		if bytes > self.Settings.DeadLetterPayloadMaxBytes then
			return nil, bytes, true
		end
		return Util.deepCopy(payload), bytes, false
	end

	function Store:_recordOperationOutcome(
		operations: {[string]: any},
		operationId: string,
		operation: {[string]: any},
		status: string,
		now: number,
		result: any?,
		virtualError: any?
	): {[string]: any}
		operations.Pending[operationId] = nil
		local receipt = {
			Id = operationId,
			Type = operation.Type,
			Status = status,
			CreatedAt = operation.CreatedAt,
			AppliedAt = now,
			CompletedAt = now,
			Attempts = operation.Attempts or 0,
			LastAttemptAt = operation.LastAttemptAt,
			LastError = operation.LastError or (virtualError and virtualError.Message),
			Result = Util.deepCopy(result),
			Error = Util.deepCopy(virtualError),
			ReplayedFrom = operation.ReplayedFrom,
		}
		if not operations.Receipts[operationId] then
			table.insert(operations.ReceiptOrder, operationId)
		end
		operations.Receipts[operationId] = receipt

		if not operations.Dedupe[operationId] then
			table.insert(operations.DedupeOrder, operationId)
		end
		operations.Dedupe[operationId] = {
			Id = operationId,
			Type = operation.Type,
			Status = status,
			CompletedAt = now,
			ReplayedFrom = operation.ReplayedFrom,
		}

		if status == "Failed" then
			local deadLetterPayload, payloadBytes, payloadOmitted = self:_copyDeadLetterPayload(operation.Payload)
			if not operations.DeadLetters[operationId] then
				table.insert(operations.DeadLetterOrder, operationId)
			end
			operations.DeadLetters[operationId] = {
				Id = operationId,
				Type = operation.Type,
				Status = "Failed",
				Payload = deadLetterPayload,
				PayloadBytes = payloadBytes,
				PayloadOmitted = payloadOmitted,
				CreatedAt = operation.CreatedAt,
				FailedAt = now,
				Attempts = operation.Attempts or 0,
				LastAttemptAt = operation.LastAttemptAt,
				LastError = operation.LastError or (virtualError and virtualError.Message),
				Error = Util.deepCopy(virtualError),
				ReplayedFrom = operation.ReplayedFrom,
			}
		end
		return receipt
	end

	function Store:_applyPendingOperations(record: {[string]: any}, baseData: {[any]: any}, key: string)
		local operations = record.Meta.Operations
		local pendingList: {any} = {}
		for operationId, operation in operations.Pending do
			table.insert(pendingList, {
				Id = operationId,
				Operation = operation,
			})
		end
		table.sort(pendingList, function(left: any, right: any): boolean
			if left.Operation.CreatedAt == right.Operation.CreatedAt then
				return left.Id < right.Id
			end
			return left.Operation.CreatedAt < right.Operation.CreatedAt
		end)

		local data = Util.deepCopy(baseData)
		local completed: {any} = {}
		local retries: {any} = {}
		local processed = 0
		local now = os.time()
		local dataChanged = false

		local function finishOperation(operationId: string, operation: {[string]: any}, status: string, result: any?, virtualError: any?)
			local receipt: any = self:_recordOperationOutcome(operations, operationId, operation, status, now, result, virtualError)
			table.insert(completed, Util.deepCopy(receipt) :: any)
		end

		local function retryOrFail(operationId: string, operation: {[string]: any}, virtualError: any)
			operation.LastError = virtualError.Message or tostring(virtualError)
			if operation.Attempts >= self.Settings.MaxOperationAttempts then
				finishOperation(operationId, operation, "Failed", nil, virtualError)
				return
			end
			table.insert(retries, {
				Id = operationId,
				Type = operation.Type,
				Attempts = operation.Attempts,
				LastAttemptAt = operation.LastAttemptAt,
				Error = Util.deepCopy(virtualError),
			})
		end

		for _, entry in pendingList do
			if processed >= self.Settings.OperationProcessLimit then
				break
			end
			processed += 1

			local operationId = entry.Id
			local operation = entry.Operation
			if operations.Receipts[operationId] or operations.Dedupe[operationId] or operations.DeadLetters[operationId] then
				operations.Pending[operationId] = nil
				continue
			end
			if self.Settings.OperationTTL > 0 and now - operation.CreatedAt >= self.Settings.OperationTTL then
				operation.LastError = `Operation exceeded its {self.Settings.OperationTTL}-second TTL`
				finishOperation(
					operationId,
					operation,
					"Failed",
					nil,
					makeError("OperationExpired", operation.LastError, key)
				)
				continue
			end

			operation.Attempts = (operation.Attempts or 0) + 1
			operation.LastAttemptAt = now
			local handler = self.Operations[operation.Type]
			if type(handler) ~= "function" then
				local handlerError = makeError("OperationHandlerMissing", `No handler is registered for operation type "{operation.Type}"`, key)
				operation.LastError = handlerError.Message
				if self.Settings.UnknownOperationPolicy == "Cancel" then
					finishOperation(operationId, operation, "Cancelled", nil, handlerError)
				elseif self.Settings.UnknownOperationPolicy == "Fail" then
					finishOperation(operationId, operation, "Failed", nil, handlerError)
				else
					retryOrFail(operationId, operation, handlerError)
				end
				continue
			end

			local candidate = Util.deepCopy(data)
			local handlerOk, result = pcall(handler, candidate, Util.deepCopy(operation.Payload), {
				Id = operationId,
				Type = operation.Type,
				Key = key,
				CreatedAt = operation.CreatedAt,
				Attempts = operation.Attempts,
				LastAttemptAt = operation.LastAttemptAt,
				ReplayedFrom = operation.ReplayedFrom,
			})
			if not handlerOk then
				retryOrFail(
					operationId,
					operation,
					makeError("OperationHandlerFailed", `Operation handler "{operation.Type}" failed`, key, tostring(result))
				)
				continue
			end
			if result == VirtualStore.Retry then
				retryOrFail(
					operationId,
					operation,
					makeError("OperationRetryRequested", `Operation handler "{operation.Type}" requested a retry`, key)
				)
				continue
			end

			local status = "Applied"
			if result == VirtualStore.Cancel then
				status = "Cancelled"
				result = nil
			else
				if result ~= nil then
					local validResult, resultMessage = Util.validateData({
						Result = result,
					})
					if not validResult then
						retryOrFail(
							operationId,
							operation,
							makeError("OperationResultInvalid", resultMessage or "Operation result is invalid", key)
						)
						continue
					end
				end
				local validationError = self:_validateForSave(candidate, record.Meta)
				if validationError then
					retryOrFail(operationId, operation, validationError)
					continue
				end
				dataChanged = dataChanged or not Util.deepEqual(data, candidate)
				data = candidate
			end

			operation.LastError = nil
			finishOperation(operationId, operation, status, result, nil)
		end

		self:_compactOperationLedgers(operations)

		return data, completed, retries, dataChanged
	end

	function Store:_reportOperations(completed: {any}, retries: {any})
		local store: any = self
		for _, receipt in completed do
			if receipt.Status == "Failed" then
				store._metrics.OperationFailures += 1
				store._metrics.DeadLettersCreated += 1
				local receiptError: any = receipt.Error
				if receiptError and receiptError.Code == "OperationExpired" then
					store._metrics.OperationsExpired += 1
				end
				store.OperationFailed:Fire(receipt)
				store:_emitError(receiptError)
			else
				store._metrics.OperationsApplied += 1
				store.OperationApplied:Fire(receipt)
			end
		end
		for _, retry in retries do
			store._metrics.OperationRetries += 1
			store.OperationRetried:Fire(retry)
		end
	end

	function Store:_mergeOperationLedgers(current: {[string]: any}, historical: {[string]: any}): {[string]: any}
		local merged = {
			Pending = Util.deepCopy(current.Pending),
			Receipts = {},
			ReceiptOrder = {},
			Dedupe = {},
			DedupeOrder = {},
			DeadLetters = {},
			DeadLetterOrder = {},
		}

		local function addReceipts(source: {[string]: any})
			for _, operationId in source.ReceiptOrder do
				local receipt = source.Receipts[operationId]
				if receipt and not merged.Receipts[operationId] then
					merged.Receipts[operationId] = Util.deepCopy(receipt)
					table.insert(merged.ReceiptOrder, operationId)
				end
			end
		end

		local function addDedupe(source: {[string]: any})
			for _, operationId in source.DedupeOrder do
				local dedupe = source.Dedupe[operationId]
				if dedupe and not merged.Dedupe[operationId] then
					merged.Dedupe[operationId] = Util.deepCopy(dedupe)
					table.insert(merged.DedupeOrder, operationId)
				end
			end
		end

		local function addDeadLetters(source: {[string]: any})
			for _, operationId in source.DeadLetterOrder do
				local deadLetter = source.DeadLetters[operationId]
				if deadLetter and not merged.DeadLetters[operationId] then
					merged.DeadLetters[operationId] = Util.deepCopy(deadLetter)
					table.insert(merged.DeadLetterOrder, operationId)
				end
			end
		end

		addReceipts(historical)
		addReceipts(current)
		addDedupe(historical)
		addDedupe(current)
		addDeadLetters(historical)
		addDeadLetters(current)
		self:_compactOperationLedgers(merged)
		return merged
	end
end

return OperationLedger
