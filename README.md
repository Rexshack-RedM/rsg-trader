# rsg-trader

Dynamic-price NPC traders for **RSG-Core (RedM)**. Players buy and sell items at prices that move with stock levels. Admins place traders and manage stock in game through a built-in admin panel, with no config edits or restarts.

## Features
- NPC traders spawn and despawn by distance, with optional fade-in and an ox_target "Speak with the Trader" option
- Buy / Sell UI that shows stock bars, your cash, owned counts and live totals. Quantity is capped by stock, by what you carry and by what you can afford.
- Dynamic pricing: low stock costs more, high stock costs less, and traders pay a configurable fraction of their sell price
- `/traderadmin` panel to add, edit, move, teleport to and delete traders, and to add, edit and remove items using a searchable item picker
- Map blips per trader (can be toggled)
- Draggable panels; double-click a header to reset its position
- Auto-creates and migrates the database tables (including a migration from the old `rex_trader` table)
- ox_lib notifications and JSON locales

## Dependencies
- rsg-core
- rsg-inventory
- ox_lib
- ox_target
- oxmysql

## Installation
1. Drop `rsg-trader` into your resources folder.
2. Add `ensure rsg-trader` to your server.cfg **after** the dependencies.
3. Database:
   - `Config.AutoDatabase = true` (default): tables are created and upgraded on start.
   - `Config.AutoDatabase = false`: import `installation/rsg-trader.sql` manually.
4. Restart the server, then use `/traderadmin` (admin permission) to add your first trader where you are standing.

## Configuration (`shared/config.lua`)
| Option | Description |
|---|---|
| `MaxBuyAmount` / `MaxSellAmount` | Max quantity per transaction |
| `InteractDistance` | Server-side max distance (m) from the trader to trade |
| `Cooldown` | Server-side cooldown (ms) between trades per player |
| `DistanceSpawn` / `FadeIn` | NPC spawn range and fade effect |
| `Pricing.priceMultipliers` | Price multiplier at low, normal and high stock |
| `Pricing.min/maxPriceFactor` | Price clamp relative to base price |
| `Pricing.sellFactor` | Fraction of the sell price a trader pays players. Keep `sellFactor * lowStock < normalStock` to prevent buy/sell profit loops. |
| `Sounds` | Frontend sounds for open, close, success and fail |
| `DefaultTraders` / `DefaultItems` | Seed data, used only when the tables are first created |

## Security
All money and item changes happen server-side. Each trade checks:
- the player, trader and item exist, and the amount is a valid integer within limits
- the player is within range of the trader (using server-side coords)
- the per-player cooldown

Stock is reserved atomically, so two players can't buy the same units. If payment or the inventory add fails, money and stock are refunded. Prices are always calculated on the server, and every admin callback checks the `admin` permission.

## Discord Webhooks
All settings are in `server/webhook_config.lua`. This file is **server-only**, so players can never read your webhook URLs.

1. In Discord, go to Channel Settings > Integrations > Webhooks > New Webhook, then Copy URL.
2. Paste the URLs into `WebhookConfig.Channels`. Channels can share one URL, and an empty channel is disabled.
3. Restart the resource and run `/traderwebhooktest` (admin) to send a test embed to each channel.

| Channel | Events |
|---|---|
| `trade` | `buy`, `sell`: player, character, citizenid, trader, item, total, stock |
| `admin` | `trader_created/updated/deleted`, `item_added/updated/removed`: who changed what, including position, model, prices |
| `security` | `suspicious`: malformed or out-of-range trade requests, trades away from the trader, admin callbacks by non-admins |

Behaviour:
- Each event can be switched on or off and given its own colour or channel in `WebhookConfig.Events`.
- Embeds are queued and batched (up to 10 per message every `FlushInterval` ms). Discord `429` rate limits are respected and the embeds are retried.
- Security logs are throttled per player and per reason (`SecurityThrottle`), and can ping a role (`SecurityPing`).
- Optionally ping on large trades with `LargeTradeAmount` / `LargeTradePing`.
- Player identifiers (license, Discord mention, Steam) can be hidden with `ShowIdentifiers = false`.
- Set `UseRsgLog = true` to also send plain-text logs to rsg-log (key `rsgtrader`).

Other resources can post through the same queue:
```lua
exports['rsg-trader']:SendWebhook('buy', source, 'Title', { { name = 'Field', value = 'Value' } }, 'optional description')
```

## Locales
Included: `en`, `de`, `el`, `es`, `fr`, `ja`, `nl`, `pl`, `pt-br`, `ro`. Every player-facing string (notifications, NUI, target labels, commands) and the Discord webhook embeds come from `locales/*.json`. Set the language in server.cfg with `setr ox:locale de`. ox_lib falls back to `en` for any missing key.
