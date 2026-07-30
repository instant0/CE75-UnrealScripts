# CE75 — Next work plan

**Updated:** 2026-07-25 (evening) — **P0 + P1 implemented in CE75.LUA**  
**Context:** Inventory + GNames + Alkimia display titles are **shipping-quality**. Loc Plan A done (98.3% bag). Script 38 killed static ns\* in module.

---

## Where we are (do not re-open)

| Area | State |
|------|--------|
| Bag chain, categories, live track | ✅ |
| Equipped tab (basic multi-source) | ✅ works; layout incomplete |
| Loc catalog `InitFromNs` (~43k, ~13s, 1 AOB) | ✅ |
| FName → title join | ✅ 284/289; 4 fists + quiver only |
| Item/def → FText pointer | ❌ ruled out |
| Module RVA → live ns\* | ❌ ruled out (38) |

---

## Priority ladder

### P0 — Product polish — **DONE 2026-07-25**

| ID | Status |
|----|--------|
| **P0.1** | ✅ Lookup prefers `InitFromNs` / `InitFromEntry` / `Init`; D:/R: helper paths; tiny map clear |
| **P0.2** | ✅ `HumanFist_*` hidden (`isSystem`; `UEngine.Inv.showSystemItems=true` to show) |
| **P0.3** | ✅ Quiver → Ranged/Quiver + pretty name |
| **P0.4** | ✅ Menu “Inventory session checklist (log)” + first Refresh logs checklist |

---

### P1 — Equipped / hotbar — **DONE (code) 2026-07-25**

| ID | Status |
|----|--------|
| **P1.1** | ✅ Auto stride score on InvMgr+0x158; dump lists all strides |
| **P1.2** | ✅ live (158) → cdo (180) → visual (190) priority |
| **P1.3** | ✅ Visual sub-group; no double logical name |
| **P1.4** | ✅ `(slot)` prefix on equipped rows |
| **P1.5** | ✅ qty when bag-like entry+0x10 parses; else pointer |

**Verify in-game:** equip bow/crossbow, Refresh, check Equipped `(n)` labels + checklist equip parse line.  
**Docs:** `CE75-EQUIPPED-FINDINGS.md`.

---

### P2 — Release packaging (medium process)

| ID | Task | Why | Done when |
|----|------|-----|-----------|
| **P2.1** | **Single drop folder** | D: / R: / projects drift | One README: files to copy, `dofile` order, game attach |
| **P2.2** | **Default menu for end user** | Debug demoted | Debug submenu only; primary = Refresh Inv / Live / Lookup names / Add Player |
| **P2.3** | **Version stamp** | Know which LUA is loaded | Comment header + optional `print` on load (`CE75` date/hash) |

**Docs:** `CE75-RELEASE-PROPOSAL.md` refresh.

---

### P3 — Loc Init comfort (low priority RE)

Only if ~13s `InitFromNs` is painful.

| ID | Task | Why | Done when |
|----|------|-----|-----------|
| **P3.1** | **B3.2 — module refs to FText helper vt** `exe+0x7569B78` | Possible global near pools | Candidate RVAs or abandon |
| **P3.2** | **B3.3 — common heap owner of many entry\*** | Map root / TMap | Walk entries 0 AOB from root |
| **P3.3** | **Accept 1 AOB forever** | Sane default | Documented as final; no more B work |

**Default recommendation:** **P3.3** unless user pushes for zero-AOB.

---

### P4 — Backlog (do not schedule unless needed)

| ID | Task |
|----|------|
| **P4.1** | vtBinary upstream CE patch |
| **P4.2** | Curated “slim player” address list |
| **P4.3** | Magic continuous/recharge subtypes from def (not FName) |
| **P4.4** | Alternate ns for quiver (unlikely) |
| **P4.5** | Player Description hints + `[S/C/U/P]` (T1–T3) | ✅ 2026-07-25 |
| **P4.6** | `39_dump_player_props.lua` glossary dump (T4) | ✅ |
| **P4.7** | Address-list expand-state + Add Player dedupe | ✅ 2026-07-25 (Collapsed restore + player reuse) |
| **P4.8** | T5 manual: save .CT, reload, verify Description column width persists |

---

## Suggested sequence (concrete)

```text
Week / session focus
────────────────────
1) P0.1 → P0.2 → P0.4     Menu + fists + checklist     [CE75.LUA]
2) P1.1 → P1.2            Equip array layout             [dump + play]
3) P1.4 → P1.5 (± P1.3)   Slot labels / qty / clean tree
4) P2.1 → P2.2            Package + menu cleanup
5) P3 only if requested   Zero-AOB experiments
```

---

## Explicit non-goals (for now)

- Re-hunting item→FText fields  
- Lockey grammar passes (0 class-A misses)  
- Module RVA → live ns\* (proven empty)  
- AOB on every inventory open  

---

## Dependencies

| Task | Needs |
|------|--------|
| P0.* | Helper + CE75 on same machine path user actually `dofile`s |
| P1.* | Game session, equip dump tool, live equip/unequip |
| P2.* | Stable P0 behavior |
| P3.* | Optional; full map already works |

---

## Success snapshot (next milestone)

**“v1 inventory release”** when:

1. Lookup names works from menu alone (P0.1)  
2. No HumanFist spam (P0.2)  
3. Equipped shows all hotbar slots with indices (P1.1–P1.4)  
4. Short README for copy/`dofile` (P2.1)  

Loc titles already meet the bar for that milestone.
