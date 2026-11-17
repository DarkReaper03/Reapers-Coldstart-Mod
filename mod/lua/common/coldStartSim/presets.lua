-- ColdStart Sim: realism presets (PLAN.md section 6). Plain Lua with no game globals, shared by the
-- vehicle side, the game-engine side and the local tests.
--
-- A preset is a set of effect toggles plus a few strengths. The settings screen (Phase 5) will let
-- every toggle be changed on its own; until then the preset is picked from the console:
--   coldStartSim_main.setPreset("casual")

local M = {}

M.names = {"display", "casual", "realistic", "hardcore"} -- mildest to harshest
M.default = "realistic"

local realistic = {
  label = "Realistic",
  effects = true, -- false: gauges and models only, the engine behaves exactly as stock
  spawnSoak = true, -- a car that spawns pre-heated is cold-soaked to the outside temperature
  keepTempsOnReset = true, -- recovering/resetting doesn't warm or cool the engine
  slowCranking = true, -- thick oil and a sagging battery slow the starter
  minCrankingShare = 0, -- never crank slower than this share of the stock cranking speed
  startFailures = true, -- the engine can fail to fire (too slow, glow plugs, brown-out)
  firingBonus = 0, -- added to the slowest share of stock cranking speed that still fires
  fastIdle = true, -- cold fast idle
  coldDrag = true, -- thick oil drags on a running cold engine (dynamicFriction)
  dragStrength = 1,
  misfires = true, -- a deep-cold engine stumbles for its first half minute
  misfireStrength = 1,
  starterOverheat = true, -- the starter cuts out after long cranking until it has cooled
  starterHeatLimit = 30, -- heat units (~seconds of hard cranking) before the cut-out
  flatBattery = true, -- a battery too flat to turn the starter only clicks
  batteryFreezing = false, -- a flat battery left in deep cold freezes and can't start the car
}

local function variant(changes)
  local preset = {}
  for key, value in pairs(realistic) do preset[key] = value end
  for key, value in pairs(changes) do preset[key] = value end
  return preset
end

M.presets = {
  display = variant({label = "Display only", effects = false}),
  -- slow cold cranking and fast idle for the feel, but it always starts
  casual = variant({label = "Casual", minCrankingShare = 0.5, startFailures = false, coldDrag = false,
    misfires = false, starterOverheat = false, flatBattery = false}),
  realistic = realistic,
  hardcore = variant({label = "Hardcore", firingBonus = 0.05, dragStrength = 1.25, misfireStrength = 2,
    starterHeatLimit = 20, batteryFreezing = true}),
}

-- A valid preset name (any case), or nil.
function M.normalize(name)
  if type(name) ~= "string" then return nil end
  local key = name:lower()
  return M.presets[key] and key or nil
end

-- A copy of a preset's options; the default preset for an unknown name.
function M.options(name)
  local preset = M.presets[M.normalize(name) or M.default]
  local copy = {}
  for key, value in pairs(preset) do copy[key] = value end
  return copy
end

-- "display, casual, realistic, hardcore" for messages
function M.list()
  return table.concat(M.names, ", ")
end

return M
