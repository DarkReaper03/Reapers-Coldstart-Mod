-- ColdStart Sim: warnings (PLAN.md section 7). Plain Lua with no game globals, shared by the
-- vehicle side and the local tests.
--
-- Each warning is a check on the vehicle's live values that returns a level when it should be on:
--   0 info (blue/green light, no toast), 1 caution (amber), 2 warning (amber + toast + chime),
--   3 critical (red, flashing + toast + chime).
-- The evaluator adds what makes dash lights trustworthy:
--   * hysteresis: every check gets its own on/off state and clears at a gentler threshold
--   * debounce: a condition has to hold for `onDelay` (1 s default) before the light comes on, and
--     be gone for `offDelay` (1 s) before it goes off; a rise in level (warning -> critical) is
--     immediate
--   * start-up grace: oil pressure is ignored for 3-10 s after the engine starts (thick oil longer)
--   * no change while cranking (voltage and pressure collapse by design), except the lights that
--     are about cranking (starter hot, glow plugs, flat battery)
--   * dark dash: with the key off nothing is evaluated and every light goes out
-- Lights can be acknowledged (clicking them in the HUD, or a keybind): they stay lit but dimmed and
-- don't toast or chime again until they have gone out and come back.
--
-- Inputs (x, all optional; °C, kPa, V, A, rpm, s):
--   ignition (0-3), running, cranking, rpm, runSeconds, oilKPa, oilReliefKPa, oilC, oilLevel
--   (oil mass / the game's minimum safe mass), oilViscosity, coolantC, thermostatC, batteryV, nominalV,
--   batterySoc, batteryA (+ discharging), batteryTempC, crankMinV, sinceCrank (s since the last crank ended),
--   glowWait, starterCutout, batteryFlat, batteryFrozen, ambientC, intakeC

local M = {}

local max, min = math.max, math.min

M.levels = {info = 0, caution = 1, warning = 2, critical = 3}

local function clamp(x, lo, hi)
  return min(max(x, lo), hi)
end

local function scale(x)
  return (x.nominalV or 12) / 12
end

-- Grace after a start before oil pressure counts: 3 s, up to 10 s for thick cold oil.
function M.oilGraceSeconds(viscosityCSt)
  return clamp(3 + 7 * ((viscosityCSt or 0) - 100) / 2000, 3, 10)
end

-- Lowest healthy cranking voltage, per 12 V: the battery load test's 9.6 V at 21 °C, less in the
-- cold (BCI's table: 8.5 V at -18 °C), extended at the same 0.028 V/°C to 7.6 V at -50 °C. A flat
-- 9.6 V lit "weak battery" for every healthy battery in deep cold.
function M.crankLimitV(batteryTempC)
  return 9.6 - 0.028 * clamp(21 - (batteryTempC or 21), 0, 80)
end

-- Lowest acceptable running oil pressure: 50 kPa (7 psi) at idle, then the "10 psi per 1,000 rpm"
-- rule (69 kPa per 1,000 rpm) above 1,500 rpm.
function M.oilPressureLimitKPa(rpm)
  rpm = rpm or 0
  if rpm <= 1500 then return 50 end
  return max(50, 69 * rpm / 1000)
end

-- Definitions. check(x, active) returns a level or nil; `active` lets a check clear at a different
-- threshold than it triggers at (hysteresis). title: the light's name; text(x, level): the toast.
M.definitions = {
  {
    id = "OIL_PRESS_LOW", icon = "oil", title = "Oil pressure",
    check = function(x, active)
      if not x.running or not x.oilKPa then return nil end
      if (x.runSeconds or 0) < M.oilGraceSeconds(x.oilViscosity) then return nil end
      local limit = M.oilPressureLimitKPa(x.rpm)
      if x.oilKPa < (active and limit * 1.3 or limit) then return 3 end
    end,
    text = function() return "Low oil pressure! Stop the engine." end,
  },
  {
    id = "OIL_PRESS_COLD_REVS", icon = "oil", title = "Cold oil",
    check = function(x, active)
      if not x.running or not (x.oilC and x.oilKPa and x.oilReliefKPa) then return nil end
      local cold = x.oilC < (active and 45 or 40)
      local revs = (x.rpm or 0) > (active and 2700 or 3000)
      local atRelief = x.oilKPa >= x.oilReliefKPa * (active and 0.9 or 0.98)
      if cold and revs and atRelief then return 1 end
    end,
    text = function() return "Cold oil: keep the revs low until it warms up" end,
  },
  {
    id = "OIL_TEMP_HIGH", icon = "oilTemp", title = "Oil temperature",
    check = function(x, active)
      if not x.oilC then return nil end
      if x.oilC > 145 or (active == 3 and x.oilC > 140) then return 3 end
      if x.oilC > (active and 125 or 130) then return 2 end
    end,
    text = function(x, level)
      return level >= 3 and "Oil overheating! Stop the engine." or string.format("Oil temperature high (%.0f °C)", x.oilC or 0)
    end,
  },
  {
    id = "OIL_LEVEL_LOW", icon = "oilLevel", title = "Oil level",
    check = function(x, active)
      if not x.oilLevel then return nil end
      if x.oilLevel < (active and 1.05 or 1) then return 2 end
    end,
    text = function() return "Oil level low" end,
  },
  {
    id = "COOLANT_HIGH", icon = "coolant", title = "Engine temperature",
    check = function(x, active)
      if not x.coolantC then return nil end
      local thermostat = x.thermostatC or 90
      if x.coolantC > thermostat + 30 or (active == 3 and x.coolantC > thermostat + 25) then return 3 end
      if x.coolantC > thermostat + (active and 15 or 20) then return 2 end
    end,
    text = function(x, level)
      return level >= 3 and "Engine overheating! Stop the engine." or "Engine temperature high"
    end,
  },
  {
    id = "ENGINE_COLD", icon = "cold", title = "Engine cold",
    check = function(x, active)
      local t = x.coolantC or x.oilC
      if not t then return nil end
      if t < (active and 42 or 40) then return 0 end
    end,
    text = function() return "Engine cold: take it easy until it warms up" end,
  },
  {
    id = "VOLT_CRITICAL", icon = "battery", title = "Battery voltage",
    check = function(x, active)
      if not x.batteryV then return nil end
      local s = scale(x)
      local limit = (x.running and 11.5 or 11.0) * s
      if x.batteryV < (active and limit + 0.3 * s or limit) then return 3 end
    end,
    text = function(x) return string.format("Battery voltage critical (%.1f V)", x.batteryV or 0) end,
  },
  {
    id = "VOLT_LOW", icon = "battery", title = "Battery voltage", onDelay = 10,
    check = function(x, active)
      if not x.batteryV then return nil end
      local s = scale(x)
      local limit = (x.running and 12.6 or 12.0) * s
      if x.batteryV < (active and limit + 0.2 * s or limit) then return 2 end
    end,
    text = function(x) return string.format("Battery voltage low (%.1f V)", x.batteryV or 0) end,
  },
  {
    id = "VOLT_HIGH", icon = "battery", title = "Charging voltage",
    check = function(x, active)
      if not x.batteryV then return nil end
      local s = scale(x)
      if x.batteryV > (active and 15.0 or 15.2) * s then return 2 end
    end,
    text = function(x) return string.format("Charging voltage too high (%.1f V)", x.batteryV or 0) end,
  },
  {
    id = "NOT_CHARGING", icon = "battery", title = "Not charging", onDelay = 15,
    check = function(x, active)
      if not x.running or not x.batteryA then return nil end
      if x.batteryA > (active and 2 or 5) then return 2 end
    end,
    text = function() return "Battery not charging: the alternator can't keep up" end,
  },
  {
    id = "CRANK_VOLT_LOW", icon = "battery", title = "Weak battery", allowWhileCranking = false,
    check = function(x)
      if not (x.crankMinV and x.sinceCrank) or x.sinceCrank > 30 then return nil end
      if x.crankMinV < M.crankLimitV(x.batteryTempC) * scale(x) then return 1 end
    end,
    text = function(x) return string.format("Weak battery: it fell to %.1f V while cranking", x.crankMinV or 0) end,
  },
  {
    id = "BATT_SOC_LOW", icon = "battery", title = "Battery charge",
    check = function(x, active)
      if not x.batterySoc then return nil end
      local soc = x.batterySoc
      if soc < (active and 0.3 or 0.25) then return 2 end
      if soc < (active and 0.55 or 0.5) then return 1 end
    end,
    text = function(x) return string.format("Battery low (%d %% charged)", math.floor((x.batterySoc or 0) * 100 + 0.5)) end,
  },
  {
    -- no toast: turning the key says it ("Click... the battery is too flat", coldstart.lua)
    id = "BATT_FLAT", icon = "battery", title = "Battery flat", onDelay = 0, allowWhileCranking = true, toast = false,
    check = function(x)
      if x.batteryFlat and not x.running then return 2 end
    end,
    text = function() return "Battery too flat to start the engine: charge it or jump-start it" end,
  },
  {
    id = "BATT_FROZEN", icon = "battery", title = "Battery frozen", onDelay = 0, allowWhileCranking = true, toast = false,
    check = function(x)
      if x.batteryFrozen then return 3 end
    end,
    text = function() return "Battery frozen! Warm it up before trying to start." end,
  },
  {
    id = "GLOW_WAIT", icon = "glow", title = "Glow plugs", onDelay = 0, offDelay = 0, allowWhileCranking = true,
    check = function(x)
      if x.glowWait then return 0 end
    end,
    text = function() return "Wait to start: glow plugs heating" end,
  },
  {
    id = "STARTER_HOT", icon = "starter", title = "Starter hot", onDelay = 0, allowWhileCranking = true,
    check = function(x)
      if x.starterCutout then return 1 end
    end,
    text = function() return "Starter overheated: let it cool" end,
  },
  {
    -- block heater, charger or jump leads connected (services.lua)
    id = "PLUGGED_IN", icon = "plug", title = "Plugged in", onDelay = 0, offDelay = 0, allowWhileCranking = true,
    check = function(x)
      if x.pluggedIn then return 0 end
    end,
    text = function() return "Something is plugged into the car" end,
  },
  {
    -- driving off with something still connected: it came loose (services.lua already says so)
    id = "BLOCK_HEATER_CORD", icon = "plug", title = "Cord", onDelay = 0, allowWhileCranking = true, toast = false,
    check = function(x)
      if x.droveOff then return 2 end
    end,
    text = function(x) return "You drove off with the " .. tostring(x.droveOff) .. " still connected!" end,
  },
  {
    id = "ICE_RISK", icon = "ice", title = "Ice risk",
    check = function(x, active)
      if not x.ambientC then return nil end
      if x.ambientC <= (active and 4 or 3) then return 0 end
    end,
    text = function() return "Freezing outside: watch for ice" end,
  },
  {
    id = "IAT_HIGH", icon = "intake", title = "Intake air",
    check = function(x, active)
      if not x.intakeC then return nil end
      if x.intakeC > (active and 55 or 60) then return 1 end
    end,
    text = function(x) return string.format("Intake air hot (%.0f °C): less power", x.intakeC or 0) end,
  },
}

M.byId = {}
for index, def in ipairs(M.definitions) do
  def.order = index
  M.byId[def.id] = def
end

local Evaluator = {}
Evaluator.__index = Evaluator

-- options: {disabled = {[id] = true}} (warnings switched off in the settings)
function M.new(options)
  local self = setmetatable({}, Evaluator)
  self.states = {}
  for _, def in ipairs(M.definitions) do
    self.states[def.id] = {active = false, level = nil, onTimer = 0, offTimer = 0, acked = false}
  end
  self.events = {}
  self.list = {} -- reused: active warnings for the HUD
  self:configure(options)
  return self
end

function Evaluator:configure(options)
  options = type(options) == "table" and options or {}
  self.disabled = type(options.disabled) == "table" and options.disabled or {}
end

local function switchOff(state)
  state.active, state.level, state.onTimer, state.offTimer, state.acked = false, nil, 0, 0, false
end

function Evaluator:update(dt, x)
  local dark = (x.ignition or 0) < 1
  for _, def in ipairs(M.definitions) do
    local state = self.states[def.id]
    if dark or self.disabled[def.id] then
      switchOff(state)
    elseif not (x.cranking and def.allowWhileCranking ~= true) then
      local want = def.check(x, state.active and state.level or false)
      if want ~= nil then
        state.offTimer = 0
        if state.active then
          if want > state.level then -- escalation: immediate, and it alerts again
            state.level, state.acked = want, false
            table.insert(self.events, {id = def.id, level = want})
          else
            state.level = want
          end
        else
          state.onTimer = state.onTimer + dt
          if state.onTimer >= (def.onDelay or 1) then
            state.active, state.level, state.onTimer, state.acked = true, want, 0, false
            table.insert(self.events, {id = def.id, level = want})
          end
        end
      else
        state.onTimer = 0
        if state.active then
          state.offTimer = state.offTimer + dt
          if state.offTimer >= (def.offDelay or 1) then switchOff(state) end
        end
      end
    end
  end
end

-- Newly raised (or escalated) warnings since the last call: {{id, level}, ...}, oldest first.
function Evaluator:popEvents()
  local events = self.events
  self.events = {}
  return events
end

-- Acknowledge one warning, or every active one when id is nil.
function Evaluator:ack(id)
  for wid, state in pairs(self.states) do
    if state.active and (id == nil or wid == id) then state.acked = true end
  end
end

function Evaluator:isActive(id)
  local state = self.states[id]
  return state ~= nil and state.active
end

-- Active warnings for the HUD, most severe first: {{id, level, acked (0/1)}, ...}.
-- The table is reused between calls.
function Evaluator:activeList()
  local list = self.list
  for i = #list, 1, -1 do list[i] = nil end
  for _, def in ipairs(M.definitions) do
    local state = self.states[def.id]
    if state.active then
      list[#list + 1] = {def.id, state.level, state.acked and 1 or 0}
    end
  end
  table.sort(list, function(a, b)
    if a[2] ~= b[2] then return a[2] > b[2] end
    return M.byId[a[1]].order < M.byId[b[1]].order
  end)
  return list
end

-- Does this warning toast? (Some only light up: another message already says it.)
function M.toasts(id)
  local def = M.byId[id]
  return def ~= nil and def.toast ~= false
end

-- Toast text for a warning at a level (x: the same inputs as update).
function M.text(id, x, level)
  local def = M.byId[id]
  if not def then return tostring(id) end
  return def.text(x or {}, level or 0)
end

return M
