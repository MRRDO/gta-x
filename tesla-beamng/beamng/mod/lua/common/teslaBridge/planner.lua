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
local Brain = require('teslaBridge/brain')
local Judge = require('teslaBridge/judge')
local Policy = require('teslaBridge/policy')
local Lidar = require('teslaBridge/lidar')

local M = {}

local sqrt, abs, min, max, floor = math.sqrt, math.abs, math.min, math.max, math.floor
local clamp = P.clamp
local MPH = 0.44704

-- per-profile behavior (speed offset, curves, gap and throttle come from pathing.PROFILES)
M.BEHAVIOR = {
  -- leftAbove: at this speed (m/s) it lives in the fast (left) lane; cut: scale on the gap it needs
  -- to change lanes (1 = normal); signalDelay: seconds of blinker before it moves over
  sloth    = { pass = nil,       gapLeft = 8, keepLeft = false, crossEta = 6,   cut = 1.2,  signalDelay = 3.0 },
  chill    = { pass = 8 * MPH,   gapLeft = 7, keepLeft = false, crossEta = 5.5, cut = 1.1,  signalDelay = 3.0 },
  standard = { pass = 5 * MPH,   gapLeft = 6, keepLeft = false, crossEta = 5,   cut = 1,    signalDelay = 3.0 },
  hurry    = { pass = 3 * MPH,   gapLeft = 5, keepLeft = false, leftAbove = 22, crossEta = 4.5, cut = 0.8, signalDelay = 2.5 },
  madmax   = { pass = 2 * MPH,   gapLeft = 4, keepLeft = true,  leftAbove = 14, crossEta = 4,   cut = 0.6, signalDelay = 1.2 },
  furious  = { pass = 0.5 * MPH, gapLeft = 3, keepLeft = true,  leftAbove = 8,  crossEta = 3,   cut = 0.4, signalDelay = 0.6 },
}

M.DEFAULT_SETTINGS = {
  quirks = { phantomBraking = false, yellowHesitation = false, wiggle = false, hesitate = false, weather = true, creep = true },
  speedOffsetMph = nil,  -- TACC/Autosteer: set speed = limit + offset (nil: profile offset)
  setSpeed = nil,        -- TACC/Autosteer fixed set speed (m/s) when the driver picked one
  followDistance = nil,  -- 1..7 (TACC); nil = profile gap
  laneChanges = true,
  allowDriveways = false, -- Banish / park-nearby may use a driveway only when switched on (a spot tapped on the map always works)
  nags = true,
  unresponsive = 'park',  -- no answer to the last nag: park nearby if there's a spot, else pull over
  trafficControl = 'auto', -- 'confirm': wait for the driver's go (accelerator tap / confirm button) after stopping at a sign or light
  confidenceFloor = 0.55, -- below this FSD asks the driver to take over (and keeps driving)
}
-- how long FSD sits at a stop sign before going, per profile (seconds; Tesla is brief)
-- acceleration setting: how hard FSD (and, in the car, your pedal) may build power
local ACCEL = { chill = { th = 0.75, rise = 0.7 }, standard = { th = 1, rise = 1 }, sport = { th = 1.4, rise = 1.5 } }
setmetatable(ACCEL, { __index = function() return ACCEL.standard end })
local STOP_DWELL = { sloth = 1.6, chill = 1.3, standard = 1.0, hurry = 0.7, madmax = 0.4, furious = 0.2 }

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
    nag = Nag.new(), learn = opts.learn,
    t = 0, events = {}, lastDisengage = nil,
    wiggleUntil = -1, phantom = nil, lastOverhead = false,
    arrivalMemory = {},
    brain = opts.brain or Brain.new(), hangBack = {}, judge = Judge.new(), lightAge = {}, pedNoted = {}, policy = opts.policy,
  }, Planner)
  self.nag.rng = self.rng
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
  self.nag.enabled = self.settings.nags ~= false and self.settings.nagMode ~= 'off'
  local nm = self.settings.nagMode
  self.nag.mode = (nm == 'camera' or nm == 'wheel' or nm == 'off') and nm or 'auto'
end

function Planner:prof() return P.PROFILES[self.profile] or P.PROFILES.standard end

-- Change the speed profile while driving (re-derives the speed caps).
function Planner:setProfile(profile)
  if not P.PROFILES[profile] then return end
  self.profile = profile
  if self.path then
    local prof = self:prof()
    P.speedProfile(self.path, { offset = prof.offset, aLat = prof.aLat, straight = prof.straight, endSpeed = (not self.path.openEnded) and 0 or nil })
    self.builtFor = profile
  end
end
function Planner:beh() return M.BEHAVIOR[self.profile] or M.BEHAVIOR.standard end

---------------------------------------------------------------------------
-- routes
---------------------------------------------------------------------------

-- Is something solid standing in the spot (a pole, a tree, a bin, a wall: the level's parking data lists spots like that)? Looked at
-- with static rays from the middle, once per spot every 20 s. Parked cars are not static, they are handled by spotOccupied.
local rayChecks, rayBlocked = 0, 0
local function spotObstructed(spot, cast)
  if not cast then return false end
  -- a check that says "blocked" for most spots is the check being wrong (a bad ray origin, odd level geometry), not the spots: switch it
  -- off, or free spots (and the blips for them on the map) would vanish
  if rayChecks >= 20 and rayBlocked / rayChecks > 0.6 then return false end
  local now = os.clock()
  if spot.chk and now - spot.chk.t < 20 then return spot.chk.v end
  local blocked = false
  local z = (spot.z or 0)
  -- something solid right in the middle of the stall (the car is 1.9 m wide: the footprint's core is within 0.9 m of the centre in any
  -- direction; the axis of a stall in the level data is not reliable enough to look further along it)
  for _, d in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
    local ok, hit = pcall(cast, spot.x, spot.y, z + 0.8, d[1], d[2], 0, 0.9)
    if ok and hit then blocked = true; break end
  end
  rayChecks = rayChecks + 1
  if blocked then rayBlocked = rayBlocked + 1 end
  spot.chk = { t = now, v = blocked }
  return blocked
end

local function spotOccupied(spot, cars, cast)
  for _, c in ipairs(cars or {}) do
    if (c.x - spot.x) ^ 2 + (c.y - spot.y) ^ 2 < 2.4 ^ 2 then return true end
  end
  return spotObstructed(spot, cast)
end

-- Best free parking spot near the destination (FSD v14: nearer, and not taken).
-- A spot's own axis (from the level's parking data) refines "opens toward the road": the car should end
-- parallel to the painted lines. The axis may be the spot's length or its width (and either sign), so take
-- whichever of the four directions is closest to the road-derived one, if that is within 35 degrees.
local function snapToSpotAxis(spot, ox, oy)
  if not spot.known then return ox, oy end
  local ax, ay = spot.dx or 0, spot.dy or 0
  local l = sqrt(ax * ax + ay * ay)
  if l < 0.5 then return ox, oy end
  ax, ay = ax / l, ay / l
  local best, bd
  for _, c in ipairs({ { ax, ay }, { -ax, -ay }, { -ay, ax }, { ay, -ax } }) do
    local d = c[1] * ox + c[2] * oy
    if not bd or d > bd then best, bd = c, d end
  end
  if bd and bd > math.cos(math.rad(35)) then return best[1], best[2] end
  return ox, oy
end

-- Is this spot a driveway (a lone space off the road, not part of a lot or a row along the street)? Lots have neighbours, street
-- spots sit within the roadside band; a spot with fewer than two others within 15 m that is also well off the road is a driveway.
-- Banish and the "park nearby" choices skip them unless Settings > Allow parking in driveways is on (tapping a spot on the map always works).
function Planner:isDriveway(sp)
  if type(sp) ~= 'table' then return false end
  if sp.driveway ~= nil then return sp.driveway end
  if #(self.parking or {}) < 8 then return false end -- too few spots in the level to tell a lot from a driveway
  local n = 0
  for _, o in ipairs(self.parking or {}) do
    if o ~= sp and (o.x - sp.x) ^ 2 + (o.y - sp.y) ^ 2 < 15 * 15 then n = n + 1; if n >= 2 then break end end
  end
  local offRoad = true
  if self.graph and n < 2 then
    local e, _, ed = P.nearestEdge(self.graph, sp.x, sp.y, nil, nil, 30)
    if e then
      local na = self.graph.nodes[e.a]
      offRoad = ed > ((na and na.r) or 4) + 3.5
    end
  end
  sp.driveway = n < 2 and offRoad
  return sp.driveway
end

-- A kerbside bay: sits in the roadside band and runs along the road (parallel parking), not a stall of a lot.
function Planner:isStreetSpot(sp)
  if sp.street ~= nil then return sp.street end
  sp.street = false
  if self.graph and sp.dx then
    local e, _, ed = P.nearestEdge(self.graph, sp.x, sp.y, nil, nil, 30)
    if e then
      local a, b = self.graph.nodes[e.a], self.graph.nodes[e.b]
      local ex, ey = b.x - a.x, b.y - a.y
      local el = sqrt(ex * ex + ey * ey)
      local sl = sqrt(sp.dx * sp.dx + sp.dy * sp.dy)
      if el > 1e-6 and sl > 1e-6 then
        local along = abs(ex * sp.dx + ey * sp.dy) / (el * sl)
        sp.street = ed < ((a.r or 4) + 3.5) and along > 0.75
      end
    end
  end
  return sp.street
end

function Planner:spotAllowed(sp)
  return (self.settings and self.settings.allowDriveways) or not self:isDriveway(sp)
end

function Planner:pickSpot(dest, cars, radius, path, ego, wantLot)
  if self.chosenSpot and not spotOccupied(self.chosenSpot, cars, self.castRay) then return self.chosenSpot end
  -- The best spot is not only the one closest to the pin: with a route in hand, a spot the car reaches sooner (and that sits close to
  -- the road it is on) wins against one a few metres closer to the pin that means driving past a row of free ones; a spot behind the
  -- car costs a turn around.
  local s0 = 0
  if path and ego then
    local pr0 = P.project(path, ego.x, ego.y)
    s0 = pr0 and pr0.s or 0
  end
  local best, bestScore, bestStreet, bestStreetScore
  for _, sp in ipairs(self.parking) do
    local d = sqrt((sp.x - dest[1]) ^ 2 + (sp.y - dest[2]) ^ 2)
    if d < (radius or 80) and not spotOccupied(sp, cars, self.castRay) and self:spotAllowed(sp) then
      -- walking: the first 25 m from the pin are all "right there"; beyond that every metre counts double (a spot beside the car,
      -- 150 m from the pin, must not tie with one at the pin that costs 150 m of driving)
      local score = min(d, 25) + 2.0 * max(0, d - 25)
      if path then
        local pr = P.project(path, sp.x, sp.y)
        if pr then
          local ahead = pr.s - s0
          if ahead < -3 then score = score + 60 else score = score + 1.0 * max(0, ahead) end
          score = score + 0.6 * max(0, pr.dist - 4) -- how far it sits off the road we are on
        end
      end
      if wantLot and self:isStreetSpot(sp) then
        if not bestStreetScore or score < bestStreetScore then bestStreet, bestStreetScore = sp, score end
      elseif not bestScore or score < bestScore then best, bestScore = sp, score end
    end
  end
  return best or bestStreet -- "Parking Lot" takes a lot stall when there is one, a kerbside bay only when there is nothing else
end

