---@meta
-- opx_weather server exports (all synchronous, never yield). Every setter answers the environment state, or
-- `false, reason`.
-- Reasons: environment_unavailable (open77_weather not running), invalid_bucket, invalid_time, invalid_rate,
-- invalid_weather (not a string), unknown_preset, shared_bucket, invalid_player, bucket_unavailable;
-- from the authority: unknown_weather, unknown_bucket, too_many_environment_overrides,
-- permission_denied:world.environment. Preset registration: see RegisterPreset / UnregisterPreset.
-- bucket nil or Config.sharedBucket (0) = the shared sky, never an override. Any other bucket gets its own
-- override on first use, seeded from the shared sky. The authority holds at most 64 overrides (all resources):
-- when refused, opx_weather releases one of its own empty ones (Config.reclaimEmptyAfter) and retries once.
-- The owner of an override or a preset is the calling resource; both are removed when it stops (owner_stopped).
-- Provider contract (opx_core Config.providers.weather): the ten functions GetState ... ClearPlayer. Presets,
-- catalogue, GetOverrides and the events are optional extras; callers handle their absence.

---@class OpxEnvironmentState  What Open77.environment.getState answers (open77_weather is the authority).
---@field scope string 'default' or 'bucket:<n>'
---@field bucket integer|nil nil for the shared sky
---@field hour integer
---@field minute integer
---@field second integer
---@field secondsOfDay number
---@field rate number game seconds per real second
---@field frozen boolean clock stopped (same as timeFrozen)
---@field timeFrozen boolean
---@field weather string canonical weather name (sunny, rain...)
---@field weatherPreset string REDengine 24h_weather_* value
---@field weatherFrozen boolean pinned: no random draws
---@field randomWeather boolean
---@field transitionSeconds number
---@field weatherTransitionRemainingMs number
---@field nextWeatherInMs number|nil
---@field revision integer
---@field authorityEpoch integer
---@field buckets integer[] every bucket holding an override (all resources), ascending
---@field reason string

---@class OpxWeatherPreset
---@field time? integer[]|{hour:integer, minute?:integer, second?:integer} { hour, minute, second }
---@field weather? string weather name or alias (GetWeathers)
---@field transition? number 0..300 seconds (default 0)
---@field rate? number 0..120 game seconds per real second
---@field frozen? boolean stops the clock and pins the weather (false releases both)
---@field timeFrozen? boolean overrides `frozen` for the clock
---@field weatherFrozen? boolean overrides `frozen` for the weather
---@field name? string (read back only)
---@field resource? string owner (read back only)

---@class OpxWeatherInfo  Last argument of opx:weatherChanged.
---@field resource? string resource that made / owned the change
---@field preset? string preset applied (or last applied to that bucket)
---@field source? integer player of an ApplyToPlayer sky

---@class OpxWeatherOverride
---@field bucket integer
---@field resource string owner (the resource whose call created it)
---@field preset string|nil last preset applied
---@field source integer|nil player of an ApplyToPlayer sky
---@field players integer players standing in the bucket
---@field lost boolean the authority is down; restored when it comes back

---@class OpxWeatherCatalogueEntry
---@field name string
---@field preset string|nil REDengine value
---@field aliases string[]

exports.opx_weather = {}

