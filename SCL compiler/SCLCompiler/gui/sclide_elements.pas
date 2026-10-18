{ SCL Studio - "SCL elements" panel: language elements and project items by category,
  collapsible, drag & drop (or double click) into the SCL editor }
unit sclide_elements;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, contnrs, Forms, Controls, StdCtrls, ExtCtrls, ComCtrls, Graphics,
  scl_base, scl_types, scl_ast, scl_compiler;

const
  SNIP_CURSOR = #1;   // caret position after insertion

type
  TElemItem = class
  public
    Caption: string;
    Snippet: string;
    Descr: string;
  end;

  TInsertSnippetEvent = procedure(const Snippet: string) of object;

  TElementsPanel = class(TPanel)
  private
    FItems: TObjectList;          // TElemItem (static + project)
    FCats: TStringList;           // category name -> TList of TElemItem (objects)
    FProjectCats: TStringList;
    FTree: TTreeView;
    FFilter: TEdit;
    FDescr: TMemo;
    FDragNode: TTreeNode;
    FDownPos: TPoint;
    FExpanded: TStringList;
    procedure AddCat(const Cat: string; Project: Boolean = False);
    procedure Add(const Cat, ACaption, ASnippet, ADescr: string);
    procedure BuildStatic;
    procedure Rebuild;
    procedure FilterChange(Sender: TObject);
    procedure TreeChange(Sender: TObject; Node: TTreeNode);
    procedure TreeDblClick(Sender: TObject);
    procedure TreeMouseDown(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
    procedure TreeMouseMove(Sender: TObject; Shift: TShiftState; X, Y: Integer);
    procedure TreeMouseUp(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
    procedure CloseClick(Sender: TObject);
    procedure RememberExpanded;
  public
    OnInsertSnippet: TInsertSnippetEvent;
    OnClosePanel: TNotifyEvent;
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure UpdateProject(C: TSclCompiler);
    function IsElementDrag(Source: TObject): Boolean;
    function DraggedSnippet: string;
    property Tree: TTreeView read FTree;
  end;

implementation

const
  CUR = SNIP_CURSOR;
  NL = LineEnding;

{ TElementsPanel }

constructor TElementsPanel.Create(AOwner: TComponent);
var
  Head: TPanel;
  L: TLabel;
  B: TButton;
  Sp: TSplitter;
begin
  inherited Create(AOwner);
  BevelOuter := bvNone;
  Width := 270;
  FItems := TObjectList.Create(True);
  FCats := TStringList.Create;
  FCats.OwnsObjects := True;
  FProjectCats := TStringList.Create;
  FExpanded := TStringList.Create;
  FExpanded.Sorted := True;
  FExpanded.Duplicates := dupIgnore;

  Head := TPanel.Create(Self);
  Head.Parent := Self;
  Head.Align := alTop;
  Head.Height := 26;
  Head.BevelOuter := bvNone;
  Head.Color := clBtnShadow;
  Head.ParentBackground := False;
  L := TLabel.Create(Head);
  L.Parent := Head;
  L.Caption := '  SCL elements';
  L.Align := alClient;
  L.Layout := tlCenter;
  L.Font.Style := [fsBold];
  L.Font.Color := clWhite;
  B := TButton.Create(Head);
  B.Parent := Head;
  B.Align := alRight;
  B.Width := 26;
  B.Caption := 'x';
  B.Hint := 'Close panel (Alt+2)';
  B.ShowHint := True;
  B.OnClick := @CloseClick;

  FFilter := TEdit.Create(Self);
  FFilter.Parent := Self;
  FFilter.Align := alTop;
  FFilter.Top := Head.Top + Head.Height + 1;
  FFilter.TextHint := 'Search element...';
  FFilter.OnChange := @FilterChange;

  FDescr := TMemo.Create(Self);
  FDescr.Parent := Self;
  FDescr.Align := alBottom;
  FDescr.Height := 120;
  FDescr.ReadOnly := True;
  FDescr.ScrollBars := ssAutoBoth;
  FDescr.Font.Name := 'Consolas';
  FDescr.Color := clInfoBk;

  Sp := TSplitter.Create(Self);
  Sp.Parent := Self;
  Sp.Align := alBottom;
  Sp.Top := FDescr.Top - 5;

  FTree := TTreeView.Create(Self);
  FTree.Parent := Self;
  FTree.Align := alClient;
  FTree.ReadOnly := True;
  FTree.HideSelection := False;
  FTree.RowSelect := True;
  FTree.ToolTips := True;
  FTree.DragMode := dmManual;
  FTree.OnChange := @TreeChange;
  FTree.OnDblClick := @TreeDblClick;
  FTree.OnMouseDown := @TreeMouseDown;
  FTree.OnMouseMove := @TreeMouseMove;
  FTree.OnMouseUp := @TreeMouseUp;

  BuildStatic;
  Rebuild;
end;

destructor TElementsPanel.Destroy;
begin
  FCats.Free;
  FProjectCats.Free;
  FItems.Free;
  FExpanded.Free;
  inherited Destroy;
end;

procedure TElementsPanel.AddCat(const Cat: string; Project: Boolean);
begin
  if FCats.IndexOf(Cat) < 0 then FCats.AddObject(Cat, TList.Create);
  if Project and (FProjectCats.IndexOf(Cat) < 0) then FProjectCats.Add(Cat);
end;

procedure TElementsPanel.Add(const Cat, ACaption, ASnippet, ADescr: string);
var
  It: TElemItem;
  I: Integer;
begin
  AddCat(Cat);
  It := TElemItem.Create;
  It.Caption := ACaption;
  It.Snippet := ASnippet;
  It.Descr := ADescr;
  FItems.Add(It);
  I := FCats.IndexOf(Cat);
  TList(FCats.Objects[I]).Add(It);
end;

procedure TElementsPanel.BuildStatic;
const
  C_CTRL = 'Program control';
  C_OPS = 'Operators';
  C_CONST = 'Constants / literals';
  C_TYPES = 'Elementary data types';
  C_CTYPES = 'Structured data types';
  C_DECL = 'Declaration sections';
  C_BLOCKS = 'Block templates';
  C_BIT = 'Bit logic / edges';
  C_TIMER = 'Timers';
  C_CNT = 'Counters';
  C_CMP = 'Comparison / selection';
  C_MATH = 'Math functions';
  C_CONV = 'Conversion';
  C_SHIFT = 'Shift / rotate / slice';
  C_STR = 'String';
var
  S: string;
  T: array of string;
  Conv: array of string;
begin
  { ---- program control ---- }
  Add(C_CTRL, 'IF ... THEN', 'IF ' + CUR + ' THEN' + NL + '    ;' + NL + 'END_IF;',
    'Conditional execution.');
  Add(C_CTRL, 'IF ... ELSE', 'IF ' + CUR + ' THEN' + NL + '    ;' + NL + 'ELSE' + NL + '    ;' + NL + 'END_IF;',
    'Two branches.');
  Add(C_CTRL, 'IF ... ELSIF ... ELSE', 'IF ' + CUR + ' THEN' + NL + '    ;' + NL + 'ELSIF  THEN' + NL + '    ;' + NL +
    'ELSE' + NL + '    ;' + NL + 'END_IF;', 'Several conditions.');
  Add(C_CTRL, 'CASE ... OF', 'CASE ' + CUR + ' OF' + NL + '    1:' + NL + '        ;' + NL + '    2, 3:' + NL +
    '        ;' + NL + '    4..9:' + NL + '        ;' + NL + 'ELSE' + NL + '    ;' + NL + 'END_CASE;',
    'Multi-way branch on an integer selector. Labels: value, list (2, 3) or range (4..9).');
  Add(C_CTRL, 'FOR ... TO ... DO', 'FOR #i := 0 TO ' + CUR + ' DO' + NL + '    ;' + NL + 'END_FOR;',
    'Counting loop. The control variable must be an integer.');
  Add(C_CTRL, 'FOR ... BY ... DO', 'FOR #i := 10 TO 0 BY -1 DO' + NL + '    ' + CUR + ';' + NL + 'END_FOR;',
    'Counting loop with step (BY may be negative).');
  Add(C_CTRL, 'WHILE ... DO', 'WHILE ' + CUR + ' DO' + NL + '    ;' + NL + 'END_WHILE;',
    'Loop while the condition is TRUE (checked before each pass).');
  Add(C_CTRL, 'REPEAT ... UNTIL', 'REPEAT' + NL + '    ' + CUR + ';' + NL + 'UNTIL  END_REPEAT;',
    'Loop until the condition is TRUE (checked after each pass).');
  Add(C_CTRL, 'CONTINUE', 'CONTINUE;', 'Skip to the next loop pass.');
  Add(C_CTRL, 'EXIT', 'EXIT;', 'Leave the innermost loop.');
  Add(C_CTRL, 'RETURN', 'RETURN;', 'Leave the block.');
  Add(C_CTRL, 'REGION', 'REGION ' + CUR + 'Name' + NL + '    ;' + NL + 'END_REGION', 'Foldable code region.');
  Add(C_CTRL, ':= (assignment)', CUR + ' := ;', 'Assignment.');
  Add(C_CTRL, '// comment', '// ' + CUR, 'Line comment.');
  Add(C_CTRL, '(* comment *)', '(* ' + CUR + ' *)', 'Block comment.');

  { ---- operators ---- }
  Add(C_OPS, 'AND', ' AND ', 'Logical / bitwise AND (also &).');
  Add(C_OPS, 'OR', ' OR ', 'Logical / bitwise OR.');
  Add(C_OPS, 'XOR', ' XOR ', 'Exclusive OR.');
  Add(C_OPS, 'NOT', 'NOT ', 'Negation.');
  Add(C_OPS, '=', ' = ', 'Equal.');
  Add(C_OPS, '<>', ' <> ', 'Not equal.');
  Add(C_OPS, '<', ' < ', 'Less than.');
  Add(C_OPS, '<=', ' <= ', 'Less or equal.');
  Add(C_OPS, '>', ' > ', 'Greater than.');
  Add(C_OPS, '>=', ' >= ', 'Greater or equal.');
  Add(C_OPS, '+', ' + ', 'Addition (numbers, Time).');
  Add(C_OPS, '-', ' - ', 'Subtraction.');
  Add(C_OPS, '*', ' * ', 'Multiplication.');
  Add(C_OPS, '/', ' / ', 'Division (integer division truncates).');
  Add(C_OPS, 'MOD', ' MOD ', 'Remainder of an integer division.');
  Add(C_OPS, '**', ' ** ', 'Exponent (result Real / LReal).');

  { ---- constants ---- }
  Add(C_CONST, 'TRUE', 'TRUE', 'Bool constant.');
  Add(C_CONST, 'FALSE', 'FALSE', 'Bool constant.');
  Add(C_CONST, 'T#1S (Time)', 'T#1S', 'Time: T#1D2H3M4S5MS (range -24D..24D).');
  Add(C_CONST, 'LT#1MS (LTime)', 'LT#1MS', 'LTime in ns resolution (S7-1500).');
  Add(C_CONST, 'S5T#1S (S5Time)', 'S5T#1S', 'S5Time (S7-300/400).');
  Add(C_CONST, 'D#2024-01-01 (Date)', 'D#2024-01-01', 'Date.');
  Add(C_CONST, 'TOD#12:00:00 (Time_Of_Day)', 'TOD#12:00:00', 'Time of day.');
  Add(C_CONST, 'DT#2024-01-01-12:00:00', 'DT#2024-01-01-12:00:00', 'Date and time.');
  Add(C_CONST, '16#FF (hex)', '16#FF', 'Hexadecimal integer.');
  Add(C_CONST, '2#1010 (binary)', '2#1010', 'Binary integer.');
  Add(C_CONST, 'W#16#0000 (Word)', 'W#16#0000', 'Typed Word constant (also B#, DW#, LW#).');
  Add(C_CONST, 'INT#5 (typed)', 'INT#5', 'Typed integer constant.');
  Add(C_CONST, '''text'' (String)', '''' + CUR + '''', 'String literal. Escape: $N new line, $T tab, $'' quote.');

  { ---- elementary types ---- }
  T := ['Bool', 'Byte', 'Word', 'DWord', 'LWord', 'SInt', 'Int', 'DInt', 'LInt', 'USInt', 'UInt', 'UDInt',
    'ULInt', 'Real', 'LReal', 'Time', 'LTime', 'S5Time', 'Date', 'Time_Of_Day', 'LTime_Of_Day',
    'Date_And_Time', 'LDT', 'Char', 'WChar'];
  for S in T do
    Add(C_TYPES, S, S, Format('%s - %d bit. LInt/ULInt/LWord/LTime/LTOD/LDT: S7-1500 only. ' +
      'SInt/USInt/UInt/UDInt/LReal/WChar: S7-1200/1500. S5Time: S7-300/400.',
      [S, ElementaryBits(FindElementaryType(S).Kind)]));

  { ---- structured types ---- }
  Add(C_CTYPES, 'Array[..] of', 'Array[0..' + CUR + '9] of Int', 'One-dimensional array.');
  Add(C_CTYPES, 'Array[.., ..] of', 'Array[0..' + CUR + '2, 0..3] of Int', 'Two-dimensional array.');
  Add(C_CTYPES, 'Struct', 'Struct' + NL + '    ' + CUR + 'Member : Int;' + NL + 'END_STRUCT', 'Anonymous structure.');
  Add(C_CTYPES, 'String[n]', 'String[' + CUR + '20]', 'String with max. length n (<= 254).');
  Add(C_CTYPES, 'WString[n]', 'WString[' + CUR + '20]', 'Unicode string (S7-1200/1500).');
  Add(C_CTYPES, 'DTL', 'DTL', 'Date and time long (S7-1200/1500).');

  { ---- declaration sections ---- }
  Add(C_DECL, 'VAR_INPUT', 'VAR_INPUT' + NL + '    ' + CUR + 'In1 : Bool;' + NL + 'END_VAR', 'Input parameters.');
  Add(C_DECL, 'VAR_OUTPUT', 'VAR_OUTPUT' + NL + '    ' + CUR + 'Out1 : Bool;' + NL + 'END_VAR', 'Output parameters.');
  Add(C_DECL, 'VAR_IN_OUT', 'VAR_IN_OUT' + NL + '    ' + CUR + 'InOut1 : Int;' + NL + 'END_VAR', 'In/out parameters (by reference).');
  Add(C_DECL, 'VAR (static)', 'VAR' + NL + '    ' + CUR + 'Stat1 : Int;' + NL + 'END_VAR', 'Static variables (FB / DB).');
  Add(C_DECL, 'VAR RETAIN', 'VAR RETAIN' + NL + '    ' + CUR + 'Stat1 : Int;' + NL + 'END_VAR', 'Retentive static variables.');
  Add(C_DECL, 'VAR_TEMP', 'VAR_TEMP' + NL + '    ' + CUR + 'tmp : Int;' + NL + 'END_VAR', 'Temporary variables.');
  Add(C_DECL, 'VAR CONSTANT', 'VAR CONSTANT' + NL + '    ' + CUR + 'C_MAX : Int := 10;' + NL + 'END_VAR', 'Local constants.');

  { ---- block templates ---- }
  Add(C_BLOCKS, 'FUNCTION (FC)', 'FUNCTION "' + CUR + 'NewFC" : Void' + NL + 'VERSION : 0.1' + NL + '   VAR_INPUT' + NL +
    '      IN : Int;' + NL + '   END_VAR' + NL + NL + 'BEGIN' + NL + NL + 'END_FUNCTION', 'Function without memory.');
  Add(C_BLOCKS, 'FUNCTION_BLOCK (FB)', 'FUNCTION_BLOCK "' + CUR + 'NewFB"' + NL + 'VERSION : 0.1' + NL + '   VAR_INPUT' + NL +
    '      Start : Bool;' + NL + '   END_VAR' + NL + '   VAR' + NL + '      Count : DInt;' + NL + '   END_VAR' + NL + NL +
    'BEGIN' + NL + NL + 'END_FUNCTION_BLOCK', 'Function block with instance memory.');
  Add(C_BLOCKS, 'ORGANIZATION_BLOCK (OB)', 'ORGANIZATION_BLOCK "' + CUR + 'Main"' + NL + 'VERSION : 0.1' + NL + NL +
    'BEGIN' + NL + NL + 'END_ORGANIZATION_BLOCK', 'Organization block (Main = OB1, Startup = OB100).');
  Add(C_BLOCKS, 'DATA_BLOCK (global)', 'DATA_BLOCK "' + CUR + 'NewDB"' + NL + 'VERSION : 0.1' + NL + '   VAR' + NL +
    '      Value : Int;' + NL + '   END_VAR' + NL + NL + 'BEGIN' + NL + NL + 'END_DATA_BLOCK', 'Global data block.');
  Add(C_BLOCKS, 'DATA_BLOCK (instance)', 'DATA_BLOCK "' + CUR + 'iNewFB"' + NL + 'VERSION : 0.1' + NL + 'NON_RETAIN' + NL +
    '"NewFB"' + NL + NL + 'BEGIN' + NL + NL + 'END_DATA_BLOCK', 'Instance data block of an FB.');
  Add(C_BLOCKS, 'TYPE (UDT)', 'TYPE "' + CUR + 'typeNew"' + NL + 'VERSION : 0.1' + NL + '   STRUCT' + NL +
    '      Value : Int;' + NL + '   END_STRUCT;' + NL + NL + 'END_TYPE', 'PLC data type.');

  { ---- bit logic / edges ---- }
  Add(C_BIT, 'R_TRIG (rising edge)', '#' + CUR + 'R_TRIG_Instance(CLK := );',
    'Declare in VAR:  R_TRIG_Instance : R_TRIG;' + NL + 'Q = TRUE for one cycle on a rising edge of CLK.');
  Add(C_BIT, 'F_TRIG (falling edge)', '#' + CUR + 'F_TRIG_Instance(CLK := );',
    'Declare in VAR:  F_TRIG_Instance : F_TRIG;');
  Add(C_BIT, 'RS (reset dominant)', '#' + CUR + 'RS_Instance(S := , R1 := );', 'Declare in VAR:  RS_Instance : RS;');
  Add(C_BIT, 'SR (set dominant)', '#' + CUR + 'SR_Instance(S1 := , R := );', 'Declare in VAR:  SR_Instance : SR;');

  { ---- timers ---- }
  Add(C_TIMER, 'TON (on delay)', '#' + CUR + 'TON_Instance(IN := , PT := T#1S);',
    'Declare in VAR:  TON_Instance : TON_TIME;' + NL + 'Q = TRUE after IN was TRUE for PT. Outputs: .Q .ET');
  Add(C_TIMER, 'TOF (off delay)', '#' + CUR + 'TOF_Instance(IN := , PT := T#1S);',
    'Declare in VAR:  TOF_Instance : TOF_TIME;');
  Add(C_TIMER, 'TP (pulse)', '#' + CUR + 'TP_Instance(IN := , PT := T#1S);', 'Declare in VAR:  TP_Instance : TP_TIME;');
  Add(C_TIMER, 'TONR (retentive on delay)', '#' + CUR + 'TONR_Instance(IN := , R := , PT := T#1S);',
    'Declare in VAR:  TONR_Instance : TONR_TIME;  (S7-1200/1500)');
  Add(C_TIMER, 'IEC_TIMER .TON', '#' + CUR + 'IEC_Timer_Instance.TON(IN := , PT := T#1S);',
    'Declare in VAR:  IEC_Timer_Instance : IEC_TIMER;');

  { ---- counters ---- }
  Add(C_CNT, 'CTU (count up)', '#' + CUR + 'CTU_Instance(CU := , R := , PV := 10);',
    'Declare in VAR:  CTU_Instance : CTU_INT;' + NL + 'Outputs: .Q .CV');
  Add(C_CNT, 'CTD (count down)', '#' + CUR + 'CTD_Instance(CD := , LD := , PV := 10);',
    'Declare in VAR:  CTD_Instance : CTD_INT;');
  Add(C_CNT, 'CTUD (up / down)', '#' + CUR + 'CTUD_Instance(CU := , CD := , R := , LD := , PV := 10);',
    'Declare in VAR:  CTUD_Instance : CTUD_INT;  Outputs: .QU .QD .CV');

  { ---- comparison / selection ---- }
  Add(C_CMP, 'MIN', 'MIN(IN1 := ' + CUR + ', IN2 := )', 'Smallest input (2..32 inputs).');
  Add(C_CMP, 'MAX', 'MAX(IN1 := ' + CUR + ', IN2 := )', 'Largest input.');
  Add(C_CMP, 'LIMIT', 'LIMIT(MN := ' + CUR + ', IN := , MX := )', 'Clamp IN to MN..MX.');
  Add(C_CMP, 'SEL', 'SEL(G := ' + CUR + ', IN0 := , IN1 := )', 'G = FALSE -> IN0, G = TRUE -> IN1.');
  Add(C_CMP, 'MUX', 'MUX(K := ' + CUR + ', IN0 := , IN1 := , IN2 := )', 'Select input number K.');

  { ---- math ---- }
  T := ['ABS', 'SQR', 'SQRT', 'EXP', 'LN', 'LOG', 'SIN', 'COS', 'TAN', 'ASIN', 'ACOS', 'ATAN', 'FRAC'];
  for S in T do
    Add(C_MATH, S, S + '(' + CUR + ')', S + '(IN) - floating point math function (ABS also for integers).');

  { ---- conversion ---- }
  Add(C_CONV, 'TRUNC', 'TRUNC(' + CUR + ')', 'Real -> DInt, cut off decimals.');
  Add(C_CONV, 'ROUND', 'ROUND(' + CUR + ')', 'Real -> DInt, round to nearest.');
  Add(C_CONV, 'CEIL', 'CEIL(' + CUR + ')', 'Real -> DInt, round up.');
  Add(C_CONV, 'FLOOR', 'FLOOR(' + CUR + ')', 'Real -> DInt, round down.');
  Add(C_CONV, 'NORM_X', 'NORM_X(MIN := 0, VALUE := ' + CUR + ', MAX := 27648)', 'Normalize VALUE to 0.0..1.0.');
  Add(C_CONV, 'SCALE_X', 'SCALE_X(MIN := 0.0, VALUE := ' + CUR + ', MAX := 100.0)', 'Scale 0.0..1.0 to MIN..MAX.');
  Conv := ['BOOL_TO_INT', 'INT_TO_BOOL', 'INT_TO_DINT', 'DINT_TO_INT', 'INT_TO_REAL', 'DINT_TO_REAL',
    'REAL_TO_INT', 'REAL_TO_DINT', 'REAL_TO_LREAL', 'LREAL_TO_REAL', 'INT_TO_WORD', 'WORD_TO_INT',
    'DINT_TO_DWORD', 'DWORD_TO_DINT', 'BYTE_TO_WORD', 'WORD_TO_BYTE', 'TIME_TO_DINT', 'DINT_TO_TIME',
    'S5TIME_TO_TIME', 'TIME_TO_S5TIME', 'CHAR_TO_BYTE', 'BYTE_TO_CHAR'];
  for S in Conv do
    Add(C_CONV, S, S + '(' + CUR + ')', 'Explicit conversion ' + StringReplace(S, '_TO_', ' -> ', []) +
      '. Every pair of numeric / bit string / time types is available as X_TO_Y.');

  { ---- shift / slice ---- }
  Add(C_SHIFT, 'SHL', 'SHL(IN := ' + CUR + ', N := 1)', 'Shift left.');
  Add(C_SHIFT, 'SHR', 'SHR(IN := ' + CUR + ', N := 1)', 'Shift right.');
  Add(C_SHIFT, 'ROL', 'ROL(IN := ' + CUR + ', N := 1)', 'Rotate left.');
  Add(C_SHIFT, 'ROR', 'ROR(IN := ' + CUR + ', N := 1)', 'Rotate right.');
  Add(C_SHIFT, '.%X0 (bit slice)', '.%X' + CUR + '0', 'Bit n of a bit string / integer (S7-1200/1500).');
  Add(C_SHIFT, '.%B0 (byte slice)', '.%B' + CUR + '0', 'Byte n (B0 = least significant).');
  Add(C_SHIFT, '.%W0 (word slice)', '.%W' + CUR + '0', 'Word n.');
  Add(C_SHIFT, '.%D0 (dword slice)', '.%D' + CUR + '0', 'DWord n.');

  { ---- string ---- }
  Add(C_STR, 'LEN', 'LEN(' + CUR + ')', 'Current length of a string.');
  Add(C_STR, 'CONCAT', 'CONCAT(IN1 := ' + CUR + ', IN2 := )', 'Join two strings.');
  Add(C_STR, 'LEFT', 'LEFT(IN := ' + CUR + ', L := 1)', 'First L characters.');
  Add(C_STR, 'RIGHT', 'RIGHT(IN := ' + CUR + ', L := 1)', 'Last L characters.');
  Add(C_STR, 'MID', 'MID(IN := ' + CUR + ', L := 1, P := 1)', 'L characters from position P.');
  Add(C_STR, 'FIND', 'FIND(IN1 := ' + CUR + ', IN2 := )', 'Position of IN2 in IN1 (0 = not found).');

  { project categories (filled by UpdateProject) }
  AddCat('Project: PLC tags', True);
  AddCat('Project: Data blocks', True);
  AddCat('Project: Functions (FC)', True);
  AddCat('Project: Function blocks (FB)', True);
  AddCat('Project: PLC data types', True);
end;

procedure TElementsPanel.RememberExpanded;
var
  N: TTreeNode;
  Nm: string;
begin
  N := FTree.Items.GetFirstNode;
  while N <> nil do
  begin
    Nm := N.Text;
    if LastDelimiter('(', Nm) > 1 then Nm := Copy(Nm, 1, LastDelimiter('(', Nm) - 2);
    if N.Expanded then FExpanded.Add(Nm)
    else if FExpanded.IndexOf(Nm) >= 0 then FExpanded.Delete(FExpanded.IndexOf(Nm));
    N := N.GetNextSibling;
  end;
end;

procedure TElementsPanel.Rebuild;
var
  I, J: Integer;
  Cat: TTreeNode;
  L: TList;
  It: TElemItem;
  F: string;
  Any: Boolean;
begin
  F := LowerCase(Trim(FFilter.Text));
  FTree.Items.BeginUpdate;
  try
    if FTree.Items.Count > 0 then RememberExpanded;
    FTree.Items.Clear;
    for I := 0 to FCats.Count - 1 do
    begin
      L := TList(FCats.Objects[I]);
      Any := False;
      Cat := nil;
      for J := 0 to L.Count - 1 do
      begin
        It := TElemItem(L[J]);
        if (F <> '') and (Pos(F, LowerCase(It.Caption)) = 0) and (Pos(F, LowerCase(It.Snippet)) = 0) then Continue;
        if Cat = nil then Cat := FTree.Items.Add(nil, FCats[I]);
        FTree.Items.AddChildObject(Cat, It.Caption, It);
        Any := True;
      end;
      if (Cat = nil) and (F = '') then
        Cat := FTree.Items.Add(nil, FCats[I]);   // keep empty project categories visible
      if Cat <> nil then
      begin
        Cat.Text := Format('%s (%d)', [FCats[I], Cat.Count]);
        if Any and ((F <> '') or (FExpanded.IndexOf(FCats[I]) >= 0)) then Cat.Expand(False);
      end;
    end;
  finally
    FTree.Items.EndUpdate;
  end;
end;

procedure TElementsPanel.UpdateProject(C: TSclCompiler);
var
  I, J, K: Integer;
  B: TBlockInfo;
  T: TTagInfo;
  Args, Snip, Ins, Desc, Ret: string;
  M: TMember;
  It: TElemItem;
  L: TList;
begin
  { remove old project items }
  for I := 0 to FProjectCats.Count - 1 do
  begin
    K := FCats.IndexOf(FProjectCats[I]);
    L := TList(FCats.Objects[K]);
    for J := 0 to L.Count - 1 do FItems.Remove(TObject(L[J]));
    L.Clear;
  end;
  if C <> nil then
  begin
    for I := 0 to C.TagCount - 1 do
    begin
      T := C.TagInfos[I];
      if T.IsConst then
        Add('Project: PLC tags', T.Name + '  (constant)', '"' + T.Name + '"',
          Format('User constant %s : %s = %s' + NL + '%s', [T.Name, TypeName(T.Typ), T.Tag.Value, T.Tag.Comment]))
      else
        Add('Project: PLC tags', T.Name + '  ' + T.Tag.Address, '"' + T.Name + '"',
          Format('PLC tag %s : %s  %s' + NL + '%s', [T.Name, TypeName(T.Typ), T.Tag.Address, T.Tag.Comment]));
    end;
    for I := 0 to C.BlockCount - 1 do
    begin
      B := C.Blocks[I];
      case B.Kind of
        ukDB:
          begin
            if B.DBInstOf <> nil then
            begin
              Args := '';
              if B.DataType <> nil then
                for J := 0 to B.DataType.MemberCount - 1 do
                begin
                  M := B.DataType.Member(J);
                  if M.Section = msInput then
                  begin
                    if Args <> '' then Args := Args + ',' + NL + '    ';
                    if Args = '' then Ins := CUR else Ins := '';
                    Args := Args + M.Name + ' := ' + Ins;
                  end;
                end;
              Snip := '"' + B.Name + '"(' + Args + ');';
              if Pos(CUR, Snip) = 0 then Snip := Snip + CUR;
              Desc := Format('DB%d "%s" - instance of FB "%s". Drop = single instance call.', [B.Number, B.Name,
                B.DBInstOf.Name]);
            end
            else
            begin
              Snip := '"' + B.Name + '".' + CUR;
              Desc := Format('DB%d "%s" - global data block (%d bytes)', [B.Number, B.Name, B.SizeBytes]);
            end;
            Add('Project: Data blocks', Format('DB%d %s', [B.Number, B.Name]), Snip, Desc);
          end;
        ukFC:
          begin
            Args := '';
            if B.ParamType <> nil then
              for J := 0 to B.ParamType.MemberCount - 1 do
              begin
                M := B.ParamType.Member(J);
                if M.Section = msReturn then Continue;
                if Args <> '' then Args := Args + ', ';
                if Args = '' then Ins := CUR else Ins := '';
                if M.Section = msOutput then Args := Args + M.Name + ' => ' + Ins
                else Args := Args + M.Name + ' := ' + Ins;
              end;
            Snip := '"' + B.Name + '"(' + Args + ')';
            if (B.RetType = nil) or (B.RetType.Kind = tkVoid) then Snip := Snip + ';';
            if Pos(CUR, Snip) = 0 then Snip := Snip + CUR;
            if (B.RetType <> nil) and (B.RetType.Kind <> tkVoid) then Ret := ' : ' + TypeName(B.RetType) else Ret := ' : Void';
            Add('Project: Functions (FC)', Format('FC%d %s', [B.Number, B.Name]), Snip,
              Format('FC%d "%s"%s' + NL + '%s', [B.Number, B.Name, Ret, B.U.Title]));
          end;
        ukFB:
          begin
            Args := '';
            if B.DataType <> nil then
              for J := 0 to B.DataType.MemberCount - 1 do
              begin
                M := B.DataType.Member(J);
                if M.Section = msInput then
                begin
                  if Args <> '' then Args := Args + ',' + NL + '    ';
                  Args := Args + M.Name + ' := ';
                end;
              end;
            Add('Project: Function blocks (FB)', Format('FB%d %s  (declare)', [B.Number, B.Name]),
              CUR + 'Instance : "' + B.Name + '";',
              Format('Multi-instance declaration of FB%d "%s" (put it in VAR of an FB).', [B.Number, B.Name]));
            Add('Project: Function blocks (FB)', Format('FB%d %s  (call)', [B.Number, B.Name]),
              '#' + CUR + 'Instance(' + Args + ');',
              Format('Multi-instance call of FB%d "%s". Rename #Instance to the declared instance.', [B.Number, B.Name]));
          end;
        ukUDT:
          Add('Project: PLC data types', B.Name, '"' + B.Name + '"' + CUR,
            Format('PLC data type "%s" (%d bytes)', [B.Name, B.SizeBytes]));
      end;
    end;
  end;
  Rebuild;
end;

procedure TElementsPanel.FilterChange(Sender: TObject);
begin
  Rebuild;
end;

procedure TElementsPanel.TreeChange(Sender: TObject; Node: TTreeNode);
var
  It: TElemItem;
begin
  if (Node <> nil) and (TObject(Node.Data) is TElemItem) then
  begin
    It := TElemItem(Node.Data);
    FDescr.Text := It.Descr + NL + NL + StringReplace(It.Snippet, CUR, '', [rfReplaceAll]);
  end
  else
    FDescr.Text := 'Drag an element into the SCL editor, or double click it to insert at the cursor.';
end;

procedure TElementsPanel.TreeDblClick(Sender: TObject);
var
  N: TTreeNode;
begin
  N := FTree.Selected;
  if (N <> nil) and (TObject(N.Data) is TElemItem) and Assigned(OnInsertSnippet) then
    OnInsertSnippet(TElemItem(N.Data).Snippet);
end;

procedure TElementsPanel.TreeMouseDown(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  FDragNode := nil;
  if Button <> mbLeft then Exit;
  FDragNode := FTree.GetNodeAt(X, Y);
  if (FDragNode <> nil) and not (TObject(FDragNode.Data) is TElemItem) then FDragNode := nil;
  FDownPos := Point(X, Y);
end;

procedure TElementsPanel.TreeMouseMove(Sender: TObject; Shift: TShiftState; X, Y: Integer);
begin
  if (FDragNode <> nil) and (ssLeft in Shift) and
     ((Abs(X - FDownPos.X) > 5) or (Abs(Y - FDownPos.Y) > 5)) then
  begin
    FTree.Selected := FDragNode;
    FTree.BeginDrag(True);
  end;
end;

procedure TElementsPanel.TreeMouseUp(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  FDragNode := nil;
end;

function TElementsPanel.IsElementDrag(Source: TObject): Boolean;
begin
  Result := (Source = FTree) and (FTree.Selected <> nil) and (TObject(FTree.Selected.Data) is TElemItem);
end;

function TElementsPanel.DraggedSnippet: string;
begin
  if IsElementDrag(FTree) then Result := TElemItem(FTree.Selected.Data).Snippet else Result := '';
end;

procedure TElementsPanel.CloseClick(Sender: TObject);
begin
  if Assigned(OnClosePanel) then OnClosePanel(Self);
end;

end.
