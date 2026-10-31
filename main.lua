-- RG Lander: a vector-graphics landing game for small Linux handhelds.
--
-- Rendering: everything is drawn as anti-aliased lines into a logical
-- 720x480 (or 640x480) canvas, a phosphor bloom is added, and the result
-- is shown 1:1 on the RG34XXSP (scaled/letterboxed on a desktop).
--
-- Developer flags:
--   --autotest N            headless: fly N autopilot sorties per world
--   --shot NAME --mode M    render mode M (title|options|howto|game) and
--     [--time S] [--world W]  save NAME.png to the save directory after S s
--   --windowed / --fullscreen

local core = require("src.core")
local settings = require("src.settings")
local input = require("src.input")
local audio = require("src.audio")
local worlds = require("src.worlds")
local Game = require("src.game")

local lg = love.graphics
local glow, Title, vfont
if lg then
  glow = require("src.glow")
  Title = require("src.title")
  vfont = require("src.vfont")
end

local state
local canvases = {}
local app = {}
local shot

local function hasArg(args, name)
  for _, a in ipairs(args) do if a == name then return true end end
  return false
end

local function argValue(args, name)
  for i, a in ipairs(args) do if a == name then return args[i + 1] end end
  return nil
end

local function makeCanvases()
  canvases.scene = lg.newCanvas(core.VW, core.VH)
  canvases.final = lg.newCanvas(core.VW, core.VH)
  canvases.final:setFilter("linear", "linear")
  glow.init(core.VW, core.VH)
end

function core.setAspect(i)
  settings.data.aspect = i
  core.VW = (i == 2) and 640 or 720
  core.VH = 480
  if lg then makeCanvases() end
end

function app.toTitle()
  state = Title.new(app)
end

