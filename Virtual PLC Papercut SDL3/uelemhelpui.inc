{ ---------- the help of an element: the right button on the elements panel (SCL, STL, LAD) ----------
  A window over the program editor with the page of uElemHelp: its text, steps, tables, the code of the
  example, and its pictures: a LAD rung drawn with the cells of the editor, a timing diagram, the bits of a
  word, a flowchart. Prev / Next go through the list of the panel; Insert example puts the example into
  the editor (SCL / STL at the caret, LAD as a new network). Esc, Close or a click beside it closes it. }

function EhPick(B: Boolean; C1, C2: TBGRAPixel): TBGRAPixel;
begin
  if B then Result := C1 else Result := C2;
end;

procedure TPlcUI.EhFreeNets;
var
  K: Integer;
begin
  for K := 0 to High(FEhNets) do FEhNets[K].Free;
  FEhNets := nil;
end;

procedure TPlcUI.EhOpen(I: Integer);
var
  K: Integer;
begin
  if (I < 0) or (I > High(FElems)) then Exit;
  EhFreeNets;
  FEhIdx := I;
  FEhLang := FElemLang;
  FEhPage := ElemHelpPage(FEhLang, FElems[I], Project.Family);
  // the networks of the LAD pictures (nil for the other blocks)
  SetLength(FEhNets, Length(FEhPage.Blocks));
  for K := 0 to High(FEhPage.Blocks) do
    if FEhPage.Blocks[K].K = hbLad then FEhNets[K] := HelpLadNet(FEhPage.Blocks[K].S)
    else if FEhPage.Blocks[K].K in [hbFbd, hbCfc] then FEhNets[K] := EhFbdNet(FEhPage.Blocks[K])
    else FEhNets[K] := nil;
  FEhScroll := 0;
  FEhSel0 := Point(0, 0);
  FEhSel1 := FEhSel0;
  FEhOn := True;
  FCtxOn := False;
  FElemPress := -1;
end;

{ the boxes of an FBD / CFC picture: its LAD rung converted (CFC: placed by the data flow) }
function TPlcUI.EhFbdNet(const Bk: THelpBlock): TNetwork;
var
  L: TNetwork;
  Err: string;
begin
  L := HelpLadNet(Bk.S);
  try
    Result := LadToFbd(L, Project, Err);
  finally
    L.Free;
  end;
  if (Result <> nil) and (Bk.K = hbCfc) then
  begin
    Result.Kind := nkCFC;
    Result.ChartW := 0;
    Result.ChartH := 0;
    CfcAutoPlace(Result);
  end;
end;

procedure TPlcUI.EhClose;
begin
  FEhOn := False;
  FEhSel0 := Point(0, 0);
  FEhSel1 := FEhSel0;
  EhFreeNets;
end;

{ the words of S in lines of the width W }
function TPlcUI.EhWrap(const S: string; Kind: TFontKind; Size, W: Single): TStringArray;
var
  Words: TStringArray;
  Cur: string;
  K, N: Integer;
begin
  Result := nil;
  N := 0;
  Words := S.Split(' ');
  Cur := '';
  for K := 0 to High(Words) do
  begin
    if (Cur <> '') and (TxtW(Kind, Size, Cur + ' ' + Words[K]) > W) then
    begin
      SetLength(Result, N + 1);
      Result[N] := Cur;
      Inc(N);
      Cur := Words[K];
    end
    else if Cur = '' then Cur := Words[K]
    else Cur := Cur + ' ' + Words[K];
  end;
  SetLength(Result, N + 1);
  Result[N] := Cur;
end;

{ the example can go into the editor: SCL / STL text, a LAD rung }
function TPlcUI.EhCanInsert: Boolean;
var
  K: Integer;
begin
  Result := False;
  if CurBlock = nil then Exit;
  if FEhLang in ['L', 'F', 'K'] then
  begin
    for K := 0 to High(FEhNets) do
      if FEhNets[K] <> nil then Exit(True);
  end
  else
    Result := FEhPage.Example <> '';
end;

procedure TPlcUI.EhInsert;
var
  K: Integer;
  N: TNetwork;
begin
  if not EhCanInsert then Exit;
  N := CurNet;
  if FEhLang in ['L', 'F', 'K'] then
  begin
    // the first picture of the page as a new network below the selected one
    for K := 0 to High(FEhNets) do
      if FEhNets[K] <> nil then Break;
    case FEhLang of
      'F': DoClick(Act(acAddNet, 7), '');
      'K': DoClick(Act(acAddNet, 9), '');
    else
      DoClick(Act(acAddNet, 1), '');
    end;
    N := CurNet;
    if N = nil then Exit;
    N.Assign(FEhNets[K]);
    N.Title := 'Example: ' + FEhPage.Title;
    MarkDirty;
    Toast('The example is a new ' + LangTitle(FEhLang) + ' network: change the operands to yours');
  end
  else if (N <> nil) and (((FEhLang = 'S') and (N.Kind = nkSTL)) or ((FEhLang = 'C') and (N.Kind = nkSCL))) then
  begin
    // at the caret of the text network
    FStlNet := FNetSel;
    N := EdBegin;
    if N = nil then Exit;
    EdUndoPoint(N, 0);
    // the example on lines of its own: after the line of the caret when that one has text
    if Trim(FEd.Line(FEd.Caret.Row)) <> '' then
    begin
      FEd.Caret.Col := FEd.LineLen(FEd.Caret.Row);
      FEd.Collapse;
      ElemPut(LineEnding + FEhPage.Example);
    end
    else
      ElemPut(FEhPage.Example);
    EdEnd(N);
    FScrollToCaret := True;
    Toast('The example is at the caret');
  end
  else
  begin
    // no text network of the language selected: a new one with the example
    if FEhLang = 'S' then DoClick(Act(acAddNet, 3), '') else DoClick(Act(acAddNet, 5), '');
    N := CurNet;
    if N = nil then Exit;
    N.Stl.Text := FEhPage.Example;
    N.Title := 'Example: ' + FEhPage.Title;
    FEdNet := nil;
    MarkDirty;
    Toast('The example is a new ' + LangTitle(FEhLang) + ' network');
  end;
  EhClose;
end;

{ a flowchart of the kind and texts of S ('kind|text|text..'), from Y; its height }
function TPlcUI.EhFlow(const S: string; X0, Y, W: Single): Single;
const
  BW = 300;
  BH = 34;
  DW = 320;
  DH = 62;
