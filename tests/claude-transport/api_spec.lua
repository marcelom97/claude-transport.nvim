local api = require("claude-transport.api")

describe("api event emitter", function()
	before_each(function()
		api.clear()
	end)

	it("calls registered listener on emit", function()
		local called = false
		api.on("test", function()
			called = true
		end)
		api.emit("test")
		assert.is_true(called)
	end)

	it("passes arguments to listener", function()
		local received_args = {}
		api.on("test", function(a, b)
			received_args = { a, b }
		end)
		api.emit("test", "hello", 42)
		assert.same({ "hello", 42 }, received_args)
	end)

	it("supports multiple listeners", function()
		local count = 0
		api.on("test", function()
			count = count + 1
		end)
		api.on("test", function()
			count = count + 1
		end)
		api.emit("test")
		assert.equals(2, count)
	end)

	it("removes specific listener with off", function()
		local count = 0
		local fn = function()
			count = count + 1
		end
		api.on("test", fn)
		api.off("test", fn)
		api.emit("test")
		assert.equals(0, count)
	end)

	it("clear removes all listeners", function()
		local count = 0
		api.on("test", function()
			count = count + 1
		end)
		api.clear()
		api.emit("test")
		assert.equals(0, count)
	end)

	it("does not error when emitting event with no listeners", function()
		assert.has_no_error(function()
			api.emit("nonexistent")
		end)
	end)

	it("does not error when removing from nonexistent event", function()
		assert.has_no_error(function()
			api.off("nonexistent", function() end)
		end)
	end)
end)
