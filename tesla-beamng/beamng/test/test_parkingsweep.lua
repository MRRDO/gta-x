-- Sweep of destinations / arrival choices / profiles: FSD must end up stopped and parked near where it was sent, never driving past.
-- Run: luajit beamng/test/test_parkingsweep.lua   (VERBOSE=1 prints every case)
package.path = 'beamng/test/?.lua;beamng/mod/lua/common/?.lua;' .. package.path
local W = require('world')
local P = require('teslaBridge/pathing')
local VERBOSE = os.getenv('VERBOSE')

local function straight(x0, x1, r, limit, step)
  local nodes, prev = {}, nil
  for x = x0, x1, step or 100 do
    local id = 'n' .. x
    nodes[id] = { pos = { x = x, y = 0, z = 0 }, radius = r, links = {} }
    if prev then nodes[prev].links[id] = { drivability = 1, oneWay = false, speedLimit = limit } end
    prev = id
  end
  return nodes
end
local LANE1 = -P.laneCenter(5, false, 0)

local fails, total = 0, 0
local function run(name, o)
  total = total + 1
  local spots = {}
  if o.spots then for i = 0, 5 do spots[#spots + 1] = { x = o.dx - 6 + i * 3, y = o.dy + (o.dy > 0 and 2 or -2), z = 0, dx = 0, dy = o.dy > 0 and -1 or 1, known = true } end end
  local w = W.new({ nodes = straight(0, 1600, 5, 13.4, o.step), ego = { x = 0, y = LANE1, psi = 0, v = o.v0 or 0 }, parking = spots })
  w.planner:setRoute({ o.dx, o.dy, 0 }, nil, o.arrival)
  w:engage('fsd', o.profile)
  w:run(220, function(ww) return ww:saw('arrived') ~= nil end)
  local x, y = w:refPos()
  local d = math.sqrt((x - o.dx) ^ 2 + (y - o.dy) ^ 2)
  local arrived = w:saw('arrived') ~= nil
  local limit = (o.dy > 12 or o.dy < -12) and 14 or 10
  if o.arrival == 'Street' or o.arrival == 'Pull Over' then limit = 99; d = math.abs(x - o.dx) + math.max(0, math.abs(y) - 7) end -- along the kerb near it; the kerb is as close as the road gets
  if o.arrival == 'Street' then limit = 20 elseif o.arrival == 'Pull Over' then limit = 40 end
  local ok = arrived and d < limit and not w.collided and math.abs(w.ego.v or 0) < 0.5
  if not ok then fails = fails + 1 end
  if not ok or VERBOSE then print(string.format('%s %-9s dest(%4d,%4d) %-11s %-8s v0=%2d spots=%s -> arrived=%s dist=%.1f x=%.0f y=%.1f v=%.1f%s', ok and 'ok  ' or 'FAIL', '', o.dx, o.dy, tostring(o.arrival), o.profile, o.v0 or 0, tostring(o.spots), tostring(arrived), d, x, y, w.ego.v or 0, w.collided and ' COLLIDED' or '')) end
end

for _, arrival in ipairs({ 'auto', 'Parking Lot', 'Street', 'Driveway', 'Pull Over' }) do
  for _, dy in ipairs({ -3, 3, 6, 25, -30 }) do
    for _, spots in ipairs({ false, true }) do
      for _, profile in ipairs({ 'standard', 'madmax' }) do
        run('c', { dx = 650, dy = dy, arrival = arrival, spots = spots, profile = profile, v0 = 0 })
      end
    end
  end
end
for _, step in ipairs({ 250, 400 }) do
  for _, arrival in ipairs({ 'auto', 'Parking Lot', 'Driveway' }) do
    for _, dy in ipairs({ -3, 6, 40 }) do
      run('c', { dx = 650, dy = dy, arrival = arrival, spots = false, profile = 'standard', v0 = 0, step = step })
      run('c', { dx = 710, dy = dy, arrival = arrival, spots = true, profile = 'standard', v0 = 0, step = step })
    end
  end
end
-- starting at speed, destination close to the start
for _, arrival in ipairs({ 'auto', 'Parking Lot' }) do
  run('c', { dx = 150, dy = 6, arrival = arrival, spots = true, profile = 'standard', v0 = 12 })
  run('c', { dx = 150, dy = -3, arrival = arrival, spots = false, profile = 'madmax', v0 = 14 })
end
print(string.format('%d cases, %d failed', total, fails))
os.exit(fails == 0 and 0 or 1)
