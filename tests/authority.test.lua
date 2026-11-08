local test = require("lde-test")

local authority = require("registry.registry.authority")

test.it("reads namespaced ownership from the namespace", function()
	local read = authority.fromText([[
		{
			"namespaces": { "tltp": [88457139] },
			"top": { "hood": [86097860], "fs": [86097860] }
		}
	]])

	test.deepEqual(authority.ownersFor(read, "tltp/mail"), { 88457139 })
	test.deepEqual(authority.ownersFor(read, "hood"), { 86097860 })
	test.equal(authority.ownersFor(read, "missing"), nil)
end)

test.it("treats an empty owner list as uncovered", function()
	local read = authority.fromText('{"namespaces":{"tltp":[]},"top":{}}')
	test.falsy(authority.isCovered(read, "tltp/mail"))
end)

test.it("assigns namespaces for namespaced packages", function()
	local target = authority.empty()
	authority.setOwner(target, "tltp/mail", 88457139)
	authority.setOwner(target, "hood", 86097860)

	test.deepEqual(target.namespaces.tltp, { 88457139 })
	test.deepEqual(target.top.hood, { 86097860 })
end)

test.it("writes sorted namespaces and top-level keys", function()
	local target = authority.fromText([[
		{"namespaces":{"zeta":[],"alpha":[]},"top":{"zeta":[],"alpha":[]}}
	]])
	local encoded = authority.encode(target)

	test.truthy(encoded:find('"namespaces"', 1, true) < encoded:find('"top"', 1, true))
	test.truthy(encoded:find('"alpha"', 1, true) < encoded:find('"zeta"', 1, true))
	test.includes(encoded, "\t\"namespaces\": {")
end)

test.it("round-trips through save and load", function()
	local temporary = os.tmpname()
	local target = authority.fromText('{"namespaces":{"tltp":[1]},"top":{"hood":[2]}}')
	authority.save(temporary, target)

	local read = authority.load(temporary)
	os.remove(temporary)

	test.deepEqual(read.namespaces.tltp, { 1 })
	test.deepEqual(read.top.hood, { 2 })
end)

test.it("lets an owner append co-owners", function()
	local base = authority.fromText('{"namespaces":{"tltp":[1]},"top":{"hood":[2]}}')
	local head = authority.fromText('{"namespaces":{"tltp":[1,3]},"top":{"hood":[2,4]}}')

	local ok, err = authority.canAddOwners(base, head, 1)
	test.falsy(ok, err)
	local ok2, err2 = authority.canAddOwners(base, head, 2)
	test.falsy(ok2, err2)
end)

test.it("rejects owner removals, reordering and foreign keys", function()
	local base = authority.fromText('{"namespaces":{"tltp":[1]},"top":{"hood":[2]}}')

	local removed = authority.fromText('{"namespaces":{"tltp":[]},"top":{"hood":[2]}}')
	test.falsy(authority.canAddOwners(base, removed, 1))

	local reordered = authority.fromText('{"namespaces":{"tltp":[1]},"top":{"hood":[2]}}')
	reordered.top.hood = { 2, 4 }
	local ok, err = authority.canAddOwners(base, reordered, 1)
	test.falsy(ok)
	test.includes(err, "only an owner of package hood")

	local addedKey = authority.fromText('{"namespaces":{"tltp":[1]},"top":{"hood":[2],"new":[1]}}')
	test.falsy(authority.canAddOwners(base, addedKey, 1))

	local duplicate = authority.fromText('{"namespaces":{"tltp":[1,1]},"top":{"hood":[2]}}')
	test.falsy(authority.canAddOwners(base, duplicate, 1))
end)
