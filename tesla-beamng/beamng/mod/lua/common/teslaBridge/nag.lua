-- teslaBridge/nag.lua
-- Driver supervision like FSD (Supervised): the app's cabin camera reports
-- attention (ok / phone / eyesOff / unknown) and the wheel reports nudges.
-- Escalates: 1 "Pay attention to the road" (blue flash) -> 2 beeping ->
-- 3 "Take over immediately" (red). Ignored at 3 -> the car slows to a stop with
-- hazards, FSD shuts off and you get a strike. 5 strikes -> FSD locked out for
-- the rest of the drive. Pure Lua (tested in beamng/test/).

local M = {}

local MAX_STRIKES = 5
M.MAX_STRIKES = MAX_STRIKES

-- seconds of inattention before level 1, per profile (Hurry / Mad Max ask for more attention)
local CAMERA_GRACE = { sloth = 5, chill = 5, standard = 4, hurry = 3, madmax = 2.5 }
-- with no camera: seconds between required wheel nudges
local NUDGE_INTERVAL = { sloth = 45, chill = 45, standard = 30, hurry = 25, madmax = 20 }
local STEP = 5        -- seconds per escalation level
local FORCE_AFTER = 5 -- seconds at level 3 before the car stops itself

local Nag = {}
Nag.__index = Nag

function M.new()
  return setmetatable({
    level = 0, reason = nil, strikes = 0, lockedOut = false,
    badSince = nil, lastNudge = 0, level3Since = nil, forcing = false,
    enabled = true,
  }, Nag)
end

-- A wheel nudge / "I'm here" tap. Clears levels 1-2 (not 3: you must take over).
function Nag:nudge(t)
  self.lastNudge = t
  if self.level < 3 then self.level, self.reason, self.badSince = 0, nil, nil end
end

-- Called when the driver takes over (any disengage). Level 3 answered in time: no strike.
function Nag:onDisengage()
  self.level, self.reason, self.badSince, self.level3Since, self.forcing = 0, nil, nil, nil, false
end

-- New drive (level reload): strikes stay (Tesla keeps them), lockout ends only on reset.
function Nag:reset()
  self.strikes, self.lockedOut = 0, false
  self:onDisengage()
end

-- att = { state = 'ok'|'phone'|'eyesOff'|'unknown', t = time of the report }
-- Returns { level, reason, events = {...}, forceStop = bool, strike = bool }
function Nag:tick(t, engaged, profile, att)
  local out = { events = {} }
  if not engaged or not self.enabled then
    self.badSince, self.level3Since, self.forcing = nil, nil, false
    if self.level ~= 0 then self.level, self.reason = 0, nil; out.events[#out.events + 1] = { kind = 'nag', level = 0 } end
    self.lastNudge = t
    out.level = 0
    return out
  end
  local camera = att and att.state and att.state ~= 'unknown' and (t - (att.t or -1e9)) < 3
  local target, reason = 0, nil
  if camera then
    if att.state == 'phone' or att.state == 'eyesOff' then
      self.badSince = self.badSince or t
      local grace = (CAMERA_GRACE[profile] or 4) * (att.state == 'phone' and 0.7 or 1)
      local bad = t - self.badSince
      if bad > grace then
        target = math.min(3, 1 + math.floor((bad - grace) / STEP))
        reason = att.state
      end
    else
      self.badSince = nil
    end
    -- a good camera report counts like a nudge for the no-camera fallback
    if att.state == 'ok' then self.lastNudge = t end
  else
    self.badSince = nil
    local interval = NUDGE_INTERVAL[profile] or 30
    local since = t - self.lastNudge
    if since > interval then
      target = math.min(3, 1 + math.floor((since - interval) / (STEP * 2)))
      reason = 'hands'
    end
  end
  -- level 3 latches until the driver takes over or the car stops itself
  if self.level == 3 then target, reason = 3, self.reason end
  if target ~= self.level then
    self.level, self.reason = target, reason
    out.events[#out.events + 1] = { kind = 'nag', level = target, reason = reason }
    if target == 3 then self.level3Since = t end
  end
  if self.level == 3 and self.level3Since and t - self.level3Since > FORCE_AFTER then
    if not self.forcing then
      self.forcing = true
      out.events[#out.events + 1] = { kind = 'nag', level = 3, reason = self.reason, forcing = true }
    end
    out.forceStop = true
  end
  out.level, out.reason = self.level, self.reason
  return out
end

-- The car finished its forced stop: FSD off, strike, maybe lockout.
function Nag:strike()
  self.strikes = self.strikes + 1
  local ev = { { kind = 'strike', strikes = self.strikes, max = MAX_STRIKES } }
  if self.strikes >= MAX_STRIKES and not self.lockedOut then
    self.lockedOut = true
    ev[#ev + 1] = { kind = 'lockout', strikes = self.strikes }
  end
  self:onDisengage()
  return ev
end

function Nag:status()
  return { level = self.level, reason = self.reason, strikes = self.strikes, maxStrikes = MAX_STRIKES, lockedOut = self.lockedOut }
end

return M
