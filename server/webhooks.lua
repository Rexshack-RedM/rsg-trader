---------------------------------------------
-- discord webhook system
-- usage (server): Webhook.Send(event, src, title, fields, description)
-- export (other resources): exports['rsg-trader']:SendWebhook(event, src, title, fields, description)
---------------------------------------------
local RSGCore = exports['rsg-core']:GetCoreObject()
local cfg = WebhookConfig
lib.locale()

Webhook = {}

local queues = {}      -- url -> { embeds..., pings = set }
local blockedUntil = {} -- url -> GetGameTimer() time when rate limit ends
local throttle = {}    -- src:event -> last time

local MAX_QUEUE = 100   -- per url, oldest dropped beyond this

local function trunc(s, n)
    s = tostring(s or '')
    return #s > n and s:sub(1, n - 3) .. '...' or s
end

local function validUrl(url)
    if type(url) ~= 'string' then return false end
    return url:match('^https://[%w%.]*discord%.com/api/webhooks/') ~= nil
        or url:match('^https://[%w%.]*discordapp%.com/api/webhooks/') ~= nil
end

local function identifiers(src)
    local ids = {}
    for _, id in ipairs(GetPlayerIdentifiers(src) or {}) do
        local kind, value = id:match('^(%w+):(.+)$')
        if kind then ids[kind] = value end
    end
    return ids
end

