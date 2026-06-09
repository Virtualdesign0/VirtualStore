--!nonstrict

local Common = require(script.Parent.Common)

local DAY_SECONDS = 24 * 60 * 60
local TEMPLATE = {
	LastClaimAt = 0,
	Streak = 0,
	BestStreak = 0,
	TotalClaims = 0,
	ClaimedDays = {},
	ClaimOrder = {},
}

local DailyRewards = {}
DailyRewards.__index = DailyRewards

local function dayIndex(timestamp: number): number
	return math.floor(timestamp / DAY_SECONDS)
end

local function dayKey(timestamp: number): string
	return tostring(dayIndex(timestamp))
end

local function pruneClaims(state: {[any]: any}, limit: number)
	while #state.ClaimOrder > limit do
		local removed = table.remove(state.ClaimOrder, 1)
		state.ClaimedDays[removed] = nil
	end
end

function DailyRewards.new(store: any, options: {[string]: any}?): any
	assert(store, "DailyRewards needs a store")
	local config = options or {}
	return setmetatable({
		Store = store,
		Path = Common.path(config.Path, {"DailyRewards"}),
		Clock = config.Clock or os.time,
		OperationType = config.OperationType or "GrantDailyReward",
		AwaitTimeout = config.AwaitTimeout or 15,
		PollInterval = config.PollInterval or 0.5,
	}, DailyRewards)
end

function DailyRewards.template(): {[any]: any}
	return {
		LastClaimAt = 0,
		Streak = 0,
		BestStreak = 0,
		TotalClaims = 0,
		ClaimedDays = {},
		ClaimOrder = {},
	}
end

function DailyRewards.dayKey(timestamp: number): string
	return dayKey(Common.assertTimestamp(timestamp))
end

function DailyRewards.operationId(userId: any, timestamp: number): string
	assert(userId ~= nil, "Daily reward user ID is required")
	return Common.operationId("daily", userId, dayKey(Common.assertTimestamp(timestamp)))
end

function DailyRewards.operationHandler(rewards: {[any]: any}, options: {[string]: any}?): (({[any]: any}, {[any]: any}, {[any]: any}) -> any)
	assert(type(rewards) == "table" and #rewards > 0, "Daily rewards must be a non-empty array")
	local config = options or {}
	local path = Common.path(config.Path, {"DailyRewards"})
	local claimLimit = config.ClaimedDayLimit or 45
	local grant = config.Grant
	local retryToken = config.Retry
	assert(type(claimLimit) == "number" and claimLimit >= 1 and claimLimit == math.floor(claimLimit), "ClaimedDayLimit must be a positive integer")
	assert(grant == nil or type(grant) == "function", "Daily reward Grant must be a function")

	return function(data, payload, context)
		local claimAt = Common.assertTimestamp(payload.ClaimAt, "ClaimAt")
		local claimDay = dayKey(claimAt)
		assert(payload.DayKey == claimDay, "Daily reward DayKey does not match ClaimAt")
		local state = Common.state(data, path, TEMPLATE)
		state.ClaimedDays = state.ClaimedDays or {}
		state.ClaimOrder = state.ClaimOrder or {}

		if state.ClaimedDays[claimDay] then
			return {
				AlreadyClaimed = true,
				DayKey = claimDay,
				Streak = state.Streak or 0,
			}
		end

		local lastClaimAt = state.LastClaimAt or 0
		local streak = if lastClaimAt > 0 and dayIndex(claimAt) - dayIndex(lastClaimAt) == 1
			then (state.Streak or 0) + 1
			else 1
		local rewardIndex = ((streak - 1) % #rewards) + 1
		local reward = rewards[rewardIndex]
		local grantResult = nil
		if type(reward) == "function" then
			grantResult = reward(data, {
				ClaimAt = claimAt,
				DayKey = claimDay,
				Streak = streak,
				RewardIndex = rewardIndex,
			}, context)
		elseif grant then
			grantResult = grant(data, reward, {
				ClaimAt = claimAt,
				DayKey = claimDay,
				Streak = streak,
				RewardIndex = rewardIndex,
				Operation = context,
			})
		else
			error("Daily reward entries must be functions when no Grant callback is configured")
		end
		if retryToken ~= nil and grantResult == retryToken then
			return retryToken
		end

		state.LastClaimAt = claimAt
		state.Streak = streak
		state.BestStreak = math.max(state.BestStreak or 0, streak)
		state.TotalClaims = (state.TotalClaims or 0) + 1
		state.ClaimedDays[claimDay] = claimAt
		table.insert(state.ClaimOrder, claimDay)
		pruneClaims(state, claimLimit)

		return {
			Claimed = true,
			DayKey = claimDay,
			Streak = streak,
			RewardIndex = rewardIndex,
			GrantResult = grantResult,
		}
	end
end

function DailyRewards:GetState(session: any, now: number?): {[string]: any}
	local timestamp = now or self.Clock()
	local state = Common.read(session, self.Path, TEMPLATE)
	state.DayKey = dayKey(timestamp)
	state.CanClaim = not state.ClaimedDays[state.DayKey]
	return state
end

function DailyRewards:CanClaim(session: any, now: number?): (boolean, string?, {[string]: any})
	local state = self:GetState(session, now)
	if not state.CanClaim then
		return false, "AlreadyClaimed", state
	end
	return true, nil, state
end

function DailyRewards:ClaimAsync(session: any, userId: any, now: number?): (any?, any?)
	local claimAt = now or self.Clock()
	Common.assertTimestamp(claimAt, "ClaimAt")
	local operationId = DailyRewards.operationId(userId, claimAt)
	local queued, queueError = session:QueueOperationAsync(operationId, self.OperationType, {
		ClaimAt = claimAt,
		DayKey = dayKey(claimAt),
	})
	if not queued then
		return nil, queueError
	end
	return self.Store:AwaitOperationAsync(session.Key, operationId, self.AwaitTimeout, self.PollInterval)
end

return DailyRewards
