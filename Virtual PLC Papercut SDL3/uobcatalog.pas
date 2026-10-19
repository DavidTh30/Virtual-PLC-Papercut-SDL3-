unit uObCatalog;

{ The organization blocks of each CPU family: the standard OBs with their numbers, names, event classes
  and priorities, which events a user OB of its own number (>= 123, S7-1200 / 1500) can have, and the
  start information of an OB as the CPU writes it at its start:
    - S7-1200 / S7-1500: the Input section of the interface (Initial_Call, LADDR, Fault_ID, ..)
    - S7-300 / S7-400: the first 20 bytes of the local data (Temp): OBnn_EV_CLASS .. OBnn_DATE_TIME }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, uPlcTypes;

type
  TObEvent = (oeProgramCycle, oeStartup, oeTimeOfDay, oeTimeDelay, oeCyclic, oeHardware, oeStatus, oeUpdate,
    oeProfile, oeSyncCycle, oeMultiComputing, oeTimeError, oePowerSupply, oeDiagnostic, oePullPlug, oeCpuFault,
    oeProgExec, oeRackFailure, oeCommError, oeProcessing, oeBackground, oeHotRestart, oeColdRestart,
    oeProgError, oeIoAccess);

  TObInfo = record
    Number: Integer;
    Event: TObEvent;
    Name: string;        // the default name (TIA, or the symbol of STEP 7 classic)
    Prio: Integer;       // the default priority
  end;
  TObInfos = array of TObInfo;

  { a variable of the start information }
  TObStartVar = record
    Name, TypeText, Comment: string;
    InputSec: Boolean;   // TIA: the Input section; classic: Temp
  end;
  TObStartVars = array of TObStartVar;
  TObEventList = array of TObEvent;

const
  ObEventNames: array[TObEvent] of string = ('Program cycle', 'Startup', 'Time of day', 'Time delay interrupt',
    'Cyclic interrupt', 'Hardware interrupt', 'Status', 'Update', 'Profile', 'Synchronous cycle',
    'Multicomputing interrupt', 'Time error interrupt', 'Power supply error', 'Diagnostic error interrupt',
    'Pull or plug of modules', 'CPU hardware fault', 'Program execution error', 'Rack or station failure',
    'Communication error', 'Processing interrupt', 'Background', 'Hot restart', 'Cold restart',
    'Programming error', 'IO access error');
  { what starts the OB in the Virtual PLC }
  ObEventStart: array[TObEvent] of string = (
    'every cycle (OB1 first, then the others by number)',
    'STOP -> RUN, before the first cycle (OB100 first, then the others by number)',
    'the PC clock: the start date / time and the interval of the OB',
    'SRT_DINT(OB_NR := .., DTIME := T#.., SIGN := ..) in the program; CAN_DINT cancels',
    'its cycle time (and phase), between the networks of the cycle',
    'an edge of its input (rising / falling / both), as a channel''s hardware interrupt',
    'not started by the Virtual PLC (DPV1 / PROFINET status alarm)',
    'not started by the Virtual PLC (DPV1 / PROFINET update alarm)',
    'not started by the Virtual PLC (manufacturer specific alarm)',
    'not started by the Virtual PLC (isochronous mode)',
    'not started by the Virtual PLC (multicomputing)',
    'the cycle time exceeded (watchdog): the CPU stays in RUN, the cycle time starts again once',
    'not started by the Virtual PLC (power supply)',
    'I/O screen, Fault injection: Diagnostic interrupt',
    'I/O screen, Fault injection: Pull / plug module',
    'not started by the Virtual PLC (CPU hardware)',
    'not started by the Virtual PLC (priority class error)',
    'I/O screen, Fault injection: PROFINET IO station failure / return',
    'not started by the Virtual PLC (communication)',
    'not started by the Virtual PLC (processing interrupt)',
    'not started by the Virtual PLC (background)',
    'not started by the Virtual PLC (hot restart: complete restart here)',
    'not started by the Virtual PLC (cold restart: complete restart here)',
    'a programming error (area length, no DB, ..): the program goes on after the instruction',
    'an access to an I/O address that is not there (PI / PQ): the program goes on');

