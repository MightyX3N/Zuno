-- Account dialogs: back up (export), restore (import). Drawn on top of everything.
-- app.modal = { kind = "export" | "import", ... }   app.job = { label, fn } runs after one frame.
local Icons = require("zuno_ui.icons")
local Theme = require("zuno_ui.theme")

local M = {}

-- Scrim + card. Returns cx, cy, or nil when the user clicked outside (closes the modal).
function M.frame(app, w, h, cw, ch, closable)
  local P, T, ui = app.P, app.T, app.ui
  local scrim = ui:hit("modal:scrim", 0, 0, w, h, { block = true, cursor = false })
  P.rect(0, 0, w, h, T.scrim)
  if closable and scrim.clicked then app.modal = nil; return nil end
  local cx, cy = math.floor((w - cw) / 2), math.max(16, math.floor((h - ch) / 2))
  ui:hit("modal:card", cx, cy, cw, ch, { block = true, cursor = false })
  app:card(cx, cy, cw, ch)
  if closable and app:icon_button("modal:close", "close", cx + cw - 52, cy + 20, 32, "Close") then app.modal = nil; return nil end
  return cx, cy
end

function M.paragraph(app, text, x, y, w, color, size)
  local f = app:font("regular", size or 14)
  local lh = math.floor(app.P.line_height(f) * 1.45)
  local lines = app:wrap(f, text, w)
  for i, l in ipairs(lines) do app.P.text(l, x, y + (i - 1) * lh, f, color or app.T.muted) end
  return y + #lines * lh
end

local function checkbox(app, id, x, y, checked, label)
  local P, T = app.P, app.T
  local f = app:font("medium", 14)
  local st = app.ui:hit(id, x, y, 24 + P.measure(f, label) + 10, 24)
  P.rect(x, y + 1, 22, 22, checked and T.accent or T.bg, 6)
  P.rect_line(x, y + 1, 22, 22, checked and T.accent or T.input, 6, 1.5)
  if checked then Icons.draw(P, "check", x + 2, y + 3, 18, T.on_accent, 2.2) end
  P.text(label, x + 32, y + 12 - P.line_height(f) / 2, f, T.text)
  return st.clicked
end

------------------------------------------------------------------ export
function M.open_export(app)
  app.P.blur_all()
  app.settings_open = false
  app.modal = { kind = "export", key = app.ctl:new_recovery_key(), confirmed = false }
end

local function finish_export(app, m)
  local ctl, P = app.ctl, app.P
  local data = ctl:export_account(m.key)
  local name = require("zuno_ui.account").file_name(ctl.settings.name)
  m.waiting = true
  P.save_file(name, data, "Zuno account", "zunokey", function(path, err)
    m.waiting = nil
    if path then
      m.done = { path = path }
    elseif err == "cancelled" then
      m.cancelled = true
    else
      local fallback, ferr = P.save_fallback(name, data)
      if fallback then m.done = { path = fallback, fallback = true }
      else m.error = "Couldn't save the file: " .. tostring(ferr or err) end
    end
  end)
end

function M.draw_export(app, w, h)
  local P, T, ctl, m = app.P, app.T, app.ctl, app.modal
  local cw, ch = math.min(560, w - 32), m.done and 330 or 470
  local cx, cy = M.frame(app, w, h, cw, ch, true)
  if not cx then return end
  local x, iw = cx + 28, cw - 56
  if m.done then
    Icons.draw(P, "check", x, cy + 26, 26, T.ok, 2.4)
    P.text("Account backed up", x + 36, cy + 24, app:font("head_bold", 22), T.text)
    local y = M.paragraph(app, m.fallback and "No save dialog was available, so the file went to your Zuno folder:" or "Saved to:", x, cy + 74, iw)
    P.rect(x, y + 6, iw, 40, T.sunken, 8)
    app.ui:text_fit(m.done.path, x + 12, y + 26 - P.line_height(app:font("medium", 13)) / 2, iw - 24, app:font("medium", 13), T.text)
    y = M.paragraph(app, "Keep the file and the recovery key in different places. To restore, choose Import account in Settings (or drop the file onto Zuno) and type the key.", x, y + 62, iw)
    if m.done.fallback and app:button("export:openfolder", x, cy + ch - 66, 150, 42, "Open folder", "secondary") then
      P.open_folder(m.done.path:match("^(.*)[/\\]") or m.done.path)
    end
    if app:button("export:close", cx + cw - 28 - 110, cy + ch - 66, 110, 42, "Done", "primary") then app.modal = nil end
    return
  end
  P.text("Back up your account", x, cy + 24, app:font("head_bold", 22), T.text)
  local y = M.paragraph(app, "You'll get a file and this recovery key. You need both to restore your account on a new device. Keep them apart, for example the file on a USB stick and the key on paper.", x, cy + 70, iw)
  -- the key
  P.rect(x, y + 12, iw, 64, T.sunken, 12)
  local size = 24
  while size > 14 and P.measure(app:font("head_bold", size), m.key) > iw - 130 do size = size - 1 end
  local kf = app:font("head_bold", size)
  local shown = app:secret(m.key, "export:key", x, y + 12, iw - 96, 64)
  if shown then P.text(m.key, x + 18, y + 44 - P.line_height(kf) / 2, kf, T.text) end
  if app:button("export:copy", x + iw - 86, y + 28, 72, 32, "Copy", "secondary", { radius = 8 }) then
    P.set_clipboard(m.key); ctl:toast("Recovery key copied. Paste it somewhere safe, then clear your clipboard.")
  end
  y = y + 92
  y = M.paragraph(app, "Lose both the file and the key and the account is gone. Nobody can reset it, not even a server owner.", x, y, iw, T.danger, 13)
  if checkbox(app, "export:confirm", x, y + 14, m.confirmed, "I've saved my recovery key") then m.confirmed = not m.confirmed end
  if m.error then app.ui:text_fit(m.error, x, cy + ch - 104, iw, app:font("regular", 13), T.danger) end
  if m.cancelled then app.ui:text_fit("Not saved. Press the button again to choose where.", x, cy + ch - 104, iw, app:font("regular", 13), T.muted) end
  if m.waiting then app.ui:text_fit("Choose where to save it in the file window…", x, cy + ch - 104, iw, app:font("regular", 13), T.muted) end
  if app:button("export:save", cx + cw - 28 - 200, cy + ch - 66, 200, 42, "Save account file…", "primary", { disabled = not m.confirmed or m.waiting }) then
    m.error, m.cancelled = nil, nil
    app.job = { label = "Encrypting your account…", fn = function() finish_export(app, m) end }
  end
