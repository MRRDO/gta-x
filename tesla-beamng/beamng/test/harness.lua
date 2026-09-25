-- A tiny fake BeamNG: runs the real mod Lua (GE extension + vehicle extension)
-- in two separate environments with stubbed game APIs and a bicycle-model car,
-- and serves the real TCP port so the real relay can connect.
--
--   luajit beamng/test/harness.lua            (from tesla-beamng/, needs lua-socket + lua-dkjson)
--   HARNESS_SPEED=4  run the sim 4x faster than real time (default 4)
--   HARNESS_SECONDS  stop after this many game seconds (default: run forever)
--
-- What it can't tell you: whether the stubbed API names match the real game.
-- That's what the in-game `debug` command is for.

package.path = 'beamng/mod/lua/common/?.lua;/usr/share/lua/5.1/?.lua;/usr/share/lua/5.1/?/init.lua;' .. package.path
package.cpath = package.cpath .. ';/usr/lib/x86_64-linux-gnu/lua/5.1/?.so'

local json = require('dkjson')
local socket = require('socket')
local mime = require('mime')

local SPEED = tonumber(os.getenv('HARNESS_SPEED') or '4')
local MAX_T = tonumber(os.getenv('HARNESS_SECONDS') or '0')
local QUIET = os.getenv('HARNESS_QUIET') == '1'
local TRUE_SIGN = tonumber(os.getenv('HARNESS_STEER_SIGN') or '1') -- +1: positive input steers right
local FFB_SIGN = tonumber(os.getenv('HARNESS_FFB_SIGN') or '1')     -- -1: wheel motor wired backwards
local NO_WHEEL = os.getenv('HARNESS_NO_WHEEL') == '1'

local gameT = 0
local function hlog(...) if not QUIET then print(string.format('[harness %6.1f]', gameT), ...) end end

local function jsonEncode(t) return json.encode(t) end
local function jsonDecode(s) return json.decode(s) end

---------------------------------------------------------------------------
-- world: a 5x5 city grid, 150 m blocks, like the unit tests
---------------------------------------------------------------------------

local mapNodes = {}
do
  local B = 150
  for i = 0, 4 do
    for j = 0, 4 do
      mapNodes[i .. '_' .. j] = { pos = { x = i * B, y = j * B, z = 0 }, radius = 5, links = {} }
    end
  end
  for i = 0, 4 do
    for j = 0, 4 do
      local id = i .. '_' .. j
      if i < 4 then mapNodes[id].links[(i + 1) .. '_' .. j] = { drivability = 1, oneWay = false, speedLimit = 13.4 } end
      if j < 4 then mapNodes[id].links[i .. '_' .. (j + 1)] = { drivability = 1, oneWay = false } end
    end
  end
end

-- traffic light at the east end of the first long block, stop sign at the first junction
-- red until the player has waited at it for 3 s, then green
local lightGreen, waitedAtLight = false, 0
local function lightState()
  return lightGreen and 'greenTrafficLight' or 'redTrafficLight'
end
local signalInstances = {
  { name = 'stop_1_0', pos = { x = 146, y = -7, z = 0 }, dir = { x = 1, y = 0, z = 0 }, signalType = 'stopSign' },
  { name = 'light_2_0', pos = { x = 296, y = -7, z = 0 }, dir = { x = 1, y = 0, z = 0 }, signalType = 'trafficLight',
    getState = function() return lightState() end },
}

---------------------------------------------------------------------------
-- vehicles
---------------------------------------------------------------------------

local geQueue, vehQueue = {}, {}

local function newCar(id, x, y, psi)
  return { id = id, x = x, y = y, psi = psi, v = 0, delta = 0, wb = 2.9, ref = 1.4, dmax = math.rad(34), arcadeStill = 0 }
end

local player = newCar(1001, 10, -1.8, 0)
local lead = newCar(2002, 70, -1.8, 0)
lead.v = 6

local function refPos(c)
  return c.x + math.cos(c.psi) * c.ref, c.y + math.sin(c.psi) * c.ref
end

