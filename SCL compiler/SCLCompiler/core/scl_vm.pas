{ Reference Virtual PLC interpreter for .svpl images.
  Used by the compiler test harness (sclc --sim) and as executable specification of the
  instruction set for the real Virtual PLC. }
unit scl_vm;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, scl_vmformat, scl_vmmem;

type
  PBytes = ^TBytes;

  EVmError = class(Exception);
  { an error of the program (an S7 CPU calls OB121 for it): array index, missing DB, null pointer, address }
  EVmProgError = class(EVmError);

  TVirtualPlc = class
  private
    FImg: TSvImage;
    FOwnsImg: Boolean;
    FI, FQ, FM, FL: TBytes;
    FDB: array of TBytes;          // index = DB number
    FStack: array of TVmValue;
    FSP: Integer;
    FLTop: Integer;
    FPending: array of Integer;
    FNowNs: Int64;
    FDepth: Integer;
    FLastCyclic: array of Int64;
    FSubst: TBytes;                // the substitute of a faulty access: reads 0, writes go nowhere
    FContinue: Boolean;            // a faulty access goes on with the substitute (S7-1200, or OB121 loaded)
    FOb121: Integer;               // the block index of OB121, -1 none
    FOb121Due: Boolean;            // a programming error in this OB: OB121 runs after it
    function SubstAddr(const Msg: string; BI: Integer): Int64;
    procedure NoteError(const Msg: string; BI: Integer);
    procedure Push(const V: TVmValue); inline;
    procedure PushI(V: Int64); inline;
    procedure PushF(V: Double); inline;
    function Pop: TVmValue; inline;
    function PopI: Int64; inline;
    function PopF: Double; inline;
    function AreaMem(A: Int64): PBytes;
    procedure Execute(BI: Integer; Inst: Int64; FP: Integer);
    procedure SysFB(Id: Integer; CntVT: Byte; Inst: Int64);
    procedure EnsureL(Top: Integer);
    procedure RunOB(BI: Integer; const Inputs: array of string);
    procedure RunOBSafe(BI: Integer; const Inputs: array of string);
    procedure ProgramError(BI: Integer; E: EVmError);
  public
    CycleCount: Int64;
    { the CPU's answer to a run-time error of the program (array index, missing DB, null pointer), like a
      real one: the S7-1200 - and every CPU with OB121 - enters it in the diagnostic buffer and goes on (the
      faulty read gives 0, the faulty write is not done; OB121 runs after the OB); without OB121 the
      S7-300 / 400 / 1500 go to STOP. An internal error (not of the program) always stops. }
    Stopped: Boolean;
    StopNs: Int64;                 // the time of the STOP
    StopReason: string;
    Diag: TStringList;             // the diagnostic buffer, oldest first
    ProgErrors: Integer;
    constructor Create(AImg: TSvImage; AOwns: Boolean = False);
    destructor Destroy; override;
    procedure ColdStart;
    procedure Cycle(CycleMs: Integer);
    function ReadAddr(A: Int64; VT: Byte): TVmValue;
    procedure WriteAddr(A: Int64; VT: Byte; const V: TVmValue);
    function ReadStringAt(A: Int64; Wide: Boolean): string;
    procedure WriteStringAt(A: Int64; const S: string; Wide: Boolean);   { the max. length from the header }
    function FindVar(const Path: string; out A: Int64; out VT: Byte; out TypeText: string): Boolean;
    property NowNs: Int64 read FNowNs write FNowNs;
    property Image: TSvImage read FImg;
  end;

implementation

const
  STACK_SIZE = 4096;
  AREA_SUBST = 15;      // inside the VM only: the substitute of a faulty access
  SUBST_SIZE = 65536;
  L_SIZE = 1024 * 1024;
  PROC_IMG = 8192;

constructor TVirtualPlc.Create(AImg: TSvImage; AOwns: Boolean);
begin
  inherited Create;
  FImg := AImg;
  FOwnsImg := AOwns;
  SetLength(FStack, STACK_SIZE);
  SetLength(FI, PROC_IMG);
  SetLength(FQ, PROC_IMG);
  SetLength(FM, PROC_IMG);
  SetLength(FL, 64 * 1024);
  SetLength(FDB, 65536);
  SetLength(FSubst, SUBST_SIZE);
  FOb121 := -1;
  Diag := TStringList.Create;
end;

destructor TVirtualPlc.Destroy;
begin
  Diag.Free;
  if FOwnsImg then FImg.Free;
  inherited;
end;

procedure TVirtualPlc.Push(const V: TVmValue);
begin
  if FSP >= STACK_SIZE then raise EVmError.Create('Value stack overflow');
  FStack[FSP] := V;
  Inc(FSP);
end;

procedure TVirtualPlc.PushI(V: Int64);
var
  X: TVmValue;
begin
  X.I := V;
  Push(X);
end;

procedure TVirtualPlc.PushF(V: Double);
var
  X: TVmValue;
