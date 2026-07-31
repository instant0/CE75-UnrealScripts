# Enabling the Unreal Engine Developer Console — Task Index

Split of the monolithic `research/CE75-DEV-CONSOLE.md` into sequential implementation tasks. Each numbered task (1–10) is a self-contained unit an agent can implement in `UnrealEngine-75.LUA` in order.

[`00-BACKGROUND.md`](00-BACKGROUND.md) is **reference material, not a task** — pure knowledge (disable vectors, the five re-enable approaches, the API/struct table, detection snippets, references). It contains no code and nothing to implement; read it first, then start at Task 1.

**Goal feature:** `UEngine_enableDeveloperConsole()` in the core script — detects how a shipped UE4/UE5 game disabled its console, repairs only what is broken, and surfaces status via a Debug-menu entry.

**Status — PLAN ONLY, NOT IMPLEMENTED ⚠️** (verified 2026-07-31 against `UnrealEngine-75.LUA` 4489 lines, UE4/UE5 engine source, and CE 7.5 source `LuaHandler.pas`):

- ✅ **Self-contained: no UE4SS or other external tool required.** Every engine function that must be *called* (`StaticConstructObject_Internal`, `SpawnCheatManager`, `ConsoleCommand`) is invoked through **CE 7.5's built-in remote-call APIs** — `executeCodeEx` (`LuaHandler.pas:16864`), `executeMethod` (`:16865`) and `allocateMemory`/`writeString`/`writeBytes` — verified in source, plus the thin wrappers in Task 06 (Phase 3 Prelude).
- ❌ **No `UEngine_enableDeveloperConsole()` function exists** (grepped — zero console/CheatManager hits in the core script).
- ❌ **No `UEngine.UGameViewportClient` cache, no `UEngine.DevConsoleEnabled` state, no menu item.** `UEngine.GUI.miDebug` exists and is the right home for the menu entry, but nothing has been added.

---

## Task list (implementation order)

| # | File | Deliverable | Depends on |
|---|------|-------------|------------|
| 1 | [`01-TASK-PHASE1-DETECT.md`](01-TASK-PHASE1-DETECT.md) | `UEngine_detectFNameLayout()` → `UEngine.UEFlavour`, `UEngine.FNameSize`, `UEngine.EngineVersion`, `UEngine.SCOPositionalSig` + `UObject_getName` FNameSize fix + `NameToIndexMin` + `ObjectArrayNumElements` caches | — |
| 2 | [`02-TASK-OFFSET-DISCOVERY.md`](02-TASK-OFFSET-DISCOVERY.md) | Steps A+B: `GameViewport` and `ViewportConsole` offsets cached | — |
| 3 | [`03-TASK-FIND-CONSOLE-CLASS.md`](03-TASK-FIND-CONSOLE-CLASS.md) | Step E: `UEngine_findClassByName(name)` → Console UClass | 1, 2 (offset pattern) |
| 4 | [`04-TASK-CONSOLE-CLASS-FIX.md`](04-TASK-CONSOLE-CLASS-FIX.md) | Step C: fix `UEngine::ConsoleClass` (needed before instance creation) | 3 |
| 5 | [`05-TASK-ASSESSMENT.md`](05-TASK-ASSESSMENT.md) | Phase 2: read-only state probe → `UEngine.DevConsoleState` + `needs` list (+ `consoleCDO` / `cheatCDO` hard-gate signals) | 1, 2, 4 |
| 6 | [`06-TASK-REMOTE-CALL-PRELUDE.md`](06-TASK-REMOTE-CALL-PRELUDE.md) | `UEngine_callFunction` / `UEngine_callMethod` wrappers over `executeCodeEx`/`executeMethod` | — |
| 7 | [`07-TASK-CREATE-CONSOLE.md`](07-TASK-CREATE-CONSOLE.md) | Step D (crux): construct `UConsole` with outer=GameViewport via `StaticConstructObject_Internal` | 2, 3, 4, 5, 6 |
| 8 | [`08-TASK-CONSOLE-KEYS.md`](08-TASK-CONSOLE-KEYS.md) | Step F: patch `UInputSettings` CDO `ConsoleKeys` first FKey `KeyName` to `Tilde` | 1 |
| 9 | [`09-TASK-CHEATMANAGER.md`](09-TASK-CHEATMANAGER.md) | Step G (bonus): patch `CheatClass` + `SpawnCheatManager()` via `UEngine_callMethod` (vtable-resolved, `cheatCDO`-gated) | 3, 5, 6 |
| 10 | [`10-TASK-ORCHESTRATOR.md`](10-TASK-ORCHESTRATOR.md) | `UEngine_enableDeveloperConsole()` orchestrator + Phase 4 verify + menu + state tracking | 1–9 |

