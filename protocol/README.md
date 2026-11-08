# protocol

Shared wire protocol used by the server, the native client and the web client.

- Frames: `u32` length prefix + MessagePack body
- Transport: raw TCP (native clients) or WebSocket (browser), on the same port
- Handshake: server challenge signed with the user's Ed25519 key, then X25519 key exchange
- Voice: Opus over UDP (native) or over the WebSocket (browser)
