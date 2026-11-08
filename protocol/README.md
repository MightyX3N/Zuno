# protocol

Wire protocol and shared Lua used by the server and every client.

## Layers

1. **Frames**: big-endian `u32` length + body, max 65 535 bytes (`zuno/frame.lua`).
2. **Handshake**: `Noise_XX_25519_ChaChaPoly_BLAKE2b` (`zuno/noise.lua`, checked against the
   official cacophony test vectors). Each side's static key is its Ed25519 identity converted
   to X25519, and the Ed25519 public key travels inside the encrypted handshake payloads, so a
   key can't be claimed without owning it. Prologue `zuno-handshake/1`.
   - msg 1 (client): `{p = "zuno", min, max}` (protocol versions)
   - msg 2 (server): `{v, key, name, app}` or `{err = "client_outdated" | "server_outdated", min, max}`
   - msg 3 (client): `{key, name}`. The client checks the server key against its pinned copy
     **before** sending this, so it never reveals itself to an impostor.
3. **Packets**: after the handshake every frame is one ChaCha20-Poly1305 message containing a
   MessagePack map with a type field `t` (`zuno/session.lua`).

## Packets (version 1)

Client → server (validated by `zuno/packets.lua`): `ping`, `sync`, `history`, `since`, `send`,
`edit`, `delete`, `typing`, `profile`, `claim`, `channel_create`, `channel_update`,
`channel_delete`. Requests may carry `q`; errors echo it as `re`.

Server → client: `pong`, `state`, `messages`, `msg`, `typing`, `presence`, `member`, `channel`,
`channel_removed`, `err`, `notice`.

Every message change (new, edit, delete) bumps a server-wide revision `rev`. After a reconnect
the client asks `since {ch, rev}` per loaded channel and gets exactly what it missed.

## Files

| File | Runs on | |
|---|---|---|
| `compat.lua` | LuaJIT + Lua 5.4 | Bit ops, UTF-8 checks, hex: lets shared code run on both |
| `msgpack.lua` | LuaJIT + Lua 5.4 | Pure-Lua MessagePack with a hardened decoder |
| `frame.lua` | LuaJIT + Lua 5.4 | Framing |
| `packets.lua`, `version.lua` | LuaJIT + Lua 5.4 | Packet specs and version negotiation |
| `noise.lua`, `session.lua` | LuaJIT + Lua 5.4 (given a crypto backend) | Handshake and encrypted session |
| `crypto.lua` | LuaJIT (FFI) | Monocypher binding. The browser will supply the same functions from JS/WASM |