begin
  X.F := V;
  Push(X);
end;

function TVirtualPlc.Pop: TVmValue;
begin
  if FSP <= 0 then raise EVmError.Create('Value stack underflow');
  Dec(FSP);
  Result := FStack[FSP];
end;

function TVirtualPlc.PopI: Int64;
begin
  Result := Pop.I;
end;

function TVirtualPlc.PopF: Double;
begin
  Result := Pop.F;
end;

procedure TVirtualPlc.EnsureL(Top: Integer);
begin
  if Top > L_SIZE then raise EVmError.Create('Local stack overflow');
  if Top > Length(FL) then SetLength(FL, Max(Top, Length(FL) * 2));
end;

function TVirtualPlc.AreaMem(A: Int64): PBytes;
var
  N: Integer;
begin
  case AddrArea(A) of
    AREA_I, AREA_PI: Result := @FI;
    AREA_Q, AREA_PQ: Result := @FQ;
    AREA_M: Result := @FM;
    AREA_L: Result := @FL;
    AREA_C: Result := @FImg.ConstPool;
    AREA_SUBST: Result := @FSubst;
    AREA_DB:
      begin
        N := AddrDB(A);
        if (N > High(FDB)) or (Length(FDB[N]) = 0) then
        begin
          if not FContinue then raise EVmProgError.CreateFmt('DB%d does not exist', [N]);
          SubstAddr(Format('DB%d does not exist', [N]), -1);
          Result := @FSubst;
        end
        else
          Result := @FDB[N];
      end;
  else
    begin
      if not FContinue then raise EVmProgError.CreateFmt('Invalid address %x', [A]);
      SubstAddr(Format('Invalid address %x', [A]), -1);
      Result := @FSubst;
    end;
  end;
end;

function TVirtualPlc.ReadAddr(A: Int64; VT: Byte): TVmValue;
var
  M: PBytes;
begin
  M := AreaMem(A);
  if VT = VT_PTR then
    Result.I := Int64(MemReadBE(M^, AddrBit(A) div 8, 8))
  else
    Result := MemReadBits(M^, AddrBit(A), VT);
end;

procedure TVirtualPlc.WriteAddr(A: Int64; VT: Byte; const V: TVmValue);
var
  M: PBytes;
begin
  if AddrArea(A) = AREA_C then raise EVmError.Create('Write to constant area');
  M := AreaMem(A);
  if VT = VT_PTR then
    MemWriteBE(M^, AddrBit(A) div 8, 8, QWord(V.I))
  else
    MemWriteBits(M^, AddrBit(A), VT, V);
end;

function TVirtualPlc.ReadStringAt(A: Int64; Wide: Boolean): string;
begin
  Result := MemReadString(AreaMem(A)^, AddrBit(A), Wide);
end;

procedure TVirtualPlc.WriteStringAt(A: Int64; const S: string; Wide: Boolean);
var
  M: PBytes;
  MaxLen: Integer;
begin
  if AddrArea(A) = AREA_C then raise EVmError.Create('Write to constant area');
  M := AreaMem(A);
  if Wide then MaxLen := MemReadBE(M^, AddrBit(A) div 8, 2)
  else MaxLen := MemReadBE(M^, AddrBit(A) div 8, 1);
  MemWriteString(M^, AddrBit(A), MaxLen, S, Wide);
end;

procedure TVirtualPlc.ColdStart;
var
  I: Integer;
  D: TSvDataBlock;
  Order: TList;
begin
  FillChar(FI[0], Length(FI), 0);
  FillChar(FQ[0], Length(FQ), 0);
  FillChar(FM[0], Length(FM), 0);
  for I := 0 to High(FDB) do SetLength(FDB[I], 0);
  for I := 0 to FImg.DataBlocks.Count - 1 do
  begin
    D := FImg.DataBlock(I);
    FDB[D.Number] := Copy(D.Data);
  end;
  FSP := 0;
  FLTop := 0;
  SetLength(FPending, 0);
  CycleCount := 0;
  Stopped := False;
  StopReason := '';
  ProgErrors := 0;
  Diag.Clear;
  FOb121 := -1;
  for I := 0 to FImg.Blocks.Count - 1 do
    if (FImg.Block(I).Kind = BK_OB) and (FImg.Block(I).EventClass = 121) then FOb121 := I;
  FContinue := (FImg.Cpu = 2) or (FOb121 >= 0);
  SetLength(FLastCyclic, FImg.Blocks.Count);
  for I := 0 to High(FLastCyclic) do FLastCyclic[I] := 0;
  Order := TList.Create;
  try
    for I := 0 to FImg.Blocks.Count - 1 do
      if not Stopped and (FImg.Block(I).Kind = BK_OB) and (FImg.Block(I).EventClass = 100) then
        RunOBSafe(I, ['LostRetentive', 'LostRTC']);
  finally
    Order.Free;
  end;
end;

