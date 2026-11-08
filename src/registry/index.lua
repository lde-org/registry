-- `dist/index.json`: the client-facing package list.
--
-- The generator only reads portfiles and `last-updated.json`; it never runs
-- git, so a build cannot invent a date and a shallow checkout is enough.

local json = require("registry.registry.json")
local portfile = require("registry.registry.portfile")
local metadataModule = require("registry.registry.metadata")

local M = {}

---@class registry.index.Entry
---@field name string
---@field description string?
---@field authors string[]
---@field tags string[]
---@field latest string?
---@field git string?
---@field lastUpdated string?
---@field firstPublished string?
---@field approximate boolean?

---@param pkg table
---@param meta registry.metadata.Entry?
---@return registry.index.Entry
function M.entry(pkg, meta)
	return {
		name = pkg.name,
		description = pkg.description,
		authors = type(pkg.authors) == "table" and not json.isNull(pkg.authors) and pkg.authors or {},
		tags = type(pkg.tags) == "table" and not json.isNull(pkg.tags) and pkg.tags or {},
		latest = portfile.latestVersion(pkg.versions, pkg.revoked),
		git = pkg.git,
		lastUpdated = meta and meta.lastUpdated or nil,
		firstPublished = meta and meta.firstPublished or nil,
		approximate = meta and meta.backfilled or nil,
	}
end

--- Newest first, then name. Packages without a date sort last.
---@param a registry.index.Entry
---@param b registry.index.Entry
---@return boolean
function M.compareEntries(a, b)
	local timeA = metadataModule.parseEpoch(a.lastUpdated) or 0
	local timeB = metadataModule.parseEpoch(b.lastUpdated) or 0
	if timeA ~= timeB then return timeA > timeB end
	return a.name < b.name
end

---@param entries registry.index.Entry[]
---@return registry.index.Entry[]
function M.sort(entries)
	table.sort(entries, M.compareEntries)
	return entries
end

---@param entry registry.index.Entry
---@return table
function M.encodeEntry(entry)
	local fields = {
		{ "name", entry.name },
		{ "description", entry.description or json.null },
		{ "authors", json.array(entry.authors) },
		{ "tags", json.array(entry.tags) },
		{ "latest", entry.latest or json.null },
		{ "git", entry.git },
		{ "lastUpdated", entry.lastUpdated or json.null },
		{ "firstPublished", entry.firstPublished or json.null },
	}
	if entry.approximate then
		fields[#fields + 1] = { "approximate", true }
	end
	return json.ordered(fields)
end

---@param entries { pkg: table }[]
---@param metadata table<string, registry.metadata.Entry>
---@return registry.index.Entry[]
function M.build(entries, metadata)
	local index = {}
	for _, source in ipairs(entries) do
		local pkg = source.pkg
		index[#index + 1] = M.entry(pkg, metadata[pkg.name])
	end
	return M.sort(index)
end

---@param index registry.index.Entry[]
---@return table
function M.encode(index)
	local encoded = {}
	for i, entry in ipairs(index) do
		encoded[i] = M.encodeEntry(entry)
	end
	return json.array(encoded)
end

return M
