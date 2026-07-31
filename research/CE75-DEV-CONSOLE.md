# Enabling the Unreal Engine Developer Console

Research into how UE4/UE5 games ship with the console disabled and common approaches to re-enable it.

## Status — PLAN ONLY, NOT IMPLEMENTED ⚠️

Verified 2026-07-31 against `UnrealEngine-75.LUA` (4489 lines) and UE4/UE5 engine source:

- ✅ **Self-contained: no UE4SS or other external tool is required.** Every engine function that must be *called* (`StaticConstructObject_Internal`, `SpawnCheatManager`, `ConsoleCommand`) is invoked through the CE-native `UEngine_callFunction` remote-call utility (Phase 3 Prelude). All offset discovery is property walking / memory scanning already present in the core script.
- ❌ **No `UEngine_enableDeveloperConsole()` function exists** (grepped — zero console/CheatManager hits in the core script).
- ❌ **No `UEngine.UGameViewportClient` cache, no `UEngine.DevConsoleEnabled` state, no menu item.** `UEngine.GUI.miDebug` exists and is the right home for the menu entry, but nothing has been added.

Everything below is a *proposal*. The steps marked **[fixed]** contain corrections discovered during review; the original text made claims about the engine that do not match UE4/UE5 source.

---

## Background

The UE developer console (toggled by default with ~/Tilde) provides access to `CheatManager` commands like `God`, `Slomo`, `Summon`, `ToggleDebugCamera`, and `r.Fog 0`. Many shipped titles disable it by:

1. Removing the console key binding from `DefaultInput.ini` (`[/Script/Engine.InputSettings] ConsoleKeys=(Key=None)`)
2. Nulling `UEngine::ConsoleClass` (config: `[/Script/Engine.Engine].ConsoleClassName=`)
3. Compiling out console creation entirely — **`UGameViewportClient::SetupInitialLocalPlayer` only creates the console under `#if ALLOW_CONSOLE` / `#if !UE_BUILD_SHIPPING`**, which is off in Shipping/Test builds
4. Nulling or removing the `CheatManager` class reference on the `PlayerController`

**Key correction vs. original plan**: steps 1–4 above are the real disable vectors. The original plan listed "Removing the console key binding from `DefaultInput.ini`" and "Setting `ConsoleKey=None` in `Console.ini`" — that INI section is UE3-era. In UE4/UE5 the toggle key lives in `UInputSettings::ConsoleKeys` and the console *class* lives on `UEngine`, not on the viewport client (see F2/F4 below).

## Common Re-enable Approaches

### 1. INI Patching (easiest, works on unlocked games) — rarely works on shipped titles

Edit or inject into `<Game>/Saved/Config/WindowsNoEditor/Input.ini`:

```ini
[/Script/Engine.InputSettings]
ConsoleKeys=Tilde
```

Also ensure a `CheatManager` class is assigned in `DefaultGame.ini`:

```ini
[/Script/Engine.PlayerController]
CheatClass=CheatManager
```

If the game validates INI signatures or uses PAK'd defaults, INI patching alone won't work. Note: this only fixes the **key**; it does nothing if the console object was never created (see F3).

### 2. AOB Patching the Console Key Check

Find `UConsole::InputKey_InputLine` (the `GetDefault<UInputSettings>()->ConsoleKeys.Contains(Key)` check) or `APlayerController::ConsoleKey` (guarded by `#if ALLOW_CONSOLE`), and NOP/force the comparison so any key — or the Tilde key specifically — toggles the console. This is game/engine-version specific AOB work; only needed if `UInputSettings::ConsoleKeys` is empty or the check was recompiled.

### 3. Constructing a UConsole Object

If the game never created a console instance (`ViewportConsole == null` — guaranteed in Shipping because creation is compiled out), force-create one. **This is the hard step and the original plan understated it.** See the corrected Step D below. The proven approach for shipped games — expressed here in abstract terms (the CE-native mechanics are in Step D / the `UEngine_callFunction` prelude):

```lua
-- abstract recipe (CE-native mechanics in Step D):
-- 1. locate StaticConstructObject_Internal via AOB
-- 2. build an FStaticConstructObjectParameters{ Class=Console, Outer=GameViewport } in memory
-- 3. UEngine_callFunction(fnAddr, paramsPtr) -> new UConsole*
-- 4. writePointer(vp + ViewportConsole.off, newUConsole)
-- If the console already exists, skip straight to key remap (Step F).
```

### 4. Forcing the Console Class

Some games ship with a console class but set it to `None` on the **engine** (not the viewport):

