-- QR code encoder (ISO/IEC 18004): byte mode, error correction level M, versions 1-10
-- (up to 213 bytes). Pure Lua for LuaJIT and Lua 5.4. Returns a matrix m[y][x] = true (dark).
local compat = require("zuno.compat")
local bxor = compat.bxor

local QR = {}

-- version -> { ec codewords per block, { {blocks, data codewords}, ... } }   (level M)
local BLOCKS = {
  { 10, { { 1, 16 } } }, { 16, { { 1, 28 } } }, { 26, { { 1, 44 } } }, { 18, { { 2, 32 } } },
  { 24, { { 2, 43 } } }, { 16, { { 4, 27 } } }, { 18, { { 4, 31 } } }, { 22, { { 2, 38 }, { 2, 39 } } },
  { 22, { { 3, 36 }, { 2, 37 } } }, { 26, { { 4, 43 }, { 1, 44 } } },
}
local ALIGN = { {}, { 6, 18 }, { 6, 22 }, { 6, 26 }, { 6, 30 }, { 6, 34 }, { 6, 22, 38 }, { 6, 24, 42 }, { 6, 26, 46 }, { 6, 28, 50 } }
local VERSION_BITS = { [7] = 0x07C94, [8] = 0x085BC, [9] = 0x09A99, [10] = 0x0A4D3 }

------------------------------------------------------------------ GF(256) and Reed-Solomon
local EXP, LOG = {}, {}
do
  local x = 1
  for i = 0, 254 do
    EXP[i] = x; LOG[x] = i
    x = x * 2
    if x >= 256 then x = bxor(x, 0x11D) end
  end
  for i = 255, 511 do EXP[i] = EXP[i - 255] end
end
local function gmul(a, b)
  if a == 0 or b == 0 then return 0 end
  return EXP[LOG[a] + LOG[b]]
end

local function rs_generator(n)
  local g = { 1 }
  for i = 0, n - 1 do
    local ng = {}
    for j = 1, #g + 1 do ng[j] = 0 end
    for j = 1, #g do
      ng[j] = bxor(ng[j], g[j])
      ng[j + 1] = bxor(ng[j + 1], gmul(g[j], EXP[i]))
    end
    g = ng
  end
  return g
end

local function rs_remainder(data, n)
  local g = rs_generator(n)
  local r = {}
  for i = 1, n do r[i] = 0 end
  for _, d in ipairs(data) do
    local factor = bxor(d, r[1])
    table.remove(r, 1); r[n] = 0
    for i = 1, n do r[i] = bxor(r[i], gmul(g[i + 1], factor)) end
  end
  return r
end

------------------------------------------------------------------ data
local function capacity(v)
  local total = 0
  for _, grp in ipairs(BLOCKS[v][2]) do total = total + grp[1] * grp[2] end
  return total
end

