-- Emoji: lookup, :shortcodes:, search and drawing from the Twemoji sheet.
-- Messages always carry real Unicode emoji. Text fields can't draw them, so the composer
-- shows :shortcodes: instead and converts them when the message is sent.
local E = {}

local data
local by_text, by_name, max_bytes
local function load()
  if data then return end
  data = require("zuno_ui.emoji_data")
  by_text, by_name, max_bytes = {}, {}, 0
  for i, row in ipairs(data.list) do
    row.index = i
    by_text[row[1]] = i
    -- The plain form (without U+FE0F) counts too, except for symbols that are usually text,
    -- like © ® ™ and arrows: only U+1Fxxx and the U+2600-27BF symbols/dingbats are taken.
    local alt = row[4]
    if alt and not by_text[alt] then
      local b1, b2 = alt:byte(1, 2)
      if b1 >= 0xF0 or (b1 == 0xE2 and b2 >= 0x98 and b2 <= 0x9E) then by_text[alt] = i end
    end
    for _, n in ipairs(row[2]) do if not by_name[n] then by_name[n] = i end end
    max_bytes = math.max(max_bytes, #row[1])
  end
end

function E.count() load(); return #data.list end
function E.categories() load(); return data.categories end
function E.get(i) load(); return data.list[i] end
function E.text(i) load(); return data.list[i] and data.list[i][1] end
function E.name(i) load(); return data.list[i] and data.list[i][2][1] end
function E.by_name(name) load(); return by_name[name] end

-- Skin tones are drawn with the plain emoji (the sheet has no tone variants).
local function strip_tones(s) return (s:gsub("\240\159\143[\187-\191]", "")) end

-- Index of the emoji whose text is exactly s, or nil.
function E.lookup(s)
  load()
  return by_text[s] or by_text[strip_tones(s)] or by_text[strip_tones(s):gsub("\239\184\143", "")]
end

local function char_len(c)
  if c < 0x80 then return 1 elseif c < 0xE0 then return 2 elseif c < 0xF0 then return 3 end
  return 4
end

-- If an emoji starts at byte i of s, returns its index and the byte where it ends.
function E.at(s, i)
  load()
  local c = s:byte(i)
  if not c then return nil end
  if c < 0x80 then
    -- only keycaps (1️⃣, #️⃣) start with an ASCII character
    if not s:find("^[#*0-9]\239\184\143\226\131\163", i) then return nil end
  elseif c < 0xC2 then
    return nil
  end
  -- collect up to 12 code point boundaries, then try the longest candidate first
  local ends, p = {}, i
  while #ends < 12 and p <= #s and p - i < max_bytes + 8 do
    local b = s:byte(p)
    if b < 0x80 and p > i then break end -- emoji sequences never continue with ASCII
    p = p + char_len(b)
    ends[#ends + 1] = p - 1
  end
  for k = #ends, 1, -1 do
    local idx = E.lookup(s:sub(i, ends[k]))
    if idx then
      -- swallow a trailing variation selector / skin tone that the lookup ignored
      local e = ends[k]
      while true do
        local nxt = s:sub(e + 1, e + 3)
        if nxt == "\239\184\143" then e = e + 3
        elseif s:sub(e + 1, e + 4):find("^\240\159\143[\187-\191]") then e = e + 4
        else break end
      end
      return idx, e
    end
  end
  return nil
end

-- Split text into pieces: { text = "..." } and { emoji = index, text = "😀" }.
function E.split(s)
  local out, buf, i = {}, {}, 1
  while i <= #s do
    local idx, e = E.at(s, i)
    if idx then
      if #buf > 0 then out[#out + 1] = { text = table.concat(buf) }; buf = {} end
      out[#out + 1] = { emoji = idx, text = s:sub(i, e) }
      i = e + 1
    else
      local c = s:byte(i)
      local n = char_len(c)
      buf[#buf + 1] = s:sub(i, i + n - 1)
      i = i + n
    end
  end
  if #buf > 0 then out[#out + 1] = { text = table.concat(buf) } end
  return out
end

-- True when the text is only emoji (and spaces), and how many: big emoji for short ones.
function E.only_emoji(s)
  local n = 0
  for _, piece in ipairs(E.split(s)) do
    if piece.emoji then n = n + 1
    elseif piece.text:find("%S") then return false, 0 end
  end
  return n > 0, n
end

-- 😀 -> :grinning:   (for text fields, which can't draw emoji)
function E.to_shortcodes(s)
  local out = {}
  for _, piece in ipairs(E.split(s)) do
    out[#out + 1] = piece.emoji and (":" .. E.name(piece.emoji) .. ":") or piece.text
  end
  return table.concat(out)
end

-- :grinning: -> 😀, except inside `code`.
function E.from_shortcodes(s)
  load()
  local out, i = {}, 1
  while i <= #s do
    local fence = s:find("```", i, true)
    local tick = s:find("`", i, true)
    local stop = tick or (#s + 1)
    local chunk = s:sub(i, stop - 1)
    out[#out + 1] = chunk:gsub(":([%w_+%-]+):", function(n)
      local idx = by_name[n:lower()]
      return idx and data.list[idx][1] or nil
    end)
    if not tick then break end
    -- copy the code span (or block) unchanged
    local close_pat = (fence == tick) and "```" or "`"
    local close = s:find(close_pat, tick + #close_pat, true)
    if not close then out[#out + 1] = s:sub(tick); break end
    out[#out + 1] = s:sub(tick, close + #close_pat - 1)
    i = close + #close_pat
  end
  return table.concat(out)
end

-- Search by short name / words in the name. Returns a list of indexes.
function E.search(q, limit)
  load()
  q = (q or ""):lower():gsub("^:", ""):gsub(":$", "")
  local exact, prefix, inside = {}, {}, {}
  if q == "" then return {} end
  for i, row in ipairs(data.list) do
    local best
    for _, n in ipairs(row[2]) do
      if n == q then best = 1; break
      elseif n:sub(1, #q) == q then best = math.min(best or 2, 2)
      elseif n:find(q, 1, true) then best = math.min(best or 3, 3) end
    end
    if not best and row[5]:find(q, 1, true) then best = 3 end
    if best == 1 then exact[#exact + 1] = i elseif best == 2 then prefix[#prefix + 1] = i elseif best == 3 then inside[#inside + 1] = i end
  end
  local out = {}
  for _, l in ipairs({ exact, prefix, inside }) do
    for _, i in ipairs(l) do
      out[#out + 1] = i
      if limit and #out >= limit then return out end
    end
  end
  return out
end

-- Indexes in one category (1-based category number).
function E.in_category(c)
  load()
  local out = {}
  for i, row in ipairs(data.list) do if row[3] == c then out[#out + 1] = i end end
  return out
end

-- Draw emoji i at (x, y) with size s. Falls back to the text if the platform has no images.
local sheet
function E.draw(P, i, x, y, s)
  load()
  if not P.image then return end
  sheet = sheet or P.image(data.image)
  if not sheet then return end
  local step = data.cell + 2 * data.pad
  local col, row = (i - 1) % data.cols, math.floor((i - 1) / data.cols)
  P.draw_image(sheet, x, y, s, s, col * step + data.pad, row * step + data.pad, data.cell, data.cell)
end

return E
