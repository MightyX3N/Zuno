-- Small helpers so shared Zuno code runs on both LuaJIT (Lua 5.1) and Lua 5.4 (Wasmoon).
-- Rule for shared code: no goto, no // or bitwise operators, no integer-only assumptions.
-- Use the functions here instead.
local compat = {}

compat.unpack = table.unpack or unpack
compat.is_luajit = type(jit) == "table"

local ok_bit, bitlib = pcall(require, "bit")
if ok_bit and bitlib then
  compat.band, compat.bor, compat.bxor = bitlib.band, bitlib.bor, bitlib.bxor
  compat.lshift, compat.rshift = bitlib.lshift, bitlib.rshift
else
  -- Lua 5.3+: compile the operators at runtime so this file still parses on 5.1.
  local f = assert((loadstring or load)([[
    return function(a, b) return a & b end,
           function(a, b) return a | b end,
           function(a, b) return a ~ b end,
           function(a, n) return a << n end,
           function(a, n) return a >> n end
  ]]))
  compat.band, compat.bor, compat.bxor, compat.lshift, compat.rshift = f()
end

-- True when n is a whole number that fits in a double without loss.
function compat.is_int(n)
  return type(n) == "number" and n == math.floor(n) and n >= -9007199254740992 and n <= 9007199254740992
end

-- Integer division / modulo that work the same everywhere.
function compat.idiv(a, b) return math.floor(a / b) end

-- XOR two equal-length byte strings.
function compat.xor_bytes(a, b)
  assert(#a == #b, "xor_bytes: length mismatch")
  local out, bx = {}, compat.bxor
  for i = 1, #a do out[i] = string.char(bx(a:byte(i), b:byte(i))) end
  return table.concat(out)
end

function compat.hex(s)
  return (s:gsub(".", function(c) return string.format("%02x", c:byte()) end))
end

function compat.unhex(h)
  if #h % 2 ~= 0 or h:find("[^%x]") then return nil end
  return (h:gsub("%x%x", function(x) return string.char(tonumber(x, 16)) end))
end

-- Strict UTF-8 check (rejects overlongs, surrogates and > U+10FFFF).
function compat.valid_utf8(s)
  local i, n = 1, #s
  while i <= n do
    local c = s:byte(i)
    local len, min
    if c < 0x80 then len, min = 1, 0
    elseif c >= 0xC2 and c <= 0xDF then len, min = 2, 0x80
    elseif c >= 0xE0 and c <= 0xEF then len, min = 3, 0x800
    elseif c >= 0xF0 and c <= 0xF4 then len, min = 4, 0x10000
    else return false end
    if i + len - 1 > n then return false end
    local cp = len == 1 and c or (c % (2 ^ (7 - len)))
    for j = 1, len - 1 do
      local cc = s:byte(i + j)
      if cc < 0x80 or cc > 0xBF then return false end
      cp = cp * 64 + (cc - 0x80)
    end
    if cp < min or cp > 0x10FFFF or (cp >= 0xD800 and cp <= 0xDFFF) then return false end
    i = i + len
  end
  return true
end

-- Number of UTF-8 code points (assumes valid UTF-8).
function compat.utf8_len(s)
  local _, count = s:gsub("[^\128-\191]", "")
  return count
end

-- Byte position where code point number n starts (n >= 1), or #s + 1 past the end.
function compat.utf8_offset(s, n)
  local count = 0
  for i = 1, #s do
    local c = s:byte(i)
    if c < 0x80 or c >= 0xC0 then
      count = count + 1
      if count == n then return i end
    end
  end
  return #s + 1
end

-- Cut to at most n code points.
function compat.utf8_sub(s, n)
  return s:sub(1, compat.utf8_offset(s, n + 1) - 1)
end

return compat
