unit uTextEdit;

{ The text engine of the STL / SCL editor (Notepad++ style), without drawing.

  Lines      the text of one network (TStrings, set before every call)
  Caret      where typing goes; Anchor: the other end of the selection (= Caret: none)
  Block      a column (rectangular) selection: rows Anchor..Caret, columns Anchor..Caret;
             typing, Backspace and Delete act on every row of it
  Columns    are characters (UTF-8 code points), a column past the end of a line is virtual:
             typing there pads the line with spaces }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, LazUTF8;

type
  TTextPos = record
    Row, Col: Integer;
  end;

  { TTextEdit }

  TTextEdit = class
  public
    Lines: TStrings;
    Caret, Anchor: TTextPos;
    Block: Boolean;        // column selection
    Overwrite: Boolean;    // Insert key
    WantCol: Integer;      // the column Up / Down keep
    TabW: Integer;         // spaces per Tab
    Scl: Boolean;          // SCL: one more indent after THEN / DO / OF ...
    Changed: Boolean;      // the last command changed the text
    constructor Create;
    function TP(R, C: Integer): TTextPos;
    function Line(R: Integer): string;
    function LineLen(R: Integer): Integer;
    function ChAt(R, C: Integer): string;
    procedure Clamp;
    function HasSel: Boolean;
    procedure SelRange(out A, B: TTextPos);
    procedure BlockRange(out R1, R2, C1, C2: Integer);
    function SelText: string;
    procedure Collapse;
    procedure MoveTo(const P: TTextPos; Extend: Boolean);
    { editing }
    procedure DeleteRange(const A, B: TTextPos);
    function DeleteSel: Boolean;
    procedure InsertText(const S: string);
    procedure TypeText(const S: string);
    procedure NewLine;
    procedure Backspace(ByWord: Boolean);
    procedure Del(ByWord: Boolean);
    procedure Indent(Back: Boolean);
    procedure DuplicateLines;
    procedure DeleteLines;
    procedure MoveLines(Dir: Integer);
    procedure JoinLines;
    procedure Comment(Mode: Integer);     // 1 add //, -1 remove, 0 toggle
    procedure ChangeCase(Upper: Boolean);
    { moving }
    procedure Left(Extend, ByWord: Boolean);
    procedure Right(Extend, ByWord: Boolean);
    procedure Up(Extend: Boolean; N: Integer = 1);
    procedure Down(Extend: Boolean; N: Integer = 1);
    procedure Home(Extend: Boolean);
    procedure EndKey(Extend: Boolean);
    procedure DocHome(Extend: Boolean);
    procedure DocEnd(Extend: Boolean);
    { selecting }
    procedure SelectAll;
    procedure SelectWord(const P: TTextPos);
    procedure SelectLines(R1, R2: Integer);
    function WordAt(const P: TTextPos; out C1, C2: Integer): string;
    function WordBefore(out C1: Integer): string;
    function MatchBracket(const P: TTextPos; out At, M: TTextPos): Boolean;
    function Find(const S: string; From: TTextPos; Back, MatchCase, Whole: Boolean; out A, B: TTextPos): Boolean;
    function LinesOfSel(out R1, R2: Integer): Boolean;
  end;

function IsWordCh(const C: string): Boolean;
function PosLess(const A, B: TTextPos): Boolean;
function PosEq(const A, B: TTextPos): Boolean;

implementation

function IsWordCh(const C: string): Boolean;
begin
  if C = '' then Exit(False);
  Result := (C[1] in ['A'..'Z', 'a'..'z', '0'..'9', '_']) or (Ord(C[1]) >= $80);
end;

function PosLess(const A, B: TTextPos): Boolean;
begin
  Result := (A.Row < B.Row) or (A.Row = B.Row) and (A.Col < B.Col);
end;

function PosEq(const A, B: TTextPos): Boolean;
begin
  Result := (A.Row = B.Row) and (A.Col = B.Col);
end;

{ TTextEdit }

constructor TTextEdit.Create;
begin
  inherited Create;
  TabW := 4;
end;

function TTextEdit.TP(R, C: Integer): TTextPos;
begin
  Result.Row := R;
  Result.Col := C;
end;

