local test = require("lde-test")
local sha256 = require("registry.registry.sha256")

test.it("hashes the standard SHA-256 vectors", function()
	test.equal(sha256.sumhexa(""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
	test.equal(sha256.sumhexa("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
end)
