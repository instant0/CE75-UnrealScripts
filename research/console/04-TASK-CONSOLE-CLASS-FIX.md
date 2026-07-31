# Task 4 — Step C: Fix `ConsoleClass` on UGameEngine — [fixed]

**Goal:** Ensure `UEngine::ConsoleClass` (a `TSubclassOf<UConsole>`, stored as a raw `UClass*`) points at the `Console` UClass. Runs only when the `consoleClass` signal read by Task 5 is null.

**Depends on:** Task 3 (`UEngine_findClassByName`), core `UEngine_getAllProperties`.
**Needed by:** Task 7 (console creation requires a non-null console class).

---

Property walk the GameEngine class for `ConsoleClass` (ClassProperty; `TSubclassOf<UConsole>` stores a raw `UClass*`). Cache as `UEngine.UGameEngine.ConsoleClass`. If it is null, find the `Console` UClass and write it:

```lua
local consoleClassAddr = UEngine_findClassByName('Console')   -- Task 3
writePointer(UEngine.UGameEngine + UEngine.UGameEngine.ConsoleClass, consoleClassAddr)
```

This is necessary but **not sufficient** — nothing re-runs `SetupInitialLocalPlayer`, so the instance must be created too (Task 7).

---

## Definition of done

- `UEngine.UGameEngine.ConsoleClass` offset resolved and cached.
- If the engine's `ConsoleClass` was null, it is written with the `Console` UClass found by Task 3.
- If the class cannot be found, the need is recorded as unpatched (no write, no crash).

## Verification

1. On a config-patched game (ConsoleClass null): after running, `readPointer(ge + ConsoleClass.off)` returns a valid `UClass*`.
2. Re-run is a no-op (idempotent): class already set → nothing written.
3. On an already-enabled game, this repair never executes (guarded by the `needs` list).
