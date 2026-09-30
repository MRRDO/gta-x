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
local takeoverLevel = 'normal' -- how hard the wheel must be pushed to take over: 'light' | 'normal' | 'firm'
local steerBias = 0 -- unused: kept at 0 (FSD steering is never biased by the hands)
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
local swerve = { on = true, flips = {}, lastSign = 0, active = false, calmT = 0, t0 = 0 } -- Swerve Assist
-- Tesla driving feel while you drive (FSD off): stopping mode 'roll' | 'creep' | 'hold',
-- regen (lift off = slows like one-pedal driving), accel 'standard' | 'chill'
local feel = { stopping = 'roll', regen = false, accel = 'standard', held = false, th = 0, refresh = 0, holding = false }

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

-- Paddles (and any shift-up / shift-down bindings) become turn signals: left = shift down,
-- right = shift up. Gears then come only from the app / D-R-N-P (setting paddleSignals, default on).
local paddleOrig = {}
local function installPaddleSignals()
  local mc = controller and controller.mainController
  if not mc then return end
  local function left() ap.paddleT = now; pcall(electrics.toggle_left_signal) end
  local function right() ap.paddleT = now; pcall(electrics.toggle_right_signal) end
  for name, fn in pairs({ shiftDownOnDown = left, shiftDown = left, shiftUpOnDown = right, shiftUp = right }) do
    if type(mc[name]) == 'function' and not paddleOrig[name] and mc[name] ~= fn then
      paddleOrig[name] = mc[name]
      if name:find('OnDown') or name == 'shiftDown' or name == 'shiftUp' then mc[name] = function() if ap.paddleSignals ~= false then fn() else return paddleOrig[name]() end end end
    end
  end
end

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
--  1. config (0.39+, preferred): hydros.getFFBID() / getFFBConfig() tell us the device;
--     hydros.enableFFB = false + hydros.onFFBConfigChanged(cfg) makes hydros let go
--     (what BeamMP does), and enableFFB = true + the same call gives it back. Older
--     games: we keep the config the game hands hydros through that same function.
--  2. upvalue (older games): the device id lives in a local (FFBID): debug.setupvalue
--     it to -1 while engaged. 0.39's sandbox blocks debug.setupvalue, so every debug
--     call is pcall'd and this route is only used when it works.
-- Forces go out with obj:sendForceFeedback(id, torque, damping, inertia, friction):
-- 0.39 needs all five (the old 2-argument call fails silently: no force at all).
---------------------------------------------------------------------------

local Wh = require('teslaBridge/wheel')
local Sfl = require('teslaBridge/steerfeel')
local steeringWeight = 'standard' -- Tesla's Steering Weight: light | standard | heavy

local ffb = {
  enabled = true, strength = 1.5, roadFeel = 0, -- 1.5: what the raw path needs to follow FSD (measured) -- softer hold and no road buzz by default: the wheel shook and fought overtaking
  rangeDeg = 900, -- the physical wheel's rotation (G29: 900); the G29 turns 1:1 with the car's wheel
  persist = false, -- after FSD keep our own steering feel instead of handing the wheel back (game FFB stayed dead)
  restoreUntil = nil, -- after release: keep checking that the game has the wheel back
  spring = Wh.new({ gripScale = Wh.takeoverLimit(takeoverLevel) / 0.15 }), held = false, fn = nil, idx = nil, id = nil, fcap = 10, method = nil,
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

local function hydrosCall(name, ...)
  if type(hydros) ~= 'table' or type(hydros[name]) ~= 'function' then return nil end
  local ok, v = pcall(hydros[name], ...)
  if ok then return v end
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
  if not pcall(debug.getupvalue, installFFBHook, 1) then return nil, 'debug.getupvalue blocked by the sandbox' end
  local seen = {}
  local function scan(f, depth)
    if seen[f] then return nil end
    seen[f] = true
    local nested = {}
    for i = 1, 150 do
      local okU, n, val = pcall(debug.getupvalue, f, i)
      if not okU or not n then break end
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
  local ok
  if ffb.ext then
    -- the game keeps the wheel and adds our torque to its own (hydros.setExternalForce): the way that reaches
    -- cars where a raw obj:sendForceFeedback is ignored
    ffb.lastForce, ffb.lastSendT = force, now
    return (pcall(hydros.setExternalForce, force))
  end
  if ffb.sendArgs ~= 2 then
    ok = pcall(obj.sendForceFeedback, obj, ffb.id, force, ffb.dampArg or 0, ffb.inertiaArg or 0, ffb.frictionArg or 0) -- torque, damping, inertia, friction
    if not ok and ffb.sendArgs == nil then ffb.sendArgs = 2 end -- a game with the old signature
  end
  if ffb.sendArgs == 2 then ok = pcall(obj.sendForceFeedback, obj, ffb.id, force) end
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

local function currentCfg()
  local c = hydrosCall('getFFBConfig')
  if type(c) == 'table' then ffbCfg = c end
  if not ffbCfg then ffbCfg = findStoredCfg() end
  return ffbCfg
end

-- the device id hydros drives right now (-1: none / let go)
local function hydrosId()
  local id = tonumber(hydrosCall('getFFBID'))
  if id then return id end
  local st = currentCfg() and ffbCfg.steering
  return st and tonumber(st.FFBID) or nil
end

-- the id of the wheel bound to steering (from the config, which keeps it while hydros lets go)
local function cfgId()
  local st = currentCfg() and ffbCfg.steering
  local id = st and tonumber(st.FFBID)
  if id and id >= 0 then return id end
  return ffb.id or hydrosId()
end

local function applyCfg(cfg)
  local fn = origFFBCfg or (type(hydros) == 'table' and hydros.onFFBConfigChanged)
  if fn == wrappedFFBCfg then fn = origFFBCfg end
  if type(fn) == 'function' then return pcall(fn, cfg) end
  return false
end

-- Returns ok, method, f, i, id
local function ffbProbe()
  if not ffb.enabled then ffb.status, ffb.reason = 'off', 'turned off'; return false end
  if ffb.held or ffb.own then return true end
  if not hasSendFFB() then ffb.status, ffb.reason = 'unavailable', 'obj:sendForceFeedback missing'; return false end
  -- the game itself isn't driving any wheel for steering (this car has no usable FFB binding): we can't
  -- move or hold the wheel, so don't try (holding a wheel that can't follow reads as a takeover)
  local gid = tonumber(hydrosCall('getFFBID'))
  if gid and gid < 0 and hydros and hydros.enableFFB ~= false then
    ffb.status, ffb.reason = 'no wheel', 'the game has no force feedback on steering in this car'
    return false
  end
  local cid = cfgId()
  if cid and cid >= 0 and type(hydros) == 'table' and hydros.enableFFB ~= nil and currentCfg() then
    ffb.status, ffb.reason = 'available', 'via FFB config'
    return true, 'config', nil, nil, cid
  end
  local f, i, id = scanUpvalues(FFB_ID_NAMES)
  if f then
    if id < 0 then ffb.status, ffb.reason = 'no wheel', 'no force-feedback wheel bound to steering'; return false end
    -- 0.39's sandbox: reading works but writing may not
    if not pcall(debug.setupvalue, f, i, id) then ffb.status, ffb.reason = 'unavailable', 'debug.setupvalue blocked and no FFB config'; return false end
    ffb.status, ffb.reason = 'available', nil
    return true, 'upvalue', f, i, id
  end
  if cid == -1 then ffb.status, ffb.reason = 'no wheel', 'no force-feedback wheel bound to steering'; return false end
  ffb.status, ffb.reason = 'unavailable', i or 'FFB device id not found'
  return false
