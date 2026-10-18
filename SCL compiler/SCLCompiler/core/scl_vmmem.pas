{ SCL Compiler / Virtual PLC - encoding of values in S7 memory (big endian, bit addresses).
  Shared by the compiler (DB start images) and the Virtual PLC runtime. }
unit scl_vmmem;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, scl_vmformat;

type
  { a stack value: integers / bit strings / times as Int64, floating point as Double }
  TVmValue = record
    case Integer of
      0: (I: Int64);
      1: (F: Double);
  end;

function IsFloatVT(VT: Byte): Boolean; inline;
function WrapToVT(V: Int64; VT: Byte): Int64;
procedure MemWriteBits(var Mem: TBytes; BitOff: Int64; VT: Byte; const V: TVmValue);
function MemReadBits(const Mem: TBytes; BitOff: Int64; VT: Byte): TVmValue;
procedure MemWriteBE(var Mem: TBytes; ByteOff: Int64; NBytes: Integer; V: QWord);
function MemReadBE(const Mem: TBytes; ByteOff: Int64; NBytes: Integer): QWord;
procedure MemWriteString(var Mem: TBytes; BitOff: Int64; MaxLen: Integer; const S: string; Wide: Boolean);
function MemReadString(const Mem: TBytes; BitOff: Int64; Wide: Boolean): string;
function EncodeS5Time(Ms: Int64): Word;
function DecodeS5Time(W: Word): Int64;
function EncodeDT(MsSince1990: Int64): QWord;
function DecodeDT(Q: QWord): Int64;
function VmInt(V: Int64): TVmValue; inline;
function VmFloat(V: Double): TVmValue; inline;

implementation

function VmInt(V: Int64): TVmValue;
begin
  Result.I := V;
end;

function VmFloat(V: Double): TVmValue;
begin
  Result.F := V;
end;

function IsFloatVT(VT: Byte): Boolean;
begin
  Result := VT in [VT_REAL, VT_LREAL];
end;

function WrapToVT(V: Int64; VT: Byte): Int64;
begin
  case VT of
    VT_BOOL: Result := V and 1;
    VT_BYTE, VT_USINT, VT_CHAR: Result := V and $FF;
    VT_SINT: Result := ShortInt(V and $FF);
    VT_WORD, VT_UINT, VT_WCHAR, VT_DATE, VT_S5TIME: Result := V and $FFFF;
    VT_INT: Result := SmallInt(V and $FFFF);
    VT_DWORD, VT_UDINT, VT_TOD: Result := V and $FFFFFFFF;
    VT_DINT, VT_TIME: Result := LongInt(V and $FFFFFFFF);
  else
    Result := V;
  end;
end;

procedure MemWriteBE(var Mem: TBytes; ByteOff: Int64; NBytes: Integer; V: QWord);
var
  I: Integer;
begin
  if (ByteOff < 0) or (ByteOff + NBytes > Length(Mem)) then Exit;
  for I := NBytes - 1 downto 0 do
  begin
    Mem[ByteOff + I] := V and $FF;
    V := V shr 8;
  end;
end;

function MemReadBE(const Mem: TBytes; ByteOff: Int64; NBytes: Integer): QWord;
var
  I: Integer;
begin
  Result := 0;
  if (ByteOff < 0) or (ByteOff + NBytes > Length(Mem)) then Exit;
  for I := 0 to NBytes - 1 do
    Result := (Result shl 8) or Mem[ByteOff + I];
end;

function ToBCD(V: Integer): Integer;
begin
  Result := ((V div 10) mod 10) shl 4 or (V mod 10);
end;

function FromBCD(V: Integer): Integer;
begin
  Result := ((V shr 4) and $F) * 10 + (V and $F);
end;

function EncodeS5Time(Ms: Int64): Word;
var
  Base, Bv, V: Integer;
begin
  if Ms < 0 then Ms := 0;
  Base := 0;
  Bv := 10;
  while (Ms div Bv > 999) and (Base < 3) do
  begin
    Inc(Base);
    Bv := Bv * 10;
  end;
  V := Ms div Bv;
  if V > 999 then V := 999;
  Result := (Base shl 12) or ((V div 100) shl 8) or (((V div 10) mod 10) shl 4) or (V mod 10);
end;

function DecodeS5Time(W: Word): Int64;
const
  Bases: array[0..3] of Integer = (10, 100, 1000, 10000);
var
  V: Integer;
begin
  V := ((W shr 8) and $F) * 100 + ((W shr 4) and $F) * 10 + (W and $F);
  Result := Int64(V) * Bases[(W shr 12) and 3];
end;

function EncodeDT(MsSince1990: Int64): QWord;
var
  Dt: TDateTime;
  Y, Mo, D, H, Mi, S, Ms: Word;
  Wd: Integer;
begin
  Dt := EncodeDate(1990, 1, 1) + MsSince1990 / 86400000.0;
  DecodeDate(Dt, Y, Mo, D);
  DecodeTime(Dt, H, Mi, S, Ms);
  Ms := MsSince1990 mod 1000;
  Wd := DayOfWeek(Dt); // 1 = Sunday (S7 uses 1 = Sunday too)
  Result := (QWord(ToBCD(Y mod 100)) shl 56) or (QWord(ToBCD(Mo)) shl 48) or (QWord(ToBCD(D)) shl 40) or
    (QWord(ToBCD(H)) shl 32) or (QWord(ToBCD(Mi)) shl 24) or (QWord(ToBCD(S)) shl 16) or
    (QWord(ToBCD(Ms div 10)) shl 8) or (QWord((Ms mod 10) shl 4)) or QWord(Wd);
end;

