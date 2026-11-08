-- LÖVE implementation of the platform API (see ui/PLATFORM.md).
local utf8 = require("utf8")
local lg = love.graphics

local P = {}
local font_files = {
  regular = "assets/fonts/Inter-400.ttf", medium = "assets/fonts/Inter-500.ttf",
  semibold = "assets/fonts/Inter-600.ttf", bold = "assets/fonts/Inter-700.ttf",
  head = "assets/fonts/SpaceGrotesk-500.ttf", head_bold = "assets/fonts/SpaceGrotesk-700.ttf",
}
local fonts = {}

local function color(c) lg.setColor(c[1], c[2], c[3], c[4] or 1) end

function P.font(face, size)
  local k = face .. ":" .. size
  if not fonts[k] then
    local f = lg.newFont(font_files[face] or font_files.regular, size)
    f:setFallbacks(lg.newFont(size)) -- LÖVE's built-in font for symbols Inter lacks
    fonts[k] = f
  end
  return fonts[k]
end

function P.rect(x, y, w, h, c, r)
  if not c or w <= 0 or h <= 0 then return end
  color(c)
  r = math.min(r or 0, w / 2, h / 2)
  lg.rectangle("fill", x, y, w, h, r, r, r > 0 and 8 or nil)
end

function P.rect_line(x, y, w, h, c, r, width)
  if not c then return end
  color(c)
  lg.setLineWidth(width or 1)
  local inset = (width or 1) / 2
  r = math.min(r or 0, w / 2, h / 2)
  lg.rectangle("line", x + inset, y + inset, w - 2 * inset, h - 2 * inset, r, r, r > 0 and 8 or nil)
end

function P.circle(x, y, r, c) color(c); lg.circle("fill", x, y, r, math.max(12, math.floor(r * 2))) end
function P.circle_line(x, y, r, c, width) color(c); lg.setLineWidth(width or 1); lg.circle("line", x, y, r, math.max(12, math.floor(r * 2))) end

function P.line(points, c, width)
  color(c)
  lg.setLineWidth(width or 1)
  lg.setLineJoin("miter")
  lg.line(points)
end

function P.text(str, x, y, font, c)
  if str == "" then return end
  color(c)
  lg.setFont(font)
  lg.print(str, math.floor(x + 0.5), math.floor(y + 0.5))
end

function P.measure(font, str) return font:getWidth(str) end
function P.line_height(font) return font:getHeight() end

function P.wrap(font, str, width)
  local _, lines = font:getWrap(str, math.max(10, width))
  if #lines == 0 then lines = { "" } end
  return lines
end

