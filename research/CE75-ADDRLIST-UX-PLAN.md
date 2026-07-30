# Address-list UX: collapse on refresh + duplicate Player

**Updated:** 2026-07-25  
**Related:** `CE75.LUA` (`UEngine_buildInventoryAddressList`, `UEngine_addPlayerToAddressList`), `CE75-NEXT-WORK.md`

---

## Problems (user-reported)

| # | Symptom | Cause (current code) |
|---|---------|----------------------|
| **1** | Turning on **Live track** / any rebuild **collapses** Inventory (and nested tabs) | `UEngine_buildInventoryAddressList` **deletes** the whole tree (`UEngine_destroyInvTree`) and recreates groups with `moHideChildren` → CE shows them **collapsed** |
| **2** | Equip change while expanded → same collapse | Live timer calls refresh → fingerprint changes → full rebuild → same as (1) |
| **3** | **Add Player** again creates a **second** Character group | Always `createMemoryRecord()`; never finds/reuses existing root by name or stored `UEngine.Player.rootMR` |

These are UX bugs, not game memory bugs.

---

## What “Inventory session checklist (log)” does

It is **only a log helper** — it does **not** change memory or the address list.

`UEngine_logInventorySessionChecklist()` prints to the CE log:

1. Suggested session order: attach → open inv once → Lookup names → Refresh → optional Live track  
2. Whether **loc map** is ready (`InventoryDisplay_IsReady`)  
3. Last **equip parse** meta if any (`InvMgr+0x158` data/count/stride/hits)

Triggered by:

- Menu **Inventory session checklist (log)**  
- First **Add / Refresh Inventory** in a session (once)

Safe to ignore day-to-day if you already know the flow.

---

## Fix plan

### Fix A — Inventory: preserve expand state (P1.5-style UX)

**Goal:** After live refresh / equip change, tree looks as expanded as before.

#### A.1 Save collapse state before destroy

Before `UEngine_destroyInvTree()`:

```text
walk Inventory root + children
for each MemoryRecord that is a group header:
  key = path e.g. "Inventory\Equipped\Ranged"
  expanded[key] = not collapsed  -- CE API: try mr.Collapsed / Options / Active
```

CE 7.5 Lua: verify which property works (try in order):

| Candidate | Notes |
|-----------|--------|
| `mr.Collapsed` | Boolean if exposed |
| `mr.Options` string contains collapse flags | Fragile |
| `AddressList.getCollapsed` / tree node | Version-dependent |

Spike: one group, expand, read fields, collapse, read again — document the working API.

#### A.2 Rebuild tree (unchanged structure)

Keep current build (tabs → subs → items) so keys stay stable:

```text
Inventory
  Equipped
    Melee / Ranged / Visual / …
  Food
  …
```

Path keys must match save step (same tab/sub names).

#### A.3 Restore expand state after build

For each recreated group MR with matching key:

- If was expanded → clear collapse / set Collapsed=false  
- Root Inventory: if user had it open, restore open  

Default for **new** groups (first run): keep `moHideChildren` (collapsed) — only restore **known** keys.

#### A.4 Optional: in-place update (harder, nicer)

Instead of delete-all:

1. Diff fingerprint → list added/removed/changed names  
2. Remove only vanished item MRs  
3. Add only new item MRs under existing parents  
4. Update Description/Address on existing rows (qty already live via chain)

**Pros:** No flash, expand state native.  
**Cons:** More code; edge cases (tab empty, rename after loc load).

**Recommendation:** implement **A.1–A.3 first** (save/restore). If still janky, do A.4 later.

#### A.5 Live track first activation

Today: enable Live → immediate force refresh → rebuild → collapse.

After A.1–A.3:

- First activation still rebuilds once if needed, but **restores** expand if tree already existed  
- If tree missing, first build may still start collapsed (OK)

Also: on Live enable, if `lastFp` matches and root exists, **skip** rebuild (already partly true for non-force; check first refresh uses `force=true` and always rebuilds).

```lua
-- setInventoryLiveTracking(true) currently:
UEngine_refreshInventoryAddressList(true)  -- force=true always rebuilds
```

Change to:

```lua
UEngine_refreshInventoryAddressList(false)  -- only rebuild if fp changed
-- or force only if no rootMR
```

---

### Fix B — Add Player: update in place (no duplicate) — **DONE 2026-07-25**

**Goal:** Second click refreshes the same Character group.

| Piece | Status |
|-------|--------|
| `UEngine.Player.rootMR` + `rootClassName` | ✅ |
| Clear children + refill on reuse | ✅ |
| Find by description / `(N props)` prefix | ✅ `UEngine_findPlayerRootMR` |
| Auto-add after UE init when character exists | ✅ `UEngine_scheduleAutoAddPlayer` (opt out: `UEngine.Player.autoAdd=false`) |

Still open: **Fix A** inventory expand-state on live refresh.

---

## Implementation order

| Step | Work | Status |
|------|------|--------|
| 1 | Spike CE 7.5 expand/collapse Lua API | ✅ `mr.Collapsed` (pcall) |
| 2 | **A.5** Live track: no force rebuild if tree exists | ✅ |
| 3 | **A.1–A.3** save/restore expand paths on inv rebuild | ✅ `UEngine_invCaptureExpandState` / restore |
| 4 | **B.1–B.3** Player root reuse | ✅ |
| 5 | (Optional) **A.4** in-place inv row patch | open if still janky |

**Note:** `Collapsed` is on `TMemoryRecord` in CE 7.5 Pascal; Lua binding is not explicit — restore uses `pcall(mr.Collapsed=…)`. If expand still resets, CE may not publish Collapsed to Lua → then A.4 or CE upgrade.

---

## Success criteria

| Check | Pass |
|-------|------|
| Expand Inventory → Equipped → Ranged; equip item; live refresh | Groups stay expanded |
| Enable Live with tree already open | Does not force-collapse if no change; if change, restore expand |
| Add Player twice | One Character group; contents refreshed |
| Checklist menu | Still only logs; no side effects |

---

## Out of scope

- Changing equip detection logic  
- Loc Init  
- CE core patches for TreeView  

---

## Checklist log — one-line summary

**Debug/session helper only:** prints recommended steps + loc/equip status to the log. Not required for normal use.
