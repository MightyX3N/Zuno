-- Files in chat: attaching, uploading with the message, showing images and file cards,
-- the image viewer, and loading pictures (attachments, avatars, server emoji) from the cache.
local Icons = require("zuno_ui.icons")
local Theme = require("zuno_ui.theme")

local M = {}

M.IMAGE_MAX_W, M.IMAGE_MAX_H = 400, 300
M.AUTO_LOAD = 12 * 1024 * 1024 -- images bigger than this load on click

function M.human(n)
  if not n then return "" end
  if n >= 1073741824 then return ("%.1f GB"):format(n / 1073741824) end
  if n >= 1048576 then return ("%.1f MB"):format(n / 1048576) end
  if n >= 1024 then return ("%d KB"):format(math.floor(n / 1024 + 0.5)) end
  return n .. " bytes"
end

local MIME = {
  png = "image/png", jpg = "image/jpeg", jpeg = "image/jpeg", gif = "image/gif", bmp = "image/bmp", webp = "image/webp",
  txt = "text/plain", md = "text/markdown", pdf = "application/pdf", zip = "application/zip", mp3 = "audio/mpeg",
  mp4 = "video/mp4", json = "application/json", lua = "text/x-lua",
}
function M.ext(name) return (name:match("%.([%w]+)$") or ""):lower() end
function M.mime(name) return MIME[M.ext(name)] end

function M.is_image(f)
  return f.w and f.h and f.w > 0 and f.h > 0 and f.w <= 8192 and f.h <= 8192 and (f.mime or ""):find("^image/") ~= nil
end