function app.startGame(demo, worldIndex)
  local d = settings.data
  local wi = worldIndex or d.world
  if demo and not worldIndex then wi = love.math.random(1, #worlds) end
  state = Game.new({
    world = wi, rating = demo and 2 or d.rating,
    assisted = demo or d.attitude == 1, demo = demo, app = app,
  })
end

-- A "WxH" argument (passed by the muOS launcher) gives the screen size.
local function resolutionArg(args)
  for _, a in ipairs(args) do
    local w, h = tostring(a):match("^(%d+)x(%d+)$")
    if w then return tonumber(w), tonumber(h) end
  end
end

local function setupWindow(args)
  local device = os.getenv("RGLANDER_DEVICE") == "1" or hasArg(args, "--fullscreen")
  local dw, dh = love.window.getDesktopDimensions()
  if dw <= 1024 and dh <= 768 then device = true end
  local rw, rh = resolutionArg(args)
  if rw then device = true end
  if hasArg(args, "--windowed") or shot then device = false end
  core.device = device
  if device and rw then
    -- muOS: a window the size of the screen (the rgTrek / 2048 Plus setup)
    love.window.setMode(rw, rh, { vsync = 1 })
    love.mouse.setVisible(false)
  elseif device then
    love.window.setMode(0, 0, { fullscreen = true, fullscreentype = "desktop", vsync = 1 })
    love.mouse.setVisible(false)
  elseif not shot then
    local s = math.max(1, math.floor(math.min((dw - 80) / 720, (dh - 120) / 480)))
    love.window.setMode(720 * s, 480 * s, { resizable = true, vsync = 1, minwidth = 360, minheight = 240 })
  end
end

local function runAutotest(n)
  print(string.format("autotest: %d sorties per world (PILOT, autopilot)", n))
  for wi, w in ipairs(worlds) do
    local tally = { perfect = 0, soft = 0, hard = 0, crash = 0, timeout = 0 }
    local reasons = {}
    local fuelSum, timeSum = 0, 0
    for _ = 1, n do
      local g = Game.new({ world = wi, rating = 2, assisted = true, demo = true, app = app })
      local t = 0
      while g.phase == "fly" and t < 300 do
        g:autopilot()
        g:fixedStep(1 / 120)
        t = t + 1 / 120
      end
      local k = g.result and g.result.kind or "timeout"
      tally[k] = (tally[k] or 0) + 1
      if k == "crash" then reasons[g.result.sub] = (reasons[g.result.sub] or 0) + 1 end
      fuelSum = fuelSum + g.sortieFuel
      timeSum = timeSum + t
    end
    print(string.format("%-6s perfect %3d  soft %3d  hard %3d  crash %3d  timeout %d | %4.0f kg/sortie of %4.0f | %5.1f s",
      w.name, tally.perfect, tally.soft, tally.hard, tally.crash, tally.timeout,
      fuelSum / n, w.fuel, timeSum / n))
    for r, c in pairs(reasons) do print(string.format("         %3d x %s", c, r)) end
  end
end

function love.load(args)
  args = args or {}
  love.math.setRandomSeed(os.time())
  settings.load()
  for i, a in ipairs(args) do
    if a == "--opt" and args[i + 1] then
      local k, v = args[i + 1]:match("^(%w+)=(%w+)$")
      if k and settings.data[k] ~= nil then
        if type(settings.data[k]) == "boolean" then settings.data[k] = v == "true" else settings.data[k] = tonumber(v) end
      end
    end
  end
  settings.sanitize(#worlds)

  if hasArg(args, "--autotest") then
    core.testMode = true
    runAutotest(tonumber(argValue(args, "--autotest")) or 20)
    love.event.quit()
    return
  end

  local shotName = argValue(args, "--shot")
  if shotName then
    core.testMode = true
    shot = {
      name = shotName,
      mode = argValue(args, "--mode") or "title",
      frames = math.floor((tonumber(argValue(args, "--time")) or 1) * 60),
      world = tonumber(argValue(args, "--world")),
      turbo = tonumber(argValue(args, "--turbo")) or 1,
    }
  end

  if shot then love.math.setRandomSeed(tonumber(argValue(args, "--seed")) or 1) end
  setupWindow(args)
  lg.setDefaultFilter("linear", "linear")
  lg.setLineStyle("smooth")
  lg.setLineJoin("bevel")
  core.setPhosphor(settings.data.phosphor)
  if core.device and not settings.fromFile then
    local w, h = lg.getDimensions()
    if w / h < 1.4 then settings.data.aspect = 2 end
  end
  core.setAspect(settings.data.aspect)
  input.init(settings.data.swapab)
  audio.init(settings.data.sound and not shot)

  if shot then
    if shot.mode == "game" then
      app.startGame(true, shot.world or 1)
    elseif shot.mode == "crash" then
      app.startGame(false, shot.world or 1)   -- nobody at the controls
    elseif shot.mode == "pause" then
      app.startGame(false, shot.world or 1)
      state.paused = true
    elseif shot.mode == "gameover" then
      app.startGame(false, shot.world or 1)
      state.score = 1250
      state:gameOver()
    else
      app.toTitle()
      if shot.mode == "options" then state.menu = "options" end
      if shot.mode == "howto" then state.menu = "howto" end
    end
  else
    app.toTitle()
  end
end

function love.update(dt)
  if shot then dt = 1 / 60 end
  core.time = core.time + dt
  input.update(dt)
  if input.quitCombo() then
    love.event.quit()
    return
  end
  if input.pressed.y then core.showFPS = not core.showFPS end
  if shot then
    for _ = 1, shot.turbo do state:update(dt) end
    shot.frames = shot.frames - shot.turbo
  else
    state:update(dt)
  end
end

function love.draw()
  lg.setCanvas(canvases.scene)
  lg.clear(0, 0, 0, 1)
  lg.setColor(1, 1, 1, 1)
  state:draw()
  if core.showFPS then
    lg.setLineWidth(1.2)
    core.setc(0.8)
    vfont.draw(string.format("%d FPS", love.timer.getFPS()), core.VW / 2, core.VH - 40, 9, "center")
  end

  glow.composite(canvases.scene, settings.data.glow, canvases.final)
  lg.setCanvas()
  lg.clear(0, 0, 0, 1)
  lg.setColor(1, 1, 1, 1)

  local ww, wh = lg.getDimensions()
  if core.device then
    -- Fill the panel; with SCREEN 4:3 the 640x480 canvas is stretched to
    -- 720x480, which corrects a physically 4:3 panel's non-square pixels.
    lg.draw(canvases.final, 0, 0, 0, ww / core.VW, wh / core.VH)
  else
    local s = math.min(ww / core.VW, wh / core.VH)
    lg.draw(canvases.final, math.floor((ww - core.VW * s) / 2), math.floor((wh - core.VH * s) / 2), 0, s, s)
  end

  if shot and shot.frames <= 0 then
    local file = shot.name .. ".png"
    canvases.final:newImageData():encode("png", file)
    print("saved " .. love.filesystem.getSaveDirectory() .. "/" .. file)
    shot = nil
    love.event.quit()
  end
end

function love.joystickadded() input.refresh() end
function love.joystickremoved() input.refresh() end

function love.quit()
  if not core.testMode then settings.save() end
end
