-- The lander: geometry, rigid-body flight physics and vector drawing.
--
-- Physics model (SI units, y up, angle counter-clockwise, 0 = upright):
--   * mass m = dry mass + propellant + cargo; the lander gets lighter as
--     it burns (and when cargo is delivered)
--   * main engine: thrust F = Fmax * throttle along the body axis, with a
--     first-order spool lag; propellant flow dm/dt = F / ve (so the rocket
--     equation emerges naturally from integrating F/m)
--   * attitude: RCS torque against moment of inertia I = m * k^2. In
--     "assisted" mode the stick commands a rotation *rate* and the RCS
--     nulls it when released; in "manual" mode the stick commands torque
--   * atmosphere (if any): quadratic drag 1/2 rho Cd A |v_rel| v_rel
--     relative to the wind, plus aerodynamic damping of rotation; with
--     env.H the density falls as exp(-altitude / H)
--   * round body (env.R, arcade): (x, y) are surface arc length and
--     altitude, vx/vy the tangential/radial velocity. The exact polar
--     equations add gravity falling off as (R/r)^2, the centripetal term
--     vx^2/r and the Coriolis term -vx*vy/r. They vanish at landing speeds
--     but make ~sqrt(gR) sideways a real orbit.
--   * damage (missions only, lander.dmg = health 0..1 per system):
--     engine -> less thrust and sputtering; rcs -> weaker jets and a stuck
--     thruster that makes it drift; tank -> leaks propellant
-- Integrated with semi-implicit Euler at a fixed 120 Hz by game.lua.

local core = require("src.core")
local lg = love.graphics
local sin, cos, abs, exp = math.sin, math.cos, math.abs, math.exp

local Lander = {}
Lander.__index = Lander

Lander.DRY = 2000        -- kg, dry mass
Lander.VE = 2000         -- m/s, effective exhaust velocity (Isp ~ 204 s)
Lander.K2 = 2.2          -- m^2, radius of gyration squared
Lander.CDA = 16          -- m^2, drag coefficient x reference area
Lander.SPOOL = 0.12      -- s, engine throttle time constant
Lander.MAX_RATE = 1.5    -- rad/s, assisted-mode rotation rate limit
Lander.RCS_FUEL = 0.35   -- kg/s at full RCS authority
Lander.FOOT_X = 3.6
Lander.FOOT_Y = -1.95
Lander.NOZZLE_Y = -1.45

-- Line art, metres, origin at the centre of mass.
Lander.SHAPE = {
  { -2.0, -0.6, 2.0, -0.6, 2.0, 0.8, -2.0, 0.8, -2.0, -0.6 },                     -- descent stage
  { -1.5, 0.8, -2.1, 1.7, -1.7, 2.9, -0.7, 3.4, 0.7, 3.4, 1.7, 2.9, 2.1, 1.7, 1.5, 0.8 }, -- cabin
  { -1.0, 2.0, -0.6, 2.7, 0.6, 2.7, 1.0, 2.0, -1.0, 2.0 },                         -- window
  { 1.0, 3.25, 1.5, 4.1 },                                                         -- antenna mast
  { 1.15, 4.35, 1.85, 3.85 },                                                      -- antenna dish
  { -2.0, 0.5, -3.6, -1.9 },                                                       -- left primary strut
  { -2.0, -0.4, -2.88, -0.82 },                                                    -- left secondary strut
  { -4.1, -1.95, -3.1, -1.95 },                                                    -- left foot pad
  { 2.0, 0.5, 3.6, -1.9 },
  { 2.0, -0.4, 2.88, -0.82 },
  { 4.1, -1.95, 3.1, -1.95 },
  { -0.55, -0.6, -0.95, -1.45, 0.95, -1.45, 0.55, -0.6 },                          -- engine bell
}

-- Convex hull of the body (CCW), used to catch terrain spikes.
Lander.HULL = { -2.0, -0.6, -0.95, -1.45, 0.95, -1.45, 2.0, -0.6, 2.1, 1.7,
                1.7, 2.9, 0.7, 3.4, -0.7, 3.4, -1.7, 2.9, -2.1, 1.7 }

-- Points that must never touch the ground (everything except the feet).
Lander.HULL_PTS = { -2.0, -0.6, -0.95, -1.45, 0.95, -1.45, 2.0, -0.6, 2.1, 1.7,
                    1.7, 2.9, 0.7, 3.4, -0.7, 3.4, -1.7, 2.9, -2.1, 1.7,
                    -2.88, -0.82, 2.88, -0.82, 1.5, 4.1 }

