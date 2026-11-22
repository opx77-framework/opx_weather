Config = {}

-- Named looks of the sky owned by opx_weather itself, applied with ApplyPreset / ApplyToPlayer.
-- Other resources declare their own presets at runtime with exports.opx_weather:RegisterPreset (see README).
-- Fields (all optional, at least one of time / weather / rate / frozen flags):
--   time          = { hour, minute, second } (or { hour = h, minute = m, second = s })
--   weather       = a weather name or alias of Config.weathers (sunny, lightclouds, cloudy, rain, fog...)
--   transition    = seconds of weather blend, 0..300 (default 0: instant)
--   rate          = game seconds per real second, 0..120 (8 = the engine's natural speed)
--   frozen        = true stops the clock AND pins the weather; false releases both
--   timeFrozen    = overrides `frozen` for the clock only
--   weatherFrozen = overrides `frozen` for the weather only (pinned = no random draws)
Config.presets = {
	-- Character selection and creation: bright, still, flattering light.
	showcase = { time = { 13, 0, 0 }, weather = 'sunny', frozen = true, transition = 0 },
	-- A quiet evening, for scenes that want it.
	dusk = { time = { 19, 30, 0 }, weather = 'lightclouds', frozen = true, transition = 0 },
}

-- The weather catalogue of open77_weather (system/open77_weather/shared/config.lua › presets and aliases).
-- A resource cannot read another resource's files, so this is a mirror: GetWeathers / ResolveWeather answer
-- from it and RegisterPreset validates against it. If you add a weather to open77_weather, add it here too.
-- SetWeather itself is not filtered by this list: the authority has the last word ('unknown_weather').
Config.weathers = {
	{ name = 'sunny',       preset = '24h_weather_sunny' },
	{ name = 'lightclouds', preset = '24h_weather_light_clouds' },
	{ name = 'cloudy',      preset = '24h_weather_cloudy' },
	{ name = 'rain',        preset = '24h_weather_rain' },
	{ name = 'heavyclouds', preset = '24h_weather_heavy_clouds' },
	{ name = 'fog',         preset = '24h_weather_fog' },
	{ name = 'pollution',   preset = '24h_weather_pollution' },
	{ name = 'sandstorm',   preset = '24h_weather_sandstorm' },
}
Config.weatherAliases = {
	clear = 'sunny',
	clouds = 'cloudy',
	light_clouds = 'lightclouds',
	heavy_clouds = 'heavyclouds',
	storm = 'sandstorm',
}

-- ApplyToPlayer refuses the shared world bucket (it would change everyone's sky). true allows it: the preset
-- is then applied to the shared sky itself.
Config.allowSharedBucket = false

-- Routing bucket every player shares (open77 default). Passing it as `bucket` to any export means the shared
-- sky (same as nil); it is never turned into an override.
Config.sharedBucket = 0

-- Name of the environment authority resource. Watched so OPX overrides survive its restart.
Config.authority = 'open77_weather'

-- A `restart` / `stop` + `start` of the authority returns every sky to its configuration and forgets every
-- bucket override. true re-applies the overrides made through opx_weather (time advanced while it was down,
-- weather, rate, frozen flags). The shared sky is never re-applied: a restart is the operator's reset lever.
Config.restoreAfterAuthorityRestart = true

-- The authority holds at most 64 bucket overrides at once (shared by every resource). When a new one is
-- refused, opx_weather releases ONE of its own overrides that has nobody standing in it and that nobody
-- touched for this many seconds, then retries. false = never reclaim (the call fails with
-- 'too_many_environment_overrides').
Config.reclaimEmptyAfter = 30

-- A sky given by ApplyToPlayer is released as soon as that player leaves the bucket and nobody else is in it
-- (it is always released when the player disconnects). false = keep it until ClearPlayer / Reset.
Config.releasePlayerSkyOnLeave = true

-- A stopping opx_weather cannot reach the authority, so the bucket overrides it made outlive its stop. They are
-- recorded in Open77.kvp and settled at its next start: an empty one is cleared, one that players still stand
-- in (and whose owner still runs) is kept and tracked again. false = never record nor settle them.
Config.clearLeftoversOnStart = true
