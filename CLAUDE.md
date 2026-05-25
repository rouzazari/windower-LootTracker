# LootTracker — CLAUDE.md

## Project overview

A [Windower](https://www.windower.net/) addon for Final Fantasy XI written in Lua. Tracks loot drops during a session, supports auto-drop of slip-stored items, auto-sell to NPCs, clipboard copy of item names, and cross-character shared-stack analysis via the FindAll addon.

Single file: `LootTracker.lua`

## Dev/deploy workflow

After every code change, the file must be copied to the live Windower install:

```
F:\code\windower-LootTracker\LootTracker.lua
  →  C:\windower\addons\LootTracker\LootTracker.lua
```

This is handled automatically by a PostToolUse hook in `.claude/settings.local.json` (fires on Edit/Write). No manual copy needed.

## Windower Lua environment

- Windower addons run inside Windower's embedded Lua 5.1 runtime — not standard desktop Lua.
- Available libraries: `resources`, `config`, `texts`, `packets`, `sets` (all Windower-specific).
- `res` = `resources` table: `res.items[id]`, `res.bags`, etc.
- `windower.*` global API: `windower.ffxi.get_items()`, `windower.add_to_chat()`, `windower.send_command()`, `windower.copy_to_clipboard()`, `windower.register_event()`, etc.
- `packets.parse()` / `packets.new()` / `packets.inject()` for raw FFXI network packets.
- Events: `incoming chunk`, `outgoing chunk`, `incoming text`, `add item`, `load`, `unload`, `login`, `logout`, `zone change`, `addon command`.

## Key design notes

- Loot state is session-scoped and resets on zone change (`reset()`).
- Two on-screen text boxes: `display` (cumulative loot counts) and `recent_display` (last 10 drops).
- FindAll integration: reads `C:\windower\addons\findAll\data\<CharName>.lua` snapshots. Used for slip-storage matching (auto-drop) and cross-character shared-stack analysis.
- Sell automation uses injected outgoing packet `0x084` (price query) and listens for incoming `0x03D` (price response / sale confirmed). Requires the NPC sell window to be open.
- `_drop`, `_sell_confirm`, `_sell_next` are internal deferred commands invoked via `windower.send_command('wait N; lua c loottracker ...')`.
- Clipboard copy tracks the last interacted item via outgoing packets `0x037` (use/equip) and `0x050`.

## Commands

```
//lt copy                  - Copy last used/equipped item name to clipboard (Ctrl+Shift+C)
//lt copyall               - Copy all bag contents to clipboard as CSV
//lt reset / r             - Clear session loot log
//lt show / hide           - Toggle displays
//lt autodrop [on|off]     - Toggle auto-drop of slip-stored items on pickup
//lt preview / p           - Preview what //lt drop would discard
//lt drop                  - Drop all slip-stored items from inventory
//lt refresh               - Reload FindAll snapshot from disk
//lt shared                - Show stackable items split across all characters
//lt sell                  - Sell items on sell list (NPC window must be open)
//lt sell preview          - Preview what would be sold
//lt sell add/remove/list/clear/stop
//lt help                  - Show help
```

## Git

- Sole author: rouzazari. Never add `Co-Authored-By:` lines to commit messages.
