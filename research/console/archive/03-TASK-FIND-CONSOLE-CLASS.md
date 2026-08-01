# Task 3 — Step E: Find the `Console` UClass in memory

**Goal:** Implement `UEngine_findClassByName(name)` and use it to locate the `Console` UClass. Read-only.

**Depends on:** Task 1 (FNameSize + `UObject_getName` fix, `UEngine.NameToIndexMin`, `UEngine.ObjectArrayNumElements`), Task 2 offset pattern; core state `UEngine.ObjectArray`, `UEngine.ObjectArrayListType`, `UEngine.ObjectArrayEntryStructSize`, `UEngine.UObject.Class/Name`, `UObject_getName`, `isVTable`.
**Used by:** Task 4 (ConsoleClass fix), Task 7 (create console), Task 9 (CheatManager).

---

The original plan's hardcoded layout (`numElements = readInteger(UEngine.ObjectArray + 0x08)`, `objectsPtr = readPointer(UEngine.ObjectArray + 0x10)`) is wrong: the scanner already discovers and caches `UEngine.ObjectArray`, `UEngine.ObjectArrayListType` (0 = direct, 1 = chunked), and `UEngine.ObjectArrayEntryStructSize`, and `UObject`'s Class/Name offsets are dynamic (`UEngine.UObject.Class`, `UEngine.UObject.Name`).

**Primary path — walk the object array.** Deterministic and cheap: it reuses the object-array layout the scanner already discovered and cached, so no module-wide memscan is needed. The exact derefs below are the ones implemented in `UEngine_findNameTestAddress` (UnrealEngine-75.LUA:958) and `FindObjectArray` (UnrealEngine-75.LUA:1439); validate against the target game's logged `ObjectArrayListType` / `ObjectArrayEntryStructSize` because the layout varies by UE version:

```lua
function UEngine_findClassByName(name, t)
  local count  = UEngine.ObjectArrayNumElements     -- cached by Task 1 (NOT ObjectArray+0x08)
  if count == nil then return nil, 'ObjectArrayNumElements not cached (Task 1)' end
  local stride = UEngine.ObjectArrayEntryStructSize
  local target = (UEngine.NameToIndexMin and UEngine.NameToIndexMin[name])
                 or UEngine.NameToIndex[name]       -- lowest index = comparison-table entry (Task 1)
  local p      = readPointer(UEngine.ObjectArray + 0x10)
  for i = 0, count - 1 do
    if t and t.Terminated then return nil, 'terminated' end
    local obj = nil
    if UEngine.ObjectArrayListType == 1 then   -- chunked: p is a chunk table (pointer-sized entries)
      local chunk = readPointer(p + math.floor(i / 65536) * processhandler.pointersize)
      obj = readPointer(chunk + (i % 65536) * stride)
    else                                        -- direct: p points at the element array
      obj = readPointer(readPointer(p) + i * stride)
    end
    if obj and obj ~= 0 then
      local objClass = readPointer(obj + UEngine.UObject.Class)
      if objClass and UObject_getName(objClass) == 'Class' and readInteger(obj + UEngine.UObject.Name) == target then
        return obj
      end
    end
  end
  return nil
end
```

The name test `readInteger(obj + UEngine.UObject.Name) == target` compares the ComparisonIndex dword directly — layout-safe on both UE4 and UE5 (ComparisonIndex sits at `+0` of the FName in both flavours). The class test `UObject_getName(objClass) == 'Class'` is correct on both flavours **only after the Task 1 `UObject_getName` FNameSize fix has run** — before that, UE5 names resolve with a DisplayIndex suffix and this walk silently returns nil.

**Fallback path — FName-index memory scan** (matches the existing `FindGEngine` pattern at UnrealEngine-75.LUA:827-903). Use only when the object array is not scanned, the entry stride is unknown, or `UEngine.ObjectArrayNumElements` is nil. It is a module-wide scan, can return many false 4-byte matches, and is slower and less deterministic than the array walk:

```lua
function UEngine_findClassByName(name, t)
  local index = (UEngine.NameToIndexMin and UEngine.NameToIndexMin[name])
                or UEngine.NameToIndex[name]       -- lowest index = comparison-table entry (Task 1)
  if index == nil then return nil end
  local ms = createMemScan()
  ms.VarType = vtDword
  ms.Fastscanmethod = fsmAligned
  ms.Fastscanparameter = 4
  ms.Scanvalue = index
  ms.ScanWritable = 'scanInclude'
  ms.scan() ms.waitTillDone()
  local r = getMemScanResults(ms)
  ms.destroy() ms = nil
  for i = 1, #r do
    if t and t.Terminated then return nil, 'terminated' end
    local obj = r[i] - UEngine.UObject.Name
    local objClass = obj > 0 and readPointer(obj + UEngine.UObject.Class) or 0
    -- a UClass has Class -> a UClass whose own name is "Class"
    if objClass and objClass ~= 0 and UObject_getName(objClass) == 'Class' and isVTable(readPointer(obj)) then
      return obj
    end
  end
  return nil
end
```

