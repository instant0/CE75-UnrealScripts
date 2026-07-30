# Localization — verified pipeline & next plans

**Updated:** 2026-07-24 (night)  
**Related:** `CE75-DISPLAY-NAMES.md`, `CE75-DISPLAY-LINK-IDEAS.md`, `inventory_display_helper.lua`, `CE75-STATUS.md`

---

## 1. Verified model (shipping)

### Join (item identity → title)

```
bag/equip item*
  +0x18 NameIndex ──GNames──► FName   e.g. ItAr_Rune_TeleportToSwampCamp
                    │
                    ▼ lower()
              loc key          e.g. itar_rune_teleporttoswampcamp
                    │
                    ▼ AlkimiaLocMap[key]
              UI title         e.g. Teleport to the Swamp Camp
```

| Fact | Evidence |
|------|----------|
| No `item` / def / CDO / Base pointer to FText, title, key, or hash | Scripts **33–34** (Teleport + full bag) |
| Loc rows are **scattered** (small `0x50` slabs), not one linear array of all strings | Script **35** (12 titles local only) |
| All rows share **`entry+0x10 → ns*`** UTF-16 `"AlkimiaLocalization"` | Dumps 32–36 |
| Full catalog = every heap struct with that ns pointer at +0x10 | Script **36** / `InitFromNs` |
| UI paint only sees resolved strings (not GEngine inventory) | BP stack at `+10B86BA` |

### Loc entry layout (stable)

| Off | Content |
|-----|---------|
| +0x00 | title UTF-16* |
| +0x08 | len, max (dwords) |
| +0x10 | **ns*** → `"AlkimiaLocalization"` |
| +0x18 | **key*** → lockey |
| +0x20 | hash (u64) |
| +0x30 | helper vt `exe+0x7569B78` (build-specific) |

Description rows: key ends with `_description`.

### Production Init (session, once)

| Step | Cost | API |
|------|------|-----|
| Obtain **ns\*** | 0 AOB if known | From any FText entry `+0x10`, or leftover `_G.AlkimiaNs` |
| Build map | **1×** full-heap `AOBScan` for `ptr == ns*` | `InventoryDisplay_InitFromNs(ns)` |
| Cap | Process **all** hits (`MAX_REFS ≥ 60k`) | Was 20k → dropped Teleport; **fixed** |
| Runtime | **0 AOB** | `InventoryDisplay_GetTitle(FName)` |

**Verified session result:**

```
hits=44417 used=44417
parsed=44117 titles=43581 descs=536
time ≈ 13–14 s (one AOB)
ItAr_Rune_TeleportToSwampCamp → Teleport to the Swamp Camp ✓
```

**Script 37 bag autopsy (full map, 289 unique bag types):**

```
resolved=284  missing=5  (98.3% hit)
miss classes: A(grammar)=0  B(no key)=5  C(desc)=0

[B] HumanFist_NoWeapon
[B] HumanFist_NoWeapon_Climbing
[B] HumanFist_NoWeapon_Swimming
[B] HumanFist_NoWeapon_WaterWalking
[B] ItRw_Quiver
```

**Plan A outcome:** No lockey grammar work needed — `lower(FName)` already covers loot.  
Remaining five are **class B** (no Alkimia key in the 43k map), not matcher bugs.

Legacy path (no ns seed): `InventoryDisplay_Init()` → up to **2** AOBs (find ns string, then ptrs). Prefer **InitFromNs** when ns known.

### Operator load order (CE Lua)

