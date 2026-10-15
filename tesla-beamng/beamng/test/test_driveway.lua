-- Driveways are skipped unless allowed; the accidental re-engage's "still on the line" check; the pole bundle. Run: luajit beamng/test/test_driveway.lua
package.path = 'beamng/test/?.lua;beamng/mod/lua/common/?.lua;' .. package.path
local W = require('world')
local P = require('teslaBridge/pathing')
local fails, total = 0, 0
local function check(c, msg) total = total + 1; if not c then fails = fails + 1; print('FAIL: ' .. msg) end end

local nodes, prev = {}, nil
for x = 0, 600, 100 do
  local id = 'n' .. x
  nodes[id] = { pos = { x = x, y = 0, z = 0 }, radius = 5, links = {} }
  if prev then nodes[prev].links[id] = { drivability = 1, oneWay = false, speedLimit = 13.4 } end
  prev = id
end
local spots = {}
for i = 0, 9 do spots[#spots + 1] = { x = 300 + i * 3, y = 40, z = 0, dx = 0, dy = -1, known = true } end -- a lot (10 spots in a row, 40 m off the road)
spots[#spots + 1] = { x = 120, y = 60, z = 0, dx = 0, dy = -1, known = true }                         -- a lone space far from the road: a driveway
spots[#spots + 1] = { x = 200, y = 7, z = 0, dx = 1, dy = 0, known = true }                           -- a lone space at the roadside: street parking
local w = W.new({ nodes = nodes, ego = { x = 0, y = -2.5, psi = 0, v = 0 }, parking = spots })
local pl = w.planner
check(pl:isDriveway(spots[11]) == true, 'a lone spot well off the road is a driveway')
check(pl:isDriveway(spots[1]) == false, 'a spot in a lot is not')
check(pl:isDriveway(spots[12]) == false, 'a lone spot at the roadside is street parking, not a driveway')
local ego = { x = 100, y = 0 }
local ids = pl:freeSpotsNear(ego, {}, 400, 20)
local has = function(t, id) for _, v in ipairs(t) do if v == id then return true end end return false end
check(not has(ids, 11) and has(ids, 1) and has(ids, 12), 'Banish candidates leave the driveway out')
pl.settings.allowDriveways = true
ids = pl:freeSpotsNear(ego, {}, 400, 20)
check(has(ids, 11), 'with "allow driveways" on it may use it')
check(select(1, pl:nearestFreeSpot(ego, {}, 400)) ~= nil, 'nearest free spot works')
pl.settings.allowDriveways = false
local ok = pl:parkAtSpot(11, ego, {}, { road = true })
check(ok == true, 'a spot picked on the map always works, driveway or not')

-- the bump check
pl.path = { pts = { { x = 0, y = 0 }, { x = 10, y = 0 }, { x = 20, y = 0 }, { x = 30, y = 0 } }, s = { 0, 10, 20, 30 } }
check(pl:onPath({ x = 12, y = 0.4, hx = 1, hy = 0 }, 1.6, 20) == true, 'a bump: still on the line, pointing along it')
check(pl:onPath({ x = 12, y = 3.5, hx = 1, hy = 0 }, 1.6, 20) == false, 'steered 3.5 m off the line: not a bump')
check(pl:onPath({ x = 12, y = 0.2, hx = 0.6, hy = 0.8 }, 1.6, 20) == false, 'pointing 53 degrees off the line: not a bump')

-- a thin pole between the old rays is seen by the dense bundle
local pole = { x = 14, y = 0.55, r = 0.1 }
pl.castRay = function(x, y, z, dx, dy, dz, dist)
  -- a vertical pole 0.1 m wide at (14, 0.55)
  if math.abs(dx) < 0.5 then return nil end
  local t = (pole.x - x) / dx
  if t < 0 or t > dist then return nil end
  local py = y + dy * t
  if math.abs(py - pole.y) < pole.r and z < 2 then return t end
  return nil
end
local e = { x = 11.5, y = 0, z = 0, hx = 1, hy = 0, len = 4.6, wid = 1.9 }
check(pl:aheadBlocked(e, 1) == true, 'aheadBlocked sees a 0.1 m pole at the edge of the lane')
local d = pl:forwardClearDist({ x = 5, y = 0, z = 0, hx = 1, hy = 0, len = 4.6, wid = 1.9 }, 14)
check(d ~= nil and d > 5 and d < 8, 'forwardClearDist gives the distance to the pole (' .. tostring(d) .. ')')
print(string.format('%d passed, %d failed', total - fails, fails))
os.exit(fails == 0 and 0 or 1)
