-- Reverse driving + maneuvers against a bicycle model. Run: luajit beamng/test/test_maneuver.lua

package.path = 'beamng/mod/lua/common/?.lua;' .. package.path
local C = require('teslaBridge/control')
local Mv = require('teslaBridge/maneuver')

local failures, passes = 0, 0
local function check(cond, msg)
  if cond then passes = passes + 1 else failures = failures + 1; print('FAIL: ' .. msg) end
end

-- run segments like the planner does: one plan per segment, stop at its end, shift, next
local function runSegments(car, segs, opts)
  opts = opts or {}
  local d = C.new({ steerSign = opts.guessSign or 1 })
  local wb, dmax = 2.9, math.rad(34)
  local dt = 1 / 60
  local trace = {}
  for si, seg in ipairs(segs) do
    local flat, vcap = {}, {}
    for _, p in ipairs(seg.pts) do flat[#flat + 1] = p.x; flat[#flat + 1] = p.y; flat[#flat + 1] = 0; vcap[#vcap + 1] = seg.maxSpeed or 1.5 end
    vcap[#vcap] = 0
    d:setPlan({ seq = si, pts = flat, vcap = vcap, dir = seg.dir, maxSpeed = seg.maxSpeed })
    local t = 0
    while t < 40 do
      local hx, hy = math.cos(car.psi), math.sin(car.psi)
      local out = d:update(dt, { x = car.x + hx * 1.4, y = car.y + hy * 1.4, hx = hx, hy = hy, v = car.v, yawRate = car.v * math.tan(car.delta) / wb })
      local want = -(opts.trueSign or 1) * out.steer * dmax
      local rate = math.rad(90) * dt
      car.delta = car.delta + math.max(-rate, math.min(rate, want - car.delta))
      local dir = seg.dir
      local acc = 3.0 * out.throttle * dir
      local nv = car.v + acc * dt
      local stop = 8 * out.brake + 6 * (out.parkingbrake or 0)
      if nv > 0 then nv = math.max(0, nv - stop * dt) elseif nv < 0 then nv = math.min(0, nv + stop * dt) end
      car.v = nv
      car.psi = car.psi + car.v * math.tan(car.delta) / wb * dt
      car.x = car.x + math.cos(car.psi) * car.v * dt
      car.y = car.y + math.sin(car.psi) * car.v * dt
      trace[#trace + 1] = { x = car.x, y = car.y, psi = car.psi }
      t = t + dt
      if (out.remaining or 9) < 0.5 and math.abs(car.v) < 0.05 then break end
    end
    car.v = 0
  end
  return trace
end

local function angDiff(a, b)
  local d = (a - b) % (2 * math.pi)
  if d > math.pi then d = d - 2 * math.pi end
  return math.abs(d)
end

-- 1. back out of a spot north of an east-west road, then face east
do
  -- car's reference point (1.4 m ahead of the rear axle) at (0, 9), nose north
  local car = { x = 0, y = 9 - 1.4, psi = math.pi / 2, v = 0, delta = 0 }
  local ego = { x = 0, y = 9, hx = 0, hy = 1 }
  local segs = Mv.backOut(ego, { x = 0, y = -1.8, dx = 1, dy = 0 }, 6)
  check(segs and #segs == 1 and segs[1].dir == -1, 'backOut gives one reverse segment')
  check(Mv.backOut({ x = 0, y = -8, hx = 0, hy = 1 }, { x = 0, y = -1.8, dx = 1, dy = 0 }) == nil, 'no reverse needed when the road is ahead')
  runSegments(car, segs)
  local rx, ry = car.x + math.cos(car.psi) * 1.4, car.y + math.sin(car.psi) * 1.4
  local e = segs[1].pts[#segs[1].pts]
  check(math.sqrt((rx - e.x) ^ 2 + (ry - e.y) ^ 2) < 1.5, string.format('backs out to the lane (%.1f, %.1f vs %.1f, %.1f)', rx, ry, e.x, e.y))
  check(angDiff(car.psi, 0) < math.rad(25), 'ends facing east, heading ' .. math.deg(car.psi))
end

-- 2. three-point turn on a 10 m road, each leg planned from the car's real pose
do
  local car = { x = -1.4, y = -1.8, psi = 0, v = 0, delta = 0 }
  local road = { cx = 0, cy = 0, dx = 1, dy = 0, r = 5 }
  local worst, legs, dirs, lastDir = 0, 0, {}, nil
  while legs < 6 do
    local hx, hy = math.cos(car.psi), math.sin(car.psi)
    local seg = Mv.kTurnNext({ x = car.x + hx * 1.4, y = car.y + hy * 1.4, hx = hx, hy = hy }, road, 5.5, lastDir)
    if not seg then break end
    legs = legs + 1
    dirs[#dirs + 1] = seg.dir
    lastDir = seg.dir
    local tr = runSegments(car, { seg })
    if os.getenv('DEBUG') then print(string.format('leg %d dir %d -> psi %.0f y %.1f', legs, seg.dir, math.deg(car.psi), car.y)) end
    for _, p in ipairs(tr) do
      for _, off in ipairs({ 2.3 + 1.4, -2.3 + 1.4 }) do
        worst = math.max(worst, math.abs(p.y + math.sin(p.psi) * off))
      end
    end
  end
  check(dirs[1] == 1 and dirs[2] == -1 and dirs[3] == 1, 'kTurn goes forward, reverse, forward')
  check(legs <= 5, 'turns around in at most 5 legs, took ' .. legs)
  check(angDiff(car.psi, math.pi) < math.rad(20), 'car ends facing west, heading ' .. math.deg(car.psi))
  check(worst < 5.8, string.format('stays on the road (max |y| of bumpers %.1f m)', worst))
end

-- 3. back into a perpendicular spot on the north side
do
  local q, rev = Mv.backIn({ x = 20, y = 8, outx = 0, outy = -1 }, { x = 20, y = -1.8, dx = 1, dy = 0 }, 6)
  check(q.x > 25, 'stops past the spot before reversing')
  -- drive forward to q first
  local fwd = {}
  for x = -1, q.x, 1 do fwd[#fwd + 1] = { x = x, y = -1.8 } end
  local car = { x = -2.4, y = -1.8, psi = 0, v = 0, delta = 0 }
  runSegments(car, { { dir = 1, pts = fwd, maxSpeed = 2.5 }, rev })
  local rx, ry = car.x + math.cos(car.psi) * 1.4, car.y + math.sin(car.psi) * 1.4
  check(math.sqrt((rx - 20) ^ 2 + (ry - 8) ^ 2) < 1.5, string.format('ends in the spot (%.1f, %.1f)', rx, ry))
  check(angDiff(car.psi, -math.pi / 2) < math.rad(20), 'parked facing out (south), heading ' .. math.deg(car.psi))
end

-- 4. reverse steering works with an inverted-steering car whose sign was already learned
do
  local car = { x = 0, y = 9 - 1.4, psi = math.pi / 2, v = 0, delta = 0 }
  local segs = Mv.backOut({ x = 0, y = 9, hx = 0, hy = 1 }, { x = 0, y = -1.8, dx = 1, dy = 0 }, 6)
  runSegments(car, segs, { guessSign = -1, trueSign = -1 })
  check(angDiff(car.psi, 0) < math.rad(25), 'inverted car backs out too, heading ' .. math.deg(car.psi))
end

print(string.format('%d passed, %d failed', passes, failures))
os.exit(failures == 0 and 0 or 1)
