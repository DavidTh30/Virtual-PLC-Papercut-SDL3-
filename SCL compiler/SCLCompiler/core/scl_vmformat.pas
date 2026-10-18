{ SCL Compiler - Virtual PLC image format (.svpl): opcodes, container, reader, disassembler.
  This unit has no dependency on the compiler and can be shared with the Virtual PLC. }
unit scl_vmformat;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, contnrs;

const
  SVPL_MAGIC: array[0..3] of Char = ('S', 'V', 'P', 'L');
  SVPL_VERSION = 1;

  { memory areas (address bits 56..62) }
  AREA_NONE = 0;
  AREA_I = 1;     // process image inputs
  AREA_Q = 2;     // process image outputs
  AREA_M = 3;     // bit memory
  AREA_DB = 4;    // data blocks (DB number in bits 40..55)
  AREA_L = 5;     // local stack (absolute offset inside the L stack)
  AREA_C = 6;     // constant pool (read only)
  AREA_PI = 7;    // peripheral inputs  (%IW64:P)
  AREA_PQ = 8;    // peripheral outputs

  ADDR_DB_SHIFT = 40;
  ADDR_AREA_SHIFT = 56;
  ADDR_BIT_MASK = (Int64(1) shl 40) - 1;

  { VM value types (= TTypeKind ordinal of elementary types) }
  VT_BOOL = 1; VT_BYTE = 2; VT_WORD = 3; VT_DWORD = 4; VT_LWORD = 5;
  VT_SINT = 6; VT_INT = 7; VT_DINT = 8; VT_LINT = 9;
  VT_USINT = 10; VT_UINT = 11; VT_UDINT = 12; VT_ULINT = 13;
  VT_REAL = 14; VT_LREAL = 15;
  VT_TIME = 16; VT_LTIME = 17; VT_S5TIME = 18;
  VT_DATE = 19; VT_TOD = 20; VT_LTOD = 21; VT_DT = 22; VT_LDT = 23;
  VT_CHAR = 24; VT_WCHAR = 25;
  VT_PTR = 40;

  { block kinds }
  BK_OB = 1; BK_FC = 2; BK_FB = 3; BK_DB = 4;

  { block flags }
  BF_OPTIMIZED = 1;
  BF_RETAIN = 2;
  BF_INSTANCE = 4;

  { variable flags }
  VF_RETAIN = 1;
  VF_BYREF = 2;
  VF_HIDDEN = 4;
  VF_ARRAY = 8;
  VF_STRUCT = 16;

  { builtin math ids (opBuiltin) }
  BI_SQRT = 1; BI_EXP = 2; BI_LN = 3; BI_LOG = 4; BI_SIN = 5; BI_COS = 6; BI_TAN = 7;
  BI_ASIN = 8; BI_ACOS = 9; BI_ATAN = 10; BI_FRAC = 11;

  { system FB ids (opSysFB) }
  SFB_TP = 1; SFB_TON = 2; SFB_TOF = 3; SFB_TONR = 4;
  SFB_TP_L = 11; SFB_TON_L = 12; SFB_TOF_L = 13; SFB_TONR_L = 14;
  SFB_CTU = 20; SFB_CTD = 21; SFB_CTUD = 22;
  SFB_RTRIG = 30; SFB_FTRIG = 31; SFB_RS = 32; SFB_SR = 33;

  { trap codes }
  TRAP_INDEX = 1;      // array index out of range
  TRAP_DIV0 = 2;       // integer division by zero
  TRAP_NULLPTR = 3;

