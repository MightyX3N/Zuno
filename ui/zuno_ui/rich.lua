-- Message formatting: a small Markdown subset, mentions, links and emoji.
--
--   **bold**  *italic* or _italic_  ~~strike~~  `code`  ```code block```
--   > quote   - bullet   # heading (also ## and ###)
--   <@key>    mention (the composer turns @Name into this)
--   http(s):// links, emoji images
--
-- parse() turns the text into blocks of styled spans. layout() places them in a width and
-- returns draw operations plus clickable areas. Colors are names ("text", "link", ...)
-- resolved when drawing, so a layout survives theme changes.
local E = require("zuno_ui.emoji")

local R = {}

------------------------------------------------------------------ inline parsing
local function is_space(c) return c == nil or c == "" or c:find("^%s") ~= nil end
local function is_word(c) return c ~= nil and c ~= "" and c:find("^[%w\128-\255]") ~= nil end

-- Is there a closing delimiter `d` after position i (with non-space before it)?
local function closer_after(s, i, d)
  local p = i
  while true do
    local a = s:find(d, p, true)
    if not a then return false end
    local before = s:sub(a - 1, a - 1)
    if a > i and not is_space(before) then
      if d == "*" and s:sub(a, a + 2) == "***" then return true -- closes ***bold italic***
      elseif d == "*" and (s:sub(a + 1, a + 1) == "*" or before == "*") then p = a + 2
      elseif d == "_" and is_word(s:sub(a + 1, a + 1)) then p = a + 1
      else return true end
    else
      p = a + 1
    end
  end
end

local URL_END = "[%.,!?:;%)%]'\"]+$"

