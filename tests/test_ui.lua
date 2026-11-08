-- Shared UI tests: draw every screen against a fake platform. Runs on LuaJIT and Lua 5.4,
-- which proves the UI code works in the browser's Lua too.
local T = require("testlib")
local UI = require("zuno_ui.ui")
local App = require("zuno_ui.app")
local Controller = require("zuno_ui.controller")
local Theme = require("zuno_ui.theme")
local pack = dofile("layouts/tabs/pack.lua")

local S = { shared = true }

-- Fake platform: records draw calls, measures text at 7 px per byte.
local function fake_platform()
  local P = { calls = 0, texts = {}, now_t = 1000 }
  local function count() P.calls = P.calls + 1 end
  for _, k in ipairs({ "rect", "rect_line", "circle", "circle_line", "line", "clip", "unclip", "set_cursor", "set_clipboard", "open_url", "blur_all" }) do
    P[k] = count
  end
  function P.text(s) count(); P.texts[#P.texts + 1] = s end
  function P.font(face, size) return { face = face, size = size } end
  function P.measure(_, s) return #s * 7 end
  function P.line_height(f) return f.size + 3 end
  function P.wrap(_, s, w)
    local out, per = {}, math.max(1, math.floor(w / 7))
    for para in (s .. "\n"):gmatch("(.-)\n") do
      if para == "" then out[#out + 1] = "" end
      for i = 1, #para, per do out[#out + 1] = para:sub(i, i + per - 1) end
    end
    return out
  end
  function P.now() return P.now_t end
  function P.size() return 1280, 800 end
  function P.device() return { form = "desktop", input = "mouse", dark = P.dark } end
  local fields = {}
  function P.field(id)
    fields[id] = fields[id] or { text = "", get = function(f) return f.text end, set = function(f, t) f.text = t end,
      layout = function() end, draw = function() end, height = function() return 20 end,
      focus = function(f) P.focused = f end, blur = function() end, focused = function(f) return P.focused == f end,
      set_secret = function() end }
    return fields[id]
  end
  return P
end

local function fake_env(P)
  local files = {}
  local n = 0
  local crypto = {
    ed25519_new_seed = function() n = n + 1; return string.rep(string.char(n), 32) end,
    ed25519_public = function(seed) return string.rep(seed:sub(1, 1), 32) end,
  }
  local transport = function() return { status = function() return "connecting" end, send = function() end,
    receive = function() end, close = function() end } end
  return { crypto = crypto, transport = transport, now = P.now,
    storage = { read = function(k) return files[k] end, write = function(k, v) files[k] = v end }, files = files }
end

local function has_text(P, needle)
  for _, t in ipairs(P.texts) do if t:find(needle, 1, true) then return true end end
  return false
end

local function frame(app, P) P.texts = {}; app:draw() end

S["welcome screen, then a server tab with a full chat"] = function()
  local P = fake_platform()
  local env = fake_env(P)
  local ctl = Controller.new(env)
  local ui = UI.new(P)
  local app = App.new(ui, P, ctl, pack)
  frame(app, P)
  T.ok(has_text(P, "Welcome to Zuno"), "welcome")
  T.ok(has_text(P, "Host a server"), "host card hidden when host env missing? should still show title")

  T.ok(ctl:add_server("my-server.at.ply.gg:41234"))
  local conn = ctl:conn()
  -- pretend we're online with some state
  conn.status = "online"
  conn.me = { user = ctl.key, name = "patrick", role = "owner" }
  conn:_on_packet({ t = "state", server = { name = "my-server" }, me = conn.me, rev = 3,
    channels = { { id = 1, name = "general", kind = "text", topic = "Say hi" }, { id = 2, name = "Lounge", kind = "voice" } },
    members = { { user = ctl.key, name = "patrick", role = "owner", online = true }, { user = string.rep("b", 64), name = "nova", role = "member", online = false } } })
  conn.send = function() return true end
  frame(app, P)
  conn:_on_packet({ t = "messages", ch = 1, more = false, list = {
    { id = 1, a = string.rep("b", 64), at = 1700000000000, body = "hello there", rev = 1 },
    { id = 2, a = ctl.key, at = 1700000060000, body = "a much longer message " .. string.rep("word ", 60), rev = 2, edited = 1700000070000 },
  } })
  frame(app, P)
  T.ok(has_text(P, "general"), "channel"); T.ok(has_text(P, "hello there"), "message")
  T.ok(has_text(P, "(edited)"), "edited mark"); T.ok(has_text(P, "nova"), "member")
  T.ok(has_text(P, "This is the start of #general"), "start of channel")
  T.eq(ctl.servers[1].name, "my-server", "server name remembered")

  -- typing + unread + pending
  conn.typing[1] = { [string.rep("b", 64)] = P.now() + 5 }
  conn:send_message(1, "on its way")
  frame(app, P)
  T.ok(has_text(P, "nova is typing"), "typing"); T.ok(has_text(P, "Sending"), "pending message")

  -- dark theme + settings + dialog + menu all draw
  ctl:set_theme("dark"); app.settings_open = true
  frame(app, P); T.ok(has_text(P, "Settings")); T.eq(app:theme_name(), "dark")
  app.settings_open = false
  app:confirm("Delete this message?", "It's removed for everyone.", "Delete", function() end, true)
  frame(app, P); T.ok(has_text(P, "Delete this message?"))
  app.dialog = nil
  app:open_menu(10, 10, { { label = "Copy text", fn = function() end } })
  frame(app, P); T.ok(has_text(P, "Copy text"))
end

S["connection states draw their panels"] = function()
  local P = fake_platform()
  local ctl = Controller.new(fake_env(P))
  local app = App.new(UI.new(P), P, ctl, pack)
  ctl:add_server("example.com:5")
  local conn = ctl:conn()
  app.page = nil
  conn.status = "waiting"; conn.next_try = P.now() + 8; conn.error = "connection refused"
  frame(app, P); T.ok(has_text(P, "reach the server"), "waiting panel")
  conn.status = "key_changed"; conn.changed_key = string.rep("c", 64); ctl.servers[1].key = string.rep("d", 64)
  frame(app, P); T.ok(has_text(P, "identity changed"), "key panel")
  conn.status = "outdated"; conn.error = "This server needs a newer version of Zuno. Please update."
  frame(app, P); T.ok(has_text(P, "newer version"), "outdated panel")
end

S["settings persist and bad saved data is ignored"] = function()
  local P = fake_platform()
  local env = fake_env(P)
  local ctl = Controller.new(env)
  T.ok(ctl:set_name("Patrick"))
  T.ok(not ctl:set_name(string.rep("x", 40)), "too long")
  ctl:add_server("a.example:1"); ctl:add_server("b.example:2"); ctl:add_server("a.example:1")
  T.eq(#ctl.servers, 2, "no duplicates"); T.eq(ctl.active, 1, "duplicate selects existing")
  local ctl2 = Controller.new(env)
  T.eq(ctl2.settings.name, "Patrick"); T.eq(#ctl2.servers, 2); T.eq(ctl2.key, ctl.key, "same identity")
  env.files["client.dat"] = "\255garbage"
  local ctl3 = Controller.new(env)
  T.eq(#ctl3.servers, 0, "garbage file ignored")
end

S["hit regions: topmost wins, clicks need press and release on the same region"] = function()
  local P = fake_platform()
  local ui = UI.new(P)
  ui:begin(800, 600); ui:hit("under", 0, 0, 100, 100); ui:hit("over", 50, 50, 100, 100); ui:finish()
  ui:mouse_pressed(60, 60, 1); ui:mouse_released(60, 60, 1)
  ui:begin(800, 600)
  local u = ui:hit("under", 0, 0, 100, 100); local o = ui:hit("over", 50, 50, 100, 100)
  T.ok(o.clicked and not u.clicked)
  ui:finish()
  ui:mouse_pressed(10, 10, 1); ui:mouse_released(120, 120, 1)
  ui:begin(800, 600)
  T.ok(not ui:hit("under", 0, 0, 100, 100).clicked, "drag-off is not a click")
end

S["theme colors parse"] = function()
  local t = Theme.build(pack, "dark")
  T.eq(#t.bg, 4); T.ok(t.names[1][1] > 0)
  local c = Theme.hex("#ff000080"); T.eq(c[1], 1); T.ok(math.abs(c[4] - 128 / 255) < 1e-9)
end

return S
