-- One-off migration for packages published before the registry recorded dates.
--
-- Reconstructs firstPublished/lastUpdated from git history and flags entries
-- with `backfilled: true` (exposed as `approximate` by the index). Recorded
-- entries are left alone; `--force` recomputes them.
--
-- Run on a full clone:
--   lde run src/backfill.lua
--   lde run src/backfill.lua -- --force

local git = require("registry.registry.git")
local metadataModule = require("registry.registry.metadata")
local portfile = require("registry.registry.portfile")

local ROOT = "."
local PACKAGES_DIR = ROOT .. "/packages"
local METADATA_FILE = ROOT .. "/last-updated.json"

local force = false
for _, value in ipairs(arg or {}) do
	if value == "--force" then force = true end
end

local names = {}
for name in pairs(portfile.loadByName(PACKAGES_DIR)) do
	names[#names + 1] = name
end
table.sort(names)

local metadata = metadataModule.read(METADATA_FILE)
local changed = 0

for _, name in ipairs(names) do
	local existing = metadata[name]
	if existing and not existing.backfilled and not force then
		io.stdout:write("- ", name, ": already recorded, skipping\n")
	else
		if force then io.stdout:write("~ ", name, ": recomputing (--force)\n") end

		local added = git.firstCommit(ROOT, name)
		local modified = git.lastCommit(ROOT, name)

		local addedDate = added and added.date or nil
		local modifiedDate = modified and modified.date or addedDate

		local firstPublished = metadataModule.laterOf(existing and existing.firstPublished, addedDate)
		local lastUpdated = metadataModule.laterOf(
			firstPublished,
			metadataModule.laterOf(existing and existing.lastUpdated, modifiedDate)
		)

		local entry = {
			firstPublished = firstPublished,
			lastUpdated = metadataModule.laterOf(firstPublished, lastUpdated),
			-- Only ever true here: nothing in this file was observed live.
			backfilled = true,
		}

		metadata[name] = entry
		changed = changed + 1
		io.stdout:write("+ ", name, ": firstPublished=", tostring(entry.firstPublished),
			" lastUpdated=", tostring(entry.lastUpdated), " (approximate)\n")
	end
end

metadataModule.save(METADATA_FILE, metadata)
io.stdout:write(string.format("\nWrote %d entries to %s (%d rebuilt).\n",
	#metadataModule.sortedNames(metadata), METADATA_FILE, changed))
