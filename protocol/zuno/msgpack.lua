-- Pure-Lua MessagePack for Zuno (runs on LuaJIT and Lua 5.4).
--
-- Encoding rules:
--   * Lua strings encode as MessagePack str. Wrap raw bytes with mp.bin(s) to encode as bin.
--   * A table whose keys are exactly 1..n encodes as an array; an empty table encodes as an
--     array unless wrapped with mp.map({}). Everything else encodes as a map.
--   * Whole numbers encode as integers (up to 2^53), others as float64.
--   * mp.null encodes as nil inside arrays/maps where a hole is needed.
-- Decoding returns plain Lua values (str and bin both become strings).
-- The decoder never trusts lengths: sizes are checked against the input and a depth limit.
local compat = require("zuno.compat")

local mp = {}
local char, byte, floor, concat = string.char, string.byte, math.floor, table.concat

local BIN_MT = {}
local MAP_MT = { __mp_map = true }
local ARRAY_MT = { __mp_array = true }

function mp.bin(s) return setmetatable({ s = s }, BIN_MT) end
function mp.map(t) return setmetatable(t or {}, MAP_MT) end
function mp.array(t) return setmetatable(t or {}, ARRAY_MT) end
mp.null = setmetatable({}, { __tostring = function() return "mp.null" end })

---------------------------------------------------------------- byte helpers
local function be(n, bytes)
  local out = {}
  for i = bytes, 1, -1 do
    out[i] = char(n % 256)
    n = floor(n / 256)
  end
  return concat(out)
end

local function read_be(s, pos, bytes)
  local n = 0
  for i = 0, bytes - 1 do n = n * 256 + byte(s, pos + i) end
  return n
end

-- IEEE 754 double <-> 8 bytes, big endian (no string.pack / ffi dependency).
local function encode_double(x)
  if x ~= x then return "\127\248\0\0\0\0\0\0" end
  local sign = 0
  if x < 0 or (x == 0 and 1 / x < 0) then sign = 128; x = -x end
  if x == math.huge then return char(sign + 127, 240, 0, 0, 0, 0, 0, 0) end
  if x == 0 then return char(sign, 0, 0, 0, 0, 0, 0, 0) end
  local m, e = math.frexp(x) -- x = m * 2^e, 0.5 <= m < 1
  e = e + 1022
  if e <= 0 then -- subnormal
    m = m * 2 ^ (e + 52)
    e = 0
  else
    m = (m * 2 - 1) * 2 ^ 52
  end
  m = floor(m + 0.5)
  local hi = floor(m / 2 ^ 32)
  local lo = m - hi * 2 ^ 32
  return char(sign + floor(e / 16), (e % 16) * 16 + floor(hi / 65536)) .. be(hi % 65536, 2) .. be(lo, 4)
end

local function decode_double(s, pos)
  local b1, b2 = byte(s, pos, pos + 1)
  local sign = b1 >= 128 and -1 or 1
  local e = (b1 % 128) * 16 + floor(b2 / 16)
  local m = (b2 % 16) * 2 ^ 48 + read_be(s, pos + 2, 6)
  if e == 2047 then
    if m == 0 then return sign * math.huge end
    return 0 / 0
  end
  if e == 0 then return sign * m * 2 ^ -1074 end
  return sign * (1 + m / 2 ^ 52) * 2 ^ (e - 1023)
end

---------------------------------------------------------------- encoder
local encode_value

local function is_array(t)
  local mt = getmetatable(t)
  if mt == ARRAY_MT then return true, #t end
  if mt == MAP_MT then return false end
  local n = #t
  local count = 0
  for _ in pairs(t) do
    count = count + 1
    if count > n then return false end
  end
  return count == n, n
end

