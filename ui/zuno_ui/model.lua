-- Client core: one Conn per server the user has added. No drawing and no sockets here:
-- the platform gives a transport factory, a crypto backend and a clock, so the same code
-- runs in the LÖVE client, in tests and (later) in the browser.
--
-- transport interface:  t = factory(host, port)
--   t:status()  -> "connecting" | "open" | "closed", err
--   t:send(bytes)        t:receive() -> bytes or nil        t:close()
local Session = require("zuno.session")
local P = require("zuno.packets")
local compat = require("zuno.compat")

local M = {}

M.PING_EVERY = 25      -- seconds
M.TYPING_SHOWN = 6     -- seconds a typing indicator stays without a new event
M.TYPING_SEND_EVERY = 3

--------------------------------------------------------------------- addresses
-- "host:port", "host:port#FINGERPRINTHEX", "[v6]:port". Default port 41234.
function M.parse_address(text)
  if type(text) ~= "string" then return nil, "empty address" end
  text = text:gsub("^%s+", ""):gsub("%s+$", "")
  text = text:gsub("^zuno://", "")
  local addr, fp = text:match("^([^#]+)#(%x+)$")
  if not addr then addr = text end
  local host, port = addr:match("^%[([%x:]+)%]:(%d+)$")
  if not host then host, port = addr:match("^([%w%.%-]+):(%d+)$") end
  if not host then host = addr:match("^([%w%.%-]+)$"); port = "41234" end
  if not host or host == "" then return nil, "That doesn't look like a server address. Example: my-server.at.ply.gg:41234" end
  port = tonumber(port)
  if not port or port < 1 or port > 65535 then return nil, "The port must be a number from 1 to 65535" end
  if fp and #fp < 16 then return nil, "The part after # must be the server's key fingerprint (at least 16 characters)" end
  return { host = host:lower(), port = port, fingerprint = fp and fp:lower() or nil,
           address = (host:find(":") and ("[" .. host .. "]") or host:lower()) .. ":" .. port }
end

--------------------------------------------------------------------- Conn
local Conn = {}
Conn.__index = Conn
M.Conn = Conn

-- env: { crypto, transport (factory), now (fn -> seconds), identity_seed, name (display name) }
-- entry: { address, key (pinned server key hex, optional), name (last known server name), fingerprint }
function M.new_conn(env, entry)
  local self = setmetatable({}, Conn)
  self.env, self.entry = env, entry
  local parsed = assert(M.parse_address(entry.address))
  self.host, self.port = parsed.host, parsed.port
  if parsed.fingerprint and not entry.key then entry.fingerprint = parsed.fingerprint end
  self.status = "offline"
  self.error = nil
  self.attempt = 0
  self.next_try = 0
  self.listeners = {}
  self:_reset_state()
  return self
end

function Conn:_reset_state()
  self.channels = {}          -- ordered list
  self.channel_by_id = {}
  self.members = {}           -- key -> { user, name, role, online }
  self.me = nil
  self.server = nil
  self.typing = {}            -- ch -> { [user] = expires }
  self.latency = nil
  self.msgs = self.msgs or {} -- ch -> store (kept across reconnects for resume)
  self.unread = self.unread or {}
  self.mentions = self.mentions or {} -- ch -> count of unread messages that mention me / reply to me
  self.last_read = self.last_read or {}
  self.pending = self.pending or {}
end

