local utils = require("claude-transport.server.utils")

describe("server utils", function()
	describe("base64_encode", function()
		it("encodes empty string", function()
			assert.equals("", utils.base64_encode(""))
		end)

		it("encodes 'Hello'", function()
			assert.equals("SGVsbG8=", utils.base64_encode("Hello"))
		end)

		it("encodes binary data", function()
			local result = utils.base64_encode("\0\1\2\3")
			assert.equals("AAECAw==", result)
		end)
	end)

	describe("sha1_binary", function()
		it("produces 20-byte digest", function()
			local digest = utils.sha1_binary("test")
			assert.equals(20, #digest)
		end)
	end)

	describe("generate_accept_key", function()
		it("produces correct accept key for known input", function()
			local key = utils.generate_accept_key("dGhlIHNhbXBsZSBub25jZQ==")
			assert.equals("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", key)
		end)
	end)

	describe("is_valid_utf8", function()
		it("accepts ASCII", function()
			assert.is_true(utils.is_valid_utf8("hello world"))
		end)

		it("accepts valid multibyte", function()
			assert.is_true(utils.is_valid_utf8("héllo wörld"))
		end)

		it("accepts 4-byte emoji and U+10FFFF", function()
			assert.is_true(utils.is_valid_utf8("\240\159\146\169")) -- 💩
			assert.is_true(utils.is_valid_utf8("\244\143\191\191")) -- U+10FFFF
		end)

		it("rejects overlong encodings", function()
			assert.is_false(utils.is_valid_utf8("\192\128")) -- overlong NUL
			assert.is_false(utils.is_valid_utf8("\224\128\128")) -- overlong 3-byte
			assert.is_false(utils.is_valid_utf8("\240\128\128\128")) -- overlong 4-byte
		end)

		it("rejects UTF-16 surrogate codepoints", function()
			assert.is_false(utils.is_valid_utf8("\237\160\128")) -- U+D800
			assert.is_false(utils.is_valid_utf8("\237\191\191")) -- U+DFFF
		end)

		it("rejects codepoints above U+10FFFF", function()
			assert.is_false(utils.is_valid_utf8("\244\144\128\128")) -- U+110000
			assert.is_false(utils.is_valid_utf8("\245\128\128\128")) -- 0xF5 lead
		end)

		it("rejects invalid continuation byte", function()
			assert.is_false(utils.is_valid_utf8("\xC0\x00"))
		end)

		it("rejects truncated sequence", function()
			assert.is_false(utils.is_valid_utf8("\xE0\x80"))
		end)
	end)

	describe("uint16 conversion", function()
		it("round-trips 0", function()
			assert.equals(0, utils.bytes_to_uint16(utils.uint16_to_bytes(0)))
		end)

		it("round-trips 256", function()
			assert.equals(256, utils.bytes_to_uint16(utils.uint16_to_bytes(256)))
		end)

		it("round-trips 65535", function()
			assert.equals(65535, utils.bytes_to_uint16(utils.uint16_to_bytes(65535)))
		end)
	end)

	describe("uint64 conversion", function()
		it("round-trips 0", function()
			assert.equals(0, utils.bytes_to_uint64(utils.uint64_to_bytes(0)))
		end)

		it("round-trips 1000000", function()
			assert.equals(1000000, utils.bytes_to_uint64(utils.uint64_to_bytes(1000000)))
		end)
	end)

	describe("apply_mask", function()
		it("masks and unmasks correctly", function()
			local mask = "\x37\xfa\x21\x3d"
			local data = "Hello"
			local masked = utils.apply_mask(data, mask)
			local unmasked = utils.apply_mask(masked, mask)
			assert.equals(data, unmasked)
		end)

		it("handles empty data", function()
			local result = utils.apply_mask("", "\x00\x00\x00\x00")
			assert.equals("", result)
		end)
	end)

	describe("parse_http_headers", function()
		it("parses standard headers", function()
			local request = "GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\n\r\n"
			local headers = utils.parse_http_headers(request)
			assert.equals("localhost", headers["host"])
			assert.equals("websocket", headers["upgrade"])
		end)

		it("normalizes header names to lowercase", function()
			local request = "GET / HTTP/1.1\r\nContent-Type: text/plain\r\n\r\n"
			local headers = utils.parse_http_headers(request)
			assert.equals("text/plain", headers["content-type"])
		end)
	end)

	describe("constant_time_equals", function()
		it("returns true for identical strings", function()
			assert.is_true(utils.constant_time_equals("a-secret-token", "a-secret-token"))
		end)

		it("returns false for same-length differing strings", function()
			assert.is_false(utils.constant_time_equals("a-secret-token", "a-secret-tokem"))
		end)

		it("returns false for different-length strings", function()
			assert.is_false(utils.constant_time_equals("short", "longer-token"))
		end)

		it("returns false for non-string input", function()
			assert.is_false(utils.constant_time_equals(nil, "token"))
		end)
	end)
end)
