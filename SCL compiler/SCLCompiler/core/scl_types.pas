{ SCL Compiler - data type system, constant values and S7 memory layout }
unit scl_types;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, contnrs, scl_base;

type
  { Elementary kinds keep their ordinal as VM type code (tkBool = 1 .. tkWChar = 25). }
  TTypeKind = (tkVoid,
    tkBool, tkByte, tkWord, tkDWord, tkLWord,
    tkSInt, tkInt, tkDInt, tkLInt,
    tkUSInt, tkUInt, tkUDInt, tkULInt,
    tkReal, tkLReal,
    tkTime, tkLTime, tkS5Time,
    tkDate, tkTOD, tkLTOD, tkDT, tkLDT,
    tkChar, tkWChar,
    tkString, tkWString,
    tkArray, tkStruct, tkFBInst, tkSysFB,
    tkAnyInt, tkAnyReal, tkAnyString, tkPointer);

  TMemberSection = (msNone, msInput, msOutput, msInOut, msStatic, msTemp, msReturn, msConstant);
  TRetainMode = (rmDefault, rmRetain, rmNonRetain);

  TConstKind = (ckNone, ckInt, ckReal, ckBool, ckString);
  TConstValue = record
    Kind: TConstKind;
    I: Int64;
    F: Double;
    S: string;
  end;
  TConstArray = array of TConstValue;

  TSclType = class;

  TMember = class
  public
    Name: string;
    Typ: TSclType;
    OffsetBits: Int64;
    Section: TMemberSection;
    ByRef: Boolean;          // stored as 64-bit pointer (VAR_IN_OUT, FC aggregate params)
    HasInit: Boolean;
    Init: TConstValue;
    InitList: TConstArray;   // array initializer [1, 2, 3(0)]
    Comment: string;
    Retain: TRetainMode;
    DeclPos: TSrcPos;
    Hidden: Boolean;         // internal (e.g. timer state) - not shown to the user
    function StorageBits: Int64;
  end;

  TSclType = class
  public
    Kind: TTypeKind;
    Name: string;            // UDT / FB / system type name, '' for anonymous
    SizeBits: Int64;
    ElemType: TSclType;      // array
    Lo, Hi: Integer;         // array bounds
    Members: TObjectList;    // TMember (struct, UDT, FB instance, system FB)
    MaxLen: Integer;         // String / WString
    IsUDT: Boolean;
    Block: TObject;          // TBlockInfo for FB instances
    SysFB: string;           // TON, CTU, IEC_TIMER ...
    LitValue: TConstValue;   // for literal pseudo types
    constructor Create(AKind: TTypeKind);
    destructor Destroy; override;
    function MemberCount: Integer;
    function Member(I: Integer): TMember;
    function FindMember(const AName: string): TMember;
    function AddMember(const AName: string; AType: TSclType; ASection: TMemberSection): TMember;
    function ElemCount: Integer;
    function ElemStrideBits: Int64;
  end;

{ elementary types / registry }
function ElemType(K: TTypeKind): TSclType;
function FindElementaryType(const AName: string): TSclType;
function NewType(K: TTypeKind): TSclType;          // owned by the global type pool
function NewStringType(AMax: Integer; Wide: Boolean): TSclType;
function NewArrayType(AElem: TSclType; ALo, AHi: Integer): TSclType;
procedure ClearTypePool;

{ classification }
function IsElementaryKind(K: TTypeKind): Boolean;
function IsIntKind(K: TTypeKind): Boolean;
function IsSignedKind(K: TTypeKind): Boolean;
function IsBitKind(K: TTypeKind): Boolean;
function IsRealKind(K: TTypeKind): Boolean;
function IsNumericKind(K: TTypeKind): Boolean;
function IsTimeKind(K: TTypeKind): Boolean;
function IsDateTimeKind(K: TTypeKind): Boolean;
function IsStringKind(K: TTypeKind): Boolean;
function IsAggregate(T: TSclType): Boolean;
function ElementaryBits(K: TTypeKind): Integer;
function IntRangeOf(K: TTypeKind; out ALo, AHi: Int64): Boolean;
function KindName(K: TTypeKind): string;
function TypeName(T: TSclType): string;
function SameType(A, B: TSclType): Boolean;
function TypeSupportedOn(K: TTypeKind; Cpu: TCpuFamily): Boolean;
function IntRank(K: TTypeKind): Integer;

