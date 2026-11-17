-- ColdStart Sim: game-engine (GE) side. One instance for the whole game.
--
-- Phase 1: keeps a registry of the vehicles the mod attached to and writes a compatibility
-- report to settings/coldStartSim/debug/compat.json in the user folder. Each entry holds the
-- vehicle's detected profile plus the probe results measured on the vehicle side.
--
-- It also hosts the compatibility test runner. In the GE console run
--     coldStartSim_main.runCompatTest()           -- at the current outside temperature
--     coldStartSim_main.runColdTest()             -- at -20 C (or runColdTest(-35) etc.)
-- to swap your vehicle for each base vehicle in turn, cold-start it, record the result (compat.json,
-- "lastTest") and put your own vehicle back; a cold run also puts your temperature setting back.
-- coldStartSim_main.stopCompatTest() stops early.
--
-- Settings (0.3.2): coldStartSim_main.setPreset("casual") picks the realism preset (display, casual,
-- realistic, hardcore), saved in settings/coldStartSim/settings.json and sent to every vehicle.
-- Later phases add the settings screen, climate presets and soak memory here.

local M = {}

local presets = require("coldStartSim/presets")
local settingsModel = require("coldStartSim/settings")
local carsetup = require("coldStartSim/carsetup")
local defaults = require("coldStartSim/models/defaults")

M.version = "0.9.0" -- keep in sync with modVersion in lua/vehicle/extensions/auto/coldStartSim.lua

local logTag = "coldStartSim"
local reportDir = "settings/coldStartSim/debug/"
local reportPath = reportDir .. "compat.json"
local saveInterval = 2 -- seconds; batches report writes

local attached = {} -- [vehicleId] = report key
local versionWarned = {} -- [vehicle-side version] = true once the mismatch message was shown
local report = nil -- {modVersion, gameVersion, updated, vehicles = {[key] = entry}, lastTest}
local dirty = false
local saveTimer = 0
local memorySaveTimer = 0

local function timestamp()
  return os.date("%Y-%m-%d %H:%M:%S")
end

local function toJson(data)
  local ok, text = pcall(jsonEncode, data)
  return ok and text or tostring(data)
end

local function loadReport()
  local data = jsonReadFile(reportPath)
  if type(data) ~= "table" or type(data.vehicles) ~= "table" then
    data = {vehicles = {}}
  end
  report = data
end

local function saveReport()
  if not dirty or not report then return end
  dirty = false
  report.modVersion = M.version
  report.gameVersion = beamng_versiond or beamng_version
  report.updated = timestamp()
  local ok, err = pcall(function()
    FS:directoryCreate(reportDir, true)
    jsonWriteFile(reportPath, report, true)
  end)
  if not ok then
    log("W", logTag, "Could not write " .. reportPath .. ": " .. tostring(err))
  end
end

local function reportKey(profile)
  return tostring(profile.model or "unknown") .. " / " .. tostring(profile.configName or "default")
end

-- "1.2.3" -> 1002003, nil if it isn't a version string
local function versionNumber(version)
  local major, minor, patch = tostring(version):match("^(%d+)%.(%d+)%.(%d+)")
  if not major then return nil end
  return tonumber(major) * 1000000 + tonumber(minor) * 1000 + tonumber(patch)
end

----------------------------------------------------------------------------------------------------
-- Settings (lua/common/coldStartSim/settings.lua): saved in settings/coldStartSim/settings.json,
-- sent to every vehicle and to the HUD apps (UI event "ColdStartSimSettings"). The settings screen
-- (pause menu -> Mods -> ColdStart Sim) calls getSettings/getSettingsSchema/setSettings/resetSettings.
-- The effects switch (setEffectsEnabled) is for this session only.
----------------------------------------------------------------------------------------------------

local settingsPath = "settings/coldStartSim/settings.json"
local settings = nil -- see settings.lua
local effectsEnabled = true
local applyClimate -- (defined with the climate presets below)

local function loadSettings()
  local data = jsonReadFile(settingsPath)
  settings = settingsModel.sanitize(data) -- also migrates version 1 (preset only)
end

local function saveSettings()
  local ok, err = pcall(jsonWriteFile, settingsPath, settings, true)
  if not ok then log("W", logTag, "Could not save settings: " .. tostring(err)) end
end

-- What every vehicle runs. Vehicles still on code older than 0.3.2 only know the effects switch.
local function settingsCommand()
  if not settings then loadSettings() end
  local packet = serialize(settingsModel.forVehicle(settings, effectsEnabled))
  return "if coldStartSim then if coldStartSim.applySettings then coldStartSim.applySettings(" .. packet
    .. ") elseif coldStartSim.setEffectsEnabled then coldStartSim.setEffectsEnabled("
    .. tostring(effectsEnabled and settings.preset ~= "display") .. ") end end"
