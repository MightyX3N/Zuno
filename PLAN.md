# Zuno: master plan

Everything decided so far, and every task left to do. Tick boxes as work lands.
If a decision changes, update it here in the same commit.

Website: https://zuno.dovecross.site (homepage) · https://zuno.dovecross.site/app/ (browser client)
Repo: https://github.com/MightyX3N/Zuno · Studio: DoveCross · Author: MightyX3N

---

## 1. What Zuno is

- Self-hosted chat app: text channels, voice channels, file sharing, roles.
- Does **not** look like Discord. Each server can ship its own layout (modding).
- No central company server. Anyone hosts a server: on their PC through **playit.gg**, or on a VPS, dedicated server or NAS.
- Built in **Lua**.

## 2. Decisions (locked unless changed here)

| Topic | Decision |
|---|---|
| Name | Zuno |
| Native client | LÖVE 11.5 (LuaJIT): Windows, Linux, Android |
| Browser client | Plain HTML/CSS/JS UI + **Wasmoon** (Lua 5.4 in WASM) to run shared Lua and layout scripts. Not love.js (no JS FFI, ~10–15 MB, bad iOS keyboard) |
| iOS | Through the browser client (Safari, add to home screen). No native iOS app |
| Server | Standalone **LuaJIT + LuaSocket**, no LÖVE. Targets Windows x64, Linux x64, Linux ARM64 (NAS / Raspberry Pi) |
| Client hosting | Desktop client bundles the `server/` package and has a "Host a server" button |
| Storage (server) | SQLite via LuaJIT FFI |
| Crypto | Monocypher via FFI (X25519, XChaCha20-Poly1305, Ed25519, Argon2). Browser: matching JS/WASM implementation |
| Voice codec | Opus (libopus via FFI; WebCodecs in browser) |
| Wire format | `u32` length prefix + MessagePack body |
| Transport | Raw TCP for native clients, WebSocket for browser, **same port**: server sniffs first bytes (`GET ` = WebSocket upgrade) |
| Voice transport | UDP (native) / Opus frames over the WebSocket (browser) |
| Default layout | **Tabs** (light, servers as tabs along the top) |
| Website hosting | GitHub Pages via Actions, deploys `web/`. Custom domain `zuno.dovecross.site` |
| Docker | Not used |

## 3. playit.gg facts that shape the design

- Free plan: raw **TCP and UDP** tunnels only. HTTPS tunnels need Premium → no HTTP/WebSocket-over-TLS for free from playit.
- Addresses are stable, e.g. `name.at.ply.gg:41234` → used as the server's invite address.
- Free tier allows a handful of tunnels; a Zuno server needs **1 TCP** (everything) **+ 1 UDP** (voice, optional).
- Tunnel traffic is not encrypted → Zuno encrypts everything itself.
- Server sees playit's IP, not the user's → bans are by identity key, not IP (Proxy Protocol optional later).

### 3.1 playit Premium must be supported too
Zuno works on the free plan, but if the host has Premium, Zuno uses what it adds:

| Premium feature | How Zuno uses it |
|---|---|
| **HTTPS tunnels** | playit terminates TLS → browser clients connect with `wss://` straight to the playit HTTPS address. Server receives plain WebSocket behind the tunnel (no own cert needed). Gives full browser support incl. voice without the host owning a domain |
| **Custom domains** | Invite address can be the host's own domain (e.g. `chat.example.com`) on TCP/UDP or HTTPS tunnels |
| **Dedicated IP** | Works as a normal address; nothing special needed |
| **More tunnels / ports** | Optional separate ports per service (e.g. dedicated file-transfer port) if the host wants |

- Server config has a **connection setup** section where the host enters each public address and what it is: `tcp` (native clients), `udp` (voice), `https` (browser via playit HTTPS tunnel), plus optional custom domain.
- The invite / server info sent to clients lists all available addresses; each client picks the one it can use (native → TCP/UDP, browser → HTTPS/`wss`).
- Server accepts WebSocket both directly (own TLS or plain) and behind a TLS-terminating tunnel (trust `X-Forwarded-*` only from the tunnel when enabled).

## 4. Browser client constraints (important)

- Browsers can't open raw TCP/UDP → browser uses **WebSocket** on the same server port.
- GitHub Pages is HTTPS → browser may only use **`wss://`** → server needs a valid TLS certificate.
- Can't get a cert for `*.at.ply.gg`. So:
  - **Host has playit Premium**: use a playit **HTTPS tunnel** → full browser support incl. voice, no cert work (see 3.1).
  - **Server owner has a domain** (e.g. `chat.example.com` CNAME → playit tunnel): server gets a Let's Encrypt cert via DNS-01 and terminates TLS itself → full browser support incl. voice. (Verify playit free tier accepts a CNAME'd domain; else Premium.)
  - **No domain**: server can serve the web client itself over plain `http://name.at.ply.gg:port` → `ws://` works. Text chat yes; **no voice** (mic needs a secure context). App-level encryption still applies.
