unit uPlcCompiler;

{ Compiles the project into the runtime's op code (TCProgram).

  STL and LAD end up in the same instruction list: a LAD network is evaluated
  column by column; every cell loads its row's power (opLadLoad), runs the
  element as normal bit logic / box op, and stores the row's result
  (opLadStore). opLadCol then joins the rows that are linked on the right edge
  of the column (OR of the branch) and hands the power to the next column.

  Operands are resolved here: absolute addresses, "Tags", "DB".Var(.Member)
  with [index] for arrays, DB numbers / names, constants and status bits
  (BR OV OS ==0 <>0 >0 <0 >=0 <=0 UO). Ranges are checked against the CPU
  model, optimized DBs refuse absolute access, the S7-1200 refuses STL and S5
  timers / counters, ENT / LEAVE only exist on the S7-400.

  Every op knows its network and line (STL) / cell (LAD) for the monitor and
  the diagnostic buffer, and its time class for the model cycle time. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, StrUtils, uPlcTypes, uPlcProject, uObCatalog, uFbd;

type
  TOpCode = (
    opNop,
    // bit logic
    opA, opAN, opO, opON, opX, opXN, opOAlone,
    opAParen, opANParen, opOParen, opONParen, opXParen, opXNParen, opParenClose,
    opAssign, opS, opR, opNOT, opSET, opCLR, opSAVE, opFP, opFN, opCoilNeg,
    // S5 timers and counters
    opSP, opSE, opSD, opSS, opSF, opFR, opCU, opCD, opSC,
    // load / transfer
    opL, opLC, opT, opLDBNO, opLDBLG, opLDINO, opLDILG,
    opTAK, opPUSH, opPOP, opENT, opLEAVE, opCAW, opCAD, opINC, opDEC,
    // arithmetic
    opAddI, opSubI, opMulI, opDivI, opAddD, opSubD, opMulD, opDivD, opMOD,
    opAddR, opSubR, opMulR, opDivR, opAddConst,
    opABS, opSQRT, opSQR, opLN, opEXP, opSIN, opCOS, opTAN, opASIN, opACOS, opATAN,
    opNEGI, opNEGD, opNEGR, opINVI, opINVD,
    opITD, opDTR, opITB, opBTI, opDTB, opBTD, opRND, opTRUNC, opRNDP, opRNDM,
    // compare (Sub = TCmpOp)
    opCmpI, opCmpD, opCmpR,
    // word logic (Opd = constant or none: ACCU2)
    opAW, opOW, opXOW, opAD, opOD, opXOD,
    // shift / rotate (Sub = count, -1 = ACCU2-LL)
    opSLW, opSRW, opSLD, opSRD, opSSI, opSSD, opRLD, opRRD,
    // jumps (Ext = target op)
    opJU, opJC, opJCN, opJCB, opJNB, opJBI, opJNBI, opJO, opJOS, opJZ, opJN, opJP, opJM,
    opJPZ, opJMZ, opJUO, opLOOP,
    // blocks (Ext = block index)
    opBE, opBEU, opBEC, opCALL, opCC, opOPN, opOPNDI,
    // LAD
    opNetBegin, opLadBegin, opLadLoad, opLadStore, opLadCol,
    opPContact, opNContact,
    opTON, opTOF, opTP, opTONR, opCTU, opCTD, opCTUD,
    opBoxCmp, opBoxMove, opBoxMath, opNormX, opScaleX,
    opBoxRange,  // IN_RANGE / OUT_RANGE (Sub 1): MIN, VAL, MAX of DType
    opBoxConv,   // CONV / ROUND / TRUNC / CEIL / FLOOR: Sub = mode shl 8 + the OUT type, DType the IN type
    // SCL: a value stack (Double holds every S7 value exactly up to 32 bit)
    opSPush, opSPushK, opSPushIdx, opSStore, opSStoreIdx, opSBin, opSUn, opSTern,
    opSJmp, opSJz, opSPop, opSSetReg, opSGetReg, opSTimer, opSCounter, opSIndex, opSCopy,
    // SCL strings: a stack of their own; Sub 1 = WString, Ext 1 = a variable index (its offset on the value
    // stack), Hi = the max length of the target
    opStrPush, opStrPushK, opStrStore, opStrOp,
    // SCL inside LAD / STL (the boxes of SCL functions): the RLO onto the stack, the stack into the RLO
    opSRloPush, opSRloSet,
    opCALLFB,    // Ext = FB, Opd = the instance (arDB: an instance DB, arDI: a multi-instance), Sub 1 = on RLO
    opCallIf,    // LAD CALL box with parameters: RLO = 0 skips to Ext (ENO = 0)
    opCallEnd);  // ... and after the call ENO = 1

  TOperandKind = (okNone, okAddr, okConst, okStatus, okBlock);

  TOperand = record
    Kind: TOperandKind;
    A: TAddr;
    C: TConst;
    DType: TDataType;   // declared type (tags, DB variables), dtNone for plain addresses
    Status: Integer;    // okStatus: 0 BR 1 OV 2 OS 3 ==0 4 <>0 5 >0 6 <0 7 >=0 8 <=0 9 UO
    Block: Integer;     // okBlock: index in TCProgram.Blocks
    Text: string;
  end;

  TTimeCat = (tcBit, tcWord, tcFix, tcFloat);

  TOp = record
    Code: TOpCode;
    Sub: Integer;
    Opd: TOperand;
    Ext: Integer;       // jump target / block / first box parameter / ladder column table
    Net: Integer;       // network index
    Line: Integer;      // STL line or LAD cell index (r * Cols + c)
    Mon: Integer;       // monitor slot, -1 = none
    Cat: TTimeCat;
    Weight: Byte;       // instruction count for the model time
    DType: TDataType;   // box type; SCL: the value type of the op
    K: Double;          // SCL: constant
    KI: Int64;          // SCL: the exact constant of a 64 bit type
    Lo, Hi: Integer;    // SCL opSIndex: array bounds (Sub = element stride in bits)
  end;

  TMonSlot = record
    Stamp: LongWord;    // cycle number of the last execution (0 = never)
    Status: Word;       // bit 0 RLO, 1 STA, 2 /FC, 3 OR, 4 OS, 5 OV, 6 CC0, 7 CC1, 8 BR
    Accu1, Accu2: LongWord;
    DB: Integer;
    Val: Double;        // SCL: the value stored / tested on the line
    DT: TDataType;
  end;
  PMonSlot = ^TMonSlot;

  TLadGroups = array[0..MaxLadRows - 1] of ShortInt;   // group id of a row, -1 = none

  TNetInfo = record
    Kind: TNetKind;
    MonBase: Integer;   // STL: slot = MonBase + line; LAD: MonBase + cell * 2 (+0 in, +1 out)
    Lines: Integer;
    Rows: Integer;
    Cols: Integer;      // LAD: columns (the cell index is r * Cols + c)
    FirstOp: Integer;
    { LAD: resolved operands of each cell, for the monitor (Opnd, P0..P4) }
    CellOps: array of array[0..5] of TOperand;
    { FBD / CFC: the SCL they were compiled as, the box (its Id) of every line (the monitor: the value of a box
      is the one of its first line with :=) }
    Scl: array of string;
    LineNode: TIntArray;
  end;

  { TCBlock }

  TCBlock = class
  public
    Kind: TBlockKind;
    Number: Integer;
    Name: string;
    Ops: array of TOp;
    Params: array of TOperand;
    LadTables: array of TLadGroups;
    Nets: array of TNetInfo;
    Mon: array of TMonSlot;
    CodeBytes: Integer;   // estimate of the work memory
    { an OB: its start information in the local data (Key: ObStartKey of the variable) }
    StartInfo: array of record
      Key: string;
      Ofs, Bit: Integer;
      DType: TDataType;
    end;
    function Title: string;
  end;

  { an OB of the program and what starts it }
  TCObRef = record
    BI, Number: Integer;
    Event: TObEvent;
    Prio: Integer;
    CycleMs, PhaseMs: Integer;          // cyclic interrupt
    TrigOk: Boolean;                    // hardware interrupt: its input bit
    TrigOfs, TrigBit, TrigEdge: Integer;
    TodOk, TodActive: Boolean;          // time of day
    TodStart: TDateTime;
    TodMode: Integer;
  end;

  TCDb = record
    Number: Integer;
    Name: string;
    Size: Integer;
    Optimized: Boolean;
    Init: array of Byte;
    RetainMask: array of Byte;   // 1 = keep the byte on a restart (S7-1200 retain)
  end;

  TCompileMsg = record
    Block: string;
    Net, Line: Integer;   // 1-based, 0 = none
    Text: string;
    IsError: Boolean;
  end;

  { TCProgram }

  TCProgram = class
  public
    ModelIdx: Integer;
    Family: TCpuFamily;
    Blocks: array of TCBlock;
    DBs: array of TCDb;
    Msgs: array of TCompileMsg;
    ErrorCount, WarnCount: Integer;
    OB1, OBCyc, OB100: Integer;   // block indexes, -1 = none
    Obs: array of TCObRef;         // every OB, by number
    CyclicMs: Integer;
    ClockByte: Integer;
    SysByte: Integer;              // system memory byte, -1 = off
    CodeBytes, DataBytes: Integer;
    destructor Destroy; override;
    function FindBlock(AKind: TBlockKind; ANumber: Integer): Integer;
  end;

  { TResolver: operands of the offline project }

  { a variable on its way through a path: "DB".Arr[2].Member.Sub }
  TVarInfo = record
    A: TAddr;             // the start of the variable (array: its first element)
    T: TDataType;
    Udt: TDataBlock;      // T = dtStruct
    IsArray: Boolean;
    Lo, Hi: Integer;
    Dims: TArrDims;       // more than one dimension: Lo..Hi = 0..n-1
    TypeText: string;     // as declared (TON_TIME, CTU_INT ...)
  end;

  TResolver = class
  private
    FProject: TPlcProject;
    FModel: TCpuModel;
    FTemps: TStrings;
    FIface: TDataBlock;
  public
    constructor Create(AProject: TPlcProject);
    { "DB".Var..., "Tag" or #temp up to the end of S; arrays and structs are allowed as the result }
    function ResolveVar(const S: string; out V: TVarInfo; out Err: string): Boolean;
    { follows [n] and .Member from V }
    function Walk(var V: TVarInfo; Rest: string; out Err: string): Boolean;
    { VAR_TEMP of the block being compiled: name=type, object = bit offset in L }
    property Temps: TStrings read FTemps write FTemps;
    { the interface of the block being compiled: #Input, #Static ... of an FB are in the instance (DI) }
    property Iface: TDataBlock read FIface write FIface;
    { Kind of operand wanted: bits, words etc. are checked by the caller }
    function Resolve(const S: string; out Opd: TOperand; out Err: string; AllowConst: Boolean = True): Boolean;
    function ResolveAddr(const S: string; out Opd: TOperand; out Err: string): Boolean;
    function CheckRange(const A: TAddr; out Err: string): Boolean;
    function SymbolOf(const A: TAddr): string;   // tag name or DB variable, '' when none
    property Project: TPlcProject read FProject;
  end;

function Compile(AProject: TPlcProject): TCProgram;
function OperandSizeBytes(const O: TOperand): Integer;
function IsWordish(const O: TOperand; Bytes: Integer): Boolean;

implementation

const
  StatusNames: array[0..9] of string = ('BR', 'OV', 'OS', '==0', '<>0', '>0', '<0', '>=0', '<=0', 'UO');

{ TCBlock }

function TCBlock.Title: string;
begin
  case Kind of
    bkOB: Result := 'OB';
    bkFB: Result := 'FB';
  else
    Result := 'FC';
  end;
  Result := Result + IntToStr(Number);
end;

{ TCProgram }

destructor TCProgram.Destroy;
var
  I: Integer;
begin
  for I := 0 to High(Blocks) do Blocks[I].Free;
  inherited Destroy;
end;

function TCProgram.FindBlock(AKind: TBlockKind; ANumber: Integer): Integer;
var
  I: Integer;
begin
  for I := 0 to High(Blocks) do
    if (Blocks[I].Kind = AKind) and (Blocks[I].Number = ANumber) then Exit(I);
  Result := -1;
end;

function OperandSizeBytes(const O: TOperand): Integer;
begin
  Result := 0;
  case O.Kind of
    okAddr:
      case O.A.Size of
        osBit: Result := 0;
        osByte: Result := 1;
        osWord: Result := 2;
        osDWord: Result := 4;
      end;
    okConst:
      case O.C.Size of
        osBit: Result := 0;
        osByte: Result := 1;
        osWord: Result := 2;
        osDWord: Result := 4;
      end;
  end;
end;

function IsWordish(const O: TOperand; Bytes: Integer): Boolean;
begin
  Result := (O.Kind = okAddr) and (OperandSizeBytes(O) = Bytes) and not (O.A.Area in [arT, arC]);
end;

{ TResolver }

constructor TResolver.Create(AProject: TPlcProject);
begin
  inherited Create;
  FProject := AProject;
  FModel := Models[AProject.ModelIdx];
end;

function TResolver.CheckRange(const A: TAddr; out Err: string): Boolean;
var
  Sz, Lim: Integer;
  D: TDataBlock;
begin
  Err := '';
  case A.Size of
    osBit, osByte: Sz := 1;
    osWord: Sz := 2;
  else
    Sz := 4;
  end;
  Lim := MaxInt;
  case A.Area of
    arI, arPI: Lim := FModel.InBytes;
    arQ, arPQ: Lim := FModel.OutBytes;
    arM: Lim := FModel.MBytes;
    arL: Lim := 256;
    arT:
      begin
        if FModel.Timers = 0 then
        begin
          Err := FamilyNames[FModel.Family] + ' has no S5 timers: use TON / TOF / TP';
          Exit(False);
        end;
        if A.Num >= FModel.Timers then
        begin
          Err := Format('timer T%d does not exist (T0..T%d)', [A.Num, FModel.Timers - 1]);
          Exit(False);
        end;
        Exit(True);
      end;
    arC:
      begin
        if FModel.Counters = 0 then
        begin
          Err := FamilyNames[FModel.Family] + ' has no S5 counters: use CTU / CTD / CTUD';
          Exit(False);
        end;
        if A.Num >= FModel.Counters then
        begin
          Err := Format('counter C%d does not exist (C0..C%d)', [A.Num, FModel.Counters - 1]);
          Exit(False);
        end;
        Exit(True);
      end;
    arDB:
      if A.DB > 0 then
      begin
        D := FProject.FindDB(A.DB);
        if D = nil then
        begin
          Err := Format('DB%d does not exist', [A.DB]);
          Exit(False);
        end;
        Lim := D.Size;
      end;
  end;
  if A.Ofs + Sz > Lim then
  begin
    Err := Format('address out of range (%s has %d bytes)', [AreaNames[A.Area], Lim]);
    Exit(False);
  end;
  Result := True;
end;

function TResolver.ResolveAddr(const S: string; out Opd: TOperand; out Err: string): Boolean;
begin
  Result := Resolve(S, Opd, Err, False);
  if Result and (Opd.Kind <> okAddr) then
  begin
    Err := 'an address is needed here';
    Result := False;
  end;
end;

function TResolver.Resolve(const S: string; out Opd: TOperand; out Err: string; AllowConst: Boolean): Boolean;
var
  T, Nm, Rest, Mem, IdxS: string;
  P, Ti, VI, Idx, ElemSz, Q: Integer;
  D: TDataBlock;
  V: TDbVar;
  A: TAddr;
  Lo, Hi, I: Integer;
  Ty: TDataType;
  VInf: TVarInfo;

  { a DB variable or a temp: its path must end at an elementary value }
  function FromVar: Boolean;
  begin
    Result := False;
    if not ResolveVar(T, VInf, Err) then Exit;
    if VInf.IsArray then
      Err := T + ' is an array: index [n] expected'
    else if VInf.T = dtStruct then
      Err := Format('%s is a struct (%s): a member expected', [T, VInf.Udt.Name])
    else
    begin
      Opd.Kind := okAddr;
      Opd.A := VInf.A;
      Opd.DType := VInf.T;
      Result := True;
    end;
  end;

begin
  Result := False;
  Err := '';
  FillChar(Opd, SizeOf(Opd), 0);
  Opd.Kind := okNone;
  Opd.Block := -1;
  T := Trim(S);
  Opd.Text := T;
  if T = '' then
  begin
    Err := 'operand missing';
    Exit;
  end;
  // status bits
  for I := 0 to High(StatusNames) do
    if UpperCase(T) = StatusNames[I] then
    begin
      Opd.Kind := okStatus;
      Opd.Status := I;
      Exit(True);
    end;
  // symbols: "Name" or "Name".Member...
  Nm := '';
  Rest := '';
  if T[1] = '"' then
  begin
    P := PosEx('"', T, 2);
    if P = 0 then
    begin
      Err := 'closing " missing';
      Exit;
    end;
    Nm := Copy(T, 2, P - 2);
    Rest := Copy(T, P + 1, MaxInt);
  end
  else if not ParseAddr(T, A, Err) and (Length(T) > 0) and (T[1] in ['A'..'Z', 'a'..'z', '_']) then
  begin
    // unquoted symbol: Name or Name.Member (not an address, not a constant)
    P := Pos('.', T);
    if P > 0 then
    begin
      Nm := Copy(T, 1, P - 1);
      Rest := Copy(T, P, MaxInt);
    end
    else
      Nm := T;
    if (FProject.FindTag(Nm) < 0) and (FProject.FindDBByName(Nm) = nil) then
      Nm := '';
  end;
  if Nm <> '' then
  begin
    Ti := FProject.FindTag(Nm);
    if (Ti >= 0) and (Rest = '') then
    begin
      if not ParseAddr(FProject.Tags[Ti].Address, A, Err) then
      begin
        Err := 'tag "' + Nm + '": ' + Err;
        Exit;
      end;
      Opd.Kind := okAddr;
      Opd.A := A;
      if not ParseDataType(FProject.Tags[Ti].TypeText, Opd.DType, Lo, Hi) then Opd.DType := dtNone;
      Result := CheckRange(A, Err);
      Exit;
    end;
    D := FProject.FindDBByName(Nm);
    if D = nil then
    begin
      if Ti >= 0 then Err := 'tag "' + Nm + '" has no members'
      else Err := 'unknown symbol "' + Nm + '"';
      Exit;
    end;
    D.Layout;
    if Rest = '' then
    begin
      Opd.Kind := okBlock;
      Opd.A := MakeAddr(arDB, osByte, 0, 0, D.Number);
      Opd.Block := D.Number;
      Exit(True);
    end;
    Exit(FromVar);
  end;
  // VAR_TEMP: #name...
  if (T[1] = '#') and (FTemps <> nil) then Exit(FromVar);
  // absolute address
  if ParseAddr(T, A, Err) then
  begin
    Opd.Kind := okAddr;
    Opd.A := A;
    if (A.Area = arDB) and (A.DB > 0) then
    begin
      D := FProject.FindDB(A.DB);
      if (D <> nil) and D.Optimized then
      begin
        Err := Format('DB%d "%s" is optimized: only symbolic access ("%s".Var)', [D.Number, D.Name, D.Name]);
        Exit;
      end;
      if D <> nil then D.Layout;
    end;
    Result := CheckRange(A, Err);
    Exit;
  end;
  // DB number for OPN / instance
  if (Length(T) >= 3) and SameText(Copy(T, 1, 2), 'DB') and TryStrToInt(Copy(T, 3, MaxInt), I) then
  begin
    Opd.Kind := okBlock;
    Opd.Block := I;
    Opd.A := MakeAddr(arDB, osByte, 0, 0, I);
    if FProject.FindDB(I) = nil then
    begin
      Err := Format('DB%d does not exist', [I]);
      Exit;
    end;
    Exit(True);
  end;
  if (Length(T) >= 3) and SameText(Copy(T, 1, 2), 'DI') and TryStrToInt(Copy(T, 3, MaxInt), I) then
  begin
    Opd.Kind := okBlock;
    Opd.Block := I;
    Opd.A := MakeAddr(arDI, osByte, 0, 0, I);
    if FProject.FindDB(I) = nil then
    begin
      Err := Format('DB%d does not exist', [I]);
      Exit;
    end;
    Exit(True);
  end;
  if AllowConst and ParseConst(T, Opd.C) then
  begin
    Opd.Kind := okConst;
    Err := '';
    Exit(True);
  end;
  if Err = '' then Err := 'unknown operand "' + T + '"';
end;

function TResolver.ResolveVar(const S: string; out V: TVarInfo; out Err: string): Boolean;
var
  T, Nm, Rest, Mem: string;
  P, K: Integer;
  D: TDataBlock;
  Dv: TDbVar;
  Lo, Hi: Integer;
begin
  Result := False;
  Err := '';
  FillChar(V, SizeOf(V), 0);
  T := Trim(S);
  if T = '' then
  begin
    Err := 'operand missing';
    Exit;
  end;
  if T[1] = '#' then
  begin
    P := 2;
    while (P <= Length(T)) and not (T[P] in ['.', '[']) do Inc(P);
    Nm := Copy(T, 2, P - 2);
    Rest := Copy(T, P, MaxInt);
    if FTemps <> nil then K := FTemps.IndexOfName(UpperCase(Nm)) else K := -1;
    if (K < 0) and (FIface <> nil) then
    begin
      // a parameter or static of an FB: in the instance data, the DI register + the instance offset;
      // a parameter of an FC: in its local data, before the Temps
      K := FIface.FindVar(Nm);
      if (K >= 0) and (FIface.Vars[K].Section <> vsTemp) then
      begin
        Dv := FIface.Vars[K];
        if not Dv.Valid then
        begin
          Err := Format('#%s: unknown data type %s', [Nm, Dv.TypeText]);
          Exit;
        end;
        if FIface.IsFC then V.A := MakeAddr(arL, TypeOpSize(Dv.DType), Dv.Ofs, Dv.Bit)
        else V.A := MakeAddr(arDI, TypeOpSize(Dv.DType), Dv.Ofs, Dv.Bit, 0);
        V.T := Dv.DType;
        V.Udt := Dv.Udt;
        V.IsArray := Dv.IsArray;
        V.Lo := Dv.Lo;
        V.Hi := Dv.Hi;
        V.Dims := Dv.Dims;
        V.TypeText := Dv.TypeText;
        Result := Walk(V, Rest, Err);
        Exit;
      end;
      K := -1;
    end;
    if K < 0 then
    begin
      Err := '#' + Nm + ' is not declared (VAR_TEMP ' + Nm + ' : Int; END_VAR, or in the interface)';
      Exit;
    end;
    if not FProject.ParseVarType(FTemps.ValueFromIndex[K], V.T, Lo, Hi, V.Udt) then
    begin
      Err := '#' + Nm + ': unknown data type ' + FTemps.ValueFromIndex[K];
      Exit;
    end;
    V.IsArray := Hi >= Lo;
    V.Lo := Lo;
    V.Hi := Hi;
    V.TypeText := FTemps.ValueFromIndex[K];
    if Length(ArrayDims(V.TypeText)) > 1 then V.Dims := ArrayDims(V.TypeText);
    V.A := MakeAddr(arL, TypeOpSize(V.T), PtrInt(FTemps.Objects[K]) div 8, PtrInt(FTemps.Objects[K]) mod 8);
    Result := Walk(V, Rest, Err);
    Exit;
  end;
  if T[1] = '"' then
  begin
    P := PosEx('"', T, 2);
    if P = 0 then
    begin
      Err := 'closing " missing';
      Exit;
    end;
    Nm := Copy(T, 2, P - 2);
    Rest := Copy(T, P + 1, MaxInt);
  end
  else
  begin
    P := 1;
    while (P <= Length(T)) and not (T[P] in ['.', '[']) do Inc(P);
    Nm := Copy(T, 1, P - 1);
    Rest := Copy(T, P, MaxInt);
  end;
  D := FProject.FindDBByName(Nm);
  if D = nil then
  begin
    Err := 'unknown data block "' + Nm + '"';
    Exit;
  end;
  D.Layout;
  if (Rest = '') or (Rest[1] <> '.') then
  begin
    Err := '. expected after "' + Nm + '"';
    Exit;
  end;
  Delete(Rest, 1, 1);
  P := 1;
  while (P <= Length(Rest)) and not (Rest[P] in ['.', '[']) do Inc(P);
  Mem := Copy(Rest, 1, P - 1);
  Rest := Copy(Rest, P, MaxInt);
  K := D.FindVar(Mem);
  if K < 0 then
  begin
    Err := Format('"%s" has no variable %s', [D.Name, Mem]);
    Exit;
  end;
  Dv := D.Vars[K];
  if not Dv.Valid then
  begin
    Err := Format('%s: unknown data type %s', [Mem, Dv.TypeText]);
    Exit;
  end;
  V.A := MakeAddr(arDB, TypeOpSize(Dv.DType), Dv.Ofs, Dv.Bit, D.Number);
  V.T := Dv.DType;
  V.Udt := Dv.Udt;
  V.IsArray := Dv.IsArray;
  V.Lo := Dv.Lo;
  V.Hi := Dv.Hi;
  V.Dims := Dv.Dims;
  V.TypeText := Dv.TypeText;
  Result := Walk(V, Rest, Err);
end;

{ the element number of "i, j, .." in an array of more dimensions }
function FlatIndex(const Dims: TArrDims; const Txt: string; out Idx: Integer; out Err: string): Boolean;
var
  L: TStringList;
  K, V: Integer;
begin
  Result := False;
  Idx := 0;
  L := TStringList.Create;
  try
    L.CommaText := StringReplace(Txt, ' ', '', [rfReplaceAll]);
    if L.Count <> Length(Dims) then
    begin
      Err := Format('%d indexes expected [%s]', [Length(Dims), Txt]);
      Exit;
    end;
    for K := 0 to High(Dims) do
    begin
      if not TryStrToInt(L[K], V) then
      begin
        Err := 'constant array index expected';
        Exit;
      end;
      if (V < Dims[K].Lo) or (V > Dims[K].Hi) then
      begin
        Err := Format('index %d outside [%d..%d]', [V, Dims[K].Lo, Dims[K].Hi]);
        Exit;
      end;
      Idx := Idx * (Dims[K].Hi - Dims[K].Lo + 1) + V - Dims[K].Lo;
    end;
  finally
    L.Free;
  end;
  Result := True;
end;

function TResolver.Walk(var V: TVarInfo; Rest: string; out Err: string): Boolean;
var
  P, Q, Idx, I, BitOfs: Integer;
  Mem: string;
  Sub, VT: TDataType;
  OPv, OCv, OEt, OBits: Integer;
  M: TDbVar;
begin
  Result := False;
  Err := '';
  while Rest <> '' do
  begin
    if Rest[1] = '[' then
    begin
      if not V.IsArray then
      begin
        Err := 'not an array: ' + Rest;
        Exit;
      end;
      Q := Pos(']', Rest);
      if Q = 0 then
      begin
        Err := '] missing';
        Exit;
      end;
      if Length(V.Dims) > 1 then
      begin
        // [i, j, ..]: row by row, the last index fastest
        if not FlatIndex(V.Dims, Copy(Rest, 2, Q - 2), Idx, Err) then Exit;
      end
      else if not TryStrToInt(Trim(Copy(Rest, 2, Q - 2)), Idx) then
      begin
        Err := 'constant array index expected';
        Exit;
      end;
      V.Dims := nil;
      Rest := Copy(Rest, Q + 1, MaxInt);
      if (Idx < V.Lo) or (Idx > V.Hi) then
      begin
        Err := Format('index %d outside [%d..%d]', [Idx, V.Lo, V.Hi]);
        Exit;
      end;
      if V.T = dtBool then
      begin
        BitOfs := V.A.Bit + Idx - V.Lo;
        V.A.Ofs := V.A.Ofs + BitOfs div 8;
        V.A.Bit := BitOfs mod 8;
      end
      else
        V.A.Ofs := V.A.Ofs + (Idx - V.Lo) * ElemStride(V.T, V.Udt);
      V.IsArray := False;
      Continue;
    end;
    if Rest[1] <> '.' then
    begin
      Err := 'unexpected "' + Rest + '"';
      Exit;
    end;
    if V.IsArray then
    begin
      Err := 'an array: index [n] expected before ' + Rest;
      Exit;
    end;
    P := 2;
    while (P <= Length(Rest)) and not (Rest[P] in ['.', '[']) do Inc(P);
    Mem := Copy(Rest, 2, P - 2);
    if (Length(Mem) >= 2) and (Mem[1] = '"') then Mem := Copy(Mem, 2, Length(Mem) - 2);
    Rest := Copy(Rest, P, MaxInt);
    if V.T = dtStruct then
    begin
      // a member of a PLC data type
      V.Udt.Layout;
      I := V.Udt.FindVar(Mem);
      if (I >= 0) and V.Udt.IsIface and (V.Udt.Vars[I].Section = vsTemp) then I := -1;
      if I < 0 then
      begin
        Err := Format('%s has no member %s', [V.Udt.Name, Mem]);
        Exit;
      end;
      M := V.Udt.Vars[I];
      if not M.Valid then
      begin
        Err := Format('%s.%s: unknown data type %s', [V.Udt.Name, Mem, M.TypeText]);
        Exit;
      end;
      V.A := MakeAddr(V.A.Area, TypeOpSize(M.DType), V.A.Ofs + M.Ofs, M.Bit, V.A.DB);
      V.T := M.DType;
      V.Udt := M.Udt;
      V.IsArray := M.IsArray;
      V.Lo := M.Lo;
      V.Hi := M.Hi;
      V.Dims := M.Dims;
      V.TypeText := M.TypeText;
      Continue;
    end;
    // members of IEC_TIMER / IEC_COUNTER
    Mem := UpperCase(Mem);
    Sub := dtNone;
    IecOffsets(V.Udt, V.T = dtIECTimer, OPv, OCv, OEt, OBits, VT);
    if V.T = dtIECTimer then
    begin
      // IEC_TIMER / TON_TIME: PT 0, ET 4, IN 8.0, Q 8.1; TON_LTIME: PT 0, ET 8, IN 16.0, Q 16.1
      if Mem = 'PT' then begin Sub := VT; V.A.Size := osDWord; end
      else if Mem = 'ET' then begin Sub := VT; V.A.Size := osDWord; V.A.Ofs := V.A.Ofs + OEt; end
      else if Mem = 'IN' then begin Sub := dtBool; V.A.Size := osBit; V.A.Ofs := V.A.Ofs + OBits; V.A.Bit := 0; end
      else if Mem = 'Q' then begin Sub := dtBool; V.A.Size := osBit; V.A.Ofs := V.A.Ofs + OBits; V.A.Bit := 1; end;
    end
    else if V.T = dtIECCounter then
    begin
      I := AnsiIndexStr(Mem, ['CU', 'CD', 'R', 'LD', 'QU', 'QD']);
      if I >= 0 then
      begin
        Sub := dtBool;
        V.A.Size := osBit;
        V.A.Bit := I;
      end
      else if Mem = 'Q' then begin Sub := dtBool; V.A.Size := osBit; V.A.Bit := 4; end
      else if Mem = 'PV' then begin Sub := VT; V.A.Size := TypeOpSize(VT); V.A.Ofs := V.A.Ofs + OPv; end
      else if Mem = 'CV' then begin Sub := VT; V.A.Size := TypeOpSize(VT); V.A.Ofs := V.A.Ofs + OCv; end;
    end;
    if Sub = dtNone then
    begin
      Err := Format('%s has no member %s', [DataTypeNames[V.T], Mem]);
      Exit;
    end;
    V.T := Sub;
    V.Udt := nil;
  end;
  Result := True;
end;

function TResolver.SymbolOf(const A: TAddr): string;
var
  I, J: Integer;
  B: TAddr;
  E: string;
  D: TDataBlock;
begin
  Result := '';
  for I := 0 to High(FProject.Tags) do
    if ParseAddr(FProject.Tags[I].Address, B, E) and SameAddr(A, B) then
      Exit('"' + FProject.Tags[I].Name + '"');
  if (A.Area = arDB) and (A.DB > 0) then
  begin
    D := FProject.FindDB(A.DB);
    if D = nil then Exit;
    D.Layout;
    for J := 0 to High(D.Vars) do
      if D.Vars[J].Valid and not D.Vars[J].IsArray and (D.Vars[J].Ofs = A.Ofs) and
        ((A.Size <> osBit) or (D.Vars[J].DType = dtBool) and (D.Vars[J].Bit = A.Bit)) and
        (TypeOpSize(D.Vars[J].DType) = A.Size) then
        Exit('"' + D.Name + '".' + D.Vars[J].Name);
  end;
end;

{ ====================================================================== }
{ the compiler                                                           }
{ ====================================================================== }

type

  { TCompiler }

  TCompiler = class
  private
    FProject: TPlcProject;
    FModel: TCpuModel;
    FRes: TResolver;
    FProg: TCProgram;
    FBlock: TCBlock;
    FSrc: TBlock;
    FNet, FLine: Integer;
    FLabels: TStringList;     // label=op index
    FFixups: TStringList;     // label=op index of the jump
    FTemps: TStringList;      // SCL VAR_TEMP of the block: name=type, object = L offset
    FTempOfs: Integer;
    FInline: Boolean;         // CompileSclText: SCL in LAD / STL
    FInlineWhat: string;
    FConsts: TStringList;     // SCL VAR CONSTANT of the block: name, object = index in FConstV / FConstT
    FConstV: array of Double;
    FConstI: array of Int64;  // the exact value of a 64 bit constant
    FConstT: array of TDataType;
    procedure CompileScl(N: TNetwork);
    { SCL code inside a LAD / STL network (a box of an SCL function, CALL SEL ..): no monitor slots, the
      messages on the cell / line with What before them; __RLO__ is the RLO; True without an error }
    function CompileSclText(const Code, What: string): Boolean;
    function StlSclCall(const Tgt: string; const Names, Acts: array of string): Boolean;
    procedure Msg(const AText: string; AErr: Boolean = True);
    function Emit(ACode: TOpCode; ACat: TTimeCat; AWeight: Integer = 1): Integer;
    procedure CompileStl(N: TNetwork);
    procedure CompileStlLine(const ALine: string);
    procedure CompileLad(N: TNetwork);
    procedure CompileBlock(B: TBlock; Index: Integer);
    procedure BuildDBs;
    function OperandOf(const S: string; out Opd: TOperand; AllowConst: Boolean = True): Boolean;
    function BlockRef(const S: string; out Index: Integer): Boolean;
    { a call with a parameter list (STL CALL lines, a LAD CALL box): Names[i] := Acts[i] }
    function ParamCall(Blk: TBlock; BI: Integer; const InstText: string; const Inst: TOperand;
      const Names, Acts: array of string; const Lines: array of Integer; Cond: Boolean): Boolean;
    function FCRef(const S: string): TBlock;
    procedure CompileStlCall(const Tgt: string; const Names, Acts: array of string; const Lines: array of Integer);
    { "Inst_DB", DB10, FB1, DB10, #inst: the FB and its instance; False with Err = '' when S is no FB call }
    function FBInstance(const S: string; out BI: Integer; out Inst: TOperand; out Err: string): Boolean;
    function AddParam(const Opd: TOperand): Integer;
  public
    constructor Create(AProject: TPlcProject);
    destructor Destroy; override;
    function Run: TCProgram;
  end;

constructor TCompiler.Create(AProject: TPlcProject);
begin
  inherited Create;
  FProject := AProject;
  FModel := Models[AProject.ModelIdx];
  FRes := TResolver.Create(AProject);
  FLabels := TStringList.Create;
  FFixups := TStringList.Create;
  FTemps := TStringList.Create;
  FRes.Temps := FTemps;
  FConsts := TStringList.Create;
end;

destructor TCompiler.Destroy;
begin
  FRes.Free;
  FLabels.Free;
  FFixups.Free;
  FTemps.Free;
  FConsts.Free;
  inherited Destroy;
end;

procedure TCompiler.Msg(const AText: string; AErr: Boolean);
var
  N: Integer;
begin
  N := Length(FProg.Msgs);
  SetLength(FProg.Msgs, N + 1);
  if FSrc <> nil then FProg.Msgs[N].Block := FSrc.Title else FProg.Msgs[N].Block := '';
  FProg.Msgs[N].Net := FNet + 1;
  FProg.Msgs[N].Line := FLine + 1;
  if FInline and (FInlineWhat <> '') then FProg.Msgs[N].Text := FInlineWhat + ': ' + AText
  else FProg.Msgs[N].Text := AText;
  FProg.Msgs[N].IsError := AErr;
  if AErr then Inc(FProg.ErrorCount) else Inc(FProg.WarnCount);
end;

function TCompiler.Emit(ACode: TOpCode; ACat: TTimeCat; AWeight: Integer): Integer;
begin
  Result := Length(FBlock.Ops);
  SetLength(FBlock.Ops, Result + 1);
  FillChar(FBlock.Ops[Result], SizeOf(TOp), 0);
  FBlock.Ops[Result].Code := ACode;
  FBlock.Ops[Result].Cat := ACat;
  FBlock.Ops[Result].Weight := AWeight;
  FBlock.Ops[Result].Net := FNet;
  FBlock.Ops[Result].Line := FLine;
  FBlock.Ops[Result].Mon := -1;
  FBlock.Ops[Result].Ext := -1;
  FBlock.Ops[Result].Opd.Block := -1;
end;

function TCompiler.AddParam(const Opd: TOperand): Integer;
begin
  Result := Length(FBlock.Params);
  SetLength(FBlock.Params, Result + 1);
  FBlock.Params[Result] := Opd;
end;

function TCompiler.OperandOf(const S: string; out Opd: TOperand; AllowConst: Boolean): Boolean;
var
  E: string;
begin
  Result := FRes.Resolve(S, Opd, E, AllowConst);
  if not Result then Msg(E);
end;

{ FC1 / "FC name" / name: index in FProg.Blocks (all blocks exist already) }
function TCompiler.BlockRef(const S: string; out Index: Integer): Boolean;
var
  T: string;
  I, N: Integer;
begin
  Result := False;
  Index := -1;
  T := Trim(S);
  if (T <> '') and (T[1] = '"') then T := StringReplace(T, '"', '', [rfReplaceAll]);
  if (Length(T) > 2) and SameText(Copy(T, 1, 2), 'FC') and TryStrToInt(Copy(T, 3, MaxInt), N) then
    Index := FProg.FindBlock(bkFC, N)
  else
    for I := 0 to High(FProg.Blocks) do
      if (FProg.Blocks[I].Kind = bkFC) and SameText(FProg.Blocks[I].Name, T) then Index := I;
  if Index < 0 then
  begin
    if FProject.FindFB(S) <> nil then
      Msg(Format('%s is an FB: call it with an instance ("Inst_DB"(...), #inst(...), CALL FB1, DB10)', [S]))
    else if FProject.FindDBByName(T) <> nil then
      Msg(Format('DB "%s" is a global DB, no instance of an FB', [T]))
    else
      Msg('block ' + S + ' does not exist');
    Exit;
  end;
  // STL / LAD calls pass no parameters (SCL compiles its FC calls itself)
  for I := 0 to High(FProject.FindBlock(bkFC, FProg.Blocks[Index].Number).Iface.Vars) do
    if FProject.FindBlock(bkFC, FProg.Blocks[Index].Number).Iface.Vars[I].Section in [vsInput, vsOutput, vsInOut, vsReturn] then
    begin
      Msg(Format('%s has parameters: give them (STL: lines "Name := operand" after CALL; LAD: the CALL box pins; SCL: "%s"(a := ..))',
        [S, FProg.Blocks[Index].Name]));
      Exit;
    end;
  Result := True;
end;

function TCompiler.FBInstance(const S: string; out BI: Integer; out Inst: TOperand; out Err: string): Boolean;
var
  P, N: Integer;
  FbS, DbS, U: string;
  D: TDataBlock;
  Fb, Fb2: TBlock;
  V: TVarInfo;
begin
  Result := False;
  Err := '';
  BI := -1;
  FillChar(Inst, SizeOf(Inst), 0);
  Inst.Block := -1;
  P := Pos(',', S);
  if P > 0 then
  begin
    FbS := Trim(Copy(S, 1, P - 1));
    DbS := Trim(Copy(S, P + 1, MaxInt));
  end
  else
  begin
    FbS := '';
    DbS := Trim(S);
  end;
  if DbS = '' then Exit;
  Fb := nil;
  if DbS[1] = '#' then
  begin
    if not FRes.ResolveVar(DbS, V, Err) then Exit;
    if (V.T <> dtStruct) or V.IsArray or not V.Udt.IsIface then
    begin
      Err := DbS + ' is no FB instance';
      Exit;
    end;
    Fb := FProject.FindBlock(bkFB, V.Udt.Number);
    Inst.Kind := okAddr;
    Inst.A := V.A;
  end
  else
  begin
    U := StringReplace(DbS, '"', '', [rfReplaceAll]);
    D := FProject.FindDBByName(U);
    if (D = nil) and SameText(Copy(U, 1, 2), 'DB') and TryStrToInt(Copy(U, 3, MaxInt), N) then D := FProject.FindDB(N);
    if D = nil then
    begin
      if FbS <> '' then Err := 'instance DB ' + DbS + ' does not exist';
      Exit;
    end;
    if D.InstanceOf <= 0 then
    begin
      if (FbS <> '') or (FProject.FindFB(U) <> nil) then Err := Format('DB%d "%s" is no instance DB', [D.Number, D.Name]);
      Exit;
    end;
    Fb := FProject.InstanceFB(D);
    if Fb = nil then
    begin
      Err := Format('DB%d is the instance of FB%d, which does not exist', [D.Number, D.InstanceOf]);
      Exit;
    end;
    Inst.Kind := okAddr;
    Inst.A := MakeAddr(arDB, osByte, 0, 0, D.Number);
  end;
  Inst.Text := DbS;
  if FbS <> '' then
  begin
    Fb2 := FProject.FindFB(FbS);
    if Fb2 = nil then
    begin
      Err := 'FB ' + FbS + ' does not exist';
      Exit;
    end;
    if Fb2 <> Fb then
    begin
      Err := Format('%s is an instance of FB%d, not of %s', [DbS, Fb.Number, FbS]);
      Exit;
    end;
  end;
  BI := FProg.FindBlock(bkFB, Fb.Number);
  Result := BI >= 0;
end;

{ ---------- calls with a parameter list (STL, LAD) ---------- }

function VarTypeName(const V: TVarInfo): string;
begin
  if V.T = dtStruct then Result := '"' + V.Udt.Name + '"' else Result := DataTypeNames[V.T];
  if V.IsArray then Result := Format('Array[%d..%d] of %s', [V.Lo, V.Hi, Result]);
end;

function VarBytes(const V: TVarInfo): Integer;
begin
  if not V.IsArray then
  begin
    if V.T = dtStruct then Result := V.Udt.Size else Result := DataTypeSize(V.T);
  end
  else if V.T = dtBool then
    Result := (V.Hi - V.Lo + 1 + 7) div 8
  else
    Result := (V.Hi - V.Lo + 1) * ElemStride(V.T, V.Udt);
end;

function TCompiler.FCRef(const S: string): TBlock;
var
  T: string;
  I, N: Integer;
begin
  Result := nil;
  T := StringReplace(Trim(S), '"', '', [rfReplaceAll]);
  if SameText(Copy(T, 1, 2), 'FC') and TryStrToInt(Copy(T, 3, MaxInt), N) then Exit(FProject.FindBlock(bkFC, N));
  for I := 0 to FProject.BlockCount - 1 do
    if (FProject.Block(I).Kind = bkFC) and SameText(FProject.Block(I).Name, T) then Exit(FProject.Block(I));
end;

{ the parameters are copied like in SCL: Inputs before the call, Outputs (and InOuts) back after it;
  an FC's parameters are in its local data (arL, DB = -1: the next frame), an FB's in the instance }
function TCompiler.ParamCall(Blk: TBlock; BI: Integer; const InstText: string; const Inst: TOperand;
  const Names, Acts: array of string; const Lines: array of Integer; Cond: Boolean): Boolean;
var
  U: TDataBlock;
  K, I, J, Pass, Skip: Integer;
  Given: array of Boolean;
  Idx: array of Integer;
  V, AV: TVarInfo;
  MO, AO: TOperand;
  C: TConst;
  E, Nm: string;
  M: TDbVar;
  IsFB, Blk2, Ok: Boolean;
  Kv: Double;

  procedure Op1(Code: TOpCode; const O: TOperand; T: TDataType);
  var
    X: Integer;
  begin
    X := Emit(Code, tcWord, 2);
    FBlock.Ops[X].Opd := O;
    FBlock.Ops[X].DType := T;
  end;

  procedure EmitCopy(const Dst, Src: TOperand; Bytes: Integer);
  var
    X: Integer;
  begin
    X := Emit(opSCopy, tcWord, Min(255, 2 + Bytes div 4));
    FBlock.Ops[X].Opd := Dst;
    FBlock.Ops[X].Ext := AddParam(Src);
    FBlock.Ops[X].Sub := Bytes;
  end;

  function SizeOk(const O: TOperand; T: TDataType): Boolean;
  begin
    if O.Kind <> okAddr then Exit(False);
    if O.A.Area in [arT, arC] then Exit(False);
    if T = dtBool then Result := O.A.Size = osBit
    else Result := (O.A.Size <> osBit) and (OperandSizeBytes(O) = Max(1, DataTypeSize(T)));
  end;

begin
  Result := False;
  U := Blk.Iface;
  U.Name := Blk.Name;
  U.Number := Blk.Number;
  U.Layout;
  IsFB := Blk.Kind = bkFB;
  SetLength(Given, Length(U.Vars));
  SetLength(Idx, Length(Names));
  // match the names
  Ok := True;
  for J := 0 to High(Names) do
  begin
    if J <= High(Lines) then FLine := Lines[J];
    K := U.FindVar(Trim(Names[J]));
    if (K >= 0) and (U.Vars[K].Section in [vsStatic, vsTemp]) then K := -1;
    if (K >= 0) and IsFB and (U.Vars[K].Section = vsReturn) then K := -1;
    Idx[J] := K;
    if K < 0 then
    begin
      Msg(Format('%s "%s" has no parameter %s', [Blk.Title, Blk.Name, Names[J]]));
      Ok := False;
      Continue;
    end;
    if Given[K] then
    begin
      Msg(Names[J] + ' is given twice');
      Ok := False;
    end;
    Given[K] := True;
    if not U.Vars[K].Valid then
    begin
      Msg(Format('%s.%s: unknown data type %s', [Blk.Title, U.Vars[K].Name, U.Vars[K].TypeText]));
      Ok := False;
    end;
  end;
  if not IsFB then
    for K := 0 to High(U.Vars) do
      if (U.Vars[K].Section in [vsInput, vsOutput, vsInOut]) and not Given[K] then
      begin
        Msg(Format('%s "%s": parameter %s missing (an FC needs every parameter)', [Blk.Title, Blk.Name, U.Vars[K].Name]));
        Ok := False;
      end;
  if not Ok then Exit;
  Skip := -1;
  if Cond then Skip := Emit(opCallIf, tcBit, 1);
  for Pass := 0 to 1 do
  begin
    for J := 0 to High(Names) do
    begin
      if J <= High(Lines) then FLine := Lines[J];
      M := U.Vars[Idx[J]];
      Nm := M.Name;
      // the parameter
      if IsFB then
      begin
        if not FRes.ResolveVar(InstText + '.' + Nm, V, E) then
        begin
          Msg(E);
          Exit;
        end;
      end
      else
      begin
        FillChar(V, SizeOf(V), 0);
        V.A := MakeAddr(arL, TypeOpSize(M.DType), M.Ofs, M.Bit, -1);
        V.T := M.DType;
        V.Udt := M.Udt;
        V.IsArray := M.IsArray;
        V.Lo := M.Lo;
        V.Hi := M.Hi;
      end;
      FillChar(MO, SizeOf(MO), 0);
      MO.Kind := okAddr;
      MO.A := V.A;
      MO.DType := V.T;
      MO.Block := -1;
      MO.Text := '#' + Nm;
      Blk2 := V.IsArray or (V.T in [dtStruct, dtIECTimer, dtIECCounter]);
      // the actual: a constant (Inputs only), a variable / address, a whole struct / array
      if Blk2 then
      begin
        if not FRes.ResolveVar(Trim(Acts[J]), AV, E) then
        begin
          if Pass = 0 then Msg(Nm + ': ' + E);
          Exit;
        end;
        if not SameText(VarTypeName(AV), VarTypeName(V)) then
        begin
          if Pass = 0 then Msg(Format('type mismatch: parameter %s is %s, %s is %s', [Nm, VarTypeName(V), Acts[J], VarTypeName(AV)]));
          Exit;
        end;
        FillChar(AO, SizeOf(AO), 0);
        AO.Kind := okAddr;
        AO.A := AV.A;
        AO.Block := -1;
        AO.Text := Trim(Acts[J]);
        if (Pass = 0) and ((M.Section in [vsInput, vsInOut]) or not IsFB and (M.Section = vsOutput)) then
          EmitCopy(MO, AO, VarBytes(V));
        if (Pass = 1) and (M.Section in [vsOutput, vsInOut, vsReturn]) then EmitCopy(AO, MO, VarBytes(V));
        Continue;
      end;
      if (M.Section = vsInput) and ParseConst(Trim(Acts[J]), C) then
      begin
        if Pass = 1 then Continue;
        case C.Kind of
          ckReal: Kv := C.R;
          ckBool, ckInt, ckDInt, ckTime, ckChar: Kv := C.I;
        else
          Kv := C.Bits;
        end;
        if (V.T = dtBool) and not (C.Kind in [ckBool, ckInt]) or (V.T <> dtReal) and (C.Kind = ckReal) or
          (V.T = dtReal) and not (C.Kind in [ckReal, ckInt, ckDInt]) then
        begin
          Msg(Format('%s is %s: the constant %s does not fit', [Nm, DataTypeNames[V.T], Acts[J]]));
          Exit;
        end;
        I := Emit(opSPushK, tcWord, 1);
        FBlock.Ops[I].K := Kv;
        FBlock.Ops[I].DType := V.T;
        Op1(opSStore, MO, V.T);
        Continue;
      end;
      if not FRes.Resolve(Trim(Acts[J]), AO, E, False) then
      begin
        if Pass = 0 then Msg(Nm + ': ' + E);
        Exit;
      end;
      if not SizeOk(AO, V.T) then
      begin
        if Pass = 0 then
          Msg(Format('%s is %s: %s does not fit', [Nm, DataTypeNames[V.T], Acts[J]]));
        Exit;
      end;
      if (Pass = 1) and (M.Section in [vsOutput, vsInOut, vsReturn]) and (AO.A.Area in [arI, arPI]) then
        Msg(Nm + ': an output to an input: the next input image overwrites it', False);
      if (Pass = 0) and ((M.Section in [vsInput, vsInOut]) or not IsFB and (M.Section = vsOutput)) then
      begin
        Op1(opSPush, AO, V.T);
        Op1(opSStore, MO, V.T);
      end;
      if (Pass = 1) and (M.Section in [vsOutput, vsInOut, vsReturn]) then
      begin
        Op1(opSPush, MO, V.T);
        Op1(opSStore, AO, V.T);
      end;
    end;
    if Pass = 0 then
    begin
      if IsFB then
      begin
        I := Emit(opCALLFB, tcWord, 6);
        FBlock.Ops[I].Opd := Inst;
      end
      else
        I := Emit(opCALL, tcWord, 4);
      FBlock.Ops[I].Ext := BI;
    end;
  end;
  if Cond then
  begin
    I := Emit(opCallEnd, tcBit, 1);
    FBlock.Ops[Skip].Ext := I + 1;
  end;
  Result := True;
end;

{ STL: CALL with parameter lines (CALL FC2 / CALL FB1, DB2 / CALL "Inst_DB" / CALL #inst) }
{ STL: CALL of an SCL function (CALL SEL with G := .., IN0 := .., RET_VAL := ..; also OUT := ..) or of a system FB
  instance (CALL #Delay with IN := .., PT := .., Q := ..; TON_TIME, CTU_INT, R_TRIG, RS ..): compiled as SCL }
function TCompiler.StlSclCall(const Tgt: string; const Names, Acts: array of string): Boolean;
const
  Fns: array[0..39] of string = ('SEL', 'MUX', 'LIMIT', 'MIN', 'MAX', 'NORM_X', 'SCALE_X', 'CONCAT', 'LEN', 'LEFT',
    'RIGHT', 'MID', 'FIND', 'SHL', 'SHR', 'ROL', 'ROR', 'ABS', 'SQR', 'SQRT', 'EXP', 'LN', 'LOG', 'SIN', 'COS', 'TAN',
    'ASIN', 'ACOS', 'ATAN', 'FRAC', 'TRUNC', 'ROUND', 'CEIL', 'FLOOR', 'S_MOVE', 'EXPT', 'MOD', 'NEG', 'SRT_DINT',
    'CAN_DINT');
  Clocks: array[0..6] of string = ('RD_SYS_T', 'RD_LOC_T', 'WR_SYS_T', 'WR_LOC_T', 'READ_CLK', 'SET_CLK', 'TIME_TCK');
  Outs: array[0..7] of string = ('Q', 'ET', 'QU', 'QD', 'CV', 'Q1', 'RET_VAL', 'OUT');
var
  U, Res, Args, Code: string;
  K, J: Integer;
  IsFn, IsOut: Boolean;
  V: TVarInfo;
  Er: string;
begin
  Result := False;
  U := UpperCase(Trim(Tgt));
  // the clock: every parameter is passed (OUT / CDT too), RET_VAL is the result
  if MatchStr(U, Clocks) then
  begin
    Result := True;
    Res := '';
    Args := '';
    for K := 0 to High(Names) do
      if SameText(Names[K], 'RET_VAL') then Res := Acts[K]
      else
      begin
        if Args <> '' then Args := Args + ', ';
        Args := Args + Names[K] + ' := ' + Acts[K];
      end;
    if Res <> '' then Code := Format('%s := %s(%s);', [Res, U, Args])
    else Code := Format('%s(%s);', [U, Args]);
    CompileSclText(Code, 'CALL ' + U);
    Exit;
  end;
  IsFn := Pos('_TO_', U) > 0;
  for K := 0 to High(Fns) do
    if Fns[K] = U then IsFn := True;
  if not IsFn then
  begin
    // a system FB instance: a timer / counter of TIA or R_TRIG / F_TRIG / RS / SR
    if not FRes.ResolveVar(Trim(Tgt), V, Er) then Exit;
    if not ((V.T in [dtIECTimer, dtIECCounter]) and (SysFbMethod(V.TypeText) <> '')) and
      not ((V.T = dtStruct) and IsSysFb(V.Udt)) then Exit;
  end;
  Result := True;
  Res := '';
  Args := '';
  for K := 0 to High(Names) do
  begin
    // value_type := Int (TIA writes the type of the instruction): the types come from the operands
    if SameText(Names[K], 'value_type') or SameText(Names[K], 'time_type') or SameText(Names[K], 'count_type') then Continue;
    IsOut := False;
    for J := 0 to High(Outs) do
      if SameText(Names[K], Outs[J]) then IsOut := True;
    if IsFn and IsOut then
    begin
      Res := Acts[K];
      Continue;
    end;
    if Args <> '' then Args := Args + ', ';
    if IsOut then Args := Args + Names[K] + ' => ' + Acts[K] else Args := Args + Names[K] + ' := ' + Acts[K];
  end;
  if IsFn then
  begin
    if Res = '' then
    begin
      Msg('CALL ' + Tgt + ': RET_VAL := <target> missing (the result)');
      Exit;
    end;
    case U of
      'S_MOVE': Code := Format('%s := %s;', [Res, Acts[0]]);
      'EXPT': Code := Format('%s := (%s) ** (%s);', [Res, Acts[0], Acts[1]]);
      'MOD': Code := Format('%s := (%s) MOD (%s);', [Res, Acts[0], Acts[1]]);
      'NEG': Code := Format('%s := -(%s);', [Res, Acts[0]]);
    else
      Code := Format('%s := %s(%s);', [Res, Trim(Tgt), Args]);
    end;
  end
  else
    Code := Format('%s(%s);', [Trim(Tgt), Args]);
  CompileSclText(Code, 'CALL ' + Trim(Tgt));
end;

procedure TCompiler.CompileStlCall(const Tgt: string; const Names, Acts: array of string; const Lines: array of Integer);
var
  BI: Integer;
  Inst: TOperand;
  E: string;
  Blk: TBlock;
  L0: Integer;
begin
  L0 := FLine;
  if StlSclCall(Tgt, Names, Acts) then
  begin
    FLine := L0;
    Exit;
  end;
  if FBInstance(Tgt, BI, Inst, E) then
  begin
    Blk := FProject.FindBlock(bkFB, FProg.Blocks[BI].Number);
    if Inst.A.Area = arDB then E := '"' + FProject.FindDB(Inst.A.DB).Name + '"' else E := Trim(Tgt);
    if Pos(',', E) > 0 then E := Trim(Copy(E, Pos(',', E) + 1, MaxInt));
    ParamCall(Blk, BI, E, Inst, Names, Acts, Lines, False);
  end
  else if E <> '' then
    Msg(E)
  else
  begin
    Blk := FCRef(Tgt);
    if Blk = nil then
    begin
      if FProject.FindFB(Tgt) <> nil then Msg(Tgt + ' is an FB: CALL FB1, DB10 (an instance DB)')
      else Msg('block ' + Tgt + ' does not exist');
      Exit;
    end;
    ParamCall(Blk, FProg.FindBlock(bkFC, Blk.Number), '', Inst, Names, Acts, Lines, False);
  end;
  FLine := L0;
end;

{$I uplcscl.inc}

function TCompiler.CompileSclText(const Code, What: string): Boolean;
var
  N: TNetwork;
  E0, L0: Integer;
  In0: Boolean;
  W0: string;
begin
  E0 := FProg.ErrorCount;
  L0 := FLine;
  In0 := FInline;
  W0 := FInlineWhat;
  N := TNetwork.Create(nkSCL);
  try
    N.Stl.Text := Code;
    FInline := True;
    if not In0 then FInlineWhat := What;
    try
      CompileScl(N);
    finally
      FInline := In0;
      FInlineWhat := W0;
      FLine := L0;
    end;
  finally
    N.Free;
  end;
  Result := FProg.ErrorCount = E0;
end;

{ the SCL of a box of an SCL function: IF __RLO__ THEN OUT := SEL(..); END_IF; (ENO = EN), an edge / flip-flop:
  its call with the RLO and the RLO := Q; an empty pin of the optional ones is left out }
function LadBoxScl(const Ce: TLadCell; out Code, Err: string): Boolean;
var
  Out, Fn, Args: string;
  K, NP: Integer;

  function P(I: Integer): string;
  begin
    Result := Trim(Ce.P[I]);
  end;

  function Need(I: Integer): Boolean;
  begin
    Result := P(I) <> '';
    if not Result then Err := LadParamName(Ce.Kind, I) + ' missing';
  end;

  procedure Named(const Names: array of string);
  var
    J: Integer;
  begin
    Args := '';
    for J := 0 to High(Names) do
      if P(J) <> '' then
      begin
        if Args <> '' then Args := Args + ', ';
        Args := Args + Names[J] + ' := ' + P(J);
      end;
  end;

begin
  Result := False;
  Code := '';
  Err := '';
  NP := LadParamCount(Ce.Kind);
  Fn := LadKindNames[Ce.Kind];
  case Ce.Kind of
    lkRTrig, lkFTrig, lkRS, lkSR:
      begin
        if Trim(Ce.Opnd) = '' then
        begin
          Err := 'the instance is missing (a ' + Fn + ' variable: a Static or in a DB)';
          Exit;
        end;
        case Ce.Kind of
          lkRTrig, lkFTrig: Code := Format('%s(CLK := __RLO__);'#10'__RLO__ := %s.Q;', [Trim(Ce.Opnd), Trim(Ce.Opnd)]);
          lkRS:
            begin
              if not Need(0) then Exit;
              Code := Format('%s(S := __RLO__, R1 := %s);'#10'__RLO__ := %s.Q1;', [Trim(Ce.Opnd), P(0), Trim(Ce.Opnd)]);
            end;
        else
          begin
            if not Need(0) then Exit;
            Code := Format('%s(S1 := __RLO__, R := %s);'#10'__RLO__ := %s.Q1;', [Trim(Ce.Opnd), P(0), Trim(Ce.Opnd)]);
          end;
        end;
        Exit(True);
      end;
    lkInc, lkDec:
      begin
        if not Need(0) then Exit;
        if Ce.Kind = lkInc then Code := Format('%s := %s + 1;', [P(0), P(0)])
        else Code := Format('%s := %s - 1;', [P(0), P(0)]);
        Code := 'IF __RLO__ THEN'#10 + Code + #10'END_IF;';
        Exit(True);
      end;
  end;
  // a function: OUT is the last pin; the inputs, the optional ones of MUX / MIN / MAX may be empty
  if not Need(NP - 1) then Exit;
  Out := P(NP - 1);
  for K := 0 to NP - 2 do
    if not (((Ce.Kind = lkMux) and (K = 3)) or ((Ce.Kind in [lkMin, lkMax]) and (K >= 2))) then
      if not Need(K) then Exit;
  case Ce.Kind of
    lkSel: Named(['G', 'IN0', 'IN1']);
    lkMux: Named(['K', 'IN0', 'IN1', 'IN2']);
    lkLimit: Named(['MN', 'IN', 'MX']);
    lkMin, lkMax: Named(['IN1', 'IN2', 'IN3', 'IN4']);
    lkShl..lkRor: Named(['IN', 'N']);
    lkConcat, lkFind: Named(['IN1', 'IN2']);
    lkLeft, lkRight: Named(['IN', 'L']);
    lkMid: Named(['IN', 'L', 'P']);
  end;
  case Ce.Kind of
    lkNegate: Code := Format('%s := -(%s);', [Out, P(0)]);
    lkExpt: Code := Format('%s := %s ** %s;', [Out, P(0), P(1)]);
    lkMod: Code := Format('%s := %s MOD %s;', [Out, P(0), P(1)]);
    lkAndW: Code := Format('%s := %s AND %s;', [Out, P(0), P(1)]);
    lkOrW: Code := Format('%s := %s OR %s;', [Out, P(0), P(1)]);
    lkXorW: Code := Format('%s := %s XOR %s;', [Out, P(0), P(1)]);
    lkInvW: Code := Format('%s := NOT %s;', [Out, P(0)]);
    lkSMove: Code := Format('%s := %s;', [Out, P(0)]);
    lkSqrt..lkFrac, lkLen: Code := Format('%s := %s(%s);', [Out, Fn, P(0)]);
  else
    Code := Format('%s := %s(%s);', [Out, Fn, Args]);
  end;
  Code := 'IF __RLO__ THEN'#10 + Code + #10'END_IF;';
  Result := True;
end;

{ an IEC timer / counter box whose instance has a layout of its own (TON_LTIME, CTU_DINT ..): as SCL }
function LadIecScl(const Ce: TLadCell; out Code: string): Boolean;
var
  I: string;

  function Pin(const Nm, V: string; IsOut: Boolean): string;
  begin
    if Trim(V) = '' then Exit('');
    if IsOut then Result := ', ' + Nm + ' => ' + Trim(V) else Result := ', ' + Nm + ' := ' + Trim(V);
  end;

begin
  Result := True;
  I := Trim(Ce.Opnd);
  case Ce.Kind of
    lkTON, lkTOF, lkTP:
      Code := Format('%s(IN := __RLO__%s%s);'#10'__RLO__ := %s.Q;', [I, Pin('PT', Ce.P[0], False), Pin('ET', Ce.P[1], True), I]);
    lkTONR:
      Code := Format('%s(IN := __RLO__%s%s%s);'#10'__RLO__ := %s.Q;', [I, Pin('R', Ce.P[1], False), Pin('PT', Ce.P[0], False),
        Pin('ET', Ce.P[2], True), I]);
    lkCTU:
      Code := Format('%s(CU := __RLO__%s%s%s);'#10'__RLO__ := %s.QU;', [I, Pin('R', Ce.P[1], False), Pin('PV', Ce.P[0], False),
        Pin('CV', Ce.P[2], True), I]);
    lkCTD:
      Code := Format('%s(CD := __RLO__%s%s%s);'#10'__RLO__ := %s.QD;', [I, Pin('LD', Ce.P[1], False), Pin('PV', Ce.P[0], False),
        Pin('CV', Ce.P[2], True), I]);
    lkCTUD:
      Code := Format('%s(CU := __RLO__%s%s%s%s%s);'#10'__RLO__ := %s.QU;', [I, Pin('CD', Ce.P[1], False), Pin('R', Ce.P[2], False),
        Pin('LD', Ce.P[3], False), Pin('PV', Ce.P[0], False), Pin('CV', Ce.P[4], True), I]);
  else
    Result := False;
  end;
end;

{ ---------- STL ---------- }

procedure TCompiler.CompileStlLine(const ALine: string);
var
  S, Mn, Opnd, Lbl, E: string;
  P, I, K: Integer;
  Opd: TOperand;
  InQ: Boolean;
  Op: Integer;
  Cnt: Integer;
  CO: TCmpOp;

  procedure Need(Ok: Boolean; const What: string);
  begin
    if not Ok then Msg(What);
  end;

  function BitOperand: Boolean;
  begin
    Result := OperandOf(Opnd, Opd, False);
    if not Result then Exit;
    if Opd.Kind = okStatus then Exit(True);
    if (Opd.Kind <> okAddr) or (Opd.A.Size <> osBit) then
    begin
      Msg('bit operand expected: ' + Opnd);
      Result := False;
    end;
  end;

  procedure EmitBit(Code: TOpCode; AllowStatus, AllowTC: Boolean);
  begin
    if not BitOperand then Exit;
    if (Opd.Kind = okStatus) and not AllowStatus then
    begin
      Msg(Mn + ' does not take a status bit');
      Exit;
    end;
    if (Opd.Kind = okAddr) and (Opd.A.Area in [arT, arC]) and not AllowTC then
    begin
      Msg(Mn + ' cannot write a timer / counter bit (use S / R)');
      Exit;
    end;
    Op := Emit(Code, tcBit);
    FBlock.Ops[Op].Opd := Opd;
  end;

  procedure EmitPlain(Code: TOpCode; Cat: TTimeCat);
  begin
    if Opnd <> '' then Msg(Mn + ' takes no operand');
    Emit(Code, Cat);
  end;

  procedure EmitJump(Code: TOpCode);
  begin
    if Opnd = '' then
    begin
      Msg('jump label expected');
      Exit;
    end;
    Op := Emit(Code, tcWord);
    FFixups.AddObject(UpperCase(Opnd), TObject(PtrInt(Op)));
  end;

  procedure EmitTC(Code: TOpCode; Area: TArea);
  begin
    if not OperandOf(Opnd, Opd, False) then Exit;
    if (Opd.Kind <> okAddr) or (Opd.A.Area <> Area) then
    begin
      if Area = arT then Msg(Mn + ': timer T n expected') else Msg(Mn + ': counter C n expected');
      Exit;
    end;
    Op := Emit(Code, tcFix, 2);
    FBlock.Ops[Op].Opd := Opd;
  end;

  procedure EmitWordLogic(Code: TOpCode; Bytes: Integer);
  begin
    Op := Emit(Code, tcWord);
    if Opnd <> '' then
    begin
      if not OperandOf(Opnd, Opd) then Exit;
      if Opd.Kind <> okConst then
      begin
        Msg(Mn + ': constant expected (or none: ACCU2)');
        Exit;
      end;
      FBlock.Ops[Op].Opd := Opd;
    end;
  end;

  procedure EmitShift(Code: TOpCode);
  begin
    Op := Emit(Code, tcWord);
    FBlock.Ops[Op].Sub := -1;
    if Opnd <> '' then
    begin
      if not TryStrToInt(Opnd, Cnt) or (Cnt < 0) or (Cnt > 32) then
        Msg(Mn + ': shift count 0..32 expected')
      else
        FBlock.Ops[Op].Sub := Cnt;
    end;
  end;

  procedure EmitCmp(Code: TOpCode; AOp: TCmpOp; Cat: TTimeCat);
  begin
    if Opnd <> '' then Msg(Mn + ' takes no operand');
    Op := Emit(Code, Cat);
    FBlock.Ops[Op].Sub := Ord(AOp);
  end;

begin
  S := ALine;
  // comment
  InQ := False;
  for P := 1 to Length(S) - 1 do
  begin
    if S[P] = '"' then InQ := not InQ;
    if not InQ and (S[P] = '/') and (S[P + 1] = '/') then
    begin
      S := Copy(S, 1, P - 1);
      Break;
    end;
  end;
  S := Trim(S);
  if S = '' then Exit;
  // label
  P := Pos(':', S);
  if (P > 1) and (Pos('"', Copy(S, 1, P)) = 0) and (Pos(' ', Trim(Copy(S, 1, P - 1))) = 0) and
    not (S[1] in ['0'..'9']) and (Pos('#', Copy(S, 1, P)) = 0) then
  begin
    Lbl := UpperCase(Trim(Copy(S, 1, P - 1)));
    if (Lbl <> '') and (Lbl[1] in ['A'..'Z', '_']) and (Copy(S, P, 2) <> ':P') then
    begin
      if FLabels.IndexOf(Lbl) >= 0 then Msg('label ' + Lbl + ' defined twice')
      else FLabels.AddObject(Lbl, TObject(PtrInt(Length(FBlock.Ops))));
      S := Trim(Copy(S, P + 1, MaxInt));
      if S = '' then
      begin
        Emit(opNop, tcBit);
        Exit;
      end;
    end;
  end;
  // mnemonic and operand
  P := 1;
  while (P <= Length(S)) and not (S[P] in [' ', #9]) do Inc(P);
  Mn := UpperCase(Copy(S, 1, P - 1));
  Opnd := Trim(Copy(S, P, MaxInt));
  if (Opnd = '(') and (Mn <> '') then
  begin
    Mn := Mn + '(';
    Opnd := '';
  end;
  // operations written together with their operand: A(, O(
  if (Length(Mn) > 1) and (Mn[Length(Mn)] = '(') and (Opnd <> '') then
    Msg('nothing may follow ' + Mn);

  case Mn of
    'A', 'U': EmitBit(opA, True, True);
    'AN', 'UN': EmitBit(opAN, True, True);
    'O':
      if Opnd = '' then Emit(opOAlone, tcBit) else EmitBit(opO, True, True);
    'ON': EmitBit(opON, True, True);
    'X': EmitBit(opX, True, True);
    'XN': EmitBit(opXN, True, True);
    'A(', 'U(': EmitPlain(opAParen, tcBit);
    'AN(', 'UN(': EmitPlain(opANParen, tcBit);
    'O(': EmitPlain(opOParen, tcBit);
    'ON(': EmitPlain(opONParen, tcBit);
    'X(': EmitPlain(opXParen, tcBit);
    'XN(': EmitPlain(opXNParen, tcBit);
    ')': EmitPlain(opParenClose, tcBit);
    '=': EmitBit(opAssign, False, False);
    'S':
      begin
        if not OperandOf(Opnd, Opd, False) then Exit;
        if (Opd.Kind = okAddr) and (Opd.A.Area = arC) then
        begin
          Op := Emit(opSC, tcFix, 2);
          FBlock.Ops[Op].Opd := Opd;
        end
        else if (Opd.Kind = okAddr) and (Opd.A.Size = osBit) and (Opd.A.Area <> arT) then
        begin
          Op := Emit(opS, tcBit);
          FBlock.Ops[Op].Opd := Opd;
        end
        else
          Msg('S: bit or counter expected');
      end;
    'R':
      begin
        if not OperandOf(Opnd, Opd, False) then Exit;
        if (Opd.Kind = okAddr) and (Opd.A.Size = osBit) then
        begin
          Op := Emit(opR, tcBit);
          FBlock.Ops[Op].Opd := Opd;
        end
        else
          Msg('R: bit, timer or counter expected');
      end;
    'NOT': EmitPlain(opNOT, tcBit);
    'SET': EmitPlain(opSET, tcBit);
    'CLR': EmitPlain(opCLR, tcBit);
    'SAVE': EmitPlain(opSAVE, tcBit);
    'FP': EmitBit(opFP, False, False);
    'FN': EmitBit(opFN, False, False);
    'SP': EmitTC(opSP, arT);
    'SE': EmitTC(opSE, arT);
    'SD': EmitTC(opSD, arT);
    'SS': EmitTC(opSS, arT);
    'SF': EmitTC(opSF, arT);
    'FR':
      begin
        if not OperandOf(Opnd, Opd, False) then Exit;
        if (Opd.Kind <> okAddr) or not (Opd.A.Area in [arT, arC]) then
        begin
          Msg('FR: timer or counter expected');
          Exit;
        end;
        Op := Emit(opFR, tcFix);
        FBlock.Ops[Op].Opd := Opd;
      end;
    'CU', 'ZV': EmitTC(opCU, arC);
    'CD', 'ZR': EmitTC(opCD, arC);
    'L':
      begin
        if UpperCase(Opnd) = 'DBNO' then Emit(opLDBNO, tcWord)
        else if UpperCase(Opnd) = 'DBLG' then Emit(opLDBLG, tcWord)
        else if UpperCase(Opnd) = 'DINO' then Emit(opLDINO, tcWord)
        else if UpperCase(Opnd) = 'DILG' then Emit(opLDILG, tcWord)
        else
        begin
          if not OperandOf(Opnd, Opd) then Exit;
          if Opd.Kind = okStatus then
          begin
            Msg('L: a status bit cannot be loaded');
            Exit;
          end;
          if (Opd.Kind = okAddr) and (Opd.A.Size = osBit) and not (Opd.A.Area in [arT, arC]) then
          begin
            Msg('L: byte, word or double word expected (not a bit)');
            Exit;
          end;
          if Opd.Kind = okBlock then
          begin
            Msg('L: use OPN to open a DB');
            Exit;
          end;
          Op := Emit(opL, tcWord);
          FBlock.Ops[Op].Opd := Opd;
        end;
      end;
    'LC':
      begin
        if not OperandOf(Opnd, Opd, False) then Exit;
        if (Opd.Kind <> okAddr) or not (Opd.A.Area in [arT, arC]) then
        begin
          Msg('LC: timer or counter expected');
          Exit;
        end;
        Op := Emit(opLC, tcWord);
        FBlock.Ops[Op].Opd := Opd;
      end;
    'T':
      begin
        if not OperandOf(Opnd, Opd, False) then Exit;
        if (Opd.Kind <> okAddr) or (Opd.A.Size = osBit) or (Opd.A.Area in [arT, arC]) then
        begin
          Msg('T: byte, word or double word address expected');
          Exit;
        end;
        if Opd.A.Area in [arI, arPI] then
        begin
          if Opd.A.Area = arPI then
          begin
            Msg('T: peripheral inputs cannot be written');
            Exit;
          end;
        end;
        Op := Emit(opT, tcWord);
        FBlock.Ops[Op].Opd := Opd;
      end;
    'TAK': EmitPlain(opTAK, tcWord);
    'PUSH': EmitPlain(opPUSH, tcWord);
    'POP': EmitPlain(opPOP, tcWord);
    'ENT', 'LEAVE':
      begin
        if FModel.Accus < 4 then
          Msg(Mn + ' needs the four accumulators of the S7-400')
        else if Mn = 'ENT' then EmitPlain(opENT, tcWord)
        else EmitPlain(opLEAVE, tcWord);
      end;
    'CAW': EmitPlain(opCAW, tcWord);
    'CAD': EmitPlain(opCAD, tcWord);
    'INC', 'DEC':
      begin
        if not TryStrToInt(Opnd, Cnt) or (Cnt < 0) or (Cnt > 255) then
        begin
          Msg(Mn + ': constant 0..255 expected');
          Exit;
        end;
        if Mn = 'INC' then Op := Emit(opINC, tcFix) else Op := Emit(opDEC, tcFix);
        FBlock.Ops[Op].Sub := Cnt;
      end;
    '+I': EmitPlain(opAddI, tcFix);
    '-I': EmitPlain(opSubI, tcFix);
    '*I': EmitPlain(opMulI, tcFix);
    '/I': EmitPlain(opDivI, tcFix);
    '+D': EmitPlain(opAddD, tcFix);
    '-D': EmitPlain(opSubD, tcFix);
    '*D': EmitPlain(opMulD, tcFix);
    '/D': EmitPlain(opDivD, tcFix);
    'MOD': EmitPlain(opMOD, tcFix);
    '+R': EmitPlain(opAddR, tcFloat);
    '-R': EmitPlain(opSubR, tcFloat);
    '*R': EmitPlain(opMulR, tcFloat);
    '/R': EmitPlain(opDivR, tcFloat);
    '+':
      begin
        if not OperandOf(Opnd, Opd) then Exit;
        if (Opd.Kind <> okConst) or not (Opd.C.Kind in [ckInt, ckDInt]) then
        begin
          Msg('+: integer constant expected (+ 5, + L#5)');
          Exit;
        end;
        Op := Emit(opAddConst, tcFix);
        FBlock.Ops[Op].Opd := Opd;
      end;
    'ABS': EmitPlain(opABS, tcFloat);
    'SQRT': EmitPlain(opSQRT, tcFloat);
    'SQR': EmitPlain(opSQR, tcFloat);
    'LN': EmitPlain(opLN, tcFloat);
    'EXP': EmitPlain(opEXP, tcFloat);
    'SIN': EmitPlain(opSIN, tcFloat);
    'COS': EmitPlain(opCOS, tcFloat);
    'TAN': EmitPlain(opTAN, tcFloat);
    'ASIN': EmitPlain(opASIN, tcFloat);
    'ACOS': EmitPlain(opACOS, tcFloat);
    'ATAN': EmitPlain(opATAN, tcFloat);
    'NEGI': EmitPlain(opNEGI, tcFix);
    'NEGD': EmitPlain(opNEGD, tcFix);
    'NEGR': EmitPlain(opNEGR, tcFloat);
    'INVI': EmitPlain(opINVI, tcWord);
    'INVD': EmitPlain(opINVD, tcWord);
    'ITD': EmitPlain(opITD, tcWord);
    'DTR': EmitPlain(opDTR, tcFloat);
    'ITB': EmitPlain(opITB, tcFix);
    'BTI': EmitPlain(opBTI, tcFix);
    'DTB': EmitPlain(opDTB, tcFix);
    'BTD': EmitPlain(opBTD, tcFix);
    'RND': EmitPlain(opRND, tcFloat);
    'TRUNC': EmitPlain(opTRUNC, tcFloat);
    'RND+': EmitPlain(opRNDP, tcFloat);
    'RND-': EmitPlain(opRNDM, tcFloat);
    'AW': EmitWordLogic(opAW, 2);
    'OW': EmitWordLogic(opOW, 2);
    'XOW': EmitWordLogic(opXOW, 2);
    'AD': EmitWordLogic(opAD, 4);
    'OD': EmitWordLogic(opOD, 4);
    'XOD': EmitWordLogic(opXOD, 4);
    'SLW': EmitShift(opSLW);
    'SRW': EmitShift(opSRW);
    'SLD': EmitShift(opSLD);
    'SRD': EmitShift(opSRD);
    'SSI': EmitShift(opSSI);
    'SSD': EmitShift(opSSD);
    'RLD': EmitShift(opRLD);
    'RRD': EmitShift(opRRD);
    'JU': EmitJump(opJU);
    'JC': EmitJump(opJC);
    'JCN': EmitJump(opJCN);
    'JCB': EmitJump(opJCB);
    'JNB': EmitJump(opJNB);
    'JBI': EmitJump(opJBI);
    'JNBI': EmitJump(opJNBI);
    'JO': EmitJump(opJO);
    'JOS': EmitJump(opJOS);
    'JZ': EmitJump(opJZ);
    'JN': EmitJump(opJN);
    'JP': EmitJump(opJP);
    'JM': EmitJump(opJM);
    'JPZ': EmitJump(opJPZ);
    'JMZ': EmitJump(opJMZ);
    'JUO': EmitJump(opJUO);
    'LOOP': EmitJump(opLOOP);
    'BE': EmitPlain(opBE, tcWord);
    'BEU': EmitPlain(opBEU, tcWord);
    'BEC': EmitPlain(opBEC, tcWord);
    'CALL', 'UC', 'CC':
      begin
        // an FB with its instance: CALL FB1, DB10 / CALL "Inst_DB" / CALL #inst
        if FBInstance(Opnd, K, Opd, E) or (E <> '') then
        begin
          if E <> '' then
          begin
            Msg(E);
            Exit;
          end;
          Op := Emit(opCALLFB, tcWord, 6);
          FBlock.Ops[Op].Ext := K;
          FBlock.Ops[Op].Opd := Opd;
          FBlock.Ops[Op].Sub := Ord(Mn = 'CC');
          Exit;
        end;
        if not BlockRef(Opnd, K) then Exit;
        if Mn = 'CC' then Op := Emit(opCC, tcWord, 4) else Op := Emit(opCALL, tcWord, 4);
        FBlock.Ops[Op].Ext := K;
      end;
    'OPN':
      begin
        if not OperandOf(Opnd, Opd, False) then Exit;
        if Opd.Kind <> okBlock then
        begin
          Msg('OPN: DB n or DI n expected');
          Exit;
        end;
        if Opd.A.Area = arDI then Op := Emit(opOPNDI, tcWord) else Op := Emit(opOPN, tcWord);
        FBlock.Ops[Op].Opd := Opd;
      end;
    'NOP', 'BLD':
      Emit(opNop, tcBit);
  else
    begin
      // compare instructions
      I := -1;
      for CO := Low(TCmpOp) to High(TCmpOp) do
      begin
        if Mn = CmpOpNames[CO] + 'I' then begin EmitCmp(opCmpI, CO, tcFix); I := 1; end;
        if Mn = CmpOpNames[CO] + 'D' then begin EmitCmp(opCmpD, CO, tcFix); I := 1; end;
        if Mn = CmpOpNames[CO] + 'R' then begin EmitCmp(opCmpR, CO, tcFloat); I := 1; end;
      end;
      if I < 0 then Msg('unknown instruction "' + Mn + '"');
    end;
  end;
end;

function StripStl(const S: string): string;
var
  P: Integer;
begin
  Result := S;
  P := Pos('//', Result);
  if P > 0 then Result := Copy(Result, 1, P - 1);
  Result := Trim(Result);
end;

{ CALL <target> on its own (no label) }
function IsCallLine(const S: string; out Tgt: string): Boolean;
var
  T: string;
begin
  T := StripStl(S);
  Result := SameText(Copy(T, 1, 5), 'CALL ') or SameText(Copy(T, 1, 5), 'CALL'#9);
  if Result then Tgt := Trim(Copy(T, 6, MaxInt)) else Tgt := '';
end;

{ a parameter line of a CALL:  Name := operand  (also Name => operand) }
function IsParamLine(const S: string; out Nm, Act: string): Boolean;
var
  T: string;
  P, Q: Integer;
begin
  Result := False;
  T := StripStl(S);
  P := Pos(':=', T);
  Q := Pos('=>', T);
  if (Q > 0) and ((P = 0) or (Q < P)) then P := Q;
  if P <= 1 then Exit;
  Nm := Trim(Copy(T, 1, P - 1));
  Act := Trim(Copy(T, P + 2, MaxInt));
  if (Nm = '') or (Act = '') or not (Nm[1] in ['A'..'Z', 'a'..'z', '_']) then Exit;
  for Q := 1 to Length(Nm) do
    if not (Nm[Q] in ['A'..'Z', 'a'..'z', '0'..'9', '_']) then Exit;
  Result := True;
end;

procedure TCompiler.CompileStl(N: TNetwork);
var
  I, J, First: Integer;
  Tgt, Nm, Ac: string;
  Names, Acts: array of string;
  Lines: array of Integer;
begin
  if FModel.Family = cfS71200 then
  begin
    FLine := -1;
    Msg('STL is not available on the S7-1200: use LAD');
    Exit;
  end;
  I := 0;
  while I < N.Stl.Count do
  begin
    FLine := I;
    First := Length(FBlock.Ops);
    // CALL with a parameter list on the next lines:   Name := operand
    if IsCallLine(N.Stl[I], Tgt) and (I + 1 < N.Stl.Count) and IsParamLine(N.Stl[I + 1], Nm, Ac) then
    begin
      SetLength(Names, 0);
      SetLength(Acts, 0);
      SetLength(Lines, 0);
      J := I + 1;
      while (J < N.Stl.Count) and IsParamLine(N.Stl[J], Nm, Ac) do
      begin
        SetLength(Names, Length(Names) + 1);
        SetLength(Acts, Length(Acts) + 1);
        SetLength(Lines, Length(Lines) + 1);
        Names[High(Names)] := Nm;
        Acts[High(Acts)] := Ac;
        Lines[High(Lines)] := J;
        Inc(J);
      end;
      CompileStlCall(Tgt, Names, Acts, Lines);
      if Length(FBlock.Ops) > First then
        FBlock.Ops[High(FBlock.Ops)].Mon := FBlock.Nets[FNet].MonBase + I;
      I := J;
      Continue;
    end;
    CompileStlLine(N.Stl[I]);
    // the monitor slot of the line: its last op
    if Length(FBlock.Ops) > First then
      FBlock.Ops[High(FBlock.Ops)].Mon := FBlock.Nets[FNet].MonBase + I;
    Inc(I);
  end;
  FLine := -1;
end;

{ ---------- LAD ---------- }

procedure TCompiler.CompileLad(N: TNetwork);
var
  SclErr: string;
  R, C, Op, I, K, G, Cell: Integer;
  Ce: TLadCell;
  Opd: TOperand;
  Pars: array[0..4] of TOperand;
  Grp: TLadGroups;
  Used: array[0..MaxLadRows - 1] of Boolean;
  Any, Box: Boolean;
  Base: Integer;
  NI: Integer;
  E: string;
  FbInst: TOperand;
  CallBlk: TBlock;
  Pins: TIntArray;
  CNames, CActs: array of string;

  function Opnd1(const S: string; Bit: Boolean; const What: string): Boolean;
  begin
    Result := False;
    if Trim(S) = '' then
    begin
      Msg(What + ' missing');
      Exit;
    end;
    if not OperandOf(S, Opd, False) then Exit;
    if Opd.Kind = okStatus then
    begin
      Msg('status bits only in STL');
      Exit;
    end;
    if Bit and ((Opd.Kind <> okAddr) or (Opd.A.Size <> osBit)) then
    begin
      Msg(What + ': bit operand expected: ' + S);
      Exit;
    end;
    Result := True;
  end;

  { a box parameter: typed value or address }
  function Par(I: Integer; const S: string; Bytes: Integer; IsOut, Optional, IsBit: Boolean): Boolean;
  var
    E: string;
  begin
    Result := False;
    FillChar(Pars[I], SizeOf(TOperand), 0);
    Pars[I].Kind := okNone;
    Pars[I].Block := -1;
    if Trim(S) = '' then
    begin
      if Optional then Exit(True);
      Msg(LadParamName(Ce.Kind, I) + ' missing');
      Exit;
    end;
    if not FRes.Resolve(S, Pars[I], E, not IsOut) then
    begin
      Msg(LadParamName(Ce.Kind, I) + ': ' + E);
      Exit;
    end;
    if Pars[I].Kind = okStatus then
    begin
      Msg('status bits only in STL');
      Exit;
    end;
    if IsOut and (Pars[I].Kind <> okAddr) then
    begin
      Msg(LadParamName(Ce.Kind, I) + ': output needs an address');
      Exit;
    end;
    if IsOut and (Pars[I].A.Area in [arI, arPI]) then
    begin
      Msg(LadParamName(Ce.Kind, I) + ': inputs cannot be written');
      Exit;
    end;
    if IsBit then
    begin
      if (Pars[I].Kind = okAddr) and (Pars[I].A.Size <> osBit) then
      begin
        Msg(LadParamName(Ce.Kind, I) + ': bit expected');
        Exit;
      end;
      if (Pars[I].Kind = okConst) and (Pars[I].C.Kind <> ckBool) then
      begin
        Msg(LadParamName(Ce.Kind, I) + ': TRUE / FALSE or a bit expected');
        Exit;
      end;
    end
    else if Pars[I].Kind = okAddr then
    begin
      if (Pars[I].A.Area in [arT, arC]) or (OperandSizeBytes(Pars[I]) <> Bytes) then
      begin
        Msg(Format('%s: %s needs a %d byte operand (%s is %d)', [LadParamName(Ce.Kind, I),
          LadKindNames[Ce.Kind], Bytes, S, OperandSizeBytes(Pars[I])]));
        Exit;
      end;
    end
    else if Pars[I].Kind = okConst then
    begin
      if (Bytes = 4) and (Pars[I].C.Kind = ckInt) then
      begin
        // an INT constant widens to DINT / REAL
        Pars[I].C.Bits := LongWord(LongInt(Pars[I].C.I));
        Pars[I].C.Size := osDWord;
      end;
    end
    else if Pars[I].Kind = okBlock then
    begin
      Msg(LadParamName(Ce.Kind, I) + ': value or address expected');
      Exit;
    end;
    Result := True;
  end;

  function TypeBytes(T: TDataType): Integer;
  begin
    case T of
      dtInt, dtWord, dtUInt: Result := 2;
      dtByte, dtSInt, dtUSInt, dtChar: Result := 1;
    else
      Result := 4;
    end;
  end;

  function Instance(Want: TDataType): Boolean;
  begin
    Result := False;
    if Trim(Ce.Opnd) = '' then
    begin
      Msg(LadKindNames[Ce.Kind] + ': instance missing (a ' + DataTypeNames[Want] + ' variable in a DB)');
      Exit;
    end;
    if not OperandOf(Ce.Opnd, Opd, False) then Exit;
    if (Opd.Kind <> okAddr) or (Opd.DType <> Want) then
    begin
      Msg(LadKindNames[Ce.Kind] + ': instance must be a ' + DataTypeNames[Want] + ' variable, e.g. "Motor".Delay');
      Exit;
    end;
    Result := True;
  end;

  { TON_LTIME / CTU_DINT ..: an instance of another layout }
  function IecVariant(const S: string): Boolean;
  var
    V: TVarInfo;
    Er: string;
  begin
    Result := (Trim(S) <> '') and FRes.ResolveVar(Trim(S), V, Er) and (V.Udt <> nil) and (V.Udt.IecVar <> dtNone);
  end;

  procedure EmitBox(Code: TOpCode; NPar: Integer; Cat: TTimeCat; W: Integer);
  var
    J: Integer;
  begin
    Op := Emit(Code, Cat, W);
    FBlock.Ops[Op].Opd := Opd;
    FBlock.Ops[Op].DType := Ce.DType;
    FBlock.Ops[Op].Sub := Ord(Ce.Cmp);
    FBlock.Ops[Op].Ext := Length(FBlock.Params);
    for J := 0 to NPar - 1 do AddParam(Pars[J]);
  end;


  procedure LadIec;
  begin
    if Instance(dtIECTimer) and Par(0, Ce.P[0], 4, False, False, False) and
      Par(1, Ce.P[1], 4, True, True, False) then
      case Ce.Kind of
        lkTON: EmitBox(opTON, 2, tcFix, 12);
        lkTOF: EmitBox(opTOF, 2, tcFix, 12);
      else
        EmitBox(opTP, 2, tcFix, 12);
      end;
  end;
begin
  NI := FNet;
  Base := FBlock.Nets[NI].MonBase;
  SetLength(FBlock.Nets[NI].CellOps, N.Rows * N.Cols);
  Emit(opLadBegin, tcBit);
  for C := 0 to N.Cols - 1 do
  begin
    Any := False;
    for R := 0 to N.Rows - 1 do
    begin
      Ce := N.Cell(R, C);
      Cell := R * N.Cols + C;
      FLine := Cell;
      Used[R] := Ce.Kind <> lkEmpty;
      if Ce.Kind = lkEmpty then Continue;
      Any := True;
      FillChar(Opd, SizeOf(Opd), 0);
      Opd.Block := -1;
      for I := 0 to 4 do
      begin
        FillChar(Pars[I], SizeOf(TOperand), 0);
        Pars[I].Block := -1;
      end;
      Op := Emit(opLadLoad, tcBit);
      FBlock.Ops[Op].Sub := R;
      FBlock.Ops[Op].Mon := Base + Cell * 2;
      Box := True;
      case Ce.Kind of
        lkWire: ;
        lkNO, lkNC:
          if Opnd1(Ce.Opnd, True, 'operand') then
          begin
            if Ce.Kind = lkNO then Op := Emit(opA, tcBit) else Op := Emit(opAN, tcBit);
            FBlock.Ops[Op].Opd := Opd;
          end;
        lkPos, lkNeg:
          if Opnd1(Ce.Opnd, True, 'operand') and Par(0, Ce.P[0], 0, True, False, True) then
          begin
            if Ce.Kind = lkPos then Op := Emit(opPContact, tcBit, 2) else Op := Emit(opNContact, tcBit, 2);
            FBlock.Ops[Op].Opd := Opd;
            FBlock.Ops[Op].Ext := AddParam(Pars[0]);
          end;
        lkNot: Emit(opNOT, tcBit);
        lkCoil, lkCoilNeg:
          if Opnd1(Ce.Opnd, True, 'operand') then
          begin
            if Opd.A.Area in [arT, arC] then Msg('a coil cannot write a timer / counter (use R)')
            else if Opd.A.Area in [arI, arPI] then Msg('coil on an input: allowed, but the input image is overwritten at the next cycle', False);
            if Ce.Kind = lkCoil then Op := Emit(opAssign, tcBit) else Op := Emit(opCoilNeg, tcBit);
            FBlock.Ops[Op].Opd := Opd;
          end;
        lkSet, lkReset:
          if Opnd1(Ce.Opnd, True, 'operand') then
          begin
            if (Ce.Kind = lkSet) and (Opd.A.Area = arT) then Msg('S cannot set a timer')
            else if (Ce.Kind = lkSet) and (Opd.A.Area = arC) then Msg('use SC to set a counter')
            else
            begin
              if Ce.Kind = lkSet then Op := Emit(opS, tcBit) else Op := Emit(opR, tcBit);
              FBlock.Ops[Op].Opd := Opd;
            end;
          end;
        lkSD, lkSE, lkSP, lkSS, lkSF:
          if Opnd1(Ce.Opnd, True, 'timer') then
          begin
            if Opd.A.Area <> arT then Msg('timer T n expected')
            else if Par(0, Ce.P[0], 2, False, False, False) then
            begin
              Op := Emit(opL, tcWord);
              FBlock.Ops[Op].Opd := Pars[0];
              case Ce.Kind of
                lkSD: Op := Emit(opSD, tcFix, 2);
                lkSE: Op := Emit(opSE, tcFix, 2);
                lkSP: Op := Emit(opSP, tcFix, 2);
                lkSS: Op := Emit(opSS, tcFix, 2);
              else
                Op := Emit(opSF, tcFix, 2);
              end;
              FBlock.Ops[Op].Opd := Opd;
            end;
          end;
        lkCU, lkCD:
          if Opnd1(Ce.Opnd, True, 'counter') then
          begin
            if Opd.A.Area <> arC then Msg('counter C n expected')
            else
            begin
              if Ce.Kind = lkCU then Op := Emit(opCU, tcFix, 2) else Op := Emit(opCD, tcFix, 2);
              FBlock.Ops[Op].Opd := Opd;
            end;
          end;
        lkSC:
          if Opnd1(Ce.Opnd, True, 'counter') then
          begin
            if Opd.A.Area <> arC then Msg('counter C n expected')
            else if Par(0, Ce.P[0], 2, False, False, False) then
            begin
              Op := Emit(opL, tcWord);
              FBlock.Ops[Op].Opd := Pars[0];
              Op := Emit(opSC, tcFix, 2);
              FBlock.Ops[Op].Opd := Opd;
            end;
          end;
        lkSel..lkSR:
          begin
            // a box of an SCL function: its SCL; the pins resolved for the monitor
            if LadBoxScl(Ce, E, SclErr) then CompileSclText(E, LadKindNames[Ce.Kind])
            else Msg(LadKindNames[Ce.Kind] + ': ' + SclErr);
            for I := 0 to LadParamCount(Ce.Kind) - 1 do
              if (Trim(Ce.P[I]) <> '') and not FRes.Resolve(Ce.P[I], Pars[I], SclErr, True) then Pars[I].Kind := okNone;
            if (Trim(Ce.Opnd) <> '') and not FRes.Resolve(Ce.Opnd, Opd, SclErr, False) then Opd.Kind := okNone;
          end;
        lkTON, lkTOF, lkTP, lkTONR, lkCTU, lkCTD, lkCTUD:
          if IecVariant(Ce.Opnd) then
          begin
            // TON_LTIME, CTU_DINT ..: the instance has a layout of its own, the box goes through SCL
            if LadIecScl(Ce, E) then CompileSclText(E, LadKindNames[Ce.Kind]);
            if not FRes.Resolve(Ce.Opnd, Opd, SclErr, False) then Opd.Kind := okNone;
            for I := 0 to LadParamCount(Ce.Kind) - 1 do
              if (Trim(Ce.P[I]) <> '') and not FRes.Resolve(Ce.P[I], Pars[I], SclErr, True) then Pars[I].Kind := okNone;
          end
          else
            case Ce.Kind of
              lkTON, lkTOF, lkTP: LadIec;
              lkTONR:
                if Instance(dtIECTimer) and Par(0, Ce.P[0], 4, False, False, False) and
                  Par(1, Ce.P[1], 0, False, True, True) and Par(2, Ce.P[2], 4, True, True, False) then
                  EmitBox(opTONR, 3, tcFix, 14);
              lkCTU, lkCTD:
                if Instance(dtIECCounter) and Par(0, Ce.P[0], 2, False, False, False) and
                  Par(1, Ce.P[1], 0, False, True, True) and Par(2, Ce.P[2], 2, True, True, False) then
                begin
                  if Ce.Kind = lkCTU then EmitBox(opCTU, 3, tcFix, 8) else EmitBox(opCTD, 3, tcFix, 8);
                end;
            else
              if Instance(dtIECCounter) and Par(0, Ce.P[0], 2, False, False, False) and
                Par(1, Ce.P[1], 0, False, True, True) and Par(2, Ce.P[2], 0, False, True, True) and
                Par(3, Ce.P[3], 0, False, True, True) and Par(4, Ce.P[4], 2, True, True, False) then
                EmitBox(opCTUD, 5, tcFix, 10);
            end;
        lkCmp:
          if Par(0, Ce.P[0], TypeBytes(Ce.DType), False, False, False) and
            Par(1, Ce.P[1], TypeBytes(Ce.DType), False, False, False) then
          begin
            if Ce.DType = dtReal then EmitBox(opBoxCmp, 2, tcFloat, 3) else EmitBox(opBoxCmp, 2, tcFix, 3);
          end;
        lkMove:
          if Par(0, Ce.P[0], TypeBytes(Ce.DType), False, False, False) and
            Par(1, Ce.P[1], TypeBytes(Ce.DType), True, False, False) then
            EmitBox(opBoxMove, 2, tcWord, 2);
        lkAdd, lkSub, lkMul, lkDiv:
          if Par(0, Ce.P[0], TypeBytes(Ce.DType), False, False, False) and
            Par(1, Ce.P[1], TypeBytes(Ce.DType), False, False, False) and
            Par(2, Ce.P[2], TypeBytes(Ce.DType), True, False, False) then
          begin
            if Ce.DType = dtReal then EmitBox(opBoxMath, 3, tcFloat, 3) else EmitBox(opBoxMath, 3, tcFix, 3);
            FBlock.Ops[Op].Sub := Ord(Ce.Kind) - Ord(lkAdd);
          end;
        lkNormX:
          if Par(0, Ce.P[0], TypeBytes(Ce.DType), False, False, False) and
            Par(1, Ce.P[1], TypeBytes(Ce.DType), False, False, False) and
            Par(2, Ce.P[2], TypeBytes(Ce.DType), False, False, False) and
            Par(3, Ce.P[3], 4, True, False, False) then
            EmitBox(opNormX, 4, tcFloat, 6);
        lkScaleX:
          if Par(0, Ce.P[0], TypeBytes(Ce.DType), False, False, False) and
            Par(1, Ce.P[1], 4, False, False, False) and
            Par(2, Ce.P[2], TypeBytes(Ce.DType), False, False, False) and
            Par(3, Ce.P[3], TypeBytes(Ce.DType), True, False, False) then
            EmitBox(opScaleX, 4, tcFloat, 6);
        lkInRange, lkOutRange:
          if Par(0, Ce.P[0], TypeBytes(Ce.DType), False, False, False) and
            Par(1, Ce.P[1], TypeBytes(Ce.DType), False, False, False) and
            Par(2, Ce.P[2], TypeBytes(Ce.DType), False, False, False) then
          begin
            if Ce.DType = dtReal then EmitBox(opBoxRange, 3, tcFloat, 3) else EmitBox(opBoxRange, 3, tcFix, 3);
            FBlock.Ops[Op].Sub := Ord(Ce.Kind = lkOutRange);
          end;
        lkConv, lkRound, lkTrunc, lkCeil, lkFloor:
          if (Ce.Kind <> lkConv) and (Ce.DType <> dtReal) then
            Msg(LadKindNames[Ce.Kind] + ': IN is a Real')
          else if (Ce.Kind <> lkConv) and (Ce.DType2 in [dtReal, dtBool]) then
            Msg(LadKindNames[Ce.Kind] + ': OUT is an integer type')
          else if Par(0, Ce.P[0], TypeBytes(Ce.DType), False, False, False) and
            Par(1, Ce.P[1], TypeBytes(Ce.DType2), True, False, False) then
          begin
            EmitBox(opBoxConv, 2, tcFloat, 3);
            FBlock.Ops[Op].Sub := (Ord(Ce.Kind) - Ord(lkConv)) shl 8 + Ord(Ce.DType2);
          end;
        lkCall:
          begin
            // the pins of the box: the block's parameters (Input, InOut, Output, Return)
            CallBlk := nil;
            if FBInstance(Ce.Opnd, K, FbInst, E) then CallBlk := FProject.FindBlock(bkFB, FProg.Blocks[K].Number)
            else if E = '' then CallBlk := FCRef(Ce.Opnd);
            if E <> '' then
              Msg(E)
            else if CallBlk = nil then
            begin
              if BlockRef(Ce.Opnd, K) then ;
            end
            else
            begin
              Pins := CallPins(CallBlk);
              SetLength(CNames, 0);
              SetLength(CActs, 0);
              for I := 0 to High(Pins) do
                if CallArg(Ce, I) <> '' then
                begin
                  SetLength(CNames, Length(CNames) + 1);
                  SetLength(CActs, Length(CActs) + 1);
                  CNames[High(CNames)] := CallBlk.Iface.Vars[Pins[I]].Name;
                  CActs[High(CActs)] := CallArg(Ce, I);
                end;
              if CallBlk.Kind = bkFB then
              begin
                if FbInst.A.Area = arDB then E := '"' + FProject.FindDB(FbInst.A.DB).Name + '"' else E := Trim(Ce.Opnd);
                if Pos(',', E) > 0 then E := Trim(Copy(E, Pos(',', E) + 1, MaxInt));
                if Length(CNames) = 0 then
                begin
                  Op := Emit(opCALLFB, tcWord, 6);
                  FBlock.Ops[Op].Ext := K;
                  FBlock.Ops[Op].Opd := FbInst;
                  FBlock.Ops[Op].Sub := 1;
                end
                else
                  ParamCall(CallBlk, K, E, FbInst, CNames, CActs, [], True);
              end
              else if Length(Pins) = 0 then
              begin
                Op := Emit(opCC, tcWord, 4);
                FBlock.Ops[Op].Ext := FProg.FindBlock(bkFC, CallBlk.Number);
              end
              else
                ParamCall(CallBlk, FProg.FindBlock(bkFC, CallBlk.Number), '', FbInst, CNames, CActs, [], True);
            end;
          end;
      else
        Box := False;
      end;
      if not Box then Msg('element not supported here');
      // the resolved operands of the cell, for the monitor
      FBlock.Nets[NI].CellOps[Cell][0] := Opd;
      for I := 0 to 4 do FBlock.Nets[NI].CellOps[Cell][I + 1] := Pars[I];
      Op := Emit(opLadStore, tcBit);
      FBlock.Ops[Op].Sub := R;
      FBlock.Ops[Op].Mon := Base + Cell * 2 + 1;
    end;
    // join the rows linked on the right edge of this column
    for R := 0 to MaxLadRows - 1 do Grp[R] := -1;
    G := 0;
    R := 0;
    while R < N.Rows do
    begin
      if N.Cell(R, C).Down and (R + 1 < N.Rows) then
      begin
        K := R;
        while (K + 1 < N.Rows) and N.Cell(K, C).Down do Inc(K);
        for I := R to K do Grp[I] := G;
        Inc(G);
        R := K + 1;
      end
      else
        Inc(R);
    end;
    if not Any and (G = 0) then
    begin
      // nothing in this column: every row's power ends here
      Op := Emit(opLadCol, tcBit);
      FBlock.Ops[Op].Ext := Length(FBlock.LadTables);
      SetLength(FBlock.LadTables, Length(FBlock.LadTables) + 1);
      FBlock.LadTables[High(FBlock.LadTables)] := Grp;
      Continue;
    end;
    Op := Emit(opLadCol, tcBit);
    FBlock.Ops[Op].Ext := Length(FBlock.LadTables);
    SetLength(FBlock.LadTables, Length(FBlock.LadTables) + 1);
    FBlock.LadTables[High(FBlock.LadTables)] := Grp;
  end;
  FLine := -1;
end;

procedure TCompiler.CompileBlock(B: TBlock; Index: Integer);
var
  I, J, K, Slots, T, M0: Integer;
  N, Sn: TNetwork;
  Gen: array of TStringList;
  Errs: TStringList;
  LN: TIntArray;
  Bx: string;

  { the box of a line of an FBD / CFC network: its number for a message }
  function BoxOf(NI, L: Integer): string;
  var
    Q: Integer;
  begin
    Result := '';
    if (L < 0) or (L > High(FBlock.Nets[NI].LineNode)) or (FBlock.Nets[NI].LineNode[L] = 0) then Exit;
    Q := B.Net(NI).NodeIndex(FBlock.Nets[NI].LineNode[L]);
    if Q >= 0 then Result := Format('box #%d %s: ', [FBlock.Nets[NI].LineNode[L], FbdBoxDefOf(B.Net(NI).Nodes[Q].Box).Title]);
  end;

begin
  FSrc := B;
  FBlock := FProg.Blocks[Index];
  FLabels.Clear;
  FFixups.Clear;
  FTemps.Clear;
  FTempOfs := 0;
  FConsts.Clear;
  FConstV := nil;
  FConstI := nil;
  FConstT := nil;
  // the interface: Temp in the local data, the rest (FB only) in the instance
  B.Iface.Name := B.Name;
  B.Iface.Number := B.Number;
  B.Iface.Layout;
  FRes.Iface := nil;
  if B.Kind in [bkFB, bkFC, bkOB] then FRes.Iface := B.Iface;
  K := 0;
  for I := 0 to High(B.Iface.Vars) do
  begin
    FNet := -1;
    FLine := -1;
    if not B.Iface.Vars[I].Valid then
      Msg(Format('%s.%s: unknown data type "%s"', [B.Title, B.Iface.Vars[I].Name, B.Iface.Vars[I].TypeText]))
    else if B.Iface.Vars[I].Section = vsTemp then
    begin
      if B.Iface.Vars[I].DType in [dtIECTimer, dtIECCounter] then
        Msg(Format('%s.%s: timers / counters keep their state, declare them Static', [B.Title, B.Iface.Vars[I].Name]));
      FTemps.AddObject(UpperCase(B.Iface.Vars[I].Name) + '=' + B.Iface.Vars[I].TypeText,
        TObject(PtrInt(B.Iface.Vars[I].Ofs * 8 + B.Iface.Vars[I].Bit)));
    end
    else if (B.Kind = bkOB) and not B.Iface.Vars[I].System then
      Msg(Format('%s.%s: an OB has its start information (Input) and Temp only', [B.Title, B.Iface.Vars[I].Name]))
    else if B.Kind = bkOB then
    else if (B.Kind = bkFC) and (B.Iface.Vars[I].Section = vsStatic) then
      Msg(Format('%s.%s: an FC has no Static (no instance): use an FB or a DB', [B.Title, B.Iface.Vars[I].Name]))
    else if (B.Kind = bkFB) and (B.Iface.Vars[I].Section = vsReturn) then
      Msg(Format('%s.%s: an FB has no Return value: use an Output', [B.Title, B.Iface.Vars[I].Name]))
    else if B.Iface.Vars[I].Section = vsReturn then
    begin
      Inc(K);
      if K > 1 then Msg(Format('%s: only one Return value', [B.Title]));
      if B.Iface.Vars[I].IsArray or (B.Iface.Vars[I].DType in [dtStruct, dtIECTimer, dtIECCounter]) then
        Msg(Format('%s.%s: the Return value must be an elementary type', [B.Title, B.Iface.Vars[I].Name]));
    end;
  end;
  FTempOfs := B.Iface.TempSize * 8;
  if B.Iface.TempSize > 256 then Msg(Format('%s: more than 256 bytes of local data (Temp, FC parameters)', [B.Title]));
  SetLength(FBlock.Nets, B.NetCount);
  Slots := 0;
  // FBD / CFC: their SCL first (its lines are the monitor slots)
  SetLength(Gen, B.NetCount);
  Errs := TStringList.Create;
  for I := 0 to B.NetCount - 1 do
    if B.Net(I).Kind in [nkFBD, nkCFC] then
    begin
      Gen[I] := TStringList.Create;
      Errs.Clear;
      FbdToScl(B.Net(I), FProject, Gen[I], LN, Errs, B, I + 1);
      FBlock.Nets[I].LineNode := LN;
      SetLength(FBlock.Nets[I].Scl, Gen[I].Count);
      for J := 0 to Gen[I].Count - 1 do FBlock.Nets[I].Scl[J] := Gen[I][J];
      FNet := I;
      FLine := -1;
      for J := 0 to Errs.Count - 1 do
      begin
        Bx := Copy(Errs[J], 1, Pos('|', Errs[J]) - 1);
        Msg(Format('box #%s: %s', [Bx, Copy(Errs[J], Pos('|', Errs[J]) + 1, MaxInt)]));
      end;
      if (B.Net(I).Kind = nkFBD) or (Length(B.Net(I).Nodes) = 0) then ;
    end
    else Gen[I] := nil;
  Errs.Free;
  for I := 0 to B.NetCount - 1 do
  begin
    N := B.Net(I);
    FBlock.Nets[I].Kind := N.Kind;
    FBlock.Nets[I].MonBase := Slots;
    FBlock.Nets[I].Rows := N.Rows;
    FBlock.Nets[I].Cols := N.Cols;
    if N.Kind in [nkFBD, nkCFC] then
    begin
      FBlock.Nets[I].Lines := Gen[I].Count;
      Inc(Slots, Gen[I].Count);
    end
    else if N.Kind in [nkSTL, nkSCL] then
    begin
      FBlock.Nets[I].Lines := N.Stl.Count;
      Inc(Slots, N.Stl.Count);
    end
    else
      Inc(Slots, N.Rows * N.Cols * 2);
  end;
  SetLength(FBlock.Mon, Slots);
  for I := 0 to B.NetCount - 1 do
  begin
    FNet := I;
    FLine := -1;
    N := B.Net(I);
    FBlock.Nets[I].FirstOp := Length(FBlock.Ops);
    J := Emit(opNetBegin, tcBit, 0);
    FBlock.Ops[J].Sub := I;
    case N.Kind of
      nkSTL: CompileStl(N);
      nkSCL: CompileScl(N);
      nkFBD, nkCFC:
        begin
          // the SCL of the boxes; its messages name the box of the line
          Sn := TNetwork.Create(nkSCL);
          try
            Sn.Stl.Assign(Gen[I]);
            M0 := Length(FProg.Msgs);
            CompileScl(Sn);
            for J := M0 to High(FProg.Msgs) do
              if FProg.Msgs[J].Net = I + 1 then
                FProg.Msgs[J].Text := BoxOf(I, FProg.Msgs[J].Line - 1) + FProg.Msgs[J].Text;
          finally
            Sn.Free;
          end;
        end;
    else
      CompileLad(N);
    end;
  end;
  for I := 0 to High(Gen) do Gen[I].Free;
  FNet := B.NetCount - 1;
  FLine := -1;
  // the block end
  Emit(opBEU, tcWord);
  // resolve jumps
  for I := 0 to FFixups.Count - 1 do
  begin
    J := FLabels.IndexOf(FFixups[I]);
    T := PtrInt(FFixups.Objects[I]);
    if J < 0 then
    begin
      FNet := FBlock.Ops[T].Net;
      FLine := FBlock.Ops[T].Line;
      Msg('jump label ' + FFixups[I] + ' not found');
    end
    else
      FBlock.Ops[T].Ext := PtrInt(FLabels.Objects[J]);
  end;
  // work memory: about 4 bytes per op + 36 bytes block header
  FBlock.CodeBytes := 36 + Length(FBlock.Ops) * 4 + Length(FBlock.Params) * 6;
  FRes.Iface := nil;
  FSrc := nil;
end;

{ the start values of every DB }
procedure TCompiler.BuildDBs;
var
  I, J, K, Sz, N: Integer;
  D: TDataBlock;
  V: TDbVar;

  procedure Put(Ofs, Bytes: Integer; Val: LongWord);
  var
    B: Integer;
  begin
    for B := 0 to Bytes - 1 do
      if Ofs + B < Length(FProg.DBs[I].Init) then
        FProg.DBs[I].Init[Ofs + B] := (Val shr ((Bytes - 1 - B) * 8)) and $FF;
  end;

  procedure Put8(Ofs: Integer; Q: QWord);
  begin
    Put(Ofs, 4, LongWord(Q shr 32));
    Put(Ofs + 4, 4, LongWord(Q));
  end;

  { the 8 bytes of a 64 bit start value: T#.. into an LTime in ns, a number into an LReal }
  function Start64(T: TDataType; const Cn: TConst): QWord;
  var
    D: Double;
    I: Int64;
  begin
    if T = dtLReal then
    begin
      if Cn.Kind = ckReal then D := Cn.R else D := Cn.I;
      Move(D, Result, 8);
      Exit;
    end;
    I := Cn.I;
    if (Cn.Kind = ckTime) and (T in [dtLTime, dtLTOD]) then I := I * 1000000;
    if T = dtDT then Exit(EncodeDT(I));
    Result := QWord(I);
  end;

  { a String / WString at Ofs: its max length, the length and the characters of the start value }
  procedure InitStr(Ofs: Integer; U: TDataBlock; St: string; const Where: string; Report: Boolean);
  var
    S: UnicodeString;
    Q, K, Len: Integer;
  begin
    if (U = nil) or (U.StrMax <= 0) then Exit;
    St := Trim(St);
    Q := Pos('#', St);
    if (Q > 0) and (Q < Pos('''', St)) then Delete(St, 1, Q);   // STRING#'..', WSTRING#'..'
    S := '';
    if (Length(St) >= 2) and (St[1] = '''') and (St[Length(St)] = '''') then
      S := UTF8Decode(SclStrDecode(Copy(St, 2, Length(St) - 2), U.StrWide))
    else if (St <> '') and Report then
      Msg(Format('%s: start value %s is not a string (''text'')', [Where, St]));
    Len := Min(Length(S), U.StrMax);
    if Ofs + U.Size > Length(FProg.DBs[I].Init) then Exit;
    if U.StrWide then
    begin
      Put(Ofs, 2, U.StrMax);
      Put(Ofs + 2, 2, Len);
      for K := 1 to Len do Put(Ofs + 2 + 2 * K, 2, Ord(S[K]));
    end
    else
    begin
      FProg.DBs[I].Init[Ofs] := U.StrMax;
      FProg.DBs[I].Init[Ofs + 1] := Len;
      for K := 1 to Len do
        if Ord(S[K]) > 255 then FProg.DBs[I].Init[Ofs + 1 + K] := Ord('?')
        else FProg.DBs[I].Init[Ofs + 1 + K] := Ord(S[K]);
    end;
  end;

  { start values of Src's variables at byte Base; a struct recurses into its members }
  procedure InitVars(Src: TDataBlock; Base: Integer; const Where: string; Report: Boolean);
  var
    J, K, E, N, Sz, Stride: Integer;
    V: TDbVar;
    Cn: TConst;
    Bits: LongWord;
    Sg: Single;
    Items: TStringArray;
    St: string;
  begin
    for J := 0 to High(Src.Vars) do
    begin
      V := Src.Vars[J];
      if not V.Valid then
      begin
        if Report then Msg(Format('%s.%s: unknown data type "%s"', [Where, V.Name, V.TypeText]));
        Continue;
      end;
      if Report and (FModel.Family <> cfS71500) and (V.DType in [dtLWord, dtLInt, dtULInt, dtLTime, dtLTOD, dtLDT]) then
        Msg(Format('%s.%s: %s only exists on the S7-1500', [Where, V.Name, DataTypeNames[V.DType]]));
      if Report and (FModel.Family = cfS71200) and (V.DType = dtDT) then
        Msg(Format('%s.%s: Date_And_Time does not exist on the S7-1200 (DTL)', [Where, V.Name]));
      if Report and not IsTia(FModel.Family) and (V.DType in [dtSInt, dtUSInt, dtUInt, dtUDInt, dtWChar, dtWString, dtLReal]) then
        Msg(Format('%s.%s: %s only exists on the S7-1200 / S7-1500', [Where, V.Name, DataTypeNames[V.DType]]));
      if V.IsArray then N := V.Hi - V.Lo + 1 else N := 1;
      Stride := ElemStride(V.DType, V.Udt);
      if V.DType = dtStruct then
      begin
        for E := 0 to N - 1 do
          InitVars(V.Udt, Base + V.Ofs + E * Stride, Where + '.' + V.Name, Report and (E = 0));
        Continue;
      end;
      if V.DType in [dtString, dtWString] then
      begin
        // the max length in the head of every string, the start value after it
        if V.IsArray and (Copy(Trim(V.Start), 1, 1) = '[') then Items := ExpandInitList(V.Start) else Items := nil;
        for E := 0 to N - 1 do
        begin
          if Items <> nil then
          begin
            if E <= High(Items) then St := Items[E] else St := '';
          end
          else
            St := V.Start;
          InitStr(Base + V.Ofs + E * Stride, V.Udt, St, Where + '.' + V.Name, Report and (E = 0));
        end;
        Continue;
      end;
      if Trim(V.Start) = '' then Continue;
      if V.DType in [dtIECTimer, dtIECCounter] then Continue;
      // an array: one value for all elements, or a list "[1, 2, 3(7)]"
      if V.IsArray and (Copy(Trim(V.Start), 1, 1) = '[') then Items := ExpandInitList(V.Start) else Items := nil;
      Sz := DataTypeSize(V.DType);
      for E := 0 to N - 1 do
      begin
        if Items <> nil then
        begin
          if E > High(Items) then Break;
          St := Items[E];
        end
        else
          St := V.Start;
        if not ParseStartValue(St, Cn) then
        begin
          if Report then Msg(Format('%s.%s: start value "%s" is not a constant', [Where, V.Name, St]));
          Break;
        end;
        Bits := Cn.Bits;
        if (V.DType = dtReal) and (Cn.Kind in [ckInt, ckDInt]) then
        begin
          Sg := Cn.I;
          Bits := PLongWord(@Sg)^;
        end;
        if (V.DType in [dtDInt, dtTime]) and (Cn.Kind = ckInt) then Bits := LongWord(LongInt(Cn.I));
        if DataTypeSize(V.DType) = 8 then
        begin
          // 64 bit: LReal, DT in BCD, the integers / times as they are
          Put8(Base + V.Ofs + E * Stride, Start64(V.DType, Cn));
          Continue;
        end;
        if V.DType = dtBool then
        begin
          K := V.Bit + E;
          if Bits <> 0 then
            FProg.DBs[I].Init[Base + V.Ofs + K div 8] := FProg.DBs[I].Init[Base + V.Ofs + K div 8] or (1 shl (K mod 8));
        end
        else
          Put(Base + V.Ofs + E * Stride, Sz, Bits);
      end;
    end;
  end;

begin
  SetLength(FProg.DBs, FProject.DBCount);
  for I := 0 to FProject.DBCount - 1 do
  begin
    D := FProject.DB(I);
    D.Layout;
    FProg.DBs[I].Number := D.Number;
    FProg.DBs[I].Name := D.Name;
    FProg.DBs[I].Size := D.Size;
    FProg.DBs[I].Optimized := D.Optimized and IsTia(FModel.Family);
    SetLength(FProg.DBs[I].Init, D.Size);
    SetLength(FProg.DBs[I].RetainMask, D.Size);
    if D.Size > 0 then
    begin
      FillChar(FProg.DBs[I].Init[0], D.Size, 0);
      FillChar(FProg.DBs[I].RetainMask[0], D.Size, 0);
    end;
    if (D.Number < 1) or (D.Number > FModel.MaxDB) then
    begin
      FLine := -1;
      FNet := -1;
      Msg(Format('DB%d: the %s allows DB1..DB%d', [D.Number, FModel.Name, FModel.MaxDB]));
    end;
    if (D.InstanceOf > 0) and (FProject.InstanceFB(D) = nil) then
      Msg(Format('DB%d is the instance of FB%d, which does not exist', [D.Number, D.InstanceOf]));
    if D.Size > FModel.MaxDBSize then
      Msg(Format('DB%d: %d bytes, the %s allows %d', [D.Number, D.Size, FModel.Name, FModel.MaxDBSize]));
    InitVars(D, 0, Format('DB%d', [D.Number]), True);
    for J := 0 to High(D.Vars) do
    begin
      V := D.Vars[J];
      if not V.Valid or not V.Retain then Continue;
      if V.IsArray then N := V.Hi - V.Lo + 1 else N := 1;
      if V.DType = dtBool then Sz := (V.Bit + N + 7) div 8
      else Sz := Max(1, ElemStride(V.DType, V.Udt)) * N;
      for K := V.Ofs to Min(D.Size - 1, V.Ofs + Sz - 1) do FProg.DBs[I].RetainMask[K] := 1;
    end;
    Inc(FProg.DataBytes, D.Size);
  end;
end;

function TCompiler.Run: TCProgram;
var
  I, Ix, J2: Integer;
  B: TBlock;
  Allowed: Boolean;
  Ev: TObEvent;
  Info: TObInfo;
  TA: TAddr;
  Er: string;
begin
  FProg := TCProgram.Create;
  FProg.ModelIdx := FProject.ModelIdx;
  FProg.Family := FModel.Family;
  FProg.CyclicMs := FProject.CyclicMs;
  FProg.ClockByte := FProject.ClockByte;
  if IsTia(FModel.Family) then FProg.SysByte := FProject.SysByte else FProg.SysByte := -1;
  FProg.OB1 := -1;
  FProg.OBCyc := -1;
  FProg.OB100 := -1;
  FNet := -1;
  FLine := -1;
  // every block first, so that calls can refer forwards
  SetLength(FProg.Blocks, FProject.BlockCount);
  for I := 0 to FProject.BlockCount - 1 do
  begin
    B := FProject.Block(I);
    FProg.Blocks[I] := TCBlock.Create;
    FProg.Blocks[I].Kind := B.Kind;
    FProg.Blocks[I].Number := B.Number;
    FProg.Blocks[I].Name := B.Name;
  end;
  BuildDBs;
  for I := 0 to FProject.BlockCount - 1 do
  begin
    B := FProject.Block(I);
    FSrc := B;
    if B.Kind = bkOB then
    begin
      // the OBs of the family: a standard number, or one of its own (>= 123) of an event that allows it
      Ev := FProject.ObEventOfBlock(B);
      Allowed := ObInfoOf(FModel.Family, B.Number, Info) or ((B.Number >= 123) and ObCustomOk(FModel.Family, Ev));
      if not Allowed then
        Msg(Format('OB%d is not an OB of the %s (see + OB: the standard OBs and the numbers of your own)',
          [B.Number, FamilyNames[FModel.Family]]), False)
      else if not ObSimulated(Ev) then
        Msg(Format('OB%d (%s): its event does not happen in the Virtual PLC, the OB is not started', [B.Number,
          ObEventNames[Ev]]), False);
      if B.Number = 1 then FProg.OB1 := I;
      if B.Number = 100 then FProg.OB100 := I;
      if Allowed then
      begin
        SetLength(FProg.Obs, Length(FProg.Obs) + 1);
        with FProg.Obs[High(FProg.Obs)] do
        begin
          BI := I;
          Number := B.Number;
          Event := Ev;
          Prio := Info.Prio;
          if Prio = 0 then Prio := 1;
          CycleMs := Max(1, FProject.ObCycleMs(B));
          PhaseMs := Max(0, B.PhaseMs);
          TrigOk := False;
          TrigEdge := EnsureRange(B.TrigEdge, 0, 2);
          if Ev = oeHardware then
          begin
            if ParseAddr(B.TrigAddr, TA, Er) and (TA.Area in [arI, arPI]) and (TA.Size = osBit) then
            begin
              TrigOk := True;
              TrigOfs := TA.Ofs;
              TrigBit := TA.Bit;
            end
            else
              Msg(Format('OB%d: its hardware interrupt needs an input bit (e.g. %%I0.0), not "%s"', [B.Number,
                B.TrigAddr]), False);
          end;
          TodMode := EnsureRange(B.TodMode, 0, High(TodModeNames));
          TodActive := B.TodActive;
          TodOk := ParseTodStart(B.TodStart, TodStart);
          if (Ev = oeTimeOfDay) and TodActive and not TodOk then
            Msg(Format('OB%d: the start "%s" is no date and time (yyyy-mm-dd hh:mm:ss)', [B.Number, B.TodStart]), False);
          if (Ev = oeCyclic) and (FProg.OBCyc < 0) then FProg.OBCyc := I;
        end;
      end;
    end;
    CompileBlock(B, I);
    if B.Kind = bkOB then
    begin
      // where the CPU writes the start information
      for Ix := 0 to High(B.Iface.Vars) do
        if B.Iface.Vars[Ix].System and B.Iface.Vars[Ix].Valid then
        begin
          J2 := Length(FProg.Blocks[I].StartInfo);
          SetLength(FProg.Blocks[I].StartInfo, J2 + 1);
          FProg.Blocks[I].StartInfo[J2].Key := ObStartKey(B.Iface.Vars[Ix].Name);
          FProg.Blocks[I].StartInfo[J2].Ofs := B.Iface.Vars[Ix].Ofs;
          FProg.Blocks[I].StartInfo[J2].Bit := B.Iface.Vars[Ix].Bit;
          FProg.Blocks[I].StartInfo[J2].DType := B.Iface.Vars[Ix].DType;
        end;
    end;
    Inc(FProg.CodeBytes, FProg.Blocks[I].CodeBytes);
  end;
  FSrc := nil;
  FNet := -1;
  FLine := -1;
  if FProg.OB1 < 0 then Msg('OB1 is missing: the CPU cannot go to RUN');
  // a call cycle would recurse for ever
  for I := 0 to High(FProg.Blocks) do
    for Ix := 0 to High(FProg.Blocks[I].Ops) do
      if (FProg.Blocks[I].Ops[Ix].Code in [opCALL, opCC, opCALLFB]) and (FProg.Blocks[I].Ops[Ix].Ext = I) then
      begin
        FSrc := FProject.Block(I);
        FNet := FProg.Blocks[I].Ops[Ix].Net;
        FLine := FProg.Blocks[I].Ops[Ix].Line;
        Msg('a block calls itself');
      end;
  FSrc := nil;
  if FProg.CodeBytes + FProg.DataBytes > FModel.WorkMem then
    Msg(Format('program needs %d bytes, the %s has %d bytes work memory',
      [FProg.CodeBytes + FProg.DataBytes, FModel.Name, FModel.WorkMem]));
  Result := FProg;
end;

function Compile(AProject: TPlcProject): TCProgram;
var
  C: TCompiler;
begin
  C := TCompiler.Create(AProject);
  try
    Result := C.Run;
  finally
    C.Free;
  end;
end;

end.
