# CE 7.5 Structure Dissect Crash: "list index (0) out of bounds"

**Status:** ROOT CAUSE + WIPING BUG FIXED in CE75.LUA

---

## Two separate bugs

### A) Empty TreeView crash
When the **global structure list is empty**, the v1 dissect override hits:
```
StructureDissectEvent: Lua Function error(list index (0) out of bounds)
```

**Workaround:** Always keep at least one structure in the global list  
→ `DO_NOT_DELETE_PLACEHOLDER` (1 byte element).

### B) Script wiped ALL structures (the real “launch deletes everything”)
CE 7.5 API:
```pascal
// LuaStructure.pas — INDEX ONLY
getStructure(i) → DissectedStructs[i]
```

Old CE75 code did:
```lua
getStructure('GameEngine')   -- string coerces to integer 0!
remove / destroy             -- deletes index 0
-- loop 20× → wipes entire list
```

So every `LaunchUEInfoScanner` / `ensureGameEngineStructure` **destroyed every structure starting at index 0**, then failed to rebuild, then dissect crashed.

---

## Fix (current CE75.LUA)

| Rule | Implementation |
|------|----------------|
| Never `getStructure(name)` | `UEngine_findStructureByName(name)` scans `getStructure(i).Name` |
| Always keep placeholder | `UEngine_ensureDissectSeed()` → `DO_NOT_DELETE_PLACEHOLDER` |
| Never delete placeholder | `UEngine_removeStructuresNamed` refuses placeholder / `UE_Seed` |
| Update GameEngine in place | Clear elements + refill; only recreate if fill fails |
| Seed before create/remove | Placeholder asserted before and after GameEngine work |

### Launch flow
1. Scanner finds GEngine  
2. Main thread: `ensureDissectSeed` → register callbacks → `ensureGameEngineStructure`  
3. If `GameEngine` exists → **update** (no full list wipe)  
4. Else create `GameEngine` while placeholder stays  

### Manual recovery (if list already empty)
```lua
UEngine_ensureDissectSeed()
-- optional if scanner already done:
UEngine_ensureGameEngineStructure()
```

Or GUI: create any 1-byte structure, rename to `DO_NOT_DELETE_PLACEHOLDER`, then re-run scanner.

---

## Do not
- Call `getStructure('AnyName')` — always index 0  
- Remove/destroy all structures before dissect callbacks  
- Delete `DO_NOT_DELETE_PLACEHOLDER`  

---

## Related
- `CE75.LUA`: `UEngine_findStructureByName`, `UEngine_ensureDissectSeed`, `UEngine_ensureGameEngineStructure`
- CE source: `LuaStructure.pas` `getStructure` → `DissectedStructs[i]`
