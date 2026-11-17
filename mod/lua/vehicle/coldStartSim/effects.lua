-- ColdStart Sim: the only way the mod changes engine fields (PLAN.md section 6).
--
-- Last-write ownership: for each field we remember the stock ("base") value and the value we last
-- wrote. If the field still holds our value, the base is unchanged; if anything else changed it
-- (the game's reset(), damage, another mod), the new value becomes the base and our change is
-- re-applied on top. So fields the game never resets (starterTorque, idleAV) don't compound, and
-- fields it does reset (dynamicFriction, maxTorqueLimit) pick up the fresh stock value.
-- release()/restoreAll() put the base values back, e.g. when the effects are switched off.

-- Never writes a value that isn't a finite number: a NaN or infinity in an engine field spreads
-- through the drivetrain into the physics (a vehicle instability). Such a value is refused, the
-- field goes back to stock, and report() lists it.

local M = {}

local Effects = {}
Effects.__index = Effects

local function finite(x)
  return type(x) == "number" and x == x and x ~= math.huge and x ~= -math.huge
end
M.finite = finite

function M.new(device)
  return setmetatable({device = device, fields = {}, refused = {}}, Effects)
end

-- the bookkeeping entry for a numeric field, with its base brought up to date
local function track(self, name)
  local current = self.device[name]
  if not finite(current) then return nil end
  local field = self.fields[name]
  if not field then
    field = {base = current, written = nil}
    self.fields[name] = field
  elseif field.written == nil or current ~= field.written then
    field.base = current -- not ours (any more): adopt it as the stock value
  end
  return field
end

-- stock value of a field (what it would be without the mod), or nil if it isn't a number
function Effects:baseOf(name)
  local field = track(self, name)
  return field and field.base or nil
end

function Effects:set(name, value)
  local field = track(self, name)
  if not field then return false end
  if not finite(value) then
    self.refused[name] = tostring(value)
    self:release(name)
    return false
  end
  self.device[name] = value
  field.written = value
  return true
end

function Effects:scale(name, factor)
  local field = track(self, name)
  if not field then return false end
  return self:set(name, field.base * factor)
end

function Effects:offset(name, delta)
  local field = track(self, name)
  if not field then return false end
  return self:set(name, field.base + delta)
end

-- give a field back to the game (only if it still holds our value)
function Effects:release(name)
  local field = self.fields[name]
  if not field then return end
  if field.written ~= nil and self.device[name] == field.written then
    self.device[name] = field.base
  end
  field.written = nil
end

function Effects:restoreAll()
  for name in pairs(self.fields) do
    self:release(name)
  end
end

-- every field we track: stock value, what we wrote (nil: released), what the engine holds now;
-- plus any value that was refused (not a finite number)
function Effects:report()
  local fields = {}
  for name, field in pairs(self.fields) do
    local current = self.device[name]
    fields[name] = {base = field.base, written = field.written,
      current = finite(current) and current or tostring(current)}
  end
  return {fields = fields, refused = next(self.refused) and self.refused or nil}
end

return M
