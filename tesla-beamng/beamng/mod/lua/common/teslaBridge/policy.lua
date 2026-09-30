-- teslaBridge/policy.lua
-- Runs a small neural network trained on Quentin's driving (rl/train_bc.py -> policy.json).
-- Phase 1 use: an ADVISORY pedal suggestion (-1 brake .. +1 accelerate) that the planner may
-- blend in a little; it can never override the safety layer or the speed limits. Off by default.
-- Cost: 7*16 + 16*16 + 16 multiply-adds (about 400) per call, a few microseconds; call it at
-- 10 Hz or less. Pure Lua (tested in beamng/test/).

local M = {}
local tanh = function(x) if x > 20 then return 1 elseif x < -20 then return -1 end local e = math.exp(2 * x); return (e - 1) / (e + 1) end

local Policy = {}
Policy.__index = Policy

-- spec = decoded policy.json ({ names, scale, layers = { { w, b, act } } })
function M.new(spec)
  if type(spec) ~= 'table' or type(spec.layers) ~= 'table' or #spec.layers == 0 then return nil end
  local n = #spec.layers[1].w[1]
  if spec.scale and #spec.scale ~= n then return nil end
  return setmetatable({ spec = spec, n = n, bufA = {}, bufB = {} }, Policy)
end

local function clip(x) if x > 1.5 then return 1.5 elseif x < -1.5 then return -1.5 end return x end

-- obs = raw observation in spec.names order (same units features.py uses)
function Policy:act(obs)
  local sc = self.spec.scale
  local a = self.bufA
  for i = 1, self.n do a[i] = clip(obs[i] / (sc and sc[i] or 1)) end
  local cur, nxt = a, self.bufB
  local width = self.n
  for _, L in ipairs(self.spec.layers) do
    local rows = #L.w
    for r = 1, rows do
      local w, s = L.w[r], L.b[r]
      for c = 1, width do s = s + w[c] * cur[c] end
      nxt[r] = tanh(s)
    end
    cur, nxt = nxt, cur
    width = rows
  end
  return cur[1]
end

return M
