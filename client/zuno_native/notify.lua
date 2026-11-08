-- Desktop notifications while Zuno runs.
--   Windows: a tray icon whose balloon shows as a normal Windows notification.
--   Linux: notify-send (libnotify) when installed.   macOS: osascript.
-- flash() asks for attention (taskbar flash / dock bounce) through SDL.
local ffi = require("ffi")
local compat = require("zuno.compat")
local M = {}

local sdl, sdl_tried
local function load_sdl()
  if sdl_tried then return sdl end
  sdl_tried = true
  ffi.cdef[[
    typedef struct { uint8_t major, minor, patch; } ZUNO_SDL_version;
    typedef struct { ZUNO_SDL_version version; int subsystem;
      union { struct { void *window; void *hdc; void *hinstance; } win; uint8_t dummy[64]; } info; } ZUNO_SDL_SysWMinfo;
    void *SDL_GL_GetCurrentWindow(void);
    int SDL_GetWindowWMInfo(void *window, ZUNO_SDL_SysWMinfo *info);
    void SDL_GetVersion(ZUNO_SDL_version *ver);
    int SDL_FlashWindow(void *window, int operation);
  ]]
  local names = ffi.os == "Windows" and { "SDL2" } or (ffi.os == "OSX" and { "SDL2", "/Library/Frameworks/SDL2.framework/SDL2" } or { "SDL2-2.0.so.0", "SDL2" })
  for _, n in ipairs(names) do
    local ok, lib = pcall(ffi.load, n)
    if ok then sdl = lib; break end
  end
  -- LÖVE links SDL itself, so its symbols may already be in the process
  if not sdl then local ok = pcall(function() return ffi.C.SDL_GL_GetCurrentWindow end); if ok then sdl = ffi.C end end
  return sdl
end

local function window_handle()
  local lib = load_sdl()
  if not lib then return nil end
  local win = lib.SDL_GL_GetCurrentWindow()
  if win == nil then return nil end
  return win, lib
end

function M.flash()
  local win, lib = window_handle()
  if win then pcall(function() lib.SDL_FlashWindow(win, 2) end) end -- SDL_FLASH_UNTIL_FOCUSED
end

