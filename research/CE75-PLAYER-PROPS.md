# Player / Character address-list: hints, safety, CE tooltips

**Updated:** 2026-07-25  
**Code:** `CE75.LUA` — `UEngine_PlayerPropHints`, `UEngine_playerPropHint`, `UEngine_addPlayerToAddressList`

---

## 1. Does CE 7.5 support tooltips on the address list?

### Investigated (CE 7.5 source)

| Surface | Finding |
|---------|---------|
| `LuaMemoryRecord.pas` | **No** `Tooltip` / `Hint` property on `MemoryRecord` |
| Exposed fields | `Description`, type, address, offsets, dropdowns, colors, hotkeys, … |
| Address list UI | List shows **Description** (+ value/address columns). No hover-tooltip API wired to records |
| Other Hints in CE | Form buttons (e.g. offset add/remove) use `ShowHint`/`Hint` — **not** address-list rows |

**Conclusion for posterity:**  
**Cheat Engine 7.5 does not expose per-entry tooltips for the main address list via Lua.**  

### Description column width

| Question | Answer |
|----------|--------|
| Does the list **auto-adjust** width to show full Description? | **No** (typical CE UI). Column width is **user-resized** / saved with the table; long text is clipped with `…` in the cell unless you drag the column wider. |
| What we do | Cap formatted Description at **~70 characters** (`PROP_DESC_MAX` in `UEngine_addPlayerToAddressList`) so name + helptext fit a normal width. |

Practical ways to attach meaning:

| Approach | Pros | Cons |
|----------|------|------|
| **Append to `Description`** (current) `Name · short hint`, **max ~70 chars** | Always visible, works | Must truncate long hints |
| **Group hierarchy** Flags→Tick, Movement, … | Navigation | Not a full glossary |
| **External doc** (this file) | Room for safety notes | Must open separately |
| **Child comment row** under each prop | “documentation row” | Doubles tree size |
| **CE table comments / separate list** | Free-form | Manual |

**Do not** expect `mr.Tooltip = '…'` to work unless a future CE version adds it (verify in newer CE Lua docs if upgrading).

---

## 2. What we show

On **Add Player**, each property Description is roughly:

```text
PropertyName · short hint [S]
```

(≤70 chars; tier tag when known.)

### Bool / bit values (UX)

Bools use `vtBinary` + optional dropdown when CE accepts it:

| Memory value | Display |
|--------------|---------|
| 0 | **Disabled** |
| 1 | **Enabled** |

**Implementation note (CE 7.5):** `DropDownList` is a **TStringList object** (read-only property). Use `list.clear()` + `list.add('0:Disabled')` only.  
**Never** `mr.DropDownList = '…string…'` — that overwrites the object pointer and causes **ACCESS VIOLATION**.

Click the **value** cell → pick Enabled/Disabled (no typing 0/1).  
True one-click toggle (no menu) is not a stock CE address-list feature without a hotkey/script.

### Flag grouping (name-based, not runtime “value analysis”)

All bools under **Flags → &lt;sub&gt;**. Subs are chosen from the **property name** (and type), e.g.:

| Sub | Examples |
|-----|----------|
| Life | `bCanBeDamaged`, health/damage/life/death/god |
| Network | `bNet*`, replicate, dormant |
| Movement | jump, crouch, walk, controller rotation |
| Tick | tick-related |
| … | see `UEngine_playerFlagSub` |

Non-bools (e.g. `InitialLifeSpan` float) stay under top-level **Life**.  
So Life numbers and Life flags are **siblings in meaning**, different trees (value vs Flags→Life) — intentional: one place for “life combat” bools, one for life numerics.

**Natural grouping** = UE name semantics + property type, not clustering by current 0/1 values (those change every frame and do not define categories).

---

## 3. Safety model (for editing values)

Editing live UE objects can crash the game, desync multiplayer, or corrupt the session. Treat tiers as **guidance**, not guarantees.

| Tier | Meaning | Edit? |
|------|---------|--------|
| **S — Safe-ish** | Commonly tweaked for single-player cheats; usually recoverable | OK with care |
| **C — Caution** | May break movement/camera/AI until reload or state reset | Prefer read; small experiments |
| **U — Unsafe** | Engine/replication/lifecycle; high crash or soft-lock risk | **Read-only** unless you know the call site |
| **P — Pointer** | Object references; changing without a valid UObject* is crashy | Do not poke random values |
| **?** — Unknown | Not classified yet | Treat as **C** or **U** |

### Known / common AActor · APawn · ACharacter (UE-style)

