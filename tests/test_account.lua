local T = require("testlib")
local C = require("zuno.crypto")
local A = require("zuno_ui.account")

local S = {}

local acc = { seed = string.rep("\7", 32), name = "patrick", theme = "dark",
  servers = { { address = "my-server.at.ply.gg:41234", key = string.rep("ab", 32), name = "my-server" } } }

S["recovery keys look right and normalize"] = function()
  local k = A.new_recovery_key(C)
  T.ok(k:match("^%w%w%w%w%w%-%w%w%w%w%w%-%w%w%w%w%w%-%w%w%w%w%w%-%w%w%w%w%w$"), k)
  T.ok(not k:find("[ILOU]"), "no confusing letters")
  T.eq(A.normalize_recovery_key(k:lower():gsub("%-", " ")), k)
  T.eq(A.normalize_recovery_key("k7qm9xtd4hpaw2re8nvcoooil"), "K7QM9-XTD4H-PAW2R-E8NVC-00011")
  T.eq(A.normalize_recovery_key("too short"), nil)
  local seen = {}
  for _ = 1, 50 do local x = A.new_recovery_key(C); T.ok(not seen[x]); seen[x] = true end
end

S["export then import gives the same account"] = function()
  local rk = A.new_recovery_key(C)
  local file = A.export_file(C, acc, rk, 256, 1)
  T.eq(file:sub(1, 8), A.MAGIC)
  local back = A.import_file(C, file, rk:lower())
  T.eq(back.seed, acc.seed); T.eq(back.name, "patrick"); T.eq(back.theme, "dark")
  T.eq(back.servers[1].address, acc.servers[1].address); T.eq(back.servers[1].key, acc.servers[1].key)
end

S["wrong key, damaged file, tampered header and junk are refused"] = function()
  local rk = A.new_recovery_key(C)
  local file = A.export_file(C, acc, rk, 256, 1)
  local _, e1 = A.import_file(C, file, A.new_recovery_key(C)); T.ok(e1:find("Wrong recovery key"))
  local _, e2 = A.import_file(C, file:sub(1, -2) .. "x", rk); T.ok(e2:find("Wrong recovery key"))
  -- weaken the parameters in the header: must fail, not decrypt
  local weak = file:sub(1, 8) .. "\0\0\0\8" .. "\1" .. file:sub(14)
  local _, e3 = A.import_file(C, weak, rk); T.ok(e3)
  local _, e4 = A.import_file(C, "hello", rk); T.ok(e4:find("isn't a Zuno account"))
  local _, e5 = A.import_file(C, file, "nope"); T.ok(e5:find("25 letters"))
end

S["default parameters: 64 MiB Argon2id finishes in reasonable time"] = function()
  local t = os.clock()
  local rk = A.new_recovery_key(C)
  local file = A.export_file(C, acc, rk)
  T.ok(A.import_file(C, file, rk))
  T.ok(os.clock() - t < 10, "took " .. (os.clock() - t) .. " s")
end

S["file names"] = function()
  T.eq(A.file_name("Patrick R."), "Patrick-R.zunokey")
  T.eq(A.file_name("æøå"), "account.zunokey")
end

return S
