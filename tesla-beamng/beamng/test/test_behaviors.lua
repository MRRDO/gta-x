-- FSD behaviors in a closed-loop world (planner + safety + driver + bicycle car + traffic).
-- Run: luajit beamng/test/test_behaviors.lua   (ONLY=name to run one scenario)

package.path = 'beamng/test/?.lua;beamng/mod/lua/common/?.lua;' .. package.path
local W = require('world')
local P = require('teslaBridge/pathing')

local failures, passes = 0, 0
local function check(cond, msg)
  if cond then passes = passes + 1 else failures = failures + 1; print('FAIL: ' .. msg) end
end
local ONLY = os.getenv('ONLY')
local function scenario(name, fn)
  if ONLY and ONLY ~= name then return end
  local ok, err = pcall(fn)
  if not ok then failures = failures + 1; print('FAIL: ' .. name .. ' crashed: ' .. tostring(err)) end
end

-- a straight east-west road of nodes every `step` m
local function straight(x0, x1, r, limit, step, extra)
  local nodes = {}
  step = step or 100
  local prev
  for x = x0, x1, step do
    local id = 'n' .. x
    nodes[id] = { pos = { x = x, y = 0, z = 0 }, radius = r, links = {} }
    if prev then nodes[prev].links[id] = { drivability = 1, oneWay = false, speedLimit = limit } end
    prev = id
  end
  if extra then extra(nodes) end
  return nodes
end

-- a city grid, blocks of `B` m, radius 5 (one lane each way)
local function grid(nx, ny, B, r)
  local nodes = {}
  for i = 0, nx do
    for j = 0, ny do
      nodes[i .. '_' .. j] = { pos = { x = i * B, y = j * B, z = 0 }, radius = r or 5, links = {} }
    end
  end
  for i = 0, nx do
    for j = 0, ny do
      local id = i .. '_' .. j
      if i < nx then nodes[id].links[(i + 1) .. '_' .. j] = { drivability = 1, oneWay = false, speedLimit = 13.4 } end
      if j < ny then nodes[id].links[i .. '_' .. (j + 1)] = { drivability = 1, oneWay = false, speedLimit = 13.4 } end
    end
  end
  return nodes
end