local function encode_str(s, buf, as_bin)
  local n = #s
  if as_bin then
    if n < 256 then buf[#buf + 1] = "\196" .. char(n)
    elseif n < 65536 then buf[#buf + 1] = "\197" .. be(n, 2)
    else buf[#buf + 1] = "\198" .. be(n, 4) end
  else
    if n < 32 then buf[#buf + 1] = char(0xa0 + n)
    elseif n < 256 then buf[#buf + 1] = "\217" .. char(n)
    elseif n < 65536 then buf[#buf + 1] = "\218" .. be(n, 2)
    else buf[#buf + 1] = "\219" .. be(n, 4) end
  end
  buf[#buf + 1] = s
end

local function encode_int(n, buf)
  if n >= 0 then
    if n < 128 then buf[#buf + 1] = char(n)
    elseif n < 256 then buf[#buf + 1] = "\204" .. char(n)
    elseif n < 65536 then buf[#buf + 1] = "\205" .. be(n, 2)
    elseif n < 4294967296 then buf[#buf + 1] = "\206" .. be(n, 4)
    else buf[#buf + 1] = "\207" .. be(n, 8) end
  else
    if n >= -32 then buf[#buf + 1] = char(256 + n)
    elseif n >= -128 then buf[#buf + 1] = "\208" .. char(256 + n)
    elseif n >= -32768 then buf[#buf + 1] = "\209" .. be(65536 + n, 2)
    elseif n >= -2147483648 then buf[#buf + 1] = "\210" .. be(4294967296 + n, 4)
    else
      -- int64 two's complement without exceeding double precision
      local hi = floor(n / 4294967296)
      local lo = n - hi * 4294967296
      buf[#buf + 1] = "\211" .. be(hi + 4294967296, 4) .. be(lo, 4)
    end
  end
end

encode_value = function(v, buf, depth)
  if depth > 64 then error("msgpack: nesting too deep", 0) end
  local t = type(v)
  if v == nil or v == mp.null then buf[#buf + 1] = "\192"
  elseif v == false then buf[#buf + 1] = "\194"
  elseif v == true then buf[#buf + 1] = "\195"
  elseif t == "number" then
    if compat.is_int(v) then encode_int(v, buf) else buf[#buf + 1] = "\203" .. encode_double(v) end
  elseif t == "string" then encode_str(v, buf, false)
  elseif t == "table" then
    if getmetatable(v) == BIN_MT then encode_str(v.s, buf, true); return end
    local arr, n = is_array(v)
    if arr then
      if n < 16 then buf[#buf + 1] = char(0x90 + n)
      elseif n < 65536 then buf[#buf + 1] = "\220" .. be(n, 2)
      else buf[#buf + 1] = "\221" .. be(n, 4) end
      for i = 1, n do encode_value(v[i], buf, depth + 1) end
    else
      local keys = {}
      for k in pairs(v) do keys[#keys + 1] = k end
      -- Sorted keys -> deterministic bytes (handy for tests and signatures).
      table.sort(keys, function(a, b)
        local ta, tb = type(a), type(b)
        if ta ~= tb then return ta < tb end
        return a < b
      end)
      local n2 = #keys
      if n2 < 16 then buf[#buf + 1] = char(0x80 + n2)
      elseif n2 < 65536 then buf[#buf + 1] = "\222" .. be(n2, 2)
      else buf[#buf + 1] = "\223" .. be(n2, 4) end
      for _, k in ipairs(keys) do
        encode_value(k, buf, depth + 1)
        encode_value(v[k], buf, depth + 1)
      end
    end
  else
    error("msgpack: cannot encode " .. t, 0)
  end
end

function mp.encode(v)
  local buf = {}
  encode_value(v, buf, 0)
  return concat(buf)
end

---------------------------------------------------------------- decoder
local MAX_DEPTH = 32

local function decode_value(s, pos, depth, len)
  if pos > len then error("msgpack: truncated", 0) end
  if depth > MAX_DEPTH then error("msgpack: nesting too deep", 0) end
  local c = byte(s, pos)
  local function need(n) if pos + n > len + 1 then error("msgpack: truncated", 0) end end

  local function read_str(n, at)
    if at + n - 1 > len then error("msgpack: truncated", 0) end
    return s:sub(at, at + n - 1), at + n
  end

  local function read_array(n, at)
    if n > len - at + 1 then error("msgpack: bad array length", 0) end
    local t = {}
    for i = 1, n do t[i], at = decode_value(s, at, depth + 1, len) end
    return t, at
  end

  local function read_map(n, at)
    if n * 2 > len - at + 1 then error("msgpack: bad map length", 0) end
    local t = {}
    for _ = 1, n do
      local k
      k, at = decode_value(s, at, depth + 1, len)
      if k == nil or (type(k) ~= "string" and type(k) ~= "number" and type(k) ~= "boolean") then
        error("msgpack: unsupported map key", 0)
      end
      if k ~= k then error("msgpack: NaN map key", 0) end
      t[k], at = decode_value(s, at, depth + 1, len)
    end
    return t, at
  end

  if c < 0x80 then return c, pos + 1 end
  if c >= 0xe0 then return c - 256, pos + 1 end
  if c >= 0xa0 and c <= 0xbf then return read_str(c - 0xa0, pos + 1) end
  if c >= 0x90 and c <= 0x9f then return read_array(c - 0x90, pos + 1) end
  if c >= 0x80 and c <= 0x8f then return read_map(c - 0x80, pos + 1) end

  if c == 0xc0 then return nil, pos + 1 end
  if c == 0xc2 then return false, pos + 1 end
  if c == 0xc3 then return true, pos + 1 end
  if c == 0xc4 or c == 0xd9 then need(2); return read_str(byte(s, pos + 1), pos + 2) end
  if c == 0xc5 or c == 0xda then need(3); return read_str(read_be(s, pos + 1, 2), pos + 3) end
  if c == 0xc6 or c == 0xdb then need(5); return read_str(read_be(s, pos + 1, 4), pos + 5) end
  if c == 0xca then -- float32
    need(5)
    local b1, b2, b3, b4 = byte(s, pos + 1, pos + 4)
    local sign = b1 >= 128 and -1 or 1
    local e = (b1 % 128) * 2 + floor(b2 / 128)
    local m = (b2 % 128) * 65536 + b3 * 256 + b4
    local v
    if e == 255 then v = (m == 0) and sign * math.huge or 0 / 0
    elseif e == 0 then v = sign * m * 2 ^ -149
    else v = sign * (1 + m / 2 ^ 23) * 2 ^ (e - 127) end
    return v, pos + 5
  end
  if c == 0xcb then need(9); return decode_double(s, pos + 1), pos + 9 end
  if c == 0xcc then need(2); return byte(s, pos + 1), pos + 2 end
  if c == 0xcd then need(3); return read_be(s, pos + 1, 2), pos + 3 end
  if c == 0xce then need(5); return read_be(s, pos + 1, 4), pos + 5 end
  if c == 0xcf then need(9); return read_be(s, pos + 1, 8), pos + 9 end
  if c == 0xd0 then need(2); local v = byte(s, pos + 1); return v >= 128 and v - 256 or v, pos + 2 end
  if c == 0xd1 then need(3); local v = read_be(s, pos + 1, 2); return v >= 32768 and v - 65536 or v, pos + 3 end
  if c == 0xd2 then need(5); local v = read_be(s, pos + 1, 4); return v >= 2147483648 and v - 4294967296 or v, pos + 5 end
  if c == 0xd3 then
    need(9)
    local hi, lo = read_be(s, pos + 1, 4), read_be(s, pos + 5, 4)
    if hi >= 2147483648 then hi = hi - 4294967296 end
    return hi * 4294967296 + lo, pos + 9
  end
  if c == 0xdc then need(3); return read_array(read_be(s, pos + 1, 2), pos + 3) end
  if c == 0xdd then need(5); return read_array(read_be(s, pos + 1, 4), pos + 5) end
  if c == 0xde then need(3); return read_map(read_be(s, pos + 1, 2), pos + 3) end
  if c == 0xdf then need(5); return read_map(read_be(s, pos + 1, 4), pos + 5) end
  error(("msgpack: unsupported type 0x%02x"):format(c), 0)
end

-- Decode one complete value. Returns value, or nil + error. Trailing bytes are an error.
function mp.decode(s)
  if type(s) ~= "string" then return nil, "msgpack: input must be a string" end
  local ok, v, pos = pcall(decode_value, s, 1, 0, #s)
  if not ok then return nil, v end
  if pos ~= #s + 1 then return nil, "msgpack: trailing bytes" end
  return v
end

return mp
