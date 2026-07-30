# Item Internal IDs, UI Categories & Display Names

**Master doc** for naming/categories. Chain → `CE75-INVENTORY.md`. GNames → `CE75-GNAMES-PROPOSAL.md`. Status → `CE75-STATUS.md`.

---

## 1. Three layers

| Layer | Example | Source |
|-------|---------|--------|
| **Internal FName** | `ItAr_Scroll_TransformBloodfly` | GNames + item **+0x18** ✅ |
| **Short label** | `Scroll Transform Bloodfly` | Strip `ItXX_` + pretty-space ✅ in CE75.LUA |
| **UI category path** | Magic → Scroll | Heuristic tab/sub in address list ✅ |
| **Display title** | `Transform Into Bloodfly` | ✅ catalog via `InitFromNs` + `lower(FName)`; **~60 bag misses** = key grammar (`CE75-LOC-NEXT.md`) |

**Status:** Alkimia catalog + join **verified** (43k+ titles, Teleport OK). Remaining: miss-key rules + optional zero-AOB Init.

---

## 2. In-game UI taxonomy (observed)

Top tabs (**11** including All):

```
All
├── Melee
│   ├── One-Handed Sword      e.g. Broadsword
│   ├── One-Handed Mace       e.g. Club
│   ├── Two-Handed Sword      e.g. Custodian's Blade
│   ├── Two-Handed Axe        e.g. Light BattleAxe
│   └── Orc Weapon            e.g. Krush Pach
├── Ranged
│   ├── Bow
│   ├── Crossbow
│   ├── Arrow
│   └── Bolt
├── Magic
│   ├── Rune Normal Continuous Spell   e.g. Fire Bolt
│   ├── Rune Rechargeable Spell        e.g. Ball Lightning
│   ├── Rune Normal Spell              e.g. Light
│   ├── Scroll Normal Spell            e.g. Transform Into Meatbug
│   └── Scroll Rechargeable Spell      e.g. Fireball
├── Wearables
│   ├── Ring
│   ├── Amulet
│   └── Armor
├── Food
│   ├── Herb
│   ├── Food
│   └── Drug
├── Potions
│   └── Drink
├── Materials
│   ├── Trophy
│   ├── Ore
│   └── Material
├── Documents
│   └── Writing
├── Miscellaneous
│   ├── Junk
│   ├── Torch
│   └── Instrument
└── Artefacts
    ├── Key
    └── Quest Item
```

**Counts:** 10 content tabs (+ All) ≈ **10 It\*** loot prefixes. Code still has a **14**-way loop (armor/fist/extra buckets).

---

## 3. Heuristic map: FName → UI tab / subtab

Enough to **group** bag items and build interim labels. **Not** a substitute for real display names or engine category enums.

| UI tab | UI subtab | Internal signals (FName) |
|--------|-----------|---------------------------|
| **Melee** | One-Handed Sword | `ItMw_1H_Sword_*` |
| | One-Handed Mace | `ItMw_1H_Mace_*` (also Club/Hammer tokens) |
| | Two-Handed Sword | `ItMw_2H_Sword_*` |
| | Two-Handed Axe | `ItMw_2H_Axe_*` (incl. Pickaxe) |
| | Orc Weapon | `ItMw_*` with `Orc` / `Krush` / `Pach` tokens |
| **Ranged** | Bow | `ItRw_Bow_*` |
| | Crossbow | `ItRw_Crossbow_*` / `ItRw_*Crossbow*` |
| | Arrow | `ItAm_Arrow` |
| | Bolt | `ItAm_Bolt` |
| **Magic** | Rune … | `ItAr_Rune_*` — continuous/recharge/normal **not** in FName yet (need def/UI data) |
| | Scroll … | `ItAr_Scroll_*` — same; subtype unknown from ID alone |
| **Wearables** | Ring | `ItAt_Ring_*` |
| | Amulet | `ItAt_Amulet_*` |
| | Armor | `Vlk_*`/`Stt_*`/`Kdf_*`/`Ryl_*` / `*_Armor*` (not `ItAr_`) |
| **Food** | Herb | `ItFo_Plants_*` |
| | Food | other `ItFo_*` except Potion/Joint-as-drug |
| | Drug | `ItMi_Joint_*` or `ItFo_*` drug tokens if any |
| **Potions** | Drink | `ItFo_Potion_*` (Wine, Health, Mana, …) |
| **Materials** | Trophy | `ItAt_<Animal>_*` (not Ring/Amulet) |
| | Ore | **`ItMi_Orenugget` only** (confirmed in UI) |
| | Material | all other mats (`Smith_*`, `Alchemy_*`, Stuff, Amphore, …) |
| **Documents** | Writing | `ItWr_*` (Book, Map, Scroll) |
| **Miscellaneous** | Junk | residual `ItMi_*` (Oldcoin, Stuff, …) |
| | Torch | `*Torch*` |
| | Instrument | `*Instrument*` / lute tokens if present |
| **Artefacts** | Key | `ItKe_*` |
| | Quest Item | `ItMs_*` |

