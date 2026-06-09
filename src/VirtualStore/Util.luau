--!nonstrict

local HttpService = game:GetService("HttpService")

local Util = {}

function Util.deepCopy<T>(value: T, seen: {[any]: any}?): T
	if type(value) ~= "table" then
		return value
	end

	local visited = seen or {}
	if visited[value :: any] then
		return visited[value :: any] :: any
	end

	local copy = {}
	visited[value :: any] = copy
	for key, child in value :: any do
		copy[Util.deepCopy(key, visited)] = Util.deepCopy(child, visited)
	end
	return copy :: any
end

function Util.reconcile(target: {[any]: any}, template: {[any]: any})
	for key, templateValue in template do
		if type(key) == "string" then
			local targetValue = target[key]
			if targetValue == nil then
				target[key] = Util.deepCopy(templateValue)
			elseif type(targetValue) == "table" and type(templateValue) == "table" then
				Util.reconcile(targetValue, templateValue)
			end
		end
	end
end

function Util.deepEqual(left: any, right: any): boolean
	if type(left) ~= type(right) then
		return false
	end
	if type(left) ~= "table" then
		return left == right
	end
	for key, value in left do
		if not Util.deepEqual(value, right[key]) then
			return false
		end
	end
	for key in right do
		if left[key] == nil then
			return false
		end
	end
	return true
end

function Util.normalizePath(path: any): {any}
	if type(path) == "string" or type(path) == "number" then
		path = {path}
	end
	assert(type(path) == "table" and #path > 0, "Path must be a non-empty array")
	local result = {}
	for index, key in path do
		assert(
			type(key) == "string" or (type(key) == "number" and key >= 1 and key == math.floor(key)),
			`Path entry {index} must be a string or positive integer`
		)
		result[index] = key
	end
	return result
end

function Util.getPath(root: any, path: {any}): any
	local current = root
	for _, key in path do
		if type(current) ~= "table" then
			return nil
		end
		current = current[key]
	end
	return current
end

function Util.setPath(root: {[any]: any}, path: {any}, value: any)
	local current = root
	for index = 1, #path - 1 do
		local key = path[index]
		local child = current[key]
		if child == nil then
			child = {}
			current[key] = child
		end
		assert(type(child) == "table", `Path cannot traverse non-table entry at index {index}`)
		current = child
	end
	current[path[#path]] = value
end

local function isArray(value: {[any]: any}): boolean
	local count = 0
	local largest = 0
	for key in value do
		if type(key) ~= "number" then
			return false
		end
		count += 1
		largest = math.max(largest, key)
	end
	return count > 0 and count == largest
end

local function appendPath(path: {any}, key: any): {any}
	local result = table.clone(path)
	table.insert(result, key)
	return result
end

function Util.diff(previous: any, current: any, path: {any}?, changes: {any}?): {any}
	local output = changes or {}
	local currentPath = path or {}
	if Util.deepEqual(previous, current) then
		return output
	end
	if type(previous) ~= "table" or type(current) ~= "table" or isArray(previous) or isArray(current) then
		table.insert(output, {
			Path = table.clone(currentPath),
			Old = Util.deepCopy(previous),
			New = Util.deepCopy(current),
		})
		return output
	end
	for key, value in current do
		Util.diff(previous[key], value, appendPath(currentPath, key), output)
	end
	for key, value in previous do
		if current[key] == nil then
			table.insert(output, {
				Path = appendPath(currentPath, key),
				Old = Util.deepCopy(value),
				New = nil,
			})
		end
	end
	return output
end

function Util.changePaths(changes: {any}): {{any}}
	local paths = {}
	for _, change in changes do
		table.insert(paths, table.clone(change.Path))
	end
	return paths
end

function Util.readOnlyProxy(value: any, cache: {[any]: any}?): any
	if type(value) ~= "table" then
		return value
	end
	local proxies = cache or {}
	if proxies[value] then
		return proxies[value]
	end
	local proxy = {}
	proxies[value] = proxy
	local metatable = {
		__index = function(_self, key)
			return Util.readOnlyProxy(value[key], proxies)
		end,
		__newindex = function()
			error("StrictData session.Data is read-only; use Transaction, Set, Patch, Increment, Insert, or Remove", 2)
		end,
		__len = function()
			return #value
		end,
		__iter = function()
			local function iterator(_state, key)
				local nextKey, nextValue = next(value, key)
				return nextKey, Util.readOnlyProxy(nextValue, proxies)
			end
			return iterator, nil, nil
		end,
	}
	setmetatable(proxy, metatable)
	table.freeze(proxy)
	metatable.__metatable = "VirtualStoreStrictData"
	return proxy
end

local function validateValue(value: any, path: string, visiting: {[any]: boolean}): (boolean, string?)
	local valueType = type(value)

	if valueType == "number" then
		if value ~= value or value == math.huge or value == -math.huge then
			return false, `{path} contains a non-finite number`
		end
		return true
	end

	if valueType == "string" or valueType == "boolean" then
		return true
	end

	if valueType ~= "table" then
		return false, `{path} contains unsupported type "{valueType}"`
	end

	if visiting[value] then
		return false, `{path} contains a cyclic table reference`
	end
	visiting[value] = true

	local stringKeys = 0
	local numberKeys = 0
	local largestIndex = 0

	for key, child in value do
		local keyType = type(key)
		if keyType == "string" then
			stringKeys += 1
		elseif keyType == "number" then
			if key ~= math.floor(key) or key < 1 then
				visiting[value] = nil
				return false, `{path} contains invalid numeric key "{key}"`
			end
			numberKeys += 1
			largestIndex = math.max(largestIndex, key)
		else
			visiting[value] = nil
			return false, `{path} contains unsupported key type "{keyType}"`
		end

		local childPath = if keyType == "string" then `{path}.{key}` else `{path}[{key}]`
		local valid, message = validateValue(child, childPath, visiting)
		if not valid then
			visiting[value] = nil
			return false, message
		end
	end

	visiting[value] = nil

	if stringKeys > 0 and numberKeys > 0 then
		return false, `{path} mixes string and numeric keys`
	end
	if numberKeys > 0 and largestIndex ~= numberKeys then
		return false, `{path} is an array with gaps`
	end

	return true
end

function Util.validateData(value: any): (boolean, string?)
	if type(value) ~= "table" then
		return false, "Data must be a table"
	end
	return validateValue(value, "Data", {})
end

function Util.estimateBytes(value: any): (boolean, number | string)
	local ok, encoded = pcall(HttpService.JSONEncode, HttpService, value)
	if not ok then
		return false, tostring(encoded)
	end
	return true, #encoded
end

function Util.merge(defaults: {[string]: any}, overrides: {[string]: any}?): {[string]: any}
	local result = Util.deepCopy(defaults)
	if overrides then
		for key, value in overrides do
			result[key] = value
		end
	end
	return result
end

function Util.removeValue(values: {any}, value: any): boolean
	local index = table.find(values, value)
	if not index then
		return false
	end
	table.remove(values, index)
	return true
end

return Util