------------------------------------------------------------------ Windows
local tray
local function utf16_into(dst, max, s)
  local n = ffi.C.MultiByteToWideChar(65001, 0, s, #s, nil, 0)
  if n >= max then n = max - 1 end
  ffi.C.MultiByteToWideChar(65001, 0, s, #s, dst, n)
  dst[n] = 0
end

local function windows_show(title, body)
  if not tray then
    ffi.cdef[[
      typedef struct {
        uint32_t cbSize; void *hWnd; uint32_t uID; uint32_t uFlags; uint32_t uCallbackMessage; void *hIcon;
        uint16_t szTip[128]; uint32_t dwState; uint32_t dwStateMask; uint16_t szInfo[256]; uint32_t uVersion;
        uint16_t szInfoTitle[64]; uint32_t dwInfoFlags; uint8_t guidItem[16]; void *hBalloonIcon;
      } ZUNO_NOTIFYICONDATAW;
      int Shell_NotifyIconW(uint32_t msg, ZUNO_NOTIFYICONDATAW *data);
      void *ExtractIconW(void *inst, const uint16_t *file, uint32_t index);
      uint32_t GetModuleFileNameW(void *module, uint16_t *buf, uint32_t size);
      void *LoadImageW(void *inst, const uint16_t *name, uint32_t type, int cx, int cy, uint32_t flags);
    ]]
    -- also declared by files.lua; a second identical cdef would be an error
    pcall(ffi.cdef, "int MultiByteToWideChar(unsigned int cp, uint32_t flags, const char *s, int n, uint16_t *w, int wn);")
    local win, lib = window_handle()
    if not win then return false end
    local info = ffi.new("ZUNO_SDL_SysWMinfo")
    lib.SDL_GetVersion(info.version)
    if lib.SDL_GetWindowWMInfo(win, info) == 0 then return false end
    local shell = ffi.load("shell32")
    local d = ffi.new("ZUNO_NOTIFYICONDATAW")
    d.cbSize = ffi.sizeof(d)
    d.hWnd = info.info.win.window
    d.uID = 7001
    -- Zuno's icon (written to a real file by the backend); the exe's own icon otherwise
    if M.icon_path then
      local wp = ffi.new("uint16_t[1024]")
      utf16_into(wp, 1024, M.icon_path)
      local user32 = ffi.load("user32")
      -- IMAGE_ICON from a file: small for the tray, big for the notification itself
      local ok, icon = pcall(function() return user32.LoadImageW(nil, wp, 1, 0, 0, 0x10 + 0x40) end)
      if ok and icon ~= nil then d.hIcon = icon end
      local ok2, big = pcall(function() return user32.LoadImageW(nil, wp, 1, 64, 64, 0x10) end)
      if ok2 and big ~= nil then d.hBalloonIcon = big end
    end
    if d.hIcon == nil then
      local path = ffi.new("uint16_t[512]")
      ffi.C.GetModuleFileNameW(nil, path, 512)
      d.hIcon = shell.ExtractIconW(nil, path, 0)
    end
    d.uFlags = 0x2 + 0x4 -- NIF_ICON | NIF_TIP
    utf16_into(d.szTip, 128, "Zuno")
    if shell.Shell_NotifyIconW(0, d) == 0 then return false end -- NIM_ADD
    tray = { d = d, shell = shell }
  end
  local d = tray.d
  d.uFlags = 0x10 -- NIF_INFO
  utf16_into(d.szInfoTitle, 64, title)
  utf16_into(d.szInfo, 256, body ~= "" and body or " ")
  -- NIIF_USER | NIIF_LARGE_ICON shows Zuno's icon instead of the blue "i"; NIIF_NOSOUND because
  -- Zuno plays its own sound. The app name above it is the exe's FileDescription ("Zuno").
  d.dwInfoFlags = d.hBalloonIcon ~= nil and (0x4 + 0x20 + 0x10) or (0x1 + 0x10)
  return tray.shell.Shell_NotifyIconW(1, d) ~= 0 -- NIM_MODIFY
end

------------------------------------------------------------------ Linux / macOS
local function sh_quote(s) return "'" .. s:gsub("'", "'\\''") .. "'" end
local has_notify_send
local function linux_show(title, body)
  if has_notify_send == nil then
    local p = io.popen("command -v notify-send 2>/dev/null")
    has_notify_send = p and (p:read("*a") or "") ~= "" or false
    if p then p:close() end
  end
  if not has_notify_send then return false end
  os.execute("notify-send -a Zuno " .. sh_quote(title) .. " " .. sh_quote(body) .. " >/dev/null 2>&1 &")
  return true
end

local function mac_show(title, body)
  local function q(s) return '"' .. s:gsub('[\\"]', "\\%0") .. '"' end
  os.execute("osascript -e " .. sh_quote("display notification " .. q(body) .. " with title " .. q(title)) .. " >/dev/null 2>&1 &")
  return true
end

-- Keep notifications short and on one line each.
local function clean(s, max)
  s = tostring(s or ""):gsub("[%c]+", " ")
  if compat.utf8_len(s) > max then s = compat.utf8_sub(s, max - 1) .. "…" end
  return s
end

function M.show(title, body)
  title, body = clean(title, 60), clean(body, 200)
  M.last = { title = title, body = body } -- for tests
  if os.getenv("ZUNO_DEBUG_NOTIFY") then print("[notify] " .. title .. " | " .. body) end
  if ffi.os == "Windows" then return windows_show(title, body)
  elseif ffi.os == "OSX" then return mac_show(title, body)
  else return linux_show(title, body) end
end

function M.cleanup()
  if tray then pcall(tray.shell.Shell_NotifyIconW, 2, tray.d); tray = nil end -- NIM_DELETE
end

return M
