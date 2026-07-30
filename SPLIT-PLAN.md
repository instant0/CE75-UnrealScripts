# Split Plan: CE75.LUA → Generic Core + G1R Plugin

## Goal

Split the monolithic `CE75.LUA` into a **generic Unreal Engine core** (works on any UE4/UE5 game) and a **Gothic 1 Remix plugin** (game-specific features loaded on demand via manifest-driven scan).

---

## File Layout

```
{anywhere: CE autorun dir, R:\Games\, etc.}
├── CE75.LUA                  ← Generic Unreal Engine core (load once, autorun)
│
└── Scripts\                  ← Plugin folder, sibling to CE75.LUA
    │
    └── g1r\                  ← One folder per game
        ├── g1r-plugin.lua    ← Plugin entry point (named *-Plugin.LUA)
        ├── g1r.manifest      ← JSON metadata (executable, main file, helpers)
        └── inventory_display_helper.lua  ← helper loaded by plugin
```

**Base path rule**: The `Scripts/` folder always sits alongside `CE75.LUA`. If the core is at `R:\CE75.LUA`, the plugin search path is `R:\Scripts\g1r\*`.

---

## Manifest Format (`g1r.manifest`)

Standard JSON, stored in the plugin folder root alongside the main script:

```json
{
  "name": "Gothic 1 Remake",
  "executable": "G1R-Win64-Shipping",
  "main": "g1r-plugin.lua",
  "helpers": [
    "inventory_display_helper.lua"
  ]
}
```

| Field | Purpose |
|-------|---------|
| `name` | Display name for the CE menu |
| `executable` | Process name substring for auto-detection (case-insensitive match) |
| `main` | Entry point script, loaded via `dofile` |
| `helpers` | Sub-modules loaded by the plugin (not scanned, not auto-loaded) |

No comment-header parsing needed — cleaner and avoids blank-line/encoding edge cases.

---

## Plugin Scanner

### How Discovery Works

`UEngine_scanPlugins()` runs at menu-build time inside `UEngine_buildSuccessMenus`:

1. Determine script directory from `debug.getinfo(1,'S').source`
2. Walk `<script_dir>/Scripts/` subfolders
3. For each subfolder, check for `*-Plugin.LUA` + `*.manifest` pair
4. Parse the JSON manifest → `{ name, executable, main, helpers }`
5. Build plugin list
6. Add menu entry: **Unreal Engine > Load Game Plugin ▸ > Gothic 1 Remake**

On menu click, the core `pcall(dofile)`'s the plugin's main file. The plugin script runs and calls `UEngine_registerPlugin(...)` to populate its submenu.

### Auto-Detection (Process Match)

After `couldBeUnrealEngine()` returns true, scan loaded plugins for an `executable` field matching the current process name. On match, auto-`dofile` that plugin.

### Plugin Script Template

```lua
-- g1r-plugin.lua
-- Loaded by CE75.LUA plugin scanner

-- ... all plugin code ...

if type(UEngine_registerPlugin) == 'function' then
  UEngine_registerPlugin('Gothic 1 Remake', function(parentMenu)
    parentMenu.add('Add / Refresh Inventory Items')
    parentMenu.add('Live track inventory changes')
    parentMenu.add('Lookup real item names (once, background)')
    -- etc.
  end)
end
```

---

## Feature Ownership

### Stays in Generic `CE75.LUA` (works on ANY UE4/UE5 game)

