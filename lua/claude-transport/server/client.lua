---@brief WebSocket client connection management
local frame = require("claude-transport.server.frame")
local handshake = require("claude-transport.server.handshake")
local utils = require("claude-transport.server.utils")
local logger = require("claude-transport.logger")

local M = {}

-- Caps to keep a misbehaving client from exhausting memory. Frame payloads are
-- separately capped in frame.lua; this bounds handshake buffering and the total
-- size of a fragmented message across frames.
M.MAX_HANDSHAKE_BYTES = 8192
M.MAX_MESSAGE_BYTES = 100 * 1024 * 1024
M.MAX_WRITE_QUEUE_BYTES = 4 * 1024 * 1024

---@class WebSocketClient
---@field id string Unique client identifier
---@field tcp_handle table The vim.loop TCP handle
---@field state string Connection state: "connecting", "connected", "closing", "closed"
---@field buffer string Incoming data buffer
---@field handshake_complete boolean Whether WebSocket handshake is complete
---@field last_ping number Timestamp of last ping sent
---@field last_pong number Timestamp of last pong received
---@field fragment table|nil In-progress fragmented message: { opcode = number, parts = string[] }

---Create a new WebSocket client
---@param tcp_handle table The vim.loop TCP handle
---@return WebSocketClient client The client object
function M.create_client(tcp_handle)
	local client_id = tostring(tcp_handle):gsub("userdata: ", "client_")

	local client = {
		id = client_id,
		tcp_handle = tcp_handle,
		state = "connecting",
		buffer = "",
		handshake_complete = false,
		last_ping = 0,
		last_pong = vim.loop.now(),
	}

	return client
end

local function handle_data_frame(parsed_frame, client, on_message)
	vim.schedule(function()
		on_message(client, parsed_frame.payload)
	end)
end

---RFC 6455 §7.4: 1000-1003 and 1007-1011 are defined, 3000-4999 are
---registered/private ranges; everything else must not appear on the wire.
local function is_valid_close_code(code)
	if code >= 3000 and code <= 4999 then
		return true
	end
	return code == 1000 or code == 1001 or code == 1002 or code == 1003 or (code >= 1007 and code <= 1011)
end

local function handle_control_frame(parsed_frame, client, on_close)
	if parsed_frame.opcode == frame.OPCODE.CLOSE then
		local code, reason = 1000, ""
		if #parsed_frame.payload >= 2 then
			code = parsed_frame.payload:byte(1) * 256 + parsed_frame.payload:byte(2)
			if #parsed_frame.payload > 2 then
				reason = parsed_frame.payload:sub(3)
			end
			if not is_valid_close_code(code) then
				code, reason = 1002, "invalid close code"
			end
		end
		if client.state == "connected" and not client.tcp_handle:is_closing() then
			client.tcp_handle:write(frame.create_close_frame(code, reason))
			client.state = "closing"
		end
		vim.schedule(function()
			on_close(client, code, reason)
		end)
	elseif parsed_frame.opcode == frame.OPCODE.PING then
		if not client.tcp_handle:is_closing() then
			client.tcp_handle:write(frame.create_pong_frame(parsed_frame.payload))
		end
	elseif parsed_frame.opcode == frame.OPCODE.PONG then
		client.last_pong = vim.loop.now()
	end
end

