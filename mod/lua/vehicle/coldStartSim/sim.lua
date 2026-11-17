-- ColdStart Sim: runs the Phase 2 models for one vehicle.
--
-- Simulation and display only: nothing here changes how the car drives (that is Phase 3).
-- Inputs come from the adapter (stock engine, thermals, electrics); outputs feed telemetry.
-- The models themselves live in lua/common/coldStartSim/models/ so the local tests can run them.

local M = {}

local oilModel = require("coldStartSim/models/oil")
local batteryModel = require("coldStartSim/models/battery")
local electrical = require("coldStartSim/models/electrical")
local glowModel = require("coldStartSim/models/glowplug")
local cabinModel = require("coldStartSim/models/cabin")
local intakeModel = require("coldStartSim/models/intake")
local defaults = require("coldStartSim/models/defaults")
local starting = require("coldStartSim/models/starting")

local exp, max, min = math.exp, math.max, math.min

local params = nil
local oil, battery, starter, glow, cabin, intake = nil, nil, nil, nil, nil, nil
local isCombustion = false
local thermalsLive = false
local estimate = nil -- fallback temperatures for engines without live thermals
local loadExtra = {}
local crank = {active = false, minV = nil, peakA = 0, lastMinV = nil, lastPeakA = nil}

M.state = {} -- read by telemetry; reused table

-- Engine temperatures from the best available source: the game's thermals, the dashboard
-- electrics, or (for engines with neither) a simple warm-up estimate: toward 90 °C with a
-- 6-minute time constant while running, toward outside air over 1.5 hours when off.
local function engineTemperatures(dt, engine, e, ambientC, running, s)
  if thermalsLive and engine then
    s.thermals = "stock"
    s.oilC, s.coolantC, s.blockC, s.exhaustC = engine.oil, engine.coolant, engine.block, engine.exhaust
  elseif (e.oilTemp or 0) ~= 0 or (e.waterTemp or 0) ~= 0 then
    s.thermals = "electrics"
    s.oilC, s.coolantC, s.blockC, s.exhaustC = e.oilTemp, e.waterTemp, e.waterTemp, nil
  else
    s.thermals = "estimated"
    estimate = estimate or {oil = ambientC, coolant = ambientC}
    local target = running and 90 or ambientC
    local tau = running and 360 or 5400
    local k = 1 - exp(-dt / tau)
    estimate.oil = estimate.oil + (target - estimate.oil) * k
    estimate.coolant = estimate.coolant + (target - estimate.coolant) * k
    s.oilC, s.coolantC, s.blockC, s.exhaustC = estimate.oil, estimate.coolant, estimate.coolant, nil
  end
end

-- profile: from profile.lua; ambientC: outside air at spawn (starting temperature of everything);
-- setup: the player's per-car setup (coldStartSim/carsetup.lua), nil for auto
function M.init(profile, ambientC, setup)
  params = defaults.forProfile(profile, setup)
  isCombustion = profile.kind == "ice"
  thermalsLive = profile.thermals == "stock"
  estimate = nil
  local startC = ambientC or 20

  battery = batteryModel.new({
    voltage = params.battery.voltage, capacityAh = params.battery.capacityAh, cca = params.battery.cca,
    alternatorA = params.battery.alternatorA, soc = params.battery.soc, tempC = startC,
  })
  cabin = cabinModel.new({tempC = startC, targetC = params.cabin.targetC, size = params.cabin.size,
    ptcW = profile.kind == "ev" and 4000 or 0})
  if isCombustion then
    oil = oilModel.new(params.oil)
    starter = electrical.newStarter(params.starter)
    intake = intakeModel.new({intercooled = params.intake.intercooled, tempC = startC})
    glow = params.glow and glowModel.new(params.glow) or nil
  else
    oil, starter, intake, glow = nil, nil, nil, nil
  end
  crank.active, crank.minV, crank.peakA, crank.lastMinV, crank.lastPeakA = false, nil, 0, nil, nil
  return params
end

