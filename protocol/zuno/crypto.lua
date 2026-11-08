-- Native crypto for Zuno (LuaJIT FFI over Monocypher). Server and LÖVE client use this.
-- The browser client will provide the same functions from JS/WASM.
--
-- Every function takes and returns Lua strings of raw bytes.
local ffi = require("ffi")

ffi.cdef[[
void crypto_wipe(void *secret, size_t size);
typedef struct { uint64_t counter; uint8_t key[32]; uint8_t nonce[8]; } crypto_aead_ctx;
void crypto_aead_init_ietf(crypto_aead_ctx *ctx, const uint8_t key[32], const uint8_t nonce[12]);
void crypto_aead_write(crypto_aead_ctx *ctx, uint8_t *cipher_text, uint8_t mac[16],
                       const uint8_t *ad, size_t ad_size, const uint8_t *plain_text, size_t text_size);
int  crypto_aead_read(crypto_aead_ctx *ctx, uint8_t *plain_text, const uint8_t mac[16],
                      const uint8_t *ad, size_t ad_size, const uint8_t *cipher_text, size_t text_size);
void crypto_aead_lock(uint8_t *cipher_text, uint8_t mac[16], const uint8_t key[32], const uint8_t nonce[24],
                      const uint8_t *ad, size_t ad_size, const uint8_t *plain_text, size_t text_size);
int  crypto_aead_unlock(uint8_t *plain_text, const uint8_t mac[16], const uint8_t key[32], const uint8_t nonce[24],
                        const uint8_t *ad, size_t ad_size, const uint8_t *cipher_text, size_t text_size);
void crypto_blake2b(uint8_t *hash, size_t hash_size, const uint8_t *message, size_t message_size);
void crypto_x25519_public_key(uint8_t public_key[32], const uint8_t secret_key[32]);
void crypto_x25519(uint8_t raw_shared_secret[32], const uint8_t your_secret_key[32], const uint8_t their_public_key[32]);
void crypto_eddsa_to_x25519(uint8_t x25519[32], const uint8_t eddsa[32]);
void crypto_sha512(uint8_t hash[64], const uint8_t *message, size_t message_size);
void crypto_ed25519_key_pair(uint8_t secret_key[64], uint8_t public_key[32], uint8_t seed[32]);
void crypto_ed25519_sign(uint8_t signature[64], const uint8_t secret_key[64], const uint8_t *message, size_t message_size);
int  crypto_ed25519_check(const uint8_t signature[64], const uint8_t public_key[32], const uint8_t *message, size_t message_size);
]]

local M = {}
local lib