- Browser voice = Opus over WebSocket (TCP), slightly higher latency.

## 5. Identity, accounts and devices

- Identity = **Ed25519 master key** generated on first launch. No usernames/passwords, no central accounts.
- Login to a server = sign a random server challenge. Bans, roles, permissions are tied to the public key.
- Message history lives on servers → new devices see history automatically.
- **All devices are equal**: every linked device holds the full account (master key, profile, server list, settings, layout choices).

### 5.1 Link a device by QR code
1. Logged-in device → "Link a device" → shows QR. QR holds only a **temporary key + session ID + one of the user's server addresses**. Never the account itself.
2. QR content is a link: `https://zuno.dovecross.site/link#<payload>` (fragment is never sent to the web host).
   - Android: system camera opens it in the Zuno app (Android App Links; host `/.well-known/assetlinks.json` on Pages).
   - iPhone/browser: opens the web client, which finishes the link.
   - No camera (desktop): fallback short code typed by hand.
3. Both devices meet through that Zuno server, which relays encrypted bytes only.
4. New device shows a **6-digit code**; the old device asks the user to **type it in**. Nothing is sent until the code matches. (A viewer who scans a streamed QR gets a different code the streamer never sees.)
5. On approval: full account package sent end-to-end encrypted. No recovery key needed in transit.
6. **One scan only**: QR dies on first scan. A second scan attempt cancels the link and warns "Someone else tried to use this link code". Expires after 2 minutes regardless.

### 5.2 Backup / transfer file
- Settings → "Export account" → `<name>.zunokey` file (same contents as the QR package).
- Encrypted with a generated **recovery key** (e.g. `K7QM-9XTD-4HPA-W2RE-8NVC`), shown once, with Copy / Save / Print. Key derived with Argon2id, data sealed with XChaCha20-Poly1305.
- "Import account" = pick file + enter recovery key.
- UI must state clearly: lose both file and key and the account is gone (no reset possible).

### 5.3 Lost / stolen device
- "Replace my key": a remaining device generates a new master key, signs a hand-over with the old key, pushes it to all the user's servers; servers then accept only the new key.
- First valid hand-over wins; disputes resolved by the server owner (owner tools needed).

### 5.4 Streamer mode
- Blurs link QR, recovery key, server addresses and other sensitive details; click-and-hold to reveal; Copy buttons so secrets never need to be on screen.
- Auto-enables on desktop when OBS / Streamlabs is running; manual toggle everywhere.

## 6. Layouts and modding

- A **layout pack** = mostly data (Lua table): regions, which built-in components go where, theme tokens (colors, fonts, spacing), assets, and a **mobile variant**.
- Built-in components: server list, channel list, message list, composer, member list, voice panel, top bar, settings.
- Optional **sandboxed scripts**: no `io`, `os`, `ffi`, `require`, network; instruction limit + memory cap. Custom widgets draw through a small API (rect, text, image, input) implemented by both renderers (LÖVE and HTML).
- Servers can ship a pack; clients download on connect and cache by hash.
- User controls: "Use server layouts" toggle + per-server override. Missing mobile variant → default mobile layout.
- Built-in packs (from the design canvas): **tabs** (default), **terminal**, **messenger** (early-2000s IM look, no MSN branding), **deck** (multi-column).
- Design previews: https://claude.ai/artifact/M3y1Py8gQWnN5JgjRQknHi (private to the owner)

## 7. Known platform limits

- **Notifications**: LÖVE apps pause in the background on Android; no push when the app is closed. Real push needs FCM = a central relay, against the self-hosted idea. Skipped for now; optional relay later. Same limit on iOS/browser.
- Native libs (Monocypher, Opus, SQLite) must be built for Windows x64, Linux x64, Linux ARM64, Android arm64.

## 8. Repo layout

```
protocol/   spec + shared Lua (framing, msgpack, packets, crypto wrappers)
server/     standalone server
client/     LÖVE client (desktop + Android)
web/        homepage (/), browser client (/app/), link handler (/link)
layouts/    tabs/ terminal/ messenger/ deck/
docs/       hosting, modding, protocol docs
.github/    workflows (Pages deploy now; release builds later)
```

---

## 9. Task list

### Phase 0: Setup
- [x] Create repo `MightyX3N/Zuno`
- [x] Skeleton folders + READMEs
- [x] Homepage (`web/index.html`) in Tabs style
- [x] Placeholder client page (`web/app/`)
- [x] Pages workflow + custom domain `zuno.dovecross.site`
- [x] Master plan (this file)
- [ ] Choose a license
- [ ] Logo / icon

