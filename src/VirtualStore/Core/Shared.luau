--!strict

local Util = require(script.Parent.Parent.Util)

local Shared = {}

function Shared.makeError(code: string, message: string, key: string?, cause: any?, attempts: number?)
	return {
		Code = code,
		Message = message,
		Key = key,
		Cause = cause,
		Attempts = attempts,
	}
end

function Shared.setSessionData(session: any, data: {[any]: any})
	session._data = data
	session.Data = if session._store.Settings.StrictData then Util.readOnlyProxy(data) else data
end

function Shared.emitSessionChange(session: any, reason: string, changes: {any}, source: string?): boolean
	if #changes == 0 then
		return false
	end
	session._dirty = true
	session._changeRevision += 1
	local event: any = {
		Reason = reason,
		Source = source,
		At = os.time(),
		Revision = session._changeRevision,
		Paths = Util.changePaths(changes),
	}
	if session._store.Settings.TrackChangeDetails then
		event.Changes = Util.deepCopy(changes)
	end
	if session._store.Settings.AuditLogLimit > 0 then
		local auditEntry: any = Util.deepCopy(event)
		auditEntry.Changes = Util.deepCopy(changes)
		table.insert(session._auditLog, auditEntry)
		while #session._auditLog > session._store.Settings.AuditLogLimit do
			table.remove(session._auditLog, 1)
		end
	end
	session.OnChanged:Fire(event)
	return true
end

function Shared.leaseIsActive(lease: any, now: number): boolean
	return type(lease) == "table"
		and type(lease.Token) == "string"
		and type(lease.ExpiresAt) == "number"
		and lease.ExpiresAt > now
end

function Shared.copyPublicMetadata(meta: {[string]: any}): {[string]: any}
	local pendingOperationCount = 0
	local deadLetterCount = 0
	if type(meta.Operations) == "table" and type(meta.Operations.Pending) == "table" then
		for _ in meta.Operations.Pending do
			pendingOperationCount += 1
		end
	end
	if type(meta.Operations) == "table" and type(meta.Operations.DeadLetters) == "table" then
		for _ in meta.Operations.DeadLetters do
			deadLetterCount += 1
		end
	end
	return {
		CreatedAt = meta.CreatedAt,
		UpdatedAt = meta.UpdatedAt,
		Revision = meta.Revision,
		DataRevision = meta.DataRevision,
		UserIds = Util.deepCopy(meta.UserIds),
		Tags = Util.deepCopy(meta.Tags),
		PendingOperationCount = pendingOperationCount,
		DeadLetterCount = deadLetterCount,
	}
end

function Shared.validateOperationId(operationId: any)
	assert(type(operationId) == "string" and #operationId > 0, "Operation id must be a non-empty string")
	assert(#operationId <= 120, "Operation id cannot exceed 120 characters")
end

function Shared.validateOperationType(operationType: any)
	assert(type(operationType) == "string" and #operationType > 0, "Operation type must be a non-empty string")
	assert(#operationType <= 60, "Operation type cannot exceed 60 characters")
end

function Shared.copySnapshot(record: {[string]: any}): {[string]: any}
	return {
		Data = Util.deepCopy(record.Data),
		Metadata = Shared.copyPublicMetadata(record.Meta),
	}
end

function Shared.validateKey(key: any)
	assert(type(key) == "string", "VirtualStore key must be a string")
	assert(#key > 0, "VirtualStore key cannot be empty")
	assert(#key <= 50, "VirtualStore key cannot exceed 50 characters")
end

return Shared
