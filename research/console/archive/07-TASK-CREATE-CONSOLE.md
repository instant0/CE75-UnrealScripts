# Task 7 — Step D: Create the `UConsole` instance — [fixed — this is the crux]

> **CORRECTED (2026-08-01) — see [11-TASK-DUAL-VERSION-CORRECTIONS.md](../11-TASK-DUAL-VERSION-CORRECTIONS.md) §2/§7d/§9.** The SCO params struct claims in this archived doc are WRONG and superseded: `FStaticConstructObjectParameters` (UE5.4, `UObjectGlobals.h:1594-1640`) has TWO bools (`bCopyTransientsFromClassDefaults`, `bAssumeTemplateIsArchetype`) between `InternalSetFlags` and `Template`, so **`Template = align8(internalOff+6) = 0x28 for BOTH FName sizes`** (the old `align8(internalOff+4)` = 0x20 was wrong for FName=8). The fake fields `bAllowNativeClassCreation` and "InitializationOptions" DO NOT EXIST — delete them (real trailing fields: InstanceGraph, ExternalPackage, PropertyInitCallback, SubobjectOverrides). The implemented code (`console.lua:1257`) already reflects this. UE4.26/4.27 bool presence remains a runtime-verify open item (§8).

**Goal:** Construct a `UConsole` with `GameViewport` as its **outer** and assign it to `ViewportConsole`. Runs only when the `console` signal read by Task 5 is null.

**Depends on:** Task 1 (FName size + `UEngine.EngineVersion`), Task 2 (GameViewport/ViewportConsole offsets), Task 3 (Console UClass → `UEngine.ConsoleClassAddr`), Task 4 (ConsoleClass set), Task 5 (`UEngine.DevConsoleState.consoleCDO` hard gate + `UEngine.DevConsoleState.viewport`), Task 6 (`UEngine_callFunction`, `console.lua:888`).
**Fallback:** approach #5 (`PlayerController->ConsoleCommand()`, background doc) when this is infeasible.

> **Implementation target (per [`SPLITFILE.md`](SPLITFILE.md) §6):** implement `UEngine_createConsole()` in **`Scripts/console/console.lua`**. No `UnrealEngine-75.LUA` edit is needed for this task (the core only holds the guarded scanner callout that Tasks 2–4 use).

---

The original plan's **Option C ("the console should auto-create on first `~` press") is FALSE for UE4/UE5**: `UGameViewportClient::InputKey` routes keys to `ViewportConsole` only if it already exists (`ViewportConsole ? ViewportConsole->InputKey(...) : false`) and never creates it. In Shipping/Test builds the creation code in `SetupInitialLocalPlayer` was **compiled out** (`#if ALLOW_CONSOLE`/`#if !UE_BUILD_SHIPPING`), so it will never appear on its own.

The proven approach on shipped games is to construct a `UConsole` with `GameViewport` as its **outer** and assign it to `ViewportConsole`:

```lua
-- UEngine_createConsole() -> consoleAddr, nil | nil, err
--   Called by the Task 10 orchestrator ONLY when UEngine.DevConsoleState.needs
--   contains 'console' AND it is not blocked. Mirrors SetupInitialLocalPlayer:
--   StaticConstructObject_Internal(UConsole::StaticClass(), viewport, NAME_None, ...).

-- 0) Hard gate first: never call SCO without the Console CDO present.
--    (A null Template makes ConstructObject resolve Class->GetDefaultObject(); if
--     that CDO does not exist it is CREATED on the injected thread ->
--     check(IsInGameThread()) crash. Task 5 verified Default__Console exists.)
local state = UEngine.DevConsoleState
if not (state and state.consoleCDO) then
  return nil, 'blocked: no Default__Console CDO (foreign-thread GetDefaultObject() risk)'
end

-- 1) Inputs (Task 2/3/5 caches).
local vp      = state.viewport                       -- UGameViewportClient* (Task 5 probe)
local consoleClass = UEngine.ConsoleClassAddr       -- UClass* Console (Task 3)
if not vp or not consoleClass then return nil, 'blocked: no viewport/console class' end

-- 2) SCO address (cached; located per the section below).
local scoAddr = UEngine.SCOAddr
if not scoAddr then
  return nil, 'blocked: StaticConstructObject_Internal not located/validated (Task 7 locate step)'
end

-- 3) Allocate + fill the params struct. Offsets depend on Task 1's measured
--    FNameSize (8 for UE4 and UE5-without-CasePreservingName, 12 for UE5 WITH
--    case-preserving names) — do NOT hard-code 8 or 12 by family.
--    Layout (UObjectGlobals.h FStaticConstructObjectParameters):
--      0x00 Class(ptr) 0x08 Outer(ptr) 0x10 FName {SetFlags;InternalSetFlags} Template(ptr)
--      Template offset shifts ONLY with FName width. Trailing fields (InstanceGraph,
--      UE5.0+ bAllowNativeClassCreation/ExternalPackage, UE5.1+ InitializationOptions)
--      are left 0 — see "Trailing struct fields" under Notes.
local fnameSize   = UEngine.FNameSize
local setFlagsOff = 0x10 + fnameSize                -- 0x18 (FName=8) / 0x1C (FName=12)
local internalOff = setFlagsOff + 4
local templateOff = (internalOff + 4 + 7) // 8 * 8  -- 0x20 / 0x28

local params = allocateMemory(0x60)  -- zero-filled fresh page (VirtualAllocEx); never reuse a buffer
writePointer (params + 0x00, consoleClass)          -- Class  = UConsole UClass (Task 3)
writePointer (params + 0x08, vp)                    -- Outer  = GameViewport (MUST be the viewport)
writeInteger(params + 0x10, 0)                      -- FName ComparisonIndex = NAME_None (0)
writeInteger(params + 0x14, 0)                      -- FName Number (UE4) / DisplayIndex (UE5)
if fnameSize == 12 then writeInteger(params + 0x18, 0) end  -- FName Number (UE5 only)
writeInteger(params + setFlagsOff, 0)               -- SetFlags = RF_NoFlags
writeInteger(params + internalOff, 0)               -- InternalSetFlags = None
writePointer (params + templateOff, 0)              -- Template = nil (CDO gate makes this safe)

-- 4) Call it. UEngine_callFunction puts argPtr in RCX = the one arg (params ref);
--    RAX = the new UConsole*. CE returns nil for RAX==0 OR call failure.
local consoleObject, callErr = UEngine_callFunction(scoAddr, params)
if not consoleObject then
  return nil, 'unpatched: SCO call failed/nil return'..(callErr and (': '..callErr) or '')
end

-- 5) Validate BEFORE any write: class name must be "Console". The outer is set by
--    SCO from Params.Outer during construction, so passing vp here structurally
--    guarantees Outer == GameViewport; the remaining real risk is a wrong vp, which
--    Task 2/5 already validated as a UGameViewportClient. (There is no cached
--    UObject.Outer offset to re-check; the class-name check + correct vp is the gate.)
local clsAddr = readPointer(consoleObject + UEngine.UObject.Class)
local clsName = UObject_getName(clsAddr)
if clsName ~= 'Console' then return nil, 'unpatched: created object class is '..tostring(clsName) end

-- 6) Only now assign.
writePointer(vp + UEngine.UGameViewportClient.ViewportConsole, consoleObject)
UEngine.SCOAddr = UEngine.SCOAddr or scoAddr  -- persist across runs (0 AOBs on 2nd run)
return consoleObject, nil
```

---

## Locating `StaticConstructObject_Internal`

This is the riskiest part of the whole feature — do not treat it as a one-liner. `StaticConstructObject_Internal` is a **non-exported** engine function whose body varies by engine version; a single pattern will not hold across UE4.26–UE5.x. Work through the steps below **in order**, and never proceed with an unvalidated address.

### 0. Which module to scan

