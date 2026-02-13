local logger = require("claude-transport.logger")
local tcp_server = require("claude-transport.server.tcp")
local tools = require("claude-transport.tools.init")
local api = require("claude-transport.api")

local MCP_PROTOCOL_VERSION = "2024-11-05"
local PLUGIN_VERSION = "0.1.0"

local M = {}

local deferred_responses = {}

M.state = {
	server = nil,
	port = nil,
	auth_token = nil,
	handlers = {},
	ping_timer = nil,
}

function M.start(config, auth_token)
	if M.state.server then
		return false, "Server already running"
	end

	M.state.auth_token = auth_token

	if auth_token then
		logger.debug("server", "Starting WebSocket server with authentication enabled")
	else
		logger.debug("server", "Starting WebSocket server WITHOUT authentication (insecure)")
	end

	M.register_handlers()
	tools.setup(M)

	local callbacks = {
		on_message = function(client, message)
			M._handle_message(client, message)
		end,
		on_connect = function(client)
			logger.debug("server", "WebSocket client connected:", client.id)
			vim.schedule(function()
				api.emit("connect", { id = client.id, state = client.state })
			end)
		end,
		on_disconnect = function(client, code, reason)
			logger.debug("server", "WebSocket client disconnected:", client.id)
			vim.schedule(function()
				api.emit("disconnect", { id = client.id, code = code, reason = reason })
			end)
		end,
		on_error = function(error_msg)
			logger.error("server", "WebSocket server error:", error_msg)
		end,
	}

	local server, error_msg = tcp_server.create_server(config, callbacks, M.state.auth_token)
	if not server then
		return false, error_msg or "Unknown server creation error"
	end

	M.state.server = server
	M.state.port = server.port

	local ping_interval = config.ping_interval or 30000
	M.state.ping_timer = tcp_server.start_ping_timer(server, ping_interval)

	return true, server.port
end

function M.stop()
	if not M.state.server then
		return false, "Server not running"
	end

	if M.state.ping_timer then
		M.state.ping_timer:stop()
		M.state.ping_timer:close()
		M.state.ping_timer = nil
	end

	tcp_server.stop_server(M.state.server)

	deferred_responses = {}

	M.state.server = nil
	M.state.port = nil
	M.state.auth_token = nil
	return true
end

function M._handle_message(client, message)
	local success, parsed = pcall(vim.json.decode, message)
	if not success then
		M.send_response(client, nil, nil, {
			code = -32700,
			message = "Parse error",
			data = "Invalid JSON",
		})
		return
	end

	if type(parsed) ~= "table" or parsed.jsonrpc ~= "2.0" then
		M.send_response(client, parsed.id, nil, {
			code = -32600,
			message = "Invalid Request",
			data = "Not a valid JSON-RPC 2.0 request",
		})
		return
	end

	vim.schedule(function()
		api.emit("message", { id = client.id }, parsed)
	end)

	if parsed.id then
		M._handle_request(client, parsed)
	else
		M._handle_notification(client, parsed)
	end
end

function M._handle_request(client, request)
	local method = request.method
	local params = request.params or {}
	local id = request.id

	local handler = M.state.handlers[method]
	if not handler then
		M.send_response(client, id, nil, {
			code = -32601,
			message = "Method not found",
			data = "Unknown method: " .. tostring(method),
		})
		return
	end

	local success, result, error_data = pcall(handler, client, params)
	if success then
		if result and result._deferred then
			M._setup_deferred_response({
				client = result.client,
				id = id,
				coroutine = result.coroutine,
				method = method,
				params = result.params,
			})
			return
		end

		if error_data then
			M.send_response(client, id, nil, error_data)
		else
			M.send_response(client, id, result, nil)
		end
	else
		M.send_response(client, id, nil, {
			code = -32603,
			message = "Internal error",
			data = tostring(result),
		})
	end
end

function M._setup_deferred_response(deferred_info)
	local co = deferred_info.coroutine

	local response_sender = function(result)
		if result and result.content then
			M.send_response(deferred_info.client, deferred_info.id, result, nil)
		elseif result and result.error then
			M.send_response(deferred_info.client, deferred_info.id, nil, result.error)
		else
			M.send_response(deferred_info.client, deferred_info.id, nil, {
				code = -32603,
				message = "Internal error",
				data = "Deferred response completed with unexpected format",
			})
		end
	end

	deferred_responses[tostring(co)] = response_sender
end

function M._handle_notification(client, notification)
	local method = notification.method
	local params = notification.params or {}
	local handler = M.state.handlers[method]
	if handler then
		pcall(handler, client, params)
	end
end

function M.register_handlers()
	M.state.handlers = {
		["initialize"] = function(client, params)
			return {
				protocolVersion = MCP_PROTOCOL_VERSION,
				capabilities = {
					logging = vim.empty_dict(),
					prompts = { listChanged = true },
					resources = { subscribe = true, listChanged = true },
					tools = { listChanged = true },
				},
				serverInfo = {
					name = "claude-transport-neovim",
					version = PLUGIN_VERSION,
				},
			}
		end,
		["notifications/initialized"] = function(client, params) end,
		["prompts/list"] = function(client, params)
			return { prompts = {} }
		end,
		["tools/list"] = function(client, params)
			return { tools = tools.get_tool_list() }
		end,
		["tools/call"] = function(client, params)
			local result_or_error_table = tools.handle_invoke(client, params)
			if result_or_error_table and result_or_error_table._deferred then
				return result_or_error_table
			end
			if result_or_error_table.error then
				return nil, result_or_error_table.error
			elseif result_or_error_table.result then
				return result_or_error_table.result, nil
			else
				return nil,
					{
						code = -32603,
						message = "Internal error",
						data = "Tool handler returned unexpected format",
					}
			end
		end,
	}
end

function M.send(client, method, params)
	if not M.state.server then
		return false
	end
	local message = {
		jsonrpc = "2.0",
		method = method,
		params = params or vim.empty_dict(),
	}
	tcp_server.send_to_client(M.state.server, client.id, vim.json.encode(message))
	return true
end

function M.send_response(client, id, result, error_data)
	if not M.state.server then
		return false
	end
	local response = { jsonrpc = "2.0", id = id }
	if error_data then
		response.error = error_data
	else
		response.result = result
	end
	tcp_server.send_to_client(M.state.server, client.id, vim.json.encode(response))
	return true
end

function M.broadcast(method, params)
	if not M.state.server then
		return false
	end
	local message = {
		jsonrpc = "2.0",
		method = method,
		params = params or vim.empty_dict(),
	}
	tcp_server.broadcast(M.state.server, vim.json.encode(message))
	return true
end

function M.get_status()
	if not M.state.server then
		return { running = false, port = nil, client_count = 0 }
	end
	return {
		running = true,
		port = M.state.port,
		client_count = tcp_server.get_client_count(M.state.server),
		clients = tcp_server.get_clients_info(M.state.server),
	}
end

return M
