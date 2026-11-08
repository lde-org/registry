-- Version-key and version-source validation.

local M = {}

local VERSION_KEYS = {
	["commit"] = true,
	["git"] = true,
	["branch"] = true,
	["archive"] = true,
	["sha256"] = true,
	["size"] = true,
}

local COMMIT_PATTERN = "^[0-9a-f]+$"
local SHA256_PATTERN = "^[0-9a-f]+$"
local GIT_PREFIXES = { "https://", "http://", "git@", "ssh://" }

---@param version string
---@return boolean
function M.isVersionKey(version)
	return version:match("^%d+%.%d+%.%d+$") ~= nil
		or version:match("^%d+%.%d+%.%d+[%-+][%w%.%-]+$") ~= nil
end

---@param commit any
---@return boolean
function M.isCommit(commit)
	return type(commit) == "string" and #commit == 40 and commit:match(COMMIT_PATTERN) ~= nil
end

---@param url any
---@return boolean
function M.isGitUrl(url)
	if type(url) ~= "string" or url:match("%s") ~= nil then return false end
	for _, prefix in ipairs(GIT_PREFIXES) do
		if url:sub(1, #prefix) == prefix then return true end
	end
	return false
end

---@param url any
---@return boolean
function M.isArchiveUrl(url)
	return type(url) == "string" and url:match("^https?://") ~= nil and url:match("%s") == nil
end

---@param value any
---@return boolean
function M.isSha256(value)
	return type(value) == "string" and #value == 64 and value:match(SHA256_PATTERN) ~= nil
end

---@param map table<string, any>
---@return string[]
local function sortedKeys(map)
	local keys = {}
	for key in pairs(map) do keys[#keys + 1] = key end
	table.sort(keys)
	return keys
end

--- Version keys listed in a portfile's `revoked` array.
---@param revoked any
---@return table<string, boolean>
function M.revokedSet(revoked)
	local set = {}
	if type(revoked) ~= "table" then return set end
	for _, revokedVersion in ipairs(revoked) do
		if type(revokedVersion) == "string" then set[revokedVersion] = true end
	end
	return set
end

---@param value any
---@return boolean
local function isObject(value)
	if type(value) ~= "table" then return false end
	for key in pairs(value) do
		if type(key) ~= "string" then return false end
	end
	return true
end

---@param errors string[]
---@param path string
---@param message string
local function push(errors, path, message)
	errors[#errors + 1] = path .. ": " .. message
end

---@param versionValue any
---@param path string
---@param errors string[]
function M.validateValue(versionValue, path, errors)
	if type(versionValue) == "string" then
		if not M.isCommit(versionValue) then
			push(errors, path, "must be a 40-character lowercase commit hash or a source object")
		end
		return
	end

	if not isObject(versionValue) then
		push(errors, path, "must be a commit hash string or a source object")
		return
	end

	for _, key in ipairs(sortedKeys(versionValue)) do
		if not VERSION_KEYS[key] then
			push(errors, path .. "/" .. key, "must not be an additional property")
		end
	end

	if versionValue.archive ~= nil then
		if versionValue.commit ~= nil or versionValue.git ~= nil or versionValue.branch ~= nil then
			push(errors, path, "an archive version cannot also set commit, git or branch")
		end
		if not M.isArchiveUrl(versionValue.archive) then
			push(errors, path .. "/archive", "must be an http(s) URL")
		end
		if versionValue.sha256 == nil then
			push(errors, path .. "/sha256", "is required for archive versions")
		elseif not M.isSha256(versionValue.sha256) then
			push(errors, path .. "/sha256", "must be a 64-character lowercase SHA-256")
		end
		if versionValue.size ~= nil
			and (type(versionValue.size) ~= "number" or versionValue.size <= 0 or versionValue.size % 1 ~= 0) then
			push(errors, path .. "/size", "must be a positive integer")
		end
		return
	end

	local commit = versionValue.commit
	if commit == nil then
		push(errors, path .. "/commit", "is required for git versions")
	elseif not M.isCommit(commit) then
		push(errors, path .. "/commit", "must be a 40-character lowercase commit hash")
	end

	if versionValue.git ~= nil and not M.isGitUrl(versionValue.git) then
		push(errors, path .. "/git", "must be a git URL")
	end
	if versionValue.branch ~= nil and type(versionValue.branch) ~= "string" then
		push(errors, path .. "/branch", "must be a string")
	end
	if versionValue.sha256 ~= nil and not M.isSha256(versionValue.sha256) then
		push(errors, path .. "/sha256", "must be a 64-character lowercase SHA-256")
	end
end

---@param a any
---@param b any
---@return boolean
function M.versionEqual(a, b)
	if a == nil or b == nil then return a == b end
	if type(a) ~= "table" or type(b) ~= "table" then return a == b end

	for key, value in pairs(a) do
		if not M.versionEqual(value, b[key]) then return false end
	end
	for key in pairs(b) do
		if a[key] == nil then return false end
	end
	return true
end

---@param base table<string, any>?
---@param head table<string, any>?
---@return string[]
function M.overriddenVersions(base, head)
	base = base or {}
	head = head or {}
	local overridden = {}
	for _, version in ipairs(sortedKeys(base)) do
		if not M.versionEqual(base[version], head[version]) then
			overridden[#overridden + 1] = version
		end
	end
	return overridden
end

---@param base table<string, any>?
---@param head table<string, any>?
---@return string[]
function M.addedVersions(base, head)
	base = base or {}
	head = head or {}
	local added = {}
	for _, version in ipairs(sortedKeys(head)) do
		if base[version] == nil then added[#added + 1] = version end
	end
	return added
end

---@param base any
---@param head any
---@return string[]
function M.addedRevocations(base, head)
	if type(head) ~= "table" then return {} end
	local baseSet = M.revokedSet(base)
	local added = {}
	for _, revokedVersion in ipairs(head) do
		if type(revokedVersion) == "string" and not baseSet[revokedVersion] then
			added[#added + 1] = revokedVersion
		end
	end
	table.sort(added)
	return added
end

---@param base any
---@param head any
---@return string[]
function M.removedRevocations(base, head)
	if type(base) ~= "table" then return {} end
	local headSet = M.revokedSet(head)
	local removed = {}
	for _, revokedVersion in ipairs(base) do
		if type(revokedVersion) == "string" and not headSet[revokedVersion] then
			removed[#removed + 1] = revokedVersion
		end
	end
	table.sort(removed)
	return removed
end

--- True when a change only adds or removes `revoked` keys.
---@param overridden string[]
---@param added string[]
---@param revokedAdded string[]
---@param revokedRemoved string[]
---@return boolean
function M.isRevocationOnly(overridden, added, revokedAdded, revokedRemoved)
	return #overridden == 0 and #added == 0 and (#revokedAdded > 0 or #revokedRemoved > 0)
end

return M
