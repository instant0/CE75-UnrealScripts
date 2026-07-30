# Finding GNames (FNamePool)

**Master doc** for GNames / FNamePool strategy and UE name-pool data.  
Scan API → `CE75-SCANNING-GUIDE.md`. Struct layouts → `CE75-REFERENCE.md`. Project status → `CE75-STATUS.md`.

## Problem — SOLVED (session 2026-07-24)

Inventory NameIndex → string works via discovered GNames.

| | |
|--|--|
| GNames | `0x7FF656796600` = **exe+0x9AE6600** |
| Validation | entry0=`"None"`, entry1=`"ByteProperty"` |
| Resolve | `block=idx>>16`, `off=idx&0xFFFF`, `Blocks[block]+off*2`, Format A header |
| Result | **318/318** occupied slots named (`InventoryNamed`) |
| Example | idx `0xB19712` → `ItAr_Scroll_TransformLurker` |

Rediscover GNames each session if static RVA reads 0. Script: `26_investigate_orearmor_hits.lua`.

## What we know (UE / this game)

| Fact | Value |
|------|-------|
| FNamePool | Lock + CurrentBlock + Cursor + `Blocks[8192]` at **+0x10** (typical) |
| FNameEntry | `uint16` header + N chars, **no NUL** |
| Header | bit0 = isWide; Format A len = `hdr>>6`; Format B len = `hdr>>1` |
| Entry 0 | always `"None"` (validate any candidate with this) |
| Entries 1… | `"ByteProperty"`, `"IntProperty"`, `"FloatProperty"`, … |
| Resolution | `block = Index>>16`, `off = Index&0xFFFF`, `entry = Blocks[block] + off*2` (stride 2) |
| Known heap FName (one session) | `"Stone_ImprovedOreArmor"` @ `0x2B988E982E6` |
| GUI baselines | ~13× `"Improved"`, ~171× case-insensitive `orearmor` |
| Old static | `exe+0x9AE6600` — moves between sessions; do not hardcode |

**CE Lua scanning rules** (vartypes, wait/init, no bogus AOB “case-insensitive” patterns): only in `CE75-SCANNING-GUIDE.md`.

## Failed approaches (summary)

Module `.data` candidate sweeps and fixed RVA never validated entry[0]==`"None"`. Early Lua “string” probes used wrong `TVariableType` / skipped FoundList init — not a CE limitation on FNames.

---

## Proposed Approaches

### Approach A: Byte-Array Scan for FNamePool Blocks

**Concept:** Scan the heap for the byte pattern of the first FNameEntry ("None" with its header). Each hit is a potential start of a FNamePool block. Validate by checking if subsequent entries match "ByteProperty", "IntProperty", etc.

**Implementation:**
1. Construct byte pattern for FNameEntry header + "None": `00 01 4E 6F 6E 65` (header=0x0100, "None")
2. Byte-array scan entire heap for this pattern
3. For each hit, read forward and validate:
   - Entry 0: "None" (length=4, ANSI)
   - Entry 1: "ByteProperty" (length=12, ANSI)
   - Entry 2: "IntProperty" (length=11, ANSI)
   - Entry 3: "FloatProperty" (length=13, ANSI)
4. Valid hits are FNamePool block starts
5. Scan for pointers TO these block addresses in the module .data section
6. The pointer location is FNamePool.Blocks[0]
7. FNamePool base = Blocks[0] - 0x10

**Pros:**
- Uses our new finding about byte array scanning
- Directly finds the block memory
- Validation is definitive (entry[0]="None", entry[1]="ByteProperty")
- Works even if GNames is not in module .data

**Cons:**
- Large scan (entire heap, 5-10GB)
- May find false positives (the string "None" appears in many contexts)
- Requires follow-up scan to find the Blocks[] pointer
- Slow (minutes for full heap scan)

**Estimated time:** 5-10 minutes for heap scan + 1-2 minutes for pointer scan

---

### Approach B: Find GNames via Known String Block

**Concept:** We know "Stone_ImprovedOreArmor" is at `0x2B988E982E6`. This string lives inside a FNamePool block. Scan for a pointer TO that block in the module .data section. The pointer is `FNamePool.Blocks[N]`. Calculate GNames base from that pointer.

