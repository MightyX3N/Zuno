-- Zuno client UI: the Tabs layout (desktop variant), drawn through the platform API.
local Theme = require("zuno_ui.theme")
local Icons = require("zuno_ui.icons")
local P_ = require("zuno.packets")
local version = require("zuno.version")
local AccountUI = require("zuno_ui.account_ui")
local Rich = require("zuno_ui.rich")
local E = require("zuno_ui.emoji")
local Compose = require("zuno_ui.compose")
local Picker = require("zuno_ui.emoji_picker")
local FilesUI = require("zuno_ui.files_ui")
local LinkUI = require("zuno_ui.link_ui")

local App = {}
App.__index = App

local TAB_BAR_H = 52
local NAV_W, INFO_W = 230, 260
local GROUP_GAP = 5 * 60 * 1000 -- ms between messages before a new name header

function App.new(ui, P, ctl, pack)
  local self = setmetatable({ ui = ui, P = P, ctl = ctl, pack = pack }, App)
  self.views = {}            -- entry -> per-server view state
  self.page = nil            -- nil (server), "add"
  self.wrap_cache, self.wrap_count = {}, 0
  self.rich_cache, self.rich_count = {}, 0
  self.fonts = {}
  self.menu, self.dialog = nil, nil
  self.settings_open = false
  return self
end

----------------------------------------------------------------- helpers
function App:font(face, size)
  local k = face .. size
  local f = self.fonts[k]
  if not f then f = self.P.font(face, size); self.fonts[k] = f end
  return f
end

function App:theme_name()
  local t = self.ctl.settings.theme
  if t == "system" then return self.P.device().dark and "dark" or "light" end
  return t
end

function App:wrap(font, text, width)
  local key = tostring(font) .. "|" .. width .. "|" .. text
  local v = self.wrap_cache[key]
  if v then return v end
  if self.wrap_count > 4000 then self.wrap_cache, self.wrap_count = {}, 0 end
  v = self.P.wrap(font, text, width)
  self.wrap_cache[key] = v
  self.wrap_count = self.wrap_count + 1
  return v
end

function App:view_for(entry)
  local v = self.views[entry]
  if not v then
    v = { scroll = 0, ch = entry.last_ch }
    self.views[entry] = v
  end
  return v
end

local function fmt_time(ms) return os.date("%H:%M", math.floor(ms / 1000)) end

local function day_label(ms)
  local t = math.floor(ms / 1000)
  local d = os.date("%Y-%m-%d", t)
  if d == os.date("%Y-%m-%d") then return "Today" end
  if d == os.date("%Y-%m-%d", os.time() - 86400) then return "Yesterday" end
  return os.date("%d %B %Y", t):gsub("^0", "")
end

function App:button(id, x, y, w, h, label, kind, opts)
  opts = opts or {}
  local P, T = self.P, self.T
  local disabled = opts.disabled
  local st = disabled and {} or self.ui:hit(id, x, y, w, h, { tip = opts.tip })
  local bg, fg
  if kind == "primary" then
    bg = st.hovered and T.accent_hover or T.accent; fg = T.on_accent
  elseif kind == "danger" then
    bg = T.danger; fg = T.on_accent
  elseif kind == "ghost" then
    bg = st.hovered and T.hover or nil; fg = T.text
  else
    bg = T.card; fg = T.text
  end
  if disabled then bg = bg and Theme.alpha(bg, 0.5); fg = Theme.alpha(fg, 0.6) end
  if bg then P.rect(x, y, w, h, bg, opts.radius or 9) end
  if kind == "secondary" or kind == nil then P.rect_line(x, y, w, h, st.hovered and T.text or T.line, opts.radius or 9, 1) end
  local f = opts.font or self:font("semibold", 13)
  if opts.icon then
    local tw = label ~= "" and P.measure(f, label) or 0
    local total = 18 + (tw > 0 and tw + 8 or 0)
    local ix = x + (w - total) / 2
    Icons.draw(P, opts.icon, ix, y + (h - 18) / 2, 18, fg)
    if tw > 0 then P.text(label, ix + 26, y + (h - P.line_height(f)) / 2, f, fg) end
  else
    P.text(label, x + (w - P.measure(f, label)) / 2, y + (h - P.line_height(f)) / 2, f, fg)
  end
  return st.clicked, st
end

function App:icon_button(id, icon, x, y, size, tip, active)
  local T = self.T
  local st = self.ui:hit(id, x, y, size, size, { tip = tip })
  if st.hovered or active then self.P.rect(x, y, size, size, active and T.sunken or T.hover, 8) end
  Icons.draw(self.P, icon, x + (size - 18) / 2, y + (size - 18) / 2, 18, st.hovered and T.text or T.soft)
  return st.clicked
end

-- Round picture of a member: their uploaded avatar when there is one (conn given), else a letter.
function App:avatar(key, name, x, y, size, conn)
  local T = self.T
  local m = conn and conn.members[key]
  local av = m and m.av
  if conn == nil and key == self.ctl.key then
    local c = self.ctl:conn()
    av = c and c.members[key] and c.members[key].av
    conn = c
  end
  if av and self.P.image_from_data then
    local img = FilesUI.image(self, conn, av)
    if img then FilesUI.draw_fit(self.P, img, x, y, size, size, true, size / 2); return end
  end
  local c = Theme.pick(T.avatars, key or name or "?")
  self.P.circle(x + size / 2, y + size / 2, size / 2, c)
  local letter = (name or "?"):match("^[%z\1-\127\194-\244][\128-\191]*") or "?"
  letter = letter:upper()
  local f = self:font("semibold", math.floor(size * 0.42))
  self.P.text(letter, x + (size - self.P.measure(f, letter)) / 2, y + (size - self.P.line_height(f)) / 2, f, { 0.09, 0.1, 0.11, 1 })
end

----------------------------------------------------------------- streamer mode
-- On when the user turned it on, or "auto" and a streaming / recording app is running.
function App:streamer()
  local s = self.ctl.settings.streamer
  if s == "on" then return true end
  if s == "off" then return false end
  return self.P.recording_detected and self.P.recording_detected() or false
end

-- Draws a cover over a secret when streamer mode is on. Returns true when the secret may be
-- shown (streamer mode off, or the user is holding the mouse on it).
function App:secret(text, id, x, y, w, h)
  if not self:streamer() then return true end
  local P, T = self.P, self.T
  local st = self.ui:hit("secret:" .. id, x, y, w, h, { tip = "Hidden in streamer mode. Hold to reveal." })
  if st.pressed then return true end
  local f = self:font("semibold", 12)
  local label = "Hidden · hold to reveal"
  local bw = math.min(w - 20, 260)
  P.rect(x + 12, y + h / 2 - 12, bw, 24, Theme.alpha(T.faint, 0.25), 12)
  self.ui:text_fit(label, x + 24, y + h / 2 - P.line_height(f) / 2, bw - 24, f, T.muted)
  return false
end

function App:file_dropped(name, data)
  if name:lower():find("%.zunokey$") then
    AccountUI.open_import(self, { name = name, data = data })
  elseif self.page ~= "add" and self.ctl:conn() and self.ctl:conn().status == "online" then
    local entry = self.ctl.servers[self.ctl.active]
    FilesUI.attach(self, self.ctl:conn(), self:view_for(entry), name, data)
  elseif self.on_file_dropped then
    self.on_file_dropped(name, data)
  else
    self.ctl:toast("To import an account, drop its .zunokey file here.")
  end
end

function App:label(text, x, y)
  self.P.text(text:upper(), x, y, self:font("head_bold", 11), self.T.muted)
end

function App:open_menu(x, y, items)
  self.menu = { x = x, y = y, items = items }
end

function App:confirm(title, text, ok_label, fn, danger)
  self.dialog = { kind = "confirm", title = title, text = text, ok = ok_label, fn = fn, danger = danger }
end

----------------------------------------------------------------- frame
function App:draw()
  local ui, P = self.ui, self.P
  local w, h = P.size()
  -- slow work runs one frame after its "working..." overlay was shown
  if self.job and self.job.shown then
    local j = self.job; self.job = nil
    local ok, err = pcall(j.fn)
    if not ok then self.ctl:toast("Something went wrong: " .. tostring(err), "error") end
  end
  self.T = Theme.build(self.pack, self:theme_name())
  local T = self.T
  ui:begin(w, h)
  P.rect(0, 0, w, h, T.app)

  -- what the user is looking at decides which messages notify
  self.ctl.viewing = { focused = (not P.window_focused) or P.window_focused() }
  self.ctl.streamer_on = self:streamer() -- notifications don't show message text while streaming
  self:draw_tabs(w)
  local conn = self.ctl:conn()
  local body_y = TAB_BAR_H
  P.rect(0, body_y, w, h - body_y, T.bg)
  if self.page == "add" or not conn then
    self:draw_add_page(0, body_y, w, h - body_y)
  else
    self:draw_server(conn, 0, body_y, w, h - body_y)
  end

  if self.settings_open then self:draw_settings(w, h) else self.settings_init = nil end
  if self.modal then
    if self.modal.kind == "export" then AccountUI.draw_export(self, w, h)
    elseif self.modal.kind == "import" then AccountUI.draw_import(self, w, h)
    elseif self.modal.draw then self.modal.draw(self, w, h) end
  end
  if self.viewer then FilesUI.draw_viewer(self, w, h) end
  if self.dialog then self:draw_dialog(w, h) end
  if self.picker then Picker.draw(self) end
  if self.menu then self:draw_menu(w, h) end
  self:draw_toasts(w, h)
  ui:draw_tooltip(T, self:font("medium", 12))
  if self.job then AccountUI.draw_job(self, w, h); self.job.shown = true end

  -- global keys
  if ui:pressed("escape") then
    if self.menu then self.menu = nil
    elseif self.picker then self.picker = nil
    elseif self.viewer then self.viewer = nil
    elseif self.dialog then self.dialog = nil
    elseif self.modal and not self.modal.sticky then self.modal = nil
    elseif self.settings_open then self.settings_open = false end
  end
  if ui:pressed(",") then
    local _, mods = ui:pressed(",")
    if mods.ctrl then self.settings_open = true end
  end
  ui:finish()
end

