package.path = 'beamng/test/?.lua;beamng/mod/lua/common/?.lua;' .. package.path
local F = require('teslaBridge/steerfeel')
local failures, passes = 0, 0
local function check(c, m) if c then passes = passes + 1 else failures = failures + 1; print('FAIL: ' .. m) end end
local T = F.torque

check(T{ pos = 0, vel = 0, v = 20 } == 0, 'nothing pushes a centred, still wheel')
check(T{ pos = 0.3, vel = 0, v = 20 } < 0 and T{ pos = -0.3, vel = 0, v = 20 } > 0, 'the wheel is pulled back toward centre, either side')
check(math.abs(T{ pos = 0.3, vel = 0, v = 20 } + T{ pos = -0.3, vel = 0, v = 20 }) < 1e-9, 'symmetric left and right')
local slow, fast = -T{ pos = 0.3, vel = 0, v = 2 }, -T{ pos = 0.3, vel = 0, v = 25 }
check(fast > slow * 2, string.format('heavier at speed than parked (%.3f vs %.3f)', fast, slow))
local noLat, lat = -T{ pos = 0.3, vel = 0, v = 20, latAcc = 0 }, -T{ pos = 0.3, vel = 0, v = 20, latAcc = 7 }
check(lat > noLat, 'cornering load adds self-aligning force')
-- levels out with angle rather than growing without bound
local a1, a2 = -T{ pos = 0.5, vel = 0, v = 20 }, -T{ pos = 1.0, vel = 0, v = 20 }
check(a2 >= a1 and a2 < a1 * 1.5, string.format('self-aligning levels out (%.3f -> %.3f)', a1, a2))
-- friction and damping oppose motion
local still, moving = T{ pos = 0.3, vel = 0, v = 10 }, T{ pos = 0.3, vel = 1.0, v = 10 }
check(moving < still, 'a wheel moving outward is resisted')
check(T{ pos = 0.3, vel = -1.0, v = 10 } > still, 'a wheel moving back is resisted the other way')
-- steering weight
local l, s, h = -T{ pos = 0.3, vel = 0, v = 20, weight = 'light' }, -T{ pos = 0.3, vel = 0, v = 20 }, -T{ pos = 0.3, vel = 0, v = 20, weight = 'heavy' }
check(l < s and s < h, string.format('light < standard < heavy (%.3f %.3f %.3f)', l, s, h))
-- bounded, and no chatter at centre: smooth across zero
local bounded = true
for _, pos in ipairs({ -1, -0.5, 0, 0.5, 1 }) do for _, vel in ipairs({ -8, 0, 8 }) do for _, v in ipairs({ 0, 10, 40 }) do
  if math.abs(T{ pos = pos, vel = vel, v = v, latAcc = 12, weight = 'heavy', gain = 2 }) > 1 then bounded = false end
end end end
check(bounded, 'always within -1..1')
local jump = 0
local prev = T{ pos = -0.05, vel = 0, v = 20 }
for i = -49, 50 do local f = T{ pos = i / 1000, vel = 0, v = 20 }; jump = math.max(jump, math.abs(f - prev)); prev = f end
check(jump < 0.03, string.format('smooth through centre (largest step %.4f)', jump))

print(string.format('%d passed, %d failed', passes, failures))
os.exit(failures == 0 and 0 or 1)
