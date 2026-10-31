-- Heads-up display, sized for a 3.4" 720x480 panel (~254 ppi): 12 px
-- vector text for readouts, brightness (not colour) for hierarchy, and
-- blinking for warnings, like a monochrome vector monitor.

local core = require("src.core")
local vfont = require("src.vfont")
local lg = love.graphics
local abs, floor, min, max, sin, cos, sqrt, log = math.abs, math.floor, math.min, math.max, math.sin, math.cos, math.sqrt, math.log

local H = {}

local function blink(rate, duty)
  return (core.time * (rate or 4)) % 1 < (duty or 0.6)
end

local function arrowH(v) if abs(v) < 0.05 then return " " end return v < 0 and "{" or "}" end
local function arrowV(v) if abs(v) < 0.05 then return " " end return v < 0 and "]" or "[" end

-- Log-scaled speed -> gauge radius, so 0.5 and 20 m/s are both readable.
local function speedR(v, r) return r * min(1, log(1 + v) / log(31)) end

local function drawReadouts(g)
  local VW = core.VW
  local L = g.lander
  local th = 12
  local adv = vfont.advance(th)
  local y1, y2, y3, y4 = 12, 31, 50, 69
  lg.setLineWidth(1.5)

  -- left block
  local lx, vx = 14, 14 + 6 * adv
  core.setc(0.5)
  vfont.draw("SCORE", lx, y1, th)
  vfont.draw("TIME", lx, y2, th)
  vfont.draw("FUEL", lx, y3, th)
  core.setc(1)
  vfont.draw(string.format("%05d", floor(g.score)), vx, y1, th)
  local t = floor(g.time)
  vfont.draw(string.format("%02d:%02d", floor(t / 60), t % 60), vx, y2, th)
  local low = g.fuel < g.fuelStart * 0.12
  if not low or blink(3) then
    vfont.draw(string.format("%4d KG", floor(g.fuel + 0.5)), vx, y3, th)
  end

  -- right block (all value strings are 11 chars, right aligned)
  local rx = VW - 14
  local lab = VW - 14 - 23 * adv
  local lim = g.limits
  local alt = max(0, g.alt or 0)
  local flying = g.phase == "fly"
  core.setc(0.5)
  vfont.draw("ALTITUDE", lab, y1, th)
  vfont.draw("HORIZ SPEED", lab, y2, th)
  vfont.draw("VERT SPEED", lab, y3, th)
  core.setc(1)
  vfont.draw(string.format(" %6.1f M  ", min(alt, 9999.9)), rx, y1, th, "right")
  local warnH = flying and alt < 40 and abs(L.vx) > lim.hardH
  if not warnH or blink(5) then
    vfont.draw(string.format("%s%6.1f M/S", arrowH(L.vx), abs(L.vx)), rx, y2, th, "right")
  end
  local warnV = flying and alt < 40 and -L.vy > lim.hardV
  if not warnV or blink(5) then
    vfont.draw(string.format("%s%6.1f M/S", arrowV(L.vy), abs(L.vy)), rx, y3, th, "right")
  end
  if g.world.rho > 0 then
    core.setc(0.5)
    vfont.draw("WIND", lab, y4, th)
    core.setc(0.85)
    local wv = g.env.windx
    vfont.draw(string.format("%s%6.1f M/S", arrowH(wv), abs(wv)), rx, y4, th, "right")
  end

  -- centre: world and sortie
  local midx = (vx + 7 * adv + lab) / 2
  lg.setLineWidth(1.2)
  core.setc(0.4)
  vfont.draw(string.format("%s  SORTIE %d", g.world.name, g.sortie), midx, y1 + 1, 10, "center")
  if g.demo and blink(1.5) then
    core.setc(0.7)
    vfont.draw("DEMO - PRESS ANY BUTTON", core.VW / 2, core.VH - 22, 10, "center")
  end
end