----------------------------------------------------------------- tab bar
function App:draw_tabs(w)
  local P, T, ui, ctl = self.P, self.T, self.ui, self.ctl
  P.rect(0, 0, w, TAB_BAR_H, T.bar)
  local x = 16
  local f = self:font("medium", 14)
  local right_reserved = 56
  for i, entry in ipairs(ctl.servers) do
    local conn = ctl.conns[entry]
    local name = entry.name or entry.address:gsub("#.*$", "")
    local unread, pings = 0, 0
    for _, n in pairs(conn.unread) do unread = unread + n end
    for _, n in pairs(conn.mentions) do pings = pings + n end
    local cnt = pings > 0 and ("@" .. pings) or (unread > 0 and tostring(unread) or "")
    local tw = math.min(180, P.measure(f, name))
    local cw = cnt ~= "" and (P.measure(self:font(pings > 0 and "semibold" or "regular", 12), cnt) + (pings > 0 and 20 or 8)) or 0
    local tab_w = 16 + 22 + 10 + tw + cw + 16
    if x + tab_w > w - right_reserved - 60 then break end
    local active = self.page ~= "add" and ctl.active == i
    local st = ui:hit("tab:" .. i, x, 10, tab_w, 42)
    if active then P.rect(x, 10, tab_w, 46, T.bg, 10)
    elseif st.hovered then P.rect(x, 10, tab_w, 42, T.hover, 10) end
    local color = Theme.pick(T.names, entry.key or name)
    P.rect(x + 16, 20, 22, 22, entry.hosted and T.accent or color, 6)
    local initial = (name:match("^[%w]") or "?"):upper()
    local fi = self:font("head_bold", 12)
    P.text(initial, x + 16 + (22 - P.measure(fi, initial)) / 2, 20 + (22 - P.line_height(fi)) / 2, fi, { 1, 1, 1, 1 })
    ui:text_fit(name, x + 48, 31 - P.line_height(f) / 2, tw, f, T.text)
    if pings > 0 then
      local bf = self:font("semibold", 12)
      P.rect(x + 48 + tw + 8, 22, P.measure(bf, cnt) + 12, 18, T.danger, 9)
      P.text(cnt, x + 48 + tw + 14, 31 - P.line_height(bf) / 2, bf, T.on_accent)
    elseif cnt ~= "" then
      P.text(cnt, x + 48 + tw + 8, 31 - P.line_height(self:font("regular", 12)) / 2, self:font("regular", 12), T.faint)
    end
    if conn.status ~= "online" then
      local dot = (conn.status == "key_changed" or conn.status == "outdated") and T.danger or T.idle
      P.circle(x + 38, 21, 4, T.bar); P.circle(x + 38, 21, 3, dot)
    end
    if st.clicked then ctl:select(i); self.page = nil end
    if st.rclicked then
      self:open_menu(ui.rclick_x, ui.rclick_y, {
        { label = "Reconnect", fn = function() conn:retry_now() end },
        { label = "Copy address", fn = function() P.set_clipboard((entry.address:gsub("#.*$", ""))) end },
        { label = "Remove server", danger = true, fn = function()
            self:confirm("Remove " .. name .. "?", "You can add it again later with its address.", "Remove",
              function() ctl:remove_server(i) end, true)
          end },
      })
    end
    x = x + tab_w + 4
  end
  -- "+" tab
  local add_active = self.page == "add" or #ctl.servers == 0
  local st = ui:hit("tab:add", x, 10, 44, 42, { tip = "Add or host a server" })
  if add_active then P.rect(x, 10, 44, 46, T.bg, 10) elseif st.hovered then P.rect(x, 10, 44, 42, T.hover, 10) end
  Icons.draw(P, "plus", x + 13, 22, 18, T.soft)
  if st.clicked then self.page = "add" end
  -- settings
  if self:icon_button("settings", "settings", w - 50, 12, 36, "Settings (Ctrl+,)") then self.settings_open = true end
end

----------------------------------------------------------------- server view
function App:draw_server(conn, x, y, w, h)
  local P, T = self.P, self.T
  local entry = self.ctl.servers[self.ctl.active]
  local v = self:view_for(entry)

  -- pick a channel
  local texts = conn:text_channels()
  if v.ch and not conn.channel_by_id[v.ch] and #conn.channels > 0 then v.ch = nil end
  if not v.ch and texts[1] then v.ch = texts[1].id end
  if conn.status == "online" and v.ch and conn.view_ch ~= v.ch then self:switch_channel(conn, entry, v, v.ch) end
  self.ctl.viewing.entry, self.ctl.viewing.ch = entry, v.ch

  local show_info = w >= 1000
  local chat_w = w - NAV_W - (show_info and INFO_W or 0)
  self:draw_nav(conn, entry, v, x, y, NAV_W, h)
  P.rect(x + NAV_W, y, 1, h, T.line)
  if show_info then
    P.rect(x + w - INFO_W, y, 1, h, T.line)
    self:draw_info(conn, entry, x + w - INFO_W, y, INFO_W, h)
  end
  self:draw_chat(conn, entry, v, x + NAV_W + 1, y, chat_w - 1, h)
end

function App:switch_channel(conn, entry, v, ch)
  local unread = conn.unread[ch] or 0
  v.ch = ch
  v.scroll = 0
  v.new_marker = nil
  if unread > 0 then
    local s = conn:store_for(ch)
    local list = s.list
    if #list >= unread then v.new_marker = list[#list - unread + 1].id
    elseif s.loaded then v.new_marker = list[1] and list[1].id end
    v.new_marker_pending = unread
  end
  conn:view(ch)
  self.ctl:remember_channel(entry, ch)
  local f = self.P.field("composer:" .. entry.address .. ":" .. ch, { multiline = true })
  f:focus()
end

function App:draw_nav(conn, entry, v, x, y, w, h)
  local P, T, ui = self.P, self.T, self.ui
  local cx, cy = x + 14, y + 20
  if #conn.channels > 0 then self:label("Text", cx + 10, cy) end
  cy = cy + 22
  local f = self:font("medium", 14)
  for _, ch in ipairs(conn:text_channels()) do
    local sel = ch.id == v.ch
    local unread = conn.unread[ch.id]
    local st = ui:hit("ch:" .. ch.id, cx, cy, w - 28, 34)
    if sel then P.rect(cx, cy, w - 28, 34, T.sel_bg, 8)
    elseif st.hovered then P.rect(cx, cy, w - 28, 34, T.hover, 8) end
    local color = sel and T.sel_fg or (unread and T.text or T.soft)
    local face = (sel or unread) and "medium" or "regular"
    ui:text_fit(ch.name, cx + 10, cy + 17 - P.line_height(f) / 2, w - 28 - 20 - (unread and 30 or 0), self:font(face, 14), color)
    local pings = conn.mentions[ch.id]
    if (unread or pings) and not sel then
      -- red with the number of mentions, otherwise the number of unread messages
      local n = pings or unread
      local s = (pings and "@" or "") .. (n > 99 and "99+" or tostring(n))
      local bf = self:font("semibold", 12)
      local bw = P.measure(bf, s) + 14
      P.rect(cx + w - 28 - bw - 8, cy + 8, bw, 18, pings and T.danger or T.accent, 9)
      P.text(s, cx + w - 28 - bw - 8 + 7, cy + 17 - P.line_height(bf) / 2, bf, T.on_accent)
    end
    if st.clicked and not sel and conn.status == "online" then self:switch_channel(conn, entry, v, ch.id) end
    if st.rclicked and conn:is_owner() then
      self:open_menu(ui.rclick_x, ui.rclick_y, {
        { label = "Copy name", fn = function() P.set_clipboard("#" .. ch.name) end },
        { label = "Delete channel", danger = true, fn = function()
            self:confirm("Delete #" .. ch.name .. "?", "All messages in it are deleted for everyone.", "Delete",
              function() conn:send({ t = "channel_delete", ch = ch.id }) end, true)
          end },
      })
    end
    cy = cy + 38
  end
  local voices = conn:voice_channels()
  if #voices > 0 then
    cy = cy + 14
    self:label("Voice", cx + 10, cy); cy = cy + 22
    for _, ch in ipairs(voices) do
      ui:hit("vc:" .. ch.id, cx, cy, w - 28, 34, { tip = "Voice channels arrive in a later update", cursor = false })
      Icons.draw(P, "speaker", cx + 10, cy + 8, 18, T.faint)
      ui:text_fit(ch.name, cx + 36, cy + 17 - P.line_height(f) / 2, w - 80, self:font("regular", 14), T.faint)
      cy = cy + 38
    end
  end
  -- me card
  local my = y + h - 66
  local me_name = conn.me and conn.me.name or self.ctl:display_name()
  local st = ui:hit("me", cx, my, w - 28, 52, { tip = "Settings" })
  P.rect(cx, my, w - 28, 52, st.hovered and T.input or T.sunken, 10)
  self:avatar(self.ctl.key, me_name, cx + 10, my + 10, 32, conn)
  ui:text_fit(me_name, cx + 52, my + 9, w - 28 - 62, self:font("semibold", 14), T.text)
  local status_text, status_color = "Online", T.voice
  if conn.status ~= "online" then status_text, status_color = "Offline", T.faint end
  if conn:is_owner() then status_text = status_text .. " · Owner" end
  P.text(status_text, cx + 52, my + 28, self:font("regular", 12), status_color)
  if st.clicked then self.settings_open = true end
end

