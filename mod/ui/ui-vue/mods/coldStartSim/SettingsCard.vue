<template>
  <div class="csset">
    <header class="csset-head">
      <span class="csset-title">ColdStart Sim</span>
      <span class="csset-version">settings</span>
    </header>

    <nav class="csset-tabs">
      <button
        v-for="t in TABS"
        :key="t.id"
        type="button"
        class="csset-tab"
        :class="{ active: tab === t.id }"
        @click="tab = t.id">
        {{ t.label }}
      </button>
    </nav>

    <div v-if="!ready" class="csset-body csset-wait">{{ error || "Loading…" }}</div>

    <div v-else class="csset-body">
      <!-- This car -->
      <section v-if="tab === 'car'" class="csset-section">
        <template v-if="car">
          <p class="csset-car">{{ car.name }}</p>
          <div class="csset-readings">
            <span>Battery <b>{{ fmt(car.battV, 1) }} V</b> · {{ car.battSoc != null ? Math.round(car.battSoc * 100) + " %" : "—" }}</span>
            <span v-if="car.kind === 'ice'">Coolant <b>{{ fmt(car.coolant != null ? car.coolant : car.oil, 0) }} °C</b></span>
            <span>Outside <b>{{ fmt(car.oat, 0) }} °C</b></span>
          </div>
          <div class="csset-row">
            <span class="csset-label">Block heater<em v-if="car.heater"> · plugged in</em></span>
            <BngButton :accent="car.heater ? 'main' : 'secondary'" @click="action('blockHeater')">{{ car.heater ? "Unplug" : "Plug in" }}</BngButton>
          </div>
          <div class="csset-row">
            <span class="csset-label">Battery charger<em v-if="car.charger"> · {{ car.chargerA ? fmt(car.chargerA, 0) + " A" : "connected" }}</em></span>
            <BngButton :accent="car.charger ? 'main' : 'secondary'" @click="action('charger')">{{ car.charger ? "Disconnect" : "Connect" }}</BngButton>
          </div>
          <div class="csset-row">
            <span class="csset-label">Jump leads<em v-if="car.jump"> · connected</em></span>
            <BngButton :accent="car.jump ? 'main' : 'secondary'" @click="action('jumpLeads')">{{ car.jump ? "Disconnect" : "Connect" }}</BngButton>
          </div>
          <div class="csset-row">
            <span class="csset-label">Battery warmer<em v-if="car.warmer"> · plugged in</em></span>
            <BngButton :accent="car.warmer ? 'main' : 'secondary'" @click="action('batteryWarmer')">{{ car.warmer ? "Unplug" : "Plug in" }}</BngButton>
          </div>
          <div class="csset-row">
            <span class="csset-label">Warning lights</span>
            <BngButton accent="secondary" @click="action('ackWarnings')">Acknowledge all</BngButton>
          </div>
          <p class="csset-hint">Drive off with anything still connected and it comes loose. Block heaters, chargers and battery
            warmers work {{ settings.sim.serviceSpeed }}× faster than real time (Simulation tab). Keybinds: Options → Controls →
            Vehicle → "ColdStart Sim: …".</p>

          <template v-if="car.kind === 'ice'">
            <h3 class="csset-sub">Starting aids</h3>
            <div class="csset-row">
              <span class="csset-label">Starting fluid<em v-if="car.ether"> · in the intake, {{ car.ether }} s</em></span>
              <BngButton accent="secondary" @click="action('startingFluid')">Spray</BngButton>
            </div>
            <div v-if="car.fuel === 'diesel'" class="csset-row">
              <span class="csset-label">Glow plugs<em v-if="car.glow && car.glow.wait"> · preheating</em></span>
              <BngButton accent="secondary" @click="action('glowCycle')">Preheat again</BngButton>
            </div>
            <p class="csset-hint">Ether lets an engine that cranks too slowly fire, for 15 s after the spray. Never with hot glow
              plugs on a diesel. Glow plugs cool down again if you wait too long after the light goes out: preheat again
              (key on).</p>
          </template>

          <h3 class="csset-sub">Garage</h3>
          <div class="csset-row">
            <span class="csset-label">Battery<em v-if="car.battCCA"> · {{ Math.round(car.battCCA) }} CCA</em></span>
            <BngButton accent="secondary" @click="action('newBattery')">Fit a new battery</BngButton>
          </div>
          <template v-if="carSetup">
            <div v-if="car.kind === 'ice'" class="csset-row">
              <span class="csset-label">Oil (change it)</span>
              <BngDropdown class="csset-control" :model-value="setupValue('oilGrade')" :items="setupItems('oilGrade', carSetup.auto.oilGrade)"
                @update:modelValue="v => changeSetup('oilGrade', v)" />
            </div>

            <h3 class="csset-sub">This car's setup</h3>
            <div class="csset-row">
              <span class="csset-label">Battery size</span>
              <BngDropdown class="csset-control" :model-value="setupValue('battery')"
                :items="setupItems('battery', carSetup.auto.cca + ' CCA')" @update:modelValue="v => changeSetup('battery', v)" />
            </div>
            <div class="csset-row">
              <span class="csset-label">System voltage</span>
              <BngDropdown class="csset-control" :model-value="setupValue('voltage')" :items="setupItems('voltage', carSetup.auto.voltage + ' V')"
                @update:modelValue="v => changeSetup('voltage', v)" />
            </div>
            <template v-if="car.kind === 'ice'">
              <div class="csset-row">
                <span class="csset-label">Fuel</span>
                <BngDropdown class="csset-control" :model-value="setupValue('fuel')" :items="setupItems('fuel', carSetup.auto.fuel)"
                  @update:modelValue="v => changeSetup('fuel', v)" />
              </div>
              <div v-if="carSetup.current.fuel === 'diesel'" class="csset-row">
                <span class="csset-label">Glow plugs</span>
                <BngDropdown class="csset-control" :model-value="setupValue('glowPlugs')"
                  :items="setupItems('glowPlugs', carSetup.auto.glowPlugs ? 'glow plugs' : 'none')" @update:modelValue="v => changeSetup('glowPlugs', v)" />
              </div>
              <div class="csset-row">
                <span class="csset-label">Block heater power</span>
                <BngDropdown class="csset-control" :model-value="setupValue('heaterWatts')" :items="carSetup.choices.heaterWatts"
                  @update:modelValue="v => changeSetup('heaterWatts', v)" />
              </div>
              <div class="csset-row">
                <BngSwitch :model-value="setupValue('effects')" label="Cold-start effects on this car"
                  @update:modelValue="v => changeSetup('effects', v)" />
              </div>
            </template>
            <BngButton accent="secondary" class="csset-button" @click="resetSetup">Back to this car's own values</BngButton>
            <p class="csset-hint">Saved for this model and config ({{ carSetup.key }}) and used every time it spawns. "Auto"
              is what the mod worked out from the engine (or the car modder's settings). Now:
              {{ carSetup.current.oilGrade || "—" }}, {{ carSetup.current.cca }} CCA / {{ carSetup.current.capacityAh }} Ah,
              {{ carSetup.current.voltage }} V, {{ carSetup.current.fuel || "—" }}.</p>
          </template>
        </template>
        <p v-else class="csset-hint">Sit in a car to see it here.</p>
      </section>

      <!-- Simulation -->
      <section v-if="tab === 'sim'" class="csset-section">
        <div class="csset-row">
          <span class="csset-label">Realism preset</span>
          <BngDropdown class="csset-control" :model-value="settings.preset" :items="schema.presets" @update:modelValue="setPreset" />
        </div>
        <p class="csset-hint">{{ PRESET_HINTS[settings.preset] }}</p>

        <div class="csset-row">
          <BngSwitch :model-value="settings.effectsOn" label="Cold-start effects (this session)" @update:modelValue="setEffectsOn" />
        </div>
        <p class="csset-hint">Off: every car behaves stock and only the gauges run. Comes back on with a game restart.</p>

        <div class="csset-row">
          <span class="csset-label">Climate</span>
          <BngDropdown class="csset-control" :model-value="settings.sim.climate" :items="schema.choices.climate"
            @update:modelValue="v => save({ sim: { climate: v } })" />
        </div>
        <p class="csset-hint">Sets the game's own outside temperature on every map (Environment in the pause menu shows it).</p>
        <div class="csset-row">
          <BngSwitch :model-value="settings.sim.soakMemory" label="Cars remember how warm they were"
            @update:modelValue="v => save({ sim: { soakMemory: v } })" />
        </div>
        <p class="csset-hint">A car you respawn within two days starts as warm (and as charged) as you left it, cooled for the
          time that has passed. Off: every spawn starts at the outside temperature.</p>
        <div class="csset-row csset-row-col">
          <span class="csset-label">Block heater and charger speed: <b>{{ settings.sim.serviceSpeed }}×</b></span>
          <BngSlider class="csset-slider" :model-value="settings.sim.serviceSpeed" :min="1" :max="60" :step="1"
            @update:modelValue="v => save({ sim: { serviceSpeed: v } }, true)" />
        </div>

        <h3 class="csset-sub">Effects</h3>
        <div v-for="toggle in schema.effectToggles" :key="toggle.key" class="csset-row csset-row-col">
          <BngSwitch :model-value="effectValue(toggle.key)" :label="toggle.label" :disabled="settings.preset === 'display'"
            @update:modelValue="v => setEffect(toggle.key, v)" />
          <span class="csset-desc">{{ toggle.desc }}<em v-if="isOverridden(toggle.key)"> · changed from the preset</em></span>
        </div>
        <div v-for="slider in schema.effectSliders" :key="slider.key" class="csset-row csset-row-col">
          <span class="csset-label">{{ slider.label }}: <b>{{ formatSlider(effectValue(slider.key), slider) }}</b></span>
          <BngSlider class="csset-slider" :model-value="effectValue(slider.key)" :min="slider.min" :max="slider.max" :step="slider.step"
            @update:modelValue="v => setEffect(slider.key, v, true)" />
        </div>
        <BngButton accent="secondary" class="csset-button" @click="reset('effects')">Back to the preset's values</BngButton>
      </section>

      <!-- Warnings -->
      <section v-if="tab === 'warnings'" class="csset-section">
        <div class="csset-row">
          <BngSwitch :model-value="settings.warnings.toasts" label="Pop-up messages" @update:modelValue="v => save({ warnings: { toasts: v } })" />
        </div>
        <div class="csset-row">
          <span class="csset-label">Messages for</span>
          <BngDropdown class="csset-control" :model-value="settings.warnings.toastLevel" :items="schema.choices.level"
            @update:modelValue="v => save({ warnings: { toastLevel: v } })" />
        </div>
        <div class="csset-row">
          <BngSwitch :model-value="settings.warnings.chime" label="Chime" @update:modelValue="v => save({ warnings: { chime: v } })" />
        </div>
        <div class="csset-row">
          <span class="csset-label">Chime for</span>
          <BngDropdown class="csset-control" :model-value="settings.warnings.chimeLevel" :items="schema.choices.level"
            @update:modelValue="v => save({ warnings: { chimeLevel: v } })" />
        </div>
        <h3 class="csset-sub">Warning lights</h3>
        <div v-for="w in schema.warnings" :key="w.id" class="csset-row">
          <BngSwitch :model-value="!disabled[w.id]" :label="w.title + ' (' + w.id + ')'" @update:modelValue="v => setWarning(w.id, v)" />
        </div>
        <BngButton accent="secondary" class="csset-button" @click="reset('warnings')">Reset warnings</BngButton>
      </section>

      <!-- Gauges -->
      <section v-if="tab === 'gauges'" class="csset-section">
        <div class="csset-row">
          <span class="csset-label">Theme</span>
          <BngDropdown class="csset-control" :model-value="settings.hud.theme" :items="schema.choices.theme"
            @update:modelValue="v => save({ hud: { theme: v } })" />
        </div>
        <div class="csset-row csset-row-col">
          <span class="csset-label">Background: <b>{{ Math.round(settings.hud.opacity * 100) }} %</b></span>
          <BngSlider class="csset-slider" :model-value="settings.hud.opacity" :min="0.1" :max="1" :step="0.05"
            @update:modelValue="v => save({ hud: { opacity: v } }, true)" />
        </div>
        <div class="csset-row csset-row-col">
          <span class="csset-label">Size: <b>{{ Math.round(settings.hud.scale * 100) }} %</b></span>
          <BngSlider class="csset-slider" :model-value="settings.hud.scale" :min="0.6" :max="1.8" :step="0.05"
            @update:modelValue="v => save({ hud: { scale: v } }, true)" />
        </div>
        <div class="csset-row">
          <BngSwitch :model-value="settings.hud.compact" label="Compact tiles" @update:modelValue="v => save({ hud: { compact: v } })" />
        </div>
        <div class="csset-row">
          <BngSwitch :model-value="settings.hud.showTitle" label="Title bar" @update:modelValue="v => save({ hud: { showTitle: v } })" />
        </div>
        <div class="csset-row">
          <BngSwitch :model-value="settings.hud.showFooter" label="Footer line" @update:modelValue="v => save({ hud: { showFooter: v } })" />
        </div>
        <div class="csset-row">
          <span class="csset-label">Show</span>
          <BngDropdown class="csset-control" :model-value="settings.hud.autoHide" :items="schema.choices.autoHide"
            @update:modelValue="v => save({ hud: { autoHide: v } })" />
        </div>
        <div class="csset-row">
          <span class="csset-label">Temperature</span>
          <BngDropdown class="csset-control" :model-value="settings.hud.units.temperature" :items="schema.choices.temperature"
            @update:modelValue="v => save({ hud: { units: { temperature: v } } })" />
        </div>
        <div class="csset-row">
          <span class="csset-label">Pressure</span>
          <BngDropdown class="csset-control" :model-value="settings.hud.units.pressure" :items="schema.choices.pressure"
            @update:modelValue="v => save({ hud: { units: { pressure: v } } })" />
        </div>

        <h3 class="csset-sub">Tiles (order and visibility)</h3>
        <div v-for="(tile, index) in settings.hud.tiles" :key="tile.id" class="csset-row csset-tile-row">
          <BngSwitch :model-value="tile.visible" :label="tileLabel(tile.id)" @update:modelValue="v => setTileVisible(index, v)" />
          <span class="csset-move">
            <button type="button" class="csset-arrow" :disabled="index === 0" @click="moveTile(index, -1)">▲</button>
            <button type="button" class="csset-arrow" :disabled="index === settings.hud.tiles.length - 1" @click="moveTile(index, 1)">▼</button>
          </span>
        </div>
        <BngButton accent="secondary" class="csset-button" @click="reset('hud')">Reset gauges</BngButton>
      </section>

      <!-- Warning lights -->
      <section v-if="tab === 'lights'" class="csset-section">
        <div class="csset-row">
          <span class="csset-label">Layout</span>
          <BngDropdown class="csset-control" :model-value="settings.lights.layout" :items="schema.choices.layout"
            @update:modelValue="v => save({ lights: { layout: v } })" />
        </div>
        <div class="csset-row">
          <span class="csset-label">Lights that are off</span>
          <BngDropdown class="csset-control" :model-value="settings.lights.idle" :items="schema.choices.idle"
            @update:modelValue="v => save({ lights: { idle: v } })" />
        </div>
        <div class="csset-row csset-row-col">
          <span class="csset-label">Light size: <b>{{ Math.round(settings.lights.size * 100) }} %</b></span>
          <BngSlider class="csset-slider" :model-value="settings.lights.size" :min="0.6" :max="2" :step="0.05"
            @update:modelValue="v => save({ lights: { size: v } }, true)" />
        </div>
        <p class="csset-hint">Add the apps from the pause menu: System → HUD Apps → edit your layout → Add app →
          "ColdStart Sim - Gauges" and "ColdStart Sim - Warning Lights". Click a lit warning light to acknowledge it.</p>
        <BngButton accent="secondary" class="csset-button" @click="reset('lights')">Reset warning lights</BngButton>
      </section>

      <!-- About -->
      <section v-if="tab === 'about'" class="csset-section">
        <p class="csset-hint">Simulates what cold weather does to a car: battery, oil pressure, engine, cabin and intake
          temperatures, cold cranking and starts that can fail, with warnings and these HUD apps. Works on base and modded
          vehicles with the standard powertrain.</p>
        <p class="csset-hint">Compatibility test (about 4 minutes, swaps your car for one of each kind of base vehicle and
          back): it records the results in settings/coldStartSim/debug/compat.json.</p>
        <BngButton accent="secondary" class="csset-button" @click="runTest(null)">Run the compatibility test</BngButton>
        <BngButton accent="secondary" class="csset-button" @click="runTest(-20)">Run it at −20 °C</BngButton>
        <BngButton accent="attention" class="csset-button" @click="reset(null)">Reset every setting</BngButton>
      </section>
    </div>
  </div>
</template>

<script setup>
// ColdStart Sim settings screen (pause menu → Mods → ColdStart Sim). Everything is stored by the
// game-engine side (lua/ge/extensions/coldStartSim/main.lua, settings/coldStartSim/settings.json);
// this card reads the schema and settings from it and sends each change back.
import { computed, onBeforeUnmount, onMounted, ref, watch } from "vue"
import { useBridge } from "@/bridge"
import { useEvents, useStreams } from "@/services/events"
import { BngButton, BngDropdown, BngSlider, BngSwitch } from "@/common/components/base"

// The bridge's `lua` proxy only knows the game's own functions (LuaFunctionSignatures.js), so the
// mod's functions are called through engineLua, like that proxy does underneath.
const { api } = useBridge()
function callGE(name, ...args) {
  const code = `coldStartSim_main.${name}(${args.map(arg => api.serializeToLua(arg)).join(",")})`
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`no answer from coldStartSim_main.${name}`)), 4000)
    api.engineLua(code, result => {
      clearTimeout(timer)
      resolve(result)
    })
  })
}

