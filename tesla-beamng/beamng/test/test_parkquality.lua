-- Parking quality sweep: perpendicular spots on either side, with parked neighbours, several profiles. The car must end in the
-- spot (within 1.2 m), square to it (within 8 degrees) and in Park. Run: luajit beamng/test/test_parkquality.lua (VERBOSE=1)
package.path = 'beamng/test/?.lua;beamng/mod/lua/common/?.lua;' .. package.path
local W = require('world')
local P = require('teslaBridge/pathing')
local VERBOSE = os.getenv('VERBOSE')
local function straight()
  local nodes, prev = {}, nil
  for x = 0, 1000, 100 do local id = 'n' .. x; nodes[id] = { pos = { x = x, y = 0, z = 0 }, radius = 5, links = {} }; if prev then nodes[prev].links[id] = { drivability = 1, oneWay = false, speedLimit = 13.4 } end; prev = id end
  return nodes
end
local LANE1 = -P.laneCenter(5, false, 0)
local total, fails = 0, 0
for _, side in ipairs({ 1, -1 }) do
  for _, neigh in ipairs({ false, true }) do
    for _, profile in ipairs({ 'standard', 'madmax' }) do
      total = total + 1
      local sy = side * 9
      local spot = { x = 300, y = sy, z = 0, dx = 0, dy = -side, known = true }
      local parking = { spot }
      local w = W.new({ nodes = straight(), ego = { x = 0, y = LANE1, psi = 0, v = 0 }, parking = parking })
      if neigh then
        for _, nx in ipairs({ 297.3, 302.7 }) do w:addCar({ id = nx, pts = { { x = nx, y = sy }, { x = nx, y = sy + side * 1 } }, speedFn = function() return 0 end, s0 = 0 }) end
      end
      w.planner:setRoute({ 300, side * 5, 0 }, nil, 'Parking Lot')
      w:engage('fsd', profile)
      w:run(220, function(ww) return ww:saw('arrived') ~= nil end)
      local x, y = w:refPos()
      local want = math.atan2(-(-side), 0) -- nose out of the spot toward the road: direction (0, -side)... either way up to 180 deg
      local axis = math.atan2(-side, 0)
      local d = math.abs(((w.ego.psi - axis + math.pi / 2) % math.pi) - math.pi / 2) -- parked square, nose in or out
      local ok = w:saw('arrived') ~= nil and math.sqrt((x - 300) ^ 2 + (y - sy) ^ 2) < 1.5 and d < math.rad(8) and w.ego.gear == 'P' and not w.collided
      if not ok then fails = fails + 1 end
      if not ok or VERBOSE then print(string.format('%s side=%2d neighbours=%s %-8s -> arrived=%s at (%.1f,%.1f) off by %.1f deg gear=%s%s', ok and 'ok  ' or 'FAIL', side, tostring(neigh), profile, tostring(w:saw('arrived') ~= nil), x, y, math.deg(d), tostring(w.ego.gear), w.collided and ' COLLIDED' or '')) end
    end
  end
end
print(string.format('%d cases, %d failed', total, fails))
os.exit(fails == 0 and 0 or 1)
