local M = {}

---Path to the lock file directory
---@return string lock_dir The path to the lock file directory
local function get_lock_dir()
	local claude_config_dir = os.getenv("CLAUDE_CONFIG_DIR")
	if claude_config_dir and claude_config_dir ~= "" then
		return vim.fn.expand(claude_config_dir .. "/ide")
	else
		return vim.fn.expand("~/.claude/ide")
	end
end

M.lock_dir = get_lock_dir()

local bit = require("bit")

---Read cryptographically secure random bytes from the OS
---@param n number Number of bytes
---@return string bytes
local function random_bytes(n)
	-- libuv CSPRNG (OS entropy pool)
	local ok, bytes = pcall(vim.loop.random, n)
	if ok and type(bytes) == "string" and #bytes == n then
		return bytes
	end

	local f = io.open("/dev/urandom", "rb")
	if f then
		local data = f:read(n)
		f:close()
		if data and #data == n then
			return data
		end
	end

	error("No cryptographically secure random source available")
end

---Generate a random UUID v4 for authentication from OS entropy
---@return string uuid A randomly generated UUID string
local function generate_auth_token()
	local b = { random_bytes(16):byte(1, 16) }
	-- RFC 4122: set version (4) and variant (10xx) bits
	b[7] = bit.bor(bit.band(b[7], 0x0f), 0x40)
	b[9] = bit.bor(bit.band(b[9], 0x3f), 0x80)
	return string.format("%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x", unpack(b))
end

---Generate a new authentication token
---@return string auth_token A newly generated authentication token
function M.generate_auth_token()
	return generate_auth_token()
end

---Create the lock file for a specified WebSocket port
---@param port number The port number for the WebSocket server
---@param auth_token? string Optional pre-generated auth token (generates new one if not provided)
---@return boolean success Whether the operation was successful
---@return string result_or_error The lock file path if successful, or error message if failed
---@return string? auth_token The authentication token if successful
function M.create(port, auth_token)
	if not port or type(port) ~= "number" then
		return false, "Invalid port number"
	end

	if port < 1 or port > 65535 then
		return false, "Port number out of valid range (1-65535): " .. tostring(port)
	end

	local ok, err = pcall(function()
		return vim.fn.mkdir(M.lock_dir, "p")
	end)

	if not ok then
		return false, "Failed to create lock directory: " .. (err or "unknown error")
	end

	pcall(vim.loop.fs_chmod, M.lock_dir, tonumber("700", 8))

	local lock_path = M.lock_dir .. "/" .. port .. ".lock"

	local workspace_folders = M.get_workspace_folders()
	if not auth_token then
		local auth_success, auth_result = pcall(generate_auth_token)
		if not auth_success then
			return false, "Failed to generate authentication token: " .. (auth_result or "unknown error")
		end
		auth_token = auth_result
	else
		-- Validate provided auth_token
		if type(auth_token) ~= "string" then
			return false, "Authentication token must be a string, got " .. type(auth_token)
		end
		if #auth_token < 10 then
			return false, "Authentication token too short (minimum 10 characters)"
		end
		if #auth_token > 500 then
			return false, "Authentication token too long (maximum 500 characters)"
		end
	end

	-- Prepare lock file content
	local lock_content = {
		pid = vim.fn.getpid(),
		workspaceFolders = workspace_folders,
		ideName = "Neovim",
		transport = "ws",
		authToken = auth_token,
	}

	local json
	local ok_json, json_err = pcall(function()
		json = vim.json.encode(lock_content)
		return json
	end)

	if not ok_json or not json then
		return false, "Failed to encode lock file content: " .. (json_err or "unknown error")
	end

	-- Write to a temp file created with 0600, then rename into place so the
	-- token is never observable in a partially-written or world-readable file.
	local tmp_path = lock_path .. ".tmp"
	local fd, open_err = vim.loop.fs_open(tmp_path, "w", tonumber("600", 8))
	if not fd then
		return false, "Failed to create lock file: " .. (open_err or tmp_path)
	end

	local written, write_err = vim.loop.fs_write(fd, json, -1)
	vim.loop.fs_close(fd)
	if not written or written < #json then
		pcall(os.remove, tmp_path)
		return false, "Failed to write lock file: " .. (write_err or "short write")
	end

	local rename_ok, rename_err = vim.loop.fs_rename(tmp_path, lock_path)
	if not rename_ok then
		pcall(os.remove, tmp_path)
		return false, "Failed to publish lock file: " .. (rename_err or "unknown error")
	end

	return true, lock_path, auth_token
end

