local RSGCore = exports['rsg-core']:GetCoreObject()
lib.locale()

local blips = {}
local uiOpen = false

-- locale keys sent to the NUI
local UI_KEYS = {
    'ui_buy', 'ui_sell', 'ui_stock', 'ui_owned', 'ui_each', 'ui_total', 'ui_no_items', 'ui_no_sell_items',
    'ui_low', 'ui_sold_out', 'ui_normal', 'ui_high', 'ui_max', 'ui_cash', 'ui_close', 'ui_no_blip', 'ui_trader',
    'ui_admin_title', 'ui_admin_sub', 'ui_add_trader', 'ui_edit_trader', 'ui_name', 'ui_model', 'ui_blip',
    'ui_move_here', 'ui_pos_note', 'ui_items', 'ui_add_item', 'ui_edit_item', 'ui_item', 'ui_lowstock', 'ui_highstock',
    'ui_baseprice', 'ui_save', 'ui_cancel', 'ui_delete', 'ui_edit', 'ui_teleport', 'ui_confirm', 'ui_back',
    'ui_delete_trader_q', 'ui_delete_items_too', 'ui_delete_item_q', 'ui_no_traders', 'ui_search', 'ui_itemcount',
    'ui_search_items', 'ui_pick_item', 'ui_already_listed', 'ui_no_matches', 'ui_refine_search',
}

local function uiStrings()
    local t = {}
    for _, k in ipairs(UI_KEYS) do t[k] = locale(k) end
    return t
end

---------------------------------------------
-- traders (synced from the server via GlobalState)
---------------------------------------------
function GetTraders()
    return GlobalState.rsgTraders or {}
end

function GetTrader(traderid)
    for _, t in ipairs(GetTraders()) do
        if t.traderid == traderid then return t end
    end
end

