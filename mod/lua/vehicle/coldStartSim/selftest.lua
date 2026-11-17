-- ColdStart Sim: vehicle side of the compatibility test (driven from GE by
-- coldStartSim_main.runCompatTest()).
--
-- Stops the engine, optionally cold-soaks the stock thermals to the outside temperature, turns the
-- key to ON and waits like a driver would (a second, or until a diesel's "wait to start" light goes
-- out), cranks until the engine catches or a timeout, releases the key, idles a few seconds and
-- reports what happened.

local M = {}

local adapter = require("coldStartSim/adapter")
local num = adapter.num

local stopTimeout = 10 -- s to wait for a running engine to spin down
local ignitionOnSeconds = 1.0 -- key at ON before cranking, like a driver would
local maxGlowWaitSeconds = 20 -- give up waiting for the glow-plug light after this long
local steadyCrankAfter = 0.3 -- s; ignore the starter's spin-up when averaging cranking rpm
local idleSeconds = 3 -- s after the start before reading idle rpm

local test = nil
local reportFn = nil
local waitLightFn = nil -- returns true while the "wait to start" light is on

local function round(x, step)
  if not x then return nil end
  step = step or 0.1
  return math.floor(x / step + 0.5) * step
end

local function thermalsOf(h)
  return h.hasThermals and h.device.thermals or nil
end

function M.isRunning()
  return test ~= nil
end

-- waitLight (optional): function returning true while the glow plugs are still preheating
function M.start(h, timeoutSeconds, coldSoak, fn, waitLight)
  reportFn = fn
  waitLightFn = waitLight
  test = {
    h = h, phase = "stop", timer = 0, firstFrame = true,
    timeout = timeoutSeconds or 15, coldSoak = coldSoak ~= false,
    result = {},
  }
end

local function finish()
  local result = test.result
  test = nil
  if reportFn then reportFn(result) end
end

function M.abort(reason)
  if not test then return end
  test.result.aborted = reason
  finish()
end

-- Turns the key; on failure ends the test with an error instead of waiting for a timeout.
local function turnKey(level)
  if adapter.setIgnitionLevel(level) then return true end
  test.result.error = "could not set ignition level " .. level .. " (unsupported vehicle controller)"
  finish()
  return false
end

function M.update(dt)
  if not test or dt <= 0 then return end
  local h, r = test.h, test.result
  local d = h.device
  local rpm = (num(d.outputAV1) or 0) * adapter.avToRPM
  local starterMaxRPM = (num(d.starterMaxAV) or 0) * adapter.avToRPM
  test.timer = test.timer + dt

  if test.phase == "stop" then
    if test.firstFrame then
      test.firstFrame = false
      local t = thermalsOf(h)
      r.ambientC = round(adapter.ambientC())
      r.wasRunning = rpm > starterMaxRPM * 1.1
      r.blockBeforeSoakC = t and round(num(t.engineBlockTemperature)) or nil
      if not turnKey(0) then return end
    end
    if rpm < 10 or test.timer > stopTimeout then
      if test.coldSoak then
        r.coldSoaked = adapter.setEngineTemperatures(h, adapter.ambientC())
      end
      if not turnKey(2) then return end
      test.phase, test.timer = "ignition", 0
    end

  elseif test.phase == "ignition" then
    local glowing = waitLightFn ~= nil and waitLightFn() == true
    if test.timer >= ignitionOnSeconds and (not glowing or test.timer >= maxGlowWaitSeconds) then
      r.keyOnSeconds = round(test.timer, 0.01) -- includes any glow-plug wait
      local t = thermalsOf(h)
      r.blockAtCrankC = t and round(num(t.engineBlockTemperature)) or nil
      if not turnKey(3) then return end
      test.phase, test.timer = "crank", 0
      test.engaged, test.steadySum, test.steadyCount = false, 0, 0
    end

  elseif test.phase == "crank" then
    local engaged = (num(d.starterEngagedCoef) or 0) > 0
    if engaged and not test.engaged then
      test.engaged = true
      r.fuelCutSeconds = round(num(d.starterThrottleKillTimer), 0.01)
    end
    if engaged and test.timer >= steadyCrankAfter and (num(d.starterThrottleKillTimer) or 0) > 0 then
      test.steadySum = test.steadySum + rpm
      test.steadyCount = test.steadyCount + 1
    end
    local caught = rpm > starterMaxRPM * 1.1
    if caught or (test.engaged and not engaged) or test.timer >= test.timeout then
      if not turnKey(2) then return end -- release the key
      r.starterEngaged = test.engaged
      r.caught = caught
      r.crankSeconds = round(test.timer, 0.01)
      r.crankRpm = test.steadyCount > 0 and round(test.steadySum / test.steadyCount, 1) or nil
      r.timedOut = not caught and test.timer >= test.timeout
      test.phase, test.timer = "idle", 0
    end

  elseif test.phase == "idle" then
    if test.timer >= idleSeconds then
      local t = thermalsOf(h)
      r.rpmAfterStart = round(rpm, 1)
      r.runningAfterStart = rpm > starterMaxRPM * 1.1
      r.oilAfterC = t and round(num(t.oilTemperature)) or nil
      finish()
    end
  end
end

return M
