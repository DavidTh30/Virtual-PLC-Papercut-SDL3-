unit uPlcRuntime;

{ The virtual CPU: memory, the scan cycle (own thread), the instruction
  interpreter, S5 and IEC timers / counters, forces, the diagnostic buffer and
  the cycle statistics.

  Scan cycle in RUN:
    commands from the UI (download, modify at the cycle check point, forces, mode)
    process image of the inputs: I := field inputs (SimIn) with the forces
    clock memory byte
    OB1; between its networks a due cyclic interrupt (OB35 / OB30) runs
    process image of the outputs: field outputs (SimOut) := Q with the forces
    statistics, watchdog, pacing (free run / 1 ms / the model's cycle time)
  STOP: outputs off (forced outputs stay), inputs still read, no program.
  STOP -> RUN: complete restart (non retentive memory cleared), OB100, then OB1.
  MRES: all memory reset to the start values.

  Status word, as on a real S7: RLO, /FC (first check), STA, OR, OS, OV, CC0,
  CC1, BR. AND binds before OR: "A a / O b / A c" is a OR (b AND c); the OR bit
  holds the result of the finished AND groups (Eff = OR or RLO).

  Accumulators: 2 on the S7-300 / S7-1200, 4 on the S7-400 (arithmetic pulls
  ACCU3 -> ACCU2, ACCU4 -> ACCU3; ENT, LEAVE, PUSH, POP).

  Data is big-endian: MW20 = MB20 (high) MB21 (low).

  Programming errors (area length, missing DB, BCD): S7-300/400 go to STOP
  (OB121 / OB122 are not loaded); the S7-1200 writes the diagnostic buffer,
  flashes ERROR and goes on with the next instruction. Cycle time over the
  watchdog (150 ms): STOP on every family (OB80 not loaded). }

{$mode objfpc}{$H+}
{$R-}{$Q-}

interface

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  Classes, SysUtils, Math, SyncObjs, fgl, uPlcTypes, uPlcProject, uPlcCompiler;

const
  HistCycles = 256;
  MaxDiag = 100;
  LFrame = 256;
  MaxDepth = 16;

type
  TRunMode = (rmStop, rmStartup, rmRun, rmMres);
  TPacing = (pcFree, pcMin1ms, pcModel);
  TDiagKind = (dkInfo, dkWarn, dkError, dkMode);

  TDiagEntry = record
    Time: TDateTime;
    Kind: TDiagKind;
    Text: string;
  end;

  TS5Timer = record
    Mode: Byte;          // 0 none, 1 SP, 2 SE, 3 SD, 4 SS, 5 SF
    Running, Q, Edge: Boolean;
    StartMs, DurMs: Double;
    TV: Word;            // S5TIME of the last start
  end;

  TS5Counter = record
    Value: Integer;
    EdgeU, EdgeD, EdgeS: Boolean;
  end;

  TIecState = record
    StartMs: Double;
    Running, PrevIn: Boolean;
  end;

  TDbMem = record
    Data: array of Byte;
    Present: Boolean;
    Optimized: Boolean;   // S7-1200 optimized access: no absolute access from outside
  end;

  { a read / write of a memory range for the communication servers; done by the
    PLC thread at the cycle check point, so the data is consistent within a cycle }
  TAreaResult = (arOk, arNoObject, arOutOfRange, arNotAllowed, arTypeNotSupported);

  TAreaReq = record
    Area: TArea;           // arI arQ arM arDB arT arC
    DB: Integer;
    Ofs, Len: Integer;     // bytes; with Bits: first bit (byte * 8 + bit) and bit count; T / C: number, count
    Bits: Boolean;         // bit access, Data packed LSB first (Modbus / S7 bit)
    Write: Boolean;
    Data: array of Byte;
    Res: TAreaResult;
    Done: PRTLEvent;
    Processed: Boolean;
  end;
  PAreaReq = ^TAreaReq;

  TCtx = record
    RLO, FC, STA, ORb, OS, OV, CC0, CC1, BR: Boolean;
    Accu: array[1..4] of LongWord;
    DBReg, DIReg: Integer;
    DIOfs: Integer;     // the instance offset of a multi-instance in the DI (AR2 in S7)
  end;

  EPlcError = class(Exception);     // programming error (OB121 / OB122)
  EPlcFatal = class(Exception);     // cycle time, block stack: always STOP
  TDiagArray = array of TDiagEntry;

  TPlcCmdKind = (ckRun, ckStop, ckMres, ckDownload, ckModify, ckForce, ckUnforce, ckUnforceAll,
    ckSetModel, ckBusFault, ckClearDiag, ckPacing, ckAreaIO);

  TPlcCmd = record
    Kind: TPlcCmdKind;
    Opd: TOperand;
    Value: LongWord;
    Int: Integer;
    Int2: Integer;      // serial number of the command
    Prog: TCProgram;
    Req: PAreaReq;      // ckAreaIO
  end;

  TPlcRuntime = class;

  TPlcThread = class(TThread)
  private
    FRt: TPlcRuntime;
  protected
    procedure Execute; override;
  public
    constructor Create(ART: TPlcRuntime);
  end;

  TKeyMap = specialize TFPGMap<Int64, Integer>;

  { TPlcRuntime }

  TPlcRuntime = class
  private
    FThread: TPlcThread;
    FLock: TCriticalSection;       // commands, diagnostic buffer, retired programs
    FCmds: array of TPlcCmd;
    FDiag: array of TDiagEntry;
    FRetired: TList;
    FCtx: TCtx;
    FPin, FPout: array[0..MaxLadRows - 1] of Boolean;
    FNest: array[0..7] of record
      RLO, ORb, FC: Boolean;
      Code: TOpCode;
    end;
    FNestN: Integer;
    { SCL value stack, CASE registers, the last value for the monitor }
    FSt: array[0..255] of Double;
    FSp: Integer;
    FReg: array[0..15] of Double;   // SCL: 0..7 CASE selectors, 8 the offset of a timer instance
    FSclLast: Double;
    FDepth: Integer;
    FCurBlock: array[0..MaxDepth] of Integer;
    FCurPc: array[0..MaxDepth] of Integer;
    FCycleStartMs: Double;
    FNextCycMs: Double;
    FInCyclic: Boolean;
    FOpsCount: Integer;
    FCatCount: array[TTimeCat] of Int64;
    FIecKeys: TKeyMap;
    FIec: array of TIecState;
    FErrThisCycle: Integer;
    FStopRequest: string;
    FMresUntil: Double;
    FLastCycleEnd: Double;
    FErrWhere: string;
    FPostSerial, FDoneSerial: Integer;
    FLastStartMs: Double;
    FTimer: THandle;     // high resolution waitable timer (Windows 10 1803+), 0 = Sleep
    FLastErr: string;
    FLastErrMs: Double;
    FCpsT0: Double;
    FCpsN: Integer;
    procedure PreciseWait(Ms: Double);
    procedure ThreadLoop;
    function SclRead(const O: TOperand; DT: TDataType): Double;
    procedure SclWrite(const O: TOperand; DT: TDataType; V: Double);
    function SclIdx(const Op: TOp; BitOfs: Int64): TOperand; overload;
    function SclIdx(const Op: TOp; BitOfs: Int64; const Base: TOperand): TOperand; overload;
    procedure SPush(V: Double); inline;
    function SPop: Double; inline;
    procedure ProcessCommands;
    procedure DoCommand(const C: TPlcCmd);
    procedure AllocMemory;
    procedure LoadDBs(Full: Boolean);
    procedure CompleteRestart;
    procedure GoStop(const Why: string);
    procedure GoRun;
    procedure RunCycle;
    procedure ReadInputs;
    procedure WriteOutputs;
    procedure UpdateClock(NowMs: Double);
    procedure ExecBlock(BI: Integer);
    procedure CheckCyclic;
    procedure RunOB(BI: Integer);
    procedure ProgError(const Msg: string);
    function WhereStr: string;
    function TimerIdx(const A: TAddr): Integer;
    function CounterIdx(const A: TAddr): Integer;
    procedure TickTimer(var T: TS5Timer; NowMs: Double);
    function TimerValue(var T: TS5Timer; NowMs: Double; BCD: Boolean): LongWord;
    procedure TimerOp(Code: TOpCode; const A: TAddr; S: Boolean);
    function IecState(const A: TAddr): Integer;
    function InstMember(const Inst: TAddr; AOfs, ABit: Integer; ASize: TOpSize): TAddr;
    function IecTimer(Code: TOpCode; const Inst: TAddr; E: Boolean; PT: Int64; R: Boolean; out ET: Int64): Boolean;
    function IecCounter(Code: TOpCode; const Inst: TAddr; CU, CD, R, LD: Boolean; PV: Int64; out CV: Int64): Boolean;
    { memory }
    function AreaPtr(const A: TAddr; Bytes: Integer; ForWrite: Boolean): PByte;
    function ReadBitA(const A: TAddr): Boolean;
    procedure WriteBitA(const A: TAddr; V: Boolean);
    function ReadRaw(const A: TAddr): LongWord;
    procedure WriteRaw(const A: TAddr; V: LongWord);
    function ReadOpdBit(const O: TOperand): Boolean;
    function ReadOpdRaw(const O: TOperand): LongWord;
    function ReadInt(const O: TOperand; T: TDataType): Int64;
    function ReadReal(const O: TOperand; T: TDataType): Double;
    procedure WriteInt(const O: TOperand; T: TDataType; V: Int64);
    procedure WriteReal(const O: TOperand; V: Double);
    function StatusBit(I: Integer): Boolean;
    procedure SetCCFromInt(V: Int64);
    procedure SetCCFromReal(V: Single);
    procedure MonRecord(const B: TCBlock; Slot: Integer; Bit0: Boolean);
    procedure DiagAdd(AKind: TDiagKind; const AText: string);
    procedure ApplyForceIn;
  public
    { the model and the memory (sized for the model) }
    ModelIdx: Integer;
    Model: TCpuModel;
    I, Q, M: array of Byte;
    SimIn, SimOut: array of Byte;     // field side: written by the I/O panel / read by the lamps
    L: array of Byte;
    Timers: array of TS5Timer;
    Counters: array of TS5Counter;
    DBs: array of TDbMem;             // index = DB number
    ForceMaskI, ForceValI, ForceMaskQ, ForceValQ, ForceMaskM, ForceValM: array of Byte;
    ForceCount: Integer;
    Prog: TCProgram;                  // the downloaded program (UI reads it)
    ProgSerial: Integer;
    { state }
    Mode: TRunMode;
    StopCause: string;
    BusFault: Boolean;
    ErrorUntilMs: Double;             // S7-1200 ERROR LED flashing
    SysFault: Boolean;                // SF / INTF: the last STOP was caused by an error
    Pacing: TPacing;
    MonBlock: Integer;                // compiled block whose monitor slots are written
    { statistics }
    CycleNo: LongWord;
    HostUs, HostMinUs, HostMaxUs, HostAvgUs: Double;
    ModelUs, ModelMinUs, ModelMaxUs, ModelAvgUs: Double;
    PeriodMs: Double;
    CyclesPerSec: Double;
    CycCount, CycLate: Int64;
    HostHist, ModelHist: array[0..HistCycles - 1] of Single;
    HistPos: Integer;
    OpsLastCycle: Integer;
    StartTimeMs: Double;
    constructor Create(AModelIdx: Integer);
    destructor Destroy; override;
    { UI side }
    procedure Post(const C: TPlcCmd);
    { waits until the thread has handled everything posted so far }
    function WaitCommands(TimeoutMs: Integer = 1000): Boolean;
    procedure CmdRun;
    procedure CmdStop;
    procedure CmdMres;
    procedure CmdDownload(AProg: TCProgram);
    procedure CmdModify(const O: TOperand; V: LongWord);
    procedure CmdForce(const O: TOperand; V: LongWord);
    procedure CmdUnforce(const O: TOperand);
    procedure CmdUnforceAll;
    procedure CmdSetModel(AIdx: Integer);
    procedure CmdBusFault(AOn: Boolean);
    procedure CmdClearDiag;
    procedure CmdPacing(P: TPacing);
    procedure FreeRetired;
    function DiagCopy(MaxN: Integer): TDiagArray;
    function DiagCount: Integer;
    { reading for the UI (any thread, values may be one cycle old) }
    function PeekRaw(const O: TOperand; out V: LongWord): Boolean;
    function PeekBit(const O: TOperand; out V: Boolean): Boolean;
    function IsForced(const O: TOperand): Boolean;
    function TimerRemainMs(N: Integer): Double;
    function TimerRunning(N: Integer): Boolean;
    function TimerQ(N: Integer): Boolean;
    function CounterValue(N: Integer): Integer;
    procedure SetSimBit(ByteOfs, Bit: Integer; V: Boolean);
    function GetSimBit(ByteOfs, Bit: Integer): Boolean;
    function GetOutBit(ByteOfs, Bit: Integer): Boolean;
    procedure SetSimWord(ByteOfs: Integer; V: SmallInt);
    function GetOutWord(ByteOfs: Integer): SmallInt;
    function NowMs: Double;
    { communication: blocks until the PLC thread has done the request (False = timeout) }
    function AreaIO(var R: TAreaReq; TimeoutMs: Integer = 1000): Boolean;
    procedure DoAreaIO(var R: TAreaReq);
  end;

function PlcNowMs: Double;
function FormatRaw(V: LongWord; Size: TOpSize; F: TDispFmt): string;
function ParseValueText(const S: string; Size: TOpSize; F: TDispFmt; out V: LongWord): Boolean;
function DefaultFmt(const O: TOperand): TDispFmt;

implementation

{$IFDEF WINDOWS}
function QueryPerformanceCounter(var C: Int64): LongBool; stdcall; external 'kernel32.dll';
function QueryPerformanceFrequency(var F: Int64): LongBool; stdcall; external 'kernel32.dll';
function timeBeginPeriod(P: LongWord): LongWord; stdcall; external 'winmm.dll';
function timeEndPeriod(P: LongWord): LongWord; stdcall; external 'winmm.dll';
function CreateWaitableTimerExW(Attr: Pointer; Name: PWideChar; Flags, Access: LongWord): THandle; stdcall;
  external 'kernel32.dll';
function SetWaitableTimer(H: THandle; var Due: Int64; Period: LongInt; Routine, Arg: Pointer;
  Resume: LongBool): LongBool; stdcall; external 'kernel32.dll';
function WaitForSingleObject(H: THandle; Ms: LongWord): LongWord; stdcall; external 'kernel32.dll';
function CloseHandle(H: THandle): LongBool; stdcall; external 'kernel32.dll';

const
  CREATE_WAITABLE_TIMER_HIGH_RESOLUTION = $00000002;
  TIMER_ALL_ACCESS = $1F0003;

var
  QpcFreq: Int64 = 0;

function PlcNowMs: Double;
var
  C: Int64;
begin
  if QpcFreq = 0 then QueryPerformanceFrequency(QpcFreq);
  QueryPerformanceCounter(C);
  Result := Double(C) / Double(QpcFreq) * 1000;
end;
{$ELSE}
function PlcNowMs: Double;
begin
  Result := Double(GetTickCount64);
end;
{$ENDIF}

function SgBits(V: Single): LongWord; inline;
begin
  Result := PLongWord(@V)^;
end;

function BitsSg(V: LongWord): Single; inline;
begin
  Result := PSingle(@V)^;
end;

{ ---------- value text ---------- }

function DefaultFmt(const O: TOperand): TDispFmt;
begin
  Result := dfDec;
  if O.Kind <> okAddr then Exit;
  if O.A.Area = arT then Exit(dfS5Time);
  if O.A.Area = arC then Exit(dfCounter);
  case O.DType of
    dtBool: Exit(dfBool);
    dtReal: Exit(dfReal);
    dtTime: Exit(dfTime);
    dtS5Time: Exit(dfS5Time);
    dtChar: Exit(dfChar);
    dtByte, dtWord, dtDWord: Exit(dfHex);
  end;
  if O.A.Size = osBit then Result := dfBool;
end;

function FormatRaw(V: LongWord; Size: TOpSize; F: TDispFmt): string;
var
  Bits, K: Integer;
  Ok: Boolean;
begin
  case Size of
    osBit: Bits := 1;
    osByte: Bits := 8;
    osWord: Bits := 16;
  else
    Bits := 32;
  end;
  if Size = osBit then
  begin
    if F = dfDec then Exit(IntToStr(V and 1));
    if V <> 0 then Exit('TRUE') else Exit('FALSE');
  end;
  case F of
    dfBool:
      if V <> 0 then Result := 'TRUE' else Result := 'FALSE';
    dfDec:
      case Size of
        osByte: Result := IntToStr(V and $FF);
        osWord: Result := IntToStr(SmallInt(V and $FFFF));
      else
        Result := IntToStr(LongInt(V));
      end;
    dfHex:
      case Size of
        osByte: Result := 'B#16#' + IntToHex(V and $FF, 2);
        osWord: Result := 'W#16#' + IntToHex(V and $FFFF, 4);
      else
        Result := 'DW#16#' + IntToHex(V, 8);
      end;
    dfBin:
      begin
        Result := '2#';
        for K := Bits - 1 downto 0 do
        begin
          if (V shr K) and 1 <> 0 then Result := Result + '1' else Result := Result + '0';
          if (K mod 4 = 0) and (K > 0) then Result := Result + '_';
        end;
      end;
    dfReal:
      if Size = osDWord then Result := FloatToStrDot(BitsSg(V)) else Result := '(4 bytes)';
    dfTime:
      if Size = osDWord then Result := FormatTime(LongInt(V)) else Result := '(4 bytes)';
    dfS5Time:
      if Size = osWord then Result := FormatS5Time(V and $FFFF) else Result := '(2 bytes)';
    dfCounter:
      begin
        K := BcdToInt(V and $FFF, 3, Ok);
        if Ok then Result := 'C#' + IntToStr(K) else Result := 'C#?';
      end;
    dfChar:
      if (V and $FF >= 32) and (V and $FF < 127) then Result := '''' + Chr(V and $FF) + ''''
      else Result := '#' + IntToStr(V and $FF);
  end;
end;

function ParseValueText(const S: string; Size: TOpSize; F: TDispFmt; out V: LongWord): Boolean;
var
  C: TConst;
  U: string;
  R: Double;
  Sg: Single;
  I64: Int64;
  Ms: Int64;
begin
  Result := False;
  V := 0;
  U := UpperCase(Trim(S));
  if U = '' then Exit;
  if Size = osBit then
  begin
    if (U = '1') or (U = 'TRUE') then begin V := 1; Exit(True); end;
    if (U = '0') or (U = 'FALSE') then begin V := 0; Exit(True); end;
    Exit;
  end;
  if (F = dfReal) and StrToFloatDot(U, R) then
  begin
    Sg := R;
    V := SgBits(Sg);
    Exit(True);
  end;
  if (F = dfTime) and (Pos('#', U) = 0) and ParseTimeLiteral(U, Ms) then
  begin
    V := LongWord(LongInt(Ms));
    Exit(True);
  end;
  if (F = dfS5Time) and (Pos('#', U) = 0) and ParseTimeLiteral(U, Ms) then
  begin
    V := MsToS5Time(Ms);
    Exit(True);
  end;
  if (F = dfCounter) and TryStrToInt64(U, I64) and (I64 >= 0) and (I64 <= 999) then
  begin
    V := IntToBcd(I64, 3, Result);
    Exit(True);
  end;
  if not ParseConst(S, C) then Exit;
  if C.Kind = ckReal then
  begin
    Sg := C.R;
    V := SgBits(Sg);
  end
  else if C.Kind in [ckInt, ckDInt] then
    V := LongWord(LongInt(C.I))
  else
    V := C.Bits;
  case Size of
    osByte: V := V and $FF;
    osWord: V := V and $FFFF;
  end;
  Result := True;
end;

{ ---------- thread ---------- }

constructor TPlcThread.Create(ART: TPlcRuntime);
begin
  FRt := ART;
  FreeOnTerminate := False;
  inherited Create(False);
end;

procedure TPlcThread.Execute;
begin
  FRt.ThreadLoop;
end;

{ ---------- TPlcRuntime ---------- }

constructor TPlcRuntime.Create(AModelIdx: Integer);
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FRetired := TList.Create;
  FIecKeys := TKeyMap.Create;
  FIecKeys.Sorted := True;
  ModelIdx := EnsureRange(AModelIdx, 0, ModelCount - 1);
  Model := Models[ModelIdx];
  AllocMemory;
  Mode := rmStop;
  Pacing := pcMin1ms;
  MonBlock := -1;
  StartTimeMs := PlcNowMs;
  HostMinUs := 1E9;
  ModelMinUs := 1E9;
  DiagAdd(dkMode, 'Power on: ' + Model.Name + ', ' + Model.Firmware + ' - STOP (no user program)');
  {$IFDEF WINDOWS}timeBeginPeriod(1);{$ENDIF}
  FThread := TPlcThread.Create(Self);
end;

destructor TPlcRuntime.Destroy;
var
  K: Integer;
begin
  FThread.Terminate;
  FThread.WaitFor;
  FThread.Free;
  {$IFDEF WINDOWS}timeEndPeriod(1);{$ENDIF}
  FreeRetired;
  FreeAndNil(Prog);
  for K := 0 to High(FCmds) do
    if FCmds[K].Prog <> nil then FCmds[K].Prog.Free;
  FRetired.Free;
  FIecKeys.Free;
  FLock.Free;
  inherited Destroy;
end;

function TPlcRuntime.NowMs: Double;
begin
  Result := PlcNowMs;
end;

procedure TPlcRuntime.AllocMemory;
begin
  Model := Models[ModelIdx];
  SetLength(I, 0);
  SetLength(I, Model.InBytes);
  SetLength(Q, 0);
  SetLength(Q, Model.OutBytes);
  SetLength(M, 0);
  SetLength(M, Model.MBytes);
  SetLength(SimIn, 0);
  SetLength(SimIn, Model.InBytes);
  SetLength(SimOut, 0);
  SetLength(SimOut, Model.OutBytes);
  SetLength(L, 0);
  SetLength(L, LFrame * (MaxDepth + 2));
  SetLength(Timers, 0);
  SetLength(Timers, Model.Timers);
  SetLength(Counters, 0);
  SetLength(Counters, Model.Counters);
  SetLength(ForceMaskI, 0);
  SetLength(ForceMaskI, Model.InBytes);
  SetLength(ForceValI, 0);
  SetLength(ForceValI, Model.InBytes);
  SetLength(ForceMaskQ, 0);
  SetLength(ForceMaskQ, Model.OutBytes);
  SetLength(ForceValQ, 0);
  SetLength(ForceValQ, Model.OutBytes);
  SetLength(ForceMaskM, 0);
  SetLength(ForceMaskM, Model.MBytes);
  SetLength(ForceValM, 0);
  SetLength(ForceValM, Model.MBytes);
  ForceCount := 0;
  SetLength(DBs, 0);
  FIecKeys.Clear;
  SetLength(FIec, 0);
end;

{ the DBs of the program: Full = start values for everything (download of a
  changed DB, MRES); otherwise only DBs whose size changed are re-initialised }
procedure TPlcRuntime.LoadDBs(Full: Boolean);
var
  K, N, MaxN: Integer;
  Keep: array of Boolean;
begin
  if Prog = nil then
  begin
    SetLength(DBs, 0);
    Exit;
  end;
  MaxN := 0;
  for K := 0 to High(Prog.DBs) do MaxN := Max(MaxN, Prog.DBs[K].Number);
  if Length(DBs) < MaxN + 1 then SetLength(DBs, MaxN + 1);
  SetLength(Keep, Length(DBs));
  for K := 0 to High(Keep) do Keep[K] := False;
  for K := 0 to High(Prog.DBs) do
  begin
    N := Prog.DBs[K].Number;
    if (N < 1) or (N > High(DBs)) then Continue;
    Keep[N] := True;
    if Full or not DBs[N].Present or (Length(DBs[N].Data) <> Prog.DBs[K].Size) then
    begin
      DBs[N].Data := Copy(Prog.DBs[K].Init);
      SetLength(DBs[N].Data, Prog.DBs[K].Size);
    end;
    DBs[N].Present := True;
    DBs[N].Optimized := Prog.DBs[K].Optimized;
  end;
  // DBs that are no longer in the program are deleted
  for K := 0 to High(DBs) do
    if not Keep[K] then
    begin
      DBs[K].Present := False;
      SetLength(DBs[K].Data, 0);
    end;
  FIecKeys.Clear;
  SetLength(FIec, 0);
end;

procedure TPlcRuntime.DiagAdd(AKind: TDiagKind; const AText: string);
var
  N: Integer;
begin
  FLock.Enter;
  try
    N := Length(FDiag);
    if N >= MaxDiag then
    begin
      Move(FDiag[1], FDiag[0], SizeOf(TDiagEntry) * (N - 1));
      FillChar(FDiag[N - 1], SizeOf(TDiagEntry), 0);
      Dec(N);
    end
    else
      SetLength(FDiag, N + 1);
    FDiag[N].Time := Now;
    FDiag[N].Kind := AKind;
    FDiag[N].Text := AText;
  finally
    FLock.Leave;
  end;
end;

function TPlcRuntime.DiagCopy(MaxN: Integer): TDiagArray;
var
  K, N: Integer;
begin
  FLock.Enter;
  try
    N := Min(MaxN, Length(FDiag));
    SetLength(Result, N);
    // newest first
    for K := 0 to N - 1 do Result[K] := FDiag[High(FDiag) - K];
  finally
    FLock.Leave;
  end;
end;

function TPlcRuntime.DiagCount: Integer;
begin
  Result := Length(FDiag);
end;

{ ---------- commands ---------- }

procedure TPlcRuntime.Post(const C: TPlcCmd);
var
  N: Integer;
begin
  FLock.Enter;
  try
    N := Length(FCmds);
    SetLength(FCmds, N + 1);
    FCmds[N] := C;
    Inc(FPostSerial);
    FCmds[N].Int2 := FPostSerial;
  finally
    FLock.Leave;
  end;
end;

function TPlcRuntime.WaitCommands(TimeoutMs: Integer): Boolean;
var
  Target: Integer;
  T0: Double;
begin
  Target := FPostSerial;
  T0 := PlcNowMs;
  while (FDoneSerial < Target) and (PlcNowMs - T0 < TimeoutMs) do Sleep(1);
  Result := FDoneSerial >= Target;
end;

function NewCmd(K: TPlcCmdKind): TPlcCmd;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.Kind := K;
end;

procedure TPlcRuntime.CmdRun;
begin
  Post(NewCmd(ckRun));
end;

procedure TPlcRuntime.CmdStop;
begin
  Post(NewCmd(ckStop));
end;

procedure TPlcRuntime.CmdMres;
begin
  Post(NewCmd(ckMres));
end;

procedure TPlcRuntime.CmdDownload(AProg: TCProgram);
var
  C: TPlcCmd;
begin
  C := NewCmd(ckDownload);
  C.Prog := AProg;
  Post(C);
end;

procedure TPlcRuntime.CmdModify(const O: TOperand; V: LongWord);
var
  C: TPlcCmd;
begin
  C := NewCmd(ckModify);
  C.Opd := O;
  C.Value := V;
  Post(C);
end;

procedure TPlcRuntime.CmdForce(const O: TOperand; V: LongWord);
var
  C: TPlcCmd;
begin
  C := NewCmd(ckForce);
  C.Opd := O;
  C.Value := V;
  Post(C);
end;

procedure TPlcRuntime.CmdUnforce(const O: TOperand);
var
  C: TPlcCmd;
begin
  C := NewCmd(ckUnforce);
  C.Opd := O;
  Post(C);
end;

procedure TPlcRuntime.CmdUnforceAll;
begin
  Post(NewCmd(ckUnforceAll));
end;

procedure TPlcRuntime.CmdSetModel(AIdx: Integer);
var
  C: TPlcCmd;
begin
  C := NewCmd(ckSetModel);
  C.Int := AIdx;
  Post(C);
end;

procedure TPlcRuntime.CmdBusFault(AOn: Boolean);
var
  C: TPlcCmd;
begin
  C := NewCmd(ckBusFault);
  C.Int := Ord(AOn);
  Post(C);
end;

procedure TPlcRuntime.CmdClearDiag;
begin
  Post(NewCmd(ckClearDiag));
end;

procedure TPlcRuntime.CmdPacing(P: TPacing);
var
  C: TPlcCmd;
begin
  C := NewCmd(ckPacing);
  C.Int := Ord(P);
  Post(C);
end;

procedure TPlcRuntime.FreeRetired;
var
  K: Integer;
begin
  FLock.Enter;
  try
    for K := 0 to FRetired.Count - 1 do TCProgram(FRetired[K]).Free;
    FRetired.Clear;
  finally
    FLock.Leave;
  end;
end;

procedure TPlcRuntime.ProcessCommands;
var
  List: array of TPlcCmd;
  K: Integer;
begin
  if Length(FCmds) = 0 then Exit;
  FLock.Enter;
  try
    List := FCmds;
    FCmds := nil;
  finally
    FLock.Leave;
  end;
  for K := 0 to High(List) do DoCommand(List[K]);
  if Length(List) > 0 then FDoneSerial := List[High(List)].Int2;
end;

{ which bits / bytes an operand covers in a force table }
procedure ForceBits(const O: TOperand; var Mask, Val: array of Byte; V: LongWord; Setting: Boolean);
var
  N, K, B: Integer;
  ByteV: Byte;
begin
  if O.A.Size = osBit then
  begin
    if O.A.Ofs > High(Mask) then Exit;
    if Setting then
    begin
      Mask[O.A.Ofs] := Mask[O.A.Ofs] or (1 shl O.A.Bit);
      if V <> 0 then Val[O.A.Ofs] := Val[O.A.Ofs] or (1 shl O.A.Bit)
      else Val[O.A.Ofs] := Val[O.A.Ofs] and not (1 shl O.A.Bit);
    end
    else
      Mask[O.A.Ofs] := Mask[O.A.Ofs] and not (1 shl O.A.Bit);
    Exit;
  end;
  case O.A.Size of
    osByte: N := 1;
    osWord: N := 2;
  else
    N := 4;
  end;
  for K := 0 to N - 1 do
  begin
    B := O.A.Ofs + K;
    if B > High(Mask) then Exit;
    ByteV := (V shr ((N - 1 - K) * 8)) and $FF;
    if Setting then
    begin
      Mask[B] := $FF;
      Val[B] := ByteV;
    end
    else
      Mask[B] := 0;
  end;
end;

function CountBits(const A: array of Byte): Integer;
var
  K, B: Integer;
  V: Byte;
begin
  Result := 0;
  for K := 0 to High(A) do
    if A[K] <> 0 then
    begin
      V := A[K];
      for B := 0 to 7 do
        if (V shr B) and 1 <> 0 then Inc(Result);
    end;
end;

procedure TPlcRuntime.DoCommand(const C: TPlcCmd);
var
  Old: TCProgram;
  Was: TRunMode;
  Ar: TArea;
begin
  case C.Kind of
    ckRun:
      if Mode = rmStop then GoRun;
    ckStop:
      if Mode <> rmStop then GoStop('STOP by the operator');
    ckMres:
      begin
        if Mode <> rmStop then GoStop('STOP by the operator (memory reset)');
        Mode := rmMres;
        FMresUntil := PlcNowMs + 1500;
        DiagAdd(dkMode, 'Memory reset (MRES) requested');
      end;
    ckDownload:
      begin
        Old := Prog;
        Was := Mode;
        Prog := C.Prog;
        Inc(ProgSerial);
        MonBlock := -1;
        LoadDBs(False);
        if Old <> nil then
        begin
          FLock.Enter;
          FRetired.Add(Old);
          FLock.Leave;
        end;
        DiagAdd(dkInfo, Format('Download: %d blocks, %d DBs, %d bytes code, %d bytes data',
          [Length(Prog.Blocks), Length(Prog.DBs), Prog.CodeBytes, Prog.DataBytes]));
        if (Was = rmRun) and (Prog.OB1 < 0) then GoStop('OB1 deleted');
      end;
    ckModify:
      try
        if C.Opd.Kind = okAddr then
        begin
          if C.Opd.A.Size = osBit then WriteBitA(C.Opd.A, C.Value <> 0) else WriteRaw(C.Opd.A, C.Value);
          if C.Opd.A.Area = arI then
          begin
            // the next input transfer would overwrite I: change the field value as well
            if C.Opd.A.Size = osBit then SetSimBit(C.Opd.A.Ofs, C.Opd.A.Bit, C.Value <> 0);
          end;
        end;
      except
        on E: Exception do DiagAdd(dkWarn, 'Modify ' + C.Opd.Text + ': ' + E.Message);
      end;
    ckForce, ckUnforce:
      if C.Opd.Kind = okAddr then
      begin
        Ar := C.Opd.A.Area;
        if (Ar in [arI, arPI]) then ForceBits(C.Opd, ForceMaskI, ForceValI, C.Value, C.Kind = ckForce)
        else if (Ar in [arQ, arPQ]) then ForceBits(C.Opd, ForceMaskQ, ForceValQ, C.Value, C.Kind = ckForce)
        else if Ar = arM then ForceBits(C.Opd, ForceMaskM, ForceValM, C.Value, C.Kind = ckForce);
        ForceCount := CountBits(ForceMaskI) + CountBits(ForceMaskQ) + CountBits(ForceMaskM);
        if C.Kind = ckForce then
          DiagAdd(dkWarn, 'Force: ' + C.Opd.Text + ' = ' + FormatRaw(C.Value, C.Opd.A.Size, dfHex))
        else
          DiagAdd(dkInfo, 'Force removed: ' + C.Opd.Text);
      end;
    ckUnforceAll:
      begin
        FillChar(ForceMaskI[0], Length(ForceMaskI), 0);
        FillChar(ForceMaskQ[0], Length(ForceMaskQ), 0);
        if Length(ForceMaskM) > 0 then FillChar(ForceMaskM[0], Length(ForceMaskM), 0);
        if ForceCount > 0 then DiagAdd(dkInfo, 'All forces removed');
        ForceCount := 0;
      end;
    ckSetModel:
      begin
        if Mode <> rmStop then GoStop('CPU changed');
        ModelIdx := EnsureRange(C.Int, 0, ModelCount - 1);
        Old := Prog;
        Prog := nil;
        Inc(ProgSerial);
        if Old <> nil then
        begin
          FLock.Enter;
          FRetired.Add(Old);
          FLock.Leave;
        end;
        AllocMemory;
        SysFault := False;
        StopCause := '';
        FLock.Enter;
        SetLength(FDiag, 0);
        FLock.Leave;
        DiagAdd(dkMode, 'New CPU: ' + Model.Name + ' ' + Model.OrderNo + ' ' + Model.Firmware);
      end;
    ckBusFault:
      begin
        BusFault := C.Int <> 0;
        if BusFault then
        begin
          DiagAdd(dkError, 'PROFINET IO: station failure (device 1 "ET200SP")');
          if StopOnStationFailure(Model.Family) and (Mode = rmRun) then
          begin
            SysFault := True;
            GoStop('station failure, OB86 not loaded');
          end;
        end
        else
          DiagAdd(dkInfo, 'PROFINET IO: station return (device 1 "ET200SP")');
      end;
    ckClearDiag:
      begin
        FLock.Enter;
        SetLength(FDiag, 0);
        FLock.Leave;
      end;
    ckPacing:
      Pacing := TPacing(EnsureRange(C.Int, 0, Ord(High(TPacing))));
    ckAreaIO:
      if C.Req <> nil then
      begin
        DoAreaIO(C.Req^);
        C.Req^.Processed := True;
        RTLEventSetEvent(C.Req^.Done);
      end;
  end;
end;

{ ---------- modes ---------- }

procedure TPlcRuntime.GoStop(const Why: string);
begin
  Mode := rmStop;
  StopCause := Why;
  DiagAdd(dkMode, 'RUN -> STOP: ' + Why);
end;

procedure TPlcRuntime.CompleteRestart;
var
  K, J, N: Integer;
  RetM, RetC: Integer;
begin
  // retentive by default: S7-300/400 MB0..MB15 and C0..C7, S7-1200 nothing (DB retain flags)
  if IsTia(Model.Family) then
  begin
    RetM := 0;
    RetC := 0;
  end
  else
  begin
    RetM := 16;
    RetC := 8;
  end;
  for K := RetM to High(M) do M[K] := 0;
  FillChar(Q[0], Length(Q), 0);
  for K := 0 to High(Timers) do FillChar(Timers[K], SizeOf(TS5Timer), 0);
  for K := RetC to High(Counters) do FillChar(Counters[K], SizeOf(TS5Counter), 0);
  if IsTia(Model.Family) and (Prog <> nil) then
    for K := 0 to High(Prog.DBs) do
    begin
      N := Prog.DBs[K].Number;
      if (N > High(DBs)) or not DBs[N].Present then Continue;
      for J := 0 to Min(High(Prog.DBs[K].Init), High(DBs[N].Data)) do
        if Prog.DBs[K].RetainMask[J] = 0 then DBs[N].Data[J] := Prog.DBs[K].Init[J];
    end;
  FIecKeys.Clear;
  SetLength(FIec, 0);
end;

procedure TPlcRuntime.GoRun;
begin
  if Prog = nil then
  begin
    DiagAdd(dkError, 'STOP -> RUN refused: no user program loaded');
    StopCause := 'no user program';
    Exit;
  end;
  if Prog.OB1 < 0 then
  begin
    DiagAdd(dkError, 'STOP -> RUN refused: OB1 missing');
    StopCause := 'OB1 missing';
    Exit;
  end;
  if StopOnStationFailure(Model.Family) and BusFault then
  begin
    DiagAdd(dkError, 'STOP -> RUN refused: station failure, OB86 not loaded');
    SysFault := True;
    StopCause := 'station failure, OB86 not loaded';
    Exit;
  end;
  SysFault := False;
  StopCause := '';
  Mode := rmStartup;
  if IsTia(Model.Family) then DiagAdd(dkMode, 'STOP -> STARTUP (warm restart)')
  else DiagAdd(dkMode, 'STOP -> STARTUP (complete restart, OB100)');
  CompleteRestart;
  FErrThisCycle := 0;
  ReadInputs;
  FCycleStartMs := PlcNowMs;
  if Prog.OB100 >= 0 then
  begin
    try
      RunOB(Prog.OB100);
    except
      on E: Exception do
      begin
        SysFault := True;
        GoStop('error in OB100: ' + E.Message);
        Exit;
      end;
    end;
    if Mode = rmStop then Exit;
  end;
  Mode := rmRun;
  FNextCycMs := PlcNowMs + Max(1, Prog.CyclicMs);
  HostMinUs := 1E9;
  HostMaxUs := 0;
  ModelMinUs := 1E9;
  ModelMaxUs := 0;
  DiagAdd(dkMode, 'STARTUP -> RUN');
end;

{ ---------- process images ---------- }

procedure TPlcRuntime.ApplyForceIn;
var
  K: Integer;
begin
  if ForceCount = 0 then Exit;
  for K := 0 to High(I) do
    if ForceMaskI[K] <> 0 then
      I[K] := (I[K] and not ForceMaskI[K]) or (ForceValI[K] and ForceMaskI[K]);
  for K := 0 to High(M) do
    if ForceMaskM[K] <> 0 then
      M[K] := (M[K] and not ForceMaskM[K]) or (ForceValM[K] and ForceMaskM[K]);
end;

procedure TPlcRuntime.ReadInputs;
begin
  if Length(I) > 0 then Move(SimIn[0], I[0], Length(I));
  ApplyForceIn;
end;

procedure TPlcRuntime.WriteOutputs;
var
  K: Integer;
  V: Byte;
begin
  if ForceCount = 0 then
  begin
    // nothing forced: one block copy (the S7-1500 has 32 KB of outputs)
    if Length(Q) = 0 then Exit;
    if Mode = rmRun then Move(Q[0], SimOut[0], Length(Q)) else FillChar(SimOut[0], Length(SimOut), 0);
    Exit;
  end;
  for K := 0 to High(Q) do
  begin
    if Mode = rmRun then V := Q[K] else V := 0;   // STOP: outputs disabled
    if ForceMaskQ[K] <> 0 then V := (V and not ForceMaskQ[K]) or (ForceValQ[K] and ForceMaskQ[K]);
    SimOut[K] := V;
  end;
end;

procedure TPlcRuntime.UpdateClock(NowMs: Double);
const
  Periods: array[0..7] of Double = (100, 200, 400, 500, 800, 1000, 1600, 2000);
var
  K: Integer;
  V: Byte;
  T: Double;
begin
  if (Prog = nil) or (Prog.ClockByte < 0) or (Prog.ClockByte > High(M)) then Exit;
  T := NowMs - StartTimeMs;
  V := 0;
  for K := 0 to 7 do
    if Frac(T / Periods[K]) < 0.5 then V := V or (1 shl K);
  M[Prog.ClockByte] := V;
end;

{ ---------- memory access ---------- }

procedure RaiseArea(const A: TAddr; ForWrite: Boolean; const Why: string);
var
  S: string;
begin
  if ForWrite then S := 'Area length error when writing ' else S := 'Area length error when reading ';
  raise EPlcError.Create(S + FormatAddr(A, cfS7300) + Why);
end;

function TPlcRuntime.AreaPtr(const A: TAddr; Bytes: Integer; ForWrite: Boolean): PByte;
var
  N, Ofs: Integer;
begin
  Result := nil;
  case A.Area of
    arI, arPI:
      begin
        if A.Ofs + Bytes > Length(I) then RaiseArea(A, ForWrite, '');
        if A.Area = arPI then
        begin
          if ForWrite then RaiseArea(A, True, ' (peripheral inputs are read only)');
          Result := @SimIn[A.Ofs];
        end
        else
          Result := @I[A.Ofs];
      end;
    arQ, arPQ:
      begin
        if A.Ofs + Bytes > Length(Q) then RaiseArea(A, ForWrite, '');
        Result := @Q[A.Ofs];
      end;
    arM:
      begin
        if A.Ofs + Bytes > Length(M) then RaiseArea(A, ForWrite, '');
        Result := @M[A.Ofs];
      end;
    arL:
      begin
        if A.Ofs + Bytes > LFrame then RaiseArea(A, ForWrite, ' (local data)');
        // DB = -1: the local data of the block about to be called (FC parameters)
        if A.DB = -1 then Result := @L[(FDepth + 1) * LFrame + A.Ofs]
        else Result := @L[FDepth * LFrame + A.Ofs];
      end;
    arDB, arDI:
      begin
        Ofs := A.Ofs;
        if A.Area = arDI then
        begin
          N := FCtx.DIReg;
          Inc(Ofs, FCtx.DIOfs);
        end
        else
        begin
          if A.DB > 0 then FCtx.DBReg := A.DB;   // a fully qualified access opens the DB
          N := FCtx.DBReg;
        end;
        if (N <= 0) or (N > High(DBs)) or not DBs[N].Present then
        begin
          if N <= 0 then raise EPlcError.Create('No DB open (OPN DB n) for ' + FormatAddr(A, cfS7300));
          raise EPlcError.Create(Format('DB%d not loaded (%s)', [N, FormatAddr(A, cfS7300)]));
        end;
        if Ofs + Bytes > Length(DBs[N].Data) then
          RaiseArea(A, ForWrite, Format(' (DB%d has %d bytes)', [N, Length(DBs[N].Data)]));
        Result := @DBs[N].Data[Ofs];
      end;
  else
    raise EPlcError.Create('operand not addressable: ' + AreaNames[A.Area]);
  end;
end;

function TPlcRuntime.ReadBitA(const A: TAddr): Boolean;
var
  P: PByte;
  K: Integer;
begin
  case A.Area of
    arT:
      begin
        K := TimerIdx(A);
        TickTimer(Timers[K], PlcNowMs);
        Exit(Timers[K].Q);
      end;
    arC:
      Exit(Counters[CounterIdx(A)].Value <> 0);
  end;
  P := AreaPtr(A, 1, False);
  Result := (P^ shr A.Bit) and 1 <> 0;
end;

procedure TPlcRuntime.WriteBitA(const A: TAddr; V: Boolean);
var
  P: PByte;
begin
  P := AreaPtr(A, 1, True);
  if V then P^ := P^ or (1 shl A.Bit) else P^ := P^ and not (1 shl A.Bit);
  if A.Area = arPQ then
  begin
    // immediate output: the module gets it now
    SimOut[A.Ofs] := Q[A.Ofs];
    if ForceMaskQ[A.Ofs] <> 0 then
      SimOut[A.Ofs] := (SimOut[A.Ofs] and not ForceMaskQ[A.Ofs]) or (ForceValQ[A.Ofs] and ForceMaskQ[A.Ofs]);
  end;
end;

function TPlcRuntime.ReadRaw(const A: TAddr): LongWord;
var
  P: PByte;
begin
  case A.Size of
    osBit:
      Result := Ord(ReadBitA(A));
    osByte:
      begin
        P := AreaPtr(A, 1, False);
        Result := P^;
      end;
    osWord:
      begin
        P := AreaPtr(A, 2, False);
        Result := (LongWord(P[0]) shl 8) or P[1];
      end;
  else
    P := AreaPtr(A, 4, False);
    Result := (LongWord(P[0]) shl 24) or (LongWord(P[1]) shl 16) or (LongWord(P[2]) shl 8) or P[3];
  end;
  if (A.Area = arPI) and (ForceCount > 0) then
  begin
    // forced peripheral inputs are forced on the bus as well
    case A.Size of
      osByte:
        Result := (Result and not ForceMaskI[A.Ofs]) or (ForceValI[A.Ofs] and ForceMaskI[A.Ofs]);
      osWord:
        Result := (Result and not ((LongWord(ForceMaskI[A.Ofs]) shl 8) or ForceMaskI[A.Ofs + 1])) or
          (((LongWord(ForceValI[A.Ofs]) shl 8) or ForceValI[A.Ofs + 1]) and
          ((LongWord(ForceMaskI[A.Ofs]) shl 8) or ForceMaskI[A.Ofs + 1]));
    end;
  end;
end;

procedure TPlcRuntime.WriteRaw(const A: TAddr; V: LongWord);
var
  P: PByte;
  N, K: Integer;
begin
  case A.Size of
    osBit:
      begin
        WriteBitA(A, V <> 0);
        Exit;
      end;
    osByte:
      begin
        P := AreaPtr(A, 1, True);
        P^ := V and $FF;
        N := 1;
      end;
    osWord:
      begin
        P := AreaPtr(A, 2, True);
        P[0] := (V shr 8) and $FF;
        P[1] := V and $FF;
        N := 2;
      end;
  else
    P := AreaPtr(A, 4, True);
    P[0] := V shr 24;
    P[1] := (V shr 16) and $FF;
    P[2] := (V shr 8) and $FF;
    P[3] := V and $FF;
    N := 4;
  end;
  if A.Area = arPQ then
    for K := A.Ofs to A.Ofs + N - 1 do
    begin
      SimOut[K] := Q[K];
      if ForceMaskQ[K] <> 0 then SimOut[K] := (SimOut[K] and not ForceMaskQ[K]) or (ForceValQ[K] and ForceMaskQ[K]);
    end;
end;

function TPlcRuntime.StatusBit(I: Integer): Boolean;
begin
  case I of
    0: Result := FCtx.BR;
    1: Result := FCtx.OV;
    2: Result := FCtx.OS;
    3: Result := not FCtx.CC1 and not FCtx.CC0;
    4: Result := FCtx.CC1 <> FCtx.CC0;
    5: Result := FCtx.CC1 and not FCtx.CC0;
    6: Result := not FCtx.CC1 and FCtx.CC0;
    7: Result := not FCtx.CC0;
    8: Result := not FCtx.CC1;
    9: Result := FCtx.CC1 and FCtx.CC0;
  else
    Result := False;
  end;
end;

function TPlcRuntime.ReadOpdBit(const O: TOperand): Boolean;
begin
  case O.Kind of
    okAddr: Result := ReadBitA(O.A);
    okStatus: Result := StatusBit(O.Status);
    okConst: Result := O.C.Bits <> 0;
  else
    Result := False;
  end;
end;

function TPlcRuntime.ReadOpdRaw(const O: TOperand): LongWord;
var
  K: Integer;
begin
  case O.Kind of
    okConst: Result := O.C.Bits;
    okAddr:
      case O.A.Area of
        arT:
          begin
            K := TimerIdx(O.A);
            Result := TimerValue(Timers[K], PlcNowMs, False);
          end;
        arC: Result := Counters[CounterIdx(O.A)].Value;
      else
        Result := ReadRaw(O.A);
      end;
  else
    Result := 0;
  end;
end;

function TPlcRuntime.ReadInt(const O: TOperand; T: TDataType): Int64;
var
  V: LongWord;
begin
  if O.Kind = okConst then
  begin
    case O.C.Kind of
      ckInt, ckDInt, ckTime, ckCounter, ckBool, ckChar: Exit(O.C.I);
      ckReal: Exit(Round(O.C.R));
      ckS5Time: Exit(O.C.I);
    else
      Exit(LongInt(O.C.Bits));
    end;
  end;
  if O.Kind = okNone then Exit(0);
  V := ReadOpdRaw(O);
  case O.A.Size of
    osBit: Result := V and 1;
    osByte: if T = dtSInt then Result := ShortInt(V and $FF) else Result := V and $FF;
    osWord: if T in [dtWord, dtUInt] then Result := V and $FFFF else Result := SmallInt(V and $FFFF);
  else
    if T in [dtDWord, dtUDInt] then Result := V else Result := LongInt(V);
  end;
end;

function TPlcRuntime.ReadReal(const O: TOperand; T: TDataType): Double;
begin
  if T <> dtReal then Exit(ReadInt(O, T));
  if O.Kind = okConst then
  begin
    if O.C.Kind = ckReal then Exit(O.C.R);
    if O.C.Kind in [ckInt, ckDInt] then Exit(O.C.I);
    Exit(BitsSg(O.C.Bits));
  end;
  if O.Kind = okNone then Exit(0);
  Result := BitsSg(ReadOpdRaw(O));
end;

procedure TPlcRuntime.WriteInt(const O: TOperand; T: TDataType; V: Int64);
begin
  if O.Kind <> okAddr then Exit;
  WriteRaw(O.A, LongWord(V));
end;

procedure TPlcRuntime.WriteReal(const O: TOperand; V: Double);
var
  Sg: Single;
begin
  if O.Kind <> okAddr then Exit;
  Sg := V;
  WriteRaw(O.A, SgBits(Sg));
end;

{ ---------- communication ---------- }

function TPlcRuntime.AreaIO(var R: TAreaReq; TimeoutMs: Integer): Boolean;
var
  C: TPlcCmd;
  T0: Double;
begin
  R.Done := RTLEventCreate;
  try
    C := NewCmd(ckAreaIO);
    C.Req := @R;
    R.Processed := False;
    Post(C);
    // the PLC thread answers within a cycle; the request lives on our stack, so
    // wait until it is really done (or the thread is gone at shutdown)
    T0 := PlcNowMs;
    repeat
      RTLEventWaitFor(R.Done, 100);
    until R.Processed or FThread.Finished or (PlcNowMs - T0 > Max(TimeoutMs, 60000));
    Result := R.Processed;
  finally
    RTLEventDestroy(R.Done);
    R.Done := nil;
  end;
end;

procedure TPlcRuntime.DoAreaIO(var R: TAreaReq);
var
  P: PByte;
  Lim, K, B, Bit, N: Integer;
  Ok: Boolean;
  V: LongWord;

  function Mem: Boolean;
  begin
    Result := False;
    P := nil;
    Lim := 0;
    case R.Area of
      arI: begin P := @I[0]; Lim := Length(I); end;
      arQ: begin P := @Q[0]; Lim := Length(Q); end;
      arM: begin P := @M[0]; Lim := Length(M); end;
      arDB:
        begin
          if (R.DB < 1) or (R.DB > High(DBs)) or not DBs[R.DB].Present then
          begin
            R.Res := arNoObject;
            Exit;
          end;
          if DBs[R.DB].Optimized then
          begin
            R.Res := arNotAllowed;
            Exit;
          end;
          Lim := Length(DBs[R.DB].Data);
          if Lim > 0 then P := @DBs[R.DB].Data[0];
        end;
    else
      begin
        R.Res := arTypeNotSupported;
        Exit;
      end;
    end;
    Result := True;
  end;

begin
  R.Res := arOk;
  if R.Len < 0 then
  begin
    R.Res := arOutOfRange;
    Exit;
  end;
  // timers and counters: two bytes each (S5TIME / counter value in BCD)
  if R.Area in [arT, arC] then
  begin
    if R.Area = arT then N := Length(Timers) else N := Length(Counters);
    if (R.Ofs < 0) or (R.Ofs + R.Len > N) then
    begin
      if N = 0 then R.Res := arNoObject else R.Res := arOutOfRange;
      Exit;
    end;
    if R.Write then
    begin
      if R.Area = arT then
      begin
        R.Res := arTypeNotSupported;
        Exit;
      end;
      for K := 0 to R.Len - 1 do
      begin
        V := BcdToInt(((LongWord(R.Data[K * 2]) shl 8) or R.Data[K * 2 + 1]) and $FFF, 3, Ok);
        if Ok then Counters[R.Ofs + K].Value := V;
      end;
      Exit;
    end;
    SetLength(R.Data, R.Len * 2);
    for K := 0 to R.Len - 1 do
    begin
      if R.Area = arT then V := TimerValue(Timers[R.Ofs + K], PlcNowMs, True)
      else V := IntToBcd(Counters[R.Ofs + K].Value, 3, Ok);
      R.Data[K * 2] := (V shr 8) and $FF;
      R.Data[K * 2 + 1] := V and $FF;
    end;
    Exit;
  end;
  if not Mem then Exit;
  if R.Bits then
  begin
    if (R.Ofs < 0) or ((R.Ofs + R.Len + 7) div 8 > Lim) or (R.Ofs + R.Len > Lim * 8) then
    begin
      R.Res := arOutOfRange;
      Exit;
    end;
    if not R.Write then
    begin
      SetLength(R.Data, (R.Len + 7) div 8);
      if Length(R.Data) > 0 then FillChar(R.Data[0], Length(R.Data), 0);
    end;
    for K := 0 to R.Len - 1 do
    begin
      B := (R.Ofs + K) div 8;
      Bit := (R.Ofs + K) mod 8;
      if R.Write then
      begin
        if (R.Data[K div 8] shr (K mod 8)) and 1 <> 0 then P[B] := P[B] or (1 shl Bit)
        else P[B] := P[B] and not (1 shl Bit);
      end
      else if (P[B] shr Bit) and 1 <> 0 then
        R.Data[K div 8] := R.Data[K div 8] or (1 shl (K mod 8));
    end;
    Exit;
  end;
  if (R.Ofs < 0) or (R.Ofs + R.Len > Lim) then
  begin
    R.Res := arOutOfRange;
    Exit;
  end;
  if R.Write then
  begin
    if R.Len > 0 then Move(R.Data[0], P[R.Ofs], R.Len);
  end
  else
  begin
    SetLength(R.Data, R.Len);
    if R.Len > 0 then Move(P[R.Ofs], R.Data[0], R.Len);
  end;
end;

{ ---------- peeking for the UI ---------- }

function TPlcRuntime.PeekRaw(const O: TOperand; out V: LongWord): Boolean;
var
  P: PByte;
  N, D: Integer;
  T: Double;
begin
  Result := False;
  V := 0;
  if O.Kind = okConst then
  begin
    V := O.C.Bits;
    Exit(True);
  end;
  if O.Kind <> okAddr then Exit;
  case O.A.Size of
    osBit, osByte: N := 1;
    osWord: N := 2;
  else
    N := 4;
  end;
  P := nil;
  case O.A.Area of
    arI: if O.A.Ofs + N <= Length(I) then P := @I[O.A.Ofs];
    arPI: if O.A.Ofs + N <= Length(SimIn) then P := @SimIn[O.A.Ofs];
    arQ: if O.A.Ofs + N <= Length(Q) then P := @Q[O.A.Ofs];
    arPQ: if O.A.Ofs + N <= Length(SimOut) then P := @SimOut[O.A.Ofs];
    arM: if O.A.Ofs + N <= Length(M) then P := @M[O.A.Ofs];
    arDB:
      begin
        D := O.A.DB;
        if (D > 0) and (D <= High(DBs)) and DBs[D].Present and (O.A.Ofs + N <= Length(DBs[D].Data)) then
          P := @DBs[D].Data[O.A.Ofs];
      end;
    arT:
      if O.A.Num < Length(Timers) then
      begin
        if O.A.Size = osBit then V := Ord(TimerQ(O.A.Num))
        else
        begin
          T := TimerRemainMs(O.A.Num);
          V := MsToS5Time(Round(T));
          if not Timers[O.A.Num].Running then V := Timers[O.A.Num].TV and $3000;
        end;
        Exit(True);
      end;
    arC:
      if O.A.Num < Length(Counters) then
      begin
        if O.A.Size = osBit then V := Ord(Counters[O.A.Num].Value <> 0)
        else V := IntToBcd(Counters[O.A.Num].Value, 3, Result);
        Exit(True);
      end;
  end;
  if P = nil then Exit;
  case O.A.Size of
    osBit: V := (P^ shr O.A.Bit) and 1;
    osByte: V := P^;
    osWord: V := (LongWord(P[0]) shl 8) or P[1];
  else
    V := (LongWord(P[0]) shl 24) or (LongWord(P[1]) shl 16) or (LongWord(P[2]) shl 8) or P[3];
  end;
  Result := True;
end;

function TPlcRuntime.PeekBit(const O: TOperand; out V: Boolean): Boolean;
var
  R: LongWord;
  O2: TOperand;
begin
  O2 := O;
  if (O2.Kind = okAddr) and (O2.A.Area in [arT, arC]) then O2.A.Size := osBit;
  Result := PeekRaw(O2, R);
  V := R <> 0;
end;

function TPlcRuntime.IsForced(const O: TOperand): Boolean;
var
  K, N: Integer;
  Mask: PByte;
  Len: Integer;
begin
  Result := False;
  if (O.Kind <> okAddr) or (ForceCount = 0) then Exit;
  case O.A.Area of
    arI, arPI: begin Mask := @ForceMaskI[0]; Len := Length(ForceMaskI); end;
    arQ, arPQ: begin Mask := @ForceMaskQ[0]; Len := Length(ForceMaskQ); end;
    arM: begin Mask := @ForceMaskM[0]; Len := Length(ForceMaskM); end;
  else
    Exit;
  end;
  if O.A.Size = osBit then
    Exit((O.A.Ofs < Len) and ((Mask[O.A.Ofs] shr O.A.Bit) and 1 <> 0));
  case O.A.Size of
    osByte: N := 1;
    osWord: N := 2;
  else
    N := 4;
  end;
  for K := O.A.Ofs to O.A.Ofs + N - 1 do
    if (K < Len) and (Mask[K] <> 0) then Exit(True);
end;

function TPlcRuntime.TimerRemainMs(N: Integer): Double;
var
  T: TS5Timer;
begin
  Result := 0;
  if (N < 0) or (N >= Length(Timers)) then Exit;
  T := Timers[N];
  if T.Running then Result := Max(0, T.DurMs - (PlcNowMs - T.StartMs));
end;

function TPlcRuntime.TimerRunning(N: Integer): Boolean;
begin
  Result := (N >= 0) and (N < Length(Timers)) and Timers[N].Running and
    (PlcNowMs - Timers[N].StartMs < Timers[N].DurMs);
end;

function TPlcRuntime.TimerQ(N: Integer): Boolean;
var
  T: TS5Timer;
begin
  Result := False;
  if (N < 0) or (N >= Length(Timers)) then Exit;
  T := Timers[N];
  Result := T.Q;
  if T.Running and (PlcNowMs - T.StartMs >= T.DurMs) then
    case T.Mode of
      1, 2: Result := False;
      3: Result := T.Edge;
      4: Result := True;
      5: Result := False;
    end;
end;

function TPlcRuntime.CounterValue(N: Integer): Integer;
begin
  if (N < 0) or (N >= Length(Counters)) then Exit(0);
  Result := Counters[N].Value;
end;

procedure TPlcRuntime.SetSimBit(ByteOfs, Bit: Integer; V: Boolean);
begin
  if (ByteOfs < 0) or (ByteOfs > High(SimIn)) then Exit;
  if V then SimIn[ByteOfs] := SimIn[ByteOfs] or (1 shl Bit)
  else SimIn[ByteOfs] := SimIn[ByteOfs] and not (1 shl Bit);
end;

function TPlcRuntime.GetSimBit(ByteOfs, Bit: Integer): Boolean;
begin
  Result := (ByteOfs >= 0) and (ByteOfs <= High(SimIn)) and ((SimIn[ByteOfs] shr Bit) and 1 <> 0);
end;

function TPlcRuntime.GetOutBit(ByteOfs, Bit: Integer): Boolean;
begin
  Result := (ByteOfs >= 0) and (ByteOfs <= High(SimOut)) and ((SimOut[ByteOfs] shr Bit) and 1 <> 0);
end;

procedure TPlcRuntime.SetSimWord(ByteOfs: Integer; V: SmallInt);
var
  W: Word;
begin
  if (ByteOfs < 0) or (ByteOfs + 1 > High(SimIn)) then Exit;
  W := Word(V);
  // one 16 bit store (big-endian in memory)
  PWord(@SimIn[ByteOfs])^ := Swap(W);
end;

function TPlcRuntime.GetOutWord(ByteOfs: Integer): SmallInt;
begin
  if (ByteOfs < 0) or (ByteOfs + 1 > High(SimOut)) then Exit(0);
  Result := SmallInt((Word(SimOut[ByteOfs]) shl 8) or SimOut[ByteOfs + 1]);
end;

{ ---------- timers and counters ---------- }

function TPlcRuntime.TimerIdx(const A: TAddr): Integer;
begin
  Result := A.Num;
  if (Result < 0) or (Result >= Length(Timers)) then
    raise EPlcError.Create(Format('Timer T%d does not exist', [A.Num]));
end;

function TPlcRuntime.CounterIdx(const A: TAddr): Integer;
begin
  Result := A.Num;
  if (Result < 0) or (Result >= Length(Counters)) then
    raise EPlcError.Create(Format('Counter C%d does not exist', [A.Num]));
end;

procedure TPlcRuntime.TickTimer(var T: TS5Timer; NowMs: Double);
begin
  if T.Running and (NowMs - T.StartMs >= T.DurMs) then
  begin
    T.Running := False;
    case T.Mode of
      1, 2: T.Q := False;           // SP / SE: pulse over
      3: T.Q := T.Edge;             // SD: on while the start signal is still 1
      4: T.Q := True;               // SS: latched until R
      5: T.Q := False;              // SF: off delay over
    end;
  end;
end;

function TPlcRuntime.TimerValue(var T: TS5Timer; NowMs: Double; BCD: Boolean): LongWord;
const
  Bases: array[0..3] of Integer = (10, 100, 1000, 10000);
var
  Base: Integer;
  Rem: Double;
  V: Int64;
  Ok: Boolean;
begin
  TickTimer(T, NowMs);
  Base := (T.TV shr 12) and 3;
  if T.Running then Rem := Max(0, T.DurMs - (NowMs - T.StartMs)) else Rem := 0;
  V := Ceil(Rem / Bases[Base]);
  if V > 999 then V := 999;
  if BCD then Result := IntToBcd(V, 3, Ok) or (LongWord(Base) shl 12)
  else Result := V;
end;

procedure TPlcRuntime.TimerOp(Code: TOpCode; const A: TAddr; S: Boolean);
var
  K: Integer;
  T: ^TS5Timer;
  Now: Double;
  Rising, Falling: Boolean;
  TV: Word;
  Ok: Boolean;

  procedure Start;
  begin
    TV := FCtx.Accu[1] and $FFFF;
    BcdToInt(TV and $FFF, 3, Ok);
    if not Ok then raise EPlcError.Create('BCD conversion error: time value ' + IntToHex(TV, 4));
    T^.TV := TV;
    T^.StartMs := Now;
    T^.DurMs := S5TimeToMs(TV);
    T^.Running := True;
  end;

begin
  K := TimerIdx(A);
  T := @Timers[K];
  Now := PlcNowMs;
  TickTimer(T^, Now);
  Rising := S and not T^.Edge;
  Falling := not S and T^.Edge;
  case Code of
    opSP:
      begin
        T^.Mode := 1;
        if Rising then
        begin
          Start;
          T^.Q := True;
        end;
        if not S then
        begin
          T^.Running := False;
          T^.Q := False;
        end;
        if T^.Running then T^.Q := True;
      end;
    opSE:
      begin
        T^.Mode := 2;
        if Rising then
        begin
          Start;
          T^.Q := True;
        end;
      end;
    opSD:
      begin
        T^.Mode := 3;
        if Rising then
        begin
          Start;
          T^.Q := False;
        end;
        if not S then
        begin
          T^.Running := False;
          T^.Q := False;
        end;
      end;
    opSS:
      begin
        T^.Mode := 4;
        if Rising then Start;
      end;
    opSF:
      begin
        T^.Mode := 5;
        if S then
        begin
          T^.Running := False;
          T^.Q := True;
        end
        else if Falling then
        begin
          Start;
          T^.Q := True;
        end;
      end;
  end;
  T^.Edge := S;
  if T^.DurMs <= 0 then TickTimer(T^, Now + 1);
end;

function TPlcRuntime.IecState(const A: TAddr): Integer;
var
  Key: Int64;
  Ix: Integer;
begin
  // an instance in the DI (an FB's static timer): the state belongs to the DB and offset it is in
  if A.Area = arDI then Key := Int64(FCtx.DIReg) shl 32 or (A.Ofs + FCtx.DIOfs)
  else Key := Int64(A.DB) shl 32 or A.Ofs;
  if FIecKeys.Find(Key, Ix) then Exit(FIecKeys.Data[Ix]);
  Result := Length(FIec);
  SetLength(FIec, Result + 1);
  FillChar(FIec[Result], SizeOf(TIecState), 0);
  FIecKeys.Add(Key, Result);
end;

{ ---------- IEC timers and counters (LAD boxes and SCL calls) ---------- }

function TPlcRuntime.InstMember(const Inst: TAddr; AOfs, ABit: Integer; ASize: TOpSize): TAddr;
begin
  Result := Inst;
  Result.Ofs := Result.Ofs + AOfs;
  Result.Bit := ABit;
  Result.Size := ASize;
end;

{ TON / TOF / TP / TONR on an IEC_TIMER (PT 0, ET 4, IN 8.0, Q 8.1); the result is Q }
function TPlcRuntime.IecTimer(Code: TOpCode; const Inst: TAddr; E: Boolean; PT: Int64; R: Boolean;
  out ET: Int64): Boolean;
var
  St: ^TIecState;
  Now: Double;
  V: Boolean;
  Ix: Integer;

  function Member(AOfs, ABit: Integer; ASize: TOpSize): TAddr;
  begin
    Result := InstMember(Inst, AOfs, ABit, ASize);
  end;

begin
  Now := PlcNowMs;
  // IecState may grow FIec: take the address only after it
  Ix := IecState(Inst);
  St := @FIec[Ix];
  if PT < 0 then PT := 0;
  WriteRaw(Member(0, 0, osDWord), LongWord(PT));
  ET := LongInt(ReadRaw(Member(4, 0, osDWord)));
  V := ReadBitA(Member(8, 1, osBit));
    case Code of
      opTON:
        if E then
        begin
          if not St^.PrevIn then
          begin
            St^.StartMs := Now;
            St^.Running := True;
          end;
          ET := Min(PT, Round(Now - St^.StartMs));
          V := ET >= PT;
        end
        else
        begin
          ET := 0;
          V := False;
          St^.Running := False;
        end;
      opTOF:
        if E then
        begin
          ET := 0;
          V := True;
          St^.Running := False;
        end
        else
        begin
          if St^.PrevIn then
          begin
            St^.StartMs := Now;
            St^.Running := True;
          end;
          if St^.Running then
          begin
            ET := Min(PT, Round(Now - St^.StartMs));
            V := ET < PT;
            if not V then St^.Running := False;
          end
          else
            V := False;
        end;
      opTP:
        begin
          if E and not St^.PrevIn and not St^.Running then
          begin
            St^.StartMs := Now;
            St^.Running := True;
          end;
          if St^.Running then
          begin
            ET := Min(PT, Round(Now - St^.StartMs));
            if ET >= PT then St^.Running := False;
          end
          else if not E then
            ET := 0;
          V := St^.Running;
        end;
    else
      begin
        // TONR: the time accumulates while IN = 1, R resets
        if R then
        begin
          ET := 0;
          St^.Running := False;
        end;
        if E then
        begin
          if not St^.Running then
          begin
            St^.StartMs := Now - ET;
            St^.Running := True;
          end;
          ET := Min(PT, Round(Now - St^.StartMs));
        end
        else
          St^.Running := False;
        V := ET >= PT;
      end;
    end;
  St^.PrevIn := E;
  WriteRaw(Member(4, 0, osDWord), LongWord(LongInt(ET)));
  WriteBitA(Member(8, 0, osBit), E);
  WriteBitA(Member(8, 1, osBit), V);
  Result := V;
end;

{ CTU / CTD / CTUD on an IEC_COUNTER (CU CD R LD QU QD in byte 0, PV 2, CV 4); the result is QU (CTD: QD) }
function TPlcRuntime.IecCounter(Code: TOpCode; const Inst: TAddr; CU, CD, R, LD: Boolean; PV: Int64;
  out CV: Int64): Boolean;
var
  I1, I2: Int64;
  V, V2, Done: Boolean;

  function Member(AOfs, ABit: Integer; ASize: TOpSize): TAddr;
  begin
    Result := InstMember(Inst, AOfs, ABit, ASize);
  end;

begin
  I1 := SmallInt(ReadRaw(Member(4, 0, osWord)) and $FFFF);
  I2 := EnsureRange(PV, -32768, 32767);
  WriteRaw(Member(2, 0, osWord), LongWord(I2) and $FFFF);
    case Code of
      opCTU:
        begin
          V := ReadBitA(Member(0, 0, osBit));    // old CU
          V2 := R;
          if V2 then I1 := 0
          else if CU and not V and (I1 < 32767) then Inc(I1);
          WriteBitA(Member(0, 0, osBit), CU);
          WriteBitA(Member(0, 2, osBit), V2);
          V := I1 >= I2;
          WriteBitA(Member(0, 4, osBit), V);
        end;
      opCTD:
        begin
          V := ReadBitA(Member(0, 1, osBit));    // old CD
          V2 := LD;
          if V2 then I1 := I2
          else if CD and not V and (I1 > -32768) then Dec(I1);
          WriteBitA(Member(0, 1, osBit), CD);
          WriteBitA(Member(0, 3, osBit), V2);
          V := I1 <= 0;
          WriteBitA(Member(0, 5, osBit), V);
        end;
    else
      begin
        Done := CD;
        V := ReadBitA(Member(0, 0, osBit));          // old CU
        V2 := ReadBitA(Member(0, 1, osBit));         // old CD
        if R then I1 := 0
        else if LD then I1 := I2
        else
        begin
          if CU and not V and (I1 < 32767) then Inc(I1);
          if Done and not V2 and (I1 > -32768) then Dec(I1);
        end;
        WriteBitA(Member(0, 0, osBit), CU);
        WriteBitA(Member(0, 1, osBit), Done);
        WriteBitA(Member(0, 2, osBit), R);
        WriteBitA(Member(0, 3, osBit), LD);
        WriteBitA(Member(0, 5, osBit), I1 <= 0);
        V := I1 >= I2;
        WriteBitA(Member(0, 4, osBit), V);
      end;
    end;
  WriteRaw(Member(4, 0, osWord), LongWord(I1) and $FFFF);
  CV := I1;
  Result := V;
  if Done then ;
end;

{ ---------- status helpers ---------- }

procedure TPlcRuntime.SetCCFromInt(V: Int64);
begin
  FCtx.CC1 := V > 0;
  FCtx.CC0 := V < 0;
end;

procedure TPlcRuntime.SetCCFromReal(V: Single);
begin
  if IsNan(V) then
  begin
    FCtx.CC1 := True;
    FCtx.CC0 := True;
  end
  else
  begin
    FCtx.CC1 := V > 0;
    FCtx.CC0 := V < 0;
  end;
end;

procedure TPlcRuntime.MonRecord(const B: TCBlock; Slot: Integer; Bit0: Boolean);
var
  S: PMonSlot;
  W: Word;
begin
  if (Slot < 0) or (Slot > High(B.Mon)) then Exit;
  S := @B.Mon[Slot];
  W := Ord(Bit0) or (Ord(FCtx.STA) shl 1) or (Ord(FCtx.FC) shl 2) or (Ord(FCtx.ORb) shl 3) or
    (Ord(FCtx.OS) shl 4) or (Ord(FCtx.OV) shl 5) or (Ord(FCtx.CC0) shl 6) or (Ord(FCtx.CC1) shl 7) or
    (Ord(FCtx.BR) shl 8);
  S^.Status := W;
  S^.Accu1 := FCtx.Accu[1];
  S^.Accu2 := FCtx.Accu[2];
  S^.DB := FCtx.DBReg;
  S^.Stamp := CycleNo;
end;

function TPlcRuntime.WhereStr: string;
var
  B: TCBlock;
  Pc, BI: Integer;
begin
  Result := '';
  BI := FCurBlock[FDepth];
  Pc := FCurPc[FDepth];
  if (Prog = nil) or (BI < 0) or (BI > High(Prog.Blocks)) then Exit;
  B := Prog.Blocks[BI];
  if (Pc < 0) or (Pc > High(B.Ops)) then Exit;
  Result := Format(' in %s network %d', [B.Title, B.Ops[Pc].Net + 1]);
  if (B.Ops[Pc].Net >= 0) and (B.Ops[Pc].Net <= High(B.Nets)) then
    if B.Nets[B.Ops[Pc].Net].Kind in [nkSTL, nkSCL] then
      Result := Result + Format(' line %d', [B.Ops[Pc].Line + 1])
    else if B.Ops[Pc].Line >= 0 then
      Result := Result + Format(' row %d column %d', [B.Ops[Pc].Line div Max(1, B.Nets[B.Ops[Pc].Net].Cols) + 1,
        B.Ops[Pc].Line mod Max(1, B.Nets[B.Ops[Pc].Net].Cols) + 1]);
end;

procedure TPlcRuntime.ProgError(const Msg: string);
var
  S: string;
  T: Double;
begin
  Inc(FErrThisCycle);
  if FErrThisCycle > 1 then Exit;
  // the same error every cycle: one entry per 2 s
  S := Msg + WhereStr;
  T := PlcNowMs;
  if (S = FLastErr) and (T - FLastErrMs < 2000) then Exit;
  FLastErr := S;
  FLastErrMs := T;
  DiagAdd(dkError, S);
end;

{ ---------- the interpreter ---------- }

{ ---------- SCL ---------- }

{ an integer value to its type (16 bit Int wraps like the CPU), REAL to single precision }
function SclWrap(V: Double; DT: TDataType): Double;
var
  I: Int64;
  Sg: Single;
begin
  if DT = dtReal then
  begin
    if IsNan(V) or IsInfinite(V) or (Abs(V) > 3.4E38) then Exit(V);
    Sg := V;
    Exit(Sg);
  end;
  if IsNan(V) or IsInfinite(V) then Exit(0);
  if Abs(V) > 9.2E18 then Exit(0);
  I := Trunc(V);
  case DT of
    dtBool: Result := Ord(I <> 0);
    dtSInt: Result := ShortInt(I and $FF);
    dtByte, dtUSInt, dtChar: Result := I and $FF;
    dtInt: Result := SmallInt(I and $FFFF);
    dtWord, dtUInt, dtS5Time, dtDate: Result := I and $FFFF;
    dtDInt, dtTime, dtTOD: Result := LongInt(I and $FFFFFFFF);
    dtUDInt, dtDWord: Result := I and $FFFFFFFF;
  else
    Result := V;
  end;
end;

function SclWidth(DT: TDataType): Integer;
begin
  case DT of
    dtByte, dtSInt, dtUSInt, dtChar: Result := 8;
    dtWord, dtInt, dtUInt: Result := 16;
  else
    Result := 32;
  end;
end;

function SclBin(Op: Integer; DT: TDataType; A, B: Double): Double;
var
  IA, IB, Mask: Int64;
  W, Nn: Integer;
begin
  try
    case Op of
      0: Result := A + B;
      1: Result := A - B;
      2: Result := A * B;
      3:
        if DT = dtReal then
        begin
          if B = 0 then
          begin
            if A = 0 then Result := NaN else if A > 0 then Result := Infinity else Result := NegInfinity;
          end
          else
            Result := A / B;
        end
        else if Trunc(B) = 0 then Result := 0
        else Result := Trunc(A) div Trunc(B);
      4: if Trunc(B) = 0 then Result := 0 else Result := Trunc(A) mod Trunc(B);
      5: Result := Power(A, B);
      6: Exit(Ord((A <> 0) and (B <> 0)));
      7: Exit(Ord((A <> 0) or (B <> 0)));
      8: Exit(Ord((A <> 0) xor (B <> 0)));
      9: Result := Trunc(A) and Trunc(B);
      10: Result := Trunc(A) or Trunc(B);
      11: Result := Trunc(A) xor Trunc(B);
      12: Exit(Ord(A = B));
      13: Exit(Ord(A <> B));
      14: Exit(Ord(A < B));
      15: Exit(Ord(A > B));
      16: Exit(Ord(A <= B));
      17: Exit(Ord(A >= B));
      18: Result := Min(A, B);
      19: Result := Max(A, B);
      20..23:
        begin
          W := SclWidth(DT);
          if W = 32 then Mask := $FFFFFFFF else Mask := (Int64(1) shl W) - 1;
          IA := Trunc(A) and Mask;
          Nn := Trunc(B);
          if Nn < 0 then Nn := 0;
          case Op of
            20: if Nn >= W then IB := 0 else IB := (IA shl Nn) and Mask;
            21: if Nn >= W then IB := 0 else IB := IA shr Nn;
            22: begin Nn := Nn mod W; IB := ((IA shl Nn) or (IA shr (W - Nn))) and Mask; end;
          else
            begin Nn := Nn mod W; IB := ((IA shr Nn) or (IA shl (W - Nn))) and Mask; end;
          end;
          Result := IB;
        end;
    else
      Result := 0;
    end;
  except
    Result := NaN;
  end;
  Result := SclWrap(Result, DT);
end;

function SclUn(Fn: Integer; DT: TDataType; V: Double): Double;
begin
  try
    case Fn of
      0: Result := SclWrap(-V, DT);
      1: Result := Ord(V = 0);
      2: Result := SclWrap(not Trunc(V), DT);
      3: Result := SclWrap(Abs(V), DT);
      4: if V < 0 then Result := NaN else Result := Sqrt(V);
      5: Result := V * V;
      6: if V <= 0 then Result := NaN else Result := Ln(V);
      7: if V > 88 then Result := Infinity else Result := Exp(V);
      8: Result := Sin(V);
      9: Result := Cos(V);
      10: Result := Tan(V);
      11: if Abs(V) > 1 then Result := NaN else Result := ArcSin(V);
      12: if Abs(V) > 1 then Result := NaN else Result := ArcCos(V);
      13: Result := ArcTan(V);
      14: if IsNan(V) or (Abs(V) > 2.1E9) then Result := 0 else Result := Round(V);   // halves to even
      15: if IsNan(V) or (Abs(V) > 2.1E9) then Result := 0 else Result := Trunc(V);
      16: if IsNan(V) or (Abs(V) > 2.1E9) then Result := 0 else Result := Ceil(V);
      17: if IsNan(V) or (Abs(V) > 2.1E9) then Result := 0 else Result := Floor(V);
      18: Result := SclWrap(V, DT);
      19: Result := Ord(V <> 0);
      20: if V <= 0 then Result := NaN else Result := Log10(V);
      21: Result := Frac(V);
    else
      Result := V;
    end;
  except
    Result := NaN;
  end;
  if Fn in [4..13, 20, 21] then Result := SclWrap(Result, dtReal);
end;

function SclTern(Fn: Integer; DT: TDataType; A, B, C: Double): Double;
begin
  case Fn of
    0: Result := SclWrap(Min(Max(B, A), C), DT);                    // LIMIT(MN, IN, MX)
    1: if A <> 0 then Result := C else Result := B;                   // SEL(G, IN0, IN1)
    2: if C = A then Result := 0 else Result := SclWrap((B - A) / (C - A), dtReal);   // NORM_X
  else
    begin
      Result := B * (C - A) + A;                                      // SCALE_X
      if DT <> dtReal then Result := Round(Result);
      Result := SclWrap(Result, DT);
    end;
  end;
end;

procedure TPlcRuntime.SPush(V: Double);
begin
  if FSp > High(FSt) then raise EPlcFatal.Create('SCL: expression stack overflow');
  FSt[FSp] := V;
  Inc(FSp);
end;

function TPlcRuntime.SPop: Double;
begin
  if FSp <= 0 then raise EPlcError.Create('SCL: expression stack underflow');
  Dec(FSp);
  Result := FSt[FSp];
end;

function TPlcRuntime.SclRead(const O: TOperand; DT: TDataType): Double;
begin
  if (O.Kind = okAddr) and ((O.A.Size = osBit) or (O.A.Area in [arT, arC]) and (DT = dtBool)) then
    Result := Ord(ReadBitA(O.A))
  else if DT = dtReal then Result := ReadReal(O, dtReal)
  else Result := ReadInt(O, DT);
end;

procedure TPlcRuntime.SclWrite(const O: TOperand; DT: TDataType; V: Double);
var
  W: Double;
begin
  if O.Kind <> okAddr then Exit;
  if O.A.Size = osBit then WriteBitA(O.A, V <> 0)
  else if DT = dtReal then WriteReal(O, V)
  else
  begin
    W := SclWrap(V, DT);
    WriteRaw(O.A, LongWord(Int64(Trunc(W)) and $FFFFFFFF));
  end;
end;

{ "DB".Arr[i]: the element's address; the index is checked against the bounds }
{ the operand of an access with variable indexes: Opd is the first element, BitOfs from opSIndex }
function TPlcRuntime.SclIdx(const Op: TOp; BitOfs: Int64): TOperand;
begin
  Result := SclIdx(Op, BitOfs, Op.Opd);
end;

function TPlcRuntime.SclIdx(const Op: TOp; BitOfs: Int64; const Base: TOperand): TOperand;
var
  BitPos: Int64;
begin
  Result := Base;
  BitPos := Int64(Result.A.Ofs) * 8 + Result.A.Bit + BitOfs;
  Result.A.Ofs := BitPos div 8;
  Result.A.Bit := BitPos mod 8;
end;

procedure TPlcRuntime.RunOB(BI: Integer);
begin
  FDepth := 0;
  FNestN := 0;
  FSp := 0;
  FCtx.FC := False;
  FCtx.ORb := False;
  FCtx.RLO := False;
  FCtx.DBReg := 0;
  FCtx.DIReg := 0;
  FCtx.DIOfs := 0;
  ExecBlock(BI);
end;

procedure TPlcRuntime.CheckCyclic;
var
  Saved: TCtx;
  SavedNest: Integer;
  SavedDepth: Integer;
  Now: Double;
begin
  if FInCyclic or (Prog = nil) or (Prog.OBCyc < 0) or (Mode <> rmRun) then Exit;
  Now := PlcNowMs;
  if Now < FNextCycMs then Exit;
  if Now - FNextCycMs > Prog.CyclicMs then
  begin
    Inc(CycLate);
    FNextCycMs := Now;
  end;
  FNextCycMs := FNextCycMs + Max(1, Prog.CyclicMs);
  // the interrupt is transparent for the interrupted block
  Saved := FCtx;
  SavedNest := FNestN;
  SavedDepth := FDepth;
  FInCyclic := True;
  try
    Inc(FDepth);
    FCurBlock[FDepth] := Prog.OBCyc;
    FCtx.FC := False;
    FCtx.ORb := False;
    FCtx.DBReg := 0;
    FNestN := 0;
    ExecBlock(Prog.OBCyc);
    Inc(CycCount);
  finally
    FInCyclic := False;
    FDepth := SavedDepth;
    FNestN := SavedNest;
    FCtx := Saved;
  end;
end;

{ the values an integer type holds (CONV, ROUND, ...: a value outside is ENO = 0) }
function InTypeRange(T: TDataType; V: Int64): Boolean;
begin
  case T of
    dtByte, dtUSInt, dtChar: Result := (V >= 0) and (V <= 255);
    dtSInt: Result := (V >= -128) and (V <= 127);
    dtWord, dtUInt: Result := (V >= 0) and (V <= 65535);
    dtInt: Result := (V >= -32768) and (V <= 32767);
    dtDWord, dtUDInt: Result := (V >= 0) and (V <= 4294967295);
  else
    Result := (V >= -2147483648) and (V <= 2147483647);
  end;
end;

procedure TPlcRuntime.ExecBlock(BI: Integer);
var
  B: TCBlock;
  Pc, NOps, Bits, Cnt, K: Integer;
  Op: ^TOp;
  V, V2, E, Done: Boolean;
  A1, A2, R: LongWord;
  I1, I2, IR: Int64;
  T2: TDataType;
  S1, S2, SR: Single;
  D1: Double;
  Opd2, CpDst: TOperand;
  CpSrc, CpTo: PByte;
  SavedNest: Integer;
  SavedDB, SavedDI: Integer;
  St: ^TIecState;
  Ix: Integer;
  PT, ET: Int64;
  Now: Double;
  Ok: Boolean;
  Mon: Boolean;
  Pars: ^TOperand;

  function Eff: Boolean; inline;
  begin
    Result := FCtx.ORb or FCtx.RLO;
  end;

  procedure DoA(Val: Boolean); inline;
  begin
    if FCtx.FC then FCtx.RLO := FCtx.RLO and Val
    else
    begin
      FCtx.RLO := Val;
      FCtx.FC := True;
    end;
  end;

  procedure DoO(Val: Boolean); inline;
  begin
    if FCtx.FC then
    begin
      FCtx.ORb := FCtx.ORb or FCtx.RLO;
      FCtx.RLO := Val;
    end
    else
    begin
      FCtx.RLO := Val;
      FCtx.FC := True;
    end;
  end;

  procedure DoX(Val: Boolean); inline;
  begin
    if FCtx.FC then
    begin
      FCtx.RLO := (FCtx.ORb or FCtx.RLO) xor Val;
      FCtx.ORb := False;
    end
    else
    begin
      FCtx.RLO := Val;
      FCtx.FC := True;
    end;
  end;

  procedure EndBit(Val: Boolean); inline;
  begin
    FCtx.RLO := Val;
    FCtx.ORb := False;
    FCtx.FC := False;
  end;

  procedure ArithPull; inline;
  begin
    if Model.Accus = 4 then
    begin
      FCtx.Accu[2] := FCtx.Accu[3];
      FCtx.Accu[3] := FCtx.Accu[4];
    end;
  end;

  procedure IntResult(Val: Int64; Wide: Boolean);
  begin
    if Wide then
    begin
      FCtx.OV := (Val < -2147483648) or (Val > 2147483647);
      FCtx.Accu[1] := LongWord(Val);
      SetCCFromInt(LongInt(FCtx.Accu[1]));
    end
    else
    begin
      FCtx.OV := (Val < -32768) or (Val > 32767);
      FCtx.Accu[1] := (FCtx.Accu[1] and $FFFF0000) or (LongWord(Val) and $FFFF);
      SetCCFromInt(SmallInt(FCtx.Accu[1] and $FFFF));
    end;
    if FCtx.OV then FCtx.OS := True;
  end;

  procedure RealResult(Val: Single);
  begin
    FCtx.Accu[1] := SgBits(Val);
    SetCCFromReal(Val);
    FCtx.OV := IsNan(Val) or IsInfinite(Val);
    if FCtx.OV then FCtx.OS := True;
  end;

  procedure Compare(CmpOp: Integer; Gt, Lt, Eq: Boolean);
  begin
    FCtx.CC1 := Gt;
    FCtx.CC0 := Lt;
    FCtx.OV := False;
    case TCmpOp(CmpOp) of
      coEQ: V := Eq;
      coNE: V := not Eq;
      coGT: V := Gt;
      coLT: V := Lt;
      coGE: V := Gt or Eq;
    else
      V := Lt or Eq;
    end;
    FCtx.RLO := V;
    FCtx.ORb := False;
    FCtx.FC := True;
    FCtx.STA := V;
  end;

  function CmpNum(CmpOp: Integer; X, Y: Double): Boolean;
  begin
    case TCmpOp(CmpOp) of
      coEQ: Result := X = Y;
      coNE: Result := X <> Y;
      coGT: Result := X > Y;
      coLT: Result := X < Y;
      coGE: Result := X >= Y;
    else
      Result := X <= Y;
    end;
  end;

  function ShiftCount: Integer;
  begin
    if Op^.Sub >= 0 then Result := Op^.Sub else Result := FCtx.Accu[2] and $FF;
  end;

  procedure Jump;
  begin
    Pc := Op^.Ext - 1;   // the loop increments
  end;

  procedure AfterCondJump;
  begin
    FCtx.FC := False;
    FCtx.RLO := True;
    FCtx.ORb := False;
    FCtx.STA := True;
  end;

  procedure CallBlock(Target: Integer);
  var
    SavedReg: array[0..15] of Double;
    SavedDIOfs: Integer;
  begin
    if FDepth >= MaxDepth - 1 then raise EPlcFatal.Create('Block stack overflow (calls nested too deep)');
    SavedNest := FNestN;
    SavedDB := FCtx.DBReg;
    SavedDI := FCtx.DIReg;
    SavedDIOfs := FCtx.DIOfs;
    SavedReg := FReg;    // SCL CASE selectors and instance offsets of the caller
    FCurPc[FDepth] := Pc;
    Inc(FDepth);
    FCurBlock[FDepth] := Target;
    FNestN := 0;
    FCtx.FC := False;
    FCtx.ORb := False;
    try
      ExecBlock(Target);
    finally
      Dec(FDepth);
      FNestN := SavedNest;
      // the block stack restores the DB registers
      FCtx.DBReg := SavedDB;
      FCtx.DIReg := SavedDI;
      FCtx.DIOfs := SavedDIOfs;
      FReg := SavedReg;
    end;
    FCtx.FC := False;
    FCtx.ORb := False;
  end;

  { an FB: the instance DB (or the caller's instance for a multi-instance) in the DI register }
  procedure CallFB;
  var
    Inst: TAddr;
    N, Ofs, OldDI, OldOfs: Integer;
  begin
    Inst := Op^.Opd.A;
    if Op^.Lo and 1 <> 0 then Inst.Ofs := Inst.Ofs + Round(SPop) div 8;
    if Inst.Area = arDI then
    begin
      N := FCtx.DIReg;
      Ofs := FCtx.DIOfs + Inst.Ofs;
    end
    else
    begin
      N := Inst.DB;
      Ofs := Inst.Ofs;
    end;
    if (N <= 0) or (N > High(DBs)) or not DBs[N].Present then
      raise EPlcError.Create(Format('instance DB%d not loaded (%s)', [N, Prog.Blocks[Op^.Ext].Title]));
    OldDI := FCtx.DIReg;
    OldOfs := FCtx.DIOfs;
    FCtx.DIReg := N;
    FCtx.DIOfs := Ofs;
    try
      CallBlock(Op^.Ext);
    finally
      FCtx.DIReg := OldDI;
      FCtx.DIOfs := OldOfs;
    end;
  end;

  { an IEC_TIMER / IEC_COUNTER member: instance + offset }
  function Member(AOfs, ABit: Integer; ASize: TOpSize): TAddr;
  begin
    Result := Op^.Opd.A;
    Result.Ofs := Result.Ofs + AOfs;
    Result.Bit := ABit;
    Result.Size := ASize;
  end;

  function Par(N: Integer): TOperand; inline;
  begin
    Result := B.Params[Op^.Ext + N];
  end;

begin
  if (Prog = nil) or (BI < 0) or (BI > High(Prog.Blocks)) then
    raise EPlcError.Create('Block not loaded');
  B := Prog.Blocks[BI];
  FCurBlock[FDepth] := BI;
  NOps := Length(B.Ops);
  Mon := BI = MonBlock;
  Pc := 0;
  while Pc < NOps do
  begin
    Op := @B.Ops[Pc];
    FCurPc[FDepth] := Pc;
    Inc(FCatCount[Op^.Cat], Op^.Weight);
    Inc(FOpsCount);
    if FOpsCount and 1023 = 0 then
      if PlcNowMs - FCycleStartMs > Model.WatchdogMs then
      begin
        if FErrWhere = '' then FErrWhere := WhereStr;
        raise EPlcFatal.Create(Format('Cycle time exceeded (%d ms), OB80 not loaded', [Model.WatchdogMs]));
      end;
    try
      case Op^.Code of
        opNop: ;
        // ---------- bit logic ----------
        opA, opAN, opO, opON, opX, opXN:
          begin
            V := ReadOpdBit(Op^.Opd);
            FCtx.STA := V;
            if Op^.Code in [opAN, opON, opXN] then V := not V;
            case Op^.Code of
              opA, opAN: DoA(V);
              opO, opON: DoO(V);
            else
              DoX(V);
            end;
          end;
        opOAlone:
          begin
            if FCtx.FC then FCtx.ORb := FCtx.ORb or FCtx.RLO;
            FCtx.FC := False;
          end;
        opAParen, opANParen, opOParen, opONParen, opXParen, opXNParen:
          begin
            if FNestN > 6 then raise EPlcError.Create('Nesting stack overflow (more than 7 levels)');
            FNest[FNestN].RLO := FCtx.RLO;
            FNest[FNestN].ORb := FCtx.ORb;
            FNest[FNestN].FC := FCtx.FC;
            FNest[FNestN].Code := Op^.Code;
            Inc(FNestN);
            FCtx.FC := False;
            FCtx.ORb := False;
          end;
        opParenClose:
          begin
            if FNestN = 0 then raise EPlcError.Create('Nesting stack underflow: ) without (');
            V := Eff;
            Dec(FNestN);
            FCtx.RLO := FNest[FNestN].RLO;
            FCtx.ORb := FNest[FNestN].ORb;
            FCtx.FC := FNest[FNestN].FC;
            case FNest[FNestN].Code of
              opAParen: DoA(V);
              opANParen: DoA(not V);
              opOParen: DoO(V);
              opONParen: DoO(not V);
              opXParen: DoX(V);
            else
              DoX(not V);
            end;
          end;
        opAssign:
          begin
            V := Eff;
            WriteBitA(Op^.Opd.A, V);
            EndBit(V);
          end;
        opCoilNeg:
          begin
            V := Eff;
            WriteBitA(Op^.Opd.A, not V);
            EndBit(V);
          end;
        opS:
          begin
            V := Eff;
            if V then WriteBitA(Op^.Opd.A, True);
            EndBit(V);
          end;
        opR:
          begin
            V := Eff;
            if V then
              case Op^.Opd.A.Area of
                arT:
                  begin
                    K := TimerIdx(Op^.Opd.A);
                    Timers[K].Running := False;
                    Timers[K].Q := False;
                    Timers[K].TV := Timers[K].TV and $3000;
                  end;
                arC: Counters[CounterIdx(Op^.Opd.A)].Value := 0;
              else
                WriteBitA(Op^.Opd.A, False);
              end;
            EndBit(V);
          end;
        opNOT:
          begin
            FCtx.RLO := not Eff;
            FCtx.ORb := False;
          end;
        opSET:
          begin
            EndBit(True);
            FCtx.STA := True;
          end;
        opCLR:
          begin
            EndBit(False);
            FCtx.STA := False;
          end;
        opSAVE: FCtx.BR := Eff;
        opFP, opFN:
          begin
            V := Eff;
            V2 := ReadBitA(Op^.Opd.A);
            WriteBitA(Op^.Opd.A, V);
            if Op^.Code = opFP then V := V and not V2 else V := not V and V2;
            FCtx.RLO := V;
            FCtx.ORb := False;
            FCtx.FC := True;
          end;
        // ---------- S5 timers / counters ----------
        opSP, opSE, opSD, opSS, opSF:
          begin
            V := Eff;
            TimerOp(Op^.Code, Op^.Opd.A, V);
            FCtx.FC := False;
            FCtx.ORb := False;
            FCtx.RLO := V;
          end;
        opFR:
          begin
            V := Eff;
            if V then
              if Op^.Opd.A.Area = arT then Timers[TimerIdx(Op^.Opd.A)].Edge := False
              else
              begin
                K := CounterIdx(Op^.Opd.A);
                Counters[K].EdgeU := False;
                Counters[K].EdgeD := False;
                Counters[K].EdgeS := False;
              end;
            EndBit(V);
          end;
        opCU, opCD, opSC:
          begin
            V := Eff;
            K := CounterIdx(Op^.Opd.A);
            case Op^.Code of
              opCU:
                begin
                  if V and not Counters[K].EdgeU and (Counters[K].Value < 999) then Inc(Counters[K].Value);
                  Counters[K].EdgeU := V;
                end;
              opCD:
                begin
                  if V and not Counters[K].EdgeD and (Counters[K].Value > 0) then Dec(Counters[K].Value);
                  Counters[K].EdgeD := V;
                end;
            else
              begin
                if V and not Counters[K].EdgeS then
                begin
                  Cnt := BcdToInt(FCtx.Accu[1] and $FFF, 3, Ok);
                  if not Ok then
                    raise EPlcError.Create('BCD conversion error: counter preset ' + IntToHex(FCtx.Accu[1] and $FFFF, 4));
                  Counters[K].Value := Cnt;
                end;
                Counters[K].EdgeS := V;
              end;
            end;
            EndBit(V);
          end;
        // ---------- load / transfer ----------
        opL:
          begin
            R := ReadOpdRaw(Op^.Opd);
            FCtx.Accu[2] := FCtx.Accu[1];
            FCtx.Accu[1] := R;
          end;
        opLC:
          begin
            if Op^.Opd.A.Area = arT then
              R := TimerValue(Timers[TimerIdx(Op^.Opd.A)], PlcNowMs, True)
            else
              R := IntToBcd(Counters[CounterIdx(Op^.Opd.A)].Value, 3, Ok);
            FCtx.Accu[2] := FCtx.Accu[1];
            FCtx.Accu[1] := R;
          end;
        opT: WriteRaw(Op^.Opd.A, FCtx.Accu[1]);
        opLDBNO, opLDBLG, opLDINO, opLDILG:
          begin
            FCtx.Accu[2] := FCtx.Accu[1];
            if Op^.Code in [opLDBNO, opLDBLG] then K := FCtx.DBReg else K := FCtx.DIReg;
            if Op^.Code in [opLDBNO, opLDINO] then FCtx.Accu[1] := K
            else if (K > 0) and (K <= High(DBs)) then FCtx.Accu[1] := Length(DBs[K].Data)
            else FCtx.Accu[1] := 0;
          end;
        opTAK:
          begin
            R := FCtx.Accu[1];
            FCtx.Accu[1] := FCtx.Accu[2];
            FCtx.Accu[2] := R;
          end;
        opPUSH:
          begin
            if Model.Accus = 4 then
            begin
              FCtx.Accu[4] := FCtx.Accu[3];
              FCtx.Accu[3] := FCtx.Accu[2];
            end;
            FCtx.Accu[2] := FCtx.Accu[1];
          end;
        opPOP:
          begin
            FCtx.Accu[1] := FCtx.Accu[2];
            if Model.Accus = 4 then
            begin
              FCtx.Accu[2] := FCtx.Accu[3];
              FCtx.Accu[3] := FCtx.Accu[4];
            end;
          end;
        opENT:
          begin
            FCtx.Accu[4] := FCtx.Accu[3];
            FCtx.Accu[3] := FCtx.Accu[2];
          end;
        opLEAVE:
          begin
            FCtx.Accu[2] := FCtx.Accu[3];
            FCtx.Accu[3] := FCtx.Accu[4];
          end;
        opCAW:
          begin
            R := FCtx.Accu[1];
            FCtx.Accu[1] := (R and $FFFF0000) or ((R and $FF) shl 8) or ((R shr 8) and $FF);
          end;
        opCAD:
          begin
            R := FCtx.Accu[1];
            FCtx.Accu[1] := (R shl 24) or ((R and $FF00) shl 8) or ((R shr 8) and $FF00) or (R shr 24);
          end;
        opINC: FCtx.Accu[1] := (FCtx.Accu[1] and $FFFFFF00) or ((FCtx.Accu[1] + LongWord(Op^.Sub)) and $FF);
        opDEC: FCtx.Accu[1] := (FCtx.Accu[1] and $FFFFFF00) or ((FCtx.Accu[1] - LongWord(Op^.Sub)) and $FF);
        // ---------- integer arithmetic ----------
        opAddI, opSubI, opMulI:
          begin
            I1 := SmallInt(FCtx.Accu[2] and $FFFF);
            I2 := SmallInt(FCtx.Accu[1] and $FFFF);
            case Op^.Code of
              opAddI: IR := I1 + I2;
              opSubI: IR := I1 - I2;
            else
              IR := I1 * I2;
            end;
            if Op^.Code = opMulI then
            begin
              // the product goes into the whole ACCU1, OV when outside INT
              FCtx.Accu[1] := LongWord(LongInt(IR));
              FCtx.OV := (IR < -32768) or (IR > 32767);
              if FCtx.OV then FCtx.OS := True;
              SetCCFromInt(IR);
            end
            else
              IntResult(IR, False);
            ArithPull;
          end;
        opDivI:
          begin
            I1 := SmallInt(FCtx.Accu[2] and $FFFF);
            I2 := SmallInt(FCtx.Accu[1] and $FFFF);
            if I2 = 0 then
            begin
              FCtx.OV := True;
              FCtx.OS := True;
              FCtx.CC1 := True;
              FCtx.CC0 := True;
            end
            else
            begin
              IR := I1 div I2;
              K := I1 mod I2;
              FCtx.Accu[1] := (LongWord(K) and $FFFF) shl 16;
              IntResult(IR, False);
            end;
            ArithPull;
          end;
        opAddD, opSubD, opMulD:
          begin
            I1 := LongInt(FCtx.Accu[2]);
            I2 := LongInt(FCtx.Accu[1]);
            case Op^.Code of
              opAddD: IR := I1 + I2;
              opSubD: IR := I1 - I2;
            else
              IR := I1 * I2;
            end;
            IntResult(IR, True);
            ArithPull;
          end;
        opDivD, opMOD:
          begin
            I1 := LongInt(FCtx.Accu[2]);
            I2 := LongInt(FCtx.Accu[1]);
            if I2 = 0 then
            begin
              FCtx.OV := True;
              FCtx.OS := True;
              FCtx.CC1 := True;
              FCtx.CC0 := True;
            end
            else
            begin
              if Op^.Code = opDivD then IR := I1 div I2 else IR := I1 mod I2;
              IntResult(IR, True);
            end;
            ArithPull;
          end;
        opAddConst:
          if Op^.Opd.C.Size = osDWord then
            FCtx.Accu[1] := FCtx.Accu[1] + LongWord(LongInt(Op^.Opd.C.I))
          else
            FCtx.Accu[1] := (FCtx.Accu[1] and $FFFF0000) or ((FCtx.Accu[1] + LongWord(Op^.Opd.C.I)) and $FFFF);
        // ---------- floating point ----------
        opAddR, opSubR, opMulR, opDivR:
          begin
            S1 := BitsSg(FCtx.Accu[2]);
            S2 := BitsSg(FCtx.Accu[1]);
            case Op^.Code of
              opAddR: SR := S1 + S2;
              opSubR: SR := S1 - S2;
              opMulR: SR := S1 * S2;
            else
              if S2 = 0 then
              begin
                if S1 = 0 then SR := NaN
                else if S1 > 0 then SR := Infinity
                else SR := NegInfinity;
              end
              else
                SR := S1 / S2;
            end;
            RealResult(SR);
            ArithPull;
          end;
        opABS: FCtx.Accu[1] := FCtx.Accu[1] and $7FFFFFFF;
        opSQRT, opSQR, opLN, opEXP, opSIN, opCOS, opTAN, opASIN, opACOS, opATAN:
          begin
            S1 := BitsSg(FCtx.Accu[1]);
            case Op^.Code of
              opSQRT: if S1 < 0 then SR := NaN else SR := Sqrt(S1);
              opSQR: SR := S1 * S1;
              opLN: if S1 <= 0 then SR := NaN else SR := Ln(S1);
              opEXP: if S1 > 88 then SR := Infinity else SR := Exp(S1);
              opSIN: SR := Sin(S1);
              opCOS: SR := Cos(S1);
              opTAN: SR := Tan(S1);
              opASIN: if Abs(S1) > 1 then SR := NaN else SR := ArcSin(S1);
              opACOS: if Abs(S1) > 1 then SR := NaN else SR := ArcCos(S1);
            else
              SR := ArcTan(S1);
            end;
            RealResult(SR);
          end;
        opNEGI:
          begin
            I1 := SmallInt(FCtx.Accu[1] and $FFFF);
            IntResult(-I1, False);
          end;
        opNEGD:
          begin
            I1 := LongInt(FCtx.Accu[1]);
            IntResult(-I1, True);
          end;
        opNEGR: FCtx.Accu[1] := FCtx.Accu[1] xor $80000000;
        opINVI: FCtx.Accu[1] := FCtx.Accu[1] xor $FFFF;
        opINVD: FCtx.Accu[1] := not FCtx.Accu[1];
        // ---------- conversion ----------
        opITD: FCtx.Accu[1] := LongWord(LongInt(SmallInt(FCtx.Accu[1] and $FFFF)));
        opDTR:
          begin
            S1 := LongInt(FCtx.Accu[1]);
            FCtx.Accu[1] := SgBits(S1);
          end;
        opITB:
          begin
            I1 := SmallInt(FCtx.Accu[1] and $FFFF);
            if Abs(I1) > 999 then
            begin
              FCtx.OV := True;
              FCtx.OS := True;
            end
            else
            begin
              R := IntToBcd(Abs(I1), 3, Ok);
              if I1 < 0 then R := R or $F000;
              FCtx.Accu[1] := (FCtx.Accu[1] and $FFFF0000) or R;
              FCtx.OV := False;
            end;
          end;
        opBTI:
          begin
            I1 := BcdToInt(FCtx.Accu[1] and $FFF, 3, Ok);
            if not Ok then raise EPlcError.Create('BCD conversion error (BTI): ' + IntToHex(FCtx.Accu[1] and $FFFF, 4));
            if FCtx.Accu[1] and $8000 <> 0 then I1 := -I1;
            FCtx.Accu[1] := (FCtx.Accu[1] and $FFFF0000) or (LongWord(I1) and $FFFF);
          end;
        opDTB:
          begin
            I1 := LongInt(FCtx.Accu[1]);
            if Abs(I1) > 9999999 then
            begin
              FCtx.OV := True;
              FCtx.OS := True;
            end
            else
            begin
              R := IntToBcd(Abs(I1), 7, Ok);
              if I1 < 0 then R := R or $F0000000;
              FCtx.Accu[1] := R;
              FCtx.OV := False;
            end;
          end;
        opBTD:
          begin
            I1 := BcdToInt(FCtx.Accu[1] and $0FFFFFFF, 7, Ok);
            if not Ok then raise EPlcError.Create('BCD conversion error (BTD): ' + IntToHex(FCtx.Accu[1], 8));
            if FCtx.Accu[1] and $80000000 <> 0 then I1 := -I1;
            FCtx.Accu[1] := LongWord(LongInt(I1));
          end;
        opRND, opTRUNC, opRNDP, opRNDM:
          begin
            S1 := BitsSg(FCtx.Accu[1]);
            if IsNan(S1) or (S1 > 2147483647.0) or (S1 < -2147483648.0) then
            begin
              FCtx.OV := True;
              FCtx.OS := True;
            end
            else
            begin
              case Op^.Code of
                opRND: IR := Round(S1);        // halves to the even number
                opTRUNC: IR := Trunc(S1);
                opRNDP: IR := Ceil(S1);
              else
                IR := Floor(S1);
              end;
              FCtx.Accu[1] := LongWord(LongInt(IR));
              FCtx.OV := False;
            end;
          end;
        // ---------- compare ----------
        opCmpI:
          begin
            I1 := SmallInt(FCtx.Accu[2] and $FFFF);
            I2 := SmallInt(FCtx.Accu[1] and $FFFF);
            Compare(Op^.Sub, I1 > I2, I1 < I2, I1 = I2);
          end;
        opCmpD:
          begin
            I1 := LongInt(FCtx.Accu[2]);
            I2 := LongInt(FCtx.Accu[1]);
            Compare(Op^.Sub, I1 > I2, I1 < I2, I1 = I2);
          end;
        opCmpR:
          begin
            S1 := BitsSg(FCtx.Accu[2]);
            S2 := BitsSg(FCtx.Accu[1]);
            if IsNan(S1) or IsNan(S2) then
            begin
              Compare(Op^.Sub, False, False, False);
              FCtx.RLO := False;
              FCtx.CC1 := True;
              FCtx.CC0 := True;
              FCtx.OV := True;
              FCtx.OS := True;
            end
            else
              Compare(Op^.Sub, S1 > S2, S1 < S2, S1 = S2);
          end;
        // ---------- word logic ----------
        opAW, opOW, opXOW:
          begin
            if Op^.Opd.Kind = okConst then A2 := Op^.Opd.C.Bits and $FFFF else A2 := FCtx.Accu[2] and $FFFF;
            A1 := FCtx.Accu[1] and $FFFF;
            case Op^.Code of
              opAW: R := A1 and A2;
              opOW: R := A1 or A2;
            else
              R := A1 xor A2;
            end;
            FCtx.Accu[1] := (FCtx.Accu[1] and $FFFF0000) or R;
            FCtx.CC1 := R <> 0;
            FCtx.CC0 := False;
            FCtx.OV := False;
          end;
        opAD, opOD, opXOD:
          begin
            if Op^.Opd.Kind = okConst then A2 := Op^.Opd.C.Bits else A2 := FCtx.Accu[2];
            A1 := FCtx.Accu[1];
            case Op^.Code of
              opAD: R := A1 and A2;
              opOD: R := A1 or A2;
            else
              R := A1 xor A2;
            end;
            FCtx.Accu[1] := R;
            FCtx.CC1 := R <> 0;
            FCtx.CC0 := False;
            FCtx.OV := False;
          end;
        // ---------- shift / rotate ----------
        opSLW, opSRW, opSSI:
          begin
            Cnt := ShiftCount;
            if Cnt > 0 then
            begin
              A1 := FCtx.Accu[1] and $FFFF;
              case Op^.Code of
                opSLW:
                  begin
                    if Cnt <= 16 then FCtx.CC1 := (A1 shr (16 - Cnt)) and 1 <> 0 else FCtx.CC1 := False;
                    if Cnt >= 16 then R := 0 else R := (A1 shl Cnt) and $FFFF;
                  end;
                opSRW:
                  begin
                    if Cnt <= 16 then FCtx.CC1 := (A1 shr (Cnt - 1)) and 1 <> 0 else FCtx.CC1 := False;
                    if Cnt >= 16 then R := 0 else R := A1 shr Cnt;
                  end;
              else
                begin
                  I1 := SmallInt(A1);
                  if Cnt > 15 then Cnt := 16;
                  FCtx.CC1 := (I1 shr (Cnt - 1)) and 1 <> 0;
                  R := LongWord(SarInt64(I1, Cnt)) and $FFFF;
                end;
              end;
              FCtx.Accu[1] := (FCtx.Accu[1] and $FFFF0000) or R;
              FCtx.CC0 := False;
              FCtx.OV := False;
            end;
          end;
        opSLD, opSRD, opSSD, opRLD, opRRD:
          begin
            Cnt := ShiftCount;
            if Cnt > 0 then
            begin
              A1 := FCtx.Accu[1];
              case Op^.Code of
                opSLD:
                  begin
                    if Cnt <= 32 then FCtx.CC1 := (A1 shr (32 - Cnt)) and 1 <> 0 else FCtx.CC1 := False;
                    if Cnt >= 32 then R := 0 else R := A1 shl Cnt;
                  end;
                opSRD:
                  begin
                    if Cnt <= 32 then FCtx.CC1 := (A1 shr (Cnt - 1)) and 1 <> 0 else FCtx.CC1 := False;
                    if Cnt >= 32 then R := 0 else R := A1 shr Cnt;
                  end;
                opSSD:
                  begin
                    if Cnt > 31 then Cnt := 32;
                    I1 := LongInt(A1);
                    FCtx.CC1 := (I1 shr (Cnt - 1)) and 1 <> 0;
                    R := LongWord(SarInt64(I1, Cnt));
                  end;
                opRLD:
                  begin
                    Cnt := Cnt mod 32;
                    R := RolDWord(A1, Cnt);
                    FCtx.CC1 := R and 1 <> 0;
                  end;
              else
                begin
                  Cnt := Cnt mod 32;
                  R := RorDWord(A1, Cnt);
                  FCtx.CC1 := R and $80000000 <> 0;
                end;
              end;
              FCtx.Accu[1] := R;
              FCtx.CC0 := False;
              FCtx.OV := False;
            end;
          end;
        // ---------- jumps ----------
        opJU: Jump;
        opJC:
          begin
            if Eff then Jump;
            AfterCondJump;
          end;
        opJCN:
          begin
            if not Eff then Jump;
            AfterCondJump;
          end;
        opJCB, opJNB:
          begin
            V := Eff;
            FCtx.BR := V;
            if V = (Op^.Code = opJCB) then Jump;
            AfterCondJump;
          end;
        opJBI: begin if FCtx.BR then Jump; FCtx.FC := False; end;
        opJNBI: begin if not FCtx.BR then Jump; FCtx.FC := False; end;
        opJO: if FCtx.OV then Jump;
        opJOS:
          if FCtx.OS then
          begin
            FCtx.OS := False;
            Jump;
          end;
        opJZ: if not FCtx.CC1 and not FCtx.CC0 then Jump;
        opJN: if FCtx.CC1 <> FCtx.CC0 then Jump;
        opJP: if FCtx.CC1 and not FCtx.CC0 then Jump;
        opJM: if not FCtx.CC1 and FCtx.CC0 then Jump;
        opJPZ: if not FCtx.CC0 then Jump;
        opJMZ: if not FCtx.CC1 then Jump;
        opJUO: if FCtx.CC1 and FCtx.CC0 then Jump;
        opLOOP:
          begin
            A1 := (FCtx.Accu[1] - 1) and $FFFF;
            FCtx.Accu[1] := (FCtx.Accu[1] and $FFFF0000) or A1;
            if A1 <> 0 then Jump;
          end;
        // ---------- blocks ----------
        opBE, opBEU:
          begin
            FCtx.FC := False;
            FCtx.ORb := False;
            FCtx.STA := True;
            Break;
          end;
        opBEC:
          begin
            if Eff then
            begin
              FCtx.FC := False;
              FCtx.ORb := False;
              Break;
            end;
            AfterCondJump;
          end;
        opCALL: CallBlock(Op^.Ext);
        opCallIf:
          if not Eff then
          begin
            // a LAD CALL box with EN = 0: no parameters, no call, ENO = 0
            FCtx.RLO := False;
            FCtx.FC := True;
            FCtx.ORb := False;
            Pc := Op^.Ext - 1;
          end;
        opCallEnd:
          begin
            FCtx.RLO := True;     // ENO = EN
            FCtx.FC := True;
            FCtx.ORb := False;
          end;
        opCALLFB:
          if Op^.Sub = 1 then
          begin
            // LAD box / CC: on the RLO
            V := Eff;
            if V then CallFB;
            FCtx.RLO := V;
            FCtx.FC := True;
            FCtx.ORb := False;
          end
          else
            CallFB;
        opCC:
          begin
            V := Eff;
            if V then CallBlock(Op^.Ext);
            FCtx.RLO := V;    // ENO = EN
            FCtx.FC := True;
            FCtx.ORb := False;
          end;
        opOPN:
          begin
            K := Op^.Opd.Block;
            if (K <= 0) or (K > High(DBs)) or not DBs[K].Present then
              raise EPlcError.Create(Format('OPN: DB%d not loaded', [K]));
            FCtx.DBReg := K;
          end;
        opOPNDI:
          begin
            K := Op^.Opd.Block;
            if (K <= 0) or (K > High(DBs)) or not DBs[K].Present then
              raise EPlcError.Create(Format('OPN DI: DB%d not loaded', [K]));
            FCtx.DIReg := K;
          end;
        // ---------- LAD ----------
        // ---------- SCL ----------
        opSPush: SPush(SclRead(Op^.Opd, Op^.DType));
        opSPushK: SPush(Op^.K);
        opSPushIdx:
          begin
            D1 := SPop;
            SPush(SclRead(SclIdx(Op^, Round(D1)), Op^.DType));
          end;
        opSStore:
          begin
            FSclLast := SPop;
            SclWrite(Op^.Opd, Op^.DType, FSclLast);
          end;
        opSStoreIdx:
          begin
            FSclLast := SPop;
            D1 := SPop;
            SclWrite(SclIdx(Op^, Round(D1)), Op^.DType, FSclLast);
          end;
        opSBin:
          begin
            D1 := SPop;
            SPush(SclBin(Op^.Sub, Op^.DType, SPop, D1));
          end;
        opSUn: SPush(SclUn(Op^.Sub, Op^.DType, SPop));
        opSTern:
          begin
            S1 := 0;
            D1 := SPop;
            Now := SPop;
            SPush(SclTern(Op^.Sub, Op^.DType, SPop, Now, D1));
          end;
        opSJmp: Pc := Op^.Ext - 1;
        opSJz:
          begin
            FSclLast := SPop;
            if FSclLast = 0 then Pc := Op^.Ext - 1;
          end;
        opSPop: SPop;
        opSSetReg:
          begin
            FSclLast := SPop;
            FReg[Op^.Sub and 15] := FSclLast;
          end;
        opSGetReg: SPush(FReg[Op^.Sub and 15]);
        opSCopy:
          begin
            // a := b for a whole struct / array: Sub bytes from Params[Ext] to Opd;
            // Lo bit 1: the source has variable indexes, bit 0: the target (offsets on the stack)
            Opd2 := B.Params[Op^.Ext];
            if Op^.Lo and 2 <> 0 then Opd2 := SclIdx(Op^, Round(SPop), Opd2);
            if Op^.Lo and 1 <> 0 then CpDst := SclIdx(Op^, Round(SPop)) else CpDst := Op^.Opd;
            CpSrc := AreaPtr(Opd2.A, Op^.Sub, False);
            CpTo := AreaPtr(CpDst.A, Op^.Sub, True);
            if Op^.Sub > 0 then Move(CpSrc^, CpTo^, Op^.Sub);
            FSclLast := Op^.Sub;
          end;
        opSIndex:
          begin
            // index -> bit offset of the element; Ext = 1 adds it to the offset of an outer index
            I1 := Round(SPop);
            if (I1 < Op^.Lo) or (I1 > Op^.Hi) then
              raise EPlcError.Create(Format('Array index %d outside [%d..%d] (%s)', [I1, Op^.Lo, Op^.Hi, Op^.Opd.Text]));
            D1 := Double(I1 - Op^.Lo) * Op^.Sub;
            if Op^.Ext = 1 then D1 := D1 + SPop;
            SPush(D1);
          end;
        opSTimer:
          begin
            D1 := SPop;                 // R
            Now := SPop;                // PT
            V := SPop <> 0;             // IN
            if Op^.Ext = 1 then         // an instance in an array: "DB".M[#i].T
              V := IecTimer(TOpCode(Op^.Sub), SclIdx(Op^, Round(FReg[8])).A, V, Round(Now), D1 <> 0, ET)
            else
            V := IecTimer(TOpCode(Op^.Sub), Op^.Opd.A, V, Round(Now), D1 <> 0, ET);
            FSclLast := Ord(V);
          end;
        opSCounter:
          begin
            I2 := Round(SPop);          // PV
            E := SPop <> 0;             // LD
            Done := SPop <> 0;          // R
            V2 := SPop <> 0;            // CD
            V := SPop <> 0;             // CU
            if Op^.Ext = 1 then
              V := IecCounter(TOpCode(Op^.Sub), SclIdx(Op^, Round(FReg[8])).A, V, V2, Done, E, I2, I1)
            else
              V := IecCounter(TOpCode(Op^.Sub), Op^.Opd.A, V, V2, Done, E, I2, I1);
            FSclLast := Ord(V);
          end;
        opNetBegin:
          begin
            FNestN := 0;
            FSp := 0;
            FCtx.FC := False;
            FCtx.ORb := False;
            if (FDepth = 0) and not FInCyclic then CheckCyclic;
          end;
        opLadBegin:
          for K := 0 to MaxLadRows - 1 do
          begin
            FPin[K] := True;
            FPout[K] := False;
          end;
        opLadLoad:
          begin
            FCtx.RLO := FPin[Op^.Sub];
            FCtx.FC := True;
            FCtx.ORb := False;
          end;
        opLadStore: FPout[Op^.Sub] := Eff;
        opLadCol:
          begin
            for K := 0 to MaxLadRows - 1 do
              if B.LadTables[Op^.Ext][K] < 0 then FPin[K] := FPout[K];
            for K := 0 to MaxLadRows - 1 do
              if B.LadTables[Op^.Ext][K] >= 0 then
              begin
                V := False;
                for Cnt := 0 to MaxLadRows - 1 do
                  if B.LadTables[Op^.Ext][Cnt] = B.LadTables[Op^.Ext][K] then V := V or FPout[Cnt];
                FPin[K] := V;
              end;
            for K := 0 to MaxLadRows - 1 do FPout[K] := False;
          end;
        opPContact, opNContact:
          begin
            E := Eff;
            V := ReadBitA(Op^.Opd.A);
            Opd2 := B.Params[Op^.Ext];
            V2 := ReadBitA(Opd2.A);
            WriteBitA(Opd2.A, V);
            if Op^.Code = opPContact then V := V and not V2 else V := not V and V2;
            FCtx.STA := V;
            FCtx.RLO := E and V;
            FCtx.ORb := False;
            FCtx.FC := True;
          end;
        opTON, opTOF, opTP, opTONR:
          begin
            E := Eff;
            PT := ReadInt(Par(0), dtTime);
            V := IecTimer(Op^.Code, Op^.Opd.A, E, PT, (Op^.Code = opTONR) and ReadOpdBit(Par(1)), ET);
            if Op^.Code = opTONR then K := 2 else K := 1;
            if Par(K).Kind = okAddr then WriteRaw(Par(K).A, LongWord(LongInt(ET)));
            FCtx.RLO := V;
            FCtx.ORb := False;
            FCtx.FC := True;
          end;
        opCTU, opCTD, opCTUD:
          begin
            E := Eff;
            I2 := ReadInt(Par(0), dtInt);
            case Op^.Code of
              opCTU: V := IecCounter(opCTU, Op^.Opd.A, E, False, ReadOpdBit(Par(1)), False, I2, I1);
              opCTD: V := IecCounter(opCTD, Op^.Opd.A, False, E, False, ReadOpdBit(Par(1)), I2, I1);
            else
              V := IecCounter(opCTUD, Op^.Opd.A, E, ReadOpdBit(Par(1)), ReadOpdBit(Par(2)), ReadOpdBit(Par(3)), I2, I1);
            end;
            if Op^.Code = opCTUD then K := 4 else K := 2;
            if Par(K).Kind = okAddr then WriteRaw(Par(K).A, LongWord(I1) and $FFFF);
            FCtx.RLO := V;
            FCtx.ORb := False;
            FCtx.FC := True;
          end;
        opBoxCmp:
          begin
            E := Eff;
            V := False;
            if E then
              V := CmpNum(Op^.Sub, ReadReal(Par(0), Op^.DType), ReadReal(Par(1), Op^.DType));
            FCtx.RLO := E and V;
            FCtx.ORb := False;
            FCtx.FC := True;
          end;
        opBoxMove:
          begin
            E := Eff;
            if E then
            begin
              R := ReadOpdRaw(Par(0));
              if (Par(0).Kind = okConst) and (Op^.DType = dtReal) and (Par(0).C.Kind <> ckReal) then
              begin
                S1 := ReadReal(Par(0), dtDInt);
                R := SgBits(S1);
              end;
              WriteRaw(Par(1).A, R);
            end;
            FCtx.RLO := E;
            FCtx.ORb := False;
            FCtx.FC := True;
          end;
        opBoxMath:
          begin
            E := Eff;
            Ok := True;
            if E then
            begin
              if Op^.DType = dtReal then
              begin
                S1 := ReadReal(Par(0), dtReal);
                S2 := ReadReal(Par(1), dtReal);
                case Op^.Sub of
                  0: SR := S1 + S2;
                  1: SR := S1 - S2;
                  2: SR := S1 * S2;
                else
                  if S2 = 0 then
                  begin
                    SR := 0;
                    Ok := False;
                  end
                  else
                    SR := S1 / S2;
                end;
                if IsNan(SR) or IsInfinite(SR) then Ok := False;
                WriteReal(Par(2), SR);
              end
              else
              begin
                I1 := ReadInt(Par(0), Op^.DType);
                I2 := ReadInt(Par(1), Op^.DType);
                case Op^.Sub of
                  0: IR := I1 + I2;
                  1: IR := I1 - I2;
                  2: IR := I1 * I2;
                else
                  if I2 = 0 then
                  begin
                    IR := 0;
                    Ok := False;
                  end
                  else
                    IR := I1 div I2;
                end;
                if Op^.DType = dtInt then Ok := Ok and (IR >= -32768) and (IR <= 32767)
                else if Op^.DType = dtDInt then Ok := Ok and (IR >= -2147483648) and (IR <= 2147483647);
                WriteInt(Par(2), Op^.DType, IR);
              end;
            end;
            FCtx.RLO := E and Ok;
            FCtx.ORb := False;
            FCtx.FC := True;
          end;
        opBoxRange:
          begin
            // IN_RANGE: MIN <= VAL <= MAX; OUT_RANGE: VAL < MIN or VAL > MAX
            E := Eff;
            V := False;
            if E then
            begin
              D1 := ReadReal(Par(1), Op^.DType);
              V := (D1 >= ReadReal(Par(0), Op^.DType)) and (D1 <= ReadReal(Par(2), Op^.DType));
              if Op^.Sub = 1 then V := not V;
            end;
            FCtx.RLO := E and V;
            FCtx.ORb := False;
            FCtx.FC := True;
          end;
        opBoxConv:
          begin
            // CONV (any number to any), ROUND (to the nearest, a half to the even), TRUNC, CEIL, FLOOR;
            // a value OUT cannot hold: ENO = 0, OUT unchanged
            E := Eff;
            Ok := True;
            if E then
            begin
              T2 := TDataType(Op^.Sub and $FF);
              if Op^.DType = dtReal then
              begin
                D1 := ReadReal(Par(0), dtReal);
                if T2 = dtReal then WriteReal(Par(1), D1)
                else if IsNan(D1) or IsInfinite(D1) or (Abs(D1) > 4.3E9) then Ok := False
                else
                begin
                  case Op^.Sub shr 8 of
                    2: IR := Trunc(D1);
                    3: IR := Ceil(D1);
                    4: IR := Floor(D1);
                  else
                    IR := Round(D1);
                  end;
                  Ok := InTypeRange(T2, IR);
                  if Ok then WriteInt(Par(1), T2, IR);
                end;
              end
              else
              begin
                IR := ReadInt(Par(0), Op^.DType);
                if T2 = dtReal then WriteReal(Par(1), IR)
                else
                begin
                  Ok := InTypeRange(T2, IR);
                  if Ok then WriteInt(Par(1), T2, IR);
                end;
              end;
            end;
            FCtx.RLO := E and Ok;
            FCtx.ORb := False;
            FCtx.FC := True;
          end;
        opNormX, opScaleX:
          begin
            E := Eff;
            Ok := True;
            if E then
            begin
              if Op^.Code = opNormX then
              begin
                D1 := ReadReal(Par(2), Op^.DType) - ReadReal(Par(0), Op^.DType);
                if D1 = 0 then Ok := False
                else WriteReal(Par(3), (ReadReal(Par(1), Op^.DType) - ReadReal(Par(0), Op^.DType)) / D1);
              end
              else
              begin
                D1 := ReadReal(Par(1), dtReal) * (ReadReal(Par(2), Op^.DType) - ReadReal(Par(0), Op^.DType)) +
                  ReadReal(Par(0), Op^.DType);
                if Op^.DType = dtReal then WriteReal(Par(3), D1)
                else
                begin
                  if IsNan(D1) or (Abs(D1) > 2147483647) then
                  begin
                    Ok := False;
                    D1 := 0;
                  end;
                  IR := Round(D1);
                  if (Op^.DType = dtInt) and ((IR < -32768) or (IR > 32767)) then Ok := False;
                  WriteInt(Par(3), Op^.DType, IR);
                end;
              end;
            end;
            FCtx.RLO := E and Ok;
            FCtx.ORb := False;
            FCtx.FC := True;
          end;
      end;
    except
      on Ex: EPlcError do
      begin
        if not StopOnProgError(Model.Family) then
        begin
          // S7-1200: no STOP, the error is logged, ERROR flashes, the next instruction runs
          ProgError(Ex.Message);
          ErrorUntilMs := PlcNowMs + 3000;
        end
        else
        begin
          if FErrWhere = '' then FErrWhere := WhereStr;
          raise;
        end;
      end;
    end;
    if Mon and (Op^.Mon >= 0) then
    begin
      if Op^.Code = opLadLoad then MonRecord(B, Op^.Mon, FPin[Op^.Sub])
      else if Op^.Code = opLadStore then MonRecord(B, Op^.Mon, FPout[Op^.Sub])
      else if Op^.Code in [opSStore, opSStoreIdx, opSJz, opSTimer, opSCounter, opSSetReg, opSCopy] then
      begin
        MonRecord(B, Op^.Mon, FSclLast <> 0);
        if Op^.Mon <= High(B.Mon) then B.Mon[Op^.Mon].Val := FSclLast;
        if Op^.Mon > High(B.Mon) then
        else
        if Op^.Code in [opSJz, opSTimer, opSCounter] then B.Mon[Op^.Mon].DT := dtBool
        else if Op^.Code = opSCopy then B.Mon[Op^.Mon].DT := dtStruct     // Val = bytes copied
        else B.Mon[Op^.Mon].DT := Op^.DType;
      end
      else MonRecord(B, Op^.Mon, Eff);
    end;
    Inc(Pc);
  end;
  if Bits = 0 then ;
end;

procedure TPlcRuntime.RunCycle;
var
  T0, T1: Double;
  Us: Double;
  C: TTimeCat;
begin
  FErrThisCycle := 0;
  FErrWhere := '';
  FillChar(FCatCount, SizeOf(FCatCount), 0);
  FOpsCount := 0;
  T0 := PlcNowMs;
  FCycleStartMs := T0;
  ReadInputs;
  UpdateClock(T0);
  try
    RunOB(Prog.OB1);
    CheckCyclic;
  except
    on E: Exception do
    begin
      SysFault := True;
      if FErrWhere = '' then FErrWhere := WhereStr;
      DiagAdd(dkError, E.Message + FErrWhere);
      if E is EPlcFatal then
        GoStop(E.Message)
      else if not StopOnProgError(Model.Family) then
        GoStop(E.Message)
      else
        GoStop('programming error, OB121 not loaded');
    end;
  end;
  WriteOutputs;
  T1 := PlcNowMs;
  Inc(CycleNo);
  OpsLastCycle := FOpsCount;
  HostUs := (T1 - T0) * 1000;
  // what the real CPU would need: operating system + process images + instructions
  Us := Model.OsUs + (Model.InBytes + Model.OutBytes) * 0.0;
  for C := Low(TTimeCat) to High(TTimeCat) do
    case C of
      tcBit: Us := Us + FCatCount[C] * Model.BitNs / 1000;
      tcWord: Us := Us + FCatCount[C] * Model.WordNs / 1000;
      tcFix: Us := Us + FCatCount[C] * Model.FixNs / 1000;
      tcFloat: Us := Us + FCatCount[C] * Model.FloatNs / 1000;
    end;
  ModelUs := Us;
  if HostUs < HostMinUs then HostMinUs := HostUs;
  if HostUs > HostMaxUs then HostMaxUs := HostUs;
  if ModelUs < ModelMinUs then ModelMinUs := ModelUs;
  if ModelUs > ModelMaxUs then ModelMaxUs := ModelUs;
  if HostAvgUs = 0 then HostAvgUs := HostUs else HostAvgUs := HostAvgUs * 0.99 + HostUs * 0.01;
  if ModelAvgUs = 0 then ModelAvgUs := ModelUs else ModelAvgUs := ModelAvgUs * 0.99 + ModelUs * 0.01;
  HostHist[HistPos] := HostUs;
  ModelHist[HistPos] := ModelUs;
  HistPos := (HistPos + 1) mod HistCycles;
end;

{ waits Ms milliseconds: a high resolution timer when there is one (about
  0.5 ms exact), else Sleep (about 1 - 2 ms with timeBeginPeriod(1)) }
procedure TPlcRuntime.PreciseWait(Ms: Double);
var
  Due: Int64;
  T0: Double;
begin
  if Ms <= 0 then Exit;
  {$IFDEF WINDOWS}
  if FTimer <> 0 then
  begin
    T0 := PlcNowMs;
    Due := -Round(Ms * 10000);   // relative, 100 ns units
    if SetWaitableTimer(FTimer, Due, 0, nil, nil, False) then
    begin
      WaitForSingleObject(FTimer, 100);
      Exit;
    end;
    if T0 = 0 then ;
  end;
  {$ENDIF}
  Sleep(Max(1, Round(Ms)));
end;

procedure TPlcRuntime.ThreadLoop;
var
  T, Wait, Target: Double;
begin
  {$IFDEF WINDOWS}
  FTimer := CreateWaitableTimerExW(nil, nil, CREATE_WAITABLE_TIMER_HIGH_RESOLUTION, TIMER_ALL_ACCESS);
  {$ENDIF}
  FLastCycleEnd := PlcNowMs;
  FCpsT0 := FLastCycleEnd;
  while not FThread.Terminated do
  begin
    ProcessCommands;
    if Mode = rmMres then
    begin
      if PlcNowMs >= FMresUntil then
      begin
        // memory reset: everything back to the start values, the program stays
        FillChar(M[0], Length(M), 0);
        FillChar(Q[0], Length(Q), 0);
        FillChar(I[0], Length(I), 0);
        if Length(Timers) > 0 then FillChar(Timers[0], SizeOf(TS5Timer) * Length(Timers), 0);
        if Length(Counters) > 0 then FillChar(Counters[0], SizeOf(TS5Counter) * Length(Counters), 0);
        LoadDBs(True);
        Mode := rmStop;
        SysFault := False;
        StopCause := 'memory reset';
        DiagAdd(dkMode, 'Memory reset (MRES) done - STOP');
      end;
      WriteOutputs;
      Sleep(5);
      Continue;
    end;
    if (Mode = rmRun) and (Prog <> nil) and (Prog.OB1 >= 0) then
    begin
      RunCycle;
      T := PlcNowMs;
      if FLastStartMs > 0 then PeriodMs := FCycleStartMs - FLastStartMs;
      FLastStartMs := FCycleStartMs;
      // pacing
      case Pacing of
        pcMin1ms:
          begin
            // one cycle per millisecond
            // the timer wakes up to 0.5 ms late: sleep most of it, spin the rest
            Target := FCycleStartMs + 1;
            Wait := Target - T;
            if (FTimer <> 0) and (Wait > 0.5) then PreciseWait(Wait - 0.42)
            else if (FTimer = 0) and (Wait > 0.05) then Sleep(1);
            while PlcNowMs < Target do ;
          end;
        pcModel:
          begin
            // as long as the real CPU would need: sleep most of it, spin the rest
            Target := FCycleStartMs + ModelUs / 1000;
            if (FTimer <> 0) and (Target - PlcNowMs > 0.6) then PreciseWait(Target - PlcNowMs - 0.4)
            else if (FTimer = 0) and (Target - PlcNowMs > 2.5) then Sleep(1);
            while PlcNowMs < Target do ;
          end;
      else
        if CycleNo and 255 = 0 then Sleep(0);
      end;
      FLastCycleEnd := PlcNowMs;
      Inc(FCpsN);
      if FLastCycleEnd - FCpsT0 >= 500 then
      begin
        CyclesPerSec := FCpsN * 1000 / (FLastCycleEnd - FCpsT0);
        FCpsN := 0;
        FCpsT0 := FLastCycleEnd;
      end;
    end
    else
    begin
      if Mode = rmRun then GoStop('no OB1');
      ReadInputs;
      UpdateClock(PlcNowMs);
      WriteOutputs;
      CyclesPerSec := 0;
      Sleep(2);
    end;
  end;
  {$IFDEF WINDOWS}
  if FTimer <> 0 then CloseHandle(FTimer);
  FTimer := 0;
  {$ENDIF}
end;

end.
