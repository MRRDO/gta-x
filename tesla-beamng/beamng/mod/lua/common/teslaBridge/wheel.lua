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

-- How far the wheel may be pushed off FSD's angle (raw axis, 1 = full lock) before it counts as
-- taking over. A light touch just nudges the car (like the gas pedal speeds it up); a firm turn,
-- enough to move the car a lot, disengages.
-- Road feel: a texture on top of the spring so the wheel isn't dead while FSD drives.
-- hp = vertical acceleration with the slow part removed (g), v = speed (m/s), t = time (s),
-- gain 0..2. Returns a torque offset as a fraction of full force (bounded by 0.35 * gain).
function M.roadTexture(hp, v, t, gain)
  gain = clamp(gain or 1, 0, 2)
  if gain <= 0 then return 0 end
  local n = math.sin(t * 47) * 0.6 + math.sin(t * 83 + 1.3) * 0.4
  local speedK = min(1, max(0, v) / 25)
  local bump = min(1, abs(hp or 0) / 0.5)
  local tex = 0.06 * speedK * n + 0.25 * bump * (0.5 + 0.5 * n)
  return clamp(tex * gain, -0.35 * gain, 0.35 * gain) * ((hp or 0) < 0 and -1 or 1)
end

M.TAKEOVER = { light = 0.09, normal = 0.14, firm = 0.25 }
function M.takeoverLimit(level) return M.TAKEOVER[level] or M.TAKEOVER.normal end

-- Steering the driver adds on top of FSD's while they lean on the wheel lightly.
function M.nudgeBias(dev, limit)
  local a = abs(dev or 0)
  if a < 0.04 then return 0 end
  local b = min(0.12, (a - 0.04) * 0.5)
  if a > (limit or 0.25) then return 0 end -- past the limit it's a takeover, not a nudge
  return dev > 0 and b or -b
end

function M.new(opts)
  opts = opts or {}
  return setmetatable({
    sign = opts.sign or 1,     -- flips itself if the wheel runs away from the target
    confirmed = false,         -- sign proven by the wheel converging
    flips = 0,
    disabled = false,
    stiffness = opts.stiffness or 0.09, -- raw error that asks for full force
    damping = opts.damping or 0.28,     -- seconds (Kd / Kp)
    ramp = 0, vel = 0, lastPos = nil,
    tf = nil, fPrev = 0, integ = 0,     -- smoothed target, last force, friction term
    wrongT = 0, goodT = 0, gripT = 0,
    gripScale = opts.gripScale or 1,    -- scales how far off target counts as gripping (M.takeoverLimit / 0.15)
  }, Spring)
end

function Spring:reset()
  self.ramp, self.vel, self.lastPos = 0, 0, nil
  self.tf, self.fPrev, self.integ = nil, 0, 0
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
  local cap = fcap * clamp(strength or 1, 0, 2)
  -- smooth the target (FSD's steering comes in steps): no jerks for the motor to chase
  -- start from where the wheel IS (no snap to FSD's angle when it takes over) and move the target at a sane speed
  self.tf = self.tf or pos
  local want = self.tf + (target - self.tf) * clamp(dt / 0.06, 0, 1)
  self.tf = self.tf + clamp(want - self.tf, -6 * dt, 6 * dt)
  local e = self.tf - pos
  local kp = cap / self.stiffness
  -- a hair of deadband so the motor doesn't buzz around the target
  local eUse = e
  local DB = 0.004
  if abs(eUse) < DB then eUse = 0 else eUse = eUse - (eUse > 0 and DB or -DB) end
  -- friction: a small steady error with the wheel not moving builds extra push (wheels
  -- with a stiff rim otherwise stop a few degrees short)
  if abs(e) > 0.01 and abs(self.vel) < 0.05 then
    self.integ = clamp(self.integ + e * dt * 4, -0.3, 0.3)
  else
    self.integ = self.integ * max(0, 1 - dt * 4)
  end
  local f = kp * eUse - kp * self.damping * self.vel + self.integ * cap
  -- the spring gives way the further you pull it: overtaking by hand shouldn't be a wrestling match
  local capUse = cap * clamp(1 - (abs(e) - 0.2) * 2, 0.5, 1)
  f = clamp(f, -capUse, capUse) * self.ramp
  -- chatter guard: a force that keeps flipping sign is the wheel shaking; back off for a moment
  self.chT = (self.chT or 0) + dt
  local sg = f > 0.15 * cap and 1 or (f < -0.15 * cap and -1 or 0)
  if sg ~= 0 and self.lastSg and sg ~= self.lastSg then self.flips8 = (self.flips8 or 0) + 1 end
  if sg ~= 0 then self.lastSg = sg end
  if self.chT >= 1 then
    if (self.flips8 or 0) >= 6 then self.soft = 0.35; self.softUntil = 2 end
    self.chT, self.flips8 = 0, 0
  end
  if self.softUntil and self.softUntil > 0 then
    self.softUntil = self.softUntil - dt
    f = f * (self.soft or 1)
    if self.softUntil <= 0 then self.soft, self.softUntil = 1, nil end
  end
  -- slew limit: full swing in ~0.15 s, not in one frame (that's the shake)
  local maxStep = cap * dt / 0.03
  f = clamp(f, self.fPrev - maxStep, self.fPrev + maxStep)
  self.fPrev = f
  local converging = e * self.vel > 0 -- |target - pos| shrinking

  -- direction check: pushing hard but the wheel keeps speeding up away from the
  -- target. After a flip, wait until the wheel's momentum is gone before judging again.
  self.flipHold = max(0, (self.flipHold or 0) - dt)
  if not self.confirmed then
    local speedingAway = not converging and abs(self.vel) > 0.4 and abs(self.vel) >= prevSpeed - 1e-3
    if self.flipHold <= 0 and self.ramp >= 1 and abs(e) > 0.15 and abs(f) > 0.4 * cap and speedingAway then
      self.wrongT = self.wrongT + dt
      if self.wrongT > 0.25 then
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

  -- grip: far from target, force saturated, not closing in -> the driver is holding it.
  -- Also resisting: the spring pushes hard but the wheel stays still (held against FSD);
  -- a wheel that's just lagging in a quick turn is moving toward the target, so it's not that.
  local gs = self.gripScale or 1
  local held = abs(e) > 0.1 * gs and abs(f) > 0.6 * capUse and not (converging and abs(self.vel) > 0.1)
  local resisting = abs(e) > 0.06 * gs and abs(f) > 0.5 * capUse and abs(self.vel) < 0.05
  if self.ramp >= 1 and (held or resisting) then
    self.gripT = self.gripT + dt
  else
    self.gripT = max(0, self.gripT - dt * 2)
  end
  return self.sign * f, self.gripT > (resisting and not held and 0.45 or 0.35), e
end

M.Spring = Spring
return M
