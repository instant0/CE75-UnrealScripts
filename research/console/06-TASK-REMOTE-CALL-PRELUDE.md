# Task 6 — Phase 3 Prelude: Exact CE 7.5 features required for remote calls

**Goal:** Implement the `UEngine_callFunction` / `UEngine_callMethod` wrappers over CE 7.5's built-in remote-call APIs. No target writes of its own.

**Depends on:** nothing beyond CE 7.5 built-ins (verified against `LuaHandler.pas`).
**Used by:** Task 7 (create console), Task 9 (CheatManager spawn), background approach #5 fallback (`ConsoleCommand`).

---

Several steps must **create** an object, i.e. call one C++ function in the target process (Task 7 calls `StaticConstructObject_Internal`, Task 9 calls `SpawnCheatManager`, the background approach #5 fallback calls `ConsoleCommand`). UE4SS offered that as a Lua binding; **CE 7.5 already has it built in**. The following CE 7.5 Lua functions were **verified directly against the CE 7.5 source** (`LuaHandler.pas`) and are the only remote-call machinery the plan uses — no hand-written thunks needed:

| CE 7.5 Lua function | Registered at | Purpose here |
|---|---|---|
| `executeCodeEx(callmethod, timeout, address, param1, param2, ...)` | `LuaHandler.pas:16864` | Call `StaticConstructObject_Internal` with a params-struct pointer; also the correct vehicle for **instance methods with arguments** (instance as param1 → RCX) |
| `executeMethod(callmethod, timeout, address, instance, param1, ...)` | `LuaHandler.pas:16865` | **Zero-extra-arg** instance calls only — `SpawnCheatManager`. See the register-collision caveat below |
| `allocateMemory(size[, base][, protection])` | `LuaHandler.pas:16952` | Allocate the `FStaticConstructObjectParameters` struct / `FString` in the target |
| `writePointer` / `writeInteger` / `writeBytes` / `writeString` | `LuaHandler.pas:16200-16228` | Fill the allocated structs |
| `readPointer` / `readInteger` | (core script) | Verify results / walk the object array |

**`executeCodeEx` / `executeMethod` semantics** (from `LuaHandler.pas:11535-12038`):
- `callmethod`: `0` = stdcall, `1` = cdecl (only affects 32-bit stack cleanup; irrelevant on x64).
- `timeout`: `0` = fire-and-forget (no return value), `nil`/`-1` = infinite, else milliseconds. The plan always waits with a finite timeout (e.g. `5000`).
- `address`: absolute address of the C++ function (AOB-found, or resolved from a vtable slot).
- Each `paramN` is a plain Lua value or `{type=N, value=v}` — types: `0` = integer/pointer, `1` = float, `2` = double, `3` = ASCII string (auto-allocated in target, pointer passed, freed after), `4` = wide string (same). Plain strings → type 3, plain integers → type 0, plain floats → type 1.
- x64 arg marshalling is handled by CE: params 1–4 → `RCX, RDX, R8, R9`, params 5+ → stack with shadow space allocated (`sub rsp, align(max(4,paramcount)*8,$10)+8`).
- `executeMethod` adds an `instance` argument (slot 4, before the params): a plain value is loaded into `RCX` (the `this` pointer), or `{regnr=N, classinstance=addr}` selects another register (0=rax..15=r15).
- **Register collision — [fixed].** Verified in `LuaHandler.pas`: the instance `mov` is emitted at line 11736 *before* the parameter loop (line 11745), and the first parameter is also assigned to RCX (line 11836). So `executeMethod(addr, instance, param1)` ends with `RCX=param1`, clobbering `this`. `executeMethod` is therefore safe only for methods with **no extra arguments**. For any method with arguments, call `executeCodeEx(addr, instance, param1, ...)`, which yields the exact x64 thiscall: `RCX=this`, `RDX=arg1`, `R8=arg2`. The wrapper below does this.
- **Return value**: CE writes `RAX` to a scratch slot and returns it as the Lua result (single value on success, `nil, errormsg` on failure/timeout). For x64 this is the `UObject*` we need.
- **Execution model (important):** the call runs on a **new thread** CE creates via `CreateRemoteThread` — NOT the game thread. See the foreign-thread caveat below.

Wrapper used by the steps (thin — delegates everything to the built-ins above):

```lua
-- UEngine_callFunction(fnAddr, argPtr) -> UObject*/value or nil, err
--   Calls fn(argPtr) on x64 (argPtr goes to RCX). For StaticConstructObject_Internal.
local function UEngine_callFunction(fnAddr, argPtr)
  local result, err = executeCodeEx(0, 5000, fnAddr, argPtr)   -- param type 0 = pointer
  return (result and result ~= 0) and result or nil, err
end

-- UEngine_callMethod(fnAddr, instance, param1, param2) -> value or nil, err
--   Virtual/instance call. Delegates to executeCodeEx so the instance lands in
--   RCX and the args in RDX/R8 (correct x64 thiscall). Do NOT use executeMethod
--   here — it clobbers RCX with param1 (see register-collision caveat above).
--   Used for SpawnCheatManager (no extra args) and ConsoleCommand (FString& + bWriteToLog).
local function UEngine_callMethod(fnAddr, instance, param1, param2)
  local result, err
  if param2 ~= nil then
    result, err = executeCodeEx(0, 5000, fnAddr, instance, param1, param2)
  elseif param1 ~= nil then
    result, err = executeCodeEx(0, 5000, fnAddr, instance, param1)
  else
    result, err = executeCodeEx(0, 5000, fnAddr, instance)
  end
  return (result and result ~= 0) and result or nil, err
end
```

Caveats (first-class plan items, not footnotes):
- **Foreign-thread execution.** `executeCodeEx`/`executeMethod` run the call on a CE-injected `CreateRemoteThread` thread, **not the game thread**. Code paths that `check(IsInGameThread())` (e.g. `UClass::CreateDefaultObject` in some UE4 versions) will crash. Mitigations: only call paths whose CDOs already exist (verify `Default__Console` / `Default__CheatManager` are in the object array first, so `GetDefaultObject()` never builds one), and prefer running the feature at a quiet moment (main menu).
- **Lock stalls, not deadlocks.** `GUObjectArray` and the name pool are guarded by critical sections; a concurrent GC pass only adds a short stall.
- **Best-effort, always verified.** A nil/0 return, or a returned object whose class isn't `Console`, must be recorded as an unpatched need — never assumed to have succeeded. Nothing is written to the game until the returned object validates.
- **Timeout = leaked allocations.** If `executeCodeEx` times out, CE deliberately leaves the stub/scratch allocated (`dontfree`), so a finite timeout is required (never `0` fire-and-forget for these calls) and repeated timeouts must abort the phase rather than loop.

---

## Definition of done

- `UEngine_callFunction` / `UEngine_callMethod` exist as core utilities (or documented plan items for Tasks 7/9).
- Both always use a finite ms timeout; never `0` (fire-and-forget) for these calls.
- Callers validate the returned object (class name) before writing anything.

## Verification

- On a UE4/UE5 target, call an innocuous engine function via `UEngine_callFunction` and confirm RAX comes back as expected.
- Confirm `UEngine_callMethod` passes the instance in RCX (SpawnCheatManager path, zero extra args) and, via `executeCodeEx`, the instance in RCX + param1 in RDX + param2 in R8 (ConsoleCommand path: `pc`, `&FString`, `bWriteToLog=1`).
