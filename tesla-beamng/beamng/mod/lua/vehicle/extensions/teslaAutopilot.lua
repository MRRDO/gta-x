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
local watch = nil        -- after a steering takeover: was it an accidental bump?
local lastReengage = -1e9
local handsNudges = 0
local lastNudgeT = -1e9
local assist = { aeb = 0, ldaSteer = 0, throttleCap = nil, t = -1e9 }
local assistHeld = false -- local throttle/brake taken away for an assist
local hazardOn = false

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
--
-- Players' devices reach the car through input.event (wheels, pedals, axes),
-- input.kbdSteer (keyboard steering), input.padAccelerateBrake (gamepad
-- trigger axis) and input.toggleEvent. The last three call the module's
-- internal event() directly, so each is wrapped to see the player's input.
---------------------------------------------------------------------------

local raw = {}       -- [itype] = { v, f (filter), t, args }
local localSeen = {} -- [itype] = count, for diagnostics
local injecting = false
local orig = {}      -- original input functions
local kbdL, kbdR = 0, 0

local function record(itype, v, filter, a4, a5)
  raw[itype] = { v = v or 0, f = filter, t = now, args = (a4 or a5) and { a4, a5 } or nil }
  localSeen[itype] = (localSeen[itype] or 0) + 1
end

local function wrappedEvent(itype, ivalue, filter, a4, a5, a6, source, ...)
  if not injecting and (source == nil or source == 'local') then record(itype, ivalue, filter, a4, a5) end
  return orig.event(itype, ivalue, filter, a4, a5, a6, source, ...)
end

local function wrappedKbdSteer(isRight, val, filter, ...)
  if isRight then kbdR = val or 0 else kbdL = val or 0 end
  if not injecting then record('steering', kbdR - kbdL, filter) end
  return orig.kbdSteer(isRight, val, filter, ...)
end

local function wrappedPad(val, filter, ...)
  if not injecting then
    val = val or 0
    record('throttle', val > 0 and val or 0, filter)
    record('brake', val < 0 and -val or 0, filter)
  end
  return orig.padAccelerateBrake(val, filter, ...)
end

local function wrappedToggle(itype, ...)
  if not injecting then
    local cur = input.state and input.state[itype] and input.state[itype].val or 0
    record(itype, cur > 0.5 and 0 or 1, 0)
  end
  return orig.toggleEvent(itype, ...)
end

local WRAPS = { event = wrappedEvent, kbdSteer = wrappedKbdSteer, padAccelerateBrake = wrappedPad, toggleEvent = wrappedToggle }

local function installInputHook()
  if not input then return end
  for name, fn in pairs(WRAPS) do
    if type(input[name]) == 'function' and input[name] ~= fn then
      orig[name] = input[name]
      input[name] = fn
    end
  end
end

local function removeInputHook()
  if not input then return end
  for name, fn in pairs(WRAPS) do
    if input[name] == fn and orig[name] then input[name] = orig[name] end
  end
end

local function inject(itype, val)
  if not orig.event then installInputHook() end
  if not orig.event then return end
  injecting = true
  local ok, err = pcall(orig.event, itype, val, FILTER, nil, nil, nil, SOURCE)
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
-- force-feedback wheel (G29 etc.): while engaged we drive the wheel motor
-- ourselves with a position spring, so the physical wheel turns with the car.
--
-- The game's hydros module owns the FFB device. Two ways to take it over:
--  1. its device id lives in a local (FFBID): find it with debug.getupvalue,
--     set it to -1 while engaged (hydros stops sending) and send our own forces
--     with obj:sendForceFeedback(id, force). Put the id back on disengage.
--  2. fallback: we keep the FFB config the game hands hydros
--     (hydros.onFFBConfigChanged), then switch hydros' FFB off with
--     hydros.enableFFB = false + that call (what BeamMP does), and on again after.
---------------------------------------------------------------------------

local Wh = require('teslaBridge/wheel')

local ffb = {
  enabled = true, strength = 0.6,
  spring = Wh.new(), held = false, fn = nil, idx = nil, id = nil, fcap = 10, method = nil,
  status = 'unknown', reason = nil,
  ratio = 1, -- steering_input per raw wheel unit (learned while you drive)
  lastForce = nil, force = 0, target = 0, pos = 0, grip = false,
  minInterval = 0.01, lastSendT = -1, -- wheel drivers misbehave when flooded (hydros throttles too)
  helper = false, -- the external wheel helper owns the motor (backup mode)
}