---Remove the lock file for the given port
---@param port number The port number of the WebSocket server
---@return boolean success Whether the operation was successful
---@return string? error Error message if operation failed
function M.remove(port)
	if not port or type(port) ~= "number" then
		return false, "Invalid port number"
	end

	local lock_path = M.lock_dir .. "/" .. port .. ".lock"

	if vim.fn.filereadable(lock_path) == 0 then
		return false, "Lock file does not exist: " .. lock_path
	end

	local ok, err = pcall(function()
		return os.remove(lock_path)
	end)

	if not ok then
		return false, "Failed to remove lock file: " .. (err or "unknown error")
	end

	return true
end

---Update the lock file for the given port
---@param port number The port number of the WebSocket server
---@return boolean success Whether the operation was successful
---@return string result_or_error The lock file path if successful, or error message if failed
---@return string? auth_token The authentication token if successful
function M.update(port)
	if not port or type(port) ~= "number" then
		return false, "Invalid port number"
	end

	local exists = vim.fn.filereadable(M.lock_dir .. "/" .. port .. ".lock") == 1
	if exists then
		local remove_ok, remove_err = M.remove(port)
		if not remove_ok then
			return false, "Failed to update lock file: " .. remove_err
		end
	end

	return M.create(port)
end

---Read the authentication token from a lock file
---@param port number The port number of the WebSocket server
---@return boolean success Whether the operation was successful
---@return string? auth_token The authentication token if successful, or nil if failed
---@return string? error Error message if operation failed
function M.get_auth_token(port)
	if not port or type(port) ~= "number" then
		return false, nil, "Invalid port number"
	end

	local lock_path = M.lock_dir .. "/" .. port .. ".lock"

	if vim.fn.filereadable(lock_path) == 0 then
		return false, nil, "Lock file does not exist: " .. lock_path
	end

	local file = io.open(lock_path, "r")
	if not file then
		return false, nil, "Failed to open lock file: " .. lock_path
	end

	local content = file:read("*all")
	file:close()

	if not content or content == "" then
		return false, nil, "Lock file is empty: " .. lock_path
	end

	local ok, lock_data = pcall(vim.json.decode, content)
	if not ok or type(lock_data) ~= "table" then
		return false, nil, "Failed to parse lock file JSON: " .. lock_path
	end

	local auth_token = lock_data.authToken
	if not auth_token or type(auth_token) ~= "string" then
		return false, nil, "No valid auth token found in lock file"
	end

	return true, auth_token, nil
end

---Check whether a process id refers to a running process.
---@param pid any The pid to probe
---@return boolean alive True if the process exists (or exists but is not signalable by us)
function M.is_pid_alive(pid)
	if type(pid) ~= "number" or pid <= 0 then
		return false
	end
	-- Signal 0 performs error checking without sending a signal.
	local res = { pcall(vim.loop.kill, pid, 0) }
	if not res[1] then
		return false
	end
	local ret, err_name = res[2], res[4]
	if ret == 0 then
		return true
	end
	-- EPERM: the process exists but belongs to another user.
	if err_name == "EPERM" then
		return true
	end
	return false
end

---Remove lock files left behind by Neovim instances that are no longer running.
---@return string[] removed Paths of the lock files that were removed
function M.cleanup_stale()
	local removed = {}
	if vim.fn.isdirectory(M.lock_dir) == 0 then
		return removed
	end

	local entries = vim.fn.glob(M.lock_dir .. "/*.lock", true, true)
	for _, path in ipairs(entries) do
		local file = io.open(path, "r")
		if file then
			local content = file:read("*all")
			file:close()
			local ok, data = pcall(vim.json.decode, content or "")
			if ok and type(data) == "table" and type(data.pid) == "number" and not M.is_pid_alive(data.pid) then
				if pcall(os.remove, path) then
					removed[#removed + 1] = path
				end
			end
		end
	end

	return removed
end

---Get active LSP clients using available API
---@return table Array of LSP clients
local function get_lsp_clients()
	if vim.lsp then
		if vim.lsp.get_clients then
			-- Neovim >= 0.11
			return vim.lsp.get_clients()
		elseif vim.lsp.get_active_clients then
			-- Neovim 0.8-0.10
			return vim.lsp.get_active_clients()
		end
	end
	return {}
end

---Get workspace folders for the lock file
---@return table Array of workspace folder paths
function M.get_workspace_folders()
	local seen = {}
	local folders = {}

	local cwd = vim.fn.getcwd()
	seen[cwd] = true
	folders[#folders + 1] = cwd

	local clients = get_lsp_clients()
	for _, client in pairs(clients) do
		if client.config and client.config.workspace_folders then
			for _, ws in ipairs(client.config.workspace_folders) do
				local path = ws.uri
				if path:sub(1, 7) == "file://" then
					path = path:sub(8)
				end
				if not seen[path] then
					seen[path] = true
					folders[#folders + 1] = path
				end
			end
		end
	end

	return folders
end

return M
