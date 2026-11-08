-- Migration: add SHA-256 content pins to existing portfile versions.
--
-- Run manually through the "Run Migration" workflow, or locally:
--   lde run scripts/2026-11-07-add-sha256.lua -- --dry-run
--
-- Git versions get the hash of the archive the client downloads (GitHub,
-- Codeberg, GitLab, Bitbucket). Archive versions get the hash of their tarball.
-- The script is idempotent: versions that already have a hash are skipped
-- unless --force is passed. It never changes a version's commit or source.

local fs = require("fs")
local path = require("path")
local process = require("process")
local json = require("json")

local portfile = require("registry.registry.portfile")
local sha256 = require("registry.registry.sha256")

local ROOT = "."
local PACKAGES_DIR = ROOT .. "/packages"

local options = {
	dryRun = false,
	force = false,
	packageName = nil,
}

local i = 1
while arg and arg[i] do
	local value = arg[i]
	if value == "--dry-run" then
		options.dryRun = true
	elseif value == "--force" then
		options.force = true
	elseif value == "--package" then
		i = i + 1
		options.packageName = arg[i]
	elseif value:sub(1, 10) == "--package=" then
		options.packageName = value:sub(11)
	elseif value == "--help" or value == "-h" then
		io.stdout:write("usage: lde run scripts/2026-11-07-add-sha256.lua -- [--dry-run] [--force] [--package <name>]\n")
		os.exit(0)
	else
		io.stderr:write("unknown option: " .. value .. "\n")
		os.exit(2)
	end
	i = i + 1
end

---@param url string
---@return string?
---@return string? err
local function download(url)
	local file = os.tmpname()
	local code, _, stderr = process.exec("curl", {
		"--fail",
		"--location",
		"--silent",
		"--show-error",
		"--retry", "2",
		"--max-time", "120",
		"--output", file,
		url,
	})
	if code ~= 0 then
		fs.delete(file)
		return nil, (stderr and stderr ~= "") and stderr or ("curl exited with " .. tostring(code))
	end
	local content = fs.read(file)
	fs.delete(file)
	if not content then return nil, "could not read the downloaded archive" end
	return sha256.sumhexa(content), nil
end

---@param url string
---@return string?
local function httpsGitUrl(url)
	local host, repo = url:match("^git@([^:]+):(.+)$")
	if host then return "https://" .. host .. "/" .. repo end
	local protoHost, protoPath = url:match("^ssh://git@([^/]+)/(.+)$")
	if protoHost then return "https://" .. protoHost .. "/" .. protoPath end
	return url
end

---@param gitUrl string
---@param commit string
---@return string?
local function tarballUrl(gitUrl, commit)
	local url = httpsGitUrl(gitUrl):gsub("/+$", ""):gsub("%.git$", "")

	local owner, repo = url:match("^https?://github%.com/([^/]+)/([^/]+)$")
	if owner then
		return "https://github.com/" .. owner .. "/" .. repo .. "/archive/" .. commit .. ".tar.gz"
	end

	owner, repo = url:match("^https?://codeberg%.org/([^/]+)/([^/]+)$")
	if owner then
		return "https://codeberg.org/" .. owner .. "/" .. repo .. "/archive/" .. commit .. ".tar.gz"
	end

	owner, repo = url:match("^https?://gitlab%.com/([^/]+)/([^/]+)$")
	if owner then
		return "https://gitlab.com/" .. owner .. "/" .. repo .. "/-/archive/" .. commit
			.. "/" .. repo .. "-" .. commit .. ".tar.gz"
	end

	owner, repo = url:match("^https?://bitbucket%.org/([^/]+)/([^/]+)$")
	if owner then
		return "https://bitbucket.org/" .. owner .. "/" .. repo .. "/get/" .. commit .. ".tar.gz"
	end

	return nil
end

---@param entry any
---@param pkg table
---@return string? kind # "git"|"archive"
---@return string? source
---@return string? commit
---@return string? existingHash
local function sourceOf(entry, pkg)
	if type(entry) == "string" then
		return "git", pkg.git, entry, nil
	end
	if type(entry) ~= "table" then return nil end
	if entry.archive then
		return "archive", entry.archive, nil, entry.sha256
	end
	return "git", entry.git or pkg.git, entry.commit, entry.sha256
end

---@param entry any
---@param hash string
local function setHash(entry, hash)
	if type(entry) == "table" then
		if entry.sha256 ~= nil then
			entry.sha256 = hash
		else
			json.addField(entry, "sha256", hash)
		end
	end
end

local updatedVersions = 0
local updatedFiles = 0
local skippedVersions = 0
local failures = 0

for _, relative in ipairs(portfile.list(PACKAGES_DIR)) do
	local file = path.join(PACKAGES_DIR, relative)
	local pkg, readErr = portfile.read(file)
	if not pkg then
		io.stderr:write("skip " .. relative .. ": " .. (readErr or "invalid portfile") .. "\n")
		failures = failures + 1
	elseif not options.packageName or pkg.name == options.packageName then
		local changed = false
		local versionKeys = {}
		for version in pairs(pkg.versions or {}) do versionKeys[#versionKeys + 1] = version end
		table.sort(versionKeys, function(a, b)
			local compared = portfile.compareVersions(a, b)
			if compared ~= 0 then return compared < 0 end
			return a < b
		end)

		for _, version in ipairs(versionKeys) do
			local entry = pkg.versions[version]
			local kind, source, commit, existingHash = sourceOf(entry, pkg)
			if not kind or not source then
				io.stderr:write("skip " .. pkg.name .. "@" .. version .. ": no usable source\n")
				failures = failures + 1
			elseif existingHash and not options.force then
				skippedVersions = skippedVersions + 1
			else
				local url
				if kind == "archive" then
					url = source
				else
					if not commit then
						io.stderr:write("skip " .. pkg.name .. "@" .. version .. ": missing commit\n")
						failures = failures + 1
						goto continue
					end
					url = tarballUrl(source, commit)
					if not url then
						io.stderr:write("skip " .. pkg.name .. "@" .. version
							.. ": host has no archive endpoint (" .. source .. ")\n")
						failures = failures + 1
						goto continue
					end
				end

				local hash, hashErr = download(url)
				if not hash then
					io.stderr:write("fail " .. pkg.name .. "@" .. version .. ": " .. (hashErr or "download failed") .. "\n")
					failures = failures + 1
					goto continue
				end

				if existingHash and existingHash == hash then
					skippedVersions = skippedVersions + 1
					goto continue
				end

				if type(entry) == "string" then
					local replacement = {}
					json.addField(replacement, "commit", entry)
					json.addField(replacement, "sha256", hash)
					pkg.versions[version] = replacement
				else
					setHash(entry, hash)
				end
				changed = true
				updatedVersions = updatedVersions + 1
				io.stdout:write(string.format("update %s@%s sha256=%s\n",
					pkg.name, version, hash))
			end
			::continue::
		end

		if changed then
			updatedFiles = updatedFiles + 1
			if not options.dryRun then
				local written = fs.write(file, json.encode(pkg))
				if not written then
					io.stderr:write("fail writing " .. file .. "\n")
					failures = failures + 1
				end
			end
		end
	end
end

io.stdout:write(string.format(
	"%s: %d version(s) in %d file(s); skipped %d; failures %d\n",
	options.dryRun and "dry-run" or "done",
	updatedVersions, updatedFiles, skippedVersions, failures))

if failures > 0 then os.exit(1) end
