# Task 2 — Steps A + B: Offset Discovery (GameViewport, ViewportConsole)

**Goal:** Resolve and cache the two property offsets the assessment and console creation need. **Read-only — no writes to target memory.**

**Depends on:** Task 1 (`UObject_getName` FNameSize fix, for UE5 class-name validation), core scanner state (`UEngine.GameEngineClass`, `UEngine_getAllProperties`, `UEngine.UObject.Class`, `UObject_getName`, `isVTable`).
**Used by:** Task 5 (assessment), Task 7 (create console).

---

## Step A. Discover `GameViewport` offset on UGameEngine (always needed)

Reuse the existing `UEngine_getAllProperties(classPtr)` on the GameEngine class to find the `GameViewport` property (ObjectProperty). Cache result in `UEngine.GameViewport` (see cache-key deviation below).

```lua
local props = UEngine_getAllProperties(UEngine.GameEngineClass)
-- lookup the offset where name == "GameViewport", it's an ObjectProperty
```

Fallback: if `GameViewport` isn't in the property link (engine stripping), scan the UGameEngine instance's memory for pointer candidates pointing to a `UGameViewportClient`. Reuse the `FindGEngine` candidate-validation pattern (UnrealEngine-75.LUA:853-903): for each pointer-sized slot inside the instance, read the candidate and require it to be a valid UObject — `isVTable(readPointer(candidate))` **and** its class name resolving to `GameViewportClient` (`UObject_getName`, which needs the Task 1 fix on UE5). Pick the slot whose candidate stays stable across a few seconds (survives ticks/GC). Log the result's class name (`UObject_getName`) for debugging. In UE5.x the property is `TObjectPtr<UGameViewportClient>` — stored as a raw pointer at the property offset, so direct `readPointer` works.

## Step B. Discover `ViewportConsole` offset — [fixed]

`ViewportConsole` (`TObjectPtr<UConsole>`) is the **only** console-related property on `UGameViewportClient`. There is **no `ConsoleClass` here** — the original plan's steps 3/4/7 ("discover + write `ConsoleClass` on the viewport client") are invalid and must be re-targeted at `UEngine::ConsoleClass` (Task 4).

```lua
local vpClass = readPointer(vp + UEngine.UObject.Class)
local vpProps = UEngine_getAllProperties(vpClass)
-- find "ViewportConsole" (ObjectProperty); cache as UEngine.UGameViewportClient.ViewportConsole
```

Runs only when a viewport client pointer is available (after Step A succeeds). If the property isn't found, leave `UEngine.UGameViewportClient.ViewportConsole` nil — the console-instance repair (Task 7) will record it as blocked.

---

## Cached state (Task 10 state table)

- `UEngine.GameViewport` — offset of `GameViewport` (ObjectProperty) on the UGameEngine **instance**
- `UEngine.UGameViewportClient.ViewportConsole` — offset of `ViewportConsole` (ObjectProperty) on the viewport class

**Cache-key deviation:** the doc's original contract read `UEngine.UGameEngine.GameViewport`, but `UEngine.UGameEngine` is the numeric instance pointer used in arithmetic throughout the script (`FindGEngine`, `UEngine_detectFNameLayout`, `UEngine_findLocalPlayer`) and a Lua number cannot hold child keys. The offset is therefore cached as `UEngine.GameViewport`. `UEngine.UGameViewportClient` is a fresh table (never used as a number), so `UEngine.UGameViewportClient.ViewportConsole` matches the doc exactly. The implementation function is `UEngine_discoverViewportOffsets()` (UnrealEngine-75.LUA:1148), wired into `UEInfoScanner` right after `findGameInstanceFPropertyAndFields` (UnrealEngine-75.LUA:2686-2693).

## Definition of done

- Both offsets resolve via `UEngine_getAllProperties` on a live UE4/UE5 target and log the class name.
- Assessment (Task 5) can then read `readPointer(ge + GameViewport)` and `readPointer(vp + ViewportConsole)`.
- No writes performed.

## Verification

