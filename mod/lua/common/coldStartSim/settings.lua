-- ColdStart Sim: the settings model (PLAN.md section 8). Plain Lua with no game globals, used by the
-- game-engine side (which loads, saves and broadcasts them) and the local tests.
--
-- settings/coldStartSim/settings.json, version 2:
--   preset      realism preset (presets.lua)
--   effects     per-effect overrides on top of the preset ({fastIdle = false, dragStrength = 1.5});
--               a key that's missing follows the preset
--   warnings    {disabled = {[id] = true}, toasts, toastLevel, chime, chimeLevel}
--   hud         the gauges app: tiles (order and visibility), theme, opacity, scale, compact,
--               showTitle, showFooter, autoHide, units {temperature, pressure}
--   lights      the warning-lights app: layout, idle, size
-- sanitize() turns anything (an old or hand-edited file, a partial update from the UI) into a
-- complete, valid table, so the rest of the code never checks types.

local M = {}

local presets = require("coldStartSim/presets")
local warnings = require("coldStartSim/warnings")

M.version = 2

-- the effect switches and strengths the settings screen offers (keys of presets.lua options)
M.effectToggles = {
  {key = "spawnSoak", label = "Cold-soak pre-heated spawns", desc = "A car the game spawns warm starts at the outside temperature."},
  {key = "keepTempsOnReset", label = "Keep engine temperature on reset", desc = "Recovering or resetting the car doesn't warm or cool the engine."},
  {key = "slowCranking", label = "Slower cranking in the cold", desc = "Thick oil and a sagging battery slow the starter."},
  {key = "startFailures", label = "Starts can fail", desc = "Too slow, glow plugs not ready or the battery browning out: no fire."},
  {key = "flatBattery", label = "Flat battery only clicks", desc = "A battery too flat to turn the starter can't start the car."},
  {key = "fastIdle", label = "Cold fast idle", desc = "A cold engine idles faster until it warms up."},
  {key = "coldDrag", label = "Cold engine drag", desc = "Thick cold oil makes a running engine work harder."},
  {key = "misfires", label = "Cold misfires", desc = "A deep-cold engine stumbles for its first half minute."},
  {key = "starterOverheat", label = "Starter overheating", desc = "Crank too long and the starter cuts out until it cools."},
  {key = "batteryFreezing", label = "Batteries can freeze", desc = "A flat battery left in deep cold freezes solid."},
}
M.effectSliders = {
  {key = "dragStrength", label = "Cold drag strength", min = 0.5, max = 2, step = 0.05},
  {key = "misfireStrength", label = "Misfire strength", min = 0.5, max = 3, step = 0.1},
  {key = "starterHeatLimit", label = "Starter heat limit (s of hard cranking)", min = 10, max = 60, step = 1},
}

-- gauge tiles, in the default order; the first ones are shown by default
M.tiles = {
  {id = "battery", label = "Battery voltage", visible = true},
  {id = "oilP", label = "Oil pressure", visible = true},
  {id = "coolant", label = "Coolant", visible = true},
  {id = "oil", label = "Oil temperature", visible = true},
  {id = "glow", label = "Glow plugs (diesel)", visible = true},
  {id = "oat", label = "Outside air", visible = true},
  {id = "cabin", label = "Cabin air", visible = true},
  {id = "iat", label = "Intake air", visible = true},
  {id = "block", label = "Engine block", visible = true},
  {id = "rpm", label = "RPM", visible = true},
  {id = "boost", label = "Boost (turbo)", visible = true},
  {id = "soc", label = "Battery charge", visible = false},
  {id = "battA", label = "Battery current", visible = false},
  {id = "altA", label = "Alternator output", visible = false},
  {id = "battT", label = "Battery temperature", visible = false},
  {id = "egt", label = "Exhaust temperature", visible = false},
  {id = "visc", label = "Oil viscosity", visible = false},
  {id = "crank", label = "Last crank", visible = false},
}

-- Climate presets (PLAN.md section 5.1): a flat-ish day/night temperature for every map, through
-- the game's own environment, so stock systems and the mod agree. "game" leaves the map's curve.
M.climates = {
  {value = "game", label = "Map default"},
  {value = "mild", label = "Mild winter (-5 °C)", averageC = -5, minC = -9, maxC = -1},
  {value = "cold", label = "Cold (-15 °C)", averageC = -15, minC = -20, maxC = -10},
  {value = "arctic", label = "Arctic (-30 °C)", averageC = -30, minC = -35, maxC = -25},
  {value = "siberian", label = "Siberian (-45 °C)", averageC = -45, minC = -50, maxC = -40},
  {value = "hot", label = "Desert heat (+38 °C)", averageC = 38, minC = 30, maxC = 46},
}
M.climateById = {}
for _, climate in ipairs(M.climates) do M.climateById[climate.value] = climate end

