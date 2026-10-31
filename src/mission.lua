-- Missions: a persistent career of cargo runs between HQ and outposts.
--
-- One wide world per body, with an HQ and six named outposts. At HQ you
-- pick a contract (cargo, destination, reward, deadline), refuel and
-- repair - both cost credits - and launch. The cargo's mass is added to
-- the lander; propellant burns off as you fly. Hard landings damage the
-- gear and one other system. A crash costs a replacement lander; running
-- dry at an outpost costs a rescue; with no credits left the career ends.
-- The career is saved every time you dock at HQ.

local core = require("src.core")
local input = require("src.input")
local audio = require("src.audio")
local settings = require("src.settings")
local Terrain = require("src.terrain")
local Lander = require("src.lander")
local Game = require("src.game")
local hud = require("src.hud")

local abs, floor, ceil, max, min, sqrt = math.abs, math.floor, math.ceil, math.max, math.min, math.sqrt

local Mission = setmetatable({}, { __index = Game })
Mission.__index = Mission

local WORLD_WIDTH = 3840
local OUTPOSTS = 6
local START_CREDITS = 1500
local REPLACEMENT_COST = 1500
local RESCUE_COST = 400
local FUEL_PRICE = 0.6          -- credits per kg
local REPAIR_PRICE = 6          -- credits per percentage point, per system
local EMERGENCY_FUEL = 0.25     -- free fill-up level (fraction) when broke
local TANK_FACTOR = 1.5         -- cargo landers carry 1.5x the arcade fuel load

Mission.SYSTEMS = { "engine", "rcs", "tank", "gear" }
Mission.SYS_LABEL = { engine = "ENG", rcs = "RCS", tank = "TNK", gear = "GEAR" }
Mission.RESCUE_COST = RESCUE_COST

local SYSTEMS, SYS_LABEL = Mission.SYSTEMS, Mission.SYS_LABEL
local GRADES = Game.GRADES

-- Outposts are named after real features of each body.
local BASE_NAMES = {
  moon = { "TYCHO", "KEPLER", "COPERNICUS", "PLATO", "GRIMALDI", "ARISTARCHUS", "SHACKLETON", "MARIUS", "PROCLUS", "LANGRENUS" },
  mars = { "THARSIS", "HELLAS", "ELYSIUM", "GALE", "JEZERO", "ARABIA", "UTOPIA", "NOCTIS", "ARGYRE", "MERIDIANI" },
  titan = { "KRAKEN", "LIGEIA", "XANADU", "SHANGRI-LA", "SELK", "MENRVA", "PUNGA", "BELET", "ADIRI", "SINLAP" },
  ceres = { "OCCATOR", "KERWAN", "AHUNA", "URVARA", "YALODE", "DANTU", "HAULANI", "ERNUTET", "KUPALO", "JUNINA" },
}
local BASE_SUFFIX = { "STATION", "BASE", "OUTPOST", "CAMP", "DEPOT" }

-- Pay scales with how hard a world is to fly (Mars burns ~2.3x the fuel).
local WORLD_PAY = { moon = 1.0, mars = 1.7, titan = 1.1, ceres = 0.8 }

local CARGO = {
  { name = "WATER",            min = 300, max = 700 },
  { name = "OXYGEN CANISTERS", min = 150, max = 350 },
  { name = "DRILL PARTS",      min = 400, max = 800 },
  { name = "FOOD RATIONS",     min = 100, max = 250 },
  { name = "MEDICAL SUPPLIES", min = 60,  max = 150, fragile = true },
  { name = "SCIENCE PAYLOAD",  min = 50,  max = 120, fragile = true },
  { name = "SOLAR PANELS",     min = 200, max = 400, fragile = true },
  { name = "REACTOR CORE",     min = 500, max = 900, fragile = true },
}

local function careerFile(worldId) return "career_" .. worldId .. ".txt" end

function Mission.saveInfo(worldId)
  local t = settings.readKV(careerFile(worldId))
  if not t then return nil end
  return { deliveries = tonumber(t.deliveries) or 0, credits = tonumber(t.credits) or 0 }
