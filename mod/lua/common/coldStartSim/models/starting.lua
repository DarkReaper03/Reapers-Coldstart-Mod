-- ColdStart Sim: cold-start physics layered on the game's own starter. Pure Lua.
--
-- The game's starter is a straight torque-speed line (combustionEngine.lua:783),
--     starter torque = starterTorque * (1 - w / starterMaxAV),
-- and while the fuel is cut the engine resists with friction + engineBrakeTorque + dynamicFriction * w.
-- The steady cranking speed is where the two meet, and in the stock game it is the same at -40 °C
-- as at 25 °C.
--
-- Cold model, relative to each vehicle's own stock cranking speed (so it behaves the same on every
-- vehicle, whatever its stock starter's headroom):
--   m = cranking-resistance multiplier from oil viscosity (1 warm; ~1.9 at -20 °C on 5W-30)
--   u = starter voltage relative to a normal warm cranking voltage (11 V per 12 V)
--   the starter is a DC motor whose torque line scales with u; with a reference headroom s0
--   (the share of stall torque a warm engine needs) its speed relative to stock is
--       r = (u - m * s0) / (1 - s0)
--   and its current follows the torque it delivers, as a share of stall torque:
--       tau = u - r * (1 - s0)            (= m * s0 once the speed has settled)
-- We then pick the game starterTorque that makes the game's own physics settle at r * stock speed.
-- Speeds are angular velocities (rad/s) unless the name says rpm.

local M = {}

local log10, max, min = math.log10, math.max, math.min

local function clamp(x, lo, hi)
  return min(max(x, lo), hi)
end

M.referenceHeadroom = 0.2 -- s0: share of stall torque a warm engine needs from the starter
M.referenceCrankingV = 11.0 -- normal warm cranking voltage, per 12 V
M.brownoutV = 7 -- per 12 V, under load: below this the ECU browns out (no injection or spark)
-- per 12 V, at the starter's locked-rotor inrush: below this the solenoid can't hold in. It pulls
-- in, the voltage collapses under the inrush and it drops out again: the starter only clicks.
-- With a 640 CCA battery and a V8 starter that's below ~7 % charge when warm, ~30 % at -20 °C,
-- ~40 % at -40 °C and ~50 % at -50 °C; a full battery turns it down to about -70 °C (in 0.8.0 a
-- full battery clicked below about -46 °C: the inrush was taken as a fixed current, see
-- crankingSupply).
M.solenoidHoldV = 6.0

-- Is the battery too flat to turn the starter at all? inrushV: battery voltage at the starter's
-- locked-rotor inrush (crankingSupply with relative = 0).
function M.solenoidClicks(inrushV, nominalV)
  return inrushV ~= nil and inrushV < M.solenoidHoldV * (nominalV or 12) / 12
end

