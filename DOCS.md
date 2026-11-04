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
