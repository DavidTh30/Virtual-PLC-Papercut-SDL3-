unit uSclElems;

{ The SCL elements of the program editor: every element of SCL Studio (the SCL Compiler), in the same
  categories, and the project's own tags, DBs, FCs, FBs and PLC data types. Each element has a caption,
  the code it inserts (ElemCur marks where the caret goes) and a description. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, uPlcTypes, uPlcProject;

const
  ElemCur = #1;          // the caret after the snippet was inserted
  ElemProject = 'Project: ';

type
  TSclElem = record
    Cat: string;
    Cap: string;
    Snip: string;        // '' : the caption only (a key of the editor); LAD: the operand it puts in
    Descr: string;
    Kind: Integer;       // LAD: Ord(TLadKind) + 256 * the comparison (1 ==, 2 <>, ..), -1: none
  end;
  TSclElems = array of TSclElem;

{ the static elements (built once) }
function SclStaticElems: TSclElems;
{ the static elements and the ones of the project (Cur: the block being edited, its interface) }
function SclElems(P: TPlcProject; Cur: TBlock): TSclElems;
{ the snippet as text: no caret mark }
function ElemText(const Snip: string): string;
{ the elements of LAD (what the CPU family has) and of STL, with the project's own, in the same categories }
function LadElems(P: TPlcProject; Cur: TBlock): TSclElems;
function StlElems(P: TPlcProject; Cur: TBlock): TSclElems;

implementation

var
  Static: TSclElems = nil;

procedure Add(var L: TSclElems; const Cat, Cap, Snip, Descr: string);
var
  N: Integer;
begin
  N := Length(L);
  SetLength(L, N + 1);
  L[N].Cat := Cat;
  L[N].Cap := Cap;
  L[N].Snip := Snip;
  L[N].Descr := Descr;
  L[N].Kind := -1;
end;

procedure AddK(var L: TSclElems; const Cat, Cap: string; K: TLadKind; Cmp: Integer; const Descr: string);
begin
  Add(L, Cat, Cap, '', Descr);
  L[High(L)].Kind := Ord(K) + 256 * Cmp;
end;

function ElemText(const Snip: string): string;
begin
  Result := StringReplace(Snip, ElemCur, '', [rfReplaceAll]);
end;

procedure Build(var L: TSclElems);
const
  NL = LineEnding;
  CUR = ElemCur;
  C_CTRL = 'Program control';
  C_OPS = 'Operators';
  C_CONST = 'Constants / literals';
  C_TYPES = 'Elementary data types';
  C_CTYPES = 'Structured data types';
  C_DECL = 'Declaration sections';
  C_BLOCKS = 'Block templates (.scl source)';
  C_BIT = 'Bit logic / edges';
  C_TIMER = 'Timers';
  C_CNT = 'Counters';
  C_CMP = 'Comparison / selection';
  C_MATH = 'Math functions';
  C_CONV = 'Conversion';
  C_SHIFT = 'Shift / rotate / slice';
  C_STR = 'String';
  C_ADDR = 'Operands / addresses';
  C_KEYS = 'Editor keys';
  Types: array[0..24] of string = ('Bool', 'Byte', 'Word', 'DWord', 'LWord', 'SInt', 'Int', 'DInt', 'LInt',
    'USInt', 'UInt', 'UDInt', 'ULInt', 'Real', 'LReal', 'Time', 'LTime', 'S5Time', 'Date', 'Time_Of_Day',
    'LTime_Of_Day', 'Date_And_Time', 'LDT', 'Char', 'WChar');
  Bits: array[0..24] of Integer = (1, 8, 16, 32, 64, 8, 16, 32, 64, 8, 16, 32, 64, 32, 64, 32, 64, 16, 16, 32,
    64, 64, 64, 8, 16);
  Math: array[0..12] of string = ('ABS', 'SQR', 'SQRT', 'EXP', 'LN', 'LOG', 'SIN', 'COS', 'TAN', 'ASIN', 'ACOS',
    'ATAN', 'FRAC');
  Conv: array[0..21] of string = ('BOOL_TO_INT', 'INT_TO_BOOL', 'INT_TO_DINT', 'DINT_TO_INT', 'INT_TO_REAL',
    'DINT_TO_REAL', 'REAL_TO_INT', 'REAL_TO_DINT', 'REAL_TO_LREAL', 'LREAL_TO_REAL', 'INT_TO_WORD', 'WORD_TO_INT',
    'DINT_TO_DWORD', 'DWORD_TO_DINT', 'BYTE_TO_WORD', 'WORD_TO_BYTE', 'TIME_TO_DINT', 'DINT_TO_TIME',
    'S5TIME_TO_TIME', 'TIME_TO_S5TIME', 'CHAR_TO_BYTE', 'BYTE_TO_CHAR');
var
  K: Integer;
begin
  { ---- program control ---- }
  Add(L, C_CTRL, 'IF ... THEN', 'IF ' + CUR + ' THEN' + NL + '    ;' + NL + 'END_IF;', 'Conditional execution.');
  Add(L, C_CTRL, 'IF ... ELSE', 'IF ' + CUR + ' THEN' + NL + '    ;' + NL + 'ELSE' + NL + '    ;' + NL + 'END_IF;',
    'Two branches.');
  Add(L, C_CTRL, 'IF ... ELSIF ... ELSE', 'IF ' + CUR + ' THEN' + NL + '    ;' + NL + 'ELSIF  THEN' + NL + '    ;' + NL +
    'ELSE' + NL + '    ;' + NL + 'END_IF;', 'Several conditions, tested in order.');
  Add(L, C_CTRL, 'CASE ... OF', 'CASE ' + CUR + ' OF' + NL + '    1:' + NL + '        ;' + NL + '    2, 3:' + NL +
    '        ;' + NL + '    4..9:' + NL + '        ;' + NL + 'ELSE' + NL + '    ;' + NL + 'END_CASE;',
    'Multi-way branch on an integer selector. Labels: a value, a list (2, 3) or a range (4..9).');
  Add(L, C_CTRL, 'FOR ... TO ... DO', 'FOR #i := 0 TO ' + CUR + ' DO' + NL + '    ;' + NL + 'END_FOR;',
    'Counting loop. The control variable must be an integer (VAR_TEMP i : Int;).');
  Add(L, C_CTRL, 'FOR ... BY ... DO', 'FOR #i := 10 TO 0 BY -1 DO' + NL + '    ' + CUR + ';' + NL + 'END_FOR;',
    'Counting loop with a step (BY may be negative, a constant).');
  Add(L, C_CTRL, 'WHILE ... DO', 'WHILE ' + CUR + ' DO' + NL + '    ;' + NL + 'END_WHILE;',
    'Loop while the condition is TRUE (checked before each pass).');
  Add(L, C_CTRL, 'REPEAT ... UNTIL', 'REPEAT' + NL + '    ' + CUR + ';' + NL + 'UNTIL  END_REPEAT;',
    'Loop until the condition is TRUE (checked after each pass).');
  Add(L, C_CTRL, 'CONTINUE', 'CONTINUE;', 'Skip to the next loop pass.');
  Add(L, C_CTRL, 'EXIT', 'EXIT;', 'Leave the innermost loop.');
  Add(L, C_CTRL, 'RETURN', 'RETURN;', 'Leave the block.');
  Add(L, C_CTRL, 'REGION', 'REGION ' + CUR + 'Name' + NL + '    ;' + NL + 'END_REGION', 'A region of code with a name.');
  Add(L, C_CTRL, ':= (assignment)', CUR + ' := ;', 'Assignment: target := expression;');
  Add(L, C_CTRL, '// comment', '// ' + CUR, 'Line comment.');
  Add(L, C_CTRL, '(* comment *)', '(* ' + CUR + ' *)', 'Block comment (also over several lines).');

  { ---- operators ---- }
  Add(L, C_OPS, 'AND', ' AND ', 'Logical / bitwise AND (also &).');
  Add(L, C_OPS, 'OR', ' OR ', 'Logical / bitwise OR.');
  Add(L, C_OPS, 'XOR', ' XOR ', 'Exclusive OR.');
  Add(L, C_OPS, 'NOT', 'NOT ', 'Negation (Bool) or the complement of a bit string.');
  Add(L, C_OPS, '=', ' = ', 'Equal.');
  Add(L, C_OPS, '<>', ' <> ', 'Not equal.');
  Add(L, C_OPS, '<', ' < ', 'Less than.');
  Add(L, C_OPS, '<=', ' <= ', 'Less or equal.');
  Add(L, C_OPS, '>', ' > ', 'Greater than.');
  Add(L, C_OPS, '>=', ' >= ', 'Greater or equal.');
  Add(L, C_OPS, '+', ' + ', 'Addition (numbers, Time).');
  Add(L, C_OPS, '-', ' - ', 'Subtraction.');
  Add(L, C_OPS, '*', ' * ', 'Multiplication.');
  Add(L, C_OPS, '/', ' / ', 'Division (an integer division truncates).');
  Add(L, C_OPS, 'MOD', ' MOD ', 'Remainder of an integer division.');
  Add(L, C_OPS, '**', ' ** ', 'Exponent (the result is a Real). Binds tighter than a unary minus.');

  { ---- constants ---- }
  Add(L, C_CONST, 'TRUE', 'TRUE', 'Bool constant.');
  Add(L, C_CONST, 'FALSE', 'FALSE', 'Bool constant.');
  Add(L, C_CONST, 'T#1S (Time)', 'T#1S', 'Time: T#1D2H3M4S5MS (range -24D..24D).');
  Add(L, C_CONST, 'LT#1MS (LTime)', 'LT#1MS', 'LTime in ns resolution (S7-1500).');
  Add(L, C_CONST, 'S5T#1S (S5Time)', 'S5T#1S', 'S5Time (S7-300/400).');
  Add(L, C_CONST, 'D#2024-01-01 (Date)', 'D#2024-01-01', 'Date (days since 1990-01-01).');
  Add(L, C_CONST, 'TOD#12:00:00 (Time_Of_Day)', 'TOD#12:00:00', 'Time of day (ms since midnight).');
  Add(L, C_CONST, 'DT#2024-01-01-12:00:00', 'DT#2024-01-01-12:00:00', 'Date and time.');
  Add(L, C_CONST, '16#FF (hex)', '16#FF', 'Hexadecimal integer.');
  Add(L, C_CONST, '8#17 (octal)', '8#17', 'Octal integer.');
  Add(L, C_CONST, '2#1010 (binary)', '2#1010', 'Binary integer.');
  Add(L, C_CONST, 'W#16#0000 (Word)', 'W#16#0000', 'Typed Word constant (also B#16#, DW#16#, LW#16#).');
  Add(L, C_CONST, 'INT#5 (typed)', 'INT#5', 'Typed integer constant: SINT#, USINT#, INT#, UINT#, DINT#, UDINT#, ' +
    'BYTE#, WORD#, DWORD#, BOOL#, REAL#, also INT#16#FF.');
  Add(L, C_CONST, 'CHAR#''A''', 'CHAR#''' + CUR + 'A''', 'Typed Char constant.');
  Add(L, C_CONST, '''text'' (String)', '''' + CUR + '''', 'String literal. Escape: $N new line, $T tab, $'' quote.');

  { ---- elementary types ---- }
  for K := 0 to High(Types) do
    Add(L, C_TYPES, Types[K], Types[K], Format('%s - %d bit. LInt/ULInt/LWord/LTime/LTOD/LDT: S7-1500 only. ' +
      'SInt/USInt/UInt/UDInt/LReal/WChar: S7-1200/1500. S5Time: S7-300/400.', [Types[K], Bits[K]]));

  { ---- structured types ---- }
  Add(L, C_CTYPES, 'Array[..] of', 'Array[0..' + CUR + '9] of Int', 'One-dimensional array.');
  Add(L, C_CTYPES, 'Array[.., ..] of', 'Array[0..' + CUR + '2, 0..3] of Int',
    'Two-dimensional array: "DB".a[1, 2] (the last index runs fastest).');
  Add(L, C_CTYPES, 'Struct', 'Struct' + NL + '    ' + CUR + 'Member : Int;' + NL + 'END_STRUCT', 'Anonymous structure.');
  Add(L, C_CTYPES, 'String[n]', 'String[' + CUR + '20]', 'String with a max. length n (<= 254).');
  Add(L, C_CTYPES, 'WString[n]', 'WString[' + CUR + '20]', 'Unicode string (S7-1200/1500).');
  Add(L, C_CTYPES, 'DTL', 'DTL', 'Date and time long (S7-1200/1500): YEAR MONTH DAY WEEKDAY HOUR MINUTE SECOND NANOSECOND.');
  Add(L, C_CTYPES, 'IEC_TIMER / TON_TIME', 'TON_TIME', 'An IEC timer instance: TON_TIME, TOF_TIME, TP_TIME, ' +
    'TONR_TIME or IEC_TIMER.');
  Add(L, C_CTYPES, 'IEC_COUNTER / CTU_INT', 'CTU_INT', 'An IEC counter instance: CTU_INT, CTD_INT, CTUD_INT or ' +
    'IEC_COUNTER.');

  { ---- declaration sections ---- }
  Add(L, C_DECL, 'VAR_INPUT', 'VAR_INPUT' + NL + '    ' + CUR + 'In1 : Bool;' + NL + 'END_VAR',
    'Input parameters (an .scl source; in the editor: + Input of the interface).');
  Add(L, C_DECL, 'VAR_OUTPUT', 'VAR_OUTPUT' + NL + '    ' + CUR + 'Out1 : Bool;' + NL + 'END_VAR', 'Output parameters.');
  Add(L, C_DECL, 'VAR_IN_OUT', 'VAR_IN_OUT' + NL + '    ' + CUR + 'InOut1 : Int;' + NL + 'END_VAR',
    'In/out parameters (by reference).');
  Add(L, C_DECL, 'VAR (static)', 'VAR' + NL + '    ' + CUR + 'Stat1 : Int;' + NL + 'END_VAR', 'Static variables (FB / DB).');
  Add(L, C_DECL, 'VAR RETAIN', 'VAR RETAIN' + NL + '    ' + CUR + 'Stat1 : Int;' + NL + 'END_VAR',
    'Retentive static variables.');
  Add(L, C_DECL, 'VAR_TEMP', 'VAR_TEMP' + NL + '    ' + CUR + 'tmp : Int;' + NL + 'END_VAR',
    'Temporary variables at the top of a network: #tmp.');
  Add(L, C_DECL, 'VAR CONSTANT', 'VAR CONSTANT' + NL + '    ' + CUR + 'C_MAX : Int := 10;' + NL + 'END_VAR',
    'Local constants at the top of a network: #C_MAX (read only).');

  { ---- block templates ---- }
  Add(L, C_BLOCKS, 'FUNCTION (FC)', 'FUNCTION "' + CUR + 'NewFC" : Void' + NL + 'VERSION : 0.1' + NL + '   VAR_INPUT' + NL +
    '      IN : Int;' + NL + '   END_VAR' + NL + NL + 'BEGIN' + NL + NL + 'END_FUNCTION',
    'A function without memory, for an .scl source (Import .scl makes the block).');
  Add(L, C_BLOCKS, 'FUNCTION_BLOCK (FB)', 'FUNCTION_BLOCK "' + CUR + 'NewFB"' + NL + 'VERSION : 0.1' + NL + '   VAR_INPUT' + NL +
    '      Start : Bool;' + NL + '   END_VAR' + NL + '   VAR' + NL + '      Count : DInt;' + NL + '   END_VAR' + NL + NL +
    'BEGIN' + NL + NL + 'END_FUNCTION_BLOCK', 'A function block with instance memory, for an .scl source.');
  Add(L, C_BLOCKS, 'ORGANIZATION_BLOCK (OB)', 'ORGANIZATION_BLOCK "' + CUR + 'Main"' + NL + 'VERSION : 0.1' + NL + NL +
    'BEGIN' + NL + NL + 'END_ORGANIZATION_BLOCK', 'An organization block (Main = OB1, Startup = OB100).');
  Add(L, C_BLOCKS, 'DATA_BLOCK (global)', 'DATA_BLOCK "' + CUR + 'NewDB"' + NL + 'VERSION : 0.1' + NL + '   VAR' + NL +
    '      Value : Int;' + NL + '   END_VAR' + NL + NL + 'BEGIN' + NL + NL + 'END_DATA_BLOCK', 'A global data block.');
  Add(L, C_BLOCKS, 'DATA_BLOCK (instance)', 'DATA_BLOCK "' + CUR + 'iNewFB"' + NL + 'VERSION : 0.1' + NL + 'NON_RETAIN' + NL +
    '"NewFB"' + NL + NL + 'BEGIN' + NL + NL + 'END_DATA_BLOCK', 'The instance data block of an FB.');
  Add(L, C_BLOCKS, 'TYPE (UDT)', 'TYPE "' + CUR + 'typeNew"' + NL + 'VERSION : 0.1' + NL + '   STRUCT' + NL +
    '      Value : Int;' + NL + '   END_STRUCT;' + NL + NL + 'END_TYPE', 'A PLC data type.');

  { ---- bit logic / edges ---- }
  Add(L, C_BIT, 'R_TRIG (rising edge)', '#' + CUR + 'R_TRIG_Instance(CLK := );',
    'Declare as a Static:  R_TRIG_Instance : R_TRIG' + NL + 'Q = TRUE for one cycle on a rising edge of CLK.');
  Add(L, C_BIT, 'F_TRIG (falling edge)', '#' + CUR + 'F_TRIG_Instance(CLK := );',
    'Declare as a Static:  F_TRIG_Instance : F_TRIG' + NL + 'Q = TRUE for one cycle on a falling edge of CLK.');
  Add(L, C_BIT, 'RS (reset dominant)', '#' + CUR + 'RS_Instance(S := , R1 := );',
    'Declare as a Static:  RS_Instance : RS' + NL + 'Q1: R1 wins over S.');
  Add(L, C_BIT, 'SR (set dominant)', '#' + CUR + 'SR_Instance(S1 := , R := );',
    'Declare as a Static:  SR_Instance : SR' + NL + 'Q1: S1 wins over R.');

  { ---- timers ---- }
  Add(L, C_TIMER, 'TON (on delay)', '#' + CUR + 'TON_Instance(IN := , PT := T#1S);',
    'Declare as a Static:  TON_Instance : TON_TIME' + NL + 'Q = TRUE after IN was TRUE for PT. Outputs: .Q .ET');
  Add(L, C_TIMER, 'TOF (off delay)', '#' + CUR + 'TOF_Instance(IN := , PT := T#1S);',
    'Declare as a Static:  TOF_Instance : TOF_TIME');
  Add(L, C_TIMER, 'TP (pulse)', '#' + CUR + 'TP_Instance(IN := , PT := T#1S);', 'Declare as a Static:  TP_Instance : TP_TIME');
  Add(L, C_TIMER, 'TONR (retentive on delay)', '#' + CUR + 'TONR_Instance(IN := , R := , PT := T#1S);',
    'Declare as a Static:  TONR_Instance : TONR_TIME  (S7-1200/1500)');
  Add(L, C_TIMER, 'IEC_TIMER .TON', '"' + CUR + 'DB".Timer.TON(IN := , PT := T#1S);',
    'A Static or a DB variable:  Timer : IEC_TIMER  (also .TOF .TP .TONR)');

  { ---- counters ---- }
  Add(L, C_CNT, 'CTU (count up)', '#' + CUR + 'CTU_Instance(CU := , R := , PV := 10);',
    'Declare as a Static:  CTU_Instance : CTU_INT' + NL + 'Outputs: .Q .CV');
  Add(L, C_CNT, 'CTD (count down)', '#' + CUR + 'CTD_Instance(CD := , LD := , PV := 10);',
    'Declare as a Static:  CTD_Instance : CTD_INT');
  Add(L, C_CNT, 'CTUD (up / down)', '#' + CUR + 'CTUD_Instance(CU := , CD := , R := , LD := , PV := 10);',
    'Declare as a Static:  CTUD_Instance : CTUD_INT  Outputs: .QU .QD .CV');
  Add(L, C_CNT, 'IEC_COUNTER .CTU', '"' + CUR + 'DB".Counter.CTU(CU := , R := , PV := 10);',
    'A Static or a DB variable:  Counter : IEC_COUNTER  (also .CTD .CTUD)');

  { ---- comparison / selection ---- }
  Add(L, C_CMP, 'MIN', 'MIN(IN1 := ' + CUR + ', IN2 := )', 'Smallest input (2..32 inputs).');
  Add(L, C_CMP, 'MAX', 'MAX(IN1 := ' + CUR + ', IN2 := )', 'Largest input.');
  Add(L, C_CMP, 'LIMIT', 'LIMIT(MN := ' + CUR + ', IN := , MX := )', 'Clamp IN to MN..MX.');
  Add(L, C_CMP, 'SEL', 'SEL(G := ' + CUR + ', IN0 := , IN1 := )', 'G = FALSE -> IN0, G = TRUE -> IN1.');
  Add(L, C_CMP, 'MUX', 'MUX(K := ' + CUR + ', IN0 := , IN1 := , IN2 := )',
    'Input number K (IN0..IN31); INELSE := .. when K is outside (else 0).');

  { ---- math ---- }
  for K := 0 to High(Math) do
    Add(L, C_MATH, Math[K], Math[K] + '(' + CUR + ')', Math[K] + '(IN) - floating point math function ' +
      '(ABS also for integers).');

  { ---- conversion ---- }
  Add(L, C_CONV, 'TRUNC', 'TRUNC(' + CUR + ')', 'Real -> DInt, cut off the decimals.');
  Add(L, C_CONV, 'ROUND', 'ROUND(' + CUR + ')', 'Real -> DInt, to the nearest (a half to even).');
  Add(L, C_CONV, 'CEIL', 'CEIL(' + CUR + ')', 'Real -> DInt, round up.');
  Add(L, C_CONV, 'FLOOR', 'FLOOR(' + CUR + ')', 'Real -> DInt, round down.');
  Add(L, C_CONV, 'NORM_X', 'NORM_X(MIN := 0, VALUE := ' + CUR + ', MAX := 27648)', 'Normalize VALUE to 0.0..1.0.');
  Add(L, C_CONV, 'SCALE_X', 'SCALE_X(MIN := 0.0, VALUE := ' + CUR + ', MAX := 100.0)', 'Scale 0.0..1.0 to MIN..MAX.');
  for K := 0 to High(Conv) do
    Add(L, C_CONV, Conv[K], Conv[K] + '(' + CUR + ')', 'Explicit conversion ' + StringReplace(Conv[K], '_TO_', ' -> ', []) +
      '. Every pair of numeric / bit string / time types is available as X_TO_Y.');

  { ---- shift / slice ---- }
  Add(L, C_SHIFT, 'SHL', 'SHL(IN := ' + CUR + ', N := 1)', 'Shift left.');
  Add(L, C_SHIFT, 'SHR', 'SHR(IN := ' + CUR + ', N := 1)', 'Shift right.');
  Add(L, C_SHIFT, 'ROL', 'ROL(IN := ' + CUR + ', N := 1)', 'Rotate left.');
  Add(L, C_SHIFT, 'ROR', 'ROR(IN := ' + CUR + ', N := 1)', 'Rotate right.');
  Add(L, C_SHIFT, '.%X0 (bit slice)', '.%X' + CUR + '0', 'Bit n of a bit string / integer: "DB".w.%X3 (read and write).');
  Add(L, C_SHIFT, '.%B0 (byte slice)', '.%B' + CUR + '0', 'Byte n (B0 = the least significant).');
  Add(L, C_SHIFT, '.%W0 (word slice)', '.%W' + CUR + '0', 'Word n of a DWord / DInt.');
  Add(L, C_SHIFT, '.%D0 (dword slice)', '.%D' + CUR + '0', 'DWord n of an LWord.');

  { ---- string ---- }
  Add(L, C_STR, 'LEN', 'LEN(' + CUR + ')', 'The current length of a string.');
  Add(L, C_STR, 'CONCAT', 'CONCAT(IN1 := ' + CUR + ', IN2 := )', 'Join two strings.');
  Add(L, C_STR, 'LEFT', 'LEFT(IN := ' + CUR + ', L := 1)', 'The first L characters.');
  Add(L, C_STR, 'RIGHT', 'RIGHT(IN := ' + CUR + ', L := 1)', 'The last L characters.');
  Add(L, C_STR, 'MID', 'MID(IN := ' + CUR + ', L := 1, P := 1)', 'L characters from the position P.');
  Add(L, C_STR, 'FIND', 'FIND(IN1 := ' + CUR + ', IN2 := )', 'The position of IN2 in IN1 (0 = not found).');

  { ---- operands ---- }
  Add(L, C_ADDR, '"Tag"', '"' + CUR + '"', 'A PLC tag by its name.');
  Add(L, C_ADDR, '"DB".Var', '"' + CUR + 'DB".Var', 'A variable of a data block.');
  Add(L, C_ADDR, '"DB".Arr[#i]', '"' + CUR + 'DB".Arr[#i]', 'An array element with a variable index.');
  Add(L, C_ADDR, '#local', '#' + CUR, 'A parameter, a Static, a VAR_TEMP or a VAR CONSTANT of the block.');
  Add(L, C_ADDR, '%MW20', '%MW' + CUR + '20', 'An absolute address: %I %Q %M, X B W D, %DB1.DBW0.');
  Add(L, C_ADDR, 'FC call', '"' + CUR + 'Name"(In := , Out => );', 'An FC: named (:= inputs, => outputs) or positional.');
  Add(L, C_ADDR, 'FB call', '"' + CUR + 'Inst_DB"(In := , Out => );', 'An FB with its instance DB, or #multi(..).');

  { ---- the PLC clock ---- }
  Add(L, 'Date and time (clock)', 'RD_LOC_T', '#Ret := RD_LOC_T(OUT => ' + CUR + '#Now);',
    'Reads the local time of the PLC clock into a DTL (also a DT or an LDT). S7-1200/1500.');
  Add(L, 'Date and time (clock)', 'RD_SYS_T', '#Ret := RD_SYS_T(OUT => ' + CUR + '#Utc);',
    'Reads the system time (UTC) into a DTL (or an LDT). S7-1200/1500.');
  Add(L, 'Date and time (clock)', 'WR_LOC_T', '#Ret := WR_LOC_T(LOCTIME := ' + CUR + '#SetTo, DST := FALSE);',
    'Sets the PLC clock to a local time (a DTL, DT or LDT). S7-1200/1500.');
  Add(L, 'Date and time (clock)', 'WR_SYS_T', '#Ret := WR_SYS_T(IN := ' + CUR + '#SetTo);',
    'Sets the PLC clock to a system time (UTC: a DTL or an LDT). S7-1200/1500.');
  Add(L, 'Date and time (clock)', 'TIME_TCK', CUR + '#Tick := TIME_TCK();',
    'The milliseconds since the CPU started (a Time; for measuring times).');
  Add(L, 'Date and time (clock)', 'READ_CLK', '#Ret := READ_CLK(CDT => ' + CUR + '#Dt);',
    'Reads the PLC clock into a Date_And_Time (SFC1 of the S7-300/400; also on the 1500).');
  Add(L, 'Date and time (clock)', 'SET_CLK', '#Ret := SET_CLK(PDT := ' + CUR + '#Dt);',
    'Sets the PLC clock from a Date_And_Time (SFC0 of the S7-300/400).');

  { ---- the keys of the editor ---- }
  Add(L, C_KEYS, 'Ctrl+Z / Ctrl+Y', '', 'Undo / redo.');
  Add(L, C_KEYS, 'Ctrl+D', '', 'Duplicate the line.');
  Add(L, C_KEYS, 'Ctrl+L', '', 'Delete the line.');
  Add(L, C_KEYS, 'Ctrl+Q', '', 'Comment / uncomment the lines.');
  Add(L, C_KEYS, 'Ctrl+Shift+Up/Down', '', 'Move the lines.');
  Add(L, C_KEYS, 'Ctrl+F / Ctrl+H / F3', '', 'Find / replace / find the next.');
  Add(L, C_KEYS, 'Ctrl+G', '', 'Go to a line.');
  Add(L, C_KEYS, 'Ctrl+Space', '', 'Complete a name.');
  Add(L, C_KEYS, 'Alt+drag, Alt+Shift+arrows', '', 'A column selection.');
end;

procedure BuildLad(var L: TSclElems; Fam: TCpuFamily);
const
  C_BIT = 'Bit logic';
  C_EDGE = 'Bit logic / edges (boxes)';
  C_TIMER = 'Timers';
  C_CNT = 'Counters';
  C_CMP = 'Comparison / selection';
  C_MATH = 'Math functions';
  C_MOVE = 'Move / conversion';
  C_SHIFT = 'Shift / rotate / word logic';
  C_STR = 'String';
  C_CTRL = 'Program control';
  C_KEYS = 'Editor keys';
  Fns: array[0..10] of TLadKind = (lkAbs, lkSqr, lkSqrt, lkExp, lkLn, lkSin, lkCos, lkTan, lkAsin, lkAcos, lkAtan);
var
  K: Integer;
  S5: Boolean;
begin
  S5 := Fam <> cfS71200;
  AddK(L, C_BIT, '-| |- NO contact', lkNO, 0, 'Normally open: the power goes on when the operand is 1.');
  AddK(L, C_BIT, '-|/|- NC contact', lkNC, 0, 'Normally closed: the power goes on when the operand is 0.');
  AddK(L, C_BIT, '-|P|- P contact', lkPos, 0, 'A rising edge of the operand (the edge memory bit below it).');
  AddK(L, C_BIT, '-|N|- N contact', lkNeg, 0, 'A falling edge of the operand.');
  AddK(L, C_BIT, '-|NOT|-', lkNot, 0, 'Inverts the power flow.');
  AddK(L, C_BIT, 'wire', lkWire, 0, 'A wire: the power goes through.');
  AddK(L, C_BIT, '-( )- Coil', lkCoil, 0, 'Assignment: the operand := the power.');
  AddK(L, C_BIT, '-(/)- Negated coil', lkCoilNeg, 0, 'The operand := NOT the power.');
  AddK(L, C_BIT, '-(S)- Set coil', lkSet, 0, 'The operand := 1 while the power is on.');
  AddK(L, C_BIT, '-(R)- Reset coil', lkReset, 0, 'The operand := 0 while the power is on (also a timer / counter).');
  AddK(L, C_EDGE, 'R_TRIG', lkRTrig, 0, 'Rising edge box: CLK is the rung, Q the power out for one cycle. Its instance: an ' +
    'R_TRIG variable (a Static or in a DB).');
  AddK(L, C_EDGE, 'F_TRIG', lkFTrig, 0, 'Falling edge box: Q is 1 for one cycle when CLK goes 0. Instance: F_TRIG.');
  AddK(L, C_EDGE, 'RS (reset dominant)', lkRS, 0, 'Flip-flop: S is the rung, R1 resets and wins. Instance: RS.');
  AddK(L, C_EDGE, 'SR (set dominant)', lkSR, 0, 'Flip-flop: S1 is the rung and wins, R resets. Instance: SR.');
  AddK(L, C_TIMER, 'TON', lkTON, 0, 'On delay: Q after IN (the rung) was 1 for PT. The instance: IEC_TIMER, TON_TIME or ' +
    'TON_LTIME (PT in LT#).');
  AddK(L, C_TIMER, 'TOF', lkTOF, 0, 'Off delay: Q stays 1 for PT after IN went 0.');
  AddK(L, C_TIMER, 'TP', lkTP, 0, 'Pulse: Q is 1 for PT from a rising edge of IN.');
  if IsTia(Fam) then AddK(L, C_TIMER, 'TONR', lkTONR, 0, 'Retentive on delay: the time adds up while IN is 1, R resets.');
  if S5 then
  begin
    AddK(L, C_TIMER, '(SD) S5 on delay', lkSD, 0, 'S5 timer T n as an on delay coil (time value S5T#).');
    AddK(L, C_TIMER, '(SE) S5 ext. pulse', lkSE, 0, 'S5 timer T n: an extended pulse.');
    AddK(L, C_TIMER, '(SP) S5 pulse', lkSP, 0, 'S5 timer T n: a pulse while the power is on.');
    AddK(L, C_TIMER, '(SS) S5 ret. on delay', lkSS, 0, 'S5 timer T n: a retentive on delay (reset with R).');
    AddK(L, C_TIMER, '(SF) S5 off delay', lkSF, 0, 'S5 timer T n: an off delay.');
  end;
  AddK(L, C_CNT, 'CTU', lkCTU, 0, 'Count up on the rising edges of CU (the rung); R resets, Q at CV >= PV. Instance: ' +
    'IEC_COUNTER, CTU_INT, CTU_DINT ..');
  AddK(L, C_CNT, 'CTD', lkCTD, 0, 'Count down on CD (the rung); LD loads PV, Q at CV <= 0.');
  AddK(L, C_CNT, 'CTUD', lkCTUD, 0, 'Count up (the rung) and down (CD); R, LD; QU / QD.');
  if S5 then
  begin
    AddK(L, C_CNT, '(CU) S5 count up', lkCU, 0, 'S5 counter C n: count up.');
    AddK(L, C_CNT, '(CD) S5 count down', lkCD, 0, 'S5 counter C n: count down.');
    AddK(L, C_CNT, '(SC) S5 set counter', lkSC, 0, 'S5 counter C n := the preset (C#).');
  end;
  AddK(L, C_CMP, 'CMP ==', lkCmp, 1, 'The power goes on when IN1 = IN2 (the data type in the box).');
  AddK(L, C_CMP, 'CMP <>', lkCmp, 2, 'IN1 <> IN2.');
  AddK(L, C_CMP, 'CMP >', lkCmp, 3, 'IN1 > IN2.');
  AddK(L, C_CMP, 'CMP <', lkCmp, 4, 'IN1 < IN2.');
  AddK(L, C_CMP, 'CMP >=', lkCmp, 5, 'IN1 >= IN2.');
  AddK(L, C_CMP, 'CMP <=', lkCmp, 6, 'IN1 <= IN2.');
  AddK(L, C_CMP, 'IN_RANGE', lkInRange, 0, 'The power goes on when MIN <= VAL <= MAX.');
  AddK(L, C_CMP, 'OUT_RANGE', lkOutRange, 0, 'The power goes on when VAL < MIN or VAL > MAX.');
  AddK(L, C_CMP, 'SEL', lkSel, 0, 'OUT := IN1 when G, else IN0 (EN: the rung, ENO = EN). As SCL SEL.');
  AddK(L, C_CMP, 'MUX', lkMux, 0, 'OUT := the input number K (IN0 .. IN2; IN2 may stay empty). As SCL MUX.');
  AddK(L, C_CMP, 'LIMIT', lkLimit, 0, 'OUT := IN, limited to MN .. MX.');
  AddK(L, C_CMP, 'MIN', lkMin, 0, 'OUT := the smallest input (IN1 .. IN4, IN3 / IN4 may stay empty).');
  AddK(L, C_CMP, 'MAX', lkMax, 0, 'OUT := the largest input.');
  AddK(L, C_MATH, 'ADD', lkAdd, 0, 'OUT := IN1 + IN2 (the data type in the box).');
  AddK(L, C_MATH, 'SUB', lkSub, 0, 'OUT := IN1 - IN2.');
  AddK(L, C_MATH, 'MUL', lkMul, 0, 'OUT := IN1 * IN2.');
  AddK(L, C_MATH, 'DIV', lkDiv, 0, 'OUT := IN1 / IN2.');
  AddK(L, C_MATH, 'MOD', lkMod, 0, 'OUT := IN1 MOD IN2 (integers).');
  AddK(L, C_MATH, 'NEG', lkNegate, 0, 'OUT := -IN.');
  AddK(L, C_MATH, 'INC', lkInc, 0, 'IN_OUT := IN_OUT + 1 while the power is on.');
  AddK(L, C_MATH, 'DEC', lkDec, 0, 'IN_OUT := IN_OUT - 1 while the power is on.');
  AddK(L, C_MATH, 'EXPT', lkExpt, 0, 'OUT := IN1 ** IN2 (a Real).');
  for K := 0 to High(Fns) do
    AddK(L, C_MATH, LadKindNames[Fns[K]], Fns[K], 0, 'OUT := ' + LadKindNames[Fns[K]] + '(IN): a floating point function ' +
      '(ABS also for integers). As the SCL function.');
  AddK(L, C_MATH, 'FRAC', lkFrac, 0, 'OUT := the decimal places of IN.');
  AddK(L, C_MOVE, 'MOVE', lkMove, 0, 'OUT1 := IN (the data type in the box).');
  AddK(L, C_MOVE, 'S_MOVE', lkSMove, 0, 'OUT := IN for strings (and any value): the target keeps its own length.');
  AddK(L, C_MOVE, 'CONV', lkConv, 0, 'OUT := IN converted (IN / OUT types in the box; a value OUT cannot hold: ENO = 0).');
  AddK(L, C_MOVE, 'ROUND', lkRound, 0, 'Real -> integer, to the nearest (a half to even).');
  AddK(L, C_MOVE, 'TRUNC', lkTrunc, 0, 'Real -> integer, the decimals cut off.');
  AddK(L, C_MOVE, 'CEIL', lkCeil, 0, 'Real -> integer, up.');
  AddK(L, C_MOVE, 'FLOOR', lkFloor, 0, 'Real -> integer, down.');
  AddK(L, C_MOVE, 'NORM_X', lkNormX, 0, 'OUT := (VALUE - MIN) / (MAX - MIN): 0.0 .. 1.0.');
  AddK(L, C_MOVE, 'SCALE_X', lkScaleX, 0, 'OUT := VALUE * (MAX - MIN) + MIN.');
  AddK(L, C_SHIFT, 'SHL', lkShl, 0, 'OUT := IN shifted left by N bits.');
  AddK(L, C_SHIFT, 'SHR', lkShr, 0, 'OUT := IN shifted right by N bits.');
  AddK(L, C_SHIFT, 'ROL', lkRol, 0, 'OUT := IN rotated left by N bits.');
  AddK(L, C_SHIFT, 'ROR', lkRor, 0, 'OUT := IN rotated right by N bits.');
  AddK(L, C_SHIFT, 'AND (word)', lkAndW, 0, 'OUT := IN1 AND IN2, bit by bit.');
  AddK(L, C_SHIFT, 'OR (word)', lkOrW, 0, 'OUT := IN1 OR IN2.');
  AddK(L, C_SHIFT, 'XOR (word)', lkXorW, 0, 'OUT := IN1 XOR IN2.');
  AddK(L, C_SHIFT, 'INV', lkInvW, 0, 'OUT := NOT IN: every bit inverted.');
  AddK(L, C_STR, 'CONCAT', lkConcat, 0, 'OUT := IN1 joined with IN2.');
  AddK(L, C_STR, 'LEN', lkLen, 0, 'OUT := the length of the string IN.');
  AddK(L, C_STR, 'LEFT', lkLeft, 0, 'OUT := the first L characters of IN.');
  AddK(L, C_STR, 'RIGHT', lkRight, 0, 'OUT := the last L characters of IN.');
  AddK(L, C_STR, 'MID', lkMid, 0, 'OUT := L characters of IN from the position P.');
  AddK(L, C_STR, 'FIND', lkFind, 0, 'OUT := the position of IN2 in IN1 (0: not there).');
  AddK(L, C_STR, 'S_MOVE', lkSMove, 0, 'OUT := IN: a string into another one.');
  AddK(L, C_CTRL, 'CALL', lkCall, 0, 'Calls an FC or an FB (its instance DB); the pins are its parameters.');
  Add(L, C_KEYS, 'Del / Ctrl+X / Ctrl+C / Ctrl+V', '', 'Delete, cut, copy, paste (inserts) the selected cells.');
  Add(L, C_KEYS, 'Shift+click, Shift+arrows', '', 'A selection of cells; Ctrl+A the network.');
  Add(L, C_KEYS, 'drag an element', '', 'Moves the cells (into another network too, onto wires).');
  Add(L, C_KEYS, 'Ctrl+Z / Ctrl+Y', '', 'Undo / redo.');
end;

procedure BuildStl(var L: TSclElems);
const
  NL = LineEnding;
  CUR = ElemCur;
  C_BIT = 'Bit logic';
  C_LOAD = 'Load / transfer / accumulators';
  C_TIMER = 'Timers (S5)';
  C_CNT = 'Counters (S5)';
  C_INT = 'Integer math';
  C_REAL = 'Real math';
  C_CMP = 'Comparison';
  C_CONV = 'Conversion';
  C_WORD = 'Word logic / shift / rotate';
  C_JUMP = 'Jumps';
  C_BLOCK = 'Blocks / calls';
  C_SCL = 'SCL functions (CALL)';
  C_SYS = 'System FBs (CALL)';
  C_KEYS = 'Editor keys';

  procedure M(const Cat, Mn, Descr: string; Opnd: Boolean = True);
  begin
    if Opnd then Add(L, Cat, Mn, Mn + ' ' + CUR, Descr) else Add(L, Cat, Mn, Mn, Descr);
  end;

  procedure Fn(const Name, Pins, Descr: string);
  var
    S, P: string;
    K: Integer;
    Pt: TStringArray;
  begin
    S := 'CALL ' + Name;
    Pt := Pins.Split(',');
    for K := 0 to High(Pt) do
    begin
      P := Trim(Pt[K]);
      if K = 0 then S := S + NL + '  ' + P + ' := ' + CUR else S := S + NL + '  ' + P + ' := ';
    end;
    Add(L, C_SCL, 'CALL ' + Name, S, Descr);
  end;

begin
  M(C_BIT, 'A', 'AND: the RLO := RLO AND the operand (the first check loads it).');
  M(C_BIT, 'AN', 'AND NOT.');
  M(C_BIT, 'O', 'OR.');
  M(C_BIT, 'ON', 'OR NOT.');
  M(C_BIT, 'X', 'Exclusive OR.');
  M(C_BIT, 'XN', 'Exclusive OR NOT.');
  M(C_BIT, 'A(', 'AND of a bracket: A( .. ).', False);
  M(C_BIT, 'O(', 'OR of a bracket.', False);
  M(C_BIT, ')', 'The end of a bracket.', False);
  M(C_BIT, 'O', 'OR (an empty O): AND before OR.', False);
  M(C_BIT, '=', 'Assignment: the operand := RLO.');
  M(C_BIT, 'S', 'Set the operand while RLO = 1.');
  M(C_BIT, 'R', 'Reset the operand (also a timer / counter).');
  M(C_BIT, 'NOT', 'Inverts the RLO.', False);
  M(C_BIT, 'SET', 'RLO := 1.', False);
  M(C_BIT, 'CLR', 'RLO := 0.', False);
  M(C_BIT, 'FP', 'A rising edge of the RLO (its edge memory bit as the operand).');
  M(C_BIT, 'FN', 'A falling edge of the RLO.');
  M(C_LOAD, 'L', 'Load the operand / a constant into ACCU 1 (ACCU 1 goes to ACCU 2).');
  M(C_LOAD, 'T', 'Transfer ACCU 1 into the operand.');
  M(C_LOAD, 'LC', 'Load a timer / counter value as BCD.');
  M(C_LOAD, 'OPN', 'Open a data block: OPN DB 1, then DBW2 ...');
  M(C_LOAD, 'TAK', 'Swap ACCU 1 and ACCU 2.', False);
  M(C_LOAD, 'PUSH', 'ACCU 1 -> ACCU 2 (-> 3 -> 4).', False);
  M(C_LOAD, 'POP', 'ACCU 2 -> ACCU 1.', False);
  M(C_LOAD, 'ENT', 'ACCU 3 -> 4, 2 -> 3 (S7-400).', False);
  M(C_LOAD, 'LEAVE', 'ACCU 3 -> 2, 4 -> 3 (S7-400).', False);
  M(C_LOAD, 'CAW', 'Swap the bytes of the low word of ACCU 1.', False);
  M(C_LOAD, 'CAD', 'Swap the four bytes of ACCU 1.', False);
  M(C_TIMER, 'SD', 'Start the timer T n as an on delay with the time value in ACCU 1 (L S5T#5S).');
  M(C_TIMER, 'SE', 'An extended pulse.');
  M(C_TIMER, 'SP', 'A pulse.');
  M(C_TIMER, 'SS', 'A retentive on delay.');
  M(C_TIMER, 'SF', 'An off delay.');
  M(C_CNT, 'CU', 'Count the counter C n up on a rising edge of the RLO.');
  M(C_CNT, 'CD', 'Count down.');
  M(C_INT, '+I', 'ACCU 2 + ACCU 1 (Int); also -I *I /I.', False);
  M(C_INT, '-I', 'ACCU 2 - ACCU 1 (Int).', False);
  M(C_INT, '*I', 'ACCU 2 * ACCU 1 (Int).', False);
  M(C_INT, '/I', 'ACCU 2 / ACCU 1 (Int).', False);
  M(C_INT, '+D', 'ACCU 2 + ACCU 1 (DInt); also -D *D /D.', False);
  M(C_INT, 'MOD', 'The remainder of /D.', False);
  M(C_INT, '+', 'ACCU 1 + a constant: + 5, + L#5.');
  M(C_INT, 'INC', 'Low byte of ACCU 1 + n.');
  M(C_INT, 'DEC', 'Low byte of ACCU 1 - n.');
  M(C_INT, 'NEGI', 'ACCU 1 := -ACCU 1 (Int); NEGD for DInt.', False);
  M(C_REAL, '+R', 'ACCU 2 + ACCU 1 (Real); also -R *R /R.', False);
  M(C_REAL, 'ABS', 'The absolute value of the Real in ACCU 1.', False);
  M(C_REAL, 'SQR', 'The square.', False);
  M(C_REAL, 'SQRT', 'The square root.', False);
  M(C_REAL, 'EXP', 'e to the power of ACCU 1.', False);
  M(C_REAL, 'LN', 'The natural logarithm.', False);
  M(C_REAL, 'SIN', 'The sine (rad); also COS TAN ASIN ACOS ATAN.', False);
  M(C_REAL, 'NEGR', 'ACCU 1 := -ACCU 1 (Real).', False);
  M(C_CMP, '==I', 'RLO := ACCU 2 = ACCU 1 (Int); also <>I >I <I >=I <=I, D for DInt, R for Real.', False);
  M(C_CMP, '>I', 'ACCU 2 > ACCU 1 (Int).', False);
  M(C_CMP, '<I', 'ACCU 2 < ACCU 1 (Int).', False);
  M(C_CMP, '==R', 'ACCU 2 = ACCU 1 (Real).', False);
  M(C_CONV, 'ITD', 'Int -> DInt.', False);
  M(C_CONV, 'DTR', 'DInt -> Real.', False);
  M(C_CONV, 'RND', 'Real -> DInt, to the nearest; also RND+ RND- TRUNC.', False);
  M(C_CONV, 'ITB', 'Int -> BCD; BTI, DTB, BTD.', False);
  M(C_CONV, 'INVI', 'The ones complement of the Int; INVD for DInt.', False);
  M(C_WORD, 'AW', 'ACCU 1 AND ACCU 2 (word) or AND a constant: AW W#16#00FF; also OW XOW, AD OD XOD.');
  M(C_WORD, 'OW', 'OR (word).');
  M(C_WORD, 'XOW', 'XOR (word).');
  M(C_WORD, 'SLW', 'Shift the low word left by n (or by ACCU 2); SRW SLD SRD, SSI SSD with the sign.');
  M(C_WORD, 'SRW', 'Shift right (word).');
  M(C_WORD, 'RLD', 'Rotate the double word left; RRD right.');
  M(C_JUMP, 'JU', 'Jump to a label (M001: ..).');
  M(C_JUMP, 'JC', 'Jump when RLO = 1; JCN when 0.');
  M(C_JUMP, 'JCN', 'Jump when RLO = 0.');
  M(C_JUMP, 'JZ', 'Jump when the result was 0; JN JP JM JPZ JMZ JUO, JO JOS.');
  M(C_JUMP, 'LOOP', 'Count the low word of ACCU 1 down, jump while it is not 0.');
  Add(L, C_JUMP, 'label:', CUR + 'M001: NOP 0', 'A label: up to 4 characters before the colon.');
  Add(L, C_BLOCK, 'CALL FC with parameters', 'CALL "' + CUR + 'FC"' + NL + '  In := ' + NL + '  Out := ',
    'Calls an FC: one parameter per line (Name := operand).');
  Add(L, C_BLOCK, 'CALL FB, instance DB', 'CALL "' + CUR + 'Inst_DB"' + NL + '  In := ',
    'Calls an FB with its instance (CALL FB1, DB10 also).');
  M(C_BLOCK, 'BE', 'Block end.', False);
  M(C_BLOCK, 'BEC', 'Block end when RLO = 1.', False);
  M(C_BLOCK, 'NOP 0', 'No operation.', False);
  Fn('SEL', 'G, IN0, IN1, RET_VAL', 'RET_VAL := IN1 when G, else IN0 (as SCL SEL).');
  Fn('MUX', 'K, IN0, IN1, IN2, RET_VAL', 'RET_VAL := the input number K.');
  Fn('LIMIT', 'MN, IN, MX, RET_VAL', 'RET_VAL := IN limited to MN .. MX.');
  Fn('MIN', 'IN1, IN2, RET_VAL', 'The smallest input (up to IN32).');
  Fn('MAX', 'IN1, IN2, RET_VAL', 'The largest input.');
  Fn('NORM_X', 'MIN, VALUE, MAX, RET_VAL', 'Normalize to 0.0 .. 1.0.');
  Fn('SCALE_X', 'MIN, VALUE, MAX, RET_VAL', 'Scale 0.0 .. 1.0 to MIN .. MAX.');
  Fn('SHL', 'IN, N, RET_VAL', 'Shift left.');
  Fn('ROL', 'IN, N, RET_VAL', 'Rotate left (also SHR, ROR).');
  Fn('CONCAT', 'IN1, IN2, RET_VAL', 'Join two strings.');
  Fn('LEN', 'IN, RET_VAL', 'The length of a string.');
  Fn('LEFT', 'IN, L, RET_VAL', 'The first L characters.');
  Fn('RIGHT', 'IN, L, RET_VAL', 'The last L characters.');
  Fn('MID', 'IN, L, P, RET_VAL', 'L characters from the position P.');
  Fn('FIND', 'IN1, IN2, RET_VAL', 'The position of IN2 in IN1.');
  Fn('S_MOVE', 'IN, RET_VAL', 'A string into another one.');
  Fn('INT_TO_REAL', 'IN, RET_VAL', 'Every X_TO_Y conversion of SCL: CALL REAL_TO_INT, DINT_TO_INT ...');
  Fn('READ_CLK', 'CDT, RET_VAL', 'The PLC clock into a Date_And_Time (SFC1).');
  Fn('SET_CLK', 'PDT, RET_VAL', 'The PLC clock set from a Date_And_Time (SFC0).');
  Fn('RD_LOC_T', 'OUT, RET_VAL', 'The local time into a DTL (S7-1500).');
  Fn('TIME_TCK', 'RET_VAL', 'The ms since the start of the CPU.');
  Add(L, C_SYS, 'CALL a TON_TIME', 'CALL #' + CUR + 'Delay' + NL + '  IN := ' + NL + '  PT := T#1S' + NL + '  Q := ',
    'A Static (or DB variable) of TON_TIME / TOF_TIME / TP_TIME / TONR_TIME / TON_LTIME: IN, PT, Q, ET.');
  Add(L, C_SYS, 'CALL a CTU_INT', 'CALL #' + CUR + 'Count' + NL + '  CU := ' + NL + '  R := ' + NL + '  PV := 10' + NL +
    '  CV := ', 'A counter of CTU_INT / CTD_INT / CTUD_INT / CTU_DINT ..: CU, CD, R, LD, PV, Q / QU / QD, CV.');
  Add(L, C_SYS, 'CALL an R_TRIG', 'CALL #' + CUR + 'Edge' + NL + '  CLK := ' + NL + '  Q := ',
    'R_TRIG / F_TRIG: CLK, Q.');
  Add(L, C_SYS, 'CALL an RS', 'CALL #' + CUR + 'Latch' + NL + '  S := ' + NL + '  R1 := ' + NL + '  Q1 := ',
    'RS (reset wins) / SR (S1, R; set wins): Q1.');
  Add(L, C_KEYS, 'Ctrl+Z / Ctrl+Y', '', 'Undo / redo.');
  Add(L, C_KEYS, 'Ctrl+D / Ctrl+L', '', 'Duplicate / delete the line.');
  Add(L, C_KEYS, 'Ctrl+Q', '', 'Comment / uncomment.');
  Add(L, C_KEYS, 'Ctrl+F / Ctrl+H / F3', '', 'Find / replace / the next.');
  Add(L, C_KEYS, 'Alt+Up / Ctrl+Click', '', 'Find the declaration of the name at the caret.');
end;

{ the project's own elements: LAD puts the name as the operand of the selected element (an FC: a CALL box) }
procedure AddProject(var L: TSclElems; P: TPlcProject; Cur: TBlock; Lad, Stl: Boolean);
var
  I, J: Integer;
  B: TBlock;
  D: TDataBlock;
begin
  if Cur <> nil then
    for I := 0 to High(Cur.Iface.Vars) do
      Add(L, ElemProject + 'this block', '#' + Cur.Iface.Vars[I].Name, '#' + Cur.Iface.Vars[I].Name,
        Format('%s : %s  (%s)  %s', [Cur.Iface.Vars[I].Name, Cur.Iface.Vars[I].TypeText,
        SectionNames[Cur.Iface.Vars[I].Section], Cur.Iface.Vars[I].Comment]));
  for I := 0 to High(P.Tags) do
    Add(L, ElemProject + 'PLC tags', '"' + P.Tags[I].Name + '"', '"' + P.Tags[I].Name + '"',
      Format('%s  %s : %s  %s', [P.Tags[I].Name, P.Tags[I].Address, P.Tags[I].TypeText, P.Tags[I].Comment]));
  for I := 0 to P.DBCount - 1 do
  begin
    D := P.DB(I);
    if D.InstanceOf > 0 then
    begin
      if Lad then
      begin
        AddK(L, ElemProject + 'Data blocks', Format('CALL "%s"', [D.Name]), lkCall, 0,
          Format('DB%d: the instance of FB%d - a CALL box with it.', [D.Number, D.InstanceOf]));
        L[High(L)].Snip := '"' + D.Name + '"';
      end
      else
        Add(L, ElemProject + 'Data blocks', Format('CALL "%s"', [D.Name]), Format('CALL "%s"', [D.Name]),
          Format('DB%d: the instance of FB%d - its call.', [D.Number, D.InstanceOf]));
      Continue;
    end;
    for J := 0 to High(D.Vars) do
      Add(L, ElemProject + 'Data blocks', Format('"%s".%s', [D.Name, D.Vars[J].Name]),
        Format('"%s".%s', [D.Name, D.Vars[J].Name]),
        Format('DB%d.%s : %s  %s', [D.Number, D.Vars[J].Name, D.Vars[J].TypeText, D.Vars[J].Comment]));
  end;
  for I := 0 to P.BlockCount - 1 do
  begin
    B := P.Block(I);
    if B.Kind <> bkFC then Continue;
    if Lad then
    begin
      AddK(L, ElemProject + 'Functions (FC)', Format('CALL "%s"', [B.Name]), lkCall, 0,
        Format('FC%d "%s": a CALL box with its parameters as pins. %s', [B.Number, B.Name, B.Comment]));
      L[High(L)].Snip := '"' + B.Name + '"';
    end
    else
      Add(L, ElemProject + 'Functions (FC)', Format('CALL "%s"', [B.Name]), Format('CALL "%s"', [B.Name]),
        Format('FC%d "%s": its call (one parameter per line). %s', [B.Number, B.Name, B.Comment]));
  end;
  if Stl then ;
end;

function LadElems(P: TPlcProject; Cur: TBlock): TSclElems;
begin
  Result := nil;
  if P <> nil then BuildLad(Result, P.Family) else BuildLad(Result, cfS71500);
  if P <> nil then AddProject(Result, P, Cur, True, False);
end;

function StlElems(P: TPlcProject; Cur: TBlock): TSclElems;
begin
  Result := nil;
  BuildStl(Result);
  if P <> nil then AddProject(Result, P, Cur, False, True);
end;

function SclStaticElems: TSclElems;
begin
  if Static = nil then Build(Static);
  Result := Static;
end;

{ "Name"(In := , Out => ) for the interface of a block }
function CallArgs(B: TBlock): string;
var
  I: Integer;
  First: Boolean;
begin
  Result := '';
  First := True;
  for I := 0 to High(B.Iface.Vars) do
    if B.Iface.Vars[I].Section in [vsInput, vsOutput, vsInOut] then
    begin
      if not First then Result := Result + ', ';
      Result := Result + B.Iface.Vars[I].Name;
      if B.Iface.Vars[I].Section = vsOutput then Result := Result + ' => ' else Result := Result + ' := ';
      if First then Result := Result + ElemCur;
      First := False;
    end;
end;

function SclElems(P: TPlcProject; Cur: TBlock): TSclElems;
var
  I, J: Integer;
  B: TBlock;
  D: TDataBlock;
  Ret, S: string;
begin
  Result := Copy(SclStaticElems);
  if P = nil then Exit;
  // the interface of the block being edited
  if Cur <> nil then
    for I := 0 to High(Cur.Iface.Vars) do
      Add(Result, ElemProject + 'this block', '#' + Cur.Iface.Vars[I].Name, '#' + Cur.Iface.Vars[I].Name,
        Format('%s : %s  (%s)  %s', [Cur.Iface.Vars[I].Name, Cur.Iface.Vars[I].TypeText,
        SectionNames[Cur.Iface.Vars[I].Section], Cur.Iface.Vars[I].Comment]));
  for I := 0 to High(P.Tags) do
    Add(Result, ElemProject + 'PLC tags', '"' + P.Tags[I].Name + '"', '"' + P.Tags[I].Name + '"',
      Format('%s  %s : %s  %s', [P.Tags[I].Name, P.Tags[I].Address, P.Tags[I].TypeText, P.Tags[I].Comment]));
  for I := 0 to P.DBCount - 1 do
  begin
    D := P.DB(I);
    if D.InstanceOf > 0 then
    begin
      B := P.InstanceFB(D);
      if B <> nil then
        Add(Result, ElemProject + 'Data blocks', Format('"%s"(..)', [D.Name]), Format('"%s"(%s);', [D.Name, CallArgs(B)]),
          Format('DB%d: the instance of FB%d "%s" - its call.', [D.Number, B.Number, B.Name]));
      Continue;
    end;
    for J := 0 to High(D.Vars) do
      Add(Result, ElemProject + 'Data blocks', Format('"%s".%s', [D.Name, D.Vars[J].Name]),
        Format('"%s".%s', [D.Name, D.Vars[J].Name]),
        Format('DB%d.%s : %s  %s', [D.Number, D.Vars[J].Name, D.Vars[J].TypeText, D.Vars[J].Comment]));
  end;
  for I := 0 to P.BlockCount - 1 do
  begin
    B := P.Block(I);
    if B.Kind = bkFC then
    begin
      Ret := '';
      for J := 0 to High(B.Iface.Vars) do
        if B.Iface.Vars[J].Section = vsReturn then Ret := B.Iface.Vars[J].TypeText;
      if Ret <> '' then S := Format('%s := "%s"(%s);', [ElemCur, B.Name, CallArgs(B)])
      else S := Format('"%s"(%s);', [B.Name, CallArgs(B)]);
      if Ret <> '' then Ret := ', returns ' + Ret;
      Add(Result, ElemProject + 'Functions (FC)', Format('"%s"(..)', [B.Name]), S,
        Format('FC%d "%s"%s. %s', [B.Number, B.Name, Ret, B.Comment]));
    end
    else if B.Kind = bkFB then
      Add(Result, ElemProject + 'Function blocks (FB)', Format('"%s"', [B.Name]), Format('"%s"', [B.Name]),
        Format('FB%d "%s": a type for a Static (a multi-instance), called as #name(%s). %s',
        [B.Number, B.Name, ElemText(CallArgs(B)), B.Comment]));
  end;
  for I := 0 to P.Udts.Count - 1 do
    Add(Result, ElemProject + 'PLC data types', '"' + TDataBlock(P.Udts[I]).Name + '"',
      '"' + TDataBlock(P.Udts[I]).Name + '"', Format('A PLC data type with %d members.',
      [Length(TDataBlock(P.Udts[I]).Vars)]));
end;

end.
