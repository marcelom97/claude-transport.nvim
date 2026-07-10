local check_dirty = require("claude-transport.tools.check_document_dirty")
local open_file = require("claude-transport.tools.open_file")
local workspace_folders = require("claude-transport.tools.get_workspace_folders")
-- Pre-load lazily-required modules: tests below cd away from the repo root,
-- which breaks the relative runtimepath used by the test harness.
require("claude-transport.lockfile")
require("claude-transport.logger")

local function make_dir()
	local dir = vim.fn.tempname()
	vim.fn.mkdir(dir, "p")
	return dir
end

local function decode_first(res)
	return vim.json.decode(res.content[1].text)
end

describe("tools", function()
	local dir

	before_each(function()
		dir = make_dir()
	end)

	after_each(function()
		vim.cmd("normal! \27")
		vim.fn.delete(dir, "rf")
	end)

	describe("checkDocumentDirty buffer lookup", function()
		it("does not match a buffer by path substring", function()
			local full = dir .. "/notes.txt"
			vim.fn.writefile({ "hi" }, full)
			vim.cmd("edit " .. vim.fn.fnameescape(full))

			local res = check_dirty.handler({ filePath = "otes.txt" })
			assert.is_false(decode_first(res).success)
		end)

		it("finds a buffer by exact full path", function()
			local full = dir .. "/notes.txt"
			vim.fn.writefile({ "hi" }, full)
			vim.cmd("edit " .. vim.fn.fnameescape(full))

			local res = check_dirty.handler({ filePath = full })
			local decoded = decode_first(res)
			assert.is_true(decoded.success)
			assert.is_false(decoded.isDirty)
		end)
	end)

	describe("openFile", function()
		it("opens files whose names start with % literally", function()
			local weird = dir .. "/%weird.txt"
			vim.fn.writefile({ "hi" }, weird)
			-- Give % something to expand to if the implementation misuses expand()
			vim.cmd("edit " .. vim.fn.fnameescape(dir .. "/other.txt"))

			local prev = vim.fn.getcwd()
			vim.cmd("cd " .. vim.fn.fnameescape(dir))
			local ok, res = pcall(open_file.handler, { filePath = "%weird.txt" })
			vim.cmd("cd " .. vim.fn.fnameescape(prev))

			assert.is_true(ok)
			assert.matches("%%weird%.txt", res.content[1].text)
		end)

		it("selects the requested line range with 1-based marks", function()
			local full = dir .. "/lines.txt"
			vim.fn.writefile({ "l1", "l2", "l3", "l4", "l5" }, full)

			local ok = pcall(open_file.handler, { filePath = full, startLine = 2, endLine = 3 })
			assert.is_true(ok)
			vim.cmd("normal! \27")
			assert.equals(2, vim.fn.getpos("'<")[2])
			assert.equals(3, vim.fn.getpos("'>")[2])
		end)

		it("finds endText on the same line as startText", function()
			local full = dir .. "/text.txt"
			vim.fn.writefile({ "foo bar baz" }, full)

			local ok, res = pcall(open_file.handler, { filePath = full, startText = "bar", endText = "baz" })
			assert.is_true(ok)
			assert.matches('selected text from "bar" to "baz"', res.content[1].text)
			vim.cmd("normal! \27")
			local s = vim.fn.getpos("'<")
			local e = vim.fn.getpos("'>")
			assert.equals(1, s[2])
			assert.equals(5, s[3]) -- 1-based col of "bar"
			assert.equals(1, e[2])
			assert.equals(11, e[3]) -- 1-based col of last char of "baz"
		end)
	end)

	describe("getLatestSelection", function()
		it("returns valid JSON when no selection exists", function()
			require("claude-transport.selection").state.latest_selection = nil
			local get_latest = require("claude-transport.tools.get_latest_selection")
			local res = get_latest.handler({})
			local ok, decoded = pcall(vim.json.decode, res.content[1].text)
			assert.is_true(ok)
			assert.is_false(decoded.success)
		end)
	end)

	describe("getWorkspaceFolders", function()
		it("emits percent-encoded file URIs", function()
			local spaced = dir .. "/work space"
			vim.fn.mkdir(spaced, "p")
			local prev = vim.fn.getcwd()
			vim.cmd("cd " .. vim.fn.fnameescape(spaced))

			local res = workspace_folders.handler({})
			vim.cmd("cd " .. vim.fn.fnameescape(prev))

			local decoded = decode_first(res)
			assert.matches("work%%20space$", decoded.folders[1].uri)
		end)
	end)
end)
