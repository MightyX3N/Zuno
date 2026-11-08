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
| Native client | LÖVE 11.5 (LuaJIT): Windows, Linux, Android (phone, tablet and Android TV) |
| UI architecture | **One Lua UI for every platform** (see 6.0). Built-in components, layouts and addon widgets are written once in Lua against a small **platform API**. Only the backend that implements that API exists twice: LÖVE and browser |
| Browser client | **Wasmoon** (Lua 5.4 in WASM) runs the same Lua UI as the native client. JS only implements the platform API: drawing on a `<canvas>`, with **real HTML `<input>`/`<textarea>` elements placed over the canvas** for typing (proper iOS/Android keyboard, IME, emoji, paste). Not love.js (no JS FFI, ~10–15 MB, bad iOS keyboard) |
| Lua dialect | Shared code (protocol, UI, layouts, addons) must run on **both LuaJIT (5.1) and Lua 5.4**: no `goto`, no 5.4-only `//` or bitwise operators, use a small `compat` module for bit ops and integer math |
| iOS | Through the browser client (Safari, add to home screen). No native iOS app |
| Server | Standalone **LuaJIT + LuaSocket**, no LÖVE. Targets Windows x64, Linux x64, Linux ARM64 (NAS / Raspberry Pi) |
| Client hosting | Desktop client bundles the `server/` package and has a "Host a server" button |
| Storage (server) | SQLite via LuaJIT FFI |
| Crypto | Monocypher via FFI (X25519, XChaCha20-Poly1305, Ed25519, Argon2). Browser: matching JS/WASM implementation |
| Voice codec | Opus (libopus via FFI; WebCodecs in browser) |
| Wire format | `u32` length prefix + MessagePack body |
| Transport | Raw TCP for native clients, WebSocket for browser, **same port**: server sniffs first bytes (`GET ` = WebSocket upgrade) |
| Voice transport | UDP (native) / Opus frames over the WebSocket (browser) |
| Default layout | **Tabs** (servers as tabs along the top), light and dark, with desktop / tablet / phone / TV variants (see 6.1) |
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

### 4.1 Server-hosted web client
- Every server can serve the web client itself on its own port (HTTP on the same port as TCP/WebSocket). Opening the server's address in a browser loads Zuno with that server's layout preloaded.
- Full features (incl. voice) when reached over HTTPS (playit Premium HTTPS tunnel or own cert); text only over plain HTTP.
- **Trust rule**: the host controls that copy of the client, so it could be modified to steal keys.
  - Server-hosted client starts with a **separate identity for that server** by default.
  - Linking/importing the main account there shows a warning naming the host ("only link if you trust this host").
  - The official client at `zuno.dovecross.site/app/` is the recommended place for the main account.
- Server bundles a web client version matching its protocol version; owners can turn the built-in client off.

### 4.2 Load on the official website
- Chat and voice never pass through GitHub: browsers connect straight to Zuno servers. Pages only serves the client's static files (cached after first load).
- GitHub Pages soft limit ≈ 100 GB bandwidth/month → keep the web client small. Server-hosted clients take load off Pages.
- App binaries go on **GitHub Releases**, not Pages.
- If traffic outgrows Pages, `web/` is plain static files → move to Cloudflare Pages or similar with no code changes.

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

