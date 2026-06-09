--!nonstrict

local Util = require(script.Parent.Parent.Util)

local Settings = {}

Settings.Defaults = table.freeze({
	AutoSaveInterval = 60,
	AutoSaveCheckInterval = 1,
	AutoSaveConcurrency = 2,
	AutoSaveRetryInterval = 10,
	LeaseTimeout = 180,
	OpenTimeout = 20,
	OpenRetryInterval = 1,
	RetryAttempts = 5,
	RetryDelay = 0.5,
	RetryBackoff = 2,
	BudgetTimeout = 10,
	BudgetPollInterval = 0.25,
	MaxDataBytes = 3_800_000,
	CriticalErrorThreshold = 5,
	CriticalWindow = 120,
	CriticalRecovery = 60,
	CloseTimeout = 25,
	CloseRetryInterval = 1,
	CloseConcurrency = 10,
	OperationProcessLimit = 50,
	OperationReceiptLimit = 500,
	OperationDedupeLimit = 5_000,
	DeadLetterLimit = 100,
	DeadLetterPayloadMaxBytes = 8_192,
	OperationTTL = 0,
	WriteReceiptLimit = 20,
	MaxOperationAttempts = 10,
	UnknownOperationPolicy = "Retry",
	StrictData = false,
	TrackChangeDetails = false,
	AuditLogLimit = 0,
	ReconcileOnOpen = true,
	ValidateData = true,
	EnableMessaging = true,
	AutoReleaseOnHandoff = true,
	HandoffMessageCooldown = 2,
	BindToClose = true,
})