M.choices = {
  climate = M.climates,
  theme = {
    {value = "dark", label = "Dark glass"}, {value = "amber", label = "OEM amber"}, {value = "blue", label = "Night blue"},
    {value = "lcd", label = "Retro LCD"}, {value = "contrast", label = "High contrast"}, {value = "light", label = "Light"},
  },
  autoHide = {
    {value = "never", label = "Always show"}, {value = "warm", label = "Hide once warm"}, {value = "off", label = "Hide with the key off"},
  },
  temperature = {{value = "game", label = "Game setting"}, {value = "c", label = "°C"}, {value = "f", label = "°F"}},
  pressure = {
    {value = "game", label = "Game setting"}, {value = "kPa", label = "kPa"}, {value = "bar", label = "bar"}, {value = "psi", label = "psi"},
  },
  layout = {{value = "row", label = "Row"}, {value = "column", label = "Column"}, {value = "grid", label = "Grid"}},
  idle = {{value = "dim", label = "Dimmed"}, {value = "hide", label = "Hidden"}},
  level = {
    {value = 1, label = "Caution and worse"}, {value = 2, label = "Warnings and critical"}, {value = 3, label = "Critical only"},
  },
}

local ranges = {
  opacity = {0.1, 1}, scale = {0.6, 1.8}, size = {0.6, 2}, serviceSpeed = {1, 60},
}

local function isChoice(list, value)
  for _, choice in ipairs(list) do
    if choice.value == value then return true end
  end
  return false
end

local function clamp(x, lo, hi)
  return math.min(math.max(x, lo), hi)
end

local function number(x, lo, hi, fallback)
  if type(x) ~= "number" or x ~= x then return fallback end
  return clamp(x, lo, hi)
end

local function bool(x, fallback)
  if type(x) == "boolean" then return x end
  return fallback
end

local function choice(list, x, fallback)
  return isChoice(list, x) and x or fallback
end

local function defaultTiles()
  local tiles = {}
  for i, tile in ipairs(M.tiles) do tiles[i] = {id = tile.id, visible = tile.visible} end
  return tiles
end

function M.defaults()
  return {
    version = M.version,
    preset = presets.default,
    effects = {},
    -- climate preset, how much faster than real time block heaters and chargers work, and whether
    -- a car spawns in the state its model/config was left in (soak memory)
    sim = {climate = "game", serviceSpeed = 10, soakMemory = true},
    warnings = {disabled = {}, toasts = true, toastLevel = 2, chime = true, chimeLevel = 2},
    hud = {
      tiles = defaultTiles(), theme = "dark", opacity = 0.72, scale = 1, compact = false,
      showTitle = true, showFooter = true, autoHide = "never", units = {temperature = "game", pressure = "game"},
    },
    lights = {layout = "row", idle = "dim", size = 1},
  }
end

local knownTiles = {}
for _, tile in ipairs(M.tiles) do knownTiles[tile.id] = tile end

local sliderByKey = {}
for _, slider in ipairs(M.effectSliders) do sliderByKey[slider.key] = slider end
local toggleByKey = {}
for _, toggle in ipairs(M.effectToggles) do toggleByKey[toggle.key] = toggle end

