-- Input: merges SDL gamepad (D-pad, buttons, sticks, triggers) with the
-- keyboard, and exposes per-frame "down"/"pressed" states plus menu repeat.
--
-- On the handheld, PortMaster's gptokeyb also turns buttons into key
-- presses. When a real gamepad is visible to SDL there, the keyboard is
-- ignored so nothing is read twice.

local core = require("src.core")

local I = {}

local ACTIONS = { "left", "right", "up", "down", "a", "b", "x", "y", "l1", "r1", "start", "select" }

local KEYS = {
  left = { "left" }, right = { "right" }, up = { "up" }, down = { "down" },
  a = { "z", "space" }, b = { "x", "lshift" }, x = { "c", "h" }, y = { "v" },
  l1 = { "q", "pageup" }, r1 = { "e", "pagedown" },
  start = { "return", "p" }, select = { "escape", "backspace" },
}

local PAD = {
  left = "dpleft", right = "dpright", up = "dpup", down = "dpdown",
  a = "a", b = "b", x = "x", y = "y",
  l1 = "leftshoulder", r1 = "rightshoulder",
  start = "start", select = "back",
}

local DEAD = 0.18

I.down, I.pressed = {}, {}
I.lx, I.ly = 0, 0     -- left stick, dead-zoned (-1..1)
I.thr = 0             -- analog throttle 0..1 (stick up / right trigger)
I.swapAB = false
I.keyboard = true

local pads = {}
local raw = {}
local navDown, navRep, navTimer = {}, {}, {}
local navNow = {}

function I.refresh()
  pads = {}
  if love.joystick then
    for _, j in ipairs(love.joystick.getJoysticks()) do
      if j:isGamepad() then pads[#pads + 1] = j end
    end
  end
  I.keyboard = not (core.device and #pads > 0)
end

function I.init(swap)
  I.swapAB = swap and true or false
  I.refresh()
end

local function dz(v)
  local a = math.abs(v)
  if a < DEAD then return 0 end
  local s = (a - DEAD) / (1 - DEAD)
  return v < 0 and -s or s
end

local function keyDown(list)
  for i = 1, #list do
    if love.keyboard.isDown(list[i]) then return true end
  end
  return false
end

function I.update(dt)
  for _, a in ipairs(ACTIONS) do
    local d = I.keyboard and keyDown(KEYS[a]) or false
    if not d then
      local btn = PAD[a]
      for _, j in ipairs(pads) do
        if j:isGamepadDown(btn) then d = true; break end
      end
    end
    raw[a] = d
  end
  if I.swapAB then raw.a, raw.b = raw.b, raw.a end
  for _, a in ipairs(ACTIONS) do
    local d = raw[a]
    I.pressed[a] = d and not I.down[a]
    I.down[a] = d
  end

  local lx, ly, ry, rt = 0, 0, 0, 0
  for _, j in ipairs(pads) do
    local v = j:getGamepadAxis("leftx"); if math.abs(v) > math.abs(lx) then lx = v end
    v = j:getGamepadAxis("lefty"); if math.abs(v) > math.abs(ly) then ly = v end
    v = j:getGamepadAxis("righty"); if math.abs(v) > math.abs(ry) then ry = v end
    v = j:getGamepadAxis("triggerright"); if v > rt then rt = v end
  end
  I.lx, I.ly = dz(lx), dz(ly)
  I.thr = math.max(0, -I.ly, -dz(ry), rt > 0.1 and rt or 0)

  -- Menu navigation with auto-repeat (D-pad or left stick).
  navNow.left = I.down.left or lx < -0.55
  navNow.right = I.down.right or lx > 0.55
  navNow.up = I.down.up or ly < -0.55
  navNow.down = I.down.down or ly > 0.55
  for dir, d in pairs(navNow) do
    if d and not navDown[dir] then
      navRep[dir] = true
      navTimer[dir] = 0.35
    elseif d then
      navTimer[dir] = navTimer[dir] - dt
      if navTimer[dir] <= 0 then
        navRep[dir] = true
        navTimer[dir] = 0.09
      else
        navRep[dir] = false
      end
    else
      navRep[dir] = false
    end
    navDown[dir] = d
  end
end

function I.nav(dir) return navRep[dir] or false end

function I.anyPressed()
  for _, a in ipairs(ACTIONS) do
    if I.pressed[a] then return true end
  end
  return false
end

function I.quitCombo() return I.down.start and I.down.select end

return I