local function drawBars(g)
  local VH = core.VH
  local L = g.lander
  local base, hgt, w = VH - 30, 100, 9
  local function bar(x, frac, label)
    core.setc(0.45)
    lg.setLineWidth(1.2)
    lg.rectangle("line", x, base - hgt, w, hgt)
    core.setc(0.95)
    local top = base - hgt * core.clamp(frac, 0, 1)
    for yy = base - 2, top + 0.5, -3 do lg.line(x + 2, yy, x + w - 2, yy) end
    core.setc(0.5)
    vfont.draw(label, x + w / 2, base + 6, 8, "center")
  end
  local x1, x2 = 16, 46
  lg.setColor(0, 0, 0, 0.85)
  lg.rectangle("fill", x1 - 8, base - hgt - 6, x2 + w - x1 + 20, hgt + 26)
  bar(x1, L.thr, "THR")
  -- throttle lever setting (triangle) and hover throttle (tick)
  core.setc(0.9)
  local ly = base - hgt * g.lever
  lg.line(x1 + w + 2, ly, x1 + w + 7, ly - 3, x1 + w + 7, ly + 3, x1 + w + 2, ly)
  local hy = base - hgt * g:hoverThrottle()
  core.setc(0.6)
  lg.line(x1 - 5, hy, x1 - 1, hy)
  bar(x2, g.fuel / g.fuelStart, "FUEL")
end

-- Attitude / velocity instrument: the lander's axis and its velocity
-- vector on a log scale; the inner ring is the safe touchdown speed.
local function drawGauge(g)
  local VW, VH = core.VW, core.VH
  local L, lim = g.lander, g.limits
  local cx, cy, r = VW - 48, VH - 48, 32
  lg.setColor(0, 0, 0, 0.85)
  lg.circle("fill", cx, cy, r + 3, 40)
  lg.rectangle("fill", cx - 24, cy + r, 48, 16)
  lg.setLineWidth(1.2)
  core.setc(0.35)
  lg.circle("line", cx, cy, r, 40)
  core.setc(0.22)
  lg.circle("line", cx, cy, speedR(lim.softV, r), 24)
  core.setc(0.4)
  for k = -3, 3 do
    local an = k * math.pi / 6
    local s, c = sin(an), cos(an)
    lg.line(cx + s * (r - 4), cy - c * (r - 4), cx + s * r, cy - c * r)
  end

  local alt = g.alt or 0
  local flying = g.phase == "fly"
  local tiltDeg = abs(core.wrapAngle(L.a)) * 180 / math.pi
  if not (flying and alt < 40 and tiltDeg > lim.hardT) or blink(5) then
    local ux, uy = -sin(L.a), -cos(L.a)
    local px, py = -uy, ux
    core.setc(1)
    lg.setLineWidth(1.6)
    local bx, by = cx - ux * r * 0.3, cy - uy * r * 0.3
    lg.line(bx, by, cx + ux * r * 0.75, cy + uy * r * 0.75)
    lg.line(bx - px * r * 0.3, by - py * r * 0.3, bx + px * r * 0.3, by + py * r * 0.3)
  end

  local sp = sqrt(L.vx * L.vx + L.vy * L.vy)
  if sp > 0.05 then
    local dx, dy = L.vx / sp, -L.vy / sp
    local len = speedR(sp, r)
    local tx, ty = cx + dx * len, cy + dy * len
    core.setc(sp > lim.softV and 0.75 or 1)
    lg.setLineWidth(1.3)
    lg.line(cx, cy, tx, ty)
    local hl = 5
    for _, s in ipairs({ 2.6, -2.6 }) do
      local c2, s2 = cos(s), sin(s)
      lg.line(tx, ty, tx + (dx * c2 - dy * s2) * hl, ty + (dx * s2 + dy * c2) * hl)
    end
  end
  core.setc(0.45)
  vfont.draw("ATT/VEL", cx, cy + r + 5, 8, "center")
end

local function drawPadHints(g)
  if g.phase ~= "fly" then return end
  local VW, VH = core.VW, core.VH
  local T, view, L = g.terrain, g.view, g.lander
  local lp, rp, ld, rd
  for _, p in ipairs(T.pads) do
    local sx = VW / 2 + core.wdelta(p.cx - view.cx, T.W) * view.z
    local d = core.wdelta(p.cx - L.x, T.W)
    if sx < -10 and d < 0 then
      if not ld or -d < ld then lp, ld = p, -d end
    elseif sx > VW + 10 and d > 0 then
      if not rd or d < rd then rp, rd = p, d end
    end
  end
  lg.setLineWidth(1.2)
  core.setc(0.6)
  local y = VH * 0.42
  if lp then
    vfont.draw("{X" .. lp.mult, 10, y, 10)
    vfont.draw(string.format("%dM", floor(ld)), 10, y + 15, 8)
  end
  if rp then
    vfont.draw("X" .. rp.mult .. "}", VW - 10, y, 10, "right")
    vfont.draw(string.format("%dM", floor(rd)), VW - 10, y + 15, 8, "right")
  end
