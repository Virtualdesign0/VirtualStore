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

-- Both leaderboard indices share this module-wide gate. The budget check is
-- kept together with the real request so concurrent projections cannot all
-- consume the same apparent final token and overflow Roblox's throttle queue.
local writeBusy = false
local writeReleased = Instance.new("BindableEvent")

local function waitForBudget(requestKind: string, timeout: number, pollInterval: number): boolean
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

local function withWriteGate(requestKind: string, callback: () -> ...any): ...any
	while writeBusy do
		writeReleased.Event:Wait()
	end
	writeBusy = true

	local results = table.pack(pcall(function()
		-- OrderedIndex already performed the bounded wait. Re-check without
		-- extending its timeout while this shared gate is held.
		if not waitForBudget(requestKind, 0, 0.25) then
			error(`OrderedDataStore {requestKind} budget changed before the request started`)
		end
		return callback()
	end))

	writeBusy = false
	writeReleased:Fire()

	if not results[1] then
		error(results[2], 0)
	end

	return table.unpack(results, 2, results.n)
end

function DataStoreAdapter.new(name: string, scope: string?)
	return setmetatable({
		_store = DataStoreService:GetOrderedDataStore(name, scope),
	}, DataStoreAdapter)
end

function DataStoreAdapter:WaitForBudgetAsync(requestKind: string, timeout: number, pollInterval: number): boolean
	return waitForBudget(requestKind, timeout, pollInterval)
end

function DataStoreAdapter:SetAsync(key: string, value: number): any
	return withWriteGate("Write", function()
		return self._store:SetAsync(key, value)
	end)
end

function DataStoreAdapter:IncrementAsync(key: string, delta: number): number
	return withWriteGate("Write", function()
		return self._store:IncrementAsync(key, delta)
	end)
end

function DataStoreAdapter:GetAsync(key: string): number?
	return self._store:GetAsync(key)
end

function DataStoreAdapter:RemoveAsync(key: string): number?
	return withWriteGate("Remove", function()
		return self._store:RemoveAsync(key)
	end)
end

function DataStoreAdapter:GetSortedAsync(ascending: boolean, pageSize: number, minValue: number?, maxValue: number?): any
	return self._store:GetSortedAsync(ascending, pageSize, minValue, maxValue)
end

return DataStoreAdapter
