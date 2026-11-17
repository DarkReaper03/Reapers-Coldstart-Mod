-- ColdStart Sim: cold soak (engine-off cooling) and block heater. Pure Lua.
-- Used from Phase 3 on, to cold-soak a car at spawn and to cool it between sessions.
--
-- Newton cooling: T(t) = T_amb + (T0 - T_amb) * e^(-t / tau).
-- A block heater of P watts settles at T_amb + P / G, with G (W/K) the engine's heat loss.

local M = {}

local exp, max = math.exp, math.max

-- Engine-off time constants in still air, seconds.
M.tauSeconds = {
  oil = 1.2 * 3600,
  coolant = 1.5 * 3600,
  block = 1.5 * 3600, -- iron block
  blockAluminium = 1.2 * 3600,
  exhaust = 0.3 * 3600,
  battery = 2 * 3600,
}

function M.cool(tempC, ambientC, seconds, tauSeconds)
  if seconds <= 0 then return tempC end
  return ambientC + (tempC - ambientC) * exp(-seconds / max(tauSeconds, 1))
end

-- Temperature rise a block heater settles at (default heat loss 25 W/K: 750 W gives +30 °C).
function M.blockHeaterRiseC(watts, lossWPerK)
  return (watts or 0) / (lossWPerK or 25)
end

-- Same as cool(), but with a block heater pulling toward ambient + rise.
function M.coolWithHeater(tempC, ambientC, seconds, tauSeconds, heaterWatts, lossWPerK)
  return M.cool(tempC, ambientC + M.blockHeaterRiseC(heaterWatts, lossWPerK), seconds, tauSeconds)
end

return M
