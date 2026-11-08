local test = require("lde-test")

local schema = require("registry.registry.schema")

local COMMIT = "0123456789abcdef0123456789abcdef01234567"
local OTHER_COMMIT = "89abcdef0123456789abcdef0123456789abcdef"

---@param overrides table?
---@return table
local function portfile(overrides)
	local pkg = {
		name = "hood",
		git = "https://github.com/codebycruz/hood.git",
		versions = { ["0.1.0"] = COMMIT },
	}
	for key, value in pairs(overrides or {}) do pkg[key] = value end
	return pkg
end

test.it("accepts a minimal legacy portfile", function()
	test.deepEqual(schema.validate(portfile()), {})
end)

test.it("accepts tags", function()
	test.deepEqual(schema.validate(portfile({ tags = { "rendering", "gpu-bindings" } })), {})
end)

test.it("rejects too many tags", function()
	local tags = {}
	for i = 1, 11 do tags[i] = "tag" .. i end
	local errors = schema.validate(portfile({ tags = tags }))
	test.truthy(#errors > 0)
end)

test.it("rejects duplicate and malformed tags", function()
	local duplicate = schema.validate(portfile({ tags = { "json", "json" } }))
	test.truthy(#duplicate > 0)
	local malformed = schema.validate(portfile({ tags = { "JSON" } }))
	test.truthy(#malformed > 0)
	local tooLong = schema.validate(portfile({ tags = { string.rep("a", 33) } }))
	test.truthy(#tooLong > 0)
end)

test.it("accepts per-version source objects", function()
	test.deepEqual(schema.validate(portfile({
		versions = {
			["0.1.0"] = COMMIT,
			["0.2.0"] = {
				commit = OTHER_COMMIT,
				git = "https://github.com/lde-org/other.git",
				branch = "trunk",
			},
		},
	})), {})
end)

test.it("rejects malformed version objects", function()
	local missingCommit = schema.validate(portfile({ versions = { ["0.1.0"] = { branch = "main" } } }))
	test.truthy(#missingCommit > 0)

	local extraField = schema.validate(portfile({
		versions = { ["0.1.0"] = { commit = COMMIT, tag = "v0.1.0" } },
	}))
	test.truthy(#extraField > 0)

	local uppercase = schema.validate(portfile({ versions = { ["0.1.0"] = string.upper(COMMIT) } }))
	test.truthy(#uppercase > 0)
end)

test.it("rejects bad version keys and empty versions", function()
	test.truthy(#schema.validate(portfile({ versions = { ["1.0"] = COMMIT } })) > 0)
	test.truthy(#schema.validate(portfile({ versions = {} })) > 0)
end)

test.it("rejects unknown top-level properties", function()
	test.truthy(#schema.validate(portfile({ legacyField = true })) > 0)
end)

test.it("matches package names to file paths", function()
	test.truthy(schema.nameMatchesPath("hood", "packages/hood.json"))
	test.truthy(schema.nameMatchesPath("tltp/mail", "packages/tltp/mail.json"))
	test.falsy(schema.nameMatchesPath("hood", "packages/other.json"))
end)

test.it("rejects invalid and traversing names", function()
	test.falsy(schema.isValidName("Hood"))
	test.falsy(schema.isValidName("a-"))
	test.falsy(schema.isValidName("ab/cd"))
	test.falsy(schema.isValidName("tltp//mail"))
	test.truthy(schema.isValidName("a"))
	test.truthy(schema.isValidName("tltp/mail"))
	test.truthy(schema.namePathError("../packages/hood") ~= nil)
end)

test.it("compares version values structurally", function()
	local base = { ["0.1.0"] = { commit = COMMIT, git = "https://example.com/a.git" } }
	local head = { ["0.1.0"] = { git = "https://example.com/a.git", commit = COMMIT } }
	test.deepEqual(schema.overriddenVersions(base, head), {})
	test.deepEqual(schema.addedVersions(base, head), {})
end)

test.it("detects modified, removed and added versions", function()
	local base = { ["0.1.0"] = COMMIT, ["0.2.0"] = OTHER_COMMIT }
	local head = { ["0.1.0"] = OTHER_COMMIT, ["0.3.0"] = COMMIT }
	test.deepEqual(schema.overriddenVersions(base, head), { "0.1.0", "0.2.0" })
	test.deepEqual(schema.addedVersions(base, head), { "0.3.0" })
end)

test.it("accepts hash-pinned archive versions without a top-level git", function()
	local portfile = {
		name = "tarball",
		versions = {
			["1.0.0"] = {
				archive = "https://example.com/tarball-1.0.0.tar.gz",
				sha256 = string.rep("a", 64),
				size = 1234,
			},
		},
	}
	test.deepEqual(schema.validate(portfile), {})
end)

test.it("requires a hash for archive versions and rejects mixed sources", function()
	local missing = {
		name = "tarball",
		versions = { ["1.0.0"] = { archive = "https://example.com/tarball.tar.gz" } },
	}
	local errors = schema.validate(missing)
	test.equal(#errors, 1)
	test.includes(errors[1], "sha256")

	local mixed = {
		name = "tarball",
		git = "https://example.com/repo.git",
		versions = {
			["1.0.0"] = {
				commit = string.rep("b", 40),
				archive = "https://example.com/tarball.tar.gz",
				sha256 = string.rep("a", 64),
			},
		},
	}
	local mixedErrors = schema.validate(mixed)
	test.equal(#mixedErrors, 1)
	test.includes(mixedErrors[1], "cannot also set commit")
end)

test.it("accepts revoked versions that exist", function()
	test.deepEqual(schema.validate(portfile({
		versions = { ["0.1.0"] = COMMIT, ["0.2.0"] = OTHER_COMMIT },
		revoked = { "0.2.0" },
	})), {})
	test.deepEqual(schema.validate(portfile({ revoked = {} })), {})
end)

test.it("rejects malformed, duplicate and unknown revoked versions", function()
	test.truthy(#schema.validate(portfile({ revoked = "0.1.0" })) > 0)
	test.truthy(#schema.validate(portfile({ revoked = { "0.2.0" } })) > 0)
	test.truthy(#schema.validate(portfile({ revoked = { "0.1.0", "0.1.0" } })) > 0)
	test.truthy(#schema.validate(portfile({ revoked = { "1.0" } })) > 0)
	test.truthy(#schema.validate(portfile({ revoked = { true } })) > 0)
end)

test.it("detects added and removed revocations", function()
	test.deepEqual(schema.addedRevocations({ "0.1.0" }, { "0.2.0", "0.1.0" }), { "0.2.0" })
	test.deepEqual(schema.removedRevocations({ "0.1.0", "0.2.0" }, { "0.1.0" }), { "0.2.0" })
	test.deepEqual(schema.addedRevocations(nil, { "0.1.0" }), { "0.1.0" })
	test.deepEqual(schema.removedRevocations({ "0.1.0" }, nil), { "0.1.0" })
	test.deepEqual(schema.revokedSet({ "0.1.0" }), { ["0.1.0"] = true })
end)

test.it("allows a revocation-only change but not a no-op or version bump", function()
	test.truthy(schema.isRevocationOnly({}, {}, { "0.1.0" }, {}))
	test.truthy(schema.isRevocationOnly({}, {}, {}, { "0.1.0" }))
	test.falsy(schema.isRevocationOnly({}, {}, {}, {}))
	test.falsy(schema.isRevocationOnly({ "0.2.0" }, { "0.3.0" }, {}, {}))
end)
