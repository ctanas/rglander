-- Title screen, options and the "how to fly" page. Idling for a while
-- starts an attract-mode demo flown by the autopilot.

local core = require("src.core")
local vfont = require("src.vfont")
local input = require("src.input")
local audio = require("src.audio")
local settings = require("src.settings")
local worlds = require("src.worlds")
local Terrain = require("src.terrain")
local scene = require("src.scene")
local Game = require("src.game")
local lg = love.graphics

local Title = {}
Title.__index = Title

local MAIN = {
  { id = "start", label = "START MISSION" },
  { id = "world", label = "WORLD" },
  { id = "rating", label = "RATING" },
  { id = "options", label = "OPTIONS" },
  { id = "howto", label = "HOW TO FLY" },
  { id = "quit", label = "QUIT" },
}

local OPTIONS = {
  { id = "attitude", label = "ATTITUDE", help = "ASSISTED: RCS STOPS ROTATION FOR YOU. MANUAL: PURE INERTIA" },
  { id = "glow", label = "GLOW", help = "PHOSPHOR BLOOM. LOWER IT IF THE FRAME RATE DROPS" },
  { id = "phosphor", label = "PHOSPHOR", help = "COLOUR OF THE VECTOR TUBE" },
  { id = "aspect", label = "SCREEN", help = "PICK 4:3 IF THE PLANET IN THE SKY LOOKS SQUASHED" },
  { id = "swapab", label = "BUTTONS", help = "SWAP A AND B IF CONFIRM IS ON THE WRONG BUTTON" },
  { id = "sound", label = "SOUND", help = "PROCEDURAL ENGINE RUMBLE, RCS HISS AND ALARMS" },
  { id = "back", label = "BACK" },
}

local IDLE_DEMO = 30

local function valueOf(id)
  local d = settings.data
  if id == "world" then return worlds[d.world].name
  elseif id == "rating" then return Game.RATINGS[d.rating].name
  elseif id == "attitude" then return d.attitude == 1 and "ASSISTED" or "MANUAL"
  elseif id == "glow" then return ({ "OFF", "LOW", "HIGH" })[d.glow]
  elseif id == "phosphor" then return core.PHOSPHORS[d.phosphor].name
  elseif id == "aspect" then return d.aspect == 1 and "3:2" or "4:3"
  elseif id == "swapab" then return d.swapab and "SWAPPED" or "NORMAL"
  elseif id == "sound" then return d.sound and "ON" or "OFF"
  end
  return nil
end

local function cycle(v, n, dir) return (v - 1 + dir) % n + 1 end

function Title.new(app)
  local self = setmetatable({
    app = app, menu = "main", sel = 1, idle = 0,
    view = { cx = 0, cy = 0, z = 1, W = 1280 },
  }, Title)
  self:rebuild()
  audio.silence()
  return self
end

function Title:rebuild()
  self.terrain = Terrain.new(worlds[settings.data.world], 1234 + settings.data.world * 7)
end