Shipping UE4/UE5 statically links the engine into the game's main executable — there is no separate `Core.dll`/`CoreUObject.dll`. Scan the game's own module:
- Get the module list with `enumModules()` (already used by `UEngine_detectEngineVersion`, `console.lua:176`). The first entry is normally the main exe.
- Use `AOBScanModuleUnique(moduleName, pattern, ...)` to scope the scan to that module (`simpleaobscanner.pas:136`). If module-scoped lookup fails, fall back to process-wide `AOBScanUnique` / `AOBScan`.
- **Cache results** (`UEngine.SCOAddr`, `UEngine.SAOPatterns`): the SCANNING-GUIDE hard rule is ≤3 scans per run and 0 on repeat runs.

### 1. CE 7.5 API this task uses (all verified against CE 7.5 source)

Source tree: `/mnt/y/Lazarus/Projects/cheat-engine-7.5/Cheat Engine/`.

| API | What it gives you | Source ref | Gotcha |
|---|---|---|---|
| `AOBScanModuleUnique(module, pattern[, prot[, alignType[, alignParam]]])` | Single integer address (or `nil`) of the 1st pattern hit in a module | `LuaHandler.pas:4291` → `simpleaobscanner.pas:136` | **Synchronous** — internally `firstscan` + `waittillreallydone` (`simpleaobscanner.pas:58-59`) → blocks the UI thread. Run in the scanner/worker-thread model, cap count. Default prot `'*X*W*C'`. |
| `AOBScanUnique(pattern, ...)` | Same, process-wide | `LuaHandler.pas:4346` (= module `''`) | Same blocking caveat |
| `AOBScan(pattern[, prot[, alignType[, alignParam]]])` | `StringList` object of ALL hits (`fl.Count`, `fl[i]`), or `nil` | `LuaHandler.pas:4364`; pattern build-up `:4402-4416` | `fl[i]` are hex strings (no `0x`). Not FoundList, not `.Address` (CE75-REFERENCE §15). |
| Pattern syntax | Hex bytes space-separated; `*` (or `??`) = wildcard | `LuaHandler.pas:4406` | Same `vtByteArray` semantics as SCANNING-GUIDE §7 |
| `createDisassembler()` → `d` | `d:disassemble(addr)` → string; `d:getLastDisassembleData()` → table | `LuaDisassembler.pas:225/19/210` | `bytes` is a **1-indexed** int array → `#ldd.bytes` = instruction length (advance the cursor by it). |
| `LastDisassembleData` fields | `address, opcode, parameters, description, bytes[], modrmValueType, modrmValue, parameterValueType, parameterValue, isJump, isCall, isRet, isRep, isConditionalJump` | `LastDisassembleData.pas:16-55`, `TDisAssemblerValueType` `:11` | `dvtNone=0`, `dvtAddress=1`, `dvtValue=2` |
| Direct `call rel32` | `isCall=true`, `parameterValueType=dvtAddress`, **`parameterValue = resolved absolute target`** | `disassembler.pas:15009-15030` | **This is the xref-walk key** — filter `isCall and parameterValue == SAO`. |
| `[rip+disp]` operand (e.g. `lea rcx,[rip+X]`) | `modrmValueType=dvtAddress`, **`modrmValue = the RAW disp32, NOT the resolved target`** | `disassembler.pas:864-867` | Resolve yourself: `target = instrAddr + #bytes + signext32(modrmValue)`. The disp-field byte offset is `riprelative` — **not exposed** in the Lua table. |
| `[reg+disp8]` operand (e.g. `lea rcx,[rbp-8]`) | `modrmValueType=dvtValue`, `modrmValue = sign-extended disp8` | `disassembler.pas:902-903` | For stack-locals this is a small int — matches the params-struct convention check below. |
| `getDissectCode()` → `dc`; `dc:dissect(module)`; `dc:getReferences(addr)` | Full-module call graph; `{ [call_site] = jumptype }` for everything that jumps/calls `addr` (`jtCall=0, jtUnconditional=1, jtConditional=2, jtMemory=3`) | `LuaDissectCode.pas:22/31/144`; `DissectCodeThread.pas:32` | Heavy analysis but thread-based (`dowork`+`waitTillDone`). `saveToFile`/`loadFromFile` cache it. |
| `createRipRelativeScanner(mod[, includeLongJumps])`; `.Address[i]`, `.Count` | **Address of the disp32 field** of each RIP-relative instruction in the module (NOT the instruction start, NOT the target) | `LuaRIPRelativeScanner.pas:16`; `RipRelativeScanner.pas:107` + `disassembler.pas:867` | Of limited use here (params struct is a stack local, not a global). Do not treat `.Address[i]` as an instruction address or as the reference target. |

