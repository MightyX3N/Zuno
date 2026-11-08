-- Device linking (PLAN 5.1). The old device ("sender") holds the account; the new device
-- ("receiver") wants it. They meet through a Zuno server that only relays opaque bytes.
--
--   1. Sender asks its server for a link code (sid). It shows a QR with
--      https://zuno.dovecross.site/link#1.<server, sid, A> and the same as typeable text.
--   2. Receiver connects to that server as a guest and joins the sid (one join only).
--   3. Both exchange ephemeral X25519 keys A and B through the relay and derive the same
--      secret k. The receiver SHOWS a 6-digit code made from k; the user TYPES it on the sender.
--      A relay that swapped keys would make the two codes differ, so nothing is sent.
--      (With the QR the receiver also knows A in advance and checks it.)
--   4. Only after the code matches, the sender sends the account sealed with k.
local mp = require("zuno.msgpack")
local compat = require("zuno.compat")
local Session = require("zuno.session")
local model = require("zuno_ui.model")
local Account = require("zuno_ui.account")

local L = {}
L.URL = "https://zuno.dovecross.site/link#"
L.MAX_TRIES = 3

------------------------------------------------------------------ base64url
local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
function L.b64url(s)
  local out = {}
  for i = 1, #s, 3 do
    local a, b, c = s:byte(i, i + 2)
    local n = a * 65536 + (b or 0) * 256 + (c or 0)
    local chars = 2 + (b and 1 or 0) + (c and 1 or 0)
    for j = 1, chars do
      local v = math.floor(n / 2 ^ (18 - 6 * (j - 1))) % 64
      out[#out + 1] = B64:sub(v + 1, v + 1)
    end
  end
  return table.concat(out)
end

function L.unb64url(s)
  if s:find("[^%w%-_]") then return nil end
  local out, n, bits = {}, 0, 0
  for i = 1, #s do
    n = n * 64 + (B64:find(s:sub(i, i), 1, true) - 1)
    bits = bits + 6
    if bits >= 8 then
      bits = bits - 8
      local v = math.floor(n / 2 ^ bits)
      out[#out + 1] = string.char(v)
      n = n - v * 2 ^ bits
    end
  end
  return table.concat(out)
end

------------------------------------------------------------------ link text
function L.make_url(address, sid, A)
  return L.URL .. "1." .. L.b64url(mp.encode({ s = address, i = sid, k = mp.bin(A) }))
end

local function norm_sid(s)
  s = (s or ""):upper():gsub("[^0-9A-Z]", ""):gsub("O", "0"):gsub("[IL]", "1")
  if #s ~= 8 then return nil end
  return s:sub(1, 4) .. "-" .. s:sub(5, 8)
end
L.norm_sid = norm_sid

-- Accepts the full link (QR / pasted), or an address plus a code.
-- Returns { address, sid, A (optional) } or nil + message.
function L.parse(address_text, code_text)
  local all = ((address_text or "") .. " " .. (code_text or "")):gsub("^%s+", "")
  local payload = all:match("/link#1%.([%w%-_]+)") or all:match("^1%.([%w%-_]+)")
  if payload then
    local raw = L.unb64url(payload)
    local t = raw and mp.decode(raw)
    if type(t) ~= "table" or type(t.s) ~= "string" or type(t.i) ~= "string" or type(t.k) ~= "string" or #t.k ~= 32 then
      return nil, "That link is damaged. Try the code instead."
    end
    if not model.parse_address(t.s) then return nil, "That link has a bad server address." end
    return { address = t.s, sid = norm_sid(t.i), A = t.k }
  end
  local addr = model.parse_address(address_text or "")
  if not addr then return nil, "Type the server address shown on your other device." end
  local sid = norm_sid(code_text)
  if not sid then return nil, "The link code is 8 letters and numbers, like K7QM-9XTD." end
  return { address = addr.address, sid = sid }
end

------------------------------------------------------------------ crypto
function L.derive(C, shared, A, B, sid)
  local k = C.blake2b(shared .. A .. B .. sid, 32)
  local enc = C.blake2b("zuno-link-key" .. k, 32)
  local h = C.blake2b("zuno-link-code" .. k, 32)
  local n = ((h:byte(1) * 256 + h:byte(2)) * 256 + h:byte(3)) * 256 + h:byte(4)
  return enc, ("%06d"):format(n % 1000000)
end

------------------------------------------------------------------ sender (old device)
local Sender = {}
Sender.__index = Sender

-- conn: an online model Conn. account: function() -> account table. now: clock.
function L.sender(C, conn, address_for_new_device, account)
  local self = setmetatable({ C = C, conn = conn, address = address_for_new_device, account = account,
    state = "opening", tries = 0 }, Sender)
  self.a_sk, self.A = C.x25519_keypair()
  self.unsub = conn:on(function(ev, p) if ev == "link" then self:_packet(p) end end)
  L.q = (L.q or 900000) + 1
  self.q = L.q
  if not conn:send({ t = "link_open", q = self.q }) then self:_fail("Not connected to the server.") end
  return self
end

function Sender:_fail(msg) self.state = "failed"; self.error = msg; self:_stop() end
function Sender:_stop() if self.unsub then self.unsub(); self.unsub = nil end end

function Sender:_send(t)
  self.conn:send({ t = "link_data", sid = self.sid, d = mp.bin(mp.encode(t)) })
end

function Sender:_packet(p)
  if p.t == "link_opened" then
    if p.re ~= self.q or self.sid then return end -- someone else's link
    self.sid = p.sid
    self.expires = self.conn.env.now() + (p.expires_in or 120)
    self.url = L.make_url(self.address, p.sid, self.A)
    self.state = "waiting"
  elseif p.sid ~= self.sid then
    return
  elseif p.t == "link_event" then
    if p.ev == "joined" then
      self.state = "joined"
      self:_send({ t = "hello", pk = mp.bin(self.A) })
    elseif p.ev == "second_scan" then
      self:_fail("Someone else tried to use this link code, so the link was cancelled. Start again, and keep the code private.")
    elseif p.ev == "expired" then
      self:_fail("The link code expired. Start again.")
    elseif self.state ~= "done" then
      self:_fail("The other device left.")
    end
  elseif p.t == "link_data" then
    local m = mp.decode(p.d or "")
    if type(m) ~= "table" then return end
    if m.t == "hello" and type(m.pk) == "string" and #m.pk == 32 and not self.B then
      self.B = m.pk
      self.key, self.code = L.derive(self.C, self.C.x25519(self.a_sk, self.B), self.A, self.B, self.sid)
      self.state = "code"
    elseif m.t == "done" then
      self.state = "done"
      self.conn:send({ t = "link_close", sid = self.sid })
      self:_stop()
    elseif m.t == "cancel" then
      self:_fail("The other device cancelled.")
    end
  end
end

-- The user typed the code shown on the new device. Returns true if it matched.
function Sender:enter_code(text)
  if self.state ~= "code" then return false end
  local typed = (text or ""):gsub("%D", "")
  if typed == self.code then
    self.state = "sending"
    local box = self.C.seal(self.key, Account.encode_package(self.account()), "zuno-link")
    self:_send({ t = "account", box = mp.bin(box) })
    return true
  end
  self.tries = self.tries + 1
  if self.tries >= L.MAX_TRIES then
    self:_send({ t = "cancel" })
    self.conn:send({ t = "link_close", sid = self.sid })
    self:_fail("Wrong code too many times, so the link was cancelled.")
  end
  return false
end

function Sender:remaining() return self.expires and math.max(0, math.floor(self.expires - self.conn.env.now())) or nil end

function Sender:update()
  if (self.state == "waiting" or self.state == "joined") and self.expires and self.conn.env.now() > self.expires then
    self:_fail("The link code expired. Start again.")
  end
  if self.conn.status ~= "online" and self.state ~= "done" and self.state ~= "failed" then
    self:_fail("Lost the connection to the server.")
  end
end

function Sender:cancel()
  if self.sid and self.state ~= "done" and self.state ~= "failed" then
    if self.state == "code" or self.state == "joined" then self:_send({ t = "cancel" }) end
    self.conn:send({ t = "link_close", sid = self.sid })
  end
  self.state = "failed"
  self:_stop()
end

------------------------------------------------------------------ receiver (new device)
local Receiver = {}
Receiver.__index = Receiver

-- env: { crypto, transport, now }. target from L.parse.
function L.receiver(env, target)
  local C = env.crypto
  local addr = assert(model.parse_address(target.address))
  local self = setmetatable({ env = env, C = C, target = target, state = "connecting" }, Receiver)
  self.b_sk, self.B = C.x25519_keypair()
  self.session = Session.client(C, { identity_seed = C.ed25519_new_seed(), name = "linking", guest = true })
  self.transport = env.transport(addr.host, addr.port)
  self.started = env.now()
  return self
end

function Receiver:_fail(msg)
  if self.state == "failed" then return end
  self.state = "failed"; self.error = msg
  if self.transport then self.transport:close() end
end

function Receiver:_send(pkt)
  if not self.session:send(pkt) then return end
  local out = self.session:pull()
  if out then self.transport:send(out) end
end

function Receiver:_data(t) self:_send({ t = "link_data", sid = self.target.sid, d = mp.bin(mp.encode(t)) }) end

function Receiver:update()
  if self.state == "done" or self.state == "failed" then return end
  local st, err = self.transport:status()
  if st == "closed" then return self:_fail(err and ("Couldn't reach the server: " .. err) or "The connection closed.") end
  if st ~= "open" then
    if self.env.now() - self.started > 15 then self:_fail("Couldn't reach the server.") end
    return
  end
  if not self.started_session then
    self.started_session = true
    self.session:start()
  end
  while true do
    local data = self.transport:receive()
    if not data then break end
    for _, ev in ipairs(self.session:feed(data)) do self:_event(ev) end
    if self.state == "failed" then return end
  end
  local out = self.session:pull()
  if out then self.transport:send(out) end
end

function Receiver:_event(ev)
  if ev.type == "error" then return self:_fail("Couldn't connect securely: " .. tostring(ev.message)) end
  if ev.type == "ready" then
    self.state = "joining"
    self:_send({ t = "link_join", sid = self.target.sid })
    return
  end
  local p = ev.packet
  if p.t == "err" then return self:_fail((p.msg or "The server refused the link."):gsub("^%l", string.upper) .. ".") end
  if p.t == "link_joined" then
    self.state = "waiting"
    self:_data({ t = "hello", pk = mp.bin(self.B) })
  elseif p.t == "link_event" then
    if self.state ~= "done" then self:_fail(p.ev == "expired" and "The link code expired." or "The other device cancelled the link.") end
  elseif p.t == "link_data" then
    local m = mp.decode(p.d or "")
    if type(m) ~= "table" then return end
    if m.t == "hello" and type(m.pk) == "string" and #m.pk == 32 and not self.A then
      if self.target.A and self.target.A ~= m.pk then
        return self:_fail("The other device's key doesn't match the QR code. Someone may be interfering, so the link was stopped.")
      end
      self.A = m.pk
      self.key, self.code = L.derive(self.C, self.C.x25519(self.b_sk, self.A), self.A, self.B, self.target.sid)
      self.state = "show_code"
    elseif m.t == "account" and self.key then
      local plain = self.C.open(self.key, m.box or "", "zuno-link")
      local acc = plain and Account.decode_package(plain)
      if not acc then return self:_fail("The account couldn't be read. Try again.") end
      self.account = acc
      self:_data({ t = "done" })
      self.state = "done"
    elseif m.t == "cancel" then
      self:_fail("The other device cancelled the link (wrong code?).")
    end
  end
end

function Receiver:cancel()
  if self.state ~= "done" and self.state ~= "failed" and self.session:is_ready() then
    self:_data({ t = "cancel" })
    self:_send({ t = "link_close", sid = self.target.sid })
  end
  self:_fail("Cancelled.")
end

L.Sender, L.Receiver = Sender, Receiver
return L
