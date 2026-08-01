# Enabling the Unreal Engine Developer Console — Task Index

Split of the monolithic `research/CE75-DEV-CONSOLE.md` into sequential implementation tasks. Each numbered task (1–10) is a self-contained unit an agent can implement in order. **All console feature code (Tasks 1–10) lives in `Scripts/console/console.lua`** — split out of `UnrealEngine-75.LUA` in Phase 0 of [`SPLITFILE.md`](SPLITFILE.md). Tasks 1–6 are already implemented there; Tasks 7–10 implement into `console.lua`. `UnrealEngine-75.LUA` is touched only for the guarded boot `dofile`, the `UEngine_runConsoleScanHooks(t)` scanner callout, and (Task 10) the `menuContributors` hook.

[`00-BACKGROUND.md`](00-BACKGROUND.md) is **reference material, not a task** — pure knowledge (disable vectors, the five re-enable approaches, the API/struct table, detection snippets, references). It contains no code and nothing to implement; read it first, then start at Task 1.

**Goal feature:** `UEngine_enableDeveloperConsole()` in `Scripts/console/console.lua` — detects how a shipped UE4/UE5 game disabled its console, repairs only what is broken, and surfaces status via a Debug-menu entry.

**Status — PLAN ONLY, NOT IMPLEMENTED ⚠️** (verified 2026-07-31 against `UnrealEngine-75.LUA` 4489 lines, UE4/UE5 engine source, and CE 7.5 source `LuaHandler.pas`):

