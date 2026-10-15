package.path = 'beamng/test/?.lua;beamng/mod/lua/common/?.lua;' .. package.path
local S = require('teslaBridge/score')
local failures, passes = 0, 0
local function check(c, m) if c then passes = passes + 1 else failures = failures + 1; print('FAIL: ' .. m) end end

-- calm drive: 15 m/s for 100 s with a good gap
local s = S.new()
for i = 1, 1000 do s:update(0.1, { v = 15, yawRate = 0.02, fsd = i > 300, gap = 2.5 }) end
local r = s:summary()
check(r.score >= 98, 'calm drive scores high: ' .. r.score)
check(math.abs(r.km - 1.5) < 0.05, 'distance: ' .. r.km)
check(r.fsdPercent > 60 and r.fsdPercent < 80, 'fsd share: ' .. r.fsdPercent)
check(r.hardBrakes == 0 and not s.hazard, 'no hard brakes, no hazards')

-- one hard stop from 20 m/s at 7 m/s^2: counts once, hazards flash, score drops
s = S.new()
local v = 20
for i = 1, 100 do s:update(0.1, { v = 20, fsd = false }) end
for i = 1, 30 do v = math.max(0, v - 0.7); s:update(0.1, { v = v }) end
check(s.hardBrakes == 1, 'one hard brake counted once: ' .. s.hardBrakes)
check(s.hazard, 'emergency braking turns the hazards on')
-- moving off again clears them
for i = 1, 60 do v = math.min(12, v + 0.15); s:update(0.1, { v = v }) end
check(not s.hazard, 'hazards go off once the car is moving again')
check(s:score() < 100, 'score drops after a hard brake: ' .. s:score())

-- gentle stop does not count
s = S.new()
v = 20
for i = 1, 100 do s:update(0.1, { v = 20 }) end
for i = 1, 100 do v = math.max(0, v - 0.2); s:update(0.1, { v = v }) end
check(s.hardBrakes == 0 and not s.hazard, 'a gentle stop is not a hard brake')

-- tailgating and takeovers cost points
s = S.new()
for i = 1, 600 do s:update(0.1, { v = 20, gap = 0.6 }) end
s:takeover()
check(s:summary().tailgatePercent > 90 and s:score() < 90, 'tailgating lowers the score: ' .. s:score())

-- hard corner counts once
s = S.new()
for i = 1, 30 do s:update(0.1, { v = 15, yawRate = 0.4 }) end
check(s.hardTurns == 1, 'a hard corner counts once: ' .. s.hardTurns)

print(string.format('%d passed, %d failed', passes, failures))
os.exit(failures == 0 and 0 or 1)
