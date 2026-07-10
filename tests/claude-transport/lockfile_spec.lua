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

	describe("generate_auth_token", function()
		it("produces a UUID v4 formatted token", function()
			local token = lockfile.generate_auth_token()
			assert.matches("^%x%x%x%x%x%x%x%x%-%x%x%x%x%-4%x%x%x%-[89ab]%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$", token)
		end)

		it("does not derive tokens from math.random", function()
			-- If tokens come from math.random, forcing it constant makes them collide.
			local orig = math.random
			math.random = function()
				return 0
			end
			local ok, t1, t2 = pcall(function()
				return lockfile.generate_auth_token(), lockfile.generate_auth_token()
			end)
			math.random = orig
			assert.is_true(ok)
			assert.is_not.equal(t1, t2)
		end)
	end)

	describe("create", function()
		it("creates the lock file with owner-only permissions", function()
			local ok, path = lockfile.create(45001)
			assert.is_true(ok)
			assert.equals("rw-------", vim.fn.getfperm(path))
		end)

		it("never opens the final lock path for writing (atomic rename)", function()
			local final = tmp .. "/45002.lock"
			local wrote_final = false
			local orig_open = io.open
			io.open = function(p, mode) -- luacheck: ignore
				if p == final and mode and mode:find("w") then
					wrote_final = true
				end
				return orig_open(p, mode)
			end
			local ok = lockfile.create(45002)
			io.open = orig_open -- luacheck: ignore
			assert.is_true(ok)
			assert.is_false(wrote_final)
			local read_ok, token = lockfile.get_auth_token(45002)
			assert.is_true(read_ok)
			assert.is_string(token)
		end)

		it("leaves no temp files behind", function()
			assert.is_true(lockfile.create(45003))
			local leftovers = vim.fn.glob(tmp .. "/*.tmp", true, true)
			assert.equals(0, #leftovers)
		end)
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

		it("removes a corrupt lock file", function()
			local path = tmp .. "/34567.lock"
			local f = assert(io.open(path, "w"))
			f:write("{not valid json")
			f:close()
			lockfile.cleanup_stale()
			assert.equals(0, vim.fn.filereadable(path))
		end)

		it("removes a lock file without a pid", function()
			local path = write_lock(tmp, 45678, { authToken = "token" })
			lockfile.cleanup_stale()
			assert.equals(0, vim.fn.filereadable(path))
		end)
	end)
end)