const TABS = [
  { id: "car", label: "Car" },
  { id: "sim", label: "Simulation" },
  { id: "warnings", label: "Warnings" },
  { id: "gauges", label: "Gauges" },
  { id: "lights", label: "Lights" },
  { id: "about", label: "About" },
]

const PRESET_HINTS = {
  display: "Gauges and warnings only: the engine behaves exactly as in the stock game.",
  casual: "Slow cold cranking and a cold fast idle for the feel, but it always starts.",
  realistic: "Cold engines crank slowly, can fail to start, drag and stumble; flat batteries only click.",
  hardcore: "Harder to fire, more drag and misfires, the starter overheats sooner, batteries can freeze.",
}

const tab = ref("car")
const schema = ref(null)
const settings = ref(null)
const error = ref("")
const ready = computed(() => !!schema.value && !!settings.value)

const events = useEvents()
events.on("ColdStartSimSettings", data => {
  if (data && typeof data === "object") settings.value = normalize(data)
})

// the car you sit in, live from its stream (lua/vehicle/coldStartSim/telemetry.lua)
const car = ref(null)
let carSeenAt = 0
useStreams(["coldStartSim"], streams => {
  const data = streams && streams.coldStartSim
  if (!data) return
  car.value = data
  carSeenAt = Date.now()
})
const carTimer = setInterval(() => {
  if (car.value && Date.now() - carSeenAt > 2000) car.value = null
}, 1000)
onBeforeUnmount(() => clearInterval(carTimer))

