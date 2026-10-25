{ ---------- FBD and CFC in the program editor ----------
  A box: its title (the operator / the data type in it: a click opens its menu), the instance / operand above it,
  its input pins on the left (an operand field, or a wire from another box; a small circle: negated), its
  output pins on the right (an operand field when nothing is wired), + for one more input.
  FBD: the boxes are trees from the left; a box whose output feeds no box is a root, the roots stand below each
  other. A click on a pin and then an element of the panel puts the new box onto that pin.
  CFC: a chart of free blocks (grid 10 px) with wires; a block is moved by its title, a wire is drawn from a
  pin to a pin; the number in the block is its place in the run order (the data flow; Order between free
  blocks). The regions of the last frame (FFbdHits) tell the mouse what is under it. }

const
  FbdViewW = 974;   // the width of an FBD / CFC network in the editor (the network 1002 less its frame)
  FbdPinH = 20;
  FbdHeadH = 24;
  FbdOpW = 124;
  FbdGap = 46;
  CfcGrid = 10;

function FbdPick(B: Boolean; C1, C2: TBGRAPixel): TBGRAPixel;
begin
  if B then Result := C1 else Result := C2;
end;

{ the size of a box: its width, its height (without the field above), the field above }
procedure TPlcUI.FbdBoxGeo(const Nd: TFbdNode; out BW, BH, InstH: Single);
var
  K: Integer;
  WI, WO: Single;
  Bd: TFbdBoxDef;
begin
  Bd := FbdBoxDefOf(Nd.Box);
  WI := 0;
  WO := 0;
  for K := 0 to High(Nd.Ins) do WI := Max(WI, TxtW(fkUI, 10, Nd.Ins[K].Name));
  for K := 0 to High(Nd.Outs) do WO := Max(WO, TxtW(fkUI, 10, Nd.Outs[K].Name));
  BW := Max(96, WI + WO + 30);
  BW := Max(BW, TxtW(fkUIB, 11, FbdBoxTitle(Nd)) + 24);
  BH := FbdHeadH + Max(1, Max(Length(Nd.Ins), Length(Nd.Outs))) * FbdPinH + 6;
  if Bd.Ext then BH := BH + 12;
  if Bd.Inst <> fiNone then InstH := 22 else InstH := 0;
end;

function TPlcUI.FbdBoxTitle(const Nd: TFbdNode): string;
var
  Bd: TFbdBoxDef;
begin
  Bd := FbdBoxDefOf(Nd.Box);
  Result := Bd.Title;
  if Nd.Box = 'cmp' then Result := 'CMP ' + CmpOpNames[Nd.Cmp];
end;

function TPlcUI.FbdTypeText(const Nd: TFbdNode): string;
var
  Bd: TFbdBoxDef;
begin
  Bd := FbdBoxDefOf(Nd.Box);
  Result := '';
  if Bd.HasType then Result := DataTypeNames[Nd.DType];
  if Bd.HasType2 then Result := Result + ' to ' + DataTypeNames[Nd.DType2];
end;

{ the monitor: the value of a box (the first line of its SCL that writes) }
function TPlcUI.FbdNodeValue(NI, Id: Integer; out V: Double; out DT: TDataType): Boolean;
var
  CB: TCBlock;
  L, SlotI: Integer;
begin
  Result := False;
  V := 0;
  DT := dtNone;
  if (NI < 0) or not MonitorOk then Exit;
  CB := CompiledBlock;
  if (CB = nil) or (NI > High(CB.Nets)) or not (CB.Nets[NI].Kind in [nkFBD, nkCFC]) then Exit;
  for L := 0 to High(CB.Nets[NI].LineNode) do
    if (CB.Nets[NI].LineNode[L] = Id) and (L <= High(CB.Nets[NI].Scl)) and (Pos(':=', CB.Nets[NI].Scl[L]) > 0) then
    begin
      SlotI := CB.Nets[NI].MonBase + L;
      if (SlotI < 0) or (SlotI > High(CB.Mon)) then Exit;
      if (CB.Mon[SlotI].Stamp = 0) or (Rt.CycleNo - CB.Mon[SlotI].Stamp > 50) then Exit;
      V := CB.Mon[SlotI].Val;
      DT := CB.Mon[SlotI].DT;
      Exit(True);
    end;
end;

function TPlcUI.FbdHitAdd(NI, Node, Pin, Kind: Integer; X, Y, W, H: Single): Integer;
begin
  Result := -1;
  if NI < 0 then Exit;
  Result := Length(FFbdHits);
  SetLength(FFbdHits, Result + 1);
  FFbdHits[Result].NI := NI;
  FFbdHits[Result].Node := Node;
  FFbdHits[Result].Pin := Pin;
  FFbdHits[Result].Kind := Kind;
  FFbdHits[Result].R := RectF(X, Y, X + W, Y + H);
  Hit(X, Y, W, H, Act(acFbdHit, Result), hkDrag);
end;

function TPlcUI.FbdFieldAdd(NI, Node, Pin, Kind: Integer): Integer;
begin
  Result := Length(FFbdFlds);
  SetLength(FFbdFlds, Result + 1);
  FFbdFlds[Result].NI := NI;
  FFbdFlds[Result].Node := Node;
  FFbdFlds[Result].Pin := Pin;
  FFbdFlds[Result].Kind := Kind;
end;

{ a box at BX, BY (its frame; the field above it over BY): pins, fields, the monitor; the places of its pins }
procedure TPlcUI.DrawFbdBox(NI: Integer; N: TNetwork; K: Integer; BX, BY: Single; Cfc: Boolean);
var
  Nd: TFbdNode;
  Bd: TFbdBoxDef;
  BW, BH, InstH, PinY, TW: Single;
  I, F: Integer;
  Ed, Sel, Mon, On1, HasV: Boolean;
  S, Tt: string;
  V: Double;
  DT: TDataType;
  C: TBGRAPixel;
