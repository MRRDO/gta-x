-- teslaBridge/maneuver.lua
-- Low-speed maneuvers made of forward/reverse segments (FSD v14 style):
--   backOut  - reverse out of a parking spot onto the road, ending aligned with traffic
--   kTurn    - three-point turn to face the other way on a road
--   backIn   - pull past a spot, then reverse into it (ends facing out)
-- A maneuver is a list of segments { dir = 1 | -1, pts = {{x,y,z}...}, maxSpeed }.
-- The planner drives them one by one: stop at the end of each, shift, go on.
-- Pure Lua (tested in beamng/test/).

local M = {}

local sqrt, abs, min, max, cos, sin, atan2, pi = math.sqrt, math.abs, math.min, math.max, math.cos, math.sin, math.atan2, math.pi

local function norm(x, y)
  local l = sqrt(x * x + y * y)
  if l < 1e-9 then return 0, 0, 0 end
  return x / l, y / l, l
end

-- Cubic Bezier from p0 leaving along (t0x,t0y) to p1 arriving along (t1x,t1y) (both unit, in the
-- direction of travel), sampled every `step` m. Handle lengths scale with the gap.
function M.bezier(p0, t0x, t0y, p1, t1x, t1y, step, handle)
  step = step or 0.5
  local _, _, D = norm(p1.x - p0.x, p1.y - p0.y)
  local h = (handle or 0.45) * D
  local c1x, c1y = p0.x + t0x * h, p0.y + t0y * h
  local c2x, c2y = p1.x - t1x * h, p1.y - t1y * h
  local n = max(4, math.ceil(D * 1.6 / step))
  local pts = {}
  for k = 0, n do
    local t = k / n
    local u = 1 - t
    pts[#pts + 1] = {
      x = u * u * u * p0.x + 3 * u * u * t * c1x + 3 * u * t * t * c2x + t * t * t * p1.x,
      y = u * u * u * p0.y + 3 * u * u * t * c1y + 3 * u * t * t * c2y + t * t * t * p1.y,
      z = (p0.z or 0) + ((p1.z or 0) - (p0.z or 0)) * t,
    }
  end
  return pts
end

-- Largest |curvature| along a polyline (three-point circle fit).
function M.maxCurvature(pts)
  local k = 0
  for i = 2, #pts - 1 do
    local a, b, c = pts[i - 1], pts[i], pts[i + 1]
    local abx, aby, bcx, bcy, acx, acy = b.x - a.x, b.y - a.y, c.x - b.x, c.y - b.y, c.x - a.x, c.y - a.y
    local d = sqrt((abx * abx + aby * aby) * (bcx * bcx + bcy * bcy) * (acx * acx + acy * acy))
    if d > 1e-9 then k = max(k, abs(2 * (abx * acy - aby * acx) / d)) end
  end
  return k
end

-- Bezier that respects a minimum turning radius: lengthen the handles until it fits.
local function feasibleBezier(p0, t0x, t0y, p1, t1x, t1y, rmin)
  local best, bestK
  for _, h in ipairs({ 0.45, 0.55, 0.65, 0.35, 0.75 }) do
    local pts = M.bezier(p0, t0x, t0y, p1, t1x, t1y, 0.5, h)
    local k = M.maxCurvature(pts)
    if not bestK or k < bestK then best, bestK = pts, k end
    if k <= 1 / rmin then return pts, k end
  end
  return best, bestK
end

--- Back out of a parking spot.
-- ego = { x, y, z, hx, hy } (heading = where the nose points, into the spot)
-- road = { x, y, z (closest point in the lane we'll use), dx, dy (direction we'll drive after) }
-- Returns segments, or nil when the road isn't behind us (just drive forward).
function M.backOut(ego, road, rmin)
  rmin = rmin or 6
  local bx, by = road.x - ego.x, road.y - ego.y
  if bx * ego.hx + by * ego.hy > 0 then return nil end -- road is in front: no reverse needed
  local dx, dy = norm(road.dx, road.dy)
  -- stop point: up the road "behind" the direction we'll drive, so the tail swings into the lane
  local e = { x = road.x - dx * rmin * 0.9, y = road.y - dy * rmin * 0.9, z = road.z }
  -- reversing: we move along -heading; at the end we move along -road direction
  local pts, k = feasibleBezier(ego, -ego.hx, -ego.hy, e, -dx, -dy, rmin)
  return { { dir = -1, pts = pts, maxSpeed = 1.6, kind = 'backOut', curvature = k } }
