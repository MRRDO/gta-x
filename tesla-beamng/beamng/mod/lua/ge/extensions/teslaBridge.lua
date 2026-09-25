-- teslaBridge (game-engine extension)
-- TCP server for the Node relay (newline-delimited JSON on 127.0.0.1:8766),
-- player-vehicle state fan-out, commands, road-graph export, traffic (with
-- emergency vehicles / school buses), traffic signals, parking spots, weather.
-- Runs the FSD brain (teslaBridge/planner) at 10 Hz and active safety
-- (teslaBridge/safety) at 20 Hz. The per-frame driving (steering/throttle/brake
-- through player inputs) lives in the vehicle extension teslaAutopilot; this
-- file sends it a plan at 10 Hz and safety assists at 20 Hz.
--
-- BeamNG API names used here were checked against BeamNG 0.39-era mod code.
-- Anything less certain is called through `try()` and reported by the
-- `debug` command, so a wrong guess degrades a feature instead of the mod.

local M = {}

local P = require('teslaBridge/pathing')
local Pl = require('teslaBridge/planner')
local Sf = require('teslaBridge/safety')

local logTag = 'teslaBridge'
local PORT = 8766
local PROTOCOL = 2
local MAX_QUEUE = 512 * 1024 -- bytes of droppable output before we skip frames

local socket = nil
local server, client = nil, nil
local inbuf = ''
local outq, outPos, outBytes = {}, 1, 0
local nextBindTry = 0

local gameTime, realTime = 0, 0
local tPlan, tTraffic, tHeartbeat, tMapPoll, tSafety, tWeather = 0, 0, 0, 0, 0, 0

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

-- FSD brain, safety, and what we last told the car
local planner = nil
local plannerSettings = {}   -- kept across level loads
local safetySettings = {}
local safety = Sf.new()
local sentMode = 'off'
local plannerStatus = {}
local safetyStatus = {}
local lastAssist = nil
local attention = nil        -- { state, t } from the app's cabin camera
local lastVehSt = {}         -- gear, speed, throttle, signal, nudges from the car
local nudgeCount, nudgeT = 0, nil
local engagedAt = -1e9
local weather = { rain = 0, fog = 0 }
local overhead = false
local beacons, beaconLoaded, vehNames = {}, {}, {}

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
  planner = Pl.new({ graph = graph, signals = signals, parking = parking })
  planner:configure(plannerSettings)
  sentMode = 'off'
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

local EMERGENCY_WORDS = { 'police', 'sheriff', 'ambulance', 'fire', 'rescue', 'interceptor', 'pursuit', 'ems', 'marshal', 'patrol', 'trooper' }

local function vehName(veh, id)
  if vehNames[id] then return vehNames[id] end
  local jb = try(function() return veh:getJBeamFilename() end) or ''
  local cfg = try(function() return veh.partConfig end) or ''
  local n = string.lower(tostring(jb) .. ' ' .. tostring(cfg))
  vehNames[id] = n
  return n
end

local function isEmergencyName(n)
  for _, w in ipairs(EMERGENCY_WORDS) do if n:find(w, 1, true) then return true end end
  return false
end

-- lightbar reports from the tiny teslaBeacon extension we load into nearby cars
function M.onBeacon(vid, lightbar, hazard)
  beacons[vid] = { lightbar = tonumber(lightbar) or 0, hazard = tonumber(hazard) or 0, t = realTime }
end

local function sampleTraffic()
  local now = realTime
  local seen = {}
  local pv = playerVehicle()
  local pp = pv and pv:getPosition()
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
      local stopped = 0
      if prev and math.abs(v) < 0.3 then stopped = (prev.stoppedFor or 0) + (now - prev.t) end
      local near = pp and (p.x - pp.x) ^ 2 + (p.y - pp.y) ^ 2 < 250 * 250
      if near and not beaconLoaded[id] then
        beaconLoaded[id] = true
        vehQueue(veh, 'extensions.load("teslaBeacon")')
      end
      local name = vehName(veh, id)
      local b = beacons[id]
      local lights = b and now - b.t < 2 and b.lightbar > 0
      traffic[id] = { x = p.x, y = p.y, z = p.z, dx = d.x, dy = d.y, dz = d.z, v = v, w = sz.w, l = sz.l, t = now,
        stoppedFor = stopped, emergency = lights and isEmergencyName(name) or false,
        schoolBus = name:find('school', 1, true) ~= nil, name = name }
      seen[id] = true
    end
  end
  for id in pairs(traffic) do if not seen[id] then traffic[id] = nil end end
