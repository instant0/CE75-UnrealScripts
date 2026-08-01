-- console.lua — Developer Console feature for UnrealEngine-75.LUA (research/console 00–10)
-- Loaded by UnrealEngine-75.LUA at boot (guarded dofile, SPLITFILE.md §5.2). Depends on
-- the core globals UEngine, UObject_getName, UEngine_getAllProperties,
-- UEngine_resolveFName, UEngine_findLocalPlayer, UEngine_searchPropsOnObject.
--
-- Phase 0 (SPLITFILE.md §7): Tasks 1–6 moved verbatim from UnrealEngine-75.LUA
-- (:937–:1826, 890 lines). The core's local log() (:55) and getMemScanResults (:17)
-- are not visible from a separate file, so this file defines its own local copies
-- with identical behaviour. Everything else moved unchanged.
UEngine = UEngine or {}

-- Own local log: the core's log() is local to UnrealEngine-75.LUA (:55), so append to
-- the same UEngine.log buffer here to keep all feature output in one place.
local function log(str)
  UEngine.log=(UEngine.log or '')..str..'\n\r'
end

-- Own local copy of the core's getMemScanResults (UnrealEngine-75.LUA:17): CE 7.5
-- ms.Results doesn't exist, use createFoundList. Local to the core, duplicated here.
local function getMemScanResults(ms)
  local fl=createFoundList(ms)
  fl.initialize()
  local r={}
  for i=0,fl.Count-1 do
    table.insert(r,tonumber('0x'..fl.Address[i]))
  end
  fl.deinitialize()
  fl.destroy()
  return r
end

-- ============================================================
-- Tasks 1–6 (moved verbatim from UnrealEngine-75.LUA :937–:1826)
-- ============================================================
-- Task 1 (Phase 1): FName layout detection (UE4 vs UE5) + caches
-- ============================================================

-- Resolve a name-pool index to its string. Prefer the live pool reader
-- (UEngine_resolveFName), fall back to the CacheNamePool table (always present).
local function UEngine_fnameIndexToString(idx)
  if idx==nil then return nil end
  idx=idx&0xFFFFFFFF
  if UEngine and UEngine_resolveFName then
    local ok,s=pcall(function() return UEngine_resolveFName(idx) end)
    if ok and s and s~='' then return s end
  end
  if UEngine and UEngine.IndexToName then
    return UEngine.IndexToName[idx]
  end
  return nil
end

-- Name field address of the first valid UObject in the discovered object array.
-- Used only when UGameEngine isn't available yet (detection fallback).
function UEngine_findNameTestAddress()
  if not UEngine or not UEngine.ObjectArray or UEngine.ObjectArray==0 then return nil end
  local stride=UEngine.ObjectArrayEntryStructSize
  local atype=UEngine.ObjectArrayListType or 0
  if not stride then return nil end
  local p=readPointer(UEngine.ObjectArray+0x10)
  if not p or p==0 then return nil end
  local count=UEngine.ObjectArrayNumElements or 8192
  if count>8192 then count=8192 end
  for i=0,count-1 do
    local obj=nil
    if atype==1 then
      local chunk=readPointer(p+math.floor(i/65536)*processhandler.pointersize)
      if chunk and chunk~=0 then
        obj=readPointer(chunk+(i%65536)*stride)
      end
    else
      local elem=readPointer(p)
      if elem and elem~=0 then obj=readPointer(elem+i*stride) end
    end
    if obj and obj~=0 then
      local vt=readPointer(obj)
      if vt and isVTable(vt) then
        return obj+UEngine.UObject.Name
      end
    end
  end
  return nil
end