```
UEngine::ConsoleClass = LoadObject<UClass>(nullptr, TEXT("/Script/Engine.Console"));
```

Then create the console (Step D). Patching `ConsoleClass` alone does **not** make the console appear — nothing re-runs `SetupInitialLocalPlayer`.

### 5. Blueprint / Script-Based Activation

In UE4/5, the console can be opened from Blueprint via `Execute Console Command` nodes or from C++ via `PlayerController->ConsoleCommand()`. If a game's scripting system has access to the `PlayerController`, console commands can be executed programmatically without the UI console. This is also a good **fallback** from CE: `APlayerController::ConsoleCommand()` is a virtual (findable in the PC vtable) and works even if `ViewportConsole` was never created — commands just have no on-screen output. From CE it must be invoked via `UEngine_callFunction(consoleCommandAddr, pc)` with the command passed as an `FString&` argument (allocate an `FString` = `{ TArray<TCHAR> Data; int32 Num; int32 Capacity }` in memory and pass its address as argPtr) — **no UE4SS-style `PlayerController:ConsoleCommand("cmd")` binding exists in CE**.

## Relevant APIs and Structures — [fixed]

| Object | Purpose | Where it actually lives |
|--------|---------|------------------------|
| `UConsole` | The HUD/UI console widget. | `UGameViewportClient::ViewportConsole` (`TObjectPtr<UConsole>` in UE5.x, raw ptr readable at the property offset) |
| **`UEngine::ConsoleClass`** | **`TSubclassOf<UConsole>` (a `UClass*` in memory) used to spawn the console.** Original plan wrongly said `UGameViewportClient::ConsoleClass` — **no such property exists** on `UGameViewportClient` | `UEngine.h` |
| `UEngine::ConsoleClassName` | `FSoftClassPath` config default (`/Script/Engine.Console`) | `UEngine.h` |
| `UGameViewportClient::SetupInitialLocalPlayer()` | Creates the console **once**, but only `#if ALLOW_CONSOLE` / `#if !UE_BUILD_SHIPPING` — compiled out in Shipping/Test | `GameViewportClient.cpp` |
| **`UInputSettings::ConsoleKeys`** | **`TArray<FKey>` — the actual toggle keys.** Original plan said `UConsole.ConsoleKey` (UE3-era; does not exist in UE4/5). `ConsoleKey_DEPRECATED` migrates into `ConsoleKeys` | `InputSettings.h` / `Console.cpp` |
| `PlayerController->CheatManager` | Processes cheat commands. Must be non-null for `God`, `Slomo`, etc. | `PlayerController.h` |
| `PlayerController->CheatClass` | `TSubclassOf<UCheatManager>` used to spawn a `CheatManager` in `PostInitializeComponents` | `PlayerController.h` |

## Detection from CE

```lua
local vp = readPointer(UEngine.UGameEngine + UEngine.UGameEngine.GameViewport)
local console = vp and readPointer(vp + UEngine.UGameViewportClient.ViewportConsole)
-- if console ~= 0 and console ~= nil, a console object exists
```

Check the console class — **on the engine, not the viewport**:

```lua
local consoleClass = readPointer(UEngine.UGameEngine + UEngine.UGameEngine.ConsoleClass)
-- if consoleClass ~= 0, the game has a console class loaded
```

Check the toggle keys — **`UInputSettings` CDO `ConsoleKeys` TArray** (not a viewport/console field):

```lua
-- find the UInputSettings CDO in the object array (class name "InputSettings"),
-- read its ConsoleKeys TArray property offset, then read the FKey entries
```

Check if CheatManager is present on the PlayerController:

```lua
-- NOTE: UEngine_findLocalPlayer() returns the ULocalPlayer, NOT the PlayerController.
-- Walk LocalPlayer -> PlayerController first (this is what UEngine_findCharacter does
-- at UnrealEngine-75.LUA:3101). The original plan's UEngine.UPlayer.PlayerController
-- cache does not exist in the codebase.
local lp = UEngine_findLocalPlayer()
-- pcProp = UEngine_getAllProperties(lpClass)['PlayerController']
-- pc     = readPointer(lp + pcProp.offset)
local cm = readPointer(pc + offset_of_CheatManager)
-- or property walk: UEngine_searchPropsOnObject(pc, {'CheatManager'})
```

## Implementation Plan for `UnrealEngine-75.LUA`

Function: `UEngine_enableDeveloperConsole()`

### Design Principle — Detect → Assess → Repair → Verify

The console is disabled through **independent vectors**; a game may have *any subset* of them, so a single fixed patch sequence is wrong. The feature must:

