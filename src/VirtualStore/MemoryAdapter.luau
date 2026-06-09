--!strict

local Util = require(script.Parent.Util)

local MemoryAdapter: any = {}
MemoryAdapter.__index = MemoryAdapter

function MemoryAdapter.new(initialData: {[string]: any}?)
	local self: any = setmetatable({
		_data = Util.deepCopy(initialData or {}),
		_versions = {},
		_versionCounter = 0,
		_failuresLeft = 0,
		_failureMessage = "Injected MemoryAdapter failure",
		_failAfterWrites = 0,
		_failAfterMessage = "Injected post-write MemoryAdapter failure",
		_budgetAvailable = true,
		_updateDelay = 0,
		_stats = {
			UpdateCalls = 0,
			GetCalls = 0,
			RemoveCalls = 0,
			ActiveUpdates = 0,
			PeakActiveUpdates = 0,
		},
	}, MemoryAdapter)

	for key, value in self._data do
		self:_recordVersion(key, value, false)
	end
	return self
end

function MemoryAdapter:_maybeFail()
	local adapter: any = self
	if adapter._failuresLeft <= 0 then
		return
	end
	adapter._failuresLeft -= 1
	error(adapter._failureMessage)
end

function MemoryAdapter:FailNext(count: number, message: string?)
	self._failuresLeft = count
	self._failureMessage = message or "Injected MemoryAdapter failure"
end

function MemoryAdapter:FailAfterNextWrite(count: number, message: string?)
	self._failAfterWrites = count
	self._failAfterMessage = message or "Injected post-write MemoryAdapter failure"
end

function MemoryAdapter:WaitForBudgetAsync(_requestKind: string, _timeout: number, _pollInterval: number): boolean
	return self._budgetAvailable
end

function MemoryAdapter:SetBudgetAvailable(available: boolean)
	self._budgetAvailable = available
end

function MemoryAdapter:SetUpdateDelay(seconds: number)
	assert(type(seconds) == "number" and seconds >= 0, "Update delay must be non-negative")
	self._updateDelay = seconds
end

function MemoryAdapter:GetStats(): {[string]: number}
	return Util.deepCopy(self._stats)
end

function MemoryAdapter:_recordVersion(key: string, value: any, isDeleted: boolean)
	local adapter: any = self
	adapter._versionCounter += 1
	local history = adapter._versions[key]
	if not history then
		history = {}
		adapter._versions[key] = history
	end

	table.insert(history, {
		Version = `memory-{adapter._versionCounter}`,
		CreatedTime = os.time() * 1000 + adapter._versionCounter,
		IsDeleted = isDeleted,
		Value = Util.deepCopy(value),
	})
end

function MemoryAdapter:UpdateAsync(key: string, transform: (any, any?) -> ...any): any
	local adapter: any = self
	adapter:_maybeFail()
	adapter._stats.UpdateCalls += 1
	adapter._stats.ActiveUpdates += 1
	adapter._stats.PeakActiveUpdates = math.max(adapter._stats.PeakActiveUpdates, adapter._stats.ActiveUpdates)
	if adapter._updateDelay > 0 then
		task.wait(adapter._updateDelay)
	end

	local currentValue = Util.deepCopy(adapter._data[key])
	local ok, transformed = pcall(transform, currentValue, nil)
	adapter._stats.ActiveUpdates -= 1
	if not ok then
		error(transformed)
	end
	if transformed ~= nil then
		adapter._data[key] = Util.deepCopy(transformed)
		adapter:_recordVersion(key, transformed, false)
		if adapter._failAfterWrites > 0 then
			adapter._failAfterWrites -= 1
			error(adapter._failAfterMessage)
		end
		return Util.deepCopy(transformed)
	end
	return currentValue
end

function MemoryAdapter:GetAsync(key: string): any
	local adapter: any = self
	adapter:_maybeFail()
	adapter._stats.GetCalls += 1
	return Util.deepCopy(adapter._data[key])
end

function MemoryAdapter:RemoveAsync(key: string): any
	local adapter: any = self
	adapter:_maybeFail()
	adapter._stats.RemoveCalls += 1
	local oldValue = adapter._data[key]
	adapter._data[key] = nil
	adapter:_recordVersion(key, nil, true)
	return Util.deepCopy(oldValue)
end

function MemoryAdapter:GetVersionAsync(key: string, version: string): any
	self:_maybeFail()
	for _, entry in self._versions[key] or {} do
		if entry.Version == version then
			return Util.deepCopy(entry.Value)
		end
	end
	return nil
end

function MemoryAdapter:GetVersionAtTimeAsync(key: string, timestampMillis: number): any
	self:_maybeFail()
	local selected = nil
	for _, entry in self._versions[key] or {} do
		if entry.CreatedTime <= timestampMillis and (not selected or entry.CreatedTime > selected.CreatedTime) then
			selected = entry
		end
	end
	return if selected then Util.deepCopy(selected.Value) else nil
end

function MemoryAdapter:ListVersionsAsync(key: string, options: {[string]: any}?): {any}
	self:_maybeFail()
	local listOptions: any = options or {}
	local minDate = listOptions.MinDate or 0
	local maxDate = listOptions.MaxDate or math.huge
	local maxCount = listOptions.MaxCount or 50
	local ascending = tostring(listOptions.SortDirection):find("Ascending") ~= nil
	local versions = {}

	for _, entry in self._versions[key] or {} do
		if entry.CreatedTime >= minDate and entry.CreatedTime <= maxDate then
			table.insert(versions, {
				Version = entry.Version,
				CreatedTime = entry.CreatedTime,
				IsDeleted = entry.IsDeleted,
			})
		end
	end
	table.sort(versions, function(left: any, right: any): boolean
		if ascending then
			return left.CreatedTime < right.CreatedTime
		end
		return left.CreatedTime > right.CreatedTime
	end)
	while #versions > maxCount do
		table.remove(versions)
	end
	return versions
end

function MemoryAdapter:SetRaw(key: string, value: any, skipVersion: boolean?)
	self._data[key] = Util.deepCopy(value)
	if not skipVersion then
		self:_recordVersion(key, value, value == nil)
	end
end

function MemoryAdapter:Dump(): {[string]: any}
	return Util.deepCopy(self._data)
end

return MemoryAdapter
