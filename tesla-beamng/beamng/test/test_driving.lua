-- Plain-LuaJIT tests for the pathing + driver code. Run: luajit beamng/test/test_driving.lua
-- (from tesla-beamng/). A kinematic bicycle car stands in for BeamNG physics.

package.path = 'beamng/mod/lua/common/?.lua;' .. package.path
local P = require('teslaBridge/pathing')
local C = require('teslaBridge/control')

local failures, passes = 0, 0
local function check(cond, msg)
  if cond then passes = passes + 1 else failures = failures + 1; print('FAIL: ' .. msg) end
end
local function approx(a, b, tol) return math.abs(a - b) <= tol end

-- A city grid: nodes every 150 m, radius 5 (two-lane) except a one-way avenue on y=300 (east only).
local function grid()
  local nodes = {}
  local B = 150
  for i = 0, 4 do
    for j = 0, 4 do
      nodes[i .. '_' .. j] = { pos = { x = i * B, y = j * B, z = 0 }, radius = 5, links = {} }
    end
  end
  local function link(a, b, data)
    nodes[a].links[b] = data or { drivability = 1, oneWay = false }
  end
  for i = 0, 4 do
    for j = 0, 4 do
      local id = i .. '_' .. j
      if i < 4 then
        if j == 2 then
          link(id, (i + 1) .. '_' .. j, { drivability = 1, oneWay = true, inNode = id })
        else
          link(id, (i + 1) .. '_' .. j)
        end
      end
      if j < 4 then link(id, i .. '_' .. (j + 1)) end
    end
  end
  -- a gentle curve road off the east side
  nodes.c1 = { pos = { x = 650, y = 0, z = 0 }, radius = 4, links = {} }
  nodes.c2 = { pos = { x = 740, y = 40, z = 0 }, radius = 4, links = {} }
  nodes.c3 = { pos = { x = 790, y = 120, z = 0 }, radius = 4, links = {} }
  link('4_0', 'c1'); link('c1', 'c2'); link('c2', 'c3')
  return nodes
end

