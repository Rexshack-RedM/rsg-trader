# rsg-trader – Developer Docs

## Files
| File | Purpose |
|---|---|
| `shared/config.lua` | Settings and shared pricing helpers (`Config.GetBuyPrice`, `Config.GetSellPrice`, `Config.Round2`) |
| `server/database.lua` | Auto-creates/upgrades `rsg_trader` and `rsg_trader_npcs` (when `Config.AutoDatabase = true`), then fires `rsg-trader:server:databaseReady` |
| `server/server.lua` | Trader cache (synced to clients via `GlobalState.rsgTraders`), buy/sell and admin callbacks |
| `server/webhooks.lua` / `webhook_config.lua` | Batched, rate-limit-aware Discord logging (server only) |
| `client/client.lua` | Blips, NUI bridge, shop and admin panel |
| `client/npcs.lua` | Distance-based ped spawning with rsg-target option |
| `html/*` | NUI (RDR2 leather & gold theme) |

## Database
- `rsg_trader` – `traderid`, `item`, `stock`, `lowstock`, `highstock`, `baseprice` (unique `traderid + item`)
- `rsg_trader_npcs` – `traderid` (PK), `tradername`, `npcmodel`, `x`, `y`, `z`, `heading`, `showblip`

## Pricing
- Buy price: `baseprice × multiplier` (lowStock when `stock <= lowstock`, highStock when `stock >= highstock`), clamped by `minPriceFactor`/`maxPriceFactor`.
- Sell price: buy price × `sellFactor`. Keep `sellFactor × lowStock < normalStock` to prevent buy/sell profit loops.

## Server callbacks (rsg-core `CreateCallback`)
| Name | Args | Access |
|---|---|---|
| `rsg-trader:server:traderdata` | traderid | anyone |
| `rsg-trader:server:buy` / `:sell` | traderid, item, amount | player within `InteractDistance`, `Cooldown` applied |
| `rsg-trader:server:admin:isAdmin` | – | anyone (returns bool) |
| `rsg-trader:server:admin:traders` / `:items` | – / traderid | admin |
| `rsg-trader:server:admin:saveTrader` | `{ traderid?, tradername, npcmodel, showblip, moveHere? }` | admin; position always taken from the admin's ped server-side |
| `rsg-trader:server:admin:deleteTrader` | traderid, removeItems | admin |
| `rsg-trader:server:admin:saveItem` | `{ traderid, item, stock, lowstock, highstock, baseprice, isNew }` | admin |
| `rsg-trader:server:admin:deleteItem` | traderid, item | admin |

All callbacks return `{ ok = bool, msg = string }` for actions.

## Security
- Prices, stock, money and items are all decided server-side; the client only sends trader id, item and amount.
- Amounts are integer-clamped to `1..MaxBuyAmount/MaxSellAmount`; items must exist in `RSGCore.Shared.Items` and be listed on that trader.
- Stock is reserved with an atomic `UPDATE ... WHERE stock >= ?`; payment or inventory failures are rolled back.
- Sales that would pay $0 are rejected.
- Invalid input, distance failures and non-admin calls to admin callbacks are logged to the `security` webhook (throttled).

## Commands
- `/traderadmin` (admin) – open the admin panel
- `/traderwebhooktest` (admin) – send test embeds

## Exports
- Server: `exports['rsg-trader']:SendWebhook(event, src, title, fields, description)`

## Locales
JSON files in `locales/` (en, de, el, es, fr, ja, nl, pl, pt-br, ro), loaded by `@rsg-core/shared/locale.lua`. Set language with `setr rsg:locale <lang>`.

## rsg-economy integration

`Config.Economy = { Enabled }`. `econQuote(src, trader, mode, unitPrice, qty)` finds the region with `exports['rsg-economy']:GetRegionAt(trader position)` and calls `Quote` with `market = false`.
- `rsg-trader:server:traderdata` replaces `buyprice` and `sellprice` with the quote's per-unit `total`, so the UI shows the taxed price.
- `rsg-trader:server:buy` / `sell` use `quote.total` as the amount charged or paid (server computed, never from the client). After the money and items have moved, `Record(src, quote)` banks the tax in the treasury.
- Per-unit prices shown in the UI are rounded to cents, so a large order can differ from the shown unit price times the quantity by a few cents.
- Skipped when rsg-economy is not started or the trader has no town within `Config.RegionRadius` of rsg-economy.

<!-- BEGIN AUTO-REFERENCE (generated from the code; re-run the generator instead of editing by hand) -->

## Technical reference

Generated from the source of **rsg-trader 3.2.0**. Names, arguments and defaults below are read straight from the code.

### Dependencies

`rsg-core`, `rsg-inventory`, `rsg-target`, `oxmysql`

### Database

Tables: `rsg_trader`, `rsg_trader_npcs`.

Tables are created automatically on start while `Config.AutoDatabase = true` (default). Nothing is ever dropped or overwritten.
For a manual install set `Config.AutoDatabase = false` and import `installation/rsg-trader.sql` once.

```lua
-- shared/config.lua
Config.AutoDatabase = true -- false = import the SQL file yourself
```

### Configuration

| Option | Default | Notes |
|---|---|---|
| `Config.Debug` | `false` |  |
| `Config.AutoDatabase` | `true` | create/upgrade the database table on start (false = import installation/rsg-trader.sql manually) |
| `Config.Image` | `'rsg-inventory/html/images/'` | location of item images |
| `Config.MaxBuyAmount` | `10` | max items per buy transaction |
| `Config.MaxSellAmount` | `10` | max items per sell transaction |
| `Config.InteractDistance` | `5.0` | server-side max distance (m) from the trader to buy/sell |
| `Config.Cooldown` | `2000` | server-side cooldown (ms) between transactions per player |
| `Config.Sounds` | `table` |  |
| `Config.DistanceSpawn` | `20.0` |  |
| `Config.FadeIn` | `true` |  |
| `Config.Pricing` | `table` |  |
| `Config.DefaultModel` | `'mp_u_m_m_trader_01'` |  |
| `Config.DefaultBlip` | `{ sprite = 'blip_shop_market_stall', scale = 0.2 }` |  |
| `Config.DefaultTraders` | `table` |  |
| `Config.DefaultItems` | `table` |  |
| `Config.Economy` | `table` | The town is the one nearest to the trader (rsg-economy GetRegionAt). A trader too far from every town is untou |
| `Config.Enabled` | `true` |  |

### Exports

**Server**

| Export | Arguments | File |
|---|---|---|
| `SendWebhook` | `` | `server/webhooks.lua` |

```lua
-- example
local result = exports['rsg-trader']:SendWebhook()
```

### Events

Server events can be fired by any client, so every handler re-validates the player, the arguments and any permission, distance or cooldown on the server. Never add a reward to a handler without those checks.

| Event | Side | Arguments | File |
|---|---|---|---|
| `rsg-trader:client:openAdmin` | client | `` | `client/client.lua` |

```lua
-- from a server script
TriggerClientEvent('rsg-trader:client:openAdmin', source)
```

### Commands

| Command | Notes | File |
|---|---|---|
| `/traderadmin` | locale('sv_cmd_admin') | `server/server.lua` |
| `/traderwebhooktest` | locale('sv_cmd_webhooktest') | `server/webhooks.lua` |

### Locales

Language files in `locales/`: `de`, `el`, `en`, `es`, `fr`, `ja`, `nl`, `pl`, `pt-br`, `ro`. Set the language with `setr rsg:locale "en"`.

<!-- END AUTO-REFERENCE -->
