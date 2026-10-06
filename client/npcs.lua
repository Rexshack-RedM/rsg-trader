local spawnedPeds = {}

local function fade(ped, from, to, step)
    for i = from, to, step do
        if not DoesEntityExist(ped) then return end
        SetEntityAlpha(ped, i, false)
        Wait(50)
    end
end

local function spawnPed(trader)
    local model = joaat(trader.npcmodel)
    -- lib.requestModel throws on invalid/timed-out models, which would kill the spawn loop
    if not IsModelValid(model) or not pcall(lib.requestModel, model, 5000) then
        if Config.Debug then print(('[rsg-trader] invalid model %s for trader %s'):format(trader.npcmodel, trader.traderid)) end
        return
    end

    local ped = CreatePed(model, trader.x, trader.y, trader.z - 1.0, trader.heading, false, false, false, false)
    SetModelAsNoLongerNeeded(model)
    SetRandomOutfitVariation(ped, true)
    SetEntityCanBeDamaged(ped, false)
    SetEntityInvincible(ped, true)
    FreezeEntityPosition(ped, true)
    SetBlockingOfNonTemporaryEvents(ped, true)
    SetPedCanBeTargetted(ped, false)
    SetPedFleeAttributes(ped, 0, false)

    exports.ox_target:addLocalEntity(ped, {
        {
            name = 'rsg_trader_speak',
            icon = 'fa-solid fa-comments',
            label = locale('cl_target_speak'),
            distance = 3.0,
            onSelect = function() TraderOpenMenu(trader.traderid, 'buy') end,
        },
    })

    if Config.FadeIn then
        SetEntityAlpha(ped, 0, false)
        CreateThread(function() fade(ped, 0, 255, 51) end)
    end
    return ped
end

local function despawnPed(ped)
    if not ped or not DoesEntityExist(ped) then return end
    exports.ox_target:removeLocalEntity(ped, 'rsg_trader_speak')
    if Config.FadeIn then
        CreateThread(function()
            fade(ped, 255, 0, -51)
            DeletePed(ped)
        end)
    else
        DeletePed(ped)
    end
end

-- a trader's identity: if its model or position changes, the ped is respawned
local function signature(t)
    return ('%s|%.2f|%.2f|%.2f|%.1f'):format(t.npcmodel, t.x, t.y, t.z, t.heading)
end

CreateThread(function()
    while true do
        local playerCoords = GetEntityCoords(cache.ped)
        local active = {}

        for _, t in ipairs(GetTraders()) do
            local id = t.traderid
            local sig = signature(t)
            local spawned = spawnedPeds[id]
            local inRange = #(playerCoords - vector3(t.x, t.y, t.z)) < Config.DistanceSpawn
            active[id] = true

            if spawned and (not inRange or spawned.sig ~= sig) then
                despawnPed(spawned.ped)
                spawnedPeds[id] = nil
                spawned = nil
            end
            if inRange and not spawned then
                local ped = spawnPed(t)
                if ped then spawnedPeds[id] = { ped = ped, sig = sig } end
            end
        end

        -- traders removed by an admin
        for id, spawned in pairs(spawnedPeds) do
            if not active[id] then
                despawnPed(spawned.ped)
                spawnedPeds[id] = nil
            end
        end

        Wait(1000)
    end
end)

AddEventHandler('onResourceStop', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end
    for k, spawned in pairs(spawnedPeds) do
        if DoesEntityExist(spawned.ped) then DeletePed(spawned.ped) end
        spawnedPeds[k] = nil
    end
end)
