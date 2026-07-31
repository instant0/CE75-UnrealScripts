# CE 7.5 Reference

Single source of truth for CE 7.5 API, behavior, gotchas, UE5 issues, bugs, source code references, and address list API.

Source code scanned from: `/mnt/y/Lazarus/Projects/cheat-engine-7.5/Cheat Engine/`

---

## Paths

| What | Path |
|------|------|
| Helper scripts | `/home/malware/projects/ue-scan-gothic/` |
| Script 26 (orearmor / GNames step 0) | `.../26_investigate_orearmor_hits.lua` |
| Script 07 (inventory chain) | `.../07_test_full_chain.lua` |
| CE 7.5 source | `/mnt/y/Lazarus/Projects/cheat-engine-7.5/Cheat Engine/` |
| CE75.LUA | `/mnt/d/d/Gamehacking/LUA/CE75.LUA` |

## Key offsets (this game)

| Offset | From → To | Notes |
|--------|-----------|-------|
| **+0x7B0** | Character → Manager | Hardcoded |
| +0x170 | Manager → Container | |
| +0x168 | Container → InventoryManager | |
| +0x378 | InventoryManager → ArrayBase | 0xB8 stride, 383 entries |

**Live status / scripts:** `CE75-STATUS.md` only.  
**MemScan / vartypes / waitTillDone:** `CE75-SCANNING-GUIDE.md` only.  
**Verified API reference (every Lua function + its Pascal source line):** `CE-FUNCTIONS.md` — AOB scans, disassembler, Dissect Code, RIP scanner, `executeCodeEx`/`executeMethod`.

## Document index

| Document | Owns |
|----------|------|
| **CE75-REFERENCE.md** (this) | CE API surface, gotchas, UE5 layouts, dissect, address list |
| CE75-STATUS.md | Project state, priorities, script index |
| CE75-SCANNING-GUIDE.md | MemScan / FoundList |
| **CE-FUNCTIONS.md** | Verified Lua↔Pascal API map (source-verified) |
| CE75-GNAMES-PROPOSAL.md | GNames / FNamePool strategy |
| CE75-INVENTORY.md | Inventory chain & item layouts |
| CE75-DISPLAY-NAMES.md | Localized names |
| CE75-DISSECT-CRASH.md / CE75-VTBINARY-FIX.md | Specific CE bugs |

---

## CE 7.5 Confirmed API

**Use:** `readQword`, `readInteger`, `readPointer`, `readBytes`, `readSmallInteger`, `pcall`, `getAddress`, `getModuleSize`, `AOBScan`, `AOBScanUnique`, `AOBScanModuleUnique`, `createFoundList`, `registerStructureNameLookup`, `registerStructureDissectOverride`, `getStructure`, `getMemoryViewForm`, `getLuaEngine`, `error`, `print`, `string.format`

**Lua:** 5.3 + lnum. `string.format('0x%X')` works. Native bitwise ops. Use `//` not `math.floor`.

---

## CE 7.5 API Differences vs CE 7.7

### Functions that do NOT exist in CE 7.5

| CE 7.7 Function | CE 7.5 Status | Replacement |
|----------------|---------------|-------------|
| `getMemScanResults(ms)` | Does not exist | Use `createFoundList(ms)` + loop over `fl.Address[i]` |
| `readMemory(addr, size)` | Does not exist | Use `readBytes(addr, count, true)` — returns table of byte values (1-based) |
| `readDword(addr)` | Does not exist | Use `readInteger(addr)` for 32-bit reads |
| `readWord(addr)` | Does not exist | Use `readSmallInteger(addr)` for 16-bit reads |
| `getMemoryRegionInfo(addr)` | Does not exist | Use `enumMemoryRegions()` and iterate |
| `enumSectionsOfModule(mod)` | Does not exist | Use `enumMemoryRegions()` |
| `scanMemory(addr, size)` | Does not exist | — |
| `getMemorySize(addr)` | Does not exist | — |
| `dbk_read(addr, size)` | Does not exist | — |
| `readProcessMemory(addr, size)` | Does not exist | — |
| `MemoryStream.readFrom(stream)` | Does not exist | — |
| `MemoryStream.readString` | Does not exist | — |
| `MemoryStream.readWideString` | Does not exist | — |
| `registerCustomTypeAutoAssembler` | Exists but fails | "Incorrect tcc library" — CE 7.5 has no TCC |
| `table.count(t)` | Does not exist | Use manual counter |
| `math.floor(addr)` on 64-bit | Fails | "no integer representation" — use `//` for integer division |

