# CE75 Menu UX — Current State, Feedback & Implementation Plan

**Date:** 2026-07-24  
**Related:** `CE75-RELEASE-PROPOSAL.md`, `CE75-STATUS.md`, `CE75-DISPLAY-NAMES.md`, `CE75-DISSECT-CRASH.md`

---

## 1. Menu map (what each item does today)

| Menu item | What it does | User-facing value |
|-----------|--------------|-------------------|
| **Find Inventory Properties** | Debug dump: walks GE→Char, searches property names matching Inventory/Item/…, **prints** everything to Lua log | **Dev/debug only** — does not add a usable inventory tree. Confusing for end users. |
| **Add Player to Address List** | Dumps **all** Character properties under `PlayerCharacterBP_C` via GEngine pointer chain | Useful for reverse engineering; messy for daily use |
| **Add / Refresh Inventory Items** | Verified bag walk (+0x7B0…); categories; internal/display names; qty | **Primary inventory feature** |
| **Live track inventory changes** | 1s timer; rebuild tree only when slots/types change | Near real-time add/remove |
| **Lookup real item names** | Background load of Alkimia loc map, then refresh labels | Optional polish |

---

## 2. Feedback vs current behavior

### 2.1 Find Inventory Properties

| | |
|--|--|
| **Issue** | Unclear purpose; floods Lua log |
| **Reality** | Research helper from before the fixed inv chain existed |
| **Plan** | **P1:** Rename to `Debug: dump inventory-related properties` or move under a **Debug** submenu. **P2:** Optional — remove from default menu once Add Inventory is trusted. |
| **Implement** | Caption + `miDebug` parent; keep function for developers |

### 2.2 Add Player — BoolProperty as Byte

| | |
|--|--|
| **Issue** | `bSomething` flags share one byte; CE needs **Binary** + **bit index**, not Byte |
| **Reality** | Code used `vtByte` for BoolProperty; dissect path already had `vtBinary`+BitStart |
| **Plan** | **Done (partial):** Add Player now sets `vtBinary` + BitStart from FProperty bitmask when available; groups multi-bools at same offset under a collapsible header with `moHideChildren` |
| **Open questions** | Does CE 7.5 MemoryRecord use `BinaryStart` or `BitStart`? May need both (already pcall both). Verify in UI after reload. |
| **Follow-up** | If bits still wrong, dump one BoolProperty’s BitMaskField bytes and map CE API from `LuaMemoryRecord.pas` |

### 2.3 Add Player — organization / collapse

| | |
|--|--|
| **Issue** | Flat list; hard to minimize; want Map / movement / flags groups |
| **Plan** | **P1 (done):** root group `moHideChildren` + flag subgroups. **P2:** Heuristic buckets by name prefix (`b`→Flags, `Movement`/`Velocity`→Movement, `Camera`→Camera, else Other). **P3:** Optional “slim player” menu that only adds a curated offset list (HP, pos, …) once known. |
| **Feasibility** | High for name heuristics; curated list needs gameplay research |

### 2.4 Add Inventory — Lua log steals focus

| | |
|--|--|
| **Issue** | `print()` opens/focuses Lua Engine |
| **Plan** | **Done:** inventory path uses `log()` only; errors via `showMessage` if needed |
| **Note** | Other menus (Find Inventory) still print by design until demoted to Debug |

### 2.5 Add Inventory — only name + qty; GEngine pointer path

| | |
|--|--|
| **Issue** | Too many child rows; absolute addresses |
| **Plan** | **Done:** one row per item — Description = display/internal name, Type = Dword, Address = **qty** via `UEngine_setChainAddress(GEngine, chain…, slot*0xB8+0x10)` when chain known; fallback absolute |
| **Open questions** | Confirm CE shows `[[…GEngine…]]+…` and value tracks qty after zone change. If chain breaks on TArray layout, keep absolute + Refresh/Live. |
| **Categories** | Still grouped under Melee/Food/… headers (navigation); no sub-rows for id/slot unless Debug mode later |

### 2.6 Lookup real item names failed

| | |
|--|--|
| **Issue** | `helper missing` — path only on Linux project dir |
| **Plan** | **Done:** multiple paths + copy helper to `LUA/inventory_display_helper.lua`; log which path loaded |
| **User action** | Reload CE75.LUA; ensure helper sits next to CE75 or under `ue-scan-gothic/`; open inv once then **Lookup real item names** |
| **Runtime rule** | Never Init on every inventory open — only menu / once per session (`InventoryDisplay_IsReady`) |

### 2.7 Live tracking

| | |
|--|--|
| **Status** | Implemented (1s poll, fingerprint without qty) |
| **Plan** | Keep; document 1s latency; optional interval setting later |

---

## 3. Target address-list shapes

### Inventory (v1 — shipping shape)

```
Inventory (318 items)                    [group, collapsible]
├── Melee (34)
│   ├── Club                             addr = GEngine→…→qty   value = 1
│   └── …
├── Food (59)
│   ├── Apple  [ItFo_Apple]              real name + internal if both
│   └── …
└── …
```

### Player (v1.1)

```
PlayerCharacterBP_C                      [group, collapsible]
├── flags @ +0xABC (8 bits)              [group]
│   ├── bCanClimb                        Binary bit0
│   └── …
├── Movement                             [group — P2]
│   └── …
└── …
```

---

## 4. Implementation roadmap

| Phase | Work | Effort | Priority |
|-------|------|--------|----------|
| **A** | Inventory single-line + GEngine qty path + quiet log | Small | ✅ Done |
| **B** | Player BoolProperty Binary + flag groups | Small | ✅ Done |
| **C** | Helper path / real names menu | Small | 🔄 Partial (~210/283) |
| **D** | Demote Find Inventory to Debug submenu | Tiny | ✅ Done |
| **E** | Player property buckets (Movement/Network/…) | Medium | ✅ Done |
| **E2** | Inv subcategories + strip ItXX_ | Small | ✅ Done |
| **E3** | Equipped tab (InvMgr+0x158 / Mgr+0x180 / Children) | Medium | ✅ Done |
| **E4** | Auto-init GEngine on menu actions | Small | ✅ Done |
| **F** | Full localized titles / loc manager | Research | **Next** |
| **G** | Curated “Player essentials” list | Research | Later |
| **H** | Stats on expand (def+0x70) | Research | Later |

---

## 5. Verification checklist (you)

1. Reload CE75.LUA (dofile OK without CE restart).  
2. **Add / Refresh Inventory Items** — no Lua window focus; tree = categories → name rows; value = qty; address looks like pointer expression.  
3. Pick up / drop item with **Live track** on — appears/disappears ≤1s.  
4. **Lookup real item names** — log should say helper path + refreshed; Apple/Club etc.  
5. **Add Player** — `b*` entries type Binary; parent collapses.  

---

## 6. Comments / questions

| Topic | Comment |
|-------|---------|
| Find Inventory | Safe to hide from users; chain is hardcoded for G1R |
| Pointer qty path | Preferred; if unstable after travel, Live/Refresh fixes absolute fallback |
| Real names ~74% | Good enough for menu; missing runes still show internal id |
| Sub-categories under inv tabs | Optional; top-level 10 tabs already match game UI |
| Inject for loc manager | Still avoid; session Init is enough |

---

## 7. Doc index

| Doc | Role |
|------|------|
| **This file** | Menu UX feedback + plans |
| `CE75-RELEASE-PROPOSAL.md` | Broader release phases + threading |
| `CE75-STATUS.md` | Live checklist |