local function encode_data(bytes, v)
  local bits = {}
  local function put(val, n) for i = n - 1, 0, -1 do bits[#bits + 1] = math.floor(val / 2 ^ i) % 2 end end
  put(4, 4)                         -- byte mode
  put(#bytes, v <= 9 and 8 or 16)   -- length
  for i = 1, #bytes do put(bytes:byte(i), 8) end
  local cap = capacity(v) * 8
  for _ = 1, math.min(4, cap - #bits) do bits[#bits + 1] = 0 end
  while #bits % 8 ~= 0 do bits[#bits + 1] = 0 end
  local out = {}
  for i = 1, #bits, 8 do
    local b = 0
    for j = 0, 7 do b = b * 2 + bits[i + j] end
    out[#out + 1] = b
  end
  local pad = { 0xEC, 0x11 }
  local k = 1
  while #out < capacity(v) do out[#out + 1] = pad[k]; k = 3 - k end
  return out
end

local function interleave(data, v)
  local ec_n = BLOCKS[v][1]
  local blocks, ecs, pos = {}, {}, 1
  for _, grp in ipairs(BLOCKS[v][2]) do
    for _ = 1, grp[1] do
      local b = {}
      for i = 1, grp[2] do b[i] = data[pos]; pos = pos + 1 end
      blocks[#blocks + 1] = b
      ecs[#ecs + 1] = rs_remainder(b, ec_n)
    end
  end
  local out, maxlen = {}, 0
  for _, b in ipairs(blocks) do maxlen = math.max(maxlen, #b) end
  for i = 1, maxlen do for _, b in ipairs(blocks) do if b[i] then out[#out + 1] = b[i] end end end
  for i = 1, ec_n do for _, e in ipairs(ecs) do out[#out + 1] = e[i] end end
  return out
end

------------------------------------------------------------------ matrix
local function new_matrix(n)
  local m, fixed = {}, {}
  for y = 0, n - 1 do m[y] = {}; fixed[y] = {} end
  return m, fixed
end

local function set(m, fixed, x, y, dark) m[y][x] = dark; fixed[y][x] = true end

local function place_patterns(m, fixed, v, n)
  local function finder(cx, cy)
    for dy = -1, 7 do for dx = -1, 7 do
      local x, y = cx + dx, cy + dy
      if x >= 0 and x < n and y >= 0 and y < n then
        local dark = dx >= 0 and dx <= 6 and dy >= 0 and dy <= 6 and
          (dx == 0 or dx == 6 or dy == 0 or dy == 6 or (dx >= 2 and dx <= 4 and dy >= 2 and dy <= 4))
        set(m, fixed, x, y, dark)
      end
    end end
  end
  finder(0, 0); finder(n - 7, 0); finder(0, n - 7)
  for i = 8, n - 9 do
    set(m, fixed, i, 6, i % 2 == 0)
    set(m, fixed, 6, i, i % 2 == 0)
  end
  local al = ALIGN[v]
  local first, last = al[1], al[#al]
  for _, ay in ipairs(al) do for _, ax in ipairs(al) do
    -- every position except the three that overlap the finder patterns
    if not ((ax == first and ay == first) or (ax == first and ay == last) or (ax == last and ay == first)) then
      for dy = -2, 2 do for dx = -2, 2 do
        set(m, fixed, ax + dx, ay + dy, math.max(math.abs(dx), math.abs(dy)) ~= 1)
      end end
    end
  end end
  set(m, fixed, 8, n - 8, true) -- dark module
  -- reserve format areas
  for i = 0, 8 do
    if not fixed[8][i] then set(m, fixed, i, 8, false) end
    if not fixed[i][8] then set(m, fixed, 8, i, false) end
  end
  for i = 0, 7 do set(m, fixed, n - 1 - i, 8, false); set(m, fixed, 8, n - 1 - i, false) end
  set(m, fixed, 8, n - 8, true)
  if v >= 7 then
    for i = 0, 17 do
      local x, y = math.floor(i / 3), n - 11 + i % 3
      set(m, fixed, x, y, false); set(m, fixed, y, x, false)
    end
  end
end

local function place_data(m, fixed, n, codewords)
  local bits = {}
  for _, c in ipairs(codewords) do for i = 7, 0, -1 do bits[#bits + 1] = math.floor(c / 2 ^ i) % 2 == 1 end end
  local k, up = 1, true
  local x = n - 1
  while x > 0 do
    if x == 6 then x = x - 1 end
    for j = 0, n - 1 do
      local y = up and (n - 1 - j) or j
      for dx = 0, 1 do
        local xx = x - dx
        if not fixed[y][xx] then
          m[y][xx] = bits[k] or false
          k = k + 1
        end
      end
    end
    up = not up
    x = x - 2
  end
end

local MASKS = {
  [0] = function(x, y) return (x + y) % 2 == 0 end,
  function(_, y) return y % 2 == 0 end,
  function(x) return x % 3 == 0 end,
  function(x, y) return (x + y) % 3 == 0 end,
  function(x, y) return (math.floor(y / 2) + math.floor(x / 3)) % 2 == 0 end,
  function(x, y) return (x * y) % 2 + (x * y) % 3 == 0 end,
  function(x, y) return ((x * y) % 2 + (x * y) % 3) % 2 == 0 end,
  function(x, y) return ((x + y) % 2 + (x * y) % 3) % 2 == 0 end,
}

local function format_bits(mask)
  local data = mask -- level M = 00
  local v = data * 1024
  for i = 14, 10, -1 do
    if math.floor(v / 2 ^ i) % 2 == 1 then v = bxor(v, 0x537 * 2 ^ (i - 10)) end
  end
  return bxor(data * 1024 + v, 0x5412)
end

local function place_format(m, n, mask, v)
  local f = format_bits(mask)
  local function bit(i) return math.floor(f / 2 ^ i) % 2 == 1 end
  -- m[y][x]: first copy runs down column 8 then along row 8; second copy is split
  for i = 0, 5 do m[i][8] = bit(i) end
  m[7][8] = bit(6); m[8][8] = bit(7); m[8][7] = bit(8)
  for i = 9, 14 do m[8][14 - i] = bit(i) end
  for i = 0, 7 do m[8][n - 1 - i] = bit(i) end
  for i = 8, 14 do m[n - 15 + i][8] = bit(i) end
  m[n - 8][8] = true
  if v >= 7 then
    local vb = VERSION_BITS[v]
    for i = 0, 17 do
      local b = math.floor(vb / 2 ^ i) % 2 == 1
      local a, c = math.floor(i / 3), n - 11 + i % 3
      m[c][a] = b; m[a][c] = b
    end
  end
end

local function penalty(m, n)
  local p = 0
  for y = 0, n - 1 do
    local run, last = 0, nil
    for x = 0, n - 1 do
      if m[y][x] == last then run = run + 1 else
        if run >= 5 then p = p + run - 2 end
        run, last = 1, m[y][x]
      end
    end
    if run >= 5 then p = p + run - 2 end
  end
  for x = 0, n - 1 do
    local run, last = 0, nil
    for y = 0, n - 1 do
      if m[y][x] == last then run = run + 1 else
        if run >= 5 then p = p + run - 2 end
        run, last = 1, m[y][x]
      end
    end
    if run >= 5 then p = p + run - 2 end
  end
  for y = 0, n - 2 do for x = 0, n - 2 do
    local c = m[y][x]
    if m[y][x + 1] == c and m[y + 1][x] == c and m[y + 1][x + 1] == c then p = p + 3 end
  end end
  local dark = 0
  for y = 0, n - 1 do for x = 0, n - 1 do if m[y][x] then dark = dark + 1 end end end
  p = p + math.floor(math.abs(dark * 20 - n * n * 10) / (n * n)) * 10
  return p
end

-- Encode a string. Returns matrix (0-based rows/cols) and its size, or nil if too long.
function QR.encode(text, force_mask)
  local v
  for ver = 1, 10 do
    local overhead = 4 + (ver <= 9 and 8 or 16)
    if #text * 8 + overhead <= capacity(ver) * 8 then v = ver; break end
  end
  if not v then return nil, "too long for a QR code" end
  local n = 17 + 4 * v
  local codewords = interleave(encode_data(text, v), v)
  local best, best_p
  for mask = 0, 7 do
    local m, fixed = new_matrix(n)
    place_patterns(m, fixed, v, n)
    place_data(m, fixed, n, codewords)
    local fn = MASKS[mask]
    for y = 0, n - 1 do for x = 0, n - 1 do
      if not fixed[y][x] and fn(x, y) then m[y][x] = not m[y][x] end
    end end
    place_format(m, n, mask, v)
    local p = penalty(m, n)
    if force_mask then p = (mask == force_mask) and -1 or 1e9 end
    if not best_p or p < best_p then best, best_p = m, p end
  end
  return best, n
end

return QR
