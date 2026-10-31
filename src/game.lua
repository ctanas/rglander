-- Gameplay: one mission = a series of sorties (landings) until the
-- propellant runs out. Fuel is your life; crashes cost fuel, good
-- landings refund a little.

local core = require("src.core")
local input = require("src.input")
local audio = require("src.audio")
local settings = require("src.settings")
local worlds = require("src.worlds")
local Terrain = require("src.terrain")
local Lander = require("src.lander")
local Particles = require("src.particles")
local scene = require("src.scene")
local hud = require("src.hud")

local lg = love.graphics
local sin, cos, abs, sqrt, max, min, floor = math.sin, math.cos, math.abs, math.sqrt, math.max, math.min, math.floor

local Game = {}
Game.__index = Game

local PHYS_DT = 1 / 120
local TWR = 2.4          -- design thrust-to-weight ratio at reference mass
local A_MIN = 2.0        -- m/s^2: minimum engine authority (matters on low-g worlds)
local RCS_ALPHA = 5.0    -- rad/s^2 angular acceleration at reference mass
local Z_MIN, Z_MAX = 1.5, 6.0   -- camera zoom range, px per metre

Game.RATINGS = {
  { name = "CADET",     tol = 1.5,  fuel = 1.3,  penalty = 100, speed = 0.75 },
  { name = "PILOT",     tol = 1.0,  fuel = 1.0,  penalty = 150, speed = 1.0 },
  { name = "COMMANDER", tol = 0.75, fuel = 0.85, penalty = 200, speed = 1.25 },
}

-- Touchdown envelopes for PILOT (scaled by rating.tol). Vertical and
-- horizontal speeds in m/s, tilt in degrees. Apollo's LM was rated for
-- about 3 m/s vertical and 1.2 m/s horizontal.
Game.GRADES = {
  { id = "perfect", v = 0.8, h = 0.4, tilt = 2,  points = 100, fuel = 60, title = "PERFECT TOUCHDOWN" },
  { id = "soft",    v = 2.0, h = 1.0, tilt = 5,  points = 50,  fuel = 25, title = "TOUCHDOWN" },
  { id = "hard",    v = 3.5, h = 2.0, tilt = 10, points = 15,  fuel = 0,  title = "HARD LANDING" },
}
local GRADES = Game.GRADES

local SUBS = {
  perfect = { "THE CREW DID NOT FEEL A THING", "TEXTBOOK. FRAME THIS ONE", "SMOOTH AS GLASS" },
  soft = { "CONTACT LIGHT. ENGINE STOP", "WELCOME TO THE SURFACE", "NICE AND STEADY" },
  hard = { "STRUTS BENT - CREW SHAKEN", "THAT WILL NEED A SIGNATURE", "THE GEAR ABSORBED IT. BARELY" },
}

function Game.new(opts)
  local self = setmetatable({}, Game)
  self.app = opts.app
  self.worldIndex = opts.world
  self.world = worlds[opts.world]
  self.rating = Game.RATINGS[opts.rating]
  self.assisted = opts.assisted
  self.demo = opts.demo
  local w = self.world

  self.fuel = w.fuel * self.rating.fuel
  self.fuelStart = self.fuel
  self.mref = Lander.DRY + w.fuel
  self.Fmax = math.max(TWR * w.g, A_MIN) * self.mref
  self.torqueMax = RCS_ALPHA * self.mref * Lander.K2

  local tol = self.rating.tol
  self.limits = {
    softV = GRADES[2].v * tol, softH = GRADES[2].h * tol, softT = GRADES[2].tilt * tol,
    hardV = GRADES[3].v * tol, hardH = GRADES[3].h * tol, hardT = GRADES[3].tilt * tol,
  }

  self.score = 0
  self.sortie = 0
  self.time = 0
  self.acc = 0
  self.particles = Particles.new(1200)
  self.debris = {}
  self.cam = { cx = 0, cy = 0, z = 2, ground = 0, shake = 0 }
  self.view = { cx = 0, cy = 0, z = 2, W = 1280 }
  self.ctl = { rot = 0, thr = 0 }
  self.env = { g = w.g, rho = w.rho, windx = 0 }
  self.vbx, self.vby = {}, {}
  self.lever = 0
  self.paused = false
  self.pauseSel = 1
  self.warnT = 0
  self.stats = { perfect = 0, soft = 0, hard = 0, crash = 0 }
  self:newSortie()
  return self
