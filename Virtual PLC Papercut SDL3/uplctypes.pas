unit uPlcTypes;

{ Virtual PLC - basic S7 types shared by the project, the compiler and the runtime.

  CPU families and models (memory sizes, I/O areas, limits, instruction times),
  operand areas, absolute addresses in S7 syntax and constants.

  Address syntax (case and spaces do not matter, a leading % is allowed):
    I0.0  Q4.7  M10.1  L0.0          bits
    IB0   QB4   MB10   LB0           bytes
    IW64  QW2   MW20   LW0           words (big-endian: MB20 is the high byte)
    ID0   QD4   MD100  LD0           double words
    PIW256 PQW256  or  IW64:P QW96:P peripheral (immediate) access
    DB1.DBX0.0 DB1.DBB0 DB1.DBW2 DB1.DBD4   fully qualified DB access
    DBX0.0 DBW2 ...                  through the open DB register (OPN DB n)
    DIX0.0 DIW2 ...                  through the instance DB register (OPN DI n)
    T5  C3                           S5 timers and counters (S7-300/400 only)
  Constants:
    123  -5        INT (16 bit)          L#100000    DINT (32 bit)
    16#FF W#16#1A2B DW#16#12345678 B#16#0F   hex     2#1010_0101  binary
    1.5  -2.0E3    REAL                  TRUE FALSE  BOOL
    S5T#2S  S5T#1M30S                    S5TIME (BCD with time base)
    T#5S  T#1H2M  T#500MS  TIME#3s       TIME (32 bit ms)
    C#10                                 counter value (BCD)
    'A'                                  CHAR }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math;

type
  TCpuFamily = (cfS7300, cfS7400, cfS71200, cfS71500);
  TArea = (arNone, arI, arQ, arM, arDB, arDI, arL, arT, arC, arPI, arPQ);
  TOpSize = (osBit, osByte, osWord, osDWord);
  TDataType = (dtNone, dtBool, dtByte, dtWord, dtDWord, dtChar, dtSInt, dtUSInt, dtInt, dtUInt,
    dtDInt, dtUDInt, dtReal, dtTime, dtS5Time, dtDate, dtTOD, dtIECTimer, dtIECCounter,
    dtStruct);   // a PLC data type (UDT) of the project: size and members in uPlcProject
  TAreaSet = set of TArea;

  TAddr = record
    Area: TArea;
    Size: TOpSize;
    DB: Integer;      // DB number of a fully qualified access, 0 = the open DB register
    Ofs: Integer;     // byte offset
    Bit: Integer;     // 0..7 for bit access
    Num: Integer;     // timer / counter number
    Periph: Boolean;  // written as :P (S7-1200) or PIW / PQW
  end;

  TConstKind = (ckNone, ckInt, ckDInt, ckHex, ckReal, ckBool, ckS5Time, ckTime, ckCounter, ckChar);

  TConst = record
    Kind: TConstKind;
    Bits: LongWord;   // the 32 bit pattern as loaded into ACCU1
    I: Int64;         // integer value (ms for TIME, count for C#)
    R: Double;
    Size: TOpSize;    // osWord for INT / S5TIME / C# / W#16#, osDWord for DINT / REAL / TIME
  end;

  TCpuModel = record
    Family: TCpuFamily;
    Name: string;
    OrderNo: string;
    Firmware: string;
    WorkMem, LoadMem: Integer;   // bytes
    InBytes, OutBytes: Integer;  // I / Q address space (= process image here)
    MBytes: Integer;             // bit memory
    LBytes: Integer;             // local data per block call
    Timers, Counters: Integer;   // S5 timers / counters (0 on the S7-1200)
    MaxDB: Integer;              // highest DB number
    MaxDBSize: Integer;          // bytes per DB
    Accus: Integer;              // 2 (S7-300) or 4 (S7-400)
    BitNs, WordNs, FixNs, FloatNs: Single;  // instruction times
    OsUs: Single;                // operating system time per cycle (us)
    CyclicOB: Integer;           // 35 (S7-300/400) or 30 (S7-1200)
    WatchdogMs: Integer;         // maximum cycle time
    ForceAreas: TAreaSet;
    { on-board / default I/O }
    DI, DQ, AI, AQ: Integer;           // channels
    DIByte, DQByte, AIWord, AQWord: Integer;  // first address
  end;

