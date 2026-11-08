-- The client's state across all servers: identity, settings, server list and connections.
-- Platform hooks come in `env`:
--   crypto, transport (factory), now(), storage = { read(name) -> str|nil, write(name, str) },
--   host (optional) = { start(opts) -> ok, err ; stop() ; status() -> {running, port, error, claim} }
local mp = require("zuno.msgpack")
local compat = require("zuno.compat")
local P = require("zuno.packets")
local model = require("zuno_ui.model")
local Account = require("zuno_ui.account")

local Controller = {}
Controller.__index = Controller

local DATA_FILE = "client.dat"
local KEY_FILE = "identity.key"
local OLD_KEY_FILE = "identity.old" -- kept until every server got the "replace my key" hand-over

function Controller.new(env)
  local self = setmetatable({ env = env, conns = {}, toasts = {} }, Controller)
  self:_load()
  return self
end

function Controller:_load()
  local env = self.env
  local seed = env.storage.read(KEY_FILE)
  if not seed or #seed ~= 32 then
    seed = env.crypto.ed25519_new_seed()
    env.storage.write(KEY_FILE, seed)
    self.new_identity = true
  end
  self.seed = seed
  self.key = compat.hex(env.crypto.ed25519_public(seed))
  local old = env.storage.read(OLD_KEY_FILE)
  if old and #old == 32 then self.old_seed = old end

  local data = {}
  local raw = env.storage.read(DATA_FILE)
  if raw then data = mp.decode(raw) or {} end
  self.settings = {
    name = type(data.name) == "string" and data.name or nil,
    theme = (data.theme == "light" or data.theme == "dark") and data.theme or "system",
    host_port = compat.is_int(data.host_port) and data.host_port or 41234,
    host_name = type(data.host_name) == "string" and data.host_name or nil,
    hosting = data.hosting == true, -- restart the hosted server on launch
    streamer = (data.streamer == "on" or data.streamer == "off") and data.streamer or "auto",
  }
  self.servers = {}
  for _, e in ipairs(type(data.servers) == "table" and data.servers or {}) do
    if type(e) == "table" and type(e.address) == "string" and model.parse_address(e.address) then
      self.servers[#self.servers + 1] = { address = e.address, key = e.key, name = e.name, last_ch = e.last_ch,
        hosted = e.hosted, rekey_pending = e.rekey_pending and self.old_seed and true or nil }
    end
  end
  self.active = compat.is_int(data.active) and data.active or 1
  for _, e in ipairs(self.servers) do self:_open(e) end
  if self.active > #self.servers then self.active = #self.servers > 0 and 1 or 0 end
end

function Controller:save()
  local list = {}
  for _, e in ipairs(self.servers) do
    list[#list + 1] = { address = e.address, key = e.key, name = e.name, last_ch = e.last_ch, hosted = e.hosted,
      rekey_pending = e.rekey_pending }
  end
  self.env.storage.write(DATA_FILE, mp.encode({
    name = self.settings.name, theme = self.settings.theme, host_port = self.settings.host_port,
    host_name = self.settings.host_name, hosting = self.settings.hosting or nil, streamer = self.settings.streamer, servers = list, active = self.active,
  }))
end

------------------------------------------------------------------ account backup / restore
function Controller:account()
  return { seed = self.seed, name = self.settings.name, theme = self.settings.theme, servers = self.servers }
end

function Controller:new_recovery_key() return Account.new_recovery_key(self.env.crypto) end

-- Slow on purpose (Argon2id, 64 MiB): call from a "working..." state.
function Controller:export_account(recovery_key)
  return Account.export_file(self.env.crypto, self:account(), recovery_key)
end

function Controller:read_account_file(bytes, recovery_input)
  return Account.import_file(self.env.crypto, bytes, recovery_input)
end

