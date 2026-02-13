local M = {}

local bit = require("bit")
local ffi = require("ffi")

ffi.cdef([[
unsigned char *SHA1(const unsigned char *d, size_t n, unsigned char *md);
]])

local crypto_lib
local function get_crypto()
	if crypto_lib ~= nil then
		return crypto_lib
	end
	local ok, lib = pcall(ffi.load, "crypto")
	if ok then
		crypto_lib = lib
		return lib
	end
	crypto_lib = false
	return false
end

function M.sha1_binary(input)
	local crypto = get_crypto()
	if not crypto then
		error("OpenSSL crypto library (libcrypto) not found")
	end
	local digest = ffi.new("unsigned char[20]")
	crypto.SHA1(input, #input, digest)
	return ffi.string(digest, 20)
end

local b64chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

function M.base64_encode(data)
	local result = {}
	local padding = ""

	local pad_len = 3 - (#data % 3)
	if pad_len ~= 3 then
		data = data .. string.rep("\0", pad_len)
		padding = string.rep("=", pad_len)
	end

	for i = 1, #data, 3 do
		local a, b, c = data:byte(i, i + 2)
		local n = a * 65536 + b * 256 + c

		local i1 = math.floor(n / 262144) + 1
		local i2 = math.floor((n % 262144) / 4096) + 1
		local i3 = math.floor((n % 4096) / 64) + 1
		local i4 = (n % 64) + 1

		result[#result + 1] = b64chars:sub(i1, i1)
			.. b64chars:sub(i2, i2)
			.. b64chars:sub(i3, i3)
			.. b64chars:sub(i4, i4)
	end

	local encoded = table.concat(result)
	return encoded:sub(1, #encoded - #padding) .. padding
end

function M.generate_accept_key(client_key)
	local magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
	local hash = M.sha1_binary(client_key .. magic)
	return M.base64_encode(hash)
end

function M.parse_http_headers(request)
	local headers = {}
	for line in request:gmatch("[^\r\n]+") do
		local name, value = line:match("^([^:]+):%s*(.+)$")
		if name and value then
			headers[name:lower()] = value
		end
	end
	return headers
end

function M.is_valid_utf8(str)
	local i = 1
	while i <= #str do
		local byte = str:byte(i)
		local char_len = 1

		if byte >= 0x80 then
			if byte >= 0xF0 then
				char_len = 4
			elseif byte >= 0xE0 then
				char_len = 3
			elseif byte >= 0xC0 then
				char_len = 2
			else
				return false
			end

			for j = 1, char_len - 1 do
				if i + j > #str then
					return false
				end
				local cont = str:byte(i + j)
				if cont < 0x80 or cont >= 0xC0 then
					return false
				end
			end
		end

		i = i + char_len
	end
	return true
end

function M.uint16_to_bytes(num)
	return string.char(math.floor(num / 256), num % 256)
end

function M.uint64_to_bytes(num)
	local bytes = {}
	for i = 8, 1, -1 do
		bytes[i] = num % 256
		num = math.floor(num / 256)
	end
	return string.char(unpack(bytes))
end

function M.bytes_to_uint16(bytes)
	if #bytes < 2 then
		return 0
	end
	return bytes:byte(1) * 256 + bytes:byte(2)
end

function M.bytes_to_uint64(bytes)
	if #bytes < 8 then
		return 0
	end
	local num = 0
	for i = 1, 8 do
		num = num * 256 + bytes:byte(i)
	end
	return num
end

function M.apply_mask(data, mask)
	local result = {}
	local m1, m2, m3, m4 = mask:byte(1, 4)
	local mask_bytes = { m1, m2, m3, m4 }

	for i = 1, #data do
		result[i] = string.char(bit.bxor(data:byte(i), mask_bytes[((i - 1) % 4) + 1]))
	end

	return table.concat(result)
end

return M