function fmt(value, decimals) {
  return typeof value === "number" && Number.isFinite(value) ? value.toFixed(decimals) : "—"
}

// The car carries out the action once the game runs (it's usually paused while this menu is
// open), so the button flips straight away; the car's stream confirms it when the game resumes.
const ACTION_FIELDS = { blockHeater: "heater", charger: "charger", jumpLeads: "jump", batteryWarmer: "warmer" }
function action(name) {
  callGE("vehicleAction", name).catch(err => console.error(err))
  const field = ACTION_FIELDS[name]
  if (field && car.value) car.value = { ...car.value, [field]: !car.value[field] }
}

// This car's setup (0.9.0): saved per model/config by the game-engine side (getCarSetup/setCarSetup).
const carSetup = ref(null)
function normalizeSetup(data) {
  if (!data || typeof data !== "object") return null
  const s = JSON.parse(JSON.stringify(data))
  if (!s.setup || Array.isArray(s.setup)) s.setup = {} // an empty Lua table arrives as []
  s.auto = s.auto || {}
  s.current = s.current || {}
  s.choices = s.choices || {}
  return s
}
async function loadCarSetup() {
  try {
    carSetup.value = normalizeSetup(await callGE("getCarSetup"))
  } catch (err) {
    console.error("ColdStart Sim car setup:", err)
  }
}
// a different car (or none): fetch its setup
watch(() => (car.value ? `${car.value.model}/${car.value.config}` : null), id => {
  if (id) loadCarSetup()
  else carSetup.value = null
}, { immediate: true })

