# CE75 Release-Ready Functionality — Proposal

**Date:** 2026-07-24  
**Scope:** Gothic 1 Remake (UE 5.4) inventory in Cheat Engine 7.5 address list  
**Status:** Planning — builds on verified research (scripts 07, 26, 27, 30, 31)

Related masters: `CE75-STATUS.md`, `CE75-INVENTORY.md`, `CE75-DISPLAY-NAMES.md`, `CE75-SCANNING-GUIDE.md`

---

## 1. Why “Initialize Unreal Engine” stays responsive but our AOB freezes CE

### 1.1 What LaunchUEInfoScanner does

```lua
UEInfoScannerThread = createThread(function(t)
  t.Priority = 'tpIdle'
  UEInfoScanner(t)           -- long work here
  synchronize(function()     -- only UI/symbol updates on main thread
    ...
  end)
end)
```

| Mechanism | Effect |
|-----------|--------|
| **`createThread`** | Work runs on a **background Lua thread**, not the CE GUI thread |
| **`tpIdle` priority** | Yields CPU; game + CE stay interactive |
| **`synchronize(...)`** | Marshals tiny UI/symbol updates back to the main thread when done |
| **MemScan inside scanner** | Uses CE’s own scan engine + `waitTillDone` **inside that worker thread** — main form keeps painting |

So the game is not frozen because CE is not blocking its message loop on the scan.

### 1.2 What our helper AOB did wrong

| Bad pattern | Why it freezes |
|-------------|----------------|
| `AOBScan` / `firstScan` + `waitTillDone` on the **main thread** (Lua Engine “Execute”, menu click without a worker) | CE UI thread blocked until scan finishes |
| Full-process AOB over multi‑GB heap | Seconds–minutes of 100% work even in a thread if done carelessly |
| **N scans in a loop** (old script 31) | N × full-process cost → appears hung forever |

`AOBScan` itself is not “heavier magic” than UE init — **where it runs** and **how many times** matter.

### 1.3 Rules for release code

| Rule | Implementation |
|------|----------------|
| Any full-process scan | **Background `createThread` only** + status caption / progress |
| Inventory open / refresh | **Zero** AOB/MemScan — pointer walks + table lookup only |
| Display-name dictionary | Built **once per session** (optional menu), never per open |
| Hard caps | ≤2 AOBs for loc map; GNames via RVA/cache (0 AOB default) |

Optional later: run `InventoryDisplay_Init` the same way as `LaunchUEInfoScanner` (worker thread + `synchronize` when map ready).

---

## 2. Product goal (user proposal) — evaluation

### 2.1 Proposed UX

1. **Add Items** (after UE init + in-game inventory exists)  
   - Walk inventory chain (instant).  
   - Resolve **internal** FNames via GNames (instant).  
   - Place address-list entries under **UI categories** (Melee, Food, …) using `ClassifyItemUi` (instant).  
   - Show **qty** + internal id (and interim label).  

2. **Optional:** Unreal Engine menu → **Lookup real item names**  
   - One-shot (or background) build of Alkimia loc map.  
   - Refresh descriptions to real titles (“Apple”, “Club”, …).  
   - Never required for the tree to be useful.

### 2.2 Feasibility

| Piece | Ready? | Notes |
|-------|--------|--------|
| Inventory chain | ✅ | Char+0x7B0 → … → array 0xB8 |
| Qty / item ptr | ✅ | entry+0x10, +0x08 |
| Internal names | ✅ | item+0x18 → GNames (`exe+0x9AE6600` validated) |
| Category tree | ✅ | Script 27 heuristic ≈ in-game tabs |
| Real display titles | 🔄 ~74% | Alkimia lockey map; runes/scrolls/ammo often missing |
| Stats (damage, weight…) | ❌ | Needs def+0x70 / properties research |
| Background loc init | ⬜ easy | Same pattern as LaunchUEInfoScanner |
| Address list API | ✅ | Already used in CE75 for chains |