function DecodeDT(Q: QWord): Int64;
var
  Y, Mo, D, H, Mi, S, Ms: Integer;
  Dt: TDateTime;
begin
  Y := FromBCD((Q shr 56) and $FF);
  if Y >= 90 then Inc(Y, 1900) else Inc(Y, 2000);
  Mo := FromBCD((Q shr 48) and $FF);
  D := FromBCD((Q shr 40) and $FF);
  H := FromBCD((Q shr 32) and $FF);
  Mi := FromBCD((Q shr 24) and $FF);
  S := FromBCD((Q shr 16) and $FF);
  Ms := FromBCD((Q shr 8) and $FF) * 10 + ((Q shr 4) and $F);
  if not TryEncodeDate(Y, Mo, D, Dt) then Exit(0);
  Result := Round((Trunc(Dt) - EncodeDate(1990, 1, 1)) * 86400000.0) +
    ((H * 3600 + Mi * 60 + S) * Int64(1000)) + Ms;
end;

procedure MemWriteBits(var Mem: TBytes; BitOff: Int64; VT: Byte; const V: TVmValue);
var
  B: Int64;
  Sg: Single;
  Dw: DWord;
  Q: QWord;
begin
  B := BitOff div 8;
  case VT of
    VT_BOOL:
      begin
        if (B < 0) or (B >= Length(Mem)) then Exit;
        if V.I and 1 <> 0 then Mem[B] := Mem[B] or (1 shl (BitOff mod 8))
        else Mem[B] := Mem[B] and not (1 shl (BitOff mod 8));
      end;
    VT_BYTE, VT_SINT, VT_USINT, VT_CHAR:
      MemWriteBE(Mem, B, 1, QWord(V.I));
    VT_WORD, VT_INT, VT_UINT, VT_DATE, VT_WCHAR:
      MemWriteBE(Mem, B, 2, QWord(V.I));
    VT_S5TIME:
      MemWriteBE(Mem, B, 2, EncodeS5Time(V.I));
    VT_DWORD, VT_DINT, VT_UDINT, VT_TIME, VT_TOD:
      MemWriteBE(Mem, B, 4, QWord(V.I));
    VT_REAL:
      begin
        Sg := V.F;
        Move(Sg, Dw, 4);
        MemWriteBE(Mem, B, 4, Dw);
      end;
    VT_LREAL:
      begin
        Move(V.F, Q, 8);
        MemWriteBE(Mem, B, 8, Q);
      end;
    VT_DT:
      MemWriteBE(Mem, B, 8, EncodeDT(V.I));
  else
    MemWriteBE(Mem, B, 8, QWord(V.I));
  end;
end;

function MemReadBits(const Mem: TBytes; BitOff: Int64; VT: Byte): TVmValue;
var
  B: Int64;
  Dw: DWord;
  Sg: Single;
  Q: QWord;
begin
  B := BitOff div 8;
  Result.I := 0;
  case VT of
    VT_BOOL:
      if (B >= 0) and (B < Length(Mem)) then
        Result.I := (Mem[B] shr (BitOff mod 8)) and 1;
    VT_BYTE, VT_USINT, VT_CHAR: Result.I := MemReadBE(Mem, B, 1);
    VT_SINT: Result.I := ShortInt(MemReadBE(Mem, B, 1));
    VT_WORD, VT_UINT, VT_DATE, VT_WCHAR: Result.I := MemReadBE(Mem, B, 2);
    VT_INT: Result.I := SmallInt(MemReadBE(Mem, B, 2));
    VT_S5TIME: Result.I := DecodeS5Time(MemReadBE(Mem, B, 2));
    VT_DWORD, VT_UDINT, VT_TOD: Result.I := MemReadBE(Mem, B, 4);
    VT_DINT, VT_TIME: Result.I := LongInt(MemReadBE(Mem, B, 4));
    VT_REAL:
      begin
        Dw := MemReadBE(Mem, B, 4);
        Move(Dw, Sg, 4);
        Result.F := Sg;
      end;
    VT_LREAL:
      begin
        Q := MemReadBE(Mem, B, 8);
        Move(Q, Result.F, 8);
      end;
    VT_DT: Result.I := DecodeDT(MemReadBE(Mem, B, 8));
  else
    Result.I := Int64(MemReadBE(Mem, B, 8));
  end;
end;

procedure MemWriteString(var Mem: TBytes; BitOff: Int64; MaxLen: Integer; const S: string; Wide: Boolean);
var
  B: Int64;
  I, L: Integer;
begin
  B := BitOff div 8;
  L := Length(S);
  if L > MaxLen then L := MaxLen;
  if Wide then
  begin
    MemWriteBE(Mem, B, 2, MaxLen);
    MemWriteBE(Mem, B + 2, 2, L);
    for I := 1 to L do MemWriteBE(Mem, B + 2 + I * 2, 2, Ord(S[I]));
  end
  else
  begin
    MemWriteBE(Mem, B, 1, MaxLen);
    MemWriteBE(Mem, B + 1, 1, L);
    for I := 1 to L do MemWriteBE(Mem, B + 1 + I, 1, Ord(S[I]));
  end;
end;

function MemReadString(const Mem: TBytes; BitOff: Int64; Wide: Boolean): string;
var
  B: Int64;
  I, L: Integer;
begin
  B := BitOff div 8;
  Result := '';
  if Wide then
  begin
    L := MemReadBE(Mem, B + 2, 2);
    for I := 1 to L do Result := Result + Chr(MemReadBE(Mem, B + 2 + I * 2, 2) and $FF);
  end
  else
  begin
    L := MemReadBE(Mem, B + 1, 1);
    for I := 1 to L do Result := Result + Chr(MemReadBE(Mem, B + 1 + I, 1));
  end;
end;

end.
