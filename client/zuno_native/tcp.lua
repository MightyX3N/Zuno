-- Non-blocking TCP transport for the client core (LuaSocket; works in LÖVE and plain LuaJIT).
-- `resolve` (optional) is a function(host) -> ip or nil, err, or "pending" while it works
-- in the background, so a slow DNS lookup never freezes the UI.
local socket = require("socket")

local TCP = {}
TCP.__index = TCP

local function is_ip(host)
  return host:match("^%d+%.%d+%.%d+%.%d+$") or host:find(":")
end

function TCP.factory(resolve)
  return function(host, port) return TCP.new(host, port, resolve) end
end

function TCP.new(host, port, resolve)
  local self = setmetatable({ host = host, port = port, resolve = resolve, state = "connecting", out = {} }, TCP)
  if is_ip(host) or not resolve then self.ip = host end
  return self
end

function TCP:_start_connect()
  local sock, err
  if self.ip:find(":") then sock, err = socket.tcp6() else sock, err = socket.tcp() end
  if not sock then return self:_fail(err) end
  sock:settimeout(0)
  local ok, cerr = sock:connect(self.ip, self.port)
  self.sock = sock
  if ok then self.state = "open"; sock:setoption("tcp-nodelay", true)
  elseif cerr ~= "timeout" and cerr ~= "Operation already in progress" then return self:_fail(cerr) end
end

function TCP:_fail(err)
  self.state, self.err = "closed", err
  if self.sock then self.sock:close(); self.sock = nil end
end

function TCP:status()
  if self.state == "connecting" then
    if not self.ip then
      local ip, err = self.resolve(self.host)
      if ip == "pending" then return "connecting" end
      if not ip then self:_fail("couldn't find " .. self.host .. (err and (" (" .. err .. ")") or "")); return self.state, self.err end
      self.ip = ip
    end
    if not self.sock then self:_start_connect(); if self.state ~= "connecting" then return self.state, self.err end end
    -- Ask connect() again: it reports "already connected", still in progress, or the real
    -- error. (On Windows a refused connect never shows up as writable in select().)
    local ok, err = self.sock:connect(self.ip, self.port)
    if ok or err == "already connected" then
      self.state = "open"
      self.sock:setoption("tcp-nodelay", true)
    elseif err ~= "timeout" and err ~= "Operation already in progress" and err ~= "Operation now in progress" then
      self:_fail(err or "connection refused")
    end
  end
  if self.state == "open" then self:_flush() end
  return self.state, self.err
end

function TCP:_flush()
  if #self.out == 0 or not self.sock then return end
  local data = table.concat(self.out)
  local last, err, partial = self.sock:send(data)
  local sent = last or partial or 0
  self.out = sent < #data and { data:sub(sent + 1) } or {}
  if err == "closed" then self:_fail("connection closed") end
end

function TCP:send(bytes)
  if self.state == "closed" then return end
  self.out[#self.out + 1] = bytes
  if self.state == "open" then self:_flush() end
end

function TCP:receive()
  if self.state ~= "open" then return nil end
  local data, err, partial = self.sock:receive(65536)
  data = data or partial
  if err == "closed" then
    self:_fail("connection closed")
    if data and #data > 0 then return data end
    return nil
  end
  if data and #data > 0 then
    if TCP.on_activity then TCP.on_activity() end
    return data
  end
  return nil
end

function TCP:close()
  if self.sock then self.sock:close(); self.sock = nil end
  self.state = "closed"
end

return TCP
