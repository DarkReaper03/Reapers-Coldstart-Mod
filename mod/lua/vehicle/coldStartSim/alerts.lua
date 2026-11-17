-- ColdStart Sim: warnings for the vehicle you sit in (the definitions and their logic live in
-- lua/common/coldStartSim/warnings.lua). Turns newly raised warnings into toasts and the chime,
-- explains a start that failed, plays the solenoid click, and hands the active list to the HUD.
-- Parked cars and traffic don't run it: nobody would see their dash.

local M = {}

local warningsLib = require("coldStartSim/warnings")

local chimeEvent = "event:>UI>Career>Fuel_Low" -- the game's own low-fuel chime (ui/soundClasses.json)
local clickEvent = "event:>UI>Main>switch" -- a switch click, for the starter solenoid
local toastSeconds = 6
local toastRepeatSeconds = 30 -- the same warning doesn't toast again sooner
local chimeRepeatSeconds = 2

-- from the settings (Phase 5): which warnings are off, from which level on they toast and chime
M.config = {disabled = {}, toasts = true, toastLevel = 2, chime = true, chimeLevel = 2}

local evaluator = nil
local inputs = {}
local toastTimers = {}
local chimeTimer = 0
local runSeconds, sinceCrank, wasCranking = 0, nil, false
local seenFailures, seenClicks = 0, 0

local failureTexts = {
  ["too slow"] = "Didn't start: it cranked too slowly to fire (thick oil or a weak battery). A block heater or a charger helps.",
  ["glow plugs"] = "Didn't start: the glow plugs weren't ready. Wait for the light to go out first.",
  voltage = "Didn't start: the battery voltage fell too low for the engine computer.",
  short = "Didn't start: keep cranking a little longer.",
}

function M.init()
  evaluator = warningsLib.new(M.config)
  for id in pairs(toastTimers) do toastTimers[id] = nil end
  chimeTimer, runSeconds, sinceCrank, wasCranking = 0, 0, nil, false
  seenFailures, seenClicks = 0, 0
end

-- cfg: {disabled = {[id] = true}, toasts, toastLevel, chime, chimeLevel}; missing keys keep their value
function M.configure(cfg)
  if type(cfg) ~= "table" then return end
  for key, value in pairs(cfg) do M.config[key] = value end
  if type(M.config.disabled) ~= "table" then M.config.disabled = {} end
  if evaluator then evaluator:configure(M.config) end
end

local function toast(id, text)
  if not M.config.toasts then return end
  if type(guihooks) ~= "table" or type(guihooks.message) ~= "function" then return end
  pcall(guihooks.message, text, toastSeconds, "coldStartSim.warn." .. id)
end

local function playUI(event)
  if obj and type(obj.queueGameEngineLua) == "function" then
    obj:queueGameEngineLua(string.format("if Engine and Engine.Audio then Engine.Audio.playOnce('AudioGui', %q) end", event))
  end
end

local function chime()
  if not M.config.chime or chimeTimer > 0 then return end
  chimeTimer = chimeRepeatSeconds
  playUI(chimeEvent)
end

-- s: sim.state; engine: adapter.readEngine output (nil without an engine); e: electrics;
-- start: coldstart.state; seated: the player sits in this vehicle; plug: services.state
function M.update(dt, s, engine, e, start, ambientC, seated, running, plug)
  if not evaluator then return end
  chimeTimer = math.max(chimeTimer - dt, 0)
  for id, timer in pairs(toastTimers) do
    toastTimers[id] = timer > dt and timer - dt or nil
  end

  local cranking = engine ~= nil and engine.cranking == true
  runSeconds = running and runSeconds + dt or 0
  if wasCranking and not cranking then sinceCrank = 0 elseif sinceCrank then sinceCrank = sinceCrank + dt end
  wasCranking = cranking
  if not seated then return end

  local x = inputs
  x.ignition, x.running, x.cranking = e.ignitionLevel or 0, running, cranking
  x.rpm, x.runSeconds = engine and engine.rpm or nil, runSeconds
  x.oilKPa, x.oilReliefKPa, x.oilC, x.oilViscosity = s.oilKPa, s.oilReliefKPa, s.oilC, s.oilViscosity
  if engine and engine.oilMass and engine.oilMinSafeMass and engine.oilMinSafeMass > 0 then
    x.oilLevel = engine.oilMass / engine.oilMinSafeMass
  else
    x.oilLevel = nil
  end
  x.coolantC, x.thermostatC = s.coolantC, engine and engine.thermostat or nil
  x.batteryV, x.nominalV, x.batterySoc, x.batteryA = s.batteryV, s.nominalV, s.batterySoc, s.batteryA
  x.batteryTempC = s.batteryTempC
  x.crankMinV, x.sinceCrank = s.crankMinV, sinceCrank
  x.glowWait = s.glowWait
  x.starterCutout = start and start.starterCutout or nil
  x.batteryFlat = start and start.batteryFlat or nil
  x.batteryFrozen = start and start.batteryFrozen or nil
  x.ambientC, x.intakeC = ambientC, s.intakeC
  x.pluggedIn = plug ~= nil and (plug.blockHeater or plug.charger or plug.jumpLeads) or nil
  x.droveOff = plug ~= nil and plug.droveOff or nil

  evaluator:update(dt, x)
  for _, event in ipairs(evaluator:popEvents()) do
    if event.level >= (M.config.toastLevel or 2) and not toastTimers[event.id] and warningsLib.toasts(event.id) then
      toastTimers[event.id] = toastRepeatSeconds
      toast(event.id, warningsLib.text(event.id, x, event.level))
    end
    if event.level >= (M.config.chimeLevel or 2) then chime() end
  end

  -- a start that failed: say why (the crank record knows what held the fuel back)
  if start and start.startFailedCount ~= seenFailures then
    seenFailures = start.startFailedCount
    -- (the starter's cut-out already has its own message)
    if (e.ignitionLevel or 0) >= 1 and start.startFailed ~= "starter hot" then
      toast("startFailed", failureTexts[start.startFailed] or ("Didn't start (" .. tostring(start.startFailed) .. ")."))
    end
  end
  -- the starter solenoid clicking on a flat battery
  if start and (start.clickCount or 0) ~= seenClicks then
    seenClicks = start.clickCount or 0
    playUI(clickEvent)
  end
end

-- Active warnings for the HUD ({{id, level, acked}, ...}), nil when there are none.
function M.activeList()
  if not evaluator then return nil end
  local list = evaluator:activeList()
  return #list > 0 and list or nil
end

-- Acknowledge one warning, or all of them (id nil): they stay lit, dimmed, and stop alerting.
function M.ack(id)
  if evaluator then evaluator:ack(id) end
end

function M.isActive(id)
  return evaluator ~= nil and evaluator:isActive(id)
end

return M
