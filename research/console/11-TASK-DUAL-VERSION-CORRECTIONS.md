# 11-TASK-DUAL-VERSION-CORRECTIONS.md

Dual-version audit (UE4.x + UE5.x) of Tasks 01-10 and the Lua implementation.
Goal: every offset/layout/flag claim must hold for BOTH UE4.x and UE5.x, or be
explicitly version-gated. Source authority: local UE5.4.0 source + UE4 mirror in
`/tmp/opencode/` (UE4.11 files). EPIC NOTE: shipping games build UE with
`WITH_EDITORONLY_DATA=0`, which is the critical fact driving several fixes below.

---

## 1. MAJOR — FName layout: `{ComparisonIndex, Number, DisplayIndex}` (both versions)

### Ground truth (UE5.4 `Core/Public/UObject/NameTypes.h:1107-1117`)
```cpp
private:
	FNameEntryId	ComparisonIndex;              // +0   uint32 (name-pool index)
#if !UE_FNAME_OUTLINE_NUMBER                     // UE_FNAME_OUTLINE_NUMBER defaults to 0
	uint32			Number;                       // +4   (0 = no numeric suffix)
#endif
#if WITH_CASE_PRESERVING_NAME
	FNameEntryId	DisplayIndex;                 // +8   (only in editor-ish builds!)
#endif
```
- `WITH_CASE_PRESERVING_NAME = WITH_EDITORONLY_DATA` (`NameTypes.h:30-31`).
- `UE_FNAME_OUTLINE_NUMBER = 0` (`NameTypes.h:36-38`).

### Consequence 1: `UObject_getName` UE5 branch is wrong
`UnrealEngine-75.LUA:91` claims UE5 `{ComparisonIndex, DisplayIndex, Number}` and
reads **Number at +8**. Real layout has **Number at +4** in BOTH versions, and
DisplayIndex at +8 (editor builds only). For shipping builds FName is 8 bytes in
BOTH UE4 and UE5, so **Number is at +4 always**. Fix (see section 7):

```lua
number=readInteger(UObjectAddress+UEngine.UObject.Name+4)  -- +4 in BOTH sizes
```

### Consequence 2: FNameSize detection must not assume version
Task 1's detector ("UE5 12-byte FName, UE4 8-byte") is wrong because shipping
UE5.4 has **8-byte FName identical to UE4** (DisplayIndex compiled out).
The 12-byte form only exists in editor/dev (`WITH_EDITORONLY_DATA`) builds.
Real 12-byte layout: `+4`=Number, `+8`=DisplayIndex (DisplayIndex mirrors
ComparisonIndex for case-preserving names). Detection heuristic:

```
idx  = readInteger(off+0)   # ComparisonIndex
num  = readInteger(off+4)   # Number (0 for ordinary names)
dpy  = readInteger(off+8)
12-byte (editor UE5) if num==0 and dpy==idx
8-byte  otherwise (shipping UE5 AND all UE4)
```
Default path (legacy QWORD `{idx,number}`) is already correct for shipping
both versions — keep it as fallback, just fix the +8 read.

---

## 2. MAJOR — `FStaticConstructObjectParameters` layout (Task 7 crux)

### Ground truth (UE5.4 `CoreUObject/Public/UObject/UObjectGlobals.h:1594-1640`)
```cpp
struct FStaticConstructObjectParameters
{
	const UClass*              Class;                              // +0x00
	UObject*                   Outer;                              // +0x08
	FName                      Name;                               // +0x10 (fnameSize bytes)
	EObjectFlags               SetFlags;                           // +0x10+fnameSize
	EInternalObjectFlags       InternalSetFlags;                   // +4 after SetFlags
	bool                       bCopyTransientsFromClassDefaults;   // 1 byte
	bool                       bAssumeTemplateIsArchetype;        // 1 byte
	UObject*                   Template;                           // align8 after bools
	FObjectInstancingGraph*    InstanceGraph;
	UPackage*                  ExternalPackage;
	TFunction<void()>          PropertyInitCallback;
private:
	FObjectInitializer::FOverrides* SubobjectOverrides;
};
```
- Consumption confirmed: `UObjectGlobals.cpp:4416` reads Params.Class / Outer /
  Name / SetFlags / Template first.

### Corrected Template offsets (UE5.4, both FName sizes)
```
FName=8 : SetFlags 0x18 | Internal 0x1C | bool1 0x20 | bool2 0x21 | Template = 0x28
FName=12: SetFlags 0x1C | Internal 0x20 | bool1 0x24 | bool2 0x25 | Template = 0x28
```
**Template = 0x28 for BOTH FName sizes in UE5.** Task 7's formula
`align8(internalOff+4)` yields 0x20 (FName=8) / 0x28 (FName=12) — correct for
UE5/FName=12, WRONG for UE5/FName=8. Because both bools exist in UE5.

