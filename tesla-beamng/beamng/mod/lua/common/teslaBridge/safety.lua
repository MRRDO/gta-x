-- teslaBridge/safety.lua
-- Active safety, on whether or not FSD is driving:
--   Forward Collision Warning, Automatic Emergency Braking,
--   Automatic Collision Evasion (steer around when braking can't avoid it; then FSD
--   keeps driving), Lane Departure Avoidance, Blind Spot warning, Obstacle-Aware
--   Acceleration.
-- Predicts our car on a constant-turn-rate path and other cars at constant velocity,
-- with each car as three circles along its length. Pure Lua (tested in beamng/test/).

local M = {}

local sqrt, abs, min, max, cos, sin, atan2 = math.sqrt, math.abs, math.min, math.max, math.cos, math.sin, math.atan2

local FCW_TIME = { early = 2.8, medium = 2.2, late = 1.6 }

M.DEFAULTS = { fcw = 'medium', aeb = true, evasion = true, lda = true, blindSpot = true, obstacleAware = true }

local Safety = {}
Safety.__index = Safety

function M.new(settings)
  local s = setmetatable({ settings = {}, aebUntil = -1, fcwOn = false, ldaUntil = -1, ldaDir = 0,
    capUntil = -1, prevLat = nil, bsWarnedAt = -1e9, lastThrottle = 0, evadeCooldown = -1e9 }, Safety)
  for k, v in pairs(M.DEFAULTS) do s.settings[k] = v end
  for k, v in pairs(settings or {}) do s.settings[k] = v end
  return s
end

function Safety:configure(settings)
  for k, v in pairs(settings or {}) do self.settings[k] = v end
end

local function circles(x, y, hx, hy, l, w)
  local r = w * 0.5 + 0.15
  local o = l / 3
  return { { x + hx * o, y + hy * o, r }, { x, y, r }, { x - hx * o, y - hy * o, r } }
end

local function hit(ca, cb)
  for _, a in ipairs(ca) do
    for _, b in ipairs(cb) do
      local dx, dy = a[1] - b[1], a[2] - b[2]
      local rr = a[3] + b[3]
      if dx * dx + dy * dy < rr * rr then return true end
    end
  end
  return false
end

-- Our path over the next T seconds: constant speed and turn rate, optional sideways shift
-- (side = +1 left / -1 right, `shift` meters, completed over `tShift` s with a smoothstep).
local function egoAt(ego, t, side, shift, tShift)
  local v = ego.v
  local w = ego.yawRate or 0
  local psi0 = atan2(ego.hy, ego.hx)
  local psi = psi0 + w * t
  local x, y
  if abs(w) < 1e-3 then
    x, y = ego.x + ego.hx * v * t, ego.y + ego.hy * v * t
  else
    x = ego.x + v / w * (sin(psi) - sin(psi0))
    y = ego.y - v / w * (cos(psi) - cos(psi0))
  end
  local hx, hy = cos(psi), sin(psi)
  if side and side ~= 0 then
    local u = min(1, t / tShift)
    local f = u * u * (3 - 2 * u)
    x, y = x - hy * side * shift * f, y + hx * side * shift * f
  end
  return x, y, hx, hy
end

-- First time (s) our predicted path overlaps another car, or nil. Also the car.
function M.timeToCollision(ego, cars, horizon, side, shift, tShift)
  horizon = horizon or 3
  local best, who = nil, nil
  for _, c in ipairs(cars) do
    local dx0, dy0 = c.x - ego.x, c.y - ego.y
    if dx0 * dx0 + dy0 * dy0 < (abs(ego.v) * horizon + abs(c.v) * horizon + 20) ^ 2 then
      local t = 0.1
      while t <= horizon do
        if best and t >= best then break end
        local ex, ey, ehx, ehy = egoAt(ego, t, side, shift, tShift or 2)
        local cx, cy = c.x + c.dx * c.v * t, c.y + c.dy * c.v * t
        if hit(circles(ex, ey, ehx, ehy, ego.len or 4.6, ego.wid or 1.9), circles(cx, cy, c.dx, c.dy, c.l or 4.6, c.w or 1.9)) then
          best, who = t, c
          break
        end
        t = t + 0.1
      end
    end
  end
  return best, who
