-- Minimal SQLite binding over LuaJIT FFI.
local ffi = require("ffi")

ffi.cdef[[
typedef struct sqlite3 sqlite3;
typedef struct sqlite3_stmt sqlite3_stmt;
int sqlite3_open_v2(const char *filename, sqlite3 **ppDb, int flags, const char *zVfs);
int sqlite3_close_v2(sqlite3 *db);
int sqlite3_exec(sqlite3 *db, const char *sql, void *cb, void *arg, char **errmsg);
int sqlite3_busy_timeout(sqlite3 *db, int ms);
const char *sqlite3_errmsg(sqlite3 *db);
int sqlite3_prepare_v2(sqlite3 *db, const char *zSql, int nByte, sqlite3_stmt **ppStmt, const char **pzTail);
int sqlite3_bind_int64(sqlite3_stmt *stmt, int idx, int64_t value);
int sqlite3_bind_double(sqlite3_stmt *stmt, int idx, double value);
int sqlite3_bind_text(sqlite3_stmt *stmt, int idx, const char *value, int n, intptr_t destructor);
int sqlite3_bind_blob(sqlite3_stmt *stmt, int idx, const void *value, int n, intptr_t destructor);
int sqlite3_bind_null(sqlite3_stmt *stmt, int idx);
int sqlite3_step(sqlite3_stmt *stmt);
int sqlite3_reset(sqlite3_stmt *stmt);
int sqlite3_clear_bindings(sqlite3_stmt *stmt);
int sqlite3_finalize(sqlite3_stmt *stmt);
int sqlite3_column_count(sqlite3_stmt *stmt);
int sqlite3_column_type(sqlite3_stmt *stmt, int col);
const char *sqlite3_column_name(sqlite3_stmt *stmt, int col);
int64_t sqlite3_column_int64(sqlite3_stmt *stmt, int col);
double sqlite3_column_double(sqlite3_stmt *stmt, int col);
const unsigned char *sqlite3_column_text(sqlite3_stmt *stmt, int col);
const void *sqlite3_column_blob(sqlite3_stmt *stmt, int col);
int sqlite3_column_bytes(sqlite3_stmt *stmt, int col);
int64_t sqlite3_last_insert_rowid(sqlite3 *db);
int sqlite3_changes(sqlite3 *db);
]]

local SQLITE_OK, SQLITE_ROW, SQLITE_DONE = 0, 100, 101
local SQLITE_TRANSIENT = -1
local OPEN_FLAGS = 0x00000002 + 0x00000004 + 0x00010000 -- READWRITE | CREATE | FULLMUTEX

