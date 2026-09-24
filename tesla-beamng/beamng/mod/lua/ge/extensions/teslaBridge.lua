-- teslaBridge (game-engine extension)
-- TCP server for the Node relay (newline-delimited JSON on 127.0.0.1:8766),
-- player-vehicle state fan-out, commands, road-graph export, traffic, traffic
-- signals, parking spots, and the autopilot's route planner. The per-frame
-- driving (steering/throttle/brake through player inputs) lives in the
-- vehicle extension teslaAutopilot; this file sends it a plan at 10 Hz.
--
-- BeamNG API names used here were checked against BeamNG 0.39-era mod code.
-- Anything less certain is called through `try()` and reported by the
-- `debug` command, so a wrong guess degrades a feature instead of the mod.

local M = {}

local P = require('teslaBridge/pathing')

local logTag = 'teslaBridge'
local PORT = 8766
local PROTOCOL = 1
local MAX_QUEUE = 512 * 1024 -- bytes of droppable output before we skip frames

local socket = nil
local server, client = nil, nil
local inbuf = ''
local outq, outPos, outBytes = {}, 1, 0
local nextBindTry = 0

local gameTime, realTime = 0, 0
local tPlan, tTraffic, tHeartbeat, tMapPoll = 0, 0, 0, 0

-- world model
local level = nil
local graph = nil        -- pathing graph
local mapMsg = nil       -- cached map message (table)
local mapPending = false
local signals = {}       -- { id, x, y, z, kind = 'stop'|'signal', dirx, diry, get = fn -> 'red'|'yellow'|'green'|nil }
local parking = {}       -- { x, y, z, dx, dy }
local traffic = {}       -- [id] = { x, y, z, dx, dy, v, w, l, t }

-- vehicles
local playerId = nil
local lastVehState = {}  -- [vid] = realTime of last state message
local lastLoadTry = {}
local vehSize = {}       -- [vid] = { w, l }
local vehDiag = nil

-- autopilot / route
local ap = {
  mode = 'off', profile = 'standard',
  dest = nil, stops = nil, arrival = nil,
  path = nil, hint = nil, seq = 0,
  cleared = {}, clearedS = -1e9, stopHold = 0,
  lastVehSpeed = 0, arrived = false,
  control = nil, nextTurn = nil, leadGap = nil, remaining = nil, speedLimit = nil,
  lastDisengage = nil,
}

---------------------------------------------------------------------------
-- helpers
---------------------------------------------------------------------------

local function try(fn, ...)
  local ok, a, b, c = pcall(fn, ...)
  if ok then return a, b, c end
  return nil
end

local function num(x, digits)
  if type(x) ~= 'number' or x ~= x or x == math.huge or x == -math.huge then return 0 end
  local m = 10 ^ (digits or 2)
  return math.floor(x * m + 0.5) / m
end

local function v3(p) return { num(p.x), num(p.y), num(p.z) } end

local function logI(msg) if log then log('I', logTag, msg) else print(logTag .. ': ' .. msg) end end
local function logW(msg) if log then log('W', logTag, msg) else print(logTag .. ' WARN: ' .. msg) end end

local function playerVehicle()
  if getPlayerVehicle then return getPlayerVehicle(0) end
  if be and be.getPlayerVehicle then return be:getPlayerVehicle(0) end
end