function TTextEdit.Line(R: Integer): string;
begin
  if (R >= 0) and (R < Lines.Count) then Result := Lines[R] else Result := '';
end;

function TTextEdit.LineLen(R: Integer): Integer;
begin
  Result := UTF8Length(Line(R));
end;

function TTextEdit.ChAt(R, C: Integer): string;
begin
  Result := UTF8Copy(Line(R), C + 1, 1);
end;

procedure TTextEdit.Clamp;
begin
  if Lines.Count = 0 then Lines.Add('');
  Caret.Row := EnsureRange(Caret.Row, 0, Lines.Count - 1);
  Anchor.Row := EnsureRange(Anchor.Row, 0, Lines.Count - 1);
  if Block then
  begin
    Caret.Col := Max(0, Caret.Col);
    Anchor.Col := Max(0, Anchor.Col);
  end
  else
  begin
    Caret.Col := EnsureRange(Caret.Col, 0, LineLen(Caret.Row));
    Anchor.Col := EnsureRange(Anchor.Col, 0, LineLen(Anchor.Row));
  end;
end;

function TTextEdit.HasSel: Boolean;
begin
  if Block then Result := (Caret.Col <> Anchor.Col) or (Caret.Row <> Anchor.Row)
  else Result := not PosEq(Caret, Anchor);
end;

procedure TTextEdit.SelRange(out A, B: TTextPos);
begin
  if PosLess(Anchor, Caret) then
  begin
    A := Anchor;
    B := Caret;
  end
  else
  begin
    A := Caret;
    B := Anchor;
  end;
end;

procedure TTextEdit.BlockRange(out R1, R2, C1, C2: Integer);
begin
  R1 := Min(Anchor.Row, Caret.Row);
  R2 := Max(Anchor.Row, Caret.Row);
  C1 := Min(Anchor.Col, Caret.Col);
  C2 := Max(Anchor.Col, Caret.Col);
end;

function TTextEdit.SelText: string;
var
  A, B: TTextPos;
  R, R1, R2, C1, C2: Integer;
begin
  Result := '';
  if not HasSel then Exit;
  if Block then
  begin
    BlockRange(R1, R2, C1, C2);
    for R := R1 to R2 do
    begin
      Result := Result + UTF8Copy(Line(R), C1 + 1, C2 - C1);
      if R < R2 then Result := Result + LineEnding;
    end;
    Exit;
  end;
  SelRange(A, B);
  if A.Row = B.Row then Exit(UTF8Copy(Line(A.Row), A.Col + 1, B.Col - A.Col));
  Result := UTF8Copy(Line(A.Row), A.Col + 1, MaxInt) + LineEnding;
  for R := A.Row + 1 to B.Row - 1 do Result := Result + Line(R) + LineEnding;
  Result := Result + UTF8Copy(Line(B.Row), 1, B.Col);
end;

procedure TTextEdit.Collapse;
begin
  Anchor := Caret;
  Block := False;
end;

procedure TTextEdit.MoveTo(const P: TTextPos; Extend: Boolean);
begin
  Caret := P;
  if not Extend then Collapse;
  Clamp;
  WantCol := Caret.Col;
end;

{ ---------- editing ---------- }

procedure TTextEdit.DeleteRange(const A, B: TTextPos);
var
  L: string;
  R: Integer;
begin
  if PosEq(A, B) then Exit;
  L := UTF8Copy(Line(A.Row), 1, A.Col) + UTF8Copy(Line(B.Row), B.Col + 1, MaxInt);
  for R := B.Row downto A.Row + 1 do Lines.Delete(R);
  Lines[A.Row] := L;
  Changed := True;
end;

{ pads line R with spaces up to column C (a virtual column of a column selection) }
procedure PadTo(Ed: TTextEdit; R, C: Integer);
begin
  if Ed.LineLen(R) < C then Ed.Lines[R] := Ed.Line(R) + StringOfChar(' ', C - Ed.LineLen(R));
end;

function TTextEdit.DeleteSel: Boolean;
var
  A, B: TTextPos;
  R, R1, R2, C1, C2: Integer;
  L: string;
