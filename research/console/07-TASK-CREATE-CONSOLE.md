# Task 7 — Step D: Create the `UConsole` instance — [fixed — this is the crux]

**Goal:** Construct a `UConsole` with `GameViewport` as its **outer** and assign it to `ViewportConsole`. Runs only when the `console` signal read by Task 5 is null.

**Depends on:** Task 1 (FName size), Task 2 (GameViewport/ViewportConsole offsets), Task 3 (Console UClass), Task 4 (ConsoleClass set), Task 5 (`consoleCDO` hard gate), Task 6 (`UEngine_callFunction`).
**Fallback:** approach #5 (`PlayerController->ConsoleCommand()`, background doc) when this is infeasible.

---

The original plan's **Option C ("the console should auto-create on first `~` press") is FALSE for UE4/UE5**: `UGameViewportClient::InputKey` routes keys to `ViewportConsole` only if it already exists (`ViewportConsole ? ViewportConsole->InputKey(...) : false`) and never creates it. In Shipping/Test builds the creation code in `SetupInitialLocalPlayer` was **compiled out** (`#if ALLOW_CONSOLE`/`#if !UE_BUILD_SHIPPING`), so it will never appear on its own.

The proven approach on shipped games is to construct a `UConsole` with `GameViewport` as its **outer** and assign it to `ViewportConsole`:

```lua
-- Option A (recommended): call StaticConstructObject_Internal via UEngine_callFunction.
-- Signature depends on Task 1 (Phase 1):
--   UE4.26+ / UE5: UObject* StaticConstructObject_Internal(const FStaticConstructObjectParameters&)
--     FStaticConstructObjectParameters { Class, Outer, Name(FName), SetFlags, InternalSetFlags,
--                                        Template(CDO), bCopyTransientsFromClassDefaults,
--                                        InstanceGraph, ... }
--   UE4.25-: positional signature (Class, Outer, Name, SetFlags, InternalSetFlags, Template, ...).
--   OUT OF SCOPE: this task implements ONLY the FStaticConstructObjectParameters
--   (UE4.26+ / UE5) variant. UE4.25- targets are reported as unsupported instead of
--   half-implemented (Task 1 still caches SCOPositionalSig for diagnosis).
-- The address must be located per game — see "Locating StaticConstructObject_Internal" below.

-- 1) Allocate the params struct. Offsets depend on Task 1's FNameSize
--    (FStaticConstructObjectParameters: Class, Outer, FName Name, SetFlags,
--     InternalSetFlags, Template, ... — FName is 8 bytes in UE4, 12 in UE5,
--     which shifts every following field).
local fnameSize  = UEngine.FNameSize                 -- 8 (UE4) or 12 (UE5)
local setFlagsOff   = 0x10 + fnameSize               -- SetFlags      -> 0x18 (UE4) / 0x1C (UE5)
local internalOff   = setFlagsOff + 4                -- InternalSetFlags
local templateOff   = (internalOff + 4 + 7) // 8 * 8 -- Template (ptr, 8-aligned) -> 0x20 / 0x28

-- HARD GATE: never call SCO without the Console CDO present.
if not (UEngine.DevConsoleState and UEngine.DevConsoleState.consoleCDO) then
  -- record `console` as blocked; degrade to approach #5 (ConsoleCommand only)
  return nil, 'blocked: no Default__Console CDO (foreign-thread GetDefaultObject() risk)'
end

local params = allocateMemory(0x60)
-- NOTE: allocateMemory (VirtualAllocEx) returns freshly committed, zero-filled pages,
-- so the unwritten tail of the struct is safe. Never reuse a freed/reallocated buffer.
writePointer(params + 0x00, consoleClass)            -- Class = Console UClass (from Task 3)
writePointer(params + 0x08, vp)                      -- Outer = GameViewport (MUST be the viewport)
writeInteger(params + 0x10, 0)                       -- FName ComparisonIndex = NAME_None (0)
writeInteger(params + 0x14, 0)                       -- FName DisplayIndex (UE5) / Number (UE4)
if fnameSize == 12 then writeInteger(params + 0x18, 0) end  -- FName Number (UE5 only)
writeInteger(params + setFlagsOff, 0)                -- SetFlags = RF_NoFlags
writeInteger(params + internalOff, 0)                -- InternalSetFlags = None
writePointer(params + templateOff, 0)                -- Template = 0: engine uses the existing CDO.
--    ONLY safe because Default__Console is known to exist (the gate above); a null
--    Template with a missing CDO would force CDO creation on the foreign thread ->
--    check(IsInGameThread()) risk. Never set a non-null Template that is not the CDO.

-- 2) Call it via CE 7.5 executeCodeEx (wrapper from Task 6). RCX = params ptr,
--    return value = the new UConsole*.
local consoleObject, callErr = UEngine_callFunction(staticConstructInternalAddr, params)
if not consoleObject then
  -- recorded as unpatched; do NOT write anything. (callErr logged for debugging)
end

-- 3) Validate, then assign. Nothing is written until the object checks out.
--    (class name "Console", outer == vp). See prelude caveats.
writePointer(vp + UEngine.UGameViewportClient.ViewportConsole, consoleObject)
```

