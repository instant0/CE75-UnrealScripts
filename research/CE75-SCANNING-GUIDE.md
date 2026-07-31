# CE 7.5 Lua Memory Scanning Guide

**Canonical** reference for MemScan / FoundList in Cheat Engine 7.5.

Source: `/mnt/y/Lazarus/Projects/cheat-engine-7.5/Cheat Engine/`  
(`commontypedefs.pas`, `LuaMemscan.pas`, `memscan.pas`, `LuaFoundlist.pas`, `celua.txt`)

Project status → `CE75-STATUS.md`. GNames strategy → `CE75-GNAMES-PROPOSAL.md`.

---

## 1. TVariableType (CRITICAL — do not confuse with GUI dropdown indices)

From `commontypedefs.pas`:

| Value | Name | Use |
|------:|------|-----|
| 0 | `vtByte` | |
| 1 | `vtWord` | |
| 2 | `vtDword` | |
| 3 | `vtQword` | |
| 4 | `vtSingle` | float |
| 5 | `vtDouble` | |
| **6** | **`vtString`** | ANSI / code-page string |
| **7** | **`vtUnicodeString`** | UTF-16 string |
| **8** | **`vtByteArray`** | AOB / hex pattern + wildcards |
| 9 | `vtBinary` | |
| 10 | `vtAll` | |

**Common false belief (now corrected):** “string = 7, bytearray = 6”.  
That is wrong. **7 is Unicode.** Scripts that passed `7` for “string” searched UTF-16 and got **0 hits** on ANSI FName data. Scripts that passed `6` for “bytearray” ran a **string** scan of the hex digits as text.

---

## 2. firstScan parameter order

```lua
ms.firstScan(
    scanOption,        -- 1: 0 = soExactValue
    vartype,           -- 2: TVariableType integer (see §1)
    roundingtype,      -- 3: 0 = rtRounded
    input1,            -- 4: string value / AOB pattern
    input2,            -- 5: "" unless between-scan
    startAddress,      -- 6: integer
    stopAddress,       -- 7: integer
    protectionflags,   -- 8: e.g. "+W", "+W-C", "*"
    alignmenttype,     -- 9: 0 = not aligned
    alignmentparam,    -- 10: "" or "4"
    isHex,             -- 11: true for AOB hex patterns
    isNotBinary,       -- 12: usually false
    isUnicode,         -- 13: true → UTF-16 (also set by vartype 7)
    isCaseSensitive    -- 14: string compares only
)
```

**Wrong order** (scripts 23/23b/24): putting a type constant first shifts every arg →  
`"Failure determining what %s means"` (`symbolhandler.pas`).

```lua
-- WRONG
ms.firstScan(7, 0, "Fireball", ...)
-- RIGHT (ANSI string, case-insensitive)
ms.firstScan(0, 6, 0, "Fireball", "", 0x100000, 0x7FFFFFFFFFF,
    "+W", 0, "", false, false, false, false)
```

---

## 3. Mandatory result workflow

Scans are **asynchronous**. Official rule (`celua.txt`): always wait, then open results.

```lua
local ms = createMemScan()
ms.firstScan(0, 6, 0, "orearmor", "", 0x100000, 0x7FFFFFFFFFF,
    "+W-C", 0, "", false, false, false, false)

ms.waitTillDone()                    -- REQUIRED

local fl = createFoundList(ms)
fl.initialize()                      -- REQUIRED before Count/Address

local hits = {}
for i = 0, fl.Count - 1 do
    -- Address is hex WITHOUT "0x" (LuaFoundlist.pas)
    local addr = tonumber("0x" .. fl.Address[i])
    if addr then hits[#hits + 1] = addr end
end

fl.destroy()
ms.destroy()
```

| Mistake | Effect |
|---------|--------|
| No `waitTillDone()` | Race; empty or partial results |
| No `fl.initialize()` | `Count` stays 0 |
| `nextScan(...)` after first scan only | Starts a **second** filter scan (not “finalize”) |
| `tonumber(fl.Address[i])` without base | `nil` on hex letters, or wrong decimal |

`tonumber(fl.Address[i], 16)` also works; prefer `"0x" ..` for consistency with project docs.

---

## 4. String scanning and FNameEntry

### vtString does **not** require a null terminator