-- A new per-car setup on a car that is already running the models (0.9.0): new parameters, same
-- state. The battery keeps its charge, temperature and jump leads, the oil its pressure (a new
-- grade is an oil change, not a drop to zero), the glow plugs their heat, the cabin and intake air
-- their temperatures. Returns the new params.
local glowFields = {"state", "timer", "preheatTarget", "preheatFraction", "afterglowLeft", "lastIgnition", "readyFor", "wait"}
function M.reconfigure(profile, setup)
  if not params then return nil end
  params = defaults.forProfile(profile, setup)
  local old = battery
  battery = batteryModel.new({
    voltage = params.battery.voltage, capacityAh = params.battery.capacityAh, cca = params.battery.cca,
    alternatorA = params.battery.alternatorA, soc = old.soc, tempC = old.tempC,
  })
  if old.jump then battery:connectJumpLeads(true) end
  battery.voltage = old.voltage
  if isCombustion then
    local oldOil = oil
    oil = oilModel.new(params.oil)
    if oldOil then oil.pressureKPa, oil.targetKPa = oldOil.pressureKPa, oldOil.targetKPa end
    starter = electrical.newStarter(params.starter)
    local oldGlow = glow
    glow = params.glow and glowModel.new(params.glow) or nil
    if glow and oldGlow then
      for _, key in ipairs(glowFields) do glow[key] = oldGlow[key] end
    end
  end
  return params
end

-- The glow-plug cycle (0.9.0): preheat again with the key on. Returns the seconds it takes, or nil.
function M.glowCycle()
  if not glow then return nil end
  return glow:cycle(M.state.blockC)
end

-- A new battery (0.9.0): fully charged, at the temperature the old one had (it sat in the same cold).
function M.newBattery()
  if battery then battery.soc = 1 end
end

M.warmerRiseC = 25 -- a battery warmer pad (~80 W) holds the battery about this much above outside air

