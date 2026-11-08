-- The client's state across all servers: identity, settings, server list and connections.
-- Platform hooks come in `env`:
--   crypto, transport (factory), now(), storage = { read(name) -> str|nil, write(name, str) },
--   host (optional) = { start(opts) -> ok, err ; stop() ; status() -> {running, port, error, claim} }
local mp = require("zuno.msgpack")
local compat = require("zuno.compat")
local P = require("zuno.packets")
local model = require("zuno_ui.model")

local Controller = {}
Controller.__index = Controller

local DATA_FILE = "client.dat"
local KEY_FILE = "identity.key"

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

  local data = {}
  local raw = env.storage.read(DATA_FILE)
  if raw then data = mp.decode(raw) or {} end
  self.settings = {
    name = type(data.name) == "string" and data.name or nil,
    theme = (data.theme == "light" or data.theme == "dark") and data.theme or "system",
    host_port = compat.is_int(data.host_port) and data.host_port or 41234,
    host_name = type(data.host_name) == "string" and data.host_name or nil,
    hosting = data.hosting == true, -- restart the hosted server on launch
  }
  self.servers = {}
  for _, e in ipairs(type(data.servers) == "table" and data.servers or {}) do
    if type(e) == "table" and type(e.address) == "string" and model.parse_address(e.address) then
      self.servers[#self.servers + 1] = { address = e.address, key = e.key, name = e.name, last_ch = e.last_ch, hosted = e.hosted }
    end
  end
  self.active = compat.is_int(data.active) and data.active or 1
  for _, e in ipairs(self.servers) do self:_open(e) end
  if self.active > #self.servers then self.active = #self.servers > 0 and 1 or 0 end
end

function Controller:save()
  local list = {}
  for _, e in ipairs(self.servers) do
    list[#list + 1] = { address = e.address, key = e.key, name = e.name, last_ch = e.last_ch, hosted = e.hosted }
  end
  self.env.storage.write(DATA_FILE, mp.encode({
    name = self.settings.name, theme = self.settings.theme, host_port = self.settings.host_port,
    host_name = self.settings.host_name, hosting = self.settings.hosting or nil, servers = list, active = self.active,
  }))
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
  conn:on(function(ev, a, b)
    if ev == "entry" then self:save()
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
  local c = self.conns[e]
  if c then c:disconnect(true) end
  self.conns[e] = nil
  table.remove(self.servers, i)
  if self.active > #self.servers then self.active = #self.servers end
  if self.active == 0 and #self.servers > 0 then self.active = 1 end
  self:save()
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
