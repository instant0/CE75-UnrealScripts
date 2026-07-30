# Enabling the Unreal Engine Developer Console

Research into how UE4/UE5 games ship with the console disabled and common approaches to re-enable it.

## Background

The UE developer console (toggled by default with ~/Tilde) provides access to `CheatManager` commands like `God`, `Slomo`, `Summon`, `ToggleDebugCamera`, and `r.Fog 0`. Many shipped titles disable it by:

1. Removing the console key binding from `DefaultInput.ini`
2. Setting `ConsoleKey=None` in `Console.ini`
3. Compiling out the console entirely (`ALLOW_CONSOLE=0`)
4. Nulling or removing the `CheatManager` class reference on the `PlayerController`

## Common Re-enable Approaches

### 1. INI Patching (easiest, works on unlocked games)

Edit or inject into `Engine/Config/Console.ini` or `<Game>/Saved/Config/WindowsNoEditor/Input.ini`:

```ini
[Engine.Console]
ConsoleKey=Tilde
```

Also ensure a `CheatManager` class is assigned in `DefaultGame.ini`:

```ini
[/Script/Engine.PlayerController]
CheatClass=CheatManager
```

If the game validates INI signatures or uses PAK'd defaults, INI patching alone won't work.

### 2. AOB Patching the Console Key Check

Find the function that reads the console key binding and NOP out the check, or force the binding to Tilde regardless of config. Typical pattern in UE4/5:

```
- Find the string "ConsoleKey" in the binary
- Cross-reference to find the key-reading function
- Patch the comparison to always return Tilde (0x60 / VK_OEM_3)
```

### 3. Constructing a UConsole Object

If the game never creates a console instance (`UGameViewportClient::CreateConsole` is never called or returns null), force-create one by:

- Calling `UGameViewportClient::CreateConsole()` via hook or direct function call
- Setting `GEngine->GameViewport->ViewportConsole` to a new `UConsole` object
- Spawning a `Console` actor class via `SpawnActor` or `StaticConstructObject`

### 4. Forcing the Console Class

Some games ship with a console class but set it to `None` in the viewport client. Patch the member directly:

```
GEngine->GameViewport->ConsoleClass = LoadObject<UClass>(nullptr, TEXT("/Script/Engine.Console"));
```

Then call `CreateConsole()`.

### 5. Blueprint / Script-Based Activation

In UE4/5, the console can be opened from Blueprint via `Execute Console Command` nodes or from C++ via `PlayerController->ConsoleCommand()`. If a game's scripting system (e.g. AngelScript, Lua) has access to the `PlayerController`, a console command can be executed programmatically without the UI console.

## Relevant APIs and Structures

| Object | Purpose |
|--------|---------|
| `UConsole` | The HUD/UI console widget. `GEngine->GameViewport->ViewportConsole` |
| `UGameViewportClient::ConsoleClass` | `UClass*` for the console type to spawn. If `null`, console won't create |
| `UGameViewportClient::CreateConsole()` | Spawns the console object if `ConsoleClass` is valid |
| `PlayerController->CheatManager` | Processes cheat commands. Must be non-null for `God`, `Slomo`, etc. |
| `PlayerController->CheatClass` | `UClass*` used to spawn a `CheatManager` on `BeginPlay` |
| `UCheatManager` | Default cheat command handler. Games can subclass or remove it |

## Detection from CE

Check whether a console exists:

```lua
local vp = readPointer(UEngine.UGameEngine + UEngine.UGameEngine.GameViewport)
local console = vp and readPointer(vp + UEngine.UGameViewportClient.ViewportConsole)
-- if console ~= 0 and console ~= nil, a console object exists
```

Check the console class:

```lua
local consoleClass = vp and readPointer(vp + UEngine.UGameViewportClient.ConsoleClass)
-- if consoleClass ~= 0, the game has a console class loaded
```

Check if CheatManager is present on the PlayerController:

```lua
local pc = UEngine_findLocalPlayer()
local cm = pc and readPointer(pc + UEngine.UPlayer.PlayerController + offset_of_CheatManager)
-- or use property walk: UEngine_searchPropsOnObject(pc, {'CheatManager'})
```

## References

- `docs/SPLIT-PLAN.md` — core chain walking for GEngine, GameViewport
- `research/CE75-REFERENCE.md` — CE 7.5 Lua API reference
- UE source: `Engine/Source/Runtime/Engine/Classes/Engine/Console.h`
- UE source: `Engine/Source/Runtime/Engine/Classes/GameFramework/CheatManager.h`
