package.path = 'beamng/test/?.lua;beamng/mod/lua/common/?.lua;' .. package.path
local Dr = require('teslaBridge/drift')
local failures, passes = 0, 0
local function check(c, m) if c then passes = passes + 1 else failures = failures + 1; print('FAIL: ' .. m) end end

local function run(d, secs, s, t0)
  local pbT, maxPb, last = 0, 0, nil
  for i = 0, secs * 60 do
    s.t = (t0 or 0) + i / 60
    last = d:update(1 / 60, s)
    if last.pb > 0 then pbT = pbT + 1 / 60 end
    maxPb = math.max(maxPb, last.pb)
  end
  return pbT, last, (t0 or 0) + secs
end

-- a corner ahead at a good speed: kick (handbrake ~0.35 s), then slide, then done
local d = Dr.new()
local pbT, last = run(d, 0.5, { allowed = true, v = 16, kAhead = 0.08, yawRate = 0.1 })
check(pbT > 0.3 and pbT < 0.45, 'handbrake pulse about 0.35 s: ' .. string.format('%.2f', pbT))
pbT, last = run(d, 1.0, { allowed = true, v = 15, kAhead = 0.08, yawRate = 0.6 }, 0.5)
check(last.phase == 'slide' and last.throttleMin > 0.5, 'then slides with the throttle held')
pbT = run(d, 3, { allowed = true, v = 14, kAhead = 0.08, yawRate = 0.6 }, 1.5)
check(d.phase == 'idle', 'never slides longer than a couple of seconds')

-- never on a straight, too slow, too fast, or when not allowed
for name, s in pairs({
  straight = { allowed = true, v = 16, kAhead = 0.005, yawRate = 0 },
  slow = { allowed = true, v = 4, kAhead = 0.08, yawRate = 0 },
  fast = { allowed = true, v = 40, kAhead = 0.08, yawRate = 0 },
  notAllowed = { allowed = false, v = 16, kAhead = 0.08, yawRate = 0 },
}) do
  local dd = Dr.new()
  local t, l = run(dd, 4, s)
  check(t == 0 and l.throttleMin == 0, name .. ': no handbrake, no forced throttle')
end

-- the car starts rotating too fast: bail out at once
d = Dr.new()
run(d, 0.6, { allowed = true, v = 16, kAhead = 0.08, yawRate = 0.2 })
local _, l2 = run(d, 0.2, { allowed = true, v = 16, kAhead = 0.08, yawRate = 1.8 }, 0.6)
check(d.phase == 'idle' and l2.pb == 0 and l2.throttleMin == 0, 'a spin-out bails: no handbrake, throttle off')

-- cooldown: no second kick right away
d = Dr.new()
run(d, 6, { allowed = true, v = 16, kAhead = 0.08, yawRate = 0.1 })
local t3 = run(d, 2, { allowed = true, v = 16, kAhead = 0.08, yawRate = 0.1 }, 6)
check(t3 == 0, 'waits between drifts')

print(string.format('%d passed, %d failed', passes, failures))
os.exit(failures == 0 and 0 or 1)