begin
  Result := HasSel;
  if Block then
  begin
    BlockRange(R1, R2, C1, C2);
    if C2 > C1 then
    begin
      for R := R1 to R2 do
      begin
        L := Line(R);
        UTF8Delete(L, C1 + 1, C2 - C1);
        Lines[R] := L;
      end;
      Changed := True;
    end;
    // a zero width column caret stays on every row
    Anchor := TP(Anchor.Row, C1);
    Caret := TP(Caret.Row, C1);
    Exit;
  end;
  if not Result then Exit;
  SelRange(A, B);
  DeleteRange(A, B);
  Caret := A;
  Anchor := A;
end;

procedure TTextEdit.InsertText(const S: string);
var
  SL: TStringList;
  L, Tail: string;
  R, R1, R2, C1, C2, K: Integer;
begin
  Clamp;
  if Block and (Pos(#10, S) = 0) and (Pos(#13, S) = 0) then
  begin
    // the same text on every row of the column selection
    DeleteSel;
    BlockRange(R1, R2, C1, C2);
    for R := R1 to R2 do
    begin
      PadTo(Self, R, C1);
      L := Line(R);
      UTF8Insert(S, L, C1 + 1);
      Lines[R] := L;
    end;
    Anchor.Col := C1 + UTF8Length(S);
    Caret.Col := C1 + UTF8Length(S);
    WantCol := Caret.Col;
    Changed := True;
    Exit;
  end;
  if Block then
  begin
    DeleteSel;
    Block := False;
    Caret.Row := Min(Caret.Row, Anchor.Row);
    Anchor := Caret;
  end
  else
    DeleteSel;
  SL := TStringList.Create;
  try
    SL.Text := S;
    if (S <> '') and ((S[Length(S)] = #10) or (S[Length(S)] = #13)) then SL.Add('');
    if SL.Count = 0 then SL.Add('');
    L := Line(Caret.Row);
    Tail := UTF8Copy(L, Caret.Col + 1, MaxInt);
    Lines[Caret.Row] := UTF8Copy(L, 1, Caret.Col) + SL[0];
    for K := 1 to SL.Count - 1 do Lines.Insert(Caret.Row + K, SL[K]);
    R := Caret.Row + SL.Count - 1;
    Caret.Row := R;
    Caret.Col := LineLen(R);
    Lines[R] := Line(R) + Tail;
  finally
    SL.Free;
  end;
  Anchor := Caret;
  WantCol := Caret.Col;
  Changed := True;
end;

procedure TTextEdit.TypeText(const S: string);
var
  L: string;
begin
  // Insert key: the typed character replaces the one under the caret
  if Overwrite and not HasSel and not Block and (Caret.Col < LineLen(Caret.Row)) then
  begin
    L := Line(Caret.Row);
    UTF8Delete(L, Caret.Col + 1, UTF8Length(S));
    Lines[Caret.Row] := L;
  end;
  InsertText(S);
end;

procedure TTextEdit.NewLine;
var
  L, Ups, R: string;
  Sp: Integer;
begin
  if Block then
  begin
    Block := False;
    Anchor := Caret;
  end;
  DeleteSel;
  L := Line(Caret.Row);
  R := UTF8Copy(L, Caret.Col + 1, MaxInt);
  Lines[Caret.Row] := UTF8Copy(L, 1, Caret.Col);
  // the new line keeps the indent; SCL: one more after THEN / DO / OF / ELSE ...
  Sp := 0;
  while (Sp < Length(L)) and (Sp < Caret.Col) and (L[Sp + 1] = ' ') do Inc(Sp);
  if Scl then
  begin
    Ups := UpperCase(Trim(Lines[Caret.Row]));
    if (Copy(Ups, Length(Ups) - 3, 4) = 'THEN') or (Copy(Ups, Length(Ups) - 1, 2) = 'DO') or
      (Copy(Ups, Length(Ups) - 1, 2) = 'OF') or (Ups = 'ELSE') or (Ups = 'REPEAT') or (Ups = 'VAR_TEMP') or
      (Copy(Ups, 1, 6) = 'REGION') or ((Ups <> '') and (Ups[Length(Ups)] = ':')) then Inc(Sp, TabW);
  end;
  R := StringOfChar(' ', Sp) + TrimLeft(R);
  Lines.Insert(Caret.Row + 1, R);
  Caret := TP(Caret.Row + 1, Sp);
  Anchor := Caret;
  WantCol := Caret.Col;
  Changed := True;
end;

procedure TTextEdit.Backspace(ByWord: Boolean);
var
  R, R1, R2, C1, C2: Integer;
  P: TTextPos;
  L: string;
begin
  if Block then
  begin
    BlockRange(R1, R2, C1, C2);
    if C2 > C1 then
      DeleteSel
    else if C1 > 0 then
    begin
      for R := R1 to R2 do
        if LineLen(R) >= C1 then
        begin
          L := Line(R);
          UTF8Delete(L, C1, 1);
          Lines[R] := L;
        end;
      Anchor.Col := C1 - 1;
      Caret.Col := C1 - 1;
      Changed := True;
    end;
    Exit;
  end;
  if DeleteSel then Exit;
  P := Caret;
  if ByWord then Left(True, True)
  else if Caret.Col > 0 then
  begin
    // in the indent: back to the previous tab stop
    L := UTF8Copy(Line(Caret.Row), 1, Caret.Col);
    if (Trim(L) = '') and (Caret.Col mod TabW = 0) then Caret.Col := Caret.Col - TabW
    else if (Trim(L) = '') then Caret.Col := Caret.Col - Caret.Col mod TabW
    else Dec(Caret.Col);
  end
  else if Caret.Row > 0 then
    Caret := TP(Caret.Row - 1, LineLen(Caret.Row - 1));
  if not PosEq(P, Caret) then DeleteRange(Caret, P);
  Anchor := Caret;
  WantCol := Caret.Col;
end;

procedure TTextEdit.Del(ByWord: Boolean);
var
  R, R1, R2, C1, C2: Integer;
  P: TTextPos;
  L: string;
begin
  if Block then
  begin
    BlockRange(R1, R2, C1, C2);
    if C2 > C1 then
      DeleteSel
    else
    begin
      for R := R1 to R2 do
        if LineLen(R) > C1 then
        begin
          L := Line(R);
          UTF8Delete(L, C1 + 1, 1);
          Lines[R] := L;
        end;
      Changed := True;
    end;
    Exit;
  end;
  if DeleteSel then Exit;
  P := Caret;
  if ByWord then Right(True, True)
  else if Caret.Col < LineLen(Caret.Row) then Inc(Caret.Col)
  else if Caret.Row < Lines.Count - 1 then Caret := TP(Caret.Row + 1, 0);
  if not PosEq(P, Caret) then DeleteRange(P, Caret);
  Caret := P;
  Anchor := P;
  WantCol := Caret.Col;
end;

function TTextEdit.LinesOfSel(out R1, R2: Integer): Boolean;
var
  A, B: TTextPos;
begin
  if Block then
  begin
    R1 := Min(Anchor.Row, Caret.Row);
    R2 := Max(Anchor.Row, Caret.Row);
    Exit(R2 > R1);
  end;
  SelRange(A, B);
  R1 := A.Row;
  R2 := B.Row;
  // a selection that ends at column 0 does not take that line
  if (R2 > R1) and (B.Col = 0) then Dec(R2);
  Result := A.Row <> B.Row;
end;

procedure TTextEdit.Indent(Back: Boolean);
var
  R, R1, R2, N: Integer;
  L: string;
  Multi: Boolean;
begin
  Multi := LinesOfSel(R1, R2);
  if not Multi and not Back then
  begin
    // Tab: spaces to the next tab stop
    if Block then InsertText(StringOfChar(' ', TabW - Min(Anchor.Col, Caret.Col) mod TabW))
    else
    begin
      DeleteSel;
      InsertText(StringOfChar(' ', TabW - Caret.Col mod TabW));
    end;
    Exit;
  end;
  // the lines of the selection: one tab stop in / out
  for R := R1 to R2 do
  begin
    L := Line(R);
    if Back then
    begin
      N := 0;
      while (N < TabW) and (N < Length(L)) and (L[N + 1] = ' ') do Inc(N);
      if N > 0 then
      begin
        Lines[R] := Copy(L, N + 1, MaxInt);
        Changed := True;
      end;
      if R = Caret.Row then Caret.Col := Max(0, Caret.Col - N);
      if R = Anchor.Row then Anchor.Col := Max(0, Anchor.Col - N);
    end
    else if Trim(L) <> '' then
    begin
      Lines[R] := StringOfChar(' ', TabW) + L;
      Changed := True;
      if (R = Caret.Row) and (Caret.Col > 0) then Inc(Caret.Col, TabW);
      if (R = Anchor.Row) and (Anchor.Col > 0) then Inc(Anchor.Col, TabW);
    end;
  end;
  if not Multi then Anchor := Caret;
  WantCol := Caret.Col;
end;

procedure TTextEdit.DuplicateLines;
var
  R, R1, R2, K: Integer;
  S: string;
begin
  if HasSel and not Block and not LinesOfSel(R1, R2) then
  begin
    // Notepad++: Ctrl+D duplicates the selection in place
    S := SelText;
    Collapse;
    InsertText(S);
    Exit;
  end;
  LinesOfSel(R1, R2);
  if not HasSel then
  begin
    R1 := Caret.Row;
    R2 := Caret.Row;
  end;
  for K := R2 downto R1 do Lines.Insert(R2 + 1, Line(K));
  // the copy is selected / the caret follows it
  R := R2 - R1 + 1;
  Inc(Caret.Row, R);
  Inc(Anchor.Row, R);
  Changed := True;
end;

procedure TTextEdit.DeleteLines;
var
  R, R1, R2: Integer;
begin
  if not HasSel then
  begin
    R1 := Caret.Row;
    R2 := Caret.Row;
  end
  else
    LinesOfSel(R1, R2);
  for R := R2 downto R1 do Lines.Delete(R);
  if Lines.Count = 0 then Lines.Add('');
  Block := False;
  Caret := TP(Min(R1, Lines.Count - 1), 0);
  Caret.Col := Min(WantCol, LineLen(Caret.Row));
  Anchor := Caret;
  Changed := True;
end;

procedure TTextEdit.MoveLines(Dir: Integer);
var
  R1, R2, K: Integer;
  S: string;
begin
  if not HasSel then
  begin
    R1 := Caret.Row;
    R2 := Caret.Row;
  end
  else
    LinesOfSel(R1, R2);
  if (Dir < 0) and (R1 = 0) or (Dir > 0) and (R2 >= Lines.Count - 1) then Exit;
  if Dir < 0 then
  begin
    S := Lines[R1 - 1];
    for K := R1 to R2 do Lines[K - 1] := Lines[K];
    Lines[R2] := S;
  end
  else
  begin
    S := Lines[R2 + 1];
    for K := R2 downto R1 do Lines[K + 1] := Lines[K];
    Lines[R1] := S;
  end;
  Inc(Caret.Row, Dir);
  Inc(Anchor.Row, Dir);
  Changed := True;
end;

procedure TTextEdit.JoinLines;
var
  R, R1, R2: Integer;
  S: string;
begin
  if not LinesOfSel(R1, R2) then
  begin
    R1 := Caret.Row;
    R2 := Min(Caret.Row + 1, Lines.Count - 1);
  end;
  if R2 <= R1 then Exit;
  S := TrimRight(Lines[R1]);
  for R := R1 + 1 to R2 do S := S + ' ' + Trim(Lines[R]);
  for R := R2 downto R1 + 1 do Lines.Delete(R);
  Lines[R1] := S;
  Block := False;
  Caret := TP(R1, UTF8Length(S));
  Anchor := Caret;
  Changed := True;
end;

procedure TTextEdit.Comment(Mode: Integer);
var
  R, R1, R2, Ind, P: Integer;
  L, T: string;
  AllCmt: Boolean;
begin
  if not HasSel or not LinesOfSel(R1, R2) then
  begin
    R1 := Caret.Row;
    R2 := Caret.Row;
  end;
  AllCmt := True;
  Ind := MaxInt;
  for R := R1 to R2 do
  begin
    T := TrimLeft(Line(R));
    if T = '' then Continue;
    if Copy(T, 1, 2) <> '//' then AllCmt := False;
    Ind := Min(Ind, Length(Line(R)) - Length(T));
  end;
  if Ind = MaxInt then Ind := 0;
  if Mode = 0 then
  begin
    if AllCmt then Mode := -1 else Mode := 1;
  end;
  for R := R1 to R2 do
  begin
    L := Line(R);
    if Mode > 0 then
    begin
      // // at the common indent, like Notepad++
      if Trim(L) = '' then Continue;
      Lines[R] := Copy(L, 1, Ind) + '//' + Copy(L, Ind + 1, MaxInt);
      if R = Caret.Row then Inc(Caret.Col, 2);
      if (R = Anchor.Row) and (R <> Caret.Row) then Inc(Anchor.Col, 2);
      Changed := True;
    end
    else
    begin
      P := Pos('//', L);
      if (P = 0) or (Trim(Copy(L, 1, P - 1)) <> '') then Continue;
      Delete(L, P, 2);
      Lines[R] := L;
      if R = Caret.Row then Caret.Col := Max(0, Caret.Col - 2);
      if (R = Anchor.Row) and (R <> Caret.Row) then Anchor.Col := Max(0, Anchor.Col - 2);
      Changed := True;
    end;
  end;
  if not HasSel then Anchor := Caret;
  Clamp;
end;

procedure TTextEdit.ChangeCase(Upper: Boolean);
var
  S: string;
  A, B: TTextPos;
  Bl: Boolean;
  R, R1, R2, C1, C2: Integer;
  L: string;
begin
  if not HasSel then Exit;
  if Block then
  begin
    BlockRange(R1, R2, C1, C2);
    for R := R1 to R2 do
    begin
      L := Line(R);
      S := UTF8Copy(L, C1 + 1, C2 - C1);
      if Upper then S := UTF8UpperCase(S) else S := UTF8LowerCase(S);
      Lines[R] := UTF8Copy(L, 1, C1) + S + UTF8Copy(L, C2 + 1, MaxInt);
    end;
    Changed := True;
    Exit;
  end;
  S := SelText;
  if Upper then S := UTF8UpperCase(S) else S := UTF8LowerCase(S);
  SelRange(A, B);
  Bl := PosLess(Anchor, Caret);
  InsertText(S);
  // the selection stays
  if Bl then Anchor := A else
  begin
    Anchor := Caret;
    Caret := A;
  end;
end;

{ ---------- moving ---------- }

procedure TTextEdit.Left(Extend, ByWord: Boolean);
var
  A, B: TTextPos;
begin
  if not Extend and HasSel and not Block then
  begin
    SelRange(A, B);
    MoveTo(A, False);
    Exit;
  end;
  if not Extend then Block := False;
  if Caret.Col > 0 then
  begin
    if Caret.Col > LineLen(Caret.Row) then Caret.Col := LineLen(Caret.Row)
    else if ByWord then
    begin
      // over the spaces, then over a word or a run of other characters
      while (Caret.Col > 0) and (ChAt(Caret.Row, Caret.Col - 1) = ' ') do Dec(Caret.Col);
      if (Caret.Col > 0) and IsWordCh(ChAt(Caret.Row, Caret.Col - 1)) then
        while (Caret.Col > 0) and IsWordCh(ChAt(Caret.Row, Caret.Col - 1)) do Dec(Caret.Col)
      else
        while (Caret.Col > 0) and not IsWordCh(ChAt(Caret.Row, Caret.Col - 1)) and
          (ChAt(Caret.Row, Caret.Col - 1) <> ' ') do Dec(Caret.Col);
    end
    else
      Dec(Caret.Col);
  end
  else if Caret.Row > 0 then
    Caret := TP(Caret.Row - 1, LineLen(Caret.Row - 1));
  if not Extend then Anchor := Caret;
  WantCol := Caret.Col;
end;

procedure TTextEdit.Right(Extend, ByWord: Boolean);
var
  A, B: TTextPos;
  N: Integer;
begin
  if not Extend and HasSel and not Block then
  begin
    SelRange(A, B);
    MoveTo(B, False);
    Exit;
  end;
  if not Extend then Block := False;
  N := LineLen(Caret.Row);
  if Caret.Col < N then
  begin
    if ByWord then
    begin
      if IsWordCh(ChAt(Caret.Row, Caret.Col)) then
        while (Caret.Col < N) and IsWordCh(ChAt(Caret.Row, Caret.Col)) do Inc(Caret.Col)
      else
        while (Caret.Col < N) and not IsWordCh(ChAt(Caret.Row, Caret.Col)) and
          (ChAt(Caret.Row, Caret.Col) <> ' ') do Inc(Caret.Col);
      while (Caret.Col < N) and (ChAt(Caret.Row, Caret.Col) = ' ') do Inc(Caret.Col);
    end
    else
      Inc(Caret.Col);
  end
  else if Block and Extend then
    Inc(Caret.Col)     // a column selection may go past the end of the line
  else if Caret.Row < Lines.Count - 1 then
    Caret := TP(Caret.Row + 1, 0);
  if not Extend then Anchor := Caret;
  WantCol := Caret.Col;
end;

procedure TTextEdit.Up(Extend: Boolean; N: Integer);
begin
  if not Extend then Block := False;
  Caret.Row := Max(0, Caret.Row - N);
  if Block then Caret.Col := WantCol else Caret.Col := Min(WantCol, LineLen(Caret.Row));
  if not Extend then Anchor := Caret;
end;

procedure TTextEdit.Down(Extend: Boolean; N: Integer);
begin
  if not Extend then Block := False;
  Caret.Row := Min(Lines.Count - 1, Caret.Row + N);
  if Block then Caret.Col := WantCol else Caret.Col := Min(WantCol, LineLen(Caret.Row));
  if not Extend then Anchor := Caret;
end;

procedure TTextEdit.Home(Extend: Boolean);
var
  L: string;
  Ind: Integer;
begin
  // smart home: the first character of the line, then column 0
  L := Line(Caret.Row);
  Ind := 0;
  while (Ind < Length(L)) and (L[Ind + 1] = ' ') do Inc(Ind);
  if (Caret.Col = Ind) or (Ind = Length(L)) then Caret.Col := 0 else Caret.Col := Ind;
  if not Extend then Collapse;
  WantCol := Caret.Col;
end;

procedure TTextEdit.EndKey(Extend: Boolean);
begin
  Caret.Col := LineLen(Caret.Row);
  if not Extend then Collapse;
  WantCol := Caret.Col;
end;

procedure TTextEdit.DocHome(Extend: Boolean);
begin
  MoveTo(TP(0, 0), Extend);
end;

procedure TTextEdit.DocEnd(Extend: Boolean);
begin
  MoveTo(TP(Lines.Count - 1, LineLen(Lines.Count - 1)), Extend);
end;

{ ---------- selecting ---------- }

procedure TTextEdit.SelectAll;
begin
  Block := False;
  Anchor := TP(0, 0);
  Caret := TP(Lines.Count - 1, LineLen(Lines.Count - 1));
  WantCol := Caret.Col;
end;

function TTextEdit.WordAt(const P: TTextPos; out C1, C2: Integer): string;
var
  N: Integer;
begin
  N := LineLen(P.Row);
  C1 := Min(P.Col, N);
  C2 := C1;
  if not IsWordCh(ChAt(P.Row, C1)) and ((C1 = 0) or not IsWordCh(ChAt(P.Row, C1 - 1))) then Exit('');
  while (C1 > 0) and IsWordCh(ChAt(P.Row, C1 - 1)) do Dec(C1);
  while (C2 < N) and IsWordCh(ChAt(P.Row, C2)) do Inc(C2);
  Result := UTF8Copy(Line(P.Row), C1 + 1, C2 - C1);
end;

function TTextEdit.WordBefore(out C1: Integer): string;
begin
  C1 := Caret.Col;
  while (C1 > 0) and IsWordCh(ChAt(Caret.Row, C1 - 1)) do Dec(C1);
  Result := UTF8Copy(Line(Caret.Row), C1 + 1, Caret.Col - C1);
end;

procedure TTextEdit.SelectWord(const P: TTextPos);
var
  C1, C2: Integer;
begin
  Block := False;
  if WordAt(P, C1, C2) = '' then
  begin
    // not on a word: the run of the same character
    C1 := Min(P.Col, LineLen(P.Row));
    C2 := Min(C1 + 1, LineLen(P.Row));
  end;
  Anchor := TP(P.Row, C1);
  Caret := TP(P.Row, C2);
  WantCol := Caret.Col;
end;

procedure TTextEdit.SelectLines(R1, R2: Integer);
begin
  Block := False;
  if R2 < R1 then
  begin
    // upwards: the caret at the top
    Anchor := TP(R1, 0);
    if R1 < Lines.Count - 1 then Anchor := TP(R1 + 1, 0) else Anchor := TP(R1, LineLen(R1));
    Caret := TP(R2, 0);
  end
  else
  begin
    Anchor := TP(R1, 0);
    if R2 < Lines.Count - 1 then Caret := TP(R2 + 1, 0) else Caret := TP(R2, LineLen(R2));
  end;
  WantCol := Caret.Col;
end;

function TTextEdit.MatchBracket(const P: TTextPos; out At, M: TTextPos): Boolean;
const
  Open = '([{';
  Close = ')]}';
var
  C: string;
  K, Dir, Depth, R, Col: Integer;
  Op, Cl: Char;
begin
  Result := False;
  // the bracket after the caret, else the one before it
  At := P;
  C := ChAt(P.Row, P.Col);
  if (C = '') or (Pos(C, Open + Close) = 0) then
  begin
    if P.Col = 0 then Exit;
    At := TP(P.Row, P.Col - 1);
    C := ChAt(At.Row, At.Col);
    if (C = '') or (Pos(C, Open + Close) = 0) then Exit;
  end;
  K := Pos(C, Open);
  if K > 0 then
  begin
    Dir := 1;
    Op := Open[K];
    Cl := Close[K];
  end
  else
  begin
    K := Pos(C, Close);
    Dir := -1;
    Op := Close[K];
    Cl := Open[K];
  end;
  Depth := 0;
  R := At.Row;
  Col := At.Col;
  while (R >= 0) and (R < Lines.Count) do
  begin
    while (Col >= 0) and (Col < LineLen(R)) do
    begin
      C := ChAt(R, Col);
      if C = Op then Inc(Depth)
      else if C = Cl then
      begin
        Dec(Depth);
        if Depth = 0 then
        begin
          M := TP(R, Col);
          Exit(True);
        end;
      end;
      Inc(Col, Dir);
    end;
    Inc(R, Dir);
    if Dir > 0 then Col := 0 else Col := LineLen(R) - 1;
    if Abs(R - At.Row) > 400 then Exit;
  end;
end;

function TTextEdit.Find(const S: string; From: TTextPos; Back, MatchCase, Whole: Boolean; out A, B: TTextPos): Boolean;
var
  R, P, N, Start: Integer;
  L, Ls, Ss: string;

  function WholeOk(const Ln: string; C1, Len: Integer): Boolean;
  begin
    Result := not Whole or
      (((C1 = 0) or not IsWordCh(UTF8Copy(Ln, C1, 1))) and not IsWordCh(UTF8Copy(Ln, C1 + Len + 1, 1)));
  end;

begin
  Result := False;
  if S = '' then Exit;
  N := UTF8Length(S);
  if MatchCase then Ss := S else Ss := UTF8LowerCase(S);
  R := From.Row;
  while (R >= 0) and (R < Lines.Count) do
  begin
    L := Lines[R];
    if MatchCase then Ls := L else Ls := UTF8LowerCase(L);
    if not Back then
    begin
      if R = From.Row then Start := From.Col else Start := 0;
      P := Start;
      while P <= UTF8Length(Ls) - N do
      begin
        if (UTF8Copy(Ls, P + 1, N) = Ss) and WholeOk(L, P, N) then
        begin
          A := TP(R, P);
          B := TP(R, P + N);
          Exit(True);
        end;
        Inc(P);
      end;
      Inc(R);
    end
    else
    begin
      if R = From.Row then Start := From.Col - N else Start := UTF8Length(Ls) - N;
      P := Start;
      while P >= 0 do
      begin
        if (UTF8Copy(Ls, P + 1, N) = Ss) and WholeOk(L, P, N) then
        begin
          A := TP(R, P);
          B := TP(R, P + N);
          Exit(True);
        end;
        Dec(P);
      end;
      Dec(R);
    end;
  end;
end;

end.
