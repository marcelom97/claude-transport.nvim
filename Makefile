.PHONY: test lint format smoke

test:
	nvim --headless --noplugin -u tests/minimal_init.lua -c "PlenaryBustedDirectory tests/"

lint:
	luacheck lua tests
	stylua --check lua/ tests/ scripts/

format:
	stylua lua/ tests/ scripts/

smoke:
	nvim --headless --noplugin -u scripts/smoke.lua
