-- Heads-up display, sized for a 3.4" 720x480 panel (~254 ppi): 12 px
-- vector text for readouts, brightness (not colour) for hierarchy, and
-- blinking for warnings, like a monochrome vector monitor.
-- H.draw is the arcade HUD, H.drawMission the missions HUD.

local core = require("src.core")
local vfont = require("src.vfont")
local lg = love.graphics
local abs, floor, min, max, sin, cos, sqrt, log = math.abs, math.floor, math.min, math.max, math.sin, math.cos, math.sqrt, math.log

local H = {}

local TH = 12                 -- readout text height
local Y1, Y2, Y3, Y4 = 12, 31, 50, 69

local function blink(rate, duty)
  return (core.time * (rate or 4)) % 1 < (duty or 0.6)
end

local function arrowH(v) if abs(v) < 0.05 then return " " end return v < 0 and "{" or "}" end
local function arrowV(v) if abs(v) < 0.05 then return " " end return v < 0 and "]" or "[" end

-- Log-scaled speed -> gauge radius, so 0.5 and 20 m/s are both readable.
local function speedR(v, r) return r * min(1, log(1 + v) / log(31)) end

function H.fmtTime(t)
  t = max(0, floor(t))
  return string.format("%d:%02d", floor(t / 60), t % 60)
end

local function adv() return vfont.advance(TH) end
local function rightLabelX() return core.VW - 14 - 23 * adv() end
local function centerX() return (14 + 15 * adv() + rightLabelX()) / 2 end

---------------------------------------------------------------------------
-- Readouts
---------------------------------------------------------------------------

local function leftBlock(labels, values, warn)
  local x, vx = 14, 14 + 8 * adv()
  local ys = { Y1, Y2, Y3 }
  lg.setLineWidth(1.5)
  for i = 1, #labels do
    core.setc(0.5)
    vfont.draw(labels[i], x, ys[i], TH)
    core.setc(1)
    if not warn[i] or blink(3) then vfont.draw(values[i], vx, ys[i], TH) end
  end
end

local function drawLeftArcade(g)
  local t = floor(g.time)
  leftBlock({ "SCORE", "TIME", "FUEL" }, {
    string.format("%05d", floor(g.score)),
    string.format("%02d:%02d", floor(t / 60), t % 60),
    string.format("%4d KG", floor(g.fuel + 0.5)),
  }, { false, false, g.fuel < g.fuelStart * 0.12 })
end

local function drawLeftMission(g)
  leftBlock({ "CREDITS", "FUEL", "MASS" }, {
    string.format("%05d", floor(g.credits)),
    string.format("%4d KG", floor(g.fuel + 0.5)),
    string.format("%4d KG", floor(g.lander:mass(g.fuel) + 0.5)),
  }, { false, g.fuel < g.fuelStart * 0.12, false })
end

local function drawRight(g)
  local VW = core.VW
  local L, lim = g.lander, g.limits
  local rx, lab = VW - 14, rightLabelX()
  local alt = max(0, g.alt or 0)
  local flying = g.phase == "fly"
  lg.setLineWidth(1.5)
  core.setc(0.5)
  vfont.draw("ALTITUDE", lab, Y1, TH)
  vfont.draw("HORIZ SPEED", lab, Y2, TH)
  vfont.draw("VERT SPEED", lab, Y3, TH)
  core.setc(1)
  vfont.draw(string.format(" %6.1f M  ", min(alt, 9999.9)), rx, Y1, TH, "right")
  if not (flying and alt < 40 and abs(L.vx) > lim.hardH) or blink(5) then
    vfont.draw(string.format("%s%6.1f M/S", arrowH(L.vx), abs(L.vx)), rx, Y2, TH, "right")
  end
  if not (flying and alt < 40 and -L.vy > lim.hardV) or blink(5) then
    vfont.draw(string.format("%s%6.1f M/S", arrowV(L.vy), abs(L.vy)), rx, Y3, TH, "right")
  end
  if g.world.rho > 0 then
    core.setc(0.5)
    vfont.draw("WIND", lab, Y4, TH)
    core.setc(0.85)
    local wv = g.env.windx
    vfont.draw(string.format("%s%6.1f M/S", arrowH(wv), abs(wv)), rx, Y4, TH, "right")
  end
