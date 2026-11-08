local test = require("lde-test")

local metadata = require("registry.registry.metadata")

test.it("normalizes dates to UTC", function()
	test.equal(metadata.normalizeIso("2026-08-16T12:25:14+02:00"), "2026-08-16T10:25:14Z")
	test.equal(metadata.normalizeIso("2026-08-16T12:25:14Z"), "2026-08-16T12:25:14Z")
	test.equal(metadata.normalizeIso("2026-08-16T12:25:14.987Z"), "2026-08-16T12:25:14Z")
	test.equal(metadata.normalizeIso(nil), nil)
	test.equal(metadata.normalizeIso("not a date"), "not a date")
end)

test.it("never moves a date backwards", function()
	test.equal(
		metadata.laterOf("2026-08-16T00:00:00Z", "2026-08-15T00:00:00Z"),
		"2026-08-16T00:00:00Z")
	test.equal(
		metadata.laterOf("2026-08-15T00:00:00Z", "2026-08-16T00:00:00Z"),
		"2026-08-16T00:00:00Z")
	test.equal(metadata.laterOf(nil, "2026-08-16T00:00:00Z"), "2026-08-16T00:00:00Z")
	test.equal(metadata.laterOf("2026-08-16T00:00:00Z", nil), "2026-08-16T00:00:00Z")
end)

test.it("upgrades the legacy flat timestamp map", function()
	local read = metadata.fromText('{"hood":"2026-08-16T12:25:14+02:00"}')
	test.equal(read.hood.firstPublished, nil)
	test.equal(read.hood.lastUpdated, "2026-08-16T10:25:14Z")
	test.truthy(read.hood.backfilled)
end)

test.it("reads the recorded object shape", function()
	local read = metadata.fromText([[
		{"hood":{"firstPublished":"2026-08-16T00:00:00Z","lastUpdated":"2026-08-17T00:00:00Z"}}
	]])
	test.equal(read.hood.firstPublished, "2026-08-16T00:00:00Z")
	test.equal(read.hood.lastUpdated, "2026-08-17T00:00:00Z")
	test.falsy(read.hood.backfilled)
end)

test.it("writes sorted keys in the repo shape", function()
	local encoded = metadata.encode({
		zeta = { firstPublished = "2026-01-02T00:00:00Z", lastUpdated = "2026-01-02T00:00:00Z" },
		alpha = {
			firstPublished = "2026-01-01T00:00:00Z",
			lastUpdated = "2026-01-01T00:00:00Z",
			backfilled = true,
		},
	})

	test.truthy(encoded:find('"alpha"', 1, true) < encoded:find('"zeta"', 1, true))
	test.truthy(encoded:find('"firstPublished"', 1, true) < encoded:find('"lastUpdated"', 1, true))
	test.truthy(encoded:find('"lastUpdated"', 1, true) < encoded:find('"backfilled"', 1, true))
	test.includes(encoded, "\t\"alpha\": {")
	test.truthy(encoded:sub(-1) == "\n")
end)

test.it("treats a missing file as empty", function()
	test.deepEqual(metadata.read("tests/definitely-missing.json"), {})
end)
