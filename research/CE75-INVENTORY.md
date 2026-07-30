# Inventory System — Gothic 1 Remake (UE 5.4)

Inventory chain discovery, entry layout, game functions, breakpoint analysis.

See also: `CE75-REFERENCE.md` for CE 7.5 API, `CE75-DISSECT-CRASH.md` for dissect form crash.

---

## Inventory Chain — GEngine → Character

### Chain discovered and VERIFIED

```
GEngine
  +GI offset → GameInstance
    +LP offset → LocalPlayers (TArray)
      [0] → LocalPlayer
        +PC offset → PlayerController
          +Character offset → Character (PlayerCharacterBP_C)
            +0x7B0 → Manager (inventory manager UObject)
              +0x170 → Container
                +0x168 → InventoryManager
                  +0x378 → ArrayBase (0xB8 stride entries)
```

**Verified 2026-07-24**: `07_test_full_chain.lua` returns 318 items, 65 empty, 383 total — matches game UI.

**All offsets are found dynamically** via `UEngine_getAllProperties()` at runtime.

In this game, the property on PlayerController that leads to the Character object is named `Character` (not the stock UE4 name `Pawn`). Our code searches for `Pawn` first, then falls back to `Character`/`Owner` matches. Example offsets from one session (will vary):

| Step | Property name (this game) | Typical Offset |
|------|---------------------------|---------------|
| GameEngine → GameInstance | `GameInstance` | ~0x10A8 |
| GameInstance → LocalPlayers | `LocalPlayers` | ~0x38 |
| LocalPlayers[0] → LocalPlayer | array element [0] | +0 |
| LocalPlayer → PlayerController | `PlayerController` | ~0x30 |
| PlayerController → Character | `Character` | ~0x2E0 |
| Character → Manager | hardcoded | **+0x7B0** (fixed offset, validated 2026-07-24) |

### How the address expression works

`UEngine_setChainAddress` builds a CE pointer expression string:
```lua
mr.Address = "[[[[[[GEngine+10A8]+38]+0]+30]+2E0]+7B0]"
```

Breaking down:
1. `[GEngine+10A8]` — dereference GEngine pointer + GameInstance offset → GameInstance
2. `[...+38]` — dereference GameInstance + LocalPlayers offset → TArray data pointer
3. `[...+0]` — dereference array data + 0 → first element (LocalPlayer)
4. `[...+30]` — dereference LocalPlayer + PlayerController offset → PlayerController
5. `[...+2E0]` — dereference PlayerController + Character offset → Character
6. `[...+7B0]` — dereference Character + 0x7B0 → **Manager** (fixed offset)
7. From Manager, follow inventory chain: `+0x170 → Container → +0x168 → InvMgr → +0x378 → Array`

This approach survives process restarts because the symbol `GEngine` is re-resolved each time.

### PlayerController: Pawn and Character = same object

Both the `Pawn` property (inherited from `AController`) and a game-specific `Character` property on PlayerController point to the **same** Character object address. Our code's fallback search for `Character` is correct.

---

## Inventory Chain — Manager (CONFIRMED via breakpoint)

### Discovered chain

```
Manager (0x1527C78CA00)          ← RCX at exe+59F9BA0, stable across sessions
  +0x170 → Container (0x151C9031580)
    +0x048: packed(3,4) — small TArray
    +0x058: packed(14,16) — 14 inventory categories
    +0x168 → InventoryManager (0x151C82CE040)
      +0x370: 2 (active categories?)
      +0x378 → Array Base = 0x1514EEA0000
      +0x380: packed(383,400) — count, capacity
```

**Manager found by:** breakpoint at `exe+59F9BA0`, reading RCX.
**NOT found by:** scanning GEngine, scanning heap, scanning Character (coarse step missed it, Character address unknown).

---

## Inventory Entry

**Stride:** 0xB8. **Count:** 383. **318 occupied.**

```
+0x00: QWORD  packed(slot index in low 32, flags in high 32)
+0x08: QWORD  UObject* (AddRef'd)
+0x10: DWORD  count (quantity)
+0x18–+0x98:  mostly zeros (sparse region)
+0xA0: QWORD  hash/GUID (unique per item, NOT category data)
+0xA8: QWORD  hash/GUID (unique per item, NOT category data)
+0xB0: zero
```

**Confirmed items:** ItAt_Razor_01, ItAt_Scavenger_02, ItAr_Scroll_TransformBloodfly, HumanFist_NoWeapon, etc.

---

## Item UObject Structure (2026-07-24)

### 0x300-byte repeating sub-objects

The item UObject pointer at entry+0x08 does NOT point to a single object. It points to an **array of sub-objects**, each **0x300 bytes**. All sub-objects share:

| Field | Value | Description |
|-------|-------|-------------|
| +0x00 | vtable `0x7FF654E6BEC8` | Same for all sub-objects (module range) |
| +0x10 | Class `0x2B8EF86B780` | Same class for all sub-objects |
| +0x20 | `0x2B8B219D400` | Shared pointer (template/default data?) |

Each sub-object has a **different** NameIndex and +0x40 pointer:

| Index | Offset | NameIndex | +0x40 |
|-------|--------|-----------|-------|
| 0 | +0x000 | 0xB196C3 | 0x2B99BA51000 |
| 1 | +0x300 | 0xB196B5 | 0x2B99BA5BE00 |
| 2 | +0x600 | 0xB196A8 | 0x2B99BA51C00 |
| 3 | +0x900 | 0xB19699 | — |
| 4 | +0xC00 | 0xB1968C | — |
| 5 | +0xF00 | 0xB1967F | — |
| 6 | +0x1200 | 0xB1966E | — |
| 7 | +0x1500 | 0xB19661 | — |
| 8 | +0x1800 | 0xB19655 | — |
| 9 | +0x1B00 | 0xB1964B | — |

NameIndices decrement by ~13 per step. This may represent item variants, inventory slots, or sub-components.

### Item properties at known offsets

| Offset | Value | Notes |
|--------|-------|-------|
| +0x20 | `0x2B8B219D400` | Shared across all sub-objects — likely template/default object |
| +0x30 | `0x2B998E40010` | Heap pointer |
| +0x38 | `9` | Small integer — count or type indicator |
| +0x40 | different per sub-object | Per-item data |
| +0x58 | `0x0000000800000368` | Packed data |
| +0x70, +0x78 | `0x2B8CA69B600` | Same pointer, text "(9(T" — truncated or encoded |
| +0xE0 | `0x2B8E1590B00` | Same as base class in hierarchy |
| +0xB0 | `0x7FF651555CA0` | Module pointer (vtable?) |

### No display name on UObject

Display names ("Transform Into Bloodfly") are NOT stored as pointers on the item UObject. They are resolved at UI render time from a localization system.

### No category on UObject or entry

Categories are NOT stored in the entry structure (+0xA0/+0xA8 are hashes) or at exe+88E7258 (UTF-16 text). Category assignment is likely on the item class or in a DataTable.

### AOBScan results for item names

- **"Bloodfly"**: 2660 matches in heap (0x2B8xxxxxxx) — FName strings, asset paths, class names
- **"ItAr_"**: 2521 matches in heap — item class/asset names (e.g., `ItAr_Rune_IceBlock`, `ItAr_Scroll_Trfmeatbug`)
- **No localized display names** found in module or heap — these are resolved at render time

### Definition Objects (item+0x70)

The +0x70 field on each item UObject points to a **definition object** — a separate UObject that describes the item type. Multiple inventory slots of the same item type share the same definition object.

**Example from first 30 items:**
| Definition | Slots | Vtable |
|------------|-------|--------|
| `0x2B8CA777A80` | 0,1,2,9,16 | `0x7FF654283738` |
| `0x2B8C8016800` | 4,7,8,10-15,17-29 | `0x7FF654281708` |
| `0x2B8CA7A8F00` | 5,6,19 | `0x7FF654283738` |
| `0x2B8CA69B600` | 3 | `0x7FF654283928` |

**Definition object layout:**
| Offset | Value | Description |
|--------|-------|-------------|
| +0x00 | vtable | Different per item type |
| +0x10 | Class pointer | Different per item type |
| +0x18 | NameIndex | Appears to be pointer-like (large value, not standard FName index) |
| +0x20 | Small value | Hash or ID (0x68F41C, 0x690D6F, 0x50762D, 0x69070C) |
| +0x28 | 0x45 (69) | Consistent across all — type ID or flags |
| +0x48 | self+0x80 | Always = definition_ptr + 0x80 |
| +0x70 | 0x2B8E159D300 | Parent class (same across ALL definitions) |
| +0x80 | vtable | Matches +0x00 |

**Key finding**: +0x70 is the item type identifier. This is per-type, NOT per-instance.

### Item class hierarchy (5 levels deep)

```
0x2B8EF86B780 (0x3EEFC) — item-specific class (PropertyLink at +0x30)
  → 0x2B8E159D300 (0x217) — parent
    → 0x2B8E159D800 (0xFF53) — grandparent
      → 0x2B8E159DA80 (0x25AF4) — great-grandparent
        → 0x2B8E1590B00 (0x1F9) — base class (UObject?)
```

