--!strict

local AutoSaveScheduler = {}

function AutoSaveScheduler.install(Store: any)
	function Store:_startAutoSave()
		local store: any = self
		task.spawn(function()
			while not store._closed do
				task.wait(store.Settings.AutoSaveCheckInterval)
				local now = os.clock()
				local availableSlots = store.Settings.AutoSaveConcurrency - store._autoSaveRunning
				if availableSlots <= 0 then
					continue
				end

				local dueSessions: {any} = {}
				for _, session in store._sessions do
					if session:IsActive() and not session._autoSaveRunning and now >= session._nextSaveAt then
						table.insert(dueSessions, session)
					end
				end
				table.sort(dueSessions, function(left: any, right: any): boolean
					return left._nextSaveAt < right._nextSaveAt
				end)

				for index = 1, math.min(availableSlots, #dueSessions) do
					local session = dueSessions[index]
					session._autoSaveRunning = true
					store._autoSaveRunning += 1
					store._metrics.PeakConcurrentAutoSaves = math.max(
						store._metrics.PeakConcurrentAutoSaves,
						store._autoSaveRunning
					)

					task.spawn(function()
						local saved, _, didWrite = session:SaveAsync("AutoSave")
						if saved and didWrite == false then
							store._metrics.AutoSavesSkipped += 1
						elseif saved then
							store._metrics.AutoSaves += 1
						elseif session:IsActive() then
							store._metrics.AutoSaveFailures += 1
							session._nextSaveAt = os.clock() + math.min(
								store.Settings.AutoSaveRetryInterval,
								store.Settings.LeaseTimeout / 3
							)
						end
						session._autoSaveRunning = false
						store._autoSaveRunning -= 1
					end)
				end
			end
		end)
	end
end

return AutoSaveScheduler
