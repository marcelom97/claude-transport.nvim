local selection = require("claude-transport.selection")

local function scratch_buffer(lines)
	vim.cmd("enew!")
	local buf = vim.api.nvim_get_current_buf()
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	return buf
end

describe("selection", function()
	after_each(function()
		-- Leave any lingering visual mode and clean up timers
		vim.cmd("normal! \27")
		if selection.state.debounce_timer then
			pcall(function()
				selection.state.debounce_timer:stop()
				selection.state.debounce_timer:close()
			end)
			selection.state.debounce_timer = nil
		end
		selection.state.latest_selection = nil
	end)

	describe("get_visual_selection", function()
		it("extracts a rectangular block in visual block mode", function()
			scratch_buffer({ "abcd", "efgh", "ijkl" })
			vim.api.nvim_win_set_cursor(0, { 1, 0 })
			vim.cmd("normal! \22jl")
			local sel = selection.get_visual_selection()
			assert.is_table(sel)
			assert.equals("ab\nef", sel.text)
		end)

		it("reports UTF-16 character offsets for multibyte charwise selections", function()
			scratch_buffer({ "αβcd" })
			vim.api.nvim_win_set_cursor(0, { 1, 0 })
			vim.cmd("normal! v2l")
			local sel = selection.get_visual_selection()
			assert.is_table(sel)
			assert.equals("αβc", sel.text)
			-- α and β are 2 bytes but 1 UTF-16 unit each; selection ends after "c"
			assert.equals(0, sel.selection.start.character)
			assert.equals(3, sel.selection["end"].character)
		end)
	end)

	describe("get_cursor_position", function()
		it("reports UTF-16 character offsets for multibyte lines", function()
			scratch_buffer({ "ααx" })
			vim.api.nvim_win_set_cursor(0, { 1, 4 })
			local pos = selection.get_cursor_position()
			assert.equals(2, pos.selection.start.character)
		end)

		it("percent-encodes the fileUrl", function()
			local dir = vim.fn.tempname()
			vim.fn.mkdir(dir, "p")
			local path = dir .. "/a b.txt"
			vim.fn.writefile({ "hello" }, path)
			vim.cmd("edit " .. vim.fn.fnameescape(path))
			local pos = selection.get_cursor_position()
			assert.matches("a%%20b%.txt$", pos.fileUrl)
			vim.fn.delete(dir, "rf")
		end)
	end)

	describe("debounce_update", function()
		it("closes the previous debounce timer instead of leaking it", function()
			selection.debounce_update()
			local t1 = selection.state.debounce_timer
			assert.is_not_nil(t1)
			selection.debounce_update()
			assert.is_true(t1:is_closing())
		end)
	end)
end)
