-- teslaBridge/pathing.lua
-- Road-graph routing and path geometry shared by the GE extension (planning)
-- and the vehicle extension (steering). Pure Lua on plain numbers so it runs
-- in either BeamNG VM and in plain LuaJIT for the tests (beamng/test/).
--
-- Coordinates are BeamNG world meters, z up. Headings are 2D (x, y).
-- A "path" is { pts = { {x,y,z, r, lim, ow, drv, node}... }, s = {cumulative m} }.

local M = {}

local sqrt, abs, min, max, atan2, cos, sin, huge = math.sqrt, math.abs, math.min, math.max, math.atan2, math.cos, math.sin, math.huge
local floor, ceil, pi, tan = math.floor, math.ceil, math.pi, math.tan

local MPH = 0.44704

local function clamp(v, lo, hi) if v < lo then return lo elseif v > hi then return hi end return v end
M.clamp = clamp

local function len2(x, y) return sqrt(x * x + y * y) end

local function norm2(x, y)
  local l = sqrt(x * x + y * y)
  if l < 1e-9 then return 0, 0, 0 end
  return x / l, y / l, l
end

-- Signed angle from (ax,ay) to (bx,by), positive = counter-clockwise (left turn).
local function angleBetween(ax, ay, bx, by)
  return atan2(ax * by - ay * bx, ax * bx + ay * by)
end
M.angleBetween = angleBetween

---------------------------------------------------------------------------
-- Speeds
---------------------------------------------------------------------------

-- Default speed (m/s) for a road with no posted limit, from its half-width.
function M.classDefaultSpeed(radius, drivability)
  radius = radius or 3
  if drivability and drivability < 0.5 then return 25 * MPH end
  if radius < 3.5 then return 25 * MPH end
  if radius < 5 then return 35 * MPH end
  if radius < 7 then return 45 * MPH end
  return 65 * MPH
end

-- Map link speedLimit to m/s. BeamNG stores m/s; guard against km/h data.
function M.normalizeLimit(v)
  if type(v) ~= 'number' or v <= 0 then return nil end
  if v > 60 then v = v / 3.6 end
  return v
end

M.PROFILES = {
  sloth    = { offset = -2 * MPH, aLat = 1.8, gap = 3.0, throttle = 0.6 },
  chill    = { offset =  0,       aLat = 2.1, gap = 2.5, throttle = 0.6 },
  standard = { offset =  2 * MPH, aLat = 2.4, gap = 2.0, throttle = 0.6 },
  hurry    = { offset =  5 * MPH, aLat = 2.7, gap = 1.6, throttle = 0.7 },
  madmax   = { offset =  8 * MPH, aLat = 3.0, gap = 1.2, throttle = 0.9 },
}

---------------------------------------------------------------------------
-- Graph
---------------------------------------------------------------------------

-- Convert BeamNG map.getMap().nodes into our graph.
--   nodes[name] = { pos = {x,y,z} | vec3, radius = n, links = { [other] = {oneWay, inNode, drivability, speedLimit, ...} } }
-- Returns graph = { nodes = {[id] = {x,y,z,r}}, adj = {[id] = {[other] = edge}}, edges = {edge...} }
-- edge = { a, b, len, ow, from, drv, lim, key }. For one-way edges `from` is the
-- node traffic starts at (the link's inNode when the map provides it).
function M.buildGraph(mapNodes)
  local g = { nodes = {}, adj = {}, edges = {} }
  for id, n in pairs(mapNodes) do
    local p = n.pos
    if p then
      g.nodes[id] = { x = p.x or p[1], y = p.y or p[2], z = p.z or p[3] or 0, r = n.radius or 3 }
      g.adj[id] = {}
    end
  end
  for id, n in pairs(mapNodes) do
    if g.nodes[id] and n.links then
      for other, l in pairs(n.links) do
        if g.nodes[other] and not g.adj[id][other] then
          local a, b = g.nodes[id], g.nodes[other]
          local ow = l.oneWay and true or false
          local from = nil
          if ow then
            if l.inNode ~= nil then from = l.inNode else from = id end
            -- Some map versions only store the link on the entry node. If the
            -- link exists on both nodes with no inNode, we can't tell direction:
            -- treat as two-way rather than forbid a legal move.
            if l.inNode == nil and mapNodes[other] and mapNodes[other].links and mapNodes[other].links[id] then
              ow, from = false, nil
            end
          end
          local e = {
            a = id, b = other,
            len = max(0.1, sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2 + (a.z - b.z) ^ 2)),
            ow = ow, from = from,
            drv = l.drivability or 1,
            lim = M.normalizeLimit(l.speedLimit),
            name = l.name or l.roadName,
          }
          e.key = #g.edges + 1
          g.edges[e.key] = e
          g.adj[id][other] = e
          g.adj[other] = g.adj[other] or {}
          g.adj[other][id] = e
        end
      end
    end
  end
  return g
