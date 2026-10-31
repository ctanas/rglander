-- Orbital view for arcade mode.
--
-- The physics never changes: lander.lua already integrates the exact
-- polar equations of motion (x = surface arc length, y = altitude). This
-- module turns that state into an inertial position/velocity and Kepler
-- elements, and draws the whole world: the planet, the predicted orbit,
-- apoapsis/periapsis and the lander. The view is rotated so the lander's
-- local "up" is always screen-up, and the camera blends continuously from
-- the surface camera (low) to a view that fits the orbit (high).

local core = require("src.core")
local vfont = require("src.vfont")
local scene = require("src.scene")
local Lander = require("src.lander")
local lg = love.graphics
local sin, cos, sqrt, atan2, abs, exp, log, min, max, pi =
  math.sin, math.cos, math.sqrt, math.atan2, math.abs, math.exp, math.log, math.min, math.max, math.pi

local Orbit = {}

Orbit.UP_ALT = 700        -- switch to the orbital view above this altitude (m)
Orbit.DOWN_ALT = 600      -- and back to the surface view below this
Orbit.BLEND_TOP = 3000    -- camera fully zoomed out to the orbit above this
Orbit.WARPS = { 1, 4, 16, 64 }
Orbit.LOST_R = 7          -- beyond this many radii the lander is lost

function Orbit.mu(w) return w.g * w.R * w.R end

-- Altitude above which the air no longer drags an orbiting lander down.
function Orbit.atmosphereTop(w)
  if not w.H or w.rho <= 0 then return 0 end
  return w.H * log(w.rho / 3e-5)
end

-- Lowest periapsis that counts as a real orbit.
function Orbit.safeAltitude(g)
  return max(Orbit.atmosphereTop(g.world), g.terrain.maxH + 1000)
end

function Orbit.density(w, alt)
  if w.rho <= 0 then return 0 end
  if not w.H then return w.rho end
  return w.rho * exp(-max(0, alt) / w.H)
end

-- Inertial state. Angle theta is measured clockwise from "north" so that
-- increasing theta is eastward (+x on the surface). r_hat = (sin, cos),
-- east = (cos, -sin).
function Orbit.state(g)
  local L, R = g.lander, g.world.R
  local th = g.xu / R
  local r = R + L.y
  local st, ct = sin(th), cos(th)
  return r * st, r * ct, L.vx * ct + L.vy * st, -L.vx * st + L.vy * ct, th, r
end

function Orbit.elements(g)
  local mu = Orbit.mu(g.world)
  local px, py, vx, vy, th, r = Orbit.state(g)
  local v2 = vx * vx + vy * vy
  local eps = v2 / 2 - mu / r
  local h = px * vy - py * vx
  local rv = px * vx + py * vy
  local k = v2 - mu / r
  local ex, ey = (k * px - rv * vx) / mu, (k * py - rv * vy) / mu
  local e = sqrt(ex * ex + ey * ey)
  local el = { e = e, h = h, eps = eps, p = h * h / mu, thetaPe = atan2(ex, ey),
               r = r, theta = th, v = sqrt(v2), mu = mu, bound = eps < 0 }
  el.rp = el.p / (1 + e)
  if el.bound then
    el.a = -mu / (2 * eps)
    el.ra = el.a * (1 + e)
    el.period = 2 * pi * sqrt(el.a ^ 3 / mu)
  end
  return el
end

---------------------------------------------------------------------------
-- Camera. In the rotated frame the lander sits at (0, r). The camera is
-- described by its zoom s (px/m) and the lander's screen position (lx, ly).
-- Low down it matches the surface camera; high up the whole orbit fits.
-- In between, zoom blends geometrically while the lander's screen position
-- blends linearly, so the lander - and the ground below it - never leave
-- the screen during the zoom.
---------------------------------------------------------------------------

