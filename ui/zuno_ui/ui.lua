-- Small immediate-mode UI core on top of the platform API.
-- Each frame the app draws and registers hit regions; input is matched against the
-- regions of the last finished frame (later regions are on top).
local UI = {}
UI.__index = UI

function UI.new(P)
  return setmetatable({
    P = P, regions = {}, prev = {}, mx = -1, my = -1,
    down_id = nil, clicked = {}, rclicked = {}, scroll = {}, clip_stack = {},
    hover_id = nil, hover_since = 0, tooltip = nil, keys = {}, texts = {},
    w = 800, h = 600,
  }, UI)
end

----------------------------------------------------------------- frame
function UI:begin(w, h)
  self.w, self.h = w, h
  self.prev = self.regions
  self.regions = {}
  self.clip_stack = {}
  self.cursor = "arrow"
  self.tooltip_req = nil
end

local function top_at(list, x, y, want_scroll)
  for i = #list, 1, -1 do
    local r = list[i]
    if x >= r.x and y >= r.y and x < r.x + r.w and y < r.y + r.h and (not want_scroll or r.scroll or r.block) then
      if want_scroll and r.block and not r.scroll then return nil end
      return r
    end
  end
end

function UI:finish()
  -- clicks and scrolls are consumed by the frame that saw them
  self.clicked, self.rclicked, self.scroll = {}, {}, {}
  local r = top_at(self.regions, self.mx, self.my)
  local id = r and r.id
  if id ~= self.hover_id then self.hover_id = id; self.hover_since = self.P.now() end
  if r and r.cursor then self.cursor = r.cursor end
  self.P.set_cursor(self.cursor)
  self.keys, self.texts = {}, {}
end

----------------------------------------------------------------- clipping
function UI:clip(x, y, w, h)
  local top = self.clip_stack[#self.clip_stack]
  if top then
    local x2, y2 = math.min(x + w, top[1] + top[3]), math.min(y + h, top[2] + top[4])
    x, y = math.max(x, top[1]), math.max(y, top[2])
    w, h = math.max(0, x2 - x), math.max(0, y2 - y)
  end
  self.clip_stack[#self.clip_stack + 1] = { x, y, w, h }
  self.P.clip(x, y, w, h)
end

function UI:unclip()
  self.clip_stack[#self.clip_stack] = nil
  self.P.unclip()
end

----------------------------------------------------------------- hit regions
-- opts: cursor ("hand" default for clickable), scroll (true = receives wheel), block (true = swallows
-- hits/scroll beneath, used by modals), tip (tooltip text)
function UI:hit(id, x, y, w, h, opts)
  opts = opts or {}
  local c = self.clip_stack[#self.clip_stack]
  if c then
    local x2, y2 = math.min(x + w, c[1] + c[3]), math.min(y + h, c[2] + c[4])
    x, y = math.max(x, c[1]), math.max(y, c[2])
    w, h = x2 - x, y2 - y
    if w <= 0 or h <= 0 then return {} end
  end
  local cursor = opts.cursor
  if cursor == nil and not opts.block and not opts.scroll then cursor = "hand" end
  if cursor == false then cursor = nil end
  self.regions[#self.regions + 1] = { id = id, x = x, y = y, w = w, h = h, cursor = cursor, scroll = opts.scroll, block = opts.block }
  local hovered = self.hover_id == id
  if hovered and opts.tip and self.P.now() - self.hover_since > 0.45 then
    self.tooltip_req = { text = opts.tip, x = x, y = y, w = w, h = h }
  end
  return {
    hovered = hovered,
    pressed = self.down_id == id,
    clicked = self.clicked[id] == true,
    rclicked = self.rclicked[id] == true,
    wheel = self.scroll[id],
  }
end

----------------------------------------------------------------- input from the backend
function UI:mouse_moved(x, y) self.mx, self.my = x, y end

function UI:mouse_pressed(x, y, button)
  self.mx, self.my = x, y
  local r = top_at(self.regions, x, y)
  if button == 1 then self.down_id = r and r.id end
  if button == 2 and r then self.rdown_id = r.id end
  self.mouse_down_any = true
  return r ~= nil
end

function UI:mouse_released(x, y, button)
  local r = top_at(self.regions, x, y)
  if button == 1 then
    if r and r.id == self.down_id then self.clicked[r.id] = true end
    self.down_id = nil
  elseif button == 2 then
    if r and r.id == self.rdown_id then self.rclicked[r.id] = true; self.rclick_x, self.rclick_y = x, y end
    self.rdown_id = nil
  end
end

function UI:wheel(dx, dy)
  local r = top_at(self.regions, self.mx, self.my, true)
  if r then self.scroll[r.id] = (self.scroll[r.id] or 0) + dy end
end

function UI:key(key, mods) self.keys[#self.keys + 1] = { key = key, mods = mods or {} } end
function UI:text_input(t) self.texts[#self.texts + 1] = t end

-- True once per press of `key` this frame (keys not taken by a focused text field).
function UI:pressed(key)
  for _, k in ipairs(self.keys) do if k.key == key then return true, k.mods end end
  return false
end

----------------------------------------------------------------- drawing helpers
function UI:text_fit(str, x, y, w, font, color)
  local P = self.P
  if P.measure(font, str) <= w then P.text(str, x, y, font, color); return end
  local ell = "…"
  local lo, hi = 0, #str
  while lo < hi do
    local mid = math.floor((lo + hi + 1) / 2)
    local cut = str:sub(1, mid)
    -- don't cut inside a UTF-8 sequence
    while #cut > 0 and cut:byte(#cut) >= 0x80 and cut:byte(#cut) < 0xC0 do cut = cut:sub(1, -2) end
    if #cut > 0 and cut:byte(#cut) >= 0xC0 then cut = cut:sub(1, -2) end
    if P.measure(font, cut .. ell) <= w then lo = mid else hi = mid - 1 end
  end
  local cut = str:sub(1, lo)
  while #cut > 0 and cut:byte(#cut) >= 0x80 and cut:byte(#cut) < 0xC0 do cut = cut:sub(1, -2) end
  if #cut > 0 and cut:byte(#cut) >= 0xC0 then cut = cut:sub(1, -2) end
  P.text(cut .. ell, x, y, font, color)
end

function UI:draw_tooltip(theme, font)
  local t = self.tooltip_req
  if not t then return end
  local P = self.P
  local tw = P.measure(font, t.text) + 20
  local th = P.line_height(font) + 12
  local x = math.min(math.max(8, t.x + t.w / 2 - tw / 2), self.w - tw - 8)
  local y = t.y + t.h + 6
  if y + th > self.h - 8 then y = t.y - th - 6 end
  P.rect(x, y, tw, th, theme.sel_bg, 7)
  P.text(t.text, x + 10, y + 6, font, theme.sel_fg)
end

return UI
