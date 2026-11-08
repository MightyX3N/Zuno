-- Emoji picker popup: search, recently used, categories. Used for reactions and the composer.
local E = require("zuno_ui.emoji")
local Icons = require("zuno_ui.icons")

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
  app.picker = { x = x, y = y, on_pick = on_pick, scroll = 0, keep_open = opts.keep_open }
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

-- Sections to show: { { title, {indexes} }, ... }
local function sections(app, query)
  if query:find("%S") then
    return { { "Results", E.search(query, 200) } }
  end
  local out = {}
  local rec = {}
  for _, t in ipairs(recent(app.ctl)) do local i = E.lookup(t); if i then rec[#rec + 1] = i end end
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
        first_result = first_result or idx
        local col, row = (k - 1) % COLS, math.floor((k - 1) / COLS)
        local ex, ey = gx + 4 + col * (CELL + 4), sy + 24 + row * CELL
        if ey + CELL >= gy and ey <= gy + gh then
          local st = ui:hit("picker:e:" .. si .. ":" .. k, ex - 2, ey, CELL + 4, CELL) -- no gaps between cells
          if st.hovered then P.rect(ex, ey, CELL, CELL, T.hover, 8); hovered = idx end
          E.draw(P, idx, ex + 6, ey + 6, CELL - 12)
          if st.clicked then ui:unclip(); M.pick(app, idx) return end
        end
      end
    else
      for _, idx in ipairs(sec[2]) do first_result = first_result or idx; break end
    end
  end
  if #secs == 1 and #secs[1][2] == 0 then
    P.text("No emoji found", gx + 8, gy + 12, app:font("regular", 13), T.muted)
  end
  ui:unclip()
  -- footer: name of the hovered emoji
  local show = hovered or first_result
  P.rect(x, y + H - 34, W, 1, T.line)
  if show then
    E.draw(P, show, x + 12, y + H - 28, 22)
    ui:text_fit(":" .. E.name(show) .. ":", x + 42, y + H - 17 - P.line_height(app:font("medium", 13)) / 2, W - 54, app:font("medium", 13), T.soft)
  end
  f.on_submit = function() if first_result then M.pick(app, first_result) end end
end

function M.pick(app, idx)
  local p = app.picker
  if not p then return end
  local text = E.text(idx)
  M.remember(app.ctl, text)
  if not p.keep_open then app.picker = nil end
  p.on_pick(text, idx)
end

return M
