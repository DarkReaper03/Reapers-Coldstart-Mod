<template>
  <div class="cswl" :class="[`layout-${layout}`, { 'is-waiting': !live }]" :style="{ '--lamp-scale': lampScale }">
    <div class="cswl-lights">
      <button
        v-for="lamp in lamps"
        :key="lamp.id"
        type="button"
        class="cswl-lamp"
        :class="[`lvl-${lamp.level}`, { lit: lamp.lit, acked: lamp.acked, idle: !lamp.lit }]"
        :title="lamp.tooltip"
        @click="ack(lamp)">
        <svg viewBox="0 0 24 24" aria-hidden="true" v-html="ICONS[lamp.icon]"></svg>
      </button>
    </div>
    <div v-if="message" class="cswl-text" :class="`lvl-${message.level}`">{{ message.text }}</div>
  </div>
</template>

<script setup>
// ColdStart Sim warning lights (Phase 4). The vehicle side evaluates the warnings
// (lua/common/coldStartSim/warnings.lua) and streams the active ones as packet.warn:
// [[id, level, acked], ...] with level 0 info, 1 caution, 2 warning, 3 critical.
// Clicking a lit lamp acknowledges its warnings: they stay lit, dimmed, and stop alerting.
import { computed, onBeforeUnmount, onMounted, ref } from "vue"
import { useBridge } from "@/bridge"
import { useEvents, useStreams } from "@/services/events"

const STREAM = "coldStartSim"
const STALE_AFTER_MS = 1500

const { api } = useBridge()

// lamp layout, idle look and size, from the settings screen (pause menu → Mods → ColdStart Sim)
const layout = ref("row") // row | column | grid
const idleStyle = ref("dim") // dim | hide
const lampScale = ref(1)
function applySettings(s) {
  const lights = s && typeof s === "object" ? s.lights : null
  if (!lights) return
  if (lights.layout) layout.value = lights.layout
  if (lights.idle) idleStyle.value = lights.idle
  if (typeof lights.size === "number") lampScale.value = lights.size
}
const events = useEvents()
events.on("ColdStartSimSettings", applySettings)
onMounted(() => {
  // (through engineLua: the bridge's `lua` proxy only knows the game's own functions)
  api.engineLua("coldStartSim_main and coldStartSim_main.getSettings()", applySettings)
})

// One lamp per dashboard symbol, in dashboard order; several warnings can share a lamp.
const LAMPS = [
  { id: "oil", icon: "oil", warnings: ["OIL_PRESS_LOW", "OIL_PRESS_COLD_REVS"] },
  { id: "battery", icon: "battery", warnings: ["BATT_FROZEN", "VOLT_CRITICAL", "BATT_FLAT", "VOLT_LOW", "VOLT_HIGH", "NOT_CHARGING", "BATT_SOC_LOW", "CRANK_VOLT_LOW"] },
  { id: "coolant", icon: "coolant", warnings: ["COOLANT_HIGH"] },
  { id: "oilTemp", icon: "oilTemp", warnings: ["OIL_TEMP_HIGH"] },
  { id: "oilLevel", icon: "oilLevel", warnings: ["OIL_LEVEL_LOW"] },
  { id: "cold", icon: "cold", warnings: ["ENGINE_COLD"] },
  { id: "glow", icon: "glow", warnings: ["GLOW_WAIT"] },
  { id: "starter", icon: "starter", warnings: ["STARTER_HOT"] },
  { id: "intake", icon: "intake", warnings: ["IAT_HIGH"] },
  { id: "plug", icon: "plug", warnings: ["BLOCK_HEATER_CORD", "PLUGGED_IN"] },
  { id: "ice", icon: "ice", warnings: ["ICE_RISK"] },
]

const TEXTS = {
  OIL_PRESS_LOW: "LOW OIL PRESSURE",
  OIL_PRESS_COLD_REVS: "COLD OIL · KEEP REVS LOW",
  OIL_TEMP_HIGH: "OIL TEMPERATURE HIGH",
  OIL_LEVEL_LOW: "OIL LEVEL LOW",
  COOLANT_HIGH: "ENGINE TEMPERATURE HIGH",
  ENGINE_COLD: "ENGINE COLD",
  VOLT_CRITICAL: "BATTERY VOLTAGE CRITICAL",
  VOLT_LOW: "BATTERY VOLTAGE LOW",
  VOLT_HIGH: "CHARGING VOLTAGE HIGH",
  NOT_CHARGING: "NOT CHARGING",
  CRANK_VOLT_LOW: "WEAK BATTERY",
  BATT_SOC_LOW: "BATTERY LOW",
  BATT_FLAT: "BATTERY FLAT",
  BATT_FROZEN: "BATTERY FROZEN",
  GLOW_WAIT: "WAIT TO START",
  STARTER_HOT: "STARTER HOT",
  ICE_RISK: "ICE RISK",
  IAT_HIGH: "INTAKE AIR HOT",
  PLUGGED_IN: "PLUGGED IN",
  BLOCK_HEATER_CORD: "DROVE OFF PLUGGED IN",
}

