# CE 7.5 Lua API — Verified Reference (from Lazarus source)

**Purpose:** Canonical reference for every CE 7.5 Lua function we use in this project (console tasks + scanner), with the **exact function names, argument order, semantics and gotchas** verified directly against the CE 7.5 Pascal source. Everything in this file was read from source, not from memory or online docs.

**Source tree:** `/mnt/y/Lazarus/Projects/cheat-engine-7.5/Cheat Engine/`

**Related docs:** [`CE75-SCANNING-GUIDE.md`](CE75-SCANNING-GUIDE.md) (MemScan/FoundList workflow, AOB/string scanning, threading rules) and [`CE75-REFERENCE.md`](CE75-REFERENCE.md) (UE memory layouts + API notes) overlap with this file; **when in doubt, the Pascal source wins** — this file cites the exact line.

---

## 0. Quick reference

| Lua call | Returns | Pascal source | Notes |
|---|---|---|---|
| `AOBScan(pattern[, prot[, alignType[, alignParam]]])` | `StringList` of ALL hits (`fl.Count`, `fl[i]`), or `nil` | `LuaHandler.pas:4364` | process-wide, **synchronous (blocks UI)** |
| `AOBScanUnique(pattern, ...)` | single int, or `nil` | `LuaHandler.pas:4346` | process-wide, 1st hit |
| `AOBScanModuleUnique(module, pattern, ...)` | single int, or `nil` | `LuaHandler.pas:4291` | module-scoped, default prot `'*X*W*C'` |
| `createMemScan()` → `ms`; `ms:firstScan(...)` | — | `LuaMemscan.pas:300` | async; must `waitTillDone` |
| `createFoundList(ms)` → `fl`; `fl:initialize()`; `fl.Count`; `fl.Address[i]` / `fl[i]` | hex string | `LuaFoundlist.pas:102-117` | `Address[i]` is hex **without** `0x` |
| `createDisassembler()` → `d`; `d:disassemble(addr)` | formatted string | `LuaDisassembler.pas:19/225` | |
| `d:getLastDisassembleData()` | table (see §3) | `LuaDisassembler.pas:210` | the structured decode |
| `getDissectCode()` → `dc`; `dc:dissect(m)`; `dc:getReferences(addr)` | `{ [caller] = jumptype }` | `LuaDissectCode.pas:22/31/144` | module call graph |
| `createRipRelativeScanner(m[, includeJumps])`; `.Address[i]` | disp-field addresses | `LuaRIPRelativeScanner.pas:16` | see §5 semantics |
| `executeCodeEx(callMethod, timeout, addr, ...params)` | RAX result or nil | `LuaHandler.pas:12039` | inserts nil instance → `executeMethod` |
| `executeMethod(callMethod, timeout, addr, instance, ...params)` | RAX result or nil | `LuaHandler.pas:11534` | thiscall; **do not** use for free fn with args |
| `allocateMemory(size)` | int address | CE global | zero-filled fresh page |
| `enumModules()` | module list | CE global | main exe first |
| `getFileVersion(path)` | version info | CE global | Task 1 `EngineVersion` |

---

## 1. AOB / byte-pattern scans

### `AOBScan` — all hits, process-wide — `LuaHandler.pas:4364`

```
AOBScan(scanstring[, protectionflags[, alignmenttype[, alignmentparam]]])
```
- Returns a **`TStringList` class object** (`luaclass_newClass(L, list)`, `:4425`) of hex addresses, or **nothing (`nil`) if zero hits** (`:4421-4431`).
- If the first arg is **not** a string, CE builds the pattern from the integer args: `b > 255 → '*'`, `b == 0 → '00'`, else `inttohex(b,2)` (`:4402-4416`). This is how `AOBScan(0x48,0x8D,0x0D,...)` style calls work.
- Prot defaults to `''` (no filter). Align type defaults `fsmNotAligned=0`, param defaults `'1'`.
- Under the hood: `getaoblist` (`simpleaobscanner.pas:23`) does a `vtByteArray` `firstscan` over `0 .. 0x7FFFFFFFFFFFFFFF` (64-bit) with **`soExactValue` + `rtRounded` + `isHex=true`** (`:58`), then **`waittillreallydone`** (`:59`).

### `AOBScanUnique` — 1st hit, process-wide — `LuaHandler.pas:4346`
- Pushes `''` at stack position 1 and **delegates to `AOBScanModuleUnique`** with module `''`. Same blocking behaviour.

