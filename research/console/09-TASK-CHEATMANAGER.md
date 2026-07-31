# Task 9 — Step G: CheatManager setup (bonus) — [fixed]

**Goal:** Ensure the `PlayerController` has a `CheatManager` so `God`, `Slomo`, etc. work. Runs only if cheat commands are the goal (bonus — independent of console UI).

**Depends on:** Task 3 (`UEngine_findClassByName('CheatManager')`), Task 6 (`UEngine_callMethod`), core `UEngine_getAllProperties` + LocalPlayer→PlayerController walk.
**Used by:** Task 10 (as `needs.cheat`, best-effort).

---

For `God`, `Slomo`, etc., the `PlayerController` needs a `CheatManager`:

```lua
-- Walk LocalPlayer -> PlayerController first (UEngine_findLocalPlayer returns the ULocalPlayer).
-- Follow the exact pattern in UEngine_findCharacter (UnrealEngine-75.LUA:3101-3110):
--   lpClass = readPointer(lp + UEngine.UObject.Class)
--   lpProps = UEngine_getAllProperties(lpClass)
--   pcProp  = lpProps['PlayerController']  (ObjectProperty)
--   pc      = readPointer(lp + pcProp.offset)
--   pcClass = readPointer(pc + UEngine.UObject.Class)
local pcProps = UEngine_getAllProperties(pcClass)
local cheatClassProp = pcProps['CheatClass']      -- ClassProperty (TSubclassOf<UCheatManager>)
local cheatMgrProp   = pcProps['CheatManager']    -- ObjectProperty

if cheatClassProp and readPointer(pc + cheatClassProp.offset) == 0 then
  local cmClass = UEngine_findClassByName('CheatManager')
  writePointer(pc + cheatClassProp.offset, cmClass)
  -- CheatManager is spawned in APlayerController::PostInitializeComponents; if the PC
  -- already spawned, the field stays null. Force the spawn via CE 7.5 executeMethod
  -- (wrapper from Task 6): the PC `this` goes to RCX, matching the x64 calling
  -- convention for a virtual/instance method.
  --   find APlayerController::SpawnCheatManager() (virtual in UE5, findable via the PC
  --   vtable; in UE4 it is a plain member function, locate via AOB on the callsite in
  --   PostInitializeComponents), then:
  UEngine_callMethod(spawnCheatManagerAddr, pc)
  -- Validate by re-reading pc + cheatMgrProp.offset afterwards; if still null, record
  -- the need as unpatched (SpawnCheatManager is best-effort, void return).
end
```

Note: the original plan's snippet `local pc = UEngine_findLocalPlayer()` was wrong — that returns the `ULocalPlayer`, and `UEngine.UPlayer.PlayerController` is not a cache that exists in this codebase.

---

## Definition of done

- `CheatClass` written with the `CheatManager` UClass if it was null.
- `SpawnCheatManager()` invoked via `UEngine_callMethod` (virtual in UE5, vtable-resolved; AOB-found in UE4).
- `cheatMgrProp` re-read afterwards; null → recorded as unpatched, never assumed done.
- No PlayerController present → repair skipped gracefully (bonus only).

## Verification

1. `readPointer(pc + CheatManager.off)` non-null after the repair.
2. `God`, `Slomo`, `Summon`, `ToggleDebugCamera` accepted through the console.
3. Re-run is a no-op (idempotent).
