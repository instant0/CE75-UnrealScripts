# Task 3 — Step E: Find the `Console` UClass in memory

**Goal:** Implement `UEngine_findClassByName(name)` and use it to locate the `Console` UClass. Read-only.

**Depends on:** Task 1 (FNameSize + `UObject_getName` fix, `UEngine.NameToIndexMin`, `UEngine.ObjectArrayNumElements`), Task 2 offset pattern; core state `UEngine.ObjectArray`, `UEngine.ObjectArrayListType`, `UEngine.ObjectArrayEntryStructSize`, `UEngine.UObject.Class/Name`, `UObject_getName`, `isVTable`.
**Used by:** Task 4 (ConsoleClass fix), Task 7 (create console), Task 9 (CheatManager).

---

The original plan's hardcoded layout (`numElements = readInteger(UEngine.ObjectArray + 0x08)`, `objectsPtr = readPointer(UEngine.ObjectArray + 0x10)`) is wrong: the scanner already discovers and caches `UEngine.ObjectArray`, `UEngine.ObjectArrayListType` (0 = direct, 1 = chunked), and `UEngine.ObjectArrayEntryStructSize`, and `UObject`'s Class/Name offsets are dynamic (`UEngine.UObject.Class`, `UEngine.UObject.Name`).

**Primary path — walk the object array.** Deterministic and cheap: it reuses the object-array layout the scanner already discovered and cached, so no module-wide memscan is needed. The exact derefs below are taken from `FindObjectArray` (UnrealEngine-75.LUA:1105-1196); validate against the target game's logged `ObjectArrayListType` / `ObjectArrayEntryStructSize` because the layout varies by UE version:

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

**Fallback path — FName-index memory scan** (matches the existing `FindGEngine` pattern at UnrealEngine-75.LUA:822-866). Use only when the object array is not scanned, the entry stride is unknown, or `UEngine.ObjectArrayNumElements` is nil. It is a module-wide scan, can return many false 4-byte matches, and is slower and less deterministic than the array walk:

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

Note: this path's `UObject_getName(objClass) == 'Class'` validation depends on the Task 1 fix as well (see above), and when run from a scanner thread it must check `t.Terminated` the same way `FindGEngine` does at UnrealEngine-75.LUA:839.

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
