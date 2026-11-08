-- Writes dist/index.json from the package tree and last-updated.json.
--
-- It never runs git, so it works from a shallow checkout and cannot invent a
-- date at build time.

local fs = require("fs")
local indexModule = require("registry.registry.index")
local json = require("registry.registry.json")
local metadataModule = require("registry.registry.metadata")
local portfile = require("registry.registry.portfile")

local ROOT = "."
local PACKAGES_DIR = ROOT .. "/packages"
local METADATA_FILE = ROOT .. "/last-updated.json"
local OUTPUT_DIR = ROOT .. "/dist"
local OUTPUT_FILE = OUTPUT_DIR .. "/index.json"

local entries = portfile.loadEntries(PACKAGES_DIR)
local metadata = metadataModule.read(METADATA_FILE)
local index = indexModule.build(entries, metadata)

fs.mkdirAll(OUTPUT_DIR)
assert(fs.write(OUTPUT_FILE, json.compact(indexModule.encode(index))), "could not write " .. OUTPUT_FILE)

local missing = 0
for _, entry in ipairs(index) do
	if not entry.lastUpdated then missing = missing + 1 end
end

io.stdout:write(string.format(
	"Wrote %d packages to index.json%s\n",
	#index,
	missing > 0 and string.format(" (%d without metadata - run backfill?)", missing) or ""))
