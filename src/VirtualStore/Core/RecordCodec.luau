--!strict

local RecordCodec = {}

function RecordCodec.install(Store: any, dependencies: {
	FormatVersion: number,
	Util: any,
	makeError: any,
	copyPublicMetadata: any,
	})
	local formatVersion = dependencies.FormatVersion
	local Util = dependencies.Util
	local makeError = dependencies.makeError
	local copyPublicMetadata = dependencies.copyPublicMetadata

	function Store:_newRecord(now: number): {[string]: any}
		return {
			__virtualStore = formatVersion,
			SchemaVersion = self.SchemaVersion,
			Data = Util.deepCopy(self.Template),
			Meta = {
				CreatedAt = now,
				UpdatedAt = now,
				Revision = 0,
				DataRevision = 0,
				LastWriteToken = nil,
				LastWriteChangedData = false,
				WriteReceipts = {},
				WriteReceiptOrder = {},
				UserIds = {},
				Tags = {},
				Operations = {
					Pending = {},
					Receipts = {},
					ReceiptOrder = {},
					Dedupe = {},
					DedupeOrder = {},
					DeadLetters = {},
					DeadLetterOrder = {},
				},
				Lease = nil,
			},
		}
	end

	function Store:_decode(rawValue: any, now: number): ({[string]: any}?, any?, boolean?)
		local record: {[string]: any}

		if rawValue == nil then
			record = self:_newRecord(now)
		elseif type(rawValue) ~= "table" then
			return nil, makeError("CorruptData", "Stored value is not a table")
		elseif rawValue.__virtualStore == formatVersion then
			if type(rawValue.Data) ~= "table" or type(rawValue.Meta) ~= "table" then
				return nil, makeError("CorruptData", "VirtualStore envelope is malformed")
			end
			record = Util.deepCopy(rawValue)
		elseif rawValue.__virtualStore ~= nil then
			return nil, makeError("UnsupportedFormat", `Stored format {tostring(rawValue.__virtualStore)} is not supported`)
		else
			record = self:_newRecord(now)
			record.SchemaVersion = 0
			record.Data = Util.deepCopy(rawValue)
		end
		local decodedBaseData = Util.deepCopy(record.Data)

		local meta: any = record.Meta
		if meta.CreatedAt == nil then
			meta.CreatedAt = now
		elseif type(meta.CreatedAt) ~= "number" then
			return nil, makeError("CorruptData", "Stored creation time is invalid")
		end
		if meta.UpdatedAt == nil then
			meta.UpdatedAt = now
		elseif type(meta.UpdatedAt) ~= "number" then
			return nil, makeError("CorruptData", "Stored update time is invalid")
		end
		if meta.Revision == nil then
			meta.Revision = 0
		elseif type(meta.Revision) ~= "number" then
			return nil, makeError("CorruptData", "Stored revision is invalid")
		end
		if meta.DataRevision == nil then
			meta.DataRevision = meta.Revision
		elseif type(meta.DataRevision) ~= "number" then
			return nil, makeError("CorruptData", "Stored data revision is invalid")
		end
		if meta.LastWriteToken ~= nil and type(meta.LastWriteToken) ~= "string" then
			return nil, makeError("CorruptData", "Stored write token is invalid")
		end
		if meta.LastWriteChangedData == nil then
			meta.LastWriteChangedData = false
		elseif type(meta.LastWriteChangedData) ~= "boolean" then
			return nil, makeError("CorruptData", "Stored write change marker is invalid")
		end
		if meta.WriteReceipts == nil then
			meta.WriteReceipts = {}
		elseif type(meta.WriteReceipts) ~= "table" then
			return nil, makeError("CorruptData", "Stored write receipts are invalid")
		end
		if meta.WriteReceiptOrder == nil then
			meta.WriteReceiptOrder = {}
		elseif type(meta.WriteReceiptOrder) ~= "table" then
			return nil, makeError("CorruptData", "Stored write receipt order is invalid")
		end
		local writeReceipts: any = meta.WriteReceipts
		for token, receiptValue in writeReceipts do
			local receipt = receiptValue :: any
			if type(token) ~= "string"
				or type(receipt) ~= "table"
				or type(receipt.At) ~= "number"
				or type(receipt.ChangedData) ~= "boolean"
			then
				return nil, makeError("CorruptData", "Stored write receipt is malformed")
			end
		end
		if meta.UserIds == nil then
			meta.UserIds = {}
		elseif type(meta.UserIds) ~= "table" then
			return nil, makeError("CorruptData", "Stored user ids are invalid")
		end
		if meta.Tags == nil then
			meta.Tags = {}
		elseif type(meta.Tags) ~= "table" then
			return nil, makeError("CorruptData", "Stored tags are invalid")
		end
		if meta.Operations == nil then
			meta.Operations = {
				Pending = {},
				Receipts = {},
				ReceiptOrder = {},
				Dedupe = {},
				DedupeOrder = {},
				DeadLetters = {},
				DeadLetterOrder = {},
			}
		elseif type(meta.Operations) ~= "table" then
			return nil, makeError("CorruptData", "Stored operations are invalid")
		end
		local operations: any = meta.Operations
		if operations.Pending == nil then
			operations.Pending = {}
		elseif type(operations.Pending) ~= "table" then
			return nil, makeError("CorruptData", "Stored pending operations are invalid")
		end
		if operations.Receipts == nil then
			operations.Receipts = {}
		elseif type(operations.Receipts) ~= "table" then
			return nil, makeError("CorruptData", "Stored operation receipts are invalid")
		end
		if operations.ReceiptOrder == nil then
			operations.ReceiptOrder = {}
		elseif type(operations.ReceiptOrder) ~= "table" then
			return nil, makeError("CorruptData", "Stored operation receipt order is invalid")
		end
		if operations.Dedupe == nil then
			operations.Dedupe = {}
		elseif type(operations.Dedupe) ~= "table" then
			return nil, makeError("CorruptData", "Stored operation dedupe records are invalid")
		end
		if operations.DedupeOrder == nil then
			operations.DedupeOrder = {}
		elseif type(operations.DedupeOrder) ~= "table" then
			return nil, makeError("CorruptData", "Stored operation dedupe order is invalid")
		end
		if operations.DeadLetters == nil then
			operations.DeadLetters = {}
		elseif type(operations.DeadLetters) ~= "table" then
			return nil, makeError("CorruptData", "Stored operation dead letters are invalid")
		end
		if operations.DeadLetterOrder == nil then
			operations.DeadLetterOrder = {}
		elseif type(operations.DeadLetterOrder) ~= "table" then
			return nil, makeError("CorruptData", "Stored operation dead-letter order is invalid")
		end
		for _, deadLetter in operations.DeadLetters do
			if type(deadLetter) == "table" then
				if deadLetter.Payload ~= nil then
					local payloadEncoded, payloadBytes = Util.estimateBytes({
						Payload = deadLetter.Payload,
					})
					if payloadEncoded then
						deadLetter.PayloadBytes = payloadBytes
						if self.Settings.DeadLetterPayloadMaxBytes <= 0
							or payloadBytes > self.Settings.DeadLetterPayloadMaxBytes
						then
							deadLetter.Payload = nil
							deadLetter.PayloadOmitted = true
						else
							deadLetter.PayloadOmitted = false
						end
					else
						deadLetter.Payload = nil
						deadLetter.PayloadBytes = nil
						deadLetter.PayloadOmitted = true
					end
				elseif deadLetter.PayloadOmitted == nil then
					deadLetter.PayloadOmitted = true
				end
			end
		end
		for _, operationId in operations.ReceiptOrder do
			local receipt = operations.Receipts[operationId]
			if receipt and not operations.Dedupe[operationId] then
				operations.Dedupe[operationId] = {
					Id = operationId,
					Type = receipt.Type,
					Status = receipt.Status,
					CompletedAt = receipt.CompletedAt or receipt.AppliedAt or now,
					ReplayedFrom = receipt.ReplayedFrom,
				}
				table.insert(operations.DedupeOrder, operationId)
			end
			if receipt and receipt.Status == "Failed" and not operations.DeadLetters[operationId] then
				operations.DeadLetters[operationId] = {
					Id = operationId,
					Type = receipt.Type,
					Status = "Failed",
					CreatedAt = receipt.CreatedAt,
					FailedAt = receipt.CompletedAt or receipt.AppliedAt or now,
					Attempts = receipt.Attempts or 0,
					LastAttemptAt = receipt.LastAttemptAt,
					LastError = receipt.LastError,
					Error = Util.deepCopy(receipt.Error),
					PayloadOmitted = true,
					ReplayedFrom = receipt.ReplayedFrom,
				}
				table.insert(operations.DeadLetterOrder, operationId)
			end
		end
		while #operations.DedupeOrder > self.Settings.OperationDedupeLimit do
			local expiredId = table.remove(operations.DedupeOrder, 1)
			operations.Dedupe[expiredId] = nil
		end
		while #operations.DeadLetterOrder > self.Settings.DeadLetterLimit do
			local expiredId = table.remove(operations.DeadLetterOrder, 1)
			operations.DeadLetters[expiredId] = nil
		end
		for _, operation in operations.Pending do
			if type(operation) == "table" then
				if operation.Attempts == nil then
					operation.Attempts = 0
				end
			end
		end
		if meta.Revision < 0 or meta.Revision ~= math.floor(meta.Revision) then
			return nil, makeError("CorruptData", "Stored revision is invalid")
		end
		if meta.DataRevision < 0 or meta.DataRevision ~= math.floor(meta.DataRevision) then
			return nil, makeError("CorruptData", "Stored data revision is invalid")
		end
		if meta.Lease ~= nil then
			local lease: any = meta.Lease
			if type(lease) ~= "table"
				or type(lease.Token) ~= "string"
				or type(lease.ExpiresAt) ~= "number"
				or type(lease.RenewedAt) ~= "number"
			then
				return nil, makeError("CorruptData", "Stored lease is malformed")
			end
		end

		local version = record.SchemaVersion
		if type(version) ~= "number" or version < 0 or version ~= math.floor(version) then
			return nil, makeError("CorruptData", "SchemaVersion is invalid")
		end
		if version > self.SchemaVersion then
			return nil, makeError("NewerSchema", `Stored schema {version} is newer than supported schema {self.SchemaVersion}`)
		end

		while version < self.SchemaVersion do
			local nextVersion = version + 1
			local migration = self.Migrations[nextVersion]
			if type(migration) ~= "function" then
				return nil, makeError("MissingMigration", `Missing migration for schema {nextVersion}`)
			end

			local ok, migratedData = pcall(migration, record.Data, copyPublicMetadata(meta))
			if not ok then
				return nil, makeError("MigrationFailed", `Migration {nextVersion} failed`, nil, tostring(migratedData))
			end
			if migratedData ~= nil then
				if type(migratedData) ~= "table" then
					return nil, makeError("MigrationFailed", `Migration {nextVersion} must return a table or nil`)
				end
				record.Data = migratedData
			end
			version = nextVersion
			record.SchemaVersion = version
		end

		if self.Settings.ReconcileOnOpen then
			Util.reconcile(record.Data, self.Template)
		end

		if self.Settings.ValidateData then
			local valid, message = Util.validateData(record.Data)
			if not valid then
				return nil, makeError("CorruptData", message or "Data validation failed")
			end

			local validTags, tagsMessage = Util.validateData(meta.Tags)
			if not validTags then
				return nil, makeError("CorruptData", tagsMessage or "Stored tags are invalid")
			end
			local validUserIds, userIdsMessage = Util.validateData(meta.UserIds)
			if not validUserIds then
				return nil, makeError("CorruptData", userIdsMessage or "Stored user ids are invalid")
			end
			for _, userId in meta.UserIds do
				if type(userId) ~= "number" or userId <= 0 or userId ~= math.floor(userId) then
					return nil, makeError("CorruptData", "Stored metadata contains an invalid user id")
				end
			end

			local validOperations, operationsMessage = Util.validateData(meta.Operations)
			if not validOperations then
				return nil, makeError("CorruptData", operationsMessage or "Stored operations are invalid")
			end
			local validWriteReceipts, writeReceiptsMessage = Util.validateData(meta.WriteReceipts)
			if not validWriteReceipts then
				return nil, makeError("CorruptData", writeReceiptsMessage or "Stored write receipts are invalid")
			end
			local validWriteOrder, writeOrderMessage = Util.validateData(meta.WriteReceiptOrder)
			if not validWriteOrder then
				return nil, makeError("CorruptData", writeOrderMessage or "Stored write receipt order is invalid")
			end
			local seenWriteTokens = {}
			for _, token in meta.WriteReceiptOrder do
				if type(token) ~= "string" or not meta.WriteReceipts[token] or seenWriteTokens[token] then
					return nil, makeError("CorruptData", "Stored write receipt order is malformed")
				end
				seenWriteTokens[token] = true
			end
			for token in meta.WriteReceipts do
				if not seenWriteTokens[token] then
					return nil, makeError("CorruptData", "Stored write receipt is missing from its order")
				end
			end
			for operationId, operation in operations.Pending do
				if type(operationId) ~= "string"
					or type(operation) ~= "table"
					or operation.Id ~= operationId
					or type(operation.Type) ~= "string"
					or type(operation.CreatedAt) ~= "number"
					or type(operation.Attempts) ~= "number"
					or operation.Attempts < 0
					or operation.Attempts ~= math.floor(operation.Attempts)
					or (operation.LastAttemptAt ~= nil and type(operation.LastAttemptAt) ~= "number")
					or (operation.LastError ~= nil and type(operation.LastError) ~= "string")
					or (operation.ReplayedFrom ~= nil and type(operation.ReplayedFrom) ~= "string")
				then
					return nil, makeError("CorruptData", "Stored pending operation is malformed")
				end
			end
			local seenDedupeIds = {}
			for _, operationId in operations.DedupeOrder do
				local dedupe = operations.Dedupe[operationId]
				if type(operationId) ~= "string"
					or type(dedupe) ~= "table"
					or dedupe.Id ~= operationId
					or type(dedupe.Type) ~= "string"
					or type(dedupe.Status) ~= "string"
					or type(dedupe.CompletedAt) ~= "number"
					or (dedupe.ReplayedFrom ~= nil and type(dedupe.ReplayedFrom) ~= "string")
					or seenDedupeIds[operationId]
				then
					return nil, makeError("CorruptData", "Stored operation dedupe order is malformed")
				end
				seenDedupeIds[operationId] = true
			end
			for operationId in operations.Dedupe do
				if not seenDedupeIds[operationId] then
					return nil, makeError("CorruptData", "Stored operation dedupe record is missing from its order")
				end
			end
			local seenDeadLetterIds = {}
			for _, operationId in operations.DeadLetterOrder do
				local deadLetter = operations.DeadLetters[operationId]
				if type(operationId) ~= "string"
					or type(deadLetter) ~= "table"
					or deadLetter.Id ~= operationId
					or type(deadLetter.Type) ~= "string"
					or deadLetter.Status ~= "Failed"
					or type(deadLetter.FailedAt) ~= "number"
					or type(deadLetter.Attempts) ~= "number"
					or deadLetter.Attempts < 0
					or deadLetter.Attempts ~= math.floor(deadLetter.Attempts)
					or type(deadLetter.PayloadOmitted) ~= "boolean"
					or (deadLetter.PayloadBytes ~= nil and type(deadLetter.PayloadBytes) ~= "number")
					or (deadLetter.PayloadBytes ~= nil and (deadLetter.PayloadBytes < 0 or deadLetter.PayloadBytes ~= math.floor(deadLetter.PayloadBytes)))
					or (deadLetter.PayloadOmitted == false and type(deadLetter.Payload) ~= "table")
					or (deadLetter.ReplayedFrom ~= nil and type(deadLetter.ReplayedFrom) ~= "string")
					or seenDeadLetterIds[operationId]
				then
					return nil, makeError("CorruptData", "Stored operation dead-letter order is malformed")
				end
				seenDeadLetterIds[operationId] = true
			end
			for operationId in operations.DeadLetters do
				if not seenDeadLetterIds[operationId] then
					return nil, makeError("CorruptData", "Stored operation dead letter is missing from its order")
				end
			end
		end

		return record, nil, not Util.deepEqual(decodedBaseData, record.Data)
	end

	function Store:_validateForSave(data: {[any]: any}, meta: {[string]: any}?): any?
		if self.Settings.ValidateData then
			local valid, message = Util.validateData(data)
			if not valid then
				return makeError("InvalidData", message or "Data validation failed")
			end

			if meta then
				local validTags, tagsMessage = Util.validateData(meta.Tags)
				if not validTags then
					return makeError("InvalidData", tagsMessage or "Tag validation failed")
				end
				local validUserIds, userIdsMessage = Util.validateData(meta.UserIds)
				if not validUserIds then
					return makeError("InvalidData", userIdsMessage or "User id validation failed")
				end
				for _, userId in meta.UserIds do
					if type(userId) ~= "number" or userId <= 0 or userId ~= math.floor(userId) then
						return makeError("InvalidData", "Metadata contains an invalid user id")
					end
				end
			end
		end

		local encoded, bytesOrMessage = Util.estimateBytes({
			Data = data,
			Tags = if meta then meta.Tags else {},
			UserIds = if meta then meta.UserIds else {},
			Operations = if meta and meta.Operations then meta.Operations else {},
			WriteReceipts = if meta and meta.WriteReceipts then meta.WriteReceipts else {},
			WriteReceiptOrder = if meta and meta.WriteReceiptOrder then meta.WriteReceiptOrder else {},
		})
		if not encoded then
			return makeError("InvalidData", `Data could not be encoded: {bytesOrMessage}`)
		end
		if bytesOrMessage > self.Settings.MaxDataBytes then
			return makeError("DataTooLarge", `Data is {bytesOrMessage} bytes; limit is {self.Settings.MaxDataBytes}`)
		end
		return nil
	end

	function Store:_rememberWrite(meta: {[string]: any}, token: string, changedData: boolean, now: number)
		local store: any = self
		if not meta.WriteReceipts[token] then
			table.insert(meta.WriteReceiptOrder, token)
		end
		meta.WriteReceipts[token] = {
			At = now,
			ChangedData = changedData,
		}
		while #meta.WriteReceiptOrder > store.Settings.WriteReceiptLimit do
			local expiredToken = table.remove(meta.WriteReceiptOrder, 1)
			meta.WriteReceipts[expiredToken] = nil
		end
		meta.LastWriteToken = token
		meta.LastWriteChangedData = changedData
	end
end

return RecordCodec
