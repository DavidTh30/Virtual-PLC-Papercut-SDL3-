unit uSclSig;

{ The parameter help of the SCL editor: the call the caret is in (an FB instance "Inst"( / #Inst(, an FC
  "Fc"(, a system FB instance of TON_TIME .., a function SEL( LIMIT( ..), its signature (the parameters
  with their direction and type), the template of the call with placeholders as TIA writes them
  (_bool_in_, _time_out_), and the variables of the project that fit a parameter's type. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, StrUtils, Math, uPlcTypes, uPlcProject;

type
  TSigDir = (sdIn, sdOut, sdInOut);

  TSigParam = record
    Name, TypeText, Comment: string;
    Dir: TSigDir;
  end;

  TSclSig = record
    Callee: string;      // as written: "Motor_DB", #Delay, SEL
    Title: string;       // what it is: FB "Motor", TON_TIME, function
    Params: array of TSigParam;
    RetType: string;     // a function: its value ('' an FB / a system FB)
    Variadic: Boolean;   // MUX, MIN, MAX: IN0, IN1, .. and more
    Descr: string;
  end;

  { the call around the caret }
  TSclCall = record
    Callee: string;
    OpenRow, OpenCol: Integer;   // the "(" (row, character column)
    Seg: Integer;                // the argument the caret is in (0 = the first)
    SegText: string;             // its text up to the caret
    Given: TStringList;          // the parameters already given (upper case); the caller frees it
    Stmt: Boolean;               // the call is a statement of its own (not inside an expression)
  end;

const
  SigDirNames: array[TSigDir] of string = ('Input', 'Output', 'InOut');

{ the call the caret is in: Lines are the network's lines, the caret at (Row, Col) }
function SclCallAt(Lines: TStrings; Row, Col: Integer; out C: TSclCall): Boolean;
{ the signature of a callee of the block Cur (its interface) in the project }
function SclSignature(P: TPlcProject; Cur: TBlock; const Callee: string; out S: TSclSig): Boolean;
{ the placeholder of a parameter as TIA writes it: _bool_in_, _time_out_, _int_inout_ }
function SclPlaceholder(const TypeText: string; Dir: TSigDir): string;
function IsSclPlaceholder(const S: string): Boolean;
{ the parameter list from the first one not given: one per line, aligned under the first (Indent: the
  column of the first parameter), with ')' and ';' when Close / Semi }
function SclCallTemplate(const S: TSclSig; Given: TStrings; Indent: Integer; Close, Semi: Boolean): string;
{ the same as the ghost on one line: the placeholders as their types: IN := <Bool>, PT := <Time> .. }
function SclCallGhost(const S: TSclSig; Given: TStrings; Close, Semi: Boolean): string;
{ a value of type Have fits a parameter of type Want (ANY, ANY_NUM, ANY_BIT, ANY_INT, STRING ..) }
function SclTypeFits(const Want, Have: string): Boolean;
{ the variables that fit a type: #temps / interface, "tags", "DB".vars (Max of them) }
function SclFitting(P: TPlcProject; Cur: TBlock; const Want: string; Max: Integer): TStringList;
{ the parameter the caret is at: by its name (Name :=), else the argument's position, else the first one not given }
function SclCurParam(const S: TSclSig; const C: TSclCall): Integer;
{ the next placeholder at or after (Row, Col) in Lines, up to MaxRows rows on: its row, column and length }
function SclNextPlaceholder(Lines: TStrings; Row, Col, MaxRows: Integer; out PRow, PCol, PLen: Integer): Boolean;

implementation

const
  Kw: array[0..19] of string = ('IF', 'THEN', 'ELSIF', 'WHILE', 'UNTIL', 'CASE', 'AND', 'OR', 'XOR', 'NOT', 'MOD',
    'RETURN', 'DO', 'TO', 'BY', 'FOR', 'OF', 'ELSE', 'REPEAT', 'EXIT');

function IsKw(const S: string): Boolean;
var
  K: Integer;
begin
  Result := False;
  for K := 0 to High(Kw) do
    if SameText(Kw[K], S) then Exit(True);
end;

procedure AddP(var S: TSclSig; const Nm, Ty: string; D: TSigDir; const Cm: string = '');
var
  K: Integer;
begin
  K := Length(S.Params);
  SetLength(S.Params, K + 1);
  S.Params[K].Name := Nm;
  S.Params[K].TypeText := Ty;
  S.Params[K].Dir := D;
  S.Params[K].Comment := Cm;
end;

{ the callee written before a "(" at character index I (0-based) of the text T: "DB".x.y, #a.b, NAME }
function CalleeBefore(const T: UnicodeString; I: Integer): string;
var
  K, E: Integer;
begin
  Result := '';
  K := I - 1;
  while (K >= 0) and (T[K + 1] = ' ') do Dec(K);
  E := K;
  while K >= 0 do
  begin
    if T[K + 1] = '"' then
    begin
      // a quoted name: back to its first quote
      Dec(K);
      while (K >= 0) and (T[K + 1] <> '"') do Dec(K);
      Dec(K);
    end
    else if CharInSet(T[K + 1], ['A'..'Z', 'a'..'z', '0'..'9', '_', '.', '#']) then
      Dec(K)
    else
      Break;
  end;
  if E < 0 then Exit;
  Result := UTF8Encode(Copy(T, K + 2, E - K));
end;

function SclCallAt(Lines: TStrings; Row, Col: Integer; out C: TSclCall): Boolean;
var
  T: UnicodeString;
  R, I, K, N, Depth, Start: Integer;
  Stack: array of record
    Pos: Integer;
    Callee: string;
  end;
  RowOf: array of Integer;   // the row of each character
  ColOf: array of Integer;
  Ch: WideChar;
  Seg, Nm: string;
  P: Integer;

  procedure AddLine(const S: UnicodeString; ARow: Integer);
  var
    J: Integer;
  begin
    for J := 1 to Length(S) do
    begin
      T := T + S[J];
      SetLength(RowOf, Length(T));
      SetLength(ColOf, Length(T));
      RowOf[High(RowOf)] := ARow;
      ColOf[High(ColOf)] := J - 1;
    end;
    T := T + #10;
    SetLength(RowOf, Length(T));
    SetLength(ColOf, Length(T));
    RowOf[High(RowOf)] := ARow;
    ColOf[High(ColOf)] := Length(S);
  end;

begin
  Result := False;
  C.Callee := '';
  C.Given := nil;
  C.Seg := 0;
  C.SegText := '';
  C.Stmt := False;
  if (Lines = nil) or (Row < 0) or (Row >= Lines.Count) then Exit;
  // the code up to the caret (at most 60 lines back)
  T := '';
  RowOf := nil;
  ColOf := nil;
  for R := Max(0, Row - 60) to Row - 1 do AddLine(UTF8Decode(Lines[R]), R);
  AddLine(Copy(UTF8Decode(Lines[Row]), 1, Col), Row);
  SetLength(T, Length(T) - 1);   // no line end after the caret
  Stack := nil;
  I := 0;
  N := Length(T);
  while I < N do
  begin
    Ch := T[I + 1];
    if (Ch = '/') and (I + 1 < N) and (T[I + 2] = '/') then
    begin
      while (I < N) and (T[I + 1] <> #10) do Inc(I);
      Continue;
    end;
    if (Ch = '(') and (I + 1 < N) and (T[I + 2] = '*') then
    begin
      Inc(I, 2);
      while (I + 1 < N) and not ((T[I + 1] = '*') and (T[I + 2] = ')')) do Inc(I);
      Inc(I, 2);
      Continue;
    end;
    if Ch = '''' then
    begin
      Inc(I);
      while (I < N) and (T[I + 1] <> '''') do Inc(I);
      Inc(I);
      Continue;
    end;
    if Ch = '"' then
    begin
      Inc(I);
      while (I < N) and (T[I + 1] <> '"') do Inc(I);
      Inc(I);
      Continue;
    end;
    if Ch = '(' then
    begin
      SetLength(Stack, Length(Stack) + 1);
      Stack[High(Stack)].Pos := I;
      Stack[High(Stack)].Callee := CalleeBefore(T, I);
      if IsKw(Stack[High(Stack)].Callee) or (Stack[High(Stack)].Callee = '') or
        CharInSet(Stack[High(Stack)].Callee[1], ['0'..'9', '.']) then Stack[High(Stack)].Callee := '';
    end
    else if (Ch = ')') and (Length(Stack) > 0) then
      SetLength(Stack, High(Stack))
    else if (Ch = ';') then
      Stack := nil;   // a statement ended: no call is open
    Inc(I);
  end;
  if Length(Stack) = 0 then Exit;
  if Stack[High(Stack)].Callee = '' then Exit;
  C.Callee := Stack[High(Stack)].Callee;
  Start := Stack[High(Stack)].Pos;
  C.OpenRow := RowOf[Start];
  C.OpenCol := ColOf[Start];
  // the statement: nothing but blanks before the callee on its line (and no := before it)
  K := Start - 1;
  while (K >= 0) and (T[K + 1] <> #10) do Dec(K);
  Seg := Trim(UTF8Encode(Copy(T, K + 2, Start - K - 1)));
  C.Stmt := SameText(Seg, C.Callee) and (Length(Stack) = 1);
  // the arguments: commas at the depth of the call
  C.Given := TStringList.Create;
  C.Given.CaseSensitive := False;
  Depth := 0;
  Seg := '';
  I := Start + 1;
  while I < N do
  begin
    Ch := T[I + 1];
    if (Ch = '''') or (Ch = '"') then
    begin
      // a string literal / a quoted name: as it is
      K := I + 1;
      while (K < N) and (T[K + 1] <> Ch) do Inc(K);
      Seg := Seg + UTF8Encode(Copy(T, I + 1, K - I + 1));
      I := K + 1;
      Continue;
    end;
    if CharInSet(Ch, ['(', '[']) then Inc(Depth)
    else if CharInSet(Ch, [')', ']']) then Dec(Depth);
    if (Ch = ',') and (Depth = 0) then
    begin
      P := Pos(':=', Seg);
      if P = 0 then P := Pos('=>', Seg);
      if P > 0 then
      begin
        Nm := Trim(Copy(Seg, 1, P - 1));
        C.Given.Add(UpperCase(Nm));
      end;
      Inc(C.Seg);
      Seg := '';
    end
    else if Ch = #10 then Seg := Seg + ' '
    else Seg := Seg + UTF8Encode(UnicodeString(Ch));
    Inc(I);
  end;
  C.SegText := TrimLeft(Seg);
  Result := True;
end;

function SysFbSig(const TypeText, Method: string; var S: TSclSig): Boolean;
var
  U, Tt, Ct: string;
begin
  Result := True;
  U := UpperCase(Trim(TypeText));
  if (U = 'IEC_TIMER') or (U = 'IEC_LTIMER') then
  begin
    if Method = '' then Exit(False);
    U := UpperCase(Method) + '_TIME';
  end;
  if U = 'IEC_COUNTER' then
  begin
    if Method = '' then Exit(False);
    U := UpperCase(Method) + '_INT';
  end;
  if AnsiEndsStr('_LTIME', U) then Tt := 'LTime' else Tt := 'Time';
  Ct := 'Int';
  if AnsiEndsStr('_DINT', U) then Ct := 'DInt'
  else if AnsiEndsStr('_UDINT', U) then Ct := 'UDInt'
  else if AnsiEndsStr('_UINT', U) then Ct := 'UInt'
  else if AnsiEndsStr('_SINT', U) then Ct := 'SInt'
  else if AnsiEndsStr('_USINT', U) then Ct := 'USInt'
  else if AnsiEndsStr('_LINT', U) then Ct := 'LInt';
  S.Title := TypeText;
  if AnsiStartsStr('TONR', U) then
  begin
    AddP(S, 'IN', 'Bool', sdIn, 'the time adds up while IN is TRUE');
    AddP(S, 'R', 'Bool', sdIn, 'reset: ET := 0');
    AddP(S, 'PT', Tt, sdIn, 'the preset time');
    AddP(S, 'Q', 'Bool', sdOut, 'TRUE when ET reached PT');
    AddP(S, 'ET', Tt, sdOut, 'the time elapsed');
  end
  else if AnsiStartsStr('TON', U) or AnsiStartsStr('TOF', U) or AnsiStartsStr('TP', U) then
  begin
    AddP(S, 'IN', 'Bool', sdIn, 'the start input');
    AddP(S, 'PT', Tt, sdIn, 'the preset time (e.g. T#5S)');
    AddP(S, 'Q', 'Bool', sdOut, 'the output');
    AddP(S, 'ET', Tt, sdOut, 'the time elapsed');
  end
  else if AnsiStartsStr('CTUD', U) then
  begin
    AddP(S, 'CU', 'Bool', sdIn, 'count up (rising edge)');
    AddP(S, 'CD', 'Bool', sdIn, 'count down (rising edge)');
    AddP(S, 'R', 'Bool', sdIn, 'reset: CV := 0');
    AddP(S, 'LD', 'Bool', sdIn, 'load: CV := PV');
    AddP(S, 'PV', Ct, sdIn, 'the preset value');
    AddP(S, 'QU', 'Bool', sdOut, 'CV >= PV');
    AddP(S, 'QD', 'Bool', sdOut, 'CV <= 0');
    AddP(S, 'CV', Ct, sdOut, 'the count');
  end
  else if AnsiStartsStr('CTU', U) then
  begin
    AddP(S, 'CU', 'Bool', sdIn, 'count up (rising edge)');
    AddP(S, 'R', 'Bool', sdIn, 'reset: CV := 0');
    AddP(S, 'PV', Ct, sdIn, 'the preset value');
    AddP(S, 'Q', 'Bool', sdOut, 'CV >= PV');
    AddP(S, 'CV', Ct, sdOut, 'the count');
  end
  else if AnsiStartsStr('CTD', U) then
  begin
    AddP(S, 'CD', 'Bool', sdIn, 'count down (rising edge)');
    AddP(S, 'LD', 'Bool', sdIn, 'load: CV := PV');
    AddP(S, 'PV', Ct, sdIn, 'the preset value');
    AddP(S, 'Q', 'Bool', sdOut, 'CV <= 0');
    AddP(S, 'CV', Ct, sdOut, 'the count');
  end
  else if (U = 'R_TRIG') or (U = 'F_TRIG') then
  begin
    AddP(S, 'CLK', 'Bool', sdIn, 'the signal');
    AddP(S, 'Q', 'Bool', sdOut, 'TRUE for one call at the edge');
  end
  else if U = 'RS' then
  begin
    AddP(S, 'S', 'Bool', sdIn, 'set');
    AddP(S, 'R1', 'Bool', sdIn, 'reset (dominant)');
    AddP(S, 'Q1', 'Bool', sdOut, 'the flip flop');
  end
  else if U = 'SR' then
  begin
    AddP(S, 'S1', 'Bool', sdIn, 'set (dominant)');
    AddP(S, 'R', 'Bool', sdIn, 'reset');
    AddP(S, 'Q1', 'Bool', sdOut, 'the flip flop');
  end
  else
    Result := False;
end;

function FuncSig(const Name: string; var S: TSclSig): Boolean;
var
  U, A, B: string;
  P: Integer;
begin
  Result := True;
  U := UpperCase(Name);
  S.Title := 'function ' + U;
  case U of
    'SEL':
      begin
        AddP(S, 'G', 'Bool', sdIn, 'FALSE: IN0, TRUE: IN1');
        AddP(S, 'IN0', 'ANY', sdIn);
        AddP(S, 'IN1', 'ANY', sdIn);
        S.RetType := 'ANY';
      end;
    'MUX':
      begin
        AddP(S, 'K', 'Int', sdIn, 'which input: 0 .. n');
        AddP(S, 'IN0', 'ANY', sdIn);
        AddP(S, 'IN1', 'ANY', sdIn);
        S.RetType := 'ANY';
        S.Variadic := True;
      end;
    'LIMIT':
      begin
        AddP(S, 'MN', 'ANY_NUM', sdIn, 'the low limit');
        AddP(S, 'IN', 'ANY_NUM', sdIn, 'the value');
        AddP(S, 'MX', 'ANY_NUM', sdIn, 'the high limit');
        S.RetType := 'ANY_NUM';
      end;
    'MIN', 'MAX':
      begin
        AddP(S, 'IN1', 'ANY_NUM', sdIn);
        AddP(S, 'IN2', 'ANY_NUM', sdIn);
        S.RetType := 'ANY_NUM';
        S.Variadic := True;
      end;
    'NORM_X':
      begin
        AddP(S, 'MIN', 'ANY_NUM', sdIn, 'the low end of the range');
        AddP(S, 'VALUE', 'ANY_NUM', sdIn, 'the value (e.g. an analog input)');
        AddP(S, 'MAX', 'ANY_NUM', sdIn, 'the high end (27648)');
        S.RetType := 'Real';
      end;
    'SCALE_X':
      begin
        AddP(S, 'MIN', 'ANY_NUM', sdIn, 'the low end of the range');
        AddP(S, 'VALUE', 'Real', sdIn, '0.0 .. 1.0');
        AddP(S, 'MAX', 'ANY_NUM', sdIn, 'the high end');
        S.RetType := 'ANY_NUM';
      end;
    'CONCAT':
      begin
        AddP(S, 'IN1', 'String', sdIn);
        AddP(S, 'IN2', 'String', sdIn);
        S.RetType := 'String';
      end;
    'LEN':
      begin
        AddP(S, 'IN', 'String', sdIn);
        S.RetType := 'Int';
      end;
    'LEFT', 'RIGHT':
      begin
        AddP(S, 'IN', 'String', sdIn);
        AddP(S, 'L', 'Int', sdIn, 'the number of characters');
        S.RetType := 'String';
      end;
    'MID':
      begin
        AddP(S, 'IN', 'String', sdIn);
        AddP(S, 'L', 'Int', sdIn, 'the number of characters');
        AddP(S, 'P', 'Int', sdIn, 'the first character (1 ..)');
        S.RetType := 'String';
      end;
    'FIND':
      begin
        AddP(S, 'IN1', 'String', sdIn, 'the text');
        AddP(S, 'IN2', 'String', sdIn, 'what is looked for');
        S.RetType := 'Int';
      end;
    'SHL', 'SHR', 'ROL', 'ROR':
      begin
        AddP(S, 'IN', 'ANY_BIT', sdIn);
        AddP(S, 'N', 'Int', sdIn, 'the number of bits');
        S.RetType := 'ANY_BIT';
      end;
    'ABS':
      begin
        AddP(S, 'IN', 'ANY_NUM', sdIn);
        S.RetType := 'ANY_NUM';
      end;
    'SQR', 'SQRT', 'EXP', 'LN', 'LOG', 'SIN', 'COS', 'TAN', 'ASIN', 'ACOS', 'ATAN', 'FRAC':
      begin
        AddP(S, 'IN', 'Real', sdIn);
        S.RetType := 'Real';
      end;
    'TRUNC', 'ROUND', 'CEIL', 'FLOOR':
      begin
        AddP(S, 'IN', 'Real', sdIn);
        S.RetType := 'DInt';
      end;
    'EXPT':
      begin
        AddP(S, 'IN1', 'Real', sdIn, 'the base');
        AddP(S, 'IN2', 'ANY_NUM', sdIn, 'the exponent');
        S.RetType := 'Real';
      end;
    'SRT_DINT':
      begin
        AddP(S, 'OB_NR', 'Int', sdIn, 'the time delay interrupt OB (OB20 ..)');
        AddP(S, 'DTIME', 'Time', sdIn, 'the delay: 1 ms .. 60 s');
        AddP(S, 'SIGN', 'Word', sdIn, 'passed to the OB (#Sign)');
        S.RetType := 'Int';
        S.Descr := 'Starts a time delay interrupt OB; RET_VAL 0 or an error (16#8090: no such OB).';
      end;
    'CAN_DINT':
      begin
        AddP(S, 'OB_NR', 'Int', sdIn, 'the time delay interrupt OB');
        S.RetType := 'Int';
        S.Descr := 'Cancels a time delay interrupt that was started.';
      end;
  else
    begin
      // X_TO_Y: a conversion
      P := Pos('_TO_', U);
      if P > 1 then
      begin
        A := Copy(U, 1, P - 1);
        B := Copy(U, P + 4, MaxInt);
        AddP(S, 'IN', A, sdIn);
        S.RetType := B;
        S.Title := 'conversion ' + U;
      end
      else
        Result := False;
    end;
  end;
end;

procedure BlockSig(B: TBlock; var S: TSclSig);
var
  K: Integer;
begin
  for K := 0 to High(B.Iface.Vars) do
    with B.Iface.Vars[K] do
      case Section of
        vsInput: AddP(S, Name, TypeText, sdIn, Comment);
        vsOutput: AddP(S, Name, TypeText, sdOut, Comment);
        vsInOut: AddP(S, Name, TypeText, sdInOut, Comment);
        vsReturn: S.RetType := TypeText;
      end;
  if (B.Kind = bkFC) and (S.RetType = '') then S.RetType := 'Void';
  S.Title := Format('%s "%s"', [B.Title, B.Name]);
  S.Descr := B.Comment;
end;

{ the type of a variable: #a (the interface of Cur), "DB".a, "Tag" }
function FbOfType(P: TPlcProject; const TypeText: string): TBlock;
var
  K: Integer;
  Nm: string;
begin
  Result := nil;
  Nm := Trim(TypeText);
  if (Length(Nm) > 2) and (Nm[1] = '"') then Nm := Copy(Nm, 2, Length(Nm) - 2);
  for K := 0 to P.BlockCount - 1 do
    if (P.Block(K).Kind = bkFB) and (SameText(P.Block(K).Name, Nm) or SameText(Format('FB%d', [P.Block(K).Number]), Nm)) then
      Exit(P.Block(K));
end;

function SclSignature(P: TPlcProject; Cur: TBlock; const Callee: string; out S: TSclSig): Boolean;
var
  Nm, Rest, Ty, Method: string;
  K, Q: Integer;
  B: TBlock;
  D: TDataBlock;
  Parts: TStringArray;
begin
  Result := False;
  S.Callee := Callee;
  S.Title := '';
  S.Params := nil;
  S.RetType := '';
  S.Variadic := False;
  S.Descr := '';
  if Callee = '' then Exit;
  if Callee[1] = '#' then
  begin
    // a multi-instance / a system FB of the interface: #Delay, #T.TON
    if Cur = nil then Exit;
    Parts := Copy(Callee, 2, MaxInt).Split(['.']);
    if Length(Parts) = 0 then Exit;
    K := Cur.Iface.FindVar(Parts[0]);
    if K < 0 then Exit;
    Ty := Cur.Iface.Vars[K].TypeText;
    if Length(Parts) > 1 then Method := Parts[High(Parts)] else Method := '';
    B := FbOfType(P, Ty);
    if B <> nil then BlockSig(B, S)
    else if not SysFbSig(Ty, Method, S) then Exit;
    S.Title := Callee + ' : ' + S.Title;
    Exit(True);
  end;
  if Callee[1] = '"' then
  begin
    Q := PosEx('"', Callee, 2);
    if Q = 0 then Exit;
    Nm := Copy(Callee, 2, Q - 2);
    Rest := Copy(Callee, Q + 1, MaxInt);
    if Rest = '' then
    begin
      // an FC, or the instance DB of an FB
      for K := 0 to P.BlockCount - 1 do
        if (P.Block(K).Kind = bkFC) and SameText(P.Block(K).Name, Nm) then
        begin
          BlockSig(P.Block(K), S);
          Exit(True);
        end;
      D := P.FindDBByName(Nm);
      if (D <> nil) and (D.InstanceOf > 0) then
      begin
        B := P.FindBlock(bkFB, D.InstanceOf);
        if B = nil then Exit;
        BlockSig(B, S);
        S.Title := Format('"%s" : instance of %s', [Nm, S.Title]);
        Exit(True);
      end;
      Exit;
    end;
    // "DB".Timer / "DB".Timer.TON: a system FB in a global DB
    D := P.FindDBByName(Nm);
    if D = nil then Exit;
    Parts := Copy(Rest, 2, MaxInt).Split(['.']);
    if Length(Parts) = 0 then Exit;
    K := D.FindVar(Parts[0]);
    if K < 0 then Exit;
    if Length(Parts) > 1 then Method := Parts[High(Parts)] else Method := '';
    B := FbOfType(P, D.Vars[K].TypeText);
    if B <> nil then BlockSig(B, S)
    else if not SysFbSig(D.Vars[K].TypeText, Method, S) then Exit;
    S.Title := Callee + ' : ' + S.Title;
    Exit(True);
  end;
  Result := FuncSig(Callee, S);
end;

function SclPlaceholder(const TypeText: string; Dir: TSigDir): string;
var
  T: string;
  K: Integer;
begin
  T := '';
  for K := 1 to Length(TypeText) do
    if TypeText[K] in ['A'..'Z', 'a'..'z', '0'..'9', '_'] then T := T + LowerCase(TypeText[K]);
  if (T = '') or (Pos('array', T) = 1) then T := 'variant';
  while (Length(T) > 0) and (T[Length(T)] = '_') do SetLength(T, Length(T) - 1);
  case Dir of
    sdOut: Result := '_' + T + '_out_';
    sdInOut: Result := '_' + T + '_inout_';
  else
    Result := '_' + T + '_in_';
  end;
end;

function IsSclPlaceholder(const S: string): Boolean;
begin
  Result := (Length(S) >= 6) and (S[1] = '_') and (AnsiEndsStr('_in_', S) or AnsiEndsStr('_out_', S) or
    AnsiEndsStr('_inout_', S));
end;

function Assign(D: TSigDir): string;
begin
  if D = sdOut then Result := ' => ' else Result := ' := ';
end;

function Positional(const S: TSclSig): Boolean;
begin
  // ABS(x), LEN(s), INT_TO_REAL(i): one argument without its name
  Result := (Length(S.Params) = 1) and (S.RetType <> '') and (S.RetType <> 'Void');
end;

function SclCallTemplate(const S: TSclSig; Given: TStrings; Indent: Integer; Close, Semi: Boolean): string;
var
  K, N: Integer;
  Pad: string;
begin
  Result := '';
  if Positional(S) then
  begin
    if (Given = nil) or (Given.Count = 0) then Result := SclPlaceholder(S.Params[0].TypeText, sdIn);
  end
  else
  begin
    Pad := StringOfChar(' ', Indent);
    N := 0;
    for K := 0 to High(S.Params) do
    begin
      if (Given <> nil) and (Given.IndexOf(UpperCase(S.Params[K].Name)) >= 0) then Continue;
      if N > 0 then Result := Result + ',' + LineEnding + Pad;
      Result := Result + S.Params[K].Name + Assign(S.Params[K].Dir) + SclPlaceholder(S.Params[K].TypeText, S.Params[K].Dir);
      Inc(N);
    end;
  end;
  if Close then Result := Result + ')';
  if Semi then Result := Result + ';';
end;

function SclCallGhost(const S: TSclSig; Given: TStrings; Close, Semi: Boolean): string;
var
  K, N: Integer;
begin
  Result := '';
  if Positional(S) then
  begin
    if (Given = nil) or (Given.Count = 0) then Result := '<' + S.Params[0].TypeText + '>';
  end
  else
  begin
    N := 0;
    for K := 0 to High(S.Params) do
    begin
      if (Given <> nil) and (Given.IndexOf(UpperCase(S.Params[K].Name)) >= 0) then Continue;
      if N > 0 then Result := Result + ', ';
      Result := Result + S.Params[K].Name + Assign(S.Params[K].Dir) + '<' + S.Params[K].TypeText + '>';
      Inc(N);
    end;
  end;
  if Close then Result := Result + ')';
  if Semi then Result := Result + ';';
end;

function SclTypeFits(const Want, Have: string): Boolean;
const
  Nums: array[0..13] of string = ('SINT', 'USINT', 'INT', 'UINT', 'DINT', 'UDINT', 'LINT', 'ULINT', 'REAL', 'LREAL',
    'BYTE', 'WORD', 'DWORD', 'LWORD');
  Bits: array[0..4] of string = ('BOOL', 'BYTE', 'WORD', 'DWORD', 'LWORD');
  Ints: array[0..7] of string = ('SINT', 'USINT', 'INT', 'UINT', 'DINT', 'UDINT', 'LINT', 'ULINT');
var
  W, H: string;
  K: Integer;
begin
  W := UpperCase(Trim(Want));
  H := UpperCase(Trim(Have));
  if (W = '') or (H = '') then Exit(False);
  if W = 'ANY' then Exit(Pos('ARRAY', H) <> 1);
  if W = 'ANY_NUM' then
  begin
    for K := 0 to 9 do
      if Nums[K] = H then Exit(True);
    Exit(False);
  end;
  if W = 'ANY_BIT' then
  begin
    for K := 0 to High(Bits) do
      if Bits[K] = H then Exit(True);
    Exit(False);
  end;
  if W = 'ANY_INT' then
  begin
    for K := 0 to High(Ints) do
      if Ints[K] = H then Exit(True);
    Exit(False);
  end;
  if W = 'STRING' then Exit(Pos('STRING', H) = 1);
  if (Pos('STRING[', W) = 1) then Exit(Pos('STRING', H) = 1);
  Result := W = H;
end;

function SclFitting(P: TPlcProject; Cur: TBlock; const Want: string; Max: Integer): TStringList;
var
  K, J: Integer;
  D: TDataBlock;
begin
  Result := TStringList.Create;
  if Cur <> nil then
    for K := 0 to High(Cur.Iface.Vars) do
      if (Result.Count < Max) and SclTypeFits(Want, Cur.Iface.Vars[K].TypeText) then
        Result.Add('#' + Cur.Iface.Vars[K].Name);
  for K := 0 to High(P.Tags) do
    if (Result.Count < Max) and SclTypeFits(Want, P.Tags[K].TypeText) then Result.Add('"' + P.Tags[K].Name + '"');
  for K := 0 to P.DBCount - 1 do
  begin
    D := P.DB(K);
    if D.InstanceOf > 0 then Continue;
    for J := 0 to High(D.Vars) do
      if (Result.Count < Max) and SclTypeFits(Want, D.Vars[J].TypeText) then
        Result.Add(Format('"%s".%s', [D.Name, D.Vars[J].Name]));
  end;
end;

function SclCurParam(const S: TSclSig; const C: TSclCall): Integer;
var
  K, P: Integer;
  Nm: string;
begin
  Result := -1;
  P := Pos(':=', C.SegText);
  if P = 0 then P := Pos('=>', C.SegText);
  if P > 0 then
  begin
    Nm := Trim(Copy(C.SegText, 1, P - 1));
    for K := 0 to High(S.Params) do
      if SameText(S.Params[K].Name, Nm) then Exit(K);
    Exit;
  end;
  if Positional(S) then Exit(0);
  // a name being typed: the first parameter not given that starts with it
  for K := 0 to High(S.Params) do
    if ((C.Given = nil) or (C.Given.IndexOf(UpperCase(S.Params[K].Name)) < 0)) and
      SameText(Copy(S.Params[K].Name, 1, Length(Trim(C.SegText))), Trim(C.SegText)) then Exit(K);
end;

function SclNextPlaceholder(Lines: TStrings; Row, Col, MaxRows: Integer; out PRow, PCol, PLen: Integer): Boolean;
var
  R, I, J: Integer;
  U: UnicodeString;
  W: string;
begin
  Result := False;
  PRow := -1;
  PCol := -1;
  PLen := 0;
  for R := Row to Min(Lines.Count - 1, Row + MaxRows) do
  begin
    U := UTF8Decode(Lines[R]);
    if R = Row then I := Col + 1 else I := 1;
    while I <= Length(U) do
    begin
      if (U[I] = '_') and ((I = 1) or not CharInSet(U[I - 1], ['A'..'Z', 'a'..'z', '0'..'9', '_'])) then
      begin
        J := I;
        while (J <= Length(U)) and CharInSet(U[J], ['a'..'z', '0'..'9', '_']) do Inc(J);
        W := UTF8Encode(Copy(U, I, J - I));
        if IsSclPlaceholder(W) then
        begin
          PRow := R;
          PCol := I - 1;
          PLen := J - I;
          Exit(True);
        end;
        I := J;
      end
      else
        Inc(I);
    end;
  end;
end;

end.
