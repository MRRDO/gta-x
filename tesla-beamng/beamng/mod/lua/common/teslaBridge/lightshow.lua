-- teslaBridge/lightshow.lua
-- Light shows and welcome/goodbye animations, as pure functions of time.
-- state(name, t) -> { low, high, fog, left, right, hazard } (booleans), done (bool).
-- BeamNG cars can only do headlights (low/high), fog lights and the indicators, so these are
-- choreographed with those. (Real Tesla shows also move windows, mirrors and doors.)

local M = {}
local floor, sin = math.floor, math.sin

local function st(low, high, fog, left, right, hazard)
  return { low = low or false, high = high or false, fog = fog or false, left = left or false, right = right or false, hazard = hazard or false }
end

-- Shows: bpm, bars (16 beats-of-4 sections), pattern(beat, bar) -> state
local SHOWS = {
  -- three quick sweeps: low, high, fog, then settle on low
  welcome = { length = 2.4, pattern = function(t)
    local k = floor(t / 0.3)
    if t >= 2.1 then return st(true) end
    local m = k % 3
    return st(m == 0, m == 1, m == 2)
  end },
  goodbye = { length = 3.0, pattern = function(t)
    if t < 0.4 then return st(true) end
    if t < 2.4 then return st(true, false, false, false, false, floor((t - 0.4) / 0.4) % 2 == 0) end
    return st(false)
  end },
  -- a 60-second "holiday" show at 120 bpm: build, main groove, breakdown, finale
  holiday = { length = 60, pattern = function(t)
    local beat = t * 2 -- 120 bpm
    local b = floor(beat)
    local bar = floor(beat / 4)
    local sub = b % 4
    if t < 8 then -- build: low beams pulse on the beat, one more element every two bars
      return st(b % 2 == 0, bar >= 2 and sub == 3, bar >= 1 and sub == 1, false, false)
    elseif t < 36 then -- groove: alternate high beams and fog, blinkers chase
      local a = sub % 2 == 0
      return st(true, a, not a, sub == 0 or sub == 1, sub == 2 or sub == 3)
    elseif t < 48 then -- breakdown: slow breathing low beams, hazards on the bar
      return st(floor(beat / 2) % 2 == 0, false, false, false, false, sub == 0)
    elseif t < 58 then -- finale: strobing high beams, hazards
      return st(true, b % 2 == 0, b % 2 == 1, false, false, sub == 0 or sub == 2)
    end
    return st(t < 59) -- fade out
  end },
  -- wall of strobe, like the "Rainbow Road / Boombox" party mode
  strobe = { length = 12, pattern = function(t)
    local b = floor(t * 6)
    return st(b % 2 == 0, b % 2 == 1, b % 3 == 0, b % 4 == 1, b % 4 == 3)
  end },
}
M.SHOWS = SHOWS

function M.names()
  local o = {}
  for k in pairs(SHOWS) do o[#o + 1] = k end
  table.sort(o)
  return o
end

function M.length(name) return SHOWS[name] and SHOWS[name].length or nil end

function M.state(name, t)
  local s = SHOWS[name]
  if not s then return st(false), true end
  if t >= s.length then return st(false), true end
  return s.pattern(t), false
end

return M
