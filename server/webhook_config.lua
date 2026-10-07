---------------------------------------------
-- discord webhook settings (SERVER ONLY - never add this file to shared/client scripts,
-- otherwise players could read your webhook urls)
---------------------------------------------
WebhookConfig = {}

WebhookConfig.Enabled  = false
WebhookConfig.UseRsgLog = false -- also send logs to rsg-log (key 'rsgtrader')

WebhookConfig.BotName  = 'RSG Trader'
WebhookConfig.Avatar   = ''      -- optional image url for the bot avatar
WebhookConfig.Footer   = 'rsg-trader'
WebhookConfig.ServerName = ''    -- optional, shown as the embed author

-- create a webhook in Discord: Channel Settings > Integrations > Webhooks > New Webhook > Copy URL
-- leave a channel empty to disable it. channels can share the same url.
WebhookConfig.Channels = {
    trade    = '', -- player buy / sell
    admin    = '', -- trader + item management from /traderadmin
    security = '', -- suspicious activity (invalid input, too far, permission denied)
}

-- per event: channel, embed colour (decimal) and on/off
WebhookConfig.Events = {
    buy            = { channel = 'trade',    color = 5763719,  enabled = true }, -- green
    sell           = { channel = 'trade',    color = 3447003,  enabled = true }, -- blue
    trader_created = { channel = 'admin',    color = 5763719,  enabled = true },
    trader_updated = { channel = 'admin',    color = 16705372, enabled = true }, -- yellow
    trader_deleted = { channel = 'admin',    color = 15548997, enabled = true }, -- red
    item_added     = { channel = 'admin',    color = 5763719,  enabled = true },
    item_updated   = { channel = 'admin',    color = 16705372, enabled = true },
    item_removed   = { channel = 'admin',    color = 15548997, enabled = true },
    suspicious     = { channel = 'security', color = 15548997, enabled = true },
}

-- large trades get an @here ping in the trade channel (0 = off)
WebhookConfig.LargeTradeAmount = 0
WebhookConfig.LargeTradePing   = '@here'

-- ping for security logs ('' = none), e.g. '<@&ROLE_ID>'
WebhookConfig.SecurityPing = ''

-- the same player only creates one security log per event type within this window (ms)
WebhookConfig.SecurityThrottle = 30000

-- embeds are batched (max 10 per message) and flushed at this interval (ms)
WebhookConfig.FlushInterval = 2000

-- include player identifiers (license / discord / steam) in embeds
WebhookConfig.ShowIdentifiers = true
