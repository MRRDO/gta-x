-- Banish supervisor: a car that drives off by itself must never end up stopped in the road, so every step has a backup.
--
--   1. the nearest free spots, one after the other (a spot that is taken, has no way in, gets stuck, or is hit on the way is skipped)
--   2. before the next try after a stuck / hit / "in front of the car": back up a little (the nose may be against a pole or a wall)
--   3. no spot works: pull over at the edge of the road
--   4. pulling over does not work (a garage, no road): stop right where it is, in Park with the hazards on, and say so
--
-- Also a watchdog: not moving for a long time without a reason (a red light, a crossing pedestrian, a car ahead are reasons), or the
-- whole trip taking far too long, counts as a failure. It knows nothing about the game: GE passes the callbacks in.
--   cb.trySpot(id) -> true when a trip to that spot (or a direct park) has started
--   cb.backUp() -> true when a short reverse has started (the supervisor waits for onEvent('disengage', 'summon'))
--   cb.pullOver() -> true when a pull-over trip has started
--   cb.safeStop() -> stop here: P, hazards (always works)
--   cb.say(text) -> a notice for the app
local M = {}
M.__index = M

M.STALL_S = 28 -- not moving this long without a reason = stuck
M.TRIP_S = 480 -- a trip longer than this goes to the pull-over step

function M.new(cb)
  return setmetatable({ cb = cb, active = false }, M)
end

function M:start(spots, now)
  self.active = true
  self.spots = spots or {}
  self.idx = 0 -- the spot in use
  self.step = 'spots'
  self.t0, self.lastMove, self.pendingAt, self.pending = now, now, nil, nil
  self.failures = 0
  self.history = {}
end

function M:stop()
  self.active = false
  self.pending = nil
end

-- the first spot is chosen by the caller (its parkAtSpot already ran): remember which one
function M:started(idx) self.idx = idx or 1 end

local NEEDS_BACKUP = { stuck = true, hit = true, front = true, ['no progress'] = true }

function M:onFailure(reason, now)
  if not self.active or self.pending then return end
  self.failures = self.failures + 1
  self.history[#self.history + 1] = reason
  local kind = (reason:find('stuck') and 'stuck') or ((reason:find('hit') or reason:find('collision')) and 'hit') or (reason:find('in front') and 'front') or (reason:find('no progress') and 'no progress') or 'other'
  self.pending = { reason = reason, backup = NEEDS_BACKUP[kind] and self.step == 'spots' }
  self.pendingAt = now + 1.5 -- let the car come to rest first
end

-- What the planner reported. disengage with reason 'arrived' ends it well; a person taking over (app, brake, steering, pedal) ends it too;
-- anything else that turned FSD off is a failure; a finished backup (disengage 'summon') continues with the next spot.
function M:onEvent(kind, reason, detail, now)
  if not self.active then return end
  if kind == 'disengage' then
    if reason == 'arrived' then self:stop(); return end
    if reason == 'app' or reason == 'brake' or reason == 'steer' or reason == 'throttle' then self:stop(); return end
    if reason == 'summon' then
      if self.backingUp then
        self.backingUp = false
        self.pending, self.pendingAt = { reason = 'backed up', backup = false, resume = true }, now + 0.8
      end
      return
    end
    self:onFailure('stopped: ' .. tostring(detail or reason), now)
  elseif kind == 'error' then
    self.lastError = tostring(detail or '')
  end
end

-- one step of the cascade; returns what it did (for tests / logging)
function M:advance(now)
  local cb = self.cb
  local p = self.pending
  self.pending, self.pendingAt = nil, nil
  if p and p.backup and cb.backUp and cb.backUp() then
    self.backingUp = true
    cb.say('banish: backing up a little before trying again')
    return 'backup'
  end
  if self.step == 'spots' then
    while self.idx < #self.spots do
      self.idx = self.idx + 1
      if cb.trySpot(self.spots[self.idx]) then
        self.lastMove = now
        cb.say(string.format('banish: trying spot %d of %d', self.idx, #self.spots))
        return 'spot'
      end
    end
    self.step = 'pullover'
  end
  if self.step == 'pullover' then
    self.step = 'safestop'
    if cb.pullOver() then
      self.lastMove = now
      cb.say('banish: no spot worked, pulling over at the edge of the road')
      return 'pullover'
    end
  end
  self.step = 'done'
  cb.safeStop()
  cb.say('banish: could not park or pull over, stopped here with the hazards on')
  self:stop()
  return 'safestop'
end

-- called a few times a second. st = { moving = bool, reason = bool (it has a reason to stand: light, crossing, car ahead, a maneuver is running) }
function M:tick(now, st)
  if not self.active then return nil end
  if st.moving or st.reason then self.lastMove = now end
  if self.pending and now >= self.pendingAt then return self:advance(now) end
  if not self.pending then
    if now - self.lastMove > M.STALL_S then self:onFailure('no progress', now)
    elseif now - self.t0 > M.TRIP_S and self.step == 'spots' then self.idx = #self.spots; self:onFailure('trip took too long', now) end
  end
  return nil
end

return M
