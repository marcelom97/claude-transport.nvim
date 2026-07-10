local client_mod = require("claude-transport.server.client")
local frame = require("claude-transport.server.frame")
local utils = require("claude-transport.server.utils")

local function make_handle()
	local h = { writes = {}, closed = false }
	function h:write(data, cb)
		table.insert(self.writes, data)
		if cb then
			cb(nil)
		end
	end

	function h:close()
		self.closed = true
	end

	function h:is_closing()
		return self.closed
	end

	return h
end

local function connected_client()
	local handle = make_handle()
	local client = client_mod.create_client(handle)
	client.handshake_complete = true
	client.state = "connected"
	return client, handle
end

describe("client process_data (post-handshake)", function()
	it("delivers the payload of a valid masked text frame", function()
		local client = connected_client()
		local got
		local data = frame.create_frame(frame.OPCODE.TEXT, "hello", true, true)
		client_mod.process_data(client, data, function(_, msg)
			got = msg
		end, function() end, function() end, nil)
		vim.wait(200, function()
			return got ~= nil
		end, 10)
		assert.equals("hello", got)
	end)

	it("rejects an unmasked client frame by closing with 1002", function()
		local client, handle = connected_client()
		local err_called = false
		local unmasked = frame.create_frame(frame.OPCODE.TEXT, "hello", true, false)
		client_mod.process_data(client, unmasked, function() end, function() end, function()
			err_called = true
		end, nil)
		assert.is_true(err_called)
		assert.is_true(handle.closed)
		assert.is_not.equals("connected", client.state)
	end)

	it("closes with 1002 on a malformed frame instead of stalling", function()
		local client, handle = connected_client()
		local err_called = false
		local malformed = string.char(0xC1, 0x80) .. "\0\0\0\0"
		client_mod.process_data(client, malformed, function() end, function() end, function()
			err_called = true
		end, nil)
		assert.is_true(err_called)
		assert.is_true(handle.closed)
		assert.is_not.equals("connected", client.state)
	end)

	it("reassembles a fragmented text message", function()
		local client = connected_client()
		local got
		local on_message = function(_, msg)
			got = msg
		end
		local f1 = frame.create_frame(frame.OPCODE.TEXT, "Hel", false, true)
		local f2 = frame.create_frame(frame.OPCODE.CONTINUATION, "lo ", false, true)
		local f3 = frame.create_frame(frame.OPCODE.CONTINUATION, "World", true, true)
		client_mod.process_data(client, f1 .. f2 .. f3, on_message, function() end, function() end, nil)
		vim.wait(200, function()
			return got ~= nil
		end, 10)
		assert.equals("Hello World", got)
	end)

	it("closes with 1002 on a continuation frame with no message in progress", function()
		local client, handle = connected_client()
		local err_called = false
		local orphan = frame.create_frame(frame.OPCODE.CONTINUATION, "x", true, true)
		client_mod.process_data(client, orphan, function() end, function() end, function()
			err_called = true
		end, nil)
		assert.is_true(err_called)
		assert.is_true(handle.closed)
	end)

	it("closes with 1009 when a fragmented message exceeds the size cap", function()
		local client, handle = connected_client()
		local err_called = false
		local orig_cap = client_mod.MAX_MESSAGE_BYTES
		client_mod.MAX_MESSAGE_BYTES = 16

		local f1 = frame.create_frame(frame.OPCODE.TEXT, string.rep("a", 10), false, true)
		local f2 = frame.create_frame(frame.OPCODE.CONTINUATION, string.rep("b", 10), false, true)
		client_mod.process_data(client, f1 .. f2, function() end, function() end, function()
			err_called = true
		end, nil)

		client_mod.MAX_MESSAGE_BYTES = orig_cap
		assert.is_true(err_called)
		assert.is_true(handle.closed)
		local close_response = frame.parse_frame(handle.writes[#handle.writes])
		assert.equals(frame.OPCODE.CLOSE, close_response.opcode)
		assert.equals(1009, close_response.payload:byte(1) * 256 + close_response.payload:byte(2))
	end)

	it("responds 1002 to a close frame carrying an invalid close code", function()
		local client, handle = connected_client()
		local closed_code
		local bad_close = frame.create_frame(frame.OPCODE.CLOSE, utils.uint16_to_bytes(999), true, true)
		client_mod.process_data(client, bad_close, function() end, function(_, code)
			closed_code = code
		end, function() end, nil)
		vim.wait(200, function()
			return closed_code ~= nil
		end, 10)
		assert.equals(1002, closed_code)
		local close_response = frame.parse_frame(handle.writes[#handle.writes])
		assert.equals(frame.OPCODE.CLOSE, close_response.opcode)
		assert.equals(1002, close_response.payload:byte(1) * 256 + close_response.payload:byte(2))
	end)

	it("closes a connection whose pre-handshake buffer grows without a complete request", function()
		local handle = make_handle()
		local client = client_mod.create_client(handle)
		local err_called = false
		client_mod.process_data(client, string.rep("x", 10000), function() end, function() end, function()
			err_called = true
		end, nil)
		assert.is_true(err_called)
		assert.is_true(handle.closed)
	end)

	it("refuses to queue more data for a backpressured client", function()
		local client, handle = connected_client()
		handle.get_write_queue_size = function()
			return 10 * 1024 * 1024
		end
		local err
		client_mod.send_message(client, "payload", function(e)
			err = e
		end)
		assert.is_not_nil(err)
		assert.equals(0, #handle.writes)
	end)

	it("does not close the tcp handle twice when a pending close write completes after disconnect", function()
		local pending = {}
		local h = { close_count = 0 }
		function h:write(_, cb)
			if cb then
				table.insert(pending, cb)
			end
		end
		function h:close()
			self.close_count = self.close_count + 1
		end
		function h:is_closing()
			return self.close_count > 0
		end

		local client = client_mod.create_client(h)
		client.handshake_complete = true
		client.state = "connected"

		-- Ping-timeout path: close_client queues an async close-frame write...
		client_mod.close_client(client, 1006, "Connection timeout")
		-- ...then _disconnect_client closes the handle synchronously...
		if not h:is_closing() then
			h:close()
		end
		-- ...and later the queued write callback fires.
		for _, cb in ipairs(pending) do
			cb(nil)
		end

		assert.equals(1, h.close_count)
	end)

	it("buffers a partial frame until the rest arrives", function()
		local client = connected_client()
		local got
		local on_message = function(_, msg)
			got = msg
		end
		local data = frame.create_frame(frame.OPCODE.TEXT, "split-me", true, true)
		local half = math.floor(#data / 2)
		client_mod.process_data(client, data:sub(1, half), on_message, function() end, function() end, nil)
		vim.wait(50)
		assert.is_nil(got)
		client_mod.process_data(client, data:sub(half + 1), on_message, function() end, function() end, nil)
		vim.wait(200, function()
			return got ~= nil
		end, 10)
		assert.equals("split-me", got)
	end)
end)
