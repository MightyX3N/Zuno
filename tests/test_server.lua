-- Server integration tests: a real server on a real port, real client cores over TCP,
-- plus raw sockets that misbehave on purpose.
package.path = "client/?.lua;" .. package.path
local T = require("testlib")
local socket = require("socket")
local C = require("zuno.crypto")
local Session = require("zuno.session")
local frame = require("zuno.frame")
local compat = require("zuno.compat")
local Server = require("zuno_server.server")
local model = require("zuno_ui.model")
local TCP = require("zuno_native.tcp")

local S = {}

local function tmpdir()
  local d = os.tmpname(); os.remove(d)
  return d .. "_zuno"
end

local function start_server(dir, opts)
  opts = opts or {}
  opts.data_dir = dir
  opts.port = 0           -- any free port
  opts.bind = "127.0.0.1"
  opts.quiet = true
  local srv = Server.new(opts)
  srv:start()
  return srv
end

local function new_client(port, name, entry)
  local seed = C.ed25519_new_seed()
  local env = { crypto = C, transport = TCP.factory(), now = socket.gettime, identity_seed = seed,
                name = function() return name end }
  local conn = model.new_conn(env, entry or { address = "127.0.0.1:" .. port })
  local events = {}
  conn:on(function(ev, a, b) events[#events + 1] = { ev, a, b } end)
  conn.events = events
  conn.seed = seed
  return conn
end

-- Run server + clients until cond() is true (or fail after `secs`).
local function run_until(srv, clients, cond, secs, what)
  local deadline = socket.gettime() + (secs or 5)
  while socket.gettime() < deadline do
    srv:step(0.005)
    for _, c in ipairs(clients) do c:update() end
    if cond() then return true end
  end
  error("timed out waiting for: " .. (what or "condition"), 2)
end

local function settle(srv, clients, secs)
  local deadline = socket.gettime() + (secs or 0.3)
  while socket.gettime() < deadline do
    srv:step(0.005)
    for _, c in ipairs(clients) do c:update() end
  end
end

local function general(conn) return conn:text_channels()[1].id end

S["first run creates identity, config and default channels; key survives restart"] = function()
  local dir = tmpdir()
  local srv = start_server(dir)
  local key, code = srv.key, srv:claim_code()
  T.ok(code and code:match("^%w%w%w%w%-%w%w%w%w$"), "claim code")
  T.ok(io.open(dir .. "/config.lua"), "config written")
  srv:stop()
  local srv2 = start_server(dir)
  T.eq(srv2.key, key, "same server key after restart")
  T.eq(srv2:claim_code(), code, "same claim code until claimed")
  srv2:stop()
end

S["two clients: sync, send, receive, unread, typing, presence"] = function()
  local srv = start_server(tmpdir())
  local a = new_client(srv.port, "alice")
  local b = new_client(srv.port, "bob")
  local all = { a, b }
  run_until(srv, all, function() return a.me and b.me end, 5, "both synced")
  T.eq(a.status, "online"); T.ok(a.entry.key == srv.key, "server key pinned on first use")
  T.eq(#a:text_channels(), 1); T.eq(#a:voice_channels(), 1)
  T.eq(b.members[a.me.user].name, "alice")
  T.ok(b.members[a.me.user].online)

  local ch = general(a)
  a:view(ch); b:view(nil)
  run_until(srv, all, function() return a:store_for(ch).loaded end, 5, "history loaded")
  a:send_message(ch, "  hello bob  \n")
  T.eq(#a:pending_for(ch), 1)
  run_until(srv, all, function() return #b:store_for(ch).list == 1 end, 5, "bob got it")
  T.eq(b:store_for(ch).list[1].body, "  hello bob", "trailing space and newline trimmed, indentation kept")
  T.eq(#a:pending_for(ch), 0, "pending confirmed")
  T.eq(b.unread[ch], 1, "unread for bob")
  b:view(ch); T.eq(b.unread[ch], nil)

  b:typed(ch)
  run_until(srv, all, function() return #a:typing_names(ch) == 1 end, 5, "typing shown")
  T.eq(a:typing_names(ch)[1], "bob")

  b:disconnect(true)
  run_until(srv, all, function() return a.members[b.me.user].online == false end, 5, "presence offline")
  srv:stop()
end

S["history pages of 50 going back"] = function()
  local srv = start_server(tmpdir())
  local ch = srv.store:channels()[2].id -- text channels sort after voice? find general explicitly
  for _, c in ipairs(srv.store:channels()) do if c.kind == "text" then ch = c.id end end
  for i = 1, 120 do srv.store:add_message(ch, string.rep("a", 64), "m" .. i, i) end
  local a = new_client(srv.port, "alice")
  run_until(srv, { a }, function() return a.me end, 5, "synced")
  a:view(ch)
  run_until(srv, { a }, function() return a:store_for(ch).loaded end, 5, "page 1")
  local s = a:store_for(ch)
  T.eq(#s.list, 50); T.eq(s.list[50].body, "m120"); T.eq(s.list[1].body, "m71"); T.ok(s.more)
  a:load_history(ch)
  run_until(srv, { a }, function() return #s.list == 100 end, 5, "page 2")
  a:load_history(ch)
  run_until(srv, { a }, function() return #s.list == 120 end, 5, "page 3")
  T.eq(s.list[1].body, "m1"); T.eq(s.more, false)
  srv:stop()
end

S["edit and delete rules; claim makes an owner who can manage channels"] = function()
  local srv = start_server(tmpdir())
  local a = new_client(srv.port, "alice")
  local b = new_client(srv.port, "bob")
  local all = { a, b }
  run_until(srv, all, function() return a.me and b.me end, 5, "synced")
  local ch = general(a)
  a:view(ch); b:view(ch)
  run_until(srv, all, function() return a:store_for(ch).loaded and b:store_for(ch).loaded end)
  a:send_message(ch, "first")
  run_until(srv, all, function() return #b:store_for(ch).list == 1 end)
  local id = b:store_for(ch).list[1].id

  b:edit_message(id, "hacked")
  run_until(srv, all, function() for _, e in ipairs(b.events) do if e[1] == "error" then return true end end end, 5, "edit refused")
  T.eq(a:store_for(ch).by_id[id].body, "first")

  a:edit_message(id, "first (edited)")
  run_until(srv, all, function() return b:store_for(ch).by_id[id].body == "first (edited)" end, 5, "edit seen")
  T.ok(b:store_for(ch).by_id[id].edited)

  -- non-owner can't create channels
  b:command(ch, "/create secret")
  settle(srv, all)
  T.eq(#a:text_channels(), 1)

  -- wrong code, then right code
  b:command(ch, "/claim AAAA-AAAA")
  settle(srv, all)
  T.ok(not b:is_owner())
  b:command(ch, "/claim " .. srv:claim_code():lower())
  run_until(srv, all, function() return b:is_owner() end, 5, "bob is owner")
  T.eq(srv:claim_code(), nil, "claim code used up")
  T.eq(a.members[b.me.user].role, "owner", "everyone sees the new owner")

  -- owner deletes someone else's message
  b:delete_message(id)
  run_until(srv, all, function() return a:store_for(ch).by_id[id] == nil end, 5, "deleted for alice")

  b:command(ch, "/create lua-dev Lua talk")
  run_until(srv, all, function() return #a:text_channels() == 2 end, 5, "channel created")
  local new = a:text_channels()[2]
  T.eq(new.name, "lua-dev"); T.eq(new.topic, "Lua talk")
  b:command(new.id, "/rename lua")
  run_until(srv, all, function() return a.channel_by_id[new.id].name == "lua" end, 5, "renamed")
  b:command(new.id, "/delete-channel")
  run_until(srv, all, function() return #a:text_channels() == 1 end, 5, "channel deleted")
  b:command(ch, "/delete-channel")
  settle(srv, all)
  T.eq(#a:text_channels(), 1, "last text channel can't be deleted")
  srv:stop()
end

S["reconnect resumes: missed new, edited and deleted messages are applied"] = function()
  local srv = start_server(tmpdir())
  local a = new_client(srv.port, "alice")
  local b = new_client(srv.port, "bob")
  local all = { a, b }
  run_until(srv, all, function() return a.me and b.me end)
  local ch = general(a)
  a:view(ch); b:view(ch)
  run_until(srv, all, function() return a:store_for(ch).loaded and b:store_for(ch).loaded end)
  a:send_message(ch, "one"); a:send_message(ch, "two")
  run_until(srv, all, function() return #b:store_for(ch).list == 2 end)
  local one, two = b:store_for(ch).list[1].id, b:store_for(ch).list[2].id

  -- bob drops (simulate network loss: transport dies, not a manual disconnect)
  b.transport:close()
  b:view(nil)
  a:edit_message(one, "one!")
  a:delete_message(two)
  a:send_message(ch, "three")
  settle(srv, { a }, 0.3)
  run_until(srv, all, function() return b.status == "online" and #b:store_for(ch).list == 2 and b:store_for(ch).list[2].body == "three" end, 10, "bob resumed")
  local s = b:store_for(ch)
  T.eq(s.by_id[one].body, "one!"); T.eq(s.by_id[two], nil)
  T.eq(b.unread[ch], 1, "missed message counts as unread")
  srv:stop()
end

S["messages sent while offline are resent after reconnect"] = function()
  local srv = start_server(tmpdir())
  local a = new_client(srv.port, "alice")
  run_until(srv, { a }, function() return a.me end)
  local ch = general(a)
  a:view(ch)
  run_until(srv, { a }, function() return a:store_for(ch).loaded end)
  a.transport:close()
  a.status = "online" -- the drop is not noticed yet: the send goes nowhere
  a:send_message(ch, "lost in the void")
  run_until(srv, { a }, function() return a.status == "online" and #a:store_for(ch).list == 1 end, 10, "resent")
  T.eq(#a:pending_for(ch), 0)
  srv:stop()
end

S["persisted messages survive a server restart"] = function()
  local dir = tmpdir()
  local srv = start_server(dir)
  local a = new_client(srv.port, "alice")
  run_until(srv, { a }, function() return a.me end)
  local ch = general(a)
  a:view(ch)
  run_until(srv, { a }, function() return a:store_for(ch).loaded end)
  a:send_message(ch, "remember me")
  run_until(srv, { a }, function() return #a:store_for(ch).list == 1 end)
  srv:stop()
  local srv2 = start_server(dir)
  local b = new_client(srv2.port, "bob")
  run_until(srv2, { b }, function() return b.me end)
  b:view(ch)
  run_until(srv2, { b }, function() return #b:store_for(ch).list == 1 end, 5, "history after restart")
  T.eq(b:store_for(ch).list[1].body, "remember me")
  T.eq(b:member_name(b:store_for(ch).list[1].a), "alice")
  srv2:stop()
end

S["changed server key is caught; the user can accept it"] = function()
  local srv = start_server(tmpdir())
  local c = new_client(srv.port, "carol", { address = "127.0.0.1:" .. srv.port, key = string.rep("ab", 32) })
  run_until(srv, { c }, function() return c.status == "key_changed" end, 5, "key change detected")
  T.eq(c.changed_key, srv.key)
  T.eq(srv.store:member(compat.hex(C.ed25519_public(c.seed))), nil, "server never learned who carol is")
  c:accept_new_key()
  run_until(srv, { c }, function() return c.status == "online" and c.me end, 5, "online after accepting")
  T.eq(c.entry.key, srv.key)

  local d = new_client(srv.port, "dave", { address = "127.0.0.1:" .. srv.port .. "#deadbeefdeadbeef" })
  run_until(srv, { d }, function() return d.status == "key_changed" end, 5, "invite fingerprint mismatch")
  local e = new_client(srv.port, "erin", { address = "127.0.0.1:" .. srv.port .. "#" .. srv.key:sub(1, 16) })
  run_until(srv, { e }, function() return e.status == "online" end, 5, "invite fingerprint match")
  srv:stop()
end

S["address parsing"] = function()
  local a = model.parse_address(" My-Server.at.ply.gg:41234 ")
  T.eq(a.host, "my-server.at.ply.gg"); T.eq(a.port, 41234)
  T.eq(model.parse_address("example.com").port, 41234)
  T.eq(model.parse_address("zuno://1.2.3.4:5#ABCdef0123456789").fingerprint, "abcdef0123456789")
  T.eq(model.parse_address("1.2.3.4:5#abcd"), nil, "fingerprint too short")
  T.eq(model.parse_address("[::1]:9000").host, "::1")
  T.eq(model.parse_address("bad host:1"), nil)
  T.eq(model.parse_address("host:99999"), nil)
end

-- Raw socket helpers for misbehaving clients.
local function raw_connect(port)
  local s = assert(socket.connect("127.0.0.1", port))
  s:settimeout(0)
  return s
end

local function is_closed(srv, s, secs)
  local deadline = socket.gettime() + (secs or 3)
  while socket.gettime() < deadline do
    srv:step(0.01)
    local _, err = s:receive(1)
    if err == "closed" then return true end
  end
  return false
end

S["garbage, oversized frames and silent clients are dropped"] = function()
  local srv = start_server(tmpdir())
  local s1 = raw_connect(srv.port); s1:send("GET / HTTP/1.1\r\nHost: x\r\n\r\n")
  T.ok(is_closed(srv, s1), "garbage closed")
  local s2 = raw_connect(srv.port); s2:send("\0\1\0\0" .. string.rep("x", 100))
  T.ok(is_closed(srv, s2), "oversized handshake frame closed")
  srv.config.handshake_timeout = 0.3
  local s3 = raw_connect(srv.port)
  T.ok(is_closed(srv, s3, 3), "silent client timed out")
  T.eq(srv.handshaking, 0, "handshake counter back to 0")
  srv:stop()
end

S["flooding and rate limits"] = function()
  local srv = start_server(tmpdir())
  local a = new_client(srv.port, "alice")
  run_until(srv, { a }, function() return a.me end)
  local ch = general(a)
  -- 20 sends at once: a burst of 8 passes, the rest get rate_limited
  for i = 1, 20 do a:send({ t = "send", ch = ch, body = "spam " .. i }) end
  local limited = 0
  settle(srv, { a }, 0.5)
  for _, e in ipairs(a.events) do if e[1] == "error" and e[3] == "rate_limited" then limited = limited + 1 end end
  T.ok(limited >= 10, "rate limited " .. limited)
  -- 200 packets at once: the client is dropped
  for _ = 1, 200 do a:send({ t = "ping", n = 1 }) end
  run_until(srv, { a }, function() return a.status == "waiting" end, 5, "flooder dropped")
  srv:stop()
end

S["bad packets get an error, not a crash"] = function()
  local srv = start_server(tmpdir())
  local a = new_client(srv.port, "alice")
  run_until(srv, { a }, function() return a.me end)
  a:send({ t = "send", ch = 99999, body = "x" })
  a:send({ t = "nonsense" })
  a:send({ t = "history", ch = "x" })
  a:send({ t = "edit", id = 12345, body = "x" })
  settle(srv, { a }, 0.4)
  local codes = {}
  for _, e in ipairs(a.events) do if e[1] == "error" then codes[#codes + 1] = e[3] end end
  T.eq(#codes, 4, "four errors"); T.eq(a.status, "online", "still connected")
  srv:stop()
end

S["old clients get a clear version error"] = function()
  local srv = start_server(tmpdir())
  local s = raw_connect(srv.port)
  local sess = Session.client(C, { identity_seed = C.ed25519_new_seed(), name = "old", min = 0, max = 0 })
  sess:start(); s:send(sess:pull())
  local got
  local deadline = socket.gettime() + 3
  while socket.gettime() < deadline and not got do
    srv:step(0.01)
    local data, err, partial = s:receive(4096)
    data = data or partial
    if data and #data > 0 then
      for _, ev in ipairs(sess:feed(data)) do if ev.type == "error" then got = ev.code end end
    end
    if err == "closed" then break end
  end
  T.eq(got, "client_outdated")
  srv:stop()
end

S["replies, reactions and mentions"] = function()
  local srv = start_server(tmpdir())
  local a = new_client(srv.port, "alice")
  local b = new_client(srv.port, "bob")
  local all = { a, b }
  run_until(srv, all, function() return a.me and b.me end, 5, "synced")
  T.ok(a:supports("reply") and a:supports("react"), "protocol 2")
  local ch = general(a)
  a:view(ch); b:view(nil)
  run_until(srv, all, function() return a:store_for(ch).loaded end)
  a:send_message(ch, "question for <@" .. b.me.user .. ">")
  run_until(srv, all, function() return b.unread[ch] == 1 end, 5, "bob got it")
  T.eq(b.mentions[ch], 1, "mention counted for bob")
  local incoming
  for _, e in ipairs(b.events) do if e[1] == "incoming" then incoming = e end end
  T.ok(incoming and incoming[3] == true, "incoming event says it pings bob")

  b:view(ch)
  T.eq(b.mentions[ch], nil, "viewing clears mentions")
  run_until(srv, all, function() return b:store_for(ch).loaded end)
  local q = b:store_for(ch).list[1]
  b:send_message(ch, "answer", q.id)
  run_until(srv, all, function() return #a:store_for(ch).list == 2 end, 5, "reply arrived")
  local r = a:store_for(ch).list[2]
  T.eq(r.reply.id, q.id); T.eq(r.reply.a, a.me.user); T.eq(r.reply.b, "question for <@" .. b.me.user .. ">")

  -- reactions: add, second person, remove, limits
  a:react(r, "👍")
  run_until(srv, all, function() return b:store_for(ch).by_id[r.id].rx ~= nil end, 5, "reaction arrived")
  T.eq(b:store_for(ch).by_id[r.id].rx[1][1], "👍")
  b:react(b:store_for(ch).by_id[r.id], "👍")
  run_until(srv, all, function() local x = a:store_for(ch).by_id[r.id].rx; return x and #x[1][2] == 2 end, 5, "two people")
  T.ok(a:reacted(a:store_for(ch).by_id[r.id], "👍"))
  a:react(a:store_for(ch).by_id[r.id], "👍") -- toggle off
  run_until(srv, all, function() local x = b:store_for(ch).by_id[r.id].rx; return x and #x[1][2] == 1 end, 5, "removed")
  a:send({ t = "react", id = r.id, e = "abc", on = true })
  run_until(srv, all, function() for _, e in ipairs(a.events) do if e[1] == "error" then return true end end end, 5, "bad emoji refused")
  for i = 1, 20 do srv.store:set_reaction(r.id, string.rep("c", 64), "🔥" .. string.rep("✨", i), true, i, 40) end
  local before = #a.events
  a:react(a:store_for(ch).by_id[r.id], "😀", true)
  run_until(srv, all, function()
    for i = before + 1, #a.events do if a.events[i][1] == "error" and tostring(a.events[i][2]):find("up to 20") then return true end end
  end, 5, "too many different reactions")

  -- reacting to a missing message, replying across channels
  a:send({ t = "react", id = 99999, e = "👍", on = true })
  b:send({ t = "send", ch = ch, body = "x", reply = 99999 })
  run_until(srv, all, function()
    for _, e in ipairs(b.events) do if e[1] == "error" and tostring(e[2]):find("replied to") then return true end end
  end, 5, "reply to a missing message refused")

  -- editing keeps reactions and marks the message edited for everyone
  b:edit_message(r.id, "answer, edited")
  run_until(srv, all, function() return a:store_for(ch).by_id[r.id].body == "answer, edited" end, 5, "edit arrived")
  T.ok(a:store_for(ch).by_id[r.id].edited, "edited mark")
  T.ok(a:store_for(ch).by_id[r.id].rx, "reactions kept")

  -- deleting the original: the reply shows it's gone after a reload
  a:delete_message(q.id)
  run_until(srv, all, function() return b:store_for(ch).by_id[q.id] == nil end)
  local rows = srv:_rows_out({ srv.store:message(r.id) })
  T.ok(rows[1].reply.gone, "reply preview of a deleted message")
  srv:stop()
end

S["protocol 1 clients still chat; replies are dropped for them"] = function()
  local srv = start_server(tmpdir())
  local old = new_client(srv.port, "old")
  old.env.max_version = 1
  local new = new_client(srv.port, "new")
  local all = { old, new }
  run_until(srv, all, function() return old.me and new.me end, 5, "synced")
  T.eq(old.session_version, 1); T.ok(not old:supports("react"))
  local ch = general(old)
  old:view(ch); new:view(ch)
  run_until(srv, all, function() return old:store_for(ch).loaded and new:store_for(ch).loaded end)
  new:send_message(ch, "hi")
  run_until(srv, all, function() return #old:store_for(ch).list == 1 end)
  old:send_message(ch, "reply from old", old:store_for(ch).list[1].id) -- reply ignored, message sent
  run_until(srv, all, function() return #new:store_for(ch).list == 2 end)
  T.eq(new:store_for(ch).list[2].reply, nil)
  srv:stop()
end

S["a schema 1 database is upgraded in place"] = function()
  local dir = tmpdir()
  os.execute("mkdir -p " .. dir)
  local sqlite = require("zuno_server.sqlite")
  local db = sqlite.open(dir .. "/zuno.db")
  db:exec([[CREATE TABLE meta (k TEXT PRIMARY KEY, v TEXT);
    CREATE TABLE messages (id INTEGER PRIMARY KEY AUTOINCREMENT, ch INTEGER NOT NULL, author TEXT NOT NULL,
      body TEXT NOT NULL, at INTEGER NOT NULL, edited INTEGER, deleted INTEGER NOT NULL DEFAULT 0, rev INTEGER NOT NULL);
    INSERT INTO meta (k, v) VALUES ('schema', '1'), ('rev', '1');
    INSERT INTO messages (ch, author, body, at, rev) VALUES (1, 'aa', 'old message', 1, 1);]])
  db:close()
  local Store = require("zuno_server.store")
  local st = Store.open(dir .. "/zuno.db")
  T.eq(st:meta("schema"), "3")
  T.eq(st:message(1).body, "old message"); T.eq(st:message(1).reply_to, nil)
  local m = st:add_message(1, "bb", "reply", 2, 1)
  T.eq(m.reply_to, 1)
  T.ok(st:set_reaction(1, "bb", "👍", true, 3, 20))
  T.eq(st:reactions({ 1 })[1][1][1], "👍")
  st:close()
end

S["uploads, attachments, downloads, avatars and server emoji"] = function()
  local dir = tmpdir()
  local srv = start_server(dir)
  local a = new_client(srv.port, "alice")
  local b = new_client(srv.port, "bob")
  local all = { a, b }
  run_until(srv, all, function() return a.me and b.me end, 5, "synced")
  T.ok(a:supports("files"))
  local ch = general(a)
  a:view(ch); b:view(ch)
  run_until(srv, all, function() return a:store_for(ch).loaded and b:store_for(ch).loaded end)

  -- a 300 KB file goes up in chunks
  local data = {}
  for i = 1, 300 * 1024 / 16 do data[i] = ("%016d"):format(i) end
  data = table.concat(data)
  local file, err
  local job = a:upload(data, { name = "notes.txt", mime = "text/plain" }, function(f, e) file, err = f, e end)
  run_until(srv, all, function() return file or err end, 10, "upload done")
  T.ok(file, err); T.eq(file.size, #data); T.eq(job.acked, #data)
  T.ok(io.open(srv:_blob_path(file.hash)), "blob stored")

  -- the same bytes again: no transfer, same blob
  local again
  a:upload(data, { name = "copy.txt" }, function(f) again = f end)
  run_until(srv, all, function() return again end, 5, "dedupe")
  T.ok(again.id ~= file.id); T.eq(again.hash, file.hash)

  a:send_message(ch, "", nil, { file })
  run_until(srv, all, function() local l = b:store_for(ch).list; return l[1] and l[1].files end, 5, "attachment arrived")
  local att = b:store_for(ch).list[1].files[1]
  T.eq(att.name, "notes.txt"); T.eq(att.size, #data)

  local got
  b:download(att, function(d, e) got = d or e end)
  run_until(srv, all, function() return got end, 10, "download")
  T.eq(got, data, "same bytes back")

  -- someone else's upload can't be attached
  b:send({ t = "send", ch = ch, body = "x", files = { again.id } })
  run_until(srv, all, function() for _, e in ipairs(b.events) do if e[1] == "error" and tostring(e[2]):find("attachment") then return true end end end, 5)

  -- too big for the server
  local big_err
  a:upload(string.rep("x", 10), { name = "x", kind = "avatar" }, function(_, e) big_err = e end)
  run_until(srv, all, function() return big_err end, 5, "avatar must be an image")
  T.ok(big_err:find("image"))

  -- avatar
  local av
  a:upload("fake png bytes", { name = "a.png", mime = "image/png", w = 256, h = 256, kind = "avatar" }, function(f) av = f end)
  run_until(srv, all, function() return av end, 5, "avatar uploaded")
  a:send({ t = "profile", avatar = av.id })
  run_until(srv, all, function() local m = b.members[a.me.user]; return m and m.av and m.av.id == av.id end, 5, "avatar shown to bob")
  a:send({ t = "profile", avatar = 0 })
  run_until(srv, all, function() return b.members[a.me.user].av == nil end, 5, "avatar removed")
  T.ok(not io.open(srv:_blob_path(av.hash)), "old avatar blob deleted")

  -- server emoji: owner only
  local em
  a:upload("emoji png", { name = "cat.png", mime = "image/png", w = 64, h = 64, kind = "emoji" }, function(f) em = f end)
  run_until(srv, all, function() return em end, 5)
  a:send({ t = "emoji_add", name = "party_cat", file = em.id })
  run_until(srv, all, function() for _, e in ipairs(a.events) do if e[1] == "error" and tostring(e[2]):find("owner") then return true end end end, 5, "not owner")
  srv.store:set_member_role(a.me.user, "owner"); a.me.role = "owner"
  a:send({ t = "emoji_add", name = "party_cat", file = em.id })
  run_until(srv, all, function() return b.emoji and b.emoji[1] and b.emoji[1].name == "party_cat" end, 5, "emoji list")
  local m1 = b:store_for(ch).list[1]
  b:react(m1, ":party_cat:", true)
  run_until(srv, all, function() local x = a:store_for(ch).by_id[m1.id]; return x.rx and x.rx[1][1] == ":party_cat:" end, 5, "custom reaction")
  a:send({ t = "emoji_remove", name = "party_cat" })
  run_until(srv, all, function() return #b.emoji == 0 end, 5, "emoji removed")

  -- deleting the message frees the stored file once nothing uses it
  a:delete_message(m1.id)
  run_until(srv, all, function() return b:store_for(ch).by_id[m1.id] == nil end)
  T.ok(io.open(srv:_blob_path(file.hash)), "still used by the copy upload")
  srv:stop()

  -- a restart cleans up uploads nobody attached (older than a day)
  local Store = require("zuno_server.store")
  local st = Store.open(dir .. "/zuno.db")
  st.db:run("UPDATE files SET at = 0")
  st:close()
  local srv2 = start_server(dir)
  T.ok(not io.open(srv2:_blob_path(file.hash)), "orphan blob removed on start")
  srv2:stop()
end

S["an interrupted upload resumes where it stopped"] = function()
  local srv = start_server(tmpdir())
  local a = new_client(srv.port, "alice")
  run_until(srv, { a }, function() return a.me end, 5)
  local data = string.rep("0123456789abcdef", 40000) -- 640 KB
  local file
  local job = a:upload(data, { name = "big.bin" }, function(f) file = f end)
  run_until(srv, { a }, function() return job.acked > 200000 end, 10, "part sent")
  a.transport:close()
  run_until(srv, { a }, function() return a.status == "online" and job.state == "sending" end, 15, "reconnected")
  T.ok(job.acked > 0 and job.acked < #data, "resumed from the middle, not from 0: " .. job.acked)
  run_until(srv, { a }, function() return file end, 10, "finished")
  T.eq(file.size, #data)
  srv:stop()
end

S["hosting owner becomes owner on first connect; names update on reconnect"] = function()
  local seed = C.ed25519_new_seed()
  local key = compat.hex(C.ed25519_public(seed))
  local dir = tmpdir()
  local srv = start_server(dir, { owner_key = key })
  T.ok(srv:claim_code(), "claim code exists until the host connects")
  local env = { crypto = C, transport = TCP.factory(), now = socket.gettime, identity_seed = seed }
  local name = "patrick"
  env.name = function() return name end
  local a = model.new_conn(env, { address = "127.0.0.1:" .. srv.port })
  run_until(srv, { a }, function() return a.me end)
  T.eq(a.me.role, "owner"); T.eq(a.me.name, "patrick"); T.eq(srv:claim_code(), nil)
  a:disconnect(true)
  settle(srv, { a }, 0.2)
  name = "Patrick R"
  a.manual_off = nil; a:retry_now()
  run_until(srv, { a }, function() return a.me and a.me.name == "Patrick R" end, 5, "renamed on reconnect")
  srv:stop()
end

return S
