-- Tiny test helpers. A suite is a table: { shared = bool, ["name"] = function() ... end, ... }
local T = {}

local function fmt(v)
  if type(v) == "string" then
    if v:find("[^%g ]") then return ("<%d bytes %s>"):format(#v, (v:sub(1, 24):gsub(".", function(c) return ("%02x"):format(c:byte()) end))) end
    return ("%q"):format(v)
  end
  return tostring(v)
end

function T.eq(a, b, msg)
  if a ~= b then error((msg or "values differ") .. ": got " .. fmt(a) .. ", expected " .. fmt(b), 2) end
end

function T.ok(v, msg)
  if not v then error(msg or "expected a true value", 2) end
  return v
end

function T.fails(fn, pattern, msg)
  local ok, err = pcall(fn)
  if ok then error(msg or "expected an error", 2) end
  if pattern and not tostring(err):find(pattern) then error("error did not match '" .. pattern .. "': " .. tostring(err), 2) end
end

-- Deep equality for plain tables.
function T.same(a, b, path)
  path = path or "value"
  if type(a) ~= type(b) then error(path .. ": type " .. type(a) .. " vs " .. type(b), 2) end
  if type(a) ~= "table" then
    if a ~= b then error(path .. ": " .. fmt(a) .. " vs " .. fmt(b), 2) end
    return
  end
  for k, v in pairs(a) do T.same(v, b[k], path .. "." .. tostring(k)) end
  for k in pairs(b) do if a[k] == nil then error(path .. "." .. tostring(k) .. " missing", 2) end end
end

function T.run_suite(name, suite)
  local names = {}
  for k, v in pairs(suite) do if type(v) == "function" then names[#names + 1] = k end end
  table.sort(names)
  local failed = 0
  for _, k in ipairs(names) do
    local ok, err = xpcall(suite[k], debug.traceback)
    if not ok then
      failed = failed + 1
      print(("  FAIL %s / %s\n%s"):format(name, k, err))
    end
  end
  print(("  %-14s %d/%d"):format(name, #names - failed, #names))
  return failed, #names
end

return T