end

-- Orbital view readouts: altitude, orbital speed, apoapsis, periapsis.
local function drawRightOrbit(g)
  local VW = core.VW
  local el, R = g.el, g.world.R
  local rx, lab = VW - 14, rightLabelX()
  local safe = R + g:orbitSafeAltitude()
  lg.setLineWidth(1.5)
  core.setc(0.5)
  vfont.draw("ALTITUDE", lab, Y1, TH)
  vfont.draw("VELOCITY", lab, Y2, TH)
  vfont.draw("APOAPSIS", lab, Y3, TH)
  vfont.draw("PERIAPSIS", lab, Y4, TH)
  core.setc(1)
  vfont.draw(string.format("%6.1f KM  ", (el.r - R) / 1000), rx, Y1, TH, "right")
  vfont.draw(string.format(" %6.1f M/S", el.v), rx, Y2, TH, "right")
  vfont.draw(el.bound and string.format("%6.1f KM  ", (el.ra - R) / 1000) or "  ESCAPE   ", rx, Y3, TH, "right")
  if el.rp >= safe or blink(2.5) then
    vfont.draw(string.format("%6.1f KM  ", (el.rp - R) / 1000), rx, Y4, TH, "right")
  end
end

local function drawCenterOrbit(g)
  local el, cx = g.el, centerX()
  local safe = g.world.R + g:orbitSafeAltitude()
  lg.setLineWidth(1.2)
  core.setc(0.85)
  local status = not el.bound and "ESCAPE TRAJECTORY" or (el.rp >= safe and "IN ORBIT" or "SUBORBITAL")
  vfont.draw(status, cx, Y1 + 1, 10, "center")
  core.setc(0.6)
  if el.bound then vfont.draw("PERIOD " .. H.fmtTime(el.period), cx, Y2 + 1, 10, "center") end
  local parts = {}
  if g.warp > 1 then parts[#parts + 1] = "WARP X" .. g.warp end
  if g.hold then parts[#parts + 1] = g.hold == "pro" and "HOLD PRO" or "HOLD RETRO" end
  if #parts > 0 then
    core.setc(0.9)
    vfont.draw(table.concat(parts, "  "), cx, Y3 + 1, 10, "center")
  end
  core.setc(0.45)
  vfont.draw("L1/R1 TIME WARP   X PROGRADE/RETROGRADE HOLD", core.VW / 2, core.VH - 22, 9, "center")
end

local function drawCenterArcade(g)
  if g.mode == "orbit" then return drawCenterOrbit(g) end
  lg.setLineWidth(1.2)
  core.setc(0.4)
  vfont.draw(string.format("%s  SORTIE %d", g.world.name, g.sortie), centerX(), Y1 + 1, 10, "center")
  if g.demo and blink(1.5) then
    core.setc(0.7)
    vfont.draw("DEMO - PRESS ANY BUTTON", core.VW / 2, core.VH - 22, 10, "center")
  end
end

local function drawCenterMission(g)
  local cx = centerX()
  local L = g.lander
  lg.setLineWidth(1.2)
  if g.phase == "docked" then
    core.setc(0.6)
    vfont.draw("DOCKED AT HQ", cx, Y1 + 1, 10, "center")
    return
  end
  local c = g.contract
  local target = g:target()
  local d = core.wdelta(target.cx - L.x, g.terrain.W)
  local nav = string.format("%s %dM", arrowH(d), floor(abs(d) + 0.5))
  if c then
    core.setc(0.85)
    vfont.draw("TO " .. c.base.label, cx, Y1 + 1, 10, "center")
    local late = c.timeLeft < 0
    if not late or blink(2) then
      core.setc(late and 1 or 0.85)
      vfont.draw(nav .. "  " .. (late and "LATE " or "T-") .. H.fmtTime(abs(c.timeLeft)), cx, Y2 + 1, 10, "center")
    end
    core.setc(0.5)
    vfont.draw(string.format("CARGO %d KG%s", c.mass, c.fragile and " FRAGILE" or ""), cx, Y3 + 1, 9, "center")
  else
    core.setc(0.6)
    vfont.draw("NO CONTRACT", cx, Y1 + 1, 10, "center")
    core.setc(0.85)
    vfont.draw("HQ " .. nav, cx, Y2 + 1, 10, "center")
  end
end

---------------------------------------------------------------------------
-- Instruments
---------------------------------------------------------------------------

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
  bar(x1, L.out, "THR")
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
    for _, s in ipairs({ 2.6, -2.6 }) do
      local c2, s2 = cos(s), sin(s)
      lg.line(tx, ty, tx + (dx * c2 - dy * s2) * 5, ty + (dx * s2 + dy * c2) * 5)
    end
  end
  core.setc(0.45)
  vfont.draw("ATT/VEL", cx, cy + r + 5, 8, "center")
end

-- Missions: health of each system as a 10-segment bar; blinks when low.
local function drawDamage(g)
  local VH = core.VH
  local x, y0 = 82, VH - 88
  local systems = { "engine", "rcs", "tank", "gear" }
  local labels = { engine = "ENG", rcs = "RCS", tank = "TNK", gear = "GEAR" }
  lg.setColor(0, 0, 0, 0.85)
  lg.rectangle("fill", x - 4, y0 - 6, 92, 66)
  lg.setLineWidth(1.2)
  for i, s in ipairs(systems) do
    local hp = g.dmg[s]
    local y = y0 + (i - 1) * 14
    if hp > 0.35 or blink(3) then
      core.setc(hp < 0.999 and 0.85 or 0.5)
      vfont.draw(labels[s], x, y, 8)
      local segs = floor(hp * 10 + 0.5)
      for k = 0, 9 do
        core.setc(k < segs and 0.9 or 0.18)
        local sx = x + 34 + k * 5
        lg.line(sx, y, sx, y + 8)
      end
    end
  end
end

---------------------------------------------------------------------------
-- Navigation
---------------------------------------------------------------------------

local function edgeHint(d, label)
  local VW, VH = core.VW, core.VH
  local y = VH * 0.42
  if d < 0 then
    vfont.draw("{" .. label, 10, y, 10)
    vfont.draw(string.format("%dM", floor(-d)), 10, y + 15, 8)
  else
    vfont.draw(label .. "}", VW - 10, y, 10, "right")
    vfont.draw(string.format("%dM", floor(d)), VW - 10, y + 15, 8, "right")
  end
end

local function offscreen(g, p)
  local sx = core.VW / 2 + core.wdelta(p.cx - g.view.cx, g.terrain.W) * g.view.z
  return sx < -10 or sx > core.VW + 10
end

local function drawPadHints(g)
  if g.phase ~= "fly" or g.mode == "orbit" then return end
  local T, L = g.terrain, g.lander
  local lp, rp, ld, rd
  for _, p in ipairs(T.pads) do
    local d = core.wdelta(p.cx - L.x, T.W)
    if offscreen(g, p) then
      if d < 0 and (not ld or -d < ld) then lp, ld = p, -d end
      if d > 0 and (not rd or d < rd) then rp, rd = p, d end
    end
  end
  lg.setLineWidth(1.2)
  core.setc(0.6)
  if lp then edgeHint(-ld, "X" .. lp.mult) end
  if rp then edgeHint(rd, "X" .. rp.mult) end
end

local function drawNav(g)
  if g.phase ~= "fly" and g.phase ~= "landed" then return end
  local p = g:target()
  if not offscreen(g, p) then return end
  lg.setLineWidth(1.3)
  core.setc(0.85)
  edgeHint(core.wdelta(p.cx - g.lander.x, g.terrain.W), p.label)
end

---------------------------------------------------------------------------
-- Boxes and overlays
---------------------------------------------------------------------------

local function brackets(x0, y0, x1, y1, len)
  lg.line(x0, y0 + len, x0, y0, x0 + len, y0)
  lg.line(x1 - len, y0, x1, y0, x1, y0 + len)
  lg.line(x0, y1 - len, x0, y1, x0 + len, y1)
  lg.line(x1 - len, y1, x1, y1, x1, y1 - len)
end

-- Title / subtitle / lines box centred at cy; prompt optional.
local function drawBox(r, cy, alpha, prompt)
  local VW = core.VW
  local cx = VW / 2
  local lines = r.lines or {}
  local h = 46 + #lines * 18 + (prompt and 26 or 4)
  local top = cy - h / 2
  local bw = min(290, VW / 2 - 20)
  lg.setColor(0, 0, 0, 0.82 * alpha)
  lg.rectangle("fill", cx - bw, top - 16, bw * 2, h + 28)
  core.setc(0.6 * alpha)
  lg.setLineWidth(1.4)
  brackets(cx - bw, top - 16, cx + bw, top + h + 12, 14)
  core.setc(alpha)
  lg.setLineWidth(2.2)
  vfont.draw(r.title, cx, top, 20, "center")
  lg.setLineWidth(1.4)
  core.setc(0.75 * alpha)
  vfont.draw(r.sub or "", cx, top + 30, 11, "center")
  core.setc(0.95 * alpha)
  for i, s in ipairs(lines) do vfont.draw(s, cx, top + 32 + i * 18, 11, "center") end
  if prompt and blink(1.6) then
    core.setc(0.6 * alpha)
    lg.setLineWidth(1.2)
    vfont.draw(prompt, cx, top + h - 8, 10, "center")
  end
end

local function drawResult(g)
  local r = g.result
  if not r then return end
  local prompt
  if g.phaseT > 1.0 then
    prompt = g.demo and "DEMO" or (r.kind == "gameover" and "PRESS A FOR TITLE" or "PRESS A")
  end
  drawBox(r, core.VH * 0.36, 1, prompt)
end

local function drawPause(g)
  local VW, VH = core.VW, core.VH
  local cx, cy = VW / 2, VH / 2
  local items = g.pauseItems
  local h = 110 + #items * 26
  local top = cy - h / 2
  lg.setColor(0, 0, 0, 0.85)
  lg.rectangle("fill", cx - 200, top, 400, h)
  core.setc(0.6)
  lg.setLineWidth(1.4)
  brackets(cx - 200, top, cx + 200, top + h, 14)
  core.setc(1)
  lg.setLineWidth(2.2)
  vfont.draw("PAUSED", cx, top + 20, 20, "center")
  for i, it in ipairs(items) do
    local sel = i == g.pauseSel
    lg.setLineWidth(sel and 1.8 or 1.3)
    core.setc(sel and 1 or 0.5)
    local y = top + 62 + (i - 1) * 26
    vfont.draw(it.label, cx, y, 13, "center")
    if sel then
      vfont.draw(">", cx - vfont.width(it.label, 13) / 2 - 22, y, 13)
      vfont.draw("<", cx + vfont.width(it.label, 13) / 2 + 13, y, 13)
    end
  end
  core.setc(0.4)
  lg.setLineWidth(1.1)
  vfont.draw(g.pauseNote or "", cx, top + h - 24, 9, "center")
end

local function drawNote(g)
  if g.note and g.phase == "fly" and blink(2.5) then
    lg.setLineWidth(1.8)
    core.setc(1)
    vfont.draw(g.note.text, core.VW / 2, core.VH * 0.25, 14, "center")
  end
end

-- Missions: the HQ services panel.
local function drawPanel(g)
  local VW = core.VW
  local rows = g:panelRows()
  local cx = VW / 2
  local bw = min(300, VW / 2 - 10)
  local top, h = 92, 230
  lg.setColor(0, 0, 0, 0.88)
  lg.rectangle("fill", cx - bw, top, bw * 2, h)
  core.setc(0.6)
  lg.setLineWidth(1.4)
  brackets(cx - bw, top, cx + bw, top + h, 14)
  core.setc(1)
  lg.setLineWidth(2)
  vfont.draw("HEADQUARTERS", cx, top + 12, 16, "center")
  lg.setLineWidth(1.1)
  core.setc(0.5)
  vfont.draw(g.contract and "ACTIVE CONTRACT" or "CONTRACTS  (* = FRAGILE)", cx - bw + 28, top + 40, 9)
  local y = top + 56
  local x0, x1 = cx - bw + 28, cx + bw - 18
  for i, r in ipairs(rows) do
    if r.gap then y = y + 8 end
    local sel = i == g.panelSel
    lg.setLineWidth(sel and 1.7 or 1.3)
    core.setc(sel and 1 or (r.selectable and 0.55 or 0.85))
    vfont.draw(r.text, x0, y, 11)
    if r.right then vfont.draw(r.right, x1, y, 11, "right") end
    if sel then vfont.draw(">", x0 - 16, y, 11) end
    y = y + 20
  end
  lg.setLineWidth(1.1)
  core.setc(g.panelMsg and 0.95 or 0.6)
  vfont.draw(g:panelDetail(rows[g.panelSel]), cx, top + h - 22, 9, "center")
end

---------------------------------------------------------------------------
-- Entry points
---------------------------------------------------------------------------

function H.draw(g)
  local VW, VH = core.VW, core.VH
  drawLeftArcade(g)
  if g.mode == "orbit" then drawRightOrbit(g) else drawRight(g) end
  drawCenterArcade(g)
  drawBars(g)
  drawGauge(g)
  drawPadHints(g)

  if g.banner > 0 and g.phase == "fly" and not g.paused and g.mode ~= "orbit" then
    local a = min(1, g.banner / 0.6)
    lg.setLineWidth(2)
    core.setc(a)
    vfont.draw("SORTIE " .. g.sortie, VW / 2, VH * 0.5, 20, "center")
    lg.setLineWidth(1.3)
    core.setc(0.65 * a)
    vfont.draw(string.format("%s  -  G %.2f M/S2", g.world.name, g.world.g), VW / 2, VH * 0.5 + 30, 11, "center")
    vfont.draw("LAND ON A PAD", VW / 2, VH * 0.5 + 48, 11, "center")
  end
  drawNote(g)
  if g.phase ~= "fly" then drawResult(g) end
  if g.paused then drawPause(g) end
end

function H.drawMission(g)
  local VW, VH = core.VW, core.VH
  drawLeftMission(g)
  drawRight(g)
  drawCenterMission(g)
  drawBars(g)
  drawDamage(g)
  drawGauge(g)
  drawNav(g)
  drawNote(g)

  if g.phase == "landed" and not g.toast then
    local msg
    if g.landedPad == g.hq then msg = "B - HQ SERVICES"
    elseif g:stranded() then msg = string.format("STRANDED - B CALLS A RESCUE (%d CR)", g.RESCUE_COST) end
    if msg and blink(1.4, 0.7) then
      lg.setLineWidth(1.4)
      core.setc(0.85)
      vfont.draw(msg, VW / 2, VH * 0.5, 11, "center")
    end
  end
  if g.toast and g.phase ~= "docked" then
    drawBox(g.toast, VH * 0.36, min(1, g.toast.t / 0.6))
  end
  if g.phase == "docked" then drawPanel(g) end
  if g.phase == "crashed" or g.phase == "over" then drawResult(g) end
  if g.paused then drawPause(g) end
end

return H
