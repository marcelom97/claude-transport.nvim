local server = require("claude-transport.server.init")
local utils = require("claude-transport.server.utils")
local frame = require("claude-transport.server.frame")

local AUTH = "integration-test-token-0123456789"

local function random_ws_key()
	local bytes = {}
	for i = 1, 16 do
		bytes[i] = string.char(((i * 37 + 11) % 256))
	end
	return utils.base64_encode(table.concat(bytes))
end

-- Drives a raw WebSocket client against the live server: HTTP upgrade with auth,
-- then a masked `initialize` request, capturing the decoded JSON-RPC response.
local function request_initialize(port, auth, on_done)
	local key = random_ws_key()
	local handle = vim.loop.new_tcp()
	local state = { phase = "handshake", buffer = "", handshake_status = nil }

	local function send_initialize()
		local req = vim.json.encode({
			jsonrpc = "2.0",
			id = 1,
			method = "initialize",
			params = { protocolVersion = "2025-06-18" },
		})
		handle:write(frame.create_frame(frame.OPCODE.TEXT, req, true, true))
	end

	handle:connect("127.0.0.1", port, function(connect_err)
		if connect_err then
			on_done({ error = "connect: " .. connect_err })
			return
		end
		local request = table.concat({
			"GET / HTTP/1.1",
			"Host: 127.0.0.1",
			"Upgrade: websocket",
			"Connection: Upgrade",
			"Sec-WebSocket-Key: " .. key,
			"Sec-WebSocket-Version: 13",
			"x-claude-code-ide-authorization: " .. auth,
			"",
			"",
		}, "\r\n")
		handle:write(request)

		handle:read_start(function(read_err, data)
			if read_err or not data then
				return
			end
			state.buffer = state.buffer .. data

			if state.phase == "handshake" then
				local header_end = state.buffer:find("\r\n\r\n")
				if not header_end then
					return
				end
				state.handshake_status = state.buffer:match("^HTTP/1%.1 (%d+)")
				state.buffer = state.buffer:sub(header_end + 4)
				if state.handshake_status ~= "101" then
					handle:read_stop()
					handle:close()
					on_done({ handshake_status = state.handshake_status, response = nil })
					return
				end
				state.phase = "frame"
				send_initialize()
			end

			if state.phase == "frame" then
				local parsed, consumed = frame.parse_frame(state.buffer)
				if parsed then
					state.buffer = state.buffer:sub(consumed + 1)
					handle:read_stop()
					handle:close()
					local ok, decoded = pcall(vim.json.decode, parsed.payload)
					on_done({ handshake_status = state.handshake_status, response = ok and decoded or nil })
				end
			end
		end)
	end)
end

describe("end-to-end WebSocket + MCP", function()
	after_each(function()
		pcall(server.stop)
	end)

	it("upgrades with a valid auth token and answers initialize", function()
		local ok, port = server.start({ port_range = { min = 20000, max = 60000 }, ping_interval = 30000 }, AUTH)
		assert.is_true(ok)
		assert.is_number(port)

		local result
		request_initialize(port, AUTH, function(r)
			result = r
		end)

		vim.wait(3000, function()
			return result ~= nil
		end, 20)

		assert.is_not_nil(result)
		assert.equals("101", result.handshake_status)
		assert.is_not_nil(result.response)
		assert.equals("2025-06-18", result.response.result.protocolVersion)
		assert.equals("claude-transport-neovim", result.response.result.serverInfo.name)
	end)

	it("rejects an upgrade carrying the wrong auth token", function()
		local ok, port = server.start({ port_range = { min = 20000, max = 60000 }, ping_interval = 30000 }, AUTH)
		assert.is_true(ok)

		local result
		request_initialize(port, "the-wrong-token-9999", function(r)
			result = r
		end)

		vim.wait(3000, function()
			return result ~= nil
		end, 20)

		assert.is_not_nil(result)
		assert.equals("400", result.handshake_status)
		assert.is_nil(result.response)
	end)
end)
