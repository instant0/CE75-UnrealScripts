# Equipped items — findings + P1 layout notes

**Updated:** 2026-07-25 (P0/P1 CE75 implementation)

## Diff: unequipped → equipped (2026-07-24 session)

| Signal | Unequipped | Equipped |
|--------|------------|----------|
| Bag occupied | **285** | **283** (−2) |
| Bag ranged | Long_01, **Crossbow_04**, **Bow_Long_05**, ammo | Long_01 + ammo only |
| `Children` Char+0x190 count | **1** | **4** |
| Children samples | sword visual | sword + **Bow_Long_05_Visual** + **Quiver_Crossbow_Visual** |
| Manager+0x180 | `Default__ItMw_1H_Sword_Broad_01` | `Default__ItRw_Bow_Long_05` |
| InvMgr+0x158 | `ItMw_1H_Torch` | **`ItRw_Crossbow_04`** |

## Roles (P1)

| Source | Offset | Role in CE75 |
|--------|--------|----------------|
| **InvMgr +0x158 / +0x160** | TArray Data / Num | **Primary live equipped** — auto stride pick (8…0xB8) |
| **Manager +0x180 / +0x188** | TArray | **CDO / Default__** loadout fill (names not already live) |
| **Char +0x190 / +0x198** | Children TArray | **Visual only** (`BP_*_Visual_C`) → sub **Visual** if no logical row |

Bag `…+0x378` remains backpack only (equip removes stacks).

## CE75 behavior (2026-07-25)

- **`UEngine_unionEquipArrayParse`**: tries multiple strides and **unions by item name** (not “best stride only” — that dropped the bow after re-equip crossbow).
- Scan window: max(Num, Max≤24, at least 8) for sparse hotbar.
- Fill order: **live 158 → CDO 180 → Children visuals**; visuals use **Melee/Ranged/…** tab (not only Visual) so a bow only present as `BP_*_Visual` still shows under Equipped → Ranged with `[visual]`.
- Equipped rows: **`(slot) DisplayName`**, optional `xN` qty, tags `[CDO]` / `[visual]`.
- Dump tool lists all stride scores.

## Bug fixed: bow vanished after re-equip crossbow

**Cause:** single “best stride” + visuals parked under sub **Visual** (easy to miss) + Num-only scan missing sparse slots.  
**Fix:** name-union across strides + visual fill into gameplay subs + wider scan window.

## Still soft

- Exact designer hotbar index vs array index (confirm in-game vs dump).
- Whether qty at entry+0x10 is real for equip stride.
- Address-list **collapse** on live refresh — see `CE75-ADDRLIST-UX-PLAN.md` (not equip logic).

## Dump

```lua
dofile([[d:\d\gamehacking\lua\CE75_dump_equipment_candidates.lua]])
```

Compare equipped vs unequipped dumps; prefer stride with most NOT_BAG named hits.

See **`CE75-NEXT-WORK.md`**, **`CE75-STATUS.md`**.
