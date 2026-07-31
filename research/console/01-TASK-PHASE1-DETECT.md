# Task 1 — Phase 1: Layout Detection (UE4 vs UE5)

**Goal:** Implement `UEngine_detectFNameLayout()` and cache the layout facts every later read/write needs.

**Depends on:** nothing (core scanner state: `UEngine.UGameEngine`, `UEngine.UObject.Name`, `UEngine_resolveFName`).
**Prerequisite knowledge:** `research/console/00-BACKGROUND.md`, `research/console/README.md` (Chain of Discovery).

---

Version detection is a **gate for the later read/write steps** (FName width, `StaticConstructObject_Internal` signature, TObjectPtr handling), not a one-time "is it UE4 or UE5?" branch. Cache everything the repairs will need:

```lua
-- Phase 1 result table (all cached before any write):
--   UEngine.UEFlavour          = 'UE5' | 'UE4'
--   UEngine.FNameSize          = 12 | 8
--   UEngine.SCOPositionalSig   = true | false   -- UE4.25- only (rare)
```

**Primary detector — FName struct width.** Every UObject name is an `FName`:
- UE4: `{ ComparisonIndex@+0, Number@+4 }` → 8 bytes
- UE5: `{ ComparisonIndex@+0, DisplayIndex@+4, Number@+8 }` → 12 bytes

In UE5, `+4` holds the same name-pool index as `+0` (DisplayIndex mirrors ComparisonIndex); in UE4, `+4` is the name's Number (normally `0` → resolves to `"None"`). Use the cached name pool:

```lua
function UEngine_detectFNameLayout()
  local nameAddr = UEngine.UGameEngine + UEngine.UObject.Name
  local s0 = UEngine_resolveFName(readInteger(nameAddr))       -- e.g. "GameEngine"
  local s4 = UEngine_resolveFName(readInteger(nameAddr + 4))
  if s4 and s4 == s0 then
    UEngine.FNameSize = 12
    UEngine.UEFlavour  = 'UE5'
  else
    UEngine.FNameSize = 8
    UEngine.UEFlavour  = 'UE4'
  end
end
```

**Cross-checks** (use when the primary test is ambiguous, e.g. `+4` unreadable):
- Pointer size: `processhandler.pointersize` (8 = 64-bit, 4 = 32-bit).
- String scan of the module for `"UE5"` / `"Unreal Engine 5"` or the version banner — fragile, secondary only.
- `StaticConstructObject_Internal` signature (needed only if Task 7 runs): UE4.26+ and UE5 use `const FStaticConstructObjectParameters&`; UE4.25- uses positional params. FName width distinguishes UE5 from UE4 but **not** 4.26 from 4.25 — disassemble the located function's prologue if the target is known to be old UE4.

---

## Definition of done

- `UEngine.UEFlavour` and `UEngine.FNameSize` are set (12/UE5 or 8/UE4) by the time the orchestrator (Task 10) calls `UEngine_enableDeveloperConsole()`.
- Detection runs during PREFLIGHT/DETECT (orchestrator step 1) and is cached for Tasks 6, 7, 8.
- No writes to target memory in this task.

## Verification

1. Attach to a UE4 game → log shows `FNameSize 8 / UE4`.
2. Attach to a UE5 game → log shows `FNameSize 12 / UE5`.
3. Re-run: detection is idempotent (cached, no re-scan if already set).
