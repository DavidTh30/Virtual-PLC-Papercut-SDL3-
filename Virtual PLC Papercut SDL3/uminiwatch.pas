unit uMiniWatch;

{ The Mini Watch: a small window of its own (a second SDL window, see uSDLView) that shows the values of a few
  variables beside any screen of the main window, or beside another program. Its rows are kept in the project
  (TPlcProject.MiniWatch: the address or symbol and the format).

  Columns: Symbol, Address (absolute; an optimized DB has none), Format (a click: the next one, Shift+click the
  one before), Value. A struct / array row opens with its mark to its members / elements (as the watch table,
  TPlcUI.WatchTree). A row is added with the field at the bottom (a symbol "Motor", "DB".Var, "DB".Arr[2],
  %MW10 ..) or from the main window (the right button on a variable: Add to Mini Watch). The right button on a
  row: Cross reference (in the main window), Remove; Del removes the selected row. On top keeps the window
  over the others. Like the chat window, one design unit is one point of the window. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, StrUtils, Types, BGRABitmap, BGRABitmapTypes, uPaperDL, uUiBase, uPlcTypes,
  uPlcProject, uPlcRuntime, uUI;

type

  { TMiniWatchUI }

  TMiniWatchUI = class(TUiBase)
  private
    FDW, FDH: Single;          // the window in design units
    FDensity: Single;
    FScroll: Single;
    FSel: Integer;             // the selected row of the project's MiniWatch (-1 none)
    FRows: TWTreeRows;
    FOpen: TStringList;        // the struct / array rows opened (their keys)
    FMenu: Boolean;
    FMenuX, FMenuY: Single;
    FMenuRow: Integer;         // into FRows
    FAddText: string;
    FDragPress: Integer;       // the press that the drag of a row belongs to
    FDragX0, FDragY0: Single;
    FDragRow: Integer;         // into FRows
    procedure MakeRows;
    function RowAddr(const R: TWTreeRow): string;
    procedure DrawMenu;
  protected
    procedure DoClick(Id: Integer; const S: string); override;
    procedure DoWheel(Id: Integer; DY: Single); override;
    procedure DoDrag(Id: Integer; X, Y: Single; const R: TRectF); override;
    procedure DoDragEnd(Id: Integer; X, Y: Single); override;
    procedure DoRightClick(Id: Integer); override;
    procedure DoKey(Key: TUiKey; Ch: Char; Mods: TUiMods); override;
    procedure CommitEdit(Id: Integer; const S: string); override;
  public
    UI: TPlcUI;
    OnTop: Boolean;            // the window stays over the others (the view applies it)
    Dragging: Boolean;         // a row is dragged (DragText): the view drops it on the main window
    DragText: string;
    DropHover: Boolean;        // the main window drags a variable over this window (set by the view)
    DragOut: Boolean;          // the drag of a row is over the main window (set by the view)
    constructor Create(AGlyphs: TGlyphCache; AUI: TPlcUI);
    destructor Destroy; override;
    procedure SetDensity(V: Single);
    procedure SetSize(AW, AH: Integer); override;
    procedure Update(DT: Double);
    procedure Build(DL: TDisplayList);
    { for the tests: the rows as text; a row opened by its key; a click on a region }
    function RowsText: string;
    procedure TestOpen(const Key: string);
    function HitCenter(Id: Integer): TPointF;
  end;

const
  { the regions of the window }
  mwBg = 1; mwAdd = 2; mwOnTop = 3; mwMenuClose = 4; mwXref = 5; mwRemove = 6; mwClear = 7; mwWheel = 8;
  mwRow = $10000;              // + the row shown
  mwOpen = $20000;             // + the row shown: its open mark
  mwFmt = $30000;              // + the row of the MiniWatch: its format
  mwAddField = $40000;

implementation

const
  RowH = 24;

constructor TMiniWatchUI.Create(AGlyphs: TGlyphCache; AUI: TPlcUI);
begin
  inherited Create(AGlyphs);
  UI := AUI;
  FDensity := 1;
  FSel := -1;
  FOpen := TStringList.Create;
  FOpen.CaseSensitive := False;
end;

destructor TMiniWatchUI.Destroy;
begin
  FOpen.Free;
  inherited Destroy;
end;

procedure TMiniWatchUI.SetDensity(V: Single);
begin
  if V < 0.5 then V := 1;
  if Abs(V - FDensity) > 0.01 then
  begin
    FDensity := V;
    SetSize(FW, FH);
  end;
end;

procedure TMiniWatchUI.SetSize(AW, AH: Integer);
begin
  FW := Max(16, AW);
  FH := Max(16, AH);
  FK := FDensity;
  FOX := 0;
  FOY := 0;
  FDW := FW / FK;
  FDH := FH / FK;
end;

procedure TMiniWatchUI.Update(DT: Double);
begin
  FTime := FTime + DT;
end;

procedure TMiniWatchUI.MakeRows;
var
  A: array of string;
  W: array of Integer;
  J: Integer;
begin
  SetLength(A, Length(UI.Project.MiniWatch));
  SetLength(W, Length(A));
  for J := 0 to High(A) do
  begin
    A[J] := UI.Project.MiniWatch[J].Address;
    W[J] := J;
  end;
  UI.WatchTree(A, W, FOpen, FRows);
end;

{ the address (and path) of a row shown }
function TMiniWatchUI.RowAddr(const R: TWTreeRow): string;
begin
  if (R.WI < 0) or (R.WI > High(UI.Project.MiniWatch)) then Exit('');
  Result := Trim(UI.Project.MiniWatch[R.WI].Address) + R.Path;
end;

procedure TMiniWatchUI.Build(DL: TDisplayList);
var
  I, J, N, Vis, K: Integer;
  Y, X1, X2, X3, X4, XS, Top, ListH: Single;
  R: TWTreeRow;
  S, Adr, V: string;
  C: TBGRAPixel;
begin
  BeginFrame(DL);
  try
    D.Layer := lySheets;
    Rc(0, 0, FDW, FDH, cSheet);
    Hit(0, 0, FDW, FDH, mwBg);
    // the head
    D.Layer := lyControls;
    Rc(0, 0, FDW, 34, Mixc(cRed, cRedDark, 0.3));
    FretStrip(0, 34, FDW, 6, cGoldLight, cRedDark);
    D.Layer := lyText;
    Txt(fkUIB, 13.5, 12, 8, 'Mini Watch', cSheet);
    if UI.Rt.Mode = rmRun then S := 'RUN' else S := 'STOP';
    TxtFit(fkUI, 10.5, 104, 11, Max(10, FDW - 104 - 92), Format('%s   %d rows   %s', [S,
      Length(UI.Project.MiniWatch), UI.Project.Name]), cGoldLight);
    if OnTop then Button(FDW - 84, 6, 74, 22, 'On top', mwOnTop, bsToggleOn, True, 10.5)
    else Button(FDW - 84, 6, 74, 22, 'On top', mwOnTop, bsGold, True, 10.5);
    // the columns: Symbol, Address, Format, Value
    X1 := 10;
    X2 := 10 + (FDW - 20) * 0.34;
    X3 := 10 + (FDW - 20) * 0.58;
    X4 := X3 + 66;
    D.Layer := lyText;
    Txt(fkUIB, 10.5, X1 + 14, 46, 'Symbol', cInkSoft);
    Txt(fkUIB, 10.5, X2, 46, 'Address', cInkSoft);
    Txt(fkUIB, 10.5, X3, 46, 'Format', cInkSoft);
    Txt(fkUIB, 10.5, X4, 46, 'Value', cInkSoft);
    D.Layer := lyOrnament;
    Ln(8, 63, FDW - 8, 63, 0.8, Alpha(cGoldDark, 160));
    MakeRows;
    N := Length(FRows);
    Top := 66;
    ListH := Max(RowH, FDH - Top - 40);
    Vis := Max(1, Trunc(ListH / RowH));
    FScroll := EnsureRange(FScroll, 0, Max(0, N - Vis));
    ClipD(4, Top, FDW - 8, ListH);
    Hit(4, Top, FDW - 8, ListH, mwWheel, hkWheel);
    for J := 0 to Vis do
    begin
      I := J + Round(FScroll);
      if I >= N then Break;
      R := FRows[I];
      Y := Top + J * RowH;
      Adr := RowAddr(R);
      D.Layer := lyControls;
      if not R.Sub and (R.WI = FSel) then RR(6, Y, FDW - 12, RowH - 2, 4, Alpha(cGold, 80))
      else if R.Sub then Rc(6, Y, FDW - 12, RowH - 2, Alpha(cGoldLight, IfThen(Odd(J), 55, 30)))
      else if Odd(J) then Rc(6, Y, FDW - 12, RowH - 2, Alpha(cSheet2, 130));
      Hit(6, Y, FDW - 12, RowH - 2, mwRow + I, hkDrag);
      XS := X1 + 14 + R.Depth * 12;
      for K := 1 to R.Depth do Rc(X1 + 14 + (K - 1) * 12, Y, 2, RowH - 2, Alpha(cGoldDark, 120));
      if R.CanOpen then
      begin
        if FOpen.IndexOf(R.Key) >= 0 then
          PolyD([PointF(XS - 12, Y + 8), PointF(XS - 3, Y + 8), PointF(XS - 7.5, Y + 14)], cRedDark)
        else
          PolyD([PointF(XS - 10, Y + 6), PointF(XS - 5, Y + 11), PointF(XS - 10, Y + 16)], cRedDark);
        Hit(XS - 14, Y, 14, RowH - 2, mwOpen + I);
      end;
      D.Layer := lyText;
      if R.Sub then S := R.Lbl else S := UI.MiniSymbol(Adr);
      if R.Sub then C := cInkSoft else C := cInk;
      TxtFit(fkMono, 11, XS, Y + 4, X2 - XS - 6, S, C);
      TxtFit(fkMono, 10.5, X2, Y + 5, X3 - X2 - 6, UI.MiniAbs(R, Adr), cInkSoft);
      if not R.Sub and not R.CanOpen then
        Button(X3, Y + 1, 60, 20, DispFmtNames[UI.Project.MiniWatch[R.WI].Fmt], mwFmt + R.WI, bsGold, True, 9.5)
      else
        TxtFit(fkMono, 9.5, X3 + 2, Y + 5, 62, R.TypeText, cInkFaint);
      if R.Sub then V := UI.MiniValue(R, Adr, dfDec)
      else V := UI.MiniValue(R, Adr, UI.Project.MiniWatch[R.WI].Fmt);
      if V = 'TRUE' then C := cRed
      else if V = '?' then C := cRed
      else C := cInk;
      TxtFit(fkMonoB, 11.5, X4, Y + 4, FDW - X4 - 10, V, C);
    end;
    UnclipD;
    D.Layer := lyText;
    if N = 0 then
    begin
      TxtFit(fkUI, 11, 14, Top + 8, FDW - 28, 'No row yet: type a symbol or an address below,', cInkSoft);
      TxtFit(fkUI, 11, 14, Top + 26, FDW - 28, 'or in the main window: the right button on a variable,', cInkSoft);
      TxtFit(fkUI, 11, 14, Top + 44, FDW - 28, 'Add to Mini Watch.', cInkSoft);
    end;
    if N > Vis then
    begin
      // where the list is
      D.Layer := lyControls;
      Rc(FDW - 6, Top, 3, ListH, Alpha(cGoldDark, 50));
      Rc(FDW - 6, Top + ListH * FScroll / N, 3, Max(12, ListH * Vis / N), cRed);
    end;
    // the field that adds a row
    D.Layer := lyControls;
    Rc(0, FDH - 36, FDW, 36, cSheet2);
    Field(8, FDH - 30, FDW - 96, 24, mwAddField, FAddText, fkMono, 11.5, 0, True,
      'add: "Motor", "DB".Var, "DB".Arr[2], %MW10 .. Enter');
    Button(FDW - 82, FDH - 30, 74, 24, '+ Add', mwAdd, bsPrimary, True, 11);
    if Dragging and not DragOut then
    begin
      // a row dragged inside the window: where it goes (a row of the Mini Watch moves)
      D.Layer := lyOverlay;
      K := EnsureRange(Round((FMY - Top) / RowH), 0, N);
      Rc(8, Top + K * RowH - 2, FDW - 16, 3, cRed);
    end;
    if Dragging then
    begin
      D.Layer := lyOverlay;
      S := DragText;
      if DragOut then S := S + '  -> the main window';
      Shad(FMX + 12, FMY + 8, TxtW(fkMonoB, 11, S) + 14, 22, 4, 2, 4, 80);
      RR(FMX + 12, FMY + 8, TxtW(fkMonoB, 11, S) + 14, 22, 4, cRed);
      Txt(fkMonoB, 11, FMX + 19, FMY + 11, S, cSheet);
    end;
    if DropHover then
    begin
      // the main window drags a variable here: a drop adds it
      D.Layer := lyOverlay;
      Rc(0, 0, FDW, FDH, Alpha(cGold, 40));
      RRL(3, 3, FDW - 6, FDH - 6, 6, 3, cRed);
      RR(FDW / 2 - 120, FDH / 2 - 18, 240, 36, 6, cRed);
      Txt(fkUIB, 12.5, FDW / 2, FDH / 2 - 9, 'Drop: add to the Mini Watch', cSheet, 1);
    end;
    DrawMenu;
  finally
    EndFrame;
  end;
end;

procedure TMiniWatchUI.DrawMenu;
const
  Names: array[0..2] of string = ('Cross reference', 'Remove row', 'Remove all rows');
  Ids: array[0..2] of Integer = (mwXref, mwRemove, mwClear);
var
  X, Y, W, IY: Single;
  I: Integer;
  Hov, On: Boolean;
begin
  if not FMenu then Exit;
  W := 180;
  X := Min(FMenuX, FDW - W - 6);
  Y := Min(FMenuY, FDH - 3 * 28 - 14);
  Hit(-100, -100, FDW + 200, FDH + 200, mwMenuClose);
  D.Layer := lyOverlay;
  Shad(X, Y, W, 3 * 28 + 8, 5, 3, 6, 110);
  RR(X, Y, W, 3 * 28 + 8, 5, cSheet);
  RRL(X, Y, W, 3 * 28 + 8, 5, 1.3, cGoldDark);
  for I := 0 to 2 do
  begin
    IY := Y + 4 + I * 28;
    On := (I = 2) or ((FMenuRow >= 0) and (FMenuRow <= High(FRows)));
    Hov := On and Hot(X + 4, IY, W - 8, 26);
    if Hov then RR(X + 4, IY, W - 8, 26, 4, cRed);
    if not On then Txt(fkUI, 12, X + 14, IY + 4, Names[I], cInkFaint)
    else if Hov then Txt(fkUI, 12, X + 14, IY + 4, Names[I], cSheet)
    else Txt(fkUI, 12, X + 14, IY + 4, Names[I], cInk);
    if On then Hit(X + 4, IY, W - 8, 26, Ids[I]);
  end;
end;

procedure TMiniWatchUI.DoClick(Id: Integer; const S: string);
var
  K: Integer;
  F: TDispFmt;
begin
  if Id <> mwMenuClose then
    if FMenu and (Id <> mwXref) and (Id <> mwRemove) and (Id <> mwClear) then
    begin
      FMenu := False;
      Exit;
    end;
  case Id of
    mwMenuClose: FMenu := False;
    mwOnTop: OnTop := not OnTop;
    mwAdd:
      begin
        EndEdit(True);
        CommitEdit(mwAddField, FAddText);
      end;
    mwXref:
      begin
        FMenu := False;
        if (FMenuRow >= 0) and (FMenuRow <= High(FRows)) then UI.MiniXref(RowAddr(FRows[FMenuRow]));
      end;
    mwRemove:
      begin
        FMenu := False;
        if (FMenuRow >= 0) and (FMenuRow <= High(FRows)) then UI.MiniRemove(FRows[FMenuRow].WI);
        FSel := -1;
      end;
    mwClear:
      begin
        FMenu := False;
        while Length(UI.Project.MiniWatch) > 0 do UI.MiniRemove(0);
        FSel := -1;
      end;
  else
    if (Id >= mwRow) and (Id < mwOpen) then
    begin
      K := Id - mwRow;
      if K <= High(FRows) then FSel := FRows[K].WI;
    end
    else if (Id >= mwOpen) and (Id < mwFmt) then
    begin
      K := Id - mwOpen;
      if K <= High(FRows) then
        if FOpen.IndexOf(FRows[K].Key) >= 0 then FOpen.Delete(FOpen.IndexOf(FRows[K].Key))
        else FOpen.Add(FRows[K].Key);
    end
    else if (Id >= mwFmt) and (Id < mwAddField) then
    begin
      K := Id - mwFmt;
      if K <= High(UI.Project.MiniWatch) then
      begin
        F := UI.Project.MiniWatch[K].Fmt;
        if umShift in MouseMods then
        begin
          if F = Low(TDispFmt) then F := High(TDispFmt) else F := Pred(F);
        end
        else if F = High(TDispFmt) then F := Low(TDispFmt)
        else F := Succ(F);
        UI.Project.MiniWatch[K].Fmt := F;
        UI.Project.Modified := True;
        FSel := K;
      end;
    end;
  end;
end;

{ a row: a press selects it, a drag takes it (to the main window: the view drops it there; inside: the row moves) }
procedure TMiniWatchUI.DoDrag(Id: Integer; X, Y: Single; const R: TRectF);
var
  K: Integer;
begin
  if (Id < mwRow) or (Id >= mwOpen) then Exit;
  K := Id - mwRow;
  if FDragPress <> FPressNo then
  begin
    FDragPress := FPressNo;
    Dragging := False;
    FDragRow := K;
    FDragX0 := X;
    FDragY0 := Y;
    FMenu := False;
    if K <= High(FRows) then FSel := FRows[K].WI;
    Exit;
  end;
  if not Dragging and (Abs(X - FDragX0) + Abs(Y - FDragY0) < 6) then Exit;
  if (FDragRow < 0) or (FDragRow > High(FRows)) then Exit;
  DragText := RowAddr(FRows[FDragRow]);
  Dragging := DragText <> '';
end;

procedure TMiniWatchUI.DoDragEnd(Id: Integer; X, Y: Single);
var
  K, From, N: Integer;
  T: TWatchRow;
begin
  if Dragging and not DragOut and (FDragRow >= 0) and (FDragRow <= High(FRows)) and not FRows[FDragRow].Sub then
  begin
    // inside the window: the row moves before the row under the mouse
    N := Length(FRows);
    K := EnsureRange(Round((Y - 66) / RowH) + Round(FScroll), 0, N);
    From := FRows[FDragRow].WI;
    if K >= N then K := Length(UI.Project.MiniWatch) else K := FRows[K].WI;
    if (K <> From) and (K <> From + 1) then
    begin
      T := UI.Project.MiniWatch[From];
      UI.MiniRemove(From);
      if K > From then Dec(K);
      Insert(T, UI.Project.MiniWatch, K);
      UI.Project.Modified := True;
      FSel := K;
    end;
  end;
  Dragging := False;
  DragOut := False;
end;

procedure TMiniWatchUI.DoWheel(Id: Integer; DY: Single);
begin
  FScroll := Max(0, FScroll - DY * 2);
end;

procedure TMiniWatchUI.DoRightClick(Id: Integer);
var
  K: Integer;
begin
  FMenuRow := -1;
  if (Id >= mwRow) and (Id < mwFmt) then
  begin
    FMenuRow := (Id and $FFFF);
    if FMenuRow <= High(FRows) then FSel := FRows[FMenuRow].WI;
  end
  else if (Id >= mwFmt) and (Id < mwAddField) then
  begin
    // the format button of a row: the menu of that row
    for K := 0 to High(FRows) do
      if not FRows[K].Sub and (FRows[K].WI = Id - mwFmt) then
      begin
        FMenuRow := K;
        Break;
      end;
  end;
  FMenu := True;
  FMenuX := FMX;
  FMenuY := FMY;
end;

procedure TMiniWatchUI.DoKey(Key: TUiKey; Ch: Char; Mods: TUiMods);
begin
  if (Key = ukEsc) and FMenu then FMenu := False
  else if (Key = ukDel) and (FSel >= 0) and (FSel <= High(UI.Project.MiniWatch)) then
  begin
    UI.MiniRemove(FSel);
    FSel := Min(FSel, High(UI.Project.MiniWatch));
  end
  else if (Key = ukUp) and (FSel > 0) then Dec(FSel)
  else if (Key = ukDown) and (FSel < High(UI.Project.MiniWatch)) then Inc(FSel)
  else if (Key = ukChar) and not (umCtrl in Mods) and (Ch > ' ') then
  begin
    // typing starts the add field
    StartEdit(mwAddField, FAddText);
    TextInput(Ch);
  end;
end;

procedure TMiniWatchUI.CommitEdit(Id: Integer; const S: string);
begin
  if Id <> mwAddField then Exit;
  FAddText := '';
  if Trim(S) = '' then Exit;
  UI.MiniAdd(Trim(S));
  FSel := High(UI.Project.MiniWatch);
  FScroll := 1E6;
end;

function TMiniWatchUI.RowsText: string;
var
  I: Integer;
  Adr, F: string;
  Fm: TDispFmt;
begin
  MakeRows;
  Result := '';
  for I := 0 to High(FRows) do
  begin
    Adr := RowAddr(FRows[I]);
    Fm := dfDec;
    if FRows[I].Sub or FRows[I].CanOpen then F := FRows[I].TypeText
    else
    begin
      Fm := UI.Project.MiniWatch[FRows[I].WI].Fmt;
      F := DispFmtNames[Fm];
    end;
    Result := Result + StringOfChar(' ', FRows[I].Depth * 2) + IfThen(FRows[I].Sub, FRows[I].Lbl, UI.MiniSymbol(Adr)) +
      ' | ' + UI.MiniAbs(FRows[I], Adr) + ' | ' + F + ' | ' +
      UI.MiniValue(FRows[I], Adr, Fm) + LineEnding;
  end;
end;

procedure TMiniWatchUI.TestOpen(const Key: string);
begin
  if FOpen.IndexOf(UpperCase(Key)) < 0 then FOpen.Add(UpperCase(Key));
end;

function TMiniWatchUI.HitCenter(Id: Integer): TPointF;
var
  K: Integer;
begin
  Result := PointF(-1, -1);
  for K := FLastHitN - 1 downto 0 do
    if FLastHits[K].Id = Id then
      with FLastHits[K].R do Exit(PointF(PX((Left + Right) / 2), PY((Top + Bottom) / 2)));
end;

end.