### `AOBScanModuleUnique` — 1st hit in a module — `LuaHandler.pas:4291`
```
AOBScanModuleUnique(module, scanstring[, protectionflags[, alignmenttype[, alignmentparam]]])
```
- Requires ≥2 params; returns a **single integer** or `nil` (`:4331-4334`).
- Default protection flags: `'*X*W*C'` (`:4311`).
- Under the hood: `findaobInModule` (`simpleaobscanner.pas:136`) → `AsyncAOBScan` (`:78`): module base/size from `symhandler.getmodulebyname` (`:111`), then `firstscan` over `[base, base+size]`; `FinishAOBScan` (`:124`) → `waittilldone` + `GetOnlyOneResult`.

### Pattern syntax
- Hex bytes, space separated. **`*` = wildcard** (also `??` — both accepted by the vtByteArray matcher).
- Verified from the build-up at `:4406`; same semantics as SCANNING-GUIDE §7.

### Verified gotchas
1. **Synchronous / UI-blocking.** All three wrap a sync `waittillreallydone`. Run them in the scanner/worker-thread model; never in a per-item loop. Cap ≤3 per run (SCANNING-GUIDE §8).
2. **Module scope matters.** Use `AOBScanModuleUnique(<main exe>, ...)` first (UE is statically linked into the game exe — no engine DLL), then fall back to process-wide.
3. **Result shape differs by function**: `AOBScan` → StringList object; `*Unique` → single int. Do not confuse with FoundList.
4. **Cache results across runs** (`UEngine.SCOAddr`, pattern tables) → 0 AOBs on second run.

---

## 2. MemScan / FoundList — `LuaMemscan.pas`, `LuaFoundlist.pas`

Full workflow in SCANNING-GUIDE §3/§7. Verified API surface:

**MemScan** (`LuaMemscan.pas:299-314`):
- `ms = createMemScan()`
- `ms:firstScan(scanOption, vartype, roundingtype, input1, input2, startAddress, stopAddress, protectionflags, alignmenttype, alignmentparam, isHex, isNotBinary, isUnicode, isCaseSensitive)` (`:300`, bridge to `memscan.pas:748`)
- `ms:newScan()` — reset (`:302`); `ms:nextScan(...)` — subsequent filter (`:301`)
- `ms:waitTillDone()` (`:303`)
- `ms:OnlyOneResult` / `ms:setOnlyOneResult(bool)` / `ms:Result` (`:309-314`)
- `ms:getProgress()`, `ms:saveCurrentResults()`, `ms:getSavedResultList()` (`:304-307`)

**FoundList** (`LuaFoundlist.pas:102-117`):
- `fl = createFoundList(ms)`
- `fl:initialize()` (`:105`, REQUIRED before `Count`/`Address`)
- `fl.Count` (read-only property, `:112`)
- `fl.Address[i]` — array property, **hex string without `0x`** (`:113`; `foundlist_getAddress` calls `GetAddress(index, b, value)` `:85-100`)
- `fl.Value[i]` — array property (`:114`)
- `fl[i]` also works — Address is the default array property (`:116`)
- `fl:deinitialize()` (`:106`)

**Verified gotchas:** missing `waitTillDone` or `initialize` → empty `Count`. `tonumber("0x"..fl.Address[i])` to get an int (never raw `tonumber` without base). `readPointer` returns `0` not `nil`.

---

## 3. Disassembler — `LuaDisassembler.pas`, `disassembler.pas`, `LastDisassembleData.pas`

### Constructors — `LuaDisassembler.pas`
- `createDisassembler()` (`:225`) — new `TDisassembler`
- `getDefaultDisassembler()` (`:241`) — CE's global default disassembler
- `getVisibleDisassembler()` (`:247`) — the one driving the memory view
- `createCR3Disassembler()` (`:231`) — Windows CR3/KASLR-aware, **not on other platforms**

### Methods — `LuaDisassembler.pas:253-261`
- `d:disassemble(address)` — returns the formatted string `"ADDR - bytes - mnemonic params"` (from `disassembler.pas:15664`). Address may be a string symbol or int (`:28-31`). Internally calls `TDisassembler.disassemble(addr, desc)` (`disassembler.pas:1609-1615`).
- `d:getLastDisassembleData()` — returns a **Lua table** (`:210-223`) via `LastDisassemblerDataToTable` (`:137-208`).
- `d:decodeLastParametersToString()` (`:41`).
- Also exposed as `d.LastDisassembleData` property (`:259`).