local g = P.buildGraph(grid())
check(#g.edges == 40 + 3, 'edge count ' .. #g.edges)

-- 1. routing
do
  local rt = P.route(g, { x = 5, y = -2, hx = 1, hy = 0 }, { x = 450, y = 440 })
  check(rt ~= nil, 'route found')
  local path = P.buildPath(g, rt)
  local S = path.s
  check(S[#S] > 800 and S[#S] < 1200, 'route length sane ' .. S[#S])
  local p1, pn = path.pts[1], path.pts[#path.pts]
  check(math.abs(pn.x - 450) < 4 and math.abs(pn.y - 440) < 4, 'ends near goal')
  check(math.abs(p1.x - 5) < 4, 'starts near start')
  -- spacing ~2 m, no jumps
  local maxGap = 0
  for i = 2, #path.pts do maxGap = math.max(maxGap, S[i] - S[i - 1]) end
  check(maxGap < 2.6, 'no gaps in path ' .. maxGap)
  check(#path.turns >= 1, 'turns detected ' .. #path.turns)
end

-- 2. one-way respected: going west on y=300 isn't allowed
do
  local rt = P.route(g, { x = 600, y = 290, hx = -1, hy = 0 }, { x = 5, y = 300 })
  check(rt ~= nil, 'route around one-way')
  local usedOneWayBackwards = false
  for i = 1, #rt.nodes - 1 do
    local e = g.adj[rt.nodes[i]][rt.nodes[i + 1]]
    if e.ow and e.from ~= rt.nodes[i] then usedOneWayBackwards = true end
  end
  check(not usedOneWayBackwards, 'no wrong-way on one-way')
end

-- 3. lane offset is to the right of travel
do
  local rt = P.route(g, { x = 20, y = 0, hx = 1, hy = 0 }, { x = 130, y = 0 })
  local path = P.buildPath(g, rt)
  local mid = path.pts[math.floor(#path.pts / 2)]
  check(approx(mid.y, -1.8, 0.2), 'eastbound lane is at y=-1.8, got ' .. mid.y)
end

-- 4. speed profile slows for turns and stops at the end
do
  local rt = P.route(g, { x = 5, y = 0, hx = 1, hy = 0 }, { x = 150, y = 100 })
  local path = P.buildPath(g, rt)
  P.speedProfile(path, { offset = 0, aLat = 2.4, endSpeed = 0 })
  local vmin, vmax = 1e9, 0
  for i = 5, #path.pts - 30 do vmin = math.min(vmin, path.vcap[i]); vmax = math.max(vmax, path.vcap[i]) end
  check(vmin < 7, 'slows for the 90-degree turn: ' .. vmin)
  check(vmax > 14, 'cruises between turns: ' .. vmax)
  check(path.vcap[#path.vcap] == 0, 'stops at the end')
end

-- 5. closed-loop drive with a bicycle model
local function drive(opts)
  local rt = opts.route or P.route(g, opts.start, opts.goal)
  local path = P.buildPath(g, rt)
  local prof = P.PROFILES[opts.profile or 'standard']
  P.speedProfile(path, { offset = prof.offset, aLat = prof.aLat, endSpeed = 0 })
  local car = { x = opts.start.x, y = opts.start.y, psi = math.atan2(opts.start.hy, opts.start.hx), v = 0, delta = 0 }
  local wb, dmax = 2.9, math.rad(34)
  local trueSign = opts.trueSign or 1
  local d = C.new({ steerSign = opts.guessSign or 1 })
  local seq = 0
  local plan
  local maxLat, t = 0, 0
  local dt = 1 / 60
  local stopHeld = 0
  local log = {}
  local pr0
  local maxSpeedOver = 0
  while t < (opts.timeout or 240) do
    -- GE side at 10 Hz: window of the global path
    if not plan or (t * 10) % 1 < dt * 10 then
      pr0 = P.project(path, car.x, car.y, pr0 and pr0.i or nil, 10, 80) or pr0
      local i0 = math.max(1, pr0.i - 5)
      local i1 = math.min(#path.pts, pr0.i + 150)
      local flat, vcap = {}, {}
      for i = i0, i1 do
        local p = path.pts[i]
        flat[#flat + 1] = p.x; flat[#flat + 1] = p.y; flat[#flat + 1] = 0
        vcap[#vcap + 1] = path.vcap[i]
      end
      seq = seq + 1
      plan = { seq = seq, pts = flat, vcap = vcap, gapTime = prof.gap, throttleMax = prof.throttle }
      if opts.stopAtS then
        local sw = opts.stopAtS - path.s[i0]
        if sw > -5 and not opts.stopCleared then plan.stopS = sw end
      end
      if opts.lead then
        local ls = opts.lead.s0 + opts.lead.v * t
        plan.lead = { s = ls - path.s[i0] - 4.5, v = opts.lead.v }
      end
      d:setPlan(plan)
    end
    local ref = 1.4 -- reference point ahead of the rear axle, like a BeamNG ref node
    local hx, hy = math.cos(car.psi), math.sin(car.psi)
    local sense = { x = car.x + hx * ref, y = car.y + hy * ref, hx = hx, hy = hy, v = car.v,
      yawRate = car.v * math.tan(car.delta) / wb }
    local out = d:update(dt, sense)
    -- actuators
    local want = -trueSign * out.steer * dmax
    local rate = math.rad(90) * dt
    car.delta = car.delta + P.clamp(want - car.delta, -rate, rate)
    local acc = 3.5 * out.throttle - 8 * out.brake - 0.05 * car.v - 0.0005 * car.v * car.v
    if out.throttle > 0 and out.brake > 0 then error('throttle and brake together') end
    car.v = math.max(0, car.v + acc * dt)
    car.psi = car.psi + car.v * math.tan(car.delta) / wb * dt
    car.x = car.x + math.cos(car.psi) * car.v * dt
    car.y = car.y + math.sin(car.psi) * car.v * dt
    t = t + dt
    if t > 3 and out.lat and math.abs(out.lat) > maxLat then maxLat = math.abs(out.lat); log.worst = string.format("x=%.0f y=%.0f v=%.1f vt=%.1f s=%.0f", car.x, car.y, car.v, out.targetSpeed, out.s) end
    local lim = path.vlim and P.valueAt(path, path.vlim, out.s or 0) or 99
    maxSpeedOver = math.max(maxSpeedOver, car.v - lim)
    if opts.stopAtS and not opts.stopCleared and car.v < 0.1 and out.stopDist and out.stopDist < 6 then
      stopHeld = stopHeld + dt
      if stopHeld > 2 then opts.stopCleared = true; log.stoppedAt = out.stopDist end
    end
    if opts.lead then
      local ls = opts.lead.s0 + opts.lead.v * t
      local gap = ls - 4.5 - (out.s or 0) - path.s[math.max(1, pr0.i - 5)]
      log.minGap = math.min(log.minGap or 1e9, gap)
      if t > 40 then log.gapAt40 = log.gapAt40 or gap end
    end
    if (out.remaining or 99) < 1.5 and car.v < 0.05 then log.arrived = t; break end
  end
  local pn = path.pts[#path.pts]
  log.endErr = math.sqrt((car.x - pn.x) ^ 2 + (car.y - pn.y) ^ 2)
  log.maxLat, log.t, log.flipped, log.maxOver = maxLat, t, d.flipped, maxSpeedOver
  return log
end

do
  local r = drive({ start = { x = 5, y = -1.8, hx = 1, hy = 0 }, goal = { x = 450, y = 440 } })
  check(r.arrived ~= nil, 'drives multi-turn route and arrives (t=' .. r.t .. ')')
  check(r.maxLat < 1.2, 'stays in lane, max lateral error ' .. r.maxLat)
  check(r.endErr < 3, 'stops at destination, off by ' .. r.endErr)
  check(r.maxOver < 1.0, 'never speeds past limit+profile, over by ' .. r.maxOver)
  print(string.format('  route: %.0fs, max lat %.2f m (%s), end err %.2f m', r.arrived or -1, r.maxLat, r.worst or '', r.endErr))
end

do
  local r = drive({ start = { x = 5, y = -1.8, hx = 1, hy = 0 }, goal = { x = 450, y = 440 }, trueSign = -1 })
  check(r.arrived ~= nil, 'learns inverted steering and still arrives')
  check((r.flipped or 0) >= 1, 'flipped steering sign')
  print(string.format('  inverted: flips %d, max lat %.2f m', r.flipped or 0, r.maxLat))
end

do
  local r = drive({ start = { x = 5, y = -1.8, hx = 1, hy = 0 }, goal = { x = 790, y = 120 }, profile = 'madmax' })
  check(r.arrived ~= nil, 'curvy road arrives')
  check(r.maxLat < 1.5, 'curvy road lateral ' .. r.maxLat)
end

do
  local r = drive({ start = { x = 5, y = -1.8, hx = 1, hy = 0 }, goal = { x = 600, y = 0 }, stopAtS = 200 })
  check(r.stoppedAt ~= nil and r.stoppedAt > 0.5 and r.stoppedAt < 4, 'stops before stop line: ' .. tostring(r.stoppedAt))
  check(r.arrived ~= nil, 'continues after stop sign')
end

do
  local r = drive({ start = { x = 5, y = -1.8, hx = 1, hy = 0 }, goal = { x = 600, y = 0 }, lead = { s0 = 60, v = 8 }, timeout = 70 })
  check((r.minGap or 0) > 5, 'never closer than 5 m to lead: ' .. tostring(r.minGap))
  check(r.gapAt40 and r.gapAt40 > 12 and r.gapAt40 < 26, 'settles near 2 s gap at 8 m/s (16 m): ' .. tostring(r.gapAt40))
end

-- 6. follow-road (no destination)
do
  local rt = P.followRoad(g, 10, -1, 1, 0, 1000)
  check(rt and #rt.nodes >= 4, 'follow-road goes straight through junctions')
  check(rt.nodes[1] == '1_0' and rt.nodes[2] == '2_0', 'follow-road heads east')
end

-- 7. parking + pull over geometry
do
  local rt = P.route(g, { x = 5, y = 0, hx = 1, hy = 0 }, { x = 120, y = 0 })
  local path = P.buildPath(g, rt)
  P.pullOver(path, 30)
  local pn = path.pts[#path.pts]
  check(pn.y < -2.5, 'pull over moves toward the right edge: ' .. pn.y)
  local path2 = P.buildPath(g, rt)
  P.appendParking(path2, 135, -12, 0, 0, -1)
  local q = path2.pts[#path2.pts]
  check(approx(q.x, 135, 0.5) and approx(q.y, -12, 0.5), 'parking path ends in the spot')
end

print(string.format('%d passed, %d failed', passes, failures))
os.exit(failures == 0 and 0 or 1)
