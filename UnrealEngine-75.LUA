-- UEInfoScanner and UEInfoStructureDissect combined and adapted for Cheat Engine 7.5
-- Licensed under the MIT License by Eric Heijnen / Cheat Engine
-- https://github.com/cheat-engine/UnrealEngineTools
--
-- Reload-safe: call UEngine_CE75_ReloadCleanup before re-dofile, or just dofile again
-- (cleanup runs automatically at top of this file).

-- Tear down previous load so dofile/autorun can re-run without restarting CE
if type(_G.UEngine_CE75_ReloadCleanup)=='function' then
  pcall(_G.UEngine_CE75_ReloadCleanup)
end

-- Always ensure global table exists at load (before any UEngine.* top-level init)
UEngine = UEngine or {}

-- CE 7.5 compatibility: ms.Results doesn't exist, use createFoundList
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

local debugUEInfoScanner=false

-- CE 7.5 compatibility: MemoryStream lacks readString/readWideString
local function streamReadString(s, maxlen)
  local chars={}
  for ci=1,maxlen do
    local b=s.readByte()
    if b==nil or b==0 then break end
    chars[ci]=string.char(b)
  end
  return table.concat(chars)
end

local function streamReadWideString(s, len)
  local chars={}
  for ci=1,len do
    local lo=s.readByte()
    local hi=s.readByte()
    if lo==nil or hi==nil then break end
    local cp=lo+hi*256
    if cp==0 then break end
    chars[ci]=string.char(cp)
  end
  return table.concat(chars)
end

local function log(str)
  if UEngine==nil then
    UEngine={}
    UEngine.processid=getOpenedProcessID()
  end

  if UEngine.log==nil then
    UEngine.log=''
  end

  UEngine.log=UEngine.log..str..'\n\r'
end

function UObject_getName(UObjectAddress)
  if UEngine==nil or UEngine.UObject==nil or UEngine.UObject.Name==nil or UEngine.IndexToName==nil then
    return nil,'UEngine.UObject.Name not initialized yet'
  end

  local vftableptr=readPointer(UObjectAddress)
  if vftableptr and vftableptr>=getAddress(process) and vftableptr<getAddress(process)+getModuleSize(process) then
    local i=readQword(UObjectAddress+UEngine.UObject.Name)
    local index=i & 0xffffffff
    local number=i >> 32
    local name=UEngine.IndexToName[i&0xffffffff]

    if name and number>0 then
      name=name..'_'..number
    end

    return name
  end
end

function UObject_enumProperties(address)
  local class=readPointer(address+UEngine.UObject.Class)
  if class then
    return UClass_enumProperties(class)
  else
    return nil,'Failure to read class field'
  end
end

function UClass_enumProperties(class,usealt,r)
  if not r then
    r={}
  end

  if UEngine==nil or UEngine.FProperty==nil or UEngine.FProperty.Offset==nil then
    return nil,'UEngine.FProperty.Offset is nil'
  end

  if UEngine.UClass.SuperStruct then
    local super=readPointer(class+UEngine.UClass.SuperStruct)
    if super then
      UClass_enumProperties(super,usealt,r)
    end
  end

  local p
  if not usealt then
    if UEngine.UClass.PropertyLink then
      p=readPointer(class+UEngine.UClass.PropertyLink)
    end
  end

  if p==nil or p==0 then
    if UEngine.UClass.PropertyLinkAlt then
      p=readPointer(class+UEngine.UClass.PropertyLinkAlt)
    end
  end
  if p and p~=0 then
    while p and p~=0 do
      e={}
      if not UEngine.FProperty.PropertyLinkNext then
        log('UClass_enumProperties: WARNING - PropertyLinkNext is nil, stopping traversal')
        break
      end
      local v=readInteger(p+UEngine.FProperty.Name)
      local name=UEngine.IndexToName[v]
      if v and name then
        local offset=readInteger(p+UEngine.FProperty.Offset)

        e.offset=offset
        e.propertyAddress=p

        local c=readPointer(p+UEngine.FProperty.Class)
        if c==nil then
          return nil,'c was nil'
        end
        local nameIndex=readInteger(c+UEngine.FFieldClass.Name)

        if nameIndex==nil then
          return nil,'nameIndex==nil'
        end

        e.propertyType=UEngine.IndexToName[nameIndex]

        if UEngine.FProperty.Size then
          e.size=readInteger(p+UEngine.FProperty.Size)
        end

        r[name]=e
      end

      p=readPointer(p+UEngine.FProperty.PropertyLinkNext)
    end

    return r
  else
    return nil,'No propertylink found'
  end
end

function UEngine_getAllProperties(classPtr)
  if classPtr==nil or classPtr==0 then return nil end
  local props=UClass_enumProperties(classPtr, false)
  if props==nil then
    props=UClass_enumProperties(classPtr, true)
  else
    UClass_enumProperties(classPtr, true, props)
  end
  return props
end

function UEngine_searchProps(classPtr, keyword)
  local props=UEngine_getAllProperties(classPtr)
  if props==nil then return {} end
  local results={}
  local kw=keyword:lower()
  for name, info in pairs(props) do
    if name:lower():find(kw) then
      results[name]=info
    end
  end
  return results
end

function UEngine_readTArrayElement(baseAddr, propOffset, index)
  local dataPtr=readPointer(baseAddr+propOffset)
  local count=readInteger(baseAddr+propOffset+8)
  if dataPtr==nil or dataPtr==0 or count==nil or index>=count then
    return nil, count
  end
  local ps=8
  if processhandler and processhandler.pointersize then ps=processhandler.pointersize end
  local elemPtr=readPointer(dataPtr+index*ps)
  return elemPtr, count
end

function UEngine_dumpAllProperties(classPtr, className)
  if className==nil then
    className=UObject_getName(classPtr) or 'Unknown'
  end
  local props=UEngine_getAllProperties(classPtr)
  if props==nil then
    print('  No properties found for '..className)
    return
  end
  local count=0
  for _ in pairs(props) do count=count+1 end
  print(string.format('  Properties of %s (%d):', className, count))
  for name, info in pairs(props) do
    local extra=''
    if info.size then extra=' sz='..info.size end
    print(string.format('    %s @ +0x%X (%s%s)', name, info.offset, tostring(info.propertyType), extra))
  end
end

function getSuperListFromField(FieldAddress)
  if not FieldAddress or FieldAddress==0 then return nil end
  local ok,p0=pcall(readPointer, FieldAddress)
  if not ok or not p0 or p0==0 then return nil end
  if isVTable(p0) then
    local Names={}

    if not UEngine.FField or not UEngine.FField.Name then return nil end
    local ok2,nameindex=pcall(readQword, FieldAddress+UEngine.FField.Name)
    if not ok2 or not nameindex then return nil end
    local name=UEngine.IndexToName[nameindex]
    if name then
      if not UEngine.FField.Class then return nil end
      local class=readPointer(FieldAddress+UEngine.FField.Class)
      while class and class~=0 do
        if not UEngine.FFieldClass or not UEngine.FFieldClass.Name then return nil end
        nameindex=readQword(class+UEngine.FFieldClass.Name)
        if nameindex==nil then return nil end

        name=UEngine.IndexToName[nameindex]
        if name==nil then return nil end

        table.insert(Names,name)

        if not UEngine.FFieldClass.SuperClass then return nil end
        class=readPointer(class+UEngine.FFieldClass.SuperClass)
      end

      return Names
    end
  end
  return nil
end

function testIfSuperStructOffset(classAddress, offset)
  local depth=0
  local super={}
  local class=readPointer(classAddress+offset)
  while class and (class~=0) do
    local n=UObject_getName(class)
    if n then
      table.insert(super, n)
    else
      return nil
    end

    local newclass=readPointer(class+offset)
    if newclass==class then return nil end

    class=newclass
    depth=depth+1

    if depth>20 then return nil end
  end

  return super
end

function getSuperListFromObject(ObjectAddress)
  local super={}
  -- UE5: walk via SuperStruct (UStruct inheritance chain), not UObject.Class (metaclass chain)
  local superStructOffset = UEngine.UStruct and UEngine.UStruct.SuperStruct
  if superStructOffset then
    local class=readPointer(ObjectAddress+UEngine.UObject.Class)
    local seen={}
    while class and class~=0 do
      if seen[class] then break end
      seen[class]=true
      local n=UObject_getName(class)
      if n then table.insert(super, n)
      else
        return nil
      end
      class=readPointer(class+superStructOffset)
    end
  else
    local class=readPointer(ObjectAddress+UEngine.UObject.Class)
    local seen={}
    while class and class~=0 do
      if seen[class] then break end
      seen[class]=true
      local n=UObject_getName(class)
      if n then table.insert(super, n)
      else
        return nil
      end
      class=readPointer(class+UEngine.UObject.Class)
    end
  end

  return super
end

function GetLinkedListSize(p,LinkOffset)
  local c=0

  repeat
    p=readPointer(p+LinkOffset)
    if p and p~=nil and p~=0 then
      c=c+1
    end
  until p==nil or p==0 or c>100000
  return c
end

function UEngine_findObjectStart(startAddress)
  if UEngine.UObject and UEngine.UObject.Class and UEngine.UObject.Name then
    local address=startAddress
    address=address & 0xfffffffffffffff8

    c=0
    while c<4000 do
      local p=readPointer(address)
      if p==nil then
        return nil,'encountered unreadable memory'
      end

      if isVTable(p) then
        if readInteger(address+UEngine.UObject.Name)~=0 then
          if UObject_getName(address) then
            local pl
            pl=UObject_enumProperties(address)

            if pl then
              for propname,data in pairs(pl) do
                if address+data.offset+data.size>startAddress then return address end
              end
            end
          end
        end
      end
      address=address-8
      c=c+1
    end
  end
end

function UEngine_findStructureStart(address)
  address=address & 0xfffffffffffffff8

  c=0
  while c<100 do
    local p=readPointer(address)
    if p==nil then
      return nil,'encountered unreadable memory'
    end

    if isVTable(p) then
      return address
    end
    address=address-8
    c=c+1
  end
end

