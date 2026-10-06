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

-- backup camera state (see the backup camera section)
local Cg = require('teslaBridge/camgov')
local CAM_VIEWS = { 'rear', 'front', 'left', 'right' }
local cam = {
  settings = { backup = false, side = false, fps = 3, width = 320, height = 180, fov = 100, format = 'jpg' }, -- off by default: the off-screen capture flashes the screen white on D3D11 (0.39)
  previewUntil = -1, nextT = 0, inline = false, reverseUntil = -1, failed = nil,
  previews = {},                      -- view -> realTime until which the app asked for it (front / left / right previews)
  views = {},                         -- per view: { on, seq, buf, pending }
  rr = 0,                             -- round robin: one screenshot per tick, whichever view is next
  gov = Cg.new(), scale = 1, level = 0, govNotedLevel = 0,
}
for _, v in ipairs(CAM_VIEWS) do cam.views[v] = { on = false, seq = 0, buf = 0, pending = nil } end
local CAM_DIR = 'temp/teslaBridge'

-- FSD brain, safety, and what we last told the car
local planner = nil
local reloadRequested = nil -- (update while playing) set by the reloadMod command, handled in onUpdate
local setTraffic -- (practice runner) AI traffic, defined further down
local castRay -- static ray cast, defined further down (the planner's closure needs it declared up here)
local banishedFrom = nil   -- where Banish started (so the car can come back)
local plannerSettings = {}   -- kept across level loads
local safetySettings = {}
local safety = Sf.new()
local sentMode = 'off'
local plannerStatus = {}
local drive -- Tesla driving aids state (auto lights, speed warning), set below
local spotsSentFor = nil
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
local parkingSpotsMsg -- forward
local autoShift -- forward
local pushVehicleSettings -- forward

-- BeamNG 0.39's plain 'socket' module is a stripped copy with no bind/tcp; the game's own
-- code loads the full LuaSocket as 'socket.socket'. Take the first one that can listen.
local socketTried = -1
local netErrLogAt = -1
local fpsAvg = 30
local learn = nil -- light on-line learning of his driving style (teslaBridge/learn)
local tLearnSave = 0
local loadLearn, saveLearn -- forward
local Lr = require('teslaBridge/learn')
local Po = require('teslaBridge/policy')
local Sc = require('teslaBridge/score')
local tripScore = Sc.new() -- trip stats, Safety Score, hard-braking hazards
local tripT, tripHazardSent, tripWasMoving = nil, false, false
local tAids = 0
local climateState = {} -- climate foundation: what the app last asked for (no fan/heater hardware yet; hardware bridges read state.climate)
local CLIMATE_KEYS = { on = 'boolean', driverTemp = 'number', passengerTemp = 'number', fan = 'number', defrost = 'boolean', precondition = 'boolean',
  cabinOverheat = 'boolean', keepOn = 'boolean', dogMode = 'boolean', campMode = 'boolean', bioweapon = 'boolean', seatHeat = 'table', wheelHeat = 'boolean', vents = 'string' }
local pinLocked = false -- PIN to Drive: the car stays in Park until the app says the PIN was entered
local pinNoticeT = -1e9
local wiperLevel = 0 -- 0 at start: we never switch off wipers the driver turned on
local Ls = require('teslaBridge/lightshow')
local Lq = require('teslaBridge/launchreq')
local show = nil -- running light show { name, t0, last = key, prev = restore state }
local tShow = 0
local handoverSent = false -- the car was told a takeover is being requested (gas = take over)
local function loadSocket()
  for _, name in ipairs({ 'socket.socket', 'socket' }) do
    local ok, s = pcall(require, name)
    if ok and type(s) == 'table' and (type(s.bind) == 'function' or type(s.tcp) == 'function') then
      logI('network library: ' .. name)
      return s
    end
  end
  return nil
end

local function bindServer(host, port)
  if type(socket.bind) == 'function' then return socket.bind(host, port) end
  -- tcp4 makes the real socket now; plain tcp() may defer it to bind, so reuseaddr would
  -- silently fail and a restart would find the port "in use" until TIME_WAIT ends
  local mk = type(socket.tcp4) == 'function' and socket.tcp4 or socket.tcp
  local s, err = mk()
  if not s then return nil, err end
  pcall(function() s:setoption('reuseaddr', true) end)
  local ok, e = s:bind(host, port)
  if not ok then s:close(); return nil, e end
  ok, e = s:listen(8)
  if not ok then s:close(); return nil, e end
  return s
end

local function netUpdate()
  if not socket then
    if realTime < socketTried then return end
    socket = loadSocket()
    if not socket then
      -- log once per 30 s, not every frame
      logW('no usable network library (tried socket.socket, socket): the relay cannot connect')
      socketTried = realTime + 30
      return
    end
  end
  if not server and realTime >= nextBindTry then
    local s, err = bindServer('127.0.0.1', PORT)
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
        local rec
        local function getState()
          local st
          if type(inst.getState) == 'function' then st = try(inst.getState, inst) end
          if st == nil then st = inst.state or inst.signalState or inst.action or inst.targetState end
          if st == nil and ctrl then st = ctrl.state or ctrl.activeState or ctrl.currState end
          if type(st) == 'table' then st = st.name or st.type or st.state end
          st = string.lower(tostring(st or ''))
          if rec then rec.raw = st end
          -- flashing red / a plain "stop" state = all-way stop (stop, then go); flashing
          -- yellow = caution (no stop). 'stop' alone must not read as a red light, or the
          -- car waits forever at a stop-sign controller.
          if st:find('flash') or st:find('blink') then
            if rec then rec.flashing = true end -- a real light flashing red: all-way stop, not a painted line
            return (st:find('red') or st:find('stop')) and 'stop' or nil
          end
          if st:find('stop') and not st:find('red') then return 'stop' end
          if st:find('off') or st:find('disabled') or st:find('none') then return nil end
          if st:find('red') then return 'red' end
          if st:find('yellow') or st:find('amber') or st:find('caution') then return 'yellow' end
          if st:find('green') or st:find('go') then return 'green' end
          return nil
        end
        rec = {
          id = 'sig:' .. name, x = p.x, y = p.y, z = p.z, kind = kind, type = typ .. (ctype ~= '' and ('/' .. ctype) or ''),
          dirx = d and d.x or nil, diry = d and d.y or nil, get = kind == 'signal' and getState or nil,
        }
        signals[#signals + 1] = rec
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
  -- which traffic-system signals have a real stop sign standing near them (a 'basicstop'
  -- controller with no sign is a painted line / crosswalk: never a full stop)
  for _, sg in ipairs(signals) do
    if not sg.prop then
      for _, pp in ipairs(signals) do
        if pp.prop and (pp.x - sg.x) ^ 2 + (pp.y - sg.y) ^ 2 < 20 * 20 then sg.signNear = true; break end
      end
      if (found.props or 0) == 0 then sg.signNear = nil end -- no props in this level: can't tell
      if (found.props or 0) > 0 and not sg.signNear then sg.signNear = false end
    end
  end
  -- traffic-system "stop" points with no stop-sign prop nearby are crosswalks / painted lines,
  -- not stop signs (Quentin's rule: only real stop signs). Kept when the level has no props
  -- at all (we couldn't tell the real ones apart).
  local dropped = 0
  if (found.props or 0) > 0 then
    local keep = {}
    for _, sg in ipairs(signals) do
      local ok = true
      if sg.kind == 'stop' and not sg.prop then
        ok = false
        for _, pp in ipairs(signals) do
          if pp.prop and (pp.x - sg.x) ^ 2 + (pp.y - sg.y) ^ 2 < 20 * 20 then ok = true; break end
        end
      end
      if ok then keep[#keep + 1] = sg else dropped = dropped + 1 end
    end
    signals = keep
  end
  logI(string.format('signals: %d from traffic system, %d stop-sign props, %d sign-less stops dropped', found.ts or 0, found.props or 0, dropped))
end

local function findParking()
  parking = {}
  local function add(p, fx, fy)
    if p then parking[#parking + 1] = { x = p.x, y = p.y, z = p.z, dx = fx or 0, dy = fy or 1, known = fx ~= nil and fy ~= nil } end
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
  if not learn then loadLearn() end
  local polSpec = jsonReadFile and try(jsonReadFile, '/settings/teslaBridgePolicy.json') or nil -- trained by rl/train_bc.py
  planner = Pl.new({ graph = graph, signals = signals, parking = parking, learn = learn, policy = type(polSpec) == 'table' and Po.new(polSpec) or nil })
  safety.brain = planner.brain -- one brain reads the traffic for both driving and safety
  planner.castRay = function(x, y, z, dx, dy, dz, dist) return castRay(x, y, z, dx, dy, dz, dist) end -- Autopark looks for walls with it
  planner:configure(plannerSettings)
  sentMode = 'off'
  local sig = {}
  for _, s in ipairs(signals) do sig[#sig + 1] = { id = s.id, pos = { num(s.x), num(s.y), num(s.z) }, kind = s.kind } end
  local park = {}
  for _, p in ipairs(parking) do park[#park + 1] = { pos = { num(p.x), num(p.y), num(p.z) }, dir = { num(p.dx, 3), num(p.dy, 3), 0 } } end
  -- named places for the app's map (gas stations, garages, shops...): the level's "facilities", best effort (the shape varies by
  -- game version), each with a position when it has one
  local pois = {}
  try(function()
    local fac = freeroam_facilities and freeroam_facilities.getFacilities and freeroam_facilities.getFacilities(lvl)
    if type(fac) ~= 'table' then return end
    local function posOf(f)
      local p = f.pos or f.position or f.center or f.doorPos or (f.doors and f.doors[1] and f.doors[1].pos)
      if p and p.x then return p.x, p.y, p.z end
      if type(p) == 'table' and p[1] then return p[1], p[2], p[3] end
    end
    for kind, list in pairs(fac) do
      if type(list) == 'table' then
        for _, f in pairs(list) do
          if type(f) == 'table' and #pois < 400 then
            local x, y, z = posOf(f)
            local nm = f.name or f.label or f.id
            if x and nm then pois[#pois + 1] = { name = tostring(nm):gsub('^"?(.-)"?$', '%1'), pos = { num(x), num(y), num(z or 0) }, kind = tostring(kind) } end
          end
        end
      end
    end
  end)
  level = lvl
  mapMsg = {
    t = 'map', level = lvl, pois = pois,
    bounds = { min = { num(minx), num(miny) }, max = { num(maxx), num(maxy) } },
    minimapInfo = minimapInfo(lvl),
    nodes = nodes, links = links, signals = sig, parking = park,
  }
  logI(string.format('map %s: %d nodes, %d links, %d places', lvl, #nodes, #links, #pois))
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
castRay = function(px, py, pz, dx, dy, dz, dist)
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
    -- a second ray 0.9 m higher: a real wall/pole/car is hit by both at about the same distance; a rising road or
    -- crest is hit by the low ray much sooner (that read as a wall dead ahead: phantom braking at 30 mph)
    frontHi = castRay(ego.x + ego.hx * half, ego.y + ego.hy * half, z + 0.9, ego.hx, ego.hy, 0, 30),
    rear = castRay(ego.x - ego.hx * half, ego.y - ego.hy * half, z, -ego.hx, -ego.hy, 0, 15),
    left = castRay(ego.x, ego.y, z, -ego.hy, ego.hx, 0, 8),
    right = castRay(ego.x, ego.y, z, ego.hy, -ego.hx, 0, 8),
  }
  -- A fan of rays either side of straight ahead: a wall at an angle (a corner, a building across a bend) is missed by the
  -- single centre ray until it is too late. A hit counts when it lies inside the car's own width (plus a margin) at that
  -- distance; low and high rays have to agree (same phantom-wall rule as above).
  local wid = (ego.wid or 1.9) * 0.5 + 0.35
  for _, deg in ipairs({ -30, -18, -9, 9, 18, 30 }) do
    local a = math.rad(deg)
    local c, sn = math.cos(a), math.sin(a)
    local dx, dy = ego.hx * c - ego.hy * sn, ego.hy * c + ego.hx * sn
    local ox, oy = ego.x + ego.hx * half, ego.y + ego.hy * half
    local lo = castRay(ox, oy, z, dx, dy, 0, 25)
    if lo and math.abs(lo * sn) < wid + lo * 0.03 then
      local hi = castRay(ox, oy, z + 0.9, dx, dy, 0, 25)
      if hi and math.abs(hi - lo) < 1.5 then
        local fwd, fwdHi = lo * c, hi * c
        if not rays.front or fwd < rays.front then rays.front = fwd end
        if not rays.frontHi or fwdHi < rays.frontHi then rays.frontHi = fwdHi end
      end
    end
  end
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
  local detail = ev.detail or ev.reason or ev.dir or ev.side or ev.what or ev.action or ev.state or ev.where
  if ev.kind == 'nag' then detail = tostring(ev.level) .. (ev.reason and (' ' .. ev.reason) or '') end
  if ev.kind == 'monitoring' then detail = ev.state end
  if ev.kind == 'strike' then detail = tostring(ev.strikes) .. '/' .. tostring(ev.max) end
  if ev.kind == 'stuck' then detail = 'level ' .. tostring(ev.level) end
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
  -- approaching the destination: send the parking spots around it once (the app shows them
  -- when "show parking spots" is on; tapping one sends { t = 'autopark', spot = id })
  if planner.dest and plannerStatus.remaining and plannerStatus.remaining < 200 then
    local key = math.floor(planner.dest[1]) .. ',' .. math.floor(planner.dest[2])
    if spotsSentFor ~= key then
      spotsSentFor = key
      pcall(function() send(parkingSpotsMsg(planner.dest[1], planner.dest[2], 80)) end)
    end
  end
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
  do local mo = map and map.objects and map.objects[veh:getID()]; ego.damage = mo and tonumber(mo.damage) or nil end
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
    laneDeparture = so.lda ~= nil, ttc = so.ttc and num(so.ttc) or nil, rearWarn = so.rearWarn or nil }
  local assist = { aeb = so.aeb or 0, ldaSteer = so.lda and num(so.lda.steer, 3) or 0, lkaSteer = so.lka and num(so.lka.steer, 3) or 0, throttleCap = so.throttleCap }
  if plannerSettings.valet and (ego.v or 0) > 29 then assist.throttleCap = 0 end -- Valet: top speed about 65 mph
  local active = assist.aeb > 0 or assist.ldaSteer ~= 0 or assist.lkaSteer ~= 0 or assist.throttleCap ~= nil
  if active or (lastAssist and (lastAssist.aeb > 0 or lastAssist.ldaSteer ~= 0 or (lastAssist.lkaSteer or 0) ~= 0 or lastAssist.throttleCap ~= nil)) then
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
  -- Paint colour as #rrggbb (veh.color is a 0..1 vector; field names differ by build).
  local color = try(function()
    local c = veh.color or (veh.getColor and veh:getColor())
    if not c then return nil end
    local r, g, b = c.x or c.r or c[1], c.y or c.g or c[2], c.z or c.b or c[3]
    if not (r and g and b) then return nil end
    local function h(v) return math.max(0, math.min(255, math.floor(v * 255 + 0.5))) end
    return string.format('#%02x%02x%02x', h(r), h(g), h(b))
  end)
  return { id = veh:getID(), name = name, model = jb, color = color }
end

-- Tesla-style driving aids that run whether or not FSD drives (settings, default in brackets):
--  autoHeadlights [on]: lights on when it's dark (BeamNG time of day: 0 = noon, 0.5 = midnight)
--    or raining, off in daylight. Only acts when that changes, so you can still override.
--  autoHighBeams [off]: at night above 25 mph, high beams unless a car is ahead within 150 m.
--  speedWarning ['display'|'chime'|'off'] + speedWarnOffset [5 mph]: over the limit by more
--    than the offset for 1.5 s -> state.speedWarning (and a 'speedWarning' event with 'chime').
drive = { limitHere = nil, warning = nil, overSince = nil, lastChime = -1e9, lightsWant = nil, highWant = nil }

local function timeOfDay()
  local env = rawget(_G, 'core_environment')
  if not env or type(env.getTimeOfDay) ~= 'function' then return nil end
  local tod = try(env.getTimeOfDay)
  if type(tod) == 'table' then tod = tod.time end
  return tonumber(tod)
end

local function showKey(s) return table.concat({ tostring(s.low), tostring(s.high), tostring(s.fog), tostring(s.left), tostring(s.right), tostring(s.hazard) }, ',') end

local function showApply(veh, s)
  toVehicle(veh, 'command', { t = 'lights', low = s.low or s.high, high = s.high, fog = s.fog })
  toVehicle(veh, 'command', { t = 'signal', dir = s.hazard and 'hazard' or (s.left and 'left' or (s.right and 'right' or nil)) })
end

local function stopLightShow(veh, why)
  if not show then return end
  local was = show
  show = nil
  if veh then
    -- back to how the lights were (auto headlights decide again on the next aids tick)
    toVehicle(veh, 'command', { t = 'lights', low = was.prevLow and true or false, high = false, fog = was.prevFog and true or false })
    toVehicle(veh, 'command', { t = 'signal' })
    drive.lightsWant = nil
  end
  relayEvent({ kind = 'lightShow', detail = 'end', data = { reason = why, name = was.name } })
end

-- Only while parked (P or standing still in N) and FSD is off: never flashes lights at speed.
function M.startLightShow(name)
  local veh = playerVehicle()
  if not veh then return end
  if not name then stopLightShow(veh, 'stopped'); return end
  if not Ls.length(name) then event('error', 'unknown light show ' .. tostring(name)); return end
  if (lastVehSt.speed or 0) > 1 or (planner and planner.mode ~= 'off') then event('error', 'light shows only run while parked'); return end
  local lights = lastVehSt.lights or {}
  show = { name = name, t0 = realTime, prevLow = lights.low or lights.high, prevFog = lights.fog }
  relayEvent({ kind = 'lightShow', detail = name })
end

local function lightShowTick(veh)
  if not show or not veh then return end
  if (lastVehSt.speed or 0) > 1 or (planner and planner.mode ~= 'off') or (lastVehSt.gear ~= 'P' and lastVehSt.gear ~= 'N') then
    stopLightShow(veh, 'driving')
    return
  end
  local s, done = Ls.state(show.name, realTime - show.t0)
  if done then stopLightShow(veh, 'finished'); return end
  local key = showKey(s)
  if key ~= show.last then
    show.last = key
    showApply(veh, s)
  end
end

local function driveAidsTick(veh)
  if not veh or not graph then return end
  local ego = egoSnapshot(veh)
  -- speed limit here
  local e = P.nearestEdge(graph, ego.x, ego.y, ego.hx, ego.hy, 15)
  if e then
    local a, b = graph.nodes[e.a], graph.nodes[e.b]
    drive.limitHere = e.lim or P.classDefaultSpeed((a.r + b.r) * 0.5, e.drv)
  else
    drive.limitHere = nil
  end
  -- time gap to the car ahead in our lane (Safety Score's "following distance", and learning)
  do
    local gapT
    for _, c in ipairs(trafficList()) do
      local dx, dy = c.x - ego.x, c.y - ego.y
      local along = dx * ego.hx + dy * ego.hy
      if along > 3 and along < 80 and math.abs(-dx * ego.hy + dy * ego.hx) < 2 and ego.v > 3 then
        local t = along / ego.v
        if not gapT or t < gapT then gapT = t end
      end
    end
    drive.gapT = gapT
  end
  -- learning (a few multiplies, twice a second)
  if learn and plannerSettings.learning ~= false and drive.limitHere then
    if (not planner or planner.mode == 'off') and lastVehSt.gear == 'D' then
      local gapT
      local cars = trafficList()
      for _, c in ipairs(cars) do
        local dx, dy = c.x - ego.x, c.y - ego.y
        local along = dx * ego.hx + dy * ego.hy
        if along > 3 and along < 80 and math.abs(-dx * ego.hy + dy * ego.hx) < 2 and ego.v > 3 then
          local t = along / ego.v
          if not gapT or t < gapT then gapT = t end
        end
      end
      learn:watch(drive.limitHere, ego.v, gapT, 0.5)
    elseif planner and planner.mode == 'fsd' and lastVehSt.accelOverride then
      learn:feedback(drive.limitHere, 'faster', 0.5)
    end
    if realTime >= tLearnSave then tLearnSave = realTime + 60; saveLearn() end
  end
  -- PIN to Drive: no gear but Park until unlocked (never yanked while moving)
  if pinLocked and lastVehSt.gear and lastVehSt.gear ~= 'P' and (lastVehSt.speed or 0) < 1 then
    toVehicle(veh, 'command', { t = 'gear', gear = 'P' })
    if realTime - pinNoticeT > 3 then pinNoticeT = realTime; relayEvent({ kind = 'pinRequired', detail = 'enter the PIN to drive' }) end
  end
  -- Auto wipers from the weather (best effort: which wiper control a car exposes varies; see diag)
  if plannerSettings.autoWipers ~= false then
    local rain = weather.rain or 0
    local want = rain > 0.6 and 3 or (rain > 0.3 and 2 or (rain > 0.05 and 1 or 0))
    if want ~= wiperLevel then
      wiperLevel = want
      toVehicle(veh, 'command', { t = 'wipers', level = want })
    end
  end
  -- speed warning
  local mode = plannerSettings.speedWarning or 'display'
  local over = drive.limitHere and ego.v > drive.limitHere + (tonumber(plannerSettings.speedWarnOffset) or 5) * 0.44704
  if mode ~= 'off' and over then
    drive.overSince = drive.overSince or realTime
    if realTime - drive.overSince > 1.5 then
      drive.warning = true
      if mode == 'chime' and realTime - drive.lastChime > 15 then
        drive.lastChime = realTime
        relayEvent({ kind = 'speedWarning', detail = string.format('%.0f in a %.0f', ego.v / 0.44704, drive.limitHere / 0.44704) })
      end
    end
  else
    drive.overSince, drive.warning = nil, nil
  end
  -- lights
  local tod = timeOfDay()
  local dark = tod and tod > 0.22 and tod < 0.78 -- about 6:40 pm to 5:20 am
  local wet = (weather.rain or 0) > 0.3
  local lights = lastVehSt.lights or {}
  if plannerSettings.autoHeadlights ~= false and tod and not show then
    local want = (dark or wet) and true or false
    if want ~= drive.lightsWant then
      drive.lightsWant = want
      if want ~= (lights.low or false) then toVehicle(veh, 'command', { t = 'lights', low = want }) end
    end
  end
  -- fog lights in fog (Tesla: auto fog), only ever switched off again if we switched them on
  if plannerSettings.autoFogLights ~= false and not show then
    local foggy = (weather.fog or 0) > 0.4 and (lights.low or lights.high or false)
    if foggy ~= (drive.fogWant or false) then
      if foggy or drive.fogWant then toVehicle(veh, 'command', { t = 'lights', fog = foggy and true or false }) end
      drive.fogWant = foggy
    end
  end
  if not (plannerSettings.autoHighBeams and dark) then
    -- setting off or daylight: hand the beams back dipped if we had them up
    if drive.highWant then toVehicle(veh, 'command', { t = 'lights', high = false }) end
    drive.highWant = nil
  else
    local blocked = false
    for _, c in ipairs(trafficList()) do
      local dx, dy = c.x - ego.x, c.y - ego.y
      local d = math.sqrt(dx * dx + dy * dy)
      if d < 150 and d > 1 and (dx * ego.hx + dy * ego.hy) / d > 0.94 then blocked = true; break end -- within ~20 deg ahead
    end
    local want = (lights.low or lights.high) and ego.v > 11 and not blocked
    if want ~= drive.highWant then
      drive.highWant = want
      toVehicle(veh, 'command', { t = 'lights', high = want and true or false })
      if want ~= nil then relayEvent({ kind = 'autoHighBeams', detail = want and 'on' or 'off' }) end
    end
  end
end

-- Red/blue alert card for the app (crash, take over now, attention).
--  crash: the car's damage jumps by > 9000 within a second (a real hit, not a scrape); stays
--         until the car is repaired/reset. FSD lets go and the hazards go on.
--  takeover: FSD over 80 mph where the limit is under 55.
--  attention: the nag at level 2+.
local crash = { hist = {}, active = nil }
local function damageOf(vid)
  local mo = map and map.objects and map.objects[vid]
  return mo and tonumber(mo.damage) or nil
end

local function computeAlert(vid, st, ps, nag)
  if crash.vid ~= vid then crash = { hist = {}, active = nil, vid = vid } end -- another car: its own baseline
  local dmg = damageOf(vid)
  if dmg then
    local h = crash.hist
    h[#h + 1] = { t = realTime, d = dmg }
    while #h > 1 and realTime - h[1].t > 1 do table.remove(h, 1) end
    if crash.active and dmg < math.max(50, crash.active.base * 0.5) then crash.active = nil end -- repaired / reset
    if not crash.active and dmg - h[1].d > 9000 then
      crash.active = { t = realTime, base = h[1].d + 1 }
      relayEvent({ kind = 'collision', detail = string.format('damage +%.0f', dmg - h[1].d) })
      local veh = vehicleById(vid)
      if planner and planner.mode ~= 'off' then
        planner:disengage('error', 'collision')
        if veh then syncVehicleMode(veh) end
      end
      if veh then toVehicle(veh, 'command', { t = 'signal', dir = 'hazard' }) end
    end
  end
  if crash.active then return { kind = 'crash', message = 'Pull over immediately', level = 3 } end
  local engaged = st.autopilot and st.autopilot.engaged
  local lim = ps.speedLimit
  if engaged and planner and planner.mode == 'fsd' and (st.speed or 0) > 35.8 and lim and lim < 24.6 then
    return { kind = 'takeover', message = 'Take over immediately', level = 3 }
  end
  if engaged and (nag.level or 0) >= 1 and nag.reason == 'hands' then
    -- wheel monitoring: ask for a little force on the wheel, like a Tesla
    return { kind = 'attention', message = (nag.level or 0) >= 3 and 'Take over immediately' or 'Apply slight force to the steering wheel', level = nag.level }
  end
  if engaged and (nag.level or 0) >= 2 then
    return { kind = 'attention', message = (nag.level or 0) >= 3 and 'Take over immediately' or 'Pay attention to the road', level = nag.level }
  end
  -- FSD isn't sure (confidence under 55 %): asks for a takeover but keeps driving until you act
  if engaged and ps.lowConfidence then
    return { kind = 'lowConfidence', message = 'Take over? FSD is unsure', level = 1, confidence = ps.confidence and num(ps.confidence, 2) or nil }
  end
  -- heavy rain / fog: "FSD degraded" (it already slows down; this tells the driver why)
  local wx = ps.weather
  if engaged and type(wx) == 'table' and ((wx.rain or 0) > 0.6 or (wx.fog or 0) > 0.5) then
    return { kind = 'degraded', message = (wx.fog or 0) > 0.5 and 'FSD degraded: poor visibility (fog)' or 'FSD degraded: heavy rain', level = 1 }
  end
  return nil
end

-- Called from the vehicle extension (vehicle VM) at 20 Hz.
function M.onVehicleState(vid, json)
  lastVehState[vid] = realTime
  local veh = vehicleById(vid)
  local pv = playerVehicle()
  if not pv or pv:getID() ~= vid then return end
  -- main menu / no level: no state (the app shows its boot logo until we're in a world)
  if not levelName() then return end
  local ok, st = pcall(jsonDecode, json)
  if not ok or type(st) ~= 'table' then return end
  lastVehSt = { speed = st.speed or 0, gear = st.gear, throttle = st.rawThrottle or st.throttle, signal = st.signal ~= false and st.signal or nil,
    lights = st.lights, accelOverride = st.autopilot and st.autopilot.accelOverride or false }
  -- trip stats / Safety Score / emergency-braking hazards
  do
    local dtS = tripT and (realTime - tripT) or 0
    tripT = realTime
    if dtS > 0 and dtS < 0.5 then
      tripScore:update(dtS, { v = st.speed or 0, yawRate = yawState.rate, gap = drive and drive.gapT,
        fsd = st.autopilot and st.autopilot.engaged and st.autopilot.mode == 'fsd' })
    end
    -- hazards come on only in a crash (see the collision check above), not for hard braking
    if false and tripScore.hazard ~= tripHazardSent and veh then
      tripHazardSent = tripScore.hazard
      toVehicle(veh, 'command', tripScore.hazard and { t = 'signal', dir = 'hazard' } or { t = 'signal' })
      if tripScore.hazard then relayEvent({ kind = 'notice', detail = 'hazards on: emergency braking' }) end
    end
    if (st.speed or 0) > 2 then tripWasMoving = true end
    if st.gear == 'P' and tripWasMoving and (st.speed or 0) < 0.5 then
      tripWasMoving = false
      if tripScore.dist >= 300 then
        relayEvent({ kind = 'tripSummary', detail = tostring(tripScore:score()), data = tripScore:summary() })
      end
      tripScore:reset()
      tripHazardSent = false
    end
  end
  -- backup camera: on in R, and for 2 s after leaving it (like the real thing)
  if st.gear == 'R' then cam.reverseUntil = realTime + 2 end
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
    phase = ps.phase,
    targetSpeed = num(va.targetSpeed or 0),
    speedLimit = ps.speedLimit and num(ps.speedLimit) or nil,
    setSpeed = ps.setSpeed and num(ps.setSpeed) or nil,
    leadGap = ps.leadGap and num(ps.leadGap, 1) or nil,
    control = ps.control and { kind = ps.control.kind, dist = num(ps.control.dist, 1), red = ps.control.red, state = ps.control.state,
      id = ps.control.id, dot = ps.control.dot and num(ps.control.dot, 2) or nil, lat = ps.control.lat and num(ps.control.lat, 1) or nil } or nil,
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
    nag = { level = nag.level or 0, reason = nag.reason, strikes = nag.strikes or 0, maxStrikes = nag.maxStrikes or 5, lockedOut = nag.lockedOut or false,
      mode = nag.mode, active = nag.active, interval = nag.interval },
    confidence = ps.confidence and num(ps.confidence, 2) or nil,
    lastDisengage = planner and planner.lastDisengage or nil,
    accelOverride = va.accelOverride or false,
    steerGain = va.steerGain, steerSign = va.steerSign,
  }
  st.safety = safetyStatus
  -- the road's speed limit right here, FSD on or off (Tesla shows it all the time)
  st.speedLimit = drive.limitHere and num(drive.limitHere, 1) or nil
  st.speedWarning = drive.warning or nil
  if next(climateState) then st.climate = climateState end
  do
    local vs = {}
    for _, name in ipairs(CAM_VIEWS) do if cam.views[name].on then vs[#vs + 1] = name end end
    if #vs > 0 or cam.level > 0 then st.camera = { views = vs, level = cam.level, paused = cam.level >= 3 } end
  end
  st.trip = { score = tripScore:score(), km = num(tripScore.dist / 1000, 2), fsdPercent = num(tripScore.dist > 0 and tripScore.fsdDist / tripScore.dist * 100 or 0, 0), hardBrakes = tripScore.hardBrakes }
  local okA, alert = pcall(computeAlert, vid, st, ps, nag)
  st.autopilot.alert = okA and alert or nil
  st.damage = damageOf(vid) -- (practice runner: curb and wall hits)
  -- while FSD is asking for a takeover, tapping the accelerator hands the car over
  local wantHandover = st.autopilot.alert and (st.autopilot.alert.kind == 'takeover' or st.autopilot.alert.kind == 'lowConfidence'
    or (st.autopilot.alert.kind == 'attention' and (st.autopilot.alert.level or 0) >= 3)) or false
  if wantHandover ~= handoverSent and veh then
    handoverSent = wantHandover
    toVehicle(veh, 'command', { t = 'handover', on = wantHandover })
  end
  -- the car reports once per frame at most, so below 20 fps the state rate = the game's fps
  st.fps = num(fpsAvg, 0)
  send(st, true)
end

-- Events from the vehicle (takeover disengage, accidental-disengage re-engage, errors, diagnostics).
function M.onVehicleEvent(vid, json)
  local ok, ev = pcall(jsonDecode, json)
  if not ok or type(ev) ~= 'table' then return end
  local veh = playerVehicle()
  if ev.kind == 'disengage' then
    if learn and drive.limitHere and (ev.reason == 'brake' or ev.reason == 'steer') and (lastVehSt.speed or 0) > drive.limitHere * 0.95 then
      learn:feedback(drive.limitHere, 'slower') -- he took over while going at / over the limit
    end
    if ev.reason == 'brake' or ev.reason == 'steer' then
      local ego = veh and egoSnapshot(veh) -- remember where: the same place gets a gentler drive next time
      if learn and ego then learn:markSpot(ego.x, ego.y) end
    end
    if ev.reason == 'brake' or ev.reason == 'steer' or ev.reason == 'throttle' then tripScore:takeover() end
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
  elseif ev.kind == 'brakeInPark' then
    if veh then pcall(autoShift, veh) end
  elseif ev.kind == 'driverSignal' then
    -- the driver flicked the turn signal (wheel paddles / stalk) while FSD or Autosteer
    -- drives: change lanes that way, or turn at the next junction if there's no lane
    if planner and (planner.mode == 'fsd' or planner.mode == 'autosteer') and (ev.dir == 'left' or ev.dir == 'right') then
      planner:requestLaneChange(ev.dir)
    end
  else
    send({ t = 'event', kind = ev.kind or 'error', detail = ev.detail })
  end
end

---------------------------------------------------------------------------
-- commands
---------------------------------------------------------------------------

-- Parking spots near a point for the app's map ("show parking spots"; tap one to Autopark).
parkingSpotsMsg = function(x, y, radius)
  local list = planner and planner:spotsNear(x, y, radius, trafficList()) or {}
  local spots = {}
  for _, sp in ipairs(list) do
    spots[#spots + 1] = { id = sp.id, pos = { num(sp.x), num(sp.y), num(sp.z) }, dir = { num(sp.dx or 0, 3), num(sp.dy or 1, 3) }, free = sp.free }
  end
  return { t = 'parkingSpots', near = { num(x), num(y) }, spots = spots }
end

-- Auto Shift out of Park (setting autoShift): the driver presses the brake in P and the car
-- picks D or R itself: a wall, curb or car right in front (and room behind) -> R, else D.
autoShift = function(veh)
  if plannerSettings.autoShift == false or not planner or planner.mode ~= 'off' or pinLocked then return end
  local ego = egoSnapshot(veh)
  local rays = sampleRays(ego)
  local front, rear = rays.front, rays.rear -- metres to a wall/curb, or nil
  local carAhead, carBehind = false, false
  for _, c in ipairs(trafficList()) do
    local dx, dy = c.x - ego.x, c.y - ego.y
    local along = dx * ego.hx + dy * ego.hy
    local side = math.abs(-dx * ego.hy + dy * ego.hx)
    if side < 1.8 and along > 0 and along < 5.5 then carAhead = true end
    if side < 1.8 and along < 0 and along > -5.5 then carBehind = true end
  end
  local blockedAhead = (front and front < 2.0) or carAhead
  local blockedBehind = (rear and rear < 2.0) or carBehind
  local gear = (blockedAhead and not blockedBehind) and 'R' or 'D'
  toVehicle(veh, 'command', { t = 'gear', gear = gear })
  relayEvent({ kind = 'autoShift', detail = gear })
end

-- settings the car itself applies (its extension starts from defaults after a reload)
pushVehicleSettings = function(veh)
  local ps = plannerSettings
  if ps.swerveAssist ~= nil then toVehicle(veh, 'command', { t = 'swerveAssist', on = ps.swerveAssist and true or false }) end
  if ps.valet then toVehicle(veh, 'command', { t = 'drive', accel = 'chill' }) end
  if ps.takeover or ps.roadFeel ~= nil or ps.steeringWeight then toVehicle(veh, 'command', { t = 'wheel', takeover = ps.takeover, roadFeel = ps.roadFeel, weight = ps.steeringWeight }) end
  if ps.ownFfb ~= nil then toVehicle(veh, 'command', { t = 'wheel', ownFfb = ps.ownFfb and true or false }) end
  if ps.paddleSignals ~= nil then toVehicle(veh, 'command', { t = 'paddles', signals = ps.paddleSignals and true or false }) end
  if ps.stoppingMode or ps.regen ~= nil or ps.accelMode or ps.hillHold ~= nil or ps.regenLevel then
    toVehicle(veh, 'command', { t = 'drive', stopping = ps.stoppingMode, regen = ps.regen, accel = ps.accelMode, hillHold = ps.hillHold, regenLevel = ps.regenLevel })
  end
end

local function engageFromApp(mode, profile)
  local veh = playerVehicle()
  if not veh then event('error', 'no player vehicle'); return end
  if not planner then event('error', 'map not loaded yet'); return end
  if plannerSettings.valet then event('error', 'Valet Mode: self-driving is off'); return end
  if pinLocked then event('error', 'PIN to Drive: enter the PIN first'); return end
  ensureVehicleExtension(veh)
  local ego = egoSnapshot(veh)
  if mode ~= 'tacc' and math.abs(ego.v or 0) < 1 and ego.gear ~= 'R' then
    -- never launch into a wall/pole right in front (e.g. engaged in Park facing one)
    local front = sampleRays(ego).front
    if front and front < 4 then event('error', 'autopilot: something is right in front of the car - back up first'); return end
  end
  local ok, err = planner:engage(mode, profile, ego, trafficList())
  if not ok then event('error', 'autopilot: ' .. tostring(err)); return end
  syncVehicleMode(veh)
  planTick()
end

---------------------------------------------------------------------------
-- backup camera: while in R, render a small off-screen view from the rear bumper with
-- render_renderViews.takeScreenshot (the retail RenderView path; camera sensors are
-- BeamNG.tech-only) and hand the frames to the relay, which streams them to the iPad.
-- Nothing changes on the game screen, and it only renders while reversing (or while the
-- app asks for a preview), at low resolution and a few frames a second.
---------------------------------------------------------------------------


-- render_renderViews is an on-demand extension: in 0.39 it isn't loaded until someone asks
-- for it, so the global is nil. Load it once, then look it up wherever it lands.
local rvLoadTried = false
local function renderViews()
  local rv = render_renderViews or (type(extensions) == 'table' and rawget(extensions, 'render_renderViews'))
  if type(rv) ~= 'table' and not rvLoadTried and extensions and type(extensions.load) == 'function' then
    rvLoadTried = true
    try(extensions.load, 'render_renderViews')
    rv = render_renderViews or rawget(extensions, 'render_renderViews')
    logI('backup camera: render_renderViews ' .. (type(rv) == 'table' and 'loaded' or 'not available in this game version'))
  end
  if type(rv) == 'table' and type(rv.takeScreenshot) == 'function' then return rv end
  return nil
end

local function camSupported()
  return renderViews() ~= nil
end

-- Camera poses (BeamNG: x right, y forward, z up). rear = bumper looking back and down; front = nose,
-- looking ahead; left / right = side repeaters on the front fenders, looking back along the body.
local function camPose(veh, view)
  local p, d = veh:getPosition(), veh:getDirectionVector()
  local u = try(function() return veh:getDirectionVectorUp() end)
  local ux, uy, uz = 0, 0, 1
  if u and u.z then ux, uy, uz = u.x, u.y, u.z end
  local sz = sizeOf(veh)
  -- left = up x forward
  local lx, ly, lz = uy * d.z - uz * d.y, uz * d.x - ux * d.z, ux * d.y - uy * d.x
  if view == 'front' then
    local fwd = sz.l * 0.5 + 0.05
    local k = math.tan(math.rad(6))
    return vec3(p.x + d.x * fwd + ux * 1.0, p.y + d.y * fwd + uy * 1.0, p.z + d.z * fwd + uz * 1.0),
      quatFromDir(vec3(d.x - ux * k, d.y - uy * k, d.z - uz * k), vec3(ux, uy, uz))
  elseif view == 'left' or view == 'right' then
    local sgn = view == 'left' and 1 or -1
    local side, fwd = sz.w * 0.5 + 0.05, sz.l * 0.25
    local px, py, pz = p.x + d.x * fwd + lx * side * sgn + ux * 0.9, p.y + d.y * fwd + ly * side * sgn + uy * 0.9, p.z + d.z * fwd + lz * side * sgn + uz * 0.9
    return vec3(px, py, pz), quatFromDir(vec3(-d.x + lx * 0.4 * sgn, -d.y + ly * 0.4 * sgn, -d.z + lz * 0.4 * sgn), vec3(ux, uy, uz))
  end
  local back = sz.l * 0.5 + 0.12
  local px, py, pz = p.x - d.x * back + ux * 0.95, p.y - d.y * back + uy * 0.95, p.z - d.z * back + uz * 0.95
  local k = math.tan(math.rad(20))
  return vec3(px, py, pz), quatFromDir(vec3(-d.x - ux * k, -d.y - uy * k, -d.z - uz * k), vec3(ux, uy, uz))
end

local function camRealPath(rel)
  if FS and FS.getFileRealPath then
    local p = try(function() return FS:getFileRealPath(rel) end)
    if type(p) == 'string' and p ~= '' then return p end
  end
end

-- the frame asked for last time is on disk by now: tell the relay where (or send it)
local function camAnnounce(view)
  local v = cam.views[view]
  local rel = v.pending
  v.pending = nil
  if not rel then return end
  local msg = { t = 'camFrame', view = view, seq = v.seq, rel = rel, path = camRealPath(rel),
    width = cam.settings.width, height = cam.settings.height, fps = cam.settings.fps, mirrored = view == 'rear' }
  if cam.inline and readFile and mime then
    local data = try(readFile, rel)
    -- no file: still tell the relay (it counts misses and may ask for another format)
    if data then msg.data = mime.b64(data) else msg.missing = true end
  end
  send(msg)
end

-- which views want a picture right now
local function camWanted(veh)
  local w = {}
  if not veh then return w end
  if (cam.settings.backup and realTime < cam.reverseUntil) or realTime < cam.previewUntil then w.rear = true end
  if (cam.previews.front or -1) > realTime then w.front = true end
  -- side repeaters: while signaling (like a real car), or when the app asked
  local sig = lastVehSt.signal
  if cam.settings.side and (lastVehSt.speed or 0) > 0.5 then
    if sig == 'left' then w.left = true elseif sig == 'right' then w.right = true end
  end
  if (cam.previews.left or -1) > realTime then w.left = true end
  if (cam.previews.right or -1) > realTime then w.right = true end
  return w
end

local function camTick(veh)
  -- frame-rate governor: cameras are extra rendering, so they give way when the game slows down
  local scale, level, changed = cam.gov:update(realTime, fpsAvg)
  cam.scale, cam.level = scale, level
  if changed then
    relayEvent({ kind = 'notice', detail = level == 0 and 'cameras back to full rate' or (level == 3 and 'cameras paused: the game is running slowly' or 'cameras slowed to keep the frame rate up') })
  end
  local want = camWanted(veh)
  local n = 0
  for _, name in ipairs(CAM_VIEWS) do
    local v = cam.views[name]
    if want[name] then n = n + 1
    elseif v.on then
      v.on, v.pending = false, nil
      send({ t = 'camFrame', view = name, off = true })
    end
  end
  if n == 0 or scale <= 0 then return end
  if not camSupported() then
    if not cam.failed then
      cam.failed = 'render_renderViews.takeScreenshot missing (RenderViewManagerInstance: ' .. tostring(rawget(_G, 'RenderViewManagerInstance') ~= nil) .. ')'
      event('error', 'camera: ' .. cam.failed)
    end
    return
  end
  if realTime < cam.nextT then return end
  -- the rate is per view; the governor scales it, and it never asks for more than a sixth of the game's fps in total
  local perView = math.max(1, math.min(10, cam.settings.fps))
  local total = math.min(perView * n * scale, math.max(1, (fpsAvg or 30) / 6))
  cam.nextT = realTime + 1 / total
  -- next wanted view, round robin: one screenshot per tick
  local name
  for k = 1, #CAM_VIEWS do
    local cand = CAM_VIEWS[((cam.rr + k - 1) % #CAM_VIEWS) + 1]
    if want[cand] then name = cand; cam.rr = (cam.rr + k) % #CAM_VIEWS; break end
  end
  if not name then return end
  local v = cam.views[name]
  v.on = true
  camAnnounce(name)
  v.buf = 1 - v.buf
  local rel = CAM_DIR .. '/' .. name .. '_' .. (v.buf == 0 and 'a' or 'b') .. '.' .. cam.settings.format
  local ok, err = pcall(function()
    if FS and FS.directoryExists and not FS:directoryExists(CAM_DIR) then FS:directoryCreate(CAM_DIR, true) end
    local pos, rot = camPose(veh, name)
    renderViews().takeScreenshot({
      -- ONE named view, reused (a view per frame is the likely cause of the D3D11 white flash)
      renderViewName = 'teslaCam_' .. name, filename = rel,
      resolution = vec3(cam.settings.width, cam.settings.height, 0),
      pos = pos, rot = rot, fov = name == 'rear' and cam.settings.fov or 90, nearPlane = 0.05, screenshotDelay = 0.01,
    })
  end)
  if ok then
    v.seq = v.seq + 1
    v.pending = rel
    cam.failed = nil
  elseif cam.settings.format ~= 'png' then
    cam.settings.format = 'png' -- this game can't write JPEG screenshots this way: try PNG
  elseif not cam.failed then
    cam.failed = tostring(err)
    event('error', 'camera: ' .. cam.failed)
  end
end

-- wheel-button actions (mapped in the app's settings, pressed on the wheel; see relay button map)
local PROFILE_ORDER = { 'sloth', 'chill', 'standard', 'hurry', 'madmax' }
local runAction

handleCommand = function(msg)
  local t = msg.t
  if t == 'action' then return runAction(msg.name) end
  local veh = playerVehicle()
  if t == 'gear' and msg.gear == 'P' and planner and planner.mode ~= 'off' and planner.activity == 'drive'
    and not planner.pullingOver and veh and (lastVehSt.speed or 0) > 1 then
    -- P while FSD drives: pull over to the side of the road and park (take over to cancel)
    local okP = planner:pullOverNow(egoSnapshot(veh))
    if okP then relayEvent({ kind = 'pullOver', detail = 'pulling over (take over to cancel)' }); return end
  end
  if t == 'gear' and pinLocked and msg.gear ~= 'P' then
    -- PIN to Drive: nothing but Park until the app unlocks
    relayEvent({ kind = 'pinRequired', detail = 'enter the PIN to drive' })
    return
  end
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
    for k, v in pairs(msg) do if k ~= 't' and k ~= 'safety' and k ~= 'camera' then plannerSettings[k] = v end end
    if type(msg.camera) == 'table' then
      local c = msg.camera
      if c.backup ~= nil then cam.settings.backup = c.backup and true or false end
      if c.side ~= nil then cam.settings.side = c.side and true or false end
      if tonumber(c.fps) then cam.settings.fps = math.max(1, math.min(10, tonumber(c.fps))) end
      if c.quality == 'low' then cam.settings.width, cam.settings.height = 320, 180
      elseif c.quality == 'medium' then cam.settings.width, cam.settings.height = 480, 270
      elseif c.quality == 'high' then cam.settings.width, cam.settings.height = 640, 360 end
    end
    if planner then planner:configure(plannerSettings) end
    if veh then pushVehicleSettings(veh) end
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
  elseif t == 'buttonGuard' then
    if veh then ensureVehicleExtension(veh); toVehicle(veh, 'command', { t = 'guard' }) end
  elseif t == 'confirm' then
    if planner then planner:confirm(gameTime) end
  elseif t == 'climate' then
    for k, ty in pairs(CLIMATE_KEYS) do
      if msg[k] ~= nil and type(msg[k]) == ty then climateState[k] = msg[k] end
    end
    event('settings', 'climate updated')
  elseif t == 'pinLock' then
    pinLocked = msg.on and true or false
    if pinLocked and veh and (lastVehSt.speed or 0) < 1 then toVehicle(veh, 'command', { t = 'gear', gear = 'P' }) end
    event('settings', pinLocked and 'PIN to Drive: locked' or 'PIN to Drive: unlocked')
  elseif t == 'lightShow' then
    if not veh then return end
    M.startLightShow(msg.name)
  elseif t == 'arrivalChoice' then
    if not planner or not veh then return end
    local ok, err = planner:setArrival(msg.choice)
    if not ok then event('error', 'arrival: ' .. tostring(err)); return end
    if planner.mode == 'off' then
      local okP = planner:planPath(egoSnapshot(veh), trafficList())
      if okP then send(planner:routeMessage()); planner.routeDirty = false end
    end
  elseif t == 'reloadMod' then
    -- (update while playing) reload this extension and its modules from disk (needs the mod installed as an unpacked folder);
    -- the car's own extension too when asked. Done on the next frame: this extension is replaced while it is running.
    reloadRequested = { vehicle = msg.vehicle ~= false }
    relayEvent({ kind = 'notice', detail = 'reloading the Tesla bridge' })
  elseif t == 'traffic' and (tonumber(msg.count) or 0) < -1 then
    -- (debug) fan of static rays around a point (x, y from hx/hy fields): shortest hit per height; also which other ray APIs exist
    local fx, fy = tonumber(msg.x) or 0, tonumber(msg.y) or 0
    local pv = be:getPlayerVehicle(0)
    local z0 = (pv and pv:getPosition().z or 0)
    local out = { 'apis: be.castRay=' .. type(be.castRay) .. ' castRay=' .. type(rawget(_G, 'castRay')) .. ' castRayDown=' .. type(rawget(_G, 'castRayDown')) .. ' be.castRayStatic=' .. type(be.castRayStatic) }
    for _, h in ipairs({ 0.1, 0.4, 0.8, 1.4 }) do
      local best, bestA = 99, nil
      for k = 0, 15 do
        local a2 = k * math.pi / 8
        local okr, r = pcall(function() return rayFn(vec3(fx, fy, z0 + h), vec3(math.cos(a2), math.sin(a2), 0), 4) end)
        if okr and type(r) == 'number' and r < best then best, bestA = r, k end
      end
      out[#out + 1] = string.format('h%.1f: %.2f@%s', h, best, tostring(bestA))
    end
    relayEvent({ kind = 'notice', detail = 'fan ' .. table.concat(out, ' | ') })
  elseif t == 'traffic' and (tonumber(msg.count) or 0) < 0 then
    -- (debug) raw results of the ray function from the player's car in 8 directions at 3 heights
    local pv = be:getPlayerVehicle(0)
    if pv then
      local pp = pv:getPosition()
      local out = { 'rayFn=' .. tostring(rayFn ~= nil) .. ' G=' .. tostring(rawget(_G, 'castRayStatic') ~= nil) .. ' be=' .. tostring(be and be.castRayStatic ~= nil) }
      for k = 0, 7 do
        local a = k * math.pi / 4
        local row = {}
        for _, h in ipairs({ 0.2, 0.6, 1.2 }) do
          local okr, r = pcall(function() return (rayFn or function() end)(vec3(pp.x, pp.y, pp.z + h), vec3(math.cos(a), math.sin(a), 0), 20) end)
          row[#row + 1] = okr and tostring(type(r) == 'number' and string.format('%.1f', r) or r) or ('ERR ' .. tostring(r))
        end
        out[#out + 1] = k .. ':' .. table.concat(row, '/')
      end
      relayEvent({ kind = 'notice', detail = 'rayTest ' .. table.concat(out, ' ') })
    end
  elseif t == 'traffic' then
    -- (practice runner) AI cars around the player: count 0 removes them
    local okT, res = pcall(setTraffic, math.max(0, math.min(14, tonumber(msg.count) or 0)))
    relayEvent({ kind = 'notice', detail = 'traffic ' .. tostring(msg.count) .. ': ' .. tostring(okT and res or ('failed: ' .. tostring(res))) })
  elseif t == 'teleport' then
    -- (testing) put the player's car somewhere: x, y, z, heading (hx, hy)
    if not veh or not msg.x then return end
    if msg.repair then pcall(function() veh:resetBrokenFlexMesh() end) end -- (practice runner) fixes the damage first
    local ok, err = pcall(function()
      local dir = vec3(tonumber(msg.hx) or 1, tonumber(msg.hy) or 0, 0)
      if msg.flip then dir = -dir end
      local q = quatFromDir(dir, vec3(0, 0, 1))
      veh:setPositionRotation(msg.x, msg.y, msg.z or 0, q.x, q.y, q.z, q.w)
    end)
    relayEvent({ kind = 'notice', detail = 'teleport ' .. tostring(ok) .. ' ' .. tostring(err or '') })
  elseif t == 'autopark' then
    if not planner or not veh then return end
    local ego, cars = egoSnapshot(veh), trafficList()
    if msg.spot then
      -- a spot tapped on the map
      local ok, err, how = planner:parkAtSpot(tonumber(msg.spot), ego, cars)
      if not ok then event('error', 'autopark: ' .. tostring(err)); return end
      if how == 'route' and planner.mode == 'off' then
        -- a spot that is not right here: FSD drives to it (before, the route was drawn and the car just sat there)
        ensureVehicleExtension(veh)
        local okE, errE = planner:engage('fsd', (planner.mode == 'fsd' and planner.profile) or 'standard', ego, cars)
        if not okE then
          planner.dest, planner.arrival, planner.chosenSpot = nil, nil, nil
          event('error', 'autopark: ' .. tostring(errE))
          return
        end
        send(planner:routeMessage()); planner.routeDirty = false
      end
      relayEvent({ kind = 'autopark', detail = how == 'now' and 'parking now' or 'parking at destination' })
    else
      local ok, err = planner:autopark(ego, cars)
      if not ok then
        -- none right beside the car: choose the nearest free spot nearby and drive there (FSD engages if it was off)
        local id = planner:nearestFreeSpot(ego, cars, 400)
        local okS, errS, how = false, err, nil
        if id then okS, errS, how = planner:parkAtSpot(id, ego, cars) end
        if okS and how == 'route' then
          ensureVehicleExtension(veh)
          if planner.mode == 'off' then
            local okE, errE = planner:engage('fsd', (planner.mode == 'fsd' and planner.profile) or 'standard', ego, cars)
            if not okE then planner.dest, planner.arrival, planner.chosenSpot = nil, nil, nil; okS, errS = false, errE end
          end
          if okS then send(planner:routeMessage()); planner.routeDirty = false; relayEvent({ kind = 'autopark', detail = 'parking at the nearest spot' }) end
        elseif okS then
          relayEvent({ kind = 'autopark', detail = 'parking now' })
        end
        if not okS then event('error', 'autopark: ' .. tostring(errS)) end
      end
    end
    -- a parking trip the driver just asked for needs no second "press the brake to confirm" (the car used to shift out of Park and sit)
    if planner.mode ~= 'off' then pcall(function() planner:confirm(gameTime) end) end
    syncVehicleMode(veh)
  elseif t == 'summonTo' or t == 'banish' then
    -- Smart Summon: the car drives to a point you picked on the phone's map and stops there (P). Banish: it drives off by itself to the
    -- nearest free parking spot (up to 400 m) and parks, remembering where it was so "come back" can fetch it. No driver needed.
    if not planner or not veh then event('error', t .. ': no car'); return end
    local ego, cars = egoSnapshot(veh), trafficList()
    ensureVehicleExtension(veh)
    if t == 'banish' then
      local id = planner:nearestFreeSpot(ego, cars, 400)
      if not id then event('error', 'banish: no free parking spot within 400 m'); return end
      local ok, err, how = planner:parkAtSpot(id, ego, cars)
      if not ok then event('error', 'banish: ' .. tostring(err)); return end
      banishedFrom = { ego.x, ego.y, ego.z or 0 }
      if planner.mode == 'off' then
        local okE, errE = planner:engage('fsd', 'standard', ego, cars)
        if not okE then planner.dest, planner.arrival, planner.chosenSpot = nil, nil, nil; event('error', 'banish: ' .. tostring(errE)); return end
      end
      pcall(function() planner:confirm(gameTime) end) -- nobody is in the car to press the brake for Brake Confirm
      send(planner:routeMessage()); planner.routeDirty = false
      relayEvent({ kind = 'banish', detail = 'parking by itself' })
    else
      local to = msg.back and banishedFrom or (type(msg.to) == 'table' and { tonumber(msg.to[1]), tonumber(msg.to[2]), tonumber(msg.to[3]) or ego.z or 0 } or nil)
      if not to or not to[1] or not to[2] then event('error', 'summon: no place to come to'); return end
      planner:setRoute(to, nil, 'Pull Over')
      local okE, errE = true, nil
      if planner.mode == 'off' then okE, errE = planner:engage('fsd', 'standard', ego, cars) else planner.routeDirty = true end
      if not okE then planner.dest, planner.arrival = nil, nil; event('error', 'summon: ' .. tostring(errE)); return end
      pcall(function() planner:confirm(gameTime) end) -- nobody is in the car to press the brake for Brake Confirm
      send(planner:routeMessage()); planner.routeDirty = false
      relayEvent({ kind = 'summonTo', detail = 'coming to you' })
    end
    syncVehicleMode(veh)
  elseif t == 'emergencyStop' then
    if not planner or not veh then event('error', 'emergency: no car'); return end
    if msg.cancel then
      planner:cancelEmergency()
    else
      ensureVehicleExtension(veh)
      local ok, err = planner:emergencyStop(egoSnapshot(veh), trafficList())
      if not ok then event('error', 'emergency: ' .. tostring(err)); return end
      syncVehicleMode(veh)
      planTick()
    end
  elseif t == 'requestParkingSpots' then
    if not planner then return end
    local ego = veh and egoSnapshot(veh)
    local near = type(msg.near) == 'table' and msg.near or (ego and { ego.x, ego.y }) or nil
    if not near then return end
    send(parkingSpotsMsg(near[1], near[2], tonumber(msg.radius) or 80))
  elseif t == 'camera' then
    -- { on = true } shows the backup camera for 15 s (a preview button); { inline = true } comes
    -- from the relay when it can't read the frames from disk itself
    if msg.inline ~= nil then cam.inline = msg.inline and true or false end
    if msg.format == 'png' or msg.format == 'jpg' then cam.settings.format = msg.format end
    local pv = msg.view
    if pv == 'front' or pv == 'left' or pv == 'right' then
      if msg.on == true then cam.previews[pv] = realTime + 15 elseif msg.on == false then cam.previews[pv] = -1 end
    elseif msg.on == true then cam.previewUntil = realTime + 15
    elseif msg.on == false then cam.previewUntil = -1 end
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

-- Lane Keep Assist on/off (a wheel button or the app's Settings); the app learns about it from the 'settings' event
function M.toggleLaneKeep()
  safetySettings.lka = not (safetySettings.lka == true)
  safety:configure(safetySettings)
  send({ t = 'event', kind = 'settings', detail = 'laneKeep ' .. (safetySettings.lka and 'on' or 'off'), data = { lka = safetySettings.lka } })
end

local function stepProfile(dir)
  if not planner then return end
  local i = 3
  for k, p in ipairs(PROFILE_ORDER) do if p == planner.profile then i = k end end
  if planner.profile == 'furious' then i = #PROFILE_ORDER end -- above Mad Max; the dial steps down to it
  local p = PROFILE_ORDER[math.max(1, math.min(#PROFILE_ORDER, i + dir))]
  planner:setProfile(p)
  event('settings', 'profile ' .. p)
end

runAction = function(name)
  local mode = planner and planner.mode or 'off'
  if name == 'toggleFSD' then M.toggleAutopilot('fsd')
  elseif name == 'toggleAutosteer' then M.toggleAutopilot('autosteer')
  elseif name == 'toggleTACC' then M.toggleAutopilot('tacc')
  elseif name == 'toggleLKA' then M.toggleLaneKeep()
  elseif name == 'disengage' then handleCommand({ t = 'autopilot', mode = 'off' })
  elseif name == 'voiceNote' then M.voiceNote()
  elseif name == 'nudge' then M.nudge()
  elseif name == 'laneLeft' or name == 'laneRight' then
    local dir = name == 'laneLeft' and 'left' or 'right'
    -- the paddles: with FSD / Autosteer it asks for that turn / lane change; otherwise it is a normal stalk (press again = off)
    local fsdOn = planner and (planner.mode == 'fsd' or planner.mode == 'autosteer')
    if not fsdOn and lastVehSt and lastVehSt.signal == dir then dir = nil end
    handleCommand({ t = 'signal', dir = dir })
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
  elseif name == 'confirm' then handleCommand({ t = 'confirm' })
  elseif name == 'autopark' then handleCommand({ t = 'autopark' })
  elseif name == 'park' then handleCommand({ t = 'gear', gear = 'P' })
  elseif name == 'summonForward' then handleCommand({ t = 'summon', dir = 'forward' })
  elseif name == 'summonReverse' then handleCommand({ t = 'summon', dir = 'reverse' })
  elseif name == 'summonStop' then handleCommand({ t = 'summon', dir = nil })
  else event('error', 'unknown action ' .. tostring(name)) end
end

-- Bound to "Tesla: voice note": the app starts/stops recording a note for later.
function M.voiceNote()
  send({ t = 'event', kind = 'voiceNote', detail = 'toggle', data = { lastDisengage = planner and planner.lastDisengage or nil } })
end

-- (practice runner) AI traffic around the player's car: `count` cars spawned on the road graph 70-250 m away that drive on their own.
local trafficIds = {}
local TRAFFIC_MODELS = { 'vivace', 'sunburst2', 'etk800', 'pickup', 'roamer', 'miramar', 'legran', 'bx', 'covet' }
local function clearTraffic()
  for _, id in ipairs(trafficIds) do
    local o = be and be.getObjectByID and be:getObjectByID(id)
    if o then pcall(function() o:delete() end) end
  end
  trafficIds = {}
end
setTraffic = function(count)
  clearTraffic()
  if count <= 0 then return 'cleared' end
  local pv = be:getPlayerVehicle(0)
  if not pv or not graph or not graph.nodes then return 'no car or no road graph' end
  local pp = pv:getPosition()
  local cands = {}
  for id, n in pairs(graph.nodes) do
    local d = math.sqrt((n.x - pp.x) ^ 2 + (n.y - pp.y) ^ 2)
    if d > 70 and d < 250 then cands[#cands + 1] = n end
  end
  if #cands == 0 then return 'no road nodes nearby' end
  local made = 0
  for _ = 1, count do
    local n = cands[math.random(#cands)]
    local model = TRAFFIC_MODELS[math.random(#TRAFFIC_MODELS)]
    local ang = math.random() * 6.283
    local q = quatFromDir(vec3(math.cos(ang), math.sin(ang), 0), vec3(0, 0, 1))
    local ok, v = pcall(function()
      return core_vehicles.spawnNewVehicle(model, { pos = vec3(n.x, n.y, n.z + 0.5), rot = q, autoEnterVeh = false, cling = true })
    end)
    if ok and v then
      trafficIds[#trafficIds + 1] = v:getID()
      v:queueLuaCommand("if ai then ai.setMode('traffic') end")
      made = made + 1
    end
  end
  -- make sure the player stays in their own car
  pcall(function() be:enterVehicle(0, pv) end)
  return 'spawned ' .. made
end

-- The G29 paddles (bound to "Tesla: paddle left / right"): the turn signal; with FSD it asks for that turn / lane change.
function M.paddle(dir)
  if dir == 'left' then runAction('laneLeft') else runAction('laneRight') end
end

-- The G29 red dial (bound to "Tesla: dial up / down / click"): volume by default, its button cycles what it controls.
-- Volume goes to the app as a wheelMedia event (the iPad's music), the rest to the planner like the wheel-button actions.
local DIAL_MODES = { 'volume', 'distance', 'speed', 'profile' }
local dialIdx = 1
local DIAL_ACTIONS = { volume = { 'volumeUp', 'volumeDown' }, distance = { 'followFarther', 'followCloser' }, speed = { 'speedUp', 'speedDown' }, profile = { 'profileNext', 'profilePrev' } }
function M.dial(kind)
  if kind == 'click' then
    dialIdx = dialIdx % #DIAL_MODES + 1
    send({ t = 'event', kind = 'wheelDial', detail = DIAL_MODES[dialIdx], data = { mode = DIAL_MODES[dialIdx] } })
    return
  end
  local mode = DIAL_MODES[dialIdx]
  local act = DIAL_ACTIONS[mode][kind == 'up' and 1 or 2]
  send({ t = 'event', kind = 'wheelDial', detail = mode, data = { mode = mode, dir = kind } })
  if mode == 'volume' then send({ t = 'event', kind = 'wheelMedia', detail = act, data = { action = act } })
  else runAction(act) end
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
    planner = planner and {
      dest = planner.dest and { planner.dest[1], planner.dest[2] } or nil, arrived = planner.arrived, arrival = planner.arrival,
      openEnded = planner.path and planner.path.openEnded or nil, pathPoints = planner.path and #planner.path.pts or nil,
      pathLength = planner.path and planner.path.s and planner.path.s[#planner.path.s] or nil, activity = planner.activity,
      hint = planner.hint, status = plannerStatus and { remaining = plannerStatus.remaining, targetSpeed = plannerStatus.targetSpeed, leadGap = plannerStatus.leadGap, waitingFor = plannerStatus.waitingFor } or nil,
      lastPlan = planner.lastPlanInfo,
    } or nil,
    relayQueue2 = outBytes,
    weather = weather, weatherProbe = weatherProbe, raycast = rayFn ~= nil, overhead = overhead,
    beacons = 0, emergencyNow = 0,
    camera = { supported = camSupported(), realPath = FS ~= nil and FS.getFileRealPath ~= nil, on = cam.views.rear.on, seq = cam.views.rear.seq, level = cam.level, scale = cam.scale, views = (function() local o = {} for _, n in ipairs(CAM_VIEWS) do if cam.views[n].on then o[#o + 1] = n end end return o end)(),
      inline = cam.inline, failed = cam.failed, settings = cam.settings } }
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
  -- the raw state names and types this game version uses (for fixing the mapping)
  local raws, types = {}, {}
  for _, sg in ipairs(signals) do
    if sg.get then sg.get() end
    if sg.raw and not raws[sg.raw] then raws[sg.raw] = true; raws[#raws + 1] = sg.raw end
    if sg.type and not types[sg.type] then types[sg.type] = true; types[#types + 1] = sg.type end
    if #raws > 12 and #types > 12 then break end
  end
  d.signalStates = { raw = { unpack(raws, 1, 12) }, types = { unpack(types, 1, 12) } }
  -- which way BeamNG's signal dir points, learned from this level (1 = travel direction,
  -- -1 = facing the driver, nil = not enough signals to tell)
  if planner then d.signalStates.dirConvention = planner:signalDirConvention() end
  if planner then d.nag = planner.nag:status() end
  return d
end

---------------------------------------------------------------------------
-- hooks
---------------------------------------------------------------------------

local bindingsRefreshAt -- seconds left until the second bindings refresh (set when the extension loads)
local refreshBindings
local function doReload()
  local req = reloadRequested
  reloadRequested = nil
  -- forget the modules so they are read from disk again
  for k in pairs(package.loaded) do
    if type(k) == 'string' and k:find('^teslaBridge/') then package.loaded[k] = nil end
  end
  if req and req.vehicle then
    local veh = be and be.getPlayerVehicle and be:getPlayerVehicle(0)
    if veh then veh:queueLuaCommand("package.loaded['teslaBridge/control'] = nil; package.loaded['teslaBridge/wheel'] = nil; package.loaded['teslaBridge/nag'] = nil; package.loaded['teslaBridge/pathing'] = nil; package.loaded['teslaBridge/safety'] = nil; extensions.reload('teslaAutopilot')") end
  end
  local ok, err = pcall(function()
    if core_jobsystem and core_jobsystem.create then
      -- from a job: this extension is replaced while its own code is on the stack otherwise
      core_jobsystem.create(function(job)
        job.sleep(0.15)
        extensions.unload('teslaBridge')
        job.sleep(0.15)
        extensions.load('teslaBridge')
      end, 1)
    elseif extensions and extensions.reload then
      extensions.reload('teslaBridge')
    end
  end)
  logI('reload requested: ' .. tostring(ok) .. ' ' .. tostring(err))
end

-- ---------------------------------------------------------------------------------------------------------------------
-- Remote start (see launchreq.lua): the PC's launcher service writes settings/teslaBridgeLaunch.json before it starts the
-- game. We read it while the game starts up, load the level and swap in the car it asks for, then delete it. We also keep
-- teslaBridgeLast.json (what you were playing: "resume") and teslaBridgeCatalog.json (the levels and cars the game has: the
-- choices for "new world and car"). All best effort and logged; none of it can stop the bridge.
local LAUNCH_FILE, LAST_FILE, CATALOG_FILE = '/settings/teslaBridgeLaunch.json', '/settings/teslaBridgeLast.json', '/settings/teslaBridgeCatalog.json'
local launchPlan, launchPoll, launchLevelStarted, launchCarDone, launchWaitT = nil, 0, false, false, nil
local launchGiveUp = 300 -- stop looking for a request this long after the game started (s)
local catalogDone, lastSavedKey = false, nil

local function removeFile(path)
  if FS and FS.removeFile then try(function() FS:removeFile(path) end) end
  if jsonWriteFile then try(jsonWriteFile, path, { consumed = true }, true) end -- if the file could not be deleted, blank it
end

local function launchTick(dtReal)
  if launchPlan == nil and realTime < launchGiveUp then
    launchPoll = launchPoll - dtReal
    if launchPoll <= 0 then
      launchPoll = 2
      local req = jsonReadFile and try(jsonReadFile, LAUNCH_FILE) or nil
      if type(req) == 'table' and req.ts then
        local plan, why = Lq.parse(req, os.time())
        removeFile(LAUNCH_FILE)
        if plan then
          launchPlan = plan
          if plan.mode == 'resume' and not plan.level then
            local last = jsonReadFile and try(jsonReadFile, LAST_FILE) or nil
            if type(last) == 'table' then plan.level, plan.vehicle, plan.config = last.level, last.vehicle, last.config end
          end
          logI('remote start: ' .. plan.mode .. ' level=' .. tostring(plan.level) .. ' car=' .. tostring(plan.vehicle))
        else
          launchPlan = false
          logI('remote start request ignored: ' .. tostring(why))
        end
      end
    end
  end
  if not launchPlan then return end
  -- 1. load the level (only from the menu: if the game already loaded one, leave it)
  if launchPlan.level and not launchLevelStarted and not levelName() and realTime > 6 then
    launchLevelStarted = true
    local file = Lq.levelFile(launchPlan.level)
    local okStart = false
    if file and freeroam_freeroam and freeroam_freeroam.startFreeroam then okStart = pcall(freeroam_freeroam.startFreeroam, file) end
    if not okStart and file and core_levels and core_levels.startLevel then okStart = pcall(core_levels.startLevel, file) end
    logI('remote start: loading ' .. tostring(file) .. (okStart and '' or ' (FAILED: no level loader found)'))
  end
  -- 2. swap in the car, a few seconds after the level is up
  if launchPlan.vehicle and not launchCarDone and levelName() then
    launchWaitT = (launchWaitT or 0) + dtReal
    if launchWaitT > 6 and playerVehicle() then
      launchCarDone = true
      local opts = {}
      if launchPlan.config and core_vehicles and core_vehicles.getModel then
        opts.config = '/vehicles/' .. launchPlan.vehicle .. '/' .. launchPlan.config .. '.pc'
      end
      local ok = false
      if core_vehicles and core_vehicles.replaceVehicle then ok = pcall(core_vehicles.replaceVehicle, launchPlan.vehicle, opts) end
      if not ok and core_vehicles and core_vehicles.spawnNewVehicle then ok = pcall(core_vehicles.spawnNewVehicle, launchPlan.vehicle, opts) end
      logI('remote start: car ' .. launchPlan.vehicle .. (ok and ' placed' or ' (FAILED)'))
    end
  end
end

-- remember what is being played (called when a level finishes loading and when the player's car changes)
local function saveLastSession()
  if not jsonWriteFile then return end
  local pv = playerVehicle()
  local model = pv and try(function() return pv:getJBeamFilename() end) or nil
  local name = model and core_vehicles and core_vehicles.getModel and try(function()
    local md = core_vehicles.getModel(model)
    return md and md.model and md.model.Name
  end) or nil
  local last = Lq.last(levelName(), model, nil, name)
  if not last then return end
  local key = tostring(last.level) .. '|' .. tostring(last.vehicle)
  if key == lastSavedKey then return end
  lastSavedKey = key
  try(jsonWriteFile, LAST_FILE, last, true)
end

-- the levels and cars the game knows (mods included), for the "new world and car" pickers
local function saveCatalog()
  if catalogDone or not jsonWriteFile or not core_levels or not core_vehicles then return end
  catalogDone = true
  local levels = Lq.levels(try(core_levels.getList))
  local cars = Lq.vehicles(try(core_vehicles.getModelList))
  if #levels > 0 or #cars > 0 then
    try(jsonWriteFile, CATALOG_FILE, { v = 1, levels = levels, vehicles = cars, ts = os.time() }, true)
    logI('catalog: ' .. #levels .. ' levels, ' .. #cars .. ' cars')
  else
    catalogDone = false -- not ready yet, try again later
  end
end

-- The road ahead for the app's driving view while nobody is driving a route (manual driving, FSD off): the street the
-- car is on, followed along the level's road graph. Sent as a normal 'route' message flagged passive, about once a second
-- while moving, and never when the planner has its own path (FSD or a navigate pin), so it can't fight the real one.
local lookAt, lookSent = 0, false
local function lookAheadTick()
  if not (planner and graph and playerId) or realTime < lookAt then return end
  local veh = vehicleById(playerId)
  if not veh then return end
  if planner.mode ~= 'off' or planner.path or planner.dest then lookSent = false; return end
  local ego = egoSnapshot(veh)
  lookAt = realTime + ((ego.v or 0) > 1 and 1 or 3)
  local rt = P.followRoad(graph, ego.x, ego.y, ego.hx, ego.hy, 300, nil)
  if not rt then
    if lookSent then send({ t = 'route', points = {}, length = 0 }); lookSent = false end
    return
  end
  local path = P.buildPath(graph, rt)
  local pts = {}
  for i = 1, #path.pts, math.max(1, math.floor(#path.pts / 120)) do local q = path.pts[i]; pts[#pts + 1] = { q.x, q.y, q.z or 0 } end
  local q = path.pts[#path.pts]
  pts[#pts + 1] = { q.x, q.y, q.z or 0 }
  send({ t = 'route', points = pts, length = path.s[#path.s], openEnded = true, passive = true })
  lookSent = true
end

local function onUpdate(dtReal, dtSim)
  dtReal = dtReal or 0
  realTime = realTime + dtReal
  if reloadRequested then pcall(doReload); return end
  if bindingsRefreshAt then
    bindingsRefreshAt = bindingsRefreshAt - dtReal
    if bindingsRefreshAt <= 0 then bindingsRefreshAt = nil; if refreshBindings then refreshBindings() end end
  end
  gameTime = gameTime + (dtSim or dtReal)
  pcall(launchTick, dtReal)
  pcall(lookAheadTick)
  if not catalogDone and realTime > 8 and realTime % 5 < dtReal then pcall(saveCatalog) end
  if dtReal > 0 then fpsAvg = fpsAvg + (1 / dtReal - fpsAvg) * 0.05 end
  local okNet, netErr = pcall(netUpdate)
  if not okNet and realTime >= netErrLogAt then
    -- a network bug must not flood the log every frame
    logW('network update failed: ' .. tostring(netErr))
    netErrLogAt = realTime + 10
  end

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
      pcall(pushVehicleSettings, veh)
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
      pcall(saveLastSession)
    end
  end

  pcall(camTick, veh)

  if realTime >= tWeather then
    tWeather = realTime + 2
    pcall(sampleWeather)
  end

  if show and realTime >= tShow then
    tShow = realTime + 0.1
    pcall(lightShowTick, veh)
  end

  if realTime >= tAids then
    tAids = realTime + 0.5
    local okD, errD = pcall(driveAidsTick, veh)
    if not okD then logW('drive aids: ' .. tostring(errD)) end
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
  send({ t = 'route', points = {}, length = 0 }) -- the old level's route is meaningless now
  mapPending = true
  tMapPoll = realTime + 2 -- the road graph is built a moment after the level starts
  traffic, vehSize, beacons, beaconLoaded, vehNames = {}, {}, {}, {}, {}
  sentMode = 'off'
end

local function onClientEndMission()
  event('levelUnloaded', level or '')
  mapMsg, graph, level, planner = nil, nil, nil, nil
  send({ t = 'route', points = {}, length = 0 }) -- the old level's route is meaningless now
  traffic, vehSize, beacons, beaconLoaded, vehNames = {}, {}, {}, {}, {}
  sentMode = 'off'
end

local function onVehicleSpawned(vid)
  local veh = vehicleById(vid)
  local pv = playerVehicle()
  if veh and pv and pv:getID() == vid then ensureVehicleExtension(veh, true); pcall(saveLastSession) end
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

local LEARN_FILE = '/settings/teslaBridgeLearn.json'
loadLearn = function()
  local data = jsonReadFile and try(jsonReadFile, LEARN_FILE) or nil
  learn = Lr.new(type(data) == 'table' and data or nil)
end
saveLearn = function()
  if learn and learn.dirty and jsonWriteFile then
    learn.dirty = false
    try(jsonWriteFile, LEARN_FILE, learn:export(), true)
  end
end

-- BeamNG reads the wheel's bindings (settings/inputmaps) at start, before this mod is mounted, so our actions (the FSD button,
-- the paddles, the red dial) did not exist yet and their bindings were dropped. Ask it to read them again now that they do.
refreshBindings = function()
  pcall(function()
    if core_input_bindings and core_input_bindings.onFileChanged then core_input_bindings.onFileChanged('/settings/inputmaps/c24f046d.diff', 0) end
  end)
end

local function onExtensionLoaded()
  logI('loaded (v2) ' .. tostring(os.time()))
  loadLearn()
  if levelName() then mapPending = true end
  refreshBindings()
  bindingsRefreshAt = 4 -- and once more a few seconds later (seconds of game time from the first update)
end

local function onExtensionUnloaded()
  saveLearn()
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