var
  P: TStringArray;
  CX, Yd, Yb, Y2, XL, XR: Single;
  K, N: Integer;

  function Pt(I: Integer): string;
  begin
    if I <= High(P) then Result := P[I] else Result := '';
  end;

  procedure Head(X1, Y1, X2, Y2: Single);
  var
    A, Dx, Dy: Single;
  begin
    // an arrow head at (X2, Y2) coming from (X1, Y1)
    A := ArcTan2(Y2 - Y1, X2 - X1);
    Dx := Cos(A);
    Dy := Sin(A);
    PolyD([PointF(X2, Y2), PointF(X2 - 9 * Dx + 4.5 * Dy, Y2 - 9 * Dy - 4.5 * Dx),
      PointF(X2 - 9 * Dx - 4.5 * Dy, Y2 - 9 * Dy + 4.5 * Dx)], cInkSoft);
  end;

  { a line through the points, an arrow head at the end }
  procedure Path(const Pts: array of TPointF; const Lbl: string);
  var
    I: Integer;
  begin
    D.Layer := lyOverlay;
    for I := 1 to High(Pts) do Ln(Pts[I - 1].X, Pts[I - 1].Y, Pts[I].X, Pts[I].Y, 1.4, cInkSoft);
    if Length(Pts) >= 2 then Head(Pts[High(Pts) - 1].X, Pts[High(Pts) - 1].Y, Pts[High(Pts)].X, Pts[High(Pts)].Y);
    if Lbl <> '' then
      Txt(fkUIB, 9.5, (Pts[0].X + Pts[1].X) / 2 + 5, (Pts[0].Y + Pts[1].Y) / 2 - 13, Lbl,
        EhPick(Lbl = 'TRUE', cJade, cRedDark));
  end;

  procedure Box(BX, BY, AW: Single; const T: string);
  begin
    D.Layer := lyOverlay;
    RR(BX - AW / 2, BY, AW, BH, 4, Mixc(cSheet, cGoldLight, 0.45));
    RRL(BX - AW / 2, BY, AW, BH, 4, 1.2, cGoldDark);
    TxtFit(fkMono, 11, BX, BY + 9, AW - 14, T, cInk, 1);
  end;

  procedure Dia(BX, BY: Single; const T: string);
  begin
    // a decision: its condition in a diamond, TRUE / FALSE leave it
    D.Layer := lyOverlay;
    PolyD([PointF(BX, BY), PointF(BX + DW / 2, BY + DH / 2), PointF(BX, BY + DH), PointF(BX - DW / 2, BY + DH / 2)],
      Mixc(cSheet, cRedLight, 0.25));
    PolyLineD([PointF(BX, BY), PointF(BX + DW / 2, BY + DH / 2), PointF(BX, BY + DH), PointF(BX - DW / 2, BY + DH / 2),
      PointF(BX, BY)], 1.2, cRedDark);
    TxtFit(fkMono, 10.5, BX, BY + DH / 2 - 8, DW * 0.62, T, cInk, 1);
  end;

  procedure Term(BX, BY: Single; const T: string);
  begin
    D.Layer := lyOverlay;
    RR(BX - 120, BY, 240, 28, 14, Alpha(cRed, 40));
    RRL(BX - 120, BY, 240, 28, 14, 1.2, cRed);
    TxtFit(fkUI, 10.5, BX, BY + 6, 224, T, cRedDark, 1);
  end;

