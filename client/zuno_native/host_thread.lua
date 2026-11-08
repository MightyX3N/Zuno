-- Runs the Zuno server inside the client ("Host a server"), in its own thread.
require("love.filesystem")
require("love.timer")
local args = ...
love.filesystem.setRequirePath("?.lua;?/init.lua;protocol/?.lua;server/?.lua;ui/?.lua")
local cmd = love.thread.getChannel("zuno_host_cmd")
local evt = love.thread.getChannel("zuno_host_evt")

local ok, err = pcall(function()
  local crypto = require("zuno.crypto")
  crypto.search_paths = args.crypto_paths
  local sqlite = require("zuno_server.sqlite")
  sqlite.search_paths = args.sqlite_paths
  local Server = require("zuno_server.server")
  local srv = Server.new({
    data_dir = args.data_dir, port = args.port, name = args.name, owner_key = args.owner_key,
    log = function(level, msg) evt:push({ kind = "log", level = level, msg = msg }) end,
  })
  srv.config.port = args.port
  srv.config.name = args.name
  srv:start()
  evt:push({ kind = "ready", port = srv.port, fingerprint = srv:fingerprint() })
  while true do
    srv:step(0.05)
    local c = cmd:pop()
    if c == "stop" then
      srv:stop()
      return
    end
  end
end)
if ok then evt:push({ kind = "stopped" }) else evt:push({ kind = "error", msg = tostring(err) }) end
