-- teslaBridge/drift.lua
-- Furious profile stunt: a handbrake-and-throttle drift through a corner. EXPERIMENTAL: how a real
-- BeamNG car reacts (spin? slide?) can only be tuned in the game, so everything here is small,
-- bounded and easy to switch off (setting `drift: false`).
--
--   update(dt, in) -> { pb (0..1), throttleMin (0..1), phase }
--   in = { allowed (bool), v (m/s), kAhead (|curvature| 1/m in the next ~12-35 m), yawRate (rad/s), t }
-- Phases: idle -> kick (handbrake for 0.35 s, throttle to the floor) -> slide (throttle held, the
-- normal steering catches the car) -> idle, with a cooldown. It bails out (throttle off, no handbrake)
-- if the car rotates too fast, the corner is over, or it takes too long.

local M = {}
local abs, max = math.abs, math.max

local KICK_T, SLIDE_MAX, COOLDOWN = 0.35, 2.4, 6
local V_MIN, V_MAX = 9, 26     -- m/s: below there's nothing to slide, above it's a rollover
local K_MIN = 0.04             -- a corner of radius 25 m or tighter
local YAW_BAIL = 1.3           -- rad/s

local D = {}
D.__index = D

function M.new() return setmetatable({ phase = 'idle', t0 = 0, coolUntil = -1e9 }, D) end

function D:reset() self.phase, self.coolUntil = 'idle', -1e9 end

function D:update(dt, s)
  local t = s.t or 0
  -- (practice runner) tuned values replace the constants
  local tn = s.tune or {}
  local KICK_T, SLIDE_MAX = tonumber(tn.kick) or KICK_T, tonumber(tn.slideMax) or SLIDE_MAX
  local V_MIN, K_MIN, YAW_BAIL = tonumber(tn.vMin) or V_MIN, tonumber(tn.kMin) or K_MIN, tonumber(tn.yawBail) or YAW_BAIL
  local out = { pb = 0, throttleMin = 0, phase = self.phase }
  local v, yaw = s.v or 0, abs(s.yawRate or 0)
  if not s.allowed or v < V_MIN * 0.7 or v > V_MAX * 1.15 then
    if self.phase ~= 'idle' then self.phase, self.coolUntil = 'idle', t + COOLDOWN end
    out.phase = self.phase
    return out
  end
  if self.phase == 'idle' then
    if t >= self.coolUntil and v >= V_MIN and v <= V_MAX and (s.kAhead or 0) > K_MIN and yaw < 0.4 then
      self.phase, self.t0 = 'kick', t
    end
  end
  if self.phase == 'kick' then
    out.pb, out.throttleMin = 1, 1
    if t - self.t0 >= KICK_T then self.phase, self.t0 = 'slide', t end
  elseif self.phase == 'slide' then
    out.throttleMin = 0.6
    local over = (s.kAhead or 0) < K_MIN * 0.4 and t - self.t0 > 0.6
    if yaw > YAW_BAIL or over or t - self.t0 > SLIDE_MAX then
      self.phase, self.coolUntil = 'idle', t + COOLDOWN
      out.throttleMin = 0
    end
  end
  if yaw > YAW_BAIL and self.phase ~= 'idle' then
    self.phase, self.coolUntil = 'idle', t + COOLDOWN
    out.pb, out.throttleMin = 0, 0
  end
  out.phase = self.phase
  return out
end

M.K_MIN, M.V_MIN, M.V_MAX = K_MIN, V_MIN, V_MAX
return M
