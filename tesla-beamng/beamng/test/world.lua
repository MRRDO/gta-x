-- A small closed-loop world for testing the FSD brain without BeamNG:
-- road graph + planner (10 Hz) + safety (20 Hz) + driver (60 Hz) + a bicycle-model
-- car + scripted traffic. Used by test_behaviors.lua.

package.path = 'beamng/mod/lua/common/?.lua;' .. package.path
local P = require('teslaBridge/pathing')
local C = require('teslaBridge/control')
local Pl = require('teslaBridge/planner')
local S = require('teslaBridge/safety')

local W = {}
W.__index = W

local sqrt, cos, sin, atan2, abs, min, max = math.sqrt, math.cos, math.sin, math.atan2, math.abs, math.min, math.max

function W.new(o)
  local g = P.buildGraph(o.nodes)
  local w = setmetatable({}, W)
  w.g = g
  w.planner = Pl.new({ graph = g, signals = o.signals or {}, parking = o.parking or {}, rng = o.rng or function() return 0.99 end })
  w.planner:configure(o.settings or { quirks = { phantomBraking = false, yellowHesitation = false, wiggle = false, weather = true, creep = true } })
  w.safety = S.new(o.safety)
  w.driver = C.new()
  local e = o.ego or { x = 0, y = 0, psi = 0 }
  w.ego = { x = e.x, y = e.y, psi = e.psi, v = e.v or 0, delta = 0, wb = 2.9, ref = 1.4, len = 4.6, wid = 1.9, gear = e.gear or 'D' }
  w.cars = {}
  w.t = 0
  w.events = {}
  w.minGap = 1e9
  w.collided = false
  w.trace = {}
  w.attention = nil
  w.weather = o.weather
  w.nextPlan, w.nextSafety = 0, 0
  w.aeb, w.lda, w.cap = 0, nil, nil
  return w
end

