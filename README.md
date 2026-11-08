# Zuno

Self-hosted chat with text channels, voice and moddable layouts, built in Lua.
Anyone can host a server: on their own PC through [playit.gg](https://playit.gg), or on a VPS, dedicated server or NAS.

Website: https://zuno.dovecross.site

## Repository layout

| Folder | What it is |
|---|---|
| `protocol/` | Wire protocol spec and shared Lua code (framing, packets) used by server and clients |
| `server/` | Standalone server (LuaJIT + LuaSocket). Runs on Windows, Linux x64 and Linux ARM64 |
| `client/` | Native client built on LÖVE: Windows, Linux and Android. Can also host a server |
| `ui/` | Shared Lua UI (components, layout engine, platform API), run by both the LÖVE and browser clients |
| `web/` | Website and browser client, deployed to GitHub Pages (`/` homepage, `/app/` client) |
| `layouts/` | Built-in layout packs: `tabs` (default), `terminal`, `messenger`, `deck` |
| `native/` | Vendored C (Monocypher) built into the crypto library |
| `scripts/` | Build and packaging scripts |
| `tests/` | Test suites |
| `docs/` | Hosting, modding and protocol documentation |

## Status

**Phase 1 works: encrypted text chat.** Servers, channels, history, editing, typing, presence,
unread markers, hosting from the app, light and dark mode.
**Phase 2 in progress:** account backup files with a recovery key, linking a second device
(QR or typed code), "Replace my key", and streamer mode work. Voice, files, layouts and mobile come next.
See [PLAN.md](PLAN.md) for everything planned and done.

## Try it

| | |
|---|---|
| Host a server | [docs/hosting.md](docs/hosting.md) |
| Run the client from source | `scripts/build-client.sh && love build/client` (needs LÖVE 11.5) |
| Run a server from source | `scripts/build-native.sh && luajit server/run.lua` (needs `luajit lua-socket libsqlite3-0`) |
| Windows test build | `scripts/package-windows.sh` → `build/dist/Zuno-…-win64.zip` |
| Tests | `luajit tests/run.lua` and `lua5.4 tests/run.lua --shared` |

---
A DoveCross project.
