-- teslaBridge/launchreq.lua
-- Remote start support. The PC's launcher service (laptop/auto.mjs, driven from the phone/iPad companion page) starts
-- BeamNG and drops a small request file into the game's settings folder; this reads it. It also describes what the player
-- was last playing ("resume") and lists the levels and cars the game has (for "new world and car"), for the service to
-- show. Pure functions (no game API): the extension does the file and game calls. Tested in beamng/test/.
-- UNTESTED against the real game: the game-side calls in teslaBridge.lua are best effort and log what they do.

local M = {}

M.MAX_AGE = 600 -- seconds: an older request is a leftover from a game that never started

local function str(v, n)
  if type(v) ~= 'string' then return nil end
  v = v:gsub('[%c]', ''):sub(1, n or 120)
  if v == '' then return nil end
  return v
end

-- only plain ids (folder / model names): the request comes from a file, never build a path from anything else
local function safeId(v)
  v = str(v, 80)
  if v and v:match('^[%w_%-%.]+$') and not v:find('%.%.') then return v end
  return nil
end

-- request = decoded JSON, now = os.time(). Returns { mode, level, vehicle, config } or nil, reason
function M.parse(req, now)
  if type(req) ~= 'table' then return nil, 'not a request' end
  if type(req.ts) ~= 'number' or not now then return nil, 'no time' end
  if now - req.ts > M.MAX_AGE then return nil, 'old' end
  if req.ts - now > 300 then return nil, 'from the future' end
  local mode = req.mode
  if mode ~= 'resume' and mode ~= 'new' and mode ~= 'menu' then return nil, 'bad mode' end
  local plan = { mode = mode }
  if mode ~= 'menu' then
    plan.level = safeId(req.level)
    plan.vehicle = safeId(req.vehicle)
    plan.config = safeId(req.config)
  end
  return plan
end

-- the path the game's level loader wants for a level id
function M.levelFile(id)
  id = safeId(id)
  return id and ('/levels/' .. id .. '/info.json') or nil
end

-- what to remember about the current play session (game info -> table to save). Nil when there is nothing to remember.
function M.last(levelId, model, config, vehicleName)
  levelId, model = safeId(levelId), safeId(model)
  if not levelId then return nil end
  return { v = 1, level = levelId, vehicle = model, config = safeId(config), name = str(vehicleName, 60) }
end

local function idFromPath(p)
  return type(p) == 'string' and (p:match('/levels/([^/]+)/') or p:match('^levels/([^/]+)/')) or nil
end

-- The game's level list (core_levels.getList(): array of tables with a title and a file path) -> { {id, title} }
function M.levels(list)
  local out, seen = {}, {}
  if type(list) ~= 'table' then return out end
  for _, e in pairs(list) do
    if type(e) == 'table' then
      local id = safeId(idFromPath(e.fullfilename or e.filename or e.misFilePath or e.infoPath or e.levelPath) or e.levelName or e.name)
      if id and not seen[id] then
        seen[id] = true
        out[#out + 1] = { id = id, title = str(e.title or e.levelName or e.name, 60) or id }
      end
    end
  end
  table.sort(out, function(a, b) return a.title:lower() < b.title:lower() end)
  return out
end

-- core_vehicles.getModelList(): { models = { key = { key, Name, Brand, Type... } } } (or the models table itself) -> { {id, name, brand, type} }
function M.vehicles(list)
  local out = {}
  if type(list) ~= 'table' then return out end
  local models = list.models or list
  for k, e in pairs(models) do
    if type(e) == 'table' then
      local id = safeId(e.key or e.model or (type(k) == 'string' and k) or nil)
      local kind = str(e.Type, 20)
      if id and kind ~= 'Prop' and kind ~= 'Trailer' then
        out[#out + 1] = { id = id, name = str(e.Name or e.name, 60) or id, brand = str(e.Brand, 40), type = kind }
      end
    end
  end
  table.sort(out, function(a, b) return (a.brand or ''):lower() .. a.name:lower() < (b.brand or ''):lower() .. b.name:lower() end)
  return out
end

return M
