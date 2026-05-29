local transport = require("claude-transport")

describe("send_at_mention", function()
	it("fails gracefully when the server is not running", function()
		local ok, err = transport.send_at_mention(1, 2)
		assert.is_false(ok)
		assert.is_string(err)
	end)
end)
