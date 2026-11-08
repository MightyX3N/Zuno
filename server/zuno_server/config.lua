-- Server config: a Lua table in <data>/config.lua that the owner can edit.
local fs = require("zuno_server.fs")

local Config = {}

Config.DEFAULTS = {
  name = "My Zuno server",
  port = 41234,
  bind = "*",                 -- "*" = all interfaces, "127.0.0.1" = this machine only
  max_connections = 200,
  max_connections_per_ip = 0, -- 0 = no limit. Behind playit.gg every client has the same IP.
  max_handshakes = 32,        -- connections still in the handshake at once
  handshake_timeout = 10,     -- seconds
  idle_timeout = 120,         -- seconds without any packet (clients ping every 30 s)
  max_file_mb = 25,           -- biggest upload (files and images in channels)
  max_storage_mb = 0,         -- 0 = no limit on all stored files together
  allow_relay = true,         -- direct transfers may stream through this server when peer-to-peer fails
  max_relay_mb = 0,           -- 0 = no limit per relayed transfer
  udp = true,                 -- answer on UDP (same port) so clients can find a direct route to each other
}

local TEMPLATE = [[
-- Zuno server settings. Restart the server after editing.
return {
  -- Shown to people when they connect.
  name = %q,

  -- Port for clients (TCP). With playit.gg, point a TCP tunnel at this port.
  port = %d,

  -- "*" listens on all network interfaces. "127.0.0.1" = only this machine.
  bind = %q,

  -- Limits
  max_connections = %d,
  max_connections_per_ip = %d, -- 0 = off. Behind playit.gg all clients share one IP, so keep 0 there.
  max_handshakes = %d,
  handshake_timeout = %d,
  idle_timeout = %d,

  -- Files people post in channels (stored in the "files" folder next to this file)
  max_file_mb = %d,
  max_storage_mb = %d, -- 0 = no limit

  -- Direct file transfers between two people. They go peer-to-peer when possible;
  -- otherwise they can stream through this server (never stored).
  allow_relay = %s,
  max_relay_mb = %d, -- 0 = no limit per transfer
  udp = %s,          -- lets clients find a direct route. Behind a tunnel, it needs UDP on the same address and port.
}
]]

local function render(c)
  return TEMPLATE:format(c.name, c.port, c.bind, c.max_connections, c.max_connections_per_ip,
    c.max_handshakes, c.handshake_timeout, c.idle_timeout, c.max_file_mb, c.max_storage_mb,
    tostring(c.allow_relay), c.max_relay_mb, tostring(c.udp))
end

local function sandboxed_load(src, name)
  local env = {}
  local fn, err
  if setfenv then
    fn, err = loadstring(src, "=" .. name)
    if fn then setfenv(fn, env) end
  else
    fn, err = load(src, "=" .. name, "t", env)
  end
  if not fn then return nil, err end
  local ok, res = pcall(fn)
  if not ok then return nil, res end
  if type(res) ~= "table" then return nil, name .. " must return a table" end
  return res
end

-- Load <dir>/config.lua, creating it with defaults on first run. `overrides` win over the file.
function Config.load(dir, overrides)
  local path = fs.join(dir, "config.lua")
  local file = {}
  local src = fs.read(path)
  if src then
    local t, err = sandboxed_load(src, "config.lua")
    if not t then error("config.lua: " .. tostring(err)) end
    file = t
  end
  local c = {}
  for k, v in pairs(Config.DEFAULTS) do c[k] = v end
  for k, v in pairs(file) do c[k] = v end
  local missing = false
  for k in pairs(Config.DEFAULTS) do if file[k] == nil then missing = true end end
  if not src then
    if overrides and overrides.name then c.name = overrides.name end
    if overrides and overrides.port then c.port = overrides.port end
  end
  -- first run, or a config from an older version: write it out with every setting listed
  if missing then fs.write(path, render(c)) end
  for k, v in pairs(overrides or {}) do c[k] = v end
  assert(type(c.port) == "number" and c.port >= 0 and c.port <= 65535, "config: bad port")
  assert(type(c.name) == "string" and #c.name > 0 and #c.name <= 64, "config: name must be 1-64 characters")
  return c, path
end

return Config
