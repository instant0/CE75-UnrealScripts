# Missing link: FName → localized title

**Updated:** 2026-07-24 (night) — **catalog link SOLVED** (`InitFromNs`); research history below  
**Master next steps:** **`CE75-LOC-NEXT.md`** (Plan A key grammar, Plan B zero-AOB)  
**Related:** `CE75-DISPLAY-NAMES.md`, `inventory_display_helper.lua`, scripts 32–36

---

## ★ Resolved (production)

| Piece | Result |
|-------|--------|
| Item → FText field | ❌ none (33–34) |
| Contiguous full table | ❌ only local `0x50` slabs (35) |
| Catalog via **ptr → ns\*** | ✅ **43 581** titles, 1 AOB, all 44417 hits (36) |
| Join | `lower(FName)` → key; Teleport ✓ |
| Remaining | ~60 bag **key** mismatches; optional manager RVA |

**Do not** re-hunt item DisplayName pointers. Follow **`CE75-LOC-NEXT.md`**.

---

## Archive: ONE plan (hover BP era — completed research)

**Goal then:** find structural edge item/def/manager → FText.  
**Probe:** `ItAr_Rune_TeleportToSwampCamp` / **"Teleport to the Swamp Camp"** / key `itar_rune_teleporttoswampcamp`

### Addresses (this session — heap title moves each restart)

| Role | Value | Notes |
|------|--------|--------|
| Title UTF-16 (active UI) | **`0x2B9207699C0`** | Seen as RDX/RDI on hover memcpy; **use this instance** |
| Second search hit | (other) | Often stale/duplicate FText — ignore unless “what accesses” also hits it on inv open |
| Module base (this run) | `0x7FF64CCB0000` | From abs − RVA |
| String walk (hot) | `exe+109ED20` = `0x7FF64DD4ED20` | `movzx eax,[rcx]` — RCX=title |
| Hash continue | `exe+109ED6B` = `0x7FF64DD4ED6B` | `movzx eax,[r9-2]` |
| FString index | `exe+6E335D2` = `0x7FF653AE35D2` | `[rax+r8*2]` |
| Another read | `exe+1027A90` = `0x7FF64DCD7A90` | `movzx r8d,[rbx]` — **16× on hover only** |
| CRT memcpy | `VCRUNTIME140…` | **Ignore always** (RDX=src title, RCX=dest copy, R8=0x36 bytes) |

**“What accesses this address” counts (title @ `0x2B9207699C0`):**

| When | +109ED20 | +109ED6B | +6E335D2 | +1027A90 | CRT |
|------|----------|----------|----------|----------|-----|
| Open inventory | 2 | 30 | 16 | — | — |
| Switch to item’s tab | 4 | 60 | 32 | — | — |
| Mouse over item | — | — | — | **16** | 2,2,2 |

Tab paint = hash/walkers. Hover adds paint + **memcpy into UI buffer** (CRT) + short game read at `+1027A90`.

### What to ignore

- All **VCRUNTIME** / `vmovdqu` memcpy hits (title already resolved; only copying to widget).  
- Breaking bare on `+109ED20` without a filter (fires for every title’s every wchar).  
- Searching for more UTF-16 titles (we already have the string).

### Exactly what to do next (in order)

1. **Confirm title ptr** after any game restart: Memory View → string search `"Teleport to the Swamp Camp"` → pick the hit that “what accesses” ties to `exe+109ED20` when inventory is open (this session: `0x2B9207699C0`).
2. **Lua filtered execute BP** on the **hot walker** (we know RCX is the title there):

```lua
-- Teleport title — UPDATE titlePtr if session restarted
local titlePtr = 0x2B9207699C0
local code = getAddress("G1R-Win64-Shipping.exe") + 0x109ED20

debug_removeBreakpoint(code)
debug_setBreakpoint(code, function()
  if RCX ~= titlePtr then return 0 end  -- not our item
  -- match: stash + hard-break once
  _G.BP_Title = titlePtr
  _G.BP_RCX, _G.BP_RBX, _G.BP_RDX = RCX, RBX, RDX
  _G.BP_R8, _G.BP_R9, _G.BP_R12 = R8, R9, R12
  _G.BP_RSP, _G.BP_RBP = RSP, RBP
  print(string.format("[LOC] match RCX=%X RBX=%X RDX=%X R12=%X RSP=%X", RCX, RBX, RDX, R12, RSP))
  debug_removeBreakpoint(code)  -- one-shot
  return 1  -- freeze CE so you can open Call Stack
end)
```

