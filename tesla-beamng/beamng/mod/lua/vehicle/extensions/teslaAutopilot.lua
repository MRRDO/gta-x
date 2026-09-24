-- teslaAutopilot (vehicle extension, runs in the player car's Lua VM)
-- * Reports the car's state to the GE extension at 20 Hz.
-- * Runs app commands: gear, lights, signals, horn, doors, accelerator strip.
-- * Drives the car for the autopilot through the same input path a player
--   uses (input.event), so the steering column and wheel animate. It never
--   sets the wheels directly.
-- * Watches the player's own inputs (not ours) and disengages on takeover.
--
-- Works with any car: every part (gearbox, lights, signals, doors) is looked
-- up at runtime and anything missing is skipped and reported.

local M = {}

local C = require('teslaBridge/control')

local logTag = 'teslaAutopilot'
local SOURCE = 'teslaAP'
local FILTER = FILTER_DIRECT or 2
local STATE_HZ = 20

local abs, min, max, sqrt = math.abs, math.min, math.max, math.sqrt

local now = 0
local sendTimer = 0
local driver = nil
local ap = { engaged = false, engagedAt = 0, mode = 'off', profile = 'standard', gapTime = 2.0, throttleMax = 0.6, plan = nil, lastSignal = nil }
local lastDisengage = nil
local override = { value = 0, t = -1, active = false }
local takeover = { steering = 0, brake = 0, throttle = 0 }
local baseline = { steering = 0 }
local savedGearboxMode = nil
local lastInjected = {}
local lastOut = nil
local prevDir = nil
local dirSign = 1
local dirVotes = 0
local gearWant, gearTimer = nil, 0
local wantPark = false

---------------------------------------------------------------------------
-- messaging to GE
---------------------------------------------------------------------------

local function toGE(fn, tbl)
  local ok, s = pcall(jsonEncode, tbl)
  if not ok or not s then return end
  obj:queueGameEngineLua(string.format('if teslaBridge then teslaBridge.%s(%d, %q) end', fn, obj:getID(), s))
end

local function geEvent(kind, extra)
  local ev = extra or {}
  ev.kind = kind
  toGE('onVehicleEvent', ev)
end

local function errorEvent(detail) geEvent('error', { detail = detail }) end

---------------------------------------------------------------------------
-- player input capture (raw) vs our injected input
---------------------------------------------------------------------------

local origEvent = nil
local raw = {}      -- [itype] = { v, filter, t }
local localSeen = {} -- [itype] = count, for diagnostics
local injecting = false

local function wrappedEvent(itype, ivalue, filter, a4, a5, a6, source, ...)
  if not injecting and (source == nil or source == 'local') then
    raw[itype] = { v = ivalue or 0, f = filter, t = now }
    localSeen[itype] = (localSeen[itype] or 0) + 1
  end
  return origEvent(itype, ivalue, filter, a4, a5, a6, source, ...)
end

local function installInputHook()
  if input and type(input.event) == 'function' and input.event ~= wrappedEvent then
    origEvent = input.event
    input.event = wrappedEvent
  end
end

local function removeInputHook()
  if input and input.event == wrappedEvent and origEvent then input.event = origEvent end
end

local function inject(itype, val)
  if not origEvent then installInputHook() end
  if not origEvent then return end
  injecting = true
  local ok, err = pcall(origEvent, itype, val, FILTER, nil, nil, nil, SOURCE)
  injecting = false
  if not ok then log('E', logTag, 'input.event failed: ' .. tostring(err)) end
  lastInjected[itype] = val
end

local function allowLocal(names, allowed)
  if not (input and input.setAllowedInputSource) then return end
  for _, n in ipairs(names) do
    pcall(input.setAllowedInputSource, n, SOURCE, true)
    pcall(input.setAllowedInputSource, n, 'local', allowed)
  end
end

local function rawValue(itype, maxAge)
  local r = raw[itype]
  if not r or now - r.t > (maxAge or 1e9) then return nil end
  return r.v
end

---------------------------------------------------------------------------
-- car parts, looked up at runtime (any car)
---------------------------------------------------------------------------

local function gearboxDevice()
  if not powertrain or not powertrain.getDevice then return nil end
  return powertrain.getDevice('gearbox') or powertrain.getDevice('frontMotor') or powertrain.getDevice('rearMotor') or powertrain.getDevice('mainMotor')
end

local function isManual(dev)
  return dev and (dev.type == 'manualGearbox' or dev.type == 'sequentialGearbox')
end

local function isEV()
  if not powertrain or not powertrain.getDevices then return false end
  for _, d in pairs(powertrain.getDevices()) do
    if d.type == 'electricMotor' then return true end
  end
  return false
end

local function mainController()
  return controller and controller.mainController
end

local function gearLetter()
  local e = electrics.values
  local g = e.gear
  if type(g) == 'string' and #g > 0 then
    local c = g:sub(1, 1)
    if c == 'P' or c == 'R' or c == 'N' or c == 'D' then
      if c == 'N' and wantPark then return 'P' end
      return c
    end
    if tonumber(g) then g = tonumber(g) else return g end
  end
  local idx = type(g) == 'number' and g or e.gearIndex
  if type(idx) == 'number' then
    if idx < 0 then return 'R' end
    if idx == 0 then return wantPark and 'P' or 'N' end
    return 'M' .. idx
  end
  return 'N'
end

local GEAR_INDEX = { R = -1, N = 0, P = 1, D = 2 } -- automatic-style controller indices

local function shiftTo(letter)
  local dev = gearboxDevice()
  if isManual(dev) then
    wantPark = (letter == 'P')
    local idx = (letter == 'R') and -1 or ((letter == 'D') and 1 or 0)
    if dev.setGearIndex then pcall(dev.setGearIndex, dev, idx) end
    if letter == 'P' then inject('parkingbrake', 1) end
    return true
  end
  wantPark = false
  local mc = mainController()
  if mc and mc.shiftToGearIndex then
    pcall(mc.shiftToGearIndex, GEAR_INDEX[letter])
    return true
  end
  return false
end

local function couplers()
  local out = {}
  if not controller or not controller.getControllersByType then return out end
  local list = controller.getControllersByType('advancedCouplerControl') or {}
  for key, c in pairs(list) do
    local name = c.name or (type(key) == 'string' and key) or tostring(key)
    out[#out + 1] = { name = name, c = c }
  end
  return out
end

local function doorKey(name)
  local n = string.lower(name)
  if n:find('frunk') then return 'frunk' end
  if n:find('hood') or n:find('bonnet') then return 'hood' end
  if n:find('trunk') or n:find('tailgate') or n:find('hatch') or n:find('boot') or n:find('liftgate') then return 'trunk' end
  if n:find('door') then
    for _, k in ipairs({ 'fl', 'fr', 'rl', 'rr' }) do
      if n:find('door' .. k) or n:find(k .. 'door') or n:find('door_' .. k) or n:find(k .. '_door') then return k:upper() end
    end
    if n:find('left') or n:find('_l') then return 'L' end
    if n:find('right') or n:find('_r') then return 'R' end
  end
  return name
end

local function groupState(c)
  if not c.getGroupState then return nil end
  local ok, st = pcall(c.getGroupState)
  if ok then return st end
end

local function couplerOpen(c)
  local st = string.lower(tostring(groupState(c) or ''))
  return not (st == 'attached' or st == 'closed' or st == 'locked' or st == 'attaching' or st == '')
end

---------------------------------------------------------------------------
-- state
---------------------------------------------------------------------------

local function sense(dt)
  local px, py, pz = obj:getPositionXYZ()
  local dx, dy, dz = obj:getDirectionVectorXYZ()
  local vx, vy, vz = obj:getVelocityXYZ()
  dx, dy, dz = dx * dirSign, dy * dirSign, dz * dirSign
  local hl = sqrt(dx * dx + dy * dy)
  local hx, hy = 0, 1
  if hl > 1e-6 then hx, hy = dx / hl, dy / hl end
  local vf = vx * hx + vy * hy
  local yaw = 0
  if prevDir and dt > 0 then
    local cr = prevDir[1] * hy - prevDir[2] * hx
    local dp = prevDir[1] * hx + prevDir[2] * hy
    yaw = math.atan2(cr, dp) / dt
  end
  prevDir = { hx, hy }
  -- self-check: driving forward in a forward gear but moving "backwards"? then our
  -- direction vector is flipped for this car.
  local e = electrics.values
  local g = gearLetter()
  if (g == 'D' or g:sub(1, 1) == 'M') and (e.throttle or 0) > 0.1 and sqrt(vx * vx + vy * vy) > 2 then
    if vf < -1.5 then dirVotes = dirVotes + dt else dirVotes = max(0, dirVotes - dt) end
    if dirVotes > 1 then dirSign = -dirSign; dirVotes = 0; errorEvent('direction vector flipped for this car') end
  end
  return { x = px, y = py, z = pz, hx = hx, hy = hy, v = vf, yawRate = yaw }
end

local function buildState(s)
  local e = electrics.values
  local lock = (v and v.data and v.data.input and v.data.input.steeringWheelLock) or 450
  local steerIn = e.steering_input or 0
  local wheelDeg = e.steering and -e.steering or steerIn * lock
  local signal = nil
  if (e.hazard_enabled or 0) == 1 or e.hazard_enabled == true then signal = 'hazard'
  elseif (e.signal_left_input or 0) == 1 then signal = 'left'
  elseif (e.signal_right_input or 0) == 1 then signal = 'right' end
  local ls = e.lights_state
  local low = (ls and ls >= 1) or ((e.lowbeam or 0) > 0)
  local high = (ls and ls >= 2) or ((e.highbeam or 0) > 0)
  local doors = {}
  for _, cp in ipairs(couplers()) do doors[doorKey(cp.name)] = couplerOpen(cp.c) end
  local ev = isEV()
  local fuel = e.fuel
  return {
    speed = e.wheelspeed or abs(s.v),
    gear = gearLetter(),
    throttle = e.throttle_input or e.throttle or 0,
    brake = e.brake_input or e.brake or 0,
    parkingbrake = e.parkingbrake_input or e.parkingbrake or 0,
    steering = steerIn,
    steeringWheelDeg = wheelDeg,
    signal = signal or false,
    lights = { low = low and true or false, high = high and true or false, fog = ((e.fog or 0) > 0) },
    doors = doors,
    battery = ev and fuel or false,
    fuel = (not ev) and fuel or false,
    autopilot = {
      engaged = ap.engaged, mode = ap.mode, profile = ap.profile,
      targetSpeed = lastOut and lastOut.targetSpeed or 0,
      lastDisengage = lastDisengage,
      steerSign = driver and driver.steerSign, steerGain = driver and driver.kmax[2],
    },
  }
end

---------------------------------------------------------------------------
-- autopilot engage / disengage
---------------------------------------------------------------------------

local CONTROLLED = { 'steering', 'throttle', 'brake', 'parkingbrake' }

local function disengage(reason, detail)
  if not ap.engaged then return end
  ap.engaged = false
  ap.mode = 'off'
  allowLocal(CONTROLLED, true)
  inject('throttle', 0)
  inject('brake', 0)
  if reason ~= 'steer' then inject('steering', 0) end
  if ap.lastSignal then
    pcall(electrics.set_warn_signal, 0)
    ap.lastSignal = nil
  end
  local mc = mainController()
  if savedGearboxMode and mc and mc.setGearboxMode then pcall(mc.setGearboxMode, savedGearboxMode) end
  savedGearboxMode = nil
  lastDisengage = { reason = reason, time = now }
  if reason ~= 'app' and reason ~= 'switch' then
    geEvent('disengage', { reason = reason, detail = detail })
  end
end

local function engage(mode, opts)
  if not driver then driver = C.new() end
  ap.mode = mode
  ap.profile = opts.profile or ap.profile
  ap.gapTime = opts.gapTime or ap.gapTime
  ap.throttleMax = opts.throttleMax or ap.throttleMax
  if ap.engaged then return end
  installInputHook()
  ap.engaged = true
  ap.engagedAt = now
  takeover.steering, takeover.brake, takeover.throttle = 0, 0, 0
  baseline.steering = rawValue('steering') or 0
  driver.u = electrics.values.steering_input or 0
  driver.speedI, driver.latI = 0, 0
  local e = electrics.values
  local mc = mainController()
  if not isManual(gearboxDevice()) and e.gearboxMode == 'arcade' and mc and mc.setGearboxMode then
    -- arcade mode shifts into reverse when braking at a stop; drive like a real automatic
    savedGearboxMode = 'arcade'
    pcall(mc.setGearboxMode, 'realistic')
  end
  if mode == 'fsd' then
    allowLocal(CONTROLLED, false)
  else
    allowLocal({ 'steering' }, false)
  end
  inject('parkingbrake', 0)
  wantPark = false
  gearWant, gearTimer = 'D', 0
end

---------------------------------------------------------------------------
-- commands from the app (via GE)
---------------------------------------------------------------------------

local function setSignal(dir)
  if not electrics.set_warn_signal then errorEvent('this car has no turn signals'); return end
  pcall(electrics.set_warn_signal, 0)
  if dir == 'hazard' then pcall(electrics.set_warn_signal, 1)
  elseif dir == 'left' then pcall(electrics.toggle_left_signal)
  elseif dir == 'right' then pcall(electrics.toggle_right_signal) end
end

local handlers = {}

handlers.gear = function(cmd)
  local g = cmd.gear
  if not GEAR_INDEX[g] then errorEvent('unknown gear ' .. tostring(g)); return end
  if ap.engaged and g ~= 'D' then disengage('app') end
  if not shiftTo(g) then errorEvent('this car has no gearbox we can shift') end
  if g ~= 'P' and isManual(gearboxDevice()) then inject('parkingbrake', 0) end
end

handlers.lights = function(cmd)
  local e = electrics.values
  if not electrics.setLightsState then errorEvent('this car has no light controls'); return end
  local ls = e.lights_state or 0
  local want = ls
  if cmd.low == true and want == 0 then want = 1 end
  if cmd.low == false then want = 0 end
  if cmd.high == true then want = 2 end
  if cmd.high == false and want == 2 then want = 1 end
  if want ~= ls then pcall(electrics.setLightsState, want) end
  if cmd.fog ~= nil then
    if electrics.set_fog_lights then pcall(electrics.set_fog_lights, cmd.fog and 1 or 0)
    else errorEvent('this car has no fog lights') end
  end
end

handlers.signal = function(cmd) setSignal(cmd.dir) end

handlers.horn = function(cmd)
  if electrics.horn then pcall(electrics.horn, cmd.on and true or false) else errorEvent('no horn') end
end

handlers.door = function(cmd)
  local want = cmd.door
  for _, cp in ipairs(couplers()) do
    if doorKey(cp.name) == want or cp.name == want then
      if couplerOpen(cp.c) ~= (cmd.open and true or false) then
        if cp.c.toggleGroup then pcall(cp.c.toggleGroup) end
      end
      return
    end
  end
  errorEvent('this car has no door "' .. tostring(want) .. '"')
end

handlers.throttleOverride = function(cmd)
  override.value = math.max(-1, math.min(1, tonumber(cmd.value) or 0))
  override.t = now
end

handlers.autopilot = function(cmd)
  if cmd.mode == 'off' then
    disengage(cmd.reason == 'switch' and 'switch' or (cmd.reason == 'arrived' and 'arrived' or 'app'))
  elseif cmd.mode == 'fsd' or cmd.mode == 'autosteer' then
    engage(cmd.mode, cmd)
  end
end

function M.command(json)
  local ok, cmd = pcall(jsonDecode, json)
  if not ok or type(cmd) ~= 'table' then return end
  local h = handlers[cmd.t]
  if h then
    local ok2, err = pcall(h, cmd)
    if not ok2 then errorEvent(cmd.t .. ': ' .. tostring(err)) end
  end
end

function M.setPlan(json)
  local ok, plan = pcall(jsonDecode, json)
  if not ok or type(plan) ~= 'table' then return end
  if plan.signal == false then plan.signal = nil end
  ap.plan = plan
  plan.gapTime = plan.gapTime or ap.gapTime
  plan.throttleMax = plan.throttleMax or ap.throttleMax
  if not driver then driver = C.new() end
  driver:setPlan(plan)
end

---------------------------------------------------------------------------
-- per frame
---------------------------------------------------------------------------

-- Latest player value for an input, counting only events since we engaged
-- (a pedal already held when engaging, with no new events, doesn't count).
local function rawSinceEngage(itype)
  local r = raw[itype]
  if not r or r.t < ap.engagedAt then return nil end
  return r.v
end

local function checkTakeover(dt)
  local st = rawSinceEngage('steering')
  local br = rawSinceEngage('brake') or 0
  local th = rawSinceEngage('throttle') or 0
  local steerDev = st and abs(st - baseline.steering) or 0
  if ap.mode == 'fsd' or ap.mode == 'autosteer' then
    takeover.steering = (steerDev > 0.15) and takeover.steering + dt or 0
    takeover.brake = (br > 0.1) and takeover.brake + dt or 0
    takeover.throttle = (ap.mode == 'fsd' and th > 0.2) and takeover.throttle + dt or 0
  end
  if takeover.steering > 0.15 then disengage('steer'); return true end
  if takeover.brake > 0.15 then disengage('brake'); return true end
  if takeover.throttle > 0.15 then disengage('throttle'); return true end
  if override.active and override.value < -0.1 then disengage('brake', 'app brake'); return true end
  return false
end

local function updateGFX(dt)
  now = now + dt
  if input and input.event ~= wrappedEvent then installInputHook() end
  local s = sense(dt)
  override.active = (now - override.t) < 0.5

  if ap.engaged then
    if not checkTakeover(dt) then
      local out = driver:update(dt, s, { steerOnly = ap.mode == 'autosteer' })
      lastOut = out
      inject('steering', out.steer)
      if ap.mode == 'fsd' then
        local th, br = out.throttle, out.brake
        local pb = out.parkingbrake or 0
        if override.active and override.value > 0 then th, br = max(th, override.value), 0 end
        if electrics.values.gearboxMode == 'arcade' and s.v < 0.5 and out.targetSpeed < 0.3 then
          -- still in arcade (manual gearbox): brake at a standstill would shift to reverse, hold with the parking brake
          br, pb = 0, 1
        end
        inject('throttle', th)
        inject('brake', br)
        inject('parkingbrake', pb)
        -- keep it in drive (e.g. engaged in P or N)
        local g = gearLetter()
        gearTimer = gearTimer - dt
        if not (ap.plan and ap.plan.hold) and g ~= 'D' and g:sub(1, 1) ~= 'M' and gearTimer <= 0 then
          gearTimer = 0.5
          if s.v < 1 then shiftTo('D') end
        end
      else
        -- autosteer: speed is the driver's; we only brake for a car ahead
        if out.brake > 0.05 then inject('brake', out.brake)
        elseif (lastInjected.brake or 0) > 0 then inject('brake', 0) end
        if override.active then inject('throttle', max(0, override.value)) end
      end
      -- turn signals from the planner
      local want = ap.plan and ap.plan.signal or nil
      if want ~= ap.lastSignal then
        setSignal(want)
        ap.lastSignal = want
      end
    end
  else
    -- accelerator strip in the app, autopilot off
    if override.active then
      inject('throttle', max(0, override.value))
      inject('brake', max(0, -override.value))
    elseif (lastInjected.throttle or 0) ~= 0 or (lastInjected.brake or 0) ~= 0 then
      inject('throttle', 0)
      inject('brake', 0)
    end
  end

  sendTimer = sendTimer - dt
  if sendTimer <= 1e-6 then
    sendTimer = math.max(0, sendTimer + 1 / STATE_HZ)
    local ok, st = pcall(buildState, s)
    if ok then toGE('onVehicleState', st) else log('E', logTag, 'state: ' .. tostring(st)) end
  end
end

---------------------------------------------------------------------------
-- diagnostics
---------------------------------------------------------------------------

local function keysOf(t, limit)
  local out = {}
  if type(t) ~= 'table' then return out end
  for k, val in pairs(t) do
    out[#out + 1] = tostring(k) .. ':' .. type(val)
    if #out >= (limit or 60) then break end
  end
  table.sort(out)
  return out
end

function M.diag()
  local e = electrics.values
  local picked = {}
  for _, k in ipairs({ 'gear', 'gearIndex', 'gearboxMode', 'lights_state', 'lowbeam', 'highbeam', 'fog', 'signal_left_input',
    'signal_right_input', 'hazard_enabled', 'fuel', 'wheelspeed', 'steering', 'steering_input', 'throttle_input', 'brake_input',
    'parkingbrake_input', 'horn' }) do
    picked[k] = e[k] ~= nil and tostring(e[k]) or 'nil'
  end
  local dev = gearboxDevice()
  local cps = {}
  for _, cp in ipairs(couplers()) do
    local st = groupState(cp.c)
    cps[#cps + 1] = cp.name .. ' -> ' .. doorKey(cp.name) .. ' (' .. tostring(st) .. ')'
  end
  local d = {
    inputApi = keysOf(input),
    hasSetAllowedInputSource = input and input.setAllowedInputSource ~= nil,
    inputHookInstalled = input and input.event == wrappedEvent,
    localEventsSeen = localSeen,
    filterDirect = FILTER,
    electrics = picked,
    steeringWheelLock = v and v.data and v.data.input and v.data.input.steeringWheelLock,
    gearbox = dev and dev.type or 'none',
    gearboxMode = e.gearboxMode,
    mainController = mainController() and keysOf(mainController(), 80) or 'none',
    couplers = cps,
    hydros = hydros and keysOf(hydros, 80) or 'none',
    ffbEnabled = hydros and hydros.enableFFB,
    ev = isEV(),
    dirSign = dirSign,
    steerSign = driver and driver.steerSign,
    steerGainByBin = driver and driver.kmax,
    signFlips = driver and driver.flipped,
    engaged = ap.engaged, mode = ap.mode,
    planPoints = ap.plan and ap.plan.pts and #ap.plan.pts / 3 or 0,
  }
  geEvent('diag', { data = d })
end

---------------------------------------------------------------------------
-- hooks
---------------------------------------------------------------------------

local function onExtensionLoaded()
  driver = C.new()
  installInputHook()
  log('I', logTag, 'loaded')
end

local function onExtensionUnloaded()
  if ap.engaged then disengage('error', 'extension unloaded') end
  removeInputHook()
end

local function onReset()
  if ap.engaged then disengage('error', 'vehicle reset') end
  prevDir = nil
  raw = {}
end

M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = onExtensionUnloaded
M.onReset = onReset
M.updateGFX = updateGFX

return M
