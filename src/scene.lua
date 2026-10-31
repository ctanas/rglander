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

-- Stars and sky object; both only drawn where they are above the ground,
-- because the ground is just a line and must look solid.
function S.drawSky(view, T, world, dim)
  dim = dim or 1
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
        if sy < S.terrainScreenY(view, T, sx) - 4 then
          core.setc(st.b * (0.7 + 0.3 * math.sin(t * st.sp + st.ph)) * dim)
          lg.points(sx, sy)
        end
      end
    end
  end
  if world.sky then
    local ox, oy = VW * 0.80, VH * 0.26
    if oy + world.skyR * 2.5 < S.terrainScreenY(view, T, ox) then
      lg.setLineWidth(1.4)
      world.sky(ox, oy, world.skyR, dim)
    end
  end
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
        vfont.draw("X" .. p.mult, sx, sy + 7, th, "center")
      end
    end
  end
end

return S