end

local function sendSettings(vehicle)
  if vehicle then vehicle:queueLuaCommand(settingsCommand()) end
end

-- The settings the UI sees: the saved ones plus this session's effects switch.
local function getSettings()
  if not settings then loadSettings() end
  local copy = settingsModel.sanitize(settings)
  copy.effectsOn = effectsEnabled
  return copy
end

local function notifyUI()
  if type(guihooks) == "table" and type(guihooks.trigger) == "function" then
    pcall(guihooks.trigger, "ColdStartSimSettings", getSettings())
  end
end

local function broadcastSettings()
  notifyUI()
  if type(getAllVehicles) ~= "function" then return end
  for _, vehicle in ipairs(getAllVehicles()) do sendSettings(vehicle) end
end

-- coldStartSim_main.setPreset("casual") in the console: display, casual, realistic or hardcore
-- (PLAN.md section 6). Saved, so it stays after a restart. Clears the per-effect changes, so the
-- preset applies as it is.
local function setPreset(name)
  if not settings then loadSettings() end
  local preset = presets.normalize(name)
  if not preset then
    local message = "ColdStart Sim: unknown preset '" .. tostring(name) .. "'. Use one of: " .. presets.list()
    log("W", logTag, message)
    ui_message(message, 8, "coldStartSim")
    return false
  end
  settings.preset = preset
  settings.effects = {}
  saveSettings()
  broadcastSettings()
  local message = "ColdStart Sim: " .. presets.presets[preset].label .. " preset"
  if not effectsEnabled then message = message .. " (effects are switched off this session)" end
  log("I", logTag, message)
  ui_message(message, 6, "coldStartSim")
  return true
end

-- Changes some settings: coldStartSim_main.setSettings({hud = {theme = "amber"}}). Nested tables
-- merge, lists (hud.tiles) are replaced. Saved and sent everywhere. Returns the new settings.
local function setSettings(partial)
  if not settings then loadSettings() end
  if type(partial) == "table" and partial.preset ~= nil and presets.normalize(partial.preset) ~= settings.preset
    and partial.effects == nil then
    partial.effects = false -- a new preset starts from its own effect values
  end
  local climateBefore = settings.sim.climate
  settings = settingsModel.merge(settings, partial)
  saveSettings()
  broadcastSettings()
  if settings.sim.climate ~= climateBefore then applyClimate() end
  return getSettings()
end

-- One section ("effects", "warnings", "hud", "lights") or everything (nil) back to the defaults.
local function resetSettings(section)
  if not settings then loadSettings() end
  local climateBefore = settings.sim.climate
  settings = settingsModel.reset(settings, section)
  saveSettings()
  broadcastSettings()
  if settings.sim.climate ~= climateBefore then applyClimate() end
  return getSettings()
end

local function getSettingsSchema()
  return settingsModel.schema()
end

-- HUD apps ask on mount; the answer comes as the ColdStartSimSettings event.
local function requestSettings()
  notifyUI()
end

----------------------------------------------------------------------------------------------------
-- Climate presets (settings.sim.climate): the game's own environment temperature, so stock systems
-- and the mod agree. Re-applied when a level starts and after Ctrl+L (which resets it).
----------------------------------------------------------------------------------------------------

local climateApplied = nil -- the preset we set, so "Map default" knows to put the map's curve back

function applyClimate()
  if not settings then loadSettings() end
  if type(core_environment) ~= "table" then return end
  local id = settings.sim.climate
  local climate = settingsModel.climateById[id]
  if climate and climate.averageC then
    pcall(core_environment.setTemperatureProfile, {averageC = climate.averageC, minC = climate.minC, maxC = climate.maxC})
    climateApplied = id
    log("I", logTag, "Climate: " .. climate.label)
  elseif climateApplied then
    pcall(core_environment.resetTemperatureProfile)
    climateApplied = nil
    log("I", logTag, "Climate: map default")
  end
end

----------------------------------------------------------------------------------------------------
-- Soak memory (settings.sim.soakMemory): each car sends its engine temperatures and battery state
-- every 10 s; when the same model/config spawns again it gets them back, cooled for the time that
-- has passed (lua/vehicle/extensions/auto/coldStartSim.lua restoreState). Kept for two days in
-- settings/coldStartSim/soak.json, so it works across game restarts too.
----------------------------------------------------------------------------------------------------

local soakPath = "settings/coldStartSim/soak.json"
local soakKeepSeconds = 2 * 24 * 3600
local memory = nil -- [report key] = {state = {...}, savedAt = os.time()}
local memoryDirty = false

local function loadMemory()
  local data = jsonReadFile(soakPath)
  memory = {}
  if type(data) ~= "table" then return end
  local now = os.time()
  for key, entry in pairs(data) do
    if type(entry) == "table" and type(entry.savedAt) == "number" and now - entry.savedAt < soakKeepSeconds then
      memory[key] = entry
    end
  end
