--!nonstrict

local Util = require(script.Parent.Parent.Util)

local Common = {}

function Common.path(value: any, fallback: {any}): {any}
	return Util.normalizePath(value or fallback)
end

function Common.state(data: {[any]: any}, path: {any}, template: {[any]: any}): {[any]: any}
	local current = Util.getPath(data, path)
	if current == nil then
		current = Util.deepCopy(template)
		Util.setPath(data, path, current)
	end
	assert(type(current) == "table", "Pattern path must point to a table")
	return current
end

function Common.read(session: any, path: {any}, template: {[any]: any}): {[any]: any}
	local current = session:Get(path)
	if current == nil then
		return Util.deepCopy(template)
	end
	assert(type(current) == "table", "Pattern path must point to a table")
	return current
end

function Common.error(code: string, message: string, details: any?): {[string]: any}
	return {
		Code = code,
		Message = message,
		Details = details,
	}
end

function Common.operationId(prefix: string, ...: any): string
	local parts = {prefix}
	for _, value in {...} do
		table.insert(parts, tostring(value))
	end
	return table.concat(parts, ":")
end

function Common.assertName(value: any, label: string?): string
	assert(type(value) == "string" and #value > 0, `{label or "Name"} must be a non-empty string`)
	return value
end

function Common.assertTimestamp(value: any, label: string?): number
	assert(
		type(value) == "number" and value >= 0 and value < math.huge and value == math.floor(value),
		`{label or "Timestamp"} must be a finite non-negative integer`
	)
	return value
end

function Common.assertDuration(value: any, label: string?): number
	assert(type(value) == "number" and value >= 0 and value < math.huge, `{label or "Duration"} must be a finite non-negative number`)
	return value
end

function Common.queue(store: any, target: any, operationId: string, operationType: string, payload: {[any]: any})
	if type(target) == "string" then
		return store:QueueOperationAsync(target, operationId, operationType, payload)
	end
	assert(type(target) == "table" and type(target.QueueOperationAsync) == "function", "Target must be a key or active session")
	return target:QueueOperationAsync(operationId, operationType, payload)
end

function Common.await(store: any, target: any, operationId: string, timeout: number?, pollInterval: number?)
	local key = if type(target) == "string" then target else target.Key
	assert(type(key) == "string" and #key > 0, "Target must expose a valid key")
	return store:AwaitOperationAsync(key, operationId, timeout, pollInterval)
end

return Common