**Verdict: Feasible for a solid v1.** Real names as optional polish; categories + internal names + qty ship first.

### 2.3 Fit with current research plan

```
DONE     Chain, GNames, internal IDs, category heuristic, loc key discovery
NOW      Wire "Add Items" into CE75.LUA menu (instant path only)
NEXT     Optional "Lookup real names" (Init once, preferably threaded)
LATER    Loc manager zero-AOB init; item stats; tighter rune/scroll keys
```

Does **not** block on finding FTextLocalizationManager. Does **not** require inject.

---

## 3. Address list layout (proposed)

```
Unreal Engine / Inventory          (group)
├── Melee
│   ├── [3] Club  x1               (or internal: ItMw_1H_Mace_Club_01)
│   │     qty                      address entry+0x10
│   │     item                     pointer entry+0x08
│   └── ...
├── Ranged
├── Magic
├── Wearables
├── Food
├── Potions
├── Materials
├── Documents
├── Miscellaneous
├── Artefacts
└── Other / Hidden                 (HumanFist, unknowns)
```

**Record naming:**

| Phase | Description string |
|-------|-------------------|
| Default (instant) | `[slot] ItMw_1H_Mace_Club_01 ×1` or `Melee · Club · 1H Mace Club (01)` via ClassifyItemUi |
| After real-name lookup | `[slot] Club ×1` + tooltip/internal id in child or description suffix |

**Addresses:** prefer CE pointer expressions from GEngine where possible; fixed offsets only where already hardcoded (+0x7B0, inv chain). Slot entries may use absolute addresses refreshed on “Refresh inventory” (session-local) — document that they go stale on reload/zone.

---

## 4. Implementation plan

### Phase A — Instant “Add Items” (release core)  [~1–2 days]

| # | Task | Depends |
|---|------|---------|
| A1 | `UEngine_addInventoryToAddressList()` in CE75.LUA | UE init, in-game char |
| A2 | Ensure GNames: cache / `exe+0x9AE6600` validate (0 AOB) | — |
| A3 | Walk inv array; resolve internal name per slot | A2 |
| A4 | `ClassifyItemUi` (inline or dofile 27 logic) → tab/sub | A3 |
| A5 | Create group headers per tab; children qty + item ptr | A4 |
| A6 | Menu: **Unreal Engine → Add inventory items** | A1–A5 |
| A7 | Menu: **Refresh inventory** (rebuild tree, still 0 AOB) | A6 |
| A8 | Guardrails: no char / no GNames → clear message, no hang | — |

**Success criteria:** &lt;1s after click; 300+ items nested; CE and game stay responsive.

### Phase B — Optional real names  [~1 day]

| # | Task | Depends |
|---|------|---------|
| B1 | Menu: **Lookup real item names (once per session)** | A6, `inventory_display_helper` |
| B2 | Run `InventoryDisplay_Init` inside **`createThread`** + status on menu caption | B1 |
| B3 | `synchronize`: rename address-list nodes from `InventoryDisplay_GetTitle` | B2 |
| B4 | If Init already done (`IsReady`), skip AOB and only refresh labels | B3 |
| B5 | Missing titles keep internal id (no error spam) | B3 |

**Success criteria:** Optional path; user can ignore it; when used, UI thread not blocked (worker + synchronize).

### Phase C — Polish / research (post-v1)

| # | Task |
|---|------|
| C1 | Improve lockey match for ItAr_Rune/Scroll, ItAm_* (~70 types) |
| C2 | Find loc manager / vtable global → Init with 0 AOB |
| C3 | Item stats from def+0x70 on expand |
| C4 | Pointer-path expressions for inv slots if stable symbols exist |
| C5 | Persist nothing heavy to disk unless user asks |

---

## 5. Technical design notes

### 5.1 Threading template (loc init / any heavy work)

