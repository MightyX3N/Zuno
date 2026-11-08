-- Direct transfers on screen: "Send files…" dialog, incoming offers and the transfers panel.
local FilesUI = require("zuno_ui.files_ui")
local AccountUI = require("zuno_ui.account_ui")
local Icons = require("zuno_ui.icons")

local M = {}
M.PANEL_W = 340

------------------------------------------------------------------ send dialog
function M.open_send(app, conn, member)
  app.P.blur_all()
  app.modal = { kind = "xfer_send", conn = conn, member = member, files = {}, draw = M.draw_send }
  M.add_file(app)
end

function M.add_file(app)
  local m = app.modal
  app.P.pick_path("Any file", function(path, size)
    if not path then
      if size ~= "cancelled" then app.ctl:toast(size == "unavailable" and "No file dialog here." or tostring(size), "error") end
      return
    end
    if app.modal ~= m then return end
    if #m.files >= 20 then app.ctl:toast("Up to 20 files at once.", "error"); return end
    m.files[#m.files + 1] = { path = path, name = path:match("[^/\\]+$") or path, size = size }
  end)
end

function M.draw_send(app, w, h)
  local P, T, m = app.P, app.T, app.modal
  local rows = math.max(1, #m.files)
  local cw, ch = math.min(520, w - 32), 250 + math.min(rows, 6) * 34
  local cx, cy = AccountUI.frame(app, w, h, cw, ch, true)
  if not cx then return end
  P.text("Send files to " .. m.member.name, cx + 28, cy + 24, app:font("head_bold", 22), T.text)
  local y = AccountUI.paragraph(app, "They get a request to accept. Files go straight to them when possible, encrypted so only they can read them.",
    cx + 28, cy + 68, cw - 56, T.muted, 13)
  y = y + 10
  local total = 0
  if #m.files == 0 then P.text("No files chosen yet.", cx + 28, y + 6, app:font("regular", 14), T.faint) end
  for i, f in ipairs(m.files) do
    total = total + f.size
    if i <= 6 then
      local fy = y + (i - 1) * 34
      app.ui:text_fit(f.name, cx + 28, fy + 6, cw - 56 - 140, app:font("medium", 14), T.text)
      P.text(FilesUI.human(f.size), cx + cw - 28 - 110, fy + 7, app:font("regular", 13), T.faint)
      if app:icon_button("xfer:rm:" .. i, "close", cx + cw - 28 - 26, fy + 2, 26, "Remove") then table.remove(m.files, i); return end
    end
  end
  if #m.files > 6 then P.text(("and %d more"):format(#m.files - 6), cx + 28, y + 6 * 34 + 4, app:font("regular", 13), T.faint) end
  if app:button("xfer:add", cx + 28, cy + ch - 66, 130, 42, "Add file…", "secondary") then M.add_file(app) end
  local online = m.member.online
  local label = #m.files > 0 and ("Send " .. FilesUI.human(total)) or "Send"
  if not online then P.text(m.member.name .. " is offline.", cx + 170, cy + ch - 52, app:font("regular", 13), T.danger) end
  if app:button("xfer:go", cx + cw - 28 - 150, cy + ch - 66, 150, 42, label, "primary", { disabled = #m.files == 0 or not online }) then
    app.ctl.transfers:send(m.conn, m.member.user, m.member.name, m.files)
    app.modal = nil
  end
end

------------------------------------------------------------------ panel
local STATE_TEXT = {
  hashing = "Preparing…", offered = "Waiting for them…", connecting = "Connecting…",
  interrupted = "Paused: waiting for the connection", declined = "Declined", cancelled = "Cancelled", failed = "Failed",
}

local function summary(t)
  local names = {}
  for i, f in ipairs(t.files) do names[i] = f.name end
  return table.concat(names, ", ")
end

function M.panel_height(app)
  local list = app.ctl.transfers and app.ctl.transfers.list or {}
  local hgt = 0
  for i = math.max(1, #list - 3), #list do if list[i] then hgt = hgt + 112 end end
  return hgt
end

function M.draw_panel(app, w, h)
  local mgr = app.ctl.transfers
  if not mgr or #mgr.list == 0 then return 0 end
  local P, T, ui = app.P, app.T, app.ui
  local pw = M.PANEL_W
  local x = w - 20 - pw
  local y = h - 96
  local used = 0
  local first = math.max(1, #mgr.list - 3) -- the newest four
  for i = #mgr.list, first, -1 do
    local t = mgr.list[i]
    local ch = 100
    y = y - ch
    used = used + ch + 12
    ui:hit("xfer:card:" .. t.x, x, y, pw, ch, { block = true, cursor = false })
    P.rect(x + 1, y + 3, pw, ch, { 0, 0, 0, 0.08 }, 12)
    P.rect(x, y, pw, ch, T.card, 12)
    P.rect_line(x, y, pw, ch, T.line, 12, 1)
    local f13, f12 = app:font("semibold", 13), app:font("regular", 12)
    local title = (t.dir == "in" and ("From " .. (t.peer_name or "someone")) or ("To " .. (t.peer_name or "someone")))
    P.text(title, x + 14, y + 12, f13, T.text)
    local name = summary(t)
    if app:streamer() and t.dir == "in" then
      if not app:secret(name, "xfer:" .. t.x, x + 8, y + 30, pw - 60, 22) then name = nil end
    end
    if name then ui:text_fit(name .. " · " .. FilesUI.human(t.total), x + 14, y + 32, pw - 28, f12, T.soft) end
    local st = t.state
    local by = y + ch - 40
    if st == "asking" then
      if app:button("xfer:accept:" .. t.x, x + pw - 14 - 90, by, 90, 30, "Accept", "primary", { radius = 8 }) then mgr:accept(t) end
      if app:button("xfer:decline:" .. t.x, x + pw - 14 - 90 - 8 - 84, by, 84, 30, "Decline", "secondary", { radius = 8 }) then mgr:decline(t) end
      P.text("Saved to Downloads", x + 14, by + 8, f12, T.faint)
    elseif st == "done" then
      Icons.draw(P, "check", x + 14, by + 5, 18, T.ok, 2.2)
      P.text(t.dir == "in" and "In Downloads" or "Sent", x + 38, by + 7, app:font("medium", 13), T.text)
      if t.dir == "in" and app:button("xfer:show:" .. t.x, x + pw - 14 - 34 - 8 - 110, by, 110, 30, "Show folder", "secondary", { radius = 8 }) then
        app.P.open_folder(app.ctl.transfers.env.downloads_dir())
      end
      if app:icon_button("xfer:x:" .. t.x, "close", x + pw - 14 - 30, by, 30, "Dismiss") then mgr:dismiss(t); return used end
    elseif st == "declined" or st == "cancelled" or st == "failed" then
      ui:text_fit(t.why or STATE_TEXT[st], x + 14, by + 7, pw - 28 - 40, app:font("medium", 13), st == "failed" and T.danger or T.muted)
      if app:icon_button("xfer:x:" .. t.x, "close", x + pw - 14 - 30, by, 30, "Dismiss") then mgr:dismiss(t); return used end
    else
      -- progress
      local p = mgr:progress(t)
      P.rect(x + 14, y + 56, pw - 28, 4, T.sunken, 2)
      P.rect(x + 14, y + 56, (pw - 28) * p, 4, T.accent, 2)
      local info
      if st == "sending" or st == "receiving" then
        local route = t.route == "direct" and "Direct" or (t.route == "relay" and "Through the server" or "")
        info = ("%d%% · %s/s · %s"):format(math.floor(p * 100), FilesUI.human(math.floor(t.speed or 0)), route)
        if t.paused or t.peer_paused then info = "Paused" .. (t.peer_paused and " by " .. (t.peer_name or "them") or "") end
      else
        info = STATE_TEXT[st] or st
        if st == "hashing" then info = ("Preparing… %d%%"):format(math.floor(p * 100)) end
      end
      ui:text_fit(info, x + 14, by + 7, pw - 28 - 170, f12, T.muted)
      if (st == "sending" or st == "receiving") and app:button("xfer:pause:" .. t.x, x + pw - 14 - 84 - 8 - 84, by, 84, 30,
          t.paused and "Resume" or "Pause", "secondary", { radius = 8 }) then
        mgr:pause(t, not t.paused)
      end
      if app:button("xfer:cancel:" .. t.x, x + pw - 14 - 84, by, 84, 30, "Cancel", "secondary", { radius = 8 }) then mgr:cancel(t) end
    end
    y = y - 12
  end
  return used
end

return M