### API name changes

| CE 7.7 | CE 7.5 |
|--------|--------|
| `ReadQword` | `readQword` (lowercase q only — `LuaHandler.pas:16205`) |
| `ms.Result` | Maps to `getOnlyOneResult()` — returns nil when ≠1 result |
| `ms.Results` | Does not exist — use `createFoundList(ms)` |
| `ms.ErrorString` | Returns nil |

### Register API differences

| CE 7.7 | CE 7.5 |
|--------|--------|
| `registerStructureDissectOverride2` | Does not exist — use v1 `registerStructureDissectOverride` |
| `registerCustomTypeLua` | Works for display callbacks but returns 1 for everything in grouped scans |

---

## CE 7.5 Behavior Differences

### `fl.Address[i]` returns hex strings WITHOUT "0x" prefix

**This is the most critical gotcha.**

Source: `LuaFoundlist.pas:77`:
```pascal
lua_pushstring(L, inttohex(foundlist.GetAddress(index), 8))
```

Returns strings like `"7FF68AD0D440"` or `"0000021118356070"`.

- `tonumber("7FF68AD0D440")` → **nil** (hex letters F,A,D fail decimal parsing)
- `tonumber("21118356070")` → **21118356070** (decimal interpretation of hex, wrong value!)

**Fix:** Always prefix: `tonumber('0x' .. fl.Address[i])`

### `readPointer` returns 0 not nil for invalid addresses

CE 7.5 uses `lua_pushinteger` — returns `0` for unreadable memory, never `nil`. Since 0 is truthy in Lua, `if p then` passes. Always use `if p and p~=0 then`.

### `string.format('%x')` WORKS (unlike early concern)

CE 7.5 uses Lua 5.3 with lnum patch: `lua_Integer = long long`, `LUA_INTEGER_FRMLEN = "ll"`. The `str_format` in `lstrlib.c:898-901` transforms `%X` → `%llX`. `sprintf(buff, "%llX", n)` with `long long` is correct on MSVC/Windows x64.

**Do NOT use `string.format('0x%.0f', addr)`** — this prints the **decimal** value with `0x` prefix, which is misleading. Use `string.format('0x%X', addr)`.

### `readQword` crashes on unreadable memory

Wrap in `pcall` throughout.

### `VarType` can only be set on fresh scan

Source: `memscan.pas:8713`:
```pascal
procedure TMemScan.setVariableType(t: TVariableType);
begin
  if fLastScanType=stNewScan then
    fVariableType:=t;
end;
```

Call `newscan()` before changing VarType.

### `ScanWritable`/`ScanExecutable` default behavior

- `ScanWritable='scanInclude'` scans ALL writable pages including PAGE_EXECUTE_READWRITE
- `ScanExecutable` defaults to `scanDontCare` (no filtering) when not set
- Do NOT set `ScanExecutable='scanExclude'` unless you want to lose PAGE_EXECUTE_READWRITE regions

### `readBytes` returns a TABLE, not a string

Index with `data[i]` (1-based). `data[pos]` for byte at offset pos-1.

### Prefer targeted memory scans

Start at known objects; expand ±MB ranges before full-heap. Full-heap is a last resort (slow/freezes CE). Scan hygiene details: `CE75-SCANNING-GUIDE.md`.

### UObjects live in heap, not module static data

Manual UI scan confirms: dword=214131 found 46 hits in writable memory, 0 in module range. Never restrict scans to module range when searching for UObject instances.

### `isInExecutableMainModuleMemory` first branch is dead code

`tostring(Protect):find('execute')` never matches because Protect is a number. Works through fallback branch with numeric table lookup.

### `log` is local to script scope

Defined as `local function` inside `CE75.LUA`. Not accessible from separate Lua command prompts or autorun scripts.

---

## CE 7.5 Gotchas Summary

**Scanning (vartypes, waitTillDone, initialize, protection flags):** see `CE75-SCANNING-GUIDE.md` — do not copy recipes here.