| Feature | What it does |
|---------|-------------|
| **GEngine discovery** | Finds `GEngine` pointer, registers CE symbol |
| **Name pool caching** | Discovers and caches FName table via pattern or AOB |
| **Object array** | Discovers `FUObjectArray` |
| **FProperty offset auto-discovery** | Walks memory to find Class/Name/Offset/Owner/Size/BitMask fields |
| **UClass/UStruct property enumeration** | Walks `PropertyLink` chain, gets all properties with offsets + types |
| **Structure dissect callbacks** | Hooks CE's structure dissect to auto-name UE objects |
| **Player / Character chain** | `GEngine` → `GameInstance` → `LocalPlayers[0]` → `PlayerController` → `Pawn/Character` — identical in every UE game |
| **Player address list** | "Player (N props)" group with properties sorted by bucket (Movement, Network, Life, Flags, Components, etc.) with safety tiers `[S/C/U/P]` |
| **Player property hints** | `bCanBeDamaged` → "Can take damage", `CharacterMovement` → "Move component", etc. — based on standard UE property names |
| **Debug: Find Inventory Properties** | Scans character class for keywords like "Inventory", "Item", "Backpack", "Bag" — generic search only |
| **Format-agnostic name utilities** | `UEngine_itemShortName`, `UEngine_itemPrettyName` — no game-specific prefix knowledge |

### Only with G1R Plugin (`Scripts/g1r/g1r-plugin.lua`)

| Feature | Why G1R-specific |
|---------|-----------------|
| **Inventory snapshot** | Uses hardcoded G1R offsets: `Char+0x7B0` → `Mgr+0x170` → `Cont+0x168` → `Inv+0x378` array, stride `0xB8` |
| **Equipped items** | Reads 3 G1R-specific sources: `InvMgr+0x158 TArray`, `Manager+0x180 CDOs`, `Char+0x190 Children` |
| **Item classification** | Parses Gothic `ItXX_` prefix naming (`ItMw_`=melee, `ItRw_`=ranged, `ItFo_`=food, `ItAr_`=magic, etc.) |
| **Real item names** | Loads `inventory_display_helper.lua` → Alkimia loc map → Gothic localized titles |
| **GNames base** | Hardcoded RVA `0x9AE6600` for `G1R-Win64-Shipping.exe` |
| **Inventory address list** | "Inventory (X bag + Y equipped)" tree with Gothic item categories |
| **Live tracking** | Timer-based refresh of inventory display |
| **Display helper loading** | Locates `inventory_display_helper.lua` relative to plugin's own folder |

---

## External Dependencies

Only one: **`inventory_display_helper.lua`** (in the plugin folder) — provides localization/display name resolution for Gothic items.

Exports consumed by the G1R plugin:
- `InventoryDisplay_InitFromNs(ns)`, `InventoryDisplay_InitFromEntry(entry)`, `InventoryDisplay_Init()` — init methods
- `InventoryDisplay_IsReady()` — check if loc map is built
- `InventoryDisplay_GetTitle(name)` — returns localized display name
- `ResolveItemDisplayName(name)` — fallback name resolver

**Optional** — without it, inventory shows technical names (e.g. `ItFo_Beer`).

**Global variables**: The helper currently exports globals (`AlkimiaLocMap`, `AlkimiaFuzzy`, `AlkimiaNs`, `BP_FText`, `BP_Obj`). These should be collected into a single registry table (e.g., `UEngine.Plugins.registry['Gothic1Remake']`) to avoid cross-plugin pollution.

---

## Path Sanitization — Developer-Specific Paths to Remove

| Location in current code | What's there | Action |
|--------------------------|-------------|--------|
| `UEngine_addPlayerToAddressList` (CE75.LUA:3995) | `io.open('/mnt/d/d/...CE75-PLAYER-PROPS.txt')` and `d:\d\gamehacking\...` | Remove all. Guard behind `UEngine.Player.dumpProps` flag if the feature is kept |
| `UEngine_displayHelperPaths` (CE75.LUA:4966) | 5 hardcoded absolute paths | Remove. Plugin-relative path from `debug.getinfo` is sufficient |
| `UEngine_loadDisplayHelper` error msg (CE75.LUA:5045) | `"...Paths tried under d:\\d\\gamehacking\\lua\\ and R:\\..."` | Change to generic `"Scripts/ subfolder"` reference |

---

## Plugin Registry & API

The core exposes a minimal API table to plugins:

```lua
-- Provided by CE75.LUA as a global or UEngine member:
UEngine.PluginAPI = {
  log = log,
  registerPlugin = function(name, setupFn) ... end,
  getCharacter = UEngine_findCharacter,
  getLocalPlayer = UEngine_findLocalPlayer,
  enumerateProperties = UEngine_getAllProperties,
  resolveFName = UEngine_resolveFName,
  -- format utilities (game-agnostic)
  itemShortName = UEngine_itemShortName,
  itemPrettyName = UEngine_itemPrettyName,
}
```

Plugins call `registerPlugin(name, setupFn)` to register their menu items. The registry stores them in `UEngine.Plugins.registry[name]`.

---

## Lifecycle Model

| Event | What happens |
|-------|-------------|
| **Core loaded (dofile)** | `CE75.LUA` runs, scans `Scripts/` for manifests, builds "Load Game Plugin ▸" menu |
| **User clicks plugin** | Core `pcall(dofile)`'s the plugin's main file; plugin calls `registerPlugin(...)` |
| **User attaches to game** | `OnProcessOpened` fires; core auto-detects matching plugin and loads it |
| **User detaches / re-attaches** | Core re-runs discovery; plugin state is naturally reset since `dofile` re-runs the plugin |
| **Core re-loaded (re-dofile)** | `UEngine_CE75_ReloadCleanup` runs; plugin menu entries are destroyed; next menu rebuild re-scans |

No explicit unload mechanism needed — the tool targets one game per session. Reloading the core resets everything cleanly.

---

## Implementation Order

### Phase 1 — Core + Plugin Scanner

1. Create `Scripts/g1r/g1r.manifest` with the JSON schema above
2. Create `Scripts/g1r/g1r-plugin.lua` — move G1R-specific code here:
   - `UEngine.Inv` defaults (hardcoded offsets)
   - `UEngine_snapshotInventory`
   - `UEngine_snapshotEquipped`
   - `UEngine_classifyItemName` (Gothic `ItXX_` classification)
   - `UEngine_ensureGNames` (G1R-specific RVA)
   - `UEngine_addInventoryToAddressList`
   - `UEngine_buildInventoryAddressList`
   - `UEngine_refreshInventoryAddressList`
   - `UEngine_setInventoryLiveTracking`
   - `UEngine_loadDisplayHelper`
   - `UEngine_lookupRealItemNamesAsync`
   - `UEngine_logInventorySessionChecklist`
3. Implement `UEngine_scanPlugins()` in core — manifest-based discovery
4. Add "Load Game Plugin ▸" dynamic menu to `UEngine_buildSuccessMenus`
5. Remove all `UEngine_displayHelperPaths` developer paths from core
6. Guard/remove the `CE75-PLAYER-PROPS.txt` debug dump or gate behind `dumpProps`

### Phase 2 — Auto-Detection

1. In `couldBeUnrealEngine()` success path, run `UEngine_autoDetectPlugin()`:
   - Scan manifests for `executable` matching current process name
   - Auto-`dofile` on first match

---

## Final Menu Structure

```
Unreal Engine
├── Status
├── Prioritize this
├── Use when dissecting structures [✓]
├── ─────────────────
├── Add / Refresh Player (auto on load)
├── ─────────────────
├── Load Game Plugin ▸              ← dynamic, populated from Scripts/
│   └── Gothic 1 Remake             ← dofile Scripts/g1r/g1r-plugin.lua
├── ─────────────────
└── Debug
    └── Find Inventory Properties

--- After G1R plugin is loaded: ---

Unreal Engine
├── Status
├── Prioritize this
├── Use when dissecting structures [✓]
├── ─────────────────
├── Add / Refresh Player (auto on load)
├── ─────────────────
├── Gothic 1 Remake                 ← added by plugin via registerPlugin
│   ├── Add / Refresh Inventory Items
│   ├── Live track inventory changes
│   ├── Lookup real item names (once, background)
│   ├── Inventory session checklist (log)
│   ├── ─────────────────
│   └── Debug
│       └── Find Inventory Properties
├── ─────────────────
└── Debug
    └── Find Inventory Properties
```