## Dependency graph

```
00-BACKGROUND  (read this first — no code)
      │
      ├──────────────┐
      ▼              ▼
 T1 detect    T2 offsets ──────────► T5 assess
 (Phase 1)    │                      ▲
      │       ▼                      │
      │  T3 findClass ──► T4 ConsoleClass fix ─┘
      │                                 │
      ▼                                 ▼
 T6 prelude ──────────────────────► T7 create console (Step D)
       │
       ▼
  T8 keys (needs T1) ───────────────► T10 orchestrator + Phase 4 + menu
       │                                  ▲
       ▼                                  │
  T9 CheatManager (needs T3, T6) ─────────┘

Cross-task additions after review:
  T1 (UObject_getName fix) ───────────► T5  (name-based CDO/key detection needs it)
  T1 (NameToIndexMin) ────────────────► T3, T5, T8  (lowest name index = comparison-table entry)
  T1 (ObjectArrayNumElements) ────────► T3  (object-array walk count; `ObjectArray+0x08` is a GC max, not the count)
  T1 (EngineVersion) ─────────────────► T7  (key for the version-pinned SCO AOB table)
  T5 (consoleCDO signal) ─────────────► T7  (hard gate: never call SCO without the CDO)
  T5 (cheatCDO signal) ───────────────► T9  (hard gate: never call SpawnCheatManager without the CDO)
```

## Design principle — Detect → Assess → Repair → Verify

The console is disabled through **independent vectors**; a game may have *any subset* of them, so a single fixed patch sequence is wrong. The feature must:

1. **Detect** engine layout (UE4 vs UE5, pointer size) so every later read/write uses the right structure sizes.
2. **Assess** (read-only) every console-related signal and build a `needs` list — **no writes yet**.
3. **Repair** only the items on the `needs` list, in dependency order (class before instance before keys).
4. **Verify** by re-reading state, then report what was patched vs. what remains blocked.

This makes the feature **idempotent**: running it on an already-enabled console just reports "already active".

### Requirement matrix