procedure TVirtualPlc.RunOBSafe(BI: Integer; const Inputs: array of string);
begin
  FOb121Due := False;
  try
    RunOB(BI, Inputs);
  except
    on E: EVmError do ProgramError(BI, E);
  end;
  // a programming error went on with the substitute: now OB121
  if FOb121Due and not Stopped and (FOb121 >= 0) and (BI <> FOb121) then
  begin
    FOb121Due := False;
    try
      RunOB(FOb121, []);
    except
      on E2: EVmError do
      begin
        FSP := 0;
        FLTop := 0;
        FDepth := 0;
        SetLength(FPending, 0);
        Diag.Add(Format('t=%.2fs error in OB121: %s', [FNowNs / 1e9, E2.Message]));
        Stopped := True;
        StopNs := FNowNs;
        StopReason := 'error in OB121: ' + E2.Message;
      end;
    end;
  end;
end;

{ an entry of the diagnostic buffer; the same error again is counted, not listed again }
procedure TVirtualPlc.NoteError(const Msg: string; BI: Integer);
var
  T, Last: string;
  P: Integer;
begin
  Inc(ProgErrors);
  if BI >= 0 then T := 'programming error in ' + FImg.Block(BI).Name + ': ' + Msg
  else T := 'programming error: ' + Msg;
  Last := '';
  if Diag.Count > 0 then
  begin
    Last := Diag[Diag.Count - 1];
    P := Pos(' ', Last);
    Last := Copy(Last, P + 1, MaxInt);
  end;
  if Last <> T then Diag.Add(Format('t=%.2fs %s', [FNowNs / 1e9, T]));
end;

function TVirtualPlc.SubstAddr(const Msg: string; BI: Integer): Int64;
begin
  if not FContinue then raise EVmProgError.Create(Msg);
  NoteError(Msg, BI);
  FOb121Due := True;
  FillChar(FSubst[0], SUBST_SIZE, 0);
  Result := MakeAddr(AREA_SUBST, 0, 0);
end;

procedure TVirtualPlc.ProgramError(BI: Integer; E: EVmError);
var
  I, Ob121: Integer;
begin
  // the OB stops where the error was: its stack and frames go
  FSP := 0;
  FLTop := 0;
  FDepth := 0;
  SetLength(FPending, 0);
  if not (E is EVmProgError) then
  begin
    Diag.Add(Format('t=%.2fs internal error in %s: %s', [FNowNs / 1e9, FImg.Block(BI).Name, E.Message]));
    Stopped := True;
    StopNs := FNowNs;
    StopReason := 'internal error: ' + E.Message;
    Exit;
  end;
  NoteError(E.Message, BI);
  Ob121 := -1;
  for I := 0 to FImg.Blocks.Count - 1 do
    if (FImg.Block(I).Kind = BK_OB) and (FImg.Block(I).EventClass = 121) then Ob121 := I;
  if (Ob121 >= 0) and (Ob121 <> BI) then
  begin
    // OB121 handles it, the CPU stays in RUN (an error in OB121 itself stops)
    try
      RunOB(Ob121, []);
    except
      on E2: EVmError do
      begin
        FSP := 0;
        FLTop := 0;
        FDepth := 0;
        SetLength(FPending, 0);
        Diag.Add(Format('t=%.2fs error in OB121: %s', [FNowNs / 1e9, E2.Message]));
        Stopped := True;
        StopNs := FNowNs;
        StopReason := 'error in OB121: ' + E2.Message;
      end;
    end;
  end
  else if (Ob121 < 0) and (FImg.Cpu = 2) then
    // S7-1200 without OB121: entered in the diagnostic buffer, the CPU stays in RUN
  else
  begin
    Stopped := True;
    StopNs := FNowNs;
    StopReason := 'programming error, OB121 not loaded: ' + E.Message;
  end;
end;

procedure TVirtualPlc.RunOB(BI: Integer; const Inputs: array of string);
var
  B: TSvBlock;
  J, K: Integer;
begin
  B := FImg.Block(BI);
  FLTop := 0;
  EnsureL(B.TempBytes);
  FillChar(FL[0], B.TempBytes, 0);
  { OB start information: set TRUE for the given names (cold start of a fresh image) }
  for J := 0 to High(B.Vars) do
    for K := Low(Inputs) to High(Inputs) do
      if SameText(B.Vars[J].Path, Inputs[K]) and (B.Vars[J].VmType = VT_BOOL) then
        MemWriteBits(FL, B.Vars[J].BitOff, VT_BOOL, VmInt(1));
  FLTop := B.TempBytes;
  FDepth := 0;
  Execute(BI, 0, 0);
  FLTop := 0;
  if FSP <> 0 then raise EVmError.CreateFmt('Stack not balanced after %s (%d)', [B.Name, FSP]);
end;

procedure TVirtualPlc.Cycle(CycleMs: Integer);
var
  I: Integer;
  B: TSvBlock;