local function targets(g)
  local VW, VH = core.VW, core.VH
  local L, T, R = g.lander, g.terrain, g.world.R
  local el = g.el
  local r = R + L.y
  -- close: exactly the surface camera framing (game.lua updateCamera)
  local ground = T:maxHeight(L.x - 5, L.x + 5)
  local alt = max(0, L.y + Lander.FOOT_Y - ground)
  local sc = core.clamp(0.56 * VH / (alt + 16), g.zMin, g.zMax)
  local lead = core.clamp(L.vx * 0.9, -0.22 * VW / sc, 0.22 * VW / sc)
  local cyc = max(ground + 0.33 * VH / sc, L.y + 4.5 - 0.30 * VH / sc)
  local lxc, lyc = VW / 2 - lead * sc, VH / 2 - (L.y - cyc) * sc
  -- far: the planet centred a little low, the whole orbit in view
  local ext = max(R * 1.1, el.r * 1.08)
  if el.bound then ext = max(ext, min(el.ra, 6 * R) * 1.05) end
  local sf = 0.40 * VH / ext
  local lxf, lyf = VW / 2, VH / 2 + 18 - r * sf
  local f = core.clamp((Orbit.BLEND_TOP - L.y) / (Orbit.BLEND_TOP - Orbit.DOWN_ALT), 0, 1)
  f = f * f * (3 - 2 * f)
  return exp(core.lerp(log(sf), log(sc), f)), core.lerp(lxf, lxc, f), core.lerp(lyf, lyc, f)
end

-- Derive the drawing transform (centre and anchor) from s, lx, ly.
local function resolve(g)
  local oc = g.ocam
  local r = g.world.R + g.lander.y
  oc.ax, oc.ay = core.VW / 2, core.VH / 2
  oc.cx = (oc.ax - oc.lx) / oc.s
  oc.cy = r - (oc.ay - oc.ly) / oc.s
end

-- Start from the surface camera so the switch is seamless.
function Orbit.enterCamera(g)
  local cam, oc, L = g.cam, g.ocam, g.lander
  oc.s = cam.z
  oc.lx = core.VW / 2 + core.wdelta(L.x - cam.cx, g.terrain.W) * cam.z
  oc.ly = core.VH / 2 - (L.y - cam.cy) * cam.z
  resolve(g)
end

-- Hand the camera back to the surface view.
function Orbit.exitCamera(g)
  local cam, oc, L = g.cam, g.ocam, g.lander
  cam.z = core.clamp(oc.s, g.zMin, g.zMax)
  cam.cx = core.wrap(L.x - (oc.lx - core.VW / 2) / cam.z, g.terrain.W)
  cam.cy = L.y - (core.VH / 2 - oc.ly) / cam.z
  cam.ground = g.terrain:maxHeight(L.x - 5, L.x + 5)
end

function Orbit.updateCamera(g, dt)
  local oc = g.ocam
  local s, lx, ly = targets(g)
  local k = 1 - exp(-4 * dt)
  oc.s = exp(log(oc.s) + (log(s) - log(oc.s)) * k)
  oc.lx = oc.lx + (lx - oc.lx) * k
  oc.ly = oc.ly + (ly - oc.ly) * k
  resolve(g)
end

---------------------------------------------------------------------------
-- Drawing
---------------------------------------------------------------------------

local pts = {}

local function lineFlush(n)
  if n >= 4 then
    for j = #pts, n + 1, -1 do pts[j] = nil end
    lg.line(pts)
  end
  return 0
end

-- Draw a curve given by polar points (phi relative to the lander, radius);
-- gaps where radius < cut (hidden inside the planet).
local function polar(oc, phi, r)
  return oc.ax + (r * sin(phi) - oc.cx) * oc.s, oc.ay - (r * cos(phi) - oc.cy) * oc.s
end

local CRATERS = {
  moon = { { 0.6, 0.55, 0.13 }, { 2.2, 0.35, 0.18 }, { 3.6, 0.7, 0.09 }, { 4.9, 0.5, 0.15 }, { 5.6, 0.25, 0.1 } },
  ceres = { { 1.1, 0.5, 0.16 }, { 2.9, 0.65, 0.1 }, { 4.4, 0.4, 0.2 } },
}

