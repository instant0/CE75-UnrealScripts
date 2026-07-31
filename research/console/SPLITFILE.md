# Splitting the console feature out of `UnrealEngine-75.LUA`

**Status:** Plan approved; **Phase 0 executed** on 2026-08-01 (see §11 change log). Tasks 7–10 still open.
**Date:** 2026-08-01.
**Applies to:** the Developer Console feature (research/console tasks 1–10). Tasks 1–6 now live in `Scripts/console/console.lua` (split out of `UnrealEngine-75.LUA` in Phase 0, §11); Tasks 7–10 implement into `console.lua`.

---

## 1. Verdict

**Yes — the console feature should live in its own LUA file, not in `UnrealEngine-75.LUA`.** It is feasible without losing anything: every console function is already a top-level global that only reads/writes the shared `UEngine` table or calls CE built-ins, so the file boundary is purely mechanical.

The split is a **file-placement change, not an architecture change**. The console code keeps working exactly as it does today as long as it is loaded before the scanner runs, and the few core functions that the console work *edited* (not added) stay where they are.

**Boundary in one sentence:** the main file keeps the three tiny edits the console work made *inside* core functions plus the scanner/menu call sites; every `UEngine_*` function the console project *added* moves to `Scripts/console/console.lua`.

| Metric | Value (pre-split) | Value (post-split, 2026-08-01) |
|---|---|---|
| `UnrealEngine-75.LUA` | 5481 lines | **4560 lines** |
| Console code in core (Tasks 1–6) | `:937`–`:1826` ≈ 890 lines (~16 %) | **0** (moved to `Scripts/console/console.lua`) |
| Console scanner wiring (Tasks 1–4) | `:3101`–`:3112`, `:3276`–`:3330` ≈ 70 lines | ~15 lines (guarded Task 1 block + `UEngine_runConsoleScanHooks` callout) |
| Core-embedded console edits (must stay) | ~33 lines (`UObject_getName`, `CacheNamePool`, `FindObjectArray`) | unchanged (~33 lines) |
| `Scripts/console/console.lua` | — | **987 lines** (890 moved verbatim + ~97 header/hook scaffolding) |
| Estimated Tasks 7–10 additions | +600–900 lines | still land in `console.lua`, core stays at ~4560 |
| Console share after Tasks 7–10 | ~25 % of the file | core no longer grows with the feature |

---

## 2. Current state (measured)

All measurements below were taken against the working tree on 2026-08-01 (pre-split; see §11 for the post-split state).

### Where the console code sits today

| Task | Section in `UnrealEngine-75.LUA` | Content |
|---|---|---|
| 1 (detect) | `:937`–`:1133` | `UEngine_fnameIndexToString`, `UEngine_findNameTestAddress`, `UEngine_detectFNameLayout`, `UEngine_flavourFromVersion`, `UEngine_detectEngineVersion`, `UEngine_versionBannerScan` |
| 2 (offsets) | `:1134`–`:1237` | `UEngine_discoverViewportOffsets` |
| 3 (find class) | `:1238`–`:1356` | `UEngine_nameTargetIndex`, `UEngine_findObjectByName`, `UEngine_findClassByName` |
| 4 (fix class) | `:1357`–`:1428` | `UEngine_resolveConsoleClassOffset`, `UEngine_fixConsoleClass` |
| 5 (assess) | `:1429`–`:1756` | `UEngine_getObjectFlags`, `UEngine_findCDOs`, `UEngine_findCDO`, `UEngine_findCDOByClassName`, `UEngine_readConsoleKeys`, `UEngine_readCheatManager`, `UEngine_assessDeveloperConsole` |
| 6 (remote call) | `:1757`–`:1826` | `UEngine.RemoteCallTimeoutMs`, `UEngine_remoteCallTimeout` (local), `UEngine_callFunction`, `UEngine_callMethod` |
| 7–10 | *not implemented* | — |

### Console code the main file actually calls (dependency surface)

Every external reference to the console functions, outside the console section itself, is one of:

1. **Scanner wiring (must resolve to globals at attach time):**
   - Task 1: `:3101`–`:3112` — `UEngine_detectEngineVersion()` + `UEngine_detectFNameLayout()` **before** the SuperStruct walk (`:3260`). Load-bearing: `UObject_getName` honors `UEngine.FNameSize`, so UE5 name resolution during the scan depends on it.
   - Tasks 2–4: `:3276`–`:3330` — `UEngine_discoverViewportOffsets()`, `UEngine_findClassByName()`, `UEngine_findObjectByName()`, `UEngine_resolveConsoleClassOffset()` after `findGameInstanceFPropertyAndFields`. Best-effort (nil on failure).