### PropertyLink at UClass+0x30

The UClass at `0x2B8EF86B780` has a PropertyLink at **+0x30** (NOT +0x88 as assumed from UE5 defaults):
- `class+0x30` = `0x2B8EF8704F0` — FField with ClassPrivate=`0x2B8E1590B30`, Next=`0x2B8E159D330`
- This is the start of the FProperty chain — needs to be walked to find display name, category, icon properties

### What we still need

1. **Walk PropertyLink chain** — find all FProperty fields (display name, category, icon)
2. **Find localization table** — maps internal names → display text
3. **Find category system** — where item categories are defined
4. **Understand 0x300 structure** — what the sub-objects represent

### PropertyLink Search Results (2026-07-24)

**Result: PropertyLink NOT FOUND at any standard offset.**

| Offset Range | Result |
|--------------|--------|
| +0x30 | SuperStruct chain list (4 pointers to ancestor class+0x30) |
| +0x60 to +0x800 | Zero candidates with score ≥ 3 |

The item class (`0x2B8EF86B780`) has no FProperty chain at any tested offset. This means either:
- The item class is a data-only class with no FProperty fields
- Properties are stored in a separate structure (DataTable, DataAsset)
- The PropertyLink offset is non-standard (>0x800)

**See `CE75-DISPLAY-NAMES.md` for alternatives to find display names and categories.**

### Entry +0xA0/+0xA8 are NOT category data

Both fields contain random-looking 64-bit values that differ across every item. They are NOT category IDs and NOT lookup keys (searching heap for these values found nothing). They may be FDateTime timestamps, GUIDs, or content hashes.

### Category bytes at exe+88E7258 are NOT category IDs

Bytes 0–3 are `3, 4, 6, 5` (looked like category IDs). But bytes 8–31 decode as UTF-16: `&ThisClass::`. This is a UE5 reflection path string, not a category mapping. The first 4 bytes are coincidental.

---

## Inventory Search — Status

`UEEngine_findInventory()` searches `PlayerCharacterBP_C` + parent classes for properties matching: `Inventory`, `Item`, `Backpack`, `Bag`, `Loot`, `Equipment`, `Gear`, `Storage`, `Slot`, `Weapon`, `Ammo`, `Container`.

**Result:** No matches found. Property dump of `PlayerCharacterBP_C` shows all fields but none match the search terms.

**Root cause found via breakpoint analysis (2026-07-24):**

The inventory is NOT stored as a property on the Character object. Instead:

1. Inventory entries are stored as **separate structs** in memory, each containing:
   - `+0x00`: item metadata (packed values, not a pointer)
   - `+0x08`: UObject* to the item object
   - `+0x10`: int32 count (quantity)

2. Item objects are of class `ASClass` (e.g., `ItAt_Scavenger_02` = Scavenger Skull)
3. The `ASClass` has **no properties via PropertyLink** — it inherits everything from parent classes
4. Brute-force comparison of Character/PC/GI property data against the entry data found **no match** — the entry is NOT embedded in any of these objects directly

**Why search failed:** `UEEngine_searchPropsOnObject` only walks the SuperStruct PropertyLink chain. The inventory container is either:
- On a **Component** attached to the Character (UE5 pattern)
- On a **separate manager object** reachable through a different path
- Referenced indirectly via a non-standard mechanism

### Investigation methodology (from helper scripts)

**Approach 1 — Property brute-force** (`investigate_inventory.lua`):
For each known object (Character, PlayerController, GameInstance, LocalPlayer):
1. Walk SuperStruct hierarchy via PropertyLink + PropertyLinkAlt
2. For each property, read its value as a pointer
3. Check: does the value directly equal the entry address?
4. Check: dereference as TArray — is the entry address within `[dataPtr, dataPtr + count * stride)`?
5. Check: if the value is another UObject, walk ITS properties and check inner arrays
**Result:** No match found on any object. Container is not embedded in Character/PC/GI.

**Approach 2 — ASClass hierarchy** (`investigate_inventory2.lua`):
Walk the ASClass SuperStruct chain (ASClass → AActor → ... → UObject). At each level:
1. Check PropertyLink for array properties
2. Check PropertyLinkAlt for additional properties
3. For each property, read value from the item UObject, dereference, check if entry address is in range
**Result:** ASClass has no PropertyLink entries at any level. Item objects contain no array data.

**Approach 3 — RDX deep dump** (`investigate_inventory2.lua`):
RDX at breakpoint was `0x1503C11BCB0`. Dumped 64 bytes, checked each qword:
- If it's a heap pointer, check if it's a UObject (read +0x10 for Class)
- Check if +0x10 points to a container structure
**Result:** RDX is not a container. No inventory-related data found.

**Approach 4 — GEngine chain scan** (`find_fresh_manager.lua`, `find_via_gengine.lua`):
Scan GEngine memory (level 0: GEngine itself, level 1: dereferenced pointers) looking for any UObject that has the inventory chain pattern:
```
ptr → +0x170 → vftable in module range (container)
           → +0x168 → vftable in module range (InventoryManager)
                   → +0x378 → heap pointer (array base)
                   → +0x380 → packed count in valid range
```
Scanned GEngine up to +0x3000, then dereferenced each heap pointer and scanned +0x2000.
**Result:** No match. Manager is not reachable from GEngine chain.

**Approach 5 — Heap scan for manager pointer** (`find_char_to_mgr.lua`):
Coarse scan of heap range `0x15000000000 — 0x15300000000` (step 0x10000) for any pointer to the known manager address. Then fine scan ±0x10000 around container and InventoryManager.
**Result:** No back-pointers to manager found in heap. Manager is only reachable via the breakpoint register (RCX).

**Approach 6 — AOBScan for array base** (`find_array_owner.lua`):
AOBScan for the 8-byte pattern of the array base address. Also scanned for the entry address.
**Result:** Array base not found as a pointer anywhere in memory. Entry not found as a pointer. The array is accessed inline (not through a pointer indirection).

### Conclusions from investigation

1. The inventory manager is a **game-specific object** not derived from standard UE5 classes
2. It is **not embedded** in Character, PlayerController, GameInstance, or LocalPlayer
3. It is **not reachable** from GEngine via property chain
4. The only known access point is the **breakpoint at exe+59F9BA0** (RCX = manager)
5. The manager address is **stable across sessions** (same address each time)
6. The array base is **not pointer-indirected** — accessed inline in the function

---

## Game Functions (exe+ addresses)

### exe+59F9BA0 (14-category iterator)
- rcx = Manager
- Loops 14 times (bl 0–13)
- `[r15+0x170]` → container → `exe+59D42F0(container+0x40, &counter)` → entries + count
- Copy loop stride 0xB8, memcopy via exe+53AC610, AddRef via exe+12C3E00

### exe+59DED6C (drop operation)
- `sub [rbx+10], r14d` — decrement item count
- Calls through to exe+139E2B3 → vtable call `[r9+0x268]`

### exe+555C0CC (single item processing)
- RBX = entry address directly in array
- RSI = InventoryManager + 0x340

### exe+5BD9340 (item copy)
- RAX = slot index (0x51 = 81)
- RSI = entry count (0x12E = 302)

---

## Breakpoint Registers

### exe+59F9BA0 (category iterator)
| Reg | Value | Meaning |
|-----|-------|---------|
| RCX/R15 | 0x1527C78CA00 | **Manager** |
| R14 | 0x1502BD5D9A0 | set by caller |

### exe+555C0CC (item processing)
| Reg | Value | Meaning |
|-----|-------|---------|
| RBX | 0x1514EEA3A38 | entry 81 in array |
| RSI | 0x151C82CE380 | InventoryManager + 0x340 |

### exe+5BD9340 (item copy)
| Reg | Value | Meaning |
|-----|-------|---------|
| RAX | 0x51 (81) | slot index |
| RSI | 0x12E (302) | entry count |

### exe+139E2B3 (drop vtable call)
| Reg | Value | Meaning |
|-----|-------|---------|
| RDI | 0x152B232D980 | object being called (NOT manager) |

### Cross-path register correlation

Registers consistent across breakpoint paths 2 & 3:
| Reg | Value | Meaning |
|-----|-------|---------|
| RBP | 0x1514EEB1348 | entry + 0xD910 — possible container base (NOT confirmed) |
| R12 | 0x1526188A4C8 | consistent across paths — unknown purpose |
| R14 | 0x151CC5D9A28 | close to R15 (2 bytes apart) — pair of values |
| R15 | 0x151CC5D9A2A | close to R14 — pair of values |

Entry structure confirmed across all paths:
- Path 1: `mov eax,[rsi+0C]` = `[entry+0x10]` = count (65)
- Path 2: `cmp qword ptr [rbx+08],00` = `[entry+0x08]` = UObject* null check
- Path 3: `mov eax,[rdi+10]` = `[entry+0x10]` = count (65), `lea rdx,[rdi+18]` = data starts at +0x18

---

## Helper Scripts

Location: `/home/malware/projects/ue-scan-gothic/`

### Working scripts

