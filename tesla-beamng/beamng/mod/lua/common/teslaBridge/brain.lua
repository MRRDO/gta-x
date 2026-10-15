-- teslaBridge/brain.lua
-- A small reasoning layer: instead of reacting to one alarming number (a predicted
-- time-to-collision), it keeps a belief (0..1) that each nearby car is a real threat and
-- updates it every tick from several clues, the way a driver builds confidence:
--   is it in my lane right now? coming at me head-on or just passing in the next lane?
--   on my level (not on a bridge above/below)? has it looked dangerous for a while?
-- Belief is kept as log-odds (add evidence, clamp, decay), so it costs a few multiplies per
-- car per tick: no model files, no allocations in the hot path beyond one table per car.
-- It also reads each car over time, like a driver sizing up the traffic around them:
--   * swerving / erratic: its heading keeps flipping side to side -> give it room, don't sit beside it
--   * cutting in: sliding sideways toward our lane -> treat it as a threat / lead early
--   * hard braker: just braked hard -> keep a longer gap for a while
--   * parked: still for a while; parked properly (lined up with the road, out of the lane)
--     vs badly (angled, poking out, may pull out) -> pass wider and slower
-- Pure Lua (tested in beamng/test/).

local M = {}

local abs, exp, min, max, sqrt, atan2, pi = math.abs, math.exp, math.min, math.max, math.sqrt, math.atan2, math.pi

local PRIOR = -2.0      -- ~12%: most cars around us are not about to hit us
local LO_MIN, LO_MAX = -4, 4
M.BRAKE = 0.85          -- belief needed for emergency braking
M.WARN = 0.6            -- belief needed for a collision warning

local Brain = {}
Brain.__index = Brain

local ERRATIC_WINDOW = 5 -- s: 3+ steering flips inside this = swerving
local HARD_BRAKE = -4    -- m/s^2

function M.new()
  return setmetatable({ lo = {}, tr = {}, seen = {}, trSeen = {} }, Brain)
end

