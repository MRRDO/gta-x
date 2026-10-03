-- teslaBridge/judge.lua
-- Decision quality: makes sure FSD's choices are reasonable over time, not just each tick.
--   * commitment: a lane change that was just made isn't reversed a moment later unless there is
--     a real reason (route / merge) or a clear benefit (the lane we're in turned out much slower)
--   * confusion: stopped for no reason FSD can name (no light, sign, car, pedestrian, maneuver)
--     -> re-plan, then reset what may be jamming it, then say so and ask the driver
-- Cheap: a few comparisons per tick. Pure Lua (tested in beamng/test/).

local M = {}

local Judge = {}
Judge.__index = Judge

M.REVERSAL_HOLD = 30   -- s: no discretionary lane change back to where we just came from
M.SETTLE = 12          -- s: no discretionary change at all right after one
M.STUCK_REPLAN = 5     -- s of unexplained stillness -> re-plan
M.STUCK_RESET = 11     -- -> forget the stop/turn state that may be jamming it
M.STUCK_ASK = 22       -- -> ask the driver

function M.new()
  return setmetatable({ last = nil, still = 0, level = 0, why = nil }, Judge)
end

-- FSD (or the driver) changed lane
function Judge:laneChanged(t, from, to, reason)
  self.last = { t = t, from = from, to = to, reason = reason }
end

local FORCED = { route = true, merge = true, moveOver = true, driver = true, emergency = true }

-- May a change to lane `to` (from `cur`) for `reason` go ahead? benefit = m/s the target lane's
-- lead is faster than ours (nil = unknown / none). Returns ok, why.
function Judge:allowLane(t, cur, to, reason, benefit)
  if FORCED[reason] then return true end
  local l = self.last
  if not l then return true end
  local age = t - l.t
  if age < M.SETTLE then return false, 'settling' end
  -- (coming back to the right after passing is the plan, not a reversal: it just waits out the settle time)
  if to == l.from and reason ~= 'return' and age < M.REVERSAL_HOLD and (benefit or 0) < 5 then return false, 'reversal' end
  return true
end

-- Track unexplained stillness. `s` = { engaged, v, explained = why-string or nil, dt }.
-- Returns level (0 fine, 1 re-plan, 2 reset, 3 ask driver) and the level only when it just rose.
function Judge:watchStuck(t, s)
  if not s.engaged or (s.v or 0) > 0.6 or s.explained then
    self.still, self.level, self.why = 0, 0, nil
    return 0, nil
  end
  self.still = self.still + (s.dt or 0.1)
  local lvl = self.still >= M.STUCK_ASK and 3 or self.still >= M.STUCK_RESET and 2 or self.still >= M.STUCK_REPLAN and 1 or 0
  local rose = lvl > self.level and lvl or nil
  self.level = lvl
  return lvl, rose
end

return M