function setupValue(key) {
  const setup = carSetup.value?.setup || {}
  if (key === "effects") return setup.effects !== false
  if (key === "heaterWatts") return setup.heaterWatts || 750
  return setup[key] !== undefined ? setup[key] : "auto"
}
// the choices, with "Auto" showing what auto means for this car
function setupItems(key, autoText) {
  return (carSetup.value?.choices?.[key] || []).map(item =>
    item.value === "auto" ? { value: "auto", label: `Auto (${autoText})` } : item)
}
async function changeSetup(key, value) {
  const setup = { ...(carSetup.value?.setup || {}) }
  if (value === "auto" || (key === "effects" && value === true)) delete setup[key]
  else setup[key] = value
  carSetup.value = { ...carSetup.value, setup } // show it straight away
  try {
    const updated = normalizeSetup(await callGE("setCarSetup", { [key]: value }))
    if (updated) carSetup.value = updated
  } catch (err) {
    console.error("ColdStart Sim car setup: could not save", err)
  }
}
async function resetSetup() {
  try {
    const updated = normalizeSetup(await callGE("resetCarSetup"))
    if (updated) carSetup.value = updated
  } catch (err) {
    console.error(err)
  }
}

// Lua sends empty tables as [] and keeps numbers; make the shapes the template expects
function normalize(data) {
  const s = JSON.parse(JSON.stringify(data))
  if (!s.effects || Array.isArray(s.effects)) s.effects = {}
  s.sim = s.sim || { climate: "game", serviceSpeed: 10, soakMemory: true }
  s.warnings = s.warnings || {}
  if (!s.warnings.disabled || Array.isArray(s.warnings.disabled)) s.warnings.disabled = {}
  s.hud = s.hud || {}
  if (!Array.isArray(s.hud.tiles)) s.hud.tiles = Object.values(s.hud.tiles || {})
  s.hud.units = s.hud.units || {}
  s.lights = s.lights || {}
  return s
}