---Process incoming data for a client
---@param client WebSocketClient The client object
---@param data string The incoming data
---@param on_message function Callback for complete messages: function(client, message_text)
---@param on_close function Callback for client close: function(client, code, reason)
---@param on_error function Callback for errors: function(client, error_msg)
---@param auth_token string|nil Expected authentication token for validation
function M.process_data(client, data, on_message, on_close, on_error, auth_token)
	client.buffer = client.buffer .. data

	if not client.handshake_complete then
		if #client.buffer > M.MAX_HANDSHAKE_BYTES then
			client.buffer = ""
			on_error(client, "Handshake request exceeds " .. M.MAX_HANDSHAKE_BYTES .. " bytes")
			M.close_client(client, 1009, "handshake request too large")
			return
		end
		local complete, request, remaining = handshake.extract_http_request(client.buffer)
		if complete and request then
			local success, response_from_handshake, _ = handshake.process_handshake(request, auth_token)

			if success then
				logger.debug("client", "WebSocket handshake complete:", client.id)
			else
				logger.warn("client", "WebSocket handshake failed:", client.id)
			end

			client.tcp_handle:write(response_from_handshake, function(err)
				if err then
					logger.error("client", "Failed to send handshake response to client " .. client.id .. ": " .. err)
					on_error(client, "Failed to send handshake response: " .. err)
					return
				end

				if success then
					client.handshake_complete = true
					client.state = "connected"
					client.buffer = remaining
					logger.debug("client", "WebSocket connection established for client:", client.id)

					if #client.buffer > 0 then
						M.process_data(client, "", on_message, on_close, on_error, auth_token)
					end
				else
					client.state = "closing"
					logger.debug("client", "Closing connection for client due to failed handshake:", client.id)
					vim.schedule(function()
						client.tcp_handle:close()
					end)
				end
			end)
		end
		return
	end

	-- Parse frames at a moving offset and re-slice the buffer once at the end;
	-- slicing per frame makes a multi-frame read quadratic.
	local buf = client.buffer
	local pos = 1
	local function commit()
		client.buffer = pos > 1 and buf:sub(pos) or buf
	end

	while #buf - pos + 1 >= 2 do -- Minimum frame size
		local parsed_frame, bytes_consumed, parse_err = frame.parse_frame(buf, pos)

		if not parsed_frame then
			if parse_err then
				-- Malformed frame: closing beats stalling on an unparseable buffer.
				commit()
				on_error(client, "Protocol error: " .. parse_err)
				M.close_client(client, 1002, parse_err)
				return
			end
			break -- Incomplete frame: wait for more data.
		end

		-- RFC 6455 §5.1: every client-to-server frame must be masked.
		if not parsed_frame.masked then
			commit()
			on_error(client, "Protocol error: client frame not masked")
			M.close_client(client, 1002, "client frame must be masked")
			return
		end

		pos = pos + bytes_consumed

		local opcode = parsed_frame.opcode
		if opcode == frame.OPCODE.TEXT or opcode == frame.OPCODE.BINARY then
			if client.fragment then
				commit()
				on_error(client, "Protocol error: new data frame during a fragmented message")
				M.close_client(client, 1002, "interleaved data frame")
				return
			end
			if parsed_frame.fin then
				handle_data_frame(parsed_frame, client, on_message)
			else
				client.fragment = { opcode = opcode, parts = { parsed_frame.payload }, size = #parsed_frame.payload }
			end
		elseif opcode == frame.OPCODE.CONTINUATION then
			if not client.fragment then
				commit()
				on_error(client, "Protocol error: continuation frame with no message in progress")
				M.close_client(client, 1002, "unexpected continuation frame")
				return
			end
			client.fragment.parts[#client.fragment.parts + 1] = parsed_frame.payload
			client.fragment.size = client.fragment.size + #parsed_frame.payload
			if client.fragment.size > M.MAX_MESSAGE_BYTES then
				client.fragment = nil
				commit()
				on_error(client, "Protocol error: fragmented message exceeds size cap")
				M.close_client(client, 1009, "message too big")
				return
			end
			if parsed_frame.fin then
				local message = table.concat(client.fragment.parts)
				local is_text = client.fragment.opcode == frame.OPCODE.TEXT
				client.fragment = nil
				if is_text and not utils.is_valid_utf8(message) then
					commit()
					on_error(client, "Protocol error: invalid UTF-8 in fragmented text message")
					M.close_client(client, 1002, "invalid UTF-8")
					return
				end
				handle_data_frame({ opcode = parsed_frame.opcode, payload = message }, client, on_message)
			end
		elseif frame.is_control_frame(opcode) then
			handle_control_frame(parsed_frame, client, on_close)
		end
	end

	commit()
end

---Send a text message to a client
---@param client WebSocketClient The client object
---@param message string The message to send
---@param callback function? Optional callback: function(err)
function M.send_message(client, message, callback)
	if client.state ~= "connected" then
		if callback then
			callback("Client not connected")
		end
		return
	end

	-- Backpressure: libuv buffers writes without bound; a stalled client would
	-- otherwise accumulate outbound data indefinitely.
	local handle = client.tcp_handle
	if handle.get_write_queue_size and handle:get_write_queue_size() > M.MAX_WRITE_QUEUE_BYTES then
		if callback then
			callback("Client write queue full")
		end
		return
	end

	local text_frame = frame.create_text_frame(message)
	handle:write(text_frame, callback)
end

---Send a ping to a client
---@param client WebSocketClient The client object
---@param data string|nil Optional ping data
function M.send_ping(client, data)
	if client.state ~= "connected" then
		return
	end

	local ping_frame = frame.create_ping_frame(data or "")
	client.tcp_handle:write(ping_frame)
	client.last_ping = vim.loop.now()
end

---Close a client connection
---@param client WebSocketClient The client object
---@param code number|nil Close code (default: 1000)
---@param reason string|nil Close reason
function M.close_client(client, code, reason)
	if client.state == "closed" or client.state == "closing" then
		return
	end

	code = code or 1000
	reason = reason or ""

	if client.handshake_complete and not client.tcp_handle:is_closing() then
		local close_frame = frame.create_close_frame(code, reason)
		client.tcp_handle:write(close_frame, function()
			client.state = "closed"
			-- The handle may already have been closed by a disconnect path
			-- while this write was in flight; closing twice crashes libuv.
			if not client.tcp_handle:is_closing() then
				client.tcp_handle:close()
			end
		end)
	else
		client.state = "closed"
		if not client.tcp_handle:is_closing() then
			client.tcp_handle:close()
		end
	end

	client.state = "closing"
end

---Check if a client connection is alive
---@param client WebSocketClient The client object
---@param timeout number Timeout in milliseconds (default: 30000)
---@return boolean alive True if the client is considered alive
function M.is_client_alive(client, timeout)
	timeout = timeout or 30000 -- 30 seconds default

	if client.state ~= "connected" then
		return false
	end

	local now = vim.loop.now()
	return (now - client.last_pong) < timeout
end

---Get client info for debugging
---@param client WebSocketClient The client object
---@return table info Client information
function M.get_client_info(client)
	return {
		id = client.id,
		state = client.state,
		handshake_complete = client.handshake_complete,
		buffer_size = #client.buffer,
		last_ping = client.last_ping,
		last_pong = client.last_pong,
	}
end

return M
