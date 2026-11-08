local T = require("testlib")
local frame = require("zuno.frame")

local S = { shared = true }

S["frames split across arbitrary chunks"] = function()
  local stream = frame.encode("hello") .. frame.encode("") .. frame.encode(string.rep("z", 70000 - 4535)) .. frame.encode("end")
  for _, chunk in ipairs({ 1, 2, 3, 7, 100, 9999, #stream }) do
    local d = frame.decoder()
    local got = {}
    for i = 1, #stream, chunk do
      d:push(stream:sub(i, i + chunk - 1))
      while true do local b = d:next(); if not b then break end; got[#got + 1] = b end
    end
    T.eq(#got, 4, "chunk " .. chunk); T.eq(got[1], "hello"); T.eq(got[2], ""); T.eq(got[4], "end")
  end
end

S["length prefix is big endian"] = function()
  T.eq(frame.encode("abc"):sub(1, 4), "\0\0\0\3")
  T.eq(frame.encode(string.rep("a", 300)):sub(1, 4), "\0\0\1\44")
end

S["oversized frame is refused and the decoder stays broken"] = function()
  local d = frame.decoder(10)
  d:push("\0\0\0\11hello world")
  local b, err = d:next(); T.eq(b, nil); T.eq(err, "frame too large")
  d:push(frame.encode("ok"))
  T.eq(d:next(), nil)
  T.fails(function() frame.encode(string.rep("a", 65536)) end, "too large")
end

return S