local lib
local function load_lib(paths)
  if lib then return lib end
  local list = {}
  for _, p in ipairs(paths or {}) do list[#list + 1] = p end
  if ffi.os == "Windows" then list[#list + 1] = "sqlite3" else
    list[#list + 1] = "sqlite3"; list[#list + 1] = "libsqlite3.so.0"; list[#list + 1] = "libsqlite3.0.dylib"
  end
  local errs = {}
  for _, p in ipairs(list) do
    local ok, l = pcall(ffi.load, p)
    if ok then lib = l; return lib end
    errs[#errs + 1] = p .. ": " .. tostring(l)
  end
  error("could not load SQLite:\n  " .. table.concat(errs, "\n  "))
end

local DB = {}
DB.__index = DB

local M = {}
M.search_paths = nil

function M.open(path)
  local L = load_lib(M.search_paths)
  local pdb = ffi.new("sqlite3*[1]")
  local rc = L.sqlite3_open_v2(path, pdb, OPEN_FLAGS, nil)
  if rc ~= SQLITE_OK then
    local msg = pdb[0] ~= nil and ffi.string(L.sqlite3_errmsg(pdb[0])) or ("error " .. rc)
    if pdb[0] ~= nil then L.sqlite3_close_v2(pdb[0]) end
    error("sqlite open failed: " .. msg)
  end
  local self = setmetatable({ L = L, db = pdb[0], cache = {} }, DB)
  L.sqlite3_busy_timeout(self.db, 5000)
  return self
end

function DB:err() return ffi.string(self.L.sqlite3_errmsg(self.db)) end

function DB:exec(sql)
  local rc = self.L.sqlite3_exec(self.db, sql, nil, nil, nil)
  if rc ~= SQLITE_OK then error("sqlite: " .. self:err() .. "\n  in: " .. sql, 2) end
end

function DB:_stmt(sql)
  local st = self.cache[sql]
  if st then return st end
  local p = ffi.new("sqlite3_stmt*[1]")
  local rc = self.L.sqlite3_prepare_v2(self.db, sql, #sql, p, nil)
  if rc ~= SQLITE_OK then error("sqlite prepare: " .. self:err() .. "\n  in: " .. sql, 3) end
  self.cache[sql] = p[0]
  return p[0]
end

local function bind(L, st, args)
  for i = 1, args.n do
    local v = args[i]
    local tv = type(v)
    if v == nil then L.sqlite3_bind_null(st, i)
    elseif tv == "number" then
      if v == math.floor(v) and v >= -9007199254740992 and v <= 9007199254740992 then
        L.sqlite3_bind_int64(st, i, v)
      else
        L.sqlite3_bind_double(st, i, v)
      end
    elseif tv == "boolean" then L.sqlite3_bind_int64(st, i, v and 1 or 0)
    elseif tv == "string" then L.sqlite3_bind_text(st, i, v, #v, SQLITE_TRANSIENT)
    elseif tv == "table" and v.blob then L.sqlite3_bind_blob(st, i, v.blob, #v.blob, SQLITE_TRANSIENT)
    else error("sqlite: cannot bind " .. tv) end
  end
end

local function read_row(L, st)
  local row = {}
  for c = 0, L.sqlite3_column_count(st) - 1 do
    local name = ffi.string(L.sqlite3_column_name(st, c))
    local t = L.sqlite3_column_type(st, c)
    if t == 1 then row[name] = tonumber(L.sqlite3_column_int64(st, c))
    elseif t == 2 then row[name] = L.sqlite3_column_double(st, c)
    elseif t == 3 then row[name] = ffi.string(L.sqlite3_column_text(st, c), L.sqlite3_column_bytes(st, c))
    elseif t == 4 then row[name] = ffi.string(L.sqlite3_column_blob(st, c), L.sqlite3_column_bytes(st, c))
    end -- 5 = NULL
  end
  return row
end

-- Run a statement. Returns a list of row tables.
function DB:query(sql, ...)
  local L, st = self.L, self:_stmt(sql)
  bind(L, st, { n = select("#", ...), ... })
  local rows = {}
  while true do
    local rc = L.sqlite3_step(st)
    if rc == SQLITE_ROW then rows[#rows + 1] = read_row(L, st)
    elseif rc == SQLITE_DONE then break
    else
      local msg = self:err()
      L.sqlite3_reset(st); L.sqlite3_clear_bindings(st)
      error("sqlite: " .. msg .. "\n  in: " .. sql, 2)
    end
  end
  L.sqlite3_reset(st); L.sqlite3_clear_bindings(st)
  return rows
end

function DB:one(sql, ...) return self:query(sql, ...)[1] end

-- Run a statement for its effect. Returns last insert rowid and number of changed rows.
function DB:run(sql, ...)
  self:query(sql, ...)
  return tonumber(self.L.sqlite3_last_insert_rowid(self.db)), self.L.sqlite3_changes(self.db)
end

function DB:transaction(fn)
  self:exec("BEGIN IMMEDIATE")
  local ok, err = pcall(fn)
  if ok then self:exec("COMMIT") else self:exec("ROLLBACK"); error(err, 0) end
end

function DB:close()
  for _, st in pairs(self.cache) do self.L.sqlite3_finalize(st) end
  self.cache = {}
  if self.db ~= nil then self.L.sqlite3_close_v2(self.db); self.db = nil end
end

return M
