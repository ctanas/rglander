-- Shared state and small helpers used by every module.

local core = {
  VERSION = "0.2.0",
  VW = 720,          -- logical screen width  (720 for 3:2 panels, 640 for 4:3)
  VH = 480,          -- logical screen height
  col = { 0.86, 0.93, 1.0 },  -- current phosphor colour
  time = 0,          -- global clock, seconds
  device = false,    -- true when running fullscreen on the handheld
}

core.PHOSPHORS = {
  { name = "WHITE", col = { 0.86, 0.93, 1.00 } },
  { name = "GREEN", col = { 0.42, 1.00, 0.56 } },
  { name = "AMBER", col = { 1.00, 0.72, 0.30 } },
  { name = "CYAN",  col = { 0.45, 0.88, 1.00 } },
}

function core.setPhosphor(i)
  local p = core.PHOSPHORS[i] or core.PHOSPHORS[1]
  core.col = p.col
end

-- Set the draw colour to the phosphor colour at brightness b (0..1).
function core.setc(b, a)
  local c = core.col
  love.graphics.setColor(c[1] * b, c[2] * b, c[3] * b, a or 1)
end

function core.clamp(v, lo, hi)
  if v < lo then return lo elseif v > hi then return hi end
  return v
end

function core.lerp(a, b, t) return a + (b - a) * t end

-- Wrap x into [0, w).
function core.wrap(x, w) return x - math.floor(x / w) * w end

-- Shortest signed distance on a ring of circumference w.
function core.wdelta(d, w) return d - math.floor(d / w + 0.5) * w end

-- Frame-rate independent exponential approach.
function core.approach(cur, target, rate, dt)
  return cur + (target - cur) * (1 - math.exp(-rate * dt))
end

function core.wrapAngle(a)
  return (a + math.pi) % (2 * math.pi) - math.pi
end

return core