begin
  Nd := N.Nodes[K];
  Bd := FbdBoxDefOf(Nd.Box);
  FbdBoxGeo(Nd, BW, BH, InstH);
  Ed := (NI = FNetSel) and (Screen = scProgram);
  Sel := Ed and (FFbdNet = NI) and (FFbdNode = Nd.Id);
  Mon := MonitorOk and (NI >= 0);
  HasV := Mon and FbdNodeValue(NI, Nd.Id, V, DT);
  // the box: its body and its region first (the pins and fields over it)
  D.Layer := lyControls;
  Shad(BX, BY, BW, BH, 4, 1.5, 3, 50);
  RR(BX, BY, BW, BH, 4, FbdPick(FbdBoxIndex(Nd.Box) >= 0, Mixc(cSheet, cGoldLight, 0.32), Alpha(cRed, 40)));
  if (Sel and (FFbdPin < 0)) or (Ed and (FFbdNet = NI) and FbdInMulti(Nd.Id)) then RRL(BX - 1, BY - 1, BW + 2, BH + 2, 5, 2.2, cRed)
  else if Mon and HasV and (Bd.Outs <> nil) and (Length(Nd.Outs) > 0) and (DT = dtBool) and (V <> 0) then
    RRL(BX, BY, BW, BH, 4, 2, cRed)
  else RRL(BX, BY, BW, BH, 4, 1.1, cInk);
  Rc(BX + 1, BY + 1, BW - 2, FbdHeadH - 3, Alpha(cGold, 90));
  FbdHitAdd(NI, Nd.Id, -1, 0, BX, BY, BW, BH);
  if Cfc then FbdHitAdd(NI, Nd.Id, -1, 4, BX, BY, BW, FbdHeadH);
  D.Layer := lyText;
  Tt := FbdBoxTitle(Nd);
  TW := TxtW(fkUIB, 11, Tt);
  if Nd.Box = 'cmp' then
  begin
    // the operator: a click opens its menu
    Txt(fkUIB, 11, BX + BW / 2, BY + 4, Tt, cRedDark, 1);
    if Ed then FbdHitAdd(NI, Nd.Id, -1, 10, BX + BW / 2 - TW / 2 - 4, BY + 2, TW + 8, 18);
  end
  else
    Txt(fkUIB, 11, BX + BW / 2, BY + 4, Tt, cRedDark, 1);
  if Cfc then
  begin
    // the run order
    RR(BX + BW - 22, BY + 3, 19, 15, 3, Alpha(cRed, 200));
    Txt(fkMonoB, 9, BX + BW - 12.5, BY + 4, IntToStr(Nd.Order), cSheet, 1);
  end;
  S := FbdTypeText(Nd);
  if S <> '' then
  begin
    // the data type, under the title (a click: its menu)
    TxtFit(fkMono, 9, BX + 6, BY + FbdHeadH - 9, BW - 12, S + IfThen(Ed, ' ▾', ''), cInkSoft);
    if Ed then FbdHitAdd(NI, Nd.Id, -1, 9, BX + 2, BY + FbdHeadH - 10, BW - 4, 12);
  end;
  // the field above: the instance / the operand / the block
  if Bd.Inst <> fiNone then
  begin
    D.Layer := lyText;
    if Ed then
    begin
      F := FbdFieldAdd(NI, Nd.Id, -1, 0);
      Field(BX, BY - InstH, BW, 19, Act(fdFbd, F), Nd.Inst, fkMono, 10.5, 1, True, Bd.InstName);
    end
    else if Nd.Inst <> '' then TxtFit(fkMono, 10.5, BX + BW / 2, BY - InstH + 3, BW, Nd.Inst, cInk, 1)
    else TxtFit(fkUI, 10, BX + BW / 2, BY - InstH + 3, BW, '<' + Bd.InstName + '>', cRed, 1);
    if Mon and (Nd.Inst <> '') and (Bd.Inst = fiOperand) then
    begin
      S := LiveOf(Nd.Inst);
      if S <> '' then TxtFit(fkMonoB, 9, BX + BW + 4, BY - InstH + 4, 80, S, cRedDark);
    end;
  end;
  // the inputs
  for I := 0 to High(Nd.Ins) do
  begin
    PinY := BY + FbdHeadH + I * FbdPinH + FbdPinH / 2;
    Sel := Ed and (FFbdNet = NI) and (FFbdNode = Nd.Id) and (FFbdPin = I) and not FFbdPinOut;
    D.Layer := lyControls;
    if Sel then RR(BX - 16, PinY - 9, 18, 18, 3, Alpha(cRed, 70));
    On1 := False;
    if Mon and (Nd.Ins[I].Src = 0) and (Nd.Ins[I].Opnd <> '') then On1 := LiveOf(Nd.Ins[I].Opnd) = 'TRUE';
    Ln(BX - 14, PinY, BX, PinY, IfThen(On1, 2.4, 1.3), FbdPick(On1, cRed, cInk));
    if Nd.Ins[I].Neg then
    begin
      El(BX - 4, PinY, 3.6, 3.6, cSheet);
      ElL(BX - 4, PinY, 3.6, 3.6, 1.2, cInk);
    end;
    D.Layer := lyText;
    TxtFit(fkUI, 10, BX + 5, PinY - 7, BW / 2, Nd.Ins[I].Name, cInkSoft);
    FbdHitAdd(NI, Nd.Id, I, 1, BX - 16, PinY - 9, 16 + Min(40, BW / 2), 18);
    if Nd.Ins[I].Src = 0 then
    begin
      // an operand / a constant
      if Ed then
      begin
        F := FbdFieldAdd(NI, Nd.Id, I, 1);
        Field(BX - 16 - FbdOpW, PinY - 9, FbdOpW - 2, 18, Act(fdFbd, F), Nd.Ins[I].Opnd, fkMono, 10.5, 2, True,
          IfThen((I = 0) and (Nd.Ins[I].Name = 'EN'), '', '?'));
      end
      else if Nd.Ins[I].Opnd <> '' then
        TxtFit(fkMono, 10.5, BX - 18, PinY - 8, FbdOpW, Nd.Ins[I].Opnd, FbdPick(On1, cRed, cInk), 2)
      else if Nd.Ins[I].Name <> 'EN' then
        TxtFit(fkMono, 10.5, BX - 18, PinY - 8, FbdOpW, '?', cRed, 2);
      if Mon and (Nd.Ins[I].Opnd <> '') then
      begin
        // the value of the operand left of it
        S := LiveOf(Nd.Ins[I].Opnd);
        if (S <> '') and (S <> 'TRUE') and (S <> 'FALSE') then
          TxtFit(fkMonoB, 9, BX - 24 - Min(FbdOpW - 20, TxtW(fkMono, 10.5, Nd.Ins[I].Opnd)), PinY - 7, 90, S, cRedDark, 2);
      end;
    end;
  end;
  // + : one more input
  if Bd.Ext and Ed then
  begin
    D.Layer := lyText;
    Txt(fkUIB, 11, BX + 8, BY + BH - 15, '+', cJade);
    FbdHitAdd(NI, Nd.Id, -1, 8, BX + 2, BY + BH - 15, 16, 14);
  end;
  // the outputs
  for I := 0 to High(Nd.Outs) do
  begin
    PinY := BY + FbdHeadH + I * FbdPinH + FbdPinH / 2;
    Sel := Ed and (FFbdNet = NI) and (FFbdNode = Nd.Id) and (FFbdPin = I) and FFbdPinOut;
    On1 := HasV and (I = 0) and (DT = dtBool) and (V <> 0);
    D.Layer := lyControls;
    if Sel then RR(BX + BW - 2, PinY - 9, 18, 18, 3, Alpha(cRed, 70));
    Ln(BX + BW, PinY, BX + BW + 14, PinY, IfThen(On1, 2.4, 1.3), FbdPick(On1, cRed, cInk));
    D.Layer := lyText;
    TxtFit(fkUI, 10, BX + BW - 5, PinY - 7, BW / 2, Nd.Outs[I].Name, cInkSoft, 2);
    FbdHitAdd(NI, Nd.Id, I, 2, BX + BW - Min(40, BW / 2), PinY - 9, Min(40, BW / 2) + 16, 18);
    if not FbdOutWired(N, Nd.Id, I) or (Nd.Outs[I].Opnd <> '') then
    begin
      if Ed then
      begin
        F := FbdFieldAdd(NI, Nd.Id, I, 2);
        Field(BX + BW + 16, PinY - 9, FbdOpW - 2, 18, Act(fdFbd, F), Nd.Outs[I].Opnd, fkMono, 10.5, 0, True, '');
      end
      else if Nd.Outs[I].Opnd <> '' then TxtFit(fkMono, 10.5, BX + BW + 18, PinY - 8, FbdOpW, Nd.Outs[I].Opnd, cInk);
    end;
    if HasV and (I = 0) then
    begin
      // the value of the box
      if DT = dtBool then S := IfThen(V <> 0, 'TRUE', 'FALSE') else S := SclValText(V, DT);
      C := FbdPick((DT = dtBool) and (V = 0), cInkSoft, cRedDark);
      TxtFit(fkMonoB, 9, BX + BW + 18, PinY - 19, 110, S, C);
    end;
  end;
end;

function TPlcUI.FbdOutWired(N: TNetwork; Id, Pin: Integer): Boolean;
var
  K, I: Integer;
begin
  Result := False;
  for K := 0 to High(N.Nodes) do
    for I := 0 to High(N.Nodes[K].Ins) do
      if (N.Nodes[K].Ins[I].Src = Id) and (N.Nodes[K].Ins[I].SrcPin = Pin) then Exit(True);
end;

{ the place of an input / output pin of a box drawn at BX, BY }
function TPlcUI.FbdPinPt(const Nd: TFbdNode; BX, BY: Single; IsOut: Boolean; Pin: Integer): TPointF;
var
  BW, BH, InstH: Single;
begin
  FbdBoxGeo(Nd, BW, BH, InstH);
  if IsOut then Result := PointF(BX + BW + 14, BY + FbdHeadH + Pin * FbdPinH + FbdPinH / 2)
  else Result := PointF(BX - 14, BY + FbdHeadH + Pin * FbdPinH + FbdPinH / 2);
end;