2. **Core edits made *inside* existing core functions (these cannot move — see §4):**
   - `UObject_getName` FNameSize branch `:78`–`:84`.
   - `FindObjectArray` → `UEngine.ObjectArrayNumElements` cache `:2005`–`:2021`.
   - `CacheNamePool` → `UEngine.NameToIndexMin` per-string min index `:2376`–`:2381` + `:2394`–`:2396`.
3. **Nothing else.** No other core code reads `UEngine.ConsoleClassAddr`, `UEngine.ConsoleClass`, `UEngine.GameViewport`, `UEngine.UGameViewportClient`, `UEngine.DevConsoleState`, `UEngine.EngineVersion` (except `:3104`), `UEngine.NameToIndexMin` (except `:2395`), `UEngine.ObjectArrayNumElements` (except `:2013`), `UEngine_callFunction`/`UEngine_callMethod` (Task 6 defs only). Verified by grep — the console cache keys are written and read **only inside the console section and the wiring above**.

### Load-order / scope facts that make the split safe

- Every console function is a **global** (`function UEngine_*`), already the convention used by plugins (`Scripts/g1r/g1r-plugin.lua` defines globals and is loaded via `dofile`). A separate file that `dofile`s the same definitions is invisible to the main file's locals.
- The main file already locates itself with `debug.getinfo(1,'S').source` and `dofile`s external scripts from that directory (`UEngine_scanPlugins` `:5122`–`:5145`, `UEngine_loadPlugin` `:5170`–`:5180`). Loading a sibling console file uses the same, already-proven mechanism.
- `log` in the main file is **local** (`:55`) — a separate file cannot call it, so `console.lua` must define its own local `log` that appends to `UEngine.log` the same way (see §5).
- `UEngine_runWhenReady` (`:2743`), `UE_newMenuItem` (`:2651`), `UEngine.PluginAPI` (`:5182`) are globals — usable from the console file unchanged.

---

## 3. Evaluation — why split, and why it is worth it

### Arguments for a separate file

1. **The main file is already large and it is the shared core.** 5481 lines, and every game-agnostic concern (scanner, dissect, name pool, structure viewer, menu, plugin loader) lives there. Console enablement is a *feature* bolted on top, not part of the core scanner contract.
2. **Future Tasks 7–10 add the biggest blocks** — the orchestrator, the version-pinned SCO AOB table, keys/cheat patches, and the menu handler. That is the point where the console share jumps past a quarter of the file.
3. **The console feature is self-contained by construction.** Detect → Assess → Repair → Verify touches only: the shared `UEngine` cache table, CE read/write built-ins, and `UEngine_runWhenReady`/menu globals. It does not need `local` access to any main-file function — verified, every dependency is a global or a CE built-in.
4. **It is a clean rollback/reuse unit.** A separate file can be loaded standalone, diffed in isolation, syntax-checked alone (`luac -p console.lua`), and — if a game vendor patches something — edited without touching the core.
5. **Plugin precedent exists.** `g1r-plugin.lua` already proves an external `dofile`d file defining `UEngine_*` globals works in this codebase.
6. **Menu wiring gets simpler, not harder.** Task 10's current doc fights the `menusBuilt` flag to inject a menu item into `UEngine_buildSuccessMenus` from outside. A tiny generic hook in the builder (§5.4) removes that whole fight and lets the console file own its menu.

### Arguments against / costs (and mitigations)

1. **Two files must ship together** into CE's autorun. Mitigation: the main file `dofile`s the console file at the top, so a missing console file is a logged warning, not a crash (guarded `pcall`, guarded scanner call sites §5.3).
2. **Load order matters.** The console file must be loaded before the scanner runs (attach time). Mitigation: `dofile` at the very top of the main file (`:15`, right after the `UEngine` bootstrap `:14`) — guaranteed before any `MainForm.OnProcessOpened` handler is registered (`:5423`).
3. **`log` is local.** Mitigation: console file defines its own local `log` with the identical `UEngine.log` append.
4. **Reload/duplicate-menu risk.** Mitigation: the console file only *adds* its menu item inside a builder hook (fresh items each build, `UEngine.GUI` rebuilt from scratch on reload), and the console file's top-level code is idempotent (re-defining globals).
5. **Small per-file drift risk** (definitions in the wrong file). Mitigation: the keep/move table in §4 is the review checklist; `grep`-verify with the commands in §8.