const
  FamilyNames: array[TCpuFamily] of string = ('S7-300', 'S7-400', 'S7-1200', 'S7-1500');
  AreaNames: array[TArea] of string = ('', 'I', 'Q', 'M', 'DB', 'DI', 'L', 'T', 'C', 'PI', 'PQ');
  DataTypeNames: array[TDataType] of string = ('', 'Bool', 'Byte', 'Word', 'DWord', 'Char', 'SInt',
    'USInt', 'Int', 'UInt', 'DInt', 'UDInt', 'Real', 'Time', 'S5Time', 'Date', 'Time_Of_Day',
    'IEC_TIMER', 'IEC_COUNTER', 'Struct');

  ModelCount = 15;
  Models: array[0..ModelCount - 1] of TCpuModel = (
    (Family: cfS7300; Name: 'CPU 314'; OrderNo: '6ES7 314-1AG14-0AB0'; Firmware: 'V3.3';
     WorkMem: 128 * 1024; LoadMem: 8 * 1024 * 1024; InBytes: 1024; OutBytes: 1024; MBytes: 256;
     LBytes: 1024; Timers: 256; Counters: 256; MaxDB: 511; MaxDBSize: 16384; Accus: 2;
     BitNs: 60; WordNs: 120; FixNs: 160; FloatNs: 590; OsUs: 260; CyclicOB: 35; WatchdogMs: 150;
     ForceAreas: [arI, arQ, arPI, arPQ];
     DI: 32; DQ: 32; AI: 8; AQ: 4; DIByte: 0; DQByte: 4; AIWord: 288; AQWord: 304),
    (Family: cfS7300; Name: 'CPU 315-2 PN/DP'; OrderNo: '6ES7 315-2EH14-0AB0'; Firmware: 'V3.2';
     WorkMem: 384 * 1024; LoadMem: 8 * 1024 * 1024; InBytes: 2048; OutBytes: 2048; MBytes: 2048;
     LBytes: 1024; Timers: 256; Counters: 256; MaxDB: 1023; MaxDBSize: 16384; Accus: 2;
     BitNs: 50; WordNs: 90; FixNs: 120; FloatNs: 450; OsUs: 200; CyclicOB: 35; WatchdogMs: 150;
     ForceAreas: [arI, arQ, arPI, arPQ];
     DI: 32; DQ: 32; AI: 8; AQ: 4; DIByte: 0; DQByte: 4; AIWord: 288; AQWord: 304),
    (Family: cfS7300; Name: 'CPU 317-2 PN/DP'; OrderNo: '6ES7 317-2EK14-0AB0'; Firmware: 'V3.2';
     WorkMem: 1024 * 1024; LoadMem: 8 * 1024 * 1024; InBytes: 8192; OutBytes: 8192; MBytes: 4096;
     LBytes: 1024; Timers: 512; Counters: 512; MaxDB: 2047; MaxDBSize: 65536; Accus: 2;
     BitNs: 25; WordNs: 30; FixNs: 40; FloatNs: 160; OsUs: 120; CyclicOB: 35; WatchdogMs: 150;
     ForceAreas: [arI, arQ, arPI, arPQ];
     DI: 32; DQ: 32; AI: 8; AQ: 4; DIByte: 0; DQByte: 4; AIWord: 288; AQWord: 304),
    (Family: cfS7400; Name: 'CPU 412-2 PN'; OrderNo: '6ES7 412-2EK06-0AB0'; Firmware: 'V6.0';
     WorkMem: 1024 * 1024; LoadMem: 16 * 1024 * 1024; InBytes: 4096; OutBytes: 4096; MBytes: 4096;
     LBytes: 8192; Timers: 2048; Counters: 2048; MaxDB: 3000; MaxDBSize: 65534; Accus: 4;
     BitNs: 31; WordNs: 31; FixNs: 31; FloatNs: 62; OsUs: 100; CyclicOB: 35; WatchdogMs: 150;
     ForceAreas: [arI, arQ, arM, arPI, arPQ];
     DI: 32; DQ: 32; AI: 8; AQ: 8; DIByte: 0; DQByte: 4; AIWord: 512; AQWord: 512),
    (Family: cfS7400; Name: 'CPU 414-3 PN/DP'; OrderNo: '6ES7 414-3EM07-0AB0'; Firmware: 'V6.0';
     WorkMem: 4 * 1024 * 1024; LoadMem: 16 * 1024 * 1024; InBytes: 8192; OutBytes: 8192; MBytes: 8192;
     LBytes: 16384; Timers: 2048; Counters: 2048; MaxDB: 6000; MaxDBSize: 65534; Accus: 4;
     BitNs: 18; WordNs: 18; FixNs: 18; FloatNs: 36; OsUs: 80; CyclicOB: 35; WatchdogMs: 150;
     ForceAreas: [arI, arQ, arM, arPI, arPQ];
     DI: 32; DQ: 32; AI: 8; AQ: 8; DIByte: 0; DQByte: 4; AIWord: 512; AQWord: 512),
    (Family: cfS7400; Name: 'CPU 416-3 PN/DP'; OrderNo: '6ES7 416-3FS07-0AB0'; Firmware: 'V6.0';
     WorkMem: 16 * 1024 * 1024; LoadMem: 64 * 1024 * 1024; InBytes: 16384; OutBytes: 16384; MBytes: 16384;
     LBytes: 32768; Timers: 2048; Counters: 2048; MaxDB: 10000; MaxDBSize: 65534; Accus: 4;
     BitNs: 12.5; WordNs: 12.5; FixNs: 12.5; FloatNs: 25; OsUs: 60; CyclicOB: 35; WatchdogMs: 150;
     ForceAreas: [arI, arQ, arM, arPI, arPQ];
     DI: 32; DQ: 32; AI: 8; AQ: 8; DIByte: 0; DQByte: 4; AIWord: 512; AQWord: 512),
    (Family: cfS71200; Name: 'CPU 1211C DC/DC/DC'; OrderNo: '6ES7 211-1AE40-0XB0'; Firmware: 'V4.6';
     WorkMem: 50 * 1024; LoadMem: 1024 * 1024; InBytes: 1024; OutBytes: 1024; MBytes: 4096;
     LBytes: 16384; Timers: 0; Counters: 0; MaxDB: 59999; MaxDBSize: 65535; Accus: 2;
     BitNs: 85; WordNs: 1700; FixNs: 1700; FloatNs: 2300; OsUs: 300; CyclicOB: 30; WatchdogMs: 150;
     ForceAreas: [arPI, arPQ];
     DI: 6; DQ: 4; AI: 2; AQ: 0; DIByte: 0; DQByte: 0; AIWord: 64; AQWord: 80),
    (Family: cfS71200; Name: 'CPU 1214C DC/DC/DC'; OrderNo: '6ES7 214-1AG40-0XB0'; Firmware: 'V4.6';
     WorkMem: 100 * 1024; LoadMem: 4 * 1024 * 1024; InBytes: 1024; OutBytes: 1024; MBytes: 8192;
     LBytes: 16384; Timers: 0; Counters: 0; MaxDB: 59999; MaxDBSize: 65535; Accus: 2;
     BitNs: 85; WordNs: 1700; FixNs: 1700; FloatNs: 2300; OsUs: 300; CyclicOB: 30; WatchdogMs: 150;
     ForceAreas: [arPI, arPQ];
     DI: 14; DQ: 10; AI: 2; AQ: 0; DIByte: 0; DQByte: 0; AIWord: 64; AQWord: 80),
    (Family: cfS71200; Name: 'CPU 1215C DC/DC/DC'; OrderNo: '6ES7 215-1AG40-0XB0'; Firmware: 'V4.6';
     WorkMem: 125 * 1024; LoadMem: 4 * 1024 * 1024; InBytes: 1024; OutBytes: 1024; MBytes: 8192;
     LBytes: 16384; Timers: 0; Counters: 0; MaxDB: 59999; MaxDBSize: 65535; Accus: 2;
     BitNs: 85; WordNs: 1700; FixNs: 1700; FloatNs: 2300; OsUs: 300; CyclicOB: 30; WatchdogMs: 150;
     ForceAreas: [arPI, arPQ];
     DI: 14; DQ: 10; AI: 2; AQ: 2; DIByte: 0; DQByte: 0; AIWord: 64; AQWord: 64),
    (Family: cfS71200; Name: 'CPU 1217C DC/DC/DC'; OrderNo: '6ES7 217-1AG40-0XB0'; Firmware: 'V4.6';
     WorkMem: 150 * 1024; LoadMem: 4 * 1024 * 1024; InBytes: 1024; OutBytes: 1024; MBytes: 8192;
     LBytes: 16384; Timers: 0; Counters: 0; MaxDB: 59999; MaxDBSize: 65535; Accus: 2;
     BitNs: 85; WordNs: 1700; FixNs: 1700; FloatNs: 2300; OsUs: 300; CyclicOB: 30; WatchdogMs: 150;
     ForceAreas: [arPI, arPQ];
     DI: 14; DQ: 10; AI: 2; AQ: 2; DIByte: 0; DQByte: 0; AIWord: 64; AQWord: 64),
    { S7-1500: work memory = code + data; DI 32 / DQ 32 modules at I0 / Q0, AI 8 at IW4, AQ 4 at QW4 }
    (Family: cfS71500; Name: 'CPU 1511-1 PN'; OrderNo: '6ES7 511-1AK02-0AB0'; Firmware: 'V2.9';
     WorkMem: (150 + 1024) * 1024; LoadMem: 32 * 1024 * 1024; InBytes: 32768; OutBytes: 32768; MBytes: 16384;
     LBytes: 65536; Timers: 2048; Counters: 2048; MaxDB: 60999; MaxDBSize: 16 * 1024 * 1024; Accus: 4;
     BitNs: 60; WordNs: 72; FixNs: 96; FloatNs: 384; OsUs: 100; CyclicOB: 30; WatchdogMs: 150;
     ForceAreas: [arPI, arPQ];
     DI: 32; DQ: 32; AI: 8; AQ: 4; DIByte: 0; DQByte: 0; AIWord: 4; AQWord: 4),
    (Family: cfS71500; Name: 'CPU 1513-1 PN'; OrderNo: '6ES7 513-1AL02-0AB0'; Firmware: 'V2.9';
     WorkMem: (300 + 1536) * 1024; LoadMem: 32 * 1024 * 1024; InBytes: 32768; OutBytes: 32768; MBytes: 16384;
     LBytes: 65536; Timers: 2048; Counters: 2048; MaxDB: 60999; MaxDBSize: 16 * 1024 * 1024; Accus: 4;
     BitNs: 40; WordNs: 48; FixNs: 64; FloatNs: 256; OsUs: 80; CyclicOB: 30; WatchdogMs: 150;
     ForceAreas: [arPI, arPQ];
     DI: 32; DQ: 32; AI: 8; AQ: 4; DIByte: 0; DQByte: 0; AIWord: 4; AQWord: 4),
    (Family: cfS71500; Name: 'CPU 1515-2 PN'; OrderNo: '6ES7 515-2AM02-0AB0'; Firmware: 'V2.9';
     WorkMem: (500 + 3072) * 1024; LoadMem: 32 * 1024 * 1024; InBytes: 32768; OutBytes: 32768; MBytes: 16384;
     LBytes: 65536; Timers: 2048; Counters: 2048; MaxDB: 60999; MaxDBSize: 16 * 1024 * 1024; Accus: 4;
     BitNs: 30; WordNs: 36; FixNs: 48; FloatNs: 192; OsUs: 60; CyclicOB: 30; WatchdogMs: 150;
     ForceAreas: [arPI, arPQ];
     DI: 32; DQ: 32; AI: 8; AQ: 4; DIByte: 0; DQByte: 0; AIWord: 4; AQWord: 4),
    (Family: cfS71500; Name: 'CPU 1516-3 PN/DP'; OrderNo: '6ES7 516-3AN02-0AB0'; Firmware: 'V2.9';
     WorkMem: (1024 + 5120) * 1024; LoadMem: 32 * 1024 * 1024; InBytes: 32768; OutBytes: 32768; MBytes: 16384;
     LBytes: 65536; Timers: 2048; Counters: 2048; MaxDB: 60999; MaxDBSize: 16 * 1024 * 1024; Accus: 4;
     BitNs: 10; WordNs: 12; FixNs: 16; FloatNs: 64; OsUs: 40; CyclicOB: 30; WatchdogMs: 150;
     ForceAreas: [arPI, arPQ];
     DI: 32; DQ: 32; AI: 8; AQ: 4; DIByte: 0; DQByte: 0; AIWord: 4; AQWord: 4),
    (Family: cfS71500; Name: 'CPU 1518-4 PN/DP'; OrderNo: '6ES7 518-4AP00-0AB0'; Firmware: 'V2.9';
     WorkMem: (4096 + 20480) * 1024; LoadMem: 32 * 1024 * 1024; InBytes: 32768; OutBytes: 32768; MBytes: 16384;
     LBytes: 65536; Timers: 2048; Counters: 2048; MaxDB: 60999; MaxDBSize: 16 * 1024 * 1024; Accus: 4;
     BitNs: 1; WordNs: 2; FixNs: 1; FloatNs: 6; OsUs: 20; CyclicOB: 30; WatchdogMs: 150;
     ForceAreas: [arPI, arPQ];
     DI: 32; DQ: 32; AI: 8; AQ: 4; DIByte: 0; DQByte: 0; AIWord: 4; AQWord: 4));