type
  TOpcode = (
    opNop,
    opPushI,        // q   push int64
    opPushF,        // f   push double
    opPushAddr,     // q   push absolute address
    opAddrInst,     // u   push instance base + bit offset
    opAddrLocal,    // u   push frame base (L) + bit offset
    opAddrNewFrame, // u   push pending FC frame base + bit offset
    opAddrAdd,      // u   pop addr, push addr + bits
    opAddrIndex,    // iuu pop index, pop addr -> addr + (index-lo)*stride (count for range check)
    opLoad,         // b   pop addr, push value of type
    opStore,        // b   pop value, pop addr, store
    opLoadPtr,      // -   pop addr, push the 64-bit address stored there
    opMemCpy,       // u   pop src, pop dst, copy bits
    opStrCpy,       // b   pop src, pop dst (wide flag), respects dst max length
    opDup,          // -
    opDrop,         // -
    opSwap,         // -
    opAddI, opSubI, opMulI, opDivI, opModI, opNegI, opAbsI,
    opAddF, opSubF, opMulF, opDivF, opNegF, opExptF, opAbsF,
    opAnd, opOr, opXor, opNot,
    opEqI, opNeI, opLtI, opLeI, opGtI, opGeI,
    opLtU, opLeU, opGtU, opGeU,
    opEqF, opNeF, opLtF, opLeF, opGtF, opGeF,
    opWrap,         // b   normalize int64 to width/sign of type
    opI2F,          // -   int64 -> double
    opU2F,          // -   uint64 -> double
    opF2ITrunc, opF2IRound, opF2IFloor, opF2ICeil,
    opF2F32,        // -   round double to single precision
    opGetBit,       // b   pop v push (v shr n) and 1
    opSetBit,       // b   pop bit, pop v, push v with bit n
    opGetField,     // bb  shift, width
    opSetField,     // bb  pop field, pop v
    opShl, opShr,   // b   width: pop n, pop v
    opRol, opRor,   // b   width
    opMinI, opMaxI, opMinF, opMaxF,
    opSel,          // -   pop in1, pop in0, pop g -> g ? in1 : in0
    opJmp, opJz, opJnz,   // i relative to the next instruction
    opCall,         // w   call FC (pending frame becomes the frame)
    opCallFB,       // w   pop instance address, call FB
    opFrameAlloc,   // u   allocate a pending FC frame (bytes)
    opFrameFree,    // -   free the top pending frame
    opRet,          // -
    opBuiltin,      // w   math builtin on double
    opSysFB,        // wb  pop instance address, execute system FB (id, counter type)
    opStrCmp,       // b   pop b, pop a (addresses) push -1/0/1
    opStrLen,       // b   pop addr push length
    opStrConcat,    // b   pop b, pop a, pop dst -> push dst
    opStrLeft,      // b   pop l, pop src, pop dst -> push dst
    opStrRight,     // b
    opStrMid,       // b   pop p, pop l, pop src, pop dst -> push dst
    opStrFind,      // b   pop b, pop a -> push position
    opTrap,         // w
    opMuxPick       // b   pop n values and k: push value k (count n)
  );

  { --------------------------------------------------------------- image model }

  TSvVar = record
    Path: string;
    TypeText: string;
    VmType: Byte;
    Section: Byte;
    Flags: Byte;
    BitOff: Int64;
    SizeBits: Int64;
    InitText: string;
    Comment: string;
  end;
  TSvVarArray = array of TSvVar;

  TSvLine = record
    CodeOffset: Cardinal;
    Line: Cardinal;
  end;

  TSvBlock = class
  public
    Kind: Byte;
    Flags: Byte;
    Number: Word;
    Name: string;
    SourceFile: string;
    Code: TBytes;
    ParamBytes: Cardinal;    // FC: size of RET_VAL + parameters (allocated by caller)
    TempBytes: Cardinal;     // temp area allocated by the VM on call
    InstanceBytes: Cardinal; // FB: size of an instance
    EventClass: Word;        // OB event class (OB number group)
    Interval: Cardinal;      // cyclic interrupt OB: interval in ms
    Vars: TSvVarArray;       // interface (offsets relative to frame / instance)
    Lines: array of TSvLine;
    procedure AddVar(const V: TSvVar);
    procedure AddLine(AOffset, ALine: Cardinal);
  end;

  TSvDataBlock = class
  public
    Number: Word;
    Name: string;
    Flags: Byte;
    InstanceOf: string;      // FB / UDT / system FB name or ''
    Data: TBytes;            // initial image (big endian, S7 layout)
    RetainMap: TBytes;       // 1 bit per byte of Data: 1 = retentive
    Vars: TSvVarArray;
    procedure AddVar(const V: TSvVar);
  end;

  TSvTag = record
    Name: string;
    TypeText: string;
    Area: Byte;
    VmType: Byte;
    BitOff: Int64;
    Comment: string;
  end;

  TSvImage = class
  public
    Cpu: Byte;               // 0 S7-300, 1 S7-400, 2 S7-1200, 3 S7-1500
    ProjectName: string;
    Meta: TStringList;
    Blocks: TObjectList;     // TSvBlock (OB, FC, FB) - index = call id
    DataBlocks: TObjectList; // TSvDataBlock
    Tags: array of TSvTag;
    ConstPool: TBytes;
    constructor Create;
    destructor Destroy; override;
    function Block(I: Integer): TSvBlock;
    function DataBlock(I: Integer): TSvDataBlock;
    procedure AddTag(const T: TSvTag);
    procedure SaveToStream(S: TStream);
    procedure SaveToFile(const FN: string);
    procedure LoadFromStream(S: TStream);
    procedure LoadFromFile(const FN: string);
  end;

  { code buffer with labels / fixups for the code generator }
  TCodeBuf = class
  private
    FData: TBytes;
    FLen: Integer;
    FLabels: array of Integer;
    FFixups: array of record Pos, Lbl: Integer; end;
    procedure Grow(N: Integer);
  public
    procedure EmitByte(B: Byte);
    procedure EmitWord(W: Word);
    procedure EmitI32(V: LongInt);
    procedure EmitU32(V: Cardinal);
    procedure EmitI64(V: Int64);
    procedure EmitF64(V: Double);
    procedure Op(O: TOpcode);
    procedure OpB(O: TOpcode; B: Byte);
    procedure OpW(O: TOpcode; W: Word);
    procedure OpU(O: TOpcode; U: Cardinal);
    procedure OpQ(O: TOpcode; Q: Int64);
    function NewLabel: Integer;
    procedure SetLabel(L: Integer);
    procedure Jump(O: TOpcode; L: Integer);
    procedure Resolve;
    function Bytes: TBytes;
    property Size: Integer read FLen;
  end;

