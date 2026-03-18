local M = {}

function M.get()
	local transport = require("claude-transport")
	local running = transport.is_running()
	local connected = running and transport.is_connected() or false
	local port = running and transport.get_port() or nil
	local client_count = 0
	if running then
		local conns = transport.get_connections()
		client_count = #conns
	end

	return {
		running = running,
		connected = connected,
		port = port,
		client_count = client_count,
	}
end

function M.is_connected()
	local transport = require("claude-transport")
	return transport.is_running() and transport.is_connected()
end

function M.text()
	local state = M.get()
	if not state.running then
		return "Claude: off"
	end
	if state.connected then
		return "Claude: connected (port " .. state.port .. ")"
	end
	return "Claude: waiting (port " .. state.port .. ")"
end

function M.icon()
	local state = M.get()
	if not state.running then
		return { icon = "󰚩", color = "grey" }
	end
	if state.connected then
		return { icon = "󰚩", color = "green" }
	end
	return { icon = "󰚩", color = "yellow" }
end

return M
