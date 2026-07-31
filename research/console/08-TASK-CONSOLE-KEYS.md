# Task 8 — Step F: Register the console key — [fixed]

**Goal:** Make `~` (Tilde) toggle the console by patching the first FKey `KeyName` in the `UInputSettings` CDO `ConsoleKeys` TArray. Runs only when `consoleKeys` lacks `Tilde` (Task 5 signal).

**Depends on:** Task 1 (FName layout: `UEngine.FNameSize`, `UEngine.NameToIndex`), core property walk + object-array helpers.
**Related:** approach #2 (AOB-patch `ConsoleKeys.Contains`) is the fallback for hard-blocked games.

---

The toggle key is **not** on `UConsole` (UE3-era). UE4/UE5 use:

```cpp
// UConsole::InputKey_InputLine
if ( GetDefault<UInputSettings>()->ConsoleKeys.Contains(Key) && Event == IE_Pressed && !bModifierDown )
```

So find the `UInputSettings` CDO (object in the array with class name `InputSettings` and `RF_ClassDefaultObject` flag, or name `Default__InputSettings`), read its `ConsoleKeys` (`TArray<FKey>`) property offset via property walk, and inspect the first FKey's `KeyName` (an `FName`). An `FKey` is `{ FName KeyName; TArray<const FKeyDetails*, TInlineAllocator<4>> KeyDetails; }`.

If `ConsoleKeys` already contains `Tilde`, nothing to do. If entries exist but wrong key, patch the first entry's `KeyName`:

```lua
-- FName memory layout — use Task 1 result (IMPORTANT: the original plan's "+4 = number"
-- is wrong for UE5):
--   UE4: ComparisonIndex@+0, Number@+4               (8 bytes)
--   UE5: ComparisonIndex@+0, DisplayIndex@+4, Number@+8   (12 bytes)
-- FName equality (used by ConsoleKeys.Contains) compares ComparisonIndex + Number,
-- but ToString() reads DisplayIndex — if DisplayIndex is left 0 the key displays as
-- "None" and console input handling can misbehave.
local idx = UEngine.NameToIndex['Tilde']
if idx then
  writeInteger(fkeyAddr + 0, idx)          -- ComparisonIndex
  if UEngine.FNameSize == 12 then          -- UE5: DisplayIndex + Number
    writeInteger(fkeyAddr + 4, idx)
    writeInteger(fkeyAddr + 8, 0)
  else                                     -- UE4: Number only
    writeInteger(fkeyAddr + 4, 0)
  end
end
```

If `ConsoleKeys` is **empty** (the common shipping disable), growing the `TArray` requires engine allocation and is risky. Options: (a) patch the `ConsoleKeys.Contains` check / `APlayerController::ConsoleKey` via AOB (approach #2), (b) find a valid FKey elsewhere in the settings object and reuse its allocation, or (c) accept programmatic activation only. Prefer (a).

If `Tilde` is not in the name pool, try `BackSpace`/`Tab` (both are engine keys and virtually always loaded).

---

## Definition of done

- `UInputSettings` CDO located; `ConsoleKeys` TArray property offset resolved.
- First FKey's `KeyName` written with `Tilde`'s ComparisonIndex (and DisplayIndex+Number on UE5).
- `Tilde` key toggles the console (works together with Task 7's instance).
- Empty-array case: AOB fallback or programmatic activation recorded explicitly, not silently skipped.

## Verification

1. Patch a game whose `ConsoleKeys` holds a wrong key → `~` toggles console.
2. UE5 target: all three FName fields correct (console displays `Tilde`, input works).
3. Re-run: `Contains(Tilde)` already true → no write (idempotent).
4. Empty array: fallback path exercised or need recorded as unpatched.
