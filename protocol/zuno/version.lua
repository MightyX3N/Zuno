-- Protocol versions. Both sides send the range they support and use the highest
-- version in common. Bump MAX when adding packets; raise MIN only when dropping old ones.
local version = {
  MIN = 1,
  MAX = 3,           -- 2: replies and reactions; 3: files, avatars, server emoji, direct transfers
  APP = "0.1.0-dev", -- shown in clients and the server console
}

-- Returns the chosen version, or nil + "client_outdated" / "server_outdated".
function version.negotiate(server_min, server_max, client_min, client_max)
  local v = math.min(server_max, client_max)
  if v >= math.max(server_min, client_min) then return v end
  if client_max < server_min then return nil, "client_outdated" end
  return nil, "server_outdated"
end

return version