function App:member_menu(conn, entry, m)
  local ui = self.ui
  local items = {}
  local v = self:view_for(entry)
  if v.ch and m.user ~= self.ctl.key then
    items[#items + 1] = { label = "Mention", fn = function()
      local f = self:composer(entry, v.ch)
      f:insert("@" .. m.name .. " "); f:focus()
    end }
  end
  if self.on_member_menu then self.on_member_menu(items, conn, entry, m) end
  items[#items + 1] = { label = "Copy name", fn = function() self.P.set_clipboard(m.name) end }
  self:open_menu(ui.rclick_x, ui.rclick_y, items)
end

function App:draw_info(conn, entry, x, y, w, h)
  local P, T = self.P, self.T
  local cx, cy, iw = x + 20, y + 20, w - 40
  self:label("Connection", cx, cy); cy = cy + 22
  local addr = entry.address:gsub("#.*$", "")
  P.rect(cx, cy, iw, 32, T.sunken, 8)
  local copy = self.ui:hit("copyaddr", cx, cy, iw, 32, { tip = "Copy invite (address + server key)" })
  if not self:streamer() or copy.hovered then
    self.ui:text_fit(addr, cx + 10, cy + 16 - P.line_height(self:font("head", 13)) / 2, iw - 20, self:font("head", 13), T.text)
  else
    self.ui:text_fit("Address hidden · click to copy invite", cx + 10, cy + 16 - P.line_height(self:font("medium", 12)) / 2, iw - 20, self:font("medium", 12), T.muted)
  end
  if copy.clicked then
    P.set_clipboard(addr .. (entry.key and ("#" .. entry.key:sub(1, 20)) or ""))
    self.ctl:toast("Invite copied. It includes the server key, so friends connect to the real server.")
  end
  cy = cy + 42
  local f = self:font("regular", 14)
  local function kv(k, val, col)
    P.text(k, cx, cy, f, T.soft)
    P.text(val, cx + iw - P.measure(f, val), cy, f, col or T.soft)
    cy = cy + 25
  end
  local status = ({ online = "Connected", connecting = "Connecting…", handshake = "Connecting…",
    waiting = "Reconnecting…", key_changed = "Identity changed", outdated = "Version mismatch", offline = "Offline",
    key_replaced = "Signed out" })[conn.status] or conn.status
  kv("Status", status, conn.status == "online" and T.ok or T.idle)
  kv("Latency", conn.latency and (conn.latency .. " ms") or "–")
  kv("Encryption", conn.status == "online" and "On" or "–", T.ok)
  if entry.key then
    P.text("Server key " .. (self:streamer() and "hidden" or P_.fingerprint(entry.key):sub(1, 14)), cx, cy, self:font("regular", 12), T.faint)
    cy = cy + 22
  end
  cy = cy + 10
  -- members: online first
  local online, offline = {}, {}
  for _, m in pairs(conn.members) do
    if m.online then online[#online + 1] = m else offline[#offline + 1] = m end
  end
  local function by_name(a, b) return a.name:lower() < b.name:lower() end
  table.sort(online, by_name); table.sort(offline, by_name)
  self:label(("Members · %d online"):format(#online), cx, cy); cy = cy + 24
  self.ui:clip(x, cy, w, y + h - cy)
  for _, list in ipairs({ online, offline }) do
    for _, m in ipairs(list) do
      if cy > y + h then break end
      local ms = self.ui:hit("member:" .. m.user, cx - 6, cy - 4, iw + 12, 32, { cursor = false })
      if ms.hovered then P.rect(cx - 6, cy - 4, iw + 12, 32, T.hover, 8) end
      self:avatar(m.user, m.name, cx, cy, 24, conn)
      P.circle(cx + 21, cy + 21, 5, T.bg)
      P.circle(cx + 21, cy + 21, 3.5, m.online and T.online or T.line)
      local col = m.online and T.text or T.faint
      local role = m.role == "owner" and "Owner" or ""
      self.ui:text_fit(m.name, cx + 34, cy + 12 - P.line_height(f) / 2, iw - 34 - (role ~= "" and 50 or 0), f, col)
      if role ~= "" then
        local rf = self:font("regular", 12)
        P.text(role, cx + iw - P.measure(rf, role), cy + 12 - P.line_height(rf) / 2, rf, T.faint)
      end
      if ms.rclicked then self:member_menu(conn, entry, m) end
      cy = cy + 34
    end
  end
  self.ui:unclip()
end

----------------------------------------------------------------- chat
local FACES = { regular = { "regular", 14 }, bold = { "bold", 14 }, italic = { "italic", 14 }, bold_italic = { "bold_italic", 14 },
  mono = { "mono", 13 }, h1 = { "head_bold", 22 }, h2 = { "head_bold", 18 }, h3 = { "head_bold", 16 } }

function App:rich_ctx(conn)
  local ctx = self._rich_ctx
  if not ctx then
    ctx = { P = self.P }
    ctx.font = function(face) local d = FACES[face] or FACES.regular; return self:font(d[1], d[2]) end
    ctx.lh = math.floor(self.P.line_height(self:font("regular", 14)) * 1.5 + 0.5)
    self._rich_ctx = ctx
  end
  ctx.name_for = function(k) return conn:member_name(k) end
  ctx.custom = function(name) return conn:custom_emoji(name) end
  ctx.draw_custom = function(file, x, y, size)
    local img = FilesUI.image(self, conn, file)
    if img then FilesUI.draw_fit(self.P, img, x, y, size, size, false) end
  end
  return ctx
end

-- Formatted message layout, cached (names of mentioned people are part of the key).
function App:rich(conn, body, width)
  local key = width .. "|" .. body
  if body:find("<@", 1, true) then
    key = key .. "|" .. (body:gsub("<@(%x+)>", function(k) return conn:member_name(k) end))
  end
  if body:find(":", 1, true) then conn:custom_emoji(""); key = key .. "|e:" .. (conn.emoji_key or "") end
  local L = self.rich_cache[key]
  if L then return L end
  if self.rich_count > 3000 then self.rich_cache, self.rich_count = {}, 0 end
  L = Rich.layout(body, width, self:rich_ctx(conn))
  self.rich_cache[key] = L
  self.rich_count = self.rich_count + 1
  return L
end

local PILL_H, PILL_GAP = 28, 6
-- Reaction pills of a message: { {x, y, w, emoji, count, idx}, ... }, height
function App:reaction_layout(m, width)
  local rx = m.rx
  if not rx or #rx == 0 then return nil, 0 end
  local f = self:font("semibold", 12)
  local out, x, y = {}, 0, 0
  for _, r in ipairs(rx) do
    local cnt = tostring(#r[2])
    local pw = 8 + 18 + 6 + self.P.measure(f, cnt) + 10
    if x > 0 and x + pw > width - 40 then x = 0; y = y + PILL_H + PILL_GAP end
    out[#out + 1] = { x = x, y = y, w = pw, emoji = r[1], count = cnt, keys = r[2], idx = E.lookup(r[1]), custom = r[1]:match("^:([a-z0-9_]+):$") }
    x = x + pw + PILL_GAP
  end
  out.add_x, out.add_y = x, y
  return out, y + PILL_H + 6
end

function App:message_layout(conn, v, ch, width)
  local s = conn:store_for(ch)
  local lh = self:rich_ctx(conn).lh
  local text_w = width - 56 - 14
  local items, y = {}, 0
  local prev
  local function add(it) it.y = y; items[#items + 1] = it; y = y + it.h end
  if s.loaded and not s.more then
    add({ kind = "start", h = 70 })
  elseif s.loaded and s.more then
    add({ kind = "loading", h = 40 })
  end
  local function add_msg(m, pending)
    local day = os.date("%Y-%m-%d", math.floor(m.at / 1000))
    if not prev or prev.day ~= day then
      add({ kind = "day", h = 38, text = day_label(m.at) })
      prev = nil
    end
    if v.new_marker and m.id == v.new_marker then add({ kind = "new", h = 30 }); prev = nil end
    local header = not prev or prev.a ~= m.a or (m.at - prev.at) > GROUP_GAP or pending ~= prev.pending or m.reply ~= nil
    local L = m.body ~= "" and self:rich(conn, m.body, text_w) or { h = 0, ops = {}, hits = {} }
    local reply_h = m.reply and 24 or 0
    local fitems, files_h = FilesUI.layout(m.files, text_w)
    local pills, pills_h = self:reaction_layout(m, text_w)
    local h = L.h + files_h + (header and (14 + 23) or 6) + reply_h + pills_h + (m.upload and 22 or 0)
    add({ kind = "msg", m = m, h = h, rich = L, header = header, lh = lh, pending = pending, reply_h = reply_h, pills = pills,
          fitems = fitems, files_h = files_h })
    prev = { a = m.a, at = m.at, day = day, pending = pending }
  end
  for _, m in ipairs(s.list) do add_msg(m) end
  for _, pm in ipairs(conn:pending_for(ch)) do
    add_msg({ id = -1, a = pm.a or self.ctl.key, at = math.floor(pm.at * 1000), body = pm.body, nonce = pm.nonce, state = pm.state,
              error = pm.error, reply = pm.reply, files = pm.files }, true)
  end
  -- messages whose files are still uploading
  for i, box in ipairs(v.outbox or {}) do
    if box.ch == ch then
      local names = {}
      for _, a in ipairs(box.list) do names[#names + 1] = a.name end
      add_msg({ id = -1, nonce = "outbox" .. i, a = self.ctl.key, at = math.floor(box.at * 1000), body = box.text,
                reply = box.reply_to and { id = box.reply_to }, upload = box, state = box.state, error = box.error,
                upload_names = table.concat(names, ", ") }, true)
    end
  end
  return items, y
end

function App:draw_chat(conn, entry, v, x, y, w, h)
  local P, T, ui = self.P, self.T, self.ui
  local ch = v.ch and conn.channel_by_id[v.ch]

  -- header
  local hh = 62
  if ch then
    local hf = self:font("head_bold", 22)
    P.text(ch.name, x + 28, y + 18, hf, T.text)
    if ch.topic and ch.topic ~= "" then
      local tx = x + 28 + P.measure(hf, ch.name) + 14
      ui:text_fit(ch.topic, tx, y + 18 + P.line_height(hf) - P.line_height(self:font("regular", 14)) - 2, x + w - 28 - tx, self:font("regular", 14), T.muted)
    end
  else
    P.text(entry.name or "Connecting", x + 28, y + 18, self:font("head_bold", 22), T.text)
  end
  P.rect(x, y + hh, w, 1, T.line)

  -- status panels instead of the chat
  if conn.status ~= "online" and not ch then return self:draw_status_panel(conn, entry, x, y + hh + 1, w, h - hh - 1) end
  if conn.status == "key_changed" or conn.status == "outdated" or conn.status == "key_replaced" then
    return self:draw_status_panel(conn, entry, x, y + hh + 1, w, h - hh - 1)
  end

  local top = y + hh + 1
  local banner_h = 0
  if conn.status ~= "online" then
    banner_h = 38
    P.rect(x, top, w, banner_h, Theme.alpha(T.idle, 0.14))
    local txt = conn.status == "waiting" and ("Connection lost. Reconnecting in " .. math.max(0, math.ceil(conn.next_try - self.P.now())) .. " s")
      or "Reconnecting…"
    P.text(txt, x + 28, top + 19 - P.line_height(self:font("medium", 13)) / 2, self:font("medium", 13), T.text)
    if conn.status == "waiting" and self:button("retry", x + w - 120, top + 5, 92, 28, "Retry now", "secondary") then conn:retry_now() end
  elseif conn.unclaimed and not conn:is_owner() then
    banner_h = 38
    P.rect(x, top, w, banner_h, T.sunken)
    P.text("No owner yet. If this is your server, send /claim followed by the code from the server console.", x + 28,
      top + 19 - P.line_height(self:font("regular", 13)) / 2, self:font("regular", 13), T.soft)
  end
  top = top + banner_h

  -- composer (measured first, list fills the rest)
  local field = ch and self:composer(entry, ch.id)
  local comp_inner_w = w - 56 - 28 - 44 - 80 - 38
  local fh = field and math.max(20, math.min(160, field:height(comp_inner_w))) or 20
  local comp_h = fh + 24
  if v.replying and ch and not conn:store_for(ch.id).by_id[v.replying] then v.replying = nil end
  local edit_bar = (v.editing or v.replying) and 30 or 0
  local attach_h = FilesUI.attach_height(v)
  local typing_h = 22
  local comp_y = y + h - 20 - comp_h
  local list_bottom = comp_y - edit_bar - attach_h - typing_h
  local list_h = list_bottom - top

  if ch then self:draw_messages(conn, entry, v, ch, x, top, w, list_h) end

  -- typing line
  local names = ch and conn:typing_names(ch.id) or {}
  if #names > 0 then
    local txt
    if #names == 1 then txt = names[1] .. " is typing…"
    elseif #names == 2 then txt = names[1] .. " and " .. names[2] .. " are typing…"
    else txt = "Several people are typing…" end
    P.text(txt, x + 28, list_bottom + 2, self:font("regular", 12), T.faint)
  end

  if not ch then return end
  -- edit bar
  if v.editing then
    local by = comp_y - edit_bar
    P.text("Editing message · Esc to cancel, Enter to save", x + 32, by + 6, self:font("medium", 12), T.accent)
  elseif v.replying then
    local by = comp_y - edit_bar
    local target = conn:store_for(ch.id).by_id[v.replying]
    local rf = self:font("medium", 12)
    local label = "Replying to "
    P.text(label, x + 32, by + 6, rf, T.muted)
    local nm = conn:member_name(target.a)
    P.text(nm, x + 32 + P.measure(rf, label), by + 6, self:font("semibold", 12), Theme.pick(T.names, target.a))
    P.text("· Esc to cancel", x + 32 + P.measure(rf, label) + P.measure(self:font("semibold", 12), nm) + 6, by + 6, rf, T.faint)
    if self:icon_button("reply:cancel", "close", x + w - 28 - 26, by + 1, 24, "Cancel reply") then v.replying = nil end
  end
  -- composer box
  local cx, cw = x + 28, w - 56
  local focused = field:focused()
  P.rect(cx, comp_y, cw, comp_h, T.card, 14)
  P.rect_line(cx, comp_y, cw, comp_h, focused and T.faint or T.input, 14, 1)
  local can_files = conn:supports("files")
  local attach = ui:hit("attach", cx + 10, comp_y + comp_h / 2 - 15, 30, 30,
    { tip = can_files and "Attach files (or drop them here)" or "This server is too old for files", cursor = can_files and "hand" or false })
  Icons.draw(P, "plus", cx + 16, comp_y + comp_h / 2 - 9, 18, attach.hovered and T.text or T.faint)
  if attach.clicked and can_files then FilesUI.pick(self, conn, v) end
  FilesUI.draw_attachments(self, v, cx, comp_y - edit_bar - FilesUI.attach_height(v), cw)
  local ph = conn.status == "online" and ("Message " .. ch.name) or "Waiting for the connection…"
  field:layout(cx + 48, comp_y + 12, comp_inner_w, self:font("regular", 14), T.text, T.faint, ph)
  ui:hit("composer_field", cx + 44, comp_y, comp_inner_w + 8, comp_h, { cursor = "ibeam" })
  field:draw()
  local can_send = (field:get():find("%S") ~= nil or (v.attach and #v.attach > 0)) and conn.status == "online"
  local eb = ui:hit("composer:emoji", cx + cw - 82 - 38, comp_y + comp_h - 44 + 6, 32, 32, { tip = "Emoji" })
  if eb.hovered then P.rect(cx + cw - 82 - 38, comp_y + comp_h - 44 + 6, 32, 32, T.hover, 8) end
  Icons.draw(P, "smile", cx + cw - 82 - 38 + 7, comp_y + comp_h - 44 + 13, 18, eb.hovered and T.text or T.faint)
  if eb.clicked then
    Picker.open(self, cx + cw - 82 - 22, comp_y, function(text, idx)
      field:insert((idx and (":" .. E.name(idx) .. ":") or text) .. " ")
      field:focus()
    end, { conn = conn })
  end
  if self:button("send", cx + cw - 82, comp_y + comp_h - 44 + 6, 72, 32, v.editing and "Save" or "Send", "primary", { disabled = not can_send }) then
    self:submit(conn, entry, v, ch, field)
  end

  -- @mention and :emoji: suggestions for the word at the cursor
  local sug = field:focused() and Compose.suggest(conn, field:get():sub(1, field:cursor_pos())) or nil
  if sug and v.sug_dismissed == field:get() then sug = nil end
  if sug then
    local key = sug.kind .. #sug.items .. (sug.items[1].name or "")
    if v.sug_key ~= key then v.sug_key = key; v.sug_sel = 1 end
    v.sug_sel = math.max(1, math.min(v.sug_sel or 1, #sug.items))
    self:draw_suggestions(conn, field, v, sug, cx, comp_y - edit_bar, math.min(cw, 420))
  end
  v.sug = sug

  field.on_submit = function()
    if v.sug then self:apply_suggestion(field, v.sug, v.sug.items[v.sug_sel or 1]); return end
    self:submit(conn, entry, v, ch, field)
  end
  field.on_change = function(text)
    -- pasted emoji become :shortcodes: (the field can't draw them)
    if text:find("[\226-\244]") then
      local conv = E.to_shortcodes(text)
      if conv ~= text then
        local from_end = #text - field:cursor_pos()
        field:set(conv)
        field:set_cursor(#conv - from_end)
        return
      end
    end
    v.sug_dismissed = nil
    if text ~= "" and not text:find("^/") and not v.editing then conn:typed(ch.id) end
  end
  field.on_key = function(key)
    if v.sug then
      if key == "up" then v.sug_sel = (v.sug_sel - 2) % #v.sug.items + 1; return true end
      if key == "down" then v.sug_sel = v.sug_sel % #v.sug.items + 1; return true end
      if key == "tab" then self:apply_suggestion(field, v.sug, v.sug.items[v.sug_sel]); return true end
      if key == "escape" then v.sug_dismissed = field:get(); return true end
    end
    if key == "up" and field:get() == "" then
      -- edit my last message
      local list = conn:store_for(ch.id).list
      for i = #list, 1, -1 do
        if list[i].a == self.ctl.key then
          v.editing = list[i].id; v.replying = nil; field:set(Compose.to_field(conn, list[i].body)); return true
        end
      end
    elseif key == "escape" and v.editing then
      v.editing = nil; field:set(""); return true
    elseif key == "escape" and v.replying then
      v.replying = nil; return true
    end
    return false
  end
end

function App:apply_suggestion(field, sug, item)
  if not item then return end
  local pos = field:cursor_pos()
  field:replace(sug.from - 1, pos, Compose.insert_text(item))
end

function App:draw_suggestions(conn, field, v, sug, x, bottom, w)
  local P, T, ui = self.P, self.T, self.ui
  local row = 34
  local h = 30 + #sug.items * row + 6
  local y = bottom - h - 6
  ui:hit("sug:card", x, y, w, h, { block = true, cursor = false })
  P.rect(x + 1, y + 3, w, h, { 0, 0, 0, 0.1 }, 12)
  P.rect(x, y, w, h, T.card, 12)
  P.rect_line(x, y, w, h, T.line, 12, 1)
  local title = sug.kind == "mention" and "Members" or "Emoji"
  P.text(title:upper(), x + 14, y + 10, self:font("semibold", 11), T.faint)
  P.text("Tab or Enter to pick", x + w - 14 - P.measure(self:font("regular", 11), "Tab or Enter to pick"), y + 10, self:font("regular", 11), T.faint)
  local f = self:font("medium", 14)
  for i, item in ipairs(sug.items) do
    local iy = y + 30 + (i - 1) * row
    local st = ui:hit("sug:" .. i, x + 4, iy, w - 8, row)
    if st.hovered then v.sug_sel = i end
    if i == v.sug_sel then P.rect(x + 4, iy, w - 8, row, T.sunken, 8) end
    if item.custom then
      local img = FilesUI.image(self, conn, item.custom)
      if img then FilesUI.draw_fit(P, img, x + 14, iy + 6, 22, 22, false) end
      P.text(":" .. item.name .. ":", x + 46, iy + row / 2 - P.line_height(f) / 2, f, T.text)
    elseif item.emoji then
      E.draw(P, item.emoji, x + 14, iy + 6, 22)
      P.text(":" .. item.name .. ":", x + 46, iy + row / 2 - P.line_height(f) / 2, f, T.text)
    else
      self:avatar(item.key, item.name, x + 12, iy + 5, 24)
      P.text(item.name, x + 46, iy + row / 2 - P.line_height(f) / 2, f, T.text)
      if item.online then P.circle(x + 33, iy + 26, 4, T.card); P.circle(x + 33, iy + 26, 3, T.online) end
    end
    if st.clicked then self:apply_suggestion(field, sug, item); field:focus() end
  end
end

function App:submit(conn, entry, v, ch, field)
  local text = field:get()
  local has_files = v.attach and #v.attach > 0 and not v.editing
  if not text:find("%S") and not has_files then return end
  if conn.status ~= "online" then self.ctl:toast("Not connected yet.", "error"); return end
  if v.editing then
    conn:edit_message(v.editing, Compose.to_wire(conn, text))
    v.editing = nil
  elseif text:find("^/%a") then
    conn:command(ch.id, text)
  elseif has_files then
    FilesUI.send(self, conn, v, ch.id, Compose.to_wire(conn, text), v.replying)
    v.new_marker = nil
    v.replying = nil
  else
    if not conn:send_message(ch.id, Compose.to_wire(conn, text), v.replying) then return end
    v.new_marker = nil
    v.replying = nil
  end
  field:set("")
  v.scroll = 0
end

function App:draw_messages(conn, entry, v, ch, x, y, w, h)
  local P, T, ui = self.P, self.T, self.ui
  local items, total = self:message_layout(conn, v, ch.id, w - 56)
  local s = conn:store_for(ch.id)

  -- scrolling (v.scroll = distance from the bottom)
  local st = ui:hit("list", x, y, w, h, { scroll = true })
  if st.wheel then v.scroll = v.scroll + st.wheel * 60 end
  local max_scroll = math.max(0, total - h + 20)
  if ui:pressed("pageup") then v.scroll = v.scroll + h * 0.8 end
  if ui:pressed("pagedown") then v.scroll = v.scroll - h * 0.8 end
  v.scroll = math.max(0, math.min(v.scroll, max_scroll))
  -- near the top: load older messages
  if s.loaded and s.more and not s.loading and total - h - v.scroll < 300 then conn:load_history(ch.id) end
  if not s.loaded and not s.loading and conn.status == "online" then conn:load_history(ch.id) end

  -- jump to a message (clicked reply preview)
  if v.jump_to then
    local found
    for _, it in ipairs(items) do if it.kind == "msg" and it.m.id == v.jump_to then found = it; break end end
    if found then
      v.scroll = math.max(0, math.min(max_scroll, total - found.y - found.h / 2 - h / 2 + 12))
      v.flash, v.flash_at, v.jump_to = found.m.id, P.now(), nil
    elseif s.more then
      if not s.loading then conn:load_history(ch.id) end
    else
      v.jump_to = nil
      self.ctl:toast("That message isn't here any more.")
    end
  end

  local offset = y + h - 12 - total + v.scroll -- y where item 0 starts
  if total < h - 12 then offset = y + 8 end
  ui:clip(x, y, w, h)
  local mx = x + 28
  local body_f, name_f, time_f = self:font("regular", 14), self:font("semibold", 14), self:font("regular", 12)
  for idx, it in ipairs(items) do
    local iy = offset + it.y
    if iy + it.h >= y and iy <= y + h then
      if it.kind == "day" then
        local tw = P.measure(time_f, it.text)
        local mid = mx + (w - 56) / 2
        P.rect(mx, iy + 19, (w - 56) / 2 - tw / 2 - 12, 1, T.line)
        P.rect(mid + tw / 2 + 12, iy + 19, (w - 56) / 2 - tw / 2 - 12, 1, T.line)
        P.text(it.text, mid - tw / 2, iy + 19 - P.line_height(time_f) / 2, time_f, T.faint)
      elseif it.kind == "new" then
        local lf = self:font("semibold", 11)
        local label = "NEW"
        P.rect(mx, iy + 15, w - 56 - P.measure(lf, label) - 10, 1, T.accent)
        P.text(label, mx + w - 56 - P.measure(lf, label), iy + 15 - P.line_height(lf) / 2, lf, T.accent)
      elseif it.kind == "start" then
        P.text("This is the start of #" .. ch.name, mx, iy + 18, self:font("head_bold", 16), T.text)
        P.text("Messages here are stored on the server, so new devices see them too.", mx, iy + 42, self:font("regular", 13), T.muted)
      elseif it.kind == "loading" then
        P.text(s.loading and "Loading older messages…" or "Scroll up for older messages", mx, iy + 12, time_f, T.faint)
      elseif it.kind == "msg" then
        self:draw_message(conn, entry, v, ch, it, idx, mx, iy, w - 56, body_f, name_f, time_f)
      end
    end
  end
  ui:unclip()

  -- jump to bottom button when far up
  if v.scroll > h then
    local bx, by = x + w - 28 - 150, y + h - 46
    if self:button("jump", bx, by, 150, 34, "Jump to newest", "secondary", { radius = 17 }) then v.scroll = 0 end
  end
end

function App:rich_colors()
  local T = self.T
  return { text = T.text, link = T.link, mention = T.mention, mention_bg = T.mention_bg, code = T.code, code_bg = T.code_bg,
           quote = T.quote, quote_bar = T.quote_bar, muted = T.muted }
end

function App:composer(entry, ch_id)
  return self.P.field("composer:" .. entry.address .. ":" .. ch_id, { multiline = true, max_chars = P_.LIMITS.message_chars })
end

-- Ask before opening a link from a message.
function App:open_link(url)
  self:confirm("Open this link?", url, "Open", function() self.P.open_url(url) end)
end

-- One line of text with emoji images, cut with … when too wide.
function App:draw_inline(text, x, y, maxw, font, color)
  local P = self.P
  local fh = P.line_height(font)
  local es = math.floor(fh * 1.15 + 0.5)
  local ell = "…"
  local ew = P.measure(font, ell)
  local cx = x
  for _, piece in ipairs(E.split(text)) do
    if piece.emoji then
      if cx + es + ew > x + maxw then P.text(ell, cx, y, font, color); return end
      E.draw(P, piece.emoji, cx + 1, y + (fh - es) / 2, es)
      cx = cx + es + 2
    else
      local t = piece.text
      local tw = P.measure(font, t)
      if cx + tw > x + maxw then
        -- cut by characters
        local out = ""
        for ch in t:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
          if cx + P.measure(font, out .. ch) + ew > x + maxw then break end
          out = out .. ch
        end
        P.text(out .. ell, cx, y, font, color)
        return
      end
      P.text(t, cx, y, font, color)
      cx = cx + tw
    end
  end
end

function App:start_reply(conn, entry, v, ch, m)
  v.replying = m.id
  v.editing = nil
  self:composer(entry, ch.id):focus()
end

function App:draw_message(conn, entry, v, ch, it, idx, x, y, w, body_f, name_f, time_f)
  local P, T, ui = self.P, self.T, self.ui
  local m = it.m
  local id = "msg:" .. (m.id > 0 and m.id or (m.nonce or idx))
  local st = ui:hit(id, x - 10, y, w + 20, it.h, { cursor = false })
  -- hovering this message's own toolbar or parts counts as hovering the message
  if not st.hovered and ui.hover_id and ui.hover_id:sub(1, #id + 1) == id .. ":" then st.hovered = true end
  local mine = m.a == self.ctl.key
  local ping = not it.pending and conn:pings_me(m)
  if ping then
    P.rect(x - 10, y, w + 20, it.h, T.ping_bg, 0)
    P.rect(x - 10, y, 2, it.h, T.ping_bar)
  end
  if v.flash == m.id and P.now() - (v.flash_at or 0) < 1.6 then
    P.rect(x - 10, y, w + 20, it.h, Theme.alpha(T.accent, 0.12 * (1 - (P.now() - v.flash_at) / 1.6)), 8)
  end
  if st.hovered or v.editing == m.id or v.replying == m.id then P.rect(x - 10, y, w + 20, it.h, T.hover, 8) end
  local alpha = it.pending and 0.55 or 1
  local top = y + (it.header and 14 or 3)

  -- the message this one replies to
  if m.reply then
    local r = m.reply
    local rf = self:font("regular", 13)
    local rx0 = x + 70
    P.line({ x + 34, top + 18, x + 34, top + 10, x + 38, top + 6, rx0 - 6, top + 6 }, T.faint, 1.5)
    local label, rx = "", rx0
    if r.gone or not r.a then
      label = "Original message was deleted"
      P.text(label, rx, top - 2, self:font("italic", 13), T.faint)
    else
      local nm = "@" .. conn:member_name(r.a)
      local nf = self:font("semibold", 13)
      P.text(nm, rx, top - 2, nf, Theme.alpha(Theme.pick(T.names, r.a), 0.9))
      rx = rx + P.measure(nf, nm) + 8
      local preview = Rich.preview(r.b or "", function(k) return conn:member_name(k) end)
      self:draw_inline(preview, rx, top - 2, x + w - rx - 10, rf, T.muted)
    end
    if not r.gone and r.id then
      local rs = ui:hit(id .. ":goto", rx0, top - 4, w - 70, 20, { tip = "Show the original message" })
      if rs.clicked then v.jump_to = r.id end
    end
    top = top + it.reply_h
  end

  if it.header then
    local nm = conn:member_name(m.a)
    self:avatar(m.a, nm, x + 16, top + 2, 38, conn)
    P.text(nm, x + 70, top, name_f, Theme.alpha(Theme.pick(T.names, m.a), alpha))
    P.text(fmt_time(m.at), x + 70 + P.measure(name_f, nm) + 8, top + 3, time_f, T.faint)
    top = top + 23
  elseif st.hovered then
    P.text(fmt_time(m.at), x, top + 3, self:font("regular", 11), T.faint)
  end

  -- body
  local L = it.rich
  local ctx = self:rich_ctx(conn)
  Rich.draw(L, x + 70, top, ctx, self:rich_colors(), alpha)
  if it.fitems and #it.fitems > 0 then FilesUI.draw(self, conn, id, it.fitems, x + 70, top + L.h) end
  if m.upload then
    local box = m.upload
    local uy = top + L.h + 4
    local f = self:font("regular", 12)
    if box.state == "failed" then
      P.text("Upload failed" .. (box.error and (": " .. box.error) or ""), x + 70, uy, f, T.danger)
      local bx = x + w - 130
      if self:button(id .. ":retry", bx, y + 4, 60, 24, "Retry", "secondary", { radius = 6, font = self:font("medium", 12) }) then
        for k, o in ipairs(v.outbox) do if o == box then table.remove(v.outbox, k); break end end
        v.attach = box.list
        FilesUI.send(self, conn, v, box.ch, box.text, box.reply_to)
      end
      if self:button(id .. ":drop", bx + 66, y + 4, 64, 24, "Discard", "secondary", { radius = 6, font = self:font("medium", 12) }) then
        for k, o in ipairs(v.outbox) do if o == box then table.remove(v.outbox, k); break end end
      end
    else
      local pct = math.floor(FilesUI.outbox_progress(box) * 100)
      local label = ("Uploading %s · %d%%"):format(m.upload_names, pct)
      ui:text_fit(label, x + 70, uy, w - 80 - 90, f, T.muted)
      P.rect(x + 70, uy + 17, math.min(300, w - 80), 3, T.sunken, 1.5)
      P.rect(x + 70, uy + 17, math.min(300, w - 80) * pct / 100, 3, T.accent, 1.5)
      if self:button(id .. ":cancel", x + w - 80, y + 4, 70, 24, "Cancel", "secondary", { radius = 6, font = self:font("medium", 12) }) then
        box.state = "cancelled"
        for _, j in ipairs(box.jobs) do if j.state ~= "done" then conn:cancel_upload(j) end end
        for k, o in ipairs(v.outbox) do if o == box then table.remove(v.outbox, k); break end end
      end
    end
    return
  end
  for hi, hit in ipairs(L.hits) do
    if hit.link then
      local hs = ui:hit(id .. ":link:" .. hi, x + 70 + hit.x, top + hit.y, hit.w, hit.h, { tip = hit.link, cursor = "hand" })
      if hs.clicked then self:open_link(hit.link) end
    elseif hit.mention then
      ui:hit(id .. ":mention:" .. hi, x + 70 + hit.x, top + hit.y, hit.w, hit.h, { tip = conn:member_name(hit.mention), cursor = false })
    end
  end
  -- "(edited)" / sending state after the last line
  local last
  for _, op in ipairs(L.ops) do if op.atom and (not last or op.y > last.y or (op.y == last.y and op.x >= last.x)) then last = op end end
  local after_x = x + 70 + (last and (last.x + last.atom.w + 6) or 0)
  local after_y = top + (last and last.y or 0) + (ctx.lh - P.line_height(time_f)) / 2
  if not last then after_y = top + L.h + it.files_h + 2 end
  if L.jumbo then after_x, after_y = x + 70, top + L.h - 14 end
  if m.edited then P.text("(edited)", after_x, after_y, time_f, T.faint) end
  if it.pending then
    if m.state == "failed" then
      P.text("Not sent" .. (m.error and (": " .. m.error) or ""), after_x, after_y, time_f, T.danger)
      local bx = x + w - 130
      if self:button(id .. ":retry", bx, y + 4, 60, 24, "Retry", "secondary", { radius = 6, font = self:font("medium", 12) }) then
        conn:drop_pending(m.nonce); conn:send_message(ch.id, m.body, m.reply and m.reply.id)
      end
      if self:button(id .. ":drop", bx + 66, y + 4, 64, 24, "Discard", "secondary", { radius = 6, font = self:font("medium", 12) }) then
        conn:drop_pending(m.nonce)
      end
    else
      P.text("Sending…", after_x, after_y, time_f, T.faint)
    end
    return
  end

  -- reactions
  local can_react = conn:supports("react") and conn.status == "online"
  if it.pills then
    local py = top + L.h + it.files_h + 4
    local f = self:font("semibold", 12)
    for pi, pill in ipairs(it.pills) do
      local px = x + 70 + pill.x
      local mine_r = conn:reacted(m, pill.emoji)
      local names = {}
      for i, k in ipairs(pill.keys) do
        if i > 6 then names[#names + 1] = ("%d more"):format(#pill.keys - 6); break end
        names[#names + 1] = k == self.ctl.key and "You" or conn:member_name(k)
      end
      local tip = table.concat(names, ", ") .. " · :" .. (pill.idx and E.name(pill.idx) or pill.custom or "?") .. ":"
      local ps = ui:hit(id .. ":rx:" .. pi, px, py + pill.y, pill.w, PILL_H, { tip = tip })
      P.rect(px, py + pill.y, pill.w, PILL_H, mine_r and T.react_mine or T.react_bg, PILL_H / 2)
      P.rect_line(px, py + pill.y, pill.w, PILL_H, mine_r and T.react_line or (ps.hovered and T.faint or T.line), PILL_H / 2, 1)
      local cf = pill.custom and conn:custom_emoji(pill.custom)
      local cimg = cf and FilesUI.image(self, conn, cf)
      if pill.idx then E.draw(P, pill.idx, px + 8, py + pill.y + 5, 18)
      elseif cimg then FilesUI.draw_fit(P, cimg, px + 8, py + pill.y + 5, 18, 18, false)
      else P.text(pill.custom and "?" or pill.emoji, px + 8, py + pill.y + 6, f, T.text) end
      P.text(pill.count, px + 32, py + pill.y + PILL_H / 2 - P.line_height(f) / 2, f, mine_r and T.mention or T.soft)
      if ps.clicked and can_react then conn:react(m, pill.emoji) end
    end
    if st.hovered and can_react then
      local ax, ay = x + 70 + it.pills.add_x, py + it.pills.add_y
      local as = ui:hit(id .. ":rx:add", ax, ay, 40, PILL_H, { tip = "Add a reaction" })
      P.rect_line(ax, ay, 40, PILL_H, as.hovered and T.faint or T.line, PILL_H / 2, 1)
      Icons.draw(P, "react", ax + 11, ay + 5, 18, as.hovered and T.text or T.faint)
      if as.clicked then
        Picker.open(self, ax + 20, ay, function(e) conn:react(m, e, true) end, { conn = conn })
      end
    end
  end

  -- hover toolbar
  local can_delete = mine or conn:is_owner()
  local actions = {}
  if can_react then
    actions[#actions + 1] = { "react", "Add a reaction", function(bx, by)
      Picker.open(self, bx, by, function(e) conn:react(m, e, true) end, { conn = conn })
    end }
    actions[#actions + 1] = { "reply", "Reply", function() self:start_reply(conn, entry, v, ch, m) end }
  end
  actions[#actions + 1] = { "copy", "Copy text", function()
    P.set_clipboard(Rich.plain(m.body, function(k) return conn:member_name(k) end)); self.ctl:toast("Copied")
  end }
  if mine then
    actions[#actions + 1] = { "edit", "Edit", function()
      v.editing = m.id; v.replying = nil
      local f = self:composer(entry, ch.id)
      f:set(Compose.to_field(conn, m.body)); f:focus()
    end }
  end
  if can_delete then
    actions[#actions + 1] = { "trash", "Delete", function()
      self:confirm("Delete this message?", "It's removed for everyone.", "Delete", function() conn:delete_message(m.id) end, true)
    end }
  end
  if st.hovered then
    local bw = #actions * 30 + 6
    local bx, by = x + w - bw, y - 12
    if by < 0 then by = y + 2 end
    P.rect(bx, by, bw, 32, T.card, 8)
    P.rect_line(bx, by, bw, 32, T.line, 8, 1)
    for i, a in ipairs(actions) do
      local ix = bx + 3 + (i - 1) * 30
      if self:icon_button(id .. ":" .. a[1], a[1], ix, by + 2, 28, a[2]) then a[3](ix + 14, by) end
    end
  end
  if st.rclicked then
    local items = {}
    for _, a in ipairs(actions) do
      items[#items + 1] = { label = a[2], fn = function() a[3](ui.rclick_x, ui.rclick_y) end, danger = a[1] == "trash" }
    end
    self:open_menu(ui.rclick_x, ui.rclick_y, items)
  end
end

function App:draw_status_panel(conn, entry, x, y, w, h)
  local P, T = self.P, self.T
  local cw = math.min(520, w - 60)
  local cx = x + (w - cw) / 2
  local cy = y + math.max(40, h * 0.18)
  local f = self:font("regular", 14)
  if conn.status == "key_changed" then
    P.rect(cx, cy, cw, 300, T.danger_bg, 16)
    P.rect_line(cx, cy, cw, 300, T.danger, 16, 1.5)
    Icons.draw(P, "warn", cx + 24, cy + 24, 28, T.danger)
    P.text("This server's identity changed", cx + 64, cy + 26, self:font("head_bold", 20), T.text)
    local lines = self:wrap(f, (conn.error or "") .. " If the owner moved or reinstalled the server without its backup, this is expected. Otherwise, don't continue.", cw - 48)
    for i, l in ipairs(lines) do P.text(l, cx + 24, cy + 70 + (i - 1) * 21, f, T.soft) end
    local ky = cy + 80 + #lines * 21
    if self:secret("keys", "keychange", cx + 20, ky - 4, cw - 40, 44) then
      P.text("Expected: " .. (entry.key and P_.fingerprint(entry.key) or (entry.fingerprint or "?"):upper()), cx + 24, ky, self:font("head", 13), T.soft)
      P.text("Now:        " .. P_.fingerprint(conn.changed_key or ""), cx + 24, ky + 22, self:font("head", 13), T.danger)
    end
    if self:button("trust", cx + 24, cy + 300 - 60, 170, 38, "Trust the new identity", "danger") then
      self:confirm("Trust the new identity?", "Only do this if you're sure the owner changed the server.", "Trust it",
        function() conn:accept_new_key() end, true)
    end
    if self:button("stayoff", cx + 206, cy + 300 - 60, 120, 38, "Stay offline", "secondary") then conn:disconnect(true) end
    return
  end
  local title, text = "Connecting…", "Reaching " .. (self:streamer() and "the server" or (entry.address:gsub("#.*$", "")))
  if conn.status == "outdated" then title, text = "Version mismatch", conn.error
  elseif conn.status == "key_replaced" then title, text = "This device was signed out", conn.error
  elseif conn.status == "waiting" then
    title = "Can't reach the server"
    text = (conn.error and (conn.error:gsub("^%l", string.upper) .. ". ") or "") ..
      ("Trying again in %d s."):format(math.max(0, math.ceil(conn.next_try - P.now())))
  elseif conn.status == "offline" then title, text = "Offline", "You disconnected from this server." end
  P.text(title, cx, cy, self:font("head_bold", 22), T.text)
  local lines = self:wrap(f, text or "", cw)
  for i, l in ipairs(lines) do P.text(l, cx, cy + 40 + (i - 1) * 21, f, T.muted) end
  local by = cy + 54 + #lines * 21
  if conn.status == "waiting" or conn.status == "offline" then
    if self:button("retry2", cx, by, 120, 38, "Retry now", "primary") then conn.manual_off = nil; conn:retry_now() end
  elseif conn.status == "key_replaced" then
    if self:button("relink", cx, by, 170, 38, "Link this device", "primary") then LinkUI.open_receiver(self) end
    if self:button("reimport", cx + 182, by, 150, 38, "Import account", "secondary") then AccountUI.open_import(self) end
  end
end

----------------------------------------------------------------- add / host page
function App:card(x, y, w, h)
  self.P.rect(x, y, w, h, self.T.card, 18)
  self.P.rect_line(x, y, w, h, self.T.line, 18, 1)
end

function App:input(id, x, y, w, placeholder, opts)
  local P, T = self.P, self.T
  local f = P.field(id, opts or {})
  if opts and opts.hide_when_streaming then f:set_secret(self:streamer() and not f:focused()) end
  local focused = f:focused()
  P.rect(x, y, w, 44, T.bg, 10)
  P.rect_line(x, y, w, 44, focused and T.accent or T.input, 10, focused and 2 or 1)
  local font = self:font("regular", 15)
  f:layout(x + 12, y + 22 - P.line_height(font) / 2, w - 24, font, T.text, T.faint, placeholder)
  self.ui:hit(id .. ":hit", x, y, w, 44, { cursor = "ibeam" })
  f:draw()
  return f
end

function App:draw_add_page(x, y, w, h)
  local P, T, ui, ctl = self.P, self.T, self.ui, self.ctl
  local two = w >= 980
  local cw = two and 440 or math.min(480, w - 48)
  local total_w = two and (cw * 2 + 24) or cw
  local cx = x + (w - total_w) / 2
  local cy = y + math.max(32, (h - 420) / 2 - 20)
  local name_field
  if #ctl.servers == 0 then
    cy = math.max(y + 24, cy - 50)
    P.text("Welcome to Zuno", cx, cy - 4, self:font("head_bold", 28), T.text)
    P.text("Join a friend's server, or host your own.", cx, cy + 34, self:font("regular", 15), T.muted)
    -- returning users
    local lf = self:font("semibold", 14)
    local l1, l2 = "Import account file", "Link this device"
    local w2 = P.measure(lf, l2)
    local w1 = P.measure(lf, l1)
    local rx = cx + total_w
    local q = "Already use Zuno?"
    local qf = self:font("regular", 14)
    local lx2 = rx - w2
    local lx1 = lx2 - 22 - w1
    P.text(q, lx1 - 10 - P.measure(qf, q), cy + 34, qf, T.muted)
    local s1 = ui:hit("welcome:import", lx1, cy + 30, w1, 26)
    P.text(l1, lx1, cy + 34, lf, s1.hovered and T.accent_hover or T.accent)
    P.text("·", lx2 - 14, cy + 34, qf, T.faint)
    local s2 = ui:hit("welcome:link", lx2, cy + 30, w2, 26)
    P.text(l2, lx2, cy + 34, lf, s2.hovered and T.accent_hover or T.accent)
    if s1.clicked then AccountUI.open_import(self) end
    if s2.clicked then LinkUI.open_receiver(self) end
    cy = cy + 76
    if not ctl.settings.name or self.welcome_name then
      self.welcome_name = true
      P.text("Your name", cx, cy, self:font("semibold", 13), T.text)
      name_field = self:input("welcome:name", cx, cy + 22, math.min(360, cw), "What should people call you?", { max_chars = 32 })
      if not self.welcome_name_init then
        self.welcome_name_init = true
        if ctl.settings.name then name_field:set(ctl.settings.name) end
        name_field:focus()
      end
      P.text("You can change it later in Settings.", cx + math.min(360, cw) + 16, cy + 44 - P.line_height(self:font("regular", 13)) / 2, self:font("regular", 13), T.faint)
      cy = cy + 90
    end
  end
  -- Save the welcome name (if typed) before joining or hosting.
  local function save_welcome_name()
    if name_field and name_field:get():find("%S") then
      local ok, err = ctl:set_name(name_field:get())
      if not ok then self.add_error = err; return false end
    end
    return true
  end

  -- join card
  local jh = 270
  self:card(cx, cy, cw, jh)
  P.text("Join a server", cx + 28, cy + 26, self:font("head_bold", 22), T.text)
  P.text("Paste the address the server owner gave you.", cx + 28, cy + 60, self:font("regular", 14), T.muted)
  P.text("Server address", cx + 28, cy + 96, self:font("semibold", 13), T.text)
  local addr = self:input("add:address", cx + 28, cy + 118, cw - 56, "my-server.at.ply.gg:41234", { hide_when_streaming = true })
  local function join()
    if not save_welcome_name() then return end
    local i, err = ctl:add_server(addr:get())
    if i then addr:set(""); self.add_error = nil; self.page = nil; addr:blur() else self.add_error = err end
  end
  addr.on_submit = join
  addr.on_change = function() self.add_error = nil end
  if self.add_error then
    ui:text_fit(self.add_error, cx + 28, cy + 170, cw - 56, self:font("regular", 13), T.danger)
  end
  if self:button("join", cx + 28, cy + jh - 66, cw - 56, 42, "Join", "primary", { disabled = addr:get():find("%S") == nil }) then join() end

  -- host card
  local hx, hy = cx, cy + jh + 24
  if two then hx, hy = cx + cw + 24, cy end
  self:card(hx, hy, cw, jh)
  P.text("Host a server", hx + 28, hy + 26, self:font("head_bold", 22), T.text)
  if not ctl:can_host() then
    P.text("Hosting isn't available here.", hx + 28, hy + 60, self:font("regular", 14), T.muted)
    return
  end
  local hs = ctl:host_status()
  if hs.running then
    P.circle(hx + 34, hy + 70, 5, T.online)
    P.text(("Running on port %d"):format(hs.port or ctl.settings.host_port), hx + 48, hy + 60, self:font("semibold", 14), T.text)
    local lines = self:wrap(self:font("regular", 13),
      "Friends can join once you share it: create a TCP tunnel in playit.gg pointing at this port, then send them the tunnel address. It stays online while Zuno is open.", cw - 56)
    for i, l in ipairs(lines) do P.text(l, hx + 28, hy + 92 + (i - 1) * 20, self:font("regular", 13), T.muted) end
    if self:button("openhosted", hx + 28, hy + jh - 66, (cw - 66) / 2, 42, "Open it", "primary") then
      local i = ctl:hosting_ready(hs.port); if i then self.page = nil end
    end
    if self:button("stophost", hx + 38 + (cw - 66) / 2, hy + jh - 66, (cw - 66) / 2, 42, "Stop server", "secondary") then
      self:confirm("Stop your server?", "People connected to it will be disconnected.", "Stop", function() ctl:stop_hosting() end, true)
    end
    return
  end
  P.text("Runs on this computer while Zuno is open.", hx + 28, hy + 60, self:font("regular", 14), T.muted)
  P.text("Server name", hx + 28, hy + 96, self:font("semibold", 13), T.text)
  P.text("Port", hx + cw - 28 - 110, hy + 96, self:font("semibold", 13), T.text)
  local who = (name_field and name_field:get():find("%S")) and name_field:get():gsub("^%s+", ""):gsub("%s+$", "") or ctl:display_name()
  local hn = self:input("host:name", hx + 28, hy + 118, cw - 56 - 124, who .. "'s server")
  local hp = self:input("host:port", hx + cw - 28 - 110, hy + 118, 110, "41234")
  if not self.host_init then
    self.host_init = true
    if ctl.settings.host_name then hn:set(ctl.settings.host_name) end
    hp:set(tostring(ctl.settings.host_port))
  end
  if self.host_error or hs.error then
    ui:text_fit(self.host_error or hs.error, hx + 28, hy + 170, cw - 56, self:font("regular", 13), T.danger)
  end
  local function start()
    if not save_welcome_name() then return end
    local ok, err = ctl:start_hosting(hn:get(), hp:get())
    self.host_error = (not ok) and err or nil
  end
  hn.on_submit, hp.on_submit = start, start
  if self:button("starthost", hx + 28, hy + jh - 66, cw - 56, 42, hs.starting and "Starting…" or "Start server", "primary", { disabled = hs.starting }) then start() end
end

----------------------------------------------------------------- settings
function App:draw_settings(w, h)
  local P, T, ui, ctl = self.P, self.T, self.ui, self.ctl
  local scrim = ui:hit("settings:scrim", 0, 0, w, h, { block = true, cursor = false })
  P.rect(0, 0, w, h, T.scrim)
  if scrim.clicked then self.settings_open = false; return end
  local card_w, ch = math.min(780, w - 32), math.min(h - 32, 560)
  local card_x, cy = (w - card_w) / 2, math.max(16, (h - ch) / 2)
  ui:hit("settings:card", card_x, cy, card_w, ch, { block = true, cursor = false })
  self:card(card_x, cy, card_w, ch)
  P.text("Settings", card_x + 28, cy + 24, self:font("head_bold", 22), T.text)
  if self:icon_button("settings:close", "close", card_x + card_w - 52, cy + 20, 32, "Close") then self.settings_open = false end

  -- sections on the left, the chosen one on the right
  local side_w = 190
  local tabs = { { "general", "General" }, { "notify", "Notifications" }, { "account", "Your account" } }
  self.settings_tab = self.settings_tab or "general"
  for i, t in ipairs(tabs) do
    local by = cy + 76 + (i - 1) * 42
    local sel = self.settings_tab == t[1]
    local st = ui:hit("settings:tab:" .. t[1], card_x + 16, by, side_w - 24, 36)
    if sel then P.rect(card_x + 16, by, side_w - 24, 36, T.sunken, 8) elseif st.hovered then P.rect(card_x + 16, by, side_w - 24, 36, T.hover, 8) end
    local f = self:font(sel and "semibold" or "medium", 14)
    P.text(t[2], card_x + 30, by + 18 - P.line_height(f) / 2, f, sel and T.text or T.soft)
    if st.clicked then self.settings_tab = t[1] end
  end
  P.text("Zuno " .. version.APP, card_x + 30, cy + ch - 34, self:font("regular", 12), T.faint)
  P.rect(card_x + side_w, cy + 70, 1, ch - 90, T.line)
  local cx, cw = card_x + side_w - 6, card_w - side_w + 6 -- content: x from cx + 28, width cw - 56
  local tab = self.settings_tab

  local y = cy + 76
  if tab == "general" then
  P.text("Display name", cx + 28, y, self:font("semibold", 13), T.text)
  local nf = self:input("settings:name", cx + 28, y + 22, cw - 56 - 96, "Your name")
  if not self.settings_init then self.settings_init = true; nf:set(ctl.settings.name or "") end
  local function save_name()
    local ok, err = ctl:set_name(nf:get())
    if ok then ctl:toast("Name saved") else self.name_error = err end
  end
  nf.on_submit = save_name
  nf.on_change = function() self.name_error = nil end
  if self:button("settings:savename", cx + cw - 28 - 86, y + 22, 86, 44, "Save", "primary") then save_name() end
  if self.name_error then P.text(self.name_error, cx + 28, y + 72, self:font("regular", 13), T.danger) end

  y = y + 104
  P.text("Theme", cx + 28, y, self:font("semibold", 13), T.text)
  local opts = { { "light", "Light" }, { "dark", "Dark" }, { "system", "System" } }
  local sw = (cw - 56) / 3
  P.rect(cx + 28, y + 22, cw - 56, 40, T.sunken, 10)
  for i, o in ipairs(opts) do
    local bx = cx + 28 + (i - 1) * sw
    local sel = ctl.settings.theme == o[1]
    local st = ui:hit("theme:" .. o[1], bx, y + 22, sw, 40)
    if sel then P.rect(bx + 3, y + 25, sw - 6, 34, T.card, 8) end
    local f = self:font(sel and "semibold" or "medium", 14)
    P.text(o[2], bx + (sw - P.measure(f, o[2])) / 2, y + 42 - P.line_height(f) / 2, f, sel and T.text or T.soft)
    if st.clicked then ctl:set_theme(o[1]) end
  end

  y = y + 78
  P.text("Streamer mode", cx + 28, y, self:font("semibold", 13), T.text)
  P.text("Hides addresses, keys and codes", cx + 150, y + 1, self:font("regular", 12), T.faint)
  local sopts = { { "off", "Off" }, { "auto", "Auto" }, { "on", "On" } }
  P.rect(cx + 28, y + 22, cw - 56, 40, T.sunken, 10)
  for i, o in ipairs(sopts) do
    local bx = cx + 28 + (i - 1) * sw
    local sel = (ctl.settings.streamer or "auto") == o[1]
    local tip = o[1] == "auto" and "On while OBS or Streamlabs is running" or nil
    local st = ui:hit("streamer:" .. o[1], bx, y + 22, sw, 40, { tip = tip })
    if sel then P.rect(bx + 3, y + 25, sw - 6, 34, T.card, 8) end
    local f = self:font(sel and "semibold" or "medium", 14)
    local label = o[2]
    if o[1] == "auto" and sel and self:streamer() then label = "Auto · on now" end
    P.text(label, bx + (sw - P.measure(f, label)) / 2, y + 42 - P.line_height(f) / 2, f, sel and T.text or T.soft)
    if st.clicked then ctl:set_streamer(o[1]) end
  end

  y = y + 78
  P.text("Profile picture", cx + 28, y, self:font("semibold", 13), T.text)
  P.text("Shown on all your servers", cx + 150, y + 1, self:font("regular", 12), T.faint)
  local local_png = ctl:avatar_data()
  local preview = local_png and P.image_from_data and P.image_from_data("my-avatar:" .. (ctl.settings.avatar_hash or ""), local_png)
  if preview then FilesUI.draw_fit(P, preview, cx + 28, y + 24, 56, 56, true, 28)
  else self:avatar(ctl.key, ctl:display_name(), cx + 28, y + 24, 56, nil) end
  if self:button("settings:avatar", cx + 100, y + 36, 120, 34, ctl.settings.avatar_hash and "Change…" or "Choose…", "secondary") then
    P.pick_file("Image", nil, function(data, path)
      if not data then
        if path ~= "cancelled" then ctl:toast(path == "unavailable" and "No file dialog here." or tostring(path), "error") end
        return
      end
      local png = P.square_png and P.square_png(data, 256)
      if not png then ctl:toast("That isn't a picture Zuno can read (PNG, JPEG, BMP).", "error"); return end
      ctl:set_avatar(png)
      ctl:toast("Profile picture updated")
    end)
  end
  if ctl.settings.avatar_hash and self:button("settings:avatar_rm", cx + 230, y + 36, 100, 34, "Remove", "ghost") then
    ctl:set_avatar(nil)
  end
  end -- general

  if tab == "notify" then
    P.text("Notify me about", cx + 28, y, self:font("semibold", 13), T.text)
    local nopts = { { "all", "All messages" }, { "mentions", "Mentions & replies" }, { "off", "Nothing" } }
    local nw = (cw - 56) / 3
    P.rect(cx + 28, y + 22, cw - 56, 40, T.sunken, 10)
    for i, o in ipairs(nopts) do
      local bx = cx + 28 + (i - 1) * nw
      local sel = ctl.settings.notify == o[1]
      local st = ui:hit("notify:" .. o[1], bx, y + 22, nw, 40)
      if sel then P.rect(bx + 3, y + 25, nw - 6, 34, T.card, 8) end
      local f = self:font(sel and "semibold" or "medium", 14)
      P.text(o[2], bx + (nw - P.measure(f, o[2])) / 2, y + 42 - P.line_height(f) / 2, f, sel and T.text or T.soft)
      if st.clicked then ctl:set_notify(o[1]) end
    end
    local ny = AccountUI.paragraph(self, "While Zuno is open, you get a notification when a message arrives that you aren't looking at. "
      .. "Zuno can't notify you while it's closed yet.", cx + 28, y + 76, cw - 56, T.muted, 13)
    y = ny + 18
    local on = ctl.settings.sound
    local st = ui:hit("settings:sound", cx + 28, y, 260, 26)
    P.rect(cx + 28, y + 2, 22, 22, on and T.accent or T.card, 6)
    if not on then P.rect_line(cx + 28, y + 2, 22, 22, st.hovered and T.text or T.input, 6, 1.5) end
    if on then Icons.draw(P, "check", cx + 30, y + 4, 18, T.on_accent, 2.2) end
    P.text("Play a sound", cx + 60, y + 13 - P.line_height(self:font("medium", 14)) / 2, self:font("medium", 14), T.text)
    if st.clicked then ctl:set_sound(not on) end
    if self:button("settings:testnotify", cx + 28, y + 46, 170, 38, "Send a test", "secondary") then
      ctl:test_notification()
    end
  end

  if tab == "account" then
  P.text("Your account", cx + 28, y, self:font("semibold", 13), T.text)
  local lines = self:wrap(self:font("regular", 13), "Your account is a key on this device: no password, no central account. Back it up so you can restore it, or link your other devices.", cw - 56)
  for i, l in ipairs(lines) do P.text(l, cx + 28, y + 22 + (i - 1) * 19, self:font("regular", 13), T.muted) end
  local fy = y + 30 + #lines * 19
  P.rect(cx + 28, fy, cw - 56, 40, T.sunken, 8)
  if self:secret(ctl.key, "settings:key", cx + 28, fy, cw - 56 - 84, 40) then
    P.text(P_.fingerprint(ctl.key), cx + 40, fy + 20 - P.line_height(self:font("head", 14)) / 2, self:font("head", 14), T.text)
  end
  if self:button("settings:copykey", cx + cw - 28 - 76, fy + 5, 70, 30, "Copy", "secondary", { radius = 7 }) then
    P.set_clipboard(ctl.key); ctl:toast("Full key copied")
  end
  local by = fy + 54
  local bw3 = (cw - 56 - 20) / 3
  if self:button("settings:export", cx + 28, by, bw3, 40, "Back up…", "secondary") then AccountUI.open_export(self) end
  if self:button("settings:import", cx + 28 + bw3 + 10, by, bw3, 40, "Import…", "secondary") then AccountUI.open_import(self) end
  if self:button("settings:link", cx + 28 + 2 * (bw3 + 10), by, bw3, 40, "Link a device…", "secondary") then
    LinkUI.open_sender(self)
  end
  -- lost device
  local lf = self:font("medium", 13)
  local q = "Lost a device or worried someone copied your key?"
  P.text(q, cx + 28, by + 58, self:font("regular", 13), T.muted)
  local lx = cx + 28 + P.measure(self:font("regular", 13), q) + 8
  local rl = "Replace my key"
  local rs = ui:hit("settings:rekey", lx, by + 54, P.measure(lf, rl), 24)
  P.text(rl, lx, by + 58, lf, rs.hovered and T.accent_hover or T.accent)
  if rs.clicked then
    self.settings_open = false
    local n = #ctl.servers
    self:confirm("Replace your key?",
      "You get a new identity key. Your servers move your membership, role and messages to it, and the old key stops working everywhere, " ..
      "including on your other devices (link them again afterwards). Servers you're not connected to get the change next time you connect" ..
      (n == 0 and "." or (". You have " .. n .. " server" .. (n == 1 and "" or "s") .. "."))
      .. " Back up your account again afterwards.", "Replace key",
      function() ctl:replace_key(); ctl:toast("New key made. Moving your account on your servers…") end, true)
  end
  if ctl.old_seed then
    P.text(("Moving to your new key: %d server%s still to go."):format(ctl:rekey_pending_count(), ctl:rekey_pending_count() == 1 and "" or "s"),
      cx + 28, by + 82, self:font("medium", 12), T.idle)
  end
  end -- account
end

----------------------------------------------------------------- dialogs, menus, toasts
function App:draw_dialog(w, h)
  local P, T, ui = self.P, self.T, self.ui
  local d = self.dialog
  local scrim = ui:hit("dialog:scrim", 0, 0, w, h, { block = true, cursor = false })
  P.rect(0, 0, w, h, T.scrim)
  if scrim.clicked then self.dialog = nil; return end
  local cw = math.min(420, w - 40)
  local f = self:font("regular", 14)
  local lines = self:wrap(f, d.text or "", cw - 56)
  local ch = 140 + #lines * 21
  local cx, cy = (w - cw) / 2, (h - ch) / 2
  ui:hit("dialog:card", cx, cy, cw, ch, { block = true, cursor = false })
  self:card(cx, cy, cw, ch)
  P.text(d.title, cx + 28, cy + 24, self:font("head_bold", 19), T.text)
  for i, l in ipairs(lines) do P.text(l, cx + 28, cy + 60 + (i - 1) * 21, f, T.muted) end
  local by = cy + ch - 62
  if self:button("dialog:ok", cx + cw - 28 - 120, by, 120, 40, d.ok or "OK", d.danger and "danger" or "primary") or ui:pressed("return") then
    self.dialog = nil
    d.fn()
    return
  end
  if self:button("dialog:cancel", cx + cw - 28 - 120 - 12 - 100, by, 100, 40, "Cancel", "secondary") then self.dialog = nil end
end

function App:draw_menu(w, h)
  local P, T, ui = self.P, self.T, self.ui
  local m = self.menu
  local f = self:font("medium", 14)
  local mw = 40
  for _, it in ipairs(m.items) do mw = math.max(mw, P.measure(f, it.label) + 32) end
  local mh = #m.items * 34 + 8
  local x, y = math.min(m.x, w - mw - 8), math.min(m.y, h - mh - 8)
  local outside = ui:hit("menu:outside", 0, 0, w, h, { block = true, cursor = false })
  if outside.clicked or outside.rclicked then self.menu = nil; return end
  ui:hit("menu:card", x, y, mw, mh, { block = true, cursor = false })
  P.rect(x + 2, y + 4, mw, mh, { 0, 0, 0, 0.12 }, 10)
  P.rect(x, y, mw, mh, T.card, 10)
  P.rect_line(x, y, mw, mh, T.line, 10, 1)
  for i, it in ipairs(m.items) do
    local iy = y + 4 + (i - 1) * 34
    local st = ui:hit("menu:" .. i, x + 4, iy, mw - 8, 34)
    if st.hovered then P.rect(x + 4, iy, mw - 8, 34, T.hover, 7) end
    P.text(it.label, x + 16, iy + 17 - P.line_height(f) / 2, f, it.danger and T.danger or T.text)
    if st.clicked then self.menu = nil; it.fn(); return end
  end
end

function App:draw_toasts(w, h)
  local P, T = self.P, self.T
  local f = self:font("medium", 13)
  local y = h - 96 -- above the composer
  for i = #self.ctl.toasts, 1, -1 do
    local t = self.ctl.toasts[i]
    local lines = self:wrap(f, t.text, 320)
    local th = #lines * 19 + 20
    local tw = 0
    for _, l in ipairs(lines) do tw = math.max(tw, P.measure(f, l)) end
    tw = tw + 32
    y = y - th
    local x = w - 20 - tw
    P.rect(x, y, tw, th, T.sel_bg, 10)
    if t.kind == "error" then P.rect(x + 6, y + 8, 3, th - 16, T.danger, 2) end
    for j, l in ipairs(lines) do P.text(l, x + 16, y + 10 + (j - 1) * 19, f, T.sel_fg) end
    y = y - 10
  end
end

return App
