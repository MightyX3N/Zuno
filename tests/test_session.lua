local T = require("testlib")
local C = require("zuno.crypto")
local Session = require("zuno.session")
local version = require("zuno.version")
local compat = require("zuno.compat")

local S = {}

-- Pump bytes between two sessions until quiet. Returns all events per side.
local function pump(a, b)
  local ea, eb = {}, {}
  for _ = 1, 20 do
    local moved = false
    local x = a:pull(); if x then moved = true; for _, e in ipairs(b:feed(x)) do eb[#eb + 1] = e end end
    local y = b:pull(); if y then moved = true; for _, e in ipairs(a:feed(y)) do ea[#ea + 1] = e end end
    if not moved then break end
  end
  return ea, eb
end

local function pair(copts, sopts)
  local server_seed = C.ed25519_new_seed()
  local client_seed = C.ed25519_new_seed()
  local c = Session.client(C, setmetatable(copts or {}, { __index = { identity_seed = client_seed, name = "patrick" } }))
  local s = Session.server(C, setmetatable(sopts or {}, { __index = { identity_seed = server_seed, name = "my-server" } }))
  return c, s, client_seed, server_seed
end

S["handshake, identities and packets both ways"] = function()
  local c, s, cseed, sseed = pair()
  c:start()
  local ec, es = pump(c, s)
  T.eq(ec[1].type, "ready"); T.eq(es[1].type, "ready")
  T.eq(ec[1].peer_key, compat.hex(C.ed25519_public(sseed)))
  T.eq(es[1].peer_key, compat.hex(C.ed25519_public(cseed)))
  T.eq(es[1].peer_name, "patrick"); T.eq(ec[1].server.name, "my-server")
  T.eq(ec[1].version, version.MAX)
  c:send({ t = "send", ch = 1, body = "hej" })
  s:send({ t = "msg", id = 7, body = "hej" })
  ec, es = pump(c, s)
  T.eq(es[1].packet.body, "hej"); T.eq(ec[1].packet.id, 7)
end

S["pinned server key: match works, mismatch stops before the client reveals itself"] = function()
  local c, s, _, sseed = pair()
  local real = compat.hex(C.ed25519_public(sseed))
  c.opts.pinned_key = real
  c:start(); local ec = pump(c, s); T.eq(ec[1].type, "ready")

  local c2, s2 = pair({ pinned_key = string.rep("ab", 32) })
  c2:start()
  local ec2, es2 = pump(c2, s2)
  T.eq(ec2[1].type, "error"); T.eq(ec2[1].code, "server_key_changed")
  T.ok(ec2[1].new_key and #ec2[1].new_key == 64)
  T.eq(#es2, 0, "server never got message 3")
  T.eq(c2:pull(), nil)
end

S["version mismatch is reported to both sides"] = function()
  local c, s = pair({ min = 5, max = 6 })        -- client newer than server
  c:start()
  local ec, es = pump(c, s)
  T.eq(es[1].code, "server_outdated"); T.eq(ec[1].code, "server_outdated")
  T.eq(ec[1].server_max, version.MAX)
  local c2, s2 = pair({ min = 0, max = 0 })      -- client older than server
  c2:start()
  local ec2 = pump(c2, s2)
  T.eq(ec2[1].code, "client_outdated")
end

S["a client claiming someone else's key is rejected"] = function()
  local c, s = pair()
  -- Make the client announce a different public key than the one it proves with Noise.
  c.my_key = compat.hex(C.ed25519_public(C.ed25519_new_seed()))
  c:start()
  local _, es = pump(c, s)
  T.eq(es[1].type, "error"); T.eq(es[1].code, "handshake_failed")
end

S["garbage and oversized handshake frames close the session"] = function()
  local _, s = pair()
  local ev = s:feed("\0\0\16\0" .. string.rep("x", 4096))
  T.eq(ev[1].type, "error")
  local _, s2 = pair()
  ev = s2:feed("\0\0\0\5hello")
  T.eq(ev[1].type, "error"); T.ok(s2:is_closed())
end

S["tampered transport frame closes the session"] = function()
  local c, s = pair()
  c:start(); pump(c, s)
  c:send({ t = "sync" })
  local bytes = c:pull()
  bytes = bytes:sub(1, -2) .. string.char((bytes:byte(-1) + 1) % 256)
  local ev = s:feed(bytes)
  T.eq(ev[1].type, "error"); T.eq(ev[1].code, "protocol_error")
end

S["too-big packet is refused instead of sent"] = function()
  local c, s = pair()
  c:start(); pump(c, s)
  T.eq(c:send({ t = "x", body = string.rep("a", 70000) }), false)
  T.eq(c:send({ t = "x", body = string.rep("a", 60000) }), true)
end

return S
