-- ColdStart Sim: runs when the mod is activated (lua/ge/extensions/core/modmanager.lua).
-- Loads the game-engine side of the mod. The vehicle side loads by itself from
-- lua/vehicle/extensions/auto/coldStartSim.lua for every vehicle.

setExtensionUnloadMode("coldStartSim_main", "manual")
extensions.load("coldStartSim_main")
