# Task 9 — Step G: CheatManager setup (bonus) — [fixed]

**Goal:** Ensure the `PlayerController` has a `CheatManager` so `God`, `Slomo`, etc. work. Runs only if cheat commands are the goal (bonus — independent of console UI).

**Depends on:** Task 3 (`UEngine_findClassByName('CheatManager')`), Task 5 (`cheatCDO` hard gate), Task 6 (`UEngine_callMethod`), core `UEngine_getAllProperties` + LocalPlayer→PlayerController walk.
**Used by:** Task 10 (as `needs.cheat`, best-effort).

> **Implementation target (per [`SPLITFILE.md`](SPLITFILE.md) §6):** implement `UEngine_setupCheatManager()` in **`Scripts/console/console.lua`**. No `UnrealEngine-75.LUA` edit is needed for this task.

---

For `God`, `Slomo`, etc., the `PlayerController` needs a `CheatManager`:

```lua
-- Walk LocalPlayer -> PlayerController first (UEngine_findLocalPlayer returns the ULocalPlayer).
-- Follow the exact pattern in UEngine_findCharacter (UnrealEngine-75.LUA:3162):
--   lpClass = readPointer(lp + UEngine.UObject.Class)
--   lpProps = UEngine_getAllProperties(lpClass)
--   pcProp  = lpProps['PlayerController']  (ObjectProperty)
--   pc      = readPointer(lp + pcProp.offset)
--   pcClass = readPointer(pc + UEngine.UObject.Class)
local pcProps = UEngine_getAllProperties(pcClass)
local cheatClassProp = pcProps['CheatClass']      -- ClassProperty (TSubclassOf<UCheatManager>)
local cheatMgrProp   = pcProps['CheatManager']    -- ObjectProperty

-- HARD GATE (mirrors Task 7's consoleCDO): never call SpawnCheatManager without the
-- Default__CheatManager CDO present. NewObject<UCheatManager> on the CE foreign thread
-- would build the CDO -> check(IsInGameThread()) risk (Task 6 caveats). If blocked,
-- CheatClass may still be patched (plain write) but the spawn must NOT run.
local cheatCDO = UEngine.DevConsoleState and UEngine.DevConsoleState.cheatCDO

if cheatClassProp and readPointer(pc + cheatClassProp.offset) == 0 then
  local cmClass = UEngine_findClassByName('CheatManager')
  writePointer(pc + cheatClassProp.offset, cmClass)
  if not cheatCDO then
    -- record `cheat` as blocked (no CDO -> no foreign-thread spawn); skip the call
  else
    -- Force the spawn via the Task 6 wrapper (delegates to executeCodeEx, so the PC
    -- `this` goes to RCX — matching the x64 calling convention for a virtual/instance
    -- method; SpawnCheatManager takes no extra arguments, so executeMethod would also
    -- work but is not needed):
    --   find APlayerController::SpawnCheatManager() — virtual in BOTH UE4 and UE5
    --   (APlayerController.h), so resolve it from the PC vtable; no AOB-on-callsite
    --   needed:
    UEngine_callMethod(spawnCheatManagerAddr, pc)
    -- Validate by re-reading pc + cheatMgrProp.offset afterwards; if still null, record
    -- the need as unpatched (SpawnCheatManager is best-effort, void return).
  end
end
```

Note: the original plan's snippet `local pc = UEngine_findLocalPlayer()` was wrong — that returns the `ULocalPlayer`, and `UEngine.UPlayer.PlayerController` is not a cache that exists in this codebase.

---

## Definition of done

- `CheatClass` written with the `CheatManager` UClass if it was null.
- `SpawnCheatManager()` invoked via `UEngine_callMethod` (virtual in UE4 and UE5 — resolved from the PC vtable; no AOB needed).
- `SpawnCheatManager()` is **gated on `cheatCDO`** (`Default__CheatManager` present, Task 5 signal) — if absent, the spawn is recorded as blocked and never called.
- `cheatMgrProp` re-read afterwards; null → recorded as unpatched, never assumed done.
- No PlayerController present → repair skipped gracefully (bonus only).

## Verification

1. `readPointer(pc + CheatManager.off)` non-null after the repair.
2. `God`, `Slomo`, `Summon`, `ToggleDebugCamera` accepted through the console.
3. Re-run is a no-op (idempotent).
4. On a build where `Default__CheatManager` is genuinely absent, `cheat` is reported blocked — `SpawnCheatManager` never runs.