end

function Game:newSortie()
  self.sortie = self.sortie + 1
  local w = self.world
  local seed = floor(love.math.random() * 2147483647)
  self.terrain = Terrain.new(w, seed)
  local T = self.terrain
  local rng = love.math.newRandomGenerator(seed + 17)

  local vs = core.clamp(sqrt(w.g / 1.62), 0.45, 1.5) * self.rating.speed
  local dir = rng:random() < 0.5 and -1 or 1
  local vx = dir * (7 + min(self.sortie - 1, 8) * 1.6) * vs * (0.85 + 0.3 * rng:random())
  local vy = -(1 + rng:random() * 2) * vs
  self.lander = Lander.new(rng:random() * T.W, T.maxH + 75, vx, vy,
    { Fmax = self.Fmax, torqueMax = self.torqueMax, assisted = self.assisted })

  self.windBase = (w.wind or 0) * (rng:random() * 2 - 1)
  self.windPhase = { rng:random() * 10, rng:random() * 10, rng:random() * 10 }
  self.env.windx = 0

  self.phase = "fly"
  self.phaseT = 0
  self.result = nil
  self.note = nil
  self.lever = 0
  self.debris = {}
  self.ring = nil
  self.particles:clear()
  self.flash = 0
  self.cam.shake = 0
  self.banner = 2.6
  self.emitAcc, self.dustAcc = 0, 0
  self.sortieFuel = 0
  self.fuelOutWarned = false
  self.lowWarned = false
  self.landerVisible = true
  self.apPad = nil
  self.apFinal = false
  self.alt = self:altitude()
  self:updateCamera(0, true)
end

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

function Game:hoverThrottle()
  return core.clamp((Lander.DRY + self.fuel) * self.world.g / self.Fmax, 0, 1)
end

-- Radar altitude: lowest foot above the ground directly beneath it.
function Game:altitude()
  local L, T = self.lander, self.terrain
  local x1, y1 = L:toWorld(-Lander.FOOT_X, Lander.FOOT_Y)
  local x2, y2 = L:toWorld(Lander.FOOT_X, Lander.FOOT_Y)
  return min(y1 - T:height(x1), y2 - T:height(x2))
end

function Game:wind(alt)
  local w = self.world
  if (w.wind or 0) == 0 and (w.gust or 0) == 0 then return 0 end
  local t, p = self.time, self.windPhase
  local gust = sin(t * 0.37 + p[1]) * 0.6 + sin(t * 0.91 + p[2]) * 0.3 + sin(t * 2.3 + p[3]) * 0.1
  local f = 0.4 + 0.6 * core.clamp(alt / 120, 0, 1)   -- wind dies down near the ground
  return (self.windBase + w.gust * gust) * f
end

---------------------------------------------------------------------------
-- Update
---------------------------------------------------------------------------

function Game:readControls(dt)
  local I = input
  if I.down.up then self.lever = min(1, self.lever + dt * 0.8) end
  if I.down.down then self.lever = max(0, self.lever - dt * 0.8) end
  if I.pressed.b then self.lever = 0 end
  if I.pressed.x then self.lever = self:hoverThrottle() end
  local rot = 0
  if I.down.left or I.down.l1 then rot = rot + 1 end
  if I.down.right or I.down.r1 then rot = rot - 1 end
  if rot == 0 then rot = -I.lx end
  self.ctl.rot = rot
  self.ctl.thr = max(self.lever, I.thr, I.down.a and 1 or 0)
end