local FFB_ID_NAMES = { FFBID = true, ffbID = true, FFBId = true, ffbId = true, ffbid = true }
local ffbCfg = nil        -- last FFB config the game gave hydros
local origFFBCfg = nil

local function wrappedFFBCfg(cfg, ...)
  if type(cfg) == 'table' then ffbCfg = cfg end
  return origFFBCfg(cfg, ...)
end

local function installFFBHook()
  if type(hydros) == 'table' and type(hydros.onFFBConfigChanged) == 'function' and hydros.onFFBConfigChanged ~= wrappedFFBCfg then
    origFFBCfg = hydros.onFFBConfigChanged
    hydros.onFFBConfigChanged = wrappedFFBCfg
  end
end

local function removeFFBHook()
  if type(hydros) == 'table' and hydros.onFFBConfigChanged == wrappedFFBCfg and origFFBCfg then hydros.onFFBConfigChanged = origFFBCfg end
end

local function ffbModules()
  local mods = {}
  if type(hydros) == 'table' then mods[#mods + 1] = hydros end
  for name, m in pairs(_G) do
    if type(m) == 'table' and type(name) == 'string' and name:lower():find('ffb') then mods[#mods + 1] = m end
  end
  return mods
end

-- Find a number upvalue by name in the FFB modules' functions, following
-- function upvalues a couple of levels deep (e.g. update -> FFBcalc).
-- `names` is a set of names, or a function(name, value) -> true for a match.
local function scanUpvalues(names)
  if type(debug) ~= 'table' or not debug.getupvalue then return nil, 'no debug library in vehicle Lua' end
  local seen = {}
  local function scan(f, depth)
    if seen[f] then return nil end
    seen[f] = true
    local nested = {}
    for i = 1, 150 do
      local n, val = debug.getupvalue(f, i)
      if not n then break end
      if type(names) == 'function' then
        if names(n, val) then return f, i, val, n end
      elseif names[n] and type(val) == 'number' then return f, i, val, n end
      if type(val) == 'function' and depth < 2 then nested[#nested + 1] = val end
    end
    for _, g in ipairs(nested) do
      local a, b, c, d = scan(g, depth + 1)
      if a then return a, b, c, d end
    end
  end
  for _, m in ipairs(ffbModules()) do
    for _, f in pairs(m) do
      if type(f) == 'function' then
        local a, b, c, d = scan(f, 0)
        if a then return a, b, c, d end
      end
    end
  end
  return nil, 'no FFB device id in hydros'
end

local function hasSendFFB()
  local ok, has = pcall(function() return obj.sendForceFeedback ~= nil end)
  return ok and has
end

local function ffbSend(force)
  local ok = pcall(obj.sendForceFeedback, obj, ffb.id, force)
  ffb.lastForce = force
  ffb.lastSendT = now
  return ok
end

-- the config hydros keeps in a local table ({ steering = { FFBID = n, ... } }), for when the
-- game handed it over before we loaded (so the onFFBConfigChanged hook never saw it)
local function findStoredCfg()
  local _, _, t = scanUpvalues(function(_, v)
    return type(v) == 'table' and type(v.steering) == 'table' and type(v.steering.FFBID) == 'number'
  end)
  return t
end

local function cfgId()
  if not ffbCfg then ffbCfg = findStoredCfg() end
  local st = ffbCfg and ffbCfg.steering
  return st and tonumber(st.FFBID) or nil
end

-- Returns ok, method, f, i, id
local function ffbProbe()
  if ffb.helper then ffb.status, ffb.reason = 'helper', 'external wheel helper drives the wheel'; return false end
  if not ffb.enabled then ffb.status, ffb.reason = 'off', 'turned off'; return false end
  if ffb.held then return true end
  if not hasSendFFB() then ffb.status, ffb.reason = 'unavailable', 'obj:sendForceFeedback missing'; return false end
  local f, i, id = scanUpvalues(FFB_ID_NAMES)
  if f then
    if id < 0 then ffb.status, ffb.reason = 'no wheel', 'no force-feedback wheel bound to steering'; return false end
    ffb.status, ffb.reason = 'available', nil
    return true, 'upvalue', f, i, id
  end
  local cid = cfgId()
  if cid and cid >= 0 and origFFBCfg and hydros.enableFFB ~= nil then
    ffb.status, ffb.reason = 'available', 'via FFB config'
    return true, 'config', nil, nil, cid
  end
  ffb.status, ffb.reason = 'unavailable', i or 'FFB device id not found'
  return false
end

local function ffbTake()
  local ok, method, f, i, id = ffbProbe()
  if not ok or ffb.held then return ffb.held end
  ffb.method, ffb.fn, ffb.idx, ffb.id = method, f, i, id
  local _, _, fmax = scanUpvalues({ FFmax = true, ffMax = true })
  local cmax = ffbCfg and ffbCfg.steering and tonumber(ffbCfg.steering.ff_max_force)
  ffb.fcap = (fmax and fmax > 0) and fmax or ((cmax and cmax > 0) and cmax or 10)
  local _, _, periodms = scanUpvalues({ FFBperiodms = true })
  ffb.minInterval = (periodms and periodms > 0) and math.max(0.002, periodms / 1000) or 0.01
  if method == 'upvalue' then
    debug.setupvalue(f, i, -1) -- hydros stops driving the motor
  else
    hydros.enableFFB = false
    pcall(origFFBCfg, ffbCfg) -- hydros lets go of the device
  end
  ffb.held = true
  ffb.spring:reset()
  ffb.lastForce = nil
  ffb.status = 'active'
  return true
end

local function ffbRelease()
  if not ffb.held then return end
  ffbSend(0)
  if ffb.method == 'upvalue' then
    local _, cur = debug.getupvalue(ffb.fn, ffb.idx)
    if cur == -1 then debug.setupvalue(ffb.fn, ffb.idx, ffb.id) end
  else
    hydros.enableFFB = true
    pcall(origFFBCfg, ffbCfg)
  end
  ffb.held = false
  ffb.force, ffb.grip = 0, false
  ffb.status = 'available'
end

-- Returns true when the driver is holding the wheel against the spring.
local function ffbUpdate(dt, targetInput)
  if not ffb.held then return false end
  if ffb.method == 'upvalue' then
    local _, cur = debug.getupvalue(ffb.fn, ffb.idx)
    if cur ~= -1 then
      -- the game re-bound the wheel (settings changed): take the new id
      if type(cur) == 'number' and cur >= 0 then ffb.id = cur end
      debug.setupvalue(ffb.fn, ffb.idx, -1)
    end
  elseif ffbCfg and cfgId() and cfgId() >= 0 then
    ffb.id = cfgId()
  end
  local r = raw.steering
  local pos = r and r.v or 0
  local target = targetInput / ffb.ratio
  local f, grip = ffb.spring:update(dt, target, pos, ffb.fcap, ffb.strength)
  if dt <= 1e-4 then f = 0 end -- paused: never leave a force on the motor
  local due = now - ffb.lastSendT >= ffb.minInterval
  if (due and (ffb.lastForce == nil or abs(f - ffb.lastForce) > ffb.fcap / 400)) or (f == 0 and ffb.lastForce ~= 0) then ffbSend(f) end
  ffb.force, ffb.target, ffb.pos, ffb.grip = f, target, pos, grip
  if ffb.spring.disabled then
    errorEvent('wheel spring turned off: the wheel kept moving the wrong way')
    ffbRelease()
    ffb.status, ffb.enabled = 'disabled', false
    return false
  end
  return grip
end

-- Learn how the wheel's raw axis maps to steering input (1:1 unless the car's
-- steering lock differs from the wheel's rotation), from your own driving.
local function learnWheelRatio()
  local r = raw.steering
  if not r or now - r.t > 0.05 or abs(r.v) < 0.08 then return end
  local si = electrics.values.steering_input
  if not si then return end
  local k = si / r.v
  if k > 0.2 and k < 5 then ffb.ratio = ffb.ratio + (k - ffb.ratio) * 0.05 end
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

local function couplerOpen(c, name)
  -- the stock controller publishes <name>_notAttached (> 0 = open); fall back to its group state
  local na = name and electrics and electrics.values and electrics.values[name .. '_notAttached']
  if type(na) == 'number' then return na > 0 end
  if type(na) == 'boolean' then return na end
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
  for _, cp in ipairs(couplers()) do doors[doorKey(cp.name)] = couplerOpen(cp.c, cp.name) end
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
      accelOverride = (ap.engaged and ap.accelOverride) and true or false,
      targetSpeed = lastOut and lastOut.targetSpeed or 0,
      lastDisengage = lastDisengage,
      steerSign = driver and driver.steerSign, steerGain = driver and driver.kmax[2],
    },
    handsNudges = handsNudges,
    rawThrottle = rawValue('throttle') or 0,
    wheel = {
      status = ffb.status, reason = ffb.reason, strength = ffb.strength, method = ffb.method,
      pos = ffb.pos, target = ffb.target, force = ffb.force / max(ffb.fcap, 1e-6), ratio = ffb.ratio,
      calibrated = ffb.spring.confirmed,
    },
  }
end

---------------------------------------------------------------------------
-- autopilot engage / disengage
--   fsd       : we steer, accelerate and brake (and stop for signs/lights)
--   autosteer : we steer + hold speed/distance (like Tesla Autosteer)
--   tacc      : we hold speed/distance, you steer (Traffic-Aware Cruise Control)
---------------------------------------------------------------------------

local ALL = { 'steering', 'throttle', 'brake', 'parkingbrake' }
local SPEED_ONLY = { 'throttle', 'brake', 'parkingbrake' }
local REENGAGE_SPEED = 10.06 -- 22.5 mph
local ACCIDENTAL_PEAK = 0.25 -- of full lock


local function controlledFor(mode)
  return mode == 'tacc' and SPEED_ONLY or ALL
end

local function disengage(reason, detail)
  if not ap.engaged then return end
  local mode, profile = ap.mode, ap.profile
  ap.engaged = false
  ap.mode = 'off'
  ffbRelease()
  allowLocal(ALL, true)
  -- hand the controls back as the player has them right now
  inject('throttle', rawValue('throttle') or 0)
  inject('brake', rawValue('brake') or 0)
  inject('parkingbrake', 0)
  if reason ~= 'steer' then inject('steering', rawValue('steering') or 0) end
  if ap.lastSignal then
    pcall(electrics.set_warn_signal, 0)
    ap.lastSignal = nil
  end
  if hazardOn and reason ~= 'attention' then pcall(electrics.set_warn_signal, 0) end
  hazardOn = false
  local mc = mainController()
  if savedGearboxMode and mc and mc.setGearboxMode then pcall(mc.setGearboxMode, savedGearboxMode) end
  savedGearboxMode = nil
  lastDisengage = { reason = reason, time = now }
  if reason == 'steer' and mode ~= 'tacc' then
    -- watch the next moments: an accidental bump at speed gets FSD back on
    local speed = electrics.values.wheelspeed or 0
    local target = lastOut and lastOut.steer or 0
    local st = rawValue('steering')
    watch = { t = now, mode = mode, profile = profile, speed = speed, target = target,
      peak = st and abs(st - target) or 0, lastMove = now, prev = st }
  end
  if reason ~= 'app' and reason ~= 'switch' and reason ~= 'arrived' and reason ~= 'summon' then
    geEvent('disengage', { reason = reason, detail = detail })
  end
end

local function engage(mode, opts)
  if not driver then driver = C.new() end
  local was = ap.engaged
  ap.mode = mode
  ap.profile = opts.profile or ap.profile
  ap.gapTime = opts.gapTime or ap.gapTime
  ap.throttleMax = opts.throttleMax or ap.throttleMax
  installInputHook()
  if not was then
    ap.engaged = true
    ap.engagedAt = now
    takeover.steering, takeover.brake, takeover.throttle = 0, 0, 0
    -- Brake Confirm: the app engages while the driver is holding the brake; that brake
    -- only counts as a takeover after it has been let go once
    takeover.brakeHeld = rawValue('brake') or 0
    takeover.brakeArmed = takeover.brakeHeld < 0.1
    baseline.steering = rawValue('steering') or 0
    driver.u = electrics.values.steering_input or 0
    driver.speedI, driver.latI = 0, 0
    watch = nil
    local e = electrics.values
    local mc = mainController()
    if not isManual(gearboxDevice()) and e.gearboxMode == 'arcade' and mc and mc.setGearboxMode then
      -- arcade mode shifts into reverse when braking at a stop; drive like a real automatic
      savedGearboxMode = 'arcade'
      pcall(mc.setGearboxMode, 'realistic')
    end
    inject('parkingbrake', 0)
    wantPark = false
    gearWant, gearTimer = nil, 0
  end
  allowLocal(ALL, true)
  allowLocal(controlledFor(mode), false)
  if mode == 'tacc' then ffbRelease() else ffbTake() end
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
  if ap.engaged and g ~= 'D' and not cmd.fromPlanner then disengage('app') end
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

handlers.signal = function(cmd)
  setSignal(cmd.dir)
  hazardOn = cmd.dir == 'hazard'
end

handlers.horn = function(cmd)
  if electrics.horn then pcall(electrics.horn, cmd.on and true or false) else errorEvent('no horn') end
end

handlers.door = function(cmd)
  local want = cmd.door
  if cmd.open then
    -- like a Model X: doors only open in Park; stopped in D/R shifts to P first, moving is refused
    if abs(electrics.values.wheelspeed or 0) > 0.5 then errorEvent('doors only open when stopped'); return end
    if gearLetter() ~= 'P' then
      if ap.engaged then disengage('app') end
      shiftTo('P')
    end
  end
  for _, cp in ipairs(couplers()) do
    local k = doorKey(cp.name)
    if k == want or cp.name == want or (want == 'frunk' and k == 'hood') or (want == 'hood' and k == 'frunk') then
      if couplerOpen(cp.c, cp.name) ~= (cmd.open and true or false) then
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

handlers.wheel = function(cmd)
  if cmd.strength ~= nil then ffb.strength = math.max(0, math.min(1, tonumber(cmd.strength) or ffb.strength)) end
  if cmd.helper ~= nil then
    ffb.helper = cmd.helper and true or false
    if ffb.helper then
      ffbRelease()
      ffb.status, ffb.reason = 'helper', 'external wheel helper drives the wheel'
    elseif ap.engaged and ap.mode ~= 'tacc' then ffbTake() else ffbProbe() end
  end
  if cmd.spring ~= nil then
    ffb.enabled = cmd.spring and true or false
    if not ffb.enabled then ffbRelease(); ffb.status = 'off'
    else
      ffb.spring = Wh.new()
      if ap.engaged and ap.mode ~= 'tacc' then ffbTake() else ffbProbe() end
    end
  end
end

handlers.autopilot = function(cmd)
  if cmd.mode == 'off' then
    local r = cmd.reason
    disengage((r == 'switch' or r == 'arrived' or r == 'summon' or r == 'attention' or r == 'error') and r or 'app')
  elseif cmd.mode == 'fsd' or cmd.mode == 'autosteer' or cmd.mode == 'tacc' then
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

-- Active safety while you drive (and as a backstop under FSD): emergency braking,
-- lane departure steering, obstacle-aware throttle limit. Sent at 20 Hz while active.
function M.assist(json)
  local ok, a = pcall(jsonDecode, json)
  if not ok or type(a) ~= 'table' then return end
  assist = { aeb = tonumber(a.aeb) or 0, ldaSteer = tonumber(a.ldaSteer) or 0, throttleCap = tonumber(a.throttleCap), t = now }
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
  if not takeover.brakeArmed then
    local now_ = rawValue('brake') or 0
    -- armed once released, or right away when pressed clearly harder than the confirm press
    if now_ < 0.05 or now_ > (takeover.brakeHeld or 0) + 0.25 then takeover.brakeArmed = true end
    if not takeover.brakeArmed then br = 0 end
  end
  local steerDev = st and abs(st - baseline.steering) or 0
  local devLimit, holdT = 0.15, 0.15
  if ffb.helper and ap.mode ~= 'tacc' then
    -- the external helper turns the wheel to FSD's angle: a takeover is the wheel
    -- being well away from that (it lags a little in quick turns, hence the margin)
    steerDev = st and abs(st - (lastOut and lastOut.steer or 0) / ffb.ratio) or 0
    devLimit, holdT = 0.2, 0.3
  elseif ffb.held or ap.mode == 'tacc' then
    steerDev = 0 -- the spring moves the wheel; grips are caught by it
  end
  takeover.steering = (steerDev > devLimit) and takeover.steering + dt or 0
  takeover.brake = (br > 0.1) and takeover.brake + dt or 0
  takeover.throttle = 0 -- the accelerator never disengages (like a Tesla): it speeds you up
  if takeover.steering > holdT then disengage('steer'); return true end
  if takeover.brake > 0.15 then disengage('brake'); return true end
  if override.active and override.value < -0.1 then disengage('brake', 'app brake'); return true end
  return false
end

-- "Hands on the wheel": a small wheel movement (or a push against the spring)
-- that isn't a takeover. Feeds the nag timer on the GE side.
local function detectNudge()
  if now - lastNudgeT < 1 then return end
  local hit = false
  if ffb.held then
    local e = abs((ffb.pos or 0) - (ffb.target or 0))
    hit = e > 0.012 and e < 0.1 and not ffb.grip
  else
    local r = raw.steering
    if r and r.t > ap.engagedAt and now - r.t < 0.1 then
      local d = abs(r.v - (ffb.helper and ffb.target or baseline.steering))
      hit = d > 0.01 and d < 0.15
    end
  end
  if hit then handsNudges = handsNudges + 1; lastNudgeT = now end
end

-- After a steering takeover at speed: if the wheel was only bumped (small, short,
-- then left alone, no pedals), put FSD back on.
local function checkAccidental()
  if not watch then return end
  local age = now - watch.t
  if age > 1.6 then watch = nil; return end
  local br, th = rawValue('brake') or 0, rawValue('throttle') or 0
  if (raw.brake and raw.brake.t > watch.t and br > 0.1) or (raw.throttle and raw.throttle.t > watch.t and th > 0.15) then watch = nil; return end
  local st = rawValue('steering') or 0
  local dev = abs(st - watch.target)
  watch.peak = math.max(watch.peak, dev)
  if watch.prev and abs(st - watch.prev) > 0.01 then watch.lastMove = now end
  watch.prev = st
  -- a bump is small (under ~110 deg of a 900 deg wheel) and the wheel ends up back where FSD had it
  if age > 0.7 and watch.speed > REENGAGE_SPEED and watch.peak < ACCIDENTAL_PEAK and dev < 0.08 and now - watch.lastMove > 0.5 and now - lastReengage > 10 then
    lastReengage = now
    geEvent('reengage', { mode = watch.mode, profile = watch.profile })
    watch = nil
  end
end

local function applyAssist(engaged, s)
  local fresh = now - assist.t < 0.25
  local aeb = fresh and assist.aeb or 0
  local cap = fresh and assist.throttleCap or nil
  local lda = (fresh and not engaged) and assist.ldaSteer or 0
  if engaged then return aeb end -- under FSD the drive loop folds AEB into its own brake
  local need = aeb > 0 or cap ~= nil
  if need and not assistHeld then
    assistHeld = true
    allowLocal(SPEED_ONLY, false)
  end
  if need then
    local th = rawValue('throttle') or 0
    if aeb > 0 then inject('throttle', 0); inject('brake', aeb)
    else inject('throttle', math.min(th, cap)); inject('brake', rawValue('brake') or 0) end
  elseif assistHeld then
    assistHeld = false
    allowLocal(SPEED_ONLY, true)
    inject('throttle', rawValue('throttle') or 0)
    inject('brake', rawValue('brake') or 0)
  end
  if lda ~= 0 then
    -- the driver's own input plus the nudge (never the last injected value: that would snowball)
    inject('steering', math.max(-1, math.min(1, (rawValue('steering') or 0) + lda)))
    ap.ldaActive = true
  elseif ap.ldaActive then
    ap.ldaActive = false
    inject('steering', rawValue('steering') or 0)
  end
  local _ = s
  return 0
end

local function updateGFX(dt)
  now = now + dt
  if input and input.event ~= wrappedEvent then installInputHook() end
  installFFBHook()
  local s = sense(dt)
  override.active = (now - override.t) < 0.5

  if ap.engaged then
    local aeb = applyAssist(true, s)
    if not checkTakeover(dt) then
      local out = driver:update(dt, s, { noLearn = ap.mode == 'tacc' })
      lastOut = out
      if ap.mode ~= 'tacc' then
        inject('steering', out.steer)
        if ffb.helper then
          -- report where the helper should hold the wheel (it reads wheel.target from the state)
          ffb.target = out.steer / ffb.ratio
          ffb.pos = rawValue('steering') or ffb.pos
        end
        if ffbUpdate(dt, out.steer) then disengage('steer', 'wheel grabbed') end
      end
      detectNudge()
    end
    if ap.engaged and lastOut then
      local out = lastOut
      local plan = ap.plan or {}
      local th, br = out.throttle, out.brake
      local pb = out.parkingbrake or 0
      -- accelerator (your pedal or the app's strip) overrides: go faster while held, never brake
      local pedal = rawSinceEngage('throttle') or 0
      local accel = max(pedal, (override.active and override.value > 0) and override.value or 0)
      if plan.maneuver and accel > 0.3 then
        -- summon / autopark / 3-point turn: the accelerator cancels it (like a Tesla), never speeds it up
        disengage('throttle', plan.maneuver .. ' cancelled')
        return
      end
      ap.accelOverride = accel > 0.05 and plan.dir ~= -1 and not plan.maneuver
      if ap.accelOverride then
        th, br, pb = max(th, accel), 0, 0
        driver.speedI = 0 -- no wind-up: settle back to the set speed smoothly on release
      end
      if aeb > 0 then th, br = 0, max(br, aeb) end
      if not ap.accelOverride and electrics.values.gearboxMode == 'arcade' and abs(s.v) < 0.5 and out.targetSpeed < 0.3 then
        -- still in arcade (manual gearbox): brake at a standstill would shift to reverse, hold with the parking brake
        br, pb = 0, 1
      end
      -- right gear for the plan (reverse legs of a maneuver), shifted only when stopped
      local want = plan.dir == -1 and 'R' or 'D'
      local g = gearLetter()
      gearTimer = gearTimer - dt
      local inGear = (want == 'R' and g == 'R') or (want == 'D' and (g == 'D' or g:sub(1, 1) == 'M'))
      if not inGear and not plan.hold then
        th = 0
        br = max(br, 0.3)
        if abs(s.v) < 0.8 and gearTimer <= 0 then
          gearTimer = 0.5
          shiftTo(want)
        end
      end
      inject('throttle', th)
      inject('brake', br)
      inject('parkingbrake', pb)
      -- turn signals and hazards from the planner
      local sig = plan.hazard and 'hazard' or plan.signal
      if sig ~= ap.lastSignal then
        setSignal(sig)
        ap.lastSignal = sig
        hazardOn = sig == 'hazard'
      end
    end
  else
    learnWheelRatio()
    checkAccidental()
    applyAssist(false, s)
    -- accelerator strip in the app, autopilot off
    if override.active then
      inject('throttle', max(0, override.value))
      inject('brake', max(0, -override.value))
    elseif not assistHeld and ((lastInjected.throttle or 0) ~= 0 or (lastInjected.brake or 0) ~= 0) and not raw.throttle and not raw.brake then
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
    inputWraps = (function() local o = {} for k in pairs(orig) do o[#o + 1] = k end table.sort(o) return o end)(),
    ffb = {
      status = ffb.status, reason = ffb.reason, held = ffb.held, id = ffb.id, fcap = ffb.fcap, ratio = ffb.ratio,
      method = ffb.method, configCaptured = ffbCfg ~= nil, configId = cfgId(), configHook = origFFBCfg ~= nil,
      enableFFB = type(hydros) == 'table' and hydros.enableFFB or nil,
      sign = ffb.spring.sign, flips = ffb.spring.flips, confirmed = ffb.spring.confirmed,
      debugLib = type(debug) == 'table' and debug.getupvalue ~= nil, sendForceFeedback = hasSendFFB(),
      rawSteer = raw.steering and raw.steering.v, rawSteerFilter = raw.steering and raw.steering.f,
      rawSteerArgs = raw.steering and raw.steering.args,
    },
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
  installFFBHook()
  ffbProbe()
  log('I', logTag, 'loaded')
end

local function onExtensionUnloaded()
  if ap.engaged then disengage('error', 'extension unloaded') end
  ffbRelease()
  removeInputHook()
  removeFFBHook()
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
-- test harness hooks
M._ffb = function() return ffb end
-- one-line driver snapshot for the test harness
M._debug = function()
  local o, p = lastOut or {}, ap.plan or {}
  return string.format('held=%s cap=%s aeb=%s ovr=%s acc=%s | eng=%s s=%.2f rem=%.2f vt=%.2f lat=%.2f seq=%s n=%d dir=%s', tostring(assistHeld), tostring(assist.throttleCap), tostring(assist.aeb), tostring(override.active), tostring(ap.accelOverride), tostring(ap.engaged), o.s or -1, o.remaining or -1, o.targetSpeed or -1, o.lat or 0, tostring(p.seq), p.pts and #p.pts / 3 or 0, tostring(p.dir))
end

return M
