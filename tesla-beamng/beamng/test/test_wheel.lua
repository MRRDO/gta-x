-- Force-feedback wheel spring against a G29-like wheel model.
-- Run: luajit beamng/test/test_wheel.lua (from tesla-beamng/)

package.path = 'beamng/mod/lua/common/?.lua;' .. package.path
local W = require('teslaBridge/wheel')

local failures, passes = 0, 0
local function check(cond, msg)
  if cond then passes = passes + 1 else failures = failures + 1; print('FAIL: ' .. msg) end
end

-- G29-ish: 900 deg (raw 1 = 450 deg = 7.85 rad), ~2.1 Nm peak. The spring's
-- full force (fcap) maps to `tmax` Nm at the rim. Gear friction + damping.
local RAD_PER_RAW = math.rad(450)
local function run(opts)
  local J = opts.J or 0.03
  local tmax = opts.tmax or 1.3
  local fric = opts.fric or 0.12
  local devSign = opts.devSign or 1
  local s = W.new({ gripScale = opts.gripScale })
  local dt = 1 / 60
  local sub = 20
  local p, w = opts.p0 or 0, 0 -- raw pos, raw/s
  local seen = {}               -- position the game sees (delayed)
  local delay = opts.delay or 2
  local force = 0
  local log = { maxOver = 0, gripAt = nil, errAt = {} }
  local t = 0
  while t < (opts.T or 4) do
    local target = opts.target(t)
    seen[#seen + 1] = p
    local pos = seen[math.max(1, #seen - delay)]
    local f, grip = s:update(dt, target, pos, 1, 1)
    if t > (opts.chatterFrom or 1e9) then log.chatter = (log.chatter or 0) + math.abs(f - force) end
    force = f
    if grip and not log.gripAt then log.gripAt = t end
    for _ = 1, sub do
      local h = dt / sub
      local tau = devSign * force * tmax - 0.02 * w * RAD_PER_RAW
      if opts.hand then tau = tau + opts.hand(t, p, w) end
      local wr = w * RAD_PER_RAW
      if math.abs(wr) < 1e-3 and math.abs(tau) <= fric then
        wr = 0
      else
        local sgn = wr ~= 0 and (wr > 0 and 1 or -1) or (tau > 0 and 1 or -1)
        wr = wr + (tau - sgn * fric) / J * h
      end
      w = wr / RAD_PER_RAW
      p = p + w * h
      if p > 1 then p, w = 1, 0 elseif p < -1 then p, w = -1, 0 end
    end
    t = t + dt
    log.errAt[#log.errAt + 1] = { t = t, e = target - p, p = p, target = target }
  end
  log.spring = s
  return log
end

local function errAfter(log, t0)
  local m = 0
  for _, r in ipairs(log.errAt) do if r.t > t0 then m = math.max(m, math.abs(r.e)) end end
  return m
end

local function overshoot(log, target)
  local m = 0
  for _, r in ipairs(log.errAt) do if r.p > target then m = math.max(m, r.p - target) end end
  return m
end

-- 1. step to 135 deg: settles, small overshoot, across inertias
for _, J in ipairs({ 0.015, 0.03, 0.06 }) do
  local r = run({ J = J, target = function() return 0.3 end, T = 3 })
  check(errAfter(r, 1.5) < 0.03, string.format('J=%.3f settles, err %.3f', J, errAfter(r, 1.5)))
  check(overshoot(r, 0.3) < 0.05, string.format('J=%.3f overshoot %.3f', J, overshoot(r, 0.3)))
  check(r.gripAt == nil, 'no false grip on a step, J=' .. J)
end

-- 2. tracks a turn (90 deg of wheel over ~1 s, hold, unwind)
do
  local function turn(t)
    if t < 0.5 then return 0 elseif t < 1.5 then return (t - 0.5) * 0.2 elseif t < 3 then return 0.2 elseif t < 4 then return 0.2 - (t - 3) * 0.2 end
    return 0
  end
  local r = run({ target = turn, T = 5 })
  check(errAfter(r, 0.3) < 0.08, 'tracks a turn, max err ' .. errAfter(r, 0.3))
  check(r.gripAt == nil, 'no false grip while tracking')
end

-- 3. inverted force direction: learns the sign and still gets there
do
  local r = run({ devSign = -1, target = function() return 0.25 end, T = 4 })
  check(r.spring.flips >= 1, 'flips when the wheel runs away')
  check(errAfter(r, 3) < 0.08, 'inverted wheel settles, err ' .. errAfter(r, 3))
end

-- 4. a hand holding the wheel near center while the target is at 90 deg -> grip
do
  local r = run({
    target = function(t) return t > 0.5 and 0.2 or 0 end,
    hand = function(_, p, w) return -40 * p * RAD_PER_RAW - 1.5 * w * RAD_PER_RAW end, -- stiff arm
    T = 3,
  })
  check(r.gripAt ~= nil and r.gripAt < 1.6, 'detects a grip, at ' .. tostring(r.gripAt))
end

do
  -- in-game: "the wheel moves but it's shaky". Holding a steady turn with FSD's target
  -- arriving in 10 Hz steps (plus a little noise), the motor force must not chatter.
  local log = run({ T = 5, chatterFrom = 2, target = function(t)
    local base = 0.25
    local step = math.floor(t * 10) / 10 -- planner updates at 10 Hz
    return base + 0.01 * math.sin(step * 7.3)
  end })
  check((log.chatter or 0) < 1.0, string.format('steady turn: motor force barely chatters (sum |dF| %.2f over 3 s)', log.chatter or 0))
  check(errAfter(log, 2) < 0.03, string.format('steady turn: holds the angle (err %.3f)', errAfter(log, 2)))
end

-- 5. light touch vs firm turn (takeover level)
do
  local function hold(at, level)
    return run({
      gripScale = W.takeoverLimit(level) / 0.15,
      target = function(t) return t > 0.5 and 0.2 or 0 end,
      hand = function(t, p, w) if t < 1 then return 0 end return -40 * (p - at) * RAD_PER_RAW - 1.5 * w * RAD_PER_RAW end,
      T = 4,
    })
  end
  check(hold(0.15, 'light').gripAt ~= nil, 'light level: a modest push (0.05 off) counts as taking over')
  check(hold(0.185, 'normal').gripAt == nil, 'normal level: a light push (0.015 off) is only a nudge')
  check(hold(0.12, 'normal').gripAt ~= nil, 'normal level: holding the wheel 0.08 off takes over')
  check(hold(0.0, 'normal').gripAt ~= nil, 'normal level: holding the wheel well away takes over')
  check(hold(0.0, 'firm').gripAt ~= nil, 'firm level: a real grip still takes over')
  check(W.nudgeBias(0.02, 0.25) == 0, 'no nudge inside the dead zone')
  check(W.nudgeBias(0.12, 0.25) > 0 and W.nudgeBias(-0.12, 0.25) < 0, 'a light push steers the car a little, either way')
  check(W.nudgeBias(0.3, 0.25) == 0, 'past the limit it is a takeover, not a nudge')
  check(W.nudgeBias(0.2, 0.25) <= 0.12, 'the nudge is small')
end

do
  local bound = true
  for i = 0, 400 do
    local t = i / 30
    for _, hp in ipairs({ -1, -0.2, 0, 0.3, 1 }) do
      local x = W.roadTexture(hp, 20, t, 2)
      if math.abs(x) > 0.7 + 1e-9 then bound = false end
    end
  end
  check(bound, 'road texture stays bounded (max 0.35 * gain)')
  check(W.roadTexture(0.4, 20, 0.3, 0) == 0, 'road feel 0 = off')
  local calm, rough = 0, 0
  for i = 0, 300 do calm = math.max(calm, math.abs(W.roadTexture(0.01, 20, i / 30, 1))); rough = math.max(rough, math.abs(W.roadTexture(0.6, 20, i / 30, 1))) end
  check(rough > calm * 2, string.format('a bump is felt much more than a smooth road (%.3f vs %.3f)', rough, calm))
  check(W.roadTexture(0, 0, 0.1, 1) == 0 or math.abs(W.roadTexture(0, 0, 0.1, 1)) < 0.01, 'standing still: no texture')
end

-- 6. taking over: the wheel starts where the hand holds it (no snap), and a shaking force backs off
do
  -- FSD engages while the wheel is 0.4 off target: the first force must be small (starts from the wheel's position)
  local s = W.new()
  local f0 = s:update(1 / 60, 0.0, 0.4, 1, 1)
  check(math.abs(f0) < 0.15, 'no snap to the target when it takes over: first force ' .. string.format('%.3f', f0))
  -- a wheel that rings (force flipping sign every frame) gets softened
  local s2 = W.new()
  s2.ramp = 1
  local big = 0
  for i = 1, 240 do
    local pos = (i % 2 == 0) and 0.08 or -0.08
    local f = s2:update(1 / 60, 0, pos, 1, 1)
    if i > 200 then big = math.max(big, math.abs(f)) end
  end
  local s3 = W.new(); s3.ramp = 1
  local bigNoGuard = 0
  for i = 1, 20 do local f = s3:update(1 / 60, 0, (i % 2 == 0) and 0.08 or -0.08, 1, 1); bigNoGuard = math.max(bigNoGuard, math.abs(f)) end
  check(big < bigNoGuard, string.format('a chattering force is softened (%.2f vs %.2f)', big, bigNoGuard))
end

print(string.format('%d passed, %d failed', passes, failures))
os.exit(failures == 0 and 0 or 1)
