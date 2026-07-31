# 00 — Background & Knowledge Base

Research into how UE4/UE5 games ship with the console disabled and common approaches to re-enable it.

Reference material for the console feature — **not an implementation task: no code is written here**. Read this first, then implement Tasks 1–10. Content preserved from `research/CE75-DEV-CONSOLE.md` with the review corrections marked.

Everything here (and in Tasks 1–10) is a *proposal* until implemented in `UnrealEngine-75.LUA`. The steps marked **[fixed]** contain corrections discovered during review; the original text made claims about the engine that do not match UE4/UE5 source.

---

## Background

The UE developer console (toggled by default with ~/Tilde) provides access to `CheatManager` commands like `God`, `Slomo`, `Summon`, `ToggleDebugCamera`, and `r.Fog 0`. Many shipped titles disable it by:

1. Removing the console key binding from `DefaultInput.ini` (`[/Script/Engine.InputSettings] ConsoleKeys=(Key=None)`)
2. Nulling `UEngine::ConsoleClass` (config: `[/Script/Engine.Engine].ConsoleClassName=`)
3. Compiling out console creation entirely — **`UGameViewportClient::SetupInitialLocalPlayer` only creates the console under `#if ALLOW_CONSOLE` / `#if !UE_BUILD_SHIPPING`**, which is off in Shipping/Test builds
4. Nulling or removing the `CheatManager` class reference on the `PlayerController`

**Key correction vs. original plan**: steps 1–4 above are the real disable vectors. The original plan listed "Removing the console key binding from `DefaultInput.ini`" and "Setting `ConsoleKey=None` in `Console.ini`" — that INI section is UE3-era. In UE4/UE5 the toggle key lives in `UInputSettings::ConsoleKeys` and the console *class* lives on `UEngine`, not on the viewport client (see the API table below).

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

If the game validates INI signatures or uses PAK'd defaults, INI patching alone won't work. Note: this only fixes the **key**; it does nothing if the console object was never created (see approach 3).

### 2. AOB Patching the Console Key Check

Find `UConsole::InputKey_InputLine` (the `GetDefault<UInputSettings>()->ConsoleKeys.Contains(Key)` check) or `APlayerController::ConsoleKey` (guarded by `#if ALLOW_CONSOLE`), and NOP/force the comparison so any key — or the Tilde key specifically — toggles the console. This is game/engine-version specific AOB work; only needed if `UInputSettings::ConsoleKeys` is empty or the check was recompiled.

### 3. Constructing a UConsole Object

If the game never created a console instance (`ViewportConsole == null` — guaranteed in Shipping because creation is compiled out), force-create one. **This is the hard step and the original plan understated it.** See Task 7 (Step D). The proven approach for shipped games — expressed here in abstract terms (the CE-native mechanics are in Task 7 / the Task 6 prelude):

```lua
-- abstract recipe (CE-native mechanics in Task 7 / Task 6):
-- 1. locate StaticConstructObject_Internal via AOB
-- 2. build an FStaticConstructObjectParameters{ Class=Console, Outer=GameViewport } in memory
-- 3. UEngine_callFunction(fnAddr, paramsPtr) -> new UConsole*
-- 4. writePointer(vp + ViewportConsole.off, newUConsole)
-- If the console already exists, skip straight to key remap (Task 8 / Step F).
```

### 4. Forcing the Console Class

Some games ship with a console class but set it to `None` on the **engine** (not the viewport):

```
UEngine::ConsoleClass = LoadObject<UClass>(nullptr, TEXT("/Script/Engine.Console"));
```

Then create the console (Task 7 / Step D). Patching `ConsoleClass` alone does **not** make the console appear — nothing re-runs `SetupInitialLocalPlayer`.

### 5. Blueprint / Script-Based Activation

