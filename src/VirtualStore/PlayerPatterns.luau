--!nonstrict

local Patterns = require(script.Parent.Patterns)
local Util = require(script.Parent.Util)

local PlayerPatterns = {}

local function patternOptions(patterns: {[string]: any}, name: string): {[string]: any}?
	local value = patterns[name]
	if value == nil or value == false then
		return nil
	end
	assert(value == true or type(value) == "table", `Patterns.{name} must be true, false, or a config table`)
	return if value == true then {} else table.clone(value)
end

local function installTemplate(template: {[any]: any}, pathValue: any, defaultPath: {any}, patternTemplate: {[any]: any})
	local path = Util.normalizePath(pathValue or defaultPath)
	local existing = Util.getPath(template, path)
	if existing == nil then
		Util.setPath(template, path, Util.deepCopy(patternTemplate))
		return
	end
	assert(type(existing) == "table", "Pattern path must point to a table in the player template")
	Util.reconcile(existing, patternTemplate)
end

local function registerOperation(operations: {[string]: any}, operationType: string, handler: any)
	assert(
		operations[operationType] == nil,
		`Operation "{operationType}" is already registered; remove the duplicate or configure a different pattern operation type`
	)
	operations[operationType] = handler
end

function PlayerPatterns.prepare(config: {[string]: any}, virtualStore: any): {[string]: any}
	local configured = config.Patterns
	assert(type(configured) == "table", "Patterns must be a table")

	local cooldowns = patternOptions(configured, "Cooldowns")
	if cooldowns then
		installTemplate(config.Template, cooldowns.Path, {"Cooldowns"}, Patterns.Cooldowns.template())
	end

	local dailyRewards = patternOptions(configured, "DailyRewards")
	if dailyRewards then
		assert(type(dailyRewards.Rewards) == "table", "Patterns.DailyRewards.Rewards must be an array")
		installTemplate(config.Template, dailyRewards.Path, {"DailyRewards"}, Patterns.DailyRewards.template())
		dailyRewards.Retry = dailyRewards.Retry or virtualStore.Retry
		registerOperation(
			config.Operations,
			dailyRewards.OperationType or "GrantDailyReward",
			Patterns.DailyRewards.operationHandler(dailyRewards.Rewards, dailyRewards)
		)
	end

	local purchaseReceipts = patternOptions(configured, "PurchaseReceipts")
	if purchaseReceipts then
		assert(type(purchaseReceipts.Products) == "table", "Patterns.PurchaseReceipts.Products must be a table keyed by ProductId")
		installTemplate(config.Template, purchaseReceipts.Path, {"Purchases"}, Patterns.PurchaseReceipts.template())
		purchaseReceipts.Retry = purchaseReceipts.Retry or virtualStore.Retry
		registerOperation(
			config.Operations,
			purchaseReceipts.OperationType or "GrantDeveloperProduct",
			Patterns.PurchaseReceipts.operationHandler(purchaseReceipts.Products, purchaseReceipts)
		)
	end

	local offlineRewards = patternOptions(configured, "OfflineRewards")
	if offlineRewards then
		installTemplate(config.Template, offlineRewards.Path, {"OfflineRewards"}, Patterns.OfflineRewards.template())
		registerOperation(
			config.Operations,
			offlineRewards.OperationType or "GrantOfflineReward",
			Patterns.OfflineRewards.operationHandler(offlineRewards)
		)
	end

	local timedEffects = patternOptions(configured, "TimedEffects")
	if timedEffects then
		installTemplate(config.Template, timedEffects.Path, {"TimedEffects"}, Patterns.TimedEffects.template())
		for operationType, handler in Patterns.TimedEffects.operationHandlers(timedEffects) do
			registerOperation(config.Operations, operationType, handler)
		end
	end

	return config
end

local function makeError(code: string, message: string)
	return {
		Code = code,
		Message = message,
	}
end

local function getSession(owner: any, player: any): (any?, any?)
	local session = owner:GetSession(player)
	if not session then
		return nil, makeError("PlayerDataUnavailable", "Player data is not loaded")
	end
	return session, nil
end

local function createCooldowns(owner: any, options: {[string]: any})
	local pattern = Patterns.Cooldowns.new(owner.Store, options)
	return {
		IsReady = function(_self, player, name, now)
			local session, err = getSession(owner, player)
			if not session then
				return false, err
			end
			return pattern:IsReady(session, name, now)
		end,
		GetRemaining = function(_self, player, name, now)
			local session, err = getSession(owner, player)
			if not session then
				return 0, err
			end
			return pattern:GetRemaining(session, name, now)
		end,
		Start = function(_self, player, name, duration, now)
			local session, err = getSession(owner, player)
			if not session then
				return false, err
			end
			return pattern:Start(session, name, duration, now)
		end,
		Clear = function(_self, player, name)
			local session, err = getSession(owner, player)
			if not session then
				return false, err
			end
			return pattern:Clear(session, name)
		end,
		CleanupExpired = function(_self, player, now)
			local session, err = getSession(owner, player)
			if not session then
				return false, err
			end
			return pattern:CleanupExpired(session, now)
		end,
	}
end