| Property | Tier | Notes |
|----------|------|--------|
| `Role` / `RemoteRole` | **U** | Authority model; wrong value → weird net/authority behavior |
| `bNet*` / replication flags | **U** | Designed for multiplayer; SP may still trip internal assumes |
| `NetUpdateFrequency` / `NetPriority` / `NetCullDistanceSquared` | **C** | Mostly net; SP often ignored |
| `NetDormancy` | **C/U** | Can stop updates if set dormant wrongly |
| `bReplicates` / similar | **U** | |
| `InitialLifeSpan` | **C** | `>0` can destroy actor after N seconds |
| `CustomTimeDilation` | **C** | `0` freezes actor; huge values mess timers |
| `bCanBeDamaged` | **S** | Under **Flags → Life**; god-mode experiments |
| `bHidden` / visibility | **C** | Can hide mesh/collision inconsistently |
| `bActorEnableCollision` | **C** | Fall through world / stuck |
| Jump* / crouch-related floats on Character | **S/C** | Classic cheat surface; watch CMC also |
| `BaseEyeHeight` / `CrouchedEyeHeight` | **S** | Camera feel |
| `AutoPossessPlayer` / AI possess | **C** | Can steal control |
| `Controller` / `PlayerState` / `Mesh` / `CharacterMovement` | **P** | Valid object or crash |
| `RootComponent` | **P/U** | Detaching root = bad |
| Tick-related bools (`bCanEverTick`, …) | **C/U** | Disabling tick can freeze logic |
| `InstantiatedSoftObjectPointers` | **P/U** | Internal; do not edit |
| RayTracing* | **?** | Cosmetic/engine; leave alone |

### Gothic 1 Remake (project-specific)

Fill as you identify real names from dumps:

| Property / pattern | Tier | Notes |
|--------------------|------|--------|
| *(TBD from `Debug: dump inventory-related properties` / full prop dump)* | | Prefer gameplay HP/stamina/speed over engine bools |
| Inventory is **not** on flat Character props we edit here | — | Use Inventory menu; safer for item qty |

---

## 4. Investigation plan (expand documentation)

### 4.1 Export full property list (once per build)

Menu **Debug → Find Inventory Properties** or full class dump already prints many props. Better: small script **`39_dump_player_props.lua`** (todo) that writes:

```text
offset  type  name  bucket  flagSub  knownHint  tierGuess
```

to `CE75-PLAYER-PROPS-DUMP.txt` for offline review.

### 4.2 Classify in passes

| Pass | Focus |
|------|--------|
| 1 | All `b*` bools → Flags subs + tier U/C by name (Net/Tick = U/C) |
| 2 | Floats/ints with Jump/Speed/Health/Damage → S/C |
| 3 | Object/Struct pointers → **P** always |
| 4 | Gothic-prefixed / AS-generated names → research in-game |

### 4.3 Present in CE without tooltips

| Option | Implementation |
|--------|----------------|
| **A (recommended)** | Description: `Name · hint` within **70 chars**; later optional `[S]`/`[C]`/`[U]`/`[P]` if space |
| **B** | Optional child row `// hint` (group header false, no address) — heavy |
| **C** | Only document here; keep Description short |

Default recommendation: **A** for known map entries; heuristic short hint without tier for the rest (avoid claiming S/U wrongly).

### TODOs (player Description / docs)

| ID | Task | Status |
|----|------|--------|
| **T1** | Cap Description ~70 + pack `Name · hint` | ✅ `UEngine_formatPlayerPropDescription` |
| **T2** | Expand short hints map | ✅ expanded + heuristics |
| **T3** | Safety tag `[S]`/`[C]`/`[U]`/`[P]` in budget | ✅ tier map + infer; dropped first if over 70 |
| **T4** | Dump all Character props → glossary file | ✅ `39_dump_player_props.lua` |
| **T5** | Confirm CE table save restores Description column width | 📋 **manual only** (save .CT, restart CE, reload table, check column) |

### 4.4 Optional “safe player” slim list (later)

Separate menu: **Add slim player (safe cheats)** with only S-tier offsets once known (HP, god, speed) — `CE75-NEXT-WORK` P4.2 style.

---

## 5. Answers (short)

| Question | Answer |
|----------|--------|
| Tooltips on list? | **No** in CE 7.5 Lua for address-list rows |
| Investigate more entries? | **Yes** — dump + this doc + optional `[S/C/U/P]` in Description |
| Unsafe to edit? | Net/role/tick/lifecycle/pointers = **U/P**; movement cheats = **S/C**; when unsure, **read only** |

---

## 6. Code touchpoints (when implementing tiers)

| File | Change |
|------|--------|
| `CE75.LUA` | Expand `UEngine_PlayerPropHints`; add `UEngine_playerPropTier(name)` → append `[S]` etc. in `labeledDesc` |
| `CE75-PLAYER-PROPS.md` | Keep glossary + safety table |
| Optional `39_dump_player_props.lua` | CSV/text dump for offline labeling |

No CE engine patch required for Description-based hints.