### Prefix cheat-sheet

| Pref | Primary UI home |
|------|-----------------|
| ItMw | Melee |
| ItRw / ItAm | Ranged |
| ItAr | Magic |
| ItAt Ring/Amulet | Wearables |
| ItAt animals | Materials → Trophy |
| `*_Armor*` / faction | Wearables → Armor |
| ItFo Plants | Food → Herb |
| ItFo Potion | Potions → Drink |
| ItFo other | Food → Food |
| ItMi Ore/Smith/Alchemy | Materials |
| ItMi Joint | Food → Drug (or Misc — confirm in UI) |
| ItMi other | Miscellaneous → Junk |
| ItWr | Documents → Writing |
| ItKe | Artefacts → Key |
| ItMs | Artefacts → Quest Item |
| HumanFist | (hidden / not a loot tab) |

### Magic rune/scroll **subtypes** (continuous / rechargeable / normal)

**Cannot** classify from FName alone with current data. Need definition fields, UI metadata, or known-ID tables. Script 27 labels Magic as `Magic/Rune` or `Magic/Scroll` only.

### Interim “pretty” label (not localized)

Until FText exists, script builds a readable fallback from tokens, e.g.:

- `ItMw_2H_Axe_Pickaxe` → `Melee · Two-Handed Axe · Pickaxe`
- `ItAr_Scroll_TransformLurker` → `Magic · Scroll · Transform Lurker`
- `ItFo_Plants_Velayis_01` → `Food · Herb · Velayis (01)`

Still **not** the real UI string (`Transform Into Bloodfly`).

---

## 4. Internal ID grammar (short)

```
It <TypeCode:2> _ <tokens...> [ _ <digits> ]
```

| Pref | Meaning |
|------|---------|
| ItFo | Food |
| ItMw | Melee weapon |
| ItRw | Ranged weapon |
| ItAm | Ammo |
| ItAr | Magic artifacts (scroll/rune) |
| ItAt | Trophies + rings/amulets |
| ItMi | Misc / materials / valuables |
| ItWr | Writing |
| ItKe | Keys |
| ItMs | Mission / quest specials |

`_NN` / `_NNN`: trophy part, tier, book volume, or ToyMaker id — **not** one global rule.

### Bag run (script 27) — UI heuristic totals

| UI tab | slots | notes |
|--------|------:|-------|
| Food | 59 | Herb 30, Food 26, Drug 3 (joints) |
| Materials | 58 | Trophy 38, Material 18, Ore 2 |
| Documents | 44 | Writing |
| Melee | 34 | 1H mace/sword, 2H sword/axe, Orc, staff |
| Magic | 34 | Scroll 27, Rune 7 |
| Artefacts | 32 | Key 19, Quest 13 |
| Wearables | 23 | Ring 11, Amulet 8, Armor 4 |
| Potions | 16 | Drink (incl. wine/beer/water/mana) |
| Miscellaneous | 10 | Junk (oldcoin stack dominates qty) |
| Ranged | 4 | Bow 2, Arrow, Bolt |
| Hidden | 4 | HumanFist |

Magic continuous/recharge/normal subtypes still **not** in FName.  
Fix applied: `Amphore` no longer classified as Ore (substring false positive).

---

## 5. Scripts