{ layout (S7 standard access rules, bit offsets) }
function AlignBitsFor(T: TSclType): Integer;
procedure LayoutStruct(T: TSclType);
procedure LayoutArray(T: TSclType);

{ system function blocks }
function IsSysFBName(const AName: string): Boolean;
function MakeSysFBType(const AName: string; Cpu: TCpuFamily; out Err: string): TSclType;
function SysFBCallable(T: TSclType; const ACallName: string): Boolean;

{ constants }
function CInt(V: Int64): TConstValue;
function CReal(V: Double): TConstValue;
function CBool(V: Boolean): TConstValue;
function CStr(const V: string): TConstValue;
function ConstToStr(const C: TConstValue; K: TTypeKind): string;
function DTLType: TSclType;

const
  BIT_ALIGN_WORD = 16;

implementation

uses Math;

var
  GElem: array[TTypeKind] of TSclType;
  GPool: TObjectList;
  GDTL: TSclType;

const
  KindNames: array[TTypeKind] of string = ('Void',
    'Bool', 'Byte', 'Word', 'DWord', 'LWord',
    'SInt', 'Int', 'DInt', 'LInt',
    'USInt', 'UInt', 'UDInt', 'ULInt',
    'Real', 'LReal',
    'Time', 'LTime', 'S5Time',
    'Date', 'Time_Of_Day', 'LTime_Of_Day', 'Date_And_Time', 'LDT',
    'Char', 'WChar',
    'String', 'WString',
    'Array', 'Struct', 'FB', 'SystemFB',
    'integer constant', 'real constant', 'string constant', 'Pointer');

{ TMember }

function TMember.StorageBits: Int64;
begin
  if ByRef then Result := 64 else Result := Typ.SizeBits;
end;

{ TSclType }

constructor TSclType.Create(AKind: TTypeKind);
begin
  inherited Create;
  Kind := AKind;
  Members := TObjectList.Create(True);
  SizeBits := ElementaryBits(AKind);
end;

destructor TSclType.Destroy;
begin
  Members.Free;
  inherited Destroy;
end;

function TSclType.MemberCount: Integer;
begin
  Result := Members.Count;
end;

function TSclType.Member(I: Integer): TMember;
begin
  Result := TMember(Members[I]);
end;

function TSclType.FindMember(const AName: string): TMember;
var
  I: Integer;
begin
  for I := 0 to Members.Count - 1 do
    if CompareText(TMember(Members[I]).Name, AName) = 0 then
      Exit(TMember(Members[I]));
  Result := nil;
end;

function TSclType.AddMember(const AName: string; AType: TSclType; ASection: TMemberSection): TMember;
begin
  Result := TMember.Create;
  Result.Name := AName;
  Result.Typ := AType;
  Result.Section := ASection;
  Members.Add(Result);
end;

function TSclType.ElemCount: Integer;
begin
  Result := Hi - Lo + 1;
end;

function TSclType.ElemStrideBits: Int64;
begin
  if ElemType = nil then Exit(0);
  Result := ElemType.SizeBits;
  if ElemType.Kind = tkBool then Exit(1);
  { every non-bool element is byte aligned; aggregates are already even sized }
  Result := ((Result + 7) div 8) * 8;
end;

{ registry }

function ElemType(K: TTypeKind): TSclType;
begin
  Result := GElem[K];
end;

function NewType(K: TTypeKind): TSclType;
begin
  Result := TSclType.Create(K);
  GPool.Add(Result);
end;

function NewStringType(AMax: Integer; Wide: Boolean): TSclType;
begin
  if Wide then
  begin
    Result := NewType(tkWString);
    Result.MaxLen := AMax;
    Result.SizeBits := Int64(AMax + 2) * 16;
  end
  else
  begin
    Result := NewType(tkString);
    Result.MaxLen := AMax;
    Result.SizeBits := Int64(AMax + 2) * 8;
  end;