---

## Locating `StaticConstructObject_Internal`

This is the riskiest part of the whole feature — do not treat it as a one-liner. `StaticConstructObject_Internal` is a non-exported engine function whose body (and therefore its AOB) varies by engine version, so a single pattern will not hold across UE4.26–UE5.x. Work through these in order:

1. **Version-pinned AOB table.** Maintain a table of known-good patterns for the common engine versions (UE4.26, UE4.27, UE5.0–UE5.5), sourced from community UE console-unlock AOBs and verified per target. Key the table on `UEngine.EngineVersion` (full string cached by Task 1) — **not** on the coarse UE4/UE5 flavour: `couldBeUnrealEngine` only separates the two families (`ProductVersion:find('%%+UE4'/'%%+UE5')`, UnrealEngine-75.LUA:2406-2407) and cannot distinguish UE5.0 from UE5.5, which have different SCO bodies.
2. **Cross-reference from `StaticAllocateObject`.** AOB for `StaticAllocateObject` (very recognizable prologue/body, very few callers in the engine DLL), then disassemble each of its call sites and identify the enclosing function that is `StaticConstructObject_Internal`. Distinguish it by checking the candidate also references the CDO/`FName` machinery (`GetDefaultObject` / `MakeUniqueObjectName`), and confirm the UE4.26+/UE5 calling convention passes `&FStaticConstructObjectParameters` in RCX (`lea rcx,[rip+...]` / `mov rcx,rdx`).
3. **Degrade gracefully.** If neither step yields a validated address, record the need as unpatched, report `partial:` from the orchestrator (Task 10), and fall back to approach #5 (`PlayerController->ConsoleCommand()` — no UI, but every command still executes). **Never proceed with an unvalidated address.**

---

**The console object MUST have Outer == GameViewport**: `UConsole::ConsoleCommand()` calls `GetOuterUGameViewportClient()->GetGameInstance()` — a wrong outer is a guaranteed crash. The `Name` passed should be `NAME_None` (index 0) so the engine auto-generates a unique name for the instance; **do NOT reuse the CDO itself as the live console** (its outer is the engine package, not the viewport → crash on Enter).

Notes / limitations:
- `GLog->AddOutputDevice(ViewportConsole)` (done by `SetupInitialLocalPlayer`) will **not** run for a manually created console — engine log lines won't appear in the console, but typing commands and command output still work (routed via `FConsoleOutputDevice ConsoleOut(ViewportConsole)` in `UGameViewportClient::ConsoleCommand`).
- If calling `StaticConstructObject_Internal` is not feasible for a given game, record this need as unpatched and fall back to approach #5 (scripted `PlayerController->ConsoleCommand()`) — no UI, but every console command executes.

---

## Definition of done

- `StaticConstructObject_Internal` located via the version-pinned AOB table or the `StaticAllocateObject` cross-reference, and the address **validated by disassembly** before any call; signature branch resolved from Task 1 (`UEngine.SCOPositionalSig` / FName size).
- `consoleCDO` non-nil is a hard precondition (Task 5 signal); if nil the repair is recorded as blocked and **no** SCO call happens.
- New `UConsole*` created with `Outer == GameViewport`, validated (class name `Console`, outer == vp), then written to `ViewportConsole`.
- On nil/0 return or validation failure: recorded as unpatched, **nothing written**.
- UE4.25- (positional signature) is declared out of scope: recorded as unsupported, degrade to approach #5.
- Repeated `executeCodeEx` timeouts abort the phase (never loop with leaked allocations).

## Verification

1. After running, `readPointer(vp + ViewportConsole.off)` returns a `UConsole` whose `GetOuter` is the viewport client.
2. Pressing ~ (or the patched key, Task 8) toggles the console UI on a Shipping build.
3. Pressing Enter after typing a command does not crash (outer is correct).
4. Re-run reports `already enabled` (idempotent) and does not create a second instance.
5. On a build where SCO cannot be located (or `consoleCDO` is nil), the orchestrator returns `partial:` with `console` blocked and the `ConsoleCommand`-only path works.