| Script | Purpose |
|--------|---------|
| `inventory_final.lua` | Complete inventory listing from manager. Walks chain: manager→container→invMgr→arrayBase, iterates all entries, resolves item names via NamePool |
| `list_items2.lua` | Item lister with verification. Confirms UE5 FName offset (+0x18) vs old UE4 offset (+0x0C) |

### Investigation scripts (reusable patterns)

| Script | Purpose |
|--------|---------|
| `find_fresh_manager.lua` | `checkManagerChain()` — validates inventory chain pattern on any UObject (vftable checks at each level). Scans GEngine + heap for any object matching the chain |
| `find_via_gengine.lua` | `checkChain()` — cleaner version of chain validation. Scans GEngine level 0 + level 1 |
| `investigate_inventory.lua` | Container investigation: tests both TArray layouts, brute-force property matching against Character/PC/GI |
| `investigate_inventory2.lua` | ASClass hierarchy walk (PropertyLink + PropertyLinkAlt), RDX deep dump, deep container search (dereferences Object properties, checks inner arrays) |
| `register_dump_and_scan.lua` | Master analysis: all 3 breakpoint paths correlated, memory scans for entry/RBP/item pointers, saves results to file. Entry structure confirmation |

### New approach scripts (2026-07-24)

| Script | Approach | Purpose |
|--------|----------|---------|
| `find_components_on_character.lua` | A | Walk Character's OwnedComponents TArray (UE5 native component array, NOT UPROPERTY). Tries known offsets (+0x190, +0x188, etc.) then pattern scan. Resolves component class names, matches inventory keywords. **Result: Character found but no OwnedComponents at any tested offset — Gothic uses non-standard layout.** |
| `find_subsystems.lua` | B | Scan GameInstance and LocalPlayer for subsystem storage arrays. Resolves class names, matches inventory keywords. Checks for manager pointer |
| `find_caller_of_manager_func.lua` | C | AOBScan for CALL instructions targeting exe+59F9BA0. Disassembles backward to find how RCX (manager) is loaded. Identifies property offset on source object |

---

## What's Missing

1. **Automate the full chain** — update `CE75.LUA` / `inventory_final.lua` to dynamically resolve +0x7B0 and build the complete pointer chain: `GEngine → GI → LP → PC → Char+0x7B0 → Manager → +0x170 → Container → +0x168 → InvMgr → +0x378 → Array`
2. **Manager class name** — NamePool broken, can't resolve yet. Not blocking.
3. **Session restart validation** — verify +0x7B0 offset holds across game restarts

---

## Proposed Next Approaches (2026-07-24)

Three new approaches based on UE5 architecture research. All are distinct from the 6 approaches already tried (property brute-force, ASClass hierarchy, RDX dump, GEngine scan, heap scan, AOBScan).

### Approach A: Component Enumeration on Character

**Rationale:** UE5 standard pattern — inventory is typically a `UActorComponent` subclass attached to the Character. Every UE5 Actor stores its components in a native `TArray` (OwnedComponents) that is NOT part of the UPROPERTY reflection chain. Our existing `UEngine_getAllProperties()` only walks PropertyLink — it cannot see components.

**Why this hasn't worked before:** All 6 previous approaches scanned properties via PropertyLink or scanned raw memory. None walked the Actor's native component array.

**UE5 offset reference** (from community SDK dumps):

| Field | UE5.0 | UE5.1 | UE5.2 | UE5.3 | UE5.4 | UE5.5 |
|-------|-------|-------|-------|-------|-------|-------|
| `AActor::OwnedComponents` | +0x170 | +0x178 | +0x180 | +0x188 | +0x190 | +0x198? |
| `AActor::RootComponent` | +0x198 | +0x1A0 | +0x1A8 | +0x1B0 | +0x1B8 | +0x1C0 |

**Warning:** Gothic 1 Remake may use a custom engine fork that shifts these offsets. Must validate dynamically.

**TArray layout:**
```
+0x00: T* Data (heap pointer to array elements)
+0x08: int32 ArrayNum (current count)
+0x0C: int32 ArrayMax (allocated capacity)
```

Each element is a `UActorComponent*` — a UObject with standard layout (+0x00 vftable, +0x10 ClassPrivate, +0x18 NameIndex).

**Plan:**
1. Get Character address from GEngine chain
2. Try known offsets for OwnedComponents: +0x190, +0x188, +0x180, +0x178, +0x170
3. For each offset, read TArray and validate: dataPtr in heap, count in 5-50, capacity >= count
4. Walk each component: read vftable (must be in module range), resolve class name via NamePool
5. Look for names containing: Inventory, Item, Container, Equipment, Backpack, Manager, Storage
6. If not found at known offsets, pattern-scan Character memory for TArray pattern
7. If found, dump component properties via `UEngine_getAllProperties()`

**Script:** `find_components_on_character.lua`

---

### Approach B: Subsystem Enumeration on GameInstance

**Rationale:** UE5 Subsystems (`UGameInstanceSubsystem`, `ULocalPlayerSubsystem`) are auto-instantiated and stored on their owner. Games commonly use subsystems for manager classes. Epic docs: "Mandatory when creating manager classes (e.g., Quest Manager, Sound Manager, Economy Manager)."

**Why this hasn't worked before:** We've never checked if Gothic uses a subsystem for inventory. Subsystems are stored in an internal array on GameInstance, not via standard UPROPERTY, so they don't appear in `UEngine_getAllProperties()`.

**Subsystem types:**
| Subsystem | Lifetime | Access via |
|-----------|----------|------------|
| `UGameInstanceSubsystem` | Launch to exit | `GameInstance->GetSubsystem<T>()` |
| `ULocalPlayerSubsystem` | Player creation to destruction | `LocalPlayer->GetSubsystem<T>()` |
| `UWorldSubsystem` | Level load to unload | `World->GetSubsystem<T>()` |

**Plan:**
1. Get GameInstance from GEngine chain
2. Scan GameInstance memory for subsystem storage — look for a `TArray<USubsystem*>` pattern (heap pointer + count 1-20)
3. Walk each subsystem, resolve class name
4. Also check LocalPlayer for `ULocalPlayerSubsystem` instances
5. Look for names containing: Inventory, Item, Container, Equipment, Manager, Save, Economy, Player
6. If found, dump subsystem properties

**Script:** `find_subsystems.lua`

---

### Approach C: Find Caller of exe+59F9BA0

**Rationale:** The function at `exe+59F9BA0` receives the manager in RCX. Someone calls this function with the manager address. Finding the caller reveals how the manager is stored — property offset on some object, local variable, or global.

**Why this hasn't worked before:** We've analyzed registers at the breakpoint but never looked at the caller. The caller must load RCX with the manager address before the call — that instruction reveals ownership.

**Script:** `find_caller_of_manager_func.lua`

---

## Approach C — Detailed Implementation Plan

### Prerequisites

- Module base: `exe = getAddress("G1R-Win64-Shipping.exe")`
- Module size: `MODSIZE = getModuleSize("G1R-Win64-Shipping.exe")`
- Target function: `exe + 0x59F9BA0`
- Manager address: `0x1527C78CA00` (from breakpoint, stable across sessions)

### Step 1: Verify Target Function

Read first 16 bytes of `exe+59F9BA0` to confirm it's valid code (not data or a jump target). Log the bytes for manual verification.

### Step 2: Find Direct CALL Instructions (E8 rel32)

**⚠️ THIS APPROACH IS INVALID** — confirmed by breakpoint analysis (2026-07-24, session 2).

The function at `exe+59F9BA0` is called through a vtable or function pointer. The return address on the stack (`0x2B8B338F030`) is in the heap, not in the code section. There are no direct E8 CALL instructions targeting this function.

**Correct approach:** Use CE's **Call Stack** view when the breakpoint hits. This shows the full call chain including the indirect caller.

### Step 3: Find Indirect CALL Instructions (FF 15 / FF 50)

**⚠️ NOT VIABLE via static scan** — the indirect call goes through a vtable or function pointer at runtime. The target is computed dynamically, not stored in a fixed location.

**Correct approach:** When the breakpoint at `exe+59F9BA0` hits, use CE's **Call Stack** view. The stack frame above the current function shows the caller. Read the caller's address, then disassemble backward from there.

### Step 4: Disassemble Backward from Caller

Once we have the caller's address from the call stack:

1. Set a breakpoint at the caller's address
2. When it hits, examine how RCX was loaded before the call
3. The RCX load instruction reveals the property offset

| Pattern | Opcode | Example | Meaning |
|---------|--------|---------|---------|
| MOV RCX, [RIP+disp32] | `48 8B 0D xx xx xx xx` | Load from global variable | RCX = *(callAddr + 7 + disp) |
| MOV RCX, [RREG+disp32] | `48 8B 48 xx` (mod=2) | Load from object property | RCX = *(RREG + disp32) |
| MOV RCX, [RREG+disp8] | `48 8B 48 xx` (mod=1) | Load from nearby property | RCX = *(RREG + disp8) |
| MOV RCX, RREG | `48 89 xx` or `4C 8B xx` | Copy from another register | RCX = RREG (trace RREG backward) |
| LEA RCX, [RREG+disp32] | `48 8D 48 xx` | Compute address | RCX = RREG + disp32 |
| MOV RCX, imm32 | `48 C7 C1 xx xx xx xx` | Load immediate | RCX = constant (unlikely for pointer) |
| MOV RCX, imm64 | `48 B9 xx xx xx xx xx xx xx xx` | Load 64-bit immediate | RCX = 64-bit constant |