-- Battery voltage and starter current solved together, so the two never chase each other from one
-- frame to the next. The battery (with jump leads, if any) is a source of supplyV volts behind
-- supplyR ohms (models/battery.lua thevenin) with otherA amps of other loads on it (net of a charger
-- or alternator). The starter draws freeA plus (lockedA - freeA) times the share of its stall torque
-- it delivers, tau = u - relative * (1 - s0) with u = V / 11 V (per 12 V): at a standstill it is a
-- resistance, so a weak battery's sag also cuts the current it has to supply (a fixed locked-rotor
-- current made a full battery at -50 °C look flat, 0.8.0), and it draws less as it speeds up.
-- relative: engine speed as a share of the stock cranking speed (0 = locked: the solenoid's inrush).
-- Returns volts, starter amps, torque share.
function M.crankingSupply(supplyV, supplyR, otherA, freeA, lockedA, nominalV, relative)
  local k = 12 / ((nominalV or 12) * M.referenceCrankingV) -- u per volt
  local slope = lockedA - freeA
  local lag = max(relative or 0, 0) * (1 - M.referenceHeadroom)
  local base = (otherA or 0) + freeA
  local volts = (supplyV - supplyR * (base - slope * lag)) / (1 + supplyR * slope * k)
  local share = k * volts - lag
  if share < 0 or share > 1.2 then -- overrunning (no torque) or at the clamp: a fixed current
    share = clamp(share, 0, 1.2)
    volts = supplyV - supplyR * (base + slope * share)
  end
  return max(volts, 0), freeA + slope * share, share
end

-- Steady cranking speed of the game's starter against the engine's resistance (0 if it can't turn it).
-- resistance: friction + engine-brake torque (Nm); dynamicFriction: Nm per rad/s.
function M.crankingAV(starterTorque, starterMaxAV, resistance, dynamicFriction)
  if not (starterTorque and starterMaxAV) or starterTorque <= 0 or starterMaxAV <= 0 then return nil end
  local av = (starterTorque - resistance) / (starterTorque / starterMaxAV + (dynamicFriction or 0))
  return max(av, 0)
end

-- Game starterTorque that makes the engine settle at targetAV (the inverse of crankingAV).
function M.starterTorqueFor(targetAV, starterMaxAV, resistance, dynamicFriction)
  if targetAV <= 0 then return resistance end -- balanced: the starter strains but can't turn it
  local slip = max(1 - targetAV / starterMaxAV, 0.01)
  return (resistance + (dynamicFriction or 0) * targetAV) / slip
end

-- How much harder a cold engine is to turn: 1 at the oil's 40 °C viscosity or thinner.
-- 5W-30: ~1.9 at -20 °C, ~2.2 at -30 °C, ~2.5 at -40 °C. 15W-40: ~2.0 at -20 °C.
function M.resistanceMultiplier(viscosityCSt, v40)
  local ratio = (viscosityCSt or v40) / v40
  if ratio <= 1 then return 1 end
  return 1 + 0.55 * log10(ratio)
end

-- Starter voltage relative to a normal warm cranking voltage (1 at 11 V per 12 V).
function M.voltageRatio(volts, nominalV)
  return clamp((volts or 12.6) * 12 / (nominalV or 12) / M.referenceCrankingV, 0, 1.2)
end

-- Cranking speed relative to the vehicle's stock cranking speed (0..1).
function M.relativeCrankingSpeed(voltageRatio, resistanceMultiplier)
  local s0 = M.referenceHeadroom
  return clamp((voltageRatio - resistanceMultiplier * s0) / (1 - s0), 0, 1)
end

-- Share of the starter's stall torque (and so of its stall current) it delivers at a relative speed.
function M.starterTorqueShare(voltageRatio, relativeSpeed)
  return clamp(voltageRatio - relativeSpeed * (1 - M.referenceHeadroom), 0, 1.2)
end

-- Slowest cranking speed, as a fraction of the vehicle's stock cranking speed, that still fires.
-- Diesels need more speed (compression heat); everything needs more in deep cold. With the model
-- above a healthy gasoline car starts at -30 °C and fails around -40 °C; a nearly flat battery
-- fails at -20 °C; a healthy diesel on 15W-40 starts at -20 °C and, slowly, at -30 °C.
function M.firingFraction(diesel, blockC)
  local base = diesel and 0.40 or 0.35
  return base + 0.1 * clamp((-20 - (blockC or 20)) / 20, 0, 1)
end

-- Glow-plug preheat (0..1) a diesel needs to fire: none above +10 °C, all of it at -15 °C and below.
function M.glowRequired(blockC)
  return clamp((10 - (blockC or 20)) / 25, 0, 1)
end

-- How much harder a cold running engine drags: a dynamicFriction multiplier, 1 at the oil's 90 °C
-- viscosity. 5W-30: ~1.4 at 20 °C, ~1.9 at -20 °C; capped at 2.2 (PLAN.md section 6).
-- strength scales it (Hardcore 1.25).
function M.dragMultiplier(viscosityCSt, hotViscosityCSt, strength)
  local ratio = (viscosityCSt or hotViscosityCSt) / hotViscosityCSt
  if ratio <= 1 then return 1 end
  strength = strength or 1
  return min(1 + 0.4 * strength * log10(ratio), 1 + 1.2 * strength)
end

-- Cold misfires after a start: stumbles per second. None above -15 °C coolant, most at -35 °C and
-- below, fading to none over `windowSeconds` of running; diesels misfire half as often once running.
function M.misfireRate(coolantC, runSeconds, windowSeconds, diesel, strength)
  if not coolantC or runSeconds >= windowSeconds then return 0 end
  local coldness = clamp((-15 - coolantC) / 20, 0, 1)
  return 2.5 * (strength or 1) * coldness * (1 - runSeconds / windowSeconds) * (diesel and 0.5 or 1)
end

-- Cold fast idle, rpm added on top of the stock idle; fades out by 40 °C coolant.
function M.fastIdleRPM(coolantC, diesel)
  return clamp((40 - (coolantC or 90)) / 60, 0, 1) * (diesel and 150 or 300)
end

return M
