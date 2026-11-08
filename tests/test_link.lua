-- Device linking through a real server: QR path, typed-code path, wrong codes, second scan.
package.path = "client/?.lua;" .. package.path
local T = require("testlib")
local socket = require("socket")
local C = require("zuno.crypto")
local Server = require("zuno_server.server")
local model = require("zuno_ui.model")
local L = require("zuno_ui.link")
local TCP = require("zuno_native.tcp")

local S = {}

local function setup()
  local d = os.tmpname(); os.remove(d)
  local srv = Server.new({ data_dir = d .. "_zl", port = 0, bind = "127.0.0.1", quiet = true })
  srv:start()
  local seed = C.ed25519_new_seed()
  local env = { crypto = C, transport = TCP.factory(), now = socket.gettime, identity_seed = seed, name = function() return "patrick" end }
  local conn = model.new_conn(env, { address = "127.0.0.1:" .. srv.port })
  local acc = { seed = seed, name = "patrick", theme = "dark", servers = { { address = "127.0.0.1:" .. srv.port, key = nil, name = "x" } } }
  return srv, conn, env, acc
end

local function pump(srv, list, cond, secs, what)
  local deadline = socket.gettime() + (secs or 5)
  while socket.gettime() < deadline do
    srv:step(0.005)
    for _, x in ipairs(list) do x:update() end
    if cond() then return end
  end
  error("timed out: " .. (what or "?"), 2)
end

local function online(srv, conn) pump(srv, { conn }, function() return conn.me end, 5, "online") end

S["base64url round trip and link parsing"] = function()
  for _, s in ipairs({ "", "a", "ab", "abc", "\0\255\1hello world", string.rep("\7", 100) }) do
    T.eq(L.unb64url(L.b64url(s)), s)
  end
  local url = L.make_url("my-server.at.ply.gg:41234", "K7QM-9XTD", string.rep("A", 32))
  local t = L.parse(url)
  T.eq(t.address, "my-server.at.ply.gg:41234"); T.eq(t.sid, "K7QM-9XTD"); T.eq(t.A, string.rep("A", 32))
  local t2 = L.parse("my-server.at.ply.gg:41234", "k7qm 9xtd")
  T.eq(t2.sid, "K7QM-9XTD"); T.eq(t2.A, nil)
  T.eq(L.parse("bad address!", "K7QM-9XTD"), nil)
  T.eq(L.parse("host:1", "short"), nil)
end

