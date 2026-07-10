local transport = require("claude-transport")

describe("send_at_mention", function()
	it("fails gracefully when the server is not running", function()
		local ok, err = transport.send_at_mention(1, 2)
		assert.is_false(ok)
		assert.is_string(err)
	end)
end)

describe("lifecycle", function()
	local lockfile = require("claude-transport.lockfile")
	local tmp

	before_each(function()
		tmp = vim.fn.tempname()
		vim.fn.mkdir(tmp, "p")
		lockfile.lock_dir = tmp
	end)

	after_each(function()
		pcall(transport.stop)
		vim.fn.delete(tmp, "rf")
	end)

	it("clears the shutdown autocmd on stop", function()
		transport.setup({})
		local ok = transport.start()
		assert.is_true(ok)
		transport.stop()

		local got, autocmds = pcall(vim.api.nvim_get_autocmds, { group = "ClaudeTransportShutdown" })
		assert.is_true(not got or #autocmds == 0)
	end)
end)
