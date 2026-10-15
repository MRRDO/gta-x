package.path = 'beamng/test/?.lua;beamng/mod/lua/common/?.lua;' .. package.path
local L = require('teslaBridge/lightshow')
local failures, passes = 0, 0
local function check(c, m) if c then passes = passes + 1 else failures = failures + 1; print('FAIL: ' .. m) end end

check(#L.names() >= 4, 'has the shows: ' .. table.concat(L.names(), ','))
for _, name in ipairs(L.names()) do
  local len = L.length(name)
  local changes, last, done = 0, nil, false
  for i = 0, math.floor(len * 20) do
    local t = i / 20
    local s, d = L.state(name, t)
    local key = table.concat({ tostring(s.low), tostring(s.high), tostring(s.fog), tostring(s.left), tostring(s.right), tostring(s.hazard) }, ',')
    if key ~= last then changes = changes + 1; last = key end
    check(not (s.left and s.right and not s.hazard and name ~= 'strobe' and name ~= 'holiday'), name .. ': never both blinkers by accident at t=' .. t)
  end
  local _, dEnd = L.state(name, len + 0.1)
  check(dEnd, name .. ': ends')
  local s = L.state(name, len + 0.1)
  check(not (s.low or s.high or s.fog or s.left or s.right or s.hazard), name .. ': lights back off at the end (the car restores them)')
  check(changes > 3, name .. ': actually animates (' .. changes .. ' changes)')
end
-- the show is a pure function: same time, same state
local a, b = L.state('holiday', 12.34), L.state('holiday', 12.34)
check(a.high == b.high and a.fog == b.fog and a.left == b.left, 'deterministic')
check(L.length('nope') == nil and select(2, L.state('nope', 0)), 'unknown show is done at once')

print(string.format('%d passed, %d failed', passes, failures))
os.exit(failures == 0 and 0 or 1)
