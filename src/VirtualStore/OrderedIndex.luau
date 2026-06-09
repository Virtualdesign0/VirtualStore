--!nonstrict

local DataStoreAdapter = require(script.DataStoreAdapter)
local MemoryAdapter = require(script.MemoryAdapter)

local OrderedIndex = {}
local Index: any = {}
Index.__index = Index

local DEFAULT_SETTINGS = table.freeze({
	RetryAttempts = 5,
	RetryDelay = 0.5,
	RetryBackoff = 2,
	BudgetTimeout = 10,
	BudgetPollInterval = 0.25,
	DefaultPageSize = 50,
	MaxQueryEntries = 1_000,
	MaxRankScan = 1_000,
	CacheTTL = 0,
})

local function copy(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local result = {}
	for key, child in value do
		result[copy(key)] = copy(child)
	end
	return result
end

local function makeError(code: string, message: string, key: string?, cause: any?, attempts: number?): any
	return {
		Code = code,
		Message = message,
		Key = key,
		Cause = cause,
		Attempts = attempts,
	}
end

local function validateKey(key: any)
	assert(type(key) == "string" and #key > 0, "OrderedIndex key must be a non-empty string")
end

local function validateInteger(value: any, label: string)
	assert(
		type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge and value == math.floor(value),
		`{label} must be a finite integer`
	)
end

local function validateOptionalInteger(value: any, label: string)
	if value ~= nil then
		validateInteger(value, label)
	end
end

local function resolveSettings(overrides: any?): any
	assert(overrides == nil or type(overrides) == "table", "OrderedIndex Settings must be a table")
	local settings = {}
	for key, value in DEFAULT_SETTINGS do
		settings[key] = value
	end
	for key, value in overrides or {} do
		assert(DEFAULT_SETTINGS[key] ~= nil, `Unknown OrderedIndex setting "{tostring(key)}"`)
		settings[key] = value
	end
	assert(type(settings.RetryAttempts) == "number" and settings.RetryAttempts >= 1 and settings.RetryAttempts == math.floor(settings.RetryAttempts), "RetryAttempts must be a positive integer")
	assert(type(settings.RetryDelay) == "number" and settings.RetryDelay >= 0, "RetryDelay must be non-negative")
	assert(type(settings.RetryBackoff) == "number" and settings.RetryBackoff >= 1, "RetryBackoff must be at least 1")
	assert(type(settings.BudgetTimeout) == "number" and settings.BudgetTimeout >= 0, "BudgetTimeout must be non-negative")
	assert(type(settings.BudgetPollInterval) == "number" and settings.BudgetPollInterval > 0, "BudgetPollInterval must be positive")
	assert(type(settings.DefaultPageSize) == "number" and settings.DefaultPageSize >= 1 and settings.DefaultPageSize <= 100 and settings.DefaultPageSize == math.floor(settings.DefaultPageSize), "DefaultPageSize must be an integer from 1 to 100")
	assert(type(settings.MaxQueryEntries) == "number" and settings.MaxQueryEntries >= 1 and settings.MaxQueryEntries == math.floor(settings.MaxQueryEntries), "MaxQueryEntries must be a positive integer")
	assert(type(settings.MaxRankScan) == "number" and settings.MaxRankScan >= 1 and settings.MaxRankScan == math.floor(settings.MaxRankScan), "MaxRankScan must be a positive integer")
	assert(type(settings.CacheTTL) == "number" and settings.CacheTTL >= 0, "CacheTTL must be non-negative")
	return table.freeze(settings)
end

local function resolveQuery(self: any, limit: number?, options: any?): (number, any)
	assert(options == nil or type(options) == "table", "OrderedIndex query options must be a table")
	local query = options or {}
	local resolvedLimit = limit or self.Settings.DefaultPageSize
	assert(type(resolvedLimit) == "number" and resolvedLimit >= 1 and resolvedLimit == math.floor(resolvedLimit), "OrderedIndex query limit must be a positive integer")
	assert(resolvedLimit <= self.Settings.MaxQueryEntries, "OrderedIndex query limit exceeds MaxQueryEntries")
	local pageSize = query.PageSize or math.min(self.Settings.DefaultPageSize, resolvedLimit, 100)
	assert(type(pageSize) == "number" and pageSize >= 1 and pageSize <= 100 and pageSize == math.floor(pageSize), "PageSize must be an integer from 1 to 100")
	local ascending = if query.Ascending == nil then self.Ascending else query.Ascending
	assert(type(ascending) == "boolean", "Ascending must be a boolean")
	local minValue = if query.MinValue == nil then self.MinValue else query.MinValue
	local maxValue = if query.MaxValue == nil then self.MaxValue else query.MaxValue
	validateOptionalInteger(minValue, "MinValue")
	validateOptionalInteger(maxValue, "MaxValue")
	assert(minValue == nil or maxValue == nil or minValue <= maxValue, "MinValue must be less than or equal to MaxValue")
	return resolvedLimit, {
		Ascending = ascending,
		PageSize = pageSize,
		MinValue = minValue,
		MaxValue = maxValue,
		BypassCache = query.BypassCache == true,
	}
end

local function cacheKey(limit: number, query: any): string
	return table.concat({
		tostring(limit),
		tostring(query.Ascending),
		tostring(query.PageSize),
		tostring(query.MinValue),
		tostring(query.MaxValue),
	}, "|")
end

function OrderedIndex.new(config: any): any
	assert(type(config) == "table", "OrderedIndex.new expects a config table")
	assert(type(config.Name) == "string" and #config.Name > 0, "OrderedIndex Name must be a non-empty string")
	assert(config.Scope == nil or type(config.Scope) == "string", "OrderedIndex Scope must be a string")
	assert(config.Ascending == nil or type(config.Ascending) == "boolean", "OrderedIndex Ascending must be a boolean")
	validateOptionalInteger(config.MinValue, "OrderedIndex MinValue")
	validateOptionalInteger(config.MaxValue, "OrderedIndex MaxValue")
	assert(config.MinValue == nil or config.MaxValue == nil or config.MinValue <= config.MaxValue, "OrderedIndex MinValue must be less than or equal to MaxValue")

	local self: any = setmetatable({
		Name = config.Name,
		Scope = config.Scope or "global",
		Ascending = config.Ascending == true,
		MinValue = config.MinValue,
		MaxValue = config.MaxValue,
		Settings = resolveSettings(config.Settings),
		_adapter = config.Adapter or DataStoreAdapter.new(config.Name, config.Scope),
		_cache = {},
		_metrics = {
			Requests = 0,
			Successes = 0,
			Failures = 0,
			Retries = 0,
			BudgetWaits = 0,
			BudgetTimeouts = 0,
			CacheHits = 0,
			CacheMisses = 0,
			Sets = 0,
			Increments = 0,
			Reads = 0,
			Removes = 0,
			Lists = 0,
			RankScans = 0,
			LastError = nil,
		},
	}, Index)
	return self
end

function Index:_clearCache()
	table.clear(self._cache)
end

function Index:_call(
	operation: string,
	key: string?,
	requestKind: string,
	callback: () -> any,
	maxAttempts: number?,
	failureCode: string?
): (boolean, any)
	local lastCause = nil
	local attempts = maxAttempts or self.Settings.RetryAttempts
	for attempt = 1, attempts do
		if type(self._adapter.WaitForBudgetAsync) == "function" then
			local waitStarted = os.clock()
			local budgetOk, available = pcall(
				self._adapter.WaitForBudgetAsync,
				self._adapter,
				requestKind,
				self.Settings.BudgetTimeout,
				self.Settings.BudgetPollInterval
			)
			if os.clock() - waitStarted >= self.Settings.BudgetPollInterval then
				self._metrics.BudgetWaits += 1
			end
			if not budgetOk or available ~= true then
				self._metrics.BudgetTimeouts += 1
				self._metrics.Failures += 1
				local err = makeError("BudgetTimeout", `{operation} timed out waiting for {requestKind} budget`, key, if budgetOk then nil else available)
				self._metrics.LastError = err
				return false, err
			end
		end

		self._metrics.Requests += 1
		local ok, result = pcall(callback)
		if ok then
			self._metrics.Successes += 1
			return true, result
		end
		lastCause = result
		if attempt < attempts then
			self._metrics.Retries += 1
			task.wait(self.Settings.RetryDelay * (self.Settings.RetryBackoff ^ (attempt - 1)))
		end
	end

	self._metrics.Failures += 1
	local err = makeError(failureCode or "OrderedDataStoreError", `{operation} failed after {attempts} attempts`, key, tostring(lastCause), attempts)
	self._metrics.LastError = err
	return false, err
end

function Index:SetAsync(key: string, value: number): (number?, any?)
	validateKey(key)
	validateInteger(value, "OrderedIndex value")
	local ok, result = self:_call("SetAsync", key, "Write", function()
		return self._adapter:SetAsync(key, value)
	end)
	if not ok then
		return nil, result
	end
	self._metrics.Sets += 1
	self:_clearCache()
	return value, nil
end

function Index:ProjectAsync(key: string, value: number): (number?, any?)
	return self:SetAsync(key, value)
end

function Index:IncrementAsync(key: string, delta: number): (number?, any?)
	validateKey(key)
	validateInteger(delta, "OrderedIndex delta")
	local ok, result = self:_call("IncrementAsync", key, "Write", function()
		return self._adapter:IncrementAsync(key, delta)
	end, 1, "AmbiguousIncrement")
	if not ok then
		return nil, result
	end
	validateInteger(result, "OrderedIndex increment result")
	self._metrics.Increments += 1
	self:_clearCache()
	return result, nil
end

function Index:GetAsync(key: string): (number?, any?)
	validateKey(key)
	local ok, result = self:_call("GetAsync", key, "Read", function()
		return self._adapter:GetAsync(key)
	end)
	if not ok then
		return nil, result
	end
	if result ~= nil then
		validateInteger(result, "OrderedIndex stored value")
	end
	self._metrics.Reads += 1
	return result, nil
end

function Index:RemoveAsync(key: string): (number?, any?)
	validateKey(key)
	local ok, result = self:_call("RemoveAsync", key, "Remove", function()
		return self._adapter:RemoveAsync(key)
	end)
	if not ok then
		return nil, result
	end
	if result ~= nil then
		validateInteger(result, "OrderedIndex removed value")
	end
	self._metrics.Removes += 1
	self:_clearCache()
	return result, nil
end

function Index:GetTopAsync(limit: number?, options: any?): ({any}?, any?)
	local resolvedLimit, query = resolveQuery(self, limit, options)
	local signature = cacheKey(resolvedLimit, query)
	local cached = self._cache[signature]
	if not query.BypassCache and self.Settings.CacheTTL > 0 and cached and os.clock() - cached.At <= self.Settings.CacheTTL then
		self._metrics.CacheHits += 1
		return copy(cached.Entries), nil
	end
	self._metrics.CacheMisses += 1

	local ok, pagesOrError = self:_call("GetSortedAsync", nil, "List", function()
		return self._adapter:GetSortedAsync(query.Ascending, query.PageSize, query.MinValue, query.MaxValue)
	end)
	if not ok then
		return nil, pagesOrError
	end

	local entries = {}
	local pages = pagesOrError
	while #entries < resolvedLimit do
		local page = pages:GetCurrentPage()
		for _, entry in page do
			validateKey(entry.key)
			validateInteger(entry.value, "OrderedIndex sorted value")
			table.insert(entries, {
				Rank = #entries + 1,
				Key = entry.key,
				Value = entry.value,
			})
			if #entries >= resolvedLimit then
				break
			end
		end
		if #entries >= resolvedLimit or pages.IsFinished then
			break
		end
		local advanced, advanceError = self:_call("AdvanceToNextPageAsync", nil, "List", function()
			return pages:AdvanceToNextPageAsync()
		end)
		if not advanced then
			return nil, advanceError
		end
	end
	self._metrics.Lists += 1
	if self.Settings.CacheTTL > 0 then
		self._cache[signature] = {
			At = os.clock(),
			Entries = copy(entries),
		}
	end
	return entries, nil
end

function Index:GetRankAsync(key: string, options: any?): (any?, any?)
	validateKey(key)
	assert(options == nil or type(options) == "table", "GetRankAsync options must be a table")
	local value, readError = self:GetAsync(key)
	if readError then
		return nil, readError
	end
	if value == nil then
		return nil, makeError("NotRanked", "OrderedIndex key has no stored value", key)
	end
	local rankOptions = options or {}
	local maxScan = rankOptions.MaxScan or self.Settings.MaxRankScan
	assert(type(maxScan) == "number" and maxScan >= 1 and maxScan == math.floor(maxScan), "MaxScan must be a positive integer")
	assert(maxScan <= self.Settings.MaxQueryEntries, "MaxScan exceeds MaxQueryEntries")
	local entries, listError = self:GetTopAsync(maxScan, rankOptions)
	if not entries then
		return nil, listError
	end
	self._metrics.RankScans += 1
	for _, entry in entries do
		if entry.Key == key then
			return {
				Rank = entry.Rank,
				Key = key,
				Value = value,
				Scanned = #entries,
			}, nil
		end
	end
	if #entries >= maxScan then
		return nil, makeError("RankScanLimit", `OrderedIndex rank was not found within the first {maxScan} entries`, key)
	end
	return nil, makeError("NotRanked", "OrderedIndex key was not present in the selected sorted range", key)
end

function Index:ProjectSessionAsync(session: any, key: string, path: any): (number?, any?)
	assert(type(session) == "table" and type(session.Get) == "function", "ProjectSessionAsync expects a VirtualStore Session")
	validateKey(key)
	local value = session:Get(path)
	validateInteger(value, "OrderedIndex projected Session value")
	return self:ProjectAsync(key, value)
end

function Index:BindSession(session: any, key: string, path: any, options: any?): any
	assert(type(session) == "table" and session.OnSaved and type(session.OnSaved.Connect) == "function", "BindSession expects a VirtualStore Session")
	validateKey(key)
	assert(options == nil or type(options) == "table", "BindSession options must be a table")
	local bindOptions = options or {}
	assert(bindOptions.OnError == nil or type(bindOptions.OnError) == "function", "BindSession OnError must be a function")
	local lastProjected = nil

	local function project()
		local readOk, value = pcall(session.Get, session, path)
		if not readOk then
			if bindOptions.OnError then
				bindOptions.OnError(makeError("ProjectionReadFailed", "OrderedIndex could not read the Session projection path", key, tostring(value)))
			end
			return
		end
		if value == lastProjected then
			return
		end
		local projectOk, projected, err = pcall(self.ProjectAsync, self, key, value)
		if not projectOk then
			err = makeError("ProjectionFailed", "OrderedIndex Session projection raised an error", key, tostring(projected))
			projected = nil
		end
		if projected ~= nil then
			lastProjected = projected
		elseif bindOptions.OnError then
			bindOptions.OnError(err)
		end
	end

	local connection = session.OnSaved:Connect(function()
		task.spawn(project)
	end)
	if bindOptions.ProjectNow == true then
		task.spawn(project)
	end
	return connection
end

function Index:ClearCache()
	self:_clearCache()
end

function Index:GetDiagnostics(): any
	return {
		Name = self.Name,
		Scope = self.Scope,
		Ascending = self.Ascending,
		Settings = copy(self.Settings),
		Metrics = copy(self._metrics),
	}
end

OrderedIndex.MemoryAdapter = MemoryAdapter
OrderedIndex.DefaultSettings = DEFAULT_SETTINGS

return OrderedIndex
