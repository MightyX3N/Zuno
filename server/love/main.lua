-- Zuno server on the LÖVE runtime. Same options as server/run.lua:
--   "Zuno Server.exe" [--data DIR] [--port N] [--bind ADDR] [--name NAME]
-- Data goes next to the program in "server-data" unless --data is given.
love.filesystem.setRequirePath("?.lua;?/init.lua;protocol/?.lua;server/?.lua")

local ffi = require("ffi")
local base = love.filesystem.getSourceBaseDirectory()
local src = love.filesystem.getSource()

local crypto = require("zuno.crypto")
crypto.search_paths = ffi.os == "Windows" and { base .. "/zunocrypto.dll", src .. "/zunocrypto.dll" }
  or { src .. "/libzunocrypto.so", base .. "/libzunocrypto.so" }
local sqlite = require("zuno_server.sqlite")
sqlite.search_paths = ffi.os == "Windows" and { base .. "/sqlite3.dll", src .. "/sqlite3.dll" } or nil

local function parse(args)
  local opts = { data_dir = base .. "/server-data" }
  local i = 1
  while args[i] do
    local a, v = args[i], args[i + 1]
    if a == "--data" then opts.data_dir = v; i = i + 1
    elseif a == "--port" then opts.port = tonumber(v); i = i + 1
    elseif a == "--bind" then opts.bind = v; i = i + 1
    elseif a == "--name" then opts.name = v; i = i + 1
    end
    i = i + 1
  end
  return opts
end

function love.run()
  local args = love.arg.parseGameArguments(arg)
  local Server = require("zuno_server.server")
  local srv
  local ok, err = pcall(function()
    srv = Server.new(parse(args))
    srv:start()
    io.stdout:write("Close this window (or press Ctrl+C) to stop the server.\n")
    io.stdout:flush()
  end)
  if not ok then
    io.stderr:write("Zuno server error: " .. tostring(err) .. "\n")
    io.stderr:write("Press Enter to close.\n")
    io.read()
    return function() return 1 end
  end
  return function()
    local ok2, err2 = pcall(srv.step, srv, 0.1)
    if not ok2 then
      io.stderr:write("Zuno server error: " .. tostring(err2) .. "\n")
      pcall(srv.stop, srv)
      return 1
    end
    if love.event then
      love.event.pump()
      for name in love.event.poll() do
        if name == "quit" then srv:stop(); return 0 end
      end
    end
  end
end
