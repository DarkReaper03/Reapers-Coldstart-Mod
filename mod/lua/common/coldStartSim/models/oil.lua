-- ColdStart Sim: engine oil viscosity and oil pressure. Pure Lua: no game globals, so the same
-- file runs in the game (vehicle Lua) and in the local tests (tools/luarun.py).
--
-- Viscosity: Walther / ASTM D341,  log10(log10(nu + 0.7)) = A - B * log10(T[K]),
-- fitted per grade from its typical kinematic viscosity at 40 and 100 °C.
--
-- Pressure: positive-displacement pump feeding the bearing clearances,
--   P = k * (rpm / 1000)^0.55 * (nu / nu100)^0.4,
-- smoothly capped by the relief valve. k is calibrated so a hot engine (oil at 100 °C) idles at
-- the "hot idle" pressure. Pressure rises with a lag that grows with viscosity (thick oil takes
-- longer to reach the bearings) and is scaled by the game's oil level and oil-starvation values.
-- Units: °C, cSt, kPa, rpm, seconds.

local M = {}

local exp, max, min = math.exp, math.max, math.min
local log10 = math.log10

-- Typical values; pumpLimitC is the SAE J300 pumping-viscosity temperature for the W rating.
M.grades = {
  ["0W-20"] = {v40 = 46, v100 = 8.5, pumpLimitC = -40},
  ["5W-30"] = {v40 = 62, v100 = 10.5, pumpLimitC = -35},
  ["10W-30"] = {v40 = 72, v100 = 11, pumpLimitC = -30},
  ["10W-40"] = {v40 = 95, v100 = 14.5, pumpLimitC = -30},
  ["15W-40"] = {v40 = 110, v100 = 15, pumpLimitC = -25},
  ["20W-50"] = {v40 = 155, v100 = 18.5, pumpLimitC = -20},
}
M.defaultGrade = "5W-30"

local maxViscosity = 2e5 -- cSt; past this the oil is effectively solid
local minViscosity = 1 -- cSt

local function waltherY(nu)
  return log10(log10(nu + 0.7))
end

-- Returns a function celsius -> kinematic viscosity (cSt) for a grade name or {v40, v100} table.
function M.viscosityCurve(grade)
  local g = type(grade) == "table" and grade or M.grades[grade] or M.grades[M.defaultGrade]
  local x40, x100 = log10(313.15), log10(373.15)
  local y40, y100 = waltherY(g.v40), waltherY(g.v100)
  local b = (y40 - y100) / (x100 - x40)
  local a = y40 + b * x40
  return function(celsius)
    local kelvin = max(celsius + 273.15, 150)
    local nu = 10 ^ (10 ^ (a - b * log10(kelvin))) - 0.7
    if nu ~= nu or nu > maxViscosity then return maxViscosity end -- also catches overflow to inf
    return max(nu, minViscosity)
  end
end

-- Smooth cap: identical to x up to 80 % of cap, then bends over and approaches cap.
local function capWithKnee(x, cap)
  local knee = 0.8 * cap
  if x <= knee then return x end
  local span = cap - knee
  return cap - span * exp(-(x - knee) / span)
end
M.capWithKnee = capWithKnee

local Pump = {}
Pump.__index = Pump

-- params: grade, idleRPM, hotIdleKPa (pressure at idle with 100 °C oil), reliefKPa
function M.new(params)
  params = params or {}
  local self = setmetatable({}, Pump)
  self.grade = M.grades[params.grade] and params.grade or M.defaultGrade
  local g = M.grades[self.grade]
  self.viscosity = M.viscosityCurve(g)
  self.v40, self.v100, self.pumpLimitC = g.v40, g.v100, g.pumpLimitC
  self.reliefKPa = params.reliefKPa or 480
  local idleRPM = max(params.idleRPM or 750, 300)
  self.k = (params.hotIdleKPa or 170) / (idleRPM / 1000) ^ 0.55

  self.pressureKPa = 0 -- current gauge pressure
  self.targetKPa = 0 -- steady-state pressure for the current rpm and temperature
  self.viscosityCSt = self.viscosity(20)
  self.belowPumpLimit = false
  return self
end

-- Steady-state pressure for an oil temperature and engine speed, before level/starvation.
function Pump:steadyKPa(oilC, rpm)
  if not rpm or rpm <= 30 then return 0 end
  local nu = self.viscosity(oilC)
  return capWithKnee(self.k * (rpm / 1000) ^ 0.55 * (nu / self.v100) ^ 0.4, self.reliefKPa)
end

-- oilC: oil temperature; rpm: engine speed; lubrication: game's oilLubricationCoef (0..1, oil
-- starvation); level: 0..1 from the oil level (1 = at or above the minimum safe level).
function Pump:update(dt, oilC, rpm, lubrication, level)
  oilC = oilC or 20
  local nu = self.viscosity(oilC)
  self.viscosityCSt = nu
  self.belowPumpLimit = oilC < self.pumpLimitC

  local target = self:steadyKPa(oilC, rpm) * min(max(lubrication or 1, 0), 1) * min(max(level or 1, 0), 1)
  self.targetKPa = target

  local tau
  if target > self.pressureKPa then
    tau = min(max(0.3 * (nu / self.v40) ^ 0.3, 0.2), 8)
    if self.belowPumpLimit then tau = tau * 3 end
  else
    tau = 0.4
  end
  if dt > 0 then
    self.pressureKPa = self.pressureKPa + (target - self.pressureKPa) * (1 - exp(-dt / tau))
  end
  return self.pressureKPa
end

-- Oil level factor from the game's oil mass and its minimum safe mass: 1 at or above the minimum,
-- falling to 0 at 60 % of it.
function M.levelFactor(oilMass, minSafeMass)
  if not oilMass or not minSafeMass or minSafeMass <= 0 then return 1 end
  return min(max((oilMass / minSafeMass - 0.6) / 0.4, 0), 1)
end

return M
