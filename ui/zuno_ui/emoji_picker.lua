-- Emoji picker popup: search, recently used, categories. Used for reactions and the composer.
local E = require("zuno_ui.emoji")
local Icons = require("zuno_ui.icons")
local FilesUI = require("zuno_ui.files_ui")

local M = {}
local W, H = 368, 412
local CELL, COLS = 40, 8
local RECENT_MAX = 24
-- a picture for each category tab (by short name)
local CAT_ICONS = { "grinning", "wave", "dog", "pizza", "soccer", "airplane", "bulb", "heart", "checkered_flag" }

-- Open next to a point. on_pick(emoji_text, index) is called; the picker closes itself.
function M.open(app, ax, ay, on_pick, opts)
  opts = opts or {}
  local w, h = app.P.size()
  local x = math.max(8, math.min(ax - W + 40, w - W - 8))
  local y = ay - H - 8
  if y < 60 then y = math.min(ay + 8, h - H - 8) end
  app.picker = { x = x, y = y, on_pick = on_pick, scroll = 0, keep_open = opts.keep_open, conn = opts.conn }
  local f = app.P.field("emoji:search", { max_chars = 40 })
  f:set("")
  f:focus()
end

local function recent(ctl)
  ctl.settings.recent_emoji = ctl.settings.recent_emoji or {}
  return ctl.settings.recent_emoji
end

function M.remember(ctl, text)
  local list = recent(ctl)
  for i, t in ipairs(list) do if t == text then table.remove(list, i); break end end
  table.insert(list, 1, text)
  while #list > RECENT_MAX do table.remove(list) end
  ctl:save()
end

