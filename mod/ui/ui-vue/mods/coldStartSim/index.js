// ColdStart Sim: puts "ColdStart Sim" in the pause menu's Mods tab; it opens the settings screen
// (SettingsCard.vue). See the game's ui/ui-vue/mods/README.md.
import { lua } from "@/bridge"

const BUTTON_ID = "coldStartSim-settings"

export async function onLoad() {
  try {
    await lua.extensions.ui_pause_actions.registerModButton({
      id: BUTTON_ID,
      tabId: "mods",
      label: "ColdStart Sim",
      icon: "snowflake",
      componentName: "/ui/ui-vue/mods/coldStartSim/SettingsCard.vue",
    })
  } catch (err) {
    console.error("ColdStart Sim: could not add the settings button", err)
  }
}

export async function onUnload() {
  try {
    await lua.extensions.ui_pause_actions.unregisterModButton(BUTTON_ID)
  } catch (err) {
    // the pause menu may already be gone (UI reload)
  }
}