In UE4/5, the console can be opened from Blueprint via `Execute Console Command` nodes or from C++ via `PlayerController->ConsoleCommand()`. If a game's scripting system has access to the `PlayerController`, console commands can be executed programmatically without the UI console. This is also a good **fallback** from CE: `APlayerController::ConsoleCommand(const FString& Command, bool bWriteToLog = true)` is a virtual (findable in the PC vtable) and works even if `ViewportConsole` was never created — commands just have no on-screen output. Invoke it via CE 7.5 **`executeCodeEx` with the PC as the first (RCX) parameter — NOT `executeMethod(addr, pc, param)`**. Verified in `LuaHandler.pas`: `executeMethod` emits the instance `mov` *before* the param loop, so the first param is also assigned to RCX and clobbers the instance (and `ConsoleCommand`'s second argument `bWriteToLog` needs R8, which the wrapper never set). The correct x64 thiscall for `ConsoleCommand` is:

```lua
executeCodeEx(0, 5000, consoleCommandAddr, pc, fstringPtr, {type=0, value=1})
-- RCX = pc (this), RDX = &FString (Command), R8 = 1 (bWriteToLog)
```

(wrapper: `UEngine_callMethod(fnAddr, instance, ...)` delegates to `executeCodeEx`). The command string must be a real `FString` built in target memory (`allocateMemory`) as `{ TCHAR* Data; int32 Num; int32 Capacity }` with `Data` pointing at a wide-char buffer written via `writeString(addr, cmd, true)` — **note `writeString` writes exactly `len*2` bytes with no trailing null (`LuaHandler.pas:2485`)**: allocate `len*2+2` and write an explicit `0` terminator at `Data[len]`. **No UE4SS-style `PlayerController:ConsoleCommand("cmd")` binding exists in CE.**

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

## Detection from CE (read-only)

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
-- at UnrealEngine-75.LUA:3162). The original plan's UEngine.UPlayer.PlayerController
-- cache does not exist in the codebase.
local lp = UEngine_findLocalPlayer()
-- pcProp = UEngine_getAllProperties(lpClass)['PlayerController']
-- pc     = readPointer(lp + pcProp.offset)
local cm = readPointer(pc + offset_of_CheatManager)
-- or property walk: UEngine_searchPropsOnObject(pc, {'CheatManager'})
```

## References

- `docs/SPLIT-PLAN.md` — core chain walking for GEngine, GameViewport
- `research/CE75-REFERENCE.md` — CE 7.5 Lua API reference
- **CE 7.5 source: `LuaHandler.pas`** — remote-call API verified at `executeCodeEx` (registered `LuaHandler.pas:16864`, impl `:12039`), `executeMethod` (`:16865`), `executeCode` (`:16863`), `allocateMemory` (`:16952`, impl `:14285`), `writeString` (`:16228`), `writeBytes` (`:16200`)
- UE source: `Engine/Source/Runtime/Engine/Classes/Engine/Console.h`
- UE source: `Engine/Source/Runtime/Engine/Classes/GameFramework/CheatManager.h`
- UE source: `Engine/Source/Runtime/Engine/Classes/Engine/Engine.h` (`UEngine::ConsoleClass`, `GameViewport`)
- UE source: `Engine/Source/Runtime/Engine/Classes/Engine/GameViewportClient.h` (`ViewportConsole` — the only console field on the viewport)
- UE source: `Engine/Source/Runtime/Engine/Private/UserInterface/Console.cpp` (`GetDefault<UInputSettings>()->ConsoleKeys.Contains(Key)`)
- UE source: `Engine/Source/Runtime/Engine/Private/GameViewportClient.cpp` (`SetupInitialLocalPlayer` → console created only under `#if ALLOW_CONSOLE`/`#if !UE_BUILD_SHIPPING`)
- Shipped-game technique (engine C++ function names to locate, executed via the CE 7.5 `executeCodeEx`/`executeMethod` wrappers from Task 6 — no external tools): `StaticFindObject("/Script/Engine.Console")` → `StaticConstructObject_Internal(Class, Viewport)` → `ViewportConsole = obj` → remap `ConsoleKeys`