**Why this works:** FNamePool.Blocks[] is an array of pointers to64KB blocks. Each pointer is stored in the module .data section (or occasionally on the heap). If we find any pointer to the block containing our string, we can calculate GNames base.

**Implementation — 4 steps:**

```
Step 1: Determine the block address containing our string

  FNameBlockOffsetBits = 16 (standard UE5, must verify)
  BlockSize = 1 << FNameBlockOffsetBits = 65536 (64KB)
  BlockMask = BlockSize - 1 = 0xFFFF

  stringAddr = 0x2B988E982E6
  blockStart = stringAddr & ~BlockMask
             = 0x2B988E982E6 & 0xFFFFFFFF0000
             = 0x2B988E00000

  Verify: blockStart <= stringAddr < blockStart + BlockSize
         0x2B988E00000 <= 0x2B988E982E6 < 0x2B988F00000  ✓

Step 2: Scan module .data for pointer to blockStart

  Build hex pattern of 0x2B988E00000 (8 bytes, little-endian):
  pattern = "00 00 E0 8E 98 2B 02 00"

  Scan range: exe+0x9800000 to exe+0x9B00000 (module .data section)
  Scan type: vtByteArray, alignment 8

  Each hit at address P where readQword(P) == 0x2B988E00000 is a candidate.

Step 3: Calculate FNamePool base from each candidate

  If *P = 0x2B988E00000, then P = &FNamePool.Blocks[N] for some N.
  FNamePool.Blocks is at offset 0x10 from FNamePool base.

  So: P = FNamePoolBase + 0x10 + (N * 8)
  FNamePoolBase = P - 0x10 - (N * 8)

  We don't know N yet, but we can try all possible N values:
  - N = (stringAddr - blockStart) / stride
  - stride is typically 2 or 4
  - For stringAddr = 0x2B988E982E6, blockStart = 0x2B988E00000:
    - offset_in_block = 0x982E6
    - If stride = 2: N = 0x982E6 / 2 = 0x31173 (but N must be < 8192)
    - This doesn't work — N is too large

  PROBLEM: The offset within the block is too large for N to be a valid index.
  This means either:
  a) The block size is not 64KB (FNameBlockOffsetBits != 16)
  b) The stride is not 2 or 4
  c) Our string address is wrong

Step 4: Alternative — scan for ANY pointer to a page containing our string

  Instead of scanning for the exact block address, scan for pointers to
  any 4KB page that contains our string:

  pageStart = stringAddr & ~0xFFF = 0x2B988E98000
  Scan for pointers to addresses in range [pageStart, pageStart + 0x1000)

  Or more broadly: scan for pointers in the range [0x2B988000000, 0x2B989000000)
  that could be FNamePool block pointers.
```

**The Problem with Step 3:**

The offset `0x982E6` within a 64KB block means the string is at byte offset 622,566 within the block. But `FNamePool.Blocks[N]` only has 8192 entries, and each entry can index up to `65536 / stride` entries. For stride=2, that's 32768 entries per block, and 8192 blocks = 268 million total entries. The offset `0x982E6` is valid — it just means N is large.

**Revised calculation:**
```
  offset_in_block = stringAddr - blockStart = 0x982E6
  entry_offset = offset_in_block / stride

  If stride = 2: entry_offset = 0x982E6 / 2 = 0x4C173 = 311,155
  This exceeds 65536 (max entries per block for BlockOffsetBits=16)

  CONCLUSION: FNameBlockOffsetBits cannot be 16 if stride=2.
  Try FNameBlockOffsetBits = 14:
    BlockSize = 16384 (16KB)
    blockStart = 0x2B988E00000 & ~0x3FFF = 0x2B988E80000
    offset_in_block = 0x2B988E982E6 - 0x2B988E80000 = 0x182E6
    entry_offset = 0x182E6 / 2 = 0xC173 = 49,523
    This exceeds 16384 (max for BlockOffsetBits=14)

  Try FNameBlockOffsetBits = 18:
    BlockSize = 262144 (256KB)
    blockStart = 0x2B988E982E6 & ~0x3FFFF = 0x2B988E00000
    offset_in_block = 0x982E6
    entry_offset = 0x982E6 / 2 = 0x4C173 = 311,155
    This exceeds 262144 (max for BlockOffsetBits=18)

  Try FNameBlockOffsetBits = 20:
    BlockSize = 1048576 (1MB)
    blockStart = 0x2B988E982E6 & ~0xFFFFF = 0x2B988000000
    offset_in_block = 0xE982E6
    entry_offset = 0xE982E6 / 2 = 0x74C173 = 7,651,699
    This exceeds 1048576 (max for BlockOffsetBits=20)
```

