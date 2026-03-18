--- Tool implementation for getting workspace folders.

local schema = {
	description = "Get all workspace folders currently open in the IDE",
	inputSchema = {
		type = "object",
		additionalProperties = false,
		["$schema"] = "http://json-schema.org/draft-07/schema#",
	},
}

---Handles the getWorkspaceFolders tool invocation.
---Retrieves workspace folders, currently defaulting to CWD and attempting LSP integration.
---@return table MCP-compliant response with workspace folders data
local function handler(params)
	local lockfile = require("claude-transport.lockfile")
	local paths = lockfile.get_workspace_folders()

	local folders = {}
	for _, path in ipairs(paths) do
		table.insert(folders, {
			name = vim.fn.fnamemodify(path, ":t"),
			uri = "file://" .. path,
			path = path,
		})
	end

	local root_path = paths[1] or vim.fn.getcwd()

	return {
		content = {
			{
				type = "text",
				text = vim.json.encode({
					success = true,
					folders = folders,
					rootPath = root_path,
				}, { indent = 2 }),
			},
		},
	}
end

return {
	name = "getWorkspaceFolders",
	schema = schema,
	handler = handler,
}
