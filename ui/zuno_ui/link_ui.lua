-- Device linking dialogs. Old device: "Link a device". New device: "Link this device".
local L = require("zuno_ui.link")
local QR = require("zuno_ui.qr")
local AccountUI = require("zuno_ui.account_ui")
local Icons = require("zuno_ui.icons")

local M = {}

local function draw_qr(app, text, x, y, size)
  local P = app.P
  local key = text .. size
  if app.qr_cache_key ~= key then
    app.qr_cache_key = key
    app.qr_cache = { QR.encode(text) }
  end
  local m, n = app.qr_cache[1], app.qr_cache[2]
  P.rect(x, y, size, size, { 1, 1, 1, 1 }, 12)
  if not m then return end
  local quiet = 3
  local cell = math.floor((size - 8) / (n + 2 * quiet))
  local ox = x + math.floor((size - cell * n) / 2)
  local oy = y + math.floor((size - cell * n) / 2)
  local black = { 0.06, 0.06, 0.07, 1 }
  for yy = 0, n - 1 do
    local row = m[yy]
    local run_start
    for xx = 0, n do
      local dark = xx < n and row[xx]
      if dark and not run_start then run_start = xx end
      if not dark and run_start then
        P.rect(ox + run_start * cell, oy + yy * cell, (xx - run_start) * cell, cell, black)
        run_start = nil
      end
    end
  end
end

local function fmt_time(s) return ("%d:%02d"):format(math.floor(s / 60), s % 60) end

------------------------------------------------------------------ old device
function M.open_sender(app)
  app.P.blur_all()
  local ctl = app.ctl
  app.settings_open = false
  local entry
  local active = ctl.servers[ctl.active]
  if active and ctl.conns[active] and ctl.conns[active].status == "online" then entry = active end
  if not entry then
    for _, e in ipairs(ctl.servers) do if ctl.conns[e].status == "online" then entry = e; break end end
  end
  if not entry then
    ctl:toast("Connect to one of your servers first: linking goes through a server.", "error")
    return
  end
  local conn = ctl.conns[entry]
  local addr = entry.address:gsub("#.*$", "")
  local local_only = addr:find("^127%.") or addr:find("^localhost") or addr:find("^%[::1%]")
  local m = { kind = "link_send", entry = entry, local_only = local_only }
  m.sender = L.sender(ctl.env.crypto, conn, addr, function() return ctl:account() end)
  m.draw = M.draw_sender
  app.modal = m
  local f = app.P.field("link:addr", {})
  f:set(local_only and "" or addr)
  app.P.field("link:code", { max_chars = 12 }):set("")
end

