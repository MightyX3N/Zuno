-- Zuno client UI: the Tabs layout (desktop variant), drawn through the platform API.
local Theme = require("zuno_ui.theme")
local Icons = require("zuno_ui.icons")
local P_ = require("zuno.packets")
local version = require("zuno.version")
local AccountUI = require("zuno_ui.account_ui")
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

function App:avatar(key, name, x, y, size)
  local T = self.T
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
  if self.dialog then self:draw_dialog(w, h) end
  if self.menu then self:draw_menu(w, h) end
  self:draw_toasts(w, h)
  ui:draw_tooltip(T, self:font("medium", 12))
  if self.job then AccountUI.draw_job(self, w, h); self.job.shown = true end

  -- global keys
  if ui:pressed("escape") then
    if self.menu then self.menu = nil
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
    local unread = 0
    for _, n in pairs(conn.unread) do unread = unread + n end
    local cnt = unread > 0 and tostring(unread) or ""
    local tw = math.min(180, P.measure(f, name))
    local cw = cnt ~= "" and (P.measure(self:font("regular", 12), cnt) + 8) or 0
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
    if cnt ~= "" then P.text(cnt, x + 48 + tw + 8, 31 - P.line_height(self:font("regular", 12)) / 2, self:font("regular", 12), T.faint) end
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
    if unread and not sel then
      local s = unread > 99 and "99+" or tostring(unread)
      local bf = self:font("semibold", 12)
      local bw = P.measure(bf, s) + 14
      P.rect(cx + w - 28 - bw - 8, cy + 8, bw, 18, T.accent, 9)
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
  self:avatar(self.ctl.key, me_name, cx + 10, my + 10, 32)
  ui:text_fit(me_name, cx + 52, my + 9, w - 28 - 62, self:font("semibold", 14), T.text)
  local status_text, status_color = "Online", T.voice
  if conn.status ~= "online" then status_text, status_color = "Offline", T.faint end
  if conn:is_owner() then status_text = status_text .. " · Owner" end
  P.text(status_text, cx + 52, my + 28, self:font("regular", 12), status_color)
  if st.clicked then self.settings_open = true end
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
      P.circle(cx + 4, cy + 10, 4, m.online and T.online or T.line)
      local col = m.online and T.text or T.faint
      local role = m.role == "owner" and "Owner" or ""
      self.ui:text_fit(m.name, cx + 18, cy + 10 - P.line_height(f) / 2, iw - 18 - (role ~= "" and 50 or 0), f, col)
      if role ~= "" then
        local rf = self:font("regular", 12)
        P.text(role, cx + iw - P.measure(rf, role), cy + 10 - P.line_height(rf) / 2, rf, T.faint)
      end
      cy = cy + 27
    end
  end
  self.ui:unclip()
end

----------------------------------------------------------------- chat
function App:message_layout(conn, v, ch, width)
  local P = self.P
  local s = conn:store_for(ch)
  local body_f = self:font("regular", 14)
  local lh = math.floor(P.line_height(body_f) * 1.5 + 0.5)
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
    local header = not prev or prev.a ~= m.a or (m.at - prev.at) > GROUP_GAP or pending ~= prev.pending
    local lines = self:wrap(body_f, m.body, text_w)
    local h = #lines * lh + (header and (14 + 23) or 6)
    add({ kind = "msg", m = m, h = h, lines = lines, header = header, lh = lh, pending = pending })
    prev = { a = m.a, at = m.at, day = day, pending = pending }
  end
  for _, m in ipairs(s.list) do add_msg(m) end
  for _, pm in ipairs(conn:pending_for(ch)) do
    add_msg({ id = -1, a = pm.a or self.ctl.key, at = math.floor(pm.at * 1000), body = pm.body, nonce = pm.nonce, state = pm.state, error = pm.error }, true)
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
  local field = ch and P.field("composer:" .. entry.address .. ":" .. ch.id, { multiline = true, max_chars = P_.LIMITS.message_chars })
  local comp_inner_w = w - 56 - 28 - 44 - 80
  local fh = field and math.max(20, math.min(160, field:height(comp_inner_w))) or 20
  local comp_h = fh + 24
  local edit_bar = v.editing and 30 or 0
  local typing_h = 22
  local comp_y = y + h - 20 - comp_h
  local list_bottom = comp_y - edit_bar - typing_h
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
  end
  -- composer box
  local cx, cw = x + 28, w - 56
  local focused = field:focused()
  P.rect(cx, comp_y, cw, comp_h, T.card, 14)
  P.rect_line(cx, comp_y, cw, comp_h, focused and T.faint or T.input, 14, 1)
  local attach = ui:hit("attach", cx + 10, comp_y + comp_h / 2 - 15, 30, 30, { tip = "File sharing arrives in a later update", cursor = false })
  Icons.draw(P, "plus", cx + 16, comp_y + comp_h / 2 - 9, 18, attach.hovered and T.soft or T.faint)
  local ph = conn.status == "online" and ("Message " .. ch.name) or "Waiting for the connection…"
  field:layout(cx + 48, comp_y + 12, comp_inner_w, self:font("regular", 14), T.text, T.faint, ph)
  ui:hit("composer_field", cx + 44, comp_y, comp_inner_w + 8, comp_h, { cursor = "ibeam" })
  field:draw()
  local can_send = field:get():find("%S") ~= nil and conn.status == "online"
  if self:button("send", cx + cw - 82, comp_y + comp_h - 44 + 6, 72, 32, v.editing and "Save" or "Send", "primary", { disabled = not can_send }) then
    self:submit(conn, entry, v, ch, field)
  end

  field.on_submit = function() self:submit(conn, entry, v, ch, field) end
  field.on_change = function(text) if text ~= "" and not text:find("^/") and not v.editing then conn:typed(ch.id) end end
  field.on_key = function(key)
    if key == "up" and field:get() == "" then
      -- edit my last message
      local list = conn:store_for(ch.id).list
      for i = #list, 1, -1 do
        if list[i].a == self.ctl.key then
          v.editing = list[i].id; field:set(list[i].body); return true
        end
      end
    elseif key == "escape" and v.editing then
      v.editing = nil; field:set(""); return true
    end
    return false
  end
