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
    dtStruct,    // a PLC data type (UDT) of the project: size and members in uPlcProject
    dtWChar,     // a 16 bit character (S7-1200 / 1500)
    dtString, dtWString,    // String[n]: max, length, n bytes; WString[n]: max, length words, n words
    // 64 bit (S7-1500; LReal also S7-1200, DT S7-300/400/1500): held exactly as Int64 in SCL
    dtLWord, dtLInt, dtULInt, dtLReal,
    dtLTime,     // ns
    dtLTOD,      // ns since midnight
    dtLDT,       // ns since 1970-01-01
    dtDT);       // Date_And_Time: 8 BCD bytes, in SCL ms since 1990-01-01
  TAreaSet = set of TArea;

  { the dimensions of an array: Array[0..2, 0..3] of Int has two }
  TArrDim = record
    Lo, Hi: Integer;
  end;
  TArrDims = array of TArrDim;

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
    'IEC_TIMER', 'IEC_COUNTER', 'Struct', 'WChar', 'String', 'WString', 'LWord', 'LInt', 'ULInt', 'LReal',
    'LTime', 'LTime_Of_Day', 'LDT', 'Date_And_Time');
  { the 64 bit integers (also the times / dates in them): exact in the Int64 half of the SCL stack }
  Int64Types = [dtLWord, dtLInt, dtULInt, dtLTime, dtLTOD, dtLDT, dtDT];
  RealTypes = [dtReal, dtLReal];

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
{ the address after A: the next bit, the next byte / word / double word (Bytes: the size of A's value),
  the next timer / counter }
function NextAddr(const A: TAddr; Bytes: Integer): TAddr;
{ the next free name after a name: Tag_3 -> Tag_4, Motor -> Motor_1 (Used: the names taken, not case
  sensitive) }
function NextName(const Name: string; Used: TStrings): string;
function SameAddr(const A, B: TAddr): Boolean;
function ParseConst(const S: string; out C: TConst): Boolean;

function DataTypeSize(T: TDataType): Integer;      // bytes, 0 for Bool
function ParseDataType(const S: string; out T: TDataType; out ArrLo, ArrHi: Integer): Boolean;
function SplitArrayType(const S: string; out ArrLo, ArrHi: Integer; out Elem: string): Boolean;
{ the dimensions of "Array[a..b, c..d] of ..." (nil: no array or a bad one). An array of more than one
  dimension is laid out as one dimension 0..n-1 (row by row, the last index fastest, like the CPU) }
function ArrayDims(const S: string): TArrDims;
{ the instruction of a system FB type: TON_TIME -> TON, CTU_INT -> CTU ('' for IEC_TIMER / IEC_COUNTER) }
function SysFbMethod(const TypeText: string): string;
{ an IEC typed literal of SCL: INT#5, UDINT#16#FF, BOOL#1, REAL#1.5, 8#17, D#2024-01-31, TOD#12:00:00.5,
  CHAR#'A'; V is its value (DATE: days since 1990-01-01, TOD: ms since midnight), T its type }
function SclTypedLiteral(const S: string; out V: Double; out T: TDataType): Boolean;
{ the same with the exact value of a 64 bit integer, time or date (I) }
function SclTypedLiteralEx(const S: string; out V: Double; out I: Int64; out T: TDataType): Boolean;
{ the type of the PV / CV of a counter (CTU_DINT -> DInt, IEC_COUNTER -> Int) or of the times of a timer
  (TON_LTIME -> LTime, IEC_TIMER -> Time); dtNone for other types }
function IecVarType(const TypeText: string): TDataType;
{ the 8 bytes of a 64 bit variable as SCL writes it: LInt, ULInt, LW#16#.., an LReal, LT#.., LTOD#.., LDT#.., DT#.. }
function Format64(T: TDataType; Q: QWord): string;
{ a text (a number or a literal) into the 8 bytes of a 64 bit type; False when it does not fit }
function Parse64(T: TDataType; const S: string; out Q: QWord): Boolean;
{ Date_And_Time: ms since 1990-01-01 <-> the 8 BCD bytes (yy mm dd hh mm ss, ms and weekday) }
function EncodeDT(MsSince1990: Int64): QWord;
function DecodeDT(Q: QWord): Int64;
{ the max length of String[n] / WString[n] (also an array of them): 254 without [n], -1 when it is bad }
function StringMaxOf(const TypeText: string): Integer;
{ the text (UTF-8) of an SCL string literal without its quotes: '' -> ', $N $L new line, $R $T $P, $$, $',
  $hh a character code (Wide: $hhhh, a WString / WChar) }
function SclStrDecode(const S: string; Wide: Boolean = False): string;
{ a start value of a DB variable: ParseConst, then the typed literals of SCL and UDInt numbers }
function ParseStartValue(const S: string; out C: TConst): Boolean;
{ the start values of an array, "[1, 2, 3(7)]" -> 1, 2, 7, 7, 7 (n(v): v repeated n times) }
function ExpandInitList(const S: string): TStringArray;
{ the start value of element E (0 = the first) of an array of N elements: of the list, or the one value of all }
function ArrayStartOf(const Start: string; N, E: Integer): string;
{ the start values with element E set to Val: a list "[1, 0, 3(5)]" (runs as n(v)), one value when all are the
  same, '' when all are the default Def }
function ArrayStartSet(const Start: string; N, E: Integer; const Val, Def: string): string;
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

function NextAddr(const A: TAddr; Bytes: Integer): TAddr;
begin
  Result := A;
  if A.Area in [arT, arC] then
  begin
    Inc(Result.Num);
    Exit;
  end;
  if A.Size = osBit then
  begin
    if A.Bit >= 7 then
    begin
      Result.Bit := 0;
      Inc(Result.Ofs);
    end
    else
      Inc(Result.Bit);
    Exit;
  end;
  if Bytes <= 0 then
    case A.Size of
      osByte: Bytes := 1;
      osWord: Bytes := 2;
    else
      Bytes := 4;
    end;
  Inc(Result.Ofs, Bytes);
end;

function NextName(const Name: string; Used: TStrings): string;
var
  Base: string;
  K, N: Integer;

  function Taken(const S: string): Boolean;
  var
    J: Integer;
  begin
    for J := 0 to Used.Count - 1 do
      if SameText(Used[J], S) then Exit(True);
    Result := False;
  end;

begin
  // the number at the end goes up; none: _1
  K := Length(Name);
  while (K > 0) and (Name[K] in ['0'..'9']) do Dec(K);
  if (K < Length(Name)) and TryStrToInt(Copy(Name, K + 1, MaxInt), N) then
    Base := Copy(Name, 1, K)
  else
  begin
    if Name = '' then Base := 'Tag_' else Base := Name + '_';
    N := 0;
  end;
  repeat
    Inc(N);
    Result := Base + IntToStr(N);
  until not Taken(Result);
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
    dtWord, dtInt, dtUInt, dtS5Time, dtDate, dtWChar: Result := 2;
    dtDWord, dtDInt, dtUDInt, dtReal, dtTime, dtTOD: Result := 4;
    dtLWord, dtLInt, dtULInt, dtLReal, dtLTime, dtLTOD, dtLDT, dtDT: Result := 8;
    dtIECTimer: Result := 10;    // PT Time, ET Time, IN 8.0, Q 8.1
    dtIECCounter: Result := 6;   // CU CD R LD QU QD bits in byte 0, PV Int 2, CV Int 4
  else
    Result := 0;
  end;
end;

function TypeOpSize(T: TDataType): TOpSize;
begin
  if T in [dtString, dtWString] then Exit(osByte);   // the start of the string (its max length byte)
  case DataTypeSize(T) of
    0: Result := osBit;
    1: Result := osByte;
    2: Result := osWord;
  else
    Result := osDWord;
  end;
end;

function ArrayDims(const S: string): TArrDims;
var
  U, Inner, Part: string;
  P, Q, N, Total: Integer;
begin
  Result := nil;
  U := UpperCase(Trim(S));
  if Copy(U, 1, 6) <> 'ARRAY[' then Exit;
  P := Pos(']', U);
  if P = 0 then Exit;
  Inner := Copy(U, 7, P - 7) + ',';
  Total := 1;
  while Inner <> '' do
  begin
    Q := Pos(',', Inner);
    Part := Trim(Copy(Inner, 1, Q - 1));
    Delete(Inner, 1, Q);
    N := Length(Result);
    SetLength(Result, N + 1);
    Q := Pos('..', Part);
    if (Q = 0) or not TryStrToInt(Trim(Copy(Part, 1, Q - 1)), Result[N].Lo) or
      not TryStrToInt(Trim(Copy(Part, Q + 2, MaxInt)), Result[N].Hi) or (Result[N].Hi < Result[N].Lo) then
      Exit(nil);
    Total := Total * (Result[N].Hi - Result[N].Lo + 1);
    if (Total > 10000) or (N >= 5) then Exit(nil);
  end;
end;

{ the element range of an array type: one dimension as written, more flattened to 0..n-1 }
function ArrayRange(const S: string; out ArrLo, ArrHi: Integer): Boolean;
var
  D: TArrDims;
  K, N: Integer;
begin
  D := ArrayDims(S);
  Result := Length(D) > 0;
  if not Result then Exit;
  if Length(D) = 1 then
  begin
    ArrLo := D[0].Lo;
    ArrHi := D[0].Hi;
    Exit;
  end;
  N := 1;
  for K := 0 to High(D) do N := N * (D[K].Hi - D[K].Lo + 1);
  ArrLo := 0;
  ArrHi := N - 1;
end;

function SysFbMethod(const TypeText: string): string;
var
  U, Pfx, Sfx: string;
  P: Integer;
begin
  Result := '';
  U := UpperCase(Trim(TypeText));
  if Copy(U, 1, 6) = 'ARRAY[' then
  begin
    P := Pos(' OF ', U);
    if P = 0 then Exit('');
    U := Trim(Copy(U, P + 4, MaxInt));
  end;
  // TON_TIME, TON_LTIME, TON; CTU_INT, CTU_DINT, CTU_ULINT, CTU ...
  P := Pos('_', U);
  if P > 0 then
  begin
    Pfx := Copy(U, 1, P - 1);
    Sfx := Copy(U, P + 1, MaxInt);
  end
  else
  begin
    Pfx := U;
    Sfx := '';
  end;
  if (Pfx = 'TON') or (Pfx = 'TOF') or (Pfx = 'TP') or (Pfx = 'TONR') then
  begin
    if (Sfx = '') or (Sfx = 'TIME') or (Sfx = 'LTIME') then Result := Pfx;
  end
  else if (Pfx = 'CTU') or (Pfx = 'CTD') or (Pfx = 'CTUD') then
    case Sfx of
      '', 'SINT', 'USINT', 'INT', 'UINT', 'DINT', 'UDINT', 'LINT', 'ULINT': Result := Pfx;
    end;
end;

function IecVarType(const TypeText: string): TDataType;
var
  U: string;
  P: Integer;
begin
  Result := dtNone;
  U := UpperCase(Trim(TypeText));
  if Copy(U, 1, 6) = 'ARRAY[' then
  begin
    P := Pos(' OF ', U);
    if P = 0 then Exit;
    U := Trim(Copy(U, P + 4, MaxInt));
  end;
  if U = 'IEC_TIMER' then Exit(dtTime);
  if U = 'IEC_COUNTER' then Exit(dtInt);
  case SysFbMethod(U) of
    'TON', 'TOF', 'TP', 'TONR':
      if Pos('_LTIME', U) > 0 then Result := dtLTime else Result := dtTime;
    'CTU', 'CTD', 'CTUD':
      case Copy(U, Pos('_', U) + 1, MaxInt) of
        'SINT': Result := dtSInt;
        'USINT': Result := dtUSInt;
        'UINT': Result := dtUInt;
        'DINT': Result := dtDInt;
        'UDINT': Result := dtUDInt;
        'LINT': Result := dtLInt;
        'ULINT': Result := dtULInt;
      else
        Result := dtInt;
      end;
  end;
end;

{ the fraction of a second: .5, .123456789 (no zeros at the end), '' for none }
function FracText(Units: Int64; Digits: Integer): string;
begin
  if Units = 0 then Exit('');
  Result := IntToStr(Units);
  Result := StringOfChar('0', Digits - Length(Result)) + Result;
  while (Result <> '') and (Result[Length(Result)] = '0') do SetLength(Result, Length(Result) - 1);
  Result := '.' + Result;
end;

function DayTimeText(Ns: Int64): string;
begin
  Result := Format('%.2d:%.2d:%.2d', [Ns div 3600000000000, Ns div 60000000000 mod 60, Ns div 1000000000 mod 60]) +
    FracText(Ns mod 1000000000, 9);
end;

function Format64(T: TDataType; Q: QWord): string;
var
  Fs: TFormatSettings;
  D: Double;
  I, N: Int64;
  Ms: Int64;
begin
  I := Int64(Q);
  case T of
    dtLInt: Result := IntToStr(I);
    dtULInt: Result := UIntToStr(Q);
    dtLWord: Result := 'LW#16#' + IntToHex(Q, 16);
    dtLReal:
      begin
        // 15 digits: what an LReal holds
        Move(Q, D, 8);
        if IsNan(D) or IsInfinite(D) then Exit(FloatToStrDot(D));
        Fs := DefaultFormatSettings;
        Fs.DecimalSeparator := '.';
        Result := FloatToStrF(D, ffGeneral, 15, 0, Fs);
        if (Pos('.', Result) = 0) and (Pos('E', Result) = 0) then Result := Result + '.0';
      end;
    dtLTime:
      begin
        // LT#1D_2H_3M_4S_5MS_6US_7NS
        if I = 0 then Exit('LT#0NS');
        if I < 0 then Result := 'LT#-' else Result := 'LT#';
        N := Abs(I);
        if N >= 86400000000000 then Result := Result + IntToStr(N div 86400000000000) + 'D_';
        if N div 3600000000000 mod 24 > 0 then Result := Result + IntToStr(N div 3600000000000 mod 24) + 'H_';
        if N div 60000000000 mod 60 > 0 then Result := Result + IntToStr(N div 60000000000 mod 60) + 'M_';
        if N div 1000000000 mod 60 > 0 then Result := Result + IntToStr(N div 1000000000 mod 60) + 'S_';
        if N div 1000000 mod 1000 > 0 then Result := Result + IntToStr(N div 1000000 mod 1000) + 'MS_';
        if N div 1000 mod 1000 > 0 then Result := Result + IntToStr(N div 1000 mod 1000) + 'US_';
        if N mod 1000 > 0 then Result := Result + IntToStr(N mod 1000) + 'NS_';
        SetLength(Result, Length(Result) - 1);
      end;
    dtLTOD: Result := 'LTOD#' + DayTimeText(I mod 86400000000000);
    dtLDT:
      Result := 'LDT#' + FormatDateTime('yyyy-mm-dd', EncodeDate(1970, 1, 1) + I div 86400000000000) + '-' +
        DayTimeText(I mod 86400000000000);
    dtDT:
      begin
        Ms := DecodeDT(Q);
        Result := 'DT#' + FormatDateTime('yyyy-mm-dd', EncodeDate(1990, 1, 1) + Ms div 86400000) + '-' +
          DayTimeText((Ms mod 86400000) * 1000000);
      end;
  else
    Result := IntToStr(I);
  end;
end;

function Parse64(T: TDataType; const S: string; out Q: QWord): Boolean;
var
  V: Double;
  I: Int64;
  Lt: TDataType;
begin
  Result := False;
  Q := 0;
  if T = dtLReal then
  begin
    if not StrToFloatDot(Trim(S), V) then
    begin
      if not SclTypedLiteralEx(S, V, I, Lt) or not (Lt in RealTypes) then Exit;
    end;
    Move(V, Q, 8);
    Exit(True);
  end;
  if TryStrToInt64(Trim(S), I) then
  begin
    if T = dtDT then Q := EncodeDT(I) else Q := QWord(I);
    Exit(True);
  end;
  if TryStrToQWord(Trim(S), Q) then Exit(T in [dtULInt, dtLWord]);
  if not SclTypedLiteralEx(S, V, I, Lt) then Exit;
  if not ((Lt = T) or (Lt in [dtLInt, dtULInt, dtLWord, dtDWord, dtWord]) and (T in [dtLInt, dtULInt, dtLWord])) then Exit;
  if T = dtDT then Q := EncodeDT(I) else Q := QWord(I);
  Result := True;
end;

function ToBcd2(V: Integer): Integer;
begin
  Result := (V div 10) shl 4 or (V mod 10);
end;

function FromBcd2(V: Integer): Integer;
begin
  Result := (V shr 4) * 10 + V and $F;
end;

function EncodeDT(MsSince1990: Int64): QWord;
var
  Dt: TDateTime;
  Y, Mo, D, H, Mi, S, Ms: Word;
  Wd: Integer;
begin
  if MsSince1990 < 0 then MsSince1990 := 0;
  Dt := EncodeDate(1990, 1, 1) + MsSince1990 div 86400000;
  DecodeDate(Dt, Y, Mo, D);
  H := MsSince1990 div 3600000 mod 24;
  Mi := MsSince1990 div 60000 mod 60;
  S := MsSince1990 div 1000 mod 60;
  Ms := MsSince1990 mod 1000;
  Wd := DayOfWeek(Dt);   // 1 = Sunday, as on the CPU
  Result := (QWord(ToBcd2(Y mod 100)) shl 56) or (QWord(ToBcd2(Mo)) shl 48) or (QWord(ToBcd2(D)) shl 40) or
    (QWord(ToBcd2(H)) shl 32) or (QWord(ToBcd2(Mi)) shl 24) or (QWord(ToBcd2(S)) shl 16) or
    (QWord(ToBcd2(Ms div 10)) shl 8) or (QWord((Ms mod 10) shl 4)) or QWord(Wd);
end;

function DecodeDT(Q: QWord): Int64;
var
  Y, Mo, D, H, Mi, S, Ms: Integer;
  Dt: TDateTime;
begin
  Y := FromBcd2((Q shr 56) and $FF);
  if Y >= 90 then Inc(Y, 1900) else Inc(Y, 2000);
  Mo := FromBcd2((Q shr 48) and $FF);
  D := FromBcd2((Q shr 40) and $FF);
  H := FromBcd2((Q shr 32) and $FF);
  Mi := FromBcd2((Q shr 24) and $FF);
  S := FromBcd2((Q shr 16) and $FF);
  Ms := FromBcd2((Q shr 8) and $FF) * 10 + ((Q shr 4) and $F);
  if not TryEncodeDate(Y, Mo, D, Dt) then Exit(0);
  Result := Int64(Round(Dt - EncodeDate(1990, 1, 1))) * 86400000 + (H * 3600 + Mi * 60 + S) * Int64(1000) + Ms;
end;

function SclTypedLiteral(const S: string; out V: Double; out T: TDataType): Boolean;
var
  I: Int64;
begin
  Result := SclTypedLiteralEx(S, V, I, T);
end;

{ hh:mm:ss[.fraction]: the fraction in units of 10^-Digits s; Ok when the time is inside a day }
function DayTime(const S: string; Digits: Integer; out Units: Int64): Boolean;
var
  Parts: TStringArray;
  Hh, Mi, Ss, K: Integer;
  Fr: string;
  Scale, F: Int64;
begin
  Result := False;
  Units := 0;
  Parts := S.Split(':');
  if (Length(Parts) < 2) or (Length(Parts) > 3) or not TryStrToInt(Parts[0], Hh) or not TryStrToInt(Parts[1], Mi) then Exit;
  Ss := 0;
  Fr := '';
  if Length(Parts) = 3 then
  begin
    K := Pos('.', Parts[2]);
    if K > 0 then
    begin
      Fr := Copy(Parts[2], K + 1, MaxInt);
      Parts[2] := Copy(Parts[2], 1, K - 1);
    end;
    if not TryStrToInt(Parts[2], Ss) then Exit;
  end;
  if (Hh < 0) or (Hh > 23) or (Mi < 0) or (Mi > 59) or (Ss < 0) or (Ss > 59) then Exit;
  Scale := 1;
  for K := 1 to Digits do Scale := Scale * 10;
  // the fraction: as many digits as the unit has
  Fr := Copy(Fr + StringOfChar('0', Digits), 1, Digits);
  F := 0;
  if (Digits > 0) and not TryStrToInt64(Fr, F) then Exit;
  Units := ((Int64(Hh) * 60 + Mi) * 60 + Ss) * Scale + F;
  Result := True;
end;

{ LT#1D2H3M4S5MS6US7NS (also with _ and a leading -): ns }
function ParseLTime(const S: string; out Ns: Int64): Boolean;
var
  U, Un: string;
  K, J: Integer;
  N: Int64;
  Neg: Boolean;
begin
  Result := False;
  Ns := 0;
  U := UpperCase(StringReplace(Trim(S), '_', '', [rfReplaceAll]));
  Neg := (U <> '') and (U[1] = '-');
  if Neg then Delete(U, 1, 1);
  if U = '' then Exit;
  K := 1;
  while K <= Length(U) do
  begin
    J := K;
    while (J <= Length(U)) and (U[J] in ['0'..'9']) do Inc(J);
    if (J = K) or not TryStrToInt64(Copy(U, K, J - K), N) then Exit;
    K := J;
    while (J <= Length(U)) and (U[J] in ['A'..'Z']) do Inc(J);
    Un := Copy(U, K, J - K);
    case Un of
      'D': Ns := Ns + N * 86400000000000;
      'H': Ns := Ns + N * 3600000000000;
      'M': Ns := Ns + N * 60000000000;
      'S': Ns := Ns + N * 1000000000;
      'MS': Ns := Ns + N * 1000000;
      'US': Ns := Ns + N * 1000;
      'NS': Ns := Ns + N;
    else
      Exit;
    end;
    K := J;
  end;
  if Neg then Ns := -Ns;
  Result := True;
end;

function SclTypedLiteralEx(const S: string; out V: Double; out I: Int64; out T: TDataType): Boolean;
var
  U, Pfx, Body: string;
  P, Y, Mo, Dd, Hh, Mi: Integer;
  Lo, Hi, Dm: Int64;
  Q: QWord;
  Sec: Double;
  Dt: TDateTime;
  Neg: Boolean;
  Parts: TStringArray;
  Ws: UnicodeString;

  { decimal, or 2# / 8# / 16# digits: the magnitude up to 64 bit }
  function Num(const B: string; out R: QWord): Boolean;
  var
    K, Rd, Dg: Integer;
    Tx: string;
  begin
    Result := False;
    R := 0;
    Tx := UpperCase(StringReplace(B, '_', '', [rfReplaceAll]));
    K := Pos('#', Tx);
    Rd := 10;
    if K > 0 then
    begin
      if not TryStrToInt(Copy(Tx, 1, K - 1), Rd) or not ((Rd = 2) or (Rd = 8) or (Rd = 16)) then Exit;
      Tx := Copy(Tx, K + 1, MaxInt);
    end;
    if Tx = '' then Exit;
    for K := 1 to Length(Tx) do
    begin
      case Tx[K] of
        '0'..'9': Dg := Ord(Tx[K]) - Ord('0');
        'A'..'F': Dg := Ord(Tx[K]) - Ord('A') + 10;
      else
        Exit;
      end;
      if Dg >= Rd then Exit;
      if R > (High(QWord) - QWord(Dg)) div QWord(Rd) then Exit;   // more than 64 bit
      R := R * QWord(Rd) + QWord(Dg);
    end;
    Result := True;
  end;

  { a date yyyy-mm-dd: days since 1990-01-01 }
  function DateOf(const B: string; out Days: Int64): Boolean;
  var
    Pt: TStringArray;
  begin
    Result := False;
    Days := 0;
    Pt := B.Split('-');
    if (Length(Pt) <> 3) or not TryStrToInt(Pt[0], Y) or not TryStrToInt(Pt[1], Mo) or
      not TryStrToInt(Pt[2], Dd) or not TryEncodeDate(Y, Mo, Dd, Dt) then Exit;
    Days := Round(Dt - EncodeDate(1990, 1, 1));
    Result := True;
  end;

begin
  Result := False;
  V := 0;
  I := 0;
  T := dtNone;
  U := UpperCase(Trim(S));
  P := Pos('#', U);
  if P < 2 then Exit;
  Pfx := Copy(U, 1, P - 1);
  Body := Copy(Trim(S), P + 1, MaxInt);
  case Pfx of
    '2', '8', '16':
      begin
        // an integer in another base: a bit string like 16#FF
        if not Num(U, Q) or (Q > $FFFFFFFF) then Exit;
        I := Q;
        V := I;
        if I > $FFFF then T := dtDWord else T := dtWord;
        Exit(True);
      end;
    'LT', 'LTIME':
      begin
        if not ParseLTime(Body, I) then Exit;
        V := I;
        T := dtLTime;
        Exit(True);
      end;
    'LTOD', 'LTIME_OF_DAY':
      begin
        if not DayTime(Body, 9, I) then Exit;
        V := I;
        T := dtLTOD;
        Exit(True);
      end;
    'DT', 'DATE_AND_TIME', 'LDT', 'LDATE_AND_TIME':
      begin
        // yyyy-mm-dd-hh:mm:ss[.f]: DT in ms since 1990, LDT in ns since 1970
        P := Pos('-', Body);
        if P > 0 then P := P + Pos('-', Copy(Body, P + 1, MaxInt));
        if P > 0 then P := P + Pos('-', Copy(Body, P + 1, MaxInt));
        if (P = 0) or not DateOf(Copy(Body, 1, P - 1), Dm) then Exit;
        if Pfx[1] = 'L' then
        begin
          if not DayTime(Copy(Body, P + 1, MaxInt), 9, I) then Exit;
          I := (Dm + 7305) * 86400000000000 + I;      // 7305 days from 1970 to 1990
          T := dtLDT;
        end
        else
        begin
          if not DayTime(Copy(Body, P + 1, MaxInt), 3, I) or (Y > 2089) then Exit;
          I := Dm * 86400000 + I;
          T := dtDT;
        end;
        V := I;
        Exit(True);
      end;
    'BOOL':
      begin
        Body := UpperCase(Body);
        if (Body = 'TRUE') or (Body = '1') then V := 1
        else if (Body = 'FALSE') or (Body = '0') then V := 0
        else Exit;
        I := Round(V);
        T := dtBool;
        Exit(True);
      end;
    'REAL', 'LREAL':
      begin
        if not StrToFloatDot(Body, Sec) then Exit;
        V := Sec;
        if Pfx = 'LREAL' then T := dtLReal else T := dtReal;
        Exit(True);
      end;
    'CHAR':
      begin
        if (Length(Body) <> 3) or (Body[1] <> '''') or (Body[3] <> '''') then Exit;
        V := Ord(Body[2]);
        I := Round(V);
        T := dtChar;
        Exit(True);
      end;
    'WCHAR':
      begin
        if (Length(Body) < 3) or (Body[1] <> '''') or (Body[Length(Body)] <> '''') then Exit;
        Ws := UTF8Decode(SclStrDecode(Copy(Body, 2, Length(Body) - 2), True));
        if Length(Ws) <> 1 then Exit;
        V := Ord(Ws[1]);
        I := Round(V);
        T := dtWChar;
        Exit(True);
      end;
    'D', 'DATE':
      begin
        if not DateOf(Body, I) or (I < 0) or (I > 65535) then Exit;
        V := I;
        T := dtDate;
        Exit(True);
      end;
    'TOD', 'TIME_OF_DAY':
      begin
        Parts := Body.Split(':');
        if (Length(Parts) < 2) or (Length(Parts) > 3) or not TryStrToInt(Parts[0], Hh) or
          not TryStrToInt(Parts[1], Mi) then Exit;
        Sec := 0;
        if (Length(Parts) = 3) and not StrToFloatDot(Parts[2], Sec) then Exit;
        if (Hh < 0) or (Hh > 23) or (Mi < 0) or (Mi > 59) or (Sec < 0) or (Sec >= 60) then Exit;
        V := Hh * 3600000 + Mi * 60000 + Round(Sec * 1000);
        I := Round(V);
        T := dtTOD;
        Exit(True);
      end;
  end;
  // INT#5, INT#-5, UDINT#16#FF, BYTE#200 ...
  case Pfx of
    'SINT': begin T := dtSInt; Lo := -128; Hi := 127; end;
    'USINT': begin T := dtUSInt; Lo := 0; Hi := 255; end;
    'BYTE': begin T := dtByte; Lo := -128; Hi := 255; end;
    'INT': begin T := dtInt; Lo := -32768; Hi := 32767; end;
    'UINT': begin T := dtUInt; Lo := 0; Hi := 65535; end;
    'WORD': begin T := dtWord; Lo := -32768; Hi := 65535; end;
    'DINT': begin T := dtDInt; Lo := -2147483648; Hi := 2147483647; end;
    'UDINT': begin T := dtUDInt; Lo := 0; Hi := 4294967295; end;
    'DWORD', 'DW': begin T := dtDWord; Lo := -2147483648; Hi := 4294967295; end;
    'LINT': begin T := dtLInt; Lo := Low(Int64); Hi := High(Int64); end;
    'ULINT', 'LWORD', 'LW': begin if Pfx = 'ULINT' then T := dtULInt else T := dtLWord; Lo := 0; Hi := -1; end;
  else
    Exit;
  end;
  Neg := (Body <> '') and (Body[1] = '-');
  if (Body <> '') and (Body[1] in ['-', '+']) then Delete(Body, 1, 1);
  if not Num(Body, Q) then
  begin
    T := dtNone;
    Exit;
  end;
  if T in [dtULInt, dtLWord] then
  begin
    // all 64 bit (the pattern in an Int64); LWord also negative
    if Neg and (T = dtULInt) then
    begin
      T := dtNone;
      Exit;
    end;
    I := Int64(Q);
    if Neg then I := -I;
    V := Q;
    Exit(True);
  end;
  if Neg then
  begin
    if Q > QWord(High(Int64)) + 1 then
    begin
      T := dtNone;
      Exit;
    end;
    I := -Int64(Q);
  end
  else
  begin
    if Q > QWord(High(Int64)) then
    begin
      T := dtNone;
      Exit;
    end;
    I := Q;
  end;
  if (I < Lo) or (I > Hi) then
  begin
    T := dtNone;
    Exit;
  end;
  V := I;
  Result := True;
end;

function StringMaxOf(const TypeText: string): Integer;
var
  U: string;
  P, Q, Lim: Integer;
begin
  U := UpperCase(Trim(TypeText));
  if Copy(U, 1, 6) = 'ARRAY[' then
  begin
    P := Pos(' OF ', U);
    if P = 0 then Exit(-1);
    U := Trim(Copy(U, P + 4, MaxInt));
  end;
  if Copy(U, 1, 1) = 'W' then Lim := 16382 else Lim := 254;
  P := Pos('[', U);
  if P = 0 then Exit(254);
  Q := Pos(']', U);
  if (Q < P) or (Trim(Copy(U, Q + 1, MaxInt)) <> '') or not TryStrToInt(Trim(Copy(U, P + 1, Q - P - 1)), Result) or
    (Result < 1) or (Result > Lim) then
    Result := -1;
end;

{ a character code as UTF-8 bytes (kept as bytes in any string) }
function CodeUtf8(H: Integer): string;
begin
  if H < $80 then Result := Chr(H)
  else if H < $800 then Result := Chr($C0 or (H shr 6)) + Chr($80 or (H and $3F))
  else Result := Chr($E0 or (H shr 12)) + Chr($80 or ((H shr 6) and $3F)) + Chr($80 or (H and $3F));
end;

function SclStrDecode(const S: string; Wide: Boolean): string;
var
  K, H, Nd: Integer;
begin
  Result := '';
  K := 1;
  while K <= Length(S) do
  begin
    if (S[K] = '''') and (K < Length(S)) and (S[K + 1] = '''') then
    begin
      Result := Result + '''';
      Inc(K, 2);
      Continue;
    end;
    if (S[K] = '$') and (K < Length(S)) then
    begin
      Inc(K);
      case UpCase(S[K]) of
        'N', 'L': Result := Result + #10;
        'R': Result := Result + #13;
        'T': Result := Result + #9;
        'P': Result := Result + #12;
        '$': Result := Result + '$';
        '''': Result := Result + '''';
      else
        if Wide then Nd := 4 else Nd := 2;
        if (K + Nd - 1 <= Length(S)) and TryStrToInt('$' + Copy(S, K, Nd), H) then
        begin
          Result := Result + CodeUtf8(H);
          Inc(K, Nd - 1);
        end
        else
          Result := Result + S[K];
      end;
      Inc(K);
      Continue;
    end;
    Result := Result + S[K];
    Inc(K);
  end;
end;

function ParseStartValue(const S: string; out C: TConst): Boolean;
var
  V: Double;
  T: TDataType;
  Sg: Single;
  I: Int64;
  Q: QWord;
begin
  Result := ParseConst(S, C);
  if Result then Exit;
  FillChar(C, SizeOf(C), 0);
  if TryStrToInt64(Trim(S), I) and (I > 2147483647) and (I <= 4294967295) then
  begin
    // a UDInt / DWord number
    C.Kind := ckDInt;
    C.I := I;
    C.Bits := LongWord(I);
    C.Size := osDWord;
    Exit(True);
  end;
  if TryStrToQWord(Trim(S), Q) then
  begin
    // a 64 bit number: the pattern in I
    C.Kind := ckDInt;
    C.I := Int64(Q);
    C.Bits := LongWord(Q);
    C.Size := osDWord;
    Exit(True);
  end;
  if not SclTypedLiteralEx(S, V, I, T) then Exit;
  if T in Int64Types then
  begin
    C.Kind := ckDInt;
    C.I := I;
    C.R := V;
    C.Bits := LongWord(I);
    C.Size := osDWord;
    Exit(True);
  end;
  if T in RealTypes then
  begin
    C.Kind := ckReal;
    C.R := V;
    Sg := V;
    C.Bits := PLongWord(@Sg)^;
  end
  else
  begin
    C.Kind := ckDInt;
    C.I := Round(V);
    C.Bits := LongWord(C.I and $FFFFFFFF);
  end;
  C.Size := osDWord;
  Result := True;
end;

function ArrayStartOf(const Start: string; N, E: Integer): string;
var
  L: TStringArray;
begin
  Result := '';
  if (E < 0) or (E >= N) then Exit;
  if Copy(Trim(Start), 1, 1) = '[' then
  begin
    L := ExpandInitList(Start);
    if E <= High(L) then Result := L[E];
  end
  else
    Result := Trim(Start);
end;

function ArrayStartSet(const Start: string; N, E: Integer; const Val, Def: string): string;
var
  L: TStringArray;
  K, Run: Integer;

  function Item(J: Integer): string;
  begin
    if (J <= High(L)) and (Trim(L[J]) <> '') then Result := Trim(L[J]) else Result := Def;
  end;

begin
  Result := Trim(Start);
  if (E < 0) or (E >= N) or (N <= 0) then Exit;
  SetLength(L, N);
  for K := 0 to N - 1 do L[K] := ArrayStartOf(Start, N, K);
  L[E] := Trim(Val);
  // all the same: one value (the default: none)
  K := 1;
  while (K < N) and (Item(K) = Item(0)) do Inc(K);
  if K = N then
  begin
    if SameText(Item(0), Def) then Exit('') else Exit(Item(0));
  end;
  Result := '';
  K := 0;
  while K < N do
  begin
    Run := 1;
    while (K + Run < N) and (Item(K + Run) = Item(K)) do Inc(Run);
    if Result <> '' then Result := Result + ', ';
    if Run > 1 then Result := Result + Format('%d(%s)', [Run, Item(K)]) else Result := Result + Item(K);
    Inc(K, Run);
  end;
  Result := '[' + Result + ']';
end;

function ExpandInitList(const S: string): TStringArray;
var
  U, It: string;
  K, N, Q, Cnt, Depth: Integer;
  InStr: Boolean;

  procedure Add(const V: string; Times: Integer);
  var
    J: Integer;
  begin
    for J := 1 to Times do
    begin
      if N > 100000 then Exit;
      SetLength(Result, N + 1);
      Result[N] := V;
      Inc(N);
    end;
  end;

  procedure Item(It: string);
  begin
    It := Trim(It);
    if It = '' then Exit;
    // n(v): v repeated n times
    Q := Pos('(', It);
    if (Q > 1) and (It[Length(It)] = ')') and TryStrToInt(Trim(Copy(It, 1, Q - 1)), Cnt) and (Cnt > 0) then
      Add(Trim(Copy(It, Q + 1, Length(It) - Q - 1)), Cnt)
    else
      Add(It, 1);
  end;

begin
  Result := nil;
  N := 0;
  U := Trim(S);
  if (U = '') or (U[1] <> '[') then Exit;
  Delete(U, 1, 1);
  if (U <> '') and (U[Length(U)] = ']') then SetLength(U, Length(U) - 1);
  It := '';
  Depth := 0;
  InStr := False;
  for K := 1 to Length(U) do
  begin
    if U[K] = '''' then InStr := not InStr;
    if not InStr then
    begin
      if U[K] = '(' then Inc(Depth) else if U[K] = ')' then Dec(Depth);
      if (U[K] = ',') and (Depth = 0) then
      begin
        Item(It);
        It := '';
        Continue;
      end;
    end;
    It := It + U[K];
  end;
  Item(It);
end;

function ParseDataType(const S: string; out T: TDataType; out ArrLo, ArrHi: Integer): Boolean;
var
  U: string;
  P: Integer;
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
    if not ArrayRange(U, ArrLo, ArrHi) then Exit;
    U := Trim(Copy(U, P + 1, MaxInt));
    if Copy(U, 1, 3) <> 'OF ' then Exit;
    U := Trim(Copy(U, 4, MaxInt));
  end;
  if U = 'TOD' then U := 'TIME_OF_DAY';
  if U = 'BOOLEAN' then U := 'BOOL';
  if U = 'LTOD' then U := 'LTIME_OF_DAY';
  if U = 'DT' then U := 'DATE_AND_TIME';
  if U = 'LDATE_AND_TIME' then U := 'LDT';
  // the system FBs of the S7-1200 / 1500: an IEC timer / counter whose call names the instruction
  case SysFbMethod(U) of
    'TON', 'TOF', 'TP', 'TONR':
      begin
        T := dtIECTimer;
        Exit(True);
      end;
    'CTU', 'CTD', 'CTUD':
      begin
        T := dtIECCounter;
        Exit(True);
      end;
  end;
  // strings: String, String[20], WString[100]; WChar
  if U = 'WCHAR' then
  begin
    T := dtWChar;
    Exit(True);
  end;
  if (U = 'STRING') or (Copy(U, 1, 7) = 'STRING[') or (U = 'WSTRING') or (Copy(U, 1, 8) = 'WSTRING[') then
  begin
    if StringMaxOf(U) < 0 then Exit;
    if U[1] = 'W' then T := dtWString else T := dtString;
    Exit(True);
  end;
  for D := Succ(dtNone) to High(TDataType) do
    if not (D in [dtStruct, dtString, dtWString]) and (UpperCase(DataTypeNames[D]) = U) then
    begin
      T := D;
      Result := True;
      Exit;
    end;
end;

{ Array[lo..hi] of <Elem>: False for a malformed array, Lo > Hi and Elem = S when S is no array }
function SplitArrayType(const S: string; out ArrLo, ArrHi: Integer; out Elem: string): Boolean;
var
  U: string;
  P: Integer;
begin
  Result := False;
  ArrLo := 0;
  ArrHi := -1;
  Elem := Trim(S);
  U := UpperCase(Elem);
  if Copy(U, 1, 6) <> 'ARRAY[' then Exit(True);
  P := Pos(']', U);
  if P = 0 then Exit;
  if not ArrayRange(U, ArrLo, ArrHi) then Exit;
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
