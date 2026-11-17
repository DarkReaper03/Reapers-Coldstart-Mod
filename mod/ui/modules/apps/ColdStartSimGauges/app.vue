<template>
  <div v-if="!hidden" class="csim" :class="[`theme-${hud.theme}`, { 'is-waiting': !live, compact: hud.compact }]" :style="rootStyle">
    <header v-if="hud.showTitle" class="csim-head">
      <span class="csim-title" :title="titleTooltip">{{ title }}</span>
      <span class="csim-state" :class="`state-${state.id}`">{{ state.label }}</span>
    </header>

    <div v-if="live" class="csim-grid">
      <div v-for="tile in tiles" :key="tile.id" class="csim-tile" :class="`lvl-${tile.level}`">
        <span class="csim-label">{{ tile.label }}</span>
        <span class="csim-reading">
          <span class="csim-value">{{ tile.value }}</span>
          <span v-if="tile.unit" class="csim-unit">{{ tile.unit }}</span>
        </span>
        <span v-if="tile.sub && !hud.compact" class="csim-sub">{{ tile.sub }}</span>
      </div>
    </div>
    <div v-else class="csim-waiting">Waiting for vehicle data…</div>

    <footer v-if="live && hud.showFooter" class="csim-foot">{{ footer }}</footer>
  </div>
</template>

<script setup>
// ColdStart Sim gauges (Phase 3: simulated battery, oil pressure, cabin, intake and glow plugs, plus
// why a cold engine isn't firing yet while it cranks).
// Data comes from the vehicle-side stream "coldStartSim" (lua/vehicle/coldStartSim/telemetry.lua),
// always in °C / kPa / V / A / rpm. Units follow the player's game settings through the bridge.
import { computed, onBeforeUnmount, onMounted, ref } from "vue"
import { useBridge } from "@/bridge"
import { useEvents, useStreams } from "@/services/events"

const STREAM = "coldStartSim"
const STALE_AFTER_MS = 1500
const SHOW_CRANK_VOLTAGE_MS = 15000 // after a start, the battery tile shows the cranking voltage

const { units, api } = useBridge()

// Settings from the settings screen (pause menu → Mods → ColdStart Sim), kept by the game-engine
// side and pushed as the ColdStartSimSettings event. Defaults until they arrive.
const DEFAULT_TILES = ["battery", "oilP", "coolant", "oil", "glow", "oat", "cabin", "iat", "block", "rpm", "boost"]
const hud = ref({
  tiles: DEFAULT_TILES.map(id => ({ id, visible: true })),
  theme: "dark",
  opacity: 0.72,
  scale: 1,
  compact: false,
  showTitle: true,
  showFooter: true,
  autoHide: "never",
  units: { temperature: "game", pressure: "game" },
})
function applySettings(s) {
  if (!s || typeof s !== "object" || !s.hud) return
  const next = { ...hud.value, ...s.hud }
  next.tiles = Array.isArray(s.hud.tiles) ? s.hud.tiles : Object.values(s.hud.tiles || {})
  next.units = { ...hud.value.units, ...(s.hud.units || {}) }
  hud.value = next
}
const events = useEvents()
events.on("ColdStartSimSettings", applySettings)
onMounted(() => {
  // (through engineLua: the bridge's `lua` proxy only knows the game's own functions)
  api.engineLua("coldStartSim_main and coldStartSim_main.getSettings()", applySettings)
})

const rootStyle = computed(() => ({
  "--csim-bg-alpha": hud.value.opacity,
  zoom: hud.value.scale,
}))

const packet = ref(null)
const lastPacketAt = ref(0)
const clock = ref(Date.now())
const crankEndedAt = ref(0)
let wasCranking = false
let clockTimer = null

useStreams([STREAM], streams => {
  const data = streams && streams[STREAM]
  if (!data) return
  if (wasCranking && !data.cranking) crankEndedAt.value = Date.now()
  wasCranking = !!data.cranking
  packet.value = data
  lastPacketAt.value = Date.now()
})

onMounted(() => {
  clockTimer = setInterval(() => (clock.value = Date.now()), 500)
})

onBeforeUnmount(() => {
  if (clockTimer) clearInterval(clockTimer)
})

const live = computed(() => !!packet.value && clock.value - lastPacketAt.value < STALE_AFTER_MS)

