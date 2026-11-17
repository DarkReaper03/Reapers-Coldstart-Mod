-- ColdStart Sim: cabin air temperature with an automatic heater. Pure Lua.
--
-- One lumped heat capacity for cabin air and trim. Fresh air comes in through the heater core,
-- which heats it toward the coolant temperature (effectiveness 0.7), so there is no real heat
-- until the engine warms up. Heat also leaks through the body, faster at speed. Electric vehicles
-- use a PTC heater instead. The climate control picks a blower level from the gap to the target.
-- Each step is solved exactly (the equation is linear), so it stays stable for any time step.

local M = {}

local exp, max, min = math.exp, math.max, math.min

M.blowerMassFlow = {[0] = 0, 0.03, 0.05, 0.07, 0.09} -- kg/s per blower level, passenger car
local airCp = 1005 -- J/(kg K)
local heaterEffectiveness = 0.7
local occupantW = 100

local Cabin = {}
Cabin.__index = Cabin

-- Blower level an automatic climate control picks for a temperature gap (°C below target).
local function blowerForDemand(demand)
  if demand > 8 then return 4 end
  if demand > 5 then return 3 end
  if demand > 2.5 then return 2 end
  return 1
end

-- params: tempC (start), targetC, size (1 = passenger car; scales heat capacity, leaks and
-- airflow, e.g. ~8 for a bus), ptcW (electric heater power, EVs only)
function M.new(params)
  params = params or {}
  local self = setmetatable({}, Cabin)
  self.size = params.size or 1
  self.heatCapacity = 40000 * self.size -- J/K: cabin air plus the surface layer of the trim
  self.tempC = params.tempC or 20
  self.targetC = params.targetC or 21
  self.ptcW = params.ptcW or 0
  self.blowerLevel = 0
  self.supplyC = self.tempC
  return self
end

-- ambientC: outside air; heaterSourceC: coolant (or oil on air-cooled engines), nil if unknown;
-- speedKmh: vehicle speed; ignitionLevel: 0..3 (the blower runs with the key at ACC or ON).
function Cabin:update(dt, ambientC, heaterSourceC, speedKmh, ignitionLevel)
  local demand = self.targetC - self.tempC
  local heaterHot = heaterSourceC ~= nil and heaterSourceC > self.tempC + 5
  local occupied = (ignitionLevel or 0) >= 1 -- someone in the car
  local blower = 0
  if occupied then
    if demand > 0.5 and (heaterHot or self.ptcW > 0) then
      blower = blowerForDemand(demand) -- the further from target, the harder it blows
    else
      blower = 1 -- cold engine: low fan so it doesn't blow freezing air; or just ventilating
    end
  end
  self.blowerLevel = blower

  local massFlow = M.blowerMassFlow[blower] * self.size
  local supply = ambientC
  if blower > 0 and demand > 0 then
    if heaterSourceC then
      supply = supply + heaterEffectiveness * max(heaterSourceC - ambientC, 0)
    end
    if self.ptcW > 0 and (ignitionLevel or 0) >= 2 then
      supply = supply + self.ptcW / (massFlow * airCp)
    end
  end
  self.supplyC = supply

  -- dT/dt = (a - b * T) / C, solved exactly over the step
  local airflowWPerK = massFlow * airCp
  local leakWPerK = (25 + 1.2 * min(max(speedKmh or 0, 0), 150)) * self.size
  local b = airflowWPerK + leakWPerK
  local a = airflowWPerK * supply + leakWPerK * ambientC + (occupied and occupantW or 0)
  local equilibrium = a / b
  if dt > 0 then
    self.tempC = equilibrium + (self.tempC - equilibrium) * exp(-b * dt / self.heatCapacity)
  end
  return self.tempC
end

return M
