{ SCL Compiler - lexer }
unit scl_lexer;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, scl_base;

type
  TTokKind = (tkEOF, tkIdent, tkLocal, tkGlobal, tkIntLit, tkRealLit, tkTypedLit,
    tkStringLit, tkAddress, tkPragma,
    tkAssign, tkOutAssign, tkLParen, tkRParen, tkLBrack, tkRBrack, tkComma,
    tkSemi, tkColon, tkDot, tkDotDot, tkPlus, tkMinus, tkStar, tkSlash, tkPower,
    tkEq, tkNe, tkLt, tkLe, tkGt, tkGe, tkAmp);

  TToken = record
    Kind: TTokKind;
    Text: string;       // identifier name (without quotes / #), literal source, pragma body
    Up: string;         // upper case of Text (identifiers)
    I: Int64;
    F: Double;
    S: string;          // string literal value
    LitType: string;    // typed literal: canonical type name (INT, TIME, DATE ...)
    Pos: TSrcPos;
    EndOffset: Integer; // offset of the last char + 1
  end;
  TTokenArray = array of TToken;

  TSclLexer = class
  private
    FSrc: string;
    FFile: string;
    FP: Integer;
    FLine, FLineStart: Integer;
    FDiags: TDiagList;
    function Cur: Char; inline;
    function Peek(N: Integer = 1): Char; inline;
    procedure Advance;
    function CurPos: TSrcPos;
    procedure SkipWhite;
    procedure Err(const APos: TSrcPos; const Msg: string);
    procedure ReadNumber(var T: TToken; const Prefix: string);
    procedure ReadTyped(var T: TToken; const Prefix: string);
    function ReadStringLit(var T: TToken): Boolean;
    function ReadDigits(Base: Integer; out V: QWord): Boolean;
  public
    constructor Create(const ASrc, AFile: string; ADiags: TDiagList);
    function Next: TToken;
    function TokenizeAll: TTokenArray;
  end;

function TokKindText(K: TTokKind): string;
function ParseDurationText(const S: string; out Ns: Int64): Boolean;

implementation

uses Math, DateUtils;

function TokKindText(K: TTokKind): string;
const
  N: array[TTokKind] of string = ('end of file', 'identifier', '#local', '"global"', 'integer',
    'real', 'typed constant', 'string', 'address', 'pragma',
    ':=', '=>', '(', ')', '[', ']', ',', ';', ':', '.', '..', '+', '-', '*', '/', '**',
    '=', '<>', '<', '<=', '>', '>=', '&');
begin
  Result := N[K];
end;

constructor TSclLexer.Create(const ASrc, AFile: string; ADiags: TDiagList);
begin
  inherited Create;
  FSrc := ASrc;
  FFile := AFile;
  FP := 1;
  FLine := 1;
  FLineStart := 1;
  FDiags := ADiags;
end;

function TSclLexer.Cur: Char;
begin
  if FP <= Length(FSrc) then Result := FSrc[FP] else Result := #0;
end;

function TSclLexer.Peek(N: Integer): Char;
begin
  if FP + N <= Length(FSrc) then Result := FSrc[FP + N] else Result := #0;
end;

procedure TSclLexer.Advance;
begin
  if Cur = #10 then
  begin
    Inc(FLine);
    FLineStart := FP + 1;
  end;
  Inc(FP);
end;

function TSclLexer.CurPos: TSrcPos;
begin
  Result := MakePos(FFile, FLine, FP - FLineStart + 1, FP);
end;

procedure TSclLexer.Err(const APos: TSrcPos; const Msg: string);
begin
  if FDiags <> nil then FDiags.Error(APos, Msg);
end;

procedure TSclLexer.SkipWhite;
var
  P: TSrcPos;
