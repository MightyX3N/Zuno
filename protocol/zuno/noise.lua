-- Noise_XX_25519_ChaChaPoly_BLAKE2b (Noise Protocol Framework, revision 34).
--
--   XX:  -> e
--        <- e, ee, s, es
--        -> s, se
--
-- Both sides prove they own their static X25519 key. Zuno uses each side's
-- Ed25519 identity converted to X25519 as the static key (see session.lua).
-- Needs a crypto backend with: x25519, x25519_public, x25519_keypair, blake2b,
-- aead_encrypt, aead_decrypt (protocol/zuno/crypto.lua on native).
local compat = require("zuno.compat")

local Noise = {}
Noise.PROTOCOL_NAME = "Noise_XX_25519_ChaChaPoly_BLAKE2b"
local HASHLEN, BLOCKLEN, DHLEN = 64, 128, 32
local MAX_MESSAGE = 65535
local MAX_NONCE = 2 ^ 53 -- far more than any connection will send; guards float precision

local function hmac(C, key, data)
  if #key > BLOCKLEN then key = C.blake2b(key, HASHLEN) end
  key = key .. string.rep("\0", BLOCKLEN - #key)
  local ipad = compat.xor_bytes(key, string.rep("\54", BLOCKLEN))
  local opad = compat.xor_bytes(key, string.rep("\92", BLOCKLEN))
  return C.blake2b(opad .. C.blake2b(ipad .. data, HASHLEN), HASHLEN)
end

local function hkdf(C, ck, ikm, n)
  local temp = hmac(C, ck, ikm)
  local o1 = hmac(C, temp, "\1")
  local o2 = hmac(C, temp, o1 .. "\2")
  if n == 2 then return o1, o2 end
  return o1, o2, hmac(C, temp, o2 .. "\3")
end

local function nonce_bytes(n)
  local b = { "\0\0\0\0" }
  for i = 1, 8 do
    b[#b + 1] = string.char(n % 256)
    n = math.floor(n / 256)
  end
  return table.concat(b)
end

---------------------------------------------------------------- CipherState
local Cipher = {}
Cipher.__index = Cipher

function Noise.cipher(C, key)
  return setmetatable({ C = C, k = key, n = 0 }, Cipher)
end

function Cipher:has_key() return self.k ~= nil end

function Cipher:encrypt(ad, pt)
  if not self.k then return pt end
  assert(self.n < MAX_NONCE, "noise: nonce exhausted")
  local out = self.C.aead_encrypt(self.k, nonce_bytes(self.n), ad, pt)
  self.n = self.n + 1
  return out
end

-- Returns plaintext or nil (authentication failure). Nonce only advances on success.
function Cipher:decrypt(ad, ct)
  if not self.k then return ct end
  assert(self.n < MAX_NONCE, "noise: nonce exhausted")
  local pt = self.C.aead_decrypt(self.k, nonce_bytes(self.n), ad, ct)
  if pt == nil then return nil end
  self.n = self.n + 1
  return pt
end

---------------------------------------------------------------- SymmetricState
local Sym = {}
Sym.__index = Sym

local function new_symmetric(C)
  local name = Noise.PROTOCOL_NAME
  local h = #name <= HASHLEN and (name .. string.rep("\0", HASHLEN - #name)) or C.blake2b(name, HASHLEN)
  return setmetatable({ C = C, h = h, ck = h, cs = Noise.cipher(C, nil) }, Sym)
end

function Sym:mix_hash(data) self.h = self.C.blake2b(self.h .. data, HASHLEN) end

function Sym:mix_key(ikm)
  local ck, tk = hkdf(self.C, self.ck, ikm, 2)
  self.ck = ck
  self.cs = Noise.cipher(self.C, tk:sub(1, 32))
end

function Sym:encrypt_and_hash(pt)
  local ct = self.cs:encrypt(self.h, pt)
  self:mix_hash(ct)
  return ct
end

function Sym:decrypt_and_hash(ct)
  local pt = self.cs:decrypt(self.h, ct)
  if pt == nil then return nil end
  self:mix_hash(ct)
  return pt
end

function Sym:split()
  local k1, k2 = hkdf(self.C, self.ck, "", 2)
  return Noise.cipher(self.C, k1:sub(1, 32)), Noise.cipher(self.C, k2:sub(1, 32))
end

---------------------------------------------------------------- HandshakeState (XX only)
local HS = {}
HS.__index = HS

-- opts: { initiator = bool, prologue = string, s = static secret (32), e = optional fixed ephemeral secret (tests only) }
function Noise.handshake(C, opts)
  local self = setmetatable({ C = C, initiator = opts.initiator, step = 1 }, HS)
  self.sym = new_symmetric(C)
  self.sym:mix_hash(opts.prologue or "")
  self.s_sk = assert(opts.s, "noise: static key required")
  self.s_pk = C.x25519_public(self.s_sk)
  self.fixed_e = opts.e
  return self
end

function HS:_new_ephemeral()
  if self.fixed_e then
    self.e_sk = self.fixed_e
    self.e_pk = self.C.x25519_public(self.e_sk)
  else
    self.e_sk, self.e_pk = self.C.x25519_keypair()
  end
end

function HS:_dh(sk, pk) return self.C.x25519(sk, pk) end

-- Whose turn: true if this side writes the next handshake message.
function HS:my_turn()
  if self.step > 3 then return false end
  return (self.step % 2 == 1) == self.initiator
end

function HS:done() return self.step > 3 end

-- Write the next handshake message carrying payload. Returns message bytes.
function HS:write(payload)
  assert(self:my_turn(), "noise: not our turn to write")
  payload = payload or ""
  local sym, out = self.sym, {}
  if self.step == 1 then           -- -> e
    self:_new_ephemeral()
    out[#out + 1] = self.e_pk; sym:mix_hash(self.e_pk)
  elseif self.step == 2 then       -- <- e, ee, s, es
    self:_new_ephemeral()
    out[#out + 1] = self.e_pk; sym:mix_hash(self.e_pk)
    sym:mix_key(self:_dh(self.e_sk, self.re))
    out[#out + 1] = sym:encrypt_and_hash(self.s_pk)
    sym:mix_key(self:_dh(self.s_sk, self.re))
  else                             -- -> s, se
    out[#out + 1] = sym:encrypt_and_hash(self.s_pk)
    sym:mix_key(self:_dh(self.s_sk, self.re))
  end
  out[#out + 1] = sym:encrypt_and_hash(payload)
  local msg = table.concat(out)
  assert(#msg <= MAX_MESSAGE, "noise: message too large")
  self.step = self.step + 1
  return msg
end

-- Read the next handshake message. Returns payload, or nil + error string.
function HS:read(msg)
  if self:my_turn() or self:done() then return nil, "unexpected handshake message" end
  if #msg > MAX_MESSAGE then return nil, "handshake message too large" end
  local sym, pos = self.sym, 1
  local function take(n)
    if pos + n - 1 > #msg then return nil end
    local s = msg:sub(pos, pos + n - 1); pos = pos + n; return s
  end
  local function take_rs()
    local n = DHLEN + (sym.cs:has_key() and 16 or 0)
    local ct = take(n); if not ct then return nil, "short handshake message" end
    local rs = sym:decrypt_and_hash(ct); if not rs then return nil, "handshake decryption failed" end
    self.rs = rs
    return true
  end
  if self.step == 1 then           -- responder reads: e
    self.re = take(DHLEN); if not self.re then return nil, "short handshake message" end
    sym:mix_hash(self.re)
  elseif self.step == 2 then       -- initiator reads: e, ee, s, es
    self.re = take(DHLEN); if not self.re then return nil, "short handshake message" end
    sym:mix_hash(self.re)
    sym:mix_key(self:_dh(self.e_sk, self.re))
    local ok, err = take_rs(); if not ok then return nil, err end
    sym:mix_key(self:_dh(self.e_sk, self.rs))
  else                             -- responder reads: s, se
    local ok, err = take_rs(); if not ok then return nil, err end
    sym:mix_key(self:_dh(self.e_sk, self.rs))
  end
  local payload = sym:decrypt_and_hash(msg:sub(pos))
  if payload == nil then return nil, "handshake decryption failed" end
  self.step = self.step + 1
  return payload
end

-- After the third message: returns send_cipher, recv_cipher, handshake_hash.
function HS:split()
  assert(self:done(), "noise: handshake not finished")
  local c1, c2 = self.sym:split()
  self.e_sk, self.s_sk, self.fixed_e = nil, nil, nil
  if self.initiator then return c1, c2, self.sym.h end
  return c2, c1, self.sym.h
end

Noise.MAX_MESSAGE = MAX_MESSAGE
return Noise