-- Simple guidance law used by the attract-mode demo and the self-test.
function Game:autopilot()
  local L, T = self.lander, self.terrain
  local g = self.world.g
  if not self.apPad then
    local best, bd
    for _, p in ipairs(T.pads) do
      local d = abs(core.wdelta(p.cx - L.x, T.W)) / (1 + p.mult * 0.1)
      if not bd or d < bd then best, bd = p, d end
    end
    self.apPad = best
  end
  local p = self.apPad
  local dx = core.wdelta(p.cx - L.x, T.W)
  local footY = L.y + Lander.FOOT_Y
  local hPad = footY - p.y
  -- hysteresis: commit to the final descent once over the pad
  if self.apFinal then
    if abs(dx) > 14 then self.apFinal = false end
  elseif abs(dx) < 4 and abs(L.vx) < 2 then
    self.apFinal = true
  end
  local far = not self.apFinal
  local vxd, vyd
  if far then
    local a, b = L.x, L.x + dx
    if a > b then a, b = b, a end
    local safeY = max(T:maxHeight(a - 12, b + 12), p.y) + 20
    local vmax = 12 * core.clamp(sqrt(g / 1.62), 0.45, 1.2)
    vxd = core.clamp(dx * 0.12, -vmax, vmax)
    vyd = core.clamp((safeY - footY) * 0.4, -6, 5)
  else
    vxd = core.clamp(dx * 0.5, -1.2, 1.2)
    vyd = -core.clamp(hPad * 0.2 + 0.4, 0.5, 6)
    -- not lined up with the pad yet: slow the descent near the ground
    local misaligned = abs(dx) > max(0.5, p.w / 2 - Lander.FOOT_X - 0.6) or abs(L.vx) > 0.6
    if misaligned and hPad < 20 then vyd = max(vyd, hPad < 6 and 0 or -0.3) end
    self.apAligned = not misaligned
  end
  local axd = (vxd - L.vx) * 0.9
  local ayd = (vyd - L.vy) * 1.8 + g
  if ayd < 0.15 * g then ayd = 0.15 * g end
  local lim = far and 0.8 or core.clamp(math.atan(0.3 / g), 0.08, 0.6)
  if not far and min(hPad, self:altitude()) < 8 then lim = min(lim, 0.1) end
  local ad = core.clamp(math.atan2(-axd, ayd), -lim, lim)
  if self.apFinal and self.apAligned and min(hPad, self:altitude()) < 4 then ad = 0 end
  -- Vertical priority: size the burn for the vertical need, let the tilt
  -- supply whatever horizontal push that gives (vital in low gravity).
  local m = Lander.DRY + self.fuel
  local thr = m * ayd / (self.Fmax * max(cos(L.a), 0.3))
  self.ctl.thr = core.clamp(thr, 0, 1)
  self.ctl.rot = core.clamp((ad - L.a) * 3 - L.w * 0.3, -1, 1)
end

function Game:update(dt)
  local I = input
  dt = min(dt, 0.1)

  if self.demo then
    if I.anyPressed() then return self.app.toTitle() end
  elseif (I.pressed.start or I.pressed.select) and self.phase ~= "gameover" then
    self.paused = not self.paused
    self.pauseSel = 1
    audio.play("blip")
    if self.paused then audio.silence() end
    return
  end

  if self.paused then return self:updatePause() end

  if self.phase == "fly" then
    if self.demo then self:autopilot() else self:readControls(dt) end
  else
    self.ctl.thr, self.ctl.rot = 0, 0
  end

  self.acc = self.acc + dt
  while self.acc >= PHYS_DT do
    self:fixedStep(PHYS_DT)
    self.acc = self.acc - PHYS_DT
  end

  local T, w = self.terrain, self.world
  self.particles:update(dt, T, w.g, w.rho, self.env.windx)
  self:updateDebris(dt)
  self.alt = self:altitude()
  self:updateCamera(dt)
  self.flash = max(0, self.flash - dt * 2.5)
  self.cam.shake = max(0, self.cam.shake - dt * 1.4)
  self.banner = max(0, self.banner - dt)
  self.phaseT = self.phaseT + dt
  if self.ring then
    self.ring.t = self.ring.t + dt
    if self.ring.t > 0.8 then self.ring = nil end
  end
  if self.note then
    self.note.t = self.note.t - dt
    if self.note.t <= 0 then self.note = nil end
  end
  self:warnings(dt)

  local L = self.lander
  local flying = self.phase == "fly"
  audio.update(dt, (flying or self.phase == "landed") and L.thr or 0, flying and abs(L.rcs) or 0)

  if self.phase == "landed" or self.phase == "crashed" then
    local go = (self.demo and self.phaseT > 3) or (self.phaseT > 1.0 and I.pressed.a)
    if go then
      if self.fuel < 1 then self:gameOver() else self:newSortie() end
    end
  elseif self.phase == "gameover" then
    if (self.demo and self.phaseT > 4) or (self.phaseT > 1.0 and I.pressed.a) then
      return self.app.toTitle()
    end
  end