begin
  P := S.Split('|');
  CX := X0 + 260;
  Result := 240;
  case Pt(0) of
    'if':
      begin
        Path([PointF(CX, Y), PointF(CX, Y + 18)], '');
        Dia(CX, Y + 18, Pt(1));
        Yd := Y + 18 + DH / 2;
        Path([PointF(CX, Y + 18 + DH), PointF(CX, Y + 104)], 'TRUE');
        Box(CX, Y + 104, BW, Pt(2));
        Path([PointF(CX, Y + 104 + BH), PointF(CX, Y + 182)], '');
        Path([PointF(CX + DW / 2, Yd), PointF(CX + DW / 2 + 60, Yd), PointF(CX + DW / 2 + 60, Y + 166), PointF(CX, Y + 166)], 'FALSE');
        Term(CX, Y + 182, 'END_IF: the program goes on');
        Result := 222;
      end;
    'ifelse':
      begin
        XL := CX - 40;
        XR := CX + 380;
        Path([PointF(CX + 170, Y), PointF(CX + 170, Y + 18)], '');
        Dia(CX + 170, Y + 18, Pt(1));
        Yd := Y + 18 + DH / 2;
        Path([PointF(CX + 170 - DW / 2, Yd), PointF(XL, Yd), PointF(XL, Y + 110)], 'TRUE');
        Path([PointF(CX + 170 + DW / 2, Yd), PointF(XR, Yd), PointF(XR, Y + 110)], 'FALSE');
        Box(XL, Y + 110, 280, Pt(2));
        Box(XR, Y + 110, 280, Pt(3));
        Path([PointF(XL, Y + 110 + BH), PointF(XL, Y + 168), PointF(CX + 170, Y + 168)], '');
        Path([PointF(XR, Y + 110 + BH), PointF(XR, Y + 168), PointF(CX + 170, Y + 168)], '');
        Path([PointF(CX + 170, Y + 168), PointF(CX + 170, Y + 188)], '');
        Term(CX + 170, Y + 188, 'END_IF');
        Result := 228;
      end;
    'elsif':
      begin
        XL := X0 + 170;
        XR := XL + 420;
        Path([PointF(XL, Y), PointF(XL, Y + 14)], '');
        Dia(XL, Y + 14, Pt(1));
        Yd := Y + 14 + DH / 2;
        Path([PointF(XL + DW / 2, Yd), PointF(XR - DW / 2, Yd)], 'FALSE');
        Dia(XR, Y + 14, Pt(3));
        Yb := Y + 118;
        Path([PointF(XL, Y + 14 + DH), PointF(XL, Yb)], 'TRUE');
        Path([PointF(XR, Y + 14 + DH), PointF(XR, Yb)], 'TRUE');
        Path([PointF(XR + DW / 2, Yd), PointF(XR + 330, Yd), PointF(XR + 330, Yb)], 'FALSE');
        Box(XL, Yb, 280, Pt(2));
        Box(XR, Yb, 280, Pt(4));
        Box(XR + 330, Yb, 260, 'ELSE: ' + Pt(5));
        Y2 := Yb + BH + 24;
        Path([PointF(XL, Yb + BH), PointF(XL, Y2), PointF(XR, Y2)], '');
        Path([PointF(XR + 330, Yb + BH), PointF(XR + 330, Y2), PointF(XR, Y2)], '');
        Path([PointF(XR, Yb + BH), PointF(XR, Y2 + 18)], '');
        Term(XR, Y2 + 18, 'END_IF');
        Result := Y2 + 58 - Y;
      end;
    'case':
      begin
        N := Length(P) - 2;
        XL := X0 + 130;
        Box(XL + (N - 1) * 135, Y, 300, 'CASE ' + Pt(1) + ' OF');
        Path([PointF(XL + (N - 1) * 135, Y + BH), PointF(XL + (N - 1) * 135, Y + 54)], '');
        D.Layer := lyOverlay;
        Ln(XL, Y + 54, XL + (N - 1) * 270, Y + 54, 1.4, cInkSoft);
        for K := 0 to N - 1 do
        begin
          Path([PointF(XL + K * 270, Y + 54), PointF(XL + K * 270, Y + 84)], '');
          Box(XL + K * 270, Y + 84, 250, Pt(K + 2));
          Path([PointF(XL + K * 270, Y + 84 + BH), PointF(XL + K * 270, Y + 144)], '');
        end;
        Ln(XL, Y + 144, XL + (N - 1) * 270, Y + 144, 1.4, cInkSoft);
        Path([PointF(XL + (N - 1) * 135, Y + 144), PointF(XL + (N - 1) * 135, Y + 164)], '');
        Term(XL + (N - 1) * 135, Y + 164, 'END_CASE');
        Result := 204;
      end;
    'loop':
      begin
        Yd := Y;
        if Pt(1) <> '' then
        begin
          Box(CX, Y, BW, Pt(1));
          Path([PointF(CX, Y + BH), PointF(CX, Y + BH + 22)], '');
          Yd := Y + BH + 22;
        end
        else
          Path([PointF(CX, Y), PointF(CX, Y + 22)], '');
        if Pt(1) = '' then Yd := Y + 22;
        Dia(CX, Yd, Pt(2));
        Path([PointF(CX, Yd + DH), PointF(CX, Yd + DH + 26)], 'TRUE');
        Yb := Yd + DH + 26;
        Box(CX, Yb, BW + 60, Pt(3));
        Y2 := Yb + BH;
        if Pt(4) <> '' then
        begin
          Path([PointF(CX, Y2), PointF(CX, Y2 + 18)], '');
          Box(CX, Y2 + 18, BW, Pt(4));
          Y2 := Y2 + 18 + BH;
        end;
        // back to the test
        Path([PointF(CX, Y2), PointF(CX, Y2 + 16), PointF(CX - DW / 2 - 50, Y2 + 16), PointF(CX - DW / 2 - 50, Yd - 10),
          PointF(CX - 4, Yd - 10)], '');
        Path([PointF(CX + DW / 2, Yd + DH / 2), PointF(CX + DW / 2 + 140, Yd + DH / 2), PointF(CX + DW / 2 + 140, Y2 + 30)], 'FALSE');
        Term(CX + DW / 2 + 140, Y2 + 30, 'after the loop');
        D.Layer := lyOverlay;
        Txt(fkUI, 9.5, CX - DW / 2 - 46, Y2 + 19, 'the next pass', cInkFaint);
        Result := Y2 + 70 - Y;
      end;
    'repeat':
      begin
        Path([PointF(CX, Y), PointF(CX, Y + 22)], '');
        Box(CX, Y + 22, BW + 40, Pt(1));
        Path([PointF(CX, Y + 22 + BH), PointF(CX, Y + 22 + BH + 24)], '');
        Yd := Y + 22 + BH + 24;
        Dia(CX, Yd, 'UNTIL ' + Pt(2));
        Path([PointF(CX - DW / 2, Yd + DH / 2), PointF(CX - DW / 2 - 50, Yd + DH / 2), PointF(CX - DW / 2 - 50, Y + 10),
          PointF(CX - 4, Y + 10)], 'FALSE');
        Path([PointF(CX, Yd + DH), PointF(CX, Yd + DH + 26)], 'TRUE');
        Term(CX, Yd + DH + 26, 'END_REPEAT: after the loop');
        Result := Yd + DH + 66 - Y;
      end;
    'continue', 'exit':
      begin
        Path([PointF(CX, Y), PointF(CX, Y + 20)], '');
        Dia(CX, Y + 20, 'FOR #i := 0 TO 9');
        Yd := Y + 20 + DH + 24;
        Path([PointF(CX, Y + 20 + DH), PointF(CX, Yd)], 'TRUE');
        Dia(CX, Yd, Pt(1));
        Yb := Yd + DH + 24;
        Path([PointF(CX, Yd + DH), PointF(CX, Yb)], 'FALSE');
        if Pt(0) = 'continue' then Box(CX, Yb, BW + 40, Pt(2)) else Box(CX, Yb, BW + 40, '(the rest of the loop)');
        // the next pass
        Path([PointF(CX, Yb + BH), PointF(CX, Yb + BH + 16), PointF(CX - DW / 2 - 50, Yb + BH + 16),
          PointF(CX - DW / 2 - 50, Y + 10), PointF(CX - 4, Y + 10)], '');
        if Pt(0) = 'continue' then
        begin
          Path([PointF(CX + DW / 2, Yd + DH / 2), PointF(CX + DW / 2 + 70, Yd + DH / 2), PointF(CX + DW / 2 + 70, Y + 10),
            PointF(CX + 4, Y + 10)], 'TRUE');
          D.Layer := lyOverlay;
          Txt(fkMonoB, 11, CX + DW / 2 + 80, Yd - 6, 'CONTINUE: the next pass', cRedDark);
        end
        else
        begin
          Path([PointF(CX + DW / 2, Yd + DH / 2), PointF(CX + DW / 2 + 160, Yd + DH / 2), PointF(CX + DW / 2 + 160, Yd + DH + 4)], 'TRUE');
          Box(CX + DW / 2 + 160, Yd + DH + 4, 240, Pt(2) + '  EXIT');
          Path([PointF(CX + DW / 2 + 160, Yd + DH + 4 + BH), PointF(CX + DW / 2 + 160, Yb + BH + 40)], '');
          Path([PointF(CX + DW / 2, Y + 20 + DH / 2), PointF(CX + DW / 2 + 300, Y + 20 + DH / 2),
            PointF(CX + DW / 2 + 300, Yb + BH + 54), PointF(CX + DW / 2 + 284, Yb + BH + 54)], 'FALSE');
          Term(CX + DW / 2 + 160, Yb + BH + 40, 'after the loop');
        end;
        Result := Yb + BH + 84 - Y;
      end;
    'jump':
      begin
        Path([PointF(CX, Y), PointF(CX, Y + 16)], '');
        Dia(CX, Y + 16, Pt(1) + ': jump?');
        Yd := Y + 16 + DH / 2;
        Yb := Y + 16 + DH + 24;
        Path([PointF(CX, Y + 16 + DH), PointF(CX, Yb)], 'FALSE');
        Box(CX, Yb, BW + 40, Pt(2));
        Path([PointF(CX, Yb + BH), PointF(CX, Yb + BH + 30)], '');
        Box(CX, Yb + BH + 30, BW + 40, Pt(3));
        Path([PointF(CX + DW / 2, Yd), PointF(CX + DW / 2 + 70, Yd), PointF(CX + DW / 2 + 70, Yb + BH + 30 + BH / 2),
          PointF(CX + BW / 2 + 22, Yb + BH + 30 + BH / 2)], 'TRUE');
        Result := Yb + 2 * BH + 50 - Y;
      end;
  end;
