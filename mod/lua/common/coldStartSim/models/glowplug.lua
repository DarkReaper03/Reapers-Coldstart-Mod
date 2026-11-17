-- ColdStart Sim: diesel glow plugs. Pure Lua.
--
-- Key to ON with a cold engine: the plugs preheat for clamp(2 + 0.25 * (10 - blockC), 0, 15)
-- seconds and the "wait to start" light is on meanwhile. They stay on while cranking a cold
-- engine and keep glowing at reduced power after the start (afterglow), which cuts misfires and
-- white smoke. preheatFraction tells the starting logic (Phase 3) how much preheat was done.

local M = {}

local max, min = math.max, math.min

function M.preheatSeconds(blockC)
  return min(max(2 + 0.25 * (10 - blockC), 0), 15)
end

function M.afterglowSeconds(blockC)
  if blockC >= 10 then return 0 end
  return min(max(30 - 6 * blockC, 30), 180)
end

local Glow = {}
Glow.__index = Glow

-- params: plugs (count), ampsPerPlug (at 12 V), nominalV
function M.new(params)
  params = params or {}
  local self = setmetatable({}, Glow)
  self.plugs = params.plugs or 6
  self.ampsPerPlug = (params.ampsPerPlug or 12) * 12 / (params.nominalV or 12)
  self.state = "off" -- off | preheat | ready | crank | afterglow | done
  self.timer = 0
  self.preheatTarget = 0
  self.preheatFraction = 0 -- 0..1 of the preheat this temperature needs
  self.afterglowLeft = 0
  self.currentA = 0
  self.wait = false
  self.lastIgnition = 0
  return self
end

-- ignitionLevel: 0..3; cranking/running: engine state; blockC: engine block temperature.
function Glow:update(dt, ignitionLevel, cranking, running, blockC)
  blockC = blockC or 20
  local full = self.plugs * self.ampsPerPlug

  if ignitionLevel < 2 then
    self.state, self.currentA, self.wait, self.timer = "off", 0, false, 0
    self.preheatFraction = max(self.preheatFraction - dt / 30, 0) -- plugs cool off
  else
    if self.lastIgnition < 2 and not running then
      self.preheatTarget = M.preheatSeconds(blockC)
      self.timer = 0
      self.state = self.preheatTarget > 0 and "preheat" or "ready"
      if self.preheatTarget <= 0 then self.preheatFraction = 1 end
    end

    if running then
      if self.state ~= "afterglow" and self.state ~= "done" then
        self.afterglowLeft = M.afterglowSeconds(blockC)
        self.state = self.afterglowLeft > 0 and "afterglow" or "done"
      end
      if self.state == "afterglow" then
        self.afterglowLeft = self.afterglowLeft - dt
        if self.afterglowLeft <= 0 then self.state = "done" end
      end
      self.currentA = self.state == "afterglow" and full * 0.6 or 0
      self.wait = false
    elseif cranking then
      self.state = "crank"
      self.currentA = blockC < 10 and full or 0
      self.wait = false
      -- plugs keep heating while cranking: skipping the wait means cranking longer, not never starting
      if self.currentA > 0 and self.preheatTarget > 0 then
        self.preheatFraction = min(self.preheatFraction + dt / self.preheatTarget, 1)
      end
    else
      if self.state == "afterglow" or self.state == "done" or self.state == "crank" then
        self.state = "ready" -- stalled or switched off with the key still on
      end
      if self.state == "preheat" then
        self.timer = self.timer + dt
        self.preheatFraction = self.preheatTarget > 0 and min(self.timer / self.preheatTarget, 1) or 1
        if self.timer >= self.preheatTarget then self.state = "ready" end
      end
      self.currentA = self.state == "preheat" and full or 0
      self.wait = self.state == "preheat"
    end
  end

  self.lastIgnition = ignitionLevel
  return self.currentA
end

return M