`CaseSensitiveAnsiStringExact` / `CaseInsensitiveAnsiStringExact` in `memscan.pas` compare **exactly `length(scanvalue1)` bytes**. No trailing `0x00` is checked.

So **ANSI `vtString` (vartype 6) can match UE5 FNameEntry strings**, which pack `[uint16 header][N chars][next header…]` with no NUL.

| Method | Vartype | Matches FName ANSI? |
|--------|--------:|---------------------|
| `vtString`, case-insensitive | **6** | **Yes** |
| `vtUnicodeString` | 7 | No (looks for UTF-16) |
| `vtByteArray` hex of ASCII | **8**, `isHex=true` | Yes (case-sensitive unless wildcards) |

### Why earlier tests showed 0 hits

1. Scripts used **vartype 7** believing it was “string” → Unicode scan.  
2. Often also skipped `waitTillDone` / `initialize`.  
3. That was misread as “vtString needs null terminators.” **Retracted 2026-07-24** after source review + script 26 fix.

### Prefer vtString for case-insensitive text

```lua
-- Case-insensitive "orearmor" (GUI ~171 hits baseline)
ms.firstScan(0, 6, 0, "orearmor", "", 0x100000, 0x7FFFFFFFFFF,
    "+W-C", 0, "", false, false, false, false)
```

### Byte-array when you need exact bytes / wildcards

```lua
-- Exact ASCII "OreArmor" (case-sensitive)
ms.firstScan(0, 8, 0, "4F 72 65 41 72 6D 6F 72", "",
    0x100000, 0x7FFFFFFFFFF, "+W", 0, "", true, false, false, false)

-- WRONG "case-insensitive" pattern (literal alternating case bytes):
-- "4F 6F 72 65 41 61 72 6D 6F 4F 72"  → searches for OooreAarmoOr
```

For true case-insensitive AOB, use `??` on case-variant positions (matches any byte) or prefer `vtString`.

---

## 5. Protection flags

`parseProtectionflags` only recognizes **`W`**, **`C`**, **`X`** (not `E`). Prefix `+` include, `-` exclude, `*` don’t-care.

| Flags | Meaning |
|-------|---------|
| `"+W"` | Writable pages (includes `PAGE_EXECUTE_READWRITE`) |
| `"+W-C"` | Writable, exclude copy-on-write — **narrower than GUI “Optional”** |
| `"+W+X"` | **AND**: page must be writable **and** executable (often too narrow) |
| `"*"` | No protection filter — **matches GUI Writable/Executable = Optional** |

### GUI “Search for text” ≠ AOBScan

From `MainUnit.pas` (CE 7.5):

| GUI control | Maps to |
|-------------|---------|
| Value type **String** | `vtString` (= **6**) |
| Scan type **Search for text** | `soExactValue` (= **0**) |
| Value type **Array of byte** | `vtByteArray` (= **8**) — different tool |
| UTF-16 checkbox | `isUnicode` |
| Case sensitive checkbox | `isCaseSensitive` |

Protection checkboxes are **tri-state**:

| State | Meaning | Flag char |
|-------|---------|-----------|
| Checked | include | `+` |
| Unchecked | **exclude** | `-` |
| Grayed | don’t care | `*` |

**Gothic session (171 hits):** Writable=Checked, Executable=Unchecked, COW=Unchecked → Lua protection **`"+W-X-C"`**.  
Executable Checked alone (with W off) → 0 hits. Do not confuse with AOBScan.

Do **not** use `+W+E` — `E` is ignored.  
`+W` already covers RWX heap/code pages; do not set executable to exclude unless intentional.

---

## 6. Pointer / AOB module scan

```lua
local pattern = string.format("%02X %02X %02X %02X %02X %02X %02X %02X",
    addr & 0xFF, (addr >> 8) & 0xFF, (addr >> 16) & 0xFF, (addr >> 24) & 0xFF,
    (addr >> 32) & 0xFF, (addr >> 40) & 0xFF, (addr >> 48) & 0xFF, (addr >> 56) & 0xFF)

ms.firstScan(0, 8, 0, pattern, "", BASE, BASE + MODSIZE,
    "+W", 0, "", true, false, false, false)
ms.waitTillDone()
-- then FoundList as in §3
```

---

## 7. Canonical helper

