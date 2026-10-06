-- teslaBridge/control.lua
-- The autopilot's driver: turns a plan (lane path window + speed caps + stop
-- point + lead car) and the car's sensed motion into steering, throttle and
-- brake inputs. No BeamNG APIs in here, so the tests can drive it against a
-- simple car model (beamng/test/).

local P = require('teslaBridge/pathing')
local Dr = require('teslaBridge/drift')

local M = {}

local abs, min, max, sqrt = math.abs, math.min, math.max, math.sqrt
local clamp = P.clamp

local Driver = {}
Driver.__index = Driver

-- Speed bins for the learned steering gain (full-lock curvature changes with speed).
local BINS = { 6, 12, 20, 30, 1e9 }
local function binOf(v)
  for i, top in ipairs(BINS) do if v < top then return i end end
  return #BINS
end

-- Steering feel: how far ahead it looks, how quickly the wheel may move, how much it smooths
local FEEL = {
  comfort  = { look = 1.2,  rate = 0.75, lpf = 0.16 },
  standard = { look = 1.0,  rate = 1.0,  lpf = 0.08 },
  sport    = { look = 0.85, rate = 1.35, lpf = 0.03 },
}
M.FEEL = FEEL

function M.new(opts)
  opts = opts or {}
  local d = setmetatable({}, Driver)
  d.steerSign = opts.steerSign or 1 -- +1: positive steering input turns right
  d.kmax = {}
  for i = 1, #BINS do d.kmax[i] = opts.kmax or 0.2 end -- curvature (1/m) at full lock
  d.steerRate = opts.steerRate or 1.5 -- full-lock fractions per second
  d.u = 0
  d.speedI = 0
  d.latI = 0
  d.wrongSign = 0
  d.lastMode = nil
  d.path, d.planSeq, d.hint = nil, nil, nil
  return d
end