end;

procedure TPlcUI.DrawElemHelp;
const
  LadCW = 116;
var
  X, Y, W, H: Single;
  K, J, R, C, Nr, Span, NB, NCol: Integer;
  YY, X0, CW, Top, ViewH, BX, TX, SW, VMax, LblW, BoxW, GX, H0, HH, XC: Single;
  Bk: THelpBlock;
  Ls, Cells: TStringArray;
  Lines: TStringList;
  ColW: array of Single;
  RowY: array of Single;
  N: TNetwork;
  S, Lb, Bs: string;
  Vals: TStringArray;
  Fl: array of Double;
  A, B: Integer;
  On1, Marked: Boolean;
  Pts: array of TPointF;

  function Line(I: Integer): string;
  begin
    if I < Lines.Count then Result := Lines[I] else Result := '';
  end;

  { a line of text that the mouse can select: it is noted (its place, font, text), the selected part of it
    gets its gold background, then the text (Code: a // comment in green) }
  procedure ER(Kind: TFontKind; Size, TX, TY, LH, MaxW: Single; const S: string; Cl: TBGRAPixel; Code: Boolean = False;
    Cont: Boolean = False);
  var
    N, C0, C1, P: Integer;
    A0, A1: TPoint;
    X1, X2: Single;
  begin
    N := FEhRunN;
    if N > High(FEhRuns) then SetLength(FEhRuns, N + 64);
    FEhRuns[N].X := TX;
    FEhRuns[N].Y := TY;
    FEhRuns[N].H := LH;
    FEhRuns[N].Kind := Kind;
    FEhRuns[N].Size := Size;
    FEhRuns[N].S := S;
    FEhRuns[N].Cont := Cont;
    Inc(FEhRunN);
    if EhHasSel then
    begin
      EhOrdered(A0, A1);
      if (N >= A0.Y) and (N <= A1.Y) then
      begin
        if N = A0.Y then C0 := A0.X else C0 := 0;
        if N = A1.Y then C1 := A1.X else C1 := UTF8Length(S);
        X1 := TX + TxtW(Kind, Size, UTF8Copy(S, 1, C0));
        X2 := TX + TxtW(Kind, Size, UTF8Copy(S, 1, C1));
        if N < A1.Y then X2 := X2 + 4;
        if X2 > X1 then Rc(X1, TY - 2, X2 - X1, LH, Alpha(cGold, 140));
      end;
    end;
    P := 0;
    if Code then P := Pos('//', S);
    if P > 0 then
    begin
      Txt(Kind, Size, TX, TY, Copy(S, 1, P - 1), Cl);
      Txt(Kind, Size, TX + TxtW(Kind, Size, Copy(S, 1, P - 1)), TY, Copy(S, P, MaxInt), cJade);
    end
    else if MaxW > 0 then TxtFit(Kind, Size, TX, TY, MaxW, S, Cl)
    else Txt(Kind, Size, TX, TY, S, Cl);
  end;

begin
  if not FEhOn then Exit;
  if FEhW < 100 then
  begin
    FEhX := 150;
    FEhY := 46;
    FEhW := 1300;
    FEhWH := 812;
  end;
  X := FEhX;
  Y := FEhY;
  W := FEhW;
  H := FEhWH;
  FEhRunN := 0;
  // a click beside the window closes it; the window takes its own clicks; its title bar moves it
  Hit(-1000, -1000, DesignW + 2000, DesignH + 2000, Act(acEhClose, 0));
  Hit(X, Y, W, H, Act(acClaudeBg, 0));
  Hit(X, Y, W, 52, Act(acEhMove, 0), hkDrag);
  D.Layer := lyOverlay;
  Rc(-1000, -1000, DesignW + 2000, DesignH + 2000, Alpha(cCharcoal, 45));
  Shad(X, Y, W, H, 6, 4, 10, 130);
  RR(X, Y, W, H, 6, cSheet);
  RRL(X + 0.5, Y + 0.5, W - 1, H - 1, 6, 1.4, cGoldDark);
  Rc(X + 1, Y + 1, W - 2, 52, Mixc(cRed, cRedDark, 0.3));
  TxtFit(fkUIB, 16, X + 18, Y + 7, W - 640, FEhPage.Title, cSheet);
  TxtFit(fkUI, 11, X + 18, Y + 31, W - 640, 'Help  ·  ' + FEhPage.Sub, Alpha(cSheet, 215));
  BX := X + W - 104;
  Button(BX, Y + 13, 92, 26, 'Close  ×', Act(acEhClose, 0), bsGold, True, 11.5);
  BX := BX - 134;
  Button(BX, Y + 13, 126, 26, 'Copy the page', Act(acEhCopy, 0), bsNormal, True, 11);
  BX := BX - 150;
  Button(BX, Y + 13, 142, 26, 'Insert example', Act(acEhIns, 0), bsNormal, EhCanInsert, 11);
  BX := BX - 96;
  Button(BX, Y + 13, 88, 26, 'Next', Act(acEhNext, 0), bsNormal, (FEhLang = FElemLang) and (FEhIdx < High(FElems)), 11);
  BX := BX - 96;
  Button(BX, Y + 13, 88, 26, 'Previous', Act(acEhPrev, 0), bsNormal, (FEhLang = FElemLang) and (FEhIdx > 0), 11);
  // the page
  Top := Y + 58;
  ViewH := H - 64;
  X0 := X + 30;
  CW := W - 84;
  ClipD(X + 4, Top, W - 26, ViewH);
  Hit(X + 4, Top, W - 26, ViewH, whEh, hkWheel);
  Hit(X + 4, Top, W - 26, ViewH, Act(acEhText, 0), hkDrag);
  YY := Top + 6 - FEhScroll;
  H0 := YY;
  Nr := 0;
  Lines := TStringList.Create;
  try
    for K := 0 to High(FEhPage.Blocks) do
    begin
      Bk := FEhPage.Blocks[K];
      Lines.Text := Bk.S;
      case Bk.K of
        hbHead:
          begin
            if K > 0 then YY := YY + 10;
            D.Layer := lyOverlay;
            ER(fkUIB, 14, X0, YY, 22, 0, Bk.S, cRedDark);
            Ln(X0, YY + 23, X0 + CW, YY + 23, 0.7, Alpha(cGoldDark, 150));
            YY := YY + 32;
            Nr := 0;
          end;
        hbText:
          begin
            Ls := EhWrap(Bk.S, fkUI, 12.5, CW);
            for J := 0 to High(Ls) do ER(fkUI, 12.5, X0, YY + J * 19, 19, 0, Ls[J], cInk, False, J > 0);
            YY := YY + Length(Ls) * 19 + 7;
          end;
        hbStep:
          begin
            Inc(Nr);
            El(X0 + 10, YY + 9, 10, 10, cRed);
            Txt(fkUIB, 10.5, X0 + 10, YY + 2, IntToStr(Nr), cSheet, 1);
            Ls := EhWrap(Bk.S, fkUI, 12.5, CW - 34);
            for J := 0 to High(Ls) do ER(fkUI, 12.5, X0 + 30, YY + J * 19, 19, 0, Ls[J], cInk, False, J > 0);
            YY := YY + Length(Ls) * 19 + 8;
          end;
        hbBullet, hbNote:
          begin
            El(X0 + 8, YY + 9, 2.8, 2.8, cGoldDark);
            Ls := EhWrap(Bk.S, fkUI, 12.5, CW - 24);
            for J := 0 to High(Ls) do ER(fkUI, 12.5, X0 + 22, YY + J * 19, 19, 0, Ls[J], cInk, False, J > 0);
            YY := YY + Length(Ls) * 19 + 5;
          end;
        hbCaption:
          begin
            ER(fkUI, 11, X0, YY - 2, 17, CW, Bk.S, cInkSoft);
            YY := YY + 20;
          end;
        hbCode:
          begin
            HH := Lines.Count * 19 + 14;
            RR(X0, YY, CW, HH, 5, Mixc(cSheet, cGoldLight, 0.3));
            RRL(X0, YY, CW, HH, 5, 0.8, Alpha(cGoldDark, 150));
            Rc(X0, YY + 3, 3, HH - 6, cRed);
            for J := 0 to Lines.Count - 1 do ER(fkMono, 12, X0 + 14, YY + 7 + J * 19, 19, 0, Lines[J], cInk, True);
            YY := YY + HH + 9;
          end;
        hbTable:
          begin
            // the columns as wide as their texts; the last one takes the rest when they do not fit
            SetLength(ColW, 0);
            for J := 0 to Lines.Count - 1 do
            begin
              Cells := Lines[J].Split('|');
              if Length(Cells) > Length(ColW) then SetLength(ColW, Length(Cells));
              for C := 0 to High(Cells) do
                if J = 0 then ColW[C] := Max(ColW[C], TxtW(fkUIB, 12, Cells[C]) + 26)
                else if C = 0 then ColW[C] := Max(ColW[C], TxtW(fkMono, 12, Cells[C]) + 26)
                else ColW[C] := Max(ColW[C], TxtW(fkUI, 12, Cells[C]) + 26);
            end;
            GX := 0;
            for C := 0 to High(ColW) do
            begin
              ColW[C] := Max(ColW[C], 60);
              GX := GX + ColW[C];
            end;
            if (GX > CW) and (Length(ColW) > 0) then
            begin
              ColW[High(ColW)] := Max(120, ColW[High(ColW)] - (GX - CW));
              GX := 0;
              for C := 0 to High(ColW) do GX := GX + ColW[C];
            end;
            HH := Lines.Count * 25;
            RR(X0, YY, GX, HH, 4, cSheet);
            for J := 0 to Lines.Count - 1 do
            begin
              if J = 0 then Rc(X0, YY, GX, 25, Alpha(cGold, 110))
              else if not Odd(J) then Rc(X0, YY + J * 25, GX, 25, Alpha(cSheet2, 140));
              Cells := Lines[J].Split('|');
              TX := X0;
              for C := 0 to High(Cells) do
              begin
                if C > High(ColW) then Break;
                if J = 0 then ER(fkUIB, 12, TX + 12, YY + J * 25 + 4, 21, ColW[C] - 16, Cells[C], cInk)
                else if C = 0 then ER(fkMono, 12, TX + 12, YY + J * 25 + 4, 21, ColW[C] - 16, Cells[C], cInk)
                else ER(fkUI, 12, TX + 12, YY + J * 25 + 4, 21, ColW[C] - 16, Cells[C], cInk);
                TX := TX + ColW[C];
              end;
            end;
            TX := X0;
            for C := 0 to High(ColW) - 1 do
            begin
              TX := TX + ColW[C];
              Ln(TX, YY, TX, YY + HH, 0.6, Alpha(cGoldDark, 110));
            end;
            RRL(X0, YY, GX, HH, 4, 0.9, Alpha(cGoldDark, 170));
            YY := YY + HH + 10;
          end;
        hbLad:
          begin
            N := nil;
            if K <= High(FEhNets) then N := FEhNets[K];
            if N = nil then Continue;
            NCol := N.LastUsedCol + 1;
            for R := 0 to N.Rows - 1 do
              if (NCol < N.Cols) and IsBox(N.Cell(R, NCol - 1).Kind) then NCol := Max(NCol, NCol + 1);
            SetLength(RowY, N.Rows + 1);
            RowY[0] := YY + 12;
            for R := 0 to N.Rows - 1 do RowY[R + 1] := RowY[R] + RowHeight(N, R);
            HH := RowY[N.Rows] - YY + 6;
            RR(X0, YY, NCol * LadCW + 44, HH, 5, Mixc(cSheet, cSheet2, 0.5));
            RRL(X0, YY, NCol * LadCW + 44, HH, 5, 0.8, Alpha(cGoldDark, 130));
            XC := X0 + 18;
            Ln(XC, YY + 22, XC, RowY[N.Rows - 1] + 60, 2.4, cInk);
            for R := 0 to N.Rows - 1 do
            begin
              C := 0;
              while C < N.Cols do
              begin
                Span := BoxSpan(N, R, C);
                if N.Cell(R, C).Kind <> lkEmpty then
                  DrawCell(9999, N, R, C, XC + C * LadCW, RowY[R], LadCW, RowY[R + 1] - RowY[R], Span, -1, -1, False);
                C := C + Span;
              end;
              for C := 0 to N.Cols - 1 do
                if N.Cell(R, C).Down and (R + 1 < N.Rows) then
                begin
                  D.Layer := lyOverlay;
                  Ln(XC + (C + 1) * LadCW, RowY[R] + 42, XC + (C + 1) * LadCW, RowY[R + 1] + 42, 1.5, cInk);
                  El(XC + (C + 1) * LadCW, RowY[R] + 42, 2.4, 2.4, cInk);
                  El(XC + (C + 1) * LadCW, RowY[R + 1] + 42, 2.4, 2.4, cInk);
                end;
            end;
            D.Layer := lyOverlay;
            YY := YY + HH + 8;
          end;
        hbWave:
          begin
            // the steps: from the first signal
            NB := 0;
            for J := 0 to Lines.Count - 1 do
              if (Line(J) <> '') and (Line(J)[1] <> '^') then
              begin
                if Pos('~', Line(J)) > 0 then NB := Length(Copy(Line(J), Pos('~', Line(J)) + 1, MaxInt).Split(','))
                else NB := Length(Copy(Line(J), Pos('=', Line(J)) + 1, MaxInt));
                Break;
              end;
            if NB = 0 then Continue;
            LblW := 130;
            SW := Min(46, (CW - LblW - 20) / NB);
            // the grid of the steps over all signals
            HH := 0;
            for J := 0 to Lines.Count - 1 do
              if Line(J) = '' then
              else if Line(J)[1] = '^' then HH := HH + 22
              else if Pos('~', Line(J)) > 0 then HH := HH + 50
              else HH := HH + 36;
            RR(X0, YY, LblW + NB * SW + 20, HH + 30, 5, Mixc(cSheet, cSheet2, 0.5));
            for J := 0 to NB do
              Ln(X0 + LblW + J * SW, YY + 4, X0 + LblW + J * SW, YY + HH + 6, 0.5, Alpha(cGoldDark, 70));
            for J := 0 to NB - 1 do
              Txt(fkMono, 9, X0 + LblW + J * SW + SW / 2, YY + HH + 9, IntToStr(J), cInkFaint, 1);
            YY := YY + 6;
            for J := 0 to Lines.Count - 1 do
            begin
              S := Line(J);
              if S = '' then Continue;
              if S[1] = '^' then
              begin
                // a time marked under the signal above: from step A to step B
                Lb := Copy(S, 2, Pos(':', S) - 2);
                Bs := Copy(S, Pos(':', S) + 1, MaxInt);
                A := StrToIntDef(Copy(Bs, 1, Pos('-', Bs) - 1), 0);
                B := StrToIntDef(Copy(Bs, Pos('-', Bs) + 1, MaxInt), 0);
                Ln(X0 + LblW + A * SW, YY + 8, X0 + LblW + B * SW, YY + 8, 1.4, cJade);
                Ln(X0 + LblW + A * SW, YY + 2, X0 + LblW + A * SW, YY + 14, 1.4, cJade);
                Ln(X0 + LblW + B * SW, YY + 2, X0 + LblW + B * SW, YY + 14, 1.4, cJade);
                Txt(fkUIB, 10, X0 + LblW + B * SW + 6, YY + 1, Lb, cJade);
                YY := YY + 22;
                Continue;
              end;
              if Pos('~', S) > 0 then
              begin
                // a value per step: a line, the values written where they change
                Lb := Copy(S, 1, Pos('~', S) - 1);
                Vals := Copy(S, Pos('~', S) + 1, MaxInt).Split(',');
                SetLength(Fl, Length(Vals));
                VMax := 1;
                for R := 0 to High(Vals) do
                begin
                  Fl[R] := StrToFloatDef(Trim(Vals[R]), 0);
                  VMax := Max(VMax, Fl[R]);
                end;
                Txt(fkMonoB, 11.5, X0 + 10, YY + 16, Lb, cInk);
                SetLength(Pts, Length(Fl) + 1);
                for R := 0 to High(Fl) do Pts[R] := PointF(X0 + LblW + R * SW, YY + 40 - Fl[R] / VMax * 32);
                Pts[High(Pts)] := PointF(X0 + LblW + Length(Fl) * SW, Pts[High(Fl)].Y);
                PolyLineD(Pts, 2, cGoldDark);
                for R := 0 to High(Fl) do
                  if (R = 0) or (Fl[R] <> Fl[R - 1]) then
                    Txt(fkMono, 8.5, X0 + LblW + R * SW + 2, YY + 40 - Fl[R] / VMax * 32 - 12, Trim(Vals[R]), cInkSoft);
                YY := YY + 50;
              end
              else
              begin
                Lb := Copy(S, 1, Pos('=', S) - 1);
                Bs := Copy(S, Pos('=', S) + 1, MaxInt);
                Txt(fkMonoB, 11.5, X0 + 10, YY + 8, Lb, cInk);
                for R := 1 to Length(Bs) do
                begin
                  On1 := Bs[R] = '1';
                  TX := X0 + LblW + (R - 1) * SW;
                  if On1 then Rc(TX, YY + 4, SW, 22, Alpha(cRed, 45));
                  if On1 then Ln(TX, YY + 4, TX + SW, YY + 4, 2, cRedDark) else Ln(TX, YY + 26, TX + SW, YY + 26, 2, cRedDark);
                  if (R > 1) and (Bs[R] <> Bs[R - 1]) then Ln(TX, YY + 4, TX, YY + 26, 2, cRedDark);
                end;
                YY := YY + 36;
              end;
            end;
            YY := YY + 34;
          end;
        hbBits:
          begin
            // a row of bit boxes per line, the bit numbers above them
            LblW := 0;
            NB := 0;
            for J := 0 to Lines.Count - 1 do
            begin
              R := LastDelimiter('=', Line(J));
              LblW := Max(LblW, TxtW(fkMonoB, 11.5, Copy(Line(J), 1, R - 1)) + 20);
              NB := Max(NB, Length(Line(J)) - R);
            end;
            LblW := Min(LblW, 380);
            if NB > 16 then BoxW := 19 else BoxW := 27;
            for C := 0 to NB - 1 do
            begin
              GX := X0 + LblW + C * BoxW + (C div 4) * 5;
              Txt(fkMono, 9, GX + (BoxW - 3) / 2, YY, IntToStr(NB - 1 - C), cInkFaint, 1);
            end;
            YY := YY + 16;
            for J := 0 to Lines.Count - 1 do
            begin
              R := LastDelimiter('=', Line(J));
              TxtFit(fkMonoB, 11.5, X0, YY + 5, LblW - 10, Copy(Line(J), 1, R - 1), cInk);
              Bs := Copy(Line(J), R + 1, MaxInt);
              for C := 1 to Length(Bs) do
              begin
                GX := X0 + LblW + (C - 1) * BoxW + ((C - 1) div 4) * 5;
                On1 := Bs[C] in ['1', 'i'];
                Marked := Bs[C] in ['o', 'i'];
                if On1 then RR(GX, YY, BoxW - 3, 25, 3, Alpha(cGold, 150)) else RR(GX, YY, BoxW - 3, 25, 3, cSheet);
                if Marked then RRL(GX, YY, BoxW - 3, 25, 3, 2, cRed) else RRL(GX, YY, BoxW - 3, 25, 3, 0.8, Alpha(cGoldDark, 150));
                Txt(fkMonoB, 11, GX + (BoxW - 3) / 2, YY + 5, IfThen(On1, '1', '0'), EhPick(Marked, cRed, cInk), 1);
              end;
              YY := YY + 31;
            end;
            YY := YY + 4;
          end;
        hbFlow:
          YY := YY + EhFlow(Bk.S, X0, YY + 4, CW) + 8;
        hbFbd, hbCfc:
          begin
            N := nil;
            if K <= High(FEhNets) then N := FEhNets[K];
            if N = nil then Continue;
            HH := FbdHeight(N);
            if Bk.K = hbCfc then HH := N.ChartH * CfcGrid;
            RR(X0, YY, CW, HH + 16, 5, Mixc(cSheet, cSheet2, 0.5));
            RRL(X0, YY, CW, HH + 16, 5, 0.8, Alpha(cGoldDark, 130));
            if Bk.K = hbFbd then DrawFbd(-1, N, X0 + 4, YY + 8, CW - 8)
            else DrawCfc(-1, N, X0 + 4, YY + 8, CW - 8);
            D.Layer := lyOverlay;
            YY := YY + HH + 24;
          end;
      end;
    end;
  finally
    Lines.Free;
  end;
  UnclipD;
  FEhH := YY + FEhScroll - H0 + 20;
  FEhScroll := EnsureRange(FEhScroll, 0, Max(0, FEhH - ViewH));
  if FEhH > ViewH then VScrollBar(21, X + W - 16, Top, ViewH, FEhH, ViewH, FEhScroll)
  else FVs[21].Range := 0;
  // the edges and corners size the window (1 left, 2 right, 4 top, 8 bottom)
  Hit(X - 4, Y + 8, 8, H - 16, Act(acEhSize, 1), hkDrag);
  Hit(X + W - 4, Y + 8, 8, H - 16, Act(acEhSize, 2), hkDrag);
  Hit(X + 8, Y - 4, W - 16, 7, Act(acEhSize, 4), hkDrag);
  Hit(X + 8, Y + H - 4, W - 16, 8, Act(acEhSize, 8), hkDrag);
  Hit(X - 5, Y - 5, 12, 12, Act(acEhSize, 5), hkDrag);
  Hit(X + W - 7, Y - 5, 12, 12, Act(acEhSize, 6), hkDrag);
  Hit(X - 5, Y + H - 7, 12, 12, Act(acEhSize, 9), hkDrag);
  Hit(X + W - 16, Y + H - 16, 20, 20, Act(acEhSize, 10), hkDrag);
  D.Layer := lyOverlay;
  for J := 0 to 2 do
    Ln(X + W - 5 - J * 4, Y + H - 3, X + W - 3, Y + H - 5 - J * 4, 1.3, EhPick(Hot(X + W - 16, Y + H - 16, 20, 20), cRed, cGoldDark));
end;

{ the test: the help of the element with this caption in the panel shown (False: no such element) }
function TPlcUI.TestElemHelp(const Cap: string): Boolean;
var
  K: Integer;
begin
  Result := False;
  for K := 0 to High(FElems) do
    if FElems[K].Cap = Cap then
    begin
      EhOpen(K);
      Exit(True);
    end;
end;

function TPlcUI.EhHasSel: Boolean;
begin
  Result := (FEhSel0.X <> FEhSel1.X) or (FEhSel0.Y <> FEhSel1.Y);
end;

procedure TPlcUI.EhOrdered(out A, B: TPoint);
begin
  if (FEhSel1.Y < FEhSel0.Y) or ((FEhSel1.Y = FEhSel0.Y) and (FEhSel1.X < FEhSel0.X)) then
  begin
    A := FEhSel1;
    B := FEhSel0;
  end
  else
  begin
    A := FEhSel0;
    B := FEhSel1;
  end;
end;

{ the text position under the mouse: (character, run) of the last frame }
function TPlcUI.EhPosAt(X, Y: Single): TPoint;
var
  K, Best, C, N: Integer;
  Score, Sc, Dy, Dx, Wd, RX, RY, RH: Single;
  Kd: TFontKind;
  Sz: Single;
  S: string;
begin
  Result := Point(0, 0);
  Best := -1;
  Score := 1E9;
  for K := 0 to FEhRunN - 1 do
  begin
    RX := FEhRuns[K].X;
    RY := FEhRuns[K].Y - 2;
    RH := FEhRuns[K].H;
    Wd := TxtW(FEhRuns[K].Kind, FEhRuns[K].Size, FEhRuns[K].S);
    if (Y >= RY) and (Y < RY + RH) then Dy := 0 else Dy := Min(Abs(Y - RY), Abs(Y - RY - RH));
    if (X >= RX) and (X <= RX + Wd) then Dx := 0 else Dx := Min(Abs(X - RX), Abs(X - RX - Wd));
    Sc := Dy * 1000 + Dx;
    if Sc < Score then
    begin
      Score := Sc;
      Best := K;
    end;
  end;
  if Best < 0 then Exit;
  Kd := FEhRuns[Best].Kind;
  Sz := FEhRuns[Best].Size;
  S := FEhRuns[Best].S;
  RX := FEhRuns[Best].X;
  N := UTF8Length(S);
  C := 0;
  while (C < N) and (RX + (TxtW(Kd, Sz, UTF8Copy(S, 1, C)) + TxtW(Kd, Sz, UTF8Copy(S, 1, C + 1))) / 2 < X) do Inc(C);
  Result := Point(C, Best);
end;

function TPlcUI.EhSelText: string;
var
  A, B: TPoint;
  K, C0, C1: Integer;
begin
  Result := '';
  if not EhHasSel then Exit;
  EhOrdered(A, B);
  for K := A.Y to Min(B.Y, FEhRunN - 1) do
  begin
    if K = A.Y then C0 := A.X else C0 := 0;
    if K = B.Y then C1 := B.X else C1 := UTF8Length(FEhRuns[K].S);
    // a cell beside the one before: a tab, else a new line
    if K > A.Y then
      if FEhRuns[K].Cont then Result := Result + ' '
      else if Abs(FEhRuns[K].Y - FEhRuns[K - 1].Y) < 1 then Result := Result + #9
      else Result := Result + LineEnding;
    Result := Result + UTF8Copy(FEhRuns[K].S, C0 + 1, C1 - C0);
  end;
end;

procedure TPlcUI.EhCopySel;
begin
  if not EhHasSel then Exit;
  ClipboardOut := EhSelText;
  Toast('Copied');
end;

procedure TPlcUI.EhSelectAll;
begin
  if FEhRunN = 0 then Exit;
  FEhSel0 := Point(0, 0);
  FEhSel1 := Point(UTF8Length(FEhRuns[FEhRunN - 1].S), FEhRunN - 1);
end;

{ a press / a drag on the window: its title bar moves it, an edge sizes it, the text is selected }
procedure TPlcUI.EhDrag(Id: Integer; X, Y: Single);
var
  P: TPoint;
  S: string;
  I0, I1, N, Ed: Integer;
  L, T, R, B: Single;
begin
  if FDragPress <> FPressNo then
  begin
    FDragPress := FPressNo;
    FEhGrab := PointF(X, Y);
    FEhRect0 := RectF(FEhX, FEhY, FEhX + FEhW, FEhY + FEhWH);
    if Id shr 16 = acEhText then
    begin
      P := EhPosAt(X, Y);
      if (MouseClicks >= 3) and (P.Y < FEhRunN) then
      begin
        // a triple click: the line
        FEhSel0 := Point(0, P.Y);
        FEhSel1 := Point(UTF8Length(FEhRuns[P.Y].S), P.Y);
      end
      else if (MouseClicks = 2) and (P.Y < FEhRunN) then
      begin
        // a double click: the word
        S := FEhRuns[P.Y].S;
        N := UTF8Length(S);
        I0 := Min(P.X, N);
        I1 := I0;
        while (I0 > 0) and (UTF8Copy(S, I0, 1) <> ' ') do Dec(I0);
        while (I1 < N) and (UTF8Copy(S, I1 + 1, 1) <> ' ') do Inc(I1);
        FEhSel0 := Point(I0, P.Y);
        FEhSel1 := Point(I1, P.Y);
      end
      else
      begin
        if not (umShift in MouseMods) then FEhSel0 := P;
        FEhSel1 := P;
      end;
      FEhSelDrag := MouseClicks <= 1;
    end;
    Exit;
  end;
  if Id shr 16 = acEhText then
  begin
    if FEhSelDrag then
    begin
      FEhSel1 := EhPosAt(X, Y);
      // past the top / the bottom: the page scrolls
      if Y < FEhY + 62 then FEhScroll := FEhScroll - 14
      else if Y > FEhY + FEhWH - 10 then FEhScroll := FEhScroll + 14;
    end;
    Exit;
  end;
  if Id shr 16 = acEhMove then
  begin
    FEhX := EnsureRange(FEhRect0.Left + X - FEhGrab.X, 120 - FEhW, DesignW - 120);
    FEhY := EnsureRange(FEhRect0.Top + Y - FEhGrab.Y, 0, DesignH - 52);
    Exit;
  end;
  // an edge: the others stay where they are
  Ed := Id and $FFFF;
  L := FEhRect0.Left;
  T := FEhRect0.Top;
  R := FEhRect0.Right;
  B := FEhRect0.Bottom;
  if Ed and 1 <> 0 then L := EnsureRange(L + X - FEhGrab.X, 0, R - EhMinW);
  if Ed and 2 <> 0 then R := EnsureRange(R + X - FEhGrab.X, L + EhMinW, DesignW);
  if Ed and 4 <> 0 then T := EnsureRange(T + Y - FEhGrab.Y, 0, B - EhMinH);
  if Ed and 8 <> 0 then B := EnsureRange(B + Y - FEhGrab.Y, T + EhMinH, DesignH);
  FEhX := L;
  FEhY := T;
  FEhW := R - L;
  FEhWH := B - T;
end;

function TPlcUI.EhRunPoint(I, C: Integer): TPointF;
begin
  Result := PointF(0, 0);
  if (I < 0) or (I >= FEhRunN) then Exit;
  with FEhRuns[I] do
    Result := DesignToPixel(X + TxtW(Kind, Size, UTF8Copy(S, 1, C)), Y + H / 2 - 2);
end;

function TPlcUI.EhRunFind(const S: string): Integer;
var
  K: Integer;
begin
  for K := 0 to FEhRunN - 1 do
    if Copy(FEhRuns[K].S, 1, Length(S)) = S then Exit(K);
  Result := -1;
end;

function TPlcUI.EhState: string;
begin
  Result := Format('window %.0f,%.0f %.0fx%.0f  selected: [%s]', [FEhX, FEhY, FEhW, FEhWH,
    StringReplace(StringReplace(EhSelText, LineEnding, '\n', [rfReplaceAll]), #9, '\t', [rfReplaceAll])]);
end;

procedure TPlcUI.TestEhRect(AX, AY, AW, AH: Single);
begin
  FEhX := AX;
  FEhY := AY;
  FEhW := AW;
  FEhWH := AH;
end;

procedure TPlcUI.TestSelNet(I: Integer);
begin
  if (CurBlock = nil) or (I < 0) or (I >= CurBlock.NetCount) then Exit;
  FNetSel := I;
  FCellR := 0;
  FCellC := 0;
  if CurBlock.Net(I).Kind = nkLAD then FStlNet := -1 else FStlNet := I;
  FEdNet := nil;
  FScrollToCaret := True;
end;

procedure TPlcUI.TestEhScroll(V: Single);
begin
  FEhScroll := V;
end;

function TPlcUI.ElemHelpShown: string;
begin
  if FEhOn then Result := ElemHelpText(FEhPage) else Result := '';
end;