1. **`firstScan` order** — `scanOption` first, then `TVariableType`. Wrong order → `"Failure determining what %s means"`.
2. **`TVariableType`:** `vtString=6`, `vtUnicodeString=7`, `vtByteArray=8` (`commontypedefs.pas`). Never treat 7 as “string”.
3. **`fl.Address[i]`** — hex without `0x`; use `tonumber('0x' .. fl.Address[i])` after `fl.initialize()`.
4. **`readPointer` → 0 not nil** — `if p and p ~= 0 then`.
5. **`string.format('%X')` works** — do not use `%.0f` for addresses.
6. **`readBytes` → 1-based table**.
7. **No `getMemoryRegionInfo` / `readDword` / `readWord`** — `enumMemoryRegions()`, `readInteger`, `readSmallInteger`.
8. **`readQword`** — lowercase; wrap unreadable addrs in `pcall`.
9. **`math.floor` on 64-bit addrs** — prefer `//`.
10. **`VarType` only on fresh scan** — `newScan` / new MemScan.
11. **BoolProperty in address list** — use `vtByte` until dissect vtBinary patch (`CE75-VTBINARY-FIX.md`).
12. **`mr.Offset[i]` for i>1** — AV; use pointer expression string in `mr.Address`.
13. **`log` local to CE75.LUA** — use `print` from other scripts.
14. **Dissect empty TreeView crash** — `CE75-DISSECT-CRASH.md`.
15. **`AOBScan`** — capital A; returns **StringList** of hex addrs (`fl[i]`) or **nil** if empty — not FoundList.

---

## UE5-Specific Issues

### FField has no vtable — `findStructureStart` fails

In UE4, `FProperty` inherits from `UObject` and has a vtable at offset 0. `findStructureStart` walks backward to find this vtable.

In UE5, `FField` does NOT inherit from `UObject` and has NO vtable. `findStructureStart` walks backward into wrong memory.

**UE5 FField layout:**
```
+0:  ClassPrivate (FFieldClass*) — 8 bytes
+8:  OwnerPrivate (UStruct*/FField*) — 8 bytes, lowest bit is tag
+16: Name (FName: ComparisonIndex + Number) — 8 bytes
+24: Next (FField*) — 8 bytes, NULL if last property
+28: ElementSize — 4 bytes
+32+: More FField/FProperty fields (Offset_Internal, etc.)
```

**Fix:** The vtDword scan finds ComparisonIndex at `r[i]` = FField+16. So FField starts at `r[i] - 16`. Verify by checking:
1. `readPointer(r[i]-16)` is a valid FFieldClass pointer
2. `readPointer(r[i]-8) & 0xfffffffffffffff8` == GameEngineClass

### `UClass->Class` points to itself in UE5 → infinite loop

`getSuperListFromObject` follows the `UObject.Class` pointer, then walks `SuperClass` up the class hierarchy. In UE5, `UClass->Class` points to itself (`UClass::StaticClass()`), creating an infinite loop.

**Fix:** Use `SuperStruct` chain (offset 64 in this game) instead. SuperStruct is the instance-level inheritance chain (UGameEngine → UEngine → UObject).

### FName Number field often non-zero

`vtQword` scans for name indices fail when the Number field (upper 32 bits) is non-zero. The ComparisonIndex is the lower 32 bits.

**Fix:** Always use `vtDword` when scanning for FName indices.

### FNameEntry strings and Lua scans

FNameEntry data has **no NUL** after the chars. That does **not** block ANSI `vtString` (`TVariableType=6`): CE compares a fixed length only.

Earlier 0-hit tests used **`vartype=7` (Unicode)** and/or skipped `waitTillDone`/`initialize`. Full correction: `CE75-SCANNING-GUIDE.md`.

**Use:** case-insensitive `vtString=6` for text; `vtByteArray=8` + hex for exact bytes/pointers.

---

## UObject Layout (UE5, this game)

```
+0x00: vftable (QWORD, game module)
+0x08: ObjectFlags (QWORD, packed)
+0x10: ClassPrivate (QWORD → UClass)
+0x18: NameIndex (DWORD → NamePool)
```

**NamePool resolution:** GNames base is **session-dynamic** (old `exe+0x9AE6600` often 0). Prefer discover via script 26 / proposal approaches.
- `block = Index >> 16`, `offset = Index & 0xFFFF` (if BlockOffsetBits=16)
- `entry = Blocks[block] + offset * 2` (stride 2)
- header Format A: `len = (hdr >> 6) & 0x3FF`; string at entry+2

---

## v1 Structure Dissect Callback

### API

