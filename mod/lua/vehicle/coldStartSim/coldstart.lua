-- ColdStart Sim: Phase 3 cold-start behaviour for one vehicle.
--
-- Changes how the engine starts, idles and runs when cold, only through effects.lua (undoable) and
-- only the fields PLAN.md section 6 allows:
--   starterTorque              slower cranking with thick oil and a sagging battery; back to stock
--                              strength (0.5 s ramp) once it fires, so the game's combustion catches
--   starterThrottleKillTimer   held while cranking if the engine can't fire yet: too slow, diesel
--                              glow plugs not ready, or the ECU browning out on low voltage
--   idleAV                     cold fast idle, fading out as the coolant warms
--   dynamicFriction            cold drag: thick oil makes a running cold engine work harder
--   ignitionCutTime            cold misfires: short ignition cuts in the first half minute
--   the starter itself         thermal cut-out after long cranking (deactivateStarter, and
--                              starterDisabled so the arcade gearbox doesn't keep restarting it)
--   thermals temperatures      cold soak at spawn; kept through a vehicle reset
-- friction is never touched (the game's damage code owns it and too much locks the engine up).
-- Which effects are on comes from the realism preset (coldStartSim/presets.lua).

local M = {}

local adapter = require("coldStartSim/adapter")
local effectsLib = require("coldStartSim/effects")
local presets = require("coldStartSim/presets")
local starting = require("coldStartSim/models/starting")
local oilModel = require("coldStartSim/models/oil")
local electrical = require("coldStartSim/models/electrical")

local num = adapter.num
local avToRPM = adapter.avToRPM
local exp, ln, max, min = math.exp, math.log, math.max, math.min

-- Effect toggles and strengths from the realism preset, plus the master switch `enabled`.
M.preset = presets.default
M.options = presets.options(M.preset)
M.options.enabled = true

local catchRampSeconds = 0.5 -- once it fires, the starter gets back to its stock strength over this long
local starterCoolSeconds = 90 -- starter cooling time constant
local starterResetShare = 2 / 3 -- the cut-out ends once the heat is back below this share of the limit
local starterReferenceShare = 0.4 -- torque share whose current adds one heat unit per second
local misfireWindowSeconds = 30 -- cold misfires fade out over this much running (x misfireStrength)
local misfireCutSeconds = 0.04 -- one stumble: a short ignition cut (x misfireStrength)
local clickShowSeconds = 3 -- the HUD shows the click this long
local clickMessageSeconds = 8 -- shortest time between two "battery flat" messages
-- starting fluid (0.9.0): ether in the intake fires at a much slower crank, and needs no glow-plug
-- preheat; a spray lasts this long
local etherSeconds = 15
local etherBonus = 0.2 -- taken off the share of stock cranking speed it needs to fire
local etherFloor = 0.12 -- ...but it still needs the engine turning at least this share

local handle = nil -- adapter engine handle (combustion engines only)
local fx = nil -- effects for that engine
local starter = nil -- starter motor current model
local diesel = false
local clickMessageTimer = 0
local oilV40 = 62
local oilVHot = 13 -- oil viscosity at 90 °C (no cold drag at or above it)
local nominalV = 12
local spawnHandled = false
local savedTemps = nil

-- what the cold-start logic is doing right now (read by telemetry and the self-test)
M.state = {
  stockRPM = nil, -- stock steady cranking speed
  targetRPM = nil, -- cranking speed the starter is set up for
  fireRPM = nil, -- slowest cranking speed that fires
  holdReason = nil, -- why the engine isn't allowed to fire: "too slow", "glow plugs", "voltage"
  firing = false, -- cranking with fuel flowing: the starter goes back to stock strength so it catches
  firingSeconds = 0,
  wasCranking = false,
  crank = {seconds = 0, heldSeconds = 0}, -- record of the current/last crank (see M.crankReport)
  starterA = nil, -- starter current for the battery model (nil = use the stock-starter estimate)
  resistance = 1, -- cold cranking-resistance multiplier
  fastIdleRPM = 0,
  spawnSoaked = false,
  dragMultiplier = 1, -- cold drag on dynamicFriction
  starterHeat = 0, -- heat units (~seconds of hard cranking), cooling with starterCoolSeconds
  starterCutout = false, -- the starter's thermal cut-out is open
  batteryFlat = false, -- the battery is too flat to turn the starter (its solenoid only clicks)
  batteryFrozen = false, -- Hardcore: the electrolyte froze; nothing until it thaws
  startFailed = nil, -- why the last crank ended without the engine running ("too slow", ... or "short")
  startFailedCount = 0, -- goes up by one for every failed start (the HUD/toasts watch it)
  clickSeconds = 0, -- > 0 for a moment after the starter clicked instead of cranking
  starterBlocked = false, -- we hold starterDisabled (arcade auto-start) for the cut-out or a flat battery
  runSeconds = 0, -- running since the last start
  misfireRate = 0, -- cold stumbles per second right now
  misfires = 0, -- stumbles since the last start
  etherSeconds = 0, -- > 0 while sprayed starting fluid is still in the intake (0.9.0)
}

local carEffectsOff = false -- the player switched the cold-start effects off for this car (0.9.0)
local switchedOff -- (defined below: gives every engine field back to the game)

local function resetRunState()
  local state = M.state
  state.crank = {seconds = 0, heldSeconds = 0}
  state.firing, state.firingSeconds, state.wasCranking = false, 0, false
  state.holdReason, state.starterA = nil, nil
  state.dragMultiplier, state.misfireRate, state.runSeconds, state.misfires = 1, 0, 0, 0
end

-- What depends on the car's setup (models/defaults.lua forProfile): the starter, diesel or not, the
-- oil grade, the system voltage. Called by init, and again when the player changes the car's setup
-- (0.9.0), which must not reset anything else (a running engine isn't re-soaked).
function M.setParams(profile, params)
  starter = params and params.starter and electrical.newStarter(params.starter) or nil
  diesel = (params and params.fuel or profile.fuel) == "diesel"
  -- cold cranking resistance and cold drag compare the oil in the engine with the oil the engine is
  -- built for (its auto grade): the same as before for the auto oil, easier on a thinner winter oil,
  -- harder on a thick one (0.9.0; measured against the oil's own viscosity a 0W-20 barely helped)
  local oilParams = params and params.oil or {}
  local design = oilParams.designGrade or oilParams.grade
  local grade = design and oilModel.grades[design]
  oilV40 = grade and grade.v40 or 62
  oilVHot = oilModel.viscosityCurve(grade and design or oilModel.defaultGrade)(90)
  nominalV = params and params.voltage or 12
  M.setCarEffects(not (params and params.effects == false))
end

-- The player's per-car switch (0.9.0): false keeps this car stock (the gauges keep working), on top
-- of the preset and the session switch.
function M.setCarEffects(on)
  carEffectsOff = on == false
  M.options.enabled = M.options.effects ~= false and M.options.sessionOn ~= false and not carEffectsOff
  if not M.options.enabled then switchedOff() end
end

function M.init(engineHandle, profile, params)
  handle = engineHandle and engineHandle.isCombustion and engineHandle or nil
  fx = handle and effectsLib.new(handle.device) or nil
  M.state.etherSeconds = 0
  M.setParams(profile, params)
  spawnHandled = false
  savedTemps = nil
  M.state.spawnSoaked = false
  M.state.starterHeat, M.state.starterCutout = 0, false
  M.state.batteryFlat, M.state.clickSeconds, M.state.starterBlocked = false, 0, false
  M.state.batteryFrozen, M.state.clickCount = false, 0
  M.state.startFailed, M.state.startFailedCount = nil, 0
  clickMessageTimer = 0
  resetRunState()
end

-- What the starter works against while the fuel is cut: friction + engine braking (Nm) and the
-- speed-dependent part (Nm per rad/s). dynamicBase: use this dynamicFriction instead of the live
-- one (the stock value, without the cold drag).
local function resistanceOf(d, dynamicBase)
  local friction = (num(d.friction) or 0) * (num(d.wearFrictionCoef) or 1) * (num(d.damageFrictionCoef) or 1)
  local dynamic = (dynamicBase or num(d.dynamicFriction) or 0) * (num(d.wearDynamicFrictionCoef) or 1)
    * (num(d.damageDynamicFrictionCoef) or 1)
  return friction + (num(d.engineBrakeTorque) or 0), dynamic
end

local function noteHold(crank, reason)
  if not crank.holds then
    crank.holds = reason
  elseif not crank.holds:find(reason, 1, true) then
    crank.holds = crank.holds .. ", " .. reason
  end
end

local function notify(text)
  log("I", "coldStartSim", text)
  if type(guihooks) == "table" and type(guihooks.message) == "function" then
    pcall(guihooks.message, text, 6, "coldStartSim.starter") -- shown to the seated player only
  end
end

-- The arcade gearbox restarts a stalled engine by itself unless starterDisabled is set
-- (vehicleController.lua:314). Hold it while the starter's cut-out is open or the battery is flat;
-- set again every update because the game clears it when the engine catches and on reset.
local function updateStarterBlock()
  local state = M.state
  local blocked = state.starterCutout or state.batteryFlat or state.batteryFrozen
  if blocked then
    adapter.setStarterBlocked(handle, true)
  elseif state.starterBlocked then
    adapter.setStarterBlocked(handle, false)
  end
  state.starterBlocked = blocked and true or false
end

local function clearStarterCutout()
  M.state.starterCutout = false
end

-- Thick oil drags on a running cold engine: dynamicFriction scaled by the oil's viscosity.
local function updateDrag(s)
  if M.options.coldDrag and s.oilViscosity then
    local multiplier = starting.dragMultiplier(s.oilViscosity, oilVHot, M.options.dragStrength)
    M.state.dragMultiplier = multiplier
    fx:scale("dynamicFriction", multiplier)
  else
    M.state.dragMultiplier = 1
    fx:release("dynamicFriction")
  end
end

local function updateStarter(dt, engine, s, blockC, holdSeconds)
  local d = handle.device
  local state = M.state
  local resistance, dynamic = resistanceOf(d) -- what the game's physics use now (cold drag included)
  local _, stockDynamic = resistanceOf(d, fx:baseOf("dynamicFriction"))
  local maxAV = num(d.starterMaxAV)
  local stockTorque = fx:baseOf("starterTorque")
  local stockAV = maxAV and starting.crankingAV(stockTorque, maxAV, resistance, stockDynamic) or nil
  state.stockRPM = stockAV and stockAV * avToRPM or nil

  local multiplier = M.options.slowCranking and starting.resistanceMultiplier(s.oilViscosity, oilV40) or 1
  local voltage = starting.voltageRatio(s.batteryV, nominalV)
  state.resistance = multiplier
  local targetAV = nil
  if M.options.slowCranking and stockAV and stockAV > 0 then
    local share = max(starting.relativeCrankingSpeed(voltage, multiplier), M.options.minCrankingShare or 0)
    targetAV = stockAV * share
    state.targetRPM = targetAV * avToRPM
  else
    state.targetRPM = state.stockRPM
  end

  -- a crank that ended without the engine running (the key let go too soon, or it can't fire)
  if state.wasCranking and not engine.cranking then
    local caught = engine.starterMaxRPM and (engine.rpm or 0) > engine.starterMaxRPM * 1.05
    if not caught and state.crank.seconds > 0.3 then
      state.startFailed = state.starterCutout and "starter hot" or state.crank.holds or "short"
      state.startFailedCount = state.startFailedCount + 1
    end
  end

  -- every crank gets a fresh record
  if engine.cranking and not state.wasCranking then
    state.crank = {seconds = 0, heldSeconds = 0}
    state.firingSeconds = 0
  end
  state.wasCranking = engine.cranking
  local crank = state.crank

  -- can it fire? (only matters while the starter is engaged)
  state.holdReason = nil
  if engine.cranking and M.options.startFailures and stockAV then
    local fraction = starting.firingFraction(diesel, blockC) + (M.options.firingBonus or 0)
    local ether = state.etherSeconds > 0 -- starting fluid in the intake (0.9.0)
    if ether then
      fraction = max(fraction - etherBonus, etherFloor)
      crank.ether = true
    end
    state.fireRPM = stockAV * avToRPM * fraction
    if (engine.rpm or 0) < state.fireRPM then
      state.holdReason = "too slow"
    elseif diesel and not ether and s.glowPct ~= nil and s.glowPct < starting.glowRequired(blockC) then
      state.holdReason = "glow plugs"
    elseif s.batteryV and s.batteryV < starting.brownoutV * nominalV / 12 then
      state.holdReason = "voltage"
    end
    if state.holdReason then
      local remaining = num(d.starterThrottleKillTimer) or 0
      if remaining <= holdSeconds then
        -- the game's own cold fuel cut is over, so this hold is what keeps the fuel off (holds
        -- during the starter's spin-up, inside the game's cut, change nothing and aren't counted)
        crank.heldSeconds = crank.heldSeconds + dt
        noteHold(crank, state.holdReason)
      end
      -- keep the game's own cranking fuel cut going (combustionEngine.lua:433-444)
      d.starterThrottleKillTimer = max(remaining, holdSeconds)
    end
  end

  -- Cranking with fuel flowing means it's firing. The starter then goes back to its stock strength
  -- (over catchRampSeconds) so the engine spins up into the speed where the game's own combustion
  -- takes over, the way a real engine speeds up as it starts firing. Some stock engines can't catch
  -- below their stock cranking speed: in 0.3.0 the base 6.0 diesel D-Series got fuel at 161 rpm
  -- (stock 240) and never caught.
  local firing = engine.cranking and not state.holdReason and (num(d.starterThrottleKillCoef) or 1) >= 1
  state.firing = firing
  state.firingSeconds = firing and state.firingSeconds + dt or 0
  local catch = min(state.firingSeconds / catchRampSeconds, 1)

  if targetAV and catch < 1 then
    local torque = min(starting.starterTorqueFor(targetAV, maxAV, resistance, dynamic), stockTorque)
    fx:set("starterTorque", torque + (stockTorque - torque) * catch)
  else
    fx:release("starterTorque")
  end

  if engine.cranking then
    crank.seconds = crank.seconds + dt
    if firing then
      crank.firedAfter = crank.firedAfter or crank.seconds
    else -- what the slow cold crank looked like before it fired
      crank.stockRPM, crank.targetRPM, crank.fireRPM = state.stockRPM, state.targetRPM, state.fireRPM
      crank.resistance, crank.batteryV = multiplier, s.batteryV
    end
  end

  -- starter current for the battery: follows the torque the starter has to deliver, solved together
  -- with the battery's voltage (a weak battery's sag cuts the current too; taking the voltage from
  -- the last update instead made the two chase each other on a very weak one)
  if starter and stockAV and stockAV > 0 then
    local relative = min(((engine.rpm or 0) / avToRPM) / stockAV, 1.5)
    if not engine.cranking then
      state.starterA = 0
    elseif s.supplyV and s.supplyR then
      local _, amps = starting.crankingSupply(s.supplyV, s.supplyR, s.otherLoadA, starter.freeA, starter.lockedA,
        nominalV, relative)
      state.starterA = amps
    else
      state.starterA = starter:currentForTorqueShare(true, starting.starterTorqueShare(voltage, relative))
    end
  else
    state.starterA = nil
  end
end

-- The starter heats with the square of its current and cools with starterCoolSeconds. Past the
-- preset's limit its thermal cut-out opens: the starter stops and won't engage again until it has
-- cooled to starterResetShare of the limit (~35 s of hard cranking trips it at -20 °C, ~35 s of
-- rest resets it).
local function updateStarterHeat(dt, engine)
  local state = M.state
  local referenceA = starter and starter:currentForTorqueShare(true, starterReferenceShare) or nil
  if engine.cranking and state.starterA and referenceA and referenceA > 0 then
    local load = state.starterA / referenceA
    state.starterHeat = state.starterHeat + dt * load * load
  end
  state.starterHeat = state.starterHeat * exp(-dt / starterCoolSeconds)

  if not M.options.starterOverheat then
    clearStarterCutout()
    return
  end
  local limit = M.options.starterHeatLimit or 30
  if not state.starterCutout and state.starterHeat >= limit then
    state.starterCutout = true
    local coolSeconds = starterCoolSeconds * ln(state.starterHeat / (limit * starterResetShare))
    notify(string.format("Starter overheated: let it cool for about %d s", 5 * math.ceil(coolSeconds / 5)))
  elseif state.starterCutout and state.starterHeat < limit * starterResetShare then
    clearStarterCutout()
  end
  if state.starterCutout and engine.cranking then
    adapter.stopStarter(handle)
  end
end

-- A battery too flat to turn the starter: the solenoid pulls in, the voltage collapses under the
-- inrush and it drops out again, so the starter clicks instead of cranking. The game's starter is
-- stopped the moment it engages (like the cut-out) and the HUD and a message say why. Charging or a
-- jump start (Phase 6) brings it back. Returns true when it stopped the starter this update.
local function updateFlatBattery(dt, engine, s)
  local state = M.state
  clickMessageTimer = max(clickMessageTimer - dt, 0)
  state.clickSeconds = max(state.clickSeconds - dt, 0)
  state.batteryFlat = M.options.flatBattery and starting.solenoidClicks(s.inrushV, nominalV) or false
  -- Hardcore: below its freezing point (lower the fuller it is) the electrolyte freezes; it thaws
  -- 2 °C above it
  if M.options.batteryFreezing and s.batteryTempC and s.batteryFreezeC then
    state.batteryFrozen = s.batteryTempC < s.batteryFreezeC + (state.batteryFrozen and 2 or 0)
  else
    state.batteryFrozen = false
  end
  if not ((state.batteryFlat or state.batteryFrozen) and engine.cranking) then return false end

  adapter.stopStarter(handle)
  if state.clickSeconds <= 0 then -- a new turn of the key: a fresh crank record
    state.crank = {seconds = 0, heldSeconds = 0}
  end
  state.crank.clicked = true
  state.crank.batteryV = s.inrushV
  state.clickSeconds = clickShowSeconds
  state.clickCount = (state.clickCount or 0) + 1
  if clickMessageTimer <= 0 then
    clickMessageTimer = clickMessageSeconds
    if state.batteryFrozen then
      notify(string.format("Nothing... the battery is frozen (%.0f °C, it freezes below %.0f °C at this charge). Warm it up first.",
        s.batteryTempC, s.batteryFreezeC))
    else
      notify(string.format("Click... the battery is too flat to turn the starter (%.1f V under load). Charge it or jump-start it.",
        s.inrushV))
    end
  end
  return true
end

local function updateFastIdle(s)
  if M.options.fastIdle and s.coolantC then
    local addRPM = starting.fastIdleRPM(s.coolantC, diesel)
    M.state.fastIdleRPM = addRPM
    fx:offset("idleAV", addRPM / avToRPM)
  else
    M.state.fastIdleRPM = 0
    fx:release("idleAV")
  end
end

-- A deep-cold engine stumbles for its first half minute: short ignition cuts at random. Only for
-- the vehicle you sit in (background vehicles update twice a second, too coarse to matter).
local function updateMisfires(dt, engine, s, background)
  local state = M.state
  local running = not engine.cranking and engine.starterMaxRPM ~= nil
    and (engine.rpm or 0) > engine.starterMaxRPM * 1.1
  if running then
    if state.runSeconds == 0 then state.misfires = 0 end
    state.runSeconds = state.runSeconds + dt
  else
    state.runSeconds = 0
  end
  state.misfireRate = 0
  if not (M.options.misfires and running) or background then return end
  local strength = M.options.misfireStrength or 1
  state.misfireRate = starting.misfireRate(s.coolantC, state.runSeconds, misfireWindowSeconds * strength, diesel, strength)
  if state.misfireRate > 0 and math.random() < state.misfireRate * dt then
    local d = handle.device
    d.ignitionCutTime = max(num(d.ignitionCutTime) or 0, misfireCutSeconds * strength)
    state.misfires = state.misfires + 1
  end
end

function switchedOff()
  if fx then fx:restoreAll() end
  clearStarterCutout()
  local state = M.state
  state.batteryFlat, state.batteryFrozen, state.clickSeconds = false, false, 0
  if handle and state.starterBlocked then updateStarterBlock() end -- gives starterDisabled back
  state.holdReason, state.starterA = nil, nil
  state.firing, state.firingSeconds = false, 0
  state.dragMultiplier, state.misfireRate, state.fastIdleRPM = 1, 0, 0
end

-- engine: adapter.readEngine output; s: sim.state; ambientC: outside air.
-- holdSeconds: how long a fuel-cut hold must last until the next update (frame time or longer).
-- background: the vehicle nobody sits in, updated twice a second.
function M.update(dt, engine, s, ambientC, holdSeconds, background)
  if not handle or not engine then return end
  if not M.options.enabled or engine.disabled then -- switched off, or the game disabled/broke the engine
    switchedOff()
    return
  end

  -- first update: cold-soak an engine the game spawned pre-heated (startThermalsPreHeated)
  if not spawnHandled then
    spawnHandled = true
    if M.options.spawnSoak and handle.thermalsEnabled and ambientC and engine.oil and engine.oil > ambientC + 5 then
      adapter.setEngineTemperatures(handle, ambientC)
      M.state.spawnSoaked = true
    end
  end

  dt = dt or 0
  M.state.etherSeconds = max(M.state.etherSeconds - dt, 0)
  local blockC = s.blockC or ambientC or 20
  updateDrag(s)
  if updateFlatBattery(dt, engine, s) then
    engine.cranking = false -- it clicked: the starter is out again, nothing turned
  end
  updateStarter(dt, engine, s, blockC, holdSeconds or 0.05)
  updateStarterHeat(dt, engine)
  updateStarterBlock()
  updateFastIdle(s)
  updateMisfires(dt, engine, s, background)
end

local function round(x, step)
  if type(x) ~= "number" then return x end
  return math.floor(x / step + 0.5) * step
end

-- The last crank, for the compatibility report: stock and cold-target cranking speeds, the
-- slowest speed that fires, which holds kept the fuel off (and for how long), when it fired; plus
-- the preset and what the engine is doing now (starter heat, cold drag, misfires since the start).
function M.crankReport()
  local c, state = M.state.crank, M.state
  return {
    stockRPM = round(c.stockRPM, 1), targetRPM = round(c.targetRPM, 1), fireRPM = round(c.fireRPM, 1),
    resistance = round(c.resistance, 0.01), batteryV = round(c.batteryV, 0.01),
    holds = c.holds, heldSeconds = round(c.heldSeconds, 0.01),
    firedAfter = round(c.firedAfter, 0.01), crankSeconds = round(c.seconds, 0.01),
    preset = M.preset, starterHeat = round(state.starterHeat, 0.1), starterCutout = state.starterCutout or nil,
    dragMultiplier = round(state.dragMultiplier, 0.01), misfires = state.misfires,
    clicked = c.clicked, -- the battery was too flat to turn the starter
    ether = c.ether, -- starting fluid helped this crank (0.9.0)
  }
end

-- What the mod has done to the engine right now, for the report after a physics instability: every
-- field it tracks (stock value, what it wrote, what the engine holds), values it refused, and the
-- fields it writes directly. Non-finite numbers come back as strings (they can't be serialized).
function M.engineReport()
  local function safe(x)
    if type(x) ~= "number" then return x end
    return effectsLib.finite(x) and x or tostring(x)
  end
  local report = fx and fx:report() or {}
  local d = handle and handle.device
  if d then
    report.ignitionCutTime = safe(d.ignitionCutTime)
    report.starterThrottleKillTimer = safe(d.starterThrottleKillTimer)
    report.friction = safe(d.friction)
    report.rpm = safe(type(d.outputAV1) == "number" and d.outputAV1 * avToRPM or nil)
  end
  local state = M.state
  report.preset, report.enabled = M.preset, M.options.enabled
  report.dragMultiplier, report.fastIdleRPM = safe(state.dragMultiplier), safe(state.fastIdleRPM)
  report.targetRPM, report.starterHeat, report.misfires = safe(state.targetRPM), safe(state.starterHeat), state.misfires
  return report
end

-- Vehicle reset: called BEFORE the game resets the powertrain (the thermals still hold the
-- current temperatures), and AFTER it on the next update.
function M.onBeforeReset()
  if handle and handle.thermalsEnabled and M.options.enabled and M.options.keepTempsOnReset then
    savedTemps = adapter.getEngineTemperatures(handle)
  end
end

-- The temperatures were just set from the soak memory: the next update isn't a fresh spawn, and a
-- reset that's in progress (the game resets every car right after spawning it) must put these back,
-- not the ones it saved before they arrived (seen in game, 0.6.0).
function M.restoredTemperatures(temps)
  spawnHandled = true
  if savedTemps and type(temps) == "table" then
    for key, value in pairs(temps) do savedTemps[key] = value end
  end
end

function M.onAfterReset()
  if handle and savedTemps then
    adapter.setEngineTemperatureTable(handle, savedTemps)
  end
  savedTemps = nil
  spawnHandled = true -- a reset is not a spawn
end

-- Realism preset (presets.lua), the per-effect changes from the settings screen (overrides: only
-- known keys of the same type as the preset's) and the effects master switch.
function M.configure(presetName, effectsOn, overrides)
  M.preset = presets.normalize(presetName) or presets.default
  local options = presets.options(M.preset)
  if type(overrides) == "table" then
    for key, value in pairs(overrides) do
      if options[key] ~= nil and type(value) == type(options[key]) and key ~= "effects" then
        options[key] = value
      end
    end
  end
  options.sessionOn = effectsOn ~= false
  options.enabled = options.sessionOn and options.effects and not carEffectsOff
  M.options = options
  if not options.enabled then switchedOff() end
end

-- Effects on or off without changing the preset (console helper; stock behaviour for comparison).
-- The per-car switch (setCarEffects) still applies.
function M.setEnabled(enabled)
  M.options.sessionOn = enabled ~= false
  M.options.enabled = M.options.sessionOn and M.options.effects ~= false and not carEffectsOff
  if not M.options.enabled then switchedOff() end
end

function M.carEffectsOn()
  return not carEffectsOff
end

-- Starting fluid (0.9.0): a spray of ether into the air intake. For the next etherSeconds the engine
-- fires at a much slower crank (deep cold, a weak battery) and a diesel needs no glow-plug preheat.
-- s: sim.state. Returns true and a message, or false and why not.
function M.sprayStartingFluid(s)
  if not handle then return false, "Starting fluid: this vehicle has no combustion engine." end
  if not M.options.enabled then
    return false, "Starting fluid: not needed, the cold-start effects are off for this car."
  end
  M.state.etherSeconds = etherSeconds
  if diesel and s and (s.glowState == "preheat" or s.glowState == "crank" or s.glowState == "afterglow"
    or (s.glowPct or 0) > 0.5) then
    return true, "Starting fluid sprayed, with the glow plugs hot! Ether can pre-ignite on them and wreck a diesel."
  end
  return true, string.format("Starting fluid sprayed into the intake: crank within %d s.", etherSeconds)
end

-- put every stock value back (extension unload)
function M.restore()
  switchedOff()
end

return M
