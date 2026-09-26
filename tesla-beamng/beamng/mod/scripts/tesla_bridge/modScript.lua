-- Loads the Tesla UI bridge when the mod is active.
load("teslaBridge")
setExtensionUnloadMode("teslaBridge", "manual")

-- controls category for the "Toggle FSD" / "Toggle Autosteer" bindings (Options > Controls)
if extensions and extensions.core_input_categories then
  extensions.core_input_categories.tesla = { order = 998, icon = "settings", title = "Tesla UI Bridge", desc = "Tesla UI autopilot controls" }
end