end

local function canTraverse(e, fromId)
  return (not e.ow) or e.from == nil or e.from == fromId
end
M.canTraverse = canTraverse

local function edgeSpeed(g, e)
  local r = (g.nodes[e.a].r + g.nodes[e.b].r) * 0.5
  return e.lim or M.classDefaultSpeed(r, e.drv)
end

local function edgeCost(g, e)
  local c = e.len / edgeSpeed(g, e)
  if e.drv < 0.3 then c = c * 10 end
  return c
end

-- Closest edge to (x,y). Optional heading (hx,hy) prefers edges that run the
-- same way and can be driven that way. Returns edge, t (0 at a .. 1 at b), dist.
function M.nearestEdge(g, x, y, hx, hy, maxDist)
  local best, bestT, bestD, bestScore = nil, 0, huge, huge
  maxDist = maxDist or 200
  for _, e in ipairs(g.edges) do
    local a, b = g.nodes[e.a], g.nodes[e.b]
    local ex, ey = b.x - a.x, b.y - a.y
    local l2 = ex * ex + ey * ey
    local t = 0
    if l2 > 1e-9 then t = clamp(((x - a.x) * ex + (y - a.y) * ey) / l2, 0, 1) end
    local px, py = a.x + ex * t, a.y + ey * t
    local d = len2(x - px, y - py)
    if d < maxDist then
      local r = a.r + (b.r - a.r) * t
      local score = max(0, d - r)
      if hx then
        local ux, uy = norm2(ex, ey)
        local dot = ux * hx + uy * hy
        local legal = (dot >= 0 and canTraverse(e, e.a)) or (dot < 0 and canTraverse(e, e.b))
        score = score + (1 - abs(dot)) * 6 + (legal and 0 or 25)
      end
      if e.drv < 0.3 then score = score + 5 end
      if score < bestScore then best, bestT, bestD, bestScore = e, t, d, score end
    end
  end
  return best, bestT, bestD
end

-- Binary min-heap keyed by f.
local function heapPush(h, item, f)
  local n = #h + 1
  h[n] = { f = f, v = item }
  while n > 1 do
    local p = floor(n / 2)
    if h[p].f <= h[n].f then break end
    h[p], h[n] = h[n], h[p]
    n = p
  end
end

local function heapPop(h)
  local n = #h
  if n == 0 then return nil end
  local top = h[1]
  h[1] = h[n]
  h[n] = nil
  n = n - 1
  local i = 1
  while true do
    local l, r, s = 2 * i, 2 * i + 1, i
    if l <= n and h[l].f < h[s].f then s = l end
    if r <= n and h[r].f < h[s].f then s = r end
    if s == i then break end
    h[i], h[s] = h[s], h[i]
    i = s
  end
  return top.v, top.f
end

