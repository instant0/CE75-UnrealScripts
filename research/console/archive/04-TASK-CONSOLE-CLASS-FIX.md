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

---

## Implementation log — 2026-07-31

Task 4 was implemented in `UnrealEngine-75.LUA` as two functions plus a scanner wiring block:

- `UEngine_resolveConsoleClassOffset()` (`:1368`) — read-only: resolves + caches the `ConsoleClass` property offset on the GameEngine class via the `UEngine_getAllProperties` property walk (Task 2 pattern). `ConsoleClass` is inherited from `UEngine`, so the GameEngine walk sees it.
- `UEngine_fixConsoleClass(t)` (`:1402`) — REPAIR-phase capability: reads the current `ConsoleClass`; if null, writes the `Console` UClass from `UEngine.ConsoleClassAddr` (Task 3 cache) or a fresh `UEngine_findClassByName('Console',t)`; verifies the write by re-reading.
- Scanner wiring (`:2921-2929`) — runs inside `UEInfoScanner` after the Task 3 block: resolves + caches the offset and logs the engine's current `ConsoleClass` value.

### Deviations from the proposal

1. **Cache key `UEngine.ConsoleClass`, not `UEngine.UGameEngine.ConsoleClass`.** Same contract problem Task 2 hit: `UEngine.UGameEngine` is the numeric instance pointer used in pointer arithmetic throughout the script, and a Lua number cannot hold child keys. The offset is cached at `UEngine.ConsoleClass` and the value read from `UGameEngine+offset`.
2. **Split into resolve + fix.** The proposal inlined the offset walk into the fix. The implementation separates the read-only offset resolution (`UEngine_resolveConsoleClassOffset`, idempotent) from the write (`UEngine_fixConsoleClass`) so Task 5's assessment can reuse the cached offset without re-walking the property link, and so the write stays isolated behind one function.
3. **Scanner is READ-ONLY — the write is NOT performed at scan time.** The proposal's snippet implies running the fix during the scan. That would put a write into the detect/assess phase and contradict the README design principle (Repair only items on the `needs` list, in the orchestrator's REPAIR phase, Task 10) and Task 5's "assessment is purely read-only". Instead the scanner resolves + caches the offset and logs the current value; `UEngine_fixConsoleClass` performs the write when the orchestrator gates it on the null signal. Running it manually (`UEngine_fixConsoleClass()`) satisfies Verification step 1.
4. **Write verified by re-read.** After `writePointer` the slot is re-read and must equal the written `UClass*`; otherwise the repair returns `nil,'write did not verify'` instead of silently reporting success.
5. **No property-type gate.** The doc labels `ConsoleClass` a `ClassProperty`; the implementation logs the resolved `propertyType` but does not require it, mirroring Task 2's tolerance (keeps the walk working across UE4/UE5 layouts where the property name match is the reliable signal).

### Verification status

1. ✅ Offset resolution + current-value logging wired into the scanner (`Task 4 scanner: UEngine::ConsoleClass current value=0x...`).
2. ⚠️ Actual write path (`UEngine_fixConsoleClass`) only exercised on a live config-patched target with `ConsoleClass == 0`; the idempotent branch (already-set → no write) is exercised on any attached target.
3. ⚠️ `writePointer` is the first write to target memory in the script (previously write-free); verified as CE 7.5 API (`LuaHandler.pas`), but field-tested only once a target is attached.

### Note for Tasks 5/10

- Task 5's probe reads the cached `UEngine.ConsoleClass` offset (no re-walk) and reports the signal; it should NOT call `UEngine_fixConsoleClass`.
- Task 10's REPAIR step a calls `UEngine_fixConsoleClass()` only when the Task 5 signal is null; the function is also self-guarded (no-op when already set).
