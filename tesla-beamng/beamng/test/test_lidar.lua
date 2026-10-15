-- The virtual lidar's classification on synthetic worlds. Run: luajit beamng/test/test_lidar.lua
package.path = 'beamng/mod/lua/common/?.lua;' .. package.path
local Ld = require('teslaBridge/lidar')
local passes, fails = 0, 0
local function check(c, m) if c then passes = passes + 1 else fails = fails + 1; print('FAIL: ' .. m) end end
local ego = { x = 0, y = 0, z = 0.5, hx = 1, hy = 0, len = 4.6, wid = 1.9 }

-- ground rising 30% ahead of the nose: a ray at height h (relative to ego.z = 0.5 above the flat road at 0) meets it at x = (h + 0.5 - 0)/0.3 ... ground z = 0.3 * x
local function slope(k)
  return function(x, y, z, dx, dy, dz, dist)
    if dx <= 1e-6 then return nil end
    -- ray at height z, going +x: hits ground z=k*x when x = z/k ... (measured from the origin along the ray)
    local t = (z / k - x) / dx
    if t > 0 and t < dist then return t end
  end
end
local L = Ld.new(slope(0.3))
L:scan(ego, 1, 30, 0)
check(L:straightAhead(1.0) == nil, 'a 30% hill is not a wall')

-- a pole 0.3 m wide, 10 m ahead, tall
local pole = Ld.new(function(x, y, z, dx, dy, dz, dist)
  local tx = 10 - x
  if dx > 1e-6 then
    local t = tx / dx
    local py = y + dy * t
    if t > 0 and t < dist and math.abs(py) < 0.15 then return t end
  end
end)
pole:scan(ego, 1, 30, 0)
local g = pole:straightAhead(1.0)
check(g and g > 7 and g < 8, 'a pole 10 m ahead is solid (' .. tostring(g) .. ')')

-- a curb: only the lowest ray hits
local curb = Ld.new(function(x, y, z, dx, dy, dz, dist)
  if z - ego.z > 0.3 then return nil end
  local t = (8 - x) / math.max(dx, 1e-6)
  if dx > 1e-6 and t > 0 and t < dist then return t end
end)
curb:scan(ego, 1, 30, 0)
check(curb:straightAhead(1.0) == nil, 'a curb is not solid')
local c = curb:alongHit({ { x = 2.4, y = 0 }, { x = 20, y = 0 } }, 0.95, { low = true })
check(c ~= nil, 'a curb is a low hit')
print(string.format('%d passed, %d failed', passes, fails))