end

local function ffbTake()
  ffb.farNoted, ffb.farT = false, 0
  ffb.stuckT, ffb.stuckLo, ffb.stuckHi = 0, nil, nil
  ffb.posStart, ffb.everMoved = nil, false
  if ffb.own and ffb.method and ffb.enabled and not ffb.helper then
    -- the device is already ours (kept after the last FSD): just start driving it again
    ffb.own, ffb.held, ffb.lastForce, ffb.restoreUntil, ffb.status = false, true, nil, nil, 'active'
    ffb.spring:reset()
    return true
  end
  ffb.own = false
  local ok, method, f, i, id = ffbProbe()
  if not ok or ffb.held then return ffb.held end
  ffb.method, ffb.fn, ffb.idx, ffb.id = method, f, i, id
  local _, _, fmax = scanUpvalues({ FFmax = true, ffMax = true })
  local cmax = ffbCfg and ffbCfg.steering and tonumber(ffbCfg.steering.ff_max_force)
  ffb.fcap = (fmax and fmax > 0) and fmax or ((cmax and cmax > 0) and cmax or 10)
  local _, _, periodms = scanUpvalues({ FFBperiodms = true })
  ffb.minInterval = (periodms and periodms > 0) and math.max(0.002, periodms / 1000) or 0.01
  if method == 'upvalue' then
    if not pcall(debug.setupvalue, f, i, -1) then ffb.status, ffb.reason = 'unavailable', 'debug.setupvalue blocked'; return false end
  else
    -- The game keeps the device (a raw obj:sendForceFeedback doesn't reach the wheel in every car) and we
    -- steer it through hydros: its own self-centring is switched off (wheelPowerSteeringCoef 0) and our
    -- spring goes in as hydros.setExternalForce, so the wheel follows FSD and nothing fights it.
    ffb.ext = ffb.forceRaw == false and type(hydros.setExternalForce) == 'function' -- raw sends by default (hydros' own path shook the wheel)
    if ffb.ext then
      if ffb.savedPSC == nil then ffb.savedPSC = hydros.wheelPowerSteeringCoef end
      hydros.wheelPowerSteeringCoef = 0
    else
      -- hydros keeps its device id and keeps computing; enableFFB = false only stops it sending to the wheel
      hydros.enableFFB = false
      local cur = hydrosId()
      if cur and cur >= 0 then ffb.id = cur end
    end
  end
  ffb.restoreUntil = nil
  ffb.held = true
  ffb.spring:reset()
  -- hydros' external force pushes the axis the other way round from a raw send (measured: -force ran the wheel to the +lock)
  -- measured on two cars and both paths: a positive force turns the axis negative, so start with the sign flipped
  -- (the spring still flips itself if a car is the other way round, and what it learns is kept for the next time)
  if not ffb.spring.confirmed and (ffb.spring.flips or 0) == 0 then ffb.spring.sign = ffb.learnedSign or -1 end
  ffb.spring.gripErr = nil
  if ffb.ext then
    -- hydros external force path (kept as an option): v1 dynamics
    ffb.spring.stiffness, ffb.spring.damping, ffb.spring.integMax = 0.09, 0.28, 0.3
    ffb.spring.velTau, ffb.spring.deadband, ffb.spring.slew = 0.05, 0.006, 0.03
    ffb.spring.gripErr = nil
  else
    -- raw sends (default): tuned by hands-off wave tests. No derivative term (its noise was the chatter), a
    -- slow force slew, stiffer; the driver's hand is judged by how far the wheel is pulled from FSD's angle
    ffb.spring.stiffness, ffb.spring.damping, ffb.spring.integMax = 0.20, 0.0, 0.15
    ffb.spring.velTau, ffb.spring.deadband, ffb.spring.slew = 0.10, 0.012, 0.25
    ffb.spring.gripErr = Wh.takeoverLimit(takeoverLevel)
  end
  if ffb.tune then
    for k, v in pairs(ffb.tune) do if v ~= nil then ffb.spring[k] = v end end
  end
  ffb.lastForce = nil
  ffb.status = ffb.helper and 'helper' or 'active'
  return true
end

-- give the wheel back to the game (its normal force feedback), and keep checking
local function ffbGiveBack()
  if ffb.method == 'upvalue' then
    local ok, _, cur = pcall(debug.getupvalue, ffb.fn, ffb.idx)
    if ok and cur == -1 then pcall(debug.setupvalue, ffb.fn, ffb.idx, ffb.id) end
    return true
  end
  hydros.enableFFB = true
  local cfg = currentCfg()
  local id = hydrosId()
  if id and id >= 0 then return true end
  applyCfg(cfg)
  id = hydrosId()
  if id and id >= 0 then return true end
  -- some versions keep FFBID in a table hydros reads: put it back ourselves
  if cfg and cfg.steering and ffb.id and ffb.id >= 0 and (tonumber(cfg.steering.FFBID) or -1) < 0 then
    cfg.steering.FFBID = ffb.id
    applyCfg(cfg)
  end
  if type(hydros.setFFBConfig) == 'function' then pcall(hydros.setFFBConfig, cfg) end
  id = hydrosId()
  if id and id < 0 and cfg then
    -- hydros may skip a config it already has: hand it a fresh copy
    local function copy(t) local o = {}; for k, v in pairs(t) do o[k] = type(v) == 'table' and copy(v) or v end; return o end
    local c2 = copy(cfg)
    if c2.steering and ffb.id and ffb.id >= 0 then c2.steering.FFBID = ffb.id end
    applyCfg(c2)
    id = hydrosId()
  end
  return id == nil or id >= 0
end

local function ffbRelease(handBack)
  if not ffb.held then return end
  ffbSend(0)
  ffb.held = false
  ffb.force, ffb.grip = 0, false
  if ffb.ext then
    -- nothing was taken from the game: give its self-centring back and stop pushing
    hydros.wheelPowerSteeringCoef = ffb.savedPSC or 1
    ffb.savedPSC = nil
    pcall(hydros.setExternalForce, 0)
    ffb.status = 'available'
    return
  end
  if ffb.persist and not handBack and ffb.method and ffb.id and ffb.id >= 0 then
    -- the game's own force feedback went dead after FSD on Quentin's setup: keep the wheel alive
    -- with our own steering feel (self-centering, speed-weighted) instead of handing it back
    ffb.own, ffb.status, ffb.reason = true, 'own', 'our own steering feel (the game keeps force feedback off)'
    ffb.spring:reset()
    return
  end
  if not ffbGiveBack() then ffb.restoreUntil = now + 3 end
  ffb.status = 'available'
end

-- after a release that didn't stick: retry every frame for a few seconds
local function ffbRestoreTick()
  if not ffb.restoreUntil or ffb.held then return end
  if ffbGiveBack() then ffb.restoreUntil = nil; return end
  if now > ffb.restoreUntil then
    ffb.restoreUntil = nil
    -- the game won't take the wheel back: keep it alive with our own self-centering (stronger
    -- with speed, like a real steering rack) instead of leaving it dead
    ffb.own, ffb.status, ffb.reason = true, 'own', 'game force feedback did not come back: using our own centering'
    ffb.spring:reset()
    errorEvent('the game did not take the wheel back: using our own self-centering force feedback')
  end
end

-- our own self-centering while the game's FFB is unavailable: spring toward 0, firmer at speed
local function ffbOwnTick(dt, s)
  if not ffb.own or ffb.held or ap.engaged then return end
  local id = hydrosId()
  if ffb.persist then
    -- ours on purpose: only let go if the game itself took the device back
    if ffb.method == 'upvalue' then
      local ok, _, cur = pcall(debug.getupvalue, ffb.fn, ffb.idx)
      id = (ok and cur ~= -1) and (tonumber(cur) or 0) or -1
    else
      id = (hydros and hydros.enableFFB == false) and -1 or id
    end
  end
  if id and id >= 0 then
    ffb.own, ffb.status = false, 'available' -- the game has the wheel again
    ffbSend(0)
    return
  end
  if not ffb.id or ffb.id < 0 then return end
  local pos = (raw.steering and raw.steering.v) or 0
  local strength = 0.12 + 0.5 * math.min(1, abs(s.v) / 20)
  local f = ffb.spring:update(dt, 0, pos, ffb.fcap, strength)
  if ffb.spring.confirmed then
    -- the wheel's direction is known: use the real EPS feel (self-aligning, friction, damping) instead of a plain spring
    local t = Sfl.torque({ pos = pos, vel = ffb.spring.vel or 0, v = s.v, latAcc = math.abs((s.yawRate or 0) * s.v), weight = steeringWeight, gain = ffb.strength })
    f = ffb.spring.sign * t * ffb.fcap
  end
  if dt > 1e-4 and now - ffb.lastSendT >= ffb.minInterval then ffbSend(f) end
end

-- where the physical wheel should be for a steering input: the same ANGLE as the car's
-- steering wheel (1:1), as a raw axis value (-1..1 = +/- half the wheel's range)
local function wheelLockDeg()
  local e = electrics.values
  local si = e.steering_input
  if si and abs(si) > 0.05 and e.steering and abs(e.steering) > 1 then
    local k = abs(e.steering / si)
    if k > 60 and k < 1200 then ffb.lockDeg = ffb.lockDeg and (ffb.lockDeg + (k - ffb.lockDeg) * 0.05) or k end
  end
  return ffb.lockDeg or ((v and v.data and v.data.input and v.data.input.steeringWheelLock) or 450)
end

local function wheelTarget(steerInput)
  if ffb.testWave then return ffb.testWave.amp * math.sin(2 * math.pi * ffb.testWave.hz * now) end -- (testing only)
  local sign = ffb.ratio < 0 and -1 or 1
  return math.max(-1, math.min(1, sign * steerInput * wheelLockDeg() / (ffb.rangeDeg * 0.5)))
end

-- Returns true when the driver is holding the wheel against the spring.
local function ffbUpdate(dt, targetInput)
  if not ffb.held then return false end
  if ffb.method == 'upvalue' then
    local ok, _, cur = pcall(debug.getupvalue, ffb.fn, ffb.idx)
    if ok and cur ~= -1 then
      -- the game re-bound the wheel (settings changed): take the new id
      if type(cur) == 'number' and cur >= 0 then ffb.id = cur end
      pcall(debug.setupvalue, ffb.fn, ffb.idx, -1)
    end
  else
    if ffb.ext and hydros.wheelPowerSteeringCoef ~= 0 then hydros.wheelPowerSteeringCoef = 0 end
    local cid = cfgId()
    if cid and cid >= 0 then ffb.id = cid end
    -- the game took the wheel back (settings changed, car reset): let go again
    local hid = hydrosId()
    if not ffb.ext and hid and hid >= 0 and hydros.enableFFB ~= false then hydros.enableFFB = false end
  end
  -- the external helper moves the wheel (the game's own force path doesn't reach some cars): we only keep the game's
  -- force feedback off the motor so it doesn't fight the helper
  if ffb.helper then return false end
  local r = raw.steering
  local pos = r and r.v or 0
  local target = wheelTarget(targetInput)
  local f, grip = ffb.spring:update(dt, target, pos, ffb.fcap, ffb.strength)
  -- road feel: bumps and surface texture through the wheel
  if (ffb.roadFeel or 0) > 0 and dt > 1e-4 then
    local gz = (type(sensors) == 'table' and tonumber(sensors.gz)) or 0
    if math.abs(gz) > 3 then gz = gz / 9.81 end -- m/s^2 -> g
    ffb.gzLP = (ffb.gzLP or gz) + (gz - (ffb.gzLP or gz)) * math.min(1, dt / 0.5)
    local v = tonumber(electrics.values.wheelspeed) or 0
    f = math.max(-ffb.fcap, math.min(ffb.fcap, f + Wh.roadTexture(gz - ffb.gzLP, v, now, ffb.roadFeel or 0) * ffb.fcap))
  end
  if dt <= 1e-4 then f = 0 end -- paused: never leave a force on the motor
  local due = now - ffb.lastSendT >= ffb.minInterval
  if (due and (ffb.lastForce == nil or abs(f - ffb.lastForce) > ffb.fcap / 400)) or (f == 0 and ffb.lastForce ~= 0) then ffbSend(f) end
  ffb.force, ffb.target, ffb.pos, ffb.grip = f, target, pos, grip
  if ffb.spring.confirmed then ffb.learnedSign = ffb.spring.sign end
  -- diagnostics: how much and how fast the wheel jitters (high-pass of its position)
  do
    ffb.jLP = (ffb.jLP or pos) + (pos - (ffb.jLP or pos)) * math.min(1, dt / 0.25)
    local hp = pos - ffb.jLP
    ffb.jRms = (ffb.jRms or 0) + (hp * hp - (ffb.jRms or 0)) * math.min(1, dt / 1.0)
    if ffb.jPrev and (hp > 0) ~= (ffb.jPrev > 0) and math.abs(hp) + math.abs(ffb.jPrev) > 0.004 then ffb.jCross = (ffb.jCross or 0) + 1 end
    ffb.jPrev = hp
    ffb.jT = (ffb.jT or 0) + dt
    if ffb.jT >= 1 then ffb.jHz, ffb.jCross, ffb.jT = (ffb.jCross or 0) / 2, 0, 0 end
    ffb.jN = (ffb.jN or 0) + 1
    ffb.jFps = 1 / math.max(dt, 1e-4)
  end
  ffb.posStart = ffb.posStart or pos
  if math.abs(pos - ffb.posStart) > 0.02 then ffb.everMoved = true end
  -- the wheel never moves although we push at length: the game isn't passing our force to the device
  -- (no usable force feedback in this car). Holding it would read as a driver grabbing the wheel.
  if abs(f) > 0.5 * ffb.fcap and dt > 1e-4 then
    ffb.stuckT = (ffb.stuckT or 0) + dt
    ffb.stuckLo = math.min(ffb.stuckLo or pos, pos)
    ffb.stuckHi = math.max(ffb.stuckHi or pos, pos)
    if ffb.stuckHi - ffb.stuckLo > 0.006 then ffb.stuckT, ffb.stuckLo, ffb.stuckHi = 0, nil, nil end
    if ffb.stuckT > 2.5 and not ffb.ext and ffb.method == 'config' and not ffb.helper and type(hydros.setExternalForce) == 'function' then
      -- our raw force doesn't move this wheel: hand the device back to the game and add our torque through it
      ffb.ext = true
      ffb.stuckT, ffb.stuckLo, ffb.stuckHi = 0, nil, nil
      ffb.posStart, ffb.everMoved = nil, false
      ffbGiveBack()
      ffb.lastForce = nil
      if ffb.savedPSC == nil then ffb.savedPSC = hydros.wheelPowerSteeringCoef end
      hydros.wheelPowerSteeringCoef = 0
      ffb.spring:reset()
      if not ffb.spring.confirmed and (ffb.spring.flips or 0) == 0 then ffb.spring.sign = -1 end
      ffb.spring.stiffness, ffb.spring.damping, ffb.spring.integMax = 0.09, 0.28, 0.3
      ffb.spring.velTau, ffb.spring.deadband, ffb.spring.slew = 0.05, 0.006, 0.03
      ffb.spring.gripErr = nil
      geEvent('notice', { detail = 'wheel ignores raw force feedback in this car: using the game force feedback plus our torque (hydros external force)' })
    elseif ffb.stuckT > 2.5 and not ffb.dead then
      -- keep pushing (the wheel may be turning where we can't see it) but never read "not moving" as a grab
      ffb.dead = true
      geEvent('notice', { detail = string.format('no wheel movement seen under force feedback (pos %.3f, force %.2f): still driving the wheel, but that is not counted as a driver grab', pos, f) })
    end
  else
    ffb.stuckT, ffb.stuckLo, ffb.stuckHi = 0, nil, nil
  end
  -- diagnostics for "the wheel goes hard right": say what it thinks when the wheel sits far from its target
  if math.abs(pos - target) > 0.4 then
    ffb.farT = (ffb.farT or 0) + dt
    if ffb.farT > 1.2 and not ffb.farNoted then
      ffb.farNoted = true
      geEvent('notice', { detail = string.format('wheel far from target: pos %.2f target %.2f sign %d ratio %.2f lockDeg %.0f range %.0f confirmed %s force %.2f',
        pos, target, ffb.spring.sign or 0, ffb.ratio or 0, wheelLockDeg() or 0, ffb.rangeDeg or 0, tostring(ffb.spring.confirmed), f) })
    end
  else
    ffb.farT = 0
  end
  if ffb.spring.disabled then
    errorEvent('wheel spring turned off: the wheel kept moving the wrong way')
    ffbRelease(true)
    ffb.status, ffb.enabled = 'disabled', false
    return false
  end
  return grip and ffb.everMoved == true and not ffb.dead
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
  wheelLockDeg()
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

-- Some car mods (the Model X / Tesla mods) already regenerate when you lift off. Adding our own
-- lift-off braking on top makes them lurch, so we stand down when the car has its own.
local ownRegenCache
local function carHasOwnRegen()
  if ownRegenCache ~= nil then return ownRegenCache end
  local found = false
  pcall(function()
    if powertrain and powertrain.getDevices then
      for _, d in pairs(powertrain.getDevices()) do
        if d.type == 'electricMotor' then
          for k, val in pairs(d) do
            if type(k) == 'string' and k:lower():find('regen') and ((type(val) == 'number' and val > 0) or type(val) == 'table') then found = true end
          end
        end
      end
    end
    for k in pairs(electrics.values or {}) do
      if type(k) == 'string' and k:lower():find('regen') then found = true end
    end
  end)
  ownRegenCache = found
  return found
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
    hold = feel.holding or nil, -- Vehicle Hold ("H" icon)
    rawThrottle = rawValue('throttle') or 0,
    wheel = {
      status = ffb.status, reason = ffb.reason, strength = ffb.strength, method = ffb.method,
      pos = ffb.pos, target = ffb.target, force = ffb.force / max(ffb.fcap, 1e-6), ratio = ffb.ratio,
      calibrated = ffb.spring.confirmed,
      -- the device the game itself drives (>= 0: normal game force feedback is on)
      gameId = (not ffb.held) and hydrosId() or nil, rangeDeg = ffb.rangeDeg,
      path = ffb.ext and 'ext' or 'raw', args = { ffb.dampArg or 0, ffb.inertiaArg or 0, ffb.frictionArg or 0 },
      jitter = ffb.held and { amp = math.sqrt(ffb.jRms or 0), hz = ffb.jHz, fps = ffb.jFps, sign = ffb.spring.sign, flips = ffb.spring.flips, soft = ffb.spring.soft } or nil,
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
  local wheelDriven = ffb.held or ffb.helper
  feel.held = false -- pedals go back to the player below; driveFeel takes them again next frame
  ap.engaged = false
  ap.mode = 'off'
  ffbRelease()
  allowLocal(ALL, true)
  -- hand the controls back as the player has them right now
  inject('throttle', rawValue('throttle') or 0)
  inject('brake', rawValue('brake') or 0)
  inject('parkingbrake', 0)
  if reason == 'arrived' then
    -- parked: straighten the front wheels (like the real car), then give the wheel back to the player
    allowLocal({ 'steering' }, false)
    inject('steering', 0)
    ap.straightUntil, ap.straightRaw = now + 1.8, rawValue('steering') or 0
  elseif reason ~= 'steer' then inject('steering', rawValue('steering') or 0) end
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
  if reason == 'brake' and mode ~= 'tacc' and (detail == nil or detail == '') then
    -- a tap on the brake: if it is over quickly and light, FSD comes back by itself
    watch = { kind = 'brake', t = now, mode = mode, profile = profile, speed = electrics.values.wheelspeed or 0, peakB = 0, lastB = now }
  end
  if reason == 'steer' and mode ~= 'tacc' then
    -- watch the next moments: an accidental bump at speed gets FSD back on
    local speed = electrics.values.wheelspeed or 0
    -- compare in the wheel's own units: with FFB the wheel sits at FSD's angle (1:1), without
    -- it the raw axis maps to steering input through the learned ratio
    local steer = lastOut and lastOut.steer or 0
    local target = wheelDriven and wheelTarget(steer) or steer / ffb.ratio
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
    ap.inGearBefore = nil
    swerve.active, swerve.flips = false, {}
    feel.held, feel.holding = false, false
    ap.prevL, ap.prevR = (e.signal_left_input or 0) > 0.5, (e.signal_right_input or 0) > 0.5
    ap.sigSetAt = now
  end
  allowLocal(ALL, true)
  allowLocal(controlledFor(mode), false)
  if mode == 'tacc' then ffbRelease() else ffbTake() end
end

---------------------------------------------------------------------------
-- commands from the app (via GE)
---------------------------------------------------------------------------

-- Set the blinkers to a state (not toggle them): if the driver's blinker is already on the
-- side we want, leave it on instead of switching it off.
local function setSignal(dir)
  if not electrics.set_warn_signal then errorEvent('this car has no turn signals'); return end
  local e = electrics.values
  local function on(k) return (e[k] or 0) > 0.5 or e[k] == true end
  if dir == 'hazard' then
    if not on('hazard_enabled') then pcall(electrics.set_warn_signal, 1) end
    return
  end
  if on('hazard_enabled') then pcall(electrics.set_warn_signal, 0) end
  local l, r = on('signal_left_input'), on('signal_right_input')
  if dir == 'left' then
    if r then pcall(electrics.toggle_right_signal) end
    if not l then pcall(electrics.toggle_left_signal) end
  elseif dir == 'right' then
    if l then pcall(electrics.toggle_left_signal) end
    if not r then pcall(electrics.toggle_right_signal) end
  else
    if l then pcall(electrics.toggle_left_signal) end
    if r then pcall(electrics.toggle_right_signal) end
  end
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

-- Wipers: cars expose them differently, so try what exists and remember what worked.
local wiperApi
handlers.wipers = function(cmd)
  local level = math.max(0, math.min(3, tonumber(cmd.level) or 0))
  local tries = {
    function() if electrics.setWiperMode then electrics.setWiperMode(level); return true end end,
    function() if electrics.set_wiper_mode then electrics.set_wiper_mode(level); return true end end,
    function() if electrics.values.wiperMode ~= nil then electrics.values.wiperMode = level; return true end end,
    function() if electrics.values.wiperModeRaw ~= nil then electrics.values.wiperModeRaw = level; return true end end,
  }
  if wiperApi then pcall(tries[wiperApi]); return end
  for i, f in ipairs(tries) do
    local ok, res = pcall(f)
    if ok and res then wiperApi = i; return end
  end
  if not wiperApi and level > 0 and not ap.wiperNoted then
    ap.wiperNoted = true
    errorEvent('auto wipers: this car has no wiper control the bridge knows (see debug > wiperKeys)')
  end
end

-- A wheel button the bridge uses (the dial, media keys...) may also be bound to something in the game
-- (the G29's buttons toggle the ignition by default). The relay tells us when one was pressed; if the
-- ignition changed in that instant, put it back.
handlers.guard = function(cmd)
  local h = ap.ignHist
  if not h or #h == 0 or not electrics.setIgnitionLevel then return end
  local want
  for i = #h, 1, -1 do
    if now - h[i].t >= 0.35 then want = h[i].l; break end
  end
  want = want or h[1].l
  local cur = tonumber(electrics.values.ignitionLevel)
  if cur and want and cur ~= want then
    pcall(electrics.setIgnitionLevel, want)
    geEvent('notice', { detail = 'wheel button also hit the ignition: put back' })
  end
end

handlers.horn = function(cmd)
  if electrics.horn then pcall(electrics.horn, cmd.on and true or false) else errorEvent('no horn') end
end

local closing = {}

local function watchClosing()
  for name, w in pairs(closing) do
    local st = string.lower(tostring(groupState(w.c) or ''))
    local na = electrics.values[name .. '_notAttached']
    local latched = st == 'attached' or st == 'closed' or st == 'locked' or (type(na) == 'number' and na == 0 and st ~= 'attaching')
    if latched then
      closing[name] = nil
    elseif now - w.t > 2.5 then
      if w.tries < 2 then
        -- the latch timed out (state back to detached): arm it again
        if st ~= 'attaching' and w.c.toggleGroup then pcall(w.c.toggleGroup) end
        w.tries, w.t = w.tries + 1, now
      else
        closing[name] = nil
        errorEvent((w.key or name) .. ' did not latch: this car has no closing force for it; push it shut in game (Tesla_X: give its coupler a closeForceMagnitude)')
      end
    end
  end
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
      -- closing only arms the latch; the panel has to reach it. Watch it and re-arm if the
      -- latch gives up (hoods with no closing force in their jbeam just sit there).
      if not cmd.open then closing[cp.name] = { c = cp.c, t = now, tries = 0, key = k } else closing[cp.name] = nil end
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
  if cmd.weight == 'light' or cmd.weight == 'standard' or cmd.weight == 'heavy' then steeringWeight = cmd.weight end
  if cmd.takeover == 'light' or cmd.takeover == 'normal' or cmd.takeover == 'firm' then
    takeoverLevel = cmd.takeover
    if ffb.spring then ffb.spring.gripScale = Wh.takeoverLimit(cmd.takeover) / 0.15 end
  end
  -- strength above 1 boosts past the game's FFB limit (a wheel set weak in the game's options)
  if cmd.strength ~= nil then ffb.strength = math.max(0, math.min(2, tonumber(cmd.strength) or ffb.strength)) end
  if cmd.roadFeel ~= nil then ffb.roadFeel = math.max(0, math.min(2, tonumber(cmd.roadFeel) or 1)) end
  if cmd.rangeDeg ~= nil then ffb.rangeDeg = math.max(180, math.min(1080, tonumber(cmd.rangeDeg) or ffb.rangeDeg)) end
  if cmd.ownFfb ~= nil then
    ffb.persist = cmd.ownFfb and true or false
    if not ffb.persist and ffb.own then ffb.own = false; ffbGiveBack() end
  end
  if cmd.wave ~= nil then ffb.testWave = (type(cmd.wave) == 'table' and cmd.wave.amp) and { amp = tonumber(cmd.wave.amp) or 0.3, hz = tonumber(cmd.wave.hz) or 0.25 } or nil end
  if cmd.wave ~= nil and not ap.engaged then
    if ffb.testWave then if not ffb.held then ffbTake() end else ffbRelease(true) end
  end
  if cmd.path ~= nil or cmd.damp ~= nil or cmd.inertia ~= nil or cmd.friction ~= nil or cmd.spr ~= nil then
    -- tuning (testing): path 'raw' | 'ext', the device-side damper / inertia / friction, spring stiffness / damping
    if cmd.damp ~= nil then ffb.dampArg = tonumber(cmd.damp) or 0 end
    if cmd.inertia ~= nil then ffb.inertiaArg = tonumber(cmd.inertia) or 0 end
    if cmd.friction ~= nil then ffb.frictionArg = tonumber(cmd.friction) or 0 end
    if cmd.spr and ffb.spring then
      ffb.tune = { stiffness = tonumber(cmd.spr.stiffness), damping = tonumber(cmd.spr.damping), velTau = tonumber(cmd.spr.velTau), deadband = tonumber(cmd.spr.deadband), slew = tonumber(cmd.spr.slew), integMax = tonumber(cmd.spr.integMax) }
    end
    if cmd.path == 'raw' or cmd.path == 'ext' then
      ffb.forceRaw = cmd.path == 'raw'
      if ffb.held then
        ffbRelease(true)
        if ap.engaged and ap.mode ~= 'tacc' then ffbTake() end
      end
    end
  end
  if cmd.pos ~= nil and ffb.helper then
    -- the wheel helper reads the wheel itself (the game's input events do not reach us in every car)
    local v = tonumber(cmd.pos)
    if v then raw.steering = { v = v, f = 0, t = now, args = {} } end
  end
  if cmd.helper ~= nil then
    ffb.helper = cmd.helper and true or false
    if ffb.helper then
      ffb.own = false
      if ap.engaged and ap.mode ~= 'tacc' then ffbTake() else ffbRelease(true) end
      ffb.status, ffb.reason = 'helper', 'external wheel helper drives the wheel'
    elseif ap.engaged and ap.mode ~= 'tacc' then ffbTake() else ffbProbe() end
  end
  if cmd.spring ~= nil then
    ffb.enabled = cmd.spring and true or false
    if not ffb.enabled then ffb.own = false; ffbRelease(true); ffb.status = 'off'
    else
      ffb.spring = Wh.new({ gripScale = Wh.takeoverLimit(takeoverLevel) / 0.15 })
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
  if ffb.helper and ap.mode ~= 'tacc' then
    local tgt = wheelTarget(lastOut and lastOut.steer or 0)
    local cur = rawValue('steering')
    if not ffb.expect or now - ap.engagedAt < 0.05 then ffb.expect = cur or tgt end
    ffb.expect = ffb.expect + (tgt - ffb.expect) * math.min(1, dt / 0.3)
  end
  local steerDev = st and abs(st - baseline.steering) or 0
  local devLimit, holdT = Wh.takeoverLimit(takeoverLevel), 0.08
  steerBias = 0
  do
    -- a slight turn of the wheel steers the car a little (how far the driver has moved it from where FSD has it);
    -- past devLimit it is a takeover, below a small dead zone it is nothing
    local dv
    if ap.mode ~= 'tacc' then
      if ffb.helper then
        if st and lastOut then
          local d = st - (ffb.expect or wheelTarget(lastOut.steer or 0))
          ffb.biasLP = (ffb.biasLP or d) + (d - (ffb.biasLP or d)) * math.min(1, dt / 0.15)
          if abs(ffb.spring.vel or 0) < 0.25 then dv = ffb.biasLP end
        end
      elseif ffb.held then
        -- the slow copy of the error (jitter of the wheel is not a hand); while the wheel is still moving to follow FSD
        -- the gap is lag, not a hand
        if abs(ffb.spring.vel or 0) < 0.25 and ffb.spring.eLP then dv = -ffb.spring.eLP end
      elseif st and lastOut then
        local a1, b1 = st - baseline.steering, st - wheelTarget(lastOut.steer or 0)
        dv = abs(a1) < abs(b1) and a1 or b1
      end
    end
    if dv and abs(dv) > 0.035 and abs(dv) < Wh.takeoverLimit(takeoverLevel) then
      steerBias = (dv > 0 and 1 or -1) * math.min(0.03, (abs(dv) - 0.035) * 0.8)
    end
  end
  if ffb.helper and ap.mode ~= 'tacc' then
    -- the external helper turns the wheel to FSD's angle: a takeover is the wheel
    -- being well away from that (it lags a little in quick turns, hence the margin)
    steerDev = (st and ffb.expect) and abs(st - ffb.expect) or 0
    devLimit, holdT = devLimit + 0.04, 0.15
    if now - ap.engagedAt < 0.8 then steerDev = 0 end -- the wheel is still getting to FSD's angle
  elseif ffb.held or ap.mode == 'tacc' then
    -- the spring moves the wheel; grips are caught by it. A light push shows up as the wheel's
    -- distance from where the spring holds it
    steerDev = 0
  end
  if not ffb.helper and not ffb.held and ap.mode ~= 'tacc' and st and lastOut then
    -- the game's own force feedback may turn the wheel along with the car, or leave it where it was:
    -- only a wheel that is neither where it started nor where FSD steers is a driver taking over
    steerDev = math.min(steerDev, abs(st - wheelTarget(lastOut.steer or 0)))
  end
  -- slight hand movement above steers a little; a strong one is a takeover
  takeover.steering = (steerDev > devLimit) and takeover.steering + dt or 0
  takeover.brake = (br > 0.04) and takeover.brake + dt or 0
  takeover.throttle = 0 -- the accelerator never disengages (like a Tesla): it speeds you up
  if takeover.steering > holdT then disengage('steer', string.format('wheel %.3f start %.3f fsd %.3f limit %.3f held %s', st or 0, baseline.steering, wheelTarget(lastOut and lastOut.steer or 0), devLimit, tostring(ffb.held))); return true end
  if takeover.brake > 0.05 then disengage('brake'); return true end
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
  if age > 2.5 then watch = nil; return end
  if watch.kind == 'brake' then
    local b = math.max(rawValue('brake') or 0, tonumber(electrics.values.brake_input) or 0)
    watch.peakB = math.max(watch.peakB, b)
    if b > 0.04 then watch.lastB = now end
    if (rawValue('throttle') or 0) > 0.15 or watch.peakB > 0.45 or now - watch.t > 1.2 and b > 0.04 then watch = nil; return end
    -- let go for a moment after a short, light press -> it was an accident
    if now - watch.lastB > 0.3 and watch.lastB - watch.t < 0.9 and watch.speed > 4 and now - lastReengage > 5 then
      lastReengage = now
      geEvent('reengage', { mode = watch.mode, profile = watch.profile })
      watch = nil
    end
    return
  end
  local br, th = rawValue('brake') or 0, rawValue('throttle') or 0
  if (raw.brake and raw.brake.t > watch.t and br > 0.1) or (raw.throttle and raw.throttle.t > watch.t and th > 0.15) then watch = nil; return end
  local st = rawValue('steering') or 0
  local dev = abs(st - watch.target)
  watch.peak = math.max(watch.peak, dev)
  if watch.prev and abs(st - watch.prev) > 0.01 then watch.lastMove = now end
  watch.prev = st
  -- a bump is small (under ~110 deg of a 900 deg wheel) and the wheel ends up back where FSD had it
  if age > 0.6 and watch.speed > REENGAGE_SPEED and watch.peak < ACCIDENTAL_PEAK and dev < 0.12 and now - watch.lastMove > 0.4 and now - lastReengage > 10 then
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

-- Swerve Assist (you're driving, FSD off): big back-and-forth steering at speed, or the car
-- starting to yaw hard -> ease the steering (less of your input, a little counter-steer
-- against the yaw) and cut the throttle until the car settles, then hand it all back.
local SWERVE_SPEED = 22 -- m/s (~50 mph)

local function swerveAssist(dt, s)
  if not swerve.on then return end
  local st = rawValue('steering') or 0
  local sign = st > 0.2 and 1 or (st < -0.2 and -1 or 0)
  if sign ~= 0 and sign ~= swerve.lastSign then
    if swerve.lastSign ~= 0 then swerve.flips[#swerve.flips + 1] = now end
    swerve.lastSign = sign
  end
  while swerve.flips[1] and now - swerve.flips[1] > 2 do table.remove(swerve.flips, 1) end
  local yaw = s.yawRate or 0
  local fast = abs(s.v) > SWERVE_SPEED
  if not swerve.active then
    if fast and ((#swerve.flips >= 3 and abs(yaw) > 0.3) or abs(yaw) > 0.7) then
      swerve.active, swerve.calmT, swerve.t0 = true, 0, now
      allowLocal({ 'steering', 'throttle' }, false)
      geEvent('swerveAssist', { detail = 'stabilizing' })
    end
    return
  end
  -- active: soften the driver's steering, counter the yaw, no throttle
  local k = (driver and driver.steerSign) or 1
  local add = math.max(-0.3, math.min(0.3, k * yaw * 0.4))
  inject('steering', math.max(-1, math.min(1, st * 0.6 + add)))
  inject('throttle', 0)
  if abs(yaw) < 0.1 and abs(st) < 0.35 then swerve.calmT = swerve.calmT + dt else swerve.calmT = 0 end
  if swerve.calmT > 0.8 or now - swerve.t0 > 4 or abs(s.v) < SWERVE_SPEED * 0.6 then
    swerve.active = false
    swerve.flips = {}
    allowLocal({ 'steering', 'throttle' }, true)
    inject('steering', rawValue('steering') or 0)
    inject('throttle', rawValue('throttle') or 0)
    geEvent('swerveAssist', { detail = 'done' })
  end
end

-- Your pedals, reshaped the Tesla way. Needs the pedals routed through us while it's on.
local function driveFeel(dt, s)
  -- Hill Hold: stopped (or nearly) on a slope with both feet off: the brake stays on until the accelerator
  local slope = 0
  pcall(function() slope = obj:getDirectionVector().z end)
  local hill = feel.hill ~= false and abs(slope) > 0.05 and abs(s.v) < 1.5
  local on = feel.stopping ~= 'roll' or feel.regen or feel.accel ~= 'standard' or hill
  local g = gearLetter()
  local driving = g == 'D' or g == 'R' or g:sub(1, 1) == 'M'
  if not on or not driving or assistHeld or swerve.active then
    if feel.held then
      feel.held = false
      allowLocal({ 'throttle', 'brake' }, true)
      inject('throttle', rawValue('throttle') or 0)
      inject('brake', rawValue('brake') or 0)
    end
    feel.holding = false
    return
  end
  feel.refresh = feel.refresh - dt
  if not feel.held or feel.refresh <= 0 then
    feel.held, feel.refresh = true, 0.5
    allowLocal({ 'throttle', 'brake' }, false)
  end
  local th, br = rawValue('throttle') or 0, rawValue('brake') or 0
  -- Chill: softer and slower to build (about 60 % of the pedal, eased in)
  if feel.accel == 'chill' then
    local want = th * 0.6
    local rate = (want > feel.th) and 0.8 or 3
    feel.th = feel.th + math.max(-rate * dt, math.min(rate * dt, want - feel.th))
    th = feel.th
  elseif feel.accel == 'sport' then
    -- Sport: the pedal is more sensitive (85 % of the pedal is full power)
    th = math.min(1, th / 0.85)
    feel.th = th
  else
    feel.th = th
  end
  local v = abs(s.v)
  feel.holding = false
  if th < 0.02 and br < 0.02 then
    if feel.regen and not carHasOwnRegen() and v > 1.5 and not (feel.stopping == 'creep' and v < 3) then
      br = math.min(0.2, 0.06 + v * 0.008) * (feel.regenLevel == 'low' and 0.6 or 1) -- lift off: regen slows the car, stronger at speed (Tesla: Standard / Low)
    end
    if (feel.stopping == 'hold' or hill) and v < 0.5 then
      br, feel.holding = 0.6, true -- Vehicle Hold: stays stopped until you press the accelerator
    elseif feel.stopping == 'creep' and v < 1.8 then
      th = 0.09 -- creeps forward like a regular automatic
    end
  end
  inject('throttle', th)
  inject('brake', br)
end

-- Plaid in the app = Sport here; and if the car has its own drive modes (BeamNG's driveModes controller), Sport too
local sportPrev = nil
local function carSportMode(on)
  local dm = controller and controller.getController and controller.getController('driveModes')
  if not dm or not dm.setDriveMode then return false end
  if on then
    local cur = dm.getCurrentDriveModeKey and dm.getCurrentDriveModeKey()
    for _, k in ipairs({ 'sport', 'Sport', 'sportPlus', 'dynamic', 'performance' }) do
      if cur == k then return true end
      if dm.getDriveModeData and dm.getDriveModeData(k) then
        sportPrev = sportPrev or cur
        dm.setDriveMode(k)
        return true
      end
    end
  elseif sportPrev then
    dm.setDriveMode(sportPrev)
    sportPrev = nil
  end
  return false
end

handlers.drive = function(cmd)
  if cmd.stopping == 'roll' or cmd.stopping == 'creep' or cmd.stopping == 'hold' then feel.stopping = cmd.stopping end
  if cmd.regenLevel == 'low' or cmd.regenLevel == 'standard' then feel.regenLevel = cmd.regenLevel end
  if cmd.hillHold ~= nil then feel.hill = cmd.hillHold and true or false end
  if cmd.regen ~= nil then
    feel.regen = cmd.regen and true or false
    if feel.regen and carHasOwnRegen() and not feel.regenNoted then
      feel.regenNoted = true
      geEvent('notice', { detail = 'this car has its own regen braking: the bridge leaves it alone' })
    end
  end
  if cmd.accel == 'chill' or cmd.accel == 'standard' or cmd.accel == 'sport' then feel.accel = cmd.accel end
  if cmd.accel == 'chill' or cmd.accel == 'standard' or cmd.accel == 'sport' then pcall(carSportMode, cmd.accel == 'sport') end
end

handlers.handover = function(cmd) ap.handover = cmd.on and true or false end

handlers.paddles = function(cmd) ap.paddleSignals = cmd.signals ~= false end

handlers.swerveAssist = function(cmd)
  swerve.on = cmd.on ~= false
  if not swerve.on and swerve.active then
    swerve.active = false
    allowLocal({ 'steering', 'throttle' }, true)
  end
end

local function updateGFX(dt)
  now = now + dt
  if input and input.event ~= wrappedEvent then installInputHook() end
  installFFBHook()
  if not ap.paddleHooked and controller and controller.mainController then ap.paddleHooked = true; pcall(installPaddleSignals) end
  if ffb.restoreUntil then pcall(ffbRestoreTick) end
  if next(closing) then pcall(watchClosing) end
  local s = sense(dt)
  override.active = (now - override.t) < 0.5
  if ap.straightUntil then
    local r = rawValue('steering') or 0
    if ap.engaged or now >= ap.straightUntil or abs(r - (ap.straightRaw or 0)) > 0.12 then
      ap.straightUntil = nil
      if not ap.engaged then allowLocal({ 'steering' }, true); inject('steering', r) end
    else
      inject('steering', 0)
    end
  end
  -- A paddle turns a signal on; the game's own paddle binding may still shift the gear (it can reach the gearbox by
  -- routes we can't wrap), so put the gear back if it moved just after a paddle press.
  do
    local g = gearLetter()
    if ap.paddleT and ap.paddleSignals ~= false then
      if now - ap.paddleT < 0.6 then
        local before = ap.paddleGear or ap.lastGear
        ap.paddleGear = before
        if before and (before == 'D' or before == 'R' or before == 'N' or before == 'P') and g ~= before and not ap.engaged then
          shiftTo(before)
          if not ap.paddleNoted then ap.paddleNoted = true; geEvent('notice', { detail = 'paddle shift undone: paddles are turn signals' }) end
        end
      else
        ap.paddleT, ap.paddleGear = nil, nil
      end
    end
    if not ap.paddleT then ap.lastGear = g end
    -- ignition history (for the wheel-button guard below): what it was ~0.4 s ago
    local lvl = tonumber(electrics.values.ignitionLevel)
    if lvl then
      ap.ignHist = ap.ignHist or {}
      local h = ap.ignHist
      h[#h + 1] = { t = now, l = lvl }
      while #h > 2 and now - h[2].t > 1.2 do table.remove(h, 1) end
    end
  end

  if ap.engaged then
    local aeb = applyAssist(true, s)
    if not checkTakeover(dt) then
      local out = driver:update(dt, s, { noLearn = ap.mode == 'tacc' })
      lastOut = out
      if ap.mode ~= 'tacc' then
        inject('steering', math.max(-1, math.min(1, out.steer + steerBias)))
        if ffb.helper then
          -- report where the helper should hold the wheel (it reads wheel.target from the state)
          ffb.target = wheelTarget(out.steer)
          ffb.pos = rawValue('steering') or ffb.pos
        end
        if ffbUpdate(dt, out.steer) then disengage('steer', string.format('wheel grabbed pos %.3f tgt %.3f eLP %.3f vel %.2f rms %.3f', ffb.pos or 0, ffb.target or 0, ffb.spring.eLP or 0, ffb.spring.vel or 0, math.sqrt(ffb.jRms or 0))) end
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
      if ap.handover and pedal > 0.25 then
        -- FSD asked for a takeover: the accelerator is the answer (instead of going faster)
        disengage('throttle', 'handover')
        return
      end
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
        -- the driver moved the gear lever (e.g. a G29 H-shifter) while FSD drives forward:
        -- put it straight back into D (no braking to a stop for it) and say so
        local driverMoved = want == 'D' and inGear == false and ap.inGearBefore and abs(s.v) >= 0.8
        if driverMoved and gearTimer <= 0 then
          gearTimer = 0.5
          shiftTo('D')
          br = 0
          if now - (ap.gearNoteT or -1e9) > 5 then
            ap.gearNoteT = now
            geEvent('notice', { detail = 'gear change ignored while FSD drives (take over to shift)' })
          end
        elseif abs(s.v) < 0.8 and gearTimer <= 0 then
          gearTimer = 0.5
          shiftTo(want)
        end
      end
      if inGear then ap.inGearBefore = true elseif abs(s.v) < 0.8 then ap.inGearBefore = false end
      inject('throttle', th)
      inject('brake', br)
      inject('parkingbrake', pb)
      -- turn signals and hazards from the planner
      local sig = plan.hazard and 'hazard' or plan.signal
      if sig ~= ap.lastSignal then
        setSignal(sig)
        ap.lastSignal = sig
        hazardOn = sig == 'hazard'
        ap.sigSetAt = now
        -- whatever the lights do now is ours: only a fresh flick after this counts as the driver
        ap.lOnT, ap.rOnT = nil, nil
        ap.prevL = (electrics.values.signal_left_input or 0) > 0.5
        ap.prevR = (electrics.values.signal_right_input or 0) > 0.5
      end
      -- the driver's own blinker (paddles / stalk bound to toggle_left/right_signal): a
      -- rising edge we didn't cause asks FSD for a lane change (or the next turn) that way
      local e2 = electrics.values
      local l, r = (e2.signal_left_input or 0) > 0.5, (e2.signal_right_input or 0) > 0.5
      -- some cars (the Tesla Model 3 mod) blink the *_input value with the flasher, and our own
      -- signal lingers after FSD turns it off: those looked like the driver signalling again and
      -- again (route kept turning off and growing). Count it only when it stays on for 0.8 s
      -- (a flasher blinks faster), well after FSD last touched the signal, or right after a paddle.
      local paddle = now - (ap.paddleT or -1e9) < 1.5
      local quiet = now - (ap.sigSetAt or -1e9) > 2.5
      if l and not ap.prevL then ap.lOnT = now end
      if r and not ap.prevR then ap.rOnT = now end
      if ap.mode ~= 'tacc' and ap.lastSignal ~= 'hazard' and (quiet or paddle) then
        if l and ap.lOnT and (paddle or now - ap.lOnT > 0.8) and ap.lastSignal ~= 'left' then ap.lOnT = nil; geEvent('driverSignal', { dir = 'left' }) end
        if r and ap.rOnT and (paddle or now - ap.rOnT > 0.8) and ap.lastSignal ~= 'right' then ap.rOnT = nil; geEvent('driverSignal', { dir = 'right' }) end
      end
      if not l then ap.lOnT = nil end
      if not r then ap.rOnT = nil end
      ap.prevL, ap.prevR = l, r
    end
  else
    learnWheelRatio()
    checkAccidental()
    if ffb.own then pcall(ffbOwnTick, dt, s) end
    if ffb.testWave and ffb.held and not ap.engaged then pcall(ffbUpdate, dt, 0) end -- (testing: drive the wheel without FSD)
    applyAssist(false, s)
    -- Auto Shift out of Park: tell GE when the driver presses the brake in P (it picks D or R
    -- if the setting is on)
    swerveAssist(dt, s)
    driveFeel(dt, s)
    local bp = math.max(rawValue('brake') or 0, tonumber(electrics.values.brake_input) or 0, tonumber(electrics.values.brake) or 0) > 0.3
    if bp and not ap.brakeWasDown and gearLetter() == 'P' and abs(s.v) < 0.3 then geEvent('brakeInPark', {}) end
    ap.brakeWasDown = bp
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
    ffbEnabled = hydros and hydros.enableFFB, psc = hydros and hydros.wheelPowerSteeringCoef, ffbExt = ffb.ext, ffbHeld = ffb.held, pscSaved = ffb.savedPSC,
    
    ev = isEV(),
    ownRegen = carHasOwnRegen(),
    wiperKeys = (function() local o = {} for k in pairs(electrics.values or {}) do if type(k) == 'string' and k:lower():find('wiper') then o[#o + 1] = k end end table.sort(o) return o end)(),
    wiperApi = wiperApi,
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
  ffb.own = false
  ffbRelease(true)
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
