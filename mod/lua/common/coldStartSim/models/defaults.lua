-- ColdStart Sim: turns a vehicle profile (lua/vehicle/coldStartSim/profile.lua) into model
-- parameters. Pure Lua. Car modders can override any of these from their jbeam with a
-- "coldStartSim" section (profile.authorConfig), e.g. {"oilGrade": "5W-40", "batteryCCA": 850}.

local M = {}

local max, min = math.max, math.min

local function clamp(x, lo, hi)
  return min(max(x, lo), hi)
end

local function primaryEngine(profile)
  local engines = type(profile.engines) == "table" and profile.engines or {}
  return engines[profile.primaryIndex or 1] or {}
end

function M.forProfile(profile)
  profile = profile or {}
  local engine = primaryEngine(profile)
  local author = type(profile.authorConfig) == "table" and profile.authorConfig or {}
  local diesel = profile.fuel == "diesel"
  local torque = engine.maxTorqueNm or 250
  local mass = profile.massKg or 1500
  local heavy = mass > 6000
  local voltage = author.voltage == 24 and 24 or (author.voltage == 12 and 12 or profile.systemVoltage or 12)

  -- Battery: bigger engines get bigger batteries; diesels usually run two in parallel; heavy
  -- trucks a bank of three or four. A 24 V system is two batteries in series (CCA per battery).
  local cca = clamp(400 + 0.6 * torque, 450, 1000) -- ~490 CCA small car, ~640 V8, ~1500 diesel pickup
  if diesel then cca = cca * 1.6 end
  if heavy then cca = max(cca, 1800) end
  cca = min(cca, 2500)
  if voltage == 24 then cca = clamp(cca / 1.6, 700, 1200) end
  cca = author.batteryCCA or cca

  -- Starter: its locked-rotor current grows with the engine, but a car's battery is always sized to
  -- turn its own starter (the CCA test: a full battery at -18 °C holds 7.2 V at the CCA current).
  -- Without this a monster-torque mod got a 1,400 A starter on a 1,000 CCA battery and only clicked
  -- at -20 °C on a full charge (a 2,600 Nm F-150 Raptor R mod, in game, 0.6.0). 12 V-equivalent amps:
  -- a 24 V starter draws half of this from batteries in series.
  local lockedA = author.starterLockedA or min(clamp(300 + 0.6 * torque, 350, 1400), 0.85 * cca * voltage / 12)

  local p = {
    voltage = voltage,
    battery = {
      voltage = voltage,
      cca = cca,
      capacityAh = author.batteryAh or cca / 10,
      alternatorA = author.alternatorA or clamp(80 + 0.08 * torque, 90, 220) * (voltage == 24 and 0.6 or 1),
      soc = 0.9,
    },
    starter = {
      lockedA = lockedA,
      nominalV = voltage,
    },
    oil = {
      grade = author.oilGrade or (diesel and "15W-40" or "5W-30"),
      idleRPM = engine.idleRPM or 750,
      hotIdleKPa = diesel and 180 or 170,
      reliefKPa = diesel and 550 or 480,
    },
    cabin = {
      size = clamp(mass / 1500, 0.6, 8),
      targetC = 21,
    },
    intake = {
      intercooled = engine.turbo == true or engine.supercharger == true,
    },
    diesel = diesel,
    electricRadiatorFan = engine.radiatorFan == "electric",
  }

  if diesel and author.glowPlugs ~= false then
    p.glow = {
      plugs = author.glowPlugCount or (torque < 450 and 4 or (torque < 1200 and 6 or 8)),
      nominalV = voltage,
    }
  end
  return p
end

return M