end

function App:submit(conn, entry, v, ch, field)
  local text = field:get()
  if not text:find("%S") then return end
  if conn.status ~= "online" then self.ctl:toast("Not connected yet.", "error"); return end
  if v.editing then
    conn:edit_message(v.editing, text)
    v.editing = nil
  elseif text:find("^/%a") then
    conn:command(ch.id, text)
  else
    if not conn:send_message(ch.id, text) then return end
    v.new_marker = nil
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

function App:draw_message(conn, entry, v, ch, it, idx, x, y, w, body_f, name_f, time_f)
  local P, T, ui = self.P, self.T, self.ui
  local m = it.m
  local id = "msg:" .. (m.id > 0 and m.id or (m.nonce or idx))
  local st = ui:hit(id, x - 10, y, w + 20, it.h, { cursor = false })
  -- hovering this message's own toolbar counts as hovering the message
  if not st.hovered and ui.hover_id and ui.hover_id:sub(1, #id + 1) == id .. ":" then st.hovered = true end
  local mine = m.a == self.ctl.key
  if st.hovered or (v.editing == m.id) then P.rect(x - 10, y, w + 20, it.h, T.hover, 8) end
  local alpha = it.pending and 0.55 or 1
  local top = y + (it.header and 14 or 3)
  if it.header then
    P.text(fmt_time(m.at), x, top + 3, time_f, T.faint)
    local nm = conn:member_name(m.a)
    P.text(nm, x + 70, top, name_f, Theme.alpha(Theme.pick(T.names, m.a), alpha))
    top = top + 23
  elseif st.hovered then
    P.text(fmt_time(m.at), x, top + 3, self:font("regular", 11), T.faint)
  end
  local col = Theme.alpha(T.text, alpha)
  for i, line in ipairs(it.lines) do
    P.text(line, x + 70, top + (i - 1) * it.lh + (it.lh - P.line_height(body_f)) / 2, body_f, col)
  end
  local last_line = it.lines[#it.lines] or ""
  local after_x = x + 70 + P.measure(body_f, last_line) + 6
  local after_y = top + (#it.lines - 1) * it.lh + (it.lh - P.line_height(time_f)) / 2
  if m.edited then P.text("(edited)", after_x, after_y, time_f, T.faint) end
  if it.pending then
    if m.state == "failed" then
      P.text("Not sent" .. (m.error and (": " .. m.error) or ""), after_x, after_y, time_f, T.danger)
      if st.hovered or true then
        local bx = x + w - 130
        if self:button(id .. ":retry", bx, y + 4, 60, 24, "Retry", "secondary", { radius = 6, font = self:font("medium", 12) }) then
          conn:drop_pending(m.nonce); conn:send_message(ch.id, m.body)
        end
        if self:button(id .. ":drop", bx + 66, y + 4, 64, 24, "Discard", "secondary", { radius = 6, font = self:font("medium", 12) }) then
          conn:drop_pending(m.nonce)
        end
      end
    else
      P.text("Sending…", after_x, after_y, time_f, T.faint)
    end
    return
  end

  local can_delete = mine or conn:is_owner()
  local actions = { { "copy", "Copy text", function() P.set_clipboard(m.body); self.ctl:toast("Copied") end } }
  if mine then
    actions[#actions + 1] = { "edit", "Edit", function()
      v.editing = m.id
      local f = P.field("composer:" .. entry.address .. ":" .. ch.id, { multiline = true })
      f:set(m.body); f:focus()
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
      if self:icon_button(id .. ":" .. a[1], a[1], bx + 3 + (i - 1) * 30, by + 2, 28, a[2]) then a[3]() end
    end
  end
  if st.rclicked then
    local items = {}
    for _, a in ipairs(actions) do items[#items + 1] = { label = a[2], fn = a[3], danger = a[1] == "trash" } end
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
  local cw, ch = math.min(560, w - 32), math.min(h - 32, 600)
  local cx, cy = (w - cw) / 2, math.max(20, (h - ch) / 2)
  ui:hit("settings:card", cx, cy, cw, ch, { block = true, cursor = false })
  self:card(cx, cy, cw, ch)
  P.text("Settings", cx + 28, cy + 24, self:font("head_bold", 22), T.text)
  if self:icon_button("settings:close", "close", cx + cw - 52, cy + 20, 32, "Close") then self.settings_open = false end

  local y = cy + 76
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
  P.text("Zuno " .. version.APP, cx + 28, cy + ch - 30, self:font("regular", 12), T.faint)
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
