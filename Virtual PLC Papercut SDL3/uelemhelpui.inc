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
    else FEhNets[K] := nil;
  FEhScroll := 0;
  FEhOn := True;
  FCtxOn := False;
  FElemPress := -1;
end;

procedure TPlcUI.EhClose;
begin
  FEhOn := False;
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
  if FEhLang = 'L' then
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
  if FEhLang = 'L' then
  begin
    // the first rung of the page as a new network below the selected one
    for K := 0 to High(FEhNets) do
      if FEhNets[K] <> nil then Break;
    DoClick(Act(acAddNet, 1), '');
    N := CurNet;
    if N = nil then Exit;
    N.Assign(FEhNets[K]);
    N.Title := 'Example: ' + FEhPage.Title;
    MarkDirty;
    Toast('The example is a new LAD network: change the operands to yours');
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
  X = 150;
  W = 1300;
  Y = 46;
  H = 812;
  LadCW = 116;
var
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

begin
  if not FEhOn then Exit;
  // a click beside the window closes it; the window takes its own clicks
  Hit(-1000, -1000, DesignW + 2000, DesignH + 2000, Act(acEhClose, 0));
  Hit(X, Y, W, H, Act(acClaudeBg, 0));
  D.Layer := lyOverlay;
  Rc(-1000, -1000, DesignW + 2000, DesignH + 2000, Alpha(cCharcoal, 60));
  Shad(X, Y, W, H, 6, 4, 10, 130);
  RR(X, Y, W, H, 6, cSheet);
  RRL(X + 0.5, Y + 0.5, W - 1, H - 1, 6, 1.4, cGoldDark);
  Rc(X + 1, Y + 1, W - 2, 52, Mixc(cRed, cRedDark, 0.3));
  TxtFit(fkUIB, 16, X + 18, Y + 7, 560, FEhPage.Title, cSheet);
  TxtFit(fkUI, 11, X + 18, Y + 31, 560, 'Help  ·  ' + FEhPage.Sub, Alpha(cSheet, 215));
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
            Txt(fkUIB, 14, X0, YY, Bk.S, cRedDark);
            Ln(X0, YY + 23, X0 + CW, YY + 23, 0.7, Alpha(cGoldDark, 150));
            YY := YY + 32;
            Nr := 0;
          end;
        hbText:
          begin
            Ls := EhWrap(Bk.S, fkUI, 12.5, CW);
            for J := 0 to High(Ls) do Txt(fkUI, 12.5, X0, YY + J * 19, Ls[J], cInk);
            YY := YY + Length(Ls) * 19 + 7;
          end;
        hbStep:
          begin
            Inc(Nr);
            El(X0 + 10, YY + 9, 10, 10, cRed);
            Txt(fkUIB, 10.5, X0 + 10, YY + 2, IntToStr(Nr), cSheet, 1);
            Ls := EhWrap(Bk.S, fkUI, 12.5, CW - 34);
            for J := 0 to High(Ls) do Txt(fkUI, 12.5, X0 + 30, YY + J * 19, Ls[J], cInk);
            YY := YY + Length(Ls) * 19 + 8;
          end;
        hbBullet, hbNote:
          begin
            El(X0 + 8, YY + 9, 2.8, 2.8, cGoldDark);
            Ls := EhWrap(Bk.S, fkUI, 12.5, CW - 24);
            for J := 0 to High(Ls) do Txt(fkUI, 12.5, X0 + 22, YY + J * 19, Ls[J], cInk);
            YY := YY + Length(Ls) * 19 + 5;
          end;
        hbCaption:
          begin
            TxtFit(fkUI, 11, X0, YY - 2, CW, Bk.S, cInkSoft);
            YY := YY + 20;
          end;
        hbCode:
          begin
            HH := Lines.Count * 19 + 14;
            RR(X0, YY, CW, HH, 5, Mixc(cSheet, cGoldLight, 0.3));
            RRL(X0, YY, CW, HH, 5, 0.8, Alpha(cGoldDark, 150));
            Rc(X0, YY + 3, 3, HH - 6, cRed);
            for J := 0 to Lines.Count - 1 do
            begin
              S := Lines[J];
              // a comment fainter
              R := Pos('//', S);
              if R > 0 then
              begin
                Txt(fkMono, 12, X0 + 14, YY + 7 + J * 19, Copy(S, 1, R - 1), cInk);
                Txt(fkMono, 12, X0 + 14 + TxtW(fkMono, 12, Copy(S, 1, R - 1)), YY + 7 + J * 19, Copy(S, R, MaxInt), cJade);
              end
              else
                Txt(fkMono, 12, X0 + 14, YY + 7 + J * 19, S, cInk);
            end;
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
                if J = 0 then TxtFit(fkUIB, 12, TX + 12, YY + J * 25 + 4, ColW[C] - 16, Cells[C], cInk)
                else if C = 0 then TxtFit(fkMono, 12, TX + 12, YY + J * 25 + 4, ColW[C] - 16, Cells[C], cInk)
                else TxtFit(fkUI, 12, TX + 12, YY + J * 25 + 4, ColW[C] - 16, Cells[C], cInk);
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
