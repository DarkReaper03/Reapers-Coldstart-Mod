-- ColdStart Sim: the only module that touches BeamNG engine internals.
--
-- Every read is defensive: a modded engine with missing or renamed fields yields nil values
-- ("no data") instead of an error. Field names were checked against BeamNG.drive 0.40.5:
--   lua/vehicle/powertrain/combustionEngine.lua
--   lua/vehicle/powertrain/combustionEngineThermals.lua
--
-- Phase 1 is read-only. Later phases add the undoable writes listed in PLAN.md section 6.

local M = {}

local avToRPM = 30 / math.pi -- rad/s -> rpm
local psiToKPa = 6.894757

local function num(x)
  if type(x) == "number" and x == x and x ~= math.huge and x ~= -math.huge then
    return x
  end
  return nil
end
M.num = num
M.avToRPM = avToRPM

local function jbeamFor(device)
  if v and v.data and device.name ~= nil then
    local data = v.data[device.name]
    if type(data) == "table" then return data end
  end
  return {}
end

-- Handles for every device in the powertrain's "engine" category (combustion engines and
-- electric motors), sorted by name so the order is stable between spawns.
function M.findEngines()
  local handles = {}
  if type(powertrain) ~= "table" or type(powertrain.getDevicesByCategory) ~= "function" then
    return handles
  end
  local ok, devices = pcall(powertrain.getDevicesByCategory, "engine")
  if not ok or type(devices) ~= "table" then return handles end
  table.sort(devices, function(a, b) return tostring(a.name) < tostring(b.name) end)

  for _, device in ipairs(devices) do
    local thermals = device.thermals
    local hasThermals = type(thermals) == "table" and num(thermals.oilTemperature) ~= nil
    table.insert(handles, {
      device = device,
      name = tostring(device.name),
      type = tostring(device.type),
      isCombustion = device.type == "combustionEngine",
      isElectric = device.type == "electricMotor",
      jbeam = jbeamFor(device),
      hasThermals = hasThermals,
      -- the jbeam flag; the thermals module still exists (frozen at ambient) when it is off
      thermalsEnabled = hasThermals and device.thermalsEnabled == true,
    })
  end
  return handles
end

-- Fills `out` with the live state of one engine. Unavailable values are set to nil.
function M.readEngine(h, out)
  local d = h.device
  local av = num(d.outputAV1)
  out.rpm = av and av * avToRPM or nil
  out.cranking = (num(d.starterEngagedCoef) or 0) > 0
  out.stalled = d.isStalled == true
  out.disabled = d.isDisabled == true or d.isBroken == true
  out.ignition = (num(d.ignitionCoef) or 0) > 0
  out.load = num(d.engineLoad)
  out.starterMaxRPM = num(d.starterMaxAV) and d.starterMaxAV * avToRPM or nil

  local t = h.hasThermals and d.thermals or nil
  local dd = t and type(t.debugData) == "table" and t.debugData.engineThermalData or nil
  if type(dd) ~= "table" then dd = nil end

  out.coolant = t and num(t.coolantTemperature) or nil -- nil on air-cooled engines
  out.oil = t and num(t.oilTemperature) or nil
  out.block = t and num(t.engineBlockTemperature) or nil
  out.wall = t and num(t.cylinderWallTemperature) or nil
  out.exhaust = t and num(t.exhaustTemperature) or nil
  out.oilMass = dd and num(dd.oilMass) or nil
  out.oilMinSafeMass = dd and num(dd.miniumSafeOilMass) or nil -- [sic], spelled this way in the game
  out.lubrication = dd and num(dd.oilLubricationCoef) or nil
  out.thermostat = dd and num(dd.thermostatTemperature) or nil
  if dd then
    out.fanActive = dd.fanActive == true or (num(dd.fanActive) or 0) > 0
  else
    out.fanActive = nil
  end
  return out
end

-- Fills `out` with the electrics values the mod uses. Returns nil when the vehicle has no electrics.
function M.readElectrics(out)
  local e = electrics and electrics.values
  if type(e) ~= "table" then return nil end
  out.ignitionLevel = num(e.ignitionLevel) -- 0 off, 1 accessory, 2 on, 3 starting
  local running = e.engineRunning
  if running == nil then
    out.engineRunning = nil
  else
    out.engineRunning = running == true or (num(running) or 0) > 0.5
  end
  out.oilTemp = num(e.oiltemp)
  out.waterTemp = num(e.watertemp)
  out.rpm = num(e.rpm)
  out.airspeed = num(e.airspeed) -- m/s
  local boost = num(e.boost) -- psi (lua/vehicle/powertrain/turbocharger.lua:276)
  out.boostKPa = boost and boost * psiToKPa or nil
  -- electrical consumers (raw values: some are booleans, some 0/1; lua/vehicle/electrics.lua:400-435)
  out.lights = e.lights_state or e.lights -- 0 off, 1 low beams, 2 high beams
  out.fog = e.fog
  out.brakelights = e.brakelights
  out.signal_L = e.signal_L
  out.signal_R = e.signal_R
  out.hazard = e.hazard
  out.horn = e.horn
  return out