onMounted(async () => {
  try {
    const [sch, cur] = await Promise.all([callGE("getSettingsSchema"), callGE("getSettings")])
    schema.value = sch
    settings.value = normalize(cur)
  } catch (err) {
    error.value = "ColdStart Sim isn't loaded (is the mod enabled?)"
    console.error("ColdStart Sim settings:", err)
  }
})

const disabled = computed(() => settings.value?.warnings?.disabled || {})

// Saves a partial change; sliders wait until they've settled for a moment.
let saveTimer = null
let pending = null
function mergeDeep(target, source) {
  for (const [key, value] of Object.entries(source)) {
    if (value && typeof value === "object" && !Array.isArray(value) && target[key] && typeof target[key] === "object") {
      mergeDeep(target[key], value)
    } else {
      target[key] = value
    }
  }
  return target
}
async function flush() {
  const partial = pending
  pending = null
  saveTimer = null
  if (!partial) return
  try {
    const updated = await callGE("setSettings", partial)
    if (updated) settings.value = normalize(updated)
  } catch (err) {
    console.error("ColdStart Sim settings: could not save", err)
  }
}
function save(partial, debounce = false) {
  mergeDeep(settings.value, JSON.parse(JSON.stringify(partial))) // show it straight away
  pending = mergeDeep(pending || {}, partial)
  if (saveTimer) clearTimeout(saveTimer)
  if (debounce) saveTimer = setTimeout(flush, 300)
  else flush()
}