3. Open inventory → go to the tab with Teleport → hover the item (or just leave tab open until it breaks).  
4. **While frozen:** CE **Call Stack** → note **2–4 return addresses above** `+109ED20` (parent was previously listed as ~`exe+10B86BA`; confirm live).  
5. For each stack object / interesting reg that looks like a heap UObject:
   - FName at `+0x18`?
   - Any qword equal to `titlePtr` or to FText entry (`titlePtr` often at entry+0x00)?  
   - Any pointer into known bag `item` / `item+0x70` def?
6. Optional second one-shot: same filter at **`exe+1027A90`** with `RBX == titlePtr` (hover-only, quieter than the hasher).  
7. **Do not** chase CRT frames.

**Done when:** one sentence — e.g. “def+0x?? holds FText/history” or “module global exe+0x???? is loc map” — then we hardcode that RVA/offset in CE75 and drop AOB Init for titles.

**Lua note:** callback on `debug_setBreakpoint(addr, fn)` → `return 0` continue, `return 1` break. No manual BP required; manual Call Stack after freeze is fine.

### ★ Call stack captured (Teleport hover → `+10B86BA`)

Top = closest to string paint. Truncated stack qwords need full heap prefix (this session often `000002B9…` / `000002B8…`).

| Depth | Code | Stack sample (low 32) | Read |
|------:|------|----------------------|------|
| 0 | **`exe+10B86BA`** | **`20DBC650`, …** | FText entry cluster @ `0x2B920DBC650` ✅ |
| 1–2 | `+10CD718`, `+10BAA65` | | Text pipeline |
| 3 | **`exe+10B855C`** | **`E41951E0`**, `20E09B3A` | **`E41951E0` = ns UTF-16 `"AlkimiaLocalization"`** (shared string pool), **not** a host UObject. `20E09B3A` = lockey string. |
| 4+ | deeper UI / UE4SS / tick | | Skip for item link |

### Dump 32 results (confirmed)

```
FText @ 0x2B920DBC650
  +0x00 → title  "Teleport to the Swamp Camp" @ 0x2B9207699C0
  +0x08    len=27 max=32
  +0x10 → ns     "AlkimiaLocalization"       @ 0x2B8E41951E0   ← was misread as "host"
  +0x18 → lockey "itar_rune_teleporttoswampcamp"
  +0x20    hash  0x2A4BFC42E7B5A819
  +0x30    vt    exe+0x7569B78
```

Neighbors `20DBC640/630` = misaligned views into **packed loc table**, not separate hosts.

**Scripts 33–34 result: CLOSED — no item-graph → FText edge.**

| Scan | Result |
|------|--------|
| 33 bag item + def (+1 ptr hop), 324 items | **0** hits on FTEXT/title/key/hash |
| 34 CDO, Base, RuneItem_Teleport_Base, GE_*, ASClass, … | **0** hits |

Teleport still has full FText @ `0x2B920DBC650` with lockey `itar_rune_teleporttoswampcamp` = lower(FName).  
Display is **not** stored on the inventory UObject tree.

**Paths left (only):**
1. **A — Practical:** session `InventoryDisplay_Init` (≤2 AOB) + `GetTitle` lockey rules — **shipping path**  
2. **B — Zero-AOB dictionary:** 1× reverse ptr scan **to** FTEXT entry → loc table/manager → hardcode RVA like GNames  
3. ~~Item/def/CDO DisplayName field~~ **dead**

---

## Why full-heap AOB Init is so slow (and what replaces it)

`InventoryDisplay_Init` does **two process-wide `AOBScan(+W)`** (namespace UTF-16, then every pointer to it). Writable heap is huge → freezes CE. Correct catalog idea, wrong discovery cost.

| Method | Cost | Role |
|--------|------|------|
| Full +W AOB ×2 | **Brutal** | Current Init |
| **Seed + stride walk** | **~0 AOB** | Script **`35_seed_walk_loc_table.lua`** — from LIVE title/entry, walk packed Alkimia rows |
| Module-image ptr scan | Small/fast | Find **static** RVA → ns* / table* (manager root) |
| Item → FText field | — | Ruled out (33–34) |

