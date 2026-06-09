--!nonstrict

local Util = require(script.Parent.Parent.Util)
local Common = require(script.Parent.Common)

local TEMPLATE = {}
local STACK_MODES = {
	Refresh = true,
	Extend = true,
	Stack = true,
	Ignore = true,
	Replace = true,
}

local TimedEffects = {}
TimedEffects.__index = TimedEffects

local function normalizeSpec(effectId: string, spec: {[string]: any}, now: number): {[string]: any}
	Common.assertName(effectId, "Effect ID")
	assert(type(spec) == "table", "Effect spec must be a table")
	local duration = Common.assertDuration(spec.Duration or 0)
	local stackMode = spec.StackMode or "Refresh"
	assert(STACK_MODES[stackMode], `Unknown timed effect stack mode "{tostring(stackMode)}"`)
	local stacks = spec.Stacks or 1
	assert(type(stacks) == "number" and stacks >= 1 and stacks == math.floor(stacks), "Effect stacks must be a positive integer")
	local maxStacks = spec.MaxStacks
	assert(maxStacks == nil or (type(maxStacks) == "number" and maxStacks >= 1 and maxStacks == math.floor(maxStacks)), "MaxStacks must be a positive integer")

	return {
		EffectId = effectId,
		Type = spec.Type or effectId,
		Duration = duration,
		StackMode = stackMode,
		Stacks = stacks,
		MaxStacks = maxStacks,
		Source = spec.Source,
		Data = Util.deepCopy(spec.Data),
		GrantedAt = Common.assertTimestamp(spec.GrantedAt or now, "GrantedAt"),
	}
end

local function applyEffect(state: {[any]: any}, payload: {[string]: any}): {[string]: any}
	local effectId = payload.EffectId
	local grantedAt = payload.GrantedAt
	local current = state[effectId]
	local active = type(current) == "table" and type(current.ExpiresAt) == "number" and current.ExpiresAt > grantedAt
	local mode = payload.StackMode

	if active and mode == "Ignore" then
		return {
			EffectId = effectId,
			Ignored = true,
			ExpiresAt = current.ExpiresAt,
			Stacks = current.Stacks or 1,
		}
	end

	local expiresAt = grantedAt + payload.Duration
	local stacks = payload.Stacks
	if active and mode == "Refresh" then
		stacks = current.Stacks or stacks
	elseif active and mode == "Extend" then
		expiresAt = current.ExpiresAt + payload.Duration
		stacks = current.Stacks or stacks
	elseif active and mode == "Stack" then
		expiresAt = current.ExpiresAt + payload.Duration
		stacks = (current.Stacks or 1) + payload.Stacks
	end
	if payload.MaxStacks then
		stacks = math.min(stacks, payload.MaxStacks)
	end

	state[effectId] = {
		Type = payload.Type,
		ExpiresAt = expiresAt,
		Stacks = stacks,
		Source = payload.Source,
		Data = Util.deepCopy(payload.Data),
		GrantedAt = grantedAt,
	}
	return {
		EffectId = effectId,
		ExpiresAt = expiresAt,
		Stacks = stacks,
		StackMode = mode,
	}
end

function TimedEffects.new(store: any?, options: {[string]: any}?): any
	local config = options or {}
	return setmetatable({
		Store = store,
		Path = Common.path(config.Path, {"TimedEffects"}),
		Clock = config.Clock or os.time,
		OperationType = config.OperationType or "GrantTimedEffect",
		RemoveOperationType = config.RemoveOperationType or "RemoveTimedEffect",
		ExpireOperationType = config.ExpireOperationType or "ExpireTimedEffects",
		AwaitTimeout = config.AwaitTimeout or 15,
		PollInterval = config.PollInterval or 0.5,
	}, TimedEffects)
end

function TimedEffects.removeOperationHandler(options: {[string]: any}?): (({[any]: any}, {[any]: any}) -> any)
	local config = options or {}
	local path = Common.path(config.Path, {"TimedEffects"})
	return function(data, payload)
		local effectId = Common.assertName(payload.EffectId, "Effect ID")
		local state = Common.state(data, path, TEMPLATE)
		local existed = state[effectId] ~= nil
		state[effectId] = nil
		return {
			EffectId = effectId,
			Removed = existed,
		}
	end
end

function TimedEffects.expireOperationHandler(options: {[string]: any}?): (({[any]: any}, {[any]: any}) -> any)
	local config = options or {}
	local path = Common.path(config.Path, {"TimedEffects"})
	return function(data, payload)
		local at = Common.assertTimestamp(payload.At, "Expiry timestamp")
		local state = Common.state(data, path, TEMPLATE)
		local expired = 0
		for effectId, effect in state do
			if type(effect) ~= "table" or type(effect.ExpiresAt) ~= "number" or effect.ExpiresAt <= at then
				state[effectId] = nil
				expired += 1
			end
		end
		return {
			At = at,
			Expired = expired,
		}
	end