const isNum = x => typeof x === "number" && Number.isFinite(x)

const formatters = {}
function formatNumber(val, decimals = 0) {
  if (!isNum(val)) return "—"
  if (val < 0 && val > -0.5 * 10 ** -decimals) val = 0
  const formatter =
    formatters[decimals] ||
    (formatters[decimals] = new Intl.NumberFormat(undefined, {
      minimumFractionDigits: decimals,
      maximumFractionDigits: decimals,
    }))
  return formatter.format(val)
}

// The game's own units (player setting), unless the settings screen overrides them.
function temperature(celsius) {
  if (!isNum(celsius)) return { value: "—", unit: "" }
  const override = hud.value.units.temperature
  if (override === "c") return { value: formatNumber(celsius, 0), unit: "°C" }
  if (override === "f") return { value: formatNumber(celsius * 1.8 + 32, 0), unit: "°F" }
  const converted = units.temperature(celsius)
  if (!converted) return { value: formatNumber(celsius, 0), unit: "°C" }
  return { value: formatNumber(converted.val, 0), unit: converted.unit }
}

const PRESSURE_OVERRIDES = {
  kPa: { factor: 1, unit: "kPa" },
  bar: { factor: 0.01, unit: "Bar" },
  psi: { factor: 0.145038, unit: "PSI" },
}

// decimals per pressure unit; oil pressure reads best without decimals except in bar
function pressure(kPa, decimalsByUnit = { Bar: 2, kPa: 0, PSI: 1 }) {
  if (!isNum(kPa)) return { value: "—", unit: "" }
  const override = PRESSURE_OVERRIDES[hud.value.units.pressure]
  const converted = override ? { val: kPa * override.factor, unit: override.unit } : units.pressure(kPa)
  if (!converted) return { value: formatNumber(kPa, 0), unit: "kPa" }
  const decimals = decimalsByUnit[converted.unit] ?? 1
  return { value: formatNumber(converted.val, decimals), unit: converted.unit }
}

// Colour levels. Phase 4 replaces these with the configurable warning rules.
function engineTempLevel(celsius, kind) {
  if (!isNum(celsius)) return "none"
  const thermostat = isNum(packet.value?.thermostat) ? packet.value.thermostat : 90
  if (kind === "oil") {
    if (celsius >= 145) return "crit"
    if (celsius >= 130) return "warn"
  } else if (kind === "coolant") {
    if (celsius >= thermostat + 30) return "crit"
    if (celsius >= thermostat + 20) return "warn"
  }
  return celsius < 40 ? "cold" : "ok"
}

function batteryLevel(p) {
  const v = p.battV
  if (!isNum(v)) return "none"
  const scale = (p.sysV || 12) / 12
  if (p.batteryFlat) return "crit" // too flat to turn the starter
  if (p.cranking) return "ok"
  if (v > 15.2 * scale) return "crit"
  if (p.running) {
    if (v < 12.0 * scale) return "crit"
    if (v < 12.6 * scale) return "warn"
  } else {
    if (v < 11.9 * scale) return "crit"
    if (v < 12.2 * scale) return "warn"
  }
  return "ok"
}

function oilPressureLevel(p) {
  if (!isNum(p.oilP)) return "none"
  if (p.running) {
    if (p.oilP < 50) return "crit"
    if (p.oilP < 100 && (p.rpm || 0) > 1500) return "warn"
    if (isNum(p.oilPRelief) && p.oilP >= 0.95 * p.oilPRelief && isNum(p.oil) && p.oil < 40) return "cold"
  }
  return "ok"
}

function batterySub(p) {
  if (p.cranking) return "cranking"
  if (p.batteryFlat && !p.running) return "too flat to crank"
  if (isNum(p.crankMinV) && clock.value - crankEndedAt.value < SHOW_CRANK_VOLTAGE_MS) {
    return `crank ${formatNumber(p.crankMinV, 1)} V`
  }
  return isNum(p.battSoc) ? `${Math.round(p.battSoc * 100)} % charged` : ""
}

// why a cranking engine isn't allowed to fire yet (lua/vehicle/coldStartSim/coldstart.lua)
const HOLD_LABELS = {
  "too slow": "SLOW",
  "glow plugs": "GLOW",
  voltage: "LOW V",
}

