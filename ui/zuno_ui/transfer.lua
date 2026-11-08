-- Direct file transfers between two people (PLAN 5.5). Shared Lua, no sockets of its own:
-- the platform gives file handles, a Downloads folder and (natively) a UDP socket.
--
--   1. Sender hashes the files, then sends a signed offer through a shared server.
--   2. Receiver accepts (signed answer). Both derive a key from ephemeral X25519 keys; the
--      signatures over those keys mean the server can't sit in the middle.
--   3. Both try a direct UDP route (local address + the address the server sees, probed from
--      both sides = hole punching). If that fails within a few seconds the bytes stream
--      through the server instead, if the server allows it. Everything is sealed with the key.
--   4. Files go one after another in chunks with acks; the receiver writes to a .zunopart
--      file in Downloads and checks the hash at the end. A dropped connection or a pause
--      continues from what arrived.
local mp = require("zuno.msgpack")
local compat = require("zuno.compat")

local X = {}
X.PROBE_TIME = 4        -- seconds to find a direct route before using the relay
X.RELAY_CHUNK = 48000
X.DIRECT_CHUNK = 1100
X.RELAY_WINDOW = 1024 * 1024
X.ACK_EVERY = 0.03

local Manager = {}
Manager.__index = Manager

-- env: { crypto, now, open, size, rename, remove, downloads_dir, sep, udp (optional) }
function X.new(env)
  return setmetatable({ env = env, list = {}, by_x = {}, listeners = {} }, Manager)
end

