local T = require("testlib")
local P = require("zuno.packets")
local version = require("zuno.version")

local S = { shared = true }

S["valid packets pass"] = function()
  T.ok(P.validate_client({ t = "send", ch = 1, body = "hi", nonce = "n1", q = 3 }))
  T.ok(P.validate_client({ t = "history", ch = 1 }))
  T.ok(P.validate_client({ t = "sync" }))
  T.ok(P.validate_client({ t = "profile", name = "patrick" }))
  T.ok(P.validate_client({ t = "channel_create", name = "lua-dev", kind = "text" }))
  T.ok(P.validate_client({ t = "send", ch = 1, body = string.rep("æ", 4000) }))
end

S["invalid packets fail"] = function()
  local bad = {
    { t = "nope" },
    { t = "send", ch = 1 },                                   -- missing body
    { t = "send", ch = "1", body = "x" },                     -- wrong type
    { t = "send", ch = 1.5, body = "x" },
    { t = "send", ch = 1, body = "   " },                     -- blank
    { t = "send", ch = 1, body = string.rep("a", 4001) },     -- too long
    { t = "send", ch = 1, body = "\255" },                    -- bad utf8
    { t = "send", ch = 1, body = "x", extra = 1 },            -- unknown field
    { t = "profile", name = "a\nb" },                         -- control char
    { t = "profile", name = string.rep("n", 33) },
    { t = "channel_create", name = "has space", kind = "text" },
    { t = "channel_create", name = "ok", kind = "video" },
    "string",
  }
  for i, p in ipairs(bad) do T.ok(not P.validate_client(p), "packet " .. i .. " should fail") end
end

S["clean_text"] = function()
  T.eq(P.clean_text("  hi  \r\n\r\n\r\n\r\nthere \n"), "  hi\n\nthere")
end

S["version negotiation"] = function()
  T.eq(version.negotiate(1, 3, 2, 5), 3)
  T.eq(version.negotiate(1, 1, 1, 1), 1)
  local v, why = version.negotiate(3, 4, 1, 2); T.eq(v, nil); T.eq(why, "client_outdated")
  v, why = version.negotiate(1, 2, 3, 4); T.eq(v, nil); T.eq(why, "server_outdated")
end

S["fingerprint format"] = function()
  T.eq(P.fingerprint(string.rep("ab", 32)), "ABAB ABAB ABAB ABAB ABAB")
end

return S