S["typed-code link moves the whole account"] = function()
  local srv, conn, env, acc = setup()
  online(srv, conn)
  local snd = L.sender(C, conn, "127.0.0.1:" .. srv.port, function() return acc end)
  pump(srv, { conn, snd }, function() return snd.state == "waiting" end, 5, "link opened")
  T.ok(snd.sid:match("^%w%w%w%w%-%w%w%w%w$")); T.ok(snd.url:find("^https://zuno.dovecross.site/link#1%."))
  local rcv = L.receiver({ crypto = C, transport = TCP.factory(), now = socket.gettime }, L.parse("127.0.0.1:" .. srv.port, snd.sid:lower()))
  pump(srv, { conn, snd, rcv }, function() return rcv.state == "show_code" and snd.state == "code" end, 5, "codes")
  T.eq(rcv.code, snd.code); T.eq(#rcv.code, 6)
  T.ok(not snd:enter_code("000000") or rcv.code == "000000", "wrong code refused")
  T.eq(rcv.account, nil, "nothing sent before the code matches")
  T.ok(snd:enter_code(rcv.code:sub(1, 3) .. " " .. rcv.code:sub(4)))
  pump(srv, { conn, snd, rcv }, function() return rcv.state == "done" and snd.state == "done" end, 5, "transfer")
  T.eq(rcv.account.seed, acc.seed); T.eq(rcv.account.name, "patrick"); T.eq(#rcv.account.servers, 1)
  T.eq(srv.store:member(require("zuno.compat").hex(C.ed25519_public(rcv.session.my_seed))), nil, "guest never became a member")
  srv:stop()
end

S["QR link: receiver checks the sender key; a swapped key is caught"] = function()
  local srv, conn, _, acc = setup()
  online(srv, conn)
  local snd = L.sender(C, conn, "127.0.0.1:" .. srv.port, function() return acc end)
  pump(srv, { conn, snd }, function() return snd.state == "waiting" end)
  local target = L.parse(snd.url)
  target.A = string.rep("\9", 32) -- pretend the relay / QR doesn't match the real sender
  local rcv = L.receiver({ crypto = C, transport = TCP.factory(), now = socket.gettime }, target)
  pump(srv, { conn, snd, rcv }, function() return rcv.state == "failed" end, 5, "mismatch caught")
  T.ok(rcv.error:find("doesn't match"))
  -- the real QR works
  local snd2 = L.sender(C, conn, "127.0.0.1:" .. srv.port, function() return acc end)
  pump(srv, { conn, snd2 }, function() return snd2.state == "waiting" end)
  local rcv2 = L.receiver({ crypto = C, transport = TCP.factory(), now = socket.gettime }, L.parse(snd2.url))
  pump(srv, { conn, snd2, rcv2 }, function() return rcv2.state == "show_code" and snd2.state == "code" end)
  snd2:enter_code(rcv2.code)
  pump(srv, { conn, snd2, rcv2 }, function() return rcv2.state == "done" end)
  srv:stop()
end

S["three wrong codes cancel; a second join cancels and warns"] = function()
  local srv, conn, _, acc = setup()
  online(srv, conn)
  local snd = L.sender(C, conn, "127.0.0.1:" .. srv.port, function() return acc end)
  pump(srv, { conn, snd }, function() return snd.state == "waiting" end)
  local env2 = { crypto = C, transport = TCP.factory(), now = socket.gettime }
  local rcv = L.receiver(env2, L.parse(snd.url))
  pump(srv, { conn, snd, rcv }, function() return snd.state == "code" end)
  local wrong = rcv.code == "111111" and "222222" or "111111"
  snd:enter_code(wrong); snd:enter_code(wrong); snd:enter_code(wrong)
  T.eq(snd.state, "failed")
  pump(srv, { conn, snd, rcv }, function() return rcv.state == "failed" end, 5, "receiver told")
  T.eq(rcv.account, nil)

  local snd2 = L.sender(C, conn, "127.0.0.1:" .. srv.port, function() return acc end)
  pump(srv, { conn, snd2 }, function() return snd2.state == "waiting" end)
  local first = L.receiver(env2, L.parse(snd2.url))
  pump(srv, { conn, snd2, first }, function() return snd2.state == "code" end)
  local second = L.receiver(env2, L.parse(snd2.url))
  pump(srv, { conn, snd2, first, second }, function() return second.state == "failed" and snd2.state == "failed" end, 5, "second scan")
  T.ok(snd2.error:find("Someone else tried"))
  pump(srv, { conn, snd2, first }, function() return first.state == "failed" end, 5, "first receiver told")
  srv:stop()
end

S["guests can't chat; expired codes fail"] = function()
  local srv, conn, _, acc = setup()
  online(srv, conn)
  local rcv = L.receiver({ crypto = C, transport = TCP.factory(), now = socket.gettime }, { address = "127.0.0.1:" .. srv.port, sid = "AAAA-AAAA" })
  pump(srv, { rcv }, function() return rcv.state == "failed" end, 5, "bad sid")
  T.ok(rcv.error:find("isn't valid"))
  -- a guest trying to send a message is refused
  local g = L.receiver({ crypto = C, transport = TCP.factory(), now = socket.gettime }, { address = "127.0.0.1:" .. srv.port, sid = "BBBB-BBBB" })
  pump(srv, { g }, function() return g.session:is_ready() end, 5, "guest ready")
  g.state = "probe"
  g:_send({ t = "send", ch = 1, body = "hi" })
  local refused
  pump(srv, { g }, function() return g.state == "failed" end, 5, "refused")
  T.ok(g.error:find("Join the server first") or g.error:find("isn't valid"), g.error)
  T.eq(#srv.store:history(1, nil, 50), 0, "no message stored")
  -- expiry
  local snd = L.sender(C, conn, "127.0.0.1:" .. srv.port, function() return acc end)
  pump(srv, { conn, snd }, function() return snd.state == "waiting" end)
  srv.links[snd.sid].expires = socket.gettime() - 1
  pump(srv, { conn, snd }, function() return snd.state == "failed" end, 5, "expired")
  T.ok(snd.error:find("expired"))
  srv:stop()
end

S["replace my key: online server moves at once, offline one on next connect, old key refused"] = function()
  local Controller = require("zuno_ui.controller")
  local compat = require("zuno.compat")
  local d1, d2 = os.tmpname(), os.tmpname(); os.remove(d1); os.remove(d2)
  local s1 = Server.new({ data_dir = d1 .. "_r1", port = 0, bind = "127.0.0.1", quiet = true }); s1:start()
  local s2 = Server.new({ data_dir = d2 .. "_r2", port = 0, bind = "127.0.0.1", quiet = true }); s2:start()
  local files = {}
  local env = { crypto = C, transport = TCP.factory(), now = socket.gettime,
    storage = { read = function(k) return files[k] end, write = function(k, v) files[k] = v end } }
  local ctl = Controller.new(env)
  ctl:set_name("patrick")
  ctl:add_server("127.0.0.1:" .. s1.port); ctl:add_server("127.0.0.1:" .. s2.port)
  local function both() s1:step(0.003); s2:step(0.003); ctl:update() end
  local function until_(cond, what)
    local t = socket.gettime() + 8
    while socket.gettime() < t do both(); if cond() then return end end
    error("timeout: " .. what, 2)
  end
  local c1, c2 = ctl:conn(1), ctl:conn(2)
  until_(function() return c1.me and c2.me end, "online")
  c1:view(c1:text_channels()[1].id)
  until_(function() return c1:store_for(c1:text_channels()[1].id).loaded end, "loaded")
  c1:send_message(c1:text_channels()[1].id, "written with the old key")
  until_(function() return #c1:store_for(c1:text_channels()[1].id).list == 1 end, "sent")
  local old_key = ctl.key
  -- an old linked device keeps the old key
  local stale = model.new_conn({ crypto = C, transport = TCP.factory(), now = socket.gettime,
    identity_seed = ctl.seed, name = function() return "old phone" end }, { address = "127.0.0.1:" .. s1.port })
  -- take server 2 offline, then replace the key
  c2:disconnect(true)
  ctl:replace_key()
  T.ok(ctl.key ~= old_key)
  until_(function() return ctl.servers[1].rekey_pending == nil and c1.status == "online" and c1.me and c1.me.user == ctl.key end, "server 1 moved")
  T.eq(s1.store:member(ctl.key).name, "patrick"); T.eq(s1.store:member(old_key), nil)
  T.eq(s1.store:history(c1:text_channels()[1].id, nil, 50)[1].author, ctl.key, "messages moved")
  T.eq(c1:store_for(c1:text_channels()[1].id).list[1].a, ctl.key, "local copy shows the new key too")
  T.ok(files["identity.old"] and #files["identity.old"] == 32, "old key kept while server 2 is pending")
  -- server 2 comes back: hand-over happens on connect
  c2.manual_off = nil; c2:retry_now()
  until_(function() return ctl.servers[2].rekey_pending == nil and c2.status == "online" and c2.me and c2.me.user == ctl.key end, "server 2 moved")
  T.eq(files["identity.old"], "", "old key deleted when every server has the new one")
  -- the stale device with the old key is refused
  local t = socket.gettime() + 8
  while socket.gettime() < t and stale.status ~= "key_replaced" do s1:step(0.003); stale:update() end
  T.eq(stale.status, "key_replaced")
  -- a restart keeps the new identity
  local ctl2 = Controller.new(env)
  T.eq(ctl2.key, ctl.key); T.eq(ctl2.old_seed, nil)
  s1:stop(); s2:stop()
end

S["replace my key: a forged hand-over is rejected"] = function()
  local srv, conn = setup()
  online(srv, conn)
  local P = require("zuno.packets")
  local mpk = require("zuno.msgpack")
  local other = C.ed25519_new_seed()
  local new_key = require("zuno.compat").hex(C.ed25519_public(C.ed25519_new_seed()))
  conn:send({ t = "rekey", new = new_key, sig = mpk.bin(C.ed25519_sign(other, P.rekey_message(srv.key, new_key))) })
  local got
  conn:on(function(ev, a, b) if ev == "error" then got = b end end)
  pump(srv, { conn }, function() return got end, 5, "rejected")
  T.eq(got, "forbidden"); T.eq(srv.store:member(new_key), nil)
  srv:stop()
end

return S
