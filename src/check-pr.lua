-- Pull request validation.
--
-- Runs on `pull_request_target` with the BASE revision checked out. Package
-- files from the PR are only read with `git show`; PR code is never executed.

local fs = require("fs")
local authorityModule = require("registry.registry.authority")
local git = require("registry.registry.git")
local github = require("registry.registry.github")
local json = require("registry.registry.json")
local schema = require("registry.registry.schema")

local function env(name)
	return os.getenv(name) or ""
end

local BASE_SHA = env("BASE_SHA")
local HEAD_SHA = env("HEAD_SHA")
local AUTHOR_ID = env("PR_AUTHOR_ID")
local AUTHOR_LOGIN = env("PR_AUTHOR_LOGIN")
local AUTHOR_ASSOCIATION = env("PR_AUTHOR_ASSOCIATION")
local REPO = env("REPO")

if BASE_SHA == "" or HEAD_SHA == "" or AUTHOR_ID == "" or REPO == "" then
	io.stderr:write("Missing required env: BASE_SHA, HEAD_SHA, PR_AUTHOR_ID, REPO\n")
	os.exit(1)
end

local ROOT = "."

local authorId = tonumber(AUTHOR_ID)

local isAdmin = github.isAdmin(REPO, AUTHOR_ASSOCIATION, AUTHOR_LOGIN)

---@param sha string
---@param filePath string
---@return table?
local function showJson(sha, filePath)
	local content = git.show(ROOT, sha, filePath)
	if not content then return nil end
	local decoded = json.decode(content)
	if type(decoded) ~= "table" then return nil end
	return decoded
end

-- Authority comes from the base ref only, never from the PR.
local authority = { namespaces = {}, top = {} }
local authorityContent = git.show(ROOT, BASE_SHA, "authority.json")
if authorityContent then
	local decoded = json.decode(authorityContent)
	if type(decoded) == "table" then
		if type(decoded.namespaces) == "table" then authority.namespaces = decoded.namespaces end
		if type(decoded.top) == "table" then authority.top = decoded.top end
	end
end

---@param name string
---@return number[]?
local function ownersFor(name)
	local namespace = name:match("^([^/]+)/")
	if namespace then return authority.namespaces[namespace] end
	return authority.top[name]
end

---@param owners number[]?
---@param id number?
---@return boolean
local function owns(owners, id)
	if not owners or not id then return false end
	for _, owner in ipairs(owners) do
		if owner == id then return true end
	end
	return false
end

---@param names string[]
---@return string
local function quoted(names)
	local parts = {}
	for i, name in ipairs(names) do parts[i] = "`" .. name .. "`" end
	return table.concat(parts, ", ")
end

local issues = {} -- close-level
local errors = {} -- request-changes-level (schema)
local touchedAuthorityFile = false
local touchedMetadataFile = false
local hasNewPackage = false
local hasModifiedPackage = false

local changes = git.parseNameStatus(git.diffNameStatus(ROOT, BASE_SHA, HEAD_SHA))