```lua
registerStructureDissectOverride(callback)
-- callback(structure, address) → boolean
-- structure: the dissect form's structure object (already created)
-- address: the memory address being dissected
-- return true on success, false on failure
```

CE 7.7's `registerStructureDissectOverride2` (which creates the structure) does not exist in CE 7.5. The v1 callback receives an existing structure and fills it.

### Trigger flow

The callback fires **only** when:
1. User opens the Structure Dissect window (via "Dissect data" from memory view)
2. User clicks "Structure" → "Define new structure"
3. User enters a name and clicks OK
4. User clicks "Yes" on the "fill in basic types" dialog

It does **NOT** fire when just opening the dissect window or setting an address.

### Dissect window quirk

If the dissect window was previously opened, "Dissect data" just shows the old window without updating the address. Close existing dissect windows first, then reopen.

### `structure.Name` must be set AFTER adding elements

Setting `structure.Name` triggers `DoFullStructChangeNotification` (`LuaStructure.pas:58`) which fires a UI refresh. If set before elements are added, the UI refreshes with an incomplete structure, causing display issues. Set Name as the last operation after all elements are added.

### UObject base fields

`UClass_enumProperties` walks the PropertyLink chain which only contains FProperty-based fields. The base UObject layout (vtable, Class, Name) is not part of this chain.

The v1 callback adds these base fields:
- `vftable` at offset 0 (pointer)
- `Class` at offset `UObject.Class` (pointer)
- `Name` at offset `UObject.Name` (FName custom type)

**Note:** `SuperStruct` (offset 64) and `PropertyLink` (offset 136) are CLASS-level offsets in the UClass object, not instance-level. They must NOT be added as base fields in instance structures — doing so reads wrong data and can crash the structure form.

### Ctrl+G bracket behavior

- `gengine` → navigates to the GEngine UObject instance
- `[gengine]` → dereferences the pointer at GEngine's address → navigates to the vtable

When dissecting the vtable address, the callback fires but `readPointer(address + UObject.Class)` returns garbage (vtable entries, not UObject pointers), so the callback returns false.

### Dissect form crash on empty TreeView

v1 callback fires with "list index (0) out of bounds" when dissect form has no existing structures. Must pre-create a seed structure first. See `CE75-DISSECT-CRASH.md` for full analysis and workaround.

---

## Address List API (CE 7.5)

### Creating records

```lua
local fl = getAddressList()
local mr = fl.createMemoryRecord()
mr.Description = "Name"
mr.Address = "GEngine+10A8"       -- symbol + offset string
mr.VarType = vtPointer             -- or vtByte, vtDword, etc.
mr.IsGroupHeader = true            -- for groups
mr.Parent = parentMR               -- nest under parent
mr.ChildStruct = getStructure('widestring')
mr.ByteSize = sz                   -- for vtByteArray
```

### Setting multi-level pointer addresses

CE 7.5 `mr.Offset[i]` for i>1 causes access violation. Instead, build a full CE pointer expression string:

```lua
mr.Address = "[[[[[GEngine+10A8]+100]+0]+30]+2E0]"
```

- Each `]+offset` adds one dereference level
- Final `+offset` outside brackets is a raw add (no dereference)
- Use `string.rep('[', n)` for the opening brackets

### BoolProperty as vtByte

BoolProperty entries are added as `vtByte` in the address list. This is correct for CE 7.5:

- CE 7.5 structure dissect has NO `vtBinary` support (shows "???")
- CE 7.5 **memory table** (`TMemoryRecord`) fully supports binary display via `extra.bitData`
- `vtByte` displays the raw byte value — adequate for single-bit bool checks
- If the dissect vtBinary patch is applied (see `CE75-VTBINARY-FIX.md`), we can switch to `vtBinary` for more precise display

---

## Known Bugs Fixed

### Bug list (16 total)