end;

function NewArrayType(AElem: TSclType; ALo, AHi: Integer): TSclType;
begin
  Result := NewType(tkArray);
  Result.ElemType := AElem;
  Result.Lo := ALo;
  Result.Hi := AHi;
  LayoutArray(Result);
end;

procedure ClearTypePool;
begin
  GPool.Clear;
  GDTL := nil;
end;

function FindElementaryType(const AName: string): TSclType;
var
  U: string;
  K: TTypeKind;
begin
  U := UpperCase(AName);
  if (U = 'TOD') or (U = 'TIME_OF_DAY') then Exit(GElem[tkTOD]);
  if (U = 'LTOD') or (U = 'LTIME_OF_DAY') then Exit(GElem[tkLTOD]);
  if (U = 'DT') or (U = 'DATE_AND_TIME') then Exit(GElem[tkDT]);
  if (U = 'LDT') or (U = 'LDATE_AND_TIME') then Exit(GElem[tkLDT]);
  if U = 'VOID' then Exit(GElem[tkVoid]);
  for K := tkBool to tkWChar do
    if U = UpperCase(KindNames[K]) then Exit(GElem[K]);
  Result := nil;
end;

{ classification }

function IsElementaryKind(K: TTypeKind): Boolean;
begin
  Result := K in [tkBool..tkWChar];
end;

function IsIntKind(K: TTypeKind): Boolean;
begin
  Result := K in [tkSInt, tkInt, tkDInt, tkLInt, tkUSInt, tkUInt, tkUDInt, tkULInt, tkAnyInt];
end;

function IsSignedKind(K: TTypeKind): Boolean;
begin
  Result := K in [tkSInt, tkInt, tkDInt, tkLInt, tkAnyInt, tkTime, tkLTime];
end;

function IsBitKind(K: TTypeKind): Boolean;
begin
  Result := K in [tkBool, tkByte, tkWord, tkDWord, tkLWord];
end;

function IsRealKind(K: TTypeKind): Boolean;
begin
  Result := K in [tkReal, tkLReal, tkAnyReal];
end;

function IsNumericKind(K: TTypeKind): Boolean;
begin
  Result := IsIntKind(K) or IsRealKind(K);
end;

function IsTimeKind(K: TTypeKind): Boolean;
begin
  Result := K in [tkTime, tkLTime, tkS5Time];
end;

function IsDateTimeKind(K: TTypeKind): Boolean;
begin
  Result := K in [tkDate, tkTOD, tkLTOD, tkDT, tkLDT];
end;

function IsStringKind(K: TTypeKind): Boolean;
begin
  Result := K in [tkString, tkWString, tkAnyString];
end;

function IsAggregate(T: TSclType): Boolean;
begin
  Result := T.Kind in [tkArray, tkStruct, tkFBInst, tkSysFB, tkString, tkWString];
end;

function ElementaryBits(K: TTypeKind): Integer;
begin
  case K of
    tkBool: Result := 1;
    tkByte, tkSInt, tkUSInt, tkChar: Result := 8;
    tkWord, tkInt, tkUInt, tkS5Time, tkDate, tkWChar: Result := 16;
    tkDWord, tkDInt, tkUDInt, tkReal, tkTime, tkTOD: Result := 32;
    tkLWord, tkLInt, tkULInt, tkLReal, tkLTime, tkLTOD, tkDT, tkLDT: Result := 64;
    tkPointer: Result := 64;
  else
    Result := 0;
  end;
end;

function IntRangeOf(K: TTypeKind; out ALo, AHi: Int64): Boolean;
begin
  Result := True;
  case K of
    tkSInt: begin ALo := -128; AHi := 127; end;
    tkInt: begin ALo := -32768; AHi := 32767; end;
    tkDInt: begin ALo := -2147483648; AHi := 2147483647; end;
    tkLInt, tkAnyInt: begin ALo := Low(Int64); AHi := High(Int64); end;
    tkUSInt, tkByte, tkChar: begin ALo := 0; AHi := 255; end;
    tkUInt, tkWord, tkWChar: begin ALo := 0; AHi := 65535; end;
    tkUDInt, tkDWord: begin ALo := 0; AHi := 4294967295; end;
    tkULInt, tkLWord: begin ALo := Low(Int64); AHi := High(Int64); end;
    tkBool: begin ALo := 0; AHi := 1; end;
  else
    Result := False;
  end;