function MakeAddr(Area: Integer; DB: Integer; BitOff: Int64): Int64;
function AddrArea(A: Int64): Integer;
function AddrDB(A: Int64): Integer;
function AddrBit(A: Int64): Int64;
function AddrToText(A: Int64): string;
function OpName(O: TOpcode): string;
function OpOperands(O: TOpcode): string;
function Disassemble(const Code: TBytes; Img: TSvImage): string;
function VmTypeName(T: Byte): string;
function VmTypeBytes(T: Byte): Integer;

implementation

uses TypInfo;

function MakeAddr(Area: Integer; DB: Integer; BitOff: Int64): Int64;
begin
  Result := (Int64(Area) shl ADDR_AREA_SHIFT) or (Int64(DB and $FFFF) shl ADDR_DB_SHIFT) or (BitOff and ADDR_BIT_MASK);
end;

function AddrArea(A: Int64): Integer;
begin
  Result := (A shr ADDR_AREA_SHIFT) and $7F;
end;

function AddrDB(A: Int64): Integer;
begin
  Result := (A shr ADDR_DB_SHIFT) and $FFFF;
end;

function AddrBit(A: Int64): Int64;
begin
  Result := A and ADDR_BIT_MASK;
end;

function AddrToText(A: Int64): string;
var
  B: Int64;
begin
  B := AddrBit(A);
  case AddrArea(A) of
    AREA_I: Result := Format('%%I%d.%d', [B div 8, B mod 8]);
    AREA_Q: Result := Format('%%Q%d.%d', [B div 8, B mod 8]);
    AREA_M: Result := Format('%%M%d.%d', [B div 8, B mod 8]);
    AREA_DB: Result := Format('%%DB%d.DBX%d.%d', [AddrDB(A), B div 8, B mod 8]);
    AREA_L: Result := Format('L%d.%d', [B div 8, B mod 8]);
    AREA_C: Result := Format('C%d', [B div 8]);
    AREA_PI: Result := Format('%%I%d.%d:P', [B div 8, B mod 8]);
    AREA_PQ: Result := Format('%%Q%d.%d:P', [B div 8, B mod 8]);
  else
    Result := Format('?%d', [B]);
  end;
end;

function OpName(O: TOpcode): string;
begin
  Result := Copy(GetEnumName(TypeInfo(TOpcode), Ord(O)), 3, 100);
end;

function OpOperands(O: TOpcode): string;
begin
  case O of
    opPushI, opPushAddr: Result := 'q';
    opPushF: Result := 'f';
    opAddrInst, opAddrLocal, opAddrNewFrame, opAddrAdd, opMemCpy, opFrameAlloc: Result := 'u';
    opAddrIndex: Result := 'iuu';
    opLoad, opStore, opStrCpy, opWrap, opGetBit, opSetBit, opShl, opShr, opRol, opRor,
    opStrCmp, opStrLen, opStrConcat, opStrLeft, opStrRight, opStrMid, opStrFind, opMuxPick: Result := 'b';
    opGetField, opSetField: Result := 'bb';
    opJmp, opJz, opJnz: Result := 'i';
    opCall, opCallFB, opBuiltin, opTrap: Result := 'w';
    opSysFB: Result := 'wb';
  else
    Result := '';
  end;
