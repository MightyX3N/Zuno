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
| `zuno_native/files.lua` | System Open / Save dialogs and Unicode-safe file access |
| `zuno_native/notify.lua` | Desktop notifications (Windows tray balloon, `notify-send`, macOS) and taskbar flash |
| `assets/fonts/` | Inter (with italics), Space Grotesk and JetBrains Mono for code (SIL OFL) |
| `assets/emoji/` | Twemoji sheet (CC-BY 4.0), rebuilt with `scripts/build-emoji.py` |
| `assets/icon/` | App icon (window, Windows tray) |

`ZUNO_DEBUG_NOTIFY=1` prints every notification to the console (handy where no notification service runs).

The UI itself is shared Lua in `ui/zuno_ui/`, so the browser client can run the same code.
Data (identity key, server list, settings) is stored in LÖVE's save folder for `zuno`.
