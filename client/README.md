# client

Native Zuno client on LÖVE 11.5: Windows and Linux now, Android later.
Includes the server, so anyone can host from the app.

```
scripts/build-client.sh        # assembles build/client/ and build/zuno.love
love build/client              # run it
ZUNO_PROFILE=second love build/client   # a second client with its own identity, for testing
scripts/package-windows.sh     # build/dist/Zuno-<version>-win64.zip (Zuno.exe + Zuno Server.exe)
```

| Path | |
|---|---|
| `main.lua`, `conf.lua` | LÖVE entry: wiring, hosting thread, DNS thread, idle-friendly main loop |
| `zuno_native/love_backend.lua` | The LÖVE implementation of the platform API ([ui/PLATFORM.md](../ui/PLATFORM.md)), including text fields |
| `zuno_native/tcp.lua` | Non-blocking TCP transport |
| `zuno_native/host_thread.lua` | Runs the server in a thread for "Host a server" |
| `assets/fonts/` | Inter and Space Grotesk (SIL OFL) |

The UI itself is shared Lua in `ui/zuno_ui/`, so the browser client can run the same code.
Data (identity key, server list, settings) is stored in LÖVE's save folder for `zuno`.
