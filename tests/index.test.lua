local test = require("lde-test")

local index = require("registry.registry.index")
local json = require("registry.registry.json")
local portfile = require("registry.registry.portfile")

local COMMIT = "0123456789abcdef0123456789abcdef01234567"

---@param name string
---@param overrides table?
---@return table
local function entry(name, overrides)
	local pkg = {
		name = name,
		git = "https://example.com/" .. name .. ".git",
		versions = { ["0.1.0"] = COMMIT },
	}
	for key, value in pairs(overrides or {}) do pkg[key] = value end
	return { pkg = pkg }
end

test.it("picks the highest semver, ignoring key order", function()
	test.equal(portfile.latestVersion({
		["1.10.0"] = COMMIT,
		["1.2.0"] = COMMIT,
		["1.9.0"] = COMMIT,
	}), "1.10.0")

	test.equal(portfile.latestVersion({
		["1.0.0"] = COMMIT,
		["1.0.0-rc.1"] = COMMIT,
	}), "1.0.0")

	test.equal(portfile.latestVersion({
		["2.0.0-rc.1"] = COMMIT,
		["1.99.0"] = COMMIT,
	}), "2.0.0-rc.1")

	test.equal(portfile.latestVersion(nil), nil)
end)

test.it("skips revoked versions when picking the latest", function()
	test.equal(portfile.latestVersion({
		["1.0.0"] = COMMIT,
		["0.9.0"] = COMMIT,
	}, { "1.0.0" }), "0.9.0")

	test.equal(portfile.latestVersion({
		["1.0.0"] = COMMIT,
		["1.0.0-rc.1"] = COMMIT,
	}, { "1.0.0" }), "1.0.0-rc.1")

	test.equal(portfile.latestVersion({ ["1.0.0"] = COMMIT }, { "1.0.0" }), nil)
end)

test.it("uses the highest unrevoked version in the index", function()
	local built = index.build({
		entry("hood", {
			versions = { ["0.1.0"] = COMMIT, ["0.2.0"] = COMMIT },
			revoked = { "0.2.0" },
		}),
	}, {})

	test.equal(built[1].latest, "0.1.0")
end)

test.it("encodes a fully revoked package with a null latest", function()
	local built = index.build({
		entry("hood", { revoked = { "0.1.0" } }),
	}, {})
	test.includes(json.compact(index.encode(built)), '"latest":null')
end)

test.it("includes tags and the latest version", function()
	local built = index.build({
		entry("hood", { tags = { "rendering" }, versions = { ["0.1.0"] = COMMIT, ["0.2.0"] = COMMIT } }),
	}, {})

	test.equal(built[1].name, "hood")
	test.equal(built[1].latest, "0.2.0")
	test.deepEqual(built[1].tags, { "rendering" })
	test.deepEqual(built[1].authors, {})
end)

test.it("sorts newest first then by name", function()
	local built = index.build({
		entry("older"),
		entry("zebra"),
		entry("newest"),
		entry("alpha"),
	}, {
		older = { lastUpdated = "2026-01-01T00:00:00Z" },
		zebra = { lastUpdated = "2026-03-01T00:00:00Z" },
		newest = { lastUpdated = "2026-05-01T00:00:00Z" },
		alpha = { lastUpdated = "2026-03-01T00:00:00Z" },
	})

	test.equal(built[1].name, "newest")
	test.equal(built[2].name, "alpha")
	test.equal(built[3].name, "zebra")
	test.equal(built[4].name, "older")
end)

test.it("sorts packages without metadata last", function()
	local built = index.build({ entry("dated"), entry("undated") }, {
		dated = { lastUpdated = "2026-01-01T00:00:00Z" },
	})
	test.equal(built[1].name, "dated")
	test.equal(built[2].name, "undated")
	test.equal(built[2].lastUpdated, nil)
end)

test.it("marks backfilled dates as approximate", function()
	local built = index.build({ entry("hood") }, {
		hood = {
			firstPublished = "2026-01-01T00:00:00Z",
			lastUpdated = "2026-02-01T00:00:00Z",
			backfilled = true,
		},
	})
	test.truthy(built[1].approximate)
end)

test.it("encodes missing values as null and empty lists as arrays", function()
	local built = index.build({ entry("hood") }, {})
	local encoded = json.compact(index.encode(built))
	test.includes(encoded, '"description":null')
	test.includes(encoded, '"authors":[]')
	test.includes(encoded, '"tags":[]')
	test.includes(encoded, '"firstPublished":null')
	test.falsy(encoded:find('"approximate"', 1, true))
end)

test.it("encodes an archive-only package with a null git URL", function()
	local built = index.build({
		{ pkg = {
			name = "tarball",
			versions = {
				["1.0.0"] = {
					archive = "https://example.com/tarball.tar.gz",
					sha256 = string.rep("a", 64),
				},
			},
		} },
	}, {})
	local encoded = index.encode(built)
	local decoded = json.decode(json.encode(encoded))
	test.equal(decoded[1].name, "tarball")
	test.equal(decoded[1].git, json.null)
end)
