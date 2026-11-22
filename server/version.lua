-- Update check: compares the version of this resource's manifest with the one published on GitHub (branch
-- main) and prints one line in the server console when a newer one is out. Config.versionCheck turns it off.
-- Needs outbound HTTP in server.jsonc: "http": { "enabled": true, "allowedHosts": ["raw.githubusercontent.com"] }.
local REPOSITORY = 'opx77-framework/opx_weather'
local MANIFEST_URL = ('https://raw.githubusercontent.com/%s/main/open77.lua'):format(REPOSITORY)

-- '1.2.0' -> { 1, 2, 0 }; nil for anything else.
local function parseVersion(text)
	local major, minor, patch = tostring(text or ''):match('^%s*(%d+)%.(%d+)%.(%d+)')
	if not major then return nil end
	return { tonumber(major), tonumber(minor), tonumber(patch) }
end

local function isNewer(remote, current)
	for i = 1, 3 do
		if remote[i] ~= current[i] then return remote[i] > current[i] end
	end
	return false
end

CreateThread(function()
	if Config.versionCheck == false then return end
	Wait(5000) -- after the start-up lines, so the notice is not buried

	local resource = GetCurrentResourceName()
	local currentText = Open77.resource.metadata(resource, 'version')
	local current = parseVersion(currentText)
	if not current then return end

	-- A refused request (HTTP off, host not allowed) still calls back with status 0 and the reason.
	Open77.http.request(MANIFEST_URL, function(status, body, _, err)
		if status ~= 200 then
			return Open77.log.debug(('update check skipped: %s'):format(err or ('HTTP %d'):format(status)))
		end

		local remoteText = ('\n' .. body):match('\nversion%s+"([^"]+)"')
		local remote = parseVersion(remoteText)
		if not remote then
			return Open77.log.debug('update check skipped: no version in the published manifest')
		end

		if isNewer(remote, current) then
			print(('[%s] update available: %s -> %s, https://github.com/%s'):format(resource, currentText, remoteText, REPOSITORY))
		end
	end, 'GET')
end)
