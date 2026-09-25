-- teslaBridge/control.lua
-- The autopilot's driver: turns a plan (lane path window + speed caps + stop
-- point + lead car) and the car's sensed motion into steering, throttle and
-- brake inputs. No BeamNG APIs in here, so the tests can drive it against a
-- simple car model (beamng/test/).

local P = require('teslaBridge/pathing')

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
  local L = reverse and clamp(2.5 + 0.7 * v, 3, 8) or clamp(2 + 0.7 * v, 4, 30)
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
  local rate = plan.urgent and 4 or self.steerRate * (v < 6 and 2 or 1)
  local du = clamp(uWant - self.u, -rate * dt, rate * dt)
  self.u = self.u + du
  out.steer = self.u

  -- speed target
  local preview = s + v * 0.3
  local vt = plan.vcap and P.valueAt(path, plan.vcap, preview, pr.i) or 10
  if plan.stopS then
    local dstop = plan.stopS - s
    vt = min(vt, sqrt(max(0, 2 * 2.5 * (dstop - 2))))
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
  out.targetSpeed = vt

  -- speed control: PI on speed error, never throttle and brake together
  local tmax = plan.throttleMax or 0.6
  local e = vt - v
  if vt < 0.3 and v < 0.6 then
    self.speedI = 0
    out.throttle, out.brake = 0, 0.5
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
  if opts.steerOnly then out.throttle, out.brake = 0, (vt < v - 3) and min(0.8, (v - vt) * 0.1) or 0 end
  return out
end

M.Driver = Driver
return M
