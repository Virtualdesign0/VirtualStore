--!nonstrict

local MultiSession = {}

function MultiSession.install(VirtualStore: any, dependencies: {
	HttpService: any,
	Util: any,
	emitSessionChange: any,
	makeError: any,
	setSessionData: any,
	})
	local HttpService = dependencies.HttpService
	local Util = dependencies.Util
	local emitSessionChange = dependencies.emitSessionChange
	local makeError = dependencies.makeError
	local setSessionData = dependencies.setSessionData

	function VirtualStore.withLocks(sessions: {any}, name: string, callback: ({any}) -> ...any): (boolean, ...any)
		assert(type(sessions) == "table" and #sessions > 0, "withLocks expects at least one session")
		assert(type(name) == "string" and #name > 0, "Lock name must be a non-empty string")
		assert(type(callback) == "function", "Lock callback must be a function")

		local ordered = table.clone(sessions)
		table.sort(ordered, function(left, right)
			return left.Key < right.Key
		end)
		local seen = {}
		for _, session in ordered do
			if seen[session] then
				return false, makeError("DuplicateSession", "withLocks received the same session twice", session.Key)
			end
			seen[session] = true
			if not session:IsActive() then
				return false, makeError("SessionInactive", "Cannot lock an inactive session", session.Key)
			end
			if session._locks[name] then
				return false, makeError("ResourceLocked", `Resource "{name}" is already locked`, session.Key)
			end
		end

		local owner = HttpService:GenerateGUID(false)
		for _, session in ordered do
			session._locks[name] = owner
		end
		local results = table.pack(pcall(callback, ordered))
		for _, session in ordered do
			if session._locks[name] == owner then
				session._locks[name] = nil
			end
		end
		if not results[1] then
			return false, makeError("LockCallbackFailed", `Multi-session lock callback "{name}" failed`, nil, tostring(results[2]))
		end
		return true, table.unpack(results, 2, results.n)
	end

	function VirtualStore.withLockTransactions(
		sessions: {any},
		name: string,
		callback: ({[any]: {[any]: any}}, {any}) -> any
	): (boolean, any?)
		assert(type(sessions) == "table" and #sessions > 0, "withLockTransactions expects at least one session")
		assert(type(name) == "string" and #name > 0, "Lock name must be a non-empty string")
		assert(type(callback) == "function", "Lock transaction callback must be a function")

		local ordered = table.clone(sessions)
		table.sort(ordered, function(left, right)
			return left.Key < right.Key
		end)
		local seen = {}
		for _, session in ordered do
			if seen[session] then
				return false, makeError("DuplicateSession", "withLockTransactions received the same session twice", session.Key)
			end
			seen[session] = true
			if not session:IsActive() then
				return false, makeError("SessionInactive", "Cannot transact on an inactive session", session.Key)
			end
			if session._locks[name] then
				return false, makeError("ResourceLocked", `Resource "{name}" is already locked`, session.Key)
			end
		end

		local owner = HttpService:GenerateGUID(false)
		for _, session in ordered do
			session._locks[name] = owner
		end
		for _, session in ordered do
			session:_beginOperation()
		end

		local working = {}
		local virtualError = nil
		for _, session in ordered do
			if not session:IsActive() then
				virtualError = makeError("SessionInactive", "Session became inactive before lock transaction", session.Key)
				break
			end
			working[session] = Util.deepCopy(session._data)
		end
		local callbackResult = nil
		if not virtualError then
			local callbackOk
			callbackOk, callbackResult = pcall(callback, working, ordered)
			if not callbackOk then
				virtualError = makeError("LockTransactionFailed", `Multi-session lock transaction "{name}" failed`, nil, tostring(callbackResult))
			elseif callbackResult == VirtualStore.Cancel then
				virtualError = makeError("Cancelled", `Multi-session lock transaction "{name}" was cancelled`)
			end
		end
		if not virtualError then
			for _, session in ordered do
				local validationError = session._store:_validateForSave(working[session], session._meta)
				if validationError then
					validationError.Key = session.Key
					virtualError = validationError
					break
				end
			end
			if not virtualError then
				for _, session in ordered do
					local changes = Util.diff(session._data, working[session])
					setSessionData(session, working[session])
					emitSessionChange(session, "LockTransaction", changes)
				end
			end
		end

		for index = #ordered, 1, -1 do
			ordered[index]:_endOperation()
		end
		for _, session in ordered do
			if session._locks[name] == owner then
				session._locks[name] = nil
			end
		end
		if virtualError then
			return false, virtualError
		end
		return true, callbackResult
	end
end

return MultiSession
