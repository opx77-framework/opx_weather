# opx_weather

Time and weather for the server: the shared sky, a sky per routing bucket, and named presets. No menu and no commands, server exports only.

## Install
- Needs: `open77_weather` (official). Load after `opx_core`. Without `open77_weather` every call answers `false, 'environment_unavailable'`.
- No database.
- Provider of the weather slot (`opx_core` `Config.providers.weather`): a replacement implements the exports in `types.lua`.
- If you add a weather to `open77_weather`, add it to `Config.weathers` too.

## Config
`config.lua`: `Config.presets` (`showcase` and `dusk` ship), `Config.allowSharedBucket`, `Config.releasePlayerSkyOnLeave`. Everything else is commented in the file.

## For developers
- Reach it through the provider slot (`exports.opx_core:GetProvider('weather')`), not by name.
- `SetTime(h, m?, s?, bucket?)`, `SetWeather(name, transitionSeconds?, bucket?)`, `FreezeTime` / `FreezeWeather(frozen, bucket?)` → state or `false, reason`. `bucket` nil = shared sky.
- `ApplyPreset(name, bucket?)`, `Reset(bucket)` → state or `false, reason`.
- `ApplyToPlayer(source, name)` / `ClearPlayer(source)`: a sky only the player's private bucket sees.
- `RegisterPreset(name, definition)` → `true` or `false, reason`. The preset belongs to your resource and goes when it stops.
- Events: `opx:weatherChanged (bucket, state, reason, info)`, `opx:weatherPresetRegistered (name, preset)`, `opx:weatherPresetUnregistered (name)`.
- Full contract: `types.lua`.
