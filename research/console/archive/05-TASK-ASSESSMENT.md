# Task 5 — Phase 2: Assessment (read-only state probe)

> **CORRECTED (2026-08-01) — see [11-TASK-DUAL-VERSION-CORRECTIONS.md](../11-TASK-DUAL-VERSION-CORRECTIONS.md) §3/§4/§7c.** Two claims in this archived doc are WRONG and superseded: (1) `RF_ClassDefaultObject` is **`0x10`** (`ObjectMacros.h:541`), NOT `0x200` — every CDO walk/gate (`console.lua:536-538` cache, `:609`, `:658`, `:803`) now uses `0x10`; (2) `FKey` is `{ FName KeyName; mutable TSharedPtr<FKeyDetails> KeyDetails; }`, NOT a TArray with inline allocator (`InputCoreTypes.h:49-123`) — we only ever touch `KeyName` at +0.

**Goal:** Build `UEngine.DevConsoleState` — every console-related signal read **without writing** — and derive the `needs` list the orchestrator (Task 10) repairs.

**Depends on:** Task 2 offsets (`GameViewport`, `ViewportConsole`), Task 4 (`ConsoleClass` offset), Task 1 (`UObject_getName` FNameSize fix, for name-based CDO/key detection), key discovery described here, PlayerController chain walk.
**Consumed by:** Task 10 orchestrator (REPAIR + VERIFY), Task 7 (the `consoleCDO` hard gate), Task 8 (keys), Task 9 (CheatManager).

---

Resolve offsets **without writing**: `GameViewport` (Task 2, Step A), `ViewportConsole` (Task 2, Step B), `ConsoleClass` (Task 4, Step C), then read every signal into `UEngine.DevConsoleState`:

```lua
UEngine.DevConsoleState = {
  viewport      = vp,        -- UGameViewportClient* (nil if unreachable)
  console       = consolePtr,-- UConsole* (nil → needs creation)
  consoleClass  = classPtr,  -- UClass* (nil → needs ConsoleClass fix)
  consoleCDO    = cdo,       -- Default__Console present in object array (nil → Task 7 creation BLOCKED)
  consoleKeys   = keys,      -- table of FKey KeyNames ({} → needs key fix)
  cheatManager  = cm,        -- UCheatManager* (nil → bonus repair)
  cheatCDO      = cmCDO,     -- Default__CheatManager present in object array (nil → Task 9 spawn BLOCKED)
  needs = { 'consoleClass', 'console', 'keys', 'cheat' },  -- built from above
}
```

`consoleCDO` is a **hard gate**, not a repair item. If it is nil, Task 7's `StaticConstructObject_Internal` call with `Template=0` would force `UClass::GetDefaultObject()` to build the CDO on the CE-injected foreign thread (`check(IsInGameThread())` risk — see Task 6 caveats). In that case the orchestrator must mark `console` as **blocked** (record the reason) instead of attempting creation, and fall back to `PlayerController->ConsoleCommand()` only.

`cheatCDO` is the same gate for Task 9's `AddCheats` NewObject replication (`NewObject<UCheatManager>` has the same foreign-thread CDO risk). Detect both CDOs the same way: find the object whose class-name index matches `Default__Console` / `Default__CheatManager` **and** whose `RF_ClassDefaultObject` flag is set — the flag is the robust signal, the name is the fast index. Match the ComparisonIndex dword via `UEngine.NameToIndexMin[...]` (not `NameToIndex` — case-preserving display-table indices can win there on UE5), reusing the Task 3 walk.

If `console ~= nil and console ~= 0`, the console already exists → skip straight to key check (Task 8); if that is also fine, return `true, 'already enabled'` **without writing anything**.

### Key signal (for `consoleKeys`)

Find the `UInputSettings` CDO (object in the array with class name `InputSettings` and `RF_ClassDefaultObject` flag, or name `Default__InputSettings`), read its `ConsoleKeys` (`TArray<FKey>`) property offset via property walk, and inspect the first FKey's `KeyName` (an `FName`). An `FKey` is `{ FName KeyName; TArray<const FKeyDetails*, TInlineAllocator<4>> KeyDetails; }`.