function NoAddr: TAddr;
function MakeAddr(AArea: TArea; ASize: TOpSize; AOfs: Integer; ABit: Integer = 0; ADB: Integer = 0): TAddr;
{ absolute address; Err is empty on success }
function ParseAddr(const S: string; out A: TAddr; out Err: string): Boolean;
function FormatAddr(const A: TAddr; Family: TCpuFamily): string;
function SameAddr(const A, B: TAddr): Boolean;
function ParseConst(const S: string; out C: TConst): Boolean;

function DataTypeSize(T: TDataType): Integer;      // bytes, 0 for Bool
function ParseDataType(const S: string; out T: TDataType; out ArrLo, ArrHi: Integer): Boolean;
function SplitArrayType(const S: string; out ArrLo, ArrHi: Integer; out Elem: string): Boolean;
function DataTypeText(T: TDataType; ArrLo, ArrHi: Integer; IsArray: Boolean): string;
function TypeOpSize(T: TDataType): TOpSize;

{ S5TIME: BCD 0..999 in bits 0..11, time base in bits 12..13 (10 ms, 100 ms, 1 s, 10 s) }
function MsToS5Time(Ms: Int64): Word;
function S5TimeToMs(W: Word): Int64;
function FormatS5Time(W: Word): string;
function FormatTime(Ms: LongInt): string;     // T#1H_2M_3S_4MS
function ParseTimeLiteral(const S: string; out Ms: Int64): Boolean;  // body after T#
function BcdToInt(W: LongWord; Digits: Integer; out Ok: Boolean): Int64;
function IntToBcd(V: Int64; Digits: Integer; out Ok: Boolean): LongWord;
function StrToFloatDot(const S: string; out V: Double): Boolean;
function FloatToStrDot(V: Double): string;
function ModelIndexByName(const AName: string): Integer;
{ family rules }
function IsTia(F: TCpuFamily): Boolean;          // S7-1200 / 1500: %addresses, optimized DBs, PUT/GET, retain flags
function HasStl(F: TCpuFamily): Boolean;         // all but the S7-1200
function StopOnProgError(F: TCpuFamily): Boolean;  // no OB121: STOP (the S7-1200 goes on)
function StopOnStationFailure(F: TCpuFamily): Boolean;  // no OB86: STOP on S7-300/400 only