| Disable vector | Detection signal (Task 5) | Repair (Tasks 2–9) | Runs when |
|---|---|---|---|
| Console never created (Shipping compile-out) | `readPointer(vp + ViewportConsole.off) == 0` (+ `consoleCDO` gate: `Default__Console` must exist) | construct `UConsole` with outer = viewport (Task 7) | shipping/test builds |
| `UEngine::ConsoleClass` set to null | `readPointer(ge + ConsoleClass.off) == 0` | find `Console` UClass, write it (Task 4) | config-patched games |
| Toggle keys removed (`ConsoleKeys` empty/wrong) | `UInputSettings` CDO `ConsoleKeys` lacks `Tilde` | patch first FKey `KeyName` (Task 8) | INI-patched games |
| Key-check recompiled / array unfixable | key never toggles despite fix | AOB-patch `ConsoleKeys.Contains` check (Approach #2, background) | hard-blocked games |
| `CheatManager` absent | `PC.CheatClass` / `PC.CheatManager` null (+ `cheatCDO` gate: `Default__CheatManager` must exist) | patch `CheatClass` + `SpawnCheatManager()` via `UEngine_callMethod` (Task 9) | cheat commands needed |
| Already enabled | all signals green | no-op | — |

### Chain of discovery (state cached across tasks)

```
UEngine.UGameEngine  (GEngine pointer, already cached)
    ↓ readPointer(ge + UObject.Class)
UGameEngine UClass
    ↓ property walk → find "GameViewport" (ObjectProperty, offset)     ← Task 2
UEngine.UGameEngine.GameViewport            ← viewport client pointer
    ↓ property walk on viewport class → find "ViewportConsole" (ObjectProperty)   ← Task 2
UEngine.UGameViewportClient.ViewportConsole ← the console instance (may be null in Shipping)
    ↓ property walk on GameEngine class → find "ConsoleClass" (ClassProperty)     ← Task 4
UEngine.UGameEngine.ConsoleClass            ← the class to spawn (may be null)
    ↓ find UClass named "Console" in the UObjectArray                             ← Task 3
UConsole UClass                             (uses UEngine.ObjectArrayNumElements + NameToIndexMin)
    ↓ create instance with outer = GameViewport (StaticConstructObject_Internal)  ← Task 7
UConsole* (assign to ViewportConsole)
```

### Orchestrator flow (assembled in Task 10)

```
UEngine_enableDeveloperConsole()
│
├─ 0  PREFLIGHT   scanner ready? (GEngine, UObject.Class/Name, NamePool, ObjectArray)
│                  └─ not ready → UEngine_runWhenReady re-queues, return nil,'pending'
│
├─ 1  DETECT      UE4 vs UE5 (FName width), pointersize        ← version gate, Task 1
│
├─ 2  ASSESS      read-only state probe → UEngine.DevConsoleState
│                  viewport / console / consoleClass / consoleCDO / consoleKeys / cheatManager
│                  └─ console already active? → return true,'already enabled'  (no writes)
│
├─ 3  REPAIR      for each item in state.needs, in order:
│                  │  a. ConsoleClass null            → find UClass 'Console' → write (Task 4)
│                  │  b. console instance null        → create UConsole(outer=vp) via
│                  │     UEngine_callFunction(StaticConstructObject_Internal) → write (Task 7)
│                  │     └─ blocked unless state.consoleCDO is present (hard gate)
│                  │  c. ConsoleKeys lacks Tilde      → patch FKey KeyName (Task 8)
│                  │  d. (bonus) CheatManager absent  → patch CheatClass + spawn (Task 9)
│                  │     └─ spawn blocked unless state.cheatCDO is present (hard gate)
│                  └─ best-effort: each repair independent, failures recorded
│
└─ 4  VERIFY      re-read all signals
                  ├─ all green → UEngine.DevConsoleEnabled=true, return true,'enabled'
                  └─ some red  → return false,'partial: <remaining needs>'
```

## Status board

| Task | File | Status |
|------|------|--------|
| 1 | `01-TASK-PHASE1-DETECT.md` | ⬜ |
| 2 | `02-TASK-OFFSET-DISCOVERY.md` | ⬜ |
| 3 | `03-TASK-FIND-CONSOLE-CLASS.md` | ⬜ |
| 4 | `04-TASK-CONSOLE-CLASS-FIX.md` | ⬜ |
| 5 | `05-TASK-ASSESSMENT.md` | ⬜ |
| 6 | `06-TASK-REMOTE-CALL-PRELUDE.md` | ⬜ |
| 7 | `07-TASK-CREATE-CONSOLE.md` | ⬜ |
| 8 | `08-TASK-CONSOLE-KEYS.md` | ⬜ |
| 9 | `09-TASK-CHEATMANAGER.md` | ⬜ |
| 10 | `10-TASK-ORCHESTRATOR.md` | ⬜ |

## Edge cases (apply to all tasks)

| Case | Handling |
|------|----------|
| GameEngine struct not scanned yet | `UEngine_ensureGameEngineStructure()` first (`UnrealEngine-75.LUA:2622`) |
| GameViewport offset unknown | Walk properties of GameEngine class at runtime |
| Console class name mismatch | Search for any UClass containing "Console" |
| **Shipping/Test build (`#if ALLOW_CONSOLE`=0)** | **Console creation is compiled out — must construct `UConsole` manually (Task 7). Pressing ~ alone never creates it.** |
| UObjectArray not scanned | Return `nil, 'ObjectArray not found'` |
| No PlayerController | Console works without PC for `r.Fog` commands, CheatManager is separate |
| UE4 vs UE5 TObjectPtr | `TObjectPtr` wraps pointer at same offset for property access (raw pointer readable at offset). Applies to `GameViewport`, `ViewportConsole` |
| **FName layout UE4 vs UE5** | **UE5 has `DisplayIndex` between ComparisonIndex and Number — write all three fields** |
| `UInputSettings::ConsoleKeys` empty | AOB-patch the `Contains` check or use programmatic activation (Task 8) |
| **Wrong `Outer` on created console** | **`UConsole::ConsoleCommand` dereferences `GetOuterUGameViewportClient()` — outer MUST be the `UGameViewportClient` or the game crashes on Enter** |
| **Remote call runs on foreign thread** | **CE-injected thread, not game thread — `check(IsInGameThread())` paths crash. Only call functions whose CDOs already exist; run at a quiet moment** |
| **`executeCodeEx` timeout** | **`timeout=0` is fire-and-forget with no return value and leaks CE's stub — always pass a finite ms timeout (e.g. 5000)** |
| Manual console + logs | `GLog->AddOutputDevice` was not re-run; engine log lines won't show in the console |

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