1. Attach; confirm `UEngine.GameViewport` is a valid offset and points at a `UGameViewportClient` (class name logged).
2. `ViewportConsole` offset resolves on the viewport class; value may legitimately be `0` on Shipping builds.
3. If property link lacks `GameViewport`, the memory-scan fallback still yields a valid viewport pointer.

---

## Implementation log — 2026-07-31

Task 2 was implemented as `UEngine_discoverViewportOffsets()` in `UnrealEngine-75.LUA` (1148-1236) and wired into `UEInfoScanner` (2686-2693), directly after `findGameInstanceFPropertyAndFields` — the earliest point where `UEngine_getAllProperties` works, because it needs `UEngine.FProperty`/`FField`/`FFieldClass` offsets.

### Deviations from the proposal

1. **Cache key for `GameViewport`.** The doc's `UEngine.UGameEngine.GameViewport` is impossible: `UEngine.UGameEngine` is the numeric instance pointer used in arithmetic throughout (`FindGEngine`, `UEngine_detectFNameLayout`, `UEngine_findLocalPlayer`, …). Stored as `UEngine.GameViewport`. `UEngine.UGameViewportClient.ViewportConsole` matches the doc exactly (fresh table, never a number). See "Cache-key deviation" above.
2. **Fallback scan target.** The proposal said "scan GEngine's memory"; the implementation scans the **UGameEngine instance** (`UEngine.UGameEngine + i*stride`, i = 0..63) — `GameViewport` is a field of the instance, so that is where its pointer slot lives. `UEngine.GEngine` is the address of the global `GEngine` *variable*, not the instance, so scanning it would only inspect one slot.
3. **Stability check.** A `sleep(50)` (guarded by `type(sleep)=='function'` for CE versions without it) between the two reads of a fallback candidate, so the pointer must survive a short window rather than just a double-read. Property-link discovery (Step A primary path) does no stability check — the property link is authoritative.
4. **No validation of `pv.propertyType`.** The proposal described `GameViewport` as an ObjectProperty; the implementation accepts any property with that name and a valid `offset` (logging the pointed-to class name for sanity). PropertyType names vary (`ObjectProperty` UE4 vs `ObjectProperty` UE5 FFieldClass; some games recompile with different FFieldClass names), so requiring it would be a false-failure risk. `ObjectProperty` checks are only meaningful when `UClass_enumProperties` resolved `propertyType`, which itself depends on `UEngine.FFieldClass.Name`.
5. **Best-effort, never aborts the scan.** A failed discovery logs and leaves caches nil (`UEngine.GameViewport` nil, `UEngine.UGameViewportClient.ViewportConsole` nil). Task 5 (assessment) and Task 7 (create console) must treat nil as "blocked" rather than fail hard.
6. **Standalone-safe.** If called with `FNameSize` unresolved it runs `UEngine_detectFNameLayout()` first (Task 1 dependency), so the class-name validation in the fallback is correct on UE5 even outside the scanner flow. Idempotent: both steps are guarded by `if <cache>==nil`, matching the Task 1 pattern.

### Verification status

1. ✅ Property-link path caches `UEngine.GameViewport` and logs the pointed-to class (expected `GameViewportClient`).
2. ✅ `UEngine.UGameViewportClient.ViewportConsole` resolved on the viewport class when the property exists; left nil otherwise (Shipping may strip it).
3. ⚠️ Memory-scan fallback implemented but not yet exercised on a stripped target.

### Stale reference fix

The original doc cited the `FindGEngine` candidate-validation pattern at `UnrealEngine-75.LUA:844-866`. After the Task 1 insertion it lives at `:853-903` (updated above). `UObject_getName`'s pre-fix location `:68-86` is also superseded — see the Task 1 implementation log; the current `UObject_getName` is `:68-95`.

### Note for Task 10 (orchestrator)

`UEngine_discoverViewportOffsets()` is already invoked during `UEInfoScanner`, so the orchestrator should not call it again; Task 10 only reads the cached `UEngine.GameViewport` / `UEngine.UGameViewportClient.ViewportConsole`.
