-- teslaBridge/camgov.lua
-- Keeps the cameras from costing frame rate. Every screenshot the cameras take is extra
-- rendering, so when the game's fps falls the governor slows them, then pauses them, and only
-- speeds them up again once the fps has been good for a while. Pure Lua (tested in beamng/test/).
--
--   level 0 = the fps the user asked for, 1 = half, 2 = a quarter, 3 = paused
--   update(t, fps) -> scale (1, 0.5, 0.25, 0), level, changed

local M = {}
local Gov = {}
Gov.__index = Gov

local SCALE = { [0] = 1, 0.5, 0.25, 0 }

-- opts.low: fps under which it steps down (default 30); opts.crit: straight to paused (default 18);
-- opts.good: fps needed to step back up (default 45)
function M.new(opts)
  opts = opts or {}
  return setmetatable({
    low = opts.low or 30, crit = opts.crit or 18, good = opts.good or 45,
    level = 0, lowSince = nil, goodSince = nil, pausedAt = nil, lastChange = -1e9,
  }, Gov)
end

function Gov:update(t, fps)
  local old = self.level
  if fps then
    if fps < self.crit and t - self.lastChange > 0.5 then
      self.level = 3
    elseif fps < self.low then
      self.goodSince = nil
      self.lowSince = self.lowSince or t
      if t - self.lowSince > 1.0 and self.level < 3 then
        self.level = self.level + 1
        self.lowSince = t -- judge the new level for another second before stepping again
      end
    else
      self.lowSince = nil
      if self.level == 3 then
        -- paused: no camera load now, so a good fps says little; retry after a rest
        self.pausedAt = self.pausedAt or t
        if t - self.pausedAt > 8 and fps >= self.good then self.level = 2; self.pausedAt = nil end
      elseif self.level > 0 and fps >= self.good then
        self.goodSince = self.goodSince or t
        if t - self.goodSince > 4 then self.level = self.level - 1; self.goodSince = nil end
      else
        self.goodSince = nil
      end
    end
  end
  if self.level ~= 3 then self.pausedAt = nil end
  local changed = self.level ~= old
  if changed then self.lastChange = t end
  return SCALE[self.level], self.level, changed
end

M.SCALE = SCALE
return M
