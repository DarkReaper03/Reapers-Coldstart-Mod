-- ColdStart Sim: electrical consumers and the starter motor's current draw. Pure Lua.
--
-- Loads are typical draws at 12 V; a 24 V system draws half the current for the same power.
-- The starter follows the same straight torque-speed line as the game's starter
-- (combustionEngine.lua: torque = starterTorque * (1 - AV / starterMaxAV)), so its current is
-- the free-running current plus the locked-rotor current times (1 - rpm / starterMaxRPM).

local M = {}

local max = math.max

M.amps12 = {
  parasitic = 0.03, -- clock, alarm, ECU memory with the key out
  accessory = 4, -- key at ACC: radio, accessories
  ignitionGasoline = 14, -- key ON: ECU, fuel pump, injectors, coils
  ignitionDiesel = 10,
  parkLights = 3,
  lowBeams = 9,
  highBeams = 9, -- on top of the low beams
  fogLights = 9,
  brakeLights = 3,
  indicator = 2, -- while the bulb is lit; blinking averages out
  horn = 5,
  radiatorFan = 18, -- electric radiator fan
  rearDefrost = 15,
}
M.blowerAmps12 = {[0] = 0, 4, 8, 13, 18} -- HVAC blower by level 0..4

local function on(x)
  return x == true or (type(x) == "number" and x > 0.5)
end

-- e: electrics values (ignitionLevel, lights, fog, brakelights, signal_L, signal_R, hazard, horn).
-- extra: {diesel = bool, radiatorFanOn = bool, blowerLevel = 0..4, rearDefrost = bool}.
-- Returns amps at the system's nominal voltage, starter and glow plugs not included.
function M.consumersA(e, extra, nominalV)
  local a = M.amps12
  local ignition = e.ignitionLevel or 0
  local total
  if ignition >= 2 then
    total = extra.diesel and a.ignitionDiesel or a.ignitionGasoline
  elseif ignition == 1 then
    total = a.accessory
  else
    total = a.parasitic
  end

  local lights = e.lights or 0
  if type(lights) ~= "number" then lights = on(lights) and 1 or 0 end
  if lights >= 1 then total = total + a.parkLights + a.lowBeams end
  if lights >= 2 then total = total + a.highBeams end
  if on(e.fog) then total = total + a.fogLights end
  if on(e.brakelights) then total = total + a.brakeLights end
  if on(e.signal_L) or on(e.hazard) then total = total + a.indicator end
  if on(e.signal_R) or on(e.hazard) then total = total + a.indicator end
  if on(e.horn) then total = total + a.horn end

  if ignition >= 1 then
    if extra.radiatorFanOn then total = total + a.radiatorFan end
    total = total + (M.blowerAmps12[extra.blowerLevel or 0] or 0)
    if extra.rearDefrost then total = total + a.rearDefrost end
  end

  return total * 12 / (nominalV or 12)
end

local Starter = {}
Starter.__index = Starter

-- params: lockedA (locked-rotor current at 12 V), freeFraction (free-running share), nominalV
function M.newStarter(params)
  params = params or {}
  local self = setmetatable({}, Starter)
  local scale = 12 / (params.nominalV or 12)
  self.lockedA = (params.lockedA or 500) * scale
  self.freeA = self.lockedA * (params.freeFraction or 0.12)
  return self
end

-- engaged: starter in mesh; rpm: engine speed; starterMaxRPM: the game's starterMaxAV in rpm.
-- Stock starter (no cold-start effects): current follows the slip on the game's torque line.
function Starter:currentA(engaged, rpm, starterMaxRPM)
  if not engaged then return 0 end
  local slip = 1
  if starterMaxRPM and starterMaxRPM > 0 then
    slip = max(1 - (rpm or 0) / starterMaxRPM, 0)
  end
  return self.freeA + self.lockedA * slip
end

-- Cold-start starter: current from the share of stall torque it delivers (models/starting.lua).
function Starter:currentForTorqueShare(engaged, torqueShare)
  if not engaged then return 0 end
  return self.freeA + (self.lockedA - self.freeA) * max(torqueShare or 0, 0)
end

return M
