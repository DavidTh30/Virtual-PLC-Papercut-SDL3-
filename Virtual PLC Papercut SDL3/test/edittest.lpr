program edittest;

{ the text engine of the STL / SCL editor (uTextEdit): Notepad++ style editing without the UI.
  Build: fpc -Mobjfpc -Fu.. -FuC:\lazarus\components\lazutils -FUlib edittest.lpr }
{$mode objfpc}{$H+}
uses Classes, SysUtils, uTextEdit;
var
  E: TTextEdit;
  L: TStringList;
  Fails: Integer = 0;
  P1, P2, At, M: TTextPos;
  C1: Integer;

procedure Chk(Ok: Boolean; const S: string);
begin
  if Ok then WriteLn('  ok   ', S) else begin WriteLn('  FAIL ', S); Inc(Fails); end;
end;

function T: string;
begin
  Result := StringReplace(TrimRight(L.Text), LineEnding, '|', [rfReplaceAll]);
end;

begin
  L := TStringList.Create;
  E := TTextEdit.Create;
  E.Lines := L;
  E.Scl := True;
  L.Text := 'IF a THEN'#10'    b := 1;'#10'END_IF;';
  E.MoveTo(E.TP(0, 3), False);
  E.Right(True, True);
  Chk(E.SelText = 'a ', 'Shift+Ctrl+Right selects a word + spaces [' + E.SelText + ']');
  E.MoveTo(E.TP(0, 0), False);
  E.Down(True);
  E.Down(True);
  E.EndKey(True);
  Chk(E.SelText = TrimRight(L.Text), 'Shift down / end select all lines');
  E.Indent(False);
  Chk(T = '    IF a THEN|        b := 1;|    END_IF;', 'Tab indents the lines ' + T);
  E.Indent(True);
  Chk(T = 'IF a THEN|    b := 1;|END_IF;', 'Shift+Tab outdents ' + T);
  E.Comment(0);
  Chk(T = '//IF a THEN|//    b := 1;|//END_IF;', 'toggle comment ' + T);
  E.Comment(0);
  Chk(T = 'IF a THEN|    b := 1;|END_IF;', 'toggle back ' + T);
  E.MoveTo(E.TP(1, 0), False);
  E.DuplicateLines;
  Chk(T = 'IF a THEN|    b := 1;|    b := 1;|END_IF;', 'Ctrl+D ' + T);
  E.DeleteLines;
  Chk(T = 'IF a THEN|    b := 1;|END_IF;', 'Ctrl+L ' + T);
  E.MoveTo(E.TP(1, 3), False);
  E.MoveLines(-1);
  Chk(T = '    b := 1;|IF a THEN|END_IF;', 'Ctrl+Shift+Up ' + T);
  E.MoveLines(1);
  Chk(T = 'IF a THEN|    b := 1;|END_IF;', 'Ctrl+Shift+Down ' + T);
  E.MoveTo(E.TP(0, 9), False);
  E.NewLine;
  Chk((E.Caret.Col = 4) and (L[1] = '    '), 'Enter after THEN indents 4');
  E.TypeText('x := 2;');
  Chk(L[1] = '    x := 2;', 'type ' + L[1]);
  E.Backspace(True);
  Chk(L[1] = '    x := 2', 'Ctrl+Back deletes the ";" run: ' + L[1]);
  E.Home(False);
  Chk(E.Caret.Col = 4, 'smart home to the text');
  E.Home(False);
  Chk(E.Caret.Col = 0, 'smart home to column 0');
  E.MoveTo(E.TP(1, 4), False);
  E.Backspace(False);
  Chk(L[1] = 'x := 2', 'Backspace in the indent: back one tab stop [' + L[1] + ']');
  // column mode
  L.Text := 'abc'#10'abc'#10'abc';
  E.MoveTo(E.TP(0, 1), False);
  E.Block := True;
  E.Caret := E.TP(2, 1);
  E.WantCol := 1;
  E.TypeText('X');
  Chk(T = 'aXbc|aXbc|aXbc', 'column typing ' + T);
  E.Backspace(False);
  Chk(T = 'abc|abc|abc', 'column backspace ' + T);
  E.Block := True;
  E.Anchor := E.TP(0, 1);
  E.Caret := E.TP(2, 2);
  Chk(E.SelText = 'b' + LineEnding + 'b' + LineEnding + 'b', 'column copy');
  E.Del(False);
  Chk(T = 'ac|ac|ac', 'column delete ' + T);
  E.Block := True;
  E.Anchor := E.TP(0, 5);
  E.Caret := E.TP(1, 5);
  E.TypeText(';');
  Chk(T = 'ac   ;|ac   ;|ac', 'column typing past the end pads ' + T);
  // find / brackets / words / paste
  L.Text := 'x := MAX(a, (b + 1));'#10'y := max(c, d);';
  Chk(E.Find('max', E.TP(0, 0), False, False, False, P1, P2) and (P1.Row = 0) and (P1.Col = 5), 'find case-insensitive');
  Chk(E.Find('max', E.TP(0, 6), False, False, False, P1, P2) and (P1.Row = 1) and (P1.Col = 5), 'find next line');
  Chk(not E.Find('MAX', E.TP(0, 6), False, True, False, P1, P2), 'match case: no MAX after the first');
  Chk(E.Find('MAX', E.TP(1, 0), True, True, False, P1, P2) and (P1.Row = 0), 'find backwards');
  Chk(not E.Find('ma', E.TP(0, 0), False, False, True, P1, P2), 'whole word');
  Chk(E.MatchBracket(E.TP(0, 8), At, M) and (M.Col = 19), Format('matching bracket of ( at 8: %d', [M.Col]));
  Chk(E.MatchBracket(E.TP(0, 20), At, M) and (At.Col = 19) and (M.Col = 8), 'bracket before the caret');
  E.MoveTo(E.TP(1, 7), False);
  Chk(E.WordBefore(C1) = 'ma', 'word before the caret');
  E.SelectWord(E.TP(0, 6));
  Chk(E.SelText = 'MAX', 'double click word');
  E.InsertText('A'#10'B');
  Chk(T = 'x := A|B(a, (b + 1));|y := max(c, d);', 'multi line paste over a selection ' + T);
  E.SelectLines(0, 0);
  E.ChangeCase(False);
  Chk(L[0] = 'x := a', 'Ctrl+U lower case ' + L[0]);
  E.MoveTo(E.TP(0, 0), False);
  E.JoinLines;
  Chk(L[0] = 'x := a B(a, (b + 1));', 'Ctrl+J join ' + L[0]);
  E.Overwrite := True;
  E.MoveTo(E.TP(0, 0), False);
  E.TypeText('z');
  Chk(L[0] = 'z := a B(a, (b + 1));', 'Insert: overwrite ' + L[0]);
  WriteLn(Fails, ' failed');
  ExitCode := Fails;
end.