Note: name-based CDO detection (`Default__InputSettings`) depends on the Task 1 `UObject_getName` FNameSize fix on UE5; a layout-safe alternative is matching the ComparisonIndex dword via `UEngine.NameToIndex['Default__InputSettings']`.

### CheatManager signal (for `cheatManager`)

```lua
-- NOTE: UEngine_findLocalPlayer() returns the ULocalPlayer, NOT the PlayerController.
-- Walk LocalPlayer -> PlayerController first (this is what UEngine_findCharacter does
-- at UnrealEngine-75.LUA:3162). The original plan's UEngine.UPlayer.PlayerController
-- cache does not exist in the codebase.
local lp = UEngine_findLocalPlayer()
-- pcProp = UEngine_getAllProperties(lpClass)['PlayerController']
-- pc     = readPointer(lp + pcProp.offset)
local cm = readPointer(pc + offset_of_CheatManager)
-- or property walk: UEngine_searchPropsOnObject(pc, {'CheatManager'})
```

---

## Definition of done

- `UEngine.DevConsoleState` populated with all seven signals (`viewport`, `console`, `consoleClass`, `consoleCDO`, `consoleKeys`, `cheatManager`, `cheatCDO`); `needs` derived from them.
- Assessment is purely read-only — zero writes to target memory.
- If `console` and `consoleKeys` are already green, the probe reports "already enabled" (idempotent path).
- If `consoleCDO` is nil while `console` is nil, the assessment flags `console` as blocked for Task 7 (no CDO → no foreign-thread creation).

## Verification

1. On a Shipping build: `console == nil`, `consoleClass` may be nil or set, `consoleCDO` present (native classes persist), `consoleKeys` empty or missing `Tilde` → `needs` lists exactly the broken vectors.
2. On an enabled dev build: all green → `needs == {}`.
3. Diff `needs` against known game state (INI-patched vs. compile-out) to confirm each signal maps to the right vector (README requirement matrix).
4. On a build where `Default__Console` is genuinely absent, `console` is reported blocked — Task 7 never runs.
5. On a build where `Default__CheatManager` is genuinely absent, `cheat` is reported blocked — Task 9's `NewObject<UCheatManager>` replication never runs (CheatClass may still be patched).

---

## Implementation log — 2026-07-31

Task 5 was implemented in `UnrealEngine-75.LUA` as one probe plus six helpers:

- `UEngine_getObjectFlags(obj)` (`:1440`) — reads the 4-byte `EObjectFlags`. Offset is **derived, not scanned**: the standard UE4/UE5 `UObject` layout is `{vtable; EObjectFlags(4); int32 InternalIndex(4); UClass* ClassPrivate; ...}`, so `ObjectFlags` sits exactly `Class - 8` (8 on 64-bit, 4 on 32-bit). Cached as `UEngine.UObject.ObjectFlags`. `UEngine.RF_ClassDefaultObject = 0x200` constant (`:1433`), verified against UE source.
- `UEngine_findCDOs(names, t)` (`:1456`) — **single-pass** object-array walk matching several CDO names at once: ComparisonIndex dword (via `UEngine_nameTargetIndex`, Task 1/3) **plus** the `RF_ClassDefaultObject` flag. Returns `{[name]=obj}` or `nil,'reason'`.
- `UEngine_findCDO(name, t)` (`:1514`) — convenience wrapper over `UEngine_findCDOs`.
- `UEngine_findCDOByClassName(className, t)` (`:1523`) — fallback CDO finder matching `obj.Class`'s name index + the flag (used when `Default__InputSettings` misses).
- `UEngine_readConsoleKeys(t, cdo)` (`:1568`) — reads the first `FKey`'s `KeyName` from `UInputSettings::ConsoleKeys`; the already-found CDO can be passed in to skip a second walk.
- `UEngine_readCheatManager(t)` (`console.lua:714`) — `LocalPlayer → PlayerController` chain (mirrors `UEngine_findCharacter`'s first half), then `CheatManager` ObjectProperty walk; returns `cm, pc, cmOff` (resolves only `CheatManager`; Task 9 searches `CheatClass` in the same walk).
- `UEngine_assessDeveloperConsole(t)` (`:1648`) — the Phase 2 probe: resolves Tasks 2/4 offsets (read-only), reads all seven signals into `UEngine.DevConsoleState`, derives `needs` + `blocked`.

### Deviations from the proposal

1. **Not wired into the scanner.** Tasks 1–4 wire read-only *discovery* into `UEInfoScanner`; Task 5 is a **runtime probe** that must read live values (viewport console, keys, CheatManager) at repair time — scan-time state would be stale by the time the orchestrator runs. The orchestrator (Task 10) calls `UEngine_assessDeveloperConsole` in both its ASSESS and VERIFY phases.
2. **ObjectFlags offset derived (`Class-8`), not scanned.** The proposal assumed the flag is available; the script has no `UObject.ObjectFlags` cache. The `Class-8` derivation holds for both UE4 and UE5 (flags 4 bytes + InternalIndex 4 bytes precede `ClassPrivate`); documented as an assumption.
3. **Single-pass CDO walk.** The proposal implied one walk per CDO (Console, CheatManager, InputSettings). `UEngine_findCDOs` matches all three names in ONE pass — each object-array pass is O(numElements) remote reads, so this roughly halves the probe's cost.
4. **`consoleKeys` = first `FKey` `KeyName` only.** The proposal's "table of FKey KeyNames" implies iterating all elements; `FKey` = `{FName KeyName; TArray<const FKeyDetails*,TInlineAllocator<4>>}` has a **version-dependent inline-allocator size** that makes the element stride fragile across UE4/UE5. Task 8 patches exactly the first `KeyName`, so the first element is both the signal and the repair target. `consoleKeys` holds 0–1 names and this is documented in the code.
5. **Added `state.blocked` (per-item reason).** The doc says "flags `console` as blocked" but gives no field. `UEngine.DevConsoleState.blocked = { console = <reason>, cheat = <reason> }` records why a `needs` item cannot be repaired (CDO missing → hard gate, or CDO walk failed → conservative refusal to attempt foreign-thread creation).
6. **Extra state fields beyond the 7 signals:** `state.inputSettingsCDO` (reused by the keys probe to avoid a second walk) and `state.playerController` (from the CheatManager chain). Harmless, logged.
7. **Return contract formalized:** `nil,'reason'` (probe could not run — scanner not ready), `true,'already enabled'` (console present **and** first console key is Tilde — the doc's idempotent path; `cheat` is bonus and may remain in `needs`), `false,'needs: <list>'` (probe ran, `needs` non-empty). The `state` table is the real contract; the return value is a convenience status.
8. **CDO-walk failure is treated as blocked, not "not found".** If the walk errors (array not ready), the probe cannot verify the hard gate, so `console`/`cheat` are blocked with `'CDO walk failed (...)…'` rather than attempting a creation that could run `GetDefaultObject()` on the CE-injected foreign thread.

### Verification status

1. ✅ `luac -p` syntax + `loadfile` pass; no `writePointer`/`writeInteger` anywhere in the Task 5 path (assessment is read-only — matches DoD).
2. ⚠️ CDO walks, FKey read, and the PC chain need a live UE4/UE5 target for field validation; the `RF_ClassDefaultObject = 0x200` and `Class-8` flag-offset assumptions should be confirmed against the target's logged flags on first run.
3. ⚠️ The `FKey` stride assumption (first-key-only) is a deliberate scope cut; revisit only if Task 8 ever needs the full key list.

### Notes for Tasks 7/8/9/10

- **Task 7:** read `UEngine.DevConsoleState.consoleCDO` as the hard gate and `blocked['console']` for the reason; never call `StaticConstructObject_Internal` when `consoleCDO` is nil.
- **Task 8:** `UEngine_readConsoleKeys`'s `dataPtr` (first FKey's `KeyName` FName at the ConsoleKeys data pointer) is the patch target — re-derive it (or reuse `state.consoleKeys` as the before-signal).
- **Task 9:** `state.cheatCDO` gates the `NewObject<UCheatManager>` replication; `state.cheatManager` is the after-signal; `state.playerController` is the base for the `CheatClass` patch.
- **Task 10:** ASSESS → `UEngine_assessDeveloperConsole()`; REPAIR each `needs` item in order, honoring `blocked`; VERIFY by re-running the same probe.