| Script | Role |
|--------|------|
| `26_…` | GNames + `InventoryNamed` |
| `27_analyze_item_prefixes.lua` | Prefix stats + **UI category heuristic** + interim labels → `InventoryCategorized` |

---

## 6. Display strings FOUND (UTF-16) — session breakthrough

GUI / AOB: **~58 hits** for UTF-16 `Transform into` / `Transform Into`.

### 6.1 Confirmed string cluster (user dump)

Addresses (examples):

`0x2B8E1E9002E`, `…00D0`, `…0170`, `…020E`, `…0300`, `…039E`, `…1340`, `…13DE`, `0x2B91CF38880`

Decoded wide strings in the same blob:

| Kind | Example text |
|------|----------------|
| **Title** | `Transform into Lizard` |
| **Description** | `Inscription of Transform into Harpy` |
| **Description** | `Inscription for Transform into Bloodfly` |

Note lowercase **into** in data (GUI search may be case-insensitive).

### 6.2 In-memory layout (from hex after UTF-16z)

Repeating pattern after each wide string:

```
[UTF-16 text][00 00][pad to 8]
QWORD  module  (e.g. 0x7FF654219B78)     ← shared vtable / FText helper
DWORD  1
DWORD  1                                 ← refcounts
QWORD  …
QWORD  …
QWORD  data                              ← often → string or related
DWORD  num                               ← length (chars)
DWORD  max                               ← capacity
… more ptrs / GUID-like …
```

→ **UE `FString` / `FText` storage**, not free-floating debug text. Titles and inscriptions sit in a **localized string heap cluster**.

### 6.3 Relation to internal IDs

| Internal FName | Expected display (same cluster) |
|----------------|----------------------------------|
| `ItAr_Scroll_TransformLurker` | `Transform into Lurker` (or similar) |
| `ItAr_Scroll_TransformBloodfly` | `Transform into Bloodfly` |
| (inscriptions) | longer help text, not the bag title |

**Link still to prove in script:** pointer from **item def (+0x70)** or DataTable row → these `FText` blocks.  
**Keys we already have:** GNames FName indices on the item.

### 6.4 Catalog model (updated)

```
Item instance
  +0x18  FName index ──GNames──► ItAr_Scroll_TransformBloodfly
  +0x70  definition ──?────────► row / FText ──► "Transform into Bloodfly"
                                      └──► "Inscription for …"
```

Scripts:

| Script | Role |
|--------|------|
| **28** | Dump defs with GNames; diff types |
| **29** | UTF-16 title scan, parse FString trailer, ptr back-refs, match Transform* inventory |

## 7. Item → title **link** — FOUND (script 30 dump)

### 7.0 The link (not brute-force titles)

From BP object `0x2B920DBC650` while showing *Teleport to the Swamp Camp*:

| Off | Value | Meaning |
|-----|--------|---------|
| +0x00 | ptr → UTF-16 | **Display title** `"Teleport to the Swamp Camp"` |
| +0x08 | `0x1B`, `0x20` | len=27, max=32 (matches title length) |
| +0x10 | ptr → UTF-16 | **Namespace** `"AlkimiaLocalization"` |
| +0x18 | ptr → UTF-16 | **Loc key** `"itar_rune_teleporttoswampcamp"` |
| +0x20 | qword | hash / id |
| +0x30 | module | shared FText/FString vtable `exe+0x7569B78` |

**Key rule:**

```
internal FName  ItAr_Rune_TeleportToSwampCamp
       ↓ lower()
loc key         itar_rune_teleporttoswampcamp
       ↓ FText entry (namespace "AlkimiaLocalization" = studio name)
display title   Teleport to the Swamp Camp
```

`AlkimiaLocalization` = **Alkimia** (developer) localization namespace, not a separate product.

Description keys: `<lockey>_description`.

**Def (+0x70) has no title ptr.** Resolve via loc key.

**Performance:** never AOB per item. **Production Init (2026-07-24):**

