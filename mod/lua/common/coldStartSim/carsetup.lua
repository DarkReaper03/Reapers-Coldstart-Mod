-- ColdStart Sim: per-car setup (0.9.0). Plain Lua with no game globals, shared by the game-engine side
-- (which saves it per model/config in settings/coldStartSim/vehicles.json), the vehicle side (which
-- applies it, models/defaults.lua forProfile) and the local tests.
--
-- Every car gets values worked out from its engine (and from a car modder's jbeam "coldStartSim"
-- section). The player can change them for one car in the settings screen's Car tab: useful for
-- modded cars whose detected values are off, and for setting a car up for winter (thin oil, a bigger
-- battery, a stronger block heater). A missing key means "auto".

local M = {}

M.choices = {
  fuel = {
    {value = "auto", label = "Auto"}, {value = "gasoline", label = "Gasoline"}, {value = "diesel", label = "Diesel"},
  },
  oilGrade = {
    {value = "auto", label = "Auto"}, {value = "0W-20", label = "0W-20 (arctic synthetic)"},
    {value = "5W-30", label = "5W-30"}, {value = "10W-30", label = "10W-30"}, {value = "10W-40", label = "10W-40"},
    {value = "15W-40", label = "15W-40 (diesel)"}, {value = "20W-50", label = "20W-50 (classic, warm climates)"},
  },
  battery = {
    {value = "auto", label = "Auto"}, {value = "small", label = "Small (75 %)"},
    {value = "heavy", label = "Heavy-duty (130 %)"}, {value = "dual", label = "Two batteries (200 %)"},
  },
  voltage = {
    {value = "auto", label = "Auto"}, {value = 12, label = "12 V"}, {value = 24, label = "24 V"},
  },
  glowPlugs = {
    {value = "auto", label = "Auto"}, {value = "on", label = "Glow plugs"}, {value = "off", label = "No glow plugs"},
  },
  heaterWatts = {
    {value = 400, label = "400 W"}, {value = 750, label = "750 W (standard)"}, {value = 1000, label = "1000 W"},
    {value = 1500, label = "1500 W (tank heater)"},
  },
}

-- battery choice -> CCA and capacity multiplier on the car's own battery
M.batteryFactor = {small = 0.75, heavy = 1.3, dual = 2}
M.defaultHeaterWatts = 750

local function allowed(list, value)
  for _, item in ipairs(list) do
    if item.value == value then return true end
  end
  return false
end

-- A clean setup: known keys with valid values only; "auto" and anything unknown are dropped (= auto).
-- effects = false switches the cold-start effects off for this car (the gauges keep working).
function M.sanitize(data)
  local s = {}
  if type(data) ~= "table" then return s end
  for _, key in ipairs({"fuel", "oilGrade", "battery", "glowPlugs"}) do
    local value = data[key]
    if type(value) == "string" and value ~= "auto" and allowed(M.choices[key], value) then s[key] = value end
  end
  local voltage = tonumber(data.voltage)
  if voltage == 12 or voltage == 24 then s.voltage = voltage end
  local watts = tonumber(data.heaterWatts)
  if watts and allowed(M.choices.heaterWatts, watts) and watts ~= M.defaultHeaterWatts then s.heaterWatts = watts end
  if data.effects == false then s.effects = false end
  return s
end

-- `current` with `partial` on top. A key set to "auto" goes back to auto, and so does effects = true
-- (on is the default).
function M.merge(current, partial)
  local merged = {}
  for key, value in pairs(M.sanitize(current)) do merged[key] = value end
  if type(partial) == "table" then
    for key, value in pairs(partial) do
      if value == "auto" or (key == "effects" and value == true) then
        merged[key] = nil
      else
        merged[key] = value
      end
    end
  end
  return M.sanitize(merged)
end

function M.isEmpty(setup)
  return type(setup) ~= "table" or next(setup) == nil
end

-- What changed, in words, for the message after a change ("oil 0W-20, heavy-duty battery").
function M.describe(setup)
  setup = M.sanitize(setup)
  local parts = {}
  if setup.oilGrade then parts[#parts + 1] = "oil " .. setup.oilGrade end
  if setup.battery then
    parts[#parts + 1] = ({small = "small battery", heavy = "heavy-duty battery", dual = "two batteries"})[setup.battery]
  end
  if setup.fuel then parts[#parts + 1] = setup.fuel end
  if setup.voltage then parts[#parts + 1] = setup.voltage .. " V" end
  if setup.glowPlugs then parts[#parts + 1] = setup.glowPlugs == "on" and "glow plugs" or "no glow plugs" end
  if setup.heaterWatts then parts[#parts + 1] = setup.heaterWatts .. " W block heater" end
  if setup.effects == false then parts[#parts + 1] = "cold-start effects off" end
  return #parts > 0 and table.concat(parts, ", ") or "auto"
end

return M