end;

function VmTypeName(T: Byte): string;
const
  N: array[1..25] of string = ('Bool', 'Byte', 'Word', 'DWord', 'LWord', 'SInt', 'Int', 'DInt',
    'LInt', 'USInt', 'UInt', 'UDInt', 'ULInt', 'Real', 'LReal', 'Time', 'LTime', 'S5Time',
    'Date', 'TOD', 'LTOD', 'DT', 'LDT', 'Char', 'WChar');
begin
  if T in [1..25] then Result := N[T]
  else if T = VT_PTR then Result := 'Ptr'
  else Result := '#' + IntToStr(T);
end;

function VmTypeBytes(T: Byte): Integer;
begin
  case T of
    VT_BOOL: Result := 0;
    VT_BYTE, VT_SINT, VT_USINT, VT_CHAR: Result := 1;
    VT_WORD, VT_INT, VT_UINT, VT_S5TIME, VT_DATE, VT_WCHAR: Result := 2;
    VT_DWORD, VT_DINT, VT_UDINT, VT_REAL, VT_TIME, VT_TOD: Result := 4;
  else
    Result := 8;
  end;
end;

{ TSvBlock }

procedure TSvBlock.AddVar(const V: TSvVar);
begin
  SetLength(Vars, Length(Vars) + 1);
  Vars[High(Vars)] := V;
end;

procedure TSvBlock.AddLine(AOffset, ALine: Cardinal);
begin
  if (Length(Lines) > 0) and (Lines[High(Lines)].CodeOffset = AOffset) then
  begin
    Lines[High(Lines)].Line := ALine;
    Exit;
  end;
  SetLength(Lines, Length(Lines) + 1);
  Lines[High(Lines)].CodeOffset := AOffset;
  Lines[High(Lines)].Line := ALine;
end;

procedure TSvDataBlock.AddVar(const V: TSvVar);
begin
  SetLength(Vars, Length(Vars) + 1);
  Vars[High(Vars)] := V;
end;

{ TSvImage }

constructor TSvImage.Create;
begin
  inherited;
  Meta := TStringList.Create;
  Blocks := TObjectList.Create(True);
  DataBlocks := TObjectList.Create(True);
end;

destructor TSvImage.Destroy;
begin
  Meta.Free;
  Blocks.Free;
  DataBlocks.Free;
  inherited;
end;

function TSvImage.Block(I: Integer): TSvBlock;
begin
  Result := TSvBlock(Blocks[I]);
end;

function TSvImage.DataBlock(I: Integer): TSvDataBlock;
begin
  Result := TSvDataBlock(DataBlocks[I]);
end;

procedure TSvImage.AddTag(const T: TSvTag);
begin
  SetLength(Tags, Length(Tags) + 1);
  Tags[High(Tags)] := T;
end;

{ ---- binary helpers (little endian container) ---- }

type
  TStrTab = class
  private
    FList: TStringList;
    FData: TMemoryStream;
  public
    constructor Create;
    destructor Destroy; override;
    function Add(const S: string): Cardinal;
  end;

constructor TStrTab.Create;
begin
  FList := TStringList.Create;
  FList.Sorted := True;
  FList.CaseSensitive := True;
  FData := TMemoryStream.Create;
  Add('');
end;

destructor TStrTab.Destroy;
begin
  FList.Free;
  FData.Free;
  inherited;
end;

function TStrTab.Add(const S: string): Cardinal;
var
  I: Integer;
  Z: Byte;
begin
  if FList.Find(S, I) then Exit(Cardinal(PtrUInt(FList.Objects[I])));
  Result := FData.Position;
  if S <> '' then FData.WriteBuffer(S[1], Length(S));
  Z := 0;
  FData.WriteBuffer(Z, 1);
  FList.AddObject(S, TObject(PtrUInt(Result)));
end;

procedure WU8(S: TStream; V: Byte); begin S.WriteBuffer(V, 1); end;
procedure WU16(S: TStream; V: Word); begin V := NtoLE(V); S.WriteBuffer(V, 2); end;
procedure WU32(S: TStream; V: Cardinal); begin V := NtoLE(V); S.WriteBuffer(V, 4); end;
procedure WI64(S: TStream; V: Int64); begin V := NtoLE(V); S.WriteBuffer(V, 8); end;
procedure WBytes(S: TStream; const B: TBytes);
begin
  WU32(S, Length(B));
  if Length(B) > 0 then S.WriteBuffer(B[0], Length(B));
