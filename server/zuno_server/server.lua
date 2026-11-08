-- The Zuno server: networking loop, sessions and all packet handlers.
--
--   local Server = require("zuno_server.server")
--   local srv = Server.new({ data_dir = "data" })   -- first run creates config, key and database
--   srv:start()
--   while true do srv:step(0.05) end               -- or srv:run()
--
-- Runs on plain LuaJIT + LuaSocket, and inside a LÖVE thread for "Host a server".
local socket = require("socket")
local C = require("zuno.crypto")
local Session = require("zuno.session")
local P = require("zuno.packets")
local compat = require("zuno.compat")
local version = require("zuno.version")
local Store = require("zuno_server.store")
local Config = require("zuno_server.config")
local fs = require("zuno_server.fs")

local mp = require("zuno.msgpack")
local Server = {}
Server.__index = Server

local function now_ms() return math.floor(socket.gettime() * 1000) end

local CLAIM_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
local function new_claim_code()
  local r, out = C.random(8), {}
  for i = 1, 8 do
    local b = r:byte(i) % #CLAIM_ALPHABET + 1
    out[#out + 1] = CLAIM_ALPHABET:sub(b, b)
    if i == 4 then out[#out + 1] = "-" end
  end
  return table.concat(out)
end

-- Token bucket: `rate` tokens per second, up to `burst`.
local function bucket(rate, burst) return { rate = rate, burst = burst, tokens = burst, t = socket.gettime() } end
local function take(b, n)
  local t = socket.gettime()
  b.tokens = math.min(b.burst, b.tokens + (t - b.t) * b.rate)
  b.t = t
  if b.tokens >= (n or 1) then b.tokens = b.tokens - (n or 1); return true end
  return false
end

--------------------------------------------------------------------- setup
-- opts: data_dir (required), port, bind, name, owner_key (hex; becomes owner on first start),
--       log (function(level, msg)), quiet
function Server.new(opts)
  assert(opts and opts.data_dir, "data_dir required")
  local self = setmetatable({}, Server)
  self.opts = opts
  self.log_fn = opts.log or function(level, msg)
    if not opts.quiet then io.stdout:write(os.date("%H:%M:%S "), level, " ", msg, "\n"); io.stdout:flush() end
  end
  fs.mkdirs(opts.data_dir)
  self.config = Config.load(opts.data_dir, { port = opts.port, bind = opts.bind, name = opts.name })

  -- Server identity (Ed25519 seed). Moving this file moves the server's identity.
  local key_path = fs.join(opts.data_dir, "server.key")
  local seed = fs.read(key_path)
  if not seed then
    seed = C.ed25519_new_seed()
    fs.write(key_path, seed, true)
    self:log("info", "created a new server identity key")
  end
  assert(#seed == 32, "server.key is damaged (expected 32 bytes)")
  self.seed = seed
  self.key = compat.hex(C.ed25519_public(seed))

  self.store = Store.open(fs.join(opts.data_dir, "zuno.db"))
  if #self.store:channels() == 0 then
    self.store:create_channel("general", "text", "Say hi")
    self.store:create_channel("Lounge", "voice", "")
  end
  -- The person hosting from their client becomes owner the first time they connect.
  if opts.owner_key and not self.store:owner() then self.pending_owner = opts.owner_key end
  if not self.store:owner() and not self.store:meta("claim_code") then
    self.store:set_meta("claim_code", new_claim_code())
  end

  self.links = {}        -- sid -> device link relay session
  self.conns = {}        -- socket -> conn
  self.online = {}       -- user key -> { [conn] = true }
  self.handshaking = 0
  return self
end

function Server:log(level, msg) self.log_fn(level, msg) end

function Server:fingerprint() return P.fingerprint(self.key) end

function Server:claim_code() return self.store:meta("claim_code") end

function Server:start()
  local c = self.config
  local listener, err = socket.bind(c.bind, c.port)
  if not listener then
    err = tostring(err)
    -- Windows reports a port taken by another program as "permission denied".
    if err:find("in use") or (err:find("permission") and c.port >= 1024) then
      error(("Port %d is busy (another server?). Try another."):format(c.port), 0)
    end
    error("Could not listen on port " .. c.port .. ": " .. err, 0)
  end
  listener:settimeout(0)
  self.listener = listener
  local _, port = listener:getsockname()
  self.port = tonumber(port)
  self:log("info", ("Zuno server %s \"%s\" listening on port %d"):format(version.APP, c.name, self.port))
  self:log("info", "server key fingerprint: " .. self:fingerprint())
  self:log("info", "verified invite: <your address>#" .. self.key:sub(1, 20))
  local code = self:claim_code()
  if code then
    self:log("info", "no owner yet. To become the owner, connect with Zuno and send:  /claim " .. code)
  end
  return self.port
end

function Server:stop()
  for _, conn in pairs(self.conns) do self:_drop(conn, "server stopping") end
  if self.listener then self.listener:close(); self.listener = nil end
  self.store:close()
  self:log("info", "server stopped")
end

--------------------------------------------------------------------- connections
function Server:_count_ip(ip)
  local n = 0
  for _, conn in pairs(self.conns) do if conn.ip == ip then n = n + 1 end end
  return n
end

function Server:_accept()
  while true do
    local sock = self.listener:accept()
    if not sock then return end
    sock:settimeout(0)
    sock:setoption("tcp-nodelay", true)
    local ip = sock:getpeername() or "?"
    local c = self.config
    local count = 0
    for _ in pairs(self.conns) do count = count + 1 end
    if count >= c.max_connections or self.handshaking >= c.max_handshakes
       or (c.max_connections_per_ip > 0 and self:_count_ip(ip) >= c.max_connections_per_ip) then
      sock:close()
    else
      local conn = {
        sock = sock, ip = ip, out = {}, out_bytes = 0, opened = socket.gettime(),
        last_recv = socket.gettime(),
        session = Session.server(C, { identity_seed = self.seed, name = c.name }),
        general = bucket(20, 60), sends = bucket(1.5, 8), claims = bucket(0.1, 5), typing_at = 0,
      }
      self.conns[sock] = conn
      self.handshaking = self.handshaking + 1
    end
  end
end

function Server:_queue_raw(conn, bytes)
  if not bytes or conn.closed then return end
  conn.out[#conn.out + 1] = bytes
  conn.out_bytes = conn.out_bytes + #bytes
  if conn.out_bytes > 8 * 1024 * 1024 then self:_drop(conn, "too slow (send buffer full)") end
end

function Server:send(conn, pkt)
  if conn.closed or not conn.session:is_ready() then return end
  if not conn.session:send(pkt) then
    self:log("warn", "packet too large for " .. tostring(pkt.t))
    return
  end
  self:_queue_raw(conn, conn.session:pull())
end

function Server:_drop(conn, why)
  if conn.closed then return end
  conn.closed = true
  -- flush whatever is queued (e.g. a version error) before closing
  if #conn.out > 0 then conn.sock:send(table.concat(conn.out)) end
  conn.sock:close()
  self.conns[conn.sock] = nil
  if conn.link then self:_close_link(conn.link, conn, "closed") end
  if not conn.ready then
    self.handshaking = self.handshaking - 1
  elseif conn.user then
    local set = self.online[conn.user]
    if set then
      set[conn] = nil
      if next(set) == nil then
        self.online[conn.user] = nil
        self.store:touch_member(conn.user, now_ms())
        self:broadcast({ t = "presence", user = conn.user, online = false })
      end
    end
  end
  if conn.retired then return end
  if why and conn.user then self:log("info", ("%s disconnected (%s)"):format(conn.user:sub(1, 8), why)) end
end

function Server:broadcast(pkt, except)
  for _, conn in pairs(self.conns) do
    if conn.user and conn ~= except then self:send(conn, pkt) end
  end
end

function Server:_on_ready(conn, ev)
  self.handshaking = self.handshaking - 1
  conn.ready = true
  if ev.guest then
    -- A device being linked: not a member, may only use the link relay.
    conn.guest = true
    return
  end
  local key = ev.peer_key
  if self.store:retired(key) then
    -- This key was replaced ("Replace my key"). Tell the device and close.
    conn.ready, conn.retired = true, true
    self:send(conn, { t = "err", code = "key_replaced", msg = "this account's key was replaced on another device" })
    self:_drop(conn, nil)
    return
  end
  local name = ev.peer_name
  if not (name and P.check_field("name", name)) then name = "user-" .. key:sub(1, 6) end
  local member, is_new = self.store:upsert_member(key, name, now_ms())
  local changed = false
  if self.pending_owner == key and not self.store:owner() then
    self.store:set_member_role(key, "owner")
    self.store:set_meta("claim_code", nil)
    self.pending_owner = nil
    changed = true
  end
  if not is_new and ev.peer_name and P.check_field("name", ev.peer_name) and ev.peer_name ~= member.name then
    self.store:set_member_name(key, ev.peer_name) -- renamed while offline
    changed = true
  end
  if changed then member = self.store:member(key) end
  conn.user = key
  local first = self.online[key] == nil
  self.online[key] = self.online[key] or {}
  self.online[key][conn] = true
  self:log("info", ("%s connected as %s%s"):format(key:sub(1, 8), member.name, is_new and " (new member)" or ""))
  if is_new or changed then self:broadcast({ t = "member", user = key, name = member.name, role = member.role, online = true }, conn)
  elseif first then self:broadcast({ t = "presence", user = key, online = true }, conn) end
end

function Server:_read(conn)
  local data, err, partial = conn.sock:receive(65536)
  data = data or partial
  if data and #data > 0 then
    conn.last_recv = socket.gettime()
    for _, ev in ipairs(conn.session:feed(data)) do
      if ev.type == "ready" then
        self:_on_ready(conn, ev)
      elseif ev.type == "packet" then
        self:_handle(conn, ev.packet)
      elseif ev.type == "error" then
        self:_queue_raw(conn, conn.session:pull())
        self:_drop(conn, ev.message)
        return
      end
      if conn.closed then return end
    end
    self:_queue_raw(conn, conn.session:pull())
  end
  if err == "closed" then self:_drop(conn, "closed") end
end

function Server:_write(conn)
  if #conn.out == 0 then return end
  local data = table.concat(conn.out)
  local last, err, partial_last = conn.sock:send(data)
  local sent = last or partial_last or 0
  if sent < #data then
    conn.out = { data:sub(sent + 1) }
    conn.out_bytes = #data - sent
  else
    conn.out = {}
    conn.out_bytes = 0
  end
  if err == "closed" then self:_drop(conn, "closed") end
end

function Server:_timeouts()
  local t, c = socket.gettime(), self.config
  for _, conn in pairs(self.conns) do
    if not conn.ready and t - conn.opened > c.handshake_timeout then
      self:_drop(conn, "handshake timeout")
    elseif conn.guest and t - conn.opened > 180 then
      self:_drop(conn, "link guest timeout")
    elseif conn.ready and t - conn.last_recv > c.idle_timeout then
      self:_drop(conn, "idle timeout")
    end
  end
end

-- One loop iteration. Waits up to `timeout` seconds for network activity.
function Server:step(timeout)
  local readers, writers = { self.listener }, {}
  for sock, conn in pairs(self.conns) do
    readers[#readers + 1] = sock
    if #conn.out > 0 then writers[#writers + 1] = sock end
  end
  local r, w = socket.select(readers, writers, timeout or 0.05)
  for _, sock in ipairs(r) do
    if sock == self.listener then self:_accept()
    else local conn = self.conns[sock]; if conn then self:_read(conn) end end
  end
  for _, sock in ipairs(w) do
    local conn = self.conns[sock]; if conn then self:_write(conn) end
  end
  -- write anything produced this step right away
  for _, conn in pairs(self.conns) do if #conn.out > 0 then self:_write(conn) end end
  local t = socket.gettime()
  if not self.last_timeout_check or t - self.last_timeout_check > 1 then
    self.last_timeout_check = t
    self:_timeouts()
    for _, link in pairs(self.links) do
      if t > link.expires then self:_close_link(link, nil, "expired") end
    end
  end
end

function Server:run(should_stop)
  if not self.listener then self:start() end
  while not (should_stop and should_stop()) do self:step(0.1) end
  self:stop()
end

--------------------------------------------------------------------- packet helpers
-- Short preview of a replied-to message (so clients can show it without loading it).
local function reply_preview(row)
  if not row then return { gone = true } end
  if row.deleted == 1 then return { id = row.id, gone = true } end
  local b = row.body -- formatting is kept: clients make their own one-line preview
  if compat.utf8_len(b) > P.LIMITS.reply_preview then
    b = b:sub(1, compat.utf8_offset(b, P.LIMITS.reply_preview + 1) - 1):gsub("<@%x*$", "") .. "…"
  end
  return { id = row.id, a = row.author, b = b }
end

local function msg_fields(row, rx, replied)
  local m = {
    id = row.id, ch = row.ch, a = row.author, at = row.at, body = row.body,
    edited = row.edited, deleted = row.deleted == 1 or nil, rev = row.rev,
  }
  if row.deleted ~= 1 then
    if row.reply_to then m.reply = reply_preview(replied); m.reply.id = row.reply_to end
    m.rx = rx -- { {emoji, {keys}}, ... } or nil
  end
  return m
end

-- Message rows -> wire tables, with their reactions and reply previews (batched).
function Server:_rows_out(rows)
  local ids, reply_ids = {}, {}
  for i, row in ipairs(rows) do
    ids[i] = row.id
    if row.reply_to then reply_ids[#reply_ids + 1] = row.reply_to end
  end
  local rx = self.store:reactions(ids)
  local replied = self.store:messages_by_id(reply_ids)
  local out = {}
  for i, row in ipairs(rows) do out[i] = msg_fields(row, rx[row.id], row.reply_to and replied[row.reply_to]) end
  return out
end

function Server:_msg_out(row, nonce)
  local m = self:_rows_out({ row })[1]
  m.t, m.nonce = "msg", nonce
  return m
end

local function channel_out(ch)
  return { id = ch.id, name = ch.name, kind = ch.kind, topic = ch.topic, position = ch.position }
end

function Server:_err(conn, pkt, code, msg)
  self:send(conn, { t = "err", code = code, msg = msg, re = pkt.q })
end

function Server:_is_owner(key)
  local m = self.store:member(key)
  return m and m.role == "owner"
end

--------------------------------------------------------------------- handlers
local H = {}

function H.ping(self, conn, pkt) self:send(conn, { t = "pong", n = pkt.n }) end

function H.sync(self, conn)
  local me = self.store:member(conn.user)
  local channels, members = {}, {}
  for _, ch in ipairs(self.store:channels()) do channels[#channels + 1] = channel_out(ch) end
  for _, m in ipairs(self.store:members()) do
    members[#members + 1] = { user = m.key, name = m.name, role = m.role, online = self.online[m.key] ~= nil }
  end
  self:send(conn, {
    t = "state",
    server = { name = self.config.name, key = self.key, app = version.APP },
    me = { user = me.key, name = me.name, role = me.role },
    channels = channels, members = members, rev = self.store:current_rev(),
    unclaimed = self:claim_code() ~= nil or nil,
  })
end

function H.history(self, conn, pkt)
  local ch = self.store:channel(pkt.ch)
  if not ch or ch.kind ~= "text" then return self:_err(conn, pkt, P.ERR.not_found, "no such channel") end
  local limit = math.max(1, math.min(pkt.limit or P.LIMITS.history_page, P.LIMITS.history_page))
  local rows, more = self.store:history(ch.id, pkt.before, limit)
  self:send(conn, { t = "messages", ch = ch.id, list = self:_rows_out(rows), more = more, before = pkt.before, re = pkt.q })
end

function H.since(self, conn, pkt)
  local ch = self.store:channel(pkt.ch)
  if not ch or ch.kind ~= "text" then return self:_err(conn, pkt, P.ERR.not_found, "no such channel") end
  local rows = self.store:since(ch.id, pkt.rev, P.LIMITS.since_max)
  if not rows then return self:send(conn, { t = "messages", ch = ch.id, list = {}, reset = true, re = pkt.q }) end
  self:send(conn, { t = "messages", ch = ch.id, list = self:_rows_out(rows), since = pkt.rev, re = pkt.q })
end

function H.send(self, conn, pkt)
  if not take(conn.sends) then return self:_err(conn, pkt, P.ERR.rate_limited, "slow down a little") end
  local ch = self.store:channel(pkt.ch)
  if not ch or ch.kind ~= "text" then return self:_err(conn, pkt, P.ERR.not_found, "no such channel") end
  local body = P.clean_text(pkt.body)
  if body == "" then return self:_err(conn, pkt, P.ERR.invalid, "empty message") end
  local reply
  if pkt.reply then
    local target = self.store:message(pkt.reply)
    if not target or target.ch ~= ch.id or target.deleted == 1 then
      return self:_err(conn, pkt, P.ERR.not_found, "the message you replied to is gone")
    end
    reply = target.id
  end
  local row = self.store:add_message(ch.id, conn.user, body, now_ms(), reply)
  self:broadcast(self:_msg_out(row, pkt.nonce))
end

function H.edit(self, conn, pkt)
  if not take(conn.sends) then return self:_err(conn, pkt, P.ERR.rate_limited, "slow down a little") end
  local row = self.store:message(pkt.id)
  if not row or row.deleted == 1 then return self:_err(conn, pkt, P.ERR.not_found, "no such message") end
  if row.author ~= conn.user then return self:_err(conn, pkt, P.ERR.forbidden, "you can only edit your own messages") end
  local body = P.clean_text(pkt.body)
  if body == "" then return self:_err(conn, pkt, P.ERR.invalid, "empty message") end
  if body == row.body then return end
  self:broadcast(self:_msg_out(self.store:edit_message(row.id, body, now_ms())))
end

function H.delete(self, conn, pkt)
  local row = self.store:message(pkt.id)
  if not row or row.deleted == 1 then return self:_err(conn, pkt, P.ERR.not_found, "no such message") end
  if row.author ~= conn.user and not self:_is_owner(conn.user) then
    return self:_err(conn, pkt, P.ERR.forbidden, "you can only delete your own messages")
  end
  self:broadcast(self:_msg_out(self.store:delete_message(row.id)))
end

function H.react(self, conn, pkt)
  if not take(conn.sends) then return self:_err(conn, pkt, P.ERR.rate_limited, "slow down a little") end
  local row = self.store:message(pkt.id)
  if not row or row.deleted == 1 then return self:_err(conn, pkt, P.ERR.not_found, "no such message") end
  local updated, why = self.store:set_reaction(row.id, conn.user, pkt.e, pkt.on, now_ms(), P.LIMITS.reactions_per_message)
  if why == "too_many" then
    return self:_err(conn, pkt, P.ERR.too_long, ("a message can have up to %d different reactions"):format(P.LIMITS.reactions_per_message))
  end
  if updated then self:broadcast(self:_msg_out(updated)) end
end

function H.typing(self, conn, pkt)
  local t = socket.gettime()
  if t - conn.typing_at < 1.5 then return end
  conn.typing_at = t
  local ch = self.store:channel(pkt.ch)
  if not ch or ch.kind ~= "text" then return end
  self:broadcast({ t = "typing", ch = ch.id, user = conn.user }, conn)
end

function H.profile(self, conn, pkt)
  local name = pkt.name:gsub("^%s+", ""):gsub("%s+$", "")
  self.store:set_member_name(conn.user, name)
  local m = self.store:member(conn.user)
  self:broadcast({ t = "member", user = m.key, name = m.name, role = m.role, online = true })
end

function H.claim(self, conn, pkt)
  local code = self:claim_code()
  if not code then return self:_err(conn, pkt, P.ERR.forbidden, "this server already has an owner") end
  if not take(conn.claims) then return self:_err(conn, pkt, P.ERR.rate_limited, "too many attempts, wait a minute") end
  local given = pkt.code:upper():gsub("%s", "")
  if #given ~= #code or not C.equal(given, code) then
    return self:_err(conn, pkt, P.ERR.forbidden, "wrong claim code")
  end
  self.store:set_member_role(conn.user, "owner")
  self.store:set_meta("claim_code", nil)
  local m = self.store:member(conn.user)
  self:log("info", m.name .. " (" .. m.key:sub(1, 8) .. ") is now the owner")
  self:broadcast({ t = "member", user = m.key, name = m.name, role = m.role, online = true })
  self:send(conn, { t = "notice", msg = "You are now the owner of this server.", re = pkt.q })
end

function H.channel_create(self, conn, pkt)
  if not self:_is_owner(conn.user) then return self:_err(conn, pkt, P.ERR.forbidden, "only the owner can create channels") end
  if self.store:channel_by_name(pkt.name, pkt.kind) then return self:_err(conn, pkt, P.ERR.exists, "that channel already exists") end
  if #self.store:channels() >= 200 then return self:_err(conn, pkt, P.ERR.invalid, "too many channels") end
  local ch = self.store:create_channel(pkt.name, pkt.kind, pkt.topic)
  local out = channel_out(ch); out.t = "channel"
  self:broadcast(out)
end

function H.channel_update(self, conn, pkt)
  if not self:_is_owner(conn.user) then return self:_err(conn, pkt, P.ERR.forbidden, "only the owner can change channels") end
  local ch = self.store:channel(pkt.ch)
  if not ch then return self:_err(conn, pkt, P.ERR.not_found, "no such channel") end
  if pkt.name then
    local other = self.store:channel_by_name(pkt.name, ch.kind)
    if other and other.id ~= ch.id then return self:_err(conn, pkt, P.ERR.exists, "that channel already exists") end
  end
  local out = channel_out(self.store:update_channel(ch.id, pkt.name, pkt.topic)); out.t = "channel"
  self:broadcast(out)
end

function H.channel_delete(self, conn, pkt)
  if not self:_is_owner(conn.user) then return self:_err(conn, pkt, P.ERR.forbidden, "only the owner can delete channels") end
  local ch = self.store:channel(pkt.ch)
  if not ch then return self:_err(conn, pkt, P.ERR.not_found, "no such channel") end
  local text_count = 0
  for _, c in ipairs(self.store:channels()) do if c.kind == "text" then text_count = text_count + 1 end end
  if ch.kind == "text" and text_count <= 1 then return self:_err(conn, pkt, P.ERR.invalid, "a server needs at least one text channel") end
  self.store:delete_channel(ch.id)
  self:broadcast({ t = "channel_removed", ch = ch.id })
end

--------------------------------------------------------------------- device linking relay
local LINK_ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
local function new_sid()
  local r, out = C.random(8), {}
  for i = 1, 8 do
    local b = r:byte(i) % 32 + 1
    out[#out + 1] = LINK_ALPHABET:sub(b, b)
    if i == 4 then out[#out + 1] = "-" end
  end
  return table.concat(out)
end

function Server:_close_link(link, by, why)
  if self.links[link.sid] ~= link then return end
  self.links[link.sid] = nil
  for _, c in ipairs({ link.owner, link.joiner }) do
    if c then
      c.link = nil
      if c ~= by and not c.closed then self:send(c, { t = "link_event", sid = link.sid, ev = why or "closed" }) end
    end
  end
end

function H.link_open(self, conn, pkt)
  if not take(conn.claims) then return self:_err(conn, pkt, P.ERR.rate_limited, "wait a moment before trying again") end
  if conn.link then self:_close_link(conn.link, conn, "closed") end
  local sid = new_sid()
  local link = { sid = sid, owner = conn, expires = socket.gettime() + 120 }
  self.links[sid] = link
  conn.link = link
  self:send(conn, { t = "link_opened", sid = sid, expires_in = 120, re = pkt.q })
end

function H.link_join(self, conn, pkt)
  if not take(conn.claims) then return self:_err(conn, pkt, P.ERR.rate_limited, "too many attempts, wait a minute") end
  local sid = pkt.sid:upper():gsub("[^0-9A-Z]", "")
  sid = sid:sub(1, 4) .. "-" .. sid:sub(5, 8)
  local link = self.links[sid]
  if not link or link.owner == conn then return self:_err(conn, pkt, P.ERR.not_found, "that link code isn't valid any more") end
  if link.joiner then
    -- One scan only: a second attempt cancels the link and warns the owner.
    self:_close_link(link, conn, "second_scan")
    return self:_err(conn, pkt, P.ERR.forbidden, "that link code was already used")
  end
  link.joiner = conn
  conn.link = link
  self:send(link.owner, { t = "link_event", sid = sid, ev = "joined" })
  self:send(conn, { t = "link_joined", sid = sid, re = pkt.q })
end

function H.link_data(self, conn, pkt)
  local link = conn.link
  if not link or link.sid ~= pkt.sid or not link.joiner then return self:_err(conn, pkt, P.ERR.not_found, "no such link") end
  local peer = (link.owner == conn) and link.joiner or link.owner
  self:send(peer, { t = "link_data", sid = link.sid, d = mp.bin(pkt.d) })
end

function H.rekey(self, conn, pkt)
  if not take(conn.claims) then return self:_err(conn, pkt, P.ERR.rate_limited, "too many attempts, wait a minute") end
  local old = conn.user
  if pkt.new == old then return self:_err(conn, pkt, P.ERR.invalid, "that's the same key") end
  local msg = P.rekey_message(self.key, pkt.new)
  if not C.ed25519_verify(pkt.sig, compat.unhex(old), msg) then
    return self:_err(conn, pkt, P.ERR.forbidden, "the hand-over signature is wrong")
  end
  if self.store:member(pkt.new) or self.store:retired(pkt.new) then
    return self:_err(conn, pkt, P.ERR.exists, "that new key is already used on this server")
  end
  self.store:replace_key(old, pkt.new, now_ms())
  local m = self.store:member(pkt.new)
  self:log("info", ("%s replaced their key: %s -> %s"):format(m.name, old:sub(1, 8), pkt.new:sub(1, 8)))
  self:send(conn, { t = "rekeyed", old = old, new = pkt.new, re = pkt.q })
  -- everyone else: the member's identity moved
  self:broadcast({ t = "member_rekeyed", old = old, new = pkt.new }, conn)
  -- every connection still using the old key is closed (including this one)
  for _, c in pairs(self.conns) do
    if c.user == old then
      self:send(c, { t = "err", code = "key_replaced", msg = "this account's key was replaced" })
      self:_drop(c, "key replaced")
    end
  end
end

function H.link_close(self, conn, pkt)
  local link = conn.link
  if link and link.sid == pkt.sid then self:_close_link(link, conn, "closed") end
end

function Server:_handle(conn, pkt)
  if not take(conn.general) then
    -- Way over the limit: a misbehaving client. Drop it.
    return self:_drop(conn, "flooding")
  end
  local ok, why = P.validate_client(pkt)
  if not ok then return self:_err(conn, pkt, P.ERR.bad_packet, why) end
  if conn.guest and not P.GUEST_ALLOWED[pkt.t] then
    return self:_err(conn, pkt, P.ERR.forbidden, "join the server first")
  end
  local fn = H[pkt.t]
  local success, err = pcall(fn, self, conn, pkt)
  if not success then
    self:log("error", "handler " .. pkt.t .. " failed: " .. tostring(err))
    self:_err(conn, pkt, "server_error", "something went wrong on the server")
  end
end

return Server
