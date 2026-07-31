# Enabling the Unreal Engine Developer Console

Research into how UE4/UE5 games ship with the console disabled and common approaches to re-enable it.

> **REORGANIZED — content moved to `research/console/`.** This document is now an index/summary. The full spec (background, 5 approaches, API tables, detection snippets, implementation plan, Steps A–G, Phase 3 Prelude, Phase 4, edge cases, references) lives in the task docs under [`research/console/`](console/), split so each task can be implemented in sequence. The move was write-first: all content was written to `research/console/` before this file was trimmed.

## Status — PLAN ONLY, NOT IMPLEMENTED ⚠️

Verified 2026-07-31 against `UnrealEngine-75.LUA` (4489 lines), UE4/UE5 engine source, and the **CE 7.5 source** (`LuaHandler.pas`):

- ✅ **Self-contained: no UE4SS or other external tool is required.** Every engine function that must be *called* (`StaticConstructObject_Internal`, `SpawnCheatManager`, `ConsoleCommand`) is invoked through **CE 7.5's built-in remote-call APIs** — `executeCodeEx`, `executeMethod`, `allocateMemory`/`writeString`/`writeBytes` — plus the thin wrappers in [`06-TASK-REMOTE-CALL-PRELUDE.md`](console/06-TASK-REMOTE-CALL-PRELUDE.md).
- ❌ **No `UEngine_enableDeveloperConsole()` function exists** (grepped — zero console/CheatManager hits in the core script).
- ❌ **No `UEngine.UGameViewportClient` cache, no `UEngine.DevConsoleEnabled` state, no menu item.** `UEngine.GUI.miDebug` exists and is the right home for the menu entry, but nothing has been added.

Everything in the task docs is a *proposal*; the steps marked **[fixed]** contain corrections discovered during review.

## Task breakdown (in `research/console/`)

| # | Doc | Content |
|---|-----|---------|
| — | [`console/README.md`](console/README.md) | Index, dependency graph, requirement matrix, chain of discovery, status board, edge cases |
| 0 | [`console/00-BACKGROUND.md`](console/00-BACKGROUND.md) | Background (disable vectors), 5 re-enable approaches, relevant APIs/structures, detection-from-CE snippets, references |
| 1 | [`console/01-TASK-PHASE1-DETECT.md`](console/01-TASK-PHASE1-DETECT.md) | **Phase 1** layout detection — `UEngine_detectFNameLayout()` → `UEFlavour`, `FNameSize` (8/12), cross-checks |
| 2 | [`console/02-TASK-OFFSET-DISCOVERY.md`](console/02-TASK-OFFSET-DISCOVERY.md) | **Step A + B** — `GameViewport` and `ViewportConsole` offsets |
| 3 | [`console/03-TASK-FIND-CONSOLE-CLASS.md`](console/03-TASK-FIND-CONSOLE-CLASS.md) | **Step E** — `UEngine_findClassByName()` → `Console` UClass (FName scan + object-array paths) |
| 4 | [`console/04-TASK-CONSOLE-CLASS-FIX.md`](console/04-TASK-CONSOLE-CLASS-FIX.md) | **Step C** — fix `UEngine::ConsoleClass` |
| 5 | [`console/05-TASK-ASSESSMENT.md`](console/05-TASK-ASSESSMENT.md) | **Phase 2** assessment — `UEngine.DevConsoleState` + `needs` list (read-only) |
| 6 | [`console/06-TASK-REMOTE-CALL-PRELUDE.md`](console/06-TASK-REMOTE-CALL-PRELUDE.md) | **Phase 3 Prelude** — CE 7.5 `executeCodeEx`/`executeMethod` wrappers + caveats |
| 7 | [`console/07-TASK-CREATE-CONSOLE.md`](console/07-TASK-CREATE-CONSOLE.md) | **Step D (crux)** — construct `UConsole` with outer=GameViewport via `StaticConstructObject_Internal` |
| 8 | [`console/08-TASK-CONSOLE-KEYS.md`](console/08-TASK-CONSOLE-KEYS.md) | **Step F** — patch `UInputSettings` CDO `ConsoleKeys` FKey `KeyName` → `Tilde` |
| 9 | [`console/09-TASK-CHEATMANAGER.md`](console/09-TASK-CHEATMANAGER.md) | **Step G (bonus)** — `CheatClass` + `SpawnCheatManager()` via `UEngine_callMethod` |
| 10 | [`console/10-TASK-ORCHESTRATOR.md`](console/10-TASK-ORCHESTRATOR.md) | **Phase 4** verify + `UEngine_enableDeveloperConsole()` orchestrator + Debug-menu integration + state tracking |

### Implementation order

```
00-BACKGROUND (read first)
  → T1 detect → T2 offsets → T3 findClass → T4 ConsoleClass fix → T5 assess
  → T6 prelude → T7 create console → T8 keys → T9 CheatManager → T10 orchestrator
```

Start at [`console/README.md`](console/README.md) for the dependency graph and status board.

## Design principle — Detect → Assess → Repair → Verify

The console is disabled through **independent vectors**; a game may have *any subset* of them, so a single fixed patch sequence is wrong. The feature must:

1. **Detect** engine layout (UE4 vs UE5, pointer size) so every later read/write uses the right structure sizes.
2. **Assess** (read-only) every console-related signal and build a `needs` list — **no writes yet**.
3. **Repair** only the items on the `needs` list, in dependency order (class before instance before keys).
4. **Verify** by re-reading state, then report what was patched vs. what remains blocked.

