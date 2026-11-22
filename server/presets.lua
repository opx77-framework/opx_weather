-- opx_weather: weather catalogue (mirror of open77_weather) and the preset registry.
-- Presets are data declared by the resource that owns them: Config.presets belong to opx_weather, any other
-- resource adds its own with RegisterPreset and they leave with the VM that registered them.

Weather = Weather or {}
local W = Weather
local RESOURCE = GetCurrentResourceName()
local NAME_PATTERN = '^[a-z][a-z0-9_]+$' -- same rule as opx_core jobs: 2..32 chars, lowercase
-- GetPresets answers every preset in one export result (the platform refuses a result over 4,096 values or
-- 48 KiB): 128 presets stay far below both.
local MAX_PRESETS = 128

function W.log(level, message, ...)
	if select('#', ...) > 0 then message = message:format(...) end
	print(('[opx_weather] %s: %s'):format(level, message))
end

-- A whole number in low..high as a Lua integer (a numeric string or a float such as 42.0 is converted), else
-- nil. The platform natives that read a player id or a routing bucket ABORT THE SERVER PROCESS on a negative,
-- fractional or oversized value, and pcall does not catch it: ids and buckets go through here first.
function W.whole(value, low, high)
	if type(value) == 'string' then value = tonumber(value) end
	if type(value) ~= 'number' then return nil end
	local n = math.tointeger(value) -- nil for a fraction, NaN, an infinity
	if not n or n < low or n > high then return nil end
	return n
end

-- Ownership --------------------------------------------------------------------
-- What another resource registers belongs to the VM that registered it: its name AND its generation (the
-- platform changes the generation on every restart and reload). On a reload the new VM runs its start code
-- before the others are told that the old one stopped, so a registry that purges on the name alone erases
-- what was just registered again.

-- Generation of the VM a resource runs now: 0 when it is not running, nil when the platform cannot tell.
function W.generationOf(name)
	local api = Open77.resource
	if type(api) ~= 'table' or type(api.generation) ~= 'function' then return nil end
	local ok, generation = pcall(api.generation, name)
	if ok and type(generation) == 'number' then return generation end
	return nil
end

-- True while the VM that registered something (resource name, generation) is the one still running.
-- Without a generation on either side only the resource state decides.
function W.ownerAlive(owner, generation)
	if owner == RESOURCE then return true end
	local ok, state = pcall(GetResourceState, owner)
	if not ok or (state ~= 'running' and state ~= 'starting') then return false end
	local current = W.generationOf(owner)
	return generation == nil or current == nil or current == generation
end

-- Weather catalogue --------------------------------------------------------------