-- Detect FName layout and cache the layout facts every later read/write needs.
-- Idempotent: cached once, re-runs are no-ops.
--   UEngine.FNameSize     = 12 | 8   (measured in-memory FName width — the field the
--     number offset and Task 8's FKey write depend on)
--   UEngine.UEFlavour     = 'UE5' | 'UE4'  (from EngineVersion when resolvable,
--     else inferred from FNameSize)
--   UEngine.SCOPositionalSig = false (UE4.26+/UE5 use the params-struct SCO
--     signature; UE4.25- is rare and Task 7 refines this by disassembly)
-- Primary test: at a known instance's FName, +4 is
--   UE4: Number (normally 0 -> resolves to "None")
--   UE5 + WITH_CASE_PRESERVING_NAME: DisplayIndex -> same name, case-insensitively
--     (comparison entries are stored lowercase; exact equality is NOT guaranteed)
--   UE5 shipping (case preservation compiled out): FName is 8 bytes like UE4, so
--     the +4 test cannot distinguish shipping UE5 from UE4 — EngineVersion does.
function UEngine_detectFNameLayout()
  if UEngine==nil or UEngine.UObject==nil or UEngine.UObject.Name==nil then
    return nil,'UEngine.UObject.Name not initialized yet'
  end
  if UEngine.FNameSize~=nil and UEngine.UEFlavour~=nil then
    log('UEngine_detectFNameLayout: already cached (FNameSize='..tostring(UEngine.FNameSize)..' flavour='..tostring(UEngine.UEFlavour)..')')
    return true
  end

  -- EngineVersion is the authoritative UE4/UE5 signal (shipping UE5 still has
  -- 8-byte FNames). Probe it here so the flavour below can use it.
  if not UEngine.EngineVersion or UEngine.EngineVersion=='' then
    UEngine_detectEngineVersion()
  end
  local versionFlavour=UEngine_flavourFromVersion(UEngine.EngineVersion)

  local nameAddr=nil
  if UEngine.UGameEngine and UEngine.UGameEngine~=0 then
    nameAddr=UEngine.UGameEngine+UEngine.UObject.Name
  else
    nameAddr=UEngine_findNameTestAddress()
  end
  if not nameAddr then
    return nil,'UEngine_detectFNameLayout: no UObject instance to test FName layout'
  end

  local s0=UEngine_fnameIndexToString(readInteger(nameAddr))
  local num=readInteger(nameAddr+4)
  local dpy=readInteger(nameAddr+8)

  -- 12-byte FNames exist ONLY in editor-ish UE5 builds (WITH_CASE_PRESERVING_NAME).
  -- Real layout is {ComparisonIndex@+0, Number@+4, DisplayIndex@+8}; DisplayIndex
  -- mirrors ComparisonIndex for case-preserving names. Number is @+4 in BOTH sizes
  -- (11-TASK-DUAL-VERSION-CORRECTIONS §1; NameTypes.h:1107-1117). Probe +8 for the
  -- mirror and confirm +4 is a small Number — the old probe compared +4 (Number, 0)
  -- and never fired on a real 12-byte build.
  local m12=false
  if s0 and s0~='' and num and num==0 and dpy and dpy~=0 then
    local sd=UEngine_fnameIndexToString(dpy)
    if sd and (sd==s0 or sd:lower()==s0:lower()) then
      m12=true    -- +8 is a DisplayIndex (editor UE5), mirroring ComparisonIndex
    end
  end

  UEngine.FNameSize = m12 and 12 or 8
  UEngine.UEFlavour = versionFlavour or (m12 and 'UE5' or 'UE4')

  -- 12-byte FNames exist only in UE5 with WITH_CASE_PRESERVING_NAME. If the version
  -- probe disagreed, the measurement wins for the memory layout label.
  if m12 and UEngine.UEFlavour=='UE4' then
    log('UEngine_detectFNameLayout: 12-byte FName measured but version says UE4; 12-byte FNames are UE5-only, using UE5')
    UEngine.UEFlavour='UE5'
  end

  -- Cross-check: UE5 never shipped 32-bit; a 4-byte pointer forces UE4 (and 8-byte FNames).
  if UEngine.UEFlavour=='UE5' and processhandler and processhandler.pointersize==4 then
    log('UEngine_detectFNameLayout: pointer size is 4, forcing UE4 (UE5 has no 32-bit support)')
    UEngine.UEFlavour='UE4'
    UEngine.FNameSize=8
  end

  UEngine.SCOPositionalSig=false

  log('UEngine_detectFNameLayout: FNameSize='..tostring(UEngine.FNameSize)..' UEFlavour='..tostring(UEngine.UEFlavour)..' (+0="'..tostring(s0)..'" +4(num)="'..tostring(num)..'" +8(dpy)="'..tostring(dpy and UEngine_fnameIndexToString(dpy) or 'nil')..'" version="'..tostring(UEngine.EngineVersion)..'")')
  return true
end

-- UE4/UE5 family from an engine version string like '5.3.2' -> 'UE5'.
local function UEngine_flavourFromVersion(version)
  if not version or version=='' then return nil end
  local maj=version:match('^(%d+)')
  if maj then return 'UE'..maj end
  return nil
end

-- Cache the full engine version string (e.g. '5.3.2') keyed for Task 7's
-- version-pinned StaticConstructObject_Internal AOB table. couldBeUnrealEngine
-- only separates UE4 from UE5 (ProductVersion), too coarse for 5.0 vs 5.5.
-- Primary: ProductVersion; fallback: memscan of the "%+UE5+Release-<minor>" banner.
function UEngine_detectEngineVersion()
  if UEngine.EngineVersion and UEngine.EngineVersion~='' then
    return UEngine.EngineVersion
  end
  local r=enumModules()
  if r and #r>0 then
    local ok,v=pcall(getFileVersion, r[1].PathToFile)
    if ok and v then
      local pv=v.ProductVersion or v.FileVersion or ''
      local flavour,minor=pv:match('%%+UE(%d)%+Release%-([%d%.]+)')
      if flavour then
        UEngine.EngineVersion=minor
        log('UEngine_detectEngineVersion: UE'..flavour..' '..minor..' (ProductVersion)')
        return UEngine.EngineVersion
      end
    end
  end
  local banner=UEngine_versionBannerScan()
  if banner then
    UEngine.EngineVersion=banner
    log('UEngine_detectEngineVersion: '..banner..' (module banner scan)')
    return UEngine.EngineVersion
  end
  log('UEngine_detectEngineVersion: version string not resolvable')
  return nil
end

-- Fallback version source: bounded string memscan for the "%+UE5+Release-<minor>"
-- banner CE strings that shipped UE builds carry in the main module.
local function UEngine_versionBannerScan()
  if not process or not getAddress or not getModuleSize then return nil end
  local mstart=getAddress(process)
  local mstop=mstart+getModuleSize(process)
  if not mstart or not mstop then return nil end
  for _,flavour in ipairs({'UE5','UE4'}) do
    local pat='%+UE'..flavour..'+Release-'
    local ms=createMemScan()
    ms.VarType=vtString
    ms.Scanvalue=pat
    ms.Startaddress=mstart
    ms.Stopaddress=mstop
    ms.Fastscanmethod=fsmNotAligned
    local okScan=pcall(function()
      ms.scan()
      ms.waitTillDone()
    end)
    local r=okScan and getMemScanResults(ms) or {}
    ms.destroy() ms=nil
    for i=1,math.min(4,#r) do
      local s=readString(r[i],64)
      if s then
        local v=s:match('^%%%+'..flavour..'%+Release%-([%d%.]+)')
        if v then return v end
      end
    end
  end
  return nil
end

-- ============================================================
-- Task 2 (Steps A + B): offset discovery (GameViewport, ViewportConsole)
-- ============================================================

-- Step A: discover UGameEngine::GameViewport (ObjectProperty -> UGameViewportClient).
-- Step B: discover UGameViewportClient::ViewportConsole (ObjectProperty -> UConsole).
-- Read-only: caches offsets, never writes target memory.
--
-- Cache contract (Task 02 doc) says UEngine.UGameEngine.GameViewport, but
-- UEngine.UGameEngine is the numeric instance pointer used in arithmetic
-- throughout (FindGEngine, UEngine_detectFNameLayout, UEngine_findLocalPlayer,
-- ...) and a Lua number cannot hold child keys, so the offset is cached as
-- UEngine.GameViewport. UEngine.UGameViewportClient.ViewportConsole matches the
-- doc exactly (fresh table, UGameViewportClient is never used as a number).
function UEngine_discoverViewportOffsets()
  if UEngine.UGameEngine==nil or UEngine.UGameEngine==0 then
    return nil,'UEngine_discoverViewportOffsets: UGameEngine not found. Run the scanner first.'
  end
  if UEngine.UObject==nil or UEngine.UObject.Class==nil then
    return nil,'UEngine_discoverViewportOffsets: UObject.Class not initialized'
  end

  -- Depends on Task 1's FNameSize for UE5 class-name validation; resolve it if
  -- this function is called standalone (the scanner flow has already run it).
  if UEngine.FNameSize==nil or UEngine.UEFlavour==nil then
    local dr,de=UEngine_detectFNameLayout()
    if not dr then
      log('UEngine_discoverViewportOffsets: FName layout not resolved ('..tostring(de)..'), class-name validation may be unreliable')
    end
  end

  -- Step A: GameViewport offset on UGameEngine (always needed).
  if UEngine.GameViewport==nil then
    local geClass=UEngine.GameEngineClass or readPointer(UEngine.UGameEngine+UEngine.UObject.Class)
    log('UEngine_discoverViewportOffsets: Step A - GameViewport on UGameEngine (class='..tostring(geClass and UObject_getName(geClass) or nil)..')')

    local props=UEngine_getAllProperties(geClass)
    local pv=props and props['GameViewport'] or nil
    if pv and pv.offset then
      UEngine.GameViewport=pv.offset
      local vp=readPointer(UEngine.UGameEngine+UEngine.GameViewport)
      local vpName=nil
      if vp and vp~=0 then
        local vpClass=readPointer(vp+UEngine.UObject.Class)
        if vpClass then vpName=UObject_getName(vpClass) end
      end
      log('UEngine_discoverViewportOffsets: GameViewport @+'..UEngine.GameViewport..' -> 0x'..string.format('%X',vp or 0)..' (class='..tostring(vpName)..')')
    else
      log('UEngine_discoverViewportOffsets: GameViewport not in property link, scanning UGameEngine memory for a UGameViewportClient pointer')
      local found=false
      local stride=processhandler and processhandler.pointersize or 8
      for i=0,63 do
        local slot=UEngine.UGameEngine+i*stride
        local cand=readPointer(slot)
        if cand and cand~=0 and isVTable(readPointer(cand)) then
          local cClass=readPointer(cand+UEngine.UObject.Class)
          local cName=cClass and UObject_getName(cClass) or nil
          if cName=='GameViewportClient' then
            -- stability: candidate must survive a short tick window (re-read after a delay)
            if type(sleep)=='function' then pcall(sleep,50) end
            local cand2=readPointer(slot)
            if cand2==cand then
              UEngine.GameViewport=i*stride
              log('UEngine_discoverViewportOffsets: GameViewport fallback found at +'..UEngine.GameViewport..' -> 0x'..string.format('%X',cand))
              found=true
              break
            else
              log('UEngine_discoverViewportOffsets: candidate +'..(i*stride)..' ('..string.format('0x%X',cand)..') did not survive re-read, skipping')
            end
          end
        end
      end
      if not found then
        log('UEngine_discoverViewportOffsets: GameViewport not resolvable; leaving UEngine.GameViewport nil')
      end
    end
  end

  -- Step B: ViewportConsole offset on UGameViewportClient (only when a viewport exists).
  if UEngine.UGameViewportClient==nil then
    UEngine.UGameViewportClient={}
  end
  if UEngine.GameViewport and UEngine.UGameViewportClient.ViewportConsole==nil then
    local vp=readPointer(UEngine.UGameEngine+UEngine.GameViewport)
    if vp and vp~=0 then
      local vpClass=readPointer(vp+UEngine.UObject.Class)
      if vpClass then
        log('UEngine_discoverViewportOffsets: Step B - ViewportConsole on viewport class '..tostring(UObject_getName(vpClass)))
        local vpProps=UEngine_getAllProperties(vpClass)
        local pvc=vpProps and vpProps['ViewportConsole'] or nil
        if pvc and pvc.offset then
          UEngine.UGameViewportClient.ViewportConsole=pvc.offset
          log('UEngine_discoverViewportOffsets: ViewportConsole @+'..pvc.offset)
        else
          UEngine.UGameViewportClient.ViewportConsole=nil
          log('UEngine_discoverViewportOffsets: ViewportConsole not found on viewport class (Shipping builds may strip it); left nil')
        end
      end
    end
  end

  return true
end

-- ============================================================
-- Task 3 (Step E): find the Console UClass in memory
-- ============================================================

-- Resolve the ComparisonIndex dword for a name. Uses NameToIndexMin (Task 1) so the
-- lowest index wins (comparison-table entries allocate first). On UE5
-- WITH_CASE_PRESERVING_NAME builds (FNameSize==12) the comparison table stores names
-- lowercased while the exact-case string only exists in the display table, and the
-- object's +0 FName field is the ComparisonIndex — so also consider the lowercased
-- variant and take the minimum (comparison block-0 indexes are always lower than
-- display block-1 indexes). FNameSize==8 builds (UE4 / shipping UE5) use a single
-- case-sensitive table, so exact-case lookup only (a lowercase variant, if it exists,
-- is a DIFFERENT FName and must not win).
function UEngine_nameTargetIndex(name)
  if name==nil then return nil end
  local target=(UEngine.NameToIndexMin and UEngine.NameToIndexMin[name]) or UEngine.NameToIndex[name]
  if UEngine.FNameSize==12 then
    local low=name:lower()
    if low~=name then
      local t2=(UEngine.NameToIndexMin and UEngine.NameToIndexMin[low]) or UEngine.NameToIndex[low]
      if t2 and (target==nil or t2<target) then target=t2 end
    end
  end
  return target
end

-- Walk the object array for the first UObject whose name ComparisonIndex matches the
-- target. Deref logic mirrors UEngine_findNameTestAddress (Task 1) / FindObjectArray.
-- Returns nil when absent, or nil,'reason' when the array is not ready. Reused by
-- Task 5 (CDO detection gate) as well as the Task 3 primary path.
function UEngine_findObjectByName(name, t)
  if UEngine.ObjectArray==nil or UEngine.ObjectArray==0 then
    return nil,'ObjectArray not found. Run the scanner first.'
  end
  local stride=UEngine.ObjectArrayEntryStructSize
  if stride==nil then
    return nil,'ObjectArrayEntryStructSize not cached (scanner must run first)'
  end
  local count=UEngine.ObjectArrayNumElements
  if count==nil or count<1 then
    return nil,'ObjectArrayNumElements not cached (Task 1)'
  end
  local target=UEngine_nameTargetIndex(name)
  if target==nil then
    return nil,'name index not found in name pool: '..tostring(name)
  end
  local atype=UEngine.ObjectArrayListType or 0
  local p=readPointer(UEngine.ObjectArray+0x10)
  if p==nil or p==0 then
    return nil,'object array base unreadable'
  end
  local ps=processhandler and processhandler.pointersize or 8
  for i=0,count-1 do
    if t and t.Terminated then return nil,'terminated' end
    local obj=nil
    if atype==1 then
      local chunk=readPointer(p+math.floor(i/65536)*ps)
      if chunk and chunk~=0 then
        obj=readPointer(chunk+(i%65536)*stride)
      end
    else
      local elem=readPointer(p)
      if elem and elem~=0 then
        obj=readPointer(elem+i*stride)
      end
    end
    if obj and obj~=0 and readInteger(obj+UEngine.UObject.Name)==target then
      return obj
    end
  end
  return nil
end

-- Find a UClass object (its own class field resolves to "Class") whose name matches.
-- Primary: object-array walk. Fallback: FName-index module memscan (FindGEngine
-- pattern) — used when the array is unscanned, the stride/count is unknown, or the
-- walk found a same-named instance rather than a class. Case-insensitive class-name
-- check because non-shipping UE5 resolves names to lowercased comparison entries.
function UEngine_findClassByName(name, t)
  local obj=UEngine_findObjectByName(name,t)
  if obj then
    local objClass=readPointer(obj+UEngine.UObject.Class)
    local objClassName=objClass and UObject_getName(objClass)
    if objClassName and string.lower(objClassName)=='class' then
      return obj
    end
  end

  local target=UEngine_nameTargetIndex(name)
  if target==nil then return nil end
  local ms=createMemScan()
  ms.VarType=vtDword
  ms.Fastscanmethod=fsmAligned
  ms.Fastscanparameter=4
  ms.Scanvalue=target
  ms.ScanWritable='scanInclude'
  local okScan=pcall(function()
    ms.scan()
    ms.waitTillDone()
  end)
  local r=okScan and getMemScanResults(ms) or {}
  ms.destroy() ms=nil
  for i=1,#r do
    if t and t.Terminated then return nil,'terminated' end
    local candidate=r[i]-UEngine.UObject.Name
    if candidate>0 then
      local vt=readPointer(candidate)
      if vt and isVTable(vt) then
        local objClass=readPointer(candidate+UEngine.UObject.Class)
        local objClassName=objClass and UObject_getName(objClass)
        if objClassName and string.lower(objClassName)=='class' then
          return candidate
        end
      end
    end
  end
  return nil
end

-- ============================================================
-- Task 4 (Step C): fix UEngine::ConsoleClass
-- ============================================================

-- Resolve + cache the ConsoleClass property offset on the GameEngine class.
-- ConsoleClass is a ClassProperty (TSubclassOf<UConsole> stores a raw UClass*)
-- inherited from UEngine, so the GameEngine property walk sees it. Cached as
-- UEngine.ConsoleClass: mirrors the Task 2 cache contract (UEngine.UGameEngine is
-- the numeric instance pointer and cannot hold child keys, so the offset lives at
-- UEngine.ConsoleClass and the value is read from UGameEngine+offset).
-- Read-only; best-effort (failure leaves the offset uncached, no write, no crash).
function UEngine_resolveConsoleClassOffset()
  if UEngine.ConsoleClass~=nil then return true end
  if UEngine.UGameEngine==nil or UEngine.UGameEngine==0 then
    return nil,'UEngine_resolveConsoleClassOffset: UGameEngine not found. Run the scanner first.'
  end
  if UEngine.UObject==nil or UEngine.UObject.Class==nil then
    return nil,'UEngine_resolveConsoleClassOffset: UObject.Class not initialized'
  end
  if UEngine.FNameSize==nil or UEngine.UEFlavour==nil then
    local dr,de=UEngine_detectFNameLayout()
    if not dr then
      log('UEngine_resolveConsoleClassOffset: FName layout not resolved ('..tostring(de)..'), class-name validation may be unreliable')
    end
  end

  local geClass=UEngine.GameEngineClass or readPointer(UEngine.UGameEngine+UEngine.UObject.Class)
  local props=UEngine_getAllProperties(geClass)
  local pcc=props and props['ConsoleClass'] or nil
  if pcc and pcc.offset then
    UEngine.ConsoleClass=pcc.offset
    log('UEngine_resolveConsoleClassOffset: ConsoleClass @+'..pcc.offset..' (type='..tostring(pcc.propertyType)..')')
    return true
  end
  log('UEngine_resolveConsoleClassOffset: ConsoleClass not in property link; left nil')
  return nil,'ConsoleClass offset not found'
end

-- Repair UEngine::ConsoleClass: when the engine's value is null, find the Console
-- UClass (Task 3) and write it. Idempotent: a non-null value is never overwritten,
-- so calling this on an already-enabled game is a no-op. When the Console UClass
-- cannot be found, nothing is written and the repair is reported as unpatched so
-- the orchestrator (Task 10) can surface the blocker. This is the REPAIR-phase
-- capability for the README requirement-matrix row "UEngine::ConsoleClass set to
-- null -> find Console UClass, write it (Task 4)".
function UEngine_fixConsoleClass(t)
  local r,e=UEngine_resolveConsoleClassOffset()
  if not r then return nil,e end

  local slot=UEngine.UGameEngine+UEngine.ConsoleClass
  local current=readPointer(slot)
  if current and current~=0 then
    log('UEngine_fixConsoleClass: ConsoleClass already set to 0x'..string.format('%X',current)..' ('..tostring(UObject_getName(current))..') - no write')
    return true,'already set'
  end

  local consoleClass=UEngine.ConsoleClassAddr or UEngine_findClassByName('Console',t)
  if consoleClass==nil or consoleClass==0 then
    log('UEngine_fixConsoleClass: Console UClass not found; repair unpatched (no write)')
    return nil,'Console UClass not found; unpatched'
  end

  writePointer(slot, consoleClass)
  local verify=readPointer(slot)
  if verify==consoleClass then
    log('UEngine_fixConsoleClass: wrote ConsoleClass 0x'..string.format('%X',consoleClass)..' ('..tostring(UObject_getName(consoleClass))..')')
    return true,'written'
  end
  log('UEngine_fixConsoleClass: write did not verify (read back '..tostring(verify and string.format('0x%X',verify) or 'nil')..')')
  return nil,'write did not verify'
end

-- ============================================================
-- Task 5 (Phase 2): assessment - read-only state probe
-- ============================================================

-- RF_ClassDefaultObject = 0x00000010 (ObjectMacros.h:541; verified 2026-08-01).
-- NOTE: earlier code used 0x200 which is NOT the CDO flag (11-TASK-DUAL-VERSION-CORRECTIONS §4).
UEngine.RF_ClassDefaultObject=UEngine.RF_ClassDefaultObject or 0x10

-- Read the 4-byte EObjectFlags of a UObject. Offset is NOT scanned: the standard
-- UE4/UE5 UObject layout is {vtable; EObjectFlags(4); int32 InternalIndex(4);
-- UClass* ClassPrivate; FName NamePrivate; ...}, so ObjectFlags always sits exactly
-- 8 bytes below the discovered UObject.Class offset (works for both 64-bit and the
-- rare 32-bit UE4: Class-8 = 8 and 4 respectively). Cached as UEngine.UObject.ObjectFlags.
function UEngine_getObjectFlags(obj)
  if obj==nil or obj==0 then return nil end
  if UEngine.UObject==nil or UEngine.UObject.Class==nil then return nil end
  if UEngine.UObject.ObjectFlags==nil then
    UEngine.UObject.ObjectFlags=UEngine.UObject.Class-8
  end
  if UEngine.UObject.ObjectFlags<0 then return nil end
  return readInteger(obj+UEngine.UObject.ObjectFlags)
end

-- Walk the object array ONCE for several class-default-object names. Matches each
-- object's own FName ComparisonIndex dword against the target set AND requires the
-- RF_ClassDefaultObject flag (0x10) to be set - the flag is the robust signal, the
-- name is the fast index (Task 5 doc). Deref logic mirrors UEngine_findObjectByName.
-- Returns { [name] = obj, ... } (names as passed), or nil,'reason' when the array
-- is not ready. A name with no pool index is simply absent from the result.
function UEngine_findCDOs(names, t)
  if UEngine.UObject==nil or UEngine.UObject.Name==nil then
    return nil,'UObject.Name not initialized. Run the scanner first.'
  end
  if UEngine.ObjectArray==nil or UEngine.ObjectArray==0 then
    return nil,'ObjectArray not found. Run the scanner first.'
  end
  local stride=UEngine.ObjectArrayEntryStructSize
  if stride==nil then
    return nil,'ObjectArrayEntryStructSize not cached (scanner must run first)'
  end
  local count=UEngine.ObjectArrayNumElements
  if count==nil or count<1 then
    return nil,'ObjectArrayNumElements not cached (Task 1)'
  end
  local targets={}
  for i=1,#names do
    local idx=UEngine_nameTargetIndex(names[i])
    if idx~=nil then targets[idx]=names[i] end
  end
  if not next(targets) then return {} end

  local atype=UEngine.ObjectArrayListType or 0
  local p=readPointer(UEngine.ObjectArray+0x10)
  if p==nil or p==0 then
    return nil,'object array base unreadable'
  end
  local ps=processhandler and processhandler.pointersize or 8
  local found={}
  for i=0,count-1 do
    if t and t.Terminated then return nil,'terminated' end
    local obj=nil
    if atype==1 then
      local chunk=readPointer(p+math.floor(i/65536)*ps)
      if chunk and chunk~=0 then
        obj=readPointer(chunk+(i%65536)*stride)
      end
    else
      local elem=readPointer(p)
      if elem and elem~=0 then
        obj=readPointer(elem+i*stride)
      end
    end
    if obj and obj~=0 then
      local nameIdx=readInteger(obj+UEngine.UObject.Name)
      local name=targets[nameIdx]
      if name then
        local flags=UEngine_getObjectFlags(obj)
        if flags and (flags & UEngine.RF_ClassDefaultObject)~=0 then
          found[name]=obj
        end
      end
    end
  end
  return found
end

-- Convenience wrapper for a single CDO name (returns the UObject* or nil).
function UEngine_findCDO(name, t)
  local found,err=UEngine_findCDOs({name}, t)
  if err then return nil,err end
  return found[name]
end

-- Fallback CDO finder by CLASS name instead of the Default__ name: walks the array
-- matching obj.Class's FName ComparisonIndex AND the RF_ClassDefaultObject flag.
-- Used when the Default__InputSettings name lookup misses (renamed/stripped CDO).
function UEngine_findCDOByClassName(className, t)
  if UEngine.UObject==nil or UEngine.UObject.Class==nil or UEngine.UObject.Name==nil then return nil end
  local classTarget=UEngine_nameTargetIndex(className)
  if classTarget==nil then return nil end
  if UEngine.ObjectArray==nil or UEngine.ObjectArray==0 then return nil end
  local stride=UEngine.ObjectArrayEntryStructSize
  local count=UEngine.ObjectArrayNumElements
  if stride==nil or count==nil or count<1 then return nil end
  local atype=UEngine.ObjectArrayListType or 0
  local p=readPointer(UEngine.ObjectArray+0x10)
  if p==nil or p==0 then return nil end
  local ps=processhandler and processhandler.pointersize or 8
  for i=0,count-1 do
    if t and t.Terminated then return nil end
    local obj=nil
    if atype==1 then
      local chunk=readPointer(p+math.floor(i/65536)*ps)
      if chunk and chunk~=0 then
        obj=readPointer(chunk+(i%65536)*stride)
      end
    else
      local elem=readPointer(p)
      if elem and elem~=0 then
        obj=readPointer(elem+i*stride)
      end
    end
    if obj and obj~=0 then
      local objClass=readPointer(obj+UEngine.UObject.Class)
      if objClass and objClass~=0 and readInteger(objClass+UEngine.UObject.Name)==classTarget then
        local flags=UEngine_getObjectFlags(obj)
        if flags and (flags & UEngine.RF_ClassDefaultObject)~=0 then
          return obj
        end
      end
    end
  end
  return nil
end

-- Shared CDO->property->TArray derivation for UInputSettings::ConsoleKeys (Task 8
-- review: the read and write sides must agree, so the read half of the patch lives
-- here). FKey = { FName KeyName; mutable TSharedPtr<FKeyDetails> KeyDetails }
-- (InputCoreTypes.h:49-123; corrected 2026-08-01) — only KeyName@+0 and the TArray
-- head (Data@+0 / Num@+8, heap allocator) are touched, so the KeyDetails pointer
-- (left null, resolved lazily by key name) never matters.
-- Returns
--   cdo, propOffset, dataPtr, count       (resolved; count may be 0, dataPtr nil)
-- or nil,reason.
function UEngine_resolveConsoleKeys(t, cdo)
  if UEngine.UObject==nil or UEngine.UObject.Name==nil then
    return nil,'UObject offsets not initialized'
  end
  if cdo==nil then
    cdo=UEngine_findCDO('Default__InputSettings',t)
    if cdo==nil then
      cdo=UEngine_findCDOByClassName('InputSettings',t)
    end
  end
  if cdo==nil or cdo==0 then
    return nil,'UInputSettings CDO not found'
  end
  local isClass=readPointer(cdo+UEngine.UObject.Class)
  local props=UEngine_getAllProperties(isClass)
  local ck=props and props['ConsoleKeys'] or nil
  if ck==nil or ck.offset==nil then
    return nil,'ConsoleKeys property not found'
  end
  local dataPtr=readPointer(cdo+ck.offset)
  local count=readInteger(cdo+ck.offset+8)
  return cdo, ck.offset, dataPtr, count
end

-- Read UInputSettings::ConsoleKeys (TArray<FKey>): return the FKey KeyName of the
-- FIRST element as a table ({name} or {}). Only the first key is read: Task 8
-- patches exactly this first KeyName - so the first element is both the repair
-- target and the signal.
function UEngine_readConsoleKeys(t, cdo)
  local cdo2, ckOffset, dataPtr, count = UEngine_resolveConsoleKeys(t, cdo)
  if cdo2==nil then
    log('UEngine_readConsoleKeys: '..tostring(ckOffset))
    return nil,ckOffset
  end
  local keys={}
  if dataPtr and dataPtr~=0 and count and count>0 then
    local nameIdx=readInteger(dataPtr)
    local keyName=nameIdx and UEngine_fnameIndexToString(nameIdx)
    if keyName then table.insert(keys,keyName) end
  end
  log('UEngine_readConsoleKeys: ConsoleKeys count='..tostring(count or 0)..' first='..tostring(keys[1] or 'none'))
  return keys
end

-- Read the CheatManager signal: LocalPlayer -> PlayerController chain (mirrors the
-- first half of UEngine_findCharacter, UnrealEngine-75.LUA:3162), then property-walk
-- PlayerController for 'CheatManager' (ObjectProperty). Returns cm, pc, cmOff.
function UEngine_readCheatManager(t)
  if UEngine.UObject==nil or UEngine.UObject.Class==nil then return nil,'UObject.Class not initialized' end
  local lp,lpCount=UEngine_findLocalPlayer()
  if lp==nil or lp==0 then return nil,'no LocalPlayer: '..tostring(lpCount) end
  local lpClass=readPointer(lp+UEngine.UObject.Class)
  if lpClass==nil or lpClass==0 then return nil,'LocalPlayer class unreadable' end
  local lpProps=UEngine_getAllProperties(lpClass)
  local pcProp=lpProps and lpProps['PlayerController'] or nil
  if pcProp==nil then
    for name,info in pairs(lpProps or {}) do
      if info.propertyType=='ObjectProperty' and name:lower():find('controller') then
        pcProp=info
        break
      end
    end
  end
  if pcProp==nil then return nil,'PlayerController property not found on LocalPlayer' end
  local pc=readPointer(lp+pcProp.offset)
  if pc==nil or pc==0 then return nil,'PlayerController is nil' end

  local found=UEngine_searchPropsOnObject(pc, {'CheatManager'})
  local cmProp=nil
  for name,info in pairs(found) do
    if name=='CheatManager' then cmProp=info break end
  end
  if cmProp==nil then
    for name,info in pairs(found) do
      if info.propertyType=='ObjectProperty' and name:lower():find('cheat') then
        cmProp=info
        break
      end
    end
  end
  if cmProp==nil then return nil,'CheatManager property not found on PlayerController' end
  local cm=readPointer(pc+cmProp.offset)
  return cm, pc, cmProp.offset
end

-- Phase 2 assessment: build UEngine.DevConsoleState (7 signals + needs + blocked)
-- WITHOUT writing target memory, then derive the orchestrator's repair list.
-- Return contract (documented in Task 5 doc):
--   nil,'reason'            - probe could not run (scanner not ready)
--   true,'already enabled'  - console present AND first console key is Tilde
--                             (idempotent path; 'cheat' is bonus and may remain in needs)
--   false,'needs: <list>'   - probe ran; UEngine.DevConsoleState.needs has the repairs
-- The state table is the real contract; the return value is a convenience status.
function UEngine_assessDeveloperConsole(t)
  if UEngine.UGameEngine==nil or UEngine.UGameEngine==0 then
    return nil,'UEngine_assessDeveloperConsole: UGameEngine not found. Run the scanner first.'
  end
  if UEngine.UObject==nil or UEngine.UObject.Class==nil then
    return nil,'UEngine_assessDeveloperConsole: UObject.Class not initialized'
  end
  if UEngine.FNameSize==nil or UEngine.UEFlavour==nil then
    local dr,de=UEngine_detectFNameLayout()
    if not dr then
      log('UEngine_assessDeveloperConsole: FName layout not resolved ('..tostring(de)..'), name-based CDO/key detection may fail')
    end
  end

  -- Resolve offsets (Tasks 2 + 4). Read-only; failures only leave caches nil.
  local vpR,vpErr=UEngine_discoverViewportOffsets()
  if not vpR then log('UEngine_assessDeveloperConsole: viewport offsets: '..tostring(vpErr)) end
  local ccR,ccErr=UEngine_resolveConsoleClassOffset()
  if not ccR then log('UEngine_assessDeveloperConsole: consoleClass offset: '..tostring(ccErr)) end

  local state={}
  state.viewport=nil
  if UEngine.GameViewport then
    state.viewport=readPointer(UEngine.UGameEngine+UEngine.GameViewport)
  end
  state.console=nil
  if state.viewport and state.viewport~=0 and UEngine.UGameViewportClient and UEngine.UGameViewportClient.ViewportConsole then
    state.console=readPointer(state.viewport+UEngine.UGameViewportClient.ViewportConsole)
  end
  state.consoleClass=nil
  if UEngine.ConsoleClass then
    state.consoleClass=readPointer(UEngine.UGameEngine+UEngine.ConsoleClass)
  end

  -- CDO hard gates (single-pass walk; name + RF_ClassDefaultObject flag).
  local cdos,cdoErr=UEngine_findCDOs({'Default__Console','Default__CheatManager','Default__InputSettings'},t)
  local cdoWalkOK=cdoErr==nil
  if not cdoWalkOK then
    log('UEngine_assessDeveloperConsole: CDO walk failed: '..tostring(cdoErr))
  end
  state.consoleCDO=cdoWalkOK and cdos['Default__Console'] or nil
  state.cheatCDO=cdoWalkOK and cdos['Default__CheatManager'] or nil
  state.inputSettingsCDO=cdoWalkOK and cdos['Default__InputSettings'] or nil

  -- Console keys (first FKey KeyName; reuse the single-pass CDO result).
  local keys,keyErr=UEngine_readConsoleKeys(t, state.inputSettingsCDO)
  state.consoleKeys=keys or {}
  if keyErr then log('UEngine_assessDeveloperConsole: consoleKeys: '..tostring(keyErr)) end

  -- CheatManager via the LocalPlayer -> PlayerController chain.
  local cm,pc,cmOff=UEngine_readCheatManager(t)
  state.cheatManager=cm
  state.playerController=pc

  -- Derive needs + blocked.
  local needs={}
  local blocked={}
  if state.consoleClass==nil then table.insert(needs,'consoleClass') end
  if state.console==nil or state.console==0 then
    table.insert(needs,'console')
    if state.consoleCDO==nil then
      if cdoWalkOK then
        blocked['console']='Default__Console CDO missing; Task 7 creation blocked'
      else
        blocked['console']='CDO walk failed ('..tostring(cdoErr)..'); Task 7 creation not attempted'
      end
    end
  end
  local firstKey=state.consoleKeys[1]
  if firstKey==nil or string.lower(firstKey)~='tilde' then
    table.insert(needs,'keys')
  end
  if state.cheatManager==nil or state.cheatManager==0 then
    table.insert(needs,'cheat')
    if state.cheatCDO==nil then
      if cdoWalkOK then
        blocked['cheat']='Default__CheatManager CDO missing; Task 9 spawn blocked'
      else
        blocked['cheat']='CDO walk failed ('..tostring(cdoErr)..'); Task 9 spawn not attempted'
      end
    end
  end

  state.needs=needs
  state.blocked=blocked
  UEngine.DevConsoleState=state

  log('UEngine_assessDeveloperConsole: viewport='..tostring(state.viewport and string.format('0x%X',state.viewport))
    ..' console='..tostring(state.console and string.format('0x%X',state.console))
    ..' consoleClass='..tostring(state.consoleClass and string.format('0x%X',state.consoleClass))
    ..' consoleCDO='..tostring(state.consoleCDO and 'present' or 'absent')
    ..' cheatManager='..tostring(state.cheatManager and string.format('0x%X',state.cheatManager))
    ..' cheatCDO='..tostring(state.cheatCDO and 'present' or 'absent')
    ..' keys='..#state.consoleKeys)
  local blockedStr=''
  for k,v in pairs(blocked) do
    blockedStr=blockedStr..(blockedStr=='' and '' or '; ')..k..'='..v
  end
  log('UEngine_assessDeveloperConsole: needs='..table.concat(needs,', ')..(blockedStr~='' and (' blocked={'..blockedStr..'}') or ''))

  if (state.console and state.console~=0) and firstKey and string.lower(firstKey)=='tilde' then
    return true,'already enabled'
  end
  if #needs==0 then
    return true,'already enabled'
  end
  return false,'needs: '..table.concat(needs,', ')
end

-- ============================================================
-- Task 6 (Phase 3 prelude): CE 7.5 remote-call wrappers
-- ============================================================

-- Default finite ms timeout for UEngine_callFunction / UEngine_callMethod. CE 7.5's
-- executeCodeEx/executeMethod treat timeout 0 as fire-and-forget (no return value)
-- and nil/-1 as infinite; on a timeout OR fire-and-forget, CE leaves the injected
-- stub/scratch allocated (dontfree:=timeout=0, LuaHandler.pas:11968; WAIT_TIMEOUT
-- also dontfree, :11997). The plan therefore always waits with a finite timeout, and
-- the wrappers enforce that here: an explicit 0/nil timeout is refused, not passed.
UEngine.RemoteCallTimeoutMs=UEngine.RemoteCallTimeoutMs or 5000

-- Normalize a caller-supplied timeout to a finite positive ms value. nil, 0 and
-- negatives are refused (0 = fire-and-forget, nil = infinite — both leak CE's stub)
-- and replaced with the default, so callers can never accidentally pass a
-- leak-inducing timeout (Task 6 DoD: "always finite ms, never 0").
local function UEngine_remoteCallTimeout(ms)
  local t=tonumber(ms)
  t=t and math.floor(t) or 0
  if t<=0 then
    log('UEngine_remoteCallTimeout: refusing timeout '..tostring(ms)..' (0/nil = fire-and-forget/infinite, leaks CE stub); using '..UEngine.RemoteCallTimeoutMs)
    return UEngine.RemoteCallTimeoutMs
  end
  return t
end

-- UEngine_callFunction(fnAddr, argPtr[, timeoutMs]) -> value or nil, err
--   Free-function call on x64: argPtr is param1 and lands in RCX. This is the sole
--   argument of StaticConstructObject_Internal (the FStaticConstructObjectParameters*).
--   Delegates to CE executeCodeEx, which inserts a nil instance (LuaHandler.pas:12055)
--   so the first param is the only register write. Always waits with a finite timeout;
--   on success RAX is returned as the Lua result (the UObject* we need); RAX=0 and CE
--   failures both come back as nil (a null return is recorded as an unpatched need,
--   never assumed to have succeeded — Task 6 caveat).
function UEngine_callFunction(fnAddr, argPtr, timeoutMs)
  if not fnAddr or fnAddr==0 then return nil,'UEngine_callFunction: fnAddr is nil' end
  local ms=UEngine_remoteCallTimeout(timeoutMs)
  local ok,result,err=pcall(executeCodeEx, 0, ms, fnAddr, argPtr)
  if not ok then return nil,'UEngine_callFunction: executeCodeEx raised: '..tostring(result) end
  if result==nil then return nil,err end
  if result==0 then return nil end
  return result
end

-- UEngine_callMethod(fnAddr, instance, param1, param2[, timeoutMs]) -> value or nil, err
--   Instance (thiscall) call. Delegates to executeCodeEx with the instance as the
--   FIRST param, yielding the exact x64 thiscall: RCX=instance, RDX=param1, R8=param2.
--   Do NOT use CE's executeMethod here — it emits the instance mov BEFORE the param
--   loop and then assigns param1 to RCX too, clobbering `this` (LuaHandler.pas:11736
--   vs :11836). Used for SpawnCheatManager (zero extra args) and ConsoleCommand
--   (FString& as param1, bWriteToLog as param2 — pass {type=0,value=1}, R8 is not
--   defaulted). CE failures/timeouts come back as nil,errormsg; a successful call
--   returning RAX=0 comes back as nil (no error).
function UEngine_callMethod(fnAddr, instance, param1, param2, timeoutMs)
  if not fnAddr or fnAddr==0 then return nil,'UEngine_callMethod: fnAddr is nil' end
  if not instance or instance==0 then return nil,'UEngine_callMethod: instance is nil' end
  local ms=UEngine_remoteCallTimeout(timeoutMs)
  local ok,result,err
  if param2~=nil then
    ok,result,err=pcall(executeCodeEx, 0, ms, fnAddr, instance, param1, param2)
  elseif param1~=nil then
    ok,result,err=pcall(executeCodeEx, 0, ms, fnAddr, instance, param1)
  else
    ok,result,err=pcall(executeCodeEx, 0, ms, fnAddr, instance)
  end
  if not ok then return nil,'UEngine_callMethod: executeCodeEx raised: '..tostring(result) end
  if result==nil then return nil,err end
  if result==0 then return nil end
  return result
end

-- ============================================================
-- Task 7 (Step D): create the UConsole instance
-- ============================================================

-- Version-pinned StaticConstructObject_Internal AOB table (Task 7, Locating §2 Path A).
-- Entries are FILLED AT CE ATTACH against a live target — never fabricated. Schema:
--   UEngine.SCOPatterns[fullEngineVersion] = { pattern, module, structFNameSize, source, verified }
--     pattern         hex AOB bytes for the SCO prologue (params-struct signature, UE4.26+/UE5)
--     module          module name to scope the scan (default: main exe)
--     structFNameSize cross-check only (must equal UEngine.FNameSize), not a key
--     source          where the pattern came from (community AOB / captured prologue)
--     verified        date the §4 checklist passed on a live target
UEngine.SCOPatterns=UEngine.SCOPatterns or {}

-- Version-pinned StaticAllocateObject AOB table (Locating §3 Path B step 1). Same
-- fill-at-attach rule. SAO's prologue is markedly more stable than SCO's across
-- versions, so an SAO pattern + xref is the fallback when no SCO entry exists.
UEngine.SAOPatterns=UEngine.SAOPatterns or {}

-- Main-module name for module-scoped AOB scans (UE statically links the engine into
-- the game exe — no engine DLL). enumModules()'s first entry is normally the main exe
-- (same source as UEngine_detectEngineVersion, console.lua:176).
local function UEngine_mainModuleName()
  local r=enumModules()
  if r and #r>0 then
    local p=r[1].PathToFile or ''
    local name=p:match('([^/\\]+)$')
    if name and name~='' then return name end
  end
  if process and process~='' then return process end
  return nil
end

-- Walk backward from a call site to the enclosing function start by finding the
-- MSVC function-boundary padding run (CC CC / CC 00 00 00 / 90 90 after a C3 ret,
-- standard in /Gy shipping builds); the byte after the run is the candidate start.
-- Locating §3 step 3. Returns the candidate address or nil.
local function UEngine_findFunctionStart(callSite)
  local window=0x2000
  local base=callSite-window
  local ok,data=pcall(readBytes, base, window, true)
  if not ok or not data or #data~=window then return nil end
  local i=window
  while i>=2 do
    local b=data[i]
    if b==0xCC or b==0x90 or b==0x00 then
      local j=i
      while j>1 and (data[j-1]==0xCC or data[j-1]==0x90 or data[j-1]==0x00) do
        j=j-1
      end
      if (i-j+1)>=2 then
        return base+i -- data[i] sits at base+(i-1); the function starts at the next byte
      end
      i=j-1
    else
      i=i-1
    end
  end
  return nil
end

-- Guarded target-memory free (CE global deallocateMemory; safe even on 7.5 builds
-- where it may be absent). Only call AFTER a remote call completed — never on a
-- timeout/nil path where CE's injected thread may still be running.
local function UEngine_free(addr)
  if addr and type(deallocateMemory)=='function' then
    pcall(deallocateMemory, addr)
  end
end

-- Task 7 §4 validation checklist for a StaticConstructObject_Internal candidate.
-- ALL of items 1–3 must pass before the address may be cached/called (soft items 4–5
-- are logged only). saoAddr is the StaticAllocateObject anchor from Path B step 1.
--   item 1: MSVC prologue within the first ~8 instructions (push / sub rsp,imm /
--     endbr64 — the exact "mov [rsp+8],rbx" rendering is version-dependent, so any
--     push or sub rsp, counts as a plausible prologue start)
--   item 2: calls StaticAllocateObject (isCall + parameterValue == SAO)
--   item 3 (decisive): within ~6 instructions before the SAO call, RCX is loaded
--     from a STACK local (lea/mov rcx,[rbp|rsp+disp] -> modrmValueType=dvtValue).
--     A rip-relative load (dvtAddress) would mean a global — i.e. a different
--     function. lea and mov are both accepted: the params struct pointer is a stack
--     local in UE source, but SCO may first spill Params into a callee-saved reg
--     and reload a field from the stack before calling SAO.
-- Returns true,{saoCall=,rcx=} | nil,reason.
local function UEngine_validateSCO(candidate, saoAddr)
  if not candidate or candidate==0 then return nil,'candidate==0' end
  local d=createDisassembler()
  if not d then return nil,'createDisassembler failed' end
  local prologueOK=false
  local saoCallInstr=nil
  local rcxStackBefore=nil
  local softNameMachinery=false
  local softResultHandling=false
  local addr=candidate
  for i=1,512 do
    local ok,st=pcall(function() return d:disassemble(addr) end)
    if not ok then break end
    local ldd=d:getLastDisassembleData()
    if not ldd then break end
    local op=ldd.opcode or ''
    local params=string.lower(ldd.parameters or '')
    if i<=8 and not prologueOK then
      if op=='endbr64' then prologueOK=true end
      if op=='push' then prologueOK=true end
      if op=='sub' and params:match('^rsp,') then prologueOK=true end
    end
    if ldd.isCall and ldd.parameterValue and ldd.parameterValue==saoAddr then
      saoCallInstr=i
    end
    if saoCallInstr and (op=='lea' or op=='mov') and params:match('^rcx,%[r[sb]p')
       and ldd.modrmValueType==2 then
      if i>=saoCallInstr-6 and i<saoCallInstr then
        rcxStackBefore=i
      end
    end
    if saoCallInstr and i>saoCallInstr and ldd.isCall then softNameMachinery=true end
    if saoCallInstr and i>saoCallInstr and (op=='test' or op=='mov') and params:find('rax') then
      softResultHandling=true
    end
    if ldd.isRet and saoCallInstr then break end
    local n=ldd.bytes and #ldd.bytes or 0
    if n<=0 then break end
    addr=addr+n
  end
  if not prologueOK then return nil,'no MSVC prologue in first 8 instructions' end
  if not saoCallInstr then return nil,'no call to StaticAllocateObject found' end
  if not rcxStackBefore then return nil,'no stack-local rcx (lea/mov rcx,[rsp|rbp+..]) within 6 instrs before SAO call' end
  log('UEngine_validateSCO: candidate 0x'..string.format('%X',candidate)..' PASSES (SAO call @instr '..saoCallInstr..', stack-rcx @instr '..rcxStackBefore
    ..'; soft: nameMachinery='..tostring(softNameMachinery)..' resultHandling='..tostring(softResultHandling)..')')
  return true,{saoCall=saoCallInstr, rcx=rcxStackBefore}
end

-- Locate StaticAllocateObject (Locating §3 step 1). Order: (a) version-pinned SAO
-- AOB pattern (shipping-stable prologue), else (b) Dissect-Code string xref (dev
-- builds only — Shipping compiles the distinctive check/FName strings out). Returns
-- the SAO address or nil.
local function UEngine_locateStaticAllocateObject()
  if UEngine.SAOAddr and UEngine.SAOAddr~=0 then return UEngine.SAOAddr end
  local version=UEngine.EngineVersion
  local entry=version and UEngine.SAOPatterns and UEngine.SAOPatterns[version]
  if entry and entry.pattern then
    local module=entry.module or UEngine_mainModuleName()
    local ok,hit=pcall(AOBScanModuleUnique, module, entry.pattern)
    if ok and hit and hit~=0 then
      UEngine.SAOAddr=hit
      log('UEngine_locateStaticAllocateObject: SAO 0x'..string.format('%X',hit)..' (version-pinned AOB)')
      return hit
    end
  end
  local okD,dc=pcall(getDissectCode)
  if okD and dc then
    local module=UEngine_mainModuleName()
    if module then
      local okDis=pcall(function() dc:dissect(module) end)
      if okDis then
        local okS,strs=pcall(function() return dc:getReferencedStrings() end)
        if okS and strs then
          for strAddr,str in pairs(strs) do
            if type(str)=='string' and (str:find('StaticAllocateObject') or str:find('AllocateObject')) then
              local okR,refs=pcall(function() return dc:getReferences(strAddr) end)
              if okR and refs then
                for refAddr,jt in pairs(refs) do
                  if jt==0 or jt==1 then
                    local start=UEngine_findFunctionStart(refAddr)
                    if start then
                      UEngine.SAOAddr=start
                      log('UEngine_locateStaticAllocateObject: SAO 0x'..string.format('%X',start)..' (string xref, dev build)')
                      return start
                    end
                  end
                end
              end
            end
          end
        end
      end
    end
  end
  return nil
end

-- Locate + validate StaticConstructObject_Internal (Locating §2/§3/§4). Path A:
-- version-pinned SCO AOB table keyed on UEngine.EngineVersion. Path B: SAO
-- cross-reference via Dissect Code. Every candidate passes the §4 checklist before
-- it is cached as UEngine.SCOAddr (persisted -> 0 scans on repeat runs). Degrades to
-- nil,reason — never a fabricated address. Returns true,addr[,detail] | nil,reason.
function UEngine_locateStaticConstructObject()
  if UEngine.SCOAddr and UEngine.SCOAddr~=0 then return true,UEngine.SCOAddr end

  -- The SAO anchor is required for checklist items 2+3 (the decisive evidence), so
  -- locate it first. Without it a candidate is unvalidated and is never called.
  local sao=UEngine_locateStaticAllocateObject()
  if not sao then
    return nil,'StaticAllocateObject not located; cannot validate a SCO candidate (Locating §3 step 1 failed)'
  end

  -- Path A: version-pinned AOB table.
  local version=UEngine.EngineVersion
  local entry=version and UEngine.SCOPatterns and UEngine.SCOPatterns[version]
  if entry and entry.pattern then
    local module=entry.module or UEngine_mainModuleName()
    local ok,hit=pcall(AOBScanModuleUnique, module, entry.pattern)
    if ok and hit and hit~=0 then
      local valid,detail=UEngine_validateSCO(hit, sao)
      if valid then
        UEngine.SCOAddr=hit
        log('UEngine_locateStaticConstructObject: Path A 0x'..string.format('%X',hit)..' (version '..tostring(version)..')')
        return true,hit,detail
      end
      log('UEngine_locateStaticConstructObject: Path A hit failed checklist: '..tostring(detail))
    elseif not ok then
      log('UEngine_locateStaticConstructObject: Path A scan raised: '..tostring(hit))
    else
      log('UEngine_locateStaticConstructObject: Path A no hit for version '..tostring(version))
    end
  end

  -- Path B: cross-reference from StaticAllocateObject.
  local okD,dc=pcall(getDissectCode)
  if okD and dc then
    local module=UEngine_mainModuleName()
    if module then
      if not UEngine.dissectReady then
        local okDis=pcall(function() dc:dissect(module) end)
        if not okDis then return nil,'dissect of '..tostring(module)..' failed' end
        UEngine.dissectReady=true
      end
      local okR,refs=pcall(function() return dc:getReferences(sao) end)
      if okR and refs then
        for callSite,jt in pairs(refs) do
          if jt==0 or jt==1 then
            local start=UEngine_findFunctionStart(callSite)
            if start then
              local valid,detail=UEngine_validateSCO(start, sao)
              if valid then
                UEngine.SCOAddr=start
                log('UEngine_locateStaticConstructObject: Path B 0x'..string.format('%X',start)..' (SAO caller 0x'..string.format('%X',callSite)..')')
                return true,start,detail
              end
            end
          end
        end
      end
      return nil,'no validated SCO caller of StaticAllocateObject'
    end
    return nil,'main module name unresolvable (Path B unavailable)'
  end
  return nil,'getDissectCode failed (Path B unavailable)'
end

-- UEngine_createConsole() -> consoleAddr, nil | nil, err
--   Task 7 (Step D), the crux: construct a UConsole with outer = GameViewport and
--   assign it to ViewportConsole. Called by the Task 10 orchestrator ONLY when
--   UEngine.DevConsoleState.needs contains 'console' AND it is not blocked. Mirrors
--   SetupInitialLocalPlayer: StaticConstructObject_Internal(Console UClass, viewport,
--   NAME_None, ...). The write only happens when ViewportConsole reads null and the
--   created object validates; SCO is cached so repeat calls are no-ops.
function UEngine_createConsole()
  -- 0) Hard gate first: never call SCO without the Console CDO present.
  --    (A null Template makes ConstructObject resolve Class->GetDefaultObject(); if
  --     that CDO does not exist it is CREATED on the injected thread ->
  --     check(IsInGameThread()) crash. Task 5 verified Default__Console exists.)
  local state=UEngine.DevConsoleState
  if not (state and state.consoleCDO) then
    return nil,'blocked: no Default__Console CDO (foreign-thread GetDefaultObject() risk)'
  end

  -- 1) Inputs (Task 2/3/5 caches).
  local vp=state.viewport
  local consoleClass=UEngine.ConsoleClassAddr
  if not vp or vp==0 then return nil,'blocked: no viewport' end
  if not consoleClass or consoleClass==0 then return nil,'blocked: no console class' end
  if not UEngine.UGameViewportClient or not UEngine.UGameViewportClient.ViewportConsole then
    return nil,'blocked: ViewportConsole offset unknown (Task 2)'
  end

  -- 2) SCO address (cached; located + validated by the section above if not already).
  local scoAddr=UEngine.SCOAddr
  if not scoAddr or scoAddr==0 then
    local okL,locErr=UEngine_locateStaticConstructObject()
    if not okL then
      return nil,'blocked: StaticConstructObject_Internal not located/validated ('..tostring(locErr)..')'
    end
    scoAddr=UEngine.SCOAddr
  end

  -- 3) Signature branch: Task 1's FNameSize decides the struct layout (UE4.26+/UE5
  --    params-struct variant; UEngine.SCOPositionalSig=false always).
  if UEngine.FNameSize==nil then
    local dr,de=UEngine_detectFNameLayout()
    if not dr then return nil,'blocked: FName layout unresolved ('..tostring(de)..')' end
  end
  local fnameSize=UEngine.FNameSize

  -- 4) Allocate + fill the params struct. Offsets depend on FNameSize (8 for UE4 /
  --    shipping-UE5, 12 for UE5 WITH_CASE_PRESERVING_NAME) — never hard-code by
  --    family. Layout (UObjectGlobals.h FStaticConstructObjectParameters):
  --      0x00 Class(ptr) 0x08 Outer(ptr) 0x10 FName {SetFlags;InternalSetFlags} Template(ptr)
  --    Template offset shifts only with FName width. Trailing fields (InstanceGraph,
  --    UE5.0+ bAllowNativeClassCreation/ExternalPackage, UE5.1+ InitializationOptions)
  --    are left 0 on the fresh zero-filled page.
  local setFlagsOff=0x10+fnameSize
  local internalOff=setFlagsOff+4
  local templateOff=(internalOff+4+7)//8*8

  local params=allocateMemory(0x60)
  if not params or params==0 then return nil,'unpatched: allocateMemory failed' end
  writePointer(params+0x00, consoleClass)             -- Class = UConsole UClass (Task 3)
  writePointer(params+0x08, vp)                       -- Outer = GameViewport (MUST be the viewport)
  writeInteger(params+0x10, 0)                        -- FName ComparisonIndex = NAME_None (0)
  writeInteger(params+0x14, 0)                        -- FName Number (UE4) / DisplayIndex (UE5)
  if fnameSize==12 then writeInteger(params+0x18,0) end -- FName Number (UE5 only)
  writeInteger(params+setFlagsOff, 0)                 -- SetFlags = RF_NoFlags
  writeInteger(params+internalOff, 0)                 -- InternalSetFlags = None
  writePointer(params+templateOff, 0)                 -- Template = nil (CDO gate makes this safe)

  -- 5) Call it. UEngine_callFunction puts argPtr in RCX = the one arg (params ref);
  --    RAX = the new UConsole*. CE returns nil for RAX==0 OR call failure.
  local consoleObject,callErr=UEngine_callFunction(scoAddr, params)
  if not consoleObject then
    -- On failure/timeout CE leaves its stub allocated and the remote thread may still
    -- be running — do NOT free params here. The orchestrator aborts on repeated
    -- timeouts (never loops with leaked allocations).
    return nil,'unpatched: SCO call failed/nil return'..(callErr and (': '..callErr) or '')
  end

  -- 6) Validate BEFORE any write: class name must be "Console". The outer is set by
  --    SCO from Params.Outer during construction, so passing vp here structurally
  --    guarantees Outer == GameViewport; the remaining real risk is a wrong vp, which
  --    Task 2/5 already validated as a UGameViewportClient. (There is no cached
  --    UObject.Outer offset to re-check; the class-name check + correct vp is the gate.)
  local clsAddr=readPointer(consoleObject+UEngine.UObject.Class)
  local clsName=clsAddr and UObject_getName(clsAddr) or nil
  if clsName~='Console' then
    UEngine_free(params)
    return nil,'unpatched: created object class is '..tostring(clsName)
  end

  -- 7) Only now assign.
  writePointer(vp+UEngine.UGameViewportClient.ViewportConsole, consoleObject)
  UEngine_free(params)
  UEngine.SCOAddr=UEngine.SCOAddr or scoAddr -- persist across runs (0 AOBs on 2nd run)
  log('UEngine_createConsole: created UConsole 0x'..string.format('%X',consoleObject)..' (outer=viewport 0x'..string.format('%X',vp)..') -> ViewportConsole')
  return consoleObject,nil
