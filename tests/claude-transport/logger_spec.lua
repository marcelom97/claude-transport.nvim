local logger = require("claude-transport.logger")

describe("logger", function()
	after_each(function()
		logger.setup({ log_level = "info" })
	end)

	it("emits synchronously outside fast-event contexts", function()
		logger.setup({ log_level = "info" })
		local got
		local orig = vim.notify
		vim.notify = function(msg, _level, _opts) -- luacheck: ignore
			got = msg
		end
		logger.error("spec", "boom")
		vim.notify = orig -- luacheck: ignore
		assert.is_string(got)
		assert.matches("boom", got)
	end)

	it("filters messages below the configured level", function()
		logger.setup({ log_level = "warn" })
		assert.is_false(logger.is_level_enabled("info"))
		assert.is_true(logger.is_level_enabled("warn"))
		assert.is_true(logger.is_level_enabled("error"))
	end)

	it("treats an unknown level name as disabled", function()
		assert.is_false(logger.is_level_enabled("nope"))
	end)
end)
