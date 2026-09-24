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
  local s = W.new()
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
  check(errAfter(r, 3) < 0.04, 'inverted wheel settles, err ' .. errAfter(r, 3))
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

print(string.format('%d passed, %d failed', passes, failures))
os.exit(failures == 0 and 0 or 1)
