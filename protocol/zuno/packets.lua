-- Packet definitions shared by server and clients (protocol version 1).
--
-- Every packet is a MessagePack map with a type field `t`. Client requests may carry
-- `q` (request id); errors caused by that request echo it back as `re`.
-- Users are identified by the hex of their Ed25519 public key (64 chars).
local compat = require("zuno.compat")

local P = {}

P.LIMITS = {
  message_chars = 4000,   -- code points per message
  name_chars = 32,        -- display names, channel names
  topic_chars = 200,
  history_page = 50,
  since_max = 500,        -- max changes returned on resume before asking for a full reload
}

-- Field specs:  "int", "bool", "str:N" (N bytes max, valid UTF-8), "text:N" (N code points,
-- valid UTF-8, not blank), "name" (1..32 chars, no control chars), "key" (64 hex chars),
-- "enum:a|b", prefix "?" = optional.
P.client = {
  ping          = { n = "?int" },
  sync          = {},
  history       = { ch = "int", before = "?int", limit = "?int" },
  since         = { ch = "int", rev = "int" },
  send          = { ch = "int", body = "text:4000", nonce = "?str:40" },
  edit          = { id = "int", body = "text:4000" },
  delete        = { id = "int" },
  typing        = { ch = "int" },
  profile       = { name = "name" },
  claim         = { code = "str:64" },
  channel_create = { name = "channel", kind = "enum:text|voice", topic = "?str:200" },
  channel_update = { ch = "int", name = "?channel", topic = "?str:200" },
  channel_delete = { ch = "int" },
  -- device linking relay (5.1): the server only forwards opaque, end-to-end encrypted bytes
  link_open     = {},
  link_join     = { sid = "str:16" },
  link_data     = { sid = "str:16", d = "bin:60000" },
  link_close    = { sid = "str:16" },
  -- "Replace my key" (5.3): signed by the old key, moves the membership to the new key
  rekey         = { new = "key", sig = "bin:64" },
}

-- What the old key signs for a key hand-over on one server.
function P.rekey_message(server_key, new_key) return "zuno-rekey-v1:" .. server_key .. ":" .. new_key end

-- What a guest connection (a device that is being linked, not a member) may send.
P.GUEST_ALLOWED = { ping = true, link_join = true, link_data = true, link_close = true }

-- Server packets (documented here; the client checks their basic shape).
P.server = {
  pong = true, state = true, messages = true, msg = true, typing = true, presence = true,
  member = true, channel = true, channel_removed = true, err = true, notice = true,
  link_opened = true, link_joined = true, link_data = true, link_event = true, rekeyed = true, member_rekeyed = true,
}

-- Error codes sent in `err` packets.
P.ERR = {
  bad_packet = "bad_packet", rate_limited = "rate_limited", not_found = "not_found",
  forbidden = "forbidden", too_long = "too_long", invalid = "invalid", exists = "exists",
}

local function check_field(spec, v)
  local optional = spec:sub(1, 1) == "?"
  if optional then spec = spec:sub(2) end
  if v == nil then return optional end
  local kind, arg = spec:match("^(%a+):?(.*)$")
  if kind == "int" then
    return compat.is_int(v) and v >= -9007199254740991 and v <= 9007199254740991
  elseif kind == "bool" then
    return type(v) == "boolean"
  elseif kind == "str" then
    return type(v) == "string" and #v <= tonumber(arg) and compat.valid_utf8(v)
  elseif kind == "bin" then
    return type(v) == "string" and #v <= tonumber(arg)
  elseif kind == "text" then
    return type(v) == "string" and #v <= tonumber(arg) * 4 and compat.valid_utf8(v)
       and compat.utf8_len(v) <= tonumber(arg) and v:find("%S") ~= nil
  elseif kind == "name" then
    return type(v) == "string" and compat.valid_utf8(v) and not v:find("[%c]")
       and v:find("%S") ~= nil and compat.utf8_len(v) <= P.LIMITS.name_chars and #v <= 128
  elseif kind == "channel" then
    return type(v) == "string" and #v >= 1 and #v <= 32 and v:match("^[%w%-_]+$") ~= nil
  elseif kind == "key" then
    return type(v) == "string" and #v == 64 and not v:find("[^0-9a-f]")
  elseif kind == "enum" then
    if type(v) ~= "string" then return false end
    for opt in arg:gmatch("[^|]+") do if opt == v then return true end end
    return false
  end
  return false
end
P.check_field = check_field

-- Validate a decoded client packet. Returns true, or false + reason.
-- Unknown fields are rejected so mistakes show up early.
function P.validate_client(pkt)
  if type(pkt) ~= "table" then return false, "not a map" end
  local spec = P.client[pkt.t]
  if not spec then return false, "unknown packet type" end
  if pkt.q ~= nil and not check_field("int", pkt.q) then return false, "bad q" end
  for k, v in pairs(pkt) do
    if k ~= "t" and k ~= "q" then
      local s = spec[k]
      if not s then return false, "unknown field " .. tostring(k) end
      if not check_field(s, v) then return false, "bad field " .. k end
    end
  end
  for k, s in pairs(spec) do
    if s:sub(1, 1) ~= "?" and pkt[k] == nil then return false, "missing field " .. k end
  end
  return true
end

-- Clean user text: normalise line endings, trim trailing whitespace, cap blank lines.
function P.clean_text(s)
  s = s:gsub("\r\n?", "\n"):gsub("[ \t]+\n", "\n"):gsub("\n\n\n+", "\n\n")
  return (s:gsub("^%s*\n", ""):gsub("%s+$", ""))
end

-- Short, readable fingerprint of a key (hex or raw): groups of 4, first 20 hex chars.
function P.fingerprint(key)
  local h = #key == 32 and compat.hex(key) or key
  return (h:sub(1, 20):upper():gsub("(%x%x%x%x)", "%1 "):gsub(" $", ""))
end

return P
