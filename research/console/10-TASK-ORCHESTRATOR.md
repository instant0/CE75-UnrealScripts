# Task 10 — Orchestrator: `UEngine_enableDeveloperConsole()` + Phase 4 Verify + Menu + State

**Goal:** Assemble Tasks 1–9 into the single entry point `UEngine_enableDeveloperConsole()` with PREFLIGHT → DETECT → ASSESS → REPAIR → VERIFY, wire it into the Debug menu, and track state.

**Depends on:** Tasks 1–9. This is the final assembly task.

---

## Orchestrator flow

```
UEngine_enableDeveloperConsole()
│
├─ 0  PREFLIGHT   scanner ready? (GEngine, UObject.Class/Name, NamePool, ObjectArray)
│                  └─ not ready → UEngine_runWhenReady re-queues, return nil,'pending'
│
├─ 1  DETECT      UE4 vs UE5 (FName width), pointersize        ← version gate, Task 1
│
├─ 2  ASSESS      read-only state probe → UEngine.DevConsoleState
│                  viewport / console / consoleClass / consoleCDO / consoleKeys / cheatManager
│                  └─ console already active? → return true,'already enabled'  (no writes)
│
├─ 3  REPAIR      for each item in state.needs, in order:
│                  │  a. ConsoleClass null            → find UClass 'Console' → write (Task 4)
│                  │  b. console instance null        → create UConsole(outer=vp) via
│                  │     UEngine_callFunction(StaticConstructObject_Internal) → write (Task 7)
│                  │     └─ blocked unless state.consoleCDO is present (hard gate)
│                  │  c. ConsoleKeys lacks Tilde      → patch FKey KeyName (Task 8)
│                  │  d. (bonus) CheatManager absent  → patch CheatClass + spawn (Task 9)
│                  │     └─ spawn blocked unless state.cheatCDO is present (hard gate)
│                  └─ best-effort: each repair independent, failures recorded
│
└─ 4  VERIFY      re-read all signals
                  ├─ all green → UEngine.DevConsoleEnabled=true, return true,'enabled'
                  └─ some red  → return false,'partial: <remaining needs>'
```

## Phase 4 — Verify

Re-run the Task 5 (Phase 2) read of every signal. Set `UEngine.DevConsoleEnabled = true` only when the console instance + keys are green (CheatManager stays a separate bonus). Return a structured result so the menu handler can surface a per-need status:

```lua
return ok, summaryString   -- e.g. "Enabled (console, keys); CheatManager not present (optional)"
```

## Menu Integration

Add inside `UEngine_buildSuccessMenus()` (UnrealEngine-75.LUA:1890) under the Debug menu. The menu must be added there (or to `UEngine.GUI.miDebug` after it is created) because `UEngine.GUI.menusBuilt` makes later direct additions from outside the builder unreliable. Two details the builder enforces:

- Register `'miEnableConsole'` in the stale-menu destroy list at UnrealEngine-75.LUA:1899-1904 (alongside `miDebug`, `miFindInventory`, etc.) so script reloads never leave a duplicated entry.
- Create the item right after `UEngine.GUI.miSearchCharProps` is added to `miDebug` (UnrealEngine-75.LUA:1962), before `menusBuilt` is set.

```lua
UEngine.GUI.miEnableConsole = UE_newMenuItem('Enable Developer Console')
UEngine.GUI.miEnableConsole.OnClick = function()
  UEngine_runWhenReady(function()
    local ok, msg = UEngine_enableDeveloperConsole()
    if ok then
      showMessage('Developer Console enabled. Press ~ (Tilde) to open.')
    else
      showMessage('Failed: ' .. tostring(msg))
    end
  end)
end
UEngine.GUI.miDebug.add(UEngine.GUI.miEnableConsole)
```

## State Tracking

- `UEngine.UGameEngine.GameViewport` — cached offset (or nil if undetected)
- `UEngine.UGameEngine.ConsoleClass` — cached offset of the engine's console class property
- `UEngine.UGameViewportClient` — table with `ViewportConsole` offset
- `UEngine.DevConsoleState` — Task 5 probe table (includes the `consoleCDO` and `cheatCDO` hard-gate signals)
- `UEngine.DevConsoleEnabled` — boolean, set when enable succeeds (prevents double-run)
- `UEngine.EngineVersion`, `UEngine.ObjectArrayNumElements`, `UEngine.NameToIndexMin` — Task 1 caches (see README chain of discovery)

---

## Definition of done

- `UEngine_enableDeveloperConsole()` exists in the core script and follows the 5-stage flow exactly.
- Idempotent: second run on an enabled game returns `true, 'already enabled'` with zero writes.
- Per-need status is reported through the return string (VERIFY stage).
- Menu item present under `UEngine.GUI.miDebug`; click runs the feature via `UEngine_runWhenReady`.
- `UEngine.DevConsoleEnabled` gates re-entry.

## Verification

1. **Shipping game, all vectors disabled** → `enabled` (console + keys green), CheatManager optional note if absent.
2. **Already-enabled dev build** → `already enabled`, no writes (verify by re-reading memory / second run).
3. **Hard-blocked game** (empty `ConsoleKeys`) → `partial: <remaining needs>` with key repair recorded.
4. **Scanner not ready** → `nil, 'pending'`, re-queued via `UEngine_runWhenReady`.
5. Menu: **Unreal Engine → Debug → Enable Developer Console**; message on success/failure.