-- A* between two points on the graph.
-- start: { x, y, hx, hy } (heading used to avoid U-turns). goal: { x, y }.
-- Returns { nodes = {id...}, startEdge, startT, goalEdge, goalT, startPt, goalPt } or nil, err.
function M.route(g, start, goal)
  local se, st = M.nearestEdge(g, start.x, start.y, start.hx, start.hy)
  local ge, gt = M.nearestEdge(g, goal.x, goal.y)
  if not se or not ge then return nil, 'no road near ' .. (se and 'destination' or 'start') end

  local function edgePoint(e, t)
    local a, b = g.nodes[e.a], g.nodes[e.b]
    return { x = a.x + (b.x - a.x) * t, y = a.y + (b.y - a.y) * t, z = a.z + (b.z - a.z) * t, r = a.r + (b.r - a.r) * t }
  end
  local startPt, goalPt = edgePoint(se, st), edgePoint(ge, gt)

  -- Which way along the start edge is "forward"?
  local ax, ay = g.nodes[se.b].x - g.nodes[se.a].x, g.nodes[se.b].y - g.nodes[se.a].y
  local fwdIsB = true
  if start.hx then fwdIsB = (ax * start.hx + ay * start.hy) >= 0 end

  -- Same edge, goal ahead: drive straight there.
  if se == ge and ((fwdIsB and gt >= st) or (not fwdIsB and gt <= st)) then
    return { nodes = {}, startEdge = se, startT = st, goalEdge = ge, goalT = gt, startPt = startPt, goalPt = goalPt }
  end

  local UTURN = 300 -- seconds of penalty: only if nothing else works
  local gScore, came, closed, open = {}, {}, {}, {}
  local maxV = 40
  local function h(id)
    local n = g.nodes[id]
    return len2(n.x - goalPt.x, n.y - goalPt.y) / maxV
  end
  local function seed(id, cost)
    if gScore[id] == nil or cost < gScore[id] then
      gScore[id] = cost
      came[id] = '__start'
      heapPush(open, id, cost + h(id))
    end
  end
  local spd = edgeSpeed(g, se)
  if fwdIsB then
    if canTraverse(se, se.a) then seed(se.b, (1 - st) * se.len / spd) end
    if canTraverse(se, se.b) then seed(se.a, st * se.len / spd + UTURN) end
  else
    if canTraverse(se, se.b) then seed(se.a, st * se.len / spd) end
    if canTraverse(se, se.a) then seed(se.b, (1 - st) * se.len / spd + UTURN) end
  end

  -- Goal entry: arriving at ge.a then driving t*len toward b, or at ge.b then (1-t)*len toward a.
  local gspd = edgeSpeed(g, ge)
  local goalVia = {}
  if canTraverse(ge, ge.a) then goalVia[ge.a] = gt * ge.len / gspd end
  if canTraverse(ge, ge.b) then goalVia[ge.b] = (1 - gt) * ge.len / gspd end

  local bestGoal, bestGoalCost = nil, huge
  local iterations = 0
  while true do
    local id, f = heapPop(open)
    if not id then break end
    if f >= bestGoalCost then break end
    if not closed[id] then
      closed[id] = true
      iterations = iterations + 1
      if goalVia[id] then
        local c = gScore[id] + goalVia[id]
        if c < bestGoalCost then bestGoal, bestGoalCost = id, c end
      end
      local prev = came[id]
      for other, e in pairs(g.adj[id] or {}) do
        if not closed[other] and canTraverse(e, id) and not (e == se and prev == '__start') then
          local c = gScore[id] + edgeCost(g, e)
          if other == prev then c = c + UTURN end
          if gScore[other] == nil or c < gScore[other] then
            gScore[other] = c
            came[other] = id
            heapPush(open, other, c + h(other))
          end
        end
      end
    end
  end
  if not bestGoal then return nil, 'no route' end

  local nodes = {}
  local cur = bestGoal
  while cur and cur ~= '__start' do
    table.insert(nodes, 1, cur)
    cur = came[cur]
  end
  return { nodes = nodes, startEdge = se, startT = st, goalEdge = ge, goalT = gt, startPt = startPt, goalPt = goalPt, cost = bestGoalCost, iterations = iterations }
end

