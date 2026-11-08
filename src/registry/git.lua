-- Thin, argument-list wrappers around the `git` binary.
--
-- Every call passes an argument list to process.exec, so nothing is
-- interpolated into a shell.

local process = require("process")

local M = {}

---@param args string[]
---@param opts { cwd: string? }?
---@return integer exitCode
---@return string stdout
---@return string stderr
function M.exec(args, opts)
	local code, stdout, stderr = process.exec("git", args, {
		cwd = opts and opts.cwd or nil,
		stdout = "pipe",
		stderr = "pipe",
	})
	return code or 1, stdout or "", stderr or ""
end

---@param cwd string
---@param sha string
---@param filePath string
---@return string?
function M.show(cwd, sha, filePath)
	local code, stdout = M.exec({ "show", sha .. ":" .. filePath }, { cwd = cwd })
	if code ~= 0 then return nil end
	return stdout
end

---@param cwd string
---@param baseSha string
---@param headSha string
---@return string
function M.diffNameStatus(cwd, baseSha, headSha)
	local code, stdout, stderr = M.exec(
		{ "diff", "--name-status", baseSha .. "..." .. headSha, "--", "packages/", "authority.json", "last-updated.json" },
		{ cwd = cwd }
	)
	if code ~= 0 then
		error("git diff failed: " .. stderr, 0)
	end
	return stdout
end

---@class registry.git.Change
---@field status string
---@field path string
---@field oldPath string?

--- Parses `git diff --name-status` output. Renames are kept as their own
--- status so the checker can reject them; add/delete pairs still work.
---@param output string
---@return registry.git.Change[]
function M.parseNameStatus(output)
	local changes = {}
	for line in output:gmatch("[^\r\n]+") do
		local fields = {}
		for field in line:gmatch("([^\t]+)") do
			fields[#fields + 1] = field
		end
		local status = fields[1]
		if status then
			if status:sub(1, 1) == "R" then
				if fields[2] and fields[3] then
					changes[#changes + 1] = { status = "R", path = fields[3], oldPath = fields[2] }
				end
			elseif fields[2] then
				changes[#changes + 1] = { status = status, path = fields[2] }
			end
		end
	end
	return changes
end

--- Runs a `git log --format=%H%n%cI` command and returns the hash and date.
---@param cwd string
---@param args string[]
---@return { sha: string, date: string }?
function M.commitInfo(cwd, args)
	local code, stdout = M.exec(args, { cwd = cwd })
	if code ~= 0 then return nil end
	local sha, date = stdout:match("^%s*(%S+)%s*\n%s*(%S+)%s*$")
	if not sha or not date then return nil end
	return { sha = sha, date = date }
end

--- The commit that first added a package's portfile, and its date.
---@param cwd string
---@param name string
---@return { sha: string, date: string }?
function M.firstCommit(cwd, name)
	return M.commitInfo(cwd, {
		"log",
		"--follow",
		"--diff-filter=A",
		"--format=%H%n%cI",
		"-1",
		"--",
		"packages/" .. name .. ".json",
	})
end

--- The newest commit that touched a package's portfile, and its date.
---@param cwd string
---@param name string
---@return { sha: string, date: string }?
function M.lastCommit(cwd, name)
	return M.commitInfo(cwd, {
		"log",
		"-1",
		"--format=%H%n%cI",
		"--",
		"packages/" .. name .. ".json",
	})
end

---@param cwd string
---@param paths string[]
function M.add(cwd, paths)
	local args = { "add" }
	for _, filePath in ipairs(paths) do args[#args + 1] = filePath end
	local code, _, stderr = M.exec(args, { cwd = cwd })
	if code ~= 0 then error("git add failed: " .. stderr, 0) end
end

---@param cwd string
---@param message string
---@param identity { name: string, email: string }
---@return boolean
function M.commit(cwd, message, identity)
	local code = M.exec({
		"-c", "user.name=" .. identity.name,
		"-c", "user.email=" .. identity.email,
		"commit", "-m", message,
	}, { cwd = cwd })
	return code == 0
end

--- Pushes HEAD to `branch`. The checkout step configures the origin remote
--- with the app token; passing the token through argv would expose it in the
--- process list.
---@param cwd string
---@param branch string
---@return integer exitCode
---@return string stderr
function M.push(cwd, branch)
	local code, _, stderr = M.exec({
		"push",
		"origin",
		"HEAD:" .. branch,
	}, { cwd = cwd })
	return code, stderr
end

return M
