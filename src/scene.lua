-- Shared scene drawing: starfield, sky object, terrain line and pads.
-- A "view" is { cx, cy, z, W }: camera centre (m), zoom (px/m), world width.

local core = require("src.core")
local vfont = require("src.vfont")
local lg = love.graphics

local S = {}

local stars
local pts = {}

local function makeStars()
  local rng = love.math.newRandomGenerator(4242)
  stars = {}
  for i = 1, 120 do
    stars[i] = {
      x = rng:random(), y = rng:random() * 0.9,
      b = 0.12 + rng:random() ^ 2 * 0.6,
      ph = rng:random() * 6.28, sp = 0.4 + rng:random() * 2.2,
      big = rng:random() < 0.12,
    }
  end
end

function S.toScreen(view, wx, wy)
  return core.VW / 2 + core.wdelta(wx - view.cx, view.W) * view.z,
         core.VH / 2 - (wy - view.cy) * view.z
end

function S.terrainScreenY(view, T, sx)
  local wx = view.cx + (sx - core.VW / 2) / view.z
  return core.VH / 2 - (T:height(wx) - view.cy) * view.z
end

-- Stars at infinity (fixed on screen). visible(sx, sy, margin) decides
-- whether a point is open sky - the ground is only a line, so stars must
-- not show through it.
function S.drawStarfield(world, dim, visible)
  if not stars then makeStars() end
  local VW, VH = core.VW, core.VH
  local count = math.floor(#stars * (world.stars or 1))
  local t = core.time
  for pass = 1, 2 do
    local big = pass == 2
    lg.setPointSize(big and 2 or 1.3)
    for i = 1, count do
      local st = stars[i]
      if st.big == big then
        local sx, sy = st.x * VW, st.y * VH
        if visible(sx, sy, 4) then
          core.setc(st.b * (0.7 + 0.3 * math.sin(t * st.sp + st.ph)) * dim)
          lg.points(sx, sy)
        end
      end
    end
  end
end

function S.drawSkyObject(world, dim, visible)
  if not world.sky then return end
  local ox, oy = core.VW * 0.80, core.VH * 0.26
  if visible(ox, oy, world.skyR * 2.5) then
    lg.setLineWidth(1.4)
    world.sky(ox, oy, world.skyR, dim)
  end
end

-- Stars and sky object above the local terrain.
function S.drawSky(view, T, world, dim)
  dim = dim or 1
  local function visible(sx, sy, margin) return sy + margin < S.terrainScreenY(view, T, sx) end
  S.drawStarfield(world, dim, visible)
  S.drawSkyObject(world, dim, visible)
end

function S.drawTerrain(view, T)
  local VW, VH, z = core.VW, core.VH, view.z
  local hw = VW / 2 / z + 2
  local xa, xb = view.cx - hw, view.cx + hw
  local W, n, xs, ys = T.W, T.n, T.xs, T.ys
  local k = math.floor(xa / W)
  local i = T:indexAt(xa - k * W)
  if i == 0 then i = n; k = k - 1 end
  local c = 0
  for _ = 1, n * 3 do
    local wx = xs[i] + k * W
    pts[c + 1] = VW / 2 + (wx - view.cx) * z
    pts[c + 2] = VH / 2 - (ys[i] - view.cy) * z
    c = c + 2
    if wx > xb then break end
    i = i + 1
    if i > n then i = 1; k = k + 1 end
  end
  for j = #pts, c + 1, -1 do pts[j] = nil end
  if c >= 4 then lg.line(pts) end
end

function S.drawPads(view, T, labels, dim)
  dim = dim or 1
  local VW, VH, z = core.VW, core.VH, view.z
  for _, p in ipairs(T.pads) do
    local sx = VW / 2 + core.wdelta(p.cx - view.cx, T.W) * z
    local hw = p.w / 2 * z
    if sx + hw > -40 and sx - hw < VW + 40 then
      local sy = VH / 2 - (p.y - view.cy) * z
      lg.setLineWidth(3)
      core.setc(dim)
      lg.line(sx - hw, sy, sx + hw, sy)
      -- beacon masts with blinking lights
      local bh = math.max(4, 1.4 * z)
      lg.setLineWidth(1.2)
      core.setc(0.6 * dim)
      lg.line(sx - hw, sy, sx - hw, sy - bh)
      lg.line(sx + hw, sy, sx + hw, sy - bh)
      if (core.time * 1.3 + p.cx * 0.013) % 1 < 0.45 then
        core.setc(dim)
        lg.circle("fill", sx - hw, sy - bh - 1.5, 1.7)
        lg.circle("fill", sx + hw, sy - bh - 1.5, 1.7)
      end
      if labels then
        local th = core.clamp(z * 1.9, 9, 13)
        core.setc(0.85 * dim)
        lg.setLineWidth(1.3)
        vfont.draw(p.label or ("X" .. p.mult), sx, sy + 7, th, "center")
      end
    end
  end
end

-- Buildings at mission sites (HQ hangar, fuel tanks, radio mast; outpost
-- dome and antenna), drawn in the same schematic line style.
function S.drawStructures(view, T)
  local structs = T.structs
  if not structs then return end
  local VW, VH, z = core.VW, core.VH, view.z
  local pi, cos, sin = math.pi, math.cos, math.sin
  lg.setLineWidth(core.clamp(z * 0.28, 1.1, 1.8))
  for _, s in ipairs(structs) do
    local sx = VW / 2 + core.wdelta(s.x - view.cx, T.W) * z
    local hw, h = s.w / 2 * z, s.h * z
    if sx + hw > -20 and sx - hw < VW + 20 then
      local sy = VH / 2 - (s.y - view.cy) * z
      core.setc(0.8)
      if s.kind == "hangar" then
        local wall = h * 0.55
        local p = { sx - hw, sy, sx - hw, sy - wall }
        for k = 0, 14 do
          local t = pi - pi * k / 14
          p[#p + 1] = sx + cos(t) * hw
          p[#p + 1] = sy - wall - sin(t) * (h - wall)
        end
        p[#p + 1] = sx + hw
        p[#p + 1] = sy
        lg.line(p)
        core.setc(0.45)
        lg.line(sx - hw * 0.5, sy, sx - hw * 0.5, sy - wall * 0.85, sx + hw * 0.5, sy - wall * 0.85, sx + hw * 0.5, sy)
        for k = -1, 1 do lg.line(sx + k * hw * 0.5, sy - wall - (h - wall) * 0.15, sx + k * hw * 0.62, sy - wall - (h - wall) * 0.95) end
      elseif s.kind == "tank" then
        local top = sy - h + hw
        lg.line(sx - hw, sy, sx - hw, top)
        lg.line(sx + hw, sy, sx + hw, top)
        lg.arc("line", "open", sx, top, hw, pi, 2 * pi, 12)
        core.setc(0.45)
        lg.line(sx - hw, sy - h * 0.3, sx + hw, sy - h * 0.3)
        lg.line(sx - hw, sy - h * 0.6, sx + hw, sy - h * 0.6)
      elseif s.kind == "mast" then
        local w2 = math.max(1.5, hw * 1.6)
        lg.line(sx - w2, sy, sx, sy - h, sx + w2, sy)
        core.setc(0.45)
        for k = 1, 4 do
          local f = k / 5
          lg.line(sx - w2 * (1 - f), sy - h * f, sx + w2 * (1 - f), sy - h * f)
        end
        if (core.time * 1.1) % 1 < 0.5 then
          core.setc(1)
          lg.circle("fill", sx, sy - h - 2, 2)
        end
      elseif s.kind == "dome" then
        lg.arc("line", "open", sx, sy, hw, pi, 2 * pi, 24)
        core.setc(0.45)
        lg.line(sx - hw * 0.22, sy, sx - hw * 0.22, sy - h * 0.4, sx + hw * 0.22, sy - h * 0.4, sx + hw * 0.22, sy)
        lg.arc("line", "open", sx, sy, hw * 0.7, pi * 1.15, pi * 1.4, 6)
        lg.arc("line", "open", sx, sy, hw * 0.7, pi * 1.6, pi * 1.85, 6)
      elseif s.kind == "antenna" then
        lg.line(sx, sy, sx, sy - h)
        lg.arc("line", "open", sx + hw * 1.5, sy - h, hw * 3, pi * 0.75, pi * 1.25, 8)
        if (core.time * 0.9 + 0.3) % 1 < 0.5 then
          core.setc(1)
          lg.circle("fill", sx, sy - h - 1.5, 1.5)
        end
      end
    end
  end
end

return S
