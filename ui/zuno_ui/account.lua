-- Account package (everything a device needs to be "you") and the .zunokey backup file.
--
-- .zunokey layout:
--   "ZUNOKEY" 0x01 | u32 BE memory (KiB) | u8 passes | 16-byte salt | XChaCha20-Poly1305 box
-- The box key is Argon2id(recovery key, salt). The header is the box's associated data,
-- so changing the parameters breaks the file instead of weakening it.
local mp = require("zuno.msgpack")
local compat = require("zuno.compat")

local A = {}

A.MAGIC = "ZUNOKEY\1"
A.KIB = 65536   -- 64 MiB
A.PASSES = 3

local ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ" -- Crockford base32: no I, L, O, U

-- 25 characters = 125 random bits, shown as K7QM-9XTD-4HPA-W2RE-8NVC
function A.new_recovery_key(C)
  local bytes = C.random(16)
  local bits, nbits, out = 0, 0, {}
  local i = 1
  while #out < 25 do
    if nbits < 5 then bits = bits * 256 + bytes:byte(i); i = i + 1; nbits = nbits + 8 end
    local shift = 2 ^ (nbits - 5)
    local v = math.floor(bits / shift)
    bits = bits - v * shift
    nbits = nbits - 5
    out[#out + 1] = ALPHABET:sub(v + 1, v + 1)
  end
  local s = table.concat(out)
  return s:sub(1, 5) .. "-" .. s:sub(6, 10) .. "-" .. s:sub(11, 15) .. "-" .. s:sub(16, 20) .. "-" .. s:sub(21, 25)
end

-- Accepts what people actually type: lower case, spaces, missing dashes, O for 0, I/L for 1.
function A.normalize_recovery_key(s)
  s = (s or ""):upper():gsub("[%s%-]", ""):gsub("O", "0"):gsub("[IL]", "1")
  if #s ~= 25 or s:find("[^" .. ALPHABET .. "]") then return nil end
  return s:sub(1, 5) .. "-" .. s:sub(6, 10) .. "-" .. s:sub(11, 15) .. "-" .. s:sub(16, 20) .. "-" .. s:sub(21, 25)
end

local function be32(n)
  return string.char(math.floor(n / 16777216) % 256, math.floor(n / 65536) % 256, math.floor(n / 256) % 256, n % 256)
end

-- The account as a table: { seed (32 bytes), name, theme, servers = { {address, key, name}, ... } }
function A.encode_package(acc)
  local servers = {}
  for _, e in ipairs(acc.servers or {}) do
    servers[#servers + 1] = { address = e.address, key = e.key, name = e.name }
  end
  -- the picture itself stays on the servers; the hash tells the new device it's already set
  return mp.encode({ v = 1, seed = mp.bin(acc.seed), name = acc.name, theme = acc.theme, servers = mp.array(servers),
                     avatar_hash = acc.avatar_hash })
end

function A.decode_package(bytes)
  local t = mp.decode(bytes)
  if type(t) ~= "table" or t.v ~= 1 or type(t.seed) ~= "string" or #t.seed ~= 32 then return nil, "not a Zuno account" end
  local servers = {}
  for _, e in ipairs(type(t.servers) == "table" and t.servers or {}) do
    if type(e) == "table" and type(e.address) == "string" then
      servers[#servers + 1] = { address = e.address, key = type(e.key) == "string" and e.key or nil,
                                name = type(e.name) == "string" and e.name or nil }
    end
  end
  return { seed = t.seed, name = type(t.name) == "string" and t.name or nil,
           theme = type(t.theme) == "string" and t.theme or nil, servers = servers,
           avatar_hash = type(t.avatar_hash) == "string" and #t.avatar_hash == 64 and t.avatar_hash or nil }
end

function A.export_file(C, acc, recovery_key, kib, passes)
  kib, passes = kib or A.KIB, passes or A.PASSES
  local salt = C.random(16)
  local header = A.MAGIC .. be32(kib) .. string.char(passes) .. salt
  local key = C.argon2id(recovery_key, salt, kib, passes, 32)
  return header .. C.seal(key, A.encode_package(acc), header)
end

-- Returns the account table, or nil + a message for people.
function A.import_file(C, bytes, recovery_input)
  if type(bytes) ~= "string" or bytes:sub(1, 8) ~= A.MAGIC or #bytes < 8 + 5 + 16 + 40 then
    return nil, "That isn't a Zuno account file (.zunokey)."
  end
  local rk = A.normalize_recovery_key(recovery_input)
  if not rk then return nil, "A recovery key is 25 letters and numbers, like K7QM9-XTD4H-PAW2R-E8NVC-3J6TK." end
  local b = { bytes:byte(9, 13) }
  local kib = ((b[1] * 256 + b[2]) * 256 + b[3]) * 256 + b[4]
  local passes = b[5]
  if kib < 8 or kib > 1048576 or passes < 1 or passes > 16 then return nil, "This account file is damaged." end
  local header = bytes:sub(1, 29)
  local salt = bytes:sub(14, 29)
  local key = C.argon2id(rk, salt, kib, passes, 32)
  local plain = C.open(key, bytes:sub(30), header)
  if not plain then return nil, "Wrong recovery key, or the file is damaged." end
  local acc, err = A.decode_package(plain)
  if not acc then return nil, err end
  return acc
end

-- Safe file name from a display name.
function A.file_name(name)
  local base = (name or "account"):gsub("[^%w%-_ ]", ""):gsub("%s+", "-")
  if base == "" then base = "account" end
  return base .. ".zunokey"
end

A.hex = compat.hex
return A
