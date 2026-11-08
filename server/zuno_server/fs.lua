-- Tiny file helpers (LuaJIT FFI for mkdir/chmod).
local ffi = require("ffi")
local fs = {}

if ffi.os == "Windows" then
  ffi.cdef("int _mkdir(const char *path);")
else
  ffi.cdef("int mkdir(const char *path, unsigned int mode); int chmod(const char *path, unsigned int mode);")
end

fs.sep = ffi.os == "Windows" and "\\" or "/"

function fs.join(...)
  return (table.concat({ ... }, "/"):gsub("[/\\]+", fs.sep))
end

function fs.exists(path)
  local f = io.open(path, "rb")
  if f then f:close(); return true end
  return false
end

-- Create a directory and its parents (ignores "already exists").
function fs.mkdirs(path)
  local norm = path:gsub("\\", "/")
  local cur = norm:sub(1, 1) == "/" and "/" or ""
  for part in norm:gmatch("[^/]+") do
    cur = cur .. part
    if not cur:match("^%a:$") then
      if ffi.os == "Windows" then ffi.C._mkdir(cur) else ffi.C.mkdir(cur, 448) end -- 0700
    end
    cur = cur .. "/"
  end
end

function fs.read(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local s = f:read("*a"); f:close()
  return s
end

-- Write via a temp file + rename so a crash never leaves a half-written file.
function fs.write(path, data, private)
  local tmp = path .. ".tmp"
  local f = assert(io.open(tmp, "wb"))
  f:write(data); f:close()
  if ffi.os ~= "Windows" and private then ffi.C.chmod(tmp, 384) end -- 0600
  os.remove(path)
  assert(os.rename(tmp, path))
end

return fs
