--- Shared helpers for MCP tool implementations.

local M = {}

---Resolve a file path (absolute, relative, or ~-prefixed) to a loaded buffer
---by exact path comparison. Avoids vim.fn.bufnr()'s file-pattern matching,
---which can resolve a substring to the wrong buffer.
---@param file_path string
---@return integer bufnr The buffer number, or -1 if no buffer has that file open
function M.find_buffer(file_path)
	if type(file_path) ~= "string" or file_path == "" then
		return -1
	end
	local target = vim.fn.fnamemodify(file_path, ":p")
	-- Buffer names hold resolved paths (e.g. /var -> /private/var on macOS)
	local resolved = vim.loop.fs_realpath(target) or target
	for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_loaded(bufnr) then
			local name = vim.api.nvim_buf_get_name(bufnr)
			if name == target or name == resolved then
				return bufnr
			end
		end
	end
	return -1
end

return M