end

function Game:updatePause()
  local I = input
  audio.update(0.016, 0, 0)
  if I.nav("up") then self.pauseSel = (self.pauseSel - 2) % 3 + 1; audio.play("blip") end
  if I.nav("down") then self.pauseSel = self.pauseSel % 3 + 1; audio.play("blip") end
  if I.pressed.b then self.paused = false; return end
  if I.pressed.a then
    audio.play("blip")
    if self.pauseSel == 1 then
      self.paused = false
    elseif self.pauseSel == 2 then
      self.app.startGame(false)
    else
      self.app.toTitle()
    end
  end
end

function Game:warnings(dt)
  self.warnT = self.warnT - dt
  self.sinkWarn = false
  if self.phase ~= "fly" then return end
  local vdown = -self.lander.vy
  self.sinkWarn = self.alt < 35 and vdown > self.limits.hardV * 1.15
  if self.sinkWarn and self.warnT <= 0 then
    audio.play("beep", 0.5)
    self.warnT = 0.42
  end
  local low = self.fuel > 0 and self.fuel < self.fuelStart * 0.12
  if low and not self.lowWarned then
    self.lowWarned = true
    self.note = { text = "LOW FUEL", t = 2.5 }
    audio.play("alarm", 0.6)
  elseif not low and self.fuel > 0 then
    self.lowWarned = false
  end
end

function Game:fixedStep(dt)
  local L, T = self.lander, self.terrain
  if self.phase == "fly" then
    self.time = self.time + dt
    local alt = L.y - T:height(L.x)
    self.env.windx = self:wind(alt)
    local used = L:step(dt, self.ctl, self.env, self.fuel)
    used = min(used, self.fuel)
    self.fuel = self.fuel - used
    self.sortieFuel = self.sortieFuel + used
    if self.fuel <= 0 and not self.fuelOutWarned then
      self.fuelOutWarned = true
      self.note = { text = "FUEL EXHAUSTED", t = 3 }
      audio.play("alarm", 0.8)
    end
    L.x = core.wrap(L.x, T.W)
    self:emit(dt)
    self:checkContact()
  elseif self.phase == "landed" then
    L.a = core.approach(L.a, 0, 10, dt)
    L.y = core.approach(L.y, self.restY, 10, dt)
    L.thr = core.approach(L.thr, 0, 12, dt)
  end
end

---------------------------------------------------------------------------
-- Particles: exhaust, ground dust, RCS puffs
---------------------------------------------------------------------------

local function puff(P, L, px, py, dirx, s, c)
  local rnd = love.math.random
  local wx, wy = L:toWorld(px, py)
  local sp = 6 + rnd() * 4
  P:add(wx, wy, L.vx + dirx * c * sp, L.vy + dirx * s * sp, 0.1 + rnd() * 0.1, 4, 0.8)
end