local byKey = {}   -- lowercase name or REDengine preset -> catalogue entry
local catalogue = {}
for _, entry in ipairs(Config.weathers or {}) do
	if type(entry) == 'table' and type(entry.name) == 'string' then
		local item = { name = entry.name:lower(), preset = type(entry.preset) == 'string' and entry.preset or nil, aliases = {} }
		catalogue[#catalogue + 1] = item
		byKey[item.name] = item
		if item.preset then byKey[item.preset:lower()] = item end
	end
end
for alias, target in pairs(Config.weatherAliases or {}) do
	local item = type(alias) == 'string' and type(target) == 'string' and byKey[target:lower()]
	if item then
		item.aliases[#item.aliases + 1] = alias:lower()
		byKey[alias:lower()] = byKey[alias:lower()] or item
	end
end
for _, item in ipairs(catalogue) do table.sort(item.aliases) end

-- Canonical weather name for a name, alias or REDengine preset, or nil.
function W.resolveWeather(name)
	if type(name) ~= 'string' then return nil end
	local item = byKey[name:lower()]
	return item and item.name or nil
end

function W.weathers()
	local out = {}
	for i, item in ipairs(catalogue) do
		local aliases = {}
		for j, alias in ipairs(item.aliases) do aliases[j] = alias end
		out[i] = { name = item.name, preset = item.preset, aliases = aliases }
	end
	return out
end

-- Presets ------------------------------------------------------------------------

local presets = {}     -- name -> normalised definition (+ name, resource)
local generations = {} -- name -> generation of the VM that registered it (nil: opx_weather itself, or unknown)
local count = 0

local int = W.whole

local function optionalBool(value)
	if value == nil then return true, nil end
	if type(value) ~= 'boolean' then return false end
	return true, value
end

-- Validates and normalises a preset definition: the normalised copy, or nil and a reason.
function W.normalisePreset(def)
	if type(def) ~= 'table' then return nil, 'invalid_preset' end
	local out = {}
	if def.time ~= nil then
		if type(def.time) ~= 'table' then return nil, 'invalid_time' end
		local h = int(def.time[1] or def.time.hour, 0, 23)
		local m = int(def.time[2] or def.time.minute or 0, 0, 59)
		local s = int(def.time[3] or def.time.second or 0, 0, 59)
		if not h or not m or not s then return nil, 'invalid_time' end
		out.time = { h, m, s }
	end
	if def.weather ~= nil then
		out.weather = W.resolveWeather(def.weather)
		if not out.weather then return nil, 'unknown_weather' end
	end
	if def.transition ~= nil then
		local t = tonumber(def.transition)
		if not t or t ~= t or t < 0 or t > 300 then return nil, 'invalid_transition' end
		out.transition = t
	end
	if def.rate ~= nil then
		local r = tonumber(def.rate)
		if not r or r ~= r or r < 0 or r > 120 then return nil, 'invalid_rate' end
		out.rate = r
	end
	local ok, frozen = optionalBool(def.frozen)
	local okT, timeFrozen = optionalBool(def.timeFrozen)
	local okW, weatherFrozen = optionalBool(def.weatherFrozen)
	if not (ok and okT and okW) then return nil, 'invalid_preset' end
	if timeFrozen == nil then timeFrozen = frozen end
	if weatherFrozen == nil then weatherFrozen = frozen end
	out.timeFrozen, out.weatherFrozen = timeFrozen, weatherFrozen
	-- kept for readers of the old shape: true only when both are frozen
	if timeFrozen ~= nil or weatherFrozen ~= nil then out.frozen = timeFrozen == true and weatherFrozen == true end
	if not (out.time or out.weather or out.rate or timeFrozen ~= nil or weatherFrozen ~= nil) then
		return nil, 'empty_preset'
	end
	return out
end

local function copy(preset)
	local out = {}
	for k, v in pairs(preset) do out[k] = v end
	if preset.time then out.time = { preset.time[1], preset.time[2], preset.time[3] } end
	return out
end

function W.getPreset(name)
	return type(name) == 'string' and presets[name] or nil
end

function W.presetCopy(name)
	local p = W.getPreset(name)
	return p and copy(p) or nil
end

function W.presetList()
	local out = {}
	for name, p in pairs(presets) do out[name] = copy(p) end
	return out
end

-- Host-wide announcement of a registry change. Never for opx_weather's own presets: they are registered
-- while this VM loads, when the platform refuses every event (resource_preparing).
local function announce(owner, event, ...)
	if owner == RESOURCE then return end
	local ok, reason = TriggerEvent(event, ...)
	if ok == false then W.log('warn', '%s not published: %s', event, tostring(reason)) end
end

-- `generation`: the VM of `owner` that registers (nil for opx_weather itself). The same owner name always
-- replaces its own entry, whatever its generation; another resource only takes a name whose owner VM is gone.
function W.registerPreset(owner, name, def, generation)
	if type(name) ~= 'string' or #name > 32 or not name:match(NAME_PATTERN) then return false, 'invalid_name' end
	local existing = presets[name]
	if existing and existing.resource ~= owner and W.ownerAlive(existing.resource, generations[name]) then
		return false, 'preset_taken'
	end
	if not existing and count >= MAX_PRESETS then return false, 'preset_limit' end
	local preset, reason = W.normalisePreset(def)
	if not preset then return false, reason end
	preset.name, preset.resource = name, owner
	if not existing then count = count + 1 end
	presets[name], generations[name] = preset, generation
	if owner ~= RESOURCE then W.log('info', 'preset %s registered by %s', name, owner) end
	announce(owner, 'opx:weatherPresetRegistered', name, copy(preset))
	return true
end

function W.unregisterPreset(owner, name)
	local preset = type(name) == 'string' and presets[name] or nil
	if not preset then return false, 'unknown_preset' end
	if preset.resource == RESOURCE and owner ~= RESOURCE then return false, 'protected' end
	if preset.resource ~= owner then return false, 'not_owner' end
	presets[name], generations[name] = nil, nil
	count = count - 1
	announce(owner, 'opx:weatherPresetUnregistered', name)
	return true
end

-- Drops the presets of `owner` whose VM is gone (stopped, or replaced by a restart / reload). Those the VM
-- running now registered stay.
function W.dropPresets(owner)
	local names = {}
	for name, preset in pairs(presets) do
		if preset.resource == owner and not W.ownerAlive(owner, generations[name]) then names[#names + 1] = name end
	end
	for _, name in ipairs(names) do W.unregisterPreset(owner, name) end
end

-- Config.presets belong to opx_weather; a bad one is logged and skipped, never fatal.
for name, def in pairs(Config.presets or {}) do
	local ok, reason = W.registerPreset(RESOURCE, name, def)
	if not ok then W.log('warn', 'Config.presets.%s ignored: %s', tostring(name), reason) end
end
