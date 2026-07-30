-- inventory_display_helper.lua
-- ONE-SHOT init + O(1) lookups for inventory display names.
--
-- Call after game attach + UnrealEngine-75.LUA is loaded (e.g. after LaunchUEInfoScanner):
--   dofile([[.../inventory_display_helper.lua]])
--   InventoryDisplay_Init()     -- may do ≤2 AOBs once
--
-- ON INVENTORY UI OPEN (must be instant — no scans):
--   local title = InventoryDisplay_GetTitle("ItFo_Apple")  -- "Apple" or nil
--   local title = InventoryDisplay_GetTitleFromItem(itemPtr)
--
-- NEVER scan inside a per-slot loop. If map missing, show internal FName only.
--
-- Localization layout (researched):
--   internal FName (GNames, item+0x18)
--     → loc key = lower(FName)   e.g. itfo_apple
--     → FText-like entry in heap:
--          +0x00 → UTF-16 title
--          +0x08 len, max
--          +0x10 → "AlkimiaLocalization"  (Alkimia = developer)
--          +0x18 → UTF-16 loc key
--          +0x30 → shared helper vtable  exe+0x7569B78 (build-specific)
--
-- Bridge options (preference order):
--   1) Cached _G.AlkimiaLocMap from prior Init (0 AOB)     ← use this at runtime
--   2) Init: 2× AOB (+W) build map once per session
--   3) Future: find FTextLocalizationManager / property on def (no AOB)
--   4) Avoid: inject code / per-item AOB / scan on every inventory open

local M = {}

local MAX_AOB = 2
-- Full ns-ptr AOB can return 40k+ hits; capping at 20k drops late entries (e.g. Teleport).
local MAX_REFS = 60000

local function rqw(a)
    if not a or a == 0 then return nil end
    local ok, v = pcall(readQword, a)
    return ok and v or nil
end
local function rdi(a)
    if not a or a == 0 then return nil end
    local ok, v = pcall(readInteger, a)
    return ok and v or nil
end
local function rby(a)
    if not a or a == 0 then return nil end
    local ok, v = pcall(readByte, a)
    return ok and v or nil
end
local function isHeap(p) return p and p > 0x100000 and p < 0x7FFFFFFFFFF end

