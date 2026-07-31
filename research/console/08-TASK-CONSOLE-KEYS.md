# Task 8 — Step F: Register the console key — [fixed]

**Goal:** Make `~` (Tilde) toggle the console by patching the first FKey `KeyName` in the `UInputSettings` CDO `ConsoleKeys` TArray. Runs only when `consoleKeys` lacks `Tilde` (Task 5 signal).

**Depends on:** Task 1 (FName layout: `UEngine.FNameSize`, `UEngine.NameToIndex` + per-string min index `UEngine.NameToIndexMin`), core property walk + object-array helpers.
**Related:** approach #2 (AOB-patch `ConsoleKeys.Contains`) is the fallback for hard-blocked games.

> **Implementation target (per [`SPLITFILE.md`](SPLITFILE.md) §6):** implement `UEngine_patchConsoleKeys()` in **`Scripts/console/console.lua`**. No `UnrealEngine-75.LUA` edit is needed for this task.

---

The toggle key is **not** on `UConsole` (UE3-era). UE4/UE5 use:

```cpp
// UConsole::InputKey_InputLine
if ( GetDefault<UInputSettings>()->ConsoleKeys.Contains(Key) && Event == IE_Pressed && !bModifierDown )
```

So find the `UInputSettings` CDO (object in the array with class name `InputSettings` and `RF_ClassDefaultObject` flag, or name `Default__InputSettings`), read its `ConsoleKeys` (`TArray<FKey>`) property offset via property walk, and inspect the first FKey's `KeyName` (an `FName`). An `FKey` is `{ FName KeyName; TArray<const FKeyDetails*, TInlineAllocator<4>> KeyDetails; }`.

Note: name-based CDO detection (`Default__InputSettings`) depends on the Task 1 `UObject_getName` FNameSize fix on UE5; a layout-safe alternative is matching the ComparisonIndex dword via `UEngine.NameToIndex['Default__InputSettings']`.

If `ConsoleKeys` already contains `Tilde`, nothing to do. If entries exist but wrong key, patch the first entry's `KeyName`:

```lua
-- FName memory layout — use Task 1 result (IMPORTANT: the original plan's "+4 = number"
-- is wrong for UE5):
--   UE4: ComparisonIndex@+0, Number@+4               (8 bytes)
--   UE5: ComparisonIndex@+0, DisplayIndex@+4, Number@+8   (12 bytes)
-- FName equality (used by ConsoleKeys.Contains) compares ComparisonIndex + Number,
-- but ToString() reads DisplayIndex — if DisplayIndex is left 0 the key displays as
-- "None" and console input handling can misbehave.

-- Index selection — [fixed]: CacheNamePool fills N2I[str]=index (last one wins), so on
-- UE5 with case-preserving names the "Tilde" entry may be the DISPLAY-table index, not
-- the comparison-table index that FName::Contains compares. The comparison entry is
-- allocated first, so the LOWEST index for the string is the one we need. Record a
-- per-string minimum alongside the pool enumeration (e.g. UEngine.NameToIndexMin[str])
-- in Task 1/`CacheNamePool`. The console file already wraps this — plus the UE5
-- lowercase `tilde` fallback — in UEngine_nameTargetIndex('Tilde') (console.lua:348);
-- use that instead of reaching for NameToIndexMin directly here.
local idx = UEngine_nameTargetIndex and UEngine_nameTargetIndex('Tilde')
            or UEngine.NameToIndexMin and UEngine.NameToIndexMin['Tilde']
            or UEngine.NameToIndex['Tilde']
if idx then
  writeInteger(fkeyAddr + 0, idx)          -- ComparisonIndex
  if UEngine.FNameSize == 12 then          -- UE5: DisplayIndex + Number
    writeInteger(fkeyAddr + 4, idx)
    writeInteger(fkeyAddr + 8, 0)
  else                                     -- UE4: Number only
    writeInteger(fkeyAddr + 4, 0)
  end
end
```

Validate after writing: resolve the patched FName back and confirm it reads `Tilde` (i.e. the ComparisonIndex actually points at the comparison-table entry). If it resolves to the wrong index, fall back to approach #2.

If `ConsoleKeys` is **empty** — note this is the RARE case: `UInputSettings`' default ctor adds Tilde+BackSpace to `ConsoleKeys` in **all** build configs, so an empty array means an INI (`[/Script/Engine.InputSettings] ConsoleKeys=(Key=None)`) or a code patch cleared it. The realistic disable is a *wrong* key, which the overwrite above already handles. For the empty case, growing the `TArray` requires engine allocation and is risky. Options: (a) **in-place fill when the array still holds capacity** (`dataPtr≠0`: write element 0 and set `Num=1` — no allocation, hence foreign-thread-safe), (b) patch the `ConsoleKeys.Contains` check / `APlayerController::ConsoleKey` via AOB (approach #2), (c) find a valid FKey elsewhere in the settings object and reuse its allocation, or (d) accept programmatic activation only. When `dataPtr==0` there is no capacity: **record the need explicitly** (`'keys: empty; needs approach #2 AOB / programmatic'`) — never silently skip. Prefer (a), then record (b/d) as the documented fallback (the AOB hunt itself is deferred; see the Implementation review below).