function R.inline(s)
  local spans = {}
  local st = { b = false, i = false, s = false }
  local buf = {}
  local function flush()
    if #buf == 0 then return end
    spans[#spans + 1] = { text = table.concat(buf), b = st.b, i = st.i, s = st.s }
    buf = {}
  end
  local function push(span)
    flush()
    span.b, span.i, span.s = span.b or st.b, span.i or st.i, span.s or st.s
    spans[#spans + 1] = span
  end
  local i, n = 1, #s
  while i <= n do
    local c = s:sub(i, i)
    local two = s:sub(i, i + 1)
    if c == "\\" and s:sub(i + 1, i + 1):find("^[%*_~`>\\#%-<|]") then
      buf[#buf + 1] = s:sub(i + 1, i + 1); i = i + 2
    elseif c == "`" then
      local close = s:find("`", i + 1, true)
      if close and close > i + 1 then
        push({ text = s:sub(i + 1, close - 1), code = true })
        i = close + 1
      else
        buf[#buf + 1] = c; i = i + 1
      end
    elseif c == "<" and s:find("^<@%x+>", i) then
      local key = s:match("^<@(%x+)>", i)
      push({ mention = key, text = "@" })
      i = i + #key + 3
    elseif (c == "h" or c == "H") and s:find("^[hH][tT][tT][pP][sS]?://[^%s<>]", i) and not is_word(s:sub(i - 1, i - 1)) then
      local url = s:match("^%S+", i)
      url = url:match("^[^<>]+")
      local trimmed = url:gsub(URL_END, "")
      -- keep a closing ) that belongs to the link, like in Wikipedia URLs
      if url:sub(#trimmed + 1, #trimmed + 1) == ")" and select(2, trimmed:gsub("%(", "")) > select(2, trimmed:gsub("%)", "")) then
        trimmed = trimmed .. ")"
      end
      push({ text = trimmed, link = trimmed })
      i = i + #trimmed
    elseif two == "**" then
      if st.b or closer_after(s, i + 2, "**") then flush(); st.b = not st.b; i = i + 2
      else buf[#buf + 1] = two; i = i + 2 end
    elseif two == "~~" then
      if st.s or closer_after(s, i + 2, "~~") then flush(); st.s = not st.s; i = i + 2
      else buf[#buf + 1] = two; i = i + 2 end
    elseif c == "*" then
      local nxt = s:sub(i + 1, i + 1)
      if st.i and st.idelim == "*" and not is_space(s:sub(i - 1, i - 1)) then
        flush(); st.i = false; i = i + 1
      elseif not st.i and not is_space(nxt) and closer_after(s, i + 1, "*") then
        flush(); st.i = true; st.idelim = "*"; i = i + 1
      else
        buf[#buf + 1] = c; i = i + 1
      end
    elseif c == "_" then
      local prev, nxt = s:sub(i - 1, i - 1), s:sub(i + 1, i + 1)
      if st.i and st.idelim == "_" and not is_space(prev) and not is_word(nxt) then
        flush(); st.i = false; i = i + 1
      elseif not st.i and not is_word(prev) and not is_space(nxt) and closer_after(s, i + 1, "_") then
        flush(); st.i = true; st.idelim = "_"; i = i + 1
      else
        buf[#buf + 1] = c; i = i + 1
      end
    else
      local b = s:byte(i)
      local len = b < 0x80 and 1 or (b < 0xE0 and 2 or (b < 0xF0 and 3 or 4))
      buf[#buf + 1] = s:sub(i, i + len - 1)
      i = i + len
    end
  end
  flush()
  return spans
end

------------------------------------------------------------------ blocks
function R.parse(body)
  local blocks = {}
  local lines = {}
  for line in (body .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = line end
  local i = 1
  while i <= #lines do
    local line = lines[i]
    local fence = line:match("^%s*```(.*)$")
    local single = fence and fence:match("^(.-)```%s*$")
    local close
    if fence and not single then
      for j = i + 1, #lines do if lines[j]:find("```", 1, true) then close = j; break end end
    end
    if single and single ~= "" then
      blocks[#blocks + 1] = { kind = "code", text = single } -- ```code``` on one line
      i = i + 1
    elseif close then
      local body_lines = {}
      if not fence:match("^%w*$") then body_lines[1] = fence end -- ```lua: the language tag is dropped
      for j = i + 1, close - 1 do body_lines[#body_lines + 1] = lines[j] end
      local tail = lines[close]:match("^(.-)```")
      if tail ~= "" then body_lines[#body_lines + 1] = tail end
      blocks[#blocks + 1] = { kind = "code", text = table.concat(body_lines, "\n") }
      local after = lines[close]:match("```(.*)$")
      if after:find("%S") then blocks[#blocks + 1] = { kind = "line", spans = R.inline(after) } end
      i = close + 1
    else
      local q = line:match("^>%s?(.*)$")
      local h, htext = line:match("^(#+)%s+(.+)$")
      local bullet = line:match("^%s*[%-%*]%s+(.+)$") or line:match("^%s*\226\128\162%s+(.+)$")
      if q then
        blocks[#blocks + 1] = { kind = "quote", spans = R.inline(q) }
      elseif h and #h <= 3 then
        blocks[#blocks + 1] = { kind = "heading", level = #h, spans = R.inline(htext) }
      elseif bullet then
        blocks[#blocks + 1] = { kind = "bullet", spans = R.inline(bullet) }
      elseif not line:find("%S") then
        blocks[#blocks + 1] = { kind = "blank" }
      else
        blocks[#blocks + 1] = { kind = "line", spans = R.inline(line) }
      end
      i = i + 1
    end
  end
  return blocks
end

-- Plain text for copying: mentions become @Name, formatting marks stay as typed.
function R.plain(body, name_for)
  return (body:gsub("<@(%x+)>", function(k) return "@" .. name_for(k) end))
end

-- One-line summary without formatting marks (reply previews, notifications).
function R.preview(body, name_for)
  local s = body:gsub("<@(%x+)>", function(k) return "@" .. (name_for and name_for(k) or "someone") end)
  s = s:gsub("```%w*", " "):gsub("\n>%s?", "\n"):gsub("^>%s?", "")
  s = s:gsub("%*%*(.-)%*%*", "%1"):gsub("~~(.-)~~", "%1"):gsub("`([^`]*)`", "%1")
  s = s:gsub("%f[%w%*]%*([^%*%s][^%*]-)%*", "%1"):gsub("%f[%w_]_([^_%s][^_]-)_%f[^%w_]", "%1")
  s = s:gsub("\\([%*_~`>#])", "%1")
  return (s:gsub("%s+", " "):gsub("^ ", ""):gsub(" $", ""))
end

------------------------------------------------------------------ layout
-- ctx: { P, font = fn(style) -> font, size = base font size, name_for = fn(key) -> name,
--        lh = line height }
local function face_for(span)
  if span.code then return "mono" end
  if span.b and span.i then return "bold_italic" end
  if span.b then return "bold" end
  if span.i then return "italic" end
  return "regular"
end

-- Pieces of one span: words, spaces and emoji, each with a width.
local function atoms_of(span, ctx, face, esize, color)
  local P = ctx.P
  local f = ctx.font(face)
  local out = {}
  if span.mention then
    local label = "@" .. ctx.name_for(span.mention)
    out[1] = { text = label, w = P.measure(f, label) + 8, font = f, mention = span.mention, pad = 4, color = "mention", bg = "mention_bg" }
    return out
  end
  local pieces = span.code and { { text = span.text } } or E.split(span.text)
  for _, piece in ipairs(pieces) do
    if piece.emoji then
      out[#out + 1] = { emoji = piece.emoji, w = esize + 2, size = esize, link = span.link, raw = piece.text }
    else
      for word, space in piece.text:gmatch("([^ ]*)( *)") do
        if word ~= "" then
          out[#out + 1] = { text = word, w = P.measure(f, word), font = f, strike = span.s, link = span.link,
            color = span.link and "link" or (span.code and "code" or color), bg = span.code and "code_bg" or nil, code = span.code }
        end
        if space ~= "" then
          out[#out + 1] = { text = space, w = P.measure(f, space), font = f, space = true, bg = span.code and "code_bg" or nil, code = span.code }
        end
      end
    end
  end
  return out
end

-- Break one atom that is wider than the line into pieces that fit.
local function split_atom(a, width, P)
  local out, cur = {}, ""
  for ch in a.text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
    if cur ~= "" and P.measure(a.font, cur .. ch) > width then
      local piece = {}
      for k, v in pairs(a) do piece[k] = v end
      piece.text, piece.w = cur, P.measure(a.font, cur)
      out[#out + 1] = piece
      cur = ch
    else
      cur = cur .. ch
    end
  end
  local piece = {}
  for k, v in pairs(a) do piece[k] = v end
  piece.text, piece.w = cur, P.measure(a.font, cur)
  out[#out + 1] = piece
  return out
end

-- Place atoms in lines. Returns the height used and appends draw ops.
local function flow(atoms, x0, y0, width, lh, ops, hits, P)
  local x, y = 0, 0
  local line_h = lh
  local function newline() x = 0; y = y + line_h; line_h = lh end
  local queue = {}
  for _, a in ipairs(atoms) do
    if not a.space and not a.emoji and a.w > width then
      for _, p in ipairs(split_atom(a, width, P)) do queue[#queue + 1] = p end
    else
      queue[#queue + 1] = a
    end
  end
  for _, a in ipairs(queue) do
    if a.space and x == 0 and not a.code then
      -- no spaces at the start of a wrapped line
    else
      if x > 0 and x + a.w > width and not a.space then newline() end
      local h = a.emoji and (a.size + 4) or lh
      if h > line_h then line_h = h end
      ops[#ops + 1] = { atom = a, x = x0 + x, y = y0 + y, line = y }
      if a.link or a.mention then
        hits[#hits + 1] = { x = x0 + x, y = y0 + y, w = a.w, h = lh, link = a.link, mention = a.mention }
      end
      x = x + a.w
    end
  end
  return y + line_h
end

-- Lay out a message. Returns { h, ops, hits }. ops are drawn by R.draw.
function R.layout(body, width, ctx)
  local P = ctx.P
  local blocks = R.parse(body)
  local only, count = E.only_emoji(body)
  local jumbo = only and count <= 10
  local base_lh = ctx.lh
  local esize = jumbo and 40 or math.floor(P.line_height(ctx.font("regular")) * 1.3 + 0.5)
  local ops, hits = {}, {}
  local y = 0
  for bi, b in ipairs(blocks) do
    if b.kind == "blank" then
      y = y + math.floor(base_lh / 2)
    elseif b.kind == "code" then
      local f = ctx.font("mono")
      local clh = math.floor(P.line_height(f) * 1.4 + 0.5)
      local pad = 8
      local inner = width - pad * 2
      local start = y
      y = y + (bi > 1 and 4 or 0)
      local bg = { box = true, x = 0, y = y, w = width, h = 0, color = "code_bg", radius = 6 }
      ops[#ops + 1] = bg
      local ly = y + pad
      for line in (b.text .. "\n"):gmatch("(.-)\n") do
        line = line:gsub("\t", "    ")
        local atom = { text = line, w = P.measure(f, line), font = f, color = "code" }
        local parts = atom.w > inner and split_atom(atom, inner, P) or { atom }
        for _, p in ipairs(parts) do
          ops[#ops + 1] = { atom = p, x = pad, y = ly, line = 0, lh = clh }
          ly = ly + clh
        end
      end
      bg.h = ly + pad - y
      y = ly + pad + 4
      if y - start < 0 then y = start end
    else
      local indent, color, lh = 0, "text", jumbo and (esize + 8) or base_lh
      local face_override
      if b.kind == "quote" then
        indent = 14; color = "quote"
      elseif b.kind == "bullet" then
        indent = 18
        ops[#ops + 1] = { dot = true, x = 6, y = y + lh / 2, color = "muted" }
      elseif b.kind == "heading" then
        face_override = "h" .. b.level
        lh = math.floor(P.line_height(ctx.font(face_override)) * 1.35 + 0.5)
      end
      local atoms = {}
      for _, sp in ipairs(b.spans) do
        local face = face_override or face_for(sp)
        if face_override and sp.code then face = "mono" end
        for _, a in ipairs(atoms_of(sp, ctx, face, esize, color)) do atoms[#atoms + 1] = a end
      end
      local top = y
      y = y + flow(atoms, indent, y, width - indent, lh, ops, hits, P)
      if b.kind == "quote" then ops[#ops + 1] = { box = true, x = 0, y = top + 2, w = 3, h = y - top - 4, color = "quote_bar", radius = 1.5 } end
    end
  end
  return { h = math.max(y, base_lh), ops = ops, hits = hits, jumbo = jumbo }
end

local function fade(c, a) return { c[1], c[2], c[3], (c[4] or 1) * a } end

-- Draw a layout at (x, y). colors: name -> {r,g,b,a}. alpha multiplies everything.
function R.draw(L, x, y, ctx, colors, alpha)
  local P = ctx.P
  local function col(name)
    local c = colors[name] or colors.text
    if alpha and alpha < 1 then return { c[1], c[2], c[3], (c[4] or 1) * alpha } end
    return c
  end
  -- backgrounds first (code blocks, inline code, mention pills, quote bars)
  for _, op in ipairs(L.ops) do
    if op.box then
      P.rect(x + op.x, y + op.y, op.w, op.h, col(op.color), op.radius)
    elseif op.atom and op.atom.bg then
      local a = op.atom
      local lh = op.lh or ctx.lh
      local fh = P.line_height(a.font)
      local ty = y + op.y + (lh - fh) / 2
      P.rect(x + op.x, ty - 1, a.w, fh + 2, col(a.bg), a.mention and 4 or 3)
    end
  end
  for _, op in ipairs(L.ops) do
    local a = op.atom
    if op.dot then
      P.circle(x + op.x, y + op.y, 2.5, col(op.color))
    elseif a and a.emoji then
      E.draw(P, a.emoji, x + op.x + 1, y + op.y + (L.jumbo and 4 or (ctx.lh - a.size) / 2), a.size)
    elseif a and not a.space then
      local lh = op.lh or ctx.lh
      local fh = P.line_height(a.font)
      local tx, ty = x + op.x + (a.pad or 0), y + op.y + (lh - fh) / 2
      if L.jumbo then ty = y + op.y + (lh - fh) / 2 + 10 end
      local c = col(a.color or "text")
      P.text(a.text, tx, ty, a.font, c)
      if a.strike then P.rect(tx, ty + fh * 0.55, a.w, 1, c) end
      if a.link then P.rect(tx, ty + fh - 1, a.w, 1, fade(c, 0.5)) end
    end
  end
end

return R