function Title:change(id, dir)
  local d = settings.data
  if id == "world" then d.world = cycle(d.world, #worlds, dir); self:rebuild()
  elseif id == "rating" then d.rating = cycle(d.rating, #Game.RATINGS, dir)
  elseif id == "attitude" then d.attitude = cycle(d.attitude, 2, dir)
  elseif id == "glow" then d.glow = cycle(d.glow, 3, dir)
  elseif id == "phosphor" then d.phosphor = cycle(d.phosphor, #core.PHOSPHORS, dir); core.setPhosphor(d.phosphor)
  elseif id == "aspect" then core.setAspect(cycle(d.aspect, 2, dir))
  elseif id == "swapab" then d.swapab = not d.swapab; input.swapAB = d.swapab
  elseif id == "sound" then d.sound = not d.sound; audio.setEnabled(d.sound)
  else return false end
  audio.play("blip")
  settings.save()
  return true
end

function Title:activate(id)
  if id == "start" then
    audio.play("blip")
    self.app.startGame(false)
  elseif id == "options" then
    self.menu, self.sel = "options", 1
    audio.play("blip")
  elseif id == "howto" then
    self.menu = "howto"
    audio.play("blip")
  elseif id == "quit" then
    love.event.quit()
  elseif id == "back" then
    self.menu, self.sel = "main", 4
    audio.play("blip")
  else
    self:change(id, 1)
  end
end

function Title:update(dt)
  local I = input
  self.view.cx = core.wrap(self.view.cx + dt * 9, self.terrain.W)

  local active = I.anyPressed() or I.nav("up") or I.nav("down") or I.nav("left") or I.nav("right")
  if active then self.idle = 0 else self.idle = self.idle + dt end
  if self.idle > IDLE_DEMO then return self.app.startGame(true) end

  if self.menu == "howto" then
    if I.pressed.a or I.pressed.b or I.pressed.start or I.pressed.select then
      self.menu = "main"
      audio.play("blip")
    end
    return
  end

  local items = self.menu == "main" and MAIN or OPTIONS
  if I.nav("up") then self.sel = (self.sel - 2) % #items + 1; audio.play("blip") end
  if I.nav("down") then self.sel = self.sel % #items + 1; audio.play("blip") end
  local id = items[self.sel].id
  if I.nav("left") then self:change(id, -1) elseif I.nav("right") then self:change(id, 1) end
  if I.pressed.a or I.pressed.start then self:activate(id) end
  if (I.pressed.b or I.pressed.select) and self.menu == "options" then
    self.menu, self.sel = "main", 4
    audio.play("blip")
  end
end

function Title:drawHowto()
  local VW = core.VW
  local lim = Game.GRADES
  local r = Game.RATINGS[settings.data.rating]
  local x0 = VW / 2 - 300
  local rows = {
    { "D-PAD LEFT/RIGHT, L1/R1", "ROTATE (RCS JETS)" },
    { "D-PAD UP/DOWN", "SET THROTTLE LEVER" },
    { "A (HOLD)", "FULL THRUST" },
    { "B", "CUT THROTTLE LEVER" },
    { "X", "LEVER TO HOVER THRUST" },
    { "LEFT STICK", "ROTATE + ANALOG THRUST" },
    { "R2 / RIGHT STICK UP", "ANALOG THRUST" },
    { "START", "PAUSE" },
    { "SELECT + START", "QUIT" },
  }
  lg.setColor(0, 0, 0, 0.88)
  lg.rectangle("fill", x0 - 16, 122, 632, 268)
  local y = 132
  lg.setLineWidth(1.3)
  for _, row in ipairs(rows) do
    core.setc(0.55)
    vfont.draw(row[1], x0, y, 10)
    core.setc(0.95)
    vfont.draw(row[2], x0 + 290, y, 10)
    y = y + 17
  end
  y = y + 8
  core.setc(1)
  vfont.draw(string.format("TOUCHDOWN LIMITS (%s)", r.name), VW / 2, y, 11, "center")
  y = y + 20
  core.setc(0.85)
  vfont.draw(string.format("VERTICAL %.1f M/S   HORIZONTAL %.1f M/S   TILT %d^",
    lim[2].v * r.tol, lim[2].h * r.tol, math.floor(lim[2].tilt * r.tol + 0.5)), VW / 2, y, 10, "center")
  y = y + 16
  vfont.draw(string.format("UP TO %.1f M/S SURVIVES AS A HARD LANDING", lim[3].v * r.tol), VW / 2, y, 10, "center")
  y = y + 22
  core.setc(0.6)
  vfont.draw("FUEL IS YOUR LIFE. NARROW PADS PAY UP TO X5.", VW / 2, y, 10, "center")
  y = y + 16
  vfont.draw("BURNING FUEL MAKES THE LANDER LIGHTER AND TWITCHIER.", VW / 2, y, 10, "center")
end

function Title:draw()
  local VW, VH = core.VW, core.VH
  local w = worlds[settings.data.world]
  local v, T = self.view, self.terrain
  v.z = 0.95
  v.cy = 6 + (VH - 14 - VH / 2) / v.z
  v.W = T.W

  scene.drawSky(v, T, w, 0.8)
  lg.setLineWidth(1.4)
  core.setc(0.5)
  scene.drawTerrain(v, T)
  scene.drawPads(v, T, false, 0.55)

  lg.setLineWidth(2.8)
  core.setc(1)
  vfont.draw("RG LANDER", VW / 2, 42, 44, "center")
  lg.setLineWidth(1.2)
  core.setc(0.5)
  vfont.draw("A VECTOR DESCENT SIMULATOR", VW / 2, 100, 10, "center")

  core.setc(0.3)
  vfont.draw("V" .. core.VERSION, VW - 10, VH - 16, 8, "right")

  if self.menu == "howto" then
    self:drawHowto()
    if (core.time * 1.6) % 1 < 0.6 then
      core.setc(0.5)
      vfont.draw("PRESS A", VW / 2, VH - 40, 10, "center")
    end
    return
  end

  local items = self.menu == "main" and MAIN or OPTIONS
  local y0, dy, th = 142, 27, 14
  for i, it in ipairs(items) do
    local y = y0 + (i - 1) * dy
    local sel = i == self.sel
    lg.setLineWidth(sel and 1.9 or 1.4)
    core.setc(sel and 1 or 0.5)
    local val = valueOf(it.id)
    if val then
      vfont.draw(it.label, VW / 2 - 140, y, th)
      vfont.draw(val, VW / 2 + 140, y, th, "right")
    else
      vfont.draw(it.label, VW / 2, y, th, "center")
    end
    if sel then
      vfont.draw(">", VW / 2 - 172, y, th)
      vfont.draw("<", VW / 2 + 160, y, th)
    end
  end

  lg.setLineWidth(1.2)
  local iy = y0 + #items * dy + 6
  if self.menu == "main" then
    core.setc(0.7)
    vfont.draw(w.blurb, VW / 2, iy, 10, "center")
    core.setc(0.45)
    vfont.draw(string.format("G %.2f M/S2  -  %s  -  BEST %05d", w.g, w.atmo,
      settings.hiscores[w.id] or 0), VW / 2, iy + 17, 9, "center")
  else
    local help = OPTIONS[self.sel].help
    if help then
      core.setc(0.6)
      vfont.draw(help, VW / 2, iy, 9, "center")
    end
  end
end

return Title