-- Watch every car once per tick (safe to call twice with the same t). Cheap: a few
-- arithmetic ops per car, one small table per car kept between ticks.
function Brain:observe(t, cars)
  if self.obsT == t then return end
  local dt = self.obsT and (t - self.obsT) or nil
  self.obsT = t
  local seen = self.trSeen
  for k in pairs(seen) do seen[k] = nil end
  for _, c in ipairs(cars) do
    local id = c.id or c
    seen[id] = true
    local tr = self.tr[id]
    if not tr then tr = { flips = {}, acc = 0, vx = 0, vy = 0 }; self.tr[id] = tr end
    local h = atan2(c.dy or 0, c.dx or 1)
    local v = c.v or 0
    if dt and dt > 1e-3 and dt < 0.6 and tr.x then
      local dh = h - tr.h
      if dh > pi then dh = dh - 2 * pi elseif dh < -pi then dh = dh + 2 * pi end
      local yaw = dh / dt
      tr.yaw = (tr.yaw or 0) + (yaw - (tr.yaw or 0)) * 0.5
      if abs(v) > 5 and abs(tr.yaw) > 0.06 then
        local sg = tr.yaw > 0 and 1 or -1
        if tr.sign and sg ~= tr.sign then tr.flips[#tr.flips + 1] = t end
        tr.sign = sg
      end
      tr.acc = tr.acc + ((v - tr.v) / dt - tr.acc) * 0.3
      if tr.acc < HARD_BRAKE and abs(tr.v) > 3 then tr.hardBrakeT = t end
      tr.vx = tr.vx + ((c.x - tr.x) / dt - tr.vx) * 0.5
      tr.vy = tr.vy + ((c.y - tr.y) / dt - tr.vy) * 0.5
    end
    local f = tr.flips
    while f[1] and t - f[1] > ERRATIC_WINDOW do table.remove(f, 1) end
    tr.erratic = #f >= 3
    if abs(v) < 0.3 then tr.stillSince = tr.stillSince or t else tr.stillSince = nil end
    tr.x, tr.y, tr.h, tr.v, tr.t = c.x, c.y, h, v, t
  end
  for id in pairs(self.tr) do if not seen[id] then self.tr[id] = nil end end
end

-- What the brain knows about a car (or nil).
function Brain:traits(c) return c and self.tr[c.id or c] end

function Brain:isErratic(c) local tr = self:traits(c); return tr and tr.erratic or false end

function Brain:hardBraked(c, t, within)
  local tr = self:traits(c)
  return tr and tr.hardBrakeT and (t or self.obsT or 0) - tr.hardBrakeT < (within or 8) or false
end

-- still for over 3 s
function Brain:parkedFor(c)
  local tr = self:traits(c)
  return (tr and tr.stillSince) and (self.obsT or 0) - tr.stillSince or 0
end

-- A parked car: 'good' (lined up with the road, not in our way) or 'bad' (angled / poking into
-- the lane: it may pull out or a door may open). dot = its heading vs the road, clearance =
-- metres between it and our car's path (negative = overlapping).
function M.parkedQuality(dot, clearance)
  if abs(dot or 1) < 0.9 then return 'bad' end
  if (clearance or 9) < 0.5 then return 'bad' end
  return 'good'
end

-- Sliding sideways toward our lane ahead of us: seconds until it's in our corridor, or nil.
function Brain:cutInEta(ego, c)
  local tr = self:traits(c)
  if not tr then return nil end
  local lon, lat = M.relative(ego, c)
  if lon < -2 or lon > 45 then return nil end
  local vlat = -tr.vx * ego.hy + tr.vy * ego.hx
  if lat * vlat >= 0 or abs(vlat) < 0.6 then return nil end -- not moving toward us
  local corridor = ((ego.wid or 1.9) + (c.w or 1.9)) * 0.5
  if abs(lat) <= corridor then return 0 end
  local eta = (abs(lat) - corridor) / abs(vlat)
  if eta < 2.5 then return eta end
  return nil
end

-- A car right behind us in our lane, close and for a while (tailgating): the car, and how many
-- seconds behind us it is. Needs us moving (a car close behind at a light is normal).
function Brain:tailgater(ego, cars)
  local v = ego.v or 0
  if v < 8 then self.tailSince = nil; return nil end
  local best, bestGap
  for _, c in ipairs(cars) do
    local lon, lat, dot = M.relative(ego, c)
    if lon < 0 and lon > -22 and dot > 0.7 and abs(lat) < ((ego.wid or 1.9) + (c.w or 1.9)) * 0.5 and abs(ego.z and c.z and c.z - ego.z or 0) < 2.5 then
      local gap = (-lon - ((ego.len or 4.6) + (c.l or 4.6)) * 0.5) / max(v, 1)
      if (c.v or 0) >= v - 1 and gap < 0.9 and (not bestGap or gap < bestGap) then best, bestGap = c, gap end
    end
  end
  if not best then self.tailSince = nil; return nil end
  self.tailSince = self.tailSince or self.obsT or 0
  if (self.obsT or 0) - self.tailSince >= 3 then return best, bestGap end
  return nil
end

-- A pedestrian (small, slow) heading for the road: seconds until they would be in our corridor,
-- or nil. `pathLat` = their signed sideways distance from our path centre, `vLat` = their sideways
-- speed (+ = away from the path's left side, sign matches pathLat).
function M.pedestrianEta(pathLat, vLat, corridor)
  if vLat == nil or abs(vLat) < 0.4 then return nil end
  if pathLat * vLat >= 0 then return nil end            -- walking away
  local d = abs(pathLat) - corridor
  if d <= 0 then return 0 end
  local eta = d / abs(vLat)
  if eta < 4 then return eta end
  return nil
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
function M.evidence(ego, c, ttc, need, br)
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
  -- what we've learned about this car over time
  if br then
    local tr = br.tr[c.id or c]
    if tr then
      if tr.erratic and lon > -5 and lon < 50 and abs(lat) < 7 then e = e + 0.5 end -- unpredictable: believe the prediction more
      if br:cutInEta(ego, c) then e = e + 1.0 end -- coming into our lane: its "beside us" position isn't reassuring
      if inLane and tr.hardBrakeT and (br.obsT or 0) - tr.hardBrakeT < 2 then e = e + 0.5 end
      if not inLane and tr.stillSince and (br.obsT or 0) - tr.stillSince > 3 and abs(dot) > 0.95 then e = e - 0.5 end -- parked properly
    end
  end
  -- turning hard (a junction) makes the prediction less sure either way: damp it
  if abs(ego.yawRate or 0) > 0.25 then e = e * 0.7 end
  return e
end

-- Update beliefs. `threat` = { car, ttc, need } for the car the prediction flagged (or nil).
-- Returns the highest belief and that car.
function Brain:update(t, ego, cars, threat)
  self:observe(t, cars)
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
      lo = lo + M.evidence(ego, c, isFlag and threat.ttc or nil, isFlag and threat.need or nil, self)
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

function Brain:reset() self.lo, self.tr, self.obsT = {}, {}, nil end

return M
