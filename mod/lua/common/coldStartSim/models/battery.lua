-- ColdStart Sim: lead-acid starter battery, alternator and the electrical bus. Pure Lua.
--
-- Battery (per 12 V block; a 24 V system is two blocks in series):
--   open-circuit voltage  OCV = 11.8 + 0.9 * SOC
--   internal resistance   R = (5 / CCA) * e^(-0.018 * (T + 18)) * (1 + 2 * (1 - SOC)^3 + 2.8 * (1 - SOC)^5)
--   usable capacity       C * clamp(1 + 0.008 * (T - 25), 0.45, 1.05)
--   charge acceptance     falls with cold and with SOC
-- Alternator: output depends on its speed (engine rpm x pulley ratio); the regulator holds
-- 14.4 V minus 20 mV/°C of battery temperature, clamped to 13.8-14.9 V.
-- Bus: if the alternator covers the loads the bus sits at the regulator voltage and the spare
-- current charges the battery; otherwise the battery supplies the rest and V = OCV - I * R.
-- Units: V, A, Ah, °C, rpm, seconds. Battery current is + when discharging, - when charging.

local M = {}

local exp, max, min = math.exp, math.max, math.min

local Battery = {}
Battery.__index = Battery

-- params: voltage (12 or 24), capacityAh, cca, alternatorA, pulleyRatio, soc (0..1), tempC
function M.new(params)
  params = params or {}
  local self = setmetatable({}, Battery)
  self.nominalV = params.voltage == 24 and 24 or 12
  self.blocks = self.nominalV / 12
  self.capacityAh = params.capacityAh or 60
  self.cca = params.cca or 600
  self.alternatorA = params.alternatorA or 110
  self.pulleyRatio = params.pulleyRatio or 2.8
  self.soc = params.soc or 0.9
  self.tempC = params.tempC or 20

  self.voltage = self:openCircuitVoltage()
  self.currentA = 0
  self.alternatorOutA = 0
  self.loadA = 0
  return self
end

function Battery:openCircuitVoltage()
  return (11.8 + 0.9 * self.soc) * self.blocks
end

-- Rises in the cold (x1.8 at -50 °C against -18 °C) and steeply as the battery runs flat: x1.3 at
-- half charge, x4 at 10 %, x5.8 flat, where under a starter's current the voltage collapses (the
-- acid in the plates runs out). A full battery in deep cold is weak; a flat one can't turn a starter.
function Battery:internalResistance()
  local empty = 1 - self.soc
  local r = (5 / self.cca) * exp(-0.018 * (self.tempC + 18)) * (1 + 2 * empty ^ 3 + 2.8 * empty ^ 5)
  return r * self.blocks
end

-- The battery as a source for a load that depends on its voltage (the starter): an ideal source of
-- `volts` behind `ohms`. With jump leads the two batteries in parallel.
function Battery:thevenin()
  local ocv, r = self:openCircuitVoltage(), self:internalResistance()
  local jump = self.jump
  if jump then
    local conductance = 1 / r + 1 / jump.resistance
    return (ocv / r + jump.voltage / jump.resistance) / conductance, 1 / conductance
  end
  return ocv, r
end

-- Jump leads to a healthy donor battery: a 12.6 V source (per 12 V) behind 20 mΩ of battery and
-- leads, in parallel with ours. nil disconnects them.
function Battery:connectJumpLeads(connected)
  if connected then
    self.jump = {voltage = 12.6 * self.blocks, resistance = 0.02 * self.blocks}
  else
    self.jump = nil
  end
end

-- Terminal voltage while supplying a fixed `amps` (no alternator): OCV - I * R, or with jump leads
-- the two batteries in parallel. Never below 0. (The starter isn't a fixed current: it draws less
-- as the voltage sags, see models/starting.lua crankingSupply.)
function Battery:voltageAt(amps)
  local volts, ohms = self:thevenin()
  return max(volts - (amps or 0) * ohms, 0)
end

function Battery:usableCapacityAh()
  return self.capacityAh * min(max(1 + 0.008 * (self.tempC - 25), 0.45), 1.05)
end