end

local function brackets(x0, y0, x1, y1, len)
  lg.line(x0, y0 + len, x0, y0, x0 + len, y0)
  lg.line(x1 - len, y0, x1, y0, x1, y0 + len)
  lg.line(x0, y1 - len, x0, y1, x0 + len, y1)
  lg.line(x1 - len, y1, x1, y1, x1, y1 - len)
end

local function drawResult(g)
  local r = g.result
  if not r then return end
  local VW, VH = core.VW, core.VH
  local cx = VW / 2
  local lines = r.lines or {}
  local h = 46 + #lines * 18 + 26
  local top = VH * 0.36 - h / 2
  local bw = min(290, VW / 2 - 20)
  lg.setColor(0, 0, 0, 0.82)
  lg.rectangle("fill", cx - bw, top - 16, bw * 2, h + 28)
  core.setc(0.6)
  lg.setLineWidth(1.4)
  brackets(cx - bw, top - 16, cx + bw, top + h + 12, 14)
  core.setc(1)
  lg.setLineWidth(2.2)
  vfont.draw(r.title, cx, top, 20, "center")
  lg.setLineWidth(1.4)
  core.setc(0.75)
  vfont.draw(r.sub or "", cx, top + 30, 11, "center")
  core.setc(0.95)
  for i, s in ipairs(lines) do vfont.draw(s, cx, top + 32 + i * 18, 11, "center") end
  if g.phaseT > 1.0 and blink(1.6) then
    core.setc(0.6)
    lg.setLineWidth(1.2)
    local prompt = g.demo and "DEMO" or (r.kind == "gameover" and "PRESS A FOR TITLE" or "PRESS A")
    vfont.draw(prompt, cx, top + h - 8, 10, "center")
  end
end

local PAUSE_ITEMS = { "RESUME", "RESTART MISSION", "QUIT TO TITLE" }

local function drawPause(g)
  local VW, VH = core.VW, core.VH
  local cx, cy = VW / 2, VH / 2
  lg.setColor(0, 0, 0, 0.85)
  lg.rectangle("fill", cx - 170, cy - 90, 340, 180)
  core.setc(0.6)
  lg.setLineWidth(1.4)
  brackets(cx - 170, cy - 90, cx + 170, cy + 90, 14)
  core.setc(1)
  lg.setLineWidth(2.2)
  vfont.draw("PAUSED", cx, cy - 70, 20, "center")
  for i, s in ipairs(PAUSE_ITEMS) do
    local sel = i == g.pauseSel
    lg.setLineWidth(sel and 1.8 or 1.3)
    core.setc(sel and 1 or 0.5)
    local y = cy - 28 + (i - 1) * 26
    vfont.draw(s, cx, y, 13, "center")
    if sel then
      vfont.draw(">", cx - vfont.width(s, 13) / 2 - 22, y, 13)
      vfont.draw("<", cx + vfont.width(s, 13) / 2 + 13, y, 13)
    end
  end
  core.setc(0.4)
  lg.setLineWidth(1.1)
  vfont.draw("SELECT+START QUITS THE GAME", cx, cy + 66, 9, "center")
end

function H.draw(g)
  local VW, VH = core.VW, core.VH
  drawReadouts(g)
  drawBars(g)
  drawGauge(g)
  drawPadHints(g)

  if g.banner > 0 and g.phase == "fly" and not g.paused then
    local a = min(1, g.banner / 0.6)
    lg.setLineWidth(2)
    core.setc(a)
    vfont.draw("SORTIE " .. g.sortie, VW / 2, VH * 0.5, 20, "center")
    lg.setLineWidth(1.3)
    core.setc(0.65 * a)
    vfont.draw(string.format("%s  -  G %.2f M/S2", g.world.name, g.world.g), VW / 2, VH * 0.5 + 30, 11, "center")
    vfont.draw("LAND ON A PAD", VW / 2, VH * 0.5 + 48, 11, "center")
  end

  if g.note and g.phase == "fly" and blink(2.5) then
    lg.setLineWidth(1.8)
    core.setc(1)
    vfont.draw(g.note.text, VW / 2, VH * 0.25, 14, "center")
  end

  if g.phase ~= "fly" then drawResult(g) end
  if g.paused then drawPause(g) end
end

return H
