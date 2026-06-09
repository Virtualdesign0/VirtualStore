--!nonstrict

local Common = require(script.Parent.Common)

local TEMPLATE = {}

local Cooldowns = {}
Cooldowns.__index = Cooldowns

function Cooldowns.new(_store: any?, options: {[string]: any}?): any
	local config = options or {}
	return setmetatable({
		Path = Common.path(config.Path, {"Cooldowns"}),
		Clock = config.Clock or os.time,
	}, Cooldowns)
end

function Cooldowns.template(): {[any]: any}
	return {}
end

function Cooldowns:GetRemaining(session: any, name: string, now: number?): number
	Common.assertName(name, "Cooldown name")
	local timestamp = now or self.Clock()
	local state = Common.read(session, self.Path, TEMPLATE)
	local expiresAt = state[name]
	if type(expiresAt) ~= "number" then
		return 0
	end
	return math.max(0, expiresAt - timestamp)
end

function Cooldowns:IsReady(session: any, name: string, now: number?): boolean
	return self:GetRemaining(session, name, now) <= 0
end

function Cooldowns:Start(session: any, name: string, duration: number, now: number?): (boolean, any?)
	Common.assertName(name, "Cooldown name")
	Common.assertDuration(duration)
	local timestamp = now or self.Clock()
	return session:Transaction(function(data)
		local state = Common.state(data, self.Path, TEMPLATE)
		state[name] = timestamp + duration
	end, {
		Reason = "CooldownStarted",
		Source = name,
	})
end

function Cooldowns:Clear(session: any, name: string): (boolean, any?)
	Common.assertName(name, "Cooldown name")
	return session:Transaction(function(data)
		local state = Common.state(data, self.Path, TEMPLATE)
		state[name] = nil
	end, {
		Reason = "CooldownCleared",
		Source = name,
	})
end

function Cooldowns:CleanupExpired(session: any, now: number?): (boolean, any?)
	local timestamp = now or self.Clock()
	return session:Transaction(function(data)
		local state = Common.state(data, self.Path, TEMPLATE)
		for name, expiresAt in state do
			if type(expiresAt) ~= "number" or expiresAt <= timestamp then
				state[name] = nil
			end
		end
	end, {
		Reason = "CooldownsCleaned",
	})
end

return Cooldowns