### Fake fields that DO NOT exist (must delete from Task 7)
- `bAllowNativeClassCreation` — not in UE5.4 struct.
- "UE5.1+ InitializationOptions" — no such trailing field. Real trailing fields:
  `InstanceGraph`, `ExternalPackage`, `PropertyInitCallback`, `SubobjectOverrides`.

### UE4.26/4.27 status — UNVERIFIED, must be runtime-verified
UE4.11 mirror in `/tmp/opencode/` predates `FStaticConstructObjectParameters`
(introduced UE4.26), so the exact UE4.26/4.27 struct cannot be confirmed from
the local UE4 source. Unknown: whether the two bools exist before UE5.
- If bools ABSENT in UE4: Template = 0x20 (FName=8) / 0x28 (FName=12) — matches
  Task 7's original formula for FName=8.
- If bools PRESENT in UE4.27: Template = 0x28 (both sizes) — same as UE5.

Runtime verification step (mandatory before relying on the offset):
1. Fill what we believe is `Template` at +0x28 with the Console `UClass*`.
2. Execute `StaticConstructObject_Internal`; the returned `UObject*` must be a
   valid vftable'd object whose `NamePrivate` == "Console".
3. If the object is invalid or name mismatch, try +0x20 (no-bools UE4 layout)
   and re-verify. Log which offset won.

---

## 3. MAJOR — `FKey` layout: `{FName KeyName; TSharedPtr<FKeyDetails>}` (Task 8)

### Ground truth (UE5.4 `InputCore/Classes/InputCoreTypes.h:49-123`)
```cpp
struct FKey
{
	FName KeyName;
	mutable TSharedPtr<FKeyDetails> KeyDetails;
};
```
NOT `{FName; TArray<const FKeyDetails*, TInlineAllocator<4>>}` as Tasks 5/8 claim.
- Patch path unchanged in spirit: we only need to set `KeyName` (FName at +0 of
  the FKey) = `FName(EnumToName(PConsoleKey))`. We never touch `KeyDetails`.
- TSharedPtr is a pointer-sized (or pointer+refcount in ThreadSafe mode) member;
  we do NOT construct it. Leave it zeroed/null. `GetKeyDetails()` lazily
  resolves from KeyName when the engine uses the key.

---

## 4. MAJOR — `RF_ClassDefaultObject = 0x00000010` (Task 5)

### Ground truth (UE5.4 `CoreUObject/Public/UObject/ObjectMacros.h:541`)
```cpp
RF_ClassDefaultObject = 0x00000010
```
Task 5's `0x200` is WRONG (0x200 is unrelated — e.g. RF_ArchetypeObject area).
- CDO gate (cheatCDO detection, Task 9) must test flag `0x10`, not `0x200`.

---

## 5. VERIFIED CORRECT (no change needed)

| Claim | UE5.4 evidence | UE4 evidence |
|---|---|---|
| `UEngine::GameViewport` = raw ptr to UGameViewportClient | `Engine.h:397` (`TObjectPtr`; raw in shipping) | mirror `ue4_engine.cpp` |
| `UEngine::ConsoleClass` = `TSubclassOf<UConsole>` (raw UClass*) | `Engine.h:776` | same pattern (TSubclassOf = raw ptr) |
| `UGameViewportClient::ViewportConsole` = `TObjectPtr<UConsole>` | `GameViewportClient.h:82` | same |
| `InputSettings::ConsoleKeys` = `TArray<FKey>` | `InputSettings.h:186` | same |
| `UConsole` `UCLASS(Within=GameViewportClient, config=Input, transient, MinimalAPI)` | `Console.h:61` | same |
| `AddCheats` spawn path via `NewObject<UCheatManager>(this, CheatClass)` | `PlayerController.cpp:1107` / `:1129` (EnableCheats) | `ue4_pc.cpp:1033` / `:1052`, `NewObject` `:1047` |
| UObject layout `{ObjectFlags, InternalIndex, ClassPrivate, NamePrivate, OuterPrivate}` → ObjectFlags @ ClassPrivate-8 | `UObjectBase.h:260-266` | same |
| `TObjectPtr<T>` = raw `T*` when `WITH_EDITORONLY_DATA=0` | Engine.h usage | N/A (UE4 has no TObjectPtr) |