This makes the feature **idempotent**: running it on an already-enabled console just reports "already active".

## Requirement matrix

| Disable vector | Detection signal (Task 5) | Repair | Runs when |
|---|---|---|---|
| Console never created (Shipping compile-out) | `readPointer(vp + ViewportConsole.off) == 0` | construct `UConsole` with outer = viewport (Task 7) | shipping/test builds |
| `UEngine::ConsoleClass` set to null | `readPointer(ge + ConsoleClass.off) == 0` | find `Console` UClass, write it (Task 4) | config-patched games |
| Toggle keys removed (`ConsoleKeys` empty/wrong) | `UInputSettings` CDO `ConsoleKeys` lacks `Tilde` | patch first FKey `KeyName` (Task 8) | INI-patched games |
| Key-check recompiled / array unfixable | key never toggles despite fix | AOB-patch `ConsoleKeys.Contains` check (Approach #2) | hard-blocked games |
| `CheatManager` absent | `PC.CheatClass` / `PC.CheatManager` null | patch `CheatClass` + `SpawnCheatManager()` via `UEngine_callMethod` (Task 9) | cheat commands needed |
| Already enabled | all signals green | no-op | — |

## Chain of discovery

```
UEngine.UGameEngine  (GEngine pointer, already cached)
    ↓ readPointer(ge + UObject.Class)
UGameEngine UClass
    ↓ property walk → find "GameViewport" (ObjectProperty, offset)              ← Task 2
UEngine.UGameEngine.GameViewport            ← viewport client pointer
    ↓ property walk on viewport class → find "ViewportConsole" (ObjectProperty) ← Task 2
UEngine.UGameViewportClient.ViewportConsole ← the console instance (may be null in Shipping)
    ↓ property walk on GameEngine class → find "ConsoleClass" (ClassProperty)   ← Task 4
UEngine.UGameEngine.ConsoleClass            ← the class to spawn (may be null)
    ↓ find UClass named "Console" in the UObjectArray                           ← Task 3
UConsole UClass
    ↓ create instance with outer = GameViewport (StaticConstructObject_Internal) ← Task 7
UConsole* (assign to ViewportConsole)
```

## Orchestrator flow (assembled in Task 10)

```
UEngine_enableDeveloperConsole()
│
├─ 0  PREFLIGHT   scanner ready? (GEngine, UObject.Class/Name, NamePool, ObjectArray)
│                  └─ not ready → UEngine_runWhenReady re-queues, return nil,'pending'
│
├─ 1  DETECT      UE4 vs UE5 (FName width), pointersize        ← version gate, Task 1
│
├─ 2  ASSESS      read-only state probe → UEngine.DevConsoleState
│                  viewport / console / consoleClass / consoleKeys / cheatManager
│                  └─ console already active? → return true,'already enabled'  (no writes)
│
├─ 3  REPAIR      for each item in state.needs, in order:
│                  │  a. ConsoleClass null            → find UClass 'Console' → write (Task 4)
│                  │  b. console instance null        → create UConsole(outer=vp) via
│                  │     UEngine_callFunction(StaticConstructObject_Internal) → write (Task 7)
│                  │  c. ConsoleKeys lacks Tilde      → patch FKey KeyName (Task 8)
│                  │  d. (bonus) CheatManager absent  → patch CheatClass + spawn (Task 9)
│                  └─ best-effort: each repair independent, failures recorded
│
└─ 4  VERIFY      re-read all signals
                  ├─ all green → UEngine.DevConsoleEnabled=true, return true,'enabled'
                  └─ some red  → return false,'partial: <remaining needs>'
```

## References

- `docs/SPLIT-PLAN.md` — core chain walking for GEngine, GameViewport
- `research/CE75-REFERENCE.md` — CE 7.5 Lua API reference
- **CE 7.5 source: `LuaHandler.pas`** — remote-call API (`executeCodeEx` registered `:16864`, `executeMethod` `:16865`, `allocateMemory` `:16952`, `writeString` `:16228`, `writeBytes` `:16200`)
- UE source: `Engine/Source/Runtime/Engine/Classes/Engine/Console.h`
- UE source: `Engine/Source/Runtime/Engine/Classes/GameFramework/CheatManager.h`
- UE source: `Engine/Source/Runtime/Engine/Classes/Engine/Engine.h` (`UEngine::ConsoleClass`, `GameViewport`)
- UE source: `Engine/Source/Runtime/Engine/Classes/Engine/GameViewportClient.h` (`ViewportConsole` — the only console field on the viewport)
- UE source: `Engine/Source/Runtime/Engine/Private/UserInterface/Console.cpp` (`GetDefault<UInputSettings>()->ConsoleKeys.Contains(Key)`)
- UE source: `Engine/Source/Runtime/Engine/Private/GameViewportClient.cpp` (`SetupInitialLocalPlayer` → console created only under `#if ALLOW_CONSOLE`/`#if !UE_BUILD_SHIPPING`)
- Shipped-game technique: `StaticFindObject("/Script/Engine.Console")` → `StaticConstructObject_Internal(Class, Viewport)` → `ViewportConsole = obj` → remap `ConsoleKeys` (executed via CE 7.5 `executeCodeEx`/`executeMethod` wrappers from Task 6 — no external tools)
