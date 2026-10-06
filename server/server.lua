local RSGCore = exports['rsg-core']:GetCoreObject()
lib.locale()

local cooldowns = {}
local Traders = {} -- traderid -> trader row (loaded from rsg_trader_npcs)

---------------------------------------------
-- trader npcs (database)
---------------------------------------------
local function syncTraders()
    local list = {}
    for _, t in pairs(Traders) do
        list[#list + 1] = t
    end
    GlobalState.rsgTraders = list
end

local function loadTraders()
    local rows = MySQL.query.await('SELECT * FROM rsg_trader_npcs') or {}
    Traders = {}
    for _, r in ipairs(rows) do
        r.showblip = r.showblip == 1 or r.showblip == true
        Traders[r.traderid] = r
    end
    syncTraders()
    print(('[%s] ^2Loaded %d traders^7'):format(GetCurrentResourceName(), #rows))
end

AddEventHandler('rsg-trader:server:databaseReady', loadTraders)
if not Config.AutoDatabase then
    MySQL.ready(loadTraders)
end

local function makeTraderId(name)
    local base = name:lower():gsub('[^%w]', ''):sub(1, 40)
    if base == '' then base = 'trader' end
    local id, n = base, 1
    while Traders[id] do
        n = n + 1
        id = base .. n
    end
    return id
end

---------------------------------------------
-- helpers
---------------------------------------------
local function copyTable(t)
    local c = {}
    for k, v in pairs(t) do c[k] = v end
    return c
end

local function result(ok, msg) return { ok = ok, msg = msg } end

local round2 = Config.Round2

local function isAdmin(src)
    return RSGCore.Functions.GetPlayer(src) ~= nil and RSGCore.Functions.HasPermission(src, 'admin')
end

local function isNearTrader(src, trader)
    local ped = GetPlayerPed(src)
    if ped == 0 then return false end
    return #(GetEntityCoords(ped) - vector3(trader.x, trader.y, trader.z)) <= Config.InteractDistance
end

local function onCooldown(src)
    local now = GetGameTimer()
    if cooldowns[src] and now - cooldowns[src] < Config.Cooldown then return true end
    cooldowns[src] = now
    return false
end

local function toInt(v, min, max)
    v = tonumber(v)
    if not v or v ~= v then return nil end
    v = math.floor(v)
    if (min and v < min) or (max and v > max) then return nil end
    return v
end

local function trim(s)
    return type(s) == 'string' and s:gsub('^%s+', ''):gsub('%s+$', '') or nil
end

-- discord webhook (server/webhooks.lua) + optional rsg-log
local function log(event, src, title, fields, msg)
    Webhook.Send(event, src, title, fields)
    if WebhookConfig.UseRsgLog then
        TriggerEvent('rsg-log:server:CreateLog', 'rsgtrader', 'RSG Trader', 'default', msg, false)
    end
end

local function traderLabel(traderid)
    local t = Traders[traderid]
    return t and ('%s (`%s`)'):format(t.tradername, traderid) or ('`%s`'):format(tostring(traderid))
end

local function money(n) return ('$%.2f'):format(n) end

local function adminDenied(src, action)
    Webhook.Suspicious(src, locale('wh_reason_no_admin'), action)
end

-- shared validation for buy/sell; returns Player, trader, row, amount, itemData or nil + message
local function validateTrade(src, traderid, item, amount, max)
    local Player = RSGCore.Functions.GetPlayer(src)
    if not Player then return end
    if type(traderid) ~= 'string' or type(item) ~= 'string' then
        Webhook.Suspicious(src, locale('wh_reason_malformed'), ('traderid=%s item=%s'):format(type(traderid), type(item)))
        return
    end
    local trader = Traders[traderid]
    local itemData = RSGCore.Shared.Items[item]
    local qty = toInt(amount, 1, max)
    if not trader or not itemData or not qty then
        Webhook.Suspicious(src, locale('wh_reason_invalid'), ('trader=%s item=%s amount=%s (max %s)'):format(traderid, item, tostring(amount), max))
        return nil, locale('sv_invalid_trade')
    end
    amount = qty
    if not isNearTrader(src, trader) then
        local c = GetEntityCoords(GetPlayerPed(src))
        Webhook.Suspicious(src, locale('wh_reason_too_far'), ('trader=%s at %.1f, %.1f, %.1f | player at %.1f, %.1f, %.1f'):format(
            traderid, trader.x, trader.y, trader.z, c.x, c.y, c.z))
        return nil, locale('sv_too_far')
    end
    if onCooldown(src) then return nil, locale('sv_cooldown') end
    local row = MySQL.single.await('SELECT * FROM rsg_trader WHERE traderid = ? AND item = ?', { traderid, item })
    if not row then return nil, locale('sv_invalid_trade') end
    return Player, trader, row, amount, itemData
end

---------------------------------------------
-- shop: trader stock with server-calculated prices
---------------------------------------------
lib.callback.register('rsg-trader:server:traderdata', function(source, traderid)
    if not Traders[traderid] then return {} end
    local rows = MySQL.query.await('SELECT item, stock, lowstock, highstock, baseprice FROM rsg_trader WHERE traderid = ? ORDER BY item', { traderid }) or {}
    local list = {}
    for _, r in ipairs(rows) do
        if RSGCore.Shared.Items[r.item] then
            r.buyprice  = Config.GetBuyPrice(r.stock, r.lowstock, r.highstock, r.baseprice)
            r.sellprice = Config.GetSellPrice(r.stock, r.lowstock, r.highstock, r.baseprice)
            list[#list + 1] = r
        end
    end
    return list
end)

---------------------------------------------
-- shop: player buys from the trader
---------------------------------------------
lib.callback.register('rsg-trader:server:buy', function(source, traderid, item, amount)
    local src = source
    local Player, trader, row, qty, itemData = validateTrade(src, traderid, item, amount, Config.MaxBuyAmount)
    if not Player then return result(false, trader) end

    if row.stock < qty then return result(false, locale('sv_not_enough_stock', row.stock)) end

    local total = round2(Config.GetBuyPrice(row.stock, row.lowstock, row.highstock, row.baseprice) * qty)
    if Player.Functions.GetMoney('cash') < total then return result(false, locale('sv_not_enough_money')) end
    if not exports['rsg-inventory']:CanAddItem(src, item, qty) then return result(false, locale('sv_inventory_full')) end

    -- atomic stock reservation (prevents two players buying the same stock)
    local affected = MySQL.update.await('UPDATE rsg_trader SET stock = stock - ? WHERE traderid = ? AND item = ? AND stock >= ?', { qty, traderid, item, qty })
    if not affected or affected < 1 then return result(false, locale('sv_stock_changed')) end

    if not Player.Functions.RemoveMoney('cash', total, 'rsg-trader-buy') then
        MySQL.update('UPDATE rsg_trader SET stock = stock + ? WHERE traderid = ? AND item = ?', { qty, traderid, item })
        return result(false, locale('sv_not_enough_money'))
    end

    if not exports['rsg-inventory']:AddItem(src, item, qty, nil, nil, 'rsg-trader-buy') then
        -- refund if the inventory rejected the item after payment
        Player.Functions.AddMoney('cash', total, 'rsg-trader-refund')
        MySQL.update('UPDATE rsg_trader SET stock = stock + ? WHERE traderid = ? AND item = ?', { qty, traderid, item })
        return result(false, locale('sv_inventory_full'))
    end
    TriggerClientEvent('rsg-inventory:client:ItemBox', src, itemData, 'add', qty)
    log('buy', src, locale('wh_title_buy'), {
        { name = locale('wh_trader'), value = traderLabel(traderid) },
        { name = locale('wh_item'), value = ('%dx %s (`%s`)'):format(qty, itemData.label, item) },
        { name = locale('wh_total'), value = money(total) },
        { name = locale('wh_stock_left'), value = tostring(row.stock - qty) },
    }, ('%s bought %sx %s from %s for %s'):format(GetPlayerName(src), qty, itemData.label, traderid, money(total)))
    if WebhookConfig.LargeTradeAmount > 0 and total >= WebhookConfig.LargeTradeAmount then
        Webhook.Send('buy', src, locale('wh_title_large_buy'), { { name = locale('wh_total'), value = money(total) } }, nil, WebhookConfig.LargeTradePing)
    end
    return result(true, locale('sv_bought', qty, itemData.label, ('%.2f'):format(total)))
end)

---------------------------------------------
-- shop: player sells to the trader
---------------------------------------------
lib.callback.register('rsg-trader:server:sell', function(source, traderid, item, amount)
    local src = source
    local Player, trader, row, qty, itemData = validateTrade(src, traderid, item, amount, Config.MaxSellAmount)
    if not Player then return result(false, trader) end

    local total = round2(Config.GetSellPrice(row.stock, row.lowstock, row.highstock, row.baseprice) * qty)
    if not exports['rsg-inventory']:RemoveItem(src, item, qty, nil, 'rsg-trader-sell') then
        return result(false, locale('sv_not_enough_items'))
    end

    Player.Functions.AddMoney('cash', total, 'rsg-trader-sell')
    MySQL.update.await('UPDATE rsg_trader SET stock = stock + ? WHERE traderid = ? AND item = ?', { qty, traderid, item })
    TriggerClientEvent('rsg-inventory:client:ItemBox', src, itemData, 'remove', qty)
    log('sell', src, locale('wh_title_sell'), {
        { name = locale('wh_trader'), value = traderLabel(traderid) },
        { name = locale('wh_item'), value = ('%dx %s (`%s`)'):format(qty, itemData.label, item) },
        { name = locale('wh_total'), value = money(total) },
        { name = locale('wh_stock_now'), value = tostring(row.stock + qty) },
    }, ('%s sold %sx %s to %s for %s'):format(GetPlayerName(src), qty, itemData.label, traderid, money(total)))
    if WebhookConfig.LargeTradeAmount > 0 and total >= WebhookConfig.LargeTradeAmount then
        Webhook.Send('sell', src, locale('wh_title_large_sell'), { { name = locale('wh_total'), value = money(total) } }, nil, WebhookConfig.LargeTradePing)
    end
    return result(true, locale('sv_sold', qty, itemData.label, ('%.2f'):format(total)))
end)

---------------------------------------------
-- admin panel
---------------------------------------------
RSGCore.Commands.Add('traderadmin', locale('sv_cmd_admin'), {}, false, function(source)
    TriggerClientEvent('rsg-trader:client:openAdmin', source)
end, 'admin')

lib.callback.register('rsg-trader:server:admin:isAdmin', function(source)
    return isAdmin(source)
end)

lib.callback.register('rsg-trader:server:admin:traders', function(source)
    if not isAdmin(source) then return nil end
    local counts = {}
    for _, r in ipairs(MySQL.query.await('SELECT traderid, COUNT(*) AS c FROM rsg_trader GROUP BY traderid') or {}) do
        counts[r.traderid] = r.c
    end
    local list = {}
    for _, t in pairs(Traders) do
        local copy = copyTable(t)
        copy.itemcount = counts[t.traderid] or 0
        list[#list + 1] = copy
    end
    table.sort(list, function(a, b) return a.tradername < b.tradername end)
    return list
end)

-- create (no traderid) or update (traderid) a trader
lib.callback.register('rsg-trader:server:admin:saveTrader', function(source, data)
    local src = source
    if not isAdmin(src) then adminDenied(src, 'saveTrader'); return result(false, locale('sv_no_permission')) end
    if type(data) ~= 'table' then return result(false, locale('sv_invalid_trade')) end

    local name = trim(data.tradername)
    if not name or #name < 2 or #name > 50 then return result(false, locale('sv_invalid_name')) end

    local model = trim(data.npcmodel)
    model = (model and model ~= '') and model:lower() or Config.DefaultModel
    if #model > 60 or model:find('[^%w_]') then return result(false, locale('sv_invalid_model')) end

    local existing = data.traderid and Traders[data.traderid]
    if data.traderid and not existing then return result(false, locale('sv_not_found')) end

    local trader = existing and copyTable(existing) or { traderid = makeTraderId(name) }
    trader.tradername = name
    trader.npcmodel = model
    trader.showblip = data.showblip and true or false

    -- position always taken server-side
    if not existing or data.moveHere then
        local ped = GetPlayerPed(src)
        if ped == 0 then return result(false, locale('sv_invalid_trade')) end
        local c = GetEntityCoords(ped)
        trader.x, trader.y, trader.z, trader.heading = c.x, c.y, c.z, GetEntityHeading(ped)
    end

    MySQL.query.await([[
        INSERT INTO rsg_trader_npcs (traderid, tradername, npcmodel, x, y, z, heading, showblip) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ON DUPLICATE KEY UPDATE tradername = VALUES(tradername), npcmodel = VALUES(npcmodel), x = VALUES(x), y = VALUES(y),
        z = VALUES(z), heading = VALUES(heading), showblip = VALUES(showblip)
    ]], { trader.traderid, trader.tradername, trader.npcmodel, trader.x, trader.y, trader.z, trader.heading, trader.showblip and 1 or 0 })

    Traders[trader.traderid] = trader
    syncTraders()
    log(existing and 'trader_updated' or 'trader_created', src, locale(existing and 'wh_title_trader_updated' or 'wh_title_trader_created'), {
        { name = locale('wh_trader'), value = traderLabel(trader.traderid) },
        { name = locale('wh_model'), value = trader.npcmodel },
        { name = locale('wh_blip'), value = locale(trader.showblip and 'wh_yes' or 'wh_no') },
        { name = locale('wh_position'), value = ('%.2f, %.2f, %.2f (h %.1f)'):format(trader.x, trader.y, trader.z, trader.heading), inline = false },
        existing and existing.tradername ~= name and { name = locale('wh_renamed_from'), value = existing.tradername } or nil,
    }, ('%s %s trader %s'):format(GetPlayerName(src), existing and 'updated' or 'created', trader.traderid))
    return result(true, locale(existing and 'sv_trader_updated' or 'sv_trader_added', name))
end)

lib.callback.register('rsg-trader:server:admin:deleteTrader', function(source, traderid, removeItems)
    local src = source
    if not isAdmin(src) then adminDenied(src, 'deleteTrader'); return result(false, locale('sv_no_permission')) end
    local trader = Traders[traderid]
    if not trader then return result(false, locale('sv_not_found')) end

    MySQL.query.await('DELETE FROM rsg_trader_npcs WHERE traderid = ?', { traderid })
    if removeItems then
        MySQL.query.await('DELETE FROM rsg_trader WHERE traderid = ?', { traderid })
    end
    Traders[traderid] = nil
    syncTraders()
    log('trader_deleted', src, locale('wh_title_trader_deleted'), {
        { name = locale('wh_trader'), value = ('%s (`%s`)'):format(trader.tradername, traderid) },
        { name = locale('wh_items_deleted'), value = locale(removeItems and 'wh_yes' or 'wh_no') },
    }, ('%s removed trader %s'):format(GetPlayerName(src), traderid))
    return result(true, locale('sv_trader_removed', trader.tradername))
end)

lib.callback.register('rsg-trader:server:admin:items', function(source, traderid)
    if not isAdmin(source) or not Traders[traderid] then return nil end
    return MySQL.query.await('SELECT item, stock, lowstock, highstock, baseprice FROM rsg_trader WHERE traderid = ? ORDER BY item', { traderid }) or {}
end)

-- add or update an item on a trader
lib.callback.register('rsg-trader:server:admin:saveItem', function(source, data)
    local src = source
    if not isAdmin(src) then adminDenied(src, 'saveItem'); return result(false, locale('sv_no_permission')) end
    if type(data) ~= 'table' then return result(false, locale('sv_invalid_trade')) end
    if not Traders[data.traderid] then return result(false, locale('sv_not_found')) end

    local item = trim(data.item)
    item = item and item:lower()
    if not item or not RSGCore.Shared.Items[item] then return result(false, locale('sv_item_missing')) end

    local stock     = toInt(data.stock, 0, 1000000)
    local lowstock  = toInt(data.lowstock, 0, 1000000)
    local highstock = toInt(data.highstock, 1, 1000000)
    local baseprice = tonumber(data.baseprice)
    if not stock or not lowstock or not highstock or not baseprice or highstock <= lowstock or baseprice <= 0 or baseprice > 1000000 then
        return result(false, locale('sv_invalid_input'))
    end
    baseprice = math.floor(baseprice * 100 + 0.5) / 100

    if data.isNew then
        local exists = MySQL.scalar.await('SELECT COUNT(*) FROM rsg_trader WHERE traderid = ? AND item = ?', { data.traderid, item })
        if exists and exists > 0 then return result(false, locale('sv_already_exists')) end
        MySQL.insert.await('INSERT INTO rsg_trader (traderid, item, stock, lowstock, highstock, baseprice) VALUES (?, ?, ?, ?, ?, ?)',
            { data.traderid, item, stock, lowstock, highstock, baseprice })
    else
        local affected = MySQL.update.await('UPDATE rsg_trader SET stock = ?, lowstock = ?, highstock = ?, baseprice = ? WHERE traderid = ? AND item = ?',
            { stock, lowstock, highstock, baseprice, data.traderid, item })
        if not affected or affected < 1 then return result(false, locale('sv_invalid_trade')) end
    end
    log(data.isNew and 'item_added' or 'item_updated', src, locale(data.isNew and 'wh_title_item_added' or 'wh_title_item_updated'), {
        { name = locale('wh_trader'), value = traderLabel(data.traderid) },
        { name = locale('wh_item'), value = ('%s (`%s`)'):format(RSGCore.Shared.Items[item].label, item) },
        { name = locale('wh_stock'), value = tostring(stock) },
        { name = locale('wh_low_high'), value = ('%d / %d'):format(lowstock, highstock) },
        { name = locale('wh_baseprice'), value = money(baseprice) },
    }, ('%s %s item %s on %s'):format(GetPlayerName(src), data.isNew and 'added' or 'updated', item, data.traderid))
    return result(true, locale(data.isNew and 'sv_added' or 'sv_item_updated'))
end)

lib.callback.register('rsg-trader:server:admin:deleteItem', function(source, traderid, item)
    local src = source
    if not isAdmin(src) then adminDenied(src, 'deleteItem'); return result(false, locale('sv_no_permission')) end
    if not Traders[traderid] or type(item) ~= 'string' then return result(false, locale('sv_invalid_trade')) end
    MySQL.query.await('DELETE FROM rsg_trader WHERE traderid = ? AND item = ?', { traderid, item })
    log('item_removed', src, locale('wh_title_item_removed'), {
        { name = locale('wh_trader'), value = traderLabel(traderid) },
        { name = locale('wh_item'), value = ('`%s`'):format(item) },
    }, ('%s removed item %s from %s'):format(GetPlayerName(src), item, traderid))
    return result(true, locale('sv_item_removed'))
end)

AddEventHandler('playerDropped', function()
    cooldowns[source] = nil
end)