local function drawPlanet(g)
  local oc, w, T, R = g.ocam, g.world, g.terrain, g.world.R
  local th0 = g.el.theta
  local Rpx = R * oc.s
  local n = 0
  if Rpx < core.VW * 3 then
    -- whole disc
    lg.setLineWidth(1.6)
    core.setc(0.92)
    local N = 160
    for k = 0, N do
      local sx, sy = polar(oc, 2 * pi * k / N, R)
      pts[n + 1], pts[n + 2] = sx, sy
      n = n + 2
    end
    lineFlush(n)
    -- schematic surface features fixed to the body (they turn as you orbit)
    lg.setLineWidth(1.1)
    core.setc(0.3)
    for _, c in ipairs(CRATERS[w.id] or {}) do
      local sx, sy = polar(oc, c[1] - th0, R * c[2])
      lg.circle("line", sx, sy, c[3] * Rpx * 0.5, 20)
    end
    if w.id == "mars" then
      for _, a0 in ipairs({ 0, pi }) do
        n = 0
        for k = -6, 6 do
          local sx, sy = polar(oc, a0 - th0 + k * 0.06, R * 0.93)
          pts[n + 1], pts[n + 2] = sx, sy
          n = n + 2
        end
        lineFlush(n)
      end
    end
    -- atmosphere boundary, dashed
    local top = Orbit.atmosphereTop(w)
    if top > 0 then
      core.setc(0.28)
      for k = 0, 71, 2 do
        local sa, sb = 2 * pi * k / 72, 2 * pi * (k + 1) / 72
        local x1, y1 = polar(oc, sa, R + top)
        local x2, y2 = polar(oc, sb, R + top)
        lg.line(x1, y1, x2, y2)
      end
    end
  else
    -- close up: the real terrain, wrapped around the body
    lg.setLineWidth(1.6)
    core.setc(0.92)
    local half = min(pi, (core.VW / oc.s) / R)
    local step = max(6 / (oc.s * R), 10 / R)
    for phi = -half, half + step * 0.5, step do
      local sx, sy = polar(oc, phi, R + T:height(g.xu + phi * R))
      pts[n + 1], pts[n + 2] = sx, sy
      n = n + 2
    end
    lineFlush(n)
  end
end

local function drawPath(g)
  local oc, R, el = g.ocam, g.world.R, g.el
  if el.e < 1e-9 and el.p < 1 then return end
  local th0 = el.theta
  lg.setLineWidth(1.2)
  core.setc(0.55)
  local n = 0
  local N = 180
  local function plot(nu)
    local r = el.p / (1 + el.e * cos(nu))
    if r >= R and r < Orbit.LOST_R * R * 1.5 then
      local sx, sy = polar(oc, el.thetaPe + nu - th0, r)
      pts[n + 1], pts[n + 2] = sx, sy
      n = n + 2
    else
      n = lineFlush(n)
    end
  end
  if el.bound then
    for k = 0, N do plot(2 * pi * k / N) end
  else
    local numax = (el.e > 1 and math.acos(-1 / el.e) or pi) - 0.03
    for k = 0, N do plot(-numax + 2 * numax * k / N) end
  end
  lineFlush(n)

  -- apsis markers
  lg.setLineWidth(1.2)
  local function mark(nu, r, label)
    local sx, sy = polar(oc, el.thetaPe + nu - th0, r)
    core.setc(0.9)
    lg.circle("line", sx, sy, 3, 10)
    core.setc(0.7)
    vfont.draw(label, sx + 6, sy - 4, 8)
  end
  if el.rp > R then mark(0, el.rp, "PE") end
  if el.bound and el.ra < Orbit.LOST_R * R then mark(pi, el.ra, "AP") end
end

function Orbit.draw(g)
  local oc, R, w = g.ocam, g.world.R, g.world
  local pcx, pcy = polar(oc, 0, 0)
  local Rpx = R * oc.s
  local function visible(sx, sy, margin)
    local dx, dy = sx - pcx, sy - pcy
    return dx * dx + dy * dy > (Rpx + margin) ^ 2
  end
  scene.drawStarfield(w, 1, visible)
  scene.drawSkyObject(w, 1, visible)
  drawPlanet(g)
  drawPath(g)
  if g.landerVisible then
    local L = g.lander
    local sx, sy = polar(oc, 0, R + L.y)
    Lander.drawAt(sx, sy, L.a, max(oc.s, 1.8), L.out, 1)
  end
end

return Orbit