const GLOW_LABELS = {
  off: "OFF",
  preheat: "WAIT",
  ready: "READY",
  crank: "ON",
  afterglow: "AFTER",
  done: "OFF",
}

// Every tile this vehicle can show (by id); `tiles` puts them in the order the settings ask for.
const allTiles = computed(() => {
  const p = packet.value
  if (!p) return {}
  const map = {}
  const add = (id, label, parts, level = "ok", sub = "") => (map[id] = { id, label, level, sub, ...parts })

  add("battery", "Battery", { value: formatNumber(p.battV, 1), unit: "V" }, batteryLevel(p), batterySub(p))
  add("soc", "Charge", { value: isNum(p.battSoc) ? formatNumber(p.battSoc * 100, 0) : "—", unit: "%" },
    isNum(p.battSoc) ? (p.battSoc < 0.25 ? "crit" : p.battSoc < 0.5 ? "warn" : "ok") : "none")
  add("battA", "Battery A", { value: isNum(p.battA) ? formatNumber(-p.battA, 0) : "—", unit: "A" }, "ok",
    isNum(p.battA) ? (p.battA > 0.5 ? "discharging" : p.battA < -0.5 ? "charging" : "") : "")
  add("battT", "Batt. temp", temperature(p.battT), isNum(p.battT) && isNum(p.battFreeze) && p.battT < p.battFreeze + 5 ? "crit" : "ok",
    isNum(p.battFreeze) ? `freezes ${temperature(p.battFreeze).value}${temperature(p.battFreeze).unit}` : "")
  if (p.kind === "ice") {
    add("oilP", "Oil press.", pressure(p.oilP), oilPressureLevel(p), p.oilTooThick ? "too thick to pump" : p.oilGrade || "")
    add("altA", "Alternator", { value: formatNumber(p.altA, 0), unit: "A" }, "ok", isNum(p.loadA) ? `loads ${formatNumber(p.loadA, 0)} A` : "")
    if (p.thermals !== "none") {
      if (isNum(p.coolant)) add("coolant", "Coolant", temperature(p.coolant), engineTempLevel(p.coolant, "coolant"))
      else add("coolant", "Coolant", { value: "air", unit: "cooled" }, "none")
      add("oil", "Oil temp", temperature(p.oil), engineTempLevel(p.oil, "oil"))
    }
    if (p.glow) {
      add("glow", "Glow plugs", { value: GLOW_LABELS[p.glow.state] || p.glow.state, unit: "" },
        p.glow.wait ? "warn" : "ok", p.glow.wait ? `${Math.round((p.glow.pct || 0) * 100)} %` : "")
    }
    add("iat", "Intake", temperature(p.iat))
    if (isNum(p.block)) add("block", "Block", temperature(p.block), engineTempLevel(p.block, "block"))
    add("rpm", "RPM", { value: isNum(p.rpm) ? formatNumber(Math.max(0, p.rpm), 0) : "—", unit: "" })
    if (p.turbo) add("boost", "Boost", pressure(p.boost, { Bar: 2, kPa: 0, PSI: 1 }))
    if (isNum(p.egt)) add("egt", "Exhaust", temperature(p.egt))
    add("visc", "Oil visc.", { value: isNum(p.visc) ? formatNumber(p.visc, 0) : "—", unit: "cSt" },
      p.oilTooThick ? "crit" : "ok", p.oilGrade || "")
    add("crank", "Last crank", { value: isNum(p.crankMinV) ? formatNumber(p.crankMinV, 1) : "—", unit: "V" },
      isNum(p.crankMinV) && p.crankMinV < 9.6 * ((p.sysV || 12) / 12) ? "warn" : "ok",
      isNum(p.crankPeakA) ? `peak ${formatNumber(p.crankPeakA, 0)} A` : "")
  }
  add("oat", "Outside", temperature(p.oat), isNum(p.oat) && p.oat <= 3 ? "ice" : "ok")
  add("cabin", "Cabin", temperature(p.cabin), isNum(p.cabin) && p.cabin < 10 ? "cold" : "ok")
  return map
})

const tiles = computed(() => {
  const map = allTiles.value
  const order = hud.value.tiles || []
  const list = []
  for (const entry of order) {
    if (entry && entry.visible && map[entry.id]) list.push(map[entry.id])
  }
  return list
})