### 5.1.1 Reverse link: the new device shows the QR (TV, desktop without camera)
A TV has no camera and typing with a remote is painful, so the **new device shows the QR and the phone scans it** (same idea as signing into Netflix/YouTube on a TV).
1. New device (TV) → "Sign in with your phone" (the TV's first screen) → shows QR. QR holds the TV's **temporary key + session ID + its LAN address and a temporary port**. Same `https://zuno.dovecross.site/link#<payload>` link format, flagged as a reverse link.
2. Phone scans it (system camera or the Zuno app's scanner) and connects **straight to the TV over the local network**. No Zuno server needed, because the TV doesn't have an account or any servers yet.
3. TV shows the **6-digit code**; the phone asks the user to type it in. Nothing is sent until it matches (same rule as 5.1).
4. Phone sends the full account package end-to-end encrypted. The account includes the **server list, so the TV joins all the user's servers at once**. Settings and layout choices come with it.
5. TV shows "Signed in as <name>" with a Cancel button for a few seconds before it connects to the servers.
6. Same one-scan rule and 2-minute expiry as 5.1.
- **Fallback when LAN fails** (guest Wi-Fi, client isolation, phone on mobile data, or the phone is the browser client, which can't open LAN connections from an HTTPS page): the TV asks for one server invite address (typed once or entered as a short invite code) and the link continues through that server as in 5.1.
- Desktops without a camera use the same reverse flow; the typed short code from 5.1 stays as the last fallback.
- **Join a server from the phone**: on a linked TV, an invite opened on the phone can be sent to the user's other devices ("Also join on: Living room TV"), since all devices share the account and server list sync.

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

### 5.5 Direct file sharing

Send files straight to another user without posting them in a channel. Both users must be online.

- Start from a user's profile / context menu or a DM: **Send file** → receiver gets a prompt (name, size, sender) → Accept / Decline. Nothing transfers before Accept.
- **End-to-end encrypted** for the receiver's key; relays can't read it.
- **Route**: try direct peer-to-peer first (shared server only for signaling; UDP hole punching on native clients, WebRTC data channel in the browser). If that fails → stream through a server both users share. The server forwards encrypted bytes only and **never stores** the file.
- **Server owner settings**: allow/deny relayed transfers, max relayed file size. Direct P2P transfers are not limited by the server.
- Progress bar, pause / resume (continues after a dropped connection), multiple files at once, hash check on arrival.
- Streamer mode hides incoming file names until revealed.

### 5.6 Server identity (anti-impersonation)
- Every server has its own **Ed25519 server key**, created on first run. The handshake proves the server holds it.
- Clients **pin** the key on first connect (trust on first use) and warn loudly if it changes ("this server's identity changed").
- Invite links can include the key fingerprint so even the first connect is verified.
- Moving a server to a new address/host keeps the key (it's in the server backup), so members don't get a warning.

### 5.7 What is encrypted from whom
- **All traffic** is encrypted between client and server (playit and the network can't read it).
- **Channel messages** are readable by the server (it stores, pages and searches them). The host is the community owner, same trust model as any self-hosted chat. Stated clearly in the client.
- **DMs and direct file transfers are end-to-end encrypted**: the relaying server can't read them.

### 5.8 Spam and raid protection
Keys are free to make, so anyone can create endless identities. Servers need gates:
- Join modes: open / password / invite code / owner approval.
- New-member limits: slow mode, can't post links or files for X minutes, rate limits per identity and per connection.
- Optional small proof-of-work on join to make mass joins expensive.
- Lockdown button: pause joins during a raid.
- Reports to moderators, message deletion in bulk, audit log of mod actions.
- Server-side DoS protection: connection limits, frame size limits, handshake timeouts.

### 5.9 Versions and updates
- Protocol version in the handshake; server and client agree on the highest version both support, refuse cleanly with "update your app" / "server is outdated".
- Clients check GitHub Releases for updates and offer to install (desktop) or link to the new APK.
- Server prints update notices in its console.

### 5.10 Server admin
- Headless server is managed from the owner's Zuno client (server settings) plus a **console** (CLI commands: create channel, ban, backup, etc.).
- **Backup / restore**: one command exports database, server key, config, layouts and addons into one file; restore on a new machine to move hosts.
- Users can delete their own messages, and ask the server to delete everything they posted ("leave and delete my data").

## 6. Layouts and modding

### 6.0 One UI, two thin backends
- The whole client UI is **Lua, written once**: built-in components, layout packs, layout scripts and addon widgets. Native runs it on LuaJIT inside LÖVE; the browser runs the same files on Wasmoon.
- The UI talks to the platform only through a small **platform API**:
  - draw: rect, rounded rect, line, image, text (with font, size, color, clipping), measure text
  - input: pointer/touch, wheel/scroll, keys, focus, and **D-pad / arrow-key focus navigation** (move focus between components and items, select, back). Needed for TV remotes; also gives keyboard-only use on desktop
  - device info: form factor (desktop / phone / tablet / TV), main input type (mouse, touch, remote), system light/dark preference
  - text fields: create / move / resize / read / destroy a native text field
  - clipboard write (read only after a user paste), open link (with confirm), sound playback
  - timers, window size, safe areas (phone notch / keyboard height / TV overscan)
- **Two backends** implement that API and nothing else:
  - **LÖVE**: `love.graphics`, `love.keyboard`/`love.textinput`, `love.system` clipboard.
  - **Browser**: a full-window `<canvas>` for drawing. Text fields are **real HTML `<input>`/`<textarea>` elements positioned over the canvas** where the Lua UI places them, styled to match the layout. That gives the proper on-screen keyboard on iOS/Android, IME, emoji picker, paste and spellcheck.
- **Text selection / copy in messages**: done in the Lua UI (drag to select, copy via the platform API) so it works the same everywhere.
- **Accessibility in the browser**: the backend keeps a hidden DOM mirror (ARIA labels for buttons, a live region for new messages) generated from the Lua UI tree, so screen readers still work.
- Shared Lua lives in `ui/` (plus `protocol/` and `layouts/`); the Pages workflow copies these into the site at deploy so the browser loads the exact same files.

### 6.1 Layout packs
- A **layout pack** = mostly data (Lua table): regions, which built-in components go where, theme tokens (colors, fonts, spacing), assets, plus **form factors** and **color schemes** (below).
- **Color schemes**: every pack defines a **light and a dark** token set. The client follows the system setting by default, with a manual Light / Dark / System choice. A pack that only defines one scheme uses it for both.
- **Form factors**: a pack can define variants for **desktop, phone, tablet and TV**. The client picks one from screen size and input type (TV = remote / D-pad). Missing variant → nearest one the pack has (tablet → desktop or phone, TV → tablet), and if the pack has none that fit, the default Tabs variant for that form factor.
- **Tabs (default) per form factor**:
  - Desktop: servers as tabs along the top, channels left, chat, member/info panel right.
  - Tablet: same as desktop with larger touch targets; member panel opens on demand.
  - Phone: server tabs become a horizontal strip at the top (scrolls when there are many) with a pull-down switcher; channels slide in from the left, members from the right; chat is full screen.
  - TV: 10-foot UI, large text, everything reachable with the D-pad. Built for reading chat, sitting in voice and (later) watching streams. Typing opens the system on-screen keyboard or voice input. First screen when not signed in = reverse-link QR (5.1.1).
- Built-in components: server list, channel list, message list, composer, member list, voice panel, top bar, settings.
- Optional **sandboxed scripts**: no `io`, `os`, `ffi`, `require`, network; instruction limit + memory cap. Custom widgets draw through the same platform API as the built-in components (see 6.0), so a layout works unchanged on LÖVE and in the browser.
- Servers can ship a pack; clients download on connect and cache by hash.
- User controls: "Use server layouts" toggle + per-server override, Light / Dark / System.
- Built-in packs (from the design canvas): **tabs** (default), **terminal**, **messenger** (early-2000s IM look, no MSN branding), **deck** (multi-column).
- Design previews: [`docs/design/layouts.html`](docs/design/layouts.html) (exported design canvas with all four layouts) and [`docs/design/tabs-variants.html`](docs/design/tabs-variants.html) (Tabs in dark mode and on tablet, phone and TV). Open them in a browser

### 6.2 Addons (features, not just theming)

Servers can add real features: polls, games, music-bot panels, leaderboards, stream panels, custom commands, and so on. Two kinds:

**Server plugins** (run on the server)
- Lua on the server, installed by the owner on purpose.
- API: server events (message sent, user joined, voice join…), commands, own namespaced database tables, send messages as a bot, talk to their client addon.
- Sandboxed from the host machine by default (no `io`, `os`, `ffi`, raw sockets). Owner can grant extra rights per plugin in the server config (e.g. outbound HTTP to listed hosts).

**Client addons** (shipped by a server, run in every member's client)
- **One sandbox per server**: each server's addons run in their own Lua state. Native: a separate `love.thread`; browser: a Wasmoon instance in a Web Worker. Server A's addons can never see server B, the UI of other servers, or each other's storage.
- **No access to the computer or the user's data**: no `io`, `os`, `ffi`, `require`, `load` of bytecode, `debug`, `string.dump`, no file system, no clipboard reading, no network except messages to **its own server's plugin** through the Zuno API. Never sees the account key, the account package, other servers or DMs elsewhere.
- **Instruction limit + memory cap**; an addon that hangs or blows up is stopped and reported, the client keeps running.
- **Capability API only**:
  - UI: panels, buttons, modals, widgets in regions the layout allows (same draw API as layout scripts)
  - Read: channels / members / messages of **that server** the user can already see
  - Act: send a message or reaction **only right after a user action** (click), marked "via <addon>"
  - Talk to its server plugin (custom packets, rate-limited)
  - Play sounds / show images from the addon's own assets
  - Small per-addon storage, scoped to that server, size quota
  - Hook core media features (voice, future video) through the API, never raw devices
  - Open links only through a confirmation dialog
- **Permissions shown on join**: list of what the server's addons can do; user can allow, deny, or turn addons off per server at any time. Rate limits on everything that sends.
- Addon code is signed by the server key, cached by hash, and viewable ("View source") from server settings.

### 6.3 Video sharing (future)
- Core Zuno provides capture (screen/camera), encode/decode (H.264 or VP9/AV1 via FFI; WebCodecs in browser), stream transport, and a video component.
- Addons/plugins decide UI and rules ("Go live" button, who may stream, quality/viewer caps, watch parties).
- Bandwidth: server relays every stream to every viewer → P2P for small groups, owner quality caps, VPS for big servers.
- The **video playback core** (decoding + drawing video into the UI) is shared with Watch together (6.4): native uses **libmpv via FFI**, rendered into a texture; browser uses `<video>` + hls.js / WebCodecs.

### 6.4 Watch together (Jellyfin)
Server owners can connect their own **Jellyfin** server so members watch movies and shows together, with chat and voice running alongside. Same self-hosted idea as Zuno: the media stays on the owner's PC / NAS.

- **Official addon**: a server plugin + client panel, built on the video playback core (6.3). Ships with Zuno but is off until the owner sets it up.
- **Owner setup** (server settings): Jellyfin address + API key of a **dedicated Jellyfin user**. That user's library access decides what members can see. Who may start a watch party is a normal Zuno permission.
- **Members**: "Watch together" panel → browse the shared library (posters, search, seasons/episodes) → start a watch party in a channel, others click Join.
- **Stream route (default): through the Zuno server.** The plugin fetches the stream from Jellyfin and forwards it to each viewer over the normal encrypted Zuno connection. Works with the single playit TCP tunnel, Jellyfin never has to be public, viewers need no Jellyfin account.
  - Cost: the host's **upload** bandwidth (5 viewers × 8 Mbit/s = 40 Mbit/s). Owner sets a max quality / bitrate and max viewers; Jellyfin transcodes down to it. Optional later: viewers pick a lower quality for themselves.
  - Optional **direct mode** for owners whose Jellyfin is already public over HTTPS: clients stream straight from Jellyfin with a short-lived token from the plugin; Zuno only syncs.
- **Sync done by Zuno, not Jellyfin SyncPlay** (SyncPlay only works between Jellyfin clients): the party leader's play / pause / seek go to everyone with a timestamp; clients correct small drift by adjusting speed slightly and hard-seek on big drift. Everyone waits while someone buffers. Leader can hand over control or allow everyone to control.
- Subtitles and audio tracks: picked per viewer from what Jellyfin offers.
- Fits the **TV** variant especially well (couch + remote + friends in voice).

## 7. Known platform limits

- **LÖVE video**: LÖVE only plays Ogg Theora. Real video (Jellyfin, streams) needs libmpv via FFI on every native target, Android included.
- **Notifications**: LÖVE apps pause in the background on Android; no push when the app is closed. Real push needs FCM = a central relay, against the self-hosted idea. Skipped for now; optional relay later. Same limit on iOS/browser.
- Native libs (Monocypher, Opus, SQLite, later libmpv) must be built for Windows x64, Linux x64, Linux ARM64, Android arm64.

## 8. Repo layout

```
protocol/   spec + shared Lua (framing, msgpack, packets, crypto wrappers)
server/     standalone server
client/     LÖVE client (desktop + Android)
ui/         shared Lua UI: built-in components, layout engine, platform API definition
web/        homepage (/), browser client (/app/: canvas + HTML-input backend), link handler (/link)
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
- [ ] Server identity key + client key pinning (TOFU), fingerprint in invite links, warning on change
- [ ] Protocol version negotiation + clean "update required" errors
- [ ] Server DoS basics: connection limits, max frame size, handshake timeout, rate limits
- [ ] Reconnect with resume (re-sync missed messages after a drop)
- [ ] Server: config file, first-run setup (database, owner key), local port
- [ ] Server: TCP listener, connection handling (coroutines + non-blocking sockets)
- [ ] Server: channels + categories, send/edit/delete messages, history paging (50 per page)
- [ ] Server: member list, presence, typing indicators
- [ ] Client: identity key generation + local storage
- [ ] Client: server list, add server by address, connect/reconnect
- [ ] `ui/`: platform API spec (draw, input, text fields, clipboard, timers, safe areas)
- [ ] `ui/`: `compat` module so shared Lua runs on both LuaJIT (5.1) and Lua 5.4; test both in CI
- [ ] Client: LÖVE backend for the platform API
- [ ] Client: Tabs layout hard-coded first in `ui/` (servers as tabs, channels left, chat, info/member panel)
- [ ] Client: text rendering, scrolling, unread markers, composer
- [ ] Client: "Host a server" button (starts bundled server)
- [ ] Hosting guide in `docs/` (playit.gg TCP tunnel setup)

### Phase 2: Accounts across devices + core features
- [ ] Export / import `.zunokey` file with recovery key (Argon2id + XChaCha20-Poly1305)
- [ ] QR device linking (temporary key, relay through a server, typed 6-digit code, one-scan, 2-min expiry, warning on second scan)
- [ ] Reverse link (5.1.1): new device shows QR, phone scans, direct LAN connection, typed 6-digit code
- [ ] Reverse link fallback through one server invite when LAN fails
- [ ] "Also join on my other devices" when opening an invite
- [ ] Fallback typed link code for devices without a camera
- [ ] `web/link/` handler page
- [ ] Streamer mode (blur + reveal, Copy buttons, OBS/Streamlabs auto-detect on desktop)
- [ ] "Replace my key" hand-over + server-owner dispute tools
- [ ] Markdown, mentions, replies, reactions, custom emoji
- [ ] File and image uploads (chunked over TCP), avatars
- [ ] Notifications while the app is running
- [ ] Direct file sharing: offer / accept / decline prompt
- [ ] Direct file sharing: end-to-end encryption for the receiver's key
- [ ] Direct file sharing: P2P via UDP hole punching (native), server as signaling
- [ ] Direct file sharing: relay fallback through a shared server (stream only, never stored)
- [ ] Direct file sharing: owner settings (allow relay, max relayed size)
- [ ] Direct file sharing: progress, pause/resume, multiple files, hash check
- [ ] Direct file sharing in the browser: WebRTC data channel (Phase 6)

### Phase 3: Server management
- [ ] Roles + permission bitflags, per-channel overrides
- [ ] Kick / ban by identity key
- [ ] Invite addresses, optional server password
- [ ] Server settings editable from the client (owner key)
- [ ] Optional playit Proxy Protocol support (real client IPs)
- [ ] Join modes: open / password / invite code / owner approval
- [ ] New-member limits (slow mode, no links/files at first), optional proof-of-work on join
- [ ] Raid lockdown button
- [ ] Reports, bulk delete, audit log of mod actions
- [ ] Server console (CLI commands for admin tasks)
- [ ] Server backup / restore (DB, server key, config, layouts, addons) for moving hosts
- [ ] "Delete my data" request from a user
- [ ] Message search (server-side)
- [ ] Pinned messages, per-channel notification settings (mute, mentions only)
- [ ] Block users (client-side, hides them everywhere)

### Phase 4: Layouts and addons
- [ ] Layout pack format (Lua table spec) + loader
- [ ] Move Tabs layout into `layouts/tabs/` as a pack
- [ ] Light / dark color schemes in the pack format + Light / Dark / System setting
- [ ] Form-factor variants in the pack format (desktop / phone / tablet / TV) with fallback rules
- [ ] D-pad / arrow-key focus navigation in the platform API and all built-in components
- [ ] Port Terminal, Messenger, Deck packs
- [ ] Server-shipped packs: download on connect, cache by hash
- [ ] Sandboxed layout scripts (restricted env, instruction limit, memory cap) + widget draw API
- [ ] "Use server layouts" toggle + per-server override
- [ ] Server plugins: loader, event/command/DB API, host sandbox, per-plugin extra rights in config
- [ ] Client addons: one sandbox per server (love.thread native / Web Worker + Wasmoon browser)
- [ ] Client addons: locked-down environment, instruction limit, memory cap, crash isolation
- [ ] Client addons: capability API (UI, read server data, user-triggered send, plugin messaging, assets, scoped storage, link confirm)
- [ ] Client addons: permission prompt on join, per-server allow/deny/off, rate limits
- [ ] Addon signing by server key, hash cache, "View source"
- [ ] Example addons: poll, simple game, leaderboard
- [ ] Modding guide in `docs/` (layouts, client addons, server plugins)

### Phase 5: Android
- [ ] LÖVE Android build (APK) via CI
- [ ] Android arm64 builds of native libs
- [ ] Tabs: phone and tablet variants (see 6.1)
- [ ] Phone variants of Terminal, Messenger, Deck
- [ ] Android TV: Leanback launcher entry, D-pad navigation, overscan safe area, system on-screen keyboard
- [ ] Tabs: TV variant + "Sign in with your phone" first screen
- [ ] Touch input, on-screen keyboard handling
- [ ] Android App Link for `zuno.dovecross.site/link` (assetlinks.json on Pages)

### Phase 6: Browser client
- [ ] Server: WebSocket support on the same port (first-byte sniffing)
- [ ] Server: optional TLS (own cert) + Let's Encrypt DNS-01 helper/docs
- [ ] Server: built-in web client served on its own port (HTTP + HTTPS), with the server's layout preloaded, can be turned off
- [ ] Server-hosted client: separate per-server identity by default + warning before linking the main account
- [ ] Server: work behind a playit Premium HTTPS tunnel (plain WebSocket behind TLS termination)
- [ ] Server config "connection setup": list public addresses by type (tcp / udp / https / custom domain)
- [ ] Clients pick the right address from the server's address list (native → TCP/UDP, browser → HTTPS)
- [ ] Hosting guide: free plan vs Premium setups
- [ ] Wasmoon integration: run the full shared Lua UI (`ui/`, `protocol/`, `layouts/`) in the browser
- [ ] `web/app/`: browser backend for the platform API (canvas drawing, text measuring, input events)
- [ ] `web/app/`: native HTML text fields positioned over the canvas (iOS/Android keyboard, IME, emoji, paste)
- [ ] `web/app/`: hidden DOM mirror for screen readers (ARIA labels, live region for new messages)
- [ ] Pages workflow: copy `ui/`, `protocol/`, `layouts/` into the site at deploy
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
- [ ] Update checker in clients (GitHub Releases), update notice in server console
- [ ] Automated tests in CI: protocol, crypto, sandbox escape tests, MessagePack fuzzing
- [ ] Security review of crypto + addon sandbox before first public release

### Phase 9: Watch together (Jellyfin), after voice (7), addons (4) and the video core
- [ ] Video playback core: libmpv FFI bindings + render to texture (Windows, Linux, Android)
- [ ] Video playback core in the browser: `<video>` + hls.js
- [ ] Server plugin: Jellyfin connection (address, API key, dedicated user), library browsing API
- [ ] Server plugin: stream proxy (Jellyfin → Zuno server → viewers), owner max bitrate / max viewers
- [ ] Client panel: browse library, start / join a watch party in a channel
- [ ] Sync: leader controls, timestamped play / pause / seek, drift correction, wait-for-buffering, hand over control
- [ ] Per-viewer subtitles and audio track
- [ ] Optional direct mode (public Jellyfin over HTTPS, short-lived tokens)
- [ ] TV variant of the watch-together screen
- [ ] Hosting guide: setting up Jellyfin with Zuno

### Later / ideas
- [ ] DMs (relayed through a server both users share, end-to-end encrypted)
- [ ] Friends list + online status across servers
- [ ] Threads (reply chains in their own side panel)
- [ ] Custom emoji / sticker packs per server
- [ ] Translations (English + Danish first)
- [ ] Accessibility: font scaling, high contrast, screen-reader labels in the web client (via the hidden DOM mirror)
- [ ] Optional public server list (static JSON on the website, added via pull request)
- [ ] Plugin / bot API in Lua
- [ ] Optional push relay for background notifications
- [ ] Video / screen sharing as a core feature addons can hook into (see 6.3)