-- engine: adapter.readEngine() output for the primary engine (nil for vehicles without one)
-- e: adapter.readElectrics() output; ambientC, baroKPa: environment
-- starterOverrideA: starter current from the cold-start logic (coldstart.lua); nil = estimate it
-- from the stock starter
-- external: what's plugged in (services.lua electrical()): {chargerA, chargeSpeed, jump, warmer}
function M.update(dt, engine, e, ambientC, baroKPa, starterOverrideA, external)
  if not params or dt <= 0 then return end
  local s = M.state
  ambientC = ambientC or 20
  local ignition = e.ignitionLevel or 0
  local rpm = engine and engine.rpm or 0
  local cranking = engine and engine.cranking or false
  local running = e.engineRunning
  if running == nil then running = rpm > 300 end
  local speedKmh = (e.airspeed or 0) * 3.6
  if isCombustion then
    engineTemperatures(dt, engine, e, ambientC, running, s)
  else
    s.thermals, s.oilC, s.coolantC, s.blockC, s.exhaustC = nil, nil, nil, nil, nil
  end
  local coolant = s.coolantC or s.oilC -- air-cooled engines: the oil carries the heat
  local block = s.blockC or ambientC

  -- cabin first: its blower is an electrical load
  cabin:update(dt, ambientC, coolant, speedKmh, ignition)

  -- electrical loads
  loadExtra.diesel = params.diesel
  loadExtra.radiatorFanOn = params.electricRadiatorFan and engine ~= nil and engine.fanActive == true
  loadExtra.blowerLevel = cabin.blowerLevel
  local loadA = electrical.consumersA(e, loadExtra, params.voltage)
  local glowA = glow and glow:update(dt, ignition, cranking, running, block) or 0
  local starterA = 0
  if starterOverrideA ~= nil then
    starterA = cranking and starterOverrideA or 0
  elseif starter and engine then
    starterA = starter:currentA(cranking, rpm, engine.starterMaxRPM)
  end

  -- battery sits in the engine bay: it warms with the engine and cools toward outside air; a battery
  -- warmer (0.9.0) holds it warmer, at the service speed like the block heater
  local bayC = ambientC + 0.3 * max((block or ambientC) - ambientC, 0)
  local envSpeed = 1
  if external and external.warmer then
    bayC = max(bayC, ambientC + M.warmerRiseC)
    envSpeed = external.chargeSpeed or 1
  end
  local jump = external ~= nil and external.jump == true
  if jump ~= (battery.jump ~= nil) then battery:connectJumpLeads(jump) end
  local chargerA = external and external.chargerA or 0
  battery:update(dt, loadA + glowA + starterA, rpm, bayC, chargerA, external and external.chargeSpeed or 1, envSpeed)
  -- the battery as the starter sees it: coldstart.lua solves the starter's current against it
  local supplyV, supplyR = battery:thevenin()
  local otherA = loadA + glowA - chargerA - battery:alternatorAvailableA(rpm)

  -- cranking stats: lowest sustained voltage (after the first 0.3 s, so the starter's
  -- locked-rotor inrush doesn't count, like a load tester) and highest current
  if cranking then
    if not crank.active then
      crank.active, crank.elapsed, crank.minV, crank.peakA = true, 0, nil, starterA
    end
    crank.elapsed = crank.elapsed + dt
    crank.peakA = max(crank.peakA, starterA)
    if crank.elapsed >= 0.3 then
      crank.minV = crank.minV and min(crank.minV, battery.voltage) or battery.voltage
    end
  elseif crank.active then
    crank.active = false
    crank.lastMinV, crank.lastPeakA = crank.minV, crank.peakA
  end

  -- oil
  if oil and engine then
    oil:update(dt, s.oilC or ambientC, rpm, engine.lubrication,
      oilModel.levelFactor(engine.oilMass, engine.oilMinSafeMass))
  end

  -- intake air
  if intake then
    intake:update(dt, ambientC, coolant, speedKmh, e.boostKPa, baroKPa)
  end

  -- outputs (°C, kPa, V, A)
  s.nominalV = params.voltage
  s.batteryCCA, s.batteryAh = battery.cca, battery.capacityAh
  s.batteryV = battery.voltage
  s.batterySoc = battery.soc
  s.batteryA = battery.currentA
  s.batteryTempC = battery.tempC
  s.alternatorA = battery.alternatorOutA
  s.chargerA = battery.chargerOutA
  s.jumpLeads = battery.jump ~= nil
  s.loadA = battery.loadA
  s.batteryFreezeC = battery:freezePointC()
  s.supplyV, s.supplyR, s.otherLoadA = supplyV, supplyR, otherA
  -- what the battery would hold at the starter's locked-rotor inrush (the dead-battery click)
  s.inrushV = starter and starting.crankingSupply(supplyV, supplyR, otherA, starter.freeA, starter.lockedA,
    params.voltage, 0) or nil
  s.crankMinV = crank.active and crank.minV or crank.lastMinV
  s.crankPeakA = crank.active and crank.peakA or crank.lastPeakA
  s.cabinC = cabin.tempC
  s.blower = cabin.blowerLevel
  if oil then
    s.oilKPa = oil.pressureKPa
    s.oilReliefKPa = oil.reliefKPa
    s.oilViscosity = oil.viscosityCSt
    s.oilGrade = oil.grade
    s.oilBelowPumpLimit = oil.belowPumpLimit
  else
    s.oilKPa, s.oilReliefKPa, s.oilViscosity, s.oilGrade, s.oilBelowPumpLimit = nil, nil, nil, nil, nil
  end
  s.intakeC = intake and intake.tempC or nil
  if glow then
    s.glowState = glow.state
    s.glowWait = glow.wait
    s.glowPct = glow.preheatFraction
  else
    s.glowState, s.glowWait, s.glowPct = nil, nil, nil
  end
  return s
end

function M.getParams()
  return params
end

-- Console/test helper: set the battery's state of charge (0..1), e.g. to try a weak battery.
function M.setBatterySoc(soc)
  if battery then battery.soc = min(max(soc, 0), 1) end
end

-- Soak memory: the battery as it was left (soc 0..1, tempC may be nil).
function M.setBatteryState(soc, tempC)
  if not battery then return end
  if type(soc) == "number" and soc == soc then battery.soc = min(max(soc, 0), 1) end
  if type(tempC) == "number" and tempC == tempC then battery.tempC = tempC end
end

return M