end;

function RU8(S: TStream): Byte; begin S.ReadBuffer(Result, 1); end;
function RU16(S: TStream): Word; begin S.ReadBuffer(Result, 2); Result := LEtoN(Result); end;
function RU32(S: TStream): Cardinal; begin S.ReadBuffer(Result, 4); Result := LEtoN(Result); end;
function RI64(S: TStream): Int64; begin S.ReadBuffer(Result, 8); Result := LEtoN(Result); end;
function RBytes(S: TStream): TBytes;
var
  N: Cardinal;
begin
  N := RU32(S);
  SetLength(Result, N);
  if N > 0 then S.ReadBuffer(Result[0], N);
end;

procedure WriteVars(S: TStream; ST: TStrTab; const V: TSvVarArray);
var
  I: Integer;
begin
  WU32(S, Length(V));
  for I := 0 to High(V) do
  begin
    WU32(S, ST.Add(V[I].Path));
    WU32(S, ST.Add(V[I].TypeText));
    WU8(S, V[I].VmType);
    WU8(S, V[I].Section);
    WU8(S, V[I].Flags);
    WU8(S, 0);
    WI64(S, V[I].BitOff);
    WI64(S, V[I].SizeBits);
    WU32(S, ST.Add(V[I].InitText));
    WU32(S, ST.Add(V[I].Comment));
  end;
end;

function StrAt(const Tab: TBytes; Ofs: Cardinal): string;
var
  E: Cardinal;
begin
  Result := '';
  if Ofs >= Cardinal(Length(Tab)) then Exit;
  E := Ofs;
  while (E < Cardinal(Length(Tab))) and (Tab[E] <> 0) do Inc(E);
  SetLength(Result, E - Ofs);
  if E > Ofs then Move(Tab[Ofs], Result[1], E - Ofs);
end;

procedure ReadVars(S: TStream; const Tab: TBytes; out V: TSvVarArray);
var
  I, N: Integer;
begin
  N := RU32(S);
  SetLength(V, N);
  for I := 0 to N - 1 do
  begin
    V[I].Path := StrAt(Tab, RU32(S));
    V[I].TypeText := StrAt(Tab, RU32(S));
    V[I].VmType := RU8(S);
    V[I].Section := RU8(S);
    V[I].Flags := RU8(S);
    RU8(S);
    V[I].BitOff := RI64(S);
    V[I].SizeBits := RI64(S);
    V[I].InitText := StrAt(Tab, RU32(S));
    V[I].Comment := StrAt(Tab, RU32(S));
  end;
end;

procedure TSvImage.SaveToStream(S: TStream);
var
  ST: TStrTab;
  Secs: array of record Id: string; Data: TMemoryStream; end;
  M: TMemoryStream;
  I, J: Integer;
  B: TSvBlock;
  D: TSvDataBlock;
  Ofs: Cardinal;

  function NewSec(const Id: string): TMemoryStream;
  begin
    SetLength(Secs, Length(Secs) + 1);
    Secs[High(Secs)].Id := Id;
    Secs[High(Secs)].Data := TMemoryStream.Create;
    Result := Secs[High(Secs)].Data;
  end;

