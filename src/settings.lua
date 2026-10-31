-- Persistent settings and high scores (plain key=value text in the save dir).

local S = {
  data = {
    world = 1,       -- index into worlds
    rating = 2,      -- 1 cadet, 2 pilot, 3 commander
    attitude = 1,    -- 1 assisted, 2 manual
    glow = 3,        -- 1 off, 2 low, 3 high
    phosphor = 1,
    aspect = 1,      -- 1 = 3:2 (720x480 square pixels), 2 = 4:3 panel
    swapab = false,
    sound = true,
  },
  hiscores = {},
}

local FILE = "settings.txt"

function S.load()
  if not love.filesystem.getInfo(FILE) then return end
  local ok, content = pcall(love.filesystem.read, FILE)
  if not ok or type(content) ~= "string" then return end
  S.fromFile = true   -- the player has saved settings; don't apply first-run defaults
  for line in content:gmatch("[^\r\n]+") do
    local k, v = line:match("^([%w_]+)%s*=%s*(.-)%s*$")
    if k then
      local hs = k:match("^hi_(.+)$")
      if hs then
        S.hiscores[hs] = tonumber(v) or 0
      elseif S.data[k] ~= nil then
        if type(S.data[k]) == "boolean" then
          S.data[k] = (v == "true")
        else
          S.data[k] = tonumber(v) or S.data[k]
        end
      end
    end
  end
end

function S.sanitize(nworlds)
  local d = S.data
  local function int(v, lo, hi, def)
    v = math.floor(tonumber(v) or def)
    if v < lo or v > hi then v = def end
    return v
  end
  d.world = int(d.world, 1, nworlds, 1)
  d.rating = int(d.rating, 1, 3, 2)
  d.attitude = int(d.attitude, 1, 2, 1)
  d.glow = int(d.glow, 1, 3, 3)
  d.phosphor = int(d.phosphor, 1, 4, 1)
  d.aspect = int(d.aspect, 1, 2, 1)
end

function S.save()
  if require("src.core").testMode then return end
  local out = {}
  for k, v in pairs(S.data) do out[#out + 1] = k .. "=" .. tostring(v) end
  for k, v in pairs(S.hiscores) do out[#out + 1] = "hi_" .. k .. "=" .. tostring(v) end
  table.sort(out)
  pcall(love.filesystem.write, FILE, table.concat(out, "\n") .. "\n")
end

return S
