-- Composer helpers: what the user types vs. what is sent.
--   In the field: @Name and :shortcode:   (fields can't draw emoji)
--   On the wire:  <@key> and real emoji
-- Plus the @ / : suggestions shown above the composer.
local E = require("zuno_ui.emoji")

local C = {}

local function members_by_name_length(conn)
  local list = {}
  for key, m in pairs(conn.members) do list[#list + 1] = { key = key, name = m.name } end
  table.sort(list, function(a, b) return #a.name > #b.name end)
  return list
end

local function is_word_byte(b) return b and (b >= 0x80 or string.char(b):find("[%w_]")) end

-- Field text -> message text.
function C.to_wire(conn, text)
  text = E.from_shortcodes(text)
  if not text:find("@", 1, true) then return text end
  local out, i = {}, 1
  local members = members_by_name_length(conn)
  while i <= #text do
    local at = text:find("@", i, true)
    if not at then out[#out + 1] = text:sub(i); break end
    out[#out + 1] = text:sub(i, at - 1)
    local matched
    if not is_word_byte(text:byte(at - 1)) then
      for _, m in ipairs(members) do
        local cand = text:sub(at + 1, at + #m.name)
        if cand:lower() == m.name:lower() and not is_word_byte(text:byte(at + #m.name + 1)) then matched = m; break end
      end
    end
    if matched then
      out[#out + 1] = "<@" .. matched.key .. ">"
      i = at + 1 + #matched.name
    else
      out[#out + 1] = "@"
      i = at + 1
    end
  end
  return table.concat(out)
end

-- Message text -> field text (for editing).
function C.to_field(conn, body)
  body = body:gsub("<@(%x+)>", function(k) return "@" .. conn:member_name(k) end)
  return E.to_shortcodes(body)
end

-- What to suggest for the text before the cursor. Returns nil or
-- { kind = "mention" | "emoji", from = byte where the @ / : is, items = {...} }
function C.suggest(conn, before)
  local at_pos, q = before:match("()@([^%s@]*)$")
  if at_pos and not is_word_byte(before:byte(at_pos - 1)) and #q <= 32 then
    local ql = q:lower()
    local starts, inside = {}, {}
    for key, m in pairs(conn.members) do
      local n = m.name:lower()
      if n:sub(1, #ql) == ql then starts[#starts + 1] = { key = key, name = m.name, online = m.online }
      elseif ql ~= "" and n:find(ql, 1, true) then inside[#inside + 1] = { key = key, name = m.name, online = m.online } end
    end
    local function order(a, b)
      if a.online ~= b.online then return a.online and true or false end
      return a.name:lower() < b.name:lower()
    end
    table.sort(starts, order); table.sort(inside, order)
    local items = {}
    for _, l in ipairs({ starts, inside }) do for _, it in ipairs(l) do if #items < 8 then items[#items + 1] = it end end end
    if #items == 0 then return nil end
    return { kind = "mention", from = at_pos, items = items }
  end
  local c_pos, eq = before:match("():([%w_+%-]+)$")
  if c_pos and #eq >= 2 and not is_word_byte(before:byte(c_pos - 1)) then
    local items = {}
    local ql = eq:lower()
    for _, e in ipairs(conn.emoji or {}) do -- server emoji first
      if #items < 4 and e.name:find(ql, 1, true) then
        items[#items + 1] = { custom = conn:custom_emoji(e.name), name = e.name }
      end
    end
    for _, idx in ipairs(E.search(eq, 8 - #items)) do items[#items + 1] = { emoji = idx, name = E.name(idx) } end
    if #items == 0 then return nil end
    return { kind = "emoji", from = c_pos, items = items }
  end
  return nil
end

-- Text that replaces the typed @que / :que when a suggestion is picked.
function C.insert_text(item)
  if item.emoji or item.custom then return ":" .. item.name .. ": " end
  return "@" .. item.name .. " "
end

return C