```lua
function UEngine_lookupRealItemNamesAsync()
  if InventoryDisplay_IsReady() then
    UEngine_applyDisplayNamesToAddressList()  -- main thread, fast
    return
  end
  createThread(function(t)
    t.Priority = 'tpIdle'
    local ok = InventoryDisplay_Init()
    synchronize(function()
      if ok then UEngine_applyDisplayNamesToAddressList() end
      -- restore menu caption
    end)
  end)
end
```

### 5.2 Dependencies between helpers

```
LaunchUEInfoScanner          → GEngine, offsets, menus, dissect seed
26 / EnsureGNames            → GNamesBase (RVA)
27 ClassifyItemUi            → tab/sub (pure string logic)
inventory_display_helper     → AlkimiaLocMap (optional, threaded Init)
Add inventory items          → chain + GNames + Classify  [required]
Lookup real names            → helper Init + rename nodes   [optional]
```

### 5.3 What we will not do in v1

- Full-process AOB on the main thread  
- Per-item AOB  
- Require real names for Add Items  
- Inject game code for symbols  
- Block on loc manager research  

---

## 6. Risks and mitigations

| Risk | Mitigation |
|------|------------|
| GNames RVA moves between builds | Validate `"None"`; message to re-run discovery offline; keep RVA list |
| Address list absolutes go stale | “Refresh inventory”; document session-local |
| Loc map incomplete (runes) | Internal names still correct; optional lookup best-effort |
| Thread + Lua state issues | Follow CE75 pattern: work in thread, UI only in `synchronize` |
| Dissect empty crash | Already: `UEngine_ensureDissectSeed` on Launch |

---

## 7. Live inventory tracking (checkbox)

**Yes — feasible without freezing**, via polling (not game hooks):

| Mechanism | Detail |
|-----------|--------|
| Menu checkbox | **Live track inventory changes** |
| Timer | `createTimer` on main form, **Interval ≈ 1000 ms** |
| Work per tick | Pointer walk of ~383 slots only (same as snapshot) — **milliseconds** |
| Diff | Fingerprint `slot:item:qty:nameIdx`; **rebuild tree only when changed** |
| Add item | Appears on next tick after obtain |
| Remove item | Dropped from tree on next tick |
| Qty change | Rebuild updates `×N` in description; qty child still live-addresses memory |

**Not true event-driven** (no item-pickup hook). 1s latency is fine for CE use.

**Caveats:** absolute addresses; after reload/zone click Refresh or keep live on. Collapsed/expanded UI state resets on full rebuild (acceptable v1).

Implemented in `CE75.LUA`: `UEngine_setInventoryLiveTracking`, `UEngine_refreshInventoryAddressList`.

---

## 8. Success definition (v1 “release-ready” inventory)

- [x] After **Initialize Unreal Engine**, user can **Add inventory items** without freezes  
- [x] Items under **category groups** (heuristic tabs)  
- [x] Quantity + item pointer  
- [x] Internal FName always available  
- [x] Optional **Live track** checkbox (1s poll)  
- [x] Optional **Lookup real item names** (background thread)  
- [ ] No mandatory multi-minute wait to see the tree  

---

## 8. Recommended immediate next step

Implement **Phase A** in `CE75.LUA` (menu + address list), reusing:

- Inventory offsets from `CE75-INVENTORY.md`  
- GNames resolve from safe script 26  
- `ClassifyItemUi` from script 27 (port minimal pure-Lua subset into CE75 or dofile helper)  

Defer Phase B until A feels snappy in real use.

---

## 9. Document index update

| Doc | Role |
|-----|------|
| **CE75-RELEASE-PROPOSAL.md** (this) | Release UX + phased plan |
| CE75-STATUS.md | Live checklist |
| CE75-DISPLAY-NAMES.md | Loc/FText research detail |
| CE75-SCANNING-GUIDE.md | Threading + AOB safety rules |
