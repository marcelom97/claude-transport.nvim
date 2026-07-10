local client_manager = require("claude-transport.server.client")

local M = {}

local MAX_PORT_ATTEMPTS = 50
local DEFAULT_HANDSHAKE_TIMEOUT_MS = 10000

-- Unseeded, LuaJIT's math.random yields the same port sequence in every
-- Neovim instance, so concurrent instances all race for the same ports.
local rng_seeded = false
local function seed_rng()
	if rng_seeded then
		return
	end
	rng_seeded = true
	local seed
	local ok, bytes = pcall(vim.loop.random, 4)
	if ok and type(bytes) == "string" and #bytes == 4 then
		seed = 0
		for i = 1, 4 do
			seed = seed * 256 + bytes:byte(i)
		end
	else
		seed = (vim.loop.hrtime() + vim.fn.getpid()) % 2147483647
	end
	math.randomseed(seed)
end

function M.create_server(config, callbacks, auth_token)
	seed_rng()

	local min_port, max_port = config.port_range.min, config.port_range.max
	if min_port > max_port then
		return nil, "Invalid port range " .. min_port .. "-" .. max_port
	end

	local server = {
		server = nil,
		port = nil,
		auth_token = auth_token,
		handshake_timeout_ms = config.handshake_timeout_ms or DEFAULT_HANDSHAKE_TIMEOUT_MS,
		clients = {},
		on_message = callbacks.on_message or function() end,
		on_connect = callbacks.on_connect or function() end,
		on_disconnect = callbacks.on_disconnect or function() end,
		on_error = callbacks.on_error or function(_) end,
	}

	-- Bind AND listen on the real handle before accepting a port: a separate
	-- test-bind is racy, and SO_REUSEADDR lets bind() succeed against a port
	-- another process is already listening on (listen() then fails EADDRINUSE).
	for _ = 1, MAX_PORT_ATTEMPTS do
		local port = math.random(min_port, max_port)
		local tcp_server = vim.loop.new_tcp()
		if not tcp_server then
			return nil, "Failed to create TCP server"
		end

		local bind_ok = tcp_server:bind("127.0.0.1", port)
		if bind_ok then
			local listen_ok = tcp_server:listen(128, function(listen_err_inner)
				if listen_err_inner then
					server.on_error("Listen error: " .. listen_err_inner)
					return
				end
				M._handle_new_connection(server)
			end)
			if listen_ok then
				server.server = tcp_server
				server.port = port
				return server, nil
			end
		end
		tcp_server:close()
	end

	return nil, "No available ports in range " .. min_port .. "-" .. max_port
end

function M._handle_new_connection(server)
	local client_tcp = vim.loop.new_tcp()
	if not client_tcp then
		server.on_error("Failed to create client TCP handle")
		return
	end

	local ok, err = server.server:accept(client_tcp)
	if not ok then
		server.on_error("Failed to accept connection: " .. (err or "unknown"))
		client_tcp:close()
		return
	end

	local client = client_manager.create_client(client_tcp)
	server.clients[client.id] = client

	-- Drop connections that never finish the WebSocket handshake; otherwise a
	-- silent socket holds a client slot (and its buffer) forever.
	local handshake_timer = vim.loop.new_timer()
	if handshake_timer then
		client.handshake_timer = handshake_timer
		handshake_timer:start(server.handshake_timeout_ms or DEFAULT_HANDSHAKE_TIMEOUT_MS, 0, function()
			handshake_timer:stop()
			if not handshake_timer:is_closing() then
				handshake_timer:close()
			end
			client.handshake_timer = nil
			if not client.handshake_complete then
				M._disconnect_client(server, client, 1006, "Handshake timeout")
			end
		end)
	end

	client_tcp:read_start(function(read_err, data)
		if read_err then
			M._disconnect_client(server, client, 1006, "Read error: " .. read_err)
			return
		end

		if not data then
			M._disconnect_client(server, client, 1006, "EOF")
			return
		end

		client_manager.process_data(client, data, function(cl, message)
			server.on_message(cl, message)
		end, function(cl, code, reason)
			M._disconnect_client(server, cl, code, reason)
		end, function(cl, error_msg)
			server.on_error("Client " .. cl.id .. " error: " .. error_msg)
			M._disconnect_client(server, cl, 1006, error_msg)
		end, server.auth_token)
	end)

	server.on_connect(client)
end

function M._disconnect_client(server, client, code, reason)
	if not server.clients[client.id] then
		return
	end

	server.on_disconnect(client, code, reason)
	server.clients[client.id] = nil

	if client.handshake_timer then
		client.handshake_timer:stop()
		if not client.handshake_timer:is_closing() then
			client.handshake_timer:close()
		end
		client.handshake_timer = nil
	end

	if not client.tcp_handle:is_closing() then
		client.tcp_handle:close()
	end
end

function M.send_to_client(server, client_id, message, callback)
	local client = server.clients[client_id]
	if not client then
		if callback then
			callback("Client not found: " .. client_id)
		end
		return
	end
	client_manager.send_message(client, message, callback)
end

function M.broadcast(server, message)
	for _, client in pairs(server.clients) do
		client_manager.send_message(client, message)
	end
end

function M.get_client_count(server)
	local count = 0
	for _ in pairs(server.clients) do
		count = count + 1
	end
	return count
end

function M.get_clients_info(server)
	local clients = {}
	for _, client in pairs(server.clients) do
		table.insert(clients, client_manager.get_client_info(client))
	end
	return clients
end

function M.close_client(server, client_id, code, reason)
	local client = server.clients[client_id]
	if client then
		client_manager.close_client(client, code, reason)
	end
end

function M.stop_server(server)
	for _, client in pairs(server.clients) do
		client_manager.close_client(client, 1001, "Server shutting down")
	end
	server.clients = {}

	if server.server and not server.server:is_closing() then
		server.server:close()
	end
end

function M.start_ping_timer(server, interval)
	interval = interval or 30000
	local last_run = vim.loop.now()

	local timer = vim.loop.new_timer()
	if not timer then
		server.on_error("Failed to create ping timer")
		return nil
	end

	timer:start(interval, interval, function()
		local now = vim.loop.now()
		local elapsed = now - last_run

		if elapsed > (interval * 1.5) then
			for _, client in pairs(server.clients) do
				if client.state == "connected" then
					client.last_pong = now
				end
			end
		end

		for _, client in pairs(server.clients) do
			if client.state == "connected" then
				if client_manager.is_client_alive(client, interval * 2) then
					client_manager.send_ping(client, "ping")
				else
					client_manager.close_client(client, 1006, "Connection timeout")
					M._disconnect_client(server, client, 1006, "Connection timeout")
				end
			end
		end

		last_run = now
	end)

	return timer
end

return M