-- A complete, valid settings table from anything (version 1 files only had the preset).
function M.sanitize(data)
  data = type(data) == "table" and data or {}
  local s = M.defaults()
  s.preset = presets.normalize(data.preset) or presets.default

  local effects = type(data.effects) == "table" and data.effects or {}
  for key, value in pairs(effects) do
    if toggleByKey[key] and type(value) == "boolean" then
      s.effects[key] = value
    elseif sliderByKey[key] and type(value) == "number" and value == value then
      local slider = sliderByKey[key]
      s.effects[key] = clamp(value, slider.min, slider.max)
    end
  end

  local sim = type(data.sim) == "table" and data.sim or {}
  s.sim.climate = M.climateById[sim.climate] and sim.climate or s.sim.climate
  s.sim.serviceSpeed = number(sim.serviceSpeed, ranges.serviceSpeed[1], ranges.serviceSpeed[2], s.sim.serviceSpeed)
  s.sim.soakMemory = bool(sim.soakMemory, s.sim.soakMemory)

  local w = type(data.warnings) == "table" and data.warnings or {}
  if type(w.disabled) == "table" then
    for id, off in pairs(w.disabled) do
      if warnings.byId[id] and off == true then s.warnings.disabled[id] = true end
    end
  end
  s.warnings.toasts = bool(w.toasts, s.warnings.toasts)
  s.warnings.chime = bool(w.chime, s.warnings.chime)
  s.warnings.toastLevel = math.floor(number(w.toastLevel, 0, 3, s.warnings.toastLevel))
  s.warnings.chimeLevel = math.floor(number(w.chimeLevel, 0, 3, s.warnings.chimeLevel))

  local h = type(data.hud) == "table" and data.hud or {}
  if type(h.tiles) == "table" then
    local tiles, seen = {}, {}
    for _, tile in ipairs(h.tiles) do
      if type(tile) == "table" and knownTiles[tile.id] and not seen[tile.id] then
        seen[tile.id] = true
        tiles[#tiles + 1] = {id = tile.id, visible = bool(tile.visible, knownTiles[tile.id].visible)}
      end
    end
    for _, tile in ipairs(M.tiles) do -- tiles added in a later version go at the end
      if not seen[tile.id] then tiles[#tiles + 1] = {id = tile.id, visible = tile.visible} end
    end
    s.hud.tiles = tiles
  end
  s.hud.theme = choice(M.choices.theme, h.theme, s.hud.theme)
  s.hud.opacity = number(h.opacity, ranges.opacity[1], ranges.opacity[2], s.hud.opacity)
  s.hud.scale = number(h.scale, ranges.scale[1], ranges.scale[2], s.hud.scale)
  s.hud.compact = bool(h.compact, s.hud.compact)
  s.hud.showTitle = bool(h.showTitle, s.hud.showTitle)
  s.hud.showFooter = bool(h.showFooter, s.hud.showFooter)
  s.hud.autoHide = choice(M.choices.autoHide, h.autoHide, s.hud.autoHide)
  local units = type(h.units) == "table" and h.units or {}
  s.hud.units.temperature = choice(M.choices.temperature, units.temperature, s.hud.units.temperature)
  s.hud.units.pressure = choice(M.choices.pressure, units.pressure, s.hud.units.pressure)

  local l = type(data.lights) == "table" and data.lights or {}
  s.lights.layout = choice(M.choices.layout, l.layout, s.lights.layout)
  s.lights.idle = choice(M.choices.idle, l.idle, s.lights.idle)
  s.lights.size = number(l.size, ranges.size[1], ranges.size[2], s.lights.size)
  return s
end

local function isArray(t)
  return type(t) == "table" and (#t > 0 or next(t) == nil)
end

-- Deep-merges `partial` into a copy of `current` (lists such as hud.tiles are replaced, not merged),
-- then sanitizes. `partial.effects = false` (or warnings.disabled = false) clears that table.
function M.merge(current, partial)
  local function mergeInto(target, source)
    for key, value in pairs(source) do
      if value == false and type(target[key]) == "table" then
        target[key] = {}
      elseif type(value) == "table" and type(target[key]) == "table" and not isArray(value) then
        mergeInto(target[key], value)
      else
        target[key] = value
      end
    end
  end
  local copy = M.sanitize(current)
  if type(partial) == "table" then mergeInto(copy, partial) end
  return M.sanitize(copy)
end

-- One section back to its defaults (nil: everything).
function M.reset(current, section)
  if section == nil then return M.defaults() end
  local copy = M.sanitize(current)
  local defaults = M.defaults()
  if defaults[section] ~= nil then copy[section] = defaults[section] end
  return copy
end

-- What a vehicle needs: {preset, effects = on/off, overrides = {...}, warnings = {...}}
function M.forVehicle(s, effectsOn)
  return {preset = s.preset, effects = effectsOn ~= false, overrides = s.effects, warnings = s.warnings,
    services = {serviceSpeed = s.sim.serviceSpeed}}
end

-- The preset's options with the overrides on top (what the vehicle actually runs).
function M.effectiveOptions(s)
  local options = presets.options(s.preset)
  for key, value in pairs(s.effects or {}) do
    if toggleByKey[key] or sliderByKey[key] then options[key] = value end
  end
  return options
end

-- Everything the settings screen needs to draw itself.
function M.schema()
  local presetList = {}
  for _, name in ipairs(presets.names) do
    presetList[#presetList + 1] = {value = name, label = presets.presets[name].label}
  end
  local warningList = {}
  for _, def in ipairs(warnings.definitions) do
    warningList[#warningList + 1] = {id = def.id, title = def.title, icon = def.icon}
  end
  local presetOptions = {}
  for _, name in ipairs(presets.names) do presetOptions[name] = presets.options(name) end
  return {
    version = M.version, presets = presetList, presetOptions = presetOptions,
    effectToggles = M.effectToggles, effectSliders = M.effectSliders,
    warnings = warningList, tiles = M.tiles, choices = M.choices,
  }
end

return M
