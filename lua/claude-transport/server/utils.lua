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

---Strict UTF-8 validation (RFC 3629): rejects overlong encodings, UTF-16
---surrogates (U+D800-U+DFFF), codepoints above U+10FFFF, and stray bytes.
---The first continuation byte's valid range depends on the lead byte; the
---rest must be 0x80-0xBF.
function M.is_valid_utf8(str)
	local i, n = 1, #str
	while i <= n do
		local b = str:byte(i)
		if b <= 0x7F then
			i = i + 1
		else
			local len, first_lo, first_hi
			if b >= 0xC2 and b <= 0xDF then
				len, first_lo, first_hi = 2, 0x80, 0xBF
			elseif b == 0xE0 then
				len, first_lo, first_hi = 3, 0xA0, 0xBF
			elseif (b >= 0xE1 and b <= 0xEC) or b == 0xEE or b == 0xEF then
				len, first_lo, first_hi = 3, 0x80, 0xBF
			elseif b == 0xED then
				len, first_lo, first_hi = 3, 0x80, 0x9F
			elseif b == 0xF0 then
				len, first_lo, first_hi = 4, 0x90, 0xBF
			elseif b >= 0xF1 and b <= 0xF3 then
				len, first_lo, first_hi = 4, 0x80, 0xBF
			elseif b == 0xF4 then
				len, first_lo, first_hi = 4, 0x80, 0x8F
			else
				return false
			end

			if i + len - 1 > n then
				return false
			end
			local c1 = str:byte(i + 1)
			if c1 < first_lo or c1 > first_hi then
				return false
			end
			for j = 2, len - 1 do
				local c = str:byte(i + j)
				if c < 0x80 or c > 0xBF then
					return false
				end
			end
			i = i + len
		end
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

---Compare two strings in constant time relative to their length.
---Avoids leaking how many leading bytes matched via early-exit timing.
---@param a string
---@param b string
---@return boolean equal
function M.constant_time_equals(a, b)
	if type(a) ~= "string" or type(b) ~= "string" then
		return false
	end
	if #a ~= #b then
		return false
	end
	local diff = 0
	for i = 1, #a do
		diff = bit.bor(diff, bit.bxor(a:byte(i), b:byte(i)))
	end
	return diff == 0
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