-- Items are emoji indexes (numbers) or server emoji { custom = file, name } and the "add" tile.
local function server_items(app, query)
  local conn = app.picker.conn
  if not conn or not conn:supports("emoji") then return nil end
  local items = {}
  for _, e in ipairs(conn.emoji or {}) do
    if query == "" or e.name:find(query:lower(), 1, true) then items[#items + 1] = { custom = conn:custom_emoji(e.name), name = e.name } end
  end
  if query == "" and conn:is_owner() then items[#items + 1] = { add = true } end
  return #items > 0 and items or nil
end

-- Sections to show: { { title, {items} }, ... }
local function sections(app, query)
  query = query:gsub("^%s+", ""):gsub("%s+$", "")
  local server = server_items(app, query)
  if query ~= "" then
    local out = {}
    if server then out[1] = { "This server", server } end
    out[#out + 1] = { "Results", E.search(query, 200) }
    return out
  end
  local out = {}
  if server then out[1] = { "This server", server } end
  local rec = {}
  for _, t in ipairs(recent(app.ctl)) do
    local i = E.lookup(t)
    local c = not i and app.picker.conn and t:match("^:([a-z0-9_]+):$")
    if i then rec[#rec + 1] = i
    elseif c and app.picker.conn:custom_emoji(c) then rec[#rec + 1] = { custom = app.picker.conn:custom_emoji(c), name = c } end
  end
  if #rec > 0 then out[#out + 1] = { "Recently used", rec } end
  for c, name in ipairs(E.categories()) do out[#out + 1] = { name, E.in_category(c), cat = c } end
  return out
end

function M.draw(app)
  local p = app.picker
  if not p then return end
  local P, T, ui = app.P, app.T, app.ui
  local w, h = P.size()
  -- click outside closes
  local scrim = ui:hit("picker:scrim", 0, 0, w, h, { block = true, cursor = false })
  if scrim.clicked or ui:pressed("escape") then app.picker = nil; return end
  local x, y = p.x, p.y
  P.rect(x + 2, y + 4, W, H, { 0, 0, 0, 0.12 }, 14)
  ui:hit("picker:card", x, y, W, H, { block = true, cursor = false })
  P.rect(x, y, W, H, T.card, 14)
  P.rect_line(x, y, W, H, T.line, 14, 1)

  -- search
  local f = app:input("emoji:search", x + 12, y + 12, W - 24, "Search emoji")
  local q = f:get()

  -- category tabs
  local secs = sections(app, q)
  local tab_y = y + 64
  local tw = (W - 16) / #CAT_ICONS
  for i, n in ipairs(CAT_ICONS) do
    local idx = E.by_name(n)
    local tx = x + 8 + (i - 1) * tw
    local st = ui:hit("picker:cat:" .. i, tx, tab_y, tw, 30, { tip = E.categories()[i] })
    if st.hovered then P.rect(tx + 2, tab_y, tw - 4, 30, T.hover, 6) end
    if idx then E.draw(P, idx, tx + (tw - 20) / 2, tab_y + 5, 20) end
    if st.clicked then
      f:set("")
      p.jump_cat = i
    end
  end
  P.rect(x, tab_y + 36, W, 1, T.line)

  -- grid
  local gx, gy, gw, gh = x + 8, tab_y + 40, W - 16, H - (tab_y + 40 - y) - 34
  local list_st = ui:hit("picker:grid", gx, gy, gw, gh, { scroll = true, cursor = false })
  if list_st.wheel then p.scroll = p.scroll - list_st.wheel * 60 end
  -- measure content
  local tf = app:font("semibold", 11)
  local total, starts = 0, {}
  for si, sec in ipairs(secs) do
    starts[si] = total
    total = total + 24 + math.ceil(#sec[2] / COLS) * CELL + 6
  end
  if p.jump_cat then
    for si, sec in ipairs(secs) do if sec.cat == p.jump_cat then p.scroll = starts[si] end end
    p.jump_cat = nil
  end
  if p.last_q ~= q then p.scroll = 0; p.last_q = q end
  p.scroll = math.max(0, math.min(p.scroll, math.max(0, total - gh)))
  ui:clip(gx, gy, gw, gh)
  local hovered
  local first_result
  for si, sec in ipairs(secs) do
    local sy = gy + starts[si] - p.scroll
    local rows = math.ceil(#sec[2] / COLS)
    if sy + 24 + rows * CELL >= gy and sy <= gy + gh then
      P.text(sec[1]:upper(), gx + 6, sy + 6, tf, T.faint)
      for k, idx in ipairs(sec[2]) do
        if not (type(idx) == "table" and idx.add) then first_result = first_result or idx end
        local col, row = (k - 1) % COLS, math.floor((k - 1) / COLS)
        local ex, ey = gx + 4 + col * (CELL + 4), sy + 24 + row * CELL
        if ey + CELL >= gy and ey <= gy + gh then
          local st = ui:hit("picker:e:" .. si .. ":" .. k, ex - 2, ey, CELL + 4, CELL,
            { tip = type(idx) == "table" and idx.add and "Add a server emoji" or nil }) -- no gaps between cells
          if st.hovered then P.rect(ex, ey, CELL, CELL, T.hover, 8); hovered = idx end
          if type(idx) == "table" and idx.add then
            P.rect_line(ex + 6, ey + 6, CELL - 12, CELL - 12, T.faint, 6, 1)
            Icons.draw(P, "plus", ex + 11, ey + 11, 18, T.muted)
            if st.clicked then ui:unclip(); app.picker = nil; M.add_custom(app, p.conn) return end
          else
            M.draw_item(app, p.conn, idx, ex + 6, ey + 6, CELL - 12)
            if st.clicked then ui:unclip(); M.pick(app, idx) return end
            if st.rclicked and type(idx) == "table" and p.conn:is_owner() then
              local name = idx.name
              app:open_menu(ui.rclick_x, ui.rclick_y, { { label = "Remove :" .. name .. ":", danger = true, fn = function()
                app:confirm("Remove :" .. name .. ":?", "It disappears from messages and reactions on this server.", "Remove",
                  function() p.conn:send({ t = "emoji_remove", name = name }) end, true)
              end } })
              app.picker = nil
            end
          end
        end
      end
    else
      for _, idx in ipairs(sec[2]) do if not (type(idx) == "table" and idx.add) then first_result = first_result or idx; break end end
    end
  end
  if #secs == 1 and #secs[1][2] == 0 then
    P.text("No emoji found", gx + 8, gy + 12, app:font("regular", 13), T.muted)
  end
  ui:unclip()
  -- footer: name of the hovered emoji
  local show = hovered or first_result
  P.rect(x, y + H - 34, W, 1, T.line)
  if show and not (type(show) == "table" and show.add) then
    M.draw_item(app, p.conn, show, x + 12, y + H - 28, 22)
    local nm = type(show) == "table" and show.name or E.name(show)
    ui:text_fit(":" .. nm .. ":", x + 42, y + H - 17 - P.line_height(app:font("medium", 13)) / 2, W - 54, app:font("medium", 13), T.soft)
  end
  f.on_submit = function() if first_result then M.pick(app, first_result) end end
end

function M.draw_item(app, conn, idx, x, y, s)
  if type(idx) == "table" then
    local img = FilesUI.image(app, conn, idx.custom)
    if img then FilesUI.draw_fit(app.P, img, x, y, s, s, false) end
  else
    E.draw(app.P, idx, x, y, s)
  end
end

function M.pick(app, idx)
  local p = app.picker
  if not p then return end
  local text = type(idx) == "table" and (":" .. idx.name .. ":") or E.text(idx)
  if type(idx) == "table" then idx = nil end
  M.remember(app.ctl, text)
  if not p.keep_open then app.picker = nil end
  p.on_pick(text, idx)
end

------------------------------------------------------------------ adding a server emoji (owner)
function M.add_custom(app, conn)
  app.P.pick_file("Image", nil, function(data, path)
    if not data then
      if path ~= "cancelled" then app.ctl:toast(path == "unavailable" and "No file dialog here." or tostring(path), "error") end
      return
    end
    local png = app.P.square_png and app.P.square_png(data, 64)
    if not png then app.ctl:toast("That isn't a picture Zuno can read (PNG, JPEG, BMP).", "error"); return end
    local base = (path:match("([^/\\]+)%.[%w]+$") or path:match("[^/\\]+$") or "emoji"):lower():gsub("[^a-z0-9_]", "_"):gsub("_+", "_")
    base = base:gsub("^_", ""):gsub("_$", ""):sub(1, 32)
    if #base < 2 then base = "emoji" end
    app.modal = { kind = "emoji_add", conn = conn, png = png, draw = M.draw_add }
    app.P.field("emoji:name", { max_chars = 32 }):set(base)
  end)
end

function M.draw_add(app, w, h)
  local AccountUI = require("zuno_ui.account_ui")
  local P, T, m = app.P, app.T, app.modal
  local cw, ch = math.min(440, w - 32), 300
  local cx, cy = AccountUI.frame(app, w, h, cw, ch, true)
  if not cx then return end
  P.text("Add a server emoji", cx + 28, cy + 24, app:font("head_bold", 22), T.text)
  local img = P.image_from_data("emoji-add:" .. tostring(m), m.png)
  if img then FilesUI.draw_fit(P, img, cx + 28, cy + 80, 64, 64, false) end
  P.text("Name", cx + 112, cy + 76, app:font("semibold", 13), T.text)
  local f = app:input("emoji:name", cx + 112, cy + 98, cw - 140, "party_cat", { max_chars = 32 })
  if not m.focused then m.focused = true; f:focus() end
  local name = f:get()
  local err
  if not name:match("^[a-z0-9_]+$") or #name < 2 then err = "2 to 32 of a-z, 0-9 and _"
  elseif E.by_name(name) then err = ":" .. name .. ": is already a normal emoji"
  elseif m.conn:custom_emoji(name) then err = "Replaces the server's :" .. name .. ":" end
  if err then P.text(err, cx + 112, cy + 150, app:font("regular", 12), err:find("^Replaces") and T.muted or T.danger) end
  AccountUI.paragraph(app, "Everyone on this server can use it as :" .. (name ~= "" and name or "name") .. ":.", cx + 28, cy + 176, cw - 56, T.muted, 13)
  local ok = not err or err:find("^Replaces")
  local function go()
    if not ok then return end
    local conn, png = m.conn, m.png
    app.modal = nil
    conn:upload(png, { name = name .. ".png", mime = "image/png", w = 64, h = 64, kind = "emoji" }, function(file, uerr)
      if not file then app.ctl:toast("Couldn't upload the emoji: " .. tostring(uerr), "error"); return end
      conn:send({ t = "emoji_add", name = name, file = file.id })
      app.ctl:toast(":" .. name .. ": added")
    end)
  end
  f.on_submit = go
  if app:button("emoji:add", cx + cw - 28 - 110, cy + ch - 66, 110, 42, "Add", "primary", { disabled = not ok }) then go() end
end

return M