end;

function IntRank(K: TTypeKind): Integer;
begin
  case K of
    tkSInt: Result := 1;
    tkUSInt: Result := 1;
    tkInt: Result := 2;
    tkUInt: Result := 2;
    tkDInt: Result := 3;
    tkUDInt: Result := 3;
    tkLInt: Result := 4;
    tkULInt: Result := 4;
  else
    Result := 0;
  end;
end;

function KindName(K: TTypeKind): string;
begin
  Result := KindNames[K];
end;

function TypeName(T: TSclType): string;
begin
  if T = nil then Exit('?');
  case T.Kind of
    tkArray:
      Result := Format('Array[%d..%d] of %s', [T.Lo, T.Hi, TypeName(T.ElemType)]);
    tkString:
      Result := Format('String[%d]', [T.MaxLen]);
    tkWString:
      Result := Format('WString[%d]', [T.MaxLen]);
    tkStruct:
      if T.Name <> '' then Result := '"' + T.Name + '"' else Result := 'Struct';
    tkFBInst:
      Result := '"' + T.Name + '"';
    tkSysFB:
      Result := T.Name;
  else
    Result := KindNames[T.Kind];
  end;
end;

function SameType(A, B: TSclType): Boolean;
begin
  if A = B then Exit(True);
  if (A = nil) or (B = nil) then Exit(False);
  if A.Kind <> B.Kind then Exit(False);
  case A.Kind of
    tkArray:
      Result := (A.Lo = B.Lo) and (A.Hi = B.Hi) and SameType(A.ElemType, B.ElemType);
    tkString, tkWString:
      Result := True;
    tkStruct:
      Result := (A.Name <> '') and (CompareText(A.Name, B.Name) = 0);
    tkFBInst, tkSysFB:
      Result := CompareText(A.Name, B.Name) = 0;
  else
    Result := True;
  end;
end;

function TypeSupportedOn(K: TTypeKind; Cpu: TCpuFamily): Boolean;
begin
  case Cpu of
    cpuS7_300, cpuS7_400:
      Result := K in [tkVoid, tkBool, tkByte, tkWord, tkDWord, tkInt, tkDInt, tkReal,
        tkTime, tkS5Time, tkDate, tkTOD, tkDT, tkChar, tkString, tkArray, tkStruct,
        tkFBInst, tkSysFB];
    cpuS7_1200:
      Result := not (K in [tkLWord, tkLInt, tkULInt, tkLTime, tkLTOD, tkLDT, tkS5Time]);
  else
    Result := True;
  end;
end;

{ layout }

function AlignBitsFor(T: TSclType): Integer;
begin
  case T.Kind of
    tkBool: Result := 1;
    tkByte, tkSInt, tkUSInt, tkChar: Result := 8;
  else
    Result := BIT_ALIGN_WORD;
  end;
end;

function AlignUp(V, A: Int64): Int64; inline;
begin
  if A <= 1 then Exit(V);
  Result := ((V + A - 1) div A) * A;
end;

procedure LayoutStruct(T: TSclType);
var
  I: Integer;
  M: TMember;
  Cur, A: Int64;
begin
  Cur := 0;
  for I := 0 to T.Members.Count - 1 do
  begin
    M := TMember(T.Members[I]);
    if M.ByRef then
      A := BIT_ALIGN_WORD
    else
      A := AlignBitsFor(M.Typ);
    Cur := AlignUp(Cur, A);
    M.OffsetBits := Cur;
    Inc(Cur, M.StorageBits);
  end;
  T.SizeBits := AlignUp(Cur, BIT_ALIGN_WORD);
end;

procedure LayoutArray(T: TSclType);
var
  N: Int64;