begin
  while True do
  begin
    while (Cur <> #0) and (Cur <= ' ') do Advance;
    if (Cur = '/') and (Peek = '/') then
    begin
      while not (Cur in [#0, #10]) do Advance;
    end
    else if (Cur = '(') and (Peek = '*') then
    begin
      P := CurPos;
      Advance; Advance;
      while (Cur <> #0) and not ((Cur = '*') and (Peek = ')')) do Advance;
      if Cur = #0 then Err(P, 'Unterminated comment') else begin Advance; Advance; end;
    end
    else if (Cur = '/') and (Peek = '*') then
    begin
      P := CurPos;
      Advance; Advance;
      while (Cur <> #0) and not ((Cur = '*') and (Peek = '/')) do Advance;
      if Cur = #0 then Err(P, 'Unterminated comment') else begin Advance; Advance; end;
    end
    else
      Break;
  end;
end;

function DigitVal(C: Char): Integer;
begin
  case C of
    '0'..'9': Result := Ord(C) - Ord('0');
    'A'..'F': Result := Ord(C) - Ord('A') + 10;
    'a'..'f': Result := Ord(C) - Ord('a') + 10;
  else
    Result := 99;
  end;
end;

function TSclLexer.ReadDigits(Base: Integer; out V: QWord): Boolean;
var
  Any: Boolean;
begin
  V := 0;
  Any := False;
  while (Cur = '_') or (DigitVal(Cur) < Base) do
  begin
    if Cur <> '_' then
    begin
      V := V * QWord(Base) + QWord(DigitVal(Cur));
      Any := True;
    end;
    Advance;
  end;
  Result := Any;
end;

{ reads a numeric literal at the current position (digits, based, real) }
procedure TSclLexer.ReadNumber(var T: TToken; const Prefix: string);
var
  V, Fr: QWord;
  Start, B: Integer;
  S: string;
  Neg: Boolean;
  Code: Integer;
  D: Double;
begin
  Neg := False;
  if Cur = '-' then begin Neg := True; Advance; end
  else if Cur = '+' then Advance;
  Start := FP;
  if not (Cur in ['0'..'9']) then
  begin
    Err(CurPos, 'Number expected');
    T.Kind := tkIntLit;
    Exit;
  end;
  ReadDigits(10, V);
  if Cur = '#' then
  begin
    B := V;
    if not (B in [2, 8, 16]) then Err(T.Pos, 'Invalid number base ' + IntToStr(B));
    Advance;
    if not ReadDigits(B, V) then Err(T.Pos, 'Digits expected after base');
    T.Kind := tkIntLit;
    T.I := Int64(V);
    if Neg then T.I := -T.I;
    Exit;
  end;
  if ((Cur = '.') and (Peek in ['0'..'9'])) or (Cur in ['e', 'E']) then
  begin
    if Cur = '.' then
    begin
      Advance;
      ReadDigits(10, Fr);
    end;
    if (Cur in ['e', 'E']) and (Peek in ['0'..'9', '+', '-']) then
    begin
      Advance;
      if Cur in ['+', '-'] then Advance;
      ReadDigits(10, Fr);
    end;
    S := StringReplace(Copy(FSrc, Start, FP - Start), '_', '', [rfReplaceAll]);
    Val(S, D, Code);
    if Code <> 0 then Err(T.Pos, 'Invalid real number ' + S);
    if Neg then D := -D;
    T.Kind := tkRealLit;
    T.F := D;
    Exit;
  end;
  T.Kind := tkIntLit;
  T.I := Int64(V);
  if Neg then T.I := -T.I;
end;

function ParseDurationText(const S: string; out Ns: Int64): Boolean;
var
  I, J: Integer;
  Neg: Boolean;
  Num, U: string;
  V: Double;
  Code: Integer;
  Total: Double;
  Mul: Double;
begin
  Result := False;
  Ns := 0;
  I := 1;
  Neg := False;
  if (I <= Length(S)) and (S[I] = '-') then begin Neg := True; Inc(I); end;
  Total := 0;
  if I > Length(S) then Exit;
  while I <= Length(S) do
  begin
    if S[I] = '_' then begin Inc(I); Continue; end;
    J := I;
    while (I <= Length(S)) and (S[I] in ['0'..'9', '.']) do Inc(I);
    Num := Copy(S, J, I - J);
    if Num = '' then Exit;
    J := I;
    while (I <= Length(S)) and (S[I] in ['A'..'Z', 'a'..'z']) do Inc(I);
    U := UpperCase(Copy(S, J, I - J));
    if U = 'D' then Mul := 86400e9
    else if U = 'H' then Mul := 3600e9
    else if U = 'M' then Mul := 60e9
    else if U = 'S' then Mul := 1e9
    else if U = 'MS' then Mul := 1e6
    else if U = 'US' then Mul := 1e3
    else if U = 'NS' then Mul := 1
    else Exit;
    Val(Num, V, Code);
    if Code <> 0 then Exit;
    Total := Total + V * Mul;
  end;
  if Neg then Total := -Total;
  Ns := Round(Total);
  Result := True;
end;

function CanonType(const P: string): string;
var
  U: string;
begin
  U := UpperCase(P);
  if (U = 'T') or (U = 'TIME') then Result := 'TIME'
  else if (U = 'LT') or (U = 'LTIME') then Result := 'LTIME'
  else if (U = 'S5T') or (U = 'S5TIME') then Result := 'S5TIME'
  else if (U = 'D') or (U = 'DATE') then Result := 'DATE'
  else if (U = 'TOD') or (U = 'TIME_OF_DAY') then Result := 'TOD'
  else if (U = 'LTOD') or (U = 'LTIME_OF_DAY') then Result := 'LTOD'
  else if (U = 'DT') or (U = 'DATE_AND_TIME') then Result := 'DT'
  else if (U = 'LDT') or (U = 'LDATE_AND_TIME') then Result := 'LDT'
  else if U = 'B' then Result := 'BYTE'
  else if U = 'W' then Result := 'WORD'
  else if U = 'DW' then Result := 'DWORD'
  else if U = 'LW' then Result := 'LWORD'
  else if (U = 'BOOL') or (U = 'BYTE') or (U = 'WORD') or (U = 'DWORD') or (U = 'LWORD') or
    (U = 'SINT') or (U = 'INT') or (U = 'DINT') or (U = 'LINT') or (U = 'USINT') or
    (U = 'UINT') or (U = 'UDINT') or (U = 'ULINT') or (U = 'REAL') or (U = 'LREAL') or
    (U = 'CHAR') or (U = 'WCHAR') or (U = 'STRING') or (U = 'WSTRING') then Result := U
  else Result := '';
end;

function ParseDateText(const S: string; out Days: Int64): Boolean;
var
  Y, Mo, D: Integer;
  Parts: TStringArray;
  Dt: TDateTime;
begin
  Result := False;
  Parts := S.Split(['-']);
  if Length(Parts) <> 3 then Exit;
  Y := StrToIntDef(Parts[0], -1);
  Mo := StrToIntDef(Parts[1], -1);
  D := StrToIntDef(Parts[2], -1);
  if not TryEncodeDate(Y, Mo, D, Dt) then Exit;
  Days := Trunc(Dt) - Trunc(EncodeDate(1990, 1, 1));
  Result := True;
end;

function ParseTodText(const S: string; out Ns: Int64): Boolean;
var
  Parts: TStringArray;
  H, Mi: Integer;
  Sec: Double;
  Code: Integer;
begin
  Result := False;
  Parts := S.Split([':']);
  if not (Length(Parts) in [2, 3]) then Exit;
  H := StrToIntDef(Parts[0], -1);
  Mi := StrToIntDef(Parts[1], -1);
  Sec := 0;
  if Length(Parts) = 3 then
  begin
    Val(Parts[2], Sec, Code);
    if Code <> 0 then Exit;
  end;
  if (H < 0) or (H > 23) or (Mi < 0) or (Mi > 59) or (Sec < 0) or (Sec >= 60) then Exit;
  Ns := Round(((H * 3600.0) + Mi * 60.0 + Sec) * 1e9);
  Result := True;
end;

procedure TSclLexer.ReadTyped(var T: TToken; const Prefix: string);
var
  Canon, Body: string;
  Start: Integer;
  Ns, Days: Int64;
  P, I: Integer;
  Sub: TToken;
begin
  Canon := CanonType(Prefix);
  if Canon = '' then
  begin
    Err(T.Pos, 'Unknown constant prefix ' + Prefix + '#');
    Canon := 'DINT';
  end;
  T.Kind := tkTypedLit;
  T.LitType := Canon;
  Advance; // '#'
  if (Canon = 'TIME') or (Canon = 'LTIME') or (Canon = 'S5TIME') then
  begin
    Start := FP;
    while Cur in ['0'..'9', 'A'..'Z', 'a'..'z', '_', '.', '-'] do Advance;
    Body := Copy(FSrc, Start, FP - Start);
    if not ParseDurationText(Body, Ns) then Err(T.Pos, 'Invalid time constant ' + Prefix + '#' + Body);
    if Canon = 'LTIME' then T.I := Ns else T.I := Ns div 1000000;
  end
  else if Canon = 'DATE' then
  begin
    Start := FP;
    while Cur in ['0'..'9', '-'] do Advance;
    Body := Copy(FSrc, Start, FP - Start);
    if not ParseDateText(Body, Days) then Err(T.Pos, 'Invalid date constant ' + Body);
    T.I := Days;
  end
  else if (Canon = 'TOD') or (Canon = 'LTOD') then
  begin
    Start := FP;
    while Cur in ['0'..'9', ':', '.'] do Advance;
    Body := Copy(FSrc, Start, FP - Start);
    if not ParseTodText(Body, Ns) then Err(T.Pos, 'Invalid time of day constant ' + Body);
    if Canon = 'LTOD' then T.I := Ns else T.I := Ns div 1000000;
  end
  else if (Canon = 'DT') or (Canon = 'LDT') then
  begin
    Start := FP;
    while Cur in ['0'..'9', ':', '.', '-'] do Advance;
    Body := Copy(FSrc, Start, FP - Start);
    { yyyy-mm-dd-hh:mm:ss.fff }
    P := 0;
    for I := 1 to Length(Body) do
      if Body[I] = '-' then
      begin
        Inc(P);
        if P = 3 then begin P := I; Break; end;
      end;
    if (P < 3) or not ParseDateText(Copy(Body, 1, P - 1), Days) or
       not ParseTodText(Copy(Body, P + 1, MaxInt), Ns) then
    begin
      Err(T.Pos, 'Invalid date and time constant ' + Body);
      Days := 0; Ns := 0;
    end;
    if Canon = 'LDT' then
      T.I := (Days + 7305) * Int64(86400000000000) + Ns   { 1970 based }
    else
      T.I := Days * Int64(86400000) + Ns div 1000000;   { 1990 based ms }
  end
  else if (Canon = 'STRING') or (Canon = 'WSTRING') or (Canon = 'CHAR') or (Canon = 'WCHAR') then
  begin
    if Cur = '''' then
    begin
      ReadStringLit(Sub);
      T.S := Sub.S;
      if (Canon = 'CHAR') or (Canon = 'WCHAR') then
      begin
        if Length(T.S) <> 1 then Err(T.Pos, 'Char constant must have exactly one character');
        if T.S <> '' then T.I := Ord(T.S[1]);
      end;
    end
    else if (Canon = 'CHAR') or (Canon = 'WCHAR') then
    begin
      Sub := T;
      ReadNumber(Sub, '');
      T.I := Sub.I;
    end
    else
      Err(T.Pos, 'String constant expected');
  end
  else if Canon = 'BOOL' then
  begin
    Start := FP;
    while Cur in ['A'..'Z', 'a'..'z', '0'..'9'] do Advance;
    Body := UpperCase(Copy(FSrc, Start, FP - Start));
    if (Body = 'TRUE') or (Body = '1') then T.I := 1
    else if (Body = 'FALSE') or (Body = '0') then T.I := 0
    else Err(T.Pos, 'Invalid Bool constant');
  end
  else
  begin
    Sub := T;
    ReadNumber(Sub, Canon);
    if Sub.Kind = tkRealLit then
    begin
      T.F := Sub.F;
      if (Canon <> 'REAL') and (Canon <> 'LREAL') then Err(T.Pos, 'Real value not allowed for ' + Canon);
    end
    else
    begin
      T.I := Sub.I;
      T.F := Sub.I;
    end;
  end;
end;

function TSclLexer.ReadStringLit(var T: TToken): Boolean;
var
  R: string;
  H: string;
  C: Char;
begin
  R := '';
  Advance; // opening '
  while True do
  begin
    C := Cur;
    if C = #0 then
    begin
      Err(T.Pos, 'Unterminated string');
      Break;
    end;
    if C = '''' then
    begin
      if Peek = '''' then
      begin
        R := R + '''';
        Advance; Advance;
        Continue;
      end;
      Advance;
      Break;
    end;
    if C = '$' then
    begin
      Advance;
      C := Cur;
      case UpCase(C) of
        'N', 'L': R := R + #10;
        'R': R := R + #13;
        'T': R := R + #9;
        'P': R := R + #12;
        '$': R := R + '$';
        '''': R := R + '''';
      else
        H := C + Peek;
        if (DigitVal(H[1]) < 16) and (DigitVal(H[2]) < 16) then
        begin
          R := R + Chr(DigitVal(H[1]) * 16 + DigitVal(H[2]));
          Advance;
        end
        else
          R := R + C;
      end;
      Advance;
      Continue;
    end;
    R := R + C;
    Advance;
  end;
  T.S := R;
  Result := True;
end;

function TSclLexer.Next: TToken;
var
  Start: Integer;
  Id: string;
begin
  SkipWhite;
  FillChar(Result, SizeOf(Result), 0);
  Result.Pos := CurPos;
  Start := FP;
  case Cur of
    #0:
      Result.Kind := tkEOF;
    'A'..'Z', 'a'..'z', '_':
      begin
        while Cur in ['A'..'Z', 'a'..'z', '0'..'9', '_'] do Advance;
        Id := Copy(FSrc, Start, FP - Start);
        if (Cur = '#') and (CanonType(Id) <> '') then
          ReadTyped(Result, Id)
        else
        begin
          Result.Kind := tkIdent;
          Result.Text := Id;
          Result.Up := UpperCase(Id);
        end;
      end;
    '0'..'9':
      ReadNumber(Result, '');
    '#':
      begin
        Advance;
        if Cur = '"' then
        begin
          Advance;
          Start := FP;
          while not (Cur in [#0, '"', #10]) do Advance;
          Result.Text := Copy(FSrc, Start, FP - Start);
          if Cur = '"' then Advance else Err(Result.Pos, 'Unterminated quoted name');
        end
        else
        begin
          Start := FP;
          while Cur in ['A'..'Z', 'a'..'z', '0'..'9', '_'] do Advance;
          Result.Text := Copy(FSrc, Start, FP - Start);
          if Result.Text = '' then Err(Result.Pos, 'Name expected after #');
        end;
        Result.Kind := tkLocal;
        Result.Up := UpperCase(Result.Text);
      end;
    '"':
      begin
        Advance;
        Start := FP;
        while not (Cur in [#0, '"', #10]) do Advance;
        Result.Text := Copy(FSrc, Start, FP - Start);
        if Cur = '"' then Advance else Err(Result.Pos, 'Unterminated quoted name');
        Result.Kind := tkGlobal;
        Result.Up := UpperCase(Result.Text);
      end;
    '''':
      begin
        Result.Kind := tkStringLit;
        ReadStringLit(Result);
      end;
    '%':
      begin
        Advance;
        while Cur in ['A'..'Z', 'a'..'z'] do Advance;
        while Cur in ['0'..'9'] do Advance;
        while (Cur = '.') and (Peek in ['A'..'Z', 'a'..'z', '0'..'9']) do
        begin
          Advance;
          while Cur in ['A'..'Z', 'a'..'z'] do Advance;
          while Cur in ['0'..'9'] do Advance;
        end;
        Result.Kind := tkAddress;
        Result.Text := UpperCase(Copy(FSrc, Start + 1, FP - Start - 1));
        Result.Up := Result.Text;
      end;
    '{':
      begin
        Advance;
        Start := FP;
        while not (Cur in [#0, '}']) do Advance;
        Result.Text := Trim(Copy(FSrc, Start, FP - Start));
        if Cur = '}' then Advance else Err(Result.Pos, 'Unterminated pragma');
        Result.Kind := tkPragma;
      end;
    ':':
      begin
        Advance;
        if Cur = '=' then begin Advance; Result.Kind := tkAssign; end
        else Result.Kind := tkColon;
      end;
    '=':
      begin
        Advance;
        if Cur = '>' then begin Advance; Result.Kind := tkOutAssign; end
        else Result.Kind := tkEq;
      end;
    '<':
      begin
        Advance;
        if Cur = '>' then begin Advance; Result.Kind := tkNe; end
        else if Cur = '=' then begin Advance; Result.Kind := tkLe; end
        else Result.Kind := tkLt;
      end;
    '>':
      begin
        Advance;
        if Cur = '=' then begin Advance; Result.Kind := tkGe; end
        else Result.Kind := tkGt;
      end;
    '*':
      begin
        Advance;
        if Cur = '*' then begin Advance; Result.Kind := tkPower; end
        else Result.Kind := tkStar;
      end;
    '.':
      begin
        Advance;
        if Cur = '.' then begin Advance; Result.Kind := tkDotDot; end
        else Result.Kind := tkDot;
      end;
    '(': begin Advance; Result.Kind := tkLParen; end;
    ')': begin Advance; Result.Kind := tkRParen; end;
    '[': begin Advance; Result.Kind := tkLBrack; end;
    ']': begin Advance; Result.Kind := tkRBrack; end;
    ',': begin Advance; Result.Kind := tkComma; end;
    ';': begin Advance; Result.Kind := tkSemi; end;
    '+': begin Advance; Result.Kind := tkPlus; end;
    '-': begin Advance; Result.Kind := tkMinus; end;
    '/': begin Advance; Result.Kind := tkSlash; end;
    '&': begin Advance; Result.Kind := tkAmp; end;
  else
    Err(Result.Pos, 'Unexpected character ''' + Cur + '''');
    Advance;
    Result := Next();
    Exit;
  end;
  Result.EndOffset := FP;
  if Result.Text = '' then
    Result.Text := Copy(FSrc, Start, FP - Start);
end;

function TSclLexer.TokenizeAll: TTokenArray;
var
  N: Integer;
  T: TToken;
begin
  N := 0;
  SetLength(Result, 256);
  repeat
    T := Next;
    if N >= Length(Result) then SetLength(Result, Length(Result) * 2);
    Result[N] := T;
    Inc(N);
  until T.Kind = tkEOF;
  SetLength(Result, N);
end;

end.