end

local function trafficList()
  local list = {}
  for id, c in pairs(traffic) do
    list[#list + 1] = { id = id, x = c.x, y = c.y, z = c.z, dx = c.dx, dy = c.dy, v = c.v, l = c.l, w = c.w,
      stoppedFor = c.stoppedFor, emergency = c.emergency, schoolBus = c.schoolBus }
  end
  return list
end

local function sendTraffic()
  local cars = {}
  local pv = playerVehicle()
  local pp = pv and pv:getPosition()
  for id, c in pairs(traffic) do
    if not pp or (c.x - pp.x) ^ 2 + (c.y - pp.y) ^ 2 < 600 * 600 then
      cars[#cars + 1] = { id = id, pos = { num(c.x), num(c.y), num(c.z) }, dir = { num(c.dx, 3), num(c.dy, 3), num(c.dz, 3) }, speed = num(c.v), w = num(c.w), l = num(c.l),
        emergency = c.emergency or nil, schoolBus = c.schoolBus or nil }
    end
  end
  send({ t = 'traffic', cars = cars }, true)
end

---------------------------------------------------------------------------
-- sensing: weather, static raycasts
---------------------------------------------------------------------------

local weatherProbe = {}

local function sampleWeather()
  local rain, fog = 0, 0
  -- rain: Precipitation objects in the level (drops count)
  if scenetree and scenetree.findClassObjects then
    local list = try(scenetree.findClassObjects, 'Precipitation') or {}
    for _, name in ipairs(list) do
      local o = scenetree.findObject(name)
      local drops = o and (try(function() return tonumber(o.numDrops) end) or try(function() return tonumber(o:getField('numDrops', '')) end))
      if drops then rain = math.max(rain, math.min(1, drops / 4000)); weatherProbe.rain = 'numDrops' end
    end
  end
  -- fog: environment fog density
  local env = rawget(_G, 'core_environment')
  if env then
    local dens = type(env.getFogDensity) == 'function' and try(env.getFogDensity)
    if type(dens) == 'number' then
      fog = math.max(0, math.min(1, (dens - 0.002) / 0.02))
      weatherProbe.fog = 'core_environment.getFogDensity'
    end
    if type(env.getPrecipitation) == 'function' then
      local pr = try(env.getPrecipitation)
      if type(pr) == 'number' then rain = math.max(rain, math.min(1, pr)); weatherProbe.rain = 'core_environment.getPrecipitation' end
    end
  end
  weather = { rain = rain, fog = fog }
end

local rayFn = nil
local rayProbed = false
local function castRay(px, py, pz, dx, dy, dz, dist)
  if not rayProbed then
    rayProbed = true
    if rawget(_G, 'castRayStatic') then
      rayFn = function(o, d, l) return castRayStatic(o, d, l) end
    elseif be and be.castRayStatic then
      rayFn = function(o, d, l) return be:castRayStatic(o, d, l) end
    end
  end
  if not rayFn or not vec3 then return nil end
  local hit = try(rayFn, vec3(px, py, pz), vec3(dx, dy, dz), dist)
  if type(hit) == 'number' and hit > 0 and hit < dist then return hit end
  return nil
end

-- distances to static things around the car (walls, poles) and a bridge overhead
local function sampleRays(ego)
  local z = (ego.z or 0) + 0.6
  local half = (ego.len or 4.6) * 0.5
  local rays = {
    front = castRay(ego.x + ego.hx * half, ego.y + ego.hy * half, z, ego.hx, ego.hy, 0, 30),
    rear = castRay(ego.x - ego.hx * half, ego.y - ego.hy * half, z, -ego.hx, -ego.hy, 0, 15),
    left = castRay(ego.x, ego.y, z, -ego.hy, ego.hx, 0, 8),
    right = castRay(ego.x, ego.y, z, ego.hy, -ego.hx, 0, 8),
  }
  overhead = castRay(ego.x, ego.y, (ego.z or 0) + 2.5, 0, 0, 1, 12) ~= nil
  return rays
end

