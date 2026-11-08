# server

Standalone Zuno server: LuaJIT + LuaSocket, SQLite through LuaJIT FFI, Monocypher for crypto.
Runs headless on a PC, VPS, dedicated server or NAS. Setup guide: [docs/hosting.md](../docs/hosting.md).

```
scripts/build-native.sh                     # once: builds build/native/linux-x64/libzunocrypto.so
luajit server/run.lua [--data DIR] [--port N] [--bind ADDR] [--name NAME]
```

| Path | |
|---|---|
| `run.lua` | Command-line entry (Linux / macOS / anything with LuaJIT) |
| `love/` | Same server on the LÖVE runtime, no window. Used for `Zuno Server.exe` on Windows |
| `zuno_server/server.lua` | Network loop (non-blocking sockets + `select`), sessions, rate limits, all packet handlers |
| `zuno_server/store.lua` | SQLite schema and queries |
| `zuno_server/sqlite.lua` | Minimal SQLite FFI binding |
| `zuno_server/config.lua` | `config.lua` loading (sandboxed) and first-run defaults |

The same `Server` module also runs inside the desktop client for "Host a server"
(`client/zuno_native/host_thread.lua`).