-- The nearest free parking spot to the car (index into self.parking and the spot), within `radius` m; nil if none.
-- The free spots within `radius`, nearest first (up to n): Banish tries them in turn instead of giving up on the first
function Planner:freeSpotsNear(ego, cars, radius, n)
  local list = {}
  for i, sp in ipairs(self.parking or {}) do
    local d = sqrt((sp.x - ego.x) ^ 2 + (sp.y - ego.y) ^ 2)
    if d < (radius or 200) and self:spotAllowed(sp) and not spotOccupied(sp, cars, self.castRay) then list[#list + 1] = { id = i, d = d } end
  end
  table.sort(list, function(a, b) return a.d < b.d end)
  local out = {}
  for i = 1, math.min(n or 5, #list) do out[i] = list[i].id end
  return out
end

function Planner:nearestFreeSpot(ego, cars, radius)
  local best, bi, bd
  for i, sp in ipairs(self.parking or {}) do
    local d = sqrt((sp.x - ego.x) ^ 2 + (sp.y - ego.y) ^ 2)
    if d < (radius or 200) and self:spotAllowed(sp) and not spotOccupied(sp, cars, self.castRay) and (not bd or d < bd) then best, bi, bd = sp, i, d end
  end
  return bi, best, bd
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

-- Is the destination well off the road the route ends on (a business, a car park)? 10..150 m away.
function Planner:destOffRoad(path)
  local e = path.pts[#path.pts]
  if not e or not self.dest then return false end
  local d = sqrt((self.dest[1] - e.x) ^ 2 + (self.dest[2] - e.y) ^ 2)
  return d > 10 and d < 150
end

-- May the car turn around (stop, three-point turn) when the destination is behind it? Not right after one, and
-- the driver can switch it off (settings.uturn = false).
function Planner:mayUTurn(ego)
  if self.settings and self.settings.uturn == false then return false end
  if self.noUturnUntil and self.t < self.noUturnUntil then return false end
  return true
end

-- While turnAround.phase == 'stop' the car slows to a stop in its lane (stopS), then turns around if the road has room.
-- Returns the stop position (arc length) to use, or nil.
function Planner:turnAroundTick(ego, cars, sCar, v, stopS)
  local ta = self.turnAround
  if not ta or ta.phase ~= 'stop' then return stopS end
  if self.t - ta.t > 40 then
    self.turnAround, self.noUturnUntil = nil, self.t + 90
    self.replanNow = true
    return stopS
  end
  local pr = self.path and P.project(self.path, ta.px, ta.py)
  if pr and pr.s and (not stopS or pr.s < stopS) then stopS = pr.s end
  local near = (ego.x - ta.px) ^ 2 + (ego.y - ta.py) ^ 2 < 2.5 * 2.5
  if v < 0.4 or (near and v < 1.0) then
    local loc = self.graph and P.locate(self.graph, ego.x, ego.y, ego.hx, ego.hy, 40)
    if loc and not loc.ow and loc.r < 9 then
      local latRight = P.laneCenter(loc.r, false, loc.lane) - loc.lat
      local road = { cx = ego.x - loc.dy * latRight, cy = ego.y + loc.dx * latRight, dx = loc.dx, dy = loc.dy, r = loc.r }
      local seg, clearK = self:kTurnLeg(ego, road, nil, cars)
      if seg and clearK then
        self.kturn = { road = road, lastDir = seg.dir }
        self.turnAround, self.noUturnUntil = nil, self.t + 90 -- one turn, then on to the destination (no second one right away)
        self:emit('uturn', { state = 'turning' })
        self:startManeuver({ seg }, 'drive', 'kTurn')
        return stopS
      end
    end
    -- no room here (one-way, wide road, walls): drive on and take the long way round
    self.turnAround, self.noUturnUntil = nil, self.t + 90
    self:emit('uturn', { state = 'noRoom' })
    self.replanNow = true
  end
  return stopS
end


-- Leaving a drive-thru / lot window that is off the road: a smooth curve from where the car stands (pointing the way it
-- points) onto the road route, joining it ~15 m along. Only for the trip's way out (self.leaveLot).
function Planner:joinFromLot(path, ego)
  local pts = path.pts
  local p1 = pts[1]
  if not p1 then return end
  local d0 = sqrt((p1.x - ego.x) ^ 2 + (p1.y - ego.y) ^ 2)
  if d0 < 6 or d0 > 150 then return end
  local S = P.cumulative(pts)
  local jn = #pts
  for i = 1, #pts do if S[i] >= 15 then jn = i; break end end
  local pj, pj0 = pts[jn], pts[max(1, jn - 1)]
  local tx, ty = pj.x - pj0.x, pj.y - pj0.y
  local tl = sqrt(tx * tx + ty * ty)
  if tl < 1e-6 then return end
  tx, ty = tx / tl, ty / tl
  local conn = Mv.feasibleBezier({ x = ego.x, y = ego.y, z = ego.z or 0 }, ego.hx, ego.hy, pj, tx, ty, 6)
  local all = {}
  for _, q in ipairs(conn) do q.lim = 4; all[#all + 1] = q end
  for i = jn + 1, #pts do all[#all + 1] = pts[i] end
  local old = S[jn]
  local newS = P.cumulative(all)
  local joinS = newS[#conn] or 0
  path.pts = all
  path.s = newS
  for _, tn in ipairs(path.turns or {}) do tn.s = tn.s - old + joinS end
  self.joinedLot = true
end


-- Does a reverse path keep the car's body clear of the parked cars around a stall? Both bodies are three circles (nose, middle, tail);
-- the neighbours are taken to stand along the stall's axis (ox, oy). 0.2 m of room is the least accepted.
local function sweepClear(pts, ego, cars, spot, ox, oy)
  local er = (ego.wid or 1.9) * 0.5 + 0.3 -- the car lags its path a little, so this much room is wanted
  local others = {}
  for _, c in ipairs(cars or {}) do
    if abs(c.v or 0) < 0.3 and (c.x - spot.x) ^ 2 + (c.y - spot.y) ^ 2 < 9 * 9 and (c.x - spot.x) ^ 2 + (c.y - spot.y) ^ 2 > 0.8 * 0.8 then
      local cr, half = (c.w or 1.9) * 0.5, ((c.l or 4.6) * 0.5 - (c.w or 1.9) * 0.5)
      for _, off in ipairs({ -half, 0, half }) do others[#others + 1] = { x = c.x + ox * off, y = c.y + oy * off, r = cr } end
    end
  end
  local half = (ego.len or 4.6) * 0.5 - (ego.wid or 1.9) * 0.5
  for i = 1, #pts - 1 do
    local tx, ty = pts[i + 1].x - pts[i].x, pts[i + 1].y - pts[i].y
    local tl = sqrt(tx * tx + ty * ty)
    if tl > 1e-9 then tx, ty = tx / tl, ty / tl end
    local nx, ny = -tx, -ty -- reversing: the nose points back along the way we came
    for _, off in ipairs({ -half, 0, half }) do
      local ex, ey = pts[i].x + nx * off, pts[i].y + ny * off
      for _, o in ipairs(others) do
        if (o.x - ex) ^ 2 + (o.y - ey) ^ 2 < (o.r + er) ^ 2 then return false end
      end
    end
  end
  return true
end

-- Back into a stall: the smoothest approach that keeps clear of parked neighbours. The simple curve first; when it would clip a
-- neighbour (a stall between two cars needs the car square to it before its corners reach them), fixed-radius arcs with longer
-- and longer straight tails, nearest first. Returns Q (end of the forward approach) and the reverse segment (validated = true when
-- checked against the neighbours).
function Planner:planBackIn(ego, cars, spot, road, ox, oy)
  local q, rev = Mv.backIn(spot, road, 6)
  local flanked = false
  for _, c in ipairs(cars or {}) do
    if abs(c.v or 0) < 0.3 and (c.x - spot.x) ^ 2 + (c.y - spot.y) ^ 2 < 6 * 6 and (c.x - spot.x) ^ 2 + (c.y - spot.y) ^ 2 > 0.8 * 0.8 then flanked = true end
  end
  -- alone in a row the smooth curve is fine; between parked cars the car is brought in square, with the longest straight run
  -- that fits (it has the most room to settle onto the stall's line before the corners reach the neighbours)
  if not flanked and sweepClear(rev.pts, ego, cars, spot, ox, oy) then rev.validated = true; return q, rev end
  local best
  for _, tail in ipairs({ 1.5, 2.5, 3.5, 4.5 }) do
    for _, R in ipairs({ 5.4, 6.5 }) do
      for _, extra in ipairs({ 1.0, 2.5 }) do
        local Q, pts = Mv.backInArc({ x = spot.x, y = spot.y, z = spot.z }, { x = ox, y = oy }, { x = road.dx, y = road.dy }, R, extra, tail)
        if sweepClear(pts, ego, cars, spot, ox, oy) and (not best or tail + R > best.lat) then
          best = { lat = tail + R, Q = Q, seg = { dir = -1, pts = pts, maxSpeed = 1.4, kind = 'backIn', curvature = 1 / R, validated = true } }
        end
      end
    end
  end
  if best then return best.Q, best.seg end
  return q, rev
end

-- Pull forward into a perpendicular stall: straight along the aisle, one arc of radius R into the stall's axis, straight to its centre. Checked
-- against the neighbours; returns the new path, or nil (the caller backs in instead).
function Planner:planPullIn(ego, cars, path, pr, spot, ox, oy)
  local hx, hy = -ox, -oy -- into the stall: the opposite of the way it opens
  local P0 = path.pts[pr.i]
  local P1 = path.pts[min(#path.pts, pr.i + 1)]
  local tx, ty = P1.x - P0.x, P1.y - P0.y
  local tl = sqrt(tx * tx + ty * ty)
  if tl < 1e-6 then return nil end
  tx, ty = tx / tl, ty / tl
  local cr = tx * hy - ty * hx -- cross(t, h): which way the turn goes, and its size
  if abs(cr) < 0.3 then return nil end -- not a real turn in: leave it to the back-in
  local wx, wy = spot.x - P0.x, spot.y - P0.y
  local u = (wx * hy - wy * hx) / cr
  local bb = (tx * wy - ty * wx) / cr
  if bb < 0.5 then return nil end
  local X = { x = P0.x + tx * u, y = P0.y + ty * u } -- where the aisle line meets the stall's axis
  local theta = math.acos(max(-1, min(1, tx * hx + ty * hy)))
  local sgn = cr > 0 and 1 or -1
  for _, R in ipairs({ 5.4, 6.2, 7.5 }) do
    local TL = R * math.tan(theta / 2)
    if bb >= TL + 1.8 then -- (a short straight at the end leaves the car still turning when it stops: only pull in with room to settle square)
      local T1 = { x = X.x - tx * TL, y = X.y - ty * TL }
      local T2 = { x = X.x + hx * TL, y = X.y + hy * TL }
      local C = { x = T1.x - sgn * ty * R * -1 * -1, y = T1.y + sgn * tx * R * -1 * -1 }
      -- centre of the arc: from T1, R to the side we turn toward (left of t when sgn > 0)
      C = { x = T1.x + (-ty) * sgn * R, y = T1.y + tx * sgn * R }
      local z = spot.z or P0.z or 0
      local curve = {}
      local nArc = max(6, math.ceil(theta * R / 0.6))
      local v0x, v0y = T1.x - C.x, T1.y - C.y
      for i = 1, nArc do
        local ph = sgn * theta * i / nArc
        local cph, sph = math.cos(ph), math.sin(ph)
        curve[#curve + 1] = { x = C.x + v0x * cph - v0y * sph, y = C.y + v0x * sph + v0y * cph, z = z }
      end
      local last = curve[#curve]
      local run = sqrt((spot.x - last.x) ^ 2 + (spot.y - last.y) ^ 2)
      for m = 1, max(1, math.floor(run / 0.6)) do curve[#curve + 1] = { x = last.x + hx * 0.6 * m, y = last.y + hy * 0.6 * m, z = z } end
      curve[#curve + 1] = { x = spot.x, y = spot.y, z = z }
      -- the route up to 2 m before the arc starts, then a straight run to it
      local j = pr.i
      while j > 1 and ((X.x - path.pts[j].x) * tx + (X.y - path.pts[j].y) * ty) < TL + 2 do j = j - 1 end
      local head = {}
      for i = 1, j do head[#head + 1] = path.pts[i] end
      local A = path.pts[j]
      local run0 = sqrt((T1.x - A.x) ^ 2 + (T1.y - A.y) ^ 2)
      local pre = {}
      for m = 1, max(1, math.floor(run0 / 1.0)) do pre[#pre + 1] = { x = A.x + (T1.x - A.x) * m / math.max(1, math.floor(run0 / 1.0)), y = A.y + (T1.y - A.y) * m / math.max(1, math.floor(run0 / 1.0)), z = z } end
      local all = {}
      for _, q in ipairs(pre) do all[#all + 1] = q end
      for _, q in ipairs(curve) do all[#all + 1] = q end
      local rev = {}
      for i = #all, 1, -1 do rev[#rev + 1] = all[i] end -- the sweep check wants the nose pointing back along the points (it was written for reversing)
      if sweepClear(rev, ego, cars, spot, ox, oy) then
        local cut = {}
        for i = 1, j do cut[i] = path.pts[i] end
        for _, q in ipairs(all) do
          local pt = {}
          for kk, vv in pairs(A) do pt[kk] = vv end
          pt.x, pt.y, pt.z, pt.node, pt.lim = q.x, q.y, q.z, nil, 2.0
          cut[#cut + 1] = pt
        end
        path.pts = cut
        path.s = P.cumulative(cut)
        path.parked = true
        return path
      end
    end
  end
  return nil
end

-- Build self.path from the ego pose (route to dest via stops, or follow the road).
function Planner:planPath(ego, cars)
  local g = self.graph
  if not g then return false, 'map not loaded yet' end
  local hx, hy = ego.hx, ego.hy
  local path
  self.uturnNeeded = false
  if self.dest and self.mode ~= 'autosteer' then -- Autopilot does not navigate
    local legs = {}
    if self.turnVia then legs[1] = { self.turnVia.x, self.turnVia.y } end
    for _, s in ipairs(self.stops or {}) do legs[#legs + 1] = s end
    legs[#legs + 1] = self.dest
    local sx, sy = ego.x, ego.y
    local all
    for li, goal in ipairs(legs) do
      -- moving: no sharp turn at the next junction (inside ~2.5 s of travel); the car goes on and turns at a later one
      local moving = li == 1 and (ego.v or 0) > 3 and ego.gear ~= 'R' and (self.t or 0) < (self.noSharpUntil or -1)
      local rt, err = P.route(g, { x = sx, y = sy, hx = hx, hy = hy, uturnCost = (li == 1 and self:mayUTurn(ego)) and 40 or nil,
        sharpTurnWithin = moving and max(14, (ego.v or 0) * 2.5 + 6) or nil }, { x = goal[1], y = goal[2] })
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
    -- a pin near a business with parking just parks there (the driver picked Street / Driveway / Curbside otherwise): look wider for a free spot
    local spot = (kind == 'Parking Lot' or kind == 'Parking Garage' or kind == 'auto') and self:pickSpot(self.dest, cars, kind == 'auto' and 120 or 160, path, ego, kind ~= 'auto') or nil
    path.arrivalKind = 'point'
    -- tell the app what the car is doing about parking (a banner: "Looking for parking" / "Parking spot found"), once per
    -- destination and state
    if kind == 'Parking Lot' or kind == 'Parking Garage' or kind == 'auto' then
      local st = spot and 'found' or 'looking'
      if self.parkNoted ~= key .. st then
        self.parkNoted = key .. st
        self:emit('parkingSearch', { state = st })
      end
    end
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
      if perpendicular then ox, oy = snapToSpotAxis(spot, ox, oy) end
      self.spot = spot
      local pulled = false
      if perpendicular and (self.settings.parkStyle or 'auto') ~= 'backIn' and (self.settings.parkStyle == 'pullIn' or true) then
        -- pull in nose-first when the curve fits and the neighbours allow it (easier than backing in); otherwise back in
        pulled = self:planPullIn(ego, cars, path, pr, spot, ox, oy) ~= nil
        if pulled then path.arrivalKind = 'parking' end
      end
      if pulled then
        -- (path already runs into the stall)
      elseif perpendicular then
        -- back into the stall: stop past it, then reverse in
        local q, rev = self:planBackIn(ego, cars, { x = spot.x, y = spot.y, z = spot.z, outx = ox, outy = oy },
          { x = pr.x, y = pr.y, z = spot.z, dx = rdx, dy = rdy }, ox, oy)
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
        path.afterKind = 'backIn'
        path.arrivalKind = 'parking'
      else
        -- a kerbside bay: park facing the way traffic goes (the stall axis has no sign)
        local sdx, sdy = spot.dx, spot.dy
        if sdx and (sdx * rdx + sdy * rdy) < -0.2 and self:isStreetSpot(spot) then sdx, sdy = -sdx, -sdy end
        P.appendParking(path, spot.x, spot.y, spot.z, sdx, sdy)
        path.arrivalKind = 'parking'
      end
    elseif kind == 'Street' and self:parallelPark(path, cars) then
      path.arrivalKind = 'parking'
    elseif kind == 'Drive Thru' then
      -- the pin is the order window: drive up to it (turning in off the road when it is a business set back from it), stop, wait, go on
      do -- where to rejoin the road afterwards: 200 m on from where the route meets it
        local n = #path.pts
        local e, e0 = path.pts[n], path.pts[max(1, n - 1)]
        local tx, ty = e.x - e0.x, e.y - e0.y
        local tl = sqrt(tx * tx + ty * ty)
        if tl > 1e-6 then self.exitPt = { e.x + tx / tl * 200, e.y + ty / tl * 200, e.z or 0 } end
      end
      if self:destOffRoad(path) then
        local e = path.pts[#path.pts]
        P.appendParking(path, self.dest[1], self.dest[2], e.z, self.dest[1] - e.x, self.dest[2] - e.y)
      end
      path.arrivalKind = 'driveThru'
    elseif kind == 'Drive On' then
      path.arrivalKind = 'point'
    elseif (kind == 'Parking Lot' or kind == 'Parking Garage' or kind == 'auto' or kind == 'Driveway') and self:destOffRoad(path) then
      -- the destination isn't on a road (a business, a lot with no mapped aisles): turn in and drive up to it
      local e = path.pts[#path.pts]
      local ux, uy = self.dest[1] - e.x, self.dest[2] - e.y
      P.appendParking(path, self.dest[1], self.dest[2], e.z, ux, uy)
      path.arrivalKind = 'parking'
    elseif kind ~= 'Driveway' and kind ~= 'Take Over' then
      -- the driver asked to pull over: as far to the edge as the car fits (about 0.15 m of clearance), else the usual 0.5 m
      P.pullOver(path, self.pullingOver and 20 or 30, 1, self.pullingOver and 1.1 or nil)
      path.arrivalKind = 'curb'
    end
  else
    local rt, err = P.followRoad(g, ego.x, ego.y, hx, hy, 1500, self.turnVia)
    if not rt then return false, err end
    path = P.buildPath(g, rt)
  end
  if self.dest and self.uturnNeeded and self:mayUTurn(ego) and (ego.v or 0) > 1.0 and self.mode ~= 'off' and self.activity == 'drive' then
    -- the best way is back the way we came: keep going straight, slow to a stop, and turn around (see turnAroundTick)
    local rt2 = P.followRoad(g, ego.x, ego.y, ego.hx, ego.hy, 1500, nil)
    if rt2 then
      path = P.buildPath(g, rt2)
      if not self.turnAround then
        local d = max(8, (ego.v or 0) * (ego.v or 0) / 4 + 4) -- a fixed place to stop, a comfortable braking distance ahead
        self.turnAround = { phase = 'stop', t = self.t, px = ego.x + ego.hx * d, py = ego.y + ego.hy * d }
        self:emit('uturn', { state = 'stopping' })
      end
    end
  elseif not self.uturnNeeded then
    self.turnAround = nil
  end
  if self.dest then
    -- tell the report when a trip comes out far longer than the straight line (why: U-turns
    -- avoided, one-ways, the destination snapping to another road)
    local straight = sqrt((self.dest[1] - ego.x) ^ 2 + (self.dest[2] - ego.y) ^ 2)
    local len = path.s[#path.s]
    if len > 3 * straight + 300 then
      self:emit('longRoute', { length = floor(len), straight = floor(straight), uturnAvoided = self.uturnNeeded or nil })
    end
  end
  if self.leaveLot then self:joinFromLot(path, ego) end
  prependBack(path, 150)
  local prof = self:prof()
  P.speedProfile(path, { offset = prof.offset, aLat = prof.aLat, straight = prof.straight, decel = prof.decel, endSpeed = (not path.openEnded) and 0 or nil })
  path.limit = {}
  for i, pt in ipairs(path.pts) do path.limit[i] = pt.lim or P.classDefaultSpeed(pt.r, pt.drv) end
  self.path, self.hint = path, nil
  self.cleared, self.clearedS, self.stopFsm = {}, -1e9, {}
  self.lane = { k = 0, change = nil, cooldown = 0 }
  self.syncLane = true -- the lane we are really in, not "the right one", is where the new path starts
  self.bumps = {}
  self.arrived = false
  self.routeDirty = true
  return true
end

-- "Street" arrival: find a free curb gap near the end of the route (not at a junction, clear
-- of parked cars), stop in the lane past it, then parallel park. Returns true when set up.
function Planner:parallelPark(path, cars)
  local pts, S = path.pts, path.s
  local n = #pts
  if n < 4 then return false end
  local sEnd = S[n]
  local CAR_L, GAP = 4.8, 7.2
  local function sample(sq)
    local lo = 1
    while lo < n - 1 and S[lo + 1] < sq do lo = lo + 1 end
    local a, b = pts[lo], pts[lo + 1]
    local u = (sq - S[lo]) / max(1e-6, S[lo + 1] - S[lo])
    local tx, ty = b.x - a.x, b.y - a.y
    local tl = sqrt(tx * tx + ty * ty)
    if tl < 1e-6 then return nil end
    return { x = a.x + (b.x - a.x) * u, y = a.y + (b.y - a.y) * u, z = (a.z or 0) + ((b.z or 0) - (a.z or 0)) * u,
      dx = tx / tl, dy = ty / tl, r = a.r or 4, ow = a.ow, i = lo }
  end
  -- nearest the destination first, backing up the road
  for back = 10, 45, 2 do
    local c = sample(sEnd - back)
    if c and c.r >= 3.5 then
      -- route points run down the lane centre; the spot centre sits 1.1 m in from the road edge
      local lane = c.ow and 0 or min(c.r * 0.5, 1.8)
      local curb = c.r - 1.1 -- spot centre from the road's centreline
      local rx, ry = c.dy, -c.dx
      local spot = { x = c.x + rx * (curb - lane), y = c.y + ry * (curb - lane), z = c.z }
      local ok = true
      -- not in a junction
      for i = max(1, c.i - 8), min(n, c.i + 8) do
        local p = pts[i]
        if p.node and (self.degree[p.node] or 0) >= 3 and (p.x - c.x) ^ 2 + (p.y - c.y) ^ 2 < 18 * 18 then ok = false; break end
      end
      -- the gap is free of cars
      if ok then
        for _, o in ipairs(cars or {}) do
          local ox, oy = o.x - spot.x, o.y - spot.y
          local along = ox * c.dx + oy * c.dy
          local side = ox * rx + oy * ry
          if abs(along) < GAP * 0.5 + CAR_L * 0.5 - 0.3 and abs(side) < 2.2 then ok = false; break end
        end
      end
      local q, segs
      if ok then
        q, segs = Mv.parallel(spot, { dx = c.dx, dy = c.dy, off = curb - lane }, 6)
        local pe = { z = c.z, wid = 1.9, len = 4.8 }
        if not self:pathClear(segs[1].pts, pe, cars, 3.5, 2.6) then ok = false end
      end
      if ok then
        -- run the route on (in the lane) to q, then do the maneuver
        local pr = P.project(path, c.x, c.y)
        local cut = {}
        for i = 1, pr.i do cut[i] = pts[i] end
        local base = pts[pr.i]
        local qx, qy = q.x, q.y -- in the lane, past the gap
        local steps = max(1, floor(sqrt((qx - base.x) ^ 2 + (qy - base.y) ^ 2) / 2))
        for k = 1, steps do
          local u = k / steps
          local p = {}
          for kk, vv in pairs(base) do p[kk] = vv end
          p.x, p.y, p.node = base.x + (qx - base.x) * u, base.y + (qy - base.y) * u, nil
          p.lim = 5
          cut[#cut + 1] = p
        end
        path.pts = cut
        path.s = P.cumulative(cut)
        path.afterManeuver = segs
        path.afterKind = 'parallel'
        self.spot = { x = spot.x, y = spot.y, z = spot.z, dx = c.dx, dy = c.dy }
        return true
      end
    end
  end
  return false
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
  self.noSharpUntil = (self.t or 0) + 20 -- a new place picked while driving: no sharp turn at the junction right ahead for the next 20 s (see planPath)
  self.turnVia, self.chosenSpot = nil, nil
  self.pullingOver, self.unresponsive = nil, nil -- a new trip replaces a pull-over in progress
  self.arrivingFor = nil
  self.path = nil
  self.spot = nil
  self.exitDrive, self.exitPt, self.dtStart, self.leaveLot, self.destMin = nil, nil, nil, nil, nil
end

-- The driver's answer to the 'arriving' prompt: park / street (parallel) / pullOver / driveway / takeOver
local ARRIVAL_KINDS = { park = 'Parking Lot', street = 'Street', pullOver = 'Pull Over', driveway = 'Driveway', takeOver = 'Take Over', driveThru = 'Drive Thru' }
function Planner:setArrival(choice)
  local kind = ARRIVAL_KINDS[choice]
  if not kind or not self.dest then return false, 'no such arrival choice' end
  self.arrival = kind
  self.chosenSpot = nil
  if self.mode ~= 'off' then self.replanNow = true else self.path = nil end
  self:emit('arrivalChoice', { choice = choice })
  return true
end

function Planner:cancelRoute()
  self.dest, self.stops, self.arrival, self.spot, self.turnVia, self.chosenSpot = nil, nil, nil, nil, nil, nil
  self.pullingOver, self.unresponsive = nil, nil
  self.path = nil
end

-- mode: 'fsd' | 'autosteer' (steer + cruise) | 'tacc' (cruise only). Returns ok, err.
function Planner:engage(mode, profile, ego, cars)
  -- the lane you start in is the lane you stay in: no passing, no fast-lane or back-to-the-right drifting (the route, a merge, or you
  -- signalling still change it)
  if self.settings.laneLock ~= false then self.lanePinUntil = math.huge end
  self.curveAlertUntil = nil
  self.unattended = nil -- Banish / Summon set it again after engaging
  self.farTicks = 0 -- a fresh start: an earlier off-road spell must not count against this one
  if mode ~= 'tacc' and self.settings.easeEngage ~= false and abs(ego.v or 0) > 3 then self.engageSeq = (self.engageSeq or 0) + 1; self.easeUntil = (self.t or 0) + 70 else self.easeUntil = nil end
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
  if not self.path or (self.path.openEnded and self.dest and mode ~= 'autosteer') or (not self.path.openEnded and (not self.dest or mode == 'autosteer')) or self.builtFor ~= self.profile then
    local ok, err = self:planPath(ego, cars)
    if not ok then self.mode = 'off'; return false, err end
    self.builtFor = self.profile
  end
  if mode == 'fsd' and stationary and self.graph and (ego.gear == 'P' or ego.wallAhead) then
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
        local okc, whyc = self:segsClear(segs, ego, cars)
        if not okc then
          -- no room to swing out backwards: if the way ahead is open just drive off forward (FSD used to refuse to start)
          if self:aheadBlocked(ego, 1) then
            self.mode = 'off'
            return false, 'not enough room to back out safely (' .. tostring(whyc) .. ')'
          end
          self:emit('notice', { detail = 'no room to back out: driving forward out of the spot' })
        else
          self:startManeuver(segs, 'drive', 'backOut')
        end
      end
    elseif loc and self.uturnNeeded and not loc.ow and loc.r < 9 then
      -- centerline point: step from us back across our offset from it
      local latRight = P.laneCenter(loc.r, false, loc.lane) - loc.lat
      local road = { cx = ego.x - loc.dy * latRight, cy = ego.y + loc.dx * latRight, dx = loc.dx, dy = loc.dy, r = loc.r }
      local seg, clearS = self:kTurnLeg(ego, road, nil, cars)
      if seg and not clearS then
        self.mode = 'off'
        return false, 'not enough room to turn around safely'
      end
      if seg then
        self.kturn = { road = road, lastDir = seg.dir }
        self:startManeuver({ seg }, 'drive', 'kTurn')
      end
    end
  end
  if self.dest and mode == 'fsd' then
    -- a trip from earlier still being there is the likely reason FSD "just parks" (it drives to the old destination and finishes there)
    self:emit('notice', { detail = string.format('FSD is following a trip (arrival: %s, %.0f m away)', tostring(self.arrival or 'auto'), sqrt((self.dest[1] - ego.x) ^ 2 + (self.dest[2] - ego.y) ^ 2)) })
  end
  self:emit('engaged', { mode = mode, profile = self.profile })
  return true
end

-- A trip FSD made up itself (Banish's spot, a summon point, a tapped parking spot) is not the driver's: when it was interrupted (taken
-- over, stopped) it stayed, so the next "start FSD" drove back to it and parked "where it previously parked". A fresh start from the
-- driver forgets such a trip; a trip the app handed over (navigate) is kept.
function Planner:freshStart()
  if self.internalTrip then
    self:cancelRoute()
    self.chosenSpot, self.spot, self.maneuver = nil, nil, nil
    self.internalTrip = nil
    return true
  end
  return false
end

function Planner:disengage(reason, detail)
  if self.mode == 'off' then return end
  self.mode = 'off'
  self.unattended = nil
  self.activity = 'drive'
  self.maneuver = nil
  self.lastDisengage = { reason = reason, time = self.t }
  if self.pullingOver then
    -- taken over mid pull-over: keep the original trip (arrived: it's done)
    local sv = self.pullingOver.saved
    self.pullingOver = nil
    if reason ~= 'arrived' then self.dest, self.stops, self.arrival, self.path = sv.dest, sv.stops, sv.arrival, nil end
  end
  self.nag:onDisengage()
  self:emit('disengage', { reason = reason, detail = detail })
end

-- Is something (a wall, a pole, a curb or step) right in the way of the car moving `dirSign` (1 forward, -1 back)?
function Planner:aheadBlocked(ego, dirSign)
  local cast = self.castRay
  if not cast then return false end
  local hx, hy = ego.hx * dirSign, ego.hy * dirSign
  local half, wid = (ego.len or 4.6) * 0.5, (ego.wid or 1.9) * 0.5
  local z0 = ego.z or 0
  local reach = half + 1.1 -- (a bit more than the car's own length ahead: stop before touching, not on touching)
  -- a ray every 0.15 m across the car's width (+ a margin): a pole is thin (the old 5 rays, 0.5 m apart, slipped between)
  for _, h in ipairs({ 0.5, 0.2 }) do
    local off = -(wid + 0.1)
    while off <= wid + 0.1 do
      if cast(ego.x - hy * off, ego.y + hx * off, z0 + h, hx, hy, 0, reach) then return true end
      off = off + 0.15
    end
  end
  -- a step or drop under the nose
  local g0 = self:groundAt(cast, ego.x, ego.y, z0 + 1.5)
  local g1 = self:groundAt(cast, ego.x + hx * (half + 0.7), ego.y + hy * (half + 0.7), z0 + 1.5)
  if g0 and g1 and math.abs(g1 - g0) > 0.12 then return true end
  return false
end

-- Distance (m, from the bumper) to the nearest upright obstacle (pole, post, wall, car) straight ahead within maxD, across the car's width.
-- Upright = a high and a low ray both hit at about the same distance (a ramp or kerb is hit by the low one only).
function Planner:forwardClearDist(ego, maxD)
  local cast = self.castRay
  if not cast then return nil end
  local hx, hy = ego.hx, ego.hy
  local half, wid = (ego.len or 4.6) * 0.5, (ego.wid or 1.9) * 0.5
  local z0 = ego.z or 0
  local ox, oy = ego.x + hx * half, ego.y + hy * half
  local best
  local off = -(wid + 0.15)
  while off <= wid + 0.15 do
    local px, py = ox - hy * off, oy + hx * off
    local hi = cast(px, py, z0 + 0.8, hx, hy, 0, maxD)
    if hi then
      local lo = cast(px, py, z0 + 0.35, hx, hy, 0, maxD)
      if lo and math.abs(hi - lo) < 0.8 and (not best or lo < best) then best = lo end
    end
    off = off + 0.15
  end
  return best
end

-- Virtual lidar (FSD only): a fan of rays at the nose, read along the line we are about to drive.
--   a wall / pole / barrier on the line: nudge around it when 1.4 m or less of sideways room clears it, otherwise brake to stop short
--   (and after a few seconds back off and re-plan, then ask the driver); other cars are skipped (the car-following code owns those)
--   a curb on the line at speed: a small sideways nudge, never a stop, and none near the end of the route / parking / pulling over
function Planner:lidarAssist(ego, pr, sCar, v, cap, fsd)
  local path = self.path
  if not fsd or self.settings.lidar == false or not self.castRay or not path then self.lidarOut = nil; return end
  local Ld = self.lidar
  if not Ld then
    Ld = Lidar.new(function(x, y, z, dx, dy, dz, d) return self.castRay(x, y, z, dx, dy, dz, d) end)
    self.lidar = Ld
  end
  local range = clamp(v * 3.5 + 14, 18, 40)
  if self.t - (self.lidarT or -9) >= 0.09 then
    self.lidarT = self.t
    Ld:scan(ego, 1, range, self.t)
  end
  local half, wid = (ego.len or 4.6) * 0.5, (ego.wid or 1.9) * 0.5
  local S = path.s
  -- the line we will drive (the lane shift included), from the car forward
  local poly = { { x = ego.x, y = ego.y } }
  for i = pr.i, #path.pts do
    if S[i] - sCar > range then break end
    local a, b = path.pts[max(1, i - 1)], path.pts[min(#path.pts, i + 1)]
    local tx, ty = b.x - a.x, b.y - a.y
    local tl = sqrt(tx * tx + ty * ty)
    if tl > 1e-6 and S[i] > sCar + 0.3 then
      local sh = self:shiftAt(S[i], i)
      poly[#poly + 1] = { x = path.pts[i].x - ty / tl * sh, y = path.pts[i].y + tx / tl * sh }
    end
  end
  if #poly < 2 then return end
  -- other cars are not walls (they are handled by following / passing); anything within a car's reach of one is skipped
  local cars = self.lastCars or {}
  local function isCar(p)
    for _, c in ipairs(cars) do
      local r = max(c.l or 4.6, c.w or 1.9) * 0.5 + 1.2
      if (c.x - p.x) ^ 2 + (c.y - p.y) ^ 2 < r * r then return true end
    end
    return false
  end
  local halfW = wid + 0.25 + min(0.2, v * 0.015)
  local s, lat = Ld:alongHit(poly, halfW, nil, isCar)
  local out = { gap = nil, nudge = nil, curb = nil }
  self.lidarOut = out
  local _, w = self:laneAt(pr.i)
  local maxShift = clamp(((w or 3.4) - wid * 2) * 0.5 + 0.5, 0.6, 1.4)
  if s then
    local gap = s - half
    out.gap = gap
    if gap < max(14, v * 2.2 + 8) then
      local hasNudge = false
      for _, b in ipairs(self.bumps) do if b.kind == 'lidar' and b.s1 > sCar then hasNudge = true end end
      if not hasNudge then
        local sh = Ld:clearShift(poly, wid + 0.2, s + 4, maxShift, isCar)
        if sh and gap > 3.5 and v > 1.5 then
          self.bumps[#self.bumps + 1] = { s0 = sCar + max(1, gap - 5), s1 = sCar + s + 6, off = sh * 1.2, ramp = max(5, min(gap * 0.5, v * 0.8)), kind = 'lidar' }
          out.nudge = sh
          self:emit('notice', { detail = string.format('lidar: something solid %.0f m ahead, steering %.1f m %s around it', gap, abs(sh), sh > 0 and 'left' or 'right') })
          hasNudge = true
        end
      end
      if hasNudge then
        cap(max(4, min(v, sqrt(2 * 3.5 * max(0, gap - 1.5)) + 3)))
        self.lidarBlockedT = nil
      else
        cap(sqrt(2 * 4.0 * max(0, gap - 2.4)))
        out.blocked = true
        self.lidarBlockedT = self.lidarBlockedT or self.t
      end
    else
      self.lidarBlockedT = nil
    end
  else
    self.lidarBlockedT = nil
    -- a curb on the line: a small nudge away from it (never a stop; not when arriving, parking or pulling over)
    local calm = v > 6 and not self.pullingOver and not self.maneuver and (not self.dest or (path.s[#path.s] - sCar) > 45)
    if calm then
      local hasCurb = false
      for _, b in ipairs(self.bumps) do if b.kind == 'lidarCurb' and b.s1 > sCar then hasCurb = true end end
      if not hasCurb then
        local cs, clat = Ld:alongHit(poly, wid + 0.05, { low = true }, isCar)
        if cs and cs - half > 2 and cs - half < 12 then
          local sh = clamp(-(clat or 0) / abs(clat or 1) * 0.35, -0.35, 0.35) -- away from the curb's side
          if clat and abs(clat) > 0.01 then
            self.bumps[#self.bumps + 1] = { s0 = sCar + cs - 3, s1 = sCar + cs + 6, off = sh, ramp = 6, kind = 'lidarCurb' }
            out.curb = sh
          end
        end
      end
    end
  end
  -- blocked for good: back off and look again, then hand it to the driver
  if self.lidarBlockedT and v < 0.5 then
    local waited = self.t - self.lidarBlockedT
    if waited > 4 and (not self.lidarRecT or self.t - self.lidarRecT > 10) then
      self.lidarRecT = self.t
      self:emit('notice', { detail = 'lidar: the way ahead is blocked' })
      self.lidarTryRecover = true
    end
    if waited > 25 then self.status.lowConfidence = true; self.conf = min(self.conf or 1, 0.3) end
  else
    if not self.lidarBlockedT then self.lidarRecT = nil end
  end
end

-- Are all the legs of a maneuver clear of walls, curbs and cars?
function Planner:segsClear(segs, ego, cars)
  for _, sg in ipairs(segs or {}) do
    local ok, why = self:pathClear(sg.pts, ego, cars, 0, 2.6)
    if not ok then return false, why end
  end
  return true
end

function Planner:startManeuver(segs, after, kind)
  self.activity = 'maneuver'
  self.maneuver = { segs = segs, idx = 1, after = after, kind = kind, dwell = 0 }
  self:emit('maneuver', { what = kind, legs = #segs })
end

-- Dumb Summon: straight forward/back up to 12 m at walking pace.
function Planner:summon(dir, ego, len)
  if not dir then
    if self.activity == 'summon' then self.activity = 'drive'; self.mode = 'off'; self:emit('summon', { state = 'stopped' }) end
    return true
  end
  local sgn = dir == 'reverse' and -1 or 1
  local pts = {}
  for d = 0, len or 12, 0.5 do pts[#pts + 1] = { x = ego.x + ego.hx * d * sgn, y = ego.y + ego.hy * d * sgn, z = ego.z or 0 } end
  self.mode = 'fsd'
  self:startManeuver({ { dir = sgn, pts = pts, maxSpeed = 1.0 } }, 'stop', 'summon')
  self.activity = 'summon'
  return true
end

-- Is the car still on the line it was driving (within maxDist metres, pointing within maxDeg of it)? Used to tell a bump of the wheel
-- (it ended up where it was going) from a driver steering his own way (the accidental re-engage must not drag him back to the route).
function Planner:onPath(ego, maxDist, maxDeg)
  local path = self.path
  if not path or not path.pts or #path.pts < 3 then return true end -- nothing to compare with: it is not a reason to refuse
  local pr = P.project(path, ego.x, ego.y)
  if not pr then return true end
  if pr.dist > (maxDist or 1.6) then return false end
  local i = min(#path.pts - 1, max(1, pr.i))
  local tx, ty = path.pts[i + 1].x - path.pts[i].x, path.pts[i + 1].y - path.pts[i].y
  local tl = sqrt(tx * tx + ty * ty)
  if tl < 1e-6 then return true end
  local dot = (tx * ego.hx + ty * ego.hy) / tl
  return dot >= math.cos(math.rad(maxDeg or 20))
end

-- "I'm not feeling well": FSD takes over (engaging if it was off), hazards on, and it stops at the safer of
-- a free parking spot that is quick to reach or the side of the road. Cancel with cancelEmergency().
function Planner:emergencyStop(ego, cars)
  if self.emergency then return true end
  if self.mode == 'off' then
    local ok, err = self:engage('fsd', 'sloth', ego, cars)
    if not ok then return false, err end
  end
  self.emergency = { t = self.t }
  self:emit('emergencyStop', {})
  return true
end

function Planner:cancelEmergency()
  if not self.emergency then return false end
  self.emergency = nil -- the next tick restores the original trip (same path as an answered nag)
  self:emit('emergencyStop', { cancelled = true })
  return true
end

-- Stopped (parked / pulled over) for an unresponsive driver: P, hazards on, a strike, FSD off.
function Planner:finishUnresponsive(out)
  if not self.unresponsive then return false end
  local kind = self.unresponsive.kind
  self.unresponsive = nil
  self.chosenSpot = nil
  if self.emergency then
    -- the driver asked for this (not feeling well): hazards on, no strike, and the app can call someone now
    self.emergency = nil
    out.commands[#out.commands + 1] = { t = 'signal', dir = 'hazard' }
    self:emit('emergencyStopped', { where = kind == 'park' and 'parkingSpot' or 'roadside' })
    self:disengage('arrived', 'emergency stop')
  else
    for _, ev in ipairs(self.nag:strike()) do self:emit(ev.kind, ev) end
    self:emit('unresponsive', { action = kind == 'park' and 'parked' or 'pulledOver' })
    self:disengage('attention', 'driver did not respond')
  end
  self.dest, self.path = nil, nil
  out.route = self:routeMessage()
  return true
end

-- Parking spots near a point, for the app's map (id = index in the level's list).
function Planner:spotsNear(x, y, radius, cars)
  local out = {}
  for i, sp in ipairs(self.parking) do
    local d = sqrt((sp.x - x) ^ 2 + (sp.y - y) ^ 2)
    if d < (radius or 80) then
      out[#out + 1] = { id = i, x = sp.x, y = sp.y, z = sp.z or 0, dx = sp.dx, dy = sp.dy, free = not spotOccupied(sp, cars, self.castRay), d = d }
    end
  end
  table.sort(out, function(a, b) return a.d < b.d end)
  while #out > 40 do out[#out] = nil end
  return out
end

-- The driver tapped a parking spot on the map: park there. Close by: Autopark now. On a
-- trip: make it the destination (FSD parks there on arrival). Returns ok, err, how.
function Planner:parkAtSpot(id, ego, cars, opts)
  local sp = self.parking[id]
  if not sp then return false, 'no such parking spot' end
  if spotOccupied(sp, cars, self.castRay) then return false, 'that spot is taken' end
  local d = sqrt((sp.x - ego.x) ^ 2 + (sp.y - ego.y) ^ 2)
  -- opts.road (Banish): drive there like a car, at road speed; the slow direct maneuver (walking pace) only for a spot right beside us
  if d < ((opts and opts.road) and 14 or 40) and (ego.v or 0) < 3 then
    local ok, err = self:autopark(ego, cars, sp)
    if ok then return ok, err, 'now' end
    -- the direct approach did not fit (spot behind the car, a wall or neighbours in the way): drive there by road and park on
    -- arrival instead (this used to give up with "no room to maneuver into that spot", even in the middle of an empty road)
  end
  self.chosenSpot = sp
  self.dest, self.stops, self.arrival = { sp.x, sp.y, sp.z or 0 }, nil, 'Parking Lot'
  self.internalTrip = true
  self.turnVia = nil
  if self.mode ~= 'off' then self.replanNow = true else self.path = nil end
  return true, nil, 'route'
end

-- Autopark v2: back into a perpendicular spot.
--  * the spot's own axis (the level's parking data) gives the direction the car ends in; the open side is found with rays
--  * a staging pose beside the spot (on either side), a smooth approach to it that respects the turning radius and is
--    checked for walls / curbs / cars, then the reverse arc in
--  * nothing fits (facing a wall, too close): a short straight move first, then again (up to 3 times)
local function unitv(x, y)
  local l = sqrt(x * x + y * y)
  if l < 1e-9 then return 0, 0 end
  return x / l, y / l
end

-- Is the stretch of path free of walls, curbs and cars? `pts` in the order of travel (forward or reverse); `skipEnd` metres at the
-- end are not checked with rays (the back of a spot is a wall on purpose).
-- Height of the ground at (x, y), from a ray cast straight down from zTop; nil when nothing is hit within 5 m. Cached per autopark.
function Planner:groundAt(cast, x, y, zTop)
  self.gcache = self.gcache or {}
  local key = math.floor(x / 0.3) * 100003 + math.floor(y / 0.3)
  local c = self.gcache[key]
  if c ~= nil then return c or nil end
  local d = cast(x, y, zTop, 0, 0, -1, 5)
  local g = d and (zTop - d) or false
  self.gcache[key] = g
  return g or nil
end

function Planner:pathClear(pts, ego, cars, skipEnd, overhang)
  local cast = self.castRay
  local wid = (ego.wid or 1.9) * 0.5 + 0.1 + ((self.apActive and tonumber(self.apActive.margin)) or 0)
  local over = overhang or 2.6
  local total = Mv.length(pts)
  local run = 0
  local prevG = {}
  for i = 1, #pts - 1 do
    local a, b = pts[i], pts[i + 1]
    local dx, dy = unitv(b.x - a.x, b.y - a.y)
    run = run + sqrt((b.x - a.x) ^ 2 + (b.y - a.y) ^ 2)
    for _, c in ipairs(cars or {}) do
      local rr = c.blocked and 1.5 or 3.2
      if (c.x - a.x) ^ 2 + (c.y - a.y) ^ 2 < rr * rr then return false, 'car' end
    end
    if cast and i % 2 == 1 and run < total - (skipEnd or 0) then
      -- curbs, steps and drops: the ground under the car's line and both sides must not jump between neighbouring samples
      local zTop = ((a.z or ego.z or 0) + (ego.z or a.z or 0)) * 0.5 + 1.5
      for k, off in ipairs({ 0, wid, -wid }) do
        local ox, oy = a.x + -dy * off, a.y + dx * off
        local g = self:groundAt(cast, ox, oy, zTop)
        local pg = prevG[k]
        if pg ~= nil and g ~= nil and math.abs(g - pg) > 0.09 then return false, 'curb' end
        if pg ~= nil and g == nil then return false, 'drop' end
        prevG[k] = g
      end
      -- the car's footprint: rays from the centre out to the body outline at every sample (an object that would end up inside the car,
      -- e.g. a wall or pole the nose or a corner swings into on a turn)
      if i % 3 == 1 then
        local zf = (a.z or ego.z or 0) + 0.5
        local hl, hw = (ego.len or 4.8) * 0.5, wid
        for _, ang in ipairs({ 0, 0.4, -0.4, 1.57, -1.57, 2.74, -2.74, 3.14159 }) do
          local ca, sa = math.cos(ang), math.sin(ang)
          -- distance from the centre to the outline of the rectangle in this direction
          local tx = math.abs(ca) > 1e-6 and hl / math.abs(ca) or 1e9
          local ty = math.abs(sa) > 1e-6 and hw / math.abs(sa) or 1e9
          local reach = math.min(tx, ty) + 0.2
          local rx, ry = dx * ca - dy * sa, dx * sa + dy * ca
          if cast(a.x, a.y, zf, rx, ry, 0, reach) then return false, 'body' end
        end
      end
      for _, h in ipairs({ 0.6, 0.22 }) do
        local z = (a.z or ego.z or 0) + h
        -- close together (poles are thin): 7 rays across the car's width
        for _, off in ipairs({ 0, wid * 0.33, -wid * 0.33, wid * 0.66, -wid * 0.66, wid, -wid }) do
          local ox, oy = a.x + -dy * off, a.y + dx * off
          local hit = cast(ox, oy, z, dx, dy, 0, over)
          if hit then return false, 'wall' end
        end
      end
    end
  end
  return true
end

-- Free distance from a point along a direction (nil-safe: 30 m when nothing is hit or there is no ray function).
function Planner:freeDist(x, y, z, dx, dy, dist)
  if not self.castRay then return dist end
  return self.castRay(x, y, (z or 0) + 0.6, dx, dy, 0, dist) or dist
end

-- The best way to the staging pose and back into the spot from `pose` ({x, y, z, hx, hy}); nil when nothing fits.
function Planner:autoparkStage(pose, ego, cars, spot, o, rmin, why)
  local R = rmin + 0.6
  local best
  for _, ds in ipairs({ 1, -1 }) do
    local d = { x = -o.y * ds, y = o.x * ds }
    for _, extra in ipairs({ 1.5, 4, 7, 10 }) do
      for _, r in ipairs({ R, R + 1.2 }) do
        local Q, rev = Mv.backInArc(spot, o, d, r, extra, self.apActive and tonumber(self.apActive.tail) or 4.5)
        local fwd, kf = Mv.feasibleBezier(pose, pose.hx, pose.hy, Q, d.x, d.y, rmin)
        local q = sqrt((Q.x - pose.x) ^ 2 + (Q.y - pose.y) ^ 2)
        local head0 = q > 0.1 and (pose.hx * (Q.x - pose.x) + pose.hy * (Q.y - pose.y)) / q or 1
        if kf and kf <= 1.1 / rmin and head0 > 0.05 then
          local okF, whyF = self:pathClear(fwd, ego, cars, 0, 2.6)
          local okR, whyR = self:pathClear(rev, ego, cars, 4.5, 2.6)
          if okF and okR then
            local score = Mv.length(fwd) + Mv.length(rev) + 25 * kf
            if not best or score < best.score then best = { score = score, fwd = fwd, rev = rev, Q = Q } end
          elseif why then
            why[#why + 1] = string.format('ds%d+%.1f r%.1f: fwd %s rev %s', ds, extra, r, okF and 'ok' or tostring(whyF), okR and 'ok' or tostring(whyR))
          end
        elseif why then
          why[#why + 1] = string.format('ds%d+%.1f r%.1f: kf %.3f head0 %.2f (limit %.3f)', ds, extra, r, kf or -1, head0, 1.1 / rmin)
        end
      end
    end
  end
  return best
end

-- The learned parking policy (trained by the practice runner, tools/practice): a linear Gaussian policy over a few features of
-- where the car is relative to the spot; its mean picks the autopark knobs. Must match features() in practice.mjs.
local AP_RANGE = { rmin = { 5, 8 }, fwdSpeed = { 1.8, 4.0 }, revSpeed = { 0.9, 2.0 }, tail = { 3, 6 }, margin = { 0, 0.8 } }
local AP_ORDER = { 'rmin', 'fwdSpeed', 'revSpeed', 'tail', 'margin' }
local function apFeatures(ego, sx, sy, ax, ay)
  local dx, dy = sx - ego.x, sy - ego.y
  local dist = math.max(0.5, sqrt(dx * dx + dy * dy))
  local rx, ry = ego.x - sx, ego.y - sy
  return {
    1, math.min(dist, 25) / 15,
    (ego.hx * dx + ego.hy * dy) / dist, (ego.hx * dy - ego.hy * dx) / dist,
    (rx * ax + ry * ay) / 15, (-rx * ay + ry * ax) / 15,
    math.abs(ego.hx * ax + ego.hy * ay),
  }
end
local function apPolicyAction(pol, f)
  local out = {}
  for _, k in ipairs(AP_ORDER) do
    local w = pol[k]
    local z = 0
    if type(w) == 'table' then for i = 1, #f do z = z + (tonumber(w[i]) or 0) * f[i] end end
    local r = AP_RANGE[k]
    out[k] = r[1] + (r[2] - r[1]) / (1 + math.exp(-z))
  end
  return out
end

-- A spot beside the road (open at both ends along its axis): parallel park into it from the lane the car is in.
function Planner:autoparkParallel(ego, cars, best, ax, ay, z)
  local px, py = -ay, ax -- across the spot's axis
  local side = (ego.x - best.x) * px + (ego.y - best.y) * py
  local nx, ny = px, py
  if side < 0 then nx, ny = -px, -py end -- toward the road (where the car is)
  local dxv, dyv = ny, -nx -- the driving direction: the spot is on its right
  local off = max(2.4, min(3.6, math.abs(side)))
  local spot = { x = best.x, y = best.y, z = z }
  local rmin = 6
  local q, segs = Mv.parallel(spot, { dx = dxv, dy = dyv, off = off }, rmin)
  local function stage(pose)
    local fwd, kf = Mv.feasibleBezier(pose, pose.hx, pose.hy, q, dxv, dyv, rmin)
    local q0 = sqrt((q.x - pose.x) ^ 2 + (q.y - pose.y) ^ 2)
    local head0 = q0 > 0.1 and (pose.hx * (q.x - pose.x) + pose.hy * (q.y - pose.y)) / q0 or 1
    if not (kf and kf <= 1.1 / rmin and head0 > 0.05) then self.apWhy = string.format('kf %.3f/%.3f head0 %.2f', kf or -1, 1.1 / rmin, head0); return nil end
    local okc, whyc = self:pathClear(fwd, ego, cars, 0, 2.6)
    if not okc then self.apWhy = 'path ' .. tostring(whyc); return nil end
    return fwd
  end
  local egoP = { x = ego.x, y = ego.y, z = ego.z or z, hx = ego.hx, hy = ego.hy }
  local fwd = stage(egoP)
  local revOk = self:pathClear(segs[1].pts, ego, cars, 3.5, 2.6)
  self:emit('autoparkPlan', { parallel = true, spot = { best.x, best.y }, found = fwd ~= nil and revOk, rev = revOk, why = self.apWhy, q = { q.x, q.y }, d = { dxv, dyv }, ego = { ego.x, ego.y, ego.hx, ego.hy } })
  if not revOk then return false, 'no room to parallel park there' end
  if fwd then
    self.mode = 'fsd'
    self.spot = best
    self.autoparkTries = 0
    self:startManeuver({ { dir = 1, pts = fwd, maxSpeed = 2.5, kind = 'autoparkApproach' }, segs[1], segs[2] }, 'park', 'autopark')
    return true
  end
  -- not reachable from here: a short straight move forward (or back) first, then again
  if (self.autoparkTries or 0) < 3 then
    local psi0 = math.atan2(ego.hy, ego.hx)
    local bestPre, bestCost
    for _, dirSign in ipairs({ 1, -1 }) do
      for _, cv in ipairs({ 0, 1 / (rmin * 1.15), -1 / (rmin * 1.15), 1 / (rmin * 0.95), -1 / (rmin * 0.95) }) do
        for _, len in ipairs({ 3, 5, 8, 12, 16 }) do
          local pts, ex, ey, epsi = Mv.rollOut(ego.x, ego.y, psi0, dirSign, cv, len)
          for _, pt in ipairs(pts) do pt.z = ego.z or z end
          local cost = len * (dirSign < 0 and 1.3 or 1)
          if (not bestCost or cost < bestCost) and self:pathClear(pts, ego, cars, 0, 2.6)
             and stage({ x = ex, y = ey, z = ego.z or z, hx = math.cos(epsi), hy = math.sin(epsi) }) then
            bestPre, bestCost = { pts = pts, dir = dirSign }, cost
          end
        end
      end
    end
    if bestPre then
      self.autoparkTries = (self.autoparkTries or 0) + 1
      self.mode = 'fsd'
      self.spot = best
      self:startManeuver({ { dir = bestPre.dir, pts = bestPre.pts, maxSpeed = bestPre.dir > 0 and 2.0 or 1.5, kind = 'autoparkReposition' } }, 'repeat', 'autopark')
      return true
    end
  end
  self.autoparkTries = 0
  return false, 'no room to maneuver into that spot'
end

function Planner:autopark(ego, cars, want, retry)
  local best, bd
  if not retry then self.apBlocked, self.apRetries, self.apFix, self.apFixBad = nil, 0, 0, nil end
  self.gcache = {}
  if self.apBlocked then -- places where an earlier try got stuck count as obstacles
    local c2 = {}
    for _, c in ipairs(cars or {}) do c2[#c2 + 1] = c end
    for _, b in ipairs(self.apBlocked) do c2[#c2 + 1] = { x = b.x, y = b.y, z = b.z, blocked = true } end
    cars = c2
  end
  if want then
    best = (not spotOccupied(want, cars, self.castRay)) and want or nil
  else
    for _, sp in ipairs(self.parking) do
      local d = sqrt((sp.x - ego.x) ^ 2 + (sp.y - ego.y) ^ 2)
      if d < 25 and self:spotAllowed(sp) and not spotOccupied(sp, cars, self.castRay) and (not bd or d < bd) then best, bd = sp, d end
    end
  end
  if not best then return false, 'no free parking spot nearby' end
  self.autoparkTries = self.autoparkTries or 0
  local z = best.z or ego.z or 0
  -- the spot's axis: the direction the car ends in (either way); without data: the way from the car to the spot
  local ax, ay
  if best.known and ((best.dx or 0) ~= 0 or (best.dy or 0) ~= 0) then ax, ay = unitv(best.dx, best.dy) else ax, ay = unitv(best.x - ego.x, best.y - ego.y) end
  -- the knobs: an explicit setting (the practice runner exploring), else the learned policy's mean, else the defaults
  local tune = self.settings.apTune
  if not tune and type(self.settings.apPolicy) == 'table' then
    local okp, act = pcall(function() return apPolicyAction(self.settings.apPolicy, apFeatures(ego, best.x, best.y, ax, ay)) end)
    if okp then tune = act end
  end
  tune = tune or {}
  self.apActive = tune
  local rmin = tonumber(tune.rmin) or 6
  -- the open side: where there is room in front of the spot; on a tie, the side the car is on
  local fPlus, fMinus = self:freeDist(best.x, best.y, z, ax, ay, 14), self:freeDist(best.x, best.y, z, -ax, -ay, 14)
  -- a spot on the roadside (the road runs along its axis, close by): parallel parking; lots have the axis across the aisle
  if self.graph then
    local e, _, ed = P.nearestEdge(self.graph, best.x, best.y, nil, nil, 12)
    if e then
      local na, nb = self.graph.nodes[e.a], self.graph.nodes[e.b]
      local ex, ey = unitv(nb.x - na.x, nb.y - na.y)
      if ed < (na.r or 4) + 3.5 and math.abs(ex * ax + ey * ay) > 0.85 then return self:autoparkParallel(ego, cars, best, ax, ay, z) end
    end
  end
  local onPlus = ((ego.x - best.x) * ax + (ego.y - best.y) * ay) >= 0
  local o
  if fPlus > fMinus + 3 then o = { x = ax, y = ay } elseif fMinus > fPlus + 3 then o = { x = -ax, y = -ay } else o = { x = (onPlus and ax or -ax), y = (onPlus and ay or -ay) } end
  local spot = { x = best.x, y = best.y, z = z }
  local egoP = { x = ego.x, y = ego.y, z = ego.z or z, hx = ego.hx, hy = ego.hy }
  local why = {}
  local plan = self:autoparkStage(egoP, ego, cars, spot, o, rmin, why)
  local pre, preCost
  if not plan and self.autoparkTries < 3 then
    -- a pre-move (forward or back, straight or on an arc) that leaves a pose the staging fits from
    local psi0 = math.atan2(ego.hy, ego.hx)
    for _, dirSign in ipairs({ 1, -1 }) do
      for _, cv in ipairs({ 0, 1 / (rmin * 1.15), -1 / (rmin * 1.15) }) do
        for _, len in ipairs({ 3, 5, 8, 12 }) do
          local pts, ex, ey, epsi = Mv.rollOut(ego.x, ego.y, psi0, dirSign, cv, len)
          for _, p in ipairs(pts) do p.z = ego.z or z end
          local okP = self:pathClear(pts, ego, cars, 0, 2.6)
          if okP then
            local np = { x = ex, y = ey, z = ego.z or z, hx = math.cos(epsi), hy = math.sin(epsi) }
            local pl = self:autoparkStage(np, ego, cars, spot, o, rmin, nil)
            if pl then
              local cost = len * (dirSign < 0 and 1.3 or 1) + pl.score
              if not preCost or cost < preCost then preCost, pre = cost, { pts = pts, dir = dirSign, len = len, curv = cv } end
            end
          end
        end
      end
    end
  end
  local rayDiag = {}
  if self.castRay then
    local bx, by = ego.x + ego.hx * 2.3, ego.y + ego.hy * 2.3
    for _, h in ipairs({ 0.1, 0.2, 0.3, 0.45, 0.6 }) do rayDiag[#rayDiag + 1] = string.format('%.2f:%s', h, tostring(self.castRay(bx, by, (ego.z or z) + h, ego.hx, ego.hy, 0, 6))) end
  end
  local function thin(pts) local out = {}; for i = 1, #pts, 3 do out[#out + 1] = { math.floor(pts[i].x * 10 + 0.5) / 10, math.floor(pts[i].y * 10 + 0.5) / 10 } end; return out end
  self:emit('autoparkPlan', { spot = { best.x, best.y }, open = { o.x, o.y }, free = { fPlus, fMinus }, found = plan ~= nil, pre = pre and { dir = pre.dir, len = pre.len, curv = pre.curv } or nil,
    fwd = plan and thin(plan.fwd) or nil, rev = plan and thin(plan.rev) or nil, why = (not plan and not pre) and why or nil, ego = { ego.x, ego.y, ego.hx, ego.hy }, rays = rayDiag })
  if plan then
    self.mode = 'fsd'
    self.spot = best
    self.autoparkTries = 0
    self:startManeuver({ { dir = 1, pts = plan.fwd, maxSpeed = tonumber(tune.fwdSpeed) or 2.5, kind = 'autoparkApproach' }, { dir = -1, pts = plan.rev, maxSpeed = tonumber(tune.revSpeed) or 1.4, kind = 'backIn' } }, 'park', 'autopark')
    return true
  end
  if pre then
    self.autoparkTries = self.autoparkTries + 1
    self.mode = 'fsd'
    self.spot = best
    self:startManeuver({ { dir = pre.dir, pts = pre.pts, maxSpeed = pre.dir > 0 and 2.0 or 1.5, kind = 'autoparkReposition' } }, 'repeat', 'autopark')
    return true
  end
  self.autoparkTries = 0
  return false, 'no room to maneuver into that spot'
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

-- Driver asked to go left/right and there's no lane that way: turn at the next junction
-- that has a road that way (far enough ahead to do it calmly), then carry on to the
-- destination (or keep following the road).
function Planner:turnAtNext(dir, sCar, v, maxAhead, quiet)
  local path, g = self.path, self.graph
  if not path or not g then return false end
  local minAhead = max(25, v * 2.5)
  for i = 2, #path.pts do
    local p = path.pts[i]
    local ahead = path.s[i] - sCar
    if ahead > (maxAhead or 400) then break end
    if p.node and ahead > minAhead and (self.degree[p.node] or 0) >= 3 then
      local prev = path.pts[i - 1]
      local hx, hy = p.x - prev.x, p.y - prev.y
      local hl = sqrt(hx * hx + hy * hy)
      if hl > 1e-6 then
        hx, hy = hx / hl, hy / hl
        local nextNode
        for j = i + 1, min(#path.pts, i + 40) do if path.pts[j].node then nextNode = path.pts[j].node; break end end
        local best, bestScore
        local cn = g.nodes[p.node]
        for other, e in pairs(g.adj[p.node] or {}) do
          if other ~= nextNode and P.canTraverse(e, p.node) and e.drv >= 0.3 then
            local on = g.nodes[other]
            local ox, oy = on.x - cn.x, on.y - cn.y
            local ol = sqrt(ox * ox + oy * oy)
            if ol > 1e-6 then
              ox, oy = ox / ol, oy / ol
              local cross = hx * oy - hy * ox -- + = left
              local dot = hx * ox + hy * oy
              if (dir == 'left' and cross > 0.5) or (dir == 'right' and cross < -0.5) then
                local score = abs(dot) -- closest to a square turn
                if not bestScore or score < bestScore then best, bestScore = { other = other, ox = ox, oy = oy, len = ol }, score end
              end
            end
          end
        end
        if best then
          local d = min(20, best.len * 0.5)
          self.turnVia = { at = p.node, to = best.other, x = cn.x + best.ox * d, y = cn.y + best.oy * d, dir = dir, t = self.t }
          self.replanNow = true
          self:emit('turnRequest', { dir = dir, dist = ahead })
          return true
        end
      end
    end
  end
  if not quiet then self:emit('turnRequest', { dir = dir, none = true }) end
  return false
end

-- P pressed while FSD drives: pull over to the side of the road a little ahead, stop, P.
-- Grabbing the wheel, the brake or the accelerator cancels it (normal takeover).
function Planner:pullOverNow(ego)
  if self.mode == 'off' or not self.path then return false end
  local path = self.path
  local pr = P.project(path, ego.x, ego.y)
  if not pr then return false end
  local v = max(0, ego.v or 0)
  -- stopped: only far enough ahead to move over to the edge; moving: a stopping distance
  local sAt = min(path.s[#path.s] - 1, pr.s + (v < 1 and 18 or max(35, v * 4)))
  local qx, qy, qz = P.pointAt(path, sAt, pr.i)
  self.pullingOver = { saved = { dest = self.dest, stops = self.stops, arrival = self.arrival } }
  self.dest, self.stops, self.arrival, self.turnVia, self.chosenSpot = { qx, qy, qz or 0 }, nil, 'Pull Over', nil, nil
  self.replanNow = true
  self:emit('pullOver', { dist = floor(sAt - pr.s) })
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
function Planner:laneClear(k, onPath, sCar, v, egoLen, cut)
  cut = cut or 1
  for _, o in ipairs(onPath) do
    if o.dot > 0.3 and abs(o.lat - k * o.laneW) < o.laneW * 0.5 + (o.c.w or 1.9) * 0.5 - 0.2 then
      local rel = o.s - sCar
      local half = ((o.c.l or 4.6) + (egoLen or 4.6)) * 0.5
      if rel >= 0 then
        if rel - half < max(8, (v - o.vAlong) * 3 + 6) * cut then return false, o end
      else
        if -rel - half < max(6, (o.vAlong - v) * 3 + 6) * cut then return false, o end
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
  -- hit guard: the car's damage jumped while it was driving itself: stop at once instead of pushing on (curb, wall, another car)
  if ego.damage then
    if not self.dmgBase or self.mode == 'off' or ego.damage < self.dmgBase - 100 then self.dmgBase = ego.damage end
    local lim = self.maneuver and 450 or 2500
    local jump = ego.damage - self.dmgBase
    if self.mode ~= 'off' and jump > lim then
      self.dmgBase = ego.damage
      self.maneuver, self.kturn = nil, nil
      self.activity = 'drive'
      out.commands[#out.commands + 1] = { t = 'gear', gear = 'P' }
      self:emit('error', { detail = 'hit something (damage +' .. math.floor(jump) .. '), stopped' })
      self:disengage('error', 'collision')
      return out
    end
  end
  self.brain:observe(t, cars) -- read the traffic: swerving, cutting in, hard braking, parked
  self.tailCar = self.brain:tailgater(ego, cars) -- someone riding our bumper?
  for id, t0 in pairs(self.hangBack) do if t - t0 > 60 then self.hangBack[id] = nil end end

  -- supervision
  local lim = self.status and self.status.speedLimit
  local nagOut = self.nag:tick(t, self.mode ~= 'off' and self.mode ~= 'tacc' and self.activity ~= 'summon' and not self.unattended, self.profile, ego.attention,
    { v = ego.v or 0, limit = lim, highway = self.onHighway })
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
    -- off the path: plan again from here; if that doesn't bring us back onto it (a car park or field
    -- far from any road) give up instead of sitting there braking
    self.farTicks = (self.farTicks or 0) + 1
    local ok = self:planPath(ego, cars)
    if not ok then self:disengage('error', 'lost the road')
    elseif self.farTicks > 20 then self:disengage('error', 'too far from a road to drive') end
    return self:finish(out)
  end
  self.farTicks = 0
  self.hint = pr.i
  local S = path.s
  local sCar = pr.s
  local remaining = S[#S] - sCar
  local v = max(0, ego.v)
  self.status = {}
  local st = self.status
  st.remaining = (not path.openEnded) and remaining or nil
  st.speedLimit = path.limit[pr.i]
  -- point-to-point: as the destination comes up, offer the arrival choices (the app shows a
  -- sheet; if nobody answers FSD does what was picked earlier / its default)
  if self.dest and not self.exitDrive and not path.openEnded and remaining > 25 and remaining < max(120, v * 10) then
    local key = floor(self.dest[1] / 25) .. ',' .. floor(self.dest[2] / 25)
    if self.arrivingFor ~= key then
      self.arrivingFor = key
      local free = 0
      for _, sp in ipairs(self.parking) do
        if (sp.x - self.dest[1]) ^ 2 + (sp.y - self.dest[2]) ^ 2 < 100 * 100 and not spotOccupied(sp, cars, self.castRay) then free = free + 1 end
      end
      self:emit('arriving', { dist = floor(remaining), current = self.arrival or 'auto', freeSpots = free,
        options = { 'park', 'street', 'pullOver', 'driveway', 'takeOver', 'driveThru' } })
    end
  end
  self.onHighway = ((path.pts[pr.i].r or 0) >= 9) or nil -- wide multi-lane road

  if self.turnVia and (ego.x - self.turnVia.x) ^ 2 + (ego.y - self.turnVia.y) ^ 2 < 12 * 12 then
    self.turnVia = nil -- made the turn: later replans go straight to the destination
  elseif self.turnVia and self.t - (self.turnVia.t or self.t) > 30 then
    -- missed it (or circling around it): forget the turn and go straight to the destination
    self.turnVia = nil
    self.replanNow = true
  end
  if self.replanNow or (path.openEnded and remaining < 400) then
    self.replanNow = nil
    if not self:planPath(ego, cars) then self.turnVia = nil; self:planPath(ego, cars) end
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

  -- Autopilot (the old Autosteer: cruise + lane centering, no navigation): a bend it was not built for ends the steering at once.
  -- "Take over immediately", then it carries on as plain cruise control (mode 'tacc') until the driver steers or turns it off.
  if self.mode == 'autosteer' and v > 3 then
    local ahead = 40 + v * 3
    local kMax = 0
    for i = pr.i, #path.pts do
      if S[i] - sCar > ahead then break end
      local kk = math.abs(P.curvatureAt(path.pts, i, 3))
      if kk > kMax then kMax = kk end
    end
    -- a bend that needs under 25 mph at 2.5 m/s^2 sideways (radius under about 48 m), like a junction turn or a tight ramp
    if kMax > 0.0205 and v > math.sqrt(2.5 / kMax) - 1 then
      self.mode, steering = 'tacc', false
      self.curveAlertUntil = (self.t or 0) + 7
      self:emit('notice', { detail = 'Autopilot cannot take this bend: take over' })
    end
  end
  st.curveTakeover = (self.curveAlertUntil and (self.t or 0) < self.curveAlertUntil) or nil

  -- the next turn (lanes reset through it)
  local nextTurn
  for _, tn in ipairs(path.turns or {}) do
    if tn.s > sCar - 15 then nextTurn = tn; break end
  end
  self.nextTurnS = nextTurn and nextTurn.s or nil
  -- passed a turn: lane index resets
  if self.lastTurnS and sCar > self.lastTurnS + 15 then
    self.lane.k, self.lane.change, self.lastTurnS = 0, nil, nil
    self.syncLane = true
  end
  if nextTurn and sCar > nextTurn.s - 5 then self.lastTurnS = nextTurn.s end

  local iL0 = max(1, pr.i - 60)
  local look = { pts = {}, s = {}, i0 = iL0 }
  for i = iL0, i1 do look.pts[#look.pts + 1] = path.pts[i]; look.s[#look.s + 1] = S[i] end
  local onPath = self:carsOnPath(look, cars, egoPt)
  local nHere, wHere = self:laneAt(pr.i)
  -- After a new path or a turn the lane index starts at 0 (the right lane). If the car is really in another lane that made FSD swing
  -- sideways with no signal ("a hard turn for no reason" on a highway): take the index from where the car is.
  if self.syncLane and not self.lane.change then
    self.syncLane = nil
    if nHere and nHere > 1 and wHere and wHere > 0.5 then
      self.lane.k = clamp(floor(pr.lat / wHere + 0.5), 0, nHere - 1)
    end
  end
  local egoLen, egoWid = ego.len or 4.6, ego.wid or 1.9
  local maxSpeed = nil
  local waitingFor = nil
  local signal = nil
  local function cap(vv) maxSpeed = maxSpeed and min(maxSpeed, vv) or vv end
  -- a solid thing dead ahead (wall, barrier, closed road: the soak crashed at 24 m/s into one, twice at the same spot): slow down
  -- in time to stop with room to spare; the static rays reach 60 m, the emergency brake only starts at about 20 m
  if fsd and ego.wallAhead and v > 5 and abs(ego.yawRate or 0) < 0.12 then cap(sqrt(2 * 3.0 * max(0, ego.wallAhead - 8))) end
  -- nobody in the car (Banish / Summon): look for poles, posts and walls right ahead with a dense bundle of rays and stop short of them
  if self.unattended and v > 0.3 and self.castRay then
    local dObs = self:forwardClearDist(ego, 14)
    if dObs then cap(max(0, sqrt(2 * 2.0 * max(0, dObs - 1.3)))) end
  end

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
    local badlyParked = stationary and Brain.parkedQuality(o.dot, clearance) == 'bad'
    if badlyParked then
      -- angled or poking out: it may pull out or a door may open -> pass wider and slower
      want = max(want, 1.2)
      if fsd and rel > -2 and rel < 40 and clearance < 2.5 and clearance > -((c.w or 1.9) + egoWid) * 0.5 + 0.6 then cap(max(11, v * 0.9)) end
    end
    -- a pedestrian heading for the road: slow down early enough to stop, don't wait until they step out
    if fsd and (c.w or 2) < 1.2 and (c.l or 4) < 1.5 and rel > 2 and rel < 45 then
      local tr = self.brain:traits(c)
      local a, b = path.pts[o.i], path.pts[min(#path.pts, o.i + 1)]
      local tx, ty = b.x - a.x, b.y - a.y
      local tl = sqrt(tx * tx + ty * ty)
      if tr and tl > 1e-6 then
        local vLat = tr.vx * (-ty / tl) + tr.vy * (tx / tl)
        local eta = Brain.pedestrianEta(o.lat - ourSh, vLat, egoWid * 0.5 + 0.6)
        if eta and eta < rel / max(v, 1) + 1.5 then
          cap(max(3, sqrt(2 * 2.0 * max(0, rel - 4))))
          if not self.pedNoted[c.id or c] then self.pedNoted[c.id or c] = t; self:emit('brain', { what = 'pedestrian', eta = floor(eta * 10) / 10 }) end
        end
      end
    end
    -- a swerving car ahead in the next lane: hang back instead of pulling alongside it (for a while)
    if fsd and o.dot > 0.3 and rel > -3 and rel < 25 and clearance > 0 and clearance < 4 and self.brain:isErratic(c) then
      local hb = self.hangBack[c.id or c]
      if not hb then hb = t; self.hangBack[c.id or c] = hb; self:emit('brain', { what = 'erratic', id = c.id }) end
      if t - hb < 15 then cap(max(5, o.vAlong - 1)) end
    end
    -- school bus: slow way down when passing a stopped one
    if c.schoolBus and abs(c.v) < 0.5 and rel > -10 and rel < 80 and abs(o.lat) < 12 then
      st.schoolBus = true
      if rel < 75 then cap(4.5) end -- start slowing early: comfortable braking needs the room
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
      elseif o.dot > 0.3 and self.brain:cutInEta(ego, c) then
        -- sliding into our lane: follow it already (a driver eases off before it's all the way in)
        local rear = o.s - (c.l or 4.6) * 0.5 - egoLen * 0.5
        if not lead or rear < lead.s then lead = { s = rear, v = max(0, o.vAlong), o = o, cutIn = true } end
      end
    end
  end
  st.leadGap = lead and (lead.s - sCar) or nil

  ---------------------------------------------------------------- go around a blocking stopped car
  -- (only when allowed: settings.crossCenter. By default FSD does not cross the centre line on its own, it waits like a driver told not to)
  if fsd and self.settings.crossCenter == true and lead and lead.o.c and abs(lead.o.c.v) < 0.3 and (lead.o.c.stoppedFor or 0) > 5 and nHere == 1 and not path.pts[pr.i].ow
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
  if fsd and self.turnAround then stopS = self:turnAroundTick(ego, cars, sCar, v, stopS) end
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
  local boostScale = (self.lightBoostUntil and t < self.lightBoostUntil) and 1.1 or 1
  -- what we've learned about Quentin's style on this kind of road (FSD only, mild)
  local limNow = path.limit and path.limit[pr.i]
  local learnSpeed = self.learn and self.mode == 'fsd' and self.learn:speedScale(limNow) or 1
  -- the policy trained on his driving (rl/train_bc.py): an advisory nudge of at most +-8% on the speed
  -- caps, only when the setting is on; the limits, the brain and the safety layer all still apply
  if self.policy and self.settings.policy and self.mode == 'fsd' and limNow then
    if not self.polT or t - self.polT >= 0.2 then
      local dtp = self.polT and (t - self.polT) or 0.2
      self.polT = t
      local ctl = st.control
      local gap = st.leadGap and min(st.leadGap, 60) or 60
      local closing = (self.polGap and dtp > 0) and (self.polGap - gap) / dtp or 0
      local acc = (self.polV and dtp > 0) and (v - self.polV) / dtp or 0
      self.polGap, self.polV = gap, v
      local a = self.policy:act({ v, limNow, gap, closing, ctl and ctl.dist and min(ctl.dist, 80) or 80, (ctl and ctl.state == 'red') and 1 or 0, acc })
      self.polScale = (self.polScale or 1) + ((1 + 0.08 * clamp(a, -1, 1)) - (self.polScale or 1)) * 0.2
    end
    learnSpeed = learnSpeed * self.polScale
    st.policy = floor((self.polScale - 1) * 1000) / 10 -- % nudge, for diagnostics
  end
  if self.learn and self.mode == 'fsd' and self.learn.spotScale then learnSpeed = learnSpeed * self.learn:spotScale(ego.x, ego.y) end
  local learnGap = self.learn and self.mode == 'fsd' and self.learn:gapScale(limNow) or 1
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

  ---------------------------------------------------------------- confidence
  -- How sure FSD is right now (0..1): unreadable lights, busy junctions, going around things,
  -- bad weather, emergency vehicles, sharp curves taken too fast, being off its path.
  do
    local conf = 0.95
    local ctl = st.control
    if ctl and ctl.kind == 'signal' and ctl.state == nil and ctl.dist and ctl.dist < 45 then conf = conf - 0.45 end
    if waitingFor == 'crossTraffic' or waitingFor == 'gap' then
      self.busySince = self.busySince or t
      conf = conf - min(0.35, 0.1 + 0.04 * (t - self.busySince))
    else
      self.busySince = nil
    end
    if st.goAround then conf = conf - 0.2 end
    if st.emergency then conf = conf - 0.15 end
    if st.schoolBus then conf = conf - 0.15 end
    if st.creeping then conf = conf - 0.1 end
    conf = conf - 0.25 * (wx.rain or 0) - 0.3 * (wx.fog or 0)
    if pr.dist > 3 then conf = conf - min(0.4, 0.1 * (pr.dist - 3)) end
    local vc = path.vcap[pr.i]
    if vc and v > vc * 1.25 + 1 then conf = conf - 0.2 end
    conf = max(0, min(1, conf))
    self.conf = self.conf and (self.conf + (conf - self.conf) * min(1, 0.1 / 0.4)) or conf
    if self.conf < (self.settings.confidenceFloor or 0.55) then
      self.lowSince = self.lowSince or t
    else
      self.lowSince = nil
    end
    st.confidence = self.conf
    -- low for 1.5 s: ask the driver to take over (FSD keeps driving if they don't)
    st.lowConfidence = self.lowSince ~= nil and t - self.lowSince > 1.5 or nil
  end

  ---------------------------------------------------------------- caution (people and parked cars)
  -- Like FSD: slow down for someone on foot near the road ahead, and ease past parked cars
  -- close to the lane (a door could open) instead of driving by at full speed.
  for _, c in ipairs(cars) do
    if abs(c.v or 0) < 3 then
      local pj = P.project(win, c.x, c.y)
      if pj and pj.s > sCar - 2 and pj.s - sCar < 130 then
        local small = (c.w or 2) < 1.2 and (c.l or 4) < 1.5
        local latAbs = abs(pj.lat)
        -- allowed speed at distance d so we can still ease down to `target` at the comfortable rate
        local function easeTo(target)
          local d = max(0, pj.s - sCar - 4)
          return sqrt(target * target + 2 * (prof.decel or 1.8) * d)
        end
        if small and latAbs < 6 then
          cap(easeTo(latAbs < 2.8 and 2.5 or 5.5))     -- pedestrian at / near the road
          st.pedestrian = true
        elseif abs(c.v or 0) < 0.5 and latAbs > 1.0 and latAbs < 3.2 and (c.l or 4) > 3 then
          cap(easeTo(8.9))                              -- parked right beside the lane: <= 20 mph
        end
      end
    end
  end

  ---------------------------------------------------------------- turn signals
  -- FSD signals early: about 6 s before the turn, at least 60 m
  if not signal and nextTurn and nextTurn.s - sCar < max(60, v * 6) and nextTurn.s - sCar > -5 then signal = nextTurn.dir end
  if not signal and path.arrivalKind == 'curb' and remaining < 45 then signal = 'right' end
  if not signal and st.emergency and st.emergency.action == 'pullOver' then signal = 'right' end
  st.nextTurn = nextTurn and { dir = nextTurn.dir, dist = max(0, nextTurn.s - sCar), road = nextTurn.road or '' } or nil

  ---------------------------------------------------------------- forced stop (ignored nag)
  local hazard = false
  if nagOut.forceStop or self.emergency then
    -- unresponsive driver: hazards and alarm (the app beeps on the alert), slow down, then
    --  setting unresponsive = 'park' and a free spot within 500 m: drive there, park, P
    --  otherwise (or 'pullOver'): pull over to the curb a little ahead, stop, P
    -- (no hazard lights here: they are for a crash only)
    if not self.unresponsive then
      self.unresponsive = { t = t, saved = { dest = self.dest, stops = self.stops, arrival = self.arrival } }
      local kind = 'pullOver'
      if self.emergency or self.settings.unresponsive == 'park' then
        local sp, bd
        for _, cand in ipairs(self.parking) do
          local rx, ry = cand.x - ego.x, cand.y - ego.y
          local d = sqrt(rx * rx + ry * ry)
          -- an emergency takes a spot only if it is quick and ahead (about 8 s away); otherwise the roadside is safer
          local reach = not self.emergency or (d < 130 and d / max(v, 5) < 8 and rx * ego.hx + ry * ego.hy > 0.2 * d)
          if d < 500 and reach and self:spotAllowed(cand) and not spotOccupied(cand, cars, self.castRay) and (not bd or d < bd) then sp, bd = cand, d end
        end
        if sp then
          kind = 'park'
          self.chosenSpot = sp
          self.dest, self.stops, self.arrival = { sp.x, sp.y, sp.z or 0 }, nil, 'Parking Lot'
        end
      end
      if kind == 'pullOver' then
        local sAt = min(S[#S] - 1, sCar + max(50, v * 5))
        local qx, qy, qz = P.pointAt(path, sAt, pr.i)
        self.dest, self.stops, self.arrival = { qx, qy, qz or 0 }, nil, 'Pull Over'
      end
      self.turnVia = nil
      self.unresponsive.kind = kind
      self.replanNow = true
      self:emit('unresponsive', { action = kind, reason = self.nag.reason, mode = self.nag.active })
      self:emit('notice', { detail = string.format('no answer to the %s reminder (%s monitoring): %s. Settings > Autopilot > Driver Monitoring > Off stops this',
        tostring(self.nag.reason or 'attention'), tostring(self.nag.active or '?'), kind == 'park' and 'parking' or 'pulling over') })
    end
    cap(self.emergency and 9 or 11) -- ~20-25 mph
  elseif self.unresponsive then
    -- the driver answered: back to the original trip
    local sv = self.unresponsive.saved
    self.unresponsive = nil
    self.dest, self.stops, self.arrival, self.chosenSpot = sv.dest, sv.stops, sv.arrival, nil
    self.replanNow = true
    self:emit('unresponsive', { action = 'cancelled' })
  end

  ---------------------------------------------------------------- arrival
  -- Drove past the destination: it got close (< 30 m), is now moving away (25 m further than the closest) and nothing stopped us.
  -- Whatever went wrong with the route, don't drive on forever: pull over a little further along and finish the trip there.
  if self.dest and not self.exitDrive and not self.pullingOver and self.arrival ~= 'Take Over' and path.arrivalKind ~= 'driveThru' and v > 2 then
    local dd = sqrt((self.dest[1] - ego.x) ^ 2 + (self.dest[2] - ego.y) ^ 2)
    if not self.destMin or dd < self.destMin then self.destMin = dd end
    if self.destMin < 30 and dd > self.destMin + 25 then
      local sAt = min(S[#S] - 1, sCar + max(30, v * 4))
      local qx, qy, qz = P.pointAt(path, sAt, pr.i)
      self:emit('missedDest', { closest = floor(self.destMin), now = floor(dd) })
      self.dest, self.stops, self.arrival, self.turnVia, self.chosenSpot, self.destMin = { qx, qy, qz or 0 }, nil, 'Pull Over', nil, nil, nil
      self.replanNow = true
    end
  end
  local hold = false
  if self.exitDrive and not path.openEnded and remaining < 30 then
    -- rejoined the road after the drive-thru: no destination any more, just drive on
    self.exitDrive, self.leaveLot = nil, nil
    self.dest, self.arrival, self.path = nil, nil, nil
    self:planPath(ego, cars)
    out.route = self:routeMessage()
    return self:finish(out)
  end
  if not path.openEnded and remaining < 2.5 and v < 0.3 then
    hold = true
    if path.arrivalKind == 'driveThru' then
      -- the window: wait for the order (settings.driveThruWait seconds), then carry on along the road
      if not self.dtStart then
        self.dtStart = self.t
        self:emit('driveThru', { state = 'window' })
      end
      if self.t - self.dtStart < (self.settings.driveThruWait or 25) then return self:finish(out) end
      self.dtStart = nil
      self:emit('driveThru', { state = 'done' })
      -- back out onto the road (a route to a point further along it), then carry on with no destination
      local ex = self.exitPt
      self.dest, self.stops, self.arrival, self.spot, self.turnVia, self.chosenSpot, self.exitPt = ex, nil, ex and 'Drive On' or nil, nil, nil, nil, nil
      self.exitDrive = ex and true or nil
      self.leaveLot = true
      self:planPath(ego, cars)
      out.route = self:routeMessage()
      return self:finish(out)
    end
    if path.afterManeuver then
      local segs = path.afterManeuver
      path.afterManeuver = nil
      self.apFix, self.apFixBad = 0, nil
      self:startManeuver(segs, 'park', path.afterKind or 'backIn')
      return self:finish(out)
    end
    if not self.arrived then
      self.arrived = true
      local handOver = self.arrival == 'Take Over'
      if not handOver then out.commands[#out.commands + 1] = { t = 'gear', gear = 'P' } end
      if self:finishUnresponsive(out) then return self:finish(out) end
      self:emit('arrived', { detail = handOver and 'takeOver' or path.arrivalKind, destDist = self.dest and floor(sqrt((self.dest[1] - ego.x) ^ 2 + (self.dest[2] - ego.y) ^ 2)) or nil })
      self:disengage('arrived')
      self.dest, self.path = nil, nil
      out.route = self:routeMessage()
      return self:finish(out)
    end
  end

  ---------------------------------------------------------------- confusion: stopped and can't say why
  do
    local explained
    if waitingFor or self.hesitateUntil and t < self.hesitateUntil then explained = 'waiting'
    elseif stopS and stopS - sCar < 45 then explained = 'stopPoint'
    elseif lead and lead.s - sCar < 15 and lead.v < 1.5 then explained = 'car'
    elseif st.goAround or st.schoolBus or st.emergency or st.creeping then explained = 'situation'
    elseif maxSpeed and maxSpeed < 0.5 then explained = 'capped'
    elseif remaining < 40 and not path.openEnded then explained = 'arriving'
    elseif self.lane.change then explained = 'laneChange' end
    local lvl, rose = self.judge:watchStuck(t, { engaged = fsd, v = ego.v, explained = explained, dt = dt })
    st.stuck = lvl > 0 and lvl or nil
    if rose then
      local ctl = st.control
      self:emit('stuck', { level = rose, lead = lead and floor(lead.s - sCar) or nil, lane = self.lane.k, ctl = ctl and ctl.kind or nil, dist = ctl and ctl.dist and floor(ctl.dist) or nil,
        state = ctl and ctl.state or nil, speedCap = maxSpeed and floor(maxSpeed * 10) / 10 or nil, activity = self.activity })
      if rose == 1 then
        self.replanNow = true -- fresh route from where we are
      elseif rose == 2 then
        -- forget whatever stop / turn / wait state may be jamming us and try again
        self.stopFsm, self.cleared, self.lightStopped, self.redWait = {}, {}, {}, {}
        self.turnVia, self.leftCommitted, self.leftWaitSince, self.hesitateUntil = nil, false, nil, nil
        self.replanNow = true
      end
    end
    if lvl >= 3 then st.lowConfidence = true; self.conf = min(self.conf or 1, 0.3) end -- ask the driver to help
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
    vcap[#vcap + 1] = path.vcap[i] * wxScale * learnSpeed * boostScale
  end
  self.seq = self.seq + 1
  local gap = prof.gap * learnGap
  -- a lead that swerves or just braked hard gets more room
  local wary = lead and lead.o and (self.brain:isErratic(lead.o.c) or self.brain:hardBraked(lead.o.c, t, 8))
  if self.settings.followDistance then gap = 0.8 + (clamp(self.settings.followDistance, 1, 7) - 1) * 0.35 end
  if wary then gap = gap * 1.4 end
  if lead and lead.cutIn and (self.profile == 'sloth' or self.profile == 'chill' or self.profile == 'standard') then gap = gap * 1.25 end -- let it in
  -- virtual lidar (FSD only)
  self.lastCars = cars
  self:lidarAssist(ego, pr, sCar, v, cap, fsd)
  if fsd and self.lidar then
    -- always filled (the black box keeps it; the app only draws it when Service Mode asks)
    st.lidar = self.lidar:debugPoints()
    local lo = self.lidarOut
    if lo then st.lidarInfo = { gap = lo.gap and floor(lo.gap * 10 + 0.5) / 10 or nil, nudge = lo.nudge and floor(lo.nudge * 100 + 0.5) / 100 or nil, curb = lo.curb, blocked = lo.blocked or nil } end
  end
  if self.lidarTryRecover then
    self.lidarTryRecover = nil
    if self:recoverStuck(ego, cars, out, 'wall ahead', 1) then return self:finish(out) end
  end
  -- stuck while it should be moving (against a curb or wall, wheels spinning): stop instead of pushing on
  do
    local wantsMove = (maxSpeed or 0) > 2 and not hold and not hazard and not lead and not wary and not self.maneuver
      and not (stopS and stopS - sCar < 30) and ego.gear ~= 'P'
    if self.mode == 'fsd' and wantsMove and (ego.v or 0) < 0.35 then self.stuckT = (self.stuckT or 0) + dt else self.stuckT = 0 end
    if self.stuckT > 6 then
      self.stuckT = 0
      out.commands[#out.commands + 1] = { t = 'gear', gear = 'P' }
      self:emit('error', { detail = 'stuck: something is blocking the car, stopped' })
      self:disengage('error', 'stuck')
      return out
    end
  end
  -- Furious Max stunts: on a clear, straight stretch it weaves (swings from side to side) or darts across the lane. Only the driven
  -- line is moved (inside the lane); the safety layer, the stops and the cars ahead are still obeyed. Knobs: settings.driftTune.
  if self.profile == 'furious' and self.settings.stunts ~= false and self.mode == 'fsd' and not lead and not hold and not hazard
     and not (st.weather and (st.weather.rain > 0.3 or st.weather.fog > 0.3)) and (not stopS or stopS - sCar > 160)
     and (ego.v or 0) > 12 and (ego.v or 0) < 34 and self.t >= (self.stuntCool or 0) then
    local tn = self.settings.driftTune or {}
    local clear = true
    for _, c in ipairs(cars or {}) do
      if (c.x - ego.x) ^ 2 + (c.y - ego.y) ^ 2 < 70 ^ 2 then clear = false; break end
    end
    if clear and self:junctionNear(ego.x, ego.y, 110) then clear = false end
    if clear then
      for i = pr.i, #path.pts - 1 do
        local si = path.s[i] - sCar
        if si > 130 then break end
        if si > 0 and math.abs(P.curvatureAt(path.pts, i, 3)) > 0.006 then clear = false; break end
      end
    end
    if clear then
      local _, w = self:laneAt(pr.i)
      local amp = math.min(tonumber(tn.weaveAmp) or 1.3, (w or 3.4) * 0.45)
      local gap = tonumber(tn.weaveGap) or 38
      local kind = (math.random() < 0.65) and 'weave' or 'dart'
      local n = (kind == 'weave') and 3 or 1
      local sgn = (math.random() < 0.5) and 1 or -1
      for k = 1, n do
        local s0 = sCar + 45 + (k - 1) * gap
        self.bumps[#self.bumps + 1] = { s0 = s0, s1 = s0 + 6, off = sgn * amp * ((k % 2 == 1) and 1 or -1), ramp = (kind == 'dart') and 9 or 15, kind = 'stunt' }
      end
      self.stuntCool = self.t + (tonumber(tn.stuntEvery) or 22)
      self:emit('stunt', { kind = kind })
    end
  end
  st.brain = (wary or (lead and lead.cutIn)) and { wary = wary or nil, cutIn = lead.cutIn or nil } or nil
  out.plan = {
    seq = self.seq, pts = flat, vcap = vcap, dir = 1,
    stopS = stopS and (stopS - sBase) or nil,
    lead = lead and { s = lead.s - sBase, v = lead.v } or nil,
    signal = signal or false, hazard = hazard,
    hold = hold, openEnded = path.openEnded or false,
    gapTime = gap, throttleMax = clamp(prof.throttle * ACCEL[self.settings.accelMode or 'standard'].th, 0.2, 1), decel = prof.decel,
    accel = (prof.accel or 1.9) * ACCEL[self.settings.accelMode or 'standard'].th,
    rise = prof.rise * ACCEL[self.settings.accelMode or 'standard'].rise, feel = self.settings.steerFeel,
    driftTune = self.settings.driftTune,
    drift = (self.profile == 'furious' and self.settings.drift == true and not lead and not stopS and not hold and not hazard and not (st.weather and (st.weather.rain > 0.3 or st.weather.fog > 0.3)) and (self.mode == 'fsd')) or nil,
    maxSpeed = maxSpeed, wiggle = wiggle or nil,
    urgent = (self.urgentUntil and t < self.urgentUntil) or nil,
    mode = self.mode,
    easeId = (self.easeUntil and (self.t or 0) < self.easeUntil) and self.engageSeq or nil,
    maneuver = self.pullingOver and 'pullOver' or nil,
  }
  st.maxSpeed = maxSpeed
  return self:finish(out)
end

-- someone on foot (a small, slow road user) within r m of a point
function Planner:pedestrianNear(x, y, cars, r)
  for _, c in ipairs(cars or {}) do
    local small = (c.w or 2) < 1.2 and (c.l or 4) < 1.5
    if small and abs(c.v or 0) < 3 and (c.x - x) ^ 2 + (c.y - y) ^ 2 < r * r then return true end
  end
  return false
end

-- the junction a sign/light guards (cached)
function Planner:signalJunction(sg)
  self.sigJunction = self.sigJunction or {}
  local j = self.sigJunction[sg.id]
  if j == nil then
    j = self:junctionNear(sg.x, sg.y, 35) or false
    self.sigJunction[sg.id] = j
  end
  return j or nil
end

-- Which way does BeamNG's signal dir point: +1 = the direction traffic drives (toward the
-- junction), -1 = the way the light faces (toward drivers). Learned from the level: a
-- signal stands before its junction, so dir . (junction - signal) tells us. nil = unknown.
function Planner:signalDirConvention()
  if self.sigConv ~= nil then return self.sigConv or nil end
  local votes, n = 0, 0
  for _, sg in ipairs(self.signals) do
    if sg.dirx and not sg.prop then
      local j = self:signalJunction(sg)
      if j then
        local jx, jy = j.x - sg.x, j.y - sg.y
        local jl = sqrt(jx * jx + jy * jy)
        if jl > 3 then
          local d = (sg.dirx * jx + sg.diry * jy) / jl
          if abs(d) > 0.5 then votes = votes + (d > 0 and 1 or -1); n = n + 1 end
        end
      end
    end
  end
  -- a clear majority of at least 3 signals, else keep accepting both directions
  if n >= 3 and abs(votes) >= 0.6 * n then self.sigConv = votes > 0 and 1 or -1 else self.sigConv = false end
  return self.sigConv or nil
end

-- Stop-sign props have no direction: skip one that stands beside a road crossing ours
-- (it's for the cross street) rather than beside our own road.
function Planner:propFacesCrossRoad(sg, tx, ty, distOurs)
  self.propDir = self.propDir or {}
  local d = self.propDir[sg.id]
  if d == nil then
    local e, _, ed = P.nearestEdge(self.graph, sg.x, sg.y, nil, nil, 25)
    if e then
      local a, b = self.graph.nodes[e.a], self.graph.nodes[e.b]
      local ex, ey = b.x - a.x, b.y - a.y
      local el = sqrt(ex * ex + ey * ey)
      d = el > 1e-6 and { ex / el, ey / el, ed } or false
    else
      d = false
    end
    self.propDir[sg.id] = d
  end
  if not d then return false end
  -- its nearest road runs across ours (> 60 deg) and is clearly nearer than ours
  return abs(d[1] * tx + d[2] * ty) < 0.5 and d[3] + 3 < (distOurs or 1e9)
end

-- Where to stop for a sign/light: before the edge of the junction it guards (our nose
-- lands ~0.5 m short of the crossing road), else at the sign itself. Also where to creep to.
function Planner:stopLine(sg, win, sSign)
  local j = self:signalJunction(sg)
  if not j then return sSign, sSign + 3 end
  local pr = P.project(win, j.x, j.y)
  if not pr or pr.dist > 12 or pr.s < sSign - 25 or pr.s > sSign + 35 then return sSign, sSign + 3 end
  local edge = pr.s - (j.r or 4)
  -- driver stops its reference point 2 m before stopS; the nose sits ~2.3 m ahead of it
  return min(sSign, edge - 0.8), edge + 0.2, j
end

-- Stop signs (stop, 2 s, creep & peek, check cross traffic) and traffic lights (with
-- yellow-light hesitation). Returns stopS (global arc length), control status, waitingFor.
-- "Traffic Light and Stop Sign Control: confirm": after a stop FSD waits for the driver's go
-- (a tap on the accelerator, or the confirm button) before leaving the line.
function Planner:confirm(t) self.confirmT = t or self.t end
function Planner:takeConfirm(t, ego)
  if (ego and ego.throttle or 0) > 0.3 then return true end
  if self.confirmT and t - self.confirmT < 5 then self.confirmT = nil; return true end
  return false
end

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
        local a = win.pts[pr.i]; local b = win.pts[min(#win.pts, pr.i + 1)]
        local tx, ty = b.x - a.x, b.y - a.y
        local tl = sqrt(tx * tx + ty * ty)
        if tl > 1e-6 then tx, ty = tx / tl, ty / tl end
        local dot
        if okLat and sg.dirx then
          dot = tx * sg.dirx + ty * sg.diry
          -- facing our way only (once we know which way BeamNG's signal dir points)
          local conv = self:signalDirConvention()
          if conv then okLat = conv * dot > 0.6 else okLat = abs(dot) > 0.6 end
        end
        if okLat and sg.prop and self:propFacesCrossRoad(sg, tx, ty, pr.dist + 2) then okLat = false end
        if okLat then
          -- a light or sign past the centre of its junction belongs to the other direction
          local j = self:signalJunction(sg)
          if j then
            local pj = P.project(win, j.x, j.y)
            if pj and pj.dist < 12 and pr.s > pj.s + 1 then okLat = false end
          end
        end
        sg.dbg = { dot = dot, lat = pr.lat }
        local fsm = self.stopFsm[sg.id]
        local waiting = fsm and fsm.state ~= 'done' and fsm.state ~= 'approach'
        local relevant = okLat and (pr.s > sCar - 3 or waiting)
        if relevant and not waiting then
          -- once our reference point reaches the stop line we're committed: a light or sign
          -- whose line is behind us (e.g. the far-side light for the other direction, whose
          -- line is the edge of the junction we're already in) must never stop the car
          local line = self:stopLine(sg, win, pr.s)
          local rw = self.redWait and self.redWait[sg.id]
          local heldAtRed = not (rw and rw.noted) and not self.cleared[sg.id] and sg.kind == 'signal' and v < 0.8 and line - sCar > -2.5 and sg.get and sg.get() == 'red'
          if line - sCar < 0.5 and not heldAtRed then
            relevant = false
            if fsm and fsm.state == 'approach' then
              -- overshot a stop sign's line: stopped here, it counts; still rolling, it's missed
              if v < 0.5 then fsm.state, fsm.t = 'stopped', t; relevant = true
              else fsm.state = 'done'; self.cleared[sg.id] = true; self.clearedS = pr.s end
            end
          end
        end
        if relevant and (not best or pr.s < best.s) then best = { sg = sg, s = pr.s } end
      end
    end
  end
  if not best then return nil, nil, waitingFor end
  local sg, sSign = best.sg, best.s
  local s, creepS, jn = self:stopLine(sg, win, sSign)
  local dist = s - sCar
  local control = { kind = sg.kind, dist = dist, red = false, id = sg.id,
    dot = sg.dbg and sg.dbg.dot, lat = sg.dbg and sg.dbg.lat }
  local stopS
  local stt = sg.kind == 'signal' and sg.get and sg.get() or nil
  if stt and sg.countdown and (self.settings.signalCountdown or 'off') ~= 'off' then
    local secs, to = sg.countdown()
    if secs then
      local m = self.settings.signalCountdown
      control.countdown, control.countTo = math.floor(secs * 10 + 0.5) / 10, to
      control.cdWheel = (m == 'wheel' or m == 'both') or nil
    end
  end

  -- a red that never changes while we wait at it (a broken or unreadable light) is treated
  -- like an all-way stop after 90 s, so FSD can't be stranded forever
  self.redWait = self.redWait or {}
  if stt == 'red' and v < 0.3 and dist < 8 then
    local rw = self.redWait[sg.id]
    if not rw then rw = { t = t }; self.redWait[sg.id] = rw end
    if t - rw.t > 90 then
      if not rw.noted then rw.noted = true; self:emit('signalStuck', { id = sg.id }) end
      stt = 'stop'
    end
  elseif stt ~= 'red' then
    self.redWait[sg.id] = nil
  end

  -- a signal in a stop state ('basicstop') with no stop sign near it is a painted line or a
  -- crosswalk: Quentin's rule is no full stop there, only for a pedestrian in the way
  if stt == 'stop' and sg.signNear == false and not sg.flashing then
    control.kind, control.red = 'crosswalk', false
    if self:pedestrianNear(sg.x, sg.y, cars, 7) then
      control.red = true
      return s, control, 'pedestrian'
    end
    return nil, control, waitingFor
  end

  -- stop signs, and signals showing an all-way stop (flashing red / stop state)
  if sg.kind == 'stop' or stt == 'stop' then
    control.kind = 'stop'
    if self.cleared[sg.id] or sSign <= self.clearedS + 25 then return nil, control, waitingFor end
    local fsm = self.stopFsm[sg.id]
    if not fsm then fsm = { state = 'approach' }; self.stopFsm[sg.id] = fsm end
    control.red = true
    if fsm.state == 'approach' then
      stopS = s
      -- stopped at the line, or stopped short of it for a while (e.g. behind a car that left)
      if v < 0.3 then fsm.still = fsm.still or t else fsm.still = nil end
      if v < 0.3 and (dist < 6 or (dist < 20 and t - fsm.still > 2.5)) then fsm.state, fsm.t = 'stopped', t end
    elseif fsm.state == 'stopped' then
      stopS = s
      if t - fsm.t >= (STOP_DWELL[self.profile] or 1.0) then
        if self.settings.quirks.creep then fsm.state, fsm.t = 'creep', t else fsm.state, fsm.t = 'peek', t end
      end
    elseif fsm.state == 'creep' then
      -- inch forward to see around the corner (nose to the edge of the crossing road)
      stopS = creepS
      cap(1.3)
      self.status.creeping = true
      if not fsm.noted then fsm.noted = true; self:emit('creeping', {}) end
      if v < 0.2 and (creepS - 2) - sCar < 1.2 or t - fsm.t > 5 then fsm.state, fsm.t = 'peek', t end
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
        if t - fsm.clearSince > 0.3 and self.settings.trafficControl == 'confirm' and not self:takeConfirm(t, ego) then
          waitingFor = 'confirm'
          if not fsm.asked then fsm.asked = true; self:emit('confirmGo', { what = 'stopSign' }) end
        elseif t - fsm.clearSince > 0.3 then
          fsm.state = 'done'
          self.cleared[sg.id] = true
          self.clearedS = sSign
          -- the classic FSD go-stop-go hesitation, now and then
          if self.settings.quirks.hesitate and self.rng() < 0.15 then self.hesitateUntil = t + 1.5 end
          stopS = nil
        end
      end
    end
    control.dist = dist
    return stopS, control, waitingFor
  end

  -- traffic light
  control.state = stt
  control.red = stt == 'red'
  -- how long has it been this colour? (only trustworthy if we watched it change)
  local la = self.lightAge[sg.id]
  if not la or la.state ~= stt then la = { state = stt, t = t, saw = la ~= nil }; self.lightAge[sg.id] = la end
  self.lightStopped = self.lightStopped or {}
  if stt == 'red' and v < 0.5 and dist < 10 then self.lightStopped[sg.id] = t end
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
    -- Mad Max / Furious: a yellow we can make -> put the foot down and clear it
    if dec.go and (self.profile == 'madmax' or self.profile == 'furious') and dist > 0 and v > 8 then
      self.lightBoostUntil = t + 2.5
    end
    if dec.hesitate and t - dec.t < 0.7 then cap(max(3, v - 2)) end
  else
    self.yellow[sg.id] = nil
    -- a green that has been green a long time is about to change: don't arrive at speed
    -- (the hurried profiles gamble on it, the careful ones get ready to stop)
    local careful = self.profile == 'sloth' or self.profile == 'chill' or self.profile == 'standard'
    if careful and la.saw and stt == 'green' and t - la.t > 20 and dist > 8 and dist < 45 and v > 6 then
      cap(max(5, sqrt(2 * 2.2 * max(0, dist - 2))))
      if not la.noted then la.noted = true; self:emit('brain', { what = 'staleGreen', age = floor(t - la.t) }) end
    end
    -- green after we stopped at it: in confirm mode wait for the driver's go
    local stoppedAt = self.lightStopped[sg.id]
    if stoppedAt and t - stoppedAt < 120 and self.settings.trafficControl == 'confirm' then
      if self:takeConfirm(t, ego) then
        self.lightStopped[sg.id] = nil
      else
        stopS = s
        waitingFor = 'confirm'
        if not control.asked then
          control.asked = true
          if self.lastConfirmAsk ~= sg.id then self.lastConfirmAsk = sg.id; self:emit('confirmGo', { what = 'light' }) end
        end
      end
    else
      self.lightStopped[sg.id] = nil
    end
  end
  return stopS, control, waitingFor
end

-- The next leg of a multi-point turn, with backups: the usual tight-but-safe leg first, then a tighter radius and smaller margins to the road
-- edge (a two-lane road is wide enough for a 3-point turn, it just needs the whole width). Returns the leg (or nil when the turn is done) and
-- whether one was found clear; a false means every variant hit something.
function Planner:kTurnLeg(ego, road, lastDir, cars)
  local first
  for _, v in ipairs({ { 6, 0.6 }, { 5.4, 0.4 }, { 5.0, 0.25 } }) do
    local seg = Mv.kTurnNext(ego, road, v[1], lastDir, v[2])
    if not seg then return nil, true end
    first = first or seg
    if self:segsClear({ seg }, ego, cars) then return seg, true end
  end
  return first, false
end

function Planner:laneChangeLogic(t, sCar, v, iCar, onPath, lead, nextTurn, egoLen, fsd)
  local lane = self.lane
  local path = self.path
  local n = P.laneModel(path.pts[iCar].r, path.pts[iCar].ow)
  local beh = self:beh()
  if lane.k > n - 1 and not lane.change then
    -- road narrowed under us: merge (the lane count comes from node widths, which jitter along a highway: it has to stay narrow a while,
    -- or FSD changed lanes "for no reason")
    lane.narrowSince = lane.narrowSince or t
    if t - lane.narrowSince > 2.5 then
      lane.change = { from = lane.k, to = n - 1, reason = 'merge', phase = 'signal', t = t }
    end
  else
    lane.narrowSince = nil
  end
  local ch = lane.change
  if ch then
    if ch.phase == 'signal' then
      if t - ch.t > beh.signalDelay then
        local ok = self:laneClear(ch.to, onPath, sCar, v, egoLen, beh.cut)
        if ok then
          ch.phase = 'moving'
          ch.s0 = sCar + v * 0.3
          ch.s1 = ch.s0 + clamp(v * 3.2, 20, 70)
          self:emit('laneChange', { dir = ch.to > ch.from and 'left' or 'right', reason = ch.reason })
        elseif t - ch.t > 6 then
          lane.change = nil -- gave up; try again later
          lane.cooldown = t + 8
        end
      end
    elseif ch.phase == 'moving' then
      if sCar > ch.s1 then
        lane.k = ch.to; lane.change = nil
        self.judge:laneChanged(t, ch.from, ch.to, ch.reason)
        -- route / merge / driver changes can follow quickly; the ones FSD chose (passing, fast lane, coming back) wait
        lane.cooldown = t + ((ch.reason == 'route' or ch.reason == 'merge' or ch.reason == 'driver' or ch.reason == 'moveOver') and 3 or 14)
        lane.lastDiscretionary = (ch.reason == 'pass' or ch.reason == 'madMax' or ch.reason == 'return') and t or lane.lastDiscretionary
      end
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
  if not want and lane.k > minN - 1 then
    lane.narrowAheadSince = lane.narrowAheadSince or t
    if t - lane.narrowAheadSince > 2.5 then want, reason = minN - 1, 'merge' end
  else
    lane.narrowAheadSince = nil
  end
  if not want and self.driverLaneRequest and t - self.driverLaneRequest.t < 1 then
    local dir = self.driverLaneRequest.dir
    local d = dir == 'left' and 1 or -1
    local k = lane.k + d
    local routeTurnsThatWay = nextTurn and nextTurn.dir == dir and nextTurn.s - sCar < 200
    if fsd and not routeTurnsThatWay and not self.turnVia and t - (self.lastTurnReqT or -1e9) > 15 and self:turnAtNext(dir, sCar, v, 150, true) then
      self.lastTurnReqT = t
      -- the turn signal means "turn there": a junction with a road that way coming up
    elseif k >= 0 and k <= minN - 1 then want, reason = k, 'driver'; self.lanePinUntil = t + 90 -- a lane the driver picked stays put
    elseif fsd and not routeTurnsThatWay and not self.turnVia and t - (self.lastTurnReqT or -1e9) > 15 then
      -- no lane that way (and never into oncoming traffic): take the next turn that way
      -- (once: a repeated request must not keep re-routing off the route)
      self.lastTurnReqT = t
      self:turnAtNext(dir, sCar, v)
    end
    self.driverLaneRequest = nil
  end
  if not want and self.moveOverRequest and lane.k < minN - 1 then want, reason = lane.k + 1, 'moveOver' end
  self.moveOverRequest = nil
  local pinned = self.lanePinUntil and t < self.lanePinUntil
  if not want and fsd and not prep and not pinned and self.tailCar and lane.k > 0 and (not lead or lead.v > v - 1) then
    -- someone is riding our bumper: get out of the way to the right instead of holding them up
    want, reason = lane.k - 1, 'yield'
    if not self.tailNoted then self.tailNoted = true; self:emit('brain', { what = 'tailgater' }) end
  elseif not self.tailCar then
    self.tailNoted = false
  end
  if not want and fsd and not prep then
    -- pass a slower car
    local cruise = path.vcap[iCar] or v
    local wantsPass = beh.pass and not pinned and lead and lead.s - sCar < 80 and lead.v < cruise - beh.pass and lane.k < minN - 1
    -- a car that is only slow for a moment (braking for a light, a lane change) isn't worth passing
    if wantsPass then lane.slowSince = lane.slowSince or t else lane.slowSince = nil end
    if wantsPass and t - lane.slowSince >= 2.5 then
      want, reason = lane.k + 1, 'pass'
    elseif beh.leftAbove and not pinned and minN >= 2 and v > beh.leftAbove and lane.k < minN - 1 and (not nextTurn or nextTurn.s - sCar > 1000) then
      -- hurry / Mad Max live in the fast lane at speed (still checked for a safe gap below)
      want, reason = lane.k + 1, 'madMax'
    elseif lane.k > 0 and not pinned and not (beh.leftAbove and v > beh.leftAbove * 0.8) then
      -- back to the right lane once clear (and not passing someone slower there)
      local slowerRight = false
      for _, o in ipairs(onPath) do
        if o.dot > 0.3 and o.lane == lane.k - 1 and o.s > sCar and o.s - sCar < 60 and o.vAlong < v - 1 then slowerRight = true end
      end
      -- and not right after passing: give it a while so it doesn't weave
      if not slowerRight and t - (lane.lastDiscretionary or -1e9) > 10 then want, reason = lane.k - 1, 'return' end
    end
  end
  if want and want ~= lane.k then
    local to = lane.k + (want > lane.k and 1 or -1)
    -- no lane changes right at a junction
    if nextTurn and nextTurn.s - sCar < 25 and reason ~= 'route' then return end
    -- is the target lane actually better? (m/s its nearest car ahead is faster than ours)
    local theirs, ours = 60, lead and lead.v or 60
    for _, o in ipairs(onPath) do
      if o.lane == to and o.dot > 0.3 and o.s > sCar and o.s - sCar < 80 and o.vAlong < theirs then theirs = o.vAlong end
    end
    local okJ, whyJ = self.judge:allowLane(t, lane.k, to, reason, theirs - ours)
    if not okJ then
      if not self.judgeNoted or t - self.judgeNoted > 20 then self.judgeNoted = t; self:emit('brain', { what = 'laneHold', why = whyJ, wanted = reason }) end
    elseif self:laneClear(to, onPath, sCar, v, egoLen, beh.cut) or reason == 'merge' or reason == 'route' then
      lane.change = { from = lane.k, to = to, reason = reason, phase = 'signal', t = t }
    end
  end
end

-- Backups for a maneuver that cannot go on (stuck against something, off its line, no room for the next leg). It used to stop dead and
-- hand the car back, wherever that was (once in the middle of the road). Now, in order:
--   1. back off 3 m (the way that is clear), then try the same thing again from there (parking: plan again; turn around: next leg)
--   2. back off 5 m and try again
--   3. a turn around is given up and the route goes on without it (no U-turn for 2 minutes); anything else pulls over to the side of the road
--   4. only if even that is impossible does FSD hand the car back
-- A new stuck spell more than 90 s after the last one starts at 1 again. Returns true while it is still handling it.
function Planner:recoverStuck(ego, cars, out, what, sdir, after)
  local r = self.rec
  if not r or self.t - r.t > 90 then r = { n = 0, t = self.t }; self.rec = r end
  r.t, r.n = self.t, r.n + 1
  self.maneuver = nil
  self.activity = 'drive'
  if r.n <= 2 then
    local len = r.n == 1 and 3 or 5
    for _, d in ipairs({ -(sdir or 1), sdir or 1 }) do
      local pts = {}
      for k = 0, len, 0.5 do pts[#pts + 1] = { x = ego.x + ego.hx * k * d, y = ego.y + ego.hy * k * d, z = ego.z or 0 } end
      if self:pathClear(pts, ego, cars, 0, 2.6) and not self:aheadBlocked(ego, d) then
        self:emit('notice', { detail = string.format('%s stuck: backing off %d m and trying again (%d)', tostring(what), len, r.n) })
        self:startManeuver({ { dir = d, pts = pts, maxSpeed = 1.2, kind = 'unstick' } }, after or 'drive', 'unstick')
        return true
      end
    end
  end
  if what == 'autopark' or what == 'backIn' then return false end -- the Banish supervisor tries the next spot
  if what == 'kTurn' and r.n <= 4 then
    self.kturn, self.turnAround = nil, nil
    self.noUturnUntil = self.t + 120
    self.replanNow = true
    out.commands[#out.commands + 1] = { t = 'gear', gear = 'D' }
    self:emit('notice', { detail = 'no room to turn around here: carrying on and routing another way' })
    return true
  end
  if self.mode == 'fsd' and self.path and r.n <= 5 and not self.pullingOver and self:pullOverNow(ego) then
    self:emit('notice', { detail = tostring(what) .. ' stuck: pulling over to the side instead of stopping in the road' })
    return true
  end
  return false
end

-- Forward/reverse segments (backing out, 3-point turn, back-in parking, summon, autopark).
function Planner:tickManeuver(ego, cars, out)
  local mv = self.maneuver
  if not mv then self.activity = 'drive'; return end
  local seg = mv.segs[mv.idx]
  local segPath = { pts = seg.pts, s = P.cumulative(seg.pts) }
  local pr = P.project(segPath, ego.x, ego.y)
  local remaining = segPath.s[#segPath.s] - (pr and pr.s or 0)
  local moving = abs(ego.v) > 0.3 -- (a car in D creeps at 0.15 m/s)
  self.status = { maneuver = { kind = mv.kind, step = mv.idx, total = #mv.segs, dir = seg.dir }, remaining = nil }
  -- failsafe: way off the maneuver's path (bad steering, pushed by something) -> stop, hand back
  if pr and pr.dist > 3 then
    if self:recoverStuck(ego, cars, out, mv.kind .. ' off course', seg.dir, (mv.kind == 'kTurn' and self.kturn) and 'kturn' or nil) then return end
    self.maneuver, self.kturn = nil, nil
    self.activity = 'drive'
    out.commands[#out.commands + 1] = { t = 'gear', gear = 'P' }
    self:emit('error', { detail = mv.kind .. ' went off course, stopped' })
    self:disengage('error', mv.kind .. ' off course')
    return
  end
  -- wrong gear (a Banish back-in sat in D for 4 s with the brake held and was called stuck): ask for the right one again, and don't
  -- start the "stuck" clock until the gear is right
  do
    local wantG = seg.dir < 0 and 'R' or 'D'
    local g = ego.gear
    if g and g ~= wantG and not (wantG == 'D' and g:sub(1, 1) == 'M') and not moving then
      if self.t - (mv.gearAsk or -9) > 0.7 then
        mv.gearAsk = self.t
        out.commands[#out.commands + 1] = { t = 'gear', gear = wantG }
      end
      mv.segT, mv.chkT, mv.chkPos = self.t, nil, nil
    end
  end
  -- stuck: told to move but not moving (a curb or wall under the nose, wheels spinning): stop instead of pushing on
  mv.segT = mv.segT or self.t
  if self.t - (mv.chkT or self.t) >= 2.0 then
    local moved = mv.chkPos and sqrt((ego.x - mv.chkPos[1]) ^ 2 + (ego.y - mv.chkPos[2]) ^ 2) or 99
    if remaining > 1.2 and self.t - mv.segT > 3 and moved < 0.3 then
      local sdir = seg and seg.dir or 1
      local spot = self.spot
      local kt = self.kturn
      self.maneuver, self.kturn = nil, nil
      self.activity = 'drive'
      if spot and (self.apRetries or 0) < 3 and (mv.kind == 'autopark' or mv.kind == 'backIn') then
        -- learn the obstacle (just ahead of the nose, or behind the tail) and plan again around it
        self.apRetries = (self.apRetries or 0) + 1
        self.apBlocked = self.apBlocked or {}
        self.apBlocked[#self.apBlocked + 1] = { x = ego.x + ego.hx * 2.2 * sdir, y = ego.y + ego.hy * 2.2 * sdir, z = ego.z }
        out.commands[#out.commands + 1] = { t = 'gear', gear = 'P' }
        local ok = self:autopark(ego, cars, spot, true)
        if ok then
          self:emit('notice', { detail = 'autopark: blocked, trying another way' })
          return
        end
      end
      if mv.kind ~= 'summon' then
        self.kturn = kt
        local after = (mv.kind == 'kTurn' and kt) and 'kturn' or ((mv.kind == 'autopark' or mv.kind == 'backIn') and spot) and 'repeat' or nil
        if self:recoverStuck(ego, cars, out, mv.kind, sdir, after) then return end
        self.kturn = nil
      end
      out.commands[#out.commands + 1] = { t = 'gear', gear = 'P' }
      self:emit('error', { detail = mv.kind .. ' is stuck (something is in the way), stopped' })
      self:disengage('error', mv.kind .. ' stuck')
      return
    end
    mv.chkPos, mv.chkT = { ego.x, ego.y }, self.t
  elseif not mv.chkT then
    mv.chkPos, mv.chkT = { ego.x, ego.y }, self.t
  end
  -- obstacle in the way (summon / autopark): stop
  local blocked = false
  for _, c in ipairs(cars) do
    local rx, ry = c.x - ego.x, c.y - ego.y
    local hx, hy = seg.dir < 0 and -ego.hx or ego.hx, seg.dir < 0 and -ego.hy or ego.hy
    local lon = rx * hx + ry * hy
    local lat = abs(-rx * hy + ry * hx)
    -- a back-in already checked against the parked cars (planBackIn) is not stopped by this straight-box test, which ignores the
    -- swing of the arc; only moving cars hold it
    local checked = seg.validated and abs(c.v or 0) < 0.3
    if not checked and lon > 0 and lon - ((ego.len or 4.6) + (c.l or 4.6)) * 0.5 < 1.5 and lat < ((ego.wid or 1.9) + (c.w or 1.9)) * 0.5 + 0.2 then blocked = true end
  end
  -- anything solid close ahead in the direction of travel (walls, poles, curbs) also holds the car; not at the very end of a leg
  -- (the spot's back wall is meant to be that close)
  if not blocked and remaining > 1.8 and self:aheadBlocked(ego, seg.dir) then blocked = true end
  if remaining < 0.6 and not moving then
    mv.dwell = mv.dwell + (self.t - (mv.lastT or self.t))
    if mv.dwell > 0.4 then
      if mv.kind == 'kTurn' and self.kturn then
        local nxt, clearN = self:kTurnLeg(ego, self.kturn.road, self.kturn.lastDir, cars)
        if nxt and not clearN then
          if self:recoverStuck(ego, cars, out, 'kTurn', mv.segs[mv.idx] and mv.segs[mv.idx].dir or 1, 'kturn') then return end
          self.maneuver, self.kturn = nil, nil
          self.activity = 'drive'
          out.commands[#out.commands + 1] = { t = 'gear', gear = 'P' }
          self:emit('error', { detail = 'turn around: no room to continue, stopped' })
          self:disengage('error', 'no room')
          return
        end
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
        if mv.after == 'repeat' and self.spot then
          -- a reposition move finished: plan the parking again from where we are
          local ok, err = self:autopark(ego, cars, self.spot, true)
          if not ok then
            out.commands[#out.commands + 1] = { t = 'gear', gear = 'P' }
            self:emit('error', { detail = 'autopark: ' .. tostring(err) })
            self:disengage('error', 'autopark ' .. tostring(err))
          end
          return
        end
        if mv.after == 'kturn' and self.kturn then
          -- backed off a blockage during a turn around: carry on with the turn from where the car is now
          local nxt, clearN = self:kTurnLeg(ego, self.kturn.road, nil, cars)
          if nxt and clearN then
            self.kturn.lastDir = nxt.dir
            self:startManeuver({ nxt }, 'drive', 'kTurn')
            return
          end
          self.kturn = nil
        end
        if mv.after == 'park' then
          -- where did we end up, against where the maneuver meant to (and the spot's own data)?
          local last = mv.segs[#mv.segs]
          local n = last and #last.pts or 0
          local err
          if n >= 2 then
            local a, b = last.pts[n - 1], last.pts[n]
            local tx, ty = b.x - a.x, b.y - a.y
            local tl = sqrt(tx * tx + ty * ty)
            if tl > 1e-6 then
              tx, ty = tx / tl, ty / tl
              local rx, ry = ego.x - b.x, ego.y - b.y
              local hxw, hyw = (last.dir or 1) * tx, (last.dir or 1) * ty -- the way the nose should point
              local dot = clamp(ego.hx * hxw + ego.hy * hyw, -1, 1)
              err = { lon = rx * tx + ry * ty, lat = -rx * ty + ry * tx, headingDeg = math.deg(math.acos(dot)) }
            end
          end
          -- Also measure against the stall itself (its painted axis from the level's data), not only against where the move meant to end:
          -- the car is "right" when it sits inside the lines, however the plan was drawn. The worse of the two counts.
          local sp0 = self.spot
          if err and sp0 and sp0.known and (sp0.dx or 0) ^ 2 + (sp0.dy or 0) ^ 2 > 0.25 then
            local al = sqrt(sp0.dx * sp0.dx + sp0.dy * sp0.dy)
            local ax, ay = sp0.dx / al, sp0.dy / al
            local bestC, bestD
            for _, c in ipairs({ { ax, ay }, { -ax, -ay }, { -ay, ax }, { ay, -ax } }) do
              local d = c[1] * ego.hx + c[2] * ego.hy
              if not bestD or d > bestD then bestC, bestD = c, d end
            end
            local h2 = math.deg(math.acos(clamp(bestD, -1, 1)))
            local rx, ry = ego.x - sp0.x, ego.y - sp0.y
            local lat2 = -rx * bestC[2] + ry * bestC[1]
            local lon2 = rx * bestC[1] + ry * bestC[2]
            if h2 <= 35 then -- (an axis far from the car's heading is not this stall's axis)
              if h2 > err.headingDeg then err.headingDeg = h2 end
              if abs(lat2) > abs(err.lat) then err.lat = lat2 end
              if abs(lon2) > abs(err.lon) then err.lon = lon2 end
            end
          end
          if err and sp0 and not sp0.known then
            -- no axis for this stall: the car's own heading stands in for it. The stall's middle should be on the car's centreline, so the
            -- sideways distance of the spot's position from that line is how far off the lines the car sits.
            local rx, ry = ego.x - sp0.x, ego.y - sp0.y
            local latC = -rx * ego.hy + ry * ego.hx
            if abs(latC) > abs(err.lat) then err.lat = latC end
          end
          -- Crooked or off the stall's middle (a car is about 1.9 m in a 2.5 m stall: 0.3 m each side): pull forward and back in again
          -- (up to 4 times, each only when it made things clearly better) instead of leaving it over the lines
          local badness = err and (err.headingDeg / 4 + abs(err.lat) / 0.3 + abs(err.lon) / 0.9) or 0
          -- (Quentin: a 7 degree error was "fixed" by pulling out of the stall and parking worse; a car about 1.9 m wide in a 2.5 m stall
          -- is still inside the lines at 8 degrees, so leave small errors alone)
          local worthIt = err and (err.headingDeg > 9 or abs(err.lat) > 0.4 or abs(err.lon) > 1.2)
          -- a second try only when the first one made it clearly better; otherwise this is as straight as the car gets
          if worthIt and (self.apFixBad or 1e9) - badness < 0.15 and (self.apFix or 0) > 0 then worthIt = false end
          self.apFixBad = badness
          if worthIt and self.spot and self.settings.parkFix ~= false and (mv.kind == 'autopark' or mv.kind == 'backIn') and (self.apFix or 0) < 4 then
            self.apFix = (self.apFix or 0) + 1
            local okFix = self:autopark(ego, cars, self.spot, true)
            if okFix then
              self:emit('notice', { detail = string.format('parking: %.0f deg off, %.1f m to the side: pulling forward to straighten up', err.headingDeg, err.lat) })
              mv.lastT = self.t
              return
            end
          end
          out.commands[#out.commands + 1] = { t = 'gear', gear = 'P' }
          if self:finishUnresponsive(out) then self.dest, self.path = nil, nil; out.route = self:routeMessage(); return end
          local sp = self.spot
          self:emit('arrived', { detail = 'parking', err = err, destDist = self.dest and floor(sqrt((self.dest[1] - ego.x) ^ 2 + (self.dest[2] - ego.y) ^ 2)) or nil,
            spot = sp and { x = sp.x, y = sp.y, dx = sp.dx, dy = sp.dy, known = sp.known } or nil,
            car = { x = ego.x, y = ego.y, hx = ego.hx, hy = ego.hy } })
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
      mv.segT, mv.chkT, mv.chkPos = self.t, nil, nil
    end
  else
    mv.dwell = 0
  end
  mv.lastT = self.t
  -- parking assist: the lidar looks in the direction of travel (the tail when reversing) and eases the car down as it closes in
  local segMax = seg.maxSpeed or 1.5
  if self.settings.lidar ~= false and self.castRay and (ego.v or 0) < 3 then
    local Ld = self.lidar or Lidar.new(function(x, y, z, dx, dy, dz, d) return self.castRay(x, y, z, dx, dy, dz, d) end)
    self.lidar = Ld
    Ld:scan(ego, seg.dir < 0 and -1 or 1, 6, self.t)
    local f = Ld:straightAhead((ego.wid or 1.9) * 0.5 + 0.1)
    if f then segMax = min(segMax, max(0.35, 0.35 + 0.5 * (f - (ego.len or 4.6) * 0.5 - 0.8))) end
    self.status = self.status or {}
    self.status.lidar = Ld:debugPoints()
    self.status.lidarRear = seg.dir < 0 or nil
    self.status.lidarInfo = { gap = f and floor((f - (ego.len or 4.6) * 0.5) * 10 + 0.5) / 10 or nil, rear = seg.dir < 0 or nil }
  end
  local flat, vcap = {}, {}
  for i, p in ipairs(seg.pts) do
    flat[#flat + 1] = p.x; flat[#flat + 1] = p.y; flat[#flat + 1] = p.z or 0
    vcap[i] = segMax
  end
  vcap[#vcap] = 0
  self.seq = self.seq + 1
  out.plan = {
    seq = self.seq, pts = flat, vcap = vcap, dir = seg.dir, maxSpeed = blocked and 0 or segMax,
    hold = blocked, openEnded = false, gapTime = 2, throttleMax = 0.45, signal = false, mode = self.mode,
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
  -- what the app shows: "Leaving parking spot", "Parking...", "Parked in ..."
  local mv = self.maneuver
  if self.mode == 'off' then
    local ld = self.lastDisengage
    st.phase = (ld and ld.reason == 'arrived' and self.t - (ld.time or -1e9) < 600) and 'parked' or nil
  elseif mv and (mv.kind == 'backOut' or mv.kind == 'kTurn') then
    st.phase = 'leaving'
  elseif mv and (mv.kind == 'backIn' or mv.kind == 'autopark') then
    st.phase = 'parking'
  elseif self.path and self.path.arrivalKind == 'parking' and st.remaining and st.remaining < 40 then
    st.phase = 'parking'
  else
    st.phase = 'driving'
  end
  if self.routeDirty then out.route = out.route or self:routeMessage(); self.routeDirty = false end
  out.status = st
  return out
end

return M
