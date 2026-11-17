-- ColdStart Sim: Phase 1 probe.
--
-- Measures how the stock engine and thermals behave on this vehicle and reports each finding to
-- the GE side, which writes it to settings/coldStartSim/debug/compat.json. The numbers are the
-- baseline that Phase 2 and 3 are tuned against:
--   ambient   environment readings (temperature, pressure, air density)
--   spawn     temperatures right after spawning vs ambient (effect of startThermalsPreHeated)
--   reset     temperatures before/after a vehicle reset (powertrain.reset runs after onReset)
--   startN    stock cranking: steady cranking rpm on the starter alone, fuel-cut time, how long
--             until the engine caught, block/oil temperature
--   warmup    oil/coolant/block temperatures every 60 s for the first 5 minutes after a cold start
--   cooldown  oil/coolant/block cooling time constants with the engine off (10-minute window)

local M = {}

local adapter = require("coldStartSim/adapter")
local num = adapter.num

local maxStartReports = 5
local steadyCrankAfter = 0.3 -- s; ignore the starter's spin-up when averaging cranking rpm
local warmupInterval = 60 -- s between warm-up samples
local warmupSamples = 5
local warmupMaxAboveAmbient = 10 -- °C; only measure warm-ups that start from a cold engine
local cooldownSeconds = 600
local cooldownMinAboveAmbient = 30 -- °C; smaller differences are swamped by heat soak

local reportFn = nil
local primary = nil
local done = {}
local beforeReset = nil
local cooldown = nil
local warmup = nil
local crank = nil
local starts = 0

local function round(x, step)
  if not x then return nil end
  step = step or 0.01
  return math.floor(x / step + 0.5) * step
end

local function report(name, data)
  if reportFn then reportFn(name, data) end
end

local function temps(d)
  local t = d.thermals
  return {
    oil = round(num(t.oilTemperature), 0.1),
    coolant = round(num(t.coolantTemperature), 0.1),
    block = round(num(t.engineBlockTemperature), 0.1),
    exhaust = round(num(t.exhaustTemperature), 0.1),
  }
end

local function rpmOf(d)
  return (num(d.outputAV1) or 0) * adapter.avToRPM
end

local function starterMaxRPMOf(d)
  return (num(d.starterMaxAV) or 0) * adapter.avToRPM
end

function M.init(engines, profile, fn)
  reportFn = fn
  primary = profile.primaryIndex and engines[profile.primaryIndex] or nil
  if primary and not (primary.isCombustion and primary.hasThermals) then
    primary = nil
  end
  done, beforeReset, cooldown, warmup, crank, starts = {}, nil, nil, nil, nil, 0

  local preheat = nil
  if settings and type(settings.getValue) == "function" then
    preheat = settings.getValue("startThermalsPreHeated")
  end
  report("ambient", {
    temperatureC = round(adapter.ambientC(), 0.1),
    pressureKPa = round(adapter.ambientPressureKPa(), 0.01),
    relativeAirDensity = round(num(obj:getRelativeAirDensity()), 0.001),
  })
  if primary then
    local spawn = temps(primary.device)
    spawn.ambient = round(adapter.ambientC(), 0.1)
    spawn.startThermalsPreHeated = preheat
    spawn.thermalsEnabled = primary.thermalsEnabled
    report("spawn", spawn)
  end
end

-- Runs inside onReset, i.e. BEFORE the game resets the powertrain.
function M.onBeforeReset()
  if primary and not done.reset then
    beforeReset = temps(primary.device)
  end
end

-- Runs on the first updateGFX after a reset, i.e. AFTER powertrain.reset().
function M.onAfterReset()
  crank, cooldown, warmup = nil, nil, nil
  if primary and beforeReset and not done.reset then
    local after = temps(primary.device)
    report("reset", {
      before = beforeReset,
      after = after,
      thermalsChangedByReset = beforeReset.oil ~= after.oil or beforeReset.coolant ~= after.coolant,
      ambient = round(adapter.ambientC(), 0.1),
    })
    done.reset = true
  end
  beforeReset = nil
end