begin
  N := Int64(T.Hi) - T.Lo + 1;
  if N < 0 then N := 0;
  T.SizeBits := N * T.ElemStrideBits;
  if T.ElemType.Kind = tkBool then
    T.SizeBits := AlignUp(T.SizeBits, 8);
end;

{ system FBs }

type
  TSysFBInfo = record
    Name: string;
    Family: Char;   // T timer, L ltimer, C counter, E edge, F flipflop, I IEC_TIMER container
    CntKind: TTypeKind;
  end;

const
  SysFBs: array[0..29] of TSysFBInfo = (
    (Name: 'TP'; Family: 'T'; CntKind: tkVoid),
    (Name: 'TON'; Family: 'T'; CntKind: tkVoid),
    (Name: 'TOF'; Family: 'T'; CntKind: tkVoid),
    (Name: 'TONR'; Family: 'T'; CntKind: tkVoid),
    (Name: 'TP_TIME'; Family: 'T'; CntKind: tkVoid),
    (Name: 'TON_TIME'; Family: 'T'; CntKind: tkVoid),
    (Name: 'TOF_TIME'; Family: 'T'; CntKind: tkVoid),
    (Name: 'TONR_TIME'; Family: 'T'; CntKind: tkVoid),
    (Name: 'TP_LTIME'; Family: 'L'; CntKind: tkVoid),
    (Name: 'TON_LTIME'; Family: 'L'; CntKind: tkVoid),
    (Name: 'TOF_LTIME'; Family: 'L'; CntKind: tkVoid),
    (Name: 'TONR_LTIME'; Family: 'L'; CntKind: tkVoid),
    (Name: 'IEC_TIMER'; Family: 'I'; CntKind: tkVoid),
    (Name: 'IEC_LTIMER'; Family: 'J'; CntKind: tkVoid),
    (Name: 'CTU'; Family: 'C'; CntKind: tkInt),
    (Name: 'CTD'; Family: 'C'; CntKind: tkInt),
    (Name: 'CTUD'; Family: 'C'; CntKind: tkInt),
    (Name: 'CTU_INT'; Family: 'C'; CntKind: tkInt),
    (Name: 'CTD_INT'; Family: 'C'; CntKind: tkInt),
    (Name: 'CTUD_INT'; Family: 'C'; CntKind: tkInt),
    (Name: 'CTU_DINT'; Family: 'C'; CntKind: tkDInt),
    (Name: 'CTD_DINT'; Family: 'C'; CntKind: tkDInt),
    (Name: 'CTUD_DINT'; Family: 'C'; CntKind: tkDInt),
    (Name: 'IEC_COUNTER'; Family: 'K'; CntKind: tkInt),
    (Name: 'IEC_DCOUNTER'; Family: 'K'; CntKind: tkDInt),
    (Name: 'IEC_UDCOUNTER'; Family: 'K'; CntKind: tkUDInt),
    (Name: 'R_TRIG'; Family: 'E'; CntKind: tkVoid),
    (Name: 'F_TRIG'; Family: 'E'; CntKind: tkVoid),
    (Name: 'RS'; Family: 'F'; CntKind: tkVoid),
    (Name: 'SR'; Family: 'F'; CntKind: tkVoid));

function FindSysFB(const AName: string): Integer;
var
  I: Integer;
begin
  for I := Low(SysFBs) to High(SysFBs) do
    if CompareText(SysFBs[I].Name, AName) = 0 then Exit(I);
  Result := -1;
end;

function IsSysFBName(const AName: string): Boolean;
begin
  Result := FindSysFB(AName) >= 0;
end;

function MakeSysFBType(const AName: string; Cpu: TCpuFamily; out Err: string): TSclType;
var
  Idx: Integer;
  Info: TSysFBInfo;
  T: TSclType;
  TimeT: TSclType;
  CntT: TSclType;

  procedure M(const N: string; Ty: TSclType; S: TMemberSection; Hid: Boolean = False);
  var
    X: TMember;
  begin
    X := T.AddMember(N, Ty, S);
    X.Hidden := Hid;
  end;