// Auto-hide: once the engine is warm and nothing is wrong, or with the key off.
const hidden = computed(() => {
  const mode = hud.value.autoHide
  if (mode === "never") return false
  const p = packet.value
  if (!live.value || !p) return mode === "off"
  if (mode === "off") return !p.ign
  const warm = (isNum(p.coolant) ? p.coolant : p.oil) >= 60
  const warnings = Array.isArray(p.warn) && p.warn.some(w => Array.isArray(w) && w[1] >= 1)
  return !!p.running && warm && !warnings
})

const state = computed(() => {
  const p = packet.value
  if (!live.value || !p) return { id: "none", label: "—" }
  if (p.starterClick && !p.running) return { id: "crank", label: "CLICK · BATTERY FLAT" }
  if (p.starterHot && !p.running) return { id: "crank", label: "STARTER HOT · WAIT" }
  if (p.cranking) return { id: "crank", label: p.startHold ? `CRANKING · ${HOLD_LABELS[p.startHold] || p.startHold}` : "CRANKING" }
  if (p.running) return p.kind === "ev" ? { id: "run", label: "READY" } : { id: "run", label: "RUNNING" }
  if (p.ign === 1) return { id: "acc", label: "ACC" }
  if (p.ign >= 2) return { id: "on", label: "IGN ON" }
  return { id: "off", label: "OFF" }
})

const title = computed(() => (live.value && packet.value?.name) || "ColdStart Sim")
const titleTooltip = computed(() => {
  const p = packet.value
  return p ? `${p.model} / ${p.config}` : ""
})

const FUEL_LABELS = { gasoline: "Gasoline", diesel: "Diesel", electricEnergy: "Electric" }
const THERMALS_LABELS = {
  stock: "game thermals",
  electrics: "dash temps",
  estimated: "estimated temps",
  none: "no temps",
}

const footer = computed(() => {
  const p = packet.value
  if (!p) return ""
  const parts = []
  if (p.fuel) parts.push(FUEL_LABELS[p.fuel] || p.fuel)
  if (p.turbo) parts.push("boosted")
  if (p.sysV) parts.push(`${p.sysV} V`)
  if (p.kind === "ice") parts.push(THERMALS_LABELS[p.thermals] || p.thermals)
  if (p.engines > 1) parts.push(`${p.engines} engines`)
  if (isNum(p.oilLevel) && p.oilLevel < 1) parts.push("OIL LOW")
  if (p.heater) parts.push("block heater on")
  if (p.charger) parts.push(isNum(p.chargerA) ? `charging ${formatNumber(p.chargerA, 0)} A` : "charger on")
  if (p.jump) parts.push("jump leads on")
  if (p.warmer) parts.push("battery warmer on")
  if (isNum(p.ether)) parts.push(`starting fluid ${p.ether} s`)
  if (p.carEffects === false) parts.push("effects off for this car")
  if (isNum(p.lube) && p.lube < 0.98) parts.push(`lubrication ${Math.round(p.lube * 100)}%`)
  parts.push(`v${p.mod}`)
  return parts.join(" · ")
})
</script>

