-- ColdStart Sim: builds the packet streamed to the HUD apps (stream "coldStartSim").
--
-- Internal units: °C, kPa, V, A, rpm, m/s. The UI converts to the player's units.
-- The packet table is reused between frames: guihooks.queueStream keeps a reference and
-- serialises it later in the same graphics step, and we only rebuild it right before queueing.

local M = {}

M.version = 3

local packet = {}
local glow = {}

-- profile: profile.lua; engine/e: adapter.readEngine/readElectrics output (engine may be nil);
-- s: sim.state; ambientC, baroKPa: environment; start: coldstart.state (may be nil).
function M.build(profile, engine, e, s, ambientC, baroKPa, modVersion, start)
  packet.v = M.version
  packet.mod = modVersion
  packet.phase = 3
  packet.name = profile.name
  packet.model = profile.model
  packet.config = profile.configName
  packet.kind = profile.kind
  packet.fuel = profile.fuel
  packet.engines = profile.engineCount
  packet.turbo = profile.turbo
  packet.sysV = s.nominalV

  -- environment and driving state
  packet.oat = ambientC
  packet.baro = baroKPa
  packet.ign = e.ignitionLevel
  packet.speed = e.airspeed
  packet.boost = e.boostKPa
  packet.rpm = engine and engine.rpm or nil
  packet.cranking = engine and engine.cranking or nil
  local running = e.engineRunning
  if running == nil and engine then
    local idle = (profile.engines[profile.primaryIndex] or {}).idleRPM or 600
    running = engine.ignition and not engine.stalled and (engine.rpm or 0) > idle * 0.5
  end
  packet.running = running

  -- engine temperatures (game thermals, dashboard electrics, or the fallback estimate)
  packet.thermals = s.thermals or "none"
  packet.coolant = s.coolantC
  packet.oil = s.oilC
  packet.block = s.blockC
  packet.egt = s.exhaustC
  packet.thermostat = engine and engine.thermostat or nil
  packet.fan = engine and engine.fanActive or nil
  packet.lube = engine and engine.lubrication or nil
  if engine and engine.oilMass and engine.oilMinSafeMass and engine.oilMinSafeMass > 0 then
    packet.oilLevel = engine.oilMass / engine.oilMinSafeMass
  else
    packet.oilLevel = nil
  end

  -- oil pressure
  packet.oilP = s.oilKPa
  packet.oilPRelief = s.oilReliefKPa
  packet.visc = s.oilViscosity
  packet.oilGrade = s.oilGrade
  packet.oilTooThick = s.oilBelowPumpLimit

  -- electrical
  packet.battV = s.batteryV
  packet.battSoc = s.batterySoc
  packet.battA = s.batteryA
  packet.battT = s.batteryTempC
  packet.battFreeze = s.batteryFreezeC
  packet.altA = s.alternatorA
  packet.chargerA = s.chargerA ~= nil and s.chargerA > 0 and s.chargerA or nil
  packet.loadA = s.loadA
  packet.crankMinV = s.crankMinV
  packet.crankPeakA = s.crankPeakA

  -- air
  packet.cabin = s.cabinC
  packet.blower = s.blower
  packet.iat = s.intakeC

  -- cold-start logic (Phase 3)
  packet.startHold = start and start.holdReason or nil -- why it isn't firing yet
  packet.crankTargetRPM = start and start.targetRPM or nil
  packet.fastIdleRPM = start and start.fastIdleRPM or nil
  packet.starterHot = start and start.starterCutout or nil -- thermal cut-out open (0.3.2)
  packet.coldDrag = start and start.dragMultiplier ~= 1 and start.dragMultiplier or nil
  packet.misfireRate = start and start.misfireRate > 0 and start.misfireRate or nil
  packet.batteryFlat = start and start.batteryFlat or nil -- too flat to turn the starter (0.3.3)
  packet.starterClick = start and start.clickSeconds > 0 or nil -- it just clicked instead of cranking

  -- diesel glow plugs
  if s.glowState then
    glow.state, glow.wait, glow.pct = s.glowState, s.glowWait, s.glowPct
    packet.glow = glow
  else
    packet.glow = nil
  end

  return packet
end

return M
