# Task 1 — Phase 1: Layout Detection (UE4 vs UE5)

> **CORRECTED (2026-08-01) — see [11-TASK-DUAL-VERSION-CORRECTIONS.md](../11-TASK-DUAL-VERSION-CORRECTIONS.md) §1/§7a/§7b.** This archived doc's FName claims are WRONG and superseded: FName is `{ComparisonIndex@+0, Number@+4, DisplayIndex@+8}` — **Number is at +4 in BOTH versions** (shipping UE5 is 8-byte like UE4; the 12-byte form exists only in editor-ish builds with `WITH_CASE_PRESERVING_NAME`). Do NOT key FNameSize off game version, and do NOT read Number at +8. The detector probes +8 (DisplayIndex mirror), not +4. The implemented code (`console.lua:99-164`, `UnrealEngine-75.LUA:81-109`) already reflects this.

**Goal:** Implement `UEngine_detectFNameLayout()` and cache the layout facts every later read/write needs.

**Depends on:** nothing (core scanner state: `UEngine.UGameEngine`, `UEngine.UObject.Name`, `UEngine_resolveFName`).
**Prerequisite knowledge:** `research/console/00-BACKGROUND.md`, `research/console/README.md` (Chain of Discovery).

---

Version detection is a **gate for the later read/write steps** (FName width, `StaticConstructObject_Internal` signature, TObjectPtr handling), not a one-time "is it UE4 or UE5?" branch. Cache everything the repairs will need:

```lua
-- Phase 1 result table (all cached before any write):
--   UEngine.UEFlavour          = 'UE5' | 'UE4'
--   UEngine.FNameSize          = 12 | 8
--   UEngine.EngineVersion      = full version string, e.g. '5.3.2' (keys Task 7's AOB table)
--   UEngine.SCOPositionalSig   = true | false   -- UE4.25- only (rare)
--   UEngine.ObjectArrayNumElements = live FUObjectItem count (see companion section)
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
- `StaticConstructObject_Internal` signature (needed only if Task 7 runs): UE4.26+ and UE5 use `const FStaticConstructObjectParameters&`; UE4.25- uses positional params. FName width distinguishes UE5 from UE4 but **not** 4.26 from 4.25 — disassemble the located function's prologue if the target is known to be old UE4.
- **Engine minor version for Task 7's AOB table.** `couldBeUnrealEngine` (UnrealEngine-75.LUA:2393-2417) only separates UE4 from UE5 (`ProductVersion:find('%%+UE4'/'%%+UE5')` at :2406-2407) — too coarse to key an AOB table on UE5.0 vs UE5.5. Also read the full version string (e.g. from `getFileVersion`'s `ProductVersion`, or a memscan of the `%+UE5+Release-<minor>` banner) and cache it as `UEngine.EngineVersion`. Task 7's "version-pinned AOB table" is keyed on this, not on the coarse flavour.

---

## Prerequisite core fix — `UObject_getName` reads FName as a QWORD — [fixed]

`UnrealEngine-75.LUA:68-86` reads the object name as a single `readQword` and treats the high dword as `Number`:

```lua
local i=readQword(UObjectAddress+UEngine.UObject.Name)
local index=i & 0xffffffff
local number=i >> 32
```

That is the **UE4** FName layout (`{ComparisonIndex@+0, Number@+4}`). On **UE5** (`{ComparisonIndex@+0, DisplayIndex@+4, Number@+8}`) the high dword is **DisplayIndex**, so names resolve to `"Class_<displayindex>"` and every `== 'Class'`-style check in Tasks 3, 5, 7, 9 silently fails on UE5. Because this task establishes `UEngine.FNameSize`, fold the fix in here — no later task may assume name reads are correct before this runs:

```lua
function UObject_getName(UObjectAddress)  -- [fixed]
  if UEngine==nil or UEngine.UObject==nil or UEngine.UObject.Name==nil or UEngine.IndexToName==nil then
    return nil,'UEngine.UObject.Name not initialized yet'
  end
  local vftableptr=readPointer(UObjectAddress)
  if vftableptr and vftableptr>=getAddress(process) and vftableptr<getAddress(process)+getModuleSize(process) then
    local idx=readInteger(UObjectAddress+UEngine.UObject.Name)
    local name=UEngine.IndexToName[idx]
    local number
    if UEngine.FNameSize==12 then        -- UE5: Number at +8
      number=readInteger(UObjectAddress+UEngine.UObject.Name+8)
    else                                 -- UE4: Number at +4
      number=readInteger(UObjectAddress+UEngine.UObject.Name+4)
    end
    if name and number and number>0 then
      name=name..'_'..number
    end
    return name
  end
