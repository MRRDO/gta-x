-- teslaBridge/wheel.lua
-- Position spring for a force-feedback wheel (e.g. Logitech G29): while the
-- autopilot drives, push the physical wheel to where the car's steering is.
--   force = sign * (Kp * (target - pos) - Kd * velocity), clamped, ramped in.
-- Positions are the wheel's raw axis value (-1..1). Force is in the game's FFB
-- units, capped at `fcap`. No BeamNG APIs here (tested in beamng/test/).
--
-- Also answers "is the driver holding the wheel?": the wheel stays far from
-- the target and isn't moving toward it -> grip takeover.

local M = {}

local abs, min, max = math.abs, math.min, math.max
local function clamp(v, lo, hi) if v < lo then return lo elseif v > hi then return hi end return v end

local Spring = {}
Spring.__index = Spring

function M.new(opts)
  opts = opts or {}
  return setmetatable({
    sign = opts.sign or 1,     -- flips itself if the wheel runs away from the target
    confirmed = false,         -- sign proven by the wheel converging
    flips = 0,
    disabled = false,
    stiffness = opts.stiffness or 0.12, -- raw error that asks for full force
    damping = opts.damping or 0.2,      -- seconds (Kd / Kp)
    ramp = 0, vel = 0, lastPos = nil,
    wrongT = 0, goodT = 0, gripT = 0,
  }, Spring)
end

function Spring:reset()
  self.ramp, self.vel, self.lastPos = 0, 0, nil
  self.wrongT, self.gripT, self.goodT = 0, 0, 0
end

-- dt s, target/pos raw axis units, fcap max force. Returns force, gripping (bool), err.
function Spring:update(dt, target, pos, fcap, strength)
  if self.disabled or dt <= 0 then return 0, false, 0 end
  target = clamp(target, -1, 1)
  local prevSpeed = abs(self.vel)
  if self.lastPos then
    local v = (pos - self.lastPos) / dt
    local a = clamp(dt / 0.03, 0, 1)
    self.vel = self.vel + (v - self.vel) * a
  end
  self.lastPos = pos
  self.ramp = min(1, self.ramp + dt / 0.8)
  local cap = fcap * clamp(strength or 1, 0, 1)
  local e = target - pos
  local kp = cap / self.stiffness
  local f = kp * e - kp * self.damping * self.vel
  f = clamp(f, -cap, cap) * self.ramp
  local converging = e * self.vel > 0 -- |target - pos| shrinking

  -- direction check: pushing hard but the wheel keeps speeding up away from the
  -- target. After a flip, wait until the wheel's momentum is gone before judging again.
  self.flipHold = max(0, (self.flipHold or 0) - dt)
  if not self.confirmed then
    local speedingAway = not converging and abs(self.vel) > 0.4 and abs(self.vel) >= prevSpeed - 1e-3
    if self.flipHold <= 0 and abs(e) > 0.04 and abs(f) > 0.4 * cap and speedingAway then
      self.wrongT = self.wrongT + dt
      if self.wrongT > 0.12 then
        self.sign = -self.sign
        self.flips = self.flips + 1
        self.wrongT, self.ramp, self.flipHold = 0, 0.3, 0.6
        if self.flips > 3 then self.disabled = true end
      end
    else
      self.wrongT = max(0, self.wrongT - dt)
    end
    if converging and abs(self.vel) > 0.2 then
      self.goodT = self.goodT + dt
      if self.goodT > 0.5 then self.confirmed = true end
    end
  end

  -- grip: far from target, force saturated, not closing in -> the driver is holding it
  if self.ramp >= 1 and abs(e) > 0.1 and abs(f) > 0.6 * cap and not (converging and abs(self.vel) > 0.1) then
    self.gripT = self.gripT + dt
  else
    self.gripT = max(0, self.gripT - dt * 2)
  end
  return self.sign * f, self.gripT > 0.35, e
end

M.Spring = Spring
return M