-- plan = { seq, pts = {x,y,z,...}, vcap = {...}, stopS, lead = {s, v}, hold, throttleMax, gapTime,
--          dir = 1 | -1 (reverse), maxSpeed, urgent (evasive: faster steering), wiggle (low-speed quirk) }
function Driver:setPlan(plan)
  if not plan or not plan.pts or #plan.pts < 6 then self.path = nil; return end
  if plan.seq == self.planSeq then return end
  local pts = {}
  for i = 1, #plan.pts, 3 do
    pts[#pts + 1] = { x = plan.pts[i], y = plan.pts[i + 1], z = plan.pts[i + 2] }
  end
  self.path = { pts = pts, s = P.cumulative(pts), vcap = plan.vcap }
  self.plan = plan
  self.planSeq = plan.seq
  self.hint = nil
end

-- Learn which way the steering goes and how hard, from what the car actually did.
function Driver:learn(dt, v, yawRate, uApplied)
  if v < 3 or abs(uApplied) < 0.08 then return end
  local kAct = yawRate / v
  local g = kAct / uApplied -- expected about -steerSign * kmax
  if abs(g) < 0.01 then return end
  if (g > 0 and self.steerSign > 0) or (g < 0 and self.steerSign < 0) then
    self.wrongSign = self.wrongSign + dt
    if self.wrongSign > 0.4 then
      self.steerSign = -self.steerSign
      self.wrongSign = 0
      self.flipped = (self.flipped or 0) + 1
    end
    return
  end
  self.wrongSign = max(0, self.wrongSign - dt)
  local b = binOf(v)
  local a = clamp(dt / 2.5, 0, 0.2)
  self.kmax[b] = clamp(self.kmax[b] + (abs(g) - self.kmax[b]) * a, 0.03, 0.6)
end

-- sense = { x, y, hx, hy (unit heading), v (m/s, forward), yawRate (rad/s, + = left) }
-- Returns { steer, throttle, brake, parkingbrake, targetSpeed, lat, s, remaining }
function Driver:update(dt, sense, opts)
  opts = opts or {}
  local out = { steer = self.u, throttle = 0, brake = 0, parkingbrake = 0, targetSpeed = 0 }
  local path, plan = self.path, self.plan
  if not path then
    out.brake = 0.3
    return out
  end
  dt = clamp(dt, 0.001, 0.1)
  self.t = (self.t or 0) + dt
  local reverse = plan.dir == -1
  -- in reverse we steer the car's tail: flip the heading and use backward speed
  local hx, hy = sense.hx, sense.hy
  if reverse then hx, hy = -hx, -hy end
  local v = max(0, reverse and -sense.v or sense.v)

  -- learn only from steering we actually applied (not in TACC, where the driver steers)
  if not reverse and not opts.noLearn then self:learn(dt, v, sense.yawRate or 0, self.u) end

  -- where are we on the window?
  local pr = P.project(path, sense.x, sense.y, self.hint, 8, 40)
  if not pr or pr.dist > 12 then pr = P.project(path, sense.x, sense.y) end
  self.hint = pr.i
  local s = pr.s
  out.s, out.lat = s, pr.lat
  out.remaining = path.s[#path.s] - s

  -- steering: pure pursuit + a little lane-centering integral
  local fl = FEEL[plan.feel] or FEEL.standard
  local L = reverse and clamp(2.5 + 0.7 * v, 3, 8) or clamp((2 + (v > 15 and 0.9 or 0.7) * v) * fl.look, 4, 40)
  local k = P.purePursuit(path, s, sense.x, sense.y, hx, hy, L, pr.i)
  if v > 1 and not reverse then
    self.latI = clamp(self.latI + pr.lat * dt, -3, 3)
  end
  if not reverse then k = k - 0.004 * self.latI end
  local kmax = self.kmax[binOf(v)]
  -- backing up, the same curvature needs the opposite steering
  local uWant = clamp((reverse and 1 or -1) * self.steerSign * k / kmax, -1, 1)
  if plan.wiggle and not reverse and v < 8 and v > 0.5 then
    uWant = uWant + 0.018 * math.sin(self.t * 4.1) -- FSD's little low-speed steering fidget
  end
  -- a real car's wheel moves slower the faster it goes
  local rate = plan.urgent and 4 or self.steerRate * fl.rate * (v < 6 and 2 or (v > 20 and 0.75 or 1))
  if not plan.urgent then
    self.uf = self.uf and (self.uf + (uWant - self.uf) * clamp(dt / fl.lpf, 0, 1)) or uWant
    uWant = self.uf
  else
    self.uf = uWant
  end
  -- stopped and staying stopped (light, stop line, hold): keep the wheel where it is instead
  -- of chasing a pure-pursuit point that swings to full lock at zero speed
  local holding = v < 0.5 and (plan.hold or (plan.stopS and plan.stopS - s < 2.5))
  if holding then rate = 0 end
  local du = clamp(uWant - self.u, -rate * dt, rate * dt)
  self.u = self.u + du
  out.steer = self.u

  -- speed target
  local preview = s + v * 0.3
  local vt = plan.vcap and P.valueAt(path, plan.vcap, preview, pr.i) or 10
  if opts.speedBoost and opts.speedBoost > 0 then vt = vt + opts.speedBoost end -- the driver's light accelerator touch (stops and cars ahead still cap it below)
  -- Just engaged above the speed the plan wants (limit, profile): do not stamp on the brake. Hold the speed when it is only a
  -- little over, otherwise come down gently (about 0.6 m/s^2, a lift-off and a bit of regen). Stops, a car ahead, a bend that
  -- is already too fast and any evasive manoeuvre still cap the speed below, so this only softens the speed-limit step.
  if plan.easeId and not reverse and not plan.urgent then
    if self.easeActive ~= plan.easeId and self.easeDone ~= plan.easeId then
      self.easeActive, self.easeV, self.easeT = plan.easeId, v, 0
    end
    if self.easeActive == plan.easeId then
      self.easeT = self.easeT + dt
      local latG = 0
      for i = pr.i, #path.pts - 1 do
        if path.s[i] - s > 40 then break end
        latG = math.max(latG, v * v * abs(P.curvatureAt(path.pts, i, 3)))
      end
      if self.easeV <= vt + 0.05 or latG > 3.5 or self.easeT > 60 then
        self.easeActive, self.easeDone = nil, plan.easeId -- done, or a bend that needs the speed down now: normal control
      else
        local over = self.easeV - vt
        local rate = over <= 2.2 and 0.15 or (self.easeT > 30 and 1.2 or 0.6)
        self.easeV = math.max(vt, self.easeV - rate * dt)
        self.easeV = math.min(self.easeV, math.max(v, vt) + 0.5) -- never above what the car is really doing
        vt = self.easeV
      end
    end
  elseif not plan.easeId then
    self.easeActive = nil
  end
  if plan.stopS then
    local dstop = plan.stopS - s
    -- Tesla-style: start easing off early and brake at a steady, gentle rate (per profile)
    vt = min(vt, sqrt(max(0, 2 * (plan.decel or 2.0) * (dstop - 2))))
    out.stopDist = dstop
  end
  if plan.lead then
    local gap = plan.lead.s - s
    local T = plan.gapTime or 2.0
    local want = max(6, T * v)
    local vl = max(0, plan.lead.v or 0)
    local vlead = vl + 0.35 * (gap - want)
    vlead = min(vlead, sqrt(max(0, vl * vl + 2 * 3.5 * (gap - 5))))
    if gap < 4 then vlead = 0 end
    vt = min(vt, max(0, vlead))
    out.leadGap = gap
  end
  if plan.maxSpeed then vt = min(vt, plan.maxSpeed) end
  if plan.hold or out.remaining < (reverse and 0.3 or 0.5) and not plan.openEnded then vt = 0 end
  vt = max(0, vt)
  -- accelerate like a person driving, not like a launch: the speed we ask for rises at the profile's accel
  -- (m/s^2) instead of jumping to the new target; slowing down is never delayed
  if plan.accel and not plan.urgent then
    local ramp = self.vtRamp or v
    if vt <= ramp then ramp = vt else ramp = min(vt, max(ramp, v) + plan.accel * dt) end
    self.vtRamp = ramp
    vt = ramp
  else
    self.vtRamp = nil
  end
  out.targetSpeed = vt

  -- speed control: PI on speed error, never throttle and brake together
  local tmax = plan.throttleMax or 0.6
  local e = vt - v
  if vt < 0.3 and v < 0.6 then
    self.speedI = 0
    -- soft stop: ease the brake off as the car comes to rest (no lurch), then hold it
    -- (an EV in D creeps at ~0.15 m/s: the old 0.12 + 0.6 v brake could not stop that, and maneuvers never went on to their next leg)
    out.throttle, out.brake = 0, (v > 0.08) and (0.25 + 0.8 * v) or 0.6
    if plan.hold then out.parkingbrake = 1 end
  else
    self.speedI = clamp(self.speedI + e * dt * 0.08, -0.3, 0.4)
    local u = 0.25 * e + self.speedI
    if plan.urgent and e < -1 then u = min(u, e * 0.5) end -- evasive: brake decisively
    -- hard stop needed? required decel beyond comfort -> brake harder
    if plan.stopS then
      local d = plan.stopS - 2 - s
      if d > 0.5 and v > 1 then
        local need = v * v / (2 * d)
        if need > 3 then u = min(u, -need / 6) end
      end
    end
    if u > 0.02 then
      out.throttle = min(u, tmax)
    elseif u < -0.05 then
      out.brake = min(-u * 1.2, 0.8)
      if self.speedI > 0 then self.speedI = 0 end
    end
  end
  -- smooth pedals (jerk limit): effort builds and releases gradually, like FSD. Emergency
  -- braking (urgent plans) and the standstill hold are not slowed down.
  if not plan.urgent and not (vt < 0.3 and v < 0.6) then
    local up = (plan.rise or 1.1)
    local pt, pb = self.pThr or 0, self.pBrk or 0
    local wantThr, wantBrk = out.throttle, out.brake
    -- full brake is ~9 m/s^2, so 0.45/s of brake is ~4 m/s^3 of jerk: what a passenger calls smooth
    out.throttle = max(pt - 2.0 * dt, min(pt + up * dt, wantThr))
    local low = v < 3 and (1 + (3 - v) * 1.2) or 1 -- at walking pace a quick brake is gentle anyway
    out.brake = max(pb - 1.0 * dt, min(pb + 0.42 * up * low * dt, wantBrk))
    -- never both: the pedal we don't want lets go at once
    if wantBrk > 0 then out.throttle = 0 elseif wantThr > 0 then out.brake = 0 end
    -- a hard stop the plan really needs (stop line coming up fast) can still bite
    if plan.stopS and plan.stopS - 2 - s > 0.5 and v > 1 and v * v / (2 * (plan.stopS - 2 - s)) > 3 then
      out.brake = max(out.brake, min(0.8, 0.4 + (v * v / (2 * (plan.stopS - 2 - s)) - 3) * 0.2))
    end
  end
  self.pThr, self.pBrk = out.throttle, out.brake
  -- Furious drift (experimental, only when the planner allows it: furious profile, clear road, no stop coming)
  if plan.drift and not reverse and not plan.urgent then
    local kAhead = 0
    for i = pr.i, #path.pts - 1 do
      local si = path.s[i] - s
      if si > 36 then break end
      if si >= 12 then kAhead = math.max(kAhead, abs(P.curvatureAt(path.pts, i, 3))) end
    end
    self.drift = self.drift or Dr.new()
    local r = self.drift:update(dt, { allowed = true, v = v, kAhead = kAhead, yawRate = sense.yawRate or 0, t = self.t, tune = plan.driftTune })
    if r.pb > 0 then out.parkingbrake = 1 end
    if r.throttleMin > 0 then out.throttle, out.brake = math.max(out.throttle, r.throttleMin), 0 end
    out.driftPhase = r.phase
  elseif self.drift then
    self.drift:reset()
  end
  if opts.steerOnly then out.throttle, out.brake = 0, (vt < v - 3) and min(0.8, (v - vt) * 0.1) or 0 end
  return out
end

M.Driver = Driver
return M