1. **Detect** engine layout (UE4 vs UE5, pointer size) so every later read/write uses the right structure sizes.
2. **Assess** (read-only) every console-related signal and build a `needs` list — **no writes yet**.
3. **Repair** only the items on the `needs` list, in dependency order (class before instance before keys).
4. **Verify** by re-reading state, then report what was patched vs. what remains blocked.

This makes the feature **idempotent**: running it on an already-enabled console just reports "already active".

### Orchestrator Flow

```
UEngine_enableDeveloperConsole()
│
├─ 0  PREFLIGHT   scanner ready? (GEngine, UObject.Class/Name, NamePool, ObjectArray)
│                  └─ not ready → UEngine_runWhenReady re-queues, return nil,'pending'
│
├─ 1  DETECT      UE4 vs UE5 (FName width), pointersize        ← version gate, Phase 1
│
├─ 2  ASSESS      read-only state probe → UEngine.DevConsoleState
│                  viewport / console / consoleClass / consoleKeys / cheatManager
│                  └─ console already active? → return true,'already enabled'  (no writes)
│
├─ 3  REPAIR      for each item in state.needs, in order:
│                  │  a. ConsoleClass null            → find UClass 'Console' → write (Step C)
│                  │  b. console instance null        → create UConsole(outer=vp) via
│                  │     UEngine_callFunction(StaticConstructObject_Internal) → write (Step D)
│                  │  c. ConsoleKeys lacks Tilde      → patch FKey KeyName (Step F)
│                  │  d. (bonus) CheatManager absent  → patch CheatClass + spawn (Step G)
│                  └─ best-effort: each repair independent, failures recorded
│
└─ 4  VERIFY      re-read all signals
                  ├─ all green → UEngine.DevConsoleEnabled=true, return true,'enabled'
                  └─ some red  → return false,'partial: <remaining needs>'
```

### Requirement Matrix

