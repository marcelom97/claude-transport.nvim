std = "luajit"
cache = true
codes = true

read_globals = { "vim" }

max_line_length = false

-- Handlers and callbacks intentionally accept arguments they may not use
-- (e.g. JSON-RPC handlers take (client, params)).
ignore = {
	"212", -- unused argument
	"122", -- setting a read-only field of a global (vim.*)
}

files["tests/**/*_spec.lua"] = {
	std = "+busted",
	-- Specs frequently unpack tuples and bind only some values
	-- (e.g. `local parsed, consumed = ...`); unused-variable noise is not useful here.
	ignore = { "211", "212", "213" },
}
