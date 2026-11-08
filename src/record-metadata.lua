-- Records package owners and timing metadata after a merge.
--
-- Dates come from this repository's own history: the commit that first added a
-- portfile is the first publish, and the newest commit that touched it is the
-- last update (a portfile only changes when a version is added). Recorded
-- entries are trusted as-is, so history rewrites can never move a date
-- backwards and a hand-corrected entry is not overwritten.

local authorityModule = require("registry.registry.authority")
local git = require("registry.registry.git")
local github = require("registry.registry.github")
local json = require("registry.registry.json")
local metadataModule = require("registry.registry.metadata")
local portfile = require("registry.registry.portfile")

local function env(name)
	return os.getenv(name) or ""
end

local REPO = env("REPO")
if REPO == "" then
	io.stderr:write("Missing required env: REPO\n")
	os.exit(1)
end

local ROOT = "."
local PACKAGES_DIR = "packages"
local AUTHORITY_FILE = "authority.json"
local METADATA_FILE = "last-updated.json"

local portfiles = portfile.loadByName(PACKAGES_DIR)
local packageNames = {}
for name in pairs(portfiles) do packageNames[#packageNames + 1] = name end
table.sort(packageNames)

local authority = authorityModule.load(AUTHORITY_FILE)

-- ---- Owners ----
-- Every package without an owner entry is new since the last sync. Namespaced
-- packages are covered by their namespace, so a fresh package in a namespace
-- that already has an owner is never assigned a new one.
local missing = {}
for _, name in ipairs(packageNames) do
	if not authorityModule.isCovered(authority, name) then
		missing[#missing + 1] = name
	end
end

local authorityChanged = false

if #missing > 0 then
	io.stdout:write("Resolving owners for: ", table.concat(missing, ", "), "\n")

	for _, name in ipairs(missing) do
		-- A previous iteration may have just created this namespace.
		if authorityModule.isCovered(authority, name) then
			io.stdout:write("  ", name, " is covered by an owner recorded in this run\n")
		else
			local relative = "packages/" .. name .. ".json"
			local introducing = git.firstCommit(ROOT, name)
			if not introducing then
				io.stderr:write("Could not find introducing commit for ", name, "\n")
				os.exit(1)
			end

			local id, resolveError = github.commitAuthorId(REPO, introducing.sha)
			if not id then
				io.stderr:write("Could not resolve the GitHub id of the author of ", relative,
					" (commit ", introducing.sha, "). ", resolveError or "",
					" Record it manually in authority.json.\n")
				os.exit(1)
			end

			authorityModule.setOwner(authority, name, id)
			local namespace = authorityModule.namespaceOf(name)
			if namespace then
				io.stdout:write("  namespace ", namespace, " -> ", tostring(id), "\n")
			else
				io.stdout:write("  ", name, " -> ", tostring(id), "\n")
			end
		end
	end
	authorityChanged = true
else
	io.stdout:write("No new packages to record.\n")
end

-- ---- First published / last updated ----
local metadata = metadataModule.read(METADATA_FILE)
local metadataChanged = false

for _, name in ipairs(packageNames) do
	local stored = metadata[name]
	local recorded = stored ~= nil and not stored.backfilled

	if not recorded then
		local introduced = git.firstCommit(ROOT, name)
		local modified = git.lastCommit(ROOT, name)

		local firstPublished = metadataModule.normalizeIso(introduced and introduced.date)
		local lastUpdated = metadataModule.normalizeIso(modified and modified.date) or firstPublished

		local entry = {
			firstPublished = firstPublished,
			lastUpdated = metadataModule.laterOf(firstPublished, lastUpdated),
		}

		-- Only the first run for a package can be an estimate; later runs record
		-- a commit that was actually observed.
		if (stored and stored.backfilled) or not firstPublished or not lastUpdated then
			entry.backfilled = true
		end

		if not json.equal(stored, entry) then
			metadata[name] = entry
			metadataChanged = true
			io.stdout:write("  ", name, ": firstPublished=", tostring(entry.firstPublished),
				" lastUpdated=", tostring(entry.lastUpdated),
				entry.backfilled and " (backfilled)" or "", "\n")
		end
	end
end

-- Packages no longer in the registry don't linger in the metadata file.
for _, name in ipairs(metadataModule.sortedNames(metadata)) do
	if portfiles[name] == nil then
		metadata[name] = nil
		metadataChanged = true
		io.stdout:write("  ", name, ": removed\n")
	end
end

if authorityChanged then
	authorityModule.save(AUTHORITY_FILE, authority)
end
if metadataChanged then
	metadataModule.save(METADATA_FILE, metadata)
	io.stdout:write("Updated ", METADATA_FILE, "\n")
end

if not authorityChanged and not metadataChanged then
	io.stdout:write("No package metadata changes.\n")
	os.exit(0)
end

-- ---- Commit and push to master ----
git.add(ROOT, { AUTHORITY_FILE, METADATA_FILE })

local identity = github.resolveIdentity()
if not git.commit(ROOT, "Record package metadata (owners, first published, last updated)", identity) then
	io.stderr:write("Nothing to commit or commit failed\n")
	os.exit(0)
end

local code, stderr = git.push(ROOT, "master")
if code ~= 0 then
	io.stderr:write("Push failed. The bot token needs contents:write on master (or branch protection must allow the bot).\n")
	io.stderr:write(stderr, "\n")
	os.exit(1)
end
io.stdout:write("Pushed package metadata to master.\n")
