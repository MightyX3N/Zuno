-- Server storage: SQLite schema and all queries in one place.
local sqlite = require("zuno_server.sqlite")

local unpack = table.unpack or unpack

local Store = {}
Store.__index = Store

local SCHEMA_VERSION = 3

local SCHEMA = [[
CREATE TABLE IF NOT EXISTS meta (k TEXT PRIMARY KEY, v TEXT);
CREATE TABLE IF NOT EXISTS members (
  key TEXT PRIMARY KEY,           -- hex Ed25519 public key
  name TEXT NOT NULL,
  role TEXT NOT NULL DEFAULT 'member',
  joined_at INTEGER NOT NULL,
  last_seen INTEGER NOT NULL,
  avatar INTEGER                  -- schema 3: file id
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
  rev INTEGER NOT NULL,
  reply_to INTEGER                -- schema 2
);
CREATE INDEX IF NOT EXISTS messages_ch_id ON messages (ch, id);
CREATE INDEX IF NOT EXISTS messages_ch_rev ON messages (ch, rev);
CREATE TABLE IF NOT EXISTS reactions (
  msg INTEGER NOT NULL,
  key TEXT NOT NULL,              -- who reacted
  emoji TEXT NOT NULL,
  at INTEGER NOT NULL,
  PRIMARY KEY (msg, key, emoji)
);
CREATE INDEX IF NOT EXISTS reactions_msg ON reactions (msg, at);
CREATE TABLE IF NOT EXISTS files (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  hash TEXT NOT NULL,             -- hex BLAKE2b-256 of the content; the blob is files/<2>/<hash>
  size INTEGER NOT NULL,
  name TEXT NOT NULL,
  mime TEXT NOT NULL DEFAULT '',
  w INTEGER, h INTEGER,           -- image size, as told by the uploader
  kind TEXT NOT NULL DEFAULT 'file', -- file | avatar | emoji
  owner TEXT NOT NULL,
  at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS files_hash ON files (hash);
CREATE TABLE IF NOT EXISTS message_files (
  msg INTEGER NOT NULL,
  file INTEGER NOT NULL,
  pos INTEGER NOT NULL,
  PRIMARY KEY (msg, pos)
);
CREATE INDEX IF NOT EXISTS message_files_file ON message_files (file);
CREATE TABLE IF NOT EXISTS emoji (
  name TEXT PRIMARY KEY,
  file INTEGER NOT NULL,
  by TEXT NOT NULL,
  at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS retired_keys (
  key TEXT PRIMARY KEY,           -- an identity key that was replaced
  replaced_by TEXT NOT NULL,
  at INTEGER NOT NULL
);
]]

function Store.open(path)
  local db = sqlite.open(path)
  db:exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA foreign_keys=ON;")
  db:exec(SCHEMA)
  local self = setmetatable({ db = db }, Store)
  self:_migrate()
  if not self:meta("rev") then self:set_meta("rev", "0") end
  return self
end

function Store:close() self.db:close() end

-- Bring an older database up to date. CREATE TABLE IF NOT EXISTS already added new tables.
function Store:_migrate()
  local v = tonumber(self:meta("schema") or "0")
  if v < 2 then
    local has = false
    for _, c in ipairs(self.db:query("PRAGMA table_info(messages)")) do if c.name == "reply_to" then has = true end end
    if not has then self.db:exec("ALTER TABLE messages ADD COLUMN reply_to INTEGER") end
  end
  if v < 3 then
    local has = false
    for _, c in ipairs(self.db:query("PRAGMA table_info(members)")) do if c.name == "avatar" then has = true end end
    if not has then self.db:exec("ALTER TABLE members ADD COLUMN avatar INTEGER") end
  end
  if v ~= SCHEMA_VERSION then self:set_meta("schema", tostring(SCHEMA_VERSION)) end
end

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

function Store:retired(key) return self.db:one("SELECT * FROM retired_keys WHERE key = ?", key) end

-- Move a member to a new key: membership, role and authorship. The old key is retired.
function Store:replace_key(old, new, now)
  self.db:transaction(function()
    self.db:run("UPDATE members SET key = ? WHERE key = ?", new, old)
    self.db:run("UPDATE messages SET author = ? WHERE author = ?", new, old)
    self.db:run("UPDATE OR IGNORE reactions SET key = ? WHERE key = ?", new, old)
    self.db:run("UPDATE files SET owner = ? WHERE owner = ?", new, old)
    self.db:run("DELETE FROM reactions WHERE key = ?", old)
    -- mentions are stored as <@key> inside message text
    self.db:run("UPDATE messages SET body = REPLACE(body, ?, ?) WHERE body LIKE ?", "<@" .. old .. ">", "<@" .. new .. ">", "%<@" .. old .. ">%")
    self.db:run("UPDATE retired_keys SET replaced_by = ? WHERE replaced_by = ?", new, old)
    self.db:run("INSERT INTO retired_keys (key, replaced_by, at) VALUES (?, ?, ?)", old, new, now)
  end)
end

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

function Store:add_message(ch, author, body, now, reply_to, files)
  local id
  self.db:transaction(function()
    local rev = self:next_rev()
    id = self.db:run("INSERT INTO messages (ch, author, body, at, rev, reply_to) VALUES (?, ?, ?, ?, ?, ?)",
      ch, author, body, now, rev, reply_to)
    for pos, f in ipairs(files or {}) do
      self.db:run("INSERT INTO message_files (msg, file, pos) VALUES (?, ?, ?)", id, f, pos)
    end
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
    self.db:run("DELETE FROM reactions WHERE msg = ?", id)
  end)
  local files = self.db:query("SELECT file FROM message_files WHERE msg = ?", id)
  self.db:run("DELETE FROM message_files WHERE msg = ?", id)
  local gone = {}
  for _, f in ipairs(files) do gone[#gone + 1] = self:release_file(f.file) end
  return self:message(id), gone
end

------------------------------------------------------------------ files
function Store:file(id) return self.db:one("SELECT * FROM files WHERE id = ?", id) end

function Store:add_file(f)
  local id = self.db:run("INSERT INTO files (hash, size, name, mime, w, h, kind, owner, at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
    f.hash, f.size, f.name, f.mime or "", f.w, f.h, f.kind, f.owner, f.at)
  return self:file(id)
end

function Store:hash_used(hash) return self.db:one("SELECT 1 AS x FROM files WHERE hash = ? LIMIT 1", hash) ~= nil end

-- Files of a message list: msg id -> { file rows in order }
function Store:message_files(ids)
  local out = {}
  if #ids == 0 then return out end
  local marks = {}
  for i = 1, #ids do marks[i] = "?" end
  local rows = self.db:query("SELECT m.msg AS msg, f.* FROM message_files m JOIN files f ON f.id = m.file WHERE m.msg IN ("
    .. table.concat(marks, ",") .. ") ORDER BY m.msg, m.pos", unpack(ids))
  for _, r in ipairs(rows) do
    out[r.msg] = out[r.msg] or {}
    table.insert(out[r.msg], r)
  end
  return out
end

-- Is a file still used by a message, an avatar or an emoji?
function Store:file_in_use(id)
  return self.db:one("SELECT 1 AS x FROM message_files WHERE file = ? LIMIT 1", id) ~= nil
    or self.db:one("SELECT 1 AS x FROM members WHERE avatar = ? LIMIT 1", id) ~= nil
    or self.db:one("SELECT 1 AS x FROM emoji WHERE file = ? LIMIT 1", id) ~= nil
end

-- Delete a file record nothing uses any more. Returns the hash if no record needs the blob.
function Store:release_file(id)
  if self:file_in_use(id) then return nil end
  local f = self:file(id)
  if not f then return nil end
  self.db:run("DELETE FROM files WHERE id = ?", id)
  if not self:hash_used(f.hash) then return f.hash end
  return nil
end

-- Uploads that were never attached to anything (older than `before`). Returns hashes to delete.
function Store:orphan_files(before)
  local gone = {}
  for _, f in ipairs(self.db:query("SELECT id FROM files WHERE at < ?", before)) do
    local h = self:release_file(f.id)
    if h then gone[#gone + 1] = h end
  end
  return gone
end

function Store:set_member_avatar(key, file) self.db:run("UPDATE members SET avatar = ? WHERE key = ?", file, key) end

------------------------------------------------------------------ server emoji
function Store:emoji_list()
  return self.db:query("SELECT e.name AS name, e.file AS file, f.hash AS hash, f.size AS size FROM emoji e JOIN files f ON f.id = e.file ORDER BY e.name")
end
function Store:emoji(name) return self.db:one("SELECT * FROM emoji WHERE name = ?", name) end
function Store:add_emoji(name, file, by, now) self.db:run("INSERT OR REPLACE INTO emoji (name, file, by, at) VALUES (?, ?, ?, ?)", name, file, by, now) end
function Store:remove_emoji(name) self.db:run("DELETE FROM emoji WHERE name = ?", name) end

------------------------------------------------------------------ reactions
-- Add or remove one reaction. Bumps the message's revision so clients that resume see it.
-- Returns the message row, or nil + reason.
function Store:set_reaction(id, key, emoji, on, now, max_distinct)
  local result, why
  self.db:transaction(function()
    local exists = self.db:one("SELECT 1 AS x FROM reactions WHERE msg = ? AND key = ? AND emoji = ?", id, key, emoji)
    if on == (exists ~= nil) then return end -- nothing changes
    if on then
      local seen = self.db:one("SELECT 1 AS x FROM reactions WHERE msg = ? AND emoji = ? LIMIT 1", id, emoji)
      if not seen and self.db:one("SELECT COUNT(DISTINCT emoji) AS n FROM reactions WHERE msg = ?", id).n >= max_distinct then
        why = "too_many"; return
      end
      self.db:run("INSERT INTO reactions (msg, key, emoji, at) VALUES (?, ?, ?, ?)", id, key, emoji, now)
    else
      self.db:run("DELETE FROM reactions WHERE msg = ? AND key = ? AND emoji = ?", id, key, emoji)
    end
    self.db:run("UPDATE messages SET rev = ? WHERE id = ?", self:next_rev(), id)
    result = true
  end)
  if why then return nil, why end
  return self:message(id), result
end

-- Reactions for a list of message ids: id -> { { emoji, {keys...} }, ... } in first-reaction order.
function Store:reactions(ids)
  local out = {}
  if #ids == 0 then return out end
  local marks = {}
  for i = 1, #ids do marks[i] = "?" end
  local rows = self.db:query("SELECT msg, key, emoji FROM reactions WHERE msg IN (" .. table.concat(marks, ",") .. ") ORDER BY at, rowid", unpack(ids))
  local index = {}
  for _, r in ipairs(rows) do
    local list = out[r.msg] or {}
    out[r.msg] = list
    index[r.msg] = index[r.msg] or {}
    local e = index[r.msg][r.emoji]
    if not e then e = { r.emoji, {} }; index[r.msg][r.emoji] = e; list[#list + 1] = e end
    e[2][#e[2] + 1] = r.key
  end
  return out
end

-- Messages by id (for reply previews): id -> row
function Store:messages_by_id(ids)
  local out = {}
  if #ids == 0 then return out end
  local marks = {}
  for i = 1, #ids do marks[i] = "?" end
  for _, r in ipairs(self.db:query("SELECT * FROM messages WHERE id IN (" .. table.concat(marks, ",") .. ")", unpack(ids))) do out[r.id] = r end
  return out
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