{ the standard OBs of a family, by number }
function ObCatalog(F: TCpuFamily): TObInfos;
{ the catalog entry of a number (Found: a standard OB of the family) }
function ObInfoOf(F: TCpuFamily; Number: Integer; out Info: TObInfo): Boolean;
{ the events a family has (in the order of the catalog) }
function ObEvents(F: TCpuFamily): TObEventList;
{ an OB of its own number (>= 123, S7-1200 / 1500) can have this event }
function ObCustomOk(F: TCpuFamily; E: TObEvent): Boolean;
{ the event of an OB: the stored one (Stored >= 0), else the standard OB's, else program cycle }
function ObEventOf(F: TCpuFamily; Number, Stored: Integer): TObEvent;
{ the Virtual PLC starts OBs of this event }
function ObSimulated(E: TObEvent): Boolean;
{ the default cycle time of a cyclic interrupt OB (OB30 5 s .. OB38 10 ms; a custom one 100 ms) }
function ObDefaultCycleMs(Number: Integer): Integer;
{ the start information of an OB }
function ObStartInfo(F: TCpuFamily; E: TObEvent; Number: Integer): TObStartVars;
{ the meaning of a start information variable: its name without OBnn_ (upper case): EV_CLASS, INITIAL_CALL .. }
function ObStartKey(const VarName: string): string;
{ the event class (classic: OBnn_EV_CLASS) of an event }
function ObEvClass(E: TObEvent): Byte;
{ the start of a time of day OB: 'yyyy-mm-dd hh:mm:ss' (the seconds may be left out) }
function ParseTodStart(const S: string; out DT: TDateTime): Boolean;
function FormatTodStart(DT: TDateTime): string;
{ the time of day OB: its intervals }
const
  TodModeNames: array[0..6] of string = ('once', 'every minute', 'every hour', 'every day', 'every week',
    'every month', 'every year');

implementation

procedure AddOb(var L: TObInfos; N: Integer; E: TObEvent; const Nm: string; P: Integer);
var
  K: Integer;
begin
  K := Length(L);
  SetLength(L, K + 1);
  L[K].Number := N;
  L[K].Event := E;
  L[K].Name := Nm;
  L[K].Prio := P;
end;

function ObCatalog(F: TCpuFamily): TObInfos;
var
  K: Integer;
  Tia: Boolean;
begin
  Result := nil;
  Tia := IsTia(F);
  if Tia then
  begin
    AddOb(Result, 1, oeProgramCycle, 'Main', 1);
    for K := 10 to 17 do
      if K = 10 then AddOb(Result, K, oeTimeOfDay, 'Time of day', 2)
      else AddOb(Result, K, oeTimeOfDay, Format('Time of day %d', [K - 10]), 2);
    for K := 20 to 23 do
      if K = 20 then AddOb(Result, K, oeTimeDelay, 'Time delay interrupt', 3)
      else AddOb(Result, K, oeTimeDelay, Format('Time delay interrupt %d', [K - 20]), 3 + K - 20);
    for K := 30 to 38 do
      if K = 30 then AddOb(Result, K, oeCyclic, 'Cyclic interrupt', 8)
      else AddOb(Result, K, oeCyclic, Format('Cyclic interrupt %d', [K - 30]), 8 + K - 30);
    for K := 40 to 47 do
      if K = 40 then AddOb(Result, K, oeHardware, 'Hardware interrupt', 16)
      else AddOb(Result, K, oeHardware, Format('Hardware interrupt %d', [K - 40]), 16 + K - 40);
    AddOb(Result, 55, oeStatus, 'Status', 4);
    AddOb(Result, 56, oeUpdate, 'Update', 4);
    AddOb(Result, 57, oeProfile, 'Profile', 4);
    if F = cfS71500 then
      for K := 61 to 64 do
        if K = 61 then AddOb(Result, K, oeSyncCycle, 'Synchronous Cycle', 21)
        else AddOb(Result, K, oeSyncCycle, Format('Synchronous Cycle %d', [K - 61]), 21);
    AddOb(Result, 80, oeTimeError, 'Time error interrupt', 22);
    AddOb(Result, 82, oeDiagnostic, 'Diagnostic error interrupt', 5);
    AddOb(Result, 83, oePullPlug, 'Pull or plug of modules', 6);
    AddOb(Result, 86, oeRackFailure, 'Rack or station failure', 6);
    AddOb(Result, 100, oeStartup, 'Startup', 1);
    if F = cfS71500 then
    begin
      AddOb(Result, 121, oeProgError, 'Programming error', 7);
      AddOb(Result, 122, oeIoAccess, 'IO access error', 7);
    end;
    Exit;
  end;
  // STEP 7 classic: the symbols of the standard library
  AddOb(Result, 1, oeProgramCycle, 'CYCL_EXC', 1);
  if F = cfS7400 then
  begin
    for K := 10 to 17 do AddOb(Result, K, oeTimeOfDay, Format('TOD_INT%d', [K - 10]), 2);
    for K := 20 to 23 do AddOb(Result, K, oeTimeDelay, Format('DEL_INT%d', [K - 20]), 3 + K - 20);
    for K := 30 to 38 do AddOb(Result, K, oeCyclic, Format('CYC_INT%d', [K - 30]), 7 + K - 30);
    for K := 40 to 47 do AddOb(Result, K, oeHardware, Format('HW_INT%d', [K - 40]), 16 + K - 40);
  end
  else
  begin
    AddOb(Result, 10, oeTimeOfDay, 'TOD_INT0', 2);
    AddOb(Result, 20, oeTimeDelay, 'DEL_INT0', 3);
    AddOb(Result, 35, oeCyclic, 'CYC_INT5', 12);
    AddOb(Result, 40, oeHardware, 'HW_INT0', 16);
  end;
  AddOb(Result, 55, oeStatus, 'DP: STATUS ALARM', 2);
  AddOb(Result, 56, oeUpdate, 'DP: UPDATE ALARM', 2);
  AddOb(Result, 57, oeProfile, 'DP: MANUFACTURE ALARM', 2);
  if F = cfS7400 then
  begin
    AddOb(Result, 60, oeMultiComputing, 'MULTICOMP', 25);
    for K := 61 to 64 do AddOb(Result, K, oeSyncCycle, Format('SYNC_%d', [K - 60]), 25);
  end
  else
    AddOb(Result, 61, oeSyncCycle, 'SYNC_1', 25);
  AddOb(Result, 80, oeTimeError, 'CYCL_FLT', 26);
  AddOb(Result, 81, oePowerSupply, 'PS_FLT', 26);
  AddOb(Result, 82, oeDiagnostic, 'I/O_FLT1', 26);
  AddOb(Result, 83, oePullPlug, 'I/O_FLT2', 26);
  AddOb(Result, 84, oeCpuFault, 'CPU_FLT', 26);
  AddOb(Result, 85, oeProgExec, 'OBNL_FLT', 26);
  AddOb(Result, 86, oeRackFailure, 'RACK_FLT', 26);
  AddOb(Result, 87, oeCommError, 'COMM_FLT', 26);
  if F = cfS7400 then
  begin
    AddOb(Result, 88, oeProcessing, 'BLCK_ABORT', 28);
    AddOb(Result, 90, oeBackground, 'BACKGROUND', 29);
  end;
  AddOb(Result, 100, oeStartup, 'COMPLETE RESTART', 27);
  if F = cfS7400 then
  begin
    AddOb(Result, 101, oeHotRestart, 'RESTART', 27);
    AddOb(Result, 102, oeColdRestart, 'COLD RESTART', 27);
  end;
  AddOb(Result, 121, oeProgError, 'PROG_ERR', 0);
  AddOb(Result, 122, oeIoAccess, 'MOD_ERR', 0);
end;

function ObInfoOf(F: TCpuFamily; Number: Integer; out Info: TObInfo): Boolean;
var
  L: TObInfos;
  K: Integer;
begin
  L := ObCatalog(F);
  for K := 0 to High(L) do
    if L[K].Number = Number then
    begin
      Info := L[K];
      Exit(True);
    end;
  FillChar(Info, SizeOf(Info), 0);
  Info.Number := Number;
  Result := False;
end;

function ObEvents(F: TCpuFamily): TObEventList;
var
  L: TObInfos;
  K, J: Integer;
  Seen: set of TObEvent;
begin
  Result := nil;
  Seen := [];
  L := ObCatalog(F);
  for K := 0 to High(L) do
    if not (L[K].Event in Seen) then
    begin
      Include(Seen, L[K].Event);
      J := Length(Result);
      SetLength(Result, J + 1);
      Result[J] := L[K].Event;
    end;
end;

function ObCustomOk(F: TCpuFamily; E: TObEvent): Boolean;
begin
  Result := IsTia(F) and (E in [oeProgramCycle, oeStartup, oeTimeOfDay, oeTimeDelay, oeCyclic, oeHardware,
    oeSyncCycle]);
  if (F = cfS71200) and (E = oeSyncCycle) then Result := False;
end;

function ObEventOf(F: TCpuFamily; Number, Stored: Integer): TObEvent;
var
  Info: TObInfo;
begin
  if ObInfoOf(F, Number, Info) then Exit(Info.Event);
  if (Stored >= Ord(Low(TObEvent))) and (Stored <= Ord(High(TObEvent))) then Exit(TObEvent(Stored));
  Result := oeProgramCycle;
end;

function ObSimulated(E: TObEvent): Boolean;
begin
  Result := E in [oeProgramCycle, oeStartup, oeTimeOfDay, oeTimeDelay, oeCyclic, oeHardware, oeTimeError,
    oeDiagnostic, oePullPlug, oeRackFailure, oeProgError, oeIoAccess];
end;

function ObDefaultCycleMs(Number: Integer): Integer;
const
  Ms: array[30..38] of Integer = (5000, 2000, 1000, 500, 200, 100, 50, 20, 10);
begin
  if (Number >= 30) and (Number <= 38) then Result := Ms[Number] else Result := 100;
end;

function ObEvClass(E: TObEvent): Byte;
begin
  case E of
    oeProgramCycle, oeTimeOfDay, oeTimeDelay, oeCyclic, oeHardware, oeStatus, oeUpdate, oeProfile,
    oeSyncCycle, oeMultiComputing, oeBackground: Result := $11;
    oeStartup, oeHotRestart, oeColdRestart: Result := $13;
    oeProgError, oeIoAccess: Result := $25;
    oeDiagnostic, oePullPlug, oeRackFailure: Result := $39;
  else
    Result := $35;
  end;
end;

procedure AddV(var L: TObStartVars; const Nm, Ty, Cm: string; Inp: Boolean);
var
  K: Integer;
begin
  K := Length(L);
  SetLength(L, K + 1);
  L[K].Name := Nm;
  L[K].TypeText := Ty;
  L[K].Comment := Cm;
  L[K].InputSec := Inp;
end;

function ObStartInfo(F: TCpuFamily; E: TObEvent; Number: Integer): TObStartVars;
var
  P: string;

  procedure I(const Nm, Ty, Cm: string);
  begin
    AddV(Result, Nm, Ty, Cm, True);
  end;

  procedure T(const Nm, Ty, Cm: string);
  begin
    AddV(Result, P + Nm, Ty, Cm, False);
  end;

  // classic: the 6 bytes of the head (byte 1 and byte 5 may have their own names)
  procedure Head(const B1, B5: string);
  begin
    T('EV_CLASS', 'Byte', 'event class (16#11: OB started)');
    if B1 <> '' then T(B1, 'Byte', 'start information') else T('STRT_INF', 'Byte', 'start information');
    T('PRIORITY', 'Byte', 'priority class');
    T('OB_NUMBR', 'Byte', 'OB number');
    T('RESERVED_1', 'Byte', 'reserved');
    if B5 <> '' then T(B5, 'Byte', '') else T('RESERVED_2', 'Byte', 'reserved');
  end;

begin
  Result := nil;
  if IsTia(F) then
  begin
    case E of
      oeProgramCycle:
        begin
          I('Initial_Call', 'Bool', 'Initial call of this OB');
          I('Remanence', 'Bool', '=True, if remanent data are available');
        end;
      oeStartup:
        begin
          I('LostRetentive', 'Bool', '=True, if retentive data are lost');
          I('LostRTC', 'Bool', '=True, if real time clock is lost');
        end;
      oeTimeOfDay:
        begin
          I('CaughtUp', 'Bool', '=True, if OB call is caught up because of time jump');
          I('SecondTimes', 'Bool', '=True, if OB is started for the second time because of time jump');
        end;
      oeTimeDelay: I('Sign', 'Word', 'Identifier passed when calling SRT_DINT');
      oeCyclic:
        begin
          I('Initial_Call', 'Bool', 'Initial call of this OB');
          I('Event_Count', 'Int', 'Number of skipped events');
        end;
      oeHardware:
        begin
          I('LADDR', 'Word', 'Hardware identifier (HW_IO)');
          I('USI', 'Word', 'User structure identifier (16#0001 to 16#FFFF reserved)');
          I('IChannel', 'USInt', 'Channel number');
          I('EventType', 'Byte', 'Event type: 1 rising edge, 2 falling edge');
        end;
      oeStatus, oeUpdate, oeProfile:
        begin
          I('LADDR', 'Word', 'Hardware identifier (HW_IO)');
          I('Slot', 'UInt', 'Slot number');
          I('Specifier', 'Word', 'Alarm specifier');
        end;
      oeSyncCycle:
        begin
          I('Initial_Call', 'Bool', 'Initial call of this OB');
          I('PIP_Input', 'Bool', 'Process image partition of inputs is up to date');
          I('PIP_Output', 'Bool', 'Process image partition of outputs is up to date');
          I('IO_System', 'USInt', 'Distributed IO system number');
          I('Event_Count', 'Int', 'Number of skipped events');
        end;
      oeTimeError:
        begin
          I('fault_id', 'Byte', 'Fault identifier: 16#01 cycle time exceeded');
          I('csg_OBnr', 'Int', 'Number of the OB that caused the error (OB_ANY)');
          I('csg_prio', 'UInt', 'Priority of the OB that caused the error');
        end;
      oeDiagnostic:
        begin
          I('IO_state', 'Word', 'IO state of the module');
          I('LADDR', 'Word', 'Hardware identifier (HW_ANY)');
          I('Channel', 'UInt', 'Channel number');
          I('MultiError', 'Bool', '=True, if more than one error is present');
        end;
      oePullPlug, oeRackFailure:
        begin
          I('LADDR', 'Word', 'Hardware identifier (HW_IO)');
          I('Event_Class', 'Byte', '16#38 / 16#39: module / station returning / failing');
          I('Fault_ID', 'Byte', 'Fault identifier');
        end;
      oeProgError, oeIoAccess:
        begin
          I('BlockNr', 'UInt', 'Number of the block of the error');
          I('Reaction', 'USInt', 'Reaction: 0 ignore, 1 substitute value, 2 skip instruction');
          I('Fault_ID', 'Byte', 'Fault identifier');
          I('BlockType', 'USInt', 'Block type: 1 OB, 2 FC, 3 FB');
          I('Area', 'USInt', 'Memory area of the access');
          I('DBNr', 'UInt', 'DB number (DB_ANY)');
          I('Csg_OBNr', 'Int', 'Number of the OB that caused the error (OB_ANY)');
          I('Csg_Prio', 'UInt', 'Priority of the OB that caused the error');
          I('Width', 'USInt', 'Width of the access: 0 bit, 1 byte, 2 word, 3 double word');
        end;
    end;
    Exit;
  end;
  // STEP 7 classic: 20 bytes of Temp
  P := Format('OB%d_', [Number]);
  case E of
    oeProgramCycle:
      begin
        T('EV_CLASS', 'Byte', 'Bits 0-3 = 1 (coming event), bits 4-7 = 1 (event class 1)');
        T('SCAN_1', 'Byte', '1 (cold restart scan 1 of OB 1), 3 (scan 2-n of OB 1)');
        T('PRIORITY', 'Byte', 'Priority of OB execution');
        T('OB_NUMBR', 'Byte', '1 (Organization block 1, OB1)');
        T('RESERVED_1', 'Byte', 'Reserved for system');
        T('RESERVED_2', 'Byte', 'Reserved for system');
        T('PREV_CYCLE', 'Int', 'Cycle time of previous OB1 scan (milliseconds)');
        T('MIN_CYCLE', 'Int', 'Minimum cycle time of OB1 (milliseconds)');
        T('MAX_CYCLE', 'Int', 'Maximum cycle time of OB1 (milliseconds)');
      end;
    oeStartup, oeHotRestart, oeColdRestart:
      begin
        Head('STRTUP', '');
        T('STOP', 'Word', 'Event that caused the CPU to STOP');
        T('STRT_INFO', 'DWord', 'Information on the current startup');
      end;
    oeCyclic:
      begin
        Head('', '');
        T('PHASE_OFFSET', 'Word', 'Phase offset (msec)');
        T('RESERVED_3', 'Int', 'Reserved for system');
        T('EXC_FREQ', 'Int', 'Frequency of execution (msec)');
      end;
    oeTimeOfDay:
      begin
        Head('', '');
        T('PERIOD_EXE', 'Word', 'Period of execution');
        T('RESERVED_3', 'Int', 'Reserved for system');
        T('RESERVED_4', 'Int', 'Reserved for system');
      end;
    oeTimeDelay:
      begin
        Head('', '');
        T('SIGN', 'Word', 'Identifier input (SIGN) of SRT_DINT');
        T('DTIME', 'Time', 'Elapsed delay time (DTIME of SRT_DINT)');
      end;
    oeHardware:
      begin
        Head('', 'IO_FLAG');
        T('MDL_ADDR', 'Word', 'Base address of the module initiating the interrupt');
        T('POINT_ADDR', 'DWord', 'Interrupt status of the module (the bit of the channel)');
      end;
    oeTimeError:
      begin
        Head('FLT_ID', '');
        T('ERROR_INFO', 'Word', 'Error information on the event');
        T('ERR_EV_CLASS', 'Byte', 'Class of the event causing the error');
        T('ERR_EV_NUM', 'Byte', 'Number of the event causing the error');
        T('OB_PRIORITY', 'Byte', 'Priority of the OB causing the error');
        T('OB_NUM', 'Byte', 'Number of the OB causing the error');
      end;
    oeDiagnostic:
      begin
        Head('FLT_ID', 'IO_FLAG');
        T('MDL_ADDR', 'Word', 'Base address of the module with the fault');
        T('MDL_STATUS', 'DWord', 'Module defect, internal / external fault, channel fault ..');
      end;
    oePullPlug:
      begin
        Head('FLT_ID', 'MDL_ID');
        T('MDL_ADDR', 'Word', 'Base address of the module');
        T('RACK_NUM', 'Word', 'Rack / slot of the module');
        T('MDL_TYPE', 'Word', 'Module type');
      end;
    oeRackFailure:
      begin
        Head('FLT_ID', '');
        T('MDL_ADDR', 'Word', 'Base address of the station');
        T('RACKS_FLTD', 'DWord', 'The racks / stations that failed');
      end;
    oeProgError:
      begin
        T('EV_CLASS', 'Byte', '16#25, event class 2, entering event state, internal fault event');
        T('SW_FLT', 'Byte', 'Software programming fault');
        T('PRIORITY', 'Byte', 'Priority of the OB where the fault occurred');
        T('OB_NUMBR', 'Byte', '121 (Organization block 121, OB121)');
        T('BLK_TYPE', 'Byte', 'Type of the block where the fault occurred');
        T('RESERVED_1', 'Byte', 'Reserved for system');
        T('FLT_REG', 'Word', 'Specific register that caused the fault');
        T('BLK_NUM', 'Word', 'Number of the block where the fault occurred');
        T('PRG_ADDR', 'Word', 'Address in the block where the fault occurred');
      end;
    oeIoAccess:
      begin
        T('EV_CLASS', 'Byte', '16#29, event class 2, entering event state, internal fault event');
        T('SW_FLT', 'Byte', 'Software error code');
        T('PRIORITY', 'Byte', 'Priority of the OB where the fault occurred');
        T('OB_NUMBR', 'Byte', '122 (Organization block 122, OB122)');
        T('BLK_TYPE', 'Byte', 'Type of the block where the fault occurred');
        T('MEM_AREA', 'Byte', 'Memory area and type of access');
        T('MEM_ADDR', 'Word', 'Memory address where the fault occurred');
        T('BLK_NUM', 'Word', 'Number of the block where the fault occurred');
        T('PRG_ADDR', 'Word', 'Address in the block where the fault occurred');
      end;
  else
    begin
      Head('', '');
      T('INFO_1', 'Word', 'Event information');
      T('INFO_2', 'Word', 'Event information');
      T('INFO_3', 'Word', 'Event information');
    end;
  end;
  T('DATE_TIME', 'Date_And_Time', 'Date and time the OB was started');
end;

function ParseTodStart(const S: string; out DT: TDateTime): Boolean;
var
  Y, Mo, Dd, H, Mi, Se: Integer;
  T: string;
  D0, T0: TDateTime;
begin
  Result := False;
  DT := 0;
  T := Trim(S);
  if Length(T) < 16 then Exit;
  if not (TryStrToInt(Copy(T, 1, 4), Y) and (T[5] = '-') and TryStrToInt(Copy(T, 6, 2), Mo) and (T[8] = '-') and
    TryStrToInt(Copy(T, 9, 2), Dd) and (T[11] in [' ', 'T', '-']) and TryStrToInt(Copy(T, 12, 2), H) and
    (T[14] = ':') and TryStrToInt(Copy(T, 15, 2), Mi)) then Exit;
  Se := 0;
  if (Length(T) >= 19) and ((T[17] <> ':') or not TryStrToInt(Copy(T, 18, 2), Se)) then Exit;
  if not TryEncodeDate(Y, Mo, Dd, D0) or not TryEncodeTime(H, Mi, Se, 0, T0) then Exit;
  DT := D0 + T0;
  Result := True;
end;

function FormatTodStart(DT: TDateTime): string;
begin
  Result := FormatDateTime('yyyy"-"mm"-"dd hh":"nn":"ss', DT);
end;

function ObStartKey(const VarName: string): string;
var
  K: Integer;
begin
  Result := UpperCase(VarName);
  // OBnn_xxx -> xxx
  if (Length(Result) > 3) and (Copy(Result, 1, 2) = 'OB') and (Result[3] in ['0'..'9']) then
  begin
    K := 3;
    while (K <= Length(Result)) and (Result[K] in ['0'..'9']) do Inc(K);
    if (K <= Length(Result)) and (Result[K] = '_') then Result := Copy(Result, K + 1, MaxInt);
  end;
end;

end.