function findGameInstanceFPropertyAndFields(t)
  if not UEngine.UGameEngine then return nil,'Find UGameEngine and GameEngineClass first' end
  if not UEngine.GameEngineClass then return nil,'Find the GameEngineClass first' end

  local index=UEngine.NameToIndex['GameInstance']
  if index==nil then return nil,'GameInstance not found in name pool' end
  log('findGameInstanceFPropertyAndFields: GameInstance name index='..tostring(index)..' type='..type(index))
  local ms=createMemScan()
  ms.VarType=vtDword
  ms.ScanValue=index
  log('findGameInstanceFPropertyAndFields: ScanValue set to "'..tostring(ms.ScanValue)..'" VarType=vtDword')
  ms.Fastscanmethod=fsmAligned
  ms.Fastscanparameter=4

  log('scanning GameInstance')
  ms.scan()
  ms.waitTillDone()

  local errstr=ms.ErrorString
  local r=getMemScanResults(ms)
  ms.destroy()
  ms=nil

  if errstr and errstr~='' then
    return nil,errstr
  end

  if #r==0 then
    log('findGameInstanceFPropertyAndFields: scan returned 0 results')
    return nil,'Failure finding references to the GameInstance FProperty'
  end

  log('findGameInstanceFPropertyAndFields: scan returned '..#r..' results, GameEngineClass='..string.format('0x%X',UEngine.GameEngineClass))

  local FPropertyOwnerOffset
  local GameInstanceFProperty

  -- UE5 approach: FField has no vtable, so findStructureStart fails.
  -- In UE5 FField layout: +0=ClassPrivate, +8=OwnerPrivate, +16=Name(FName), +24=Next
  -- The vtDword scan found the DWORD ComparisonIndex at r[i] = FField+16
  -- So FField starts at r[i] - 16. Verify by checking ClassPrivate and OwnerPrivate.
  for i=1,#r do
    local ffield_start = r[i] - 16
    if ffield_start > 0 then
      local classPtr = readPointer(ffield_start)       -- ClassPrivate at +0
      local ownerRaw = readPointer(ffield_start + 8)   -- OwnerPrivate at +8

      if classPtr and classPtr ~= 0 and ownerRaw and ownerRaw ~= 0 then
        local masked = ownerRaw & 0xfffffffffffffff8
        if masked == UEngine.GameEngineClass then
          -- Verify ClassPrivate points to an FFieldClass with a name ending in 'Property'
          local classNameIdx = readQword(classPtr)
          local className = classNameIdx and UEngine.IndexToName[classNameIdx]
          if className and className:endsWith('Property') then
            GameInstanceFProperty = ffield_start
            FPropertyOwnerOffset = 8
            -- Set known UE5 FField offsets directly (no vtable, so the loop can't discover Class)
            UEngine.FProperty.Class = 0
            UEngine.FFieldClass = {}
            UEngine.FFieldClass.Name = 0
            -- Find SuperClass in FFieldClass
            for j=0,16 do
              local sv = readPointer(classPtr + j*8)
              if sv and sv ~= 0 then
                local ok2,sv2 = pcall(readQword, sv)
                if ok2 and sv2 then
                  local sname = UEngine.IndexToName[sv2]
                  if sname and (sname:endsWith('Property') or sname:endsWith('PropertyBase') or sname=='Field') then
                    UEngine.FFieldClass.SuperClass = j*8
                    log('findGameInstanceFPropertyAndFields: FFieldClass.SuperClass='..(j*8)..' name='..sname)
                    break
                  end
                end
              end
            end
            log('findGameInstanceFPropertyAndFields: UE5 FField found at '..string.format('0x%X',ffield_start)..' (scan result '..i..'), ClassPrivate='..className..', OwnerOffset=8')
            break
          else
            if i <= 5 then log('findGameInstanceFPropertyAndFields: result '..i..' ClassPrivate name not a Property: '..tostring(className)) end
          end
        end
      end
    end
  end

  -- Fallback: try UE4-style vtable-based approach
  if not GameInstanceFProperty then
    log('findGameInstanceFPropertyAndFields: UE5 direct approach failed, trying UE4 vtable fallback')
    local bases={}
    for i=1,#r do
      local base=UEngine_findStructureStart(r[i])
      if base then
        table.insert(bases,base)
      end
    end

    log('findGameInstanceFPropertyAndFields: '..#bases..' vtable bases found from '..#r..' results')

    for i=1,#bases do
      for j=1,32 do
        local p=readPointer(bases[i]+j*8)
        local masked=p and (p & 0xfffffffffffffff8) or 0
        if masked==UEngine.GameEngineClass then
          log('findGameInstanceFPropertyAndFields: UE4 base '..i..' base='..string.format('0x%X',bases[i])..' GameEngineClass match at offset '..(j*8))
          if FPropertyOwnerOffset then
            if FPropertyOwnerOffset>j*8 then
              FPropertyOwnerOffset=j*8
              GameInstanceFProperty=bases[i]
            end
          else
            FPropertyOwnerOffset=j*8
            GameInstanceFProperty=bases[i]
          end
          break
        end
      end
    end
  end

  if not GameInstanceFProperty then
    log('findGameInstanceFPropertyAndFields: GameInstanceFProperty not found')
    return nil,'GameInstanceFProperty not found'
  end

  if GameInstanceFProperty then
    log('findGameInstanceFPropertyAndFields: GameInstanceFProperty='..string.format('0x%X',GameInstanceFProperty)..' OwnerOffset='..FPropertyOwnerOffset)
    if not UEngine.FProperty then UEngine.FProperty={} end
    UEngine.FProperty.Owner=FPropertyOwnerOffset

    local potentialPropertyLists={}

    for i=1,64 do
      local p=GameInstanceFProperty+i*4
      local pp=readPointer(p)
      if pp==nil then
        log('findGameInstanceFPropertyAndFields: FProperty scan ended at i='..i..', readPointer returned nil (unreadable)')
        break
      end
      local pi=pp & 0xffffffff

      if pp~=0 and isVTable(pp) then
        log('findGameInstanceFPropertyAndFields: FProperty scan ended at i='..i..', vtable detected at '..string.format('0x%X',pp))
        break
      end

      if UEngine.FProperty.Name==nil then
        if pi==index then
          UEngine.FProperty.Name=i*4
          log('findGameInstanceFPropertyAndFields: FProperty.Name found at offset '..(i*4))
        end
      end

      if (UEngine.FProperty.Offset==nil) and (pi>8) and (pi<0x9000) and ((pi & 7) == 0) then
        local potentialGameInstanceObject=readPointer(UEngine.UGameEngine+pi)
        if potentialGameInstanceObject and potentialGameInstanceObject~=0 then
          local name=UObject_getName(potentialGameInstanceObject)
          if name then
             if i<=20 then log('findGameInstanceFPropertyAndFields: candidate offset '..(i*4)..' pi='..pi..' name='..name) end
             local superlist=getSuperListFromObject(potentialGameInstanceObject)
             if superlist then
               for j=1,#superlist do
                 if superlist[j]=='GameInstance' then
                   UEngine.FProperty.Offset=i*4
                   log('findGameInstanceFPropertyAndFields: FProperty.Offset found at '..(i*4)..' via '..name..'->GameInstance')
                 end
               end
             end
          end
        end
      end

      if (i & 0x1==0) and (pp & 0x7==0) then
        if UEngine.FProperty.Class==nil then
          for j=0,16 do
            local ok,v=pcall(readQword,pp+j*4)
            if ok and v then
              local n=UEngine.IndexToName[v]
              if n then
                if n:endsWith('Property') then
                  UEngine.FProperty.Class=i*4
                  UEngine.FFieldClass={}
                  UEngine.FFieldClass.Name=j*4
                  log('findGameInstanceFPropertyAndFields: FProperty.Class found at offset '..(i*4)..', FFieldClass.Name at '..(j*4)..', className='..n)
                  break
                end
              end
            end
          end

          if UEngine.FProperty.Class and UEngine.FFieldClass.Name then
            local pf=readPointer(GameInstanceFProperty+UEngine.FProperty.Class)
            if pf and pf~=0 then
              for j=0,16 do
                local v=readPointer(pf+j*8)
                if v and v~=0 then
                  local ok2,v2=pcall(readQword,v+UEngine.FFieldClass.Name)
                  if ok2 and v2 then
                    local name=UEngine.IndexToName[v2]
                    if name and (name:endsWith('Property') or name:endsWith('PropertyBase') or name=='Field') then
                      UEngine.FFieldClass.SuperClass=j*8
                      log('findGameInstanceFPropertyAndFields: FFieldClass.SuperClass found at '..(j*8)..', name='..name)
                      break
                    end
                  end
                end
              end
            else
              log('findGameInstanceFPropertyAndFields: WARNING - FProperty.Class ptr at offset '..UEngine.FProperty.Class..' returned nil/0 pointer '..string.format('0x%X',GameInstanceFProperty+UEngine.FProperty.Class))
            end
          end
        end
        table.insert(potentialPropertyLists, i*4)
      end
    end

    log('findGameInstanceFPropertyAndFields: FProperty.Name='..tostring(UEngine.FProperty and UEngine.FProperty.Name)..' FProperty.Class='..tostring(UEngine.FProperty and UEngine.FProperty.Class)..' FProperty.Offset='..tostring(UEngine.FProperty and UEngine.FProperty.Offset)..' FProperty.Owner='..tostring(UEngine.FProperty and UEngine.FProperty.Owner)..' FFieldClass.Name='..tostring(UEngine.FFieldClass and UEngine.FFieldClass.Name)..' potentialPropertyLists='..#potentialPropertyLists)
    if UEngine.FProperty and UEngine.FFieldClass and UEngine.FFieldClass.Name and UEngine.FProperty.Class and UEngine.FProperty.Name and UEngine.FProperty.Offset and UEngine.FProperty.Owner then
      log('findGameInstanceFPropertyAndFields: All FProperty fields found, building FField and PropertyLinks')
      UEngine.FField={}
      UEngine.FField.Class=UEngine.FProperty.Class
      UEngine.FField.Owner=UEngine.FProperty.Owner
      UEngine.FField.Name=UEngine.FProperty.Name

      local PropertyLinkNextOffset
      local BestPropertyCount

      for i=1,#potentialPropertyLists do
        local p=readPointer(GameInstanceFProperty+potentialPropertyLists[i])
        if p and p~=0 then
          local superlist=getSuperListFromField(p)

          if superlist and (
                            ((#superlist>=2) and (superlist[#superlist]=='Field') and (superlist[#superlist-1]=='Property'))
                            or
                            ((#superlist>=3) and (superlist[#superlist]=='Object') and (superlist[#superlist-1]=='Field') and (superlist[#superlist-2]=='Property'))
                            )
          then
            local c=GetLinkedListSize(GameInstanceFProperty, potentialPropertyLists[i])
            if PropertyLinkNextOffset==nil or c>BestPropertyCount then
              PropertyLinkNextOffset=potentialPropertyLists[i]
              BestPropertyCount=c
            end
          end
        end
      end
      UEngine.FProperty.PropertyLinkNext=PropertyLinkNextOffset
      log('findGameInstanceFPropertyAndFields: PropertyLinkNext='..tostring(PropertyLinkNextOffset))

      local PropertyLinkOffset
      BestPropertyCount=0
      local altoffset
      for i=1,100 do
        local p=readPointer(UEngine.GameEngineClass+i*8)
        if p and p~=0 and isVTable(p) then
          log('findGameInstanceFPropertyAndFields: PropertyLink scan stopped at i='..i..', vtable at '..string.format('0x%X',p))
          break
        end

        local superlist=getSuperListFromField(p)
        if superlist and (
                          ((#superlist>=2) and (superlist[#superlist]=='Field') and (superlist[#superlist-1]=='Property'))
                          or
                          ((#superlist>=3) and (superlist[#superlist]=='Object') and (superlist[#superlist-1]=='Field') and (superlist[#superlist-2]=='Property'))
                          )
        then
          if not UEngine.FProperty.PropertyLinkNext then
            log('findGameInstanceFPropertyAndFields: WARNING - PropertyLinkNext is nil, skipping GetLinkedListSize')
          else
            local c=GetLinkedListSize(p, UEngine.FProperty.PropertyLinkNext)
            if PropertyLinkOffset==nil or c>=BestPropertyCount then
              altoffset=PropertyLinkOffset
              PropertyLinkOffset=i*8
              BestPropertyCount=c
            end
          end
        end
      end

      UEngine.UClass.PropertyLink=PropertyLinkOffset
      UEngine.UClass.PropertyLinkAlt=altoffset
      log('findGameInstanceFPropertyAndFields: PropertyLink='..tostring(PropertyLinkOffset)..' PropertyLinkAlt='..tostring(altoffset))

      log('findGameInstanceFPropertyAndFields: calling UClass_enumProperties')
      local gameEngineProperties=UClass_enumProperties(UEngine.GameEngineClass)
      if gameEngineProperties==nil then
        log('findGameInstanceFPropertyAndFields: UClass_enumProperties returned nil!')
        return nil,'UClass_enumProperties returned nil'
      end
      log('findGameInstanceFPropertyAndFields: UClass_enumProperties returned '..select('#',next(gameEngineProperties))..' properties')
      local sizes={}
      sizes[1]={}
      sizes[4]={}
      sizes[8]={}
      local bools={}

      for pname, info in pairs(gameEngineProperties) do
        if info.propertyType=='FloatProperty' then
          if #sizes[4]<10 then
            table.insert(sizes[4],info.propertyAddress)
          end
        elseif info.propertyType=='IntProperty' then
          if #sizes[4]<10 then
            table.insert(sizes[4],info.propertyAddress)
          end
        elseif info.propertyType=='ObjectProperty' then
          if #sizes[8]<10 then
            table.insert(sizes[8],info.propertyAddress)
          end
        elseif info.propertyType=='ClassProperty' then
          if #sizes[8]<10 then
            table.insert(sizes[8],info.propertyAddress)
          end
        elseif info.propertyType=='BoolProperty' then
          if #sizes[1]<10 then
            table.insert(sizes[1],info.propertyAddress)
          end

          if bools[info.offset]==nil then
            bools[info.offset]={}
          end

          table.insert(bools[info.offset], info.propertyAddress)
        end
      end

      log('findGameInstanceFPropertyAndFields: sizes: bool='..#sizes[1]..' float/int='..#sizes[4]..' obj/class='..#sizes[8]..' boolOffsets='..#bools)

      for i=2,64 do
        local foundsize=true
        for size,addresslist in pairs(sizes) do
          for j=1,#addresslist do
            if readInteger(addresslist[j]+i*4)~=size then
              foundsize=false
              break
            end
          end
          if foundsize==false then break end
        end

        if foundsize then
          UEngine.FProperty.Size=i*4
          log('findGameInstanceFPropertyAndFields: FProperty.Size='..i*4)
          break
        end
      end

      local multibitfields={}
      local couldbefullbyte=false
      for offset,addresslist in pairs(bools) do
        if #addresslist>1 then
          table.insert(multibitfields,addresslist)
        end
      end

      if #multibitfields==0 then
        couldbefullbyte=true
        for offset,addresslist in pairs(bools) do
          table.insert(multibitfields,addresslist)
        end
      end

      if not PropertyLinkNextOffset then
        log('findGameInstanceFPropertyAndFields: ERROR - PropertyLinkNextOffset is nil, cannot compute startIndex')
        return nil,'PropertyLinkNextOffset is nil'
      end

      local startIndex=UEngine.FProperty.PropertyLinkNext // 8+1
      log('findGameInstanceFPropertyAndFields: BitMaskField scan starting at index '..startIndex..', multibitfields='..#multibitfields..', couldbefullbyte='..tostring(couldbefullbyte))

      local isSingleBit={}
      isSingleBit[1]=true
      isSingleBit[2]=true
      isSingleBit[4]=true
      isSingleBit[8]=true
      isSingleBit[16]=true
      isSingleBit[32]=true
      isSingleBit[64]=true
      isSingleBit[128]=true

      for i=startIndex,64 do
        local foundbitmaskfield=true
        for j=1,#multibitfields do
          for k=1,#multibitfields[j] do
            local v=readInteger(multibitfields[j][k]+i*4)
            if v==nil then
              log('findGameInstanceFPropertyAndFields: readInteger returned nil at '..string.format('0x%X',multibitfields[j][k]+i*4))
              foundbitmaskfield=false
              break
            end
            local b1=v & 0xff
            if b1~=1 then
              foundbitmaskfield=false
              break
            end

            local b2=(v >> 8) & 0xff
            if b2~=0 then
              foundbitmaskfield=false
              break
            end

            local b3=(v >> 16) & 0xff;
            if not isSingleBit[b3] then
              if (couldbefullbyte==false) or (b3~=0xff) then
                foundbitmaskfield=false
                break
              end
            end

            local b4=(v >> 24) & 0xff;
            if not isSingleBit[b4] then
              if (couldbefullbyte==false) or (b4~=0xff) then
                foundbitmaskfield=false
                break
              end
            end
          end
          if foundbitmaskfield==false then break end
        end
        if foundbitmaskfield then
          UEngine.FProperty.BitMaskField=i*4
          UEngine.FProperty.ObjectClassType=i*4
          log('findGameInstanceFPropertyAndFields: BitMaskField/ObjectClassType found at offset '..(i*4))
          break
        end
      end

      log('findGameInstanceFPropertyAndFields: SUCCESS')
      return true, 'success'
    else
      log('findGameInstanceFPropertyAndFields: FAILED - missing fields: Name='..tostring(UEngine.FProperty and UEngine.FProperty.Name)..' Class='..tostring(UEngine.FProperty and UEngine.FProperty.Class)..' Offset='..tostring(UEngine.FProperty and UEngine.FProperty.Offset)..' Owner='..tostring(UEngine.FProperty and UEngine.FProperty.Owner)..' FFieldClass.Name='..tostring(UEngine.FFieldClass and UEngine.FFieldClass.Name))
      return nil,'Not all needed fields where found'
    end
  else
    return nil, 'Failed finding GameInstanceFProperty'
  end

  return nil,'huh?'
end

function FindGEngine(t)
  if UEngine.UObject.Name==nil then
    return nil,'UEngine.UObject.Name==nil'
  end
  local index=UEngine.NameToIndex['GameEngine']

  if index==nil then return false, "failure finding GameEngine string" end

  log('FindGEngine: scanning for dword='..index..' (GameEngine name index)')

  local ms=createMemScan()
  ms.VarType=vtDword
  ms.Fastscanmethod=fsmAligned
  ms.Fastscanparameter=4
  ms.Scanvalue=index
  ms.ScanWritable='scanInclude'
  ms.scan()
  ms.waitTillDone()
  local r=getMemScanResults(ms)
  ms.destroy() ms=nil

  if t and t.Terminated then return nil,'terminated' end

  log('FindGEngine: '..#r..' raw name index matches')
  log('FindGEngine: UObject.Name offset='..tostring(UEngine.UObject.Name)..' UObject.Class offset='..tostring(UEngine.UObject.Class))

  local r2={}
  for i=1,#r do
    local nameAddr=r[i]
    local objAddr=nameAddr-UEngine.UObject.Name
    log('FindGEngine: candidate '..i..': nameAddr='..string.format('0x%X',nameAddr)..' objAddr='..string.format('0x%X',objAddr))
    if objAddr>0 then
      local vt=readPointer(objAddr)
      local vtHex=vt and string.format('0x%X',vt) or 'nil'
      local inMod=false
      if vt then
        local mstart=getAddress(process)
        local mstop=mstart+getModuleSize(process)
        inMod=(vt>mstart and vt<mstop)
      end
      log('FindGEngine:   vt='..vtHex..' inModule='..tostring(inMod))
      if vt and isVTable(vt) then
        table.insert(r2,objAddr)
        log('FindGEngine:   -> VALID UObject candidate')
      else
        log('FindGEngine:   -> rejected by isVTable')
      end
    end
  end

  log('FindGEngine: '..#r2..' UObject candidates with GameEngine name')

  if #r2==0 then
    return nil,'FindGEngine: no candidates found'
  end

  if #r2>1 and UEngine.UObject.Class then
    log('FindGEngine: multiple candidates, filtering by Class field name')
    local filtered={}
    for i=1,#r2 do
      local classPtr=readPointer(r2[i]+UEngine.UObject.Class)
      local className=classPtr and UObject_getName(classPtr) or nil
      log('FindGEngine: candidate '..i..' ('..string.format('0x%X',r2[i])..') Class->'..tostring(className))
      if className and className~='Class' then
        table.insert(filtered,r2[i])
        log('FindGEngine:   -> kept (Class name is not "Class", likely an instance)')
      else
        log('FindGEngine:   -> skipped (Class name is "Class", this is a UClass object)')
      end
    end
    if #filtered>0 then
      r2=filtered
      log('FindGEngine: '..#r2..' candidates after filtering')
    else
      log('FindGEngine: filtering removed all candidates, using original list')
    end
  end

  UEngine.UGameEngine=r2[1]
  log('FindGEngine: found GEngine at '..string.format('0x%X',UEngine.UGameEngine))

  local ms2=createMemScan()
  ms2.VarType=vtQword
  ms2.ScanValue=UEngine.UGameEngine
  ms2.Startaddress=getAddress(process)
  ms2.Stopaddress=getAddress(process)+getModuleSize(process)
  ms2.scan()
  r=getMemScanResults(ms2)
  ms2.destroy()

  if #r>=1 then
    UEngine.GEngine=r[1]
    unregisterSymbol('GEngine')
    local n=getNameFromAddress(UEngine.GEngine,true,false,false)
    registerSymbol('GEngine',n)

    if #r>1 then
      for i=2,#r do
        local name='GEngine'..i
        UEngine[name]=r[i]
        unregisterSymbol(name)
        local n2=getNameFromAddress(UEngine[name],true,false,false)
        registerSymbol(name,n2)
      end
    end
  end

  return true
end

function isInExecutableMainModuleMemory(address)
  if UEngine.ExecutableRanges==nil then
    UEngine.ExecutableRanges={}

    if UEngine.VFTableInExecutableMemoryMethod==nil or UEngine.VFTableInExecutableMemoryMethod==2 then
      local mr=enumMemoryRegions()
      local goodrangestart=getAddress(process)
      local goodrangestop=getAddress(process)+getModuleSize(process)

      for i=1,#mr do
        if mr[i].BaseAddress>=goodrangestart and mr[i].BaseAddress+mr[i].RegionSize<=goodrangestop then
          if mr[i].Protect then
            local p=string.lower(tostring(mr[i].Protect))
            if p:find('execute') then
              local e={}
              e.start=mr[i].BaseAddress
              e.stop=mr[i].BaseAddress+mr[i].RegionSize
              table.insert(UEngine.ExecutableRanges,e)
              if UEngine.VFTableInExecutableMemoryMethod==nil then
                break
              end
            end
          end
        end
      end
    end

    if #UEngine.ExecutableRanges==0 then
      local goodrangestart=getAddress(process)
      local goodrangestop=getAddress(process)+getModuleSize(process)

      local executablePageProtect={}
      executablePageProtect[PAGE_EXECUTE]=true
      executablePageProtect[PAGE_EXECUTE_READ]=true
      executablePageProtect[PAGE_EXECUTE_READWRITE]=true
      executablePageProtect[PAGE_EXECUTE_WRITECOPY]=true

      local mr=enumMemoryRegions()
      for i=1,#mr do
        if executablePageProtect[mr[i].Protect] and (mr[i].BaseAddress>=goodrangestart) and (mr[i].BaseAddress+mr[i].RegionSize<goodrangestop) then
          local e={}
          e.start=mr[i].BaseAddress
          e.stop=mr[i].BaseAddress+mr[i].RegionSize
          table.insert(UEngine.ExecutableRanges,e)
        end
      end
    end
  end

  local er=UEngine.ExecutableRanges

  for i=1,#er do
    if address>er[i].start and address<er[i].stop then
      return true
    end
  end

  return false
end

function isVTable(address)
  if address==nil then return nil,'invalid address' end
  local goodrangestart=getAddress(process)
  local goodrangestop=getAddress(process)+getModuleSize(process)

  if address>goodrangestart and address<goodrangestop then
    for i=0,8 do
      local p=readPointer(address+i*8)
      if isInExecutableMainModuleMemory(p)==false then
        return false
      end
    end

    return true
  else
    return false;
  end
end
function InitializeUObjectArray_Verifier_Type()
  UObjectArray_Verifier_Type=true
end

function FindObjectArray(t)
  local r={}

  if UObjectArray_Verifier_Type==nil then
    InitializeUObjectArray_Verifier_Type()
  end

  if UEngine.ObjectArray==nil then
    log('FindObjectArray: scanning module memory for [N,N-1,N,0,ptr] pattern')

    local mstart=getAddress(process)
    local mstop=mstart+getModuleSize(process)

    local CHUNK=4*1024*1024
    local addr=mstart

    while addr<mstop do
      local remaining=mstop-addr
      local sz=math.min(CHUNK,remaining)
      local ok,data=pcall(readBytes,addr,sz,true)

      if ok and type(data)=='table' and #data>=24 then
        local limit=#data-23
        local pos=1
        while pos<=limit do
          if data[pos+12]==0 and data[pos+13]==0 and
             data[pos+14]==0 and data[pos+15]==0 then

            local v0=data[pos]+data[pos+1]*256+data[pos+2]*65536+data[pos+3]*16777216

            if v0>100 then
              local v4=data[pos+4]+data[pos+5]*256+data[pos+6]*65536+data[pos+7]*16777216

              if v4==v0-1 then
                local v8=data[pos+8]+data[pos+9]*256+data[pos+10]*65536+data[pos+11]*16777216

                if v8==v0 then
                  local memAddr=addr+pos-1
                  local ptr=readPointer(memAddr+16)
                  if ptr and ptr~=0 and readPointer(ptr) then
                    table.insert(r,memAddr)
                    log('  candidate: N='..v0..' at 0x'..string.format('%x',memAddr))
                  end
                end
              end
            end
          end
          pos=pos+8
        end
      end

      if t and t.Terminated then return false,'UEInfoScannerThread terminated' end
      addr=addr+sz
    end

    log('FindObjectArray: '..#r..' candidates found')

    if #r==0 then
      return false,'FindObjectArray: no valid ObjectArray found in module memory'
    end

    if #r>1 then
      local r2={}
      for i=1,#r do
        if readInteger(r[i])>100 then
          table.insert(r2,r[i])
        end
      end
      r=r2
    end

    if #r>1 then
      local r2={}
      for i=1,#r do
        local p=readPointer(r[i]+0x10)
        if p and readPointer(readPointer(p)) then
          table.insert(r2,r[i])
        end
      end
      r=r2

      if #r>1 then
        return false,'FindObjectArray needs more refining',r
      end
    end
  else
    r={}
    r[1]=UEngine.ObjectArray
  end

  if t and t.Terminated then return false, 'UEInfoScannerThread terminated' end

  if #r==1 then
    UEngine.ObjectArray=r[1]

    local p=readPointer(UEngine.ObjectArray+0x10)
    if p then
      if readByte(readPointer(p)) and readByte(readPointer(p+8)) then
        UEngine.ObjectArrayListType=0
        p=readPointer(p)
      else
        UEngine.ObjectArrayListType=1

        local ObjectListAddress=readPointer(p)
        local FirstObject=readPointer(ObjectListAddress)
        local vftable=readPointer(FirstObject)

        if vftable then
          local f1,f2,f3=readPointer(vftable), readPointer(vftable+8), readPointer(vftable+16)
          if isInExecutableMainModuleMemory(f1) and isInExecutableMainModuleMemory(f2) and isInExecutableMainModuleMemory(f3) then
            UEngine.ObjectArrayListType=0
            p=ObjectListAddress
          end
        end
      end

      local goodrangestart=getAddress(process)
      local goodrangestop=getAddress(process)+getModuleSize(process)

      local sections=nil
      if enumSectionsOfModule then
        sections=enumSectionsOfModule(process)
      end

      local object1=readPointer(p)
      local vftable=readPointer(object1)
      local firstfunctionaddress=readPointer(vftable)
      if firstfunctionaddress then
        if sections then
          for i=1,#sections do
            if firstfunctionaddress>=sections[i].Address and firstfunctionaddress<sections[i].Address+sections[i].Size then
              if sections[i].IsCode and sections[i].IsExecutable then
                UEngine.ExecutableRanges={}
                UEngine.ExecutableRanges[1]={}
                UEngine.ExecutableRanges[1].start=sections[i].Address
                UEngine.ExecutableRanges[1].stop=sections[i].Address+sections[i].Size
              end
              break
            end
          end
        end
      else
        log('FindObjectArray: doesn\'t look like a valid object')
      end

      local validpointers={}
      for i=0,32 do
        local p1=readPointer(p+(i*4))
        local pv=readPointer(p1)

        if isVTable(pv) then
          table.insert(validpointers, (i*4))
        end
      end

      if #validpointers==0 then
        UEngine.VFTableInExecutableMemoryMethod=2
        UEngine.ExecutableRanges=nil

        for i=0,32 do
          local p1=readPointer(p+(i*4))
          local pv=readPointer(p1)

          if isVTable(pv) then
            table.insert(validpointers, (i*4))
          end
        end

        if #validpointers==0 then
          UEngine.VFTableInExecutableMemoryMethod=3
          UEngine.ExecutableRanges=nil

          for i=0,32 do
            local p1=readPointer(p+(i*4))
            local pv=readPointer(p1)

            if isVTable(pv) then
              table.insert(validpointers, (i*4))
            end
          end
        end
      end

      if #validpointers<=1 then
        return false,"can't find figure out ObjectArrayEntryStruct size"
      end
      UEngine.ObjectArrayEntryStructSize=validpointers[2]-validpointers[1]

      local classPointerOffsetCount={}
      local nameoffsetcount={}

      local ClassNameIndex=UEngine.NameToIndex['Class']
      if ClassNameIndex==nil then
        return false,'There is no Class class'
      end

      for i=1,#validpointers do
        local objectaddress=readPointer(p+validpointers[i])
        for j=1,10 do
          local ep=readPointer(objectaddress+j*8)
          local depth=0
          while depth<20 do
            local newp=readPointer(ep+j*8)
            if newp==nil then break end

            if newp==ep then
              local hasClassIndex=false
              for k=2,20 do
                local index=readInteger(ep+k*4)
                if index==ClassNameIndex then
                  hasClassIndex=true
                  if nameoffsetcount[k*4] then
                    nameoffsetcount[k*4]=nameoffsetcount[k*4]+1
                  else
                    nameoffsetcount[k*4]=1
                  end
                end
              end

              if hasClassIndex then
                if classPointerOffsetCount[j*8] then
                  classPointerOffsetCount[j*8]=classPointerOffsetCount[j*8]+1
                else
                  classPointerOffsetCount[j*8]=1
                end
              end

              break
            end
            ep=newp
            depth=depth+1
          end
        end
      end

      local highestcount=0
      local bestoffset=nil

      for offset,count in pairs(classPointerOffsetCount) do
        if count>highestcount then
          bestoffset=offset
          highestcount=count
        end
      end

      UEngine.UObject={}
      UEngine.UObject.Class=bestoffset

      highestcount=0
      bestoffset=nil

      for offset,count in pairs(nameoffsetcount) do
        if count>highestcount then
          bestoffset=offset
          highestcount=count
        end
      end

      UEngine.UObject.Name=bestoffset
    end

    return true
  else
    return false, 'FindObjectArray needs more filtering'
  end
end

function SetupNamePoolLookupType()
  if getCustomType('UE FName to String')==nil then
    local function customvaluetype2_bytestovalue(b1,b2,b3,b4,b5,b6,b7,b8,address)
      local v1
      v1=(b4 << 24) + (b3<<16) + (b2 << 8) + b1
      v2=(b8 << 24) + (b7<<16) + (b6 << 8) + b5
      if UEngine and UEngine.IndexToName then
        local n=UEngine.IndexToName[v1]
        if n==nil then
          n='<noname>'
        end

        if v2>0 then
          return string.format("%s_%d",n,v2)
        else
          return n
        end
      else
        return 'noindex'
      end
    end

    local function customvaluetype2_valuetobytes(i,address)
    end

    synchronize(function()
      registerCustomTypeLua('UE FName to String',8,customvaluetype2_bytestovalue, customvaluetype2_valuetobytes, false,true )
    end)
  end
end

function CacheNamePool_old()
  log('CacheNamePool_old')
  if UEngine.NamePoolData==nil then return nil,'UEngine.NamePoolData not defined yet' end

  local N2I={}
  local I2N={}

  local sdata=createMemoryStream()
  sdata.Size=0x20000

  local count=1000

  local pointerlist=createMemoryStream()
  pointerlist.Size=8*count
  if copyMemory(UEngine.NamePoolData,pointerlist.Size, pointerlist.Memory,1)==nil then return nil,'Read Failed' end

  local stringCache={}
  local StringOffset=UEngine.FNameEntry.String

  for i=1,count do
    local p=pointerlist.readQword()
    if p==0 then break end

    sdata.Position=0
    if copyMemory(p,sdata.Size, sdata.Memory,1) then
      for j=0,16383 do
        local p2=sdata.readQword()

        if p2==nil then break end
        if p2~=0 then
          local Base=p2&0xFFFFFFFFFFFF0000
          local cache=stringCache[Base]

          if cache==nil then
            cache=createMemoryStream()

            local meminfo=getMemoryRegionInfo(Base)
            if meminfo and meminfo.State==4096 then
              while meminfo.RegionSize<0x10000+0x100 do
                local n=getMemoryRegionInfo(meminfo.BaseAddress+meminfo.RegionSize)
                if n and n.State==4096 then
                  meminfo.RegionSize=meminfo.RegionSize+n.RegionSize
                else
                  break
                end
              end

              if meminfo.RegionSize>0x10000+0x100 then
                meminfo.RegionSize=0x10000+0x100
              end

              cache.Size=meminfo.RegionSize

              if copyMemory(Base,meminfo.RegionSize, cache.Memory,1)==nil then
                cache.Size=0
              end
            end

            stringCache[Base]=cache
          end

          local pindex=p2-Base+StringOffset
          local sizeleft=cache.Size-pindex
          local str
          if sizeleft>0 then
            cache.position=pindex
            str=streamReadString(cache, math.min(100,sizeleft))
          end

          if str then
            local index=(i-1)*16384+j

            N2I[str]=index
            I2N[index]=str
          end
        end
      end
    end

    for base,ms in pairs(stringCache) do
      if ms then
        ms.destroy()
      end
    end

    stringCache={}
  end

  pointerlist.destroy()
  sdata.destroy()

  UEngine.NameToIndex=N2I
  UEngine.IndexToName=I2N

  return true
end

function CacheNamePool(t)
  log('CacheNamePool')

  if UEngine.NamePoolData==nil then
    return false, 'CacheNamePool: UEngine.NamePoolData is still undefined'
  end

  if UEngine.NamePoolData_old then
    return CacheNamePool_old(t)
  end

  local N2I={}
  local I2N={}

  local sdata=createMemoryStream()
  sdata.Size=0x20000

  local count=readInteger(UEngine.NamePoolData+8)
  if count==0 then count=1000 end

  local pointerlist=createMemoryStream()
  pointerlist.Size=8*count
  if copyMemory(UEngine.NamePoolData+0x10,pointerlist.Size, pointerlist.Memory,1)==nil then return nil,'Read Failed' end

  for i=1,count do
    if t and t.Terminated then
      sdata.destroy()
      pointerlist.destroy()
      return false, 'UEInfoScannerThread terminated'
    end

    local p=pointerlist.readQword()
    if p==0 then break end

    sdata.Position=0
    if copyMemory(p,sdata.Size, sdata.Memory,1) then
      while sdata.Position<sdata.Size do
        local entrystart=sdata.Position >> 1

        local header=sdata.readWord()
        local iswide=header & 1==1
        local len=header >> 6

        if len==0 then break end

        local str
        if iswide then
          str=streamReadWideString(sdata, len)
        else
          str=streamReadString(sdata, len)
        end

        local index=((i-1) << 16)+entrystart

        N2I[str]=index
        I2N[index]=str

        if (sdata.Position & 1) == 1 then sdata.readByte() end
      end
    else
      print("Failure reading strings")
    end
  end

  pointerlist.destroy()
  sdata.destroy()

  UEngine.NameToIndex=N2I
  UEngine.IndexToName=I2N

  return true
end

function FindNamePoolData_older(t)
  if UEngine.NamePoolData then return true end
  UEngine.NamePoolData_old=true

  local ms=createMemScan()
  ms.VarType=vtGrouped
  ms.Scanvalue=[[BA:4096 BS:128 OOO:U 1:* s:'None' s:'ByteProperty']]
  ms.scan()
  ms.waitTillDone()

  local fl=createFoundList(ms)
  fl.initialize()
  local firststringblock={}
  for i=0,fl.Count-1 do
    table.insert(firststringblock, getAddress(fl.Address[i]))
  end
  fl.deinitialize()
  fl.destroy()
  ms.destroy()

  if t and t.Terminated then
    return false,'UEInfoScannerThread terminated'
  end

  if #firststringblock==0 then
    return false,'No known stringpool found'
  end

  if #firststringblock>1 then
    local new={}
    for i=1,#firststringblock do
      local mri=getMemoryRegionInfo(firststringblock[i])
      if mri and mri.RegionSize==0x10000 then
        table.insert(new,firststringblock[i])
      end
    end
    firststringblock=new

    if #firststringblock==0 then
      return false,'No known stringpool found (2)'
    end

    if #firststringblock>1 then
      return false,'FindNamePoolData_older needs more refining'
    end
  end

  UEngine.FNameEntry={}

  local a=firststringblock[1]
  for i=0,128 do
    if readString(a+i,4)=='None' then
      UEngine.FNameEntry.String=i
      break
    end
  end

  ms=createMemScan()
  ms.VarType=vtQword
  ms.ScanValue=a
  ms.FastScanMethod=fsmLastDigits
  ms.FastScanparameter='0000'
  ms.scan()
  ms.waitTillDone()

  local fl2=createFoundList(ms)
  fl2.initialize()
  local r={}
  for i=0,fl2.Count-1 do
    table.insert(r,getAddress(fl2.Address[i]))
  end
  fl2.deinitialize()
  fl2.destroy()
  ms.destroy()

  if t and t.Terminated then
    return false,'UEInfoScannerThread terminated'
  end

  if #r==0 then return nil,'no list found' end
  if #r>1 then return nil,'needs more refining' end

  ms=createMemScan()
  ms.VarType=vtQword
  ms.ScanValue=r[1]
  ms.FastScanMethod=fsmAligned
  ms.FastScanparameter='8'
  ms.scan()
  ms.waitTillDone()

  local fl3=createFoundList(ms)
  fl3.initialize()
  local r2={}
  for i=0,fl3.Count-1 do
    table.insert(r2,getAddress(fl3.Address[i]))
  end
  fl3.deinitialize()
  fl3.destroy()
  ms.destroy()

  if #r2==0 then
    return nil,'No list found'
  end

  if #r2>1 then
    return nil,'todo: check other pointers for valid stringblocks'
  end

  UEngine.NamePoolData=r2[1]
  return true
end

function FindNamePoolData(t)
  if UEngine.NamePoolData then return true end

  local ms=createMemScan()
  ms.VarType=vtByteArray
  ms.Hexadecimal=true
  ms.Scanvalue='* 01 4e 6f 6e 65 * 03 42 79 74'
  ms.Fastscanmethod=fsmAligned
  ms.Fastscanparameter=10000
  ms.scan()

  if t and t.Terminated then
    ms.terminateScan()
    return false,'UEInfoScannerThread terminated'
  end
  ms.waitTillDone()

  local fl=createFoundList(ms)
  fl.initialize()
  local firststringblock={}
  for i=0,fl.Count-1 do
    table.insert(firststringblock, getAddress(fl.Address[i]))
  end
  fl.deinitialize()
  fl.destroy()
  ms.destroy() ms=nil

  if t and t.Terminated then
    return false,'UEInfoScannerThread terminated'
  end

  if #firststringblock==0 then
    local r,err=FindNamePoolData_older(t)
    return r,err
  end

  local mscans={}
  for i=1,#firststringblock do
    mscans[i]=createMemScan()
    mscans[i].VarType=vtQword
    mscans[i].Fastscanmethod=fsmAligned
    mscans[i].Fastscanparameter=8
    mscans[i].Scanvalue=firststringblock[i]
    mscans[i].Startaddress=getAddress(process)
    mscans[i].Stopaddress=getAddress(process)+getModuleSize(process)
    mscans[i].scan()
  end

  local r={}
  for i=1,#firststringblock do
    mscans[i].waitTillDone()
    local fl2=createFoundList(mscans[i])
    fl2.initialize()
    for j=0,fl2.Count-1 do
      table.insert(r,getAddress(fl2.Address[j]))
    end
    fl2.deinitialize()
    fl2.destroy()
    mscans[i].destroy() mscans[i]=nil
  end

  if t and t.Terminated then
    return false,'UEInfoScannerThread terminated'
  end

  if #r>1 then
    local r2={}
    for i=1,#r do
      local valid=true
      for j=1,3 do
        local a=readPointer(r[i]+j*8)
        if a~=0 then
          local mri=getMemoryRegionInfo(a)
          if (mri==nil) or (mri.RegionSize~=0x20000) then
            valid=false
            break
          end
        end
      end
      if valid then
        table.insert(r2,r[i])
      end
    end

    r=r2

    if #r>1 then
      return false,'too many found. Needs more refining'
    end
  end

  if #r==0 then
    return false,'not found'
  end

  if #r==1 then
    UEngine.NamePoolData = r[1] - 0x10
    return true
  end
end

-- Menu items created with createMenuItem(MainForm) are OWNED by MainForm.
-- Assigning fixed .Name and recreating on reload → LCL:
--   "A component named miStructureDissectCallbackStatus already exists" → GUI crash.
-- Never set .Name on these; destroy leftovers by known names before rebuild.
local UE_MENU_COMPONENT_NAMES={
  'miUnrealEngine','miStatus','miHurry','miStructureDissectCallbackStatus',
  'miSep1','miSepDebug','miDebug','miFindInventory','miAddPlayerProps','miAddInventory',
  'miInvLive','miInvRealNames','miInvChecklist',
}

local function UE_destroyMenuComponentByName(name)
  if not name or not MainForm then return end
  pcall(function()
    local c=nil
    if MainForm.findComponentByName then
      c=MainForm.findComponentByName(name)
    end
    if (not c) and MainForm[name]~=nil then c=MainForm[name] end
    if c and type(c.destroy)=='function' then c.destroy() end
  end)
end

local function UE_destroyAllUEMenuComponents()
  -- Destroy submenu items first, then root
  for i=#UE_MENU_COMPONENT_NAMES,1,-1 do
    UE_destroyMenuComponentByName(UE_MENU_COMPONENT_NAMES[i])
  end
  if UEngine and UEngine.GUI then
    pcall(function()
      if UEngine.GUI.miUnrealEngine and UEngine.GUI.miUnrealEngine.destroy then
        UEngine.GUI.miUnrealEngine.destroy()
      end
    end)
    UEngine.GUI={}
  end
end

function UE_newMenuItem(caption)
  local mi=createMenuItem(MainForm)
  -- Leave Name empty / unique — fixed names crash CE on second LaunchUEInfoScanner
  pcall(function() mi.Name='' end)
  if caption then mi.Caption=caption end
  return mi
end

-- Safe status line (scanner thread may outlive a reload that nils GUI)
local function UE_setStatusCaption(caption)
  pcall(function()
    if not UEngine then return end
    if not UEngine.GUI then UEngine.GUI={} end
    if UEngine.GUI.miStatus then
      UEngine.GUI.miStatus.Caption=tostring(caption or '')
    end
  end)
end

function createUEMenu()
  log('Creating menuitem')

  local function build()
    if not UEngine then UEngine={} end
    pcall(UE_destroyAllUEMenuComponents)
    UEngine.GUI=UEngine.GUI or {}

    local ok, err=pcall(function()
      UEngine.GUI.miUnrealEngine=UE_newMenuItem('Initializing Unreal Engine')

      UEngine.GUI.miStatus=UE_newMenuItem('Status')
      UEngine.GUI.miStatus.OnClick=function()
        if UEInfoScannerThread and (messageDialog('Cancel the Unreal Engine data collection?',mtConfirmation,mbYes, mbNo)==mrYes) then
          UEInfoScannerThread.Terminate()
        end
      end
      UEngine.GUI.miUnrealEngine.add(UEngine.GUI.miStatus)

      UEngine.GUI.miHurry=UE_newMenuItem('Prioritize this')
      UEngine.GUI.miHurry.OnClick=function()
        if UEInfoScannerThread then
          UEInfoScannerThread.Priority='tpHigher'
        end
        pcall(function()
          if UEngine.GUI and UEngine.GUI.miHurry then UEngine.GUI.miHurry.destroy() end
        end)
        if UEngine.GUI then UEngine.GUI.miHurry=nil end
      end
      UEngine.GUI.miUnrealEngine.add(UEngine.GUI.miHurry)

      if MainForm and MainForm.Menu and MainForm.miHelp then
        MainForm.Menu.Items.insert(MainForm.miHelp.MenuIndex, UEngine.GUI.miUnrealEngine)
      end
      UEngine.GUI.menusBuilt=false
    end)
    if not ok then
      log('createUEMenu build failed: '..tostring(err))
      UEngine.GUI=UEngine.GUI or {}
    end
  end

  if synchronize then
    synchronize(build)
  else
    build()
  end
end

-- True when GEngine + property offsets are usable for inventory/player menus
function UEngine_isReady()
  if not UEngine or not UEngine.UGameEngine or UEngine.UGameEngine==0 then return false end
  if not UEngine.UObject or not UEngine.UObject.Class or not UEngine.UObject.Name then return false end
  if not UEngine.FProperty or not UEngine.FProperty.Offset then return false end
  -- stale after process switch
  if UEngine.processid and getOpenedProcessID and UEngine.processid~=getOpenedProcessID() then
    return false
  end
  return true
end

function UEngine_isScannerRunning()
  local t=rawget(_G,'UEInfoScannerThread')
  if not t then return false end
  local alive=true
  pcall(function()
    if t.Finished then alive=not t.Finished end
  end)
  return alive
end

-- Run fn() on main thread when ready. If not ready, start LaunchUEInfoScanner and queue fn.
-- silent=true: no showMessage (for live track toggle etc.)
function UEngine_runWhenReady(fn, opts)
  opts=opts or {}
  if type(fn)~='function' then return false end

  if UEngine_isReady() then
    local ok,err=pcall(fn)
    if not ok then log('UEngine_runWhenReady action error: '..tostring(err)) end
    return true
  end

  UEngine=UEngine or {}
  UEngine._pendingReady=UEngine._pendingReady or {}
  UEngine._pendingReady[#UEngine._pendingReady+1]=fn

  if not UEngine_isScannerRunning() then
    log('UEngine_runWhenReady: GEngine not ready — starting LaunchUEInfoScanner')
    pcall(function()
      if UEngine.GUI and UEngine.GUI.miUnrealEngine then
        UEngine.GUI.miUnrealEngine.Caption='Initializing Unreal Engine…'
      end
    end)
    pcall(LaunchUEInfoScanner)
    if not opts.silent and showMessage then
      pcall(showMessage,
        'Unreal Engine data not ready yet.\n\nInitialization started automatically.\nYour action will run when it finishes.\n\n(If the menu still says Initializing, wait a bit.)')
    end
  else
    log('UEngine_runWhenReady: scanner already running — action queued')
    if not opts.silent and showMessage then
      pcall(showMessage, 'Unreal Engine is still initializing.\nYour action will run when it finishes.')
    end
  end

  -- Safety poll: flush queue if ready even if success path missed it
  if not UEngine._readyPollTimer then
    local t=createTimer(MainForm)
    t.Interval=500
    t.OnTimer=function(timer)
      if UEngine_isReady() then
        pcall(UEngine_flushPendingReady, true)
        pcall(function() timer.destroy() end)
        UEngine._readyPollTimer=nil
      elseif not UEngine_isScannerRunning() and not UEngine_isReady() then
        -- scanner died without success — drop queue after notifying once
        local n=UEngine._pendingReady and #UEngine._pendingReady or 0
        UEngine._pendingReady={}
        pcall(function() timer.destroy() end)
        UEngine._readyPollTimer=nil
        if n>0 then
          log('UEngine_runWhenReady: scanner ended without ready state; dropped '..n..' queued action(s)')
        end
      end
    end
    t.Enabled=true
    UEngine._readyPollTimer=t
  end
  return false
end

function UEngine_flushPendingReady(success)
  if not UEngine or not UEngine._pendingReady then return end
  local q=UEngine._pendingReady
  UEngine._pendingReady={}
  if not success or not UEngine_isReady() then return end
  log(string.format('UEngine_flushPendingReady: running %d queued action(s)', #q))
  for _,fn in ipairs(q) do
    pcall(fn)
  end
end

function UEngine_buildSuccessMenus()
  -- Idempotent: safe if Launch/scanner success runs more than once
  if not UEngine or not UEngine.GUI or not UEngine.GUI.miUnrealEngine then return end
  if UEngine.GUI.menusBuilt then
    log('UEngine_buildSuccessMenus: already built, skip')
    return
  end

  -- Drop any stale named leftovers from older script versions
  for _,n in ipairs({
    'miStructureDissectCallbackStatus','miSep1','miDebug','miFindInventory',
    'miAddPlayerProps','miAddInventory','miInvLive','miInvRealNames','miInvChecklist',
  }) do
    UE_destroyMenuComponentByName(n)
  end

  UEngine.GUI.miStructureDissectCallbackStatus=UE_newMenuItem('Use when dissecting structures')
  UEngine.GUI.miStructureDissectCallbackStatus.AutoCheck=true
  UEngine.GUI.miStructureDissectCallbackStatus.Checked=true
  UEngine.GUI.miUnrealEngine.add(UEngine.GUI.miStructureDissectCallbackStatus)

  UEngine.GUI.miSep1=UE_newMenuItem('-')
  UEngine.GUI.miUnrealEngine.add(UEngine.GUI.miSep1)

  UEngine.GUI.miAddPlayerProps=UE_newMenuItem('Add / Refresh Player (auto on load)')
  UEngine.GUI.miAddPlayerProps.OnClick=function()
    UEngine_runWhenReady(function() UEngine_addPlayerToAddressList() end)
  end
  UEngine.GUI.miUnrealEngine.add(UEngine.GUI.miAddPlayerProps)

  -- Plugin loader menu
  UEngine.GUI.miSepPlugin=UE_newMenuItem('-')
  UEngine.GUI.miUnrealEngine.add(UEngine.GUI.miSepPlugin)

  UEngine.GUI.miPluginRoot=UE_newMenuItem('Load Game Plugin ▸')
  UEngine.GUI.miUnrealEngine.add(UEngine.GUI.miPluginRoot)

  -- Scan for plugins and populate menu
  local plugins=UEngine_scanPlugins()
  if plugins and #plugins>0 then
    for _,entry in ipairs(plugins) do
      local mi=UE_newMenuItem(entry.name or entry.folder)
      mi.OnClick=function()
        UEngine_loadPlugin(entry)
      end
      UEngine.GUI.miPluginRoot.add(mi)
    end
  end

  UEngine.GUI.miStructureDissectCallbackStatus.OnClick=function()
    UEngine_runWhenReady(function()
      if UEngine.GUI and UEngine.GUI.miStructureDissectCallbackStatus
        and UEngine.GUI.miStructureDissectCallbackStatus.Checked then
        registerUEngineStructureLookupCallbacks()
      else
        unregisterUEngineStructureLookupCallbacks()
      end
    end, {silent=true})
  end

  UEngine.GUI.miSepDebug=UE_newMenuItem('-')
  UEngine.GUI.miUnrealEngine.add(UEngine.GUI.miSepDebug)

  UEngine.GUI.miDebug=UE_newMenuItem('Debug')
  UEngine.GUI.miUnrealEngine.add(UEngine.GUI.miDebug)

  UEngine.GUI.miSearchCharProps=UE_newMenuItem('Search Character for Inventory Props')
  UEngine.GUI.miSearchCharProps.OnClick=function()
    UEngine_runWhenReady(function()
      createThread(function() UEngine_searchCharacterProperties() end)
    end)
  end
  UEngine.GUI.miDebug.add(UEngine.GUI.miSearchCharProps)

  if UEngine.GUI.miStatus then
    pcall(function() UEngine.GUI.miStatus.destroy() end)
    UEngine.GUI.miStatus=nil
  end
  if UEngine.GUI.miHurry then
    pcall(function() UEngine.GUI.miHurry.destroy() end)
    UEngine.GUI.miHurry=nil
  end

  UEngine.GUI.menusBuilt=true
end

function UEInfoScanner(t)
  log('UEInfoScanner start');

  if process==nil then return false,'No process selected' end

  local versionid
  local fs=nil
  local r,r2=pcall(function()
    fs=createFileStream(enumModules()[1].PathToFile, fmOpenRead or fmShareDenyNone)
    local b=fs.read(1024)
    fs.destroy() fs=nil

    local s=byteTableToString(b)
    versionid=stringToMD5String(s)
  end)

  if fs then
    fs.destroy()
    fs=nil
  end

  if versionid==nil then
    versionid=md5memory(getAddressSafe(process),4096)
  end

  if versionid==nil then
    log('file and main module unreadable')
    return false
  end

  local id=process..'-'..versionid

  local s=getSettings("UEInfo\\"..id,true)
  local r

  if t then
    log('Threaded')
    t.FreeOnTerminate(false)
    t.Name='UEInfoScannerThread'
  end

  if UEngine==nil or UEngine.processid~=getOpenedProcessID() then
    if UEngineStructDissect then
      if unregisterStructureDissectOverride2 then
        unregisterStructureDissectOverride2(UEngineStructDissect)
      end
      UEngineStructDissect=nil
    end

    synchronize(function()
      pcall(UE_destroyAllUEMenuComponents)
    end)
    UEngine={}
    UEngine.processid=getOpenedProcessID()
  end

  if false and (s.fullyParsed) then
    log('The state was fully parsed. Using this')
    local list=s.getValueList()
    for name,value in pairs(list) do
      if name:startsWith('UEngine.') then
        local sections=table.pack(name:split('.'))

        local t=UEngine
        for i=2,#sections-1 do
          local newt=t[sections[i]]
          if newt==nil then
            t[sections[i]]={}
            newt=t[sections[i]]
          end
          t=newt
        end

        t[sections[#sections]]=tonumber(value)
      end
    end

    createUEMenu()

    UEngine.NamePoolData=getAddressSafe(s.NamePoolData)
    UEngine.ObjectArray=getAddressSafe(s.ObjectArray)
    UEngine.GEngine=getAddressSafe(s.GEngine)

    if UEngine.GEngine then
      local n=getNameFromAddress(UEngine.GEngine,true,false,false)
      if n:find(extractFileNameWithoutExt(process),nil,true) then
        registerSymbol('GEngine',n, true)
      end
    end

    log('Loading string table')
    synchronize(function() UE_setStatusCaption('Loading string table') end)

    if UEngine.NamePoolData==nil then
      local r,err=FindNamePoolData(t)
      if not r then
        log('Failed searching for NamePool:'..err)
        return nil,'FindNamePoolData failed:'..err
      end
    end

    local originalDebugState
    if disableLuaDebug then originalDebugState=disableLuaDebug() end
    local err
    r,err=CacheNamePool(t)
    if originalDebugState and restoreLuaDebug then restoreLuaDebug(originalDebugState) end

    if not r then
      return nil,'CacheNamePool failed:'..err
    end

    SetupNamePoolLookupType()

    r=true
  else
    log('New or incomplete state')
    if UEngine.NamePoolData==nil then
      local sNamePoolData=s.NamePoolData
      if sNamePoolData then
        UEngine.NamePoolData=getAddressSafe(sNamePoolData)
        log('NamePoolData was previously at '..sNamePoolData..' . Using that')
      end
    end

    if UEngine.NamePoolData==nil then
      log('Searching for NamePool')
      local r,err=FindNamePoolData(t)
      if not r then
        log('Failed searching for NamePool:'..err)
        return nil,'FindNamePoolData failed:'..err
      end

      local n=getNameFromAddress(UEngine.NamePoolData,true,false,false)
      if n:find(extractFileNameWithoutExt(process),nil,true) then
        s.NamePoolData=getNameFromAddress(UEngine.NamePoolData)
      end
    end

    if t and t.Terminated then return nil,'UEInfoScanner terminated' end

    createUEMenu()

    if UEngine.NameToIndex == nil then
      log('Loading string table')
      synchronize(function() UE_setStatusCaption('Loading string table') end)

      local originalDebugState
      if disableLuaDebug then originalDebugState=disableLuaDebug() end
      local r,err=CacheNamePool(t)
      if originalDebugState and restoreLuaDebug then restoreLuaDebug(originalDebugState) end

      if not r then
        return nil,'CacheNamePool failed:'..err
      end

      SetupNamePoolLookupType()
    end

    if t and t.Terminated then return nil,'UEInfoScanner terminated' end

    if UEngine.ObjectArray==nil then
      local sObjectArray=s.ObjectArray
      if sObjectArray then
        UEngine.ObjectArray=getAddressSafe(sObjectArray)
      end
    end

    if (UEngine.ObjectArray == nil) or (UEngine.UObject==nil) then
      log('Scanning for object table')
      synchronize(function() UE_setStatusCaption('Scanning for object table') end)

      local r,err=FindObjectArray(t)
      if not r then
        if err then
          return nil,'FindObjectArray failed:'..err
        else
          return nil,'FindObjectArray failed. No error given'
        end
      end
      s.ObjectArray=getNameFromAddress(UEngine.ObjectArray, true, false,false)
    end

    if UEngine.UGameEngine==nil then
      log('Searching for GEngine')
      synchronize(function() UE_setStatusCaption('Searching for GEngine') end)

      local r,err=FindGEngine(t)
      log('FindGEngine returned')
      if not r then
        if err then
          log('FindGEngine failed:'..err)
        else
          log('FindGEngine failed')
        end
        return nil,'FindGEngine failed:'..err
      end

      if UEngine.GEngine and UEngine.GEngine~=0 then
        s.GEngine=getNameFromAddress(UEngine.GEngine,true,false,false)
      end
    end

    log('Figuring out the "class" offset')
    if UEngine.UObject.Class~=nil then
      log('UObject.Class already set to '..tostring(UEngine.UObject.Class)..' from FindObjectArray, verifying...')
      UEngine.GameEngineClass=readPointer(UEngine.UGameEngine+UEngine.UObject.Class)
      local verifyName=UObject_getName(UEngine.GameEngineClass)
      log('UObject.Class verification: GameEngineClass name='..tostring(verifyName))
      if verifyName~='GameEngine' then
        log('UObject.Class offset '..UEngine.UObject.Class..' gives name "'..tostring(verifyName)..'", clearing and re-scanning')
        UEngine.UObject.Class=nil
      end
    end

    if UEngine.UObject.Class==nil then
      log('Scanning UGameEngine instance for Class offset')
      for i=1,32 do
        local ptr=readPointer(UEngine.UGameEngine+i*4)
        if ptr and ptr~=0 then
          local n=UObject_getName(ptr)
          if n then
            log('  offset '..(i*4)..': name='..n)
          end
          if n and n=='GameEngine' then
            UEngine.UObject.Class=i*4
            log('  -> FOUND Class offset='..i*4)
            break
          end
        end
      end
    end

    if UEngine.UObject.Class==nil then
      log('Failed finding the "class" offset')
      return nil,'UObject.Class not found'
    end

    UEngine.GameEngineClass=readPointer(UEngine.UGameEngine+UEngine.UObject.Class)
    log('GameEngineClass='..string.format('0x%X',UEngine.GameEngineClass)..' name='..tostring(UObject_getName(UEngine.GameEngineClass)))

    UEngine.UStruct={}
    UEngine.UStruct.Name=UEngine.UObject.Name
    UEngine.UStruct.Class=UEngine.UObject.Class

    if UEngine.UClass==nil then
      UEngine.UClass={}
      UEngine.UClass.Name=UEngine.UObject.Name
      UEngine.UClass.Class=UEngine.UObject.Class
    end

    if UEngine.UClass.SuperStruct then
      log('SuperStruct: using cached offset='..tostring(UEngine.UClass.SuperStruct))
      UEngine.UStruct.SuperStruct=UEngine.UClass.SuperStruct
    else
      log('SuperStruct: GameEngineClass='..string.format('0x%X',UEngine.GameEngineClass)..' UObject.Class='..tostring(UEngine.UObject.Class))
      local gcName=UObject_getName(UEngine.GameEngineClass)
      log('SuperStruct: GameEngineClass name='..tostring(gcName)..' vftable='..string.format('0x%X',readPointer(UEngine.GameEngineClass) or 0))

      if gcName=='GameEngine' then
        log('SuperStruct: branch 1 - scanning offsets for parent named Engine')
        for i=0,32 do
          local ptr=readPointer(UEngine.GameEngineClass+i*8)
          local n=UObject_getName(ptr)
          if ptr and ptr~=0 then
            log('SuperStruct:   offset '..(i*8)..': ptr='..string.format('0x%X',ptr)..' name='..tostring(n))
          end
          if n and n=='Engine' then
            UEngine.UStruct.SuperStruct=i*8
            break
          end
        end

        if UEngine.UStruct.SuperStruct==nil then
          log('SuperStruct: branch 1 fallback - no "Engine" parent, trying testIfSuperStructOffset')
        end
      end

      if UEngine.UStruct.SuperStruct==nil then
        log('SuperStruct: branch 2 - testIfSuperStructOffset for i=1..32')
        local bestOffset=nil
        local bestChainLen=0
        local bestChain=nil
        for i=1,32 do
          local r=testIfSuperStructOffset(UEngine.GameEngineClass, i*8)

          if r then
            log('SuperStruct:   offset '..(i*8)..': chain='..table.concat(r,',')..' len='..#r)
          end

          if r and #r>1 then
            for j=1,#r do
              if r[j]=='Engine' then
                UEngine.UStruct.SuperStruct=i*8
                break
              end
            end

            if UEngine.UStruct.SuperStruct then
              break
            end

            if #r>bestChainLen then
              bestOffset=i*8
              bestChainLen=#r
              bestChain=r
            end
          end
        end

        if UEngine.UStruct.SuperStruct==nil and bestOffset then
          log('SuperStruct: no chain with "Engine", using longest valid chain: offset='..bestOffset..' chain='..table.concat(bestChain,','))
          UEngine.UStruct.SuperStruct=bestOffset
        end
      end
    end

    if UEngine.UStruct.SuperStruct==nil then
      log('SuperStruct: FAILED - no valid offset found')
      return nil,'Failed finding the SuperStruct field'
    end
    log('SuperStruct: found at offset='..tostring(UEngine.UStruct.SuperStruct))

    UEngine.UClass.Name=UEngine.UStruct.Name
    UEngine.UClass.Class=UEngine.UStruct.Class
    UEngine.UClass.SuperStruct=UEngine.UStruct.SuperStruct

    UEngine.RealGameEngineClass=UEngine.GameEngineClass

    local c=UEngine.GameEngineClass
    local cname=UObject_getName(c)
    log('SuperStruct walk: starting at '..string.format('0x%X',c)..' name='..tostring(cname))
    local walkDepth=0
    while cname~='GameEngine' do
      local nextC=readPointer(c+UEngine.UClass.SuperStruct)
      if nextC==nil or nextC==0 then
        log('SuperStruct walk: chain ended at depth '..walkDepth..' without finding "GameEngine". Last name='..tostring(cname))
        break
      end
      c=nextC
      cname=UObject_getName(c)
      walkDepth=walkDepth+1
      log('SuperStruct walk: depth '..walkDepth..' -> '..string.format('0x%X',c)..' name='..tostring(cname))
      if walkDepth>20 then
        log('SuperStruct walk: exceeded depth limit')
        break
      end
    end
    if cname=='GameEngine' then
      UEngine.GameEngineClass=c
      log('SuperStruct walk: found base GameEngineClass at '..string.format('0x%X',c))
    else
      log('SuperStruct walk: using original GameEngineClass (name='..tostring(cname)..')')
    end

    if t and t.Terminated then
      return nil,'UEInfoScannerThread terminated'
    end

    log('Figuring out the other offsets (findGameInstanceFPropertyAndFields) ')
    synchronize(function() UE_setStatusCaption('Figuring out offsets') end)

    r,err=findGameInstanceFPropertyAndFields(t)
    if err then log('findGameInstanceFPropertyAndFields returned error: '..err) end
  end

  if r then
    if s.fullyParsed==nil then
      function saveLuaTable(tablename,t)
        if t then
          for name,value in pairs(t) do
            local n=tablename..'.'..name

            if type(value)=='table' then
              saveLuaTable(n,value)
            else
              s[n]=tostring(value)
            end
          end
        end
      end

      saveLuaTable('UEngine.FNameEntry', UEngine.FNameEntry)
      saveLuaTable('UEngine.UObject', UEngine.UObject)
      saveLuaTable('UEngine.UStruct', UEngine.UStruct)
      saveLuaTable('UEngine.UClass', UEngine.UClass)
      saveLuaTable('UEngine.FProperty', UEngine.FProperty)
      saveLuaTable('UEngine.FFieldClass', UEngine.FFieldClass)
      saveLuaTable('UEngine.FField', UEngine.FField)

      s['UEngine.VFTableInExecutableMemoryMethod']=UEngine.VFTableInExecutableMemoryMethod
      s['UEngine.ObjectArrayListType']=UEngine.ObjectArrayListType
      s['UEngine.ObjectArrayEntryStructSize']=UEngine.ObjectArrayEntryStructSize
      s['UEngine.NamePoolData_old']=UEngine.NamePoolData_old

      s.fullyParsed=true
    end

    log('success. Registering structure lookup callback + menus')
    synchronize(function()
      pcall(function()
        if registerUEngineStructureLookupCallbacks then
          registerUEngineStructureLookupCallbacks()
        end
      end)
      pcall(UEngine_buildSuccessMenus)
      pcall(function()
        if UEngine.GUI and UEngine.GUI.miUnrealEngine then
          UEngine.GUI.miUnrealEngine.Caption='Unreal Engine'
        end
      end)
      pcall(UEngine_flushPendingReady, true)
    end)

    return r, err
  end
end

function couldBeUnrealEngine()
  local pname=extractFileNameWithoutExt(process)
  if pname==nil then return false end

  if getAddressSafe(pname..'.agsInit') then return true end
  if getAddressSafe(pname..'.agsInitialize') then return true end

  if pname:lower():endsWith('shipping') then return true end

  local r=enumModules()
  if r and #r>0 then
    local v,res=getFileVersion(r[1].PathToFile)
    if res then
      if res.ProductVersion and res.ProductVersion:find('%%+UE4') then return true end
      if res.ProductVersion and res.ProductVersion:find('%%+UE5') then return true end

      if res.OriginalFilename then
        local ofn=extractFileNameWithoutExt(res.OriginalFilename)
        if ofn:lower():endsWith('shipping') then return true end
      end
    end
  end

  return false
end

function WaitForUnrealEngineInfo(timeout)
  if UEInfoScannerThread then
    UEInfoScannerThread.Priority='tpHigher'
  end
  return true
end

-- CE 7.5 CRITICAL: getStructure(i) is INDEX-ONLY (DissectedStructs[i]).
-- getStructure('GameEngine') coerces string→0 and returns/destroys index 0 forever.
-- Always find structures by scanning Name. See CE75-DISSECT-CRASH.md.
UEngine.DISSECT_PLACEHOLDER_NAME = UEngine.DISSECT_PLACEHOLDER_NAME or 'DO_NOT_DELETE_PLACEHOLDER'

function UEngine_findStructureByName(name)
  if not name or not getStructureCount then return nil, nil end
  local n=getStructureCount()
  if not n or n<1 then return nil, nil end
  for i=0,n-1 do
    local ok,s=pcall(getStructure, i)
    if ok and s then
      local sn=nil
      pcall(function() sn=s.Name end)
      if sn==name then return s, i end
    end
  end
  return nil, nil
end

function UEngine_structureListHasAny()
  local n=getStructureCount and getStructureCount() or 0
  return n and n>0
end

-- Always keep a tiny placeholder so empty TreeView never hits list index (0) crash.
-- Prefer it as the first created structure when the list is empty.
function UEngine_ensureDissectSeed()
  local pname=UEngine.DISSECT_PLACEHOLDER_NAME or 'DO_NOT_DELETE_PLACEHOLDER'
  local ok, err=pcall(function()
    local existing=UEngine_findStructureByName(pname)
    if existing then
      log('UEngine_ensureDissectSeed: placeholder present')
      return
    end
    -- Also accept legacy names from older scripts
    if UEngine_findStructureByName('UE_Seed') then
      log('UEngine_ensureDissectSeed: legacy UE_Seed present')
      return
    end
    local s=createStructure(pname)
    local e=s.addElement()
    e.Name='_placeholder'
    e.Offset=0
    e.VarType=vtByte
    s.addToGlobalStructureList()
    log('UEngine_ensureDissectSeed: created '..pname)
  end)
  if not ok then
    log('UEngine_ensureDissectSeed failed: '..tostring(err))
  end
  return ok
end

-- Remove structures with exact Name. NEVER removes the dissect placeholder.
function UEngine_removeStructuresNamed(name)
  if not name or not getStructureCount then return end
  local pname=UEngine.DISSECT_PLACEHOLDER_NAME or 'DO_NOT_DELETE_PLACEHOLDER'
  if name==pname or name=='UE_Seed' then
    log('UEngine_removeStructuresNamed: refused to remove placeholder '..tostring(name))
    return
  end
  for i=(getStructureCount()-1),0,-1 do
    local ok,s=pcall(getStructure, i)
    if ok and s then
      local sn=nil
      pcall(function() sn=s.Name end)
      if sn==name then
        pcall(function() s.removeFromGlobalStructureList() end)
        pcall(function() if s.destroy then s.destroy() end end)
      end
    end
  end
end

-- Clear all elements on an existing structure (in-place update; keeps global list slot)
function UEngine_clearStructureElements(s)
  if not s then return false end
  local ok=pcall(function()
    if s.beginUpdate then s.beginUpdate() end
    -- Count shrinks as we delete; always delete index 0
    local guard=0
    while guard<10000 do
      local c=s.Count or 0
      if c<=0 then break end
      local deleted=false
      -- Prefer Element[0].destroy / structure.delete if available
      pcall(function()
        if s.delete then s.delete(0); deleted=true end
      end)
      if not deleted then
        pcall(function()
          local e=s.Element[0]
          if e and e.destroy then e.destroy(); deleted=true end
        end)
      end
      if not deleted then
        pcall(function()
          local e=s.getElement and s.getElement(0)
          if e and e.destroy then e.destroy(); deleted=true end
        end)
      end
      if not deleted then break end
      guard=guard+1
    end
    if s.endUpdate then s.endUpdate() end
  end)
  return ok
end

-- Fill existing structure object from a UObject/UClass address (no new global entry)
function UEngine_fillStructureFromClass(s, classAddr)
  if not s or not classAddr or classAddr==0 then return false end
  local properties=UClass_enumProperties(classAddr,false)
  if properties==nil then
    properties=UClass_enumProperties(classAddr,true)
  else
    UClass_enumProperties(classAddr,true,properties)
  end
  if not properties then return false end

  pcall(function() if s.beginUpdate then s.beginUpdate() end end)

  -- Base UObject fields
  local function addBase(name, off, vt, child)
    local e=s.addElement()
    e.Name=name
    e.Offset=off
    e.VarType=vt
    if child then e.ChildStruct=child end
    return e
  end
  pcall(function()
    addBase('vftable', 0, vtPointer)
    if UEngine.UObject and UEngine.UObject.Name then
      local e=addBase('Name', UEngine.UObject.Name, vtCustom)
      pcall(function() e.CustomTypeName='UE FName to String' end)
    end
    if UEngine.UObject and UEngine.UObject.Class then
      addBase('Class', UEngine.UObject.Class, vtPointer, UEngine_findStructureByName('UClass'))
    end
  end)

  for name,info in pairs(properties) do
    pcall(function()
      local e=s.addElement()
      e.Name=name
      e.Offset=info.offset
      e.VarType=vtPointer
      local ptype=info.propertyType
      if ptype=='BoolProperty' and UEngine.FProperty and UEngine.FProperty.BitMaskField then
        local bit=readByte(info.propertyAddress+UEngine.FProperty.BitMaskField+2)
        local bitnr=bitbytetobitnr and bitbytetobitnr[bit]
        local byteOff=readByte(info.propertyAddress+UEngine.FProperty.BitMaskField+1) or 0
        if bitnr then
          e.VarType=vtBinary
          e.Offset=info.offset+byteOff
          e.BitStart=bitnr
          e.BitSize=1
        else
          e.VarType=vtByte
        end
      elseif ptype=='IntProperty' or ptype=='Int32Property' or ptype=='UInt32Property' then
        e.VarType=vtDword
      elseif ptype=='Int64Property' or ptype=='UInt64Property' then
        e.VarType=vtQword
      elseif ptype=='ByteProperty' or ptype=='EnumProperty' then
        e.VarType=vtByte
      elseif ptype=='FloatProperty' then
        local ok,sz=pcall(readInteger, info.propertyAddress+UEngine.FProperty.Size)
        if ok and sz and sz==4 then e.VarType=vtSingle else e.VarType=vtDouble end
      elseif ptype=='DoubleProperty' then
        e.VarType=vtDouble
      elseif ptype=='NameProperty' then
        e.VarType=vtCustom
        pcall(function() e.CustomTypeName='UE FName to String' end)
      elseif ptype=='ClassProperty' then
        e.VarType=vtPointer
        e.ChildStruct=UEngine_findStructureByName('UClass')
      elseif ptype=='ObjectProperty' then
        e.VarType=vtPointer
      elseif ptype=='StructProperty' then
        e.VarType=vtByteArray
        local ok,sz=pcall(readInteger, info.propertyAddress+UEngine.FProperty.Size)
        if ok and sz then e.Bytesize=sz end
      elseif ptype=='StrProperty' then
        e.VarType=vtPointer
      end
    end)
  end

  pcall(function() if s.endUpdate then s.endUpdate() end end)
  return true
end

-- One GameEngine structure: update in place if present; never wipe the placeholder
function UEngine_ensureGameEngineStructure()
  if not UEngine or not UEngine.UGameEngine or UEngine.UGameEngine==0 then
    log('UEngine_ensureGameEngineStructure: no UGameEngine yet')
    return nil
  end

  -- 1) Placeholder first (must exist before any create/remove that can empty the list)
  UEngine_ensureDissectSeed()

  local geAddr=UEngine.UGameEngine
  local classAddr=nil
  if UEngine.UObject and UEngine.UObject.Class then
    classAddr=readPointer(geAddr+UEngine.UObject.Class)
  end
  if not classAddr or classAddr==0 then
    classAddr=UEngine.GameEngineClass or UEngine.RealGameEngineClass
  end

  -- 2) Prefer update existing GameEngine (do not delete list slot)
  local existing=UEngine_findStructureByName('GameEngine')
  if not existing then
    existing=UEngine_findStructureByName('UE_GameEngine')
  end

  if existing and classAddr and classAddr~=0 then
    local cleared=UEngine_clearStructureElements(existing)
    local filled=UEngine_fillStructureFromClass(existing, classAddr)
    pcall(function() existing.Name='GameEngine' end)
    if filled then
      log(string.format('UEngine_ensureGameEngineStructure: UPDATED GameEngine @ 0x%X (cleared=%s elems=%s)',
        geAddr, tostring(cleared), tostring(existing.Count)))
      _G.UE_GameEngineStruct=existing
      UEngine_ensureDissectSeed() -- re-assert placeholder still present
      return existing
    end
    log('UEngine_ensureGameEngineStructure: in-place fill failed, will recreate')
  end

  -- 3) Recreate path: remove ONLY GameEngine by correct name match (placeholder stays)
  UEngine_ensureDissectSeed()
  UEngine_removeStructuresNamed('GameEngine')
  UEngine_removeStructuresNamed('UE_GameEngine')
  UEngine_ensureDissectSeed() -- if list somehow emptied, restore placeholder before create

  local s=UEngine_createStructureFromObject(geAddr)
  if s then
    pcall(function() s.Name='GameEngine' end)
    if not UEngine_findStructureByName('GameEngine') then
      pcall(function() s.addToGlobalStructureList() end)
    end
    log(string.format('UEngine_ensureGameEngineStructure: CREATED GameEngine @ 0x%X (%s elements)',
      geAddr, tostring(s.Count)))
    _G.UE_GameEngineStruct=s
    UEngine_ensureDissectSeed()
    return s
  end
  log('UEngine_ensureGameEngineStructure: createStructureFromObject failed')
  UEngine_ensureDissectSeed()
  return nil
end

function UEngine_CE75_ReloadCleanup()
  -- Stop live inventory timer
  if UEngine and UEngine.Inv and UEngine.Inv.liveTimer then
    pcall(function() UEngine.Inv.liveTimer.destroy() end)
    UEngine.Inv.liveTimer=nil
  end
  if UEngine and UEngine.Inv then
    pcall(function()
      local r=UEngine.Inv.rootMR
      if r then
        if r.delete then r.delete() elseif r.destroy then r.destroy() end
      end
    end)
    UEngine.Inv.rootMR=nil
    if UEngine.Inv.liveTimer then
      pcall(function() UEngine.Inv.liveTimer.destroy() end)
      UEngine.Inv.liveTimer=nil
    end
  end
  if UEngine and UEngine._autoPlayerTimer then
    pcall(function() UEngine._autoPlayerTimer.destroy() end)
    UEngine._autoPlayerTimer=nil
  end
  -- Keep Player.rootMR pointer only if still valid; do not delete user's address list on reload
  if UEngine and UEngine.Player then
    if not UEngine_mrLooksAlive(UEngine.Player.rootMR) then
      UEngine.Player.rootMR=nil
    end
  end
  -- Stop scanner thread
  if UEInfoScannerThread then
    pcall(function() UEInfoScannerThread.Terminate() end)
    UEInfoScannerThread=nil
  end
  -- Unregister structure callbacks (ids from previous load)
  pcall(function()
    if type(unregisterUEngineStructureLookupCallbacks)=='function' then
      unregisterUEngineStructureLookupCallbacks()
    end
  end)
  -- Unload plugins
  pcall(UEngine_unloadPlugins)
  -- Remove menu + any MainForm-owned leftovers (fixed Names from older loads)
  pcall(UE_destroyAllUEMenuComponents)
  if UEngine then UEngine.GUI=nil end
  -- Restore original OnProcessOpened so we don't nest wrappers each dofile
  if _G.__UECE75_OrigOnProcessOpened~=nil and MainForm then
    MainForm.OnProcessOpened=_G.__UECE75_OrigOnProcessOpened
  end
  log('UEngine_CE75_ReloadCleanup done')
end
_G.UEngine_CE75_ReloadCleanup=UEngine_CE75_ReloadCleanup

function LaunchUEInfoScanner()
  if UEInfoScannerThread then
    UEInfoScannerThread.Terminate()
    UEInfoScannerThread = nil
  end
  UEInfoScannerThread = createThread(function(t)
    log('UEInfoScannerThread started')

    t.Priority='tpIdle'

    local r,err
    if debugUEInfoScanner then
      r,err=UEInfoScanner(t)
    else
      local ok,ret1,ret2=pcall(function() return UEInfoScanner(t) end)
      if ok then
        r=ret1
        err=ret2
      else
        log('UEInfoScanner ERROR: '..tostring(ret1))
        print('UEInfoScanner ERROR: '..tostring(ret1))
      end
    end

    log('UEInfoScannerThread finished')
    if r then
      log('UEInfoScanner: Success')

      if UEngine.UGameEngine then
        local ok, err=pcall(function()
          autoAssemble('define(GEngine,'..string.format('%x',UEngine.UGameEngine)..')\nregistersymbol(GEngine)')
        end)
        if ok then
          log('Registered symbol GEngine='..string.format('0x%X',UEngine.UGameEngine))
        else
          log('Failed to register GEngine symbol: '..tostring(err))
        end
      end

      synchronize(function()
        if UEngine.GUI and UEngine.GUI.miUnrealEngine then
          UEngine.GUI.miUnrealEngine.caption='Unreal Engine'
        end
        -- Auto seed so user need not manually create a blank dissect first
        UEngine_ensureDissectSeed()
        if registerUEngineStructureLookupCallbacks then
          pcall(registerUEngineStructureLookupCallbacks)
        end
        -- Single GameEngine structure (replace existing, fill from live GEngine)
        pcall(UEngine_ensureGameEngineStructure)
        pcall(UEngine_flushPendingReady, true)
        -- Auto-add friendly "Player" group when character is available
        pcall(UEngine_scheduleAutoAddPlayer)
      end)
    else
      if err then
        log('UEInfoScanner failure:'..err)
      else
        log('UEInfoScanner failure')
      end
      synchronize(function()
        pcall(UEngine_flushPendingReady, false)
        pcall(UE_destroyAllUEMenuComponents)
        if UEngine then UEngine.GUI=nil end
      end)
    end
  end)
end

-- Structure Dissect / Lookup callbacks
local bitbytetobitnr={}
for i=0,7 do
  bitbytetobitnr[1<<i]=i
end

function UEngine_createStructureFromObject(address)
  if UEngine.UObject.Class==nil then return nil,'No UObject class offset' end
  local c=readPointer(address+UEngine.UObject.Class)
  if c then
    return UEngine_createStructureFromClass(c)
  end
end

function UEngine_createStructureFromClass(address)
  -- getStructure is INDEX-only in CE 7.5 — never pass a name string
  local UClassStruct=UEngine_findStructureByName('UClass')
  if UClassStruct==nil then
    UClassStruct=createStructure('UClass')
    local e=UClassStruct.addElement()
    e.Name='vftable'
    e.Offset=0
    e.VarType=vtPointer

    e=UClassStruct.addElement()
    e.Name='Name'
    e.Offset=UEngine.UClass.Name
    e.PreviewPriority=1
    e.VarType=vtCustom
    e.CustomTypeName='UE FName to String'

    e=UClassStruct.addElement()
    e.Name='Class'
    e.Offset=UEngine.UClass.Class
    e.VarType=vtPointer
    e.ChildStruct=UClassStruct
    e.PreviewPriority=2
    
    e=UClassStruct.addElement()
    e.Name='SuperStruct'
    e.Offset=UEngine.UClass.SuperStruct 
    e.VarType=vtPointer
    e.ChildStruct=UClassStruct
    
    e=UClassStruct.addElement()
    e.Name='PropertyLink'
    e.Offset=UEngine.UClass.PropertyLink
    e.VarType=vtPointer
    
    e=UClassStruct.addElement()
    e.Name='PropertyLink (fallback)'
    e.Offset=UEngine.UClass.PropertyLinkAlt
    e.VarType=vtPointer    
    
    UClassStruct.addToGlobalStructureList()
  end

  local UObjectStruct=UEngine_findStructureByName('UObject')
  if UObjectStruct==nil then
    UObjectStruct=createStructure('UObject')
    local e=UObjectStruct.addElement()
    e.Name='vftable'
    e.Offset=0
    e.VarType=vtPointer

    e=UObjectStruct.addElement()
    e.Name='Name'
    e.Offset=UEngine.UObject.Name
    e.PreviewPriority=1
    e.VarType=vtCustom
    e.CustomTypeName='UE FName to String'

    e=UObjectStruct.addElement()
    e.Name='Class'
    e.Offset=UEngine.UObject.Class
    e.VarType=vtPointer
    e.ChildStruct=UClassStruct
   
    e.PreviewPriority=2
    
    UObjectStruct.addToGlobalStructureList()
  end

  if address and address~=0 then
    local name=UObject_getName(address)
    local properties=UClass_enumProperties(address,false)
    if properties==nil then
      properties=UClass_enumProperties(address,true)   
    else
      UClass_enumProperties(address,true,properties)   
    end
     
    if properties==nil and name==nil then
      return nil
    end
    
    s=UObjectStruct.clone(name)
    if s==nil then return nil end
    
    local e

    if properties then
      for name,info in pairs(properties) do
        e=s.addElement()
        e.Name=name
        e.Offset=info.offset
        e.Vartype=vtPointer

        if info.propertyType=='BoolProperty' then
          local bit=readByte(info.propertyAddress+UEngine.FProperty.BitMaskField+2)
          local bitnr=bitbytetobitnr[bit]
          local byteOff=readByte(info.propertyAddress+UEngine.FProperty.BitMaskField+1) or 0
          if bitnr then
            e.Vartype=vtBinary
            e.Offset=info.offset+byteOff
            e.BitStart=bitnr
            e.BitSize=1
          else
            e.Vartype=vtByte
          end
        end

        if info.propertyType=='IntProperty' then
          e.Vartype=vtDword
        end

        if info.propertyType=='ByteProperty' then
          e.Vartype=vtByte
        end

        if info.propertyType=='FloatProperty' then
          local ok,sz=pcall(readInteger, info.propertyAddress+UEngine.FProperty.Size)
          if ok and sz and sz==4 then
            e.Vartype=vtSingle
          else
            e.Vartype=vtDouble
          end
        end

        if info.propertyType=='StructProperty' then
          if name:endsWith('Name') then
            e.Vartype=vtCustom
            e.CustomTypeName='UE FName to String'
          else
            e.Vartype=vtByteArray
            local ok,sz=pcall(readInteger, info.propertyAddress+UEngine.FProperty.Size)
            if ok and sz then e.ByteSize=sz end
          end
        end

        if info.propertyType=='StrProperty' then
          e.Vartype=vtPointer
          e.ChildStruct=UEngine_findStructureByName('widestring')
        end

        if info.propertyType=='ClassProperty' then
          e.Vartype=vtPointer
          e.ChildStruct=UEngine_findStructureByName('UClass')
        end

        if info.propertyType=='ObjectProperty' then
          e.Vartype=vtPointer
          if UEngine.FProperty.ObjectClassType then
            local ok2,classAddr=pcall(readPointer, info.propertyAddress+UEngine.FProperty.ObjectClassType)
            if ok2 and classAddr and classAddr~=0 then
              local childClassName=UObject_getName(classAddr)
              if childClassName then
                e.ChildClassName=childClassName
              end
            end
          end
          e.OnCreateChild=function(element, address)
            if address and address~=0 then
              local newstruct=UEngine_createStructureFromObject(address)
              if newstruct then return newstruct end
            end
            return nil
          end
        end

        if e.ChildClassName=='' then
          e.ChildClassName=string.format('Property: %x',info.propertyAddress)
        end
      end
    end

    s.addToGlobalStructureList()
    return s
  end
end

function unregisterUEngineStructureLookupCallbacks()
  if UEngineStructNameLookup then
    if unregisterStructureNameLookup then
      unregisterStructureNameLookup(UEngineStructNameLookup)
    end
    UEngineStructNameLookup=nil
  end
  
  if UEngineStructDissect then
    if unregisterStructureDissectOverride2 then
      unregisterStructureDissectOverride2(UEngineStructDissect)
    elseif unregisterStructureDissectOverride then
      unregisterStructureDissectOverride(UEngineStructDissect)
    end
    UEngineStructDissect=nil
  end
end

function UEngine_followPropertyPath(startAddr, path)
  local addr=startAddr
  for i, step in ipairs(path) do
    local propName=step[1]
    local arrayIdx=step[2] or 0

    local classPtr=readPointer(addr+UEngine.UObject.Class)
    if classPtr==nil or classPtr==0 then
      return nil,'Step '..i..': Failed to read class'
    end

    local props=UEngine_getAllProperties(classPtr)
    if props==nil then
      return nil,'Step '..i..': Failed to enumerate properties'
    end

    local prop=props[propName]
    if prop==nil then
      return nil,'Step '..i..': Property "'..propName..'" not found'
    end

    if prop.propertyType=='StructProperty' then
      local elemPtr, count=UEngine_readTArrayElement(addr, prop.offset, arrayIdx)
      if elemPtr==nil or elemPtr==0 then
        return nil,'Step '..i..': TArray['..arrayIdx..'] is nil (count='..tostring(count)..')'
      end
      addr=elemPtr
    else
      addr=readPointer(addr+prop.offset)
      if addr==nil or addr==0 then
        return nil,'Step '..i..': Nil pointer at "'..propName..'"'
      end
    end
  end
  return addr
end

function UEngine_findLocalPlayer()
  if UEngine.UGameEngine==nil then return nil,'UGameEngine not found. Run the scanner first.' end

  local geClass=readPointer(UEngine.UGameEngine+UEngine.UObject.Class)
  if geClass==nil or geClass==0 then return nil,'GameEngine class unreadable' end

  local geProps=UEngine_getAllProperties(geClass)
  if geProps==nil then return nil,'Failed to enumerate GameEngine properties' end

  local giProp=geProps['GameInstance']
  if giProp==nil then return nil,'GameInstance property not found on GameEngine' end

  local giAddr=readPointer(UEngine.UGameEngine+giProp.offset)
  if giAddr==nil or giAddr==0 then return nil,'GameInstance is nil' end

  local giClass=readPointer(giAddr+UEngine.UObject.Class)
  if giClass==nil or giClass==0 then return nil,'GameInstance class unreadable' end

  local lpProp=nil
  local giProps=UEngine_getAllProperties(giClass)
  if giProps then
    lpProp=giProps['LocalPlayers']
    if lpProp==nil then
      for name,info in pairs(giProps) do
        if name:lower():find('player') and info.propertyType=='StructProperty' then
          lpProp=info
          break
        end
      end
    end
  end
  if lpProp==nil then return nil,'LocalPlayers property not found' end

  local plrPtr,plrCount=UEngine_readTArrayElement(giAddr, lpProp.offset, 0)
  if plrPtr==nil or plrPtr==0 then return nil,'First player nil (count='..tostring(plrCount)..')' end

  local chain={giProp.offset, lpProp.offset, 0}
  return plrPtr, plrCount, chain
end

function UEngine_findCharacter()
  local plrPtr,plrCount,chain=UEngine_findLocalPlayer()
  if plrPtr==nil then return nil,plrCount end

  local lpClass=readPointer(plrPtr+UEngine.UObject.Class)
  if lpClass==nil or lpClass==0 then return nil,'LocalPlayer class unreadable' end

  local lpProps=UEngine_getAllProperties(lpClass)
  if lpProps==nil then return nil,'Failed to enumerate LocalPlayer properties' end

  local pcProp=lpProps['PlayerController']
  if pcProp==nil then
    for name,info in pairs(lpProps) do
      if info.propertyType=='ObjectProperty' and name:lower():find('controller') then
        pcProp=info
        break
      end
    end
  end
  if pcProp==nil then return nil,'PlayerController property not found on LocalPlayer' end

  local pcPtr=readPointer(plrPtr+pcProp.offset)
  if pcPtr==nil or pcPtr==0 then return nil,'PlayerController is nil' end

  local pcClass=readPointer(pcPtr+UEngine.UObject.Class)
  if pcClass==nil or pcClass==0 then return nil,'PlayerController class unreadable' end

  local pcProps=UEngine_getAllProperties(pcClass)
  if pcProps==nil then return nil,'Failed to enumerate PlayerController properties' end

  local pawnProp=pcProps['Pawn']
  if pawnProp==nil then
    for name,info in pairs(pcProps) do
      if info.propertyType=='ObjectProperty' and (name:lower():find('pawn') or name:lower():find('character') or name:lower():find('owner')) then
        pawnProp=info
        break
      end
    end
  end
  if pawnProp==nil then return nil,'Pawn property not found on PlayerController' end

  local charPtr=readPointer(pcPtr+pawnProp.offset)
  if charPtr==nil or charPtr==0 then return nil,'Pawn/Character is nil' end

  local charClass=readPointer(charPtr+UEngine.UObject.Class)
  local charClassName=UObject_getName(charClass) or 'Character'

  table.insert(chain, pcProp.offset)
  table.insert(chain, pawnProp.offset)

  return charPtr, charClassName, chain
end

-- CE 7.5 MemoryRecord Binary API: mr.Binary.Startbit / mr.Binary.Size
-- NOTE: DropDownList on MemoryRecord caused ACCESS VIOLATION on this CE 7.5 build
-- (even clear/add / string assign). Disabled until a safe API is confirmed.
-- Values show as binary 0/1; edit still works.
local function UEngine_applyBoolDropDown(mr)
  return false
end

local function UEngine_setBoolBit(mr, propertyAddress, chain, baseOffset)
  local bitMaskField=UEngine.FProperty and UEngine.FProperty.BitMaskField
  local byteOff, bitMask=0, nil
  if bitMaskField and propertyAddress then
    pcall(function()
      byteOff=readByte(propertyAddress+bitMaskField+1) or 0
      bitMask=readByte(propertyAddress+bitMaskField+2)
    end)
  end
  local bitnr=bitMask and bitbytetobitnr[bitMask]
  local off=(baseOffset or 0)+(byteOff or 0)
  if chain then
    pcall(function() UEngine_setChainAddress(mr, 'GEngine', chain, off) end)
  end
  if bitnr~=nil then
    pcall(function() mr.VarType=vtBinary end)
    pcall(function() mr.Binary.Startbit=bitnr end)
    pcall(function() mr.Binary.Size=1 end)
    return true
  end
  pcall(function() mr.VarType=vtByte end)
  return false
end

local function UEngine_isPointerLikeProp(ptype)
  if not ptype then return true end
  return ptype=='ObjectProperty' or ptype=='ClassProperty'
    or ptype=='WeakObjectProperty' or ptype=='SoftObjectProperty'
    or ptype=='SoftClassProperty' or ptype=='InterfaceProperty'
    or ptype=='DelegateProperty' or ptype=='MulticastInlineDelegateProperty'
    or ptype=='MulticastDelegateProperty' or ptype=='MulticastSparseDelegateProperty'
    or ptype=='ArrayProperty' or ptype=='MapProperty' or ptype=='SetProperty'
    or ptype=='FieldPathProperty' or ptype=='LazyObjectProperty'
end

function UEngine_mrDelete(mr)
  if not mr then return end
  pcall(function()
    if mr.delete then mr.delete()
    elseif mr.destroy then mr.destroy() end
  end)
end

function UEngine_mrClearChildren(mr)
  if not mr then return end
  pcall(function()
    local guard=0
    while guard<5000 do
      guard=guard+1
      local n=0
      pcall(function() n=mr.Count or 0 end)
      if n<1 then break end
      local c=nil
      pcall(function() c=mr.Child[0] end)
      if not c then
        pcall(function() c=mr.Child[n-1] end)
      end
      if not c then break end
      UEngine_mrDelete(c)
    end
  end)
end

function UEngine_mrLooksAlive(mr)
  if not mr then return false end
  local ok,d=pcall(function() return mr.Description end)
  return ok and d~=nil
end

-- Friendly fixed address-list title (not the raw BP class name)
local UE_PLAYER_ROOT_TITLE='Player'

-- Find existing player group: stored root, "Player …", or legacy class name
function UEngine_findPlayerRootMR(fl, className)
  fl=fl or getAddressList()
  UEngine.Player=UEngine.Player or {}
  if UEngine_mrLooksAlive(UEngine.Player.rootMR) then
    return UEngine.Player.rootMR
  end
  UEngine.Player.rootMR=nil
  if not fl then return nil end
  className=className or UEngine.Player.rootClassName
  local candidates={
    UE_PLAYER_ROOT_TITLE,
    'Player (auto on load)',
  }
  if className and className~='' then
    candidates[#candidates+1]=className
  end
  for _,desc in ipairs(candidates) do
    local ok,mr=pcall(function() return fl.getMemoryRecordByDescription(desc) end)
    if ok and UEngine_mrLooksAlive(mr) then return mr end
  end
  -- Scan top-level: "Player (N props)", "Player …", or legacy ClassName (N props)
  local n=fl.Count or 0
  for i=0,n-1 do
    local ok,mr=pcall(function() return fl[i] end)
    if not ok or not mr then
      ok,mr=pcall(function() return fl.getMemoryRecord(i) end)
    end
    if ok and UEngine_mrLooksAlive(mr) then
      local d=tostring(mr.Description or '')
      local low=d:lower()
      if low:sub(1,6)=='player' then
        return mr
      end
      if className and className~='' then
        if d==className or d:sub(1,#className)==className then
          if d:find('%(%d+ props%)') or d:find('player',1,true) then
            return mr
          end
        end
      end
    end
  end
  return nil
end

function UEngine_resolveChain(baseSymbol, chain, finalOffset)
  local addr=nil
  if baseSymbol=='GEngine' then
    addr=UEngine.UGameEngine
  end
  if addr==nil or addr==0 then return nil end

  for i=1,#chain do
    addr=readPointer(addr+chain[i])
    if addr==nil or addr==0 then return nil end
  end

  if finalOffset and finalOffset>0 then
    addr=addr+finalOffset
  end
  return addr
end

function UEngine_setChainAddress(mr, baseSymbol, chain, finalOffset)
  local n=#chain
  if n==0 then
    mr.Address=string.format('%X', finalOffset or 0)
    return
  end

  local parts={}
  table.insert(parts, string.rep('[', n))
  table.insert(parts, baseSymbol..string.format('+%X', chain[1]))
  for i=2,n do
    table.insert(parts, string.format(']+%X', chain[i]))
  end
  if finalOffset and finalOffset>0 then
    table.insert(parts, string.format(']+%X', finalOffset))
  else
    table.insert(parts, ']+0')
  end

  mr.Address=table.concat(parts)
end

function UEngine_searchPropsOnObject(objPtr, searchTerms)
  local classPtr=readPointer(objPtr+UEngine.UObject.Class)
  if classPtr==nil or classPtr==0 then return {} end

  local allFound={}
  local props=UEngine_getAllProperties(classPtr)
  if props then
    for _,term in ipairs(searchTerms) do
      for name,info in pairs(props) do
        if name:lower():find(term:lower()) then
          allFound[name]=info
        end
      end
    end
  end

  local super=readPointer(classPtr+UEngine.UClass.SuperStruct)
  while super and super~=0 do
    local superProps=UEngine_getAllProperties(super)
    if superProps then
      for _,term in ipairs(searchTerms) do
        for name,info in pairs(superProps) do
          if name:lower():find(term:lower()) then
            allFound[name]=info
          end
        end
      end
    end
    super=readPointer(super+UEngine.UClass.SuperStruct)
    local superName=super and UObject_getName(super) or ''
    if superName=='Object' then break end
  end

  return allFound, classPtr
end

function UEngine_searchCharacterProperties()
  print('')
  print('========================================')
  print('  UE PROPERTY SEARCH: Inventory')
  print('========================================')

  print('Following chain: GameEngine -> GameInstance -> LocalPlayers -> PlayerController -> Pawn/Character')
  local charPtr,err,chain=UEngine_findCharacter()
  if charPtr==nil then
    print('ERROR: '..tostring(err))
    return nil
  end

  local charClass=readPointer(charPtr+UEngine.UObject.Class)
  if charClass==nil or charClass==0 then
    print('ERROR: Character class unreadable')
    return nil
  end

  local charClassName=UObject_getName(charClass) or 'Unknown'
  print('  Character class: '..charClassName)
  print('')

  local searchTerms={'Inventory','Item','Backpack','Bag','Loot','Equipment','Gear','Storage','Slot','Weapon','Ammo','Container'}
  local allFound=UEngine_searchPropsOnObject(charPtr, searchTerms)

  if next(allFound) then
    print('--- Found inventory-related properties on '..charClassName..' ---')
    for name,info in pairs(allFound) do
      local extra=''
      if info.propertyType=='ObjectProperty' then
        local objPtr=readPointer(charPtr+info.offset)
        if objPtr and objPtr~=0 then
          local objClass=readPointer(objPtr+UEngine.UObject.Class)
          local objClassName=UObject_getName(objClass)
          extra=' -> '..tostring(objClassName)..' ('..string.format('0x%X',objPtr)..')'
        else
          extra=' -> (nil)'
        end
      elseif info.propertyType=='StructProperty' or info.propertyType=='ArrayProperty' then
        local dataPtr,count=UEngine_readTArrayElement(charPtr, info.offset, 0)
        if dataPtr and dataPtr~=0 then
          extra=' [count='..tostring(count)..']'
        else
          extra=' [count='..tostring(count)..']'
        end
      end
      print(string.format('  %s @ +0x%X (%s)%s', name, info.offset, tostring(info.propertyType), extra))
    end

    for name,info in pairs(allFound) do
      if info.propertyType=='ObjectProperty' then
        local objPtr=readPointer(charPtr+info.offset)
        if objPtr and objPtr~=0 then
          local objClass=readPointer(objPtr+UEngine.UObject.Class)
          if objClass and objClass~=0 then
            local objClassName=UObject_getName(objClass) or 'Unknown'
            print('')
            print('--- Properties of '..name..' ('..objClassName..') ---')
            UEngine_dumpAllProperties(objClass, objClassName)
          end
        end
      elseif info.propertyType=='StructProperty' or info.propertyType=='ArrayProperty' then
        local elemPtr,count=UEngine_readTArrayElement(charPtr, info.offset, 0)
        if elemPtr and elemPtr~=0 and count and count>0 then
          print('')
          print('--- '..name..' (TArray, '..count..' elements) ---')
          local maxShow=math.min(count, 5)
          for i=0,maxShow-1 do
            local ep,epCount=UEngine_readTArrayElement(charPtr, info.offset, i)
            if ep and ep~=0 then
              local epClass=readPointer(ep+UEngine.UObject.Class)
              local epClassName=UObject_getName(epClass) or 'Unknown'
              print(string.format('  [%d] %s @ %s', i, epClassName, string.format('0x%X',ep)))
              if i==0 and epClass and epClass~=0 then
                UEngine_dumpAllProperties(epClass, epClassName)
              end
            end
          end
          if count>maxShow then
            print('  ... ('..(count-maxShow)..' more)')
          end
        end
      end
    end
  else
    print('No inventory-related properties found on '..charClassName)
  end

  print('')
  print('--- ALL properties of '..charClassName..' ---')
  UEngine_dumpAllProperties(charClass, charClassName)

  print('')
  print('========================================')
  print('  Search complete')
  print('========================================')
  return charPtr, charClassName, chain
end

-- Short UE hints (keep brief — Description budget ~70 with " · " and optional [S/C/U/P]).
-- Tiers: S=safe-ish SP edit, C=caution, U=unsafe engine/net, P=pointer (don't poke)
local UEngine_PlayerPropHints={
  -- Network / authority
  Role='Authority (Auth/Auto/Sim)',
  RemoteRole='Remote net role',
  NetTag='Rep generation tag',
  NetUpdateFrequency='Replicate Hz',
  MinNetUpdateFrequency='Min rep Hz',
  NetPriority='Rep priority',
  NetCullDistanceSquared='Net relevancy dist²',
  NetDormancy='Idle dormancy',
  bReplicates='Replicate actor',
  bReplicateMovement='Replicate move',
  bNetLoadOnClient='Load on client',
  bNetUseOwnerRelevancy='Owner relevancy',
  bOnlyRelevantToOwner='Owner-only rel',
  bAlwaysRelevant='Always relevant',
  bReplayRewindable='Replay rewind',
  bExchangedRoles='Roles exchanged',
  -- Lifecycle / time
  InitialLifeSpan='Auto-destroy after s',
  CustomTimeDilation='Time scale (1=norm)',
  -- Input / possess
  AutoReceiveInput='Auto player input',
  InputPriority='Input stack prio',
  AutoPossessPlayer='Auto-possess player',
  AutoPossessAI='AI possess on spawn',
  AIControllerClass='AI controller class',
  OverrideInputComponentClass='Custom input comp',
  -- Spawn / editor
  SpawnCollisionHandlingMethod='Spawn blocking',
  SpriteScale='Editor sprite scale',
  RayTracingGroupId='RT group id',
  RayTracingGroupCullingPriority='RT cull prio',
  -- Pawn / Character
  BaseEyeHeight='Eye height cm',
  CrouchedEyeHeight='Crouch eye cm',
  PlayerState='PlayerState obj',
  Controller='Possessing controller',
  LastHitBy='Last damager ctrl',
  ControlInputVector='Pending move input',
  LastControlInputVector='Prev move input',
  JumpMaxCount='Max jumps/air',
  JumpCurrentCount='Jumps used',
  JumpForceTimeRemaining='Jump force left',
  JumpMaxHoldTime='Max jump hold s',
  JumpKeyHoldTime='Jump hold s',
  AnimRootMotionTranslationScale='Root motion scale',
  ReplayLastTransformUpdateTimeStamp='Replay xform time',
  -- Components (pointers)
  Mesh='Skeletal mesh',
  CharacterMovement='Move component',
  CapsuleComponent='Collision capsule',
  ArrowComponent='Editor arrow',
  RootComponent='Scene root',
  InstantiatedSoftObjectPointers='Soft obj instances',
  -- Common tick / visibility
  bCanEverTick='Allow actor tick',
  bAllowTickBeforeBeginPlay='Tick before BeginPlay',
  bActorEnableCollision='Collision enabled',
  bHidden='Hidden (not rendered)',
  bCanBeDamaged='Can take damage',
  bFindCameraComponentWhenViewTarget='Find cam on view',
  bUseControllerRotationPitch='Ctrl→pitch',
  bUseControllerRotationYaw='Ctrl→yaw',
  bUseControllerRotationRoll='Ctrl→roll',
  bUseControllerDesiredRotation='Ctrl desired rot',
  bOrientRotationToMovement='Face move dir',
}

-- Explicit tiers when known; else inferred (see UEngine_playerPropTier)
local UEngine_PlayerPropTiers={
  Role='U', RemoteRole='U',
  NetTag='U', NetUpdateFrequency='C', MinNetUpdateFrequency='C',
  NetPriority='C', NetCullDistanceSquared='C', NetDormancy='C',
  bReplicates='U', bReplicateMovement='U', bNetLoadOnClient='U',
  bNetUseOwnerRelevancy='U', bOnlyRelevantToOwner='U', bAlwaysRelevant='U',
  bReplayRewindable='C', bExchangedRoles='U',
  InitialLifeSpan='C', CustomTimeDilation='C',
  AutoReceiveInput='C', InputPriority='C',
  AutoPossessPlayer='C', AutoPossessAI='C',
  AIControllerClass='P', OverrideInputComponentClass='P',
  SpawnCollisionHandlingMethod='C',
  SpriteScale='S', RayTracingGroupId='?', RayTracingGroupCullingPriority='?',
  BaseEyeHeight='S', CrouchedEyeHeight='S',
  PlayerState='P', Controller='P', LastHitBy='P',
  ControlInputVector='C', LastControlInputVector='C',
  JumpMaxCount='S', JumpCurrentCount='S', JumpForceTimeRemaining='S',
  JumpMaxHoldTime='S', JumpKeyHoldTime='S',
  AnimRootMotionTranslationScale='C',
  ReplayLastTransformUpdateTimeStamp='U',
  Mesh='P', CharacterMovement='P', CapsuleComponent='P',
  ArrowComponent='P', RootComponent='P', InstantiatedSoftObjectPointers='P',
  bCanEverTick='C', bAllowTickBeforeBeginPlay='C',
  bActorEnableCollision='C', bHidden='C', bCanBeDamaged='S',
  bFindCameraComponentWhenViewTarget='C',
  bUseControllerRotationPitch='S', bUseControllerRotationYaw='S',
  bUseControllerRotationRoll='S', bUseControllerDesiredRotation='S',
  bOrientRotationToMovement='S',
}

function UEngine_playerPropHint(name)
  if not name then return nil end
  if UEngine_PlayerPropHints[name] then return UEngine_PlayerPropHints[name] end
  local n=name
  if n:match('^bNet') or n:match('^Net') or n=='Role' or n=='RemoteRole' then
    if n:find('Dormant',1,true) then return 'Net dormancy' end
    if n:find('Replicat',1,true) then return 'Replication flag' end
    if n:find('Load',1,true) then return 'Net load flag' end
    if n:match('^bNet') then return 'Net/rep flag' end
    if n:match('^Net') then return 'Network setting' end
  end
  if n:match('^bCan') then return 'Capability flag' end
  if n:match('^bIs') or n:match('^bWas') or n:match('^bHas') then return 'State flag' end
  if n:match('^bEnable') or n:match('^bUse') then return 'Feature toggle' end
  if n:find('Jump',1,true) then return 'Jump-related' end
  if n:find('Crouch',1,true) then return 'Crouch-related' end
  if n:find('Collision',1,true) or n:find('Overlap',1,true) then return 'Collision' end
  if n:find('Input',1,true) then return 'Input-related' end
  if n:find('Camera',1,true) or n:find('Eye',1,true) then return 'Camera/view' end
  if n:find('Damage',1,true) or n:find('Health',1,true) then return 'Damage/health' end
  if n:find('Replicat',1,true) then return 'Replication' end
  if n:find('Tick',1,true) then return 'Tick/update' end
  if n:find('Hidden',1,true) or n:find('Visible',1,true) then return 'Visibility' end
  if n:find('Component',1,true) or n:find('Mesh',1,true) then return 'Component ref' end
  return nil
end

-- S/C/U/P/? — for Description tag and dump glossary
function UEngine_playerPropTier(name, ptype)
  if not name then return '?' end
  if UEngine_PlayerPropTiers[name] then return UEngine_PlayerPropTiers[name] end
  local n=name
  local low=n:lower()
  if ptype and (ptype:find('Object',1,true) or ptype:find('Class',1,true)
    or ptype:find('Soft',1,true) or ptype:find('Weak',1,true)
    or ptype=='StructProperty' or ptype=='InterfaceProperty') then
    return 'P'
  end
  if n:match('^bNet') or n=='Role' or n=='RemoteRole' or low:find('replicat',1,true) then
    return 'U'
  end
  if low:find('tick',1,true) and n:match('^b') then return 'C' end
  if low:find('lifespan',1,true) or low:find('destroy',1,true) then return 'C' end
  if low:find('jump',1,true) or low:find('crouch',1,true) or low:find('eyeheight',1,true) then
    return 'S'
  end
  if low:find('damage',1,true) or low:find('health',1,true) then return 'S' end
  if n:match('^b') then return 'C' end
  if low:find('component',1,true) or low:find('mesh',1,true) or low:find('controller',1,true) then
    return 'P'
  end
  return '?'
end

-- Pack "Name · hint [T]" into maxLen (default 70). Prefer name, then tier, then hint.
local PROP_DESC_MAX=70
function UEngine_formatPlayerPropDescription(name, ptype, maxLen)
  maxLen=maxLen or PROP_DESC_MAX
  name=tostring(name or '?')
  local hint=UEngine_playerPropHint(name) or ''
  local tier=UEngine_playerPropTier(name, ptype)
  local tag=''
  if tier and tier~='?' then tag=' ['..tier..']' end

  local function fit(n, h, t)
    local s=n
    if h and h~='' then s=n..' · '..h end
    if t and t~='' then s=s..t end
    return s
  end

  local full=fit(name, hint, tag)
  if #full<=maxLen then return full, hint, tier end

  -- Drop tier if needed
  full=fit(name, hint, '')
  if #full<=maxLen then return full, hint, tier end

  -- Truncate hint
  local sep=' · '
  if hint~='' and #name+#sep+1<=maxLen then
    local hmax=maxLen-#name-#sep
    if hmax>=3 then
      return name..sep..hint:sub(1, hmax-1)..'…', hint, tier
    end
  end
  if #name<=maxLen then return name, hint, tier end
  return name:sub(1, maxLen-1)..'…', hint, tier
end

-- Sub-group under Flags for bools (name-driven “natural” clustering)
local function UEngine_playerFlagSub(name)
  local n=name or ''
  local low=n:lower()
  if n:match('^bNet') or low:find('replicat',1,true) or low:find('dormant',1,true)
    or low:find('relevant',1,true) or low:find('replay',1,true) then
    return 'Network'
  end
  if low:find('jump',1,true) or low:find('crouch',1,true) or low:find('movement',1,true)
    or low:find('fly',1,true) or low:find('walk',1,true) or low:find('fall',1,true)
    or low:find('orientrotation',1,true) or low:find('controllerrotation',1,true) then
    return 'Movement'
  end
  if low:find('input',1,true) or low:find('possess',1,true) then return 'Input' end
  if low:find('collision',1,true) or low:find('overlap',1,true) or low:find('hit',1,true)
    or low:find('physics',1,true) then
    return 'Collision'
  end
  -- Life / combat (with top-level Life numerics like InitialLifeSpan)
  if low:find('damage',1,true) or low:find('health',1,true) or low:find('life',1,true)
    or low:find('die',1,true) or low:find('death',1,true) or low:find('god',1,true)
    or n=='bCanBeDamaged' then
    return 'Life'
  end
  if low:find('hidden',1,true) or low:find('visible',1,true) or low:find('render',1,true)
    or low:find('sprite',1,true) or low:find('raytracing',1,true) then
    return 'Rendering'
  end
  if low:find('camera',1,true) or low:find('eye',1,true) or low:find('view',1,true) then
    return 'Camera'
  end
  if low:find('tick',1,true) then return 'Tick' end
  return 'Other'
end

-- Useful object refs we keep visible; everything else pointer-like → Debug
local UEngine_PlayerUsefulPointers={
  Mesh=true, CharacterMovement=true, CapsuleComponent=true, RootComponent=true,
  Controller=true, PlayerState=true, LastHitBy=true,
  ArrowComponent=true, -- optional editor; still somewhat useful
}

-- Semantic bucket for grouping (values + flags + some debug names)
local function UEngine_playerPropBucket(name, ptype)
  local n=name or ''
  local low=n:lower()
  -- All bools under one Flags tree (subs via UEngine_playerFlagSub)
  if ptype=='BoolProperty' then
    return 'Flags'
  end
  -- Pointers / soft refs / most structs: only whitelist stays out of Debug
  if UEngine_isPointerLikeProp(ptype) then
    if UEngine_PlayerUsefulPointers[n] then
      if low:find('controller',1,true) or low:find('playerstate',1,true)
        or n=='LastHitBy' then
        return 'Controllers'
      end
      return 'Components'
    end
    return 'Debug'
  end
  if ptype=='StructProperty' then
    -- Large/opaque structs are noise; small useful ones stay categorized below if named
    if low:find('transform',1,true) or low:find('vector',1,true)
      or low:find('rotator',1,true) or low:find('guid',1,true)
      or low:find('soft',1,true) then
      return 'Debug'
    end
  end
  -- numeric / enum values
  if n:match('^Net') or n=='Role' or n=='RemoteRole' or low:find('replicat',1,true)
    or low:find('dormancy',1,true) then
    return 'Network'
  end
  if low:find('jump',1,true) or low:find('crouch',1,true) or low:find('movement',1,true)
    or low:find('speed',1,true) or low:find('velocity',1,true) or low:find('gravity',1,true) then
    return 'Movement'
  end
  if low:find('input',1,true) or low:find('possess',1,true) then return 'Input' end
  if low:find('eye',1,true) or low:find('camera',1,true) or low:find('springarm',1,true) then
    return 'Camera'
  end
  if low:find('collision',1,true) or low:find('capsule',1,true) then return 'Collision' end
  if low:find('life',1,true) or low:find('damage',1,true) or low:find('health',1,true) then
    return 'Life'
  end
  if low:find('time',1,true) or low:find('dilat',1,true) or low:find('tick',1,true) then
    return 'Time'
  end
  if low:find('raytracing',1,true) or low:find('render',1,true) or low:find('sprite',1,true) then
    return 'Rendering'
  end
  return 'Other'
end

local UE_PLAYER_BUCKET_ORDER={
  'Movement','Network','Input','Camera','Collision','Life','Time','Rendering',
  'Flags','Components','Controllers','Other','Debug',
}
local UE_PLAYER_FLAG_SUB_ORDER={
  'Movement','Network','Input','Collision','Life','Camera','Rendering','Tick','Other',
}

function UEngine_addPlayerToAddressList(opts)
  opts=opts or {}
  local quiet=opts.quiet==true
  local charPtr,err,chain=UEngine_findCharacter()
  if charPtr==nil then
    if not quiet then
      log('Add Player failed: '..tostring(err))
      if showMessage then pcall(showMessage, 'Add Player failed:\n'..tostring(err)) end
    end
    return false, err
  end

  local charClass=readPointer(charPtr+UEngine.UObject.Class)
  local charClassName=UObject_getName(charClass) or 'Character'

  local fl=getAddressList()
  UEngine.Player=UEngine.Player or {}

  -- Reuse single "Player" group (no duplicates on second menu click)
  local groupMR=UEngine_findPlayerRootMR(fl, charClassName)
  local reused=false
  local rootOpts='[moHideChildren,moAllowManualCollapseAndExpand,moManualExpandCollapse]'
  if groupMR then
    reused=true
    UEngine_mrClearChildren(groupMR)
    pcall(function()
      groupMR.Description=UE_PLAYER_ROOT_TITLE
      groupMR.IsGroupHeader=true
      groupMR.Options=rootOpts
    end)
    pcall(function() UEngine_setChainAddress(groupMR, 'GEngine', chain, 0) end)
  else
    groupMR=fl.createMemoryRecord()
    groupMR.Description=UE_PLAYER_ROOT_TITLE
    UEngine_setChainAddress(groupMR, 'GEngine', chain, 0)
    groupMR.IsGroupHeader=true
    groupMR.Options=rootOpts
  end
  UEngine.Player.rootMR=groupMR
  UEngine.Player.rootClassName=charClassName

  local allProps={}
  local super=readPointer(charClass+UEngine.UClass.SuperStruct)
  local props=UEngine_getAllProperties(charClass)
  if props then
    for name,info in pairs(props) do
      allProps[name]=info
    end
  end

  while super and super~=0 do
    local superProps=UEngine_getAllProperties(super)
    if superProps then
      for name,info in pairs(superProps) do
        if allProps[name]==nil then
          allProps[name]=info
        end
      end
    end
    super=readPointer(super+UEngine.UClass.SuperStruct)
    local superName=super and UObject_getName(super) or ''
    if superName=='Object' then break end
  end

  local propList={}
  for name,info in pairs(allProps) do
    table.insert(propList, {name=name, info=info})
  end
  table.sort(propList, function(a,b) return a.info.offset<b.info.offset end)

  UEngine.LastPlayerProps=propList
  UEngine.LastPlayerClass=charClassName

  local bucketMR={}
  local bucketCount={}
  local flagSubMR={}
  local flagSubCount={}
  local GRP_OPTS='[moHideChildren,moAllowManualCollapseAndExpand,moManualExpandCollapse]'
  local function ensureBucket(name)
    if bucketMR[name] then return bucketMR[name] end
    local hdr=fl.createMemoryRecord()
    hdr.Description=name
    hdr.IsGroupHeader=true
    hdr.Options=GRP_OPTS
    hdr.Parent=groupMR
    bucketMR[name]=hdr
    bucketCount[name]=0
    return hdr
  end
  local function ensureFlagSub(sub)
    sub=sub or 'Other'
    if flagSubMR[sub] then return flagSubMR[sub] end
    local flags=ensureBucket('Flags')
    local hdr=fl.createMemoryRecord()
    hdr.Description=sub
    hdr.IsGroupHeader=true
    hdr.Options=GRP_OPTS
    hdr.Parent=flags
    flagSubMR[sub]=hdr
    flagSubCount[sub]=0
    return hdr
  end
  local function parentForProp(name, ptype)
    if ptype=='BoolProperty' then
      return ensureFlagSub(UEngine_playerFlagSub(name))
    end
    return ensureBucket(UEngine_playerPropBucket(name, ptype))
  end

  -- Pre-create in preferred order so tree sorts nicely
  for _,b in ipairs(UE_PLAYER_BUCKET_ORDER) do
    ensureBucket(b)
  end
  for _,s in ipairs(UE_PLAYER_FLAG_SUB_ORDER) do
    ensureFlagSub(s)
  end

  local byOffset={}
  local order={}
  for _,entry in ipairs(propList) do
    local off=entry.info.offset
    if not byOffset[off] then
      byOffset[off]={}
      order[#order+1]=off
    end
    byOffset[off][#byOffset[off]+1]=entry
  end
  table.sort(order)

  -- Description: "Name · hint [S|C|U|P]" max ~70 (see UEngine_formatPlayerPropDescription)
  local function labeledDesc(name, ptype)
    local s=UEngine_formatPlayerPropDescription(name, ptype, PROP_DESC_MAX)
    return s
  end

  local function addTypedMR(parent, entry)
    local mr=fl.createMemoryRecord()
    local ptype=entry.info.propertyType
    mr.Description=labeledDesc(entry.name, ptype)

    if ptype=='BoolProperty' then
      UEngine_setBoolBit(mr, entry.info.propertyAddress, chain, entry.info.offset)
    else
      UEngine_setChainAddress(mr, 'GEngine', chain, entry.info.offset)
      if ptype=='IntProperty' or ptype=='Int32Property' then
        mr.VarType=vtDword
      elseif ptype=='Int64Property' or ptype=='UInt64Property' then
        mr.VarType=vtQword
      elseif ptype=='UInt32Property' then
        mr.VarType=vtDword
      elseif ptype=='FloatProperty' then
        local ok,sz=pcall(readInteger, entry.info.propertyAddress+UEngine.FProperty.Size)
        if ok and sz and sz==4 then mr.VarType=vtSingle else mr.VarType=vtDouble end
      elseif ptype=='DoubleProperty' then
        mr.VarType=vtDouble
      elseif ptype=='ByteProperty' or ptype=='EnumProperty' then
        mr.VarType=vtByte
      elseif ptype=='NameProperty' then
        mr.VarType=vtDword
      elseif ptype=='StrProperty' then
        mr.VarType=vtPointer
      elseif ptype=='StructProperty' then
        mr.VarType=vtByteArray
        local ok,sz=pcall(readInteger, entry.info.propertyAddress+UEngine.FProperty.Size)
        if ok and sz and sz>0 and sz<=256 then
          pcall(function() mr.Aob.Size=sz end)
          pcall(function() mr.ByteSize=sz end)
        end
      else
        mr.VarType=vtPointer
      end
    end
    mr.Parent=parent
    return mr
  end

  local total=0
  for _,off in ipairs(order) do
    local group=byOffset[off]
    -- Bools: Flags → Network/Tick/… → values only (no "bits @" mid-level).
    -- Shared-byte bools still get correct BitStart via addTypedMR / Binary.
    for _,entry in ipairs(group) do
      local ptype=entry.info.propertyType
      local bucket=UEngine_playerPropBucket(entry.name, ptype)
      local parent=parentForProp(entry.name, ptype)
      addTypedMR(parent, entry)
      bucketCount[bucket]=(bucketCount[bucket] or 0)+1
      if ptype=='BoolProperty' then
        local sub=UEngine_playerFlagSub(entry.name)
        flagSubCount[sub]=(flagSubCount[sub] or 0)+1
      end
      total=total+1
    end
  end

  -- Label flag subs; remove empty
  for _,s in ipairs(UE_PLAYER_FLAG_SUB_ORDER) do
    local mr=flagSubMR[s]
    local c=flagSubCount[s] or 0
    if mr then
      if c==0 then
        pcall(function()
          if mr.delete then mr.delete() elseif mr.destroy then mr.destroy() end
        end)
        flagSubMR[s]=nil
      else
        mr.Description=string.format('%s (%d)', s, c)
      end
    end
  end

  -- Label buckets with counts; remove empty ones
  for _,b in ipairs(UE_PLAYER_BUCKET_ORDER) do
    local mr=bucketMR[b]
    local c=bucketCount[b] or 0
    if mr then
      if c==0 then
        pcall(function()
          if mr.delete then mr.delete() elseif mr.destroy then mr.destroy() end
        end)
        bucketMR[b]=nil
      else
        mr.Description=string.format('%s (%d)', b, c)
      end
    end
  end

  -- Friendly root title; class name kept in log / UEngine.Player.rootClassName
  groupMR.Description=string.format('%s (%d props)', UE_PLAYER_ROOT_TITLE, total)
  UEngine.Player.rootMR=groupMR
  UEngine.Player.rootClassName=charClassName

  if UEngine.Player.dumpProps then
    local path=UEngine.Player.dumpProps
    if type(path)~='string' then path='CE75-PLAYER-PROPS.txt' end
    pcall(function()
      local f=io.open(path, 'w')
      if not f then return end
      f:write(string.format('class=%s props=%d\n', charClassName, #propList))
      for _,entry in ipairs(propList) do
        local info=entry.info
        local bucket=UEngine_playerPropBucket(entry.name, info.propertyType)
        local hint=UEngine_playerPropHint(entry.name) or ''
        local tier=UEngine_playerPropTier(entry.name, info.propertyType) or '?'
        local extra=''
        if info.propertyType=='BoolProperty' and UEngine.FProperty and UEngine.FProperty.BitMaskField then
          local bo=readByte(info.propertyAddress+UEngine.FProperty.BitMaskField+1) or 0
          local bm=readByte(info.propertyAddress+UEngine.FProperty.BitMaskField+2) or 0
          extra=string.format(' byteOff=%d mask=0x%02X bit=%s', bo, bm, tostring(bitbytetobitnr[bm]))
        end
        f:write(string.format('+0x%04X  %-28s  %-16s  %-12s  [%s]  %s%s\n',
          info.offset, entry.name, tostring(info.propertyType), bucket, tier, hint, extra))
      end
      f:close()
    end)
  end

  if reused then
    log(string.format('Updated %s (%s): %d props', UE_PLAYER_ROOT_TITLE, charClassName, total))
  else
    log(string.format('Added %s (%s): %d props', UE_PLAYER_ROOT_TITLE, charClassName, total))
  end
  return true, total
end

-- After UE init: add/update "Player" when character exists (default ON).
-- Opt out: UEngine.Player.autoAdd=false
-- Dropdown labels disabled (caused AV); binary 0/1 only.
function UEngine_scheduleAutoAddPlayer()
  UEngine=UEngine or {}
  UEngine.Player=UEngine.Player or {}
  if UEngine.Player.autoAdd==false then
    log('Auto-add Player skipped (UEngine.Player.autoAdd=false)')
    return
  end
  if UEngine._autoPlayerTimer then return end
  local attempts=0
  local t=createTimer(MainForm)
  t.Interval=1500
  t.OnTimer=function(timer)
    attempts=attempts+1
    local ready=false
    pcall(function() ready=UEngine_isReady and UEngine_isReady() end)
    if not ready then
      if attempts>90 then
        pcall(function() timer.destroy() end)
        UEngine._autoPlayerTimer=nil
      end
      return
    end
    local charPtr=nil
    pcall(function()
      local p=UEngine_findCharacter()
      if p and p~=0 then charPtr=p end
    end)
    if charPtr then
      -- Defer so structure seed / menu settle after init
      pcall(function()
        local t2=createTimer(MainForm)
        t2.Interval=750
        t2.OnTimer=function(t2self)
          pcall(function() t2self.destroy() end)
          local aok,aerr=pcall(function()
            return UEngine_addPlayerToAddressList({quiet=true})
          end)
          if aok then
            log('Player auto-added/updated on address list (after UE init)')
          else
            log('Player auto-add failed: '..tostring(aerr))
          end
        end
        t2.Enabled=true
      end)
      pcall(function() timer.destroy() end)
      UEngine._autoPlayerTimer=nil
    elseif attempts>80 then
      log('Player auto-add: no character yet — use Add Player when in-game')
      pcall(function() timer.destroy() end)
      UEngine._autoPlayerTimer=nil
    end
  end
  t.Enabled=true
  UEngine._autoPlayerTimer=t
end



function UEngine_invReadAnsi(addr, len)
  if not addr or not len or len<1 or len>256 then return nil end
  local t={}
  for i=0,len-1 do
    local ok,b=pcall(readByte, addr+i)
    if not ok or not b or b<32 or b>126 then return nil end
    t[#t+1]=string.char(b)
  end
  return table.concat(t)
end

function UEngine_invParseFNameEntry(hdr)
  local ok0,b0=pcall(readByte, hdr)
  local ok1,b1=pcall(readByte, hdr+1)
  if not ok0 or not ok1 or b0==nil or b1==nil then return nil end
  local hv=b0|(b1<<8)
  if (hv&1)==1 then return nil end
  local lenA=(hv>>6)&0x3FF
  if lenA>0 and lenA<256 then
    local s=UEngine_invReadAnsi(hdr+2, lenA)
    if s then return s end
  end
  return nil
end



function UEngine_resolveFName(idx)
  local g=UEngine.GNamesBase or rawget(_G,'GNamesBase')
  if not g or not idx then return nil end
  idx=idx&0xFFFFFFFF
  local bp=readPointer(g+0x10+((idx>>16)*8))
  if not bp or bp==0 then return nil end
  return UEngine_invParseFNameEntry(bp+((idx&0xFFFF)*2))
end

-- Strip short prefix for cleaner labels: strips leading 3-4 letter + underscore
function UEngine_itemShortName(name)
  if not name or name=='' then return name end
  local rest=name:match('^%a%a%a%a_(.+)$')
  if rest then return rest end
  rest=name:match('^%a%a%a_(.+)$')
  if rest then return rest end
  return name
end

function UEngine_itemPrettyName(shortOrFull)
  if not shortOrFull then return '?' end
  local s=shortOrFull:gsub('_', ' ')
  s=s:gsub('(%l)(%u)', '%1 %2')
  s=s:gsub('%s+', ' '):gsub('^%s+', ''):gsub('%s+$', '')
  return s
end

-- ============================================================
-- Plugin Registry & Scanner
-- ============================================================

UEngine.Plugins=UEngine.Plugins or {registry={}}
UEngine.Plugins.loadedPlugins={}
UEngine.Plugins.scanned=false

function UEngine_scanPlugins()
  local src=debug.getinfo(1,'S').source
  local dir=src:sub(2):match('^(.*)[/\\]') or '.'
  local scriptsDir=dir..'/Scripts'
  local folders=getDirectoryList(scriptsDir, false) or {}
  local plugins={}
  for _,folder in ipairs(folders) do
    local mPath=scriptsDir..'/'..folder..'/'..folder..'.manifest'
    local lPath=scriptsDir..'/'..folder..'/'..folder..'-Plugin.lua'
    if fileExists(mPath) and fileExists(lPath) then
      local sl=createStringList()
      sl:loadFromFile(mPath)
      local entry={folder=folder, main=lPath}
      for i=0,sl.Count-1 do
        local line=sl[i]:gsub('^%s*(.-)%s*$', '%1')
        if line~='' and line:sub(1,1)~='#' then
          local k,v=line:match('^([^=]+)=(.*)$')
          if k then entry[k:lower()]=v end
        end
      end
      plugins[#plugins+1]=entry
    end
  end
  return plugins
end

function UEngine_registerPlugin(name, setupFn)
  if not name or not setupFn then return end
  UEngine.Plugins.registry[name]=setupFn
  if UEngine.GUI and UEngine.GUI.miPluginRoot then
    local mi=UE_newMenuItem(name)
    UEngine.GUI.miPluginRoot.add(mi)
    pcall(setupFn, mi)
  end
end

function UEngine_unloadPlugins()
  for name,_ in pairs(UEngine.Plugins.registry) do
    UEngine.Plugins.loadedPlugins[name]=nil
  end
  if UEngine.GUI and UEngine.GUI.miPluginRoot then
    pcall(function() UEngine.GUI.miPluginRoot.destroy() end)
    UEngine.GUI.miPluginRoot=nil
  end
  UEngine.Plugins.registry={}
  UEngine.Plugins.scanned=false
end

function UEngine_loadPlugin(entry)
  if not entry or not entry.main then return end
  if UEngine.Plugins.loadedPlugins[entry.name] then return end
  local ok,err=pcall(function() dofile(entry.main) end)
  if ok then
    UEngine.Plugins.loadedPlugins[entry.name]=true
    log(string.format('Plugin loaded: %s (%s)', entry.name or entry.folder, entry.main))
  else
    log(string.format('Plugin load failed: %s — %s', tostring(entry.name or entry.folder), tostring(err)))
  end
end

UEngine.PluginAPI={
  log=log,
  registerPlugin=UEngine_registerPlugin,
  getCharacter=UEngine_findCharacter,
  getLocalPlayer=UEngine_findLocalPlayer,
  enumerateProperties=UEngine_getAllProperties,
  resolveFName=UEngine_resolveFName,
  itemShortName=UEngine_itemShortName,
  itemPrettyName=UEngine_itemPrettyName,
  addressList=function() return getAddressList() end,
}

function registerUEngineStructureLookupCallbacks()
  if registerStructureNameLookup == nil then
    log('registerStructureNameLookup not available in this CE version')
    return
  end

  -- Avoid empty-TreeView crash on first dissect (CE 7.5)
  pcall(UEngine_ensureDissectSeed)

  unregisterUEngineStructureLookupCallbacks()

  UEngineStructNameLookup=registerStructureNameLookup(function(address)
    local obj=UEngine_findObjectStart(address)
    if obj then
      local class=readPointer(obj+UEngine.UObject.Class)
      local nameindex=readPointer(class+UEngine.UClass.Name)

      if nameindex and nameindex>0 then
        local name=UEngine.IndexToName[nameindex]

        if name then
          return name,obj
        end
      end
    end
  end,true)

  if UEngineStructDissect then
    if unregisterStructureDissectOverride2 then
      unregisterStructureDissectOverride2(UEngineStructDissect)
    elseif unregisterStructureDissectOverride then
      unregisterStructureDissectOverride(UEngineStructDissect)
    end
    UEngineStructDissect=nil
  end

  if registerStructureDissectOverride2 then
    log('registerUEngineStructureLookupCallbacks: using v2 (registerStructureDissectOverride2)')
    UEngineStructDissect=registerStructureDissectOverride2(function(address)
      local actual=UEngine_findObjectStart(address)

      if actual==address then
        local s=UEngine_createStructureFromObject(address)

        if s then
          local maxoffset=s[s.Count-1].offset
          for i=0,maxoffset,8 do
            local x=s.getElementByOffset(i)
            if s.getElementByOffsetExact(i)==nil then
              local a=readPointer(address+i)
              local name=UObject_getName(a)

              if name and name~='None' then
                local class=readPointer(a+UEngine.UObject.Class)
                if class and class~=0 then
                  local classname=UObject_getName(class)

                  if classname and classname~='None' then
                    local e=s.addElement()
                    e.offset=i
                    e.Name=name..' : '..classname
                    e.VarType=vtPointer
                    e.ChildStruct=nil
                  end
                end
              end
            end
          end
        end

        return s
      else
        return nil
      end
    end)
  elseif registerStructureDissectOverride then
    log('registerUEngineStructureLookupCallbacks: using v1 (registerStructureDissectOverride)')
    local v1callback=function(structure, address)
      log('v1 structure dissect callback invoked, address='..string.format('0x%X',address))
      local ok,result=pcall(function()
        local actual=UEngine_findObjectStart(address)
        if actual==nil then actual=address end

        local classPtr=readPointer(address+UEngine.UObject.Class)
        if not classPtr or classPtr==0 then return false end

        local className=UObject_getName(classPtr)

        local baseE=structure.addElement()
        baseE.Name='vftable'
        baseE.Offset=0
        baseE.VarType=vtPointer

        baseE=structure.addElement()
        baseE.Name='Class'
        baseE.Offset=UEngine.UObject.Class
        baseE.VarType=vtPointer
        baseE.PreviewPriority=1

        baseE=structure.addElement()
        baseE.Name='Name'
        baseE.Offset=UEngine.UObject.Name
        baseE.VarType=vtCustom
        baseE.CustomTypeName='UE FName to String'
        baseE.PreviewPriority=2

        local properties=UClass_enumProperties(classPtr, false)
        if properties==nil then
          properties=UClass_enumProperties(classPtr, true)
        else
          UClass_enumProperties(classPtr, true, properties)
        end

        if properties==nil then return false end

        local propCount=0
        for name,info in pairs(properties) do
          propCount=propCount+1
          local ok3,e=pcall(structure.addElement)
          if not ok3 or e==nil then
            log('v1 callback: addElement failed at prop '..tostring(name))
            break
          end

          pcall(function() e.Name=name end)
          pcall(function() e.Offset=info.offset end)
          e.VarType=vtPointer

          if info.propertyType=='BoolProperty' then
            local ok,bit=pcall(readByte, info.propertyAddress+UEngine.FProperty.BitMaskField+2)
            if ok and bit then
              local bitnr=bitbytetobitnr[bit]
              if bitnr then
                pcall(function() e.VarType=vtBinary end)
                pcall(function() e.BitStart=bitnr end)
                pcall(function() e.BitSize=1 end)
              else
                e.VarType=vtByte
              end
            else
              e.VarType=vtByte
            end
          end

          if info.propertyType=='IntProperty' then
            e.VarType=vtDword
          end

          if info.propertyType=='ByteProperty' then
            e.VarType=vtByte
          end

          if info.propertyType=='FloatProperty' then
            local ok,sz=pcall(readInteger, info.propertyAddress+UEngine.FProperty.Size)
            if ok and sz and sz==4 then
              e.VarType=vtSingle
            else
              e.VarType=vtDouble
            end
          end

          if info.propertyType=='StructProperty' then
            if name and name:endsWith('Name') then
              e.VarType=vtCustom
              pcall(function() e.CustomTypeName='UE FName to String' end)
            else
              e.VarType=vtByteArray
              local ok,sz=pcall(readInteger, info.propertyAddress+UEngine.FProperty.Size)
              if ok and sz then pcall(function() e.ByteSize=sz end) end
            end
          end

          if info.propertyType=='StrProperty' then
            e.VarType=vtPointer
            pcall(function() e.ChildStruct=UEngine_findStructureByName('widestring') end)
          end

          if info.propertyType=='ClassProperty' then
            e.VarType=vtPointer
            pcall(function() e.ChildStruct=UEngine_findStructureByName('UClass') end)
          end

          if info.propertyType=='ObjectProperty' then
            e.VarType=vtPointer
            if UEngine.FProperty.ObjectClassType then
              local ok2,classAddr=pcall(readPointer, info.propertyAddress+UEngine.FProperty.ObjectClassType)
              if ok2 and classAddr and classAddr~=0 then
                local childClassName=UObject_getName(classAddr)
                if childClassName then
                  pcall(function() e.ChildClassName=childClassName end)
                end
              end
            end
            pcall(function()
              e.OnCreateChild=function(element, childAddress)
                if childAddress and childAddress~=0 then
                  local newstruct=UEngine_createStructureFromObject(childAddress)
                  if newstruct then return newstruct end
                end
                return nil
              end
            end)
          end
        end

        if className then pcall(function() structure.Name=className end) end
        log('v1 callback: base=3 props='..propCount..' total='..structure.Count)

        return true
      end)

      if not ok then
        log('v1 structure dissect callback error: '..tostring(result))
        return false
      end
      return result
    end
    UEngineStructDissect=registerStructureDissectOverride(v1callback)
    log('registerUEngineStructureLookupCallbacks: v1 dissect override id='..tostring(UEngineStructDissect))
  else
    log('registerStructureDissectOverride not available in this CE version')
  end
end

-- Only capture the true original once (reload-safe; no nested wrappers)
if _G.__UECE75_OrigOnProcessOpened==nil then
  _G.__UECE75_OrigOnProcessOpened=MainForm.OnProcessOpened
end

MainForm.OnProcessOpened=function(...)
  local pid=getOpenedProcessID()
  if (pid==0xffffffff) or (pid==0xfffffffe) then
    if _G.__UECE75_OrigOnProcessOpened then
      return _G.__UECE75_OrigOnProcessOpened(...)
    end
    return
  end

  if UEInfoScannerThread then
    pcall(function() UEInfoScannerThread.Terminate() end)
    UEInfoScannerThread=nil
  end

  createThread(function(t)
    t.name='Check if Unreal Engine'
    waitForExports()
    if couldBeUnrealEngine() then
      LaunchUEInfoScanner()
    else
      if getProcessAge then
        local age=getProcessAge()
        if age==nil then return end
        if age<30000 then
          sleep(30000)
          if couldBeUnrealEngine() then
            if getOpenedProcessID()==pid then
              LaunchUEInfoScanner()
            end
          end
        end
      end
    end
  end)

  if _G.__UECE75_OrigOnProcessOpened then
    return _G.__UECE75_OrigOnProcessOpened(...)
  end
end

-- Placeholder ASAP (main thread) so empty structure list never hits CE 7.5 index-0 crash
pcall(function()
  if type(UEngine_ensureDissectSeed)=='function' then
    UEngine_ensureDissectSeed()
  end
end)

-- dofile/autorun while already attached: (re)start scanner without CE restart
if getOpenedProcessID and getOpenedProcessID()>0 and getOpenedProcessID()<0xfffffffe then
  createThread(function(t)
    t.name='UECE75 reload attach'
    sleep(200)
    pcall(function()
      if couldBeUnrealEngine and couldBeUnrealEngine() then
        LaunchUEInfoScanner()
      end
    end)
  end)
end