function Manager:on(fn) self.listeners[#self.listeners + 1] = fn end
function Manager:_emit(ev, t) for _, fn in ipairs(self.listeners) do fn(ev, t) end end

local B32 = "abcdefghijkmnpqrstuvwxyz23456789"
local function new_id(C)
  local r, out = C.random(12), {}
  for i = 1, 12 do local v = r:byte(i) % 32 + 1; out[i] = B32:sub(v, v) end
  return table.concat(out)
end

local function unhex(h) return compat.unhex(h) end

local function files_digest(C, files)
  local parts = {}
  for i, f in ipairs(files) do parts[i] = f.n .. "\0" .. f.s .. "\0" .. f.h end
  return C.blake2b(table.concat(parts, "\1"), 32)
end

local function offer_msg(server_key, x, to, eph, digest)
  return "zuno-xfer-offer-v1:" .. server_key .. ":" .. x .. ":" .. to .. ":" .. eph .. digest
end
local function answer_msg(server_key, x, from, eph_a, eph_b)
  return "zuno-xfer-answer-v1:" .. server_key .. ":" .. x .. ":" .. from .. ":" .. eph_a .. ":" .. eph_b
end

------------------------------------------------------------------ helpers
function Manager:_seed(conn) return conn.seed or conn.env.identity_seed end

function Manager:_add(t)
  self.list[#self.list + 1] = t
  self.by_x[t.x] = t
  self:_emit("added", t)
end

function Manager:_set(t, state, why)
  if t.state == state then return end
  t.state, t.why = state, why
  if state == "done" or state == "failed" or state == "cancelled" or state == "declined" then
    self:_close_files(t)
    if t.udp then t.udp:close(); t.udp = nil end
    t.finished_at = self.env.now()
  end
  self:_emit("state", t)
end

function Manager:_close_files(t)
  for _, f in ipairs(t.files) do if f.h then f.h:close(); f.h = nil end end
end

function Manager:_seal(t, msg) return self.env.crypto.seal(t.key, mp.encode(msg), t.x) end

-- Send a control or data message on the best route we have.
function Manager:_send(t, msg, force_relay)
  if not t.key then return false end
  local box = self:_seal(t, msg)
  if t.route == "direct" and not force_relay and t.peer_addr then
    return t.udp:send(t.peer_addr[1], t.peer_addr[2], "ZX" .. t.x .. box) ~= false
  end
  return t.conn:send({ t = "xfer_data", x = t.x, d = mp.bin(box) })
end

------------------------------------------------------------------ sending
-- files: { { path, name, size } }. Returns the transfer.
function Manager:send(conn, to, to_name, files)
  local C = self.env.crypto
  local t = { x = new_id(C), dir = "out", conn = conn, peer = to, peer_name = to_name, files = {},
              state = "hashing", started = self.env.now(), bytes = 0, total = 0 }
  for i, f in ipairs(files) do
    t.files[i] = { path = f.path, name = f.name, size = f.size, have = 0 }
    t.total = t.total + f.size
  end
  t.hash_i, t.hash_off = 1, 0
  self:_add(t)
  return t
end

-- Hash a few MB per call so the UI keeps running.
function Manager:_hash_step(t)
  local C = self.env.crypto
  local budget = 8 * 1024 * 1024
  while budget > 0 do
    local f = t.files[t.hash_i]
    if not f then
      self:_offer(t)
      return
    end
    if not f.hasher then
      f.hasher = C.hasher(32)
      f.h = self.env.open(f.path, "rb")
      if not f.h then return self:_set(t, "failed", "Couldn't read " .. f.name) end
    end
    local d = f.h:read(math.min(1048576, budget))
    if not d then
      f.hash = f.hasher:final(); f.hasher = nil
      f.h:close(); f.h = nil
      t.hash_i = t.hash_i + 1
    else
      f.hasher:update(d)
      budget = budget - #d
      t.hashed = (t.hashed or 0) + #d
    end
  end
end

function Manager:_offer(t)
  local C, conn = self.env.crypto, t.conn
  if conn.status ~= "online" or not conn.server then return self:_set(t, "interrupted", "Not connected") end
  t.a_sk, t.A = C.x25519_keypair()
  t.key, t.route, t.peer_addr, t.hello = nil, nil, nil, nil
  local list, raw = {}, {}
  for i, f in ipairs(t.files) do
    list[i] = { n = f.name, s = f.size, h = mp.bin(f.hash) }
    raw[i] = { n = f.name, s = f.size, h = f.hash }
  end
  local digest = files_digest(C, raw)
  local sig = C.ed25519_sign(self:_seed(conn), offer_msg(conn.server.key, t.x, t.peer, t.A, digest))
  conn.q = (conn.q or 0) + 1
  conn.xfer_q = conn.xfer_q or {}
  conn.xfer_q[conn.q] = t.x
  conn:send({ t = "xfer_offer", q = conn.q, to = t.peer, x = t.x, eph = mp.bin(t.A), sig = mp.bin(sig), files = list })
  t.offered_at = self.env.now()
  self:_set(t, "offered")
end

function Manager:_answered(t, p)
  local C = self.env.crypto
  if not p.ok then return self:_set(t, "declined", (t.peer_name or "They") .. " declined.") end
  if type(p.eph) ~= "string" or #p.eph ~= 32 or type(p.sig) ~= "string" then return self:_set(t, "failed", "Bad answer") end
  local ok = C.ed25519_verify(p.sig, unhex(t.peer), answer_msg(t.conn.server.key, t.x, t.conn.me.user, t.A, p.eph))
  if not ok then return self:_set(t, "failed", "The answer wasn't signed by " .. (t.peer_name or "them") .. ". Stopped.") end
  t.B = p.eph
  t.key = C.blake2b(C.x25519(t.a_sk, t.B) .. t.A .. t.B .. t.x, 32)
  self:_set(t, "connecting")
  self:_start_route(t)
end

------------------------------------------------------------------ receiving
function Manager:_incoming(conn, p)
  local C = self.env.crypto
  local existing = self.by_x[p.x]
  if type(p.files) ~= "table" or #p.files == 0 or #p.files > 20 then return end
  local files = {}
  for i, f in ipairs(p.files) do
    if type(f) ~= "table" or type(f.n) ~= "string" or not compat.is_int(f.s) or f.s < 0 or type(f.h) ~= "string" or #f.h ~= 32 then return end
    files[i] = { name = f.n:gsub("[%c/\\:*?\"<>|]", "_"):sub(1, 200), size = f.s, hash = f.h, have = 0 }
  end
  local digest = files_digest(C, p.files)
  if not C.ed25519_verify(p.sig, unhex(p.from), offer_msg(conn.server.key, p.x, conn.me.user, p.eph, digest)) then return end
  if existing and existing.dir == "in" and existing.peer == p.from then
    -- the same transfer offered again after a dropped connection: continue without asking
    existing.conn, existing.A, existing.relay_ok = conn, p.eph, p.relay
    if existing.state == "interrupted" or existing.state == "connecting" or existing.state == "receiving" then
      existing.resume = true
      self:accept(existing)
    end
    return
  end
  local t = { x = p.x, dir = "in", conn = conn, peer = p.from, peer_name = conn:member_name(p.from), files = files,
              A = p.eph, relay_ok = p.relay, state = "asking", started = self.env.now(), bytes = 0, total = 0 }
  for _, f in ipairs(files) do t.total = t.total + f.size end
  self:_add(t)
end

function Manager:_part_path(f)
  local dir = self.env.downloads_dir()
  return dir .. self.env.sep .. f.name .. ".zunopart"
end

-- A name that doesn't exist yet in Downloads: "photo.jpg", "photo (2).jpg", ...
function Manager:_final_path(name)
  local dir = self.env.downloads_dir()
  local base, ext = name:match("^(.*)(%.[^%.]+)$")
  if not base then base, ext = name, "" end
  local path = dir .. self.env.sep .. name
  local n = 1
  while self.env.size(path) do
    n = n + 1
    path = dir .. self.env.sep .. base .. " (" .. n .. ")" .. ext
  end
  return path
end

function Manager:accept(t)
  local C, conn = self.env.crypto, t.conn
  if conn.status ~= "online" then return end
  -- what we already have from an earlier try
  for _, f in ipairs(t.files) do
    if not f.done and f.size == 0 then
      -- nothing to transfer: just create it
      local hh = self.env.open(self:_final_path(f.name), "wb")
      if hh then hh:close() end
      f.done, f.path = true, self:_final_path(f.name)
    end
    if not f.done then
      f.part = self:_part_path(f)
      local n = self.env.size(f.part) or 0
      if n > f.size then self.env.remove(f.part); n = 0 end
      f.have = n
    end
  end
  t.b_sk, t.B = C.x25519_keypair()
  t.key = C.blake2b(C.x25519(t.b_sk, t.A) .. t.A .. t.B .. t.x, 32)
  local sig = C.ed25519_sign(self:_seed(conn), answer_msg(conn.server.key, t.x, t.peer, t.A, t.B))
  conn:send({ t = "xfer_answer", x = t.x, ok = true, eph = mp.bin(t.B), sig = mp.bin(sig) })
  t.route, t.peer_addr, t.cur = nil, nil, nil
  self:_set(t, "connecting")
  local have = {}
  for i, f in ipairs(t.files) do have[i] = f.done and f.size or f.have end
  self:_send(t, { t = "h", have = have }, true)
  self:_start_route(t)
end

function Manager:decline(t)
  t.conn:send({ t = "xfer_answer", x = t.x, ok = false })
  self:_set(t, "declined", "You declined.")
end

------------------------------------------------------------------ route: direct UDP or relay
function Manager:_start_route(t)
  t.route_started = self.env.now()
  t.probe_n = 0
  if not self.env.udp or not t.conn.transport or not t.conn.transport.ip then return end
  if not t.udp then t.udp = self.env.udp() end
  if not t.udp then return end
  local sip, sport = t.conn.transport.ip, t.conn.port
  local cands = {}
  local lip = t.udp:local_ip(sip)
  if lip and lip ~= "0.0.0.0" then cands[#cands + 1] = { lip, t.udp.port } end
  t.my_cands = cands
  -- ask the server which address it sees for us (hole punching)
  t.stun = self.env.crypto.random(16)
  t.udp:send(sip, sport, "ZU1?" .. t.stun)
  self:_send(t, { t = "c", c = cands }, true)
end

function Manager:_udp_packet(t, data, ip, port)
  if data:sub(1, 4) == "ZU1!" and t.stun and data:sub(5, 20) == t.stun then
    local pip, pport = data:sub(21):match("^(.+):(%d+)$")
    if pip then
      t.stun = nil
      local dup = false
      for _, c in ipairs(t.my_cands or {}) do if c[1] == pip and c[2] == tonumber(pport) then dup = true end end
      if not dup then
        t.my_cands[#t.my_cands + 1] = { pip, tonumber(pport) }
        self:_send(t, { t = "c", c = t.my_cands }, true)
      end
    end
    return
  end
  if data:sub(1, 2) ~= "ZX" or data:sub(3, 14) ~= t.x then return end
  t.dbg_rx = (t.dbg_rx or 0) + 1
  local plain = t.key and self.env.crypto.open(t.key, data:sub(15), t.x)
  local msg = plain and mp.decode(plain)
  if type(msg) ~= "table" then return end
  if msg.t == "p" then
    -- they reached us: answer on the same path
    t.udp:send(ip, port, "ZX" .. t.x .. self:_seal(t, { t = "q", n = msg.n }))
    if t.route ~= "direct" then t.peer_addr = { ip, port }; self:_go_direct(t) end
    return
  elseif msg.t == "q" then
    if t.route ~= "direct" then t.peer_addr = { ip, port }; self:_go_direct(t) end
    return
  end
  if t.route == "direct" then self:_message(t, msg) end
end

function Manager:_go_direct(t)
  t.route = "direct"
  t.cwnd = 128 * 1024
  self:_emit("state", t)
end

function Manager:_probe(t, now)
  if t.route == "direct" or not t.udp or not t.peer_cands then return end
  if now - (t.last_probe or 0) < 0.2 then return end
  t.last_probe = now
  t.probe_n = t.probe_n + 1
  for _, c in ipairs(t.peer_cands) do
    if type(c) == "table" and type(c[1]) == "string" and compat.is_int(c[2]) then
      t.udp:send(c[1], c[2], "ZX" .. t.x .. self:_seal(t, { t = "p", n = t.probe_n }))
    end
  end
end

------------------------------------------------------------------ messages (both routes)
function Manager:_relay_packet(t, p)
  if p.t == "xfer_answer" and t.dir == "out" and t.state == "offered" then return self:_answered(t, p) end
  if p.t == "xfer_end" then
    if t.state ~= "done" then
      if p.why == "answered" and t.dir == "in" and t.state == "asking" then
        return self:_set(t, "cancelled", "Answered on another device")
      end
      if p.why == "cancelled" then return self:_set(t, "cancelled", (t.peer_name or "They") .. " cancelled.") end
      if p.why == "peer_offline" then
        self:_close_files(t)
        for _, f in ipairs(t.files) do f.sending = nil end
        t.cur, t.offered_at = nil, self.env.now()
        return self:_set(t, "interrupted", (t.peer_name or "They") .. " went offline; continues when they're back")
      end
      self:_set(t, "failed", p.why and (p.why:gsub("^%l", string.upper)) or "Stopped")
    end
    return
  end
  if p.t == "err" then
    if t.state == "offered" then self:_set(t, (p.msg or ""):find("offline") and "interrupted" or "failed", (p.msg or "Couldn't offer"):gsub("^%l", string.upper)) end
    return
  end
  if p.t == "xfer_data" and t.key then
    local plain = self.env.crypto.open(t.key, p.d or "", t.x)
    local msg = plain and mp.decode(plain)
    if type(msg) == "table" then self:_message(t, msg) end
  end
end

function Manager:_message(t, msg)
  local now = self.env.now()
  if msg.t == "c" then
    if type(msg.c) == "table" then t.peer_cands = msg.c end
  elseif msg.t == "h" and t.dir == "out" then
    if type(msg.have) == "table" then
      for i, f in ipairs(t.files) do
        local h = msg.have[i]
        f.have = compat.is_int(h) and h >= 0 and h <= f.size and h or 0
        f.done = f.have == f.size or f.done
      end
    end
    t.hello = true
  elseif msg.t == "d" and t.dir == "in" then
    self:_data(t, msg)
  elseif msg.t == "a" and t.dir == "out" then
    self:_ack(t, msg, now)
  elseif msg.t == "fd" then
    local f = t.files[msg.f]
    if t.dir == "out" and f then
      if msg.ok then f.done = true; f.sending = nil
      else f.have, f.next, f.inflight = 0, 0, {}; f.retry = (f.retry or 0) + 1
        if f.retry > 2 then self:_set(t, "failed", f.name .. " arrived damaged three times") end
      end
    end
  elseif msg.t == "pause" then t.peer_paused = true; self:_emit("state", t)
  elseif msg.t == "resume" then t.peer_paused = false; self:_emit("state", t)
  elseif msg.t == "x" then
    self:_set(t, "cancelled", (t.peer_name or "They") .. " cancelled.")
  end
end

-- receiver: one chunk
function Manager:_data(t, msg)
  local i = msg.f
  local f = t.files[i]
  if f and f.done then
    -- they didn't hear that it arrived: say it again (at most a few times a second)
    if self.env.now() - (f.fd_at or 0) > 0.2 then f.fd_at = self.env.now(); self:_send(t, { t = "fd", f = i, ok = true }) end
    return
  end
  if not f or type(msg.d) ~= "string" or not compat.is_int(msg.o) then return end
  if t.state == "connecting" then self:_set(t, "receiving") end
  if t.cur ~= i then
    -- start (or resume) this file
    if t.cur and t.files[t.cur] and t.files[t.cur].h then t.files[t.cur].h:close(); t.files[t.cur].h = nil end
    t.cur = i
    f.h = self.env.open(f.part, f.have > 0 and "ab" or "wb")
    if not f.h then return self:_set(t, "failed", "Couldn't write to Downloads") end
    f.hasher = self.env.crypto.hasher(32)
    if f.have > 0 then
      local r = self.env.open(f.part, "rb")
      while r do local d = r:read(1048576); if not d then break end; f.hasher:update(d) end
      if r then r:close() end
    end
    f.ooo, f.ooo_bytes = {}, 0
  end
  local o, d = msg.o, msg.d
  if o == f.have then
    f.h:write(d); f.hasher:update(d); f.have = f.have + #d; t.bytes = t.bytes + #d
    while f.ooo[f.have] do
      local nd = f.ooo[f.have]
      f.ooo[f.have] = nil; f.ooo_bytes = f.ooo_bytes - #nd
      f.h:write(nd); f.hasher:update(nd); f.have = f.have + #nd; t.bytes = t.bytes + #nd
    end
  elseif o > f.have and not f.ooo[o] and o + #d <= f.size and f.ooo_bytes < 16 * 1024 * 1024 then
    f.ooo[o] = d; f.ooo_bytes = f.ooo_bytes + #d
  end
  t.need_ack = true
  if f.have >= f.size then
    f.h:close(); f.h = nil
    local ok = f.hasher:final() == f.hash
    f.hasher, f.ooo = nil, nil
    if ok then
      f.path = self:_final_path(f.name)
      if not self.env.rename(f.part, f.path) then f.path = f.part end
      f.done = true
    else
      self.env.remove(f.part)
      f.have = 0
    end
    t.cur = nil
    self:_send(t, { t = "fd", f = i, ok = ok })
    if t.route == "direct" then self:_send(t, { t = "fd", f = i, ok = ok }, true) end -- also via the server: UDP may drop it
    self:_send(t, { t = "a", f = i, u = f.have })
    local all = true
    for _, x in ipairs(t.files) do if not x.done then all = false end end
    if all then
      t.done_at = self.env.now()
      self:_set(t, "done")
    end
  end
end

-- receiver: acknowledge what arrived (cumulative + a few out-of-order chunks)
function Manager:_send_ack(t)
  local f = t.cur and t.files[t.cur]
  if not f then return end
  -- what arrived after the gap, as ranges {start, end, start, end, ...}
  local offs = {}
  for o in pairs(f.ooo or {}) do offs[#offs + 1] = o end
  table.sort(offs)
  local ranges = {}
  for _, o in ipairs(offs) do
    local e = o + #f.ooo[o]
    if #ranges > 0 and ranges[#ranges] == o then ranges[#ranges] = e
    elseif #ranges < 128 then ranges[#ranges + 1] = o; ranges[#ranges + 1] = e end
  end
  self:_send(t, { t = "a", f = t.cur, u = f.have, r = ranges })
  t.need_ack, t.last_ack = false, self.env.now()
end

-- sender: an ack
function Manager:_ack(t, msg, now)
  local f = t.files[msg.f]
  if not f or not f.inflight or not compat.is_int(msg.u) then return end
  if t.state == "connecting" then self:_set(t, "sending") end
  local acked, prompt = {}, {}
  for o, c in pairs(f.inflight) do
    if o + c.len <= msg.u then
      acked[#acked + 1] = o
      if o + c.len == msg.u then prompt[o] = true end -- the newest chunk: a fair round-trip sample
    end
  end
  local r = type(msg.r) == "table" and msg.r or {}
  if #r > 0 then
    for o, c in pairs(f.inflight) do
      for k = 1, #r - 1, 2 do
        if compat.is_int(r[k]) and compat.is_int(r[k + 1]) and o >= r[k] and o + c.len <= r[k + 1] then
          acked[#acked + 1] = o
          if o + c.len == r[k + 1] then prompt[o] = true end
          break
        end
      end
    end
  end
  for _, o in ipairs(acked) do
    local c = f.inflight[o]
    if c then
      f.inflight[o] = nil
      f.inflight_bytes = f.inflight_bytes - c.len
      if c.tries == 1 and prompt[o] then
        local rtt = now - c.t
        t.srtt = t.srtt and (t.srtt * 0.875 + rtt * 0.125) or rtt
      end
      if t.route == "direct" then t.cwnd = math.min(8 * 1024 * 1024, t.cwnd + c.len * math.max(1, 64 * 1024 / t.cwnd)) end
    end
  end
  if msg.u > f.acked then t.bytes = t.bytes + (msg.u - f.acked); f.acked = msg.u end
end

------------------------------------------------------------------ sender loop
function Manager:_pump(t, now)
  if t.paused or t.peer_paused or not t.hello or not t.route then return end
  local direct = t.route == "direct"
  local chunk = direct and X.DIRECT_CHUNK or X.RELAY_CHUNK
  local window = direct and t.cwnd or X.RELAY_WINDOW
  local i = nil
  for k, f in ipairs(t.files) do if not f.done then i = k; break end end
  if not i then
    local all_done = true
    for _, f in ipairs(t.files) do if not f.done then all_done = false end end
    if all_done then self:_set(t, "done") end
    return
  end
  local f = t.files[i]
  if not f.sending then
    f.sending = true
    f.next = f.have; f.acked = f.have
    f.inflight, f.inflight_bytes = {}, 0
    if f.h then f.h:close() end
    f.h = self.env.open(f.path, "rb")
    if not f.h then return self:_set(t, "failed", "Couldn't read " .. f.name) end
    if t.state == "connecting" then self:_set(t, "sending") end
  end
  -- retransmit what seems lost (only matters on the direct route)
  local rto = math.min(1, math.max(0.25, (t.srtt or 0.2) * 2.5))
  if direct then
    local resent = 0
    for o, c in pairs(f.inflight) do
      if now - c.t > rto and resent < 64 then
        f.h:seek(o)
        local d = f.h:read(c.len)
        if d then
          if not self:_send(t, { t = "d", f = i, o = o, d = d }) then t.dbg_fail = (t.dbg_fail or 0) + 1 end
          t.dbg_resent = (t.dbg_resent or 0) + 1
        end
        c.t, c.tries = now, c.tries + 1
        resent = resent + 1
      end
    end
    if resent > 0 and now - (t.last_cut or 0) > (t.srtt or 0.2) then
      t.cwnd = math.max(32 * 1024, t.cwnd / 2); t.last_cut = now
    end
  end
  -- new data
  local sent = 0
  -- bursts are kept small so the other side's buffer doesn't overflow; this runs every frame
  local burst = direct and 192 * 1024 or 2 * 1024 * 1024
  while f.next < f.size and f.inflight_bytes < window and sent < burst do
    f.h:seek(f.next)
    local d = f.h:read(math.min(chunk, f.size - f.next))
    if not d then break end
    if not self:_send(t, { t = "d", f = i, o = f.next, d = d }) then break end
    f.inflight[f.next] = { len = #d, t = now, tries = 1 }
    f.inflight_bytes = f.inflight_bytes + #d
    f.next = f.next + #d
    sent = sent + #d
  end
end

------------------------------------------------------------------ updates
function Manager:update()
  local now = self.env.now()
  for _, t in ipairs(self.list) do
    local st = t.state
    if st == "hashing" then
      self:_hash_step(t)
    elseif st == "connecting" or st == "sending" or st == "receiving" then
      if t.conn.status ~= "online" then
        self:_close_files(t)
        for _, f in ipairs(t.files) do f.sending = nil end
        t.cur = nil
        self:_set(t, "interrupted", "Connection lost; continues when you're both back")
      else
        if t.udp then
          for _ = 1, 4096 do
            if not t.udp then break end -- finished while reading
            local data, ip, port = t.udp:receive()
            if not data then break end
            self:_udp_packet(t, data, ip, port)
          end
        end
        self:_probe(t, now)
        if not t.route and t.route_started and now - t.route_started > X.PROBE_TIME then
          local relay = (t.dir == "in" and t.relay_ok) or (t.dir == "out" and t.conn.limits and t.conn.limits.relay)
          if relay then t.route = "relay"; self:_emit("state", t)
          else self:_set(t, "failed", "No direct connection, and this server doesn't relay transfers.") end
        end
        if t.dir == "out" then self:_pump(t, now)
        elseif (t.need_ack and now - (t.last_ack or 0) > X.ACK_EVERY) or now - (t.last_ack or 0) > 0.25 then
          self:_send_ack(t) -- also now and then without news, in case an ack got lost
        end
      end
    elseif st == "interrupted" and t.dir == "out" then
      -- try again when we're connected and they're online
      local m = t.conn.members[t.peer]
      if t.conn.status == "online" and m and m.online and now - (t.offered_at or 0) > 5 then self:_offer(t) end
    elseif st == "offered" and t.conn.status ~= "online" then
      self:_set(t, "interrupted", "Connection lost")
    end
    if X.debug and (st == "sending" or st == "receiving" or st == "connecting") and now - (t.dbg_t or 0) > 1 then
      t.dbg_t = now
      local f = t.cur and t.files[t.cur] or t.files[1]
      local n = 0
      for _ in pairs(f.inflight or {}) do n = n + 1 end
      local ooo = 0
      for _ in pairs(f.ooo or {}) do ooo = ooo + 1 end
      X.debug(("[xfer %s] %s %s route=%s have=%s next=%s acked=%s inflight=%d bytes=%s cwnd=%s srtt=%s rx=%s resent=%s fail=%s ooo=%d peer=%s"):format(t.x, t.dir, t.state,
        tostring(t.route), tostring(f.have), tostring(f.next), tostring(f.acked), n, tostring(f.inflight_bytes), tostring(t.cwnd), tostring(t.srtt),
        tostring(t.dbg_rx), tostring(t.dbg_resent), tostring(t.dbg_fail), ooo, t.peer_addr and (t.peer_addr[1] .. ":" .. t.peer_addr[2]) or "-"))
    end
    -- speed (bytes per second, smoothed)
    local dt = now - (t.speed_t or now)
    if dt >= 0.5 then
      local rate = (t.bytes - (t.speed_bytes or t.bytes)) / dt
      t.speed = t.speed and (t.speed * 0.6 + rate * 0.4) or rate
      t.speed_t, t.speed_bytes = now, t.bytes
    elseif not t.speed_t then t.speed_t, t.speed_bytes = now, t.bytes end
  end
end

-- Packets from a connection (model emits "xfer" with server packets and errors).
function Manager:packet(conn, p)
  if p.t == "xfer_offer" then return self:_incoming(conn, p) end
  local x = p.x
  if p.t == "err" and p.re and conn.xfer_q then x = conn.xfer_q[p.re] end
  local t = x and self.by_x[x]
  if t and t.conn == conn then self:_relay_packet(t, p) end
end

function Manager:active()
  local n = 0
  for _, t in ipairs(self.list) do
    if t.state == "hashing" or t.state == "offered" or t.state == "connecting" or t.state == "sending" or t.state == "receiving" then n = n + 1 end
  end
  return n
end

function Manager:pause(t, on)
  t.paused = on
  self:_send(t, { t = on and "pause" or "resume" })
  self:_emit("state", t)
end

function Manager:cancel(t)
  if t.state == "done" then return end
  if t.key then self:_send(t, { t = "x" }, true) end
  t.conn:send({ t = "xfer_end", x = t.x, why = "cancelled" })
  if t.dir == "in" then for _, f in ipairs(t.files) do if not f.done and f.part then self:_close_files(t); self.env.remove(f.part) end end end
  self:_set(t, "cancelled", "Cancelled")
end

function Manager:dismiss(t)
  for i, x in ipairs(self.list) do if x == t then table.remove(self.list, i); break end end
  self.by_x[t.x] = nil
end

function Manager:progress(t)
  if t.state == "hashing" then return (t.hashed or 0) / math.max(1, t.total) end
  local done = 0
  for _, f in ipairs(t.files) do
    if f.done then done = done + f.size
    elseif t.dir == "in" then done = done + (f.have or 0)
    else done = done + (f.acked or f.have or 0) end
  end
  return done / math.max(1, t.total)
end

X.Manager = Manager
return X
