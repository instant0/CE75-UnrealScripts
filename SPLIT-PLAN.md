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
        ├── g1r-plugin.lua    ← Plugin entry point (*-Plugin.LUA convention)
        ├── g1r.manifest      ← Key=Value metadata (NOT JSON — CE 7.5 has no JSON lib)
        └── inventory_display_helper.lua  ← helper loaded by plugin
```

**Base path rule**: The `Scripts/` folder is always a sibling of `CE75.LUA`. If the core is at `R:\CE75.LUA`, the plugin search path is `R:\Scripts\g1r\*`.

---

## Manifest Format (`g1r.manifest`)

CE 7.5's Lua engine has no JSON library. The manifest uses a simple `Key=Value` format, one entry per line. Blank lines and lines starting with `#` are ignored.

```
name=Gothic 1 Remake
executable=G1R-Win64-Shipping
main=g1r-plugin.lua
helpers=inventory_display_helper.lua
```

Parsing from Lua:
```lua
local sl = createStringList()
sl:loadFromFile(path)
for i = 0, sl.Count - 1 do
  local line = sl[i]:gsub('^%s*(.-)%s*$', '%1')
  if line ~= '' and line:sub(1,1) ~= '#' then
    local k, v = line:match('^([^=]+)=(.*)$')
    if k then manifest[k:lower()] = v end
  end
end
```

| Field | Purpose |
|-------|---------|
| `name` | Display name for the CE menu |
| `executable` | Process name substring for auto-detection (case-insensitive, partial match) |
| `main` | Entry point script, relative to plugin folder, loaded via `dofile` |
| `helpers` | Comma-separated list of sub-modules loaded by the plugin (not auto-loaded by scanner) |

No comment-header parsing needed — cleaner and avoids blank-line/encoding edge cases.

---

## Plugin Scanner

### How Discovery Works

`UEngine_scanPlugins()` runs at menu-build time inside `UEngine_buildSuccessMenus`. It uses CE 7.5 global APIs confirmed from source:

- `getFileList(path, mask, subdirs)` — list `.manifest` files
- `getDirectoryList(path, subdirs)` — list subfolders of `Scripts/`
- `createStringList():loadFromFile(path)` — read and parse manifest
- `fileExists(path)` — verify `*-Plugin.LUA` exists before adding

**Steps**:

1. Determine script directory from `debug.getinfo(1,'S').source`
2. Call `getDirectoryList(<dir>/Scripts/, false)` to get subfolder names
3. For each subfolder, check for `<folder>.manifest` + `<folder>-Plugin.LUA`
4. Parse the manifest via `createStringList():loadFromFile()`
5. Build plugin list `{ name, executable, main, helpers, folder }`
6. Add menu entry: **Unreal Engine > Load Game Plugin ▸ > Gothic 1 Remake**

On menu click, the core `pcall(dofile)`'s the fully-qualified path to the plugin's main file. The plugin then calls `UEngine_registerPlugin(...)` to register its submenu.

### Auto-Detection (Process Match)

After `couldBeUnrealEngine()` returns true, scan manifests for an `executable` field matching the current process name via `extractFileNameWithoutExt`. On match, auto-`dofile` that plugin.

### Plugin Script Template

