# LootTracker

A [Windower](https://www.windower.net/) addon for Final Fantasy XI. Tracks loot drops during a session and provides utilities for managing inventory: auto-drop of slip-stored duplicates, NPC auto-sell, clipboard copy of item names, and cross-character shared-stack analysis.

**Version:** 1.3  
**Commands:** `//loottracker` / `//lt`

---

## Installation

1. Copy `LootTracker.lua` into `<Windower>/addons/LootTracker/LootTracker.lua`.
2. Load in-game: `//lua load loottracker`
3. To load automatically on startup, add it to `<Windower>/scripts/init.txt`:
   ```
   lua load loottracker
   ```

---

## Features

### Loot display
Two draggable on-screen panels update automatically during a session:
- **LootTracker** — cumulative drop counts for all items, sorted alphabetically.
- **Recent Drops** — the last 10 items picked up, newest at top.

Both panels reset on zone change. The display panels can be repositioned by dragging and their positions are saved to `data/settings.xml`.

### Auto-drop (slip storage)
When enabled, any item that lands in your inventory and is already stored in a slip is automatically dropped after a short delay. Requires a [FindAll](https://github.com/Windower/packages/tree/live/addons/findAll) snapshot.

### Auto-sell
Maintains a persistent sell list. When the NPC sell window is open, `//lt sell` walks through every matching inventory item and sells it via injected packets, one at a time with a 1-second gap between items.

### AH price lookup
Fetches recent auction house sale data from FFXIAH for items dropped this session, displayed in a third draggable panel. Requires your server to be configured first:

```
//lt server ragnarok
```

Once set, use `//lt price` to fetch prices for all session loot, or `//lt price <item name>` for a single item. Prices are cached for 24 hours; use `//lt price refresh` to bypass the cache.

### Clipboard copy
- `//lt copy` (also **Ctrl+Shift+C**) — copies the name of the last item you used, equipped, or appraised at an NPC.
- `//lt copyall` — copies a CSV of your entire bag contents (all bags) to clipboard.

### Shared-stack analysis
`//lt shared` reads FindAll snapshots for every character and lists stackable, non-exclusive items held on two or more characters — useful for consolidating stacks before trading or auctioning.

---

## Commands

| Command | Description |
|---|---|
| `//lt copy` | Copy last used/equipped item name to clipboard (also Ctrl+Shift+C) |
| `//lt copyall` | Copy all bag contents to clipboard as CSV |
| `//lt reset` / `//lt r` | Clear the session loot log |
| `//lt show` / `//lt hide` | Toggle both on-screen panels |
| `//lt autodrop [on\|off]` | Toggle auto-drop of slip-stored items (no arg = toggle) |
| `//lt preview` / `//lt p` | Preview what `//lt drop` would discard |
| `//lt drop` | Drop all slip-stored items from inventory now |
| `//lt refresh` | Reload the FindAll snapshot from disk |
| `//lt shared` | Show stackable items split across all characters |
| `//lt server <name>` | Set your FFXIAH server for price lookups (e.g. `ragnarok`, `asura`) |
| `//lt price` | Fetch AH prices for this session's loot |
| `//lt price <item name>` | Fetch AH price for a specific item |
| `//lt price refresh` | Force-refresh session loot prices (bypass 24h cache) |
| `//lt price refresh <name>` | Force-refresh price for a specific item |
| `//lt sell` | Sell inventory items on the sell list (NPC window must be open) |
| `//lt sell preview` | Preview what `//lt sell` would sell |
| `//lt sell add <name>` | Add an item to the sell list |
| `//lt sell remove <name>` | Remove an item from the sell list |
| `//lt sell list` | Show the current sell list |
| `//lt sell clear` | Clear the sell list |
| `//lt sell stop` | Abort an in-progress sell |
| `//lt help` | Show in-game help |

---

## FindAll integration

Several features depend on [FindAll](https://github.com/Windower/packages/tree/live/addons/findAll) snapshots stored in `<Windower>/addons/findAll/data/<CharName>.lua`.

- Run `//findall` at least once per character to generate the snapshot file.
- LootTracker loads your snapshot automatically on login and reloads it on `//lt refresh`.
- `//lt shared` reads snapshots for **all** characters in that folder, so run `//findall` on each character you want included in the cross-character analysis.

Features that require FindAll: `autodrop`, `drop`, `preview`, `shared`.

---

## Settings

Settings are saved to `<Windower>/addons/LootTracker/data/settings.xml` and persist across sessions. Includes:
- Display panel positions and appearance
- `AutoDrop` toggle state
- `SellList` contents
- `Server` — your FFXIAH server name (set via `//lt server <name>`)
