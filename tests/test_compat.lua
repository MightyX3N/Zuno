local T = require("testlib")
local compat = require("zuno.compat")

local S = { shared = true }

S["bit operations"] = function()
  T.eq(compat.bxor(0xF0, 0x3C), 0xCC)
  T.eq(compat.band(0xF0, 0x3C), 0x30)
  T.eq(compat.bor(0xF0, 0x0F), 0xFF)
  T.eq(compat.xor_bytes("\1\2\3", "\1\0\255"), "\0\2\252")
end

S["hex"] = function()
  T.eq(compat.hex("\0\255a"), "00ff61")
  T.eq(compat.unhex("00ff61"), "\0\255a")
  T.eq(compat.unhex("0g"), nil)
  T.eq(compat.unhex("abc"), nil)
end

S["utf8 validation"] = function()
  T.ok(compat.valid_utf8("hej æøå 😀"))
  T.ok(not compat.valid_utf8("\192\128"), "overlong")
  T.ok(not compat.valid_utf8("\237\160\128"), "surrogate")
  T.ok(not compat.valid_utf8("\244\144\128\128"), "above U+10FFFF")
  T.ok(not compat.valid_utf8("abc\195"), "truncated")
  T.ok(not compat.valid_utf8("\255"))
  T.eq(compat.utf8_len("æøå😀a"), 5)
end

S["is_int"] = function()
  T.ok(compat.is_int(5)); T.ok(compat.is_int(-3)); T.ok(not compat.is_int(1.5))
  T.ok(not compat.is_int("5")); T.ok(not compat.is_int(math.huge)); T.ok(not compat.is_int(0 / 0))
end

return S
