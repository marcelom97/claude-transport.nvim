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