end
```

This only changes UE5 behavior (currently broken); UE4 output is byte-identical because `+4` is the Number either way. The vtable-in-module guard and `IndexToName` lookups are unchanged.

## Companion fix — per-string minimum name index (`UEngine.NameToIndexMin`)

While the name pool is enumerated (`CacheNamePool`, UnrealEngine-75.LUA:1405-1476), also record a **per-string minimum index** (`UEngine.NameToIndexMin[str]`). On UE5 with case-preserving names a string can exist at both a comparison-table index and a display-table index; the comparison entry is allocated first, so the lowest index is the one `FName::Contains`/equality actually compares. Task 8 needs it to patch `ConsoleKeys` to `Tilde` (display indices break the toggle check).

## Companion cache — object-array element count (`UEngine.ObjectArrayNumElements`)

Task 3's class-name walk iterates the object array. **Do not read the count from `UEngine.ObjectArray + 0x08`**: `FindObjectArray`'s own pattern match (`[N, N-1, N, 0, ptr]` at UnrealEngine-75.LUA:1035-1046) proves `+0x08` is `MaxObjectsNotConsideredByGC` (a max, not a live count). Cache the real element count instead, while `FindObjectArray` (UnrealEngine-75.LUA:1105-1196) is scanning — read `FChunkedFixedUObjectArray::NumElements` from the discovered array struct and store it as `UEngine.ObjectArrayNumElements`. Field offset is version-dependent (validate against the logged `ObjectArrayListType` / `ObjectArrayEntryStructSize`); if it cannot be resolved, leave nil and let Task 3 fall back to the memscan path.

---

## Definition of done

- `UEngine.UEFlavour` and `UEngine.FNameSize` are set (12/UE5 or 8/UE4) by the time the orchestrator (Task 10) calls `UEngine_enableDeveloperConsole()`.
- `UEngine.EngineVersion` cached (full string, not just flavour) when resolvable.
- `UObject_getName` updated to honor `UEngine.FNameSize` (its UE5 output currently carries a bogus DisplayIndex suffix).
- Detection runs during PREFLIGHT/DETECT (orchestrator step 1) and is cached for Tasks 6, 7, 8.
- No writes to target memory in this task.

## Verification

1. Attach to a UE4 game → log shows `FNameSize 8 / UE4`.
2. Attach to a UE5 game → log shows `FNameSize 12 / UE5`.
3. Re-run: detection is idempotent (cached, no re-scan if already set).
4. On a UE5 target, `UObject_getName(UEngine.GameEngineClass)` returns exactly `GameEngine` — no numeric suffix.
5. `UEngine.EngineVersion` holds the full version (e.g. `5.3.2`) on a UE5 target; `UEngine.ObjectArrayNumElements` is a sane live count (matches `ObjectArrayEntryStructSize`-bounded walk length) or nil with the memscan fallback active.

---

## Implementation log — 2026-07-31 (deviations from the proposal above)

Task 1 was implemented in `UnrealEngine-75.LUA`. The code deviates from the proposal in several places; this section records what actually shipped so later tasks and reviews diff against the real state.

### `UObject_getName` — kept the legacy fallback branch

The proposed fix (`if FNameSize==12 then ... else ...`) replaced the QWORD read outright. The implementation (`UnrealEngine-75.LUA:68-95`) instead keeps a three-way branch:

```lua
if UEngine.FNameSize==12 then        -- UE5: Number at +8
  number=readInteger(UObjectAddress+UEngine.UObject.Name+8)
elseif UEngine.FNameSize==8 then     -- UE4: Number at +4
  number=readInteger(UObjectAddress+UEngine.UObject.Name+4)
else                                 -- layout not detected yet: legacy QWORD fallback (UE4 layout)
  local i=readQword(UObjectAddress+UEngine.UObject.Name)
  idx=i & 0xffffffff
  name=UEngine.IndexToName[idx]
  number=i >> 32
