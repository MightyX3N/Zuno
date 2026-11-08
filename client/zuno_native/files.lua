-- Native Open / Save dialogs and Unicode-safe file access for the desktop client.
--   files.save(default_name, data, label, ext) -> path | nil, "cancelled" | "unavailable" | err
--   files.pick(label, ext)                     -> data, path | nil, "cancelled" | "unavailable" | err
-- Windows: the system dialogs (comdlg32). Linux: zenity or kdialog when installed.
-- When neither works the UI falls back to drag-and-drop / the save folder.
local ffi = require("ffi")
local M = {}

local is_windows = ffi.os == "Windows"
local MAX_READ = 64 * 1024 * 1024

if is_windows then
  pcall(ffi.cdef, "int MultiByteToWideChar(unsigned int cp, uint32_t flags, const char *s, int n, uint16_t *w, int wn);")
  ffi.cdef[[
    typedef struct {
      uint32_t lStructSize; void *hwndOwner; void *hInstance; const uint16_t *lpstrFilter;
      uint16_t *lpstrCustomFilter; uint32_t nMaxCustFilter; uint32_t nFilterIndex; uint16_t *lpstrFile;
      uint32_t nMaxFile; uint16_t *lpstrFileTitle; uint32_t nMaxFileTitle; const uint16_t *lpstrInitialDir;
      const uint16_t *lpstrTitle; uint32_t Flags; uint16_t nFileOffset; uint16_t nFileExtension;
      const uint16_t *lpstrDefExt; intptr_t lCustData; void *lpfnHook; const uint16_t *lpTemplateName;
      void *pvReserved; uint32_t dwReserved; uint32_t FlagsEx;
    } ZUNO_OPENFILENAMEW;
    int GetOpenFileNameW(ZUNO_OPENFILENAMEW *ofn);
    int GetSaveFileNameW(ZUNO_OPENFILENAMEW *ofn);
    void *GetActiveWindow(void);
    int WideCharToMultiByte(unsigned int cp, uint32_t flags, const uint16_t *w, int wn, char *s, int n, const char *d, int *u);
    void *_wfopen(const uint16_t *path, const uint16_t *mode);
    size_t fread(void *buf, size_t size, size_t n, void *f);
    size_t fwrite(const void *buf, size_t size, size_t n, void *f);
    int fclose(void *f);
    int _fseeki64(void *f, int64_t off, int origin);
    int64_t _ftelli64(void *f);
    int _wrename(const uint16_t *a, const uint16_t *b);
    int _wremove(const uint16_t *p);
    int SHGetKnownFolderPath(const uint8_t *id, uint32_t flags, void *token, uint16_t **path);
    void CoTaskMemFree(void *p);
  ]]
end