begin
  if Stopped then
  begin
    // in STOP the time goes on, the program does not run
    Inc(FNowNs, Int64(CycleMs) * 1000000);
    Exit;
  end;
  for I := 0 to FImg.Blocks.Count - 1 do
  begin
    B := FImg.Block(I);
    if (B.Kind = BK_OB) and (B.EventClass = 1) then RunOBSafe(I, []);
    if Stopped then Break;
  end;
  for I := 0 to FImg.Blocks.Count - 1 do
  begin
    B := FImg.Block(I);
    if (B.Kind = BK_OB) and (B.EventClass = 30) and (B.Interval > 0) then
      if not Stopped and (FNowNs - FLastCyclic[I] >= Int64(B.Interval) * 1000000) then
      begin
        FLastCyclic[I] := FNowNs;
        RunOBSafe(I, []);
      end;
  end;
  Inc(CycleCount);
  Inc(FNowNs, Int64(CycleMs) * 1000000);
end;

function RotL(V: QWord; N, W: Integer): QWord;
var
  Msk: QWord;
begin
  if W >= 64 then Msk := High(QWord) else Msk := (QWord(1) shl W) - 1;
  V := V and Msk;
  N := N mod W;
  if N = 0 then Exit(V);
  Result := ((V shl N) or (V shr (W - N))) and Msk;
end;

procedure TVirtualPlc.Execute(BI: Integer; Inst: Int64; FP: Integer);
var
  Code: TBytes;
  P, N: Integer;
  O: TOpcode;
  A, B2, V, Idx: Int64;
  X, Y: TVmValue;
  F1, F2: Double;
  VT, W, Sh: Byte;
  Lo: LongInt;
  Stride, Cnt: Cardinal;
  Cal: TSvBlock;
  Base, Bits, K: Int64;
  S1, S2: string;
  Msk: QWord;
  Wide: Boolean;
  Vals: array of TVmValue;

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
    L0, H0: Cardinal;
  begin
    L0 := RdU32;
    H0 := RdU32;
    Result := Int64(QWord(L0) or (QWord(H0) shl 32));
  end;

  function AddBits(Ad, Delta: Int64): Int64;
  begin
    Result := (Ad and not ADDR_BIT_MASK) or ((AddrBit(Ad) + Delta) and ADDR_BIT_MASK);
  end;

  procedure CmpI(R: Boolean);
  begin
    PushI(Ord(R));
  end;

  function DstMax(Ad: Int64; Wd: Boolean): Integer;
  var
    M: PBytes;
  begin
    M := AreaMem(Ad);
    if Wd then Result := MemReadBE(M^, AddrBit(Ad) div 8, 2)
    else Result := MemReadBE(M^, AddrBit(Ad) div 8, 1);
  end;

  procedure PutStr(Ad: Int64; const S: string; Wd: Boolean);
  begin
    MemWriteString(AreaMem(Ad)^, AddrBit(Ad), DstMax(Ad, Wd), S, Wd);
  end;

