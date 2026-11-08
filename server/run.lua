-- Start a Zuno server.
--   luajit server/run.lua [--data DIR] [--port N] [--bind ADDR] [--name NAME]
-- Run it from the Zuno folder (the one containing protocol/ and server/).
local here = (arg and arg[0] or ""):match("^(.*)[/\\]server[/\\]run%.lua$") or "."
package.path = here .. "/protocol/?.lua;" .. here .. "/server/?.lua;" .. package.path

local crypto = require("zuno.crypto")
crypto.search_paths = { here .. "/build/native/linux-x64/libzunocrypto.so", here .. "/zunocrypto.dll", here .. "/libzunocrypto.so" }

local opts = { data_dir = here .. "/server/data" }
local i = 1
while arg and arg[i] do
  local a, v = arg[i], arg[i + 1]
  if a == "--data" then opts.data_dir = v; i = i + 1
  elseif a == "--port" then opts.port = tonumber(v); i = i + 1
  elseif a == "--bind" then opts.bind = v; i = i + 1
  elseif a == "--name" then opts.name = v; i = i + 1
  elseif a == "--help" or a == "-h" then
    print("usage: luajit server/run.lua [--data DIR] [--port N] [--bind ADDR] [--name NAME]")
    os.exit(0)
  else
    io.stderr:write("unknown option: " .. a .. "\n"); os.exit(1)
  end
  i = i + 1
end

local Server = require("zuno_server.server")
local srv
local ok, err = pcall(function()
  srv = Server.new(opts)
  srv:start()
  io.stdout:write("Press Ctrl+C to stop the server.\n")
  while true do srv:step(0.1) end
end)
if not ok and tostring(err):find("interrupted!") then
  if srv then srv:stop() end -- Ctrl+C: close the database cleanly
  os.exit(0)
end
if not ok then
  io.stderr:write("Zuno server error: " .. tostring(err) .. "\n")
  os.exit(1)
end
