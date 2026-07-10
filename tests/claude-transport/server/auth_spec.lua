local server = require("claude-transport.server.init")

describe("server auth requirement", function()
	after_each(function()
		pcall(server.stop)
	end)

	it("refuses to start without an auth token", function()
		local ok, err = server.start({ port_range = { min = 45100, max = 45999 } }, nil)
		assert.is_false(ok)
		assert.matches("auth", err:lower())
	end)

	it("starts with a valid auth token", function()
		local ok, port = server.start({ port_range = { min = 45100, max = 45999 } }, "valid-token-1234567890")
		assert.is_true(ok)
		assert.is_number(port)
	end)
end)