local function candidates()
  local list = {}
  local env = os.getenv and os.getenv("ZUNO_NATIVE")
  if env and env ~= "" then list[#list + 1] = env end
  if M.search_paths then for _, p in ipairs(M.search_paths) do list[#list + 1] = p end end
  if ffi.os == "Windows" then
    list[#list + 1] = "zunocrypto"
    list[#list + 1] = "build/native/win64/zunocrypto.dll"
  else
    list[#list + 1] = "build/native/linux-x64/libzunocrypto.so"
    list[#list + 1] = "./libzunocrypto.so"
    list[#list + 1] = "zunocrypto"
  end
  return list
end

-- Load the library. Callers can set M.search_paths = {...} first (full paths tried in order).
function M.load()
  if lib then return lib end
  local errs = {}
  for _, path in ipairs(candidates()) do
    local ok, l = pcall(ffi.load, path)
    if ok then lib = l; return lib end
    errs[#errs + 1] = path .. ": " .. tostring(l)
  end
  error("could not load the Zuno crypto library (zunocrypto):\n  " .. table.concat(errs, "\n  "))
end

local function L() return lib or M.load() end
local u8 = function(n) return ffi.new("uint8_t[?]", n) end
local str = function(buf, n) return ffi.string(buf, n) end

local function check_len(s, n, what)
  if type(s) ~= "string" or #s ~= n then error(what .. " must be " .. n .. " bytes", 3) end
end

-- Secure random bytes from the operating system.
local rng_file, rtl_gen_random
function M.random(n)
  if ffi.os == "Windows" then
    if not rtl_gen_random then
      ffi.cdef("int __stdcall SystemFunction036(void *buf, unsigned long len);")
      rtl_gen_random = ffi.load("advapi32")
    end
    local buf = u8(n)
    assert(rtl_gen_random.SystemFunction036(buf, n) ~= 0, "RtlGenRandom failed")
    return str(buf, n)
  end
  rng_file = rng_file or assert(io.open("/dev/urandom", "rb"))
  local s = rng_file:read(n)
  assert(s and #s == n, "/dev/urandom read failed")
  return s
end

function M.wipe_buffer(buf, n) L().crypto_wipe(buf, n) end

-- BLAKE2b, 1..64 byte output (default 64).
function M.blake2b(msg, size)
  size = size or 64
  local out = u8(size)
  L().crypto_blake2b(out, size, msg, #msg)
  return str(out, size)
end

function M.sha512(msg)
  local out = u8(64)
  L().crypto_sha512(out, msg, #msg)
  return str(out, 64)
end

-- X25519
function M.x25519_public(sk)
  check_len(sk, 32, "x25519 secret key")
  local out = u8(32)
  L().crypto_x25519_public_key(out, sk)
  return str(out, 32)
end

function M.x25519_keypair()
  local sk = M.random(32)
  return sk, M.x25519_public(sk)
end

function M.x25519(sk, pk)
  check_len(sk, 32, "x25519 secret key"); check_len(pk, 32, "x25519 public key")
  local out = u8(32)
  L().crypto_x25519(out, sk, pk)
  return str(out, 32)
end

-- Ed25519 (standard, SHA-512). Identity keys are stored as their 32-byte seed.
function M.ed25519_public(seed)
  check_len(seed, 32, "ed25519 seed")
  local sk, pk, s = u8(64), u8(32), u8(32)
  ffi.copy(s, seed, 32) -- Monocypher wipes the seed buffer it is given
  L().crypto_ed25519_key_pair(sk, pk, s)
  local out = str(pk, 32)
  L().crypto_wipe(sk, 64)
  return out
end

function M.ed25519_new_seed() return M.random(32) end

function M.ed25519_sign(seed, msg)
  check_len(seed, 32, "ed25519 seed")
  local sk, pk, s, sig = u8(64), u8(32), u8(32), u8(64)
  ffi.copy(s, seed, 32)
  L().crypto_ed25519_key_pair(sk, pk, s)
  L().crypto_ed25519_sign(sig, sk, msg, #msg)
  L().crypto_wipe(sk, 64)
  return str(sig, 64)
end

function M.ed25519_verify(sig, pk, msg)
  if type(sig) ~= "string" or #sig ~= 64 or type(pk) ~= "string" or #pk ~= 32 then return false end
  return L().crypto_ed25519_check(sig, pk, msg, #msg) == 0
end

-- Ed25519 identity -> X25519 keys, so one identity key also works for Noise.
function M.ed25519_to_x25519_public(edpk)
  check_len(edpk, 32, "ed25519 public key")
  local out = u8(32)
  L().crypto_eddsa_to_x25519(out, edpk)
  return str(out, 32)
end

function M.ed25519_seed_to_x25519_secret(seed)
  check_len(seed, 32, "ed25519 seed")
  return M.sha512(seed):sub(1, 32) -- X25519 clamps it
end

-- ChaCha20-Poly1305 (RFC 8439). nonce: 12 bytes. Returns ciphertext .. 16-byte tag.
function M.aead_encrypt(key, nonce, ad, plaintext)
  check_len(key, 32, "aead key"); check_len(nonce, 12, "aead nonce")
  local ctx = ffi.new("crypto_aead_ctx")
  L().crypto_aead_init_ietf(ctx, key, nonce)
  local n = #plaintext
  local ct, mac = u8(n > 0 and n or 1), u8(16)
  L().crypto_aead_write(ctx, ct, mac, ad, #ad, plaintext, n)
  L().crypto_wipe(ctx, ffi.sizeof(ctx))
  return str(ct, n) .. str(mac, 16)
end

-- Returns plaintext, or nil if authentication fails.
function M.aead_decrypt(key, nonce, ad, data)
  check_len(key, 32, "aead key"); check_len(nonce, 12, "aead nonce")
  if #data < 16 then return nil end
  local n = #data - 16
  local ctx = ffi.new("crypto_aead_ctx")
  L().crypto_aead_init_ietf(ctx, key, nonce)
  local pt = u8(n > 0 and n or 1)
  local ok = L().crypto_aead_read(ctx, pt, data:sub(n + 1), ad, #ad, data, n) == 0
  L().crypto_wipe(ctx, ffi.sizeof(ctx))
  if not ok then return nil end
  return str(pt, n)
end

-- Constant-time comparison of two strings of equal length.
function M.equal(a, b)
  if #a ~= #b then return false end
  local d = 0
  local bx, bo = bit.bxor, bit.bor
  for i = 1, #a do d = bo(d, bx(a:byte(i), b:byte(i))) end
  return d == 0
end

return M