<style scoped lang="scss">
.csim {
  // theme colours (the settings screen picks a theme; --csim-bg-alpha is the opacity slider)
  --csim-bg-rgb: 18, 18, 20;
  --csim-fg: #f2f2f2;
  --csim-tile-bg: rgba(255, 255, 255, 0.06);
  --csim-tile-edge: rgba(255, 255, 255, 0.15);

  container-type: inline-size;
  width: 100%;
  height: 100%;
  display: flex;
  flex-direction: column;
  gap: 0.25rem;
  padding: 0.35rem 0.45rem;
  box-sizing: border-box;
  overflow: hidden;
  color: var(--csim-fg);
  font-family: var(--fnt-defs, sans-serif);
  background: rgba(var(--csim-bg-rgb), var(--csim-bg-alpha, 0.72));
  border-radius: var(--bng-corners-2, 0.5rem);

  &.theme-amber {
    --csim-bg-rgb: 22, 12, 2;
    --csim-fg: #ffb347;
    --csim-tile-bg: rgba(255, 160, 40, 0.08);
    --csim-tile-edge: rgba(255, 170, 60, 0.35);
  }

  &.theme-blue {
    --csim-bg-rgb: 6, 12, 30;
    --csim-fg: #a8d4ff;
    --csim-tile-bg: rgba(80, 150, 255, 0.08);
    --csim-tile-edge: rgba(90, 160, 255, 0.35);
  }

  &.theme-lcd {
    --csim-bg-rgb: 146, 166, 116;
    --csim-fg: #18240e;
    --csim-tile-bg: rgba(0, 0, 0, 0.07);
    --csim-tile-edge: rgba(0, 0, 0, 0.3);
    font-family: "Consolas", "Courier New", monospace;
  }

  &.theme-contrast {
    --csim-bg-rgb: 0, 0, 0;
    --csim-fg: #ffffff;
    --csim-tile-bg: rgba(255, 255, 255, 0.12);
    --csim-tile-edge: #ffffff;
  }

  &.theme-light {
    --csim-bg-rgb: 238, 238, 238;
    --csim-fg: #1a1a1a;
    --csim-tile-bg: rgba(0, 0, 0, 0.05);
    --csim-tile-edge: rgba(0, 0, 0, 0.25);
  }

  &.compact {
    .csim-grid {
      grid-template-columns: repeat(auto-fill, minmax(3.5rem, 1fr));
      gap: 0.15rem;
    }

    .csim-tile {
      padding: 0.1rem 0.25rem;
    }

    .csim-value {
      font-size: 0.88rem;
    }
  }
}

.csim-head {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 0.5rem;
  font-size: 0.78rem;
}

.csim-title {
  font-weight: 600;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
  opacity: 0.9;
}

.csim-state {
  flex: 0 0 auto;
  font-size: 0.6rem;
  font-weight: 700;
  letter-spacing: 0.06em;
  padding: 0.1rem 0.45rem;
  border-radius: 1rem;
  background: rgba(255, 255, 255, 0.12);

  &.state-run {
    background: rgba(70, 190, 110, 0.38);
  }

  &.state-crank {
    background: rgba(240, 170, 40, 0.5);
  }

  &.state-on,
  &.state-acc {
    background: rgba(80, 150, 240, 0.38);
  }
}

.csim-grid {
  flex: 1 1 auto;
  min-height: 0;
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(4.3rem, 1fr));
  gap: 0.2rem;
  align-content: start;
  overflow: hidden;
}

.csim-tile {
  display: flex;
  flex-direction: column;
  justify-content: center;
  min-width: 0;
  padding: 0.15rem 0.35rem;
  border-radius: 0.3rem;
  background: var(--csim-tile-bg);
  border-left: 3px solid var(--csim-tile-edge);

  &.lvl-cold {
    border-left-color: #4aa8ff;

    .csim-value {
      color: #8cc8ff;
    }
  }

  &.lvl-ice {
    border-left-color: #b9ecff;
  }

  &.lvl-warn {
    border-left-color: #ffb020;

    .csim-value {
      color: #ffc861;
    }
  }

  &.lvl-crit {
    border-left-color: #ff4d4d;

    .csim-value {
      color: #ff7a7a;
    }
  }

  &.lvl-none {
    opacity: 0.6;
  }
}

.csim-label {
  font-size: 0.54rem;
  text-transform: uppercase;
  letter-spacing: 0.06em;
  opacity: 0.7;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.csim-reading {
  display: flex;
  align-items: baseline;
  gap: 0.15rem;
  white-space: nowrap;
}

.csim-value {
  font-size: 1.02rem;
  font-weight: 700;
  font-variant-numeric: tabular-nums;
}

.csim-unit {
  font-size: 0.62rem;
  opacity: 0.75;
}

.csim-sub {
  font-size: 0.52rem;
  opacity: 0.6;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.csim-waiting {
  flex: 1 1 auto;
  display: flex;
  align-items: center;
  justify-content: center;
  font-size: 0.75rem;
  opacity: 0.7;
}

.csim-foot {
  font-size: 0.56rem;
  opacity: 0.6;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

// Bigger boxes get bigger numbers (the game's UI-apps editor resizes the app).
@container (min-width: 420px) {
  .csim-grid {
    grid-template-columns: repeat(auto-fill, minmax(5.6rem, 1fr));
  }

  .csim-value {
    font-size: 1.4rem;
  }

  .csim-label {
    font-size: 0.66rem;
  }

  .csim-sub {
    font-size: 0.6rem;
  }
}
</style>