---------------------------------------------------------------------------
-- the player car, as the planner and safety see it
---------------------------------------------------------------------------

local yawState = { prev = nil, t = 0, rate = 0 }

local function egoSnapshot(veh)
  local p = veh:getPosition()
  local d = veh:getDirectionVector()
  local hl = math.sqrt(d.x * d.x + d.y * d.y)
  local hx, hy = 0, 1
  if hl > 1e-6 then hx, hy = d.x / hl, d.y / hl end
  local v
  local vel = try(function() return veh:getVelocity() end)
  if vel and vel.x then v = vel.x * hx + vel.y * hy
  else v = (lastVehSt.speed or 0) * ((lastVehSt.gear == 'R') and -1 or 1) end
  if yawState.prev and realTime > yawState.t then
    local ph = yawState.prev
    local cr = ph[1] * hy - ph[2] * hx
    local dp = ph[1] * hx + ph[2] * hy
    local rate = math.atan2(cr, dp) / (realTime - yawState.t)
    yawState.rate = yawState.rate + (rate - yawState.rate) * 0.5
  end
  yawState.prev, yawState.t = { hx, hy }, realTime
  local sz = sizeOf(veh)
  return {
    x = p.x, y = p.y, z = p.z, hx = hx, hy = hy, v = v, yawRate = yawState.rate, len = sz.l, wid = sz.w,
    gear = lastVehSt.gear, throttle = lastVehSt.throttle, signal = lastVehSt.signal,
    engaged = planner ~= nil and planner.mode ~= 'off', handsNudgeT = nudgeT, attention = attention,
  }
end

---------------------------------------------------------------------------
-- planner <-> car
---------------------------------------------------------------------------

local function relayEvent(ev)
  local detail = ev.detail or ev.reason or ev.dir or ev.side or ev.what or ev.action or ev.state
  if ev.kind == 'nag' then detail = tostring(ev.level) .. (ev.reason and (' ' .. ev.reason) or '') end
  if ev.kind == 'strike' then detail = tostring(ev.strikes) .. '/' .. tostring(ev.max) end
  if ev.kind == 'disengage' then detail = ev.reason end -- the UI keys on the reason; the rest is in data
  local msg = { t = 'event', kind = ev.kind, detail = detail and tostring(detail) or nil, data = ev }
  send(msg)
end

-- keep the car's autopilot mode in step with the planner's
local function syncVehicleMode(veh)
  if not planner or not veh then return end
  if planner.mode == sentMode then return end
  if planner.mode == 'off' then
    local r = planner.lastDisengage and planner.lastDisengage.reason or 'app'
    toVehicle(veh, 'command', { t = 'autopilot', mode = 'off', reason = r })
  else
    local prof = P.PROFILES[planner.profile] or P.PROFILES.standard
    toVehicle(veh, 'command', { t = 'autopilot', mode = planner.mode, profile = planner.profile, throttleMax = prof.throttle, gapTime = prof.gap })
    engagedAt = realTime
  end
  sentMode = planner.mode
end

local function applyPlannerOut(veh, out)
  for _, ev in ipairs(out.events or {}) do relayEvent(ev) end
  for _, cmd in ipairs(out.commands or {}) do cmd.fromPlanner = true; toVehicle(veh, 'command', cmd) end
  if out.route then send(out.route) end
  plannerStatus = out.status or plannerStatus
  syncVehicleMode(veh)
  if out.plan and planner.mode ~= 'off' then
    -- round for a smaller message
    for i = 1, #out.plan.pts do out.plan.pts[i] = num(out.plan.pts[i]) end
    for i = 1, #out.plan.vcap do out.plan.vcap[i] = num(out.plan.vcap[i]) end
    toVehicle(veh, 'setPlan', out.plan)
  end
end

local function planTick()
  if not planner then return end
  local veh = playerVehicle()
  if not veh then return end
  local ego = egoSnapshot(veh)
  local out = planner:tick({ t = gameTime, dt = 0.1, ego = ego, cars = trafficList(), weather = weather, overhead = overhead })
  applyPlannerOut(veh, out)
end

