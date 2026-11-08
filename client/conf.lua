function love.conf(t)
  t.identity = "zuno"
  t.version = "11.5"
  t.console = false
  t.window.title = "Zuno"
  t.window.width = 1280
  t.window.height = 800
  t.window.minwidth = 900
  t.window.minheight = 600
  t.window.resizable = true
  t.window.highdpi = true
  t.window.vsync = 1
  t.window.msaa = 4
  t.modules.audio = true     -- notification sound (voice comes later)
  t.modules.sound = true
  t.modules.joystick = false
  t.modules.physics = false
  t.modules.video = false
end