begin
  ST := TStrTab.Create;
  try
    { META }
    M := NewSec('META');
    WU32(M, ST.Add(ProjectName));
    WU32(M, Meta.Count);
    for I := 0 to Meta.Count - 1 do WU32(M, ST.Add(Meta[I]));
    { BLKS + CODE }
    M := NewSec('BLKS');
    WU32(M, Blocks.Count);
    for I := 0 to Blocks.Count - 1 do
    begin
      B := Block(I);
      WU8(M, B.Kind);
      WU8(M, B.Flags);
      WU16(M, B.Number);
      WU32(M, ST.Add(B.Name));
      WU32(M, ST.Add(B.SourceFile));
      WU32(M, B.ParamBytes);
      WU32(M, B.TempBytes);
      WU32(M, B.InstanceBytes);
      WU16(M, B.EventClass);
      WU16(M, 0);
      WU32(M, B.Interval);
      WBytes(M, B.Code);
      WU32(M, Length(B.Lines));
      for J := 0 to High(B.Lines) do
      begin
        WU32(M, B.Lines[J].CodeOffset);
        WU32(M, B.Lines[J].Line);
      end;
      WriteVars(M, ST, B.Vars);
    end;
    { DATA }
    M := NewSec('DATA');
    WU32(M, DataBlocks.Count);
    for I := 0 to DataBlocks.Count - 1 do
    begin
      D := DataBlock(I);
      WU16(M, D.Number);
      WU8(M, D.Flags);
      WU8(M, 0);
      WU32(M, ST.Add(D.Name));
      WU32(M, ST.Add(D.InstanceOf));
      WBytes(M, D.Data);
      WBytes(M, D.RetainMap);
      WriteVars(M, ST, D.Vars);
    end;
    { TAGS }
    M := NewSec('TAGS');
    WU32(M, Length(Tags));
    for I := 0 to High(Tags) do
    begin
      WU32(M, ST.Add(Tags[I].Name));
      WU32(M, ST.Add(Tags[I].TypeText));
      WU8(M, Tags[I].Area);
      WU8(M, Tags[I].VmType);
      WU16(M, 0);
      WI64(M, Tags[I].BitOff);
      WU32(M, ST.Add(Tags[I].Comment));
    end;
    { CNST }
    M := NewSec('CNST');
    WBytes(M, ConstPool);
    { STRS last (all strings are known now) }
    M := NewSec('STRS');
    ST.FData.Position := 0;
    M.CopyFrom(ST.FData, ST.FData.Size);

    { header + directory }
    S.WriteBuffer(SVPL_MAGIC, 4);
    WU16(S, SVPL_VERSION);
    WU8(S, Cpu);
    WU8(S, 0);
    WU32(S, Length(Secs));
    Ofs := 12 + Cardinal(Length(Secs)) * 12;
    for I := 0 to High(Secs) do
    begin
      S.WriteBuffer(Secs[I].Id[1], 4);
      WU32(S, Ofs);
      WU32(S, Secs[I].Data.Size);
      Inc(Ofs, Secs[I].Data.Size);
    end;
    for I := 0 to High(Secs) do
    begin
      Secs[I].Data.Position := 0;
      S.CopyFrom(Secs[I].Data, Secs[I].Data.Size);
    end;
  finally
    for I := 0 to High(Secs) do Secs[I].Data.Free;
    ST.Free;
  end;
end;

procedure TSvImage.SaveToFile(const FN: string);
var
  F: TFileStream;
begin
  F := TFileStream.Create(FN, fmCreate);
  try
    SaveToStream(F);
  finally
    F.Free;
  end;
end;

procedure TSvImage.LoadFromStream(S: TStream);
var
  Mg: array[0..3] of Char;
  N, I, J, K: Integer;
  Dir: array of record Id: string; Ofs, Size: Cardinal; end;
  Tab: TBytes;
  Base: Int64;
  B: TSvBlock;
  D: TSvDataBlock;
  T: TSvTag;

  function Seek(const Id: string): Boolean;
  var
    X: Integer;
  begin
    for X := 0 to High(Dir) do
      if Dir[X].Id = Id then
      begin
        S.Position := Base + Dir[X].Ofs;
        Exit(True);
      end;
    Result := False;
  end;