begin
  Inc(FDepth);
  if FDepth > 64 then raise EVmError.Create('Call nesting too deep');
  Code := FImg.Block(BI).Code;
  P := 0;
  while P < Length(Code) do
  begin
    O := TOpcode(RdU8);
    case O of
      opNop: ;
      opPushI, opPushAddr: PushI(RdI64);
      opPushF:
        begin
          V := RdI64;
          Move(V, X.F, 8);
          Push(X);
        end;
      opAddrInst: PushI(AddBits(Inst, RdU32));
      opAddrLocal: PushI(MakeAddr(AREA_L, 0, Int64(FP) * 8 + RdU32));
      opAddrNewFrame:
        begin
          if Length(FPending) = 0 then raise EVmError.Create('No pending frame');
          PushI(MakeAddr(AREA_L, 0, Int64(FPending[High(FPending)]) * 8 + RdU32));
        end;
      opAddrAdd:
        begin
          A := PopI;
          PushI(AddBits(A, RdU32));
        end;
      opAddrIndex:
        begin
          Lo := LongInt(RdU32);
          Stride := RdU32;
          Cnt := RdU32;
          Idx := PopI;
          A := PopI;
          if (Idx < Lo) or (Idx >= Int64(Lo) + Cnt) then
            PushI(SubstAddr(Format('Array index %d out of range [%d..%d]', [Idx, Lo, Int64(Lo) + Cnt - 1]), BI))
          else
            PushI(AddBits(A, (Idx - Lo) * Stride));
        end;
      opLoad:
        begin
          VT := RdU8;
          A := PopI;
          Push(ReadAddr(A, VT));
        end;
      opStore:
        begin
          VT := RdU8;
          X := Pop;
          A := PopI;
          WriteAddr(A, VT, X);
        end;
      opLoadPtr:
        begin
          A := PopI;
          X := ReadAddr(A, VT_PTR);
          if X.I = 0 then X.I := SubstAddr('Null pointer (InOut parameter not assigned)', BI);
          Push(X);
        end;
      opMemCpy:
        begin
          Bits := RdU32;
          A := PopI;   // src
          B2 := PopI;  // dst
          K := 0;
          while K < Bits do
          begin
            if ((AddrBit(A) + K) mod 8 = 0) and ((AddrBit(B2) + K) mod 8 = 0) and (Bits - K >= 8) then
            begin
              X := ReadAddr(AddBits(A, K), VT_BYTE);
              WriteAddr(AddBits(B2, K), VT_BYTE, X);
              Inc(K, 8);
            end
            else
            begin
              X := ReadAddr(AddBits(A, K), VT_BOOL);
              WriteAddr(AddBits(B2, K), VT_BOOL, X);
              Inc(K);
            end;
          end;
        end;
      opStrCpy:
        begin
          Wide := RdU8 <> 0;
          A := PopI;
          B2 := PopI;
          PutStr(B2, ReadStringAt(A, Wide), Wide);
        end;
      opDup:
        begin
          X := Pop;
          Push(X);
          Push(X);
        end;
      opDrop: Pop;
      opSwap:
        begin
          X := Pop;
          Y := Pop;
          Push(X);
          Push(Y);
        end;
      opAddI: begin V := PopI; PushI(PopI + V); end;
      opSubI: begin V := PopI; PushI(PopI - V); end;
      opMulI: begin V := PopI; PushI(PopI * V); end;
      opDivI: begin V := PopI; A := PopI; if V = 0 then PushI(0) else PushI(A div V); end;
      opModI: begin V := PopI; A := PopI; if V = 0 then PushI(0) else PushI(A mod V); end;
      opNegI: PushI(-PopI);
      opAbsI: PushI(Abs(PopI));
      opAddF: begin F2 := PopF; PushF(PopF + F2); end;
      opSubF: begin F2 := PopF; PushF(PopF - F2); end;
      opMulF: begin F2 := PopF; PushF(PopF * F2); end;
      opDivF:
        begin
          F2 := PopF;
          F1 := PopF;
          if F2 = 0 then
          begin
            if F1 = 0 then PushF(NaN) else if F1 > 0 then PushF(Infinity) else PushF(NegInfinity);
          end
          else PushF(F1 / F2);
        end;
      opNegF: PushF(-PopF);
      opExptF: begin F2 := PopF; F1 := PopF; PushF(Power(F1, F2)); end;
      opAbsF: PushF(Abs(PopF));
      opAnd: begin V := PopI; PushI(PopI and V); end;
      opOr: begin V := PopI; PushI(PopI or V); end;
      opXor: begin V := PopI; PushI(PopI xor V); end;
      opNot: PushI(not PopI);
      opEqI: begin V := PopI; CmpI(PopI = V); end;
      opNeI: begin V := PopI; CmpI(PopI <> V); end;
      opLtI: begin V := PopI; CmpI(PopI < V); end;
      opLeI: begin V := PopI; CmpI(PopI <= V); end;
      opGtI: begin V := PopI; CmpI(PopI > V); end;
      opGeI: begin V := PopI; CmpI(PopI >= V); end;
      opLtU: begin V := PopI; CmpI(QWord(PopI) < QWord(V)); end;
      opLeU: begin V := PopI; CmpI(QWord(PopI) <= QWord(V)); end;
      opGtU: begin V := PopI; CmpI(QWord(PopI) > QWord(V)); end;
      opGeU: begin V := PopI; CmpI(QWord(PopI) >= QWord(V)); end;
      opEqF: begin F2 := PopF; CmpI(PopF = F2); end;
      opNeF: begin F2 := PopF; CmpI(PopF <> F2); end;
      opLtF: begin F2 := PopF; CmpI(PopF < F2); end;
      opLeF: begin F2 := PopF; CmpI(PopF <= F2); end;
      opGtF: begin F2 := PopF; CmpI(PopF > F2); end;
      opGeF: begin F2 := PopF; CmpI(PopF >= F2); end;
      opWrap: PushI(WrapToVT(PopI, RdU8));
      opI2F: PushF(PopI);
      opU2F: PushF(QWord(PopI));
      opF2ITrunc: PushI(Trunc(PopF));
      opF2IRound: PushI(Round(PopF));
      opF2IFloor: PushI(Floor(PopF));
      opF2ICeil: PushI(Ceil(PopF));
      opF2F32: PushF(Single(PopF));
      opGetBit:
        begin
          Sh := RdU8;
          PushI((PopI shr Sh) and 1);
        end;
      opSetBit:
        begin
          Sh := RdU8;
          B2 := PopI;
          V := PopI;
          if B2 and 1 <> 0 then PushI(V or (Int64(1) shl Sh)) else PushI(V and not (Int64(1) shl Sh));
        end;
      opGetField:
        begin
          Sh := RdU8;
          W := RdU8;
          Msk := (QWord(1) shl W) - 1;
          PushI(Int64((QWord(PopI) shr Sh) and Msk));
        end;
      opSetField:
        begin
          Sh := RdU8;
          W := RdU8;
          Msk := (QWord(1) shl W) - 1;
          B2 := PopI;
          V := PopI;
          PushI(Int64((QWord(V) and not (Msk shl Sh)) or ((QWord(B2) and Msk) shl Sh)));
        end;
      opShl, opShr, opRol, opRor:
        begin
          W := RdU8;
          N := PopI;
          V := PopI;
          if W >= 64 then Msk := High(QWord) else Msk := (QWord(1) shl W) - 1;
          case O of
            opShl: if (N >= W) or (N < 0) then PushI(0) else PushI(Int64((QWord(V) shl N) and Msk));
            opShr: if (N >= W) or (N < 0) then PushI(0) else PushI(Int64((QWord(V) and Msk) shr N));
            opRol: PushI(Int64(RotL(QWord(V), N mod W, W)));
          else
            PushI(Int64(RotL(QWord(V), (W - (N mod W)) mod W, W)));
          end;
        end;
      opMinI: begin V := PopI; A := PopI; PushI(Min(A, V)); end;
      opMaxI: begin V := PopI; A := PopI; PushI(Max(A, V)); end;
      opMinF: begin F2 := PopF; F1 := PopF; PushF(Min(F1, F2)); end;
      opMaxF: begin F2 := PopF; F1 := PopF; PushF(Max(F1, F2)); end;
      opSel:
        begin
          Y := Pop;
          X := Pop;
          if PopI <> 0 then Push(Y) else Push(X);
        end;
      opMuxPick:
        begin
          N := RdU8;
          Idx := PopI;
          SetLength(Vals, N);
          for K := N - 1 downto 0 do Vals[K] := Pop;
          if (Idx >= 0) and (Idx < N) then Push(Vals[Idx]) else PushI(0);
        end;
      opJmp:
        begin
          Lo := LongInt(RdU32);
          Inc(P, Lo);
        end;
      opJz:
        begin
          Lo := LongInt(RdU32);
          if PopI = 0 then Inc(P, Lo);
        end;
      opJnz:
        begin
          Lo := LongInt(RdU32);
          if PopI <> 0 then Inc(P, Lo);
        end;
      opFrameAlloc:
        begin
          N := RdU32;
          EnsureL(FLTop + N);
          FillChar(FL[FLTop], N, 0);
          SetLength(FPending, Length(FPending) + 1);
          FPending[High(FPending)] := FLTop;
          Inc(FLTop, N);
        end;
      opFrameFree:
        begin
          FLTop := FPending[High(FPending)];
          SetLength(FPending, Length(FPending) - 1);
        end;
      opCall:
        begin
          N := RdU16;
          Cal := FImg.Block(N);
          Base := FPending[High(FPending)];
          { pending frame must be on top of the L stack }
          FLTop := Base + Cal.ParamBytes;
          EnsureL(FLTop + Cal.TempBytes);
          if Cal.TempBytes > 0 then FillChar(FL[FLTop], Cal.TempBytes, 0);
          Inc(FLTop, Cal.TempBytes);
          SetLength(FPending, Length(FPending) - 1);
          Execute(N, 0, Base);
          SetLength(FPending, Length(FPending) + 1);
          FPending[High(FPending)] := Base;
          FLTop := Base + Cal.ParamBytes;
        end;
      opCallFB:
        begin
          N := RdU16;
          Cal := FImg.Block(N);
          A := PopI;
          Base := FLTop;
          EnsureL(FLTop + Cal.TempBytes);
          if Cal.TempBytes > 0 then FillChar(FL[FLTop], Cal.TempBytes, 0);
          Inc(FLTop, Cal.TempBytes);
          Execute(N, A, Base);
          FLTop := Base;
        end;
      opRet:
        Break;
      opBuiltin:
        begin
          N := RdU16;
          F1 := PopF;
          case N of
            BI_SQRT: PushF(Sqrt(F1));
            BI_EXP: PushF(Exp(F1));
            BI_LN: PushF(Ln(F1));
            BI_LOG: PushF(Log10(F1));
            BI_SIN: PushF(Sin(F1));
            BI_COS: PushF(Cos(F1));
            BI_TAN: PushF(Tan(F1));
            BI_ASIN: PushF(ArcSin(F1));
            BI_ACOS: PushF(ArcCos(F1));
            BI_ATAN: PushF(ArcTan(F1));
            BI_FRAC: PushF(Frac(F1));
          else
            raise EVmError.CreateFmt('Unknown builtin %d', [N]);
          end;
        end;
      opSysFB:
        begin
          N := RdU16;
          VT := RdU8;
          A := PopI;
          SysFB(N, VT, A);
        end;
      opStrCmp:
        begin
          Wide := RdU8 <> 0;
          B2 := PopI;
          A := PopI;
          S1 := ReadStringAt(A, Wide);
          S2 := ReadStringAt(B2, Wide);
          PushI(Sign(CompareStr(S1, S2)));
        end;
      opStrLen:
        begin
          Wide := RdU8 <> 0;
          PushI(Length(ReadStringAt(PopI, Wide)));
        end;
      opStrConcat:
        begin
          Wide := RdU8 <> 0;
          B2 := PopI;
          A := PopI;
          V := PopI;
          PutStr(V, ReadStringAt(A, Wide) + ReadStringAt(B2, Wide), Wide);
          PushI(V);
        end;
      opStrLeft, opStrRight:
        begin
          Wide := RdU8 <> 0;
          N := PopI;
          A := PopI;
          V := PopI;
          S1 := ReadStringAt(A, Wide);
          if N < 0 then N := 0;
          if O = opStrLeft then S1 := Copy(S1, 1, N)
          else if N < Length(S1) then S1 := Copy(S1, Length(S1) - N + 1, N);
          PutStr(V, S1, Wide);
          PushI(V);
        end;
      opStrMid:
        begin
          Wide := RdU8 <> 0;
          Idx := PopI;
          N := PopI;
          A := PopI;
          V := PopI;
          S1 := ReadStringAt(A, Wide);
          PutStr(V, Copy(S1, Idx, N), Wide);
          PushI(V);
        end;
      opStrFind:
        begin
          Wide := RdU8 <> 0;
          B2 := PopI;
          A := PopI;
          PushI(Pos(ReadStringAt(B2, Wide), ReadStringAt(A, Wide)));
        end;
      opTrap:
        raise EVmError.CreateFmt('Trap %d in %s', [RdU16, FImg.Block(BI).Name]);
    else
      raise EVmError.CreateFmt('Invalid opcode %d at %d in %s', [Ord(O), P - 1, FImg.Block(BI).Name]);
    end;
  end;
  Dec(FDepth);