function M.draw_sender(app, w, h)
  local P, T, m = app.P, app.T, app.modal
  local s = m.sender
  s:update()
  local cw, ch = math.min(640, w - 32), 470
  local cx, cy = AccountUI.frame(app, w, h, cw, ch, true)
  if not cx then s:cancel(); return end
  local x, iw = cx + 28, cw - 56
  P.text("Link a device", x, cy + 24, app:font("head_bold", 22), T.text)

  if s.state == "failed" then
    AccountUI.paragraph(app, s.error or "The link was cancelled.", x, cy + 80, iw, T.danger)
    if app:button("link:retry", cx + cw - 28 - 130, cy + ch - 66, 130, 42, "Start again", "primary") then
      M.open_sender(app)
    end
    return
  end
  if s.state == "done" then
    Icons.draw(P, "check", x, cy + 78, 26, T.ok, 2.4)
    P.text("Linked", x + 36, cy + 76, app:font("head_bold", 20), T.text)
    AccountUI.paragraph(app, "The other device now has your account, servers and settings. It connects to your servers by itself.", x, cy + 116, iw)
    if app:button("link:done", cx + cw - 28 - 110, cy + ch - 66, 110, 42, "Done", "primary") then app.modal = nil end
    return
  end
  if s.state == "code" or s.state == "sending" then
    local y = AccountUI.paragraph(app, "The new device shows a 6-digit code. Type it here so only that device gets your account.", x, cy + 76, iw)
    local f = app:input("link:code", x, y + 16, 220, "000 000", { max_chars = 12 })
    if not m.code_focused then m.code_focused = true; f:focus() end
    local function confirm()
      if s:enter_code(f:get()) then m.wrong = nil
      elseif s.state == "code" then m.wrong = ("That's not the code. %d tr%s left."):format(L.MAX_TRIES - s.tries, L.MAX_TRIES - s.tries == 1 and "y" or "ies") end
      f:set("")
    end
    f.on_submit = confirm
    if m.wrong then P.text(m.wrong, x, y + 72, app:font("regular", 13), T.danger) end
    if s.state == "sending" then P.text("Sending your account…", x, y + 72, app:font("medium", 13), T.muted) end
    if app:button("link:confirm", cx + cw - 28 - 130, cy + ch - 66, 130, 42, "Confirm", "primary",
        { disabled = s.state ~= "code" or not f:get():find("%d") }) then confirm() end
    return
  end

  -- waiting / opening / joined: show the QR and the code
  local qr_size = 220
  local text_x = x + qr_size + 28
  local tw = cx + cw - 28 - text_x
  local addr_field = P.field("link:addr", {})
  local addr = addr_field:get()
  if s.sid and addr:find("%S") then
    if app:secret("qr", "link:qr", x, cy + 76, qr_size, qr_size) then
      draw_qr(app, L.make_url(addr, s.sid, s.A), x, cy + 76, qr_size)
    else
      P.rect(x, cy + 76, qr_size, qr_size, T.sunken, 12)
      app:secret("qr", "link:qr", x, cy + 76, qr_size, qr_size)
    end
  else
    P.rect(x, cy + 76, qr_size, qr_size, T.sunken, 12)
    local note = s.sid and "Fill in the address" or "Getting a code…"
    local f = app:font("medium", 13)
    P.text(note, x + (qr_size - P.measure(f, note)) / 2, cy + 76 + qr_size / 2 - 8, f, T.muted)
  end
  local y = AccountUI.paragraph(app, "On the new device, open Zuno and choose “Link this device”. Scan the code, or type:", text_x, cy + 76, tw, T.muted, 13)
  P.text("Server address", text_x, y + 8, app:font("semibold", 12), T.text)
  app:input("link:addr", text_x, y + 26, tw, "your-server.at.ply.gg:41234", { hide_when_streaming = true })
  if m.local_only then
    y = AccountUI.paragraph(app, "This is your own server: give the address other devices use (your playit address).", text_x, y + 76, tw, T.faint, 12) - 76
  end
  P.text("Link code", text_x, y + 84, app:font("semibold", 12), T.text)
  if s.sid then
    if app:secret(s.sid, "link:sid", text_x, y + 100, tw, 44) then
      P.text(s.sid, text_x, y + 100, app:font("head_bold", 30), T.text)
    end
  end
  local status
  if s.state == "joined" then status = "The new device connected. Waiting for it…"
  elseif s.state == "waiting" then status = ("Works once. Expires in %s."):format(fmt_time(s:remaining() or 0))
  else status = "Getting a code from the server…" end
  P.text(status, text_x, y + 152, app:font("regular", 13), T.muted)
  AccountUI.paragraph(app, "Only use this with your own devices. Whoever completes the link gets your whole account.", x, cy + ch - 62, iw - 150, T.faint, 12)
  if app:button("link:cancel", cx + cw - 28 - 110, cy + ch - 66, 110, 42, "Cancel", "secondary") then s:cancel(); app.modal = nil end
end

------------------------------------------------------------------ new device
function M.open_receiver(app)
  app.P.blur_all()
  app.settings_open = false
  app.modal = { kind = "link_recv", draw = M.draw_receiver }
  app.P.field("linkr:addr", {}):set("")
  app.P.field("linkr:code", { max_chars = 12 }):set("")
