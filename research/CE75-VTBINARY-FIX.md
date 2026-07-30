# CE 7.5 Patch: Add vtBinary (Bitmask) Support to Structure Dissect

## Problem

CE 7.5's structure dissect (`TStructelement`) does NOT support `vtBinary` display.
The v1 callback correctly creates BoolProperty entries as `vtBinary` with `BitStart`/`BitSize`,
but CE 7.5 renders them as "???" because:

1. `readAndParseAddress()` in `byteinterpreter.pas:402` has no `vtBinary` case — returns `'???'`
2. `TStructelement` class has no `BitStart`/`BitSize` fields — only `TMemoryRecord` has them
3. The type-change popup has no "Binary" option for structure elements

## What Already Exists (Working)

`TMemoryRecord` (address list entries) fully supports vtBinary:
- `extra.bitData.Bit` — start bit (0-63)
- `extra.bitData.bitlength` — bit count (1-64)
- `extra.bitData.showasbinary` — display as "Binary" or integer
- Display: `MemoryRecordUnit.pas:2984-2993` — shift+mask+display
- Serialization: `MemoryRecordUnit.pas:1465-1478, 1971-1973` — XML with BitStart/BitLength/ShowAsBinary

### BoolProperty in Address List (WORKAROUND — no patch needed)

Even without the dissect vtBinary patch, BoolProperty entries can work correctly in the **address list** (memory table):

- Add BoolProperty as `vtByte` (not `vtBinary`)
- `TMemoryRecord` in the address list fully supports binary display
- The value displays correctly — raw byte value is shown
- This is what our script currently does and it works

**Key insight:** The vtBinary gap only affects the **structure dissect** form, NOT the address list. The address list uses `TMemoryRecord` which has complete vtBinary support. So for the address list, adding BoolProperty as `vtByte` is a working solution.

The vtBinary patch below is needed only if you want to see individual bits in the structure dissect form.

## Files to Modify

### 1. `StructuresFrm2.pas` — TStructelement class (~80 lines)

**Add private fields** (after line 46):
```pascal
fBitStart: integer;   // bit offset within byte (0-7)
fBitLength: integer;  // number of bits (1-8, default 1)
```

**Add public getter/setter methods:**
```pascal
function getBitStart: integer;
procedure setBitStart(newBitStart: integer);
function getBitLength: integer;
procedure setBitLength(newBitLength: integer);
```

**Add published properties** (after line 102):
```pascal
property BitStart: integer read getBitStart write setBitStart;
property BitLength: integer read getBitLength write setBitLength;
```

**Update `getBytesize`** (line 1075-1092) — add vtBinary case:
```pascal
vtBinary: result:=1;  // always 1 byte
```

**Update `getValue`** (line 1115-1145) — handle vtBinary BEFORE calling readAndParseAddress:
```pascal
if vartype=vtBinary then
begin
  result:='';
  if hashexprefix then result:='0x';
  // read 1 byte, extract bit
  if ReadProcessMemory(processhandle, pointer(address), @buf[0], 1, x) then
  begin
    temp := buf[0];
    temp := temp shr fBitStart;
    mask := qword($ff) shl fBitLength;
    temp := temp and (not mask);
    result := result + inttostr(temp);
  end
  else
    result := result + '???';
  exit;
end;
```

**Update `WriteToXMLNode`** (line 940-989) — save bit data:
```pascal
if self.VarType=vtBinary then
begin
  elementnode.SetAttribute('BitStart', IntToStr(self.BitStart));
  elementnode.SetAttribute('BitLength', IntToStr(self.BitLength));
end;
```

**Update `createFromXMLElement`** (line 1292-1340) — load bit data:
```pascal
if self.VarType=vtBinary then
begin
  s:=element.GetAttribute('BitStart');
  if s<>'' then fBitStart:=strtoint(s);
  s:=element.GetAttribute('BitLength');
  if s<>'' then fBitLength:=strtoint(s);
end;
```

**Add popup menu item** (~line 393):
```pascal
miChangeTypeBinary: TMenuItem;
```

**Create it in constructor** (~line 3045, after other type items):
```pascal
miChangeTypeBinary:=TMenuItem.create(columneditpopupmenu);
miChangeTypeBinary.Caption:='Binary (bit)';
miChangeTypeBinary.OnClick:=miChangeTypeClick;
columneditpopupmenu.Items.Add(miChangeTypeBinary);
```

**Update `MenuPopup`** (~line 5095-5145) — show Binary in type menu:
```pascal
miChangeTypeBinary.visible:=structElement<>nil;
if miChangeTypeBinary.visible then
  miChangeTypeBinary.Caption:=Format('Binary (bit): %d:%d', [structElement.BitStart, structElement.BitLength]);
```

**Update `miChangeTypeClick`** (~line 5170-5179) — handle Binary selection:
```pascal
else if (Sender = miChangeTypeBinary) then
begin
  vt := vtBinary;
  // TODO: prompt for BitStart and BitLength
  // Simple approach: default to bit 0, length 1
end;
```

### 2. `byteinterpreter.pas` — NOT needed

The vtBinary case can be handled entirely in `TStructelement.getValue` without modifying
`readAndParseAddress`. The structure element reads 1 byte and extracts the bit itself.

## Minimal Viable Patch (~60 lines)

The absolute minimum to make vtBinary display work:

1. Add `fBitStart`, `fBitLength` fields + properties to `TStructelement` (15 lines)
2. Add `vtBinary` case in `getBytesize` (1 line)
3. Add `vtBinary` handling in `getValue` (15 lines)
4. Add `BitStart`/`BitLength` to XML save/load (8 lines)
5. Add "Binary" to popup menu (5 lines)
6. Add BitStart/BitLength prompt dialog or defaults (10 lines)

Total: ~55-60 lines of Pascal changes, all in `StructuresFrm2.pas`.

## Optional Enhancements

- **BitStart/BitLength input dialog**: When user selects "Binary" type, show a small dialog asking for bit offset (0-7) and length (1-8). Or use spin-edit inline.
- **Display format**: Show as "0" or "1" for single bits, or integer value for multi-bit fields
- **ShowAsBinary flag**: Like `TMemoryRecord`, allow display as "Binary" string or integer
- **Write support**: Allow writing back bit values (currently read-only)

## Risk Assessment

**Very low risk** — changes are isolated to `TStructelement` class in one file.
No changes to core scanning, memory reading, or other CE functionality.
The `TMemoryRecord` binary implementation serves as a proven reference.

## Testing

1. Set up a UE5 game with BoolProperty fields (e.g., Gothic 1 Remake)
2. Run the v1 callback to create a structure with vtBinary entries
3. Verify entries display bit values instead of "???"
4. Test changing type via popup menu
5. Test save/load structure (XML serialization)
