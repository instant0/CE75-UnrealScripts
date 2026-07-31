# Task 2 — Steps A + B: Offset Discovery (GameViewport, ViewportConsole)

**Goal:** Resolve and cache the two property offsets the assessment and console creation need. **Read-only — no writes to target memory.**

**Depends on:** core scanner state (`UEngine.GameEngineClass`, `UEngine_getAllProperties`, `UEngine.UObject.Class`, `UObject_getName`, `isVTable`).
**Used by:** Task 5 (assessment), Task 7 (create console).

---

## Step A. Discover `GameViewport` offset on UGameEngine (always needed)

Reuse the existing `UEngine_getAllProperties(classPtr)` on the GameEngine class to find the `GameViewport` property (ObjectProperty). Cache result in `UEngine.UGameEngine.GameViewport`.

```lua
local props = UEngine_getAllProperties(UEngine.GameEngineClass)
-- lookup the offset where name == "GameViewport", it's an ObjectProperty
```

Fallback: if `GameViewport` isn't in the property link (engine stripping), scan GEngine's memory for pointer candidates pointing to a `UGameViewportClient` instance. Verify the viewport client: in UE5.x the property is `TObjectPtr<UGameViewportClient>` — stored as a raw pointer at the property offset, so direct `readPointer` works. Log the result's class name (`UObject_getName`) for debugging.

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

- `UEngine.UGameEngine.GameViewport` — offset of `GameViewport` (ObjectProperty)
- `UEngine.UGameViewportClient.ViewportConsole` — offset of `ViewportConsole` (ObjectProperty)

## Definition of done

- Both offsets resolve via `UEngine_getAllProperties` on a live UE4/UE5 target and log the class name.
- Assessment (Task 5) can then read `readPointer(ge + GameViewport)` and `readPointer(vp + ViewportConsole)`.
- No writes performed.

## Verification

1. Attach; confirm `UEngine.UGameEngine.GameViewport` is a valid offset and points at a `UGameViewportClient` (class name logged).
2. `ViewportConsole` offset resolves on the viewport class; value may legitimately be `0` on Shipping builds.
3. If property link lacks `GameViewport`, the memory-scan fallback still yields a valid viewport pointer.