end;

procedure TVirtualPlc.SysFB(Id: Integer; CntVT: Byte; Inst: Int64);
var
  L: Boolean;
  TT: Byte;
  OIn, OR_, OPT, OQ, OET, OST, OT0: Int64;
  InV, RV, Q: Boolean;
  PT, ET, T0, Now, St: Int64;
  Cb: Integer;
  OPV, OCV: Int64;
  CU, CD, R, LD, CUO, CDO: Boolean;
  CV, PV, MaxV, MinV: Int64;

  function Rd(Ofs: Int64; VT: Byte): Int64;
  begin
    Result := ReadAddr((Inst and not ADDR_BIT_MASK) or (AddrBit(Inst) + Ofs), VT).I;
  end;

  procedure Wr(Ofs: Int64; VT: Byte; V: Int64);
  begin
    WriteAddr((Inst and not ADDR_BIT_MASK) or (AddrBit(Inst) + Ofs), VT, VmInt(V));
  end;

  function B(Ofs: Int64): Boolean;
  begin
    Result := Rd(Ofs, VT_BOOL) <> 0;
  end;

begin
  case Id of
    SFB_TP, SFB_TON, SFB_TOF, SFB_TONR, SFB_TP_L, SFB_TON_L, SFB_TOF_L, SFB_TONR_L:
      begin
        L := Id >= SFB_TP_L;
        if L then
        begin
          TT := VT_LTIME; OIn := 0; OR_ := 1; OPT := 16; OQ := 80; OET := 96; OST := 160; OT0 := 176;
          Now := FNowNs;
        end
        else
        begin
          TT := VT_TIME; OIn := 0; OR_ := 1; OPT := 16; OQ := 48; OET := 64; OST := 96; OT0 := 112;
          Now := FNowNs div 1000000;
        end;
        InV := B(OIn);
        RV := B(OR_);
        PT := Rd(OPT, TT);
        ET := Rd(OET, TT);
        St := Rd(OST, VT_BYTE);       // bit0 last IN, bit1 running
        T0 := Rd(OT0, VT_LINT);
        Q := False;
        case Id mod 10 of
          SFB_TON:
            begin
              if InV then
              begin
                if St and 1 = 0 then T0 := Now;
                ET := Min(Now - T0, PT);
                Q := ET >= PT;
              end
              else
              begin
                ET := 0;
                Q := False;
              end;
            end;
          SFB_TOF:
            begin
              if InV then
              begin
                Q := True;
                ET := 0;
                St := St and not 2;
              end
              else
              begin
                if St and 1 <> 0 then
                begin
                  T0 := Now;
                  St := St or 2;
                end;
                if St and 2 <> 0 then
                begin
                  ET := Min(Now - T0, PT);
                  Q := ET < PT;
                  if not Q then St := St and not 2;
                end
                else
                  Q := False;
              end;
            end;
          SFB_TP:
            begin
              if (St and 2 = 0) and InV and (St and 1 = 0) then
              begin
                T0 := Now;
                St := St or 2;
              end;
              if St and 2 <> 0 then
              begin
                ET := Now - T0;
                if ET >= PT then
                begin
                  ET := PT;
                  St := St and not 2;
                  Q := False;
                end
                else
                  Q := True;
              end
              else
              begin
                Q := False;
                if not InV then ET := 0;
              end;
            end;
          SFB_TONR:
            begin
              if RV then
              begin
                ET := 0;
                Q := False;
              end
              else
              begin
                if InV then
                begin
                  if St and 1 <> 0 then ET := Min(ET + (Now - T0), PT);
                  T0 := Now;
                end;
                Q := ET >= PT;
              end;
            end;
        end;
        if InV then St := St or 1 else St := St and not 1;
        Wr(OQ, VT_BOOL, Ord(Q));
        Wr(OET, TT, ET);
        Wr(OST, VT_BYTE, St);
        Wr(OT0, VT_LINT, T0);
      end;
    SFB_CTU, SFB_CTD, SFB_CTUD:
      begin
        Cb := VmTypeBytes(CntVT) * 8;
        OPV := 16;
        OCV := 16 + Cb;
        CU := B(0); CD := B(1); R := B(2); LD := B(3);
        CUO := B(7); CDO := B(8);
        PV := Rd(OPV, CntVT);
        CV := Rd(OCV, CntVT);
        case CntVT of
          VT_SINT: begin MinV := -128; MaxV := 127; end;
          VT_INT: begin MinV := -32768; MaxV := 32767; end;
          VT_DINT: begin MinV := -2147483648; MaxV := 2147483647; end;
          VT_UDINT: begin MinV := 0; MaxV := 4294967295; end;
          VT_UINT: begin MinV := 0; MaxV := 65535; end;
          VT_USINT: begin MinV := 0; MaxV := 255; end;
        else
          begin MinV := Low(Int64); MaxV := High(Int64); end;
        end;
        if Id = SFB_CTU then
        begin
          if R then CV := 0
          else if CU and not CUO and (CV < MaxV) then Inc(CV);
          Wr(4, VT_BOOL, Ord(CV >= PV));
        end
        else if Id = SFB_CTD then
        begin
          if LD then CV := PV
          else if CD and not CDO and (CV > MinV) then Dec(CV);
          Wr(4, VT_BOOL, Ord(CV <= 0));
        end
        else
        begin
          if R then CV := 0
          else if LD then CV := PV
          else
          begin
            if CU and not CUO and (CV < MaxV) then Inc(CV);
            if CD and not CDO and (CV > MinV) then Dec(CV);
          end;
          Wr(5, VT_BOOL, Ord(CV >= PV));
          Wr(6, VT_BOOL, Ord(CV <= 0));
        end;
        Wr(OCV, CntVT, CV);
        Wr(7, VT_BOOL, Ord(CU));
        Wr(8, VT_BOOL, Ord(CD));
      end;
    SFB_RTRIG, SFB_FTRIG:
      begin
        InV := B(0);
        if Id = SFB_RTRIG then Wr(1, VT_BOOL, Ord(InV and not B(2)))
        else Wr(1, VT_BOOL, Ord(not InV and B(2)));
        Wr(2, VT_BOOL, Ord(InV));
      end;
    SFB_RS:
      Wr(2, VT_BOOL, Ord((B(2) or B(0)) and not B(1)));
    SFB_SR:
      Wr(2, VT_BOOL, Ord(B(0) or (B(2) and not B(1))));
  else
    raise EVmError.CreateFmt('Unknown system FB %d', [Id]);
  end;
