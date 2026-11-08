-- Uploads, downloads, avatars, server emoji and direct-transfer relaying (protocol 3).
--
-- Files are content-addressed: <data>/files/<first 2 hex>/<BLAKE2b-256 hex>. A file row is one
-- upload (name, kind, owner); several rows may share a blob. Uploads go to <data>/uploads/
-- first and are only moved into place after the hash matched, so a half upload never shows.
local C = require("zuno.crypto")
local P = require("zuno.packets")
local compat = require("zuno.compat")
local mp = require("zuno.msgpack")
local fs = require("zuno_server.fs")
local socket = require("socket")

local F = {}

function F.install(Server, H, ctx)
  local now_ms, take = ctx.now_ms, ctx.take

  function Server:_files_init()
    self.files_dir = fs.join(self.opts.data_dir, "files")
    self.uploads_dir = fs.join(self.opts.data_dir, "uploads")
    fs.mkdirs(self.files_dir); fs.mkdirs(self.uploads_dir)
    self.xfers = {}
    self.next_up = 0
    -- uploads never attached to anything are cleaned up after a day
    for _, h in ipairs(self.store:orphan_files(now_ms() - 24 * 3600 * 1000)) do self:_delete_blob(h) end
  end

  function Server:_blob_path(hash) return fs.join(self.files_dir, hash:sub(1, 2), hash) end
  function Server:_delete_blob(hash) if hash then os.remove(self:_blob_path(hash)) end end

  -- file row -> what clients get
  function Server:file_out(f)
    if not f then return nil end
    return { id = f.id, name = f.name, size = f.size, mime = f.mime ~= "" and f.mime or nil, w = f.w, h = f.h, hash = f.hash }
  end

  local function file_size(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local n = f:seek("end"); f:close()
    return n
  end

  local function storage_used(self)
    local r = self.store.db:one("SELECT COALESCE(SUM(size), 0) AS n FROM (SELECT DISTINCT hash, size FROM files)")
    return r.n
  end

  ------------------------------------------------------------------ uploads
  local KIND_LIMIT = { avatar = P.LIMITS.avatar_bytes, emoji = P.LIMITS.emoji_bytes }

  function H.upload(self, conn, pkt)
    if not take(conn.sends) then return self:_err(conn, pkt, P.ERR.rate_limited, "slow down a little") end
    local limit = KIND_LIMIT[pkt.kind] or self.config.max_file_mb * 1024 * 1024
    if pkt.size < 1 or pkt.size > limit then
      return self:_err(conn, pkt, P.ERR.too_long, ("files can be up to %s on this server"):format(F.human(limit)))
    end
    if (pkt.kind == "avatar" or pkt.kind == "emoji") and not (pkt.w and pkt.h) then
      return self:_err(conn, pkt, P.ERR.invalid, "that must be an image")
    end
    local hash = compat.hex(pkt.hash)
    local meta = { hash = hash, size = pkt.size, name = pkt.name:gsub("[%c/\\]", "_"), mime = pkt.mime, w = pkt.w, h = pkt.h,
                   kind = pkt.kind, owner = conn.user }
    -- already have these exact bytes: no transfer needed
    if file_size(self:_blob_path(hash)) == pkt.size then
      meta.at = now_ms()
      local f = self.store:add_file(meta)
      return self:send(conn, { t = "upload_done", re = pkt.q, file = self:file_out(f) })
    end
    local max_storage = self.config.max_storage_mb * 1024 * 1024
    if max_storage > 0 and storage_used(self) + pkt.size > max_storage then
      return self:_err(conn, pkt, P.ERR.too_long, "this server's storage is full")
    end
    conn.uploads = conn.uploads or {}
    local count = 0
    for _ in pairs(conn.uploads) do count = count + 1 end
    if count >= 4 then return self:_err(conn, pkt, P.ERR.rate_limited, "too many uploads at once") end
    -- resume: a part file from this person for the same content
    local part = fs.join(self.uploads_dir, conn.user:sub(1, 16) .. "-" .. hash .. ".part")
    local have = file_size(part) or 0
    if have > pkt.size then os.remove(part); have = 0 end
    local hasher = C.hasher(32)
    if have > 0 then
      local f = io.open(part, "rb")
      while true do
        local b = f:read(1048576)
        if not b then break end
        hasher:update(b)
      end
      f:close()
    end
    local out = io.open(part, "ab")
    if not out then return self:_err(conn, pkt, P.ERR.invalid, "the server couldn't store the file") end
    self.next_up = self.next_up + 1
    local up = self.next_up
    conn.uploads[up] = { meta = meta, part = part, out = out, have = have, hasher = hasher }
    self:send(conn, { t = "upload_ready", re = pkt.q, up = up, have = have })
    if have == pkt.size then self:_finish_upload(conn, up) end
  end

  function Server:_finish_upload(conn, up)
    local u = conn.uploads[up]
    conn.uploads[up] = nil
    u.out:close()
    local got = compat.hex(u.hasher:final())
    if got ~= u.meta.hash then
      os.remove(u.part)
      return self:send(conn, { t = "err", code = P.ERR.invalid, msg = "the upload was damaged; try again", up = up })
    end
    local dest = self:_blob_path(got)
    fs.mkdirs(fs.join(self.files_dir, got:sub(1, 2)))
    os.remove(dest)
    if not os.rename(u.part, dest) then
      return self:send(conn, { t = "err", code = P.ERR.invalid, msg = "the server couldn't store the file", up = up })
    end
    u.meta.at = now_ms()
    local f = self.store:add_file(u.meta)
    self:send(conn, { t = "upload_done", up = up, file = self:file_out(f) })
  end

  function H.upload_chunk(self, conn, pkt)
    local u = conn.uploads and conn.uploads[pkt.up]
    if not u then return self:_err(conn, pkt, P.ERR.not_found, "no such upload") end
    if pkt.off ~= u.have or u.have + #pkt.d > u.meta.size then
      return self:send(conn, { t = "upload_ack", up = pkt.up, have = u.have }) -- tell the client where we are
    end
    u.out:write(pkt.d)
    u.hasher:update(pkt.d)
    u.have = u.have + #pkt.d
    self:send(conn, { t = "upload_ack", up = pkt.up, have = u.have })
    if u.have == u.meta.size then self:_finish_upload(conn, pkt.up) end
  end

  function H.upload_cancel(self, conn, pkt)
    local u = conn.uploads and conn.uploads[pkt.up]
    if not u then return end
    u.out:close()
    os.remove(u.part)
    conn.uploads[pkt.up] = nil
  end

  -- On disconnect: keep part files (they resume), close handles.
  function Server:_files_dropped(conn)
    for _, u in pairs(conn.uploads or {}) do u.out:close() end
    conn.uploads = nil
    for x, t in pairs(self.xfers) do
      if t.a == conn or t.b == conn then self:_end_xfer(x, conn, "the other person went offline") end
    end
  end

  ------------------------------------------------------------------ downloads
  function H.file_get(self, conn, pkt)
    local f = self.store:file(pkt.id)
    if not f then return self:_err(conn, pkt, P.ERR.not_found, "that file is gone") end
    local len = math.min(pkt.len, P.LIMITS.file_get_max)
    if pkt.off < 0 or len < 1 or pkt.off >= f.size then return self:_err(conn, pkt, P.ERR.invalid, "bad range") end
    local h = io.open(self:_blob_path(f.hash), "rb")
    if not h then return self:_err(conn, pkt, P.ERR.not_found, "that file is gone") end
    h:seek("set", pkt.off)
    local off, stop = pkt.off, math.min(f.size, pkt.off + len)
    while off < stop do
      local d = h:read(math.min(P.LIMITS.chunk, stop - off))
      if not d then break end
      self:send(conn, { t = "file_data", id = f.id, off = off, d = mp.bin(d), size = f.size })
      off = off + #d
    end
    h:close()
  end

  ------------------------------------------------------------------ attachments
  -- Checks the file ids of a new message. Returns the list or nil + error.
  function Server:_check_attachments(conn, ids)
    local out = {}
    for _, id in ipairs(ids or {}) do
      local f = self.store:file(id)
      if not f or f.kind ~= "file" or f.owner ~= conn.user then return nil, "an attachment is missing; upload it again" end
      out[#out + 1] = f.id
    end
    return out
  end

  ------------------------------------------------------------------ avatars
  function Server:_set_avatar(conn, id)
    local old = self.store:member(conn.user).avatar
    if id == 0 then id = nil end
    if id then
      local f = self.store:file(id)
      if not f or f.kind ~= "avatar" or f.owner ~= conn.user then return false, "upload the picture first" end
    end
    self.store:set_member_avatar(conn.user, id)
    if old and old ~= id then self:_delete_blob(self.store:release_file(old)) end
    return true
  end

  function Server:member_avatar(m)
    if not m.avatar then return nil end
    local f = self.store:file(m.avatar)
    return f and { id = f.id, hash = f.hash, size = f.size } or nil
  end

  ------------------------------------------------------------------ server emoji
  function Server:emoji_out()
    local list = {}
    for _, e in ipairs(self.store:emoji_list()) do list[#list + 1] = { name = e.name, file = e.file, hash = e.hash, size = e.size } end
    return mp.array(list)
  end

  function H.emoji_add(self, conn, pkt)
    if not self:_is_owner(conn.user) then return self:_err(conn, pkt, P.ERR.forbidden, "only the owner can add server emoji") end
    local f = self.store:file(pkt.file)
    if not f or f.kind ~= "emoji" or f.owner ~= conn.user then return self:_err(conn, pkt, P.ERR.not_found, "upload the image first") end
    if #self.store:emoji_list() >= 200 and not self.store:emoji(pkt.name) then
      return self:_err(conn, pkt, P.ERR.too_long, "a server can have up to 200 emoji")
    end
    local old = self.store:emoji(pkt.name)
    self.store:add_emoji(pkt.name, f.id, conn.user, now_ms())
    if old and old.file ~= f.id then self:_delete_blob(self.store:release_file(old.file)) end
    self:broadcast({ t = "emoji", list = self:emoji_out() })
  end

  function H.emoji_remove(self, conn, pkt)
    if not self:_is_owner(conn.user) then return self:_err(conn, pkt, P.ERR.forbidden, "only the owner can remove server emoji") end
    local e = self.store:emoji(pkt.name)
    if not e then return end
    self.store:remove_emoji(pkt.name)
    self.store.db:run("DELETE FROM reactions WHERE emoji = ?", ":" .. pkt.name .. ":")
    self:_delete_blob(self.store:release_file(e.file))
    self:broadcast({ t = "emoji", list = self:emoji_out() })
  end

  ------------------------------------------------------------------ direct transfers (signaling + relay)
  -- The offer is signed by the sender's identity key and the answer by the receiver's, over
  -- their ephemeral keys, so this server can't sit in the middle. It only forwards.
  function Server:_end_xfer(x, by, why)
    local t = self.xfers[x]
    if not t then return end
    self.xfers[x] = nil
    for _, c in ipairs({ t.a, t.b }) do
      if c and c ~= by and not c.closed then self:send(c, { t = "xfer_end", x = x, why = why }) end
    end
    if not t.b then
      for c in pairs(self.online[t.to] or {}) do if c ~= by then self:send(c, { t = "xfer_end", x = x, why = why }) end end
    end
  end

  function H.xfer_offer(self, conn, pkt)
    if not take(conn.sends) then return self:_err(conn, pkt, P.ERR.rate_limited, "slow down a little") end
    if self.xfers[pkt.x] then return self:_err(conn, pkt, P.ERR.exists, "transfer id in use") end
    if pkt.to == conn.user then return self:_err(conn, pkt, P.ERR.invalid, "you can't send files to yourself") end
    local targets = self.online[pkt.to]
    if not targets or next(targets) == nil then return self:_err(conn, pkt, P.ERR.not_found, "they're offline") end
    local count = 0
    for _, t in pairs(self.xfers) do if t.a == conn then count = count + 1 end end
    if count >= 8 then return self:_err(conn, pkt, P.ERR.rate_limited, "too many transfers at once") end
    self.xfers[pkt.x] = { a = conn, to = pkt.to, relayed = 0, at = socket.gettime() }
    local fwd = { t = "xfer_offer", x = pkt.x, from = conn.user, eph = mp.bin(pkt.eph), sig = mp.bin(pkt.sig), files = pkt.files,
                  relay = self.config.allow_relay or nil,
                  relay_max = self.config.max_relay_mb > 0 and self.config.max_relay_mb * 1024 * 1024 or nil }
    for c in pairs(targets) do self:send(c, fwd) end
  end

  function H.xfer_answer(self, conn, pkt)
    local t = self.xfers[pkt.x]
    if not t or t.b or conn.user ~= t.to then return self:_err(conn, pkt, P.ERR.not_found, "that transfer is gone") end
    if not pkt.ok then
      self.xfers[pkt.x] = nil
      self:send(t.a, { t = "xfer_answer", x = pkt.x, ok = false })
      for c in pairs(self.online[t.to] or {}) do if c ~= conn then self:send(c, { t = "xfer_end", x = pkt.x, why = "answered" }) end end
      return
    end
    t.b = conn
    self:send(t.a, { t = "xfer_answer", x = pkt.x, ok = true, eph = pkt.eph and mp.bin(pkt.eph), sig = pkt.sig and mp.bin(pkt.sig) })
    -- the receiver's other devices stop showing the offer
    for c in pairs(self.online[t.to] or {}) do if c ~= conn then self:send(c, { t = "xfer_end", x = pkt.x, why = "answered" }) end end
  end

  function H.xfer_data(self, conn, pkt)
    local t = self.xfers[pkt.x]
    if not t or not t.b or (conn ~= t.a and conn ~= t.b) then return end
    local small = #pkt.d <= 2048 -- control messages (acks, routes) are always allowed
    if not small then
      if not self.config.allow_relay then return self:_end_xfer(pkt.x, nil, "this server doesn't relay transfers") end
      t.relayed = t.relayed + #pkt.d
      local max = self.config.max_relay_mb * 1024 * 1024
      if max > 0 and t.relayed > max then return self:_end_xfer(pkt.x, nil, "too big to relay through this server") end
    elseif not take(conn.general) then
      return
    end
    self:send(conn == t.a and t.b or t.a, { t = "xfer_data", x = pkt.x, d = mp.bin(pkt.d) })
  end

  function H.xfer_end(self, conn, pkt)
    local t = self.xfers[pkt.x]
    if t and (conn == t.a or conn == t.b or conn.user == t.to) then self:_end_xfer(pkt.x, conn, pkt.why or "cancelled") end
  end

  ------------------------------------------------------------------ UDP: tell clients their public address
  -- A client sends "ZU1?" + 16 bytes; the server answers "ZU1!" + the same 16 bytes + "ip:port".
  -- Used to find a direct route between two clients (hole punching). Same size in and out,
  -- so it can't be used to amplify traffic.
  function Server:_udp_start()
    if not self.config.udp then return end
    local u = socket.udp()
    if not u then return end
    local ok = u:setsockname(self.config.bind == "*" and "*" or self.config.bind, self.port)
    if not ok then u:close(); self:log("warn", "UDP port " .. self.port .. " is busy; direct transfers may need the relay"); return end
    u:settimeout(0)
    self.udp = u
    self.udp_bucket = ctx.bucket(200, 400)
  end

  function Server:_udp_step()
    local u = self.udp
    if not u then return end
    for _ = 1, 64 do
      local data, ip, port = u:receivefrom()
      if not data then return end
      if #data == 20 and data:sub(1, 4) == "ZU1?" and take(self.udp_bucket) then
        u:sendto("ZU1!" .. data:sub(5, 20) .. ip .. ":" .. port, ip, port)
      end
    end
  end
end

function F.human(n)
  if n >= 1024 * 1024 * 1024 then return ("%.1f GB"):format(n / 1073741824) end
  if n >= 1024 * 1024 then return ("%d MB"):format(math.floor(n / 1048576 + 0.5)) end
  if n >= 1024 then return ("%d KB"):format(math.floor(n / 1024 + 0.5)) end
  return n .. " bytes"
end

return F