------------------------------------------------------------------ pictures from files
-- Returns a drawable image for a file { id, hash, size }, starting a download if needed.
-- nil while it loads (or if it can't be shown).
function M.image(app, conn, file)
  local P = app.P
  if not P.image_from_data or not file or not file.hash then return nil end
  local img = P.image_from_data(file.hash)
  if img then return img end
  app.image_state = app.image_state or {}
  local st = app.image_state[file.hash]
  if st == "loading" or st == "failed" then return nil end
  app.image_state[file.hash] = "loading"
  app.ctl:fetch(conn, file, function(data)
    local made = data and P.image_from_data(file.hash, data)
    app.image_state[file.hash] = made and "ready" or "failed"
  end)
  return nil
end

-- Draw an image scaled to fit (cover = crop to fill the box instead).
function M.draw_fit(P, img, x, y, w, h, cover, radius)
  local iw, ih = P.image_size(img)
  local s = cover and math.max(w / iw, h / ih) or math.min(w / iw, h / ih)
  if cover then
    local sw, sh = w / s, h / s
    if radius and P.draw_image_round then P.draw_image_round(img, x, y, w, h, radius, (iw - sw) / 2, (ih - sh) / 2, sw, sh)
    else P.draw_image(img, x, y, w, h, (iw - sw) / 2, (ih - sh) / 2, sw, sh) end
  else
    local dw, dh = iw * s, ih * s
    P.draw_image(img, x + (w - dw) / 2, y + (h - dh) / 2, dw, dh)
  end
end

------------------------------------------------------------------ attaching (composer)
function M.attach(app, conn, v, name, data)
  if not conn:supports("files") then
    app.ctl:toast("This server is too old for files. Ask the owner to update it.", "error"); return
  end
  local max = conn.limits and conn.limits.max_file
  if max and #data > max then
    app.ctl:toast(("%s is too big: this server takes files up to %s."):format(name, M.human(max)), "error"); return
  end
  v.attach = v.attach or {}
  if #v.attach >= 10 then app.ctl:toast("Up to 10 files per message.", "error"); return end
  local a = { name = name, data = data, size = #data, mime = M.mime(name) }
  if a.mime and a.mime:find("^image/") and app.P.image_info then
    a.w, a.h = app.P.image_info(data, name)
    if not a.w then a.mime = nil end
  end
  v.attach[#v.attach + 1] = a
end

function M.pick(app, conn, v)
  app.P.pick_file("Any file", nil, function(data, path)
    if not data then
      if path ~= "cancelled" then app.ctl:toast(path == "unavailable" and "No file dialog here: drop the file onto the window." or tostring(path), "error") end
      return
    end
    M.attach(app, conn, v, path:match("[^/\\]+$") or path, data)
  end)
end

-- Row of attachment chips above the composer. Returns the height used.
function M.attach_height(v) return (v.attach and #v.attach > 0) and 76 or 0 end

function M.draw_attachments(app, v, x, y, w)
  local P, T, ui = app.P, app.T, app.ui
  if not v.attach or #v.attach == 0 then return end
  local cx = x
  local f, sf = app:font("medium", 13), app:font("regular", 12)
  for i, a in ipairs(v.attach) do
    local cw = 220
    if cx + cw > x + w then break end
    P.rect(cx, y, cw, 64, T.card, 10)
    P.rect_line(cx, y, cw, 64, T.line, 10, 1)
    if a.w and a.preview ~= false then
      a.preview_img = a.preview_img or P.image_from_data("attach:" .. tostring(a), a.data)
      if a.preview_img then M.draw_fit(P, a.preview_img, cx + 8, y + 8, 48, 48, true, 6) else a.preview = false end
    else
      P.rect(cx + 8, y + 8, 48, 48, T.sunken, 8)
      local ext = M.ext(a.name):upper():sub(1, 4)
      local ef = app:font("semibold", 11)
      P.text(ext ~= "" and ext or "FILE", cx + 8 + (48 - P.measure(ef, ext ~= "" and ext or "FILE")) / 2, y + 26, ef, T.muted)
    end
    ui:text_fit(a.name, cx + 66, y + 14, cw - 66 - 30, f, T.text)
    P.text(M.human(a.size), cx + 66, y + 34, sf, T.faint)
    if app:icon_button("attach:rm:" .. i, "close", cx + cw - 28, y + 6, 22, "Remove") then
      table.remove(v.attach, i); return
    end
    cx = cx + cw + 8
  end
end

------------------------------------------------------------------ sending with files
-- Uploads the attachments, then sends the message. Shown in the list as "Uploading…".
function M.send(app, conn, v, ch, text, reply_to)
  local list = v.attach
  v.attach = nil
  local box = { ch = ch, text = text, reply_to = reply_to, files = {}, jobs = {}, at = app.P.now(), state = "uploading" }
  v.outbox = v.outbox or {}
  v.outbox[#v.outbox + 1] = box
  local remaining = #list
  for i, a in ipairs(list) do
    box.jobs[i] = conn:upload(a.data, { name = a.name, mime = a.mime, w = a.w, h = a.h, kind = "file" }, function(file, err)
      if not file then box.state, box.error = "failed", err; return end
      box.files[i] = file
      remaining = remaining - 1
      if remaining == 0 and box.state == "uploading" then
        box.state = "sent"
        for k, o in ipairs(v.outbox) do if o == box then table.remove(v.outbox, k); break end end
        conn:send_message(ch, text, reply_to, box.files)
      end
    end)
  end
  box.list = list
end

function M.outbox_progress(box)
  local total, done = 0, 0
  for _, j in ipairs(box.jobs) do total = total + j.size; done = done + math.min(j.acked, j.size) end
  return total > 0 and done / total or 0
end

------------------------------------------------------------------ files in messages
-- Layout of a message's files at width w: list of { f, x, y, w, h, image }, total height
function M.layout(files, w)
  local out, y = {}, 0
  for _, f in ipairs(files or {}) do
    if M.is_image(f) then
      local s = math.min(1, M.IMAGE_MAX_W / f.w, M.IMAGE_MAX_H / f.h, (w - 4) / f.w)
      local iw, ih = math.max(40, math.floor(f.w * s)), math.max(40, math.floor(f.h * s))
      out[#out + 1] = { f = f, x = 0, y = y + 6, w = iw, h = ih, image = true }
      y = y + 6 + ih
    else
      out[#out + 1] = { f = f, x = 0, y = y + 6, w = math.min(360, w - 4), h = 60 }
      y = y + 66
    end
  end
  return out, y
end

function M.draw(app, conn, id, items, x, y)
  local P, T, ui = app.P, app.T, app.ui
  for i, it in ipairs(items) do
    local f, bx, by = it.f, x + it.x, y + it.y
    if it.image then
      local auto = f.size <= M.AUTO_LOAD or (app.load_big and app.load_big[f.hash])
      local img = auto and M.image(app, conn, f)
      local st = ui:hit(id .. ":file:" .. i, bx, by, it.w, it.h, { tip = f.name })
      if img then
        P.rect(bx, by, it.w, it.h, T.sunken, 8)
        M.draw_fit(P, img, bx, by, it.w, it.h, true, 8)
        if st.clicked then app.viewer = { conn = conn, file = f } end
      else
        P.rect(bx, by, it.w, it.h, T.sunken, 8)
        local msg
        if not auto then msg = "Image · " .. M.human(f.size) .. " · click to load"
        elseif app.image_state and app.image_state[f.hash] == "failed" then msg = "Couldn't load the image"
        else
          local p = conn:download_progress(f.id)
          msg = p and ("Loading " .. math.floor(p * 100) .. "%") or "Loading…"
        end
        local mf = app:font("medium", 12)
        ui:text_fit(msg, bx + 10, by + it.h / 2 - 8, it.w - 20, mf, T.muted)
        if st.clicked and not auto then app.load_big = app.load_big or {}; app.load_big[f.hash] = true end
      end
    else
      local st = ui:hit(id .. ":file:" .. i, bx, by, it.w, it.h, { cursor = false })
      P.rect(bx, by, it.w, it.h, T.card, 10)
      P.rect_line(bx, by, it.w, it.h, st.hovered and T.faint or T.line, 10, 1)
      P.rect(bx + 10, by + 10, 40, 40, T.sunken, 8)
      local ext = M.ext(f.name):upper():sub(1, 4)
      local ef = app:font("semibold", 11)
      if ext == "" then ext = "FILE" end
      P.text(ext, bx + 10 + (40 - P.measure(ef, ext)) / 2, by + 23, ef, T.muted)
      ui:text_fit(f.name, bx + 60, by + 12, it.w - 60 - 96, app:font("medium", 14), T.text)
      local p = conn:download_progress(f.id)
      P.text(p and ("Downloading " .. math.floor(p * 100) .. "%") or M.human(f.size), bx + 60, by + 33, app:font("regular", 12), T.faint)
      if app:button(id .. ":save:" .. i, bx + it.w - 86, by + 14, 74, 32, "Save", "secondary", { radius = 8 }) then
        M.save(app, conn, f)
      end
    end
  end
end

-- Download (or take from the cache) and ask where to save.
function M.save(app, conn, f)
  app.ctl:fetch(conn, f, function(data, err)
    if not data then app.ctl:toast("Couldn't download " .. f.name .. ": " .. tostring(err), "error"); return end
    local ext = M.ext(f.name)
    app.P.save_file(f.name, data, ext ~= "" and (ext:upper() .. " file") or "File", ext ~= "" and ext or nil, function(path, serr)
      if path then app.ctl:toast("Saved " .. f.name)
      elseif serr ~= "cancelled" then
        local fb = app.P.save_fallback(f.name, data)
        if fb then app.ctl:toast("Saved to " .. fb) else app.ctl:toast("Couldn't save: " .. tostring(serr), "error") end
      end
    end)
  end)
end

------------------------------------------------------------------ image viewer
function M.draw_viewer(app, w, h)
  local vw = app.viewer
  if not vw then return end
  local P, T, ui = app.P, app.T, app.ui
  local scrim = ui:hit("viewer:scrim", 0, 0, w, h, { block = true, cursor = false })
  P.rect(0, 0, w, h, { 0, 0, 0, 0.82 })
  if scrim.clicked or ui:pressed("escape") then app.viewer = nil; return end
  local img = M.image(app, vw.conn, vw.file)
  if img then
    local iw, ih = P.image_size(img)
    local s = math.min(1, (w - 80) / iw, (h - 140) / ih)
    local dw, dh = iw * s, ih * s
    ui:hit("viewer:img", (w - dw) / 2, (h - dh) / 2 - 20, dw, dh, { block = true, cursor = false })
    P.draw_image(img, (w - dw) / 2, (h - dh) / 2 - 20, dw, dh)
  end
  local f = app:font("medium", 14)
  local label = vw.file.name .. " · " .. M.human(vw.file.size)
  P.text(label, (w - P.measure(f, label)) / 2, h - 70, f, { 1, 1, 1, 0.9 })
  if app:button("viewer:save", w / 2 - 110, h - 46, 100, 34, "Save", "primary") then M.save(app, vw.conn, vw.file) end
  if app:button("viewer:close", w / 2 + 10, h - 46, 100, 34, "Close", "secondary") then app.viewer = nil end
end

M.Icons, M.Theme = Icons, Theme
return M