end

function M.draw_receiver(app, w, h)
  local P, T, ctl, m = app.P, app.T, app.ctl, app.modal
  local r = m.receiver
  if r then r:update() end
  local cw, ch = math.min(560, w - 32), 440
  local cx, cy = AccountUI.frame(app, w, h, cw, ch, true)
  if not cx then if r then r:cancel() end; return end
  local x, iw = cx + 28, cw - 56
  P.text("Link this device", x, cy + 24, app:font("head_bold", 22), T.text)

  if r and r.state == "done" then
    if not m.applied then
      m.applied = true
      ctl:replace_account(r.account)
      app.page = #ctl.servers == 0 and "add" or nil
      app.welcome_name = nil
      ctl:toast("This device is linked" .. (r.account.name and (". Welcome, " .. r.account.name) or "") .. ".")
      app.modal = nil
    end
    return
  end
  if r and r.state == "show_code" then
    local y = AccountUI.paragraph(app, "Type this code on your other device:", x, cy + 80, iw)
    local code = r.code:sub(1, 3) .. " " .. r.code:sub(4)
    local shown = app:secret(code, "linkr:code6", x, y + 16, iw, 80)
    if shown then
      local f = app:font("head_bold", 52)
      P.text(code, x + (iw - P.measure(f, code)) / 2, y + 22, f, T.text)
    end
    AccountUI.paragraph(app, "Nothing is sent until the code matches. Waiting for your other device…", x, y + 120, iw, T.muted, 13)
    if app:button("linkr:cancel", cx + cw - 28 - 110, cy + ch - 66, 110, 42, "Cancel", "secondary") then r:cancel(); app.modal = nil end
    return
  end
  if r and r.state ~= "failed" then
    local msg = ({ connecting = "Connecting to the server…", joining = "Joining the link…", waiting = "Connected. Waiting for your other device…" })[r.state] or "Working…"
    AccountUI.paragraph(app, msg, x, cy + 80, iw)
    if app:button("linkr:cancel", cx + cw - 28 - 110, cy + ch - 66, 110, 42, "Cancel", "secondary") then r:cancel(); app.modal = nil end
    return
  end

  -- form
  local y = AccountUI.paragraph(app, "On your other device, open Settings and choose “Link a device”. Type what it shows, or paste the whole link into the first box.", x, cy + 70, iw)
  P.text("Server address", x, y + 10, app:font("semibold", 13), T.text)
  local af = app:input("linkr:addr", x, y + 32, iw, "your-server.at.ply.gg:41234", { hide_when_streaming = true })
  P.text("Link code", x, y + 90, app:font("semibold", 13), T.text)
  local cf = app:input("linkr:code", x, y + 112, 220, "K7QM-9XTD", { max_chars = 12 })
  if not m.focused then m.focused = true; af:focus() end
  if r and r.state == "failed" then m.error = r.error; m.receiver = nil end
  local function go()
    local target, err = L.parse(af:get(), cf:get())
    if not target then m.error = err; return end
    m.error = nil
    m.receiver = L.receiver(ctl.env, target)
  end
  af.on_submit, cf.on_submit = go, go
  af.on_change = function() m.error = nil end
  if #ctl.servers > 0 then
    AccountUI.paragraph(app, ("This replaces the account on this device (%s, %d server%s)."):format(ctl:display_name(), #ctl.servers, #ctl.servers == 1 and "" or "s"),
      x, y + 170, iw, T.danger, 13)
  end
  if m.error then app.ui:text_fit(m.error, x, cy + ch - 100, iw, app:font("regular", 13), T.danger) end
  if app:button("linkr:go", cx + cw - 28 - 120, cy + ch - 66, 120, 42, "Link", "primary", { disabled = not af:get():find("%S") }) then go() end
end

return M
