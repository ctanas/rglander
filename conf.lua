-- RG Lander - LÖVE configuration
-- Target: Anbernic RG34XXSP (720x480, Allwinner H700, Mali-G31) via PortMaster.

function love.conf(t)
  t.identity = "rglander"
  t.version = "11.4"           -- runs on 11.4 and 11.5 (PortMaster ships 11.5)
  t.console = false
  t.accelerometerjoystick = false
  t.gammacorrect = false

  t.window.title = "RG Lander"
  t.window.width = 720
  t.window.height = 480
  t.window.resizable = true
  t.window.minwidth = 320
  t.window.minheight = 240
  t.window.fullscreen = false
  t.window.vsync = 1
  t.window.msaa = 0            -- lines are anti-aliased by LÖVE's smooth line style
  t.window.highdpi = false

  t.modules.physics = false    -- all physics is hand-written
  t.modules.video = false
  t.modules.touch = false

  -- Headless physics self-test: `love . --autotest 20`
  local headless = false
  if type(arg) == "table" then
    for _, a in ipairs(arg) do
      if a == "--autotest" then headless = true end
    end
  end
  if headless then
    t.window = false
    t.modules.graphics = false
    t.modules.audio = false
  end
end
