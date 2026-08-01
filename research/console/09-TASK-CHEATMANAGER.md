# Task 9 — Step G: CheatManager setup (bonus) — [fixed]

**Goal:** Ensure the `PlayerController` has a `CheatManager` so `God`, `Slomo`, etc. work. Runs only if cheat commands are the goal (bonus — independent of console UI).

**Depends on:** Task 3 (`UEngine_findClassByName('CheatManager')`), Task 5 (`cheatCDO` hard gate + `state.playerController`), Task 6 (`UEngine_callMethod` / `UEngine_callFunction`), Task 7 (`UEngine.SCOAddr` — validated `StaticConstructObject_Internal`), core `UEngine_getAllProperties` + property walk.
**Used by:** Task 10 (as `needs.cheat`, best-effort).

> **Implementation target (per [`SPLITFILE.md`](SPLITFILE.md) §6):** implement `UEngine_setupCheatManager()` in **`Scripts/console/console.lua`**. No `UnrealEngine-75.LUA` edit is needed for this task.

---

For `God`, `Slomo`, etc., the `PlayerController` needs a non-null `CheatManager`. `CheatManager`/`CheatClass` are `APlayerController` UPROPERTYs (`TObjectPtr<UCheatManager>` / `TSubclassOf<UCheatManager>` in UE5.x, raw `UCheatManager*` in UE4; the class's default `CheatClass` is `UCheatManager::StaticClass()`, set in the `APlayerController` constructor). `UCheatManager` is `UCLASS(Blueprintable, Within=PlayerController)` — its Outer is the PlayerController (see References). **Layout note (dual-version):** in a shipped UE5 game `WITH_EDITORONLY_DATA = 0` (`CoreMiscDefines.h:25`) makes `FObjectHandle = UObject*` (`ObjectHandleDefines.h:10`), so `TObjectPtr`/`TSubclassOf` are plain pointers — the property-walk read at the UPROPERTY offset is layout-identical to UE4.

### The spawn entry point is the SAME in UE4 and UE 5.4 (verified against both sources)

The CheatManager spawn is `APlayerController::AddCheats(bool bForce)` in **both** UE4 and UE 5.4.0 (a `virtual`, default `bForce = false`, `PlayerController.h:1970`). The earlier claim that UE5 moved it to `AController::SpawnCheatManager()` is **false — no such function exists anywhere in the UE 5.4.0 source tree** (whole-tree grep = 0 matches), and it is not listed in the UE5.8 `AController` API docs either.

- **UE4.x** — `APlayerController::AddCheats(bool bForce)` (`Private/PlayerController.cpp`). Body (verified):
  ```cpp
  void APlayerController::AddCheats(bool bForce)
  {
      UWorld* World = GetWorld();
      check(World);
      // Abort if cheat manager exists or there is no cheat class
      if (CheatManager || !CheatClass) { return; }
      // Spawn if game mode says we are allowed, or if bForce
      if ((World->GetAuthGameMode() && World->GetAuthGameMode()->AllowCheats(this)) || bForce)
      {
          CheatManager = NewObject<UCheatManager>(this, CheatClass);
          CheatManager->InitCheatManager();
      }
  }
  void APlayerController::EnableCheats()   // called from PostInitializeComponents
  {
  #if !(UE_BUILD_SHIPPING || UE_BUILD_TEST)
      AddCheats(true);   // forced in dev builds
  #else
      AddCheats();       // Shipping/Test: ONLY if GameMode->AllowCheats(this)
  #endif
  }
  ```
- **UE 5.4.0** — the same `APlayerController::AddCheats(bool bForce)` (`Private/PlayerController.cpp:1107`), with two changes:
  1. The body is wrapped in `#if UE_WITH_CHEAT_MANAGER`, and `UE_WITH_CHEAT_MANAGER` is defined as `(1 && !UE_BUILD_SHIPPING)` (`Classes/GameFramework/CheatManagerDefines.h:8`). **In Shipping the native spawn is compiled out entirely** — the engine literally cannot spawn a CheatManager there, which is exactly why the SCO-replication repair (below) is the *only* way to get one in a Shipping 5.4 game.
  2. `EnableCheats()` (`:1129`) gates on `#if !UE_BUILD_SHIPPING` only (the UE4 `UE_BUILD_TEST` special-case is gone, since `UE_WITH_CHEAT_MANAGER` already excludes Shipping).
  Body is otherwise identical, incl. the `AllowCheats(this) || bForce` gate and the `NewObject<UCheatManager>(this, CheatClass)` + `InitCheatManager()` core. `CheatManager`/`CheatClass` remain `APlayerController` UPROPERTYs (`PlayerController.h:363/370`, `TObjectPtr<UCheatManager>` / `TSubclassOf<UCheatManager>`); ctor `CheatClass = UCheatManager::StaticClass()` (`:192`); spawned from `PostInitializeComponents()` (`:1028`, `AddCheats()` call at `:1046`). The 5.4 header comment (`:356`–`:361`) documents the intended behavior: "In Shipping configurations, the manager is always disabled because UE_WITH_CHEAT_MANAGER is 0 … cheats are enabled by default in single player games but can be forced on with the EnableCheats console command", overridable via `EnableCheats`/`AGameModeBase::AllowCheats`.
- **Shared core (both):** `CheatManager = NewObject<UCheatManager>(this, CheatClass);` then `CheatManager->InitCheatManager();`. **Because this core action is identical across UE4/UE5.4 and *is* `StaticConstructObject_Internal`, Option C below is version-agnostic — no version-branching needed in the repair.** (In a Shipping 5.4 target it is not merely convenient but *required*: the native `AddCheats` does not exist there.)

Console-cheat dispatch does **not** need `InitCheatManager()`. The command flow is identical in UE4 and UE5.4: `UConsole::ConsoleCommand` (`UserInterface/Console.cpp:520` UE4 / `:606` UE5.4) → `ConsoleTargetPlayer->PlayerController->ConsoleCommand(Command)` (`:539` / `:625`) → `APlayerController::ConsoleCommand` (`PlayerController.cpp:384` / `:517`) → `Player->ConsoleCommand` (`Player.cpp:28` / `:30`) → `UPlayer::Exec` (`Player.cpp:92` / `:95`). UE5.4's `UPlayer::Exec` prepends `FExec::Exec(InWorld, Cmd, Ar)` (self-registered exec-command handlers) and then runs the same branch chain, which reaches the cheat manager at `PlayerController->CheatManager->ProcessConsoleExec(Cmd, Ar, PCPawn)` (`Player.cpp:134` UE4 / `:143` UE5.4). `ProcessConsoleExec` is the `UObject` base (overridden by `UCheatManager`, `CheatManager.h:103`); the UE5.4 override (`CheatManager.cpp:92`) first routes `BlueprintAuthorityOnly` cheats to `ServerExec()` on a client and iterates `CheatManagerExtensions`, then falls back to `Super::ProcessConsoleExec` = `FindFunction(name)` → `ProcessEvent`. Only a **non-null** `CheatManager` is required (all of `God`, `Slomo`, `Summon`, `ToggleDebugCamera` are `UFUNCTION(exec)` on `UCheatManager`), so replicating the `NewObject` step is sufficient for the goal.

### The spawn address question (corrected 2026-08-01)

The earlier wording *"`SpawnCheatManager()` is virtual in UE4 and UE5 → resolve it from the PC vtable; no AOB needed"* is **not implementable as written** (and the function name itself was wrong — the spawn is `AddCheats`, which *is* virtual in both UE4 and UE5.4, but the resolution claim still fails). Resolving a virtual from the vtable requires its **slot index**, which is version-pinned compiler output. Neither this doc nor anything in `research/` carries UE source, a SDK/vtable dump, or a slot table (verified: `CE75-REFERENCE.md`, `CE75-PLAYER-PROPS.md` contain no `AddCheats` data), so the claim gave no way to obtain `spawnCheatManagerAddr`. Three options:

- **Option C — replicate `NewObject<UCheatManager>` via Task 7's `UEngine.SCOAddr` (chosen).**
  `AddCheats`'s core action *is* `StaticConstructObject_Internal`, already located AND validated by Task 7 and cached/persisted as `UEngine.SCOAddr` (`console.lua:1126`). Zero new function location. The params-struct fill is exactly `UEngine_createConsole`'s (`console.lua:1245`–`:1254`), substituting `Class = CheatClass UClass`, `Outer = pc`, keeping `SetFlags = RF_NoFlags (0)` and `Template = nil` — the `cheatCDO` gate covers the CDO-get-without-create path, so the foreign-thread safety argument is identical to Task 7. The returned object is validated **before** the write (`newCM.Class == passed CheatClass`), then `writePointer(pc + CheatManager.off, newCM)`. Deviations from the real spawn are benign for the goal: the `CheatManager || !CheatClass` abort and `InitCheatManager()` are skipped, and the `AllowCheats(this)` gate is bypassed — none of them affect `ProcessConsoleExec`-based cheat dispatch.
- **Option B — version-pinned `AddCheats` body AOB (fallback).** A Task 7-style pattern table (`UEngine.CheatManagerPatterns[engineVersion] = {...}`, filled at CE attach, never fabricated), using the locating toolset already documented in `CE-FUNCTIONS.md` §6 / `06-TASK-REMOTE-CALL-PRELUDE.md` (`AOBScanModuleUnique`, `getReferences`, `LastDisassembleData`, `UEngine_findFunctionStart`). Only needed if full engine behavior (`InitCheatManager`, the `AllowCheats` gate) is ever required.
- **Option A — vtable-resolve (rejected).** Requires the slot index, present nowhere; a runtime vtable hunt (disassembling PC-vtable targets for a null-check + SCO-call body) is heavier and undocumented versus Option C.

**Decision: implement Option C.** If it is ever shown insufficient on a live target, promote Option B — the pattern table is the documented extension point, exactly like Task 7's `UEngine.SCOPatterns`.

### References (online UE/CE source used for this task — added 2026-08-01)

The original research read the UE source online but **left no URLs or version pinning anywhere in `research/`** (0 `http(s)://` matches in the whole tree; UE source cited only by repo-relative path like `Engine/Source/Runtime/Engine/Classes/GameFramework/CheatManager.h`). Those citations are re-added here with the anchors verified on 2026-08-01:

- **UE5.4.0 full source (authoritative UE5 pin, on this machine)** — `/home/malware/projects/Unreal/5.4.0-release/UnrealEngine-5.4.0-release/` (tag `5.4.0-release`; `ENGINE_MAJOR_VERSION 5, MINOR 4, PATCH 0`). Verified anchors: `APlayerController::AddCheats` `Engine/Source/Runtime/Engine/Private/PlayerController.cpp:1107`; `EnableCheats` `:1129`; `PostInitializeComponents` `:1028` (`AddCheats()` at `:1046`); ctor `CheatClass = UCheatManager::StaticClass()` `:192`; `PlayerController.h:363/370` (`CheatManager`/`CheatClass`); `UE_WITH_CHEAT_MANAGER` `Classes/GameFramework/CheatManagerDefines.h:8`; `UPlayer::Exec` `Private/Player.cpp:95` (CheatManager branch `:143`); `UConsole::ConsoleCommand` `Private/UserInterface/Console.cpp:606` (`:625`/`:631`/`:636`); `UCheatManager::ProcessConsoleExec` `Private/CheatManager.cpp:92`. **No `AController::SpawnCheatManager` exists anywhere in 5.4.0** (whole-tree grep = 0).
- **UE4 `PlayerController.cpp`** (AddCheats ~:1033, EnableCheats ~:1052, PostInitializeComponents→AddCheats() ~:967, ctor `CheatClass = UCheatManager::StaticClass()` ~:93) — `https://github.com/folgerwang/UnrealEngine/blob/release/Engine/Source/Runtime/Engine/Private/PlayerController.cpp` (public mirror, `release` branch, UE4-era; `https://raw.githubusercontent.com/folgerwang/UnrealEngine/release/...` for raw text).
- **UE4 exec chain to the CheatManager** — `UConsole::ConsoleCommand` `Engine/Source/Runtime/Engine/Private/UserInterface/Console.cpp:520/539`; `UPlayer::Exec` `Player.cpp:92`, CheatManager branch (`CheatManager->ProcessConsoleExec`) `:134`; `UPlayer::ConsoleCommand` `:28` (same mirror).
- **UE4 `PlayerController.h`** (CheatManager/CheatClass UPROPERTYs `:326/:330`; `AddCheats` virtual `:1691`) — `Engine/Source/Runtime/Engine/Classes/GameFramework/PlayerController.h` (same mirror).
- **`UCheatManager` class API (UE5.7/5.8 docs)** — confirms `UCLASS(Blueprintable, Within=PlayerController)`, `virtual void InitCheatManager()`, `virtual bool ProcessConsoleExec(...)` (overridden from `UObject`), and `God`/`Slomo`/`Summon`/`ToggleDebugCamera` as `UFUNCTION(exec)`: `https://dev.epicgames.com/documentation/unreal-engine/API/Runtime/Engine/UCheatManager`
- **`AController` class API (UE5.8 docs)** — no `SpawnCheatManager` in the function list (consistent with 5.4.0): `https://dev.epicgames.com/documentation/unreal-engine/API/Runtime/Engine/AController`
- **CE 7.5 source** (`LuaHandler.pas`, executeCodeEx/executeMethod register behavior) — also cited path:line only (e.g. `:11736` vs `:11836`); official source requires the CE 7.5 checkout. Keep the `LuaHandler.pas:<line>` references as the pin, and treat `research/CE-FUNCTIONS.md` §6 as the verified extract.

Version-pinning rule (from Task 1's engine gate): the `UEngine.EngineVersion`/`UEngine.UEFlavour` detection decides which facts above apply to a live target. The spawn is `APlayerController::AddCheats` in both UE4 and UE5.4 (identical `NewObject` core), so no function-name branching is ever needed; the only per-version facts are the build-gate differences (`UE4: EnableCheats` also forces in `UE_BUILD_TEST`; `UE5.4: UE_WITH_CHEAT_MANAGER` = shipping-compiled-out) and the exact line numbers above. Option C (SCO replication) is version-agnostic because it reproduces only the shared `NewObject` core — and in a Shipping UE5.4 game it is the *only* way (the native spawn is compiled out).

### Correction (2026-08-01 — dual-version source audit, see 11-TASK-DUAL-VERSION-CORRECTIONS.md)

Option C (SCO replication) stands, but it inherits two corrections from the audit:

1. **`templateOff` (SCO params struct).** The params fill referenced below
   (`console.lua:1241-1254`) must use the corrected `templateOff = align8(internalOff+6)`
   = 0x28 for BOTH FName sizes (the two `bool` fields `bCopyTransientsFromClassDefaults`
   + `bAssumeTemplateIsArchetype` exist in `FStaticConstructObjectParameters`
   (`UObjectGlobals.h:1594-1640`); the old `align8(internalOff+4)` = 0x20 was wrong for
   FName=8). Section 11 §2/§7d. Applies to CheatManager exactly as to Console.
2. **`cheatCDO` gate flag.** The CDO gate below (`cheatCDO`) is populated by Task 5's
   CDO walk, which tests `RF_ClassDefaultObject`. The constant was wrong (`0x200`);
   it must be `0x10` (`ObjectMacros.h:541`). Section 11 §4/§7c. If the flag test is
   wrong, the walk finds no CDO and Option C is blocked needlessly.

## Repair flow

```lua
-- pc is already in hand: Task 5's probe stores it as
-- UEngine.DevConsoleState.playerController (05-TASK-ASSESSMENT.md). Reuse it — do not re-walk.
local state = UEngine.DevConsoleState
local pc    = state and state.playerController
if not pc or pc == 0 then return nil,'no PlayerController (bonus only — skip)' end

-- Resolve BOTH offsets in one property walk. Task 5's UEngine_readCheatManager
-- (console.lua:714) resolves only 'CheatManager'; extend the search to
-- {'CheatManager','CheatClass'}.
local pcProps = UEngine_searchPropsOnObject(pc, {'CheatManager','CheatClass'})
local cmProp  = pcProps and pcProps['CheatManager']
local ccProp  = pcProps and pcProps['CheatClass']
if not cmProp then return nil,'CheatManager property not found on PlayerController' end

-- HARD GATE (mirrors Task 7's consoleCDO): never construct a UCheatManager without the
-- Default__CheatManager CDO present. NewObject on the CE foreign thread with a missing
-- CDO would build it -> check(IsInGameThread()) risk (Task 6 caveats). If blocked,
-- CheatClass may still be patched (plain write) but the spawn must NOT run.
local cheatCDO = state and state.cheatCDO

local cm = readPointer(pc + cmProp.offset)
if cm and cm ~= 0 then return true,'already enabled' end      -- idempotent
if ccProp and readPointer(pc + ccProp.offset) == 0 then        -- patch CheatClass first
  local cmClass = UEngine_findClassByName('CheatManager')      -- Task 3 walk (console.lua:413)
  writePointer(pc + ccProp.offset, cmClass)
end
if not cheatCDO then
  if state then state.blocked.cheat='no Default__CheatManager CDO — spawn refused' end
  return false,'cheat blocked (CDO missing)'
end

local ccAddr = readPointer(pc + ccProp.offset)                 -- CheatClass UClass to construct
-- Option C: replicate NewObject via the validated SCO (UEngine_createConsole's params
-- fill at console.lua:1245, reworked: Class=ccAddr, Outer=pc, SetFlags=0, Template=nil).
local newCM = <Task 7 params fill> UEngine_callFunction(UEngine.SCOAddr, params)
if not newCM then return false,'spawn failed (AddCheats NewObject replication)' end
if readPointer(newCM + UEngine.UObject.Class) ~= ccAddr then   -- validate BEFORE writing
  UEngine_free(params)
  return false,'spawn validation failed (class mismatch)'
end
writePointer(pc + cmProp.offset, newCM)
UEngine_free(params)
return newCM, pc                                               -- verify by re-read upstream
```

Notes:
- `UEngine_findLocalPlayer()` returns the `ULocalPlayer`, **not** the `PlayerController` — never use it as `pc`.
- `UEngine_callMethod` (console.lua:922) always delegates to `executeCodeEx` and is **never** replaced by CE's `executeMethod` (register collision, `LuaHandler.pas:11736` vs `:11836`, Task 6). Option C does not need a method call at all, so that caveat is moot here.
- `UEngine_findClassByName('CheatManager')` resolves the native `UCheatManager` UClass even on Shipping builds (classes persist in `GUObjectArray`; it is the *instance* that is absent). If `CheatClass` is a BP subclass, its name differs — validation uses `Class == ccAddr`, not a name string.

---

## Definition of done

- `CheatClass` written with the `CheatManager` UClass if it was null.
- `CheatManager` created via Option C (`UEngine.SCOAddr`, Task 7's validated `StaticConstructObject_Internal`) with `Outer = pc`, `SetFlags = RF_NoFlags`, `Template = nil`.
- Created object validated **before** assignment (`Class == passed CheatClass`).
- The spawn is **gated on `cheatCDO`** (`Default__CheatManager` present, Task 5 signal) — if absent, `cheat` is recorded as blocked (`state.blocked.cheat`) and the spawn never runs. `CheatClass` may still be patched.
- `CheatManager` re-read after the write; null → recorded as unpatched, never assumed done.
- No PlayerController present → repair skipped gracefully (bonus only).

## Verification

1. `readPointer(pc + CheatManager.off)` non-null after the repair.
2. `God`, `Slomo`, `Summon`, `ToggleDebugCamera` accepted through the console.
3. Re-run is a no-op (idempotent).
4. On a build where `Default__CheatManager` is genuinely absent, `cheat` is reported blocked — the spawn never runs.
5. Syntax gate before use: `luac -p Scripts/console/console.lua` and `loadfile`. No unit tests are written for this task (verification is the syntax gate + live CE-attach checks 1–4).

---

## Implementation review (2026-08-01)

Review-only pass (no code written). Corrections landed in this doc:

1. **The vtable claim was unimplementable as written.** No slot-index data for `SpawnCheatManager` exists in `research/` (no UE source, no SDK/vtable dump). Replaced with Option C (replicate `NewObject` via Task 7's already-located+validated `UEngine.SCOAddr`), fallback Option B (version-pinned body AOB), Option A rejected.
2. **The spawn entry point is the SAME in UE4 and UE5.4 — and the doc's "AController::SpawnCheatManager(), virtual in both" was wrong twice.** First the UE4 fix: the spawn is `APlayerController::AddCheats(bool bForce)`/`EnableCheats()`, not `AController::SpawnCheatManager()`. Second, verified against the **local UE 5.4.0 source** (`projects/Unreal/5.4.0-release`): `SpawnCheatManager` does not exist in 5.4.0 (whole-tree grep = 0) and is absent from the UE5.8 `AController` docs — UE5.4 still spawns via `APlayerController::AddCheats` (`PlayerController.cpp:1107`), identical `NewObject<UCheatManager>(this, CheatClass)` + `InitCheatManager()` core, wrapped in the new `UE_WITH_CHEAT_MANAGER` (=`1 && !UE_BUILD_SHIPPING`) build gate (Shipping ⇒ native spawn compiled out entirely). Option C is therefore version-agnostic *and* the only path to a CheatManager in a Shipping UE5.4 game.
3. **The exec-dispatch claim was also wrong.** The earlier sentence credited `APlayerController::ProcessConsoleExec` — UE4's `APlayerController` does **not** override it. Verified chain (same in UE4 and UE5.4): `UConsole::ConsoleCommand` → `APlayerController::ConsoleCommand` (`PlayerController.cpp:384` UE4 / `:517` UE5.4) → `UPlayer::Exec` (`Player.cpp:92` / `:95`, UE5.4 prepends `FExec::Exec`), which reaches the cheat manager at `PlayerController->CheatManager->ProcessConsoleExec(...)` (`:92` / `:143`). Corrected with the `Player.cpp`/`Console.cpp` anchors.
4. **The original research left no online references** (0 URLs in `research/`). Added a References section with the verified mirror/docs URLs and a version-pinning rule.
5. **`UEngine_readCheatManager` (console.lua:714) resolves only `CheatManager`** — the repair must search `{'CheatManager','CheatClass'}` in one property walk (`UEngine_searchPropsOnObject`, core `:3381`).
6. **`state.playerController` (Task 5) already provides `pc`** — no re-walk of LocalPlayer at repair time.
7. **Stale `executeMethod` parenthetical removed** — `UEngine_callMethod` always uses `executeCodeEx` (Task 6 register-collision finding); Option C needs no method call anyway.
8. **Stale line refs fixed while auditing:** `console.lua:712` comment `UnrealEngine-75.LUA:3684` → `:3162`; `UEngine_readCheatManager` ref `:1602` (05-TASK-ASSESSMENT.md) → `console.lua:714`; "vtable-resolved" wording in `README.md` / `SPLITFILE.md` §6 / `CE75-DEV-CONSOLE.md` requirement-matrix rows → SCO-replication wording.

## Change log

- 2026-08-01 — Implementation review: corrected the spawn-address strategy (Option C chosen), extended the property walk to `CheatClass`, reuse `state.playerController`, removed the `executeMethod` parenthetical, fixed stale cross-doc refs.
- 2026-08-01 — Follow-up review: corrected the UE4/UE5 spawn-entry-point claim (`AddCheats` vs `SpawnCheatManager`, incl. the UE4 `AllowCheats` gate) and re-added the online source references the original research had omitted. Implementation of `UEngine_setupCheatManager()` **pending**.
- 2026-08-01 — Third review, now against the **local UE 5.4.0 source** (`projects/Unreal/5.4.0-release/UnrealEngine-5.4.0-release/`): the earlier UE5 body ("`AController::SpawnCheatManager()`, `PlayerInput && ...` guard") was **fabricated — no such function exists in 5.4.0** (or the 5.8 docs). Corrected: UE5.4 spawns via the same `APlayerController::AddCheats` (identical core), wrapped in `UE_WITH_CHEAT_MANAGER` (shipping-compiled-out); added UE5.4 line anchors for the spawn, `UPlayer::Exec` chain, `UConsole::ConsoleCommand`, and `UCheatManager::ProcessConsoleExec`. Dual-version support is now fully sourced: UE4 = folgerwang mirror, UE5.4 = local tag, same `NewObject` core in both ⇒ Option C needs no version-branching.