**Disassembler logic:**

```
for offset = 40 downto 0:
    addr = callAddr - offset
    byte = readByte(addr)
    
    if byte in {0x48, 0x4C}:  -- REX.W or REX.WR prefix
        nextByte = readByte(addr + 1)
        if nextByte == 0x8B:  -- MOV
            parse ModRM at addr + 2
            if destination == RCX:
                record RCX load instruction
        elif nextByte == 0x8D:  -- LEA
            parse ModRM at addr + 2
            if destination == RCX:
                record RCX load instruction
        elif nextByte == 0xC7:  -- MOV reg, imm32
            parse ModRM at addr + 2
            if destination == RCX:
                record RCX load instruction
        elif nextByte == 0xB9:  -- MOV RCX, imm64
            record RCX load instruction
    
    elif byte == 0xE8:  -- CALL rel32 (nested call, skip backward)
        offset -= 5
```

### Step 5: Analyze RCX Load Instruction

Once we identify the caller (from call stack), disassemble backward to find how RCX was loaded. Common patterns:

| Pattern | Example | Meaning |
|---------|---------|---------|
| `MOV RCX, [RREG+disp]` | `mov rcx, [rbx+0x170]` | Manager at offset 0x170 on object in RBX |
| `MOV RCX, [RIP+disp32]` | `mov rcx, [rip+0x1234]` | Load from global variable |
| `MOV RCX, RREG` | `mov rcx, r15` | Copy from another register (trace backward) |
| `LEA RCX, [RREG+disp]` | `lea rcx, [rbx+0x170]` | Address computation (embedded struct) |

### Step 6: Cross-Reference with Known Objects

For each discovered property offset:

1. **Check breakpoint registers:** When exe+59F9BA0 was hit, what was in the base register?
   - RCX = `0x2BA46527B40` (manager itself)
   - RBX = `0x2BA4ACB1858` (unknown object — possible source)

2. **Check if base register points to a known object:**
   - Character at `0x2BA2056F340`
   - PlayerController at `0x2BA4F685A40`
   - GameInstance at `0x2B90CBC2C80`
   - LocalPlayer at `0x2B9884E3740`

3. **If base register = Character + known offset:**
   - The offset is the Character → Manager link (solves the puzzle)

4. **If base register = some other object:**
   - The offset reveals a new intermediate object in the chain
   - Follow that object back to Character or another known object

### Step 7: Validate the Link

Once a candidate offset is found:

1. Read the pointer at `objectAddr + offset`
2. Confirm it equals the known manager address (`0x1527C78CA00`)
3. Verify the object is reachable from the GEngine chain
4. If validation passes, the Character → Manager link is solved

### Expected Outcomes

**Best case:** Find `mov rcx, [rXX+0xYYY]` where rXX points to Character or a known object. The offset 0xYYY is the property that holds the manager. This directly solves the Character → Manager link.

**Moderate case:** Find the RCX load but rXX points to an unknown object. We now have a new intermediate object to investigate, narrowing the search.

**Worst case:** No CALL instructions found (function called indirectly via vtable). Fall back to Approach B (subsystem scan) or suggest manual breakpoint analysis.

### Risk Assessment

**Low risk** — read-only memory scanning, no writes, no hooks.

**Key uncertainty:** The function is called indirectly (vtable/function pointer). Static AOB scanning cannot find the caller. The call stack approach requires manual interaction with CE's debugger.

### Performance

| Method | Time |
|--------|------|
| Breakpoint + call stack | <1 second (manual, CE GUI) |
| Disassemble backward from caller | <1 second (Lua script) |

The call stack approach is both faster and more accurate than static scanning.

---

### Implementation Order

1. ~~**Approach A first** — most likely to succeed (UE5 standard pattern, new approach)~~ **❌ Eliminated** — Gothic Character does not use standard UE5 OwnedComponents layout. Character found at `0x2BA2056F340` but no component array at any tested offset.
2. ~~**Approach C second** — gives concrete info about how the manager is stored.** NOW FIRST PRIORITY.~~ **❌ Partially invalidated** — Approach C (caller analysis) traced the call stack through the GC hook, not the inventory code path. The manager IS passed in RCX but the caller is the garbage collector, not inventory code. We still know `exe+5A02300` calls `exe+59F9BA0` but the caller of `exe+5A02300` is the GC.
3. ~~**Approach B third** — if C fails, subsystem is the last standard UE5 pattern~~ **Not yet tried** — subsystem enumeration could still reveal the manager.
4. **GNames search** — CRITICAL BLOCKER for item names. See `CE75-GNAMES-PROPOSAL.md`.
5. **Manager global pointer scan** — scan module .data for manager vftable or manager address. See "Revised Approach" below.

---

## Approach A — Detailed Implementation Plan

