# Task 5 — Phase 2: Assessment (read-only state probe)

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

`cheatCDO` is the same gate for Task 9's `SpawnCheatManager()` (`NewObject<UCheatManager>` has the same foreign-thread CDO risk). Detect both CDOs the same way: find the object whose class-name index matches `Default__Console` / `Default__CheatManager` **and** whose `RF_ClassDefaultObject` flag is set — the flag is the robust signal, the name is the fast index. Match the ComparisonIndex dword via `UEngine.NameToIndexMin[...]` (not `NameToIndex` — case-preserving display-table indices can win there on UE5), reusing the Task 3 walk.

If `console ~= nil and console ~= 0`, the console already exists → skip straight to key check (Task 8); if that is also fine, return `true, 'already enabled'` **without writing anything**.

### Key signal (for `consoleKeys`)

Find the `UInputSettings` CDO (object in the array with class name `InputSettings` and `RF_ClassDefaultObject` flag, or name `Default__InputSettings`), read its `ConsoleKeys` (`TArray<FKey>`) property offset via property walk, and inspect the first FKey's `KeyName` (an `FName`). An `FKey` is `{ FName KeyName; TArray<const FKeyDetails*, TInlineAllocator<4>> KeyDetails; }`.

Note: name-based CDO detection (`Default__InputSettings`) depends on the Task 1 `UObject_getName` FNameSize fix on UE5; a layout-safe alternative is matching the ComparisonIndex dword via `UEngine.NameToIndex['Default__InputSettings']`.

### CheatManager signal (for `cheatManager`)

```lua
-- NOTE: UEngine_findLocalPlayer() returns the ULocalPlayer, NOT the PlayerController.
-- Walk LocalPlayer -> PlayerController first (this is what UEngine_findCharacter does
-- at UnrealEngine-75.LUA:3101). The original plan's UEngine.UPlayer.PlayerController
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
5. On a build where `Default__CheatManager` is genuinely absent, `cheat` is reported blocked — Task 9's `SpawnCheatManager` never runs (CheatClass may still be patched).