function setPreset(name) {
  save({ preset: name, effects: false })
}

async function setEffectsOn(on) {
  settings.value.effectsOn = on
  try {
    await callGE("setEffectsEnabled", on)
  } catch (err) {
    console.error(err)
  }
}

function effectValue(key) {
  const s = settings.value
  if (s.effects && s.effects[key] !== undefined) return s.effects[key]
  const preset = schema.value?.presetOptions?.[s.preset]
  return preset ? preset[key] : undefined
}

function isOverridden(key) {
  const s = settings.value
  const preset = schema.value?.presetOptions?.[s.preset]
  return s.effects && s.effects[key] !== undefined && preset && preset[key] !== s.effects[key]
}

function setEffect(key, value, debounce = false) {
  save({ effects: { [key]: value } }, debounce)
}

function formatSlider(value, slider) {
  if (typeof value !== "number") return "—"
  return slider.step < 1 ? value.toFixed(2) : String(Math.round(value))
}

function setWarning(id, on) {
  const next = { ...disabled.value }
  if (on) delete next[id]
  else next[id] = true
  settings.value.warnings.disabled = next
  // the whole table goes over: an empty one clears it
  save({ warnings: { disabled: Object.keys(next).length ? next : false } })
}

function tileLabel(id) {
  const tile = (schema.value?.tiles || []).find(t => t.id === id)
  return tile ? tile.label : id
}

