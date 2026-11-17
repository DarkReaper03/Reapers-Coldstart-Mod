-- ColdStart Sim: builds a description of the vehicle from what the game already knows
-- (powertrain devices, their jbeam data, vehicle info). The models use it from Phase 2 on;
-- in Phase 1 it feeds the HUD footer and the compatibility report.

local M = {}

local adapter = require("coldStartSim/adapter")
local num = adapter.num

-- System-voltage guess: 24 V only for heavy diesel vehicles (buses, heavy trucks).
-- US-style semi tractors stay on 12 V like the real ones. Overridable in a later phase.
local heavyVehicleMassKg = 10000

local function round(x)
  return x and math.floor(x + 0.5) or nil
end

local function describeEngine(h)
  local d, j = h.device, h.jbeam
  local e = {
    name = h.name,
    type = h.type,
    maxPowerPS = round(num(d.maxPower)),
    maxTorqueNm = round(num(d.maxTorque)),
    idleRPM = round(num(d.idleRPM)),
    maxRPM = round(num(d.maxRPM)),
    inertia = num(d.inertia),
  }
  if h.isCombustion then
    e.fuel = tostring(d.requiredEnergyType or "gasoline")
    e.thermals = h.thermalsEnabled and "stock" or (h.hasThermals and "disabled" or "missing")
    e.customThermalsFile = type(j.thermalsLuaFileName) == "string" and j.thermalsLuaFileName or nil
    e.blockMaterial = type(j.engineBlockMaterial) == "string" and j.engineBlockMaterial or "iron"
    e.airCooled = j.isAirCooledOnly == true
    e.oilVolumeL = num(j.oilVolume) or 5 -- same default as the thermals
    e.thermostatC = num(j.thermostatTemperature) or 90
    e.radiatorFan = type(j.radiatorFanType) == "string" and j.radiatorFanType or nil
    e.turbo = type(d.turbocharger) == "table" and d.turbocharger.isExisting == true
    e.supercharger = type(d.supercharger) == "table" and d.supercharger.isExisting == true
    e.starterTorque = num(d.starterTorque)
    e.starterMaxRPM = round(num(d.starterMaxAV) and d.starterMaxAV * adapter.avToRPM)
    e.starterThrottleKillTime = num(d.starterThrottleKillTime)
    e.friction = num(d.friction)
    e.dynamicFriction = num(d.dynamicFriction)
    e.apiMissing = adapter.checkApi(h)
  elseif h.isElectric then
    e.fuel = "electricEnergy"
  else
    e.fuel = d.requiredEnergyType and tostring(d.requiredEnergyType) or nil
  end
  return e
end

function M.build(engines)
  local p = {}
  local dir = type(v.vehicleDirectory) == "string" and v.vehicleDirectory or ""
  p.model = dir:match("/vehicles/([^/]+)") or "unknown"
  local configFile = v.config and v.config.partConfigFilename
  p.configName = type(configFile) == "string" and configFile:match("([^/]+)%.pc$") or "custom"
  local info = v.data and v.data.information
  p.name = type(info) == "table" and type(info.name) == "string" and info.name or p.model
  p.massKg = round(adapter.vehicleMass())

  p.engines = {}
  local combustionCount, electricCount = 0, 0
  local bestPower, primaryIndex = -1, nil
  for i, h in ipairs(engines) do
    local e = describeEngine(h)
    p.engines[i] = e
    if h.isCombustion then
      combustionCount = combustionCount + 1
      local power = e.maxPowerPS or 0
      if power > bestPower then
        bestPower, primaryIndex = power, i
      end
    elseif h.isElectric then
      electricCount = electricCount + 1
    end
  end
  if not primaryIndex and electricCount > 0 then
    for i, h in ipairs(engines) do
      if h.isElectric then
        primaryIndex = i
        break
      end
    end
  end

  p.engineCount = #engines
  p.primaryIndex = primaryIndex
  p.kind = combustionCount > 0 and "ice" or (electricCount > 0 and "ev" or "none")

  local primary = primaryIndex and p.engines[primaryIndex] or nil
  p.fuel = primary and primary.fuel or nil
  p.thermals = primary and primary.thermals or nil
  p.turbo = primary and (primary.turbo or primary.supercharger) or false

  local heavyDiesel = p.fuel == "diesel" and (p.massKg or 0) > heavyVehicleMassKg
  p.systemVoltage = heavyDiesel and 24 or 12

  -- Optional per-vehicle tuning that car modders can add to their jbeam (see PLAN.md section 9).
  local authorConfig = v.data and v.data.coldStartSim
  p.authorConfig = type(authorConfig) == "table" and authorConfig or nil

  return p
end

return M
