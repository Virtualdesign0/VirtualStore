--!nonstrict

local MemoryAdapter: any = {}
MemoryAdapter.__index = MemoryAdapter

local Pages: any = {}
Pages.__index = Pages

local function copyEntries(entries: {any}): {any}
	local result = {}
	for index, entry in entries do
		result[index] = {
			key = entry.key,
			value = entry.value,
		}
	end
	return result
end

function Pages.new(entries: {any}, pageSize: number)
	local self: any = setmetatable({
		_entries = entries,
		_pageSize = pageSize,
		_page = 1,
		IsFinished = #entries <= pageSize,
	}, Pages)
	return self
end

function Pages:GetCurrentPage(): {any}
	local first = (self._page - 1) * self._pageSize + 1
	local last = math.min(first + self._pageSize - 1, #self._entries)
	local result = {}
	for index = first, last do
		local entry = self._entries[index]
		if entry then
			table.insert(result, {
				key = entry.key,
				value = entry.value,
			})
		end
	end
	return result
end

function Pages:AdvanceToNextPageAsync()
	if self.IsFinished then
		return
	end
	self._page += 1
	self.IsFinished = self._page * self._pageSize >= #self._entries
end

function MemoryAdapter.new(initialData: {[string]: number}?)
	local data = {}
	for key, value in initialData or {} do
		data[key] = value
	end
	return setmetatable({
		_data = data,
		_budgetAvailable = true,
		_failuresLeft = 0,
		_failureMessage = "Injected OrderedMemoryAdapter failure",
		_stats = {
			SetCalls = 0,
			IncrementCalls = 0,
			GetCalls = 0,
			RemoveCalls = 0,
			SortedCalls = 0,
		},
	}, MemoryAdapter)
end

function MemoryAdapter:_maybeFail()
	if self._failuresLeft <= 0 then
		return
	end
	self._failuresLeft -= 1
	error(self._failureMessage)
end

function MemoryAdapter:FailNext(count: number, message: string?)
	self._failuresLeft = count
	self._failureMessage = message or "Injected OrderedMemoryAdapter failure"
end

function MemoryAdapter:SetBudgetAvailable(available: boolean)
	self._budgetAvailable = available
end

function MemoryAdapter:WaitForBudgetAsync(_requestKind: string, _timeout: number, _pollInterval: number): boolean
	return self._budgetAvailable
end

function MemoryAdapter:GetStats(): {[string]: number}
	return table.clone(self._stats)
end

function MemoryAdapter:SetAsync(key: string, value: number)
	self:_maybeFail()
	self._stats.SetCalls += 1
	self._data[key] = value
end

function MemoryAdapter:IncrementAsync(key: string, delta: number): number
	self:_maybeFail()
	self._stats.IncrementCalls += 1
	local value = (self._data[key] or 0) + delta
	self._data[key] = value
	return value
end

function MemoryAdapter:GetAsync(key: string): number?
	self:_maybeFail()
	self._stats.GetCalls += 1
	return self._data[key]
end

function MemoryAdapter:RemoveAsync(key: string): number?
	self:_maybeFail()
	self._stats.RemoveCalls += 1
	local value = self._data[key]
	self._data[key] = nil
	return value
end

function MemoryAdapter:GetSortedAsync(ascending: boolean, pageSize: number, minValue: number?, maxValue: number?): any
	self:_maybeFail()
	self._stats.SortedCalls += 1
	local entries = {}
	for key, value in self._data do
		if (minValue == nil or value >= minValue) and (maxValue == nil or value <= maxValue) then
			table.insert(entries, {
				key = key,
				value = value,
			})
		end
	end
	table.sort(entries, function(left, right)
		if left.value == right.value then
			return left.key < right.key
		end
		if ascending then
			return left.value < right.value
		end
		return left.value > right.value
	end)
	return Pages.new(copyEntries(entries), pageSize)
end

return MemoryAdapter
