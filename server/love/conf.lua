-- Standalone server on the LÖVE runtime (used for the Windows download, where LÖVE already
-- brings LuaJIT + LuaSocket). No window: it runs in a console.
function love.conf(t)
  t.identity = "zuno-server"
  t.console = true
  t.window = false
  for _, m in ipairs({ "audio", "sound", "graphics", "image", "font", "joystick", "keyboard", "mouse",
                       "physics", "touch", "video", "window" }) do
    t.modules[m] = false
  end
end
