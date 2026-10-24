unit uFbd;

{ FBD (function block diagram) and CFC (continuous function chart): the boxes they have, a new box, the SCL
  a network of them is compiled as, the execution order of a CFC chart, a LAD network converted to FBD and
  the lists of the elements panel.

  A network holds boxes (TFbdNode) with pins. An input pin is an operand / a constant or a wire from an
  output pin of another box; an output pin may also write an operand. The compiler turns the boxes into SCL
  (one statement or a few per box, the wired outputs in temps fbN_Pin), so the runtime, the monitor (the value
  written on the first line of a box) and the messages are the ones of SCL.
  FBD: the boxes are trees drawn from the right (a box whose output feeds no other box is a root, the roots
  run from the top). CFC: the boxes are placed freely on a chart and run in the order of the data flow (a box
  after the boxes it reads), their Order deciding between boxes that do not depend on each other. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Math, StrUtils, uPlcTypes, uPlcProject, uSclElems;

type
  { a pin of a box: its name, its type ('B' Bool, 'N' the type of the box, 'D' its second type, 'T' Time,
    'I' Int, 'R' Real, 'S' String, 'X' given by the block of a CALL), optional }
  TFbdPinDef = record
    Name: string;
    Ty: Char;
    Opt: Boolean;
  end;
  TFbdPinDefs = array of TFbdPinDef;
  { what is above the box: nothing, the instance of an FB (timers, counters, edges), an operand (=, S, R, the
    edge memory of P / N, the variable of INC / DEC), the block (CALL) }
  TFbdInst = (fiNone, fiInstance, fiOperand, fiBlock);
  TFbdBoxDef = record
    Id, Title, Cat, Descr: string;
    Ins, Outs: TFbdPinDefs;
    Inst: TFbdInst;
    InstName: string;     // what the field above the box is called
    Ext: Boolean;         // inputs can be added (AND, OR, ADD, MUX ..)
    HasType, HasType2, HasCmp: Boolean;
    DefType, DefType2: TDataType;
    Types: string;        // the data types it may have (the menu of the box): 'num', 'int', 'bits', 'any'
  end;
  TFbdBoxDefs = array of TFbdBoxDef;

function FbdBoxes: TFbdBoxDefs;
function FbdBoxIndex(const Id: string): Integer;   // -1: unknown
function FbdBoxDefOf(const Id: string): TFbdBoxDef;
{ the types a box can be given (its menu) }
function FbdTypeChoices(const D: TFbdBoxDef): TStringArray;

{ a new box of the kind Id (its pins, its types) with the next id of the network; CALL: the pins of the
  block (P, Blk: the FC, or the instance DB of an FB) }
function NewFbdNode(N: TNetwork; const Id: string; P: TPlcProject; const Blk: string): TFbdNode;
{ the pins of a CALL box from its block: the inputs (Input, InOut) and the outputs (Output, Return value) }
procedure FbdCallPins(P: TPlcProject; const Blk: string; var Nd: TFbdNode);
{ an input added to / removed from a box that has more of them (IN3, IN4 ..) }
function FbdAddInput(var Nd: TFbdNode): Boolean;
function FbdRemoveInput(var Nd: TFbdNode; Pin: Integer): Boolean;
{ the type of a pin of a box (a data type name for a temp, '' unknown) }
function FbdPinType(P: TPlcProject; const Nd: TFbdNode; IsOut: Boolean; Pin: Integer): string;

{ the boxes in the order they run: FBD from the roots, CFC by the data flow (and Order) }
function FbdRunOrder(N: TNetwork): TIntArray;
{ CFC: Order 1 .. n as they run now }
procedure CfcRenumber(N: TNetwork);
{ CFC: the boxes placed in columns by the data flow (a converted network, a help picture) }
procedure CfcAutoPlace(N: TNetwork);
{ the boxes whose output feeds no other box (FBD: the roots, from the top) }
function FbdRoots(N: TNetwork): TIntArray;
{ a box and every box that feeds only it (FBD: Del) out of the network; the wires to them are cut }
procedure FbdDeleteNode(N: TNetwork; Id: Integer; WithInputs: Boolean);

{ the SCL of an FBD / CFC network: the lines; LineNode: the box (its Id) of every line (0: none); the
  problems found (each 'Id|text') }
procedure FbdToScl(N: TNetwork; P: TPlcProject; Lines: TStrings; out LineNode: TIntArray; Errs: TStrings;
  Blk: TBlock = nil; NetNo: Integer = 0);

{ the boxes of a network written by a tool (JSON): unknown boxes refused, every box with the pins of its kind (the
  pins given keep their operand / wire; more inputs added as named), CFC places by the data flow when none are
  given; '' or the problem }
function FbdNormalize(N: TNetwork; P: TPlcProject): string;

{ a LAD network as FBD boxes (nil: it cannot be; Err says why) }
function LadToFbd(L: TNetwork; P: TPlcProject; out Err: string): TNetwork;

{ the elements panel: the boxes ('#box:id' in Snip) and the project's operands / FCs }
function FbdElems(P: TPlcProject; Cur: TBlock; Cfc: Boolean): TSclElems;
const
  FbdBoxSnip = '#box:';

implementation

var
  Defs: TFbdBoxDefs = nil;

function PinDefs(const S: string): TFbdPinDefs;
var
  Parts: TStringArray;
  K: Integer;
  T: string;
begin
  // 'IN1:B,IN2:B,EN:B?' ('?' optional)
  Result := nil;
  if S = '' then Exit;
  Parts := S.Split(',');
  SetLength(Result, Length(Parts));
  for K := 0 to High(Parts) do
  begin
    T := Trim(Parts[K]);
    Result[K].Opt := (T <> '') and (T[Length(T)] = '?');
    if Result[K].Opt then Delete(T, Length(T), 1);
    Result[K].Name := Copy(T, 1, Pos(':', T) - 1);
    Result[K].Ty := Copy(T, Pos(':', T) + 1, 1)[1];
  end;
end;

procedure Def(const Id, Title, Cat: string; Inst: TFbdInst; const InstName, Ins, Outs: string; Ext: Boolean;
  const Types: string; DT, DT2: TDataType; const Descr: string);
var
  N: Integer;
begin
  N := Length(Defs);
  SetLength(Defs, N + 1);
  Defs[N].Id := Id;
  Defs[N].Title := Title;
  Defs[N].Cat := Cat;
  Defs[N].Inst := Inst;
  Defs[N].InstName := InstName;
  Defs[N].Ins := PinDefs(Ins);
  Defs[N].Outs := PinDefs(Outs);
  Defs[N].Ext := Ext;
  Defs[N].Types := Types;
  Defs[N].HasType := Types <> '';
  Defs[N].HasType2 := DT2 <> dtNone;
  Defs[N].HasCmp := Id = 'cmp';
  Defs[N].DefType := DT;
  Defs[N].DefType2 := DT2;
  Defs[N].Descr := Descr;
end;

procedure Build;
const
  C_BIT = 'Bit logic';
  C_EDGE = 'Edges / flip-flops';
  C_TIMER = 'Timers';
  C_CNT = 'Counters';
  C_CMP = 'Comparison';
  C_MATH = 'Math functions';
  C_MOVE = 'Move / conversion';
  C_SEL = 'Selection';
  C_WORD = 'Shift / word logic';
  C_STR = 'String';
  C_PRG = 'Program control';
  Fns: array[0..11] of string = ('abs', 'sqr', 'sqrt', 'exp', 'ln', 'sin', 'cos', 'tan', 'asin', 'acos', 'atan', 'frac');
var
  K: Integer;
  Dt: TDataType;
begin
  Def('and', 'AND', C_BIT, fiNone, '', 'IN1:B,IN2:B', 'Q:B', True, '', dtBool, dtNone,
    'Q is TRUE when every input is TRUE. More inputs: + in the box; a small circle negates an input.');
  Def('or', 'OR', C_BIT, fiNone, '', 'IN1:B,IN2:B', 'Q:B', True, '', dtBool, dtNone, 'Q is TRUE when an input is TRUE.');
  Def('xor', 'XOR', C_BIT, fiNone, '', 'IN1:B,IN2:B', 'Q:B', True, '', dtBool, dtNone,
    'Q is TRUE when an odd number of inputs is TRUE (two inputs: they differ).');
  Def('assign', '=', C_BIT, fiOperand, 'operand', 'IN:B', '', False, '', dtBool, dtNone,
    'Assignment: the operand above the box := IN (every cycle).');
  Def('set', 'S', C_BIT, fiOperand, 'operand', 'IN:B', '', False, '', dtBool, dtNone,
    'Set: the operand := TRUE while IN is TRUE; it stays TRUE.');
  Def('reset', 'R', C_BIT, fiOperand, 'operand', 'IN:B', '', False, '', dtBool, dtNone,
    'Reset: the operand := FALSE while IN is TRUE (also a timer / counter instance).');
  Def('p', 'P', C_EDGE, fiOperand, 'edge memory bit', 'IN:B', 'Q:B', False, '', dtBool, dtNone,
    'Rising edge of IN: Q is TRUE for one cycle; the memory bit above keeps the last value.');
  Def('n', 'N', C_EDGE, fiOperand, 'edge memory bit', 'IN:B', 'Q:B', False, '', dtBool, dtNone,
    'Falling edge of IN: Q is TRUE for one cycle.');
  Def('rtrig', 'R_TRIG', C_EDGE, fiInstance, 'instance (R_TRIG)', 'CLK:B', 'Q:B', False, '', dtBool, dtNone,
    'Rising edge box: Q is TRUE for one cycle when CLK goes TRUE. Its instance: an R_TRIG variable.');
  Def('ftrig', 'F_TRIG', C_EDGE, fiInstance, 'instance (F_TRIG)', 'CLK:B', 'Q:B', False, '', dtBool, dtNone,
    'Falling edge box: Q is TRUE for one cycle when CLK goes FALSE.');
  Def('sr', 'SR', C_EDGE, fiInstance, 'instance (SR)', 'S1:B,R:B', 'Q1:B', False, '', dtBool, dtNone,
    'Flip-flop, set dominant: S1 sets Q1, R resets it, S1 wins.');
  Def('rs', 'RS', C_EDGE, fiInstance, 'instance (RS)', 'S:B,R1:B', 'Q1:B', False, '', dtBool, dtNone,
    'Flip-flop, reset dominant: S sets Q1, R1 resets it and wins.');
  Def('ton', 'TON', C_TIMER, fiInstance, 'instance (TON_TIME / IEC_TIMER)', 'IN:B,PT:T', 'Q:B,ET:T', False, '', dtBool, dtNone,
    'On delay: Q after IN was TRUE for PT.');
  Def('tof', 'TOF', C_TIMER, fiInstance, 'instance (TOF_TIME / IEC_TIMER)', 'IN:B,PT:T', 'Q:B,ET:T', False, '', dtBool, dtNone,
    'Off delay: Q stays TRUE for PT after IN went FALSE.');
  Def('tp', 'TP', C_TIMER, fiInstance, 'instance (TP_TIME / IEC_TIMER)', 'IN:B,PT:T', 'Q:B,ET:T', False, '', dtBool, dtNone,
    'Pulse: Q is TRUE for PT from a rising edge of IN.');
  Def('tonr', 'TONR', C_TIMER, fiInstance, 'instance (TONR_TIME / IEC_TIMER)', 'IN:B,R:B,PT:T', 'Q:B,ET:T', False, '', dtBool,
    dtNone, 'Retentive on delay: the time adds up while IN is TRUE, R resets it (S7-1200/1500).');
  Def('ctu', 'CTU', C_CNT, fiInstance, 'instance (CTU_INT / IEC_COUNTER)', 'CU:B,R:B,PV:I', 'Q:B,CV:I', False, '', dtBool, dtNone,
    'Count up on the rising edges of CU; R resets; Q at CV >= PV.');
  Def('ctd', 'CTD', C_CNT, fiInstance, 'instance (CTD_INT / IEC_COUNTER)', 'CD:B,LD:B,PV:I', 'Q:B,CV:I', False, '', dtBool, dtNone,
    'Count down on CD; LD loads PV; Q at CV <= 0.');
  Def('ctud', 'CTUD', C_CNT, fiInstance, 'instance (CTUD_INT / IEC_COUNTER)', 'CU:B,CD:B,R:B,LD:B,PV:I', 'QU:B,QD:B,CV:I',
    False, '', dtBool, dtNone, 'Count up (CU) and down (CD); R, LD; QU at CV >= PV, QD at CV <= 0.');
  Def('cmp', 'CMP', C_CMP, fiNone, '', 'IN1:N,IN2:N', 'Q:B', False, 'any', dtInt, dtNone,
    'Q is TRUE when IN1 compared with IN2 holds (==, <>, >, <, >=, <=: in the box).');
  Def('inrange', 'IN_RANGE', C_CMP, fiNone, '', 'MIN:N,VAL:N,MAX:N', 'Q:B', False, 'num', dtInt, dtNone,
    'Q is TRUE when MIN <= VAL <= MAX.');
  Def('outrange', 'OUT_RANGE', C_CMP, fiNone, '', 'MIN:N,VAL:N,MAX:N', 'Q:B', False, 'num', dtInt, dtNone,
    'Q is TRUE when VAL < MIN or VAL > MAX.');
  Def('add', 'ADD', C_MATH, fiNone, '', 'EN:B?,IN1:N,IN2:N', 'OUT:N', True, 'num', dtInt, dtNone, 'OUT := IN1 + IN2 (+ IN3 ..).');
  Def('sub', 'SUB', C_MATH, fiNone, '', 'EN:B?,IN1:N,IN2:N', 'OUT:N', False, 'num', dtInt, dtNone, 'OUT := IN1 - IN2.');
  Def('mul', 'MUL', C_MATH, fiNone, '', 'EN:B?,IN1:N,IN2:N', 'OUT:N', True, 'num', dtInt, dtNone, 'OUT := IN1 * IN2 (* IN3 ..).');
  Def('div', 'DIV', C_MATH, fiNone, '', 'EN:B?,IN1:N,IN2:N', 'OUT:N', False, 'num', dtInt, dtNone,
    'OUT := IN1 / IN2 (integers: the decimals are cut).');
  Def('mod', 'MOD', C_MATH, fiNone, '', 'EN:B?,IN1:N,IN2:N', 'OUT:N', False, 'int', dtInt, dtNone, 'OUT := IN1 MOD IN2.');
  Def('expt', 'EXPT', C_MATH, fiNone, '', 'EN:B?,IN1:N,IN2:N', 'OUT:N', False, 'real', dtReal, dtNone, 'OUT := IN1 ** IN2.');
  Def('neg', 'NEG', C_MATH, fiNone, '', 'EN:B?,IN:N', 'OUT:N', False, 'num', dtInt, dtNone, 'OUT := -IN.');
  for K := 0 to High(Fns) do
  begin
    if Fns[K] = 'abs' then Dt := dtInt else Dt := dtReal;
    Def(Fns[K], UpperCase(Fns[K]), C_MATH, fiNone, '', 'EN:B?,IN:N', 'OUT:N', False, IfThen(Fns[K] = 'abs', 'num', 'real'),
      Dt, dtNone, 'OUT := ' + UpperCase(Fns[K]) + '(IN).');
  end;
  Def('inc', 'INC', C_MATH, fiOperand, 'IN_OUT', 'EN:B?', '', False, 'int', dtInt, dtNone,
    'The operand above := itself + 1 (while EN is TRUE; every cycle: put a P edge before EN).');
  Def('dec', 'DEC', C_MATH, fiOperand, 'IN_OUT', 'EN:B?', '', False, 'int', dtInt, dtNone, 'The operand above := itself - 1.');
  Def('move', 'MOVE', C_MOVE, fiNone, '', 'EN:B?,IN:N', 'OUT1:N', False, 'any', dtInt, dtNone, 'OUT1 := IN.');
  Def('conv', 'CONV', C_MOVE, fiNone, '', 'EN:B?,IN:N', 'OUT:D', False, 'any', dtInt, dtReal,
    'OUT := IN converted (the IN and OUT types in the box).');
  Def('round', 'ROUND', C_MOVE, fiNone, '', 'EN:B?,IN:N', 'OUT:D', False, 'real', dtReal, dtDInt,
    'A Real to an integer, to the nearest (a half to even).');
  Def('trunc', 'TRUNC', C_MOVE, fiNone, '', 'EN:B?,IN:N', 'OUT:D', False, 'real', dtReal, dtDInt, 'A Real to an integer, cut.');
  Def('ceil', 'CEIL', C_MOVE, fiNone, '', 'EN:B?,IN:N', 'OUT:D', False, 'real', dtReal, dtDInt, 'A Real to an integer, up.');
  Def('floor', 'FLOOR', C_MOVE, fiNone, '', 'EN:B?,IN:N', 'OUT:D', False, 'real', dtReal, dtDInt, 'A Real to an integer, down.');
  Def('normx', 'NORM_X', C_MOVE, fiNone, '', 'EN:B?,MIN:N,VALUE:N,MAX:N', 'OUT:R', False, 'num', dtInt, dtNone,
    'OUT := (VALUE - MIN) / (MAX - MIN): 0.0 .. 1.0.');
  Def('scalex', 'SCALE_X', C_MOVE, fiNone, '', 'EN:B?,MIN:N,VALUE:R,MAX:N', 'OUT:N', False, 'num', dtInt, dtNone,
    'OUT := VALUE * (MAX - MIN) + MIN.');
  Def('sel', 'SEL', C_SEL, fiNone, '', 'EN:B?,G:B,IN0:N,IN1:N', 'OUT:N', False, 'any', dtInt, dtNone, 'OUT := IN1 when G, else IN0.');
  Def('mux', 'MUX', C_SEL, fiNone, '', 'EN:B?,K:I,IN0:N,IN1:N', 'OUT:N', True, 'any', dtInt, dtNone,
    'OUT := the input number K (IN0, IN1, ..).');
  Def('limit', 'LIMIT', C_SEL, fiNone, '', 'EN:B?,MN:N,IN:N,MX:N', 'OUT:N', False, 'num', dtInt, dtNone,
    'OUT := IN limited to MN .. MX.');
  Def('min', 'MIN', C_SEL, fiNone, '', 'EN:B?,IN1:N,IN2:N', 'OUT:N', True, 'num', dtInt, dtNone, 'OUT := the smallest input.');
  Def('max', 'MAX', C_SEL, fiNone, '', 'EN:B?,IN1:N,IN2:N', 'OUT:N', True, 'num', dtInt, dtNone, 'OUT := the largest input.');
  Def('andw', 'AND', C_WORD, fiNone, '', 'EN:B?,IN1:N,IN2:N', 'OUT:N', True, 'bits', dtWord, dtNone, 'OUT := IN1 AND IN2, bit by bit.');
  Def('orw', 'OR', C_WORD, fiNone, '', 'EN:B?,IN1:N,IN2:N', 'OUT:N', True, 'bits', dtWord, dtNone, 'OUT := IN1 OR IN2, bit by bit.');
  Def('xorw', 'XOR', C_WORD, fiNone, '', 'EN:B?,IN1:N,IN2:N', 'OUT:N', True, 'bits', dtWord, dtNone, 'OUT := IN1 XOR IN2, bit by bit.');
  Def('invw', 'INV', C_WORD, fiNone, '', 'EN:B?,IN:N', 'OUT:N', False, 'bits', dtWord, dtNone, 'OUT := every bit of IN inverted.');
  Def('shl', 'SHL', C_WORD, fiNone, '', 'EN:B?,IN:N,N:I', 'OUT:N', False, 'bits', dtWord, dtNone, 'OUT := IN shifted left by N bits.');
  Def('shr', 'SHR', C_WORD, fiNone, '', 'EN:B?,IN:N,N:I', 'OUT:N', False, 'bits', dtWord, dtNone, 'OUT := IN shifted right by N bits.');
  Def('rol', 'ROL', C_WORD, fiNone, '', 'EN:B?,IN:N,N:I', 'OUT:N', False, 'bits', dtWord, dtNone, 'OUT := IN rotated left by N bits.');
  Def('ror', 'ROR', C_WORD, fiNone, '', 'EN:B?,IN:N,N:I', 'OUT:N', False, 'bits', dtWord, dtNone, 'OUT := IN rotated right by N bits.');
  Def('concat', 'CONCAT', C_STR, fiNone, '', 'EN:B?,IN1:S,IN2:S', 'OUT:S', False, '', dtString, dtNone, 'OUT := IN1 joined with IN2.');
  Def('len', 'LEN', C_STR, fiNone, '', 'EN:B?,IN:S', 'OUT:I', False, '', dtString, dtNone, 'OUT := the length of IN.');
  Def('left', 'LEFT', C_STR, fiNone, '', 'EN:B?,IN:S,L:I', 'OUT:S', False, '', dtString, dtNone, 'OUT := the first L characters.');
  Def('right', 'RIGHT', C_STR, fiNone, '', 'EN:B?,IN:S,L:I', 'OUT:S', False, '', dtString, dtNone, 'OUT := the last L characters.');
  Def('mid', 'MID', C_STR, fiNone, '', 'EN:B?,IN:S,L:I,P:I', 'OUT:S', False, '', dtString, dtNone,
    'OUT := L characters from the position P.');
  Def('find', 'FIND', C_STR, fiNone, '', 'EN:B?,IN1:S,IN2:S', 'OUT:I', False, '', dtString, dtNone,
    'OUT := the position of IN2 in IN1 (0: not there).');
  Def('smove', 'S_MOVE', C_STR, fiNone, '', 'EN:B?,IN:S', 'OUT:S', False, '', dtString, dtNone, 'OUT := IN (a string).');
  Def('call', 'CALL', C_PRG, fiBlock, 'block (FC) / instance DB (FB)', 'EN:B?', '', False, '', dtBool, dtNone,
    'Calls an FC or an FB (its instance DB above the box); the pins are its parameters.');
end;

function FbdBoxes: TFbdBoxDefs;
begin
  if Defs = nil then Build;
  Result := Defs;
end;

function FbdBoxIndex(const Id: string): Integer;
var
  K: Integer;
begin
  FbdBoxes;
  for K := 0 to High(Defs) do
    if Defs[K].Id = Id then Exit(K);
  Result := -1;
end;

function FbdBoxDefOf(const Id: string): TFbdBoxDef;
var
  K: Integer;
begin
  K := FbdBoxIndex(Id);
  if K >= 0 then Result := Defs[K]
  else
  begin
    Result := Default(TFbdBoxDef);
    Result.Id := Id;
    Result.Title := UpperCase(Id);
  end;
end;

function FbdTypeChoices(const D: TFbdBoxDef): TStringArray;
const
  Num: array[0..10] of string = ('Int', 'DInt', 'Real', 'LReal', 'SInt', 'USInt', 'UInt', 'UDInt', 'LInt', 'Time', 'LTime');
  Ints: array[0..7] of string = ('Int', 'DInt', 'SInt', 'USInt', 'UInt', 'UDInt', 'LInt', 'ULInt');
  BitS: array[0..3] of string = ('Byte', 'Word', 'DWord', 'LWord');
  Rls: array[0..1] of string = ('Real', 'LReal');
  Anys: array[0..16] of string = ('Bool', 'Int', 'DInt', 'Real', 'LReal', 'Byte', 'Word', 'DWord', 'SInt', 'USInt', 'UInt',
    'UDInt', 'LInt', 'Time', 'Char', 'String', 'Date');
var
  K: Integer;
begin
  Result := nil;
  case D.Types of
    'num': begin SetLength(Result, Length(Num)); for K := 0 to High(Num) do Result[K] := Num[K]; end;
    'int': begin SetLength(Result, Length(Ints)); for K := 0 to High(Ints) do Result[K] := Ints[K]; end;
    'bits': begin SetLength(Result, Length(BitS)); for K := 0 to High(BitS) do Result[K] := BitS[K]; end;
    'real': begin SetLength(Result, Length(Rls)); for K := 0 to High(Rls) do Result[K] := Rls[K]; end;
    'any': begin SetLength(Result, Length(Anys)); for K := 0 to High(Anys) do Result[K] := Anys[K]; end;
  end;
end;

{ ---------- a box ---------- }

function OldOfIdx(const A: TFbdPins; const Name: string): Integer;
var
  J: Integer;
begin
  for J := 0 to High(A) do
    if SameText(A[J].Name, Name) then Exit(J);
  Result := -1;
end;

procedure FbdCallPins(P: TPlcProject; const Blk: string; var Nd: TFbdNode);
var
  B: TBlock;
  D: TDataBlock;
  U: string;
  K, Nr, NI, NO: Integer;
  Old: TFbdPins;
begin
  B := nil;
  if P <> nil then
  begin
    U := Trim(StringReplace(Blk, '"', '', [rfReplaceAll]));
    D := P.FindDBByName(U);
    if (D = nil) and SameText(Copy(U, 1, 2), 'DB') and TryStrToInt(Copy(U, 3, MaxInt), Nr) then D := P.FindDB(Nr);
    if D <> nil then B := P.InstanceFB(D)
    else
    begin
      for K := 0 to P.BlockCount - 1 do
        if (P.Block(K).Kind = bkFC) and SameText(P.Block(K).Name, U) then B := P.Block(K);
      if (B = nil) and SameText(Copy(U, 1, 2), 'FC') and TryStrToInt(Copy(U, 3, MaxInt), Nr) then B := P.FindBlock(bkFC, Nr);
    end;
  end;
  if B = nil then Exit;
  // the pins of the block; a pin that was there keeps its operand / wire
  Old := Copy(Nd.Ins);
  SetLength(Nd.Ins, 1);
  NI := 1;
  Nd.Ins[0].Name := 'EN';
  K := OldOfIdx(Old, 'EN');
  if K >= 0 then Nd.Ins[0] := Old[K] else begin Nd.Ins[0].Opnd := ''; Nd.Ins[0].Src := 0; Nd.Ins[0].Neg := False; end;
  for K := 0 to High(B.Iface.Vars) do
    if B.Iface.Vars[K].Section in [vsInput, vsInOut] then
    begin
      SetLength(Nd.Ins, NI + 1);
      Nd.Ins[NI] := Default(TFbdPin);
      Nd.Ins[NI].Name := B.Iface.Vars[K].Name;
      Nr := OldOfIdx(Old, B.Iface.Vars[K].Name);
      if Nr >= 0 then Nd.Ins[NI] := Old[Nr];
      Inc(NI);
    end;
  Old := Copy(Nd.Outs);
  NO := 0;
  SetLength(Nd.Outs, 0);
  for K := 0 to High(B.Iface.Vars) do
    if B.Iface.Vars[K].Section in [vsOutput, vsReturn] then
    begin
      SetLength(Nd.Outs, NO + 1);
      Nd.Outs[NO] := Default(TFbdPin);
      if B.Iface.Vars[K].Section = vsReturn then Nd.Outs[NO].Name := 'RET_VAL' else Nd.Outs[NO].Name := B.Iface.Vars[K].Name;
      Nr := OldOfIdx(Old, Nd.Outs[NO].Name);
      if Nr >= 0 then Nd.Outs[NO] := Old[Nr];
      Inc(NO);
    end;
end;

function NewFbdNode(N: TNetwork; const Id: string; P: TPlcProject; const Blk: string): TFbdNode;
var
  D: TFbdBoxDef;
  K: Integer;
begin
  D := FbdBoxDefOf(Id);
  Result := Default(TFbdNode);
  if N <> nil then Result.Id := N.NewNodeId else Result.Id := 1;
  Result.Box := Id;
  Result.DType := D.DefType;
  Result.DType2 := D.DefType2;
  Result.Cmp := coEQ;
  SetLength(Result.Ins, Length(D.Ins));
  for K := 0 to High(D.Ins) do Result.Ins[K].Name := D.Ins[K].Name;
  SetLength(Result.Outs, Length(D.Outs));
  for K := 0 to High(D.Outs) do Result.Outs[K].Name := D.Outs[K].Name;
  case Id of
    'ton', 'tof', 'tp', 'tonr': Result.Ins[High(Result.Ins)].Opnd := 'T#2S';
    'ctu', 'ctd', 'ctud': Result.Ins[High(Result.Ins)].Opnd := '10';
  end;
  if Id = 'call' then
  begin
    Result.Inst := Blk;
    FbdCallPins(P, Blk, Result);
  end;
  if N <> nil then
  begin
    Result.Order := Length(N.Nodes) + 1;
    Result.X := 2;
    Result.Y := 2;
  end;
end;

function FbdAddInput(var Nd: TFbdNode): Boolean;
var
  D: TFbdBoxDef;
  K, Nr, Last: Integer;
  Pfx: string;
begin
  Result := False;
  D := FbdBoxDefOf(Nd.Box);
  if not D.Ext or (Length(Nd.Ins) >= 32) then Exit;
  // the last numbered input: its name with the next number
  Last := High(Nd.Ins);
  Pfx := Nd.Ins[Last].Name;
  K := Length(Pfx);
  while (K > 0) and (Pfx[K] in ['0'..'9']) do Dec(K);
  Nr := StrToIntDef(Copy(Pfx, K + 1, MaxInt), 0);
  SetLength(Nd.Ins, Last + 2);
  Nd.Ins[Last + 1] := Default(TFbdPin);
  Nd.Ins[Last + 1].Name := Copy(Pfx, 1, K) + IntToStr(Nr + 1);
  Result := True;
end;

function FbdRemoveInput(var Nd: TFbdNode; Pin: Integer): Boolean;
var
  D: TFbdBoxDef;
  K, Base: Integer;
begin
  Result := False;
  D := FbdBoxDefOf(Nd.Box);
  // only the inputs added (more than the box has at least)
  if not D.Ext or (Length(Nd.Ins) <= Length(D.Ins)) or (Pin < Length(D.Ins) - 1) or (Pin > High(Nd.Ins)) then Exit;
  Base := Length(D.Ins) - 2;
  for K := Pin to High(Nd.Ins) - 1 do
  begin
    Nd.Ins[K].Opnd := Nd.Ins[K + 1].Opnd;
    Nd.Ins[K].Src := Nd.Ins[K + 1].Src;
    Nd.Ins[K].SrcPin := Nd.Ins[K + 1].SrcPin;
    Nd.Ins[K].Neg := Nd.Ins[K + 1].Neg;
  end;
  SetLength(Nd.Ins, Length(Nd.Ins) - 1);
  if Base = 0 then ;
  Result := True;
end;

function TyName(Ty: Char; const Nd: TFbdNode): string;
begin
  case Ty of
    'B': Result := 'Bool';
    'N': Result := DataTypeNames[Nd.DType];
    'D': Result := DataTypeNames[Nd.DType2];
    'T': Result := 'Time';
    'I': Result := 'Int';
    'R': Result := 'Real';
    'S': Result := 'String';
  else
    Result := '';
  end;
  // the counters of another type: CTU_DINT .. (the PV / CV type)
  if (Ty = 'I') and (Nd.Box = 'mux') then Result := 'Int';
end;

function FbdPinType(P: TPlcProject; const Nd: TFbdNode; IsOut: Boolean; Pin: Integer): string;
var
  D: TFbdBoxDef;
  B: TBlock;
  K: Integer;
  U: string;
  Db: TDataBlock;
  Nr: Integer;
begin
  Result := '';
  D := FbdBoxDefOf(Nd.Box);
  if Nd.Box = 'call' then
  begin
    if P = nil then Exit;
    if IsOut and (Pin <= High(Nd.Outs)) and (Nd.Outs[Pin].Name = 'RET_VAL') then
    begin
      B := nil;
      U := Trim(StringReplace(Nd.Inst, '"', '', [rfReplaceAll]));
      for K := 0 to P.BlockCount - 1 do
        if (P.Block(K).Kind = bkFC) and SameText(P.Block(K).Name, U) then B := P.Block(K);
      if (B = nil) and SameText(Copy(U, 1, 2), 'FC') and TryStrToInt(Copy(U, 3, MaxInt), Nr) then B := P.FindBlock(bkFC, Nr);
      if B <> nil then
        for K := 0 to High(B.Iface.Vars) do
          if B.Iface.Vars[K].Section = vsReturn then Exit(B.Iface.Vars[K].TypeText);
      Exit;
    end;
    U := Trim(StringReplace(Nd.Inst, '"', '', [rfReplaceAll]));
    B := nil;
    Db := P.FindDBByName(U);
    if Db <> nil then B := P.InstanceFB(Db)
    else
    begin
      for K := 0 to P.BlockCount - 1 do
        if (P.Block(K).Kind = bkFC) and SameText(P.Block(K).Name, U) then B := P.Block(K);
      if (B = nil) and SameText(Copy(U, 1, 2), 'FC') and TryStrToInt(Copy(U, 3, MaxInt), Nr) then B := P.FindBlock(bkFC, Nr);
    end;
    if B = nil then Exit;
    if IsOut then U := Nd.Outs[Pin].Name else U := Nd.Ins[Pin].Name;
    if SameText(U, 'EN') then Exit('Bool');
    for K := 0 to High(B.Iface.Vars) do
      if SameText(B.Iface.Vars[K].Name, U) then Exit(B.Iface.Vars[K].TypeText);
    Exit;
  end;
  if IsOut then
  begin
    if Pin <= High(D.Outs) then Result := TyName(D.Outs[Pin].Ty, Nd);
  end
  else if Pin <= High(D.Ins) then Result := TyName(D.Ins[Pin].Ty, Nd)
  else if Length(D.Ins) > 0 then Result := TyName(D.Ins[High(D.Ins)].Ty, Nd);
end;

{ ---------- the order, the roots ---------- }

function Feeds(N: TNetwork; Id: Integer): Boolean;
var
  K, I: Integer;
begin
  Result := False;
  for K := 0 to High(N.Nodes) do
    for I := 0 to High(N.Nodes[K].Ins) do
      if N.Nodes[K].Ins[I].Src = Id then Exit(True);
end;

function FbdRoots(N: TNetwork): TIntArray;
var
  K, C: Integer;
begin
  Result := nil;
  C := 0;
  for K := 0 to High(N.Nodes) do
    if not Feeds(N, N.Nodes[K].Id) then
    begin
      SetLength(Result, C + 1);
      Result[C] := K;
      Inc(C);
    end;
end;

function FbdRunOrder(N: TNetwork): TIntArray;
var
  Done, Busy: array of Boolean;
  C, K, Best, I, S: Integer;
  Ready: Boolean;

  procedure Put(K: Integer);
  begin
    SetLength(Result, C + 1);
    Result[C] := K;
    Inc(C);
    Done[K] := True;
  end;

  { FBD: the inputs of a box first (a tree from its root) }
  procedure Visit(K: Integer);
  var
    I, S: Integer;
  begin
    if Done[K] or Busy[K] then Exit;
    Busy[K] := True;
    for I := 0 to High(N.Nodes[K].Ins) do
      if N.Nodes[K].Ins[I].Src > 0 then
      begin
        S := N.NodeIndex(N.Nodes[K].Ins[I].Src);
        if S >= 0 then Visit(S);
      end;
    Busy[K] := False;
    if not Done[K] then Put(K);
  end;

begin
  Result := nil;
  C := 0;
  SetLength(Done, Length(N.Nodes));
  SetLength(Busy, Length(N.Nodes));
  if N.Kind = nkFBD then
  begin
    for K := 0 to High(N.Nodes) do
      if not Feeds(N, N.Nodes[K].Id) then Visit(K);
    // boxes in a loop (no root): in their place
    for K := 0 to High(N.Nodes) do
      if not Done[K] then Visit(K);
    Exit;
  end;
  // CFC: the next one is the box with the smallest Order whose sources have all run; in a loop the smallest
  // Order of the rest
  while C < Length(N.Nodes) do
  begin
    Best := -1;
    for K := 0 to High(N.Nodes) do
    begin
      if Done[K] then Continue;
      Ready := True;
      for I := 0 to High(N.Nodes[K].Ins) do
        if N.Nodes[K].Ins[I].Src > 0 then
        begin
          S := N.NodeIndex(N.Nodes[K].Ins[I].Src);
          if (S >= 0) and (S <> K) and not Done[S] then Ready := False;
        end;
      if Ready and ((Best < 0) or (N.Nodes[K].Order < N.Nodes[Best].Order)) then Best := K;
    end;
    if Best < 0 then
      for K := 0 to High(N.Nodes) do
        if not Done[K] and ((Best < 0) or (N.Nodes[K].Order < N.Nodes[Best].Order)) then Best := K;
    Put(Best);
  end;
end;

procedure CfcRenumber(N: TNetwork);
var
  R: TIntArray;
  K: Integer;
begin
  R := FbdRunOrder(N);
  for K := 0 to High(R) do N.Nodes[R[K]].Order := K + 1;
end;

procedure CfcAutoPlace(N: TNetwork);
var
  Col: array of Integer;
  ColY: array of Integer;
  R: TIntArray;
  K, I, S, MaxC: Integer;
begin
  // a column per step of the data flow, the boxes of a column below each other
  R := FbdRunOrder(N);
  SetLength(Col, Length(N.Nodes));
  MaxC := 0;
  for K := 0 to High(R) do
  begin
    Col[R[K]] := 0;
    for I := 0 to High(N.Nodes[R[K]].Ins) do
      if N.Nodes[R[K]].Ins[I].Src > 0 then
      begin
        S := N.NodeIndex(N.Nodes[R[K]].Ins[I].Src);
        if (S >= 0) and (S <> R[K]) then Col[R[K]] := Max(Col[R[K]], Col[S] + 1);
      end;
    MaxC := Max(MaxC, Col[R[K]]);
  end;
  SetLength(ColY, MaxC + 1);
  for K := 0 to MaxC do ColY[K] := 2;
  for K := 0 to High(R) do
  begin
    N.Nodes[R[K]].X := 14 + Col[R[K]] * 30;
    N.Nodes[R[K]].Y := ColY[Col[R[K]]];
    ColY[Col[R[K]]] := ColY[Col[R[K]]] + 6 + Max(Length(N.Nodes[R[K]].Ins), Length(N.Nodes[R[K]].Outs)) * 2;
  end;
  CfcRenumber(N);
  N.ChartW := Max(N.ChartW, 14 + (MaxC + 1) * 30 + 10);
  for K := 0 to MaxC do N.ChartH := Max(N.ChartH, ColY[K] + 2);
end;

procedure FbdDeleteNode(N: TNetwork; Id: Integer; WithInputs: Boolean);
var
  K, I, J, S: Integer;
  Del: array of Integer;

  procedure Mark(AId: Integer);
  var
    Q, P: Integer;
  begin
    Q := N.NodeIndex(AId);
    if Q < 0 then Exit;
    for P := 0 to High(Del) do
      if Del[P] = AId then Exit;
    SetLength(Del, Length(Del) + 1);
    Del[High(Del)] := AId;
    if WithInputs then
      for P := 0 to High(N.Nodes[Q].Ins) do
        if N.Nodes[Q].Ins[P].Src > 0 then Mark(N.Nodes[Q].Ins[P].Src);
  end;

begin
  Del := nil;
  Mark(Id);
  for K := High(N.Nodes) downto 0 do
  begin
    S := -1;
    for J := 0 to High(Del) do
      if Del[J] = N.Nodes[K].Id then S := J;
    if S >= 0 then
    begin
      for I := K to High(N.Nodes) - 1 do N.Nodes[I] := N.Nodes[I + 1];
      SetLength(N.Nodes, Length(N.Nodes) - 1);
    end;
  end;
  // the wires from the deleted boxes are cut
  for K := 0 to High(N.Nodes) do
    for I := 0 to High(N.Nodes[K].Ins) do
      if (N.Nodes[K].Ins[I].Src > 0) and (N.NodeIndex(N.Nodes[K].Ins[I].Src) < 0) then N.Nodes[K].Ins[I].Src := 0;
end;

{ ---------- the SCL ---------- }

{ the declared type of an instance: "DB".Var (a DB variable), #Var / Var (the interface of the block) }
function InstTypeText(P: TPlcProject; Blk: TBlock; const Inst: string): string;
var
  S, Db, V: string;
  D: TDataBlock;
  K, Q: Integer;
begin
  Result := '';
  S := Trim(Inst);
  if S = '' then Exit;
  if S[1] = '#' then
  begin
    V := Copy(S, 2, MaxInt);
    if Blk <> nil then
      for K := 0 to High(Blk.Iface.Vars) do
        if SameText(Blk.Iface.Vars[K].Name, V) then Exit(Blk.Iface.Vars[K].TypeText);
    Exit;
  end;
  if (S[1] = '"') and (P <> nil) then
  begin
    Q := PosEx('"', S, 2);
    if Q = 0 then Exit;
    Db := Copy(S, 2, Q - 2);
    V := Copy(S, Q + 2, MaxInt);
    D := P.FindDBByName(Db);
    if (D = nil) or (V = '') or (Pos('.', V) > 0) or (Pos('[', V) > 0) then Exit;
    for K := 0 to High(D.Vars) do
      if SameText(D.Vars[K].Name, V) then Exit(D.Vars[K].TypeText);
  end;
end;

procedure FbdToScl(N: TNetwork; P: TPlcProject; Lines: TStrings; out LineNode: TIntArray; Errs: TStrings;
  Blk: TBlock = nil; NetNo: Integer = 0);
var
  R: TIntArray;
  K, I, J, S, Nd0: Integer;
  Wired: array of array of Boolean;
  Body, Decl: TStringList;
  BodyNode: TIntArray;
  Nd: TFbdNode;
  D: TFbdBoxDef;
  E: array of string;
  En, Op, X, Tp, Ty, Call: string;
  HasEn: Boolean;
  Seen: TStringList;

  procedure Err(AId: Integer; const S: string);
  begin
    Errs.Add(Format('%d|%s', [AId, S]));
  end;

  { the temp of an output: #fb<network>_<box>_<pin> (the temps of a block are one set: every network its own) }
  function Temp(Id: Integer; const Pin: string): string;
  begin
    if NetNo > 0 then Result := Format('#fb%d_%d_%s', [NetNo, Id, Pin]) else Result := Format('#fb%d_%s', [Id, Pin]);
  end;

  { an output that nothing reads and that writes no operand: a temp only for the monitor (the first output,
    not a string: 256 bytes of local data) }
  function MonTemp(AK, Pin: Integer): Boolean;
  begin
    Result := (Pin = 0) and not Wired[AK][Pin] and (Trim(N.Nodes[AK].Outs[Pin].Opnd) = '') and
      (N.Nodes[AK].Box <> 'move') and (N.Nodes[AK].Box <> 'smove') and
      not SameText(FbdPinType(P, N.Nodes[AK], True, Pin), 'String') and (N.Nodes[AK].Box <> 'call');
  end;

  procedure Line(const S: string);
  begin
    if HasEn then Body.Add('    ' + S) else Body.Add(S);
    SetLength(BodyNode, Body.Count);
    BodyNode[Body.Count - 1] := Nd.Id;
  end;

  { the expression of input I ('' : empty) }
  function InExpr(I: Integer): string;
  var
    Q: Integer;
  begin
    Result := '';
    if I > High(Nd.Ins) then Exit;
    if Nd.Ins[I].Src > 0 then
    begin
      Q := N.NodeIndex(Nd.Ins[I].Src);
      if (Q >= 0) and (Nd.Ins[I].SrcPin <= High(N.Nodes[Q].Outs)) then
        Result := Temp(Nd.Ins[I].Src, N.Nodes[Q].Outs[Nd.Ins[I].SrcPin].Name)
      else
        Err(Nd.Id, Format('input %s: the box it is wired to is not there', [Nd.Ins[I].Name]));
    end
    else
      Result := Trim(Nd.Ins[I].Opnd);
    if (Result <> '') and Nd.Ins[I].Neg then Result := 'NOT ' + Result;
  end;

  { the input by its name ('' : empty); an input that must be there: a message }
  function Inp(const Name: string; Need: Boolean = True): string;
  var
    Q: Integer;
  begin
    Result := '';
    for Q := 0 to High(Nd.Ins) do
      if SameText(Nd.Ins[Q].Name, Name) then Exit(InExpr(Q));
    if Need then Err(Nd.Id, Format('%s: no input %s', [D.Title, Name]));
  end;

  function Need(const Name: string): string;
  begin
    Result := Inp(Name);
    if Result = '' then
    begin
      Err(Nd.Id, Format('%s: the input %s is empty', [D.Title, Name]));
      Result := 'FALSE';
    end;
  end;

  { the inputs from the first one named Pfx on: joined with the operator }
  function Joined(const Op: string; From: Integer): string;
  var
    Q, C: Integer;
    S: string;
  begin
    Result := '';
    C := 0;
    for Q := From to High(Nd.Ins) do
    begin
      S := InExpr(Q);
      if S = '' then
      begin
        Err(Nd.Id, Format('%s: the input %s is empty', [D.Title, Nd.Ins[Q].Name]));
        S := 'FALSE';
      end;
      if C > 0 then Result := Result + ' ' + Op + ' ';
      Result := Result + S;
      Inc(C);
    end;
    if C > 1 then Result := '(' + Result + ')';
  end;

  function FirstData: Integer;
  begin
    // the first input after EN
    if (Length(Nd.Ins) > 0) and SameText(Nd.Ins[0].Name, 'EN') then Result := 1 else Result := 0;
  end;

  { the main output Q / OUT: into its temp (wired) and its operand }
  procedure Output(Pin: Integer; const Ex: string);
  var
    Dst: string;
  begin
    if Pin > High(Nd.Outs) then Exit;
    Dst := Trim(Nd.Outs[Pin].Opnd);
    if Wired[K][Pin] then
    begin
      Line(Temp(Nd.Id, Nd.Outs[Pin].Name) + ' := ' + Ex + ';');
      if Dst <> '' then Line(Dst + ' := ' + Temp(Nd.Id, Nd.Outs[Pin].Name) + ';');
    end
    else if Dst <> '' then Line(Dst + ' := ' + Ex + ';')
    else if MonTemp(K, Pin) then
      // nothing reads it: the value for the monitor only
      Line(Temp(Nd.Id, Nd.Outs[Pin].Name) + ' := ' + Ex + ';');
  end;

  function OutIdx(const Name: string): Integer;
  var
    Q: Integer;
  begin
    for Q := 0 to High(Nd.Outs) do
      if SameText(Nd.Outs[Q].Name, Name) then Exit(Q);
    Result := -1;
  end;

  procedure NeedTemp(Pin: Integer);
  var
    T: string;
  begin
    // the temp of an output (wired, or for the monitor)
    T := FbdPinType(P, Nd, True, Pin);
    if T = '' then T := 'Int';
    if Seen.IndexOf(Temp(Nd.Id, Nd.Outs[Pin].Name)) < 0 then
    begin
      Seen.Add(Temp(Nd.Id, Nd.Outs[Pin].Name));
      Decl.Add(Format('    %s : %s;', [Copy(Temp(Nd.Id, Nd.Outs[Pin].Name), 2, MaxInt), T]));
    end;
  end;

  { an FB box (timers, counters, edges): its call with the inputs, its outputs }
  procedure FbCall(const Pins: array of string);
  var
    Q, Oi: Integer;
    S, A: string;
  begin
    if Trim(Nd.Inst) = '' then
    begin
      // no call without its instance (the message says it)
      Err(Nd.Id, D.Title + ': the instance above the box is empty');
      Exit;
    end;
    S := '';
    for Q := 0 to High(Pins) do
    begin
      A := Inp(Pins[Q], False);
      if (A = '') and ((Q = 0) or (Pins[Q] = 'PT') or (Pins[Q] = 'PV')) then
      begin
        Err(Nd.Id, Format('%s: the input %s is empty', [D.Title, Pins[Q]]));
        A := 'FALSE';
      end;
      if A = '' then Continue;
      if S <> '' then S := S + ', ';
      S := S + Pins[Q] + ' := ' + A;
    end;
    // an IEC_TIMER / IEC_COUNTER is called as Inst.TON(..) / Inst.CTU(..)
    A := UpperCase(InstTypeText(P, Blk, Nd.Inst));
    if (A = 'IEC_TIMER') or (A = 'IEC_COUNTER') or (A = 'IEC_LTIMER') then
      Line(Trim(Nd.Inst) + '.' + UpperCase(Nd.Box) + '(' + S + ');')
    else
      Line(Trim(Nd.Inst) + '(' + S + ');');
    for Oi := 0 to High(Nd.Outs) do
      if Wired[K][Oi] or (Trim(Nd.Outs[Oi].Opnd) <> '') or (Oi = 0) then
        Output(Oi, Trim(Nd.Inst) + '.' + Nd.Outs[Oi].Name);
  end;

begin
  Lines.Clear;
  LineNode := nil;
  R := FbdRunOrder(N);
  // which outputs are wired
  SetLength(Wired, Length(N.Nodes));
  for K := 0 to High(N.Nodes) do SetLength(Wired[K], Length(N.Nodes[K].Outs));
  for K := 0 to High(N.Nodes) do
    for I := 0 to High(N.Nodes[K].Ins) do
      if N.Nodes[K].Ins[I].Src > 0 then
      begin
        S := N.NodeIndex(N.Nodes[K].Ins[I].Src);
        if (S >= 0) and (N.Nodes[K].Ins[I].SrcPin <= High(Wired[S])) then Wired[S][N.Nodes[K].Ins[I].SrcPin] := True;
      end;
  Body := TStringList.Create;
  Decl := TStringList.Create;
  Seen := TStringList.Create;
  try
    BodyNode := nil;
    for J := 0 to High(R) do
    begin
      K := R[J];
      Nd := N.Nodes[K];
      D := FbdBoxDefOf(Nd.Box);
      if FbdBoxIndex(Nd.Box) < 0 then
      begin
        Err(Nd.Id, 'unknown box "' + Nd.Box + '"');
        Continue;
      end;
      for I := 0 to High(Nd.Outs) do
        if (Wired[K][I] or MonTemp(K, I)) and (Nd.Box <> 'call') then NeedTemp(I);
      // EN: the box runs only while it is TRUE
      HasEn := False;
      En := Inp('EN', False);
      HasEn := False;
      Nd0 := Body.Count;
      HasEn := False;
      Line(Format('// #%d %s', [Nd.Id, D.Title]));
      if En <> '' then
      begin
        Line('IF ' + En + ' THEN');
        HasEn := True;
      end;
      SetLength(E, Length(Nd.Ins));
      case Nd.Box of
        'and': Output(0, Joined('AND', 0));
        'or': Output(0, Joined('OR', 0));
        'xor': Output(0, Joined('XOR', 0));
        'assign':
          begin
            if Trim(Nd.Inst) = '' then Err(Nd.Id, '=: the operand above the box is empty');
            Line(Trim(Nd.Inst) + ' := ' + Need('IN') + ';');
          end;
        'set', 'reset':
          begin
            if Trim(Nd.Inst) = '' then Err(Nd.Id, D.Title + ': the operand above the box is empty');
            Line('IF ' + Need('IN') + ' THEN ' + Trim(Nd.Inst) + ' := ' + IfThen(Nd.Box = 'set', 'TRUE', 'FALSE') + '; END_IF;');
          end;
        'p', 'n':
          begin
            if Trim(Nd.Inst) = '' then Err(Nd.Id, D.Title + ': the edge memory bit above the box is empty');
            X := Need('IN');
            if Nd.Box = 'p' then Output(0, '(' + X + ') AND NOT ' + Trim(Nd.Inst))
            else Output(0, 'NOT (' + X + ') AND ' + Trim(Nd.Inst));
            Line(Trim(Nd.Inst) + ' := ' + X + ';');
          end;
        'rtrig', 'ftrig': FbCall(['CLK']);
        'sr': FbCall(['S1', 'R']);
        'rs': FbCall(['S', 'R1']);
        'ton', 'tof', 'tp': FbCall(['IN', 'PT']);
        'tonr': FbCall(['IN', 'R', 'PT']);
        'ctu': FbCall(['CU', 'R', 'PV']);
        'ctd': FbCall(['CD', 'LD', 'PV']);
        'ctud': FbCall(['CU', 'CD', 'R', 'LD', 'PV']);
        'cmp':
          begin
            Op := CmpOpNames[Nd.Cmp];
            if Op = '==' then Op := '=';
            Output(0, '(' + Need('IN1') + ' ' + Op + ' ' + Need('IN2') + ')');
          end;
        'inrange': Output(0, Format('((%s <= %s) AND (%s <= %s))', [Need('MIN'), Need('VAL'), Need('VAL'), Need('MAX')]));
        'outrange': Output(0, Format('((%s < %s) OR (%s > %s))', [Need('VAL'), Need('MIN'), Need('VAL'), Need('MAX')]));
        'add': Output(0, Joined('+', FirstData));
        'sub': Output(0, '(' + Need('IN1') + ' - ' + Need('IN2') + ')');
        'mul': Output(0, Joined('*', FirstData));
        'div': Output(0, '(' + Need('IN1') + ' / ' + Need('IN2') + ')');
        'mod': Output(0, '(' + Need('IN1') + ' MOD ' + Need('IN2') + ')');
        'expt': Output(0, '(' + Need('IN1') + ' ** ' + Need('IN2') + ')');
        'neg': Output(0, '-(' + Need('IN') + ')');
        'abs', 'sqr', 'sqrt', 'exp', 'ln', 'sin', 'cos', 'tan', 'asin', 'acos', 'atan', 'frac':
          Output(0, UpperCase(Nd.Box) + '(' + Need('IN') + ')');
        'inc', 'dec':
          begin
            if Trim(Nd.Inst) = '' then Err(Nd.Id, D.Title + ': the operand above the box is empty');
            Line(Trim(Nd.Inst) + ' := ' + Trim(Nd.Inst) + IfThen(Nd.Box = 'inc', ' + 1;', ' - 1;'));
          end;
        'move', 'smove': Output(0, Need('IN'));
        'conv':
          if Nd.DType = Nd.DType2 then Output(0, Need('IN'))
          else Output(0, Format('%s_TO_%s(%s)', [UpperCase(DataTypeNames[Nd.DType]), UpperCase(DataTypeNames[Nd.DType2]), Need('IN')]));
        'round', 'trunc', 'ceil', 'floor':
          begin
            X := UpperCase(Nd.Box) + '(' + Need('IN') + ')';
            if not (Nd.DType2 in [dtDInt]) then X := Format('DINT_TO_%s(%s)', [UpperCase(DataTypeNames[Nd.DType2]), X]);
            Output(0, X);
          end;
        'normx': Output(0, Format('NORM_X(MIN := %s, VALUE := %s, MAX := %s)', [Need('MIN'), Need('VALUE'), Need('MAX')]));
        'scalex': Output(0, Format('SCALE_X(MIN := %s, VALUE := %s, MAX := %s)', [Need('MIN'), Need('VALUE'), Need('MAX')]));
        'sel': Output(0, Format('SEL(G := %s, IN0 := %s, IN1 := %s)', [Need('G'), Need('IN0'), Need('IN1')]));
        'mux':
          begin
            X := 'MUX(K := ' + Need('K');
            for I := FirstData + 1 to High(Nd.Ins) do X := X + ', ' + Nd.Ins[I].Name + ' := ' + Need(Nd.Ins[I].Name);
            Output(0, X + ')');
          end;
        'limit': Output(0, Format('LIMIT(MN := %s, IN := %s, MX := %s)', [Need('MN'), Need('IN'), Need('MX')]));
        'min', 'max':
          begin
            X := UpperCase(Nd.Box) + '(';
            for I := FirstData to High(Nd.Ins) do
            begin
              if I > FirstData then X := X + ', ';
              X := X + Nd.Ins[I].Name + ' := ' + Need(Nd.Ins[I].Name);
            end;
            Output(0, X + ')');
          end;
        'andw': Output(0, Joined('AND', FirstData));
        'orw': Output(0, Joined('OR', FirstData));
        'xorw': Output(0, Joined('XOR', FirstData));
        'invw': Output(0, 'NOT ' + Need('IN'));
        'shl', 'shr', 'rol', 'ror': Output(0, Format('%s(IN := %s, N := %s)', [UpperCase(Nd.Box), Need('IN'), Need('N')]));
        'concat': Output(0, Format('CONCAT(IN1 := %s, IN2 := %s)', [Need('IN1'), Need('IN2')]));
        'len': Output(0, Format('LEN(%s)', [Need('IN')]));
        'left', 'right': Output(0, Format('%s(IN := %s, L := %s)', [UpperCase(Nd.Box), Need('IN'), Need('L')]));
        'mid': Output(0, Format('MID(IN := %s, L := %s, P := %s)', [Need('IN'), Need('L'), Need('P')]));
        'find': Output(0, Format('FIND(IN1 := %s, IN2 := %s)', [Need('IN1'), Need('IN2')]));
        'call':
          begin
            if Trim(Nd.Inst) = '' then Err(Nd.Id, 'CALL: the block above the box is empty');
            Call := '';
            for I := FirstData to High(Nd.Ins) do
            begin
              X := InExpr(I);
              if X = '' then Continue;
              if Call <> '' then Call := Call + ', ';
              Call := Call + Nd.Ins[I].Name + ' := ' + X;
            end;
            Tp := '';
            for I := 0 to High(Nd.Outs) do
            begin
              if Nd.Outs[I].Name = 'RET_VAL' then
              begin
                Tp := Temp(Nd.Id, 'RET_VAL');
                NeedTemp(I);
                Continue;
              end;
              if Wired[K][I] then
              begin
                NeedTemp(I);
                X := Temp(Nd.Id, Nd.Outs[I].Name);
              end
              else X := Trim(Nd.Outs[I].Opnd);
              if X = '' then Continue;
              if Call <> '' then Call := Call + ', ';
              Call := Call + Nd.Outs[I].Name + ' => ' + X;
            end;
            Ty := Trim(Nd.Inst);
            if Pos('"', Ty) = 0 then Ty := '"' + Ty + '"';
            if Tp <> '' then Line(Tp + ' := ' + Ty + '(' + Call + ');') else Line(Ty + '(' + Call + ');');
            for I := 0 to High(Nd.Outs) do
              if Wired[K][I] and (Trim(Nd.Outs[I].Opnd) <> '') then
                Line(Trim(Nd.Outs[I].Opnd) + ' := ' + Temp(Nd.Id, Nd.Outs[I].Name) + ';')
              else if (Nd.Outs[I].Name = 'RET_VAL') and (Trim(Nd.Outs[I].Opnd) <> '') then
                Line(Trim(Nd.Outs[I].Opnd) + ' := ' + Tp + ';');
          end;
      end;
      if HasEn then
      begin
        HasEn := False;
        Line('END_IF;');
      end;
      if Nd0 = 0 then ;
      if Length(E) = 0 then ;
    end;
    if Decl.Count > 0 then
    begin
      Lines.Add('VAR_TEMP');
      Lines.AddStrings(Decl);
      Lines.Add('END_VAR');
    end;
    SetLength(LineNode, Lines.Count + Body.Count);
    for I := 0 to Lines.Count - 1 do LineNode[I] := 0;
    for I := 0 to Body.Count - 1 do LineNode[Lines.Count + I] := BodyNode[I];
    Lines.AddStrings(Body);
  finally
    Body.Free;
    Decl.Free;
    Seen.Free;
  end;
end;

function FbdNormalize(N: TNetwork; P: TPlcProject): string;
var
  K, I, J: Integer;
  B: TFbdNode;
  Placed: Boolean;
begin
  Result := '';
  Placed := False;
  for K := 0 to High(N.Nodes) do
  begin
    if FbdBoxIndex(N.Nodes[K].Box) < 0 then Exit(Format('node %d: unknown box "%s"', [N.Nodes[K].Id, N.Nodes[K].Box]));
    B := NewFbdNode(nil, N.Nodes[K].Box, P, N.Nodes[K].Inst);
    B.Id := N.Nodes[K].Id;
    B.Inst := N.Nodes[K].Inst;
    if FbdBoxDefOf(B.Box).HasType and (N.Nodes[K].DType <> dtBool) then B.DType := N.Nodes[K].DType;
    if FbdBoxDefOf(B.Box).HasType2 and (N.Nodes[K].DType2 <> dtNone) then B.DType2 := N.Nodes[K].DType2;
    B.Cmp := N.Nodes[K].Cmp;
    B.X := N.Nodes[K].X;
    B.Y := N.Nodes[K].Y;
    B.Order := N.Nodes[K].Order;
    if (B.X <> 0) or (B.Y <> 0) then Placed := True;
    for I := 0 to High(N.Nodes[K].Ins) do
    begin
      J := OldOfIdx(B.Ins, N.Nodes[K].Ins[I].Name);
      while (J < 0) and FbdBoxDefOf(B.Box).Ext and FbdAddInput(B) do J := OldOfIdx(B.Ins, N.Nodes[K].Ins[I].Name);
      if J < 0 then Exit(Format('node %d (%s): no input pin "%s"', [B.Id, B.Box, N.Nodes[K].Ins[I].Name]));
      B.Ins[J] := N.Nodes[K].Ins[I];
    end;
    for I := 0 to High(N.Nodes[K].Outs) do
    begin
      J := OldOfIdx(B.Outs, N.Nodes[K].Outs[I].Name);
      if J < 0 then Exit(Format('node %d (%s): no output pin "%s"', [B.Id, B.Box, N.Nodes[K].Outs[I].Name]));
      B.Outs[J] := N.Nodes[K].Outs[I];
    end;
    N.Nodes[K] := B;
  end;
  // the wires: a box written without its outputs left the pin name (#1 name): now its pins are there
  for K := 0 to High(N.Nodes) do
    for I := 0 to High(N.Nodes[K].Ins) do
      if N.Nodes[K].Ins[I].Src > 0 then
      begin
        J := N.NodeIndex(N.Nodes[K].Ins[I].Src);
        if J < 0 then
          Exit(Format('node %d: input %s is wired from node %d, which is not there', [N.Nodes[K].Id, N.Nodes[K].Ins[I].Name,
            N.Nodes[K].Ins[I].Src]));
        if Copy(N.Nodes[K].Ins[I].Opnd, 1, 1) = #1 then
        begin
          N.Nodes[K].Ins[I].SrcPin := Max(0, OldOfIdx(N.Nodes[J].Outs, Copy(N.Nodes[K].Ins[I].Opnd, 2, MaxInt)));
          if OldOfIdx(N.Nodes[J].Outs, Copy(N.Nodes[K].Ins[I].Opnd, 2, MaxInt)) < 0 then
            Exit(Format('node %d: input %s: node %d has no output "%s"', [N.Nodes[K].Id, N.Nodes[K].Ins[I].Name,
              N.Nodes[K].Ins[I].Src, Copy(N.Nodes[K].Ins[I].Opnd, 2, MaxInt)]));
          N.Nodes[K].Ins[I].Opnd := '';
        end;
      end;
  if (N.Kind = nkCFC) and not Placed then CfcAutoPlace(N)
  else if N.Kind = nkCFC then CfcRenumber(N);
end;

{ ---------- LAD to FBD ---------- }

type
  { the power at a place of the rung: none, the rail (TRUE), an operand not in a box yet (a contact on the
    rail), the output of a box }
  TSig = record
    Kind: Integer;      // 0 none, 1 rail, 2 operand, 3 box output
    Opnd: string;
    Node, Pin: Integer; // Kind 3: the box Id and its output
    Neg: Boolean;
  end;

function LadToFbd(L: TNetwork; P: TPlcProject; out Err: string): TNetwork;
var
  F: TNetwork;
  Pw, Nx: array of TSig;
  R, C, K, G0, G1, I: Integer;
  Ce: TLadCell;
  Nd: TFbdNode;
  Sg: TSig;

  function Add(const Node: TFbdNode): Integer;
  begin
    SetLength(F.Nodes, Length(F.Nodes) + 1);
    F.Nodes[High(F.Nodes)] := Node;
    Result := High(F.Nodes);
  end;

  { the signal into the input pin }
  procedure Put(var Pin: TFbdPin; const S: TSig);
  begin
    Pin.Neg := S.Neg;
    case S.Kind of
      1: Pin.Opnd := 'TRUE';
      2: Pin.Opnd := S.Opnd;
      3:
        begin
          Pin.Src := S.Node;
          Pin.SrcPin := S.Pin;
        end;
    end;
  end;

  function Box(const Id: string): TFbdNode;
  begin
    Result := NewFbdNode(F, Id, P, '');
    Result.Id := F.NewNodeId;
  end;

  function OutSig(Id, Pin: Integer): TSig;
  begin
    Result := Default(TSig);
    Result.Kind := 3;
    Result.Node := Id;
    Result.Pin := Pin;
  end;

  { the power AND a term: a new AND box, or one more input of the AND box it comes from }
  function AndSig(const A, B: TSig): TSig;
  var
    Q: Integer;
  begin
    if A.Kind = 0 then Exit(A);
    if A.Kind = 1 then Exit(B);
    if B.Kind = 1 then Exit(A);
    if (A.Kind = 3) and not A.Neg then
    begin
      Q := F.NodeIndex(A.Node);
      if (Q >= 0) and (F.Nodes[Q].Box = 'and') and not Feeds(F, A.Node) then
      begin
        FbdAddInput(F.Nodes[Q]);
        Put(F.Nodes[Q].Ins[High(F.Nodes[Q].Ins)], B);
        Exit(A);
      end;
    end;
    Nd := Box('and');
    Put(Nd.Ins[0], A);
    Put(Nd.Ins[1], B);
    Q := Add(Nd);
    Result := OutSig(F.Nodes[Q].Id, 0);
  end;

  function Term(const Opnd: string; Neg: Boolean): TSig;
  begin
    Result := Default(TSig);
    Result.Kind := 2;
    Result.Opnd := Opnd;
    Result.Neg := Neg;
  end;

  { a box with the LAD pins (by their names), its first input the power }
  function LadBox(const Id: string; const S: TSig; const PowPin: string): TFbdNode;
  var
    Q, J: Integer;
    Nm: string;
  begin
    Result := Box(Id);
    if FbdBoxDefOf(Id).Inst <> fiNone then Result.Inst := Ce.Opnd;
    Result.DType := Ce.DType;
    if FbdBoxDefOf(Id).HasType2 then Result.DType2 := Ce.DType2;
    Result.Cmp := Ce.Cmp;
    for Q := 0 to Min(4, LadParamCount(Ce.Kind) - 1) do
    begin
      Nm := LadParamName(Ce.Kind, Q);
      // an input the box has not yet (IN2 of MUX, IN3 / IN4 of MIN / MAX): added when it is given
      if (Ce.P[Q] <> '') and (OldOfIdx(Result.Ins, Nm) < 0) and (OldOfIdx(Result.Outs, Nm) < 0) and
        FbdBoxDefOf(Id).Ext then
        while (OldOfIdx(Result.Ins, Nm) < 0) and FbdAddInput(Result) do ;
      for J := 0 to High(Result.Ins) do
        if SameText(Result.Ins[J].Name, Nm) then Result.Ins[J].Opnd := Ce.P[Q];
      for J := 0 to High(Result.Outs) do
        if SameText(Result.Outs[J].Name, Nm) then Result.Outs[J].Opnd := Ce.P[Q];
    end;
    if PowPin <> '' then
      for J := 0 to High(Result.Ins) do
        if SameText(Result.Ins[J].Name, PowPin) then Put(Result.Ins[J], S);
  end;

  function BoxId(K: TLadKind): string;
  begin
    case K of
      lkAdd: Result := 'add'; lkSub: Result := 'sub'; lkMul: Result := 'mul'; lkDiv: Result := 'div';
      lkMod: Result := 'mod'; lkExpt: Result := 'expt'; lkNegate: Result := 'neg';
      lkMove: Result := 'move'; lkConv: Result := 'conv'; lkRound: Result := 'round'; lkTrunc: Result := 'trunc';
      lkCeil: Result := 'ceil'; lkFloor: Result := 'floor'; lkNormX: Result := 'normx'; lkScaleX: Result := 'scalex';
      lkSel: Result := 'sel'; lkMux: Result := 'mux'; lkLimit: Result := 'limit'; lkMin: Result := 'min'; lkMax: Result := 'max';
      lkAndW: Result := 'andw'; lkOrW: Result := 'orw'; lkXorW: Result := 'xorw'; lkInvW: Result := 'invw';
      lkShl: Result := 'shl'; lkShr: Result := 'shr'; lkRol: Result := 'rol'; lkRor: Result := 'ror';
      lkConcat: Result := 'concat'; lkLen: Result := 'len'; lkLeft: Result := 'left'; lkRight: Result := 'right';
      lkMid: Result := 'mid'; lkFind: Result := 'find'; lkSMove: Result := 'smove'; lkInc: Result := 'inc'; lkDec: Result := 'dec';
      lkSqrt: Result := 'sqrt'; lkSqr: Result := 'sqr'; lkAbs: Result := 'abs'; lkExp: Result := 'exp'; lkLn: Result := 'ln';
      lkSin: Result := 'sin'; lkCos: Result := 'cos'; lkTan: Result := 'tan'; lkAsin: Result := 'asin';
      lkAcos: Result := 'acos'; lkAtan: Result := 'atan'; lkFrac: Result := 'frac';
    else
      Result := '';
    end;
  end;

var
  Q: Integer;
  Id: string;
  Oi: Integer;
begin
  Result := nil;
  Err := '';
  F := TNetwork.Create(nkFBD);
  F.Title := L.Title;
  F.Comment := L.Comment;
  SetLength(Pw, L.Rows);
  SetLength(Nx, L.Rows);
  // every row starts at the rail
  for R := 0 to L.Rows - 1 do
  begin
    Pw[R] := Default(TSig);
    Pw[R].Kind := 1;
  end;
  for C := 0 to L.Cols - 1 do
  begin
    for R := 0 to L.Rows - 1 do
    begin
      Ce := L.Cell(R, C);
      Sg := Pw[R];
      case Ce.Kind of
        lkEmpty:
          // the right half of a box drawn over two cells carries its output on
          if (C > 0) and IsBox(L.Cell(R, C - 1).Kind) then Sg := Pw[R] else Sg := Default(TSig);
        lkWire: ;
        lkNO: Sg := AndSig(Sg, Term(Ce.Opnd, False));
        lkNC: Sg := AndSig(Sg, Term(Ce.Opnd, True));
        lkNot: if Sg.Kind <> 0 then Sg.Neg := not Sg.Neg;
        lkPos, lkNeg:
          begin
            if Ce.Kind = lkPos then Nd := Box('p') else Nd := Box('n');
            Nd.Inst := Ce.P[0];
            Put(Nd.Ins[0], Term(Ce.Opnd, False));
            Q := Add(Nd);
            Sg := AndSig(Sg, OutSig(F.Nodes[Q].Id, 0));
          end;
        lkCoil, lkCoilNeg, lkSet, lkReset:
          begin
            case Ce.Kind of
              lkSet: Nd := Box('set');
              lkReset: Nd := Box('reset');
            else
              Nd := Box('assign');
            end;
            Nd.Inst := Ce.Opnd;
            if Sg.Kind = 0 then Sg := Term('FALSE', False);
            Put(Nd.Ins[0], Sg);
            if Ce.Kind = lkCoilNeg then Nd.Ins[0].Neg := not Nd.Ins[0].Neg;
            Add(Nd);
            // a coil passes the power on (another coil after it)
          end;
        lkCmp, lkInRange, lkOutRange:
          begin
            case Ce.Kind of
              lkCmp: Nd := LadBox('cmp', Sg, '');
              lkInRange: Nd := LadBox('inrange', Sg, '');
            else
              Nd := LadBox('outrange', Sg, '');
            end;
            Q := Add(Nd);
            Sg := AndSig(Sg, OutSig(F.Nodes[Q].Id, 0));
          end;
        lkTON, lkTOF, lkTP, lkTONR, lkCTU, lkCTD, lkCTUD, lkRTrig, lkFTrig, lkRS, lkSR:
          begin
            case Ce.Kind of
              lkTON: Nd := LadBox('ton', Sg, 'IN');
              lkTOF: Nd := LadBox('tof', Sg, 'IN');
              lkTP: Nd := LadBox('tp', Sg, 'IN');
              lkTONR: Nd := LadBox('tonr', Sg, 'IN');
              lkCTU: Nd := LadBox('ctu', Sg, 'CU');
              lkCTD: Nd := LadBox('ctd', Sg, 'CD');
              lkCTUD: Nd := LadBox('ctud', Sg, 'CU');
              lkRTrig: Nd := LadBox('rtrig', Sg, 'CLK');
              lkFTrig: Nd := LadBox('ftrig', Sg, 'CLK');
              lkRS: Nd := LadBox('rs', Sg, 'S');
            else
              Nd := LadBox('sr', Sg, 'S1');
            end;
            if Sg.Kind = 0 then
              for I := 0 to High(Nd.Ins) do
                if (I = 0) then Nd.Ins[I].Opnd := 'FALSE';
            Q := Add(Nd);
            Sg := OutSig(F.Nodes[Q].Id, 0);
          end;
        lkCall:
          begin
            Nd := Box('call');
            Nd.Inst := Ce.Opnd;
            FbdCallPins(P, Ce.Opnd, Nd);
            if Sg.Kind <> 1 then Put(Nd.Ins[0], Sg);
            // the actual parameters in the pin order of LAD (inputs, InOut, outputs, Return)
            Oi := 0;
            for I := 1 to High(Nd.Ins) do
            begin
              Nd.Ins[I].Opnd := CallArg(Ce, Oi);
              Inc(Oi);
            end;
            for I := 0 to High(Nd.Outs) do
            begin
              Nd.Outs[I].Opnd := CallArg(Ce, Oi);
              Inc(Oi);
            end;
            Add(Nd);
          end;
        lkSD, lkSE, lkSP, lkSS, lkSF, lkCU, lkCD, lkSC:
          begin
            Err := Format('row %d column %d: the S5 timers / counters have no FBD box here (use TON / CTU ..)', [R + 1, C + 1]);
            F.Free;
            Exit;
          end;
      else
        begin
          Id := BoxId(Ce.Kind);
          if Id = '' then
          begin
            Err := Format('row %d column %d: %s has no FBD box', [R + 1, C + 1, LadKindNames[Ce.Kind]]);
            F.Free;
            Exit;
          end;
          if Ce.Kind in [lkInc, lkDec] then
          begin
            if Ce.Kind = lkInc then Nd := Box('inc') else Nd := Box('dec');
            Nd.Inst := Ce.P[0];
            Nd.DType := Ce.DType;
          end
          else
            Nd := LadBox(Id, Sg, '');
          // EN: the power (not the rail: then always)
          if (Sg.Kind <> 1) and (Length(Nd.Ins) > 0) and (Nd.Ins[0].Name = 'EN') then Put(Nd.Ins[0], Sg);
          Add(Nd);
          // ENO = EN: the power goes on
        end;
      end;
      Nx[R] := Sg;
    end;
    // the branch lines at the right edge of the column: their rows get the OR of their powers
    R := 0;
    while R < L.Rows do
    begin
      G0 := R;
      G1 := R;
      while (G1 + 1 < L.Rows) and L.Cell(G1, C).Down do Inc(G1);
      if G1 > G0 then
      begin
        Nd := Box('or');
        SetLength(Nd.Ins, 0);
        for K := G0 to G1 do
          if Nx[K].Kind <> 0 then
          begin
            SetLength(Nd.Ins, Length(Nd.Ins) + 1);
            Nd.Ins[High(Nd.Ins)] := Default(TFbdPin);
            Nd.Ins[High(Nd.Ins)].Name := 'IN' + IntToStr(Length(Nd.Ins));
            Put(Nd.Ins[High(Nd.Ins)], Nx[K]);
          end;
        if Length(Nd.Ins) = 1 then Sg := Nx[G0]
        else if Length(Nd.Ins) = 0 then Sg := Default(TSig)
        else
        begin
          // the rail in an OR: always TRUE
          Q := Add(Nd);
          Sg := OutSig(F.Nodes[Q].Id, 0);
        end;
        for K := G0 to G1 do Nx[K] := Sg;
      end;
      R := G1 + 1;
    end;
    for R := 0 to L.Rows - 1 do Pw[R] := Nx[R];
  end;
  Result := F;
end;

{ ---------- the elements panel ---------- }

function FbdElems(P: TPlcProject; Cur: TBlock; Cfc: Boolean): TSclElems;
var
  K, I, J: Integer;
  B: TBlock;
  D: TDataBlock;

  procedure Add(const Cat, Cap, Snip, Descr: string);
  var
    N: Integer;
  begin
    N := Length(Result);
    SetLength(Result, N + 1);
    Result[N].Cat := Cat;
    Result[N].Cap := Cap;
    Result[N].Snip := Snip;
    Result[N].Descr := Descr;
    Result[N].Kind := -1;
  end;

begin
  Result := nil;
  FbdBoxes;
  for K := 0 to High(Defs) do
    if Defs[K].Id <> 'call' then Add(Defs[K].Cat, Defs[K].Title + IfThen(Defs[K].Cat = 'Shift / word logic', ' (word)', ''),
      FbdBoxSnip + Defs[K].Id, Defs[K].Descr)
    else Add(Defs[K].Cat, 'CALL', FbdBoxSnip + 'call', Defs[K].Descr);
  if Cfc then
  begin
    Add('Editor keys', 'drag a block', '', 'Moves the block on the chart (by its title).');
    Add('Editor keys', 'drag a pin to a pin', '', 'Wires an output to an input (or an input to an output).');
    Add('Editor keys', 'Del', '', 'Deletes the selected block (its wires go too) or the selected wire.');
    Add('Editor keys', 'Ctrl+Z / Ctrl+Y', '', 'Undo / redo.');
  end
  else
  begin
    Add('Editor keys', 'click a pin, then an element', '', 'The box goes onto the input pin (its output feeds the pin).');
    Add('Editor keys', 'Del', '', 'Deletes the selected box and the boxes that feed it; on a pin: its operand.');
    Add('Editor keys', 'Ctrl+Z / Ctrl+Y', '', 'Undo / redo.');
  end;
  if P = nil then Exit;
  if Cur <> nil then
    for I := 0 to High(Cur.Iface.Vars) do
      Add(ElemProject + 'this block', '#' + Cur.Iface.Vars[I].Name, '#' + Cur.Iface.Vars[I].Name,
        Format('%s : %s  (%s)  %s', [Cur.Iface.Vars[I].Name, Cur.Iface.Vars[I].TypeText, SectionNames[Cur.Iface.Vars[I].Section],
        Cur.Iface.Vars[I].Comment]));
  for I := 0 to High(P.Tags) do
    Add(ElemProject + 'PLC tags', '"' + P.Tags[I].Name + '"', '"' + P.Tags[I].Name + '"',
      Format('%s  %s : %s  %s', [P.Tags[I].Name, P.Tags[I].Address, P.Tags[I].TypeText, P.Tags[I].Comment]));
  for I := 0 to P.DBCount - 1 do
  begin
    D := P.DB(I);
    if D.InstanceOf > 0 then
    begin
      Add(ElemProject + 'Data blocks', Format('CALL "%s"', [D.Name]), FbdBoxSnip + 'call:"' + D.Name + '"',
        Format('DB%d: the instance of FB%d - a CALL box with it.', [D.Number, D.InstanceOf]));
      Continue;
    end;
    for J := 0 to High(D.Vars) do
      Add(ElemProject + 'Data blocks', Format('"%s".%s', [D.Name, D.Vars[J].Name]), Format('"%s".%s', [D.Name, D.Vars[J].Name]),
        Format('DB%d.%s : %s  %s', [D.Number, D.Vars[J].Name, D.Vars[J].TypeText, D.Vars[J].Comment]));
  end;
  for I := 0 to P.BlockCount - 1 do
  begin
    B := P.Block(I);
    if B.Kind = bkFC then
      Add(ElemProject + 'Functions (FC)', Format('CALL "%s"', [B.Name]), FbdBoxSnip + 'call:"' + B.Name + '"',
        Format('FC%d "%s": a CALL box with its parameters as pins. %s', [B.Number, B.Name, B.Comment]));
  end;
end;

end.
