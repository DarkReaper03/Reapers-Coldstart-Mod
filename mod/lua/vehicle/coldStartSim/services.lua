-- ColdStart Sim: things you plug into a parked car (Phase 6).
--   blockHeater  an engine block heater on mains power: warms the block, coolant and (slower) the
--                oil toward outside + 30 °C (750 W against ~25 W/K of heat loss, models/soak.lua)
--   charger      a mains battery charger: 10 A into the battery while the engine is off
--   jumpLeads    jump leads to a healthy donor battery (models/battery.lua connectJumpLeads)
-- Real block heaters and chargers take hours; the settings' service speed (default x10) speeds
-- them up. Drive off with something still connected and it comes loose, with a warning.
-- Toggled from keybinds (lua/ge/extensions/core/input/actions/coldStartSim.json), the settings
-- screen or the console: coldStartSim.action("blockHeater").

local M = {}

local adapter = require("coldStartSim/adapter")
local soak = require("coldStartSim/models/soak")

local exp, max = math.exp, math.max

M.names = {"blockHeater", "charger", "jumpLeads"}
M.labels = {blockHeater = "block heater", charger = "battery charger", jumpLeads = "jump leads"}

M.config = {serviceSpeed = 10, heaterWatts = 750, chargerA = 10}
M.state = {blockHeater = false, charger = false, jumpLeads = false, droveOff = nil, droveOffSeconds = 0}

local driveOffKmh = 3
local droveOffShowSeconds = 6
-- how fast each temperature follows the heater (engine-off time constants, before the speed-up)
local heaterTau = {
  engineBlockTemperature = soak.tauSeconds.block, cylinderWallTemperature = soak.tauSeconds.block,
  coolantTemperature = soak.tauSeconds.coolant, oilTemperature = soak.tauSeconds.oil * 1.5,
}

local handle = nil
local notifyFn = nil

local function notify(text)
  if notifyFn then notifyFn(text) end
end

-- engineHandle: adapter handle of the primary combustion engine (nil: no engine to heat)
function M.init(engineHandle, notifier)
  handle = engineHandle and engineHandle.isCombustion and engineHandle or nil
  notifyFn = notifier
  local state = M.state
  state.blockHeater, state.charger, state.jumpLeads = false, false, false
  state.droveOff, state.droveOffSeconds = nil, 0
end

-- cfg: {serviceSpeed, heaterWatts, chargerA}; missing keys keep their value
function M.configure(cfg)
  if type(cfg) ~= "table" then return end
  for key, value in pairs(cfg) do
    if M.config[key] ~= nil and type(value) == "number" and value == value then M.config[key] = value end
  end
end

-- Plugs in (on = true), unplugs (false) or toggles (nil). Returns the new state, or nil for an
-- unknown name.
function M.set(name, on)
  if M.state[name] == nil or name == "droveOff" or name == "droveOffSeconds" then return nil end
  if on == nil then on = not M.state[name] end
  on = on == true
  if M.state[name] == on then return on end
  M.state[name] = on
  local label = M.labels[name] or name
  if on and name == "blockHeater" and not (handle and handle.thermalsEnabled) then
    notify("Block heater plugged in, but this engine has no temperatures to warm.")
  else
    notify((on and "Connected: " or "Disconnected: ") .. label)
  end
  return on
end

function M.any()
  local state = M.state
  return state.blockHeater or state.charger or state.jumpLeads
end

-- What the battery sees this update: {chargerA, chargeSpeed, jump}.
local electrical = {chargerA = 0, chargeSpeed = 1, jump = false}
function M.electrical(running)
  electrical.chargerA = (M.state.charger and not running) and M.config.chargerA or 0
  electrical.chargeSpeed = M.config.serviceSpeed
  electrical.jump = M.state.jumpLeads
  return electrical
end

local function warmEngine(dt, ambientC)
  if not (handle and handle.thermalsEnabled and ambientC) then return end
  local temps = adapter.getEngineTemperatures(handle)
  if not temps then return end
  local target = ambientC + soak.blockHeaterRiseC(M.config.heaterWatts)
  local speed = max(M.config.serviceSpeed, 1)
  local changed = false
  for key, tau in pairs(heaterTau) do
    local t = temps[key]
    if t and t < target then
      temps[key] = t + (target - t) * (1 - exp(-dt * speed / tau))
      changed = true
    end
  end
  if changed then adapter.setEngineTemperatureTable(handle, temps) end
end

-- speedKmh: road speed; running: engine running; ambientC: outside air
function M.update(dt, speedKmh, ambientC)
  local state = M.state
  state.droveOffSeconds = max(state.droveOffSeconds - dt, 0)
  if state.droveOffSeconds <= 0 then state.droveOff = nil end

  if (speedKmh or 0) > driveOffKmh and M.any() then
    local what = {}
    for _, name in ipairs(M.names) do
      if state[name] then
        what[#what + 1] = M.labels[name]
        state[name] = false
      end
    end
    state.droveOff = table.concat(what, " and ")
    state.droveOffSeconds = droveOffShowSeconds
    notify("You drove off with the " .. state.droveOff .. " still connected! It came loose.")
  end

  if state.blockHeater then warmEngine(dt, ambientC) end
end

return M