for _, change in ipairs(changes) do
	local path, status = change.path, change.status

	if status == "R" and path:sub(1, 9) == "packages/" then
		issues[#issues + 1] = string.format(
			"`%s`: package cannot be renamed (`%s` -> `%s`).", path,
			tostring(change.oldPath), path)

	elseif path == "authority.json" then
		touchedAuthorityFile = true
		if not isAdmin then
			local headContent = git.show(ROOT, HEAD_SHA, "authority.json")
			if not headContent then
				issues[#issues + 1] = "`authority.json` cannot be deleted."
			else
				local headAuthority = authorityModule.fromText(headContent)
				local allowed, reason =
					authorityModule.canAddOwners(authority, headAuthority, authorId)
				if not allowed then
					issues[#issues + 1] = "`authority.json`: " .. tostring(reason)
						.. ". Only repository admins can make other ownership changes."
				end
			end
		end

	elseif path == "last-updated.json" then
		touchedMetadataFile = true
		if not isAdmin then
			issues[#issues + 1] = "`last-updated.json` can only be modified by repository admins."
		end

	elseif path:sub(1, 9) == "packages/" and path:sub(-5) == ".json" then
		local baseContent = status ~= "A" and git.show(ROOT, BASE_SHA, path) or nil
		local headContent = status ~= "D" and git.show(ROOT, HEAD_SHA, path) or nil

		if status == "D" then
			if baseContent then
				local pkg = json.decode(baseContent)
				if type(pkg) == "table" then
					local name = type(pkg.name) == "string" and pkg.name or ""
					local owners = ownersFor(name)
					if not owners or #owners == 0 then
						issues[#issues + 1] = string.format(
							"`%s`: package `%s` has no recorded owner.", path, name)
					elseif not owns(owners, authorId) and not isAdmin then
						issues[#issues + 1] = string.format(
							"`%s`: only the package owner (GitHub id %s) or a repo admin may delete `%s`.",
							path, table.concat(owners, ", "), name)
					end
				end
			end

		elseif headContent then
			local pkg, decodeError = json.decode(headContent)
			if type(pkg) ~= "table" then
				errors[#errors + 1] = string.format("`%s`: invalid JSON (%s)", path, decodeError or "not an object")
			else
				for _, validationError in ipairs(schema.validate(pkg)) do
					errors[#errors + 1] = string.format("`%s`%s", path, validationError)
				end

				local name = type(pkg.name) == "string" and pkg.name or nil
				if name then
					if not schema.nameMatchesPath(name, path) then
						errors[#errors + 1] = string.format(
							"`%s`: package `name` (`%s`) must match the filename.", path, name)
					end
					local pathError = schema.namePathError(name)
					if pathError then
						errors[#errors + 1] = string.format("`%s`: %s", path, pathError)
					end
				end

				-- New package: claimable by the author (recorded after merge).
				if status == "A" then
					hasNewPackage = true

				else
					hasModifiedPackage = true

					local basePkg = baseContent and json.decode(baseContent) or nil
					if type(basePkg) == "table" then
						local baseName = type(basePkg.name) == "string" and basePkg.name or nil
						if baseName and baseName ~= name then
							issues[#issues + 1] = string.format(
								"`%s`: package cannot be renamed (`%s` -> `%s`).", path, baseName,
								tostring(name))
						end

						local owners = baseName and ownersFor(baseName) or nil
						if not owners or #owners == 0 then
							issues[#issues + 1] = string.format(
								"`%s`: package `%s` has no recorded owner; a repo admin needs to add it to authority.json.",
								path, tostring(baseName))
						elseif not owns(owners, authorId) and not isAdmin then
							issues[#issues + 1] = string.format(
								"`%s`: `%s` is owned by GitHub id(s) %s; only the owner or a repo admin may modify it (you are id %s).",
								path, tostring(baseName), table.concat(owners, ", "), AUTHOR_ID)
						end

						-- Base versions must be untouched. An update adds exactly
						-- one version; a revocation-only change may add none.
						local overridden = schema.overriddenVersions(basePkg.versions, pkg.versions)
						local added = schema.addedVersions(basePkg.versions, pkg.versions)
						local revokedAdded = schema.addedRevocations(basePkg.revoked, pkg.revoked)
						local revokedRemoved = schema.removedRevocations(basePkg.revoked, pkg.revoked)

						if #overridden > 0 then
							issues[#issues + 1] = string.format(
								"`%s`: existing versions must not be modified or removed (%s).",
								path, quoted(overridden))
						end

						if #revokedRemoved > 0 and not isAdmin then
							issues[#issues + 1] = string.format(
								"`%s`: only a repo admin may un-revoke versions (%s).",
								path, quoted(revokedRemoved))
						end

						local revocationOnly = schema.isRevocationOnly(
							overridden, added, revokedAdded, revokedRemoved)
						if #added ~= 1 and not revocationOnly then
							issues[#issues + 1] = string.format(
								"`%s`: updates must add exactly one new version (found %d).",
								path, #added)
						end
					elseif baseContent then
						errors[#errors + 1] = string.format("`%s`: base portfile is not valid JSON", path)
					end
				end
			end
		end
	end
end

local verdict
if #issues > 0 then
	verdict = "close"
elseif #errors > 0 then
	verdict = "request-changes"
elseif hasNewPackage or touchedAuthorityFile or touchedMetadataFile then
	verdict = "approve"
elseif hasModifiedPackage then
	verdict = "approve-merge"
else
	verdict = "approve"
end

local comment = {}
if verdict == "close" then
	comment[#comment + 1] = "This pull request was closed automatically."
	comment[#comment + 1] = ""
	comment[#comment + 1] = "**Reasons:**"
	for _, issue in ipairs(issues) do
		comment[#comment + 1] = "- " .. issue
	end
	comment[#comment + 1] = ""
	comment[#comment + 1] = "Only the recorded package owner (or a repo admin) may modify an existing package."
elseif verdict == "request-changes" then
	comment[#comment + 1] = "This pull request needs changes before it can be merged."
	comment[#comment + 1] = ""
	comment[#comment + 1] = "**Errors:**"
	for _, validationError in ipairs(errors) do
		comment[#comment + 1] = "- " .. validationError
	end
elseif verdict == "approve" then
	comment[#comment + 1] =
		"Package validated. A maintainer will review and merge this PR; ownership is recorded after merge."
else
	comment[#comment + 1] = "Package update validated. Approved and merged automatically."
end

local body = table.concat(comment, "\n")

local commentFile = env("COMMENT_FILE")
if commentFile ~= "" then
	fs.write(commentFile, body)
else
	io.stdout:write(body, "\n")
end

local outputFile = env("GITHUB_OUTPUT")
if outputFile ~= "" then
	local handle = assert(io.open(outputFile, "a"))
	handle:write("verdict=", verdict, "\n")
	handle:close()
end

io.stdout:write("verdict=", verdict, "\n")
