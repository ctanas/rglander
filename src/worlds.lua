-- Landing sites. Gravity and surface air density are real values; the
-- lander's engine is sized per world (see game.lua) so each one is flyable.

local core = require("src.core")
local lg = love.graphics
local sin, cos, pi, sqrt = math.sin, math.cos, math.pi, math.sqrt

---------------------------------------------------------------------------
-- Schematic sky objects (drawn at a fixed screen spot: they are "at
-- infinity", so they do not move as the camera translates).
---------------------------------------------------------------------------

local function earth(x, y, r, dim)
  core.setc(0.9 * dim)
  lg.arc("line", "open", x, y, r, -pi / 2, pi / 2, 24)          -- lit limb
  core.setc(0.28 * dim)
  lg.arc("line", "open", x, y, r, pi / 2, 3 * pi / 2, 24)       -- night limb
  -- terminator (gibbous phase)
  core.setc(0.7 * dim)
  local pts = {}
  for i = 0, 20 do
    local t = -pi / 2 + pi * i / 20
    pts[#pts + 1] = x - 0.35 * r * cos(t)
    pts[#pts + 1] = y + r * sin(t)
  end
  lg.line(pts)
  -- a couple of cloud bands on the day side
  core.setc(0.45 * dim)
  lg.line(x - 0.05 * r, y - 0.45 * r, x + 0.55 * r, y - 0.5 * r, x + 0.8 * r, y - 0.35 * r)
  lg.line(x + 0.05 * r, y + 0.25 * r, x + 0.45 * r, y + 0.15 * r, x + 0.75 * r, y + 0.3 * r)
end

local function ellipseRing(x, y, rx, ry, rot, pr)
  local cr, sr = cos(rot), sin(rot)
  local seg = {}
  local function flush()
    if #seg >= 4 then lg.line(seg) end
    seg = {}
  end
  for i = 0, 72 do
    local t = i / 72 * 2 * pi
    local ex, ey = rx * cos(t), ry * sin(t)
    local px, py = x + ex * cr - ey * sr, y + ex * sr + ey * cr
    -- far half of the ring is hidden behind the planet disc
    local hidden = ey < 0 and ((px - x) ^ 2 + (py - y) ^ 2) < pr * pr
    if hidden then flush() else
      seg[#seg + 1] = px
      seg[#seg + 1] = py
    end
  end
  flush()
end

local function saturn(x, y, r, dim)
  local rot = -0.38
  core.setc(0.85 * dim)
  lg.circle("line", x, y, r, 36)
  core.setc(0.35 * dim)
  local cr, sr = cos(rot), sin(rot)
  for _, d in ipairs({ -0.45, 0.3 }) do
    local hw = sqrt(1 - d * d) * r * 0.92
    local ox, oy = -d * r * sr, d * r * cr
    lg.line(x + ox - hw * cr, y + oy - hw * sr, x + ox + hw * cr, y + oy + hw * sr)
  end
  core.setc(0.8 * dim)
  ellipseRing(x, y, r * 2.3, r * 0.55, rot, r)
  core.setc(0.45 * dim)
  ellipseRing(x, y, r * 1.75, r * 0.4, rot, r)
end

local POTATO = { 1, 0, 0.7, 0.62, 0.1, 0.9, -0.5, 0.78, -0.95, 0.2, -0.82, -0.45, -0.2, -0.86, 0.5, -0.7, 1, 0 }

local function rock(x, y, r, b)
  local pts = {}
  for i = 1, #POTATO, 2 do
    pts[#pts + 1] = x + POTATO[i] * r * 1.3
    pts[#pts + 1] = y + POTATO[i + 1] * r
  end
  core.setc(b)
  lg.line(pts)
end

local function marsMoons(x, y, r, dim)
  rock(x, y, r, 0.85 * dim)
  core.setc(0.35 * dim)
  lg.circle("line", x - 0.3 * r, y + 0.1 * r, r * 0.28, 12)   -- Stickney crater
  rock(x - 78, y + 26, r * 0.42, 0.6 * dim)
end

local function sun(x, y, r, dim)
  core.setc(0.9 * dim)
  lg.circle("line", x, y, r, 20)
  core.setc(0.45 * dim)
  for k = 0, 7 do
    local a = k * pi / 4 + pi / 8
    lg.line(x + cos(a) * r * 1.7, y + sin(a) * r * 1.7, x + cos(a) * r * 2.6, y + sin(a) * r * 2.6)
  end
end

---------------------------------------------------------------------------

return {
  {
    id = "moon", name = "MOON",
    g = 1.62, rho = 0, wind = 0, gust = 0,
    fuel = 1000, relief = 110, rough = 0.56, craters = 4,
    pads = { 2, 2, 3, 4, 5 },
    stars = 1.0, sky = earth, skyR = 16,
    atmo = "NO ATMOSPHERE",
    blurb = "GENTLE GRAVITY, NO AIR. A PURE TEST OF PILOTING",
  },
  {
    id = "mars", name = "MARS",
    g = 3.71, rho = 0.020, wind = 8, gust = 10,
    fuel = 1500, relief = 125, rough = 0.5, craters = 2,
    pads = { 2, 3, 3, 4, 5 },
    stars = 0.6, sky = marsMoons, skyR = 9,
    atmo = "THIN CO2 AIR 0.020 KG/M3",
    blurb = "HEAVY AND FAST. THE THIN AIR WILL NOT SAVE YOU",
  },
  {
    id = "titan", name = "TITAN",
    g = 1.35, rho = 5.3, wind = 1.5, gust = 2.5,
    fuel = 900, relief = 70, rough = 0.42, craters = 0,
    pads = { 2, 2, 3, 4, 5 },
    stars = 0.25, sky = saturn, skyR = 13,
    atmo = "DENSE N2 AIR 5.3 KG/M3",
    blurb = "THICK AIR BRAKES YOUR FALL - AND THE WIND PUSHES",
  },
  {
    id = "ceres", name = "CERES",
    g = 0.28, rho = 0, wind = 0, gust = 0,
    fuel = 600, relief = 140, rough = 0.6, craters = 5,
    pads = { 2, 3, 4, 5, 5 },
    stars = 1.0, sky = sun, skyR = 5,
    atmo = "NO ATMOSPHERE",
    blurb = "ALMOST WEIGHTLESS. PATIENCE SAVES FUEL",
  },
}
