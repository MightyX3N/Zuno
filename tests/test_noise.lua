local T = require("testlib")
local C = require("zuno.crypto")
local Noise = require("zuno.noise")
local compat = require("zuno.compat")
local hex, unhex = compat.hex, compat.unhex

local S = {}

-- Official cacophony vector: every handshake and transport message must match byte for byte.
S["cacophony XX vector"] = function()
  local vectors = dofile("tests/vectors/noise_xx.lua")
  T.ok(#vectors >= 1, "no vectors")
  for _, v in ipairs(vectors) do
    local init = Noise.handshake(C, { initiator = true, prologue = unhex(v.init_prologue),
      s = unhex(v.init_static), e = unhex(v.init_ephemeral) })
    local resp = Noise.handshake(C, { initiator = false, prologue = unhex(v.resp_prologue),
      s = unhex(v.resp_static), e = unhex(v.resp_ephemeral) })
    local i_send, i_recv, r_send, r_recv
    for idx, m in ipairs(v.messages) do
      local payload = unhex(m.payload)
      local sender_is_init = (idx % 2 == 1)
      local ct, got
      if idx <= 3 then
        local w, r = sender_is_init and init or resp, sender_is_init and resp or init
        ct = w:write(payload)
        got = r:read(ct)
        if idx == 3 then
          i_send, i_recv = init:split()
          r_send, r_recv = resp:split()
          T.eq(hex(init.sym.h), v.handshake_hash, "handshake hash")
        end
      else
        local sc, rc = sender_is_init and i_send or r_send, sender_is_init and r_recv or i_recv
        ct = sc:encrypt("", payload)
        got = rc:decrypt("", ct)
      end
      T.eq(hex(ct), m.ciphertext, "message " .. idx .. " ciphertext")
      T.eq(got, payload, "message " .. idx .. " payload")
    end
  end
end

S["random keys round trip and both sides see each other's static key"] = function()
  local a_s, b_s = C.random(32), C.random(32)
  local a = Noise.handshake(C, { initiator = true, prologue = "zuno", s = a_s })
  local b = Noise.handshake(C, { initiator = false, prologue = "zuno", s = b_s })
  T.eq(b:read(a:write("hi")), "hi")
  T.eq(a:read(b:write("hello")), "hello")
  T.eq(b:read(a:write("")), "")
  T.eq(a.rs, C.x25519_public(b_s)); T.eq(b.rs, C.x25519_public(a_s))
  local as, ar, ah = a:split(); local bs, br, bh = b:split()
  T.eq(ah, bh, "same handshake hash")
  for i = 1, 5 do
    T.eq(br:decrypt("", as:encrypt("", "msg" .. i)), "msg" .. i)
    T.eq(ar:decrypt("", bs:encrypt("", "reply" .. i)), "reply" .. i)
  end
end

S["tampered or replayed messages are rejected"] = function()
  local a = Noise.handshake(C, { initiator = true, s = C.random(32) })
  local b = Noise.handshake(C, { initiator = false, s = C.random(32) })
  b:read(a:write("")); local m2 = b:write("")
  local bad = m2:sub(1, 40) .. string.char((m2:byte(41) + 1) % 256) .. m2:sub(42)
  local p, err = a:read(bad)
  T.eq(p, nil); T.ok(err)
  -- untouched message still works on a fresh initiator state? (state unchanged except failure) -> use new pair
  local a2 = Noise.handshake(C, { initiator = true, s = C.random(32) })
  local b2 = Noise.handshake(C, { initiator = false, s = C.random(32) })
  b2:read(a2:write("")); a2:read(b2:write("")); b2:read(a2:write(""))
  local s, _ = a2:split(); local _, r = b2:split()
  local ct = s:encrypt("", "once")
  T.eq(r:decrypt("", ct), "once")
  T.eq(r:decrypt("", ct), nil, "replay must fail")
end

S["prologue mismatch fails"] = function()
  local a = Noise.handshake(C, { initiator = true, prologue = "zuno/1", s = C.random(32) })
  local b = Noise.handshake(C, { initiator = false, prologue = "other", s = C.random(32) })
  b:read(a:write(""))
  local p = a:read(b:write(""))
  T.eq(p, nil)
end

return S