implementation

function IsTia(F: TCpuFamily): Boolean;
begin
  Result := F in [cfS71200, cfS71500];
end;

function HasStl(F: TCpuFamily): Boolean;
begin
  Result := F <> cfS71200;
end;

function StopOnProgError(F: TCpuFamily): Boolean;
begin
  Result := F <> cfS71200;
end;

function StopOnStationFailure(F: TCpuFamily): Boolean;
begin
  Result := F in [cfS7300, cfS7400];
end;

function NoAddr: TAddr;
begin
  FillChar(Result, SizeOf(Result), 0);
end;

function MakeAddr(AArea: TArea; ASize: TOpSize; AOfs: Integer; ABit: Integer; ADB: Integer): TAddr;
begin
  Result := NoAddr;
  Result.Area := AArea;
  Result.Size := ASize;
  Result.Ofs := AOfs;
  Result.Bit := ABit;
  Result.DB := ADB;
  if AArea in [arT, arC] then Result.Num := AOfs;
end;

function SameAddr(const A, B: TAddr): Boolean;
begin
  Result := (A.Area = B.Area) and (A.Size = B.Size) and (A.DB = B.DB) and (A.Ofs = B.Ofs) and
    ((A.Size <> osBit) or (A.Bit = B.Bit)) and (A.Num = B.Num);
end;

function StrToFloatDot(const S: string; out V: Double): Boolean;
var
  FS: TFormatSettings;
begin
  FS := DefaultFormatSettings;
  FS.DecimalSeparator := '.';
  FS.ThousandSeparator := #0;
  Result := TryStrToFloat(S, V, FS);
end;

