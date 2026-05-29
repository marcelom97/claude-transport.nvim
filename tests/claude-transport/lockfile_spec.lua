local lockfile = require("claude-transport.lockfile")

local function write_lock(dir, port, data)
	local path = dir .. "/" .. port .. ".lock"
	local f = assert(io.open(path, "w"))
	f:write(vim.json.encode(data))
	f:close()
	return path
end

describe("lockfile", function()
	local tmp
	before_each(function()
		tmp = vim.fn.tempname()
		vim.fn.mkdir(tmp, "p")
		lockfile.lock_dir = tmp
	end)
	after_each(function()
		vim.fn.delete(tmp, "rf")
	end)

	describe("is_pid_alive", function()
		it("treats the current process as alive", function()
			assert.is_true(lockfile.is_pid_alive(vim.fn.getpid()))
		end)

		it("treats an unused pid as dead", function()
			assert.is_false(lockfile.is_pid_alive(999999))
		end)

		it("treats a non-number as dead", function()
			assert.is_false(lockfile.is_pid_alive("nope"))
		end)
	end)

	describe("cleanup_stale", function()
		it("removes a lock whose owning process is gone", function()
			local path = write_lock(tmp, 12345, { pid = 999999, authToken = "token" })
			lockfile.cleanup_stale()
			assert.equals(0, vim.fn.filereadable(path))
		end)

		it("keeps a lock whose owning process is alive", function()
			local path = write_lock(tmp, 23456, { pid = vim.fn.getpid(), authToken = "token" })
			lockfile.cleanup_stale()
			assert.equals(1, vim.fn.filereadable(path))
		end)
	end)
end)
