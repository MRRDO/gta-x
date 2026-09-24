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
  local w = W.new({ nodes = straight(0, 1000, 5, 13.4), ego = { x = 400, y = LANE1, psi = 0, v = 0 } })
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

print(string.format('%d passed, %d failed', passes, failures))
os.exit(failures == 0 and 0 or 1)
