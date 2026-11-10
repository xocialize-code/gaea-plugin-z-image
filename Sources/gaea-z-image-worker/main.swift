import GaeaPluginKit
import ZImagePlugin

// The plugin's worker: ZImagePlugin's definition over GPP (GaeaPluginKit). `--manifest <path>` writes manifest.json.
await GaeaPluginMain.run(zImagePlugin)