end

-- ============================================================
-- Task 8 (Step F): register the console key
-- ============================================================

-- Make the first UInputSettings::ConsoleKeys FKey toggle the console. Runs when
-- DevConsoleState.needs contains 'keys' (first FKey KeyName != Tilde; Task 5
-- signal). Plain memory write to the CDO property - safe off the game thread (no
-- engine call). Return contract (matches the Task 10 orchestrator needs list):
--   true,'already set'  - first key already Tilde (idempotent, no write)
--   true,'written'      - first FKey KeyName written (or in-place-filled an
--                         empty array that still held capacity, Num set to 1)
--   nil,'<reason>'      - blocked / unpatched (recorded, never silently skipped)
-- Target key: Tilde, falling back to BackSpace then Tab if absent from the pool.
-- FName layout from UEngine.FNameSize (Task 1): Number @+4 in BOTH sizes; only
-- 12-byte editor UE5 adds DisplayIndex @+8 (11-TASK-DUAL-VERSION-CORRECTIONS §1).
-- Empty-array rule (08-TASK doc, corrected 2026-08-01): an empty array means
-- an INI/code clear, not a shipping default - in-place fill only when dataPtr~=0
-- (write element 0, set Num=1; no allocation); when dataPtr==0 the TArray has no
-- capacity and growing it needs engine allocation (risky on a foreign thread), so
-- the need is recorded explicitly instead.
function UEngine_patchConsoleKeys(t, cdo)
  local cdo2, ckOffset, dataPtr, count = UEngine_resolveConsoleKeys(t, cdo)
  if cdo2==nil then
    return nil, ckOffset
  end

  if UEngine.FNameSize==nil then
    local dr,de=UEngine_detectFNameLayout()
    if not dr then
      return nil,'keys: FName layout unresolved ('..tostring(de)..')'
    end
  end

  local fkeyAddr = (dataPtr and dataPtr~=0) and dataPtr or nil

  local first=nil
  if fkeyAddr and count and count>0 then
    local nameIdx=readInteger(fkeyAddr)
    first=nameIdx and UEngine_fnameIndexToString(nameIdx)
  end

  if first and string.lower(first)=='tilde' then
    log('UEngine_patchConsoleKeys: first key already '..first..' - no write')
    return true,'already set'
  end

  local idx=UEngine_nameTargetIndex('Tilde')
  local keyName='Tilde'
  if idx==nil then
    idx=UEngine_nameTargetIndex('BackSpace')
    keyName='BackSpace'
  end
  if idx==nil then
    idx=UEngine_nameTargetIndex('Tab')
    keyName='Tab'
  end
  if idx==nil then
    log('UEngine_patchConsoleKeys: Tilde/BackSpace/Tab not in name pool; unpatched')
    return nil,'keys: target key not in name pool (Tilde/BackSpace/Tab); needs approach #2 AOB / programmatic'
  end

  if fkeyAddr==nil then
    -- Empty array with no capacity (dataPtr==0): cannot grow without engine
    -- allocation - record the need explicitly (DoD: never silently skipped).
    log('UEngine_patchConsoleKeys: ConsoleKeys empty with no capacity; unpatched')
    return nil,'keys: empty; needs approach #2 AOB / programmatic'
  end

  local filledEmpty=(count==nil or count==0)

  writeInteger(fkeyAddr+0, idx)                          -- ComparisonIndex
  writeInteger(fkeyAddr+4, 0)                            -- Number (BOTH sizes)
  if UEngine.FNameSize==12 then                          -- editor-only UE5: DisplayIndex mirror at +8
    writeInteger(fkeyAddr+8, idx)
  end
  if filledEmpty then
    writeInteger(cdo2+ckOffset+8, 1)                     -- Num=1 (capacity already there)
  end

  local backIdx=readInteger(fkeyAddr+0)
  local backName=backIdx and UEngine_fnameIndexToString(backIdx)
  if backName and string.lower(backName)==keyName:lower() then
    log('UEngine_patchConsoleKeys: wrote '..keyName..' (idx '..idx..')'..(filledEmpty and ' [in-place fill]' or '')
      ..' -> verified as '..backName)
    return true,'written'
  end
  log('UEngine_patchConsoleKeys: write did not resolve ('..tostring(backName)..'); unpatched')
  return nil,'keys: write did not resolve ('..tostring(backName)..'); needs approach #2 AOB / programmatic'
