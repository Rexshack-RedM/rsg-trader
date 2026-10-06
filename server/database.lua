---------------------------------------------
-- automatic database setup
-- creates / upgrades the rsg_trader table on resource start.
-- disable with Config.AutoDatabase = false and import installation/rsg-trader.sql manually.
---------------------------------------------
if not Config.AutoDatabase then return end

local function log(msg, color)
    print(('[%s] %s%s^7'):format(GetCurrentResourceName(), color or '^2', msg))
end

local function tableExists(name)
    return (MySQL.scalar.await(
        'SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ?', { name }) or 0) > 0
end

local function indexExists(tbl, index)
    return (MySQL.scalar.await(
        'SELECT COUNT(*) FROM information_schema.STATISTICS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ? AND INDEX_NAME = ?', { tbl, index }) or 0) > 0
end

MySQL.ready(function()
    local ok, err = pcall(function()
        -- migrate from the old rex-trader table name
        if not tableExists('rsg_trader') and tableExists('rex_trader') then
            MySQL.query.await('RENAME TABLE `rex_trader` TO `rsg_trader`')
            log('Renamed table rex_trader -> rsg_trader', '^3')
        end

        local created = not tableExists('rsg_trader')

        MySQL.query.await([[
            CREATE TABLE IF NOT EXISTS `rsg_trader` (
              `id` int(11) NOT NULL AUTO_INCREMENT,
              `traderid` varchar(50) NOT NULL,
              `item` varchar(50) NOT NULL,
              `stock` int(11) NOT NULL DEFAULT 0,
              `lowstock` int(11) NOT NULL DEFAULT 0,
              `highstock` int(11) NOT NULL DEFAULT 0,
              `baseprice` decimal(11,2) NOT NULL DEFAULT 0.00,
              PRIMARY KEY (`id`),
              UNIQUE KEY `trader_item` (`traderid`, `item`)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
        ]])

        if created then
            log('Created table rsg_trader')
        else
            -- upgrade older installs
            local engine = MySQL.scalar.await(
                'SELECT ENGINE FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ?', { 'rsg_trader' })
            if engine and engine:lower() ~= 'innodb' then
                MySQL.query.await('ALTER TABLE `rsg_trader` ENGINE=InnoDB')
                log('Converted rsg_trader to InnoDB', '^3')
            end
            if not indexExists('rsg_trader', 'trader_item') then
                local dupes = MySQL.scalar.await(
                    'SELECT COUNT(*) FROM (SELECT 1 FROM rsg_trader GROUP BY traderid, item HAVING COUNT(*) > 1) d') or 0
                if dupes > 0 then
                    log(('Found %d duplicate trader/item rows - remove them so the unique key can be added.'):format(dupes), '^1')
                else
                    MySQL.query.await('ALTER TABLE `rsg_trader` ADD UNIQUE KEY `trader_item` (`traderid`, `item`)')
                    log('Added unique key trader_item', '^3')
                end
            end
        end

        -- trader npc table
        local npcsCreated = not tableExists('rsg_trader_npcs')
        MySQL.query.await([[
            CREATE TABLE IF NOT EXISTS `rsg_trader_npcs` (
              `traderid` varchar(50) NOT NULL,
              `tradername` varchar(50) NOT NULL,
              `npcmodel` varchar(60) NOT NULL,
              `x` float NOT NULL,
              `y` float NOT NULL,
              `z` float NOT NULL,
              `heading` float NOT NULL DEFAULT 0,
              `showblip` tinyint(1) NOT NULL DEFAULT 1,
              PRIMARY KEY (`traderid`)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
        ]])
        if npcsCreated then
            for _, t in ipairs(Config.DefaultTraders or {}) do
                MySQL.insert.await(
                    'INSERT IGNORE INTO rsg_trader_npcs (traderid, tradername, npcmodel, x, y, z, heading, showblip) VALUES (?, ?, ?, ?, ?, ?, ?, 1)',
                    { t.traderid, t.tradername, t.npcmodel or Config.DefaultModel, t.coords.x, t.coords.y, t.coords.z, t.coords.w })
            end
            log(('Created table rsg_trader_npcs and seeded %d traders'):format(#(Config.DefaultTraders or {})))
        end

        -- seed default items only into a brand new table
        if created and Config.DefaultItems and #Config.DefaultItems > 0 then
            for _, row in ipairs(Config.DefaultItems) do
                MySQL.insert.await(
                    'INSERT IGNORE INTO rsg_trader (traderid, item, stock, lowstock, highstock, baseprice) VALUES (?, ?, ?, ?, ?, ?)',
                    { row.traderid, row.item, row.stock or 0, row.lowstock, row.highstock, row.baseprice })
            end
            log(('Seeded %d default trade items'):format(#Config.DefaultItems))
        end
    end)

    if ok then
        TriggerEvent('rsg-trader:server:databaseReady')
    else
        log('Database setup failed: ' .. tostring(err), '^1')
    end
end)