function Game:emit(dt)
  local L, P, T = self.lander, self.particles, self.terrain
  local rnd = love.math.random
  local s, c = sin(L.a), cos(L.a)
  local thr = L.thr

  if thr > 0.02 then
    local nx, ny = L:toWorld(0, Lander.NOZZLE_Y)
    local dx, dy = s, -c            -- exhaust direction: body "down"
    self.emitAcc = self.emitAcc + dt * 170 * thr
    while self.emitAcc >= 1 do
      self.emitAcc = self.emitAcc - 1
      local spread = (rnd() - 0.5) * 0.36
      local cs, sn = cos(spread), sin(spread)
      local ex, ey = dx * cs - dy * sn, dx * sn + dy * cs
      local sp = (22 + rnd() * 22) * (0.55 + 0.45 * thr)
      P:add(nx + ex * 0.3, ny + ey * 0.3, L.vx + ex * sp, L.vy + ey * sp,
        (0.12 + rnd() * 0.22) * (0.6 + 0.4 * thr), 1, 0.55 + rnd() * 0.45)
    end

    -- Where the plume meets the ground, it sprays dust sideways.
    local reach = 4 + 14 * thr
    local hit
    for d = 0, reach, 0.75 do
      local px, py = nx + dx * d, ny + dy * d
      if py <= T:height(px) then hit = d; break end
    end
    if hit then
      local inten = thr * (1 - hit / reach)
      self.dustAcc = self.dustAcc + dt * 120 * inten
      local hx = nx + dx * hit
      local hy = T:height(hx)
      local sl = T:slope(hx)
      local tl = sqrt(1 + sl * sl)
      local tx, ty = 1 / tl, sl / tl
      while self.dustAcc >= 1 do
        self.dustAcc = self.dustAcc - 1
        local side = (rnd() < 0.5 + dx * 0.8) and 1 or -1
        local sp = (8 + rnd() * 22) * (0.4 + 0.6 * inten)
        local el = 0.04 + rnd() * 0.3
        local ce, se = cos(el), sin(el)
        P:add(hx + side * rnd() * 1.5, hy + 0.15,
          side * tx * sp * ce - ty * sp * se,
          side * ty * sp * ce + tx * sp * se,
          0.5 + rnd() * 1.1, 2, 0.3 + rnd() * 0.4)
      end
    end
  end

  -- RCS: for CCW torque the top-right quad fires right, bottom-left fires left.
  if L.rcs ~= 0 and rnd() < 0.5 + abs(L.rcs) * 0.5 then
    local sg = L.rcs > 0 and 1 or -1
    puff(P, L, 2.0 * sg, 2.6, sg, s, c)
    puff(P, L, -2.0 * sg, -0.2, -sg, s, c)
  end
end

---------------------------------------------------------------------------
-- Contact and outcomes
---------------------------------------------------------------------------

function Game:checkContact()
  local L, T = self.lander, self.terrain
  local s, c = sin(L.a), cos(L.a)
  local x, y = L.x, L.y

  local FX, FY = Lander.FOOT_X, Lander.FOOT_Y
  local f1x, f1y = x - FX * c - FY * s, y - FX * s + FY * c
  local f2x, f2y = x + FX * c - FY * s, y + FX * s + FY * c
  local h1, h2 = T:height(f1x), T:height(f2x)
  local footHit = f1y <= h1 or f2y <= h2

  local hp = Lander.HULL_PTS
  for i = 1, #hp, 2 do
    local px, py = hp[i], hp[i + 1]
    local wx, wy = x + px * c - py * s, y + px * s + py * c
    if wy <= T:height(wx) then return self:crash("HULL STRUCK THE SURFACE") end
  end

  -- Terrain spikes poking into the body or the struts.
  local n = T:collect(x - 5, x + 5, self.vbx, self.vby)
  for i = 1, n do
    local dx, dy = self.vbx[i] - x, self.vby[i] - y
    if dy < 5 and dy > -3 then
      local lx, ly = dx * c + dy * s, -dx * s + dy * c
      if Lander.insideHull(lx, ly) then return self:crash("HULL STRUCK THE SURFACE") end
      if Lander.insideLeg(lx, ly) then return self:crash("LANDING STRUT SHEARED OFF") end
    end
  end

  if footHit then self:touchdown(f1x, f2x, h1, h2) end
