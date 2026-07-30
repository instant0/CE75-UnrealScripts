-- g1r-plugin.lua
-- Gothic 1 Remake plugin for UnrealEngine-75.LUA
-- Loaded by the plugin scanner, then self-registers

-- ============================================================
-- Inventory offset defaults (G1R-specific hardcoded chain)
-- ============================================================
UEngine = UEngine or {}
do
  local invDefaults = {
    MANAGER=0x7B0, CONTAINER=0x170, INVMGR=0x168, ARRAY=0x378, COUNT=0x380,
    STRIDE=0xB8, ITEM=0x08, QTY=0x10, NAMEIDX=0x18,
    EQUIP_ARR=0x158, EQUIP_CNT=0x160,
    EQUIP_CDO_ARR=0x180, EQUIP_CDO_CNT=0x188,
    CHILDREN=0x190, CHILDREN_CNT=0x198,
    GNAMES_RVA=0x9AE6600,
  }
  UEngine.Inv = UEngine.Inv or {}
  for k,v in pairs(invDefaults) do
    if UEngine.Inv[k]==nil then UEngine.Inv[k]=v end
  end
end

-- ============================================================
-- FName helpers (local copies for self-containment)
-- ============================================================
local function invReadAnsi(addr, len)
  if not addr or not len or len<1 or len>256 then return nil end
  local t={}
  for i=0,len-1 do
    local ok,b=pcall(readByte, addr+i)
    if not ok or not b or b<32 or b>126 then return nil end
    t[#t+1]=string.char(b)
  end
  return table.concat(t)
end

local function invParseFNameEntry(hdr)
  local ok0,b0=pcall(readByte, hdr)
  local ok1,b1=pcall(readByte, hdr+1)
  if not ok0 or not ok1 or b0==nil or b1==nil then return nil end
  local hv=b0|(b1<<8)
  if (hv&1)==1 then return nil end
  local lenA=(hv>>6)&0x3FF
  if lenA>0 and lenA<256 then
    local s=invReadAnsi(hdr+2, lenA)
    if s then return s end
  end
  return nil
end

-- ============================================================
-- UEngine_ensureGNames — G1R-specific with hardcoded RVA
-- ============================================================
function UEngine_ensureGNames()
  local g=rawget(_G,'GNamesBase') or UEngine.GNamesBase
  local function valid(base)
    if not base or base==0 then return false end
    local b0=readPointer(base+0x10)
    if not b0 or b0==0 then return false end
    return invParseFNameEntry(b0)=='None'
  end
  if valid(g) then
    UEngine.GNamesBase=g
    _G.GNamesBase=g
    return g
  end
  local base=getAddress('G1R-Win64-Shipping.exe')
  if base then
    local cand=base+UEngine.Inv.GNAMES_RVA
    if valid(cand) then
      UEngine.GNamesBase=cand
      _G.GNamesBase=cand
      pcall(function() registerSymbol('GNames', cand, true) end)
      log(string.format('UEngine_ensureGNames: 0x%X (exe+0x%X)', cand, UEngine.Inv.GNAMES_RVA))
      return cand
    end
  end
  if UEngine.NamePoolData and valid(UEngine.NamePoolData) then
    UEngine.GNamesBase=UEngine.NamePoolData
    _G.GNamesBase=UEngine.NamePoolData
    return UEngine.NamePoolData
  end
  return nil
end

-- ============================================================
-- UEngine_classifyItemName — Gothic item prefix classification
-- ============================================================
function UEngine_classifyItemName(name)
  if not name or name=='' or name=='?' then
    return {tab='Unknown', sub='Other', short=name or '?', display=name or '?', label=name or '?'}
  end
  local pref, rest=name:match('^(It%a%a)_(.+)$')
  if not pref then pref, rest=name:match('^([A-Za-z]+)_(.+)$') end
  local short=UEngine_itemShortName(name)
  if not pref then
    local pretty=UEngine_itemPrettyName(short)
    return {tab='Unknown', sub='Other', short=short, display=pretty, label=pretty}
  end
  local tok={}
  for t in (rest or short or ''):gmatch('[^_]+') do tok[#tok+1]=t end
  local low=name:lower()
  local function has(n)
    n=n:lower()
    for _,t in ipairs(tok) do if t:lower():find(n,1,true) then return true end end
    return false
  end
  local tab, sub='Unknown', 'Other'
  if low:find('armor',1,true) or pref=='Vlk' or pref=='Stt' or pref=='Kdf' or pref=='Ryl'
    or pref=='Sld' or pref=='Org' or pref=='Grd' or pref=='Nov' or pref=='Tpl' then
    tab, sub='Wearables', 'Armor'
  elseif pref=='HumanFist' or low:find('humanfist',1,true) then
    tab, sub='Hidden', 'Unarmed'
  elseif pref=='ItMw' then
    tab='Melee'
    if has('orc') or has('krush') then sub='Orc Weapon'
    elseif tok[1]=='1H' and has('sword') then sub='One-Handed Sword'
    elseif tok[1]=='1H' and (has('mace') or has('club')) then sub='One-Handed Mace'
    elseif tok[1]=='2H' and has('sword') then sub='Two-Handed Sword'
    elseif tok[1]=='2H' and (has('axe') or has('pickaxe')) then sub='Two-Handed Axe'
    elseif tok[1]=='1H' then sub='One-Handed'
    elseif tok[1]=='2H' then sub='Two-Handed'
    else sub='Other Melee' end
  elseif pref=='ItRw' then
    tab='Ranged'
    if has('quiver') then sub='Quiver'
    elseif has('cross') then sub='Crossbow'
    elseif has('bow') then sub='Bow'
    else sub='Other Ranged' end
  elseif pref=='ItAm' then
    tab, sub='Ranged', 'Ammo'
  elseif pref=='ItAr' then
    tab='Magic'
    if tok[1]=='Rune' then sub='Rune'
    elseif tok[1]=='Scroll' then sub='Scroll'
    else sub='Other Magic' end
  elseif pref=='ItAt' then
    if tok[1]=='Ring' then tab, sub='Wearables', 'Ring'
    elseif tok[1]=='Amulet' then tab, sub='Wearables', 'Amulet'
    else tab, sub='Materials', 'Trophy' end
  elseif pref=='ItFo' then
    if tok[1]=='Potion' then
      tab='Potions'
      if has('mana') then sub='Mana'
      elseif has('health') or has('hp') or has('essence') then sub='Health'
      elseif has('speed') or has('haste') then sub='Buff'
      else sub='Potion' end
    elseif tok[1]=='Plants' then tab, sub='Food', 'Herb'
    elseif has('joint') or has('swamp') then tab, sub='Food', 'Drug'
    elseif has('meat') or has('ham') or has('sausage') or has('cheese') or has('bread') then
      tab, sub='Food', 'Food'
    elseif has('beer') or has('wine') or has('water') or has('booze') then
      tab, sub='Food', 'Drink'
    else tab, sub='Food', 'Food' end
  elseif pref=='ItMi' then
    if has('joint') then tab, sub='Food', 'Drug'
    elseif low:find('orenugget',1,true) or has('ore') then tab, sub='Materials', 'Ore'
    elseif tok[1]=='Smith' or tok[1]=='Alchemy' or has('sulfur') or has('quartz')
      or has('coal') or has('flask') then
      tab, sub='Materials', 'Material'
    elseif has('gold') or has('nugget') then tab, sub='Materials', 'Ore'
    else tab, sub='Miscellaneous', 'Junk' end
  elseif pref=='ItWr' then
    tab='Documents'
    if has('map') then sub='Map'
    elseif has('book') then sub='Book'
    elseif has('letter') or has('note') then sub='Note'
    else sub='Writing' end
  elseif pref=='ItKe' then tab, sub='Artefacts', 'Key'
  elseif pref=='ItMs' then tab, sub='Artefacts', 'Quest Item'
  elseif pref=='ItRu' then tab, sub='Magic', 'Rune'
  elseif pref=='ItSc' then tab, sub='Magic', 'Scroll'
  elseif pref=='ItPo' then tab, sub='Potions', 'Potion'
  end

  local pretty=UEngine_itemPrettyName(short)
  local disp=pretty
  local real=nil
  if type(InventoryDisplay_GetTitle)=='function' then
    real=InventoryDisplay_GetTitle(name)
  elseif type(ResolveItemDisplayName)=='function' then
    real=ResolveItemDisplayName(name)
  end
  if real and real~='' then disp=real end
  local isSystem=tab=='Hidden' or low:find('humanfist',1,true)
  if isSystem then
    disp=pretty
    real=nil
  end
  if has('quiver') and not real then
    disp=UEngine_itemPrettyName(short)
  end
  if pref=='ItAm' then
    if has('arrow') or low:find('arrow',1,true) then
      short, pretty, disp='Arrow', 'Arrow', 'Arrow'
    elseif has('bolt') or low:find('bolt',1,true) then
      short, pretty, disp='Bolt', 'Bolt', 'Bolt'
    end
    real=nil
  end
  return {
    tab=tab, sub=sub or 'Other', short=short, pretty=pretty,
    display=disp, internal=name, hasRealName=(real~=nil),
    isSystem=isSystem or false,
    label=string.format('%s / %s · %s', tab, sub or 'Other', disp),
  }
end

-- ============================================================
-- Local helpers for item resolution and collection
-- ============================================================

local function nameFromItemish(p)
  if not p or p==0 or p<0x10000 then return nil end
  local n=nil
  if UEngine.UObject and UEngine.UObject.Name then
    local ok,q=pcall(readQword, p+UEngine.UObject.Name)
    if ok and q then n=UEngine_resolveFName(q&0xFFFFFFFF) end
  end
  if (not n) or n=='' or n=='None' then
    local idx=readInteger(p+0x18)
    if idx then n=UEngine_resolveFName(idx&0xFFFFFFFF) end
  end
  if not n or n=='' or n=='None' then return nil end
  local core=n:match('^Default__(.+)$') or n:match('^BP_(.+)_Visual_C$') or n:match('^BP_(.+)_C$') or n
  return core, n
end

local function collectPtrArrayItems(data, count, stride, opts)
  local out, seen={}, {}
  opts=opts or {}
  local allowVisual=opts.allowVisual
  local allowFist=opts.allowFist
  local itemOff=opts.itemOff
  local qtyOff=opts.qtyOff
  if not data or data==0 or not count or count<1 then return out end
  if count>64 then count=64 end
  stride=stride or 8
  for i=0,count-1 do
    local base=data+i*stride
    local cands={}
    if itemOff then
      cands[#cands+1]=readPointer(base+itemOff)
    else
      cands[#cands+1]=readPointer(base)
      cands[#cands+1]=readPointer(base+8)
    end
    for _,p in ipairs(cands) do
      if p and p~=0 and p>0x10000 and not seen[p] then
        local core, raw=nameFromItemish(p)
        if core then
          local ok=core:match('^It%a%a_')
            or (allowFist and core:find('Fist',1,true))
            or (allowVisual and raw and raw:find('Visual',1,true))
          if ok then
            seen[p]=true
            local qty=1
            if qtyOff then
              local q=readInteger(base+qtyOff)
              if q and q>0 and q<100000 then qty=q end
            end
            out[#out+1]={
              slot=i, item=p, name=core, rawName=raw, ptrAddr=base,
              qty=qty, entryBase=base, stride=stride,
            }
            break
          end
        end
      end
    end
  end
  return out
end

local function unionEquipArrayParse(data, count, maxc)
  if not data or data==0 then return {}, 8, 0 end
  local n=count or 0
  if maxc and maxc>n and maxc<=24 then n=maxc end
  if n<1 then n=8 end
  if n>24 then n=24 end
  local strides={8, 0x10, 0x18, 0x20, 0x28, 0xB8}
  if UEngine.Inv and UEngine.Inv.EQUIP_STRIDE then
    strides={UEngine.Inv.EQUIP_STRIDE}
  end
  local byName={}
  local bestSt, bestN=8, 0
  local perStride={}
  for _,st in ipairs(strides) do
    local rows=collectPtrArrayItems(data, n, st, {allowFist=false})
    if st>=0x18 then
      local bagLike=collectPtrArrayItems(data, n, st, {
        itemOff=0x08, qtyOff=0x10, allowFist=false,
      })
      if #bagLike>#rows then rows=bagLike end
    end
    perStride[st]=#rows
    if #rows>bestN then bestN=#rows; bestSt=st end
    for _,e in ipairs(rows) do
      local prev=byName[e.name]
      if not prev then
        byName[e.name]=e
      else
        local prefer=(e.slot or 99)<(prev.slot or 99)
          or ((e.qty or 1)>(prev.qty or 1) and (e.slot or 0)==(prev.slot or 0))
        if prefer then byName[e.name]=e end
      end
    end
  end
  local list={}
  for _,e in pairs(byName) do list[#list+1]=e end
  table.sort(list, function(a,b) return (a.slot or 0)<(b.slot or 0) end)
  return list, bestSt, #list, perStride
end

-- ============================================================
-- Inventory snapshot functions
-- ============================================================

function UEngine_snapshotEquipped(charPtr, manager, invMgr)
  local I=UEngine.Inv or {}
  local equipArr=I.EQUIP_ARR or 0x158
  local equipCnt=I.EQUIP_CNT or 0x160
  local cdoArr=I.EQUIP_CDO_ARR or 0x180
  local cdoCnt=I.EQUIP_CDO_CNT or 0x188
  local children=I.CHILDREN or 0x190
  local childrenCnt=I.CHILDREN_CNT or 0x198
  local byName, list, fp={}, {}, {}
  local showSystem=I.showSystemItems==true

  local function pushRow(e, source, kind)
    if not e or not e.name then return end
    local ui=UEngine_classifyItemName(e.name)
    if ui.isSystem and not showSystem then return end
    if byName[e.name] then return end
    byName[e.name]=true
    local slot=e.slot
    local disp=ui.display or ui.pretty or e.name
    local sub=ui.tab or 'Other'
    if kind=='visual' and (not ui.tab or ui.tab=='Unknown') then
      sub='Visual'
    end
    local row={
      slot=slot, item=e.item, name=e.name, rawName=e.rawName,
      source=source, qty=e.qty or 1,
      tab='Equipped',
      sub=sub,
      display=disp, short=ui.short, pretty=ui.pretty,
      hasRealName=ui.hasRealName, isSystem=ui.isSystem,
      ptrAddr=e.ptrAddr, entryBase=e.entryBase, stride=e.stride,
      equipKind=kind or 'logical',
      equipped=true,
    }
    list[#list+1]=row
    fp[#fp+1]=string.format('E%d:%s:%X', slot or -1, e.name, e.item or 0)
  end

  local equipMeta={stride=nil, count=0, data=0}
  if invMgr and invMgr~=0 then
    local data=readPointer(invMgr+equipArr)
    local cnt=readInteger(invMgr+equipCnt) or 0
    local maxc=readInteger(invMgr+equipCnt+4)
    equipMeta.data=data or 0
    equipMeta.count=cnt
    equipMeta.max=maxc
    if data and data~=0 then
      local rows, st, n, per=unionEquipArrayParse(data, cnt, maxc)
      equipMeta.stride=st
      equipMeta.hits=n
      equipMeta.perStride=per
      UEngine.Inv._equipParse={
        data=data, count=cnt, max=maxc, stride=st, hits=n, perStride=per,
      }
      for _,e in ipairs(rows) do
        pushRow(e, string.format('InvMgr+0x158/st%X', e.stride or st), 'live')
      end
    end
  end

  if manager and manager~=0 then
    local data=readPointer(manager+cdoArr)
    local cnt=readInteger(manager+cdoCnt) or 0
    local maxc=readInteger(manager+cdoCnt+4)
    local n=cnt
    if maxc and maxc>n and maxc<=24 then n=maxc end
    if data and n and n>0 then
      local rows=collectPtrArrayItems(data, n, 8, {allowFist=false})
      if #rows<2 then
        local r2=collectPtrArrayItems(data, n, 0x10, {allowFist=false})
        for _,e in ipairs(r2) do rows[#rows+1]=e end
      end
      for _,e in ipairs(rows) do
        pushRow(e, 'Mgr+0x180', 'cdo')
      end
    end
  end

  if charPtr and charPtr~=0 then
    local data=readPointer(charPtr+children)
    local cnt=readInteger(charPtr+childrenCnt) or 0
    if data and cnt and cnt>0 then
      local vis=collectPtrArrayItems(data, cnt, 8, {allowVisual=true, allowFist=false})
      for _,e in ipairs(vis) do
        local isVis=e.rawName and e.rawName:find('Visual',1,true)
        if isVis or (e.name and e.name:match('^It%a%a_')) then
          pushRow(e, 'Children+0x190', 'visual')
        end
      end
    end
  end

  table.sort(list, function(a,b)
    local ka=(a.equipKind=='live' and 0) or (a.equipKind=='cdo' and 1) or 2
    local kb=(b.equipKind=='live' and 0) or (b.equipKind=='cdo' and 1) or 2
    if ka~=kb then return ka<kb end
    local sa, sb=a.slot or 999, b.slot or 999
    if sa~=sb then return sa<sb end
    return tostring(a.display)<tostring(b.display)
  end)
  return list, table.concat(fp, '|'), equipMeta
end

function UEngine_snapshotInventory()
  local charPtr, err, charChain=UEngine_findCharacter()
  if not charPtr then return nil, err or 'no character' end
  local gnames=UEngine_ensureGNames()
  local I=UEngine.Inv
  local invChain={}
  if type(charChain)=='table' then
    for _,v in ipairs(charChain) do invChain[#invChain+1]=v end
  end
  invChain[#invChain+1]=I.MANAGER
  invChain[#invChain+1]=I.CONTAINER
  invChain[#invChain+1]=I.INVMGR
  invChain[#invChain+1]=I.ARRAY
  UEngine.Inv.qtyChain=invChain

  local manager=readPointer(charPtr+I.MANAGER)
  if not manager or manager==0 then return nil, 'no manager (+0x7B0)' end
  local container=readPointer(manager+I.CONTAINER)
  local invMgr=container and readPointer(container+I.INVMGR)
  local arrayBase=invMgr and readPointer(invMgr+I.ARRAY)
  local packed=invMgr and readQword(invMgr+I.COUNT)
  if not arrayBase or arrayBase==0 then return nil, 'no inv array' end
  local count=packed and (packed&0xFFFFFFFF) or 383
  if count>2000 then count=383 end
  local items, fpParts={}, {}
  local showSystem=I.showSystemItems==true
  for slot=0,count-1 do
    local entry=arrayBase+slot*I.STRIDE
    local item=readPointer(entry+I.ITEM)
    if item and item~=0 and item>0x10000 then
      local qty=readInteger(entry+I.QTY) or 0
      local idx=readInteger(item+I.NAMEIDX) or 0
      local iname=UEngine_resolveFName(idx) or '?'
      local ui=UEngine_classifyItemName(iname)
      if ui.isSystem and not showSystem then
        fpParts[#fpParts+1]=string.format('S%d:%X', slot, idx)
      else
        items[#items+1]={
          slot=slot, qty=qty, idx=idx, name=iname, item=item, entry=entry,
          tab=ui.tab, sub=ui.sub, display=ui.display, label=ui.label,
          short=ui.short, pretty=ui.pretty, hasRealName=ui.hasRealName,
          isSystem=ui.isSystem,
          qtyFinalOff=slot*I.STRIDE+I.QTY, equipped=false,
        }
        fpParts[#fpParts+1]=string.format('%d:%X:%X', slot, item, idx)
      end
    end
  end

  local eqList, eqFp, eqMeta=UEngine_snapshotEquipped(charPtr, manager, invMgr)
  UEngine.Inv._lastEquipMeta=eqMeta
  for _,e in ipairs(eqList) do
    e.equipped=true
    items[#items+1]=e
  end
  if eqFp and eqFp~='' then fpParts[#fpParts+1]=eqFp end

  table.sort(items, function(a,b)
    local at, bt=a.tab or '', b.tab or ''
    if at=='Equipped' and bt~='Equipped' then return true end
    if bt=='Equipped' and at~='Equipped' then return false end
    if at~=bt then return at<bt end
    if a.equipped and b.equipped then
      local sa, sb=a.slot or 999, b.slot or 999
      if sa~=sb then return sa<sb end
    end
    if a.sub~=b.sub then return tostring(a.sub)<tostring(b.sub) end
    return (a.display or a.name)<(b.display or b.name)
  end)
  return items, table.concat(fpParts, '|'), arrayBase, count
end

-- ============================================================
-- Address list helpers
-- ============================================================

local function invNormDesc(d)
  d=tostring(d or '')
  d=d:gsub('%s*%(%d+%s*bag%s*%+%s*%d+%s*equipped%)%s*$','')
  d=d:gsub('%s*%(%d+%)%s*$','')
  return d
end

local function mrGetCollapsed(mr)
  if not mr then return nil end
  local ok,v=pcall(function() return mr.Collapsed end)
  if ok and type(v)=='boolean' then return v end
  return nil
end

local function mrSetCollapsed(mr, collapsed)
  if not mr or collapsed==nil then return end
  pcall(function() mr.Collapsed=collapsed end)
end

local function captureExpandState(root)
  local state={}
  if not root or not UEngine_mrLooksAlive(root) then return state end
  local function walk(mr, path)
    if not mr then return end
    local desc=invNormDesc(mr.Description)
    local p=(path=='') and desc or (path..'/'..desc)
    local hasKids=(mr.Count or 0)>0
    local isGroup=false
    pcall(function() isGroup=mr.IsGroupHeader and true or false end)
    if isGroup or hasKids then
      local c=mrGetCollapsed(mr)
      if c~=nil then state[p]=c end
      for i=0,(mr.Count or 0)-1 do
        local ch=nil
        pcall(function() ch=mr.Child[i] end)
        if ch then walk(ch, p) end
      end
    end
  end
  walk(root, '')
  return state
end

local function restoreExpandState(root, state)
  if not root or not state or not next(state) then return false end
  local restored=0
  local function walk(mr, path)
    if not mr then return end
    local desc=invNormDesc(mr.Description)
    local p=(path=='') and desc or (path..'/'..desc)
    local hasKids=(mr.Count or 0)>0
    local isGroup=false
    pcall(function() isGroup=mr.IsGroupHeader and true or false end)
    if isGroup or hasKids then
      if state[p]~=nil then
        mrSetCollapsed(mr, state[p])
        restored=restored+1
      end
      for i=0,(mr.Count or 0)-1 do
        local ch=nil
        pcall(function() ch=mr.Child[i] end)
        if ch then walk(ch, p) end
      end
    end
  end
  walk(root, '')
  return restored>0
end

local function destroyInvTree()
  local root=UEngine.Inv.rootMR
  if root and UEngine_mrLooksAlive(root) then
    UEngine.Inv._expandState=captureExpandState(root)
  end
  UEngine.Inv.rootMR=nil
  if not root then return end
  UEngine_mrDelete(root)
end

local TAB_ORDER={
  'Equipped','Melee','Ranged','Magic','Wearables','Food','Potions',
  'Materials','Documents','Miscellaneous','Artefacts','Hidden','Unknown',
}

function UEngine_buildInventoryAddressList(items)
  local fl=getAddressList()
  destroyInvTree()
  local expandState=UEngine.Inv._expandState

  local nBag, nEq=0, 0
  if items then
    for _,it in ipairs(items) do
      if it.equipped or it.tab=='Equipped' then nEq=nEq+1 else nBag=nBag+1 end
    end
  end

  local root=fl.createMemoryRecord()
  root.Description=string.format('Inventory (%d bag + %d equipped)', nBag, nEq)
  root.IsGroupHeader=true
  root.Options='[moHideChildren,moAllowManualCollapseAndExpand,moManualExpandCollapse]'
  UEngine.Inv.rootMR=root

  if not items or #items==0 then
    if expandState then restoreExpandState(root, expandState) end
    return root
  end

  local GRP='[moHideChildren,moAllowManualCollapseAndExpand,moManualExpandCollapse]'
  local tabMR={}
  local subMR={}
  local tabCount={}
  local subCount={}

  local function ensureTab(tab)
    tab=tab or 'Unknown'
    if tabMR[tab] then return tabMR[tab] end
    local mr=fl.createMemoryRecord()
    mr.Description=tab
    mr.IsGroupHeader=true
    mr.Parent=root
    mr.Options=GRP
    tabMR[tab]=mr
    tabCount[tab]=0
    return mr
  end

  local function ensureSub(tab, sub)
    tab=tab or 'Unknown'
    sub=sub or 'Other'
    local key=tab..'\0'..sub
    if subMR[key] then return subMR[key] end
    local parent=ensureTab(tab)
    local mr=fl.createMemoryRecord()
    mr.Description=sub
    mr.IsGroupHeader=true
    mr.Parent=parent
    mr.Options=GRP
    subMR[key]=mr
    subCount[key]=0
    return mr
  end

  for _,it in ipairs(items) do
    if it.equipped or it.tab=='Equipped' then ensureTab('Equipped'); break end
  end

  local chain=UEngine.Inv.qtyChain
  local useChain=type(chain)=='table' and #chain>=2

  for _,it in ipairs(items) do
    local tab=it.tab or 'Unknown'
    local sub=it.sub or 'Other'
    local parent=ensureSub(tab, sub)
    local mr=fl.createMemoryRecord()

    local short=it.short or (it.name and UEngine_itemShortName(it.name)) or it.name or '?'
    local pretty=it.pretty or UEngine_itemPrettyName(short)
    local disp=it.display or pretty
    local slotTag=''
    if it.equipped and it.slot~=nil then
      slotTag=string.format('(%d) ', it.slot)
    end
    if it.equipped then
      local kind=it.equipKind
      local src=''
      if kind=='visual' then src=' [visual]'
      elseif kind=='cdo' then src=' [CDO]'
      end
      if it.hasRealName and disp and pretty and disp~=pretty then
        mr.Description=string.format('%s%s  [%s]%s', slotTag, disp, pretty, src)
      else
        mr.Description=string.format('%s%s%s', slotTag, tostring(disp or pretty or short), src)
      end
      if it.qty and it.qty>1 then
        mr.Description=mr.Description..string.format(' x%d', it.qty)
      end
    elseif it.hasRealName and disp and short and disp~=short and disp~=pretty then
      mr.Description=string.format('%s  [%s]', disp, pretty)
    else
      mr.Description=tostring(disp or pretty or short)
    end

    if it.equipped then
      if it.qty and it.qty>0 and it.entryBase and it.equipKind=='live' then
        local qaddr=nil
        if it.stride and it.stride>=0x18 then
          qaddr=it.entryBase+0x10
          local q=readInteger(qaddr)
          if q and q>0 and q<100000 then
            mr.VarType=vtDword
            mr.Address=string.format('%X', qaddr)
          end
        end
        if not mr.Address or mr.Address=='' then
          mr.VarType=vtPointer
          if it.ptrAddr then mr.Address=string.format('%X', it.ptrAddr)
          elseif it.item then mr.Address=string.format('%X', it.item) end
        end
      else
        mr.VarType=vtPointer
        if it.ptrAddr then
          mr.Address=string.format('%X', it.ptrAddr)
        elseif it.item then
          mr.Address=string.format('%X', it.item)
        end
      end
    else
      mr.VarType=vtDword
      if useChain and it.qtyFinalOff then
        pcall(function()
          UEngine_setChainAddress(mr, 'GEngine', chain, it.qtyFinalOff)
        end)
      end
      if not mr.Address or mr.Address=='' then
        if it.entry then
          mr.Address=string.format('%X', it.entry+UEngine.Inv.QTY)
        end
      end
    end
    mr.Parent=parent
    tabCount[tab]=(tabCount[tab] or 0)+1
    local key=tab..'\0'..sub
    subCount[key]=(subCount[key] or 0)+1
  end

  for tab,mr in pairs(tabMR) do
    mr.Description=string.format('%s (%d)', tab, tabCount[tab] or 0)
  end
  for key,mr in pairs(subMR) do
    local sub=key:match('\0(.+)$') or key
    mr.Description=string.format('%s (%d)', sub, subCount[key] or 0)
  end

  root.Description=string.format('Inventory (%d bag + %d equipped)', nBag, nEq)

  if expandState and next(expandState) then
    local okRest=restoreExpandState(root, expandState)
    if not okRest then
      local rootKey=invNormDesc(root.Description)
      for k,col in pairs(expandState) do
        if not col and (k=='Inventory' or k:match('^Inventory')) then
          mrSetCollapsed(root, false)
          break
        end
      end
    end
  end
  return root
end

function UEngine_refreshInventoryAddressList(force)
  local okSnap, items, fp=pcall(UEngine_snapshotInventory)
  if not okSnap then
    if force then log('Inventory snapshot error: '..tostring(items)) end
    return false, tostring(items)
  end
  if not items then
    if force then log('Inventory refresh failed: '..tostring(fp)) end
    return false, tostring(fp)
  end

  if (not force) and UEngine.Inv.lastFp==fp and UEngine.Inv.rootMR
    and UEngine_mrLooksAlive(UEngine.Inv.rootMR) then
    return true
  end

  if UEngine.Inv.rootMR and UEngine_mrLooksAlive(UEngine.Inv.rootMR) then
    UEngine.Inv._expandState=captureExpandState(UEngine.Inv.rootMR)
  end

  local okBuild, errBuild=pcall(UEngine_buildInventoryAddressList, items)
  if not okBuild then
    if force then log('Inventory build error: '..tostring(errBuild)) end
    return false, tostring(errBuild)
  end
  UEngine.Inv.lastFp=fp
  _G.InventoryNamed=items
  if force then
    log(string.format('Inventory address list: %d items (GNames=%s)',
      #items, UEngine.GNamesBase and string.format('0x%X',UEngine.GNamesBase) or 'nil'))
  end
  return true
end

function UEngine_addInventoryToAddressList()
  local ok, err=UEngine_refreshInventoryAddressList(true)
  if not ok then
    log('Add Inventory failed: '..tostring(err))
    if showMessage then
      pcall(showMessage, 'Add Inventory failed:\n'..tostring(err or 'unknown')
        ..'\n\nEnsure Unreal Engine finished initializing and you are in-game.')
    end
  end
  return ok
end

function UEngine_setInventoryLiveTracking(enabled)
  if UEngine.Inv.liveTimer then
    pcall(function() UEngine.Inv.liveTimer.destroy() end)
    UEngine.Inv.liveTimer=nil
  end
  if not enabled then return end
  UEngine.Inv.liveTimer=createTimer(MainForm, false)
  local t=UEngine.Inv.liveTimer
  t.Interval=2000
  t.OnTimer=function()
    local ok=pcall(function()
      if UEngine_mrLooksAlive(UEngine.Inv.rootMR) then
        UEngine_refreshInventoryAddressList(false)
      else
        UEngine_refreshInventoryAddressList(true)
      end
    end)
    if not ok then
      pcall(function() UEngine.Inv.liveTimer.destroy() end)
      UEngine.Inv.liveTimer=nil
    end
  end
  t.Enabled=true
end

-- ============================================================
-- Display helper management (inventory_display_helper.lua)
-- ============================================================

function UEngine_displayHelperPaths()
  local helperPaths={}
  pcall(function()
    local src=debug.getinfo(1,'S').source
    if src and src:sub(1,1)=='@' then
      local dir=src:sub(2):match('^(.*)[/\\]')
      if dir then
        helperPaths[#helperPaths+1]=dir..'/inventory_display_helper.lua'
        helperPaths[#helperPaths+1]=dir..'\\inventory_display_helper.lua'
      end
    end
  end)
  return helperPaths
end

function UEngine_loadDisplayHelper()
  if type(InventoryDisplay_InitFromNs)=='function' or type(InventoryDisplay_Init)=='function' then
    return true, 'already loaded'
  end
  local loadErr='not found'
  for _,p in ipairs(UEngine_displayHelperPaths()) do
    local ok,err=pcall(function() dofile(p) end)
    if ok and (type(InventoryDisplay_InitFromNs)=='function' or type(InventoryDisplay_Init)=='function') then
      log('Loaded display helper: '..p)
      return true, p
    end
    if not ok then loadErr=tostring(err) end
  end
  return false, loadErr
end

function UEngine_lookupRealItemNamesAsync()
  if type(InventoryDisplay_IsReady)=='function' and InventoryDisplay_IsReady() then
    UEngine_refreshInventoryAddressList(true)
    log('Real names already loaded — inventory refreshed (0 AOB).')
    return
  end
  createThread(function(th)
    th.Priority='tpIdle'
    local loaded, loadInfo=UEngine_loadDisplayHelper()
    local okInit, nTitles=false, 0
    local method='?'
    if loaded then
      local m=rawget(_G,'AlkimiaLocMap')
      if type(m)=='table' then
        local n=0
        for _ in pairs(m) do n=n+1; if n>100 then break end end
        if n>0 and n<=100 then _G.AlkimiaLocMap=nil; _G.AlkimiaFuzzy=nil end
      end
      local ns=rawget(_G,'AlkimiaNs')
      local entry=rawget(_G,'BP_FText') or rawget(_G,'BP_Obj')
      if type(InventoryDisplay_InitFromNs)=='function' and ns and ns~=0 then
        local ok,n=InventoryDisplay_InitFromNs(ns)
        okInit, nTitles, method=ok and true or false, n or 0, 'InitFromNs'
      elseif type(InventoryDisplay_InitFromEntry)=='function' and entry then
        local ok,n=InventoryDisplay_InitFromEntry(entry)
        okInit, nTitles, method=ok and true or false, n or 0, 'InitFromEntry'
      elseif type(InventoryDisplay_Init)=='function' then
        local ok,n=InventoryDisplay_Init()
        okInit, nTitles, method=ok and true or false, n or 0, 'Init'
      end
    end
    synchronize(function()
      if okInit then
        UEngine_refreshInventoryAddressList(true)
        log(string.format(
          'Real item names: %s titles=%s method=%s — refresh done. (Open inv once before first Lookup if Init fails.)',
          tostring(nTitles), tostring(nTitles), method))
      else
        log('Real name lookup failed. Load helper via dofile then Lookup again. Paths tried under Scripts/g1r/ subfolder  ('..tostring(loadInfo)..')')
      end
    end)
  end)
end

function UEngine_logInventorySessionChecklist()
  log('Inventory session: 1) Attach game  2) Open inv in-game once  3) Lookup real item names  4) Add/Refresh Inventory  5) optional Live track')
  if type(InventoryDisplay_IsReady)=='function' and InventoryDisplay_IsReady() then
    log('  Loc map: ready')
  else
    log('  Loc map: not ready — use menu Lookup real item names (or dofile helper + InitFromNs)')
  end
  local em=UEngine.Inv and UEngine.Inv._equipParse
  if em then
    log(string.format('  Equip parse: InvMgr+0x158 data=0x%X count=%s stride=0x%X hits=%s',
      em.data or 0, tostring(em.count), em.stride or 0, tostring(em.hits)))
  end
end

-- ============================================================
-- Plugin registration
-- ============================================================
if type(UEngine_registerPlugin) == 'function' then
  UEngine_registerPlugin('Gothic 1 Remake', function(parentMenu)
    local miAddInv=UE_newMenuItem('Add / Refresh Inventory Items')
    miAddInv.OnClick=function()
      UEngine_runWhenReady(function()
        if not UEngine.Inv._checklistLogged then
          UEngine_logInventorySessionChecklist()
          UEngine.Inv._checklistLogged=true
        end
        UEngine_addInventoryToAddressList()
      end)
    end
    parentMenu.add(miAddInv)

    local miLive=UE_newMenuItem('Live track inventory changes')
    miLive.AutoCheck=true
    miLive.Checked=false
    miLive.OnClick=function()
      local want=miLive.Checked
      if not want then
        UEngine_setInventoryLiveTracking(false)
        return
      end
      UEngine_runWhenReady(function()
        miLive.Checked=true
        UEngine_setInventoryLiveTracking(true)
      end)
    end
    parentMenu.add(miLive)

    local miRealNames=UE_newMenuItem('Lookup real item names (once, background)')
    miRealNames.OnClick=function()
      UEngine_runWhenReady(function() UEngine_lookupRealItemNamesAsync() end)
    end
    parentMenu.add(miRealNames)

    local miChecklist=UE_newMenuItem('Inventory session checklist (log)')
    miChecklist.OnClick=function()
      UEngine_logInventorySessionChecklist()
    end
    parentMenu.add(miChecklist)

    local miSep=UE_newMenuItem('-')
    parentMenu.add(miSep)

    local debugMenu=UE_newMenuItem('Debug')
    local miFindInv=UE_newMenuItem('Find Inventory Properties')
    miFindInv.OnClick=function()
      UEngine_runWhenReady(function()
        createThread(function()
          UEngine_searchCharacterProperties()
        end)
      end)
    end
    debugMenu.add(miFindInv)
    parentMenu.add(debugMenu)
  end)
end