local comdlg, user32
local function wide(s)
  local n = ffi.C.MultiByteToWideChar(65001, 0, s, #s, nil, 0)
  local buf = ffi.new("uint16_t[?]", n + 1)
  ffi.C.MultiByteToWideChar(65001, 0, s, #s, buf, n)
  buf[n] = 0
  return buf, n
end
local function narrow(w)
  local n = ffi.C.WideCharToMultiByte(65001, 0, w, -1, nil, 0, nil, nil)
  local buf = ffi.new("char[?]", n)
  ffi.C.WideCharToMultiByte(65001, 0, w, -1, buf, n, nil, nil)
  return ffi.string(buf)
end

-- Read / write any path (UTF-8), including non-ASCII paths on Windows.
function M.read(path)
  if is_windows then
    local wpath = wide(path)   -- one value each: wide() also returns a length
    local wmode = wide("rb")
    local f = ffi.C._wfopen(wpath, wmode)
    if f == nil then return nil, "couldn't open " .. path end
    local chunks, buf = {}, ffi.new("uint8_t[65536]")
    local total = 0
    while true do
      local n = tonumber(ffi.C.fread(buf, 1, 65536, f))
      if n <= 0 then break end
      total = total + n
      if total > MAX_READ then ffi.C.fclose(f); return nil, "file too large" end
      chunks[#chunks + 1] = ffi.string(buf, n)
    end
    ffi.C.fclose(f)
    return table.concat(chunks)
  end
  local f, err = io.open(path, "rb")
  if not f then return nil, err end
  local data = f:read(MAX_READ + 1); f:close()
  if data and #data > MAX_READ then return nil, "file too large" end
  return data or ""
end

function M.write(path, data)
  if is_windows then
    local wpath = wide(path)
    local wmode = wide("wb")
    local f = ffi.C._wfopen(wpath, wmode)
    if f == nil then return nil, "couldn't write " .. path end
    local n = tonumber(ffi.C.fwrite(data, 1, #data, f))
    ffi.C.fclose(f)
    if n ~= #data then return nil, "couldn't write the whole file" end
    return true
  end
  local f, err = io.open(path, "wb")
  if not f then return nil, err end
  f:write(data); f:close()
  return true
end

------------------------------------------------------------------ Windows dialogs
local function win_dialog(save, default_name, label, ext)  comdlg = comdlg or ffi.load("comdlg32")
  user32 = user32 or ffi.load("user32")
  -- ext nil = any file
  local filter_str = ext and ("%s (*.%s)\0*.%s\0All files (*.*)\0*.*\0\0"):format(label, ext, ext) or "All files (*.*)\0*.*\0\0"
  local filter = wide(filter_str)
  local fbuf = ffi.new("uint16_t[1024]")
  if default_name then
    local w, n = wide(default_name)
    ffi.copy(fbuf, w, math.min(n, 1000) * 2)
  end
  local ofn = ffi.new("ZUNO_OPENFILENAMEW")
  ofn.lStructSize = ffi.sizeof(ofn)
  ofn.hwndOwner = user32.GetActiveWindow()
  ofn.lpstrFilter = filter
  ofn.nFilterIndex = 1
  ofn.lpstrFile = fbuf
  ofn.nMaxFile = 1024
  local defext = ext and wide(ext)
  ofn.lpstrDefExt = defext
  -- OFN_EXPLORER | OFN_NOCHANGEDIR | OFN_PATHMUSTEXIST | (save: OVERWRITEPROMPT, open: FILEMUSTEXIST)
  ofn.Flags = 0x80000 + 0x8 + 0x800 + (save and 0x2 or 0x1000)
  local ok = save and comdlg.GetSaveFileNameW(ofn) or comdlg.GetOpenFileNameW(ofn)
  if ok == 0 then return nil, "cancelled" end
  return narrow(fbuf)
end

------------------------------------------------------------------ Linux dialogs
local function sh_quote(s) return "'" .. s:gsub("'", "'\\''") .. "'" end
local function has(cmd)
  local f = io.popen("command -v " .. cmd .. " 2>/dev/null")
  if not f then return false end
  local out = f:read("*a"); f:close()
  return out ~= nil and out ~= ""
end

-- The Linux dialog runs in a thread: while it is open the app must keep answering X11
-- (clipboard requests from the dialog, for example). Blocking here crashed the app.
local DIALOG_THREAD = [[
  local cmd = ...
  local f = io.popen(cmd)
  local out = f and (f:read("*a") or "") or false
  if f then f:close() end
  love.thread.getChannel("zuno_dialog"):push(out or "\0unavailable")
]]
local pending

local function linux_command(save, default_name, label, ext)
  local cmd
  if has("zenity") then
    cmd = "zenity --file-selection" .. (save and (" --save --confirm-overwrite --filename=" .. sh_quote(default_name or "")) or "")
      .. (ext and (" --file-filter=" .. sh_quote(label .. " | *." .. ext)) or "") .. " --file-filter='All files | *' 2>/dev/null"
  elseif has("kdialog") then
    cmd = "kdialog " .. (save and "--getsavefilename " or "--getopenfilename ") .. sh_quote(default_name or ".")
      .. " " .. sh_quote(ext and ("*." .. ext .. "|" .. label) or "*|All files") .. " 2>/dev/null"
  else
    return nil
  end
  return cmd
end

-- Opens a dialog; calls done(path) or done(nil, "cancelled" | "unavailable" | err) later.
local function dialog(save, default_name, label, ext, done)
  if is_windows then
    -- The Windows dialog keeps processing messages for our window itself.
    -- SDL's text input (IME) on our window empties the dialog's File name box: pause it.
    local typing = love and love.keyboard and love.keyboard.hasTextInput()
    if typing then love.keyboard.setTextInput(false) end
    local ok, path, err = pcall(win_dialog, save, default_name, label, ext)
    if typing then love.keyboard.setTextInput(true) end
    if not ok then return done(nil, "unavailable") end
    return done(path, err)
  elseif ffi.os == "Linux" and love and love.thread then
    if pending then return done(nil, "a file dialog is already open") end
    local cmd = linux_command(save, default_name, label, ext)
    if not cmd then return done(nil, "unavailable") end
    love.thread.getChannel("zuno_dialog"):clear()
    love.thread.newThread(DIALOG_THREAD):start(cmd)
    pending = function(out)
      if out == "\0unavailable" then return done(nil, "unavailable") end
      out = out:gsub("[\r\n]+$", "")
      if out == "" then return done(nil, "cancelled") end
      if save and ext and not out:lower():find("%." .. ext .. "$") then out = out .. "." .. ext end
      done(out)
    end
    return
  end
  done(nil, "unavailable")
end

-- Call every frame: delivers the result of a dialog running in the background.
function M.poll()
  if not pending then return end
  local out = love.thread.getChannel("zuno_dialog"):pop()
  if out then
    local cb = pending
    pending = nil
    cb(out)
  end
end

function M.busy() return pending ~= nil end

-- done(path) or done(nil, reason)
function M.save(default_name, data, label, ext, done)
  dialog(true, default_name, label, ext, function(path, err)
    if not path then return done(nil, err) end
    local okc, ok, werr = pcall(M.write, path, data)
    if not okc then return done(nil, tostring(ok)) end
    if not ok then return done(nil, werr) end
    done(path)
  end)
end

------------------------------------------------------------------ streaming access (big files)
-- h = files.open(path, "rb" | "ab" | "r+b" | "wb"); h:read(n), h:write(s), h:seek(off), h:size(), h:close()
local Handle = {}
Handle.__index = Handle

function M.open(path, mode)
  if is_windows then
    local f = ffi.C._wfopen((wide(path)), (wide(mode)))
    if f == nil then return nil, "couldn't open " .. path end
    return setmetatable({ f = f, win = true }, Handle)
  end
  local f, err = io.open(path, mode)
  if not f then return nil, err end
  return setmetatable({ f = f }, Handle)
end

function Handle:read(n)
  if self.win then
    local buf = ffi.new("uint8_t[?]", n)
    local got = tonumber(ffi.C.fread(buf, 1, n, self.f))
    if got <= 0 then return nil end
    return ffi.string(buf, got)
  end
  return self.f:read(n)
end
function Handle:write(s)
  if self.win then return tonumber(ffi.C.fwrite(s, 1, #s, self.f)) == #s end
  return self.f:write(s) ~= nil
end
function Handle:seek(off)
  if self.win then return ffi.C._fseeki64(self.f, off, 0) == 0 end
  return self.f:seek("set", off) ~= nil
end
function Handle:size()
  if self.win then
    ffi.C._fseeki64(self.f, 0, 2)
    return tonumber(ffi.C._ftelli64(self.f))
  end
  local cur = self.f:seek()
  local n = self.f:seek("end")
  self.f:seek("set", cur)
  return n
end
function Handle:close()
  if self.f == nil then return end
  if self.win then ffi.C.fclose(self.f) else self.f:close() end
  self.f = nil
end

function M.size(path)
  local h = M.open(path, "rb")
  if not h then return nil end
  local n = h:size(); h:close()
  return n
end

function M.rename(a, b)
  if is_windows then return ffi.C._wrename((wide(a)), (wide(b))) == 0 end
  return os.rename(a, b) ~= nil
end
function M.remove(p)
  if is_windows then return ffi.C._wremove((wide(p))) == 0 end
  return os.remove(p) ~= nil
end

-- The user's Downloads folder (created if missing), or nil.
local downloads
function M.downloads_dir()
  if downloads then return downloads end
  if is_windows then
    -- FOLDERID_Downloads {374DE290-123F-4565-9164-39C4925E467B}
    local id = ffi.new("uint8_t[16]", { 0x90, 0xE2, 0x4D, 0x37, 0x3F, 0x12, 0x65, 0x45, 0x91, 0x64, 0x39, 0xC4, 0x92, 0x5E, 0x46, 0x7B })
    local ok, dir = pcall(function()
      local shell = ffi.load("shell32")
      local out = ffi.new("uint16_t*[1]")
      if shell.SHGetKnownFolderPath(id, 0, nil, out) ~= 0 then return nil end
      local s = narrow(out[0])
      ffi.load("ole32").CoTaskMemFree(out[0])
      return s
    end)
    downloads = ok and dir or ((os.getenv("USERPROFILE") or ".") .. "\\Downloads")
  else
    local p = io.popen("xdg-user-dir DOWNLOAD 2>/dev/null")
    local d = p and p:read("*l")
    if p then p:close() end
    if not d or d == "" or d == os.getenv("HOME") then d = (os.getenv("HOME") or ".") .. "/Downloads" end
    os.execute("mkdir -p '" .. d:gsub("'", "'\\''") .. "'")
    downloads = d
  end
  return downloads
end

-- done(path, size) or done(nil, reason): choose a file without reading it (big transfers).
function M.pick_path(label, done)
  dialog(false, nil, label, nil, function(path, err)
    if not path then return done(nil, err) end
    local n = M.size(path)
    if not n then return done(nil, "couldn't open the file") end
    done(path, n)
  end)
end

-- done(data, path) or done(nil, reason)
function M.pick(label, ext, done)
  dialog(false, nil, label, ext, function(path, err)
    if not path then return done(nil, err) end
    local okc, data, rerr = pcall(M.read, path)
    if not okc then return done(nil, tostring(data)) end
    if not data then return done(nil, rerr) end
    done(data, path)
  end)
end

return M