local function readUtf16z(addr, maxChars)
    if not addr then return nil end
    maxChars = maxChars or 120
    local t = {}
    for i = 0, maxChars - 1 do
        local lo, hi = rby(addr + i * 2), rby(addr + i * 2 + 1)
        if not lo or not hi or (lo == 0 and hi == 0) then break end
        if hi == 0 and lo >= 32 and lo < 127 then t[#t + 1] = string.char(lo)
        elseif hi == 0 then t[#t + 1] = "?"
        else break end
    end
    return #t > 0 and table.concat(t) or nil
end

local function readAnsi(addr, len)
    if not addr or not len or len < 1 or len > 256 then return nil end
    local t = {}
    for i = 0, len - 1 do
        local b = rby(addr + i)
        if not b or b < 32 or b > 126 then return nil end
        t[#t + 1] = string.char(b)
    end
    return table.concat(t)
end

local function parseEntry(hdr)
    local b0, b1 = rby(hdr), rby(hdr + 1)
    if not b0 or not b1 then return nil end
    local hv = b0 | (b1 << 8)
    if (hv & 1) == 1 then return nil end
    local lenA = (hv >> 6) & 0x3FF
    if lenA > 0 and lenA < 256 then
        local s = readAnsi(hdr + 2, lenA)
        if s then return s end
    end
    return nil
end

local function validateGNames(base)
    if not base or base == 0 then return false end
    local b0 = rqw(base + 0x10)
    if not b0 then return false end
    return parseEntry(b0) == "None"
end

local function resolveFName(gnames, idx)
    if not gnames or not idx then return nil end
    idx = idx & 0xFFFFFFFF
    local bp = rqw(gnames + 0x10 + (idx >> 16) * 8)
    if not bp then return nil end
    return parseEntry(bp + (idx & 0xFFFF) * 2)
end

local function utf16Aob(s)
    local p = {}
    for i = 1, #s do p[#p + 1] = string.format("%02X 00", s:byte(i)) end
    return table.concat(p, " ")
end

local function ptrPat(addr)
    return string.format("%02X %02X %02X %02X %02X %02X %02X %02X",
        addr & 0xFF, (addr >> 8) & 0xFF, (addr >> 16) & 0xFF, (addr >> 24) & 0xFF,
        (addr >> 32) & 0xFF, (addr >> 40) & 0xFF, (addr >> 48) & 0xFF, (addr >> 56) & 0xFF)
end

local function aobOnce(pattern, prot, label, budget)
    budget.n = budget.n + 1
    if budget.n > MAX_AOB then
        print(string.format("[InventoryDisplay] REFUSED AOB '%s' (budget)", label))
        return nil
    end
    print(string.format("[InventoryDisplay] AOB %d/%d %s ...", budget.n, MAX_AOB, label))
    local ok, fl = pcall(AOBScan, pattern, prot or "+W")
    if not ok or not fl then return {} end
    local hits, n = {}, fl.Count or 0
    local lim = math.min(n, MAX_REFS)
    for i = 0, lim - 1 do
        local s = fl[i]
        if s then
            local a = tonumber("0x" .. tostring(s))
            if a then hits[#hits + 1] = a end
        end
    end
    pcall(function() fl.destroy() end)
    print(string.format("[InventoryDisplay]   hits=%d used=%d", n, #hits))
    return hits
end

local function buildFuzzy(locMap)
    local fz = {}
    for k, v in pairs(locMap) do
        if not k:find("_description", 1, true) then
            fz[k] = v
            local c = k:gsub("_", "")
            if not fz["c:" .. c] then fz["c:" .. c] = v end
        end
    end
    return fz
end

local function lookup(locMap, fuzzy, name)
    if not name or not locMap then return nil end
    local low = name:lower()
    local candidates = { low }
    if low:sub(1, 5) == "itar_" then candidates[#candidates + 1] = low:sub(6) end
    for _, k in ipairs(candidates) do
        local e = locMap[k]
        if e and e.title then return e.title, k end
    end
    local compact = low:gsub("_", "")
    local e = fuzzy and fuzzy["c:" .. compact]
    if e and e.title then return e.title, e.key end
    if #compact >= 14 then
        local tail = #compact > 36 and compact:sub(-36) or compact
        for k, v in pairs(locMap) do
            if not k:find("_description", 1, true) then
                local kc = k:gsub("_", "")
                if kc:find(tail, 1, true) or tail:find(kc, 1, true) then
                    if v.title and not v.title:lower():find("inscription", 1, true) then
                        return v.title, k
                    end
                end
            end
        end
    end
    return nil
end

--- Ensure GNames using the GNamesBase set by the plugin.
--- Does NOT compute exe+RVA itself — the plugin's UEngine_ensureGNames handles that.
function InventoryDisplay_EnsureGNames(gnamesBase)
    local g = gnamesBase or rawget(_G, "GNamesBase")
    if validateGNames(g) then
        _G.GNamesBase = g
        return g
    end
    print("[InventoryDisplay] GNames not found — call UEngine_ensureGNames first")
    return nil
end

local function parseLocEntryAt(entry, nsAddr)
    local titlePtr, keyPtr = rqw(entry), rqw(entry + 0x18)
    local nsPtr = rqw(entry + 0x10)
    if nsPtr ~= nsAddr or not isHeap(titlePtr) or not isHeap(keyPtr) then return nil end
    local len, maxc = rdi(entry + 0x08) or 0, rdi(entry + 0x0C) or 0
    if len < 1 or len > 200 or maxc < len or maxc > 400 then return nil end
    local title = readUtf16z(titlePtr, 120)
    local key = readUtf16z(keyPtr, 100)
    if not key or not title or #key < 3 then return nil end
    return {
        title = title, titlePtr = titlePtr, entry = entry, key = key,
        hash = rqw(entry + 0x20),
    }
end

local function buildMapFromNsPointerHits(nsAddr, refs)
    local locMap, locDesc = {}, {}
    local titles, descs, parsed = 0, 0, 0
    for _, ref in ipairs(refs) do
        if parsed >= MAX_REFS then break end
        -- ref is address of the qword that stores ns* → that field is entry+0x10
        local entry = ref - 0x10
        local e = parseLocEntryAt(entry, nsAddr)
        if e then
            parsed = parsed + 1
            if e.key:find("_description", 1, true) then
                local k = e.key:gsub("_description$", "")
                if not locDesc[k] then locDesc[k] = e.title; descs = descs + 1 end
            elseif not locMap[e.key] then
                locMap[e.key] = e
                titles = titles + 1
            end
        end
    end
    return locMap, locDesc, titles, descs, parsed
end

local function installMap(locMap, locDesc, titles, aobs, method)
    _G.AlkimiaLocMap = locMap
    _G.AlkimiaLocDesc = locDesc
    _G.AlkimiaFuzzy = buildFuzzy(locMap)
    _G.AlkimiaNs = rawget(_G, "AlkimiaNs")
    print(string.format("[InventoryDisplay] Init done: titles=%d AOBs=%d method=%s",
        titles, aobs or 0, method or "?"))
    return true, titles
end

--- FAST: one AOB only — pointers to known namespace string address.
--- Prefer this when you already have ns* from a seed FText entry (script 35).
function InventoryDisplay_InitFromNs(nsAddr, opts)
    opts = opts or {}
    if not nsAddr or nsAddr == 0 then
        print("[InventoryDisplay] InitFromNs: nil ns")
        return false, 0
    end
    if readUtf16z(nsAddr, 40) ~= "AlkimiaLocalization" then
        print("[InventoryDisplay] InitFromNs: ns address is not AlkimiaLocalization text")
        return false, 0
    end
    _G.AlkimiaNs = nsAddr
    print(string.format("[InventoryDisplay] InitFromNs: 1× AOB ptr→ns 0x%X ...", nsAddr))
    local budget = { n = 0 }
    local refs = aobOnce(ptrPat(nsAddr), "+W", "ftext-entries-via-ns", budget)
    if refs == nil then return false, 0 end
    local locMap, locDesc, titles, descs, parsed = buildMapFromNsPointerHits(nsAddr, refs)
    print(string.format("[InventoryDisplay] parsed=%d titles=%d descs=%d", parsed, titles, descs))
    return installMap(locMap, locDesc, titles, budget.n, "InitFromNs")
end

--- Seed from FText entry or title-bearing entry addr; then InitFromNs (1 AOB).
function InventoryDisplay_InitFromEntry(entryAddr, opts)
    if not entryAddr then return false, 0 end
    local ns = rqw(entryAddr + 0x10)
    local key = rqw(entryAddr + 0x18)
    print(string.format("[InventoryDisplay] InitFromEntry 0x%X ns=0x%X key=\"%s\"",
        entryAddr, ns or 0, (key and readUtf16z(key, 80)) or "?"))
    return InventoryDisplay_InitFromNs(ns, opts)
end

--- Build or reuse AlkimiaLocMap.
--- Optimized: if _G.AlkimiaNs or opts.ns set → 1 AOB only.
--- Else legacy: 2 AOB (find ns string, then all entry refs).
function InventoryDisplay_Init(opts)
    opts = opts or {}
    local force = opts.forceRebuild

    if not force and type(rawget(_G, "AlkimiaLocMap")) == "table" then
        local n = 0
        for _ in pairs(_G.AlkimiaLocMap) do n = n + 1 end
        if n > 100 then
            if not _G.AlkimiaFuzzy then _G.AlkimiaFuzzy = buildFuzzy(_G.AlkimiaLocMap) end
            print(string.format("[InventoryDisplay] Init: reuse map (%d keys), 0 AOB", n))
            return true, n
        end
    end

    local nsKnown = opts.ns or rawget(_G, "AlkimiaNs")
    if nsKnown and readUtf16z(nsKnown, 40) == "AlkimiaLocalization" then
        print("[InventoryDisplay] Init: using cached ns → 1 AOB path")
        return InventoryDisplay_InitFromNs(nsKnown, opts)
    end

    local entrySeed = opts.entry or rawget(_G, "BP_FText") or rawget(_G, "BP_Obj")
    if entrySeed and rqw(entrySeed + 0x10) then
        local ns = rqw(entrySeed + 0x10)
        if readUtf16z(ns, 40) == "AlkimiaLocalization" then
            print("[InventoryDisplay] Init: ns from BP_FText/entry → 1 AOB path")
            return InventoryDisplay_InitFromNs(ns, opts)
        end
    end

    local budget = { n = 0 }
    print("[InventoryDisplay] Init: building AlkimiaLocMap (legacy max 2 AOB, +W)...")

    local nsHits = aobOnce(utf16Aob("AlkimiaLocalization"), "+W", "namespace", budget)
    if nsHits == nil then return false, 0 end
    local nsAddr = nil
    for _, a in ipairs(nsHits) do
        if readUtf16z(a, 40) == "AlkimiaLocalization" then nsAddr = a; break end
    end
    if not nsAddr then
        print("[InventoryDisplay] namespace string not in +W — open inventory once in-game")
        return false, 0
    end
    _G.AlkimiaNs = nsAddr

    local refs = aobOnce(ptrPat(nsAddr), "+W", "ftext-entries", budget)
    if refs == nil then return false, 0 end

    local locMap, locDesc, titles, descs, parsed = buildMapFromNsPointerHits(nsAddr, refs)
    print(string.format("[InventoryDisplay] parsed=%d titles=%d descs=%d", parsed, titles, descs))
    return installMap(locMap, locDesc, titles, budget.n, "Init-legacy-2AOB")
end

--- O(1)-ish lookup. NEVER scans. Returns title or nil.
function InventoryDisplay_GetTitle(internalName)
    local map = rawget(_G, "AlkimiaLocMap")
    if type(map) ~= "table" then return nil end
    local fz = rawget(_G, "AlkimiaFuzzy") or buildFuzzy(map)
    return lookup(map, fz, internalName)
end

--- From item UObject pointer (needs GNamesBase). No scans.
function InventoryDisplay_GetTitleFromItem(itemPtr)
    local g = rawget(_G, "GNamesBase")
    if not itemPtr or not g then return nil end
    local idx = rdi(itemPtr + 0x18)
    local iname = resolveFName(g, idx)
    if not iname then return nil end
    local title = InventoryDisplay_GetTitle(iname)
    return title, iname
end

--- True if map is ready for UI (no init needed). Require a full catalog, not a tiny slab walk.
function InventoryDisplay_IsReady()
    local m = rawget(_G, "AlkimiaLocMap")
    if type(m) ~= "table" then return false end
    local n = 0
    for _ in pairs(m) do
        n = n + 1
        if n > 100 then return true end
    end
    return false
end

-- Also export classic names used by scripts 26/31
_G.ResolveItemDisplayName = InventoryDisplay_GetTitle
_G.InventoryDisplay_Init = InventoryDisplay_Init
_G.InventoryDisplay_InitFromNs = InventoryDisplay_InitFromNs
_G.InventoryDisplay_InitFromEntry = InventoryDisplay_InitFromEntry
_G.InventoryDisplay_EnsureGNames = InventoryDisplay_EnsureGNames
_G.InventoryDisplay_GetTitle = InventoryDisplay_GetTitle
_G.InventoryDisplay_GetTitleFromItem = InventoryDisplay_GetTitleFromItem
_G.InventoryDisplay_IsReady = InventoryDisplay_IsReady

-- If run as a script (not only dofile library), init once + optional bag report
if debug.getinfo(2, "S") == nil or true then
    -- Always define APIs; only auto-init when executed as main chunk via explicit flag
end

print("[InventoryDisplay] helper loaded. Call InventoryDisplay_Init() once per session.")
print("  Then InventoryDisplay_GetTitle(internalName) — never scans.")

return M
