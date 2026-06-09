--!strict

local DataStoreService = game:GetService("DataStoreService")

local DataStoreAdapter: any = {}
DataStoreAdapter.__index = DataStoreAdapter

local REQUEST_BUDGETS = {
	Read = {Enum.DataStoreRequestType.OrderedRead},
	Write = {Enum.DataStoreRequestType.OrderedWrite},
	List = {Enum.DataStoreRequestType.GetSortedAsync},
	Remove = {Enum.DataStoreRequestType.OrderedRemove},
}

function DataStoreAdapter.new(name: string, scope: string?)
	return setmetatable({
		_store = DataStoreService:GetOrderedDataStore(name, scope),
	}, DataStoreAdapter)
end

function DataStoreAdapter:WaitForBudgetAsync(requestKind: string, timeout: number, pollInterval: number): boolean
	local budgets = REQUEST_BUDGETS[requestKind]
	if not budgets then
		return true
	end

	local deadline = os.clock() + timeout
	while true do
		local available = true
		for _, requestType in budgets do
			if DataStoreService:GetRequestBudgetForRequestType(requestType) <= 0 then
				available = false
				break
			end
		end
		if available then
			return true
		end
		if os.clock() >= deadline then
			return false
		end
		task.wait(math.min(pollInterval, math.max(0, deadline - os.clock())))
	end
end

function DataStoreAdapter:SetAsync(key: string, value: number): any
	return self._store:SetAsync(key, value)
end

function DataStoreAdapter:IncrementAsync(key: string, delta: number): number
	return self._store:IncrementAsync(key, delta)
end

function DataStoreAdapter:GetAsync(key: string): number?
	return self._store:GetAsync(key)
end

function DataStoreAdapter:RemoveAsync(key: string): number?
	return self._store:RemoveAsync(key)
end

function DataStoreAdapter:GetSortedAsync(ascending: boolean, pageSize: number, minValue: number?, maxValue: number?): any
	return self._store:GetSortedAsync(ascending, pageSize, minValue, maxValue)
end

return DataStoreAdapter