begin
  Err := '';
  Idx := FindSysFB(AName);
  if Idx < 0 then Exit(nil);
  Info := SysFBs[Idx];
  if (Info.Family in ['L', 'J']) and (Cpu <> cpuS7_1500) then
  begin
    Err := Format('%s is only available on S7-1500', [Info.Name]);
    Exit(nil);
  end;
  if (Cpu in [cpuS7_300, cpuS7_400]) and (Pos('TONR', UpperCase(Info.Name)) > 0) then
  begin
    Err := Format('%s is not available on %s', [Info.Name, CpuNames[Cpu]]);
    Exit(nil);
  end;
  if (Cpu in [cpuS7_300, cpuS7_400]) and (Info.CntKind in [tkUDInt]) then
  begin
    Err := Format('%s is not available on %s', [Info.Name, CpuNames[Cpu]]);
    Exit(nil);
  end;
  T := NewType(tkSysFB);
  T.Name := UpperCase(Info.Name);
  T.SysFB := UpperCase(Info.Name);
  case Info.Family of
    'T', 'L', 'I', 'J':
      begin
        if Info.Family in ['L', 'J'] then TimeT := GElem[tkLTime] else TimeT := GElem[tkTime];
        M('IN', GElem[tkBool], msInput);
        M('R', GElem[tkBool], msInput);
        M('PT', TimeT, msInput);
        M('Q', GElem[tkBool], msOutput);
        M('ET', TimeT, msOutput);
        M('_ST', GElem[tkByte], msStatic, True);
        M('_T0', GElem[tkLInt], msStatic, True);
      end;
    'C', 'K':
      begin
        CntT := GElem[Info.CntKind];
        M('CU', GElem[tkBool], msInput);
        M('CD', GElem[tkBool], msInput);
        M('R', GElem[tkBool], msInput);
        M('LD', GElem[tkBool], msInput);
        M('Q', GElem[tkBool], msOutput);
        M('QU', GElem[tkBool], msOutput);
        M('QD', GElem[tkBool], msOutput);
        M('_CUO', GElem[tkBool], msStatic, True);
        M('_CDO', GElem[tkBool], msStatic, True);
        M('PV', CntT, msInput);
        M('CV', CntT, msOutput);
      end;
    'E':
      begin
        M('CLK', GElem[tkBool], msInput);
        M('Q', GElem[tkBool], msOutput);
        M('_M', GElem[tkBool], msStatic, True);
      end;
    'F':
      begin
        if T.SysFB = 'RS' then
        begin
          M('S', GElem[tkBool], msInput);
          M('R1', GElem[tkBool], msInput);
        end
        else
        begin
          M('S1', GElem[tkBool], msInput);
          M('R', GElem[tkBool], msInput);
        end;
        M('Q1', GElem[tkBool], msOutput);
      end;
  end;
  LayoutStruct(T);
  Result := T;
end;

function SysFBCallable(T: TSclType; const ACallName: string): Boolean;
var
  U: string;
begin
  U := UpperCase(ACallName);
  if T.SysFB = 'IEC_TIMER' then
    Result := (U = 'TP') or (U = 'TON') or (U = 'TOF') or (U = 'TONR')
  else if T.SysFB = 'IEC_LTIMER' then
    Result := (U = 'TP') or (U = 'TON') or (U = 'TOF') or (U = 'TONR')
  else if Copy(T.SysFB, 1, 4) = 'IEC_' then
    Result := (U = 'CTU') or (U = 'CTD') or (U = 'CTUD')
  else
    Result := False;
end;

{ constants }

function CInt(V: Int64): TConstValue;
begin
  Result.Kind := ckInt;
  Result.I := V;
  Result.F := V;
  Result.S := '';
end;

function CReal(V: Double): TConstValue;
begin
  Result.Kind := ckReal;
  Result.F := V;
  Result.I := 0;
  Result.S := '';
end;

function CBool(V: Boolean): TConstValue;
begin
  Result.Kind := ckBool;
  Result.I := Ord(V);
  Result.F := Ord(V);
  Result.S := '';
end;

function CStr(const V: string): TConstValue;
begin
  Result.Kind := ckString;
  Result.S := V;
  Result.I := 0;
  Result.F := 0;
end;