local function validateResolved(settings: any)
	assert(type(settings.AutoSaveInterval) == "number" and settings.AutoSaveInterval >= 0, "AutoSaveInterval must be non-negative")
	assert(type(settings.AutoSaveCheckInterval) == "number" and settings.AutoSaveCheckInterval > 0, "AutoSaveCheckInterval must be positive")
	assert(type(settings.AutoSaveConcurrency) == "number" and settings.AutoSaveConcurrency >= 1 and settings.AutoSaveConcurrency == math.floor(settings.AutoSaveConcurrency), "AutoSaveConcurrency must be a positive integer")
	assert(type(settings.AutoSaveRetryInterval) == "number" and settings.AutoSaveRetryInterval > 0, "AutoSaveRetryInterval must be positive")
	assert(type(settings.LeaseTimeout) == "number" and settings.LeaseTimeout > 0, "LeaseTimeout must be positive")
	assert(settings.LeaseTimeout > settings.AutoSaveInterval * 2, "LeaseTimeout must be greater than 2x AutoSaveInterval")
	assert(type(settings.OpenTimeout) == "number" and settings.OpenTimeout >= 0, "OpenTimeout must be non-negative")
	assert(type(settings.OpenRetryInterval) == "number" and settings.OpenRetryInterval > 0, "OpenRetryInterval must be positive")
	assert(type(settings.RetryAttempts) == "number" and settings.RetryAttempts >= 1, "RetryAttempts must be at least 1")
	assert(type(settings.RetryDelay) == "number" and settings.RetryDelay >= 0, "RetryDelay must be non-negative")
	assert(type(settings.RetryBackoff) == "number" and settings.RetryBackoff >= 1, "RetryBackoff must be at least 1")
	assert(type(settings.BudgetTimeout) == "number" and settings.BudgetTimeout >= 0, "BudgetTimeout must be non-negative")
	assert(type(settings.BudgetPollInterval) == "number" and settings.BudgetPollInterval > 0, "BudgetPollInterval must be positive")
	assert(type(settings.MaxDataBytes) == "number" and settings.MaxDataBytes > 0, "MaxDataBytes must be positive")
	assert(type(settings.CriticalErrorThreshold) == "number" and settings.CriticalErrorThreshold >= 0, "CriticalErrorThreshold must be non-negative")
	assert(type(settings.CriticalWindow) == "number" and settings.CriticalWindow > 0, "CriticalWindow must be positive")
	assert(type(settings.CriticalRecovery) == "number" and settings.CriticalRecovery > 0, "CriticalRecovery must be positive")
	assert(type(settings.CloseTimeout) == "number" and settings.CloseTimeout >= 0, "CloseTimeout must be non-negative")
	assert(type(settings.CloseRetryInterval) == "number" and settings.CloseRetryInterval > 0, "CloseRetryInterval must be positive")
	assert(type(settings.CloseConcurrency) == "number" and settings.CloseConcurrency >= 1 and settings.CloseConcurrency == math.floor(settings.CloseConcurrency), "CloseConcurrency must be a positive integer")
	assert(type(settings.OperationProcessLimit) == "number" and settings.OperationProcessLimit >= 1 and settings.OperationProcessLimit == math.floor(settings.OperationProcessLimit), "OperationProcessLimit must be a positive integer")
	assert(type(settings.OperationReceiptLimit) == "number" and settings.OperationReceiptLimit >= 1 and settings.OperationReceiptLimit == math.floor(settings.OperationReceiptLimit), "OperationReceiptLimit must be a positive integer")
	assert(type(settings.OperationDedupeLimit) == "number" and settings.OperationDedupeLimit >= settings.OperationReceiptLimit and settings.OperationDedupeLimit == math.floor(settings.OperationDedupeLimit), "OperationDedupeLimit must be an integer greater than or equal to OperationReceiptLimit")
	assert(type(settings.DeadLetterLimit) == "number" and settings.DeadLetterLimit >= 0 and settings.DeadLetterLimit == math.floor(settings.DeadLetterLimit), "DeadLetterLimit must be a non-negative integer")
	assert(type(settings.DeadLetterPayloadMaxBytes) == "number" and settings.DeadLetterPayloadMaxBytes >= 0 and settings.DeadLetterPayloadMaxBytes == math.floor(settings.DeadLetterPayloadMaxBytes), "DeadLetterPayloadMaxBytes must be a non-negative integer")
	assert(type(settings.OperationTTL) == "number" and settings.OperationTTL >= 0, "OperationTTL must be non-negative")
	assert(type(settings.WriteReceiptLimit) == "number" and settings.WriteReceiptLimit >= 1 and settings.WriteReceiptLimit == math.floor(settings.WriteReceiptLimit), "WriteReceiptLimit must be a positive integer")
	assert(type(settings.MaxOperationAttempts) == "number" and settings.MaxOperationAttempts >= 1 and settings.MaxOperationAttempts == math.floor(settings.MaxOperationAttempts), "MaxOperationAttempts must be a positive integer")
	assert(type(settings.UnknownOperationPolicy) == "string" and table.find({"Retry", "Cancel", "Fail"}, settings.UnknownOperationPolicy) ~= nil, "UnknownOperationPolicy must be Retry, Cancel, or Fail")
	assert(type(settings.StrictData) == "boolean", "StrictData must be a boolean")
	assert(type(settings.TrackChangeDetails) == "boolean", "TrackChangeDetails must be a boolean")
	assert(type(settings.AuditLogLimit) == "number" and settings.AuditLogLimit >= 0 and settings.AuditLogLimit == math.floor(settings.AuditLogLimit), "AuditLogLimit must be a non-negative integer")
	assert(type(settings.ReconcileOnOpen) == "boolean", "ReconcileOnOpen must be a boolean")
	assert(type(settings.ValidateData) == "boolean", "ValidateData must be a boolean")
	assert(type(settings.EnableMessaging) == "boolean", "EnableMessaging must be a boolean")
	assert(type(settings.AutoReleaseOnHandoff) == "boolean", "AutoReleaseOnHandoff must be a boolean")
	assert(type(settings.HandoffMessageCooldown) == "number" and settings.HandoffMessageCooldown >= 0, "HandoffMessageCooldown must be non-negative")
	assert(type(settings.BindToClose) == "boolean", "BindToClose must be a boolean")
end

function Settings.validate(overrides: any?): (any?, string?)
	if overrides ~= nil and type(overrides) ~= "table" then
		return nil, "config.Settings must be a table"
	end

	local settings = Util.merge(Settings.Defaults, overrides)
	local ok, message = pcall(validateResolved, settings)
	if not ok then
		return nil, tostring(message)
	end
	return settings, nil
end

return Settings
