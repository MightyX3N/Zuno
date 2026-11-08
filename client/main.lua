-- Zuno desktop client (LÖVE 11.5).
love.filesystem.setRequirePath("?.lua;?/init.lua;protocol/?.lua;ui/?.lua;server/?.lua")

-- Optional separate profile, e.g. to run two clients on one PC: ZUNO_PROFILE=test love .
local profile = os.getenv("ZUNO_PROFILE")
if profile and profile:match("^[%w_-]+$") then love.filesystem.setIdentity("zuno-" .. profile) end

local ffi = require("ffi")
local src = love.filesystem.getSource()
local base = love.filesystem.getSourceBaseDirectory()
local function native_paths(win, linux)
  if ffi.os == "Windows" then return { base .. "/" .. win, src .. "/" .. win, win } end
  return { src .. "/" .. linux, base .. "/" .. linux, linux }
end
local CRYPTO_PATHS = native_paths("zunocrypto.dll", "libzunocrypto.so")
local SQLITE_PATHS = ffi.os == "Windows" and { base .. "/sqlite3.dll", src .. "/sqlite3.dll" } or {}

local crypto = require("zuno.crypto")
crypto.search_paths = CRYPTO_PATHS

local P = require("zuno_native.love_backend")
local TCP = require("zuno_native.tcp")
local UI = require("zuno_ui.ui")
local App = require("zuno_ui.app")
local Controller = require("zuno_ui.controller")
local pack = require("layouts.tabs.pack")

local ui, app, ctl
local last_input, last_net = 0, 0
local fatal_error

------------------------------------------------------------------ system dark mode
local advapi
if ffi.os == "Windows" then
  pcall(function()
    ffi.cdef[[
      long RegGetValueA(void *hkey, const char *sub, const char *value, unsigned long flags,
                        unsigned long *type, void *data, unsigned long *size);
    ]]
    advapi = ffi.load("advapi32")
  end)
end

local function detect_dark()
  if ffi.os == "Windows" then
    if not advapi then return nil end
    local ok, res = pcall(function()
      local adv = advapi
      local data = ffi.new("unsigned long[1]")
      local size = ffi.new("unsigned long[1]", 4)
      -- HKEY_CURRENT_USER is ((HKEY)(ULONG_PTR)((LONG)0x80000001)): sign-extended on 64-bit
      local HKCU = ffi.cast("void *", ffi.cast("intptr_t", -2147483647))
      local rc = adv.RegGetValueA(HKCU, "Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
        "AppsUseLightTheme", 0x10, nil, data, size)
      if rc ~= 0 then return nil end
      return data[0] == 0
    end)
    if ok then return res end
    return nil
  elseif ffi.os == "Linux" then
    local f = io.popen("gsettings get org.gnome.desktop.interface color-scheme 2>/dev/null")
    if not f then return nil end
    local out = f:read("*a") or ""
    f:close()
    if out:find("dark") then return true end
    if out:find("default") or out:find("light") then return false end
    return nil
  end
  return nil
end

------------------------------------------------------------------ DNS in a thread
local dns_cache, dns_pending = {}, {}
local dns_req, dns_res
local function resolve(host)
  local c = dns_cache[host]
  if c and love.timer.getTime() - c.at < 60 then
    if c.ip then return c.ip end
    return nil, c.err
  end
  while true do
    local r = dns_res:pop()
    if not r then break end
    dns_cache[r.host] = { ip = r.ip or nil, err = r.err or nil, at = love.timer.getTime() }
    dns_pending[r.host] = nil
  end
  c = dns_cache[host]
  if c and love.timer.getTime() - c.at < 60 then
    if c.ip then return c.ip end
    return nil, c.err
  end
  if not dns_pending[host] then dns_pending[host] = true; dns_req:push(host) end
  return "pending"
end

------------------------------------------------------------------ hosting
local host = { thread = nil, state = { running = false } }
local host_cmd, host_evt

function host.start(opts)
  if host.thread and host.thread:isRunning() then return nil, "A server is already running." end
  host.resumed = opts.resume and true or false
  host.state = { running = false, starting = true, port = opts.port }
  host_cmd:clear(); host_evt:clear()
  host.thread = love.thread.newThread("zuno_native/host_thread.lua")
  host.thread:start({
    data_dir = love.filesystem.getSaveDirectory() .. "/hosted-server",
    port = opts.port, name = opts.name, owner_key = opts.owner_key,
    crypto_paths = CRYPTO_PATHS, sqlite_paths = SQLITE_PATHS,
  })
  return true
end

function host.stop() if host.thread and host.thread:isRunning() then host_cmd:push("stop") end end
function host.status() return host.state end

local function poll_host()
  if not host_evt then return end
  while true do
    local e = host_evt:pop()
    if not e then break end
    if e.kind == "ready" then
      host.state = { running = true, port = e.port, fingerprint = e.fingerprint }
      if host.resumed then
        ctl:hosting_ready(e.port, true) -- reconnect our own tab, don't switch to it
      else
        ctl:toast("Your server is running on port " .. e.port .. ".")
        if ctl:hosting_ready(e.port) then app.page = nil end
      end
    elseif e.kind == "error" then
      local msg = e.msg:gsub("^.-:%d+: ", "")
      host.state = { running = false, error = msg }
      ctl:toast("Couldn't start the server: " .. msg, "error")
    elseif e.kind == "stopped" then
      host.state = { running = false }
      ctl:toast("Your server stopped.")
    elseif e.kind == "log" then
      print("[server] " .. e.level .. " " .. e.msg)
    end
  end
  if host.thread and not host.thread:isRunning() and host.state.running then
    host.state = { running = false, error = host.thread:getError() }
  end
end

