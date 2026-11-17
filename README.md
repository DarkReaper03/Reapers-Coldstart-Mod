# ColdStart Sim

[![Latest release](https://img.shields.io/github/v/release/DarkReaper03/Reapers-Coldstart-Mod?include_prereleases&label=release)](https://github.com/DarkReaper03/Reapers-Coldstart-Mod/releases)
![BeamNG.drive 0.40](https://img.shields.io/badge/BeamNG.drive-0.40-orange)

**Cold weather for BeamNG.drive.** ColdStart Sim simulates your car's battery and oil pressure, and the engine, oil, cabin, intake and outside temperatures. It makes a cold engine behave like one: slow cranking, failed starts, fast idle and warning lights, with a HUD you can set up the way you like. It works on the base vehicles and on modded cars that use the standard powertrain, without changing any vehicle files.

<!-- Screenshots: when editing on GitHub, drag dist/screenshots/hud-cold-start.jpg and settings-screen.jpg here,
     or commit them under docs/ and use ![HUD](docs/hud-cold-start.jpg) -->

## Features

- **Cold cranking:** thick oil and a cold battery slow the starter. A start can fail because the engine turns too slowly to fire, a diesel's glow plugs aren't ready, or the battery browns out. A battery that's too flat only clicks.
- **Cold running:** fast idle until the engine warms up, a cold engine that drags and stumbles for its first half minute, and a starter that overheats if you crank it too long.
- **Warning lights and messages:** 11 dashboard lamps cover 20 warnings: oil pressure, revving on cold oil, oil and coolant temperature, oil level, battery voltage, charge and charging, weak battery, glow plugs, starter overheating, ice risk and hot intake air. Click a lamp to acknowledge it.
- **Plug things in:** engine block heater, battery charger and jump leads, from the pause menu or keybinds. Drive off with them still connected and they come loose.
- **Climate presets:** Mild winter (−5 °C), Cold (−15 °C), Arctic (−30 °C), Siberian (−45 °C) and Desert heat (+38 °C) on any map, or keep the map's own temperature.
- **Cars remember** how warm and charged you left them, and cool down for the time that has passed.
- **Realism presets** from Display only to Hardcore, and you can switch each effect on or off.
- **Customizable HUD:** two apps (gauges and warning lights), 18 gauges to show, hide and reorder, six themes, size, opacity, compact mode, auto-hide and your own units (°C/°F, kPa/bar/psi).

## Install

1. Download **`coldstartsim.zip`** from the [latest release](https://github.com/DarkReaper03/Reapers-Coldstart-Mod/releases), not the "Source code" archives.
2. Put it in `%LOCALAPPDATA%\BeamNG\BeamNG.drive\current\mods\`. Don't unzip it.
3. Start BeamNG.drive and check that the mod is enabled in the mod manager.

To update, replace the old `coldstartsim.zip`. Your settings are kept.

## Getting started

- **Settings and your car's plug-ins:** pause menu → **Mods → ColdStart Sim** (Car, Simulation, Warnings, Gauges, Lights, About).
- **HUD apps:** pause menu → System → HUD Apps → edit your layout → Add app → **ColdStart Sim - Gauges** and **ColdStart Sim - Warning Lights**.
- **Keybinds** (unbound by default): Options → Controls → Vehicle → "ColdStart Sim: block heater / battery charger / jump leads / acknowledge warnings".
- **Try it:** pick a climate preset, or set the temperature under Environment in the pause menu. Switch the engine off and give it a cold start. For a challenge, try −20 °C with a 30 % battery.

## Realism presets

| Preset | What it does |
|---|---|
| **Display only** | Gauges, warnings and models only. The engine behaves exactly as stock. |
| **Casual** | Slow cold cranking and fast idle for the feel, but it always starts: no failed starts, no clicking battery, no cold drag, misfires or starter overheating. |
| **Realistic** (default) | Everything on: failed starts, the dead-battery click, cold drag, cold misfires and starter overheating. |
| **Hardcore** | Harder to fire, more drag and misfires, a starter that overheats sooner, and batteries that can freeze in deep cold. |

## Surviving deep cold

With 5W-30 oil and a full battery, a cold-soaked gasoline car still starts down to about −35 °C. Below about −40 °C it turns over, but too slowly to fire. At −50 °C the engine needs warming to about −30 °C first, because the battery is weaker there too:

- **Block heater:** plug it in from the Car tab or the keybind. At −50 °C it needs 10–15 minutes at the default service speed. You can speed it up in Settings → Simulation → Service speed.
- **Battery charger:** for a battery that has run down. A battery only clicks when it's actually low: below about 30 % charge at −20 °C, or about 50 % at −50 °C.
- **Jump leads:** a donor battery for a flat one.
- **Casual:** if you just want to drive.

## How it works

- **Battery:** a lead-acid model sized from the engine (cold cranking amps, capacity), with its voltage set by the state of charge. Its internal resistance rises in the cold and as it runs flat. An alternator with a temperature-compensated regulator charges it, and real loads draw from it (ignition, lights, blower, glow plugs, the starter).
- **Oil:** viscosity by grade (0W-20 to 20W-50) and temperature. Pressure comes from viscosity, rpm and the relief valve, with a start-up grace before the warning.
- **Starting:** the starter slows with oil drag and battery sag, relative to each vehicle's own stock cranking speed. The engine needs a minimum cranking speed to fire, more in deep cold. Diesels need their glow plugs.
- **Temperatures:** the game's own engine thermals (or the dashboard values, or an estimate), plus cabin, intake-air and battery models. Engines cold-soak at spawn and cool down between sessions.
- **No overwritten files:** everything the mod changes on the engine goes through a small undo layer, so switching the effects off restores the stock values. No game or vehicle files are overwritten. The car you drive costs about 0.014 ms per frame, and each AI traffic car about 0.002 ms.

## Compatibility

- BeamNG.drive 0.40.x (tested on 0.40.5).
- All base vehicles: gasoline, diesel (with glow plugs), heavy trucks and buses (24 V), and electric cars (battery and cabin only).
- Modded cars that use the game's standard powertrain, with no changes needed. Tested with, among others, the Bumblebee, '77 Trans-Am, Charger Demon, F-150 Raptor R, Silverado, Suburban, RX-7 and Samurai mods. Mods that bring their own engine or starter logic may not behave as expected.

### For car modders (optional)

Every car gets sensible values worked out from its engine. To set them yourself, add a `coldStartSim` section to one of your car's parts (any part that's always installed, the engine for example). Your car still works without this mod, which just ignores the section:

```json
"coldStartSim": {
    "oilGrade": "0W-20",
    "batteryCCA": 850,
    "batteryAh": 80,
    "alternatorA": 160,
    "voltage": 12,
    "starterLockedA": 600,
    "glowPlugs": true,
    "glowPlugCount": 6
}
```

| Key | Meaning |
|---|---|
| `oilGrade` | `0W-20`, `5W-30`, `10W-30`, `10W-40`, `15W-40` or `20W-50` (default 5W-30 gasoline, 15W-40 diesel) |
| `batteryCCA`, `batteryAh` | Battery cold cranking amps and capacity (for 24 V: per battery) |
| `alternatorA` | Alternator output in amps |
| `voltage` | `12` or `24` (the system voltage) |
| `starterLockedA` | Starter locked-rotor current, in amps at 12 V |
| `glowPlugs`, `glowPlugCount` | Diesels: `false` for an engine without glow plugs; how many plugs |

## Console helpers

Open the console with `~` (game-engine context):

- `coldStartSim_main.runColdTest()`: cold-starts one of each kind of base vehicle at −20 °C (`runColdTest(-35)` for another temperature) and records the results.
- `coldStartSim_main.setPreset("casual")`: `display`, `casual`, `realistic` or `hardcore`.
- `coldStartSim_main.vehicleAction("blockHeater")`: also `"charger"`, `"jumpLeads"` or `"ackWarnings"`, for the car you're in.

## Reporting a problem

Open an issue with the car, config, temperature and realism preset. Attach `%LOCALAPPDATA%\BeamNG\BeamNG.drive\current\settings\coldStartSim\debug\compat.json`, where the mod records what it saw for each car.

## Repository

`mod/` is exactly what ships: zip the **contents** of `mod/`, so that `lua/`, `scripts/` and `ui/` sit at the zip's root, and name the zip `coldstartsim.zip`. To run from a clone instead, link the folder into the game, for example `mklink /J "%LOCALAPPDATA%\BeamNG\BeamNG.drive\current\mods\unpacked\coldstartsim" "<clone>\mod"`. While it's linked, don't delete the mod from the in-game mod manager: that deletes the files through the link.

<!-- License: this repo has no LICENSE file yet. Add one (e.g. MIT) and mention it here. -->