end

local function saveMemory()
  if not memoryDirty or not memory then return end
  memoryDirty = false
  local ok, err = pcall(jsonWriteFile, soakPath, memory, true)
  if not ok then log("W", logTag, "Could not save the soak memory: " .. tostring(err)) end
end

-- Called by every car every 10 s.
local function vehicleState(vehicleId, state)
  if type(state) ~= "table" then return end
  if not memory then loadMemory() end
  local key = attached[vehicleId]
  if not key then return end
  memory[key] = {state = state, savedAt = os.time()}
  memoryDirty = true
end

-- A freshly spawned car: hand back the state its model/config was left in.
local function restoreMemory(vehicle, key)
  if not settings then loadSettings() end
  if not (vehicle and settings.sim.soakMemory) then return end
  if not memory then loadMemory() end
  local entry = memory[key]
  if not entry then return end
  local elapsed = os.time() - entry.savedAt
  if elapsed < 0 or elapsed > soakKeepSeconds then return end
  vehicle:queueLuaCommand(string.format(
    "if coldStartSim and coldStartSim.restoreState then coldStartSim.restoreState(%s, %d) end", serialize(entry.state), elapsed))
end

----------------------------------------------------------------------------------------------------
-- Per-car setup (0.9.0, lua/common/coldStartSim/carsetup.lua): the player's oil grade, battery,
-- voltage, fuel, glow plugs, block-heater power and effects switch for one model/config, saved in
-- settings/coldStartSim/vehicles.json and sent to the car whenever it spawns. The settings screen's
-- Car tab calls getCarSetup / setCarSetup / resetCarSetup for the car the player sits in.
----------------------------------------------------------------------------------------------------

local carSetupPath = "settings/coldStartSim/vehicles.json"
local carSetups = nil -- [report key] = setup

local function loadCarSetups()
  local data = jsonReadFile(carSetupPath)
  carSetups = {}
  if type(data) ~= "table" then return end
  for key, setup in pairs(data) do
    local clean = carsetup.sanitize(setup)
    if type(key) == "string" and not carsetup.isEmpty(clean) then carSetups[key] = clean end
  end
end

local function saveCarSetups()
  local ok, err = pcall(jsonWriteFile, carSetupPath, carSetups, true)
  if not ok then log("W", logTag, "Could not save the car setups: " .. tostring(err)) end
end

local function sendCarSetup(vehicle, setup, announce)
  if not vehicle then return end
  vehicle:queueLuaCommand(string.format("if coldStartSim and coldStartSim.applyCarSetup then coldStartSim.applyCarSetup(%s, %s) end",
    serialize(setup or {}), tostring(announce == true)))
end

-- The player's car: its vehicle object, report key and profile (nil if none attached).
local function playerCar()
  local vehicle = getPlayerVehicle(0)
  if not vehicle then return nil end
  local key = attached[vehicle:getId()]
  local entry = key and report and report.vehicles[key]
  return vehicle, key, entry and entry.profile
end

-- For the settings screen: {key, name, kind, setup, auto = {...}, choices}. auto holds what the car
-- runs with no setup (from its engine and any jbeam "coldStartSim" section). nil without a car.
local function getCarSetup()
  if not carSetups then loadCarSetups() end
  local _, key, profile = playerCar()
  if not key or type(profile) ~= "table" then return nil end
  local auto = defaults.forProfile(profile)
  local setup = carSetups[key] or {}
  local now = defaults.forProfile(profile, setup)
  return {
    key = key, name = profile.name, kind = profile.kind, setup = setup, choices = carsetup.choices,
    auto = {
      fuel = auto.fuel, oilGrade = auto.oil.grade, cca = math.floor(auto.battery.cca + 0.5),
      capacityAh = math.floor(auto.battery.capacityAh + 0.5), voltage = auto.voltage, glowPlugs = auto.glow ~= nil,
      heaterWatts = auto.heaterWatts,
    },
    current = {
      fuel = now.fuel, oilGrade = now.oil.grade, cca = math.floor(now.battery.cca + 0.5),
      capacityAh = math.floor(now.battery.capacityAh + 0.5), voltage = now.voltage, glowPlugs = now.glow ~= nil,
      heaterWatts = now.heaterWatts, effects = now.effects,
    },
  }
end

-- Changes the player's car's setup: setCarSetup({oilGrade = "0W-20"}); "auto" puts one value back.
-- Saved, applied to the car straight away (an oil change, a new battery size...). Returns getCarSetup().
local function setCarSetup(partial)
  if not carSetups then loadCarSetups() end
  local vehicle, key = playerCar()
  if not key then return nil end
  local setup = carsetup.merge(carSetups[key], partial)
  carSetups[key] = not carsetup.isEmpty(setup) and setup or nil
  saveCarSetups()
  sendCarSetup(vehicle, setup, true)
  return getCarSetup()
