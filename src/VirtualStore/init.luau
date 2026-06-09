--!nonstrict

local HttpService = game:GetService("HttpService")
local MessagingService = game:GetService("MessagingService")

local DataStoreAdapter = require(script.DataStoreAdapter)
local MemoryAdapter = require(script.MemoryAdapter)
local PlayerStore = require(script.PlayerStore)
local AutoSaveScheduler = require(script.Core.AutoSaveScheduler)
local Diagnostics = require(script.Core.Diagnostics)
local MultiSession = require(script.Core.MultiSession)
local OperationLedger = require(script.Core.OperationLedger)
local PlayerFactory = require(script.Core.PlayerFactory)
local RecordCodec = require(script.Core.RecordCodec)
local SessionApi = require(script.Core.Session)
local Settings = require(script.Core.Settings)
local Shared = require(script.Core.Shared)
local StoreApi = require(script.Core.Store)
local StoreFactory = require(script.Core.StoreFactory)
local ReplicationServer = require(script.ReplicationServer)
local Signal = require(script.Signal)
local Util = require(script.Util)

local patternsModule = script:FindFirstChild("Patterns")
local loadedPatterns = nil
local orderedIndexModule = script:FindFirstChild("OrderedIndex")
local loadedOrderedIndex = nil

local function getPatterns(): any?
	if loadedPatterns == nil and patternsModule ~= nil then
		loadedPatterns = require(patternsModule)
	end
	return loadedPatterns
end

local function getOrderedIndex(): any?
	if loadedOrderedIndex == nil and orderedIndexModule ~= nil then
		loadedOrderedIndex = require(orderedIndexModule)
	end
	return loadedOrderedIndex
end

local FORMAT_VERSION = 1
local PACKAGE_VERSION = "0.1.0"

local VirtualStore = {}
local Store = {}
local Session = {}

setmetatable(VirtualStore, {
	__index = function(self, key)
		if key == "Patterns" then
			local patterns = getPatterns()
			if patterns ~= nil then
				rawset(self, key, patterns)
			end
			return patterns
		elseif key == "OrderedIndex" then
			local orderedIndex = getOrderedIndex()
			if orderedIndex ~= nil then
				rawset(self, key, orderedIndex)
			end
			return orderedIndex
		end
		return nil
	end,
})

Store.__index = Store
Session.__index = Session

VirtualStore.Version = PACKAGE_VERSION
VirtualStore.MemoryAdapter = MemoryAdapter
VirtualStore.Replicator = ReplicationServer
VirtualStore.Cancel = table.freeze({})
VirtualStore.Retry = table.freeze({})

function VirtualStore.id(prefix: string?): string
	return if prefix then `{prefix}:{HttpService:GenerateGUID(false)}` else HttpService:GenerateGUID(false)
end

local makeError = Shared.makeError
local setSessionData = Shared.setSessionData
local emitSessionChange = Shared.emitSessionChange
local leaseIsActive = Shared.leaseIsActive
local copyPublicMetadata = Shared.copyPublicMetadata
local validateOperationId = Shared.validateOperationId
local validateOperationType = Shared.validateOperationType
local copySnapshot = Shared.copySnapshot
local validateKey = Shared.validateKey

function VirtualStore.new(config: {[string]: any})
	return StoreFactory.new(config, {
		DataStoreAdapter = DataStoreAdapter,
		Game = game,
		Settings = Settings,
		Signal = Signal,
		Store = Store,
		Util = Util,
	})
end

function VirtualStore.players(config: {[string]: any})
	return PlayerFactory.players(config, {
		PlayerPatternsModule = script:FindFirstChild("PlayerPatterns"),
		PlayerStore = PlayerStore,
		Util = Util,
		VirtualStore = VirtualStore,
		getPatterns = getPatterns,
	})
end

VirtualStore.Players = VirtualStore.players

MultiSession.install(VirtualStore, {
	HttpService = HttpService,
	Util = Util,
	emitSessionChange = emitSessionChange,
	makeError = makeError,
	setSessionData = setSessionData,
})
StoreApi.install(Store, {
	FormatVersion = FORMAT_VERSION,
	HttpService = HttpService,
	MessagingService = MessagingService,
	Session = Session,
	Signal = Signal,
	Util = Util,
	VirtualStore = VirtualStore,
	copyPublicMetadata = copyPublicMetadata,
	copySnapshot = copySnapshot,
	emitSessionChange = emitSessionChange,
	leaseIsActive = leaseIsActive,
	makeError = makeError,
	setSessionData = setSessionData,
	validateKey = validateKey,
	validateOperationId = validateOperationId,
	validateOperationType = validateOperationType,
})
Diagnostics.install(Store, {
	Util = Util,
	Version = PACKAGE_VERSION,
})
AutoSaveScheduler.install(Store)
OperationLedger.install(Store, {
	Util = Util,
	VirtualStore = VirtualStore,
	makeError = makeError,
})
RecordCodec.install(Store, {
	FormatVersion = FORMAT_VERSION,
	Util = Util,
	makeError = makeError,
	copyPublicMetadata = copyPublicMetadata,
})
SessionApi.install(Session, {
	Util = Util,
	VirtualStore = VirtualStore,
	makeError = makeError,
	setSessionData = setSessionData,
	emitSessionChange = emitSessionChange,
})

return VirtualStore
