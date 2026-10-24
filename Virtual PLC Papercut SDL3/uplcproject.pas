unit uPlcProject;

{ Virtual PLC project: the offline data the user edits.

  Blocks      OB1 (main cycle), OB35 / OB30 (cyclic interrupt), OB100 (startup), FCs, FBs
  FB          a function block with an interface (Input, Output, InOut, Static, Temp);
              its data lives in an instance DB (InstanceOf = FB number, the variables
              follow the interface) or as a multi-instance: a Static of the FB type
  Networks    LAD (a grid of cells, Cols columns (LadCols .. MaxLadCols), power flows left to right) or
              STL (instruction list text, S7-300/400 only)
  Data blocks typed variables, laid out like a standard (non optimized) S7 DB:
              Bool packed into bits, Byte types on a byte, everything bigger and
              every array / struct on an even byte
  Data types  PLC data types (UDT): a struct with typed members, used in DBs and
              VAR_TEMP as "Name" or UDTn, also as Array[lo..hi] of "Name"
  Tags        the PLC tag table (symbol table): name, type, absolute address
  Watch       the watch and force table
  I/O panel   switch types of the digital inputs, generator of each analog input

  LAD cells: a cell holds one element. Down = a vertical link on the right edge
  of the cell to the same edge of the row below (branches open and close there).
  Operands (Opnd, P[0..4]) are text: absolute addresses, "Tags", "DB".Var and
  constants; they are resolved when the program is compiled.

  File format: JSON (.vplc). }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, fpjson, jsonparser, uPlcTypes, uObCatalog;

const
  LadCols = 8;        // the columns of a new LAD network (and how many show at a time)
  MaxLadCols = 32;    // a network grows to the right up to this
  MaxLadRows = 8;

