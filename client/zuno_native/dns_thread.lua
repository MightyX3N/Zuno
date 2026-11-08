-- Background DNS lookups so a slow resolver never freezes the window.
require("love.timer")
local socket = require("socket")
local req = love.thread.getChannel("zuno_dns_req")
local res = love.thread.getChannel("zuno_dns_res")
while true do
  local host = req:demand()
  if host == "__quit" then return end
  local ip, err = socket.dns.toip(host)
  res:push({ host = host, ip = ip or false, err = (not ip) and tostring(err) or false })
end
