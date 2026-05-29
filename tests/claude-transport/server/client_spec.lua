local client_mod = require("claude-transport.server.client")
local frame = require("claude-transport.server.frame")

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
