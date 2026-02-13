local M = {}

M.ERROR_CODES = {
	PARSE_ERROR = -32700,
	INVALID_REQUEST = -32600,
	METHOD_NOT_FOUND = -32601,
	INVALID_PARAMS = -32602,
	INTERNAL_ERROR = -32000,
}

M.tools = {}

function M.setup(server)
	M.server = server
end

function M.register_defaults()
	M.register(require("claude-transport.tools.open_file"))
	M.register(require("claude-transport.tools.get_current_selection"))
	M.register(require("claude-transport.tools.get_open_editors"))
	M.register(require("claude-transport.tools.get_latest_selection"))
	M.register(require("claude-transport.tools.get_diagnostics"))
	M.register(require("claude-transport.tools.get_workspace_folders"))
	M.register(require("claude-transport.tools.check_document_dirty"))
	M.register(require("claude-transport.tools.save_document"))
end

function M.get_tool_list()
	local tool_list = {}
	for name, tool_data in pairs(M.tools) do
		if tool_data.schema then
			table.insert(tool_list, {
				name = name,
				description = tool_data.schema.description,
				inputSchema = tool_data.schema.inputSchema,
			})
		end
	end
	return tool_list
end

function M.register(tool_module)
	if not tool_module or not tool_module.name or not tool_module.handler then
		return
	end
	M.tools[tool_module.name] = {
		handler = tool_module.handler,
		schema = tool_module.schema,
		requires_coroutine = tool_module.requires_coroutine,
	}
end

function M.register_tool(name, schema, handler)
	M.tools[name] = {
		handler = handler,
		schema = schema,
	}
end

function M.unregister_tool(name)
	M.tools[name] = nil
end

function M.handle_invoke(client, params)
	local tool_name = params.name
	local input = params.arguments

	if not M.tools[tool_name] then
		return {
			error = {
				code = -32601,
				message = "Tool not found: " .. tool_name,
			},
		}
	end

	local api = require("claude-transport.api")
	api.emit("tool_call", client, tool_name, input)

	local tool_data = M.tools[tool_name]
	local pcall_results

	if tool_data.requires_coroutine then
		local co = coroutine.create(function()
			return tool_data.handler(input)
		end)
		local success, result = coroutine.resume(co)
		if coroutine.status(co) == "suspended" then
			return { _deferred = true, coroutine = co, client = client, params = params }
		end
		pcall_results = { success, result }
	else
		pcall_results = { pcall(tool_data.handler, input) }
	end

	local pcall_success = pcall_results[1]
	local handler_return_val1 = pcall_results[2]
	local handler_return_val2 = pcall_results[3]

	if not pcall_success then
		local err_code = M.ERROR_CODES.INTERNAL_ERROR
		local err_msg = "Tool execution failed"
		local err_data_payload = tostring(handler_return_val1)
		if type(handler_return_val1) == "table" and handler_return_val1.code and handler_return_val1.message then
			err_code = handler_return_val1.code
			err_msg = handler_return_val1.message
			err_data_payload = handler_return_val1.data
		elseif type(handler_return_val1) == "string" then
			err_msg = handler_return_val1
		end
		return { error = { code = err_code, message = err_msg, data = err_data_payload } }
	end

	if handler_return_val1 == false then
		local err_val = handler_return_val2
		local err_code = M.ERROR_CODES.INTERNAL_ERROR
		local err_msg = "Tool reported an error"
		local err_data_payload = tostring(err_val)
		if type(err_val) == "table" and err_val.code and err_val.message then
			err_code = err_val.code
			err_msg = err_val.message
			err_data_payload = err_val.data
		elseif type(err_val) == "string" then
			err_msg = err_val
		end
		return { error = { code = err_code, message = err_msg, data = err_data_payload } }
	end

	return { result = handler_return_val1 }
end

return M
