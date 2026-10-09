-- teslaBridge/score.lua
-- Trip stats, a Tesla-style Safety Score, and the hard-braking hazard lights.
-- Pure Lua (no BeamNG APIs): the GE extension feeds it the car's motion each tick.
--
-- update(dt, s) with s = { v (m/s, forward), yawRate, fsd (bool), gap (s to the car ahead or nil),
--                          moving (bool) }
-- Longitudinal acceleration is derived from v, so callers need no accelerometer.

local M = {}
local abs, max, min = math.abs, math.max, math.min
local Score = {}
Score.__index = Score

local HARD_BRAKE = 4.5     -- m/s^2 (about 0.46 g): the Safety Score's "hard braking"
local HAZARD_BRAKE = 6.5   -- m/s^2 for 0.25 s: emergency braking, hazards flash
local HARD_TURN = 4.0      -- lateral m/s^2
local TAILGATE = 1.0       -- s of gap at speed

function M.new()
  local o = setmetatable({}, Score)
  o:reset()
  return o
end

function Score:reset()
  self.dist, self.fsdDist, self.time = 0, 0, 0
  self.hardBrakes, self.hardTurns, self.takeovers, self.warnings = 0, 0, 0, 0
  self.tailgateT, self.tailgateEligibleT = 0, 0
  self.topSpeed = 0
  self.lastV = nil
  self.smoothA = 0
  self.brakeHold, self.turnHold = 0, 0
  self.inBrake, self.inTurn = false, false
  self.hazard = false
  self.hazardHold, self.resumeT = 0, 0
end

function Score:takeover() self.takeovers = self.takeovers + 1 end
function Score:warning() self.warnings = self.warnings + 1 end

function Score:update(dt, s)
  dt = max(dt, 1e-3)
  local v = s.v or 0
  if self.lastV then
    local a = (v - self.lastV) / dt
    self.smoothA = self.smoothA + (a - self.smoothA) * min(1, dt / 0.15)
  end
  self.lastV = v
  local a = self.smoothA
  if v > 1 then
    local d = v * dt
    self.dist = self.dist + d
    if s.fsd then self.fsdDist = self.fsdDist + d end
  end
  if s.moving ~= false and v > 1 then self.time = self.time + dt end
  self.topSpeed = max(self.topSpeed, v)
  -- hard braking events (one per stop, re-armed when the braking eases)
  if a < -HARD_BRAKE and v > 3 then
    self.brakeHold = self.brakeHold + dt
    if self.brakeHold > 0.2 and not self.inBrake then self.inBrake = true; self.hardBrakes = self.hardBrakes + 1 end
  else
    self.brakeHold = 0
    if a > -HARD_BRAKE * 0.5 then self.inBrake = false end
  end
  -- hard cornering
  local lat = abs((s.yawRate or 0) * v)
  if lat > HARD_TURN and v > 5 then
    self.turnHold = self.turnHold + dt
    if self.turnHold > 0.3 and not self.inTurn then self.inTurn = true; self.hardTurns = self.hardTurns + 1 end
  else
    self.turnHold = 0
    if lat < HARD_TURN * 0.6 then self.inTurn = false end
  end
  -- following too closely
  if s.gap and v > 8 then
    self.tailgateEligibleT = self.tailgateEligibleT + dt
    if s.gap < TAILGATE then self.tailgateT = self.tailgateT + dt end
  end
  -- hazard lights: on in emergency braking, off once the car is moving again (or the driver says so)
  if a < -HAZARD_BRAKE and v > 5 then
    self.hazardHold = self.hazardHold + dt
    if self.hazardHold > 0.25 then self.hazard = true; self.resumeT = 0 end
  else
    self.hazardHold = 0
  end
  if self.hazard and a > 0.5 and v > 3 then
    self.resumeT = self.resumeT + dt
    if self.resumeT > 2 then self.hazard = false end
  elseif self.hazard then
    self.resumeT = 0
  end
end

-- 0..100, higher is safer. Penalties per km driven (so a short trip isn't ruined by one event).
function Score:score()
  local km = max(self.dist / 1000, 0.3)
  local tailPct = self.tailgateEligibleT > 5 and self.tailgateT / self.tailgateEligibleT * 100 or 0
  local p = min(30, self.hardBrakes / km * 6)
    + min(25, tailPct * 0.5)
    + min(15, self.takeovers / km * 3)
    + min(20, self.hardTurns / km * 4)
    + min(10, self.warnings / km * 5)
  return max(0, math.floor(100 - p + 0.5))
end

function Score:summary()
  return {
    km = self.dist / 1000,
    minutes = self.time / 60,
    fsdPercent = self.dist > 0 and self.fsdDist / self.dist * 100 or 0,
    hardBrakes = self.hardBrakes, hardTurns = self.hardTurns, takeovers = self.takeovers, warnings = self.warnings,
    tailgatePercent = self.tailgateEligibleT > 5 and self.tailgateT / self.tailgateEligibleT * 100 or 0,
    topSpeed = self.topSpeed,
    score = self:score(),
  }
end

return M
