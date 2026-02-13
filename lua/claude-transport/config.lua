local M = {}

M.defaults = {
	port_range = { min = 10000, max = 65535 },
	auto_start = false,
	log_level = "info",
	ping_interval = 30000,
	register_default_tools = true,
}

function M.validate(config)
	assert(
		type(config.port_range) == "table"
			and type(config.port_range.min) == "number"
			and type(config.port_range.max) == "number"
			and config.port_range.min > 0
			and config.port_range.max <= 65535
			and config.port_range.min <= config.port_range.max,
		"Invalid port range"
	)

	assert(type(config.auto_start) == "boolean", "auto_start must be a boolean")

	local valid_log_levels = { "trace", "debug", "info", "warn", "error" }
	local is_valid_log_level = false
	for _, level in ipairs(valid_log_levels) do
		if config.log_level == level then
			is_valid_log_level = true
			break
		end
	end
	assert(is_valid_log_level, "log_level must be one of: " .. table.concat(valid_log_levels, ", "))

	assert(
		type(config.ping_interval) == "number" and config.ping_interval > 0,
		"ping_interval must be a positive number"
	)

	assert(type(config.register_default_tools) == "boolean", "register_default_tools must be a boolean")

	return true
end

function M.apply(user_config)
	local config = vim.deepcopy(M.defaults)

	if user_config then
		if user_config.port_range then
			if type(user_config.port_range) == "table" then
				if user_config.port_range[1] and user_config.port_range[2] then
					config.port_range = { min = user_config.port_range[1], max = user_config.port_range[2] }
				else
					config.port_range = vim.tbl_deep_extend("force", config.port_range, user_config.port_range)
				end
			end
			local filtered = vim.deepcopy(user_config)
			filtered.port_range = nil
			config = vim.tbl_deep_extend("force", config, filtered)
		else
			config = vim.tbl_deep_extend("force", config, user_config)
		end
	end

	M.validate(config)
	return config
end

return M