Additional UE4-mirror confirmations (UE4.11 files in `/tmp/opencode/`):
- `RF_ClassDefaultObject` used as a HasAnyFlags test in `ue4_pc.cpp:1211`,
  `ue4_engine.cpp:2600` — flag semantics identical to UE5.
- `NewObject<UCheatManager>(this, CheatClass)` inside `AddCheats`
  (`ue4_pc.cpp:1047`) — matches UE5.4's spawn model (Task 9's Option C holds
  for both families).

---

## 6. Required edits to the TASK docs

1. **Task 01 (PHASE1-DETECT)** — rewrite FName section: FName is
   `{ComparisonIndex, Number, DisplayIndex}`; Number at +4 in both versions;
   12-byte only in editor builds; new detection heuristic (section 1 above);
   do NOT key FNameSize off game version.
2. **Task 05 (ASSESSMENT)** — replace CDO flag `0x200` with `RF_ClassDefaultObject = 0x10`; rewrite the FKey type to `{FName; TSharedPtr<FKeyDetails>}`.
3. **Task 07 (CREATE-CONSOLE)** — corrected SCO offsets: Template=0x28 both sizes
   (UE5), delete `bAllowNativeClassCreation` and "InitializationOptions" fake
   fields, add UE4 0x20/0x28 runtime verification step.
4. **Task 08 (CONSOLE-KEYS)** — correct FKey layout; patch only `KeyName` at +0.
5. **Task 09 (CHEATMANAGER)** — CDO gate uses flag 0x10.

## 7. Required code fixes — verified locations in the codebase

All locations confirmed against the current files. FIX = documentation of what
must change; do not edit until this task is approved.

### 7a. `UnrealEngine-75.LUA:91-92` — `UObject_getName` UE5 branch reads Number at +8
```lua
if UEngine.FNameSize==12 then        -- BUG: comment says {CI,DI,Num}; real is {CI,Num,DI}
  number=readInteger(UObjectAddress+UEngine.UObject.Name+8)   -- +8 is DisplayIndex, NOT Number
```
FIX: Number is at **+4 in both sizes** (DisplayIndex only exists in the 12-byte
editor build, at +8). Replace the two branches with one read at +4; keep the
legacy QWORD fallback unchanged:
```lua
local number
if UEngine.FNameSize==12 or UEngine.FNameSize==8 then
  number=readInteger(UObjectAddress+UEngine.UObject.Name+4)   -- +4 in BOTH sizes
else
  local i=readQword(UObjectAddress+UEngine.UObject.Name)      -- legacy fallback ok
  idx=i & 0xffffffff
  name=UEngine.IndexToName[idx]
  number=i >> 32
end
```

### 7b. `console.lua:125-137` — FNameSize detector probes +4, but DisplayIndex is at +8
```lua
local s0=UEngine_fnameIndexToString(readInteger(nameAddr))
local s4=UEngine_fnameIndexToString(readInteger(nameAddr+4))   -- +4 is Number (0 -> "None")
...
if s4==s0 or s4:lower()==s0:lower() then m12=true end          -- BUG: compares +4==+0
```
On a real 12-byte editor build, +4 is **Number** (0 → resolves to NAME_None),
so this branch never fires → a 12-byte build is mis-detected as 8-byte.
FIX: probe +8 for DisplayIndex and confirm +4 is a small Number:
```lua
local num=readInteger(nameAddr+4)                 -- Number (0 for plain names)
local dpy=readInteger(nameAddr+8)
local m12=false
if s0 and s0~='' and num and num==0 and dpy and dpy~=0 then
  local sd=UEngine_fnameIndexToString(dpy)
  if sd and (sd==s0 or sd:lower()==s0:lower()) then m12=true end
end
```
(FNameSize stays 8 for all shipping UE4/UE5; 12 only for editor-ish UE5.)

### 7c. `console.lua:530` — `RF_ClassDefaultObject` flag constant
```lua
UEngine.RF_ClassDefaultObject=UEngine.RF_ClassDefaultObject or 0x200   -- BUG
```
FIX: `0x10` (verified `ObjectMacros.h:541`). Affects all CDO gates
(`:601`, `:650`, `:794`, Task 9 cheatCDO).

