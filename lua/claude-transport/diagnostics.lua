local M = {}

M.state = {
	enabled = false,
	server = nil,
	debounce_timer = nil,
	debounce_ms = 500,
	pending_uris = {},
}

function M.enable(server)
	if M.state.enabled then
		return
	end
	M.state.enabled = true
	M.state.server = server
	M._create_autocmds()
end

function M.disable()
	if not M.state.enabled then
		return
	end
	M.state.enabled = false
	M._clear_autocmds()
	M.state.server = nil
	M.state.pending_uris = {}
	if M.state.debounce_timer then
		M.state.debounce_timer:stop()
		M.state.debounce_timer:close()
		M.state.debounce_timer = nil
	end
end

function M.is_enabled()
	return M.state.enabled
end

function M._create_autocmds()
	local group = vim.api.nvim_create_augroup("ClaudeTransportDiagnostics", { clear = true })
	vim.api.nvim_create_autocmd("DiagnosticChanged", {
		group = group,
		callback = function(ev)
			M._on_diagnostics_changed(ev)
		end,
	})
end

function M._clear_autocmds()
	pcall(vim.api.nvim_clear_autocmds, { group = "ClaudeTransportDiagnostics" })
end

function M._on_diagnostics_changed(ev)
	if not M.state.enabled or not M.state.server then
		return
	end

	local bufnr = ev.buf
	if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
		local file_path = vim.api.nvim_buf_get_name(bufnr)
		if file_path and file_path ~= "" then
			M.state.pending_uris["file://" .. file_path] = true
		end
	end

	M._debounce_broadcast()
end

function M._debounce_broadcast()
	if M.state.debounce_timer then
		M.state.debounce_timer:stop()
		M.state.debounce_timer:close()
	end

	M.state.debounce_timer = vim.loop.new_timer()
	M.state.debounce_timer:start(M.state.debounce_ms, 0, vim.schedule_wrap(function()
		M._flush()
	end))
end

function M._flush()
	if not M.state.enabled or not M.state.server then
		M.state.pending_uris = {}
		return
	end

	local uris = {}
	for uri in pairs(M.state.pending_uris) do
		table.insert(uris, uri)
	end
	M.state.pending_uris = {}

	if #uris > 0 then
		M.state.server.broadcast("diagnostics_changed", { uris = uris })
	end

	if M.state.debounce_timer then
		M.state.debounce_timer:stop()
		M.state.debounce_timer:close()
		M.state.debounce_timer = nil
	end
end

return M