local function safetyTick()
  if not planner or not graph then return end
  local veh = playerVehicle()
  if not veh then return end
  local ego = egoSnapshot(veh)
  local cars = trafficList()
  local lane = P.locate(graph, ego.x, ego.y, ego.hx, ego.hy, 20)
  local rays = sampleRays(ego)
  local so = safety:tick(gameTime, 0.05, { ego = ego, cars = cars }, { lane = lane, rays = rays, attention = attention })
  for _, ev in ipairs(so.events) do relayEvent(ev) end
  safetyStatus = { fcw = so.fcw or false, aeb = (so.aeb or 0) > 0, blindLeft = so.blindLeft or false, blindRight = so.blindRight or false,
    laneDeparture = so.lda ~= nil, ttc = so.ttc and num(so.ttc) or nil }
  local assist = { aeb = so.aeb or 0, ldaSteer = so.lda and num(so.lda.steer, 3) or 0, throttleCap = so.throttleCap }
  local active = assist.aeb > 0 or assist.ldaSteer ~= 0 or assist.throttleCap ~= nil
  if active or (lastAssist and (lastAssist.aeb > 0 or lastAssist.ldaSteer ~= 0 or lastAssist.throttleCap ~= nil)) then
    toVehicle(veh, 'assist', assist)
  end
  lastAssist = assist
  if so.evade then
    if planner:evade(so.evade.side, so.evade.shift, ego, cars) then
      planTick() -- plan the swerve right away
    end
  end
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
      sentMode = 'off' -- a fresh extension starts disengaged
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
  lastVehSt = { speed = st.speed or 0, gear = st.gear, throttle = st.rawThrottle or st.throttle, signal = st.signal ~= false and st.signal or nil }
  if (st.handsNudges or 0) > nudgeCount then nudgeCount = st.handsNudges; nudgeT = gameTime end
  st.handsNudges, st.rawThrottle = nil, nil
  st.t = 'state'
  st.time = num(gameTime)
  st.vehicle = vehicleInfo(veh or pv)
  local p = pv:getPosition()
  local d = pv:getDirectionVector()
  st.pos = v3(p)
  st.dir = { num(d.x, 4), num(d.y, 4), num(d.z, 4) }
  local va = st.autopilot or {}
  -- the car lost its autopilot state (reset / reload) while the planner thinks it's driving
  if planner and va.engaged == false and planner.mode ~= 'off' and sentMode ~= 'off' and engagedAt + 1.5 < realTime then
    planner:disengage('error', 'car lost autopilot state')
    sentMode = 'off'
  end
  local ps = plannerStatus or {}
  local nag = ps.nag or {}
  st.autopilot = {
    engaged = va.engaged or false,
    mode = (va.engaged and planner) and planner.mode or 'off',
    profile = planner and planner.profile or 'standard',
    activity = ps.activity,
    targetSpeed = num(va.targetSpeed or 0),
    speedLimit = ps.speedLimit and num(ps.speedLimit) or nil,
    setSpeed = ps.setSpeed and num(ps.setSpeed) or nil,
    leadGap = ps.leadGap and num(ps.leadGap, 1) or nil,
    control = ps.control and { kind = ps.control.kind, dist = num(ps.control.dist, 1), red = ps.control.red, state = ps.control.state } or nil,
    nextTurn = ps.nextTurn and { dir = ps.nextTurn.dir, dist = num(ps.nextTurn.dist, 0), road = ps.nextTurn.road } or nil,
    remaining = ps.remaining and num(ps.remaining, 0) or nil,
    lane = ps.lane,
    creeping = ps.creeping or false,
    waitingFor = ps.waitingFor,
    goAround = ps.goAround or false,
    emergencyVehicle = ps.emergency and ps.emergency.action or nil,
    schoolBus = ps.schoolBus or false,
    phantomBrake = ps.phantomBrake or false,
    weather = ps.weather,
    maneuver = ps.maneuver,
    nag = { level = nag.level or 0, reason = nag.reason, strikes = nag.strikes or 0, maxStrikes = nag.maxStrikes or 5, lockedOut = nag.lockedOut or false },
    lastDisengage = planner and planner.lastDisengage or nil,
    accelOverride = va.accelOverride or false,
    steerGain = va.steerGain, steerSign = va.steerSign,
  }
  st.safety = safetyStatus
  send(st, true)
end

