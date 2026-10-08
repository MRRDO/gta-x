-- Banish supervisor: every failure has a backup, and the last backup always stops the car safely. Run: luajit beamng/test/test_banish.lua
package.path = 'beamng/mod/lua/common/?.lua;' .. package.path
local B = require('teslaBridge/banish')
local fails, total = 0, 0
local function check(c, msg) total = total + 1; if not c then fails = fails + 1; print('FAIL: ' .. msg) end end

local function make(spec)
  local log = {}
  local sup = B.new({
    trySpot = function(id) log[#log + 1] = 'spot' .. id; return spec.spotOk == nil or spec.spotOk[id] end,
    backUp = function() log[#log + 1] = 'backup'; return spec.canBackUp ~= false end,
    pullOver = function() log[#log + 1] = 'pullover'; return spec.pullOk ~= false end,
    safeStop = function() log[#log + 1] = 'safestop' end,
    say = function() end,
  })
  return sup, log
end
local function drain(sup, t) for _ = 1, 40 do t = t + 2; sup:tick(t, { moving = true }) end return t end

-- 1. the first spot gets stuck: back up, then the second spot
do
  local sup, log = make({})
  sup:start({ 11, 12, 13 }, 0); sup:started(1)
  sup:onEvent('error', nil, 'backIn is stuck (something is in the way), stopped', 1)
  sup:onEvent('disengage', 'error', 'backIn stuck', 1)
  sup:tick(3, { moving = false })
  check(log[1] == 'backup', 'stuck: backs up first')
  sup:onEvent('disengage', 'summon', nil, 6)
  sup:tick(8, { moving = false })
  check(log[2] == 'spot12', 'then the next spot (' .. tostring(log[2]) .. ')')
  sup:onEvent('disengage', 'arrived', nil, 30)
  check(not sup.active, 'arrived ends the supervision')
end
-- 2. every spot fails: pull over
do
  local sup, log = make({ spotOk = { [11] = false, [12] = false }, canBackUp = false })
  sup:start({ 11, 12 }, 0)
  sup:onEvent('disengage', 'error', 'no route', 1)
  sup:tick(3, { moving = false })
  check(log[1] == 'spot11' and log[2] == 'spot12' and log[3] == 'pullover', 'all spots refused: pulls over (' .. table.concat(log, ',') .. ')')
end
-- 3. pulling over does not work either: safe stop, never nothing
do
  local sup, log = make({ spotOk = {}, pullOk = false })
  sup:start({ 11 }, 0)
  sup:onEvent('disengage', 'error', 'x', 1)
  sup:tick(3, { moving = false })
  check(log[#log] == 'safestop' and not sup.active, 'nothing works: stops safely with the hazards (' .. table.concat(log, ',') .. ')')
end
-- 4. the driver takes over: the supervisor lets go
do
  local sup = make({})
  sup:start({ 11 }, 0)
  sup:onEvent('disengage', 'steer', nil, 5)
  check(not sup.active, 'a person taking over ends it')
end
-- 5. watchdog: standing still without a reason is a failure; standing for a red light is not
do
  local sup, log = make({ canBackUp = false })
  sup:start({ 11, 12 }, 0); sup:started(1)
  for t = 1, 60 do sup:tick(t, { moving = false, reason = true }) end
  check(#log == 0, 'waiting at a light for 60 s is fine')
  local t = 61
  while t < 120 and #log == 0 do sup:tick(t, { moving = false }); t = t + 1 end
  check(table.concat(log, ','):find('spot12') ~= nil, 'no reason and no progress: next spot (' .. table.concat(log, ',') .. ')')
end
-- 6. a long failure history always ends: no endless loop
do
  local sup, log = make({ canBackUp = true })
  sup:start({ 1, 2, 3, 4, 5, 6 }, 0)
  local t = 0
  for _ = 1, 40 do
    sup:onEvent('disengage', 'error', 'stuck', t)
    t = t + 4; sup:tick(t, { moving = false })
    if sup.backingUp then sup:onEvent('disengage', 'summon', nil, t); t = t + 2; sup:tick(t, { moving = false }) end
    if not sup.active then break end
  end
  check(not sup.active, 'it ends after the spots are used up (' .. #log .. ' actions)')
  check(log[#log] == 'pullover' or log[#log] == 'safestop', 'last step is a pull over or a stop')
end
print(string.format('%d passed, %d failed', total - fails, fails))
os.exit(fails == 0 and 0 or 1)
