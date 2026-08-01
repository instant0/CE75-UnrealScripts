# Task 10 — Orchestrator: `UEngine_enableDeveloperConsole()` + Phase 4 Verify + Menu + State

**Goal:** Assemble Tasks 1–9 into the single entry point `UEngine_enableDeveloperConsole()` with PREFLIGHT → DETECT → ASSESS → REPAIR → VERIFY, wire it into the Debug menu, and track state.

**Depends on:** Tasks 1–9. This is the final assembly task.

> **Implemented 2026-08-01:** `UEngine_enableDeveloperConsole()` added at the end of `console.lua` (Task 10 section) implementing the 5-stage flow exactly: PREFLIGHT (`UEngine_isReady` → else `UEngine_runWhenReady` re-queue + `nil,'pending'`), DETECT (version + FName width, best-effort caches), ASSESS (Task 5 probe; `true,'already enabled'` short-circuit with zero writes), REPAIR (iterate `state.needs` in order → `UEngine_fixConsoleClass` / `UEngine_createConsole` / `UEngine_patchConsoleKeys` / `UEngine_setupCheatManager`, each independent and failure-logged), VERIFY (re-run Task 5 probe; `DevConsoleEnabled=true` only when console+keys green, CheatManager stays bonus). Menu: console.lua registers once (`UEngine._consoleMenuRegistered` idempotence guard) on `UEngine.menuContributors`; the core `UEngine_buildSuccessMenus` now iterates `UEngine.menuContributors` with `pcall(contrib, UEngine.GUI.miDebug)` right after `miSearchCharProps` is added (`UnrealEngine-75.LUA:2010`). Syntax gate passed (`luac -p` + `loadfile` on both files); mock test still 28/28.

> **Correction (2026-08-01 — dual-version source audit, see [11-TASK-DUAL-VERSION-CORRECTIONS.md](11-TASK-DUAL-VERSION-CORRECTIONS.md)):** The orchestrator itself holds no offset/flag constants, but it depends on three corrected primitives: (1) the DETECT gate now keys FName layout off measurement not version — shipping UE5 is 8-byte like UE4; (2) the `consoleCDO`/`cheatCDO` hard gates (REPAIR b/d) test `RF_ClassDefaultObject`, whose constant must be `0x10` not `0x200`; (3) the Task 7/9 SCO params `templateOff` = 0x28 for both FName sizes (two bools exist in the struct). Verify these are applied in Tasks 7/8/9 before assembling.

> **Implementation target (per [`SPLITFILE.md`](SPLITFILE.md) §6):** implement `UEngine_enableDeveloperConsole()` in **`Scripts/console/console.lua`**. The **only** `UnrealEngine-75.LUA` edit this task needs is the ~6-line `menuContributors` iteration in `UEngine_buildSuccessMenus` (§5.5). Do NOT register the item in the core's stale-destroy list.

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

**Location: `Scripts/console/console.lua` via the `UEngine.menuContributors` hook (SPLITFILE.md §5.5).** This supersedes the original in-builder placement: `UEngine_buildSuccessMenus()` (`UnrealEngine-75.LUA:1935`) iterates `UEngine.menuContributors` right after `miSearchCharProps` is added to `miDebug` and before `menusBuilt` is set, calling each with `UEngine.GUI.miDebug`. Because the contributor runs *inside* the builder, the item is recreated fresh on every build and needs **no** entry in the core's stale-menu destroy list (no duplicate risk).

The console file registers a contributor at load (idempotent — re-defining globals on reload is safe):

```lua
UEngine.menuContributors = UEngine.menuContributors or {}
UEngine.menuContributors[#UEngine.menuContributors+1] = function(miDebug)
  local mi = UE_newMenuItem('Enable Developer Console')
  mi.OnClick = function()
    UEngine_runWhenReady(function()
      local ok, msg = UEngine_enableDeveloperConsole()
      if ok then
        showMessage('Developer Console enabled. Press ~ (Tilde) to open.')
      else
        showMessage('Failed: ' .. tostring(msg))
      end
    end)
  end
  miDebug.add(mi)
end
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