### Phase 1: Protocol + server + desktop client (text chat)
- [ ] `protocol/`: framing (u32 length + MessagePack), packet definitions, versioning
- [ ] `protocol/`: pure-Lua MessagePack encoder/decoder
- [ ] FFI bindings: Monocypher, SQLite (Windows x64 + Linux x64 first)
- [ ] Handshake: server challenge → Ed25519 signature → X25519 session key → encrypted frames
- [ ] Server: config file, first-run setup (database, owner key), local port
- [ ] Server: TCP listener, connection handling (coroutines + non-blocking sockets)
- [ ] Server: channels + categories, send/edit/delete messages, history paging (50 per page)
- [ ] Server: member list, presence, typing indicators
- [ ] Client: identity key generation + local storage
- [ ] Client: server list, add server by address, connect/reconnect
- [ ] Client: Tabs layout hard-coded first (servers as tabs, channels left, chat, info/member panel)
- [ ] Client: text rendering, scrolling, unread markers, composer
- [ ] Client: "Host a server" button (starts bundled server)
- [ ] Hosting guide in `docs/` (playit.gg TCP tunnel setup)

### Phase 2: Accounts across devices + core features
- [ ] Export / import `.zunokey` file with recovery key (Argon2id + XChaCha20-Poly1305)
- [ ] QR device linking (temporary key, relay through a server, typed 6-digit code, one-scan, 2-min expiry, warning on second scan)
- [ ] Fallback typed link code for devices without a camera
- [ ] `web/link/` handler page
- [ ] Streamer mode (blur + reveal, Copy buttons, OBS/Streamlabs auto-detect on desktop)
- [ ] "Replace my key" hand-over + server-owner dispute tools
- [ ] Markdown, mentions, replies, reactions, custom emoji
- [ ] File and image uploads (chunked over TCP), avatars
- [ ] Notifications while the app is running

### Phase 3: Server management
- [ ] Roles + permission bitflags, per-channel overrides
- [ ] Kick / ban by identity key
- [ ] Invite addresses, optional server password
- [ ] Server settings editable from the client (owner key)
- [ ] Optional playit Proxy Protocol support (real client IPs)

### Phase 4: Layout system
- [ ] Layout pack format (Lua table spec) + loader
- [ ] Move Tabs layout into `layouts/tabs/` as a pack
- [ ] Port Terminal, Messenger, Deck packs
- [ ] Server-shipped packs: download on connect, cache by hash
- [ ] Sandboxed layout scripts (restricted env, instruction limit, memory cap) + widget draw API
- [ ] "Use server layouts" toggle + per-server override
- [ ] Modding guide in `docs/`

### Phase 5: Android
- [ ] LÖVE Android build (APK) via CI
- [ ] Android arm64 builds of native libs
- [ ] Mobile variants of all four built-in layouts
- [ ] Touch input, on-screen keyboard handling
- [ ] Android App Link for `zuno.dovecross.site/link` (assetlinks.json on Pages)

### Phase 6: Browser client
- [ ] Server: WebSocket support on the same port (first-byte sniffing)
- [ ] Server: optional TLS (own cert) + Let's Encrypt DNS-01 helper/docs
- [ ] Server: optional built-in web client over plain HTTP for owners without a domain
- [ ] Server: work behind a playit Premium HTTPS tunnel (plain WebSocket behind TLS termination)
- [ ] Server config "connection setup": list public addresses by type (tcp / udp / https / custom domain)
- [ ] Clients pick the right address from the server's address list (native → TCP/UDP, browser → HTTPS)
- [ ] Hosting guide: free plan vs Premium setups
- [ ] `web/app/`: HTML/CSS renderer for layout packs
- [ ] Wasmoon integration: run shared Lua + layout scripts in the browser
- [ ] JS/WASM crypto matching the native implementation
- [ ] QR scanning in the browser (camera) for device linking
- [ ] iOS Safari testing, add-to-home-screen support

### Phase 7: Voice
- [ ] Opus FFI bindings (all native targets)
- [ ] Server: UDP voice relay (forward packets to channel members, no mixing)
- [ ] Client: mic capture (LÖVE RecordingDevice), playback (QueueableSource)
- [ ] Push-to-talk + voice activation, speaking indicators, per-user volume, mute/deafen
- [ ] Browser: WebCodecs Opus over WebSocket (secure context only)

### Phase 8: Releases
- [ ] GitHub Actions: Windows + Linux client builds
- [ ] GitHub Actions: Android APK
- [ ] GitHub Actions: server packages (Windows x64, Linux x64, Linux ARM64)
- [ ] GitHub Releases + download links on the homepage
- [ ] Protocol reference in `docs/`

### Later / ideas
- [ ] DMs (relayed through a server both users share)
- [ ] Plugin / bot API in Lua
- [ ] Optional push relay for background notifications
- [ ] Screen sharing