```lua
local VT_STRING, VT_BYTEARRAY = 6, 8

local function memScan(vartype, input, startA, stopA, prot, isHex, unicode, caseSens)
    local ms = createMemScan()
    local ok, err = pcall(function()
        ms.firstScan(0, vartype, 0, input, "",
            startA or 0x100000, stopA or 0x7FFFFFFFFFF,
            prot or "+W", 0, "",
            isHex and true or false, false,
            unicode and true or false,
            caseSens and true or false)
    end)
    if not ok then ms.destroy(); error(err) end
    ms.waitTillDone()
    local fl = createFoundList(ms)
    fl.initialize()
    local out = {}
    for i = 0, fl.Count - 1 do
        local a = tonumber("0x" .. fl.Address[i])
        if a then out[#out + 1] = a end
    end
    fl.destroy()
    ms.destroy()
    return out
end

-- FName / ANSI text:
-- memScan(VT_STRING, "orearmor", nil, nil, "+W-C", false, false, false)
-- Pointer bytes:
-- memScan(VT_BYTEARRAY, "00 01 4E 6F 6E 65", base, base+size, "+W", true, false, false)
```

---

## 8. PERFORMANCE — NEVER freeze CE

**Hard rule (learned the hard way):**

| Forbidden | Why |
|-----------|-----|
| `AOBScan` / `firstScan` **inside a per-item loop** | Hundreds of full-process scans → CE freeze/crash |
| Unbounded full-heap scans “just in case” | Multi‑GB game + many AOBs = unusable |
| Retrying the same heavy scan with 5 prot variants blindly | Multiplies cost |

| Required | How |
|----------|-----|
| Cap full-process scans | e.g. ≤ **3** AOBs per script run |
| Prefer `+W` over `""` when data is heap | Smaller working set |
| Build a **map once**, then O(1) lookup | Script 31 pattern: ns AOB → ptr AOB → `key→title` |
| Reuse `_G` maps across runs | 0 AOBs on second run |

If a script needs data for N items: **one** structure walk or **one** bulk scan — never N scans.

### Background vs main thread

| Pattern | Freezes CE UI? |
|---------|----------------|
| `createThread` + work + `synchronize(ui)` (LaunchUEInfoScanner) | **No** — scanner runs off UI thread |
| `AOBScan` / `waitTillDone` in Lua Engine Execute or menu **without** a worker thread | **Yes** — blocks message loop |
| Inventory open: pointer walk + dict lookup only | **No** |

Release rule: heavy work = same threading model as Initialize Unreal Engine. Details: `CE75-RELEASE-PROPOSAL.md` §1.

---

## 9. Other CE 7.5 scan gotchas

| Topic | Fact |
|-------|------|
| `VarType` change | Only on fresh scan (`newScan` / new `createMemScan`) |
| `readQword` | Wrap in `pcall` |
| `readPointer` | Returns `0` not `nil` — test `p and p ~= 0` |
| Bit ops | Lua 5.3 natives (`\| & << >>`); no `bit.*` |
| `math.floor` on 64-bit addrs | Prefer `//` |
| `AOBScan` | Capital `AOBScan`; returns **StringList** of hex addrs (`fl[i]`, `fl.Count`), or **nil** if 0 hits — **not** FoundList / not `.Address` |
| Scope | Prefer tight ranges; full-heap only when necessary |

---

## 10. Source map

| File | Role |
|------|------|
| `commontypedefs.pas` | `TVariableType` enum values |
| `LuaMemscan.pas` | `firstScan` / `nextScan` / `waitTillDone` bridge |
| `memscan.pas` | Match routines, `parseProtectionflags`, async controller |
| `LuaFoundlist.pas` | `Address[i]` → hex string; `initialize` |
| `foundlisthelper.pas` | Result file open on `Initialize` |
| `celua.txt` | Documents waitTillDone + initialize |

---

## 11. Project pointers

- GNames / script 26 pipeline: `CE75-GNAMES-PROPOSAL.md`
- UE layouts: `CE75-REFERENCE.md`
- Live status: `CE75-STATUS.md`
- **Verified Lua API reference (every function with its Pascal source line): `CE-FUNCTIONS.md`** — AOB scans, disassembler `getLastDisassembleData`, Dissect Code, RIP scanner, `executeCodeEx`/`executeMethod`. Read it before trusting any API behaviour from memory.