end

---------------------------------------------------------------------------
-- Setup
---------------------------------------------------------------------------

function Mission.new(opts)
  local saved = opts.resume and settings.readKV(careerFile(require("src.worlds")[opts.world].id)) or nil
  if saved and tonumber(saved.rating) then opts.rating = core.clamp(floor(tonumber(saved.rating)), 1, #Game.RATINGS) end

  local self = setmetatable({}, Mission)
  Game.init(self, opts)
  self.isMission = true
  self.pauseItems = {
    { id = "resume", label = "RESUME" },
    { id = "title", label = "QUIT TO TITLE" },
  }
  self.pauseNote = "THE CAREER IS SAVED AT EVERY HQ DOCKING"

  local w = self.world
  self.capacity = w.fuel * TANK_FACTOR
  self.fuelStart = self.capacity            -- fuel gauge and low-fuel warning
  self.fuel = self.capacity
  self.dmg = { engine = 1, rcs = 1, tank = 1, gear = 1, rcsBias = 1 }
  self.credits = START_CREDITS
  self.earned, self.deliveries, self.failed, self.landers = 0, 0, 0, 1
  self.seed = floor(love.math.random() * 2147483647)
  self.ctlLanded = { thr = 0, rot = 0 }
  self:updateLimits()
  if saved then self:applySave(saved) end

  self:buildWorld()
  if saved then self:restoreContract(saved) end
  self:spawnAtHQ()
  self:dock()
  return self
end

function Mission:buildWorld()
  local w = self.world
  local rng = love.math.newRandomGenerator(self.seed + 99)
  local pool = {}
  for i, n in ipairs(BASE_NAMES[w.id] or BASE_NAMES.moon) do pool[i] = n end
  for i = #pool, 2, -1 do
    local j = rng:random(1, i)
    pool[i], pool[j] = pool[j], pool[i]
  end
  local sites = {}
  local hqAt = rng:random(1, OUTPOSTS + 1)
  for i = 1, OUTPOSTS + 1 do
    if i == hqAt then
      sites[i] = { kind = "hq", w = 30, flat = 26, label = "HQ", name = "HEADQUARTERS" }
    else
      local short = table.remove(pool)
      sites[i] = {
        kind = "base", w = rng:random(14, 22), flat = 14, label = short,
        name = short .. " " .. BASE_SUFFIX[rng:random(1, #BASE_SUFFIX)],
      }
    end
  end
  self.terrain = Terrain.new(w, self.seed, { width = WORLD_WIDTH, sites = sites })
  self.bases = {}
  for _, p in ipairs(self.terrain.pads) do
    if p.kind == "hq" then self.hq = p else self.bases[#self.bases + 1] = p end
  end
  self.windBase = (w.wind or 0) * (rng:random() * 2 - 1)
  self.windPhase = { rng:random() * 10, rng:random() * 10, rng:random() * 10 }
end

-- A fresh lander standing on the HQ pad.
function Mission:spawnAtHQ()
  local hq = self.hq
  self.restY = hq.y - Lander.FOOT_Y
  self.lander = Lander.new(hq.cx, self.restY, 0, 0, {
    Fmax = self.Fmax, torqueMax = self.torqueMax, assisted = self.assisted,
    dmg = self.dmg, cargo = self.contract and self.contract.mass or 0,
  })
  self.landedPad = hq
  self.landerVisible = true
  self.debris = {}
  self.particles:clear()
  self.ring = nil
  self.flash = 0
  self.cam.shake = 0
  self.lever = 0
  self.result = nil
  self.toast = nil
  self.apPad, self.apFinal = nil, false
  self.alt = self:altitude()
  self:updateCamera(0, true)
end

---------------------------------------------------------------------------
-- Contracts and HQ services
---------------------------------------------------------------------------

function Mission:distanceTo(pad, fromX)
  return abs(core.wdelta(pad.cx - (fromX or self.hq.cx), self.terrain.W))
end

function Mission:makeOffers()
  local w = self.world
  local vs = core.clamp(sqrt(w.g / 1.62), 0.45, 1.5)
  local offers, used = {}, {}
  while #offers < 3 do
    local base = self.bases[love.math.random(1, #self.bases)]
    if not used[base] then
      used[base] = true
      local cargo = CARGO[love.math.random(1, #CARGO)]
      local mass = floor((cargo.min + love.math.random() * (cargo.max - cargo.min)) / 10 + 0.5) * 10
      local dist = self:distanceTo(base)
      local reward = (100 + dist * 0.4 + mass * 0.35) * (cargo.fragile and 1.35 or 1) * (WORLD_PAY[w.id] or 1)
      offers[#offers + 1] = {
        base = base, cargo = cargo.name, fragile = cargo.fragile or false, mass = mass, dist = dist,
        reward = floor(reward / 10 + 0.5) * 10,
        deadline = floor((60 + dist / (11 * vs) + mass * 0.03) / self.rating.speed),
      }
    end
  end
  table.sort(offers, function(a, b) return a.dist < b.dist end)
  self.offers = offers
end

function Mission:accept(o)
  self.contract = {
    base = o.base, cargo = o.cargo, fragile = o.fragile, mass = o.mass,
    dist = o.dist, reward = o.reward, deadline = o.deadline, timeLeft = o.deadline,
  }
  self.offers = nil
  self.lander.cargo = o.mass
  self:panelMessage(string.format("LOADED %d KG %s FOR %s", o.mass, o.cargo, o.base.label))
  audio.play("chime", 0.5)
  self:save()
end

function Mission:refuelQuote()
  local need = self.capacity - self.fuel
  if need < 1 then return 0, 0, "full" end
  if self.credits < 1 and self.fuel < self.capacity * EMERGENCY_FUEL then
    return floor(self.capacity * EMERGENCY_FUEL - self.fuel), 0, "emergency"
  end
  local kg = min(need, self.credits / FUEL_PRICE)
  return floor(kg), ceil(floor(kg) * FUEL_PRICE), kg < need and "partial" or "ok"
end

function Mission:refuel()
  local kg, cost, kind = self:refuelQuote()
  if kg < 1 then
    self:panelMessage(kind == "full" and "THE TANK IS FULL" or "NO CREDITS FOR FUEL")
    return
  end
  self.fuel = self.fuel + kg
  self.credits = self.credits - cost
  self:panelMessage(kind == "emergency" and string.format("EMERGENCY ALLOWANCE: +%d KG", kg)
    or string.format("PUMPED %d KG FOR %d CR", kg, cost))
  audio.play("blip")
  self:save()
end

function Mission:repairQuote()
  local pts = 0
  for _, s in ipairs(SYSTEMS) do pts = pts + (1 - self.dmg[s]) * 100 end
  return ceil(pts * REPAIR_PRICE - 0.001), pts
end

function Mission:repair()
  local cost, pts = self:repairQuote()
  if pts < 0.5 then self:panelMessage("ALL SYSTEMS NOMINAL"); return end
  if self.credits < 1 then self:panelMessage("NO CREDITS FOR REPAIRS"); return end
  local frac = min(1, self.credits / cost)
  for _, s in ipairs(SYSTEMS) do self.dmg[s] = self.dmg[s] + (1 - self.dmg[s]) * frac end
  local paid = min(cost, ceil(cost * frac))
  self.credits = max(0, self.credits - paid)
  self:updateLimits()
  self:panelMessage(frac < 1 and string.format("PARTIAL REPAIR FOR %d CR", paid)
    or string.format("REPAIRED FOR %d CR", paid))
  audio.play("blip")
  self:save()
end

function Mission:panelMessage(text) self.panelMsg = { text = text, t = 3 } end

-- Rows of the HQ panel: { text, right, kind, offer, selectable }.
function Mission:panelRows()
  local rows = {}
  local c = self.contract
  if c then
    rows[#rows + 1] = { text = string.format("TO %-20s %4dKG", c.base.name, c.mass),
      right = (c.timeLeft >= 0 and "T-" or "LATE ") .. hud.fmtTime(abs(c.timeLeft)), kind = "active" }
  else
    for _, o in ipairs(self.offers or {}) do
      rows[#rows + 1] = {
        text = string.format("%-18s%5dM%5dKG", o.base.name .. (o.fragile and "*" or ""), o.dist, o.mass),
        right = string.format("%dCR %s", o.reward, hud.fmtTime(o.deadline)),
        kind = "offer", offer = o, selectable = true,
      }
    end
  end
  local kg, cost, kind = self:refuelQuote()
  rows[#rows + 1] = {
    text = "REFUEL", kind = "refuel", selectable = true, gap = true,
    right = kind == "full" and "TANK FULL" or kind == "emergency" and string.format("+%d KG FREE", kg)
      or kg < 1 and "NO CREDITS" or string.format("+%d KG  -%d CR", kg, cost),
  }
  local rcost, pts = self:repairQuote()
  rows[#rows + 1] = {
    text = "REPAIR", kind = "repair", selectable = true,
    right = pts < 0.5 and "ALL SYSTEMS OK" or string.format("-%d CR", rcost),
  }
  rows[#rows + 1] = { text = "LAUNCH", kind = "launch", selectable = true }
  return rows
end

function Mission:panelDetail(row)
  if self.panelMsg then return self.panelMsg.text end
  if not row then return "" end
  if row.kind == "offer" then
    local o = row.offer
    return string.format("%s - %d KG%s - DEADLINE %s", o.cargo, o.mass, o.fragile and " - FRAGILE" or "", hud.fmtTime(o.deadline))
  elseif row.kind == "refuel" then
    return string.format("TANK %d / %d KG - FUEL %.1f CR PER KG", floor(self.fuel + 0.5), self.capacity, FUEL_PRICE)
  elseif row.kind == "repair" then
    local parts = {}
    for _, s in ipairs(SYSTEMS) do parts[#parts + 1] = string.format("%s %d%%", SYS_LABEL[s], floor(self.dmg[s] * 100 + 0.5)) end
    return table.concat(parts, "  ")
  elseif row.kind == "launch" then
    return self.contract and ("DELIVER " .. self.contract.cargo .. " TO " .. self.contract.base.label)
      or "TAKE OFF WITHOUT CARGO - B ALSO CLOSES THIS PANEL"
  end
  return ""
end

function Mission:dock()
  self.phase = "docked"
  self.phaseT = 0
  self.dockPending = nil
  self.landedPad = self.hq
  if not self.contract and not self.offers then self:makeOffers() end
  self.panelSel = nil
  self:save()
end

function Mission:launch()
  self.phase = "landed"
  self.phaseT = 0
  self.panelMsg = nil
  audio.play("blip")
end

function Mission:updatePanel()
  local I = input
  local rows = self:panelRows()
  local function step(from, dir)
    local i = from
    for _ = 1, #rows do
      i = (i - 1 + dir) % #rows + 1
      if rows[i].selectable then return i end
    end
    return from
  end
  if not self.panelSel or not (rows[self.panelSel] and rows[self.panelSel].selectable) then
    self.panelSel = step(#rows, 1)
  end
  if I.nav("up") then self.panelSel = step(self.panelSel, -1); self.panelMsg = nil; audio.play("blip") end
  if I.nav("down") then self.panelSel = step(self.panelSel, 1); self.panelMsg = nil; audio.play("blip") end
  if I.pressed.b then return self:launch() end
  if I.pressed.a then
    local row = rows[self.panelSel]
    if row.kind == "offer" then self:accept(row.offer); self.panelSel = nil
    elseif row.kind == "refuel" then self:refuel()
    elseif row.kind == "repair" then self:repair()
    elseif row.kind == "launch" then self:launch() end
  end
end

---------------------------------------------------------------------------
-- Damage
---------------------------------------------------------------------------

-- Damaged gear shrinks the touchdown envelope (down to 55%).
function Mission:tol()
  return self.rating.tol * (0.55 + 0.45 * self.dmg.gear)
end

-- Hard landing: the gear always takes a hit, plus one random system.
function Mission:applyDamage(vdown, hs, tilt)
  local tol, soft = self:tol(), GRADES[2]
  local r = max(vdown / (soft.v * tol), hs / (soft.h * tol), tilt / (soft.tilt * tol))
  local sev = core.clamp((r - 1) / 0.9, 0, 1)
  local hits = { gear = 0.12 + 0.3 * sev }
  hits[({ "engine", "rcs", "tank" })[love.math.random(1, 3)]] = 0.08 + 0.3 * sev
  local parts = {}
  for _, s in ipairs(SYSTEMS) do
    if hits[s] then
      local before = self.dmg[s]
      self.dmg[s] = max(0, before - hits[s])
      if s == "rcs" then self.dmg.rcsBias = love.math.random() < 0.5 and -1 or 1 end
      parts[#parts + 1] = string.format("%s -%d%%", SYS_LABEL[s], floor((before - self.dmg[s]) * 100 + 0.5))
    end
  end
  self:updateLimits()
  return "DAMAGE  " .. table.concat(parts, "  ")
end

---------------------------------------------------------------------------
-- Outcomes
---------------------------------------------------------------------------

function Mission:land(grade, pad, vdown, hs, tilt, groundY)
  local L = self.lander
  self.phase = "landed"
  self.phaseT = 0
  L.vx, L.vy, L.w, L.rcs, L.a = 0, 0, 0, 0, 0
  self.restY = groundY - Lander.FOOT_Y
  L.y = self.restY
  self.lever = 0
  self.landedPad = pad

  local lines = { string.format("V %.1f   H %.1f M/S   TILT %d^", vdown, hs, floor(tilt + 0.5)) }
  if grade.id == "hard" then lines[#lines + 1] = self:applyDamage(vdown, hs, tilt) end

  local title, sub = grade.title, pad and pad.name or "OFF-PAD"
  local c = self.contract
  if c and pad == c.base then
    local pay = c.reward
    if c.timeLeft < 0 then pay = pay * 0.5; lines[#lines + 1] = "LATE - HALF PAY" end
    if grade.id == "hard" then
      if c.fragile then pay = pay * 0.3; lines[#lines + 1] = "FRAGILE CARGO DAMAGED - 30% PAY"
      else pay = pay * 0.85; lines[#lines + 1] = "ROUGH HANDLING - 85% PAY" end
    elseif grade.id == "perfect" then
      pay = pay * 1.1; lines[#lines + 1] = "PERFECT LANDING BONUS +10%"
    end
    pay = floor(pay + 0.5)
    self.credits = self.credits + pay
    self.earned = self.earned + pay
    self.deliveries = self.deliveries + 1
    lines[#lines + 1] = string.format("%s DELIVERED: +%d CR", c.cargo, pay)
    title, sub = "DELIVERED", grade.title .. " AT " .. pad.name
    self.contract = nil
    L.cargo = 0
  elseif pad == self.hq then
    self.dockPending = 1.0
  end
  if self:stranded() and pad ~= self.hq then
    lines[#lines + 1] = string.format("STRANDED - B CALLS A RESCUE (%d CR)", RESCUE_COST)
  end
  self.toast = { title = title, sub = sub, lines = lines, t = 6 }

  local rnd = love.math.random
  for _ = 1, floor(10 + vdown * 10) do
    local side = rnd() < 0.5 and -1 or 1
    local sp = (2 + rnd() * 6) * (0.5 + vdown * 0.5)
    self.particles:add(L.x + side * Lander.FOOT_X, groundY + 0.1, side * sp, sp * (0.1 + rnd() * 0.4), 0.6 + rnd() * 0.8, 2, 0.4)
  end
  if grade.id == "hard" then
    self.cam.shake = 0.45
    audio.play("thud", 0.9)
  else
    audio.play("chime", 0.7)
  end
end

-- Can't take off: out of propellant, or too heavy for the damaged engine.
function Mission:stranded()
  if self.fuel < 2 then return true end
  local L = self.lander
  return self.Fmax * L:engineFactor() < L:mass(self.fuel) * self.world.g * 1.02
end

function Mission:rescue()
  if self.credits < RESCUE_COST then
    return self:careerOver("NO CREDITS LEFT FOR A RESCUE")
  end
  self.credits = self.credits - RESCUE_COST
  self:spawnAtHQ()
  self:dock()
  self:panelMessage(string.format("TOWED BACK TO HQ FOR %d CR", RESCUE_COST))
end

function Mission:crash(reason)
  self:explode()
  self.toast = nil
  self.dockPending = nil
  local lines = {}
  if self.contract then
    lines[#lines + 1] = "CARGO LOST: " .. self.contract.cargo
    self.failed = self.failed + 1
    self.contract = nil
  end
  self.canReplace = self.credits >= REPLACEMENT_COST
  if self.canReplace then
    lines[#lines + 1] = string.format("REPLACEMENT LANDER -%d CR", REPLACEMENT_COST)
  else
    lines[#lines + 1] = string.format("A NEW LANDER COSTS %d CR - YOU HAVE %d", REPLACEMENT_COST, floor(self.credits))
  end
  self.result = { kind = "crash", title = "LANDER DESTROYED", sub = reason, lines = lines }
end

function Mission:replaceLander()
  self.credits = self.credits - REPLACEMENT_COST
  self.landers = self.landers + 1
  for _, s in ipairs(SYSTEMS) do self.dmg[s] = 1 end
  self.fuel = self.capacity
  self:updateLimits()
  self.offers = nil
  self:spawnAtHQ()
  self:dock()
  self:panelMessage("A NEW LANDER IS READY ON THE PAD")
end

function Mission:careerOver(reason)
  self.phase = "over"
  self.phaseT = 0
  self.toast = nil
  settings.remove(careerFile(self.world.id))
  local key = "m_" .. self.world.id
  local best = settings.hiscores[key] or 0
  local record = self.earned > best
  if record then
    settings.hiscores[key] = self.earned
    settings.save()
  end
  self.result = {
    kind = "gameover", title = "CAREER OVER", sub = reason,
    lines = {
      string.format("%d DELIVERIES - %d FAILED - %d LANDERS", self.deliveries, self.failed, self.landers),
      string.format("EARNED %d CR%s", self.earned, record and " - NEW RECORD" or ""),
    },
  }
  audio.play("beep", 0.6)
end

---------------------------------------------------------------------------
-- Update
---------------------------------------------------------------------------

function Mission:update(dt)
  local I = input
  dt = min(dt, 0.1)
  if self:handlePauseToggle() then return end
  if self.paused then return self:updatePause() end

  local phase = self.phase
  if phase == "docked" then
    self.ctl.thr, self.ctl.rot = 0, 0
    self:updatePanel()
  elseif phase == "fly" or phase == "landed" then
    if self.autopilotOn then self:autopilot() else self:readControls(dt) end
    if phase == "landed" then
      self.ctl.rot = 0
      if I.pressed.b then
        if self.landedPad == self.hq then self:dock()
        elseif self:stranded() then self:rescue() end
      end
      if self.dockPending then
        self.dockPending = self.dockPending - dt
        if self.dockPending <= 0 then self:dock() end
      end
    end
  else
    self.ctl.thr, self.ctl.rot = 0, 0
  end

  self:updateCommon(dt)

  if self.toast then
    self.toast.t = self.toast.t - dt
    if self.toast.t <= 0 then self.toast = nil end
  end
  if self.panelMsg then
    self.panelMsg.t = self.panelMsg.t - dt
    if self.panelMsg.t <= 0 then self.panelMsg = nil end
  end

  if self.phase == "crashed" and self.phaseT > 1.0 and I.pressed.a then
    if self.canReplace then self:replaceLander() else self:careerOver("NO CREDITS FOR A NEW LANDER") end
  elseif self.phase == "over" and self.phaseT > 1.0 and I.pressed.a then
    self.app.toTitle()
  end
end

function Mission:fixedStep(dt)
  local c = self.contract
  if c and (self.phase == "fly" or self.phase == "landed") then c.timeLeft = c.timeLeft - dt end
  if self.phase == "fly" then return Game.fixedStep(self, dt) end
  if self.phase ~= "landed" then return end

  -- On the ground: the engine can run (and the tank can leak); thrust
  -- greater than weight lifts the lander off.
  local L = self.lander
  self.time = self.time + dt
  self.ctlLanded.thr = self.ctl.thr
  local used = min(L:step(dt, self.ctlLanded, self.env, self.fuel), self.fuel)
  self.fuel = self.fuel - used
  self.sortieFuel = self.sortieFuel + used
  L.vx, L.w, L.a = 0, 0, 0
  if L.y <= self.restY then
    L.y = self.restY
    if L.vy < 0 then L.vy = 0 end
  elseif L.y > self.restY + 0.05 and L.vy > 0 then
    self.phase = "fly"
    self.phaseT = 0
    self.landedPad = nil
    self.dockPending = nil
  end
  self:emit(dt)
end

function Mission:pauseAction(id)
  if id == "resume" then self.paused = false else self.app.toTitle() end
end

-- Where to go next: the contract's outpost, else HQ.
function Mission:target()
  return self.contract and self.contract.base or self.hq
end

---------------------------------------------------------------------------
-- Saving (only ever while docked at HQ)
---------------------------------------------------------------------------

function Mission:save()
  local d = self.dmg
  local t = {
    seed = self.seed, rating = self.ratingIndex, credits = floor(self.credits), fuel = floor(self.fuel),
    engine = d.engine, rcs = d.rcs, tank = d.tank, gear = d.gear, rcsBias = d.rcsBias,
    earned = self.earned, deliveries = self.deliveries, failed = self.failed, landers = self.landers,
  }
  local c = self.contract
  if c then
    for i, p in ipairs(self.terrain.pads) do if p == c.base then t.c_base = i end end
    t.c_cargo, t.c_fragile, t.c_mass = c.cargo, c.fragile and 1 or 0, c.mass
    t.c_dist, t.c_reward, t.c_deadline, t.c_time = c.dist, c.reward, c.deadline, floor(c.timeLeft)
  end
  settings.writeKV(careerFile(self.world.id), t)
end

function Mission:applySave(t)
  local function num(k, def) return tonumber(t[k]) or def end
  self.seed = num("seed", self.seed)
  self.credits = num("credits", self.credits)
  self.fuel = core.clamp(num("fuel", self.fuel), 0, self.capacity)
  for _, s in ipairs(SYSTEMS) do self.dmg[s] = core.clamp(num(s, 1), 0, 1) end
  self.dmg.rcsBias = num("rcsBias", 1) < 0 and -1 or 1
  self.earned, self.deliveries = num("earned", 0), num("deliveries", 0)
  self.failed, self.landers = num("failed", 0), num("landers", 1)
  self:updateLimits()
end

function Mission:restoreContract(t)
  local base = self.terrain.pads[tonumber(t.c_base) or -1]
  if not base or base.kind ~= "base" then return end
  self.contract = {
    base = base, cargo = t.c_cargo or "CARGO", fragile = t.c_fragile == "1",
    mass = tonumber(t.c_mass) or 0, dist = tonumber(t.c_dist) or 0, reward = tonumber(t.c_reward) or 0,
    deadline = tonumber(t.c_deadline) or 0, timeLeft = tonumber(t.c_time) or 0,
  }
end

---------------------------------------------------------------------------
-- Draw
---------------------------------------------------------------------------

function Mission:draw()
  self:drawWorld()
  hud.drawMission(self)
end

return Mission
