-- Procedural, horizontally wrapping terrain: a periodic midpoint-
-- displacement heightfield with craters, plus flat landing pads whose
-- score multiplier grows as they get narrower.
--
-- opts (all optional):
--   width  world width in metres (multiple of 160; default 1280)
--   sites  list of pad specs { w, flat, kind, label, name, mult } placed one
--          per sector; `flat` adds level shoulders either side of the pad
--          (where missions put buildings). Without sites, arcade pads with
--          x2..x5 multipliers are made from world.pads.

local core = require("src.core")

local Terrain = {}
Terrain.__index = Terrain

local WIDTH = 1280        -- metres; the world wraps around
local SAMPLES = 128       -- one vertex every 10 m
local PAD_WIDTH = { [2] = 24, [3] = 18, [4] = 14, [5] = 11 }

function Terrain.new(world, seed, opts)
  opts = opts or {}
  local rng = love.math.newRandomGenerator(seed)
  local width = opts.width or WIDTH
  local self = setmetatable({ W = width }, Terrain)
  local N, dx = math.floor(width / (WIDTH / SAMPLES)), WIDTH / SAMPLES
  local relief, rough = world.relief, world.rough
  local function rnd() return rng:random() * 2 - 1 end

  -- Periodic midpoint displacement.
  local h = {}
  local step = 16
  for i = 0, N - 1, step do h[i] = rng:random() * relief end
  local amp = relief * 0.35
  while step > 1 do
    local half = step / 2
    for i = 0, N - 1, step do
      h[i + half] = (h[i] + h[(i + step) % N]) * 0.5 + rnd() * amp
    end
    amp = amp * rough
    step = half
  end

  -- Craters: parabolic bowl plus a raised rim.
  for _ = 1, world.craters or 0 do
    local ci = rng:random(0, N - 1)
    local R = rng:random(3, 6)
    local depth = R * dx * (0.14 + rng:random() * 0.1)
    local rim = depth * 0.45
    local reach = math.ceil(R * 1.8)
    for j = -reach, reach do
      local u = math.abs(j) / R
      local d = rim * math.exp(-((u - 1) / 0.32) ^ 2)
      if u < 1 then d = d + depth * (u * u - 1) end
      local idx = (ci + j) % N
      h[idx] = h[idx] + d
    end
  end

  -- Normalise to the world's relief.
  local lo, hi = math.huge, -math.huge
  for i = 0, N - 1 do
    if h[i] < lo then lo = h[i] end
    if h[i] > hi then hi = h[i] end
  end
  local k = relief / math.max(1, hi - lo)
  for i = 0, N - 1 do h[i] = 6 + (h[i] - lo) * k end

  local function baseAt(x)
    local fx = x / dx
    local i0 = math.floor(fx)
    local t = fx - i0
    local a, b = h[i0 % N], h[(i0 + 1) % N]
    return a + (b - a) * t
  end

  -- Landing sites, one per sector.
  local specs = opts.sites
  if not specs then
    local mults = {}
    for i, m in ipairs(world.pads or { 2, 2, 3, 4, 5 }) do mults[i] = m end
    for i = #mults, 2, -1 do
      local j = rng:random(1, i)
      mults[i], mults[j] = mults[j], mults[i]
    end
    specs = {}
    for i, m in ipairs(mults) do specs[i] = { w = PAD_WIDTH[m] or 18, mult = m } end
  end
  local K = #specs
  local sector = width / K
  local pads = {}
  for i, sp in ipairs(specs) do
    local w, flat = sp.w, sp.flat or 0
    local span = w + 2 * flat
    local margin = 30
    local cx = (i - 1) * sector + margin + span / 2 + rng:random() * (sector - 2 * margin - span)
    local sum, cnt = 0, 0
    for xx = cx - span / 2, cx + span / 2, 2 do sum = sum + baseAt(xx); cnt = cnt + 1 end
    pads[i] = {
      x0 = cx - w / 2, x1 = cx + w / 2, cx = cx, w = w, y = sum / cnt, flat = flat,
      mult = sp.mult or 1, kind = sp.kind, label = sp.label, name = sp.name,
    }
  end

  -- Vertex list: base samples outside the sites + site end points.
  local verts = {}
  for i = 0, N - 1 do
    local x = i * dx
    local inside = false
    for _, p in ipairs(pads) do
      if x >= p.x0 - p.flat - 3 and x <= p.x1 + p.flat + 3 then inside = true; break end
    end
    if not inside then verts[#verts + 1] = { x, h[i] } end
  end
  for _, p in ipairs(pads) do
    verts[#verts + 1] = { p.x0, p.y }
    verts[#verts + 1] = { p.x1, p.y }
    if p.flat > 0 then
      verts[#verts + 1] = { p.x0 - p.flat, p.y }
      verts[#verts + 1] = { p.x1 + p.flat, p.y }
    end
  end
  table.sort(verts, function(a, b) return a[1] < b[1] end)

  self.xs, self.ys = {}, {}
  local maxH = -math.huge
  for i, v in ipairs(verts) do
    self.xs[i], self.ys[i] = v[1], v[2]
    if v[2] > maxH then maxH = v[2] end
  end
  self.n = #verts
  self.pads = pads
  self.maxH = maxH

  -- Buildings on the level shoulders of HQ and outposts. They are solid:
  -- each is also a collision box [x - w/2, x + w/2] x [y, y + h].
  local structs = {}
  local function add(kind, x, y, w, hgt, name)
    structs[#structs + 1] = { kind = kind, x = core.wrap(x, width), y = y, w = w, h = hgt, name = name }
  end
  for _, p in ipairs(pads) do
    if p.kind == "hq" then
      add("hangar", p.x0 - p.flat * 0.5, p.y, 15, 7, "THE HANGAR")
      add("tank", p.x1 + 6, p.y, 4.5, 6, "A FUEL TANK")
      add("tank", p.x1 + 12, p.y, 4.5, 6, "A FUEL TANK")
      add("mast", p.x1 + 20, p.y, 1.2, 15, "THE RADIO MAST")
    elseif p.kind == "base" then
      local left = rng:random() < 0.5
      add("dome", left and p.x0 - 7.5 or p.x1 + 7.5, p.y, 10, 5, "A HABITAT DOME")
      add("antenna", left and p.x1 + 8 or p.x0 - 8, p.y, 1.2, 9, "AN ANTENNA")
    end
  end
  self.structs = #structs > 0 and structs or nil
  return self
end

-- Building containing world point (x, y), if any.
function Terrain:structAt(x, y)
  local structs = self.structs
  if not structs then return nil end
  for i = 1, #structs do
    local s = structs[i]
    if y >= s.y and y <= s.y + s.h and math.abs(core.wdelta(x - s.x, self.W)) <= s.w / 2 then
      return s
    end
  end
  return nil
end

-- Largest i with xs[i] <= x (x already wrapped), or 0 if x < xs[1].
function Terrain:indexAt(x)
  local xs = self.xs
  if x < xs[1] then return 0 end
  local lo, hi = 1, self.n
  while lo < hi do
    local mid = math.floor((lo + hi + 1) / 2)
    if xs[mid] <= x then lo = mid else hi = mid - 1 end
  end
  return lo
end

function Terrain:height(x)
  local W = self.W
  x = x - math.floor(x / W) * W
  local xs, ys, n = self.xs, self.ys, self.n
  local i = self:indexAt(x)
  local xa, ya, xb, yb
  if i == 0 then
    xa, ya, xb, yb = xs[n] - W, ys[n], xs[1], ys[1]
  elseif i == n then
    xa, ya, xb, yb = xs[n], ys[n], xs[1] + W, ys[1]
  else
    xa, ya, xb, yb = xs[i], ys[i], xs[i + 1], ys[i + 1]
  end
  return ya + (yb - ya) * (x - xa) / (xb - xa)
end

function Terrain:slope(x)
  return self:height(x + 0.5) - self:height(x - 0.5)
end

-- Highest terrain point in [xa, xb] (unwrapped coordinates).
function Terrain:maxHeight(xa, xb)
  local m = math.max(self:height(xa), self:height(xb))
  local W, n, xs, ys = self.W, self.n, self.xs, self.ys
  local k = math.floor(xa / W)
  local i = self:indexAt(xa - k * W) + 1
  if i > n then i = 1; k = k + 1 end
  for _ = 1, n do
    local x = xs[i] + k * W
    if x > xb then break end
    if ys[i] > m then m = ys[i] end
    i = i + 1
    if i > n then i = 1; k = k + 1 end
  end
  return m
end

-- Collect vertices in (xa, xb] into ox/oy (unwrapped, in xa's frame).
function Terrain:collect(xa, xb, ox, oy)
  local W, n, xs, ys = self.W, self.n, self.xs, self.ys
  local k = math.floor(xa / W)
  local i = self:indexAt(xa - k * W) + 1
  if i > n then i = 1; k = k + 1 end
  local c = 0
  for _ = 1, n do
    local x = xs[i] + k * W
    if x > xb then break end
    c = c + 1
    ox[c], oy[c] = x, ys[i]
    i = i + 1
    if i > n then i = 1; k = k + 1 end
  end
  return c
end

-- Pad that holds both feet (foot centres within the pad +- tol), if any.
function Terrain:padUnder(xa, xb, tol)
  tol = tol or 0.35
  local W = self.W
  for _, p in ipairs(self.pads) do
    local da = core.wdelta(xa - p.cx, W)
    local db = core.wdelta(xb - p.cx, W)
    local lo, hi = math.min(da, db), math.max(da, db)
    if lo >= -p.w / 2 - tol and hi <= p.w / 2 + tol then return p end
  end
  return nil
end

return Terrain
