local M = {}

local logger = require("claude-transport.logger")
local api = require("claude-transport.api")

M.state = {
	config = require("claude-transport.config").defaults,
	server = nil,
	port = nil,
	auth_token = nil,
	initialized = false,
}

function M.setup(opts)
	opts = opts or {}

	local config = require("claude-transport.config")
	M.state.config = config.apply(opts)

	logger.setup(M.state.config)

	vim.api.nvim_create_user_command("ClaudeTransportStart", function()
		local ok, err = M.start()
		if not ok then
			logger.error("init", "Start failed: " .. tostring(err))
		end
	end, { desc = "Start Claude transport server" })

	vim.api.nvim_create_user_command("ClaudeTransportStop", function()
		local ok, err = M.stop()
		if not ok then
			logger.error("init", "Stop failed: " .. tostring(err))
		end
	end, { desc = "Stop Claude transport server" })

	vim.api.nvim_create_user_command("ClaudeTransportStatus", function()
		if M.is_running() then
			local port = M.get_port()
			local connected = M.is_connected()
			vim.notify(
				string.format(
					"Claude transport: running on port %d (%s)",
					port,
					connected and "connected" or "no clients"
				),
				vim.log.levels.INFO
			)
		else
			vim.notify("Claude transport: not running", vim.log.levels.INFO)
		end
	end, { desc = "Show Claude transport server status" })

	if M.state.config.auto_start then
		M.start()
	end

	M.state.initialized = true
	return M
end

function M.start()
	if M.state.server then
		logger.warn("init", "Already running on port " .. tostring(M.state.port))
		return false, "Already running"
	end

	local server = require("claude-transport.server.init")
	local lockfile = require("claude-transport.lockfile")
	local tools = require("claude-transport.tools.init")

	if M.state.config.register_default_tools then
		tools.register_defaults()
	end

	local auth_token
	local auth_success, auth_result = pcall(function()
		return lockfile.generate_auth_token()
	end)

	if not auth_success then
		logger.error("init", "Failed to generate auth token: " .. tostring(auth_result))
		return false, auth_result
	end
	auth_token = auth_result

	local success, result = server.start(M.state.config, auth_token)
	if not success then
		logger.error("init", "Failed to start server: " .. tostring(result))
		return false, result
	end

	M.state.server = server
	M.state.port = tonumber(result)
	M.state.auth_token = auth_token

	local lock_success, lock_result = lockfile.create(M.state.port, auth_token)
	if not lock_success then
		server.stop()
		M.state.server = nil
		M.state.port = nil
		M.state.auth_token = nil
		logger.error("init", "Failed to create lock file: " .. tostring(lock_result))
		return false, lock_result
	end

	vim.api.nvim_create_autocmd("VimLeavePre", {
		group = vim.api.nvim_create_augroup("ClaudeTransportShutdown", { clear = true }),
		callback = function()
			if M.state.server then
				M.stop()
			end
		end,
	})

	local selection = require("claude-transport.selection")
	selection.enable(M.state.server, 50)

	logger.info("init", "Claude transport started on port " .. tostring(M.state.port))
	return true, M.state.port
end

function M.stop()
	if not M.state.server then
		return false, "Not running"
	end

	local selection = require("claude-transport.selection")
	selection.disable()

	local lockfile = require("claude-transport.lockfile")
	lockfile.remove(M.state.port)

	M.state.server.stop()

	M.state.server = nil
	M.state.port = nil
	M.state.auth_token = nil

	api.clear()

	logger.info("init", "Claude transport stopped")
	return true
end

function M.is_running()
	return M.state.server ~= nil
end

function M.get_port()
	return M.state.port
end

function M.get_connections()
	if not M.state.server then
		return {}
	end
	local server_module = require("claude-transport.server.init")
	local status = server_module.get_status()
	return status.clients or {}
end

function M.is_connected()
	if not M.state.server then
		return false
	end
	local server_module = require("claude-transport.server.init")
	local status = server_module.get_status()
	if status.clients and #status.clients > 0 then
		for _, info in ipairs(status.clients) do
			if info.handshake_complete == true then
				return true
			end
		end
		return false
	end
	return status.client_count and status.client_count > 0
end

function M.broadcast(method, params)
	if not M.state.server then
		return false
	end
	return M.state.server.broadcast(method, params)
end

function M.send(connection_id, method, params)
	if not M.state.server then
		return false
	end
	local server_module = require("claude-transport.server.init")
	local tcp = require("claude-transport.server.tcp")
	if not server_module.state.server then
		return false
	end
	local message = {
		jsonrpc = "2.0",
		method = method,
		params = params or vim.empty_dict(),
	}
	tcp.send_to_client(server_module.state.server, connection_id, vim.json.encode(message))
	return true
end

function M.notify_at_mention(file_path, start_line, end_line)
	return M.broadcast("at_mentioned", {
		filePath = file_path,
		lineStart = start_line,
		lineEnd = end_line,
	})
end

function M.register_tool(name, schema, handler)
	local tools = require("claude-transport.tools.init")
	tools.register_tool(name, schema, handler)
end

function M.unregister_tool(name)
	local tools = require("claude-transport.tools.init")
	tools.unregister_tool(name)
end

function M.get_registered_tools()
	local tools = require("claude-transport.tools.init")
	return tools.get_tool_list()
end

function M.on(event, callback)
	api.on(event, callback)
end

return M