-- Strut triangles (stopping short of the feet).
Lander.LEGS = {
  { -2.0, 0.5, -3.25, -1.38, -2.0, -0.6 },
  { 2.0, 0.5, 3.25, -1.38, 2.0, -0.6 },
}

function Lander.new(x, y, vx, vy, spec)
  return setmetatable({
    x = x, y = y, vx = vx, vy = vy,
    a = 0, w = 0,            -- angle, angular velocity
    thr = 0,                 -- spooled throttle 0..1
    out = 0,                 -- thrust actually produced, as a fraction of Fmax
    rcs = 0,                 -- signed RCS activity -1..1
    Fmax = spec.Fmax,
    torqueMax = spec.torqueMax,
    assisted = spec.assisted,
    cargo = spec.cargo or 0, -- kg
    dmg = spec.dmg,          -- nil = undamageable (arcade)
    sputT = 0,
  }, Lander)
end

function Lander:mass(fuel) return Lander.DRY + fuel + self.cargo end

-- Fraction of rated thrust a damaged engine can still give.
function Lander:engineFactor()
  local d = self.dmg
  return d and (0.55 + 0.45 * d.engine) or 1
end

-- Propellant lost through a damaged tank, kg/s.
function Lander:leakRate()
  local d = self.dmg
  if d and d.tank < 0.95 then return (1 - d.tank) * 2.5 end
  return 0
end

-- Advance one fixed step. ctl = { thr = 0..1, rot = -1..1 }.
-- env = { g, rho, windx }. Returns propellant used (kg).
function Lander:step(dt, ctl, env, fuel)
  local m = self:mass(fuel)
  local d = self.dmg
  local cmd = fuel > 0 and core.clamp(ctl.thr, 0, 1) or 0
  self.thr = self.thr + (cmd - self.thr) * (1 - exp(-dt / Lander.SPOOL))
  if cmd == 0 and self.thr < 0.003 then self.thr = 0 end
  local Fmax = self.Fmax * self:engineFactor()
  if d and d.engine < 0.7 then
    -- a damaged engine sputters: irregular dips in thrust
    self.sputT = self.sputT + dt
    local s = self.sputT
    local dip = (0.7 - d.engine) * 1.3 * math.max(0, sin(s * 11.3) * sin(s * 2.9 + 1.3))
    Fmax = Fmax * (1 - math.min(0.85, dip))
  end
  local F = Fmax * self.thr
  self.out = F / self.Fmax
  local used = F / Lander.VE * dt + self:leakRate() * dt

  -- Attitude control
  local I = m * Lander.K2
  local tmax = self.torqueMax * (d and (0.35 + 0.65 * d.rcs) or 1)
  local torque
  if self.assisted then
    local target = core.clamp(ctl.rot, -1, 1) * Lander.MAX_RATE
    torque = core.clamp((target - self.w) * I / dt, -tmax, tmax)
  else
    torque = core.clamp(ctl.rot, -1, 1) * tmax
    if abs(self.w) > 3 and torque * self.w > 0 then torque = 0 end
  end
  if d and d.rcs < 0.6 then
    -- a stuck thruster pushes one way; assisted mode fights it
    torque = torque + (0.6 - d.rcs) * 0.25 * self.torqueMax * (d.rcsBias or 1)
  end
  if fuel <= 0 then torque = 0 end
  self.rcs = core.clamp(torque / tmax, -1, 1)
  if abs(self.rcs) < 0.01 then self.rcs = 0 end
  used = used + abs(self.rcs) * Lander.RCS_FUEL * dt
  self.w = self.w + torque / I * dt

  -- Translation
  local s, c = sin(self.a), cos(self.a)
  local ax = -s * F / m
  local ay = c * F / m
  local R = env.R
  local r
  if R then
    r = R + math.max(self.y, -0.5 * R)
    local gr = env.g * (R / r) ^ 2
    ay = ay - gr + self.vx * self.vx / r
    ax = ax - self.vy * self.vx / r
  else
    ay = ay - env.g
  end
  local rho = env.rho
  if rho > 0 then
    if env.H then rho = rho * exp(-math.max(0, self.y) / env.H) end
    local rvx, rvy = self.vx - env.windx, self.vy
    local sp = math.sqrt(rvx * rvx + rvy * rvy)
    local k = 0.5 * rho * Lander.CDA * sp / m
    ax = ax - k * rvx
    ay = ay - k * rvy
    self.w = self.w * exp(-0.12 * rho * dt)
  end
  self.vx = self.vx + ax * dt
  self.vy = self.vy + ay * dt
  if R then
    self.x = self.x + self.vx * dt * R / r          -- arc length along the surface
    -- the horizon turns as you travel; an uncontrolled craft keeps its
    -- inertial attitude (assisted mode holds attitude to the horizon)
    if not self.assisted then self.a = self.a + self.vx / r * dt end
  else
    self.x = self.x + self.vx * dt
  end
  self.y = self.y + self.vy * dt
  self.a = self.a + self.w * dt
  return used