---@param bucket? integer nil (or Config.sharedBucket) = the shared sky
---@return OpxEnvironmentState|false state, string? reason 'unknown_bucket' = this bucket has no override (it follows the shared sky)
function exports.opx_weather:GetState(bucket) end
---@param hour integer 0..23
---@param minute? integer 0..59
---@param second? integer 0..59
---@param bucket? integer
---@return OpxEnvironmentState|false state, string? reason
function exports.opx_weather:SetTime(hour, minute, second, bucket) end
---@param frozen boolean
---@param bucket? integer
---@return OpxEnvironmentState|false state, string? reason
function exports.opx_weather:FreezeTime(frozen, bucket) end
---@param rate number game seconds per real second, 0..120 (8 = engine speed)
---@param bucket? integer
---@return OpxEnvironmentState|false state, string? reason
function exports.opx_weather:SetTimeRate(rate, bucket) end
---@param preset string weather name, alias or REDengine preset (sunny, lightclouds, cloudy, rain, fog...)
---@param transitionSeconds? number 0..300, default 0 (instant)
---@param bucket? integer
---@return OpxEnvironmentState|false state, string? reason
function exports.opx_weather:SetWeather(preset, transitionSeconds, bucket) end
--- Pins the weather (no random draws) or releases it.
---@param frozen boolean
---@param bucket? integer
---@return OpxEnvironmentState|false state, string? reason
function exports.opx_weather:FreezeWeather(frozen, bucket) end
--- Retires a bucket override (never the shared bucket): its players see the shared sky again.
---@param bucket integer
---@return OpxEnvironmentState|false state, string? reason the shared sky state on success
function exports.opx_weather:Reset(bucket) end
--- Applies a named preset (Config.presets or RegisterPreset), e.g. 'showcase'.
---@param name string
---@param bucket? integer
---@return OpxEnvironmentState|false state, string? reason
function exports.opx_weather:ApplyPreset(name, bucket) end
--- Applies a preset to the player's own routing bucket only (refused on the shared bucket: 'shared_bucket',
--- unless Config.allowSharedBucket). One sky per player: a new one in another bucket gives back the old one if
--- empty. Released when the player disconnects, and when he leaves the bucket and nobody else is in it
--- (Config.releasePlayerSkyOnLeave).
---@param source integer
---@param name string
---@return OpxEnvironmentState|false state, string? reason
function exports.opx_weather:ApplyToPlayer(source, name) end
--- Gives back the sky ApplyToPlayer gave this player (else his current bucket's override).
---@param source integer
---@return OpxEnvironmentState|false state, string? reason
function exports.opx_weather:ClearPlayer(source) end

--- Declares a preset owned by the calling resource (removed when it stops). Re-registering your own name replaces it.
--- Prefix names with your resource (heist_night). Another running resource's name = preset_taken; the config.lua
--- ones are protected. A preset is applied weather first: an unknown weather changes nothing. At most 128 presets.
---@param name string lowercase, [a-z][a-z0-9_]+, 2..32 chars
---@param definition OpxWeatherPreset
---@return boolean ok, string? reason 'invalid_name'|'preset_taken'|'preset_limit'|'invalid_preset'|'empty_preset'|'invalid_time'|'unknown_weather'|'invalid_transition'|'invalid_rate'
function exports.opx_weather:RegisterPreset(name, definition) end
---@param name string
---@return boolean ok, string? reason 'unknown_preset'|'not_owner'|'protected'
function exports.opx_weather:UnregisterPreset(name) end
---@param name string
---@return OpxWeatherPreset|nil preset normalised copy (time = {h, m, s}, weather canonical, frozen flags resolved)
function exports.opx_weather:GetPreset(name) end
---@return table<string, OpxWeatherPreset> presets by name
function exports.opx_weather:GetPresets() end
--- Config.weathers mirrors open77_weather/shared/config.lua: add a weather there, add it here too.
--- SetWeather is not filtered by this list (the authority decides).
---@return OpxWeatherCatalogueEntry[] weathers the authority knows (Config.weathers mirror)
function exports.opx_weather:GetWeathers() end
---@param name string name, alias or REDengine preset
---@return string|nil canonical canonical weather name, nil when unknown
function exports.opx_weather:ResolveWeather(name) end
---@return OpxWeatherOverride[] overrides made through opx_weather, ascending by bucket
function exports.opx_weather:GetOverrides() end

-- Events (server, host-wide):
-- opx:weatherChanged (bucket|nil, state|nil, reason, info: OpxWeatherInfo)  every change made through opx_weather
--   reason: a call (time, time_frozen, time_rate, weather, weather_frozen, preset, reset); an override released
--   (player_dropped, player_left, owner_stopped, reclaimed: state = the shared sky again); cleared_externally
--   (Open77.environment.clearBucket called directly); authority_stopped (state nil), then restored.
--   For every environment change whoever made it, listen to the platform event onEnvironmentChanged(state).
-- opx:weatherPresetRegistered (name, preset: OpxWeatherPreset)
-- opx:weatherPresetUnregistered (name)