**Two string-search hits for one title:** use only the **LIVE** one (accessed when inventory paints). The other is stale/unused cache — never read on open. Live title → FText entry (`+0x00` = title*) → same row layout as dump 32.

**Missing link (engine):** not item+offset → string; it is  
`FName --lower--> key` + **`FTextLocalizationManager` / packed cache table`**.  
Script 35 builds the cache by walking; module hits near ns*/first entry* are the attack surface for a GNames-style RVA.

### Script 35 result (important)

| Observation | Meaning |
|-------------|---------|
| Stride `0x50`, score 17, **titles=12** only | Entries sit in **small slabs**, not one giant array of all ~19k strings |
| Teleport works; Apple/sword nil | Local cluster only (teleport/rune neighborhood) |
| Full ptr AOB to title: 1 hit, ~9s | Entry still `@0x2B920DBC650`; MemScan range path flaky |
| ns `0x2B8E41951E0` from seed | **Enough to skip ns-string AOB** |

**Full catalog** = every struct with `+0x10 == ns*` (scattered).  
**Optimized Init:** `InventoryDisplay_InitFromNs(ns)` / script **`36_init_from_ns_one_aob.lua`** → **1× AOB** (not 2).  
Still not zero-AOB; manager RVA remains the long-term missing link.

---

## What already connects (two solid halves)

```
IDENTITY (bag/equip)                         DISPLAY (UI text)
─────────────────────                        ─────────────────
item+0x18 NameIndex                          FText-like heap entry:
  → GNames → "ItAr_Rune_TeleportToSwampCamp"    +0x00 → UTF-16 title
                                               +0x10 → "AlkimiaLocalization"
                                               +0x18 → UTF-16 lockey
                                               +0x20 hash
                                               +0x30 vt exe+0x7569B78

PROVEN BRIDGE (partial, dictionary only):
  lockey ≈ lower(FName)     e.g. itar_rune_teleporttoswampcamp
  session Init: ≤2 AOB → AlkimiaLocMap (~19k titles)
  runtime: GetTitle(FName) table only  →  ~210/283 bag types
