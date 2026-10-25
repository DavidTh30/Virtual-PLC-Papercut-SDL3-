unit uElemHelp;

{ The help of the elements panel of the program editor (SCL, STL, LAD): for every element a page with what
  it does, its syntax, its parameters, how it is used step by step, pictures (a LAD rung drawn by the
  editor itself, a timing diagram, a truth / value table, the bits of a word, a flowchart) and an example.
  The page is data: the program editor lays its blocks out from the top. The functions that the three
  languages share (the timers, MIN, LIMIT, SHL, the strings ..) are written once.

  The data of the pictures ('\' starts a new line in every one):
    hbTable  rows of cells split by '|'; the first row is the head
    hbLad    rows of cells split by ';': '' empty, '-' a wire, else 'id[@Type][>Type2][=op] operand|p0|p1..'
             (id: LadKindIds, the pins in the order of LadParamName) and '!' at the end: a branch line down
    hbWave   a signal per line: 'Name=0011100' (a bit per step) or 'Name~0,1,2,3' (a value per step);
             '^Text:a-b' marks the steps a .. b of the signal above it
    hbBits   'Label=0101..' (16 or 32 bits, the most significant first; 'o' / 'i' a 0 / 1 marked red)
    hbFlow   'kind|text|text..': if, ifelse, elsif, case, loop (FOR / WHILE), repeat, exit, continue, jump
    hbMem    the bytes of a DB per line: 'Label=name:bytes:kind|..' (kind v a variable, b a Bool, p a gap);
             a label that starts with '!' has no offsets (an optimized DB) }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Math, StrUtils, uPlcTypes, uPlcProject, uSclElems, uFbd;

type
  THelpBlockKind = (hbHead, hbText, hbStep, hbBullet, hbCode, hbTable, hbLad, hbWave, hbBits, hbFlow,
    hbCaption, hbNote, hbFbd, hbCfc, hbMem);
  THelpBlock = record
    K: THelpBlockKind;
    S: string;
  end;
  TElemHelpPage = record
    Title, Sub: string;      // the element, 'SCL  ·  Timers'
    Blocks: array of THelpBlock;
    Example: string;         // the example as code for the editor (SCL / STL; '' none)
  end;

{ the help page of an element of the panel: Lang 'C' SCL, 'S' STL, 'L' LAD }
function ElemHelpPage(Lang: Char; const E: TSclElem; Fam: TCpuFamily): TElemHelpPage;
{ the page as text (Copy, the test) }
function ElemHelpText(const P: TElemHelpPage): string;
{ the help of the Retain column of the Data blocks screen (Fam: the CPU family of the project) }
function RetainHelpPage(Fam: TCpuFamily): TElemHelpPage;
{ the help of the button Optimized DB of the Data blocks screen }
function OptimizedHelpPage(Fam: TCpuFamily): TElemHelpPage;
function LangTitle(Lang: Char): string;
{ the network of a LAD picture (hbLad); the caller frees it. HelpLadErr: the ids that are not known }
function HelpLadNet(const S: string): TNetwork;

var
  HelpLadErr: string;

implementation

var
  Pg: TElemHelpPage;
  Lg: Char;
  Fm: TCpuFamily;
  { a picture that FnPage puts after its values (the bits of a shift ..) }
  XHead, XBits, XCap: string;

function LangTitle(Lang: Char): string;
begin
  case Lang of
    'L': Result := 'LAD';
    'S': Result := 'STL';
    'F': Result := 'FBD';
    'K': Result := 'CFC';
  else
    Result := 'SCL';
  end;
end;

{ ---------- the blocks of the page ---------- }

function NL(const S: string): string;
begin
  Result := StringReplace(S, '\', LineEnding, [rfReplaceAll]);
end;

{ FBD / CFC: the text written for LAD in the words of boxes and pins }
function Fx(const S: string): string;
const
  Pairs: array[0..21, 0..1] of string = (
    ('EN is the rung on its left, ENO the power out (ENO = EN; FALSE when the result is invalid)',
     'EN on its left: the box runs while it is TRUE (empty: always)'),
    ('Put the condition contact (or nothing: the box runs always), then the box on the next cell.',
     'Select the input pin the box feeds (or nothing: a new box), then double click the box in the list.'),
    ('Put a contact (the start condition) in front of it, then the box on the next cell; it takes two cells.',
     'Select the pin it feeds (or nothing: a new box), then double click the box; type or wire its IN.'),
    ('Put the counting contact (often a P contact or a sensor), then the box on the next cell.',
     'Double click the box; its CU: an operand (often a sensor) or the output of another box.'),
    ('Put the signal contact, then the box; type the instance above it', 'Double click the box, type the instance above it'),
    ('Click the box: type the inputs and the output in the properties panel on the right; choose the data type there.',
     'Type the operands at its pins (or wire boxes into them); the data type: a click on the type under the title.'),
    ('Click the box: type the instance above it and the pins in the properties panel.',
     'Type the instance in the field above the box and the operands at its pins.'),
    ('Click the box: type the instance above it', 'Type the instance in the field above the box'),
    ('in the properties panel on the right', 'at its pins'),
    ('in the properties panel', 'at its pins'),
    ('Put a coil behind the box: it gets Q.', 'Select the box and double click = : the assignment gets Q.'),
    ('Put it on the rung like a contact, then the coil.', 'Double click it; select it and double click = for the output.'),
    ('Put it on the rung like a contact; type MIN, VAL and MAX.', 'Double click it; type MIN, VAL and MAX at its pins.'),
    ('Put a CALL on the rung, then type the FC name or the instance DB above it', 'Double click CALL, type the FC or the instance DB above it'),
    ('a box on the rung: ', 'a box: '),
    ('a box like a contact: IN1 above, IN2 below; the operator and the type in it',
     'a box: IN1 and IN2 on its left, Q on its right; the operator and the type in its title'),
    ('is the rung on its left', 'is its first input (an operand, or the output of another box)'),
    ('the power out on its right', 'the output on its right'),
    ('the power out', 'the output'),
    (' (the rung)', ''),
    ('the rung', 'the input'),
    ('a P contact in front of it', 'a P box before its EN'));
  More: array[0..10, 0..1] of string = (
    ('while EN has power', 'while EN is TRUE'),
    ('use a P contact in front of it', 'use a P box before EN'),
    ('while the power is on', 'while EN is TRUE'),
    ('put a P contact in front', 'put a P box before EN'),
    ('A contact box: the power goes through when', 'A box: Q is TRUE when'),
    ('A comparison contact: the power goes through when', 'A comparison box: Q is TRUE when'),
    ('the power goes on', 'Q is TRUE'),
    ('the output: the power on the right of the box', 'the output of the box'),
    ('|power', '|Q'),
    ('power in|power out', 'IN|Q'),
    ('Without power the target', 'While EN is FALSE the target'));
var
  K: Integer;
begin
  Result := S;
  if not (Lg in ['F', 'K']) then Exit;
  for K := 0 to High(More) do Result := StringReplace(Result, More[K, 0], More[K, 1], [rfReplaceAll]);
  for K := 0 to High(Pairs) do Result := StringReplace(Result, Pairs[K, 0], Pairs[K, 1], [rfReplaceAll]);
end;

procedure Add(K: THelpBlockKind; const S: string);
var
  N: Integer;
begin
  N := Length(Pg.Blocks);
  SetLength(Pg.Blocks, N + 1);
  Pg.Blocks[N].K := K;
  Pg.Blocks[N].S := S;
end;

procedure Head(const S: string);
begin
  Add(hbHead, S);
end;

procedure Txt(const S: string);
begin
  Add(hbText, Fx(S));
end;

procedure Step(const S: string);
begin
  Add(hbStep, Fx(S));
end;

procedure Bul(const S: string);
begin
  Add(hbBullet, Fx(S));
end;

procedure Note(const S: string);
begin
  Add(hbNote, S);
end;

procedure Code(const S: string);
begin
  Add(hbCode, NL(S));
end;

procedure Tab(const S: string);
begin
  Add(hbTable, NL(Fx(S)));
end;

procedure Pic(K: THelpBlockKind; const S, Cap: string);
begin
  Add(K, NL(S));
  if Cap <> '' then Add(hbCaption, Cap);
end;

procedure Lad(const S, Cap: string);
begin
  // FBD / CFC: the same rung as boxes (converted when the page is shown)
  case Lg of
    'F': Pic(hbFbd, S, Cap);
    'K': Pic(hbCfc, S, Cap);
  else
    Pic(hbLad, S, Cap);
  end;
end;

procedure Wave(const S, Cap: string);
begin
  Pic(hbWave, S, Cap);
end;

procedure Bits(const S, Cap: string);
begin
  Pic(hbBits, S, Cap);
end;

procedure Mem(const S, Cap: string);
begin
  Pic(hbMem, S, Cap);
end;

procedure Flow(const S, Cap: string);
begin
  Add(hbFlow, S);
  if Cap <> '' then Add(hbCaption, Cap);
end;

{ the example: shown as code, and what "Insert example" puts into the editor }
procedure Example(const S, What: string);
begin
  Head('Example');
  if What <> '' then Txt(What);
  Code(S);
  if Pg.Example = '' then Pg.Example := NL(S);
end;

procedure Summary(const S: string);
begin
  Head('What it does');
  Txt(S);
end;

procedure Syntax(const S: string);
begin
  Head('Syntax');
  Code(Fx(S));
end;

procedure Params(const Rows: string);
begin
  Head('Parameters');
  Tab('Name|Data type|Meaning\' + Rows);
end;

{ how it is used: the steps of the language, the ones of the element in between }
procedure HowTo(const Extra: array of string);
var
  K: Integer;
begin
  Head('How to use it');
  case Lg of
    'F':
      begin
        Step('Click a pin of a box in the FBD network (it gets a red frame) where the new box goes: its output feeds that ' +
          'pin. A box selected (no pin): the new box comes after it and reads its output. Nothing selected: a new box ' +
          '(a new tree below the others).');
        Step('Double click the box in this list, or drag it by its grip onto a pin.');
      end;
    'K':
      begin
        Step('Double click the block in this list: it goes onto the chart (beside the selected block), or drag it by its ' +
          'grip onto the chart where it goes.');
        Step('Wire it: drag from an output pin to an input pin of another block. Move it by its title; the number in ' +
          'its title is its place in the run order (the data flow decides, Run earlier / later between free blocks).');
      end;
    'L':
      begin
        Step('Click the cell of the LAD network where the element goes (the cell gets a gold frame). A contact goes ' +
          'on the rung from the left, a coil or a box after the contacts that switch it.');
        Step('Double click the element in this list, or drag it by its grip (the dots) onto a cell (a wire or an ' +
          'empty cell). Several cells: Shift+click; a new row: + Row below the panel.');
      end;
    'S':
      begin
        Step('Click into an STL network at the line where the instruction goes (the caret). One instruction per line.');
        Step('Double click the element in this list, drag it by its grip into the code, or right button: Insert at ' +
          'the caret.');
      end;
  else
    begin
      Step('Click into an SCL network at the place where the code goes (the caret).');
      Step('Double click the element in this list, drag it by its grip into the code, or right button: Insert at ' +
        'the caret. The caret lands where the first thing has to be typed.');
    end;
  end;
  for K := 0 to High(Extra) do Step(Extra[K]);
  if Lg in ['F', 'K'] then
    Step('Compile (F7), download (F8) and RUN (F5). Monitor (F9) shows the value at every pin; a TRUE wire is red.')
  else if Lg = 'L' then
    Step('Compile (F7), download (F8) and RUN (F5). Monitor (F9) draws the power flow in red and the values at the ' +
      'pins.')
  else
    Step('Compile (F7), download (F8) and RUN (F5). Monitor (F9) shows the value of every line beside the code.');
end;

procedure Notes(const N: array of string);
var
  K: Integer;
begin
  if Length(N) = 0 then Exit;
  Head('Good to know');
  for K := 0 to High(N) do Bul(N[K]);
end;

{ ---------- values for the tables ---------- }

function FStr(V: Double): string;
var
  Fs: TFormatSettings;
begin
  Fs := DefaultFormatSettings;
  Fs.DecimalSeparator := '.';
  if IsNan(V) then Exit('NaN (invalid: ENO = FALSE)');
  if IsInfinite(V) then Exit('Inf (invalid: ENO = FALSE)');
  Result := FloatToStrF(V, ffGeneral, 7, 0, Fs);
  if (Pos('.', Result) = 0) and (Pos('E', Result) = 0) then Result := Result + '.0';
end;

{ the bits of V (W bits); the bits From .. To (0 = the least significant) marked }
function BinMark(V: QWord; W, From, ToB: Integer): string;
var
  K: Integer;
  B: Boolean;
begin
  Result := '';
  for K := W - 1 downto 0 do
  begin
    B := (V shr K) and 1 = 1;
    if (K >= From) and (K <= ToB) then
    begin
      if B then Result := Result + 'i' else Result := Result + 'o';
    end
    else if B then Result := Result + '1'
    else Result := Result + '0';
  end;
end;

function Hex4(V: QWord): string;
begin
  Result := '16#' + IntToHex(V and $FFFF, 4);
end;

procedure ClockPage(const Name: string); forward;

{ ---------- the timers, counters, edges: all three languages ---------- }

procedure TimerPage(const Name: string);
var
  Ty, Inst, Pins: string;
  R: Boolean;
begin
  R := Name = 'TONR';
  Ty := Name + '_TIME';
  Inst := '#' + Name + '_Instance';
  if Name = 'TON' then
    Summary('On delay. When IN becomes TRUE the timer starts; Q becomes TRUE when IN has stayed TRUE for the time PT. ' +
      'When IN goes FALSE, Q and the elapsed time ET go back to 0 at once. A pulse on IN shorter than PT does nothing. ' +
      'Typical: a motor that starts only after the start button was held for 2 s, a filter for a bouncing sensor.')
  else if Name = 'TOF' then
    Summary('Off delay. Q follows IN to TRUE at once; when IN goes FALSE, Q stays TRUE for the time PT and goes FALSE ' +
      'after it. IN TRUE again before PT ends restarts it (Q stays TRUE). Typical: a fan that runs on for 30 s after ' +
      'the heater is off, a light that stays on after the last movement.')
  else if Name = 'TP' then
    Summary('Pulse. A rising edge of IN starts a pulse of the length PT on Q. The pulse runs to its end even when IN ' +
      'goes FALSE early, and a new edge during the pulse does not restart it. Typical: a horn for exactly 3 s, a ' +
      'fixed pulse for a counter or a valve.')
  else
    Summary('Retentive on delay (time accumulator, S7-1200/1500). While IN is TRUE the time adds up in ET; when IN ' +
      'goes FALSE, ET stays (it is not reset). Q becomes TRUE when ET reaches PT. Only R resets ET and Q. Typical: the ' +
      'running hours of a pump, a maintenance interval.');
  if R then Pins := 'IN|Bool|the input: the time runs while it is TRUE\R|Bool|reset: ET := 0, Q := FALSE\'
  else Pins := 'IN|Bool|the start input\';
  case Lg of
    'L', 'F', 'K':
      begin
        Syntax(Format('a box on the rung: IN is the rung on its left, Q the power out on its right.\' +
          'Above the box: its instance (%s or IEC_TIMER).\PT, %sET: the pins on its left / right.',
          [Ty, IfThen(R, 'R, ', '')]));
        Params(Pins + 'PT|Time|the preset time: T#2S, T#500MS, T#1M30S or a Time variable\Q|Bool|the output: the ' +
          'power on the right of the box\ET|Time|the elapsed time (0 .. PT)\instance|' + Ty + ' / IEC_TIMER|its memory: ' +
          'a Static of the FB, a DB variable, or a single instance DB');
        HowTo(['Put a contact (the start condition) in front of it, then the box on the next cell; it takes two cells.',
          'Click the box: type the instance above it (#Delay, "Timers".Delay) and the pins PT' + IfThen(R, ', R', '') +
          ', ET in the properties panel on the right.',
          'Declare the instance first: in an FB the interface row Static Delay : ' + Ty +
          ', or a DB variable Delay : IEC_TIMER.',
          'Put a coil behind the box: it gets Q.']);
        if R then
          Lad('no "Pump_On";tonr #RunTime|T#10H|"Reset_Hours"|#Hours;-;coil "Service_Due"', 'the time adds up while the pump runs')
        else
          Lad('no "Start_PB";' + LowerCase(Name) + ' #Delay|T#2S|#Delay_ET;-;coil "Motor"', Format('"Motor" from Q of the %s', [Name]));
        Txt('The same in SCL:');
        if R then Code('#RunTime.TONR(IN := "Pump_On", R := "Reset_Hours", PT := T#10H);\"Service_Due" := #RunTime.Q;')
        else Code('#Delay(IN := "Start_PB", PT := T#2S);\"Motor" := #Delay.Q;');
      end;
    'S':
      begin
        Syntax(Format('CALL #%s_Instance\  IN := ..\%s  PT := T#2S\  Q  := ..\  ET := ..', [Name, IfThen(R, '  R  := ..\', '')]));
        Params(Pins + 'PT|Time|the preset time\Q|Bool|the output\ET|Time|the elapsed time');
        HowTo(['Declare the instance as a Static of the FB (Delay : ' + Ty + ') or as a DB variable.',
          'Write one parameter per line under the CALL: Name := operand. Q and ET may stay out.']);
      end;
  else
    begin
      Syntax(Format('%s(IN := .., %sPT := ..);\.. := %s.Q;    .. := %s.ET;', [Inst, IfThen(R, 'R := .., ', ''), Inst, Inst]));
      Params(Pins + 'PT|Time|the preset time: T#2S, T#500MS or a Time variable\.Q|Bool|the output (read after the call)\' +
        '.ET|Time|the elapsed time (0 .. PT)');
      HowTo(['Declare the instance: in the interface of the FB a row Static ' + Name + '_Instance : ' + Ty +
        ' (or in a global DB: Timer : IEC_TIMER, then "DB".Timer.' + Name + '(..)).',
        'Fill in IN (a condition) and PT. Call the timer in every cycle (not only inside an IF that may not run).',
        'Use .Q (and .ET) after the call.']);
    end;
  end;
  Head('Timing diagram');
  if Name = 'TON' then
    Wave('IN=0111111000110000\^PT:1-4\Q=0000111000000000\ET~0,1,2,3,3,3,3,0,0,1,2,0,0,0,0,0',
      'PT = 3 steps: Q after IN was TRUE for PT; the second pulse is shorter than PT: no Q')
  else if Name = 'TOF' then
    Wave('IN=0111100000110000\Q=0111111100111110\^PT:5-8\ET~0,0,0,0,0,1,2,3,3,3,0,0,1,2,3,3',
      'PT = 3 steps: Q stays TRUE for PT after IN went FALSE')
  else if Name = 'TP' then
    Wave('IN=0110000011111110\Q=0111100011110000\^PT:1-5\ET~0,1,2,3,4,0,0,0,1,2,3,4,4,4,4,0',
      'PT = 4 steps: the pulse always lasts PT, how long IN stays TRUE does not matter')
  else
    Wave('IN=0111000111100000\R=0000000000000110\Q=0000000111111000\ET~0,1,2,3,3,3,3,4,4,4,4,4,4,0,0,0',
      'PT = 4 steps: ET adds the times while IN is TRUE; R resets it');
  if Lg = 'S' then
    Example(Format('CALL #Delay\  IN := "Start_PB"\%s  PT := T#2S\  Q  := "Motor"', [IfThen(R, '  R  := "Reset_Hours"\', '')]),
      'Declare Delay : ' + Ty + ' as a Static of the FB first.')
  else if Lg = 'C' then
  begin
    if Name = 'TON' then
      Example('// Static: Delay : TON_TIME\#Delay(IN := "Start_PB", PT := T#2S);\"Motor" := #Delay.Q;\"Remaining" := T#2S - #Delay.ET;',
        'The motor starts 2 s after the start button; the time left is shown on the HMI.')
    else if Name = 'TOF' then
      Example('// Static: RunOn : TOF_TIME\#RunOn(IN := "Heater_On", PT := T#30S);\"Fan" := #RunOn.Q;',
        'The fan runs with the heater and 30 s longer.')
    else if Name = 'TP' then
      Example('// Static: Horn : TP_TIME, Edge : R_TRIG\#Edge(CLK := "Alarm");\#Horn(IN := #Edge.Q, PT := T#3S);\"Horn_Out" := #Horn.Q;',
        'A horn for exactly 3 s on every new alarm.')
    else
      Example('// Static: Hours : TONR_TIME\#Hours(IN := "Pump_On", R := "Reset_Hours", PT := T#100H);\"Service_Due" := #Hours.Q;',
        'After 100 running hours of the pump "Service_Due" comes; "Reset_Hours" sets it back.');
  end;
  Notes(['Every timer needs its own instance; two calls of the same instance disturb each other.',
    'PT of a TIME is at most T#24D20H31M23S647MS; TON_LTIME / TOF_LTIME .. take LTime (LT#, S7-1500).',
    'The timer runs on the CPU time: it is exact even when the cycle is slow, but Q only changes when the timer is ' +
    'called.',
    'In the Watch table "DB".Timer.ET / .Q show the timer; the instance can be dragged there.']);
end;

procedure S5TimerPage(const Name: string);
var
  Sum, W, Cap, Lk, Fn: string;
begin
  if Name = 'SD' then
  begin
    Sum := 'S5 on delay (S_ODT). Q becomes TRUE when the start input has stayed TRUE for the time value; it goes FALSE ' +
      'with the start input. As TON, with the S5 timers T0 .. T255 of the S7-300/400.';
    W := 'S=0111111000110000\Q=0000111000000000';
    Cap := 'time value = 3 steps';
  end
  else if Name = 'SE' then
  begin
    Sum := 'S5 extended pulse (S_PEXT). A rising edge starts a pulse of the time value; the pulse runs to its end ' +
      'even when the start input goes FALSE, a new edge starts it again.';
    W := 'S=0100000011000000\Q=0111000011100000';
    Cap := 'time value = 3 steps';
  end
  else if Name = 'SP' then
  begin
    Sum := 'S5 pulse (S_PULSE). Q is TRUE while the start input is TRUE, at most for the time value: the pulse ends ' +
      'early when the input goes FALSE.';
    W := 'S=0111111001000000\Q=0111000001000000';
    Cap := 'time value = 3 steps: the second pulse ends with the input';
  end
  else if Name = 'SS' then
  begin
    Sum := 'S5 retentive on delay (S_ODTS). A rising edge starts the time, which runs to its end even when the input ' +
      'goes FALSE; then Q stays TRUE until the timer is reset (R).';
    W := 'S=0100000000000000\R=0000000000110000\Q=0000111111000000';
    Cap := 'time value = 3 steps: Q stays until R';
  end
  else
  begin
    Sum := 'S5 off delay (S_OFFDT). Q follows the input to TRUE; when the input goes FALSE, Q stays TRUE for the ' +
      'time value.';
    W := 'S=0111100000000000\Q=0111111100000000';
    Cap := 'time value = 3 steps';
  end;
  Summary(Sum);
  Lk := LowerCase(Name);
  if Lg in ['F', 'K'] then
  begin
    // the box S_ODT .. with the timer above it
    case Name of
      'SD': Fn := 'S_ODT';
      'SE': Fn := 'S_PEXT';
      'SP': Fn := 'S_PULSE';
      'SS': Fn := 'S_ODTS';
    else
      Fn := 'S_OFFDT';
    end;
    Syntax('a box ' + Fn + ': the timer above it (T1); S (the start), TV (the time value S5T#..) and R on its left; Q ' +
      '(the timer bit) and BI (the time left, binary) on its right');
    Params('timer|Timer|above the box: T0 .. T255\S|Bool|start\TV|S5Time|S5T#2S (at most S5T#2H46M30S) or a word in BCD\' +
      'R|Bool|reset (optional)\Q|Bool|the timer bit\BI|Word|the time left (binary)');
    HowTo(['Double click the box, type the timer above it (T1), the start at S and the time at TV.',
      'Its Q goes on: select the box and double click = (or wire it to another box).']);
    Lad('no "Start";' + Lk + ' T1|S5T#2S;-;-\no T1;coil "Motor"', 'the S5 timer and its bit');
    Txt('The same in SCL:');
    Code(Fn + '(T_NO := T1, S := "Start", TV := S5T#2S, Q => "Motor");');
    Head('Timing diagram');
    Wave(W, Cap);
    Notes(['The S5 timers exist on the S7-300/400/1500; on an S7-1200 use TON / TOF / TP.',
      'A timer is a global resource: two places that start T1 disturb each other.']);
    Exit;
  end;
  if Lg = 'L' then
  begin
    Syntax('a coil (' + Name + ') with the timer as its operand (T1) and the time value (S5T#..) below it.\The timer bit ' +
      'is read with a contact: -| |- T1.');
    Params('operand|Timer|the S5 timer: T0 .. T255\time value|S5Time|S5T#2S, S5T#500MS (at most S5T#2H46M30S), or a ' +
      'word with the value in BCD\T n (contact)|Bool|the timer bit: Q\R (a reset coil)|-|-(R)- T1 resets the timer');
    HowTo(['Put the start condition, then the ' + Name + ' coil on the next cell.',
      'Type the timer (T1) above the coil and the time value below it.',
      'In another rung read the timer: a contact -| |- T1, then the coil of the output.']);
    Lad('no "Start_PB";' + Lk + ' T1|S5T#2S\no T1;coil "Motor"', 'rung 1 starts T1, rung 2 reads it');
    Txt('The same in STL:');
    Code('A     "Start_PB"\L     S5T#2S\' + Name + '    T 1\A     T 1\=     "Motor"');
  end
  else
  begin
    Syntax('A     <start condition>\L     S5T#2S        // the time value into ACCU 1\' + Name +
      '    T 1           // start the timer with the RLO\A     T 1           // the timer bit');
    Params('T n|Timer|the timer: T 0 .. T 255\ACCU 1|S5Time|the time value: L S5T#2S before the start\RLO|Bool|the start ' +
      'condition');
    HowTo(['Write the start condition (A ..), then L S5T#.. and the start instruction ' + Name + ' T n.',
      'Read the timer later with A T n (or L T n: the time left, LC T n as BCD); R T n resets it.']);
    Example('A     "Start_PB"\L     S5T#2S\' + Name + '    T 1\A     T 1\=     "Motor"', 'T1 as an ' + Sum[1] + ' timer.');
  end;
  Head('Timing diagram');
  Wave(W, Cap);
  Notes(['The S5 timers exist on the S7-300/400 only; on an S7-1200/1500 use TON / TOF / TP.',
    'S5Time has a time base (10 ms .. 10 s): the larger the time, the coarser it is.',
    'A timer is a global resource: two places that start T1 disturb each other.']);
end;

procedure CounterPage(const Name: string);
var
  Inst: string;
begin
  Inst := '#' + Name + '_Instance';
  if Name = 'CTU' then
    Summary('Count up. Every rising edge of CU adds 1 to the counter value CV. Q is TRUE while CV >= PV. R = TRUE sets ' +
      'CV to 0. Typical: count boxes on a conveyor and stop after 10.')
  else if Name = 'CTD' then
    Summary('Count down. LD = TRUE loads CV with PV; every rising edge of CD subtracts 1. Q is TRUE while CV <= 0. ' +
      'Typical: the parts left in a magazine.')
  else
    Summary('Count up and down. A rising edge of CU adds 1, of CD subtracts 1. R sets CV to 0 (it wins), LD loads PV. ' +
      'QU is TRUE while CV >= PV, QD while CV <= 0. Typical: the cars in a parking garage (in / out).');
  case Lg of
    'L', 'F', 'K':
      begin
        if Name = 'CTU' then
          Syntax('a box: CU is the rung on its left, Q the power out.\Above: the instance (CTU_INT, IEC_COUNTER).\PV, R, CV: ' +
            'the pins.')
        else if Name = 'CTD' then
          Syntax('a box: CD is the rung, Q the power out.\PV, LD, CV: the pins.')
        else
          Syntax('a box: CU is the rung, QU the power out.\PV, CD, R, LD, CV: the pins.');
        HowTo(['Put the counting contact (often a P contact or a sensor), then the box on the next cell.',
          'Click the box: type the instance above it and the pins in the properties panel.',
          'Declare the instance: Static Count : ' + Name + '_INT (or IEC_COUNTER) in the FB, or a DB variable.']);
        if Name = 'CTU' then Lad('no "Box_Sensor";ctu #Count|10|"Reset_PB"|#Boxes;-;coil "Full"', '10 boxes: "Full"')
        else if Name = 'CTD' then Lad('no "Part_Out";ctd #Left|20|"Refill"|#Parts;-;coil "Empty"', 'empty after 20 parts')
        else Lad('no "Car_In";ctud #Cars|50|"Car_Out"|"Reset"||#Count;-;coil "Garage_Full"', 'cars in and out');
      end;
    'S':
      begin
        Syntax('CALL #' + Name + '_Instance\  CU := ..\  R  := ..\  PV := 10\  Q  := ..\  CV := ..');
        HowTo(['Declare the instance as a Static (Count : ' + Name + '_INT) or a DB variable.',
          'One parameter per line under the CALL; the outputs may stay out.']);
      end;
  else
    begin
      if Name = 'CTU' then Syntax(Inst + '(CU := .., R := .., PV := 10);\.. := ' + Inst + '.Q;   .. := ' + Inst + '.CV;')
      else if Name = 'CTD' then Syntax(Inst + '(CD := .., LD := .., PV := 10);\.. := ' + Inst + '.Q;')
      else Syntax(Inst + '(CU := .., CD := .., R := .., LD := .., PV := 10);\.. := ' + Inst + '.QU;   .. := ' + Inst + '.QD;');
      HowTo(['Declare the instance: Static ' + Name + '_Instance : ' + Name + '_INT in the FB interface (or in a DB: Counter : ' +
        'IEC_COUNTER, then "DB".Counter.' + Name + '(..)).',
        'Fill in the inputs; the counter counts the rising edges itself, no R_TRIG is needed.',
        'Read .Q / .CV after the call.']);
    end;
  end;
  if Name = 'CTU' then
    Params('CU|Bool|count up on a rising edge\R|Bool|reset: CV := 0\PV|Int|the preset value\Q|Bool|CV >= PV\CV|Int|the counter value')
  else if Name = 'CTD' then
    Params('CD|Bool|count down on a rising edge\LD|Bool|load: CV := PV\PV|Int|the preset value\Q|Bool|CV <= 0\CV|Int|the counter value')
  else
    Params('CU|Bool|count up\CD|Bool|count down\R|Bool|reset: CV := 0\LD|Bool|load: CV := PV\PV|Int|the preset value\QU|Bool|CV >= PV\' +
      'QD|Bool|CV <= 0\CV|Int|the counter value');
  Head('Timing diagram');
  if Name = 'CTU' then
    Wave('CU=0101010101000000\R=0000000000001100\CV~0,1,1,2,2,3,3,4,4,5,5,5,0,0,0,0\Q=0000011111110000',
      'PV = 3: Q from the third edge on, R sets CV back to 0')
  else if Name = 'CTD' then
    Wave('LD=0110000000000000\CD=0001010100000000\CV~0,3,3,2,2,1,1,0,0,0,0,0,0,0,0,0\Q=1000000111111111',
      'PV = 3: LD loads 3, every edge of CD counts down, Q at CV <= 0')
  else
    Wave('CU=0101010000000000\CD=0000000101000000\CV~0,1,1,2,2,3,3,2,2,1,1,1,1,1,1,1\QU=0000011000000000\QD=1000000000000000',
      'PV = 3: up three times, down twice');
  if Lg = 'C' then
  begin
    if Name = 'CTU' then
      Example('// Static: Count : CTU_INT\#Count(CU := "Box_Sensor", R := "Reset_PB", PV := 10);\"Full" := #Count.Q;\"Boxes" := #Count.CV;',
        'Counts the boxes; at 10 "Full" comes, the reset button starts again.')
    else if Name = 'CTD' then
      Example('// Static: Left : CTD_INT\#Left(CD := "Part_Out", LD := "Refill", PV := 20);\"Empty" := #Left.Q;',
        'A magazine of 20 parts: "Empty" when the last one is out.')
    else
      Example('// Static: Cars : CTUD_INT\#Cars(CU := "Car_In", CD := "Car_Out", R := "Reset", LD := FALSE, PV := 50);\"Garage_Full" := #Cars.QU;',
        'The garage is full at 50 cars.');
  end
  else if Lg = 'S' then
    Example('CALL #Count\  CU := "Box_Sensor"\  R  := "Reset_PB"\  PV := 10\  Q  := "Full"\  CV := "Boxes"',
      'Declare Count : CTU_INT as a Static first.');
  Notes(['The counter counts the rising edges of its input itself.',
    'CTU_INT counts up to 32767 and stays there; CTU_DINT, CTU_UDINT .. count further.',
    'Every counter needs its own instance.']);
end;

procedure S5CounterPage(const Name: string);
begin
  if Name = 'CU' then
    Summary('S5 counter count up: a rising edge of the RLO adds 1 to the counter C n (0 .. 999). The counter bit is TRUE ' +
      'while the value is not 0.')
  else if Name = 'CD' then
    Summary('S5 counter count down: a rising edge subtracts 1 from C n (not below 0).')
  else
    Summary('S5 set counter: a rising edge loads the counter C n with the preset value (C#..).');
  if Lg in ['F', 'K'] then
  begin
    Syntax('a box S_CU / S_CD / S_CUD: the counter above it (C1); CU / CD (the counting inputs), S (load PV), PV (C#..), ' +
      'R on its left; Q (the counter bit) and CV (the value) on its right');
    Params('counter|Counter|above the box: C0 .. C255\CU / CD|Bool|count on a rising edge\S|Bool|load PV\' +
      'PV|Word|C#0 .. C#999\R|Bool|reset\Q|Bool|TRUE while the value is not 0\CV|Word|the value (binary)');
    HowTo(['Double click the box, type the counter above it (C1) and the counting signal at CU / CD.',
      'CV: an operand for the value; Q: TRUE while it is not 0.']);
    Lad('p "Box_Sensor"|"Edge_M";cu C1\no "Load";sc C1|C#10', 'count up, load 10');
    Txt('The same in SCL:');
    Code('S_CU(C_NO := C1, CU := "Box_Sensor", S := "Load", PV := C#10, CV => "Count");');
    Notes(['The S5 counters exist on the S7-300/400/1500; on an S7-1200 use CTU / CTD / CTUD.', 'The value is 0 .. 999.']);
    Exit;
  end;
  if Lg = 'L' then
  begin
    Syntax('a coil (' + Name + ') with the counter as its operand (C1)' + IfThen(Name = 'SC', ' and the preset (C#10) below', '') +
      '.\The counter bit: a contact -| |- C1.');
    Params('operand|Counter|C0 .. C255\preset (SC)|Word|C#0 .. C#999\C n (contact)|Bool|TRUE while the value is not 0');
    HowTo(['Put the counting condition, then the coil on the next cell.', 'Type the counter (C1) above it.',
      'Read it with a contact -| |- C1, or the value with L C 1 in STL.']);
    Lad('p "Box_Sensor"|"Edge_M";cu C1\no "Load";sc C1|C#10', 'count up, load 10');
  end
  else
  begin
    Syntax('A     <condition>\' + Name + '    C 1' + IfThen(Name = 'SC', '\// before SC: L C#10 (the preset in ACCU 1)', ''));
    HowTo(['Write the condition (A ..), then ' + Name + ' C n.', 'L C n loads the value, LC C n as BCD, A C n reads the bit.']);
    Example('A     "Box_Sensor"\CU    C 1\A     "Load"\L     C#10\S     C 1\L     C 1\T     "Count"', 'counts up, "Load" sets 10.');
  end;
  Notes(['The S5 counters exist on the S7-300/400 only; on an S7-1200/1500 use CTU / CTD / CTUD.',
    'The value is 0 .. 999.']);
end;

procedure EdgePage(const Name: string);
begin
  if Name = 'R_TRIG' then
    Summary('Rising edge: Q is TRUE for exactly one cycle when CLK goes from FALSE to TRUE. Typical: do something once per ' +
      'button press, count a pulse, start a sequence step.')
  else if Name = 'F_TRIG' then
    Summary('Falling edge: Q is TRUE for exactly one cycle when CLK goes from TRUE to FALSE. Typical: a button released, ' +
      'a part that left the sensor.')
  else if Name = 'RS' then
    Summary('Flip-flop, reset dominant. S = TRUE sets Q1, R1 = TRUE resets it; when both are TRUE, R1 wins (Q1 = FALSE). ' +
      'Q1 keeps its value when both are FALSE. Typical: a motor latch where the stop must always win.')
  else
    Summary('Flip-flop, set dominant. S1 = TRUE sets Q1, R = TRUE resets it; when both are TRUE, S1 wins (Q1 = TRUE). ' +
      'Typical: an alarm memory that must not be lost while the cause is there.');
  case Lg of
    'L', 'F', 'K':
      begin
        Syntax('a box: ' + IfThen((Name = 'R_TRIG') or (Name = 'F_TRIG'), 'CLK', IfThen(Name = 'RS', 'S', 'S1')) +
          ' is the rung on its left, the power out on its right.\Above it: its instance (' + Name + ').');
        if Name = 'RS' then Params('S|Bool|set (the rung)\R1|Bool|reset, wins\Q1|Bool|the state (the power out)\instance|RS|its memory')
        else if Name = 'SR' then Params('S1|Bool|set (the rung), wins\R|Bool|reset\Q1|Bool|the state\instance|SR|its memory')
        else Params('CLK|Bool|the signal (the rung)\Q|Bool|the edge: TRUE for one cycle\instance|' + Name + '|its memory');
        HowTo(['Declare the instance: Static Edge : ' + Name + ' in the FB (or a DB variable).',
          'Put the signal contact, then the box; type the instance above it' + IfThen((Name = 'RS') or (Name = 'SR'),
          ' and the reset in the properties panel', '') + '.']);
        if Name = 'RS' then Lad('no "Start_PB";rs #Latch|"Stop_PB";-;coil "Motor"', 'the stop wins')
        else if Name = 'SR' then Lad('no "Alarm";sr #Mem|"Ack";-;coil "Alarm_Lamp"', 'the alarm wins over the acknowledge')
        else Lad('no "Button";' + LowerCase(StringReplace(Name, '_', '', [])) + ' #Edge;-;coil "Pulse"', 'one cycle per press');
      end;
    'S':
      begin
        if (Name = 'RS') or (Name = 'SR') then Syntax('CALL #Latch\  S := ..\  R1 := ..\  Q1 := ..')
        else Syntax('CALL #Edge\  CLK := ..\  Q   := ..');
        HowTo(['Declare the instance as a Static (Edge : ' + Name + ').', 'One parameter per line under the CALL.']);
        Txt('In STL itself the edge of the RLO is FP / FN with an edge memory bit (A "Button"  FP "Edge_M"  = "Pulse").');
      end;
  else
    begin
      if Name = 'RS' then Syntax('#RS_Instance(S := .., R1 := ..);\.. := #RS_Instance.Q1;')
      else if Name = 'SR' then Syntax('#SR_Instance(S1 := .., R := ..);\.. := #SR_Instance.Q1;')
      else Syntax('#' + Name + '_Instance(CLK := ..);\IF #' + Name + '_Instance.Q THEN .. END_IF;');
      HowTo(['Declare the instance: Static ' + Name + '_Instance : ' + Name + ' in the FB interface.',
        'Call it in every cycle, then use .Q / .Q1.']);
    end;
  end;
  Head('Timing diagram');
  if Name = 'R_TRIG' then Wave('CLK=0011110001100000\Q=0010000001000000', 'Q: one cycle at every rising edge')
  else if Name = 'F_TRIG' then Wave('CLK=0011110001100000\Q=0000001000010000', 'Q: one cycle at every falling edge')
  else if Name = 'RS' then Wave('S=0110000111100000\R1=0001100001100000\Q1=0110000110000000', 'both TRUE (steps 9, 10): reset wins')
  else Wave('S1=0110000111100000\R=0001100001100000\Q1=0110000111111111', 'both TRUE (steps 9, 10): set wins');
  if Lg = 'C' then
  begin
    if Name = 'R_TRIG' then
      Example('// Static: Edge : R_TRIG\#Edge(CLK := "Button");\IF #Edge.Q THEN\    "Presses" := "Presses" + 1;\END_IF;',
        'Counts every press of the button once.')
    else if Name = 'F_TRIG' then
      Example('// Static: Gone : F_TRIG\#Gone(CLK := "Part_Sensor");\IF #Gone.Q THEN\    "Parts" := "Parts" + 1;\END_IF;',
        'Counts a part when it has left the sensor.')
    else if Name = 'RS' then
      Example('// Static: Latch : RS\#Latch(S := "Start_PB", R1 := "Stop_PB" OR "Overload");\"Motor" := #Latch.Q1;',
        'Start / stop of a motor: stop and overload always win.')
    else
      Example('// Static: Mem : SR\#Mem(S1 := "High_Temp", R := "Ack");\"Alarm_Lamp" := #Mem.Q1;',
        'The alarm stays until it is acknowledged and the temperature is normal again.');
  end
  else if Lg = 'S' then
  begin
    if (Name = 'RS') or (Name = 'SR') then Example('CALL #Latch\  S  := "Start_PB"\  R1 := "Stop_PB"\  Q1 := "Motor"', '')
    else Example('CALL #Edge\  CLK := "Button"\  Q   := "Pulse"', '');
  end;
  Notes(['An edge needs memory: every R_TRIG / F_TRIG has its own instance (the value of the last cycle).',
    'A temp variable (VAR_TEMP) cannot be the instance: it forgets its value at the end of the block.']);
end;

{ ---------- the functions shared by SCL, LAD (a box) and STL (CALL) ---------- }

{ Pins: 'Name|Type|meaning\..' (the inputs, then the output OUT / RET_VAL); SclEx, StlEx: the examples; LadEx: the
  rung; Tbl: a table of values }
procedure FnPage(const Name, Sum, Pins, SclSyn, SclEx, LadEx, StlEx, ExWhat, Tbl, TblCap: string;
  const Nts: array of string);
begin
  Summary(Sum);
  case Lg of
    'L', 'F', 'K':
      begin
        Syntax('a box on the rung: EN is the rung on its left, ENO the power out (ENO = EN; FALSE when the result is ' +
          'invalid).\The inputs on its left, the output on its right; the data type in the box.');
        Params(Pins);
        HowTo(['Put the condition contact (or nothing: the box runs always), then the box on the next cell.',
          'Click the box: type the inputs and the output in the properties panel on the right; choose the data type there.']);
        if LadEx <> '' then Lad(LadEx, '');
        if SclEx <> '' then
        begin
          Txt('The same in SCL:');
          Code(SclEx);
        end;
      end;
    'S':
      begin
        Syntax(StlEx);
        Params(StringReplace(Pins, 'OUT|', 'RET_VAL|', []));
        HowTo(['Write CALL ' + Name + ' and one parameter per line: Name := operand (or a constant).',
          'RET_VAL is the result: an operand of the same type.']);
      end;
  else
    begin
      Syntax(SclSyn);
      Params(Pins);
      HowTo(['Replace the placeholders: an operand ("Tag", #Var, "DB".Var) or a constant; the result goes left of :=.',
        'The function can also be a part of an expression: #y := ' + Name + '(..) * 2;']);
    end;
  end;
  if Tbl <> '' then
  begin
    Head('Values');
    Tab(Tbl);
    if TblCap <> '' then Add(hbCaption, TblCap);
  end;
  if XBits <> '' then
  begin
    Head(XHead);
    Bits(XBits, XCap);
    XBits := '';
  end;
  if Lg = 'S' then Example(StlEx, ExWhat)
  else if Lg = 'C' then Example(SclEx, ExWhat);
  Notes(Nts);
end;

function StlCall(const Name, Lines: string): string;
begin
  Result := 'CALL ' + Name + '\' + Lines;
end;

procedure SelectPage(const Name: string);
var
  K: Integer;
  S: string;
begin
  if Name = 'MIN' then
    FnPage('MIN', 'Returns the smallest of its inputs (2 .. 32 in SCL, up to 4 in the LAD box). All inputs have the same ' +
      'data type (Int, DInt, Real, Time ..).', 'IN1|number|the first value\IN2|number|the second value\IN3 ..|number|more ' +
      'values (optional)\OUT|number|the smallest',
      'MIN(IN1 := .., IN2 := ..)', '"Speed_Set" := MIN(IN1 := "Speed_HMI", IN2 := "Speed_Max");',
      'no "Enable";min@Int "Speed_HMI"|"Speed_Max"|||"Speed_Set";-', StlCall('MIN', '  IN1 := "Speed_HMI"\  IN2 := "Speed_Max"\  RET_VAL := "Speed_Set"'),
      'The speed of the HMI, but never more than the maximum.',
      'IN1|IN2|IN3|OUT\5|9||5\-3|2|7|-3\2.5|2.4||2.4', '', ['Mixed types need a conversion first (INT_TO_REAL ..).'])
  else if Name = 'MAX' then
    FnPage('MAX', 'Returns the largest of its inputs (2 .. 32 in SCL, up to 4 in the LAD box).',
      'IN1|number|the first value\IN2|number|the second value\IN3 ..|number|more values\OUT|number|the largest',
      'MAX(IN1 := .., IN2 := ..)', '"Level_Peak" := MAX(IN1 := "Level_Peak", IN2 := "Level");',
      'no "Enable";max@Int "Level_Peak"|"Level"|||"Level_Peak";-', StlCall('MAX', '  IN1 := "Level_Peak"\  IN2 := "Level"\  RET_VAL := "Level_Peak"'),
      'Keeps the highest level seen (a peak memory).', 'IN1|IN2|IN3|OUT\5|9||9\-3|2|7|7\2.5|2.4||2.5', '', [])
  else if Name = 'LIMIT' then
    FnPage('LIMIT', 'Limits IN to the range MN .. MX: below MN the result is MN, above MX it is MX, in between IN itself.',
      'MN|number|the lower limit\IN|number|the value\MX|number|the upper limit\OUT|number|IN, limited',
      'LIMIT(MN := .., IN := .., MX := ..)', '"Valve_Pos" := LIMIT(MN := 0.0, IN := "PID_Out", MX := 100.0);',
      'no "Enable";limit@Real 0.0|"PID_Out"|100.0|"Valve_Pos";-', StlCall('LIMIT', '  MN := 0.0\  IN := "PID_Out"\  MX := 100.0\  RET_VAL := "Valve_Pos"'),
      'The valve gets 0 .. 100 % whatever the controller computes.', 'MN|IN|MX|OUT\0|-5|100|0\0|42|100|42\0|130|100|100', '',
      ['MN must be <= MX.'])
  else if Name = 'SEL' then
    FnPage('SEL', 'Selects one of two values: G = FALSE gives IN0, G = TRUE gives IN1.',
      'G|Bool|the selector\IN0|any|the value for G = FALSE\IN1|any|the value for G = TRUE\OUT|any|IN0 or IN1',
      'SEL(G := .., IN0 := .., IN1 := ..)', '"Setpoint" := SEL(G := "Night", IN0 := 21.0, IN1 := 17.0);',
      'no "Enable";sel@Real "Night"|21.0|17.0|"Setpoint";-', StlCall('SEL', '  G := "Night"\  IN0 := 21.0\  IN1 := 17.0\  RET_VAL := "Setpoint"'),
      'The room temperature 21 °C by day, 17 °C at night.', 'G|IN0|IN1|OUT\FALSE|21.0|17.0|21.0\TRUE|21.0|17.0|17.0', '', [])
  else
  begin
    S := 'K|IN0|IN1|IN2|OUT';
    for K := 0 to 3 do
      if K <= 2 then S := S + Format('\%d|10|20|30|%d', [K, 10 + K * 10]) else S := S + '\3|10|20|30|INELSE (else 0)';
    FnPage('MUX', 'Selects the input number K: K = 0 gives IN0, K = 1 IN1 ... A K that has no input gives INELSE (0 when ' +
      'there is none) and ENO = FALSE.', 'K|Int|the number of the input\IN0 .. IN31|any|the values\INELSE|any|the value ' +
      'for a K outside (optional)\OUT|any|the selected value',
      'MUX(K := .., IN0 := .., IN1 := .., IN2 := ..)', '"Speed" := MUX(K := "Gear", IN0 := 0, IN1 := 300, IN2 := 800, INELSE := 0);',
      'no "Enable";mux@Int "Gear"|0|300|800|"Speed";-', StlCall('MUX', '  K := "Gear"\  IN0 := 0\  IN1 := 300\  IN2 := 800\  RET_VAL := "Speed"'),
      'A speed per gear.', S, '', ['The LAD box has IN0 .. IN2; SCL takes up to IN31.']);
  end;
end;

procedure MathPage(const Name: string);
const
  Xs: array[0..3] of Double = (0.0, 0.5, 2.0, -1.0);
var
  K: Integer;
  S, Sum, Fml: string;
  V: Double;
begin
  Fml := Name + '(IN)';
  case Name of
    'ABS': Sum := 'The absolute value: -5 gives 5. Works for integers and Real.';
    'SQR': Sum := 'The square: IN * IN.';
    'SQRT': Sum := 'The square root. A negative IN is invalid (NaN, ENO = FALSE).';
    'EXP': Sum := 'e (2.71828) to the power of IN.';
    'LN': Sum := 'The natural logarithm (base e). IN must be > 0.';
    'LOG': Sum := 'The logarithm to the base 10. IN must be > 0.';
    'SIN': Sum := 'The sine of IN in radians (degrees * 3.14159 / 180).';
    'COS': Sum := 'The cosine of IN in radians.';
    'TAN': Sum := 'The tangent of IN in radians.';
    'ASIN': Sum := 'The arc sine: the angle in radians (-1.5708 .. 1.5708) whose sine is IN (-1 .. 1).';
    'ACOS': Sum := 'The arc cosine: the angle in radians (0 .. 3.14159) whose cosine is IN (-1 .. 1).';
    'ATAN': Sum := 'The arc tangent: the angle in radians (-1.5708 .. 1.5708).';
    'FRAC': Sum := 'The decimal places of IN: 3.75 gives 0.75, -2.5 gives -0.5.';
  else
    Sum := Name + '(IN): a floating point function.';
  end;
  S := 'IN|' + Name + '(IN)';
  for K := 0 to High(Xs) do
  begin
    case Name of
      'ABS': V := Abs(Xs[K]);
      'SQR': V := Sqr(Xs[K]);
      'SQRT': if Xs[K] < 0 then V := NaN else V := Sqrt(Xs[K]);
      'EXP': V := Exp(Xs[K]);
      'LN': if Xs[K] <= 0 then V := NaN else V := Ln(Xs[K]);
      'LOG': if Xs[K] <= 0 then V := NaN else V := Log10(Xs[K]);
      'SIN': V := Sin(Xs[K]);
      'COS': V := Cos(Xs[K]);
      'TAN': V := Tan(Xs[K]);
      'ASIN': if Abs(Xs[K]) > 1 then V := NaN else V := ArcSin(Xs[K]);
      'ACOS': if Abs(Xs[K]) > 1 then V := NaN else V := ArcCos(Xs[K]);
      'ATAN': V := ArcTan(Xs[K]);
      'FRAC': V := Frac(Xs[K] + 0.25);
    else
      V := Xs[K];
    end;
    if Name = 'FRAC' then S := S + '\' + FStr(Xs[K] + 0.25) + '|' + FStr(V)
    else S := S + '\' + FStr(Xs[K]) + '|' + FStr(V);
  end;
  FnPage(Name, Sum, 'IN|Real / LReal|the value' + IfThen(Name = 'ABS', ' (also an integer)', '') + '\OUT|Real / LReal|' + Fml,
    Name + '(IN := ..)    or    ' + Name + '(..)',
    IfThen(Pos(Name, 'SIN COS TAN') > 0, '#Rad := "Angle" * 3.14159 / 180.0;\"Y" := "Radius" * ' + Name + '(#Rad);',
      '"Result" := ' + Name + '("Value");'),
    'no "Enable";' + LowerCase(Name) + '@Real "Value"|"Result";-', StlCall(Name, '  IN := "Value"\  RET_VAL := "Result"'),
    '', S, 'computed with the same functions as the CPU', ['The result of an Real input is a Real, of an LReal an LReal.',
    'An invalid input gives NaN and ENO = FALSE; check it with the ENO of the box or before the call.']);
end;

procedure RoundPage(const Name: string);
const
  Xs: array[0..5] of Double = (2.4, 2.5, 3.5, 2.6, -2.5, -2.6);
var
  K: Integer;
  S, Sum: string;
  V: Int64;
begin
  case Name of
    'TRUNC': Sum := 'Converts a Real into an integer (DInt) by cutting the decimals off: 2.9 gives 2, -2.9 gives -2.';
    'ROUND': Sum := 'Converts a Real into an integer (DInt) to the nearest whole number; a half goes to the even one ' +
      '(2.5 gives 2, 3.5 gives 4).';
    'CEIL': Sum := 'Converts a Real into the smallest integer that is not less: 2.1 gives 3, -2.9 gives -2.';
  else
    Sum := 'Converts a Real into the largest integer that is not greater: 2.9 gives 2, -2.1 gives -3.';
  end;
  S := 'IN|' + Name;
  for K := 0 to High(Xs) do
  begin
    case Name of
      'TRUNC': V := Trunc(Xs[K]);
      'ROUND': V := Round(Xs[K]);
      'CEIL': V := Ceil(Xs[K]);
    else
      V := Floor(Xs[K]);
    end;
    S := S + '\' + FStr(Xs[K]) + '|' + IntToStr(V);
  end;
  FnPage(Name, Sum, 'IN|Real / LReal|the value\OUT|DInt (LAD: the type in the box)|the whole number',
    Name + '(..)', '"Count" := ' + Name + '("Litres" / 2.5);', 'no "Enable";' + LowerCase(Name) + '@Real>DInt "Litres"|"Count";-',
    StlCall(Name, '  IN := "Litres"\  RET_VAL := "Count"'), '', S, '', ['A Real that is too large for the target wraps around: ' +
    'check the range first.', 'STL: RND, RND+, RND-, TRUNC work on ACCU 1.']);
end;

procedure ScalePage(const Name: string);
begin
  if Name = 'NORM_X' then
    FnPage('NORM_X', 'Normalizes VALUE from the range MIN .. MAX to 0.0 .. 1.0: OUT := (VALUE - MIN) / (MAX - MIN). With ' +
      'SCALE_X it turns a raw analog value (0 .. 27648) into a physical one.',
      'MIN|Int / Real|the start of the range\VALUE|Int / Real|the value\MAX|Int / Real|the end of the range\OUT|Real|0.0 .. 1.0',
      'NORM_X(MIN := .., VALUE := .., MAX := ..)', '#n := NORM_X(MIN := 0, VALUE := "AI_Level", MAX := 27648);\"Level_m" := SCALE_X(MIN := 0.0, VALUE := #n, MAX := 5.0);',
      'no "Enable";normx@Int 0|"AI_Level"|27648|#n;-\no "Enable";scalex@Real 0.0|#n|5.0|"Level_m";-',
      StlCall('NORM_X', '  MIN := 0\  VALUE := "AI_Level"\  MAX := 27648\  RET_VAL := #n'),
      'An analog input 0 .. 27648 as 0 .. 5 m.', 'MIN|VALUE|MAX|OUT\0|0|27648|0.0\0|13824|27648|0.5\0|27648|27648|1.0\0|30000|27648|1.085',
      'a value outside MIN .. MAX gives less than 0.0 or more than 1.0', [])
  else
    FnPage('SCALE_X', 'Scales VALUE from 0.0 .. 1.0 to the range MIN .. MAX: OUT := VALUE * (MAX - MIN) + MIN. After NORM_X ' +
      'it gives the physical value; before an analog output it turns 0 .. 1 into 0 .. 27648.',
      'MIN|Int / Real|the start of the range\VALUE|Real|0.0 .. 1.0\MAX|Int / Real|the end of the range\OUT|Int / Real|the scaled value',
      'SCALE_X(MIN := .., VALUE := .., MAX := ..)', '"AQ_Valve" := SCALE_X(MIN := 0, VALUE := "Valve_Pos" / 100.0, MAX := 27648);',
      'no "Enable";scalex@Int 0|#Frac|27648|"AQ_Valve";-', StlCall('SCALE_X', '  MIN := 0\  VALUE := #Frac\  MAX := 27648\  RET_VAL := "AQ_Valve"'),
      'A valve position 0 .. 100 % to an analog output.', 'MIN|VALUE|MAX|OUT\0.0|0.0|5.0|0.0\0.0|0.5|5.0|2.5\4.0|0.25|20.0|8.0', '', []);
end;

procedure ConvPage(const Name: string);
var
  A, B, S, Sum: string;
  Q: Integer;
begin
  Q := Pos('_TO_', Name);
  A := Copy(Name, 1, Q - 1);
  B := Copy(Name, Q + 4, MaxInt);
  Sum := 'Converts a value of the type ' + A + ' into the type ' + B + '. SCL does not mix types by itself: every ' +
    'assignment of another type needs such a conversion.';
  if (A = 'INT') and (B = 'REAL') then S := 'IN|OUT\5|5.0\-300|-300.0\32767|32767.0'
  else if (A = 'DINT') and (B = 'REAL') then S := 'IN|OUT\100000|100000.0\-7|-7.0\16777217|16777216.0 (a Real has 7 digits)'
  else if (B = 'INT') and (A = 'REAL') then S := 'IN|OUT\2.5|2 (a half to even)\3.5|4\-1.7|-2\40000.0|-25536 (wraps: out of range)'
  else if (B = 'DINT') and (A = 'REAL') then S := 'IN|OUT\2.5|2\1.0E6|1000000\-0.4|0'
  else if (A = 'INT') and (B = 'DINT') then S := 'IN|OUT\-5|-5\32767|32767'
  else if (A = 'DINT') and (B = 'INT') then S := 'IN|OUT\1000|1000\70000|4464 (wraps: out of range)\-40000|25536 (wraps)'
  else if A = 'BOOL' then S := 'IN|OUT\FALSE|0\TRUE|1'
  else if B = 'BOOL' then S := 'IN|OUT\0|FALSE\1|TRUE\5|TRUE'
  else if (A = 'INT') and (B = 'WORD') then S := 'IN|OUT\255|16#00FF\-1|16#FFFF'
  else if (A = 'WORD') and (B = 'INT') then S := 'IN|OUT\16#00FF|255\16#FFFF|-1'
  else if (A = 'DINT') and (B = 'DWORD') then S := 'IN|OUT\-1|16#FFFF_FFFF\65536|16#0001_0000'
  else if (A = 'DWORD') and (B = 'DINT') then S := 'IN|OUT\16#0000_0010|16\16#FFFF_FFFF|-1'
  else if (A = 'BYTE') and (B = 'WORD') then S := 'IN|OUT\16#A5|16#00A5'
  else if (A = 'WORD') and (B = 'BYTE') then S := 'IN|OUT\16#12A5|16#A5 (the low byte)'
  else if (A = 'TIME') and (B = 'DINT') then S := 'IN|OUT\T#1S|1000 (ms)\T#1M30S|90000'
  else if (A = 'DINT') and (B = 'TIME') then S := 'IN|OUT\1500|T#1S500MS\60000|T#1M'
  else if (A = 'S5TIME') and (B = 'TIME') then S := 'IN|OUT\S5T#2S|T#2S\S5T#1M10S|T#1M10S'
  else if (A = 'TIME') and (B = 'S5TIME') then S := 'IN|OUT\T#2S|S5T#2S\T#3H|S5T#2H46M30S (the largest)'
  else if (A = 'CHAR') and (B = 'BYTE') then S := 'IN|OUT\''A''|16#41 (65)'
  else if (A = 'BYTE') and (B = 'CHAR') then S := 'IN|OUT\16#41|''A'''
  else if (A = 'REAL') and (B = 'LREAL') then S := 'IN|OUT\0.1|0.100000001490116 (the Real error shows)'
  else if (A = 'LREAL') and (B = 'REAL') then S := 'IN|OUT\3.14159265358979|3.141593'
  else S := '';
  if Lg in ['L', 'F', 'K'] then
  begin
    FnPage(Name, Sum + ' The CONV box does every conversion: the types of IN and OUT are chosen in the box.',
      'IN|' + A + '|the value\OUT|' + B + '|the converted value', '', '"Speed_R" := ' + Name + '("Speed_I");',
      'no "Enable";conv@' + A + '>' + B + ' "Speed_I"|"Speed_R";-', '', '', S, '', []);
    Exit;
  end;
  FnPage(Name, Sum, 'IN|' + A + '|the value\OUT|' + B + '|the converted value', Name + '(..)',
    '"Flow_R" := ' + Name + '("Flow_I");', '', StlCall(Name, '  IN := "Flow_I"\  RET_VAL := "Flow_R"'),
    'The value of "Flow_I" as ' + B + '.', S, '', ['Every pair of the numeric, bit string and time types exists as X_TO_Y ' +
    '(INT_TO_DINT, REAL_TO_INT, WORD_TO_INT ..): write it the same way.',
    'A value that the target cannot hold wraps around (DINT_TO_INT(70000) = 4464): check the range before.',
    'REAL to an integer rounds (a half to even); TRUNC cuts the decimals off instead.']);
end;

procedure ShiftPage(const Name: string);
var
  V, R: QWord;
  Sum, Lbl: string;
begin
  V := $00B3;
  case Name of
    'SHL':
      begin
        R := (V shl 3) and $FFFF;
        Sum := 'Shifts the bits of IN N places to the left; 0s come in from the right, the bits that leave on the left are ' +
          'lost. For an unsigned number: IN * 2^N.';
        Lbl := 'SHL(IN, N := 3) = ' + Hex4(R) + '=' + BinMark(R, 16, 0, 2);
      end;
    'SHR':
      begin
        R := V shr 3;
        Sum := 'Shifts the bits of IN N places to the right; 0s come in from the left. For an unsigned number: IN / 2^N.';
        Lbl := 'SHR(IN, N := 3) = ' + Hex4(R) + '=' + BinMark(R, 16, 13, 15);
      end;
    'ROL':
      begin
        R := ((V shl 3) or (V shr 13)) and $FFFF;
        Sum := 'Rotates the bits of IN N places to the left: the bits that leave on the left come in again on the right.';
        Lbl := 'ROL(IN, N := 3) = ' + Hex4(R) + '=' + BinMark(R, 16, 0, 2);
      end;
  else
    begin
      R := ((V shr 3) or (V shl 13)) and $FFFF;
      Sum := 'Rotates the bits of IN N places to the right: the bits that leave on the right come in again on the left.';
      Lbl := 'ROR(IN, N := 3) = ' + Hex4(R) + '=' + BinMark(R, 16, 13, 15);
    end;
  end;
  XHead := 'The bits';
  XBits := 'IN = ' + Hex4(V) + '=' + BinMark(V, 16, -1, -1) + '\' + Lbl;
  XCap := 'the bits that came in are red';
  FnPage(Name, Sum, 'IN|Byte / Word / DWord (integers too)|the bit pattern\N|UInt|how many places\OUT|as IN|the result',
    Name + '(IN := .., N := ..)', '"Mask" := ' + Name + '(IN := "Pattern", N := 3);', 'no "Step";' + LowerCase(Name) +
    '@Word "Pattern"|3|"Mask";-', StlCall(Name, '  IN := "Pattern"\  N := 3\  RET_VAL := "Mask"'), '', '', '',
    ['STL itself: SLW / SRW / SLD / SRD shift ACCU 1, RLD / RRD rotate it.', 'A running light: ROL of a Word once per second.']);
end;

procedure StringPage(const Name: string);
begin
  case Name of
    'LEN': FnPage('LEN', 'The current length of a string (the number of characters in it, not its maximum).',
      'IN|String|the string\OUT|Int|its length', 'LEN(..)', '"Chars" := LEN("Barcode");', 'no "Read";len "Barcode"|"Chars";-',
      StlCall('LEN', '  IN := "Barcode"\  RET_VAL := "Chars"'), '', 'IN|OUT\''ABC''|3\''''|0\''Line 1''|6', '', []);
    'CONCAT': FnPage('CONCAT', 'Joins IN2 to the end of IN1. The result is cut at the maximum length of the target.',
      'IN1|String|the first part\IN2|String|the second part\OUT|String|IN1 followed by IN2', 'CONCAT(IN1 := .., IN2 := ..)',
      '#Msg := CONCAT(IN1 := ''Station '', IN2 := "Station_Name");', 'no "Show";concat ''Station ''|"Station_Name"|#Msg;-',
      StlCall('CONCAT', '  IN1 := ''Station ''\  IN2 := "Station_Name"\  RET_VAL := #Msg'), '',
      'IN1|IN2|OUT\''AB''|''CD''|''ABCD''\''Tank ''|''3''|''Tank 3''', '', ['More parts: CONCAT inside CONCAT.']);
    'LEFT': FnPage('LEFT', 'The first L characters of IN.', 'IN|String|the string\L|Int|how many characters\OUT|String|the first L',
      'LEFT(IN := .., L := ..)', '#Code := LEFT(IN := "Barcode", L := 3);', 'no "Read";left "Barcode"|3|#Code;-',
      StlCall('LEFT', '  IN := "Barcode"\  L := 3\  RET_VAL := #Code'), '', 'IN|L|OUT\''ABCDEF''|3|''ABC''\''AB''|5|''AB''', '', []);
    'RIGHT': FnPage('RIGHT', 'The last L characters of IN.', 'IN|String|the string\L|Int|how many characters\OUT|String|the last L',
      'RIGHT(IN := .., L := ..)', '#Serial := RIGHT(IN := "Barcode", L := 4);', 'no "Read";right "Barcode"|4|#Serial;-',
      StlCall('RIGHT', '  IN := "Barcode"\  L := 4\  RET_VAL := #Serial'), '', 'IN|L|OUT\''ABCDEF''|2|''EF''', '', []);
    'MID': FnPage('MID', 'L characters of IN from the position P (the first character is position 1).',
      'IN|String|the string\L|Int|how many characters\P|Int|from which position (1 = the first)\OUT|String|the part',
      'MID(IN := .., L := .., P := ..)', '#Lot := MID(IN := "Barcode", L := 2, P := 4);', 'no "Read";mid "Barcode"|2|4|#Lot;-',
      StlCall('MID', '  IN := "Barcode"\  L := 2\  P := 4\  RET_VAL := #Lot'), '', 'IN|L|P|OUT\''ABCDEF''|2|3|''CD''\''ABCDEF''|3|5|''EF''', '', []);
    'FIND': FnPage('FIND', 'The position of the string IN2 in IN1 (1 = at the start); 0 when it is not there.',
      'IN1|String|where to look\IN2|String|what to find\OUT|Int|its position, 0: not found', 'FIND(IN1 := .., IN2 := ..)',
      '#Pos := FIND(IN1 := "Barcode", IN2 := ''-'');', 'no "Read";find "Barcode"|''-''|#Pos;-',
      StlCall('FIND', '  IN1 := "Barcode"\  IN2 := ''-''\  RET_VAL := #Pos'), '', 'IN1|IN2|OUT\''AB-CD''|''-''|3\''ABCD''|''X''|0', '', []);
  else
    FnPage('S_MOVE', 'Copies a string into another one. The target keeps its own maximum length: a longer string is cut.',
      'IN|String|the source\OUT|String|the target', '(SCL: an assignment #Target := #Source;)', '"Recipe_Name" := #Name;',
      'no "Load";smove #Name|"Recipe_Name";-', StlCall('S_MOVE', '  IN := #Name\  RET_VAL := "Recipe_Name"'), '', '', '', []);
  end;
end;

{ ---------- SCL ---------- }

procedure SclControl(const Cap: string);
begin
  case Cap of
    'IF ... THEN':
      begin
        Summary('Runs the statements between THEN and END_IF only when the condition is TRUE. Otherwise the program goes on ' +
          'after END_IF.');
        Syntax('IF <condition> THEN\    <statements>;\END_IF;');
        HowTo(['Type the condition after IF: a Bool ("Start"), a comparison (#Temp > 80.0) or both (#a AND NOT #b).',
          'Write the statements on the lines between THEN and END_IF (indented by 4 spaces).']);
        Head('Flowchart');
        Flow('if|#Temp > 80.0|"Fan" := TRUE', '');
        Example('IF "Temp" > 80.0 THEN\    "Fan" := TRUE;\END_IF;', 'The fan goes on above 80 °C (and stays on: nothing switches it off here).');
        Notes(['A statement in an IF that is not run keeps its last value: an output is not reset by itself. For a ' +
          'Bool that follows the condition write "Fan" := "Temp" > 80.0;',
          'Every IF ends with END_IF; (the semicolon too).']);
      end;
    'IF ... ELSE':
      begin
        Summary('Two branches: the statements after THEN when the condition is TRUE, the ones after ELSE when it is FALSE.');
        Syntax('IF <condition> THEN\    <statements>;\ELSE\    <statements>;\END_IF;');
        HowTo(['Type the condition after IF.', 'Write the TRUE branch after THEN and the FALSE branch after ELSE.']);
        Head('Flowchart');
        Flow('ifelse|"Auto"|"Speed" := "Speed_Auto"|"Speed" := "Speed_Hand"', '');
        Example('IF "Auto" THEN\    "Speed" := "Speed_Auto";\ELSE\    "Speed" := "Speed_Hand";\END_IF;', 'Auto or hand speed.');
        Notes(['For a simple choice of a value SEL is shorter: "Speed" := SEL(G := "Auto", IN0 := "Speed_Hand", IN1 := "Speed_Auto");']);
      end;
    'IF ... ELSIF ... ELSE':
      begin
        Summary('Several conditions tested from the top: the first TRUE one runs its statements, the others are skipped. ' +
          'ELSE runs when none was TRUE.');
        Syntax('IF <condition 1> THEN\    <statements>;\ELSIF <condition 2> THEN\    <statements>;\ELSE\    <statements>;\END_IF;');
        HowTo(['Type the first condition after IF and the next one after ELSIF (as many ELSIF as needed).',
          'Order them: the first TRUE one wins.']);
        Head('Flowchart');
        Flow('elsif|"Level" > 90.0|"Pump" := 2|"Level" > 50.0|"Pump" := 1|"Pump" := 0', '');
        Example('IF "Level" > 90.0 THEN\    "Pumps" := 2;\ELSIF "Level" > 50.0 THEN\    "Pumps" := 1;\ELSE\    "Pumps" := 0;\END_IF;',
          'Two pumps above 90 %, one above 50 %.');
        Notes(['ELSIF is one word (not ELSE IF).']);
      end;
    'CASE ... OF':
      begin
        Summary('A branch for each value of an integer selector. A label is a value (1:), a list (2, 3:) or a range (4..9:). ' +
          'ELSE runs for every other value. Typical: the steps of a sequence.');
        Syntax('CASE <integer> OF\    1:\        <statements>;\    2, 3:\        <statements>;\    4..9:\        <statements>;\ELSE\    <statements>;\END_CASE;');
        HowTo(['Type the selector after CASE: an Int / DInt / USInt variable (often the step of a sequence).',
          'Write a label per value with its statements; a statement may set the selector to the next step.']);
        Head('Flowchart');
        Flow('case|#Step|0: wait for start|1: fill|2: mix|ELSE: stop', '');
        Example('CASE #Step OF\    0:  // idle\        IF "Start" THEN #Step := 1; END_IF;\    1:  // fill\        "Valve" := TRUE;\        IF "Full" THEN #Step := 2; END_IF;\    2:  // mix\        "Valve" := FALSE;\        "Mixer" := TRUE;\ELSE\    #Step := 0;\END_CASE;',
          'A small sequence: idle, fill, mix.');
        Notes(['The labels must not overlap.', 'The selector is an integer; for a string use IF .. ELSIF.']);
      end;
    'FOR ... TO ... DO', 'FOR ... BY ... DO':
      begin
        Summary('A counting loop: the control variable runs from the start value to the end value (step 1, or the step ' +
          'after BY, which may be negative); the statements run once for each value. The whole loop runs within one cycle.');
        Syntax('FOR #i := <start> TO <end> DO\    <statements>;\END_FOR;\\FOR #i := 10 TO 0 BY -1 DO\    <statements>;\END_FOR;');
        HowTo(['Declare the control variable: a VAR_TEMP i : Int at the top of the network (or a Temp of the interface).',
          'Type the start and the end value; inside the loop #i is the index (#Arr[#i]).']);
        Head('Flowchart');
        Flow('loop|#i := 0|#i <= 9|#Sum := #Sum + "Data".Val[#i]|#i := #i + 1', '');
        Example('VAR_TEMP\    i : Int;\END_VAR\#Sum := 0;\FOR #i := 0 TO 9 DO\    #Sum := #Sum + "Data".Val[#i];\END_FOR;',
          'The sum of the ten values of an array.');
        Notes(['The loop runs completely in one PLC cycle: a long loop makes the cycle long (the watchdog stops the CPU).',
          'Do not change #i inside the loop; EXIT leaves it early, CONTINUE skips to the next value.']);
      end;
    'WHILE ... DO':
      begin
        Summary('Repeats the statements while the condition is TRUE. The condition is checked before every pass: when it ' +
          'is FALSE at the start the statements never run.');
        Syntax('WHILE <condition> DO\    <statements>;\END_WHILE;');
        HowTo(['Type the condition after WHILE.', 'Make sure a statement in the loop changes the condition, or it never ends.']);
        Head('Flowchart');
        Flow('loop||#i < 10 AND "Data".Val[#i] <> 0|#i := #i + 1|', '');
        Example('#i := 0;\WHILE (#i < 10) AND ("Data".Val[#i] <> 0) DO\    #i := #i + 1;\END_WHILE;\"First_Zero" := #i;',
          'Finds the first 0 in an array.');
        Notes(['An endless loop stops the CPU (cycle watchdog). Add a counter as a second condition.']);
      end;
    'REPEAT ... UNTIL':
      begin
        Summary('Repeats the statements until the condition is TRUE. The condition is checked after every pass, so the ' +
          'statements run at least once.');
        Syntax('REPEAT\    <statements>;\UNTIL <condition>\END_REPEAT;');
        HowTo(['Write the statements after REPEAT.', 'Type the end condition after UNTIL.']);
        Head('Flowchart');
        Flow('repeat|#i := #i + 1|#i >= 10 OR "Data".Val[#i] = 0', '');
        Example('#i := -1;\REPEAT\    #i := #i + 1;\UNTIL (#i >= 9) OR ("Data".Val[#i] = 0)\END_REPEAT;', '');
        Notes(['UNTIL has no semicolon before END_REPEAT.']);
      end;
    'CONTINUE':
      begin
        Summary('Skips the rest of the current pass of a loop (FOR, WHILE, REPEAT) and goes on with the next pass.');
        Syntax('CONTINUE;');
        HowTo(['Put CONTINUE inside an IF in the loop: the passes where the condition is TRUE are skipped.']);
        Head('Flowchart');
        Flow('continue|"Data".Val[#i] < 0|#Sum := #Sum + "Data".Val[#i]', '');
        Example('FOR #i := 0 TO 9 DO\    IF "Data".Val[#i] < 0 THEN\        CONTINUE;\    END_IF;\    #Sum := #Sum + "Data".Val[#i];\END_FOR;',
          'Adds only the positive values.');
      end;
    'EXIT':
      begin
        Summary('Leaves the innermost loop at once; the program goes on after END_FOR / END_WHILE / END_REPEAT.');
        Syntax('EXIT;');
        HowTo(['Put EXIT inside an IF in the loop: when the condition is TRUE the loop ends.']);
        Head('Flowchart');
        Flow('exit|"Data".Val[#i] = "Wanted"|#Found := #i', '');
        Example('#Found := -1;\FOR #i := 0 TO 9 DO\    IF "Data".Val[#i] = "Wanted" THEN\        #Found := #i;\        EXIT;\    END_IF;\END_FOR;',
          'Looks for a value and stops at the first one.');
      end;
    'RETURN':
      begin
        Summary('Leaves the block (FC / FB) at once: the statements after RETURN in this block do not run in this cycle; the ' +
          'caller goes on after the call.');
        Syntax('RETURN;');
        HowTo(['Put RETURN inside an IF: e.g. at the top, when the block has nothing to do.']);
        Example('IF NOT #Enable THEN\    #Busy := FALSE;\    RETURN;\END_IF;\// the rest of the block', 'A block that does nothing while it is not enabled.');
        Notes(['Set the outputs before RETURN: an output not written keeps its value (FB) or is not defined (FC).']);
      end;
    'REGION':
      begin
        Summary('Groups lines under a name. It does nothing in the CPU; it gives the code a structure (as in TIA Portal).');
        Syntax('REGION <name>\    <statements>;\END_REGION');
        HowTo(['Type the name after REGION and put the lines between REGION and END_REGION.']);
        Example('REGION Inputs\    #Start := "Start_PB" AND NOT "Stop_PB";\END_REGION\REGION Outputs\    "Motor" := #Start;\END_REGION', '');
      end;
    ':= (assignment)':
      begin
        Summary('Gives the variable on the left the value of the expression on the right. Every statement ends with a ' +
          'semicolon. The types must fit (else a conversion: INT_TO_REAL ..).');
        Syntax('<variable> := <expression>;');
        HowTo(['Type the target first (an output, a DB variable, #local), then the expression after :=.']);
        Example('"Motor" := "Start" AND NOT "Stop";\"Total" := "Count" * 2 + 1;\"Avg" := ("A" + "B") / 2.0;', '');
        Head('Precedence (the highest first)');
        Tab('Operators|Example\( )|(#a + #b) * 2\function call|ABS(#x)\**|#x ** 2.0\- (sign), NOT|-#x, NOT #b\* / MOD|#a MOD 10\+ -|#a + #b\< > <= >=|#t > 80.0\= <>|#s = 3\AND, &|#a AND #b\XOR|#a XOR #b\OR|#a OR #b');
      end;
    '// comment':
      begin
        Summary('A comment to the end of the line: the CPU ignores it.');
        Syntax('// text');
        HowTo(['Type // and the text. Ctrl+Q comments out the selected lines (and in again).']);
        Example('"Motor" := "Start";  // the conveyor motor', '');
      end;
  else
    begin
      Summary('A block comment between (* and *): it may cover several lines.');
      Syntax('(* text\   more text *)');
      HowTo(['Put (* before and *) after the text.']);
      Example('(* Station 3: the filling\   Author: .. *)', '');
    end;
  end;
end;

procedure SclOperator(const Cap: string);
begin
  case Cap of
    'AND', 'OR', 'XOR', 'NOT':
      begin
        if Cap = 'AND' then Summary('TRUE only when both sides are TRUE. With bit strings (Byte, Word ..): bit by bit (a mask). ' +
          '& is the same.')
        else if Cap = 'OR' then Summary('TRUE when at least one side is TRUE. With bit strings: bit by bit.')
        else if Cap = 'XOR' then Summary('TRUE when exactly one side is TRUE (the sides differ). With bit strings: bit by bit.')
        else Summary('Turns TRUE into FALSE and FALSE into TRUE. With a bit string every bit is inverted.');
        if Cap = 'NOT' then Syntax('NOT <operand>') else Syntax('<operand> ' + Cap + ' <operand>');
        HowTo(['Use it in a condition (IF "A" ' + IfThen(Cap = 'NOT', 'AND NOT "B"', Cap + ' "B"') + ' THEN) or an ' +
          'assignment.', 'Brackets make the order clear: ("A" OR "B") AND "C".']);
        Head('Truth table');
        if Cap = 'NOT' then Tab('A|NOT A\FALSE|TRUE\TRUE|FALSE')
        else if Cap = 'AND' then Tab('A|B|A AND B\FALSE|FALSE|FALSE\FALSE|TRUE|FALSE\TRUE|FALSE|FALSE\TRUE|TRUE|TRUE')
        else if Cap = 'OR' then Tab('A|B|A OR B\FALSE|FALSE|FALSE\FALSE|TRUE|TRUE\TRUE|FALSE|TRUE\TRUE|TRUE|TRUE')
        else Tab('A|B|A XOR B\FALSE|FALSE|FALSE\FALSE|TRUE|TRUE\TRUE|FALSE|TRUE\TRUE|TRUE|FALSE');
        if Cap = 'AND' then
        begin
          Head('With a Word: a mask');
          Bits('IN = 16#5AF3=' + BinMark($5AF3, 16, -1, -1) + '\mask 16#00FF=' + BinMark($00FF, 16, -1, -1) + '\IN AND 16#00FF = 16#00F3=' +
            BinMark($00F3, 16, 0, 7), 'only the low byte stays');
        end;
        if Cap = 'AND' then Example('"Motor" := "Start" AND "Door_Closed";\#Low := "Status" AND 16#00FF;', '')
        else if Cap = 'OR' then Example('"Alarm" := "Overload" OR "Over_Temp";', '')
        else if Cap = 'XOR' then Example('"Changed" := "Input" XOR #Last;\#Last := "Input";', 'TRUE in the cycle where the input changed.')
        else Example('"Ready" := NOT "Fault";', '');
        Txt('In LAD: AND = contacts in series, OR = contacts in parallel (a branch), NOT = an NC contact or -|NOT|-.');
      end;
    '=', '<>', '<', '<=', '>', '>=':
      begin
        Summary('Compares two values and gives a Bool: TRUE when the comparison holds. Both sides have the same data type ' +
          '(Int with Int, Real with Real ..).');
        Syntax('<value> ' + Cap + ' <value>');
        HowTo(['Use it as a condition (IF "Level" ' + Cap + ' 50.0 THEN) or assign it to a Bool.']);
        Head('Values');
        Tab('A|B|A ' + Cap + ' B\' + Format('5|3|%s\3|3|%s\2|3|%s', [
          BoolToStr((Cap = '<>') or (Cap = '>') or (Cap = '>='), 'TRUE', 'FALSE'),
          BoolToStr((Cap = '=') or (Cap = '<=') or (Cap = '>='), 'TRUE', 'FALSE'),
          BoolToStr((Cap = '<>') or (Cap = '<') or (Cap = '<='), 'TRUE', 'FALSE')]));
        Example('"High" := "Level" ' + Cap + ' 80.0;', '');
        Notes(['Do not compare two Real values with = : 0.1 + 0.2 is not exactly 0.3. Use ABS(#a - #b) < 0.001.',
          'In LAD the CMP box does the same.']);
      end;
  else
    begin
      case Cap of
        '+': Summary('Adds two numbers (also Time + Time, DTL / Date + Time on the S7-1200/1500).');
        '-': Summary('Subtracts the right number from the left one; before a number it is the sign (-#x).');
        '*': Summary('Multiplies two numbers.');
        '/': Summary('Divides the left number by the right one. With integers the result is cut (7 / 2 = 3); a division by 0 ' +
          'gives 0 and ENO = FALSE.');
        'MOD': Summary('The remainder of an integer division: 7 MOD 3 = 1. Typical: every n-th thing (#i MOD 10 = 0).');
      else
        Summary('The power: the left number to the power of the right one; the result is a Real. 2 ** 3 = 8.0.');
      end;
      Syntax('<value> ' + Cap + ' <value>');
      HowTo(['Both sides have the same type (Int with Int, Real with Real); else convert one: INT_TO_REAL(#i) * 1.5.']);
      Head('Values');
      case Cap of
        '+': Tab('A|B|A + B\5|3|8\32767|1|-32768 (Int wraps)\T#1S|T#500MS|T#1S500MS');
        '-': Tab('A|B|A - B\5|3|2\3|5|-2\T#2S|T#500MS|T#1S500MS');
        '*': Tab('A|B|A * B\5|3|15\2.5|4.0|10.0\300|200|-5536 (Int wraps: use DInt)');
        '/': Tab('A|B|A / B\7|2|3\7.0|2.0|3.5\5|0|0 (ENO = FALSE)');
        'MOD': Tab('A|B|A MOD B\7|3|1\10|5|0\-7|3|-1');
      else
        Tab('A|B|A ** B\2|3|8.0\9.0|0.5|3.0\10|-1|0.1');
      end;
      Example('"Total" := "Count_A" ' + Cap + ' "Count_B";', '');
      Notes(['An integer result that does not fit wraps around: use DInt (or Real) for large values.']);
    end;
  end;
end;

procedure SclConst(const E: TSclElem);
begin
  Summary(E.Descr);
  Syntax(ElemText(E.Snip));
  HowTo(['Insert it and change the value; a constant can stand wherever a value of its type is expected.']);
  Head('Forms');
  case E.Cap of
    'TRUE', 'FALSE': Tab('Constant|Value\TRUE|1\FALSE|0\BOOL#1|TRUE');
    'T#1S (Time)': Tab('Constant|Meaning\T#2S|2 seconds\T#500MS|0.5 s\T#1M30S|90 s\T#1H|1 hour\T#2D3H|2 days 3 hours\T#-5S|minus 5 s');
    'LT#1MS (LTime)': Tab('Constant|Meaning\LT#1MS|1 ms\LT#500US|500 µs\LT#100NS|100 ns');
    'S5T#1S (S5Time)': Tab('Constant|Meaning\S5T#2S|2 s\S5T#100MS|0.1 s\S5T#2H46M30S|the largest');
    'D#2024-01-01 (Date)': Tab('Constant|Meaning\D#2024-01-01|1 January 2024\DATE#1990-01-01|the first date');
    'TOD#12:00:00 (Time_Of_Day)': Tab('Constant|Meaning\TOD#12:00:00|noon\TOD#06:30:00.500|6:30:00.5');
    'DT#2024-01-01-12:00:00': Tab('Constant|Meaning\DT#2024-01-01-12:00:00|1 Jan 2024, noon');
    '16#FF (hex)', '8#17 (octal)', '2#1010 (binary)': Tab('Constant|Decimal\16#FF|255\16#1A|26\8#17|15\2#1010|10\2#1111_0000|240 (_ for reading)');
    'W#16#0000 (Word)': Tab('Constant|Type\B#16#FF|Byte\W#16#00FF|Word\DW#16#0000_FFFF|DWord\LW#16#..|LWord');
    'INT#5 (typed)': Tab('Constant|Type\INT#5|Int\DINT#-1|DInt\REAL#1.5|Real\USINT#200|USInt\WORD#16#FF|Word');
    'CHAR#''A''': Tab('Constant|Code\CHAR#''A''|16#41\''$N''|a new line');
  else
    Tab('Literal|Meaning\''Hello''|5 characters\''''|empty\''It$''s''|a quote: $''\''A$NB''|a new line: $N\''$T''|a tab');
  end;
  Example('"Delay_PT" := T#2S;\"Mask" := 16#00FF;\"Text" := ''Ready'';', '');
end;

procedure SclType(const Cap: string);
var
  Rng, Fam, Ex, Sz: string;
begin
  Fam := 'all CPUs';
  case Cap of
    'Bool': begin Rng := 'FALSE, TRUE'; Sz := '1 bit'; Ex := 'Running : Bool := FALSE;'; end;
    'Byte': begin Rng := '16#00 .. 16#FF'; Sz := '8 bits'; Ex := 'Status : Byte;'; end;
    'Word': begin Rng := '16#0000 .. 16#FFFF'; Sz := '16 bits'; Ex := 'Flags : Word;'; end;
    'DWord': begin Rng := '16#0000_0000 .. 16#FFFF_FFFF'; Sz := '32 bits'; Ex := 'Mask : DWord;'; end;
    'LWord': begin Rng := '16#0 .. 16#FFFF_FFFF_FFFF_FFFF'; Sz := '64 bits'; Fam := 'S7-1500'; Ex := 'Bits : LWord;'; end;
    'SInt': begin Rng := '-128 .. 127'; Sz := '8 bits'; Fam := 'S7-1200/1500'; Ex := 'Offset : SInt;'; end;
    'Int': begin Rng := '-32768 .. 32767'; Sz := '16 bits'; Ex := 'Count : Int := 0;'; end;
    'DInt': begin Rng := '-2147483648 .. 2147483647'; Sz := '32 bits'; Ex := 'Total : DInt;'; end;
    'LInt': begin Rng := '-9.2E18 .. 9.2E18'; Sz := '64 bits'; Fam := 'S7-1500'; Ex := 'Big : LInt;'; end;
    'USInt': begin Rng := '0 .. 255'; Sz := '8 bits'; Fam := 'S7-1200/1500'; Ex := 'Step : USInt;'; end;
    'UInt': begin Rng := '0 .. 65535'; Sz := '16 bits'; Fam := 'S7-1200/1500'; Ex := 'Pieces : UInt;'; end;
    'UDInt': begin Rng := '0 .. 4294967295'; Sz := '32 bits'; Fam := 'S7-1200/1500'; Ex := 'Seconds : UDInt;'; end;
    'ULInt': begin Rng := '0 .. 1.8E19'; Sz := '64 bits'; Fam := 'S7-1500'; Ex := 'Ns : ULInt;'; end;
    'Real': begin Rng := '±1.2E-38 .. ±3.4E38 (7 digits)'; Sz := '32 bits'; Ex := 'Temp : Real := 20.0;'; end;
    'LReal': begin Rng := '±2.2E-308 .. ±1.8E308 (15 digits)'; Sz := '64 bits'; Fam := 'S7-1200/1500'; Ex := 'Exact : LReal;'; end;
    'Time': begin Rng := 'T#-24D20H31M23S648MS .. T#24D20H31M23S647MS (ms)'; Sz := '32 bits'; Ex := 'Delay : Time := T#5S;'; end;
    'LTime': begin Rng := 'LT#-106751D .. LT#106751D (ns)'; Sz := '64 bits'; Fam := 'S7-1500'; Ex := 'Fine : LTime := LT#1MS;'; end;
    'S5Time': begin Rng := 'S5T#0MS .. S5T#2H46M30S'; Sz := '16 bits (BCD with a time base)'; Fam := 'S7-300/400'; Ex := 'T_Val : S5Time := S5T#2S;'; end;
    'Date': begin Rng := 'D#1990-01-01 .. D#2168-12-31'; Sz := '16 bits (days)'; Ex := 'Today : Date;'; end;
    'Time_Of_Day': begin Rng := 'TOD#00:00:00 .. TOD#23:59:59.999'; Sz := '32 bits (ms)'; Ex := 'Start_At : Time_Of_Day := TOD#06:00:00;'; end;
    'LTime_Of_Day': begin Rng := 'LTOD#00:00:00 .. LTOD#23:59:59.999999999'; Sz := '64 bits (ns)'; Fam := 'S7-1500'; Ex := 'At : LTime_Of_Day;'; end;
    'Date_And_Time': begin Rng := 'DT#1990-01-01-00:00:00 .. DT#2089-12-31-23:59:59.999'; Sz := '8 bytes (BCD)'; Ex := 'Stamp : Date_And_Time;'; end;
    'LDT': begin Rng := 'LDT#1970-01-01-00:00:00 .. LDT#2262-04-11-23:47:16'; Sz := '64 bits (ns since 1970)'; Fam := 'S7-1500'; Ex := 'Stamp : LDT;'; end;
    'Char': begin Rng := 'one ASCII character'; Sz := '8 bits'; Ex := 'Key : Char := ''A'';'; end;
  else
    begin Rng := 'one Unicode character'; Sz := '16 bits'; Fam := 'S7-1200/1500'; Ex := 'Letter : WChar;'; end;
  end;
  Summary('The elementary data type ' + Cap + '. It is used in declarations: the interface of a block, the variables of a ' +
    'data block, a VAR_TEMP, a PLC tag.');
  Head('The type');
  Tab('Property|Value\Size|' + Sz + '\Range|' + Rng + '\CPUs|' + Fam);
  Syntax('<name> : ' + Cap + ';\<name> : ' + Cap + ' := <start value>;');
  HowTo(['Insert the type name into a declaration (VAR_TEMP .. END_VAR at the top of the network), or type it in the Data ' +
    'type column of the interface / the DB / the tag table.']);
  Example('VAR_TEMP\    ' + Ex + '\END_VAR', '');
  Notes(['Values of different types do not mix: convert with X_TO_Y (INT_TO_REAL ..).', 'On a CPU that does not have the type ' +
    'the compiler says so.']);
end;

procedure SclCType(const Cap: string);
begin
  case Cap of
    'Array[..] of':
      begin
        Summary('An array: many values of one type under one name, reached by an index. Array[0..9] of Int holds 10 Int: ' +
          'Arr[0] .. Arr[9]. The index may be a variable: "DB".Arr[#i].');
        Syntax('<name> : Array[<lo>..<hi>] of <type>;');
        HowTo(['Declare it in a DB or the interface; on the Data blocks screen an array opens (the mark) to show its ' +
          'elements with their own start values.', 'Use it with an index: "Data".Arr[3], "Data".Arr[#i] in a FOR loop.']);
        Example('// "Data": Val : Array[0..9] of Int\FOR #i := 0 TO 9 DO\    "Data".Val[#i] := 0;\END_FOR;', 'Clears the whole array.');
        Notes(['An index outside lo .. hi is an error at run time (the CPU stops or OB121).', 'Array of Bool packs 8 values into a byte.']);
      end;
    'Array[.., ..] of':
      begin
        Summary('An array of two dimensions: Array[0..2, 0..3] of Int is 3 rows of 4 values; Arr[1, 2] is row 1, column 2. ' +
          'In memory the last index runs fastest.');
        Syntax('<name> : Array[<lo1>..<hi1>, <lo2>..<hi2>] of <type>;');
        HowTo(['Declare it like a one-dimensional array; give both indexes when it is used.']);
        Head('The elements in memory');
        Tab('Arr|[.., 0]|[.., 1]|[.., 2]|[.., 3]\[0, ..]|0|1|2|3\[1, ..]|4|5|6|7\[2, ..]|8|9|10|11');
        Example('"Table".Cell[#Row, #Col] := #Value;', '');
      end;
    'Struct':
      begin
        Summary('A structure: several members of different types under one name: Motor.Speed, Motor.Running. In the ' +
          'Data blocks screen and the interface a struct opens to its members with their addresses.');
        Syntax('<name> : Struct\    <member> : <type>;\    ..\END_STRUCT;');
        HowTo(['Declare it in a DB or an interface (in an .scl source as text).',
          'For a struct used many times make a PLC data type (TYPE / UDT) instead.']);
        Example('// a DB variable Motor : Struct Speed : Int; Running : Bool; END_STRUCT\IF "Plant".Motor.Running THEN\    "Plant".Motor.Speed := 1500;\END_IF;', '');
      end;
    'String[n]', 'WString[n]':
      begin
        Summary('A text of at most n characters (n <= 254). A String needs n + 2 bytes: the maximum, the current length, ' +
          'the characters. WString holds Unicode characters (S7-1200/1500).');
        Syntax('<name> : ' + Copy(Cap, 1, Pos('[', Cap)) + '20];');
        HowTo(['Declare it; work with it through LEN, CONCAT, LEFT, RIGHT, MID, FIND.']);
        Head('In memory');
        Tab('Byte|0|1|2|3|4\Content|max (20)|length (3)|''A''|''B''|''C''');
        Example('#Msg := CONCAT(IN1 := ''Tank '', IN2 := "Tank_No");', '');
      end;
    'DTL':
      begin
        Summary('Date and time long (12 bytes, S7-1200/1500): the members YEAR, MONTH, DAY, WEEKDAY, HOUR, MINUTE, SECOND, ' +
          'NANOSECOND. The clock of the CPU is read into a DTL.');
        Head('The members');
        Tab('Member|Type|Values\YEAR|UInt|1970 .. 2262\MONTH|USInt|1 .. 12\DAY|USInt|1 .. 31\WEEKDAY|USInt|1 = Sunday .. 7\HOUR|USInt|0 .. 23\' +
          'MINUTE|USInt|0 .. 59\SECOND|USInt|0 .. 59\NANOSECOND|UDInt|0 .. 999999999');
        Syntax('<name> : DTL;');
        HowTo(['Declare it, then use the members: #Now.HOUR.']);
        Example('IF ("Clock".Now.HOUR >= 22) OR ("Clock".Now.HOUR < 6) THEN\    "Night" := TRUE;\END_IF;', '');
      end;
    'IEC_TIMER / TON_TIME':
      begin
        Summary('The data type of a timer instance. TON_TIME, TOF_TIME, TP_TIME, TONR_TIME (or IEC_TIMER, which can run any ' +
          'of them) hold PT, ET, IN and Q of one timer.');
        Syntax('Delay : TON_TIME;        // a Static of the FB\Timer : IEC_TIMER;       // in a DB: "DB".Timer.TON(..)');
        HowTo(['Declare the instance, then call it: #Delay(IN := .., PT := ..); see the Timers category.']);
        Head('The members');
        Tab('Member|Type|Meaning\PT|Time|the preset\ET|Time|the elapsed time\IN|Bool|the input\Q|Bool|the output');
        Example('#Delay(IN := "Start", PT := T#3S);\"Lamp" := #Delay.Q;', '');
      end;
  else
    begin
      Summary('The data type of a counter instance: CTU_INT, CTD_INT, CTUD_INT (and the DInt / UDInt .. kinds) or ' +
        'IEC_COUNTER hold CU, CD, R, LD, PV, CV, Q / QU / QD of one counter.');
      Syntax('Count : CTU_INT;         // a Static of the FB\Counter : IEC_COUNTER;    // in a DB: "DB".Counter.CTU(..)');
      HowTo(['Declare the instance, then call it; see the Counters category.']);
      Head('The members');
      Tab('Member|Type|Meaning\CU / CD|Bool|count up / down\R / LD|Bool|reset / load\PV|Int|the preset\CV|Int|the value\QU / QD|Bool|the outputs');
      Example('#Count(CU := "Sensor", R := "Reset", PV := 10);\"Full" := #Count.Q;', '');
    end;
  end;
end;

procedure SclDecl(const E: TSclElem);
var
  Rows: string;
begin
  case E.Cap of
    'VAR_INPUT': Summary('The inputs of an FC / FB: the caller gives them (In := ..); inside the block they are read.');
    'VAR_OUTPUT': Summary('The outputs of an FC / FB: the block writes them, the caller reads them (Out => ..).');
    'VAR_IN_OUT': Summary('In / out parameters: the caller gives a variable; the block reads and writes it (by reference).');
    'VAR (static)': Summary('Static variables of an FB: they keep their value from cycle to cycle in the instance DB. ' +
      'Timers, counters, edges and multi-instances of an FB are Statics.');
    'VAR RETAIN': Summary('Static variables that keep their value over a power failure (retentive).');
    'VAR_TEMP': Summary('Temporary variables: they live only while the block runs (no value from the last cycle). In this ' +
      'editor a VAR_TEMP section at the top of an SCL network declares #tmp for that network.');
  else
    Summary('Local constants: a name for a fixed value (#C_MAX); they cannot be written.');
  end;
  Syntax(ElemText(E.Snip));
  HowTo(['In the program editor the interface table above the networks has these sections (+ Input, + Output ..); add a ' +
    'row there instead of typing the section.',
    'In an .scl source (Import .scl) the sections are written as text; VAR_TEMP / VAR CONSTANT also at the top of an SCL network.']);
  Head('The sections');
  Rows := 'Section|Who writes|Keeps its value|Blocks\VAR_INPUT|the caller|FB: yes, FC: no|FC, FB\VAR_OUTPUT|the block|FB: yes|FC, FB\' +
    'VAR_IN_OUT|both|-|FC, FB\VAR|the block|yes|FB\VAR_TEMP|the block|no|all\VAR CONSTANT|nobody|-|all';
  Tab(Rows);
  Example(ElemText(E.Snip), '');
end;

procedure SclTemplate(const E: TSclElem);
begin
  case E.Cap of
    'FUNCTION (FC)': Summary('A function: a block without memory of its own. It works with its parameters and ' +
      'temps; a value it must keep goes to a DB. ": Void" has no return value, ": Int" returns an Int (#Ret_Val).');
    'FUNCTION_BLOCK (FB)': Summary('A function block: a block with memory (its instance DB). Timers, counters, ' +
      'sequences live in FBs. Every call has its own instance.');
    'ORGANIZATION_BLOCK (OB)': Summary('An organization block: the CPU calls it (OB1 every cycle, OB100 at the start, OB35 ' +
      'every 100 ms ..). It is not called from the program.');
    'DATA_BLOCK (global)': Summary('A global data block: variables that every block can read and write ("DB".Var).');
    'DATA_BLOCK (instance)': Summary('The instance data block of an FB: the memory of one call of the FB.');
  else
    Summary('A PLC data type (UDT): a struct with a name, used as the type of many variables ("Valve_T").');
  end;
  Syntax(ElemText(E.Snip));
  HowTo(['These templates are for an .scl source file: write the block as text, then Import .scl (SCL source ▼ under the ' +
    'blocks) makes the block, the DB or the type.',
    'In the editor itself blocks are made with + FC / + FB / + OB, DBs and types on the Data blocks screen.']);
  Example(ElemText(E.Snip), '');
end;

procedure SclSlice(const Cap: string);
begin
  Summary('Reaches a part of a bit string or an integer by its number: .%X3 is bit 3, .%B0 the least significant byte, .%W1 ' +
    'the upper word of a DWord, .%D0 a DWord of an LWord. It can be read and written.');
  Syntax('<operand>.%X<n>    <operand>.%B<n>    <operand>.%W<n>    <operand>.%D<n>');
  HowTo(['Type it after the operand: "Status".%X3, #w.%B1.']);
  Head('The bits');
  Bits('"Status" = 16#5AF3=' + BinMark($5AF3, 16, 3, 3) + '\.%X3 = TRUE (bit 3)=' + BinMark($5AF3, 16, 3, 3) + '\.%B0 = 16#F3=' +
    BinMark($5AF3, 16, 0, 7) + '\.%B1 = 16#5A=' + BinMark($5AF3, 16, 8, 15), 'bit 0 is on the right');
  Example('"Motor_Fault" := "Status".%X3;\#Low := "Status".%B0;', '');
end;

procedure SclOperand(const E: TSclElem);
begin
  Summary(E.Descr);
  case E.Cap of
    '"Tag"': begin Syntax('"Name"'); HowTo(['Type the name of a PLC tag in quotes; Ctrl+Space completes it; the Variables tab ' +
      'of the right panel lists the tags to drag in.']); Example('"Motor" := "Start_PB";', ''); end;
    '"DB".Var': begin Syntax('"DB_Name".Variable'); HowTo(['The DB name in quotes, a point, the variable; struct members ' +
      'with more points: "Plant".Inlet.Open.']); Example('"Recipe".Temp := 72.5;', ''); end;
    '"DB".Arr[#i]': begin Syntax('"DB".Arr[<index>]'); HowTo(['The index is a constant or an integer variable.']);
      Example('"Data".Val[#i] := 0;', ''); end;
    '#local': begin Syntax('#Name'); HowTo(['The # marks a variable of this block: a parameter, a Static, a Temp. Drag a ' +
      'row of the interface by its grip into the code.']); Example('#Count := #Count + 1;', ''); end;
    '%MW20': begin Syntax('%I0.0  %Q4.1  %MB10  %MW20  %MD30  %IW64  %DB1.DBW0'); HowTo(['An absolute address: the area, ' +
      'the size (X bit, B byte, W word, D double word) and the byte (.bit).']);
      Tab('Address|Meaning\%I0.0|input bit\%Q4.1|output bit\%MW20|memory word (bytes 20, 21)\%IW64|an analog input word\%DB1.DBX0.0|bit 0.0 of DB1');
      Example('%MW20 := %IW64;', ''); end;
    'FC call': begin Syntax('"FC_Name"(In1 := .., In2 := .., Out1 => ..);\#y := "FC_Name"(..);   // an FC with a return value');
      HowTo(['Inputs with :=, outputs with =>; every parameter of an FC must be given.',
        'The FCs of the project are in the category Project: Functions (FC) with their parameters.']);
      Example('"Scale"(Raw := "AI_Level", Lo := 0.0, Hi := 5.0, Out => "Level_m");', ''); end;
  else
    begin Syntax('"Instance_DB"(In := .., Out => ..);\#Multi(In := ..);   // a Static of the FB type');
      HowTo(['Give the instance DB of the FB (+ Instance DB in the interface) or call a multi-instance (a Static of the FB ' +
        'type).', 'Inputs left out keep their last value.']);
      Example('"Motor1_DB"(Start := "Start_PB", Stop := "Stop_PB", Run => "Motor1");', ''); end;
  end;
end;

{ ---------- LAD ---------- }

procedure LadBit(K: TLadKind);
begin
  case K of
    lkNO:
      begin
        Summary('Normally open contact: the power goes through when the operand is TRUE (1). Contacts in series are an ' +
          'AND, contacts in parallel (a branch) an OR.');
        Syntax('-| |-   with the operand above it (a Bool: %I0.0, "Start", #In, "DB".Flag)');
        HowTo(['Put it on the rung from the left; type the operand above it (or drag a tag / a variable onto it).']);
        Lad('no "Start";no "Door_Closed"!;-;coil "Motor"\no "Jog";-', '"Motor" := ("Start" AND "Door_Closed") OR "Jog"');
        Head('Truth table');
        Tab('operand|power in|power out\0|1|0\1|1|1\any|0|0');
      end;
    lkNC:
      begin
        Summary('Normally closed contact: the power goes through when the operand is FALSE (0). Typical: a stop button ' +
          '(wired NC) or "not in fault".');
        Syntax('-|/|-   with the operand above it');
        HowTo(['Put it on the rung; type the operand above it.']);
        Lad('no "Start";nc "Stop";nc "Overload";coil "Motor"', '"Motor" := "Start" AND NOT "Stop" AND NOT "Overload"');
        Head('Truth table');
        Tab('operand|power in|power out\0|1|1\1|1|0\any|0|0');
      end;
    lkPos, lkNeg:
      begin
        if K = lkPos then Summary('Rising edge contact: the power goes through for one cycle when the operand goes from 0 ' +
          'to 1. The edge memory bit below it keeps the old value.')
        else Summary('Falling edge contact: the power goes through for one cycle when the operand goes from 1 to 0.');
        Syntax('-|' + IfThen(K = lkPos, 'P', 'N') + '|-   the operand above, the edge memory bit below (a bit used for nothing else)');
        HowTo(['Type the operand above it and a free memory bit below it (%M10.0, "Edge_Start", a Static).']);
        Lad(IfThen(K = lkPos, 'p', 'n') + ' "Button"|"Edge_M";coil "Pulse"', '');
        Head('Timing diagram');
        if K = lkPos then Wave('Button=0011110001100000\power out=0010000001000000', '')
        else Wave('Button=0011110001100000\power out=0000001000010000', '');
        Notes(['Every edge contact needs its own edge memory bit.']);
      end;
    lkNot:
      begin
        Summary('Inverts the power flow: no power in gives power out and the other way round.');
        Syntax('-|NOT|-');
        HowTo(['Put it after the contacts whose result is to be inverted.']);
        Lad('no "A";no "B";not;coil "Not_Both"', '"Not_Both" := NOT ("A" AND "B")');
      end;
    lkWire:
      begin
        Summary('A piece of the rung: the power goes through. A wire fills the cells between the contacts and the coil.');
        Syntax('---');
        HowTo(['Put it on an empty cell between elements; + Row and the branch button make parallel branches.']);
        Lad('no "A";-;-;coil "Q"', '');
      end;
    lkCoil:
      begin
        Summary('Coil: the operand gets the power of the rung: TRUE while the power is on, FALSE when it is off. Every ' +
          'cycle it is written.');
        Syntax('-( )-   with the operand above it');
        HowTo(['Put it at the end of the rung, type the operand above it.']);
        Lad('no "Start";nc "Stop";coil "Motor"', '');
        Notes(['Write an output with one coil only; two coils of the same operand: the last one wins.']);
      end;
    lkCoilNeg:
      begin
        Summary('Negated coil: the operand gets the inverted power: FALSE while the power is on, TRUE when it is off.');
        Syntax('-(/)-');
        HowTo(['Put it at the end of the rung.']);
        Lad('no "Fault";ncoil "Ready"', '"Ready" := NOT "Fault"');
      end;
    lkSet:
      begin
        Summary('Set coil: while the power is on the operand becomes TRUE; when the power goes off it stays TRUE. Only a ' +
          'reset coil (or another write) makes it FALSE again.');
        Syntax('-(S)-');
        HowTo(['Put it at the end of a rung; reset the same operand in another rung with -(R)-.']);
        Lad('no "Start";set "Motor"\no "Stop";reset "Motor"', 'start sets, stop resets (the later rung wins)');
        Head('Timing diagram');
        Wave('Start=0110000001100000\Stop=0000011000000110\Motor=0111100001111000', '');
      end;
  else
    begin
      Summary('Reset coil: while the power is on the operand becomes FALSE (a timer / counter is reset). It stays FALSE ' +
        'when the power goes off.');
      Syntax('-(R)-');
      HowTo(['Put it at the end of a rung; the set is in another rung.']);
      Lad('no "Start";set "Motor"\no "Stop";reset "Motor"', '');
      Notes(['The rung that comes later in the cycle wins: put the reset after the set, so that the stop wins.']);
    end;
  end;
  Txt('Equivalent in SCL and STL:');
  case K of
    lkNO: Code('SCL: "Motor" := ("Start" AND "Door_Closed") OR "Jog";\STL: A( \     A "Start"\     A "Door_Closed"\     )\     O "Jog"\     = "Motor"');
    lkNC: Code('SCL: "Motor" := "Start" AND NOT "Stop" AND NOT "Overload";\STL: A "Start"  AN "Stop"  AN "Overload"  = "Motor"');
    lkPos: Code('STL: A "Button"\     FP "Edge_M"\     = "Pulse"');
    lkNeg: Code('STL: A "Button"\     FN "Edge_M"\     = "Pulse"');
    lkSet, lkReset: Code('SCL: IF "Start" THEN "Motor" := TRUE; END_IF;\     IF "Stop" THEN "Motor" := FALSE; END_IF;\STL: A "Start"  S "Motor"  A "Stop"  R "Motor"');
    lkCoil: Code('SCL: "Motor" := "Start" AND NOT "Stop";');
    lkCoilNeg: Code('SCL: "Ready" := NOT "Fault";');
    lkNot: Code('SCL: "Not_Both" := NOT ("A" AND "B");');
  else
    Code('SCL: "Q" := "A";');
  end;
end;

procedure LadCmp(Cmp: Integer);
var
  Op, Sym: string;
begin
  case Cmp of
    1: begin Op := '=='; Sym := '='; end;
    2: begin Op := '<>'; Sym := '<>'; end;
    3: begin Op := '>'; Sym := '>'; end;
    4: begin Op := '<'; Sym := '<'; end;
    5: begin Op := '>='; Sym := '>='; end;
  else
    begin Op := '<='; Sym := '<='; end;
  end;
  Summary('A comparison contact: the power goes through when IN1 ' + Op + ' IN2 holds. The data type (Int, DInt, Real, Time ..) ' +
    'is chosen in the box; both inputs have it.');
  Syntax('a box like a contact: IN1 above, IN2 below; the operator and the type in it');
  Params('IN1|Int / Real / ..|the first value\IN2|the same type|the second value (or a constant)');
  HowTo(['Put it on the rung like a contact, then the coil.', 'Click it: type IN1 and IN2, choose the type.']);
  Lad('cmp@Int=' + Op + ' "Level"|80;coil "High"', '"High" := "Level" ' + Sym + ' 80');
  Head('Values');
  Tab('IN1|IN2|power\' + Format('90|80|%s\80|80|%s\70|80|%s', [
    BoolToStr(Cmp in [2, 3, 5], 'on', 'off'), BoolToStr(Cmp in [1, 5, 6], 'on', 'off'), BoolToStr(Cmp in [2, 4, 6], 'on', 'off')]));
  Txt('The same in SCL:');
  Code('"High" := "Level" ' + Sym + ' 80;');
  Notes(['Two comparisons in series make a range: >= MIN and <= MAX (or IN_RANGE).']);
end;

procedure LadArith(K: TLadKind);
var
  Nm, Op, Sum: string;
begin
  Nm := LadKindNames[K];
  case K of
    lkAdd: begin Op := '+'; Sum := 'Adds: OUT := IN1 + IN2.'; end;
    lkSub: begin Op := '-'; Sum := 'Subtracts: OUT := IN1 - IN2.'; end;
    lkMul: begin Op := '*'; Sum := 'Multiplies: OUT := IN1 * IN2.'; end;
    lkDiv: begin Op := '/'; Sum := 'Divides: OUT := IN1 / IN2 (integers: the decimals are cut; / 0: ENO = 0).'; end;
    lkMod: begin Op := 'MOD'; Sum := 'The remainder of the integer division: OUT := IN1 MOD IN2.'; end;
    lkExpt: begin Op := '**'; Sum := 'The power: OUT := IN1 ** IN2 (a Real).'; end;
  end;
  FnPage(Nm, Sum + ' The data type is chosen in the box (Int, DInt, Real ..); all pins have it.',
    'IN1|number|the first value\IN2|number|the second value\OUT|number|the result',
    '', '"Total" := "Count_A" ' + Op + ' "Count_B";', 'no "Enable";' + LadKindIds[K] + '@Int "Count_A"|"Count_B"|"Total";-', '', '',
    'IN1|IN2|OUT\' + IfThen(K = lkMod, '7|3|1\10|5|0', IfThen(K = lkDiv, '7|2|3\8|0|0 (ENO = 0)', IfThen(K = lkExpt,
    '2.0|3.0|8.0', IfThen(K = lkMul, '6|7|42', IfThen(K = lkSub, '10|4|6', '5|3|8'))))), '', ['An Int result that does not fit ' +
    'wraps around (32767 + 1 = -32768): use DInt or Real for large values.', 'The box runs in every cycle while EN has power: ' +
    'for "once" use a P contact in front of it.']);
end;

procedure LadMisc(K: TLadKind);
begin
  case K of
    lkMove:
      FnPage('MOVE', 'Copies IN to OUT1 while the power is on (EN). IN may be a constant. The data type is chosen in the box.',
        'IN|any|the value\OUT1|the same type|the target', '', '"Speed_Set" := 1500;', 'no "Start";move@Int 1500|"Speed_Set";-', '', '',
        '', '', ['Without power the target keeps its value.']);
    lkNegate:
      FnPage('NEG', 'Changes the sign: OUT := -IN.', 'IN|number|the value\OUT|number|-IN', '', '"Minus" := -"Value";',
        'no "Enable";negate@Int "Value"|"Minus";-', '', '', 'IN|OUT\5|-5\-3|3', '', []);
    lkInc, lkDec:
      FnPage(LadKindNames[K], IfThen(K = lkInc, 'Adds 1 to the operand in every cycle while the power is on.',
        'Subtracts 1 from the operand in every cycle while the power is on.') + ' For once per event put a P contact in front.',
        'IN_OUT|integer|the operand that is changed', '', '"Count" := "Count" ' + IfThen(K = lkInc, '+', '-') + ' 1;',
        'p "Sensor"|"Edge_M";' + LadKindIds[K] + '@Int "Count";-', '', '', '', '', []);
    lkInRange, lkOutRange:
      begin
        Summary(IfThen(K = lkInRange, 'A contact box: the power goes through when MIN <= VAL <= MAX.',
          'A contact box: the power goes through when VAL < MIN or VAL > MAX.') + ' The data type is chosen in the box.');
        Params('MIN|number|the lower limit\VAL|number|the value\MAX|number|the upper limit');
        HowTo(['Put it on the rung like a contact; type MIN, VAL and MAX.']);
        Lad(IfThen(K = lkInRange, 'inrange', 'outrange') + '@Int 20|"Temp"|30;coil "' + IfThen(K = lkInRange, 'Temp_Ok', 'Temp_Alarm') + '"', '');
        Head('Values');
        Tab('MIN|VAL|MAX|power\20|25|30|' + IfThen(K = lkInRange, 'on', 'off') + '\20|35|30|' + IfThen(K = lkInRange, 'off', 'on'));
        Txt('The same in SCL:');
        if K = lkInRange then Code('"Temp_Ok" := ("Temp" >= 20) AND ("Temp" <= 30);')
        else Code('"Temp_Alarm" := ("Temp" < 20) OR ("Temp" > 30);');
      end;
    lkConv:
      FnPage('CONV', 'Converts IN from one data type into another (the types of IN and OUT are chosen in the box): Int to ' +
        'Real, Real to DInt (rounded), Word to Int ..', 'IN|the IN type|the value\OUT|the OUT type|the converted value', '',
        '"Speed_R" := INT_TO_REAL("Speed_I");', 'no "Enable";conv@Int>Real "Speed_I"|"Speed_R";-', '', '',
        'IN (Int)|OUT (Real)\5|5.0\-300|-300.0', '', ['A value the target cannot hold: ENO = 0.']);
    lkAndW, lkOrW, lkXorW, lkInvW:
      begin
        XHead := 'The bits';
        XCap := 'the bits of the result are red';
        case K of
          lkAndW: XBits := 'IN1 = 16#5AF3=' + BinMark($5AF3, 16, -1, -1) + '\IN2 = 16#00FF=' + BinMark($00FF, 16, -1, -1) + '\OUT = 16#00F3=' + BinMark($00F3, 16, 0, 7);
          lkOrW: XBits := 'IN1 = 16#5AF3=' + BinMark($5AF3, 16, -1, -1) + '\IN2 = 16#00FF=' + BinMark($00FF, 16, -1, -1) + '\OUT = 16#5AFF=' + BinMark($5AFF, 16, 0, 7);
          lkXorW: XBits := 'IN1 = 16#5AF3=' + BinMark($5AF3, 16, -1, -1) + '\IN2 = 16#00FF=' + BinMark($00FF, 16, -1, -1) + '\OUT = 16#5A0C=' + BinMark($5A0C, 16, 0, 7);
        else
          XBits := 'IN = 16#5AF3=' + BinMark($5AF3, 16, -1, -1) + '\OUT = 16#A50C=' + BinMark($A50C, 16, 0, 15);
        end;
        FnPage(LadKindNames[K], IfThen(K = lkInvW, 'Inverts every bit of IN.', 'Combines IN1 and IN2 bit by bit (' +
          LadKindNames[K] + ').') + ' The data type (Byte, Word, DWord) is chosen in the box.',
          IfThen(K = lkInvW, 'IN|Word|the bits\OUT|Word|NOT IN', 'IN1|Word|the bits\IN2|Word|the mask\OUT|Word|the result'), '',
          IfThen(K = lkInvW, '#Out := NOT "Status";', '#Out := "Status" ' + LadKindNames[K] + ' 16#00FF;'),
          'no "Enable";' + LadKindIds[K] + '@Word "Status"|' + IfThen(K = lkInvW, '#Out', '16#00FF|#Out') + ';-', '', '', '', '', []);
      end;
    lkCall:
      begin
        Summary('Calls an FC or an FB. The box shows the parameters of the block as pins: Inputs and InOuts on the left, ' +
          'Outputs and the return value on the right. EN = 0 skips the call.');
        Syntax('a box: the block (FC) or the instance DB of the FB above it; the pins are its parameters');
        HowTo(['Put a CALL on the rung, then type the FC name or the instance DB above it (or double click an FC / an ' +
          'instance DB in the category Project of this list: it comes with its pins).',
          'Fill in the pins in the properties panel; an FC needs every Input / Output / InOut.']);
        Lad('no "Enable";call "Motor1_DB";-;coil "Motor1_Run"', 'an FB with its instance DB');
        Txt('The same in SCL:');
        Code('"Motor1_DB"(Start := "Start_PB", Stop := "Stop_PB", Run => "Motor1");');
      end;
  end;
end;

procedure LadPage(const E: TSclElem);
var
  K: TLadKind;
  Nm: string;
begin
  K := TLadKind(E.Kind and 255);
  Nm := LadKindNames[K];
  case K of
    lkNO, lkNC, lkPos, lkNeg, lkNot, lkWire, lkCoil, lkCoilNeg, lkSet, lkReset: LadBit(K);
    lkRTrig: EdgePage('R_TRIG');
    lkFTrig: EdgePage('F_TRIG');
    lkRS: EdgePage('RS');
    lkSR: EdgePage('SR');
    lkTON: TimerPage('TON');
    lkTOF: TimerPage('TOF');
    lkTP: TimerPage('TP');
    lkTONR: TimerPage('TONR');
    lkSD: S5TimerPage('SD');
    lkSE: S5TimerPage('SE');
    lkSP: S5TimerPage('SP');
    lkSS: S5TimerPage('SS');
    lkSF: S5TimerPage('SF');
    lkCTU: CounterPage('CTU');
    lkCTD: CounterPage('CTD');
    lkCTUD: CounterPage('CTUD');
    lkCU: S5CounterPage('CU');
    lkCD: S5CounterPage('CD');
    lkSC: S5CounterPage('SC');
    lkCmp: LadCmp(E.Kind div 256);
    lkSel: SelectPage('SEL');
    lkMux: SelectPage('MUX');
    lkLimit: SelectPage('LIMIT');
    lkMin: SelectPage('MIN');
    lkMax: SelectPage('MAX');
    lkAdd, lkSub, lkMul, lkDiv, lkMod, lkExpt: LadArith(K);
    lkAbs, lkSqr, lkSqrt, lkExp, lkLn, lkSin, lkCos, lkTan, lkAsin, lkAcos, lkAtan, lkFrac: MathPage(Nm);
    lkRound, lkTrunc, lkCeil, lkFloor: RoundPage(Nm);
    lkNormX: ScalePage('NORM_X');
    lkScaleX: ScalePage('SCALE_X');
    lkShl, lkShr, lkRol, lkRor: ShiftPage(Nm);
    lkConcat, lkLen, lkLeft, lkRight, lkMid, lkFind, lkSMove: StringPage(Nm);
  else
    LadMisc(K);
  end;
end;

{ ---------- STL ---------- }

procedure StlBit(const E: TSclElem);
var
  Cap: string;
begin
  Cap := E.Cap;
  if (Cap = 'O') and (Pos(ElemCur, E.Snip) = 0) then Cap := 'O (empty)';
  Summary(E.Descr + ' STL works with the RLO (the result of logic operation): the first check of a sequence loads it, ' +
    'the following ones combine it, = / S / R write it.');
  case Cap of
    'A', 'AN', 'O', 'ON', 'X', 'XN':
      begin
        Syntax(Cap + '     <bit operand>      // %I0.0, "Start", #In, "DB".Flag, T 1, C 1');
        HowTo(['Write one check per line, then = (or S / R) with the output.']);
        Head('The RLO line by line');
        if Cap[1] = 'A' then
          Tab('Line|"Start"|"Door"|RLO after it\A     "Start"|1|1|1 (loaded)\' + Cap + '    "Door"|1|1|' + IfThen(Cap = 'A', '1', '0') +
            '\=     "Motor"|||"Motor" := RLO')
        else if Cap[1] = 'O' then
          Tab('Line|"Start"|"Jog"|RLO after it\A     "Start"|0|1|0\' + Cap + '    "Jog"|0|1|' + IfThen(Cap = 'O', '1', '0') +
            '\=     "Motor"|||"Motor" := RLO')
        else
          Tab('Line|"A"|"B"|RLO after it\A     "A"|1|1|1\' + Cap + '     "B"|1|1|' + IfThen(Cap = 'X', '0', '1') + '\=     "Q"|||"Q" := RLO');
        Head('The same in LAD');
        if (Cap = 'A') or (Cap = 'AN') then Lad('no "Start";' + IfThen(Cap = 'A', 'no', 'nc') + ' "Door";coil "Motor"', '')
        else if (Cap = 'O') or (Cap = 'ON') then Lad('no "Start"!;-;coil "Motor"\' + IfThen(Cap = 'O', 'no', 'nc') + ' "Jog"', '');
        Example('A     "Start"\' + Cap + '    "Door_Closed"\=     "Motor"', '');
      end;
    'A(', 'O(', ')':
      begin
        Syntax('A(\  O     "A"\  O     "B"\)\A     "C"\=     "Q"');
        HowTo(['Open the bracket, write the checks inside, close it with ); the bracket result is combined with the RLO ' +
          'before it.']);
        Head('The same in LAD');
        Lad('no "A"!;no "C";coil "Q"\no "B"', '"Q" := ("A" OR "B") AND "C"');
        Example('A(\O     "A"\O     "B"\)\A     "C"\=     "Q"', '');
      end;
    'O (empty)':
      begin
        Syntax('A     "A"\A     "B"\O\A     "C"\A     "D"\=     "Q"');
        HowTo(['An O without an operand between two AND groups: AND is done before OR.']);
        Lad('no "A";no "B"!;coil "Q"\no "C";no "D"', '"Q" := ("A" AND "B") OR ("C" AND "D")');
        Example('A     "A"\A     "B"\O\A     "C"\A     "D"\=     "Q"', '');
      end;
    '=', 'S', 'R':
      begin
        Syntax(Cap + '     <bit operand>');
        if Cap = '=' then HowTo(['Write it after the checks: the operand gets the RLO.'])
        else HowTo(['Write it after the checks: while the RLO is 1 the operand is ' + IfThen(Cap = 'S', 'set (TRUE)', 'reset (FALSE)') +
          '; it keeps the value when the RLO is 0.']);
        if Cap <> '=' then
        begin
          Head('Timing diagram');
          Wave('Start=0110000001100000\Stop=0000011000000110\Motor=0111100001111000', 'A "Start" S "Motor" / A "Stop" R "Motor"');
        end;
        Example('A     "Start"\S     "Motor"\A     "Stop"\R     "Motor"', '');
      end;
    'FP', 'FN':
      begin
        Syntax(Cap + '    <edge memory bit>');
        HowTo(['After the check of the signal: ' + Cap + ' with a memory bit used for nothing else; the RLO is 1 for one cycle ' +
          'at the ' + IfThen(Cap = 'FP', 'rising', 'falling') + ' edge.']);
        Head('Timing diagram');
        if Cap = 'FP' then Wave('"Button"=0011110001100000\RLO after FP=0010000001000000', '')
        else Wave('"Button"=0011110001100000\RLO after FN=0000001000010000', '');
        Example('A     "Button"\' + Cap + '    "Edge_M"\=     "Pulse"', '');
      end;
  else
    begin
      Syntax(Cap);
      HowTo(['Write it alone on a line.']);
      if Cap = 'NOT' then Example('A     "A"\A     "B"\NOT\=     "Not_Both"', '')
      else if Cap = 'SET' then Example('SET\=     "Always_On"', '')
      else Example('CLR\=     "Always_Off"', '');
    end;
  end;
end;

procedure StlAccu(const E: TSclElem);
begin
  Summary(E.Descr + ' The accumulators: ACCU 1 and ACCU 2 (S7-400: ACCU 1 .. 4) are the work registers of STL; L loads ' +
    'ACCU 1 (the old ACCU 1 moves to ACCU 2), the math works on both, T stores ACCU 1.');
  Syntax(ElemText(E.Snip) + IfThen(Pos(ElemCur, E.Snip) > 0, '<operand>', ''));
  HowTo(['Load the values with L, do the operation, transfer the result with T.']);
  Head('The accumulators line by line');
  case E.Cap of
    'TAK': Tab('Line|ACCU 1|ACCU 2\L     5|5|..\L     7|7|5\TAK|5|7');
    'PUSH', 'POP', 'ENT', 'LEAVE': Tab('Line|ACCU 1|ACCU 2\L     5|5|..\PUSH|5|5\POP|5|5');
    'CAW': Tab('Line|ACCU 1\L     W#16#1234|16#1234\CAW|16#3412');
    'CAD': Tab('Line|ACCU 1\L     DW#16#12345678|16#12345678\CAD|16#78563412');
    'OPN': Tab('Line|Meaning\OPN   DB 1|DB1 is the open data block\L     DBW 2|word 2 of DB1');
  else
    Tab('Line|ACCU 1|ACCU 2\L     "A" (= 5)|5|..\L     "B" (= 3)|3|5\+I|8|..\T     "Sum"|8 -> "Sum"|..');
  end;
  if E.Cap = 'OPN' then Example('OPN   DB 1\L     DBW 2\T     "Value"', '')
  else if E.Cap = 'LC' then Example('LC    T 1\T     "T1_BCD"', 'the time left of T1 as BCD')
  else Example('L     "A"\L     "B"\+I\T     "Sum"', '');
end;

procedure StlMath(const E: TSclElem);
var
  Ty: string;
begin
  Summary(E.Descr + ' The result is in ACCU 1; the status bits (OV, OS, CC0/1) tell an overflow or the sign.');
  Syntax(ElemText(E.Snip) + IfThen(Pos(ElemCur, E.Snip) > 0, '<value>', ''));
  if Pos('R', E.Cap) > 0 then Ty := 'Real' else if Pos('D', E.Cap) > 0 then Ty := 'DInt' else Ty := 'Int';
  HowTo(['L the first value, L the second one (both ' + Ty + '), then the instruction, then T the result.']);
  Head('The accumulators line by line');
  if E.Cap = '-I' then Tab('Line|ACCU 1|ACCU 2\L     10|10|..\L     4|4|10\-I|6 (= 10 - 4)|..')
  else if E.Cap = '*I' then Tab('Line|ACCU 1|ACCU 2\L     6|6|..\L     7|7|6\*I|42|..')
  else if E.Cap = '/I' then Tab('Line|ACCU 1|ACCU 2\L     7|7|..\L     2|2|7\/I|3 (= 7 / 2)|..')
  else if E.Cap = 'MOD' then Tab('Line|ACCU 1|ACCU 2\L     L#7|7|..\L     L#3|3|7\MOD|1|..')
  else if (E.Cap = 'SQR') or (E.Cap = 'SQRT') or (E.Cap = 'ABS') or (E.Cap = 'EXP') or (E.Cap = 'LN') or (E.Cap = 'SIN') or
    (E.Cap = 'NEGR') or (E.Cap = 'NEGI') then
    Tab('Line|ACCU 1\L     "Value" (= 2.0)|2.0\' + E.Cap + '|the result\T     "Result"|-> "Result"')
  else if (E.Cap = '+') or (E.Cap = 'INC') or (E.Cap = 'DEC') then Tab('Line|ACCU 1\L     "Count" (= 5)|5\' + E.Cap + ' 1|' +
    IfThen(E.Cap = 'DEC', '4', '6') + '\T     "Count"|-> "Count"')
  else Tab('Line|ACCU 1|ACCU 2\L     "A" (= 5)|5|..\L     "B" (= 3)|3|5\' + E.Cap + '|' + IfThen(Pos('-', E.Cap) > 0, '2', '8') + '|..');
  if (E.Cap = 'SQR') or (E.Cap = 'SQRT') or (E.Cap = 'ABS') or (E.Cap = 'EXP') or (E.Cap = 'LN') or (E.Cap = 'SIN') or
    (E.Cap = 'NEGR') or (E.Cap = 'NEGI') then
    Example('L     "Value"\' + E.Cap + '\T     "Result"', '')
  else if (E.Cap = '+') or (E.Cap = 'INC') or (E.Cap = 'DEC') then Example('L     "Count"\' + E.Cap + ' 1\T     "Count"', '')
  else Example('L     "A"\L     "B"\' + E.Cap + '\T     "Result"', '');
  Notes(['The types are not checked: +I adds the lower words as Int, +R the double words as Real. Load the right type.']);
end;

procedure StlCompare(const E: TSclElem);
begin
  Summary(E.Descr + ' The result of the comparison is the RLO: it can be combined (A ..) and written (=).');
  Syntax('L     <value 1>\L     <value 2>\' + E.Cap + '\=     <bit>');
  HowTo(['L both values, then the comparison; the RLO is TRUE when ACCU 2 ' + Copy(E.Cap, 1, Length(E.Cap) - 1) + ' ACCU 1.']);
  Head('The same in LAD');
  Lad('cmp@' + IfThen(E.Cap[Length(E.Cap)] = 'R', 'Real', 'Int') + '=' + Copy(E.Cap, 1, Length(E.Cap) - 1) + ' "Level"|80;coil "High"', '');
  Example('L     "Level"\L     80\' + E.Cap + '\=     "High"', '');
end;

procedure StlConvert(const E: TSclElem);
begin
  Summary(E.Descr + ' The conversion works on ACCU 1.');
  Syntax('L     <value>\' + E.Cap + '\T     <target>');
  HowTo(['L the value, the conversion, T the result into an operand of the new type.']);
  Head('Values');
  case E.Cap of
    'ITD': Tab('ACCU 1 before (Int)|after (DInt)\-5|-5\32767|32767');
    'DTR': Tab('ACCU 1 before (DInt)|after (Real)\100|100.0\-7|-7.0');
    'RND': Tab('before (Real)|RND|RND+|RND-|TRUNC\2.5|2|3|2|2\2.6|3|3|2|2\-2.6|-3|-2|-3|-2');
    'ITB': Tab('before (Int)|after (BCD)\123|W#16#0123\-45|W#16#F045');
  else
    Tab('before|after\W#16#00FF|W#16#FF00');
  end;
  Example('L     "Count_I"\ITD\DTR\T     "Count_R"', 'Int -> DInt -> Real (an Int to Real takes two steps).');
end;

procedure StlWord(const E: TSclElem);
begin
  Summary(E.Descr);
  Syntax(ElemText(E.Snip) + '<value>');
  if (E.Cap = 'AW') or (E.Cap = 'OW') or (E.Cap = 'XOW') then
  begin
    HowTo(['L the word, then ' + E.Cap + ' with a constant (or L a second word and ' + E.Cap + ' without one), T the result.']);
    Head('The bits');
    if E.Cap = 'AW' then Bits('ACCU 1 = 16#5AF3=' + BinMark($5AF3, 16, -1, -1) + '\AW W#16#00FF = 16#00F3=' + BinMark($00F3, 16, 0, 7), '')
    else if E.Cap = 'OW' then Bits('ACCU 1 = 16#5AF3=' + BinMark($5AF3, 16, -1, -1) + '\OW W#16#00FF = 16#5AFF=' + BinMark($5AFF, 16, 0, 7), '')
    else Bits('ACCU 1 = 16#5AF3=' + BinMark($5AF3, 16, -1, -1) + '\XOW W#16#00FF = 16#5A0C=' + BinMark($5A0C, 16, 0, 7), '');
    Example('L     "Status"\' + E.Cap + '    W#16#00FF\T     "Low_Byte"', '');
  end
  else
  begin
    HowTo(['L the value, ' + E.Cap + ' n (the number of places), T the result.']);
    Head('The bits');
    if E.Cap = 'SLW' then Bits('ACCU 1 = 16#00B3=' + BinMark($00B3, 16, -1, -1) + '\SLW 3 = 16#0598=' + BinMark($0598, 16, 0, 2), '')
    else if E.Cap = 'SRW' then Bits('ACCU 1 = 16#00B3=' + BinMark($00B3, 16, -1, -1) + '\SRW 3 = 16#0016=' + BinMark($0016, 16, 13, 15), '')
    else Bits('ACCU 1 = 16#8000_00B3=' + BinMark($800000B3, 32, -1, -1) + '\RLD 1 = 16#0000_0167=' + BinMark($00000167, 32, 0, 0), '');
    Example('L     "Pattern"\' + E.Cap + '   3\T     "Pattern"', '');
  end;
end;

procedure StlJump(const E: TSclElem);
begin
  Summary(E.Descr + ' A jump goes to a label in the same network: the lines between are skipped.');
  if E.Cap = 'label:' then Syntax('M001: <instruction>') else Syntax(E.Cap + '    <label>\..\<label>: ..');
  HowTo(['Write the jump with a label (up to 4 characters), and the same label with a colon before the line where it goes.']);
  Head('Flowchart');
  if E.Cap = 'LOOP' then Flow('loop|L 10 / T #n|#n <> 0|the lines of the loop|LOOP: #n - 1', '')
  else Flow('jump|' + E.Cap + '|the lines skipped|M001: the lines after the label', '');
  if E.Cap = 'LOOP' then
    Example('      L     10\NEXT: T     #n\      // the lines of the loop\      L     #n\      LOOP  NEXT', 'Runs the lines 10 times.')
  else if E.Cap = 'JU' then Example('      JU    M001\      L     1        // skipped\      T     "X"\M001: NOP 0', '')
  else Example('      A     "Manual"\      ' + E.Cap + '    M001\      L     "Speed_Auto"\      T     "Speed"\M001: NOP 0',
    'In manual the automatic speed is not written.');
end;

procedure StlBlocks(const E: TSclElem);
begin
  Summary(E.Descr);
  if Pos('CALL', E.Cap) = 1 then
  begin
    Syntax(ElemText(E.Snip));
    HowTo(['Give the FC (or the instance DB of the FB), then one parameter per line: Name := operand.',
      'The FCs / instance DBs of the project are in the category Project of this list.']);
    Example(StringReplace(StringReplace(ElemText(E.Snip), '"FC"', '"Scale"', []), '"Inst_DB"', '"Motor1_DB"', []) + '"Start_PB"', '');
  end
  else
  begin
    Syntax(E.Cap);
    HowTo(['Write it alone on a line.']);
    if E.Cap = 'BEC' then Example('A     "Not_Enabled"\BEC\// the rest of the block', 'leaves the block while "Not_Enabled"')
    else Example(E.Cap, '');
  end;
end;

procedure StlPage(const E: TSclElem);
var
  Cat, Nm: string;
begin
  Cat := E.Cat;
  if Cat = 'Bit logic' then StlBit(E)
  else if Cat = 'Load / transfer / accumulators' then StlAccu(E)
  else if Cat = 'Timers (S5)' then S5TimerPage(E.Cap)
  else if Cat = 'Counters (S5)' then S5CounterPage(E.Cap)
  else if (Cat = 'Integer math') or (Cat = 'Real math') then StlMath(E)
  else if Cat = 'Comparison' then StlCompare(E)
  else if Cat = 'Conversion' then StlConvert(E)
  else if Cat = 'Word logic / shift / rotate' then StlWord(E)
  else if Cat = 'Jumps' then StlJump(E)
  else if Cat = 'Blocks / calls' then StlBlocks(E)
  else if Cat = 'SCL functions (CALL)' then
  begin
    Nm := Copy(E.Cap, 6, MaxInt);
    if Pos(Nm, 'SEL MUX LIMIT MIN MAX') > 0 then SelectPage(Nm)
    else if (Nm = 'NORM_X') or (Nm = 'SCALE_X') then ScalePage(Nm)
    else if (Nm = 'SHL') or (Nm = 'ROL') then ShiftPage(Nm)
    else if Pos('_TO_', Nm) > 0 then ConvPage(Nm)
    else if MatchStr(Nm, ['READ_CLK', 'SET_CLK', 'RD_LOC_T', 'TIME_TCK']) then ClockPage(Nm)
    else StringPage(Nm);
  end
  else if Cat = 'System FBs (CALL)' then
  begin
    if Pos('TON', E.Cap) > 0 then TimerPage('TON')
    else if Pos('CTU', E.Cap) > 0 then CounterPage('CTU')
    else if Pos('R_TRIG', E.Cap) > 0 then EdgePage('R_TRIG')
    else EdgePage('RS');
  end;
end;

{ ---------- the keys, the project ---------- }

procedure KeyPage(const E: TSclElem);
begin
  Summary(E.Descr);
  Head('How to use it');
  if Lg in ['F', 'K'] then
  begin
    if Pos('Del', E.Cap) = 1 then
    begin
      Step('Click a box (FBD: and the boxes that feed it go too), a wire (CFC: near its end at the pin) or a pin.');
      Step('Del: the box / the wire / the operand of the pin goes. Undo (Ctrl+Z) takes it back.');
    end
    else if Pos('Ctrl+Z', E.Cap) = 1 then
      Step('Ctrl+Z undoes the last change (200 steps), Ctrl+Y does it again (also the Undo / Redo buttons).')
    else if Pos('drag a block', E.Cap) = 1 then
      Step('Press the mouse on the title of a block and drag it: it moves by the grid of the chart; its wires follow.')
    else if Pos('drag a pin', E.Cap) = 1 then
    begin
      Step('Press the mouse on an output pin (right side of a block) and drag: a red dashed line follows.');
      Step('Release it on an input pin (left side) of another block: the wire is there; an operand of that pin goes.');
    end
    else
    begin
      Step('Click a pin of a box: it gets a red frame.');
      Step('Double click a box in the list: it goes onto that pin and feeds it; the operand of the pin moves onto ' +
        'its first input.');
    end;
    Exit;
  end;
  case Lg of
    'L':
      begin
        if Pos('Del', E.Cap) = 1 then
        begin
          Step('Select cells: click one, Shift+click the last one (or a rubber band with the mouse).');
          Step('Del deletes them, Ctrl+X cuts, Ctrl+C copies; click the target cell and Ctrl+V inserts them there.');
        end
        else if Pos('Shift', E.Cap) = 1 then
        begin
          Step('Click the first cell, then Shift+click the last one, or Shift+arrows from the selected cell.');
          Step('Ctrl+A selects the whole network.');
        end
        else if Pos('drag', E.Cap) = 1 then
        begin
          Step('Press the mouse on an element (or on the selected cells) and drag: a ghost follows the mouse.');
          Step('The red frame shows where they land; grey: no room there. Release to drop them (also into another network).');
        end
        else Step('Ctrl+Z undoes the last change (200 steps), Ctrl+Y does it again (also the Undo / Redo buttons).');
      end;
  else
    begin
      case E.Cap of
        'Ctrl+Z / Ctrl+Y': Step('Ctrl+Z undoes the last change; Ctrl+Y (or Ctrl+Shift+Z) does it again. Typing on one line ' +
          'within 3 s is one step.');
        'Ctrl+D', 'Ctrl+D / Ctrl+L': Step('Ctrl+D copies the line of the caret (or the selected lines) below; Ctrl+L deletes it.');
        'Ctrl+L': Step('Ctrl+L deletes the line of the caret.');
        'Ctrl+Q': Step('Select the lines (or put the caret on one) and press Ctrl+Q: // goes in front of them; again: out.');
        'Ctrl+Shift+Up/Down': Step('Ctrl+Shift+Up / Down moves the line of the caret (or the selected lines) up / down.');
        'Ctrl+F / Ctrl+H / F3': Step('Ctrl+F opens the find bar, Ctrl+H find and replace; F3 the next place, Shift+F3 the one ' +
          'before. Replace / All replace.');
        'Ctrl+G': Step('Ctrl+G asks for a line number and puts the caret there.');
        'Ctrl+Space': Step('Type the start of a name and press Ctrl+Space: a list of the tags, DBs, #locals and functions that ' +
          'start so; Enter takes one.');
        'Alt+Up / Ctrl+Click': Step('Put the caret on a name and press Alt+Up (or Ctrl+click it): the editor goes to its ' +
          'declaration (the interface row, the tag, the DB variable).');
      else
        Step('Drag with the Alt key held: a block (column) selection; Alt+Shift+arrows makes it from the keyboard. Typing ' +
          'writes into every line of it.');
      end;
    end;
  end;
end;

procedure ProjectPage(const E: TSclElem);
var
  Kind: string;
begin
  Kind := Copy(E.Cat, Length(ElemProject) + 1, MaxInt);
  Summary(E.Descr);
  Head('How to use it');
  if Lg in ['F', 'K'] then
  begin
    Step('Select a pin of a box (or a box: the field above it).');
    Step('Double click this entry, or drag it onto the pin: it becomes the operand (an FC / an instance DB: a CALL box).');
  end
  else if Lg = 'L' then
  begin
    Step('Select a cell of the LAD network (a contact, a coil, a box pin).');
    Step('Double click this entry, or drag it onto the element: it becomes the operand (an FC / an instance DB: a CALL box).');
  end
  else
  begin
    Step('Put the caret where the name goes.');
    Step('Double click this entry, drag it into the code, or right button: Insert at the caret.');
  end;
  if Kind = 'this block' then Txt('A variable of the interface of this block: inside the block it is written with #.')
  else if Kind = 'PLC tags' then Txt('A PLC tag: a name for an address (Tags screen); in the code in quotes.')
  else if Kind = 'Data blocks' then Txt('A variable of a global data block, or the instance DB of an FB (its call).')
  else if Pos('Functions', Kind) = 1 then Txt('An FC of the project: its call with every parameter.')
  else if Pos('Function blocks', Kind) = 1 then Txt('An FB of the project: a type for a Static (a multi-instance) or the ' +
    'FB of an instance DB.')
  else Txt('A PLC data type of the project: the type of a variable.');
  Head('The code it puts in');
  if ElemText(E.Snip) <> '' then Code(ElemText(E.Snip)) else Code(E.Cap);
  Txt('The right button on it (in the code) has Cross reference: every place where it is used.');
end;

{ ---------- the PLC clock ---------- }

procedure ClockPage(const Name: string);
var
  Rd, Wr, Sys: Boolean;
  Pin, Ex: string;
begin
  Rd := (Name = 'RD_LOC_T') or (Name = 'RD_SYS_T') or (Name = 'READ_CLK');
  Wr := (Name = 'WR_LOC_T') or (Name = 'WR_SYS_T') or (Name = 'SET_CLK');
  Sys := (Name = 'RD_SYS_T') or (Name = 'WR_SYS_T');
  case Name of
    'RD_LOC_T': Pin := 'OUT';
    'RD_SYS_T': Pin := 'OUT';
    'WR_LOC_T': Pin := 'LOCTIME';
    'WR_SYS_T': Pin := 'IN';
    'READ_CLK': Pin := 'CDT';
    'SET_CLK': Pin := 'PDT';
  else
    Pin := '';
  end;
  if Name = 'TIME_TCK' then
    Summary('TIME_TCK returns the milliseconds since the CPU started, as a Time (it wraps after 24 days). Two readings ' +
      'give the time between them, without a timer instance.')
  else if Rd then
    Summary(Name + ' reads the PLC clock: ' + IfThen(Sys, 'the system time (UTC)', 'the local time') + ' into ' +
      IfThen(Name = 'READ_CLK', 'a Date_And_Time (DT)', 'a DTL (a struct of YEAR .. NANOSECOND), or a DT / LDT') +
      '. The clock runs with the PC clock; the CPU screen shows it and sets it (PLC clock card).')
  else
    Summary(Name + ' sets the PLC clock to ' + IfThen(Sys, 'a system time (UTC)', 'a local time') + ' (' +
      IfThen(Name = 'SET_CLK', 'a Date_And_Time', 'a DTL, or a DT / LDT') + '). It runs on from there. Call it once (an edge), ' +
      'not in every cycle.');
  if Name = 'TIME_TCK' then Syntax('#Tick := TIME_TCK();')
  else if Rd then Syntax(Format('#Ret := %s(%s => #Time);    // or the statement %s(%s => #Time);', [Name, Pin, Name, Pin]))
  else Syntax(Format('#Ret := %s(%s := #Time%s);', [Name, Pin, IfThen(Name = 'WR_LOC_T', ', DST := FALSE', '')]));
  if Name = 'TIME_TCK' then Params('RET_VAL|Time|the ms since the start')
  else
    Params(Pin + '|' + IfThen((Name = 'READ_CLK') or (Name = 'SET_CLK'), 'Date_And_Time', 'DTL / DT / LDT') + '|the time ' +
      IfThen(Rd, 'read (written by the instruction)', 'to set') + '\RET_VAL|Int|0: done' +
      IfThen(Name = 'WR_LOC_T', '\DST|Bool|summer time (not used here)', ''));
  HowTo(['Declare the time variable: a Static / Temp of the block or a DB variable ' +
    IfThen((Name = 'READ_CLK') or (Name = 'SET_CLK'), 'Dt : Date_And_Time', 'Now : DTL') + ', and RET_VAL : Int.',
    IfThen(Wr, 'Set it from an edge (a button), with the members filled first.', 'Read it in every cycle; use its members: ' +
    '#Now.HOUR, #Now.MINUTE ..')]);
  if (Name <> 'TIME_TCK') and (Name <> 'READ_CLK') and (Name <> 'SET_CLK') then
  begin
    Head('The members of a DTL');
    Tab('Member|Type|Values\YEAR|UInt|1970 .. 2262\MONTH|USInt|1 .. 12\DAY|USInt|1 .. 31\WEEKDAY|USInt|1 = Sunday .. 7 = ' +
      'Saturday\HOUR|USInt|0 .. 23\MINUTE|USInt|0 .. 59\SECOND|USInt|0 .. 59\NANOSECOND|UDInt|0 .. 999 999 999');
  end;
  case Name of
    'RD_LOC_T': Ex := '// Static: Now : DTL, Ret : Int\#Ret := RD_LOC_T(OUT => #Now);\"Night" := (#Now.HOUR >= 22) OR (#Now.HOUR < 6);' +
      '\"Weekend" := (#Now.WEEKDAY = 1) OR (#Now.WEEKDAY = 7);';
    'RD_SYS_T': Ex := '// Static: Utc : DTL\RD_SYS_T(OUT => #Utc);\"Log".Stamp := #Utc;';
    'WR_LOC_T': Ex := '// Static: SetTo : DTL, Edge : R_TRIG\#Edge(CLK := "Set_PB");\IF #Edge.Q THEN\    #SetTo := "HMI".NewTime;\' +
      '    #Ret := WR_LOC_T(LOCTIME := #SetTo, DST := FALSE);\END_IF;';
    'WR_SYS_T': Ex := 'IF "Sync" THEN\    #Ret := WR_SYS_T(IN := "NTP".Utc);\    "Sync" := FALSE;\END_IF;';
    'TIME_TCK': Ex := '// Static: T0 : Time\IF "Start" THEN #T0 := TIME_TCK(); END_IF;\"Took" := TIME_TCK() - #T0;';
    'READ_CLK': Ex := '// Static: Dt : Date_And_Time\#Ret := READ_CLK(CDT => #Dt);\"Shift_Start" := #Dt >= DT#2024-01-01-06:00:00;';
  else
    Ex := 'IF "Set_PB" AND NOT #Old THEN\    #Ret := SET_CLK(PDT := "HMI".NewTime);\END_IF;\#Old := "Set_PB";';
  end;
  if Lg = 'S' then
  begin
    if Name = 'TIME_TCK' then Example('CALL TIME_TCK\  RET_VAL := #Tick', '')
    else Example(Format('CALL %s\  %s := #Time\  RET_VAL := #Ret', [Name, Pin]), 'one parameter per line');
  end
  else if Lg in ['F', 'K'] then
  begin
    Head('Example (as SCL)');
    Code(Ex);
  end
  else Example(Ex, '');
  Notes(['RD_SYS_T / RD_LOC_T / WR_SYS_T / WR_LOC_T: S7-1200/1500; READ_CLK / SET_CLK: S7-300/400 (also the 1500).',
    'The system time is the local time minus the time zone of this PC; DST (summer time) is not used.',
    'A changed clock stays until the app is closed; the CPU screen sets it back (Set to PC time).']);
end;

{ ---------- FBD / CFC ---------- }

procedure FbdLogicPage(const Id: string);
var
  Op: string;
begin
  Op := UpperCase(Id);
  if Id = 'and' then
    Summary('AND box: Q is TRUE only when every input is TRUE. It is the FBD form of contacts in series. More inputs: ' +
      'the + in the box (or the right button: Add input); a small circle at an input negates it (NOT).')
  else if Id = 'or' then
    Summary('OR box: Q is TRUE when at least one input is TRUE. It is the FBD form of a parallel branch.')
  else
    Summary('XOR box: Q is TRUE when an odd number of inputs is TRUE (two inputs: when they differ).');
  Syntax('a box ' + Op + ': IN1, IN2 (+ IN3 ..) on its left, Q on its right;\the inputs: operands (%I0.0, "Start", #In) or ' +
    'the outputs of other boxes');
  Params('IN1, IN2 ..|Bool|the inputs (negated: the circle)\Q|Bool|the result');
  HowTo(['Type the operands at its inputs (or put boxes onto them); the right button on an input: Negate this input.',
    'Select the box and double click = : the assignment of Q to an output.']);
  Head('Truth table');
  if Id = 'and' then Tab('IN1|IN2|Q\FALSE|FALSE|FALSE\FALSE|TRUE|FALSE\TRUE|FALSE|FALSE\TRUE|TRUE|TRUE')
  else if Id = 'or' then Tab('IN1|IN2|Q\FALSE|FALSE|FALSE\FALSE|TRUE|TRUE\TRUE|FALSE|TRUE\TRUE|TRUE|TRUE')
  else Tab('IN1|IN2|Q\FALSE|FALSE|FALSE\FALSE|TRUE|TRUE\TRUE|FALSE|TRUE\TRUE|TRUE|FALSE');
  Head('Picture');
  if Id = 'and' then Lad('no "Start";nc "Stop";coil "Motor"', '"Motor" := "Start" AND NOT "Stop"')
  else if Id = 'or' then Lad('no "Start"!;coil "Lamp"\no "Test"', '"Lamp" := "Start" OR "Test"')
  else Lad('no "A";-;coil "Q"', '');
  Txt('The same in SCL:');
  if Id = 'and' then Code('"Motor" := "Start" AND NOT "Stop";')
  else if Id = 'or' then Code('"Lamp" := "Start" OR "Test";')
  else Code('"Changed" := "A" XOR "B";');
  Notes(['A box with more inputs is one box: AND of 4 inputs needs no AND chain.',
    'In LAD the same is contacts in series (AND) or a branch (OR); Convert to FBD (the right button on a LAD network) ' +
    'turns a rung into these boxes.']);
end;

procedure FbdCoilPage(const Id: string);
begin
  if Id = 'assign' then
    Summary('Assignment box =: the operand above it gets the value of IN in every cycle (TRUE or FALSE). It is the FBD ' +
      'form of the coil.')
  else if Id = 'set' then
    Summary('Set box S: while IN is TRUE the operand above becomes TRUE; it stays TRUE when IN goes FALSE.')
  else
    Summary('Reset box R: while IN is TRUE the operand above becomes FALSE (also a timer / counter instance).');
  Syntax('a box ' + IfThen(Id = 'assign', '=', UpperCase(Copy(Id, 1, 1))) + ': the operand above it, IN on its left');
  Params('operand|Bool|above the box: the output, the memory bit ..\IN|Bool|the condition: an operand or a box');
  HowTo(['Select the box whose result it takes (AND, OR, a timer ..) and double click ' +
    IfThen(Id = 'assign', '=', UpperCase(Copy(Id, 1, 1))) + ': it comes after it.',
    'Type the operand in the field above it.']);
  Head('Picture');
  if Id = 'assign' then Lad('no "Start";nc "Stop";coil "Motor"', '')
  else Lad('no "Start";set "Motor"\no "Stop";reset "Motor"', 'S and R of the same operand: the later one wins');
  if Id <> 'assign' then
  begin
    Head('Timing diagram');
    Wave('Start=0110000001100000\Stop=0000011000000110\Motor=0111100001111000', '');
  end;
  Txt('The same in SCL:');
  if Id = 'assign' then Code('"Motor" := "Start" AND NOT "Stop";')
  else Code('IF "Start" THEN "Motor" := TRUE; END_IF;\IF "Stop" THEN "Motor" := FALSE; END_IF;');
end;

procedure FbdEdgePage(const Id: string);
begin
  if Id = 'p' then
    Summary('P box (rising edge): Q is TRUE for one cycle when IN goes from FALSE to TRUE. The memory bit above the ' +
      'box keeps the value of the last cycle (a bit used for nothing else).')
  else
    Summary('N box (falling edge): Q is TRUE for one cycle when IN goes from TRUE to FALSE.');
  Syntax('a box ' + UpperCase(Id) + ': the edge memory bit above it, IN on its left, Q on its right');
  Params('memory bit|Bool|above the box: %M10.0, "Edge_M", a Static\IN|Bool|the signal\Q|Bool|the edge: one cycle');
  HowTo(['Double click the box, type the memory bit above it and the signal at IN.',
    'Its Q goes on: select the box and double click = (or a counter, a box with EN).']);
  Head('Picture');
  Lad(Id + ' "Button"|"Edge_M";coil "Pulse"', '');
  Head('Timing diagram');
  if Id = 'p' then Wave('IN=0011110001100000\Q=0010000001000000', '')
  else Wave('IN=0011110001100000\Q=0000001000010000', '');
  Txt('The same in SCL:');
  if Id = 'p' then Code('"Pulse" := "Button" AND NOT "Edge_M";\"Edge_M" := "Button";')
  else Code('"Pulse" := NOT "Button" AND "Edge_M";\"Edge_M" := "Button";');
  Notes(['Every edge needs its own memory bit. R_TRIG / F_TRIG do the same with an instance.']);
end;

procedure FbdBoxPage(const E: TSclElem);
var
  Id: string;
  Ce: TSclElem;
begin
  Id := Copy(E.Snip, Length(FbdBoxSnip) + 1, MaxInt);
  if Copy(Id, 1, 5) = 'call:' then Id := 'call';
  Ce := E;
  case Id of
    'and', 'or', 'xor': FbdLogicPage(Id);
    'assign', 'set', 'reset': FbdCoilPage(Id);
    'p', 'n': FbdEdgePage(Id);
    'rtrig': EdgePage('R_TRIG');
    'ftrig': EdgePage('F_TRIG');
    'rs': EdgePage('RS');
    'sr': EdgePage('SR');
    'ton', 'tof', 'tp', 'tonr': TimerPage(UpperCase(Id));
    'ctu', 'ctd', 'ctud': CounterPage(UpperCase(Id));
    'sodt': S5TimerPage('SD');
    'sodts': S5TimerPage('SS');
    'spulse': S5TimerPage('SP');
    'spext': S5TimerPage('SE');
    'soffdt': S5TimerPage('SF');
    'scu': S5CounterPage('CU');
    'scd': S5CounterPage('CD');
    'scud': S5CounterPage('CU');
    'cmp': LadCmp(5);
    'inrange': LadMisc(lkInRange);
    'outrange': LadMisc(lkOutRange);
    'add': LadArith(lkAdd);
    'sub': LadArith(lkSub);
    'mul': LadArith(lkMul);
    'div': LadArith(lkDiv);
    'mod': LadArith(lkMod);
    'expt': LadArith(lkExpt);
    'neg': LadMisc(lkNegate);
    'inc': LadMisc(lkInc);
    'dec': LadMisc(lkDec);
    'move': LadMisc(lkMove);
    'conv': LadMisc(lkConv);
    'round', 'trunc', 'ceil', 'floor': RoundPage(UpperCase(Id));
    'normx': ScalePage('NORM_X');
    'scalex': ScalePage('SCALE_X');
    'sel', 'mux', 'limit', 'min', 'max': SelectPage(UpperCase(Id));
    'andw': LadMisc(lkAndW);
    'orw': LadMisc(lkOrW);
    'xorw': LadMisc(lkXorW);
    'invw': LadMisc(lkInvW);
    'shl', 'shr', 'rol', 'ror': ShiftPage(UpperCase(Id));
    'concat', 'len', 'left', 'right', 'mid', 'find': StringPage(UpperCase(Id));
    'smove': StringPage('S_MOVE');
    'call': LadMisc(lkCall);
    'rdloct': ClockPage('RD_LOC_T');
    'rdsyst': ClockPage('RD_SYS_T');
    'wrloct': ClockPage('WR_LOC_T');
    'wrsyst': ClockPage('WR_SYS_T');
    'timetck': ClockPage('TIME_TCK');
    'readclk': ClockPage('READ_CLK');
    'setclk': ClockPage('SET_CLK');
    'abs', 'sqr', 'sqrt', 'exp', 'ln', 'sin', 'cos', 'tan', 'asin', 'acos', 'atan', 'frac': MathPage(UpperCase(Id));
  end;
  if Ce.Cap = '' then ;
end;

{ ---------- the page ---------- }

function ElemHelpPage(Lang: Char; const E: TSclElem; Fam: TCpuFamily): TElemHelpPage;
var
  Cat: string;
begin
  Pg.Title := E.Cap;
  Pg.Sub := LangTitle(Lang) + '  ·  ' + E.Cat;
  Pg.Blocks := nil;
  Pg.Example := '';
  Lg := Lang;
  Fm := Fam;
  Cat := E.Cat;
  if Copy(Cat, 1, Length(ElemProject)) = ElemProject then ProjectPage(E)
  else if Cat = 'Editor keys' then KeyPage(E)
  else if Lang in ['F', 'K'] then FbdBoxPage(E)
  else if Lang = 'L' then
  begin
    if E.Kind >= 0 then LadPage(E);
  end
  else if Lang = 'S' then StlPage(E)
  else if Cat = 'Program control' then SclControl(E.Cap)
  else if Cat = 'Operators' then SclOperator(E.Cap)
  else if Cat = 'Constants / literals' then SclConst(E)
  else if Cat = 'Elementary data types' then SclType(E.Cap)
  else if Cat = 'Structured data types' then SclCType(E.Cap)
  else if Cat = 'Declaration sections' then SclDecl(E)
  else if Cat = 'Block templates (.scl source)' then SclTemplate(E)
  else if Cat = 'Bit logic / edges' then EdgePage(Copy(E.Cap, 1, Pos(' ', E.Cap + ' ') - 1))
  else if Cat = 'Timers' then
  begin
    if Pos('IEC_TIMER', E.Cap) = 1 then TimerPage('TON') else TimerPage(Copy(E.Cap, 1, Pos(' ', E.Cap) - 1));
  end
  else if Cat = 'Counters' then
  begin
    if Pos('IEC_COUNTER', E.Cap) = 1 then CounterPage('CTU') else CounterPage(Copy(E.Cap, 1, Pos(' ', E.Cap) - 1));
  end
  else if Cat = 'Comparison / selection' then SelectPage(E.Cap)
  else if Cat = 'Math functions' then MathPage(E.Cap)
  else if Cat = 'Conversion' then
  begin
    if Pos('_TO_', E.Cap) > 0 then ConvPage(E.Cap)
    else if (E.Cap = 'NORM_X') or (E.Cap = 'SCALE_X') then ScalePage(E.Cap)
    else RoundPage(E.Cap);
  end
  else if Cat = 'Shift / rotate / slice' then
  begin
    if Pos('.%', E.Cap) = 1 then SclSlice(E.Cap) else ShiftPage(E.Cap);
  end
  else if Cat = 'String' then StringPage(E.Cap)
  else if Cat = 'Operands / addresses' then SclOperand(E)
  else if Cat = 'Date and time (clock)' then ClockPage(E.Cap);
  // nothing special: its description and its code
  if Length(Pg.Blocks) = 0 then
  begin
    Summary(E.Descr);
    if ElemText(E.Snip) <> '' then Syntax(ElemText(E.Snip));
    HowTo([]);
  end;
  if (Pg.Example = '') and not (Lang in ['L', 'F', 'K']) and (ElemText(E.Snip) <> '') then Pg.Example := ElemText(E.Snip);
  Result := Pg;
end;

function HelpLadNet(const S: string): TNetwork;
var
  Rows: TStringList;
  Cells, Parts: TStringArray;
  R, C, K, P, P0, MaxC: Integer;
  T, Id, Rest, Ty, Ty2, Op: string;
  Ce: TLadCell;
  Kd, Lk: TLadKind;
  Co: TCmpOp;
  DT: TDataType;
  Lo, Hi: Integer;
  Found, Down: Boolean;
begin
  Result := TNetwork.Create(nkLAD);
  Rows := TStringList.Create;
  try
    Rows.Text := S;
    MaxC := 1;
    for R := 0 to Rows.Count - 1 do MaxC := Max(MaxC, Length(Rows[R].Split(';')));
    Result.SetRows(Max(1, Rows.Count));
    Result.SetCols(MaxC);
    for R := 0 to Rows.Count - 1 do
    begin
      Cells := Rows[R].Split(';');
      for C := 0 to High(Cells) do
      begin
        T := Trim(Cells[C]);
        if T = '' then Continue;
        Down := T[Length(T)] = '!';
        if Down then T := Trim(Copy(T, 1, Length(T) - 1));
        if T = '-' then Ce := NewCell(lkWire, '')
        else
        begin
          P := Pos(' ', T);
          if P = 0 then
          begin
            Id := T;
            Rest := '';
          end
          else
          begin
            Id := Copy(T, 1, P - 1);
            Rest := Copy(T, P + 1, MaxInt);
          end;
          Op := '';
          Ty := '';
          Ty2 := '';
          P := Pos('=', Id);
          if P > 0 then
          begin
            Op := Copy(Id, P + 1, MaxInt);
            Id := Copy(Id, 1, P - 1);
          end;
          P := Pos('>', Id);
          if P > 0 then
          begin
            Ty2 := Copy(Id, P + 1, MaxInt);
            Id := Copy(Id, 1, P - 1);
          end;
          P := Pos('@', Id);
          if P > 0 then
          begin
            Ty := Copy(Id, P + 1, MaxInt);
            Id := Copy(Id, 1, P - 1);
          end;
          Found := False;
          Kd := lkEmpty;
          for Lk := Low(TLadKind) to High(TLadKind) do
            if (LadKindIds[Lk] <> '') and SameText(LadKindIds[Lk], Id) then
            begin
              Kd := Lk;
              Found := True;
              Break;
            end;
          if not Found then
          begin
            HelpLadErr := HelpLadErr + ' ' + Id;
            Continue;
          end;
          Ce := NewCell(Kd, '');
          if (Ty <> '') and ParseDataType(Ty, DT, Lo, Hi) then Ce.DType := DT;
          if (Ty2 <> '') and ParseDataType(Ty2, DT, Lo, Hi) then Ce.DType2 := DT;
          if Op <> '' then
            for Co := Low(TCmpOp) to High(TCmpOp) do
              if CmpOpNames[Co] = Op then Ce.Cmp := Co;
          if Rest <> '' then
          begin
            Parts := Rest.Split('|');
            if LadOpndName(Kd) <> '' then
            begin
              Ce.Opnd := Parts[0];
              P0 := 1;
            end
            else
              P0 := 0;
            for K := P0 to High(Parts) do
              if K - P0 <= 4 then Ce.P[K - P0] := Parts[K];
          end;
        end;
        Ce.Down := Down;
        Result.SetCell(R, C, Ce);
      end;
    end;
  finally
    Rows.Free;
  end;
end;

function RetainHelpPage(Fam: TCpuFamily): TElemHelpPage;
begin
  Pg.Title := 'Retain';
  Pg.Sub := 'Data blocks  ·  the Retain column';
  Pg.Blocks := nil;
  Pg.Example := '';
  Lg := 'C';
  Fm := Fam;
  Summary('Retain decides what a variable of a data block holds after the CPU starts again. A Retain variable keeps ' +
    'the value it had (the CPU keeps it in its retentive memory); a variable that is not Retain gets its start value ' +
    'again. A restart is every STOP to RUN of the CPU (the warm restart) and, on a real CPU, switching the power off ' +
    'and on. While the CPU runs there is no difference: both hold what the program writes.');
  Head('What happens to the value');
  Tab('Event|Retain (ticked)|not Retain\RUN (the program runs)|what the program writes|what the program writes\' +
    'STOP|stays as it is|stays as it is\STOP -> RUN (warm restart, OB100)|keeps its value|back to the start value\' +
    'power off / on (a real CPU)|keeps its value|back to the start value\Download (the DB is the same)|keeps its value|' +
    'keeps its value\Download (the DB changed: a variable more / another type)|the start value|the start value\' +
    'MRES (memory reset)|the start value|the start value');
  Add(hbCaption, 'the start value: the Start value column of the variable');
  Head('Timing diagram');
  Wave('CPU RUN=1111111100111111\^STOP:8-10\Pieces (Retain)~0,1,2,3,4,5,6,7,7,7,7,8,9,10,11,12\' +
    'Batch (not Retain)~0,1,2,3,4,5,6,7,7,7,0,1,2,3,4,5', 'the CPU stops at step 8 and runs again at step 10 (a warm restart)');
  Txt('Both variables count the same pieces. In STOP nothing changes; at the warm restart (step 10) the Retain variable ' +
    'goes on from 7, the other one starts again from its start value 0.');
  Head('How to use it');
  Step('Open the Data blocks screen and select the DB (a global DB; an instance DB takes it from the interface of its FB).');
  Step('Tick Retain for the variables that must survive a restart; leave it free for the others.');
  Step('Set the Start value (the value a variable that is not Retain gets at every restart, and every variable after an ' +
    'MRES).');
  Step('Download (F8) and RUN (F5). Try it: STOP (F6), RUN (F5) again and look at the Monitor value column.');
  Head('Example');
  Txt('A DB "Production" with two counters of the same sensor: the total stays over every restart, the count of the ' +
    'shift starts again.');
  Tab('Name|Data type|Start value|Retain|Monitor before STOP|after STOP -> RUN\TotalPieces|UDInt|0|yes|15230|15230\' +
    'ShiftPieces|UInt|0|no|412|0\OperatingHours|Real|0.0|yes|1288.5|1288.5\StepNo|Int|0|no|3|0');
  Code('// OB1: both count the rising edges of the sensor\IF "Sensor" AND NOT #Old THEN\    "Production".TotalPieces := ' +
    '"Production".TotalPieces + 1;\    "Production".ShiftPieces := "Production".ShiftPieces + 1;\END_IF;\#Old := "Sensor";');
  Notes(['Make Retain: totals, operating hours, counters for maintenance, parameters and recipes typed on the HMI - what ' +
    'must not be lost.',
    'Leave it free: the steps of a sequence, commands, states of the machine - after a restart the machine should start ' +
    'from a known state (the start value), not in the middle of a step.',
    'A real CPU has a limited retentive memory (a few KB on the S7-1200): mark only what is needed.',
    'In TIA Portal a standard (not optimized) DB has one Retain setting for the whole DB; an optimized DB one per ' +
    'variable. The Virtual PLC keeps it per variable for both.',
    'S7-300/400: the Retain column is not used; the DBs keep their values and MB0 .. MB15, C0 .. C7 are retentive. ' +
    'Instance DBs: the Retain of the FB''s Static variables (VAR RETAIN).',
    'MRES (memory reset on the CPU screen) puts every variable back to its start value, also the Retain ones.']);
  if Fm = cfS7300 then ;
  Result := Pg;
end;

function OptimizedHelpPage(Fam: TCpuFamily): TElemHelpPage;
begin
  Pg.Title := 'Optimized DB';
  Pg.Sub := 'Data blocks  ·  the button Optimized DB: ON / OFF';
  Pg.Blocks := nil;
  Pg.Example := '';
  Lg := 'C';
  Fm := Fam;
  Summary('Optimized block access (S7-1200 / S7-1500) decides how the CPU keeps the variables of a data block. ' +
    'A standard DB (Optimized DB: OFF) lays its variables out one after the other at fixed offsets, like an S7-300: ' +
    'every variable has an absolute address (DB1.DBX0.0, DB1.DBW2, DB1.DBD6) besides its name. An optimized DB ' +
    '(Optimized DB: ON) lets the CPU arrange the memory itself: the variables have no offset, they are reached only ' +
    'by their name ("Plant".Speed). The values the program computes are the same; what differs is how the DB ' +
    'can be reached.');
  Head('What changes');
  Tab('|Optimized DB: OFF (standard)|Optimized DB: ON\Offset column|0.0, 2.0, 4.0 .. (the S7 layout)|empty\' +
    'symbolic access "DB".Var|yes|yes\absolute access DB1.DBW2 in the program|yes|compile error: only symbolic access\' +
    'PUT / GET, S7 connection, HMI by address|yes (with PUT/GET permitted)|refused (not allowed)\' +
    'Modbus holding registers on DBn|yes|refused\Retain|per variable in the Virtual PLC (in TIA one setting for ' +
    'the whole DB)|per variable\gaps between the variables|yes (a Bool before an Int leaves a byte free)|none, the ' +
    'CPU packs them\S7-300 / S7-400|always standard|not available');
  Head('The memory of the DB');
  Txt('The same five variables in a standard and in an optimized DB:');
  Mem('Standard (OFF)=Start:1:b|gap:1:p|Speed:2:v|Stop:1:b|gap:1:p|Temp:4:v|Alarm:1:b|gap:1:p\' +
    '!Optimized (ON)=Temp:4:v|Speed:2:v|Start:1:b|Stop:1:b|Alarm:1:b',
    'standard: Bool, gap, Int at 2.0, Bool at 4.0, gap, Real at 6.0, Bool at 10.0 (12 bytes)  ·  optimized: the CPU ' +
    'sorts the variables by size, without an address');
  Txt('In the standard DB an Int, a Real, a DInt always starts at an even byte, so a Bool before it leaves a free ' +
    'byte; the offsets are what an absolute address (DB1.DBW2 = Speed, DB1.DBD6 = Temp) points at. In the optimized ' +
    'DB there is no offset to point at: "Plant".Speed is the only way to it.');
  Head('The result of the same program');
  Tab('Statement|Optimized DB: OFF|Optimized DB: ON\"Plant".Speed := 1500;|Speed = 1500|Speed = 1500\' +
    '%DB1.DBW2 := 1500;  (SCL)|Speed = 1500 (the same variable)|error: DB1 "Plant" is optimized: only symbolic ' +
    'access\L DB1.DBW 2  (STL)|1500|error at compile time\a partner reads DB1.DBW2 (PUT / GET)|1500|access refused\' +
    'Watch table: %DB1.DBW2|1500|the address does not resolve (red); "Plant".Speed works');
  Head('How to use it');
  Step('Open the Data blocks screen and select the DB (an S7-1200 or S7-1500 project).');
  Step('Click Optimized DB: OFF to make it optimized (ON), click again to make it standard. The Offset column ' +
    'shows the layout of a standard DB.');
  Step('Compile (F7): every absolute access to the DB is listed as an error once it is optimized.');
  Step('Download (F8): the CPU takes the new access of the DB.');
  Head('Example');
  Txt('A DB "Plant" (DB1) that an HMI or another CPU reads by address must stay standard; a DB only the program ' +
    'uses can be optimized.');
  Code('// works in both: symbolic\"Plant".Speed := "Plant".Speed + 10;\IF "Plant".Temp > 80.0 THEN\' +
    '    "Plant".Alarm := TRUE;\END_IF;\// only in a standard DB: the absolute address of Speed\%DB1.DBW2 := 0;');
  Notes(['Make it optimized: DBs that only your program uses - new TIA projects make every DB optimized; the ' +
    'CPU reaches the variables faster and there are no gaps.',
    'Keep it standard: a DB that is read by address - PUT / GET from an S7-300 or another CPU, an old HMI, a Modbus ' +
    'or S7 connection, STL code with DBW / DBD, AT views, pointers (ANY).',
    'Switching it changes the layout: download the DB again; an address read before may point elsewhere now.',
    'An instance DB takes it from its FB; a PLC data type (UDT) has its own layout and no button.',
    'S7-300 / S7-400 have no optimized DBs: every DB is standard.']);
  Result := Pg;
end;

function ElemHelpText(const P: TElemHelpPage): string;
var
  K, N: Integer;
  S: string;
begin
  Result := P.Title + LineEnding + P.Sub + LineEnding;
  N := 0;
  for K := 0 to High(P.Blocks) do
  begin
    S := P.Blocks[K].S;
    case P.Blocks[K].K of
      hbHead: begin Result := Result + LineEnding + '== ' + S + ' ==' + LineEnding; N := 0; end;
      hbStep: begin Inc(N); Result := Result + IntToStr(N) + '. ' + S + LineEnding; end;
      hbBullet, hbNote: Result := Result + '- ' + S + LineEnding;
      hbCode: Result := Result + '    ' + StringReplace(S, LineEnding, LineEnding + '    ', [rfReplaceAll]) + LineEnding;
      hbTable: Result := Result + '  ' + StringReplace(StringReplace(S, '|', ' | ', [rfReplaceAll]), LineEnding, LineEnding + '  ',
        [rfReplaceAll]) + LineEnding;
      hbLad: Result := Result + '  [LAD] ' + StringReplace(S, LineEnding, ' / ', [rfReplaceAll]) + LineEnding;
      hbFbd: Result := Result + '  [FBD] ' + StringReplace(S, LineEnding, ' / ', [rfReplaceAll]) + LineEnding;
      hbCfc: Result := Result + '  [CFC] ' + StringReplace(S, LineEnding, ' / ', [rfReplaceAll]) + LineEnding;
      hbWave: Result := Result + '  [timing] ' + StringReplace(S, LineEnding, ' / ', [rfReplaceAll]) + LineEnding;
      hbBits: Result := Result + '  [bits] ' + StringReplace(S, LineEnding, ' / ', [rfReplaceAll]) + LineEnding;
      hbFlow: Result := Result + '  [flowchart] ' + S + LineEnding;
      hbMem: Result := Result + '  [bytes] ' + StringReplace(S, LineEnding, ' / ', [rfReplaceAll]) + LineEnding;
      hbCaption: Result := Result + '  (' + S + ')' + LineEnding;
    else
      Result := Result + S + LineEnding;
    end;
  end;
end;

end.
