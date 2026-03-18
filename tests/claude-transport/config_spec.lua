local config = require("claude-transport.config")

describe("config", function()
	describe("defaults", function()
		it("has expected default values", function()
			assert.equals(false, config.defaults.auto_start)
			assert.equals("info", config.defaults.log_level)
			assert.equals(30000, config.defaults.ping_interval)
			assert.equals(true, config.defaults.register_default_tools)
			assert.equals(10000, config.defaults.port_range.min)
			assert.equals(65535, config.defaults.port_range.max)
		end)

	end)

	describe("validate", function()
		it("accepts valid config", function()
			assert.is_true(config.validate(config.defaults))
		end)

		it("rejects invalid port range min > max", function()
			local bad = vim.deepcopy(config.defaults)
			bad.port_range = { min = 65535, max = 10000 }
			assert.has_error(function()
				config.validate(bad)
			end)
		end)

		it("rejects port range with min <= 0", function()
			local bad = vim.deepcopy(config.defaults)
			bad.port_range = { min = 0, max = 65535 }
			assert.has_error(function()
				config.validate(bad)
			end)
		end)

		it("rejects port range with max > 65535", function()
			local bad = vim.deepcopy(config.defaults)
			bad.port_range = { min = 10000, max = 70000 }
			assert.has_error(function()
				config.validate(bad)
			end)
		end)

		it("rejects unknown log level", function()
			local bad = vim.deepcopy(config.defaults)
			bad.log_level = "verbose"
			assert.has_error(function()
				config.validate(bad)
			end)
		end)

		it("rejects non-boolean auto_start", function()
			local bad = vim.deepcopy(config.defaults)
			bad.auto_start = "yes"
			assert.has_error(function()
				config.validate(bad)
			end)
		end)

		it("rejects non-positive ping_interval", function()
			local bad = vim.deepcopy(config.defaults)
			bad.ping_interval = -1
			assert.has_error(function()
				config.validate(bad)
			end)
		end)

	end)

	describe("apply", function()
		it("returns defaults when no user config", function()
			local result = config.apply(nil)
			assert.same(config.defaults, result)
		end)

		it("overrides specific values", function()
			local result = config.apply({ log_level = "debug", auto_start = true })
			assert.equals("debug", result.log_level)
			assert.equals(true, result.auto_start)
			assert.equals(30000, result.ping_interval)
		end)

		it("accepts array-style port range", function()
			local result = config.apply({ port_range = { 20000, 30000 } })
			assert.equals(20000, result.port_range.min)
			assert.equals(30000, result.port_range.max)
		end)
	end)
end)
