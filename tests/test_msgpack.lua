local T = require("testlib")
local mp = require("zuno.msgpack")
local compat = require("zuno.compat")

local S = { shared = true }

local function rt(v) local d, e = mp.decode(mp.encode(v)); T.ok(e == nil, e); return d end

S["integers at every size boundary"] = function()
  for _, n in ipairs({ 0, 1, 127, 128, 255, 256, 65535, 65536, 4294967295, 4294967296, 2 ^ 53,
                       -1, -32, -33, -128, -129, -32768, -32769, -2147483648, -2147483649, -4294967296, -4294967297, -123456789012345, -(2 ^ 53) }) do
    T.eq(rt(n), n, "int " .. tostring(n))
  end
end

S["known encodings match the MessagePack spec"] = function()
  T.eq(compat.hex(mp.encode(0)), "00")
  T.eq(compat.hex(mp.encode(-1)), "ff")
  T.eq(compat.hex(mp.encode(200)), "ccc8")
  T.eq(compat.hex(mp.encode("a")), "a161")
  T.eq(compat.hex(mp.encode({ 1, 2 })), "920102")
  T.eq(compat.hex(mp.encode({ a = 1 })), "81a16101")
  T.eq(compat.hex(mp.encode(1.5)), "cb3ff8000000000000")
  T.eq(compat.hex(mp.encode(mp.bin("\1\2"))), "c4020102")
  T.eq(compat.hex(mp.encode(true)), "c3")
  T.eq(compat.hex(mp.encode({})), "90")
  T.eq(compat.hex(mp.encode(mp.map({}))), "80")
end

S["floats"] = function()
  for _, x in ipairs({ 0.5, -0.5, 3.14159, 1e300, -1e-300, 5e-324, 123456.789, 1 / 3 }) do
    T.eq(rt(x), x, "float " .. tostring(x))
  end
  T.eq(rt(math.huge), math.huge)
  local nan = rt(0 / 0); T.ok(nan ~= nan)
  -- float32 decode: 0xca 3fc00000 = 1.5
  T.eq(mp.decode("\202\63\192\0\0"), 1.5)
end

S["strings of every length class"] = function()
  for _, n in ipairs({ 0, 31, 32, 255, 256, 65535, 65536 }) do
    local s = string.rep("x", n)
    T.eq(rt(s), s, "len " .. n)
  end
  T.eq(rt("hej æøå 😀"), "hej æøå 😀")
end

S["nested structures"] = function()
  local v = { t = "state", channels = { { id = 1, name = "general" }, { id = 2, name = "lounge", kind = "voice" } },
              n = -5, f = 2.5, ok = true, list = { 1, "two", { three = 3 } } }
  T.same(rt(v), v)
  local big = {}; for i = 1, 70000 do big[i] = i % 7 end
  T.same(rt(big), big)
end

S["map keys are sorted so encoding is deterministic"] = function()
  T.eq(mp.encode({ b = 1, a = 2, c = 3 }), mp.encode({ c = 3, a = 2, b = 1 }))
end

S["decoder rejects truncated, trailing and hostile input"] = function()
  local good = mp.encode({ a = { 1, 2, 3 }, b = "hello" })
  for i = 1, #good - 1 do T.eq(mp.decode(good:sub(1, i)), nil, "truncated at " .. i) end
  T.eq(mp.decode(good .. "\0"), nil, "trailing byte")
  T.eq(mp.decode("\221\255\255\255\255"), nil, "huge array length")
  T.eq(mp.decode("\223\255\255\255\255"), nil, "huge map length")
  T.eq(mp.decode("\219\255\255\255\255abc"), nil, "huge str length")
  T.eq(mp.decode(string.rep("\145", 100) .. "\0"), nil, "deep nesting")
  T.eq(mp.decode("\193"), nil, "never-used byte")
  T.eq(mp.decode("\129\192\1"), nil, "nil map key")
  T.eq(mp.decode(""), nil, "empty")
end

S["fuzz: random bytes never crash the decoder"] = function()
  math.randomseed(1234)
  for _ = 1, 20000 do
    local n = math.random(0, 40)
    local b = {}
    for i = 1, n do b[i] = string.char(math.random(0, 255)) end
    local ok = pcall(mp.decode, table.concat(b))
    T.ok(ok, "decode raised")
  end
  -- mutate valid packets
  local base = mp.encode({ t = "send", ch = 1, body = "hello world", nonce = "abc" })
  for _ = 1, 20000 do
    local i = math.random(1, #base)
    local s = base:sub(1, i - 1) .. string.char(math.random(0, 255)) .. base:sub(i + 1)
    T.ok(pcall(mp.decode, s))
  end
end

return S