### `LastDisassembleData` table fields — exact, from `LastDisassembleDataToTable` (`LuaDisassembler.pas:137-208`) + record (`LastDisassembleData.pas:16-55`)

| Field | Type | Meaning |
|---|---|---|
| `address` | int | instruction start address |
| `opcode` | string | mnemonic (`mov`, `call`, `lea`, ...) |
| `parameters` | string | operand text |
| `description` | string | human description |
| `bytes` | **1-indexed** int array | raw instruction bytes → `#ldd.bytes` = length |
| `modrmValueType` | int | `dvtNone=0`, `dvtAddress=1`, `dvtValue=2` (`LastDisassembleData.pas:11`) |
| `modrmValue` | int | see gotchas below |
| `parameterValueType` | int | same enum |
| `parameterValue` | int | see gotchas below |
| `isJump` | bool | changes RIP/EIP |
| `isCall` | bool | is a call |
| `isRet` | bool | is a ret |
| `isRep` | bool | rep prefix |
| `isConditionalJump` | bool | conditional jump |

> `riprelative` (the disp-byte offset within the instruction) is a Pascal-only field — **NOT** in the Lua table (`LastDisassembleDataToTable` never writes it). You derive the target yourself (§ below).

### Verified decode semantics — `disassembler.pas`

1. **Direct `call rel32` ($E8)** — `:15009-15035`:
   - `isCall=true`, `parameterValueType=dvtAddress`, **`parameterValue = resolved absolute target`** (`offset + rel32`, `:15026`).
   - **This is the xref-walk key**: filter `ldd.isCall and ldd.parameterValue == SAO` to find callers of a function.
2. **`jmp rel32` ($E9)** — `:15037+`: same, resolved target in `parameterValue`.
3. **`[rip+disp]` memory operand** (e.g. `lea rcx,[rip+X]`) — `:855-877`:
   - `modrmValueType=dvtAddress`, **`modrmValue = the RAW disp32`** (`:865`), `riprelative = modrmbyte+1` (`:867`).
   - **NOT the resolved target.** Resolve: `target = instrAddr + #bytes + signext32(modrmValue)` where `signext32(x) = (x > 0x7FFFFFFF) and (x - 0x100000000) or x`.
   - `[rip+disp]` decodes only in 64-bit mode.
4. **`[reg+disp8]` memory operand** (e.g. `lea rcx,[rbp-8]`) — `:897-904`:
   - `modrmValueType=dvtValue`, `modrmValue = sign-extended disp8` (`:903`) — a small int for stack locals.
   - **This is how the params-struct convention check works** (Task 7 §4 item 3): `lea rcx,[rbp-0xNN]`/`lea rcx,[rsp+0xNN]` decodes as `dvtValue` + small disp.
5. **`call r/m64` (FF /2)** — `:15420-15476`: indirect; `parameterValueType` may be `dvtNone` (register/indirect) — no resolved target.
6. **`mov rax,[rip+disp]` reading a global** — same `[rip+disp]` rules as (3).

### Verified gotchas
- `bytes` is 1-indexed and gives instruction length → advance a linear scan cursor by `#ldd.bytes` (`LuaDisassembler.pas:82-93`).
- The `LastDisassembleData` record is per-disassembler-object and **overwritten on every `disassemble` call** — read it immediately.
- A disassembler keeps state (e.g. prefix/alignment); reuse one instance for a sequential walk.

---

## 4. Dissect Code (module call-graph analysis) — `LuaDissectCode.pas`, `DissectCodeThread.pas`

Purpose-built for "what calls this address" and function/string cross-referencing across a whole module.

- `dc = getDissectCode()` — **global singleton**, one per CE instance (`LuaDissectCode.pas:22-29`).
- `dc:dissect(modulename)` — or `dc:dissect(base, size)` (`:31-83`). Sets the memory region and runs the analysis thread (`dowork` + `waitTillDone`, `:80-81`). Raises an exception if the module isn't found.
- `dc:getReferences(address)` — `{ [from_address] = jumptype }` for every instruction that jumps to/calls `address` (`:144-177`). Returns `nil` if none.
  - `tjumptype=(jtCall=0, jtUnconditional=1, jtConditional=2, jtMemory=3)` (`DissectCodeThread.pas:32`).
  - Filter `jtCall==0` / `jtUnconditional==1` for real calls + tail jumps.
