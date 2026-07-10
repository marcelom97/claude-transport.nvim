local server = require("claude-transport.server.init")

describe("initialize handler", function()
	before_each(function()
		server.register_handlers()
	end)

	it("echoes the client's requested protocol version", function()
		local res = server.state.handlers["initialize"](nil, { protocolVersion = "2025-06-18" })
		assert.equals("2025-06-18", res.protocolVersion)
	end)

	it("falls back to a default protocol version when none is requested", function()
		local res = server.state.handlers["initialize"](nil, {})
		assert.is_string(res.protocolVersion)
		assert.is_true(#res.protocolVersion > 0)
	end)

	it("reports serverInfo and capabilities", function()
		local res = server.state.handlers["initialize"](nil, {})
		assert.is_table(res.capabilities)
		assert.equals("claude-transport-neovim", res.serverInfo.name)
	end)
end)

describe("_handle_message", function()
	it("responds -32600 instead of crashing on a JSON scalar message", function()
		local sent
		local orig = server.send_response
		server.send_response = function(_, id, result, error_data)
			sent = { id = id, result = result, error_data = error_data }
			return true
		end
		local ok = pcall(server._handle_message, { id = "test-client" }, "42")
		server.send_response = orig

		assert.is_true(ok)
		assert.is_table(sent)
		assert.is_table(sent.error_data)
		assert.equals(-32600, sent.error_data.code)
	end)
end)