local function allVehicles()
  if getAllVehicles then return getAllVehicles() end
  local t = {}
  if be then for i = 0, be:getObjectCount() - 1 do t[#t + 1] = be:getObject(i) end end
  return t
end

local function vehicleById(id)
  if not id then return nil end
  if getObjectByID then return getObjectByID(id) end
  if be and be.getObjectByID then return be:getObjectByID(id) end
  if scenetree and scenetree.findObjectById then return scenetree.findObjectById(id) end
end

local function vehQueue(veh, code)
  if veh then veh:queueLuaCommand(code) end
end

local function toVehicle(veh, fn, tbl)
  vehQueue(veh, string.format('if teslaAutopilot then teslaAutopilot.%s(%q) end', fn, jsonEncode(tbl)))
end

---------------------------------------------------------------------------
-- networking
---------------------------------------------------------------------------

local function send(tbl, droppable)
  if not client then return end
  if droppable and outBytes > MAX_QUEUE then return end
  local ok, s = pcall(jsonEncode, tbl)
  if not ok or not s then logW('encode failed for ' .. tostring(tbl.t)); return end
  outq[#outq + 1] = s .. '\n'
  outBytes = outBytes + #s + 1
end
M.send = send

local function event(kind, detail)
  send({ t = 'event', kind = kind, detail = detail })
end

local function closeClient(reason)
  if client then
    pcall(function() client:close() end)
    logI('relay disconnected (' .. tostring(reason) .. ')')
  end
  client, inbuf, outq, outPos, outBytes = nil, '', {}, 1, 0
end

local function flush()
  while client and outq[1] do
    local data = outq[1]
    local last, err, partial = client:send(data, outPos)
    if last then
      outBytes = outBytes - (#data - outPos + 1)
      table.remove(outq, 1)
      outPos = 1
    elseif err == 'timeout' then
      if partial and partial >= outPos then
        outBytes = outBytes - (partial - outPos + 1)
        outPos = partial + 1
      end
      return
    else
      closeClient(err)
      return
    end
  end
end

local handleCommand -- forward

local function netUpdate()
  if not socket then
    local ok, s = pcall(require, 'socket')
    if not ok then return end
    socket = s
  end
  if not server and realTime >= nextBindTry then
    local s, err = socket.bind('127.0.0.1', PORT)
    if s then
      s:settimeout(0)
      server = s
      logI('listening on 127.0.0.1:' .. PORT)
    else
      logW('bind failed: ' .. tostring(err) .. ' (retrying)')
      nextBindTry = realTime + 5
    end
  end
  if server then
    local c = server:accept()
    if c then
      if client then closeClient('replaced') end
      c:settimeout(0)
      pcall(function() c:setoption('tcp-nodelay', true) end)
      client = c
      logI('relay connected')
      send({ t = 'hello', protocol = PROTOCOL, game = 'BeamNG.drive', version = beamng_versionb or beamng_version or '?' })
      if mapMsg then send(mapMsg) else mapPending = true end
    end
  end
  if client then
    for _ = 1, 200 do
      local line, err, partial = client:receive('*l')
      if line then
        local full = inbuf .. line
        inbuf = ''
        if #full > 0 then
          local ok, msg = pcall(jsonDecode, full)
          if ok and type(msg) == 'table' then
            local ok2, e = pcall(handleCommand, msg)
            if not ok2 then logW('command failed: ' .. tostring(e)); event('error', tostring(e)) end
          else
            logW('bad json from relay')
          end
        end
      elseif err == 'timeout' then
        if partial and #partial > 0 then inbuf = inbuf .. partial end
        break
      else
        closeClient(err)
        break
      end
    end
    flush()
  end
end

---------------------------------------------------------------------------
-- level / map
---------------------------------------------------------------------------

local function levelName()
  local f = getMissionFilename and getMissionFilename() or ''
  return f:match('levels/([^/]+)/') or (f ~= '' and f) or nil
end

local function findSignals()
  signals = {}
  local found = {}
  -- 1) the traffic-signal system
  local ts = rawget(_G, 'core_trafficSignals') or (extensions and extensions.core_trafficSignals)
  if ts then
    local data
    for _, fname in ipairs({ 'getSignalsDict', 'getSignals', 'getValues', 'getData', 'getInstances' }) do
      if type(ts[fname]) == 'function' then
        data = try(ts[fname])
        if type(data) == 'table' then break end
      end
    end
    local instances = data and (data.instances or data.signals or data) or {}
    local controllers = data and data.controllers
    for key, inst in pairs(instances) do
      if type(inst) == 'table' and (inst.pos or inst.position) then
        local p = inst.pos or inst.position
        local d = inst.dir or inst.direction
        local name = tostring(inst.name or inst.id or key)
        local typ = string.lower(tostring(inst.signalType or inst.type or inst.controllerType or ''))
        local ctrl = controllers and inst.controllerId and controllers[inst.controllerId]
        local ctype = ctrl and string.lower(tostring(ctrl.type or ctrl.name or '')) or ''
        local kind = ((typ .. ctype):find('stop') and not (typ .. ctype):find('light')) and 'stop' or 'signal'
        local function getState()
          local st
          if type(inst.getState) == 'function' then st = try(inst.getState, inst) end
          if st == nil then st = inst.state or inst.signalState or inst.action or inst.targetState end
          if st == nil and ctrl then st = ctrl.state or ctrl.activeState or ctrl.currState end
          if type(st) == 'table' then st = st.name or st.type or st.state end
          st = string.lower(tostring(st or ''))
          if st:find('red') or st:find('stop') then return 'red' end
          if st:find('yellow') or st:find('amber') or st:find('caution') then return 'yellow' end
          if st:find('green') or st:find('go') then return 'green' end
          return nil
        end
        signals[#signals + 1] = {
          id = 'sig:' .. name, x = p.x, y = p.y, z = p.z, kind = kind,
          dirx = d and d.x or nil, diry = d and d.y or nil, get = kind == 'signal' and getState or nil,
        }
        found.ts = (found.ts or 0) + 1
      end
    end
  end
  -- 2) stop-sign props placed in the level
  local statics = scenetree and scenetree.findClassObjects and try(scenetree.findClassObjects, 'TSStatic') or {}
  local scanned = 0
  for _, name in ipairs(statics) do
    scanned = scanned + 1
    if scanned > 40000 then break end
    local o = scenetree.findObject(name)
    local shape = o and (try(function() return o.shapeName end) or try(function() return o:getField('shapeName', '') end))
    if shape and type(shape) == 'string' then
      local s = shape:lower()
      if (s:find('stop_sign') or s:find('stopsign') or s:find('sign_stop')) and not s:find('bus') then
        local p = o:getPosition()
        signals[#signals + 1] = { id = 'prop:' .. tostring(name), x = p.x, y = p.y, z = p.z, kind = 'stop', prop = true }
        found.props = (found.props or 0) + 1
      end
    end
  end
  logI(string.format('signals: %d from traffic system, %d stop-sign props', found.ts or 0, found.props or 0))
end

local function findParking()
  parking = {}
  local function add(p, fx, fy)
    if p then parking[#parking + 1] = { x = p.x, y = p.y, z = p.z, dx = fx or 0, dy = fy or 1 } end
  end
  local gp = rawget(_G, 'gameplay_parking')
  if gp and type(gp.getParkingSpots) == 'function' then
    local spots = try(gp.getParkingSpots)
    local list = spots and (spots.objects or spots.sorted or spots) or {}
    for _, sp in pairs(list) do
      if type(sp) == 'table' and sp.pos then
        local dir = sp.dirVec
        if not dir and sp.rot and vec3 then dir = try(function() return sp.rot * vec3(0, 1, 0) end) end
        add(sp.pos, dir and dir.x, dir and dir.y)
      end
    end
  end
  if #parking == 0 and scenetree and scenetree.findClassObjects then
    for _, name in ipairs(try(scenetree.findClassObjects, 'BeamNGParking') or {}) do
      local o = scenetree.findObject(name)
      if o then
        local p = o:getPosition()
        local fwd = try(function() return o:getTransform():getColumn(1) end)
        add(p, fwd and fwd.x, fwd and fwd.y)
      end
    end
  end
  logI('parking spots: ' .. #parking)
end

local function minimapInfo(lvl)
  local info = jsonReadFile and try(jsonReadFile, '/levels/' .. lvl .. '/info.json')
  local mm = info and info.minimap
  if type(mm) == 'table' and mm[1] then mm = mm[1] end
  if type(mm) == 'table' and mm.file then
    return { file = mm.file, offset = mm.offset, size = mm.size }
  end
end

local function buildMap()
  local lvl = levelName()
  if not lvl or not map or not map.getMap then return false end
  local md = try(map.getMap)
  if not md or not md.nodes or next(md.nodes) == nil then return false end
  graph = P.buildGraph(md.nodes)
  local nodes, links = {}, {}
  local minx, miny, maxx, maxy = 1e9, 1e9, -1e9, -1e9
  for id, n in pairs(graph.nodes) do
    nodes[#nodes + 1] = { id = id, pos = { num(n.x, 1), num(n.y, 1), num(n.z, 1) }, radius = num(n.r, 1) }
    minx, miny, maxx, maxy = math.min(minx, n.x), math.min(miny, n.y), math.max(maxx, n.x), math.max(maxy, n.y)
  end
  for _, e in ipairs(graph.edges) do
    local a, b = e.a, e.b
    if e.ow and e.from == b then a, b = b, a end
    links[#links + 1] = { a = a, b = b, oneWay = e.ow, speedLimit = e.lim and num(e.lim, 1) or nil, drivability = num(e.drv, 2), name = e.name }
  end
  findSignals()
  findParking()
  local sig = {}
  for _, s in ipairs(signals) do sig[#sig + 1] = { id = s.id, pos = { num(s.x), num(s.y), num(s.z) }, kind = s.kind } end
  local park = {}
  for _, p in ipairs(parking) do park[#park + 1] = { pos = { num(p.x), num(p.y), num(p.z) }, dir = { num(p.dx, 3), num(p.dy, 3), 0 } } end
  level = lvl
  mapMsg = {
    t = 'map', level = lvl,
    bounds = { min = { num(minx), num(miny) }, max = { num(maxx), num(maxy) } },
    minimapInfo = minimapInfo(lvl),
    nodes = nodes, links = links, signals = sig, parking = park,
  }
  logI(string.format('map %s: %d nodes, %d links', lvl, #nodes, #links))
  return true
end

local function sendMinimap()
  local lvl = level
  local mm = lvl and minimapInfo(lvl)
  if not mm or not readFile or not mime then event('error', 'no minimap for this level'); return end
  local file = mm.file
  if file:sub(1, 1) ~= '/' then file = '/levels/' .. lvl .. '/' .. file end
  local data = try(readFile, file)
  if not data then event('error', 'could not read ' .. file); return end
  send({ t = 'minimap', level = lvl, file = file, offset = mm.offset, size = mm.size,
         mime = file:lower():find('%.jpe?g$') and 'image/jpeg' or 'image/png', data = mime.b64(data) })
end

---------------------------------------------------------------------------
-- traffic
---------------------------------------------------------------------------

local function sizeOf(veh)
  local id = veh:getID()
  if vehSize[id] then return vehSize[id] end
  local w, l = 1.9, 4.6
  local he = try(function() return veh:getSpawnWorldOOBB():getHalfExtents() end)
  if he and he.x then
    local a, b = math.abs(he.x) * 2, math.abs(he.y) * 2
    l, w = math.max(a, b), math.min(a, b)
  else
    local il = try(function() return veh:getInitialLength() end)
    local iw = try(function() return veh:getInitialWidth() end)
    if il and il > 0 then l = il end
    if iw and iw > 0 then w = iw end
  end
  vehSize[id] = { w = w, l = l }
  return vehSize[id]
end

local function sampleTraffic()
  local now = realTime
  local seen = {}
  for _, veh in ipairs(allVehicles()) do
    local id = veh:getID()
    if id ~= playerId and (not veh.getActive or try(function() return veh:getActive() end) ~= false) then
      local p = veh:getPosition()
      local d = veh:getDirectionVector()
      local prev = traffic[id]
      local v
      local vel = try(function() return veh:getVelocity() end)
      if vel and vel.x then
        v = vel.x * d.x + vel.y * d.y + vel.z * d.z
      elseif prev and now > prev.t then
        v = ((p.x - prev.x) * d.x + (p.y - prev.y) * d.y) / (now - prev.t)
      else
        v = 0
      end
      local sz = sizeOf(veh)
      traffic[id] = { x = p.x, y = p.y, z = p.z, dx = d.x, dy = d.y, dz = d.z, v = v, w = sz.w, l = sz.l, t = now }
      seen[id] = true
    end
  end
  for id in pairs(traffic) do if not seen[id] then traffic[id] = nil end end
end

local function sendTraffic()
  local cars = {}
  local pv = playerVehicle()
  local pp = pv and pv:getPosition()
  for id, c in pairs(traffic) do
    if not pp or (c.x - pp.x) ^ 2 + (c.y - pp.y) ^ 2 < 600 * 600 then
      cars[#cars + 1] = { id = id, pos = { num(c.x), num(c.y), num(c.z) }, dir = { num(c.dx, 3), num(c.dy, 3), num(c.dz, 3) }, speed = num(c.v), w = num(c.w), l = num(c.l) }
    end
  end
  send({ t = 'traffic', cars = cars }, true)
end

---------------------------------------------------------------------------
-- route planning
---------------------------------------------------------------------------

local function profileOpts()
  return P.PROFILES[ap.profile] or P.PROFILES.standard
end

local function nearestParking(x, y, maxDist)
  local best, bd = nil, maxDist * maxDist
  for _, p in ipairs(parking) do
    local d = (p.x - x) ^ 2 + (p.y - y) ^ 2
    if d < bd then best, bd = p, d end
  end
  return best
end

-- Build ap.path from the player's pose: to ap.dest (via ap.stops) or, with no
-- destination, "keep following this road".
local function planPath(veh)
  if not graph then return false, 'map not loaded yet' end
  local p = veh:getPosition()
  local d = veh:getDirectionVector()
  local hx, hy = d.x, d.y
  local hl = math.sqrt(hx * hx + hy * hy)
  if hl < 1e-6 then hx, hy = 0, 1 else hx, hy = hx / hl, hy / hl end
  local path
  if ap.dest then
    local legs = {}
    for _, s in ipairs(ap.stops or {}) do legs[#legs + 1] = s end
    legs[#legs + 1] = ap.dest
    local sx, sy = p.x, p.y
    local all = nil
    for _, goal in ipairs(legs) do
      local rt, err = P.route(graph, { x = sx, y = sy, hx = hx, hy = hy }, { x = goal[1], y = goal[2] })
      if not rt then return false, err end
      local leg = P.buildPath(graph, rt)
      if not all then all = leg
      else
        local off = all.s[#all.s]
        for i = 2, #leg.pts do all.pts[#all.pts + 1] = leg.pts[i] end
        for _, t in ipairs(leg.turns) do t.s = t.s + off; all.turns[#all.turns + 1] = t end
        all.s = P.cumulative(all.pts)
      end
      local last = all.pts[#all.pts]
      local prev = all.pts[math.max(1, #all.pts - 1)]
      sx, sy = last.x, last.y
      hx, hy = last.x - prev.x, last.y - prev.y
      hl = math.sqrt(hx * hx + hy * hy)
      if hl > 1e-6 then hx, hy = hx / hl, hy / hl end
    end
    path = all
    -- arrival
    local kind = ap.arrival or 'auto'
    local spot = (kind == 'Parking Lot' or kind == 'Parking Garage' or kind == 'auto') and nearestParking(ap.dest[1], ap.dest[2], 60) or nil
    if spot then
      P.appendParking(path, spot.x, spot.y, spot.z, spot.dx, spot.dy)
      path.arrivalKind = 'parking'
    elseif kind ~= 'Driveway' then
      P.pullOver(path, 30)
      path.arrivalKind = 'curb'
    else
      path.arrivalKind = 'point'
    end
  else
    local rt, err = P.followRoad(graph, p.x, p.y, hx, hy, 1500)
    if not rt then return false, err end
    path = P.buildPath(graph, rt)
  end
  local prof = profileOpts()
  P.speedProfile(path, { offset = prof.offset, aLat = prof.aLat, endSpeed = (not path.openEnded) and 0 or nil })
  -- speed limit (no profile offset) for display
  path.limit = {}
  for i, pt in ipairs(path.pts) do path.limit[i] = pt.lim or P.classDefaultSpeed(pt.r, pt.drv) end
  ap.path, ap.hint = path, nil
  ap.cleared, ap.clearedS, ap.stopHold, ap.arrived = {}, -1e9, 0, false
  -- route preview for the app
  local pts = {}
  local step = math.max(1, math.floor(#path.pts / 400))
  for i = 1, #path.pts, step do local q = path.pts[i]; pts[#pts + 1] = { num(q.x, 1), num(q.y, 1), num(q.z or 0, 1) } end
  local q = path.pts[#path.pts]
  pts[#pts + 1] = { num(q.x, 1), num(q.y, 1), num(q.z or 0, 1) }
  send({ t = 'route', points = pts, length = num(path.s[#path.s], 0), openEnded = path.openEnded or false, arrival = path.arrivalKind })
  return true
end

local function disengage(reason, detail)
  local wasOn = ap.mode ~= 'off'
  ap.mode = 'off'
  local veh = playerVehicle()
  toVehicle(veh, 'command', { t = 'autopilot', mode = 'off', reason = reason })
  if wasOn then
    ap.lastDisengage = { reason = reason, time = num(gameTime) }
    event('disengage', reason .. (detail and (': ' .. detail) or ''))
  end
end

local function engage(mode, profile)
  local veh = playerVehicle()
  if not veh then event('error', 'no player vehicle'); return end
  if profile and P.PROFILES[profile] then ap.profile = profile end
  if not ap.path or ap.path.openEnded ~= (ap.dest == nil) or ap.modeBuiltFor ~= ap.profile then
    local ok, err = planPath(veh)
    if not ok then event('error', 'autopilot: ' .. tostring(err)); return end
    ap.modeBuiltFor = ap.profile
  end
  ap.mode = mode
  local prof = profileOpts()
  toVehicle(veh, 'command', { t = 'autopilot', mode = mode, profile = ap.profile, throttleMax = prof.throttle, gapTime = prof.gap })
  event('engaged', mode .. '/' .. ap.profile)
end

-- Distance along path (from `fromS`) to controls ahead, lead vehicle, turns.
local function controlsAhead(path, sCar, i0, i1, speed)
  local pts = path.pts
  local window = { pts = {}, s = {} }
  for i = i0, i1 do window.pts[#window.pts + 1] = pts[i]; window.s[#window.s + 1] = path.s[i] end
  local car = pts[i0]
  local best = nil
  for _, sg in ipairs(signals) do
    local dx, dy = sg.x - car.x, sg.y - car.y
    if dx * dx + dy * dy < 300 * 300 then
      local pr = P.project(window, sg.x, sg.y)
      if pr and pr.s > sCar - 3 then
        local r = (pr.i and window.pts[pr.i] and window.pts[pr.i].r) or 4
        local okLat = pr.dist < r + 5
        if sg.kind == 'stop' and sg.prop then okLat = pr.lat < 1 and pr.dist < r + 6 end -- sign on our right
        if okLat and sg.dirx then
          local a = window.pts[pr.i]; local b = window.pts[math.min(#window.pts, pr.i + 1)]
          local tx, ty = b.x - a.x, b.y - a.y
          local tl = math.sqrt(tx * tx + ty * ty)
          if tl > 1e-6 then okLat = math.abs((tx * sg.dirx + ty * sg.diry) / tl) > 0.6 end
        end
        if okLat then
          local dist = pr.s - sCar
          local red = false
          local needStop = false
          if sg.kind == 'stop' then
            needStop = not ap.cleared[sg.id] and pr.s > ap.clearedS + 25
            red = needStop
          else
            local st = sg.get and sg.get() or nil
            red = st == 'red'
            needStop = red or (st == 'yellow' and dist > (speed * speed) / (2 * 3) + 2)
          end
          if not best or dist < best.dist then
            best = { kind = sg.kind, dist = dist, red = red, stop = needStop, id = sg.id, s = pr.s }
          end
        end
      end
    end
  end
  return best
end

local function leadAhead(path, sCar, i0, i1, ourLen)
  local pts = path.pts
  local window = { pts = {}, s = {} }
  for i = i0, i1 do window.pts[#window.pts + 1] = pts[i]; window.s[#window.s + 1] = path.s[i] end
  local car = pts[i0]
  local best = nil
  for id, c in pairs(traffic) do
    local dx, dy = c.x - car.x, c.y - car.y
    if dx * dx + dy * dy < 200 * 200 then
      local pr = P.project(window, c.x, c.y)
      if pr and pr.s > sCar and math.abs(pr.lat) < 1.8 + c.w * 0.25 then
        local a = window.pts[pr.i]; local b = window.pts[math.min(#window.pts, pr.i + 1)]
        local tx, ty = b.x - a.x, b.y - a.y
        local tl = math.sqrt(tx * tx + ty * ty)
        local dot = tl > 1e-6 and (tx * c.dx + ty * c.dy) / tl or 1
        local v = (dot > 0.3) and c.v * dot or 0 -- crossing or oncoming in our lane: treat as stopped
        local rear = pr.s - c.l * 0.5 - ourLen * 0.5
        if not best or rear < best.s then best = { s = rear, v = math.max(0, v), id = id } end
      end
    end
  end
  return best
end

local function planTick()
  local veh = playerVehicle()
  if not veh or ap.mode == 'off' or not ap.path then
    ap.control, ap.nextTurn, ap.leadGap = nil, nil, nil
    if ap.path and ap.dest and veh then
      -- still report remaining distance while navigating without autopilot
      local p = veh:getPosition()
      local pr = P.project(ap.path, p.x, p.y, ap.hint, 10, 120) or P.project(ap.path, p.x, p.y)
      if pr then ap.hint = pr.i; ap.remaining = ap.path.s[#ap.path.s] - pr.s end
    end
    return
  end
  local path = ap.path
  local p = veh:getPosition()
  local pr = P.project(path, p.x, p.y, ap.hint, 10, 120)
  if not pr or pr.dist > 8 then pr = P.project(path, p.x, p.y) end
  if not pr then return end
  if pr.dist > 15 then
    -- we're off the path (e.g. after a takeover / re-engage somewhere else): replan
    local ok = planPath(veh)
    if not ok then disengage('error', 'lost the road') end
    return
  end
  ap.hint = pr.i
  local S = path.s
  local remaining = S[#S] - pr.s
  ap.remaining = (not path.openEnded) and remaining or nil
  ap.speedLimit = path.limit[pr.i]

  if path.openEnded and remaining < 400 then
    planPath(veh)
    return
  end

  local speed = ap.lastVehSpeed or 0
  local i0 = math.max(1, pr.i - 5)
  local i1 = math.min(#path.pts, pr.i + 160)
  local sBase = S[i0]
  local sCar = pr.s

  -- controls
  local ctl = controlsAhead(path, sCar, i0, i1, speed)
  if ctl and ctl.kind == 'stop' and ctl.stop then
    if speed < 0.3 and ctl.dist < 6 then
      ap.stopHold = ap.stopHold + 0.1
      if ap.stopHold >= 2 then
        ap.cleared[ctl.id] = true
        ap.clearedS = ctl.s
        ap.stopHold = 0
      end
    else
      ap.stopHold = 0
    end
  end
  ap.control = ctl and { kind = ctl.kind, dist = num(ctl.dist, 1), red = ctl.red } or nil

  -- lead
  local ourLen = sizeOf(veh).l
  local lead = leadAhead(path, sCar, i0, i1, ourLen)
  ap.leadGap = lead and num(lead.s - sCar, 1) or nil

  -- turns
  local nextTurn, signal = nil, nil
  for _, t in ipairs(path.turns or {}) do
    if t.s > sCar - 5 then
      nextTurn = t
      break
    end
  end
  if nextTurn and nextTurn.s - sCar < 60 then signal = nextTurn.dir end
  if path.arrivalKind == 'curb' and remaining < 45 then signal = 'right' end
  ap.nextTurn = nextTurn and { dir = nextTurn.dir, dist = num(math.max(0, nextTurn.s - sCar), 0), road = nextTurn.road or '' } or nil

  -- arrival
  local hold = false
  if not path.openEnded and remaining < 2.5 and speed < 0.3 then
    hold = true
    if not ap.arrived then
      ap.arrived = true
      toVehicle(veh, 'command', { t = 'gear', gear = 'P' })
      event('arrived', path.arrivalKind)
      disengage('arrived')
      ap.dest, ap.path = nil, nil
      return
    end
  end

  -- window for the vehicle
  local flat, vcap = {}, {}
  for i = i0, i1 do
    local q = path.pts[i]
    flat[#flat + 1] = num(q.x); flat[#flat + 1] = num(q.y); flat[#flat + 1] = num(q.z or 0)
    vcap[#vcap + 1] = num(path.vcap[i])
  end
  ap.seq = ap.seq + 1
  local prof = profileOpts()
  local plan = {
    seq = ap.seq, pts = flat, vcap = vcap,
    stopS = (ctl and ctl.stop) and (ctl.s - sBase) or nil,
    lead = lead and { s = lead.s - sBase, v = num(lead.v) } or nil,
    signal = signal or false,
    hold = hold, openEnded = path.openEnded or false,
    gapTime = prof.gap, throttleMax = prof.throttle,
  }
  toVehicle(veh, 'setPlan', plan)
end

---------------------------------------------------------------------------
-- vehicle management
---------------------------------------------------------------------------

local function ensureVehicleExtension(veh, force)
  if not veh then return end
  local id = veh:getID()
  if force or not lastVehState[id] or realTime - lastVehState[id] > 2 then
    if force or not lastLoadTry[id] or realTime - lastLoadTry[id] > 3 then
      lastLoadTry[id] = realTime
      vehQueue(veh, 'extensions.load("teslaAutopilot")')
    end
  end
end

local function vehicleInfo(veh)
  local jb = try(function() return veh:getJBeamFilename() end) or '?'
  local name = jb
  local md = core_vehicles and core_vehicles.getModel and try(core_vehicles.getModel, jb)
  if md and md.model then
    local b, n = md.model.Brand, md.model.Name
    if n then name = (b and (b .. ' ') or '') .. n end
  end
  return { id = veh:getID(), name = name, model = jb }
end

-- Called from the vehicle extension (vehicle VM) at 20 Hz.
function M.onVehicleState(vid, json)
  lastVehState[vid] = realTime
  local veh = vehicleById(vid)
  local pv = playerVehicle()
  if not pv or pv:getID() ~= vid then return end
  local ok, st = pcall(jsonDecode, json)
  if not ok or type(st) ~= 'table' then return end
  ap.lastVehSpeed = st.speed or 0
  st.t = 'state'
  st.time = num(gameTime)
  st.vehicle = vehicleInfo(veh or pv)
  local p = pv:getPosition()
  local d = pv:getDirectionVector()
  st.pos = v3(p)
  st.dir = { num(d.x, 4), num(d.y, 4), num(d.z, 4) }
  local va = st.autopilot or {}
  -- the vehicle knows engaged/targetSpeed; the planner knows the road
  if va.engaged == false and ap.mode ~= 'off' and (ap.engagedAt or 0) + 1.5 < realTime then
    ap.mode = 'off' -- the vehicle lost its state (reset/reload)
  end
  st.autopilot = {
    engaged = va.engaged or false,
    mode = va.engaged and ap.mode or 'off',
    profile = ap.profile,
    targetSpeed = num(va.targetSpeed or 0),
    speedLimit = ap.speedLimit and num(ap.speedLimit) or nil,
    leadGap = ap.leadGap,
    control = ap.control,
    nextTurn = ap.nextTurn,
    remaining = ap.remaining and num(ap.remaining, 0) or nil,
    lastDisengage = ap.lastDisengage,
    accelOverride = va.accelOverride or false,
    steerGain = va.steerGain, steerSign = va.steerSign,
  }
  send(st, true)
end

-- Events from the vehicle (disengage on takeover, errors, diagnostics).
function M.onVehicleEvent(vid, json)
  local ok, ev = pcall(jsonDecode, json)
  if not ok or type(ev) ~= 'table' then return end
  if ev.kind == 'disengage' then
    if ap.mode ~= 'off' then
      ap.mode = 'off'
      ap.lastDisengage = { reason = ev.reason or 'error', time = num(gameTime) }
      event('disengage', (ev.reason or 'error') .. (ev.detail and (': ' .. ev.detail) or ''))
    end
  elseif ev.kind == 'diag' then
    vehDiag = ev.data
    send({ t = 'debug', ge = M.diagnostics(), vehicle = vehDiag })
  else
    send({ t = 'event', kind = ev.kind or 'error', detail = ev.detail })
  end
end

---------------------------------------------------------------------------
-- commands
---------------------------------------------------------------------------

handleCommand = function(msg)
  local t = msg.t
  local veh = playerVehicle()
  if t == 'gear' or t == 'lights' or t == 'signal' or t == 'horn' or t == 'door' or t == 'throttleOverride' or t == 'wheel' then
    if not veh then event('error', 'no player vehicle'); return end
    ensureVehicleExtension(veh)
    toVehicle(veh, 'command', msg)
  elseif t == 'autopilot' then
    if msg.mode == 'off' then
      disengage('app')
    elseif msg.mode == 'fsd' or msg.mode == 'autosteer' then
      ap.engagedAt = realTime
      engage(msg.mode, msg.profile)
    elseif msg.profile then
      ap.profile = msg.profile
    end
  elseif t == 'navigate' then
    local to = msg.to
    if type(to) == 'table' and to.node and graph and graph.nodes[to.node] then
      local n = graph.nodes[to.node]
      to = { n.x, n.y, n.z }
    end
    if type(to) ~= 'table' or not to[1] then event('error', 'navigate: bad destination'); return end
    ap.dest, ap.stops, ap.arrival = to, msg.stops, msg.arrival
    if veh then
      local ok, err = planPath(veh)
      if not ok then event('error', 'navigate: ' .. tostring(err)) end
      if ap.mode ~= 'off' and ok then engage(ap.mode, ap.profile) end
    end
  elseif t == 'cancelRoute' then
    ap.dest, ap.stops, ap.arrival, ap.remaining = nil, nil, nil, nil
    send({ t = 'route', points = {}, length = 0 })
    if ap.mode ~= 'off' and veh then
      planPath(veh)
      engage(ap.mode, ap.profile)
    else
      ap.path = nil
    end
  elseif t == 'requestMap' then
    if mapMsg then send(mapMsg) else mapPending = true; event('error', 'map not ready yet') end
  elseif t == 'requestMinimap' then
    sendMinimap()
  elseif t == 'debug' then
    if veh then
      ensureVehicleExtension(veh)
      vehQueue(veh, 'if teslaAutopilot then teslaAutopilot.diag() end')
    end
    send({ t = 'debug', ge = M.diagnostics(), vehicle = vehDiag })
  elseif t == 'ping' then
    send({ t = 'pong', time = num(gameTime) })
  else
    event('error', 'unknown command ' .. tostring(t))
  end
end

-- Bound to the "Tesla: toggle FSD / Autosteer" controls (a wheel button, e.g. on a G29).
function M.toggleAutopilot(mode)
  if ap.mode ~= 'off' then
    disengage('app')
    ap.lastDisengage = { reason = 'app', time = num(gameTime) }
  else
    ap.engagedAt = realTime
    engage(mode or 'fsd', ap.profile)
  end
end

---------------------------------------------------------------------------
-- diagnostics (the `debug` command): what this BeamNG version exposes
---------------------------------------------------------------------------

local function keysOf(t, limit)
  local out = {}
  if type(t) ~= 'table' then return out end
  for k, v in pairs(t) do
    out[#out + 1] = tostring(k) .. ':' .. type(v)
    if #out >= (limit or 40) then break end
  end
  table.sort(out)
  return out
end

function M.diagnostics()
  local d = { version = beamng_versionb or beamng_version, level = levelName(), mapNodes = graph and #mapMsg.nodes or 0,
    mapLinks = graph and #graph.edges or 0, signals = #signals, parking = #parking, traffic = 0,
    apMode = ap.mode, profile = ap.profile, hasPath = ap.path ~= nil, relayQueue = outBytes }
  for _ in pairs(traffic) do d.traffic = d.traffic + 1 end
  local md = map and map.getMap and try(map.getMap)
  if md and md.nodes then
    local _, n = next(md.nodes)
    d.sampleNode = keysOf(n)
    if n and n.links then
      local _, l = next(n.links)
      d.sampleLink = keysOf(l)
      if type(l) == 'table' then
        local vals = {}
        for k, v in pairs(l) do if type(v) ~= 'table' then vals[tostring(k)] = tostring(v) end end
        d.sampleLinkValues = vals
      end
    end
  end
  local ts = rawget(_G, 'core_trafficSignals')
  d.trafficSignalsApi = ts and keysOf(ts, 60) or 'missing'
  local gp = rawget(_G, 'gameplay_parking')
  d.parkingApi = gp and keysOf(gp, 60) or 'missing'
  d.globals = {
    getPlayerVehicle = getPlayerVehicle ~= nil, getAllVehicles = getAllVehicles ~= nil, getObjectByID = getObjectByID ~= nil,
    jsonReadFile = jsonReadFile ~= nil, readFile = readFile ~= nil, mime = mime ~= nil,
  }
  if signals[1] then d.sampleSignal = { id = signals[1].id, kind = signals[1].kind, state = signals[1].get and signals[1].get() or nil } end
  return d
end

---------------------------------------------------------------------------
-- hooks
---------------------------------------------------------------------------

local function onUpdate(dtReal, dtSim)
  dtReal = dtReal or 0
  realTime = realTime + dtReal
  gameTime = gameTime + (dtSim or dtReal)
  netUpdate()

  local veh = playerVehicle()
  local vid = veh and veh:getID() or nil
  if vid ~= playerId then
    local old = playerId
    playerId = vid
    if old then
      local ov = vehicleById(old)
      if ov and ap.mode ~= 'off' then toVehicle(ov, 'command', { t = 'autopilot', mode = 'off', reason = 'switch' }) end
      ap.mode = 'off'
      ap.path = nil
    end
    if veh then
      ensureVehicleExtension(veh, true)
      event('vehicleChanged', vehicleInfo(veh).name)
      if mapMsg then send(mapMsg) end
    end
  end

  if realTime >= tHeartbeat then
    tHeartbeat = realTime + 1
    if veh then ensureVehicleExtension(veh) end
  end

  if (mapPending or not mapMsg) and realTime >= tMapPoll then
    tMapPoll = realTime + 1
    if levelName() and buildMap() then
      mapPending = false
      send(mapMsg)
      event('levelLoaded', level)
    end
  end

  if realTime >= tTraffic then
    tTraffic = realTime + 0.2
    sampleTraffic()
    sendTraffic()
  end

  if realTime >= tPlan then
    tPlan = realTime + 0.1
    local ok, err = pcall(planTick)
    if not ok then logW('plan tick: ' .. tostring(err)); disengage('error', tostring(err)) end
  end
end

local function onClientStartMission()
  mapMsg, graph, level = nil, nil, nil
  ap.path, ap.dest, ap.mode = nil, nil, 'off'
  mapPending = true
  tMapPoll = realTime + 2 -- the road graph is built a moment after the level starts
  traffic, vehSize = {}, {}
end

local function onClientEndMission()
  mapMsg, graph, level = nil, nil, nil
  ap.path, ap.dest, ap.mode = nil, nil, 'off'
  traffic, vehSize = {}, {}
end

local function onVehicleSpawned(vid)
  local veh = vehicleById(vid)
  local pv = playerVehicle()
  if veh and pv and pv:getID() == vid then ensureVehicleExtension(veh, true) end
  vehSize[vid] = nil
end

local function onVehicleResetted(vid)
  local pv = playerVehicle()
  if pv and pv:getID() == vid and ap.mode ~= 'off' then disengage('error', 'vehicle reset') end
end

local function onVehicleDestroyed(vid)
  traffic[vid] = nil
  vehSize[vid] = nil
  lastVehState[vid] = nil
end

local function onExtensionLoaded()
  logI('loaded')
  if levelName() then mapPending = true end
end

local function onExtensionUnloaded()
  closeClient('unloaded')
  if server then pcall(function() server:close() end); server = nil end
end

M.onUpdate = onUpdate
M.onClientStartMission = onClientStartMission
M.onClientEndMission = onClientEndMission
M.onVehicleSpawned = onVehicleSpawned
M.onVehicleResetted = onVehicleResetted
M.onVehicleDestroyed = onVehicleDestroyed
M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = onExtensionUnloaded

-- for the test harness
M._ap = ap
M._handleCommand = function(msg) return handleCommand(msg) end

return M
