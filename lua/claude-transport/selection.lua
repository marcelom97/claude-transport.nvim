local M = {}

M.state = {
	latest_selection = nil,
	tracking_enabled = false,
	debounce_timer = nil,
	debounce_ms = 100,
	last_active_visual_selection = nil,
	demotion_timer = nil,
	visual_demotion_delay_ms = 50,
}

function M.enable(server, visual_demotion_delay_ms)
	if M.state.tracking_enabled then
		return
	end
	M.state.tracking_enabled = true
	M.server = server
	M.state.visual_demotion_delay_ms = visual_demotion_delay_ms
	M._create_autocommands()
end

function M.disable()
	if not M.state.tracking_enabled then
		return
	end
	M.state.tracking_enabled = false
	M._clear_autocommands()
	M.state.latest_selection = nil
	M.server = nil
	if M.state.debounce_timer then
		M.state.debounce_timer:stop()
		if not M.state.debounce_timer:is_closing() then
			M.state.debounce_timer:close()
		end
		M.state.debounce_timer = nil
	end
	if M.state.demotion_timer then
		M.state.demotion_timer:stop()
		M.state.demotion_timer:close()
		M.state.demotion_timer = nil
	end
end

function M._create_autocommands()
	local group = vim.api.nvim_create_augroup("ClaudeTransportSelection", { clear = true })
	vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "BufEnter", "ModeChanged", "TextChanged" }, {
		group = group,
		callback = function()
			M.debounce_update()
		end,
	})
end

function M._clear_autocommands()
	vim.api.nvim_clear_autocmds({ group = "ClaudeTransportSelection" })
end

local function discard_debounce_timer()
	local t = M.state.debounce_timer
	if t then
		t:stop()
		if not t:is_closing() then
			t:close()
		end
		M.state.debounce_timer = nil
	end
end

function M.debounce_update()
	discard_debounce_timer()
	M.state.debounce_timer = vim.defer_fn(function()
		M.state.debounce_timer = nil
		M.update_selection()
	end, M.state.debounce_ms)
end

local function cancel_demotion_timer()
	local t = M.state.demotion_timer
	if t then
		t:stop()
		t:close()
		M.state.demotion_timer = nil
	end
end

local function is_visual_mode(mode)
	return mode == "v" or mode == "V" or mode == "\022"
end

local function handle_visual_mode(bufnr)
	cancel_demotion_timer()
	local sel = M.get_visual_selection()
	if sel then
		M.state.last_active_visual_selection = {
			bufnr = bufnr,
			selection_data = vim.deepcopy(sel),
			timestamp = vim.loop.now(),
		}
	elseif M.state.last_active_visual_selection and M.state.last_active_visual_selection.bufnr == bufnr then
		M.state.last_active_visual_selection = nil
	end
	return sel
end

local function handle_normal_mode(bufnr)
	local last = M.state.last_active_visual_selection

	if M.state.demotion_timer then
		return M.get_cursor_position()
	end

	if last and last.bufnr == bufnr and last.selection_data and not last.selection_data.selection.isEmpty then
		M.state.demotion_timer = vim.loop.new_timer()
		M.state.demotion_timer:start(
			M.state.visual_demotion_delay_ms,
			0,
			vim.schedule_wrap(function()
				cancel_demotion_timer()
				M._handle_demotion(bufnr)
			end)
		)
		return M.state.latest_selection
	end

	if last and last.bufnr == bufnr then
		M.state.last_active_visual_selection = nil
	end
	return M.get_cursor_position()
end

function M.update_selection()
	if not M.state.tracking_enabled then
		return
	end

	local bufnr = vim.api.nvim_get_current_buf()
	local buf_name = vim.api.nvim_buf_get_name(bufnr)

	if buf_name and buf_name:match("^term://") then
		cancel_demotion_timer()
		return
	end

	local mode = vim.api.nvim_get_mode().mode
	local sel = is_visual_mode(mode) and handle_visual_mode(bufnr) or handle_normal_mode(bufnr)

	if not sel then
		sel = M.get_cursor_position()
	end

	if M.has_selection_changed(sel) then
		M.state.latest_selection = sel
		if M.server then
			M.server.broadcast("selection_changed", sel)
		end
	end
end

function M._handle_demotion(original_bufnr)
	local bufnr = vim.api.nvim_get_current_buf()
	local buf_name = vim.api.nvim_buf_get_name(bufnr)

	if buf_name and buf_name:match("^term://") then
		M.state.last_active_visual_selection = nil
		return
	end

	if bufnr == original_bufnr and is_visual_mode(vim.api.nvim_get_mode().mode) then
		M.state.last_active_visual_selection = nil
		return
	end

	if bufnr == original_bufnr then
		local cursor_sel = M.get_cursor_position()
		if M.has_selection_changed(cursor_sel) then
			M.state.latest_selection = cursor_sel
			if M.server then
				M.server.broadcast("selection_changed", cursor_sel)
			end
		end
	end

	if M.state.last_active_visual_selection and M.state.last_active_visual_selection.bufnr == original_bufnr then
		M.state.last_active_visual_selection = nil
	end
