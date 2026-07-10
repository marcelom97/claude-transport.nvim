-- Minimal test: load the plugin and start the server
vim.opt.rtp:prepend(".")

local transport = require("claude-transport")
transport.setup({
	auto_start = false,
	log_level = "debug",
})

local ok, result = transport.start()
if ok then
	print("Server started on port: " .. tostring(result))
	print("Running: " .. tostring(transport.is_running()))
	print("Connected: " .. tostring(transport.is_connected()))
	print("Tools: " .. vim.inspect(transport.get_registered_tools()))

	transport.on("connect", function(conn)
		print("Client connected: " .. conn.id)
	end)

	-- Stop after a brief pause
	vim.defer_fn(function()
		transport.stop()
		print("Server stopped")
		print("Running: " .. tostring(transport.is_running()))
		vim.cmd("qa!")
	end, 1000)
else
	print("Failed to start: " .. tostring(result))
	vim.cmd("cq!")
end