```

**Gap is not “titles don’t exist”.** Gap is:

1. **FName → lockey grammar** fails for ~70 types (runes/scrolls/ammo/fists often).  
2. **No object-graph edge** item/def → FText or LocalizationManager (zero-AOB).  
3. Possible **lazy load** — some FText only appear after that item is painted in UI.

---

## Interaction points that *must* exist somewhere

The UI paints a title. Something must:

| Step | Engine side | Our status |
|------|-------------|------------|
| A | Know which item is shown | Bag entry / equip / widget bound object |
| B | Resolve type identity | FName / def / CDO class |
| C | Look up localization | namespace + key or FText history |
| D | Get UTF-16 string | FText → display |

We own **A+B** (inventory). We own **D** once we have an FText entry or lockey.  
**C** is the missing interaction — either a **function** (GetText) or a **pointer/field** (FText on def) or a **global table** (manager TMap).

---

## Ranked hypotheses

### H1 — Key grammar mismatch (highest, cheapest)
Many assets use lockeys that are **not** plain `lower(FName)`:
- Abbreviations: `Transform` → `Trf`, `TeleportTo` → shorter forms  
- Dropped prefix: `rune_…` without `itar_`  
- Tier suffixes / `_01` stripped differently  
- CDO name `Default__ItRw_…` vs instance FName  

**Map already has the title; matcher misses the key.**  
Explains ~74% success with one rule + failures clustered on magic/ammo.

### H2 — Lazy / UI-gated FText population
Alkimia heap entries (or whole ns clusters) materialize when inventory opens or when a row is hovered. Init before open → incomplete map; never-hovered types stay missing forever in that session.

### H3 — Canonical store is FTextLocalizationManager (or StringTable)
Heap FText entries are a **cache**. Real API: manager→`Find(ns, key)` or TMap.  
GEngine/UGameInstance/subsystem may hold the singleton. Zero-AOB Init = find that global once.

### H4 — Opaque FText on item or definition (not a title wchar*)
`item+0x70` def was scanned for **title string pointers** and found none.  
FText is often `{ history*, flags }` — points at **entry/history**, not at UTF-16.  
False negative if we only looked for title text.

### H5 — Loc key / DisplayName on DataAsset / def field
Shared def per type → natural place for `DisplayName` FText or `LocKey` FString/FName.  
PropertyLink failed earlier (nonstandard reflection) but **raw dump compare** resolved-def vs missing-def can still show it.

### H6 — Module anchor at `exe+0x7569B78`
Shared FText helper vtable seen on every entry.  
Pointer-scan that qword in **.data** → nearby globals = manager / entry pools (same band as GNames-ish).

### H7 — UI viewmodel path (hover BP climb)
`exe+10B86BA` (caller of hot wchar walk) loads title into RCX.  
Parent frames may hold list-item VM with item* or FText*.  
Structural link discovered from **UI down**, not inventory up.

### H8 — Multiple namespaces / tables
Ammo, fists, system items may use another ns than `AlkimiaLocalization`.  
Init only indexes one ns → systematic holes.

### H9 — Hash at FText+0x20 is primary key
FName lower is authoring convenience; runtime uses hash.  
Need FName→hash function or field that stores hash on def.

### H10 — StringTable UObject in GUObjectArray
Named `ST_*` / `Alkimia*` rows keyed by FName — walk objects once.

### H11 — Native GetDisplayName only
No UPROPERTY; only vtable. Needs BP or vtable dump (harder in pure Lua).

### H12 — .locres on disk only
Last resort; duplicates engine. Prefer runtime manager.

---

## Where inventory already “touches” type data (for H4/H5)

| Location | Role | Title likely? |
|----------|------|----------------|
| item+0x18 | FName identity | Key material only |
| item+0x70 | Shared **definition** | **Best structural candidate** |
| def+0x18 | Def’s own FName | Maybe lockey-related name |
| Equip CDO `Default__ItRw_*` | Class default | May carry DisplayName meta |
| BP `*_Visual_C` Children | Mesh only | Unlikely titles |
| Alkimia FText heap | Resolved strings | Display side |

---

## Recommended experiments (do in order)

### Exp 1 — Missing-key autopsy (H1 + H2) — **do first**
1. Open inventory in-game once.  
2. `InventoryDisplay_Init()`.  
3. List bag FNames with `GetTitle==nil`.  
4. For each missing name, search AlkimiaLocMap keys for:
   - compact (no `_`) containment  
   - token overlap  
   - drop `ItXX_`, drop trailing `_NN`  
5. Codify 3–5 rules; remeasure 210→?.  
6. Repeat Init after hovering missing items — did new keys appear? (H2)

**Success:** ≥90% without new architecture.  
**Effort:** low, pure Lua analysis script.

### Exp 2 — Back-pointer FText → def/item (H4/H5)
1. Take known entry for `itar_rune_teleporttoswampcamp`.  
2. AOB pointers to entry base, title, key, hash (+0x20).  
3. Intersect with `item` and `item+0x70` windows (±0x300).  
4. Repeat for one missing type **after** hover paints it.

**Success:** `def+X → FText entry` or kill structural edge.  
**Effort:** medium, ≤ few AOBs.

### Exp 3 — BP `exe+10B86BA` (H7 → H3/H6)
1. Breakpoint on hover of known item (RCX = title UTF-16).  
2. Dump regs + 2–3 return addresses / stack objects.  
3. Identify item/def/FText/manager.  
4. Follow module globals toward `+0x7569B78`.

**Success:** stable path for 0-AOB Init later.  
**Effort:** medium, interactive CE.

---

## What we should *not* do

- AOB / Init on every inventory refresh  
- Per-item string scan  
- Assume PropertyLink will expose DisplayName (already failed)  
- Treat Visual BP names as localization  

---

## If Exp 1 wins

Ship improved `InventoryDisplay_GetTitle` heuristics; keep 2-AOB session Init.  
Document remaining misses. Good enough for release menu.

## If Exp 1 plateaus ~80%

Run Exp 2; if def holds FText, CE75 can resolve **per type once** from `item+0x70` with 0 AOB after first def walk.  
If not, Exp 3 for manager singleton.

---

## Bottom line

There **is** an interaction: UI resolves **AlkimiaLocalization** + lockey → FText title.  
Inventory gives **FName**. The production rule for many items is `lockey = f(FName)` (often `lower`), but **f is incomplete** for a quarter of the bag, and we never found the **object edge** that would skip the dictionary.

**Most likely missing link:** imperfect **FName→lockey** (+ lazy load), not missing translation data.  
**Most valuable structural link still unproven:** **definition (`item+0x70`) or LocalizationManager → FText**.