------------------------------------------------------------------ LÖVE callbacks
function love.load()
  love.keyboard.setKeyRepeat(true)
  P.set_app_icon()
  love.keyboard.setTextInput(true)
  dns_req, dns_res = love.thread.getChannel("zuno_dns_req"), love.thread.getChannel("zuno_dns_res")
  love.thread.newThread("zuno_native/dns_thread.lua"):start()
  host_cmd, host_evt = love.thread.getChannel("zuno_host_cmd"), love.thread.getChannel("zuno_host_evt")

  local ok, err = pcall(crypto.load)
  if not ok then fatal_error = "Zuno couldn't load its crypto library.\n\n" .. tostring(err); return end

  P.set_system_dark(detect_dark())
  local storage = {
    read = function(name) return love.filesystem.read(name) end,
    write = function(name, data)
      local dir = name:match("^(.*)/[^/]*$")
      if dir then love.filesystem.createDirectory(dir) end
      assert(love.filesystem.write(name, data))
    end,
    remove = function(name) love.filesystem.remove(name) end,
    list = function(dir) return love.filesystem.getDirectoryItems(dir) end,
  }
  local transport = TCP.factory(resolve)
  if os.getenv("ZUNO_DEBUG_XFER") then require("zuno_ui.transfer").debug = print end
  ctl = Controller.new({ crypto = crypto, transport = transport, now = love.timer.getTime, storage = storage, host = host,
    notify = P.notify, sound = P.play_sound, attention = P.attention,
    transfer_env = { open = P.open_file, size = P.file_size, rename = P.rename_file, remove = P.remove_file,
                     downloads_dir = P.downloads_dir, sep = P.path_sep, udp = P.udp } })
  ui = UI.new(P)
  app = App.new(ui, P, ctl, pack)
  if #ctl.servers == 0 then app.page = "add" end
  ctl:resume_hosting()
end

local function mark() last_input = love.timer.getTime() end

function love.mousemoved(x, y) mark(); P.field_mouse_moved(x, y); if ui then ui:mouse_moved(x, y) end end
function love.mousepressed(x, y, b)
  mark()
  if not ui then return end
  P.field_mouse_pressed(x, y, b)
  ui:mouse_pressed(x, y, b)
end
function love.mousereleased(x, y, b) mark(); P.field_mouse_released(); if ui then ui:mouse_released(x, y, b) end end
function love.wheelmoved(dx, dy) mark(); if ui then ui:wheel(dx, dy) end end
function love.textinput(t) mark(); if not P.field_text_input(t) and ui then ui:text_input(t) end end
function love.keyreleased(key) P.key_up(key) end
function love.keypressed(key)
  mark()
  P.key_down(key)
  if not ui then return end
  if key == "f12" and os.getenv("ZUNO_SCREENSHOTS") then
    love.graphics.captureScreenshot("shot-" .. os.time() .. "-" .. math.floor(love.timer.getTime() * 1000) % 1000 .. ".png")
    return
  end
  if P.field_key(key) then return end
  ui:key(key, P.mods())
end
function love.resize() mark() end
function love.filedropped(file)
  mark()
  if not app then return end
  local name = file:getFilename():match("[^/\\]+$") or "file"
  file:open("r")
  local data = file:read(64 * 1024 * 1024)
  file:close()
  app:file_dropped(name, data or "")
end
function love.focus(f) mark(); if not f then P.reset_mods() end end

local dark_check = 0
function love.update()
  if not ctl then return end
  ctl:update()
  poll_host()
  P.poll_files()
  local t = love.timer.getTime()
  if t - dark_check > 15 then dark_check = t; P.set_system_dark(detect_dark()) end
end

function love.draw()
  if fatal_error then
    love.graphics.clear(0.98, 0.98, 0.97)
    love.graphics.setColor(0.1, 0.1, 0.1)
    love.graphics.printf(fatal_error, 40, 40, love.graphics.getWidth() - 80)
    return
  end
  P.new_frame()
  -- (app.modal dialogs clear focus themselves when they open, then focus their own fields)
  local modal = app.settings_open or app.dialog ~= nil or app.menu ~= nil
  if modal and not app.was_modal then P.blur_all() end
  app.was_modal = modal
  app:draw()
end

function love.quit()
  if host.thread and host.thread:isRunning() then
    host_cmd:push("stop")
    host.thread:wait()
  end
  if dns_req then dns_req:push("__quit") end
  if ctl then ctl:save() end
  pcall(function() require("zuno_native.notify").cleanup() end)
end

-- Draw at full speed only while something is happening; otherwise a few frames a second.
TCP.on_activity = function() last_net = love.timer.getTime() end
function love.run()
  if love.load then love.load(love.arg.parseGameArguments(arg), arg) end
  if love.timer then love.timer.step() end
  local next_idle_draw = 0
  return function()
    if love.event then
      love.event.pump()
      for name, a, b, c, d, e, f in love.event.poll() do
        if name == "quit" then
          if not love.quit or not love.quit() then return a or 0 end
        end
        love.handlers[name](a, b, c, d, e, f)
      end
    end
    if love.timer then love.timer.step() end
    if love.update then love.update() end
    local t = love.timer.getTime()
    local busy = t - last_input < 1.5 or t - last_net < 1.0 or (ctl and ctl.transfers and ctl.transfers:active() > 0)
    if love.graphics and love.graphics.isActive() and (busy or t >= next_idle_draw) then
      next_idle_draw = t + 0.25
      love.graphics.origin()
      love.graphics.clear(love.graphics.getBackgroundColor())
      love.draw()
      love.graphics.present()
    end
    if love.timer then love.timer.sleep(busy and 0.001 or 0.03) end
  end
end
