local T = require("testlib")
local C = require("zuno.crypto")
local compat = require("zuno.compat")
local hex, unhex = compat.hex, compat.unhex

local S = {}

S["BLAKE2b-512 of empty string (RFC 7693 test value)"] = function()
  T.eq(hex(C.blake2b("")), "786a02f742015903c6c6fd852552d272912f4740e15847618a86e217f71f5419d25e1031afee585313896444934eb04b903a685b1448b755d56f701afe9be2ce")
end

S["SHA-512 of 'abc' (FIPS 180-2)"] = function()
  T.eq(hex(C.sha512("abc")), "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f")
end

S["Ed25519 RFC 8032 test 1"] = function()
  local seed = unhex("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60")
  local pk = C.ed25519_public(seed)
  T.eq(hex(pk), "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a")
  local sig = C.ed25519_sign(seed, "")
  T.eq(hex(sig), "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b")
  T.ok(C.ed25519_verify(sig, pk, ""))
  T.ok(not C.ed25519_verify(sig, pk, "x"))
  T.eq(seed, unhex("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60"), "seed not wiped")
end

S["X25519 RFC 7748 6.1"] = function()
  local a = unhex("77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a")
  local b = unhex("5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb")
  T.eq(hex(C.x25519_public(a)), "8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a")
  T.eq(hex(C.x25519(a, C.x25519_public(b))), "4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742")
end

S["ChaCha20-Poly1305 RFC 8439 2.8.2"] = function()
  local key = unhex("808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f")
  local nonce = unhex("070000004041424344454647")
  local ad = unhex("50515253c0c1c2c3c4c5c6c7")
  local pt = "Ladies and Gentlemen of the class of '99: If I could offer you only one tip for the future, sunscreen would be it."
  local out = C.aead_encrypt(key, nonce, ad, pt)
  T.eq(hex(out:sub(-16)), "1ae10b594f09e26a7e902ecbd0600691", "tag")
  T.eq(hex(out:sub(1, 16)), "d31a8d34648e60db7b86afbc53ef7ec2", "first ciphertext block")
  T.eq(C.aead_decrypt(key, nonce, ad, out), pt)
  T.eq(C.aead_decrypt(key, nonce, ad .. "x", out), nil)
end

S["Ed25519 identity converts to a matching X25519 key pair"] = function()
  for _ = 1, 10 do
    local seed = C.ed25519_new_seed()
    local x_sk = C.ed25519_seed_to_x25519_secret(seed)
    T.eq(C.x25519_public(x_sk), C.ed25519_to_x25519_public(C.ed25519_public(seed)))
  end
end

S["random bytes differ"] = function()
  T.eq(#C.random(32), 32)
  T.ok(C.random(32) ~= C.random(32))
end

return S
