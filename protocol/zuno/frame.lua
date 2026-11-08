-- Framing: every frame is a big-endian u32 length followed by that many body bytes.
-- Used for both the Noise handshake messages and encrypted packets.
local frame = {}

frame.MAX = 65535 -- a Noise message never exceeds this

local floor, char, byte = math.floor, string.char, string.byte

function frame.encode(body)
  local n = #body
  assert(n <= frame.MAX, "frame too large")
  return char(floor(n / 16777216) % 256, floor(n / 65536) % 256, floor(n / 256) % 256, n % 256) .. body
end

-- Streaming decoder. push(bytes) adds data; next() returns the next body, or nil if
-- incomplete. A frame bigger than `max` makes next() return nil, "frame too large"
-- and the decoder stays broken (the connection should be closed).
local Decoder = {}
Decoder.__index = Decoder

function frame.decoder(max)
  return setmetatable({ parts = {}, buf = "", max = max or frame.MAX }, Decoder)
end

function Decoder:push(data)
  if data and #data > 0 then self.parts[#self.parts + 1] = data end
end

function Decoder:set_max(max) self.max = max end

function Decoder:buffered()
  local n = #self.buf
  for _, p in ipairs(self.parts) do n = n + #p end
  return n
end

function Decoder:next()
  if self.err then return nil, self.err end
  if #self.parts > 0 then
    self.buf = self.buf .. table.concat(self.parts)
    self.parts = {}
  end
  local buf = self.buf
  if #buf < 4 then return nil end
  local b1, b2, b3, b4 = byte(buf, 1, 4)
  local n = ((b1 * 256 + b2) * 256 + b3) * 256 + b4
  if n > self.max then
    self.err = "frame too large"
    return nil, self.err
  end
  if #buf < 4 + n then return nil end
  self.buf = buf:sub(5 + n)
  return buf:sub(5, 4 + n)
end

return frame