end;

function TVirtualPlc.FindVar(const Path: string; out A: Int64; out VT: Byte; out TypeText: string): Boolean;
var
  I, J, P: Integer;
  DBName, Rest: string;
  D: TSvDataBlock;
  T: TSvTag;
begin
  Result := False;
  A := 0;
  VT := 0;
  TypeText := '';
  if (Path <> '') and (Path[1] = '"') then
  begin
    P := Pos('"', Copy(Path, 2, MaxInt));
    DBName := Copy(Path, 2, P - 1);
    Rest := Copy(Path, P + 2, MaxInt);
    if (Rest <> '') and (Rest[1] = '.') then Delete(Rest, 1, 1);
    for I := 0 to FImg.DataBlocks.Count - 1 do
    begin
      D := FImg.DataBlock(I);
      if SameText(D.Name, DBName) then
      begin
        if Rest = '' then
          for J := 0 to High(FImg.Tags) do ;
        for J := 0 to High(D.Vars) do
          if SameText(D.Vars[J].Path, Rest) then
          begin
            A := MakeAddr(AREA_DB, D.Number, D.Vars[J].BitOff);
            VT := D.Vars[J].VmType;
            TypeText := D.Vars[J].TypeText;
            Exit(True);
          end;
      end;
    end;
    Exit;
  end;
  for I := 0 to High(FImg.Tags) do
  begin
    T := FImg.Tags[I];
    if SameText(T.Name, Path) then
    begin
      A := MakeAddr(T.Area, 0, T.BitOff);
      VT := T.VmType;
      TypeText := T.TypeText;
      Exit(True);
    end;
  end;
end;

end.
