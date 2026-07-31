# Task 1 — Phase 1: Layout Detection (UE4 vs UE5)

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