-- Replace this device's account with `acc` (from a file or a linked device).
function Controller:replace_account(acc)
  for _, c in pairs(self.conns) do c:disconnect(true) end
  self.conns = {}
  self.seed = acc.seed
  self.env.storage.write(KEY_FILE, acc.seed)
  self.key = compat.hex(self.env.crypto.ed25519_public(acc.seed))
  self.settings.name = acc.name or self.settings.name
  if acc.theme == "light" or acc.theme == "dark" or acc.theme == "system" then self.settings.theme = acc.theme end
  self.settings.hosting = false
  self.servers = {}
  for _, e in ipairs(acc.servers or {}) do
    if model.parse_address(e.address) then
      self.servers[#self.servers + 1] = { address = e.address, key = e.key, name = e.name }
    end
  end
  for _, e in ipairs(self.servers) do self:_open(e) end
  self.active = #self.servers > 0 and 1 or 0
  self:save()
end

function Controller:display_name()
  return self.settings.name or ("user-" .. self.key:sub(1, 6))
end

function Controller:_open(entry)
  local env = self.env
  local conn = model.new_conn({
    crypto = env.crypto, transport = env.transport, now = env.now, identity_seed = self.seed,
    name = function() return self:display_name() end,
  }, entry)
  if entry.rekey_pending and self.old_seed then conn.seed = self.old_seed; conn.rekeying = true end
  conn:on(function(ev, a, b)
    if ev == "status" and conn.status == "online" and entry.rekey_pending then self:_send_rekey(entry, conn)
    elseif ev == "rekeyed" then self:_rekey_done(entry, conn)
    elseif ev == "error" and entry.rekey_pending and conn.rekey_sent and (b == "exists" or b == "forbidden") then
      self:_rekey_failed(entry, conn, a)
    elseif ev == "entry" then self:save()
    elseif ev == "error" then self:toast(a, "error", entry)
    elseif ev == "notice" then self:toast(a, "info", entry)
    end
  end)
  self.conns[entry] = conn
  return conn
end

function Controller:conn(i) local e = self.servers[i or self.active]; return e and self.conns[e] end

-- Add a server by address. Returns its index, or nil + message.
function Controller:add_server(text, extra)
  local parsed, err = model.parse_address(text)
  if not parsed then return nil, err end
  for i, e in ipairs(self.servers) do
    local p = model.parse_address(e.address)
    if p.host == parsed.host and p.port == parsed.port then
      self.active = i; self:save()
      return i
    end
  end
  local addr = parsed.address .. (parsed.fingerprint and ("#" .. parsed.fingerprint) or "")
  local entry = { address = addr, hosted = extra and extra.hosted or nil }
  self.servers[#self.servers + 1] = entry
  self:_open(entry)
  self.active = #self.servers
  self:save()
  return self.active
end

function Controller:remove_server(i)
  local e = self.servers[i]
  if not e then return end
  e.rekey_pending = nil
  local c = self.conns[e]
  if c then c:disconnect(true) end
  self.conns[e] = nil
  table.remove(self.servers, i)
  if self.active > #self.servers then self.active = #self.servers end
  if self.active == 0 and #self.servers > 0 then self.active = 1 end
  self:save()
  self:_maybe_finish_rekey()
end

function Controller:select(i)
  if i == 0 or self.servers[i] then self.active = i; self:save() end
end

function Controller:set_name(name)
  name = name:gsub("^%s+", ""):gsub("%s+$", "")
  if not P.check_field("name", name) then return false, "Names are 1 to 32 characters." end
  self.settings.name = name
  self:save()
  for _, c in pairs(self.conns) do
    if c.status == "online" then c:send({ t = "profile", name = name }) end
  end
  return true
end

function Controller:set_theme(t) self.settings.theme = t; self:save() end
function Controller:set_streamer(s) self.settings.streamer = s; self:save() end

function Controller:remember_channel(entry, ch)
  if entry.last_ch ~= ch then entry.last_ch = ch; self:save() end
end

function Controller:toast(text, kind, entry)
  text = tostring(text):gsub("^%l", string.upper)
  self.toasts[#self.toasts + 1] = { text = text, kind = kind or "info", at = self.env.now(), entry = entry }
  while #self.toasts > 4 do table.remove(self.toasts, 1) end
end

function Controller:update()
  for _, c in pairs(self.conns) do c:update() end
  local now = self.env.now()
  for i = #self.toasts, 1, -1 do if now - self.toasts[i].at > 5 then table.remove(self.toasts, i) end end
end

------------------------------------------------------------------ replace my key (5.3)
-- A new identity key replaces the current one. Each server gets a hand-over signed by the
-- old key; servers that are offline get it on their next connect, so the old key is kept
-- (identity.old) until every server has it.
function Controller:replace_key()
  local C = self.env.crypto
  local old = self.old_seed or self.seed
  local new = C.ed25519_new_seed()
  self.env.storage.write(OLD_KEY_FILE, old)
  self.env.storage.write(KEY_FILE, new)
  self.old_seed, self.seed = old, new
  self.key = compat.hex(C.ed25519_public(new))
  for _, e in ipairs(self.servers) do
    e.rekey_pending = true
    e.rekey_failed = nil
    local c = self.conns[e]
    c.seed, c.rekeying = old, true
    if c.status == "online" then self:_send_rekey(e, c) end
  end
  self:save()
  self:_maybe_finish_rekey()
end

function Controller:_send_rekey(entry, conn)
  local C = self.env.crypto
  if not conn.server or not conn.server.key then return end
  local sig = C.ed25519_sign(self.old_seed, P.rekey_message(conn.server.key, self.key))
  conn.rekey_sent = true
  conn:send({ t = "rekey", new = self.key, sig = mp.bin(sig) })
end

function Controller:_rekey_done(entry, conn)
  entry.rekey_pending = nil
  conn.rekeying, conn.rekey_sent = nil, nil
  conn.seed = self.seed
  self:save()
  -- Drop the old-key connection now (the server is about to close it) and come back with the new key.
  conn.attempt, conn.next_try = 0, 0
  conn:connect()
  self:_maybe_finish_rekey()
end

function Controller:_rekey_failed(entry, conn, msg)
  entry.rekey_pending, entry.rekey_failed = nil, true
  conn.rekeying, conn.rekey_sent = nil, nil
  self:toast(("Couldn't move your account on %s: %s"):format(entry.name or entry.address, tostring(msg)), "error")
  self:save()
  self:_maybe_finish_rekey()
end

function Controller:rekey_pending_count()
  local n = 0
  for _, e in ipairs(self.servers) do if e.rekey_pending then n = n + 1 end end
  return n
end

function Controller:_maybe_finish_rekey()
  if self.old_seed and self:rekey_pending_count() == 0 then
    self.old_seed = nil
    self.env.storage.write(OLD_KEY_FILE, "")
    self:toast("Your key was replaced on all your servers. Link your other devices again.")
  end
end

------------------------------------------------------------------ hosting
function Controller:can_host() return self.env.host ~= nil end

function Controller:host_status() return self.env.host and self.env.host.status() or { running = false } end

function Controller:start_hosting(name, port)
  if not self.env.host then return nil, "Hosting isn't available on this device." end
  port = tonumber(port)
  if not port or port < 1 or port > 65535 or port ~= math.floor(port) then return nil, "The port must be a number from 1 to 65535." end
  name = (name or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if name == "" then name = self:display_name() .. "'s server" end
  if #name > 64 then return nil, "The server name can be up to 64 characters." end
  self.settings.host_port, self.settings.host_name = port, name
  self:save()
  local ok, err = self.env.host.start({ port = port, name = name, owner_key = self.key })
  if not ok then return nil, err end
  self.settings.hosting = true
  self:save()
  return true
end

-- Start the hosted server again if it was running when Zuno closed.
function Controller:resume_hosting()
  if self.settings.hosting and self.env.host then
    self.env.host.start({ port = self.settings.host_port, name = self.settings.host_name or (self:display_name() .. "'s server"),
      owner_key = self.key, resume = true })
  end
end

-- Called when the hosted server reports it is listening: add it as a server tab.
function Controller:hosting_ready(port, quiet)
  local addr = "127.0.0.1:" .. port
  for i, e in ipairs(self.servers) do
    if e.address == addr then
      local c = self.conns[e]
      if c and c.status ~= "online" then c.manual_off = nil; c:retry_now() end
      if not quiet then self.active = i; self:save() end
      return i
    end
  end
  if quiet then return nil end
  return self:add_server(addr, { hosted = true })
end

function Controller:stop_hosting()
  if self.env.host then self.env.host.stop() end
  self.settings.hosting = false
  self:save()
end

return Controller