| # | Bug | Root Cause | Fix |
|---|-----|-----------|-----|
| 1 | `ReadQword` crash | CE 7.5 only registers lowercase `readQword` | Changed to `readQword`, wrapped in pcall |
| 2 | Lua syntax error `malformed number near '4..'` | `j*4..` parsed as float literal | Wrapped in parens: `(j*4)` |
| 3 | `findGameInstanceFPropertyAndFields` error lost | Only first return captured | `r,err=...` |
| 4 | `vtQword` scan returns 0 results | FName Number field non-zero in UE5 | Changed to `vtDword` |
| 5 | `ms.Result` wrong API | Maps to `getOnlyOneResult()`; nil with ≠1 result | Use `createFoundList(ms)` + `fl.Address[i]` |
| 6 | `getMemScanResults` unavailable from raw console | Only works inside loaded scripts | Use `createFoundList(ms)` API |
| 7 | Defensive nil guards | Multiple functions crash on nil inputs | Guards on `getSuperListFromField`, `UClass_enumProperties`, `GetLinkedListSize`, `PropertyLinkNext` |
| 8 | Unsafe memory reads | `readQword` crashes on unreadable memory | Wrapped in pcall throughout |
| 9 | Diagnostic logging | Hard to debug pipeline failures | Added at every decision point |
| 10 | Python `elseif` counting bug | `\bif\b` regex does NOT match `elseif` | Removed `elseif` subtraction |
| 11 | UE5 FField no vtable | `findStructureStart` walks into wrong memory | Try `r[i]-16` (FField start), verify ClassPrivate/OwnerPrivate, fallback to UE4 vtable |
| 12 | Scan loop stops at NULL | `pp==0` breaks before reaching last field | Only break on `nil` (unreadable), not `0` |
| 13 | `UEngine.FProperty={}` overwrite | Detection block set values, line 419 wiped them | `if not UEngine.FProperty then` guard |
| 14 | `getSuperListFromObject` infinite loop | `UClass->Class` points to itself in UE5 | Cycle detection + use `SuperStruct` chain instead |
| 15 | `ChildClassName` bug | Was literal string `'Type: 0x..string.format(...)'` | Now reads UObject name via `UObject_getName` |
| 16 | v1 callback missing UObject base fields | Only FProperty fields from PropertyLink chain | Added vftable, Class, Name base fields |

### Bug details

**Bug #4 — `vtQword` scan for FName index:**
FName in memory: `[int32 ComparisonIndex] [uint32 Number]`. When Number ≠ 0, the 8-byte QWORD doesn't equal the raw index. `vtDword` scans 4-byte windows matching only ComparisonIndex regardless of Number.

**Bug #11 — UE5 FField no vtable:**
The vtDword scan finds FName ComparisonIndex at `r[i]` = FField+16. Subtracting 16 gives FField start. Verify with ClassPrivate pointer and OwnerPrivate back-pointer.

**Bug #14 — UE5 UClass self-reference:**
`UClass->Class` (offset 16) points to `UClass::StaticClass()` which has `Class->Class` pointing to itself. `getSuperListFromObject` follows this chain and loops forever. Fix: use SuperStruct chain (offset 64) which follows instance-level inheritance.

**Bug #15 — `ChildClassName` literal string:**
Was: `e.ChildClassName='Type: 0x'..string.format('0x%X',classPtr)` (literal string, not evaluated). Now: `e.ChildClassName=UObject_getName(classPtr)` (reads actual UObject name).

**Bug #16 — Missing UObject base fields:**
`UClass_enumProperties` walks PropertyLink chain (FProperty fields only). Base UObject layout (vftable, Class, Name) not in chain. Without base fields, structure starts at first FProperty offset (e.g., 0x30) with no object header visibility.

---

## Source Code Reference

All source at: `/mnt/y/Lazarus/Projects/cheat-engine-7.5/Cheat Engine/`

| Component | File | Key Details |
|-----------|------|-------------|
| Lua-Pascal bridge | LuaHandler.pas (17,295 lines) | All global functions; uses `lua_pushinteger` for all address values |
| MemScan engine | memscan.pas | TMemScan class; firstScan/nextScan |
| MemScan Lua wrapper | LuaMemscan.pas (333 lines) | `scan()` is just dispatcher; properties via Delphi RTTI |
| FoundList data | foundlisthelper.pas | TFoundList class, address cache (1024 entries) |
| FoundList Lua wrapper | LuaFoundlist.pas (133 lines) | `fl.Address[i]` returns hex string without "0x" prefix |
| Class wrapping | LuaClass.pas | `luaclass_newClass`, `__newindex` RTTI fallback |
| Symbol handler | symbolhandler.pas | `getNameFromAddress`, `getAddressFromNameL` |
| Memory regions | memoryquery.pas | `isExecutableAddress` |
| Custom types | CustomTypeHandler.pas | `registerCustomTypeLua`, `registerCustomTypeAutoAssembler` (fails: no TCC) |
| Structure dissect form | StructuresFrm2.pas | `addColumn` at 5569, override invocation at 4476/4586 |
| Structure dissect form (open) | MemoryBrowserFormUnit.pas:1996 | `miDissectData2Click` reuses old form without updating address |
| Structure object | LuaStructure.pas | `addColumn` at 5569, `structure_setName` at 58 |
| registerStructureDissectOverride | LuaHandler.pas:16809 | v1 callback registration |
| v1 callback invocation | LuaCaller.pas:1213-1232 | Passed `structure` object + `address` |

