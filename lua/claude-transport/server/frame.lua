local utils = require("claude-transport.server.utils")

local M = {}

M.OPCODE = {
	CONTINUATION = 0x0,
	TEXT = 0x1,
	BINARY = 0x2,
	CLOSE = 0x8,
	PING = 0x9,
	PONG = 0xA,
}

local VALID_OPCODES = {
	[0x0] = true,
	[0x1] = true,
	[0x2] = true,
	[0x8] = true,
	[0x9] = true,
	[0xA] = true,
}

function M.is_control_frame(opcode)
	return opcode >= 0x8
end

local function parse_header(data)
	if #data < 2 then
		return nil, 0
	end

	local b1, b2 = data:byte(1, 2)
	local fin = math.floor(b1 / 128) == 1
	local rsv = math.floor((b1 % 128) / 16)
	local opcode = b1 % 16
	local masked = math.floor(b2 / 128) == 1
	local len_code = b2 % 128

	if rsv ~= 0 then
		return nil, 0
	end
	if not VALID_OPCODES[opcode] then
		return nil, 0
	end
	if M.is_control_frame(opcode) and (not fin or len_code > 125) then
		return nil, 0
	end

	return { fin = fin, opcode = opcode, masked = masked, len_code = len_code }, 3
end

local function parse_payload_length(data, offset, len_code)
	if len_code < 126 then
		return len_code, offset
	elseif len_code == 126 then
		if #data < offset + 1 then
			return nil, 0
		end
		return utils.bytes_to_uint16(data:sub(offset, offset + 1)), offset + 2
	else
		if #data < offset + 7 then
			return nil, 0
		end
		local len = utils.bytes_to_uint64(data:sub(offset, offset + 7))
		if len > 100 * 1024 * 1024 then
			return nil, 0
		end
		return len, offset + 8
	end
end

local function read_mask_and_payload(data, offset, length, masked)
	local mask = nil
	if masked then
		if #data < offset + 3 then
			return nil, nil, 0
		end
		mask = data:sub(offset, offset + 3)
		offset = offset + 4
	end

	if #data < offset + length - 1 then
		return nil, nil, 0
	end

	local payload = data:sub(offset, offset + length - 1)
	if masked and mask then
		payload = utils.apply_mask(payload, mask)
	end

	return payload, mask, offset + length
end

function M.parse_frame(data)
	if type(data) ~= "string" then
		return nil, 0
	end

	local header, pos = parse_header(data)
	if not header then
		return nil, 0
	end

	local length, new_pos = parse_payload_length(data, pos, header.len_code)
	if not length then
		return nil, 0
	end
	pos = new_pos

	local payload, mask, end_pos = read_mask_and_payload(data, pos, length, header.masked)
	if not payload then
		return nil, 0
	end

	if header.opcode == M.OPCODE.TEXT and not utils.is_valid_utf8(payload) then
		return nil, 0
	end

	if header.opcode == M.OPCODE.CLOSE and length > 0 then
		if length == 1 then
			return nil, 0
		end
		if length > 2 and not utils.is_valid_utf8(payload:sub(3)) then
			return nil, 0
		end
	end

	return {
		fin = header.fin,
		opcode = header.opcode,
		masked = header.masked,
		payload_length = length,
		mask = mask,
		payload = payload,
	},
		end_pos - 1
end

function M.create_frame(opcode, payload, fin, masked)
	fin = fin ~= false
	masked = masked == true

	local parts = {}
	local b1 = opcode + (fin and 128 or 0)
	parts[#parts + 1] = string.char(b1)

	local len = #payload
	local b2 = masked and 128 or 0

	if len < 126 then
		parts[#parts + 1] = string.char(b2 + len)
	elseif len < 65536 then
		parts[#parts + 1] = string.char(b2 + 126)
		parts[#parts + 1] = utils.uint16_to_bytes(len)
	else
		parts[#parts + 1] = string.char(b2 + 127)
		parts[#parts + 1] = utils.uint64_to_bytes(len)
	end

	if masked then
		local mask = string.char(math.random(0, 255), math.random(0, 255), math.random(0, 255), math.random(0, 255))
		parts[#parts + 1] = mask
		payload = utils.apply_mask(payload, mask)
	end

	parts[#parts + 1] = payload
	return table.concat(parts)
end

function M.create_text_frame(text, fin)
	return M.create_frame(M.OPCODE.TEXT, text, fin, false)
end

function M.create_binary_frame(data, fin)
	return M.create_frame(M.OPCODE.BINARY, data, fin, false)
end

function M.create_close_frame(code, reason)
	local payload = utils.uint16_to_bytes(code or 1000) .. (reason or "")
	return M.create_frame(M.OPCODE.CLOSE, payload, true, false)
end

function M.create_ping_frame(data)
	return M.create_frame(M.OPCODE.PING, data or "", true, false)
end

function M.create_pong_frame(data)
	return M.create_frame(M.OPCODE.PONG, data or "", true, false)
end

return M
