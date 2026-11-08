# Hosting a Zuno server

A Zuno server is a small program that stores your community's channels and messages.
Run it wherever suits you, then share its address.

| Where | How | Online |
|---|---|---|
| Your own PC | "Start server" in the Zuno app, or `Zuno Server.exe` | While it's running |
| VPS / dedicated server | Linux: `luajit server/run.lua` | Always |
| NAS / Raspberry Pi | Linux x64 or ARM64: `luajit server/run.lua` | Always |

## 1. Start the server

### From the Zuno app (easiest)
Open the **+** tab, fill in a name and port (41234 by default) and press **Start server**.
You become the owner automatically. The server stays up while Zuno is open, and starts again
the next time you open Zuno until you press **Stop server**.

### Windows, without the app window
Run `Zuno Server.exe` from the Windows download. It opens a console window with the log.
Data is kept in the `server-data` folder next to it.

```
"Zuno Server.exe" --port 41234 --name "My server" --data D:\zuno-data
```

### Linux (VPS, dedicated server, NAS, Raspberry Pi)
```
sudo apt install luajit lua-socket libsqlite3-0 build-essential git
git clone https://github.com/MightyX3N/Zuno.git && cd Zuno
scripts/build-native.sh            # builds the crypto library (Monocypher)
luajit server/run.lua --port 41234 --name "My server"
```
Data goes to `server/data/` (change it with `--data /path`). To keep it running after you log
out, use a systemd service:

```ini
# /etc/systemd/system/zuno.service
[Unit]
Description=Zuno server
After=network-online.target

[Service]
WorkingDirectory=/home/zuno/Zuno
ExecStart=/usr/bin/luajit server/run.lua --data /home/zuno/zuno-data
User=zuno
Restart=on-failure

[Install]
WantedBy=multi-user.target
```
`sudo systemctl enable --now zuno`, logs with `journalctl -u zuno -f`.

## 2. Become the owner

The first start prints a claim code:

```
no owner yet. To become the owner, connect with Zuno and send:  /claim K7QM-9XTD
```

Connect with Zuno and type `/claim K7QM-9XTD` in any channel. The code works once.
(Hosting from the app skips this step.)

Owner commands, typed in the message box:

| Command | |
|---|---|
| `/create name [topic]` | New text channel |
| `/create-voice name` | New voice channel (voice itself arrives later) |
| `/topic text` | Set the current channel's topic |
| `/rename name` | Rename the current channel |
| `/delete-channel` | Delete the current channel and its messages |

Anyone can use `/nick name` and `/help`.

## 3. Let people in

### At home: playit.gg (no port forwarding)
1. Install the playit.gg agent and sign in.
2. Add a tunnel: type **TCP**, local port = your Zuno port (41234).
3. playit gives you an address like `name.at.ply.gg:41234`. Send that to your friends.
   They paste it in Zuno's **Join a server** box.

The free plan is enough. A UDP tunnel for voice will be needed once voice arrives.

### VPS or dedicated server
Open the port in the firewall (`sudo ufw allow 41234/tcp`) and share `your-ip-or-domain:41234`.

### Sharing a verified address
Every server has its own identity key. Zuno remembers it on first connect and warns loudly if it
ever changes. To protect even the first connect, add the fingerprint to the address you share:
`name.at.ply.gg:41234#<first 20 characters of the server key>`. The easy way: click the address in
the app's info panel (right side) to copy a ready invite. The server log also prints the
`#...` part on start.

## 4. Settings

`config.lua` in the data folder (created on first start):

| Setting | Default | |
|---|---|---|
| `name` | My Zuno server | Shown to everyone |
| `port` | 41234 | TCP port |
| `bind` | `*` | `127.0.0.1` = only this machine |
| `max_connections` | 200 | |
| `max_connections_per_ip` | 0 (off) | Keep 0 behind playit: everyone shares playit's IP |
| `handshake_timeout` | 10 s | |
| `idle_timeout` | 120 s | Clients ping every 25 s |

Restart the server after editing.

## 5. Backups and moving

Everything lives in the data folder:

| File | |
|---|---|
| `server.key` | The server's identity. **Keep it safe and private.** Lose it and every member sees an "identity changed" warning |
| `zuno.db` | Channels, members and messages (SQLite) |
| `config.lua` | Settings |

To back up or move hosts, stop the server and copy the whole folder. Start the server on the new
machine with `--data` pointing at the copy; members won't see a warning because the key moved
with it. (A one-command backup is planned.)

## What the server can and can't see

Traffic between Zuno and the server is encrypted (Noise protocol), so playit.gg and the network
can't read it. The server itself stores channel messages so new devices can load history; the
person hosting is the community's owner, like any self-hosted chat. Direct messages and file
transfers, when they arrive, are end-to-end encrypted.