- `dc:getReferencedStrings()` — `{ [strAddr] = str }` for every string the module references (`:179-239`). **Dev-build only** for our purposes — Shipping compiles `checkf` strings out.
- `dc:getReferencedFunctions()` — 1-indexed list of addresses that are call targets (`:241-271`).
- `dc:addReference/deleteReference(from, to, jumptype[, isString])` (`:94-142`) — manual graph edits.
- `dc:saveToFile(path)` / `dc:loadFromFile(path)` (`:273-313`) — **cache the dissection** so repeat runs skip the analysis.

### Verified gotchas
- Heavy analysis; thread-based but still one-shot. Cap the number of `dissect` calls; persist with `saveToFile`.
- `getReferences` returns the **call-site (from) addresses**, not function starts. To get the enclosing function, scan backward for MSVC boundary padding (`CC`/`CC 00 00 00` after a `C3` ret; `/Gy` builds) — first non-padding byte is the candidate start.
- The singleton is global: a second `getDissectCode()` returns the same object; `dc:clear()` (`:86`) wipes its graph.

---

## 5. RIP Relative Scanner — `LuaRIPRelativeScanner.pas`, `RipRelativeScanner.pas`

- `rrs = createRipRelativeScanner(modulename[, includeLongJumpsAndCalls])` — module-scoped (`LuaRIPRelativeScanner.pas:16-34`, `RipRelativeScanner.pas:132-142`).
- `rrs = createRipRelativeScanner(start, stop[, includeLongJumpsAndCalls])` — range form (`:36-63`).
- `rrs.Address[i]` (`:84-97`), `rrs.Count` (`RipRelativeScanner.pas:43`).

### Verified semantics — IMPORTANT (differs from intuition)
- The scanner walks **executable regions** and records every instruction with a RIP-relative operand **whose target lies inside the module** (when a module is given) (`RipRelativeScanner.pas:104`).
- **`Address[i]` = `instruction_address + riprelative`** where `riprelative = modrmbyte+1` is the byte-offset of the disp32 field within the instruction (`RipRelativeScanner.pas:107`, `disassembler.pas:867`).
- So **`.Address[i]` is the address of the disp32 field inside the code — NOT the instruction start and NOT the referenced target.**
- To get the referenced target: `target = Address[i] + 4 + signext32(readInteger(Address[i]))`.
- **Of limited use for Task 7**: the SCO params struct is a *stack local*, not a global, so `lea rcx,[rip+..]` is a *negative* signal (it would mean a different function). Documented here so nobody treats `.Address[i]` as a call site.

---

## 6. Remote calls into the target — `LuaHandler.pas`

### `executeCodeEx(callMethod, timeout, address, ...params)` — `:12039`
- Requires ≥3 params. **Inserts `nil` at stack position 4 as the instance**, then calls `executeMethod` (`:12055-12057`).
- With a nil instance, the stub performs a plain call: on x64 the params land in **RCX, RDX, R8, R9** (first four), rest on the stack.
- **This is the correct wrapper for `StaticConstructObject_Internal`**: a free function with one arg (`&FStaticConstructObjectParameters`) → `executeCodeEx(0, ms, scoAddr, paramsPtr)` puts `paramsPtr` in RCX; RAX is returned as the Lua result.

### `executeMethod(callMethod, timeout, address, instance, ...params)` — `:11534`
- Instance as first "register" arg; `instance` may be `nil` (→ no instance write), an int, or a table `{regnr=<reg>, classinstance=<int>}` (`:11659-11693`).
- **Verified pitfall** (Task 6): do NOT use `executeMethod` for an instance call with extra args — it emits the instance mov, then assigns param1 to RCX, clobbering `this` on x64. Use `executeCodeEx` with the instance as the first param so the param loop yields RCX=instance, RDX=param1, R8=param2.
- Stub mechanics (x64, `:11633-11663`): `sub rsp` aligned to `max(4,paramcount)*8`, write registers from params, `call [addressToCall]`, store RAX into `[result]`.

