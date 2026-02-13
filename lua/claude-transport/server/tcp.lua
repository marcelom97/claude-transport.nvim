local client_manager = require("claude-transport.server.client")

local M = {}

local MAX_PORT_ATTEMPTS = 50

function M.find_available_port(min_port, max_port)
	if min_port > max_port then
		return nil
	end

	local range = max_port - min_port + 1

	for _ = 1, MAX_PORT_ATTEMPTS do
		local port = min_port + math.random(0, range - 1)
		local test = vim.loop.new_tcp()
		if test then
			local ok = test:bind("127.0.0.1", port)
			test:close()
			if ok then
				return port
			end
		end
	end

	return nil
end

function M.create_server(config, callbacks, auth_token)
	local port = M.find_available_port(config.port_range.min, config.port_range.max)
	if not port then
		return nil, "No available ports in range " .. config.port_range.min .. "-" .. config.port_range.max
	end

	local tcp_server = vim.loop.new_tcp()
	if not tcp_server then
		return nil, "Failed to create TCP server"
	end

	local server = {
		server = tcp_server,
		port = port,
		auth_token = auth_token,
		clients = {},
		on_message = callbacks.on_message or function() end,
		on_connect = callbacks.on_connect or function() end,
		on_disconnect = callbacks.on_disconnect or function() end,
		on_error = callbacks.on_error or function(_) end,
	}

	local ok, err = tcp_server:bind("127.0.0.1", port)
	if not ok then
		tcp_server:close()
		return nil, "Failed to bind to port " .. port .. ": " .. (err or "unknown")
	end

	local listen_ok, listen_err = tcp_server:listen(128, function(listen_err_inner)
		if listen_err_inner then
			server.on_error("Listen error: " .. listen_err_inner)
			return
		end
		M._handle_new_connection(server)
	end)

	if not listen_ok then
		tcp_server:close()
		return nil, "Failed to listen on port " .. port .. ": " .. (listen_err or "unknown")
	end

	return server, nil
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