-- Subscribe to events. Returns a function that unsubscribes.
function Conn:on(fn)
  self.listeners[#self.listeners + 1] = fn
  return function()
    for i, f in ipairs(self.listeners) do if f == fn then table.remove(self.listeners, i); return end end
  end
end
function Conn:_emit(ev, a, b)
  local list = {}
  for i, fn in ipairs(self.listeners) do list[i] = fn end -- listeners may unsubscribe while we loop
  for _, fn in ipairs(list) do fn(ev, a, b, self) end
end

function Conn:connect()
  if self.transport then self.transport:close() end
  self.gen = (self.gen or 0) + 1 -- events still queued from the old connection are dropped
  self.status = "connecting"
  self.error = nil
  self.transport = self.env.transport(self.host, self.port)
  self.session = nil
  self.started_at = self.env.now()
  self:_emit("status")
end

function Conn:disconnect(manual)
  if self.transport then self.transport:close() end
  self.transport, self.session = nil, nil
  self.status = manual and "offline" or self.status
  self.manual_off = manual
  self:_emit("status")
end

function Conn:_went_offline()
  self.latency = nil
  self.typing = {}
  for _, m in pairs(self.members) do m.online = false end -- unknown until we're back
end

function Conn:_schedule_retry(reason)
  if self.transport then self.transport:close() end
  self.transport, self.session = nil, nil
  self:_went_offline()
  self.attempt = self.attempt + 1
  local delay = math.min(30, 2 ^ math.min(self.attempt, 5)) -- 2, 4, 8, 16, 30 s
  self.next_try = self.env.now() + delay
  self.status = "waiting"
  self.error = reason
  self:_emit("status")
end

function Conn:retry_now() self.next_try = 0; self.attempt = 0; if self.status ~= "online" then self:connect() end end

-- Trust a changed server key (after the user confirmed) and reconnect.
function Conn:accept_new_key()
  if self.changed_key then
    self.entry.key = self.changed_key
    self.changed_key = nil
    self.msgs, self.unread, self.last_read, self.pending = {}, {}, {}, {}
    self:_emit("entry")
    self:retry_now()
  end
end

function Conn:send(pkt)
  if self.status ~= "online" or not self.session then return false end
  if not self.session:send(pkt) then return false end
  local bytes = self.session:pull()
  if bytes then self.transport:send(bytes) end
  return true
end

-- Called every frame.
function Conn:update()
  local now = self.env.now()
  if self.status == "offline" and not self.manual_off and self.attempt == 0 then self:connect() end
  if self.status == "waiting" and now >= self.next_try then self:connect() end
  local t = self.transport
  if not t then return end

  local st, err = t:status()
  if st == "closed" then
    if self.status == "key_changed" or self.status == "outdated" or self.status == "key_replaced" then return end
    return self:_schedule_retry(err or "connection lost")
  end
  if st == "connecting" then
    if now - self.started_at > 15 then self:_schedule_retry("couldn't reach the server") end
    return
  end

  if not self.session then
    self.session = Session.client(self.env.crypto, {
      identity_seed = self.seed or self.env.identity_seed, name = self.env.name(), pinned_key = self.entry.key,
      max = self.env.max_version, -- tests pretend to be an older client
    })
    self.session:start()
    self.status = "handshake"
    self:_emit("status")
  end

  local gen = self.gen
  while true do
    local data = t:receive()
    if not data then break end
    for _, ev in ipairs(self.session:feed(data)) do
      self:_on_event(ev)
      if self.gen ~= gen or not self.session then return end
    end
  end
  local out = self.session and self.session:pull()
  if out then t:send(out) end

  if self.status == "handshake" and now - self.started_at > 20 then
    return self:_schedule_retry("the server didn't answer")
  end
  if self.status == "online" then
    if now - (self.last_ping or 0) > M.PING_EVERY then
      self.last_ping = now
      self.ping_sent = now
      self:send({ t = "ping", n = math.floor(now * 1000) })
    end
    for ch, users in pairs(self.typing) do
      for user, exp in pairs(users) do
        if now > exp then users[user] = nil; self:_emit("typing", ch) end
      end
    end
  end
end

function Conn:_on_event(ev)
  if ev.type == "ready" then
    if self.entry.fingerprint and not ev.peer_key:find("^" .. self.entry.fingerprint) then
      self.status = "key_changed"
      self.changed_key = ev.peer_key
      self.error = "This server's key doesn't match the fingerprint in your invite."
      self.transport:close(); self.session = nil
      return self:_emit("status")
    end
    if not self.entry.key then
      self.entry.key = ev.peer_key -- trust on first use
      self.entry.fingerprint = nil
      self:_emit("entry")
    end
    self.status = "online"
    self.attempt = 0
    self.error = nil
    self.last_ping = self.env.now()
    self.ping_sent = self.env.now()
    self.session_version = ev.version
    self:send({ t = "ping", n = 0 })
    self:send({ t = "sync" })
    self:_emit("status")
  elseif ev.type == "packet" then
    self:_on_packet(ev.packet)
  elseif ev.type == "error" then
    self.session = nil
    self:_went_offline()
    if ev.code == "server_key_changed" then
      self.status = "key_changed"
      self.changed_key = ev.new_key
      self.error = "It could be a different server pretending to be this one."
      self.transport:close()
      self:_emit("status")
    elseif ev.code == "client_outdated" or ev.code == "server_outdated" then
      self.status = "outdated"
      self.error = ev.code == "client_outdated" and "This server needs a newer version of Zuno. Please update."
        or "This server runs an older version of Zuno than yours. Ask the owner to update it."
      self.transport:close()
      self:_emit("status")
    else
      self:_schedule_retry(ev.message)
    end
  end
end

--------------------------------------------------------------------- message stores
local function store_for(self, ch)
  local s = self.msgs[ch]
  if not s then
    s = { list = {}, by_id = {}, loaded = false, more = true, loading = false, rev = 0 }
    self.msgs[ch] = s
  end
  return s
end
Conn.store_for = store_for

local function insert_sorted(list, m)
  local i = #list
  while i > 0 and list[i].id > m.id do i = i - 1 end
  table.insert(list, i + 1, m)
end

local function apply_msg(self, m)
  local s = store_for(self, m.ch)
  if m.rev and m.rev > s.rev then s.rev = m.rev end
  local cur = s.by_id[m.id]
  if m.deleted then
    if cur then
      for i, x in ipairs(s.list) do if x == cur then table.remove(s.list, i); break end end
      s.by_id[m.id] = nil
    end
    return "deleted"
  end
  if cur then
    cur.body, cur.edited, cur.rev, cur.reply, cur.rx = m.body, m.edited, m.rev, m.reply, m.rx
    return "edited"
  end
  local entry = { id = m.id, ch = m.ch, a = m.a, at = m.at, body = m.body, edited = m.edited, rev = m.rev,
                  reply = m.reply, rx = m.rx }
  s.by_id[m.id] = entry
  insert_sorted(s.list, entry)
  return "new", entry
end

-- Does this message ping me? (an @mention of my key, or a reply to one of my messages)
function Conn:pings_me(m)
  local me = self.me and self.me.user
  if not me or m.a == me then return false end
  if m.body and m.body:find("<@" .. me .. ">", 1, true) then return true end
  return type(m.reply) == "table" and m.reply.a == me
end

function Conn:_on_packet(p)
  local t = p.t
  if t == "state" then
    self.server = p.server
    self.me = p.me
    self.unclaimed = p.unclaimed
    if p.server and p.server.name and self.entry.name ~= p.server.name then
      self.entry.name = p.server.name; self:_emit("entry")
    end
    self.channels, self.channel_by_id = {}, {}
    for _, ch in ipairs(p.channels or {}) do
      self.channels[#self.channels + 1] = ch
      self.channel_by_id[ch.id] = ch
    end
    self.members = {}
    for _, m in ipairs(p.members or {}) do self.members[m.user] = m end
    -- drop stores for channels that no longer exist; resume the ones we have
    for ch in pairs(self.msgs) do if not self.channel_by_id[ch] then self.msgs[ch] = nil end end
    for ch, s in pairs(self.msgs) do
      if s.loaded then self:send({ t = "since", ch = ch, rev = s.rev }) end
    end
    -- resend messages that never got confirmed
    for nonce, pm in pairs(self.pending) do
      if pm.state == "sending" then self:send({ t = "send", ch = pm.ch, body = pm.body, nonce = nonce, reply = pm.reply_to }) end
    end
    self:_emit("state")
  elseif t == "messages" then
    local s = store_for(self, p.ch)
    if p.reset then
      s.list, s.by_id, s.loaded, s.more, s.rev = {}, {}, false, true, 0
      self:load_history(p.ch)
      return
    end
    local new_count = 0
    for _, m in ipairs(p.list or {}) do
      m.ch = p.ch
      local kind = apply_msg(self, m)
      if kind == "new" and p.since and m.a ~= (self.me and self.me.user) then
        new_count = new_count + 1
        if self:pings_me(m) and self.view_ch ~= p.ch then self.mentions[p.ch] = (self.mentions[p.ch] or 0) + 1 end
      end
    end
    if p.since == nil then -- a history page
      s.loading = false
      s.loaded = true
      s.more = p.more and true or false
    end
    if new_count > 0 and self.view_ch ~= p.ch then
      self.unread[p.ch] = (self.unread[p.ch] or 0) + new_count
    end
    self:_emit("messages", p.ch, p.before)
  elseif t == "msg" then
    if p.nonce and self.pending[p.nonce] then self.pending[p.nonce] = nil end
    local kind = apply_msg(self, p)
    local mine = self.me and p.a == self.me.user
    if kind == "new" then
      if self.typing[p.ch] then self.typing[p.ch][p.a] = nil end
      if not mine and self.view_ch ~= p.ch then self.unread[p.ch] = (self.unread[p.ch] or 0) + 1 end
      if mine then self.last_read[p.ch] = p.id end
      local ping = self:pings_me(p)
      if ping and self.view_ch ~= p.ch then self.mentions[p.ch] = (self.mentions[p.ch] or 0) + 1 end
      if not mine then self:_emit("incoming", p, ping) end
    end
    self:_emit("msg", p.ch, kind)
  elseif t == "typing" then
    self.typing[p.ch] = self.typing[p.ch] or {}
    self.typing[p.ch][p.user] = self.env.now() + M.TYPING_SHOWN
    self:_emit("typing", p.ch)
  elseif t == "presence" then
    local m = self.members[p.user]
    if m then m.online = p.online end
    self:_emit("members")
  elseif t == "member" then
    self.members[p.user] = { user = p.user, name = p.name, role = p.role, online = p.online }
    if self.me and self.me.user == p.user then self.me.name, self.me.role = p.name, p.role end
    if p.role == "owner" then self.unclaimed = nil end
    self:_emit("members")
  elseif t == "channel" then
    local existing = self.channel_by_id[p.id]
    if existing then
      existing.name, existing.topic = p.name, p.topic
    else
      local ch = { id = p.id, name = p.name, kind = p.kind, topic = p.topic, position = p.position }
      self.channels[#self.channels + 1] = ch
      self.channel_by_id[ch.id] = ch
    end
    self:_emit("channels")
  elseif t == "channel_removed" then
    for i, ch in ipairs(self.channels) do if ch.id == p.ch then table.remove(self.channels, i); break end end
    self.channel_by_id[p.ch] = nil
    self.msgs[p.ch] = nil
    self:_emit("channels")
  elseif t == "pong" then
    if p.n and p.n > 0 then self.latency = math.max(0, math.floor(self.env.now() * 1000 - p.n)) end
    if p.n == 0 and self.ping_sent then self.latency = math.floor((self.env.now() - self.ping_sent) * 1000) end
    self:_emit("latency")
  elseif t == "err" and p.code == "key_replaced" then
    if self.rekeying then return end -- we replaced it ourselves; the controller reconnects
    self.status = "key_replaced"
    self.error = "This account's key was replaced on another device, so this device can't sign in any more. Link it again or import your account."
    if self.transport then self.transport:close() end
    self.session = nil
    self:_went_offline()
    self:_emit("status")
  elseif t == "rekeyed" or t == "member_rekeyed" then
    -- someone's identity (maybe ours) moved to a new key: update everything we have locally
    local m = self.members[p.old]
    if m then self.members[p.old] = nil; m.user = p.new; self.members[p.new] = m end
    local old_tag, new_tag = "<@" .. p.old .. ">", "<@" .. p.new .. ">"
    for _, s in pairs(self.msgs) do
      for _, msg in ipairs(s.list) do
        if msg.a == p.old then msg.a = p.new end
        if msg.body:find(old_tag, 1, true) then msg.body = msg.body:gsub(old_tag:gsub("%p", "%%%0"), new_tag) end
        if type(msg.reply) == "table" and msg.reply.a == p.old then msg.reply.a = p.new end
        for _, r in ipairs(msg.rx or {}) do for i, k in ipairs(r[2]) do if k == p.old then r[2][i] = p.new end end end
      end
    end
    for _, pm in pairs(self.pending) do if pm.a == p.old then pm.a = p.new end end
    if self.me and self.me.user == p.old then self.me.user = p.new end
    self:_emit("members")
    if t == "rekeyed" then self:_emit("rekeyed", p) end
  elseif t == "err" then
    if p.re and self.pending_q and self.pending_q[p.re] then
      local pm = self.pending[self.pending_q[p.re]]
      if pm then pm.state = "failed"; pm.error = p.msg end
    end
    self:_emit("error", p.msg or p.code, p.code)
  elseif t == "notice" then
    self:_emit("notice", p.msg)
  elseif t:sub(1, 5) == "link_" then
    self:_emit("link", p)
  end
end

--------------------------------------------------------------------- actions used by the UI
function Conn:text_channels()
  local out = {}
  for _, ch in ipairs(self.channels) do if ch.kind == "text" then out[#out + 1] = ch end end
  return out
end

function Conn:voice_channels()
  local out = {}
  for _, ch in ipairs(self.channels) do if ch.kind == "voice" then out[#out + 1] = ch end end
  return out
end

function Conn:load_history(ch)
  local s = store_for(self, ch)
  if s.loading or (s.loaded and not s.more) then return end
  s.loading = true
  local before = s.loaded and s.list[1] and s.list[1].id or nil
  if not self:send({ t = "history", ch = ch, before = before }) then s.loading = false end
end

-- Mark a channel as being looked at (clears unread, loads first page).
function Conn:view(ch)
  self.view_ch = ch
  if ch then
    self.unread[ch] = nil
    self.mentions[ch] = nil
    local s = store_for(self, ch)
    if not s.loaded then self:load_history(ch) end
  end
end

local nonce_counter = 0
-- Protocol 2 added replies and reactions.
function Conn:supports(feature)
  local v = self.session_version or 1
  if feature == "reply" or feature == "react" then return v >= 2 end
  return true
end

function Conn:send_message(ch, body, reply_to)
  body = P.clean_text(body)
  if body == "" then return false end
  if compat.utf8_len(body) > P.LIMITS.message_chars then
    self:_emit("error", ("Messages can be up to %d characters."):format(P.LIMITS.message_chars), "too_long")
    return false
  end
  nonce_counter = nonce_counter + 1
  local nonce = ("%d-%d"):format(math.floor(self.env.now() * 1000) % 1000000000, nonce_counter)
  self.q = (self.q or 0) + 1
  self.pending_q = self.pending_q or {}
  self.pending_q[self.q] = nonce
  if not self:supports("reply") then reply_to = nil end
  local reply
  if reply_to then
    local target = self.msgs[ch] and self.msgs[ch].by_id[reply_to]
    reply = { id = reply_to, a = target and target.a, b = target and target.body }
  end
  self.pending[nonce] = { ch = ch, body = body, at = self.env.now(), state = "sending", a = self.me and self.me.user,
                          reply_to = reply_to, reply = reply }
  self:send({ t = "send", ch = ch, body = body, nonce = nonce, q = self.q, reply = reply_to })
  self:_emit("msg", ch, "pending")
  return true
end

function Conn:pending_for(ch)
  local out = {}
  for nonce, pm in pairs(self.pending) do if pm.ch == ch then pm.nonce = nonce; out[#out + 1] = pm end end
  table.sort(out, function(a, b) return a.at < b.at end)
  return out
end

function Conn:drop_pending(nonce) self.pending[nonce] = nil; self:_emit("msg") end

function Conn:edit_message(id, body)
  body = P.clean_text(body)
  if body == "" then return false end
  return self:send({ t = "edit", id = id, body = body })
end

function Conn:delete_message(id) return self:send({ t = "delete", id = id }) end

-- Has the user reacted with this emoji on this message?
function Conn:reacted(m, emoji)
  local me = self.me and self.me.user
  for _, r in ipairs(m.rx or {}) do
    if r[1] == emoji then
      for _, k in ipairs(r[2]) do if k == me then return true end end
      return false
    end
  end
  return false
end

function Conn:react(m, emoji, on)
  if on == nil then on = not self:reacted(m, emoji) end
  return self:send({ t = "react", id = m.id, e = emoji, on = on })
end

function Conn:typed(ch)
  local now = self.env.now()
  if now - (self.typing_sent_at or 0) < M.TYPING_SEND_EVERY then return end
  self.typing_sent_at = now
  self:send({ t = "typing", ch = ch })
end

function Conn:typing_names(ch)
  local out = {}
  for user in pairs(self.typing[ch] or {}) do
    local m = self.members[user]
    out[#out + 1] = m and m.name or user:sub(1, 8)
  end
  table.sort(out)
  return out
end

function Conn:member_name(key)
  local m = self.members[key]
  return m and m.name or ("user-" .. tostring(key):sub(1, 6))
end

function Conn:is_owner() return self.me and self.me.role == "owner" end

-- Composer slash commands. Returns true if handled.
function Conn:command(ch, text)
  local cmd, rest = text:match("^/(%S+)%s*(.-)%s*$")
  if not cmd then return false end
  cmd = cmd:lower()
  if cmd == "claim" then
    self:send({ t = "claim", code = rest })
  elseif cmd == "nick" or cmd == "name" then
    if not P.check_field("name", rest) then self:_emit("error", "Names are 1 to 32 characters.", "invalid") return true end
    self:send({ t = "profile", name = rest })
  elseif cmd == "create" or cmd == "create-voice" then
    local name, topic = rest:match("^#?([%w%-_]+)%s*(.-)$")
    if not name then self:_emit("error", "Usage: /create name [topic]", "invalid") return true end
    self:send({ t = "channel_create", name = name, kind = cmd == "create" and "text" or "voice", topic = topic ~= "" and topic or nil })
  elseif cmd == "topic" then
    self:send({ t = "channel_update", ch = ch, topic = rest:sub(1, 200) })
  elseif cmd == "rename" then
    local name = rest:match("^#?([%w%-_]+)$")
    if not name then self:_emit("error", "Usage: /rename new-name", "invalid") return true end
    self:send({ t = "channel_update", ch = ch, name = name })
  elseif cmd == "delete-channel" then
    self:send({ t = "channel_delete", ch = ch })
  elseif cmd == "help" then
    self:_emit("notice", "/nick name · /claim CODE · /create name [topic] · /create-voice name · /topic text · /rename name · /delete-channel")
  else
    self:_emit("error", "Unknown command /" .. cmd .. ". Type /help for the list.", "invalid")
  end
  return true
end

return M
