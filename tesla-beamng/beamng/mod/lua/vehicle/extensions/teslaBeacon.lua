-- teslaBeacon (vehicle extension, loaded into cars near the player)
-- Reports whether this car's emergency lights (lightbar) are on, twice a second,
-- so FSD can pull over for police / ambulances / fire trucks.

local M = {}

local timer = 0
local last = nil

local function updateGFX(dt)
  timer = timer - dt
  if timer > 0 then return end
  timer = 0.5
  local e = electrics and electrics.values or {}
  local lb = tonumber(e.lightbar) or 0
  local hz = (e.hazard_enabled == true or e.hazard_enabled == 1) and 1 or 0
  local key = lb .. ',' .. hz
  -- always send while lights are on (the GE side times reports out), else only on change
  if lb > 0 or key ~= last then
    last = key
    obj:queueGameEngineLua(string.format('if teslaBridge then teslaBridge.onBeacon(%d, %d, %d) end', obj:getID(), lb, hz))
  end
end

M.updateGFX = updateGFX
return M