end

function Game:touchdown(f1x, f2x, h1, h2)
  local L, T = self.lander, self.terrain
  local tol = self.rating.tol
  local vdown = -L.vy
  local hs = abs(L.vx)
  local tilt = abs(core.wrapAngle(L.a)) * 180 / math.pi

  local pad = T:padUnder(f1x, f2x)
  local flat = pad ~= nil
  if not flat then
    local lo, hi = math.huge, -math.huge
    for k = 0, 8 do
      local hh = T:height(f1x + (f2x - f1x) * k / 8)
      lo, hi = min(lo, hh), max(hi, hh)
    end
    flat = (hi - lo) < 0.7
  end

  local grade
  for _, g in ipairs(GRADES) do
    if vdown <= g.v * tol and hs <= g.h * tol and tilt <= g.tilt * tol then grade = g; break end
  end

  if not grade then
    local hard = GRADES[3]
    local rv, rh, rt = vdown / (hard.v * tol), hs / (hard.h * tol), tilt / (hard.tilt * tol)
    if rv >= rh and rv >= rt then
      return self:crash(string.format("IMPACT AT %.1f M/S", vdown))
    elseif rh >= rt then
      return self:crash(string.format("SIDE SLIP AT %.1f M/S", hs))
    else
      return self:crash(string.format("TOUCHED DOWN AT %d^ TILT", floor(tilt + 0.5)))
    end
  end
  if not flat then return self:crash("TIPPED OVER ON ROUGH GROUND") end

  self:land(grade, pad, vdown, hs, tilt, pad and pad.y or (h1 + h2) / 2)
end