end

local function resetCarSetup()
  if not carSetups then loadCarSetups() end
  local vehicle, key = playerCar()
  if not key then return nil end
  carSetups[key] = nil
  saveCarSetups()
  sendCarSetup(vehicle, {}, true)
  return getCarSetup()
end

-- Keybinds and the settings screen: coldStartSim_main.vehicleAction("blockHeater") on the player's
-- car ("blockHeater", "charger", "jumpLeads", "batteryWarmer", "ackWarnings", "startingFluid",
-- "glowCycle", "newBattery").
local function vehicleAction(name)
  local vehicle = getPlayerVehicle(0)
  if not vehicle then return false end
  vehicle:queueLuaCommand(string.format("if coldStartSim and coldStartSim.action then coldStartSim.action(%q) end", tostring(name)))
  return true
end

-- coldStartSim_main.setEffectsEnabled(false) in the console: every car behaves stock again (the
-- gauges keep working) until true or a game restart. The preset is kept.
local function setEffectsEnabled(enabled)
  effectsEnabled = enabled ~= false
  broadcastSettings()
  local message = "ColdStart Sim: cold-start effects " .. (effectsEnabled and "on" or "off (stock behaviour, gauges only)")
  log("I", logTag, message)
  ui_message(message, 6, "coldStartSim")
end

-- After a game-engine Lua reload (Ctrl+L) the vehicles keep running and don't attach again. Ask
-- each one to send its profile again. This only needs coldStartSim.getProfile (vehicle code 0.1.1
-- and later), so it also reaches vehicles still running older code, which then get the version
-- message telling the player to press Ctrl+R. The trailing `true` marks it as a re-announce, which
-- keeps the vehicle's probe findings so far.
local reannounceCommand = "if coldStartSim and coldStartSim.getProfile then local p = coldStartSim.getProfile() "
  .. "if p then obj:queueGameEngineLua('if coldStartSim_main then coldStartSim_main.vehicleAttached(' "
  .. ".. obj:getId() .. ', ' .. serialize(p) .. ', true) end') end end"

local function reannounceVehicles()
  if type(getAllVehicles) ~= "function" then return end
  for _, vehicle in ipairs(getAllVehicles()) do
    vehicle:queueLuaCommand(reannounceCommand)
  end
end

----------------------------------------------------------------------------------------------------
-- Compatibility test runner
----------------------------------------------------------------------------------------------------

-- One of each kind of engine the mod has to handle. Config names are the .pc files in the game's
-- content/vehicles/<model>.zip; no config means the model's default.
local defaultTestVehicles = {
  {model = "covet"}, -- small gasoline I4
  {model = "pickup"}, -- gasoline V8 pickup
  {model = "pickup", config = "d35_crew_diesel_chiefrancher_A"}, -- diesel pickup
  {model = "etk800"}, -- modern turbo diesel (854 190d)
  {model = "us_semi"}, -- semi truck
  {model = "citybus"}, -- bus
  {model = "bolide"}, -- high-revving mid-engine
  {model = "moonhawk"}, -- classic V8
  {model = "pigeon"}, -- tiny engine
  {model = "autobello"}, -- small rear-engine classic
  {model = "sbr", config = "electric_300"}, -- electric
}

local pendingRestore = nil -- the player's vehicle, respawned one frame after a test ends
local spawnTimeout = 45 -- s (real time) for a vehicle to spawn and attach
local settleSeconds = 2 -- s (sim time) after attaching before cranking
local resultMargin = 30 -- s (sim time) on top of the crank timeout to wait for a result

local test = nil

local function fmt(x, decimals)
  if type(x) ~= "number" then return "-" end
  return string.format("%." .. (decimals or 0) .. "f", x)
end

local function makeEntry(profile, outcome)
  local primary = profile.primaryIndex and type(profile.engines) == "table" and profile.engines[profile.primaryIndex] or {}
  local entry = {
    model = profile.model,
    config = profile.configName,
    name = profile.name,
    kind = profile.kind,
    fuel = profile.fuel,
    systemVoltage = profile.systemVoltage,
    massKg = profile.massKg,
    engines = profile.engineCount,
    thermals = profile.thermals,
    turbo = profile.turbo,
    apiMissing = primary.apiMissing,
  }
  for key, value in pairs(outcome or {}) do
    entry[key] = value
  end
  return entry
end