-- car = { id, pts = {{x,y}...} (polyline to follow) | x, y, dx, dy (parked), speed, l, w,
--         emergency, schoolBus, startT, speedFn(t, car) }
function W:addCar(c)
  c.l, c.w = c.l or 4.6, c.w or 1.9
  c.v = 0
  c.stoppedFor = 0
  if c.pts then
    c.s = c.s0 or 0
    c.cum = P.cumulative(c.pts)
    self:placeCar(c)
  else
    c.dx, c.dy = c.dx or 1, c.dy or 0
  end
  self.cars[#self.cars + 1] = c
  return c
end

function W:placeCar(c)
  local path = { pts = c.pts, s = c.cum }
  local x, y, _, i = P.pointAt(path, c.s)
  local a, b = c.pts[i], c.pts[min(#c.pts, i + 1)]
  local dx, dy = b.x - a.x, b.y - a.y
  local l = sqrt(dx * dx + dy * dy)
  if l > 1e-6 then c.dx, c.dy = dx / l, dy / l end
  c.x, c.y = x, y
end

function W:refPos()
  local e = self.ego
  return e.x + cos(e.psi) * e.ref, e.y + sin(e.psi) * e.ref
end

function W:snapshot()
  local e = self.ego
  local rx, ry = self:refPos()
  local cars = {}
  for _, c in ipairs(self.cars) do
    cars[#cars + 1] = { id = c.id, x = c.x, y = c.y, z = 0, dx = c.dx, dy = c.dy, v = c.v, l = c.l, w = c.w,
      stoppedFor = c.stoppedFor, emergency = c.emergency, schoolBus = c.schoolBus }
  end
  return {
    t = self.t, dt = 0.1,
    ego = { x = rx, y = ry, z = 0, hx = cos(e.psi), hy = sin(e.psi), v = e.v, yawRate = e.v * math.tan(e.delta) / e.wb,
      len = e.len, wid = e.wid, gear = e.gear, attention = self.attention or { state = 'ok', t = self.t }, handsNudgeT = self.handsNudgeT,
      throttle = self.manualThrottle or 0, signal = self.manualSignal, engaged = self.planner.mode ~= 'off' },
    cars = cars, weather = self.weather, overhead = self.overhead,
  }
end

function W:log(kind, ev)
  self.events[#self.events + 1] = { t = self.t, kind = kind, ev = ev }
end

function W:saw(kind, pred)
  for _, e in ipairs(self.events) do if e.kind == kind and (not pred or pred(e.ev, e.t)) then return e.t, e.ev end end
end

function W:step(dt)
  local e = self.ego
  self.t = self.t + dt
  local snap
  -- planner at 10 Hz
  if self.t >= self.nextPlan then
    self.nextPlan = self.t + 0.1
    snap = self:snapshot()
    local out = self.planner:tick(snap)
    for _, ev in ipairs(out.events) do self:log(ev.kind, ev) end
    for _, cmd in ipairs(out.commands) do
      if cmd.t == 'gear' then e.gear = cmd.gear end
    end
    self.status = out.status
    if out.plan then self.driver:setPlan(out.plan); self.plan = out.plan else self.plan = nil end
  end
  -- safety at 20 Hz
  if self.t >= self.nextSafety then
    self.nextSafety = self.t + 0.05
    snap = snap or self:snapshot()
    local lane = P.locate(self.g, snap.ego.x, snap.ego.y, snap.ego.hx, snap.ego.hy, 20)
    local so = self.safety:tick(self.t, 0.05, snap, { lane = lane })
    for _, ev in ipairs(so.events) do self:log(ev.kind, ev) end
    self.aeb, self.lda, self.cap = so.aeb or 0, so.lda, so.throttleCap
    self.blindLeft, self.blindRight = so.blindLeft, so.blindRight
    if so.evade then
      self.planner:evade(so.evade.side, so.evade.shift, snap.ego, snap.cars)
      self.nextPlan = 0
    end
  end
  -- who drives?
  local steer, throttle, brake, pb = 0, 0, 0, 0
  local engaged = self.planner.mode ~= 'off' and self.plan
  local rx, ry = self:refPos()
  if engaged then
    local out = self.driver:update(dt, { x = rx, y = ry, hx = cos(e.psi), hy = sin(e.psi), v = e.v, yawRate = e.v * math.tan(e.delta) / e.wb })
    steer, throttle, brake, pb = out.steer, out.throttle, out.brake, out.parkingbrake or 0
    self.lastOut = out
    local wantR = self.plan.dir == -1
    if wantR and e.gear ~= 'R' and abs(e.v) < 0.3 then e.gear = 'R' end
    if not wantR and e.gear == 'R' and abs(e.v) < 0.3 then e.gear = 'D' end
    if e.gear == 'P' and self.plan and not self.plan.hold and abs(e.v) < 0.3 then e.gear = wantR and 'R' or 'D' end
  elseif self.manual then
    steer, throttle, brake = self.manual(self)
    self.manualThrottle = throttle
  end
  if self.lda and not engaged then steer = steer + self.lda.steer end
  if self.cap then throttle = min(throttle, self.cap) end
  if (self.aeb or 0) > 0 then throttle, brake = 0, max(brake, self.aeb) end
  -- actuators + bicycle
  local want = -steer * math.rad(34)
  local rate = math.rad(90) * dt
  e.delta = e.delta + max(-rate, min(rate, want - e.delta))
  local dir = e.gear == 'D' and 1 or (e.gear == 'R' and -1 or 0)
  local acc = 3.5 * throttle * dir - 0.05 * e.v
  local nv = e.v + acc * dt
  local stop = 9 * brake + 6 * pb
  if nv > 0 then nv = max(0, nv - stop * dt) elseif nv < 0 then nv = min(0, nv + stop * dt) end
  if e.gear == 'P' then nv = 0 end
  e.v = nv
  e.psi = e.psi + e.v * math.tan(e.delta) / e.wb * dt
  e.x = e.x + cos(e.psi) * e.v * dt
  e.y = e.y + sin(e.psi) * e.v * dt
  -- traffic
  for _, c in ipairs(self.cars) do
    if c.pts then
      local sp = c.speedFn and c.speedFn(self.t, c, self) or ((not c.startT or self.t >= c.startT) and (c.speed or 0) or 0)
      c.v = sp
      c.s = min(c.cum[#c.cum], c.s + sp * dt)
      if c.s >= c.cum[#c.cum] then c.v = 0 end
      self:placeCar(c)
    end
    if abs(c.v) < 0.3 then c.stoppedFor = c.stoppedFor + dt else c.stoppedFor = 0 end
    -- gap to us (center distance minus half-lengths, rough)
    local d = sqrt((c.x - rx) ^ 2 + (c.y - ry) ^ 2)
    local lat = abs(-(c.x - rx) * sin(e.psi) + (c.y - ry) * cos(e.psi))
    local lon = abs((c.x - rx) * cos(e.psi) + (c.y - ry) * sin(e.psi))
    if lat < (c.w + e.wid) * 0.5 and lon < (c.l + e.len) * 0.5 then self.collided = true; self.collidedWith = c.id end
    self.minGap = min(self.minGap, d)
  end
  self.trace[#self.trace + 1] = { t = self.t, x = rx, y = ry, v = e.v, psi = e.psi }
end

function W:run(seconds, untilFn)
  local dt = 1 / 60
  local t1 = self.t + seconds
  while self.t < t1 do
    self:step(dt)
    if untilFn and untilFn(self) then return true end
  end
  return false
end

function W:engage(mode, profile)
  local snap = self:snapshot()
  local ok, err = self.planner:engage(mode, profile, snap.ego, snap.cars)
  self.nextPlan = 0
  return ok, err
end

return W
