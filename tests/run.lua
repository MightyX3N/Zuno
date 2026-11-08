-- Zuno test runner.  From the repo root:
--   luajit tests/run.lua            (all tests)
--   luajit tests/run.lua msgpack    (only files whose name contains "msgpack")
--   lua5.4 tests/run.lua --shared   (only tests marked shared = runs without LuaJIT/FFI)
package.path = "protocol/?.lua;server/?.lua;ui/?.lua;?.lua;tests/?.lua;" .. package.path

local filter, shared_only = nil, false
for _, a in ipairs(arg or {}) do
  if a == "--shared" then shared_only = true else filter = a end
end

-- name, runs on plain Lua 5.4 (no FFI)?
local files = {
  { "test_compat", true }, { "test_msgpack", true }, { "test_frame", true }, { "test_crypto", false },
  { "test_noise", false }, { "test_session", false }, { "test_packets", true }, { "test_server", false },
  { "test_ui", true }, { "test_account", false }, { "test_link", false },
}

local T = require("testlib")
local runtime = (type(jit) == "table" and jit.version) or _VERSION
print("Zuno tests on " .. runtime)

local total, failed = 0, 0
for _, entry in ipairs(files) do
  local name, shared = entry[1], entry[2]
  if (not filter or name:find(filter, 1, true)) and (shared or not shared_only) then
    local ok, suite = pcall(require, name)
    if not ok then
      print(("  %-14s LOAD ERROR: %s"):format(name, suite)); failed = failed + 1; total = total + 1
    else
      local f, t = T.run_suite(name, suite)
      failed, total = failed + f, total + t
    end
  end
end
print(("%d/%d passed"):format(total - failed, total))
os.exit(failed == 0 and 0 or 1)