end

---Convert a 0-based byte column to a 0-based UTF-16 code-unit offset (LSP semantics).
---@param line string|nil The line the column refers to
---@param byte_col number 0-based byte offset into the line
---@return number utf16_col
local function utf16_col(line, byte_col)
	if not line or byte_col <= 0 then
		return 0
	end
	local idx = math.min(byte_col, #line)
	-- Neovim 0.11+ signature
	local ok, res = pcall(vim.str_utfindex, line, "utf-16", idx, false)
	if ok and type(res) == "number" then
		return res
	end
	-- Neovim 0.10 signature: returns (utf32, utf16)
	local ok2, _, u16 = pcall(vim.str_utfindex, line, idx)
	if ok2 and type(u16) == "number" then
		return u16
	end
	return byte_col
end

local function file_url(file_path)
	if not file_path or file_path == "" then
		return ""
	end
	local ok, uri = pcall(vim.uri_from_fname, file_path)
	return ok and uri or ("file://" .. file_path)
end

local function get_selection_coords()
	local anchor = vim.fn.getpos("v")
	local cursor = vim.api.nvim_win_get_cursor(0)
	local p1 = { lnum = anchor[2], col = anchor[3] }
	local p2 = { lnum = cursor[1], col = cursor[2] + 1 }

	if p1.lnum < p2.lnum or (p1.lnum == p2.lnum and p1.col <= p2.col) then
		return p1, p2
	end
	return p2, p1
end

function M.get_visual_selection()
	local mode = vim.api.nvim_get_mode().mode
	if not is_visual_mode(mode) then
		return nil
	end

	local anchor = vim.fn.getpos("v")
	if anchor[2] == 0 then
		return nil
	end

	-- mode from nvim_get_mode() is the live visual mode; vim.fn.visualmode()
	-- only reports the last *completed* selection and can be stale here.
	local vmode = mode

	local s, e = get_selection_coords()
	local bufnr = vim.api.nvim_get_current_buf()
	local file_path = vim.api.nvim_buf_get_name(bufnr)
	local lines = vim.api.nvim_buf_get_lines(bufnr, s.lnum - 1, e.lnum, false)
	if #lines == 0 then
		return nil
	end

	local text, lsp_start_char, lsp_end_char

	if vmode == "V" then
		text = table.concat(lines, "\n")
		lsp_start_char = 0
		lsp_end_char = utf16_col(lines[#lines], #lines[#lines])
	elseif vmode == "\22" then
		-- Visual block: extract the rectangular column range from every line.
		local c1 = math.min(s.col, e.col)
		local c2 = math.max(s.col, e.col)
		local parts = {}
		for i = 1, #lines do
			parts[i] = string.sub(lines[i], c1, c2)
		end
		text = table.concat(parts, "\n")
		lsp_start_char = utf16_col(lines[1], c1 - 1)
		lsp_end_char = utf16_col(lines[#lines], c2)
	elseif vmode == "v" then
		if s.lnum == e.lnum then
			text = lines[1] and string.sub(lines[1], s.col, e.col)
		else
			local parts = { string.sub(lines[1], s.col) }
			for i = 2, #lines - 1 do
				parts[#parts + 1] = lines[i]
			end
			parts[#parts + 1] = string.sub(lines[#lines], 1, e.col)
			text = table.concat(parts, "\n")
		end
		if not text then
			return nil
		end
		lsp_start_char = utf16_col(lines[1], s.col - 1)
		lsp_end_char = utf16_col(lines[#lines], e.col)
	else
		return nil
	end

	return {
		text = text or "",
		filePath = file_path,
		fileUrl = file_url(file_path),
		selection = {
			start = { line = s.lnum - 1, character = lsp_start_char },
			["end"] = { line = e.lnum - 1, character = lsp_end_char },
			isEmpty = (not text or #text == 0),
		},
	}
end

function M.get_cursor_position()
	local pos = vim.api.nvim_win_get_cursor(0)
	local bufnr = vim.api.nvim_get_current_buf()
	local file_path = vim.api.nvim_buf_get_name(bufnr)
	local line = vim.api.nvim_buf_get_lines(bufnr, pos[1] - 1, pos[1], false)[1]
	local character = utf16_col(line, pos[2])
	return {
		text = "",
		filePath = file_path,
		fileUrl = file_url(file_path),
		selection = {
			start = { line = pos[1] - 1, character = character },
			["end"] = { line = pos[1] - 1, character = character },
			isEmpty = true,
		},
	}
end

function M.has_selection_changed(new)
	local old = M.state.latest_selection
	if not new then
		return old ~= nil
	end
	if not old then
		return true
	end
	if old.filePath ~= new.filePath then
		return true
	end
	if old.text ~= new.text then
		return true
	end
	local os, ns = old.selection, new.selection
	return os.start.line ~= ns.start.line
		or os.start.character ~= ns.start.character
		or os["end"].line ~= ns["end"].line
		or os["end"].character ~= ns["end"].character
end

function M.get_latest_selection()
	return M.state.latest_selection
end

return M
