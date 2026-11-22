-- opx_weather: thin, validated API over Open77.environment (open77_weather is the authority).
-- Every export answers synchronously: the environment state table, or false and a reason.
-- Bucket overrides made through this resource are tracked (owner and its VM generation, player, last known
-- state) so they can be released when their owner stops or their player leaves, reclaimed under the
-- 64-override limit, re-applied when the authority restarts, and settled at the next start when opx_weather
-- itself stopped (a stopping VM cannot reach the authority: the bucket list is kept in Open77.kvp): an empty
-- one is cleared, one that players still stand in is taken over again.
--
-- A routing bucket or a player id that is not a whole number in range ABORTS THE SERVER PROCESS inside a
-- platform native (pcall does not catch it). Every one of them is made a Lua integer by W.whole before it is
-- used, and checked once more at the doors: call(), playersIn(), validPlayer(), playerBucket().

local W = Weather
local RESOURCE = GetCurrentResourceName()
local AUTHORITY = Config.authority or 'open77_weather'
local env = Open77.environment
local whole = W.whole
local MAX_BUCKET = 4294967295 -- routing buckets are uint32
local MAX_PLAYER = 2147483647 -- a player id is a whole number from 1 up
local SHARED = whole(Config.sharedBucket, 0, MAX_BUCKET)
if not SHARED then
	W.log('warn', 'Config.sharedBucket is not a bucket number (0..%d): 0 is used', MAX_BUCKET)
	SHARED = 0
end

local tracked = {}   -- bucket -> { owner, generation, source?, preset?, touchedAt, touch, epoch, revision, snap, lost? }
local playerSky = {} -- source -> bucket given a sky by ApplyToPlayer
local touches = 0    -- orders overrides by last use (reclaim picks the least recently touched)

local function now() return Open77.time.monotonic() end

-- The resource calling an export and the generation of its VM (opx_weather itself outside an export call).
local function caller()
	local name = GetInvokingResource()
	if type(name) ~= 'string' or name == '' then return RESOURCE end
	local generation = type(GetInvokingResourceGeneration) == 'function' and GetInvokingResourceGeneration() or nil
	if type(generation) ~= 'number' then generation = W.generationOf(name) end
	return name, generation
end

local function isBucket(value)
	return math.type(value) == 'integer' and value >= 0 and value <= MAX_BUCKET
end

-- nil -> nil (shared sky); the shared bucket -> nil, true; anything that is not a bucket number -> false.
local function parseBucket(bucket)
	if bucket == nil then return nil end
	bucket = whole(bucket, 0, MAX_BUCKET)
	if not bucket then return false end
	if bucket == SHARED then return nil, true end
	return bucket
end

-- A number in low..high (NaN and the infinities are outside every range), else nil.
local function finite(value, low, high)
	if type(value) ~= 'number' or value ~= value or value < low or value > high then return nil end
	return value
end

-- Where each Open77.environment function takes its bucket.
local BUCKET_ARG = {
	getState = 1, clearBucket = 1, setTimeFrozen = 2, setTimeRate = 2, setWeatherFrozen = 2, setWeather = 3, setTime = 4,
}

-- Calls one Open77.environment function and normalises its answer. The bucket is checked one last time here,
-- whatever path led to the call.
local function call(name, ...)
	local at = BUCKET_ARG[name]
	if not at or type(env) ~= 'table' or type(env[name]) ~= 'function' then return false, 'environment_unavailable' end
	local bucket = select(at, ...)
	if bucket ~= nil and not isBucket(bucket) then
		W.log('warn', 'Open77.environment.%s not called: %s is not a bucket', name, tostring(bucket))
		return false, 'invalid_bucket'
	end
	local ok, state, reason = pcall(env[name], ...)
	if not ok then
		W.log('warn', 'Open77.environment.%s failed: %s', name, tostring(state))
		return false, 'environment_unavailable'
	end
	if not state then return false, reason or 'refused' end
	return state
end

