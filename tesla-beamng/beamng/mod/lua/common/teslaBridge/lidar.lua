-- Virtual lidar: a fan of static ray casts around the nose (or the tail), turned into "what is solid where" for the planner.
-- No rendering, no GPU: about 60 rays a scan. Pure Lua; the ray function is injected (cast(x, y, z, dx, dy, dz, dist) -> hit distance | nil).
--
-- Two rays per angle: a HIGH one (bumper height) and a LOW one (about curb height).
--   solid = the high ray hit (wall, pole, car, fence)
--   low   = only the low ray hit (a curb, a kerb ramp, a low step): the planner treats these gently, never as a reason to stop
local M = {}
M.__index = M

local sqrt, abs, cos, sin, min, max, pi = math.sqrt, math.abs, math.cos, math.sin, math.min, math.max, math.pi

function M.new(cast)
  return setmetatable({ cast = cast, pts = {}, t = -1, dirSign = 1, range = 0 }, M)
end

-- scan around the car. dirSign = 1 for the front fan, -1 for the rear one; range in metres.
function M:scan(ego, dirSign, range, t)
  local cast = self.cast
  if not cast then self.pts = {}; return self.pts end
  dirSign = dirSign or 1
  range = range or 24
  local hx, hy = ego.hx * dirSign, ego.hy * dirSign
  local half = (ego.len or 4.6) * 0.5
  local ox, oy = ego.x + hx * (half + 0.05), ego.y + hy * (half + 0.05) -- (a hair outside the bumper: a ray that starts inside the car hits the car)
  local z0 = ego.z or 0
  local pts = {}
  -- denser straight ahead (where the car is going), sparser to the sides
  -- (out to 110 degrees each way: on a turn the inside corner of the car sweeps past things that are beside the nose, not in front of it)
  local angs = {}
  for a = -110, 110, 5 do angs[#angs + 1] = a end
  for a = -27.5, 27.5, 5 do angs[#angs + 1] = a end
  for _, a in ipairs(angs) do
    local r = a * pi / 180
    local c, s = cos(r), sin(r)
    -- car frame: forward = (hx, hy), left = (-hy, hx)
    local dx, dy = hx * c - hy * s, hy * c + hx * s
    local dHi = cast(ox, oy, z0 + 0.6, dx, dy, 0, range)
    local dLo = cast(ox, oy, z0 + 0.12, dx, dy, 0, range)
    local d, kind
    -- upright = both rays agree (wall, pole, car); a high ray alone is something raised (a bar, a car's overhang);
    -- a low ray that hits well before the high one is the ground rising or a curb: never solid
    if dHi and (not dLo or abs(dHi - dLo) < 0.8) then d, kind = dLo or dHi, 'solid'
    elseif dLo then d, kind = dLo, 'low' end
    if d then
      pts[#pts + 1] = { a = a, d = d, x = ox + dx * d, y = oy + dy * d, f = d * c, l = d * s, kind = kind } -- f: forward, l: left of the fan's direction
    end
  end
  self.pts, self.t, self.dirSign, self.range = pts, t or self.t, dirSign, range
  self.ox, self.oy, self.hx, self.hy = ox, oy, hx, hy
  return pts
end

-- Distance from the fan origin along `poly` (list of {x, y}, starting at or near the car) to the first solid hit
-- that lies within `halfW` of the polyline, plus the hit's signed lateral offset (+ = left of the polyline's direction).
-- kinds: a set like { solid = true } (default) or { solid = true, low = true }.
function M:alongHit(poly, halfW, kinds, skip, minF)
  kinds = kinds or { solid = true }
  minF = minF or 0.3 -- hits beside the bumper are not 'ahead' (they are the walls the car is already passing)
  local best, bestLat, bestP
  local run = 0
  for i = 1, #poly - 1 do
    local a, b = poly[i], poly[i + 1]
    local sx, sy = b.x - a.x, b.y - a.y
    local sl = sqrt(sx * sx + sy * sy)
    if sl > 1e-6 then
      local ux, uy = sx / sl, sy / sl
      for _, p in ipairs(self.pts) do
        if kinds[p.kind] and (p.f >= minF or abs(p.a) <= 35) and not (skip and skip(p)) then
          local rx, ry = p.x - a.x, p.y - a.y
          local along = rx * ux + ry * uy
          if along >= -0.2 and along <= sl + 0.2 then
            local lat = -rx * uy + ry * ux
            if abs(lat) < halfW then
              local s = run + max(0, along)
              if not best or s < best then best, bestLat, bestP = s, lat, p end
            end
          end
        end
      end
    end
    run = run + sl
    if best and best < run then break end -- nothing later can be nearer
  end
  return best, bestLat, bestP
end

-- nearest solid thing straight ahead inside a corridor of half-width halfW (metres from the fan origin), or nil
function M:straightAhead(halfW, kinds)
  kinds = kinds or { solid = true }
  local best
  for _, p in ipairs(self.pts) do
    if kinds[p.kind] and p.f > 0 and abs(p.l) < halfW and (not best or p.f < best) then best = p.f end
  end
  return best
end

-- room to each side beside the car over the next `reach` metres: smallest sideways distance to a solid hit (nil = open)
function M:sideRoom(reach)
  local left, right
  for _, p in ipairs(self.pts) do
    if p.kind == 'solid' and p.f > -1 and p.f < reach then
      if p.l > 0 then if not left or p.l < left then left = p.l end
      else if not right or -p.l < right then right = -p.l end end
    end
  end
  return left, right
end

-- compact copy for the app's debug view: car-frame points { f, l, k } rounded to 0.1 m, k = 1 solid / 0 low
function M:debugPoints()
  local out = {}
  for _, p in ipairs(self.pts) do out[#out + 1] = { math.floor(p.f * 10 + 0.5) / 10, math.floor(p.l * 10 + 0.5) / 10, p.kind == 'solid' and 1 or 0 } end
  return out
end

-- Gentle steering: given a driven line (polyline, shifted already), find the sideways nudge (m, + = left) that clears
-- a solid hit on it. Tries 0.2 m steps up to maxShift on both sides, smaller first; returns nil when no nudge within
-- maxShift clears it (stop / go another way instead).
function M:clearShift(poly, halfW, ahead, maxShift, skip)
  local function clear(sh)
    -- shift the polyline sideways by sh
    local moved = {}
    for i = 1, #poly do
      local a = poly[min(#poly, i)]
      local b = poly[min(#poly, i + 1)]
      local c = poly[max(1, i - 1)]
      local tx, ty = b.x - c.x, b.y - c.y
      local tl = sqrt(tx * tx + ty * ty)
      if tl < 1e-6 then tx, ty, tl = 1, 0, 1 end
      moved[i] = { x = a.x - ty / tl * sh, y = a.y + tx / tl * sh }
    end
    local d = self:alongHit(moved, halfW, nil, skip)
    return not d or d > ahead
  end
  local k = 1
  while k * 0.2 <= maxShift + 1e-6 do
    local sh = k * 0.2
    -- the side with more room first
    local l, r = self:sideRoom(ahead)
    local first = ((l or 99) >= (r or 99)) and 1 or -1
    for _, sgn in ipairs({ first, -first }) do
      if clear(sgn * sh) then return sgn * sh end
    end
    k = k + 1
  end
  return nil
end

return M
