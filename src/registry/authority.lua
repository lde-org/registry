-- `authority.json`: package/namespace owners, keyed by numeric GitHub id.
--
-- Shape:
--   namespaces: namespace -> owner ids (a namespaced package is owned by its
--               namespace owner)
--   top:        flat package name -> owner ids
--
-- The bot only ever writes a fresh single-owner array; additional owners are
-- added by editing the file directly (admins only).

local fs = require("fs")
local json = require("registry.registry.json")

local M = {}

---@return table
function M.empty()
	return { namespaces = {}, top = {} }
end

---@param value any
---@return table
local function asOwnerList(value)
	if type(value) ~= "table" then return {} end
	local owners = {}
	for _, owner in ipairs(value) do
		if type(owner) == "number" then
			owners[#owners + 1] = owner
		elseif type(owner) == "string" and tonumber(owner) then
			owners[#owners + 1] = tonumber(owner)
		end
	end
	return owners
end

---@param value any
---@return table
local function normalize(value)
	local authority = M.empty()
	if type(value) ~= "table" then return authority end
	if type(value.namespaces) == "table" then
		for namespace, owners in pairs(value.namespaces) do
			if type(namespace) == "string" then
				authority.namespaces[namespace] = asOwnerList(owners)
			end
		end
	end
	if type(value.top) == "table" then
		for name, owners in pairs(value.top) do
			if type(name) == "string" then
				authority.top[name] = asOwnerList(owners)
			end
		end
	end
	return authority
end

---@param text string
---@return table
function M.fromText(text)
	local decoded = json.decode(text)
	if type(decoded) ~= "table" then return M.empty() end
	return normalize(decoded)
end

--- A missing or unreadable file is an empty authority, matching the old bot.
---@param filePath string
---@return table
function M.load(filePath)
	local content = fs.read(filePath)
	if not content then return M.empty() end
	return M.fromText(content)
end

---@param map table<string, any>
---@return string[]
function M.sortedKeys(map)
	local keys = {}
	for key in pairs(map) do keys[#keys + 1] = key end
	table.sort(keys)
	return keys
end

---@param name string
---@return string?
function M.namespaceOf(name)
	if name:find("/", 1, true) then
		return name:match("^([^/]+)/")
	end
	return nil
end

---@param authority table
---@param name string
---@return number[]?
function M.ownersFor(authority, name)
	local namespace = M.namespaceOf(name)
	if namespace then
		return authority.namespaces[namespace]
	end
	return authority.top[name]
end

--- True when a package name already has an owner entry (directly or through
--- its namespace).
---@param authority table
---@param name string
---@return boolean
function M.isCovered(authority, name)
	local owners = M.ownersFor(authority, name)
	return owners ~= nil and #owners > 0
end

--- Assigns a fresh single-owner array. Namespaced packages own the namespace.
---@param authority table
---@param name string
---@param id number
function M.setOwner(authority, name, id)
	local namespace = M.namespaceOf(name)
	if namespace then
		authority.namespaces[namespace] = { id }
	else
		authority.top[name] = { id }
	end
end

--- Whether an owner may add co-owners to keys they already own. Only additions
--- are allowed: existing owners keep their order, keys cannot be added or
--- removed, and the actor must be in the base list of every changed key.
---@param base table
---@param head table
---@param userId number?
---@return boolean
---@return string? err
function M.canAddOwners(base, head, userId)
	if not userId then return false, "a GitHub user id is required" end

	local function sameKeys(a, b)
		local keysA = M.sortedKeys(a)
		local keysB = M.sortedKeys(b)
		if #keysA ~= #keysB then return false end
		for i = 1, #keysA do
			if keysA[i] ~= keysB[i] then return false end
		end
		return true
	end

	if not sameKeys(base.namespaces, head.namespaces) then
		return false, "namespaces cannot be added or removed"
	end
	if not sameKeys(base.top, head.top) then
		return false, "package ownership entries cannot be added or removed"
	end

	local function checkScope(scopeName, baseMap, headMap)
		for _, key in ipairs(M.sortedKeys(baseMap)) do
			local before = baseMap[key]
			local after = headMap[key]
			if type(before) ~= "table" or type(after) ~= "table" then
				return false, "invalid owner list for " .. scopeName .. " " .. key
			end
			if #after < #before then
				return false, "owners cannot be removed from " .. scopeName .. " " .. key
			end
			for i = 1, #before do
				if before[i] ~= after[i] then
					return false, "existing owners of " .. scopeName .. " " .. key
						.. " cannot be reordered or replaced"
				end
			end
			local changed = #after > #before
			if changed then
				local owns = false
				for _, owner in ipairs(before) do
					if owner == userId then owns = true break end
				end
				if not owns then
					return false, "only an owner of " .. scopeName .. " " .. key
						.. " can add owners"
				end
				local seen = {}
				for _, owner in ipairs(after) do
					if type(owner) ~= "number" then
						return false, "owner ids must be numbers"
					end
					if seen[owner] then
						return false, "duplicate owner id " .. tostring(owner)
					end
					seen[owner] = true
				end
			end
		end
		return true, nil
	end

	local ok, err = checkScope("namespace", base.namespaces, head.namespaces)
	if not ok then return false, err end
	return checkScope("package", base.top, head.top)
end

---@param map table<string, any>
---@return table
local function sortedObject(map)
	local pairsList = {}
	for _, key in ipairs(M.sortedKeys(map)) do
		pairsList[#pairsList + 1] = { key, map[key] }
	end
	return json.ordered(pairsList)
end

--- Deterministic, tab-indented JSON with a trailing newline.
---@param authority table
---@return string
function M.encode(authority)
	return json.pretty(json.ordered({
		{ "namespaces", sortedObject(authority.namespaces) },
		{ "top", sortedObject(authority.top) },
	}))
end

---@param filePath string
---@param authority table
function M.save(filePath, authority)
	assert(fs.write(filePath, M.encode(authority)), "could not write " .. filePath)
end

return M
