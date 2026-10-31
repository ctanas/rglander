-- Pooled particles (structure-of-arrays, swap-remove: no per-particle
-- allocation, which keeps the GC quiet on the handheld).
--   kind 1 exhaust : no gravity (gas jet), dragged by air if present
--   kind 2 dust    : ballistic - in vacuum it flies in clean straight arcs
--   kind 3 spark   : ballistic, bounces once or twice
--   kind 4 RCS puff: short-lived

local core = require("src.core")
local lg = love.graphics
local abs, exp = math.abs, math.exp

local P = {}
P.__index = P

local STREAK = { 0.03, 0.045, 0.03, 0.02 }   -- streak length in seconds of motion
local DRAG = { 0.9, 0.6, 0.2, 0.5 }          -- per (kg/m^3) of air density
local GRAV = { false, true, true, false }

function P.new(max)
  return setmetatable({
    n = 0, max = max,
    x = {}, y = {}, vx = {}, vy = {}, life = {}, ml = {}, kind = {}, br = {},
  }, P)
end

function P:clear() self.n = 0 end

function P:add(x, y, vx, vy, life, kind, br)
  if self.n >= self.max then return end
  local i = self.n + 1
  self.n = i
  self.x[i], self.y[i], self.vx[i], self.vy[i] = x, y, vx, vy
  self.life[i], self.ml[i], self.kind[i], self.br[i] = life, life, kind, br
end

function P:kill(i)
  local n = self.n
  if i ~= n then
    self.x[i], self.y[i], self.vx[i], self.vy[i] = self.x[n], self.y[n], self.vx[n], self.vy[n]
    self.life[i], self.ml[i], self.kind[i], self.br[i] = self.life[n], self.ml[n], self.kind[n], self.br[n]
  end
  self.n = n - 1
end

function P:update(dt, T, g, rho, wind)
  local i = 1
  while i <= self.n do
    local life = self.life[i] - dt
    if life <= 0 then
      self:kill(i)
    else
      self.life[i] = life
      local k = self.kind[i]
      local vx, vy = self.vx[i], self.vy[i]
      if GRAV[k] then vy = vy - g * dt end
      local d = DRAG[k] * rho
      if d > 0 then
        local f = exp(-d * dt)
        vx = wind + (vx - wind) * f
        vy = vy * f
      end
      local x, y = self.x[i] + vx * dt, self.y[i] + vy * dt
      local dead = false
      if k ~= 4 then
        local h = T:height(x)
        if y < h then
          if k == 3 and vy < -2 then
            y = h + 0.05
            vy = -vy * 0.3
            vx = vx * 0.5
          else
            dead = true
          end
        end
      end
      if dead then
        self:kill(i)
      else
        self.x[i], self.y[i], self.vx[i], self.vy[i] = x, y, vx, vy
        i = i + 1
      end
    end
  end
end

function P:draw(view)
  local VW, VH, z, W = core.VW, core.VH, view.z, view.W
  local hw = VW / 2 / z + 5
  local cx, cy = view.cx, view.cy
  lg.setLineWidth(1.2)
  for i = 1, self.n do
    local dx = core.wdelta(self.x[i] - cx, W)
    if abs(dx) < hw then
      local sx = VW / 2 + dx * z
      local sy = VH / 2 - (self.y[i] - cy) * z
      local st = STREAK[self.kind[i]] * z
      local ex, ey = sx - self.vx[i] * st, sy + self.vy[i] * st
      if abs(ex - sx) + abs(ey - sy) < 1 then ex = sx + 1 end
      local f = self.life[i] / self.ml[i]
      core.setc(self.br[i] * f)
      lg.line(sx, sy, ex, ey)
    end
  end
end

return P