local function playersIn(bucket, except)
	if not isBucket(bucket) then return 0 end
	local ok, list = pcall(Open77.players.inBucket, bucket)
	if not ok or type(list) ~= 'table' then return 0 end
	local n = 0
	for _, id in ipairs(list) do if id ~= except then n = n + 1 end end
	return n
end

-- opx:weatherChanged (bucket|nil, state|nil, reason, info) -------------------------

local function emit(bucket, state, reason, info)
	local ok, why = TriggerEvent('opx:weatherChanged', bucket, state or nil, reason, info or {})
	if ok == false then W.log('warn', 'opx:weatherChanged (%s) not published: %s', reason, tostring(why)) end
end

-- Leftovers -------------------------------------------------------------------------
-- A stopping VM cannot reach the authority: in our own stop handler Open77.environment answers
-- resource_stopping. The overrides made through opx_weather therefore outlive its stop, restart or reload,
-- and the next VM knows nothing of them. So the tracked buckets are written to Open77.kvp (the platform's
-- per-resource store) whenever the list changes, as "bucket:authorityEpoch[:owner],...", and the next VM
-- settles what it finds there.

local KVP_KEY = 'overrides'
local leftovers -- bucket -> authority epoch, as the previous VM left them (nil until the store is read)
local leftoverOwners = {} -- bucket -> owner resource of a leftover, when the store recorded it
local track -- defined under Tracking; clearLeftovers takes an occupied leftover over with it
local saved     -- the value the store holds, as far as this VM knows
local storeWarned = false

-- One Open77.kvp call: its results, or nil and a reason when the store cannot be used.
local function store(method, ...)
	local kvp = Open77.kvp
	if type(kvp) ~= 'table' or type(kvp[method]) ~= 'function' then return nil, 'kvp_unavailable' end
	local ok, value, reason = pcall(kvp[method], ...)
	if not ok then return nil, tostring(value) end
	return value, reason
end

local function storeFailed(reason)
	if storeWarned then return end
	storeWarned = true
	W.log('warn', 'Open77.kvp: %s. Bucket skies left by a stop of %s will not be cleared at its next start',
		tostring(reason), RESOURCE)
end

local function loadLeftovers()
	if leftovers then return end
	leftovers = {}
	if Config.clearLeftoversOnStart == false then return end
	local value, reason = store('get', KVP_KEY)
	if type(value) ~= 'string' then
		if reason then storeFailed(reason) else saved = '' end
		return
	end
	saved = value
	local read = 0
	for b, e, o in value:gmatch('(%d+):(%d+):?([%w_%-%.]*)') do
		local bucket, epoch = whole(b, 0, MAX_BUCKET), tonumber(e)
		if bucket and bucket ~= SHARED and epoch then
			leftovers[bucket] = epoch
			leftoverOwners[bucket] = o ~= '' and o or nil
		end
		read = read + 1
		if read >= 256 then break end
	end
end

local function epochText(epoch)
	epoch = finite(epoch, 0, 2 ^ 53)
	return epoch and ('%.0f'):format(epoch) or '0'
end

-- One stored entry: "bucket:epoch", plus ":owner" when the owner name cannot break the format.
local function entryText(bucket, epoch, owner)
	local text = ('%d:%s'):format(bucket, epochText(epoch))
	if type(owner) == 'string' and owner:match('^[%w_%-%.]+$') and #owner <= 64 then text = text .. ':' .. owner end
	return text
end