```lua
-- g1r-plugin.lua
-- Loaded by CE75.LUA plugin scanner, then self-registers

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

### Understanding the Architecture

The inventory system has two distinct layers:

1. **Generic UE → Character chain**: `GEngine` → `GameInstance` → `LocalPlayers[0]` → `PlayerController` → `Pawn/Character`. This is standard UE property walking — the property names vary (`Pawn`, `Character`, or `Owner`) but the core searches all three. This is **core**.

2. **Character → Gothic Item Manager**: `Char+0x7B0` → `Manager`. This is **not a UE property** — it's a hardcoded pointer at a fixed offset to a Gothic-specific singleton object. The Manager, Container, and InvMgr are Gothic game objects with no standard UE equivalent. This is **plugin**.

### Stays in Generic `CE75.LUA` (any UE4/UE5 game)

| Feature | What it does |
|---------|-------------|
| **GEngine discovery** | Finds `GEngine` pointer, registers CE symbol |
| **Name pool caching** | Discovers and caches FName table via pattern or AOB |
| **Object array** | Discovers `FUObjectArray` |
| **FProperty offset auto-discovery** | Walks memory to find Class/Name/Offset/Owner/Size/BitMask fields |
| **UClass/UStruct property enumeration** | Walks `PropertyLink` chain, gets all properties with offsets + types |
| **Structure dissect callbacks** | Hooks CE's structure dissect to auto-name UE objects |
| **Player / Character chain** | `GEngine` → `GameInstance` → `LocalPlayers[0]` → `PlayerController` → `Pawn/Character` — searches `Pawn`, `Character`, `Owner` fallback |
| **Player address list** | "Player (N props)" group with properties sorted by bucket (Movement, Network, Life, Flags, Components, etc.) with safety tiers `[S/C/U/P]` |
| **Player property hints** | Standard UE property names — `bCanBeDamaged`, `CharacterMovement`, etc. |
| **Debug: Search Character for Inventory Properties** | Generic keyword scan for "Inventory", "Item", "Backpack", "Bag" — finds standard UE properties only, won't find Gothic's custom Manager |
| **Format-agnostic name utilities** | `UEngine_itemShortName` (clean up to remove Gothic `ItXX_` special case — keep only generic 3–4 letter prefix stripping), `UEngine_itemPrettyName` — no game-specific prefix knowledge |

### Only with G1R Plugin (`Scripts/g1r/g1r-plugin.lua`)

| Feature | Why G1R-specific |
|---------|-----------------|
| **Inventory snapshot** | Hardcoded Gothic-only chain: `Char+0x7B0` → `Mgr+0x170` → `Cont+0x168` → `Inv+0x378` (0x7B0 is a Gothic Item Manager pointer, not a UE property) |
| **Equipped items** | 3 Gothic-specific TArray sources: `InvMgr+0x158`, `Manager+0x180` (CDOs), `Char+0x190` (Children/Visual) |
| **Item classification** | Parses Gothic `ItXX_` prefix naming convention (`ItMw_`=melee, `ItRw_`=ranged, `ItFo_`=food, `ItAr_`=magic, etc.) |
| **Real item names** | Loads `inventory_display_helper.lua` → Alkimia loc map → Gothic localized titles |
| **GNames fast-path** | `G1R-Win64-Shipping.exe` + `0x9AE6600` shortcut with validation fallback (the RVA is session-dynamic; if it reads 0 the plugin falls back to generic `FindNamePoolData` or FName-based AOB) |
| **Inventory address list** | "Inventory (X bag + Y equipped)" tree with Gothic item categories |
| **Live tracking** | Timer-based refresh of inventory display |
| **Display helper loading** | Locates `inventory_display_helper.lua` relative to the plugin's own folder |

---

## External Dependencies

Only one: **`inventory_display_helper.lua`** (in the plugin folder) — provides localization/display name resolution for Gothic items.

Exports consumed by the G1R plugin:
- `InventoryDisplay_InitFromNs(ns)`, `InventoryDisplay_InitFromEntry(entry)`, `InventoryDisplay_Init()` — init methods
- `InventoryDisplay_IsReady()` — check if loc map is built
- `InventoryDisplay_GetTitle(name)` — returns localized display name
- `ResolveItemDisplayName(name)` — fallback name resolver

**Optional** — without it, inventory shows technical names (e.g. `ItFo_Beer`).

---

## Path Sanitization — Developer-Specific Paths to Remove

| Location in current code | What's there | Action |
|--------------------------|-------------|--------|
| `UEngine_addPlayerToAddressList` | `io.open('/mnt/d/d/...CE75-PLAYER-PROPS.txt')` and `d:\d\gamehacking\...` | Remove all. Guard behind `UEngine.Player.dumpProps` flag if kept |
| `UEngine_displayHelperPaths` | 5 hardcoded absolute paths | Remove. Plugin-relative path from `debug.getinfo` is sufficient |
| `UEngine_loadDisplayHelper` error msg | `"...Paths tried under d:\\d\\gamehacking\\lua\\ and R:\\..."` | Change to generic `"Scripts/ subfolder"` reference |

---

## Plugin Registry & API

The core exposes a minimal API table to plugins. These use CE 7.5 APIs confirmed from source:

```lua
UEngine.PluginAPI = {
  -- Utilities
  log = log,
  registerPlugin = function(name, setupFn) ... end,

  -- UE chain walking (property-based, works on any game)
  getCharacter = UEngine_findCharacter,
  getLocalPlayer = UEngine_findLocalPlayer,
  enumerateProperties = UEngine_getAllProperties,
  resolveFName = UEngine_resolveFName,   -- via generic NamePoolData

  -- Generic name formatting (no game-specific prefixes)
  itemShortName = UEngine_itemShortName,
  itemPrettyName = UEngine_itemPrettyName,

  -- Address list helpers
  addressList = function() return getAddressList() end,
}
```

Plugins call `registerPlugin(name, setupFn)` where `setupFn` receives the parent menu item and adds submenu entries. The registry stores entries in `UEngine.Plugins.registry[name]`.

---

## Lifecycle Model

| Event | What happens |
|-------|-------------|
| **Core loaded (dofile)** | Runs `UEngine_CE75_ReloadCleanup` for prior state, scans `Scripts/` for manifests |
| **Core menu built** | Adds "Load Game Plugin ▸" with entries from scan results |
| **User clicks plugin** | Core `pcall(dofile)`'s the plugin's main file; plugin calls `registerPlugin(name, setupFn)` |
| **Game attached** | `couldBeUnrealEngine()` → discovery runs; if auto-detect matches a manifest's `executable`, auto-`dofile` that plugin |
| **Process switched** | Core re-runs discovery; old plugin menu entries gone, new scan builds fresh list |
| **Core re-loaded (re-dofile)** | `UEngine_CE75_ReloadCleanup` destroys all menu entries and plugin state |

No explicit unload mechanism — the tool targets one game per CE session.

---

## CE 7.5 API Constraints (from Source Code Audit)

These are confirmed from the CE 7.5 Pascal source at `/mnt/y/Lazarus/Projects/cheat-engine-7.5/Cheat Engine/`. The plan accounts for every item.

### Available (works as expected)

| API | Source file | Usage in plan |
|-----|------------|---------------|
| `getDirectoryList(path, subdirs)` | `LuaHandler.pas:13810-13893` | Plugin scanner: enumerate `Scripts/` subfolders |
| `getFileList(path, mask, subdirs)` | `LuaHandler.pas:13810-13893` | Plugin scanner: list manifest files |
| `fileExists(path)` | `LuaHandler.pas:16935-16936` | Verify `*-Plugin.LUA` exists |
| `createStringList():loadFromFile(path)` | `LuaStringlist.pas:312-342`, `LuaStrings.pas:268-310` | Parse manifest files |
| `createFileStream()` | `LuaHandler.pas:5078-5152` | Alternative file reading |
| `synchronize(func)` | `LuaHandler.pas:3665-3703` | Thread-safe UI updates |
| `createThread(func)` | `LuaThread.pas` | Background scanning, inventory refresh |
| `createTimer(MainForm)` | `LuaTimer.pas:70-82` | Live tracking, auto-add player |
| `MainForm.OnProcessOpened` (settable) | `MainUnit.pas:1086`, `LuaObject.pas:250-278` | Auto-detect game + plugin |
| `MainForm:findComponentByName(name)` | `LuaComponent.pas:26-38` | Find menu items by name |
| `createMenuItem(MainForm)` | `LuaMenu.pas` | Build dynamic menus |
| `registerStructureNameLookup(cb)` | `LuaHandler.pas:10174-10252` | Auto-name structures on dissect |
| `getAddressList()` → `:createMemoryRecord()` | `LuaAddresslist.pas:108-115` | Add player/inventory entries |
| `Mr:Type` (read/write VarType) | `LuaMemoryRecord.pas:332-343` | Set vtDword, vtPointer, etc. |
| `Mr.Aob.Size` (byte array size) | `LuaMemoryRecord.pas:1100-1102` | Set byte array size for StructProperty |
| `Mr.Binary.Size`, `Mr.Binary.Startbit` | `LuaMemoryRecord.pas:1100-1102` | Bool bit fields |
| `Mr:delete()` | `LuaMemoryRecord.pas:~1143` | Remove old address list entries |
| `Mr:getChild(index)` / `Mr.Child[index]` | `LuaMemoryRecord.pas:126-139,1119` | Traverse address list hierarchy |
| `Mr.DropDownValue[i]` / `Mr.DropDownDescription[i]` | `LuaMemoryRecord.pas:94-123,1071-1072` | Read existing dropdown items |
| `getStructure(i)` | `LuaStructure.pas` | Index-only access (see pitfalls) |
| `createStructure(name)` + `addToGlobalStructureList()` | `LuaStructure.pas` | Create dissect structures |
| `registerCustomTypeLua(...)` | `LuaCustomType.pas` | Register "UE FName to String" type |
| `AOBScan(pattern, flags)` | `LuaMemscan.pas` | GNames fallback discovery |

### NOT Available (constraints the plan)

| API | Status | Impact |
|-----|--------|--------|
| **JSON parser** | **Absent** — no cjson/dkjson in source | Manifest must use `Key=Value` format |
| **`registerStructureDissectOverride2`** | **Absent** — only v1 exists (`LuaHandler.pas:10174-10252`) | Use single-callback v1, not the chaining v2 |
| **`createMemoryRecord()` as global** | **Absent** — only on AddressList | Always call via `getAddressList():createMemoryRecord()` |
| **`Mr.IsGroupHeader`** | **Not exposed** in Lua bindings (`LuaMemoryRecord.pas`) | Set Description pattern instead. Use `[moHideChildren,...]` string in Address field |
| **`Mr.Collapsed`** | **Not exposed** | Cannot read/write expand state from Lua |
| **`Mr.Options` / `OptionCount`** | **Not exposed** | Must use address expression string hacks |
| **`Mr.ByteSize`** | **Not exposed as property** | Use `Mr.Aob.Size = N` instead for byte arrays |
| **DropDownList TStringList object** | **Object not exposed** (`LuaMemoryRecord.pas:1071-1072`) | **Cannot clear/add items from Lua**. Individual values readable via `DropDownValue[i]`, but no `:clear()` or `:add()`. The Bool dropdown AV is **unfixable from Lua alone**. Player address list uses `vtBinary` directly as a workaround, which is the correct approach. |

### Corrected DropDownList Guidance

The current CE75.LUA already handles this correctly — it uses `vtBinary` with `Binary.Startbit` and `Binary.Size` for bools instead of dropdown strings. The plan must ensure:
- **Plugin inventory code**: Never call `mr.DropDownList = '...'` or `mr.DropDownList:clear()` — these are Pascal-side objects only.
- **Bool display in address list**: Use `vtBinary` with `Binary.Startbit` and `Binary.Size`.

### Corrected Structure Dissect Guidance

Only the v1 `registerStructureDissectOverride` callback is available. It receives the structure and address, and returns `true`/`false`. The plan should NOT reference a v2 API.

The existing code in CE75.LUA already handles this correctly with its `UEngineStructDissect` path.

---

## Implementation Steps

### Step 1 — Extract G1R Plugin from CE75.LUA

Create `Scripts/g1r/g1r-plugin.lua` by moving these functions out of `CE75.LUA`. The core retains only generic UE logic.

| Function to move | Located at (current CE75.LUA line) |
|-----------------|-----------------------------------|
| `UEngine.Inv` defaults (offsets table) | ~4092-4107 |
| `UEngine_ensureGNames` (G1R-specific RVA + exe name) | ~4134-4164 |
| `UEngine_classifyItemName` (Gothic ItXX_ prefix classification) | ~4198-4320 |
| `UEngine_snapshotEquipped` | ~4433-4542 |
| `UEngine_snapshotInventory` | ~4544-4621 |
| `UEngine_buildInventoryAddressList` | ~4710-4882 |
| `UEngine_refreshInventoryAddressList` | ~4884-4923 |
| `UEngine_addInventoryToAddressList` | ~4925-4935 |
| `UEngine_setInventoryLiveTracking` | ~4937-4964 |
| `UEngine_loadDisplayHelper` | ~4988-5002 |
| `UEngine_lookupRealItemNamesAsync` | ~5004-5049 |
| `UEngine_logInventorySessionChecklist` | ~5052-5064 |

What stays in core:
- `UEngine_itemShortName` (make truly generic: remove `ItXX_`-specific branch, keep only the generic 3–4-letter prefix strip), `UEngine_itemPrettyName` — format-agnostic utilities
- `UEngine_resolveFName` — already generic (uses `UEngine.GNamesBase`)
- `UEngine_findInventory` (renamed) → `UEngine_searchCharacterProperties` — generic keyword scan
- `UEngine_findCharacter` — searches `Pawn`/`Character`/`Owner` fallback
- `UEngine_ensureGNames` is NOT needed in core — core already has `FindNamePoolData` + `CacheNamePool`

### Step 2 — Verify Core Has No Gothic Dependencies

After removing the plugin code, test that the core does NOT reference:
- `G1R-Win64-Shipping` (anywhere)
- Hardcoded RVA `0x9AE6600`
- Gothic prefixes `ItMw_`, `ItRw_`, `ItFo_`, `ItAr_`, `ItAt_`, etc.
- `inventory_display_helper.lua`
- `AlkimiaLocMap`, `AlkimiaFuzzy`, etc.

Any such reference belongs in the plugin.

### Step 3 — Create `Scripts/g1r/g1r.manifest`

```
name=Gothic 1 Remake
executable=G1R-Win64-Shipping
main=g1r-plugin.lua
helpers=inventory_display_helper.lua
```

Parsed via `createStringList():loadFromFile()` with key=value splitting.

### Step 4 — Implement Plugin Scanner in Core

Add to `CE75.LUA`:

```lua
function UEngine_scanPlugins()
  local src = debug.getinfo(1,'S').source
  local dir = src:sub(2):match('^(.*)[/\\]') or '.'
  local scriptsDir = dir .. '/Scripts'
  local folders = getDirectoryList(scriptsDir, false)
  local plugins = {}
  for _, folder in ipairs(folders or {}) do
    local mPath = scriptsDir .. '/' .. folder .. '/' .. folder .. '.manifest'
    local lPath = scriptsDir .. '/' .. folder .. '/' .. folder .. '-Plugin.lua'
    if fileExists(mPath) and fileExists(lPath) then
      local sl = createStringList()
      sl:loadFromFile(mPath)
      local entry = { folder = folder, main = lPath }
      for i = 0, sl.Count - 1 do
        local k, v = sl[i]:match('^([^=]+)=(.*)$')
        if k then entry[k:lower()] = v end
      end
      plugins[#plugins + 1] = entry
    end
  end
  return plugins
end
```

Add "Load Game Plugin ▸" dynamic menu in `UEngine_buildSuccessMenus`.

### Step 5 — Remove Developer Paths

Delete from `CE75.LUA`:
- `UEngine_displayHelperPaths` function entirely (or gut it to script-relative only)
- Debug file writes in `UEngine_addPlayerToAddressList` (or gate behind `UEngine.Player.dumpProps`)
- Update error message in `UEngine_lookupRealItemNamesAsync` to generic path reference

### Step 6 — Move inventory_display_helper.lua

Copy/relocate from `G1R/inventory_display_helper.lua` to `Scripts/g1r/inventory_display_helper.lua`.
Update its `GNAMES_RVA` logic: accept the GNames base from the plugin rather than recalculating.

### Step 7 — Core Chain Search (Pawn/Character/Owner)

In `UEngine_findCharacter` in core, ensure the PlayerController→Pawn step searches:
1. `Pawn` property first (UE4 default)
2. `Character` property fallback (G1R uses this)
3. `Owner` property fallback
4. Generic ObjectProperty ending in "Pawn"/"Character"/"Owner"

### Step 8 — Plugin GNames Strategy

In the plugin, `UEngine_ensureGNames` should:
1. Try `getAddress('G1R-Win64-Shipping.exe') + 0x9AE6600`
2. Validate by checking entry[0] reads as "None"
3. If invalid, fall back to a narrow FName-based AOB scan
4. Final fallback: use `UEngine.PluginAPI.namePoolData()` (the core's generic discovery)

---

## Final Menu Structure

```
Unreal Engine                              ← core always
├── Status
├── Prioritize this
├── Use when dissecting structures [✓]
├── ─────────────────
├── Add / Refresh Player (auto on load)
├── ─────────────────
├── Load Game Plugin ▸                    ← dynamic, populated from Scripts/
│   └── Gothic 1 Remake                   ← dofile Scripts/g1r/g1r-plugin.lua
├── ─────────────────
└── Debug
    └── Search Character for Inventory Props  ← generic keyword scan

--- After G1R plugin loads: ---

Unreal Engine
├── Status
├── Prioritize this
├── Use when dissecting structures [✓]
├── ─────────────────
├── Add / Refresh Player (auto on load)
├── ─────────────────
├── Gothic 1 Remake                       ← registerPlugin
│   ├── Add / Refresh Inventory Items
│   ├── Live track inventory changes
│   ├── Lookup real item names (once, background)
│   ├── Inventory session checklist (log)
│   ├── ─────────────────
│   └── Debug
│       └── Find Inventory Properties     ← G1R-specific (uses hardcoded chain)
├── ─────────────────
└── Debug
    └── Search Character for Inventory Props  ← core generic keyword scan
```

Key distinction: core Debug entry is renamed "Search Character for Inventory Props" to differentiate from the plugin's G1R-specific "Find Inventory Properties".
