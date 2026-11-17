-- ColdStart Sim: vehicle entry point.
--
-- The game loads every .lua file under lua/vehicle/extensions/auto/ for every vehicle
-- (lua/vehicle/main.lua), so this is the only file in auto/; the rest of the vehicle code lives
-- in lua/vehicle/coldStartSim/ and is loaded with require().
--
-- Finds the engines, builds a vehicle profile, runs the simulation models (battery, alternator,
-- oil pressure, glow plugs, cabin, intake air), applies the Phase 3 cold-start behaviour
-- (coldstart.lua: slower cold cranking, starts that can fail, cold fast idle, cold soak at spawn,
-- temperatures kept through resets) and streams everything to the HUD app. The Phase 1 probe still
-- measures stock behaviour for the compatibility report.
--
-- Console helpers (vehicle Lua context): coldStartSim.dump(), coldStartSim.status(),
-- coldStartSim.setEffectsEnabled(false) (stock behaviour), coldStartSim.setBatterySoc(0.3)
-- Compatibility test: run coldStartSim_main.runCompatTest() in the GE console; it calls testStart() here.

local M = {}

local modVersion = "0.9.0" -- keep in sync with coldStartSim_main.version (GE warns on mismatch)
local logTag = "coldStartSim"
local streamName = "coldStartSim"
local streamInterval = 1 / 15 -- seconds between HUD updates
local backgroundInterval = 0.5 -- seconds between model updates for vehicles nobody sits in

local adapter = require("coldStartSim/adapter")
local profileBuilder = require("coldStartSim/profile")
local telemetry = require("coldStartSim/telemetry")
local probe = require("coldStartSim/probe")
local selftest = require("coldStartSim/selftest")
local sim = require("coldStartSim/sim")
local coldstart = require("coldStartSim/coldstart")
local alerts = require("coldStartSim/alerts")
local services = require("coldStartSim/services")
local soakModel = require("coldStartSim/models/soak")
local carsetup = require("coldStartSim/carsetup")