// Simple line icons (24x24, stroked with currentColor)
const ICONS = {
  oil: '<path d="M3 13h9l4-3h3l2 2-2 1h-2l-4 4H5z"/><path d="M8 13v-2h4"/><path d="M21 15c0 1-.6 2-1.3 2s-1.2-1-1.2-2 1.2-2.5 1.2-2.5"/>',
  battery: '<rect x="3" y="7" width="18" height="12" rx="1.5"/><path d="M6 7V5h3v2M15 7V5h3v2"/><path d="M6.5 13h3M8 11.5v3M14.5 13h3"/>',
  coolant: '<path d="M12 3v11"/><circle cx="12" cy="16.5" r="2.5"/><path d="M12 6h3M12 9h3"/><path d="M3 20c1.5-1 3-1 4.5 0s3 1 4.5 0 3-1 4.5 0 3 1 4.5 0"/>',
  oilTemp: '<path d="M9 3v11"/><circle cx="9" cy="16.5" r="2.5"/><path d="M9 6h2.5M9 9h2.5"/><path d="M18 9c0 0-3 3.5-3 5.5a3 3 0 0 0 6 0C21 12.5 18 9 18 9z"/>',
  oilLevel: '<path d="M3 11h9l4-3h3l2 2-2 1h-2l-4 4H5z"/><path d="M8 11V9h4"/><path d="M3 20c1.5-1 3-1 4.5 0s3 1 4.5 0 3-1 4.5 0 3 1 4.5 0"/>',
  cold: '<path d="M12 3v11"/><circle cx="12" cy="16.5" r="2.5"/><path d="M12 6h3M12 9h3"/><path d="M4 6l2 2M4 10l2-2M18 15l2 2M18 19l2-2"/>',
  glow: '<path d="M4 12c0-3 2-3 2-6M9 12c0-3 2-3 2-6M14 12c0-3 2-3 2-6"/><path d="M3 12h17v2a6 6 0 0 1-6 6H9a6 6 0 0 1-6-6z"/>',
  starter: '<circle cx="11" cy="13" r="6"/><path d="M11 9.5v3.5l2.5 1.5"/><path d="M17 7l3-3M18 10h3M14 4l1-2"/>',
  intake: '<path d="M3 8h11a3 3 0 1 0-3-3"/><path d="M3 12h15a3 3 0 1 1-3 3"/><path d="M3 16h7"/>',
  ice: '<path d="M12 2v20M3.3 7l17.4 10M3.3 17L20.7 7"/><path d="M9.5 3.5L12 5l2.5-1.5M9.5 20.5L12 19l2.5 1.5"/>',
  plug: '<path d="M9 3v5M15 3v5"/><path d="M6 8h12v3a6 6 0 0 1-12 0z"/><path d="M12 17v4"/>',
}

const packet = ref(null)
const lastPacketAt = ref(0)
const clock = ref(Date.now())
let clockTimer = null

