# Task 3 — Step E: Find the `Console` UClass in memory

**Goal:** Implement `UEngine_findClassByName(name)` and use it to locate the `Console` UClass. Read-only.

**Depends on:** Task 2 offset pattern; core state `UEngine.NameToIndex`, `UEngine.ObjectArray`, `UEngine.ObjectArrayListType`, `UEngine.ObjectArrayEntryStructSize`, `UEngine.UObject.Class/Name`, `UObject_getName`, `isVTable`.
**Used by:** Task 4 (ConsoleClass fix), Task 7 (create console), Task 9 (CheatManager).

---

The original plan's hardcoded layout (`numElements = readInteger(UEngine.ObjectArray + 0x08)`, `objectsPtr = readPointer(UEngine.ObjectArray + 0x10)`) is wrong: the scanner already discovers and caches `UEngine.ObjectArray`, `UEngine.ObjectArrayListType` (0 = direct, 1 = chunked), and `UEngine.ObjectArrayEntryStructSize`, and `UObject`'s Class/Name offsets are dynamic (`UEngine.UObject.Class`, `UEngine.UObject.Name`).

**Recommended primary path — FName-index memory scan** (matches the existing `FindGEngine` pattern at UnrealEngine-75.LUA:822-866, version-agnostic, no object-array layout assumptions):

```lua
function UEngine_findClassByName(name)
  local index = UEngine.NameToIndex[name]
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

**Secondary path — walk the object array** using the discovered state. The exact derefs below are taken from `FindObjectArray` (UnrealEngine-75.LUA:1105-1196); validate against the target game's logged `ObjectArrayListType` / `ObjectArrayEntryStructSize` because the layout varies by UE version:

```lua
function UEngine_findClassByName(name)
  local count  = readInteger(UEngine.ObjectArray + 0x08)
  local stride = UEngine.ObjectArrayEntryStructSize
  local target = UEngine.NameToIndex[name]
  local p      = readPointer(UEngine.ObjectArray + 0x10)
  for i = 0, count - 1 do
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

**Priority order:**
1. First find a `UClass` named `Console` (`/Script/Engine.Console`)
2. If that fails, find any object named `Console` and use its class as `ConsoleClass`
3. If nothing found, report failure

Note: in a Shipping build the `Console` UClass is still loaded (native engine classes persist); the CDO (`Default__Console`) also exists in the object array.

---

## Definition of done

- `UEngine_findClassByName('Console')` returns a valid `UClass*` on a Shipping UE4/UE5 target (class name resolves to `Class`).
- Falls back gracefully (returns nil) when the class is absent, without crashing.
- No writes performed.

## Verification

1. Log the resolved name of the found class + its CDO presence (`Default__Console` in object array).
2. Run on both UE4 and UE5 targets; primary path should succeed without the object-array walk.