### Lua-Pascal bridge values (LuaHandler.pas)

All memory/symbol functions use `lua_pushinteger`, returning proper 64-bit Lua integers (LUA_TINTEGER), NOT floats. Addresses maintain full precision as long as they stay as Lua integers.

Key examples:
- `readQwordEx` (line 2006): `lua_pushinteger(L, v)`
- `readPointer` (line 2036): dispatches to `readQword` for 64-bit
- `getAddress` (line 4572): `lua_pushinteger(L, symhandler.getAddressFromNameL(s))`
- `getModuleSize` (line 4487): `lua_pushinteger(L, mi.basesize)`
- `inModule` (line 4626): `lua_pushboolean(L, symhandler.inModule(address))`

### MemScan property system

Properties are set via Delphi RTTI (`SetPropValue`). No specific order required. All stored as fields and read at scan time via `scanController.scanWritable := scanWritable` etc. (`memscan.pas:8569`).

Published properties include: `VarType`, `ScanOption`, `Scanvalue`, `Scanvalue1`, `Scanvalue2`, `Startaddress`, `Stopaddress`, `Hexadecimal`, `Fastscanmethod`, `Fastscanparameter`, `scanWritable`, `scanExecutable`, `scanCopyOnWrite`.

---

## UE5 Reference Structures

### FNamePool (UE5.4)

```c
struct FNamePool {
    FRWLock Lock;           // 0x00 (8 bytes) — SRWLOCK
    uint32_t CurrentBlock;  // 0x08
    uint32_t CurrentByteCursor; // 0x0C
    uint8_t* Blocks[8192];  // 0x10 — array of chunk pointers
};

struct FNameEntry {
    uint16_t Header;
    // Format A (older UE4/early UE5):
    //   bit 0:     isWide (0 = ANSI, 1 = UTF-16)
    //   bits 1-5:  probe hash (for case-insensitive lookup)
    //   bits 6-15: string length (max 1024)
    // Format B (newer UE5):
    //   bit 0:     isWide
    //   bits 1-11: string length (max 2047)
    char Data[];            // ANSI or UTF-16, no null terminator
};
```

### FName Resolution

```c
struct FName {
    uint32_t ComparisonIndex;  // 0x00 — index into FNamePool
    int32_t Number;            // 0x04 — instance number (0 = no suffix)
};
// sizeof(FName) = 0x08
```

**Resolution formula**:
```
block  = ComparisonIndex >> FNameBlockOffsetBits  // typically 16
offset = ComparisonIndex & ((1 << FNameBlockOffsetBits) - 1)
entryAddr = FNamePool.Blocks[block] + (offset * Stride)  // Stride = 2
header = read uint16 at entryAddr
len = header >> 6  // (Format A) or header >> 1 (Format B)
isWide = header & 1
stringAddr = entryAddr + 2
```

### Validation

Entry 0 must be "None". Next entries (stable order):
1. "None"
2. "ByteProperty"
3. "IntProperty"
4. "FloatProperty"
5. "BoolProperty"
6. "ObjectProperty"

### GNames Location

GNames is a global pointer, typically stored in:
- Module `.data` section (most common)
- Member of `GUObjectArray` or `GEngine`
- Static member of `FName` class

**Search strategy**: AOBScan for LEA instruction that loads GNames, or validate candidates by checking entry[0] == "None".

### Chunks Offset

The offset from the FNamePool base to the Blocks[] array varies:
- Standard: 0x10 (lock + currentBlock + currentByteCursor)
- Some builds: 0x00 (address points directly to blocks)
- Others: 0x08, 0x20, 0x40

### BlockOffsetBits

How many bits of the FName index are used for within-chunk offset:
- Standard UE5: 16 bits (chunk = Index >> 16, offset = Index & 0xFFFF)
- Some UE4 builds: 14 bits
- Must be auto-detected per game build
