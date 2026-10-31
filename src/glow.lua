-- Phosphor bloom. The vector scene is downsampled to 1/2 and 1/4 size,
-- blurred with a separable 9-tap Gaussian (5 bilinear fetches), and
-- added back on top of the sharp lines. At 720x480 this costs very little
-- on the Mali-G31, and the shader is plain GLSL ES 1.0.

local lg = love.graphics

local G = {}

local SHADER = [[
extern vec2 dir;
vec4 effect(vec4 color, Image tex, vec2 tc, vec2 sc)
{
  vec4 s = Texel(tex, tc) * 0.2270270270;
  s += Texel(tex, tc + dir * 1.3846153846) * 0.3162162162;
  s += Texel(tex, tc - dir * 1.3846153846) * 0.3162162162;
  s += Texel(tex, tc + dir * 3.2307692308) * 0.0702702703;
  s += Texel(tex, tc - dir * 3.2307692308) * 0.0702702703;
  return s * color;
}
]]

local shader
local h1, h2, q1, q2
local hw, hh, qw, qh

function G.init(w, h)
  if not shader then
    local ok, s = pcall(lg.newShader, SHADER)
    if ok then shader = s else print("glow shader failed: " .. tostring(s)) end
  end
  hw, hh = math.floor(w / 2), math.floor(h / 2)
  qw, qh = math.floor(w / 4), math.floor(h / 4)
  h1, h2 = lg.newCanvas(hw, hh), lg.newCanvas(hw, hh)
  q1, q2 = lg.newCanvas(qw, qh), lg.newCanvas(qw, qh)
  for _, c in ipairs({ h1, h2, q1, q2 }) do c:setFilter("linear", "linear") end
end

local function blur(a, b, w, h)
  lg.setShader(shader)
  lg.setCanvas(b)
  lg.clear(0, 0, 0, 1)
  shader:send("dir", { 1 / w, 0 })
  lg.draw(a)
  lg.setCanvas(a)
  lg.clear(0, 0, 0, 1)
  shader:send("dir", { 0, 1 / h })
  lg.draw(b)
  lg.setShader()
end

-- level: 1 = off, 2 = low, 3 = high. Draws the composite into target.
function G.composite(scene, level, target)
  if not shader then level = 1 end
  lg.setColor(1, 1, 1, 1)
  if level > 1 then
    lg.setCanvas(h1)
    lg.clear(0, 0, 0, 1)
    lg.draw(scene, 0, 0, 0, hw / scene:getWidth(), hh / scene:getHeight())
    if level == 3 then
      lg.setCanvas(q1)
      lg.clear(0, 0, 0, 1)
      lg.draw(h1, 0, 0, 0, qw / hw, qh / hh)
    end
    blur(h1, h2, hw, hh)
    if level == 3 then
      blur(q1, q2, qw, qh)
      blur(q1, q2, qw, qh)
    end
  end

  lg.setCanvas(target)
  lg.clear(0, 0, 0, 1)
  lg.draw(scene)
  if level > 1 then
    local sw, sh = scene:getWidth(), scene:getHeight()
    lg.setBlendMode("add")
    local k = (level == 3) and 0.8 or 0.95
    lg.setColor(k, k, k, 1)
    lg.draw(h1, 0, 0, 0, sw / hw, sh / hh)
    if level == 3 then
      lg.setColor(0.85, 0.85, 0.85, 1)
      lg.draw(q1, 0, 0, 0, sw / qw, sh / qh)
    end
    lg.setBlendMode("alpha")
    lg.setColor(1, 1, 1, 1)
  end
end

return G
