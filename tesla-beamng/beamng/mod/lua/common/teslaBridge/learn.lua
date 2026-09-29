-- teslaBridge/learn.lua
-- Very light on-line learning of Quentin's driving style (a few numbers, no training loop):
--  * manual driving (FSD off): an average of how fast he goes relative to the limit and how
--    big a gap he keeps, per road type (slow / city / fast), only in free-flowing driving
--  * FSD on: the accelerator held = "go faster" (small push up), a brake/wheel takeover while
--    over the limit = "slower" (push down), a takeover close behind a car = "wider gap"
-- Each bucket yields a speed scale (0.85 .. 1.2) and a gap scale (0.8 .. 1.4) that the planner
-- multiplies in, blended in slowly as evidence builds. Pure Lua; the GE saves/loads the table.

local M = {}

local BUCKETS = { 'slow', 'city', 'fast' }
local function clamp(v, lo, hi) if v < lo then return lo elseif v > hi then return hi end return v end

-- limit in m/s -> bucket
function M.bucket(limit)
  if not limit then return 'city' end
  if limit < 8.9 then return 'slow' end   -- under ~20 mph
  if limit >= 22.3 then return 'fast' end -- 50+ mph
  return 'city'
end

local function newBucket() return { pref = 1.0, prefN = 0, bias = 0, gapPref = 2.0, gapN = 0, gapBias = 0 } end

function M.new(data)
  local L = { b = {}, dirty = false }
  for _, k in ipairs(BUCKETS) do
    local d = data and data[k]
    L.b[k] = newBucket()
    if type(d) == 'table' then for f, v in pairs(d) do if type(v) == 'number' then L.b[k][f] = v end end end
  end
  return setmetatable(L, { __index = M })
end

function M:export() return self.b end

-- manual driving sample: v (m/s), limit (m/s), gap (s to the car ahead, nil = free road), dt
function M:watch(limit, v, gap, dt)
  if not limit or v < 4 then return end
  local b = self.b[M.bucket(limit)]
  local a = clamp(dt / 60, 0, 0.05) -- ~1 minute time constant
  if not gap or gap > 6 then
    b.pref = b.pref + (clamp(v / limit, 0.7, 1.4) - b.pref) * a
    b.prefN = b.prefN + dt
  elseif gap > 0.6 then
    b.gapPref = b.gapPref + (gap - b.gapPref) * a
    b.gapN = b.gapN + dt
  end
  self.dirty = true
end

-- FSD feedback. kind: 'faster' (accelerator held, dt seconds) | 'slower' (took over while
-- going faster than the limit) | 'wider' (took over close behind a car)
function M:feedback(limit, kind, dt)
  local b = self.b[M.bucket(limit)]
  if kind == 'faster' then b.bias = clamp(b.bias + 0.004 * (dt or 0.5), -0.12, 0.12)
  elseif kind == 'slower' then b.bias = clamp(b.bias - 0.03, -0.12, 0.12)
  elseif kind == 'wider' then b.gapBias = clamp(b.gapBias + 0.06, -0.2, 0.4) end
  self.dirty = true
end

-- multipliers for the planner
function M:speedScale(limit)
  local b = self.b[M.bucket(limit)]
  local w = clamp(b.prefN / 600, 0, 1) -- trust the average after ~10 minutes of free driving
  return clamp(1 + w * (b.pref - 1.0) * 0.6 + b.bias, 0.85, 1.2)
end

function M:gapScale(limit)
  local b = self.b[M.bucket(limit)]
  local w = clamp(b.gapN / 300, 0, 1)
  return clamp(1 + w * (b.gapPref / 2.0 - 1) * 0.5 + b.gapBias, 0.8, 1.4)
end

return M