local function refreshBlips()
    for _, blip in ipairs(blips) do RemoveBlip(blip) end
    blips = {}
    for _, t in ipairs(GetTraders()) do
        if t.showblip then
            local blip = BlipAddForCoords(1664425300, t.x, t.y, t.z)
            SetBlipSprite(blip, joaat(Config.DefaultBlip.sprite), true)
            SetBlipScale(blip, Config.DefaultBlip.scale)
            SetBlipName(blip, t.tradername)
            blips[#blips + 1] = blip
        end
    end
end

CreateThread(refreshBlips)
AddStateBagChangeHandler('rsgTraders', 'global', function()
    Wait(0)
    refreshBlips()
end)

---------------------------------------------
-- nui helpers
---------------------------------------------
local function openUI(payload)
    payload.strings = uiStrings()
    SendNUIMessage(payload)
    SetNuiFocus(true, true)
    uiOpen = true
end

local function closeUI()
    SendNUIMessage({ action = 'close' })
    SetNuiFocus(false, false)
    uiOpen = false
end

local function notify(ntype, msg, title)
    if not msg or msg == '' then return end
    lib.notify({
        title = title or locale('ui_trader'),
        description = msg,
        type = ntype == 'success' and 'success' or ntype == 'error' and 'error' or 'inform',
        duration = 5000,
    })
end

RegisterNUICallback('notify', function(data, cb)
    notify(data.type, data.msg)
    cb('ok')
end)

local function playSound(key)
    local snd = Config.Sounds and Config.Sounds.enabled and Config.Sounds[key]
    if snd then PlaySoundFrontend(snd.name, snd.set, true, 0) end
end

RegisterNUICallback('close', function(_, cb)
    if uiOpen then playSound('close') end
    SetNuiFocus(false, false)
    uiOpen = false
    cb('ok')
end)

local function ownedCounts()
    local counts = {}
    local items = RSGCore.Functions.GetPlayerData().items or {}
    for _, v in pairs(items) do
        if v and v.name then counts[v.name] = (counts[v.name] or 0) + (v.amount or 0) end
    end
    return counts
end

---------------------------------------------
-- shop
---------------------------------------------
local function openShop(traderid, mode, msg)
    local trader = GetTrader(traderid)
    if not trader then return end

    local stock = lib.callback.await('rsg-trader:server:traderdata', false, traderid) or {}
    local owned = ownedCounts()
    local items = {}
    for _, d in ipairs(stock) do
        local info = RSGCore.Shared.Items[d.item]
        if info then
            items[#items + 1] = {
                item = d.item, label = info.label, image = ('nui://%s%s'):format(Config.Image, info.image),
                stock = d.stock, lowstock = d.lowstock, highstock = d.highstock,
                buyprice = d.buyprice, sellprice = d.sellprice, owned = owned[d.item] or 0,
            }
        end
    end

    openUI({
        action = 'openShop',
        trader = { id = traderid, name = trader.tradername },
        mode = mode or 'buy',
        items = items,
        maxBuy = Config.MaxBuyAmount,
        maxSell = Config.MaxSellAmount,
        cash = (RSGCore.Functions.GetPlayerData().money or {}).cash or 0,
    })
    if msg then notify(msg.ok and 'success' or 'error', msg.msg, trader.tradername) end
end

-- used by npcs.lua
TraderOpenMenu = function(traderid, mode)
    playSound('open')
    openShop(traderid, mode)
end

local trading = false

RegisterNUICallback('trade', function(data, cb)
    cb('ok')
    if trading then return end
    local amount = tonumber(data.amount)
    if not amount or not RSGCore.Shared.Items[data.item] then return end

    trading = true
    local res = lib.callback.await(data.mode == 'buy' and 'rsg-trader:server:buy' or 'rsg-trader:server:sell', false, data.traderid, data.item, amount)
    Wait(150) -- let inventory/money state update
    trading = false

    if res then playSound(res.ok and 'success' or 'fail') end
    if uiOpen then openShop(data.traderid, data.mode, res) end
end)

---------------------------------------------
-- admin panel
---------------------------------------------
local function adminItemList()
    local list = {}
    for name, v in pairs(RSGCore.Shared.Items) do
        if type(v) == 'table' then
            list[#list + 1] = { name = name, label = v.label or name, image = v.image or (name .. '.png') }
        end
    end
    table.sort(list, function(a, b) return a.label:lower() < b.label:lower() end)
    return list
end

local function sendTraders()
    local traders = lib.callback.await('rsg-trader:server:admin:traders', false)
    SendNUIMessage({ action = 'adminTraders', traders = traders or {} })
end

RegisterNetEvent('rsg-trader:client:openAdmin', function()
    if not lib.callback.await('rsg-trader:server:admin:isAdmin', false) then return end
    local traders = lib.callback.await('rsg-trader:server:admin:traders', false) or {}
    openUI({ action = 'openAdmin', traders = traders, itemList = adminItemList(), defaultModel = Config.DefaultModel, imagePath = 'nui://' .. Config.Image })
end)

local function adminAction(name, after)
    RegisterNUICallback(name, function(data, cb)
        local res = after(data)
        cb(res or { ok = false })
    end)
end

adminAction('admin:saveTrader', function(data)
    if data.npcmodel and data.npcmodel ~= '' and not IsModelValid(joaat(data.npcmodel)) then
        return { ok = false, msg = locale('sv_invalid_model') }
    end
    local res = lib.callback.await('rsg-trader:server:admin:saveTrader', false, data)
    if res and res.ok then sendTraders() end
    return res
end)

adminAction('admin:deleteTrader', function(data)
    local res = lib.callback.await('rsg-trader:server:admin:deleteTrader', false, data.traderid, data.removeItems)
    if res and res.ok then sendTraders() end
    return res
end)

adminAction('admin:items', function(data)
    return { ok = true, items = lib.callback.await('rsg-trader:server:admin:items', false, data.traderid) or {} }
end)

adminAction('admin:saveItem', function(data)
    return lib.callback.await('rsg-trader:server:admin:saveItem', false, data)
end)

adminAction('admin:deleteItem', function(data)
    return lib.callback.await('rsg-trader:server:admin:deleteItem', false, data.traderid, data.item)
end)

adminAction('admin:refresh', function()
    sendTraders()
    return { ok = true }
end)

adminAction('admin:teleport', function(data)
    local t = GetTrader(data.traderid)
    if not t then return { ok = false } end
    closeUI()
    DoScreenFadeOut(300)
    Wait(300)
    local h = math.rad(t.heading)
    SetEntityCoords(cache.ped, t.x - math.sin(h) * 1.5, t.y + math.cos(h) * 1.5, t.z, false, false, false, false)
    SetEntityHeading(cache.ped, (t.heading + 180.0) % 360.0)
    Wait(300)
    DoScreenFadeIn(300)
    return { ok = true }
end)

---------------------------------------------
-- cleanup
---------------------------------------------
AddEventHandler('onResourceStop', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end
    for _, blip in ipairs(blips) do RemoveBlip(blip) end
    if uiOpen then SetNuiFocus(false, false) end
end)
