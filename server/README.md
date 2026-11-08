# server

Standalone Zuno server. Plain LuaJIT + LuaSocket, no LÖVE needed, so it runs headless on a PC, VPS, dedicated server or NAS.

Targets: Windows x64, Linux x64, Linux ARM64.
Storage: SQLite. Exposed to the internet with a playit.gg TCP tunnel (plus a UDP tunnel for voice), or a normal open port.
