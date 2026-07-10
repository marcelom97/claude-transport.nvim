local tcp = require("claude-transport.server.tcp")

local TOKEN = "tcp-spec-token-0123456789"

describe("tcp server", function()
	it("fails gracefully when every port in the range is taken", function()
		local blocker = vim.loop.new_tcp()
		blocker:bind("127.0.0.1", 0)
		blocker:listen(16, function() end)
		local port = blocker:getsockname().port

		local server, err = tcp.create_server({ port_range = { min = port, max = port } }, {}, TOKEN)
		blocker:close()

		assert.is_nil(server)
		assert.matches("No available ports", err)
	end)

	it("closes connections that never complete a handshake", function()
		local server = tcp.create_server(
			{ port_range = { min = 20000, max = 60000 }, handshake_timeout_ms = 100 },
			{},
			TOKEN
		)
		assert.is_not_nil(server)

		local got_eof = false
		local sock = vim.loop.new_tcp()
		sock:connect("127.0.0.1", server.port, function(connect_err)
			if connect_err then
				got_eof = true
				return
			end
			sock:read_start(function(read_err, data)
				if read_err or not data then
					got_eof = true
				end
			end)
		end)

		vim.wait(2000, function()
			return got_eof
		end, 20)

		if not sock:is_closing() then
			sock:close()
		end
		tcp.stop_server(server)

		assert.is_true(got_eof)
	end)
end)
