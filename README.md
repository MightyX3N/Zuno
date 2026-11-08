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
| `web/` | Website and browser client, deployed to GitHub Pages (`/` homepage, `/app/` client) |
| `layouts/` | Built-in layout packs: `tabs` (default), `terminal`, `messenger`, `deck` |
| `docs/` | Hosting, modding and protocol documentation |

## Status

Early development. Nothing is released yet.

---
A DoveCross project.
