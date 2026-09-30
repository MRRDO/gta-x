-- teslaBridge/brain.lua
-- A small reasoning layer: instead of reacting to one alarming number (a predicted
-- time-to-collision), it keeps a belief (0..1) that each nearby car is a real threat and
-- updates it every tick from several clues, the way a driver builds confidence:
--   is it in my lane right now? coming at me head-on or just passing in the next lane?
--   on my level (not on a bridge above/below)? has it looked dangerous for a while?
-- Belief is kept as log-odds (add evidence, clamp, decay), so it costs a few multiplies per
-- car per tick: no model files, no allocations in the hot path beyond one table per car.
-- Pure Lua (tested in beamng/test/).

local M = {}

local abs, exp, min, max, sqrt = math.abs, math.exp, math.min, math.max, math.sqrt

local PRIOR = -2.0      -- ~12%: most cars around us are not about to hit us
local LO_MIN, LO_MAX = -4, 4
M.BRAKE = 0.85          -- belief needed for emergency braking
M.WARN = 0.6            -- belief needed for a collision warning

local Brain = {}
Brain.__index = Brain

function M.new()
  return setmetatable({ lo = {}, lastT = {} }, Brain)
end

-- where car c sits relative to us: along our heading, sideways, and heading agreement
local function relative(ego, c)
  local rx, ry = c.x - ego.x, c.y - ego.y
  local lon = rx * ego.hx + ry * ego.hy
  local lat = -rx * ego.hy + ry * ego.hx
  local dot = (c.dx or 0) * ego.hx + (c.dy or 0) * ego.hy
  return lon, lat, dot
end
M.relative = relative

-- How much this tick's clues say "real threat" (log-odds units).
-- ttc/need are from the physics prediction for this car (nil when it predicted no hit).
function M.evidence(ego, c, ttc, need)
  local e = 0
  local lon, lat, dot = relative(ego, c)
  local corridor = ((ego.wid or 1.9) + (c.w or 1.9)) * 0.5
  local inLane = lon > 0 and abs(lat) < corridor - 0.3
  local graze = lon > 0 and not inLane and abs(lat) < corridor + 0.2 -- only the body edges overlap
  -- another level (overpass / underpass): never a threat
  if ego.z and c.z and abs(c.z - ego.z) > 2.5 then return -3 end
  if ttc then
    if ttc < 0.8 then e = e + 1.4 elseif ttc < 1.3 and (need or 0) > 4 then e = e + 1.0 else e = e + 0.2 end
  else
    e = e - 1.0
  end
  if inLane then e = e + 0.6
  elseif graze then
    -- a parked car whose edge pokes into the lane: we'd pass it (a moving one: stay alert)
    if abs(c.v or 0) < 0.6 and abs(ego.yawRate or 0) < 0.15 then e = e - 1.5 end
  else
    -- only the predicted path bends into it (steering wobble over 3 s): weak evidence
    e = e - min(1.2, (abs(lat) - corridor) * 0.8 + 0.3)
    if dot < -0.5 then e = e - 1.2 end -- oncoming car in its own lane: passes us, like every day
    if abs(c.v or 0) < 0.6 then e = e - 0.6 end -- parked beside the road
  end
  -- turning hard (a junction) makes the prediction less sure either way: damp it
  if abs(ego.yawRate or 0) > 0.25 then e = e * 0.7 end
  return e
end

-- Update beliefs. `threat` = { car, ttc, need } for the car the prediction flagged (or nil).
-- Returns the highest belief and that car.
function Brain:update(t, ego, cars, threat)
  local best, bestCar = 0, nil
  local flagged = threat and threat.car
  local seen = self.seen or {}
  for k in pairs(seen) do seen[k] = nil end
  self.seen = seen
  for _, c in ipairs(cars) do
    local id = c.id or c
    seen[id] = true
    local lo = self.lo[id]
    local isFlag = c == flagged
    if lo or isFlag then
      lo = lo or PRIOR
      lo = lo + M.evidence(ego, c, isFlag and threat.ttc or nil, isFlag and threat.need or nil)
      lo = max(LO_MIN, min(LO_MAX, lo))
      if lo <= LO_MIN + 0.01 and not isFlag then self.lo[id] = nil else self.lo[id] = lo end
      local b = 1 / (1 + exp(-lo))
      if b > best then best, bestCar = b, c end
    end
  end
  -- forget cars that left the list
  for id in pairs(self.lo) do if not seen[id] then self.lo[id] = nil end end
  return best, bestCar
end

-- belief (0..1) for one car
function Brain:belief(c)
  local lo = c and self.lo[c.id or c]
  return lo and 1 / (1 + exp(-lo)) or 0
end

function Brain:reset() self.lo = {} end

return M