function setTileVisible(index, visible) {
  const tiles = settings.value.hud.tiles.map(t => ({ id: t.id, visible: t.visible }))
  tiles[index].visible = visible
  save({ hud: { tiles } })
}

function moveTile(index, delta) {
  const tiles = settings.value.hud.tiles.map(t => ({ id: t.id, visible: t.visible }))
  const target = index + delta
  if (target < 0 || target >= tiles.length) return
  const [tile] = tiles.splice(index, 1)
  tiles.splice(target, 0, tile)
  save({ hud: { tiles } })
}

async function reset(section) {
  try {
    const updated = await callGE("resetSettings", section)
    if (updated) settings.value = normalize(updated)
  } catch (err) {
    console.error(err)
  }
}

function runTest(celsius) {
  try {
    if (celsius === null) callGE("runCompatTest")
    else callGE("runColdTest", celsius)
  } catch (err) {
    console.error(err)
  }
}
</script>

<style scoped lang="scss">
.csset {
  display: flex;
  flex-direction: column;
  width: 100%;
  height: 100%;
  min-height: 20rem;
  max-height: 100%;
  color: var(--bng-off-white, #f2f2f2);
  background: rgba(var(--bng-off-black-rgb, 18, 18, 20), 0.85);
  border-radius: var(--bng-corners-2, 0.5rem);
  overflow: hidden;
}

.csset-head {
  display: flex;
  align-items: baseline;
  gap: 0.5rem;
  padding: 0.6rem 0.9rem 0.3rem;
}

.csset-title {
  font-size: 1.1rem;
  font-weight: 700;
}

.csset-version {
  opacity: 0.6;
  font-size: 0.8rem;
}

.csset-tabs {
  display: flex;
  gap: 0.25rem;
  padding: 0 0.6rem 0.4rem;
  border-bottom: 1px solid rgba(255, 255, 255, 0.1);
}

.csset-tab {
  flex: 1 1 auto;
  padding: 0.35rem 0.5rem;
  border: none;
  border-radius: 0.3rem;
  background: rgba(255, 255, 255, 0.06);
  color: inherit;
  font: inherit;
  font-size: 0.85rem;
  cursor: pointer;

  &.active {
    background: var(--bng-orange, #ff6600);
    color: #fff;
  }
}

.csset-body {
  flex: 1 1 auto;
  min-height: 0;
  overflow-y: auto;
  padding: 0.5rem 0.9rem 0.9rem;
}

.csset-wait {
  display: flex;
  align-items: center;
  justify-content: center;
  opacity: 0.7;
}

.csset-section {
  display: flex;
  flex-direction: column;
  gap: 0.35rem;
}

.csset-row {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 0.75rem;
  min-height: 2rem;
}

.csset-row-col {
  flex-direction: column;
  align-items: stretch;
  gap: 0.15rem;
}

.csset-label {
  font-size: 0.9rem;
}

.csset-control {
  min-width: 12rem;
}

.csset-slider {
  width: 100%;
}

.csset-desc,
.csset-hint {
  font-size: 0.75rem;
  opacity: 0.65;
  margin: 0;
}

.csset-sub {
  margin: 0.6rem 0 0.1rem;
  font-size: 0.9rem;
  text-transform: uppercase;
  letter-spacing: 0.06em;
  opacity: 0.8;
}

.csset-button {
  align-self: flex-start;
  margin-top: 0.4rem;
}

.csset-car {
  margin: 0;
  font-size: 1rem;
  font-weight: 700;
}

.csset-readings {
  display: flex;
  flex-wrap: wrap;
  gap: 0.4rem 1rem;
  font-size: 0.85rem;
  opacity: 0.85;
  margin-bottom: 0.3rem;
}

.csset-tile-row {
  border-bottom: 1px solid rgba(255, 255, 255, 0.05);
}

.csset-move {
  display: flex;
  gap: 0.2rem;
}

.csset-arrow {
  width: 1.8rem;
  height: 1.6rem;
  border: none;
  border-radius: 0.25rem;
  background: rgba(255, 255, 255, 0.1);
  color: inherit;
  cursor: pointer;

  &:disabled {
    opacity: 0.3;
    cursor: default;
  }
}
</style>