begin
  Blocks.Clear;
  DataBlocks.Clear;
  Meta.Clear;
  SetLength(Tags, 0);
  Base := S.Position;
  S.ReadBuffer(Mg, 4);
  if Mg <> SVPL_MAGIC then raise Exception.Create('Not a SVPL image');
  if RU16(S) > SVPL_VERSION then raise Exception.Create('Unsupported SVPL version');
  Cpu := RU8(S);
  RU8(S);
  N := RU32(S);
  SetLength(Dir, N);
  for I := 0 to N - 1 do
  begin
    SetLength(Dir[I].Id, 4);
    S.ReadBuffer(Dir[I].Id[1], 4);
    Dir[I].Ofs := RU32(S);
    Dir[I].Size := RU32(S);
  end;
  if Seek('STRS') then
    for I := 0 to High(Dir) do
      if Dir[I].Id = 'STRS' then
      begin
        SetLength(Tab, Dir[I].Size);
        if Dir[I].Size > 0 then S.ReadBuffer(Tab[0], Dir[I].Size);
      end;
  if Seek('META') then
  begin
    ProjectName := StrAt(Tab, RU32(S));
    N := RU32(S);
    for I := 0 to N - 1 do Meta.Add(StrAt(Tab, RU32(S)));
  end;
  if Seek('BLKS') then
  begin
    N := RU32(S);
    for I := 0 to N - 1 do
    begin
      B := TSvBlock.Create;
      Blocks.Add(B);
      B.Kind := RU8(S);
      B.Flags := RU8(S);
      B.Number := RU16(S);
      B.Name := StrAt(Tab, RU32(S));
      B.SourceFile := StrAt(Tab, RU32(S));
      B.ParamBytes := RU32(S);
      B.TempBytes := RU32(S);
      B.InstanceBytes := RU32(S);
      B.EventClass := RU16(S);
      RU16(S);
      B.Interval := RU32(S);
      B.Code := RBytes(S);
      K := RU32(S);
      SetLength(B.Lines, K);
      for J := 0 to K - 1 do
      begin
        B.Lines[J].CodeOffset := RU32(S);
        B.Lines[J].Line := RU32(S);
      end;
      ReadVars(S, Tab, B.Vars);
    end;
  end;
  if Seek('DATA') then
  begin
    N := RU32(S);
    for I := 0 to N - 1 do
    begin
      D := TSvDataBlock.Create;
      DataBlocks.Add(D);
      D.Number := RU16(S);
      D.Flags := RU8(S);
      RU8(S);
      D.Name := StrAt(Tab, RU32(S));
      D.InstanceOf := StrAt(Tab, RU32(S));
      D.Data := RBytes(S);
      D.RetainMap := RBytes(S);
      ReadVars(S, Tab, D.Vars);
    end;
  end;
  if Seek('TAGS') then
  begin
    N := RU32(S);
    for I := 0 to N - 1 do
    begin
      T.Name := StrAt(Tab, RU32(S));
      T.TypeText := StrAt(Tab, RU32(S));
      T.Area := RU8(S);
      T.VmType := RU8(S);
      RU16(S);
      T.BitOff := RI64(S);
      T.Comment := StrAt(Tab, RU32(S));
      AddTag(T);
    end;
  end;
  if Seek('CNST') then
    ConstPool := RBytes(S);
end;

procedure TSvImage.LoadFromFile(const FN: string);
var
  F: TFileStream;
begin
  F := TFileStream.Create(FN, fmOpenRead or fmShareDenyWrite);
  try
    LoadFromStream(F);
  finally
    F.Free;
  end;
end;

{ TCodeBuf }

procedure TCodeBuf.Grow(N: Integer);
begin
  if FLen + N > Length(FData) then
    SetLength(FData, (FLen + N) * 2 + 64);
end;

procedure TCodeBuf.EmitByte(B: Byte);
begin
  Grow(1);
  FData[FLen] := B;
  Inc(FLen);
end;

procedure TCodeBuf.EmitWord(W: Word);
begin
  EmitByte(W and $FF);
  EmitByte(W shr 8);
end;

procedure TCodeBuf.EmitI32(V: LongInt);
begin
  EmitU32(Cardinal(V));
end;

procedure TCodeBuf.EmitU32(V: Cardinal);
begin
  EmitByte(V and $FF);
  EmitByte((V shr 8) and $FF);
  EmitByte((V shr 16) and $FF);
  EmitByte((V shr 24) and $FF);
end;

procedure TCodeBuf.EmitI64(V: Int64);
begin
  EmitU32(Cardinal(V and $FFFFFFFF));
  EmitU32(Cardinal((V shr 32) and $FFFFFFFF));
end;

procedure TCodeBuf.EmitF64(V: Double);
var
  Q: Int64;
begin
  Move(V, Q, 8);
  EmitI64(Q);
end;

procedure TCodeBuf.Op(O: TOpcode);
begin
  EmitByte(Ord(O));
end;

procedure TCodeBuf.OpB(O: TOpcode; B: Byte);
begin
  EmitByte(Ord(O));
  EmitByte(B);
end;

procedure TCodeBuf.OpW(O: TOpcode; W: Word);
begin
  EmitByte(Ord(O));
  EmitWord(W);
end;

procedure TCodeBuf.OpU(O: TOpcode; U: Cardinal);
begin
  EmitByte(Ord(O));
  EmitU32(U);
end;

procedure TCodeBuf.OpQ(O: TOpcode; Q: Int64);
begin
  EmitByte(Ord(O));
  EmitI64(Q);
end;

