--!nonstrict

local Common = require(script.Parent.Common)

local TEMPLATE = {
	LastSeenAt = 0,
	LastClaimAt = 0,
	LastClaimedSeenAt = 0,
}

local OfflineRewards = {}
OfflineRewards.__index = OfflineRewards

local function defaultCalculate(seconds: number, config: {[string]: any}): number
	return math.floor(seconds / 60) * config.CoinsPerMinute
end

local function defaultGrant(data: {[any]: any}, reward: any)
	assert(type(reward) == "number", "Default offline reward must be a number")
	assert(type(data.Coins) == "number", "Default offline reward grant requires data.Coins")
	data.Coins += reward
end

local function settings(options: {[string]: any}?): {[string]: any}
	local config = options or {}
	local result = {
		Path = Common.path(config.Path, {"OfflineRewards"}),
		MaxSeconds = config.MaxSeconds or 8 * 60 * 60,
		MinimumSeconds = config.MinimumSeconds or 60,
		CoinsPerMinute = config.CoinsPerMinute or 5,
		Calculate = config.Calculate,
		Grant = config.Grant or defaultGrant,
	}
	result.Calculate = result.Calculate or function(seconds)
		return defaultCalculate(seconds, result)
	end
	assert(type(result.MaxSeconds) == "number" and result.MaxSeconds >= 0, "MaxSeconds must be non-negative")
	assert(type(result.MinimumSeconds) == "number" and result.MinimumSeconds >= 0, "MinimumSeconds must be non-negative")
	assert(type(result.Calculate) == "function", "Offline reward Calculate must be a function")
	assert(type(result.Grant) == "function", "Offline reward Grant must be a function")
	return result
end

function OfflineRewards.new(store: any, options: {[string]: any}?): any
	assert(store, "OfflineRewards needs a store")
	local config = options or {}
	local rules = settings(config)
	return setmetatable({
		Store = store,
		Path = rules.Path,
		Rules = rules,
		Clock = config.Clock or os.time,
		OperationType = config.OperationType or "GrantOfflineReward",
		AwaitTimeout = config.AwaitTimeout or 15,
		PollInterval = config.PollInterval or 0.5,
	}, OfflineRewards)
end

function OfflineRewards.template(): {[any]: any}
	return {
		LastSeenAt = 0,
		LastClaimAt = 0,
		LastClaimedSeenAt = 0,
	}
end

function OfflineRewards.operationId(userId: any, lastSeenAt: number): string
	assert(userId ~= nil, "Offline reward user ID is required")
	return Common.operationId("offline", userId, Common.assertTimestamp(lastSeenAt, "LastSeenAt"))
end

function OfflineRewards.operationHandler(options: {[string]: any}?): (({[any]: any}, {[any]: any}, {[any]: any}) -> any)
	local rules = settings(options)
	return function(data, payload, context)
		local lastSeenAt = Common.assertTimestamp(payload.LastSeenAt, "LastSeenAt")
		local claimAt = Common.assertTimestamp(payload.ClaimAt, "ClaimAt")
		local state = Common.state(data, rules.Path, TEMPLATE)
		if (state.LastClaimedSeenAt or 0) >= lastSeenAt then
			return {
				AlreadyClaimed = true,
				LastSeenAt = lastSeenAt,
			}
		end
		if state.LastSeenAt ~= lastSeenAt then
			return {
				Stale = true,
				ExpectedLastSeenAt = state.LastSeenAt,
				LastSeenAt = lastSeenAt,
			}
		end

		local seconds = math.min(rules.MaxSeconds, math.max(0, claimAt - lastSeenAt))
		if seconds < rules.MinimumSeconds then
			return {
				NoReward = true,
				OfflineSeconds = seconds,
			}
		end
		local reward = rules.Calculate(seconds, {
			Data = data,
			LastSeenAt = lastSeenAt,
			ClaimAt = claimAt,
			Operation = context,
		})
		local grantResult = rules.Grant(data, reward, {
			LastSeenAt = lastSeenAt,
			ClaimAt = claimAt,
			OfflineSeconds = seconds,
			Operation = context,
		})
		state.LastClaimAt = claimAt
		state.LastClaimedSeenAt = lastSeenAt
		state.LastSeenAt = claimAt
		return {
			Granted = true,
			OfflineSeconds = seconds,
			Reward = reward,
			GrantResult = grantResult,
		}
	end
end

function OfflineRewards:GetPending(session: any, now: number?): (any?, string?)
	local claimAt = now or self.Clock()
	local state = Common.read(session, self.Path, TEMPLATE)
	local lastSeenAt = state.LastSeenAt or 0
	if lastSeenAt <= 0 then
		return nil, "NoLastSeenAt"
	end
	local seconds = math.min(self.Rules.MaxSeconds, math.max(0, claimAt - lastSeenAt))
	if seconds < self.Rules.MinimumSeconds then
		return nil, "NoReward"
	end
	return {
		LastSeenAt = lastSeenAt,
		ClaimAt = claimAt,
		OfflineSeconds = seconds,
		Reward = self.Rules.Calculate(seconds, {
			Session = session,
			LastSeenAt = lastSeenAt,
			ClaimAt = claimAt,
		}),
	}, nil
end

function OfflineRewards:ClaimAsync(session: any, userId: any, now: number?): (any?, any?)
	local pending, pendingError = self:GetPending(session, now)
	if not pending then
		return nil, Common.error(pendingError, "No offline reward is ready")
	end
	local operationId = OfflineRewards.operationId(userId, pending.LastSeenAt)
	local queued, queueError = session:QueueOperationAsync(operationId, self.OperationType, {
		LastSeenAt = pending.LastSeenAt,
		ClaimAt = pending.ClaimAt,
	})
	if not queued then
		return nil, queueError
	end
	return self.Store:AwaitOperationAsync(session.Key, operationId, self.AwaitTimeout, self.PollInterval)
end

function OfflineRewards:MarkSeen(session: any, now: number?): (boolean, any?)
	local timestamp = now or self.Clock()
	Common.assertTimestamp(timestamp, "LastSeenAt")
	return session:Transaction(function(data)
		local state = Common.state(data, self.Path, TEMPLATE)
		state.LastSeenAt = timestamp
	end, {
		Reason = "OfflineRewardSeen",
	})
end

return OfflineRewards