local function geVehicle(c, isPlayer)
  local o = {}
  function o:getID() return c.id end
  function o:getPosition() local x, y = refPos(c); return { x = x, y = y, z = 0 } end
  function o:getDirectionVector() return { x = math.cos(c.psi), y = math.sin(c.psi), z = 0 } end
  function o:getVelocity() return { x = math.cos(c.psi) * c.v, y = math.sin(c.psi) * c.v, z = 0 } end
  function o:getJBeamFilename() return isPlayer and 'harness_sedan' or 'harness_truck' end
  function o:getSpawnWorldOOBB() return { getHalfExtents = function() return { x = 2.4, y = 0.95, z = 0.7 } end } end
  function o:queueLuaCommand(code) if isPlayer then vehQueue[#vehQueue + 1] = code end end
  return o
end
local playerObj, leadObj = geVehicle(player, true), geVehicle(lead, false)

---------------------------------------------------------------------------
-- vehicle VM
---------------------------------------------------------------------------

-- a Logitech G29: 900 deg, ~2.1 Nm at full force, gear friction
WHEEL = { p = 0, w = 0, J = 0.03, fric = 0.12, tmax = 2.1, force = 0, lastSent = nil, hand = nil }
local RAD_PER_RAW = math.rad(450)

local V = setmetatable({}, { __index = _G })
V._G = V
local vehExtensions = {}
do
  local e = {
    gear = 'P', gearIndex = 1, gearboxMode = 'arcade', lights_state = 0, lowbeam = 0, highbeam = 0, fog = 0,
    signal_left_input = 0, signal_right_input = 0, hazard_enabled = 0, fuel = 0.8, wheelspeed = 0,
    steering = 0, steering_input = 0, throttle_input = 0, brake_input = 0, parkingbrake_input = 0, horn = 0,
    throttle = 0, brake = 0,
  }
  V.electrics = {
    values = e,
    setLightsState = function(n) e.lights_state = n; e.lowbeam = n >= 1 and 1 or 0; e.highbeam = n == 2 and 1 or 0 end,
    set_fog_lights = function(v) e.fog = (v == true or v == 1) and 1 or 0 end,
    set_warn_signal = function(v)
      e.signal_left_input, e.signal_right_input = 0, 0
      e.hazard_enabled = (v == 1 or v == true) and 1 or 0
      if e.hazard_enabled == 1 then e.signal_left_input, e.signal_right_input = 1, 1 end
    end,
    toggle_left_signal = function() e.hazard_enabled = 0; e.signal_right_input = 0; e.signal_left_input = 1 - e.signal_left_input end,
    toggle_right_signal = function() e.hazard_enabled = 0; e.signal_left_input = 0; e.signal_right_input = 1 - e.signal_right_input end,
    horn = function(on) e.horn = on and 1 or 0 end,
  }
  local input = { state = {}, allowed = {} }
  function input.event(itype, val, filter, a4, a5, a6, source)
    source = source or 'local'
    local al = input.allowed[itype]
    if al and al[source] == false then return end
    input.state[itype] = { val = val, source = source }
    e[itype .. '_input'] = val
  end
  function input.setAllowedInputSource(itype, source, allowed)
    input.allowed[itype] = input.allowed[itype] or {}
    input.allowed[itype][source] = allowed
  end
  V.input = input
  V.FILTER_DIRECT = 2
  local GEARS = { [-1] = 'R', [0] = 'N', [1] = 'P', [2] = 'D' }
  local main = {
    shiftToGearIndex = function(i) if GEARS[i] then e.gear = GEARS[i]; e.gearIndex = i end end,
    setGearboxMode = function(m) e.gearboxMode = m end,
  }
  local doors = {
    { name = 'doorFLCoupler', open = false }, { name = 'doorFRCoupler', open = false }, { name = 'tailgateCoupler', open = false },
  }
  for _, d in ipairs(doors) do
    d.getGroupState = function() return d.open and 'detached' or 'attached' end
    d.toggleGroup = function() d.open = not d.open end
  end
  V.controller = {
    mainController = main,
    getControllersByType = function(t) if t == 'advancedCouplerControl' then return doors end return {} end,
  }
  local gearbox = { type = 'automaticGearbox' }
  V.powertrain = {
    getDevice = function(n) if n == 'gearbox' then return gearbox end end,
    getDevices = function() return { gearbox = gearbox } end,
  }
  V.v = { data = { input = { steeringWheelLock = 450 } } }
  -- the game's FFB owner, shaped like hydros.lua: FFBID/FFmax are locals, and
  -- update() sends a centering force every physics step while FFBID >= 0
  local FFBID = NO_WHEEL and -1 or 7
  local FFmax = 10
  V.hydros = { enableFFB = true, wheelFFBForceLimit = 2 }
  -- HARNESS_FFB_SIGN models our guess of the motor direction being wrong; the game's own
  -- forces are always right (the player set the wheel up for the game)
  V.hydros.update = function()
    WHEEL.fromGame = true
    if FFBID >= 0 and FFmax > 0 then V.obj:sendForceFeedback(FFBID, math.max(-FFmax, math.min(FFmax, -(4 + 1.2 * math.abs(player.v)) * WHEEL.p))) end -- self-centering grows with speed
    WHEEL.fromGame = false
  end
  V.hydros.onFFBConfigChanged = function(cfg) FFBID = cfg and cfg.steering and cfg.steering.FFBID or -1 end
  V.jsonEncode, V.jsonDecode = jsonEncode, jsonDecode
  V.log = function(l, tag, msg) hlog('veh', l, tag, msg) end
  V.obj = {
    getID = function() return player.id end,
    getPositionXYZ = function() local x, y = refPos(player); return x, y, 0 end,
    getDirectionVectorXYZ = function() return math.cos(player.psi), math.sin(player.psi), 0 end,
    getVelocityXYZ = function() return math.cos(player.psi) * player.v, math.sin(player.psi) * player.v, 0 end,
    queueGameEngineLua = function(_, code) geQueue[#geQueue + 1] = code end,
    sendForceFeedback = function(_, id, force) if id == 7 then WHEEL.force = WHEEL.fromGame and force * FFB_SIGN or force end end,
  }
  -- obj methods are called with ':' so shift the arguments
  for k, f in pairs(V.obj) do
    if k ~= 'queueGameEngineLua' and k ~= 'sendForceFeedback' then V.obj[k] = function(_, ...) return f(...) end end
  end
  V.extensions = {
    load = function(name)
      if vehExtensions[name] then return end
      local chunk = assert(loadfile('beamng/mod/lua/vehicle/extensions/' .. name .. '.lua'))
      setfenv(chunk, V)
      local m = chunk()
      vehExtensions[name] = m
      V[name] = m
      if m.onExtensionLoaded then m.onExtensionLoaded() end
      hlog('vehicle extension loaded: ' .. name)
    end,
  }
end

---------------------------------------------------------------------------
-- GE VM
---------------------------------------------------------------------------

local G = setmetatable({}, { __index = _G })
G._G = G
G.jsonEncode, G.jsonDecode = jsonEncode, jsonDecode
G.mime = mime
G.beamng_versionb = 'harness'
G.log = function(l, tag, msg) hlog('ge', l, tag, msg) end
G.getPlayerVehicle = function() return playerObj end
G.getAllVehicles = function() return { playerObj, leadObj } end
G.getObjectByID = function(id) if id == player.id then return playerObj elseif id == lead.id then return leadObj end end
G.getMissionFilename = function() return '/levels/harness_city/main.level.json' end
G.map = { getMap = function() return { nodes = mapNodes } end }
G.core_trafficSignals = { getSignalsDict = function() return { instances = signalInstances } end }
G.scenetree = { findClassObjects = function() return {} end, findObject = function() return nil end }
G.jsonReadFile = function() return nil end
G.readFile = function() return nil end
G.core_vehicles = { getModel = function(jb) return { model = { Brand = 'Harness', Name = jb == 'harness_sedan' and 'Sedan' or 'Truck' } } end }

local geChunk = assert(loadfile('beamng/mod/lua/ge/extensions/teslaBridge.lua'))
setfenv(geChunk, G)
local teslaBridge = geChunk()
G.teslaBridge = teslaBridge
teslaBridge.onExtensionLoaded()

local function runQueued(q, env, label)
  local items = {}
  for i = 1, #q do items[i] = q[i]; q[i] = nil end
  for _, code in ipairs(items) do
    local chunk, err = loadstring(code)
    if not chunk then error(label .. ' queued code did not compile: ' .. tostring(err) .. '\n' .. code:sub(1, 200)) end
    setfenv(chunk, env)
    local ok, e = pcall(chunk)
    if not ok then error(label .. ' queued code failed: ' .. tostring(e) .. '\n' .. code:sub(1, 200)) end
  end
end

---------------------------------------------------------------------------
-- physics
---------------------------------------------------------------------------

local function stepPlayer(dt)
  local e = V.electrics.values
  local st = V.input.state
  local u = st.steering and st.steering.val or 0
  local th = st.throttle and st.throttle.val or 0
  local br = st.brake and st.brake.val or 0
  local pb = st.parkingbrake and st.parkingbrake.val or 0
  -- steering rack: wheel follows the input at a finite rate
  local want = -TRUE_SIGN * u * player.dmax
  local rate = math.rad(90) * dt
  player.delta = player.delta + math.max(-rate, math.min(rate, want - player.delta))
  e.steering = -u * 450 -- wheel degrees as BeamNG reports them
  -- arcade gearbox quirk: holding the brake at a standstill shifts into reverse
  if e.gearboxMode == 'arcade' and e.gear == 'D' and br > 0.3 and player.v < 0.1 then
    player.arcadeStill = player.arcadeStill + dt
    if player.arcadeStill > 0.6 then e.gear = 'R'; e.gearIndex = -1; hlog('ARCADE shifted to R') end
  else
    player.arcadeStill = 0
  end
  local dir = (e.gear == 'D') and 1 or ((e.gear == 'R') and -1 or 0)
  local acc = 3.5 * th * dir - 0.05 * player.v - 0.0005 * player.v * math.abs(player.v)
  local stop = 8 * br + 6 * pb
  if e.gear == 'P' then player.v = 0; acc = 0 end
  local nv = player.v + acc * dt
  if nv > 0 then nv = math.max(0, nv - stop * dt) elseif nv < 0 then nv = math.min(0, nv + stop * dt) end
  player.v = nv
  player.psi = player.psi + player.v * math.tan(player.delta) / player.wb * dt
  player.x = player.x + math.cos(player.psi) * player.v * dt
  player.y = player.y + math.sin(player.psi) * player.v * dt
  e.wheelspeed = math.abs(player.v)
  e.throttle, e.brake = th, br
end

local started = false
local function stepWheel(dt)
  if NO_WHEEL then return end
  V.hydros.update()
  local sub = 20
  for _ = 1, sub do
    local h = dt / sub
    local tau = FFB_SIGN * WHEEL.force / 10 * WHEEL.tmax - 0.02 * WHEEL.w * RAD_PER_RAW
    if WHEEL.hand then tau = tau + WHEEL.hand(WHEEL.p, WHEEL.w) end
    local wr = WHEEL.w * RAD_PER_RAW
    if math.abs(wr) < 1e-3 and math.abs(tau) <= WHEEL.fric then
      wr = 0
    else
      local sgn = wr ~= 0 and (wr > 0 and 1 or -1) or (tau > 0 and 1 or -1)
      wr = wr + (tau - sgn * WHEEL.fric) / WHEEL.J * h
    end
    WHEEL.w = wr / RAD_PER_RAW
    WHEEL.p = math.max(-1, math.min(1, WHEEL.p + WHEEL.w * h))
  end
  -- the wheel is the player's steering device: it reports its position when it moves
  if not WHEEL.lastSent or math.abs(WHEEL.p - WHEEL.lastSent) > 1e-4 then
    WHEEL.lastSent = WHEEL.p
    V.input.event('steering', WHEEL.p, 2, 900, 1)
  end
end

local function stepLead(dt)
  -- waits 60 m ahead of the player until the first engagement, then drives east
  if not started then lead.x = player.x + 60; return end
  if lead.x < 900 then lead.x = lead.x + lead.v * dt end
end

local function stepLight(dt)
  if lightGreen then return end
  local x, y = refPos(player)
  if math.abs(x - 290) < 15 and math.abs(y) < 5 and player.v < 0.2 then waitedAtLight = waitedAtLight + dt else waitedAtLight = 0 end
  if waitedAtLight > 3 then lightGreen = true; hlog('light turns green') end
end

---------------------------------------------------------------------------
-- scenario hooks: a scripted player takeover on the second engagement
---------------------------------------------------------------------------

local engagements, engagedFor, wasEngaged = 0, 0, false
local pressedGas, releasedGas = false, false
local releaseIn, bumped = nil, nil
local summonSent = false
local SCENARIO = os.getenv('HARNESS_SCENARIO')
local function scenario(dt)
  if SCENARIO == 'summon' then
    if not summonSent and gameT > 2 then
      summonSent = true
      teslaBridge._handleCommand({ t = 'summon', dir = 'forward' })
    end
    if summonSent and gameT % 0.5 < dt then
      local pl = teslaBridge._planner()
      local ap = vehExtensions.teslaAutopilot and vehExtensions.teslaAutopilot._debug and vehExtensions.teslaAutopilot._debug()
      local x, y = refPos(player)
      print(string.format('t=%.1f ref=%.2f,%.2f v=%.2f steer=%.2f mode=%s act=%s %s', gameT, x, y, player.v, V.electrics.values.steering_input, pl.mode, pl.activity, ap or ''))
    end
    return
  end
  local al = V.input.allowed.steering
  local engaged = al and al['local'] == false
  if engaged then started = true end
  if engaged and not wasEngaged then engagements = engagements + 1; engagedFor = 0; hlog('engaged #' .. engagements) end
  if not engaged and wasEngaged then hlog('disengaged') end
  wasEngaged = engaged
  if engaged then engagedFor = engagedFor + dt end
  if engaged and engagements == 2 and engagedFor > 4 and engagedFor < 4 + dt * 1.5 then
    hlog('player presses the brake')
    V.input.event('brake', 0.6, 0) -- a player's keyboard brake (source local)
  end
  if engagements == 2 and not engaged and engagedFor > 4 then
    V.input.event('brake', 0, 0)
  end
  -- third engagement: 1-3 s in the driver presses the accelerator (FSD stays on and
  -- speeds up), then at 5 s grabs the wheel and turns it right
  if not NO_WHEEL and engaged and engagements == 3 and engagedFor > 1 and not pressedGas then
    pressedGas = true
    hlog('driver presses the accelerator')
    V.input.event('throttle', 0.8, 0)
  end
  if engagements == 3 and pressedGas and not releasedGas and engagedFor > 3 then
    releasedGas = true
    hlog('driver releases the accelerator')
    V.input.event('throttle', 0, 0)
  end
  if not NO_WHEEL and engaged and engagements == 3 and engagedFor > 5 and not WHEEL.hand then
    hlog('driver grabs the wheel')
    WHEEL.hand = function(p, w) return 25 * (0.4 - p) - 0.8 * w end
  end
  -- after taking over, the driver keeps steering for a few seconds, then lets go
  if not engaged and WHEEL.hand and engagements == 3 then
    releaseIn = (releaseIn or 3) - dt
    if releaseIn <= 0 then
      WHEEL.hand = nil; releaseIn = nil
      -- (test shortcut) the driver steers back onto the road: put the car on the first street
      player.x, player.y, player.psi, player.delta = 160, -1.8, 0, 0
      hlog('driver lets go of the wheel, back on the road')
    end
  end
  -- fourth engagement: once at speed, the driver's knee leans on the wheel for a second
  if not NO_WHEEL and engaged and engagements == 4 and engagedFor > 3 and player.v > 10.8 and not bumped then
    bumped = gameT
    hlog('driver bumps the wheel')
    WHEEL.hand = function(p, w) return 25 * (0.2 - p) - 0.8 * w end
  end
  if bumped and WHEEL.hand and gameT - bumped > 1.0 and engagements == 4 then
    WHEEL.hand = nil
    hlog('bump over')
  end
end

---------------------------------------------------------------------------
-- main loop
---------------------------------------------------------------------------

hlog(string.format('fake BeamNG running at %gx real time, steering sign %d', SPEED, TRUE_SIGN))
local dt = 1 / 60
local wall0 = socket.gettime()
local lastPrint = 0
while true do
  gameT = gameT + dt
  teslaBridge.onUpdate(dt, dt)
  runQueued(vehQueue, V, 'vehicle')
  for name, m in pairs(vehExtensions) do
    if m.updateGFX then
      local ok, err = pcall(m.updateGFX, dt)
      if not ok then error('vehicle ' .. name .. '.updateGFX: ' .. tostring(err)) end
    end
  end
  runQueued(geQueue, G, 'ge')
  scenario(dt)
  stepWheel(dt)
  stepPlayer(dt)
  stepLead(dt)
  stepLight(dt)
  if gameT - lastPrint > (tonumber(os.getenv("HARNESS_PRINT") or "5")) then
    lastPrint = gameT
    local e = V.electrics.values
    local pl = teslaBridge._planner and teslaBridge._planner()
    hlog(string.format("car x=%.1f y=%.1f v=%.1f gear=%s steer=%.2f thr=%.2f brk=%.2f wheel=%.2f ffb=%.2f fsd=%s/%s", player.x, player.y, player.v, e.gear, e.steering_input, e.throttle_input, e.brake_input, WHEEL.p, WHEEL.force,
      pl and pl.mode or '-', pl and pl.activity or '-') .. (os.getenv('HARNESS_DEBUG') and (' | ' .. vehExtensions.teslaAutopilot._debug()) or ''))
  end
  if MAX_T > 0 and gameT > MAX_T then break end
  local ahead = gameT / SPEED - (socket.gettime() - wall0)
  if ahead > 0 then socket.sleep(ahead) end
end
