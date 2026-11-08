-- Namespace requests.
--
-- An issue containing `/request-namespace <name>` is answered; a moderator then
-- comments `!approve` (or `@robolde approve`), which creates the namespace in
-- authority.json, assigns it to the issue author, and closes the issue.

local fs = require("fs")
local authorityModule = require("registry.registry.authority")
local git = require("registry.registry.git")
local github = require("registry.registry.github")

local function env(name)
	return os.getenv(name) or ""
end

local EVENT = env("EVENT")
local REPO = env("REPO")
local ISSUE_NUMBER = env("ISSUE_NUMBER")
local ISSUE_BODY = env("ISSUE_BODY")
local ISSUE_AUTHOR_ID = env("ISSUE_AUTHOR_ID")
local ISSUE_AUTHOR_LOGIN = env("ISSUE_AUTHOR_LOGIN")
local COMMENT_BODY = env("COMMENT_BODY")
local COMMENT_AUTHOR_LOGIN = env("COMMENT_AUTHOR_LOGIN")
local COMMENT_AUTHOR_ASSOCIATION = env("COMMENT_AUTHOR_ASSOCIATION")

if REPO == "" or ISSUE_NUMBER == "" or ISSUE_AUTHOR_ID == "" then
	io.stderr:write("Missing required env: REPO, ISSUE_NUMBER, ISSUE_AUTHOR_ID\n")
	os.exit(1)
end
if not ISSUE_NUMBER:match("^%d+$") then
	io.stderr:write("ISSUE_NUMBER must be numeric\n")
	os.exit(1)
end

local ROOT = "."

local MAX_NAMESPACE_LENGTH = 128

---@param name string
---@return boolean
local function isValidNamespace(name)
	return #name <= MAX_NAMESPACE_LENGTH
		and name:match("^[a-z][a-z0-9_%-]+[a-z0-9]$") ~= nil
end

--- Extracts the token after `/request-namespace`, matching the phrase
--- case-insensitively while returning the token as written.
---@param body string
---@return string?
local function requestedNamespace(body)
	local lower = body:lower()
	local startPos, endPos = lower:find("/request%-namespace", 1)
	if not startPos then return nil end
	local rest = body:sub(endPos + 1)
	return rest:match("^%s+(%S+)")
end

local requested = requestedNamespace(ISSUE_BODY) or ""

---@param body string
local function comment(body)
	local temporary = os.tmpname()
	fs.write(temporary, body)
	local code, _, stderr = require("process").exec(
		"gh", { "issue", "comment", ISSUE_NUMBER, "--body-file", temporary },
		{ stdout = "pipe", stderr = "pipe" }
	)
	os.remove(temporary)
	if code ~= 0 then
		io.stderr:write("Could not comment on issue: ", stderr or "", "\n")
	end
end

local function closeIssue()
	require("process").exec("gh", { "issue", "close", ISSUE_NUMBER },
		{ stdout = "pipe", stderr = "pipe" })
end

-- ---- Initial issue: validate and ask for a moderator ----
if EVENT == "issues" then
	if requested == "" then
		-- Not a namespace request; ignore.
		os.exit(0)
	end
	if not isValidNamespace(requested) then
		comment(string.format(
			"`%s` is not a valid namespace name. Namespaces must be 3-128 characters, " ..
			"lowercase, start with a letter, end with a letter or digit, and contain only `a-z`, `0-9`, `_` and `-`.",
			requested))
		closeIssue()
		os.exit(0)
	end
	if authorityModule.load(ROOT .. "/authority.json").namespaces[requested] then
		comment(string.format("The namespace `%s` already exists, so it cannot be claimed.", requested))
		closeIssue()
		os.exit(0)
	end
	comment(string.format(
		"Namespace request for `%s` received. A repository moderator must approve it before it can be created.",
		requested))
	os.exit(0)
end

-- ---- Comment: moderator approval ----
if EVENT == "issue_comment" then
	local lower = COMMENT_BODY:lower()
	local approved = lower:find("!approve", 1, true) ~= nil
		or (COMMENT_BODY:find("@robolde", 1, true) ~= nil and lower:find("approve") ~= nil)
	if not approved then os.exit(0) end

	if not github.isAdmin(REPO, COMMENT_AUTHOR_ASSOCIATION, COMMENT_AUTHOR_LOGIN) then
		comment("Only repository moderators can approve namespace requests.")
		os.exit(0)
	end
	if requested == "" then
		comment("This issue is not a namespace request (missing `/request-namespace <name>`).")
		os.exit(0)
	end
	if not isValidNamespace(requested) then
		comment(string.format(
			"`%s` is not a valid namespace name. Namespaces must be 3-128 characters, " ..
			"lowercase, start with a letter, end with a letter or digit, and contain only `a-z`, `0-9`, `_` and `-`.",
			requested))
		closeIssue()
		os.exit(0)
	end

	local authority = authorityModule.load(ROOT .. "/authority.json")
	if authority.namespaces[requested] then
		comment(string.format("The namespace `%s` already exists, so it cannot be claimed.", requested))
		closeIssue()
		os.exit(0)
	end

	-- Create the namespace and assign ownership to the requester.
	authorityModule.setOwner(authority, requested, tonumber(ISSUE_AUTHOR_ID))
	authorityModule.save(ROOT .. "/authority.json", authority)

	git.add(ROOT, { "authority.json" })
	local identity = github.resolveIdentity()
	if not git.commit(ROOT, "Create namespace " .. requested, identity) then
		io.stderr:write("Nothing to commit or commit failed\n")
		os.exit(1)
	end

	local code, stderr = git.push(ROOT, "master")
	if code ~= 0 then
		io.stderr:write("Push failed. The bot token needs contents:write on master (or branch protection must allow the bot).\n")
		io.stderr:write(stderr, "\n")
		os.exit(1)
	end

	comment(string.format(
		"The namespace `%s` has been created and ownership assigned to @%s (id %s).",
		requested, ISSUE_AUTHOR_LOGIN, ISSUE_AUTHOR_ID))
	closeIssue()
	os.exit(0)
end

io.stderr:write("Unknown event: " .. EVENT .. "\n")
os.exit(1)