### Calling-convention / params contract — `:11535-11553` (documented in source)
- `callMethod`: `0 = stdcall`, `1 = cdecl`. ≥2 → error (`:11613-11619`).
- `timeout`: **`0` = don't wait / no return value** (fire-and-forget); **`nil` or `-1` = infinite**; else ms (`:11621-11624`).
- param types (table `{type=x, value=y}` or bare value): `0` = integer/pointer, `1` = float, `2` = double, `3` = asciistring (CE allocates + writes it, passes the pointer), `4` = widestring.

### Verified gotchas (Task 6 rules)
- **Timeout `0` and `nil`/`-1` leak CE's stub/scratch allocation** (fire-and-forget/infinite both skip the free path). Our wrappers (`UEngine_remoteCallTimeout`, `console.lua:870`) refuse them and enforce a finite default (`UEngine.RemoteCallTimeoutMs = 5000`).
- Success returning RAX=0 comes back as `nil` (CE pushes `nil`); call failures also come back as `nil` + errmsg. `nil` ≠ success — treat as "unpatched".
- The call runs on a **remote thread** — the target must be thread-safe for the function being called (hence the CDO hard gate in Task 7: a missing CDO would be created on our thread → `check(IsInGameThread())`).

### `executeCode(address[, parameter[, timeout]])` — `:12060` — different, legacy
- Raw stdcall with a **single int parameter** (`CreateRemoteThread(..., stub, parameter, ...)`). x64 stub: `sub rsp,28 / call [addressToCall] / mov [result],rax / add rsp,28 / ret` (`:12128-12132`). Not used by the console tasks (single-arg only, no register-argument generality).

---

## 7. StringList result objects — `LuaStringlist.pas`, `LuaStrings.pas`

`AOBScan` returns a **`TStringList`** Lua class object.
- `list.Count` — read-only int.
- `list[i]` / `list:getString(i)` / `list:setString(i, s)` — item access (**0-based**, from `strings_addMetaData`, `LuaStrings.pas:119-156`, `:259`).
- `list:add(s)`, `list:addtext(s)`, `list:clear()`, `list:delete(i)`, `list:insert(i,s)`, `list:remove(s)`, `list:indexOf(s)` (`LuaStrings.pas:17-268`).
- `list.Sorted`, `list.Duplicates`, `list.CaseSensitive` (`LuaStringlist.pas:23-97`).
- The addresses are hex strings **without `0x`** → `tonumber("0x"..list[i])`.

---

## 8. How we use these in the console project

### Task 7 — locate + validate `StaticConstructObject_Internal` (see `07-TASK-CREATE-CONSOLE.md`)
- **Path A (version-pinned table):** `AOBScanModuleUnique(<mainExe>, UEngine.SCOPatterns[UEngine.EngineVersion].pattern)` → candidate int.
- **Path B (cross-ref):**
  1. `dc = getDissectCode()`, `dc:dissect(<mainExe>)`.
  2. `refs = dc:getReferences(SAO)`; keep `{k = jumptype}` where `jumptype == 0` (jtCall) or `1` (jtUnconditional).
  3. For each call site: backward-padding walk to function start, then a **linear disassemble** from the start using `d:getLastDisassembleData()` advancing by `#bytes`.
  4. **Validate** (checklist in task doc): `ldd.isCall and ldd.parameterValue == SAO` (call rel32); RCX loaded from stack local before that call (`lea rcx,[rsp/rbp-..]` → `modrmValueType==dvtValue`, small disp).
- **Call:** `UEngine_callFunction(scoAddr, params)` → `executeCodeEx(0, timeout, scoAddr, params)` → RCX=params, RAX=UObject*.

### Task 6 — remote-call wrappers
- `UEngine_callFunction` / `UEngine_callMethod` map 1:1 to `executeCodeEx` semantics above (finite timeout enforced, `console.lua:858-923`).

### Task 3 fallback (FName-index memscan) + Task 1 version banner
- `createMemScan`/`firstScan(vtByteArray)`/`waitTillDone`/`createFoundList` — the SCANNING-GUIDE §7 `memScan()` helper.

### Scanner threading rule
- AOBScan/MemScan/DissectCode are blocking; heavy work runs in the `UEInfoScanner` worker thread (`synchronize(ui)` to touch the menu) — SCANNING-GUIDE §8.

---

## 9. Source index (verified file:line map)