type
  TNetKind = (nkLAD, nkSTL, nkSCL, nkFBD, nkCFC);
  TLadKind = (lkEmpty, lkWire, lkNO, lkNC, lkPos, lkNeg, lkNot, lkCoil, lkCoilNeg, lkSet, lkReset,
    lkTON, lkTOF, lkTP, lkTONR, lkSD, lkSE, lkSP, lkSS, lkSF, lkCU, lkCD, lkSC,
    lkCTU, lkCTD, lkCTUD, lkCmp, lkMove, lkAdd, lkSub, lkMul, lkDiv, lkNormX, lkScaleX, lkCall,
    lkInRange, lkOutRange, lkConv, lkRound, lkTrunc, lkCeil, lkFloor,
    // the boxes of the SCL functions (compiled as SCL): selection, math, shift / word logic, string, edges
    lkSel, lkMux, lkLimit, lkMin, lkMax, lkSqrt, lkSqr, lkAbs, lkExp, lkLn, lkSin, lkCos, lkTan, lkAsin, lkAcos, lkAtan, lkFrac, lkNegate, lkExpt, lkMod, lkInc, lkDec, lkShl, lkShr, lkRol, lkRor, lkAndW, lkOrW, lkXorW, lkInvW, lkConcat, lkLen, lkLeft, lkRight, lkMid, lkFind, lkSMove, lkRTrig, lkFTrig, lkRS, lkSR);
  TCmpOp = (coEQ, coNE, coGT, coLT, coGE, coLE);
  TBlockKind = (bkOB, bkFC, bkFB);
  TIntArray = array of Integer;
  { interface sections of a block, in the order of the instance DB / the FC parameter area;
    vsReturn: the function value of an FC (#Ret_Val) }
  TVarSection = (vsInput, vsOutput, vsInOut, vsStatic, vsTemp, vsReturn);
  TDispFmt = (dfBool, dfDec, dfHex, dfBin, dfReal, dfTime, dfS5Time, dfCounter, dfChar);
  TInType = (itToggle, itPushNO, itPushNC);
  TAiMode = (amManual, amSine, amRamp);

  TLadCell = record
    Kind: TLadKind;
    Opnd: string;
    P: array[0..4] of string;
    DType: TDataType;
    DType2: TDataType;  // CONV, ROUND, TRUNC, CEIL, FLOOR: the type of OUT (DType is the one of IN)
    Cmp: TCmpOp;
    Down: Boolean;
    Args: string;     // lkCall: the actual parameters in pin order (CallPins), separated by |
  end;

  { FBD / CFC: a box (node) with its pins. An input pin has an operand / a constant, or a wire from an
    output pin of another box (Src: its Id, SrcPin: the index of the output); an output pin may write an
    operand. The box ids are those of uFbd (and, or, ton, add ..) }
  TFbdPin = record
    Name: string;
    Opnd: string;
    Src, SrcPin: Integer;   // Src = 0: no wire
    Neg: Boolean;           // an input: negated (the small circle)
  end;
  TFbdPins = array of TFbdPin;
  TFbdNode = record
    Id: Integer;            // > 0, unique in the network
    Box: string;
    Inst: string;           // above the box: the instance (timers, counters, edges), the operand (=, S, R, P, N,
                            // INC, DEC), the block (CALL)
    DType, DType2: TDataType;
    Cmp: TCmpOp;
    Ins, Outs: TFbdPins;
    X, Y: Integer;          // CFC: the place on the chart (grid units of 10 px)
    Order: Integer;         // CFC: the execution order (1 ..)
  end;
  TFbdNodes = array of TFbdNode;

  { TNetwork }

  TNetwork = class
  public
    Title, Comment: string;
    Kind: TNetKind;
    Rows: Integer;
    Cols: Integer;              // LAD: columns (LadCols .. MaxLadCols)
    Cells: array of TLadCell;   // Rows * Cols, row by row
    Stl: TStringList;
    Nodes: TFbdNodes;           // FBD / CFC: the boxes
    ChartW, ChartH: Integer;    // CFC: the size of the chart (grid units)
    function NodeIndex(Id: Integer): Integer;   // -1: none
    function NewNodeId: Integer;
    constructor Create(AKind: TNetKind);
    destructor Destroy; override;
    function Cell(R, C: Integer): TLadCell;
    function CellPtr(R, C: Integer): Pointer;
    procedure SetCell(R, C: Integer; const V: TLadCell);
    procedure SetRows(N: Integer);
    procedure SetCols(N: Integer);       // the cells keep their row and column
    function LastUsedCol: Integer;       // -1: an empty network
    procedure InsertRow(R: Integer);
    procedure DeleteRow(R: Integer);
    procedure Assign(Src: TNetwork);
  end;

  TDataBlock = class;
  TPlcProject = class;

  { TBlock }

  TBlock = class
  public
    Kind: TBlockKind;
    Number: Integer;
    Name, Comment: string;
    Version: string;   // VERSION : 0.1 of the SCL source
    Networks: TList;   // of TNetwork
    Iface: TDataBlock; // the interface: Vars with Section; an FB's instance layout (temps in TempSize)
    { an OB: its event (-1: the one of its standard number) and the settings of its event }
    ObEvent: Integer;
    CycleMs, PhaseMs: Integer;   // a cyclic interrupt (0: the default of its number)
    TrigAddr: string;            // a hardware interrupt: the input bit (%I0.0) ..
    TrigEdge: Integer;           // .. 0 rising, 1 falling, 2 both edges
    TodStart: string;            // a time of day interrupt: 'yyyy-mm-dd hh:nn:ss' ..
    TodMode: Integer;            // .. TodModeNames
    TodActive: Boolean;
    constructor Create(AKind: TBlockKind; ANumber: Integer; const AName: string);
    destructor Destroy; override;
    function Net(I: Integer): TNetwork;
    function NetCount: Integer;
    function AddNet(AKind: TNetKind): TNetwork;
    procedure DeleteNet(I: Integer);
    function Title: string;   // OB1 "Main"
  end;

  TDbVar = record
    Name, TypeText, Start, Comment: string;
    Retain: Boolean;
    Section: TVarSection;   // block interfaces only
    { from Layout }
    DType: TDataType;
    Udt: TDataBlock;        // DType = dtStruct: the PLC data type
    IsArray: Boolean;
    Lo, Hi: Integer;
    Dims: TArrDims;         // an array of more dimensions (Lo..Hi is then 0..n-1)
    Ofs, Bit: Integer;
    Valid: Boolean;
    System: Boolean;        // the start information of an OB: written by the CPU, not edited, not saved
  end;

  { TDataBlock }

  { a data block, or a PLC data type (IsUdt: Vars are its members, offsets from the struct start) }
  TDataBlock = class
  private
    FBusy: Boolean;
  public
    Number: Integer;
    Name, Comment: string;
    Optimized: Boolean;
    IsUdt: Boolean;
    IsIface: Boolean;         // the interface of a block (also IsUdt: an FB type is a struct)
    IsFC: Boolean;            // an FC interface: the parameters are in the local data, the Temps after them
    StrMax: Integer;          // > 0: the type of a String[StrMax] / WString[StrMax] (StrWide), no Vars
    StrWide: Boolean;
    IecVar: TDataType;        // <> dtNone: a timer (dtLTime) / counter (its PV / CV type) of another layout
    InstanceOf: Integer;      // an instance DB: the FB number, its Vars follow the interface
    Owner: TPlcProject;       // resolves the names of PLC data types
    Vars: array of TDbVar;
    Size: Integer;            // bytes, from Layout
    TempSize: Integer;        // IsIface: bytes of the Temp section (local data)
    constructor Create(ANumber: Integer; const AName: string);
    procedure AddVar(const AName, AType, AStart, AComment: string);
    { an interface variable: inserted at the end of its section }
    function AddSecVar(ASec: TVarSection; const AName, AType, AStart, AComment: string): Integer;
    procedure SortSections;
    procedure DeleteVar(I: Integer);
    procedure Layout;
    function FindVar(const AName: string): Integer;
  end;

  TTag = record
    Name, TypeText, Address, Comment: string;
    GroupId: Integer;     // its group of the tag table (0: none, only in "All tag")
  end;

  { a group of the tag table / of the watch table (a tree item): the rows keep its Id, so a group can
    be renamed (also to a name used twice: shown red) or deleted without losing a row }
  TItemGroup = record
    Id: Integer;
    Name: string;
  end;
  TItemGroups = array of TItemGroup;

  { a simulated input signal (the signal table of the I/O screen): its generator writes the input module }
  TSigKind = (sgConst, sgSquare, sgSine, sgTriangle, sgRamp, sgRandom, sgStep);
  TSimSignal = record
    Address: string;     // an input (I / PI): an address or a tag
    Kind: TSigKind;
    Lo, Hi: Double;      // the two values (Bool: 0 / 1)
    PeriodMs: Double;
    Duty: Double;        // Square: the % of the period at Hi
    On: Boolean;
    Comment: string;
  end;

  TWatchRow = record
    Address: string;
    Fmt: TDispFmt;
    ModifyValue: string;
    ModifyOn: Boolean;
    ForceOn: Boolean;
    GroupId: Integer;     // its group of the watch table (0: none)
  end;

  { the simulated communication ports (uPlcServer) }
  TCommSettings = record
    S7On: Boolean;
    S7Port: Integer;        // 102 = ISO-on-TCP
    MbOn: Boolean;
    MbPort: Integer;        // 502
    MbUnit: Integer;
    MbHRArea: TArea;        // holding registers: arM (MW) or arDB (DBn.DBW)
    MbHRDB: Integer;
    PutGet: Boolean;        // S7-1200: permit PUT/GET communication from remote partners
    AllIfaces: Boolean;     // listen on every network interface, else 127.0.0.1 only
    IpAddr: string;         // where the servers listen: 127.0.0.1, 0.0.0.0 (all) or an address of this PC
    Mask: string;           // the subnet mask of the interface (shown, saved)
    IpcOn: Boolean;         // the IPC server (the named pipe \\.\pipe\VirtualPLC) for programs on this PC
    McpWrite: Boolean;      // Claude Code (MCP, through the IPC server) may change the program, download and run
  end;

  TIoChannel = record
    InType: TInType;
    AiMode: TAiMode;
    AiValue: Integer;   // manual raw value 0..27648
  end;

  { TPlcProject }

  TPlcProject = class
  public
    Name, FileName, Author, Comment: string;
    ModelIdx: Integer;
    CyclicMs: Integer;
    ClockByte: Integer;       // clock memory byte, -1 = off
    Blocks: TList;            // of TBlock
    DBs: TList;               // of TDataBlock
    Udts: TList;              // of TDataBlock with IsUdt: the PLC data types
    Tags: array of TTag;
    Watch: array of TWatchRow;
    TagGroups, WatchGroups: TItemGroups;
    Signals: array of TSimSignal;   // the signal table of the I/O screen
    DIch: array[0..63] of TIoChannel;
    AIch: array[0..15] of TIoChannel;
    Modified: Boolean;
    Comm: TCommSettings;
    constructor Create;
    destructor Destroy; override;
    procedure Clear;
    function Family: TCpuFamily;
    function Model: TCpuModel;
    function Block(I: Integer): TBlock;
    function BlockCount: Integer;
    function FindBlock(AKind: TBlockKind; ANumber: Integer): TBlock;
    function AddBlock(AKind: TBlockKind; ANumber: Integer; const AName: string): TBlock;
    procedure DeleteBlock(I: Integer);
    function DB(I: Integer): TDataBlock;
    function DBCount: Integer;
    function FindDB(ANumber: Integer): TDataBlock;
    function FindDBByName(const AName: string): TDataBlock;
    function AddDB(ANumber: Integer; const AName: string): TDataBlock;
    procedure DeleteDB(I: Integer);
    function Udt(I: Integer): TDataBlock;
    function UdtCount: Integer;
    function FindUdt(const AName: string): TDataBlock;   // "Name", Name or UDTn
    function AddUdt(ANumber: Integer; const AName: string): TDataBlock;
    procedure DeleteUdt(I: Integer);
    function UdtTypeName(U: TDataBlock): string;         // "Name" (TIA) or UDTn
    function FindFB(const ARef: string): TBlock;          // "Name" or FBn
    function InstanceFB(D: TDataBlock): TBlock;           // the FB of an instance DB, nil for a global DB
    { an elementary type, a PLC data type, or an array of one of them }
    function ParseVarType(const S: string; out T: TDataType; out Lo, Hi: Integer; out AUdt: TDataBlock): Boolean;
    function FindTag(const AName: string): Integer;
    procedure AddTag(const AName, AType, AAddress, AComment: string);
    procedure DeleteTag(I: Integer);
    procedure DeleteTagGroup(I: Integer);     // its tags stay (no group)
    procedure DeleteWatchGroup(I: Integer);   // its rows stay
    procedure AddWatch(const AAddress: string; AFmt: TDispFmt; const AModify: string = '');
    function WatchToJson: TJSONArray;
    procedure WatchFromJson(A: TJSONArray);
    procedure SaveWatchFile(const AFile: string);   // a watch table on its own
    procedure LoadWatchFile(const AFile: string);   // replaces the rows
    procedure DeleteWatch(I: Integer);
    function AddSignal(const AAddress: string; AKind: TSigKind; ALo, AHi, APeriod, ADuty: Double): Integer;
    procedure DeleteSignal(I: Integer);
    procedure SortBlocks;
    function CyclicOB: Integer;
    { an OB: its start information in the interface (after the CPU family changed, a load, an import) }
    procedure SyncObIface(B: TBlock);
    procedure SyncObIfaces;
    function ObEventOfBlock(B: TBlock): TObEvent;
    function ObCycleMs(B: TBlock): Integer;   // a cyclic interrupt OB: its cycle time
    procedure SaveToFile(const AFile: string);
    procedure LoadFromFile(const AFile: string);
    function ToJsonText(Pretty: Boolean = True): string;   // the project file's text
    procedure LoadFromJsonText(const S: string);           // FileName stays
    procedure NewEmpty(AModel: Integer);
    procedure LoadSample(AModel: Integer);
  end;

const
  LadKindNames: array[TLadKind] of string = ('', 'wire', 'NO contact', 'NC contact', 'P contact',
    'N contact', 'NOT', 'Coil', 'Negated coil', 'Set coil', 'Reset coil',
    'TON', 'TOF', 'TP', 'TONR', 'SD on-delay', 'SE ext. pulse', 'SP pulse', 'SS ret. on-delay',
    'SF off-delay', 'CU count up', 'CD count down', 'SC set counter',
    'CTU', 'CTD', 'CTUD', 'CMP', 'MOVE', 'ADD', 'SUB', 'MUL', 'DIV', 'NORM_X', 'SCALE_X', 'CALL',
    'IN_RANGE', 'OUT_RANGE', 'CONV', 'ROUND', 'TRUNC', 'CEIL', 'FLOOR',
    'SEL', 'MUX', 'LIMIT', 'MIN', 'MAX', 'SQRT', 'SQR', 'ABS', 'EXP', 'LN', 'SIN', 'COS', 'TAN', 'ASIN', 'ACOS', 'ATAN', 'FRAC', 'NEG', 'EXPT', 'MOD', 'INC', 'DEC', 'SHL', 'SHR', 'ROL', 'ROR', 'AND', 'OR', 'XOR', 'INV', 'CONCAT', 'LEN', 'LEFT', 'RIGHT', 'MID', 'FIND', 'S_MOVE', 'R_TRIG', 'F_TRIG', 'RS', 'SR');
  LadKindIds: array[TLadKind] of string = ('', 'wire', 'no', 'nc', 'p', 'n', 'not', 'coil', 'ncoil',
    'set', 'reset', 'ton', 'tof', 'tp', 'tonr', 'sd', 'se', 'sp', 'ss', 'sf', 'cu', 'cd', 'sc',
    'ctu', 'ctd', 'ctud', 'cmp', 'move', 'add', 'sub', 'mul', 'div', 'normx', 'scalex', 'call',
    'inrange', 'outrange', 'conv', 'round', 'trunc', 'ceil', 'floor',
    'sel', 'mux', 'limit', 'min', 'max', 'sqrt', 'sqr', 'abs', 'exp', 'ln', 'sin', 'cos', 'tan', 'asin', 'acos', 'atan', 'frac', 'negate', 'expt', 'mod', 'inc', 'dec', 'shl', 'shr', 'rol', 'ror', 'andw', 'orw', 'xorw', 'invw', 'concat', 'len', 'left', 'right', 'mid', 'find', 'smove', 'rtrig', 'ftrig', 'rs', 'sr');
  CmpOpNames: array[TCmpOp] of string = ('==', '<>', '>', '<', '>=', '<=');
  DispFmtNames: array[TDispFmt] of string = ('BOOL', 'DEC', 'HEX', 'BIN', 'REAL', 'TIME', 'S5TIME',
    'COUNTER', 'CHAR');
  InTypeNames: array[TInType] of string = ('switch', 'push NO', 'push NC');
  AiModeNames: array[TAiMode] of string = ('manual', 'sine', 'ramp');

function DefaultComm: TCommSettings;
function HoldingText(const C: TCommSettings): string;
function IsIPv4(const S: string): Boolean;         // a.b.c.d, each 0..255
function CommIp(const C: TCommSettings): string;    // the listen address (from the older AllIfaces too)
function SetHolding(var C: TCommSettings; const S: string): Boolean;
function IsBox(K: TLadKind): Boolean;
{ a box of an SCL function (SEL .. SR): compiled as SCL, its EN / CLK is the rung, ENO / Q the power out }
function IsSclBox(K: TLadKind): Boolean;
function LadHasType(K: TLadKind): Boolean;    // a box with a data type (DType)
function LadHasType2(K: TLadKind): Boolean;   // ... and a second one for OUT (DType2): the converters
function IsCoilKind(K: TLadKind): Boolean;
{ parameter names of an element: index -1 = Opnd, 0..4 = P[] }
function LadParamCount(K: TLadKind): Integer;
function LadParamName(K: TLadKind; I: Integer): string;
function LadOpndName(K: TLadKind): string;
function EmptyCell: TLadCell;
function NewCell(K: TLadKind; const AOpnd: string): TLadCell;

{ FBD / CFC: a copy of the boxes (their pins copied too); the JSON of the boxes (into / from a network
  object of the project file); the name of a language }
function CopyNodes(const A: TFbdNodes): TFbdNodes;
procedure NodesToJson(N: TNetwork; Obj: TJSONObject);
procedure NodesFromJson(N: TNetwork; Obj: TJSONObject);
function NetLangName(K: TNetKind): string;

{ the pins of a CALL box: the parameters of the block in the order Input, InOut, Output, Return
  (indexes into Blk.Iface.Vars) }
function CallPins(Blk: TBlock): TIntArray;
function CallArg(const Ce: TLadCell; I: Integer): string;
procedure SetCallArg(var Ce: TLadCell; I: Integer; const S: string);

{ the stride of one array element in bytes (0 = Bool, packed bits) }
function ElemStride(T: TDataType; AUdt: TDataBlock): Integer;
function SysUdt(const AName: string): TDataBlock;     // R_TRIG, F_TRIG, RS, SR, DTL (nil: none)
{ the type of a String[Max] / WString[Max]: its size (2 + Max bytes, 4 + 2 * Max) in a TDataBlock }
function StrUdt(AMax: Integer; Wide: Boolean): TDataBlock;
{ the layout of TON_LTIME (PT 0, ET 8, IN 16.0, Q 16.1) and of the counters of other types (CTU_DINT:
  the bits in byte 0, PV at 2, CV after it); nil for the IEC_TIMER / IEC_COUNTER layout }
function IecUdt(const TypeText: string): TDataBlock;
{ a counter / timer layout: the offsets of PV / CV, of ET and of the IN / Q byte }
procedure IecOffsets(U: TDataBlock; IsTimer: Boolean; out OPv, OCv, OEt, OBits: Integer; out VT: TDataType);
{ R_TRIG, F_TRIG, RS, SR: called like an FB (DTL is a struct only) }
function IsSysFb(U: TDataBlock): Boolean;
function IsSysUdt(U: TDataBlock): Boolean;
{ a block gets another name: every "Old" of the program (SCL / STL text, LAD operands and parameters,
  CALL boxes, the FB types of multi-instances) becomes "New", in the FC itself also #Old (its value);
  the number of the places changed }
function RenameBlockInCode(P: TPlcProject; B: TBlock; const NewName: string): Integer;

{ the groups: a new one (its index; a new Id), the index of an Id (-1), the name used by another group }
function GroupAdd(var G: TItemGroups; const AName: string): Integer;
function GroupOfId(const G: TItemGroups; Id: Integer): Integer;
function GroupNameTwice(const G: TItemGroups; I: Integer): Boolean;
{ a name a group can have: not empty, not the name of the root ("All tag" / "All rows") }
function GroupNameOk(const AName, Root: string; out Err: string): Boolean;
function GroupsToJson(const G: TItemGroups): TJSONArray;
procedure GroupsFromJson(A: TJSONArray; var G: TItemGroups);

const
  AllTagsName = 'All tag';      // the root of the tag table's tree: every tag, cannot be renamed or deleted
  AllWatchName = 'All rows';    // the root of the watch table's tree
  SectionNames: array[TVarSection] of string = ('Input', 'Output', 'InOut', 'Static', 'Temp', 'Return');
  SigKindNames: array[TSigKind] of string = ('Constant', 'Square', 'Sine', 'Triangle', 'Ramp', 'Random', 'Step');

{ the value of a signal at the time T (s): its generator (Rnd: the random value of the period) }
function SignalValue(const S: TSimSignal; T: Double; Rnd: Double): Double;

{ the JSON of one block / network / data block (data type: AsType), as in the project file }
function BlockToJson(B: TBlock): TJSONObject;
function NetToJson(N: TNetwork): TJSONObject;
function DataBlockToJson(D: TDataBlock; AsType: Boolean): TJSONObject;

implementation

function ElemStride(T: TDataType; AUdt: TDataBlock): Integer;
begin
  if (T = dtStruct) and (AUdt <> nil) then Exit(AUdt.Size);
  // the elements of a string array start on an even byte
  if (T in [dtString, dtWString, dtIECTimer, dtIECCounter]) and (AUdt <> nil) then Exit((AUdt.Size + 1) div 2 * 2);
  Result := DataTypeSize(T);
  if Result >= 2 then Result := (Result + 1) div 2 * 2;
end;

function DefaultComm: TCommSettings;
begin
  Result.S7On := True;
  Result.S7Port := 102;
  Result.MbOn := True;
  Result.MbPort := 502;
  Result.MbUnit := 1;
  Result.MbHRArea := arM;
  Result.MbHRDB := 0;
  Result.PutGet := False;
  Result.AllIfaces := False;
  Result.IpAddr := '127.0.0.1';
  Result.Mask := '255.255.255.0';
  Result.IpcOn := False;
  Result.McpWrite := False;
end;

function IsIPv4(const S: string): Boolean;
var
  K, N, V, Dots: Integer;
  T: string;
begin
  Result := False;
  T := Trim(S);
  if T = '' then Exit;
  Dots := 0;
  N := 0;
  V := 0;
  for K := 1 to Length(T) do
    if T[K] = '.' then
    begin
      if N = 0 then Exit;
      Inc(Dots);
      N := 0;
      V := 0;
    end
    else if T[K] in ['0'..'9'] then
    begin
      Inc(N);
      V := V * 10 + Ord(T[K]) - 48;
      if (N > 3) or (V > 255) then Exit;
    end
    else
      Exit;
  Result := (Dots = 3) and (N > 0);
end;

function CommIp(const C: TCommSettings): string;
begin
  Result := Trim(C.IpAddr);
  if not IsIPv4(Result) then
    if C.AllIfaces then Result := '0.0.0.0' else Result := '127.0.0.1';
end;

function HoldingText(const C: TCommSettings): string;
begin
  if C.MbHRArea = arDB then Result := 'DB' + IntToStr(C.MbHRDB) else Result := 'M';
end;

function SetHolding(var C: TCommSettings; const S: string): Boolean;
var
  U: string;
  N: Integer;
begin
  U := UpperCase(Trim(S));
  Result := True;
  if (U = 'M') or (U = 'MW') then
  begin
    C.MbHRArea := arM;
    C.MbHRDB := 0;
  end
  else if (Copy(U, 1, 2) = 'DB') and TryStrToInt(Copy(U, 3, MaxInt), N) and (N > 0) then
  begin
    C.MbHRArea := arDB;
    C.MbHRDB := N;
  end
  else
    Result := False;
end;

function IsBox(K: TLadKind): Boolean;
begin
  Result := (K in [lkTON, lkTOF, lkTP, lkTONR, lkCTU, lkCTD, lkCTUD, lkCmp, lkMove, lkAdd, lkSub,
    lkMul, lkDiv, lkNormX, lkScaleX, lkCall, lkInRange, lkOutRange, lkConv, lkRound, lkTrunc, lkCeil, lkFloor]) or
    IsSclBox(K);
end;

function IsSclBox(K: TLadKind): Boolean;
begin
  Result := K >= lkSel;
end;

function LadHasType(K: TLadKind): Boolean;
begin
  Result := K in [lkCmp, lkMove, lkAdd, lkSub, lkMul, lkDiv, lkNormX, lkScaleX, lkInRange, lkOutRange, lkConv,
    lkRound, lkTrunc, lkCeil, lkFloor];
end;

function LadHasType2(K: TLadKind): Boolean;
begin
  Result := K in [lkConv, lkRound, lkTrunc, lkCeil, lkFloor];
end;

function IsCoilKind(K: TLadKind): Boolean;
begin
  Result := K in [lkCoil, lkCoilNeg, lkSet, lkReset, lkSD, lkSE, lkSP, lkSS, lkSF, lkCU, lkCD, lkSC];
end;

function LadOpndName(K: TLadKind): string;
begin
  case K of
    lkTON, lkTOF, lkTP, lkTONR: Result := 'instance (IEC_TIMER)';
    lkCTU, lkCTD, lkCTUD: Result := 'instance (IEC_COUNTER)';
    lkSD, lkSE, lkSP, lkSS, lkSF: Result := 'timer T';
    lkCU, lkCD, lkSC: Result := 'counter C';
    lkCall: Result := 'block (FC, or an FB instance DB)';
    lkRTrig: Result := 'instance (R_TRIG)';
    lkFTrig: Result := 'instance (F_TRIG)';
    lkRS: Result := 'instance (RS)';
    lkSR: Result := 'instance (SR)';
    lkCmp, lkMove, lkAdd, lkSub, lkMul, lkDiv, lkNormX, lkScaleX, lkEmpty, lkWire, lkNot, lkInRange, lkOutRange,
    lkConv, lkRound, lkTrunc, lkCeil, lkFloor: Result := '';
  else
    if IsSclBox(K) then Result := '' else Result := 'operand';
  end;
end;

function LadParamCount(K: TLadKind): Integer;
begin
  case K of
    lkPos, lkNeg: Result := 1;
    lkSD, lkSE, lkSP, lkSS, lkSF, lkSC: Result := 1;
    lkTON, lkTOF, lkTP: Result := 2;
    lkTONR: Result := 3;
    lkCTU, lkCTD: Result := 3;
    lkCTUD: Result := 5;
    lkCmp, lkMove: Result := 2;
    lkAdd, lkSub, lkMul, lkDiv: Result := 3;
    lkNormX, lkScaleX: Result := 4;
    lkInRange, lkOutRange: Result := 3;
    lkConv, lkRound, lkTrunc, lkCeil, lkFloor: Result := 2;
    lkSel, lkLimit, lkMid: Result := 4;
    lkMux, lkMin, lkMax: Result := 5;
    lkSqrt..lkFrac, lkNegate, lkInvW, lkLen, lkSMove: Result := 2;
    lkExpt, lkMod, lkShl..lkXorW, lkConcat, lkLeft, lkRight, lkFind: Result := 3;
    lkInc, lkDec, lkRS, lkSR: Result := 1;
  else
    Result := 0;
  end;
end;

function LadParamName(K: TLadKind; I: Integer): string;
begin
  Result := '';
  case K of
    lkPos, lkNeg: Result := 'edge memory bit';
    lkSD, lkSE, lkSP, lkSS, lkSF: Result := 'time value (S5T#)';
    lkSC: Result := 'preset (C#)';
    lkTON, lkTOF, lkTP:
      case I of 0: Result := 'PT'; 1: Result := 'ET'; end;
    lkTONR:
      case I of 0: Result := 'PT'; 1: Result := 'R'; 2: Result := 'ET'; end;
    lkCTU:
      case I of 0: Result := 'PV'; 1: Result := 'R'; 2: Result := 'CV'; end;
    lkCTD:
      case I of 0: Result := 'PV'; 1: Result := 'LD'; 2: Result := 'CV'; end;
    lkCTUD:
      case I of 0: Result := 'PV'; 1: Result := 'CD'; 2: Result := 'R'; 3: Result := 'LD'; 4: Result := 'CV'; end;
    lkCmp:
      case I of 0: Result := 'IN1'; 1: Result := 'IN2'; end;
    lkMove:
      case I of 0: Result := 'IN'; 1: Result := 'OUT1'; end;
    lkAdd, lkSub, lkMul, lkDiv:
      case I of 0: Result := 'IN1'; 1: Result := 'IN2'; 2: Result := 'OUT'; end;
    lkNormX, lkScaleX:
      case I of 0: Result := 'MIN'; 1: Result := 'VALUE'; 2: Result := 'MAX'; 3: Result := 'OUT'; end;
    lkInRange, lkOutRange:
      case I of 0: Result := 'MIN'; 1: Result := 'VAL'; 2: Result := 'MAX'; end;
    lkConv, lkRound, lkTrunc, lkCeil, lkFloor:
      case I of 0: Result := 'IN'; 1: Result := 'OUT'; end;
    lkSel:
      case I of 0: Result := 'G'; 1: Result := 'IN0'; 2: Result := 'IN1'; 3: Result := 'OUT'; end;
    lkMux:
      case I of 0: Result := 'K'; 1: Result := 'IN0'; 2: Result := 'IN1'; 3: Result := 'IN2'; 4: Result := 'OUT'; end;
    lkLimit:
      case I of 0: Result := 'MN'; 1: Result := 'IN'; 2: Result := 'MX'; 3: Result := 'OUT'; end;
    lkMin, lkMax:
      case I of 0: Result := 'IN1'; 1: Result := 'IN2'; 2: Result := 'IN3'; 3: Result := 'IN4'; 4: Result := 'OUT'; end;
    lkSqrt..lkFrac, lkNegate, lkInvW, lkLen, lkSMove:
      case I of 0: Result := 'IN'; 1: Result := 'OUT'; end;
    lkExpt, lkMod, lkAndW, lkOrW, lkXorW, lkConcat, lkFind:
      case I of 0: Result := 'IN1'; 1: Result := 'IN2'; 2: Result := 'OUT'; end;
    lkShl..lkRor:
      case I of 0: Result := 'IN'; 1: Result := 'N'; 2: Result := 'OUT'; end;
    lkLeft, lkRight:
      case I of 0: Result := 'IN'; 1: Result := 'L'; 2: Result := 'OUT'; end;
    lkMid:
      case I of 0: Result := 'IN'; 1: Result := 'L'; 2: Result := 'P'; 3: Result := 'OUT'; end;
    lkInc, lkDec: Result := 'IN_OUT';
    lkRS: Result := 'R1';
    lkSR: Result := 'R';
  end;
end;

function CallPins(Blk: TBlock): TIntArray;
const
  Order: array[0..3] of TVarSection = (vsInput, vsInOut, vsOutput, vsReturn);
var
  K, I, N: Integer;
begin
  SetLength(Result, 0);
  if Blk = nil then Exit;
  N := 0;
  for K := 0 to 3 do
    for I := 0 to High(Blk.Iface.Vars) do
      if Blk.Iface.Vars[I].Section = Order[K] then
      begin
        SetLength(Result, N + 1);
        Result[N] := I;
        Inc(N);
      end;
end;

function CallArg(const Ce: TLadCell; I: Integer): string;
var
  S: string;
  K, P: Integer;
begin
  S := Ce.Args;
  for K := 1 to I do
  begin
    P := Pos('|', S);
    if P = 0 then Exit('');
    Delete(S, 1, P);
  end;
  P := Pos('|', S);
  if P > 0 then Result := Copy(S, 1, P - 1) else Result := S;
end;

procedure SetCallArg(var Ce: TLadCell; I: Integer; const S: string);
var
  Parts: array of string;
  K, P, N: Integer;
  T: string;
begin
  T := Ce.Args;
  N := 0;
  SetLength(Parts, 0);
  repeat
    SetLength(Parts, N + 1);
    P := Pos('|', T);
    if P > 0 then
    begin
      Parts[N] := Copy(T, 1, P - 1);
      Delete(T, 1, P);
    end
    else
      Parts[N] := T;
    Inc(N);
  until P = 0;
  while N <= I do
  begin
    SetLength(Parts, N + 1);
    Parts[N] := '';
    Inc(N);
  end;
  Parts[I] := StringReplace(S, '|', '', [rfReplaceAll]);
  // no empty tail
  while (N > 0) and (Parts[N - 1] = '') do Dec(N);
  T := '';
  for K := 0 to N - 1 do
  begin
    if K > 0 then T := T + '|';
    T := T + Parts[K];
  end;
  Ce.Args := T;
end;

function EmptyCell: TLadCell;
var
  I: Integer;
begin
  Result.Kind := lkEmpty;
  Result.Opnd := '';
  Result.Args := '';
  for I := 0 to 4 do Result.P[I] := '';
  Result.DType := dtInt;
  Result.DType2 := dtReal;
  Result.Cmp := coEQ;
  Result.Down := False;
end;

function NewCell(K: TLadKind; const AOpnd: string): TLadCell;
begin
  Result := EmptyCell;
  Result.Kind := K;
  Result.Opnd := AOpnd;
  case K of
    lkTON, lkTOF, lkTP, lkTONR: Result.P[0] := 'T#2S';
    lkSD, lkSE, lkSP, lkSS, lkSF: Result.P[0] := 'S5T#2S';
    lkSC: Result.P[0] := 'C#10';
    lkCTU, lkCTD, lkCTUD: Result.P[0] := '10';
    lkCmp: begin Result.P[0] := 'MW20'; Result.P[1] := '10'; end;
    lkNormX, lkScaleX: Result.DType := dtInt;
    lkInRange, lkOutRange: begin Result.P[0] := '0'; Result.P[2] := '100'; end;
    lkConv: begin Result.DType := dtInt; Result.DType2 := dtReal; end;
    lkRound, lkTrunc, lkCeil, lkFloor: begin Result.DType := dtReal; Result.DType2 := dtDInt; end;
  end;
end;

{ TNetwork }

constructor TNetwork.Create(AKind: TNetKind);
begin
  inherited Create;
  Kind := AKind;
  Stl := TStringList.Create;
  Cols := LadCols;
  SetRows(1);
  ChartW := 120;
  ChartH := 42;
end;

destructor TNetwork.Destroy;
begin
  Stl.Free;
  inherited Destroy;
end;

function TNetwork.Cell(R, C: Integer): TLadCell;
begin
  if (R < 0) or (R >= Rows) or (C < 0) or (C >= Cols) then Exit(EmptyCell);
  Result := Cells[R * Cols + C];
end;

function TNetwork.CellPtr(R, C: Integer): Pointer;
begin
  Result := @Cells[R * Cols + C];
end;

procedure TNetwork.SetCell(R, C: Integer; const V: TLadCell);
begin
  if (R < 0) or (R >= Rows) or (C < 0) or (C >= Cols) then Exit;
  Cells[R * Cols + C] := V;
end;

procedure TNetwork.SetRows(N: Integer);
var
  Old, I: Integer;
begin
  N := EnsureRange(N, 1, MaxLadRows);
  Old := Length(Cells) div Cols;
  SetLength(Cells, N * Cols);
  for I := Old * Cols to N * Cols - 1 do Cells[I] := EmptyCell;
  Rows := N;
end;

procedure TNetwork.SetCols(N: Integer);
var
  Old: array of TLadCell;
  R, C, OldCols: Integer;
begin
  N := EnsureRange(N, LadCols, MaxLadCols);
  if N = Cols then Exit;
  Old := Copy(Cells);
  OldCols := Cols;
  Cols := N;
  SetLength(Cells, Rows * Cols);
  for R := 0 to Rows - 1 do
    for C := 0 to Cols - 1 do
      if C < OldCols then Cells[R * Cols + C] := Old[R * OldCols + C]
      else Cells[R * Cols + C] := EmptyCell;
end;

function TNetwork.LastUsedCol: Integer;
var
  R, C: Integer;
begin
  Result := -1;
  for R := 0 to Rows - 1 do
    for C := Cols - 1 downto Result + 1 do
      if (Cells[R * Cols + C].Kind <> lkEmpty) or Cells[R * Cols + C].Down then
      begin
        Result := C;
        Break;
      end;
end;

procedure TNetwork.InsertRow(R: Integer);
var
  I: Integer;
begin
  if Rows >= MaxLadRows then Exit;
  R := EnsureRange(R, 0, Rows);
  SetRows(Rows + 1);
  for I := (Rows - 1) * Cols - 1 downto R * Cols do Cells[I + Cols] := Cells[I];
  for I := R * Cols to R * Cols + Cols - 1 do Cells[I] := EmptyCell;
end;

procedure TNetwork.DeleteRow(R: Integer);
var
  I: Integer;
begin
  if (Rows <= 1) or (R < 0) or (R >= Rows) then Exit;
  for I := R * Cols to (Rows - 1) * Cols - 1 do Cells[I] := Cells[I + Cols];
  SetLength(Cells, (Rows - 1) * Cols);
  Dec(Rows);
  // a link down from the new last row has nothing to go to
  for I := (Rows - 1) * Cols to Rows * Cols - 1 do Cells[I].Down := False;
end;

procedure TNetwork.Assign(Src: TNetwork);
begin
  Title := Src.Title;
  Comment := Src.Comment;
  Kind := Src.Kind;
  Rows := Src.Rows;
  Cols := Src.Cols;
  Cells := Copy(Src.Cells);
  Stl.Assign(Src.Stl);
  Nodes := CopyNodes(Src.Nodes);
  ChartW := Src.ChartW;
  ChartH := Src.ChartH;
end;

function TNetwork.NodeIndex(Id: Integer): Integer;
var
  K: Integer;
begin
  for K := 0 to High(Nodes) do
    if Nodes[K].Id = Id then Exit(K);
  Result := -1;
end;

function TNetwork.NewNodeId: Integer;
var
  K: Integer;
begin
  Result := 1;
  for K := 0 to High(Nodes) do
    if Nodes[K].Id >= Result then Result := Nodes[K].Id + 1;
end;

function CopyNodes(const A: TFbdNodes): TFbdNodes;
var
  K: Integer;
begin
  // the pins are arrays of their own: copied too (a dynamic array is shared, not copied on a write)
  Result := Copy(A);
  for K := 0 to High(Result) do
  begin
    Result[K].Ins := Copy(A[K].Ins);
    Result[K].Outs := Copy(A[K].Outs);
  end;
end;

function NetLangName(K: TNetKind): string;
begin
  case K of
    nkSTL: Result := 'STL';
    nkSCL: Result := 'SCL';
    nkFBD: Result := 'FBD';
    nkCFC: Result := 'CFC';
  else
    Result := 'LAD';
  end;
end;

procedure NodesToJson(N: TNetwork; Obj: TJSONObject);
var
  A, AP: TJSONArray;
  JN, JP: TJSONObject;
  K, I, S: Integer;
begin
  A := TJSONArray.Create;
  for K := 0 to High(N.Nodes) do
    with N.Nodes[K] do
    begin
      JN := TJSONObject.Create;
      JN.Add('id', Id);
      JN.Add('box', Box);
      if Inst <> '' then JN.Add('inst', Inst);
      JN.Add('type', DataTypeNames[DType]);
      if DType2 <> dtNone then JN.Add('type2', DataTypeNames[DType2]);
      if Box = 'cmp' then JN.Add('cmp', CmpOpNames[Cmp]);
      if N.Kind = nkCFC then
      begin
        JN.Add('x', X);
        JN.Add('y', Y);
        JN.Add('order', Order);
      end;
      AP := TJSONArray.Create;
      for I := 0 to High(Ins) do
      begin
        JP := TJSONObject.Create;
        JP.Add('pin', Ins[I].Name);
        if Ins[I].Opnd <> '' then JP.Add('op', Ins[I].Opnd);
        S := N.NodeIndex(Ins[I].Src);
        if (Ins[I].Src > 0) and (S >= 0) and (Ins[I].SrcPin <= High(N.Nodes[S].Outs)) then
          JP.Add('from', Format('%d.%s', [Ins[I].Src, N.Nodes[S].Outs[Ins[I].SrcPin].Name]));
        if Ins[I].Neg then JP.Add('neg', True);
        AP.Add(JP);
      end;
      JN.Add('in', AP);
      AP := TJSONArray.Create;
      for I := 0 to High(Outs) do
      begin
        JP := TJSONObject.Create;
        JP.Add('pin', Outs[I].Name);
        if Outs[I].Opnd <> '' then JP.Add('op', Outs[I].Opnd);
        AP.Add(JP);
      end;
      JN.Add('out', AP);
      A.Add(JN);
    end;
  Obj.Add('nodes', A);
  if N.Kind = nkCFC then
  begin
    Obj.Add('chartw', N.ChartW);
    Obj.Add('charth', N.ChartH);
  end;
end;

procedure NodesFromJson(N: TNetwork; Obj: TJSONObject);
var
  A, AP: TJSONArray;
  JN, JP: TJSONObject;
  K, I, J, Q, S, Lo, Hi: Integer;
  T: TDataType;
  F, Txt: string;
  Co: TCmpOp;
begin
  N.Nodes := nil;
  A := Obj.Get('nodes', TJSONArray(nil));
  if A <> nil then
  begin
    SetLength(N.Nodes, A.Count);
    for K := 0 to A.Count - 1 do
    begin
      JN := A.Objects[K];
      with N.Nodes[K] do
      begin
        Id := JN.Get('id', K + 1);
        Box := LowerCase(JN.Get('box', 'and'));
        Inst := JN.Get('inst', '');
        DType := dtBool;
        if ParseDataType(JN.Get('type', 'Bool'), T, Lo, Hi) then DType := T;
        DType2 := dtNone;
        if ParseDataType(JN.Get('type2', ''), T, Lo, Hi) then DType2 := T;
        Cmp := coEQ;
        Txt := JN.Get('cmp', '==');
        for Co := Low(TCmpOp) to High(TCmpOp) do
          if CmpOpNames[Co] = Txt then Cmp := Co;
        X := JN.Get('x', 0);
        Y := JN.Get('y', 0);
        Order := JN.Get('order', K + 1);
        AP := JN.Get('in', TJSONArray(nil));
        if AP <> nil then
        begin
          SetLength(Ins, AP.Count);
          for I := 0 to AP.Count - 1 do
          begin
            JP := AP.Objects[I];
            Ins[I].Name := JP.Get('pin', '');
            Ins[I].Opnd := JP.Get('op', '');
            Ins[I].Neg := JP.Get('neg', False);
            Ins[I].Src := 0;
            Ins[I].SrcPin := 0;
            // "from": "3.Q" (the pin name is matched when every box is read)
            F := JP.Get('from', '');
            if F <> '' then
            begin
              Q := Pos('.', F);
              if Q = 0 then Q := Length(F) + 1;
              Ins[I].Src := StrToIntDef(Copy(F, 1, Q - 1), 0);
              Ins[I].Opnd := #1 + Copy(F, Q + 1, MaxInt);
            end;
          end;
        end;
        AP := JN.Get('out', TJSONArray(nil));
        if AP <> nil then
        begin
          SetLength(Outs, AP.Count);
          for I := 0 to AP.Count - 1 do
          begin
            Outs[I].Name := AP.Objects[I].Get('pin', '');
            Outs[I].Opnd := AP.Objects[I].Get('op', '');
            Outs[I].Src := 0;
          end;
        end;
      end;
    end;
    // the wires: the output pin by its name
    for K := 0 to High(N.Nodes) do
      for I := 0 to High(N.Nodes[K].Ins) do
        if (N.Nodes[K].Ins[I].Src > 0) and (Copy(N.Nodes[K].Ins[I].Opnd, 1, 1) = #1) then
        begin
          F := Copy(N.Nodes[K].Ins[I].Opnd, 2, MaxInt);
          N.Nodes[K].Ins[I].SrcPin := 0;
          S := N.NodeIndex(N.Nodes[K].Ins[I].Src);
          if S < 0 then
          begin
            N.Nodes[K].Ins[I].Src := 0;
            N.Nodes[K].Ins[I].Opnd := '';
          end
          else
          begin
            // the pin by its name; a box written without its outputs: the name stays (#1 name) for uFbd
            for J := 0 to High(N.Nodes[S].Outs) do
              if SameText(N.Nodes[S].Outs[J].Name, F) then
              begin
                N.Nodes[K].Ins[I].SrcPin := J;
                N.Nodes[K].Ins[I].Opnd := '';
              end;
            if (Length(N.Nodes[S].Outs) > 0) or (F = '') then N.Nodes[K].Ins[I].Opnd := '';
          end;
        end;
  end;
  N.ChartW := Obj.Get('chartw', 120);
  N.ChartH := Obj.Get('charth', 42);
end;

{ TBlock }

constructor TBlock.Create(AKind: TBlockKind; ANumber: Integer; const AName: string);
begin
  inherited Create;
  Kind := AKind;
  Number := ANumber;
  Version := '0.1';
  Name := AName;
  Networks := TList.Create;
  Iface := TDataBlock.Create(ANumber, AName);
  Iface.IsUdt := True;
  Iface.IsIface := True;
  // an OB as an FC: its start information (Input) in the local data, the Temps after it
  Iface.IsFC := AKind in [bkFC, bkOB];
  ObEvent := -1;
end;

destructor TBlock.Destroy;
var
  I: Integer;
begin
  for I := 0 to Networks.Count - 1 do TNetwork(Networks[I]).Free;
  Networks.Free;
  Iface.Free;
  inherited Destroy;
end;

function TBlock.Net(I: Integer): TNetwork;
begin
  Result := TNetwork(Networks[I]);
end;

function TBlock.NetCount: Integer;
begin
  Result := Networks.Count;
end;

function TBlock.AddNet(AKind: TNetKind): TNetwork;
begin
  Result := TNetwork.Create(AKind);
  Networks.Add(Result);
end;

procedure TBlock.DeleteNet(I: Integer);
begin
  if (I < 0) or (I >= Networks.Count) then Exit;
  TNetwork(Networks[I]).Free;
  Networks.Delete(I);
end;

function TBlock.Title: string;
begin
  case Kind of
    bkOB: Result := 'OB';
    bkFB: Result := 'FB';
  else
    Result := 'FC';
  end;
  Result := Result + IntToStr(Number);
end;

{ TDataBlock }

constructor TDataBlock.Create(ANumber: Integer; const AName: string);
begin
  inherited Create;
  Number := ANumber;
  Name := AName;
end;

procedure TDataBlock.AddVar(const AName, AType, AStart, AComment: string);
var
  N: Integer;
begin
  N := Length(Vars);
  SetLength(Vars, N + 1);
  FillChar(Vars[N], SizeOf(TDbVar), 0);
  Vars[N].Name := AName;
  Vars[N].TypeText := AType;
  Vars[N].Start := AStart;
  Vars[N].Comment := AComment;
  Layout;
end;

function TDataBlock.AddSecVar(ASec: TVarSection; const AName, AType, AStart, AComment: string): Integer;
var
  K: Integer;
  V: TDbVar;
begin
  FillChar(V, SizeOf(V), 0);
  V.Name := AName;
  V.TypeText := AType;
  V.Start := AStart;
  V.Comment := AComment;
  V.Section := ASec;
  Result := Length(Vars);
  while (Result > 0) and (Vars[Result - 1].Section > ASec) do Dec(Result);
  SetLength(Vars, Length(Vars) + 1);
  for K := High(Vars) downto Result + 1 do Vars[K] := Vars[K - 1];
  Vars[Result] := V;
  Layout;
end;

{ stable: the variables of a section keep their order }
procedure TDataBlock.SortSections;
var
  I, J: Integer;
  V: TDbVar;
begin
  for I := 1 to High(Vars) do
  begin
    V := Vars[I];
    J := I - 1;
    while (J >= 0) and (Vars[J].Section > V.Section) do
    begin
      Vars[J + 1] := Vars[J];
      Dec(J);
    end;
    Vars[J + 1] := V;
  end;
end;

procedure TDataBlock.DeleteVar(I: Integer);
var
  K: Integer;
begin
  if (I < 0) or (I > High(Vars)) then Exit;
  for K := I to High(Vars) - 1 do Vars[K] := Vars[K + 1];
  SetLength(Vars, Length(Vars) - 1);
  Layout;
end;

{ standard DB layout: bits packed, byte types on a byte, words and up, arrays
  and structs on an even byte, the DB length rounded up to even }
procedure TDataBlock.Layout;
var
  I, ByteP, BitP, Sz, N: Integer;
  T: TDataType;
  Lo, Hi: Integer;
  U: TDataBlock;

  procedure CloseBits;
  begin
    if BitP > 0 then
    begin
      Inc(ByteP);
      BitP := 0;
    end;
  end;

  procedure AlignEven;
  begin
    CloseBits;
    if Odd(ByteP) then Inc(ByteP);
  end;

  procedure SyncInstance;
  var
    Fb: TBlock;
    K, N: Integer;
  begin
    // an instance DB has the static data of its FB: Input, Output, InOut, Static
    Fb := Owner.FindBlock(bkFB, InstanceOf);
    if Fb = nil then Exit;
    N := 0;
    for K := 0 to High(Fb.Iface.Vars) do
      if Fb.Iface.Vars[K].Section <> vsTemp then Inc(N);
    SetLength(Vars, N);
    N := 0;
    for K := 0 to High(Fb.Iface.Vars) do
      if Fb.Iface.Vars[K].Section <> vsTemp then
      begin
        Vars[N] := Fb.Iface.Vars[K];
        Vars[N].Retain := False;
        Inc(N);
      end;
  end;

var
  Pass, SaveP: Integer;
begin
  if FBusy then Exit;   // a recursive PLC data type: the caller marks the member invalid
  if (StrMax > 0) or (IecVar <> dtNone) then Exit;   // a string / timer / counter type: its size is fixed
  FBusy := True;
  if (InstanceOf > 0) and (Owner <> nil) then SyncInstance;
  SaveP := 0;
  for Pass := 0 to 1 do
  begin
  // pass 0: the static data, pass 1: the Temp section of an interface (local data from 0)
  if Pass = 1 then
  begin
    CloseBits;
    if Odd(ByteP) then Inc(ByteP);
    SaveP := ByteP;
  end;
  // an FC: the Temps follow the parameters in the local data
  if (Pass = 1) and IsFC then ByteP := SaveP else ByteP := 0;
  BitP := 0;
  for I := 0 to High(Vars) do
  begin
    if (Vars[I].Section = vsTemp) <> (Pass = 1) then Continue;
    if not IsIface and (Pass = 1) then Continue;
    if Owner <> nil then
      Vars[I].Valid := Owner.ParseVarType(Vars[I].TypeText, T, Lo, Hi, U)
    else
    begin
      Vars[I].Valid := ParseDataType(Vars[I].TypeText, T, Lo, Hi);
      U := nil;
      if Vars[I].Valid and (T in [dtString, dtWString]) then U := StrUdt(StringMaxOf(Vars[I].TypeText), T = dtWString);
      if Vars[I].Valid and (T in [dtIECTimer, dtIECCounter]) then U := IecUdt(Vars[I].TypeText);
    end;
    if Vars[I].Valid and (U <> nil) then
    begin
      if U.FBusy or (U = Self) then
        Vars[I].Valid := False      // contains itself
      else
        U.Layout;
    end;
    Vars[I].DType := T;
    Vars[I].Udt := U;
    Vars[I].IsArray := Vars[I].Valid and (Hi >= Lo);
    Vars[I].Lo := Lo;
    Vars[I].Hi := Hi;
    Vars[I].Dims := nil;
    if Vars[I].IsArray and (Length(ArrayDims(Vars[I].TypeText)) > 1) then Vars[I].Dims := ArrayDims(Vars[I].TypeText);
    if not Vars[I].Valid then
    begin
      Vars[I].Ofs := ByteP;
      Vars[I].Bit := 0;
      Continue;
    end;
    Sz := DataTypeSize(T);
    if (T in [dtStruct, dtString, dtWString]) or ((T in [dtIECTimer, dtIECCounter]) and (U <> nil)) then Sz := U.Size;
    if Vars[I].IsArray then
    begin
      AlignEven;
      N := Hi - Lo + 1;
      Vars[I].Ofs := ByteP;
      Vars[I].Bit := 0;
      if T = dtBool then
        ByteP := ByteP + (N + 7) div 8
      else
        ByteP := ByteP + N * ElemStride(T, U);  // elements of a struct array stay even
      AlignEven;
    end
    else if T in [dtStruct, dtString, dtWString] then
    begin
      AlignEven;
      Vars[I].Ofs := ByteP;
      Vars[I].Bit := 0;
      ByteP := ByteP + Sz;
      AlignEven;
    end
    else if T = dtBool then
    begin
      if BitP >= 8 then
      begin
        Inc(ByteP);
        BitP := 0;
      end;
      Vars[I].Ofs := ByteP;
      Vars[I].Bit := BitP;
      Inc(BitP);
    end
    else
    begin
      if Sz = 1 then CloseBits else AlignEven;
      Vars[I].Ofs := ByteP;
      Vars[I].Bit := 0;
      ByteP := ByteP + Sz;
      if T in [dtIECTimer, dtIECCounter] then AlignEven;
    end;
  end;
  end;
  CloseBits;
  if Odd(ByteP) then Inc(ByteP);
  TempSize := ByteP;
  ByteP := SaveP;
  if IsUdt and (ByteP = 0) then ByteP := 2;   // an empty struct still takes a word
  Size := ByteP;
  FBusy := False;
end;

function TDataBlock.FindVar(const AName: string): Integer;
var
  I: Integer;
begin
  for I := 0 to High(Vars) do
    if SameText(Vars[I].Name, AName) then Exit(I);
  Result := -1;
end;

{ TPlcProject }

constructor TPlcProject.Create;
begin
  inherited Create;
  Blocks := TList.Create;
  DBs := TList.Create;
  Udts := TList.Create;
  Clear;
end;

destructor TPlcProject.Destroy;
begin
  Clear;
  Blocks.Free;
  DBs.Free;
  Udts.Free;
  inherited Destroy;
end;

procedure TPlcProject.Clear;
var
  I: Integer;
begin
  for I := 0 to Blocks.Count - 1 do TBlock(Blocks[I]).Free;
  Blocks.Clear;
  for I := 0 to DBs.Count - 1 do TDataBlock(DBs[I]).Free;
  DBs.Clear;
  for I := 0 to Udts.Count - 1 do TDataBlock(Udts[I]).Free;
  Udts.Clear;
  SetLength(Tags, 0);
  SetLength(Watch, 0);
  SetLength(Signals, 0);
  SetLength(TagGroups, 0);
  SetLength(WatchGroups, 0);
  for I := 0 to High(DIch) do
  begin
    DIch[I].InType := itToggle;
    DIch[I].AiMode := amManual;
    DIch[I].AiValue := 0;
  end;
  for I := 0 to High(AIch) do
  begin
    AIch[I].InType := itToggle;
    AIch[I].AiMode := amManual;
    AIch[I].AiValue := 0;
  end;
  Name := 'Untitled';
  FileName := '';
  Author := '';
  Comment := '';
  ModelIdx := 1;
  CyclicMs := 100;
  ClockByte := -1;
  Comm := DefaultComm;
  Modified := False;
end;

function TPlcProject.Family: TCpuFamily;
begin
  Result := Models[ModelIdx].Family;
end;

function TPlcProject.Model: TCpuModel;
begin
  Result := Models[ModelIdx];
end;

function TPlcProject.Block(I: Integer): TBlock;
begin
  Result := TBlock(Blocks[I]);
end;

function TPlcProject.BlockCount: Integer;
begin
  Result := Blocks.Count;
end;

function TPlcProject.FindBlock(AKind: TBlockKind; ANumber: Integer): TBlock;
var
  I: Integer;
begin
  for I := 0 to Blocks.Count - 1 do
    if (Block(I).Kind = AKind) and (Block(I).Number = ANumber) then Exit(Block(I));
  Result := nil;
end;

function TPlcProject.AddBlock(AKind: TBlockKind; ANumber: Integer; const AName: string): TBlock;
begin
  Result := TBlock.Create(AKind, ANumber, AName);
  Result.Iface.Owner := Self;
  Blocks.Add(Result);
  SortBlocks;
  if AKind = bkOB then SyncObIface(Result);
end;

function TPlcProject.ObEventOfBlock(B: TBlock): TObEvent;
begin
  Result := ObEventOf(Family, B.Number, B.ObEvent);
end;

function TPlcProject.ObCycleMs(B: TBlock): Integer;
begin
  if B.CycleMs > 0 then Result := B.CycleMs
  else if B.Number = CyclicOB then Result := CyclicMs
  else Result := ObDefaultCycleMs(B.Number);
end;

{ the start information first (S7-1200 / 1500: the Input section; S7-300 / 400: the first Temps), the
  variables of the user after it; a user variable of the same name as one of the start information goes }
procedure TPlcProject.SyncObIface(B: TBlock);
var
  SV: TObStartVars;
  Res: array of TDbVar;
  K, J, SV2: Integer;
  Dup: Boolean;

  procedure Put(const V: TDbVar);
  begin
    SetLength(Res, Length(Res) + 1);
    Res[High(Res)] := V;
  end;

  procedure PutSys(const S: TObStartVar);
  var
    V: TDbVar;
  begin
    FillChar(V, SizeOf(V), 0);
    V.Name := S.Name;
    V.TypeText := S.TypeText;
    V.Comment := S.Comment;
    if S.InputSec then V.Section := vsInput else V.Section := vsTemp;
    V.System := True;
    Put(V);
  end;

begin
  if (B = nil) or (B.Kind <> bkOB) then Exit;
  B.Iface.IsFC := True;
  SV := ObStartInfo(Family, ObEventOfBlock(B), B.Number);
  Res := nil;
  for K := 0 to High(SV) do
    if SV[K].InputSec then PutSys(SV[K]);
  for J := 0 to 1 do
  begin
    if J = 1 then
      for K := 0 to High(SV) do
        if not SV[K].InputSec then PutSys(SV[K]);
    for K := 0 to High(B.Iface.Vars) do
    begin
      if B.Iface.Vars[K].System then Continue;
      if (B.Iface.Vars[K].Section >= vsTemp) <> (J = 1) then Continue;
      Dup := False;
      for SV2 := 0 to High(SV) do
        if SameText(SV[SV2].Name, B.Iface.Vars[K].Name) then Dup := True;
      if not Dup then Put(B.Iface.Vars[K]);
    end;
  end;
  B.Iface.Vars := Res;
  B.Iface.Layout;
end;

procedure TPlcProject.SyncObIfaces;
var
  K: Integer;
begin
  for K := 0 to BlockCount - 1 do
    if Block(K).Kind = bkOB then SyncObIface(Block(K));
end;

procedure TPlcProject.DeleteBlock(I: Integer);
begin
  if (I < 0) or (I >= Blocks.Count) then Exit;
  Block(I).Free;
  Blocks.Delete(I);
end;

function CompareBlocks(A, B: Pointer): Integer;
begin
  Result := Ord(TBlock(A).Kind) - Ord(TBlock(B).Kind);
  if Result = 0 then
  begin
    // OB1 first, then the other OBs by number
    if TBlock(A).Number = TBlock(B).Number then Result := 0
    else if TBlock(A).Number < TBlock(B).Number then Result := -1
    else Result := 1;
  end;
end;

procedure TPlcProject.SortBlocks;
begin
  Blocks.Sort(@CompareBlocks);
end;

function TPlcProject.DB(I: Integer): TDataBlock;
begin
  Result := TDataBlock(DBs[I]);
end;

function TPlcProject.DBCount: Integer;
begin
  Result := DBs.Count;
end;

function TPlcProject.FindDB(ANumber: Integer): TDataBlock;
var
  I: Integer;
begin
  for I := 0 to DBs.Count - 1 do
    if DB(I).Number = ANumber then Exit(DB(I));
  Result := nil;
end;

function TPlcProject.FindDBByName(const AName: string): TDataBlock;
var
  I: Integer;
begin
  for I := 0 to DBs.Count - 1 do
    if SameText(DB(I).Name, AName) then Exit(DB(I));
  Result := nil;
end;

function CompareDBs(A, B: Pointer): Integer;
begin
  Result := TDataBlock(A).Number - TDataBlock(B).Number;
end;

function TPlcProject.AddDB(ANumber: Integer; const AName: string): TDataBlock;
begin
  Result := TDataBlock.Create(ANumber, AName);
  Result.Optimized := False;
  Result.Owner := Self;
  DBs.Add(Result);
  DBs.Sort(@CompareDBs);
end;

procedure TPlcProject.DeleteDB(I: Integer);
begin
  if (I < 0) or (I >= DBs.Count) then Exit;
  DB(I).Free;
  DBs.Delete(I);
end;

function TPlcProject.Udt(I: Integer): TDataBlock;
begin
  Result := TDataBlock(Udts[I]);
end;

function TPlcProject.UdtCount: Integer;
begin
  Result := Udts.Count;
end;

function TPlcProject.FindUdt(const AName: string): TDataBlock;
var
  I, N: Integer;
  S: string;
begin
  Result := nil;
  S := Trim(AName);
  if (Length(S) >= 2) and (S[1] = '"') and (S[Length(S)] = '"') then S := Copy(S, 2, Length(S) - 2)
  else if SameText(Copy(S, 1, 3), 'UDT') and TryStrToInt(Copy(S, 4, MaxInt), N) then
  begin
    for I := 0 to Udts.Count - 1 do
      if Udt(I).Number = N then Exit(Udt(I));
    Exit;
  end;
  if S = '' then Exit;
  for I := 0 to Udts.Count - 1 do
    if SameText(Udt(I).Name, S) then Exit(Udt(I));
  Result := SysUdt(S);
end;

var
  SysUdts: TList = nil;

{ the system FBs that are structs of bits: R_TRIG / F_TRIG (CLK, Q, the edge memory M), RS (S, R1, Q1)
  and SR (S1, R, Q1); not in the project's list of PLC data types }
function SysUdt(const AName: string): TDataBlock;
const
  Names: array[0..4] of string = ('R_TRIG', 'F_TRIG', 'RS', 'SR', 'DTL');
  Mems: array[0..4] of string = ('CLK,Q,M', 'CLK,Q,M', 'S,R1,Q1', 'S1,R,Q1',
    // DTL: 12 bytes as on the CPU (DTL#1970-01-01-00:00:00, a Thursday)
    'YEAR:UInt:1970,MONTH:USInt:1,DAY:USInt:1,WEEKDAY:USInt:5,HOUR:USInt,MINUTE:USInt,SECOND:USInt,NANOSECOND:UDInt');
var
  I, K: Integer;
  L: TStringList;
  Pt: TStringArray;
begin
  Result := nil;
  if SysUdts = nil then
  begin
    SysUdts := TList.Create;
    for I := 0 to High(Names) do
    begin
      Result := TDataBlock.Create(0, Names[I]);
      Result.IsUdt := True;
      L := TStringList.Create;
      try
        L.CommaText := Mems[I];
        for K := 0 to L.Count - 1 do
        begin
          // name, or name:type[:start]
          Pt := L[K].Split(':');
          if Length(Pt) = 1 then Result.AddVar(L[K], 'Bool', 'FALSE', '')
          else if Length(Pt) = 2 then Result.AddVar(Pt[0], Pt[1], '0', '')
          else Result.AddVar(Pt[0], Pt[1], Pt[2], '');
        end;
      finally
        L.Free;
      end;
      Result.Layout;
      SysUdts.Add(Result);
    end;
    Result := nil;
  end;
  for I := 0 to SysUdts.Count - 1 do
    if SameText(TDataBlock(SysUdts[I]).Name, AName) then Exit(TDataBlock(SysUdts[I]));
end;

var
  StrUdts: TStringList = nil;

function StrUdt(AMax: Integer; Wide: Boolean): TDataBlock;
var
  Nm: string;
  K: Integer;
begin
  if AMax < 1 then AMax := 254;
  if Wide then Nm := Format('WString[%d]', [AMax]) else Nm := Format('String[%d]', [AMax]);
  if StrUdts = nil then StrUdts := TStringList.Create;
  K := StrUdts.IndexOf(Nm);
  if K >= 0 then Exit(TDataBlock(StrUdts.Objects[K]));
  Result := TDataBlock.Create(0, Nm);
  Result.IsUdt := True;
  Result.StrMax := AMax;
  Result.StrWide := Wide;
  if Wide then Result.Size := 4 + 2 * AMax else Result.Size := 2 + AMax;
  StrUdts.AddObject(Nm, Result);
end;

var
  IecUdts: TStringList = nil;

function IecUdt(const TypeText: string): TDataBlock;
var
  VT: TDataType;
  Nm: string;
  K, Sz: Integer;
  IsT: Boolean;
begin
  Result := nil;
  VT := IecVarType(TypeText);
  if VT in [dtNone, dtTime, dtInt] then Exit;
  IsT := VT = dtLTime;
  Nm := UpperCase(Trim(TypeText));
  if Pos(' OF ', Nm) > 0 then Nm := Trim(Copy(Nm, Pos(' OF ', Nm) + 4, MaxInt));
  if IecUdts = nil then IecUdts := TStringList.Create;
  K := IecUdts.IndexOf(Nm);
  if K >= 0 then Exit(TDataBlock(IecUdts.Objects[K]));
  Result := TDataBlock.Create(0, Nm);
  Result.IsUdt := True;
  Result.IecVar := VT;
  if IsT then Result.Size := 18
  else
  begin
    Sz := Max(2, DataTypeSize(VT));
    Result.Size := 2 + 2 * Sz;
  end;
  IecUdts.AddObject(Nm, Result);
end;

procedure IecOffsets(U: TDataBlock; IsTimer: Boolean; out OPv, OCv, OEt, OBits: Integer; out VT: TDataType);
begin
  if IsTimer then
  begin
    OPv := 0;
    OCv := 0;
    if (U <> nil) and (U.IecVar = dtLTime) then
    begin
      VT := dtLTime;
      OEt := 8;
      OBits := 16;
    end
    else
    begin
      VT := dtTime;
      OEt := 4;
      OBits := 8;
    end;
    Exit;
  end;
  OEt := 0;
  OBits := 0;
  OPv := 2;
  if (U <> nil) and (U.IecVar <> dtNone) then VT := U.IecVar else VT := dtInt;
  OCv := 2 + Max(2, DataTypeSize(VT));
end;

{ "Old" -> "New" in S (not case sensitive), the count in Cnt }
function SwapQuoted(const S, Old, New: string; var Cnt: Integer): string;
var
  U, Q: string;
  K: Integer;
begin
  Result := '';
  U := UpperCase(S);
  Q := '"' + UpperCase(Old) + '"';
  K := 1;
  while K <= Length(S) do
  begin
    if (S[K] = '"') and (Copy(U, K, Length(Q)) = Q) then
    begin
      Result := Result + '"' + New + '"';
      Inc(K, Length(Q));
      Inc(Cnt);
    end
    else
    begin
      Result := Result + S[K];
      Inc(K);
    end;
  end;
end;

{ #Old -> #New (a whole word) }
function SwapLocal(const S, Old, New: string; var Cnt: Integer): string;
var
  K, L: Integer;
begin
  Result := '';
  L := Length(Old);
  K := 1;
  while K <= Length(S) do
  begin
    if (S[K] = '#') and SameText(Copy(S, K + 1, L), Old) and
      ((K + L + 1 > Length(S)) or not (S[K + L + 1] in ['A'..'Z', 'a'..'z', '0'..'9', '_'])) then
    begin
      Result := Result + '#' + New;
      Inc(K, L + 1);
      Inc(Cnt);
    end
    else
    begin
      Result := Result + S[K];
      Inc(K);
    end;
  end;
end;

function RenameBlockInCode(P: TPlcProject; B: TBlock; const NewName: string): Integer;
var
  I, J, K, R, C, Q: Integer;
  Bk: TBlock;
  N: TNetwork;
  Ce: TLadCell;
  Old, T: string;
  D: TDataBlock;

  procedure FixTypes(Db: TDataBlock);
  var
    V: Integer;
  begin
    for V := 0 to High(Db.Vars) do Db.Vars[V].TypeText := SwapQuoted(Db.Vars[V].TypeText, Old, NewName, Result);
  end;

begin
  Result := 0;
  Old := B.Name;
  if (Trim(NewName) = '') or (Old = NewName) then Exit;
  for I := 0 to P.BlockCount - 1 do
  begin
    Bk := P.Block(I);
    for J := 0 to Bk.NetCount - 1 do
    begin
      N := Bk.Net(J);
      for K := 0 to N.Stl.Count - 1 do
      begin
        T := SwapQuoted(N.Stl[K], Old, NewName, Result);
        // the value of an FC is #<its name> in its own code
        if (Bk = B) and (B.Kind = bkFC) and (B.Iface.FindVar(Old) < 0) then T := SwapLocal(T, Old, NewName, Result);
        if T <> N.Stl[K] then N.Stl[K] := T;
      end;
      for R := 0 to N.Rows - 1 do
        for C := 0 to N.Cols - 1 do
        begin
          Ce := N.Cell(R, C);
          if Ce.Kind = lkEmpty then Continue;
          Q := Result;
          Ce.Opnd := SwapQuoted(Ce.Opnd, Old, NewName, Result);
          for K := 0 to 4 do Ce.P[K] := SwapQuoted(Ce.P[K], Old, NewName, Result);
          Ce.Args := SwapQuoted(Ce.Args, Old, NewName, Result);
          if Result <> Q then N.SetCell(R, C, Ce);
        end;
    end;
    FixTypes(Bk.Iface);
  end;
  for I := 0 to P.DBCount - 1 do
  begin
    D := P.DB(I);
    FixTypes(D);
  end;
  for I := 0 to P.UdtCount - 1 do FixTypes(P.Udt(I));
  for I := 0 to High(P.Watch) do P.Watch[I].Address := SwapQuoted(P.Watch[I].Address, Old, NewName, Result);
  B.Name := NewName;
end;

function IsSysFb(U: TDataBlock): Boolean;
begin
  Result := IsSysUdt(U) and not SameText(U.Name, 'DTL');
end;

function IsSysUdt(U: TDataBlock): Boolean;
begin
  Result := (U <> nil) and (SysUdts <> nil) and (SysUdts.IndexOf(U) >= 0);
end;

function TPlcProject.AddUdt(ANumber: Integer; const AName: string): TDataBlock;
begin
  Result := TDataBlock.Create(ANumber, AName);
  Result.IsUdt := True;
  Result.Owner := Self;
  Udts.Add(Result);
  Udts.Sort(@CompareDBs);
end;

procedure TPlcProject.DeleteUdt(I: Integer);
begin
  if (I < 0) or (I >= Udts.Count) then Exit;
  Udt(I).Free;
  Udts.Delete(I);
end;

function TPlcProject.UdtTypeName(U: TDataBlock): string;
begin
  if IsTia(Family) then Result := '"' + U.Name + '"'
  else Result := Format('UDT%d', [U.Number]);
end;

function TPlcProject.FindFB(const ARef: string): TBlock;
var
  I, N: Integer;
  S: string;
begin
  Result := nil;
  S := Trim(ARef);
  if (Length(S) >= 2) and (S[1] = '"') and (S[Length(S)] = '"') then S := Copy(S, 2, Length(S) - 2)
  else if SameText(Copy(S, 1, 2), 'FB') and TryStrToInt(Copy(S, 3, MaxInt), N) then
    Exit(FindBlock(bkFB, N));
  if S = '' then Exit;
  for I := 0 to Blocks.Count - 1 do
    if (Block(I).Kind = bkFB) and SameText(Block(I).Name, S) then Exit(Block(I));
end;

function TPlcProject.InstanceFB(D: TDataBlock): TBlock;
begin
  if (D = nil) or (D.InstanceOf <= 0) then Exit(nil);
  Result := FindBlock(bkFB, D.InstanceOf);
end;

function TPlcProject.ParseVarType(const S: string; out T: TDataType; out Lo, Hi: Integer;
  out AUdt: TDataBlock): Boolean;
var
  Elem: string;
  Fb: TBlock;
begin
  AUdt := nil;
  Result := ParseDataType(S, T, Lo, Hi);
  if Result then
  begin
    if T in [dtString, dtWString] then AUdt := StrUdt(StringMaxOf(S), T = dtWString);
    if T in [dtIECTimer, dtIECCounter] then AUdt := IecUdt(S);
    Exit;
  end;
  if not SplitArrayType(S, Lo, Hi, Elem) then Exit;
  AUdt := FindUdt(Elem);
  if AUdt = nil then
  begin
    // a multi-instance: a variable of an FB type
    Fb := FindFB(Elem);
    if Fb = nil then Exit;
    AUdt := Fb.Iface;
    AUdt.Name := Fb.Name;
    AUdt.Number := Fb.Number;
  end;
  T := dtStruct;
  Result := True;
end;

function TPlcProject.FindTag(const AName: string): Integer;
var
  I: Integer;
begin
  for I := 0 to High(Tags) do
    if SameText(Tags[I].Name, AName) then Exit(I);
  Result := -1;
end;

procedure TPlcProject.AddTag(const AName, AType, AAddress, AComment: string);
var
  N: Integer;
begin
  N := Length(Tags);
  SetLength(Tags, N + 1);
  Tags[N].Name := AName;
  Tags[N].TypeText := AType;
  Tags[N].Address := AAddress;
  Tags[N].Comment := AComment;
  Tags[N].GroupId := 0;
end;

function GroupAdd(var G: TItemGroups; const AName: string): Integer;
var
  K, Id: Integer;
begin
  Id := 1;
  for K := 0 to High(G) do
    if G[K].Id >= Id then Id := G[K].Id + 1;
  Result := Length(G);
  SetLength(G, Result + 1);
  G[Result].Id := Id;
  G[Result].Name := AName;
end;

function GroupOfId(const G: TItemGroups; Id: Integer): Integer;
var
  K: Integer;
begin
  for K := 0 to High(G) do
    if G[K].Id = Id then Exit(K);
  Result := -1;
end;

function GroupNameTwice(const G: TItemGroups; I: Integer): Boolean;
var
  K: Integer;
begin
  Result := False;
  for K := 0 to High(G) do
    if (K <> I) and SameText(Trim(G[K].Name), Trim(G[I].Name)) then Exit(True);
end;

function GroupNameOk(const AName, Root: string; out Err: string): Boolean;
begin
  Err := '';
  if Trim(AName) = '' then Err := 'a group needs a name'
  else if SameText(Trim(AName), AllTagsName) or SameText(Trim(AName), Root) then
    Err := Format('"%s" is the name of the root of the tree: choose another', [Trim(AName)]);
  Result := Err = '';
end;

function GroupsToJson(const G: TItemGroups): TJSONArray;
var
  K: Integer;
  J: TJSONObject;
begin
  Result := TJSONArray.Create;
  for K := 0 to High(G) do
  begin
    J := TJSONObject.Create;
    J.Add('id', G[K].Id);
    J.Add('name', G[K].Name);
    Result.Add(J);
  end;
end;

procedure GroupsFromJson(A: TJSONArray; var G: TItemGroups);
var
  K, N: Integer;
begin
  SetLength(G, 0);
  if A = nil then Exit;
  for K := 0 to A.Count - 1 do
    if A.Items[K] is TJSONObject then
    begin
      N := Length(G);
      SetLength(G, N + 1);
      G[N].Id := A.Objects[K].Get('id', N + 1);
      G[N].Name := A.Objects[K].Get('name', '');
    end;
end;

procedure TPlcProject.DeleteTagGroup(I: Integer);
var
  K: Integer;
begin
  if (I < 0) or (I > High(TagGroups)) then Exit;
  for K := 0 to High(Tags) do
    if Tags[K].GroupId = TagGroups[I].Id then Tags[K].GroupId := 0;
  for K := I to High(TagGroups) - 1 do TagGroups[K] := TagGroups[K + 1];
  SetLength(TagGroups, High(TagGroups));
end;

procedure TPlcProject.DeleteWatchGroup(I: Integer);
var
  K: Integer;
begin
  if (I < 0) or (I > High(WatchGroups)) then Exit;
  for K := 0 to High(Watch) do
    if Watch[K].GroupId = WatchGroups[I].Id then Watch[K].GroupId := 0;
  for K := I to High(WatchGroups) - 1 do WatchGroups[K] := WatchGroups[K + 1];
  SetLength(WatchGroups, High(WatchGroups));
end;

procedure TPlcProject.DeleteTag(I: Integer);
var
  K: Integer;
begin
  if (I < 0) or (I > High(Tags)) then Exit;
  for K := I to High(Tags) - 1 do Tags[K] := Tags[K + 1];
  SetLength(Tags, Length(Tags) - 1);
end;

function TPlcProject.AddSignal(const AAddress: string; AKind: TSigKind; ALo, AHi, APeriod, ADuty: Double): Integer;
begin
  Result := Length(Signals);
  SetLength(Signals, Result + 1);
  Signals[Result].Address := AAddress;
  Signals[Result].Kind := AKind;
  Signals[Result].Lo := ALo;
  Signals[Result].Hi := AHi;
  Signals[Result].PeriodMs := APeriod;
  Signals[Result].Duty := ADuty;
  Signals[Result].On := False;
  Signals[Result].Comment := '';
end;

procedure TPlcProject.DeleteSignal(I: Integer);
var
  K: Integer;
begin
  if (I < 0) or (I > High(Signals)) then Exit;
  for K := I to High(Signals) - 1 do Signals[K] := Signals[K + 1];
  SetLength(Signals, High(Signals));
end;

function SignalValue(const S: TSimSignal; T: Double; Rnd: Double): Double;
var
  Ph, Per: Double;
begin
  Per := Max(1, S.PeriodMs) / 1000;
  Ph := Frac(T / Per);
  case S.Kind of
    sgSquare: if Ph * 100 < EnsureRange(S.Duty, 0, 100) then Result := S.Hi else Result := S.Lo;
    sgSine: Result := S.Lo + (S.Hi - S.Lo) * (0.5 + 0.5 * Sin(2 * Pi * Ph));
    sgTriangle: if Ph < 0.5 then Result := S.Lo + (S.Hi - S.Lo) * Ph * 2 else Result := S.Hi - (S.Hi - S.Lo) * (Ph - 0.5) * 2;
    sgRamp: Result := S.Lo + (S.Hi - S.Lo) * Ph;
    sgRandom: Result := S.Lo + (S.Hi - S.Lo) * Rnd;
    sgStep:
      begin
        // Lo, Lo + 1, .. Hi, Lo again: one step per period
        if S.Hi > S.Lo then Result := S.Lo + Trunc(T / Per) mod (Trunc(S.Hi - S.Lo) + 1)
        else Result := S.Lo;
      end;
  else
    Result := S.Hi;
  end;
end;

procedure TPlcProject.AddWatch(const AAddress: string; AFmt: TDispFmt; const AModify: string);
var
  N: Integer;
begin
  N := Length(Watch);
  SetLength(Watch, N + 1);
  Watch[N].Address := AAddress;
  Watch[N].Fmt := AFmt;
  Watch[N].ModifyValue := AModify;
  Watch[N].ModifyOn := False;
  Watch[N].ForceOn := False;
  Watch[N].GroupId := 0;
end;

procedure TPlcProject.DeleteWatch(I: Integer);
var
  K: Integer;
begin
  if (I < 0) or (I > High(Watch)) then Exit;
  for K := I to High(Watch) - 1 do Watch[K] := Watch[K + 1];
  SetLength(Watch, Length(Watch) - 1);
end;

function TPlcProject.CyclicOB: Integer;
begin
  Result := Models[ModelIdx].CyclicOB;
end;

{ ---------- JSON ---------- }

function LadKindFromId(const S: string): TLadKind;
var
  K: TLadKind;
begin
  for K := Low(TLadKind) to High(TLadKind) do
    if LadKindIds[K] = S then Exit(K);
  Result := lkEmpty;
end;

{ ---------- JSON pieces (the project file, and the exports of one block / network / DB) ---------- }

function NetToJson(N: TNetwork): TJSONObject;
var
  JC: TJSONObject;
  ACells, AStl, AP: TJSONArray;
  R, C, K: Integer;
  Ce: TLadCell;
begin
  Result := TJSONObject.Create;
  Result.Add('title', N.Title);
  Result.Add('comment', N.Comment);
  if N.Kind in [nkFBD, nkCFC] then
  begin
    Result.Add('lang', NetLangName(N.Kind));
    NodesToJson(N, Result);
  end
  else if N.Kind in [nkSTL, nkSCL] then
  begin
    AStl := TJSONArray.Create;
    for K := 0 to N.Stl.Count - 1 do AStl.Add(N.Stl[K]);
    if N.Kind = nkSTL then
    begin
      Result.Add('lang', 'STL');
      Result.Add('stl', AStl);
    end
    else
    begin
      Result.Add('lang', 'SCL');
      Result.Add('scl', AStl);
    end;
  end
  else
  begin
    Result.Add('lang', 'LAD');
    Result.Add('rows', N.Rows);
    if N.Cols <> LadCols then Result.Add('cols', N.Cols);
    ACells := TJSONArray.Create;
    for R := 0 to N.Rows - 1 do
      for C := 0 to N.Cols - 1 do
      begin
        Ce := N.Cell(R, C);
        if (Ce.Kind = lkEmpty) and not Ce.Down then Continue;
        JC := TJSONObject.Create;
        JC.Add('r', R);
        JC.Add('c', C);
        JC.Add('e', LadKindIds[Ce.Kind]);
        if Ce.Opnd <> '' then JC.Add('op', Ce.Opnd);
        if LadParamCount(Ce.Kind) > 0 then
        begin
          AP := TJSONArray.Create;
          for K := 0 to LadParamCount(Ce.Kind) - 1 do AP.Add(Ce.P[K]);
          JC.Add('p', AP);
        end;
        if LadHasType(Ce.Kind) then JC.Add('type', DataTypeNames[Ce.DType]);
        if LadHasType2(Ce.Kind) then JC.Add('type2', DataTypeNames[Ce.DType2]);
        if Ce.Kind = lkCmp then JC.Add('cmp', CmpOpNames[Ce.Cmp]);
        if (Ce.Kind = lkCall) and (Ce.Args <> '') then JC.Add('args', Ce.Args);
        if Ce.Down then JC.Add('down', True);
        ACells.Add(JC);
      end;
    Result.Add('cells', ACells);
  end;
end;

function BlockToJson(B: TBlock): TJSONObject;
var
  JV: TJSONObject;
  AVars, ANets: TJSONArray;
  J, K: Integer;
begin
  Result := TJSONObject.Create;
  case B.Kind of
    bkOB: Result.Add('kind', 'OB');
    bkFB: Result.Add('kind', 'FB');
  else
    Result.Add('kind', 'FC');
  end;
  Result.Add('number', B.Number);
  Result.Add('name', B.Name);
  Result.Add('comment', B.Comment);
  if B.Version <> '0.1' then Result.Add('version', B.Version);
  if B.Kind = bkOB then
  begin
    // the settings of the OB's event
    if B.ObEvent >= 0 then Result.Add('obEvent', B.ObEvent);
    if B.CycleMs > 0 then Result.Add('cycleMs', B.CycleMs);
    if B.PhaseMs > 0 then Result.Add('phaseMs', B.PhaseMs);
    if B.TrigAddr <> '' then
    begin
      Result.Add('trigger', B.TrigAddr);
      Result.Add('edge', B.TrigEdge);
    end;
    if B.TodStart <> '' then
    begin
      Result.Add('todStart', B.TodStart);
      Result.Add('todMode', B.TodMode);
      Result.Add('todActive', B.TodActive);
    end;
  end;
  if Length(B.Iface.Vars) > 0 then
  begin
    AVars := TJSONArray.Create;
    for K := 0 to High(B.Iface.Vars) do
    begin
      if B.Iface.Vars[K].System then Continue;   // the start information: made again on load
      JV := TJSONObject.Create;
      JV.Add('section', SectionNames[B.Iface.Vars[K].Section]);
      JV.Add('name', B.Iface.Vars[K].Name);
      JV.Add('type', B.Iface.Vars[K].TypeText);
      JV.Add('start', B.Iface.Vars[K].Start);
      JV.Add('comment', B.Iface.Vars[K].Comment);
      AVars.Add(JV);
    end;
    Result.Add('interface', AVars);
  end;
  ANets := TJSONArray.Create;
  for J := 0 to B.NetCount - 1 do ANets.Add(NetToJson(B.Net(J)));
  Result.Add('networks', ANets);
end;

function DataBlockToJson(D: TDataBlock; AsType: Boolean): TJSONObject;
var
  JV: TJSONObject;
  AVars: TJSONArray;
  J: Integer;
begin
  Result := TJSONObject.Create;
  Result.Add('number', D.Number);
  Result.Add('name', D.Name);
  Result.Add('comment', D.Comment);
  if not AsType then
  begin
    Result.Add('optimized', D.Optimized);
    if D.InstanceOf > 0 then Result.Add('instanceOf', D.InstanceOf);
  end;
  AVars := TJSONArray.Create;
  for J := 0 to High(D.Vars) do
  begin
    JV := TJSONObject.Create;
    JV.Add('name', D.Vars[J].Name);
    JV.Add('type', D.Vars[J].TypeText);
    JV.Add('start', D.Vars[J].Start);
    JV.Add('comment', D.Vars[J].Comment);
    if not AsType and D.Vars[J].Retain then JV.Add('retain', True);
    AVars.Add(JV);
  end;
  if AsType then Result.Add('members', AVars) else Result.Add('vars', AVars);
end;

function TPlcProject.WatchToJson: TJSONArray;
var
  JW: TJSONObject;
  I: Integer;
begin
  Result := TJSONArray.Create;
  for I := 0 to High(Watch) do
  begin
    JW := TJSONObject.Create;
    JW.Add('address', Watch[I].Address);
    JW.Add('format', DispFmtNames[Watch[I].Fmt]);
    JW.Add('modify', Watch[I].ModifyValue);
    if Watch[I].GroupId > 0 then JW.Add('group', Watch[I].GroupId);
    Result.Add(JW);
  end;
end;

procedure TPlcProject.WatchFromJson(A: TJSONArray);
var
  JW: TJSONObject;
  I: Integer;
  S: string;
  F: TDispFmt;
begin
  for I := 0 to A.Count - 1 do
    if A.Items[I] is TJSONObject then
    begin
      JW := A.Objects[I];
      S := JW.Get('format', 'DEC');
      AddWatch(JW.Get('address', ''), dfDec, JW.Get('modify', ''));
      Watch[High(Watch)].GroupId := JW.Get('group', 0);
      for F := Low(TDispFmt) to High(TDispFmt) do
        if DispFmtNames[F] = S then Watch[High(Watch)].Fmt := F;
    end;
end;

{ a watch table of its own (Watch and force table: Save, Open) }
procedure TPlcProject.SaveWatchFile(const AFile: string);
var
  Root: TJSONObject;
  SL: TStringList;
begin
  Root := TJSONObject.Create;
  try
    Root.Add('format', 'VirtualPLC-watch');
    Root.Add('version', 1);
    Root.Add('cpu', Models[ModelIdx].Name);
    Root.Add('project', Name);
    Root.Add('watch', WatchToJson);
    if Length(WatchGroups) > 0 then Root.Add('groups', GroupsToJson(WatchGroups));
    SL := TStringList.Create;
    try
      SL.Text := Root.FormatJSON;
      SL.SaveToFile(AFile);
    finally
      SL.Free;
    end;
  finally
    Root.Free;
  end;
end;

procedure TPlcProject.LoadWatchFile(const AFile: string);
var
  SL: TStringList;
  Data: TJSONData;
  A: TJSONArray;
begin
  SL := TStringList.Create;
  try
    SL.LoadFromFile(AFile);
    Data := GetJSON(SL.Text);
  finally
    SL.Free;
  end;
  try
    if not (Data is TJSONObject) or (TJSONObject(Data).Get('format', '') <> 'VirtualPLC-watch') then
      raise Exception.Create('not a watch table of the Virtual PLC');
    A := TJSONObject(Data).Get('watch', TJSONArray(nil));
    if A = nil then raise Exception.Create('the file has no watch rows');
    SetLength(Watch, 0);
    GroupsFromJson(TJSONObject(Data).Get('groups', TJSONArray(nil)), WatchGroups);
    WatchFromJson(A);
  finally
    Data.Free;
  end;
end;

procedure TPlcProject.SaveToFile(const AFile: string);
var
  SL: TStringList;
begin
  SL := TStringList.Create;
  try
    SL.Text := ToJsonText;
    SL.WriteBOM := False;
    SL.SaveToFile(AFile);
  finally
    SL.Free;
  end;
  FileName := AFile;
  Modified := False;
end;

function TPlcProject.ToJsonText(Pretty: Boolean): string;
var
  Root, JB, JN, JC, JD, JV, JT, JW: TJSONObject;
  ABlocks, ANets, ACells, ADbs, AVars, ATags, AWatch, AStl, AP, AIo: TJSONArray;
  I, J, R, C, K: Integer;
  B: TBlock;
  N: TNetwork;
  Ce: TLadCell;
  D: TDataBlock;
  SL: TStringList;
begin
  Root := TJSONObject.Create;
  try
    Root.Add('format', 'VirtualPLC');
    Root.Add('version', 1);
    Root.Add('name', Name);
    Root.Add('author', Author);
    Root.Add('comment', Comment);
    Root.Add('cpu', Models[ModelIdx].Name);
    Root.Add('family', FamilyNames[Family]);
    Root.Add('cyclicMs', CyclicMs);
    Root.Add('clockByte', ClockByte);
    ABlocks := TJSONArray.Create;
    for I := 0 to BlockCount - 1 do ABlocks.Add(BlockToJson(Block(I)));
    Root.Add('blocks', ABlocks);
    // PLC data types first: the DBs use them
    ADbs := TJSONArray.Create;
    for I := 0 to UdtCount - 1 do ADbs.Add(DataBlockToJson(Udt(I), True));
    if UdtCount > 0 then Root.Add('types', ADbs) else ADbs.Free;
    ADbs := TJSONArray.Create;
    for I := 0 to DBCount - 1 do ADbs.Add(DataBlockToJson(DB(I), False));
    Root.Add('dbs', ADbs);
    ATags := TJSONArray.Create;
    for I := 0 to High(Tags) do
    begin
      JT := TJSONObject.Create;
      JT.Add('name', Tags[I].Name);
      JT.Add('type', Tags[I].TypeText);
      JT.Add('address', Tags[I].Address);
      JT.Add('comment', Tags[I].Comment);
      if Tags[I].GroupId > 0 then JT.Add('group', Tags[I].GroupId);
      ATags.Add(JT);
    end;
    Root.Add('tags', ATags);
    if Length(TagGroups) > 0 then Root.Add('tagGroups', GroupsToJson(TagGroups));
    if Length(WatchGroups) > 0 then Root.Add('watchGroups', GroupsToJson(WatchGroups));
    AWatch := WatchToJson;
    Root.Add('watch', AWatch);
    if Length(Signals) > 0 then
    begin
      AIo := TJSONArray.Create;
      for I := 0 to High(Signals) do
      begin
        JW := TJSONObject.Create;
        JW.Add('address', Signals[I].Address);
        JW.Add('kind', SigKindNames[Signals[I].Kind]);
        JW.Add('lo', Signals[I].Lo);
        JW.Add('hi', Signals[I].Hi);
        JW.Add('period', Signals[I].PeriodMs);
        JW.Add('duty', Signals[I].Duty);
        JW.Add('on', Signals[I].On);
        if Signals[I].Comment <> '' then JW.Add('comment', Signals[I].Comment);
        AIo.Add(JW);
      end;
      Root.Add('signals', AIo);
    end;
    AIo := TJSONArray.Create;
    for I := 0 to High(DIch) do AIo.Add(Ord(DIch[I].InType));
    Root.Add('diTypes', AIo);
    AIo := TJSONArray.Create;
    for I := 0 to High(AIch) do
    begin
      JW := TJSONObject.Create;
      JW.Add('mode', AiModeNames[AIch[I].AiMode]);
      JW.Add('value', AIch[I].AiValue);
      AIo.Add(JW);
    end;
    Root.Add('aiChannels', AIo);
    JW := TJSONObject.Create;
    JW.Add('s7', Comm.S7On);
    JW.Add('s7Port', Comm.S7Port);
    JW.Add('modbus', Comm.MbOn);
    JW.Add('modbusPort', Comm.MbPort);
    JW.Add('modbusUnit', Comm.MbUnit);
    JW.Add('holding', HoldingText(Comm));
    JW.Add('putGet', Comm.PutGet);
    JW.Add('allInterfaces', Comm.AllIfaces);
    JW.Add('ip', CommIp(Comm));
    JW.Add('mask', Comm.Mask);
    JW.Add('ipc', Comm.IpcOn);
    JW.Add('mcpWrite', Comm.McpWrite);
    Root.Add('comm', JW);
    if Pretty then Result := Root.FormatJSON else Result := Root.AsJSON;
  finally
    Root.Free;
  end;
end;

procedure TPlcProject.LoadFromFile(const AFile: string);
var
  SL: TStringList;
begin
  SL := TStringList.Create;
  try
    SL.LoadFromFile(AFile);
    LoadFromJsonText(SL.Text);
  finally
    SL.Free;
  end;
  FileName := AFile;
end;

procedure TPlcProject.LoadFromJsonText(const S: string);
var
  Data: TJSONData;
  Root, JB, JN, JC, JD, JV, JT, JW: TJSONObject;
  ABlocks, ANets, ACells, ADbs, AVars, ATags, AWatch, AStl, AP, AIo: TJSONArray;
  I, J, K, R, C, Mi: Integer;
  B: TBlock;
  N: TNetwork;
  Ce: TLadCell;
  D: TDataBlock;
  Kind: TBlockKind;
  Sec, Sc: TVarSection;
  Sk: TSigKind;
  F: TDispFmt;
  T: TDataType;
  Lo, Hi: Integer;
  Co: TCmpOp;
  Am: TAiMode;
  Txt: string;
begin
  Data := GetJSON(S);
  try
    if not (Data is TJSONObject) then raise Exception.Create('not a Virtual PLC project');
    Root := TJSONObject(Data);
    if Root.Get('format', '') <> 'VirtualPLC' then raise Exception.Create('not a Virtual PLC project');
    Clear;
    Name := Root.Get('name', 'Untitled');
    Author := Root.Get('author', '');
    Comment := Root.Get('comment', '');
    Mi := ModelIndexByName(Root.Get('cpu', ''));
    if Mi < 0 then Mi := 1;
    ModelIdx := Mi;
    CyclicMs := EnsureRange(Root.Get('cyclicMs', 100), 1, 60000);
    ClockByte := Root.Get('clockByte', -1);
    ABlocks := Root.Get('blocks', TJSONArray(nil));
    if ABlocks <> nil then
      for I := 0 to ABlocks.Count - 1 do
      begin
        JB := ABlocks.Objects[I];
        if JB.Get('kind', 'OB') = 'FC' then Kind := bkFC
        else if JB.Get('kind', 'OB') = 'FB' then Kind := bkFB
        else Kind := bkOB;
        B := TBlock.Create(Kind, JB.Get('number', 1), JB.Get('name', ''));
        B.Comment := JB.Get('comment', '');
        B.Version := JB.Get('version', '0.1');
        B.ObEvent := JB.Get('obEvent', -1);
        B.CycleMs := JB.Get('cycleMs', 0);
        B.PhaseMs := JB.Get('phaseMs', 0);
        B.TrigAddr := JB.Get('trigger', '');
        B.TrigEdge := JB.Get('edge', 0);
        B.TodStart := JB.Get('todStart', '');
        B.TodMode := JB.Get('todMode', 0);
        B.TodActive := JB.Get('todActive', False);
        B.Iface.Owner := Self;
        Blocks.Add(B);
        AVars := JB.Get('interface', TJSONArray(nil));
        if AVars <> nil then
          for J := 0 to AVars.Count - 1 do
          begin
            JV := AVars.Objects[J];
            Sec := vsStatic;
            for Sc := Low(TVarSection) to High(TVarSection) do
              if SameText(JV.Get('section', 'Static'), SectionNames[Sc]) then Sec := Sc;
            B.Iface.AddSecVar(Sec, JV.Get('name', ''), JV.Get('type', 'Int'), JV.Get('start', ''),
              JV.Get('comment', ''));
          end;
        ANets := JB.Get('networks', TJSONArray(nil));
        if ANets <> nil then
          for J := 0 to ANets.Count - 1 do
          begin
            JN := ANets.Objects[J];
            if (JN.Get('lang', 'LAD') = 'FBD') or (JN.Get('lang', 'LAD') = 'CFC') then
            begin
              if JN.Get('lang', 'LAD') = 'FBD' then N := B.AddNet(nkFBD) else N := B.AddNet(nkCFC);
              NodesFromJson(N, JN);
            end
            else if (JN.Get('lang', 'LAD') = 'STL') or (JN.Get('lang', 'LAD') = 'SCL') then
            begin
              if JN.Get('lang', 'LAD') = 'SCL' then
              begin
                N := B.AddNet(nkSCL);
                AStl := JN.Get('scl', TJSONArray(nil));
              end
              else
              begin
                N := B.AddNet(nkSTL);
                AStl := JN.Get('stl', TJSONArray(nil));
              end;
              if AStl <> nil then
                for K := 0 to AStl.Count - 1 do N.Stl.Add(AStl.Strings[K]);
            end
            else
            begin
              N := B.AddNet(nkLAD);
              N.SetRows(JN.Get('rows', 1));
              N.SetCols(JN.Get('cols', LadCols));
              ACells := JN.Get('cells', TJSONArray(nil));
              if ACells <> nil then
                for K := 0 to ACells.Count - 1 do
                begin
                  JC := ACells.Objects[K];
                  R := JC.Get('r', 0);
                  C := JC.Get('c', 0);
                  Ce := EmptyCell;
                  Ce.Kind := LadKindFromId(JC.Get('e', ''));
                  Ce.Opnd := JC.Get('op', '');
                  AP := JC.Get('p', TJSONArray(nil));
                  if AP <> nil then
                    for Mi := 0 to Min(4, AP.Count - 1) do Ce.P[Mi] := AP.Strings[Mi];
                  if ParseDataType(JC.Get('type', 'Int'), T, Lo, Hi) then Ce.DType := T;
                  Ce.DType2 := NewCell(Ce.Kind, '').DType2;
                  if JC.Find('type2') <> nil then
                    if ParseDataType(JC.Get('type2', 'Real'), T, Lo, Hi) then Ce.DType2 := T;
                  Ce.Args := JC.Get('args', '');
                  Txt := JC.Get('cmp', '==');
                  for Co := Low(TCmpOp) to High(TCmpOp) do
                    if CmpOpNames[Co] = Txt then Ce.Cmp := Co;
                  Ce.Down := JC.Get('down', False);
                  N.SetCell(R, C, Ce);
                end;
            end;
            N.Title := JN.Get('title', '');
            N.Comment := JN.Get('comment', '');
          end;
      end;
    SortBlocks;
    ADbs := Root.Get('types', TJSONArray(nil));
    if ADbs <> nil then
    begin
      for I := 0 to ADbs.Count - 1 do
      begin
        JD := ADbs.Objects[I];
        D := AddUdt(JD.Get('number', 1), JD.Get('name', ''));
        D.Comment := JD.Get('comment', '');
        AVars := JD.Get('members', TJSONArray(nil));
        if AVars <> nil then
          for J := 0 to AVars.Count - 1 do
          begin
            JV := AVars.Objects[J];
            D.AddVar(JV.Get('name', ''), JV.Get('type', 'Int'), JV.Get('start', ''), JV.Get('comment', ''));
          end;
      end;
      // a type may use one defined after it
      for I := 0 to UdtCount - 1 do Udt(I).Layout;
    end;
    ADbs := Root.Get('dbs', TJSONArray(nil));
    if ADbs <> nil then
      for I := 0 to ADbs.Count - 1 do
      begin
        JD := ADbs.Objects[I];
        D := AddDB(JD.Get('number', 1), JD.Get('name', ''));
        D.Comment := JD.Get('comment', '');
        D.Optimized := JD.Get('optimized', False);
        D.InstanceOf := JD.Get('instanceOf', 0);
        AVars := JD.Get('vars', TJSONArray(nil));
        if AVars <> nil then
          for J := 0 to AVars.Count - 1 do
          begin
            JV := AVars.Objects[J];
            D.AddVar(JV.Get('name', ''), JV.Get('type', 'Int'), JV.Get('start', ''), JV.Get('comment', ''));
            D.Vars[High(D.Vars)].Retain := JV.Get('retain', False);
          end;
        D.Layout;
      end;
    ATags := Root.Get('tags', TJSONArray(nil));
    if ATags <> nil then
      for I := 0 to ATags.Count - 1 do
      begin
        JT := ATags.Objects[I];
        AddTag(JT.Get('name', ''), JT.Get('type', 'Bool'), JT.Get('address', ''), JT.Get('comment', ''));
        Tags[High(Tags)].GroupId := JT.Get('group', 0);
      end;
    GroupsFromJson(Root.Get('tagGroups', TJSONArray(nil)), TagGroups);
    GroupsFromJson(Root.Get('watchGroups', TJSONArray(nil)), WatchGroups);
    AWatch := Root.Get('watch', TJSONArray(nil));
    if AWatch <> nil then WatchFromJson(AWatch);
    AIo := Root.Get('signals', TJSONArray(nil));
    if AIo <> nil then
      for I := 0 to AIo.Count - 1 do
      begin
        JW := AIo.Objects[I];
        K := AddSignal(JW.Get('address', ''), sgConst, JW.Get('lo', 0.0), JW.Get('hi', 1.0), JW.Get('period', 1000.0),
          JW.Get('duty', 50.0));
        for Sk := Low(TSigKind) to High(TSigKind) do
          if SameText(SigKindNames[Sk], JW.Get('kind', '')) then Signals[K].Kind := Sk;
        Signals[K].On := JW.Get('on', False);
        Signals[K].Comment := JW.Get('comment', '');
      end;
    AIo := Root.Get('diTypes', TJSONArray(nil));
    if AIo <> nil then
      for I := 0 to Min(High(DIch), AIo.Count - 1) do
        DIch[I].InType := TInType(EnsureRange(AIo.Integers[I], 0, Ord(High(TInType))));
    AIo := Root.Get('aiChannels', TJSONArray(nil));
    if AIo <> nil then
      for I := 0 to Min(High(AIch), AIo.Count - 1) do
      begin
        JW := AIo.Objects[I];
        Txt := JW.Get('mode', 'manual');
        for Am := Low(TAiMode) to High(TAiMode) do
          if AiModeNames[Am] = Txt then AIch[I].AiMode := Am;
        AIch[I].AiValue := EnsureRange(JW.Get('value', 0), -32768, 32767);
      end;
    JW := Root.Get('comm', TJSONObject(nil));
    if JW <> nil then
    begin
      Comm.S7On := JW.Get('s7', True);
      Comm.S7Port := EnsureRange(JW.Get('s7Port', 102), 1, 65535);
      Comm.MbOn := JW.Get('modbus', True);
      Comm.MbPort := EnsureRange(JW.Get('modbusPort', 502), 1, 65535);
      Comm.MbUnit := EnsureRange(JW.Get('modbusUnit', 1), 0, 255);
      SetHolding(Comm, JW.Get('holding', 'M'));
      Comm.PutGet := JW.Get('putGet', False);
      Comm.AllIfaces := JW.Get('allInterfaces', False);
      Comm.IpAddr := JW.Get('ip', '');
      Comm.IpAddr := CommIp(Comm);
      Comm.AllIfaces := Comm.IpAddr = '0.0.0.0';
      Comm.Mask := JW.Get('mask', '255.255.255.0');
      Comm.IpcOn := JW.Get('ipc', False);
      Comm.McpWrite := JW.Get('mcpWrite', False);
      if not IsIPv4(Comm.Mask) then Comm.Mask := '255.255.255.0';
    end;
    SyncObIfaces;
    Modified := False;
  finally
    Data.Free;
  end;
end;

{ ---------- new / sample projects ---------- }

procedure TPlcProject.NewEmpty(AModel: Integer);
var
  B: TBlock;
begin
  Clear;
  ModelIdx := EnsureRange(AModel, 0, ModelCount - 1);
  Name := 'New ' + FamilyNames[Family] + ' project';
  B := AddBlock(bkOB, 1, 'Main');
  B.Comment := 'Main program cycle';
  B.AddNet(nkLAD);
  Modified := False;
end;

procedure TPlcProject.LoadSample(AModel: Integer);
var
  B: TBlock;
  N: TNetwork;
  D, U: TDataBlock;
  M: TCpuModel;
  Fam: TCpuFamily;
  AIW, QB: string;
  Ce: TLadCell;

  function Q(Bit: Integer): string;
  begin
    if IsTia(Fam) then Result := Format('%%Q0.%d', [Bit]) else Result := Format('Q4.%d', [Bit]);
  end;

  function A(const S: string): string;
  begin
    if IsTia(Fam) then Result := '%' + S else Result := S;
  end;

  procedure Lad(R, C: Integer; K: TLadKind; const Op: string; ADown: Boolean = False);
  begin
    Ce := NewCell(K, Op);
    Ce.Down := ADown;
    N.SetCell(R, C, Ce);
  end;

  { OB1: a LAD CALL box with the parameter pins of FC2 "Clamp" }
  procedure AddLimitNet;
  begin
    N := B.AddNet(nkLAD);
    N.Title := 'Speed limit: FC2 with parameters in a LAD CALL box';
    N.Comment := 'the pins are the FC interface: Value, Lo, Hi, Limited =>, Ret_Val =>';
    Lad(0, 0, lkNO, '"Motor".Running');
    Ce := NewCell(lkCall, 'FC2');
    Ce.Args := '"Motor".SpeedRpm|0.0|1000.0|"Motor".OverLimit|"Motor".SpeedLim';
    N.SetCell(0, 1, Ce);
  end;

  procedure AddSclFC;
  var
    F: TBlock;
    Nf: TNetwork;
    Di: TDataBlock;
  begin
    F := AddBlock(bkFC, 1, 'SpeedStats');
    F.Comment := 'written in SCL';
    Nf := F.AddNet(nkSCL);
    Nf.Title := 'Speed history, average, class and run seconds';
    Nf.Comment := 'SCL: REGION, an array of a PLC data type with a variable index, CASE ranges, an FB call';
    Nf.Stl.Text :=
      'VAR_TEMP' + LineEnding +
      '    i : Int;' + LineEnding +
      '    sum : DInt;' + LineEnding +
      '    lim : Bool;' + LineEnding +
      'END_VAR' + LineEnding +
      '' + LineEnding +
      'REGION speed history and average, once per second' + LineEnding +
      '    IF "Clock_1Hz" AND NOT "Motor".ClockOld THEN' + LineEnding +
      '        FOR #i := 3 TO 1 BY -1 DO' + LineEnding +
      '            "Motor".History[#i] := "Motor".History[#i - 1];   // the whole struct' + LineEnding +
      '        END_FOR;' + LineEnding +
      '        "Motor".History[0].Rpm := REAL_TO_INT("Motor".SpeedRpm);' + LineEnding +
      '        "Motor".History[0].Running := "Motor".Running;' + LineEnding +
      '        #sum := 0;' + LineEnding +
      '        FOR #i := 0 TO 3 DO' + LineEnding +
      '            #sum := #sum + "Motor".History[#i].Rpm;' + LineEnding +
      '        END_FOR;' + LineEnding +
      '        "Motor".AvgRpm := "Clamp"(Value := DINT_TO_REAL(#sum) / 4.0,' + LineEnding +
      '                                  Lo := 0.0, Hi := 1200.0, Limited => #lim);' + LineEnding +
      '    END_IF;' + LineEnding +
      '    "Motor".ClockOld := "Clock_1Hz";' + LineEnding +
      'END_REGION' + LineEnding +
      '' + LineEnding +
      'REGION speed class for the HMI' + LineEnding +
      '    CASE REAL_TO_INT("Motor".SpeedRpm) OF' + LineEnding +
      '        0..499:' + LineEnding +
      '            "Motor".SpeedClass := 1;' + LineEnding +
      '        500..999:' + LineEnding +
      '            "Motor".SpeedClass := 2;' + LineEnding +
      '        1000..1200:' + LineEnding +
      '            "Motor".SpeedClass := 3;' + LineEnding +
      '    ELSE' + LineEnding +
      '        "Motor".SpeedClass := 4;' + LineEnding +
      '    END_CASE;' + LineEnding +
      'END_REGION' + LineEnding +
      '' + LineEnding +
      '// an FB with parameters: the run seconds are counted in its instance DB' + LineEnding +
      '"RunMeter_DB"(Run := "Motor".Running, Seconds => "Motor".Seconds);';
    // FB1 "RunMeter": a TON in its static data, one pulse per second while Run
    F := AddBlock(bkFB, 1, 'RunMeter');
    F.Comment := 'run seconds (SCL, an IEC timer in the instance)';
    F.Iface.AddSecVar(vsInput, 'Run', 'Bool', 'FALSE', 'count while TRUE');
    F.Iface.AddSecVar(vsOutput, 'Seconds', 'DInt', '0', 'run seconds');
    F.Iface.AddSecVar(vsStatic, 'Pulse', 'IEC_TIMER', '', 'one pulse per second');
    Nf := F.AddNet(nkSCL);
    Nf.Title := 'Count the seconds while Run';
    Nf.Comment := 'SCL in an FB: #Run, #Seconds and #Pulse live in the instance DB';
    Nf.Stl.Text :=
      '#Pulse.TON(IN := #Run AND NOT #Pulse.Q, PT := T#1S);' + LineEnding +
      'IF #Pulse.Q THEN' + LineEnding +
      '    #Seconds := #Seconds + 1;' + LineEnding +
      'END_IF;';
    // FC2 "Clamp": an FC with parameters and a Return value
    F := AddBlock(bkFC, 2, 'Clamp');
    F.Comment := 'limit a value (an FC with a Return value)';
    F.Iface.AddSecVar(vsInput, 'Value', 'Real', '', 'the value');
    F.Iface.AddSecVar(vsInput, 'Lo', 'Real', '', 'lower limit');
    F.Iface.AddSecVar(vsInput, 'Hi', 'Real', '', 'upper limit');
    F.Iface.AddSecVar(vsOutput, 'Limited', 'Bool', '', 'TRUE when the value was outside');
    F.Iface.AddSecVar(vsReturn, 'Ret_Val', 'Real', '', 'the limited value');
    Nf := F.AddNet(nkSCL);
    Nf.Title := 'Limit Value to Lo..Hi';
    Nf.Comment := 'SCL in an FC: the parameters are in its local data, #Ret_Val is the function value';
    Nf.Stl.Text :=
      '#Ret_Val := LIMIT(MN := #Lo, IN := #Value, MX := #Hi);' + LineEnding +
      '#Limited := #Ret_Val <> #Value;';
    Di := AddDB(2, 'RunMeter_DB');
    Di.InstanceOf := 1;
    Di.Optimized := D.Optimized;
    Di.Layout;
  end;

  procedure Wires(R, C0, C1: Integer);
  var
    C: Integer;
  begin
    for C := C0 to C1 do N.SetCell(R, C, NewCell(lkWire, ''));
  end;

begin
  Clear;
  ModelIdx := EnsureRange(AModel, 0, ModelCount - 1);
  M := Models[ModelIdx];
  Fam := M.Family;
  Name := 'Motor start/stop (' + FamilyNames[Fam] + ')';
  Author := 'Virtual PLC';
  Comment := 'Motor with self holding, start-up timer, start counter, analog speed and run time in the cyclic interrupt';
  ClockByte := 0;   // MB0: M0.5 = 1 Hz
  // the sample is meant for trying HMIs / snap7 at once: PUT/GET permitted on the S7-1200
  Comm.PutGet := True;
  CyclicMs := 100;
  QB := Q(0);
  if IsTia(Fam) then AIW := 'IW' + IntToStr(M.AIWord) else AIW := 'PIW' + IntToStr(M.AIWord);

  // tags
  AddTag('Start_PB', 'Bool', A('I0.0'), 'start push button (NO)');
  AddTag('Stop_PB', 'Bool', A('I0.1'), 'stop push button, wired NC: 1 = not pressed');
  AddTag('Overload_OK', 'Bool', A('I0.2'), 'motor protection switch, 1 = healthy');
  AddTag('Reset_Count', 'Bool', A('I0.3'), 'resets the start counter');
  AddTag('Motor', 'Bool', Q(0), 'motor contactor');
  AddTag('Full_Speed', 'Bool', Q(1), 'start-up finished (star -> delta)');
  AddTag('Service_Due', 'Bool', Q(2), 'start counter reached its preset');
  AddTag('Starting_Lamp', 'Bool', Q(3), 'flashes 1 Hz during start-up');
  AddTag('Overspeed', 'Bool', Q(4), 'speed above 1200 rpm');
  AddTag('Clock_1Hz', 'Bool', A('M0.5'), 'clock memory byte MB0');
  AddTag('Start_Edge', 'Bool', A('M10.0'), 'edge memory of the motor start');
  if IsTia(Fam) then
    AddTag('Speed_AI', 'Int', '%' + AIW, 'speed sensor 0..10 V = 0..27648')
  else
    AddTag('Speed_AI', 'Int', AIW, 'speed sensor 0..10 V = 0..27648');
  DIch[0].InType := itPushNO;
  DIch[1].InType := itPushNC;
  DIch[2].InType := itToggle;
  DIch[3].InType := itPushNO;
  AIch[0].AiMode := amManual;
  AIch[0].AiValue := 13824;
  AIch[1].AiMode := amSine;

  D := AddDB(1, 'Motor');
  D.Comment := 'motor data';
  D.AddVar('SpeedRpm', 'Real', '0.0', 'scaled speed');
  D.AddVar('RunTime', 'DInt', '0', 'run time in 100 ms (cyclic interrupt)');
  D.AddVar('Startups', 'Int', '0', 'CPU start-ups (OB100)');
  D.AddVar('Running', 'Bool', 'FALSE', 'copy of the motor contactor');
  D.AddVar('SpeedNorm', 'Real', '0.0', 'speed 0..1 (NORM_X)');
  if IsTia(Fam) then
  begin
    D.AddVar('StartDelay', 'IEC_TIMER', '', 'TON: star -> delta after 5 s');
    D.AddVar('Starts', 'IEC_COUNTER', '', 'CTU: motor starts');
  end;
  U := AddUdt(1, 'SpeedSample');
  U.Comment := 'one entry of the speed history';
  U.AddVar('Rpm', 'Int', '0', 'speed in rpm');
  U.AddVar('Running', 'Bool', 'FALSE', 'motor running at the sample');
  D.AddVar('History', 'Array[0..3] of ' + UdtTypeName(U), '', 'speed history (FC1, SCL): array of a PLC data type');
  // new variables at the end: the absolute addresses above stay the same
  D.AddVar('AvgRpm', 'Real', '0.0', 'average of the history (FC1, SCL)');
  D.AddVar('SpeedClass', 'Int', '0', '1 slow .. 4 too fast (FC1, SCL CASE)');
  D.AddVar('ClockOld', 'Bool', 'FALSE', 'edge memory of the 1 Hz clock');
  D.AddVar('Seconds', 'DInt', '0', 'motor run seconds (FB1 "RunMeter")');
  D.AddVar('OverLimit', 'Bool', 'FALSE', 'speed above 1000 rpm (FC2 in LAD)');
  D.AddVar('SpeedLim', 'Real', '0.0', 'speed limited to 0..1000 rpm (FC2 in LAD)');

  if IsTia(Fam) then
  begin
    // ---------- S7-1200: LAD with IEC timers / counters ----------
    B := AddBlock(bkOB, 1, 'Main');
    B.Comment := 'Program cycle';
    N := B.AddNet(nkLAD);
    N.Title := 'Motor start / stop with self holding';
    N.Comment := 'Stop_PB is wired NC: the contact is a NO contact on the input (fail safe)';
    N.SetRows(2);
    Lad(0, 0, lkNO, '"Start_PB"', True);
    Lad(0, 1, lkNO, '"Stop_PB"');
    Lad(0, 2, lkNO, '"Overload_OK"');
    Wires(0, 3, 6);
    Lad(0, 7, lkCoil, '"Motor"');
    Lad(1, 0, lkNO, '"Motor"');
    N := B.AddNet(nkLAD);
    N.Title := 'Start-up timer: full speed after 5 s';
    Lad(0, 0, lkNO, '"Motor"');
    Lad(0, 1, lkTON, '"Motor".StartDelay');
    N.Cells[1].P[0] := 'T#5S';
    Wires(0, 2, 6);
    Lad(0, 7, lkCoil, '"Full_Speed"');
    N := B.AddNet(nkLAD);
    N.Title := 'Start counter: service after 5 starts';
    Lad(0, 0, lkNO, '"Motor"');
    Lad(0, 1, lkCTU, '"Motor".Starts');
    N.Cells[1].P[0] := '5';
    N.Cells[1].P[1] := '"Reset_Count"';
    N.Cells[1].P[2] := 'MW20';
    Wires(0, 2, 6);
    Lad(0, 7, lkCoil, '"Service_Due"');
    N := B.AddNet(nkLAD);
    N.Title := 'Starting lamp flashes with the 1 Hz clock';
    Lad(0, 0, lkNO, '"Motor"');
    Lad(0, 1, lkNC, '"Full_Speed"');
    Lad(0, 2, lkNO, '"Clock_1Hz"');
    Wires(0, 3, 6);
    Lad(0, 7, lkCoil, '"Starting_Lamp"');
    N := B.AddNet(nkLAD);
    N.Title := 'Analog speed: NORM_X + SCALE_X, overspeed above 1200 rpm';
    N.SetRows(2);
    Lad(0, 0, lkNormX, '');
    N.Cells[0].P[0] := '0';
    N.Cells[0].P[1] := '"Speed_AI"';
    N.Cells[0].P[2] := '27648';
    N.Cells[0].P[3] := '"Motor".SpeedNorm';
    Lad(0, 1, lkScaleX, '');
    N.Cells[1].DType := dtReal;
    N.Cells[1].P[0] := '0.0';
    N.Cells[1].P[1] := '"Motor".SpeedNorm';
    N.Cells[1].P[2] := '1500.0';
    N.Cells[1].P[3] := '"Motor".SpeedRpm';
    Lad(1, 0, lkCmp, '');
    Ce := N.Cell(1, 0);
    Ce.DType := dtReal;
    Ce.Cmp := coGT;
    Ce.P[0] := '"Motor".SpeedRpm';
    Ce.P[1] := '1200.0';
    N.SetCell(1, 0, Ce);
    Wires(1, 1, 6);
    Lad(1, 7, lkCoil, '"Overspeed"');
    N := B.AddNet(nkLAD);
    N.Title := 'Copy of the motor state into the DB';
    Lad(0, 0, lkNO, '"Motor"');
    Wires(0, 1, 6);
    Lad(0, 7, lkCoil, '"Motor".Running');
    if Fam = cfS71500 then
    begin
      // the S7-1500 still runs STL (with 4 accumulators) for programs moved from the S7-300/400
      N := B.AddNet(nkSTL);
      N.Title := 'S7-1500: STL with four accumulators and an S5 timer';
      N.Comment := 'T5 restarts itself every second while the motor runs; C5 counts the seconds';
      N.Stl.Text :=
        'L     "Motor".Startups' + LineEnding +
        'L     10' + LineEnding +
        'ENT' + LineEnding +
        'L     3' + LineEnding +
        '*I                        // Startups + 10 * 3' + LineEnding +
        '+I' + LineEnding +
        'T     %MW22' + LineEnding +
        'A     "Motor"' + LineEnding +
        'AN    T     5' + LineEnding +
        'CU    C     5             // counts each time T5 ran out (before it restarts)' + LineEnding +
        'A     "Motor"' + LineEnding +
        'AN    T     5             // restarts itself when it ran out' + LineEnding +
        'L     S5T#1S' + LineEnding +
        'SE    T     5' + LineEnding +
        'A     T     5' + LineEnding +
        '=     %M12.1' + LineEnding +
        'L     C     5' + LineEnding +
        'T     %MW24';
    end;

    N := B.AddNet(nkLAD);
    N.Title := 'Speed statistics in SCL (FC1)';
    Lad(0, 0, lkCall, 'FC1');
    AddSclFC;
    AddLimitNet;

    B := AddBlock(bkOB, 30, 'Cyclic interrupt');
    B.Comment := 'every 100 ms';
    N := B.AddNet(nkLAD);
    N.Title := 'Run time in 100 ms steps';
    Lad(0, 0, lkNO, '"Motor"');
    Lad(0, 1, lkAdd, '');
    Ce := N.Cell(0, 1);
    Ce.DType := dtDInt;
    Ce.P[0] := '"Motor".RunTime';
    Ce.P[1] := '1';
    Ce.P[2] := '"Motor".RunTime';
    N.SetCell(0, 1, Ce);

    B := AddBlock(bkOB, 100, 'Startup');
    N := B.AddNet(nkLAD);
    N.Title := 'Count the CPU start-ups';
    Lad(0, 0, lkAdd, '');
    Ce := N.Cell(0, 0);
    Ce.DType := dtInt;
    Ce.P[0] := '"Motor".Startups';
    Ce.P[1] := '1';
    Ce.P[2] := '"Motor".Startups';
    N.SetCell(0, 0, Ce);
  end
  else
  begin
    // ---------- S7-300 / S7-400: STL with S5 timers / counters, and LAD ----------
    B := AddBlock(bkOB, 1, 'Main');
    B.Comment := 'Main program cycle';
    N := B.AddNet(nkSTL);
    N.Title := 'Motor start / stop with self holding';
    N.Comment := 'Stop_PB is wired NC: scanned with A (fail safe)';
    N.Stl.Text :=
      'A(' + LineEnding +
      'O     "Start_PB"          // start' + LineEnding +
      'O     "Motor"             // self holding' + LineEnding +
      ')' + LineEnding +
      'A     "Stop_PB"           // NC stop button' + LineEnding +
      'A     "Overload_OK"' + LineEnding +
      '=     "Motor"';
    N := B.AddNet(nkSTL);
    N.Title := 'Start-up timer: S5 on-delay T1, full speed after 5 s';
    N.Stl.Text :=
      'A     "Motor"' + LineEnding +
      'L     S5T#5S' + LineEnding +
      'SD    T     1' + LineEnding +
      'A     T     1' + LineEnding +
      '=     "Full_Speed"';
    N := B.AddNet(nkSTL);
    N.Title := 'Start counter C1: service after 5 starts';
    N.Stl.Text :=
      'A     "Motor"' + LineEnding +
      'CU    C     1             // counts on the rising edge' + LineEnding +
      'A     "Reset_Count"' + LineEnding +
      'R     C     1' + LineEnding +
      'L     C     1' + LineEnding +
      'T     MW    20' + LineEnding +
      'L     5' + LineEnding +
      '>=I' + LineEnding +
      '=     "Service_Due"';
    N := B.AddNet(nkLAD);
    N.Title := 'Starting lamp flashes with the 1 Hz clock';
    Lad(0, 0, lkNO, '"Motor"');
    Lad(0, 1, lkNC, '"Full_Speed"');
    Lad(0, 2, lkNO, '"Clock_1Hz"');
    Wires(0, 3, 6);
    Lad(0, 7, lkCoil, '"Starting_Lamp"');
    N := B.AddNet(nkSTL);
    N.Title := 'Analog speed 0..27648 -> 0..1500 rpm, overspeed above 1200 rpm';
    N.Stl.Text :=
      'L     "Speed_AI"          // peripheral input word' + LineEnding +
      'ITD' + LineEnding +
      'DTR' + LineEnding +
      'L     2.764800e+004' + LineEnding +
      '/R' + LineEnding +
      'T     "Motor".SpeedNorm' + LineEnding +
      'L     1.500000e+003' + LineEnding +
      '*R' + LineEnding +
      'T     "Motor".SpeedRpm' + LineEnding +
      'L     1.200000e+003' + LineEnding +
      '>R' + LineEnding +
      '=     "Overspeed"';
    N := B.AddNet(nkLAD);
    N.Title := 'Copy of the motor state into the DB';
    Lad(0, 0, lkNO, '"Motor"');
    Wires(0, 1, 6);
    Lad(0, 7, lkCoil, 'DB1.DBX10.0');
    if Fam = cfS7400 then
    begin
      N := B.AddNet(nkSTL);
      N.Title := 'S7-400: four accumulators (ENT keeps the operands)';
      N.Stl.Text :=
        'L     "Motor".Startups' + LineEnding +
        'L     10' + LineEnding +
        'ENT' + LineEnding +
        'L     3' + LineEnding +
        '*I                        // (Startups) + 10 * 3' + LineEnding +
        '+I' + LineEnding +
        'T     MW    22';
    end;

    N := B.AddNet(nkLAD);
    N.Title := 'Speed statistics in SCL (FC1)';
    Lad(0, 0, lkCall, 'FC1');
    AddSclFC;
    AddLimitNet;

    B := AddBlock(bkOB, 35, 'Cyclic interrupt');
    B.Comment := 'every 100 ms';
    N := B.AddNet(nkSTL);
    N.Title := 'Run time in 100 ms steps';
    N.Stl.Text :=
      'AN    "Motor"' + LineEnding +
      'JC    END' + LineEnding +
      'L     "Motor".RunTime' + LineEnding +
      '+     L#1' + LineEnding +
      'T     "Motor".RunTime' + LineEnding +
      'END:  NOP   0';

    B := AddBlock(bkOB, 100, 'Complete restart');
    N := B.AddNet(nkSTL);
    N.Title := 'Count the CPU start-ups';
    N.Stl.Text :=
      'L     DB1.DBW8' + LineEnding +
      '+     1' + LineEnding +
      'T     DB1.DBW8';
  end;

  AddWatch('"Motor"', dfBool);
  AddWatch('"Start_PB"', dfBool, 'TRUE');
  AddWatch('"Stop_PB"', dfBool);
  if IsTia(Fam) then
  begin
    AddWatch('"Motor".StartDelay.ET', dfTime);
    AddWatch('"Motor".Starts.CV', dfDec);
  end
  else
  begin
    AddWatch('T1', dfS5Time);
    AddWatch('C1', dfCounter);
  end;
  AddWatch('MW20', dfDec, '0');
  AddWatch('"Speed_AI"', dfDec);
  AddWatch('"Motor".SpeedRpm', dfReal);
  AddWatch('"Motor".RunTime', dfDec);
  AddWatch('"Motor".Startups', dfDec);
  AddWatch('MB0', dfBin);
  AddWatch('"Motor".AvgRpm', dfReal);
  AddWatch('"Motor".SpeedClass', dfDec);
  AddWatch('"Motor".Seconds', dfDec);
  Modified := False;
end;

end.