- ✅ **Self-contained: no UE4SS or other external tool required.** Every engine function that must be *called* (`StaticConstructObject_Internal`, `AddCheats`, `ConsoleCommand`) is invoked through **CE 7.5's built-in remote-call APIs** — `executeCodeEx` (`LuaHandler.pas:16864`), `executeMethod` (`:16865`) and `allocateMemory`/`writeString`/`writeBytes` — verified in source, plus the thin wrappers in Task 06 (Phase 3 Prelude).
- ✅ **Task 1 implemented (2026-07-31):** `UEngine_detectFNameLayout()` → `UEngine.UEFlavour` / `UEngine.FNameSize` (12/UE5, 8/UE4), `UEngine.SCOPositionalSig`, `UEngine.EngineVersion` via `UEngine_detectEngineVersion()` (ProductVersion → module banner fallback); `UObject_getName` now honors `FNameSize` (Number at +4 in BOTH sizes, corrected 2026-08-01 — see Task 11); `UEngine.NameToIndexMin` recorded in `CacheNamePool`; `UEngine.ObjectArrayNumElements` read from `FChunkedFixedUObjectArray` (ObjectArray+0x24, NOT +0x08). Detection wired into `UEInfoScanner` right after `FindGEngine` (before the SuperStruct walk).
- ✅ **Task 2 implemented (2026-07-31):** `UEngine_discoverViewportOffsets()` → `UEngine.GameViewport` (offset on the UGameEngine instance; doc's `UEngine.UGameEngine.GameViewport` key is impossible — `UGameEngine` is the numeric instance pointer) and `UEngine.UGameViewportClient.ViewportConsole`, via `UEngine_getAllProperties` with a UGameEngine-instance memory-scan fallback (isVTable + `GameViewportClient` class name + re-read stability). Wired into `UEInfoScanner` after `findGameInstanceFPropertyAndFields`.
- ✅ **Task 3 implemented (2026-07-31):** `UEngine_findClassByName(name)` (object-array walk, validated as a UClass) with automatic FName-index memscan fallback (`FindGEngine` pattern), plus `UEngine_findObjectByName(name)` (name-only walk, reused for Task 5's CDO gate) and `UEngine_nameTargetIndex(name)` (FNameSize-aware ComparisonIndex — handles lowercased comparison entries on UE5 `WITH_CASE_PRESERVING_NAME`). Wired into `UEInfoScanner` after Task 2: `Console` class cached as `UEngine.ConsoleClassAddr`, CDO presence logged.
- ✅ **Task 4 implemented (2026-07-31):** `UEngine_resolveConsoleClassOffset()` (read-only property walk → `UEngine.ConsoleClass` offset, the Task 2 cache-contract key) and `UEngine_fixConsoleClass(t)` (idempotent REPAIR: writes the `Console` UClass only when `UEngine::ConsoleClass` is null, verifies by re-read; `'already set'` no-op otherwise; `'Console UClass not found; unpatched'` when blocked). Scanner wiring caches the offset + logs the current value; the write itself is deferred to the orchestrator's REPAIR phase (Task 10) per the design principle.
- ✅ **Task 5 implemented (2026-07-31):** `UEngine_assessDeveloperConsole(t)` → `UEngine.DevConsoleState` (7 signals + `needs` + `blocked`) with helpers `UEngine_getObjectFlags` (derived `Class-8` flags offset; `RF_ClassDefaultObject=0x200`), `UEngine_findCDOs` (single-pass multi-name CDO walk), `UEngine_findCDO` / `UEngine_findCDOByClassName`, `UEngine_readConsoleKeys` (first `FKey` `KeyName`), `UEngine_readCheatManager` (LocalPlayer→PC chain). Read-only, runtime probe (not scanner-wired): returns `true,'already enabled'` when console + keys are green, else `false,'needs: …'`.
- ✅ **Task 6 implemented (2026-08-01):** `UEngine_callFunction(fnAddr, argPtr[, timeoutMs])` and `UEngine_callMethod(fnAddr, instance, param1, param2[, timeoutMs])` over CE 7.5 `executeCodeEx` (`LuaHandler.pas:12039`), plus `UEngine.RemoteCallTimeoutMs` (default 5000) and a local `UEngine_remoteCallTimeout` guard that **refuses `0`/`nil`/negative timeouts** (fire-and-forget and infinite both leak CE's stub — DoD "always finite ms"). `UEngine_callMethod` always delegates to `executeCodeEx` (never `executeMethod` — register collision verified `:11736` vs `:11836`), so x64 thiscall is exact: RCX=instance, RDX=param1, R8=param2. Both wrapped in `pcall`; `RAX=0` → `nil` (unpatched need), CE failure → `nil,errormsg`, raised error → `nil,'…raised:…'`. `luac -p` + `loadfile` pass; wrapper logic unit-tested with a mocked `executeCodeEx`; pending a live target for the DoD RAX round-trip check.
- ✅ **Task 7 implemented (2026-08-01):** `UEngine_createConsole()` — the crux — plus `UEngine_locateStaticConstructObject()` (Path A version-pinned `UEngine.SCOPatterns` AOB → Path B `StaticAllocateObject` xref), `UEngine_locateStaticAllocateObject()` (`UEngine.SAOPatterns` → Dissect-Code string xref), `UEngine_validateSCO(candidate, saoAddr)` (the §4 checklist: MSVC prologue, direct `call` to SAO, decisive stack-local `lea/mov rcx,[rsp|rbp+disp]` with `modrmValueType==2` within 6 instrs before the call), `UEngine_findFunctionStart` (backward MSVC-padding walk, `readBytes(...,true)`), `UEngine_mainModuleName` (`enumModules()[1].PathToFile`, `process` fallback) and guarded `UEngine_free` (never on the timeout/nil path). Struct offsets derived from `UEngine.FNameSize`; hard gate on `UEngine.DevConsoleState.consoleCDO`; creates with outer=viewport, validates class name `Console` before the only `ViewportConsole` write; caches `UEngine.SCOAddr` (0 re-scans). Patterns tables are filled at CE attach, never fabricated. `luac -p` passes; pending a live target for the DoD checks (Appendix A in the doc).
- ❌ **No `UEngine_enableDeveloperConsole()` function exists** (console symbols in the core script are Tasks 3/4/5/6/7 scaffolding — `UEngine_findClassByName('Console')`, `UEngine.ConsoleClassAddr`, `UEngine_fixConsoleClass`, `UEngine_assessDeveloperConsole`, `UEngine_callFunction`, `UEngine_callMethod`, `UEngine_locateStaticConstructObject`, `UEngine_createConsole` — no enable/orchestrator).
- ❌ **No `UEngine.DevConsoleEnabled` flag, no menu item.** `UEngine.GUI.miDebug` exists and is the right home for the menu entry, but nothing has been added. (Task 5 already caches `UEngine.DevConsoleState`; Task 10 turns that into the `DevConsoleEnabled` flag.)

---

## Task list (implementation order)

> **Note (2026-08-01):** Tasks 01–07 are **archived** (`archive/`) — their implementations are in the tree and their content is superseded. The live task set is **08–11**. **[11-TASK-DUAL-VERSION-CORRECTIONS.md](11-TASK-DUAL-VERSION-CORRECTIONS.md)** is the dual-version (UE4.x + UE5.x) source audit; it corrects FName layout (Number @+4 both sizes, DisplayIndex @+8 editor-only), SCO `templateOff` (0x28 both sizes — two bools exist), FKey type (`TSharedPtr`, not TArray), and `RF_ClassDefaultObject` (`0x10`, not `0x200`), with the exact code locations to change. Tasks 08/09/10 carry inline correction notes pointing back to it.

| # | File | Deliverable | Depends on | Status |
|---|------|-------------|------------|--------|
| 1 | [`archive/01-TASK-PHASE1-DETECT.md`](archive/01-TASK-PHASE1-DETECT.md) | `UEngine_detectFNameLayout()` → `UEngine.UEFlavour`, `UEngine.FNameSize`, `UEngine.EngineVersion`, `UEngine.SCOPositionalSig` + `UObject_getName` FNameSize fix + `NameToIndexMin` + `ObjectArrayNumElements` caches | — | implemented (corrected in 11) |
| 2 | [`archive/02-TASK-OFFSET-DISCOVERY.md`](archive/02-TASK-OFFSET-DISCOVERY.md) | Steps A+B: `GameViewport` and `ViewportConsole` offsets cached | — | implemented (verified in 11) |
| 3 | [`archive/03-TASK-FIND-CONSOLE-CLASS.md`](archive/03-TASK-FIND-CONSOLE-CLASS.md) | Step E: `UEngine_findClassByName(name)` → Console UClass | 1, 2 (offset pattern) | implemented |
| 4 | [`archive/04-TASK-CONSOLE-CLASS-FIX.md`](archive/04-TASK-CONSOLE-CLASS-FIX.md) | Step C: fix `UEngine::ConsoleClass` (needed before instance creation) | 3 | implemented |
| 5 | [`archive/05-TASK-ASSESSMENT.md`](archive/05-TASK-ASSESSMENT.md) | Phase 2: read-only state probe → `UEngine.DevConsoleState` + `needs` list (+ `consoleCDO` / `cheatCDO` hard-gate signals) | 1, 2, 4 | implemented (flag corrected in 11) |
| 6 | [`archive/06-TASK-REMOTE-CALL-PRELUDE.md`](archive/06-TASK-REMOTE-CALL-PRELUDE.md) | `UEngine_callFunction` / `UEngine_callMethod` wrappers over `executeCodeEx`/`executeMethod` | — | implemented |
| 7 | [`archive/07-TASK-CREATE-CONSOLE.md`](archive/07-TASK-CREATE-CONSOLE.md) | Step D (crux): construct `UConsole` with outer=GameViewport via `StaticConstructObject_Internal` | 2, 3, 4, 5, 6 | implemented (templateOff corrected in 11) |
| 8 | [`08-TASK-CONSOLE-KEYS.md`](08-TASK-CONSOLE-KEYS.md) | Step F: patch `UInputSettings` CDO `ConsoleKeys` first FKey `KeyName` to `Tilde` | 1 | corrected (11) |
| 9 | [`09-TASK-CHEATMANAGER.md`](09-TASK-CHEATMANAGER.md) | Step G (bonus): patch `CheatClass` + spawn `CheatManager` via Task 7 `SCO` replication (`cheatCDO`-gated) | 3, 5, 6, 7 | corrected (11) |
| 10 | [`10-TASK-ORCHESTRATOR.md`](10-TASK-ORCHESTRATOR.md) | `UEngine_enableDeveloperConsole()` orchestrator + Phase 4 verify + menu + state tracking | 1–9 | implemented (2026-08-01) |
| 11 | [`11-TASK-DUAL-VERSION-CORRECTIONS.md`](11-TASK-DUAL-VERSION-CORRECTIONS.md) | Dual-version source audit + code-change manifest | 08–10 | applied (all §7 fixes verified; runtime-verify open items §8) |

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
  T5 (cheatCDO signal) ───────────────► T9  (hard gate: never run the NewObject/AddCheats replication without the CDO)
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
| `CheatManager` absent | `PC.CheatClass` / `PC.CheatManager` null (+ `cheatCDO` gate: `Default__CheatManager` must exist) | patch `CheatClass` + spawn `CheatManager` (Task 9, Task 7 `SCO` replication) | cheat commands needed |
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

| Task | File | Location | Status |
|------|------|----------|--------|
| 1 | `01-TASK-PHASE1-DETECT.md` | `Scripts/console/console.lua` (scanner wiring in core `UnrealEngine-75.LUA:2228`–`:2235`) | ✅ |
| 2 | `02-TASK-OFFSET-DISCOVERY.md` | `Scripts/console/console.lua` (wired via `UEngine_runConsoleScanHooks`, core `:2407`) | ✅ |
| 3 | `03-TASK-FIND-CONSOLE-CLASS.md` | `Scripts/console/console.lua` (same hook) | ✅ |
| 4 | `04-TASK-CONSOLE-CLASS-FIX.md` | `Scripts/console/console.lua` (same hook) | ✅ |
| 5 | `05-TASK-ASSESSMENT.md` | `Scripts/console/console.lua` | ✅ |
| 6 | `06-TASK-REMOTE-CALL-PRELUDE.md` | `Scripts/console/console.lua` | ✅ |
| 7 | `07-TASK-CREATE-CONSOLE.md` | `Scripts/console/console.lua` (`UEngine_createConsole` + `UEngine_locateStaticConstructObject` + §4 `UEngine_validateSCO`) | ✅ (impl. 2026-08-01; CE-verification pending) |
| 8 | `08-TASK-CONSOLE-KEYS.md` | `Scripts/console/console.lua` (`UEngine_patchConsoleKeys`) | ✅ (impl. 2026-08-01; CE-verification pending) |
| 9 | `09-TASK-CHEATMANAGER.md` | `Scripts/console/console.lua` (`UEngine_setupCheatManager`) | ✅ (impl. 2026-08-01; CE-verification pending) |
| 10 | `10-TASK-ORCHESTRATOR.md` | `Scripts/console/console.lua` (`UEngine_enableDeveloperConsole`; core `menuContributors` hook §5.5) | ✅ (impl. 2026-08-01; CE-verification pending) |

## Edge cases (apply to all tasks)

| Case | Handling |
|------|----------|
| GameEngine struct not scanned yet | `UEngine_ensureGameEngineStructure()` first (`UnrealEngine-75.LUA:2693`) |
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
- **`research/CE-FUNCTIONS.md` — verified Lua↔Pascal API map (every function with its source line): AOB scans, disassembler `getLastDisassembleData`, Dissect Code `getReferences`, RIP scanner, `executeCodeEx`/`executeMethod`**
- **CE 7.5 source: `LuaHandler.pas`** — remote-call API verified at `executeCodeEx` (registered `LuaHandler.pas:16864`, impl `:12039`), `executeMethod` (`:16865`), `executeCode` (`:16863`), `allocateMemory` (`:16952`, impl `:14285`), `writeString` (`:16228`), `writeBytes` (`:16200`)
- UE source (path-pinned, not URL-pinned until 2026-08-01 — see below): `Engine/Source/Runtime/Engine/Classes/Engine/Console.h`
- UE source: `Engine/Source/Runtime/Engine/Classes/GameFramework/CheatManager.h`
- UE source: `Engine/Source/Runtime/Engine/Classes/Engine/Engine.h` (`UEngine::ConsoleClass`, `GameViewport`)
- UE source: `Engine/Source/Runtime/Engine/Classes/Engine/GameViewportClient.h` (`ViewportConsole` — the only console field on the viewport)
- UE source: `Engine/Source/Runtime/Engine/Private/UserInterface/Console.cpp` (`GetDefault<UInputSettings>()->ConsoleKeys.Contains(Key)`)
- UE source: `Engine/Source/Runtime/Engine/Private/GameViewportClient.cpp` (`SetupInitialLocalPlayer` → console created only under `#if ALLOW_CONSOLE`/`#if !UE_BUILD_SHIPPING`)
- UE source online mirror (UE4-era `release` branch; the original research read UE source online but left no URLs — restored 2026-08-01): `https://github.com/folgerwang/UnrealEngine/blob/release/Engine/Source/...` (raw: `https://raw.githubusercontent.com/folgerwang/UnrealEngine/release/...`). Verified anchors in [`09-TASK-CHEATMANAGER.md`](09-TASK-CHEATMANAGER.md) §References.
- Epic API docs (UE5.7/5.8, function-level facts): `https://dev.epicgames.com/documentation/unreal-engine/API/Runtime/Engine/UCheatManager` and `.../API/Runtime/Engine/AController`
- Shipped-game technique (engine C++ function names to locate, executed via the CE 7.5 `executeCodeEx`/`executeMethod` wrappers from Task 6 — no external tools): `StaticFindObject("/Script/Engine.Console")` → `StaticConstructObject_Internal(Class, Viewport)` → `ViewportConsole = obj` → remap `ConsoleKeys`
