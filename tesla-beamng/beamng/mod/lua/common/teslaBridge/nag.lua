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
-- Driver monitoring modes (setting nagMode): 'off' | 'camera' (the iPad cabin camera
-- watches your eyes) | 'wheel' (a hands-on-wheel nudge every once in a while) | 'auto'
-- (camera while it reports, else wheel). In wheel mode the interval depends on the road:
local function wheelFactor(ctx)
  local v, lim = ctx and ctx.v or 0, ctx and ctx.limit
  if v < 8.9 then return 2.0 end                                    -- under ~20 mph: traffic, lots
  if (lim and lim >= 22.3) or (ctx and ctx.highway) then return 1.6 end -- freeway / 50+ mph roads
  if v >= 11 and v <= 20.2 then return 0.7 end                      -- city streets, 25-45 mph
  return 1.0
end
M.wheelFactor = wheelFactor
local CAMERA_LOST = 5 -- s without camera reports in camera mode -> fall back to the wheel

local STEP = 5        -- seconds per escalation level
local FORCE_AFTER = 5 -- seconds at level 3 before the car stops itself

local Nag = {}
Nag.__index = Nag

function M.new()
  return setmetatable({
    level = 0, reason = nil, strikes = 0, lockedOut = false,
    badSince = nil, lastNudge = 0, level3Since = nil, forcing = false,
    enabled = true, mode = 'auto', jitter = 1, rng = math.random,
    active = 'wheel', interval = nil, cameraLost = false,
  }, Nag)
end

-- A wheel nudge / "I'm here" tap. Clears levels 1-2 (not 3: you must take over).
function Nag:nudge(t)
  self.lastNudge = t
  self.jitter = 0.8 + 0.4 * self.rng() -- "every once in a while", not a metronome
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
function Nag:tick(t, engaged, profile, att, ctx)
  local out = { events = {} }
  if not engaged or not self.enabled or self.mode == 'off' then
    self.badSince, self.level3Since, self.forcing = nil, nil, false
    if self.level ~= 0 then self.level, self.reason = 0, nil; out.events[#out.events + 1] = { kind = 'nag', level = 0 } end
    self.lastNudge = t
    out.level = 0
    return out
  end
  local fresh = att and att.state and att.state ~= 'unknown' and (t - (att.t or -1e9)) < 3
  local camera = fresh
  if self.mode == 'wheel' then camera = false end
  if self.mode == 'camera' then
    -- camera only; if it stops reporting for a while, fall back to the wheel and say so
    local lost = not fresh and (t - (att and att.t or -1e9)) > CAMERA_LOST
    if lost ~= self.cameraLost then
      self.cameraLost = lost
      out.events[#out.events + 1] = { kind = 'monitoring', state = lost and 'cameraUnavailable' or 'camera' }
      if lost then self.lastNudge = t end
    end
    camera = fresh
  end
  self.active = camera and 'camera' or 'wheel'
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
    local interval = (NUDGE_INTERVAL[profile] or 30) * (self.jitter or 1)
    if self.mode == 'wheel' or self.mode == 'camera' then interval = interval * wheelFactor(ctx) end
    self.interval = interval
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
  return { level = self.level, reason = self.reason, strikes = self.strikes, maxStrikes = MAX_STRIKES, lockedOut = self.lockedOut,
    mode = (not self.enabled) and 'off' or self.mode, active = self.active,
    interval = self.active == 'wheel' and self.interval and math.floor(self.interval + 0.5) or nil }
end

return M
