-- teslaBridge/steerfeel.lua
-- What a real electric-power-steering wheel feels like, as a force on the physical wheel.
-- Pure Lua (tested in beamng/test/). Terms, the way an EPS system builds them:
--   self-aligning torque: the wheel wants to return to centre, stiff near centre and levelling out
--                         with angle, stronger with speed and with lateral acceleration
--   friction:             a steady drag against any movement (tyre scrub + the rack), more at parking speed
--   damping:              resists fast movement, more at speed (no flicking the wheel about)
--   on-centre:            the centre isn't a knife edge: forces fade in over the first few degrees
-- Steering Weight (Tesla: Light / Standard / Heavy) scales the whole thing.
--
-- torque{ pos (-1..1, wheel angle as a fraction of full lock), vel (1/s), v (m/s), latAcc (m/s^2, any sign),
--         weight = 'light'|'standard'|'heavy', gain } -> force in -1..1; positive pushes toward +pos.

local M = {}
local abs, min, max, tanh = math.abs, math.min, math.max, function(x) local e = math.exp(2 * x) return (e - 1) / (e + 1) end

M.WEIGHT = { light = 0.75, standard = 1.0, heavy = 1.35 }

local function clamp(x, lo, hi) if x < lo then return lo elseif x > hi then return hi end return x end
local function smoothstep(x) x = clamp(x, 0, 1) return x * x * (3 - 2 * x) end

function M.torque(p)
  local pos, vel, v = p.pos or 0, p.vel or 0, abs(p.v or 0)
  local w = M.WEIGHT[p.weight or 'standard'] or 1
  local speedK = clamp(v / 25, 0, 1)                 -- 0 parked .. 1 at ~55 mph
  local a = abs(pos)
  local dir = pos > 0 and 1 or (pos < 0 and -1 or 0)
  -- self-aligning: stiff around centre, levelling out; speed adds weight, lateral load adds more
  local sat = a / (a + 0.18)
  local lat = clamp(abs(p.latAcc or 0) / 9, 0, 1)
  local align = (0.06 + 0.32 * speedK + 0.30 * lat * speedK) * sat
  local force = -dir * align * smoothstep(a / 0.03)  -- fades in over the first few degrees
  -- friction: drags against movement; scrub is more noticeable when slow
  force = force - tanh(vel / 0.05) * (0.035 + 0.05 * (1 - speedK)) * min(1, a / 0.02 + 0.3)
  -- damping: heavier at speed
  force = force - vel * (0.012 + 0.02 * speedK)
  return clamp(force * w * (p.gain or 1), -1, 1)
end

return M