-- Events from the vehicle (takeover disengage, accidental-disengage re-engage, errors, diagnostics).
function M.onVehicleEvent(vid, json)
  local ok, ev = pcall(jsonDecode, json)
  if not ok or type(ev) ~= 'table' then return end
  local veh = playerVehicle()
  if ev.kind == 'disengage' then
    if planner and planner.mode ~= 'off' then
      planner:disengage(ev.reason or 'error', ev.detail)
      sentMode = 'off' -- the car already let go
      planTick()
    end
  elseif ev.kind == 'reengage' then
    -- the car decided that takeover was an accidental bump of the wheel
    if planner and veh and planner.mode == 'off' then
      local ego = egoSnapshot(veh)
      local okE, err = planner:engage(ev.mode or 'fsd', ev.profile, ego, trafficList())
      if okE then
        relayEvent({ kind = 'reengaged', detail = 'accidental takeover' })
        syncVehicleMode(veh)
      else
        relayEvent({ kind = 'error', detail = 'could not re-engage: ' .. tostring(err) })
      end
    end
  elseif ev.kind == 'diag' then
    vehDiag = ev.data
    send({ t = 'debug', ge = M.diagnostics(), vehicle = vehDiag })
  elseif ev.kind == 'nudge' then
    nudgeT = gameTime
  else
    send({ t = 'event', kind = ev.kind or 'error', detail = ev.detail })
  end
end

---------------------------------------------------------------------------
-- commands
---------------------------------------------------------------------------

local function engageFromApp(mode, profile)
  local veh = playerVehicle()
  if not veh then event('error', 'no player vehicle'); return end
  if not planner then event('error', 'map not loaded yet'); return end
  ensureVehicleExtension(veh)
  local ego = egoSnapshot(veh)
  local ok, err = planner:engage(mode, profile, ego, trafficList())
  if not ok then event('error', 'autopilot: ' .. tostring(err)); return end
  syncVehicleMode(veh)
  planTick()
end

