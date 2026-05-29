local handshake = require("claude-transport.server.handshake")

describe("WebSocket handshake", function()
	local valid_request = table.concat({
		"GET / HTTP/1.1",
		"Host: localhost:12345",
		"Upgrade: websocket",
		"Connection: Upgrade",
		"Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==",
		"Sec-WebSocket-Version: 13",
		"",
		"",
	}, "\r\n")

	local function make_request(overrides)
		local headers = {
			"GET / HTTP/1.1",
			"Host: localhost:12345",
			"Upgrade: websocket",
			"Connection: Upgrade",
			"Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==",
			"Sec-WebSocket-Version: 13",
		}
		for _, h in ipairs(overrides or {}) do
			table.insert(headers, h)
		end
		table.insert(headers, "")
		table.insert(headers, "")
		return table.concat(headers, "\r\n")
	end

	describe("validate_upgrade_request", function()
		it("accepts valid upgrade request without auth", function()
			local valid, headers = handshake.validate_upgrade_request(valid_request, nil)
			assert.is_true(valid)
			assert.is_table(headers)
		end)

		it("rejects missing Upgrade header", function()
			local bad =
				"GET / HTTP/1.1\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n"
			local valid, err = handshake.validate_upgrade_request(bad, nil)
			assert.is_false(valid)
			assert.matches("Upgrade", err)
		end)

		it("rejects missing Sec-WebSocket-Key", function()
			local bad =
				"GET / HTTP/1.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\n\r\n"
			local valid, err = handshake.validate_upgrade_request(bad, nil)
			assert.is_false(valid)
		end)

		it("rejects wrong WebSocket version", function()
			local bad =
				"GET / HTTP/1.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 8\r\n\r\n"
			local valid, err = handshake.validate_upgrade_request(bad, nil)
			assert.is_false(valid)
		end)

		it("accepts valid auth token", function()
			local req = make_request({ "x-claude-code-ide-authorization: my-valid-auth-token-1234" })
			local valid, headers = handshake.validate_upgrade_request(req, "my-valid-auth-token-1234")
			assert.is_true(valid)
		end)

		it("rejects wrong auth token", function()
			local req = make_request({ "x-claude-code-ide-authorization: wrong-token-value" })
			local valid, err = handshake.validate_upgrade_request(req, "correct-token-value")
			assert.is_false(valid)
			assert.matches("authentication", err:lower())
		end)

		it("rejects missing auth header when token expected", function()
			local valid, err = handshake.validate_upgrade_request(valid_request, "expected-token-1234")
			assert.is_false(valid)
		end)
	end)

	describe("is_websocket_endpoint", function()
		it("accepts GET HTTP/1.1", function()
			assert.is_true(handshake.is_websocket_endpoint(valid_request))
		end)

		it("rejects POST", function()
			local bad = "POST / HTTP/1.1\r\nHost: localhost\r\n\r\n"
			assert.is_false(handshake.is_websocket_endpoint(bad))
		end)

		it("rejects HTTP/1.0", function()
			local bad = "GET / HTTP/1.0\r\nHost: localhost\r\n\r\n"
			assert.is_false(handshake.is_websocket_endpoint(bad))
		end)
	end)

	describe("process_handshake", function()
		it("returns success and 101 response for valid request", function()
			local success, response, headers = handshake.process_handshake(valid_request, nil)
			assert.is_true(success)
			assert.matches("101 Switching Protocols", response)
			assert.matches("Sec%-WebSocket%-Accept", response)
		end)

		it("returns failure for non-GET", function()
			local bad = "POST / HTTP/1.1\r\nUpgrade: websocket\r\n\r\n"
			local success, response, headers = handshake.process_handshake(bad, nil)
			assert.is_false(success)
			assert.matches("404", response)
		end)
	end)

	describe("extract_http_request", function()
		it("finds complete request", function()
			local complete, request, remaining = handshake.extract_http_request(valid_request)
			assert.is_true(complete)
			assert.is_not_nil(request)
		end)

		it("returns false for incomplete request", function()
			local complete, request, remaining = handshake.extract_http_request("GET / HTTP/1.1\r\nHost: loc")
			assert.is_false(complete)
		end)

		it("preserves remaining data", function()
			local data = valid_request .. "extra data"
			local complete, request, remaining = handshake.extract_http_request(data)
			assert.is_true(complete)
			assert.equals("extra data", remaining)
		end)
	end)

	describe("create_error_response", function()
		it("creates 400 response", function()
			local response = handshake.create_error_response(400, "Bad request")
			assert.matches("400 Bad Request", response)
			assert.matches("Bad request", response)
		end)
	end)
end)