end

-- ============================================================
-- Scanner-time hooks (SPLITFILE.md §5.3): called by UEInfoScanner,
-- guarded (pcall in the core), best-effort. Replicates the Tasks
-- 2–4 wiring that previously lived in UnrealEngine-75.LUA
-- (:3276–:3330). No-op failure modes only leave caches nil.
-- ============================================================
function UEngine_runConsoleScanHooks(t)
  -- Task 2 (Steps A+B): viewport offset discovery. Runs after
  -- findGameInstanceFPropertyAndFields so UEngine_getAllProperties can resolve
  -- GameViewport / ViewportConsole from the property link. Best-effort: failure
  -- only leaves the caches nil (Task 5/7 then record the repair as blocked).
  local vpR,vpErr=UEngine_discoverViewportOffsets()
  if not vpR then
    log('UEngine_discoverViewportOffsets: '..tostring(vpErr))
  end

  -- Task 3 (Step E): locate the Console UClass and cache it. Native engine classes
  -- persist in Shipping builds, so the primary array walk normally succeeds; the
  -- "any object named Console -> its class" / "CDO Default__Console -> its class"
  -- fallbacks cover stripped or renamed class objects. Read-only.
  if UEngine.ConsoleClassAddr==nil then
    local consoleClass=UEngine_findClassByName('Console',t)
    if consoleClass==nil then
      local anyConsole=UEngine_findObjectByName('Console',t)
      if anyConsole then
        local cc=readPointer(anyConsole+UEngine.UObject.Class)
        if cc then
          consoleClass=cc
          log('UEngine_findClassByName: using class of object "Console": '..tostring(UObject_getName(cc)))
        end
      end
      if consoleClass==nil then
        local defaultConsole=UEngine_findObjectByName('Default__Console',t)
        if defaultConsole then
          local cc=readPointer(defaultConsole+UEngine.UObject.Class)
          if cc then
            consoleClass=cc
            log('UEngine_findClassByName: using class of CDO Default__Console: '..tostring(UObject_getName(cc)))
          end
        end
      end
    end
    if consoleClass then
      UEngine.ConsoleClassAddr=consoleClass
      local cdo=UEngine_findObjectByName('Default__Console',t)
      log('UEngine_findClassByName: Console class at 0x'..string.format('%X',consoleClass)..' name='..tostring(UObject_getName(consoleClass))..' CDO='..tostring(cdo and 'present' or 'absent'))
    else
      log('UEngine_findClassByName: Console class NOT found (Task 4/7 will be blocked)')
    end
  end

  -- Task 4 (Step C): resolve + cache the ConsoleClass property offset and log the
  -- engine's current value. READ-ONLY at scan time: the write repair belongs to
  -- the orchestrator's REPAIR phase (Task 10), gated on the Task 5 assessment, so
  -- scanning a config-patched game does not mutate it. Caching the offset here
  -- means Task 5's probe reuses it instead of re-walking the property link.
  local ccR,ccErr=UEngine_resolveConsoleClassOffset()
  if ccR then
    log('Task 4 scanner: UEngine::ConsoleClass current value=0x'..string.format('%X',readPointer(UEngine.UGameEngine+UEngine.ConsoleClass) or 0))
  else
    log('Task 4 scanner: '..tostring(ccErr))
  end
end
