--!strict

local Diagnostics = {}

function Diagnostics.install(Store: any, dependencies: {
	Util: any,
	Version: string,
	})
	local Util = dependencies.Util
	local packageVersion = dependencies.Version

	function Store:_setCritical(isCritical: boolean)
		local store: any = self
		if store._critical == isCritical then
			return
		end
		store._critical = isCritical
		store.CriticalStateChanged:Fire(isCritical, store:GetDiagnostics())
	end

	function Store:_pruneIssues(now: number)
		local store: any = self
		local cutoff = now - store.Settings.CriticalWindow
		while store._issues[1] and store._issues[1].At < cutoff do
			table.remove(store._issues, 1)
		end
	end

	function Store:_emitError(virtualError: {[string]: any})
		local store: any = self
		local now = os.clock()
		virtualError.Timestamp = virtualError.Timestamp or os.time()
		table.insert(store._issues, {
			At = now,
			Code = virtualError.Code,
			Key = virtualError.Key,
		})
		store._lastIssueAt = now
		store._metrics.Failures += 1
		store._metrics.LastError = Util.deepCopy(virtualError)
		store:_pruneIssues(now)
		if store.Settings.CriticalErrorThreshold > 0 and #store._issues >= store.Settings.CriticalErrorThreshold then
			store:_setCritical(true)
		end
		store.OnError:Fire(virtualError)
	end

	function Store:_recordSuccess(operation: string, elapsed: number)
		local store: any = self
		store._metrics.Successes += 1
		store._metrics.TotalLatency += elapsed
		store._metrics.AverageLatency = store._metrics.TotalLatency / store._metrics.Successes
		store._metrics.LastLatency = elapsed
		store._metrics.LastOperation = operation
	end

	function Store:_startHealthMonitor()
		local store: any = self
		task.spawn(function()
			while not store._closed do
				task.wait(math.min(5, store.Settings.CriticalRecovery))
				local now = os.clock()
				store:_pruneIssues(now)
				if store._critical
					and store._lastIssueAt
					and now - store._lastIssueAt >= store.Settings.CriticalRecovery
				then
					store:_setCritical(false)
				end
			end
		end)
	end

	function Store:IsCritical(): boolean
		local store: any = self
		return store._critical
	end

	function Store:GetDiagnostics(): {[string]: any}
		local store: any = self
		local activeSessions = 0
		for _ in store._sessions do
			activeSessions += 1
		end
		local openingSessions = 0
		for _ in store._opening do
			openingSessions += 1
		end

		return {
			Version = packageVersion,
			Store = store._identity,
			IsCritical = store._critical,
			RecentIssueCount = #store._issues,
			ActiveSessions = activeSessions,
			OpeningSessions = openingSessions,
			AutoSaveRunning = store._autoSaveRunning,
			CloseSaveRunning = store._closeRunning,
			IsClosed = store._closed,
			Metrics = Util.deepCopy(store._metrics),
		}
	end
end

return Diagnostics