function Game:land(grade, pad, vdown, hs, tilt, groundY)
  local L = self.lander
  self.phase = "landed"
  self.phaseT = 0
  L.vx, L.vy, L.w, L.rcs = 0, 0, 0, 0
  self.restY = groundY - Lander.FOOT_Y
  self.lever = 0

  local mult = pad and pad.mult or 1
  local pts = grade.points * mult
  local bonus = floor(grade.fuel * self.world.fuel / 1000 + 0.5)
  self.score = self.score + pts
  self.fuel = self.fuel + bonus
  self.stats[grade.id] = self.stats[grade.id] + 1

  local subs = SUBS[grade.id]
  local lines = {
    string.format("V %.1f   H %.1f M/S   TILT %d^", vdown, hs, floor(tilt + 0.5)),
    string.format("%d X %d = %d PTS", grade.points, mult, pts),
  }
  if bonus > 0 then lines[#lines + 1] = string.format("FUEL BONUS +%d KG", bonus) end
  if not pad then lines[#lines + 1] = "OFF-PAD LANDING - NO MULTIPLIER" end
  self.result = {
    kind = grade.id, title = grade.title,
    sub = subs[love.math.random(1, #subs)], lines = lines,
  }

  -- touchdown dust
  local rnd = love.math.random
  local P = self.particles
  local amount = floor(10 + vdown * 10)
  for _ = 1, amount do
    local side = rnd() < 0.5 and -1 or 1
    local fx = L.x + side * Lander.FOOT_X
    local sp = (2 + rnd() * 6) * (0.5 + vdown * 0.5)
    P:add(fx, groundY + 0.1, side * sp, sp * (0.1 + rnd() * 0.4), 0.6 + rnd() * 0.8, 2, 0.4)
  end

  if grade.id == "hard" then
    self.cam.shake = 0.45
    audio.play("thud", 0.9)
  else
    audio.play("chime", 0.7)
  end
end

function Game:crash(reason)
  local L = self.lander
  self.phase = "crashed"
  self.phaseT = 0
  self.landerVisible = false
  self:spawnDebris()

  local rnd = love.math.random
  local vs = core.clamp(sqrt(self.world.g / 1.62), 0.4, 1.5)
  for _ = 1, 70 do
    local a = rnd() * math.pi * 2
    local sp = (8 + rnd() * 28) * vs
    self.particles:add(L.x, L.y, L.vx * 0.3 + cos(a) * sp, L.vy * 0.2 + abs(sin(a)) * sp,
      0.5 + rnd() * 1.4, 3, 0.8 + rnd() * 0.2)
  end
  for _ = 1, 40 do
    local side = rnd() < 0.5 and -1 or 1
    local sp = (4 + rnd() * 16) * vs
    self.particles:add(L.x + side * rnd() * 3, self.terrain:height(L.x) + 0.2,
      side * sp, sp * (0.2 + rnd() * 0.6), 0.8 + rnd() * 1.5, 2, 0.45)
  end
  self.ring = { x = L.x, y = L.y, t = 0 }
  self.flash = 1
  self.cam.shake = 1
  L.thr, L.rcs = 0, 0

  local pen = floor(self.rating.penalty * self.world.fuel / 1000 + 0.5)
  self.fuel = max(0, self.fuel - pen)
  self.stats.crash = self.stats.crash + 1
  self.result = {
    kind = "crash", title = "LANDER DESTROYED", sub = reason,
    lines = { string.format("REPLACEMENT LANDER COSTS %d KG FUEL", pen) },
  }
  audio.play("explode", 0.9)
end

function Game:gameOver()
  self.phase = "gameover"
  self.phaseT = 0
  local id = self.world.id
  local best = settings.hiscores[id] or 0
  local record = self.score > best and not self.demo
  if record then
    settings.hiscores[id] = self.score
    settings.save()
  end
  local st = self.stats
  self.result = {
    kind = "gameover", title = "MISSION OVER",
    sub = record and "NEW RECORD FOR " .. self.world.name or ("BEST ON " .. self.world.name .. "  " .. best),
    lines = {
      string.format("FINAL SCORE %d", self.score),
      string.format("PERFECT %d  SOFT %d  HARD %d  LOST %d", st.perfect, st.soft, st.hard, st.crash),
    },
  }
  audio.play(record and "chime" or "beep", 0.6)
end

---------------------------------------------------------------------------
-- Debris: the lander breaks into its own line segments
---------------------------------------------------------------------------

function Game:spawnDebris()
  local L = self.lander
  local s, c = sin(L.a), cos(L.a)
  local rnd = love.math.random
  local vs = core.clamp(sqrt(self.world.g / 1.62), 0.4, 1.5)
  for _, pl in ipairs(Lander.SHAPE) do
    for i = 1, #pl - 2, 2 do
      local ax, ay = pl[i] * c - pl[i + 1] * s, pl[i] * s + pl[i + 1] * c
      local bx, by = pl[i + 2] * c - pl[i + 3] * s, pl[i + 2] * s + pl[i + 3] * c
      local mx, my = (ax + bx) / 2, (ay + by) / 2
      self.debris[#self.debris + 1] = {
        x = L.x + mx, y = L.y + my,
        hx = (bx - ax) / 2, hy = (by - ay) / 2,
        vx = L.vx * 0.3 + (mx * (1.5 + rnd() * 2.5) + (rnd() - 0.5) * 8) * vs,
        vy = max(-L.vy * 0.15, 0) + (my * (1 + rnd() * 2) + 4 + rnd() * 8) * vs,
        a = 0, w = (rnd() - 0.5) * 14, rest = false,
      }
    end
  end
end

function Game:updateDebris(dt)
  local T, g, rho, wind = self.terrain, self.world.g, self.world.rho, self.env.windx
  for _, d in ipairs(self.debris) do
    if not d.rest then
      d.vy = d.vy - g * dt
      if rho > 0 then
        local k = math.exp(-0.08 * rho * dt)
        d.vx = wind + (d.vx - wind) * k
        d.vy = d.vy * k
      end
      d.x = d.x + d.vx * dt
      d.y = d.y + d.vy * dt
      d.a = d.a + d.w * dt
      local ey = abs(d.hx * sin(d.a) + d.hy * cos(d.a))
      local gh = T:height(d.x)
      if d.y - ey <= gh then
        d.y = gh + ey
        if d.vy < 0 then d.vy = -d.vy * 0.3 end
        d.vx = d.vx * 0.6
        d.w = d.w * 0.5
        if abs(d.vy) < 0.8 and abs(d.vx) < 0.6 then d.rest = true end
      end
    end
  end
end

---------------------------------------------------------------------------
-- Camera: frames the lander and the ground beneath it, zooming in
-- smoothly as altitude drops.
---------------------------------------------------------------------------

function Game:updateCamera(dt, instant)
  local L, T, cam = self.lander, self.terrain, self.cam
  local VW, VH = core.VW, core.VH
  -- frame on the ground under the lander's footprint (not nearby peaks,
  -- which would push the pad you are aiming for off the bottom edge)
  local g = T:maxHeight(L.x - 5, L.x + 5)
  cam.ground = instant and g or core.approach(cam.ground, g, 2.5, dt)
  local alt = max(0, L.y + Lander.FOOT_Y - cam.ground)
  local zt = core.clamp(0.56 * VH / (alt + 16), Z_MIN, Z_MAX)
  if instant then
    cam.z = zt
  else
    cam.z = math.exp(core.approach(math.log(cam.z), math.log(zt), 1.8, dt))
  end
  local z = cam.z
  cam.cy = max(cam.ground + 0.33 * VH / z, L.y + 4.5 - 0.30 * VH / z)
  local lead = core.clamp(L.vx * 0.9, -0.22 * VW / z, 0.22 * VW / z)
  local tx = L.x + lead
  if instant then
    cam.cx = core.wrap(tx, T.W)
  else
    local d = core.wdelta(tx - cam.cx, T.W)
    cam.cx = core.wrap(cam.cx + d * (1 - math.exp(-3 * dt)), T.W)
  end
end

---------------------------------------------------------------------------
-- Draw
---------------------------------------------------------------------------

function Game:draw()
  local cam, view, T = self.cam, self.view, self.terrain
  local VW, VH = core.VW, core.VH
  local shx, shy = 0, 0
  if cam.shake > 0 then
    local rnd = love.math.random
    shx, shy = (rnd() - 0.5) * 12 * cam.shake, (rnd() - 0.5) * 12 * cam.shake
  end
  view.z = cam.z
  view.cx = cam.cx + shx / cam.z
  view.cy = cam.cy + shy / cam.z
  view.W = T.W

  scene.drawSky(view, T, self.world, 1)
  lg.setLineWidth(1.6)
  core.setc(0.92)
  scene.drawTerrain(view, T)
  scene.drawPads(view, T, true, 1)

  if self.ring then
    local sx, sy = scene.toScreen(view, self.ring.x, self.ring.y)
    local t = self.ring.t
    lg.setLineWidth(2)
    core.setc(1 - t / 0.8)
    lg.circle("line", sx, sy, (4 + t * 45) * view.z, 48)
  end

  self:drawDebris(view)
  self.particles:draw(view)

  local L = self.lander
  if self.landerVisible then
    Lander.draw(view, L.x, L.y, L.a, L.thr, 1)
  end

  if self.flash > 0 then
    core.setc(1, self.flash * 0.45)
    lg.rectangle("fill", 0, 0, VW, VH)
  end

  hud.draw(self)
end

function Game:drawDebris(view)
  lg.setLineWidth(core.clamp(view.z * 0.3, 1.1, 2))
  local z = view.z
  for _, d in ipairs(self.debris) do
    local c, s = cos(d.a), sin(d.a)
    local ex, ey = d.hx * c - d.hy * s, d.hx * s + d.hy * c
    local sx, sy = scene.toScreen(view, d.x, d.y)
    core.setc(d.rest and 0.5 or 0.95)
    lg.line(sx - ex * z, sy + ey * z, sx + ex * z, sy - ey * z)
  end
end

return Game