### Conclusion

The split removes ~16 % of the main file immediately (and stops the next ~25 % from landing there), at the cost of ~15 lines of generic load/wiring in the core. The console feature's coupling is entirely through globals and the shared `UEngine` table, so "as much as possible in its own file" is — practically — **everything the console project added**, which is exactly what §4 specifies.

---

## 4. Keep / move boundary

### MUST stay in `UnrealEngine-75.LUA` (cannot move)

These are edits *inside* pre-existing core functions; extracting them would require re-architecting the core:

| Location | What | Why it is core |
|---|---|---|
| `:78`–`:84` | `UObject_getName` honors `UEngine.FNameSize` (12/8) | Name resolution used by the whole scanner/dissect |
| `:2005`–`:2021` | `FindObjectArray` caches `UEngine.ObjectArrayNumElements` | Object-array walk count, generic |
| `:2376`–`:2381`, `:2394`–`:2396` | `CacheNamePool` records `UEngine.NameToIndexMin` | Name-pool cache, generic |
| `:2813`–`:2897` | `UEngine_buildSuccessMenus` (+ one generic hook, §5.4) | Menu builder, core |
| `:3101`–`:3112`, `:3276`–`:3330` | Scanner wiring call sites (guarded) | Runs inside `UEInfoScanner`, core |
| `:5114`–`:5192` | Plugin registry / loader | Core |
| `:1828`+ | `isInExecutableMainModuleMemory` etc. | Pre-existing core, untouched by the console work |

### MUST move to `Scripts/console/console.lua`

Everything the console project *added* as its own functions — the full block `:937`–`:1826`:

- Task 1: `UEngine_fnameIndexToString`, `UEngine_findNameTestAddress`, `UEngine_detectFNameLayout`, `UEngine_flavourFromVersion`, `UEngine_detectEngineVersion`, `UEngine_versionBannerScan`
- Task 2: `UEngine_discoverViewportOffsets`
- Task 3: `UEngine_nameTargetIndex`, `UEngine_findObjectByName`, `UEngine_findClassByName`
- Task 4: `UEngine_resolveConsoleClassOffset`, `UEngine_fixConsoleClass`
- Task 5: `UEngine_getObjectFlags`, `UEngine_findCDOs`, `UEngine_findCDO`, `UEngine_findCDOByClassName`, `UEngine_readConsoleKeys`, `UEngine_readCheatManager`, `UEngine_assessDeveloperConsole`
- Task 6: `UEngine.RemoteCallTimeoutMs`, `UEngine_remoteCallTimeout`, `UEngine_callFunction`, `UEngine_callMethod`
- **Tasks 7–10 (to be written):** everything listed in §6.

### Shared contract (stays on the global `UEngine` table, unchanged)

The console file reads and writes the same `UEngine` cache keys as today — `UEngine.FNameSize`, `UEngine.UEFlavour`, `UEngine.EngineVersion`, `UEngine.GameViewport`, `UEngine.UGameViewportClient.ViewportConsole`, `UEngine.ConsoleClass`, `UEngine.ConsoleClassAddr`, `UEngine.DevConsoleState`, `UEngine.NameToIndexMin`, `UEngine.ObjectArrayNumElements`, `UEngine.DevConsoleEnabled`, `UEngine.RemoteCallTimeoutMs`. This table is the boundary between the two files and must not change.

---

## 5. Target architecture

### 5.1 File layout

```
UnrealEdit75/
├── UnrealEngine-75.LUA          # core (shrinks by ~890 lines + Tasks 7–10 stay out)
└── Scripts/
    └── console/
        ├── console.lua          # ALL console code (Tasks 1–10)
        └── console.manifest     # optional; lets Tasks 7–10 also be menu-loadable
```

Naming note: use a plain `console.lua`, **not** `console-Plugin.lua` + manifest, unless we want the plugin menu to offer it. `UEngine_scanPlugins` only picks up `<folder>/<folder>-Plugin.lua` + `<folder>.manifest` pairs, so a bare `console.lua` is ignored by the plugin scanner and loaded only by the main file — exactly the behaviour we want. (A manifest pair can be added later without changing anything.)