-- wheel-button actions (mapped in the app's settings, pressed on the wheel; see relay button map)
local PROFILE_ORDER = { 'sloth', 'chill', 'standard', 'hurry', 'madmax' }
local runAction

handleCommand = function(msg)
  local t = msg.t
  if t == 'action' then return runAction(msg.name) end
  local veh = playerVehicle()
  if t == 'gear' or t == 'lights' or t == 'horn' or t == 'door' or t == 'throttleOverride' or t == 'wheel' then
    if not veh then event('error', 'no player vehicle'); return end
    ensureVehicleExtension(veh)
    toVehicle(veh, 'command', msg)
  elseif t == 'signal' then
    if not veh then event('error', 'no player vehicle'); return end
    -- the stalk while FSD / Autosteer drives: change lanes that way
    if planner and (planner.mode == 'fsd' or planner.mode == 'autosteer') and (msg.dir == 'left' or msg.dir == 'right') then
      planner:requestLaneChange(msg.dir)
    else
      toVehicle(veh, 'command', msg)
    end
  elseif t == 'autopilot' then
    if msg.mode == 'off' then
      if planner then planner:disengage('app') end
      if veh then syncVehicleMode(veh) end
    elseif planner and msg.mode == planner.mode and msg.profile then
      planner:setProfile(msg.profile) -- already on in this mode: just the profile (no re-engage)
    elseif msg.mode == 'fsd' or msg.mode == 'autosteer' or msg.mode == 'tacc' then
      engageFromApp(msg.mode, msg.profile)
    elseif msg.profile and planner then
      planner:setProfile(msg.profile)
    end
  elseif t == 'navigate' then
    local to = msg.to
    if type(to) == 'table' and to.node and graph and graph.nodes[to.node] then
      local n = graph.nodes[to.node]
      to = { n.x, n.y, n.z }
    end
    if type(to) ~= 'table' or not to[1] then event('error', 'navigate: bad destination'); return end
    if not planner or not veh then event('error', 'map not loaded yet'); return end
    planner:setRoute(to, msg.stops, msg.arrival)
    local ok, err = planner:planPath(egoSnapshot(veh), trafficList())
    if not ok then event('error', 'navigate: ' .. tostring(err)); return end
    planner.builtFor = planner.profile
    send(planner:routeMessage())
    planner.routeDirty = false
  elseif t == 'cancelRoute' then
    if not planner then return end
    planner:cancelRoute()
    send({ t = 'route', points = {}, length = 0 })
    if planner.mode ~= 'off' and veh then planner:planPath(egoSnapshot(veh), trafficList()); planner.routeDirty = false end
  elseif t == 'settings' then
    for k, v in pairs(msg) do if k ~= 't' and k ~= 'safety' then plannerSettings[k] = v end end
    if planner then planner:configure(plannerSettings) end
    if type(msg.safety) == 'table' then
      for k, v in pairs(msg.safety) do safetySettings[k] = v end
      safety:configure(safetySettings)
    end
    event('settings', 'updated')
  elseif t == 'attention' then
    attention = { state = msg.state or 'unknown', t = gameTime }
  elseif t == 'nudge' then
    nudgeT = gameTime
  elseif t == 'summon' then
    if not planner or not veh then return end
    planner:summon(msg.dir, egoSnapshot(veh))
    syncVehicleMode(veh)
  elseif t == 'autopark' then
    if not planner or not veh then return end
    local ok, err = planner:autopark(egoSnapshot(veh), trafficList())
    if not ok then event('error', 'autopark: ' .. tostring(err)) end
    syncVehicleMode(veh)
  elseif t == 'resetStrikes' then
    if planner then planner.nag:reset() end
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
  if planner and planner.mode ~= 'off' then
    planner:disengage('app')
    local veh = playerVehicle()
    if veh then syncVehicleMode(veh) end
  else
    engageFromApp(mode or 'fsd', planner and planner.profile)
  end
end

local function stepProfile(dir)
  if not planner then return end
  local i = 3
  for k, p in ipairs(PROFILE_ORDER) do if p == planner.profile then i = k end end
  local p = PROFILE_ORDER[math.max(1, math.min(#PROFILE_ORDER, i + dir))]
  planner:setProfile(p)
  event('settings', 'profile ' .. p)
end

runAction = function(name)
  local mode = planner and planner.mode or 'off'
  if name == 'toggleFSD' then M.toggleAutopilot('fsd')
  elseif name == 'toggleAutosteer' then M.toggleAutopilot('autosteer')
  elseif name == 'toggleTACC' then M.toggleAutopilot('tacc')
  elseif name == 'disengage' then handleCommand({ t = 'autopilot', mode = 'off' })
  elseif name == 'voiceNote' then M.voiceNote()
  elseif name == 'nudge' then M.nudge()
  elseif name == 'laneLeft' or name == 'laneRight' then
    handleCommand({ t = 'signal', dir = name == 'laneLeft' and 'left' or 'right' })
  elseif name == 'profileNext' then stepProfile(1)
  elseif name == 'profilePrev' then stepProfile(-1)
  elseif name == 'speedUp' or name == 'speedDown' then
    local d = name == 'speedUp' and 1 or -1
    if mode == 'fsd' then stepProfile(d) -- FSD: the scroll wheel picks the speed profile
    else
      local prof = P.PROFILES[planner and planner.profile or 'standard'] or P.PROFILES.standard
      local cur = plannerSettings.speedOffsetMph or math.floor(prof.offset / 0.44704 + 0.5)
      plannerSettings.speedOffsetMph = math.max(-10, math.min(20, cur + d))
      if planner then planner:configure(plannerSettings) end
      event('settings', string.format('speed offset %+d mph', plannerSettings.speedOffsetMph))
    end
  elseif name == 'followCloser' or name == 'followFarther' then
    local cur = plannerSettings.followDistance or 4
    plannerSettings.followDistance = math.max(1, math.min(7, cur + (name == 'followCloser' and -1 or 1)))
    if planner then planner:configure(plannerSettings) end
    event('settings', 'follow distance ' .. plannerSettings.followDistance)
  elseif name == 'autopark' then handleCommand({ t = 'autopark' })
  elseif name == 'summonForward' then handleCommand({ t = 'summon', dir = 'forward' })
  elseif name == 'summonReverse' then handleCommand({ t = 'summon', dir = 'reverse' })
  elseif name == 'summonStop' then handleCommand({ t = 'summon', dir = nil })
  else event('error', 'unknown action ' .. tostring(name)) end
end

-- Bound to "Tesla: voice note": the app starts/stops recording a note for later.
function M.voiceNote()
  send({ t = 'event', kind = 'voiceNote', detail = 'toggle', data = { lastDisengage = planner and planner.lastDisengage or nil } })
end

-- Bound to "Tesla: I'm paying attention" (a wheel button for keyboard/gamepad players).
function M.nudge()
  nudgeT = gameTime
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
  local d = { version = beamng_versionb or beamng_version, level = levelName(), mapNodes = mapMsg and #mapMsg.nodes or 0,
    mapLinks = graph and #graph.edges or 0, signals = #signals, parking = #parking, traffic = 0,
    apMode = planner and planner.mode or 'none', profile = planner and planner.profile, activity = planner and planner.activity,
    hasPath = planner ~= nil and planner.path ~= nil, relayQueue = outBytes,
    weather = weather, weatherProbe = weatherProbe, raycast = rayFn ~= nil, overhead = overhead,
    beacons = 0, emergencyNow = 0 }
  for _, c in pairs(traffic) do
    d.traffic = d.traffic + 1
    if c.emergency then d.emergencyNow = d.emergencyNow + 1 end
  end
  for _ in pairs(beacons) do d.beacons = d.beacons + 1 end
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
  local env = rawget(_G, 'core_environment')
  d.environmentApi = env and keysOf(env, 80) or 'missing'
  d.globals = {
    getPlayerVehicle = getPlayerVehicle ~= nil, getAllVehicles = getAllVehicles ~= nil, getObjectByID = getObjectByID ~= nil,
    jsonReadFile = jsonReadFile ~= nil, readFile = readFile ~= nil, mime = mime ~= nil,
    castRayStatic = rawget(_G, 'castRayStatic') ~= nil, vec3 = vec3 ~= nil,
  }
  if signals[1] then d.sampleSignal = { id = signals[1].id, kind = signals[1].kind, state = signals[1].get and signals[1].get() or nil } end
  if planner then d.nag = planner.nag:status() end
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
      if ov and sentMode ~= 'off' then toVehicle(ov, 'command', { t = 'autopilot', mode = 'off', reason = 'switch' }) end
      if planner then planner:disengage('switch'); planner:cancelRoute() end
      sentMode = 'off'
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

  if realTime >= tWeather then
    tWeather = realTime + 2
    pcall(sampleWeather)
  end

  if realTime >= tTraffic then
    tTraffic = realTime + 0.2
    sampleTraffic()
    sendTraffic()
  end

  if realTime >= tSafety then
    tSafety = realTime + 0.05
    local ok, err = pcall(safetyTick)
    if not ok then logW('safety tick: ' .. tostring(err)) end
  end

  if realTime >= tPlan then
    tPlan = realTime + 0.1
    local ok, err = pcall(planTick)
    if not ok then
      logW('plan tick: ' .. tostring(err))
      if planner and planner.mode ~= 'off' then
        planner:disengage('error', tostring(err))
        if veh then syncVehicleMode(veh) end
      end
    end
  end
end

local function onClientStartMission()
  mapMsg, graph, level, planner = nil, nil, nil, nil
  mapPending = true
  tMapPoll = realTime + 2 -- the road graph is built a moment after the level starts
  traffic, vehSize, beacons, beaconLoaded, vehNames = {}, {}, {}, {}, {}
  sentMode = 'off'
end

local function onClientEndMission()
  mapMsg, graph, level, planner = nil, nil, nil, nil
  traffic, vehSize, beacons, beaconLoaded, vehNames = {}, {}, {}, {}, {}
  sentMode = 'off'
end

local function onVehicleSpawned(vid)
  local veh = vehicleById(vid)
  local pv = playerVehicle()
  if veh and pv and pv:getID() == vid then ensureVehicleExtension(veh, true) end
  vehSize[vid] = nil
  vehNames[vid] = nil
  beaconLoaded[vid] = nil
end

local function onVehicleResetted(vid)
  local pv = playerVehicle()
  if pv and pv:getID() == vid and planner and planner.mode ~= 'off' then
    planner:disengage('error', 'vehicle reset')
    syncVehicleMode(pv)
  end
  beaconLoaded[vid] = nil
end

local function onVehicleDestroyed(vid)
  traffic[vid] = nil
  vehSize[vid] = nil
  lastVehState[vid] = nil
  beacons[vid], beaconLoaded[vid], vehNames[vid] = nil, nil, nil
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
M._planner = function() return planner end
M._handleCommand = function(msg) return handleCommand(msg) end

return M
