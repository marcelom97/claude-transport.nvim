local transport = require("claude-transport")
local server = require("claude-transport.server.init")
local tcp = require("claude-transport.server.tcp")
local stub = require("luassert.stub")

describe("at_mentioned wire format", function()
	local buffer, previous_buffer, previous_server, previous_tcp_server, message
	local broadcast_stub, connected_stub

	before_each(function()
		transport.setup({})
		previous_buffer = vim.api.nvim_get_current_buf()
		buffer = vim.api.nvim_create_buf(true, false)
		vim.api.nvim_set_current_buf(buffer)
		vim.api.nvim_buf_set_name(buffer, vim.fn.tempname())
		vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { "first", "second", "third" })
		previous_server = transport.state.server
		previous_tcp_server = server.state.server
		transport.state.server = server
		server.state.server = {}
		message = nil
		connected_stub = stub(transport, "is_connected", function()
			return true
		end)
		broadcast_stub = stub(tcp, "broadcast", function(_, payload)
			message = vim.json.decode(payload)
		end)
	end)

	after_each(function()
		broadcast_stub:revert()
		connected_stub:revert()
		transport.state.server = previous_server
		server.state.server = previous_tcp_server
		vim.api.nvim_set_current_buf(previous_buffer)
		vim.api.nvim_buf_delete(buffer, { force = true })
	end)

	it("converts an editor command range to zero-based inclusive lines", function()
		vim.cmd("1,3ClaudeTransportSend")
		assert.same({
			jsonrpc = "2.0",
			method = "at_mentioned",
			params = { filePath = vim.api.nvim_buf_get_name(buffer), lineStart = 0, lineEnd = 2 },
		}, message)
	end)

	it("converts the Lua helper's first line to zero", function()
		assert.is_true(transport.send_at_mention(1, 1))
		assert.equals(0, message.params.lineStart)
		assert.equals(0, message.params.lineEnd)
	end)

	it("preserves zero-based ranges passed to the low-level notification API", function()
		transport.notify_at_mention("/project/file.lua", 0, 2)
		assert.same({ filePath = "/project/file.lua", lineStart = 0, lineEnd = 2 }, message.params)
	end)

	it("omits line fields for a whole-file notification", function()
		transport.notify_at_mention("/project/file.lua")
		assert.same({ filePath = "/project/file.lua" }, message.params)
	end)
end)