**Key insight:** The offset within the block is very large. This suggests either:
1. The block size is very large (unlikely — standard is 64KB)
2. The stride is larger than 2 (possible — some builds use stride=4)
3. Our string address `0x2B988E982E6` is NOT at the expected position within the block
4. The FNamePool uses a different organization than standard UE5

**Revised approach — scan for the block WITHOUT assuming block size:**

```
Step 1: Scan module .data for ANY pointer in range [0x2B988000000, 0x2B989000000)

  This range covers all possible blocks that could contain our string.
  Each pointer is a candidate FNamePool.Blocks[N].

Step 2: For each candidate pointer P where *P is in [0x2B988000000, 0x2B989000000):

  blockAddr = *P
  Validate: our string 0x2B988E982E6 must be within [blockAddr, blockAddr + BlockSize)

Step 3: Once we find a valid block pointer:

  P = &FNamePool.Blocks[N]
  FNamePoolBase = P - 0x10 - (N * 8)
  But we don't know N...

  Alternative: try all N from 0 to 7 and see which gives a valid FNamePool:
  For N = 0..7:
    FNamePoolBase = P - 0x10 - (N * 8)
    Check: FNamePoolBase + 0x08 (CurrentBlock) and FNamePoolBase + 0x0C (CurrentByteCursor)
    should be reasonable values (CurrentBlock < 8192, CurrentByteCursor < BlockSize)

Step 4: Validate FNamePool by checking entry[0] == "None"
```

**Pros:**
- Starts from a known address (no large scan needed initially)
- Uses existing knowledge about FNameEntry format
- Can handle non-standard block sizes

**Cons:**
- Requires knowing the exact FNameBlockOffsetBits (or trying multiple values)
- The string address might be in an unexpected position within the block
- Need to scan module .data for pointers (100MB scan)
- Multiple candidate pointers possible

**Estimated time:** 2-5 minutes (module .data scan + validation)

**Recommended before Approach B:** Step 0 (`26_investigate_orearmor_hits.lua`) — see below.

---

### Approach C: AOBScan for LEA/MOV Loading GNames

**Concept:** The code that resolves FNames must load the GNames address at some point. Find the instruction that loads GNames by scanning for LEA/MOV patterns.

**Implementation:**
1. Set a breakpoint on a function that uses FName resolution (if we can find one)
2. When it hits, read the GNames address from the register
3. Alternatively, AOBScan for patterns like:
   - `48 8B 0D ?? ?? ?? ??` (MOV RCX, [RIP+disp32])
   - `48 8D 05 ?? ?? ?? ??` (LEA RAX, [RIP+disp32])
4. For each candidate, check if the resolved address points to a valid FNamePool

**Pros:**
- If found, directly gives us the GNames address
- No need to search for blocks
- Works even if GNames is in a non-standard location

**Cons:**
- Hard to construct AOB pattern without knowing the exact instruction
- Many MOV/LEA instructions exist (false positives)
- GNames might be loaded indirectly (through multiple levels)
- Requires dynamic analysis (breakpoints)

**Estimated time:** 15-30 minutes (if we can find a suitable function to breakpoint)

---

### Approach D: Scan for Pointers to Known String Block

**Concept:** We know "Stone_ImprovedOreArmor" is at `0x2B988E982E6`. This string is inside a FNamePool block. Scan for pointers TO the block containing this string.