function FormatDuration(V: Int64; Ns: Boolean): string;
var
  Neg: Boolean;
  D, H, Mi, S, Ms, Rest: Int64;
begin
  Neg := V < 0;
  V := Abs(V);
  if Ns then
  begin
    Rest := V mod 1000000;
    V := V div 1000000;
  end
  else
    Rest := 0;
  D := V div 86400000; V := V mod 86400000;
  H := V div 3600000; V := V mod 3600000;
  Mi := V div 60000; V := V mod 60000;
  S := V div 1000; Ms := V mod 1000;
  Result := '';
  if D > 0 then Result := Result + IntToStr(D) + 'D';
  if H > 0 then Result := Result + IntToStr(H) + 'H';
  if Mi > 0 then Result := Result + IntToStr(Mi) + 'M';
  if S > 0 then Result := Result + IntToStr(S) + 'S';
  if Ms > 0 then Result := Result + IntToStr(Ms) + 'MS';
  if Rest > 0 then Result := Result + IntToStr(Rest) + 'NS';
  if Result = '' then Result := '0S';
  if Neg then Result := '-' + Result;
end;

function ConstToStr(const C: TConstValue; K: TTypeKind): string;
begin
  case C.Kind of
    ckNone: Result := '';
    ckBool: if C.I <> 0 then Result := 'TRUE' else Result := 'FALSE';
    ckString: Result := '''' + StringReplace(C.S, '''', '$''', [rfReplaceAll]) + '''';
    ckReal: Result := FloatToStr(C.F);
    ckInt:
      case K of
        tkTime: Result := 'T#' + FormatDuration(C.I, False);
        tkLTime: Result := 'LT#' + FormatDuration(C.I, True);
        tkS5Time: Result := 'S5T#' + FormatDuration(C.I, False);
        tkByte: Result := '16#' + IntToHex(C.I and $FF, 2);
        tkWord: Result := '16#' + IntToHex(C.I and $FFFF, 4);
        tkDWord: Result := '16#' + IntToHex(C.I and $FFFFFFFF, 8);
        tkLWord: Result := '16#' + IntToHex(C.I, 16);
        tkBool: if C.I <> 0 then Result := 'TRUE' else Result := 'FALSE';
        tkReal, tkLReal: Result := FloatToStr(C.I);
        tkChar: Result := '''' + Chr(C.I and $FF) + '''';
      else
        Result := IntToStr(C.I);
      end;
  end;
end;

function DTLType: TSclType;
begin
  if GDTL = nil then
  begin
    GDTL := NewType(tkStruct);
    GDTL.Name := 'DTL';
    GDTL.IsUDT := True;
    GDTL.AddMember('YEAR', GElem[tkUInt], msNone);
    GDTL.AddMember('MONTH', GElem[tkUSInt], msNone);
    GDTL.AddMember('DAY', GElem[tkUSInt], msNone);
    GDTL.AddMember('WEEKDAY', GElem[tkUSInt], msNone);
    GDTL.AddMember('HOUR', GElem[tkUSInt], msNone);
    GDTL.AddMember('MINUTE', GElem[tkUSInt], msNone);
    GDTL.AddMember('SECOND', GElem[tkUSInt], msNone);
    GDTL.AddMember('NANOSECOND', GElem[tkUDInt], msNone);
    LayoutStruct(GDTL);
  end;
  Result := GDTL;
end;

procedure InitTypes;
var
  K: TTypeKind;
begin
  GPool := TObjectList.Create(True);
  for K := Low(TTypeKind) to High(TTypeKind) do
  begin
    GElem[K] := TSclType.Create(K);
    GElem[K].SizeBits := ElementaryBits(K);
  end;
  GElem[tkString].MaxLen := 254;
  GElem[tkString].SizeBits := 256 * 8;
  GElem[tkWString].MaxLen := 254;
  GElem[tkWString].SizeBits := 256 * 16;
end;

procedure DoneTypes;
var
  K: TTypeKind;
begin
  GPool.Free;
  for K := Low(TTypeKind) to High(TTypeKind) do
    GElem[K].Free;
end;

initialization
  InitTypes;

finalization
  DoneTypes;

end.
