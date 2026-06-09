--!nonstrict

local Util = require(script.Parent.Parent.Util)
local Common = require(script.Parent.Common)

local TEMPLATE = {
	Receipts = {},
	ReceiptOrder = {},
}

local PurchaseReceipts = {}
PurchaseReceipts.__index = PurchaseReceipts

local function defaultKey(playerId: number): string
	return `Player_{playerId}`
end

local function pruneReceipts(state: {[any]: any}, limit: number)
	while #state.ReceiptOrder > limit do
		local purchaseId = table.remove(state.ReceiptOrder, 1)
		state.Receipts[purchaseId] = nil
	end
end

function PurchaseReceipts.new(store: any, options: {[string]: any}?): any
	assert(store, "PurchaseReceipts needs a store")
	local config = options or {}
	return setmetatable({
		Store = store,
		Key = config.Key or defaultKey,
		Path = Common.path(config.Path, {"Purchases"}),
		Clock = config.Clock or os.time,
		OperationType = config.OperationType or "GrantDeveloperProduct",
		AwaitTimeout = config.AwaitTimeout or 20,
		PollInterval = config.PollInterval or 0.5,
	}, PurchaseReceipts)
end

function PurchaseReceipts.template(): {[any]: any}
	return {
		Receipts = {},
		ReceiptOrder = {},
	}
end

function PurchaseReceipts.operationId(purchaseId: any): string
	assert(purchaseId ~= nil, "Purchase ID is required")
	Common.assertName(tostring(purchaseId), "Purchase ID")
	return Common.operationId("purchase", purchaseId)
end

function PurchaseReceipts.operationHandler(products: {[any]: any}, options: {[string]: any}?): (({[any]: any}, {[any]: any}, {[any]: any}) -> any)
	assert(type(products) == "table", "Products must be a table keyed by ProductId")
	local config = options or {}
	local path = Common.path(config.Path, {"Purchases"})
	local receiptLimit = config.ReceiptLimit or 500
	local retryToken = config.Retry
	assert(type(receiptLimit) == "number" and receiptLimit >= 1 and receiptLimit == math.floor(receiptLimit), "ReceiptLimit must be a positive integer")

	return function(data, payload, context)
		assert(payload.PurchaseId ~= nil, "Purchase ID is required")
		local purchaseId = Common.assertName(tostring(payload.PurchaseId), "Purchase ID")
		assert(type(payload.PlayerId) == "number", "Purchase PlayerId must be a number")
		assert(type(payload.ProductId) == "number", "Purchase ProductId must be a number")
		local grantedAt = Common.assertTimestamp(payload.GrantedAt, "GrantedAt")
		local state = Common.state(data, path, TEMPLATE)
		state.Receipts = state.Receipts or {}
		state.ReceiptOrder = state.ReceiptOrder or {}

		local existing = state.Receipts[purchaseId]
		if existing then
			return {
				AlreadyGranted = true,
				PurchaseId = purchaseId,
				ProductId = existing.ProductId,
			}
		end

		local product = products[payload.ProductId]
		if type(product) ~= "function" then
			if retryToken ~= nil then
				return retryToken
			end
			error(`No developer product handler is registered for ProductId {payload.ProductId}`)
		end

		local grantResult = product(data, payload, context)
		if retryToken ~= nil and grantResult == retryToken then
			return retryToken
		end

		state.Receipts[purchaseId] = {
			ProductId = payload.ProductId,
			PlayerId = payload.PlayerId,
			GrantedAt = grantedAt,
		}
		table.insert(state.ReceiptOrder, purchaseId)
		pruneReceipts(state, receiptLimit)
		return {
			Granted = true,
			PurchaseId = purchaseId,
			ProductId = payload.ProductId,
			GrantResult = grantResult,
		}
	end
end

function PurchaseReceipts:IsGrantedAsync(playerId: number, purchaseId: any): (boolean, any?)
	assert(type(playerId) == "number", "Player ID must be a number")
	assert(purchaseId ~= nil, "Purchase ID is required")
	local snapshot, viewError = self.Store:ViewAsync(self.Key(playerId))
	if not snapshot then
		return false, viewError
	end
	local state = Util.getPath(snapshot.Data, self.Path)
	return type(state) == "table" and type(state.Receipts) == "table" and state.Receipts[tostring(purchaseId)] ~= nil, nil
end

function PurchaseReceipts:ProcessAsync(receiptInfo: {[string]: any}): (boolean, any?)
	assert(type(receiptInfo) == "table", "receiptInfo must be a table")
	assert(type(receiptInfo.PlayerId) == "number", "receiptInfo.PlayerId must be a number")
	assert(type(receiptInfo.ProductId) == "number", "receiptInfo.ProductId must be a number")
	assert(receiptInfo.PurchaseId ~= nil, "receiptInfo.PurchaseId is required")
	local purchaseId = tostring(receiptInfo.PurchaseId)
	local operationId = PurchaseReceipts.operationId(purchaseId)
	local key = self.Key(receiptInfo.PlayerId)
	local payload = {
		PurchaseId = purchaseId,
		PlayerId = receiptInfo.PlayerId,
		ProductId = receiptInfo.ProductId,
		GrantedAt = self.Clock(),
		CurrencySpent = receiptInfo.CurrencySpent,
		PlaceIdWherePurchased = receiptInfo.PlaceIdWherePurchased,
	}
	local queued, queueError = self.Store:QueueOperationAsync(key, operationId, self.OperationType, payload)
	if not queued then
		return false, queueError
	end
	local final, waitError = self.Store:AwaitOperationAsync(key, operationId, self.AwaitTimeout, self.PollInterval)
	if not final then
		return false, waitError
	end
	if final.Status ~= "Applied" then
		local alreadyGranted, grantedError = self:IsGrantedAsync(receiptInfo.PlayerId, purchaseId)
		if alreadyGranted then
			return true, final
		end
		if grantedError then
			return false, grantedError
		end
		return false, Common.error("PurchaseNotGranted", `Purchase operation finished as {final.Status}`, final)
	end
	return true, final
end

function PurchaseReceipts:Bind(marketplaceService: any, decisions: {[string]: any}?): (({[string]: any}) -> any)
	assert(marketplaceService, "MarketplaceService is required")
	local resultValues = decisions or {
		Granted = Enum.ProductPurchaseDecision.PurchaseGranted,
		Retry = Enum.ProductPurchaseDecision.NotProcessedYet,
	}
	assert(resultValues.Granted ~= nil and resultValues.Retry ~= nil, "Bind decisions must provide Granted and Retry")
	local callback = function(receiptInfo)
		local granted = self:ProcessAsync(receiptInfo)
		return if granted then resultValues.Granted else resultValues.Retry
	end
	marketplaceService.ProcessReceipt = callback
	return callback
end

return PurchaseReceipts
