-- Deterministic JSON helpers.
--
-- Parsing is delegated to the `json` package. Writing is done here instead of
-- through `json.encode` so output is stable: object keys can be emitted in a
-- caller-chosen order (`ordered`) or sorted alphabetically, indentation can be
-- a tab, and an empty array stays `[]` (the JSON package has no array marker).
-- Strings are still escaped by `json.encode`.

local json = require("json")

local M = {}

M.null = json.null

---@class registry.json.Array
local arrayMt = { __name = "registry.json.Array" }

---@class registry.json.Object
local objectMt = { __name = "registry.json.Object" }

--- Marks a table as an array, including an empty one.
---@param value table?
---@return table
function M.array(value)
	return setmetatable(value or {}, arrayMt)
end

--- Marks a list of `{ key, value }` pairs as an object with that key order.
---@param pairsList table
---@return table
function M.ordered(pairsList)
	return setmetatable({ pairs = pairsList }, objectMt)
end

---@param value any
---@return boolean
function M.isNull(value)
	return value == json.null
end

local function isArray(value)
	if getmetatable(value) == arrayMt then return true end
	local count = 0
	for key in pairs(value) do
		if type(key) ~= "number" or key % 1 ~= 0 or key < 1 then return false end
		count = count + 1
	end
	if count == 0 then return false end
	for i = 1, count do
		if value[i] == nil then return false end
	end
	return true
end

--- The json package's encode appends a newline to every value; strip it when
--- using it for a key or an inline string.
---@param value string
---@return string
local function encodeString(value)
	return (json.encode(value):gsub("\n$", ""))
end

local function encodeNumber(value)
	if value ~= value or value == math.huge or value == -math.huge then
		error("cannot encode a non-finite number", 0)
	end
	if value % 1 == 0 then
		return string.format("%d", value)
	end
	return string.format("%.17g", value)
end

---@param value any
---@param opts { indent: string?, newlineAtEnd: boolean? }?
---@return string
function M.encode(value, opts)
	opts = opts or {}
	local indent = opts.indent
	local out = {}

	local function newline(level)
		if indent then
			out[#out + 1] = "\n"
			out[#out + 1] = string.rep(indent, level)
		end
	end

	local put

	---@param key string
	---@param child any
	---@param level integer
	local function putMember(key, child, level)
		out[#out + 1] = encodeString(key)
		out[#out + 1] = indent and ": " or ":"
		put(child, level)
	end

	---@param current table
	---@param level integer
	local function putObject(current, level)
		local mt = getmetatable(current)
		local keys
		if mt == objectMt then
			out[#out + 1] = "{"
			local list = current.pairs
			for i = 1, #list do
				if i > 1 then out[#out + 1] = "," end
				newline(level + 1)
				putMember(list[i][1], list[i][2], level + 1)
			end
			if #list > 0 then newline(level) end
			out[#out + 1] = "}"
			return
		end

		keys = {}
		for key in pairs(current) do
			if type(key) ~= "string" then
				error("JSON object keys must be strings, got " .. type(key), 0)
			end
			keys[#keys + 1] = key
		end
		table.sort(keys)
		out[#out + 1] = "{"
		for i = 1, #keys do
			if i > 1 then out[#out + 1] = "," end
			newline(level + 1)
			putMember(keys[i], current[keys[i]], level + 1)
		end
		if #keys > 0 then newline(level) end
		out[#out + 1] = "}"
	end

	---@param current table
	---@param level integer
	local function putArray(current, level)
		local length = 0
		for key in pairs(current) do
			if type(key) == "number" and key > length then length = key end
		end
		out[#out + 1] = "["
		for i = 1, length do
			if i > 1 then out[#out + 1] = "," end
			newline(level + 1)
			put(current[i], level + 1)
		end
		if length > 0 then newline(level) end
		out[#out + 1] = "]"
	end

	---@param current any
	---@param level integer
	function put(current, level)
		if current == nil or current == json.null then
			out[#out + 1] = "null"
		elseif type(current) == "string" then
			out[#out + 1] = encodeString(current)
		elseif type(current) == "number" then
			out[#out + 1] = encodeNumber(current)
		elseif type(current) == "boolean" then
			out[#out + 1] = current and "true" or "false"
		elseif type(current) == "table" then
			local mt = getmetatable(current)
			if mt == arrayMt or (mt ~= objectMt and isArray(current)) then
				putArray(current, level)
			else
				putObject(current, level)
			end
		else
			error("cannot encode a " .. type(current), 0)
		end
	end

	put(value, 0)
	local encoded = table.concat(out)
	if opts.newlineAtEnd then encoded = encoded .. "\n" end
	return encoded
end

--- Tab-indented JSON with a trailing newline, matching the rest of the repo.
---@param value any
---@return string
function M.pretty(value)
	return M.encode(value, { indent = "\t", newlineAtEnd = true })
end

---@param value any
---@return string
function M.compact(value)
	return M.encode(value)
end

--- Parses strict JSON into plain Lua values. `json.null` is preserved as the
--- package's null sentinel so callers can tell "missing" from "null".
---@param text string
---@return table?, string?
function M.decode(text)
	local ok, value = pcall(json.decode, text, { json5 = false })
	if not ok then
		return nil, tostring(value)
	end
	-- Older json releases return a document with `unpack`; newer ones return
	-- the materialized value directly.
	if type(value) == "table" and type(value.unpack) == "function" then
		local unpackedOk, unpacked = pcall(value.unpack, value)
		if not unpackedOk then
			return nil, tostring(unpacked)
		end
		return unpacked, nil
	end
	return value, nil
end

---@param value any
---@return boolean
function M.isArray(value)
	return type(value) == "table" and isArray(value)
end

--- Structural equality through the deterministic encoding (object key order is
--- irrelevant because plain objects are sorted).
---@param a any
---@param b any
---@return boolean
function M.equal(a, b)
	local okA, encodedA = pcall(M.encode, a)
	local okB, encodedB = pcall(M.encode, b)
	if not okA or not okB then return a == b end
	return encodedA == encodedB
end

return M
