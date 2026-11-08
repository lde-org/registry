-- `last-updated.json`: timing metadata for every package.
--
-- Both dates come from the registry's own git history: when a package's
-- portfile was first added, and when it last changed (a portfile only changes
-- when a version is added). Nothing is read from the portfile itself.

local fs = require("fs")
local json = require("registry.registry.json")

local M = {}

---@class registry.metadata.Entry
---@field firstPublished string?
---@field lastUpdated string?
---@field backfilled boolean?

---@param value any
---@return string?
local function asString(value)
	if type(value) == "string" then return value end
	return nil
end

--- Days since 1970-01-01 for a proleptic Gregorian date (Howard Hinnant's
--- `daysFromCivil`), independent of the host timezone.
---@param year integer
---@param month integer
---@param day integer
---@return integer
local function daysFromCivil(year, month, day)
	if month <= 2 then year = year - 1 end
	local era = math.floor(year / 400)
	local yearOfEra = year - era * 400
	local dayOfYear = math.floor((153 * (month + (month > 2 and -3 or 9)) + 2) / 5) + day - 1
	local dayOfEra = yearOfEra * 365 + math.floor(yearOfEra / 4)
		- math.floor(yearOfEra / 100) + dayOfYear
	return era * 146097 + dayOfEra - 719468
end

--- Parses an ISO 8601 timestamp (with `Z` or a numeric offset) into Unix
--- seconds. Returns nil for anything unparseable.
---@param value any
---@return number?
function M.parseEpoch(value)
	if type(value) ~= "string" or value == "" then return nil end
	local year, month, day, hour, minute, second, rest =
		value:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)[Tt ](%d%d):(%d%d):(%d%d)(.*)$")
	if not year then return nil end

	local fraction
	local zone = rest
	local fractional, remainder = rest:match("^%.(%d+)(.*)$")
	if fractional then
		fraction = tonumber("0." .. fractional)
		zone = remainder
	end

	local offset = 0
	if zone ~= "" and zone ~= "Z" and zone ~= "z" then
		local sign, hours, minutes = zone:match("^([%+%-])(%d%d):?(%d%d)$")
		if not sign then return nil end
		offset = (tonumber(hours) * 60 + tonumber(minutes)) * 60
		if sign == "-" then offset = -offset end
	end

	local days = daysFromCivil(tonumber(year), tonumber(month), tonumber(day))
	return days * 86400
		+ tonumber(hour) * 3600
		+ tonumber(minute) * 60
		+ tonumber(second)
		+ (fraction or 0)
		- offset
end

--- Canonical UTC form of a date, with no fractional seconds. Unparseable input
--- passes through untouched (matching the old bot).
---@param value any
---@return string?
function M.normalizeIso(value)
	if type(value) ~= "string" or value == "" then return nil end
	local epoch = M.parseEpoch(value)
	if not epoch then return value end
	return os.date("!%Y-%m-%dT%H:%M:%SZ", math.floor(epoch))
end

--- The later of two dates, ignoring missing ones, so a recorded date can never
--- move backwards.
---@param a string?
---@param b string?
---@return string?
function M.laterOf(a, b)
	local timeA = M.parseEpoch(a)
	local timeB = M.parseEpoch(b)
	if not timeA then return M.normalizeIso(b) end
	if not timeB then return M.normalizeIso(a) end
	return M.normalizeIso(timeA >= timeB and a or b)
end

---@param value any
---@return boolean
local function isLegacyEntry(value)
	return type(value) == "string" or value == json.null or value == nil
end

---@param value any
---@return registry.metadata.Entry
local function normalizeEntry(value)
	local entry = {
		firstPublished = M.normalizeIso(asString(value.firstPublished)),
		lastUpdated = M.normalizeIso(asString(value.lastUpdated)),
	}
	if value.backfilled == true then entry.backfilled = true end
	return entry
end

--- Reads the object shape, normalizing the historical flat
--- `name -> timestamp` map so old files keep their dates.
---@param value any
---@return table<string, registry.metadata.Entry>
function M.fromValue(value)
	local metadata = {}
	if type(value) ~= "table" or json.isArray(value) then return metadata end
	for name, entry in pairs(value) do
		if type(name) == "string" then
			if isLegacyEntry(entry) then
				-- A flat timestamp map carries no firstPublished, so it is never
				-- treated as fully recorded; the migration fills the gap once.
				metadata[name] = {
					firstPublished = nil,
					lastUpdated = M.normalizeIso(asString(entry)),
					backfilled = true,
				}
			elseif type(entry) == "table" then
				metadata[name] = normalizeEntry(entry)
			end
		end
	end
	return metadata
end

---@param text string
---@return table<string, registry.metadata.Entry>
function M.fromText(text)
	local decoded = json.decode(text)
	if decoded == nil then return {} end
	return M.fromValue(decoded)
end

--- A missing or unreadable metadata file is empty: it is created on first write.
---@param filePath string
---@return table<string, registry.metadata.Entry>
function M.read(filePath)
	local content = fs.read(filePath)
	if not content then return {} end
	return M.fromText(content)
end

---@param map table<string, any>
---@return string[]
function M.sortedNames(map)
	local names = {}
	for name in pairs(map) do names[#names + 1] = name end
	table.sort(names)
	return names
end

---@param entry registry.metadata.Entry
---@return table
local function encodeEntry(entry)
	local fields = {
		{ "firstPublished", entry.firstPublished or json.null },
		{ "lastUpdated", entry.lastUpdated or json.null },
	}
	if entry.backfilled then
		fields[#fields + 1] = { "backfilled", true }
	end
	return json.ordered(fields)
end

--- Deterministic, tab-indented JSON with a trailing newline.
---@param metadata table<string, registry.metadata.Entry>
---@return string
function M.encode(metadata)
	local fields = {}
	for _, name in ipairs(M.sortedNames(metadata)) do
		fields[#fields + 1] = { name, encodeEntry(metadata[name]) }
	end
	return json.pretty(json.ordered(fields))
end

---@param filePath string
---@param metadata table<string, registry.metadata.Entry>
function M.save(filePath, metadata)
	assert(fs.write(filePath, M.encode(metadata)), "could not write " .. filePath)
end

return M