--- player block shown in every player-related embed
local function playerField(src)
    if not src or src <= 0 then return { name = locale('wh_player'), value = locale('wh_console'), inline = false } end
    local lines = { ('**%s** (%d)'):format(trunc(GetPlayerName(src) or 'unknown', 64), src) }
    local Player = RSGCore.Functions.GetPlayer(src)
    if Player then
        local ci = Player.PlayerData.charinfo or {}
        lines[#lines + 1] = locale('wh_character', ci.firstname or '?', ci.lastname or '?')
        lines[#lines + 1] = locale('wh_citizenid', Player.PlayerData.citizenid or '?')
    end
    if cfg.ShowIdentifiers then
        local ids = identifiers(src)
        if ids.discord then lines[#lines + 1] = locale('wh_discord', ids.discord) end
        if ids.license then lines[#lines + 1] = locale('wh_license', ids.license) end
        if ids.steam then lines[#lines + 1] = locale('wh_steam', ids.steam) end
    end
    return { name = locale('wh_player'), value = trunc(table.concat(lines, '\n'), 1024), inline = false }
end

local function enqueue(url, embed, ping)
    local q = queues[url]
    if not q then q = { embeds = {}, pings = {} }; queues[url] = q end
    if #q.embeds >= MAX_QUEUE then table.remove(q.embeds, 1) end
    q.embeds[#q.embeds + 1] = embed
    if ping and ping ~= '' then q.pings[ping] = true end
end

--- queue an embed for an event defined in WebhookConfig.Events
function Webhook.Send(event, src, title, fields, description, ping)
    if not cfg.Enabled then return end
    local ev = cfg.Events[event]
    if not ev or ev.enabled == false then return end
    local url = cfg.Channels[ev.channel]
    if not validUrl(url) then return end

    local list = {}
    if src then list[1] = playerField(src) end
    for _, f in ipairs(fields or {}) do
        if #list >= 25 then break end
        local value = f.value
        if value == nil or value == '' then value = '-' end
        list[#list + 1] = { name = trunc(f.name, 256), value = trunc(value, 1024), inline = f.inline ~= false }
    end

    enqueue(url, {
        title = trunc(title, 256),
        description = description and trunc(description, 4096) or nil,
        color = ev.color or 9807270,
        fields = list,
        author = cfg.ServerName ~= '' and { name = trunc(cfg.ServerName, 256) } or nil,
        footer = { text = trunc(cfg.Footer, 2048) },
        timestamp = os.date('!%Y-%m-%dT%H:%M:%SZ'),
    }, ping)
end

--- security log, throttled per player/event
function Webhook.Suspicious(src, reason, details)
    local key = ('%s:%s'):format(src, reason)
    local now = GetGameTimer()
    if throttle[key] and now - throttle[key] < cfg.SecurityThrottle then return end
    throttle[key] = now
    Webhook.Send('suspicious', src, locale('wh_title_suspicious'), {
        { name = locale('wh_reason'), value = reason, inline = false },
        -- details can contain client-sent strings: strip markdown/mention characters
        { name = locale('wh_details'), value = details and ('```%s```'):format(tostring(details):gsub('[`@]', '')) or '-', inline = false },
    }, nil, cfg.SecurityPing)
end

exports('SendWebhook', Webhook.Send)

---------------------------------------------
-- sender: batches up to 10 embeds per request and respects discord rate limits
---------------------------------------------
local function post(url, embeds, content)
    local payload = json.encode({
        username = cfg.BotName,
        avatar_url = cfg.Avatar ~= '' and cfg.Avatar or nil,
        content = content,
        embeds = embeds,
        allowed_mentions = { parse = { 'everyone', 'roles' } },
    })
    PerformHttpRequest(url, function(status, body, headers)
        if status == 429 then
            local ok, data = pcall(json.decode, body or '')
            local retry = (ok and data and tonumber(data.retry_after)) or 5
            blockedUntil[url] = GetGameTimer() + math.ceil(retry * 1000) + 250
            -- put the embeds back at the front of the queue
            local q = queues[url] or { embeds = {}, pings = {} }
            queues[url] = q
            for i = #embeds, 1, -1 do table.insert(q.embeds, 1, embeds[i]) end
        elseif status < 200 or status >= 300 then
            print(('[rsg-trader] ^1webhook failed (HTTP %s)^7 %s'):format(status, trunc(body, 200)))
            if status == 401 or status == 404 then
                print('[rsg-trader] ^1webhook url is invalid or was deleted - check server/webhook_config.lua^7')
            end
        end
    end, 'POST', payload, { ['Content-Type'] = 'application/json' })
end

CreateThread(function()
    while true do
        Wait(cfg.FlushInterval)
        local now = GetGameTimer()
        for url, q in pairs(queues) do
            if #q.embeds > 0 and (not blockedUntil[url] or now >= blockedUntil[url]) then
                local batch = {}
                for i = 1, math.min(10, #q.embeds) do batch[i] = table.remove(q.embeds, 1) end
                local pings = {}
                for p in pairs(q.pings) do pings[#pings + 1] = p end
                q.pings = {}
                post(url, batch, #pings > 0 and table.concat(pings, ' ') or nil)
            end
        end
    end
end)

AddEventHandler('playerDropped', function()
    local prefix = tostring(source) .. ':'
    for k in pairs(throttle) do
        if k:sub(1, #prefix) == prefix then throttle[k] = nil end
    end
end)

---------------------------------------------
-- startup check + test command
---------------------------------------------
CreateThread(function()
    if not cfg.Enabled then return end
    local count = 0
    for name, url in pairs(cfg.Channels) do
        if url ~= '' then
            if validUrl(url) then count = count + 1
            else print(('[rsg-trader] ^3webhook channel "%s" has an invalid url^7'):format(name)) end
        end
    end
    if count == 0 then print('[rsg-trader] ^3webhooks enabled but no channel urls set (server/webhook_config.lua)^7') end
end)

RSGCore.Commands.Add('traderwebhooktest', locale('sv_cmd_webhooktest'), {}, false, function(source)
    for event in pairs({ buy = true, trader_created = true, suspicious = true }) do
        Webhook.Send(event, source, locale('wh_title_test'), { { name = locale('wh_event'), value = event } }, locale('wh_test_desc'))
    end
    TriggerClientEvent('ox_lib:notify', source, { title = locale('ui_trader'), description = locale('wh_test_queued'), type = 'inform', duration = 5000 })
end, 'admin')