local function updateCranking(dt, d)
  if starts >= maxStartReports then return end
  local engaged = (num(d.starterEngagedCoef) or 0) > 0
  local rpm = rpmOf(d)
  local starterMaxRPM = starterMaxRPMOf(d)

  if engaged then
    if not crank then
      crank = {
        seconds = 0, steadySum = 0, steadyCount = 0, rpmMax = 0,
        block = num(d.thermals.engineBlockTemperature),
        oil = num(d.thermals.oilTemperature),
        fuelCutSeconds = num(d.starterThrottleKillTimer),
      }
    end
    crank.seconds = crank.seconds + dt
    crank.rpmMax = math.max(crank.rpmMax, rpm)
    local fuelCut = (num(d.starterThrottleKillTimer) or 0) > 0
    if fuelCut and crank.seconds >= steadyCrankAfter then
      crank.steadySum = crank.steadySum + rpm
      crank.steadyCount = crank.steadyCount + 1
    elseif not fuelCut and not crank.rpmAtFuelOn then
      crank.rpmAtFuelOn = rpm
    end
    if not crank.caughtAfter and rpm > starterMaxRPM then
      crank.caughtAfter = crank.seconds
    end
  elseif crank then
    starts = starts + 1
    report("start" .. starts, {
      crankSeconds = round(crank.seconds, 0.01),
      fuelCutSeconds = round(crank.fuelCutSeconds, 0.01),
      crankRpm = crank.steadyCount > 0 and round(crank.steadySum / crank.steadyCount, 1) or nil,
      rpmAtFuelOn = round(crank.rpmAtFuelOn, 1),
      caughtAfterSeconds = round(crank.caughtAfter, 0.01),
      rpmMax = round(crank.rpmMax, 1),
      starterMaxRPM = round(starterMaxRPM, 1),
      blockC = round(crank.block, 0.1),
      oilC = round(crank.oil, 0.1),
      caught = rpm > starterMaxRPM * 1.1,
    })
    crank = nil
  end
end

local function updateWarmup(dt, d)
  if done.warmup or not primary.thermalsEnabled then return end
  local t = d.thermals
  local rpm = rpmOf(d)
  local running = rpm > starterMaxRPMOf(d) * 1.1 and (num(d.starterEngagedCoef) or 0) == 0
  if not running then
    warmup = nil -- stalled or switched off: measure again on the next cold start
    return
  end
  local ambient = adapter.ambientC()
  local oil = num(t.oilTemperature)
  if not warmup then
    if ambient and oil and oil - ambient <= warmupMaxAboveAmbient then
      warmup = {elapsed = 0, nextSample = warmupInterval, rpmSum = 0, loadSum = 0, frames = 0,
        ambient = ambient, samples = {{t = 0, oil = round(oil, 0.1),
        coolant = round(num(t.coolantTemperature), 0.1), block = round(num(t.engineBlockTemperature), 0.1)}}}
    end
    return
  end
  warmup.elapsed = warmup.elapsed + dt
  warmup.rpmSum = warmup.rpmSum + rpm
  warmup.loadSum = warmup.loadSum + (num(d.engineLoad) or 0)
  warmup.frames = warmup.frames + 1
  if warmup.elapsed < warmup.nextSample then return end

  table.insert(warmup.samples, {
    t = round(warmup.elapsed, 1),
    oil = round(num(t.oilTemperature), 0.1),
    coolant = round(num(t.coolantTemperature), 0.1),
    block = round(num(t.engineBlockTemperature), 0.1),
  })
  warmup.nextSample = warmup.nextSample + warmupInterval
  if #warmup.samples > warmupSamples then
    report("warmup", {
      ambient = round(warmup.ambient, 0.1),
      rpmAvg = round(warmup.rpmSum / math.max(warmup.frames, 1), 1),
      loadAvg = round(warmup.loadSum / math.max(warmup.frames, 1), 0.01),
      samples = warmup.samples,
    })
    done.warmup = true
    warmup = nil
  end
end

local function updateCooldown(dt, d)
  if done.cooldown or not primary.thermalsEnabled then return end
  local t = d.thermals
  local ambient = adapter.ambientC()
  local oil = num(t.oilTemperature)
  local engineOff = rpmOf(d) < 10 and (num(d.starterEngagedCoef) or 0) == 0
  if not (ambient and oil and engineOff) then
    cooldown = nil -- engine running: (re)start the measurement after it is switched off
    return
  end
  if not cooldown then
    if oil - ambient >= cooldownMinAboveAmbient then
      cooldown = {elapsed = 0, ambient = ambient, start = temps(d)}
    end
    return
  end
  cooldown.elapsed = cooldown.elapsed + dt
  if cooldown.elapsed < cooldownSeconds then return end

  local finish = temps(d)
  local function tauHours(key)
    local t0, t1 = cooldown.start[key], finish[key]
    if not (t0 and t1) then return nil end
    local d0, d1 = t0 - cooldown.ambient, t1 - cooldown.ambient
    if d0 <= 0.5 or d1 <= 0.05 or d1 >= d0 then return nil end
    return round(-cooldown.elapsed / math.log(d1 / d0) / 3600, 0.01)
  end
  report("cooldown", {
    seconds = round(cooldown.elapsed, 0.1),
    ambient = round(cooldown.ambient, 0.1),
    start = cooldown.start,
    finish = finish,
    oilTauHours = tauHours("oil"),
    coolantTauHours = tauHours("coolant"),
    blockTauHours = tauHours("block"),
  })
  done.cooldown = true
  cooldown = nil
end

function M.update(dt)
  if not primary or dt <= 0 then return end
  local d = primary.device
  updateCranking(dt, d)
  updateWarmup(dt, d)
  updateCooldown(dt, d)
end

return M