| Symbol | File:line |
|---|---|
| `AOBScan` | `LuaHandler.pas:4364` |
| `AOBScanUnique` | `LuaHandler.pas:4346` |
| `AOBScanModuleUnique` | `LuaHandler.pas:4291` |
| AOB pattern build-up (`*` wildcard) | `LuaHandler.pas:4402-4416` |
| `getaoblist` (full-process vtByteArray, sync) | `simpleaobscanner.pas:23` |
| `AsyncAOBScan` / `FinishAOBScan` | `simpleaobscanner.pas:78 / :124` |
| `findaobInModule` / `findaob` | `simpleaobscanner.pas:136 / :143` |
| MemScan methods (`firstScan`…`Result`) | `LuaMemscan.pas:299-314` |
| `firstscan` pascal bridge | `memscan.pas:748` |
| FoundList (`initialize`,`Count`,`Address`,`Value`) | `LuaFoundlist.pas:102-117` |
| `createDisassembler` / `getDefaultDisassembler` / `getVisibleDisassembler` | `LuaDisassembler.pas:225 / :241 / :247` |
| `disassemble` / `getLastDisassembleData` / `decodeLastParametersToString` | `LuaDisassembler.pas:19 / :210 / :41` |
| `LastDisassemblerDataToTable` (Lua table schema) | `LuaDisassembler.pas:137-208` |
| `TDisAssemblerValueType` (`dvtNone=0,dvtAddress=1,dvtValue=2`) | `LastDisassembleData.pas:11` |
| `TLastDisassembleData` record | `LastDisassembleData.pas:16-55` |
| `disassemble` overloads | `disassembler.pas:1609-1615` |
| `call rel32` → resolved `parameterValue` | `disassembler.pas:15009-15035` |
| `jmp rel32` → resolved `parameterValue` | `disassembler.pas:15037-15059` |
| `[rip+disp]` → raw disp32 in `modrmValue` | `disassembler.pas:855-877` |
| `[reg+disp8]` → `dvtValue` + small disp | `disassembler.pas:897-904` |
| `call r/m64` (indirect, no target) | `disassembler.pas:15420-15476` |
| `getDissectCode` / `dissect` / `getReferences` / `getReferencedStrings` / `getReferencedFunctions` / `saveToFile` | `LuaDissectCode.pas:22 / :31 / :144 / :179 / :241 / :273` |
| `tjumptype` (`jtCall=0, jtUnconditional=1, jtConditional=2, jtMemory=3`) | `DissectCodeThread.pas:32` |
| `createRipRelativeScanner` / `Address[i]` | `LuaRIPRelativeScanner.pas:16 / :84` |
| RIP scan → disp-field addresses | `RipRelativeScanner.pas:104-115` + `disassembler.pas:867` |
| `executeCodeEx` (nil instance insert) | `LuaHandler.pas:12039-12058` |
| `executeMethod` (params/timeout/instance contract) | `LuaHandler.pas:11534-11693` |
| `executeCode` (legacy single-param) | `LuaHandler.pas:12060-12178` |
| `executeCodeEx`/`executeMethod` registration | `LuaHandler.pas:16864-16865` |
| `TFastScanMethod` (`fsmNotAligned=0, fsmAligned=1, fsmLastDigits=2`) | `commonTypeDefs.pas:20` |
| StringList Lua bridge | `LuaStringlist.pas:17-97`, `LuaStrings.pas:119-268` |

---

## 10. Rules of thumb distilled from source

1. **`parameterValue` on a direct call/jump is the resolved target** — the universal xref primitive.
2. **`modrmValue` on `[rip+disp]` is the raw displacement** — always resolve via `instr + len + signext(disp)`.
3. **`modrmValue` on `[reg+disp8]` is a small value** — exactly what a stack-local `lea rcx,[rsp/rbp-..]` produces.
4. **`bytes` is 1-indexed**; use `#bytes` as the stepping length for linear disassembly.
5. **AOBScan family is synchronous**; `*Unique` returns an int, `AOBScan` returns a StringList. Cap scans, cache results.
6. **`executeCodeEx` with nil instance** = free-function call (RCX=param1). **`executeMethod` with an instance + extra params clobbers RCX** — use `executeCodeEx` and pass the instance as the first param.
7. **timeout 0 / nil / -1 leak the stub** — always finite.
8. **A null return (RAX=0) and a call failure both come back as `nil`** — never treat `nil` as success.
