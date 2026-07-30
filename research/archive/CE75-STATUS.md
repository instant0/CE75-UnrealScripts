# CE 7.5 Port: Gothic 1 Remake (UE 5.4) — Status

**Updated:** 2026-07-25 — inventory + loc + player UX largely shipping; docs refreshed

## Doc map (one master per domain)

| Domain | Master doc | Freshness |
|--------|------------|-----------|
| Project status / script index | **This file** | ✅ current |
| Next work / backlog | **`CE75-NEXT-WORK.md`** | ✅ mostly; P0–P1 done |
| Localization pipeline + plans | **`CE75-LOC-NEXT.md`** | ✅ pipeline; Plan A done |
| Player props / hints / safety / no tooltips | **`CE75-PLAYER-PROPS.md`** | ✅ T1–T4; pointer→Debug note may lag 1 day |
| Address-list collapse / player reuse | **`CE75-ADDRLIST-UX-PLAN.md`** | ✅ Fix A/B done |
| Equipped / hotbar | **`CE75-EQUIPPED-FINDINGS.md`** | ✅ P1 + bow union fix |
| Loc research history | `CE75-DISPLAY-LINK-IDEAS.md` / `CE75-DISPLAY-NAMES.md` | ⚠️ historical + production notes mixed |
| Inventory chain deep dive | `CE75-INVENTORY.md` | ⚠️ older; offsets still valid |
| CE API / scanning / GNames / release | REFERENCE, SCANNING, GNAMES, RELEASE | ⚠️ pre-P0 era; technical facts OK |
| Menu UX plan | `CE75-MENU-UX-PLAN.md` | ⚠️ partly superseded by STATUS/NEXT |

**Main script:** `d:\d\gamehacking\lua\CE75.LUA`  
**Helper:** `inventory_display_helper.lua` (same folder / projects / `R:\` copy)  
**Load:** explicit `dofile([[d:\…]])` or `R:\…` — do not rely on Linux-only paths alone.

---

## Implementation state (2026-07-25)

### Core / UE

| Area | Status | Notes |
|------|--------|-------|
| UE init / GEngine | ✅ | Auto-scan on attach; menu when ready |
| Reload without CE restart | ✅ | Cleanup + menu rebuild |
| Dissect seed / GameEngine structure | ✅ | Index-only `getStructure`; in-place GE |
| GNames | ✅ | `exe+0x9AE6600`, validate `None` |

### Inventory

| Area | Status | Notes |
|------|--------|-------|
| Bag walk | ✅ | Char+0x7B0 → … → +0x378 stride 0xB8 |
| UI categories + pretty names | ✅ | Tabs/subs; ammo → **Arrow**/**Bolt** under Ranged/Ammo |
| `HumanFist_*` | ✅ | Hidden as system (`showSystemItems` to show) |
| Live track | ✅ | 1s poll; rebuild only on fingerprint change |
| Expand state on rebuild | ✅ | Save/restore `mr.Collapsed` (pcall); soft first Live enable |
| Loc titles | ✅ | `InitFromNs` ~43k titles, ~13s, 1 AOB; GetTitle 0 AOB after |
| Bag loc hit rate | ✅ | **98.3%** (37); only fists + quiver without keys |

### Equipped

| Area | Status | Notes |
|------|--------|-------|
| Multi-source | ✅ | InvMgr+0x158 union strides → Mgr+0x180 CDO → Children visual |
| Slot labels / tags | ✅ | `(n)`, `[CDO]`, `[visual]` |
| Bow drop after re-equip | ✅ | Name-union across strides + visual fill |

### Player address list

| Area | Status | Notes |
|------|--------|-------|
| Single **Player** group | ✅ | Title `Player (N props)`; not BP class name |
| Reuse on menu click | ✅ | Clear children + refill; no duplicates |
| Auto-add after UE init | ✅ | Default **on**; wait for character; `autoAdd=false` to skip |
| Hints + tier in Description | ✅ | `Name · hint [S|C|U|P]`, max ~70 chars |
| Bool dropdown Enabled/Disabled | ❌ off | Caused **ACCESS VIOLATION** on CE 7.5; binary **0/1** only |
| Flags → Life/Network/… flat | ✅ | No mid-level `bits @` groups |
| Noise pointers | ✅ | Whitelist → Components/Controllers; rest → **Debug** |

### Localization research (closed paths)

| Path | Result |
|------|--------|
| Item/def/CDO → FText ptr | ❌ none (33–34) |
| Contiguous full loc table walk | ❌ local slabs only (35) |
| Module static ptr → live ns* | ❌ zero (38) |
| Production catalog | ✅ 1× AOB ptr→ns (`InitFromNs` / 36) |

---

## Menu (Unreal Engine) — as implemented

| Item | Behavior |
|------|----------|
| Use when dissecting structures | Structure callbacks toggle |
| **Add / Refresh Player (auto on load)** | Build/update single **Player** group |
| Add / Refresh Inventory Items | Bag + Equipped tree |
| Live track inventory changes | Silent poll; expand restore on rebuild |
| Lookup real item names (once, background) | Prefer InitFromNs; D:/R: helper paths |
| Inventory session checklist (log) | Log-only steps + loc/equip status |
| Debug → Find Inventory Properties | Property dump |

---

## Remaining / optional work

| Priority | Item |
|----------|------|
| **P2** | Release packaging: one drop folder, README, version stamp |
| Low | Zero-AOB loc (accept 1 AOB as final recommended) |
| Low | Equip hotbar index vs in-game slots (soft verify) |
| Low | T5 manual: .CT column width persist |
| Low | Safe Enabled/Disabled bool UI if CE API found |
| Low | vtBinary upstream CE patch |
| Backlog | Slim “safe cheats only” player list |

---

## Scripts index

| Script | Role |
|--------|------|
| `CE75.LUA` | Main CE 7.5 port |
| `inventory_display_helper.lua` | Loc Init / GetTitle |
| `36_init_from_ns_one_aob.lua` | Full map 1 AOB runner |
| `37_loc_key_autopsy.lua` | Bag miss taxonomy |
| `38_find_loc_manager.lua` | Module ns hunt (negative) |
| `39_dump_player_props.lua` | Player prop dump + tiers |
| `CE75_dump_equipment_candidates.lua` | Equip array dumps |

---

## Critical CE 7.5 pitfalls (don’t regress)

1. **`getStructure(i)` index-only** — never pass name string  
2. **Menu `.Name`** — no duplicate MainForm component names  
3. **`print()`** steals focus — use `log()` on hot paths  
4. **Binary:** `mr.Binary.Startbit` / `Size`  
5. **Merge `UEngine.Inv` defaults** on reload  
6. **`AOBScan` has no start/stop range** (alignment args only)  
7. **Loc:** process all ns-ptr hits (`MAX_REFS` high)  
8. **Never assign string to `mr.DropDownList`** — ACCESS VIOLATION  
9. **dofile paths:** use `d:\` / `R:\` the user actually loads  

---

## Documentation currency (honest)

| Current enough to trust | Stale or research-only |
|-------------------------|-------------------------|
| **STATUS** (this file), **NEXT-WORK**, **LOC-NEXT**, **ADDRLIST-UX**, **PLAYER-PROPS**, **EQUIPPED-FINDINGS** | **INVENTORY** / **REFERENCE** / **RELEASE** / **MENU-UX** — offsets & CE facts mostly still true; menus/product flow partially outdated |
| **DISPLAY-NAMES** / **DISPLAY-LINK** | Keep as research archive; production path is LOC-NEXT |

If one file disagrees with **STATUS** or live `CE75.LUA`, **trust the code + STATUS**.