Note: this path's `UObject_getName(objClass) == 'Class'` validation depends on the Task 1 fix as well (see above), and when run from a scanner thread it must check `t.Terminated` the same way `FindGEngine` does at UnrealEngine-75.LUA:848.

**Priority order:**
1. Object-array walk (primary).
2. FName-index memscan (fallback).
3. First find a `UClass` named `Console` (`/Script/Engine.Console`); if that fails, find any object named `Console` and use its class as `ConsoleClass`; if nothing found, report failure.

Note: in a Shipping build the `Console` UClass is still loaded (native engine classes persist); the CDO (`Default__Console`) also exists in the object array.

---

## Definition of done

- `UEngine_findClassByName('Console')` returns a valid `UClass*` on a Shipping UE4/UE5 target (class name resolves to `Class`).
- Falls back gracefully (returns nil) when the class is absent, without crashing.
- No writes performed.

## Verification

1. Log the resolved name of the found class + its CDO presence (`Default__Console` in object array).
2. Run on both UE4 and UE5 targets; the primary path (object-array walk) should succeed without the memscan fallback.

---

## Implementation log — 2026-07-31

Task 3 was implemented in `UnrealEngine-75.LUA` as three functions plus a scanner wiring block:

- `UEngine_nameTargetIndex(name)` (`:1251`) — ComparisonIndex dword for a name, shared by both finders.
- `UEngine_findObjectByName(name, t)` (`:1268`) — object-array walk, name-index match only; also the reusable CDO-detection walk Task 5 needs.
- `UEngine_findClassByName(name, t)` (`:1316`) — primary walk + automatic FName-index memscan fallback.
- Scanner wiring (`:2814-2852`) — locates the `Console` class, caches `UEngine.ConsoleClassAddr`, logs class name + CDO presence. Runs inside `UEInfoScanner` right after the Task 2 block (read-only, best-effort).

### Deviations from the proposal

1. **Split into two functions.** The proposal's inline primary path checked name and class in one pass. The implementation separates name matching (`UEngine_findObjectByName`) from class validation (`UEngine_findClassByName`): the walk short-circuits on the name dword first (most objects never match), then validates the 1–2 survivors. `UEngine_findObjectByName` is exported because Task 5's `consoleCDO`/`cheatCDO` gates need exactly this walk ("reusing the Task 3 walk").
2. **`UEngine_nameTargetIndex` — FNameSize-aware target.** The proposal used `NameToIndexMin[name]` directly. That is correct for the project's target (Shipping UE5 / UE4: single case-sensitive table, 8-byte FNames), but **wrong on UE5 `WITH_CASE_PRESERVING_NAME` builds** (FNameSize==12): comparison-table entries are stored lowercased, so the object's `+0` ComparisonIndex resolves to e.g. `"console"` while the exact-case string `"Console"` only exists in the display table (a higher block-1 index). `UEngine_nameTargetIndex` therefore also looks up `name:lower()` and takes the minimum index — comparison block-0 indexes are always lower than display block-1 indexes, so the min is the ComparisonIndex. The `FNameSize==12` guard keeps Shipping/UE4 exact-case (where a lowercase variant, if present, is a *different* FName that must not win).
3. **Case-insensitive `'Class'` validation.** The proposal's `UObject_getName(objClass) == 'Class'` breaks on non-shipping UE5 for the same reason (`UObject_getName` resolves the ComparisonIndex to `"class"`). The implementation compares `string.lower(UObject_getName(objClass)) == 'class'` — identical behavior on Shipping, correct on case-preserving UE5.
4. **Automatic memscan fallback.** The proposal returned a hard error when `ObjectArrayNumElements` was nil, which contradicts the fallback's stated purpose. The implementation falls through to the memscan whenever the walk fails *for any reason* (array not scanned, stride/count unknown, or a same-named instance rather than a class).
5. **Console-specific resolution in the scanner.** Priority order 3 ("any object named `Console` → use its class") is implemented in the wiring, with an added third rung: if no object named exactly `Console` exists, use the CDO `Default__Console`'s class. The proposal's own note says the CDO persists in Shipping, so it is the most reliable native source when the class object is renamed/stripped. Result cached as `UEngine.ConsoleClassAddr` (guarded by `if UEngine.ConsoleClassAddr==nil` — idempotent, consistent with Tasks 1/2).
6. **Stale references fixed** (see inline edits): `FindObjectArray` derefs now cited at `:1439` / `UEngine_findNameTestAddress` `:958` (was `:1105-1196`), `FindGEngine` pattern at `:827-903` (was `:822-866`), `t.Terminated` example at `:848` (was `:839`).

### Verification status

1. ✅ Scanner wiring logs the resolved class name and CDO presence (`Default__Console`).
2. ⚠️ Primary walk exercised only if a UE4/UE5 target is attached; the FNameSize==12 branch is untested in the field (Shipping targets don't hit it).

### Note for Tasks 4/7/9

Use `UEngine.ConsoleClassAddr` (cached at scan time) or call `UEngine_findClassByName('Console')` at repair time — both return the `Console` UClass. The memscan fallback inside `UEngine_findClassByName` is safe to call outside the scanner thread (no `t` argument → no termination checks), but prefer the cache to avoid a module-wide scan on every repair.