### 5.2 Load order — main file boots the console file

Insert immediately after the `UEngine` bootstrap (`:14`), before the CE-compat helpers (`:16`):

```lua
-- Boot external feature modules. console.lua holds the Developer Console feature
-- (research/console tasks 1–10). Guarded: core must load and scan even without it.
pcall(function()
  local src=debug.getinfo(1,'S').source
  local dir=src:sub(2):match('^(.*)[/\\]') or '.'
  local f=dir..'/Scripts/console/console.lua'
  if fileExists(f) then
    dofile(f)
  else
    UEngine.log=(UEngine.log or '')..'console.lua not found ('..f..'); console feature disabled\n\r'
  end
end)
```

This guarantees the console globals exist before `MainForm.OnProcessOpened` is hooked (`:5423`) and before the scanner can call them.

### 5.3 Guarded scanner wiring (small main-file edits)

The three scanner call sites keep their current positions but must not crash when the console file is absent. Wrap the external calls:

- Task 1 block (`:3101`–`:3112`): keep as-is if `console.lua` is mandatory in practice, otherwise guard with `if type(UEngine_detectFNameLayout)=='function' then ... end`. **Do not remove the `UEngine_detectEngineVersion()`/`UEngine_detectFNameLayout()` calls from the scan path** — the SuperStruct walk depends on `FNameSize` via `UObject_getName`.
- Tasks 2–4 block (`:3276`–`:3330`): collapse the three inline blocks into **one** guarded callout so the wiring in core stays ~5 lines:

```lua
-- Console feature scan-time hooks (best-effort; no-ops when console.lua is absent)
if type(UEngine_runConsoleScanHooks)=='function' then
  pcall(UEngine_runConsoleScanHooks, t)
end
```

`UEngine_runConsoleScanHooks(t)` is defined in `console.lua` and contains the current Task 2 + Task 3 + Task 4 wiring body (discover offsets, find+cache Console UClass, resolve+log ConsoleClass offset).

### 5.4 Console file skeleton (`Scripts/console/console.lua`)

```lua
-- console.lua — Developer Console feature for UnrealEngine-75.LUA (research/console 00–10)
-- Loaded by UnrealEngine-75.LUA at boot (guarded dofile). Depends on the core globals
-- UEngine, UEngine_runWhenReady, UE_newMenuItem, UEngine_getAllProperties, ...
UEngine = UEngine or {}

-- Own local log: the core's log() is local to UnrealEngine-75.LUA (:55), so append to
-- the same UEngine.log buffer here to keep all feature output in one place.
local function log(str)
  UEngine.log=(UEngine.log or '')..str..'\n\r'
end

-- Reload-safe defaults (same pattern as the core's `or` guards)
UEngine.RemoteCallTimeoutMs=UEngine.RemoteCallTimeoutMs or 5000

-- [Tasks 1–10 code, moved/written here verbatim]

  -- Scanner-time hooks (called by UEInfoScanner, guarded, §5.3)
  function UEngine_runConsoleScanHooks(t)
  -- Task 2 + Task 3 + Task 4 wiring (implemented — see §11)
  end

-- Menu contribution hook (§5.5): called by UEngine_buildSuccessMenus before menusBuilt
UEngine.menuContributors=UEngine.menuContributors or {}
UEngine.menuContributors[#UEngine.menuContributors+1]=function(miDebug)
  local mi=UE_newMenuItem('Enable Developer Console')
  mi.OnClick=function()
    UEngine_runWhenReady(function()
      local ok,msg=UEngine_enableDeveloperConsole()
      if ok then showMessage('Developer Console enabled. Press ~ (Tilde) to open.')
      else showMessage('Failed: '..tostring(msg)) end
    end)
  end
  miDebug.add(mi)
end
```

### 5.5 Menu hook (the only Task-10 main-file edit under this architecture)

In `UEngine_buildSuccessMenus`, right after `miSearchCharProps` is added to `miDebug` (`:2885`) and before `menusBuilt` is set (`:2896`):

```lua
-- Feature menu contributors (console.lua etc.) — fresh items each build, so reloads
-- never leave duplicates (UEngine.GUI is rebuilt from scratch on reload).
if type(UEngine.menuContributors)=='table' then
  for _,fn in ipairs(UEngine.menuContributors) do pcall(fn, UEngine.GUI.miDebug) end
end
```