local function describeResult(e)
  local head = tostring(e.model) .. " / " .. tostring(e.config or "default")
  if e.error then return head .. ": ERROR " .. tostring(e.error) end
  if e.skipped then return head .. ": skipped (" .. tostring(e.skipped) .. ")" end
  if e.aborted then return head .. ": aborted (" .. tostring(e.aborted) .. ")" end
  local missing = type(e.apiMissing) == "table" and #e.apiMissing or 0
  local models = type(e.models) == "table" and e.models or {}
  local start = type(e.start) == "table" and e.start or {} -- what the cold-start logic did (0.3.1+)
  local holds = start.holds and string.format(", held %s s (%s)", fmt(start.heldSeconds, 2), tostring(start.holds)) or ""
  if start.clicked then
    holds = holds .. string.format(", the starter only CLICKED (battery %s V under load)", fmt(start.batteryV, 1))
  end
  return string.format(
    "%s: %s %s, %s V, %s kg | block %s C, fuel cut %s s, cranked %s s at %s rpm -> %s, %s rpm after 3 s"
      .. " | cranking %s V / %s A peak, battery %s V, oil %s kPa"
      .. " | cold crank %s of %s rpm (fires above %s), fired after %s s%s | missing fields: %d",
    head, tostring(e.kind), tostring(e.fuel), fmt(e.systemVoltage), fmt(e.massKg), fmt(e.blockAtCrankC, 1),
    fmt(e.fuelCutSeconds, 2), fmt(e.crankSeconds, 2), fmt(e.crankRpm), e.caught and "CAUGHT" or "did not catch",
    fmt(e.rpmAfterStart), fmt(models.crankMinV, 2), fmt(models.crankPeakA), fmt(models.batteryV, 2),
    fmt(models.oilKPa), fmt(start.targetRPM), fmt(start.stockRPM), fmt(start.fireRPM), fmt(start.firedAfter, 2),
    holds, missing)
end