-- Writes the buckets to clear after us (ours, plus what the previous VM left and is not cleared yet).
local function persist()
	if Config.clearLeftoversOnStart == false then return end
	loadLeftovers()
	local entries = {}
	for bucket, t in pairs(tracked) do entries[#entries + 1] = entryText(bucket, t.epoch, t.owner) end
	for bucket, epoch in pairs(leftovers) do
		if not tracked[bucket] then entries[#entries + 1] = entryText(bucket, epoch, leftoverOwners[bucket]) end
	end
	table.sort(entries)
	local value = table.concat(entries, ',')
	if value == saved then return end
	if value == '' then
		local _, reason = store('delete', KVP_KEY) -- false without a reason: the key was not there
		if reason then return storeFailed(reason) end
	else
		local done, reason = store('set', KVP_KEY, value)
		if done ~= true then return storeFailed(reason or 'refused') end
	end
	saved = value
end

-- Settles what the previous VM left: only an override that still exists, that was made under the authority
-- instance we recorded (after a restart of the authority the same bucket number is somebody else's) and that
-- nobody claimed again through this VM. One that players still stand in, whose owner still runs (or is not
-- recorded), is tracked again: on a reload of opx_weather nobody applies those skies a second time. The
-- others are cleared. false while the authority does not answer.
local function clearLeftovers()
	loadLeftovers()
	if next(leftovers) == nil then return true end
	if not call('getState') then return false end
	local buckets = {}
	for bucket in pairs(leftovers) do buckets[#buckets + 1] = bucket end
	table.sort(buckets)
	local cleared, adopted = 0, 0
	for _, bucket in ipairs(buckets) do
		if not tracked[bucket] then
			local state, reason = call('getState', bucket)
			if reason == 'environment_unavailable' then break end -- gone again: the rest waits for it
			if state and (tonumber(state.authorityEpoch) or 0) == leftovers[bucket] then
				local owner = leftoverOwners[bucket]
				local alive = owner == nil or W.ownerAlive(owner, nil)
				if alive and playersIn(bucket) > 0 then
					if owner == nil then owner = RESOURCE end
					track(bucket, state, owner, owner ~= RESOURCE and W.generationOf(owner) or nil, {})
					adopted = adopted + 1
				elseif call('clearBucket', bucket) then
					cleared = cleared + 1
				end
			end
		end
		leftovers[bucket], leftoverOwners[bucket] = nil, nil
	end
	persist()
	if cleared > 0 then W.log('info', 'cleared %d bucket sky(s) left by the previous run of %s', cleared, RESOURCE) end
	if adopted > 0 then W.log('info', 'kept %d occupied bucket sky(s) left by the previous run of %s', adopted, RESOURCE) end
	return next(leftovers) == nil
end

-- Tracking --------------------------------------------------------------------------

local function remember(t, state)
	if type(state) ~= 'table' then return end
	t.epoch, t.revision = state.authorityEpoch, tonumber(state.revision) or t.revision
	t.snap = {
		seconds = tonumber(state.secondsOfDay) or 0,
		rate = tonumber(state.rate) or 8,
		timeFrozen = state.timeFrozen == true or state.frozen == true,
		weather = state.weather,
		weatherFrozen = state.weatherFrozen == true,
		at = now(),
	}
	t.lost = nil
end

-- The override belongs to the resource whose call created it, and to that VM (generation). The same resource
-- touching it again refreshes the generation; another resource inherits it only when the owner VM is gone.
track = function(bucket, state, owner, generation, info)
	local t = tracked[bucket]
	local known = t and t.epoch
	if not t then
		t = { owner = owner, generation = generation }
		tracked[bucket] = t
	elseif t.owner == owner or not W.ownerAlive(t.owner, t.generation) then
		t.owner, t.generation = owner, generation
	end
	if info.source then t.source = info.source end
	if info.preset then t.preset = info.preset end
	touches = touches + 1
	t.touchedAt, t.touch = now(), touches
	remember(t, state)
	if known == nil or known ~= t.epoch then persist() end
end

local function forget(bucket)
	local t = tracked[bucket]
	tracked[bucket] = nil
	if t and t.source and playerSky[t.source] == bucket then playerSky[t.source] = nil end
	if t then persist() end
	return t
end

-- Retires one of our overrides on our own initiative (drop, owner stop, reclaim).
local function release(bucket, reason)
	local t = forget(bucket)
	if not t then return false end
	local state = call('clearBucket', bucket)
	if state then emit(bucket, state, reason, { resource = t.owner, preset = t.preset, source = t.source }) end
	return state and true or false
end

-- Frees one slot under the 64-override limit: the oldest untouched override of ours nobody stands in.
local function reclaim()
	local grace = Config.reclaimEmptyAfter
	if type(grace) ~= 'number' then return false end
	local best, bestTouch
	local at = now()
	for bucket, t in pairs(tracked) do
		if not t.lost and at - (t.touchedAt or 0) >= grace and playersIn(bucket) == 0
			and (not bestTouch or (t.touch or 0) < bestTouch) then
			best, bestTouch = bucket, t.touch or 0
		end
	end
	if not best then return false end
	W.log('info', 'override limit reached: releasing empty bucket %d (owner %s)', best, tracked[best].owner)
	return release(best, 'reclaimed')
end

-- Runs fn(b) for a validated bucket, retries once after a reclaim, tracks the override and emits the event.
-- fn answers state, or false, reason[, partialState] (a preset that failed half-way still made an override).
local function mutate(bucket, reason, info, fn)
	local b = parseBucket(bucket)
	if b == false then return false, 'invalid_bucket' end
	local owner, generation = caller()
	info = info or {}
	info.resource = owner
	local state, why, partial = fn(b)
	if not state and why == 'too_many_environment_overrides' and b and not tracked[b] and reclaim() then
		state, why, partial = fn(b)
	end
	if b and (state or partial) then track(b, state or partial, owner, generation, info) end
	if state then emit(b, state, reason, info)
	elseif why ~= 'environment_unavailable' then
		W.log('warn', '%s refused for %s (%s): %s', reason, b and ('bucket ' .. b) or 'the shared sky', info.resource, why)
	end
	return state, why
end

-- Raw steps ---------------------------------------------------------------------------

-- One part of a time of day as a Lua integer in 0..high (a fraction is floored), else nil.
local function timePart(value, high)
	if type(value) == 'string' then value = tonumber(value) end
	value = finite(value, 0, high)
	return value and math.tointeger(math.floor(value)) or nil
end

-- hour 0..23, minute and second 0..59 (nil = 0): three integers, or nil.
local function validTime(hour, minute, second)
	if minute == nil then minute = 0 end
	if second == nil then second = 0 end
	local h, m, s = timePart(hour, 23), timePart(minute, 59), timePart(second, 59)
	if not (h and m and s) then return nil end
	return h, m, s
end

-- Applies a normalised preset (or snapshot) to bucket b: weather first, so an unknown weather changes nothing.
local function applyDefinition(p, b, transition)
	local state, reason, last
	local function step(name, ...)
		state, reason = call(name, ...)
		if state then last = state end
		return state
	end
	if p.weather and not step('setWeather', p.weather, transition or p.transition or 0, b) then return false, reason, last end
	if p.time and not step('setTime', p.time[1], p.time[2], p.time[3], b) then return false, reason, last end
	if p.rate and not step('setTimeRate', p.rate, b) then return false, reason, last end
	if p.timeFrozen ~= nil and not step('setTimeFrozen', p.timeFrozen, b) then return false, reason, last end
	if p.weatherFrozen ~= nil and not step('setWeatherFrozen', p.weatherFrozen, b) then return false, reason, last end
	return last or call('getState', b)
end

-- Exports -----------------------------------------------------------------------------

local function GetState(bucket)
	local b = parseBucket(bucket)
	if b == false then return false, 'invalid_bucket' end
	return call('getState', b)
end

local function SetTime(hour, minute, second, bucket)
	local h, m, s = validTime(hour, minute, second)
	if not h then return false, 'invalid_time' end
	return mutate(bucket, 'time', nil, function(b) return call('setTime', h, m, s, b) end)
end

local function FreezeTime(frozen, bucket)
	return mutate(bucket, 'time_frozen', nil, function(b) return call('setTimeFrozen', frozen == true, b) end)
end

local function SetTimeRate(rate, bucket)
	rate = tonumber(rate)
	if not rate or rate ~= rate or rate < 0 or rate > 120 then return false, 'invalid_rate' end
	return mutate(bucket, 'time_rate', nil, function(b) return call('setTimeRate', rate, b) end)
end

local function SetWeather(preset, transitionSeconds, bucket)
	if type(preset) ~= 'string' or preset == '' or #preset > 64 then return false, 'invalid_weather' end
	local transition = tonumber(transitionSeconds) or 0
	if transition ~= transition then transition = 0 end
	transition = math.max(0, math.min(300, transition))
	return mutate(bucket, 'weather', nil, function(b) return call('setWeather', preset, transition, b) end)
end

local function FreezeWeather(frozen, bucket)
	return mutate(bucket, 'weather_frozen', nil, function(b) return call('setWeatherFrozen', frozen == true, b) end)
end

-- Retires a bucket's override: it follows the shared sky again.
local function Reset(bucket)
	if bucket == nil then return false, 'invalid_bucket' end
	local b, shared = parseBucket(bucket)
	if shared then return false, 'shared_bucket' end
	if not b then return false, 'invalid_bucket' end
	local t = forget(b)
	local state, reason = call('clearBucket', b)
	if state then
		emit(b, state, 'reset', { resource = (caller()), preset = t and t.preset, source = t and t.source })
	end
	return state, reason
end

-- Applies a named preset (Config.presets or RegisterPreset) to a bucket (nil = the shared sky).
local function ApplyPreset(name, bucket)
	local p = W.getPreset(name)
	if not p then return false, 'unknown_preset' end
	return mutate(bucket, 'preset', { preset = name }, function(b) return applyDefinition(p, b) end)
end

-- The id of a connected player as a Lua integer, else nil.
local function validPlayer(source)
	local src = whole(source, 1, MAX_PLAYER)
	if not src then return nil end
	local ok, name = pcall(GetPlayerName, src)
	if not ok or not name then return nil end
	return src
end

-- The routing bucket a player stands in. The platform's answer is checked like any other bucket.
local function playerBucket(source)
	local src = whole(source, 1, MAX_PLAYER)
	if not src then return nil, 'bucket_unavailable' end
	local ok, bucket = pcall(Open77.routingBuckets.getPlayer, src)
	bucket = ok and whole(bucket, 0, MAX_BUCKET) or nil
	if not bucket then return nil, 'bucket_unavailable' end
	return bucket
end

-- The sky of the player's own (private) routing bucket: only the players in that bucket see it.
local function ApplyToPlayer(source, name)
	local src = validPlayer(source)
	if not src then return false, 'invalid_player' end
	if not W.getPreset(name) then return false, 'unknown_preset' end
	local bucket, reason = playerBucket(src)
	if not bucket then return false, reason end
	local shared = bucket == SHARED
	if shared and not Config.allowSharedBucket then return false, 'shared_bucket' end
	-- a sky he had in another bucket he has since left goes back (one sky per player)
	local previous = playerSky[src]
	if previous and previous ~= bucket and playersIn(previous, src) == 0 then release(previous, 'player_left') end
	local p = W.getPreset(name)
	local state, why = mutate(bucket, 'preset', { preset = name, source = not shared and src or nil },
		function(b) return applyDefinition(p, b) end)
	if state and not shared then playerSky[src] = bucket end
	return state, why
end

-- Gives the player's private sky back to the shared sky: the bucket ApplyToPlayer gave a sky to (even if he
-- has moved since), else his current bucket.
local function ClearPlayer(source)
	local src = validPlayer(source)
	if not src then return false, 'invalid_player' end
	local bucket = playerSky[src]
	if not bucket then
		local reason
		bucket, reason = playerBucket(src)
		if not bucket then return false, reason end
	end
	playerSky[src] = nil
	return Reset(bucket)
end

-- Presets and catalogue -----------------------------------------------------------------

local function RegisterPreset(name, definition)
	local owner, generation = caller()
	return W.registerPreset(owner, name, definition, generation)
end

local function UnregisterPreset(name)
	return W.unregisterPreset((caller()), name)
end

local function GetPreset(name) return W.presetCopy(name) end
local function GetPresets() return W.presetList() end
local function GetWeathers() return W.weathers() end
local function ResolveWeather(name) return W.resolveWeather(name) end

-- The overrides made through opx_weather, ascending by bucket.
local function GetOverrides()
	local out = {}
	for bucket, t in pairs(tracked) do
		out[#out + 1] = {
			bucket = bucket, resource = t.owner, preset = t.preset, source = t.source,
			players = playersIn(bucket), lost = t.lost == true,
		}
	end
	table.sort(out, function(a, b) return a.bucket < b.bucket end)
	return out
end

-- Contract (docs/ARCHITECTURE.md › Replacing a resource › weather).
exports('GetState', GetState)
exports('SetTime', SetTime)
exports('FreezeTime', FreezeTime)
exports('SetTimeRate', SetTimeRate)
exports('SetWeather', SetWeather)
exports('FreezeWeather', FreezeWeather)
exports('Reset', Reset)
exports('ApplyPreset', ApplyPreset)
exports('ApplyToPlayer', ApplyToPlayer)
exports('ClearPlayer', ClearPlayer)
-- Additions (optional for a replacement provider).
exports('RegisterPreset', RegisterPreset)
exports('UnregisterPreset', UnregisterPreset)
exports('GetPreset', GetPreset)
exports('GetPresets', GetPresets)
exports('GetWeathers', GetWeathers)
exports('ResolveWeather', ResolveWeather)
exports('GetOverrides', GetOverrides)

-- Lifecycle -------------------------------------------------------------------------------

-- At most 64 overrides exist at once: a player who leaves gives his private sky back.
AddEventHandler('playerDropped', function()
	local src = whole(source, 1, MAX_PLAYER)
	if not src then return end
	local bucket = playerSky[src]
	playerSky[src] = nil
	if bucket and tracked[bucket] and playersIn(bucket, src) == 0 then release(bucket, 'player_dropped') end
end)

-- A player sky follows its player: once he leaves the bucket and it is empty, the override goes back.
AddEventHandler('onPlayerBucketChange', function(playerId)
	if not Config.releasePlayerSkyOnLeave then return end
	local src = whole(playerId, 1, MAX_PLAYER)
	local bucket = src and playerSky[src]
	if not bucket then return end
	local current = playerBucket(src)
	if not current or current == bucket then return end -- unknown is not "left": the next change decides
	playerSky[src] = nil
	if tracked[bucket] and playersIn(bucket) == 0 then release(bucket, 'player_left') end
end)

-- Keeps the last known state of our overrides (random draws, direct Open77.environment calls) and notices an
-- override of ours retired by someone else.
AddEventHandler('onEnvironmentChanged', function(state)
	if type(state) ~= 'table' then return end
	local revision = tonumber(state.revision) or 0
	if state.bucket ~= nil then
		local t = tracked[state.bucket]
		if t and state.authorityEpoch == t.epoch and revision >= (t.revision or 0) then remember(t, state) end
		return
	end
	if type(state.buckets) ~= 'table' then return end
	local present = {}
	for _, bucket in ipairs(state.buckets) do present[bucket] = true end
	local gone = {}
	for bucket, t in pairs(tracked) do
		if not present[bucket] and not t.lost and state.authorityEpoch == t.epoch and revision > (t.revision or 0) then
			gone[#gone + 1] = bucket
		end
	end
	for _, bucket in ipairs(gone) do
		local t = forget(bucket)
		emit(bucket, state, 'cleared_externally', { resource = t.owner, preset = t.preset, source = t.source })
	end
end)

-- Looks at each of our overrides once the authority answers again. A reload carried it: nothing to do. A
-- restart came back without it: it is applied again from its last known state
-- (Config.restoreAfterAuthorityRestart), or forgotten.
local function restoreAll()
	local buckets = {}
	for bucket in pairs(tracked) do buckets[#buckets + 1] = bucket end
	table.sort(buckets)
	local restored = 0
	for _, bucket in ipairs(buckets) do
		local t = tracked[bucket]
		if t then
			local alive, why = call('getState', bucket)
			if alive then
				local lost = t.lost
				remember(t, alive)
				if lost then emit(bucket, alive, 'restored', { resource = t.owner, preset = t.preset, source = t.source }) end
			elseif why == 'environment_unavailable' then
				break -- gone again: its next start brings us back here
			elseif Config.restoreAfterAuthorityRestart and t.snap and type(t.snap.weather) == 'string' then
				-- only whole, finite numbers in range go back to the platform
				local s = t.snap
				local rate = finite(s.rate, 0, 120) or 8
				local seconds = finite(s.seconds, 0, 86400) or 0
				if not s.timeFrozen then seconds = seconds + (finite(now() - s.at, 0, 1e9) or 0) * rate end
				seconds = math.tointeger(math.floor(seconds % 86400)) or 0
				local def = {
					weather = s.weather, rate = rate,
					time = { seconds // 3600, seconds % 3600 // 60, seconds % 60 },
					timeFrozen = s.timeFrozen == true, weatherFrozen = s.weatherFrozen == true,
				}
				local state, reason, partial = applyDefinition(def, bucket, 0)
				if state or partial then
					remember(t, state or partial)
					t.touchedAt = now()
				end
				if state then
					restored = restored + 1
					emit(bucket, state, 'restored', { resource = t.owner, preset = t.preset, source = t.source })
				else
					W.log('warn', 'could not restore the sky of bucket %d: %s', bucket, tostring(reason))
					if not partial then forget(bucket) end
				end
			else
				forget(bucket)
			end
		end
	end
	persist()
	if restored > 0 then W.log('info', 'restored %d bucket sky(s) after %s restarted', restored, AUTHORITY) end
end

-- Waits until the authority answers, then settles what the previous VM left and what it kept of ours.
-- One thread at a time, and none when there is nothing to settle.
local settling = false
local function settleSoon()
	if settling or (next(tracked) == nil and not (leftovers and next(leftovers))) then return end
	settling = true
	CreateThread(function()
		Wait(500)
		for _ = 1, 10 do
			if call('getState') then
				settling = false
				clearLeftovers()
				return restoreAll()
			end
			Wait(1000)
		end
		settling = false
		W.log('warn', '%s does not answer: the bucket skies could not be checked', AUTHORITY)
	end)
end

-- A resource stopped, restarted or reloaded. What its previous VM registered goes; what the VM running now
-- registered stays (on a reload the new VM runs its start code before the others hear about the stop, so
-- only the generation tells the two apart).
local function sweepOwner(name)
	W.dropPresets(name)
	local owned = {}
	for bucket, t in pairs(tracked) do
		if t.owner == name and not W.ownerAlive(name, t.generation) then owned[#owned + 1] = bucket end
	end
	for _, bucket in ipairs(owned) do release(bucket, 'owner_stopped') end
end

AddEventHandler('onResourceStart', function(name)
	if name == RESOURCE then
		-- Our own start: settle what the previous VM could not (empty skies cleared, occupied ones kept). On a
		-- full start this runs before the other resources apply their skies; on a reload of opx_weather they
		-- are not restarted and apply nothing again.
		if not clearLeftovers() then settleSoon() end
	elseif name == AUTHORITY then
		settleSoon()
	else
		sweepOwner(name)
	end
end)

AddEventHandler('onResourceStop', function(name)
	if name == RESOURCE then
		-- Nothing can be released from here: a stopping VM cannot call the authority nor publish an event
		-- (both answer resource_stopping). The buckets are in Open77.kvp; our next start settles them.
		return
	end
	if name == AUTHORITY then
		for bucket, t in pairs(tracked) do
			if not t.lost then
				t.lost = true
				emit(bucket, nil, 'authority_stopped', { resource = t.owner, preset = t.preset, source = t.source })
			end
		end
		-- This notice also follows a reload (which keeps every override), and it can arrive when the authority
		-- is already back: then only the authority can tell what is left.
		local ok, state = pcall(GetResourceState, AUTHORITY)
		if ok and state == 'running' then return settleSoon() end
		-- Really down: its overrides died with it. Our records stay, to apply them again when it is back.
		if not Config.restoreAfterAuthorityRestart then
			tracked, playerSky = {}, {}
			persist()
		end
		return
	end
	sweepOwner(name)
end)

if type(env) ~= 'table' then
	W.log('warn', 'Open77.environment is missing: every call answers environment_unavailable (is %s running?)', AUTHORITY)
end