This supersedes Task 10's "add `miEnableConsole` inside `UEngine_buildSuccessMenus` and register it in the stale-destroy list at `:1890`/`:1899`–`:1904`" requirement — the contributor runs *inside* the builder, so no stale-list entry is needed. (Note: `:1890`/`:1899`–`:1904`/`:1962` are the line refs **as written in the Task 10 doc**; in the current file the builder sits at `:2813`, the stale-destroy list at `:2822`–`:2827`, and `menusBuilt` is set at `:2896`.) (If the hook is not accepted, Task 10 falls back to the original in-builder placement, which then remains console UI code in the core — see the decision in §9.)

---

## 6. Guidelines for Tasks 7–10 — target `Scripts/console/console.lua`

This is the "update task 7-finish" requirement: from now on the remaining tasks implement **into `console.lua`**, not `UnrealEngine-75.LUA`. The table below supersedes the "implement in `UnrealEngine-75.LUA`" wording in `research/console/README.md` line 3 and in each task doc.

| Task | Target function(s) in `console.lua` | Main-file edits needed |
|---|---|---|
| 7 | `UEngine_createConsole()` — build the `FStaticConstructObjectParameters`, gate on `UEngine.DevConsoleState.consoleCDO`, `UEngine_callFunction(scoAddr, params)`, validate (class `Console`, outer == viewport), write `UEngine.UGameViewportClient.ViewportConsole`. Locate SCO via the version-pinned AOB table keyed on `UEngine.EngineVersion` (set by `UEngine_detectEngineVersion`, now in `console.lua`). | **None** |
| 8 | `UEngine_patchConsoleKeys()` — `UEngine_findCDO('Default__InputSettings')` / `UEngine_findCDOByClassName`, walk `ConsoleKeys` TArray, write first FKey `KeyName` using `UEngine.NameToIndexMin['Tilde']` + `UEngine.FNameSize` (UE5: ComparisonIndex/DisplayIndex/Number). Empty-array fallback recorded explicitly. | **None** |
| 9 | `UEngine_setupCheatManager()` — LocalPlayer→PC walk (reuse `UEngine_findLocalPlayer`), patch `CheatClass`, vtable-resolve `SpawnCheatManager`, call via `UEngine_callMethod` **gated on `UEngine.DevConsoleState.cheatCDO`**; verify by re-read. | **None** |
| 10 | `UEngine_enableDeveloperConsole()` — 5-stage flow (PREFLIGHT via `UEngine_runWhenReady` → DETECT → ASSESS → REPAIR → VERIFY), `UEngine.DevConsoleEnabled` state, `UEngine_runConsoleScanHooks` (if not already in Phase 0), and menu registration via `UEngine.menuContributors` (§5.4/§5.5). | **Only** the ~6-line `menuContributors` iteration in `UEngine_buildSuccessMenus` (§5.5) |

### Task 7 detail (unchanged crux, now located in the console file)

Keep every behavioural requirement from `07-TASK-CREATE-CONSOLE.md`:

- Signature branch resolved from `UEngine.FNameSize` (`FStaticConstructObjectParameters` shifts: SetFlags `0x10+FNameSize`, Template 8-aligned after InternalSetFlags — see the task doc).
- `consoleCDO` present is a hard gate; `allocateMemory(0x60)` is fresh zero-filled memory; nothing written to the game until the returned object validates.
- `Outer` MUST be the `UGameViewportClient` (`UConsole::ConsoleCommand` derefs `GetOuterUGameViewportClient()` — wrong outer = crash).
- Locate SCO only by validated address (version-pinned AOB table or `StaticAllocateObject` cross-reference); never call an unvalidated address; record `partial:` otherwise.

### Task 10 detail (menu, state, orchestrator)

- Orchestrator returns `ok, summaryString` (`'already enabled'` / `'enabled'` / `'partial: …'` / `nil,'pending'`).
- `UEngine.DevConsoleEnabled` gates re-entry.
- Menu item added **via the contributor hook**, so it appears under `Unreal Engine → Debug` with zero knowledge of `menusBuilt` in the console file. `UEngine_runWhenReady` handles the not-ready case (it already starts the scanner if needed, `:2757`).
- Do NOT register the item in the core's stale-destroy list (it is recreated each build by the hook).

### Cross-cutting rules for all of Tasks 7–10