end

------------------------------------------------------------------ import
function M.open_import(app, file)
  app.P.blur_all()
  app.settings_open = false
  app.modal = { kind = "import", file = file }
end

function M.draw_import(app, w, h)
  local P, T, ctl, m = app.P, app.T, app.ctl, app.modal
  local replacing = #ctl.servers > 0
  local cw, ch = math.min(560, w - 32), replacing and 430 or 380
  local cx, cy = M.frame(app, w, h, cw, ch, true)
  if not cx then return end
  local x, iw = cx + 28, cw - 56
  P.text("Import an account", x, cy + 24, app:font("head_bold", 22), T.text)
  local y = M.paragraph(app, "Choose your .zunokey file (or drop it onto this window) and type its recovery key.", x, cy + 70, iw)
  -- file row
  P.rect(x, y + 10, iw, 48, T.sunken, 10)
  local fname = m.file and m.file.name or "No file chosen"
  app.ui:text_fit(fname, x + 14, y + 34 - P.line_height(app:font("medium", 14)) / 2, iw - 150, app:font("medium", 14), m.file and T.text or T.faint)
  if app:button("import:choose", x + iw - 128, y + 18, 118, 32, "Choose file…", "secondary", { radius = 8, disabled = m.picking }) then
    m.picking = true
    P.pick_file("Zuno account", "zunokey", function(data, path_or_err)
      m.picking = nil
      if data then m.file = { name = path_or_err:match("[^/\\]+$") or path_or_err, data = data }; m.error = nil
      elseif path_or_err == "unavailable" then m.error = "No file dialog here. Drag the .zunokey file onto this window instead."
      elseif path_or_err ~= "cancelled" then m.error = tostring(path_or_err) end
    end)
  end
  y = y + 76
  P.text("Recovery key", x, y, app:font("semibold", 13), T.text)
  local kf = app:input("import:key", x, y + 22, iw, "K7QM9-XTD4H-PAW2R-E8NVC-3J6TK", { max_chars = 40, secret = app:streamer() })
  local function go()
    if not m.file then m.error = "Choose the account file first."; return end
    local data, key = m.file.data, kf:get()
    app.job = { label = "Unlocking your account…", fn = function()
      local acc, err = ctl:read_account_file(data, key)
      if not acc then m.error = err; return end
      ctl:replace_account(acc)
      kf:set("")
      app.modal = nil
      app.page = #ctl.servers == 0 and "add" or nil
      app.welcome_name = nil
      ctl:toast("Welcome back" .. (acc.name and (", " .. acc.name) or "") .. ". Your servers are reconnecting.")
    end }
  end
  kf.on_submit = go
  kf.on_change = function() m.error = nil end
  y = y + 80
  if replacing then
    y = M.paragraph(app, ("This replaces the account on this device (%s, %d server%s). Back it up first if you want to keep it.")
      :format(ctl:display_name(), #ctl.servers, #ctl.servers == 1 and "" or "s"), x, y, iw, T.danger, 13)
  end
  if m.error then app.ui:text_fit(m.error, x, cy + ch - 100, iw, app:font("regular", 13), T.danger) end
  if app:button("import:go", cx + cw - 28 - 140, cy + ch - 66, 140, 42, "Import", replacing and "danger" or "primary",
      { disabled = not m.file or not kf:get():find("%w") }) then go() end
end

------------------------------------------------------------------ busy overlay
function M.draw_job(app, w, h)
  local P, T = app.P, app.T
  app.ui:hit("job:block", 0, 0, w, h, { block = true, cursor = false })
  P.rect(0, 0, w, h, T.scrim)
  local f = app:font("semibold", 15)
  local tw = P.measure(f, app.job.label) + 48
  P.rect((w - tw) / 2, h / 2 - 28, tw, 56, T.card, 14)
  P.text(app.job.label, (w - tw) / 2 + 24, h / 2 - P.line_height(f) / 2, f, T.text)
end

return M