function FloatToStrDot(V: Double): string;
var
  FS: TFormatSettings;
begin
  FS := DefaultFormatSettings;
  FS.DecimalSeparator := '.';
  if IsNan(V) then Exit('NaN');
  if IsInfinite(V) then
  begin
    if V > 0 then Exit('+Inf') else Exit('-Inf');
  end;
  if (Abs(V) >= 1E7) or ((Abs(V) < 1E-4) and (V <> 0)) then
    Result := FormatFloat('0.000000E+00', V, FS)
  else
  begin
    Result := FormatFloat('0.0#####', V, FS);
  end;
end;

{ reads digits from S at P; returns -1 when there are none }
function ReadNum(const S: string; var P: Integer): Integer;
var
  Start: Integer;
begin
  Start := P;
  while (P <= Length(S)) and (S[P] in ['0'..'9']) do Inc(P);
  if P = Start then Exit(-1);
  if P - Start > 7 then Exit(-1);
  Result := StrToInt(Copy(S, Start, P - Start));
end;

function ParseAddr(const S: string; out A: TAddr; out Err: string): Boolean;
var
  T: string;
  P, N, I: Integer;
  C: Char;

  function SizeChar(Ch: Char; out Sz: TOpSize): Boolean;
  begin
    Result := True;
    case Ch of
      'X': Sz := osBit;
      'B': Sz := osByte;
      'W': Sz := osWord;
      'D': Sz := osDWord;
    else
      Result := False;
    end;
  end;

  { offset [.bit] for A.Size; P on the first digit }
  function OfsBit: Boolean;
  begin
    Result := False;
    N := ReadNum(T, P);
    if N < 0 then
    begin
      Err := 'byte offset expected';
      Exit;
    end;
    A.Ofs := N;
    if A.Size = osBit then
    begin
      if (P > Length(T)) or (T[P] <> '.') then
      begin
        Err := 'bit number expected (byte.bit, e.g. 0.0)';
        Exit;
      end;
      Inc(P);
      N := ReadNum(T, P);
      if (N < 0) or (N > 7) then
      begin
        Err := 'bit number must be 0..7';
        Exit;
      end;
      A.Bit := N;
    end;
    if P <= Length(T) then
    begin
      Err := 'unexpected "' + Copy(T, P, MaxInt) + '"';
      Exit;
    end;
    Result := True;
  end;

