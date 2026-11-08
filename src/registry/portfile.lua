-- Reading the package tree and comparing version keys.

local fs = require("fs")
local path = require("path")
local json = require("registry.registry.json")
local versionModule = require("registry.registry.version")

local M = {}

--- Every `.json` file under `packages/`, relative to it and slash-separated.
---@param packagesDir string
---@return string[]
function M.list(packagesDir)
	local files = {}

	local function walk(directory, relative)
		local iterator = fs.readdir(directory)
		if not iterator then return end
		while true do
			local entry = iterator()
			if not entry then break end
			local full = path.join(directory, entry.name)
			local rel = relative == "" and entry.name or (relative .. "/" .. entry.name)
			local isDirectory = entry.type == "dir" or (entry.type == nil and fs.isdir(full))
			if isDirectory then
				walk(full, rel)
			elseif rel:sub(-5) == ".json" then
				files[#files + 1] = rel
			end
		end
	end

	walk(packagesDir, "")
	table.sort(files)
	return files
end

--- Reads one portfile. Returns nil when the file is missing.
---@param filePath string
---@return table?, string?
function M.read(filePath)
	local content = fs.read(filePath)
	if not content then return nil, "could not read " .. filePath end
	return json.decode(content)
end

--- Every readable portfile with a string `name`, newest file order sorted by
--- path. Invalid portfiles are skipped: check-pr reports them on PRs, and the
--- metadata/index passes must not fail on a file that is being fixed.
---@param packagesDir string
---@return { path: string, pkg: table }[]
function M.loadEntries(packagesDir)
	local entries = {}
	for _, relative in ipairs(M.list(packagesDir)) do
		local pkg = M.read(path.join(packagesDir, relative))
		if type(pkg) == "table" and type(pkg.name) == "string" then
			entries[#entries + 1] = { path = relative, pkg = pkg }
		end
	end
	return entries
end

--- Package name -> portfile.
---@param packagesDir string
---@return table<string, table>
function M.loadByName(packagesDir)
	local byName = {}
	for _, entry in ipairs(M.loadEntries(packagesDir)) do
		byName[entry.pkg.name] = entry.pkg
	end
	return byName
end

---@param version string
---@return { major: integer, minor: integer, patch: integer, prerelease: string[]? }?
local function parseVersion(version)
	local major, minor, patch, rest = version:match("^(%d+)%.(%d+)%.(%d+)(.*)$")
	if not major then return nil end
	local prerelease = nil
	if rest ~= "" then
		local dash = rest:match("^%-(.+)$")
		if dash then
			prerelease = {}
			local core = dash:match("^([^%+]+)")
			for identifier in core:gmatch("[^%.]+") do
				prerelease[#prerelease + 1] = identifier
			end
		end
	end
	return {
		major = tonumber(major),
		minor = tonumber(minor),
		patch = tonumber(patch),
		prerelease = prerelease,
	}
end

---@param a string
---@param b string
---@return boolean
local function compareIdentifiers(a, b)
	local aNumber, bNumber = tonumber(a), tonumber(b)
	if aNumber and bNumber then return aNumber < bNumber end
	if aNumber then return true end
	if bNumber then return false end
	return a < b
end

--- Negative when a < b, zero when equal, positive when a > b.
---@param a string
---@param b string
---@return integer
function M.compareVersions(a, b)
	local pa, pb = parseVersion(a), parseVersion(b)
	if not pa or not pb then
		if pa then return 1 end
		if pb then return -1 end
		return a < b and -1 or (a > b and 1 or 0)
	end

	if pa.major ~= pb.major then return pa.major - pb.major end
	if pa.minor ~= pb.minor then return pa.minor - pb.minor end
	if pa.patch ~= pb.patch then return pa.patch - pb.patch end

	-- A version without a prerelease sorts after one with it.
	local preA, preB = pa.prerelease, pb.prerelease
	if not preA and not preB then return 0 end
	if not preA then return 1 end
	if not preB then return -1 end

	local length = math.max(#preA, #preB)
	for i = 1, length do
		local identifierA, identifierB = preA[i], preB[i]
		if identifierA == nil then return -1 end
		if identifierB == nil then return 1 end
		if identifierA ~= identifierB then
			return compareIdentifiers(identifierA, identifierB) and -1 or 1
		end
	end
	return 0
end

--- Highest semver key that has not been revoked, so `latest` never depends on
--- key order in the portfile.
---@param versions table<string, any>?
---@param revoked any?
---@return string?
function M.latestVersion(versions, revoked)
	if type(versions) ~= "table" then return nil end
	local revokedSet = versionModule.revokedSet(revoked)
	local keys = {}
	for key in pairs(versions) do
		if type(key) == "string" and not revokedSet[key] then keys[#keys + 1] = key end
	end
	table.sort(keys, function(a, b)
		local comparison = M.compareVersions(a, b)
		if comparison == 0 then return a > b end
		return comparison > 0
	end)
	return keys[1]
end

return M