### Prerequisites
- GEngine chain working (GEngine → GI → LP → PC → Character)
- NamePool resolution working (exe + 0x9AE6600, chunkIdx = NameIndex // 65536)
- CE 7.5 API constraints (no readDword, use readInteger/readQword, handle 0x prefix from fl.Address)

### Step 1: Get Character Address
Reuse existing GEngine chain logic from `CE75.LUA` / `inventory_final.lua`.

### Step 2: Find OwnedComponents TArray

**Method 2a — Known offset scan:**
Try offsets in order of likelihood for UE5.4:
```lua
local TRY_OFFSETS = {0x190, 0x188, 0x180, 0x178, 0x170, 0x070}
```

For each offset:
```lua
local base = charAddr + offset
local dataPtr = readQword(base)       -- +0x00: array data pointer
local count = readInteger(base + 8)   -- +0x08: ArrayNum
local max = readInteger(base + 0xC)   -- +0x0C: ArrayMax
```

Validate:
- `dataPtr` must be in heap range (0x10000000000 - 0x20000000000)
- `count` must be in range 3-100 (typical component count)
- `max` must be >= count
- `count * 8` must not exceed 0x1000 (sanity check)

**Method 2b — Pattern scan (if known offsets fail):**
Scan first 0x400 bytes of Character memory for a valid TArray:
```lua
for off = 0, 0x400, 8 do
    local dataPtr = readQword(charAddr + off)
    if dataPtr and isHeap(dataPtr) then
        local count = readInteger(charAddr + off + 8)
        local max = readInteger(charAddr + off + 0xC)
        if count and count >= 3 and count <= 100 and max and max >= count then
            -- Validate first element
            local firstElem = readQword(dataPtr)
            if firstElem and isMod(readQword(firstElem)) then
                -- This looks like a valid component array
            end
        end
    end
end
```

### Step 3: Walk Components

For each element in the validated array:
```lua
for i = 0, count - 1 do
    local compPtr = readQword(dataPtr + i * 8)
    if compPtr and compPtr ~= 0 then
        local vftable = readQword(compPtr)
        if vftable and isMod(vftable) then
            -- Valid UObject
            local classPtr = readQword(compPtr + 0x10)  -- ClassPrivate
            local nameIdx = readInteger(compPtr + 0x18)  -- NameIndex
            local className = resolveClassName(classPtr)
            local objName = resolveName(nameIdx)
            -- Log and check for inventory-related names
        end
    end
end
```

### Step 4: Identify Inventory Component

Match against keywords:
```lua
local INVENTORY_KEYWORDS = {
    "inventory", "item", "container", "equipment", "backpack",
    "manager", "storage", "loot", "gear", "weapon", "ammo",
    "bag", "satchel", "pocket", "stash", "vault"
}
```

Case-insensitive substring match on resolved class names.

### Step 5: Dump Properties of Found Component

If an inventory-related component is found:
```lua
local classPtr = readQword(compPtr + 0x10)
local props = UEngine_getAllProperties(classPtr)
-- Walk properties, look for TArray entries that could be item arrays
```

### Step 6: Cross-Reference with Known Manager

If a component is found, check if it contains a pointer to the known manager address (from breakpoint):
```lua
for name, info in pairs(props) do
    local val = readQword(compPtr + info.offset)
    if val == knownManagerAddr then
        print("FOUND: Component contains manager pointer!")
    end
end
```

### Expected Outcomes

**Best case:** Find a UActorComponent subclass on Character with inventory-related name, containing a pointer to the manager or the item array. This solves the Character → Manager link.

**Moderate case:** Find components but none are inventory-related. This narrows the search — inventory is NOT a component on Character, supporting the subsystem or other hypotheses.

**Worst case:** Component array not found at any offset. This suggests Gothic uses a non-standard pattern or the Character object layout differs significantly from stock UE5.

### Risk Assessment

**Low risk** — read-only memory scanning, no writes, no hooks. Same pattern as existing scripts.

**Key uncertainty:** The OwnedComponents offset for Gothic's specific UE5 build. The RejiDev table shows +0x190 for UE5.4, but custom forks may differ. The pattern-scan fallback handles this.

---

## Approach A — Execution Results (2026-07-24)

### Character Successfully Located

`UEngine_findCharacter()` from `CE75.LUA` returned Character at **`0x2BA2056F340`**.
GEngine chain: GEngine → GI (`0x2B90CBC2C80`) → LP (`0x2B9884E3740`) → PC (`0x2BA4F685A40`) → Character.
Chain offsets: 4264 → 56 → 0 → 48 → 720.

### Memory Dump — Key Offsets

```
+0x000: 0x7FF6553E0490  (vftable, module range ✓)
+0x008: 0x000407E300000048  (ObjectFlags = 0x48)
+0x010: 0x2B8FB3FE860  (ClassPrivate, heap pointer)
+0x018: 0x7FFF61950007E3DA  (NameIndex — non-standard, large value)
+0x050: 0x2BA2056F340  (self-pointer — Character points to itself)
+0x070–+0x138: ALL ZERO — no component array here
+0x140: 0x2BA4F685A40  (PlayerController address — matches chain)
+0x188: 0x2BA2056F340  (second self-pointer)
+0x190: 0x2BB3BB2CAC0  (heap pointer, but +0x198 = 0x0000001800000004 — not valid TArray)
+0x2C8–+0x2D0: 0x2BA4F685A40  (PC address again, two redundant references)
```

### What Was Checked

| Offset | What we looked for | Result |
|--------|-------------------|--------|
| +0x190 (UE5.4 default) | OwnedComponents TArray | ❌ +0x198 = 0x4 (not valid count/capacity) |
| +0x188 | Alternate offset | ❌ Self-pointer, not an array |
| +0x180, +0x178, +0x170 | Older UE5 offsets | ❌ Float values (0x40BD0CC4, 0x40400000), not pointers |
| +0x070 | Non-standard offset | ❌ Zero |
| +0x00–+0x068 | Early struct area | ❌ UObject header fields only |
| +0x200–+0x300 | Extended scan | ❌ Mixed data, no valid TArray pattern |

### Conclusion

**Gothic 1 Remake does NOT use the standard UE5 OwnedComponents layout on Character.**

The Character's first 0x300 bytes contain:
1. Standard UObject header (+0x00–+0x18) with non-standard NameIndex
2. Large zero region (+0x070–+0x138) — no component array
3. Scattered pointers (+0x140–+0x2D0) including redundant PlayerController references
4. No valid TArray pattern (heap_ptr + count + capacity) at any tested offset

**Root cause:** Gothic runs a custom UE5 engine fork that restructured `AActor`. The OwnedComponents array is either:
- At a much higher offset (beyond +0x300)
- Stored via a different mechanism (not a native TArray)
- Not present on the Character class at all (inventory may be elsewhere)

### Impact on Inventory Investigation

This eliminates **Approach A** (component enumeration) as a viable path. The Character does not expose its components in the standard UE5 way.

**Remaining approaches:**
| Approach | Status | Script |
|----------|--------|--------|
| ~~A: Component Enumeration~~ | ❌ Eliminated — Gothic does not use standard UE5 OwnedComponents | `find_components_on_character.lua` |
| B: Subsystem Enumeration | ⬜ Not yet tried | `find_subsystems.lua` |
| C: Caller Analysis | ⬜ Not yet tried | `find_caller_of_manager_func.lua` |

### Next Steps

1. **Approach C** — Use CE's call stack to find who calls `exe+59F9BA0`. The function is called via vtable/function pointer (return address is in heap `0x2B8B338F030`, not code section). Once we have the caller, disassemble backward to find how RCX (manager) was loaded. That reveals the property offset.

2. **Approach B** — scan GameInstance (`0x2B90CBC2C80`) and LocalPlayer (`0x2B9884E3740`) for subsystem storage arrays. The manager may be a `UGameInstanceSubsystem` rather than a component on Character.

3. **Extended Character dump** (+0x300 to +0x800) — if the above fail, check whether the component array exists at a higher offset on the Character. Some custom engine forks move OwnedComponents deep into the struct.

---

## Approach C — Execution Results (2026-07-24, session 2)

### Breakpoint at exe+59F9BA0

First instruction: `48 89 5C 24 08` (mov [rsp+08], rbx)

**Registers:**
| Reg | Value | Meaning |
|-----|-------|---------|
| RCX | `0x2BA46527B40` | **Manager** (new session address) |
| RBX | `0x2BA4ACB1858` | Unknown object |
| RSI | `0x730` (1840) | Likely a count or size |
| RDI | `0xA` (10) | Likely a category index |
| RIP | `0x7FF6526A9BA0` | Inside exe+59F9BA0 |

**Stack (at RSP = `0xF9A357EE28`):**
| Address | Value | Meaning |
|---------|-------|---------|
| `[RSP]` | `0x2B8B338F030` | Return address — in heap (see note below) |
| `[RSP+8]` | `0x3FA0000000000000` | Old value (will be overwritten by prologue) |

### Note on Return Address

The return address `0x2B8B338F030` is in the heap range. This initially suggested an indirect call. However, call stack analysis revealed the actual caller is at `G1R-Win64-Shipping.exe+5A02672` which is a **direct E8 call**. The heap return address may be due to a wrapper or trampoline between the direct caller and `exe+59F9BA0`.

---

## Call Chain (discovered 2026-07-24, session 2)

### Chain: ??? → exe+5A02300 → exe+59F9BA0

```
Unknown caller
  calls G1R-Win64-Shipping.exe+5A02300 (manager in RCX)
    calls G1R-Win64-Shipping.exe+59F9BA0 (manager in RCX, DIRECT call at exe+5A02672)
```

### G1R-Win64-Shipping.exe+5A02300 (14-category processing + iterator call)

**Receives manager in RCX. Saves it in R12.**

Manager offsets read by this function:

| Offset | Type | Purpose |
|--------|------|---------|
| `+0x3A` | byte | Flags (bit 2 tested) |
| `+0x3C` | float | Value 0.50 (written after flag check) |
| `+0x90` | ptr | Some sub-object (used for virtual calls) |
| `+0x150` | ptr | Data pointer (copied via memcpy) |
| `+0x158` | int32 | Count (number of entries to copy) |
| `+0x161` | byte | Flag (cleared after processing) |
| `+0x162` | byte | Flag (checked, controls flow to iterator call) |
| `+0x164` | float | Timer/cooldown (decremented by xmm6 parameter) |
| `+0x170` | ptr | Container — used to look up items by category |

**Flow:**
1. Reads `manager+0x164` (float timer), subtracts xmm6 (delta time?), writes back
2. If timer > 0, copies entries from `manager+0x150` (count at `manager+0x158`)
3. For each entry, checks flag byte at entry+0x08, reads item data at entry+0x04
4. Calls `G1R-Win64-Shipping.exe+59EAF80` with `manager+0x170` as container
5. If `manager+0x162` flag set, does more processing with `manager+0x090` sub-object
6. Loops through 4 category bytes at `G1R-Win64-Shipping.exe+88E7258`
7. For each category, calls `G1R-Win64-Shipping.exe+59D42F0` to get entries
8. Iterates entries with stride **0xB8** (confirming known inventory stride)
9. **Calls `G1R-Win64-Shipping.exe+59F9BA0` at exe+5A02672** (the 14-category iterator)

**Key instruction at the call site:**
```
G1R-Win64-Shipping.exe+5A0266A - mov rcx, [rsp+90]    ; restore manager (saved at entry)
G1R-Win64-Shipping.exe+5A02672 - call G1R-Win64-Shipping.exe+59F9BA0
```

### G1R-Win64-Shipping.exe+357A890 (sub-call with manager->field_0x28)

**Also receives manager in RCX. Saves it in RDI.**

```
G1R-Win64-Shipping.exe+357A8A4 - mov rbx, [rcx+28]     ; rbx = manager->field_0x28
G1R-Win64-Shipping.exe+357A8B3 - mov rdi, rcx           ; rdi = manager
...
G1R-Win64-Shipping.exe+357A95C - mov rcx, [rdi+28]     ; rcx = manager->field_0x28
G1R-Win64-Shipping.exe+357A960 - mov r9, rdi            ; r9 = manager (4th param)
G1R-Win64-Shipping.exe+357A96D - call [rax+3C8]         ; virtual call on manager->field_0x28
```

**Note:** This function also receives the manager directly. It is NOT in the call chain between exe+5A02300 and exe+59F9BA0. It may be called from a different path.

### G1R-Win64-Shipping.exe+3E7DC30 (entry collector — analyzed from paste)

**Receives manager in RCX. Saves it in R13.** This is the function whose epilogue contains the `jmp` at `exe+3E7DDFF` seen in the call stack.

**Signature:** `(rcx=manager, edx=index, r8b=flag)`

**Manager offsets used:**
| Offset | Type | Purpose |
|--------|------|---------|
| +0x28 | ptr | Start of entry data region (entries at manager+0x28 + i*0x30) |
| +0x980 | TArray\<ptr\> | Collected entry pointers (data at +0x980+0x20, count at +0x980+0x28, capacity at +0x980+0x2C) |
| +0x9B0 | int32 | Count of entries in +0x980 array |

**Entry stride in this function:** 0x30 (different from inventory iterator's 0xB8)

**Behavior:**
1. Validates via 4 check functions
2. Checks global singleton at `exe+9D1DF50`
3. Gets object from `exe+100DBC0`, stores manager at `[obj+0x50]`, index at `[obj+0x58]`
4. Dispatches through vtable+0x60 on the object
5. Loops from index to count, reading entries at `manager+0x28 + i*0x30`
6. For each entry with type >= 0x32, creates event object and appends to `manager+0x980` TArray
7. Updates count at `manager+0x9B0`
8. Tail-calls `jmp G1R-Win64-Shipping.exe+3E7DF74` (epilogue) — this is why `exe+3E7DDFF` appears in call stack as return address

**Critical:** This function does NOT load the manager from a property. The manager is passed as RCX. The property load happens in the **caller** of this function.

---

## Approach C — Disassembly Analysis: G1R-Win64-Shipping.exe+3E7DC30

### Context

The call stack when `exe+59F9BA0` is hit shows:
```
exe+59F9BA0   ← breakpoint here (manager iterator)
exe+3E7DDFF   ← return address shown in call stack
exe+3E66F90
exe+357A890
exe+5A02300
exe+59F9BA0
```

The address `exe+3E7DDFF` was investigated by disassembling the containing function at `G1R-Win64-Shipping.exe+3E7DC30`.

### Function Signature

```
G1R-Win64-Shipping.exe+3E7DC30(G1R-Win64-Shipping.exe+3E7DC30.rcx, G1R-Win64-Shipping.exe+3E7DC30.edx, G1R-Win64-Shipping.exe+3E7DC30.r8b)
```

| Parameter | Register | Saved to | Meaning |
|-----------|----------|----------|---------|
| rcx | RCX | r13 | **Object pointer** (NOT loaded from property — passed as argument) |
| edx | EDX | ebx | Integer index/category |
| r8b | R8 | ebp | Boolean flag |

### Key Finding: Manager is NOT loaded from a property in this function

The first parameter (manager) is received directly via RCX and saved to r13 at `+3E7DC5C`:
```
G1R-Win64-Shipping.exe+3E7DC5C - 4C 8B E9  - mov r13, rcx
```

This means **the property load that provides the manager happens in the CALLER of this function**, not inside it. The caller loads the manager from some object's property into RCX before calling this function.

### Function Behavior

**Initial checks** (+3E7DC5F–+3E7DC93):
- Calls 4 validation functions (exe+1170610, exe+11231A0, exe+11C79D0, exe+105A3F0)
- If any check fails, jumps to `+3E7DE04` (alternate path)

**Global singleton check** (+3E7DC93–+3E7DC9D):
```
G1R-Win64-Shipping.exe+3E7DC93 - mov rax, [G1R-Win64-Shipping.exe+9D1DF50]   ; load global pointer
G1R-Win64-Shipping.exe+3E7DC9A - cmp [rax], r12d                              ; check count != 0
G1R-Win64-Shipping.exe+3E7DC9D - je G1R-Win64-Shipping.exe+3E7DE04            ; skip if empty
```

**Manager is STORED into an object** (+3E7DCBE–+3E7DCC2):
```
G1R-Win64-Shipping.exe+3E7DCBE - mov [rcx+50], r13    ; store manager at obj+0x50
G1R-Win64-Shipping.exe+3E7DCC2 - mov [rcx+58], ebx    ; store index at obj+0x58
```
This writes the manager INTO an object — it does NOT read it from one.

**Virtual dispatch via rdi** (+3E7DCD0–+3E7DD48):
- Reads `rdi+0x68` → ref-counted pointer (lock inc at +0x38)
- Calls `exe+3E86670` with the ref-counted pointer
- Reads `rax+0x60` → vtable function pointer
- Calls through vtable: `call rsi` at +3E7DD48

**Cleanup loop** (+3E7DD70–+3E7DD90):
- Iterates array of ref-counted pointers
- `lock xadd [rcx+38], -1` for refcount release
- If refcount reaches 0, calls destructor at `ffxOpticalflowResourceIsNull+BFD0`

**Second check block** (+3E7DDC1–+3E7DDEB):
- Re-tests the same 4 validation functions from the entry
- If all pass, calls `exe+100DBC0` and dispatches through vtable+0x48
- Then **jumps to epilogue** at +3E7DF74

**The critical jump** at +3E7DDFF:
```
G1R-Win64-Shipping.exe+3E7DDFF - E9 70010000 - jmp G1R-Win64-Shipping.exe+3E7DF74
```
This is a `jmp` to the function epilogue (stack canary check + ret). It is NOT a call to `exe+3E66F90`.

**Loop over inventory entries** (+3E7DE16–+3E7DF4F):
```
G1R-Win64-Shipping.exe+3E7DE16 - movsxd rsi, [r13+000009B0]   ; rsi = manager+0x9B0 (entry count)
G1R-Win64-Shipping.exe+3E7DE25 - movsxd r15, ebx               ; r15 = index parameter
G1R-Win64-Shipping.exe+3E7DE28 - cmp rsi, r15                  ; compare count vs index
G1R-Win64-Shipping.exe+3E7DE2B - jg G1R-Win64-Shipping.exe+3E7DF5B  ; skip loop if count > index
```

Loop body computes entry address using stride **0x30** (NOT 0xB8 — different from the inventory iterator):
```
G1R-Win64-Shipping.exe+3E7DE31 - lea rbp, [rsi+rsi*2]     ; rbp = rsi * 3
G1R-Win64-Shipping.exe+3E7DE3D - shl rbp, 04               ; rbp = rsi * 48 (0x30)
G1R-Win64-Shipping.exe+3E7DE44 - add rbp, 28               ; rbp = rsi * 0x30 + 0x28
G1R-Win64-Shipping.exe+3E7DE48 - add rbp, r13               ; rbp = manager + 0x28 + rsi * 0x30
```

Each iteration at +3E7DE50–+3E7DF3F:
1. Checks `[rbp+00]` (entry type/index at stride 0x30)
2. Calls `exe+100DBC0` to get object
3. Dispatches through vtable+0x60 with entry pointer
4. Checks validation flags (same 4 checks)
5. If entry type >= 0x32 (50), creates an event object and calls `exe+3E868E0`
6. Stores result in `manager+0x980` (TArray — append entry to list)
7. Increments `manager+0x9B0` (count) after loop

**TArray append pattern** at +3E7DECF–+3E7DF33:
```
G1R-Win64-Shipping.exe+3E7DECF - lea rdi, [r13+00000980]    ; rdi = manager+0x980 (TArray)
G1R-Win64-Shipping.exe+3E7DF09 - movsxd r14, [rdi+28]       ; r14 = current count
G1R-Win64-Shipping.exe+3E7DF0D - lea eax, [r14+01]          ; new count = old + 1
G1R-Win64-Shipping.exe+3E7DF11 - mov [rdi+28], eax          ; store new count
G1R-Win64-Shipping.exe+3E7DF14 - cmp eax, [rdi+2C]          ; compare vs capacity
G1R-Win64-Shipping.exe+3E7DF17 - jna G1R-Win64-Shipping.exe+3E7DF24  ; skip realloc if ok
G1R-Win64-Shipping.exe+3E7DF19 - mov edx, r14d              ; old count
G1R-Win64-Shipping.exe+3E7DF1C - mov rcx, rdi               ; TArray this
G1R-Win64-Shipping.exe+3E7DF1F - call ffxOpticalflowResourceIsNull+D510  ; grow array
G1R-Win64-Shipping.exe+3E7DF24 - mov rax, [rdi+20]          ; data pointer
G1R-Win64-Shipping.exe+3E7DF2F - mov [rdi+r14*8], rbx       ; store entry pointer at data[count]
```

This reveals **manager+0x980** is a TArray of pointers (stride 8 bytes per element), used to collect entries.

**Final count update** at +3E7DF6D:
```
G1R-Win64-Shipping.exe+3E7DF6D - mov [r13+000009B0], r12d   ; store final count at manager+0x9B0
```

### Manager Offsets Used by This Function

| Offset | Type | Purpose |
|--------|------|---------|
| +0x28 | ptr | Starting offset for entry data (entries at manager+0x28 + i*0x30) |
| +0x50 | ptr | Stored INTO an external object (not read from manager) |
| +0x980 | TArray\<ptr\> | Array of collected entry pointers (data at +0x980+0x20, count at +0x980+0x28, capacity at +0x980+0x2C) |
| +0x9B0 | int32 | Count of entries in the +0x980 array |

### Global Addresses Referenced

| Address | Purpose |
|---------|---------|
| `G1R-Win64-Shipping.exe+9A353F8` | Stack canary / security cookie |
| `G1R-Win64-Shipping.exe+9D1DF50` | Global singleton pointer (checked for non-zero count) |
| `G1R-Win64-Shipping.exe+9D1DF68` | Second global singleton pointer (checked later in loop) |

### Critical Conclusion

**This function does NOT contain the call to `exe+3E66F90` that appeared in the call stack.** The address `exe+3E7DDFF` in the call stack is a `jmp` to the epilogue, not a call instruction. The call stack entry is explained by **tail-call optimization**: the compiler emitted `jmp` instead of `call + ret`, so the return address on the stack still points to `exe+3E7DDFF` as if it were a normal return.

**The manager is loaded by the CALLER of this function, not within it.** To find the property offset, we need to:
1. Identify who calls `G1R-Win64-Shipping.exe+3E7DC30`
2. Disassemble backward from that call site to find `mov rcx, [reg+0x???]`
3. The `???` is the property offset we need

### Next Step

**Set a breakpoint at `G1R-Win64-Shipping.exe+3E7DC30`** (the first instruction: `push rbx`). When it hits:
1. Check RCX — should be the manager address
2. Open **View → Call Stack**
3. The frame above shows the caller
4. That caller contains a `mov rcx, [reg+0x???]` — the offset we need

Alternatively, disassemble backward from the return address shown in the call stack frame above `exe+3E7DC30` to find where RCX was loaded.

---

## ⚠️ FUNDAMENTAL RETHINK (2026-07-24) — GC Path Discovery

### What happened

Breakpoint was set at `G1R-Win64-Shipping.exe+3E7DC30`. It fires **immediately** — before the inventory UI is even opened. Two call stacks were captured:

**Call stack 1 — before inventory opened:**
```
G1R-Win64-Shipping.exe+3E83055
G1R-Win64-Shipping.exe+396342B
G1R-Win64-Shipping.exe+379B05C
UE4SS.RC::Unreal::Hook::StartCallbackGarbageCollector+5C8  ← GARBAGE COLLECTOR
G1R-Win64-Shipping.exe+3FA3534
G1R-Win64-Shipping.exe+3FAAB0C
G1R-Win64-Shipping.exe+3FAAB8A
G1R-Win64-Shipping.exe+3FAB9B0
G1R-Win64-Shipping.exe+3FB3C84
G1R-Win64-Shipping.exe+73E95C2
KERNEL32.BaseThreadInitThunk+17
ntdll.RtlUserThreadStart+2C
```

**Call stack 2 — with inventory open:**
```
G1R-Win64-Shipping.exe+3E83055
G1R-Win64-Shipping.exe+39633B0  ← 0x91 bytes different from stack 1
G1R-Win64-Shipping.exe+379B05C
UE4SS.RC::Unreal::Hook::StartCallbackGarbageCollector+5C8  ← SAME GC HOOK
...identical from here down...
```

### The discovery

**Both call stacks are the garbage collector.** The function at `exe+3E7DC30` is called by UE4SS's GC hook, NOT by inventory code. It fires every frame regardless of whether the inventory UI is open.

This means **we have NEVER seen the actual inventory code path.** Every breakpoint hit, every call stack, every register dump we've collected — all of it was from the garbage collector scanning the manager object, not from inventory operations.

### What this invalidates

| Previous assumption | Reality |
|---------------------|---------|
| `exe+3E7DC30` is an "entry collector" called by inventory code | It's a **GC scanning function** called every frame |
| The call stack `exe+59F9BA0 → exe+3E7DDFF → exe+3E66F90 → exe+357A890 → exe+5A02300 → exe+59F9BA0` is the inventory path | It's the **GC path** — the garbage collector scanning the manager |
| `exe+3E66F90` dispatches inventory events | It's part of the **GC type system** — dispatching type-specific scanning |
| We need to trace the caller of `exe+3E7DC30` to find the Character → Manager property | The caller is the **GC runtime**, not inventory code. There is no property to find on this path. |
| The manager is stored as a property on Character or another object | The manager is a **global UObject singleton** — the GC finds it through its own root scanning, not through a property chain |

### What we know for certain (unchanged)

1. **Manager address is stable** — `RCX` at `exe+59F9BA0` = manager, same address across sessions
2. **Inventory chain works** — `manager → +0x170 → container → +0x168 → invMgr → +0x378 → arrayBase` (0xB8 stride)
3. **`exe+59F9BA0` processes inventory** — 14 categories, 0xB8 stride entries
4. **`exe+5A02300` calls `exe+59F9BA0`** — direct E8 call at `exe+5A02672`

### What the GC call stacks tell us

The GC path is: `GC hook → exe+3E83055 → exe+396342B → exe+3E7DC30 → exe+3E66F90 → exe+357A890 → exe+5A02300 → exe+59F9BA0`

This tells us:
1. **The manager is a UObject** — the GC scans it, which means it has a standard UObject header (vftable, ObjectFlags, ClassPrivate, NameIndex)
2. **The manager is a root object** — the GC finds it through its root scanning (reachable from a global or stack root)
3. **The manager has custom GC behavior** — `exe+3E7DC30` is a type-specific GC scanning function for the manager's class. It walks the manager's internal data structures (stride 0x30 entries at +0x28, collecting into +0x980 TArray) as part of mark-and-sweep
4. **The GC calls `exe+5A02300` → `exe+59F9BA0`** to scan the manager's inventory sub-objects (the 14 categories with 0xB8 stride)

### Manager is a global UObject singleton

Since the GC finds the manager through root scanning (not through a property on Character), the manager must be:
- **A global pointer** in the module's `.data` or `.rdata` section, OR
- **Referenced from a global array** (like `GUObjectArray`), OR
- **A CDO (Class Default Object)** of an inventory manager class

This explains why:
- The manager address is stable across sessions (it's at a fixed offset from the module base)
- No property chain from Character leads to it (it's not stored on Character)
- The GC scans it independently (it's a root object)
- All 6 property-based approaches failed (the manager isn't a property anywhere)

### Updated manager offset map

From all analyzed functions combined:

| Offset | Type | Source function | Purpose |
|--------|------|-----------------|---------|
| +0x28 | ptr | exe+3E7DC30 (GC) | Entry data region start (stride 0x30, GC-scanned) |
| +0x3A | byte | exe+5A02300 (inv) | Flag (bit 2 tested) |
| +0x3C | float | exe+5A02300 (inv) | Value 0.50 |
| +0x90 | ptr | exe+5A02300 (inv) | Sub-object for virtual calls |
| +0x150 | ptr | exe+5A02300 (inv) | Data pointer (memcpy source) |
| +0x158 | int32 | exe+5A02300 (inv) | Count for +0x150 data |
| +0x161 | byte | exe+5A02300 (inv) | Flag (cleared after processing) |
| +0x162 | byte | exe+5A02300 (inv) | Flag (controls flow) |
| +0x164 | float | exe+5A02300 (inv) | Timer/cooldown |
| +0x170 | ptr | exe+5A02300 (inv) | **Container** → inventory chain entry |
| +0x980 | TArray\<ptr\> | exe+3E7DC30 (GC) | GC-collected entry pointers |
| +0x9B0 | int32 | exe+3E7DC30 (GC) | Count of +0x980 entries |

---

## Revised Approach: Finding the Manager via Global Pointer Search

### New hypothesis

The manager is stored as a **global pointer** in the game module's data section. The inventory UI code reads this global to get the manager address.

### Why this is the most likely path

1. The manager is a UObject singleton — global pointers are how singletons are stored in C++/UE5
2. The GC finds it via root scanning — global variables are GC roots
3. The address is stable across sessions — global variables are at fixed offsets from module base
4. No property chain leads to it — it's not embedded in any object

### Approach D: Scan Module Data Section for Manager Pointer

**Plan:**
1. Get module base address: `exe = getAddress("G1R-Win64-Shipping.exe")`
2. Get module size: `MODSIZE = getModuleSize("G1R-Win64-Shipping.exe")`
3. Read the PE headers to find `.data` and `.rdata` section offsets
4. Scan those sections for the 8-byte pattern of the manager address
5. Each hit is a potential global pointer to the manager
6. For each hit, disassemble the code nearby to see if it loads the pointer and uses it for inventory operations

**Key challenge:** The manager address changes per session. We need to either:
- Use the current session's manager address for the scan, OR
- Scan for a pointer to the manager that's stable (e.g., a pointer to a pointer)

**Alternative:** Scan for the manager's vftable pointer. The vftable is in the code section and is stable. The manager object's first qword is its vftable. So we can scan the data section for the vftable address, then check if the pointer at that location is the manager.

**Script:** New script needed — `find_manager_global.lua`

### Approach E: Set Breakpoint at exe+5A02300 (Direct Caller of Inventory Iterator)

**Rationale:** `exe+5A02300` calls `exe+59F9BA0` directly (E8 at `exe+5A02672`). If we set a breakpoint here, we can differentiate between:
- **GC path:** fires every frame, call stack goes through UE4SS GC hook
- **Inventory path:** fires only during inventory operations, call stack goes through game UI code

**Plan:**
1. Set breakpoint at `G1R-Win64-Shipping.exe+5A02300`
2. Open inventory UI and interact with it
3. When breakpoint hits, check call stack
4. If call stack does NOT go through UE4SS GC hook → this is the inventory path
5. Trace up the call stack to find the game function that loads the manager

**Key insight:** When the breakpoint fires, compare the call stack with the known GC path. Any stack that does NOT contain `UE4SS.RC::Unreal::Hook::StartCallbackGarbageCollector` is the inventory path.

**Script:** New script needed — `find_inventory_entrypoint.lua`

### Approach F: Use UE4SS Console Commands

**Rationale:** UE4SS is loaded and hooks the GC. It may have exposed the manager through console commands or Lua API.

**Plan:**
1. Open UE4SS console (if available)
2. Try console commands: `obj list`, `obj dump`, `gc`, `stat memory`
3. Look for inventory-related objects in the output
4. The manager's class name will reveal its identity

**Alternative:** Write a UE4SS Lua mod that:
1. Hooks `UGameInstance::Init` or `UWorld::Tick`
2. Scans for the manager object using the inventory chain pattern
3. Logs the manager address and class name

### Approach G: Find Manager by Name/Class

**Rationale:** The manager is a UObject with a name and class. If we can find its class name, we can search for it directly.

**Plan:**
1. Read the manager's ClassPrivate: `readQword(managerAddr + 0x10)`
2. From ClassPrivate, get the class name via NamePool
3. Once we know the class name (e.g., `UInventoryManagerComponent`, `UGothicInventorySubsystem`), we can:
   - Search for objects of that class in the object array
   - Find where the class is instantiated
   - Trace back to the global that holds the instance

**Script:** Extend `inventory_final.lua` to read the manager's class and name

---

## Implementation Priority

**Updated 2026-07-24** based on actual script results.

| Priority | Approach | Effort | Expected Outcome | Status |
|----------|----------|--------|------------------|--------|
| ~~1~~ | ~~Scan Character for manager back-pointer~~ | ~~5 min~~ | ~~Find offset where Character stores manager address~~ | **❌ Script 06 negative — no back-pointer found** |
| ~~2~~ | ~~Read manager class/name~~ | ~~5 min~~ | ~~Identify what the manager IS~~ | **Blocked by missing GNames** |
| 1 | **Find GNames via orearmor anchors** | 30 min | Script 26 — `CE75-GNAMES-PROPOSAL.md` Step 0 | **Ready** |
| 2 | **UE4SS console** | 5 min | May reveal GNames or item data directly | ⬜ |
| 3 | **Breakpoint at exe+5A02300** | 15 min | Find the actual inventory code path (different from GC path) | ⬜ |
| 4 | **Scan module data section for manager** | 30 min | Find the global pointer to the manager (manager is a global UObject singleton) | ⬜ |
| 5 | **Build final automated inventory script** | 30 min | Automate complete chain with names | ⬜ After GNames found |

**Key change:** The Character → Manager back-pointer approach (script 06) was **negative** — the manager is a global UObject singleton, not stored as a property on Character. The manager is found by the GC through root scanning, not through a property chain.

---

## Manager Object Analysis (2026-07-24)

### Script 1 output

```
Manager address: 0x2BA46527B40
Vftable:         0x7FF655237400  (module range ✓ — valid UObject)
ClassPrivate:    0x2B8EF9D6000   (heap)
NameIndex:       0x49457 (300119) — resolves to garbage via NamePool

Raw dump:
  +0x00: 0x7FF655237400  (vftable, module range ✓)
  +0x08: 0x407FE00040048 (ObjectFlags)
  +0x10: 0x2B8EF9D6000   (ClassPrivate ptr)
  +0x18: 0x49457          (NameIndex — broken NamePool)
  +0x20: 0x2BA2056F340   ← CHARACTER ADDRESS!
  +0x28: 0x7FF655237920  (vftable, module range ✓)
  +0x30: 0x7FF6548ABF40  (vftable, module range ✓)
  +0x38: 0x3F000000021C0002
```

### Key finding: manager+0x20 = Character

The manager has a direct pointer to the Character at offset +0x20. This is a concrete bidirectional link:

```
Character ←→ Manager
  (at some offset)    (at +0x20)
```

If we find the Character → Manager offset, the full chain becomes:
```
GEngine → GI → LP → PC → Character → [offset] → Manager → +0x170 → container → inventory
```

### NamePool broken

Old offset `exe+0x9AE6600` returns null chunk pointers. The NamePool has shifted between sessions.

- `exe+0x9AE6600`: Chunk[0] = 0x0 (broken)
- `exe+0x9AE6AE0`: Candidate from data scan — "AnimMontage'/Game/AnimLibrary/C..." (looks valid)
- Character NameIndex `0x7E3DA` resolves to "GothicGameUserSettings" (wrong — confirms broken NamePool)

**Impact:** Can't read manager class name yet. Not blocking if back-pointer approach works.

### Revised approach: scan for back-pointer

Instead of tracing call stacks through the GC path (which we now know is NOT the inventory code), scan Character memory for the manager address. If found at offset X:

1. CE pointer expression: `[[[[[GEngine+GI]+LP]+PC]+Char]+X]` → manager
2. From manager, follow known chain: `+0x170 → container → +0x168 → invMgr → +0x378 → array`

**Script:** `06_scan_character_for_manager.lua`

### What the GC discovery changed

| Before | After |
|--------|-------|
| `exe+3E7DC30` is an "entry collector" | It's a GC scanning function |
| `exe+3E66F90` dispatches inventory events | It's part of the GC type system |
| The call stack is the inventory path | The call stack is the GC path |
| Manager is stored as a property on some object | Manager is a global UObject singleton |
| Need to trace callers to find property offset | Need to scan for back-pointer or global |

### What stayed the same

- Manager address stable across sessions
- Inventory chain works: `manager → +0x170 → container → +0x168 → invMgr → +0x378 → array`
- `exe+59F9BA0` processes inventory (14 categories, 0xB8 stride)
- `exe+5A02300` calls `exe+59F9BA0` directly

---

## GNames (FNamePool) Search Status (2026-07-24)

### Problem

Item NameIndices are known (e.g., `0xB1A8C7` for slot 0) but cannot be resolved to strings because the GNames (FNamePool) global pointer has not been found.

### UE5 FNamePool Structure

```c
struct FNamePool {
    FRWLock Lock;           // 0x00 (8 bytes)
    uint32_t CurrentBlock;  // 0x08
    uint32_t CurrentByteCursor; // 0x0C
    uint8_t* Blocks[8192];  // 0x10 — array of chunk pointers
};

struct FNameEntry {
    uint16_t Header;    // bit 0 = isWide, bits 6-15 = length (Format A)
                        // OR bit 0 = isWide, bits 1-11 = length (Format B, newer UE5)
    char Data[];        // ANSI or UTF-16, no null terminator
};
```

**Resolution formula**: `block = Index >> 16`, `offset = Index & 0xFFFF`, `entry = Blocks[block] + offset * 2`

**Validation**: Entry 0 must be "None". Next entries: "ByteProperty", "IntProperty", "FloatProperty" (registered at startup in stable order).

### Approaches Tried

| # | Approach | Result | Details |
|---|----------|--------|---------|
| 1 | Module data scan (0x9800000–0x9B00000) | 614 candidates | None had entry[0] = "None" |
| 2 | Heap scan (0x2B8B–0x2B8C, 0x2B8E–0x2B8F) | 1 candidate | False positive — weak validation gave garbage |
| 3 | Old offset exe+0x9AE6600 | Returns 0 | NamePool has moved between sessions |
| 4 | Candidate exe+0x9AE6AE0 | Not verified | "AnimMontage'/Game/...' visible nearby |
| 5 | Chunks offsets: 0x00, 0x08, 0x10, 0x20, 0x40 | All failed | No offset produced valid "None" entry |
| 6 | Strides: 2, 4 | Both failed | Neither produced valid results |
| 7 | BlockOffsetBits: 14, 16 | Both failed | Neither produced valid results |

### Why validation failed

The definitive test is: `FNamePool.Blocks[0] → entry[0] must == "None"`. All 614 module candidates and 1 heap candidate failed this test.

**Possible causes:**
1. GNames pointer is NOT in the module's .data section (it's on the heap or in a dynamic structure)
2. The chunks offset is non-standard (>0x40 or at an unusual location)
3. The FNameEntry header format is different (XOR-encrypted, or different bit layout)
4. The FNamePool is stored as a member of another object (not a standalone global)
5. The FNameBlockOffsetBits is neither 14 nor 16

### Reference: Gothic1R.LUA

The `Gothic1R.LUA` script (from `Source-materials/`) has a working FNamePool resolver:
- GNames base must be set manually (`GNamesBaseAddress = 0x0`)
- Blocks at +0x10, stride 2, Format A header
- Reads FName from `instancePtr + 0x0C` (old UE4 offset — our game uses +0x18)

### Next Steps for GNames

1. **Heap search for FNameEntry pattern** — search for bytes `00 01 4E 6F 6E 65` (header for "None" ASCII) in heap
2. **Code reference search** — AOBScan for LEA instruction that loads GNames address
3. **UE4SS console** — if available, may expose GNames directly
4. **Breakpoint on FName::ToString** — catch the function that resolves names, read GNames from its code