end

function TimedEffects.operationHandlers(options: {[string]: any}?): {[string]: any}
	local config = options or {}
	return {
		[config.OperationType or "GrantTimedEffect"] = TimedEffects.operationHandler(config),
		[config.RemoveOperationType or "RemoveTimedEffect"] = TimedEffects.removeOperationHandler(config),
		[config.ExpireOperationType or "ExpireTimedEffects"] = TimedEffects.expireOperationHandler(config),
	}
end

function TimedEffects.template(): {[any]: any}
	return {}
end

function TimedEffects.operationHandler(options: {[string]: any}?): (({[any]: any}, {[any]: any}) -> any)
	local config = options or {}
	local path = Common.path(config.Path, {"TimedEffects"})
	return function(data, payload)
		local normalized = normalizeSpec(payload.EffectId, payload, payload.GrantedAt)
		local state = Common.state(data, path, TEMPLATE)
		return applyEffect(state, normalized)
	end
end

function TimedEffects:Get(session: any, effectId: string, now: number?): any?
	Common.assertName(effectId, "Effect ID")
	local timestamp = now or self.Clock()
	local state = Common.read(session, self.Path, TEMPLATE)
	local effect = state[effectId]
	if type(effect) ~= "table" or type(effect.ExpiresAt) ~= "number" or effect.ExpiresAt <= timestamp then
		return nil
	end
	return Util.deepCopy(effect)
end

function TimedEffects:Has(session: any, effectId: string, now: number?): boolean
	return self:Get(session, effectId, now) ~= nil
end

function TimedEffects:GetRemaining(session: any, effectId: string, now: number?): number
	local timestamp = now or self.Clock()
	local effect = self:Get(session, effectId, timestamp)
	return if effect then math.max(0, effect.ExpiresAt - timestamp) else 0
end

function TimedEffects:Grant(session: any, effectId: string, spec: {[string]: any}): (boolean, any?)
	local payload = normalizeSpec(effectId, spec, self.Clock())
	return session:Transaction(function(data)
		local state = Common.state(data, self.Path, TEMPLATE)
		applyEffect(state, payload)
	end, {
		Reason = "TimedEffectGranted",
		Source = effectId,
	})
end

function TimedEffects:QueueGrantAsync(target: any, operationId: string, effectId: string, spec: {[string]: any}, awaitResult: boolean?): (any?, any?)
	assert(self.Store, "TimedEffects needs a store to queue operations")
	Common.assertName(operationId, "Operation ID")
	local payload = normalizeSpec(effectId, spec, self.Clock())
	local queued, queueError = Common.queue(self.Store, target, operationId, self.OperationType, payload)
	if not queued or not awaitResult then
		return queued, queueError
	end
	return Common.await(self.Store, target, operationId, self.AwaitTimeout, self.PollInterval)
end

function TimedEffects:QueueRemoveAsync(target: any, operationId: string, effectId: string, awaitResult: boolean?): (any?, any?)
	assert(self.Store, "TimedEffects needs a store to queue operations")
	Common.assertName(operationId, "Operation ID")
	Common.assertName(effectId, "Effect ID")
	local queued, queueError = Common.queue(self.Store, target, operationId, self.RemoveOperationType, {
		EffectId = effectId,
	})
	if not queued or not awaitResult then
		return queued, queueError
	end
	return Common.await(self.Store, target, operationId, self.AwaitTimeout, self.PollInterval)
end

function TimedEffects:QueueCleanupAsync(target: any, operationId: string, at: number?, awaitResult: boolean?): (any?, any?)
	assert(self.Store, "TimedEffects needs a store to queue operations")
	Common.assertName(operationId, "Operation ID")
	local timestamp = Common.assertTimestamp(at or self.Clock(), "Expiry timestamp")
	local queued, queueError = Common.queue(self.Store, target, operationId, self.ExpireOperationType, {
		At = timestamp,
	})
	if not queued or not awaitResult then
		return queued, queueError
	end
	return Common.await(self.Store, target, operationId, self.AwaitTimeout, self.PollInterval)
end

function TimedEffects:Remove(session: any, effectId: string): (boolean, any?)
	Common.assertName(effectId, "Effect ID")
	return session:Transaction(function(data)
		local state = Common.state(data, self.Path, TEMPLATE)
		state[effectId] = nil
	end, {
		Reason = "TimedEffectRemoved",
		Source = effectId,
	})
end

function TimedEffects:CleanupExpired(session: any, now: number?): (boolean, any?)
	local timestamp = now or self.Clock()
	return session:Transaction(function(data)
		local state = Common.state(data, self.Path, TEMPLATE)
		for effectId, effect in state do
			if type(effect) ~= "table" or type(effect.ExpiresAt) ~= "number" or effect.ExpiresAt <= timestamp then
				state[effectId] = nil
			end
		end
	end, {
		Reason = "TimedEffectsCleaned",
	})
end

return TimedEffects