end

-- Kinematic bicycle roll-out used by kTurn: advance the car along a constant-steer arc.
local function arc(x, y, psi, dir, curv, maxLen, stop)
  local pts = { { x = x, y = y } }
  local ds = 0.25
  local len = 0
  while len < maxLen do
    psi = psi + dir * curv * ds
    x = x + dir * cos(psi) * ds
    y = y + dir * sin(psi) * ds
    len = len + ds
    pts[#pts + 1] = { x = x, y = y }
    if stop(x, y, psi) then break end
  end
  return pts, x, y, psi
end

--- Multi-point turn on a two-way road, one leg at a time from where the car really is.
-- ego = { x, y, z, hx, hy }, road = { cx, cy (a centerline point), dx, dy (road direction we
-- came along), r (half width) }, lastDir = direction of the previous leg (nil at the start).
-- Returns the next segment, or nil when the car faces the other way (turn finished).
-- Overhang (reference point to bumper) taken as ~2.3 m.
function M.kTurnNext(ego, road, rmin, lastDir)
  rmin = rmin or 6
  local k = 1 / rmin
  local rx, ry = norm(road.dx, road.dy)
  local function lat(x, y) return (x - road.cx) * -ry + (y - road.cy) * rx end
  local over, margin = 2.3, 0.6
  local psi0 = atan2(ego.hy, ego.hx)
  local goal = atan2(-ry, -rx) -- facing back the way we came
  local function err(ps)
    local d = (goal - ps) % (2 * pi)
    if d > pi then d = d - 2 * pi end
    return d -- + = still need to turn left
  end
  if abs(err(psi0)) < math.rad(15) then return nil end
  local z = ego.z or 0
  local noseLat = lat(ego.x + cos(psi0) * over, ego.y + sin(psi0) * over)
  local roomAhead = noseLat < road.r - margin - 0.3
  local seg
  if roomAhead and (lastDir ~= 1 or abs(err(psi0)) < math.rad(60)) then
    -- forward, full left, until the nose nears the far edge or we're lined up
    local ex, ey, eps
    seg, ex, ey, eps = arc(ego.x, ego.y, psi0, 1, k, 30, function(px, py, ps)
      return lat(px + cos(ps) * over, py + sin(ps) * over) > road.r - margin or abs(err(ps)) < math.rad(6)
    end)
    if abs(err(eps)) < math.rad(6) then
      -- lined up: run out straight a few meters so the car finishes the rotation
      for d = 1, 6 do seg[#seg + 1] = { x = ex + cos(eps) * d, y = ey + sin(eps) * d } end
    end
    for _, p in ipairs(seg) do p.z = z end
    return { dir = 1, pts = seg, maxSpeed = 1.5, kind = 'kTurn' }
  end
  -- reverse, full right (heading keeps rotating left), until the tail nears the near edge
  local start = psi0
  seg = arc(ego.x, ego.y, psi0, -1, -k, 30, function(px, py, ps)
    return lat(px - cos(ps) * over, py - sin(ps) * over) < -road.r + margin or abs(err(ps)) < math.rad(15)
      or (ps - start) > math.rad(80)
  end)
  for _, p in ipairs(seg) do p.z = z end
  return { dir = -1, pts = seg, maxSpeed = 1.3, kind = 'kTurn' }
end

--- Reverse into a perpendicular spot.
-- spot = { x, y, z, outx, outy } (outx/outy: from the spot toward the road)
-- road = { x, y, z (lane point beside the spot), dx, dy (driving direction) }
-- Returns the forward approach end point (where to stop) and the reverse segment.
function M.backIn(spot, road, rmin)
  rmin = rmin or 6
  local dx, dy = norm(road.dx, road.dy)
  local ox, oy = norm(spot.outx, spot.outy)
  local q = { x = road.x + dx * (rmin + 2), y = road.y + dy * (rmin + 2), z = road.z }
  -- reverse: start moving along -road dir, finish moving into the spot (-out)
  local pts, k = feasibleBezier(q, -dx, -dy, spot, -ox, -oy, rmin)
  return q, { dir = -1, pts = pts, maxSpeed = 1.3, kind = 'backIn', curvature = k }
end

-- Length of a polyline.
function M.length(pts)
  local L = 0
  for i = 2, #pts do L = L + sqrt((pts[i].x - pts[i - 1].x) ^ 2 + (pts[i].y - pts[i - 1].y) ^ 2) end
  return L
end

return M
