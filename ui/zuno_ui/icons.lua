-- Icons drawn with the platform's line/circle primitives (same look on every backend).
-- Each icon fits a 20x20 box at (x, y), scaled by s/20.
local I = {}

local function pts(x, y, k, list)
  local out = {}
  for i = 1, #list, 2 do out[#out + 1] = x + list[i] * k; out[#out + 1] = y + list[i + 1] * k end
  return out
end

function I.draw(P, name, x, y, s, color, width)
  local k = s / 20
  local w = (width or 1.7) * math.max(1, k * 0.9)
  local function L(list) P.line(pts(x, y, k, list), color, w) end
  if name == "plus" then L({ 10, 3, 10, 17 }); L({ 3, 10, 17, 10 })
  elseif name == "close" then L({ 5, 5, 15, 15 }); L({ 15, 5, 5, 15 })
  elseif name == "hash" then L({ 8, 3, 6, 17 }); L({ 14, 3, 12, 17 }); L({ 3.5, 7.5, 16.5, 7.5 }); L({ 3, 12.5, 16, 12.5 })
  elseif name == "users" then
    P.circle_line(x + 7.5 * k, y + 7 * k, 3 * k, color, w)
    L({ 2, 17, 2.6, 14.4, 4.6, 12.6, 7.5, 12, 10.4, 12.6, 12.4, 14.4, 13, 17 })
    L({ 13, 4.2, 14.8, 5.2, 15.4, 7, 14.8, 8.8, 13, 9.8 }); L({ 15, 12.3, 17, 13.8, 18, 17 })
  elseif name == "settings" then
    P.circle_line(x + 10 * k, y + 10 * k, 3 * k, color, w)
    for i = 0, 7 do
      local a = i * math.pi / 4
      L({ 10 + math.cos(a) * 5.5, 10 + math.sin(a) * 5.5, 10 + math.cos(a) * 8, 10 + math.sin(a) * 8 })
    end
  elseif name == "lock" then
    P.rect_line(x + 4 * k, y + 9 * k, 12 * k, 8.5 * k, color, 2 * k, w)
    L({ 7, 9, 7, 6.5, 7.9, 4.4, 10, 3.5, 12.1, 4.4, 13, 6.5, 13, 9 })
  elseif name == "speaker" then
    L({ 3, 8, 6, 8, 10, 4, 10, 16, 6, 12, 3, 12, 3, 8 }); L({ 13, 7.5, 14.2, 10, 13, 12.5 }); L({ 15.5, 5.5, 17.5, 10, 15.5, 14.5 })
  elseif name == "send" then L({ 3, 10, 17, 10 }); L({ 11, 4, 17, 10, 11, 16 })
  elseif name == "check" then L({ 4, 10.5, 8, 14.5, 16, 5.5 })
  elseif name == "warn" then L({ 10, 3, 18, 17, 2, 17, 10, 3 }); L({ 10, 8, 10, 12 }); P.circle(x + 10 * k, y + 14.5 * k, 1.1 * k, color)
  elseif name == "chevron_down" then L({ 5, 8, 10, 13, 15, 8 })
  elseif name == "server" then
    P.rect_line(x + 3 * k, y + 3.5 * k, 14 * k, 5.5 * k, color, 1.5 * k, w)
    P.rect_line(x + 3 * k, y + 11 * k, 14 * k, 5.5 * k, color, 1.5 * k, w)
    P.circle(x + 6 * k, y + 6.25 * k, 1 * k, color); P.circle(x + 6 * k, y + 13.75 * k, 1 * k, color)
  elseif name == "copy" then
    P.rect_line(x + 7 * k, y + 7 * k, 10 * k, 10 * k, color, 2 * k, w)
    L({ 13, 4.5, 13, 3, 3, 3, 3, 13, 4.5, 13 })
  elseif name == "edit" then L({ 4, 16, 4.5, 12.5, 13, 4, 16, 7, 7.5, 15.5, 4, 16 }); L({ 11, 6, 14, 9 })
  elseif name == "trash" then
    L({ 3.5, 5.5, 16.5, 5.5 }); L({ 8, 5.5, 8, 3.5, 12, 3.5, 12, 5.5 })
    L({ 5, 5.5, 6, 17, 14, 17, 15, 5.5 })
  elseif name == "dots" then
    for i = 0, 2 do P.circle(x + (5 + i * 5) * k, y + 10 * k, 1.4 * k, color) end
  elseif name == "sun" then
    P.circle_line(x + 10 * k, y + 10 * k, 3.5 * k, color, w)
    for i = 0, 7 do
      local a = i * math.pi / 4
      L({ 10 + math.cos(a) * 6, 10 + math.sin(a) * 6, 10 + math.cos(a) * 8, 10 + math.sin(a) * 8 })
    end
  elseif name == "moon" then
    L({ 15.5, 12.5, 13, 14.6, 10, 15.3, 7, 14.6, 4.8, 12.5, 4, 9.5, 4.8, 6.5, 7, 4.4, 9, 3.6, 7.8, 6.5, 8.2, 9.5, 10.2, 12, 13, 13, 15.5, 12.5 })
  end
end

return I
