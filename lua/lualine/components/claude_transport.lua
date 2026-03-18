local lualine_require = require("lualine_require")
local M = lualine_require.require("lualine.component"):extend()

local highlight_groups = {
	green = "DiagnosticOk",
	yellow = "DiagnosticWarn",
	grey = "Comment",
}

function M:init(options)
	M.super.init(self, options)
end

function M:update_status()
	local ok, statusline = pcall(require, "claude-transport.statusline")
	if not ok then
		return ""
	end

	local icon_data = statusline.icon()
	local state = statusline.get()

	local text = icon_data.icon
	if state.running and state.connected then
		text = text .. " connected"
	elseif state.running then
		text = text .. " waiting"
	end

	local hl = highlight_groups[icon_data.color] or "Comment"
	local hl_info = vim.api.nvim_get_hl(0, { name = hl })
	if hl_info and hl_info.fg then
		self.options.color = { fg = hl_info.fg }
	end

	return text
end

return M