### 7d. `console.lua:1241-1254` — SCO params struct offsets (`UEngine_createConsole`)
```lua
local setFlagsOff=0x10+fnameSize          -- OK: 0x18 (8) / 0x1C (12)
local internalOff=setFlagsOff+4           -- OK: 0x1C / 0x20
local templateOff=(internalOff+4+7)//8*8  -- BUG: 0x20 (8) / 0x28 (12); UE5 needs 0x28 BOTH
```
Real UE5.4 has two bools between InternalSetFlags and Template:
`Template = align8(internalOff + 4 + 2)` → **0x28 for both FName sizes**.
FIX: `local templateOff=(internalOff+6+7)//8*8` (=0x28 for both). Also the FName
fill comments are misleading but the writes are all zeros (NAME_None) so no
functional bug there:
```lua
writeInteger(params+0x10, 0)   -- ComparisonIndex = NAME_None
writeInteger(params+0x14, 0)   -- Number (BOTH sizes)  -- comment wrongly says "Number (UE4) / DisplayIndex (UE5)"
if fnameSize==12 then writeInteger(params+0x18,0) end  -- DisplayIndex (12-byte editor builds only)
```
Also remove the fake trailing-field comment mentioning `bAllowNativeClassCreation`
/ `InitializationOptions` (they do not exist; real trailing fields are
InstanceGraph / ExternalPackage / PropertyInitCallback / SubobjectOverrides).

### 7e. `console.lua:1355-1361` — FKey KeyName write has inverted 12-byte layout
```lua
writeInteger(fkeyAddr+0, idx)      -- ComparisonIndex              OK
if UEngine.FNameSize==12 then      -- BUG: swapped
  writeInteger(fkeyAddr+4, idx)    -- +4 is Number, NOT DisplayIndex -> must be 0
  writeInteger(fkeyAddr+8, 0)      -- +8 is DisplayIndex, NOT Number -> must be idx
else
  writeInteger(fkeyAddr+4, 0)      -- Number-only (8-byte)         OK
end
```
FIX (mirror of 7a):
```lua
writeInteger(fkeyAddr+0, idx)      -- ComparisonIndex
writeInteger(fkeyAddr+4, 0)        -- Number (both sizes)
if UEngine.FNameSize==12 then writeInteger(fkeyAddr+8, idx) end  -- DisplayIndex (editor UE5)
```

---

## 8. Open items (do not block; record for runtime verification)
- [ ] UE4.26/4.27 SCO struct bools presence — verify at runtime (section 2).
- [ ] Confirm `FKeyDetails` size is irrelevant (we never write it).
- [x] After applying fixes, re-run `luac -p Scripts/console/console.lua`.

> **Implementation status (2026-08-01):** all §7 code fixes are applied and verified —
> `UnrealEngine-75.LUA:91-101` (Number at +4 both sizes), `console.lua:125-141`
> (detector probes +8 DisplayIndex), `console.lua:538` (`0x10`), `console.lua:1257`
> + `:1394` (`templateOff=(internalOff+6+7)//8*8` = 0x28 both sizes, fake-field comments
> removed), `console.lua:1498-1502` (FKey `+4`=Number 0, `+8`=DisplayIndex idx on
> FNameSize==12), and the SCO FName fill comments (`+0x14` Number both sizes, `+0x18`
> DisplayIndex) corrected. §6 doc edits applied to live 08/09 (inline notes) and
> archived 01/05/07 (correction banners). Syntax gate passes: `luac -p` + `loadfile`
> on both files; mock test still 28/28. Only the two runtime-verification open items
> above remain (need a live target).

## 9. Code-change location manifest (for the repair task)

| Fix | File | Lines | What changes |
|---|---|---|---|
| FName Number read | `UnrealEngine-75.LUA` | `:91-92` | `+8` → `+4` (Number at +4 both sizes) |
| FNameSize 12-byte detect | `Scripts/console/console.lua` | `:125-137` | probe +8 (DisplayIndex) not +4 |
| CDO flag constant | `Scripts/console/console.lua` | `:530` | `0x200` → `0x10` |
| SCO `templateOff` | `Scripts/console/console.lua` | `:1241-1243` | add bools: `align8(internalOff+6)` → 0x28 both |
| SCO trailing-field comment | `Scripts/console/console.lua` | `:1238-1239` | drop `bAllowNativeClassCreation`/`InitializationOptions` |
| SCO FName fill comment | `Scripts/console/console.lua` | `:1249-1251` | +0x14 is Number both sizes; +0x18 DisplayIndex (12 only) |
| FKey KeyName write | `Scripts/console/console.lua` | `:1355-1361` | swap +4/+8: Number=0@+4, DisplayIndex=idx@+8 |

Verify after changes: `luac -p Scripts/console/console.lua` and
`luac -p UnrealEngine-75.LUA` (whichever the repo lint uses — see README).
