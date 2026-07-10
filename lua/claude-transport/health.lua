local M = {}

---Run health checks. Invoked by `:checkhealth claude-transport`.
function M.check()
	local health = vim.health
	local start = health.start or health.report_start
	local ok = health.ok or health.report_ok
	local warn = health.warn or health.report_warn
	local err = health.error or health.report_error

	start("claude-transport")

	if vim.fn.has("nvim-0.10") == 1 then
		ok("Neovim 0.10+")
	else
		err("Neovim 0.10+ is required")
	end

	local utils_ok, utils = pcall(require, "claude-transport.server.utils")
	if utils_ok and pcall(utils.sha1_binary, "test") then
		ok("OpenSSL libcrypto available (FFI SHA-1 for the WebSocket handshake)")
	else
		err("OpenSSL libcrypto not loadable via FFI; the WebSocket handshake will fail")
	end

	local lockfile = require("claude-transport.lockfile")
	local dir = lockfile.lock_dir
	if vim.fn.isdirectory(dir) == 0 then
		ok("Lock file directory not created yet (created on first start): " .. dir)
	elseif vim.fn.filewritable(dir) == 2 then
		ok("Lock file directory writable: " .. dir)
		local locks = vim.fn.glob(dir .. "/*.lock", true, true)
		if #locks > 0 then
			ok(#locks .. " lock file(s) present (stale ones are pruned on start)")
		end
	else
		warn("Lock file directory not writable: " .. dir)
	end

	local transport = require("claude-transport")
	if transport.is_running() then
		ok(
			string.format(
				"Server running on port %s (%s)",
				tostring(transport.get_port()),
				transport.is_connected() and "client connected" or "no clients"
			)
		)
	else
		ok("Server not running (start with :ClaudeTransportStart)")
	end
end

return M