function TCodeBuf.NewLabel: Integer;
begin
  SetLength(FLabels, Length(FLabels) + 1);
  FLabels[High(FLabels)] := -1;
  Result := High(FLabels);
end;

procedure TCodeBuf.SetLabel(L: Integer);
begin
  FLabels[L] := FLen;
end;

procedure TCodeBuf.Jump(O: TOpcode; L: Integer);
begin
  EmitByte(Ord(O));
  SetLength(FFixups, Length(FFixups) + 1);
  FFixups[High(FFixups)].Pos := FLen;
  FFixups[High(FFixups)].Lbl := L;
  EmitI32(0);
end;

procedure TCodeBuf.Resolve;
var
  I, P, T: Integer;
  Rel: LongInt;
begin
  for I := 0 to High(FFixups) do
  begin
    P := FFixups[I].Pos;
    T := FLabels[FFixups[I].Lbl];
    if T < 0 then raise Exception.Create('Internal error: unresolved label');
    Rel := T - (P + 4);
    FData[P] := Rel and $FF;
    FData[P + 1] := (Rel shr 8) and $FF;
    FData[P + 2] := (Rel shr 16) and $FF;
    FData[P + 3] := (Rel shr 24) and $FF;
  end;
  SetLength(FFixups, 0);
end;

function TCodeBuf.Bytes: TBytes;
begin
  Result := Copy(FData, 0, FLen);
end;

{ disassembler }

function Disassemble(const Code: TBytes; Img: TSvImage): string;
var
  P, Start, K: Integer;
  O: TOpcode;
  Fmt, Args: string;
  C: Char;
  Q: Int64;
  D: Double;
  W: Word;
  SB: TStringBuilder;

  function RdU8: Byte;
  begin
    Result := Code[P];
    Inc(P);
  end;

  function RdU16: Word;
  begin
    Result := Code[P] or (Word(Code[P + 1]) shl 8);
    Inc(P, 2);
  end;

  function RdU32: Cardinal;
  begin
    Result := Cardinal(Code[P]) or (Cardinal(Code[P + 1]) shl 8) or (Cardinal(Code[P + 2]) shl 16) or
      (Cardinal(Code[P + 3]) shl 24);
    Inc(P, 4);
  end;

  function RdI64: Int64;
  var
    Lo, Hi: Cardinal;
  begin
    Lo := RdU32;
    Hi := RdU32;
    Result := Int64(QWord(Lo) or (QWord(Hi) shl 32));
  end;

begin
  SB := TStringBuilder.Create;
  try
    P := 0;
    while P < Length(Code) do
    begin
      Start := P;
      if Code[P] > Ord(High(TOpcode)) then
      begin
        SB.Append(Format('  %6d  ?? %d', [Start, Code[P]])).Append(LineEnding);
        Inc(P);
        Continue;
      end;
      O := TOpcode(RdU8);
      Fmt := OpOperands(O);
      Args := '';
      for K := 1 to Length(Fmt) do
      begin
        C := Fmt[K];
        if Args <> '' then Args := Args + ', ';
        case C of
          'b':
            begin
              W := RdU8;
              if O in [opLoad, opStore, opWrap] then Args := Args + VmTypeName(W)
              else Args := Args + IntToStr(W);
            end;
          'w':
            begin
              W := RdU16;
              Args := Args + IntToStr(W);
              if (O in [opCall, opCallFB]) and (Img <> nil) and (W < Img.Blocks.Count) then
                Args := Args + ' ; ' + Img.Block(W).Name;
            end;
          'u': Args := Args + IntToStr(RdU32);
          'i':
            begin
              Q := LongInt(RdU32);
              if O in [opJmp, opJz, opJnz] then Args := Args + '-> ' + IntToStr(P + Q)
              else Args := Args + IntToStr(Q);
            end;
          'q':
            begin
              Q := RdI64;
              if O = opPushAddr then Args := Args + AddrToText(Q) else Args := Args + IntToStr(Q);
            end;
          'f':
            begin
              Q := RdI64;
              Move(Q, D, 8);
              Args := Args + FloatToStr(D);
            end;
        end;
      end;
      if O in [opAddrInst, opAddrLocal, opAddrNewFrame, opAddrAdd] then
      begin
        Q := StrToInt64(Args);
        Args := Format('%d.%d', [Q div 8, Q mod 8]);
      end;
      SB.Append(Format('  %6d  %-14s %s', [Start, OpName(O), Args])).Append(LineEnding);
    end;
    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

end.
