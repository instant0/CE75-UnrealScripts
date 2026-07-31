# Task 5 — Phase 2: Assessment (read-only state probe)

**Goal:** Build `UEngine.DevConsoleState` — every console-related signal read **without writing** — and derive the `needs` list the orchestrator (Task 10) repairs.

**Depends on:** Task 2 offsets (`GameViewport`, `ViewportConsole`), Task 4 (`ConsoleClass` offset), key discovery described here, PlayerController chain walk.
**Consumed by:** Task 10 orchestrator (REPAIR + VERIFY), Task 8 (keys), Task 9 (CheatManager).

---

Resolve offsets **without writing**: `GameViewport` (Task 2, Step A), `ViewportConsole` (Task 2, Step B), `ConsoleClass` (Task 4, Step C), then read every signal into `UEngine.DevConsoleState`:

```lua
UEngine.DevConsoleState = {
  viewport      = vp,        -- UGameViewportClient* (nil if unreachable)
  console       = consolePtr,-- UConsole* (nil → needs creation)
  consoleClass  = classPtr,  -- UClass* (nil → needs ConsoleClass fix)
  consoleKeys   = keys,      -- table of FKey KeyNames ({} → needs key fix)
  cheatManager  = cm,        -- UCheatManager* (nil → bonus repair)
  needs = { 'consoleClass', 'console', 'keys', 'cheat' },  -- built from above
}
```

If `console ~= nil and console ~= 0`, the console already exists → skip straight to key check (Task 8); if that is also fine, return `true, 'already enabled'` **without writing anything**.

### Key signal (for `consoleKeys`)

Find the `UInputSettings` CDO (object in the array with class name `InputSettings` and `RF_ClassDefaultObject` flag, or name `Default__InputSettings`), read its `ConsoleKeys` (`TArray<FKey>`) property offset via property walk, and inspect the first FKey's `KeyName` (an `FName`). An `FKey` is `{ FName KeyName; TArray<const FKeyDetails*, TInlineAllocator<4>> KeyDetails; }`.

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

- `UEngine.DevConsoleState` populated with all five signals; `needs` derived from them.
- Assessment is purely read-only — zero writes to target memory.
- If `console` and `consoleKeys` are already green, the probe reports "already enabled" (idempotent path).

## Verification

1. On a Shipping build: `console == nil`, `consoleClass` may be nil or set, `consoleKeys` empty or missing `Tilde` → `needs` lists exactly the broken vectors.
2. On an enabled dev build: all green → `needs == {}`.
3. Diff `needs` against known game state (INI-patched vs. compile-out) to confirm each signal maps to the right vector (README requirement matrix).
