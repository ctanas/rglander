-- Procedural audio: every sound is synthesised at start-up, so the game
-- ships with no asset files. Loops are crossfaded so they repeat seamlessly.

local core = require("src.core")

local A = { enabled = true, ok = false }

local RATE = 22050
local src = {}
local thrVol, rcsVol = 0, 0

local floor, sin, exp, abs, pi = math.floor, math.sin, math.exp, math.abs, math.pi

local function toSoundData(buf, n, gain)
  local peak = 1e-6
  for i = 0, n - 1 do
    local v = abs(buf[i]); if v > peak then peak = v end
  end
  local sd = love.sound.newSoundData(n, RATE, 16, 1)
  local k = gain / peak
  for i = 0, n - 1 do sd:setSample(i, buf[i] * k) end
  return sd
end

-- Low-passed noise loop (rumble) with optional high hiss on top.
local function noiseLoop(seconds, a1, a2, hiss)
  local n = floor(seconds * RATE)
  local f = floor(0.12 * RATE)
  local rawb = {}
  local y1, y2, lp = 0, 0, 0
  local rnd = love.math.random
  for i = 0, n + f - 1 do
    local w = rnd() * 2 - 1
    y1 = y1 + (w - y1) * a1
    y2 = y2 + (y1 - y2) * a2
    lp = lp + (w - lp) * 0.3
    rawb[i] = y2 + (w - lp) * hiss
  end
  local out = {}
  for i = 0, n - 1 do
    local v = rawb[i]
    if i < f then
      local t = i / f
      v = rawb[i] * t + rawb[n + i] * (1 - t)
    end
    out[i] = v
  end
  return toSoundData(out, n, 0.9)
end

local function tone(seconds, fn)
  local n = floor(seconds * RATE)
  local buf = {}
  for i = 0, n - 1 do buf[i] = fn(i / RATE, i) end
  return toSoundData(buf, n, 0.8)
end

local function build()
  local rnd = love.math.random
  local sd = {}
  sd.thrust = noiseLoop(1.6, 0.05, 0.22, 0.10)
  sd.rcs = noiseLoop(0.8, 0.9, 0.9, 1.6)
  sd.blip = tone(0.045, function(t) return sin(2 * pi * 1320 * t) * (1 - t / 0.045) end)
  sd.beep = tone(0.11, function(t)
    local s = sin(2 * pi * 880 * t)
    return (s > 0 and 1 or -1) * 0.5 * math.min(1, t * 200) * (1 - t / 0.11)
  end)
  sd.alarm = tone(0.42, function(t)
    local f = (floor(t / 0.105) % 2 == 0) and 660 or 880
    return sin(2 * pi * f * t) * 0.7
  end)
  sd.chime = tone(1.2, function(t)
    local v = 0
    local notes = { 523.25, 659.25, 783.99, 1046.5 }
    for k, f in ipairs(notes) do
      local st = (k - 1) * 0.09
      if t >= st then v = v + sin(2 * pi * f * (t - st)) * exp(-(t - st) * 4.5) end
    end
    return v
  end)
  local lpT = 0
  sd.thud = tone(0.45, function(t)
    lpT = lpT + ((rnd() * 2 - 1) - lpT) * 0.08
    return (sin(2 * pi * 62 * t) * 0.8 + lpT * 2.5) * exp(-t * 9)
  end)
  local lpE, lpE2 = 0, 0
  sd.explode = tone(2.2, function(t)
    local a = 0.5 * exp(-t * 2.2) + 0.03
    lpE = lpE + ((rnd() * 2 - 1) - lpE) * a
    lpE2 = lpE2 + (lpE - lpE2) * 0.3
    local env = exp(-t * 1.9) * math.min(1, t * 400)
    return (lpE2 * 1.3 + sin(2 * pi * 45 * t) * 0.3 * exp(-t * 4)) * env
  end)
  return sd
end

function A.init(enabled)
  A.enabled = enabled ~= false
  if not love.audio or not love.sound then return end
  local ok, sd = pcall(build)
  if not ok then
    print("audio disabled: " .. tostring(sd))
    return
  end
  for name, data in pairs(sd) do src[name] = love.audio.newSource(data, "static") end
  src.thrust:setLooping(true)
  src.rcs:setLooping(true)
  A.ok = true
end

function A.setEnabled(on)
  A.enabled = on
  if not on and A.ok then love.audio.stop() end
end

function A.play(name, vol, pitch)
  if not (A.ok and A.enabled) then return end
  local s = src[name]
  if not s then return end
  s:stop()
  s:setVolume(vol or 0.7)
  s:setPitch(pitch or 1)
  s:play()
end

-- Continuous sounds follow engine throttle and RCS activity.
function A.update(dt, thrust, rcs)
  if not A.ok then return end
  local on = A.enabled
  thrVol = core.approach(thrVol, on and (thrust > 0.01 and 0.12 + thrust * 0.55 or 0) or 0, 18, dt)
  rcsVol = core.approach(rcsVol, on and rcs * 0.22 or 0, 30, dt)
  local t = src.thrust
  if thrVol > 0.004 then
    t:setVolume(thrVol)
    t:setPitch(0.75 + 0.45 * thrust)
    if not t:isPlaying() then t:play() end
  elseif t:isPlaying() then
    t:pause()
  end
  local r = src.rcs
  if rcsVol > 0.004 then
    r:setVolume(rcsVol)
    if not r:isPlaying() then r:play() end
  elseif r:isPlaying() then
    r:pause()
  end
end

function A.silence()
  thrVol, rcsVol = 0, 0
  if A.ok then
    src.thrust:pause()
    src.rcs:pause()
  end
end

return A
