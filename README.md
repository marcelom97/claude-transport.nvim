# claude-transport.nvim

Headless WebSocket transport layer for [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code). Implements the [MCP protocol](https://modelcontextprotocol.io/) over WebSocket so Claude Code can interact with your Neovim instance — read buffers, track selections, run diagnostics, and more. Pure Lua API, no UI.

## Requirements

- Neovim 0.10+
- LuaJIT (ships with Neovim)
- OpenSSL (`libcrypto`) — used via FFI for WebSocket handshake (SHA-1)

## Install

```lua
-- lazy.nvim
{
  "marcelom97/claude-transport.nvim",
  opts = {},
}
```

## Configuration

```lua
require("claude-transport").setup({
  auto_start = false,             -- start server on setup (default: false)
  port_range = { min = 10000, max = 65535 }, -- random port range
  log_level = "info",             -- trace | debug | info | warn | error
  ping_interval = 30000,          -- WebSocket ping interval in ms
  register_default_tools = true,  -- register built-in MCP tools
})
```

## Commands

| Command | Description |
|---------|-------------|
| `:ClaudeTransportStart` | Start the WebSocket server |
| `:ClaudeTransportStop` | Stop the WebSocket server |
| `:ClaudeTransportStatus` | Show server status (port, connection count) |

## Built-in MCP Tools

These tools are registered by default and exposed to Claude Code via the MCP protocol:

| Tool | Description |
|------|-------------|
| `checkDocumentDirty` | Check if a buffer has unsaved changes |
| `getWorkspaceFolders` | Get workspace folders (CWD + LSP workspace folders) |
| `getDiagnostics` | Get LSP diagnostics for a file |
| `getOpenEditors` | List currently open buffers |
| `getCurrentSelection` | Get the current visual selection or cursor position |
| `getLatestSelection` | Get the most recent selection (persists after leaving visual mode) |
| `openFile` | Open a file in a buffer |
| `saveDocument` | Save a buffer to disk |

## Lua API

```lua
local transport = require("claude-transport")

-- Lifecycle
transport.start()              -- start server, returns (ok, port_or_err)
transport.stop()               -- stop server
transport.is_running()         -- boolean
transport.get_port()           -- port number or nil

-- Connections
transport.is_connected()       -- true if a Claude Code client is connected
transport.get_connections()    -- list of connected client info

-- Messaging
transport.broadcast(method, params)           -- send to all clients
transport.send(connection_id, method, params) -- send to specific client
transport.notify_at_mention(file, start_line, end_line) -- file mention

-- Tools
transport.register_tool(name, schema, handler)
transport.unregister_tool(name)
transport.get_registered_tools()

-- Events
transport.on("connect", function(conn) end)
transport.on("disconnect", function(conn) end)
transport.on("message", function(conn, msg) end)
```

## How It Works

1. On start, the plugin binds a TCP server to a random localhost port
2. A lock file is written to `~/.claude/ide/<port>.lock` with an auth token
3. Claude Code CLI discovers the lock file and connects via WebSocket
4. Communication uses JSON-RPC 2.0 over the MCP protocol (version `2024-11-05`)
5. Selection tracking autocmds keep Claude aware of your cursor/visual selection

## License

MIT License