end

-- Outside air temperature in °C. Follows the level's day/night curve (core_environment).
function M.ambientC()
  local kelvin = num(obj:getEnvTemperature())
  return kelvin and (kelvin - 273.15) or nil
end

-- Ambient air pressure in kPa (obj:getEnvPressure is assumed to return Pa; checked by the probe).
function M.ambientPressureKPa()
  local pressure = num(obj:getEnvPressure())
  return pressure and pressure * 0.001 or nil
end

-- Vehicle mass in kg from the jbeam node weights.
function M.vehicleMass()
  local mass = 0
  if v and v.data and type(v.data.nodes) == "table" then
    for _, node in pairs(v.data.nodes) do
      mass = mass + (num(node.nodeWeight) or 0)
    end
  end
  return mass
end

-- Test helper (compatibility test runner): sets the stock thermals of one engine to `celsius`,
-- i.e. a full cold soak. Air-cooled engines have no coolant temperature and keep it nil.
-- The game overwrites these values on the next vehicle reset.
local thermalKeys = {
  "engineBlockTemperature", "cylinderWallTemperature", "oilTemperature", "coolantTemperature", "exhaustTemperature",
}
function M.setEngineTemperatures(h, celsius)
  local t = h.hasThermals and h.device.thermals or nil
  if not t or not num(celsius) then return false end
  for _, key in ipairs(thermalKeys) do
    if num(t[key]) then t[key] = celsius end
  end
  return true
end

-- Copy of the five stock thermals temperatures (nil without thermals).
function M.getEngineTemperatures(h)
  local t = h.hasThermals and h.device.thermals or nil
  if not t then return nil end
  local copy = {}
  for _, key in ipairs(thermalKeys) do copy[key] = num(t[key]) end
  return copy
end

-- Writes back temperatures from getEngineTemperatures (keys that are nil stay as they are).
function M.setEngineTemperatureTable(h, temps)
  local t = h.hasThermals and h.device.thermals or nil
  if not t or type(temps) ~= "table" then return false end
  for _, key in ipairs(thermalKeys) do
    if num(temps[key]) and num(t[key]) then t[key] = temps[key] end
  end
  return true
end

-- Turns the key: 0 off, 1 accessory, 2 on, 3 crank (the same call the game's input actions use).
-- Returns false when the vehicle's controller can't do it (some modded controllers).
function M.setIgnitionLevel(level)
  if not (electrics and type(electrics.setIgnitionLevel) == "function") then return false end
  local ok, err = pcall(electrics.setIgnitionLevel, level)
  if not ok then
    log("W", "coldStartSim", "Could not set ignition level " .. tostring(level) .. ": " .. tostring(err))
  end
  return ok
end

-- Disengages the starter like releasing the key (combustionEngine.lua deactivateStarter). Used for
-- the starter's thermal cut-out; the player has to turn the key again once it has cooled.
function M.stopStarter(h)
  local d = h.device
  if type(d.deactivateStarter) ~= "function" then return false end
  local ok, err = pcall(d.deactivateStarter, d)
  if not ok then log("W", "coldStartSim", "Could not stop the starter: " .. tostring(err)) end
  return ok
end

-- Blocks or unblocks the arcade gearbox's automatic restart (vehicleController.lua:314 checks
-- starterDisabled). Never unblocks an engine the game itself disabled or broke.
function M.setStarterBlocked(h, blocked)
  local d = h.device
  if blocked then
    d.starterDisabled = true
  elseif not (d.isDisabled or d.isBroken) then
    d.starterDisabled = false
  end
end

-- Fields and methods later phases rely on. Returns the names that are missing on this engine,
-- so the compatibility report shows which modded engines need a fallback.
local numberFields = {
  "outputAV1", "starterTorque", "starterMaxAV", "starterEngagedCoef", "starterThrottleKillTimer",
  "starterThrottleKillTime", "idleAV", "dynamicFriction", "maxTorqueLimit", "ignitionCoef",
  "fastIgnitionErrorChance", "slowIgnitionErrorChance",
}
local methods = {"scaleOutputTorque", "lockUp", "setIgnition", "deactivateStarter"}

function M.checkApi(h)
  local missing = {}
  local d = h.device
  for _, key in ipairs(numberFields) do
    if type(d[key]) ~= "number" then table.insert(missing, key) end
  end
  for _, key in ipairs(methods) do
    if type(d[key]) ~= "function" then table.insert(missing, key .. "()") end
  end
  if not h.hasThermals then
    table.insert(missing, "thermals")
  end
  return missing
end

return M