If `Tilde` is not in the name pool, try `BackSpace`/`Tab` (both are engine keys and virtually always loaded).

---

## Definition of done

- `UInputSettings` CDO located; `ConsoleKeys` TArray property offset resolved.
- First FKey's `KeyName` written with `Tilde`'s ComparisonIndex (and DisplayIndex+Number on UE5).
- `Tilde` key toggles the console (works together with Task 7's instance).
- Empty-array case: in-place fill when capacity exists (`dataPtr≠0`); otherwise AOB fallback or programmatic activation **recorded explicitly, not silently skipped**.

## Verification

1. Patch a game whose `ConsoleKeys` holds a wrong key → `~` toggles console.
2. UE5 target: all three FName fields correct (console displays `Tilde` — a lowercase `tilde` render is a documented cosmetic, not a fail — input works), and the written ComparisonIndex resolves back to `Tilde` (comparison-table entry, not display-table; accept the lowercased comparison entry on UE5).
3. Re-run: `Contains(Tilde)` already true → no write (idempotent).
4. Empty array: fallback path exercised or need recorded as unpatched.

---

## Implementation review (2026-08-01) — plan locked, no blocking research

Review against the current tree (`Scripts/console/console.lua`, 1333 lines; core `UnrealEngine-75.LUA` 4560 lines). **Verdict: Task 8 is implementation-ready.** Every primitive already exists from Tasks 1–5; the remaining unknowns are two locked decisions plus live-target verification.

### Verified available (no new research needed)

| Primitive | Location | Notes |
|---|---|---|
| `UEngine_findCDO('Default__InputSettings')` / `UEngine_findCDOByClassName('InputSettings')` | `console.lua:611`, `:620` | Task 5's single-pass walk already caches `DevConsoleState.inputSettingsCDO` — pass it in to skip a re-walk |
| `ConsoleKeys` TArray offset + first FKey `KeyName` read (`Data@+0`, `Num@+8`) | `UEngine_readConsoleKeys`, `console.lua:665` | the read half of the patch; share its CDO→property→`dataPtr` derivation |
| `UEngine_nameTargetIndex('Tilde')` | `console.lua:348` | returns the LOWEST (comparison-table) index incl. the UE5 lowercase `tilde` fallback — use this, not raw `NameToIndexMin` (see the corrected snippet above) |
| FName layout (`UEngine.FNameSize` 12/8) | Task 1 | UE5 CI/DI/Num @0/4/8 vs UE4 CI/Num @0/4 — branch on `FNameSize`, never on flavour alone (shipping UE5 has 8-byte FNames) |
| post-write validation | `UEngine_resolveFName` (`UnrealEngine-75.LUA:4166`) + `UEngine_fnameIndexToString` | resolves a ComparisonIndex back to its string |
| property walk | `UEngine_getAllProperties` (`UnrealEngine-75.LUA:190`) | proven by Task 5 to surface `ConsoleKeys` (ArrayProperty) with offset |

### Corrections to the plan text

1. **"Empty is the common shipping disable" is wrong** — corrected inline above. `UInputSettings`' default ctor adds Tilde+BackSpace in all build configs, so the array is normally non-empty; empty means an INI/code clear. **Wrong-key is the realistic primary path** (overwrite). Implementation order: wrong-key overwrite → idempotent no-op → empty-array edge.
2. **Empty-array handling decision (locked):** in-place fill when `dataPtr≠0` (write element 0 + `Num=1`, no allocation → foreign-thread-safe); record `'keys: empty; needs approach #2 AOB / programmatic'` when `dataPtr==0`. Do **not** implement the approach #2 AOB `Contains` patch in this task — it is a live-target, version-pinned AOB hunt (same class as Task 7's SCO patterns) that cannot be done from the shell.
3. **UE5 DisplayIndex nuance (cosmetic, don't block):** writing the comparison `tilde` index into `+4` renders `"tilde"` instead of `"Tilde"`; `Contains` compares ComparisonIndex+Number only, so the toggle is unaffected. Optional refinement: write the exact-case display index into `+4` when `NameToIndex['Tilde']` exists, else the comparison index (avoids the `"None"` display).
4. **Old-UE4 KeyDetails note (don't block):** patching only `KeyName` leaves `FKey::KeyDetails` empty. The `Contains` toggle compares FName only — works. UE4.20+/UE5 resolve `FKeyDetails` lazily from the database by `KeyName`; pre-4.20 the key's display/axis could degrade (never the toggle). Not a gate.

### Implementation outline — `UEngine_patchConsoleKeys(t, cdo)`

- Signature `UEngine_patchConsoleKeys(t, cdo)`; `cdo` = `DevConsoleState.inputSettingsCDO` (fall back to `UEngine_findCDO`/`findCDOByClassName` when not passed).
- Refactor the CDO→property→`dataPtr`/`count` derivation shared with `UEngine_readConsoleKeys` into one helper so read and write agree (it already logs `count`/first key).
- Branch:
  - first key already `tilde` → `true,'already set'` (idempotent, no write);
  - `count>0`, wrong key → `idx=UEngine_nameTargetIndex('Tilde')`, write `fkeyAddr+0` (CI), and on `FNameSize==12` `+4` (DI) `+8` (Num=0), else `+4` (Num=0) — corrected snippet above;
  - `count==0` and `dataPtr≠0` → in-place fill (write element 0's `KeyName`, set `Num=1`);
  - `count==0` and `dataPtr==0` → `nil,'keys: empty; needs approach #2 AOB / programmatic'` (recorded).
- `idx==nil` (Tilde absent from pool) → fall back to `UEngine_nameTargetIndex('BackSpace')`, then `'Tab'`.
- Validate: re-read CI, resolve via `UEngine_resolveFName`/`IndexToName`, accept `tilde`/`Tilde` → `true,'written'`; mismatch → `nil,'resolve failed'`.
- Plain memory write to the CDO property — safe off the game thread (no engine call). Return strings must match the Task 10 orchestrator `needs`/status contract.
- **No `UnrealEngine-75.LUA` edit.** `luac -p` + `loadfile` pass from the shell; a mocked-`writeInteger` unit test is shell-runnable; the `~`-toggle DoD is a CE attach.

---

## Change log — implemented 2026-08-01

### What was implemented (`Scripts/console/console.lua`, +113 lines)

| # | Change | Location |
|---|--------|----------|
| 1 | **Shared helper `UEngine_resolveConsoleKeys(t, cdo)`** — CDO→property→TArray derivation (name-primary, class-name-fallback CDO find; `ConsoleKeys` property offset; `Data@+0` / `Num@+8`). Returns `cdo, propOffset, dataPtr, count` or `nil,reason`. Read and write sides now agree by construction. | `console.lua:667` |
| 2 | **`UEngine_readConsoleKeys` refactored** onto the helper (behaviour-identical; the 4 error messages + `count`/`first` log line unchanged). | `console.lua:695` |
| 3 | **`UEngine_patchConsoleKeys(t, cdo)` implemented** per the Implementation outline above: idempotent `already set`; wrong-key overwrite with `UEngine_nameTargetIndex('Tilde')` (BackSpace→Tab fallback); FName write branched on `UEngine.FNameSize` (12: CI/DI/Num; 8: CI/Num); empty-with-capacity in-place fill (`Num=1`); empty-no-capacity recorded `'keys: empty; needs approach #2 AOB / programmatic'`; post-write validation via `UEngine_fnameIndexToString` (accepts lowercased comparison entry); FName-layout-unresolved guard. | `console.lua:1305` |

No `UnrealEngine-75.LUA` edit. No new cache keys (reuses `DevConsoleState.inputSettingsCDO` when passed; falls back to its own CDO walk otherwise).

### Return contract (Task 10 needs-list compatible)

- `true,'already set'` — first key already `Tilde` (idempotent, zero writes).
- `true,'written'` — first FKey `KeyName` written; `[in-place fill]` logged when an empty array that held capacity was filled (`Num` 0→1).
- `nil,'<reason>'` — blocked/unpatched, always explicit: `'UInputSettings CDO not found'`, `'ConsoleKeys property not found'`, `'UObject offsets not initialized'`, `'keys: FName layout unresolved (<err>)'`, `'keys: target key not in name pool (Tilde/BackSpace/Tab); needs approach #2 AOB / programmatic'`, `'keys: empty; needs approach #2 AOB / programmatic'`, `'keys: write did not resolve (<name>); needs approach #2 AOB / programmatic'`.

### Verification (shell, 2026-08-01)

- `luac -p Scripts/console/console.lua` ✅ · `loadfile` ✅.
- **Mocked-write unit test** (`/tmp/opencode/task8_test.lua`, mock CE `read/writeInteger/Pointer`, `UEngine_resolveFName`, `IndexToName`, `NameToIndexMin`, `UEngine_getAllProperties`): **28/28 checks pass** — T1 wrong-key→`written` (CI+Num); T2 already-`Tilde`→`already set`, no write; T3 empty-with-capacity→in-place fill, `Num=1`; T4 empty-no-capacity→recorded; T5 `Tilde`-absent→`BackSpace` fallback; T6 `FNameSize==12` CI/DI/Num; T7 CDO-not-found; T8 FName-layout-unresolved; T9 `readConsoleKeys` parity after refactor; T10 no target key in pool.

### Outstanding (CE attach, not shell)

- DoD items 1–3: patch a real game whose `ConsoleKeys` holds a wrong key → `~` toggles; UE5 target verifies the three FName fields + ComparisonIndex resolves to the comparison-table entry; re-run idempotence on a live target.
- README status board already updated to `✅ (impl. 2026-08-01; CE-verification pending)` (matches Task 7's convention); flips to plain `✅` after the CE attach verification.
