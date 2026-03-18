local diagnostics = require("claude-transport.diagnostics")

describe("diagnostics module", function()
	before_each(function()
		diagnostics.disable()
	end)

	describe("state management", function()
		it("starts disabled", function()
			assert.is_false(diagnostics.is_enabled())
		end)

		it("can be enabled and disabled", function()
			local mock_server = { broadcast = function() end }
			diagnostics.enable(mock_server)
			assert.is_true(diagnostics.is_enabled())
			diagnostics.disable()
			assert.is_false(diagnostics.is_enabled())
		end)

		it("is idempotent on double enable", function()
			local mock_server = { broadcast = function() end }
			diagnostics.enable(mock_server)
			diagnostics.enable(mock_server)
			assert.is_true(diagnostics.is_enabled())
		end)

		it("is idempotent on double disable", function()
			assert.has_no_error(function()
				diagnostics.disable()
				diagnostics.disable()
			end)
		end)
	end)
end)