local function recordResult(entry)
  if test.instabilities then entry.instabilities = test.instabilities end
  table.insert(test.results, entry)
  log("I", logTag, "Test " .. #test.results .. "/" .. #test.list .. " " .. describeResult(entry))
end

-- Outside temperature for a test run, through the game's own environment (core_environment).
-- Note: reloading game-engine Lua (Ctrl+L) resets the environment, so the runner sets it itself.
local function currentAmbientC()
  local ok, kelvin = pcall(core_environment.getTemperatureK)
  return ok and type(kelvin) == "number" and kelvin - 273.15 or nil
end

-- What to put back afterwards: the player's own temperature override, if they had one.
local function saveTemperature()
  local ok, state = pcall(core_environment.getState)
  local profile = ok and type(state) == "table" and state.temperatureProfile or nil
  if type(profile) ~= "table" then return {override = false} end
  return {override = profile.enabled == true, averageC = profile.averageC, minC = profile.minC, maxC = profile.maxC}
end

-- A flat temperature all day. Returns the outside temperature actually in effect afterwards.
local function setFlatTemperature(celsius)
  pcall(core_environment.setTemperatureProfile, {averageC = celsius, minC = celsius, maxC = celsius})
  return currentAmbientC()
end

local function restoreTemperature(saved)
  if not saved then return end
  pcall(core_environment.resetTemperatureProfile)
  if saved.override then
    pcall(core_environment.setTemperatureProfile, {averageC = saved.averageC, minC = saved.minC, maxC = saved.maxC})
  end
end

local function finishTest()
  local results = test.results
  local caught, cranked = 0, 0
  for _, e in ipairs(results) do
    if e.caught ~= nil then
      cranked = cranked + 1
      if e.caught then caught = caught + 1 end
    end
  end

  if not report then loadReport() end
  report.lastTest = {
    startedAt = test.startedAt,
    finishedAt = timestamp(),
    stoppedEarly = test.stopped or nil,
    coldSoak = test.coldSoak,
    crankTimeout = test.crankTimeout,
    requestedAmbientC = test.requestedAmbientC,
    ambientC = test.ambientC,
    preset = getSettings().preset,
    effects = effectsEnabled,
    results = results,
  }
  dirty = true
  saveReport()

  local original = test.original
  local savedTemperature = test.savedTemperature
  test = nil
  restoreTemperature(savedTemperature)
  -- respawn the player's vehicle on the next frame, once the restored temperature has reached the
  -- vehicles (spawning in the same frame cold-soaked it to the test temperature)
  pendingRestore = original

  local summary = string.format("ColdStart Sim test finished: %d vehicles, %d of %d cranked engines caught. Details in %s",
    #results, caught, cranked, reportPath)
  log("I", logTag, summary)
  ui_message(summary, 12, "coldStartSim")
end

local function finite(x)
  return type(x) == "number" and x == x and x ~= math.huge and x ~= -math.huge
end

-- Where a vehicle stands, as spawn options use it: {pos = vec3, rot = quat} (the rotation in the
-- spawn convention, as core_vehicles.replaceVehicle converts it for keepOtherVehRotation).
-- nil when the vehicle's position is unusable (it blew up or fell off the map).
local function vehiclePose(veh)
  local ok, pose = pcall(function()
    local pos = vec3(veh:getPosition())
    return {pos = pos, rot = quat(0, 0, 1, 0) * quat(veh:getRefNodeRotation())}
  end)
  if not ok or not pose or not (finite(pose.pos.x) and finite(pose.pos.y) and finite(pose.pos.z)) then
    return nil
  end
  return pose
end

-- Spawns a vehicle in place of the player's at `pose` (the spot where the test started).
-- replaceVehicle puts the new vehicle where the old one is, so a test vehicle that rolled away or
-- blew up (a physics instability) carried the rest of the run off the map in 0.3.2: move the old
-- one home first. With no vehicle left to replace, the spawn options carry the pose.
local function spawnAt(model, config, pose)
  local options = {config = config}
  if pose then
    options.pos, options.rot = pose.pos, pose.rot
    local current = getPlayerVehicle(0)
    if current then
      local r = quat(0, 0, 1, 0) * pose.rot -- back to the object's own convention (spawn.safeTeleport)
      pcall(function() current:setPosRot(pose.pos.x, pose.pos.y, pose.pos.z, r.x, r.y, r.z, r.w) end)
    end
  end
  return pcall(core_vehicles.replaceVehicle, model, options)
end

local function runCompatTest(options)
  options = type(options) == "table" and options or {}
  if test then
    log("W", logTag, "A compatibility test is already running. Stop it with coldStartSim_main.stopCompatTest()")
    return
  end
  if not core_vehicles then
    log("E", logTag, "core_vehicles is not loaded; start a level in freeroam first")
    return
  end
  local veh = getPlayerVehicle(0)
  if not veh then
    ui_message("ColdStart Sim: spawn any vehicle first, then run the test again.", 6, "coldStartSim")
    return
  end
  local config = veh.partConfig
  test = {
    list = type(options.vehicles) == "table" and options.vehicles or defaultTestVehicles,
    index = 0,
    phase = "next",
    timer = 0,
    results = {},
    crankTimeout = tonumber(options.crankTimeout) or 15,
    coldSoak = options.coldSoak ~= false,
    original = {
      model = veh.JBeam,
      config = (type(config) == "string" and config:find("%.pc$")) and config or nil,
    },
    home = vehiclePose(veh), -- every test vehicle spawns here, and yours comes back here
    startedAt = timestamp(),
  }
  test.original.pose = test.home

  -- optional outside temperature for the run; the player's own setting comes back at the end
  local requested = tonumber(options.ambientC)
  if requested then
    test.requestedAmbientC = requested
    test.savedTemperature = saveTemperature()
    test.ambientC = setFlatTemperature(requested)
    if not test.ambientC or math.abs(test.ambientC - requested) > 2 then
      log("W", logTag, string.format("Could not set the outside temperature to %s C (environment changes may be locked here); testing at %s C",
        tostring(requested), tostring(test.ambientC)))
    end
  else
    test.ambientC = currentAmbientC()
  end

  local message = string.format("ColdStart Sim: testing %d vehicles at %s C (about %d min). Your vehicle comes back at the end. Don't pause the game.",
    #test.list, test.ambientC and string.format("%.0f", test.ambientC) or "?", math.ceil(#test.list * 20 / 60))
  log("I", logTag, message)
  ui_message(message, 10, "coldStartSim")
end

-- The compatibility test at -20 C (or another temperature): coldStartSim_main.runColdTest(-30)
local function runColdTest(celsius)
  runCompatTest({ambientC = tonumber(celsius) or -20})
end

local function stopCompatTest()
  if test then
    test.stopped = true
    test.phase = "finish"
  end
end

local function updateTest(dtReal, dtSim)
  if test.phase == "next" then
    test.index = test.index + 1
    local item = test.list[test.index]
    if not item then
      test.phase = "finish"
      return
    end
    test.current, test.attached, test.instabilities = item, nil, nil
    local ok, vehicle = spawnAt(item.model, item.config, test.home)
    if not ok or not vehicle then
      recordResult({model = item.model, config = item.config,
        error = ok and "could not spawn (model or config not found)" or tostring(vehicle)})
      return -- stays in "next"
    end
    test.expectedId = vehicle.getID and vehicle:getID() or nil
    test.phase, test.timer = "spawning", 0

  elseif test.phase == "spawning" then
    -- a heavy modded vehicle can freeze the game for a long time while it loads; that one long frame
    -- mustn't use up the whole timeout before the car's Lua even starts
    test.timer = test.timer + math.min(dtReal, 0.25)
    if test.timer > spawnTimeout then
      recordResult({model = test.current.model, config = test.current.config,
        error = "the mod did not attach within " .. spawnTimeout .. " s (the vehicle didn't finish spawning - beamng.log "
          .. "shows the game's error, e.g. a broken config in the vehicle mod - or it has no engine)"})
      test.phase = "next"
    end

  elseif test.phase == "settle" then
    test.timer = test.timer + dtSim
    if test.timer < settleSeconds then return end
    local profile = test.attached.profile
    if profile.kind ~= "ice" then
      recordResult(makeEntry(profile, {skipped = profile.kind == "ev" and "electric, nothing to crank" or "no combustion engine"}))
      test.phase = "next"
      return
    end
    local vehicle = getObjectByID(test.attached.id)
    if not vehicle then
      recordResult(makeEntry(profile, {error = "vehicle disappeared before the start"
        .. (test.instabilities and " (the game removed it after a physics instability)" or "")}))
      test.phase = "next"
      return
    end
    vehicle:queueLuaCommand(string.format("if coldStartSim then coldStartSim.testStart(%s, %s) end",
      tostring(test.crankTimeout), tostring(test.coldSoak)))
    test.phase, test.timer = "starting", 0

  elseif test.phase == "starting" then
    test.timer = test.timer + dtSim
    if test.timer > test.crankTimeout + resultMargin then
      recordResult(makeEntry(test.attached.profile, {error = "no result from the vehicle"}))
      test.phase = "next"
    end

  elseif test.phase == "finish" then
    finishTest()
  end
end

-- Called by the vehicle side (selftest.lua) when its start attempt is over.
local function testResult(vehicleId, result)
  if not test or test.phase ~= "starting" or not test.attached or test.attached.id ~= vehicleId then return end
  if type(result) ~= "table" then result = {error = "malformed result"} end
  recordResult(makeEntry(test.attached.profile, result))
  test.phase = "next"
end

----------------------------------------------------------------------------------------------------
-- Vehicle registry and report
----------------------------------------------------------------------------------------------------

-- Called by the vehicle side once it has attached to a vehicle (spawn, Ctrl+R), and again for every
-- vehicle after a game-engine reload with reannounced = true.
local function vehicleAttached(vehicleId, profile, reannounced)
  if type(profile) ~= "table" then return end
  sendSettings(getObjectByID(vehicleId)) -- preset and effects switch
  if not report then loadReport() end
  local key = reportKey(profile)
  attached[vehicleId] = key

  local entry = report.vehicles[key] or {}
  entry.profile = profile
  entry.lastSeen = timestamp()
  -- A new vehicle session starts a fresh set of probe findings: the probe numbers its starts from 1
  -- again, so keeping the old table mixed sessions (one car's report showed a warm start1 next to
  -- start2-5 from a -50 C session days earlier). A re-announce after Ctrl+L is the same session.
  entry.probe = reannounced and type(entry.probe) == "table" and entry.probe or {}
  report.vehicles[key] = entry
  dirty = true

  -- the player's setup for this model/config (0.9.0), before the soak memory so the restored battery
  -- state lands on the right battery; also after Ctrl+L, since the car may have missed a change.
  -- Compatibility-test vehicles run on their auto values.
  if not test then
    if not carSetups then loadCarSetups() end
    if carSetups[key] then sendCarSetup(getObjectByID(vehicleId), carSetups[key], false) end
  end

  -- a fresh spawn (not the re-announce after Ctrl+L, not a compatibility-test vehicle) starts where
  -- this model/config was left
  if not reannounced and not test then
    restoreMemory(getObjectByID(vehicleId), key)
  end

  log("I", logTag, string.format("Attached to %s (id %s): kind=%s fuel=%s engines=%s thermals=%s",
    key, tostring(vehicleId), tostring(profile.kind), tostring(profile.fuel),
    tostring(profile.engineCount), tostring(profile.thermals)))

  -- The game keeps game-engine Lua loaded until Ctrl+L, while vehicle Lua reloads only when the
  -- vehicle spawns or Ctrl+R is pressed, so after a code change the two halves can differ. Say
  -- which key fixes it instead of failing in odd ways.
  local vehicleVersion = tostring(profile.modVersion or "unknown")
  if vehicleVersion ~= M.version and not versionWarned[vehicleVersion] then
    versionWarned[vehicleVersion] = true
    local vehicleNumber, gameNumber = versionNumber(vehicleVersion), versionNumber(M.version)
    local message
    if vehicleNumber and gameNumber and vehicleNumber > gameNumber then
      message = string.format("ColdStart Sim: this vehicle runs newer mod code (%s) than the game (%s). Press Ctrl+L to reload game Lua.",
        vehicleVersion, M.version)
    else
      message = string.format("ColdStart Sim: this vehicle runs older mod code (%s) than the game (%s). Press Ctrl+R in the vehicle, or respawn it.",
        vehicleVersion, M.version)
    end
    log("W", logTag, message)
    ui_message(message, 15, "coldStartSim")
  end

  -- the vehicle the test runner just spawned (traffic may spawn the same model at the same time)
  if test and test.phase == "spawning" then
    local isExpected = test.expectedId ~= nil and vehicleId == test.expectedId
    local isPlayerSameModel = vehicleId == be:getPlayerVehicleID(0) and profile.model == test.current.model
    if isExpected or (test.expectedId == nil and isPlayerSameModel) then
      test.attached = {id = vehicleId, profile = profile}
      test.phase, test.timer = "settle", 0
    end
  end
end

-- Called by the vehicle-side probe with one finding (name -> table of measured values).
local function probeResult(vehicleId, name, data)
  local key = attached[vehicleId]
  if not key or not report then return end
  local entry = report.vehicles[key]
  if not entry then return end
  entry.probe[tostring(name)] = data
  dirty = true
  log("I", logTag, string.format("Probe '%s' on %s: %s", tostring(name), key, toJson(data)))
end

local function restorePlayerVehicle()
  local original = pendingRestore
  pendingRestore = nil
  if original and original.model and core_vehicles then
    local ok, err = spawnAt(original.model, original.config, original.pose)
    if not ok then
      log("W", logTag, "Could not put your vehicle back: " .. tostring(err))
    end
  end
end

local function onUpdate(dtReal, dtSim)
  if pendingRestore then restorePlayerVehicle() end
  if test then
    local ok, err = pcall(updateTest, dtReal or 0, dtSim or 0)
    if not ok then
      log("E", logTag, "Compatibility test stopped after an error: " .. tostring(err))
      if test then
        local finished, finishErr = pcall(finishTest)
        if not finished then
          log("E", logTag, "Could not finish the compatibility test: " .. tostring(finishErr))
        end
      end
      test = nil
    end
  end

  saveTimer = saveTimer + dtReal
  if saveTimer >= saveInterval then
    saveTimer = 0
    saveReport()
  end
  memorySaveTimer = memorySaveTimer + dtReal
  if memorySaveTimer >= 30 then
    memorySaveTimer = 0
    saveMemory()
  end
end

-- a level has started: put the climate preset on it
local function onClientPostStartMission()
  applyClimate()
end

local function onVehicleDestroyed(vehicleId)
  attached[vehicleId] = nil
end

-- The game found a physics instability on a vehicle (lua/ge/main.lua onInstabilityDetected: it
-- resets the vehicle, and removes it after a second one). Ask the vehicle what the mod had written
-- to its engine at that moment (probe "instability" in compat.json), and note it on a test vehicle.
local function onInstabilityDetected(vehicleId)
  local key = attached[vehicleId]
  if not key then return end
  log("W", logTag, string.format("Physics instability on %s (id %s); asking it what the mod had changed",
    key, tostring(vehicleId)))
  local vehicle = getObjectByID(vehicleId)
  if vehicle then
    vehicle:queueLuaCommand("if coldStartSim and coldStartSim.reportInstability then coldStartSim.reportInstability() end")
  end
  if test and test.attached and test.attached.id == vehicleId then
    test.instabilities = (test.instabilities or 0) + 1
  end
end

local function onExtensionLoaded()
  loadReport()
  loadSettings()
  loadMemory()
  log("I", logTag, "ColdStart Sim " .. M.version .. " loaded (" .. settings.preset .. " preset)")
  local ok, err = pcall(reannounceVehicles)
  if not ok then
    log("W", logTag, "Could not ask existing vehicles to re-register: " .. tostring(err))
  end
  -- Ctrl+L resets the environment: put the climate preset back if a level is running
  if type(getCurrentLevelIdentifier) == "function" and getCurrentLevelIdentifier() then
    pcall(applyClimate)
  end
end

local function onExtensionUnloaded()
  saveReport()
  saveMemory()
end

-- public interface (called from vehicle Lua through obj:queueGameEngineLua, or from the console)
M.vehicleAttached = vehicleAttached
M.probeResult = probeResult
M.testResult = testResult
M.runCompatTest = runCompatTest
M.stopCompatTest = stopCompatTest
M.runColdTest = runColdTest
M.setEffectsEnabled = setEffectsEnabled
M.setPreset = setPreset
M.getSettings = getSettings
M.setSettings = setSettings
M.resetSettings = resetSettings
M.getSettingsSchema = getSettingsSchema
M.requestSettings = requestSettings
M.vehicleState = vehicleState
M.vehicleAction = vehicleAction
M.getCarSetup = getCarSetup
M.setCarSetup = setCarSetup
M.resetCarSetup = resetCarSetup
M.getAttachedVehicles = function() return attached end

-- hooks
M.onUpdate = onUpdate
M.onVehicleDestroyed = onVehicleDestroyed
M.onInstabilityDetected = onInstabilityDetected
M.onClientPostStartMission = onClientPostStartMission
M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = onExtensionUnloaded

return M