local function line(x0, y0, x1, y1, step)
  local pts = {}
  local L = math.sqrt((x1 - x0) ^ 2 + (y1 - y0) ^ 2)
  local n = math.max(1, math.floor(L / (step or 5)))
  for k = 0, n do pts[#pts + 1] = { x = x0 + (x1 - x0) * k / n, y = y0 + (y1 - y0) * k / n } end
  return pts
end

local RIGHT2 = -P.laneCenter(7.5, false, 0) -- y of the right lane (eastbound) on a 2+2 lane road
local LEFT2 = -P.laneCenter(7.5, false, 1)
local LANE1 = -P.laneCenter(5, false, 0)    -- y of the eastbound lane on a 1+1 road

---------------------------------------------------------------------------
scenario('pass', function()
  local w = W.new({ nodes = straight(0, 3000, 7.5, 25), ego = { x = 0, y = RIGHT2, psi = 0, v = 20 } })
  w:addCar({ id = 1, pts = line(120, RIGHT2, 3000, RIGHT2), speed = 12 })
  check(w:engage('fsd', 'standard'), 'engage on the highway')
  local minY, passedT = 0, nil
  w:run(60, function(ww)
    local _, y = ww:refPos()
    minY = math.max(minY, y)
    local c = ww.cars[1]
    if not passedT and ww:refPos() > c.x + 30 then passedT = ww.t end
    return passedT and ww.t > passedT + 20
  end)
  check(w:saw('laneChange', function(e) return e.reason == 'pass' end) ~= nil, 'changes lanes to pass the slow car')
  check(minY > LEFT2 - 0.8, string.format('uses the left lane (max y %.1f, left lane %.1f)', minY, LEFT2))
  check(passedT ~= nil, 'gets past the slow car')
  check(w:saw('laneChange', function(e) return e.reason == 'return' end) ~= nil, 'moves back to the right lane after passing')
  local _, y = w:refPos()
  check(math.abs(y - RIGHT2) < 0.8, string.format('ends in the right lane (y %.1f)', y))
  check(not w.collided, 'no collision while passing')
end)

scenario('passBlocked', function()
  -- a car sits in the left lane beside us for a while: wait for it before changing lanes
  local w = W.new({ nodes = straight(0, 3000, 7.5, 25), ego = { x = 0, y = RIGHT2, psi = 0, v = 12 } })
  w:addCar({ id = 1, pts = line(60, RIGHT2, 3000, RIGHT2), speed = 12 })
  -- sits right beside us (matching our speed) for 8 s, then pulls away
  w:addCar({ id = 2, pts = line(-10, LEFT2, 3000, LEFT2), s0 = 10, speedFn = function(t, c, ww)
    if t >= 8 then return 30 end
    local ex = ww:refPos()
    return math.max(0, ww.ego.v + (ex + 1 - c.x) * 2)
  end })
  w:engage('fsd', 'standard')
  w:run(25)
  local tChange = w:saw('laneChange', function(e) return e.reason == 'pass' end)
  check(tChange ~= nil, 'still passes once the lane is clear')
  check(tChange and tChange > 8, 'waits until the left lane is clear (changed at ' .. tostring(tChange) .. ')')
  check(not w.collided, 'no collision')
end)

scenario('stopSignCreep', function()
  local nodes = grid(2, 2, 150)
  local sigState = {}
  local w = W.new({ nodes = nodes, ego = { x = 5, y = LANE1, psi = 0, v = 0 },
    signals = { { id = 'stop1', x = 141, y = -7, z = 0, kind = 'stop' } } })
  -- cross traffic: southbound on x = 150 (its lane is x = 150 - 1.85), arrives around when we peek
  local south = line(150 - 1.85, 150, 150 - 1.85, -150, 5)
  w:addCar({ id = 7, pts = south, speedFn = function(t, c, ww)
    local fsm = ww.planner.stopFsm.stop1
    if fsm and (fsm.state == 'creep' or fsm.state == 'peek') then c.go = true end
    return c.go and 12 or 0
  end, s0 = 60 })
  w.planner:setRoute({ 300, LANE1, 0 }, nil, 'Driveway')
  check(w:engage('fsd', 'standard'), 'engage on the grid')
  local stoppedAtLine, crossedBeforeCar = false, false
  w:run(60, function(ww)
    local x, y = ww:refPos()
    if ww.planner.stopFsm.stop1 and ww.planner.stopFsm.stop1.state == 'stopped' then stoppedAtLine = true end
    local c = ww.cars[1]
    if x > 150 and c.y > 0 then crossedBeforeCar = true end
    return ww:saw('arrived')
  end)
  check(stoppedAtLine, 'full stop at the stop sign')
  check(w:saw('creeping') ~= nil, 'creeps forward to peek')
  check(w.status and true, 'status reported')
  local waited = false
  for _, e in ipairs(w.events) do if e.kind == 'creeping' then waited = true end end
  check(not crossedBeforeCar, 'lets the cross traffic go first')
  check(w:saw('arrived') ~= nil, 'arrives after the stop sign')
  check(not w.collided, 'no collision at the stop sign')
end)

scenario('unprotectedLeft', function()
  local nodes = grid(3, 2, 150)
  local w = W.new({ nodes = nodes, ego = { x = 50, y = LANE1, psi = 0, v = 8 } })
  -- oncoming (westbound) traffic on y = +1.85 toward the junction at (150, 0)
  for k = 0, 2 do
    w:addCar({ id = 10 + k, pts = line(215 + k * 35, -LANE1, -150, -LANE1), speed = 11 })
  end
  w.planner:setRoute({ 150 + LANE1, 140, 0 }, nil, 'Driveway') -- up the north road
  w:engage('fsd', 'standard')
  local turnedBefore = {}
  w:run(60, function(ww)
    local x, y = ww:refPos()
    if y > 8 then
      for _, c in ipairs(ww.cars) do if c.x > 150 then turnedBefore[#turnedBefore + 1] = c.id end end
      return true
    end
  end)
  check(w:saw('engaged') ~= nil, 'engaged')
  local waitedGap = false
  -- status history isn't kept; rerun check via event-free signal: we turned after all 3 passed
  check(#turnedBefore == 0, 'turns left only after the oncoming cars pass (' .. #turnedBefore .. ' still coming)')
  check(not w.collided, 'no collision on the left turn')
  local _ = waitedGap
end)

scenario('nudgeParked', function()
  local w = W.new({ nodes = straight(0, 1500, 5, 13.4), ego = { x = 0, y = LANE1, psi = 0, v = 10 } })
  -- parked half on the shoulder, half in our lane
  w:addCar({ id = 3, x = 150, y = LANE1 - 1.4, dx = 1, dy = 0 })
  w:engage('fsd', 'standard')
  local minV = 99
  w:run(30, function(ww)
    local x = ww:refPos()
    if x > 100 and x < 200 then minV = math.min(minV, ww.ego.v) end
    return x > 260
  end)
  check(w:saw('nudge') ~= nil, 'nudges over for the parked car')
  check(minV > 4, 'keeps rolling past it (min speed ' .. string.format('%.1f', minV) .. ')')
  check(not w.collided, 'no collision with the parked car')
end)

scenario('goAround', function()
  local w = W.new({ nodes = straight(0, 1500, 5, 13.4), ego = { x = 0, y = LANE1, psi = 0, v = 10 } })
  w:addCar({ id = 4, x = 150, y = LANE1, dx = 1, dy = 0 })
  w.cars[1].stoppedFor = 10
  w:engage('fsd', 'standard')
  w:run(60, function(ww) return ww:refPos() > 230 end)
  check(w:saw('goAround') ~= nil, 'goes around the stopped car')
  check(w:refPos() > 230, 'gets past it')
  check(not w.collided, 'no collision going around')
  w:run(10)
  local _, y = w:refPos()
  check(math.abs(y - LANE1) < 0.8, string.format('back in its lane (y %.1f)', y))
end)

scenario('emergencyVehicle', function()
  local w = W.new({ nodes = straight(-500, 2000, 5, 17), ego = { x = 0, y = LANE1, psi = 0, v = 14 } })
  -- police with lights, coming up behind fast (it passes on the left)
  w:addCar({ id = 9, pts = line(-160, LANE1, 2000, LANE1), speedFn = function(t, c, ww)
    local ex = ww:refPos()
    if c.x > ex - 20 and c.x < ex + 30 then c.passing = true end
    return 28
  end, emergency = true })
  -- the EV swerves into the oncoming lane to pass
  local ev = w.cars[1]
  w:engage('fsd', 'standard')
  local minV, passed = 99, false
  w:run(40, function(ww)
    local x = ww:refPos()
    if ev.x > x - 60 and ev.x < x + 10 then ev.y = -LANE1 else ev.y = LANE1 end
    if ev.x < x then minV = math.min(minV, ww.ego.v) end
    if ev.x > x + 40 then passed = true end
    return passed and ww.t > 25
  end)
  check(w:saw('emergencyVehicle') ~= nil, 'notices the emergency vehicle')
  check(minV < 1, 'pulls over and stops for it (min speed ' .. string.format('%.1f', minV) .. ')')
  check(passed and w.ego.v > 5, 'drives on after it passes')
end)

scenario('schoolBus', function()
  local w = W.new({ nodes = straight(0, 1500, 6, 17), ego = { x = 0, y = LANE1, psi = 0, v = 15 } })
  w:addCar({ id = 5, x = 200, y = -5.2, dx = 1, dy = 0, l = 11, w = 2.5, schoolBus = true })
  w.cars[1].stoppedFor = 20
  w:engage('fsd', 'standard')
  local vNear = 99
  w:run(40, function(ww)
    local x = ww:refPos()
    if x > 185 and x < 205 then vNear = math.min(vNear, math.max(ww.ego.v, 0)); vNear = math.max(vNear, 0) end
    return x > 260
  end)
  local maxNear = 0
  for _, p in ipairs(w.trace) do if p.x > 180 and p.x < 205 then maxNear = math.max(maxNear, p.v) end end
  check(w:saw('schoolBus') ~= nil, 'notices the school bus')
  check(maxNear < 6, string.format('creeps past the stopped school bus (max %.1f m/s)', maxNear))
  check(not w.collided, 'no collision with the bus')
end)

scenario('backInParking', function()
  local w = W.new({ nodes = straight(0, 1000, 5, 13.4), ego = { x = 0, y = LANE1, psi = 0, v = 0 },
    parking = { { x = 300, y = 9, z = 0, dx = 0, dy = 1 } } })
  w.planner:setRoute({ 300, 5, 0 }, nil, 'Parking Lot')
  check(w:engage('fsd', 'standard'), 'engage for parking')
  w:run(120, function(ww) return ww:saw('arrived') ~= nil end)
  local x, y = w:refPos()
  check(w:saw('maneuver', function(e) return e.what == 'backIn' end) ~= nil, 'backs into the spot')
  check(math.sqrt((x - 300) ^ 2 + (y - 9) ^ 2) < 1.8, string.format('parked in the spot (%.1f, %.1f)', x, y))
  local psi = w.ego.psi % (2 * math.pi)
  check(math.abs(psi - 1.5 * math.pi) < math.rad(25), 'facing out of the spot, heading ' .. math.deg(psi))
  check(w.ego.gear == 'P' and w.planner.mode == 'off', 'in Park, FSD off')
end)

-- "Street" arrival: find the free gap between two parked cars and parallel park in it
scenario('parallelPark', function()
  local w = W.new({ nodes = straight(0, 1000, 5, 13.4), ego = { x = 0, y = LANE1, psi = 0, v = 0 } })
  local curbY = -(5 - 1.1)
  -- parked cars at the curb: one blocks the spot nearest the destination, a gap behind it
  for _, px in ipairs({ 286, 266 }) do
    w:addCar({ id = px, pts = { { x = px, y = curbY }, { x = px + 1, y = curbY } }, speedFn = function() return 0 end, s0 = 0 })
  end
  w.planner:setRoute({ 300, -3, 0 }, nil, 'Street')
  check(w:engage('fsd', 'standard'), 'engage for street parking')
  w:run(150, function(ww) return ww:saw('arrived') ~= nil end)
  local x, y = w:refPos()
  check(w:saw('maneuver', function(e) return e.what == 'parallel' end) ~= nil, 'parallel parks')
  check(x > 268 and x < 284, string.format('in the gap between the parked cars (x %.1f)', x))
  check(math.abs(y - curbY) < 0.8, string.format('at the curb (y %.2f, curb %.2f)', y, curbY))
  local psi = (w.ego.psi + math.pi) % (2 * math.pi) - math.pi
  check(math.abs(psi) < math.rad(10), 'parallel to the road, heading ' .. string.format('%.1f', math.deg(psi)))
  check(not w.collided, 'no collision while parallel parking')
  check(w.ego.gear == 'P' and w.planner.mode == 'off', 'in Park, FSD off (street)')
end)

scenario('backOut', function()
  local w = W.new({ nodes = straight(0, 1000, 5, 13.4), ego = { x = 100, y = 9 - 1.4, psi = math.pi / 2, v = 0, gear = 'P' } })
  w.planner:setRoute({ 500, LANE1, 0 }, nil, 'Driveway')
  check(w:engage('fsd', 'standard'), 'engage in a parking spot')
  check(w.planner.activity == 'maneuver', 'starts with a maneuver')
  w:run(120, function(ww) return ww:saw('arrived') ~= nil end)
  check(w:saw('maneuver', function(e) return e.what == 'backOut' end) ~= nil, 'backs out of the spot')
  check(w:saw('arrived') ~= nil, 'then drives to the destination')
  check(not w.collided, 'no collision')
end)

scenario('threePointTurn', function()
  local w = W.new({ nodes = straight(0, 1000, 5, 13.4), ego = { x = 400, y = LANE1, psi = 0, v = 0, gear = 'P' } })
  w.planner:setRoute({ 100, -LANE1, 0 }, nil, 'Driveway')
  check(w:engage('fsd', 'standard'), 'engage facing the wrong way')
  w:run(150, function(ww) return ww:saw('arrived') ~= nil end)
  check(w:saw('maneuver', function(e) return e.what == 'kTurn' end) ~= nil, 'does a three-point turn')
  check(w:saw('arrived') ~= nil, 'then arrives')
  local x = w:refPos()
  check(x < 150, 'ended up west, x ' .. string.format('%.0f', x))
end)

scenario('summon', function()
  local w = W.new({ nodes = straight(0, 1000, 5, 13.4), ego = { x = 100, y = LANE1, psi = 0, v = 0, gear = 'P' } })
  local snap = w:snapshot()
  w.planner:summon('forward', snap.ego)
  w.nextPlan = 0
  w:run(30, function(ww) return ww:saw('summon', function(e) return e.state == 'done' end) ~= nil end)
  local x = w:refPos()
  check(x > 110 and x < 115, string.format('Dumb Summon moves ~12 m forward (x %.1f)', x))
  check(w.ego.gear == 'P', 'and parks')
end)

scenario('nag', function()
  local w = W.new({ nodes = straight(0, 20000, 5, 17), ego = { x = 0, y = LANE1, psi = 0, v = 15 } })
  w:engage('fsd', 'standard')
  w.attention = { state = 'phone', t = 0 }
  local levels = {}
  w:run(40, function(ww)
    ww.attention.t = ww.t
    return ww:saw('strike') ~= nil
  end)
  for _, e in ipairs(w.events) do if e.kind == 'nag' then levels[e.ev.level] = true end end
  check(levels[1] and levels[2] and levels[3], 'escalates 1 -> 2 -> 3 when on the phone')
  check(w:saw('strike') ~= nil, 'forced stop gives a strike')
  check(w.planner.mode == 'off' and w.ego.v < 0.5, 'car stopped and FSD off')
  -- nudges keep it quiet with no camera
  local w2 = W.new({ nodes = straight(0, 20000, 5, 17), ego = { x = 0, y = LANE1, psi = 0, v = 15 } })
  w2:engage('fsd', 'standard')
  w2.attention = { state = 'unknown', t = 0 } -- no camera: wheel nudges only
  w2:run(100, function(ww) if ww.t % 20 < 0.02 then ww.handsNudgeT = ww.t end end)
  check(w2:saw('strike') == nil and w2.planner.mode == 'fsd', 'wheel nudges every 20 s keep FSD on')
  local w4 = W.new({ nodes = straight(0, 20000, 5, 17), ego = { x = 0, y = LANE1, psi = 0, v = 15 } })
  w4:engage('fsd', 'standard')
  w4.attention = { state = 'unknown', t = 0 }
  w4:run(70)
  check(w4:saw('nag', function(e) return e.reason == 'hands' end) ~= nil, 'no camera and no nudges: hands-on-wheel nag')
  -- five strikes: locked out
  local w3 = W.new({ nodes = straight(0, 20000, 5, 17), ego = { x = 0, y = LANE1, psi = 0, v = 15 } })
  for _ = 1, 5 do
    w3:engage('fsd', 'standard')
    w3.attention = { state = 'phone', t = w3.t }
    w3:run(60, function(ww) ww.attention.t = ww.t; return ww.planner.mode == 'off' end)
    w3.attention = { state = 'ok', t = w3.t }
    w3.ego.v = 15
  end
  check(w3:saw('lockout') ~= nil, 'five strikes -> locked out')
  local ok = w3:engage('fsd', 'standard')
  check(not ok, 'cannot engage FSD when locked out')
end)

-- unresponsive driver: pull over to the curb (default), or with the setting on, drive to a
-- free parking spot nearby and park; either way P, hazards, a strike, FSD off
scenario('unresponsive', function()
  local w = W.new({ nodes = straight(0, 20000, 5, 17), ego = { x = 0, y = LANE1, psi = 0, v = 15 } })
  w:engage('fsd', 'standard')
  w.attention = { state = 'phone', t = 0 }
  w:run(90, function(ww) ww.attention.t = ww.t; return ww:saw('strike') ~= nil end)
  local _, y = w:refPos()
  check(w:saw('unresponsive', function(e) return e.action == 'pullOver' end) ~= nil, 'unresponsive: starts pulling over')
  check(y < LANE1 - 1.0, string.format('pulled over toward the curb (y %.2f, lane %.2f)', y, LANE1))
  check(y > -5 + 1.3, string.format('...without leaving the road (y %.2f)', y))
  check(w:saw('strike') ~= nil and w.planner.mode == 'off' and w.ego.v < 0.5, 'stopped, strike, FSD off')

  local w2 = W.new({ nodes = straight(0, 20000, 5, 17), ego = { x = 0, y = LANE1, psi = 0, v = 15 },
    parking = { { x = 420, y = 9, z = 0, dx = 0, dy = 1 } } })
  w2.planner:configure({ unresponsive = 'park' })
  w2:engage('fsd', 'standard')
  w2.attention = { state = 'phone', t = 0 }
  w2:run(160, function(ww) ww.attention.t = ww.t; return ww:saw('strike') ~= nil end)
  local x2, y2 = w2:refPos()
  check(w2:saw('unresponsive', function(e) return e.action == 'park' end) ~= nil, 'unresponsive + park setting: heads for the parking spot')
  check(math.sqrt((x2 - 420) ^ 2 + (y2 - 9) ^ 2) < 2.5, string.format('parked in the spot (%.1f, %.1f)', x2, y2))
  check(w2:saw('strike') ~= nil and w2.planner.mode == 'off', 'parked: strike, FSD off')
end)

-- driver monitoring modes (nagMode): off / camera / wheel, wheel interval by road context
scenario('monitoringModes', function()
  local N = require('teslaBridge/nag')
  -- road factors
  check(N.wheelFactor({ v = 5 }) == 2.0, 'wheel mode: slow (< 20 mph) -> fewer nags')
  check(N.wheelFactor({ v = 28, limit = 29 }) == 1.6, 'wheel mode: highway -> fewer nags')
  check(N.wheelFactor({ v = 15, limit = 15.6 }) == 0.7, 'wheel mode: city street 25-45 mph -> more nags')
  local function drive(mode, att, secs, v, limit)
    local n = N.new()
    n.mode = mode
    n.rng = function() return 0.5 end
    n:nudge(0)
    local first
    for k = 1, secs * 10 do
      local t = k / 10
      local o = n:tick(t, true, 'standard', att and att(t) or nil, { v = v or 15, limit = limit })
      if not first and o.level >= 1 then first = t end
    end
    return first, n
  end
  local offAt = drive('off', function(t) return { state = 'phone', t = t } end, 60)
  check(offAt == nil, 'off: no nags at all, even on the phone')
  local camAt = drive('camera', function(t) return { state = 'phone', t = t } end, 30)
  check(camAt and camAt < 10, 'camera: on the phone -> nag (' .. tostring(camAt) .. ' s)')
  local camOk = drive('camera', function(t) return { state = 'ok', t = t } end, 120)
  check(camOk == nil, 'camera: eyes on the road -> no wheel nudges needed')
  local wheelIgnoresCam = drive('wheel', function(t) return { state = 'ok', t = t } end, 60, 15, 15.6)
  check(wheelIgnoresCam and wheelIgnoresCam < 30, 'wheel: camera ignored, city street nag after ~21 s (' .. tostring(wheelIgnoresCam) .. ')')
  local hwy = drive('wheel', nil, 90, 28, 29)
  check(hwy and hwy > 45, 'wheel: highway nag comes later (' .. tostring(hwy) .. ' s)')
  -- camera mode, camera stops: falls back to the wheel and says so
  local _, n = drive('camera', function(t) if t < 5 then return { state = 'ok', t = t } end return { state = 'ok', t = 5 } end, 20)
  check(n.cameraLost == true and n.active == 'wheel', 'camera stops reporting -> wheel fallback')
end)

-- light learning: what he does when FSD is off and how he corrects FSD moves the scales a little
scenario('learning', function()
  local Lr = require('teslaBridge/learn')
  local L = Lr.new()
  check(L:speedScale(15) == 1 and L:gapScale(15) == 1, 'learning: starts neutral')
  for _ = 1, 1500 do L:watch(15, 15 * 1.12, nil, 0.5) end -- 12 minutes at 12 % over the limit
  local fast = L:speedScale(15)
  check(fast > 1.03 and fast <= 1.2, string.format('learning: drives over the limit by habit -> FSD a bit faster (%.3f)', fast))
  check(L:speedScale(30) < 1.005, 'learning: other road types stay neutral')
  local L2 = Lr.new()
  for _ = 1, 100 do L2:feedback(15, 'faster', 0.5) end
  check(L2:speedScale(15) > 1.1, 'learning: holding the accelerator pushes FSD faster')
  for _ = 1, 20 do L2:feedback(15, 'slower') end
  check(L2:speedScale(15) < 1.0, 'learning: taking over while too fast pushes it slower (bounded)')
  check(L2:speedScale(15) >= 0.85 and L2:gapScale(15) <= 1.4, 'learning: always bounded')
  local L3 = Lr.new(L:export())
  check(math.abs(L3:speedScale(15) - fast) < 1e-9, 'learning: survives save and load')
end)

-- phantom braking: a parked car beside the lane must not trigger AEB, a stopped car in the lane must
scenario('brainNoPhantom', function()
  local S = require('teslaBridge/safety')
  -- straight road, a little steering wobble, an oncoming car in its own lane: never brake
  local sf = S.new()
  local braked, warned = false, false
  for k = 0, 60 do
    local tt = k * 0.05
    local ego = { x = 27 * tt, y = 0, z = 0, hx = 1, hy = 0, v = 27, yawRate = 0.03 * math.sin(k), len = 4.6, wid = 1.9 }
    local car = { id = 7, x = 90 - 27 * tt, y = 3.6, z = 0, dx = -1, dy = 0, v = 27, l = 4.6, w = 1.9 }
    local o = sf:tick(tt, 0.05, { ego = ego, cars = { car } }, { rays = {} })
    if (o.aeb or 0) > 0 then braked = true end
    if o.fcw then warned = true end
  end
  check(not braked and not warned, 'brain: no braking/warning for an oncoming car in its own lane')
  -- a stopped car under us on another level (overpass): never brake
  local sf2 = S.new()
  local b2 = false
  for k = 0, 40 do
    local ego = { x = 0, y = 0, z = 8, hx = 1, hy = 0, v = 20, yawRate = 0, len = 4.6, wid = 1.9 }
    local o = sf2:tick(k * 0.05, 0.05, { ego = ego, cars = { { id = 2, x = 20, y = 0, z = 0, dx = 0, dy = 1, v = 0, l = 4.6, w = 1.9 } } }, { rays = {} })
    if (o.aeb or 0) > 0 then b2 = true end
  end
  check(not b2, 'brain: no braking for a car on the road below')
  -- cost: 30 cars, 2000 ticks
  local B = require('teslaBridge/brain')
  local br = B.new()
  local cars = {}
  for i = 1, 30 do cars[i] = { id = i, x = i * 7, y = (i % 3) * 3.5, z = 0, dx = 1, dy = 0, v = 20, l = 4.6, w = 1.9 } end
  local ego = { x = 0, y = 0, z = 0, hx = 1, hy = 0, v = 25, yawRate = 0, wid = 1.9 }
  local c0 = os.clock()
  for k = 1, 2000 do br:update(k * 0.05, ego, cars, { car = cars[k % 30 + 1], ttc = 1.0, need = 2 }) end
  local us = (os.clock() - c0) / 2000 * 1e6
  print(string.format('  brain: %.1f us per tick with 30 cars', us))
  check(us < 200, 'brain is cheap (< 0.2 ms a tick)')
end)

scenario('brainReads', function()
  local B = require('teslaBridge/brain')
  local ego = { x = 0, y = 0, z = 0, hx = 1, hy = 0, v = 25, yawRate = 0, wid = 1.9 }
  -- swerving: heading swings side to side at speed
  local b = B.new()
  for k = 0, 80 do
    local a = 0.12 * math.sin(k * 0.05 * 2 * math.pi * 0.7)
    b:observe(k * 0.05, { { id = 1, x = 30 + k, y = 3.6, dx = math.cos(a), dy = math.sin(a), v = 20 } })
  end
  check(b:isErratic({ id = 1 }), 'brain: sees a swerving car')
  -- one clean lane change is not swerving
  local b2 = B.new()
  for k = 0, 80 do
    local a = (k > 20 and k < 40) and 0.08 * math.sin((k - 20) / 20 * 2 * math.pi) or 0
    b2:observe(k * 0.05, { { id = 1, x = 30 + k, y = 3.6, dx = math.cos(a), dy = math.sin(a), v = 20 } })
  end
  check(not b2:isErratic({ id = 1 }), 'brain: one lane change is not swerving')
  -- cutting in: next lane, sliding toward us
  local b3 = B.new()
  local car
  for k = 0, 10 do
    car = { id = 3, x = 20, y = 3.6 - k * 0.05, dx = 1, dy = 0, v = 20 }
    b3:observe(k * 0.05, { car })
  end
  check(b3:cutInEta(ego, car) ~= nil, 'brain: sees a car cutting in')
  local b4 = B.new()
  for k = 0, 10 do
    car = { id = 4, x = 20, y = 3.6 + k * 0.05, dx = 1, dy = 0, v = 20 }
    b4:observe(k * 0.05, { car })
  end
  check(b4:cutInEta(ego, car) == nil, 'brain: a car moving away is not cutting in')
  -- hard braking
  local b5 = B.new()
  for k = 0, 20 do b5:observe(k * 0.05, { { id = 5, x = 40, y = 0, dx = 1, dy = 0, v = 20 - k * 0.4 } }) end
  check(b5:hardBraked({ id = 5 }, 1.0), 'brain: sees a hard braker')
  -- parked quality
  check(B.parkedQuality(0.99, 1.5) == 'good', 'brain: lined-up parked car is parked properly')
  check(B.parkedQuality(0.7, 1.5) == 'bad', 'brain: angled parked car is badly parked')
  check(B.parkedQuality(0.99, 0.2) == 'bad', 'brain: parked car poking into the lane is badly parked')
  -- a car cutting in right beside us counts as a real threat sooner
  local S = require('teslaBridge/safety')
  local sf = S.new()
  local braked = false
  for k = 0, 30 do
    local tt = k * 0.05
    local e = { x = 20 * tt, y = 0, z = 0, hx = 1, hy = 0, v = 20, yawRate = 0, len = 4.6, wid = 1.9 }
    local c = { id = 9, x = 20 * tt + 9, y = math.max(0, 3.6 - 3 * tt), z = 0, dx = 1, dy = 0, v = 14, l = 4.6, w = 1.9 }
    local o = sf:tick(tt, 0.05, { ego = e, cars = { c } }, { rays = {} })
    if (o.aeb or 0) > 0 then braked = true end
  end
  check(braked, 'brain: brakes for a car swerving into our lane close ahead')
end)

scenario('erraticHangBack', function()
  -- a car swerving in the next lane ahead, a bit slower: FSD doesn't pull up alongside it
  local w = W.new({ nodes = straight(0, 3000, 7.5, 25), ego = { x = 0, y = RIGHT2, psi = 0, v = 20 } })
  w:addCar({ id = 1, pts = line(40, LEFT2, 3000, LEFT2), speed = 17 })
  w:engage('fsd', 'standard')
  local wob = 0
  local closest = 1e9
  w:run(20, function(ww)
    wob = wob + 1
    local c = ww.cars[1]
    local a = 0.15 * math.sin(wob * 0.05 * 2 * math.pi * 0.6)
    c.dx, c.dy = math.cos(a), math.sin(a)
    local ex = ww:refPos()
    closest = math.min(closest, c.x - ex)
  end)
  check(w:saw('brain', function(e) return e.what == 'erratic' end) ~= nil, 'notices the swerving car')
  check(closest > 0, 'hangs back instead of pulling alongside (closest ' .. string.format('%.1f', closest) .. ' m ahead)')
  check(not w.collided, 'no collision')
end)

scenario('judgeLogic', function()
  local J = require('teslaBridge/judge')
  local j = J.new()
  check(j:allowLane(0, 0, 1, 'pass'), 'judge: first change is fine')
  j:laneChanged(10, 0, 1, 'pass')
  check(not j:allowLane(15, 1, 2, 'pass'), 'judge: no discretionary change while settling')
  check(not j:allowLane(25, 1, 0, 'madMax'), 'judge: no flip back to the lane we just left')
  check(j:allowLane(25, 1, 0, 'madMax', 7), 'judge: ...unless the other lane is much faster')
  check(j:allowLane(25, 1, 0, 'route'), 'judge: a route need overrides')
  check(j:allowLane(25, 1, 0, 'driver'), 'judge: the driver overrides')
  check(j:allowLane(25, 1, 0, 'return'), 'judge: coming back right after passing is normal')
  check(j:allowLane(50, 1, 0, 'madMax'), 'judge: later it may change again')
  -- confusion
  local j2 = J.new()
  local lvl, rose
  for k = 1, 60 do lvl, rose = j2:watchStuck(k * 0.1, { engaged = true, v = 0, dt = 0.1 }); if rose == 1 then break end end
  check(rose == 1, 'judge: unexplained stillness -> re-plan level')
  local seen3 = false
  for k = 1, 300 do lvl, rose = j2:watchStuck(10 + k * 0.1, { engaged = true, v = 0, dt = 0.1 }); if rose == 3 then seen3 = true end end
  check(seen3, 'judge: still stuck -> asks the driver')
  j2:watchStuck(99, { engaged = true, v = 0, explained = 'stopPoint', dt = 0.1 })
  check(j2.level == 0, 'judge: an explained stop is not confusion')
  -- tailgater
  local B = require('teslaBridge/brain')
  local b = B.new()
  local ego = { x = 0, y = 0, z = 0, hx = 1, hy = 0, v = 20, wid = 1.9, len = 4.6 }
  local got
  for k = 0, 80 do
    b:observe(k * 0.05, {})
    got = b:tailgater(ego, { { id = 1, x = -8, y = 0.1, z = 0, dx = 1, dy = 0, v = 21, l = 4.6, w = 1.9 } })
  end
  check(got ~= nil, 'brain: sees a tailgater after a few seconds')
  local b2 = B.new()
  for k = 0, 80 do b2:observe(k * 0.05, {}); got = b2:tailgater(ego, { { id = 1, x = -30, y = 0, z = 0, dx = 1, dy = 0, v = 21, l = 4.6, w = 1.9 } }) end
  check(got == nil, 'brain: a car well back is not a tailgater')
  local b3 = B.new()
  ego.v = 0
  for k = 0, 80 do b3:observe(k * 0.05, {}); got = b3:tailgater(ego, { { id = 1, x = -6, y = 0, z = 0, dx = 1, dy = 0, v = 0, l = 4.6, w = 1.9 } }) end
  check(got == nil, 'brain: the car behind us at a light is normal')
  -- pedestrians
  check(B.pedestrianEta(4, -1.4, 1.6) ~= nil, 'brain: pedestrian walking toward the road')
  check(B.pedestrianEta(4, 1.4, 1.6) == nil, 'brain: pedestrian walking away')
  check(B.pedestrianEta(4, 0.1, 1.6) == nil, 'brain: pedestrian standing still')
  -- learned bad spots
  local L = require('teslaBridge/learn')
  local l = L.new()
  check(l:spotScale(100, 100) == 1, 'learn: unknown place is normal')
  l:markSpot(100, 100); l:markSpot(105, 98)
  check(l:spotScale(100, 100) < 1, 'learn: two takeovers here -> gentler')
  local l2 = L.new(l:export())
  check(l2:spotScale(100, 100) < 1, 'learn: remembered after save / load')
end)

scenario('tailgaterYield', function()
  -- someone rides our bumper in the left lane: we move over to the right (the brain's verdict is stubbed
  -- here; its detection is unit tested in judgeLogic)
  local w = W.new({ nodes = straight(0, 3000, 7.5, 25), ego = { x = 100, y = LEFT2, psi = 0, v = 22 } })
  w.planner.brain.tailgater = function() return { id = 1 } end
  w:engage('fsd', 'sloth')
  w.planner.lane.k = 1 -- we are in the left lane
  w:run(15)
  check(w:saw('brain', function(e) return e.what == 'tailgater' end) ~= nil, 'reacts to a tailgater')
  check(w:saw('laneChange', function(e) return e.reason == 'yield' end) ~= nil, 'moves right for it')
end)

scenario('policyNet', function()
  local Po = require('teslaBridge/policy')
  -- a hand-made 2-input net: layer 1 = two tanh units, layer 2 = their difference
  local spec = { scale = { 10, 10 }, layers = {
    { w = { { 1, 0 }, { 0, 1 } }, b = { 0, 0 }, act = 'tanh' },
    { w = { { 1, -1 } }, b = { 0 }, act = 'tanh' } } }
  local p = Po.new(spec)
  local out = p:act({ 5, 5 })
  check(math.abs(out) < 1e-9, 'policy: symmetric input -> 0')
  out = p:act({ 10, 0 })
  local expect = math.tanh and math.tanh(math.tanh(1)) or (function(x) local e = math.exp(2 * x); return (e - 1) / (e + 1) end)((function(x) local e = math.exp(2 * x); return (e - 1) / (e + 1) end)(1))
  check(math.abs(out - expect) < 1e-9, 'policy: matches the hand-computed forward pass (' .. string.format('%.4f', out) .. ')')
  check(Po.new({}) == nil and Po.new({ scale = { 1, 2, 3 }, layers = spec.layers }) == nil, 'policy: rejects a bad spec')
  -- cost
  local big = { layers = { { w = {}, b = {}, act = 'tanh' }, { w = {}, b = {}, act = 'tanh' }, { w = { {} }, b = { 0 }, act = 'tanh' } } }
  for r = 1, 16 do big.layers[1].w[r] = {}; for c = 1, 7 do big.layers[1].w[r][c] = 0.1 end; big.layers[1].b[r] = 0 end
  for r = 1, 16 do big.layers[2].w[r] = {}; for c = 1, 16 do big.layers[2].w[r][c] = 0.05 end; big.layers[2].b[r] = 0 end
  for c = 1, 16 do big.layers[3].w[1][c] = 0.1 end
  local pb = Po.new(big)
  local c0 = os.clock()
  for _ = 1, 5000 do pb:act({ 20, 20, 30, 0, 50, 0, 1 }) end
  local us = (os.clock() - c0) / 5000 * 1e6
  print(string.format('  policy net 7-16-16-1: %.1f us per call', us))
  check(us < 100, 'policy: cheap (< 0.1 ms a call)')
end)

scenario('leastHarm', function()
  local S = require('teslaBridge/safety')
  local function run(cars, lane, rays, v)
    local sf = S.new()
    local evade, ev
    for k = 0, 10 do
      local ego = { x = 0, y = 0, z = 0, hx = 1, hy = 0, v = v or 15, yawRate = 0, len = 4.6, wid = 1.9 }
      local o = sf:tick(k * 0.05, 0.05, { ego = ego, cars = cars }, { rays = rays or {}, lane = lane })
      if o.evade then evade = o.evade end
      for _, e in ipairs(o.events) do if e.kind == 'collisionEvasion' then ev = e end end
    end
    return evade, ev
  end
  local ped = { id = 1, x = 21, y = 0, z = 0, dx = 0, dy = 1, v = 0, l = 0.6, w = 0.6 }
  local lane = { laneW = 3.5, roomLeft = 6, roomRight = 6 }
  local e1, ev1 = run({ ped }, lane, nil, 20)
  check(e1 ~= nil and ev1 and ev1.detail == 'pedestrian', 'least harm: swerves for a pedestrian braking cannot save')
  -- the oncoming lane is the only way out: still fine to save a person
  local e2 = run({ ped }, { laneW = 3.5, roomLeft = 6, roomRight = 0, oncomingLeft = true }, nil, 20)
  check(e2 ~= nil, 'least harm: takes the oncoming lane / verge rather than hit a pedestrian')
  -- parked cars both sides and walls: hitting a parked car beats hitting a person
  local carL = { id = 2, x = 18, y = 3.5, z = 0, dx = 1, dy = 0, v = 0, l = 4.6, w = 1.9 }
  local carR = { id = 3, x = 18, y = -3.5, z = 0, dx = 1, dy = 0, v = 0, l = 4.6, w = 1.9 }
  local e3 = run({ ped, carL, carR }, lane, nil, 20)
  check(e3 ~= nil, 'least harm: sideswipes a parked car to spare the pedestrian')
  -- a car ahead we can nearly stop for: no swerve (a small bump beats a manoeuvre)
  local slow = { id = 4, x = 24, y = 0, z = 0, dx = 1, dy = 0, v = 0, l = 4.6, w = 1.9 }
  local e4 = run({ slow }, lane)
  check(e4 == nil, 'least harm: a bump we can nearly stop for is braked, not swerved')
  -- but a person on the road that braking can stop for: brake
  local pedFar = { id = 5, x = 40, y = 0, z = 0, dx = 0, dy = 1, v = 0, l = 0.6, w = 0.6 }
  local e5 = run({ pedFar }, lane)
  check(e5 == nil, 'least harm: a pedestrian we can stop for is braked for')
end)

scenario('policyBlend', function()
  local function cruise(a, on)
    local w = W.new({ nodes = straight(0, 4000, 5, 20), ego = { x = 0, y = RIGHT2 + 0, psi = 0, v = 15 } })
    if a then w.planner.policy = { act = function() return a end } end
    w.planner.settings.policy = on
    w:engage('fsd', 'standard')
    w:run(40)
    return w.ego.v
  end
  local base = cruise(nil, false)
  local up = cruise(1, true)
  local down = cruise(-1, true)
  local off = cruise(1, false)
  check(up > base * 1.03 and up < base * 1.10, string.format('policy: +1 nudges speed up a little (%.1f vs %.1f)', up, base))
  check(down < base * 0.97 and down > base * 0.90, string.format('policy: -1 nudges speed down a little (%.1f vs %.1f)', down, base))
  check(math.abs(off - base) < 0.2, 'policy: does nothing while the setting is off')
end)

scenario('straightBoost', function()
  -- 1.5 km straight, then a 60 m radius bend: the straight allows a little more than the plain profile,
  -- the bend and the run-up to it do not
  local pts = {}
  local x, y, h = 0, 0, 0
  for i = 0, 750 do pts[#pts + 1] = { x = x, y = y, z = 0, r = 4, lim = 20 }; x = x + 2 end
  for i = 1, 60 do h = h + 2 / 60; x = x + 2 * math.cos(h); y = y + 2 * math.sin(h); pts[#pts + 1] = { x = x, y = y, z = 0, r = 4, lim = 20 } end
  local function prof(straight)
    local path = { pts = pts, s = P.cumulative(pts) }
    P.speedProfile(path, { offset = 0, aLat = 2.8, straight = straight })
    return path
  end
  local a, b = prof(0), prof(0.05)
  check(math.abs(b.vcap[100] / a.vcap[100] - 1.05) < 0.01, 'straight boost: +5% on the open straight (' .. string.format('%.1f vs %.1f', b.vcap[100], a.vcap[100]) .. ')')
  local last = #pts
  check(math.abs(b.vcap[last - 10] - a.vcap[last - 10]) < 0.01, 'straight boost: none in the bend')
  local near = 750 - 40 -- 80 m before the bend: the run-up brakes for it exactly as before
  check(math.abs(b.vcap[near] - a.vcap[near]) < 0.5, 'straight boost: no extra speed into the bend (' .. string.format('%.1f vs %.1f', b.vcap[near], a.vcap[near]) .. ')')
end)

scenario('aebParked', function()
  local S = require('teslaBridge/safety')
  local function braked(latOffset)
    local sf = S.new()
    local hit = false
    for k = 0, 40 do
      local ego = { x = 0, y = 0, hx = 1, hy = 0, v = 15, yawRate = 0, len = 4.6, wid = 1.9 }
      local car = { id = 1, x = 22, y = latOffset, dx = 1, dy = 0, v = 0, l = 4.6, w = 1.9 }
      local o = sf:tick(k * 0.05, 0.05, { ego = ego, cars = { car } }, { rays = {} })
      if (o.aeb or 0) > 0 then hit = true end
    end
    return hit
  end
  check(braked(0) == true, 'AEB: still brakes for a stopped car in the lane')
  check(braked(1.7) == false, 'AEB: no phantom braking for a parked car that only grazes the lane edge')
end)

-- Tesla feel: smooth pedals (low jerk), gentle steady stops, careful around people and parked cars
scenario('comfort', function()
  local w = W.new({ nodes = straight(0, 3000, 5, 17), ego = { x = 0, y = LANE1, psi = 0, v = 0 },
    signals = { { id = 'stop', x = 500, y = -7, kind = 'stop', prop = true } } })
  w.planner:setRoute({ 900, LANE1, 0 }, nil, 'Driveway')
  w:engage('fsd', 'standard')
  local prevV, prevA, maxJerk, maxDecel, maxAccel = 0, 0, 0, 0, 0
  local jerkAt, jerkV
  local last = 0
  w:run(90, function(ww)
    if ww.t - last >= 0.25 then
      local dt = ww.t - last; last = ww.t
      local a = (ww.ego.v - prevV) / dt
      if ww.t > 2 and ww.ego.v > 1.5 and prevV > 1.5 then local j = math.abs(a - prevA) / dt; if j > maxJerk then maxJerk, jerkAt, jerkV = j, ww.t, ww.ego.v end end
      maxDecel = math.min(maxDecel, a); maxAccel = math.max(maxAccel, a)
      prevV, prevA = ww.ego.v, a
    end
    return ww:saw('arrived')
  end)
  check(maxAccel < 2.6, string.format('comfort: gentle acceleration (max %.2f m/s^2)', maxAccel))
  check(-maxDecel < 3.0, string.format('comfort: gentle braking, no lurch (max %.2f m/s^2)', -maxDecel))
  check(maxJerk < 5.0, string.format('comfort: smooth pedals (max jerk %.1f m/s^3 at t=%.1f v=%.1f)', maxJerk, jerkAt or 0, jerkV or 0))
  check(w:saw('arrived') ~= nil, 'comfort: still gets there')
end)

scenario('caution', function()
  local function maxSpeedPassing(extra)
    local w = W.new({ nodes = straight(0, 1500, 6, 17), ego = { x = 0, y = LANE1, psi = 0, v = 14 } })
    if extra then extra(w) end
    w:engage('fsd', 'standard')
    local m = 0
    w:run(40, function(ww)
      local x = ww:refPos()
      if x > 196 and x < 206 then m = math.max(m, ww.ego.v) end -- right beside it
      return x > 260
    end)
    return m, w
  end
  local free = maxSpeedPassing(nil)
  local ped = maxSpeedPassing(function(w) w:addCar({ id = 8, x = 200, y = -5.0, dx = 0, dy = 1, l = 0.5, w = 0.5, v = 0 }) end)
  local parked = maxSpeedPassing(function(w) w:addCar({ id = 9, x = 200, y = -4.6, dx = 1, dy = 0, l = 4.6, w = 1.9 }) end)
  check(ped < 6.5 and ped < free - 3, string.format('caution: slows right down for a pedestrian at the road edge (%.1f vs %.1f m/s free)', ped, free))
  check(parked < 10.5 and parked < free - 1, string.format('caution: eases past a parked car beside the lane (%.1f vs %.1f m/s free)', parked, free))
end)

-- shorter stop sign dwell (Quentin: "stops a bit too long"), per profile
scenario('stopDwell', function()
  local function dwell(profile)
    local w = W.new({ nodes = grid(2, 2, 150), ego = { x = 5, y = LANE1, psi = 0, v = 0 },
      signals = { { id = 'stop1', x = 141, y = -7, z = 0, kind = 'stop' } } })
    w.planner:setRoute({ 300, LANE1, 0 }, nil, 'Driveway')
    w:engage('fsd', profile)
    local t0, t1
    w:run(80, function(ww)
      local f = ww.planner.stopFsm.stop1
      if f and f.state == 'stopped' and not t0 then t0 = ww.t end
      if f and (f.state == 'creep' or f.state == 'peek' or f.state == 'done') and not t1 then t1 = ww.t end
      return ww:saw('arrived')
    end)
    return t0 and t1 and (t1 - t0) or 99
  end
  local std, mad, sloth = dwell('standard'), dwell('madmax'), dwell('sloth')
  check(std < 1.6, string.format('stop sign: standard waits about a second (%.1f s)', std))
  check(mad < std and sloth > std, string.format('stop sign: Mad Max %.1f s < standard %.1f s < Sloth %.1f s', mad, std, sloth))
end)

-- confidence: an unreadable light lowers it under 55 %; FSD asks for a takeover but keeps driving
scenario('confidence', function()
  local w = W.new({ nodes = straight(0, 2000, 5, 15), ego = { x = 0, y = LANE1, psi = 0, v = 12 },
    signals = { { id = 'dead', x = 600, y = -7, kind = 'signal', dirx = 1, diry = 0, get = function() return nil end } } })
  w:engage('fsd', 'standard')
  local low, minConf = false, 1
  local passed = false
  w:run(60, function(ww)
    local st = ww.planner.status
    if st and st.confidence then minConf = math.min(minConf, st.confidence) end
    if st and st.lowConfidence then low = true end
    local x = ww:refPos()
    if x > 650 then passed = true end
    return passed
  end)
  check(low, string.format('confidence: an unreadable light drops it under 55 %% (min %.2f)', minConf))
  check(passed and w.planner.mode == 'fsd', 'confidence: it keeps driving if the driver does nothing')
  local calm = W.new({ nodes = straight(0, 2000, 5, 17), ego = { x = 0, y = LANE1, psi = 0, v = 12 } })
  calm:engage('fsd', 'standard')
  local calmMin = 1
  calm:run(20, function(ww) local st = ww.planner.status; if st and st.confidence then calmMin = math.min(calmMin, st.confidence) end end)
  check(calmMin > 0.85, string.format('confidence: high on an easy road (%.2f)', calmMin))
end)

scenario('aeb', function()
  local w = W.new({ nodes = straight(0, 2000, 5, 25), ego = { x = 0, y = LANE1, psi = 0, v = 20 },
    safety = { evasion = false } })
  w:addCar({ id = 1, x = 80, y = LANE1, dx = 1, dy = 0 })
  w.manual = function() return 0, 0.3, 0 end -- distracted driver, no braking
  w:run(12, function(ww) return ww.ego.v < 0.1 end)
  check(w:saw('fcw') ~= nil, 'forward collision warning')
  check(w:saw('aeb') ~= nil, 'automatic emergency braking kicks in')
  check(not w.collided, 'stops before hitting the car')
end)

scenario('evasion', function()
  local w = W.new({ nodes = straight(0, 2000, 7.5, 30), ego = { x = 0, y = RIGHT2, psi = 0, v = 25 } })
  w:addCar({ id = 1, x = 70, y = RIGHT2, dx = 1, dy = 0 })
  w.manual = function() return 0, 0.4, 0 end
  w:run(12, function(ww) return ww:refPos() > 150 end)
  check(w:saw('collisionEvasion') ~= nil, 'Automatic Collision Evasion steers around')
  check(not w.collided, 'no collision (' .. tostring(w.collidedWith) .. ')')
  check(w.planner.mode == 'fsd', 'FSD keeps driving after the evasion')
end)

scenario('laneDeparture', function()
  local w = W.new({ nodes = straight(0, 3000, 5, 30), ego = { x = 0, y = LANE1, psi = 0, v = 25 } })
  w.manual = function() return 0.012, 0.5, 0 end -- slow drift to the right
  local maxOut = 0
  w:run(8, function(ww)
    local _, y = ww:refPos()
    maxOut = math.max(maxOut, LANE1 - y)
  end)
  check(w:saw('laneDeparture') ~= nil, 'lane departure avoidance intervenes')
end)

scenario('blindSpot', function()
  local w = W.new({ nodes = straight(0, 3000, 7.5, 30), ego = { x = 0, y = RIGHT2, psi = 0, v = 20 } })
  w:addCar({ id = 1, pts = line(-4, LEFT2, 3000, LEFT2), speed = 20 })
  w.manual = function() return 0, 0.3, 0 end
  w.manualSignal = 'left'
  w:run(1)
  check(w.blindLeft == true, 'blind spot: car on the left')
  check(w.blindRight ~= true, 'nothing on the right')
  check(w:saw('blindSpotWarning') ~= nil, 'warns when signaling toward it')
end)

scenario('phantomBrake', function()
  local w = W.new({ nodes = straight(0, 5000, 5, 27), ego = { x = 0, y = LANE1, psi = 0, v = 22 },
    settings = { quirks = { phantomBraking = true, yellowHesitation = false, wiggle = false, weather = false, creep = true } }, rng = function() return 0 end })
  w:engage('fsd', 'standard')
  local v0 = w.ego.v
  local minV = 99
  w:run(4, function(ww) minV = math.min(minV, ww.ego.v) end)
  check(w:saw('phantomBrake') ~= nil, 'phantom braking happens (rng forced)')
  check(minV < v0 - 2, string.format('it actually slows (%.1f -> %.1f)', v0, minV))
end)

scenario('weather', function()
  local dry = W.new({ nodes = straight(0, 5000, 5, 25), ego = { x = 0, y = LANE1, psi = 0, v = 20 } })
  dry:engage('fsd', 'standard'); dry:run(25)
  local wet = W.new({ nodes = straight(0, 5000, 5, 25), ego = { x = 0, y = LANE1, psi = 0, v = 20 }, weather = { rain = 1, fog = 0 } })
  wet:engage('fsd', 'standard'); wet:run(25)
  check(wet.ego.v < dry.ego.v - 1.5, string.format('slower in heavy rain (%.1f vs %.1f m/s)', wet.ego.v, dry.ego.v))
end)

-- in-game bug (0.39): after crossing on green, the far-side light for the other direction
-- (red) pulled the stop line back to the junction edge behind the car ("signal in -8 m")
-- and FSD stopped in the intersection for good
scenario('farSideSignal', function()
  local w = W.new({ nodes = grid(2, 2, 150), ego = { x = 5, y = LANE1, psi = 0, v = 0 },
    signals = {
      { id = 'ours', x = 141, y = -7, kind = 'signal', dirx = 1, diry = 0, get = function() return 'green' end },
      { id = 'theirs', x = 159, y = 7, kind = 'signal', dirx = -1, diry = 0, get = function() return 'red' end },
      { id = 'north', x = 157, y = -9, kind = 'signal', dirx = 0, diry = 1, get = function() return 'red' end },
      { id = 'south', x = 143, y = 9, kind = 'signal', dirx = 0, diry = -1, get = function() return 'red' end },
      -- mid-block, no junction near it, facing the other way: only the direction check can reject it
      { id = 'midBlock', x = 75, y = 5, kind = 'signal', dirx = -1, diry = 0, get = function() return 'red' end },
    } })
  w.planner:setRoute({ 300, LANE1, 0 }, nil, 'Driveway')
  check(w:engage('fsd', 'standard'), 'engage (far-side signal)')
  local minV, minMid = 99, 99
  w:run(60, function(ww)
    local x = ww:refPos()
    if x > 146 and x < 170 then minV = math.min(minV, ww.ego.v) end
    if x > 40 and x < 90 then minMid = math.min(minMid, ww.ego.v) end
    return ww:saw('arrived')
  end)
  check(minMid > 2, string.format('ignores a red facing the other way mid-block (min %.1f m/s)', minMid))
  check(minV > 2, 'does not stop in the junction for the far-side red (min ' .. string.format('%.1f', minV) .. ' m/s)')
  check(w:saw('arrived') ~= nil, 'arrives past the far-side red')
  check(w.planner:signalDirConvention() == 1, 'learns that signal dir = travel direction (' .. tostring(w.planner:signalDirConvention()) .. ')')
end)

-- a stop-sign prop standing beside the cross street (props have no direction) is theirs, not ours
scenario('crossStreetProp', function()
  local w = W.new({ nodes = grid(2, 2, 150), ego = { x = 5, y = LANE1, psi = 0, v = 0 },
    signals = { { id = 'theirStop', x = 156, y = -12, z = 0, kind = 'stop', prop = true } } })
  w.planner:setRoute({ 300, LANE1, 0 }, nil, 'Driveway')
  check(w:engage('fsd', 'standard'), 'engage (cross-street prop)')
  local minV = 99
  w:run(60, function(ww)
    local x = ww:refPos()
    if x > 110 and x < 160 then minV = math.min(minV, ww.ego.v) end
    return ww:saw('arrived')
  end)
  check(minV > 2, 'does not stop for the cross street\'s stop sign (min ' .. string.format('%.1f', minV) .. ' m/s)')
  check(w:saw('arrived') ~= nil, 'arrives (cross-street prop)')
end)

-- a signal whose state reads "stop" (stop-sign controller / flashing red): stop, then go
scenario('stopStateSignal', function()
  local w = W.new({ nodes = grid(2, 2, 150), ego = { x = 5, y = LANE1, psi = 0, v = 0 },
    signals = { { id = 'flash', x = 141, y = -7, kind = 'signal', dirx = 1, diry = 0, get = function() return 'stop' end } } })
  w.planner:setRoute({ 300, LANE1, 0 }, nil, 'Driveway')
  check(w:engage('fsd', 'standard'), 'engage (stop-state signal)')
  local stopped = false
  w:run(60, function(ww)
    local fsm = ww.planner.stopFsm.flash
    if fsm and fsm.state == 'stopped' then stopped = true end
    return ww:saw('arrived')
  end)
  check(stopped, 'full stop at a signal showing stop')
  check(w:saw('arrived') ~= nil, 'then leaves the line and arrives')
end)

-- in-game round 3: 'basicstop' controllers with no stop sign are painted lines / crosswalks.
-- Quentin's rule: no full stop there, only for a pedestrian in the way
scenario('paintedLine', function()
  local function run(ped)
    local w = W.new({ nodes = grid(2, 2, 150), ego = { x = 5, y = LANE1, psi = 0, v = 0 },
      signals = { { id = 'line', x = 100, y = -7, kind = 'signal', dirx = 1, diry = 0, signNear = false, get = function() return 'stop' end } } })
    if ped then w:addCar({ id = 99, w = 0.6, l = 0.6, pts = { { x = 103, y = -3 }, { x = 103, y = -2.9 } }, speedFn = function() return 0 end, s0 = 0 }) end
    w.planner:setRoute({ 300, LANE1, 0 }, nil, 'Driveway')
    w:engage('fsd', 'standard')
    local minV = 99
    w:run(40, function(ww)
      local x = ww:refPos()
      if x > 60 and x < 100 then minV = math.min(minV, ww.ego.v) end
      return x > 140
    end)
    return minV
  end
  local free = run(false)
  check(free > 5, string.format('no stop at a painted line with no sign (min %.1f m/s)', free))
  local withPed = run(true)
  check(withPed < 0.5, string.format('stops for a pedestrian at the crosswalk (min %.1f m/s)', withPed))
  -- a real light flashing red (no stop-sign prop needed) is still an all-way stop
  local w = W.new({ nodes = grid(2, 2, 150), ego = { x = 5, y = LANE1, psi = 0, v = 0 },
    signals = { { id = 'flash', x = 141, y = -7, kind = 'signal', dirx = 1, diry = 0, signNear = false, flashing = true, get = function() return 'stop' end } } })
  w.planner:setRoute({ 300, LANE1, 0 }, nil, 'Driveway')
  w:engage('fsd', 'standard')
  local stopped = false
  w:run(60, function(ww) if ww.planner.stopFsm.flash and ww.planner.stopFsm.flash.state == 'stopped' then stopped = true end; return ww:saw('arrived') end)
  check(stopped, 'flashing red with no sign nearby: still stops, then goes')
end)

-- a red that never changes (unreadable / broken light): treated as an all-way stop after 90 s
scenario('stuckRed', function()
  local w = W.new({ nodes = grid(2, 2, 150), ego = { x = 5, y = LANE1, psi = 0, v = 0 },
    signals = { { id = 'dead', x = 141, y = -7, kind = 'signal', dirx = 1, diry = 0, get = function() return 'red' end } } })
  w.planner:setRoute({ 300, LANE1, 0 }, nil, 'Driveway')
  check(w:engage('fsd', 'standard'), 'engage (stuck red)')
  local tLeft
  w:run(160, function(ww)
    local x = ww:refPos()
    if not tLeft and x > 150 then tLeft = ww.t end
    return ww:saw('arrived')
  end)
  check(w:saw('signalStuck') ~= nil, 'reports the stuck light')
  check(tLeft and tLeft > 90, 'waits at the red first (left at ' .. tostring(tLeft) .. ')')
  check(w:saw('arrived') ~= nil, 'not stranded forever')
end)

scenario('yellow', function()
  -- borderline yellow: with the hesitation quirk and rng < 0.5 it stops, otherwise it goes
  local function run(rv)
    local state = 'green'
    local w = W.new({ nodes = straight(0, 2000, 5, 17), ego = { x = 0, y = LANE1, psi = 0, v = 15 },
      signals = { { id = 'L', x = 200, y = -7, kind = 'signal', dirx = 1, diry = 0, get = function() return state end } },
      settings = { quirks = { phantomBraking = false, yellowHesitation = true, wiggle = false, weather = false, creep = true } },
      rng = function() return rv end })
    w:engage('fsd', 'standard')
    w:run(30, function(ww)
      local x = ww:refPos()
      if x > 200 - 48 and state == 'green' then state = 'yellow' end
      return x > 210 or (ww.t > 25)
    end)
    return w:refPos() > 205
  end
  check(run(0.9) == true, 'borderline yellow, rng high: goes through')
  check(run(0.1) == false, 'borderline yellow, rng low: stops')
end)

scenario('tacc', function()
  local w = W.new({ nodes = straight(0, 5000, 5, 20), ego = { x = 0, y = LANE1, psi = 0, v = 10 } })
  w.planner:configure({ setSpeed = 15 })
  w:engage('autosteer', 'standard')
  w:run(30)
  check(math.abs(w.ego.v - 15) < 1.2, string.format('Autosteer holds the set speed (%.1f)', w.ego.v))
  local _, y = w:refPos()
  check(math.abs(y - LANE1) < 0.6, 'and keeps the lane')
end)

scenario('obstacleAware', function()
  local w = W.new({ nodes = straight(0, 2000, 5, 17), ego = { x = 100, y = LANE1, psi = 0, v = 0 } })
  w:addCar({ id = 1, x = 100 + 1.4 + 4.6 + 1.5, y = LANE1, dx = 1, dy = 0 })
  w.manual = function(ww) return 0, ww.t > 0.3 and 0.9 or 0, 0 end -- stomps the throttle
  w:run(1.2)
  check(w:saw('obstacleAwareAccel') ~= nil, 'obstacle-aware acceleration limits the launch')
  check(not w.collided, 'no bump into the car in front')
end)

scenario('routeLaneChange', function()
  -- 2+2 lane road with a left turn ahead: gets into the left lane first
  local nodes = straight(0, 1000, 7.5, 20, 100, function(n)
    n.north = { pos = { x = 500, y = 300, z = 0 }, radius = 5, links = {} }
    n.n500.links.north = { drivability = 1, oneWay = false, speedLimit = 13 }
  end)
  local w = W.new({ nodes = nodes, ego = { x = 0, y = RIGHT2, psi = 0, v = 15 } })
  w.planner:setRoute({ 500 + LANE1, 250, 0 }, nil, 'Driveway')
  w:engage('fsd', 'standard')
  local inLeft = false
  w:run(100, function(ww)
    local x, y = ww:refPos()
    if x > 400 and x < 470 and math.abs(y - LEFT2) < 0.8 then inLeft = true end
    return ww:saw('arrived') ~= nil
  end)
  check(w:saw('laneChange', function(e) return e.reason == 'route' end) ~= nil, 'changes lanes to follow the route')
  check(inLeft, 'is in the left lane before the left turn')
  check(w:saw('arrived') ~= nil, 'makes the turn and arrives')
end)

scenario('driverStalk', function()
  local w = W.new({ nodes = straight(0, 3000, 7.5, 25), ego = { x = 0, y = RIGHT2, psi = 0, v = 20 } })
  w:engage('fsd', 'chill')
  w:run(2)
  w.planner:requestLaneChange('left')
  local reached = false
  w:run(10, function(ww) local _, y = ww:refPos(); if math.abs(y - LEFT2) < 0.5 then reached = true end end)
  check(w:saw('laneChange', function(e) return e.reason == 'driver' end) ~= nil, 'turn-signal stalk starts a lane change')
  check(reached, 'reaches the left lane')
end)

-- paddle left on a one-lane road (no lane that way): turn left at the next junction instead,
-- never into oncoming traffic; with a destination, carry on there afterwards
scenario('paddleTurn', function()
  local function run(withDest)
    local w = W.new({ nodes = grid(3, 3, 150), ego = { x = 5, y = LANE1, psi = 0, v = 0 } })
    if withDest then w.planner:setRoute({ 450, LANE1, 0 }, nil, 'Driveway') end
    w:engage('fsd', 'standard')
    w:run(3)
    w.planner:requestLaneChange('left')
    local maxY, turnedAt = -99, nil
    w:run(90, function(ww)
      local x, y = ww:refPos()
      if y > maxY then maxY = y end
      if not turnedAt and y > 20 then turnedAt = x end
      if withDest then return ww:saw('arrived') end
      return y > 60
    end)
    return w, maxY, turnedAt
  end
  local w, maxY, at = run(false)
  check(w:saw('turnRequest', function(e) return not e.none end) ~= nil, 'no lane on the left: plans the next left turn')
  check(maxY > 60 and at and math.abs(at - 150) < 15, 'turns left at the next junction (x ' .. tostring(at) .. ', y ' .. string.format('%.0f', maxY) .. ')')
  local w2, maxY2 = run(true)
  check(maxY2 > 20, 'with a destination: takes the left turn first (' .. string.format('%.0f', maxY2) .. ')')
  check(w2:saw('arrived') ~= nil, '...then still gets to the destination')
end)

-- Quentin: "apply the turn signal and it'll force a turn there": with a junction just ahead,
-- the signal turns there even when a same-direction lane exists
scenario('signalTurn', function()
  local w = W.new({ nodes = grid(3, 3, 150, 7.5), ego = { x = 5, y = RIGHT2, psi = 0, v = 0 } })
  w:engage('fsd', 'standard')
  w:run(4)
  w.planner:requestLaneChange('left')
  local maxY, turnedAt = -99, nil
  w:run(60, function(ww)
    local x, y = ww:refPos()
    if y > maxY then maxY = y end
    if not turnedAt and y > 20 then turnedAt = x end
    return y > 60
  end)
  check(w:saw('laneChange', function(e) return e.reason == 'driver' end) == nil or maxY > 60, 'signal with a junction ahead: turns rather than just changing lanes')
  check(maxY > 60 and turnedAt and math.abs(turnedAt - 150) < 15, string.format('turns left at the junction ahead (x %s, y %.0f)', tostring(turnedAt), maxY))
end)

-- P while FSD drives: pull over and park; taking over cancels it and keeps the trip
scenario('parkPullOver', function()
  local w = W.new({ nodes = straight(0, 5000, 5, 17), ego = { x = 0, y = LANE1, psi = 0, v = 15 } })
  w.planner:setRoute({ 3000, LANE1, 0 }, nil, 'Driveway')
  w:engage('fsd', 'standard')
  w:run(3)
  local x0 = w:refPos()
  check(w.planner:pullOverNow(w:snapshot().ego), 'P while driving: starts pulling over')
  w:run(40, function(ww) return ww:saw('arrived') ~= nil end)
  local x, y = w:refPos()
  check(w:saw('arrived') ~= nil and w.ego.gear == 'P' and w.planner.mode == 'off', 'pulled over, in P, FSD off')
  check(y < LANE1 - 1.0 and y > -5 + 1.3, string.format('at the side of the road (y %.2f)', y))
  check(x - x0 < 120, string.format('stopped soon after (%.0f m)', x - x0))
  -- cancelled by a takeover: trip kept
  local w2 = W.new({ nodes = straight(0, 5000, 5, 17), ego = { x = 0, y = LANE1, psi = 0, v = 15 } })
  w2.planner:setRoute({ 3000, LANE1, 0 }, nil, 'Driveway')
  w2:engage('fsd', 'standard')
  w2:run(2)
  w2.planner:pullOverNow(w2:snapshot().ego)
  w2:run(1)
  w2.planner:disengage('steer')
  check(w2.planner.dest and w2.planner.dest[1] == 3000, 'taking over mid pull-over keeps the original trip')
  local w3 = W.new({ nodes = straight(0, 5000, 5, 17), ego = { x = 0, y = LANE1, psi = 0, v = 15 } })
  w3.planner:setRoute({ 3000, LANE1, 0 }, nil, 'Driveway')
  w3:engage('fsd', 'standard')
  w3:run(2)
  w3.planner:pullOverNow(w3:snapshot().ego)
  w3.planner:setRoute({ 4000, LANE1, 0 }, nil, 'Driveway')
  w3.planner:disengage('steer')
  check(w3.planner.dest and w3.planner.dest[1] == 4000, 'a new trip picked mid pull-over is kept after a takeover')
end)

scenario('arrivalChoice', function()
  local function trip(choice)
    local w = W.new({ nodes = straight(0, 1000, 5, 13.4), ego = { x = 0, y = LANE1, psi = 0, v = 0 } })
    w.planner:setRoute({ 400, LANE1, 0 }, nil, 'Parking Lot')
    if choice then check(w.planner:setArrival(choice), 'setArrival ' .. choice) end
    w:engage('fsd', 'standard')
    w:run(150, function(ww) return ww:saw('arrived') ~= nil end)
    return w
  end
  local w = trip('takeOver')
  local at, a = w:saw('arrived')
  check(at ~= nil and a and a.detail == 'takeOver', 'takeOver: arrived with detail takeOver')
  check(w.ego.gear ~= 'P', 'takeOver: not thrown into Park')
  check(w.ego.v < 0.5, 'takeOver: stopped at the destination')
  local n = 0
  for _, e in ipairs(w.events) do if e.kind == 'arriving' then n = n + 1 end end
  check(n == 1, 'arriving event fires exactly once (' .. n .. ')')
  local w2 = trip('pullOver')
  check(w2:saw('arrived') ~= nil and w2.ego.gear == 'P', 'pullOver: arrives and parks')
  check(select(1, w2.planner:setArrival('nonsense')) == false, 'bad choice rejected')
end)

scenario('fastLane', function()
  -- empty two-lane highway at 55 mph: standard stays right, hurry / Mad Max take the fast lane
  local function endLane(profile, v0)
    local w = W.new({ nodes = straight(0, 4000, 7.5, 25), ego = { x = 0, y = RIGHT2, psi = 0, v = v0 } })
    w:engage('fsd', profile)
    w:run(40)
    local _, y = w:refPos()
    return y, w
  end
  local y = endLane('standard', 24)
  check(math.abs(y - RIGHT2) < 0.8, 'standard keeps right on an empty highway (y ' .. string.format('%.1f', y) .. ')')
  y = endLane('hurry', 24)
  check(math.abs(y - LEFT2) < 0.8, 'hurry moves to the fast lane at highway speed (y ' .. string.format('%.1f', y) .. ')')
  local y2, w2 = endLane('madmax', 20)
  check(math.abs(y2 - LEFT2) < 0.8 and not w2.collided, 'Mad Max in the fast lane, no collision')
end)

scenario('cutIn', function()
  -- a car in the left lane a little ahead of us, going a bit slower: standard waits for a real gap,
  -- furious squeezes in
  local function firstChange(profile)
    local w = W.new({ nodes = straight(0, 3000, 7.5, 25), ego = { x = 0, y = RIGHT2, psi = 0, v = 20 } })
    w:addCar({ id = 1, pts = line(90, RIGHT2, 3000, RIGHT2), speed = 12 })
    w:addCar({ id = 2, pts = line(-30, LEFT2, 3000, LEFT2), s0 = 12, speed = 19 })
    w:engage('fsd', profile)
    w:run(15)
    return w:saw('laneChange'), w
  end
  local tS = firstChange('standard')
  local tF, wF = firstChange('furious')
  check(tF ~= nil, 'furious takes a tight gap')
  check(tS == nil or (tF and tF < tS), 'standard waits longer than furious for the lane change')
  check(not wF.collided, 'furious cut-in without a collision')
end)

scenario('steerFeel', function()
  -- a turn through a grid: comfort steering moves the wheel more slowly than sport, both stay in lane;
  -- the acceleration setting changes how hard it pulls away
  local function drive(feel, accel)
    local w = W.new({ nodes = grid(3, 3, 120, 5), ego = { x = 0, y = LANE1, psi = 0, v = 0 },
      settings = { quirks = { phantomBraking = false, yellowHesitation = false, wiggle = false, weather = true, creep = true }, steerFeel = feel, accelMode = accel } })
    w.planner:setRoute({ 240, 240, 0 }, nil, 'Driveway')
    w:engage('fsd', 'standard')
    local last, maxRate, maxA, prevV = 0, 0, 0, 0
    local prevU = 0
    w:run(80, function(ww)
      if ww.t - last >= 0.1 then
        local dt = ww.t - last; last = ww.t
        maxRate = math.max(maxRate, math.abs(ww.driver.u - prevU) / dt); prevU = ww.driver.u
        maxA = math.max(maxA, (ww.ego.v - prevV) / dt); prevV = ww.ego.v
      end
      return ww:saw('arrived')
    end)
    return maxRate, maxA, w
  end
  local rC, _, wC = drive('comfort', 'standard')
  local rS = drive('sport', 'standard')
  check(wC:saw('arrived') ~= nil and not wC.collided, 'comfort steering still gets there')
  check(rC < rS, string.format('comfort moves the wheel slower than sport (%.2f vs %.2f /s)', rC, rS))
  local _, aChill = drive('standard', 'chill')
  local _, aSport = drive('standard', 'sport')
  check(aChill < aSport, string.format('chill accelerates gentler than sport (%.2f vs %.2f m/s^2)', aChill, aSport))
end)

scenario('rearCross', function()
  -- backing out with the driver's foot down while a car crosses behind: alert, then brake
  local w = W.new({ nodes = straight(0, 2000, 5, 25), ego = { x = 50, y = LANE1, psi = 0, v = 0, gear = 'R' } })
  w:addCar({ id = 1, pts = line(38, -30, 38, 30), speed = 6, s0 = 0 })
  w.manual = function() return 0, 0.5, 0 end
  w:run(12, function(ww) return ww.collided end)
  check(w:saw('rearCrossTraffic') ~= nil, 'Rear Cross Traffic Alert fires')
  check(w:saw('aeb', function(e) return e.reverse end) ~= nil or not w.collided, 'brakes for the crossing car')
  check(not w.collided, 'no collision while reversing')
end)

scenario('offRoad', function()
  -- started well away from any road: it must end up driving on the road, or say no; never sit there braking
  for _, dy in ipairs({ 22, 60 }) do
    local w = W.new({ nodes = straight(0, 3000, 5, 17), ego = { x = 500, y = dy, psi = 0, v = 0 } })
    local ok = w:engage('fsd', 'standard')
    w:run(60)
    local _, y = w:refPos()
    local onRoad = math.abs(y) < 8
    local stuck = w.planner.mode ~= 'off' and not onRoad and w.ego.v < 0.1
    check(not stuck, string.format('%d m off the road: not silently stuck (engage %s, mode %s, y %.0f)', dy, tostring(ok), w.planner.mode, y))
  end
end)

scenario('confirmMode', function()
  local Q = { quirks = { phantomBraking = false, yellowHesitation = false, wiggle = false, weather = true, creep = false }, trafficControl = 'confirm' }
  -- stop sign: it stops, asks, and waits for the go
  local w = W.new({ nodes = grid(2, 2, 150), ego = { x = 5, y = LANE1, psi = 0, v = 0 }, settings = Q,
    signals = { { id = 'stop1', x = 141, y = -7, z = 0, kind = 'stop' } } })
  w.planner:setRoute({ 300, LANE1, 0 }, nil, 'Driveway')
  w:engage('fsd', 'standard')
  w:run(40)
  local x = w:refPos()
  check(w:saw('confirmGo', function(e) return e.what == 'stopSign' end) ~= nil, 'asks for the go at the stop sign')
  check(x < 150 and w.ego.v < 0.2, string.format('waits at the line without the go (x %.0f)', x))
  w.planner:confirm(w.t)
  w:run(40, function(ww) return ww:saw('arrived') end)
  check(w:saw('arrived') ~= nil and not w.collided, 'goes once confirmed and arrives')
  -- an accelerator tap is a go too
  local w2 = W.new({ nodes = grid(2, 2, 150), ego = { x = 5, y = LANE1, psi = 0, v = 0 }, settings = Q,
    signals = { { id = 'stop1', x = 141, y = -7, z = 0, kind = 'stop' } } })
  w2.planner:setRoute({ 300, LANE1, 0 }, nil, 'Driveway')
  w2:engage('fsd', 'standard')
  w2:run(40)
  w2.manualThrottle = 0.6
  w2:run(40, function(ww) return ww:saw('arrived') end)
  check(w2:saw('arrived') ~= nil, 'an accelerator tap confirms too')
  -- a light that turns green after we stopped at red
  local state = 'red'
  local w3 = W.new({ nodes = grid(2, 2, 150), ego = { x = 5, y = LANE1, psi = 0, v = 0 }, settings = Q,
    signals = { { id = 'lt', x = 141, y = -7, kind = 'signal', dirx = 1, diry = 0, get = function() return state end } } })
  w3.planner:setRoute({ 300, LANE1, 0 }, nil, 'Driveway')
  w3:engage('fsd', 'standard')
  w3:run(30)
  state = 'green'
  w3:run(15)
  check(w3:saw('confirmGo', function(e) return e.what == 'light' end) ~= nil and w3:refPos() < 150, 'waits at a green light it stopped for, until confirmed')
  w3.planner:confirm(w3.t)
  w3:run(40, function(ww) return ww:saw('arrived') end)
  check(w3:saw('arrived') ~= nil, 'goes on the green once confirmed')
  -- default mode: no asking
  local w4 = W.new({ nodes = grid(2, 2, 150), ego = { x = 5, y = LANE1, psi = 0, v = 0 },
    signals = { { id = 'stop1', x = 141, y = -7, z = 0, kind = 'stop' } } })
  w4.planner:setRoute({ 300, LANE1, 0 }, nil, 'Driveway')
  w4:engage('fsd', 'standard')
  w4:run(60, function(ww) return ww:saw('arrived') end)
  check(w4:saw('confirmGo') == nil and w4:saw('arrived') ~= nil, 'auto mode never asks')
end)

scenario('furiousDrive', function()
  local function trip(profile)
    local w = W.new({ nodes = grid(3, 3, 150), ego = { x = 5, y = LANE1, psi = 0, v = 0 } })
    w.planner:setRoute({ 440, 300, 0 }, nil, 'Driveway')
    w:engage('fsd', profile)
    local driftSeen, pbSeen = false, false
    w:run(120, function(ww)
      if ww.plan and ww.plan.drift then driftSeen = true end
      return ww:saw('arrived')
    end)
    return w, driftSeen
  end
  local wF, driftF = trip('furious')
  check(wF:saw('arrived') ~= nil and not wF.collided, 'furious gets there without a collision')
  check(driftF, 'furious allows drifts on a clear road')
  local wS, driftS = trip('standard')
  check(not driftS, 'other profiles never drift')
  local tF, tS = wF:saw('arrived'), wS:saw('arrived')
  check(tF and tS and tF < tS, string.format('furious is faster than standard (%.0f s vs %.0f s)', tF or -1, tS or -1))
end)

scenario('laneChangeRate', function()
  -- a busy two-lane highway: a slow car every ~250 m in both lanes. It should pass when there is a real gain,
  -- not weave back and forth.
  local w = W.new({ nodes = straight(0, 6000, 7.5, 27), ego = { x = 0, y = RIGHT2, psi = 0, v = 24 } })
  for i = 1, 14 do
    local y = (i % 2 == 0) and LEFT2 or RIGHT2
    w:addCar({ id = i, pts = line(200 + i * 260, y, 6000, y), speed = 16 + (i % 3) })
  end
  w:engage('fsd', 'standard')
  w:run(150)
  local n = 0
  for _, e in ipairs(w.events) do if e.kind == 'laneChange' then n = n + 1 end end
  print('lane changes in 150 s: ' .. n)
  check(n <= 8, 'not too many lane changes on a busy highway: ' .. n)
  check(not w.collided, 'no collision')
end)

scenario('laneCountFlap', function()
  -- the level's road width wobbles between 1 and 2 lanes every few hundred metres (node radii differ):
  -- that must not make FSD hop between lanes
  local nodes = straight(0, 6000, 7.5, 27, 100, function(nn)
    local k = 0
    for id, n in pairs(nn) do k = k + 1; n.radius = (k % 3 == 0) and 6.4 or 7.5 end
  end)
  local w = W.new({ nodes = nodes, ego = { x = 0, y = RIGHT2, psi = 0, v = 24 } })
  w:addCar({ id = 1, pts = line(400, RIGHT2, 6000, RIGHT2), speed = 14 })
  w:engage('fsd', 'standard')
  w:run(120)
  local n = 0
  for _, e in ipairs(w.events) do if e.kind == 'laneChange' then n = n + 1 end end
  print('lane changes with wobbling width: ' .. n)
  check(n <= 4, 'wobbling road width does not cause lane hopping: ' .. n)
end)

scenario('angledSpot', function()
  -- a spot whose painted lines are 20 degrees off the road's perpendicular: park parallel to the lines
  local a = math.rad(20)
  local w = W.new({ nodes = straight(0, 1000, 5, 13.4), ego = { x = 0, y = LANE1, psi = 0, v = 0 },
    parking = { { x = 300, y = 9, z = 0, dx = -math.sin(a), dy = math.cos(a), known = true } } })
  w.planner:setRoute({ 300, 5, 0 }, nil, 'Parking Lot')
  w:engage('fsd', 'standard')
  w:run(140, function(ww) return ww:saw('arrived') ~= nil end)
  local _, ev = w:saw('arrived')
  check(ev ~= nil, 'arrives')
  -- the nose should point out of the spot along its axis: (sin a, -cos a)
  local want = math.atan2(-math.cos(a), math.sin(a))
  local d = (w.ego.psi - want + math.pi) % (2 * math.pi) - math.pi
  check(math.abs(d) < math.rad(8), string.format('parked parallel to the spot lines (off by %.1f deg)', math.deg(d)))
  check(ev and ev.err ~= nil and math.abs(ev.err.lat) < 1.0, 'reports where it ended up: ' .. (ev and ev.err and string.format('lat %.2f lon %.2f head %.1f', ev.err.lat, ev.err.lon, ev.err.headingDeg) or 'nothing'))
  check(not w.collided, 'no collision')
end)

scenario('turnIntoBusiness', function()
  -- the destination is 40 m off the road (a business): FSD turns in and drives up to it instead of stopping at the curb
  for _, arrival in ipairs({ 'Parking Lot', 'Driveway' }) do
    local w = W.new({ nodes = straight(0, 1000, 5, 13.4), ego = { x = 0, y = LANE1, psi = 0, v = 0 } })
    w.planner:setRoute({ 400, 40, 0 }, nil, arrival)
    w:engage('fsd', 'standard')
    w:run(150, function(ww) return ww:saw('arrived') ~= nil end)
    local x, y = w:refPos()
    check(w:saw('arrived') ~= nil, arrival .. ': arrives')
    check(math.sqrt((x - 400) ^ 2 + (y - 40) ^ 2) < 8, string.format('%s: ends at the business, not on the road (%.0f, %.0f)', arrival, x, y))
    check(not w.collided, arrival .. ': no collision')
  end
end)

print(string.format('%d passed, %d failed', passes, failures))
os.exit(failures == 0 and 0 or 1)
