local M = {}

local listeners = {}

function M.on(event, callback)
	if not listeners[event] then
		listeners[event] = {}
	end
	table.insert(listeners[event], callback)
end

function M.off(event, callback)
	if not listeners[event] then
		return
	end
	for i, cb in ipairs(listeners[event]) do
		if cb == callback then
			table.remove(listeners[event], i)
			return
		end
	end
end

function M.emit(event, ...)
	if not listeners[event] then
		return
	end
	for _, callback in ipairs(listeners[event]) do
		local ok, err = pcall(callback, ...)
		if not ok then
			local logger = require("claude-transport.logger")
			logger.error("api", "Event callback error for '" .. event .. "': " .. tostring(err))
		end
	end
end

function M.clear()
	listeners = {}
end

return M
