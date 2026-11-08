-- Encrypted session over any byte stream (TCP now, WebSocket later).
--
-- Handshake = Noise XX. Each side's static key is its Ed25519 identity converted to X25519,
-- and the Ed25519 public key itself travels inside the encrypted handshake payloads:
--   1. client -> server   e                       payload {p="zuno", min, max}       (plaintext)
--   2. server -> client   e, ee, s, es            payload {v, key, name, app} or {err, min, max}
--   3. client -> server   s, se                   payload {key, name}
-- Each side checks that the Ed25519 key it was given converts to the static key Noise
-- authenticated, so a key can't be claimed without owning it. The client checks the
-- server key against its pinned copy BEFORE sending message 3, so it never reveals its
-- identity to an impostor.
--
-- Usage (both roles): call feed(bytes) with received data, then pull() for bytes to send.
-- feed() returns a list of events:
--   { type = "ready", peer_key = hex, peer_name = str, version = n, server = {...} }
--   { type = "packet", packet = table }
--   { type = "error", code = str, message = str, ... }   (session is closed afterwards)
local frame = require("zuno.frame")
local mp = require("zuno.msgpack")
local Noise = require("zuno.noise")
local version = require("zuno.version")
local compat = require("zuno.compat")

local Session = {}
Session.__index = Session
Session.PROLOGUE = "zuno-handshake/1"
Session.MAX_PLAINTEXT = Noise.MAX_MESSAGE - 16

local function new(C, role, opts)
  local self = setmetatable({}, Session)
  self.C, self.role, self.opts = C, role, opts
  self.out = {}
  self.state = "handshake"
  self.decoder = frame.decoder(role == "server" and 1024 or frame.MAX)
  self.my_seed = assert(opts.identity_seed, "identity_seed required")
  self.my_key = compat.hex(C.ed25519_public(self.my_seed))
  self.hs = Noise.handshake(C, {
    initiator = role == "client",
    prologue = Session.PROLOGUE,
    s = C.ed25519_seed_to_x25519_secret(self.my_seed),
  })
  return self
end

-- opts: identity_seed, name, pinned_key (hex Ed25519 of the server, optional), min, max
function Session.client(C, opts) return new(C, "client", opts) end

-- opts: identity_seed (server key), name (server name), min, max
function Session.server(C, opts) return new(C, "server", opts) end

function Session:_emit(body) self.out[#self.out + 1] = frame.encode(body) end

function Session:pull()
  if #self.out == 0 then return nil end
  local s = table.concat(self.out)
  self.out = {}
  return s
end

function Session:is_ready() return self.state == "ready" end
function Session:is_closed() return self.state == "closed" end

local function fail(self, events, code, message, extra)
  self.state = "closed"
  local ev = { type = "error", code = code, message = message }
  if extra then for k, v in pairs(extra) do ev[k] = v end end
  events[#events + 1] = ev
  return events
end

-- Client: produce message 1.
function Session:start()
  assert(self.role == "client" and self.hs.step == 1)
  self:_emit(self.hs:write(mp.encode({ p = "zuno", min = self.opts.min or version.MIN, max = self.opts.max or version.MAX })))
end

local function key_matches(C, key_hex, static_x)
  local raw = type(key_hex) == "string" and #key_hex == 64 and compat.unhex(key_hex)
  if not raw then return false end
  local ok, x = pcall(C.ed25519_to_x25519_public, raw)
  return ok and C.equal(x, static_x)
end

function Session:_handshake_frame(body, events)
  local C, hs = self.C, self.hs
  local payload, err = hs:read(body)
  if not payload then return fail(self, events, "handshake_failed", err) end
  local data = mp.decode(payload)
  if type(data) ~= "table" then return fail(self, events, "handshake_failed", "bad handshake payload") end

  if self.role == "server" then
    if hs.step == 2 then -- got message 1
      if data.p ~= "zuno" or not compat.is_int(data.min) or not compat.is_int(data.max) then
        return fail(self, events, "handshake_failed", "not a Zuno client")
      end
      local v, verr = version.negotiate(self.opts.min or version.MIN, self.opts.max or version.MAX, data.min, data.max)
      if not v then
        self:_emit(hs:write(mp.encode({ err = verr, min = self.opts.min or version.MIN, max = self.opts.max or version.MAX })))
        return fail(self, events, verr, "no common protocol version")
      end
      self.version = v
      self:_emit(hs:write(mp.encode({ v = v, key = self.my_key, name = self.opts.name or "Zuno server", app = version.APP })))
      self.decoder:set_max(2048)
    else -- got message 3
      if not key_matches(C, data.key, hs.rs) then
        return fail(self, events, "handshake_failed", "client key does not match its handshake key")
      end
      self.send_cs, self.recv_cs, self.hash = hs:split()
      self.state = "ready"
      self.decoder:set_max(frame.MAX)
      self.peer_key = data.key
      events[#events + 1] = { type = "ready", peer_key = data.key, guest = data.guest == true,
        peer_name = type(data.name) == "string" and data.name or nil, version = self.version }
    end
  else -- client got message 2
    if data.err then
      return fail(self, events, tostring(data.err), "no common protocol version", { server_min = data.min, server_max = data.max })
    end
    if not key_matches(C, data.key, hs.rs) then
      return fail(self, events, "handshake_failed", "server key does not match its handshake key")
    end
    if self.opts.pinned_key and self.opts.pinned_key ~= data.key then
      return fail(self, events, "server_key_changed", "this server's identity changed",
        { new_key = data.key, old_key = self.opts.pinned_key, server_name = data.name })
    end
    self.version = data.v
    self:_emit(hs:write(mp.encode({ key = self.my_key, name = self.opts.name, guest = self.opts.guest or nil })))
    self.send_cs, self.recv_cs, self.hash = hs:split()
    self.state = "ready"
    self.peer_key = data.key
    events[#events + 1] = { type = "ready", peer_key = data.key, peer_name = data.name, version = data.v,
      server = { name = data.name, app = data.app } }
  end
  return events
end

-- Feed received bytes. Returns a list of events.
function Session:feed(bytes)
  local events = {}
  if self.state == "closed" then return events end
  self.decoder:push(bytes)
  while self.state ~= "closed" do
    local body, err = self.decoder:next()
    if err then return fail(self, events, "protocol_error", err) end
    if not body then break end
    if self.state == "handshake" then
      self:_handshake_frame(body, events)
    else
      local pt = self.recv_cs:decrypt("", body)
      if not pt then return fail(self, events, "protocol_error", "decryption failed") end
      local pkt = mp.decode(pt)
      if type(pkt) ~= "table" or type(pkt.t) ~= "string" then
        return fail(self, events, "protocol_error", "bad packet")
      end
      events[#events + 1] = { type = "packet", packet = pkt }
    end
  end
  return events
end

-- Encrypt and queue a packet. Returns false if it is too big.
function Session:send(pkt)
  assert(self.state == "ready", "session not ready")
  local pt = mp.encode(pkt)
  if #pt > Session.MAX_PLAINTEXT then return false end
  self:_emit(self.send_cs:encrypt("", pt))
  return true
end

function Session:close() self.state = "closed" end

return Session
