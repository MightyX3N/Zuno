-- Turns a layout pack's color scheme (hex strings) into color tables for drawing.
local Theme = {}

local function hex(h)
  local r, g, b, a = h:match("^#(%x%x)(%x%x)(%x%x)(%x?%x?)$")
  assert(r, "bad color " .. tostring(h))
  return { tonumber(r, 16) / 255, tonumber(g, 16) / 255, tonumber(b, 16) / 255, a ~= "" and tonumber(a, 16) / 255 or 1 }
end
Theme.hex = hex

function Theme.build(pack, scheme)
  local src = pack.schemes[scheme] or pack.schemes.light
  local t = { scheme = scheme }
  for k, v in pairs(src) do
    if type(v) == "string" then t[k] = hex(v)
    elseif type(v) == "table" then
      t[k] = {}
      for i, h in ipairs(v) do t[k][i] = hex(h) end
    end
  end
  return t
end

-- Same color with a different alpha.
function Theme.alpha(c, a) return { c[1], c[2], c[3], a } end

-- Stable small number from a key, for picking name / avatar colors.
function Theme.pick(list, key)
  local h = 0
  for i = 1, math.min(#key, 16) do h = (h * 31 + key:byte(i)) % 2147483647 end
  return list[h % #list + 1]
end

return Theme
