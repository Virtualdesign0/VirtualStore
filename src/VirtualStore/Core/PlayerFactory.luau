--!nonstrict

local PlayerFactory = {}

function PlayerFactory.players(config: {[string]: any}, dependencies: {
	PlayerPatternsModule: any?,
	PlayerStore: any,
	Util: any,
	VirtualStore: any,
	getPatterns: any,
	})
	local PlayerPatternsModule = dependencies.PlayerPatternsModule
	local PlayerStore = dependencies.PlayerStore
	local Util = dependencies.Util
	local VirtualStore = dependencies.VirtualStore
	local getPatterns = dependencies.getPatterns

	assert(type(config) == "table", "VirtualStore.players expects a config table")
	local prepared = table.clone(config)
	prepared.Template = Util.deepCopy(config.Template)
	prepared.Operations = table.clone(config.Operations or {})
	prepared.Settings = table.clone(config.Settings or {})

	if prepared.Settings.StrictData == nil then
		prepared.Settings.StrictData = true
	end
	if prepared.LoadAttempts == nil then
		prepared.LoadAttempts = 5
	end
	if prepared.LoadRetryDelay == nil then
		prepared.LoadRetryDelay = 1
	end

	if config.Public ~= nil then
		assert(config.Replication == nil, "Use either Public or Replication, not both")
		assert(config.Public == true or type(config.Public) == "table", "Public must be true or an array of paths")
		prepared.Replication = if config.Public == true then true else {
			Paths = table.clone(config.Public),
		}
	end

	local configuredPatterns = config.Patterns
	if configuredPatterns ~= nil then
		assert(type(configuredPatterns) == "table", "Patterns must be a table")
		assert(getPatterns() ~= nil, "Patterns extension is not installed; add Patterns or remove Patterns from VirtualStore.players config")
		assert(
			PlayerPatternsModule ~= nil,
			"PlayerPatterns extension is not installed; add PlayerPatterns or remove Patterns from VirtualStore.players config"
		)
		prepared = require(PlayerPatternsModule).prepare(prepared, VirtualStore)
	end

	local playerStore = PlayerStore.new(prepared, VirtualStore.new)
	if prepared.Patterns ~= nil then
		require(PlayerPatternsModule).attach(playerStore, prepared.Patterns)
	end
	return playerStore
end

return PlayerFactory
