-- teslaBridge/planner.lua
-- The FSD brain, run by the GE extension at 10 Hz. It knows the road graph, the
-- route, traffic, signals, parking spots and the weather, and each tick hands the
-- car (vehicle extension) a short plan: a lane-shifted path window with speed
-- caps, a stop point, the car ahead, the turn signal and the gear direction.
--
-- Behaviors (FSD v14 flavored):
--   lane keeping on multi-lane roads, lane changes (route, passing, merges, move
--   over, driver's stalk), stop signs with creep/peek and cross-traffic check,
--   unprotected left turns (waits for a gap), nudging around parked cars, going
--   around a blocking stopped car, pulling over for emergency vehicles, caution
--   around school buses, yellow-light hesitation, phantom braking, low-speed
--   wiggle, slowing for rain/fog, parking spot choice + back-in parking, backing
--   out of a spot, 3-point turns, Dumb Summon, Autopark, TACC/Autosteer modes,
--   supervision nags and strikes.
--
-- No BeamNG APIs: GE passes a snapshot of the world every tick (see Planner:tick).

local P = require('teslaBridge/pathing')
local Mv = require('teslaBridge/maneuver')
local Nag = require('teslaBridge/nag')

local M = {}

local sqrt, abs, min, max, floor = math.sqrt, math.abs, math.min, math.max, math.floor
local clamp = P.clamp
local MPH = 0.44704

-- per-profile behavior (speed offset, curves, gap and throttle come from pathing.PROFILES)
M.BEHAVIOR = {
  sloth    = { pass = nil,       gapLeft = 8, keepLeft = false, crossEta = 6 },
  chill    = { pass = 8 * MPH,   gapLeft = 7, keepLeft = false, crossEta = 5.5 },
  standard = { pass = 5 * MPH,   gapLeft = 6, keepLeft = false, crossEta = 5 },
  hurry    = { pass = 3 * MPH,   gapLeft = 5, keepLeft = false, crossEta = 4.5 },
  madmax   = { pass = 2 * MPH,   gapLeft = 4, keepLeft = true,  crossEta = 4 },
}

M.DEFAULT_SETTINGS = {
  quirks = { phantomBraking = true, yellowHesitation = true, wiggle = true, weather = true, creep = true },
  speedOffsetMph = nil,  -- TACC/Autosteer: set speed = limit + offset (nil: profile offset)
  setSpeed = nil,        -- TACC/Autosteer fixed set speed (m/s) when the driver picked one
  followDistance = nil,  -- 1..7 (TACC); nil = profile gap
  laneChanges = true,
  nags = true,
}

local Planner = {}
Planner.__index = Planner

local function smooth(u)
  u = clamp(u, 0, 1)
  return u * u * (3 - 2 * u)
end

local function copy(t)
  local o = {}
  for k, v in pairs(t) do o[k] = type(v) == 'table' and copy(v) or v end
  return o
end

--- opts = { graph, signals = { {id,x,y,z,kind,dirx,diry,prop,get=fn} }, parking = { {x,y,z,dx,dy} }, rng = fn }
function M.new(opts)
  local g = opts.graph
  if g and not g.index then P.buildIndex(g) end
  local self = setmetatable({
    graph = g, signals = opts.signals or {}, parking = opts.parking or {},
    rng = opts.rng or math.random,
    settings = copy(M.DEFAULT_SETTINGS),
    mode = 'off', profile = 'standard', activity = 'drive',
    dest = nil, stops = nil, arrival = nil,
    path = nil, hint = nil, seq = 0,
    lane = { k = 0, change = nil, cooldown = 0 },
    bumps = {},
    stopFsm = {}, cleared = {}, clearedS = -1e9,
    yellow = {},
    nag = Nag.new(),
    t = 0, events = {}, lastDisengage = nil,
    wiggleUntil = -1, phantom = nil, lastOverhead = false,
    arrivalMemory = {},
  }, Planner)
  self.degree = {}
  if g then
    for id, adj in pairs(g.adj) do
      local d = 0
      for _ in pairs(adj) do d = d + 1 end
      self.degree[id] = d
    end
  end
  return self
end

function Planner:emit(kind, fields)
  local ev = fields or {}
  ev.kind = kind
  self.events[#self.events + 1] = ev
end

function Planner:configure(s)
  for k, v in pairs(s or {}) do
    if k == 'quirks' and type(v) == 'table' then
      for qk, qv in pairs(v) do self.settings.quirks[qk] = qv end
    else
      self.settings[k] = v
    end
  end
  self.nag.enabled = self.settings.nags ~= false
end

function Planner:prof() return P.PROFILES[self.profile] or P.PROFILES.standard end

-- Change the speed profile while driving (re-derives the speed caps).
function Planner:setProfile(profile)
  if not P.PROFILES[profile] then return end
  self.profile = profile
  if self.path then
    local prof = self:prof()
    P.speedProfile(self.path, { offset = prof.offset, aLat = prof.aLat, endSpeed = (not self.path.openEnded) and 0 or nil })
    self.builtFor = profile
  end
end
function Planner:beh() return M.BEHAVIOR[self.profile] or M.BEHAVIOR.standard end

---------------------------------------------------------------------------
-- routes
---------------------------------------------------------------------------

local function spotOccupied(spot, cars)
  for _, c in ipairs(cars or {}) do
    if (c.x - spot.x) ^ 2 + (c.y - spot.y) ^ 2 < 2.4 ^ 2 then return true end
  end
  return false
end

-- Best free parking spot near the destination (FSD v14: nearer, and not taken).
function Planner:pickSpot(dest, cars)
  local best, bestScore
  for _, sp in ipairs(self.parking) do
    local d = sqrt((sp.x - dest[1]) ^ 2 + (sp.y - dest[2]) ^ 2)
    if d < 80 and not spotOccupied(sp, cars) then
      local score = d
      if not bestScore or score < bestScore then best, bestScore = sp, score end
    end
  end
  return best
end

-- Extend the path straight back behind its start, so traffic behind us (lane-change
-- checks, emergency vehicles) projects onto it like everything ahead.
local function prependBack(path, len)
  local pts = path.pts
  if #pts < 2 then return end
  local a, b = pts[1], pts[2]
  local dx, dy = a.x - b.x, a.y - b.y
  local l = sqrt(dx * dx + dy * dy)
  if l < 1e-6 then return end
  dx, dy = dx / l, dy / l
  local back = {}
  local n = floor(len / 2)
  for k = n, 1, -1 do
    local p = {}
    for kk, vv in pairs(a) do p[kk] = vv end
    p.x, p.y, p.node, p.back = a.x + dx * 2 * k, a.y + dy * 2 * k, nil, true
    back[#back + 1] = p
  end
  for _, p in ipairs(pts) do back[#back + 1] = p end
  path.pts = back
  path.s = P.cumulative(back)
  local off = n * 2
  for _, t in ipairs(path.turns or {}) do t.s = t.s + off end
  path.backLen = off
end

-- Build self.path from the ego pose (route to dest via stops, or follow the road).
function Planner:planPath(ego, cars)
  local g = self.graph
  if not g then return false, 'map not loaded yet' end
  local hx, hy = ego.hx, ego.hy
  local path
  self.uturnNeeded = false
  if self.dest then
    local legs = {}
    for _, s in ipairs(self.stops or {}) do legs[#legs + 1] = s end
    legs[#legs + 1] = self.dest
    local sx, sy = ego.x, ego.y
    local all
    for li, goal in ipairs(legs) do
      local rt, err = P.route(g, { x = sx, y = sy, hx = hx, hy = hy }, { x = goal[1], y = goal[2] })
      if not rt then return false, err end
      if li == 1 and rt.uturn then self.uturnNeeded = true end
      local leg = P.buildPath(g, rt)
      if not all then all = leg
      else
        local off = all.s[#all.s]
        for i = 2, #leg.pts do all.pts[#all.pts + 1] = leg.pts[i] end
        for _, t in ipairs(leg.turns) do t.s = t.s + off; all.turns[#all.turns + 1] = t end
        all.s = P.cumulative(all.pts)
      end
      local last, prev = all.pts[#all.pts], all.pts[max(1, #all.pts - 1)]
      sx, sy = last.x, last.y
      local dx, dy = last.x - prev.x, last.y - prev.y
      local l = sqrt(dx * dx + dy * dy)
      if l > 1e-6 then hx, hy = dx / l, dy / l end
    end
    path = all
    -- arrival: remember the choice per destination, then pick the move
    local key = floor(self.dest[1] / 25) .. ',' .. floor(self.dest[2] / 25)
    if self.arrival then self.arrivalMemory[key] = self.arrival else self.arrival = self.arrivalMemory[key] end
    local kind = self.arrival or 'auto'
    local spot = (kind == 'Parking Lot' or kind == 'Parking Garage' or kind == 'auto') and self:pickSpot(self.dest, cars) or nil
    path.arrivalKind = 'point'
    if spot then
      local pr = P.project(path, spot.x, spot.y)
      local tan = path.pts[min(#path.pts, pr.i + 1)]
      local tan0 = path.pts[pr.i]
      local rdx, rdy = tan.x - tan0.x, tan.y - tan0.y
      local rl = sqrt(rdx * rdx + rdy * rdy)
      if rl > 1e-6 then rdx, rdy = rdx / rl, rdy / rl end
      -- which way does the spot open? toward the road
      local ox, oy = pr.x - spot.x, pr.y - spot.y
      local ol = sqrt(ox * ox + oy * oy)
      if ol > 1e-6 then ox, oy = ox / ol, oy / ol end
      local perpendicular = abs(ox * rdy - oy * rdx) > 0.8 and ol > 3
      self.spot = spot
      if perpendicular then
        -- FSD backs into perpendicular spots: stop past it, then reverse in
        local q, rev = Mv.backIn({ x = spot.x, y = spot.y, z = spot.z, outx = ox, outy = oy },
          { x = pr.x, y = pr.y, z = spot.z, dx = rdx, dy = rdy }, 6)
        -- cut the route at the spot and run on to q
        local cut = {}
        for i = 1, pr.i do cut[i] = path.pts[i] end
        local base = path.pts[pr.i]
        local nsteps = floor(sqrt((q.x - base.x) ^ 2 + (q.y - base.y) ^ 2) / 2)
        for k = 1, nsteps do
          local u = k / nsteps
          local p = {}
          for kk, vv in pairs(base) do p[kk] = vv end
          p.x, p.y, p.node = base.x + (q.x - base.x) * u, base.y + (q.y - base.y) * u, nil
          p.lim = 4
          cut[#cut + 1] = p
        end
        path.pts = cut
        path.s = P.cumulative(cut)
        path.afterManeuver = { rev }
        path.arrivalKind = 'parking'
      else
        P.appendParking(path, spot.x, spot.y, spot.z, spot.dx, spot.dy)
        path.arrivalKind = 'parking'
      end
    elseif kind ~= 'Driveway' then
      P.pullOver(path, 30)
      path.arrivalKind = 'curb'
    end
  else
    local rt, err = P.followRoad(g, ego.x, ego.y, hx, hy, 1500)
    if not rt then return false, err end
    path = P.buildPath(g, rt)
  end
  prependBack(path, 150)
  local prof = self:prof()
  P.speedProfile(path, { offset = prof.offset, aLat = prof.aLat, endSpeed = (not path.openEnded) and 0 or nil })
  path.limit = {}
  for i, pt in ipairs(path.pts) do path.limit[i] = pt.lim or P.classDefaultSpeed(pt.r, pt.drv) end
  self.path, self.hint = path, nil
  self.cleared, self.clearedS, self.stopFsm = {}, -1e9, {}
  self.lane = { k = 0, change = nil, cooldown = 0 }
  self.bumps = {}
  self.arrived = false
  self.routeDirty = true
  return true
end

-- Route preview for the app (and the parking pin).
function Planner:routeMessage()
  local path = self.path
  if not path then return { t = 'route', points = {}, length = 0 } end
  local pts = {}
  local first = 1
  while path.pts[first] and path.pts[first].back do first = first + 1 end
  local step = max(1, floor((#path.pts - first) / 400))
  for i = first, #path.pts, step do local q = path.pts[i]; pts[#pts + 1] = { q.x, q.y, q.z or 0 } end
  local q = path.pts[#path.pts]
  pts[#pts + 1] = { q.x, q.y, q.z or 0 }
  local msg = { t = 'route', points = pts, length = path.s[#path.s] - (path.backLen or 0), openEnded = path.openEnded or false, arrival = path.arrivalKind }
  if self.spot and path.arrivalKind == 'parking' then msg.parkingPin = { pos = { self.spot.x, self.spot.y, self.spot.z or 0 } } end
  return msg
end

---------------------------------------------------------------------------
-- engage / disengage / commands
---------------------------------------------------------------------------

function Planner:setRoute(dest, stops, arrival)
  self.dest, self.stops, self.arrival = dest, stops, arrival
  self.path = nil
  self.spot = nil
end

function Planner:cancelRoute()
  self.dest, self.stops, self.arrival, self.spot = nil, nil, nil, nil
  self.path = nil
end

-- mode: 'fsd' | 'autosteer' (steer + cruise) | 'tacc' (cruise only). Returns ok, err.
function Planner:engage(mode, profile, ego, cars)
  if self.nag.lockedOut then return false, 'FSD is locked out for this drive (too many strikes)' end
  if profile and P.PROFILES[profile] then self.profile = profile end
  self.mode = mode
  self.activity = 'drive'
  self.maneuver = nil
  self.nag:onDisengage()
  local stationary = abs(ego.v or 0) < 0.5
  if mode ~= 'tacc' and not stationary and self.graph then
    -- rolling through a field / car park far from any road: nothing to follow
    local e, _, ed = P.nearestEdge(self.graph, ego.x, ego.y, nil, nil, 60)
    if not e or ed > (self.graph.nodes[e.a].r or 4) + 8 then
      self.mode = 'off'
      return false, 'not on a road'
    end
  end
  if not self.path or (self.path.openEnded and self.dest) or (not self.path.openEnded and not self.dest) or self.builtFor ~= self.profile then
    local ok, err = self:planPath(ego, cars)
    if not ok then self.mode = 'off'; return false, err end
    self.builtFor = self.profile
  end
  if mode == 'fsd' and stationary and self.graph then
    -- start from Park: back out of a spot, or turn around when the route goes the other way
    local loc = P.locate(self.graph, ego.x, ego.y, ego.hx, ego.hy, 40)
    local e, et, ed = P.nearestEdge(self.graph, ego.x, ego.y, nil, nil, 40)
    if e and ed > (self.graph.nodes[e.a].r or 4) + 1.5 then
      local a, b = self.graph.nodes[e.a], self.graph.nodes[e.b]
      local cx, cy = a.x + (b.x - a.x) * et, a.y + (b.y - a.y) * et
      local dx, dy = b.x - a.x, b.y - a.y
      local l = sqrt(dx * dx + dy * dy)
      dx, dy = dx / l, dy / l
      -- drive the way the route goes (or keep right if no route)
      if self.path and #self.path.pts > 3 then
        local pr = P.project(self.path, cx, cy)
        local i = min(#self.path.pts - 1, pr.i + 2)
        local tx, ty = self.path.pts[i + 1].x - self.path.pts[i].x, self.path.pts[i + 1].y - self.path.pts[i].y
        if tx * dx + ty * dy < 0 then dx, dy = -dx, -dy end
      end
      local r = (a.r + b.r) * 0.5
      local off = P.laneCenter(r, e.ow, 0)
      local road = { x = cx + dy * off, y = cy - dx * off, z = a.z, dx = dx, dy = dy }
      local segs = Mv.backOut(ego, road, 6)
      if segs then
        self:startManeuver(segs, 'drive', 'backOut')
      end
    elseif loc and self.uturnNeeded and not loc.ow and loc.r < 9 then
      -- centerline point: step from us back across our offset from it
      local latRight = P.laneCenter(loc.r, false, loc.lane) - loc.lat
      local road = { cx = ego.x - loc.dy * latRight, cy = ego.y + loc.dx * latRight, dx = loc.dx, dy = loc.dy, r = loc.r }
      local seg = Mv.kTurnNext(ego, road, 6, nil)
      if seg then
        self.kturn = { road = road, lastDir = seg.dir }
        self:startManeuver({ seg }, 'drive', 'kTurn')
      end
    end
  end
  self:emit('engaged', { mode = mode, profile = self.profile })
  return true
end

function Planner:disengage(reason, detail)
  if self.mode == 'off' then return end
  self.mode = 'off'
  self.activity = 'drive'
  self.maneuver = nil
  self.lastDisengage = { reason = reason, time = self.t }
  self.nag:onDisengage()
  self:emit('disengage', { reason = reason, detail = detail })
end

function Planner:startManeuver(segs, after, kind)
  self.activity = 'maneuver'
  self.maneuver = { segs = segs, idx = 1, after = after, kind = kind, dwell = 0 }
  self:emit('maneuver', { what = kind, legs = #segs })
end

-- Dumb Summon: straight forward/back up to 12 m at walking pace.
function Planner:summon(dir, ego)
  if not dir then
    if self.activity == 'summon' then self.activity = 'drive'; self.mode = 'off'; self:emit('summon', { state = 'stopped' }) end
    return true
  end
  local sgn = dir == 'reverse' and -1 or 1
  local pts = {}
  for d = 0, 12, 0.5 do pts[#pts + 1] = { x = ego.x + ego.hx * d * sgn, y = ego.y + ego.hy * d * sgn, z = ego.z or 0 } end
  self.mode = 'fsd'
  self:startManeuver({ { dir = sgn, pts = pts, maxSpeed = 1.0 } }, 'stop', 'summon')
  self.activity = 'summon'
  return true
end

-- Autopark into the nearest free spot beside us.
function Planner:autopark(ego, cars)
  local best, bd
  for _, sp in ipairs(self.parking) do
    local d = sqrt((sp.x - ego.x) ^ 2 + (sp.y - ego.y) ^ 2)
    if d < 25 and not spotOccupied(sp, cars) and (not bd or d < bd) then best, bd = sp, d end
  end
  if not best then return false, 'no free parking spot nearby' end
  local loc = P.locate(self.graph, ego.x, ego.y, ego.hx, ego.hy, 20)
  local rdx, rdy = loc and loc.dx or ego.hx, loc and loc.dy or ego.hy
  -- spot opens toward the road: use our side
  local lat = -(best.x - ego.x) * rdy + (best.y - ego.y) * rdx
  local ox, oy = rdy * (lat > 0 and 1 or -1), -rdx * (lat > 0 and 1 or -1)
  local lon = (best.x - ego.x) * rdx + (best.y - ego.y) * rdy
  local beside = { x = ego.x + rdx * lon, y = ego.y + rdy * lon, z = ego.z }
  local q, rev = Mv.backIn({ x = best.x, y = best.y, z = best.z, outx = ox, outy = oy }, { x = beside.x, y = beside.y, z = beside.z, dx = rdx, dy = rdy }, 6)
  local fwd = {}
  local L = sqrt((q.x - ego.x) ^ 2 + (q.y - ego.y) ^ 2)
  for d = 0, L, 1 do fwd[#fwd + 1] = { x = ego.x + (q.x - ego.x) * d / L, y = ego.y + (q.y - ego.y) * d / L, z = ego.z } end
  fwd[#fwd + 1] = { x = q.x, y = q.y, z = q.z }
  self.mode = 'fsd'
  self.spot = best
  self:startManeuver({ { dir = 1, pts = fwd, maxSpeed = 2 }, rev }, 'park', 'autopark')
  return true
end

-- Automatic Collision Evasion: FSD takes over and swerves to `side` (+1 left / -1 right),
-- then keeps driving. Into a free same-direction lane it's a quick lane change;
-- otherwise a swerve onto the shoulder / empty oncoming lane and back.
function Planner:evade(side, shift, ego, cars)
  if self.mode == 'off' or not self.path then
    self.mode = 'off'
    local ok = self:engage('fsd', self.profile, ego, cars)
    if not ok then return false end
  end
  self.activity = 'drive'
  self.maneuver = nil
  local pr = P.project(self.path, ego.x, ego.y)
  if not pr then return false end
  local v = max(3, ego.v)
  local loc = self.graph and P.locate(self.graph, ego.x, ego.y, ego.hx, ego.hy, 20)
  local k = self.lane.k
  if loc and ((side > 0 and loc.sameLeft) or (side < 0 and loc.sameRight)) then
    self.lane.change = { from = k, to = k + side, reason = 'evasion', phase = 'moving', t = self.t, s0 = pr.s, s1 = pr.s + max(10, v * 1.2) }
  else
    self.bumps[#self.bumps + 1] = { s0 = pr.s + v * 1.0, s1 = pr.s + v * 3.5, off = side * shift, ramp = max(8, v * 0.9), kind = 'evasion' }
  end
  self.urgentUntil = self.t + 2.5
  self:emit('collisionEvasion', { side = side > 0 and 'left' or 'right' })
  return true
end

-- Driver's turn-signal stalk while engaged: lane change that way.
function Planner:requestLaneChange(dir)
  if self.mode == 'off' or self.mode == 'tacc' then return end
  self.driverLaneRequest = { dir = dir, t = self.t }
end

---------------------------------------------------------------------------
-- lanes and shifts along the path
---------------------------------------------------------------------------

function Planner:laneAt(i)
  local p = self.path.pts[i]
  local n, w = P.laneModel(p.r, p.ow)
  return n, w, p
end

-- lane index (float, 0 = rightmost) at arc length s
function Planner:kAt(s)
  local ch = self.lane.change
  local k = self.lane.k
  if ch and ch.phase == 'moving' then
    if s <= ch.s0 then k = ch.from elseif s >= ch.s1 then k = ch.to
    else k = ch.from + (ch.to - ch.from) * smooth((s - ch.s0) / (ch.s1 - ch.s0)) end
  end
  -- lanes are per road: fade back to the right lane through the next turn
  local ts = self.nextTurnS
  if ts and k ~= 0 then
    if s > ts + 15 then k = 0 elseif s > ts - 5 then k = k * (1 - smooth((s - (ts - 5)) / 20)) end
  end
  return k
end

-- sideways offset (m, + = left) of the driven line at arc length s / path index i
function Planner:shiftAt(s, i)
  local _, w = self:laneAt(i)
  local sh = self:kAt(s) * w
  for _, b in ipairs(self.bumps) do
    local ramp = b.ramp or 10
    if s > b.s0 - ramp and s < b.s1 + ramp then
      local f
      if s < b.s0 then f = smooth((s - (b.s0 - ramp)) / ramp)
      elseif s > b.s1 then f = 1 - smooth((s - b.s1) / ramp)
      else f = 1 end
      sh = sh + b.off * f
    end
  end
  return sh
end

---------------------------------------------------------------------------
-- world relative to our path
---------------------------------------------------------------------------

-- cars within reach, with arc length / lateral position on our (unshifted) path window
function Planner:carsOnPath(win, cars, egoPt)
  local out = {}
  for _, c in ipairs(cars) do
    local dx, dy = c.x - egoPt.x, c.y - egoPt.y
    if dx * dx + dy * dy < 220 * 220 then
      local pr = P.project(win, c.x, c.y)
      if pr and pr.dist < 25 then
        local a = win.pts[pr.i]
        local b = win.pts[min(#win.pts, pr.i + 1)]
        local tx, ty = b.x - a.x, b.y - a.y
        local tl = sqrt(tx * tx + ty * ty)
        local dot = tl > 1e-6 and (tx * c.dx + ty * c.dy) / tl or 1
        local _, w = P.laneModel(a.r, a.ow)
        out[#out + 1] = {
          c = c, s = pr.s, lat = pr.lat, dot = dot, vAlong = c.v * dot, i = pr.i + win.i0 - 1,
          lane = floor(pr.lat / w + 0.5), laneW = w,
        }
      end
    end
  end
  return out
end

-- Is target lane k clear for a lane change at our position?
function Planner:laneClear(k, onPath, sCar, v, egoLen)
  for _, o in ipairs(onPath) do
    if o.dot > 0.3 and abs(o.lat - k * o.laneW) < o.laneW * 0.5 + (o.c.w or 1.9) * 0.5 - 0.2 then
      local rel = o.s - sCar
      local half = ((o.c.l or 4.6) + (egoLen or 4.6)) * 0.5
      if rel >= 0 then
        if rel - half < max(8, (v - o.vAlong) * 3 + 6) then return false, o end
      else
        if -rel - half < max(6, (o.vAlong - v) * 3 + 6) then return false, o end
      end
    end
  end
  return true
end

-- Cross traffic (and oncoming, for lefts) heading into junction J within `eta` seconds.
function Planner:junctionBusy(jx, jy, ahx, ahy, cars, eta, includeOncoming)
  for _, c in ipairs(cars) do
    local rx, ry = jx - c.x, jy - c.y
    local d = sqrt(rx * rx + ry * ry)
    if d < 90 then
      local dot = c.dx * ahx + c.dy * ahy
      local approaching = rx * c.dx + ry * c.dy > 0
      local crossing = abs(dot) < 0.75
      local oncoming = dot < -0.75
      if d < 9 and abs(c.v) > 0.8 then return true, c end -- in the box and moving
      if approaching and c.v > 0.8 and (crossing or (includeOncoming and oncoming)) then
        if d / c.v < eta then return true, c end
      end
    end
  end
  return false
end

-- the route junction node nearest to a point (degree >= 3)
function Planner:junctionNear(x, y, maxD)
  local best, bd
  local g = self.graph
  for id, n in pairs(g.nodes) do
    if (self.degree[id] or 0) >= 3 then
      local d = (n.x - x) ^ 2 + (n.y - y) ^ 2
      if d < maxD * maxD and (not bd or d < bd) then best, bd = n, d end
    end
  end
  return best
end

---------------------------------------------------------------------------
-- the tick
---------------------------------------------------------------------------

--- snap = {
--   t, dt,
--   ego = { x, y, z, hx, hy, v (signed, m/s), yawRate, len, wid, gear, engaged, handsNudgeT, attention = {state,t} },
--   cars = { { id, x, y, z, dx, dy, v, l, w, stoppedFor, emergency, schoolBus } },
--   weather = { rain = 0..1, fog = 0..1 }, overhead = bool (bridge above us),
-- }
-- Returns { plan (for the car) | nil, status, events, route (when it changed) | nil, commands = { ... } }
function Planner:tick(snap)
  local t = snap.t
  local dt = snap.dt or 0.1
  self.t = t
  local ego = snap.ego
  local cars = snap.cars or {}
  local out = { commands = {} }

  -- supervision
  local nagOut = self.nag:tick(t, self.mode ~= 'off' and self.mode ~= 'tacc' and self.activity ~= 'summon', self.profile, ego.attention)
  for _, ev in ipairs(nagOut.events) do self:emit(ev.kind, ev) end
  if ego.handsNudgeT and ego.handsNudgeT > (self.lastNudgeSeen or -1) then
    self.lastNudgeSeen = ego.handsNudgeT
    self.nag:nudge(t)
  end

  if self.mode ~= 'off' and (self.activity == 'maneuver' or self.activity == 'summon') then
    self:tickManeuver(ego, cars, out)
    return self:finish(out)
  end

  if self.mode == 'off' or not self.path then
    self:idleStatus(ego, out)
    return self:finish(out)
  end

  local path = self.path
  local pr = P.project(path, ego.x, ego.y, self.hint, 10, 120)
  if not pr or pr.dist > 8 then pr = P.project(path, ego.x, ego.y) end
  if not pr then return self:finish(out) end
  if pr.dist > 15 then
    local ok = self:planPath(ego, cars)
    if not ok then self:disengage('error', 'lost the road') end
    return self:finish(out)
  end
  self.hint = pr.i
  local S = path.s
  local sCar = pr.s
  local remaining = S[#S] - sCar
  local v = max(0, ego.v)
  self.status = {}
  local st = self.status
  st.remaining = (not path.openEnded) and remaining or nil
  st.speedLimit = path.limit[pr.i]

  if path.openEnded and remaining < 400 then
    self:planPath(ego, cars)
    out.route = self:routeMessage()
    return self:finish(out)
  end

  local i0 = max(1, pr.i - 5)
  local i1 = min(#path.pts, pr.i + 160)
  local sBase = S[i0]
  local win = { pts = {}, s = {}, i0 = i0 }
  for i = i0, i1 do win.pts[#win.pts + 1] = path.pts[i]; win.s[#win.s + 1] = S[i] end
  local egoPt = path.pts[pr.i]
  local beh = self:beh()
  local prof = self:prof()
  local fsd = self.mode == 'fsd'
  local steering = self.mode ~= 'tacc'

  -- the next turn (lanes reset through it)
  local nextTurn
  for _, tn in ipairs(path.turns or {}) do
    if tn.s > sCar - 15 then nextTurn = tn; break end
  end
  self.nextTurnS = nextTurn and nextTurn.s or nil
  -- passed a turn: lane index resets
  if self.lastTurnS and sCar > self.lastTurnS + 15 then
    self.lane.k, self.lane.change, self.lastTurnS = 0, nil, nil
  end
  if nextTurn and sCar > nextTurn.s - 5 then self.lastTurnS = nextTurn.s end

  local iL0 = max(1, pr.i - 60)
  local look = { pts = {}, s = {}, i0 = iL0 }
  for i = iL0, i1 do look.pts[#look.pts + 1] = path.pts[i]; look.s[#look.s + 1] = S[i] end
  local onPath = self:carsOnPath(look, cars, egoPt)
  local nHere, wHere = self:laneAt(pr.i)
  local egoLen, egoWid = ego.len or 4.6, ego.wid or 1.9
  local maxSpeed = nil
  local waitingFor = nil
  local signal = nil
  local function cap(vv) maxSpeed = maxSpeed and min(maxSpeed, vv) or vv end

  -- drop finished bumps
  local keep = {}
  for _, b in ipairs(self.bumps) do if sCar < b.s1 + (b.ramp or 10) then keep[#keep + 1] = b end end
  self.bumps = keep

  ---------------------------------------------------------------- obstacles
  st.goAround, st.schoolBus, st.emergency = false, false, nil
  for _, o in ipairs(onPath) do
    local c = o.c
    local rel = o.s - sCar
    local stationary = abs(c.v) < 0.3 and (c.stoppedFor or 0) > 2
    local ourSh = self:shiftAt(o.s, o.i)
    local clearance = abs(o.lat - ourSh) - ((c.w or 1.9) + egoWid) * 0.5
    local want = (c.w or 1.9) < 1.2 and 1.2 or 0.7
    -- school bus: slow way down when passing a stopped one
    if c.schoolBus and abs(c.v) < 0.5 and rel > -10 and rel < 80 and abs(o.lat) < 12 then
      st.schoolBus = true
      if rel < 40 then cap(4.5) end
      if not self.busNoted then self.busNoted = true; self:emit('schoolBus', {}) end
    end
    if fsd and stationary and rel > 5 and rel < 90 and clearance < want and clearance > -((c.w or 1.9) + egoWid) * 0.5 + 0.6 and not c.schoolBus then
      -- partly in our lane: nudge over inside the road
      local side = o.lat < ourSh and 1 or -1 -- car on our right -> move left
      local amount = min(1.2, want - clearance)
      local exists = false
      for _, b in ipairs(self.bumps) do if b.id == c.id then exists = true end end
      if not exists then
        self.bumps[#self.bumps + 1] = { id = c.id, s0 = o.s - (c.l or 4.6) * 0.5 - 4, s1 = o.s + (c.l or 4.6) * 0.5 + 3, off = side * amount, ramp = 12, kind = 'nudge' }
        self:emit('nudge', { side = side > 0 and 'left' or 'right' })
      end
    end
    if fsd and stationary and rel > 0 and rel < 40 and clearance < want and clearance > -((c.w or 1.9) + egoWid) * 0.5 + 0.6 then
      cap(max(6.7, v * 0.8))
    end
  end

  ---------------------------------------------------------------- emergency vehicles
  for _, o in ipairs(onPath) do
    local c = o.c
    if c.emergency then
      local rel = o.s - sCar
      if o.dot > 0.3 and rel < 0 and rel > -150 and abs(o.lat) < 10 then
        -- behind us with lights on: pull over and let it by
        st.emergency = { action = 'pullOver' }
        local _, w = self:laneAt(pr.i)
        local p = path.pts[pr.i]
        local edge = max(0, (p.r or 4) - P.laneCenter(p.r, p.ow, 0) - egoWid * 0.5 - 0.3)
        self.evBump = self.evBump or { s0 = sCar + 5, s1 = sCar + 60, off = -edge, ramp = 10, kind = 'ev' }
        self.evBump.s1 = max(self.evBump.s1, sCar + 20)
        cap(rel > -100 and 0 or 6)
        waitingFor = 'emergencyVehicle'
        self.evUntil = t + 2
        local _ = w
      elseif o.dot < -0.3 and rel > 0 and rel < 150 then
        st.emergency = { action = 'yield' }
        cap(8)
      elseif abs(c.v) < 0.5 and rel > 0 and rel < 120 and o.dot > -0.3 then
        st.emergency = { action = 'moveOver' }
        cap(6.7)
        if nHere > self.lane.k + 1 and not self.lane.change then self.moveOverRequest = true end
      end
    end
  end
  if self.evBump then
    if t > (self.evUntil or 0) then
      local keep2 = {}
      for _, b in ipairs(self.bumps) do if b ~= self.evBump then keep2[#keep2 + 1] = b end end
      self.bumps = keep2
      self.evBump = nil
    else
      local found = false
      for _, b in ipairs(self.bumps) do if b == self.evBump then found = true end end
      if not found then self.bumps[#self.bumps + 1] = self.evBump end
      if not self.evNoted then self.evNoted = true; self:emit('emergencyVehicle', { action = 'pullOver' }) end
    end
  else
    self.evNoted = false
  end

  ---------------------------------------------------------------- lead car (in our driven corridor)
  local lead
  for _, o in ipairs(onPath) do
    local c = o.c
    local rel = o.s - sCar
    if rel > 0 then
      local sh = self:shiftAt(o.s, o.i)
      local overlap = abs(o.lat - sh) < ((c.w or 1.9) + egoWid) * 0.5 + 0.1
      if overlap then
        local vv = o.dot > 0.3 and max(0, o.vAlong) or 0
        local rear = o.s - (c.l or 4.6) * 0.5 - egoLen * 0.5
        if not lead or rear < lead.s then lead = { s = rear, v = vv, o = o } end
      end
    end
  end
  st.leadGap = lead and (lead.s - sCar) or nil

  ---------------------------------------------------------------- go around a blocking stopped car
  if fsd and lead and lead.o.c and abs(lead.o.c.v) < 0.3 and (lead.o.c.stoppedFor or 0) > 5 and nHere == 1 and not path.pts[pr.i].ow
    and lead.s - sCar < 25 and not self.goAround and not lead.o.c.schoolBus then
    local ctlNear = false
    for _, sg in ipairs(self.signals) do
      if (sg.x - lead.o.c.x) ^ 2 + (sg.y - lead.o.c.y) ^ 2 < 40 * 40 then ctlNear = true end
    end
    local queue = false
    for _, o in ipairs(onPath) do
      if o ~= lead.o and o.s > lead.o.s and o.s - lead.o.s < 15 and abs(o.c.v) < 0.3 and abs(o.lat - lead.o.lat) < 2 then queue = true end
    end
    local oncomingClear = true
    for _, o in ipairs(onPath) do
      if o.dot < -0.3 and o.s > sCar - 10 and o.s - sCar < max(60, abs(o.c.v) * 12 + 60) then oncomingClear = false end
    end
    if not ctlNear and not queue and oncomingClear then
      self.goAround = { id = lead.o.c.id, s0 = lead.o.s - (lead.o.c.l or 4.6) * 0.5 - 8, s1 = lead.o.s + (lead.o.c.l or 4.6) * 0.5 + 8, off = wHere + 0.3, ramp = 14, kind = 'goAround' }
      self.bumps[#self.bumps + 1] = self.goAround
      self:emit('goAround', {})
    end
  end
  if self.goAround then
    if sCar > self.goAround.s1 + 14 then self.goAround = nil
    else
      st.goAround = true
      cap(6)
      if sCar < self.goAround.s1 then signal = 'left' end
      -- the blocked car is no longer our lead once we're beside it
      if lead and lead.o.c.id == self.goAround.id then lead = nil; st.leadGap = nil end
    end
  end

  ---------------------------------------------------------------- lane changes
  if steering and self.settings.laneChanges ~= false then
    self:laneChangeLogic(t, sCar, v, pr.i, onPath, lead, nextTurn, egoLen, fsd)
  end
  local ch = self.lane.change
  st.lane = { index = self.lane.k, count = nHere }
  if ch then
    st.lane.changing = { dir = ch.to > ch.from and 'left' or 'right', reason = ch.reason, phase = ch.phase }
    signal = ch.to > ch.from and 'left' or 'right'
  end
  -- during a lane change the lead is whoever is ahead in either lane
  if ch and ch.phase == 'moving' then
    for _, o in ipairs(onPath) do
      local rel = o.s - sCar
      if rel > 0 and o.dot > 0.3 and (o.lane == ch.to or o.lane == ch.from) then
        local rear = o.s - (o.c.l or 4.6) * 0.5 - egoLen * 0.5
        if not lead or rear < lead.s then lead = { s = rear, v = max(0, o.vAlong), o = o } end
      end
    end
  end

  ---------------------------------------------------------------- controls: lights, stop signs
  local stopS, control = nil, nil
  if fsd then
    stopS, control, waitingFor = self:controls(t, win, sCar, v, cars, ego, cap, waitingFor)
  end
  st.control = control
  -- the go-stop-go hesitation after a stop sign
  if self.hesitateUntil and t < self.hesitateUntil and t > self.hesitateUntil - 0.7 then cap(0.5) end

  ---------------------------------------------------------------- unprotected left turns
  if fsd and nextTurn and nextTurn.dir == 'left' and nextTurn.s - sCar < 35 and nextTurn.s - sCar > -2 then
    local jn = nextTurn.node and self.graph.nodes[nextTurn.node]
    if not jn then
      local tp = path.pts[min(#path.pts, pr.i + floor((nextTurn.s - sCar) / 2))]
      jn = self:junctionNear(tp.x, tp.y, 30)
    end
    if jn then
      local a = path.pts[max(1, pr.i - 2)]
      local b = path.pts[min(#path.pts, pr.i + 2)]
      local ahx, ahy = b.x - a.x, b.y - a.y
      local l = sqrt(ahx * ahx + ahy * ahy)
      if l > 1e-6 then ahx, ahy = ahx / l, ahy / l end
      if not self.leftCommitted then
        local busy = self:junctionBusy(jn.x, jn.y, ahx, ahy, cars, beh.gapLeft, true)
        if busy then
          waitingFor = 'gap'
          local waitS = nextTurn.s - 7
          if not stopS or waitS < stopS then stopS = waitS end
          self.leftWaitSince = self.leftWaitSince or t
        elseif nextTurn.s - sCar < 6 then
          -- keep re-checking the gap until we're actually entering the intersection
          self.leftCommitted = true
        end
      end
    end
  elseif not nextTurn or nextTurn.s - sCar > 40 then
    self.leftCommitted, self.leftWaitSince = false, nil
  end
  st.waitingFor = waitingFor

  ---------------------------------------------------------------- quirks
  local q = self.settings.quirks
  -- phantom braking (random on the highway; more likely under bridges)
  if q.phantomBraking and fsd and v > 15 and (not lead or lead.s - sCar > 60) and not ch then
    local p = dt / 240
    if snap.overhead and not self.lastOverhead then p = 0.35 end
    if not self.phantom and self.rng() < p then
      self.phantom = { untilT = t + 1.3, cap = max(8, v - (4 + 3 * self.rng())) }
      self:emit('phantomBrake', {})
    end
  end
  self.lastOverhead = snap.overhead and true or false
  if self.phantom then
    if t > self.phantom.untilT then self.phantom = nil else cap(self.phantom.cap) end
  end
  st.phantomBrake = self.phantom ~= nil
  -- rain / fog
  local wx = snap.weather or {}
  local wxScale = 1
  if q.weather and ((wx.rain or 0) > 0.05 or (wx.fog or 0) > 0.05) then
    local lim = st.speedLimit or 20
    cap(max(6, lim + prof.offset - (wx.rain or 0) * 6 * MPH - (wx.fog or 0) * 10 * MPH))
    wxScale = sqrt(1 - 0.2 * (wx.rain or 0))
    st.weather = { rain = wx.rain or 0, fog = wx.fog or 0 }
  end
  -- low-speed steering fidget after pulling away
  if self.lastV and self.lastV < 0.3 and v > 0.8 then self.wiggleUntil = t + 3 end
  self.lastV = v
  local wiggle = q.wiggle and fsd and (t < self.wiggleUntil or st.creeping)

  ---------------------------------------------------------------- TACC / Autosteer cruise speed
  if not fsd then
    local lim = st.speedLimit or 20
    local set = self.settings.setSpeed
    if not set then
      local off = self.settings.speedOffsetMph and self.settings.speedOffsetMph * MPH or prof.offset
      set = lim + off
    end
    cap(set)
    st.setSpeed = set
  end

  ---------------------------------------------------------------- turn signals
  if not signal and nextTurn and nextTurn.s - sCar < 60 and nextTurn.s - sCar > -5 then signal = nextTurn.dir end
  if not signal and path.arrivalKind == 'curb' and remaining < 45 then signal = 'right' end
  if not signal and st.emergency and st.emergency.action == 'pullOver' then signal = 'right' end
  st.nextTurn = nextTurn and { dir = nextTurn.dir, dist = max(0, nextTurn.s - sCar), road = nextTurn.road or '' } or nil

  ---------------------------------------------------------------- forced stop (ignored nag)
  local hazard = false
  if nagOut.forceStop then
    cap(0)
    hazard = true
    if v < 0.3 then
      for _, ev in ipairs(self.nag:strike()) do self:emit(ev.kind, ev) end
      self:disengage('attention', 'driver did not respond')
      out.commands[#out.commands + 1] = { t = 'signal', dir = 'hazard' }
      return self:finish(out)
    end
  end

  ---------------------------------------------------------------- arrival
  local hold = false
  if not path.openEnded and remaining < 2.5 and v < 0.3 then
    hold = true
    if path.afterManeuver then
      local segs = path.afterManeuver
      path.afterManeuver = nil
      self:startManeuver(segs, 'park', 'backIn')
      return self:finish(out)
    end
    if not self.arrived then
      self.arrived = true
      out.commands[#out.commands + 1] = { t = 'gear', gear = 'P' }
      self:emit('arrived', { detail = path.arrivalKind })
      self:disengage('arrived')
      self.dest, self.path = nil, nil
      out.route = self:routeMessage()
      return self:finish(out)
    end
  end

  ---------------------------------------------------------------- build the window for the car
  local flat, vcap = {}, {}
  for k2 = 1, #win.pts do
    local i = i0 + k2 - 1
    local pt = win.pts[k2]
    local a = path.pts[max(1, i - 1)]
    local b = path.pts[min(#path.pts, i + 1)]
    local tx, ty = b.x - a.x, b.y - a.y
    local tl = sqrt(tx * tx + ty * ty)
    if tl > 1e-6 then tx, ty = tx / tl, ty / tl end
    local sh = self:shiftAt(win.s[k2], i)
    flat[#flat + 1] = pt.x - ty * sh
    flat[#flat + 1] = pt.y + tx * sh
    flat[#flat + 1] = pt.z or 0
    vcap[#vcap + 1] = path.vcap[i] * wxScale
  end
  self.seq = self.seq + 1
  local gap = prof.gap
  if self.mode ~= 'fsd' and self.settings.followDistance then gap = 0.8 + (clamp(self.settings.followDistance, 1, 7) - 1) * 0.35 end
  out.plan = {
    seq = self.seq, pts = flat, vcap = vcap, dir = 1,
    stopS = stopS and (stopS - sBase) or nil,
    lead = lead and { s = lead.s - sBase, v = lead.v } or nil,
    signal = signal or false, hazard = hazard,
    hold = hold, openEnded = path.openEnded or false,
    gapTime = gap, throttleMax = prof.throttle,
    maxSpeed = maxSpeed, wiggle = wiggle or nil,
    urgent = (self.urgentUntil and t < self.urgentUntil) or nil,
    mode = self.mode,
  }
  st.maxSpeed = maxSpeed
  return self:finish(out)
end

-- Where to stop for a sign/light: before the edge of the junction it guards (our nose
-- lands ~0.5 m short of the crossing road), else at the sign itself. Also where to creep to.
function Planner:stopLine(sg, win, sSign)
  self.sigJunction = self.sigJunction or {}
  local j = self.sigJunction[sg.id]
  if j == nil then
    j = self:junctionNear(sg.x, sg.y, 35) or false
    self.sigJunction[sg.id] = j
  end
  if not j then return sSign, sSign + 3 end
  local pr = P.project(win, j.x, j.y)
  if not pr or pr.dist > 12 or pr.s < sSign - 25 or pr.s > sSign + 35 then return sSign, sSign + 3 end
  local edge = pr.s - (j.r or 4)
  -- driver stops its reference point 2 m before stopS; the nose sits ~2.3 m ahead of it
  return min(sSign, edge - 0.8), edge + 0.2, j
end

-- Stop signs (stop, 2 s, creep & peek, check cross traffic) and traffic lights (with
-- yellow-light hesitation). Returns stopS (global arc length), control status, waitingFor.
function Planner:controls(t, win, sCar, v, cars, ego, cap, waitingFor)
  local best
  local egoPt = win.pts[1]
  for _, sg in ipairs(self.signals) do
    local dx, dy = sg.x - egoPt.x, sg.y - egoPt.y
    if dx * dx + dy * dy < 300 * 300 then
      local pr = P.project(win, sg.x, sg.y)
      if pr and pr.s > sCar - 6 then
        local r = (win.pts[pr.i] and win.pts[pr.i].r) or 4
        local okLat = pr.dist < r + 5
        if sg.kind == 'stop' and sg.prop then okLat = pr.lat < 1 and pr.dist < r + 6 end
        if okLat and sg.dirx then
          local a = win.pts[pr.i]; local b = win.pts[min(#win.pts, pr.i + 1)]
          local tx, ty = b.x - a.x, b.y - a.y
          local tl = sqrt(tx * tx + ty * ty)
          if tl > 1e-6 then okLat = abs((tx * sg.dirx + ty * sg.diry) / tl) > 0.6 end
        end
        local fsm = self.stopFsm[sg.id]
        local relevant = okLat and (pr.s > sCar - 3 or (fsm and fsm.state ~= 'done'))
        if relevant and (not best or pr.s < best.s) then best = { sg = sg, s = pr.s } end
      end
    end
  end
  if not best then return nil, nil, waitingFor end
  local sg, sSign = best.sg, best.s
  local s, creepS, jn = self:stopLine(sg, win, sSign)
  local dist = s - sCar
  local control = { kind = sg.kind, dist = dist, red = false }
  local stopS

  if sg.kind == 'stop' then
    if self.cleared[sg.id] or sSign <= self.clearedS + 25 then return nil, control, waitingFor end
    local fsm = self.stopFsm[sg.id]
    if not fsm then fsm = { state = 'approach' }; self.stopFsm[sg.id] = fsm end
    control.red = true
    if fsm.state == 'approach' then
      stopS = s
      if v < 0.3 and dist < 6 then fsm.state, fsm.t = 'stopped', t end
    elseif fsm.state == 'stopped' then
      stopS = s
      if t - fsm.t >= 2 then
        if self.settings.quirks.creep then fsm.state, fsm.t = 'creep', t else fsm.state, fsm.t = 'peek', t end
      end
    elseif fsm.state == 'creep' then
      -- inch forward to see around the corner (nose to the edge of the crossing road)
      stopS = creepS
      cap(1.3)
      self.status.creeping = true
      if not fsm.noted then fsm.noted = true; self:emit('creeping', {}) end
      if v < 0.2 and (creepS - 2) - sCar < 1.2 or t - fsm.t > 8 then fsm.state, fsm.t = 'peek', t end
    elseif fsm.state == 'peek' then
      stopS = max(s, sCar + 1.8)
      local j = jn or self:junctionNear(sg.x, sg.y, 30)
      local busy = false
      if j then
        local busyNow = self:junctionBusy(j.x, j.y, ego.hx, ego.hy, cars, self:beh().crossEta, false)
        busy = busyNow
      end
      if busy then
        waitingFor = 'crossTraffic'
        fsm.clearSince = nil
      else
        fsm.clearSince = fsm.clearSince or t
        if t - fsm.clearSince > 0.6 then
          fsm.state = 'done'
          self.cleared[sg.id] = true
          self.clearedS = sSign
          -- the classic FSD go-stop-go hesitation, now and then
          if self.settings.quirks.creep and self.rng() < 0.15 then self.hesitateUntil = t + 1.5 end
          stopS = nil
        end
      end
    end
    control.dist = dist
    return stopS, control, waitingFor
  end

  -- traffic light
  local stt = sg.get and sg.get() or nil
  control.state = stt
  control.red = stt == 'red'
  if stt == 'red' then
    stopS = s
  elseif stt == 'yellow' then
    local key = sg.id
    local dec = self.yellow[key]
    if not dec then
      local need = v * v / (2 * max(0.5, dist - 2))
      local go
      if need < 2.5 then go = false
      elseif need > 4.5 then go = true
      else go = not (self.settings.quirks.yellowHesitation and self.rng() < 0.5) end
      dec = { go = go, t = t, hesitate = go and self.settings.quirks.yellowHesitation and self.rng() < 0.35 }
      self.yellow[key] = dec
      if dec.hesitate then self:emit('yellowHesitation', {}) end
    end
    if not dec.go then stopS = s end
    if dec.hesitate and t - dec.t < 0.7 then cap(max(3, v - 2)) end
  else
    self.yellow[sg.id] = nil
  end
  return stopS, control, waitingFor
end

function Planner:laneChangeLogic(t, sCar, v, iCar, onPath, lead, nextTurn, egoLen, fsd)
  local lane = self.lane
  local path = self.path
  local n = P.laneModel(path.pts[iCar].r, path.pts[iCar].ow)
  local beh = self:beh()
  if lane.k > n - 1 and not lane.change then
    -- road narrowed under us: merge right now
    lane.change = { from = lane.k, to = n - 1, reason = 'merge', phase = 'signal', t = t }
  end
  local ch = lane.change
  if ch then
    if ch.phase == 'signal' then
      if t - ch.t > 1.2 then
        local ok = self:laneClear(ch.to, onPath, sCar, v, egoLen)
        if ok then
          ch.phase = 'moving'
          ch.s0 = sCar + v * 0.3
          ch.s1 = ch.s0 + clamp(v * 3.2, 20, 70)
          self:emit('laneChange', { dir = ch.to > ch.from and 'left' or 'right', reason = ch.reason })
        elseif t - ch.t > 6 then
          lane.change = nil -- gave up; try again later
          lane.cooldown = t + 4
        end
      end
    elseif ch.phase == 'moving' then
      if sCar > ch.s1 then lane.k = ch.to; lane.change = nil; lane.cooldown = t + 3 end
    end
    return
  end
  if t < lane.cooldown then return end

  -- lanes available ahead (next 150 m) and the lane we must be in for the route
  -- (only up to the next turn: lanes start over on the next road)
  local minN = n
  for i = iCar, min(#path.pts, iCar + 75) do
    if nextTurn and path.s[i] > nextTurn.s - 10 then break end
    local nn = P.laneModel(path.pts[i].r, path.pts[i].ow)
    if nn < minN then minN = nn end
  end
  local want = nil
  local reason
  local prep = nextTurn and nextTurn.s - sCar < max(150, v * 10)
  if prep then
    local need = nextTurn.dir == 'left' and (n - 1) or 0
    if lane.k ~= need then want, reason = need, 'route' end
  end
  if not want and lane.k > minN - 1 then want, reason = minN - 1, 'merge' end
  if not want and self.driverLaneRequest and t - self.driverLaneRequest.t < 1 then
    local d = self.driverLaneRequest.dir == 'left' and 1 or -1
    local k = lane.k + d
    if k >= 0 and k <= minN - 1 then want, reason = k, 'driver' end
    self.driverLaneRequest = nil
  end
  if not want and self.moveOverRequest and lane.k < minN - 1 then want, reason = lane.k + 1, 'moveOver' end
  self.moveOverRequest = nil
  if not want and fsd and not prep then
    -- pass a slower car
    local cruise = path.vcap[iCar] or v
    if beh.pass and lead and lead.s - sCar < 80 and lead.v < cruise - beh.pass and lane.k < minN - 1 then
      want, reason = lane.k + 1, 'pass'
    elseif beh.keepLeft and minN >= 2 and v > 20 and lane.k < minN - 1 and (not nextTurn or nextTurn.s - sCar > 1000) then
      want, reason = lane.k + 1, 'madMax'
    elseif lane.k > 0 and not beh.keepLeft then
      -- back to the right lane once clear (and not passing someone slower there)
      local slowerRight = false
      for _, o in ipairs(onPath) do
        if o.dot > 0.3 and o.lane == lane.k - 1 and o.s > sCar and o.s - sCar < 60 and o.vAlong < v - 1 then slowerRight = true end
      end
      if not slowerRight then want, reason = lane.k - 1, 'return' end
    end
  end
  if want and want ~= lane.k then
    local to = lane.k + (want > lane.k and 1 or -1)
    -- no lane changes right at a junction
    if nextTurn and nextTurn.s - sCar < 25 and reason ~= 'route' then return end
    if self:laneClear(to, onPath, sCar, v, egoLen) or reason == 'merge' or reason == 'route' then
      lane.change = { from = lane.k, to = to, reason = reason, phase = 'signal', t = t }
    end
  end
end

-- Forward/reverse segments (backing out, 3-point turn, back-in parking, summon, autopark).
function Planner:tickManeuver(ego, cars, out)
  local mv = self.maneuver
  if not mv then self.activity = 'drive'; return end
  local seg = mv.segs[mv.idx]
  local segPath = { pts = seg.pts, s = P.cumulative(seg.pts) }
  local pr = P.project(segPath, ego.x, ego.y)
  local remaining = segPath.s[#segPath.s] - (pr and pr.s or 0)
  local moving = abs(ego.v) > 0.15
  self.status = { maneuver = { kind = mv.kind, step = mv.idx, total = #mv.segs, dir = seg.dir }, remaining = nil }
  -- failsafe: way off the maneuver's path (bad steering, pushed by something) -> stop, hand back
  if pr and pr.dist > 3 then
    self.maneuver, self.kturn = nil, nil
    self.activity = 'drive'
    out.commands[#out.commands + 1] = { t = 'gear', gear = 'P' }
    self:emit('error', { detail = mv.kind .. ' went off course, stopped' })
    self:disengage('error', mv.kind .. ' off course')
    return
  end
  -- obstacle in the way (summon / autopark): stop
  local blocked = false
  for _, c in ipairs(cars) do
    local rx, ry = c.x - ego.x, c.y - ego.y
    local hx, hy = seg.dir < 0 and -ego.hx or ego.hx, seg.dir < 0 and -ego.hy or ego.hy
    local lon = rx * hx + ry * hy
    local lat = abs(-rx * hy + ry * hx)
    if lon > 0 and lon - ((ego.len or 4.6) + (c.l or 4.6)) * 0.5 < 1.5 and lat < ((ego.wid or 1.9) + (c.w or 1.9)) * 0.5 + 0.2 then blocked = true end
  end
  if remaining < 0.6 and not moving then
    mv.dwell = mv.dwell + (self.t - (mv.lastT or self.t))
    if mv.dwell > 0.4 then
      if mv.kind == 'kTurn' and self.kturn then
        local nxt = Mv.kTurnNext(ego, self.kturn.road, 6, self.kturn.lastDir)
        if nxt then
          mv.segs[#mv.segs + 1] = nxt
          self.kturn.lastDir = nxt.dir
        else
          self.kturn = nil
        end
      end
      mv.idx = mv.idx + 1
      mv.dwell = 0
      if mv.idx > #mv.segs then
        self.maneuver = nil
        self.activity = 'drive'
        if mv.after == 'park' then
          out.commands[#out.commands + 1] = { t = 'gear', gear = 'P' }
          self:emit('arrived', { detail = 'parking' })
          self:disengage('arrived')
          self.dest, self.path = nil, nil
          out.route = self:routeMessage()
        elseif mv.after == 'stop' then
          out.commands[#out.commands + 1] = { t = 'gear', gear = 'P' }
          self:emit('summon', { state = 'done' })
          self:disengage('summon')
        else
          self:planPath(ego, cars)
          out.route = self:routeMessage()
        end
        mv.lastT = self.t
        return
      end
      seg = mv.segs[mv.idx]
      segPath = { pts = seg.pts, s = P.cumulative(seg.pts) }
    end
  else
    mv.dwell = 0
  end
  mv.lastT = self.t
  local flat, vcap = {}, {}
  for i, p in ipairs(seg.pts) do
    flat[#flat + 1] = p.x; flat[#flat + 1] = p.y; flat[#flat + 1] = p.z or 0
    vcap[i] = seg.maxSpeed or 1.5
  end
  vcap[#vcap] = 0
  self.seq = self.seq + 1
  out.plan = {
    seq = self.seq, pts = flat, vcap = vcap, dir = seg.dir, maxSpeed = blocked and 0 or seg.maxSpeed,
    hold = blocked, openEnded = false, gapTime = 2, throttleMax = 0.35, signal = false, mode = self.mode,
    maneuver = mv.kind,
  }
end

function Planner:idleStatus(ego, out)
  self.status = {}
  if self.path and self.dest then
    local pr = P.project(self.path, ego.x, ego.y, self.hint, 10, 120) or P.project(self.path, ego.x, ego.y)
    if pr then self.hint = pr.i; self.status.remaining = self.path.s[#self.path.s] - pr.s; self.status.speedLimit = self.path.limit[pr.i] end
  end
  local _ = out
end

function Planner:finish(out)
  out.events = self.events
  self.events = {}
  local st = self.status or {}
  st.mode = self.mode
  st.profile = self.profile
  st.activity = self.activity
  st.nag = self.nag:status()
  st.lastDisengage = self.lastDisengage
  if self.routeDirty then out.route = out.route or self:routeMessage(); self.routeDirty = false end
  out.status = st
  return out
end

return M