Cross-refs: **`CE-FUNCTIONS.md`** (canonical verified API reference — every function + Pascal source line cited here) · SCANNING-GUIDE §7 (canonical `createMemScan`/`firstScan`/`waitTillDone` helper), §8 (threading + scan caps) · CE75-REFERENCE §15 (`AOBScan` result semantics).

### 2. Locate path A — version-pinned AOB table (primary)

Maintain a table keyed on **`UEngine.EngineVersion`** (the full string cached by Task 1's `UEngine_detectEngineVersion`, `console.lua:172`) — **not** on the coarse UE4/UE5 flavour: `couldBeUnrealEngine` only separates the two families (`ProductVersion:find('%%+UE4'/'%%+UE5')`, UnrealEngine-75.LUA:2464) and cannot distinguish UE5.0 from UE5.5, which have different SCO bodies.

```lua
UEngine.SCOPatterns = UEngine.SCOPatterns or {
  -- Schema: [fullEngineVersion] = { pattern, module, structFNameSize, source, verified }
  --   structFNameSize is only a cross-check against Task 1's measurement, not a key.
  --   verified = date the pattern was confirmed against a live target (CE attach).
  -- ENTRIES ARE FILLED AT CE ATTACH — see "Data required at CE attach" below.
  -- ['5.3.2'] = { pattern='48 89 5C 24 ?? ...', source='<where obtained>', verified='2026-08-??' },
}
```

Lookup: `local e = UEngine.SCOPatterns[UEngine.EngineVersion]`, then `AOBScanModuleUnique(e.module or <main exe>, e.pattern)`. Validate any hit with the checklist in §4 **before** caching it as `UEngine.SCOAddr`.

> **Data required at CE attach (cannot be done from the shell — do NOT fabricate):**
> For each engine version we support (UE4.26, UE4.27, UE5.0–UE5.5), a byte pattern for `StaticConstructObject_Internal`'s prologue. Sources: community UE console-unlock AOBs, or manual capture in the CE disassembler on a live target (disassemble a known-good SCO from a debug/unlocked build, or derive via Path B once, then record the prologue bytes). Each entry is recorded with `verified=<date>` only after the validation checklist passes on a live target. Until an entry exists for the target version, Path B + graceful degradation apply.

### 3. Locate path B — cross-reference from `StaticAllocateObject` (fallback/validator)

`StaticConstructObject_Internal` is one of very few callers of `StaticAllocateObject` in the engine DLL, which makes the SAO→caller walk unambiguous. Steps:

1. **Locate `StaticAllocateObject`.** If no version-pinned SAO pattern is on file either, use `getDissectCode()`:
   - `dc:dissect(moduleName)` (or `(base, size)`), then `dc:getReferencedStrings()` → `{ [strAddr] = str }` across the module. SAO has distinctive check/`FName` strings in **development** builds; on Shipping they are compiled out, so this is a dev-build shortcut only.
   - Shipping fallback: version-pinned SAO pattern (community source, filled at attach like Path A) — SAO's prologue is markedly more stable than SCO's across versions.
2. **Enumerate callers:** `dc:getReferences(SAO)` → `{ [callSite] = jumptype }`. Filter `jtCall==0`/`jtUnconditional==1` (calls + tail jumps into it).
3. **Find the enclosing function.** From each call site, walk backward to the function start: scan backward for MSVC function-boundary padding (`CC CC`/`CC 00 00 00`/`90 90` after a `C3` ret, standard in `/Gy` shipping builds); the first non-padding byte is the candidate start. Choose the call site whose enclosing function also contains the params-struct setup (§4 items 2–4).
4. **Validate** the candidate with the §4 checklist and only then record `UEngine.SCOAddr`.
5. Cache the dissection (`dc:saveToFile`) so repeat runs skip the analysis.

### 4. Validation checklist (ALL must pass before any call)

Disassemble from the candidate function start using the §1 API. Confirmation that the candidate is genuinely `StaticConstructObject_Internal` (UE4.26+/UE5, params-struct signature):

1. **Entry looks like a function**: within the first ~8 instructions, `endbr64` (newer CPUs/toolchains), `push rbx`, `mov [rsp+8],rbx`, `sub rsp, imm` — a plausible MSVC prologue.
2. **It calls `StaticAllocateObject`**: some instruction has `isCall==true` and `parameterValue == SAO`.
3. **Params-struct convention (decisive)**: within ~6 instructions before that call, RCX is loaded from a **stack local** — `lea rcx,[rbp-0xNN]` or `lea rcx,[rsp+0xNN]` (decodes as `modrmValueType=dvtValue`, small negative/positive disp). `FStaticConstructObjectParameters` is a stack local in UE source, so `[rip+...]` here is *wrong* for this call — a rip-relative RCX would mean a global, i.e. a different function.
4. **(Soft) Name machinery**: the function contains the `NAME_None` → `MakeUniqueObjectName` rename path after the SAO call (our `Name=NAME_None` takes exactly this branch). Confirmable via the second call into the FName namespace, or accept as weak evidence only — items 2+3 are the strong evidence.
5. **(Soft) Result handling**: after the SAO call the RAX result is `test`/`mov`-ed into a stored slot or checked before use.

If a candidate fails any item, it is **not** cached and is **not** called.

### 5. Degrade gracefully

If neither Path A nor Path B yields a validated address: record the `console` need as **unpatched**, report `partial:` from the orchestrator (Task 10), and fall back to approach #5 (`PlayerController->ConsoleCommand()` — no UI, but every command still executes). **Never proceed with an unvalidated address.**

---

**The console object MUST have Outer == GameViewport**: `UConsole::ConsoleCommand()` calls `GetOuterUGameViewportClient()->GetGameInstance()` — a wrong outer is a guaranteed crash. The `Name` passed should be `NAME_None` (index 0) so the engine auto-generates a unique name for the instance; **do NOT reuse the CDO itself as the live console** (its outer is the engine package, not the viewport → crash on Enter).

Notes / limitations:
- `GLog->AddOutputDevice(ViewportConsole)` (done by `SetupInitialLocalPlayer`) will **not** run for a manually created console — engine log lines won't appear in the console, but typing commands and command output still work (routed via `FConsoleOutputDevice ConsoleOut(ViewportConsole)` in `UGameViewportClient::ConsoleCommand`).
- **Trailing struct fields.** Everything after `Template` is left zeroed. Up to `InstanceGraph` a null is correct (the engine treats it as "no graph"). UE5.0+ adds `bAllowNativeClassCreation` (default false → 0 is right) and `ExternalPackage` (null is right). UE5.1+ adds `FObjectInitializationOptions` — zeroed means "all defaults false", which is the documented baseline; if a future engine reads a non-default option there, note it in that version's `SCOPatterns` entry. Never write a non-null `Template` that is not the CDO.
- **Repeated `executeCodeEx` timeouts abort the phase** — never loop with leaked allocations (Task 6 wrapper already refuses 0/infinite timeouts).
- If calling `StaticConstructObject_Internal` is not feasible for a given game, record this need as unpatched and fall back to approach #5 (scripted `PlayerController->ConsoleCommand()`) — no UI, but every console command executes.

---

## Definition of done

- `StaticConstructObject_Internal` located via the version-pinned AOB table (Path A) **or** the `StaticAllocateObject` cross-reference (Path B), and the address **validated by disassembly against the §4 checklist** before any call; address cached as `UEngine.SCOAddr` (persisted across runs, 0 re-scans).
- Signature branch resolved from Task 1 (`UEngine.FNameSize`; `UEngine.SCOPositionalSig=false` ⇒ params-struct variant). UE4.25- (positional signature) is **out of scope**: recorded as unsupported, degrade to approach #5.
- `consoleCDO` non-nil is a hard precondition (Task 5 signal); if nil the repair is recorded as blocked and **no** SCO call happens.
- New `UConsole*` created with `Outer == GameViewport`, validated (class name `Console`, outer == vp), then written to `ViewportConsole`. On nil/0 return or validation failure: recorded as unpatched, **nothing written**.
- Repeated `executeCodeEx` timeouts abort the phase (never loop with leaked allocations).
- Missing table entry for the target version ⇒ Path B, then degrade; never a fabricated pattern.

## Verification

1. After running, `readPointer(vp + ViewportConsole.off)` returns a `UConsole` whose `GetOuter` is the viewport client.
2. Pressing ~ (or the patched key, Task 8) toggles the console UI on a Shipping build.
3. Pressing Enter after typing a command does not crash (outer is correct).
4. Re-run reports `already enabled` (idempotent) and does not create a second instance (unique name auto-generated each call is fine — the write only happens when `console` is null).
5. On a build where SCO cannot be located (or `consoleCDO` is nil), the orchestrator returns `partial:` with `console` blocked and the `ConsoleCommand`-only path works.
6. **CE-required (not runnable from the shell):** populate `UEngine.SCOPatterns` for the target `EngineVersion` and run the §4 checklist against a live target at the next CE attach; record `verified` date in the table entry.

---

## Appendix A — Implementation status (`Scripts/console/console.lua`, verified line anchors)

Task 7 is **implemented** in `Scripts/console/console.lua` between the Task 6 block and the "Scanner-time hooks" section (`console.lua:925` header). All line numbers below verified against the current file; Task 6's `UEngine_callFunction` is at `console.lua:888`.

### Function map (name → line → doc section it implements)

| Function | Line | Implements |
|---|---|---|
| `UEngine.SCOPatterns` (table) | `console.lua:937` | Locating §2 Path A — filled at attach, never fabricated |
| `UEngine.SAOPatterns` (table) | `console.lua:942` | Locating §3 step 1 fallback — same fill-at-attach rule |
| `UEngine_mainModuleName()` | `console.lua:947` | Locating §0 — main exe name from `enumModules()[1].PathToFile`, `process` fallback |
| `UEngine_findFunctionStart(callSite)` | `console.lua:962` | Locating §3 step 3 — backward walk over MSVC padding |
| `UEngine_free(addr)` | `console.lua:989` | guarded `deallocateMemory`; only after a completed call |
| `UEngine_validateSCO(candidate, saoAddr)` | `console.lua:1009` | §4 checklist — returns `true,{saoCall,rcx}` or `nil,reason` |
| `UEngine_locateStaticAllocateObject()` | `console.lua:1061` | Locating §3 step 1 — SAO AOB → Dissect-Code string xref |
| `UEngine_locateStaticConstructObject()` | `console.lua:1111` | Locating Path A → Path B + §4, caches `UEngine.SCOAddr` |
| `UEngine_createConsole()` | `console.lua:1182` | this task — the crux |

### Deviations from the doc sketch (all intentional, keep in sync)

1. **SCO is located on demand, not required up-front.** The sketch's step 2 returned `'blocked: ... not located'` when `UEngine.SCOAddr` was nil. The shipped code instead calls `UEngine_locateStaticConstructObject()` lazily (`console.lua:1204`) and only blocks if **locating fails** — so a first call can succeed on a fresh target without a pre-warmed cache. Same shape as `UEngine_discoverViewportOffsets` (Task 2).
2. **SAO anchor is mandatory before Path A.** `UEngine_locateStaticConstructObject` refuses to scan/validate without `StaticAllocateObject` (`console.lua:1116-1119`): checklist items 2+3 are the decisive evidence, and they need the SAO address. The doc's Path A (AOB-first) text implies AOB-only validation; the code always validates a Path A hit against the SAO anchor too.
3. **Prologue check is relaxed by design** (`console.lua:1026-1030`): the exact `mov [rsp+8],rbx` rendering is version-dependent, so *any* `push` / `sub rsp,imm` / `endbr64` within the first 8 instructions counts as a plausible prologue. Strictly stricter prologue checks would reject valid SCO variants; items 2+3 carry the weight.
4. **`lea` OR `mov rcx,[rsp|rbp+disp]`** (`console.lua:1034`): SCO may spill `Params` into a callee-saved reg and reload a field from the stack before the SAO call, so both are accepted. `modrmValueType==2` (dvtValue) is required — a rip-relative load (dvtAddress) means a global → wrong function.
5. **512-instruction disassembly window** with `isRet` break once the SAO call is seen (`console.lua:1019,1044`) — bounds the walk, never reads past a function epilogue.
6. **Never free on the nil-return path.** `params` is freed only after a *completed* call: on validation failure (`console.lua:1259`) and success (`console.lua:1265`). On `UEngine_callFunction` returning nil (`console.lua:1244-1249`) nothing is freed — CE's injected thread may still be running the stub (Task 6 timeout semantics; repeated timeouts abort the phase).
7. **FNameSize re-detect** (`console.lua:1213-1216`): if Task 1's cache is nil, `UEngine_detectFNameLayout()` is re-run rather than trusting a stale `UEngine.FNameSize`. Struct offsets (`setFlagsOff=0x10+fnameSize`, `templateOff=align8(internalOff+4)`) are derived, never hard-coded.
8. **`readBytes(..., true)`** in `UEngine_findFunctionStart` (`console.lua:965`): the `true` trailing arg is mandatory — CE's `readBytes` fails on page-boundary crossings without it (SCANNING-GUIDE §7). Wrapped in `pcall`.

### Debugging walkthrough (read before touching the code)

- **"`StaticAllocateObject not located`"** → check `UEngine.SAOPatterns[EngineVersion]` is populated for the target, or the Dissect-Code string xref found nothing (Shipping build compiled the strings out). This is a locate failure, not a create failure.
- **"`Path A no hit for version X`"** → `UEngine.SCOPatterns` lacks an entry for the target's `EngineVersion` (logged by `UEngine_detectEngineVersion`). Capture the SCO prologue on a live target (or derive it via Path B once) and add the entry with `verified=<date>`.
- **"`Path A hit failed checklist: <reason>`"** → the AOB is the wrong function or the SAO anchor is stale. `reason` is one of: `no MSVC prologue in first 8 instructions` / `no call to StaticAllocateObject found` / `no stack-local rcx ... within 6 instrs before SAO call`. Re-capture the pattern from a disassembly that actually shows `call StaticAllocateObject`.
- **`UEngine_createConsole` returns `nil, 'unpatched: ...'`** → the call *completed* but produced no usable object (nil RAX, or class name ≠ `Console`). `params` is freed; the console need stays unpatched; orchestrator reports `partial:` and falls back to approach #5. Nothing was written to `ViewportConsole`.
- **Verify success:** `UEngine_createConsole` logs `created UConsole 0xXXXX (outer=viewport 0xYYYY) -> ViewportConsole`; afterwards `readPointer(vp + ViewportConsole.off)` is the new object and its `UObject.Class` name is `Console`.

### Keep-in-sync checklist (this doc vs `console.lua`)

- §4 checklist semantics (items, instruction windows, dvtValue/dvtAddress) ↔ `UEngine_validateSCO` comment block (`console.lua:995-1008`).
- Struct layout / FNameSize derivation ↔ `console.lua:1219-1228`.
- Trailing-fields-zeroed rule ↔ the fresh zero-filled `allocateMemory(0x60)` page + only fields through `templateOff` written (`console.lua:1230-1239`).
- Never-free-on-timeout rule ↔ `console.lua:1244-1249` (comment inline).
- DoD item "SCO call happens only when `consoleCDO` non-nil" ↔ `console.lua:1187-1190`.