end

function Lander:toWorld(px, py)
  local s, c = sin(self.a), cos(self.a)
  return self.x + px * c - py * s, self.y + px * s + py * c
end

local function insideConvex(poly, x, y)
  local n = #poly
  for i = 1, n, 2 do
    local ax, ay = poly[i], poly[i + 1]
    local j = i + 2
    if j > n then j = 1 end
    local bx, by = poly[j], poly[j + 1]
    if (bx - ax) * (y - ay) - (by - ay) * (x - ax) < 0 then return false end
  end
  return true
end

local function insideTri(t, x, y)
  local d1 = (x - t[3]) * (t[2] - t[4]) - (t[1] - t[3]) * (y - t[4])
  local d2 = (x - t[5]) * (t[4] - t[6]) - (t[3] - t[5]) * (y - t[6])
  local d3 = (x - t[1]) * (t[6] - t[2]) - (t[5] - t[1]) * (y - t[2])
  local neg = d1 < 0 or d2 < 0 or d3 < 0
  local pos = d1 > 0 or d2 > 0 or d3 > 0
  return not (neg and pos)
end

function Lander.insideHull(lx, ly) return insideConvex(Lander.HULL, lx, ly) end

function Lander.insideLeg(lx, ly)
  return insideTri(Lander.LEGS[1], lx, ly) or insideTri(Lander.LEGS[2], lx, ly)
end

---------------------------------------------------------------------------
-- Drawing
---------------------------------------------------------------------------

local bufs = {}
local function getbuf(n)
  local b = bufs[n]
  if not b then b = {}; bufs[n] = b end
  return b
end

local function drawPoly(pl, sx0, sy0, s, c, z)
  local n = #pl
  local b = getbuf(n)
  for i = 1, n, 2 do
    local px, py = pl[i], pl[i + 1]
    b[i] = sx0 + (px * c - py * s) * z
    b[i + 1] = sy0 - (px * s + py * c) * z
  end
  lg.line(b)
end

local flame = { 0, 0, 0, 0, 0, 0 }

-- Smallest on-screen scale (px/m) for the lander art, so it stays legible
-- on a 3.4" panel when the camera is zoomed out at high altitude. Near
-- the ground the camera zoom is always larger, so contact looks exact.
Lander.MIN_DRAW_Z = 2.6

-- Draw the lander at world position (x, y) using camera `view`.
function Lander.draw(view, x, y, a, thr, bright)
  local VW, VH = core.VW, core.VH
  local sx0 = VW / 2 + core.wdelta(x - view.cx, view.W) * view.z
  local sy0 = VH / 2 - (y - view.cy) * view.z
  Lander.drawAt(sx0, sy0, a, math.max(view.z, Lander.MIN_DRAW_Z), thr, bright)
end

-- Draw the lander centred on screen point (sx0, sy0) at z px per metre.
function Lander.drawAt(sx0, sy0, a, z, thr, bright)
  local s, c = sin(a), cos(a)
  lg.setLineWidth(core.clamp(z * 0.32, 1.25, 2.1))
  core.setc(bright or 1)
  for _, pl in ipairs(Lander.SHAPE) do drawPoly(pl, sx0, sy0, s, c, z) end

  if thr > 0.02 then
    local rnd = love.math.random
    local len = thr * (4.2 + rnd() * 1.4)
    local ny = Lander.NOZZLE_Y
    flame[1], flame[2] = -0.7, ny
    flame[3], flame[4] = (rnd() - 0.5) * 0.4, ny - len
    flame[5], flame[6] = 0.7, ny
    core.setc(1)
    drawPoly(flame, sx0, sy0, s, c, z)
    flame[1], flame[2] = -0.35, ny
    flame[3], flame[4] = (rnd() - 0.5) * 0.2, ny - len * 0.55
    flame[5], flame[6] = 0.35, ny
    core.setc(0.7)
    drawPoly(flame, sx0, sy0, s, c, z)
  end
end

return Lander