begin
  Result := False;
  Err := '';
  A := NoAddr;
  T := '';
  for I := 1 to Length(S) do
    if not (S[I] in [' ', #9]) then T := T + UpCase(S[I]);
  if (T <> '') and (T[1] = '%') then Delete(T, 1, 1);
  if T = '' then
  begin
    Err := 'empty address';
    Exit;
  end;
  // S7-1200 peripheral suffix
  if (Length(T) > 2) and (Copy(T, Length(T) - 1, 2) = ':P') then
  begin
    A.Periph := True;
    SetLength(T, Length(T) - 2);
  end;
  P := 1;
  // DBn.DBXn.n   DBXn.n   DIXn.n
  if (Length(T) >= 3) and (Copy(T, 1, 2) = 'DB') and (T[3] in ['0'..'9']) then
  begin
    P := 3;
    N := ReadNum(T, P);
    if (P > Length(T)) or (T[P] <> '.') then
    begin
      Err := 'DB access: DBn.DBX / DBB / DBW / DBD';
      Exit;
    end;
    if N < 1 then
    begin
      Err := 'DB number must be 1 or more';
      Exit;
    end;
    A.DB := N;
    Inc(P);
    if Copy(T, P, 2) <> 'DB' then
    begin
      Err := 'DB access: DBn.DBX / DBB / DBW / DBD';
      Exit;
    end;
    Inc(P, 2);
    if (P > Length(T)) or not SizeChar(T[P], A.Size) then
    begin
      Err := 'X, B, W or D expected after DB';
      Exit;
    end;
    Inc(P);
    A.Area := arDB;
    Result := OfsBit;
    Exit;
  end;
  if (Length(T) >= 3) and ((Copy(T, 1, 2) = 'DB') or (Copy(T, 1, 2) = 'DI')) and
    SizeChar(T[3], A.Size) and (Length(T) >= 4) and (T[4] in ['0'..'9']) then
  begin
    if T[2] = 'B' then A.Area := arDB else A.Area := arDI;
    P := 4;
    Result := OfsBit;
    Exit;
  end;
  // PIB / PIW / PID / PQB ...
  if (Length(T) >= 3) and (T[1] = 'P') and (T[2] in ['I', 'Q']) and (T[3] in ['B', 'W', 'D']) then
  begin
    if T[2] = 'I' then A.Area := arPI else A.Area := arPQ;
    SizeChar(T[3], A.Size);
    A.Periph := True;
    P := 4;
    Result := OfsBit;
    Exit;
  end;
  C := T[1];
  // T n / C n
  if (C in ['T', 'C']) and (Length(T) >= 2) and (T[2] in ['0'..'9']) then
  begin
    P := 2;
    N := ReadNum(T, P);
    if P <= Length(T) then
    begin
      Err := 'timer / counter number expected';
      Exit;
    end;
    if C = 'T' then A.Area := arT else A.Area := arC;
    A.Size := osBit;
    A.Num := N;
    A.Ofs := N;
    Result := True;
    Exit;
  end;
  if C in ['I', 'Q', 'M', 'L'] then
  begin
    case C of
      'I': A.Area := arI;
      'Q': A.Area := arQ;
      'M': A.Area := arM;
      'L': A.Area := arL;
    end;
    P := 2;
    if (P <= Length(T)) and (T[P] in ['B', 'W', 'D', 'X']) then
    begin
      SizeChar(T[P], A.Size);
      Inc(P);
    end
    else
      A.Size := osBit;
    Result := OfsBit;
    if Result and A.Periph then
    begin
      if A.Area = arI then A.Area := arPI
      else if A.Area = arQ then A.Area := arPQ
      else
      begin
        Err := ':P only for I and Q';
        Result := False;
      end;
    end;
    Exit;
  end;
  Err := 'unknown operand "' + S + '"';
end;

function FormatAddr(const A: TAddr; Family: TCpuFamily): string;
const
  SizeCh: array[TOpSize] of string = ('X', 'B', 'W', 'D');
  SizeCh2: array[TOpSize] of string = ('', 'B', 'W', 'D');
var
  Sp, Pre, Ob: string;
begin
  if IsTia(Family) then
  begin
    Sp := '';
    Pre := '%';
  end
  else
  begin
    Sp := ' ';
    Pre := '';
  end;
  if A.Size = osBit then Ob := IntToStr(A.Ofs) + '.' + IntToStr(A.Bit) else Ob := IntToStr(A.Ofs);
  case A.Area of
    arI, arQ, arM, arL:
      Result := Pre + AreaNames[A.Area] + SizeCh2[A.Size] + Sp + Ob;
    arPI, arPQ:
      if IsTia(Family) then
      begin
        if A.Area = arPI then Result := '%I' else Result := '%Q';
        Result := Result + SizeCh2[A.Size] + Ob + ':P';
      end
      else
        Result := AreaNames[A.Area] + SizeCh2[A.Size] + Sp + Ob;
    arDB:
      if A.DB > 0 then
        Result := Pre + 'DB' + IntToStr(A.DB) + '.DB' + SizeCh[A.Size] + Sp + Ob
      else
        Result := Pre + 'DB' + SizeCh[A.Size] + Sp + Ob;
    arDI:
      Result := Pre + 'DI' + SizeCh[A.Size] + Sp + Ob;
    arT: Result := Pre + 'T' + Sp + IntToStr(A.Num);
    arC: Result := Pre + 'C' + Sp + IntToStr(A.Num);
  else
    Result := '?';
  end;
end;

function DataTypeSize(T: TDataType): Integer;
begin
  case T of
    dtBool: Result := 0;
    dtByte, dtChar, dtSInt, dtUSInt: Result := 1;
    dtWord, dtInt, dtUInt, dtS5Time, dtDate: Result := 2;
    dtDWord, dtDInt, dtUDInt, dtReal, dtTime, dtTOD: Result := 4;
    dtIECTimer: Result := 10;    // PT Time, ET Time, IN 8.0, Q 8.1
    dtIECCounter: Result := 6;   // CU CD R LD QU QD bits in byte 0, PV Int 2, CV Int 4
  else
    Result := 0;
  end;
end;

function TypeOpSize(T: TDataType): TOpSize;
begin
  case DataTypeSize(T) of
    0: Result := osBit;
    1: Result := osByte;
    2: Result := osWord;
  else
    Result := osDWord;
  end;
end;

function ParseDataType(const S: string; out T: TDataType; out ArrLo, ArrHi: Integer): Boolean;
var
  U, Inner, LoS, HiS: string;
  P, Q: Integer;
  D: TDataType;
begin
  Result := False;
  T := dtNone;
  ArrLo := 0;
  ArrHi := -1;
  U := UpperCase(Trim(S));
  if Copy(U, 1, 6) = 'ARRAY[' then
  begin
    P := Pos(']', U);
    if P = 0 then Exit;
    Inner := Copy(U, 7, P - 7);
    Q := Pos('..', Inner);
    if Q = 0 then Exit;
    LoS := Trim(Copy(Inner, 1, Q - 1));
    HiS := Trim(Copy(Inner, Q + 2, MaxInt));
    if not TryStrToInt(LoS, ArrLo) or not TryStrToInt(HiS, ArrHi) then Exit;
    if (ArrHi < ArrLo) or (ArrHi - ArrLo > 9999) then Exit;
    U := Trim(Copy(U, P + 1, MaxInt));
    if Copy(U, 1, 3) <> 'OF ' then Exit;
    U := Trim(Copy(U, 4, MaxInt));
  end;
  if U = 'TOD' then U := 'TIME_OF_DAY';
  if U = 'BOOLEAN' then U := 'BOOL';
  for D := Succ(dtNone) to Pred(dtStruct) do
    if UpperCase(DataTypeNames[D]) = U then
    begin
      T := D;
      Result := True;
      Exit;
    end;
end;

{ Array[lo..hi] of <Elem>: False for a malformed array, Lo > Hi and Elem = S when S is no array }
function SplitArrayType(const S: string; out ArrLo, ArrHi: Integer; out Elem: string): Boolean;
var
  U, Inner: string;
  P, Q: Integer;
begin
  Result := False;
  ArrLo := 0;
  ArrHi := -1;
  Elem := Trim(S);
  U := UpperCase(Elem);
  if Copy(U, 1, 6) <> 'ARRAY[' then Exit(True);
  P := Pos(']', U);
  if P = 0 then Exit;
  Inner := Copy(U, 7, P - 7);
  Q := Pos('..', Inner);
  if Q = 0 then Exit;
  if not TryStrToInt(Trim(Copy(Inner, 1, Q - 1)), ArrLo) or
    not TryStrToInt(Trim(Copy(Inner, Q + 2, MaxInt)), ArrHi) then Exit;
  if (ArrHi < ArrLo) or (ArrHi - ArrLo > 9999) then Exit;
  Elem := Trim(Copy(Elem, P + 1, MaxInt));
  if UpperCase(Copy(Elem, 1, 3)) <> 'OF ' then Exit;
  Elem := Trim(Copy(Elem, 4, MaxInt));
  Result := True;
end;

function DataTypeText(T: TDataType; ArrLo, ArrHi: Integer; IsArray: Boolean): string;
begin
  Result := DataTypeNames[T];
  if IsArray then Result := Format('Array[%d..%d] of %s', [ArrLo, ArrHi, Result]);
end;

function BcdToInt(W: LongWord; Digits: Integer; out Ok: Boolean): Int64;
var
  I, D: Integer;
  M: Int64;
begin
  Result := 0;
  Ok := True;
  M := 1;
  for I := 0 to Digits - 1 do
  begin
    D := (W shr (I * 4)) and $F;
    if D > 9 then Ok := False;
    Result := Result + D * M;
    M := M * 10;
  end;
end;

function IntToBcd(V: Int64; Digits: Integer; out Ok: Boolean): LongWord;
var
  I: Integer;
begin
  Result := 0;
  Ok := (V >= 0) and (V < Round(IntPower(10, Digits)));
  if not Ok then V := Abs(V) mod Round(IntPower(10, Digits));
  for I := 0 to Digits - 1 do
  begin
    Result := Result or (LongWord(V mod 10) shl (I * 4));
    V := V div 10;
  end;
end;

function MsToS5Time(Ms: Int64): Word;
const
  Bases: array[0..3] of Integer = (10, 100, 1000, 10000);
var
  B: Integer;
  V: Int64;
  Ok: Boolean;
begin
  if Ms < 0 then Ms := 0;
  if Ms > 9990000 then Ms := 9990000;
  for B := 0 to 3 do
  begin
    V := Ms div Bases[B];
    if V <= 999 then
    begin
      Result := Word(IntToBcd(V, 3, Ok)) or Word(B shl 12);
      Exit;
    end;
  end;
  Result := $3999;
end;

function S5TimeToMs(W: Word): Int64;
const
  Bases: array[0..3] of Integer = (10, 100, 1000, 10000);
var
  Ok: Boolean;
begin
  Result := BcdToInt(W and $FFF, 3, Ok) * Bases[(W shr 12) and 3];
end;

function FormatTime(Ms: LongInt): string;
var
  V: Int64;
  D, H, M, S, MS2: Int64;
begin
  V := Ms;
  if V < 0 then
  begin
    Result := 'T#-';
    V := -V;
  end
  else
    Result := 'T#';
  D := V div 86400000;
  V := V mod 86400000;
  H := V div 3600000;
  V := V mod 3600000;
  M := V div 60000;
  V := V mod 60000;
  S := V div 1000;
  MS2 := V mod 1000;
  if D > 0 then Result := Result + IntToStr(D) + 'D_';
  if H > 0 then Result := Result + IntToStr(H) + 'H_';
  if M > 0 then Result := Result + IntToStr(M) + 'M_';
  if (S > 0) or ((MS2 = 0) and (D + H + M = 0)) then Result := Result + IntToStr(S) + 'S_';
  if MS2 > 0 then Result := Result + IntToStr(MS2) + 'MS_';
  if Result[Length(Result)] = '_' then SetLength(Result, Length(Result) - 1);
end;

function FormatS5Time(W: Word): string;
begin
  Result := 'S5T#' + Copy(FormatTime(S5TimeToMs(W)), 3, MaxInt);
end;

{ 1D2H3M4S5MS, 1.5S, 500MS, with optional underscores }
function ParseTimeLiteral(const S: string; out Ms: Int64): Boolean;
var
  U, NumS, UnitS: string;
  P: Integer;
  V: Double;
  Neg, Any: Boolean;
  Total: Double;
begin
  Result := False;
  Ms := 0;
  U := UpperCase(StringReplace(S, '_', '', [rfReplaceAll]));
  Neg := False;
  if (U <> '') and (U[1] = '-') then
  begin
    Neg := True;
    Delete(U, 1, 1);
  end;
  if U = '' then Exit;
  P := 1;
  Total := 0;
  Any := False;
  while P <= Length(U) do
  begin
    NumS := '';
    while (P <= Length(U)) and (U[P] in ['0'..'9', '.']) do
    begin
      NumS := NumS + U[P];
      Inc(P);
    end;
    UnitS := '';
    while (P <= Length(U)) and (U[P] in ['A'..'Z']) do
    begin
      UnitS := UnitS + U[P];
      Inc(P);
    end;
    if (NumS = '') or not StrToFloatDot(NumS, V) then Exit;
    if UnitS = 'D' then Total := Total + V * 86400000
    else if UnitS = 'H' then Total := Total + V * 3600000
    else if UnitS = 'M' then Total := Total + V * 60000
    else if UnitS = 'S' then Total := Total + V * 1000
    else if UnitS = 'MS' then Total := Total + V
    else Exit;
    Any := True;
  end;
  if not Any then Exit;
  if Total > 2147483647 then Exit;
  Ms := Round(Total);
  if Neg then Ms := -Ms;
  Result := True;
end;

function ParseConst(const S: string; out C: TConst): Boolean;
var
  U, Body: string;
  V: Int64;
  R: Double;
  Ms: Int64;
  Ok: Boolean;
  Sg: Single;
  I: Integer;

  function ParseRadix(const B: string; Radix: Integer; out Res: Int64): Boolean;
  var
    K, D: Integer;
    T: string;
  begin
    Result := False;
    Res := 0;
    T := StringReplace(B, '_', '', [rfReplaceAll]);
    if (T = '') or (Length(T) > 32) then Exit;
    for K := 1 to Length(T) do
    begin
      case T[K] of
        '0'..'9': D := Ord(T[K]) - Ord('0');
        'A'..'F': D := Ord(T[K]) - Ord('A') + 10;
      else
        Exit;
      end;
      if D >= Radix then Exit;
      Res := Res * Radix + D;
      if Res > $FFFFFFFF then Exit;
    end;
    Result := True;
  end;

begin
  Result := False;
  FillChar(C, SizeOf(C), 0);
  U := UpperCase(Trim(S));
  if U = '' then Exit;
  if (U = 'TRUE') or (U = 'FALSE') then
  begin
    C.Kind := ckBool;
    C.I := Ord(U = 'TRUE');
    C.Bits := C.I;
    C.Size := osBit;
    Exit(True);
  end;
  if (Length(S) = 3) and (S[1] = '''') and (S[3] = '''') then
  begin
    C.Kind := ckChar;
    C.I := Ord(S[2]);
    C.Bits := C.I;
    C.Size := osByte;
    Exit(True);
  end;
  if Copy(U, 1, 4) = 'S5T#' then
  begin
    if not ParseTimeLiteral(Copy(U, 5, MaxInt), Ms) or (Ms < 0) or (Ms > 9990000) then Exit;
    C.Kind := ckS5Time;
    C.I := Ms;
    C.Bits := MsToS5Time(Ms);
    C.Size := osWord;
    Exit(True);
  end;
  if (Copy(U, 1, 2) = 'T#') or (Copy(U, 1, 5) = 'TIME#') then
  begin
    if U[2] = '#' then Body := Copy(U, 3, MaxInt) else Body := Copy(U, 6, MaxInt);
    if not ParseTimeLiteral(Body, Ms) then Exit;
    C.Kind := ckTime;
    C.I := Ms;
    C.Bits := LongWord(LongInt(Ms));
    C.Size := osDWord;
    Exit(True);
  end;
  if Copy(U, 1, 2) = 'C#' then
  begin
    if not TryStrToInt64(Copy(U, 3, MaxInt), V) or (V < 0) or (V > 999) then Exit;
    C.Kind := ckCounter;
    C.I := V;
    C.Bits := IntToBcd(V, 3, Ok);
    C.Size := osWord;
    Exit(True);
  end;
  if Copy(U, 1, 2) = 'L#' then
  begin
    if not TryStrToInt64(Copy(U, 3, MaxInt), V) or (V < -2147483648) or (V > 2147483647) then Exit;
    C.Kind := ckDInt;
    C.I := V;
    C.Bits := LongWord(LongInt(V));
    C.Size := osDWord;
    Exit(True);
  end;
  // hex / binary: 16#.., W#16#.., DW#16#.., B#16#.., 2#..
  Body := '';
  if Copy(U, 1, 6) = 'DW#16#' then begin Body := Copy(U, 7, MaxInt); C.Size := osDWord; I := 16; end
  else if Copy(U, 1, 5) = 'W#16#' then begin Body := Copy(U, 6, MaxInt); C.Size := osWord; I := 16; end
  else if Copy(U, 1, 5) = 'B#16#' then begin Body := Copy(U, 6, MaxInt); C.Size := osByte; I := 16; end
  else if Copy(U, 1, 3) = '16#' then begin Body := Copy(U, 4, MaxInt); C.Size := osWord; I := 16; end
  else if Copy(U, 1, 2) = '2#' then begin Body := Copy(U, 3, MaxInt); C.Size := osWord; I := 2; end;
  if Body <> '' then
  begin
    if not ParseRadix(Body, I, V) then Exit;
    C.Kind := ckHex;
    C.I := V;
    C.Bits := LongWord(V);
    if (Copy(U, 1, 3) = '16#') or (Copy(U, 1, 2) = '2#') then
    begin
      if V > $FFFF then C.Size := osDWord else C.Size := osWord;
    end;
    Exit(True);
  end;
  // integers and reals
  if TryStrToInt64(U, V) then
  begin
    if (V >= -32768) and (V <= 32767) then
    begin
      C.Kind := ckInt;
      C.I := V;
      C.Bits := LongWord(V) and $FFFF;
      C.Size := osWord;
    end
    else if (V >= -2147483648) and (V <= 2147483647) then
    begin
      C.Kind := ckDInt;
      C.I := V;
      C.Bits := LongWord(LongInt(V));
      C.Size := osDWord;
    end
    else
      Exit;
    Exit(True);
  end;
  if (Pos('.', U) > 0) or (Pos('E', U) > 0) then
    if StrToFloatDot(U, R) then
    begin
      C.Kind := ckReal;
      C.R := R;
      Sg := R;
      C.Bits := PLongWord(@Sg)^;
      C.Size := osDWord;
      Exit(True);
    end;
end;

function ModelIndexByName(const AName: string): Integer;
var
  I: Integer;
begin
  for I := 0 to ModelCount - 1 do
    if SameText(Models[I].Name, AName) then Exit(I);
  Result := -1;
end;

end.