1. **Use the console file's local `log`** (never expect the core's local `log` to be visible).
2. **Only touch `UnrealEngine-75.LUA` for the two documented items** (§5.2 load, §5.5 menu hook). If a task needs more, stop and extend the boundary in §4 first.
3. **Keep every `UEngine_*` cache key on the shared `UEngine` table** — that is the core↔console contract.
4. **Wrap CE remote calls (`executeCodeEx`) in `pcall` and always pass a finite ms timeout** (Task 6 wrappers already enforce this; Tasks 7/9 must call the wrappers, not raw CE APIs).
5. **Preserve idempotence** (re-run = `'already enabled'`, no writes) and the hard gates (`consoleCDO`, `cheatCDO`).
6. **`luac -p console.lua` + `loadfile` must pass** before reporting a task done (see §8).

---

## 7. Phase 0 — retro-migrating the completed Tasks 1–6 (recommended, one shot)

Do the migration as a single mechanical commit so the file boundary is clean before Tasks 7–10 land:

1. Create `Scripts/console/console.lua` with the skeleton (§5.4).
2. Cut `:937`–`:1826` from `UnrealEngine-75.LUA` and paste it into `console.lua` verbatim (keep the section banner comments; nothing else changes — same globals, same `UEngine` cache keys, same comments).
3. Add the boot `dofile` at `:15` (§5.2) and the guarded wiring callout (§5.3). Replace the inline Tasks 2–4 scanner block with `UEngine_runConsoleScanHooks(t)`; keep the Task 1 block guarded.
4. Move the `UEngine_runConsoleScanHooks` body into `console.lua`.
5. Leave the three core-embedded edits (`:78`–`:84`, `:2005`–`:2021`, `:2376`–`:2396`) exactly as-is.
6. **Do not** add the menu hook or the Task-10 item yet (that belongs to Task 10).
7. Verify per §8 (syntax, load, grep-boundary, CE reload smoke test).

Optional, do not bundle into Phase 0: renaming any function, changing cache keys, or moving the scanner call sites. Keep this migration behaviour-identical.

---

## 8. Verification plan

