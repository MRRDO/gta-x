package.path = 'beamng/test/?.lua;beamng/mod/lua/common/?.lua;' .. package.path
local G = require('teslaBridge/camgov')
local failures, passes = 0, 0
local function check(c, m) if c then passes = passes + 1 else failures = failures + 1; print('FAIL: ' .. m) end end
local function run(g, t0, secs, fps)
  local sc, lv, ch
  for i = 0, secs * 10 do sc, lv, ch = g:update(t0 + i / 10, type(fps) == 'function' and fps(t0 + i / 10) or fps) end
  return sc, lv, t0 + secs
end

-- smooth game: full speed
local g = G.new()
local sc, lv = run(g, 0, 30, 60)
check(sc == 1 and lv == 0, 'a healthy game keeps the cameras at full rate')

-- fps sags a bit: steps down gradually, not straight to off
g = G.new()
sc, lv = run(g, 0, 1.5, 25)
check(lv == 1 and sc == 0.5, 'a mild dip halves the camera rate: level ' .. lv)
sc, lv = run(g, 1.5, 3, 25)
check(lv >= 2, 'a lasting dip goes to a quarter: level ' .. lv)

-- a bad dip pauses at once
g = G.new()
sc, lv = run(g, 0, 1, 10)
check(lv == 3 and sc == 0, 'a collapse pauses the cameras')

-- recovers only after a good stretch, one step at a time
g = G.new()
local t
sc, lv, t = run(g, 0, 1.5, 25)      -- level 1
sc, lv, t = run(g, t, 3, 60)        -- 3 s of good fps: not yet
check(lv == 1, 'not back up after 3 s of good fps: ' .. lv)
sc, lv, t = run(g, t, 3, 60)
check(lv == 0 and sc == 1, 'back to full after a sustained good stretch: ' .. lv)

-- paused: comes back to a quarter after resting, not full
g = G.new()
sc, lv, t = run(g, 0, 1, 10)
sc, lv, t = run(g, t, 5, 60)
check(lv == 3, 'still paused after 5 s')
sc, lv, t = run(g, t, 5, 60)
check(lv == 2, 'tries again at a quarter after resting: ' .. lv)

-- no fps reading: nothing changes
g = G.new()
for i = 1, 50 do g:update(i / 10, nil) end
check(g.level == 0, 'no reading, no change')

-- flapping fps around the threshold does not flap the cameras every tick
g = G.new()
local changes = 0
for i = 0, 600 do
  local _, _, ch = g:update(i / 10, (i % 2 == 0) and 28 or 33)
  if ch then changes = changes + 1 end
end
check(changes <= 3, 'borderline fps changes the level rarely: ' .. changes)

print(string.format('%d passed, %d failed', passes, failures))
os.exit(failures == 0 and 0 or 1)