local clip_stack = {}
function P.clip(x, y, w, h)
  clip_stack[#clip_stack + 1] = { lg.getScissor() }
  lg.setScissor(math.floor(x), math.floor(y), math.max(0, math.ceil(w)), math.max(0, math.ceil(h)))
end
function P.unclip()
  local prev = table.remove(clip_stack)
  if prev and prev[1] then lg.setScissor(prev[1], prev[2], prev[3], prev[4]) else lg.setScissor() end
end

local cursors = {}
local current_cursor
function P.set_cursor(kind)
  if kind == current_cursor then return end
  current_cursor = kind
  if not love.mouse.isCursorSupported() then return end
  if kind == "arrow" or not kind then love.mouse.setCursor() return end
  cursors[kind] = cursors[kind] or love.mouse.getSystemCursor(kind)
  love.mouse.setCursor(cursors[kind])
end

function P.set_clipboard(text) love.system.setClipboardText(text) end
function P.open_url(url) love.system.openURL(url) end
function P.now() return love.timer.getTime() end
function P.size() return lg.getDimensions() end

local system_dark = nil
P.detect_dark = nil -- set by main.lua
function P.device()
  local os_name = love.system.getOS()
  local mobile = os_name == "Android" or os_name == "iOS"
  return { form = mobile and "phone" or "desktop", input = mobile and "touch" or "mouse", dark = system_dark }
end
function P.set_system_dark(v) system_dark = v end

function P.safe_area()
  local x, y, w, h = love.window.getSafeArea()
  local W, H = lg.getDimensions()
  return { top = y, left = x, right = W - (x + w), bottom = H - (y + h) }
end

------------------------------------------------------------------ files
local files = require("zuno_native.files")
function P.save_file(name, data, label, ext, done) return files.save(name, data, label, ext, done) end
function P.pick_file(label, ext, done) return files.pick(label, ext, done) end
function P.file_dialog_open() return files.busy() end
function P.poll_files() files.poll() end

-- When no save dialog exists: write into the Zuno folder and return its real path.
function P.save_fallback(name, data)
  love.filesystem.createDirectory("exports")
  local ok, err = love.filesystem.write("exports/" .. name, data)
  if not ok then return nil, err end
  return love.filesystem.getSaveDirectory() .. "/exports/" .. name
end

function P.open_folder(path)
  path = path:gsub("\\", "/")
  if not path:find("^/") then path = "/" .. path end
  love.system.openURL("file://" .. path)
end

------------------------------------------------------------------ streaming / recording apps
-- Used by streamer mode "Auto". Checked at most every 10 seconds.
local ffi = require("ffi")
local REC_NAMES = { ["obs64.exe"] = true, ["obs32.exe"] = true, ["obs.exe"] = true, ["obs"] = true,
  ["streamlabs obs.exe"] = true, ["streamlabs desktop.exe"] = true, ["streamlabs"] = true, ["xsplit.core.exe"] = true }
local rec_checked, rec_state = -100, false
local toolhelp
local function scan_windows()
  if not toolhelp then
    ffi.cdef[[
      typedef struct { uint32_t dwSize; uint32_t cntUsage; uint32_t th32ProcessID; uintptr_t th32DefaultHeapID;
        uint32_t th32ModuleID; uint32_t cntThreads; uint32_t th32ParentProcessID; int32_t pcPriClassBase;
        uint32_t dwFlags; uint16_t szExeFile[260]; } ZUNO_PROCESSENTRY32W;
      void *CreateToolhelp32Snapshot(uint32_t flags, uint32_t pid);
      int Process32FirstW(void *snap, ZUNO_PROCESSENTRY32W *e);
      int Process32NextW(void *snap, ZUNO_PROCESSENTRY32W *e);
      int CloseHandle(void *h);
    ]]
    toolhelp = true
  end
  local snap = ffi.C.CreateToolhelp32Snapshot(2, 0)
  if snap == nil or ffi.cast("intptr_t", snap) == -1 then return false end
  local e = ffi.new("ZUNO_PROCESSENTRY32W")
  e.dwSize = ffi.sizeof(e)
  local found = false
  local ok = ffi.C.Process32FirstW(snap, e)
  while ok ~= 0 do
    local chars = {}
    for i = 0, 259 do
      local c = e.szExeFile[i]
      if c == 0 then break end
      chars[#chars + 1] = c < 128 and string.char(c) or "?"
    end
    if REC_NAMES[table.concat(chars):lower()] then found = true; break end
    ok = ffi.C.Process32NextW(snap, e)
  end
  ffi.C.CloseHandle(snap)
  return found
end
local function scan_linux()
  local p = io.popen("ls /proc 2>/dev/null")
  if not p then return false end
  local list = p:read("*a"); p:close()
  for pid in list:gmatch("%d+") do
    local f = io.open("/proc/" .. pid .. "/comm", "r")
    if f then
      local name = (f:read("*l") or ""):lower(); f:close()
      if REC_NAMES[name] then return true end
    end
  end
  return false
end
function P.recording_detected()
  local t = love.timer.getTime()
  if t - rec_checked > 10 then
    rec_checked = t
    local ok, res = pcall(ffi.os == "Windows" and scan_windows or (ffi.os == "Linux" and scan_linux or function() return false end))
    rec_state = ok and res or false
  end
  return rec_state
end

------------------------------------------------------------------ text fields
local Field = {}
Field.__index = Field
local fields = {}
local focused_field = nil
local frame_no = 0

function P.field(id, opts)
  local f = fields[id]
  if not f then
    f = setmetatable({ id = id, text = "", cursor = 0, anchor = nil, scroll_y = 0, scroll_x = 0, opts = opts or {}, blink = 0 }, Field)
    fields[id] = f
  end
  return f
end

function P.blur_all() if focused_field then focused_field.anchor = nil end; focused_field = nil end
function P.focused_field() return focused_field end
function P.new_frame() frame_no = frame_no + 1 end

local function lh_of(f) return math.floor(f.font:getHeight() * (f.opts.multiline and 1.35 or 1) + 0.5) end

-- Visual lines with byte ranges: { s = first byte index (1-based), e = last byte index, text }
local function layout_lines(font, text, width, multiline)
  local lines = {}
  if not multiline then
    lines[1] = { s = 1, e = #text, text = text }
    return lines
  end
  local pos = 1
  while true do
    local nl = text:find("\n", pos, true)
    local para_end = nl and nl - 1 or #text
    local para = text:sub(pos, para_end)
    if para == "" then
      lines[#lines + 1] = { s = pos, e = pos - 1, text = "" }
    else
      local ls = pos       -- line start byte
      local i = pos
      local last_break = nil
      while i <= para_end do
        local c = text:byte(i)
        local clen = c < 0x80 and 1 or (c < 0xE0 and 2 or (c < 0xF0 and 3 or 4))
        local candidate = text:sub(ls, i + clen - 1)
        if font:getWidth(candidate) > width and i > ls then
          local cut = last_break and last_break >= ls and last_break or (i - 1)
          lines[#lines + 1] = { s = ls, e = cut, text = text:sub(ls, cut) }
          ls = cut + 1
          last_break = nil
          i = ls
        else
          if c == 32 then last_break = i end
          i = i + clen
        end
      end
      lines[#lines + 1] = { s = ls, e = para_end, text = text:sub(ls, para_end) }
    end
    if not nl then break end
    pos = nl + 1
  end
  return lines
end

function Field:_lines(width)
  local w = width or self.w or 200
  local key = self.text .. "\0" .. w .. tostring(self.font)
  if self._lk ~= key then self._lk = key; self._lines_cache = layout_lines(self.font, self.text, w, self.opts.multiline) end
  return self._lines_cache
end

function Field:layout(x, y, w, font, col, ph_col, placeholder)
  self.x, self.y, self.w, self.font, self.color, self.ph_color = x, y, w, font, col, ph_col
  self.placeholder = placeholder or self.opts.placeholder
  self.drawn_frame = frame_no
end

function Field:height(w)
  if not self.font then return 20 end
  if not self.opts.multiline then return lh_of(self) end
  return #self:_lines(w) * lh_of(self)
end

function Field:get() return self.text end
function Field:set_secret(on) self.opts.secret = on and true or nil end
function Field:set(t)
  self.text = t or ""
  self.cursor = #self.text
  self.anchor = nil
  if self.on_change then self.on_change(self.text) end
end
function Field:focus() focused_field = self; self.blink = love.timer.getTime() end
function Field:blur() if focused_field == self then focused_field = nil end; self.anchor = nil end
function Field:focused() return focused_field == self end

-- Cursor position -> line index and x offset
function Field:_locate(pos)
  local lines = self:_lines()
  for i, l in ipairs(lines) do
    if pos >= l.s - 1 and pos <= l.e then
      return i, self.font:getWidth(self.text:sub(l.s, pos))
    end
  end
  local last = lines[#lines]
  return #lines, self.font:getWidth(last.text)
end

-- Point -> cursor position
function Field:_pos_at(px, py)
  local lines = self:_lines()
  local lh = lh_of(self)
  local li = math.max(1, math.min(#lines, math.floor((py - self.y + self.scroll_y) / lh) + 1))
  local l = lines[li]
  local rel = px - self.x + self.scroll_x
  local best, pos = math.huge, l.s - 1
  local i = l.s
  local prev_w = 0
  if math.abs(rel) < best then best = math.abs(rel); pos = l.s - 1 end
  while i <= l.e do
    local c = self.text:byte(i)
    local clen = c < 0x80 and 1 or (c < 0xE0 and 2 or (c < 0xF0 and 3 or 4))
    local wdt = self.font:getWidth(self.text:sub(l.s, i + clen - 1))
    if math.abs(rel - wdt) < best then best = math.abs(rel - wdt); pos = i + clen - 1 end
    prev_w = wdt
    i = i + clen
  end
  return pos
end

function Field:contains(x, y)
  if not self.x or self.drawn_frame ~= frame_no - 1 and self.drawn_frame ~= frame_no then return false end
  local h = self.visible_h or lh_of(self)
  return x >= self.x - 6 and x <= self.x + self.w + 6 and y >= self.y - 8 and y <= self.y + h + 8
end

local function sel_range(f)
  if not f.anchor or f.anchor == f.cursor then return nil end
  return math.min(f.anchor, f.cursor), math.max(f.anchor, f.cursor)
end

function Field:draw()
  if not self.font then return end
  local lines = self:_lines()
  local lh = lh_of(self)
  local total = #lines * lh
  local max_h = self.opts.multiline and 160 or lh
  local vis = math.min(total, max_h)
  self.visible_h = vis
  -- keep the cursor visible
  local cl, cx = self:_locate(self.cursor)
  local cy = (cl - 1) * lh
  if cy - self.scroll_y < 0 then self.scroll_y = cy end
  if cy + lh - self.scroll_y > vis then self.scroll_y = cy + lh - vis end
  self.scroll_y = math.max(0, math.min(self.scroll_y, total - vis))
  if not self.opts.multiline then
    if cx - self.scroll_x > self.w - 2 then self.scroll_x = cx - self.w + 2 end
    if cx - self.scroll_x < 0 then self.scroll_x = cx end
    if self.font:getWidth(self.text) - self.scroll_x < self.w then self.scroll_x = math.max(0, self.font:getWidth(self.text) - self.w + 2) end
  end
  P.clip(self.x - 2, self.y - 2, self.w + 4, vis + 4)
  local ox, oy = self.x - self.scroll_x, self.y - self.scroll_y
  local text_dy = math.floor((lh - self.font:getHeight()) / 2)
  if self.text == "" and self.placeholder then
    P.text(self.placeholder, ox, oy + text_dy, self.font, self.ph_color)
  end
  local a, b = sel_range(self)
  for i, l in ipairs(lines) do
    local ly = oy + (i - 1) * lh
    if a then
      local s, e = math.max(a, l.s - 1), math.min(b, l.e)
      if s < e or (s <= e and b > l.e and i < #lines) then
        local x1 = self.font:getWidth(self.text:sub(l.s, s))
        local x2 = self.font:getWidth(self.text:sub(l.s, e))
        if b > l.e and i < #lines then x2 = x2 + 6 end
        P.rect(ox + x1, ly, x2 - x1, lh, { 0.76, 0.26, 0.05, 0.28 })
      end
    end
    local shown = self.opts.secret and string.rep("•", utf8.len(l.text) or #l.text) or l.text
    P.text(shown, ox, ly + text_dy, self.font, self.color)
  end
  if focused_field == self and (love.timer.getTime() - self.blink) % 1.0 < 0.55 then
    P.rect(ox + cx, oy + cy + 2, 1.5, lh - 4, self.color)
  end
  P.unclip()
end

----- editing
local function clamp_pos(text, pos)
  pos = math.max(0, math.min(#text, pos))
  -- never stop in the middle of a UTF-8 sequence
  while pos > 0 and pos < #text and text:byte(pos + 1) >= 0x80 and text:byte(pos + 1) < 0xC0 do pos = pos - 1 end
  return pos
end

local function prev_char(text, pos)
  if pos <= 0 then return 0 end
  local p = pos - 1
  while p > 0 and text:byte(p + 1) >= 0x80 and text:byte(p + 1) < 0xC0 do p = p - 1 end
  return p
end

local function next_char(text, pos)
  if pos >= #text then return #text end
  local c = text:byte(pos + 1)
  return pos + (c < 0x80 and 1 or (c < 0xE0 and 2 or (c < 0xF0 and 3 or 4)))
end

local function word_left(text, pos)
  local p = pos
  while p > 0 and text:sub(p, p):match("%s") do p = p - 1 end
  while p > 0 and not text:sub(p, p):match("%s") do p = p - 1 end
  return p
end

local function word_right(text, pos)
  local p = pos
  while p < #text and text:sub(p + 1, p + 1):match("%s") do p = p + 1 end
  while p < #text and not text:sub(p + 1, p + 1):match("%s") do p = p + 1 end
  return p
end

function Field:_changed()
  self.blink = love.timer.getTime()
  if self.on_change then self.on_change(self.text) end
end

function Field:_replace(a, b, s)
  local max = self.opts.max_chars
  if not self.opts.multiline then s = s:gsub("[\r\n]+", " ") end
  if max then
    local room = max - (utf8.len(self.text:sub(1, a) .. self.text:sub(b + 1)) or 0)
    if room <= 0 then return end
    if (utf8.len(s) or 0) > room then s = s:sub(1, utf8.offset(s, room + 1) - 1) end
  end
  self.text = self.text:sub(1, a) .. s .. self.text:sub(b + 1)
  self.cursor = a + #s
  self.anchor = nil
  self:_changed()
end

function Field:insert(s)
  local a, b = sel_range(self)
  if a then self:_replace(a, b, s) else self:_replace(self.cursor, self.cursor, s) end
end

function Field:_move(pos, select)
  if select then self.anchor = self.anchor or self.cursor else self.anchor = nil end
  self.cursor = clamp_pos(self.text, pos)
  self.blink = love.timer.getTime()
end

-- Returns true if the key was used by the field.
function Field:key(key, ctrl, shift)
  local t = self.text
  if self.on_key and self.on_key(key) then return true end
  local a, b = sel_range(self)
  if key == "return" or key == "kpenter" then
    if self.opts.multiline and shift then self:insert("\n") return true end
    if self.on_submit then self.on_submit(self.text) end
    return true
  elseif key == "backspace" then
    if a then self:_replace(a, b, "")
    elseif self.cursor > 0 then
      local p = ctrl and word_left(t, self.cursor) or prev_char(t, self.cursor)
      self:_replace(p, self.cursor, "")
    end
    return true
  elseif key == "delete" then
    if a then self:_replace(a, b, "")
    elseif self.cursor < #t then
      local p = ctrl and word_right(t, self.cursor) or next_char(t, self.cursor)
      self:_replace(self.cursor, p, "")
    end
    return true
  elseif key == "left" then
    if a and not shift then self:_move(a, false) else self:_move(ctrl and word_left(t, self.cursor) or prev_char(t, self.cursor), shift) end
    return true
  elseif key == "right" then
    if a and not shift then self:_move(b, false) else self:_move(ctrl and word_right(t, self.cursor) or next_char(t, self.cursor), shift) end
    return true
  elseif key == "home" or key == "end" then
    if ctrl or not self.opts.multiline then self:_move(key == "home" and 0 or #t, shift) return true end
    local li = self:_locate(self.cursor)
    local l = self:_lines()[li]
    self:_move(key == "home" and l.s - 1 or l.e, shift)
    return true
  elseif (key == "up" or key == "down") and self.opts.multiline then
    local lines = self:_lines()
    local li, x = self:_locate(self.cursor)
    local target = li + (key == "up" and -1 or 1)
    if target < 1 then self:_move(0, shift) return true end
    if target > #lines then self:_move(#t, shift) return true end
    local lh = lh_of(self)
    self:_move(self:_pos_at(self.x + x - self.scroll_x, self.y + (target - 1) * lh - self.scroll_y + lh / 2), shift)
    return true
  elseif ctrl and key == "a" then self.anchor = 0; self.cursor = #t; return true
  elseif ctrl and (key == "c" or key == "x") then
    if a then
      love.system.setClipboardText(t:sub(a + 1, b))
      if key == "x" then self:_replace(a, b, "") end
    end
    return true
  elseif ctrl and key == "v" then
    local clip = love.system.getClipboardText() or ""
    clip = clip:gsub("\r\n?", "\n")
    if clip ~= "" then self:insert(clip) end
    return true
  end
  return false
end

------------------------------------------------------------------ modifier keys
-- Tracked from key events in order. love.keyboard.isDown() reports the state at the end of
-- an event batch, so a quick Shift+Enter could otherwise read as a plain Enter.
local held = {}
local MOD_KEYS = { lshift = "shift", rshift = "shift", lctrl = "ctrl", rctrl = "ctrl", lgui = "ctrl", rgui = "ctrl", lalt = "alt", ralt = "alt" }
function P.key_down(key) if MOD_KEYS[key] then held[key] = true end end
function P.key_up(key) if MOD_KEYS[key] then held[key] = nil end end
function P.mods()
  local m = {}
  for k in pairs(held) do m[MOD_KEYS[k]] = true end
  return m
end
function P.reset_mods() held = {} end

------------------------------------------------------------------ input routing for fields
function P.field_text_input(t)
  if focused_field and focused_field.drawn_frame and focused_field.drawn_frame >= frame_no - 1 then
    focused_field:insert(t)
    return true
  end
  return false
end

function P.field_key(key)
  local f = focused_field
  if not f or not f.drawn_frame or f.drawn_frame < frame_no - 1 then return false end
  local m = P.mods()
  return f:key(key, m.ctrl, m.shift)
end

local dragging
function P.field_mouse_pressed(x, y, button)
  if button ~= 1 then return false end
  for _, f in pairs(fields) do
    if f.drawn_frame and f.drawn_frame >= frame_no - 1 and f:contains(x, y) then
      f:focus()
      local pos = f:_pos_at(x, y)
      local shift = P.mods().shift
      f:_move(pos, shift)
      if not shift then f.anchor = pos end
      dragging = f
      return true
    end
  end
  return false
end

function P.field_mouse_moved(x, y)
  if dragging and love.mouse.isDown(1) then dragging.cursor = clamp_pos(dragging.text, dragging:_pos_at(x, y)) end
end

function P.field_mouse_released()
  if dragging and dragging.anchor == dragging.cursor then dragging.anchor = nil end
  dragging = nil
end

return P