-- Most current the battery will take while charging: ~20 A into a half-flat 60 Ah battery at
-- room temperature, a few amps when cold or nearly full (why short winter trips don't recharge).
function Battery:chargeAcceptanceA()
  local tempFactor = min(max(1 + 0.02 * (self.tempC - 25), 0.15), 1)
  return self.capacityAh * 0.5 * tempFactor * max(1 - self.soc, 0) ^ 0.5 + 0.2
end

function Battery:regulatorSetpointV()
  return min(max(14.4 - 0.02 * (self.tempC - 25), 13.8), 14.9) * self.blocks
end

-- Alternator output available at an engine speed: nothing below ~1,100 alternator rpm, about
-- half at a typical idle, nearly all of it above ~2,000 engine rpm.
function Battery:alternatorAvailableA(engineRPM)
  local alternatorRPM = (engineRPM or 0) * self.pulleyRatio
  if alternatorRPM <= 1100 then return 0 end
  return self.alternatorA * (1 - exp(-(alternatorRPM - 1100) / 1300))
end

-- Electrolyte freezing point; a flat battery freezes far sooner than a full one.
function Battery:freezePointC()
  return -8 - 50 * max(self.soc, 0) ^ 1.3
end

-- loadA: everything connected, at the nominal voltage (starter included while cranking);
-- engineRPM drives the alternator; envC is the air temperature around the battery.
-- chargerA: a mains battery charger's output (0 = none); it works like a small alternator.
-- chargeSpeed: game-time speed-up for the charger (the settings' service speed), SOC only.
-- envSpeed: how much faster than normal the battery follows envC (a battery warmer at the service
-- speed, 0.9.0); default 1.
function Battery:update(dt, loadA, engineRPM, envC, chargerA, chargeSpeed, envSpeed)
  loadA = max(loadA or 0, 0)
  local ocv = self:openCircuitVoltage()
  local r = self:internalResistance()
  local alternator = self:alternatorAvailableA(engineRPM)
  local available = alternator + (chargerA or 0)
  local batteryA, voltage, alternatorOut
  local jump = self.jump

  if alternator <= 0 and jump then
    -- jump leads, no alternator: our battery and the donor in parallel share the load (and the
    -- donor charges ours when it's flatter)
    voltage = (ocv / r + jump.voltage / jump.resistance - loadA + (chargerA or 0)) / (1 / r + 1 / jump.resistance)
    batteryA = (ocv - voltage) / r
    alternatorOut = 0
  elseif available > 0 then
    local setpoint = self:regulatorSetpointV()
    local chargeA = max(min((setpoint - ocv) / r, self:chargeAcceptanceA()), 0)
    if available >= loadA + chargeA then
      alternatorOut, batteryA, voltage = loadA + chargeA, -chargeA, setpoint
    elseif available >= loadA then
      local spare = available - loadA
      alternatorOut, batteryA, voltage = available, -spare, ocv + spare * r
    else
      batteryA = loadA - available
      alternatorOut, voltage = available, ocv - batteryA * r
    end
  else
    alternatorOut, batteryA = 0, loadA
    voltage = ocv - batteryA * r
  end

  if dt > 0 then
    -- charging stores ~90 % of the charge that goes in; a charger can run sped up
    local amps = batteryA > 0 and batteryA or batteryA * 0.9 * ((chargerA or 0) > 0 and (chargeSpeed or 1) or 1)
    self.soc = min(max(self.soc - amps * dt / (self:usableCapacityAh() * 3600), 0), 1)
    if envC then
      -- two-hour time constant (soak.lua tauSeconds.battery), faster under a warmer at service speed
      self.tempC = self.tempC + (envC - self.tempC) * (1 - exp(-dt * max(envSpeed or 1, 1) / 7200))
    end
  end

  self.voltage = max(voltage, 0)
  self.currentA = batteryA
  self.alternatorOutA = alternator > 0 and min(alternatorOut, alternator) or 0
  self.chargerOutA = (chargerA or 0) > 0 and max(alternatorOut - self.alternatorOutA, 0) or 0
  self.loadA = loadA
  return self.voltage
end

return M
