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

## Implementation Plan for `UnrealEngine-75.LUA`

Function: `UEngine_enableDeveloperConsole()`

### Chain of Discovery

```
UEngine.UGameEngine  (GEngine pointer, already cached)
    ↓ readPointer(vp + UObject.Class)
UGameEngine UClass
    ↓ property walk → find "GameViewport" (ObjectProperty, offset)
UEngine.UGameEngine.GameViewport
    ↓ readPointer(GEngine + GameViewportOffset)
UGameViewportClient*
    ↓ readPointer(vp + UObject.Class)
UGameViewportClient UClass
    ↓ property walk → find "ConsoleClass" (ClassProperty, offset)
    ↓ property walk → find "ViewportConsole" (ObjectProperty, offset)
```

### Steps

#### 1. Discover `GameViewport` offset on UGameEngine

Reuse existing `UEngine_getAllProperties(className)` on the GameEngine class to scan properties for the name `GameViewport`. Cache result in `UEngine.UGameEngine.GameViewport`.

```lua
local props = UEngine_getAllProperties(UEngine.GameEngineClass)
-- lookup the offset where name == "GameViewport", it's an ObjectProperty
```

Fallback: if `GameViewport` isn't in property link (removed by engine stripping), scan object memory of GEngine for pointer candidates that point to `UGameViewportClient` instances by name.

#### 2. Verify the viewport client is valid

`GameViewport` should always be set during engine init. Despite C++ being `TObjectPtr<UGameViewportClient>` in UE5 (which stores as a raw pointer in memory at the property offset), direct `readPointer` works. Log the result's class name for debugging.

#### 3. Discover `ConsoleClass` offset on UGameViewportClient

Use `UEngine_getAllProperties(vpClass)` where `vpClass = readPointer(vpAddress + UObject.Class)` to list properties. Find `ConsoleClass` (ClassProperty). Cache as `UEngine.UGameViewportClient.ConsoleClass`.

#### 4. Discover `ViewportConsole` offset on UGameViewportClient

Same property walk, find `ViewportConsole` (ObjectProperty). Cache as `UEngine.UGameViewportClient.ViewportConsole`.

#### 5. Read current state

```lua
local consoleClassPtr = readPointer(vpAddress + UEngine.UGameViewportClient.ConsoleClass)
local viewportConsolePtr = readPointer(vpAddress + UEngine.UGameViewportClient.ViewportConsole)
```

If `consoleClassPtr ~= 0` and `viewportConsolePtr ~= 0`, the console is already active — skip or report success.

#### 6. Find the `Console` UClass in memory

If `ConsoleClass` is null, search the UObjectArray for a `UClass` with `UObject_getName() == "Console"`:

```lua
function UEngine_findClassByName(name)
  -- iterate UObjectArray chunks/array
  -- for each FUObjectItem, check Object->Class == Class->Class (i.e. it's a UClass)
  -- and Object->Name == name
  -- return pointer to the UClass object
end
```

The UObjectArray is already discovered (`UEngine.ObjectArray`). Object iterating a chunked array:

```
numElements = readInteger(UEngine.ObjectArray + 0x08)
objectsPtr  = readPointer(UEngine.ObjectArray + 0x10)  -- points to chunk array or direct array
```

For each valid object, check:
- Class pointer at `obj + UEngine.UObject.Class` points to a UClass with name `Class` (self-referential for UClass)
- Name at `obj + UEngine.UObject.Name` matches `Console`

Priority order:
1. First try to find a `UClass` named `Console` (the engine class `/Script/Engine.Console`)
2. If that fails, find any object named `Console` and use its class as `ConsoleClass`
3. If nothing found, report failure

#### 7. Write `ConsoleClass`

```lua
writePointer(vpAddress + UEngine.UGameViewportClient.ConsoleClass, consoleClassAddr)
```

#### 8. Force `ViewportConsole` creation

If `CreateConsole()` were callable, that'd be ideal. In practice, after setting `ConsoleClass`, calling:

```lua
-- Option A: Try to find and call CreateConsole()
-- Get vtable from vpAddress, find CreateConsole slot
-- This is risky because of engine version differences

-- Option B: Construct a UConsole object manually using StaticConstructObject
-- Not easily callable from CE Lua

-- Option C: Wait for game to auto-create it on next tick/input
-- Many games call CreateConsole lazily on first input key

-- Option D: Copy from another engine instance or allocate empty
```

Preferred approach: **Option C** — after setting `ConsoleClass`, the console should auto-create on first `~` press. If not, fall back to calling `CreateConsole` via vtable slot.

#### 9. Register the console key

If the key binding is missing, patch `ConsoleKey` in `UGameViewportClient` or the input system. The console key is typically an `FKey` struct on `UConsole` itself:

```lua
-- UConsole has a property "ConsoleKey" (FKey, struct of FName)
-- Set it to the key for Tilde (~): name index for "Tilde" or "BackSpace"
```

In UE, `FKey` is an `FName` wrapper. If the name pool has `Tilde`, write that FName index:

```lua
local tildeIdx = UEngine.NameToIndex['Tilde']
if tildeIdx then
  writeInteger(consoleAddr + consoleKeyFNameOffset, tildeIdx)
  writeInteger(consoleAddr + consoleKeyFNameOffset + 4, 0)  -- number suffix = 0
end
```

If `Tilde` is not in the name pool, try `BackSpace` (most games support that as fallback).

#### 10. CheatManager setup (bonus)

For `God`, `Slomo`, etc., the `PlayerController` needs a `CheatManager`:

```lua
local pc = UEngine_findLocalPlayer()  -- existing
local cheatClass = readPointer(pc + playerControllerCheatClassOffset)
if cheatClass == 0 then
  -- Find UClass named "CheatManager" in object array
  -- Write it to CheatClass
  -- Also consider forcing SpawnCheatManager() call if CheatManager field is null
end
```

### Menu Integration

Add to `UEngine_buildSuccessMenus()` under the Debug menu:

```lua
UEngine.GUI.miEnableConsole=UE_newMenuItem('Enable Developer Console')
UEngine.GUI.miEnableConsole.OnClick=function()
  UEngine_runWhenReady(function()
    local ok,msg = UEngine_enableDeveloperConsole()
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
- `UEngine.UGameViewportClient` — table with `ConsoleClass` and `ViewportConsole` offsets
- `UEngine.DevConsoleEnabled` — boolean, set when enable succeeds (prevents double-run)

### Edge Cases

| Case | Handling |
|------|----------|
| GameEngine struct not scanned yet | `UEngine_ensureGameEngineStructure()` first |
| GameViewport offset unknown | Walk properties of GameEngine class at runtime |
| Console class name mismatch | Search for any UClass containing "Console" |
| UObjectArray not scanned | Return `nil, 'ObjectArray not found'` |
| No PlayerController | Console works without PC for `r.Fog` commands, CheatManager is separate |
| UE4 vs UE5 TObjectPtr | In UE5, `TObjectPtr` wraps pointer at same offset for property access (raw pointer still readable at offset) |

## References

- `docs/SPLIT-PLAN.md` — core chain walking for GEngine, GameViewport
- `research/CE75-REFERENCE.md` — CE 7.5 Lua API reference
- UE source: `Engine/Source/Runtime/Engine/Classes/Engine/Console.h`
- UE source: `Engine/Source/Runtime/Engine/Classes/GameFramework/CheatManager.h`