{ FBD: where every box goes (its frame), the height of all; the boxes as trees from the left }
procedure TPlcUI.FbdLayout(N: TNetwork; X0, Y0: Single; out BXs, BYs: TSingleArray; out H: Single);
var
  Placed: array of Boolean;
  Roots: TIntArray;
  K, R: Integer;
  Y: Single;

  function BoxW(Q: Integer): Single;
  var
    BW, BH, IH: Single;
  begin
    FbdBoxGeo(N.Nodes[Q], BW, BH, IH);
    Result := BW;
  end;

  { the room between a box and the boxes that feed it: wider when it has operand fields too (they are left of it) }
  function GapOf(Q: Integer): Single;
  var
    I: Integer;
  begin
    Result := FbdGap;
    for I := 0 to High(N.Nodes[Q].Ins) do
      if (N.Nodes[Q].Ins[I].Src = 0) and ((N.Nodes[Q].Ins[I].Opnd <> '') or (N.Nodes[Q].Ins[I].Name <> 'EN')) then
        Exit(FbdOpW + 30);
  end;

  { the width left of a box: its inputs, the boxes that feed them }
  function WidthLeft(Q, Depth: Integer): Single;
  var
    I, S: Integer;
  begin
    Result := FbdOpW + 18;
    if Depth > 30 then Exit;
    for I := 0 to High(N.Nodes[Q].Ins) do
      if N.Nodes[Q].Ins[I].Src > 0 then
      begin
        S := N.NodeIndex(N.Nodes[Q].Ins[I].Src);
        if (S >= 0) and (S <> Q) then Result := Max(Result, GapOf(Q) + BoxW(S) + WidthLeft(S, Depth + 1));
      end;
  end;

  { a box whose right edge is at RX, from Top; its inputs' boxes first (left of it); the bottom }
  function Place(Q: Integer; RX, Top: Single): Single;
  var
    I, S: Integer;
    BW, BH, IH, Cur, PinY, OutY, CTop, CB: Single;
  begin
    Placed[Q] := True;
    FbdBoxGeo(N.Nodes[Q], BW, BH, IH);
    BXs[Q] := RX - BW;
    BYs[Q] := Top + IH;
    Result := BYs[Q] + BH;
    Cur := Top;
    for I := 0 to High(N.Nodes[Q].Ins) do
      if N.Nodes[Q].Ins[I].Src > 0 then
      begin
        S := N.NodeIndex(N.Nodes[Q].Ins[I].Src);
        if (S < 0) or Placed[S] then Continue;
        // its output as high as the pin, but not over the boxes placed before
        PinY := BYs[Q] + FbdHeadH + I * FbdPinH + FbdPinH / 2;
        FbdBoxGeo(N.Nodes[S], BW, BH, IH);
        OutY := IH + FbdHeadH + N.Nodes[Q].Ins[I].SrcPin * FbdPinH + FbdPinH / 2;
        CTop := Max(Cur, PinY - OutY);
        CB := Place(S, BXs[Q] - GapOf(Q), CTop);
        Cur := CB + 10;
        Result := Max(Result, CB);
      end;
  end;

begin
  SetLength(BXs, Length(N.Nodes));
  SetLength(BYs, Length(N.Nodes));
  SetLength(Placed, Length(N.Nodes));
  Roots := FbdRoots(N);
  Y := Y0;
  for R := 0 to High(Roots) do
  begin
    K := Roots[R];
    Y := Place(K, X0 + WidthLeft(K, 0) + BoxW(K), Y) + 22;
  end;
  // boxes in a loop (no root): below the rest
  for K := 0 to High(N.Nodes) do
    if not Placed[K] then Y := Place(K, X0 + FbdOpW + 18 + BoxW(K), Y) + 22;
  H := Y - Y0;
end;

{ an orthogonal wire from an output pin to an input pin (CFC: around the boxes when it goes back) }
procedure TPlcUI.FbdWire(A, B: TPointF; On1, Sel: Boolean; Back: Single);
var
  MX: Single;
  C: TBGRAPixel;
  LW: Single;
begin
  if On1 then C := cRed else C := cInk;
  if Sel then
  begin
    C := cRedDark;
    LW := 2.6;
  end
  else if On1 then LW := 2.4
  else LW := 1.3;
  D.Layer := lyControls;
  if B.X >= A.X + 16 then
  begin
    MX := A.X + (B.X - A.X) / 2;
    PolyLineD([A, PointF(MX, A.Y), PointF(MX, B.Y), B], LW, C);
  end
  else
    // back to the left: down below the boxes, then into the pin
    PolyLineD([A, PointF(A.X + 10, A.Y), PointF(A.X + 10, Back), PointF(B.X - 10, Back), PointF(B.X - 10, B.Y), B], LW, C);
  El(B.X, B.Y, 2.2, 2.2, C);
end;

function TPlcUI.FbdHeight(N: TNetwork): Single;
var
  BXs, BYs: TSingleArray;
begin
  if N.Kind = nkCFC then Exit(N.ChartH * CfcGrid + 20);
  FbdLayout(N, 0, 0, BXs, BYs, Result);
  Result := Max(Result, 60) + 8;
  // wider than the editor: the scroll bar under the boxes
  if FbdContentW(N) > FbdViewW then Result := Result + 16;
end;

{ the width of the boxes: FBD the trees with their fields, CFC the chart }
function TPlcUI.FbdContentW(N: TNetwork): Single;
var
  BXs, BYs: TSingleArray;
  H, BW, BH, IH: Single;
  K: Integer;
begin
  if N.Kind = nkCFC then Exit(N.ChartW * CfcGrid);
  FbdLayout(N, 8, 0, BXs, BYs, H);
  Result := 0;
  for K := 0 to High(N.Nodes) do
  begin
    FbdBoxGeo(N.Nodes[K], BW, BH, IH);
    Result := Max(Result, BXs[K] + BW + FbdOpW + 24);
  end;
end;

procedure TPlcUI.DrawFbd(NI: Integer; N: TNetwork; X, Y, W: Single);
var
  BXs, BYs: TSingleArray;
  H, AY, HS, CW, TW, TX0: Single;
  K, I, S: Integer;
  A, B: TPointF;
  V: Double;
  DT: TDataType;
begin
  // wider than the editor: it scrolls sideways (the bar below, Shift+wheel)
  HS := 0;
  CW := 0;
  if NI >= 0 then
  begin
    CW := FbdContentW(N);
    HS := EnsureRange(GetHS(N), 0, Max(0, CW - W));
    SetHS(N, HS);
  end;
  FbdLayout(N, X + 8 - HS, Y + 8, BXs, BYs, H);
  if Length(N.Nodes) = 0 then
  begin
    D.Layer := lyText;
    Txt(fkUI, 11.5, X + 14, Y + 14, 'Empty FBD network: double click a box in the elements list (or drag it here).', cInkSoft);
    Txt(fkUI, 10.5, X + 14, Y + 32, 'AND / OR boxes, then = (assignment), timers, counters, math .. and the operands at the pins.',
      cInkFaint);
    FbdHitAdd(NI, 0, -1, 5, X, Y, W, 56);
    Exit;
  end;
  // a click beside the boxes: the network, nothing selected (a picture of the help: no clip of its own)
  FbdHitAdd(NI, 0, -1, 5, X, Y, W, H);
  if NI >= 0 then ClipD(X, Y - 2, W, H + 4);
  // the wires first, then the boxes over them
  for K := 0 to High(N.Nodes) do
    for I := 0 to High(N.Nodes[K].Ins) do
      if N.Nodes[K].Ins[I].Src > 0 then
      begin
        S := N.NodeIndex(N.Nodes[K].Ins[I].Src);
        if S < 0 then Continue;
        A := FbdPinPt(N.Nodes[S], BXs[S], BYs[S], True, N.Nodes[K].Ins[I].SrcPin);
        B := FbdPinPt(N.Nodes[K], BXs[K], BYs[K], False, I);
        AY := 0;
        FbdWire(A, PointF(B.X + 14, B.Y), MonitorOk and FbdNodeValue(NI, N.Nodes[S].Id, V, DT) and (DT = dtBool) and (V <> 0) and
          (N.Nodes[K].Ins[I].SrcPin = 0), False, AY);
      end;
  for K := 0 to High(N.Nodes) do DrawFbdBox(NI, N, K, BXs[K], BYs[K], False);
  if NI < 0 then Exit;
  UnclipD;
  Hit(X, Y, W, H, whLad + NI, hkWheel);
  if CW > W then
  begin
    D.Layer := lyControls;
    TW := Max(30, W * W / CW);
    TX0 := X + HS / (CW - W) * (W - TW);
    RR(X, Y + H + 4, W, 8, 4, Alpha(cSheetDark, 200));
    RR(TX0, Y + H + 4, TW, 8, 4, cRed);
    Hit(X, Y + H, W, 16, Act(acCfcHS, NI), hkDrag);
  end;
end;

procedure TPlcUI.DrawCfc(NI: Integer; N: TNetwork; X, Y, W: Single);
var
  K, I, S: Integer;
  HS, VisW, CW, CH, BW, BH, IH, Bk, TW, TX0: Single;
  A, B: TPointF;
  V: Double;
  DT: TDataType;
  Sel: Boolean;

  function NX(Q: Integer): Single;
  begin
    Result := X + N.Nodes[Q].X * CfcGrid - HS;
  end;

  function NY(Q: Integer): Single;
  begin
    Result := Y + N.Nodes[Q].Y * CfcGrid;
  end;

begin
  VisW := W;
  CW := N.ChartW * CfcGrid;
  CH := N.ChartH * CfcGrid;
  HS := EnsureRange(GetHS(N), 0, Max(0, CW - VisW));
  SetHS(N, HS);
  // the chart: its grid, its region (a drop / a click on it)
  D.Layer := lyControls;
  RR(X, Y, VisW, CH, 4, Mixc(cSheet, cSheet2, 0.35));
  K := 0;
  while K * CfcGrid * 4 < CW do
  begin
    if (K * CfcGrid * 4 - HS >= 0) and (K * CfcGrid * 4 - HS <= VisW) then
      Ln(X + K * CfcGrid * 4 - HS, Y + 2, X + K * CfcGrid * 4 - HS, Y + CH - 2, 0.5, Alpha(cGoldDark, 45));
    Inc(K);
  end;
  K := 0;
  while K * CfcGrid * 4 < CH do
  begin
    Ln(X + 2, Y + K * CfcGrid * 4, X + VisW - 2, Y + K * CfcGrid * 4, 0.5, Alpha(cGoldDark, 45));
    Inc(K);
  end;
  RRL(X, Y, VisW, CH, 4, 0.8, Alpha(cGoldDark, 150));
  if NI >= 0 then
  begin
    Hit(X, Y, VisW, CH, Act(acCfcChart, NI), hkDrag);
    Hit(X, Y, VisW, CH, whLad + NI, hkWheel);
    if NI >= Length(FCfcOrg) then SetLength(FCfcOrg, NI + 1);
    FCfcOrg[NI].X := X;
    FCfcOrg[NI].Y := Y;
    FCfcOrg[NI].HS := HS;
  end;
  if Length(N.Nodes) = 0 then
  begin
    D.Layer := lyText;
    Txt(fkUI, 11.5, X + 14, Y + 12, 'Empty CFC chart: double click a block in the elements list, or drag it onto the chart.',
      cInkSoft);
    Txt(fkUI, 10.5, X + 14, Y + 30, 'Wire a block: drag from an output pin to an input pin. Move it by its title.', cInkFaint);
  end;
  if NI >= 0 then ClipD(X, Y, VisW, CH);
  // the wires (the selected one red), then the blocks
  for K := 0 to High(N.Nodes) do
    for I := 0 to High(N.Nodes[K].Ins) do
      if N.Nodes[K].Ins[I].Src > 0 then
      begin
        S := N.NodeIndex(N.Nodes[K].Ins[I].Src);
        if S < 0 then Continue;
        A := FbdPinPt(N.Nodes[S], NX(S), NY(S), True, N.Nodes[K].Ins[I].SrcPin);
        B := FbdPinPt(N.Nodes[K], NX(K), NY(K), False, I);
        FbdBoxGeo(N.Nodes[S], BW, BH, IH);
        Bk := Max(NY(S) + BH, NY(K) + BH) + 12;
        FbdBoxGeo(N.Nodes[K], BW, BH, IH);
        Bk := Max(Bk, NY(K) + BH + 12);
        Sel := (FFbdNet = NI) and FFbdWire and (FFbdNode = N.Nodes[K].Id) and (FFbdPin = I);
        FbdWire(A, PointF(B.X + 14, B.Y), MonitorOk and FbdNodeValue(NI, N.Nodes[S].Id, V, DT) and (DT = dtBool) and (V <> 0) and
          (N.Nodes[K].Ins[I].SrcPin = 0), Sel, Bk);
        // the wire can be clicked near its end at the pin
        FbdHitAdd(NI, N.Nodes[K].Id, I, 3, B.X - 26, B.Y - 4, 14, 8);
      end;
  for K := 0 to High(N.Nodes) do DrawFbdBox(NI, N, K, NX(K), NY(K), True);
  // a rubber band being drawn
  if (FFbdMode = 4) and (FFbdNet = NI) then
  begin
    D.Layer := lyOverlay;
    Rc(Min(FFbdBand.X, FMX), Min(FFbdBand.Y, FMY), Abs(FMX - FFbdBand.X), Abs(FMY - FFbdBand.Y), Alpha(cGold, 50));
    RRL(Min(FFbdBand.X, FMX), Min(FFbdBand.Y, FMY), Abs(FMX - FFbdBand.X), Abs(FMY - FFbdBand.Y), 2, 1.2, cRedDark);
  end;
  // a wire being drawn
  if (FFbdMode = 2) and (FFbdFrom.NI = NI) then
  begin
    S := N.NodeIndex(FFbdFrom.Node);
    if S >= 0 then
    begin
      A := FbdPinPt(N.Nodes[S], NX(S), NY(S), FFbdFrom.IsOut, FFbdFrom.Pin);
      D.Layer := lyOverlay;
      DashLn(A.X, A.Y, FMX, FMY, 1.6, 5, cRed);
    end;
  end;
  // the size of the chart, sideways (not in a picture of the help)
  if NI < 0 then Exit;
  UnclipD;
  D.Layer := lyText;
  Txt(fkUI, 9.5, X + 2, Y + CH + 3, Format('chart %d x %d', [N.ChartW, N.ChartH]), cInkFaint);
  Button(X + 90, Y + CH + 1, 40, 15, '- H', Act(acCfcSize, NI * 4 + 0), bsFlat, N.ChartH > 20, 9);
  Button(X + 132, Y + CH + 1, 40, 15, '+ H', Act(acCfcSize, NI * 4 + 1), bsFlat, N.ChartH < 200, 9);
  Button(X + 174, Y + CH + 1, 40, 15, '- W', Act(acCfcSize, NI * 4 + 2), bsFlat, N.ChartW * CfcGrid > VisW, 9);
  Button(X + 216, Y + CH + 1, 40, 15, '+ W', Act(acCfcSize, NI * 4 + 3), bsFlat, N.ChartW < 400, 9);
  if CW > VisW then
  begin
    D.Layer := lyControls;
    TW := Max(30, (VisW - 300) * VisW / CW);
    TX0 := X + 270 + HS / (CW - VisW) * (VisW - 300 - TW);
    RR(X + 270, Y + CH + 4, VisW - 300, 8, 4, Alpha(cSheetDark, 200));
    RR(TX0, Y + CH + 4, TW, 8, 4, cRed);
    Hit(X + 270, Y + CH, VisW - 300, 16, Act(acCfcHS, NI), hkDrag);
  end;
end;

{ ---------- editing ---------- }

function TPlcUI.FbdSelNode(out N: TNetwork; out K: Integer): Boolean;
begin
  Result := False;
  N := CurNet;
  K := -1;
  if (N = nil) or not (N.Kind in [nkFBD, nkCFC]) or (FFbdNet <> FNetSel) then Exit;
  K := N.NodeIndex(FFbdNode);
  Result := K >= 0;
end;

{ a new box: onto the selected input pin (its operand moves to the new box), into the first free input of the
  selected box, or a new root / a new block of the chart; CFC: at the place given (or right of the selection) }
procedure TPlcUI.FbdInsert(const Id, Blk: string; AtX, AtY: Integer);
var
  N: TNetwork;
  K, Q, I, Fi: Integer;
  Nd: TFbdNode;
  Old: string;
  Target: Boolean;
begin
  N := CurNet;
  if (N = nil) or not (N.Kind in [nkFBD, nkCFC]) then
  begin
    Toast('select an FBD or a CFC network first', True);
    Exit;
  end;
  if FFbdNet <> FNetSel then
  begin
    FFbdNode := 0;
    FFbdPin := -1;
  end;
  Nd := NewFbdNode(N, Id, Project, Blk);
  if (Id = 'call') and (Length(Nd.Ins) + Length(Nd.Outs) <= 1) and (Blk <> '') then
    Toast('the block ' + Blk + ' was not found: its pins come when it is there', True);
  Fi := 0;
  if (Length(Nd.Ins) > 0) and (Nd.Ins[0].Name = 'EN') and (Length(Nd.Ins) > 1) then Fi := 1;
  K := N.NodeIndex(FFbdNode);
  Target := False;
  // after the selected box (its output pin, or the box whose output feeds nothing yet): the new box reads it
  if (K >= 0) and (Length(Nd.Ins) > Fi) and (Length(N.Nodes[K].Outs) > 0) and
    ((FFbdPinOut and (FFbdPin >= 0)) or ((FFbdPin < 0) and not FbdOutWired(N, N.Nodes[K].Id, 0))) then
  begin
    if FFbdPinOut then Q := FFbdPin else Q := 0;
    Nd.Ins[Fi].Src := N.Nodes[K].Id;
    Nd.Ins[Fi].SrcPin := Q;
    Target := True;
    if N.Kind = nkCFC then
    begin
      Nd.X := N.Nodes[K].X + 26;
      Nd.Y := N.Nodes[K].Y;
    end;
    K := -1;
  end;
  if (K >= 0) and (Length(Nd.Outs) > 0) then
  begin
    Q := -1;
    if (FFbdPin >= 0) and not FFbdPinOut and (FFbdPin <= High(N.Nodes[K].Ins)) then Q := FFbdPin
    else
      for I := 0 to High(N.Nodes[K].Ins) do
        if (N.Nodes[K].Ins[I].Src = 0) and (Trim(N.Nodes[K].Ins[I].Opnd) = '') and (N.Nodes[K].Ins[I].Name <> 'EN') then
        begin
          Q := I;
          Break;
        end;
    if Q >= 0 then
    begin
      // the operand of the pin goes onto the first input of the new box
      Old := N.Nodes[K].Ins[Q].Opnd;
      if (Old <> '') and (Fi <= High(Nd.Ins)) then Nd.Ins[Fi].Opnd := Old;
      N.Nodes[K].Ins[Q].Opnd := '';
      N.Nodes[K].Ins[Q].Src := Nd.Id;
      N.Nodes[K].Ins[Q].SrcPin := 0;
      Target := True;
      if N.Kind = nkCFC then
      begin
        Nd.X := Max(1, N.Nodes[K].X - 26);
        Nd.Y := N.Nodes[K].Y + Q * 2;
      end;
    end;
  end;
  if N.Kind = nkCFC then
  begin
    if AtX >= 0 then
    begin
      Nd.X := AtX;
      Nd.Y := AtY;
    end
    else if not Target then CfcFreePlace(N, Nd);
    Nd.Order := Length(N.Nodes) + 1;
    N.ChartW := Max(N.ChartW, Nd.X + 30);
    N.ChartH := Max(N.ChartH, Nd.Y + 4 + Max(Length(Nd.Ins), Length(Nd.Outs)) * 2 + 4);
  end;
  SetLength(N.Nodes, Length(N.Nodes) + 1);
  N.Nodes[High(N.Nodes)] := Nd;
  if N.Kind = nkCFC then CfcRenumber(N);
  FFbdNet := FNetSel;
  FFbdNode := Nd.Id;
  // the next operand goes to the field above the box (=, S, R, a timer ..) or its first free input
  FFbdPin := -1;
  if (FbdBoxDefOf(Id).Inst = fiNone) or (Id = 'call') then
    for Q := 0 to High(Nd.Ins) do
      if (Nd.Ins[Q].Src = 0) and (Nd.Ins[Q].Opnd = '') and (Nd.Ins[Q].Name <> 'EN') then
      begin
        FFbdPin := Q;
        Break;
      end;
  FFbdPinOut := False;
  FFbdWire := False;
  FStlNet := -1;
  MarkDirty;
end;

{ CFC: a free place for a new block (right of the selected one, else below the others) }
procedure TPlcUI.CfcFreePlace(N: TNetwork; var Nd: TFbdNode);
var
  K, Bot: Integer;
  BW, BH, IH, NBW, NBH, NIH: Single;
begin
  FbdBoxGeo(Nd, NBW, NBH, NIH);
  K := N.NodeIndex(FFbdNode);
  if K >= 0 then
  begin
    FbdBoxGeo(N.Nodes[K], BW, BH, IH);
    Nd.X := N.Nodes[K].X + Ceil((BW + 2 * FbdOpW + 40) / CfcGrid);
    Nd.Y := N.Nodes[K].Y;
  end
  else
  begin
    // below the blocks there are (their frames and the fields above them)
    Bot := 0;
    for K := 0 to High(N.Nodes) do
    begin
      FbdBoxGeo(N.Nodes[K], BW, BH, IH);
      Bot := Max(Bot, N.Nodes[K].Y + Ceil(BH / CfcGrid));
    end;
    Nd.X := 16;
    Nd.Y := Bot + 2 + Ceil(NIH / CfcGrid);
  end;
end;

{ an operand onto the selected pin, or the field above the selected box }
procedure TPlcUI.FbdPutOperand(const S: string);
var
  N: TNetwork;
  K: Integer;
begin
  if not FbdSelNode(N, K) then
  begin
    Toast('select a pin of a box first', True);
    Exit;
  end;
  if FFbdPin < 0 then
  begin
    if FbdBoxDefOf(N.Nodes[K].Box).Inst = fiNone then
    begin
      Toast('select a pin of the box first', True);
      Exit;
    end;
    N.Nodes[K].Inst := S;
    if N.Nodes[K].Box = 'call' then FbdCallPins(Project, S, N.Nodes[K]);
  end
  else if FFbdPinOut then N.Nodes[K].Outs[FFbdPin].Opnd := S
  else
  begin
    N.Nodes[K].Ins[FFbdPin].Src := 0;
    N.Nodes[K].Ins[FFbdPin].Opnd := S;
    // the next input
    if FFbdPin < High(N.Nodes[K].Ins) then Inc(FFbdPin);
  end;
  MarkDirty;
end;

procedure TPlcUI.FbdDelete;
var
  N: TNetwork;
  K: Integer;
begin
  if not FbdSelNode(N, K) then Exit;
  if (Length(FFbdMulti) > 1) and (FFbdPin < 0) and not FFbdWire then
  begin
    // the selected boxes
    for K := 0 to High(FFbdMulti) do FbdDeleteNode(N, FFbdMulti[K], False);
    if N.Kind = nkCFC then CfcRenumber(N);
    FFbdMulti := nil;
    FFbdNode := 0;
    MarkDirty;
    Exit;
  end;
  if FFbdWire and (FFbdPin >= 0) and (FFbdPin <= High(N.Nodes[K].Ins)) then
  begin
    N.Nodes[K].Ins[FFbdPin].Src := 0;
    FFbdWire := False;
  end
  else if (FFbdPin >= 0) and not FFbdPinOut and (FFbdPin <= High(N.Nodes[K].Ins)) then
  begin
    // a pin: its wire, else its operand; an added input goes
    if N.Nodes[K].Ins[FFbdPin].Src > 0 then
    begin
      if N.Kind = nkFBD then FbdDeleteNode(N, N.Nodes[K].Ins[FFbdPin].Src, True)
      else N.Nodes[K].Ins[FFbdPin].Src := 0;
    end
    else if N.Nodes[K].Ins[FFbdPin].Opnd <> '' then N.Nodes[K].Ins[FFbdPin].Opnd := ''
    else if FbdRemoveInput(N.Nodes[K], FFbdPin) then FFbdPin := Min(FFbdPin, High(N.Nodes[K].Ins));
  end
  else if (FFbdPin >= 0) and FFbdPinOut then N.Nodes[K].Outs[FFbdPin].Opnd := ''
  else
  begin
    // the box (FBD: and the boxes that feed only it)
    FbdDeleteNode(N, FFbdNode, N.Kind = nkFBD);
    if N.Kind = nkCFC then CfcRenumber(N);
    FFbdNode := 0;
    FFbdPin := -1;
  end;
  MarkDirty;
end;

procedure TPlcUI.FbdSelect(const H: TFbdHitRec);
begin
  FHelpFocus := False;
  FNetSel := H.NI;
  FStlNet := -1;
  FFbdNet := H.NI;
  FFbdNode := H.Node;
  FFbdWire := H.Kind = 3;
  case H.Kind of
    1, 3:
      begin
        FFbdPin := H.Pin;
        FFbdPinOut := False;
      end;
    2:
      begin
        FFbdPin := H.Pin;
        FFbdPinOut := True;
      end;
  else
    begin
      FFbdPin := -1;
      FFbdPinOut := False;
    end;
  end;
end;

{ a press / a drag / the release on a box, a pin or the chart }
procedure TPlcUI.FbdDrag(Id: Integer; X, Y: Single);
var
  Hi, I: Integer;
  H: TFbdHitRec;
  N: TNetwork;
  K: Integer;
begin
  if Id shr 16 = acCfcChart then
  begin
    if FDragPress <> FPressNo then
    begin
      FDragPress := FPressNo;
      // the empty chart: the network, no box; a drag: a rubber band selects the blocks in it
      FNetSel := Id and $FFFF;
      FStlNet := -1;
      FHelpFocus := False;
      FFbdNet := FNetSel;
      FFbdNode := 0;
      FFbdPin := -1;
      FFbdWire := False;
      if not (umShift in MouseMods) then FFbdMulti := nil;
      FFbdBand := PointF(X, Y);
      FFbdMode := 4;
    end;
    Exit;
  end;
  if Id shr 16 = acCfcHS then
  begin
    if (CurBlock = nil) or ((Id and $FFFF) >= CurBlock.NetCount) then Exit;
    N := CurBlock.Net(Id and $FFFF);
    if FDragPress <> FPressNo then
    begin
      FDragPress := FPressNo;
      FFbdGrab := PointF(X, GetHS(N));
    end;
    if N.Kind = nkCFC then SetHS(N, Max(0, FFbdGrab.Y + (X - FFbdGrab.X) * FbdContentW(N) / (FbdViewW - 300)))
    else SetHS(N, Max(0, FFbdGrab.Y + (X - FFbdGrab.X) * FbdContentW(N) / FbdViewW));
    Exit;
  end;
  Hi := Id and $FFFF;
  if Hi > High(FFbdHits) then Exit;
  H := FFbdHits[Hi];
  if (CurBlock = nil) or (H.NI >= CurBlock.NetCount) then Exit;
  N := CurBlock.Net(H.NI);
  if FDragPress <> FPressNo then
  begin
    FDragPress := FPressNo;
    FFbdMode := 0;
    FFbdGrab := PointF(X, Y);
    FHelpFocus := False;
    // Shift+click on a box: it joins the selection (or leaves it)
    if (umShift in MouseMods) and (H.Kind in [0, 4]) and (H.Node > 0) then
    begin
      if FbdInMulti(H.Node) then
      begin
        for K := 0 to High(FFbdMulti) do
          if FFbdMulti[K] = H.Node then
          begin
            FFbdMulti[K] := FFbdMulti[High(FFbdMulti)];
            SetLength(FFbdMulti, Length(FFbdMulti) - 1);
            Break;
          end;
      end
      else
      begin
        if (FFbdNet = H.NI) and (FFbdNode > 0) and not FbdInMulti(FFbdNode) then
        begin
          SetLength(FFbdMulti, Length(FFbdMulti) + 1);
          FFbdMulti[High(FFbdMulti)] := FFbdNode;
        end;
        SetLength(FFbdMulti, Length(FFbdMulti) + 1);
        FFbdMulti[High(FFbdMulti)] := H.Node;
      end;
      FNetSel := H.NI;
      FFbdNet := H.NI;
      FFbdNode := H.Node;
      FFbdPin := -1;
      Exit;
    end;
    // a block of the selection: they move together; another box: it alone
    if not ((H.Kind in [0, 4]) and FbdInMulti(H.Node) and (FFbdNet = H.NI)) then
    begin
      if H.Node > 0 then
      begin
        SetLength(FFbdMulti, 1);
        FFbdMulti[0] := H.Node;
      end
      else FFbdMulti := nil;
    end;
    case H.Kind of
      5:
        begin
          FNetSel := H.NI;
          FStlNet := -1;
          FFbdNet := H.NI;
          FFbdNode := 0;
          FFbdPin := -1;
          FFbdWire := False;
        end;
      9, 10:
        begin
          FbdSelect(H);
          FbdTypeMenu(H.Kind = 10);
        end;
    else
      FbdSelect(H);
    end;
    if H.Kind = 8 then
    begin
      FbdSelect(H);
      K := N.NodeIndex(H.Node);
      if (K >= 0) and FbdAddInput(N.Nodes[K]) then MarkDirty;
    end;
    K := N.NodeIndex(H.Node);
    if (N.Kind = nkCFC) and (K >= 0) then
    begin
      FFbdGrab0 := Point(N.Nodes[K].X, N.Nodes[K].Y);
      SetLength(FFbdMove0, Length(FFbdMulti));
      for I := 0 to High(FFbdMulti) do
        if N.NodeIndex(FFbdMulti[I]) >= 0 then
          FFbdMove0[I] := Point(N.Nodes[N.NodeIndex(FFbdMulti[I])].X, N.Nodes[N.NodeIndex(FFbdMulti[I])].Y);
      if H.Kind in [0, 4] then FFbdMode := 1
      else if H.Kind in [1, 2] then
      begin
        FFbdMode := 3;   // a wire, once the mouse moves
        FFbdFrom.NI := H.NI;
        FFbdFrom.Node := H.Node;
        FFbdFrom.Pin := H.Pin;
        FFbdFrom.IsOut := H.Kind = 2;
      end;
    end;
    Exit;
  end;
  if N.Kind <> nkCFC then Exit;
  K := N.NodeIndex(FFbdFrom.Node);
  if FFbdMode = 1 then
  begin
    // the block (the selected blocks) move by the grid
    if Length(FFbdMulti) > 1 then
    begin
      for I := 0 to Min(High(FFbdMulti), High(FFbdMove0)) do
      begin
        K := N.NodeIndex(FFbdMulti[I]);
        if K < 0 then Continue;
        N.Nodes[K].X := Max(0, FFbdMove0[I].X + Round((X - FFbdGrab.X) / CfcGrid));
        N.Nodes[K].Y := Max(0, FFbdMove0[I].Y + Round((Y - FFbdGrab.Y) / CfcGrid));
        N.ChartW := Max(N.ChartW, N.Nodes[K].X + 30);
        N.ChartH := Max(N.ChartH, N.Nodes[K].Y + 4 + Max(Length(N.Nodes[K].Ins), Length(N.Nodes[K].Outs)) * 2 + 4);
      end;
      FFbdMoved := True;
      Exit;
    end;
    K := N.NodeIndex(H.Node);
    if K < 0 then Exit;
    N.Nodes[K].X := Max(0, FFbdGrab0.X + Round((X - FFbdGrab.X) / CfcGrid));
    N.Nodes[K].Y := Max(0, FFbdGrab0.Y + Round((Y - FFbdGrab.Y) / CfcGrid));
    N.ChartW := Max(N.ChartW, N.Nodes[K].X + 30);
    N.ChartH := Max(N.ChartH, N.Nodes[K].Y + 4 + Max(Length(N.Nodes[K].Ins), Length(N.Nodes[K].Outs)) * 2 + 4);
    FFbdMoved := True;
  end
  else if (FFbdMode = 3) and (Abs(X - FFbdGrab.X) + Abs(Y - FFbdGrab.Y) > 5) then FFbdMode := 2;
end;

procedure TPlcUI.FbdDragEnd(Id: Integer; X, Y: Single);
var
  Hd: THit;
  H: TFbdHitRec;
  N: TNetwork;
  Ka, Kb: Integer;
  OutN, OutP, InN, InP: Integer;
  R: TRectF;
  BW, BH, IH, BX, BY: Single;
begin
  if FFbdMode = 4 then
  begin
    // the rubber band: the blocks it touches
    FFbdMode := 0;
    if (CurBlock = nil) or (FFbdNet >= CurBlock.NetCount) or (FFbdNet >= Length(FCfcOrg)) then Exit;
    if Abs(X - FFbdBand.X) + Abs(Y - FFbdBand.Y) < 5 then Exit;
    N := CurBlock.Net(FFbdNet);
    R := RectF(Min(X, FFbdBand.X), Min(Y, FFbdBand.Y), Max(X, FFbdBand.X), Max(Y, FFbdBand.Y));
    for Ka := 0 to High(N.Nodes) do
    begin
      FbdBoxGeo(N.Nodes[Ka], BW, BH, IH);
      BX := FCfcOrg[FFbdNet].X + N.Nodes[Ka].X * CfcGrid - FCfcOrg[FFbdNet].HS;
      BY := FCfcOrg[FFbdNet].Y + N.Nodes[Ka].Y * CfcGrid;
      if (BX < R.Right) and (BX + BW > R.Left) and (BY < R.Bottom) and (BY + BH > R.Top) and not FbdInMulti(N.Nodes[Ka].Id) then
      begin
        SetLength(FFbdMulti, Length(FFbdMulti) + 1);
        FFbdMulti[High(FFbdMulti)] := N.Nodes[Ka].Id;
      end;
    end;
    if Length(FFbdMulti) > 0 then FFbdNode := FFbdMulti[0];
    Exit;
  end;
  if FFbdMode = 1 then
  begin
    if FFbdMoved then MarkDirty;
    FFbdMoved := False;
  end
  else if FFbdMode = 2 then
  begin
    // the wire ends on a pin: an output of one block into an input of another
    if HitAt(X, Y, Hd) and (Hd.Id shr 16 = acFbdHit) and ((Hd.Id and $FFFF) <= High(FFbdHits)) then
    begin
      H := FFbdHits[Hd.Id and $FFFF];
      if (H.NI = FFbdFrom.NI) and (H.Kind in [1, 2]) and ((H.Kind = 2) <> FFbdFrom.IsOut) and (H.Node <> FFbdFrom.Node) then
      begin
        if FFbdFrom.IsOut then
        begin
          OutN := FFbdFrom.Node;
          OutP := FFbdFrom.Pin;
          InN := H.Node;
          InP := H.Pin;
        end
        else
        begin
          OutN := H.Node;
          OutP := H.Pin;
          InN := FFbdFrom.Node;
          InP := FFbdFrom.Pin;
        end;
        N := CurBlock.Net(H.NI);
        Kb := N.NodeIndex(InN);
        Ka := N.NodeIndex(OutN);
        if (Ka >= 0) and (Kb >= 0) then
        begin
          N.Nodes[Kb].Ins[InP].Src := OutN;
          N.Nodes[Kb].Ins[InP].SrcPin := OutP;
          N.Nodes[Kb].Ins[InP].Opnd := '';
          CfcRenumber(N);
          FFbdNode := InN;
          FFbdPin := InP;
          FFbdPinOut := False;
          FFbdWire := True;
          MarkDirty;
        end;
      end
      else Toast('a wire goes from an output pin to an input pin of another block', True);
    end;
  end;
  FFbdMode := 0;
end;

{ the menu of the data type (or of the comparison) of the selected box }
procedure TPlcUI.FbdTypeMenu(Cmp: Boolean);
var
  N: TNetwork;
  K, I: Integer;
  Ch: TStringArray;
  Ids: array of Integer;
  En: array of Boolean;
  Bd: TFbdBoxDef;
begin
  if not FbdSelNode(N, K) then Exit;
  if Cmp then
  begin
    OpenCtx(FMX, FMY, ['==', '<>', '>', '<', '>=', '<='], [Act(acFbdCmp, 0), Act(acFbdCmp, 1), Act(acFbdCmp, 2),
      Act(acFbdCmp, 3), Act(acFbdCmp, 4), Act(acFbdCmp, 5)], [True, True, True, True, True, True]);
    Exit;
  end;
  Bd := FbdBoxDefOf(N.Nodes[K].Box);
  Ch := FbdTypeChoices(Bd);
  if Bd.HasType2 then
  begin
    // CONV / ROUND ..: the IN type, then the OUT type
    SetLength(Ids, 0);
    SetLength(En, 0);
    for I := 0 to High(Ch) do
    begin
      SetLength(Ids, Length(Ids) + 1);
      Ids[High(Ids)] := Act(acFbdType, I);
      SetLength(En, Length(En) + 1);
      En[High(En)] := True;
    end;
    for I := 0 to High(Ch) do Ch[I] := 'IN: ' + Ch[I];
    FbdTypeMenu2(Ch, Ids, En, Bd);
    Exit;
  end;
  SetLength(Ids, Length(Ch));
  SetLength(En, Length(Ch));
  for I := 0 to High(Ch) do
  begin
    Ids[I] := Act(acFbdType, I);
    En[I] := True;
  end;
  if Length(Ch) > 0 then OpenCtx(FMX, FMY, Ch, Ids, En);
end;

procedure TPlcUI.FbdTypeMenu2(const Ch: TStringArray; const Ids: array of Integer; const En: array of Boolean;
  const Bd: TFbdBoxDef);
var
  All: TStringArray;
  AIds: array of Integer;
  AEn: array of Boolean;
  Outs: array of string;
  I, N0: Integer;
begin
  // IN types, then OUT types (Par + 1000)
  if Bd.Id = 'conv' then
  begin
    SetLength(Outs, 0);
    All := FbdTypeChoices(Bd);
    for I := 0 to High(All) do
    begin
      SetLength(Outs, Length(Outs) + 1);
      Outs[High(Outs)] := All[I];
    end;
  end
  else
  begin
    SetLength(Outs, 6);
    Outs[0] := 'DInt';
    Outs[1] := 'Int';
    Outs[2] := 'SInt';
    Outs[3] := 'LInt';
    Outs[4] := 'UDInt';
    Outs[5] := 'UInt';
  end;
  N0 := Length(Ch);
  SetLength(All, N0 + Length(Outs));
  SetLength(AIds, N0 + Length(Outs));
  SetLength(AEn, N0 + Length(Outs));
  for I := 0 to N0 - 1 do
  begin
    All[I] := Ch[I];
    AIds[I] := Ids[I];
    AEn[I] := En[I];
  end;
  for I := 0 to High(Outs) do
  begin
    All[N0 + I] := 'OUT: ' + Outs[I];
    AIds[N0 + I] := Act(acFbdType, 1000 + I);
    AEn[N0 + I] := True;
  end;
  FFbdOutTypes := Outs;
  OpenCtx(FMX, FMY, All, AIds, AEn);
end;

procedure TPlcUI.FbdSetType(Par: Integer);
var
  N: TNetwork;
  K, Lo, Hi: Integer;
  Ch: TStringArray;
  T: TDataType;
begin
  if not FbdSelNode(N, K) then Exit;
  if Par >= 1000 then
  begin
    if (Par - 1000 <= High(FFbdOutTypes)) and ParseDataType(FFbdOutTypes[Par - 1000], T, Lo, Hi) then N.Nodes[K].DType2 := T;
  end
  else
  begin
    Ch := FbdTypeChoices(FbdBoxDefOf(N.Nodes[K].Box));
    if (Par <= High(Ch)) and ParseDataType(Ch[Par], T, Lo, Hi) then N.Nodes[K].DType := T;
  end;
  MarkDirty;
end;

{ the right button on a box / a pin / a wire }
procedure TPlcUI.FbdMenu(Hi: Integer);
var
  H: TFbdHitRec;
  N: TNetwork;
  K: Integer;
  Bd: TFbdBoxDef;
  Pin, Cf: Boolean;
begin
  if Hi > High(FFbdHits) then Exit;
  H := FFbdHits[Hi];
  if H.Kind = 5 then
  begin
    FNetSel := H.NI;
    DoClick(Act(acNetHead, H.NI), '');
    Exit;
  end;
  FbdSelect(H);
  N := CurNet;
  if N = nil then Exit;
  K := N.NodeIndex(H.Node);
  if K < 0 then Exit;
  Bd := FbdBoxDefOf(N.Nodes[K].Box);
  Pin := (H.Kind = 1) or (H.Kind = 3);
  Cf := N.Kind = nkCFC;
  OpenCtx(FMX, FMY, ['Help'#9'F1', 'Add input', 'Remove this input', 'Negate this input', 'Data type ...',
    'Cut the wire', 'Delete the box'#9'Del', 'Run earlier', 'Run later', 'Order by the data flow',
    'Cross reference'#9'F11'],
    [Act(acFbdCtx, 0), Act(acFbdCtx, 1), Act(acFbdCtx, 2), Act(acFbdCtx, 3), Act(acFbdCtx, 4), Act(acFbdCtx, 5),
    Act(acFbdCtx, 6), Act(acFbdCtx, 7), Act(acFbdCtx, 8), Act(acFbdCtx, 9), Act(acFbdCtx, 10)],
    [True, Bd.Ext, Pin and Bd.Ext and (H.Pin >= Length(Bd.Ins)), Pin and ((H.Pin > High(Bd.Ins)) or (Bd.Ins[Min(H.Pin, High(Bd.Ins))].Ty = 'B')),
    Bd.HasType or Bd.HasCmp, Pin and (N.Nodes[K].Ins[H.Pin].Src > 0), True, Cf, Cf, Cf, XrefAtCaret <> '']);
end;

procedure TPlcUI.FbdCtx(Par: Integer);
var
  N: TNetwork;
  K, I: Integer;
begin
  if not FbdSelNode(N, K) then Exit;
  case Par of
    0: FbdHelp(N.Nodes[K].Box);
    1: if FbdAddInput(N.Nodes[K]) then MarkDirty;
    2: if (FFbdPin >= 0) and FbdRemoveInput(N.Nodes[K], FFbdPin) then
       begin
         FFbdPin := -1;
         MarkDirty;
       end;
    3: if (FFbdPin >= 0) and not FFbdPinOut and (FFbdPin <= High(N.Nodes[K].Ins)) then
       begin
         N.Nodes[K].Ins[FFbdPin].Neg := not N.Nodes[K].Ins[FFbdPin].Neg;
         MarkDirty;
       end;
    4: FbdTypeMenu(N.Nodes[K].Box = 'cmp');
    5: if (FFbdPin >= 0) and (FFbdPin <= High(N.Nodes[K].Ins)) then
       begin
         N.Nodes[K].Ins[FFbdPin].Src := 0;
         if N.Kind = nkCFC then CfcRenumber(N);
         MarkDirty;
       end;
    6:
      begin
        FFbdPin := -1;
        FFbdWire := False;
        FbdDelete;
      end;
    7, 8:
      begin
        // between the blocks that do not depend on each other: one place earlier / later
        for I := 0 to High(N.Nodes) do
          if (Par = 7) and (N.Nodes[I].Order = N.Nodes[K].Order - 1) then
          begin
            N.Nodes[I].Order := N.Nodes[K].Order;
            N.Nodes[K].Order := N.Nodes[K].Order - 1;
            Break;
          end
          else if (Par = 8) and (N.Nodes[I].Order = N.Nodes[K].Order + 1) then
          begin
            N.Nodes[I].Order := N.Nodes[K].Order;
            N.Nodes[K].Order := N.Nodes[K].Order + 1;
            Break;
          end;
        CfcRenumber(N);
        MarkDirty;
      end;
    9:
      begin
        for I := 0 to High(N.Nodes) do N.Nodes[I].Order := I + 1;
        CfcRenumber(N);
        MarkDirty;
      end;
    10: XrefOpen(XrefAtCaret, CurBlock);
  end;
end;

{ the help of a box: the page of the element of the panel }
procedure TPlcUI.FbdHelp(const Box: string);
var
  K: Integer;
begin
  for K := 0 to High(FElems) do
    if FElems[K].Snip = FbdBoxSnip + Box then
    begin
      EhOpen(K);
      Exit;
    end;
end;

{ a LAD network as FBD / CFC (Par: the network * 4 + 0 FBD / 1 CFC); FBD <-> CFC keeps the boxes }
procedure TPlcUI.NetConvert(Par: Integer);
var
  B: TBlock;
  N, F: TNetwork;
  NI: Integer;
  Err: string;
begin
  B := CurBlock;
  NI := Par div 4;
  if (B = nil) or (NI >= B.NetCount) then Exit;
  N := B.Net(NI);
  if N.Kind = nkLAD then
  begin
    F := LadToFbd(N, Project, Err);
    if F = nil then
    begin
      Toast('cannot convert: ' + Err, True);
      Exit;
    end;
    if Par mod 4 = 1 then
    begin
      F.Kind := nkCFC;
      CfcAutoPlace(F);
    end;
    N.Free;
    B.Networks[NI] := F;
  end
  else if N.Kind in [nkFBD, nkCFC] then
  begin
    if Par mod 4 = 1 then
    begin
      N.Kind := nkCFC;
      CfcAutoPlace(N);
    end
    else N.Kind := nkFBD;
  end;
  FNetSel := NI;
  FStlNet := -1;
  SetLength(FHScroll, 0);
  MarkDirty;
  Toast(Format('network %d is %s now (Undo takes it back)', [NI + 1, NetLangName(B.Net(NI).Kind)]));
end;

{ a field of a box: its operand / instance (CommitEdit) }
procedure TPlcUI.FbdCommit(Par: Integer; const S: string);
var
  N: TNetwork;
  K: Integer;
begin
  if (Par > High(FFbdFlds)) or (CurBlock = nil) or (FFbdFlds[Par].NI >= CurBlock.NetCount) then Exit;
  N := CurBlock.Net(FFbdFlds[Par].NI);
  K := N.NodeIndex(FFbdFlds[Par].Node);
  if K < 0 then Exit;
  case FFbdFlds[Par].Kind of
    0:
      begin
        if N.Nodes[K].Inst = Trim(S) then Exit;
        N.Nodes[K].Inst := Trim(S);
        if N.Nodes[K].Box = 'call' then FbdCallPins(Project, Trim(S), N.Nodes[K]);
      end;
    1:
      begin
        if N.Nodes[K].Ins[FFbdFlds[Par].Pin].Opnd = Trim(S) then Exit;
        N.Nodes[K].Ins[FFbdFlds[Par].Pin].Opnd := Trim(S);
      end;
  else
    begin
      if N.Nodes[K].Outs[FFbdFlds[Par].Pin].Opnd = Trim(S) then Exit;
      N.Nodes[K].Outs[FFbdFlds[Par].Pin].Opnd := Trim(S);
    end;
  end;
  MarkDirty;
end;

{ a box with pins of its own (a dynamic array is shared, not copied on a write) }
function CopyOneNode(const Nd: TFbdNode): TFbdNode;
begin
  Result := Nd;
  Result.Ins := Copy(Nd.Ins);
  Result.Outs := Copy(Nd.Outs);
end;

function TPlcUI.FbdInMulti(Id: Integer): Boolean;
var
  K: Integer;
begin
  Result := False;
  for K := 0 to High(FFbdMulti) do
    if FFbdMulti[K] = Id then Exit(True);
end;

{ the boxes to copy / cut: the selected ones (more than one), else the selected box (FBD: with the boxes that feed it) }
function TPlcUI.FbdSelIds(N: TNetwork): TIntArray;
var
  K: Integer;

  procedure Take(Id: Integer);
  var
    Q, P: Integer;
  begin
    for P := 0 to High(Result) do
      if Result[P] = Id then Exit;
    Q := N.NodeIndex(Id);
    if Q < 0 then Exit;
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := Id;
    if N.Kind = nkFBD then
      for P := 0 to High(N.Nodes[Q].Ins) do
        if N.Nodes[Q].Ins[P].Src > 0 then Take(N.Nodes[Q].Ins[P].Src);
  end;

begin
  Result := nil;
  if Length(FFbdMulti) > 1 then
  begin
    for K := 0 to High(FFbdMulti) do
      if N.NodeIndex(FFbdMulti[K]) >= 0 then
      begin
        SetLength(Result, Length(Result) + 1);
        Result[High(Result)] := FFbdMulti[K];
      end;
  end
  else if N.NodeIndex(FFbdNode) >= 0 then Take(FFbdNode);
end;

{ Ctrl+C / Ctrl+X: the boxes into the clipboard of the editor (the wires between them stay, the others are cut) }
procedure TPlcUI.FbdCopy(Cut: Boolean);
var
  N: TNetwork;
  Ids: TIntArray;
  K, I, J, C: Integer;
  Inside: Boolean;
begin
  N := CurNet;
  if (N = nil) or not (N.Kind in [nkFBD, nkCFC]) or (FFbdNet <> FNetSel) then Exit;
  Ids := FbdSelIds(N);
  if Length(Ids) = 0 then
  begin
    Toast('select a box first (CFC: a rubber band selects several)', True);
    Exit;
  end;
  FFbdClip := nil;
  for K := 0 to High(N.Nodes) do
  begin
    Inside := False;
    for J := 0 to High(Ids) do
      if Ids[J] = N.Nodes[K].Id then Inside := True;
    if not Inside then Continue;
    C := Length(FFbdClip);
    SetLength(FFbdClip, C + 1);
    FFbdClip[C] := CopyOneNode(N.Nodes[K]);
  end;
  for K := 0 to High(FFbdClip) do
    for I := 0 to High(FFbdClip[K].Ins) do
      if FFbdClip[K].Ins[I].Src > 0 then
      begin
        Inside := False;
        for J := 0 to High(Ids) do
          if Ids[J] = FFbdClip[K].Ins[I].Src then Inside := True;
        if not Inside then FFbdClip[K].Ins[I].Src := 0;
      end;
  FFbdClipCfc := N.Kind = nkCFC;
  if Cut then
  begin
    for K := 0 to High(Ids) do FbdDeleteNode(N, Ids[K], False);
    if N.Kind = nkCFC then CfcRenumber(N);
    FFbdMulti := nil;
    FFbdNode := 0;
    FFbdPin := -1;
    MarkDirty;
    Toast(Format('%d boxes cut', [Length(FFbdClip)]));
  end
  else Toast(Format('%d boxes copied', [Length(FFbdClip)]));
end;

{ Ctrl+V: the copied boxes with new Ids (their wires too); FBD: a root onto the selected input pin, else new trees;
  CFC: beside the copied ones (from FBD: placed by the data flow below the chart) }
procedure TPlcUI.FbdPaste;
var
  N, T: TNetwork;
  Map: array of TPoint;   // X old Id, Y new Id
  K, I, J, NewId, Base, Bot, Root, Pin, GroupH, Top: Integer;
  Nd: TFbdNode;
  BW, BH, IH: Single;

  function NewOf(Old: Integer): Integer;
  var
    Q: Integer;
  begin
    for Q := 0 to High(Map) do
      if Map[Q].X = Old then Exit(Map[Q].Y);
    Result := 0;
  end;

begin
  N := CurNet;
  if (N = nil) or not (N.Kind in [nkFBD, nkCFC]) then Exit;
  if Length(FFbdClip) = 0 then
  begin
    Toast('nothing copied: select boxes and Ctrl+C first', True);
    Exit;
  end;
  NewId := N.NewNodeId;
  SetLength(Map, Length(FFbdClip));
  for K := 0 to High(FFbdClip) do
  begin
    Map[K] := Point(FFbdClip[K].Id, NewId);
    Inc(NewId);
  end;
  // CFC from FBD: placed by the data flow, below the blocks there are
  T := nil;
  if (N.Kind = nkCFC) and not FFbdClipCfc then
  begin
    T := TNetwork.Create(nkCFC);
    T.Nodes := CopyNodes(FFbdClip);
    T.ChartW := 0;
    T.ChartH := 0;
    CfcAutoPlace(T);
  end;
  Bot := 0;
  for K := 0 to High(N.Nodes) do
  begin
    FbdBoxGeo(N.Nodes[K], BW, BH, IH);
    Bot := Max(Bot, N.Nodes[K].Y + Ceil(BH / CfcGrid));
  end;
  // the height of the copied group (CFC): from its top block to the bottom of its lowest one
  GroupH := 0;
  if Length(FFbdClip) > 0 then
  begin
    Top := FFbdClip[0].Y;
    for K := 0 to High(FFbdClip) do
    begin
      FbdBoxGeo(FFbdClip[K], BW, BH, IH);
      Top := Min(Top, FFbdClip[K].Y - Ceil(IH / CfcGrid));
      GroupH := Max(GroupH, FFbdClip[K].Y + Ceil(BH / CfcGrid));
    end;
    GroupH := GroupH - Top;
  end;
  Base := Length(N.Nodes);
  FFbdMulti := nil;
  for K := 0 to High(FFbdClip) do
  begin
    Nd := CopyOneNode(FFbdClip[K]);
    Nd.Id := Map[K].Y;
    for I := 0 to High(Nd.Ins) do
      if Nd.Ins[I].Src > 0 then Nd.Ins[I].Src := NewOf(Nd.Ins[I].Src);
    if N.Kind = nkCFC then
    begin
      if T <> nil then
      begin
        Nd.X := T.Nodes[K].X;
        Nd.Y := T.Nodes[K].Y + Bot + 2;
      end
      else
      begin
        // below the copied blocks (their height and 3 grid steps)
        Nd.X := FFbdClip[K].X;
        Nd.Y := FFbdClip[K].Y + GroupH + 3;
      end;
      Nd.Order := Base + K + 1;
      N.ChartW := Max(N.ChartW, Nd.X + 30);
      N.ChartH := Max(N.ChartH, Nd.Y + 4 + Max(Length(Nd.Ins), Length(Nd.Outs)) * 2 + 4);
    end;
    SetLength(N.Nodes, Length(N.Nodes) + 1);
    N.Nodes[High(N.Nodes)] := Nd;
    SetLength(FFbdMulti, Length(FFbdMulti) + 1);
    FFbdMulti[High(FFbdMulti)] := Nd.Id;
  end;
  T.Free;
  // FBD: one root with an output and an input pin selected: it feeds that pin
  if (N.Kind = nkFBD) and (FFbdNet = FNetSel) and (FFbdPin >= 0) and not FFbdPinOut then
  begin
    Root := 0;
    J := 0;
    for K := Base to High(N.Nodes) do
    begin
      I := 0;
      for Pin := Base to High(N.Nodes) do
        for J := 0 to High(N.Nodes[Pin].Ins) do
          if N.Nodes[Pin].Ins[J].Src = N.Nodes[K].Id then I := 1;
      if (I = 0) and (Length(N.Nodes[K].Outs) > 0) then
      begin
        if Root = 0 then Root := N.Nodes[K].Id else Root := -1;
      end;
    end;
    K := N.NodeIndex(FFbdNode);
    if (Root > 0) and (K >= 0) and (K < Base) and (FFbdPin <= High(N.Nodes[K].Ins)) then
    begin
      N.Nodes[K].Ins[FFbdPin].Src := Root;
      N.Nodes[K].Ins[FFbdPin].SrcPin := 0;
      N.Nodes[K].Ins[FFbdPin].Opnd := '';
    end;
  end;
  if N.Kind = nkCFC then CfcRenumber(N);
  FFbdNet := FNetSel;
  if Length(FFbdMulti) > 0 then FFbdNode := FFbdMulti[0];
  FFbdPin := -1;
  FFbdWire := False;
  FStlNet := -1;
  MarkDirty;
  Toast(Format('%d boxes pasted', [Length(FFbdClip)]));
end;

procedure TPlcUI.FbdSelectAll;
var
  N: TNetwork;
  K: Integer;
begin
  N := CurNet;
  if (N = nil) or not (N.Kind in [nkFBD, nkCFC]) then Exit;
  SetLength(FFbdMulti, Length(N.Nodes));
  for K := 0 to High(N.Nodes) do FFbdMulti[K] := N.Nodes[K].Id;
  FFbdNet := FNetSel;
  if Length(N.Nodes) > 0 then FFbdNode := N.Nodes[0].Id;
  FFbdPin := -1;
  FFbdWire := False;
end;

function TPlcUI.FbdHsText: string;
begin
  if (CurNet = nil) or not (CurNet.Kind in [nkFBD, nkCFC]) then Exit('');
  Result := Format('content %.0f px, view %d px, scrolled %.0f px', [FbdContentW(CurNet), FbdViewW, GetHS(CurNet)]);
end;

function TPlcUI.FbdMultiText: string;
var
  K: Integer;
begin
  Result := '';
  for K := 0 to High(FFbdMulti) do Result := Result + Format(' #%d', [FFbdMulti[K]]);
  Result := Trim(Result);
end;

{ the test: a box of the current FBD / CFC network as text; a hit region by its kind (the pixel) }
function TPlcUI.FbdText: string;
var
  N: TNetwork;
  K, I: Integer;
  S: string;
begin
  Result := '';
  N := CurNet;
  if (N = nil) or not (N.Kind in [nkFBD, nkCFC]) then Exit;
  for K := 0 to High(N.Nodes) do
  begin
    S := Format('#%d %s', [N.Nodes[K].Id, N.Nodes[K].Box]);
    if N.Nodes[K].Inst <> '' then S := S + ' [' + N.Nodes[K].Inst + ']';
    if N.Kind = nkCFC then S := S + Format(' @%d,%d order %d', [N.Nodes[K].X, N.Nodes[K].Y, N.Nodes[K].Order]);
    for I := 0 to High(N.Nodes[K].Ins) do
      if N.Nodes[K].Ins[I].Src > 0 then S := S + Format(' %s<-#%d', [N.Nodes[K].Ins[I].Name, N.Nodes[K].Ins[I].Src])
      else if N.Nodes[K].Ins[I].Opnd <> '' then
        S := S + Format(' %s=%s%s', [N.Nodes[K].Ins[I].Name, IfThen(N.Nodes[K].Ins[I].Neg, 'NOT ', ''), N.Nodes[K].Ins[I].Opnd]);
    for I := 0 to High(N.Nodes[K].Outs) do
      if N.Nodes[K].Outs[I].Opnd <> '' then S := S + Format(' %s->%s', [N.Nodes[K].Outs[I].Name, N.Nodes[K].Outs[I].Opnd]);
    Result := Result + S + LineEnding;
  end;
end;

procedure TPlcUI.TestFbdIns(const Id, Blk: string);
begin
  FbdInsert(Id, Blk, -1, -1);
end;

procedure TPlcUI.TestNetTop;
var
  K: Integer;
  Y: Single;
begin
  if CurBlock = nil then Exit;
  Y := IfaceHeight(CurBlock);
  for K := 0 to Min(FNetSel, CurBlock.NetCount) - 1 do Y := Y + NetHeight(CurBlock.Net(K));
  FProgScroll := Y;
  FScrollToCaret := False;
end;

procedure TPlcUI.TestFbdCtx(Par: Integer);
begin
  FbdCtx(Par);
end;

function TPlcUI.TestMsgs: string;
var
  K: Integer;
begin
  Result := Format('%d errors:', [FMsgErrors]);
  for K := 0 to High(FMsgs) do Result := Result + Format(' [nw %d: %s]', [FMsgs[K].Net, FMsgs[K].Text]);
end;

procedure TPlcUI.TestFbdOp(const S: string);
begin
  FbdPutOperand(S);
end;

function TPlcUI.FbdHitPoint(Node, Pin, Kind: Integer): TPointF;
var
  K: Integer;
begin
  Result := PointF(-1, -1);
  for K := 0 to High(FFbdHits) do
    if (FFbdHits[K].NI = FNetSel) and (FFbdHits[K].Node = Node) and (FFbdHits[K].Pin = Pin) and (FFbdHits[K].Kind = Kind) then
      with FFbdHits[K].R do
        Exit(DesignToPixel((Left + Right) / 2, (Top + Bottom) / 2));
end;

procedure TPlcUI.FbdTestSelect(Node, Pin: Integer; IsOut: Boolean);
begin
  // as a click on it: the keys go to the boxes, the box alone is selected
  FHelpFocus := False;
  FStlNet := -1;
  if Node > 0 then
  begin
    SetLength(FFbdMulti, 1);
    FFbdMulti[0] := Node;
  end
  else FFbdMulti := nil;
  FFbdNet := FNetSel;
  FFbdNode := Node;
  FFbdPin := Pin;
  FFbdPinOut := IsOut;
  FFbdWire := False;
end;
