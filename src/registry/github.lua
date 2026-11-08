-- GitHub API and bot identity helpers, all through `gh api`.

local process = require("process")
local json = require("registry.registry.json")

local M = {}

---@param args string[]
---@return integer exitCode
---@return string stdout
---@return string stderr
local function gh(args)
	local code, stdout, stderr = process.exec("gh", args, {
		stdout = "pipe",
		stderr = "pipe",
	})
	return code or 1, stdout or "", stderr or ""
end

---@param value string
---@return string
local function trim(value)
	return value:match("^%s*(.-)%s*$") or ""
end

--- Calls `gh api <path> --jq <filter>`. Returns nil + error when the call or
--- the filter fails.
---@param apiPath string
---@param jq string?
---@return string?, string?
function M.api(apiPath, jq)
	local args = { "api", apiPath }
	if jq then
		args[#args + 1] = "--jq"
		args[#args + 1] = jq
	end
	local code, stdout, stderr = gh(args)
	if code ~= 0 then
		return nil, trim(stderr ~= "" and stderr or stdout)
	end
	return trim(stdout), nil
end

--- Anyone who can merge PRs is treated as an admin/owner for ownership rules.
--- `author_association` comes from the event; MEMBER is not enough, so for
--- those we check the actual repository permission.
---@param repo string
---@param association string?
---@param login string?
---@return boolean
function M.isAdmin(repo, association, login)
	if association == "OWNER" or association == "COLLABORATOR" then
		return true
	end
	if not login or login == "" or not login:match("^[%w%-]+$") then
		return false
	end
	if repo:match("^[%w%.%-_]+/[%w%.%-_]+$") == nil then
		return false
	end
	local permission = M.api("repos/" .. repo .. "/collaborators/" .. login .. "/permission", ".permission")
	return permission == "admin" or permission == "write"
end

--- Numeric GitHub id of a commit author, falling back to the PR that introduced
--- the commit when the commit author is not linked to an account.
---@param repo string
---@param sha string
---@return number?, string?
function M.commitAuthorId(repo, sha)
	if repo:match("^[%w%.%-_]+/[%w%.%-_]+$") == nil then
		return nil, "invalid repository name: " .. repo
	end
	local id = M.api("repos/" .. repo .. "/commits/" .. sha, ".author.id")
	if id and id ~= "" and id ~= "null" then
		local number = tonumber(id)
		if number then return number end
	end
	local pullId = M.api("repos/" .. repo .. "/commits/" .. sha .. "/pulls", ".[0].user.id")
	if pullId and pullId ~= "" and pullId ~= "null" then
		local number = tonumber(pullId)
		if number then return number end
	end
	return nil, "could not resolve the GitHub id of the author of commit " .. sha
end

--- The bot's commit identity. BOT_NAME/BOT_EMAIL win; otherwise the account
--- behind the token (a user token), then a stable fallback. An installation
--- token cannot call `/user`, so App-driven runs use BOT_NAME/BOT_EMAIL or the
--- fallback.
---@return { name: string, email: string }
function M.resolveIdentity()
	local name = trim(os.getenv("BOT_NAME") or "")
	local email = trim(os.getenv("BOT_EMAIL") or "")
	if name ~= "" and email ~= "" then
		return { name = name, email = email }
	end

	local raw = M.api("user", "{login, id, name}")
	if raw then
		local info = json.decode(raw)
		if type(info) == "table" and info.login and info.id then
			local displayName = type(info.name) == "string" and trim(info.name) or ""
			if displayName == "" then displayName = info.login end
			return {
				name = displayName,
				email = tostring(info.id) .. "+" .. info.login .. "@users.noreply.github.com",
			}
		end
	end

	return { name = "robolde", email = "robolde@users.noreply.github.com" }
end

return M