**Implementation:**
1. Determine which block contains `0x2B988E982E6`
2. Scan module .data for pointers to that block address
3. Each hit is a candidate for FNamePool.Blocks[N]
4. Calculate FNamePool base = block_ptr - (0x10 + N*8)

**Pros:**
- Uses a known address
- Small scan (module .data only, ~100MB)
- Direct path to GNames

**Cons:**
- Need to know the block address (not just the string address)
- The block might be at a different alignment
- Pointer might be indirect

**Estimated time:** 2-3 minutes

---

### Approach E: Use Dumper-7's Stride Detection Algorithm

**Concept:** Implement the exact algorithm from Dumper-7's `NameArray.cpp` to auto-detect the FNamePool structure. This algorithm:
1. Finds "None" in the first chunk
2. Finds "/Script/CoreUObject" in the first chunk
3. Determines header size from the distance between them
4. Calculates stride from header size

**Implementation:**
1. Byte-array scan for "/Script/CoreUObject" in heap (unique string)
2. For each hit, scan backward to find "None" in the same block
3. Calculate header size from the offset difference
4. Determine stride (2 if header_size == 2, else 4)
5. Use this to parse the FNamePool structure

**Pros:**
- Proven algorithm (used by Dumper-7)
- Auto-detects format variations
- Handles both Format A and Format B headers

**Cons:**
- Requires finding "/Script/CoreUObject" first
- The string might not be in the first chunk
- More complex implementation

**Estimated time:** 3-5 minutes

---

### Approach F: Breakpoint on FName Construction

**Concept:** FName is constructed when objects are created. Set a breakpoint on FName::FName or FName::operator= and catch the moment a name is added to the pool.

**Implementation:**
1. AOBScan for FName constructor pattern
2. Set breakpoint
3. When it hits, read the GNames pointer from the code or registers
4. Alternatively, scan the stack for the GNames address

**Pros:**
- Catches GNames in action
- Can see the name being added
- Direct access to the pool

**Cons:**
- Very noisy (fires for every FName creation)
- Hard to find the right function
- Requires dynamic analysis

**Estimated time:** 20-30 minutes

---

## Evaluation Matrix

| Approach | Time | Complexity | Success Probability | Risk |
|----------|------|------------|---------------------|------|
| 0: Preliminary "orearmor" scan | 1-2 min | Low | High (for validation) | Low |
| B: Find GNames via known string block | 2-5 min | Medium | High | Low |
| D: Scan for block pointer | 2-3 min | Low | High | Low |
| E: Dumper-7 stride detection | 3-5 min | Medium | High | Low |
| A: Byte-array "None" scan | 5-10 min | Medium | High | Low (slow but reliable) |
| C: AOBScan for LEA/MOV | 15-30 min | High | Medium | Low |
| F: Breakpoint on FName | 20-30 min | High | Low | Medium (noisy) |

## Recommended Order

| Priority | Approach | Rationale |
|----------|----------|-----------|
| 0 | **Preliminary: script 26 `"orearmor"` scan** | ~171 GUI hits — FNameEntry anchors for Approach B |
| 1 | **B: Find GNames via known string block** | Uses known string at 0x2B988E982E6, scans module .data for block pointer |
| 2 | **D: Scan for block pointer** | If B finds the block address, D finds GNames |
| 3 | **E: Dumper-7 stride detection** | If B/D fail, use proven algorithm |
| 4 | **A: Byte-array "None" scan** | Fallback — large scan but definitive |
| 5 | **C: AOBScan for LEA/MOV** | Last resort — requires dynamic analysis |
| 6 | **F: Breakpoint on FName** | Only if all else fails |

## Implementation Details

### Step 0: OreArmor anchors → block → GNames

**Script:** `/home/malware/projects/ue-scan-gothic/26_investigate_orearmor_hits.lua`  
(console + `_G` only)

**Why `orearmor`:** multi-name substring; GUI finds many hits with Search-for-Text, case-insensitive, Memory=All, Writable/Executable=**Optional**.

#### Findings (session breakthrough)

