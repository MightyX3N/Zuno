-- Server storage: SQLite schema and all queries in one place.
local sqlite = require("zuno_server.sqlite")

local Store = {}
Store.__index = Store

local SCHEMA_VERSION = 1

local SCHEMA = [[
CREATE TABLE IF NOT EXISTS meta (k TEXT PRIMARY KEY, v TEXT);
CREATE TABLE IF NOT EXISTS members (
  key TEXT PRIMARY KEY,           -- hex Ed25519 public key
  name TEXT NOT NULL,
  role TEXT NOT NULL DEFAULT 'member',
  joined_at INTEGER NOT NULL,
  last_seen INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS channels (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL,
  kind TEXT NOT NULL DEFAULT 'text',
  topic TEXT NOT NULL DEFAULT '',
  position INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS messages (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  ch INTEGER NOT NULL,
  author TEXT NOT NULL,
  body TEXT NOT NULL,
  at INTEGER NOT NULL,
  edited INTEGER,
  deleted INTEGER NOT NULL DEFAULT 0,
  rev INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS messages_ch_id ON messages (ch, id);
CREATE INDEX IF NOT EXISTS messages_ch_rev ON messages (ch, rev);
]]

function Store.open(path)
  local db = sqlite.open(path)
  db:exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA foreign_keys=ON;")
  db:exec(SCHEMA)
  local self = setmetatable({ db = db }, Store)
  if not self:meta("schema") then self:set_meta("schema", tostring(SCHEMA_VERSION)) end
  if not self:meta("rev") then self:set_meta("rev", "0") end
  return self
end

function Store:close() self.db:close() end

function Store:meta(k)
  local r = self.db:one("SELECT v FROM meta WHERE k = ?", k)
  return r and r.v
end

function Store:set_meta(k, v)
  if v == nil then self.db:run("DELETE FROM meta WHERE k = ?", k)
  else self.db:run("INSERT INTO meta (k, v) VALUES (?, ?) ON CONFLICT(k) DO UPDATE SET v = excluded.v", k, v) end
end

-- Every change to a message bumps the server-wide revision, so clients can resume.
function Store:next_rev()
  local rev = tonumber(self:meta("rev") or "0") + 1
  self:set_meta("rev", tostring(rev))
  return rev
end

function Store:current_rev() return tonumber(self:meta("rev") or "0") end

------------------------------------------------------------------ members
function Store:member(key) return self.db:one("SELECT * FROM members WHERE key = ?", key) end

function Store:members() return self.db:query("SELECT * FROM members ORDER BY name COLLATE NOCASE") end

function Store:upsert_member(key, name, now)
  local m = self:member(key)
  if m then
    self.db:run("UPDATE members SET last_seen = ? WHERE key = ?", now, key)
    m.last_seen = now
    return m, false
  end
  self.db:run("INSERT INTO members (key, name, role, joined_at, last_seen) VALUES (?, ?, 'member', ?, ?)", key, name, now, now)
  return self:member(key), true
end

function Store:set_member_name(key, name) self.db:run("UPDATE members SET name = ? WHERE key = ?", name, key) end
function Store:set_member_role(key, role) self.db:run("UPDATE members SET role = ? WHERE key = ?", role, key) end
function Store:touch_member(key, now) self.db:run("UPDATE members SET last_seen = ? WHERE key = ?", now, key) end

function Store:owner()
  return self.db:one("SELECT * FROM members WHERE role = 'owner' LIMIT 1")
end

------------------------------------------------------------------ channels
function Store:channels() return self.db:query("SELECT * FROM channels ORDER BY kind DESC, position, id") end
function Store:channel(id) return self.db:one("SELECT * FROM channels WHERE id = ?", id) end
function Store:channel_by_name(name, kind)
  return self.db:one("SELECT * FROM channels WHERE name = ? COLLATE NOCASE AND kind = ?", name, kind)
end

function Store:create_channel(name, kind, topic)
  local pos = self.db:one("SELECT COALESCE(MAX(position), 0) + 1 AS p FROM channels WHERE kind = ?", kind).p
  local id = self.db:run("INSERT INTO channels (name, kind, topic, position) VALUES (?, ?, ?, ?)", name, kind, topic or "", pos)
  return self:channel(id)
end

function Store:update_channel(id, name, topic)
  if name then self.db:run("UPDATE channels SET name = ? WHERE id = ?", name, id) end
  if topic then self.db:run("UPDATE channels SET topic = ? WHERE id = ?", topic, id) end
  return self:channel(id)
end

function Store:delete_channel(id)
  self.db:transaction(function()
    self.db:run("DELETE FROM messages WHERE ch = ?", id)
    self.db:run("DELETE FROM channels WHERE id = ?", id)
  end)
end

------------------------------------------------------------------ messages
function Store:message(id) return self.db:one("SELECT * FROM messages WHERE id = ?", id) end

function Store:add_message(ch, author, body, now)
  local id
  self.db:transaction(function()
    local rev = self:next_rev()
    id = self.db:run("INSERT INTO messages (ch, author, body, at, rev) VALUES (?, ?, ?, ?, ?)", ch, author, body, now, rev)
  end)
  return self:message(id)
end

function Store:edit_message(id, body, now)
  self.db:transaction(function()
    local rev = self:next_rev()
    self.db:run("UPDATE messages SET body = ?, edited = ?, rev = ? WHERE id = ?", body, now, rev, id)
  end)
  return self:message(id)
end

-- Soft delete: the row stays (empty) so clients that were offline learn about it.
function Store:delete_message(id)
  self.db:transaction(function()
    local rev = self:next_rev()
    self.db:run("UPDATE messages SET body = '', deleted = 1, rev = ? WHERE id = ?", rev, id)
  end)
  return self:message(id)
end

-- Newest page before `before` (exclusive), returned oldest first. Deleted rows are skipped.
function Store:history(ch, before, limit)
  local rows = self.db:query(
    "SELECT * FROM messages WHERE ch = ? AND id < ? AND deleted = 0 ORDER BY id DESC LIMIT ?",
    ch, before or 9007199254740991, limit + 1)
  local more = #rows > limit
  if more then rows[#rows] = nil end
  local out = {}
  for i = #rows, 1, -1 do out[#out + 1] = rows[i] end
  return out, more
end

-- Changes after a revision (new, edited and deleted), oldest first. nil if too many.
function Store:since(ch, rev, max)
  local rows = self.db:query("SELECT * FROM messages WHERE ch = ? AND rev > ? ORDER BY rev LIMIT ?", ch, rev, max + 1)
  if #rows > max then return nil end
  return rows
end

return Store
