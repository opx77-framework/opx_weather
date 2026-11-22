resource "opx_weather"
version "1.1.0"
open77_version ">=0.0.1"
auto_start true

-- Time and weather API for OPX//77 over the official authority (open77_weather, Open77.environment.*).
-- No menu, no commands: other resources call its server exports (provider slot `weather` in opx_core).
-- No hard dependency: without open77_weather every call answers `false, 'environment_unavailable'`.

permissions {
    "world.environment", -- Open77.environment.* (time, weather, per-bucket overrides)
}

server_scripts {
    "config.lua",
    "server/presets.lua",  -- weather catalogue + preset registry (Config.presets, RegisterPreset)
    "server/main.lua",     -- exports, override tracking, lifecycle
}