| Disable vector | Detection signal (Phase 2) | Repair (Phase 3) | Runs when |
|---|---|---|---|
| Console never created (Shipping compile-out) | `readPointer(vp + ViewportConsole.off) == 0` | construct `UConsole` with outer = viewport (Step D) | shipping/test builds |
| `UEngine::ConsoleClass` set to null | `readPointer(ge + ConsoleClass.off) == 0` | find `Console` UClass, write it (Step E) | config-patched games |
| Toggle keys removed (`ConsoleKeys` empty/wrong) | `UInputSettings` CDO `ConsoleKeys` lacks `Tilde` | patch first FKey `KeyName` (Step F) | INI-patched games |
| Key-check recompiled / array unfixable | key never toggles despite fix | AOB-patch `ConsoleKeys.Contains` check (Approach #2) | hard-blocked games |
| `CheatManager` absent | `PC.CheatClass` / `PC.CheatManager` null | patch `CheatClass` + `SpawnCheatManager()` via `UEngine_callFunction` (Step G) | cheat commands needed |
| Already enabled | all signals green | no-op | — |

### Chain of Discovery — [fixed]

```
UEngine.UGameEngine  (GEngine pointer, already cached)
    ↓ readPointer(ge + UObject.Class)
UGameEngine UClass
    ↓ property walk → find "GameViewport" (ObjectProperty, offset)
UEngine.UGameEngine.GameViewport            ← viewport client pointer
    ↓ property walk on viewport class → find "ViewportConsole" (ObjectProperty)
UEngine.UGameViewportClient.ViewportConsole ← the console instance (may be null in Shipping)
    ↓ property walk on GameEngine class → find "ConsoleClass" (ClassProperty)
UEngine.UGameEngine.ConsoleClass            ← the class to spawn (may be null)
    ↓ find UClass named "Console" in the UObjectArray
UConsole UClass
    ↓ create instance with outer = GameViewport (StaticConstructObject_Internal)
UConsole* (assign to ViewportConsole)
```

---

### Phase 1 — Layout Detection (UE4 vs UE5)

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
- `StaticConstructObject_Internal` signature (needed only if Phase 3b runs): UE4.26+ and UE5 use `const FStaticConstructObjectParameters&`; UE4.25- uses positional params. FName width distinguishes UE5 from UE4 but **not** 4.26 from 4.25 — disassemble the located function's prologue if the target is known to be old UE4.

### Phase 2 — Assessment (read-only)

Resolve offsets **without writing**: `GameViewport` (Step A), `ViewportConsole` (Step B), `ConsoleClass` (Step C), then read every signal into `UEngine.DevConsoleState`:

```lua
UEngine.DevConsoleState = {
  viewport      = vp,        -- UGameViewportClient* (nil if unreachable)
  console       = consolePtr,-- UConsole* (nil → needs creation)
  consoleClass  = classPtr,  -- UClass* (nil → needs ConsoleClass fix)
  consoleKeys   = keys,      -- table of FKey KeyNames ({} → needs key fix)
  cheatManager  = cm,        -- UCheatManager* (nil → bonus repair)
  needs = { 'consoleClass', 'console', 'keys', 'cheat' },  -- built from above
}
```

If `console ~= nil and console ~= 0`, the console already exists → skip straight to key check (Step F); if that is also fine, return `true, 'already enabled'` **without writing anything**.

### Phase 3 — Repair (only what `needs` says)

Each numbered step below is now a **conditional repair**, dispatched from the `needs` list in this order:

#### Step A. Discover `GameViewport` offset on UGameEngine (always needed)

Reuse the existing `UEngine_getAllProperties(classPtr)` on the GameEngine class to find the `GameViewport` property (ObjectProperty). Cache result in `UEngine.UGameEngine.GameViewport`.

```lua
local props = UEngine_getAllProperties(UEngine.GameEngineClass)
-- lookup the offset where name == "GameViewport", it's an ObjectProperty
```

Fallback: if `GameViewport` isn't in the property link (engine stripping), scan GEngine's memory for pointer candidates pointing to a `UGameViewportClient` instance. Verify the viewport client: in UE5.x the property is `TObjectPtr<UGameViewportClient>` — stored as a raw pointer at the property offset, so direct `readPointer` works. Log the result's class name (`UObject_getName`) for debugging.

#### Step B. Discover `ViewportConsole` offset — [fixed] (runs if `console` signal is null)

`ViewportConsole` (`TObjectPtr<UConsole>`) is the **only** console-related property on `UGameViewportClient`. There is **no `ConsoleClass` here** — the original plan's steps 3/4/7 ("discover + write `ConsoleClass` on the viewport client") are invalid and must be re-targeted at `UEngine::ConsoleClass` (Step C).

```lua
local vpClass = readPointer(vp + UEngine.UObject.Class)
local vpProps = UEngine_getAllProperties(vpClass)
-- find "ViewportConsole" (ObjectProperty); cache as UEngine.UGameViewportClient.ViewportConsole
```

#### Step C. Fix `ConsoleClass` on UGameEngine — [fixed] (runs if `consoleClass` signal is null)

Property walk the GameEngine class for `ConsoleClass` (ClassProperty; `TSubclassOf<UConsole>` stores a raw `UClass*`). Cache as `UEngine.UGameEngine.ConsoleClass`. If it is null, find the `Console` UClass and write it:

```lua
local consoleClassAddr = UEngine_findClassByName('Console')   -- Step E
writePointer(UEngine.UGameEngine + UEngine.UGameEngine.ConsoleClass, consoleClassAddr)
```

This is necessary but **not sufficient** — nothing re-runs `SetupInitialLocalPlayer`, so the instance must be created too (Step D).

#### Phase 3 Prelude — `UEngine_callFunction` (CE-native remote call — replaces UE4SS's function-call capability)

Several steps must **create** an object, i.e. call one C++ function in the target process (Step D calls `StaticConstructObject_Internal`, Step G calls `SpawnCheatManager`, the Approach #5 fallback calls `ConsoleCommand`). UE4SS offered that as a Lua binding; **CE 7.5 has no such binding**, so the plan provides its own: build a tiny x64 thunk in target memory that sets the first argument register, calls the target by absolute address, saves `RAX` (the return value) to a scratch slot, and returns — then run it with `executeCodeEx`, which CE 7.5 executes on a new thread in the target process and waits on:

```lua
-- UEngine_callFunction(fnAddr, argPtr) -> returnValue or nil
--   fnAddr : absolute address of the C++ function (AOB-found, or resolved from a vtable slot)
--   argPtr : value loaded into RCX (x64 first arg; for virtuals, pass the `this`/instance)
--   Returns the function's RAX, i.e. the created UObject* for StaticConstructObject_Internal.
local function int64le(v)                     -- little-endian 8-byte table for an immediate
  local t = {}
  for i = 0, 7 do t[i + 1] = v % 256; v = v // 256 end
  return t
end

local function UEngine_callFunction(fnAddr, argPtr)
  local stub    = allocateMemory(0x40)
  local scratch = allocateMemory(0x8)
  local code = { 0x48, 0xB8 }                    -- mov rax, <imm64>
  for _, b in ipairs(int64le(fnAddr)) do code[#code + 1] = b end
  for _, b in ipairs({ 0x48, 0xB9 }) do code[#code + 1] = b end   -- mov rcx, <imm64> (arg1)
  for _, b in ipairs(int64le(argPtr)) do code[#code + 1] = b end
  for _, b in ipairs({ 0x48, 0xBA }) do code[#code + 1] = b end   -- mov rdx, <imm64> (scratch)
  for _, b in ipairs(int64le(scratch)) do code[#code + 1] = b end
  for _, b in ipairs({ 0x48, 0x83, 0xEC, 0x28 }) do code[#code + 1] = b end -- sub rsp, 0x28 (shadow+align)
  for _, b in ipairs({ 0xFF, 0xD0 }) do code[#code + 1] = b end   -- call rax
  for _, b in ipairs({ 0x48, 0x89, 0x02 }) do code[#code + 1] = b end -- mov [rdx], rax (save retval)
  for _, b in ipairs({ 0x48, 0x83, 0xC4, 0x28 }) do code[#code + 1] = b end -- add rsp, 0x28
  for _, b in ipairs({ 0xC3 }) do code[#code + 1] = b end          -- ret
  writeBytes(stub, code)
  executeCodeEx(0, 5000, stub, {})             -- run in target, wait <=5s
  local result = readPointer(scratch)
  return (result and result ~= 0) and result or nil
end
```

Notes on the thunk mechanics (verify against CE 7.5 at implementation time):
- `sub rsp, 0x28` allocates the x64 shadow space (0x20) plus 0x8 so `rsp` is 16-aligned at the `call`; the trailing `ret` returns into CE's execution stub. **Confirm the exact `executeCodeEx` flags semantics in CE 7.5** (call/return handling vs. bare code execution) before relying on the `ret`; if it executes as a thread entry instead, replace the final `ret` with an `int3`/thread-exit and poll `scratch` instead of trusting the return path.
- 32-bit targets use a different ABI (args on the stack, cdecl/stdcall) — the thunk must be adapted; this plan assumes 64-bit (matches the rest of the scanner).

Caveats (first-class plan items, not footnotes):
- **Foreign-thread execution.** The call runs on a CE-injected thread, **not the game thread**. Code paths that `check(IsInGameThread())` (e.g. `UClass::CreateDefaultObject` in some UE4 versions) will crash. Mitigations: only call paths whose CDOs already exist (verify `Default__Console` / `Default__CheatManager` are in the object array first, so `GetDefaultObject()` never builds one), and prefer running the feature at a quiet moment (main menu).
- **Lock stalls, not deadlocks.** `GUObjectArray` and the name pool are guarded by critical sections; a concurrent GC pass only adds a short stall.
- **Best-effort, always verified.** A nil/0 return, or a returned object whose class isn't `Console`, must be recorded as an unpatched need — never assumed to have succeeded. Nothing is written to the game until the returned object validates.

#### Step D. Create the `UConsole` instance — [fixed — this is the crux] (runs if `console` signal is null)

The original plan's **Option C ("the console should auto-create on first `~` press") is FALSE for UE4/UE5**: `UGameViewportClient::InputKey` routes keys to `ViewportConsole` only if it already exists (`ViewportConsole ? ViewportConsole->InputKey(...) : false`) and never creates it. In Shipping/Test builds the creation code in `SetupInitialLocalPlayer` was **compiled out** (`#if ALLOW_CONSOLE`/`#if !UE_BUILD_SHIPPING`), so it will never appear on its own.

The proven approach on shipped games is to construct a `UConsole` with `GameViewport` as its **outer** and assign it to `ViewportConsole`:

```lua
-- Option A (recommended): call StaticConstructObject_Internal via UEngine_callFunction.
-- Signature depends on Phase 1:
--   UE4.26+ / UE5: UObject* StaticConstructObject_Internal(const FStaticConstructObjectParameters&)
--     FStaticConstructObjectParameters { Class, Outer, Name(FName), SetFlags, InternalSetFlags,
--                                        Template(CDO), bCopyTransientsFromClassDefaults,
--                                        InstanceGraph, ... }
--   UE4.25-: positional signature (Class, Outer, Name, SetFlags, InternalSetFlags, Template, ...).
-- The address must be located per game via AOB (e.g. by scanning a call inside
-- UUserWidget::InitializeInputComponent).

-- 1) Allocate the params struct. Offsets depend on Phase 1's FNameSize
--    (FStaticConstructObjectParameters: Class, Outer, FName Name, SetFlags,
--     InternalSetFlags, Template, ... — FName is 8 bytes in UE4, 12 in UE5,
--     which shifts every following field).
local fnameSize  = UEngine.FNameSize                 -- 8 (UE4) or 12 (UE5)
local setFlagsOff   = 0x10 + fnameSize               -- SetFlags      -> 0x18 (UE4) / 0x1C (UE5)
local internalOff   = setFlagsOff + 4                -- InternalSetFlags
local templateOff   = (internalOff + 4 + 7) // 8 * 8 -- Template (ptr, 8-aligned) -> 0x20 / 0x28

local params = allocateMemory(0x60)
writePointer(params + 0x00, consoleClass)            -- Class = Console UClass (from Step E)
writePointer(params + 0x08, vp)                      -- Outer = GameViewport (MUST be the viewport)
writeInteger(params + 0x10, 0)                       -- FName ComparisonIndex = NAME_None (0)
writeInteger(params + 0x14, 0)                       -- FName DisplayIndex (UE5) / Number (UE4)
if fnameSize == 12 then writeInteger(params + 0x18, 0) end  -- FName Number (UE5 only)
writeInteger(params + setFlagsOff, 0)                -- SetFlags = RF_NoFlags
writeInteger(params + internalOff, 0)                -- InternalSetFlags = None
writePointer(params + templateOff, 0)                -- Template = 0: engine uses the existing CDO.
--    ONLY safe because Default__Console already exists (verified in the call-utility
--    prelude); a null Template with a missing CDO would force CDO creation on the
--    foreign thread -> check(IsInGameThread()) risk. Never set a non-null Template
--    that is not the CDO.

-- 2) Call it. Return value = the new UConsole*.
local consoleObject = UEngine_callFunction(staticConstructInternalAddr, params)

-- 3) Validate, then assign. Nothing is written until the object checks out.
--    (class name "Console", outer == vp). See prelude caveats.
writePointer(vp + UEngine.UGameViewportClient.ViewportConsole, consoleObject)
```

**The console object MUST have Outer == GameViewport**: `UConsole::ConsoleCommand()` calls `GetOuterUGameViewportClient()->GetGameInstance()` — a wrong outer is a guaranteed crash. The `Name` passed should be `NAME_None` (index 0) so the engine auto-generates a unique name for the instance; **do NOT reuse the CDO itself as the live console** (its outer is the engine package, not the viewport → crash on Enter).

Notes / limitations:
- `GLog->AddOutputDevice(ViewportConsole)` (done by `SetupInitialLocalPlayer`) will **not** run for a manually created console — engine log lines won't appear in the console, but typing commands and command output still work (routed via `FConsoleOutputDevice ConsoleOut(ViewportConsole)` in `UGameViewportClient::ConsoleCommand`).
- If calling `StaticConstructObject_Internal` is not feasible for a given game, record this need as unpatched and fall back to Approach #5 (scripted `PlayerController->ConsoleCommand()`) — no UI, but every console command executes.

#### Step E. Find the `Console` UClass in memory — [fixed] (used by Step C)

The original plan's hardcoded layout (`numElements = readInteger(UEngine.ObjectArray + 0x08)`, `objectsPtr = readPointer(UEngine.ObjectArray + 0x10)`) is wrong: the scanner already discovers and caches `UEngine.ObjectArray`, `UEngine.ObjectArrayListType` (0 = direct, 1 = chunked), and `UEngine.ObjectArrayEntryStructSize`, and `UObject`'s Class/Name offsets are dynamic (`UEngine.UObject.Class`, `UEngine.UObject.Name`).

**Recommended primary path — FName-index memory scan** (matches the existing `FindGEngine` pattern at UnrealEngine-75.LUA:822-866, version-agnostic, no object-array layout assumptions):

```lua
function UEngine_findClassByName(name)
  local index = UEngine.NameToIndex[name]
  if index == nil then return nil end
  local ms = createMemScan()
  ms.VarType = vtDword
  ms.Fastscanmethod = fsmAligned
  ms.Fastscanparameter = 4
  ms.Scanvalue = index
  ms.ScanWritable = 'scanInclude'
  ms.scan() ms.waitTillDone()
  local r = getMemScanResults(ms)
  ms.destroy() ms = nil
  for i = 1, #r do
    local obj = r[i] - UEngine.UObject.Name
    local objClass = obj > 0 and readPointer(obj + UEngine.UObject.Class) or 0
    -- a UClass has Class -> a UClass whose own name is "Class"
    if objClass and objClass ~= 0 and UObject_getName(objClass) == 'Class' and isVTable(readPointer(obj)) then
      return obj
    end
  end
  return nil
end
```

**Secondary path — walk the object array** using the discovered state. The exact derefs below are taken from `FindObjectArray` (UnrealEngine-75.LUA:1105-1196); validate against the target game's logged `ObjectArrayListType` / `ObjectArrayEntryStructSize` because the layout varies by UE version:

```lua
function UEngine_findClassByName(name)
  local count  = readInteger(UEngine.ObjectArray + 0x08)
  local stride = UEngine.ObjectArrayEntryStructSize
  local target = UEngine.NameToIndex[name]
  local p      = readPointer(UEngine.ObjectArray + 0x10)
  for i = 0, count - 1 do
    local obj = nil
    if UEngine.ObjectArrayListType == 1 then   -- chunked: p is a chunk table (pointer-sized entries)
      local chunk = readPointer(p + math.floor(i / 65536) * processhandler.pointersize)
      obj = readPointer(chunk + (i % 65536) * stride)
    else                                        -- direct: p points at the element array
      obj = readPointer(readPointer(p) + i * stride)
    end
    if obj and obj ~= 0 then
      local objClass = readPointer(obj + UEngine.UObject.Class)
      if objClass and UObject_getName(objClass) == 'Class' and readInteger(obj + UEngine.UObject.Name) == target then
        return obj
      end
    end
  end
  return nil
end
```

Priority order:
1. First find a `UClass` named `Console` (`/Script/Engine.Console`)
2. If that fails, find any object named `Console` and use its class as `ConsoleClass`
3. If nothing found, report failure

Note: in a Shipping build the `Console` UClass is still loaded (native engine classes persist); the CDO (`Default__Console`) also exists in the object array.

#### Step F. Register the console key — [fixed] (runs if `consoleKeys` lacks `Tilde`)

The toggle key is **not** on `UConsole` (UE3-era). UE4/UE5 use:

```cpp
// UConsole::InputKey_InputLine
if ( GetDefault<UInputSettings>()->ConsoleKeys.Contains(Key) && Event == IE_Pressed && !bModifierDown )
```

So find the `UInputSettings` CDO (object in the array with class name `InputSettings` and `RF_ClassDefaultObject` flag, or name `Default__InputSettings`), read its `ConsoleKeys` (`TArray<FKey>`) property offset via property walk, and inspect the first FKey's `KeyName` (an `FName`). An `FKey` is `{ FName KeyName; TArray<const FKeyDetails*, TInlineAllocator<4>> KeyDetails; }`.

If `ConsoleKeys` already contains `Tilde`, nothing to do. If entries exist but wrong key, patch the first entry's `KeyName`:

```lua
-- FName memory layout — use Phase 1 result (IMPORTANT: the original plan's "+4 = number"
-- is wrong for UE5):
--   UE4: ComparisonIndex@+0, Number@+4               (8 bytes)
--   UE5: ComparisonIndex@+0, DisplayIndex@+4, Number@+8   (12 bytes)
-- FName equality (used by ConsoleKeys.Contains) compares ComparisonIndex + Number,
-- but ToString() reads DisplayIndex — if DisplayIndex is left 0 the key displays as
-- "None" and console input handling can misbehave.
local idx = UEngine.NameToIndex['Tilde']
if idx then
  writeInteger(fkeyAddr + 0, idx)          -- ComparisonIndex
  if UEngine.FNameSize == 12 then          -- UE5: DisplayIndex + Number
    writeInteger(fkeyAddr + 4, idx)
    writeInteger(fkeyAddr + 8, 0)
  else                                     -- UE4: Number only
    writeInteger(fkeyAddr + 4, 0)
  end
end
```

If `ConsoleKeys` is **empty** (the common shipping disable), growing the `TArray` requires engine allocation and is risky. Options: (a) patch the `ConsoleKeys.Contains` check / `APlayerController::ConsoleKey` via AOB (Approach #2), (b) find a valid FKey elsewhere in the settings object and reuse its allocation, or (c) accept programmatic activation only. Prefer (a).

If `Tilde` is not in the name pool, try `BackSpace`/`Tab` (both are engine keys and virtually always loaded).

#### Step G. CheatManager setup (bonus) — [fixed] (runs only if cheat commands are the goal)

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
  -- already spawned, the field stays null. Force the spawn via CE-native remote call:
  -- find APlayerController::SpawnCheatManager() (virtual in UE5, findable via the PC
  -- vtable; in UE4 it is a plain member function, locate via AOB on the callsite in
  -- PostInitializeComponents), then:
  --   UEngine_callFunction(spawnCheatManagerAddr, pc)   -- rcx = the PlayerController `this`
  -- Validate the result by re-reading pc + cheatMgrProp.offset afterwards.
end
```

Note: the original plan's snippet `local pc = UEngine_findLocalPlayer()` was wrong — that returns the `ULocalPlayer`, and `UEngine.UPlayer.PlayerController` is not a cache that exists in this codebase.

### Phase 4 — Verify

Re-run the Phase 2 read of every signal. Set `UEngine.DevConsoleEnabled = true` only when the console instance + keys are green (CheatManager stays a separate bonus). Return a structured result so the menu handler can surface a per-need status:

```lua
return ok, summaryString   -- e.g. "Enabled (console, keys); CheatManager not present (optional)"
```
### Menu Integration

Add inside `UEngine_buildSuccessMenus()` (UnrealEngine-75.LUA:1890) under the Debug menu. The menu must be added there (or to `UEngine.GUI.miDebug` after it is created) because `UEngine.GUI.menusBuilt` makes later direct additions from outside the builder unreliable:

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

### State Tracking

- `UEngine.UGameEngine.GameViewport` — cached offset (or nil if undetected)
- `UEngine.UGameEngine.ConsoleClass` — cached offset of the engine's console class property
- `UEngine.UGameViewportClient` — table with `ViewportConsole` offset
- `UEngine.DevConsoleEnabled` — boolean, set when enable succeeds (prevents double-run)

### Edge Cases — [fixed]

| Case | Handling |
|------|----------|
| GameEngine struct not scanned yet | `UEngine_ensureGameEngineStructure()` first (UnrealEngine-75.LUA:2622) |
| GameViewport offset unknown | Walk properties of GameEngine class at runtime |
| Console class name mismatch | Search for any UClass containing "Console" |
| **Shipping/Test build (`#if ALLOW_CONSOLE`=0)** | **Console creation is compiled out — must construct `UConsole` manually (Step D). Pressing ~ alone never creates it.** |
| UObjectArray not scanned | Return `nil, 'ObjectArray not found'` |
| No PlayerController | Console works without PC for `r.Fog` commands, CheatManager is separate |
| UE4 vs UE5 TObjectPtr | `TObjectPtr` wraps pointer at same offset for property access (raw pointer readable at offset). Applies to `GameViewport`, `ViewportConsole` |
| **FName layout UE4 vs UE5** | **UE5 has `DisplayIndex` between ComparisonIndex and Number — write all three fields** |
| `UInputSettings::ConsoleKeys` empty | AOB-patch the `Contains` check or use programmatic activation (Step F) |
| **Wrong `Outer` on created console** | **`UConsole::ConsoleCommand` dereferences `GetOuterUGameViewportClient()` — outer MUST be the `UGameViewportClient` or the game crashes on Enter** |
| **Remote call runs on foreign thread** | **CE-injected thread, not game thread — `check(IsInGameThread())` paths crash. Only call functions whose CDOs already exist; run at a quiet moment** |
| **`executeCodeEx` return semantics differ by CE build** | **Verify flags/call-vs-thread behavior in CE 7.5 at implementation time; fallback: poll `scratch` instead of trusting `ret`** |
| Manual console + logs | `GLog->AddOutputDevice` was not re-run; engine log lines won't show in the console |

## References

- `docs/SPLIT-PLAN.md` — core chain walking for GEngine, GameViewport
- `research/CE75-REFERENCE.md` — CE 7.5 Lua API reference
- UE source: `Engine/Source/Runtime/Engine/Classes/Engine/Console.h`
- UE source: `Engine/Source/Runtime/Engine/Classes/GameFramework/CheatManager.h`
- UE source: `Engine/Source/Runtime/Engine/Classes/Engine/Engine.h` (`UEngine::ConsoleClass`, `GameViewport`)
- UE source: `Engine/Source/Runtime/Engine/Classes/Engine/GameViewportClient.h` (`ViewportConsole` — the only console field on the viewport)
- UE source: `Engine/Source/Runtime/Engine/Private/UserInterface/Console.cpp` (`GetDefault<UInputSettings>()->ConsoleKeys.Contains(Key)`)
- UE source: `Engine/Source/Runtime/Engine/Private/GameViewportClient.cpp` (`SetupInitialLocalPlayer` → console created only under `#if ALLOW_CONSOLE`/`#if !UE_BUILD_SHIPPING`)
- Shipped-game technique (engine C++ function names to locate, executed via the CE-native `UEngine_callFunction` from Phase 3 Prelude — no external tools): `StaticFindObject("/Script/Engine.Console")` → `StaticConstructObject_Internal(Class, Viewport)` → `ViewportConsole = obj` → remap `ConsoleKeys`
