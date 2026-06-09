--!nonstrict

local StoreFactory = {}

function StoreFactory.new(config: {[string]: any}, dependencies: {
	DataStoreAdapter: any,
	Game: any,
	Settings: any,
	Signal: any,
	Store: any,
	Util: any,
	})
	local DataStoreAdapter = dependencies.DataStoreAdapter
	local game = dependencies.Game
	local Settings = dependencies.Settings
	local Signal = dependencies.Signal
	local Store = dependencies.Store
	local Util = dependencies.Util
	assert(type(config) == "table", "VirtualStore.new expects a config table")
	assert(type(config.Name) == "string" and #config.Name > 0, "config.Name must be a non-empty string")
	assert(type(config.Template) == "table", "config.Template must be a table")
	assert(config.Scope == nil or type(config.Scope) == "string", "config.Scope must be a string")
	assert(config.Migrations == nil or type(config.Migrations) == "table", "config.Migrations must be a table")
	assert(config.Operations == nil or type(config.Operations) == "table", "config.Operations must be a table")
	assert(config.AdminAuthorize == nil or type(config.AdminAuthorize) == "function", "config.AdminAuthorize must be a function")

	local schemaVersion = config.SchemaVersion or 1
	assert(
		type(schemaVersion) == "number" and schemaVersion >= 1 and schemaVersion == math.floor(schemaVersion),
		"config.SchemaVersion must be a positive integer"
	)
	local validTemplate, templateMessage = Util.validateData(config.Template)
	assert(validTemplate, templateMessage or "config.Template is invalid")

	local settings, settingsError = Settings.validate(config.Settings)
	assert(settings, settingsError)

	local adapter = config.Adapter or DataStoreAdapter.new(config.Name, config.Scope)
	local self = setmetatable({
		Name = config.Name,
		Scope = config.Scope or "global",
		Template = Util.deepCopy(config.Template),
		SchemaVersion = schemaVersion,
		Migrations = config.Migrations or {},
		Operations = config.Operations or {},
		AdminAuthorize = config.AdminAuthorize,
		Settings = settings,
		OnError = Signal.new(),
		CriticalStateChanged = Signal.new(),
		SessionOpened = Signal.new(),
		SessionClosed = Signal.new(),
		OperationQueued = Signal.new(),
		OperationApplied = Signal.new(),
		OperationRetried = Signal.new(),
		OperationFailed = Signal.new(),
		_adapter = adapter,
		_sessions = {},
		_opening = {},
		_closed = false,
		_closeResult = nil,
		_closeFinished = Signal.new(),
		_handoffSentAt = {},
		_subscription = nil,
		_identity = `{config.Name}/{config.Scope or "global"}`,
		_autoSaveSequence = 0,
		_autoSaveRunning = 0,
		_closeRunning = 0,
		_critical = false,
		_issues = {},
		_lastIssueAt = nil,
		_metrics = {
			Requests = 0,
			Successes = 0,
			Failures = 0,
			Retries = 0,
			BudgetWaits = 0,
			BudgetTimeouts = 0,
			TotalBudgetWait = 0,
			TotalLatency = 0,
			AverageLatency = 0,
			LastLatency = 0,
			LastOperation = nil,
			LastError = nil,
			OpenedSessions = 0,
			Saves = 0,
			AutoSaves = 0,
			AutoSaveFailures = 0,
			AutoSavesSkipped = 0,
			CleanAutoSavesSkipped = 0,
			PeakConcurrentAutoSaves = 0,
			Restores = 0,
			Deletes = 0,
			LeaseLosses = 0,
			CloseTimeouts = 0,
			PeakConcurrentCloseSaves = 0,
			OperationsQueued = 0,
			OperationsApplied = 0,
			OperationDuplicates = 0,
			OperationRetries = 0,
			OperationFailures = 0,
			OperationsExpired = 0,
			DeadLettersCreated = 0,
			AdminRepairs = 0,
			AdminAccessDenied = 0,
			ForcedLeaseReleases = 0,
		},
	}, Store)

	if settings.EnableMessaging then
		self:_subscribeToHandoffs()
	end
	if settings.AutoSaveInterval > 0 then
		self:_startAutoSave()
	end
	if settings.CriticalErrorThreshold > 0 then
		self:_startHealthMonitor()
	end
	if settings.BindToClose then
		game:BindToClose(function()
			self:CloseAsync()
		end)
	end

	return self
end

return StoreFactory