1. **Syntax / load (both files):**
   - `luac -p UnrealEngine-75.LUA` and `luac -p Scripts/console/console.lua` both pass.
   - `luac -p` on `console.lua` **alone** (proves it does not depend on the core file's locals).
   - `loadfile` on the boot snippet to confirm the `debug.getinfo` dir resolution.
2. **Boundary (grep) — nothing console-defined is left in the core:**
   - `grep -n "function UEngine_" UnrealEngine-75.LUA` → no console function definitions remain (only the three core edits' cache keys and the wiring call sites).
   - `grep -n "UEngine_callFunction\|UEngine_callMethod\|UEngine_detectFNameLayout" UnrealEngine-75.LUA` → only the guarded call sites (`:3104`–`:3112`, the §5.3 callout), no `function` lines.
3. **Boot without the console file:** temporarily rename `console.lua`, load the core → must log a warning and still scan (guarded wiring).
4. **Boot with the console file:** load the core → console globals present (`type(UEngine_detectFNameLayout)=='function'`), no duplicates after two reloads (menu item rebuilt once per build).
5. **Behaviour parity:** re-run the Task 5/6 field verification against a UE target; results must match the pre-split behaviour (FName layout cached, viewport/console offsets cached, `UEngine_callFunction` RAX round-trip).
6. **Tasks 7–10:** each task's own DoD/verification list (§6), run against the console file path.

---

## 9. Decisions recorded / open items

| # | Question | Recommended | Owner |
|---|---|---|---|
| 1 | Split at all? | Yes — see §1/§3 | — |
| 2 | File path | `Scripts/console/console.lua` | — |
| 3 | Load mechanism | Core `dofile` at `:15` (§5.2) | — |
| 4 | Phase 0 retro-migrate Tasks 1–6? | Yes, one mechanical commit (§7) | — |
| 5 | Menu item home | Via `UEngine.menuContributors` hook in the builder (§5.5); fallback = Task 10's in-builder placement (keeps console UI in core — accepted only if the hook is rejected) | — |
| 6 | Tasks 2–4 scanner wiring | Collapse to one `UEngine_runConsoleScanHooks(t)` callout (§5.3) | — |
| 7 | Plugin-menu loadability for the console file | Deferred; `console.lua` stays out of `UEngine_scanPlugins` scope (no `-Plugin.lua`/manifest pair) unless needed | — |
| 8 | Update `research/console/README.md` | **Done 2026-08-01 (with the Task 7 kickoff):** README line 3 → "implement in `Scripts/console/console.lua`"; status board gained a Location column; task docs 07–10 got implementation-target banners (`UEngine_createConsole` / `UEngine_patchConsoleKeys` / `UEngine_setupCheatManager` / `UEngine_enableDeveloperConsole`) and their stale core line refs were re-pointed (`couldBeUnrealEngine`→`:2464`, `UEngine_findCharacter`→`:3162`, `UEngine_ensureGameEngineStructure`→`:2693`, Task 10 menu→§5.5 hook). See §11.1. | — |

---

## 10. Summary

- **Feasible now:** every console function is a self-contained global; the only hard dependencies are the three edits inside core functions (stay), the scanner call sites (become guarded), and the `UEngine` cache table (shared contract).
- **Recommended:** `Scripts/console/console.lua`, booted by a guarded `dofile` at the top of the core, owning Tasks 1–10 code; core keeps ~15 lines of load/hook/wiring for the feature.
- **Tasks 7–10:** implement into `console.lua` per §6; the only main-file change any of them needs is the ~6-line `menuContributors` iteration in `UEngine_buildSuccessMenus` (Task 10).
- **Target outcome:** `UnrealEngine-75.LUA` stops growing with the console feature: 890 lines extracted in Phase 0 (core now **4560 lines**) and the ~600–900 lines of Tasks 7–10 kept out, containing the console feature to one file.

---

## 11. Change log — Phase 0 executed (2026-08-01)

Implements §7 verbatim. One deviation from the plan text, recorded below.

| Step (§7) | Done | Result |
|---|---|---|
| 1. Create `Scripts/console/console.lua` | ✅ | New file, **987 lines** |
| 2. Cut `:937`–`:1826` into it verbatim | ✅ | **Byte-identical** move (890 lines; verified with `diff` against the pre-cut working tree) |
| 3a. Boot `dofile` at `:15` (§5.2) | ✅ | Added immediately after `UEngine = UEngine or {}` |
| 3b. Guarded scanner callout (§5.3) | ✅ | Tasks 2–4 block replaced with `pcall(UEngine_runConsoleScanHooks, t)`; Task 1 block wrapped in `type(...)=='function'` guards |
| 4. `UEngine_runConsoleScanHooks` body into `console.lua` | ✅ | Contains the former Tasks 2+3+4 scanner body (offset discovery, Console UClass cache, ConsoleClass offset log) |
| 5. Core-embedded edits untouched | ✅ | `:78`–`:84` FNameSize, `:2005`–`:2021` ObjectArrayNumElements, `:2376`–`:2396` NameToIndexMin — verified present (now `:91`–`:93`, `:1135`, `:1517` post-shift) |
| 6. No menu hook / Task-10 item | ✅ | Not added; `menuContributors` (§5.4/§5.5) still belongs to Task 10 |
| 7. Verify (§8) | ✅ | See below |

### Deviation from the plan text (one, forced by the code)

The plan's §3/§5 assumed every console function was a top-level global and had **no dependency on the core file's locals**. Two of those assumptions are false, verified against the code:

1. **`getMemScanResults` is a local in the core (`UnrealEngine-75.LUA:17`) but is called from the console block** at `:1121` (`UEngine_versionBannerScan`) and `:1338` (`UEngine_findClassByName`). Since locals never cross a file boundary, `console.lua` now defines its own **identical local copy** (CE 7.5 `createFoundList` reader, same 11 lines). This is the only behaviour-neutral duplication.
2. Four console functions are themselves `local` (`UEngine_fnameIndexToString :943`, `UEngine_flavourFromVersion :1064`, `UEngine_versionBannerScan :1104`, `UEngine_remoteCallTimeout :1773`). The verbatim cut preserves them as locals of `console.lua` — correct, and they are only referenced inside the moved block (verified by grep).

Everything else in §4's boundary held: the console block additionally calls the core **globals** `UObject_getName`, `UEngine_getAllProperties`, `UEngine_resolveFName`, `UEngine_findLocalPlayer`, `UEngine_searchPropsOnObject` — all resolve fine from a separate file.

### Post-split state (measured)

- `UnrealEngine-75.LUA`: **4560 lines** (was 5481; −890 moved, +12 boot dofile, +8 scanner-hook guards/callout, −1 blank-line collapse, net −~70 for the collapsed Tasks 2–4 wiring).
- `Scripts/console/console.lua`: **987 lines** = 890 verbatim block + ~18 header (`UEngine` bootstrap, local `log`, local `getMemScanResults`) + ~79 tail (`UEngine_runConsoleScanHooks`).
- Grep boundary: no `function UEngine_*` console definitions remain in the core; the only console references left are the two guarded call sites (`:2228`–`:2235` Task 1, `:2407`–`:2408` scan-hooks callout). The three core-embedded edits are untouched.
- Verification passed: `luac -p` and `loadfile` on **both** files; `luac -p`/`loadfile` on `console.lua` alone (proves no dependence on the core's locals).

### Outstanding (not part of Phase 0, per §7.6)

- §5.5 `menuContributors` hook in `UEngine_buildSuccessMenus` — Task 10.
- Boot-without-console-file smoke test (§8.3) and CE reload parity run (§8.5) require CE — not runnable from the shell; do at next CE attach.
- Tasks 7–10 implementation — now begin.

### §11.1 Doc-update follow-up (2026-08-01, decision #8)

Per §9#8, the task docs are updated to the new target before Tasks 7–10 begin:
- `README.md:3` now says implement in `Scripts/console/console.lua` (with the split context); status board has a **Location** column.
- Task docs 07–10 each carry an implementation-target banner naming the target function in `console.lua`; stale core line refs re-pointed to post-split lines (`couldBeUnrealEngine`→`:2464`, `UEngine_findCharacter`→`:3162`, `UEngine_ensureGameEngineStructure`→`:2693`).
- Task 10's Menu Integration rewritten to the §5.5 `UEngine.menuContributors` hook (stale `:1890/:1899/:1962` in-builder text removed).

### §11.2 Task 7 research + doc update (2026-08-01)

`07-TASK-CREATE-CONSOLE.md` rewritten with the complete SCO-location procedure. Research was done against the **local CE 7.5 source** (`/mnt/y/Lazarus/Projects/cheat-engine-7.5/Cheat Engine/`) — no AOB data was fetched or fabricated online (AOB byte patterns still require a live CE attach; the table schema and fill workflow are documented instead):
- CE Lua API pinned to source line refs: `AOBScan`/`AOBScanUnique`/`AOBScanModuleUnique` (`LuaHandler.pas:4291/4346/4364`, `simpleaobscanner.pas:23/136`), disassembler `createDisassembler`/`disassemble`/`getLastDisassembleData` (`LuaDisassembler.pas:19/210/225`), `call rel32` resolved `parameterValue` (`disassembler.pas:15009`), `[rip+disp]` `modrmValue`=raw disp32 (`disassembler.pas:864`), `getDissectCode`/`getReferences` (`LuaDissectCode.pas:22/144`, `jtCall=0`).
- **Corrections vs the old doc:** params struct is a **stack local**, so the RCX convention to verify is `lea rcx,[rsp+..]`/`lea rcx,[rbp-..]`, not `lea rcx,[rip+..]`; `RipRelativeScanner.Address[i]` is the disp32-field address, not the instruction/target (documented as out-of-scope for this task).
- `UEngine_createConsole` sketch aligned to real console.lua symbols (`DevConsoleState.viewport/consoleCDO`, `ConsoleClassAddr`, `UEngine_callFunction`, `UEngine.SCOAddr` cache, FName-size-derived struct offsets, `Template=nil` gated on the CDO).
- Path A (version-pinned `UEngine.SCOPatterns` keyed on `UEngine.EngineVersion`) + Path B (`getDissectCode` SAO cross-ref) + §4 disassembly validation checklist + §5 graceful degrade; DoD/verification updated and CE-required items flagged.
- **`research/CE-FUNCTIONS.md` created**: the source-verified reference doc for every CE Lua function used (AOB scans, MemScan/FoundList, disassembler + `LastDisassembleData` field semantics, Dissect Code, RIP scanner, `executeCodeEx`/`executeMethod`, StringList), each with its Pascal file:line. Cross-linked from `CE75-SCANNING-GUIDE.md` §11, `CE75-REFERENCE.md` index, and the Task 7 doc.
- Outstanding (unchanged): AOB byte-pattern data + CE smoke tests (§8.3/§8.5) — next CE attach.