Copy updated files to the drive you use (`D:\…\LUA` and/or `R:\`), then:

```lua
dofile([[d:\d\gamehacking\lua\inventory_display_helper.lua]])
-- or R:\inventory_display_helper.lua after copy

_G.AlkimiaLocMap = nil          -- if rebuilding
_G.AlkimiaNs = <ns address>     -- e.g. from prior entry+0x10
InventoryDisplay_InitFromNs(_G.AlkimiaNs)

-- optional runner:
-- dofile([[R:\36_init_from_ns_one_aob.lua]])
```

Do **not** rely on scripts auto-finding Linux-only paths; **explicit `dofile`** from the tree you copied.

### Two string-search hits

Same title text can appear twice. Use the **LIVE** buffer (read when inventory paints). The other is stale/unused. Data-BP on the live string can glitch UI text under the debugger (e.g. truncated “Teleportsw”) — artifact only.

---

## 2. Closed / do not reopen

| Approach | Status |
|----------|--------|
| item / def / CDO DisplayName → title wchar* | ❌ |
| Contiguous stride-walk of all loc rows from one seed | ❌ (local slab only) |
| PropertyLink for DisplayName | ❌ earlier |
| Full-heap AOB on every inventory open | ❌ never |
| Treating ns string (`E41951E0`) as host UObject | ❌ |

---

## 3. Plan A — Close bag miss list — **DONE (2026-07-24)**

**Result:** **98.3%** bag types resolve with stock `lower(FName)` + existing fuzzy.  
**Class A (grammar) misses: 0** — do **not** add speculative lockey rules.

### Remaining 5 (class B — accept or polish UI)

| FName | Handling |
|-------|----------|
| `HumanFist_NoWeapon` (+ Climbing / Swimming / WaterWalking) | System / unarmed states — **not loot**. Prefer hide from inventory tree or label **“(system) Unarmed …”** via pretty FName. No loc entry expected. |
| `ItRw_Quiver` | No key in 43k Alkimia map. Likely visual/ammo container without its own title, or rare/unused string. Keep internal/pretty name; optional later hunt for alternate ns (low priority). |

### Optional polish (A leftovers — low)

| Item | Action |
|------|--------|
| A.3 menu | Prefer `InitFromNs` when `AlkimiaNs` set; clear maps with &lt;100 keys before rebuild |
| Hide `HumanFist_*` | CE75 inventory filter or force tab **Hidden** (script 27 already had Hidden bucket for fists) |
| Quiver | Only if it appears as a real UI row with a title you can string-search |

### Out of scope for A

Zero-AOB, manager RVA, equip layout.

---

## 4. Plan B — Zero-AOB catalog (manager / static root)

**Goal:** Session map **without** full-heap AOB (GNames-style).  
**Priority:** **Medium** (comfort only — Plan A done; 1× ~13s Init is acceptable).  
**Depends on:** Catalog is ns-keyed scattered heap entries.

### B.2 result (script 38) — **negative for ns\* in module**

```
ns = 0x2B8E41951E0 "AlkimiaLocalization"
AOB ptr→ns: hits=44417
  module = 0
  heap   = 44417  (≈ every loc entry +0x10)
```

**Meaning:** This session’s **heap address of the ns string is not stored as a static qword in `G1R-Win64-Shipping.exe`**.  
Normal for UE: display strings / namespaces are allocated at load; the module holds **code + vtables**, not the live ns pointer.

So we **cannot** hardcode `readQword(exe+RVA) → ns*` for this heap ns. Plan B must target something else.

| Approach | Status after 38 |
|----------|-----------------|
| Module ptr → live ns* | ❌ **none** |
| Module ptr → live FText entry* | Not run (no `BP_FText` set); likely also 0 for same reason |
| 1× AOB ptr→ns (current InitFromNs) | ✅ still the production path |

### B.3 Revised attack list (if still pursuing zero-AOB)

Do **in order**; stop when one works.

| # | Attack | Why | How |
|---|--------|-----|-----|
| **B3.1** | **UTF-16 `"AlkimiaLocalization"` inside module** (+R image, not heap) | Source / rdata may exist even if live ns is heap | `AOBScan` utf16 pattern with default/module; if hit, still need runtime map — low value alone |
| **B3.2** | **Static ptr to FText helper vt** `exe+0x7569B78` | Every entry `+0x30` uses it; `.data` may ref vt → nearby globals / pools | Module scan for `ptrPat(base+0x7569B78)`; dump neighbors |
| **B3.3** | **Common owner of many entry\*** | TMap/array root on heap; find via reverse ptrs to 2–3 known entries, intersect | After map built: pick 3 entry addrs; AOB ptr→each; find shared heap object that points at many entries |
| **B3.4** | **GUObjectArray / named UObject** | `StringTable`, localization subsystem | Walk objects by FName if reflection works (often weak on this game) |
| **B3.5** | **Code xref / BP** | Function that does FindDisplayString(ns,key) loads manager from global | One-shot BP on known paint path; note module globals in regs — last resort |

**Realistic outcomes:**

| Outcome | Effort | Payoff |
|---------|--------|--------|
| Stay on **InitFromNs** (1 AOB ~13s / session) | Done | ✅ Good enough |
| B3.2 vt global → faster seed of ns | Medium | Maybe skip nothing if still need entry AOB |
| B3.3 map root walk | High | True 0-AOB rebuild |
| Accept 1 AOB forever | Zero | Document as final |

### B.4 Recommendation

**Default: ship with InitFromNs.** Revisit B3.2–B3.3 only if the 13s scan is a frequent pain.

### B.5 Out of scope for B

Key grammar (Plan A closed).

---

## 5. Suggested order

| Phase | Work | Outcome |
|-------|------|---------|
| ✅ | Catalog `InitFromNs` + docs | 43k titles |
| ✅ | Plan A autopsy (37) | **98.3%**; 5 system/no-key only |
| **Next** | Plan B (38) if Init time still hurts | Static ns / manager RVA |
| Optional | Hide `HumanFist_*` in CE75 list | Cleaner inventory UI |
| Later | Equip hotbar layout | `CE75-STATUS` medium items |

---

## 6. Script index (loc)

| Script / file | Role | Status |
|---------------|------|--------|
| `inventory_display_helper.lua` | Init / InitFromNs / GetTitle | ✅ production |
| `32_dump_loc_stack_objects.lua` | FText / false host dump | ✅ research done |
| `33_scan_bag_for_loc_ptrs.lua` | item/def → loc ptrs | ✅ none |
| `34_scan_cdo_base_for_loc.lua` | CDO/Base → loc ptrs | ✅ none |
| `35_seed_walk_loc_table.lua` | stride walk | ✅ local slab only |
| `36_init_from_ns_one_aob.lua` | full map 1 AOB | ✅ verified |
| **`37_loc_key_autopsy.lua`** | Plan A miss taxonomy | ✅ written (LUA + projects) |
| **`38_find_loc_manager.lua`** | Plan B module ns/entry ptrs | ✅ written (LUA + projects) |

---

## 7. Success criteria (project)

| Criterion | Target | Status |
|-----------|--------|--------|
| Session catalog | ≥ 40k titles, 1 AOB, Teleport resolves | ✅ |
| Bag unique types with real title | ≥ 95% loot-facing | ✅ **98.3%** (284/289); 4 fists + quiver class B |
| Init after known build | 0 AOB or static ns + 1 AOB | 📋 Plan B |
| Inventory open | always 0 AOB | ✅ |