-- Greedy "keep going straight" node list, for autosteer / FSD with no destination.
-- Starts at the edge nearest (x,y) heading (hx,hy); returns a route table like M.route.
function M.followRoad(g, x, y, hx, hy, length)
  local se, st = M.nearestEdge(g, x, y, hx, hy)
  if not se then return nil, 'no road here' end
  local a, b = g.nodes[se.a], g.nodes[se.b]
  local fwdIsB = ((b.x - a.x) * hx + (b.y - a.y) * hy) >= 0
  local prev, cur = se.a, se.b
  if not fwdIsB then prev, cur = se.b, se.a end
  local startPt = { x = a.x + (b.x - a.x) * st, y = a.y + (b.y - a.y) * st, z = a.z + (b.z - a.z) * st, r = a.r }
  local nodes = { cur }
  local seen = { [cur] = true }
  local dist = len2(g.nodes[cur].x - startPt.x, g.nodes[cur].y - startPt.y)
  while dist < (length or 1500) do
    local pn, cn = g.nodes[prev], g.nodes[cur]
    local dx, dy = norm2(cn.x - pn.x, cn.y - pn.y)
    local best, bestScore = nil, huge
    for other, e in pairs(g.adj[cur] or {}) do
      if other ~= prev and not seen[other] and canTraverse(e, cur) then
        local on = g.nodes[other]
        local ox, oy = norm2(on.x - cn.x, on.y - cn.y)
        local turn = abs(angleBetween(dx, dy, ox, oy))
        local score = turn + (e.drv < 0.3 and 2 or 0) + (1 - min(e.drv, 1)) * 0.5
        if turn < 2.2 and score < bestScore then best, bestScore = other, score end
      end
    end
    if not best then break end
    dist = dist + g.adj[cur][best].len
    prev, cur = cur, best
    nodes[#nodes + 1] = cur
    seen[cur] = true
  end
  local last = g.nodes[cur]
  return { nodes = nodes, startEdge = se, startT = st, startPt = startPt, goalPt = { x = last.x, y = last.y, z = last.z, r = last.r }, openEnded = true }
end

---------------------------------------------------------------------------
-- Geometry
---------------------------------------------------------------------------

local function copyPt(p)
  return { x = p.x, y = p.y, z = p.z, r = p.r, lim = p.lim, ow = p.ow, drv = p.drv, node = p.node, edgeName = p.edgeName }
end

-- Route -> centerline points. Each point carries the attributes of the edge
-- that leaves it (r, lim, ow, drv), and junction points keep their node id.
function M.routePoints(g, rt)
  local pts = {}
  local function attrs(p, e)
    if e then p.lim, p.ow, p.drv, p.edgeName = e.lim, e.ow, e.drv, e.name end
    return p
  end
  local seq = rt.nodes
  local firstEdge = rt.startEdge
  if #seq > 0 then
    local e = firstEdge
    pts[1] = attrs({ x = rt.startPt.x, y = rt.startPt.y, z = rt.startPt.z, r = rt.startPt.r }, e)
    for i = 1, #seq do
      local id = seq[i]
      local n = g.nodes[id]
      local nextE = (i < #seq) and g.adj[id][seq[i + 1]] or rt.goalEdge
      pts[#pts + 1] = attrs({ x = n.x, y = n.y, z = n.z, r = n.r, node = id }, nextE or e)
    end
  else
    pts[1] = attrs({ x = rt.startPt.x, y = rt.startPt.y, z = rt.startPt.z, r = rt.startPt.r }, firstEdge)
  end
  local gp = rt.goalPt
  local lastE = rt.goalEdge or firstEdge
  pts[#pts + 1] = attrs({ x = gp.x, y = gp.y, z = gp.z, r = gp.r }, lastE)
  -- Drop duplicates (start/goal exactly on a node).
  local out = { pts[1] }
  for i = 2, #pts do
    local a, b = out[#out], pts[i]
    if len2(a.x - b.x, a.y - b.y) > 0.3 then out[#out + 1] = b
    elseif b.node then out[#out].node = b.node end
  end
  return out
end

-- Round sharp corners with arcs so turns are drivable curves.
function M.filletCorners(pts, opts)
  opts = opts or {}
  local minAngle = opts.minAngle or math.rad(12)
  local out = { copyPt(pts[1]) }
  for i = 2, #pts - 1 do
    local p0, p1, p2 = out[#out], pts[i], pts[i + 1]
    local ix, iy, lin = norm2(p1.x - p0.x, p1.y - p0.y)
    local ox, oy, lout = norm2(p2.x - p1.x, p2.y - p1.y)
    local th = abs(angleBetween(ix, iy, ox, oy))
    if th < minAngle or lin < 0.5 or lout < 0.5 then
      out[#out + 1] = copyPt(p1)
    else
      local r = p1.r or 3
      local offset = p1.ow and 0 or min(r * 0.5, 1.8)
      local R = clamp(r * 1.5 + 3, 6, 14)
      R = max(R, offset + 5)
      local T = R * tan(th / 2)
      local Tmax = 0.45 * min(lin, lout)
      if T > Tmax then T = Tmax end
      local ax, ay = p1.x - ix * T, p1.y - iy * T
      local bx, by = p1.x + ox * T, p1.y + oy * T
      local nseg = max(3, ceil(th / math.rad(8)))
      for k = 0, nseg do
        local t = k / nseg
        local u = 1 - t
        local q = copyPt(k < nseg / 2 and p0 or p1)
        q.x = u * u * ax + 2 * u * t * p1.x + t * t * bx
        q.y = u * u * ay + 2 * u * t * p1.y + t * t * by
        q.z = p1.z
        q.r = p1.r
        q.lim, q.ow, q.drv, q.edgeName = (k < nseg / 2 and p0 or p1).lim, (k < nseg / 2 and p0 or p1).ow, (k < nseg / 2 and p0 or p1).drv, (k < nseg / 2 and p0 or p1).edgeName
        q.node = (k == floor(nseg / 2)) and p1.node or nil
        out[#out + 1] = q
      end
    end
  end
  out[#out + 1] = copyPt(pts[#pts])
  return out
end

-- Uniform spacing. Attributes come from the segment start; node ids snap to the nearest sample.
function M.resample(pts, step)
  if #pts < 2 then return { copyPt(pts[1]) } end
  local out = { copyPt(pts[1]) }
  out[1].node = pts[1].node
  local carry = 0
  for i = 1, #pts - 1 do
    local a, b = pts[i], pts[i + 1]
    local dx, dy, dz = b.x - a.x, b.y - a.y, (b.z or 0) - (a.z or 0)
    local L = len2(dx, dy)
    local d = step - carry
    while d <= L do
      local t = d / L
      local q = copyPt(a)
      q.node = nil
      q.x, q.y, q.z = a.x + dx * t, a.y + dy * t, (a.z or 0) + dz * t
      q.r = (a.r or 3) + ((b.r or 3) - (a.r or 3)) * t
      out[#out + 1] = q
      d = d + step
    end
    carry = L - (d - step)
    if b.node then
      -- snap the node to whichever sample is closest to it
      local lq = out[#out]
      lq.node = lq.node or b.node
    end
  end
  local last = pts[#pts]
  local lq = out[#out]
  if len2(lq.x - last.x, lq.y - last.y) > step * 0.25 then
    out[#out + 1] = copyPt(last)
  else
    lq.x, lq.y, lq.z = last.x, last.y, last.z
  end
  return out
end

-- One Chaikin pass, endpoints kept.
function M.chaikin(pts, passes)
  for _ = 1, passes or 1 do
    if #pts < 3 then return pts end
    local out = { copyPt(pts[1]) }
    for i = 1, #pts - 1 do
      local a, b = pts[i], pts[i + 1]
      local q = copyPt(a); q.node = nil
      q.x, q.y, q.z = 0.75 * a.x + 0.25 * b.x, 0.75 * a.y + 0.25 * b.y, 0.75 * (a.z or 0) + 0.25 * (b.z or 0)
      local r = copyPt(a); r.node = a.node
      r.x, r.y, r.z = 0.25 * a.x + 0.75 * b.x, 0.25 * a.y + 0.75 * b.y, 0.25 * (a.z or 0) + 0.75 * (b.z or 0)
      if i > 1 then out[#out + 1] = q end
      if i < #pts - 1 then out[#out + 1] = r end
    end
    out[#out + 1] = copyPt(pts[#pts])
    pts = out
  end
  return pts
end

-- Shift points sideways into the driving lane. side = 1 right-hand traffic, -1 left-hand.
-- Two-way roads: +min(r*0.5, 1.8) m right of the centerline. One-way: centered.
function M.laneOffset(pts, side)
  side = side or 1
  local out = {}
  local n = #pts
  -- raw offsets, then a moving average so lane changes (two-way <-> one-way,
  -- narrow <-> wide) blend over ~24 samples instead of jumping sideways
  local raw, sm = {}, {}
  for i = 1, n do
    local p = pts[i]
    raw[i] = p.laneOffset or (p.ow and 0 or min((p.r or 3) * 0.5, 1.8)) * side
  end
  local K = 12
  for i = 1, n do
    local sum, cnt = 0, 0
    for j = max(1, i - K), min(n, i + K) do sum = sum + raw[j]; cnt = cnt + 1 end
    sm[i] = sum / cnt
  end
  for i = 1, n do
    local p = pts[i]
    local a, b = pts[max(1, i - 1)], pts[min(n, i + 1)]
    local tx, ty = norm2(b.x - a.x, b.y - a.y)
    local d = sm[i]
    local q = copyPt(p)
    q.x, q.y = p.x + ty * d, p.y - tx * d
    out[i] = q
  end
  return out
end

function M.cumulative(pts)
  local s = { 0 }
  for i = 2, #pts do
    s[i] = s[i - 1] + len2(pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y)
  end
  return s
end

-- Signed curvature (1/m, + = left) at i, from a circle through i-k, i, i+k.
function M.curvatureAt(pts, i, k)
  k = k or 4
  local n = #pts
  local a, b, c = pts[max(1, i - k)], pts[i], pts[min(n, i + k)]
  local abx, aby = b.x - a.x, b.y - a.y
  local bcx, bcy = c.x - b.x, c.y - b.y
  local acx, acy = c.x - a.x, c.y - a.y
  local d = len2(abx, aby) * len2(bcx, bcy) * len2(acx, acy)
  if d < 1e-6 then return 0 end
  return 2 * (abx * acy - aby * acx) / d
end

-- Full pipeline: route -> drivable lane path with arc length and turns.
-- opts: { step = 2, side = 1 }
function M.buildPath(g, rt, opts)
  opts = opts or {}
  local step = opts.step or 2
  local center = M.routePoints(g, rt)
  local turns = M.findTurns(g, center)
  local pts = M.filletCorners(center)
  pts = M.resample(pts, 1)
  pts = M.laneOffset(pts, opts.side or 1)
  pts = M.chaikin(pts, 1)
  pts = M.resample(pts, step)
  local path = { pts = pts, s = M.cumulative(pts), turns = {}, openEnded = rt.openEnded }
  -- place turns on the final path by projecting their junction nodes
  local hint = 1
  for _, t in ipairs(turns) do
    local pr = M.project(path, t.x, t.y, hint, 5, 400)
    if pr then
      hint = pr.i
      path.turns[#path.turns + 1] = { s = pr.s, dir = t.dir, angle = t.angle, node = t.node, road = t.road }
    end
  end
  return path
end

-- Junction turns on the centerline: heading change > 30 deg measured 15 m either side.
function M.findTurns(g, center)
  local out = {}
  local s = M.cumulative(center)
  local function pointAt(sq)
    if sq <= 0 then return center[1] end
    for i = 2, #center do
      if s[i] >= sq then
        local t = (sq - s[i - 1]) / max(1e-6, s[i] - s[i - 1])
        local a, b = center[i - 1], center[i]
        return { x = a.x + (b.x - a.x) * t, y = a.y + (b.y - a.y) * t }
      end
    end
    return center[#center]
  end
  for i = 2, #center - 1 do
    local p = center[i]
    local deg = 0
    if p.node and g.adj[p.node] then for _ in pairs(g.adj[p.node]) do deg = deg + 1 end end
    if deg >= 3 then
      local a, b = pointAt(s[i] - 15), pointAt(s[i] + 15)
      local ix, iy = norm2(p.x - a.x, p.y - a.y)
      local ox, oy = norm2(b.x - p.x, b.y - p.y)
      local ang = angleBetween(ix, iy, ox, oy)
      if abs(ang) > math.rad(30) then
        out[#out + 1] = { x = p.x, y = p.y, dir = ang > 0 and 'left' or 'right', angle = ang, node = p.node, road = center[i].edgeName or '' }
      end
    end
  end
  return out
end

-- Per-point speed caps: limit + profile offset, lateral-accel curve limit,
-- then a backward pass so we brake at `decel` into every slow point.
-- opts: { offset, aLat, decel = 2.5, endSpeed = 0 (nil = open end), arrivalSlow = 3, arrivalDist = 40 }
function M.speedProfile(path, opts)
  local pts = path.pts
  local n = #pts
  local vlim, vcap = {}, {}
  local decel = opts.decel or 2.5
  for i = 1, n do
    local p = pts[i]
    local lim = p.lim or M.classDefaultSpeed(p.r, p.drv)
    vlim[i] = max(1, lim + (opts.offset or 0))
    local k = abs(M.curvatureAt(pts, i, 4))
    local vc = sqrt((opts.aLat or 2.4) / max(k, 1e-4))
    vcap[i] = min(vlim[i], vc)
  end
  if opts.endSpeed then
    local total = path.s[n]
    for i = 1, n do
      if total - path.s[i] < (opts.arrivalDist or 40) then vcap[i] = min(vcap[i], opts.arrivalSlow or 3) end
    end
    vcap[n] = opts.endSpeed
  end
  for i = n - 1, 1, -1 do
    local ds = path.s[i + 1] - path.s[i]
    vcap[i] = min(vcap[i], sqrt(vcap[i + 1] ^ 2 + 2 * decel * ds))
  end
  path.vlim, path.vcap = vlim, vcap
  return path
end

-- Project (x,y) onto the path. Searches [hint-back, hint+fwd] or everything.
-- Returns { i (segment start), t, s, lat (+ = point is left of path), dist, x, y }.
function M.project(path, x, y, hint, back, fwd)
  local pts, S = path.pts, path.s
  local n = #pts
  if n < 2 then
    if n == 1 then return { i = 1, t = 0, s = 0, lat = 0, dist = len2(x - pts[1].x, y - pts[1].y), x = pts[1].x, y = pts[1].y } end
    return nil
  end
  local i0, i1 = 1, n - 1
  if hint then i0, i1 = max(1, hint - (back or 10)), min(n - 1, hint + (fwd or 60)) end
  local best, bestD = nil, huge
  for i = i0, i1 do
    local a, b = pts[i], pts[i + 1]
    local ex, ey = b.x - a.x, b.y - a.y
    local l2 = ex * ex + ey * ey
    local t = 0
    if l2 > 1e-9 then t = clamp(((x - a.x) * ex + (y - a.y) * ey) / l2, 0, 1) end
    local px, py = a.x + ex * t, a.y + ey * t
    local d = (x - px) ^ 2 + (y - py) ^ 2
    if d < bestD then
      bestD = d
      local l = sqrt(l2)
      local lat = 0
      if l > 1e-9 then lat = (ex * (y - a.y) - ey * (x - a.x)) / l end
      best = { i = i, t = t, s = S[i] + (S[i + 1] - S[i]) * t, lat = lat, x = px, y = py }
    end
  end
  if best then best.dist = sqrt(bestD) end
  return best
end

-- Point and index at arc length s (clamped).
function M.pointAt(path, s, hint)
  local pts, S = path.pts, path.s
  local n = #pts
  if s <= 0 then return pts[1].x, pts[1].y, pts[1].z or 0, 1 end
  if s >= S[n] then return pts[n].x, pts[n].y, pts[n].z or 0, n end
  local i = max(1, min(n - 1, hint or 1))
  while i > 1 and S[i] > s do i = i - 1 end
  while i < n - 1 and S[i + 1] < s do i = i + 1 end
  local t = (s - S[i]) / max(1e-6, S[i + 1] - S[i])
  local a, b = pts[i], pts[i + 1]
  return a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t, (a.z or 0) + ((b.z or 0) - (a.z or 0)) * t, i
end

-- Linear interpolation of a per-point array at arc length s.
function M.valueAt(path, arr, s, hint)
  local S = path.s
  local n = #S
  if s <= 0 then return arr[1] end
  if s >= S[n] then return arr[n] end
  local _, _, _, i = M.pointAt(path, s, hint)
  local t = (s - S[i]) / max(1e-6, S[i + 1] - S[i])
  return arr[i] + (arr[i + 1] - arr[i]) * t
end

-- Pure pursuit. (x,y) reference point, (hx,hy) unit heading, s = car's arc length.
-- Returns desired curvature (1/m, + = left), target x, y, alpha.
function M.purePursuit(path, s, x, y, hx, hy, L, hint)
  local tx, ty = M.pointAt(path, s + L, hint)
  local S = path.s
  local remaining = S[#S] - s
  if remaining < L then
    -- extend past the end along the last segment so the car doesn't swerve at the end
    local pts = path.pts
    local a, b = pts[max(1, #pts - 1)], pts[#pts]
    local ex, ey = norm2(b.x - a.x, b.y - a.y)
    tx, ty = b.x + ex * (L - remaining), b.y + ey * (L - remaining)
  end
  local dx, dy = tx - x, ty - y
  local alpha = angleBetween(hx, hy, dx, dy)
  local Ld = max(1, len2(dx, dy))
  return 2 * sin(alpha) / Ld, tx, ty, alpha
end

-- Offset the last `dist` meters of a path toward the right edge (curbside stop).
function M.pullOver(path, dist, side)
  side = side or 1
  local pts = path.pts
  local S = path.s
  local total = S[#S]
  local shifted = {}
  for i = 1, #pts do
    local p = pts[i]
    local q = copyPt(p)
    local into = total - S[i]
    if into < dist then
      local w = clamp(1 - into / dist, 0, 1)
      w = w * w * (3 - 2 * w)
      local a, b = pts[max(1, i - 1)], pts[min(#pts, i + 1)]
      local tx, ty = norm2(b.x - a.x, b.y - a.y)
      local lane = p.ow and 0 or min((p.r or 3) * 0.5, 1.8)
      local extra = max(0, (p.r or 3) - 1.2 - lane) * w * side
      q.x, q.y = p.x + ty * extra, p.y - tx * extra
    end
    shifted[i] = q
  end
  path.pts = shifted
  path.s = M.cumulative(shifted)
  return path
end

-- Append a curve from the path end into a parking spot at (px,py) facing (dx,dy).
function M.appendParking(path, px, py, pz, dx, dy, step)
  step = step or 2
  local pts = path.pts
  local n = #pts
  local e = pts[n]
  local a = pts[max(1, n - 1)]
  local ex, ey = norm2(e.x - a.x, e.y - a.y)
  local D = len2(px - e.x, py - e.y)
  if D < 1 then return path end
  local ux, uy = norm2(dx, dy)
  -- If the spot faces away from us, drive in nose-first anyway (align with approach).
  if ux * (px - e.x) + uy * (py - e.y) < 0 then ux, uy = -ux, -uy end
  local c1x, c1y = e.x + ex * D * 0.4, e.y + ey * D * 0.4
  local c2x, c2y = px - ux * D * 0.4, py - uy * D * 0.4
  local segs = max(4, ceil(D / 0.5))
  local curve = {}
  for k = 1, segs do
    local t = k / segs
    local u = 1 - t
    local q = copyPt(e)
    q.node = nil
    q.x = u * u * u * e.x + 3 * u * u * t * c1x + 3 * u * t * t * c2x + t * t * t * px
    q.y = u * u * u * e.y + 3 * u * u * t * c1y + 3 * u * t * t * c2y + t * t * t * py
    q.z = (e.z or 0) + ((pz or e.z or 0) - (e.z or 0)) * t
    q.lim = 3
    curve[#curve + 1] = q
  end
  local all = {}
  for i = 1, n do all[i] = pts[i] end
  for _, q in ipairs(curve) do all[#all + 1] = q end
  path.pts = M.resample(all, step)
  path.s = M.cumulative(path.pts)
  path.parked = true
  return path
end

-- Max |curvature| over a path range, for sanity checks.
function M.maxCurvature(path, i0, i1)
  local k = 0
  for i = max(1, i0 or 1), min(#path.pts, i1 or #path.pts) do
    k = max(k, abs(M.curvatureAt(path.pts, i, 2)))
  end
  return k
end

return M
