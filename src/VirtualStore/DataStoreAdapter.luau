--!strict

local DataStoreService = game:GetService("DataStoreService")

local DataStoreAdapter: any = {}
DataStoreAdapter.__index = DataStoreAdapter

local REQUEST_BUDGETS = {
	Read = {Enum.DataStoreRequestType.StandardRead},
	Update = {
		Enum.DataStoreRequestType.StandardRead,
		Enum.DataStoreRequestType.StandardWrite,
	},
	List = {Enum.DataStoreRequestType.StandardList},
	Remove = {Enum.DataStoreRequestType.StandardRemove},
}

function DataStoreAdapter.new(name: string, scope: string?)
	return setmetatable({
		_store = DataStoreService:GetDataStore(name, scope),
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

function DataStoreAdapter:UpdateAsync(key: string, transform: (any, any?) -> ...any): any
	return self._store:UpdateAsync(key, transform)
end

function DataStoreAdapter:GetAsync(key: string): any
	return self._store:GetAsync(key)
end

function DataStoreAdapter:RemoveAsync(key: string): any
	return self._store:RemoveAsync(key)
end

function DataStoreAdapter:GetVersionAsync(key: string, version: string): any
	return self._store:GetVersionAsync(key, version)
end

function DataStoreAdapter:GetVersionAtTimeAsync(key: string, timestampMillis: number): any
	return self._store:GetVersionAtTimeAsync(key, timestampMillis)
end

function DataStoreAdapter:ListVersionsAsync(key: string, options: {[string]: any}?): {any}
	local listOptions: any = options or {}
	local maxCount = listOptions.MaxCount or 50
	local pageSize = math.min(maxCount, 1000)
	local pages = self._store:ListVersionsAsync(
		key,
		listOptions.SortDirection or Enum.SortDirection.Descending,
		listOptions.MinDate or 0,
		listOptions.MaxDate or 0,
		pageSize
	)

	local versions = {}
	while #versions < maxCount do
		for _, info in pages:GetCurrentPage() do
			table.insert(versions, {
				Version = info.Version,
				CreatedTime = info.CreatedTime,
				IsDeleted = info.IsDeleted,
			})
			if #versions >= maxCount then
				break
			end
		end

		if #versions >= maxCount or pages.IsFinished then
			break
		end
		pages:AdvanceToNextPageAsync()
	end
	return versions
end

return DataStoreAdapter
