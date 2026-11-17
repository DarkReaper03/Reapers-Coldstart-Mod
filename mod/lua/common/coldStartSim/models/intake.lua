-- ColdStart Sim: intake air temperature (IAT). Pure Lua.
--
-- IAT = outside air + engine-bay heat soak + compression heating from boost.
--   heat soak  = 0.15 * (coolant - outside) * e^(-speed / 20 km/h): hot bay at idle, ~0 on the road
--   boost      compressor outlet T2 = T1 * (1 + (PR^0.2857 - 1) / 0.72), then an intercooler
--              (effectiveness 0.7) brings it back toward outside air
-- The sensor reading follows with a 5 s lag.

local M = {}

local exp, max = math.exp, math.max

local Intake = {}
Intake.__index = Intake

-- params: intercooled (bool), tempC (start)
function M.new(params)
  params = params or {}
  local self = setmetatable({}, Intake)
  self.intercooled = params.intercooled ~= false
  self.tempC = params.tempC
  self.targetC = params.tempC
  return self
end

-- Steady-state intake temperature; boostKPa is gauge pressure (0 without boost).
function Intake:steadyC(ambientC, coolantC, speedKmh, boostKPa, baroKPa)
  local soak = 0.15 * max((coolantC or ambientC) - ambientC, 0) * exp(-max(speedKmh or 0, 0) / 20)
  local target = ambientC + soak
  if boostKPa and boostKPa > 1 then
    local baro = baroKPa or 101.325
    local ratio = (baro + boostKPa) / baro
    local inletK = target + 273.15
    local outletK = inletK * (1 + (ratio ^ 0.2857 - 1) / 0.72)
    local effectiveness = self.intercooled and 0.7 or 0
    target = outletK - effectiveness * (outletK - (ambientC + 273.15)) - 273.15
  end
  return target
end

function Intake:update(dt, ambientC, coolantC, speedKmh, boostKPa, baroKPa)
  local target = self:steadyC(ambientC, coolantC, speedKmh, boostKPa, baroKPa)
  self.targetC = target
  if not self.tempC then self.tempC = target end
  if dt > 0 then
    self.tempC = self.tempC + (target - self.tempC) * (1 - exp(-dt / 5))
  end
  return self.tempC
end

return M
