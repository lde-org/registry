-- Portfile validation and name/path rules. Version-source checks live in version.lua.
--
-- This mirrors `schemas/registry.schema.json` (kept in JSON for editors and for
-- documentation); the workflow validates with Lua only because the checks run
-- inside the lde runtime. Keep the two in sync when either changes.

local json = require("registry.registry.json")
local version = require("registry.registry.version")

local M = {}

local MAX_NAME_LENGTH = 128
local MAX_TAGS = 10
local MAX_TAG_LENGTH = 32

local TOP_LEVEL_KEYS = {
	["name"] = true,
	["description"] = true,
	["license"] = true,
	["authors"] = true,
	["tags"] = true,
	["git"] = true,
	["branch"] = true,
	["versions"] = true,
	["dependencies"] = true,
	["revoked"] = true,
}

--- A package name is `pkg` or `namespace/pkg`; both segments start with a
--- lowercase letter, contain only `a-z0-9_-`, and end with a letter or digit.
--- A namespace is exactly one level deep and at least three characters, and
--- the whole name is at most 128 characters.
---@param name string
---@return boolean
function M.isValidName(name)
	if type(name) ~= "string" or name == "" or #name > MAX_NAME_LENGTH then
		return false
	end

	local namespace, package
	if name:find("/", 1, true) then
		namespace, package = name:match("^([^/]+)/([^/]+)$")
		if not namespace then return false end
	else
		package = name
	end

	if not package:match("^[a-z]$") and not package:match("^[a-z][a-z0-9_%-]*[a-z0-9]$") then
		return false
	end

	if namespace then
		if #namespace < 3 then return false end
		if not namespace:match("^[a-z][a-z0-9_%-]+[a-z0-9]$") then return false end
	end

	return true
end

---@param tag string
---@return boolean
function M.isTag(tag)
	return #tag <= MAX_TAG_LENGTH and tag:match("^[a-z][a-z0-9%-]*$") ~= nil
end

---@param name string
---@param path string
---@return boolean
function M.nameMatchesPath(name, path)
	return "packages/" .. name .. ".json" == path
end

--- Errors for a package name that cannot be used to build a path.
---@param name any
---@return string?
function M.namePathError(name)
	if type(name) ~= "string" then return nil end
	if name:find("..", 1, true) then
		return "package `name` (`" .. name .. "`) is not a valid package name."
	end
	if name:sub(1, 1) == "/" or name:sub(-1) == "/" then
		return "package `name` (`" .. name .. "`) is not a valid package name."
	end
	for segment in (name .. "/"):gmatch("([^/]*)/") do
		if segment == "" then
			return "package `name` (`" .. name .. "`) is not a valid package name."
		end
	end
	return nil
end