end

-- Closing speed and gap to a car along our heading.
local function closing(ego, c)
  local rx, ry = c.x - ego.x, c.y - ego.y
  local d = sqrt(rx * rx + ry * ry)
  if d < 1e-3 then return 0, 0 end
  local ux, uy = rx / d, ry / d
  local vr = ego.v * (ego.hx * ux + ego.hy * uy) - c.v * (c.dx * ux + c.dy * uy)
  return vr, max(0.1, d - ((ego.len or 4.6) + (c.l or 4.6)) * 0.5)
end

-- Cars beside/behind us in the next lanes (same direction).
function M.blindSpots(ego, cars)
  local left, right = false, false
  for _, c in ipairs(cars) do
    if c.dx * ego.hx + c.dy * ego.hy > 0.5 then
      local rx, ry = c.x - ego.x, c.y - ego.y
      local lon = rx * ego.hx + ry * ego.hy
      local lat = -rx * ego.hy + ry * ego.hx
      local closingFast = lon < -9 and lon > -30 and (c.v - ego.v) > 4
      if (lon > -9 and lon < 3) or closingFast then
        if lat > 1.4 and lat < 5.5 then left = true end
        if lat < -1.4 and lat > -5.5 then right = true end
      end
    end
  end
  return left, right
end

--- One safety tick.
-- snap.ego = { x, y, hx, hy, v (signed m/s), yawRate, len, wid, steer, throttle, brake, signal, gear, engaged }
-- snap.cars = { { x, y, dx, dy, v, l, w } }
-- ctx = { lane = pathing.locate(...) or nil, rays = { front, rear, left, right } (m) or nil, attention }
-- Returns { fcw, aeb (0..1), evade = { side, shift } | nil, blindLeft, blindRight,
--           lda = { steer, emergency } | nil, throttleCap | nil, ttc, events }
function Safety:tick(t, dt, snap, ctx)
  ctx = ctx or {}
  local st = self.settings
  local ego = snap.ego
  local cars = snap.cars or {}
  local out = { events = {} }
  local fwd = { x = ego.x, y = ego.y, hx = ego.hx, hy = ego.hy, v = ego.v, yawRate = ego.yawRate, len = ego.len, wid = ego.wid }
  local speed = abs(ego.v)

  -- collision prediction (moving forward)
  local ttc, who
  if ego.v > 1 then ttc, who = M.timeToCollision(fwd, cars, 3) end
  out.ttc = ttc
  local need = 0
  if who then
    local vr, gap = closing(ego, who)
    if vr > 0 then need = vr * vr / (2 * max(0.2, gap - 0.5)) end
  end

  -- Forward Collision Warning
  local fcwT = FCW_TIME[st.fcw]
  local fcw = fcwT ~= nil and ttc ~= nil and ttc < fcwT and speed > 2.2 and need > 1.5
  if fcw and not self.fcwOn then out.events[#out.events + 1] = { kind = 'fcw', ttc = ttc } end
  self.fcwOn = fcw
  out.fcw = fcw

  -- Automatic Collision Evasion: braking can't make it -> steer around if a side is clear
  if st.evasion and ttc and ttc < 1.6 and need > 7 and speed > 8 and t > self.evadeCooldown and ctx.lane then
    local L = ctx.lane
    local best
    for _, side in ipairs({ 1, -1 }) do
      local shift = L.laneW or 3.5
      local room = side > 0 and L.roomLeft or L.roomRight
      local rayOk = not ctx.rays or not ctx.rays[side > 0 and 'left' or 'right'] or ctx.rays[side > 0 and 'left' or 'right'] > shift + 1
      if room and room - shift >= (ego.wid or 1.9) * 0.5 + 0.3 and rayOk then
        local tt = M.timeToCollision(fwd, cars, 3, side, shift, 1.8)
        if not tt then
          local score = room - shift + (side < 0 and 0.5 or 0) -- prefer the shoulder over oncoming traffic
          if (side > 0 and L.oncomingLeft) then score = score - 1 end
          if not best or score > best.score then best = { side = side, shift = shift, score = score } end
        end
      end
    end
    if best then
      out.evade = { side = best.side, shift = best.shift }
      self.evadeCooldown = t + 4
      out.events[#out.events + 1] = { kind = 'collisionEvasion', side = best.side > 0 and 'left' or 'right' }
    end
  end

  -- Automatic Emergency Braking
  if st.aeb and not out.evade and ttc and speed > 1 and (ttc < 0.8 or (ttc < 1.3 and need > 4)) then
    if self.aebUntil < t then out.events[#out.events + 1] = { kind = 'aeb', ttc = ttc } end
    self.aebUntil = t + 0.6
  end
  if self.aebUntil >= t then
    out.aeb = speed > 0.3 and 1 or 0.8
  end

  -- Blind spot monitoring
  if st.blindSpot then
    local l, r = M.blindSpots(ego, cars)
    out.blindLeft, out.blindRight = l, r
    local sig = ego.signal
    if ((sig == 'left' and l) or (sig == 'right' and r)) and t - self.bsWarnedAt > 3 then
      self.bsWarnedAt = t
      out.events[#out.events + 1] = { kind = 'blindSpotWarning', side = sig }
    end
  end

  -- Lane Departure Avoidance (manual driving, 40-90 mph, no turn signal)
  if st.lda and not ego.engaged and ctx.lane and speed > 17.9 and speed < 40.2 and not ego.signal then
    local L = ctx.lane
    local lat = L.lat
    local rate = self.prevLat and (lat - self.prevLat) / max(dt, 1e-3) or 0
    local outward = (lat > 0 and rate > 0.12) or (lat < 0 and rate < -0.12)
    if abs(lat) > L.halfW - 0.35 and outward and t > self.ldaUntil + 1.5 then
      local toward = lat > 0 and 'left' or 'right'
      local emergency = (toward == 'left' and L.oncomingLeft) or (toward == 'left' and not L.sameLeft and not L.oncomingLeft)
        or (toward == 'right' and not L.sameRight)
      if (toward == 'left' and out.blindLeft) or (toward == 'right' and out.blindRight) then emergency = true end
      self.ldaUntil = t + 0.8
      self.ldaDir = lat > 0 and 1 or -1
      self.ldaEmergency = emergency
      out.events[#out.events + 1] = { kind = 'laneDeparture', side = toward, emergency = emergency }
    end
    self.prevLat = lat
  else
    self.prevLat = ctx.lane and ctx.lane.lat or nil
  end
  if t <= self.ldaUntil then
    -- positive steering input turns right: push back toward the lane center
    local mag = self.ldaEmergency and 0.07 or 0.035
    out.lda = { steer = self.ldaDir > 0 and mag or -mag, emergency = self.ldaEmergency }
  end

  -- Obstacle-Aware Acceleration: hard throttle at low speed with something right there
  if st.obstacleAware and speed < 3 and (ego.throttle or 0) > 0.5 and (self.lastThrottle or 0) < 0.3 then
    local rev = ego.gear == 'R'
    local hx, hy = rev and -ego.hx or ego.hx, rev and -ego.hy or ego.hy
    local blocked = ctx.rays and ((rev and ctx.rays.rear and ctx.rays.rear < 2.5) or (not rev and ctx.rays.front and ctx.rays.front < 2.5))
    if not blocked then
      for _, c in ipairs(cars) do
        local rx, ry = c.x - ego.x, c.y - ego.y
        local lon = rx * hx + ry * hy
        local lat = abs(-rx * hy + ry * hx)
        if lon > 0 and lon - ((ego.len or 4.6) + (c.l or 4.6)) * 0.5 < 2.5 and lat < ((ego.wid or 1.9) + (c.w or 1.9)) * 0.5 + 0.3 then
          blocked = true
          break
        end
      end
    end
    if blocked then
      self.capUntil = t + 1.5
      out.events[#out.events + 1] = { kind = 'obstacleAwareAccel' }
    end
  end
  self.lastThrottle = ego.throttle or 0
  if t <= self.capUntil then out.throttleCap = 0.08 end

  return out
end

return M