end
```

The `else` branch preserves pre-detection behavior so `UObject_getName` stays correct even if `UEngine_detectFNameLayout` has not run yet (e.g. during early scanner stages). It also guards `number and number>0` (the proposal only had `number>0`, which would crash on nil). UE5 output is now correct; UE4 output is byte-identical to the old path.

### Detection is more robust than the proposal

The proposal tested `if s4 and s4 == s0 then FNameSize=12`. The implementation (`UEngine_detectFNameLayout`, `UnrealEngine-75.LUA:1002-1061`):

- compares **case-insensitively** (`s4==s0 or s4:lower()==s0:lower()`) because UE5 comparison-table entries are stored lowercase while the `+4` display entry preserves original case — an exact match would miss `GameEngine` vs `gameengine`;
- treats a `+4` resolving to `"None"` as *not* a DisplayIndex (that is the UE4 Number==0 case);
- uses `EngineVersion` (`UEngine_detectEngineVersion`) as the authoritative UE4/UE5 signal, because **shipping UE5 builds compile out `WITH_CASE_PRESERVING_NAME` and have 8-byte FNames indistinguishable from UE4 by the `+4` test alone**;
- cross-checks pointer size: a 4-byte pointer forces UE4 (UE5 never shipped 32-bit);
- forces `UEngine.SCOPositionalSig=false` unconditionally (UE4.26+/UE5 use the `FStaticConstructObjectParameters` signature; Task 7 still refines the rare UE4.25- case by disassembly as planned).

### `UEngine_detectEngineVersion` — ProductVersion first, banner scan as fallback

New function (`UnrealEngine-75.LUA:1075-1132`). Primary: `getFileVersion` on the first module, parsing `ProductVersion` for `%+UE5+Release-<minor>`; fallback: bounded string memscan of the main module for the `%+UE5+Release-` banner. Sets `UEngine.EngineVersion` to just the minor string (e.g. `5.3.2`).

### `UEngine.ObjectArrayNumElements` — hardcoded offsets, not version-gated

The proposal said to validate the field offset against `ObjectArrayListType` / `ObjectArrayEntryStructSize` and leave nil if unresolvable. The implementation (`FindObjectArray`, `UnrealEngine-75.LUA:1314-1327`) hardcodes `NumElements` at `ObjectArray+0x24` and `NumChunks` at `+0x2C`, with a sanity check instead:

```lua
local num=readInteger(UEngine.ObjectArray+0x24)
local numChunks=readInteger(UEngine.ObjectArray+0x2C)
-- NumElements accepted only if 0 < num < 0x10000000 AND num <= numChunks*65536
```

Layout assumption: `ObjObjects` (`FChunkedFixedUObjectArray`) starts at `ObjectArray+0x10` (`Chunks` ptr), `NumElements` at `+0x14` within it (i.e. `+0x24` absolute), `NumChunks` at `+0x1C` (`+0x2C` absolute). If the sanity check fails, `UEngine.ObjectArrayNumElements` is left nil and Task 3 falls back to the memscan path as proposed.

### `UEngine.NameToIndexMin` — implemented in `CacheNamePool`

As proposed (`UnrealEngine-75.LUA:1684-1687`, 1701): per-string minimum index recorded while the pool is enumerated; comparison-table entries allocate first so the lowest index is the one `FName` equality compares. Note it is **not** recorded in `CacheNamePool_old` (the pre-UE5-legacy pool reader) — acceptable, since `NameToIndexMin` exists for the Task 8 `ConsoleKeys`→`Tilde` patch, which targets the modern pool.

### Detection wiring — `UEInfoScanner`, not an orchestrator

The DoD said "runs during PREFLIGHT/DETECT (orchestrator step 1)". The orchestrator (Task 10) does not exist yet; the detection was wired into `UEInfoScanner` immediately after `FindGEngine` and before the SuperStruct walk (`UnrealEngine-75.LUA:2407-2418`):

```lua
if UEngine.EngineVersion==nil then
  UEngine_detectEngineVersion()
end
if UEngine.FNameSize==nil or UEngine.UEFlavour==nil then
  local detectR,detectErr=UEngine_detectFNameLayout()
  if not detectR then
    log('UEngine_detectFNameLayout failed: '..tostring(detectErr))
  end
end
```

This placement guarantees every later name-based comparison (SuperStruct walk, class-name checks) sees correct UE5 names. A failure to detect is logged but does **not** abort the scan — `UObject_getName` still works via the legacy fallback.

### Verification status

1. ✅ UE4 → `FNameSize 8 / UE4` (version path).
2. ✅ UE5 → `FNameSize 12 / UE5` when case preservation is compiled in.
3. ✅ Idempotent: early-return when `FNameSize`/`UEFlavour` already cached (`:1006-1009`).
4. ✅ `UObject_getName(UEngine.GameEngineClass)` returns `GameEngine` on UE5 (no DisplayIndex suffix).
5. ⚠️ `ObjectArrayNumElements` cached only when the chunk sanity check passes; otherwise nil + memscan fallback.

**Note on line references in this file:** the original `UnrealEngine-75.LUA` refs (`CacheNamePool` :1405-1476, `FindObjectArray` :1105-1196, `couldBeUnrealEngine` :2393-2417, `UEngine_findCharacter` :3101) predate this implementation and have all shifted. Current locations are given inline above; prefer function names over line numbers going forward.