local function createDailyRewards(owner: any, options: {[string]: any})
	local pattern = Patterns.DailyRewards.new(owner.Store, options)
	return {
		GetState = function(_self, player, now)
			local session, err = getSession(owner, player)
			if not session then
				return nil, err
			end
			return pattern:GetState(session, now)
		end,
		CanClaim = function(_self, player, now)
			local session, err = getSession(owner, player)
			if not session then
				return false, "PlayerDataUnavailable", err
			end
			return pattern:CanClaim(session, now)
		end,
		ClaimAsync = function(_self, player, now)
			local session, err = getSession(owner, player)
			if not session then
				return nil, err
			end
			return pattern:ClaimAsync(session, player.UserId, now)
		end,
		Claim = function(self, player, now)
			return self:ClaimAsync(player, now)
		end,
	}
end

local function createOfflineRewards(owner: any, options: {[string]: any})
	local pattern = Patterns.OfflineRewards.new(owner.Store, options)
	return {
		GetPending = function(_self, player, now)
			local session, err = getSession(owner, player)
			if not session then
				return nil, err
			end
			return pattern:GetPending(session, now)
		end,
		ClaimAsync = function(_self, player, now)
			local session, err = getSession(owner, player)
			if not session then
				return nil, err
			end
			return pattern:ClaimAsync(session, player.UserId, now)
		end,
		Claim = function(self, player, now)
			return self:ClaimAsync(player, now)
		end,
		MarkSeen = function(_self, player, now)
			local session, err = getSession(owner, player)
			if not session then
				return false, err
			end
			return pattern:MarkSeen(session, now)
		end,
	}
end

local function createTimedEffects(owner: any, options: {[string]: any})
	local pattern = Patterns.TimedEffects.new(owner.Store, options)
	return {
		Get = function(_self, player, effectId, now)
			local session, err = getSession(owner, player)
			if not session then
				return nil, err
			end
			return pattern:Get(session, effectId, now)
		end,
		Has = function(_self, player, effectId, now)
			local session, err = getSession(owner, player)
			if not session then
				return false, err
			end
			return pattern:Has(session, effectId, now)
		end,
		GetRemaining = function(_self, player, effectId, now)
			local session, err = getSession(owner, player)
			if not session then
				return 0, err
			end
			return pattern:GetRemaining(session, effectId, now)
		end,
		Grant = function(_self, player, effectId, spec)
			local session, err = getSession(owner, player)
			if not session then
				return false, err
			end
			return pattern:Grant(session, effectId, spec)
		end,
		Remove = function(_self, player, effectId)
			local session, err = getSession(owner, player)
			if not session then
				return false, err
			end
			return pattern:Remove(session, effectId)
		end,
		CleanupExpired = function(_self, player, now)
			local session, err = getSession(owner, player)
			if not session then
				return false, err
			end
			return pattern:CleanupExpired(session, now)
		end,
		QueueGrantAsync = function(_self, player, operationId, effectId, spec, awaitResult)
			local session, err = getSession(owner, player)
			if not session then
				return nil, err
			end
			return pattern:QueueGrantAsync(session, operationId, effectId, spec, awaitResult)
		end,
		QueueRemoveAsync = function(_self, player, operationId, effectId, awaitResult)
			local session, err = getSession(owner, player)
			if not session then
				return nil, err
			end
			return pattern:QueueRemoveAsync(session, operationId, effectId, awaitResult)
		end,
		QueueCleanupAsync = function(_self, player, operationId, at, awaitResult)
			local session, err = getSession(owner, player)
			if not session then
				return nil, err
			end
			return pattern:QueueCleanupAsync(session, operationId, at, awaitResult)
		end,
	}
end

local function optionsFor(value: any): {[string]: any}?
	if value == nil or value == false then
		return nil
	end
	return if value == true then {} else value
end

function PlayerPatterns.attach(owner: any, config: {[string]: any}?)
	local configured = config or {}
	local attached = {}

	local cooldowns = optionsFor(configured.Cooldowns)
	if cooldowns then
		attached.Cooldowns = createCooldowns(owner, cooldowns)
	end
	local dailyRewards = optionsFor(configured.DailyRewards)
	if dailyRewards then
		attached.DailyRewards = createDailyRewards(owner, dailyRewards)
	end
	local purchaseReceipts = optionsFor(configured.PurchaseReceipts)
	if purchaseReceipts then
		attached.PurchaseReceipts = Patterns.PurchaseReceipts.new(owner.Store, purchaseReceipts)
	end
	local offlineRewards = optionsFor(configured.OfflineRewards)
	if offlineRewards then
		attached.OfflineRewards = createOfflineRewards(owner, offlineRewards)
	end
	local timedEffects = optionsFor(configured.TimedEffects)
	if timedEffects then
		attached.TimedEffects = createTimedEffects(owner, timedEffects)
	end

	owner.Patterns = attached
	owner.Cooldowns = attached.Cooldowns
	owner.DailyRewards = attached.DailyRewards
	owner.PurchaseReceipts = attached.PurchaseReceipts
	owner.OfflineRewards = attached.OfflineRewards
	owner.TimedEffects = attached.TimedEffects
	owner.Daily = attached.DailyRewards
	owner.Purchases = attached.PurchaseReceipts
	owner.Offline = attached.OfflineRewards
	owner.Effects = attached.TimedEffects

	if purchaseReceipts and purchaseReceipts.AutoBind then
		attached.PurchaseReceipts:Bind(game:GetService("MarketplaceService"))
	end
end

return PlayerPatterns
