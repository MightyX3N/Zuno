-- Formatting, emoji and composer conversions (pure Lua: runs on LuaJIT and Lua 5.4).
local T = require("testlib")
local R = require("zuno_ui.rich")
local E = require("zuno_ui.emoji")
local Compose = require("zuno_ui.compose")

local S = { shared = true }

local function spans(text)
  local out = {}
  for _, sp in ipairs(R.inline(text)) do
    local tag = (sp.b and "B" or "") .. (sp.i and "I" or "") .. (sp.s and "S" or "") .. (sp.code and "C" or "")
      .. (sp.link and "L" or "") .. (sp.mention and "M" or "")
    out[#out + 1] = (tag ~= "" and (tag .. ":") or "") .. sp.text
  end
  return table.concat(out, "|")
end

S["inline markdown"] = function()
  T.eq(spans("a **b** c"), "a |B:b| c")
  T.eq(spans("*i* and _j_"), "I:i| and |I:j")
  T.eq(spans("snake_case_name stays"), "snake_case_name stays")
  T.eq(spans("~~gone~~"), "S:gone")
  T.eq(spans("`**not bold**`"), "C:**not bold**")
  T.eq(spans("a * b * c"), "a * b * c", "spaced stars are not italic")
  T.eq(spans("**open only"), "**open only", "unclosed stays as typed")
  T.eq(spans("\\*literal\\*"), "*literal*")
  T.eq(spans("***both***"), "BI:both")
end

S["links and mentions"] = function()
  T.eq(spans("go to https://example.com/a?b=1."), "go to |L:https://example.com/a?b=1|.")
  T.eq(spans("(https://en.wikipedia.org/wiki/Lua_(language))"), "(|L:https://en.wikipedia.org/wiki/Lua_(language)|)")
  T.eq(spans("nohttps://x"), "nohttps://x")
  local key = string.rep("ab", 32)
  T.eq(spans("hi <@" .. key .. ">!"), "hi |M:@|!")
  T.eq(spans("<@zz>"), "<@zz>", "only hex keys")
end

S["blocks"] = function()
  local b = R.parse("first\n> quote\n- item\n# Title\n\n```lua\nx = 1\n  y\n```\nlast")
  local kinds = {}
  for _, x in ipairs(b) do kinds[#kinds + 1] = x.kind end
  T.eq(table.concat(kinds, ","), "line,quote,bullet,heading,blank,code,line")
  T.eq(b[6].text, "x = 1\n  y")
  T.eq(R.parse("```inline```")[1].kind, "code")
  T.eq(R.parse("``` not closed")[1].kind, "line", "an unclosed fence is plain text")
end

S["emoji: find, shortcodes, only-emoji"] = function()
  local parts = E.split("hi 👍🏽 ❤️ 🏳️‍🌈 © x")
  local names = {}
  for _, p in ipairs(parts) do if p.emoji then names[#names + 1] = E.name(p.emoji) end end
  T.eq(table.concat(names, ","), "+1,heart,rainbow-flag", "skin tones and ZWJ sequences; © stays text")
  T.eq(E.to_shortcodes("ok 😂"), "ok :joy:")
  T.eq(E.from_shortcodes("ok :joy: `:joy:` :nope:"), "ok 😂 `:joy:` :nope:")
  T.eq(E.from_shortcodes(":+1: :thumbsup:"), "👍 👍")
  local only, n = E.only_emoji(" 😂😂 ")
  T.ok(only); T.eq(n, 2)
  T.ok(not E.only_emoji("😂 haha"))
  T.eq(E.name(E.search("joy", 1)[1]), "joy")
end

S["composer: @names and :shortcodes: to the wire and back"] = function()
  local A, B = string.rep("a", 64), string.rep("b", 64)
  local conn = { members = { [A] = { name = "Ann Lee", online = true }, [B] = { name = "Ann", online = false } } }
  function conn:member_name(k) return self.members[k] and self.members[k].name or "user" end
  T.eq(Compose.to_wire(conn, "hi @Ann Lee and @ann :wave:"), "hi <@" .. A .. "> and <@" .. B .. "> 👋")
  T.eq(Compose.to_wire(conn, "mail me@Ann.com"), "mail me@Ann.com", "not inside words")
  T.eq(Compose.to_wire(conn, "@Annie"), "@Annie", "whole names only")
  T.eq(Compose.to_field(conn, "<@" .. A .. "> 👋"), "@Ann Lee :wave:")
  local s = Compose.suggest(conn, "hello @an")
  T.eq(s.kind, "mention"); T.eq(#s.items, 2); T.eq(s.items[1].name, "Ann Lee", "online first")
  T.eq(s.from, 7)
  local e = Compose.suggest(conn, "nice :thu")
  T.eq(e.kind, "emoji"); T.ok(#e.items > 0)
  T.eq(Compose.suggest(conn, "time 10:30"), nil, "no emoji suggestions inside words")
  T.eq(Compose.insert_text(s.items[1]), "@Ann Lee ")
end

S["layout wraps and reports links"] = function()
  local P = { measure = function(_, s) return #s * 7 end, line_height = function() return 17 end }
  local ctx = { P = P, font = function(face) return { face = face } end, lh = 25, name_for = function() return "Ann" end }
  local L = R.layout("word " .. string.rep("x", 200) .. " https://example.com", 300, ctx)
  T.ok(L.h > 25 * 3, "long word broken over lines")
  T.eq(#L.hits, 1); T.eq(L.hits[1].link, "https://example.com")
  local J = R.layout("😀😀", 300, ctx)
  T.ok(J.jumbo, "emoji-only messages are big")
end

return S