1. **Working:** `AOBScan` ASCII hex of `OreArmor` / `ItAr_` (StringList `fl[i]`). 128 / 2520 hits.
2. **Not working in Lua:** `vtString` Search-for-text (0 hits) even when GUI text search finds ~171. Do not rely on Lua vtString for FNames yet.
3. **FName Format A** confirmed on hits (`Stone_ImprovedOreArmor`, hdr len bits).
4. **GNames found:** `0x7FF656796600` = **`exe+0x9AE6600`** this session (old RVA live again). Validate `Blocks[0]=="None"`.
5. 64KB block bases of mid-pool strings are **chunks**, not GNames base; only Blocks[0] starts with `"None"`.
6. Inventory chain (script 07) independent ✅. NameIndex @ item **+0x18**.

#### Pipeline (script 26)

1. AOBScan `OreArmor` → FName entries → unique `& ~0xFFFF` blocks.  
2. AOB module for pointer to a block → try `ptr - 0x10 - N*8` → `"None"`.  
3. `resolveName(GNames, nameIndex)` → list inventory.  
4. Globals: `GNamesBase`, `GNamesRVA`, `InventoryNamed`, …

### Approach B: Find GNames via Known String Block

```
Step 1: Read FNameEntry header at 0x2B988E982E6 - 2
  - header = readUint16(0x2B988E982E4)
  - Determine if Format A (header >> 6 = length) or Format B (header >> 1 = length)
  - Extract: isWide = header & 1, length = header >> shift

Step 2: Calculate NameIndex
  - Need to know which block this string is in
  - Need to know the stride (2 or 4)
  - NameIndex = (block_number << BlockOffsetBits) + (offset_in_block / stride)

Step 3: Find FNamePool.Blocks[] pointer
  - Scan module .data for pointer to the block containing 0x2B988E982E6
  - FNamePool base = Blocks[block_number] - 0x10 - (block_number * 8)

Step 4: Validate
  - Read entry[0] from FNamePool — must be "None"
  - Read entry[1] — must be "ByteProperty"
```

### Approach D: Scan for Block Pointer

```
Step 1: Determine block address
  - From Approach B, we know the block contains 0x2B988E982E6
  - Block start = 0x2B988E982E6 & ~0xFFFF (align to 64KB boundary)
  - Or: scan backward from the string to find the block start

Step 2: Scan module .data for block pointer
  - pattern = hex bytes of block address (8 bytes, little-endian)
  - Scan exe+0x9800000 to exe+0x9B00000

Step 3: Calculate FNamePool base
  - For each hit at address P where *P = block_address:
    - FNamePool = P - 0x10 - (block_number * 8)
    - Where block_number = (NameIndex >> BlockOffsetBits)
```

## What Success Looks Like

**Phase 1 — Preliminary validation (Step 0 / script 26):**
- Scan hits near GUI baseline (~171 for case-insensitive `orearmor`)
- Subset with valid FNameEntry headers → block bases
- Anchors ready for Approach B/D

**Phase 2 — Find GNames (Approach B or D):**
- Find a pointer to the FNamePool block containing our known strings
- Calculate GNames base from that pointer
- Validate by checking entry[0] == "None" and entry[1] == "ByteProperty"

**Phase 3 — Resolve item names:**
- Resolve slot 0 NameIndex `0xB1A8C7` to string
- Resolve all 318 item NameIndices to strings
- Build complete inventory list with names
- Find localized display names via DataTable or localization system

## Risk Assessment

**Low risk** — All approaches are read-only memory scanning. No writes, no hooks, no process modification.

**Key uncertainty:** Whether GNames is in the module .data section (most common) or somewhere else. Approaches A/B/D work regardless of location. Approach C/F require dynamic analysis.

---

## Helper scripts (GNames only)

| Script | Role |
|--------|------|
| `26_investigate_orearmor_hits.lua` | **Current** — Step 0 pipeline above |
| 23 / 23b / 24 | Broken `firstScan` arg order — ignore |
| 25 | Wrong Unicode vartype / no wait-init — ignore |
| 19–22 | Earlier GNames hunts — failed validation |

Scan mechanics → `CE75-SCANNING-GUIDE.md`. Status line → `CE75-STATUS.md`.