local engines = {}
local profile = nil
local streamTimer = 0
local simTimer = 0
local resetPending = false
local failed = false
local engineState, electricsState = {}, {}
local ambientC, baroKPa = nil, nil
local reportProbe = nil -- function(name, data): sends a finding to the GE compatibility report
local snapshots = {sinceAttach = 0, running = 0, attachSent = false, runningSent = false}
local memoryTimer = 0
local memoryInterval = 10 -- seconds between soak-memory snapshots sent to GE
local updateMemory -- (defined below, used by attach's reset of the timer)
local carSetup = {} -- the player's setup for this car (carsetup.lua, 0.9.0), sent by GE after attaching

-- Runs `command` (a call on coldStartSim_main) in GE Lua, if the GE side is loaded.
local function callGE(command)
  obj:queueGameEngineLua("if coldStartSim_main then coldStartSim_main." .. command .. " end")
end

-- A message to the player in this car (and the log).
local function notify(text)
  log("I", logTag, text)
  if type(guihooks) == "table" and type(guihooks.message) == "function" then
    pcall(guihooks.message, text, 6, "coldStartSim.services")
  end
end

local function attach()
  engines = adapter.findEngines()
  profile = profileBuilder.build(engines)
  profile.modVersion = modVersion -- lets GE detect a stale half after code changes
  if profile.kind == "none" then
    return false -- trailers, props: nothing to simulate
  end
  carSetup = {}
  local params = sim.init(profile, adapter.ambientC(), carSetup)
  coldstart.init(profile.primaryIndex and engines[profile.primaryIndex] or nil, profile, params)
  alerts.init()
  services.init(profile.primaryIndex and engines[profile.primaryIndex] or nil, notify)
  services.configure({heaterWatts = params.heaterWatts})
  memoryTimer = 0

  -- register first: GE ignores probe results from vehicles it hasn't seen attach
  local vehicleId = obj:getId()
  callGE(string.format("vehicleAttached(%d, %s)", vehicleId, serialize(profile)))
  reportProbe = function(name, data)
    callGE(string.format("probeResult(%d, %q, %s)", vehicleId, name, serialize(data)))
  end
  probe.init(engines, profile, reportProbe)
  snapshots.sinceAttach, snapshots.running, snapshots.attachSent, snapshots.runningSent = 0, 0, false, false

  local primary = profile.primaryIndex and profile.engines[profile.primaryIndex] or {}
  log("I", logTag, string.format("ColdStart Sim %s attached to %s (%s): %s, %d engine(s), thermals %s",
    modVersion, tostring(profile.name), tostring(profile.configName), tostring(profile.kind),
    profile.engineCount, tostring(primary.thermals or "n/a")))
  return true
end

local function fail(where, err)
  failed = true
  log("E", logTag, "Disabled for this vehicle after an error in " .. where .. ": " .. tostring(err))
end

local function onExtensionLoaded()
  local ok, result = pcall(attach)
  if not ok then
    log("E", logTag, "Could not attach: " .. tostring(result))
    return false
  end
  return result -- false unloads the extension for this vehicle
end

-- Called BEFORE the game resets the powertrain (lua/vehicle/main.lua, onVehicleReset): the
-- thermals still hold the pre-reset values here, and anything written to the engine now would
-- be overwritten. Work that must survive the reset happens on the next updateGFX.
local function onReset()
  if failed then return end
  local ok, err = pcall(function()
    probe.onBeforeReset()
    coldstart.onBeforeReset() -- remember the temperatures before the game resets them
  end)
  if not ok then fail("onReset", err) end
  selftest.abort("vehicle was reset during the test")
  resetPending = true
end

-- Reads the primary engine and the electrics once; the models and the HUD share the result.
local function readInputs()
  local primary = profile.primaryIndex and engines[profile.primaryIndex] or nil
  local engine = primary and adapter.readEngine(primary, engineState) or nil
  if not adapter.readElectrics(electricsState) then
    electricsState.ignitionLevel = nil
  end
  ambientC = adapter.ambientC()
  baroKPa = adapter.ambientPressureKPa()
  return engine
end

-- Is the engine running? The game's own electrics flag, or (vehicles without it) the engine
-- turning above half its idle speed with the ignition on.
local function isRunning(engine)
  local running = electricsState.engineRunning
  if running == nil and engine then
    local idle = (profile.engines[profile.primaryIndex] or {}).idleRPM or 600
    running = engine.ignition and not engine.stalled and (engine.rpm or 0) > idle * 0.5
  end
  return running == true
end

local function buildPacket(engine)
  local packet = telemetry.build(profile, engine, electricsState, sim.state, ambientC, baroKPa, modVersion, coldstart.state)
  packet.warn = alerts.activeList()
  -- what's plugged in (services.lua)
  local plugged = services.state
  packet.heater = plugged.blockHeater or nil
  packet.charger = plugged.charger or nil
  packet.jump = plugged.jumpLeads or nil
  packet.warmer = plugged.batteryWarmer or nil
  -- the car's setup (0.9.0): what the models use now, and the starting fluid still in the intake
  local params = sim.getParams()
  if params then packet.fuel = params.fuel or packet.fuel end
  packet.battCCA = sim.state.batteryCCA
  packet.ether = coldstart.state.etherSeconds > 0 and math.ceil(coldstart.state.etherSeconds) or nil
  if coldstart.carEffectsOn() then packet.carEffects = nil else packet.carEffects = false end -- (not `and false or nil`)
  return packet
end

local function round(x, step)
  if type(x) ~= "number" then return x end
  return math.floor(x / step + 0.5) * step
end

-- What the models say right now, for the compatibility report (checks Phase 2 against real engines).
local function modelSnapshot(engine)
  local s = sim.state
  return {
    ambientC = round(ambientC, 0.1), ignition = electricsState.ignitionLevel, running = electricsState.engineRunning,
    rpm = round(engine and engine.rpm, 1), thermals = s.thermals,
    oilC = round(s.oilC, 0.1), coolantC = round(s.coolantC, 0.1),
    oilKPa = round(s.oilKPa, 1), oilReliefKPa = s.oilReliefKPa, oilViscosityCSt = round(s.oilViscosity, 1), oilGrade = s.oilGrade,
    batteryV = round(s.batteryV, 0.01), batterySoc = round(s.batterySoc, 0.001), batteryA = round(s.batteryA, 0.1),
    alternatorA = round(s.alternatorA, 0.1), loadA = round(s.loadA, 0.1), batteryTempC = round(s.batteryTempC, 0.1),
    crankMinV = round(s.crankMinV, 0.01), crankPeakA = round(s.crankPeakA, 1), nominalV = s.nominalV,
    cabinC = round(s.cabinC, 0.1), blower = s.blower, intakeC = round(s.intakeC, 0.1),
    glowState = s.glowState, glowPct = round(s.glowPct, 0.01),
  }
end

-- Two snapshots per vehicle: 3 s after attaching, and after 30 s of running.
local function updateSnapshots(dt, engine)
  if not reportProbe then return end
  snapshots.sinceAttach = snapshots.sinceAttach + dt
  if not snapshots.attachSent and snapshots.sinceAttach >= 3 then
    snapshots.attachSent = true
    reportProbe("sim3s", modelSnapshot(engine))
  end
  if electricsState.engineRunning then
    snapshots.running = snapshots.running + dt
    if not snapshots.runningSent and snapshots.running >= 30 then
      snapshots.runningSent = true
      reportProbe("simRunning30s", modelSnapshot(engine))
    end
  else
    snapshots.running = 0
  end
end

-- Soak memory (Phase 6): every 10 s GE gets this car's engine temperatures and battery state, and
-- hands them back (cooled for the time that has passed) when the same model/config spawns again.
local function memorySnapshot()
  local primary = profile and profile.primaryIndex and engines[profile.primaryIndex] or nil
  local temps = primary and primary.isCombustion and adapter.getEngineTemperatures(primary) or nil
  local s = sim.state
  return {temps = temps, soc = s.batterySoc, batteryTempC = s.batteryTempC, ambientC = ambientC}
end

function updateMemory(dt)
  if not reportProbe then return end
  memoryTimer = memoryTimer + dt
  if memoryTimer < memoryInterval then return end
  memoryTimer = 0
  callGE(string.format("vehicleState(%d, %s)", obj:getId(), serialize(memorySnapshot())))
end

-- From GE after a spawn: the state this model/config was left in, `elapsed` seconds ago. Cools it
-- to now (models/soak.lua) and applies it.
local soakTau = {
  engineBlockTemperature = soakModel.tauSeconds.block, cylinderWallTemperature = soakModel.tauSeconds.block,
  coolantTemperature = soakModel.tauSeconds.coolant, oilTemperature = soakModel.tauSeconds.oil,
  exhaustTemperature = soakModel.tauSeconds.exhaust,
}
local function restoreState(state, elapsed)
  if type(state) ~= "table" or failed then return end
  elapsed = math.max(tonumber(elapsed) or 0, 0)
  local outside = adapter.ambientC() or state.ambientC or 20
  local primary = profile and profile.primaryIndex and engines[profile.primaryIndex] or nil
  if primary and primary.isCombustion and type(state.temps) == "table" then
    local temps = {}
    for key, tau in pairs(soakTau) do
      local t = tonumber(state.temps[key])
      if t then temps[key] = soakModel.cool(t, outside, elapsed, tau) end
    end
    adapter.setEngineTemperatureTable(primary, temps)
    coldstart.restoredTemperatures(temps) -- don't cold-soak it, and survive a reset in progress
  end
  local soc = tonumber(state.soc)
  if soc then
    -- the clock, alarm and ECU memory drain ~30 mA while parked
    local params = sim.getParams()
    local capacity = params and params.battery and params.battery.capacityAh or 60
    sim.setBatteryState(soc - 0.03 * elapsed / 3600 / capacity,
      tonumber(state.batteryTempC) and soakModel.cool(state.batteryTempC, outside, elapsed, soakModel.tauSeconds.battery) or nil)
  end
  log("I", logTag, string.format("Restored this car's state from %.0f min ago (soak memory)", elapsed / 60))
end

local function update(dt)
  if resetPending then
    resetPending = false
    probe.onAfterReset()
    coldstart.onAfterReset() -- put the remembered temperatures back after the game's reset
  end

  probe.update(dt)
  selftest.update(dt)

  -- full rate for the vehicle you sit in, a light update for parked cars and traffic
  simTimer = simTimer + dt
  local seated = not playerInfo or playerInfo.firstPlayerSeated ~= false
  local engine = nil
  if seated or simTimer >= backgroundInterval then
    local stepDt = simTimer
    simTimer = 0
    engine = readInputs()
    local running = isRunning(engine)
    services.update(stepDt, (electricsState.airspeed or 0) * 3.6, ambientC)
    sim.update(stepDt, engine, electricsState, ambientC, baroKPa, coldstart.state.starterA, services.electrical(running))
    -- runs before the game's own engine update this frame (lua/vehicle/main.lua:99-101); a fuel-cut
    -- hold has to last until the next of our updates
    coldstart.update(stepDt, engine, sim.state, ambientC, seated and 0.05 or backgroundInterval + 0.1, not seated)
    alerts.update(stepDt, sim.state, engine, electricsState, coldstart.state, ambientC, seated, running, services.state)
    updateSnapshots(stepDt, engine)
    updateMemory(stepDt)
  end

  streamTimer = streamTimer + dt
  if streamTimer >= streamInterval then
    streamTimer = 0
    if streams.willSend(streamName) then
      if not engine then engine = readInputs() end
      guihooks.queueStream(streamName, buildPacket(engine))
    end
  end
end

-- Phase 7: what the mod costs per frame on this car (PLAN.md budget: under 0.05 ms for the car you
-- sit in), reported once after 30 s as the probe finding "perf". os.clockhp is the game's
-- high-resolution clock (lua/vehicle/ve_utils.lua HighPerfTimer).
local clockhp = os.clockhp or os.clock
local perf = {ms = 0, frames = 0, maxMs = 0, elapsed = 0, sent = false}

local function updateGFX(dt)
  if failed then return end
  local started = clockhp()
  local ok, err = pcall(update, dt)
  if not ok then fail("updateGFX", err) end
  local ms = (clockhp() - started) * 1000
  perf.ms, perf.frames, perf.elapsed = perf.ms + ms, perf.frames + 1, perf.elapsed + (dt or 0)
  if ms > perf.maxMs then perf.maxMs = ms end
  if not perf.sent and perf.elapsed >= 30 and reportProbe then
    perf.sent = true
    reportProbe("perf", {avgMs = round(perf.ms / perf.frames, 0.0001), maxMs = round(perf.maxMs, 0.001),
      frames = perf.frames, seated = not playerInfo or playerInfo.firstPlayerSeated ~= false})
  end
end

local function dumpPacket()
  if not profile then return end
  dump(buildPacket(readInputs()))
end

local function status()
  if not profile then return "not attached" end
  return string.format("%s %s | kind=%s fuel=%s engines=%d failed=%s preset=%s effects=%s | %.4f ms/frame", modVersion,
    tostring(profile.name), tostring(profile.kind), tostring(profile.fuel), profile.engineCount, tostring(failed),
    tostring(coldstart.preset), tostring(coldstart.options.enabled), perf.frames > 0 and perf.ms / perf.frames or 0)
end

-- Compatibility test step for this vehicle: stop, cold-soak, crank, report (see selftest.lua).
-- Called from GE by coldStartSim_main's test runner; the result goes back to its testResult().
local function testStart(timeoutSeconds, coldSoak)
  local vehicleId = obj:getId()
  local function sendResult(result)
    callGE(string.format("testResult(%d, %s)", vehicleId, serialize(result)))
  end
  local primary = profile and profile.primaryIndex and engines[profile.primaryIndex] or nil
  if failed then
    sendResult({skipped = "the mod disabled itself on this vehicle after an error (see log)"})
  elseif not primary or not primary.isCombustion then
    sendResult({skipped = "no combustion engine"})
  else
    selftest.start(primary, timeoutSeconds, coldSoak, function(result)
      result.models = modelSnapshot(readInputs()) -- battery, oil pressure, glow plugs 3 s after the start
      result.start = coldstart.crankReport() -- what the cold-start logic did during the crank
      sendResult(result)
    end, function()
      return sim.state.glowWait == true -- a driver waits for the "wait to start" light
    end)
  end
end

-- Switch the cold-start effects off (true stock behaviour, for comparison) or back on.
local function setEffectsEnabled(enabled)
  coldstart.setEnabled(enabled ~= false)
  log("I", logTag, "Cold-start effects " .. (enabled ~= false and "on" or "off (stock behaviour)"))
end

-- Settings from the game-engine side (coldStartSim_main): realism preset and the effects switch.
-- settings: {preset = "realistic", effects = true}
local function applySettings(settings)
  if type(settings) ~= "table" then return end
  alerts.configure(settings.warnings)
  services.configure(settings.services)
  local before = coldstart.preset .. "/" .. tostring(coldstart.options.enabled)
  coldstart.configure(settings.preset, settings.effects ~= false, settings.overrides)
  local after = coldstart.preset .. "/" .. tostring(coldstart.options.enabled)
  if after ~= before then
    log("I", logTag, "Settings: preset " .. coldstart.preset .. ", effects " .. (coldstart.options.enabled and "on" or "off"))
  end
end

-- The player's setup for this car (0.9.0, carsetup.lua), from GE: after attaching (announce nil) and
-- when it is changed in the settings screen (announce true: say what changed). The models get the new
-- parameters and keep their state (sim.reconfigure, coldstart.setParams).
local function applyCarSetup(setup, announce)
  if failed or not profile then return end
  carSetup = carsetup.sanitize(setup)
  local params = sim.reconfigure(profile, carSetup)
  if not params then return end
  coldstart.setParams(profile, params)
  services.configure({heaterWatts = params.heaterWatts})
  local text = "Car setup: " .. carsetup.describe(carSetup)
  if announce then notify(text) else log("I", logTag, text) end
end

-- GE asks after the game found a physics instability on this vehicle: what the mod had written to
-- the engine at that moment goes to the compatibility report as the probe finding "instability".
local function reportInstability()
  if not reportProbe then return end
  local ok, data = pcall(coldstart.engineReport)
  reportProbe("instability", ok and data or {error = tostring(data)})
end

-- Console helper to try a weak battery: coldStartSim.setBatterySoc(0.3)
local function setBatterySoc(soc)
  sim.setBatterySoc(tonumber(soc) or 0.9)
end

local function onExtensionUnloaded()
  coldstart.restore() -- give every engine field back to the game
end

-- hooks
M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = onExtensionUnloaded
M.onReset = onReset
M.updateGFX = updateGFX

-- settings and console helpers
M.applySettings = applySettings
M.setEffectsEnabled = setEffectsEnabled
M.setBatterySoc = setBatterySoc
M.reportInstability = reportInstability
M.ackWarnings = function(id) alerts.ack(id) end -- id nil: all of them (HUD lights, keybind)
M.restoreState = restoreState -- soak memory, from GE

M.applyCarSetup = applyCarSetup -- per-car setup, from GE
M.getCarSetup = function() return carSetup end

-- Keybinds and the settings screen: coldStartSim.action("blockHeater") toggles, (name, true/false)
-- sets: "blockHeater", "charger", "jumpLeads", "batteryWarmer". One-off actions: "ackWarnings",
-- "startingFluid", "glowCycle", "newBattery" (0.9.0).
M.action = function(name, on)
  if failed or not profile then return nil end
  if name == "ackWarnings" then
    alerts.ack(nil)
    return true
  elseif name == "startingFluid" then
    local ok, text = coldstart.sprayStartingFluid(sim.state)
    notify(text)
    return ok
  elseif name == "glowCycle" then
    local seconds = sim.glowCycle()
    if seconds then
      notify(seconds > 0 and string.format("Glow plugs: preheating again (%d s). Wait for the light.", math.ceil(seconds))
        or "Glow plugs: not needed at this temperature.")
    else
      notify(sim.getParams() and sim.getParams().glow and "Glow plugs: turn the key to ON first (not running, not cranking)."
        or "Glow plugs: this engine has none.")
    end
    return seconds ~= nil
  elseif name == "newBattery" then
    if (electricsState.airspeed or 0) > 1 then
      notify("New battery: stop the car first.")
      return false
    end
    sim.newBattery()
    notify("New battery fitted: fully charged (at the temperature the old one had).")
    return true
  end
  return services.set(name, on)
end
M.getServices = function() return services.state end
M.getStartState = function() return coldstart.state end
M.getOptions = function() return coldstart.options end -- the effects in force (preset + overrides)

-- console helpers
M.dump = dumpPacket
M.status = status
M.getProfile = function() return profile end

-- compatibility test (called from GE)
M.testStart = testStart

return M