1. Know **ns\*** (`AlkimiaLocalization` string addr) from any loc entry `+0x10` or `_G.AlkimiaNs`  
2. **One** `AOBScan` for pointers to ns (`InitFromNs`) — process **all** hits (`MAX_REFS ≥ 60k`)  
3. Build `key → title` map (~**43 581** titles verified)  
4. Inventory = `GetTitle` only (**0** AOB while map kept)

Legacy: 2 AOBs (find ns UTF-16, then ptrs). Prefer **InitFromNs**.  
Item/def/CDO → FText: **ruled out** (scripts 33–34).  
Next: **`CE75-LOC-NEXT.md`** Plan A (key grammar), Plan B (manager/RVA).

| Approach | Structural? |
|----------|-------------|
| AOB title text only | Discovery only |
| **Loc key = lower(FName) → map from ns-ptr entries** | **Yes — production path** ✅ |
| item+0x70 / CDO title ptr | ❌ none |

### 7.1 Hover BP on “Teleport to the Swamp Camp” (session)

| Site | Role | Verdict |
|------|------|---------|
| `exe+109ED20` `movzx eax,[rcx]` | RCX = title; walk/hash wide chars | **Useful** — entry to string processing |
| `exe+109ED6B` `[r9-2]` + xor table | Continue hash (lookup key?) | Useful with stack |
| `exe+6E335D2` `[rax+r8*2]` after `[rcx+18]` | Classic **FString** char index | Confirms FString, not GEngine |
| `exe+1027A90` `[rbx]` | Another read of same string | Low value |
| VCRUNTIME `vmovdqu` memcpy | Copy 0x36 bytes for UI | **Ignore** (CRT) |

Snapshot regs (example): `RCX/RBX/RDX = 0x2B9207699C0` (title), `RBX obj = 0x2B920DBC650`, module `RDI≈0x7FF656732888` (near GNames RVA band — global/FText machinery, **not** GEngine chain).

**None of these are on the GEngine→inventory chain.** They are string/UI utilities.

### 7.1b Call stack on hover — **captured** (2026-07-24)

Hit at parent **`exe+10B86BA`** (Teleport). Full list in `CE75-DISPLAY-LINK-IDEAS.md`.

| Priority | RVA | Verdict |
|----------|-----|---------|
| Done | `+10B86BA` | Stack holds FText cluster `…20DBC650/640/630` — display side only |
| **Next** | **`+10B855C`** | Stack **`…E41951E0`** — best non-string host candidate |
| Later | `+10BAA65`, `+10B5D66` | Same band if +10B855C is thin |
| Skip | UE4SS GC, `+13A*`, `+5C*`, `+3FA*`, USER32 | Widget/tick/pump |

Still **no GEngine frame**. Climb for **item/def**, not more string walks.

### 7.2 Runtime architecture (important)

```
SESSION START (once — ~10–15 s, 1 AOB if ns known):
  dofile helper
  InventoryDisplay_InitFromNs(AlkimiaNs)  -- or Init() legacy 2 AOB
       → AlkimiaLocMap in _G  (~43k titles)

INVENTORY UI OPEN (every time — instant):
  InventoryDisplay_GetTitle(internalName)   -- dict lookup ONLY
  if nil → pretty FName / ClassifyItemUi label
```

**Do not** rebuild the map or AOB when the user opens inventory.

| File | Role |
|------|------|
| `inventory_display_helper.lua` | **API: Init / InitFromNs / GetTitle** |
| `36_init_from_ns_one_aob.lua` | Thin full-map runner |
| `26` / `27` | GNames / categories |
| `32`–`35` | Research (done) |
| **`CE75-LOC-NEXT.md`** | **Plans A (keys) + B (zero-AOB)** |

### 7.3 Manager / zero-AOB (Plan B — optional)

| Candidate | Notes |
|-----------|--------|
| **FTextLocalizationManager** | UE singleton; not found yet |
| **Module RVA → ns\*** | Skip ns-string AOB forever |
| **Module RVA → map root** | True 0-AOB entry walk if structure known |
| **exe+0x7569B78** | Shared entry helper vt — xref band |

### 7.4 Next

→ **`CE75-LOC-NEXT.md`**

1. **Plan A:** miss autopsy + `lookup()` rules (~60 bag types).  
2. **Plan B:** static ns/manager RVA (optional seamless Init).