---@param map table<string, any>
---@return string[]
local function sortedKeys(map)
	local keys = {}
	for key in pairs(map) do keys[#keys + 1] = key end
	table.sort(keys)
	return keys
end

---@param value any
---@return boolean
local function isObject(value)
	if type(value) ~= "table" or value == json.null then return false end
	for key in pairs(value) do
		if type(key) ~= "string" then return false end
	end
	return true
end

---@param value any
---@return boolean
local function isList(value)
	if type(value) ~= "table" or value == json.null then return false end
	local count = 0
	for key in pairs(value) do
		if type(key) ~= "number" or key % 1 ~= 0 or key < 1 then return false end
		count = count + 1
	end
	for i = 1, count do
		if value[i] == nil then return false end
	end
	return true
end

---@param errors string[]
---@param path string
---@param message string
local function push(errors, path, message)
	errors[#errors + 1] = path .. ": " .. message
end

--- Validates a decoded portfile. Returns a list of errors, empty when valid.
---@param pkg any
---@return string[]
function M.validate(pkg)
	local errors = {}
	if not isObject(pkg) then
		return { "/: must be an object" }
	end

	for _, key in ipairs(sortedKeys(pkg)) do
		if not TOP_LEVEL_KEYS[key] then
			push(errors, "/" .. key, "must not be an additional property")
		end
	end

	if pkg.name == nil then
		push(errors, "/name", "is required")
	elseif type(pkg.name) ~= "string" then
		push(errors, "/name", "must be a string")
	elseif not M.isValidName(pkg.name) then
		push(errors, "/name", "must be a valid package name of at most 128 characters")
	end

	if pkg.description ~= nil and type(pkg.description) ~= "string" then
		push(errors, "/description", "must be a string")
	end
	if pkg.license ~= nil and type(pkg.license) ~= "string" then
		push(errors, "/license", "must be a string")
	end

	if pkg.authors ~= nil then
		if not isList(pkg.authors) then
			push(errors, "/authors", "must be an array")
		else
			for i, author in ipairs(pkg.authors) do
				if type(author) ~= "string" then
					push(errors, "/authors/" .. (i - 1), "must be a string")
				end
			end
		end
	end

	if pkg.tags ~= nil then
		if not isList(pkg.tags) then
			push(errors, "/tags", "must be an array")
		else
			if #pkg.tags > MAX_TAGS then
				push(errors, "/tags", "must not have more than " .. MAX_TAGS .. " items")
			end
			local seen = {}
			for i, tag in ipairs(pkg.tags) do
				local path = "/tags/" .. (i - 1)
				if type(tag) ~= "string" then
					push(errors, path, "must be a string")
				else
					if not M.isTag(tag) then
						push(errors, path, "must match ^[a-z][a-z0-9-]{0,31}$")
					end
					if seen[tag] then
						push(errors, path, "must be unique")
					end
					seen[tag] = true
				end
			end
		end
	end

	if pkg.git ~= nil and not M.isGitUrl(pkg.git) then
		push(errors, "/git", "must be a git URL (https://, http://, git@ or ssh://)")
	end

	if pkg.branch ~= nil and type(pkg.branch) ~= "string" then
		push(errors, "/branch", "must be a string")
	end

	if pkg.versions == nil then
		push(errors, "/versions", "is required")
	elseif not isObject(pkg.versions) then
		push(errors, "/versions", "must be an object")
	else
		local keys = sortedKeys(pkg.versions)
		if #keys == 0 then
			push(errors, "/versions", "must have at least one property")
		end
		for _, versionKey in ipairs(keys) do
			local path = "/versions/" .. versionKey
			if not version.isVersionKey(versionKey) then
				push(errors, "/versions/" .. versionKey, "must be a semver version (X.Y.Z)")
			end
			version.validateValue(pkg.versions[versionKey], path, errors)
		end
	end

	if pkg.revoked ~= nil then
		if not isList(pkg.revoked) then
			push(errors, "/revoked", "must be an array")
		else
			local seen = {}
			local versions = isObject(pkg.versions) and pkg.versions or nil
			for i, revokedVersion in ipairs(pkg.revoked) do
				local revokedPath = "/revoked/" .. (i - 1)
				if type(revokedVersion) ~= "string" then
					push(errors, revokedPath, "must be a string")
				else
					if not version.isVersionKey(revokedVersion) then
						push(errors, revokedPath, "must be a semver version (X.Y.Z)")
					elseif versions and versions[revokedVersion] == nil then
						push(errors, revokedPath, "must name a version in /versions")
					end
					if seen[revokedVersion] then
						push(errors, revokedPath, "must be unique")
					end
					seen[revokedVersion] = true
				end
			end
		end
	end

	if pkg.git == nil then
		if type(pkg.versions) == "table" then
			for version, value in pairs(pkg.versions) do
				if type(value) ~= "table" or value.archive == nil then
					push(errors, "/versions/" .. version,
						"must be an archive source when the portfile has no top-level git URL")
				end
			end
		end
	end

	if pkg.dependencies ~= nil then
		if not isObject(pkg.dependencies) then
			push(errors, "/dependencies", "must be an object")
		else
			for _, dependency in ipairs(sortedKeys(pkg.dependencies)) do
				if type(pkg.dependencies[dependency]) ~= "string" then
					push(errors, "/dependencies/" .. dependency, "must be a string")
				end
			end
		end
	end

	return errors
end

M.isVersionKey = version.isVersionKey
M.isCommit = version.isCommit
M.isGitUrl = version.isGitUrl
M.isArchiveUrl = version.isArchiveUrl
M.isSha256 = version.isSha256
M.versionEqual = version.versionEqual
M.overriddenVersions = version.overriddenVersions
M.addedVersions = version.addedVersions
M.revokedSet = version.revokedSet
M.addedRevocations = version.addedRevocations
M.removedRevocations = version.removedRevocations
M.isRevocationOnly = version.isRevocationOnly

return M