useStreams([STREAM], streams => {
  const data = streams && streams[STREAM]
  if (!data) return
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

// active warnings by id: { level, acked }
const active = computed(() => {
  const map = {}
  const list = (live.value && packet.value && packet.value.warn) || []
  for (const entry of Array.isArray(list) ? list : Object.values(list)) {
    if (!entry) continue
    const [id, level, acked] = Array.isArray(entry) ? entry : [entry[1], entry[2], entry[3]]
    map[id] = { level: Number(level) || 0, acked: !!acked }
  }
  return map
})

const LEVEL_NAMES = ["info", "caution", "warning", "critical"]

const lamps = computed(() => {
  const result = []
  for (const lamp of LAMPS) {
    let best = null
    const lit = []
    for (const id of lamp.warnings) {
      const state = active.value[id]
      if (!state) continue
      lit.push(id)
      if (!best || state.level > best.level || (state.level === best.level && best.acked && !state.acked)) {
        best = { id, ...state }
      }
    }
    if (!best && idleStyle.value === "hide") continue
    result.push({
      id: lamp.id,
      icon: lamp.icon,
      lit: !!best,
      level: best ? LEVEL_NAMES[best.level] || "info" : "off",
      acked: best ? lit.every(id => active.value[id].acked) : false,
      warnings: lit,
      tooltip: best ? lit.map(id => TEXTS[id] || id).join(" · ") + (best.acked ? " (acknowledged)" : " · click to acknowledge") : "",
    })
  }
  return result
})

// the most severe unacknowledged warning, spelled out under the lamps
const message = computed(() => {
  let best = null
  for (const [id, state] of Object.entries(active.value)) {
    if (state.level < 1) continue // info lamps speak for themselves
    if (!best || (best.acked && !state.acked) || (best.acked === state.acked && state.level > best.level)) {
      best = { id, ...state }
    }
  }
  if (!best) return null
  return { text: TEXTS[best.id] || best.id, level: LEVEL_NAMES[best.level] || "info" }
})

function ack(lamp) {
  if (!lamp.lit) return
  for (const id of lamp.warnings) {
    api.activeObjectLua(`if coldStartSim and coldStartSim.ackWarnings then coldStartSim.ackWarnings("${id}") end`)
  }
}
</script>

<style scoped lang="scss">
.cswl {
  container-type: size;
  width: 100%;
  height: 100%;
  display: flex;
  flex-direction: column;
  justify-content: center;
  gap: 0.2rem;
  padding: 0.3rem 0.4rem;
  box-sizing: border-box;
  overflow: hidden;
  color: var(--bng-off-white, #f2f2f2);
  font-family: var(--fnt-defs, sans-serif);
  background: rgba(var(--bng-off-black-rgb, 18, 18, 20), 0.72);
  border-radius: var(--bng-corners-2, 0.5rem);

  &.is-waiting {
    opacity: 0.5;
  }
}

.cswl-lights {
  display: flex;
  flex-wrap: wrap;
  gap: 0.18rem;
  align-items: center;
  justify-content: center;
}

.layout-column .cswl-lights {
  flex-direction: column;
  flex-wrap: nowrap;
}

.layout-grid .cswl-lights {
  display: grid;
  grid-template-columns: repeat(5, 1fr);
}

.cswl-lamp {
  width: calc(1.7rem * var(--lamp-scale, 1));
  height: calc(1.7rem * var(--lamp-scale, 1));
  padding: calc(0.16rem * var(--lamp-scale, 1));
  border: none;
  border-radius: 0.35rem;
  background: rgba(255, 255, 255, 0.05);
  color: rgba(255, 255, 255, 0.16);
  cursor: default;

  svg {
    width: 100%;
    height: 100%;
    fill: none;
    stroke: currentColor;
    stroke-width: 1.7;
    stroke-linecap: round;
    stroke-linejoin: round;
  }

  &.lit {
    cursor: pointer;
  }

  &.lvl-info {
    color: #4aa8ff;
    box-shadow: 0 0 0.45rem rgba(74, 168, 255, 0.35);
  }

  &.lvl-caution,
  &.lvl-warning {
    color: #ffb020;
    box-shadow: 0 0 0.5rem rgba(255, 176, 32, 0.45);
  }

  &.lvl-critical {
    color: #ff4d4d;
    box-shadow: 0 0 0.6rem rgba(255, 77, 77, 0.55);
    animation: cswl-flash 0.9s steps(2, start) infinite;
  }

  &.acked {
    opacity: 0.45;
    box-shadow: none;
    animation: none;
  }
}

// a row keeps all eleven lamps on one line in any box width (the size setting can still make them
// bigger, then they wrap)
.layout-row .cswl-lamp {
  width: calc(min(1.7rem, (100cqw - 1rem) / 11.6) * var(--lamp-scale, 1));
  height: calc(min(1.7rem, (100cqw - 1rem) / 11.6) * var(--lamp-scale, 1));
  padding: calc(min(0.16rem, (100cqw - 1rem) / 120) * var(--lamp-scale, 1));
}

@keyframes cswl-flash {
  to {
    visibility: hidden;
  }
}

.cswl-text {
  text-align: center;
  font-size: 0.6rem;
  font-weight: 700;
  letter-spacing: 0.06em;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;

  &.lvl-caution,
  &.lvl-warning {
    color: #ffc861;
  }

  &.lvl-critical {
    color: #ff7a7a;
  }
}

// bigger box, bigger text (the game's UI-apps editor resizes the app; the lamp size is a setting)
@container (min-height: 110px) {
  .cswl-text {
    font-size: 0.75rem;
  }
}
</style>
