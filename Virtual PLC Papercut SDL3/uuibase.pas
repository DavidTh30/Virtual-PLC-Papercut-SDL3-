unit uUiBase;

{ Immediate mode papercut UI on top of the display lists.

  The whole UI is laid out in design units of a 1600 x 900 screen; K, OX, OY
  map them to frame pixels (letterboxed, centred). Every frame the screen is
  built again: widgets draw into the display list and register hit regions.
  Mouse and key events are matched against the regions of the last frame.

  Paper look: cream sheets (#F6EEDE) stacked with soft offset shadows, red
  (#B22822) and gold (#DEAA32) accents, Chinese key fret (hui wen) strips and
  corner motifs on the cards, paper grain added by the renderer. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, Types, BGRABitmap, BGRABitmapTypes, LazUTF8, uPaperDL;

type
  TFontKind = (fkUI, fkUIB, fkMono, fkMonoB, fkTitle);
  THitKind = (hkClick, hkPress, hkDrag, hkField, hkWheel);
  TBtnStyle = (bsNormal, bsPrimary, bsToggleOn, bsFlat, bsDanger, bsGold);
  TUiKey = (ukNone, ukEnter, ukEsc, ukBack, ukDel, ukLeft, ukRight, ukUp, ukDown, ukHome, ukEnd,
    ukPgUp, ukPgDn, ukTab, ukInsert, ukF1, ukF2, ukF3, ukF4, ukF5, ukF6, ukF7, ukF8, ukF9, ukF10,
    ukF11, ukF12, ukChar);
  TUiMod = (umShift, umCtrl, umAlt);
  TUiMods = set of TUiMod;

  THit = record
    R: TRectF;
    Id: Integer;
    Kind: THitKind;
    S: string;
    FontK: TFontKind;   // a field: its font, for the caret under the mouse
    FontS: Single;
  end;

const
  DesignW = 1600;
  DesignH = 900;

var
  { palette }
  cPaper, cSheet, cSheet2, cSheetDark, cInk, cInkSoft, cInkFaint, cRed, cRedDark, cRedLight, cGold,
  cGoldDark, cGoldLight, cJade, cJadeLight, cAmber, cCharcoal, cCharcoal2, cWhite, cShadow: TBGRAPixel;

type

  { TUiBase }

  TUiBase = class
  protected
    FGl: TGlyphCache;
    D: TDisplayList;
    FK, FOX, FOY: Single;
    FW, FH: Integer;
    FHits, FLastHits: array of THit;
    FHitN, FLastHitN: Integer;
    FMX, FMY: Single;
    FMouseIn: Boolean;
    FDownId, FDragId, FPressId: Integer;
    FPressNo: Integer;     // counts the mouse presses (a drag knows its own press)
    FTime: Double;
    FEditId: Integer;
    FEditText: string;
    FEditCaret: Integer;
    FEditOrig: string;
    { the field being edited as a text box: the selection runs from the anchor to the caret }
    FEditAnchor: Integer;
    FEditTX: Single;           // where its text starts (scrolled with the caret)
    FEditKind: TFontKind;
    FEditSize: Single;
    FEditDragging: Boolean;
    FEditTyping: Boolean;      // typing goes into one undo step
    FEditUndo, FEditRedo: array of record T: string; C, A: Integer; end;
    { the clip rectangles (design units): a region outside them takes no mouse }
    FClipStack: array of TRectF;
    FClipN: Integer;
    FBuilding: Boolean;
    procedure EditPush;
    procedure EditSel(out A, B: Integer);
    function EditHasSel: Boolean;
    procedure EditDeleteSel;
    function EditCaretAt(X: Single): Integer;
    function EditWordStart(P: Integer): Integer;
    function EditWordEnd(P: Integer): Integer;
    function PX(X: Single): Single; inline;
    function PY(Y: Single): Single; inline;
    function PS(V: Single): Single; inline;
    function Fnt(Kind: TFontKind; Size: Single): Integer;
    procedure Hit(X, Y, W, H: Single; Id: Integer; Kind: THitKind = hkClick; const S: string = '');
    function Hot(X, Y, W, H: Single): Boolean;
    function HitAt(X, Y: Single; out H: THit): Boolean;
    { primitives in design units }
    procedure Rc(X, Y, W, H: Single; C: TBGRAPixel);
    procedure ImgD(X, Y, W, H: Single; B: TBGRABitmap);
    procedure RR(X, Y, W, H, R: Single; C: TBGRAPixel);
    procedure RRL(X, Y, W, H, R, LW: Single; C: TBGRAPixel);
    procedure El(CX, CY, RX, RY: Single; C: TBGRAPixel);
    procedure ElL(CX, CY, RX, RY, LW: Single; C: TBGRAPixel);
    procedure Ln(X1, Y1, X2, Y2, LW: Single; C: TBGRAPixel);
    procedure DashLn(X1, Y1, X2, Y2, LW, Dash: Single; C: TBGRAPixel);
    procedure PolyD(const P: array of TPointF; C: TBGRAPixel);
    procedure PolyLineD(const P: array of TPointF; LW: Single; C: TBGRAPixel);
    procedure Shad(X, Y, W, H, R, Off, Blur: Single; Alpha: Integer = 70);
    procedure GlowD(CX, CY, R: Single; C: TBGRAPixel);
    procedure VGradD(X, Y, W, H: Single; C1, C2: TBGRAPixel);
    procedure Txt(Kind: TFontKind; Size, X, Y: Single; const S: string; C: TBGRAPixel; Align: Integer = 0);
    procedure TxtFit(Kind: TFontKind; Size, X, Y, MaxW: Single; const S: string; C: TBGRAPixel; Align: Integer = 0);
    function TxtW(Kind: TFontKind; Size: Single; const S: string): Single;
    procedure ClipD(X, Y, W, H: Single);
    procedure UnclipD;
    { papercut pieces }
    procedure Sheet(X, Y, W, H, R: Single; C: TBGRAPixel; Depth: Single = 1);
    procedure HuiWen(X, Y, Sz, LW: Single; C: TBGRAPixel);
    procedure FretStrip(X, Y, W, H: Single; C, Bg: TBGRAPixel);
    procedure CornerFret(X, Y, Sz: Single; DirX, DirY: Integer; C: TBGRAPixel);
    procedure Card(X, Y, W, H: Single; const Title: string; Fancy: Boolean = True);
    procedure CloudMotif(CX, CY, Sz: Single; C: TBGRAPixel);
    procedure Seal(X, Y, Sz: Single; const S: string);
    procedure AppLogo(X, Y, Sz: Single; RunOn: Boolean = True);
    { widgets }
    function Button(X, Y, W, H: Single; const Caption: string; Id: Integer; Style: TBtnStyle = bsNormal;
      Enabled: Boolean = True; Size: Single = 13): Boolean;
    procedure Field(X, Y, W, H: Single; Id: Integer; const Value: string; Kind: TFontKind = fkUI;
      Size: Single = 13; Align: Integer = 0; Enabled: Boolean = True; const Placeholder: string = '');
    procedure Led(CX, CY, R: Single; C: TBGRAPixel; On: Boolean);
    procedure Lamp(CX, CY, R: Single; C: TBGRAPixel; On: Boolean);
    procedure Switch(X, Y, W, H: Single; On: Boolean; Id: Integer; Kind: THitKind = hkClick);
    procedure Check(X, Y, Sz: Single; On: Boolean; Id: Integer);
    procedure ProgressBar(X, Y, W, H, Frac: Single; C: TBGRAPixel);
    { events for the screens }
    procedure DoClick(Id: Integer; const S: string); virtual;
    procedure DoPress(Id: Integer; Down: Boolean); virtual;
    procedure DoDrag(Id: Integer; X, Y: Single; const R: TRectF); virtual;
    procedure DoDragEnd(Id: Integer; X, Y: Single); virtual;   // the mouse button went up after a drag
    procedure DoRightClick(Id: Integer); virtual;               // the right button on a region (-1: none)
    procedure DoWheel(Id: Integer; DY: Single); virtual;
    procedure DoKey(Key: TUiKey; Ch: Char; Mods: TUiMods); virtual;
    procedure DoText(const S: string); virtual;
    procedure CommitEdit(Id: Integer; const S: string); virtual;
    procedure EditKey(Key: TUiKey; Ch: Char; Mods: TUiMods);
    procedure BeginFrame(ADL: TDisplayList);
    procedure EndFrame;
  public
    Clipboard: string;     // set by the view from SDL
    ClipboardOut: string;  // text the view should copy
    MouseClicks: Integer;  // 1 click, 2 double, 3 triple (set by the view before MouseDown)
    MaskId: Integer;       // the field with this id shows * for its text (a secret)
    MouseMods: TUiMods;    // Shift / Ctrl / Alt held at the mouse press
    WheelShift: Boolean;   // the wheel scrolls sideways (Shift held, or a horizontal wheel)
    constructor Create(AGlyphs: TGlyphCache);
    procedure SetSize(AW, AH: Integer); virtual;
    procedure MouseMove(X, Y: Single);
    procedure MouseDown(X, Y: Single);
    procedure MouseUp(X, Y: Single);
    procedure MouseRightDown(X, Y: Single);
    procedure Wheel(DY: Single);
    procedure KeyDown(Key: TUiKey; Ch: Char; Mods: TUiMods); virtual;
    procedure TextInput(const S: string);
    procedure StartEdit(Id: Integer; const Value: string);
    procedure EndEdit(Commit: Boolean);
    function Editing: Boolean;
    function DesignToPixel(X, Y: Single): TPointF;
    property Scale: Single read FK;
    property Time: Double read FTime write FTime;
    property Glyphs: TGlyphCache read FGl;
  end;

function Mixc(A, B: TBGRAPixel; T: Single): TBGRAPixel;
function Alpha(C: TBGRAPixel; A: Integer): TBGRAPixel;
function Darker(C: TBGRAPixel; F: Single): TBGRAPixel;

const
  FontFaces: array[TFontKind] of string = ('Segoe UI', 'Segoe UI', 'Consolas', 'Consolas', 'Palatino Linotype');
  FontBold: array[TFontKind] of Boolean = (False, True, False, True, True);

implementation

function Mixc(A, B: TBGRAPixel; T: Single): TBGRAPixel;
begin
  T := EnsureRange(T, 0, 1);
  Result.red := Round(A.red + (B.red - A.red) * T);
  Result.green := Round(A.green + (B.green - A.green) * T);
  Result.blue := Round(A.blue + (B.blue - A.blue) * T);
  Result.alpha := Round(A.alpha + (B.alpha - A.alpha) * T);
end;

function Alpha(C: TBGRAPixel; A: Integer): TBGRAPixel;
begin
  Result := C;
  Result.alpha := EnsureRange(A, 0, 255);
end;

function Darker(C: TBGRAPixel; F: Single): TBGRAPixel;
begin
  Result.red := EnsureRange(Round(C.red * F), 0, 255);
  Result.green := EnsureRange(Round(C.green * F), 0, 255);
  Result.blue := EnsureRange(Round(C.blue * F), 0, 255);
  Result.alpha := C.alpha;
end;

{ TUiBase }

constructor TUiBase.Create(AGlyphs: TGlyphCache);
begin
  inherited Create;
  FGl := AGlyphs;
  FEditId := -1;
  MaskId := -1;
  FDownId := -1;
  FDragId := -1;
  FPressId := -1;
  SetLength(FHits, 256);
  SetLength(FLastHits, 256);
  SetSize(1280, 720);
end;

procedure TUiBase.SetSize(AW, AH: Integer);
begin
  FW := Max(16, AW);
  FH := Max(16, AH);
  FK := Min(FW / DesignW, FH / DesignH);
  FOX := (FW - DesignW * FK) / 2;
  FOY := (FH - DesignH * FK) / 2;
end;

function TUiBase.DesignToPixel(X, Y: Single): TPointF;
begin
  Result := PointF(PX(X), PY(Y));
end;

function TUiBase.PX(X: Single): Single;
begin
  Result := FOX + X * FK;
end;

function TUiBase.PY(Y: Single): Single;
begin
  Result := FOY + Y * FK;
end;

function TUiBase.PS(V: Single): Single;
begin
  Result := V * FK;
end;

function TUiBase.Fnt(Kind: TFontKind; Size: Single): Integer;
begin
  Result := FGl.Get(FontFaces[Kind], Max(5, Round(Size * FK)), FontBold[Kind]);
end;

procedure TUiBase.BeginFrame(ADL: TDisplayList);
begin
  D := ADL;
  FHitN := 0;
  FClipN := 0;
  FBuilding := True;
end;

procedure TUiBase.EndFrame;
var
  T: array of THit;
  N: Integer;
begin
  // the regions of this frame answer the events until the next frame
  T := FLastHits;
  FLastHits := FHits;
  FHits := T;
  N := FLastHitN;
  FLastHitN := FHitN;
  FHitN := N;
  FHitN := 0;
  FBuilding := False;
end;

procedure TUiBase.Hit(X, Y, W, H: Single; Id: Integer; Kind: THitKind; const S: string);
var
  R: TRectF;
begin
  R := RectF(X, Y, X + W, Y + H);
  if FClipN > 0 then
  begin
    // only the part that can be seen takes the mouse
    R.Left := Max(R.Left, FClipStack[FClipN - 1].Left);
    R.Top := Max(R.Top, FClipStack[FClipN - 1].Top);
    R.Right := Min(R.Right, FClipStack[FClipN - 1].Right);
    R.Bottom := Min(R.Bottom, FClipStack[FClipN - 1].Bottom);
    if (R.Right <= R.Left) or (R.Bottom <= R.Top) then Exit;
  end;
  if FHitN >= Length(FHits) then SetLength(FHits, Length(FHits) * 2);
  FHits[FHitN].R := R;
  FHits[FHitN].FontK := fkUI;
  FHits[FHitN].FontS := 0;
  FHits[FHitN].Id := Id;
  FHits[FHitN].Kind := Kind;
  FHits[FHitN].S := S;
  Inc(FHitN);
end;

function TUiBase.Hot(X, Y, W, H: Single): Boolean;
begin
  Result := FMouseIn and (FMX >= X) and (FMX < X + W) and (FMY >= Y) and (FMY < Y + H);
end;

function TUiBase.HitAt(X, Y: Single; out H: THit): Boolean;
var
  K: Integer;
begin
  // the last region added is on top
  for K := FLastHitN - 1 downto 0 do
    if (FLastHits[K].Kind <> hkWheel) and (X >= FLastHits[K].R.Left) and (X < FLastHits[K].R.Right) and
      (Y >= FLastHits[K].R.Top) and (Y < FLastHits[K].R.Bottom) then
    begin
      H := FLastHits[K];
      Exit(True);
    end;
  Result := False;
end;

{ ---------- primitives ---------- }

procedure TUiBase.Rc(X, Y, W, H: Single; C: TBGRAPixel);
begin
  D.Rect(PX(X), PY(Y), PX(X + W), PY(Y + H), C);
end;

procedure TUiBase.ImgD(X, Y, W, H: Single; B: TBGRABitmap);
begin
  D.Image(PX(X), PY(Y), PX(X + W), PY(Y + H), B);
end;

procedure TUiBase.RR(X, Y, W, H, R: Single; C: TBGRAPixel);
begin
  D.RRect(PX(X), PY(Y), PX(X + W), PY(Y + H), PS(R), C);
end;

procedure TUiBase.RRL(X, Y, W, H, R, LW: Single; C: TBGRAPixel);
begin
  D.RRectLine(PX(X), PY(Y), PX(X + W), PY(Y + H), PS(R), Max(0.6, PS(LW)), C);
end;

procedure TUiBase.El(CX, CY, RX, RY: Single; C: TBGRAPixel);
begin
  D.Ellipse(PX(CX), PY(CY), PS(RX), PS(RY), C);
end;

procedure TUiBase.ElL(CX, CY, RX, RY, LW: Single; C: TBGRAPixel);
begin
  D.EllipseLine(PX(CX), PY(CY), PS(RX), PS(RY), Max(0.6, PS(LW)), C);
end;

procedure TUiBase.Ln(X1, Y1, X2, Y2, LW: Single; C: TBGRAPixel);
begin
  D.Line(PX(X1), PY(Y1), PX(X2), PY(Y2), Max(0.6, PS(LW)), C);
end;

procedure TUiBase.DashLn(X1, Y1, X2, Y2, LW, Dash: Single; C: TBGRAPixel);
var
  Len, T, T2, DX, DY: Single;
begin
  Len := Sqrt(Sqr(X2 - X1) + Sqr(Y2 - Y1));
  if Len < 0.1 then Exit;
  DX := (X2 - X1) / Len;
  DY := (Y2 - Y1) / Len;
  T := 0;
  while T < Len do
  begin
    T2 := Min(Len, T + Dash);
    Ln(X1 + DX * T, Y1 + DY * T, X1 + DX * T2, Y1 + DY * T2, LW, C);
    T := T + Dash * 2;
  end;
end;

procedure TUiBase.PolyD(const P: array of TPointF; C: TBGRAPixel);
var
  Q: array of TPointF;
  I: Integer;
begin
  SetLength(Q, Length(P));
  for I := 0 to High(P) do Q[I] := PointF(PX(P[I].X), PY(P[I].Y));
  D.Poly(Q, C);
end;

procedure TUiBase.PolyLineD(const P: array of TPointF; LW: Single; C: TBGRAPixel);
var
  Q: array of TPointF;
  I: Integer;
begin
  SetLength(Q, Length(P));
  for I := 0 to High(P) do Q[I] := PointF(PX(P[I].X), PY(P[I].Y));
  D.PolyLine(Q, Max(0.6, PS(LW)), C);
end;

procedure TUiBase.Shad(X, Y, W, H, R, Off, Blur: Single; Alpha: Integer);
begin
  D.Shadow(PX(X + Off * 0.5), PY(Y + Off), PX(X + W + Off * 0.5), PY(Y + H + Off), PS(R), PS(Blur),
    BGRA(60, 34, 20, Alpha));
end;

procedure TUiBase.GlowD(CX, CY, R: Single; C: TBGRAPixel);
begin
  D.Glow(PX(CX), PY(CY), PS(R), C);
end;

procedure TUiBase.VGradD(X, Y, W, H: Single; C1, C2: TBGRAPixel);
begin
  D.VGrad(PX(X), PY(Y), PX(X + W), PY(Y + H), C1, C2);
end;

procedure TUiBase.Txt(Kind: TFontKind; Size, X, Y: Single; const S: string; C: TBGRAPixel; Align: Integer);
begin
  if S = '' then Exit;
  D.Text(Fnt(Kind, Size), PX(X), PY(Y), S, C, Align);
end;

function TUiBase.TxtW(Kind: TFontKind; Size: Single; const S: string): Single;
begin
  Result := FGl.TextWidth(Fnt(Kind, Size), S) / FK;
end;

{ text cut with an ellipsis to MaxW }
procedure TUiBase.TxtFit(Kind: TFontKind; Size, X, Y, MaxW: Single; const S: string; C: TBGRAPixel; Align: Integer);
var
  T: string;
  N: Integer;
begin
  if S = '' then Exit;
  if TxtW(Kind, Size, S) <= MaxW then
  begin
    Txt(Kind, Size, X, Y, S, C, Align);
    Exit;
  end;
  N := UTF8Length(S);
  T := S;
  while (N > 1) and (TxtW(Kind, Size, T + '…') > MaxW) do
  begin
    Dec(N);
    T := UTF8Copy(S, 1, N);
  end;
  Txt(Kind, Size, X, Y, T + '…', C, Align);
end;

procedure TUiBase.ClipD(X, Y, W, H: Single);
var
  R: TRectF;
begin
  D.Clip(PX(X), PY(Y), PX(X + W), PY(Y + H));
  R := RectF(X, Y, X + W, Y + H);
  if FClipN > 0 then
  begin
    R.Left := Max(R.Left, FClipStack[FClipN - 1].Left);
    R.Top := Max(R.Top, FClipStack[FClipN - 1].Top);
    R.Right := Min(R.Right, FClipStack[FClipN - 1].Right);
    R.Bottom := Min(R.Bottom, FClipStack[FClipN - 1].Bottom);
  end;
  if FClipN >= Length(FClipStack) then SetLength(FClipStack, FClipN + 8);
  FClipStack[FClipN] := R;
  Inc(FClipN);
end;

procedure TUiBase.UnclipD;
begin
  D.Unclip;
  if FClipN > 0 then Dec(FClipN);
end;

{ ---------- papercut ---------- }

{ a paper sheet with its soft shadow }
procedure TUiBase.Sheet(X, Y, W, H, R: Single; C: TBGRAPixel; Depth: Single);
var
  L: TLayer;
begin
  L := D.Layer;
  if Depth > 0 then Shad(X, Y, W, H, R, 4 * Depth, 9 * Depth, Round(78 * Min(1, Depth)));
  RR(X, Y, W, H, R, C);
  // a lighter cut edge on top
  Ln(X + R, Y + 0.8, X + W - R, Y + 0.8, 0.9, Alpha(cWhite, 90));
  D.Layer := L;
end;

{ one hui wen (回) square spiral }
procedure TUiBase.HuiWen(X, Y, Sz, LW: Single; C: TBGRAPixel);
var
  A, B2: Single;
begin
  A := Sz;
  B2 := Sz * 0.5;
  PolyLineD([PointF(X, Y + A), PointF(X, Y), PointF(X + A, Y), PointF(X + A, Y + A * 0.78),
    PointF(X + A * 0.22, Y + A * 0.78), PointF(X + A * 0.22, Y + A * 0.24), PointF(X + A * 0.76, Y + A * 0.24),
    PointF(X + A * 0.76, Y + A * 0.56), PointF(X + A * 0.46, Y + A * 0.56)], LW, C);
  if B2 = 0 then ;
end;

{ a band of hui wen motifs between two lines }
procedure TUiBase.FretStrip(X, Y, W, H: Single; C, Bg: TBGRAPixel);
var
  N, I: Integer;
  U, Sz, X0: Single;
begin
  if Bg.alpha > 0 then Rc(X, Y, W, H, Bg);
  Ln(X, Y + 0.5, X + W, Y + 0.5, 1, C);
  Ln(X, Y + H - 0.5, X + W, Y + H - 0.5, 1, C);
  Sz := H - 6;
  U := Sz + 4;
  N := Max(1, Trunc((W - 4) / U));
  X0 := X + (W - N * U) / 2 + 2;
  for I := 0 to N - 1 do HuiWen(X0 + I * U, Y + 3, Sz, Max(0.9, H / 10), C);
end;

{ an L shaped key fret corner; DirX / DirY: +1 or -1 pointing into the card }
procedure TUiBase.CornerFret(X, Y, Sz: Single; DirX, DirY: Integer; C: TBGRAPixel);
var
  A: Single;
  W: Single;

  function P(U, V: Single): TPointF;
  begin
    Result := PointF(X + U * A * DirX, Y + V * A * DirY);
  end;

begin
  A := Sz;
  W := Max(1, Sz / 11);
  PolyLineD([P(1.0, 0), P(0, 0), P(0, 1.0)], W, C);
  PolyLineD([P(0.82, 0.18), P(0.18, 0.18), P(0.18, 0.82)], W, C);
  PolyLineD([P(0.62, 0.18), P(0.62, 0.38), P(0.38, 0.38), P(0.38, 0.62), P(0.18, 0.62)], W, C);
end;

{ a card: paper sheet, shadow, red double frame, gold corner frets, red title ribbon }
procedure TUiBase.Card(X, Y, W, H: Single; const Title: string; Fancy: Boolean);
var
  TW: Single;
begin
  D.Layer := lySheets;
  Sheet(X, Y, W, H, 10, cSheet, 1);
  D.Layer := lyOrnament;
  RRL(X + 6, Y + 6, W - 12, H - 12, 7, 1.1, Alpha(cRed, 150));
  if Fancy then
  begin
    RRL(X + 10, Y + 10, W - 20, H - 20, 5, 0.7, Alpha(cGoldDark, 140));
    CornerFret(X + 13, Y + 13, 13, 1, 1, cGoldDark);
    CornerFret(X + W - 13, Y + 13, 13, -1, 1, cGoldDark);
    CornerFret(X + 13, Y + H - 13, 13, 1, -1, cGoldDark);
    CornerFret(X + W - 13, Y + H - 13, 13, -1, -1, cGoldDark);
  end;
  if Title <> '' then
  begin
    TW := TxtW(fkUIB, 14, Title) + 34;
    D.Layer := lySheets;
    Shad(X + 22, Y - 9, TW, 26, 4, 2, 4, 70);
    RR(X + 22, Y - 9, TW, 26, 4, cRed);
    D.Layer := lyOrnament;
    RRL(X + 25, Y - 6, TW - 6, 20, 3, 0.8, Alpha(cGoldLight, 200));
    El(X + 31, Y + 4, 2.4, 2.4, cGoldLight);
    El(X + 22 + TW - 9, Y + 4, 2.4, 2.4, cGoldLight);
    D.Layer := lyText;
    Txt(fkUIB, 14, X + 22 + TW / 2, Y - 6, Title, cSheet, 1);
  end;
  D.Layer := lySheets;
end;

{ a xiangyun cloud scroll, cut out of darker paper }
procedure TUiBase.CloudMotif(CX, CY, Sz: Single; C: TBGRAPixel);
var
  I: Integer;
  A: Single;
  P: array of TPointF;
begin
  El(CX, CY, Sz, Sz * 0.62, C);
  El(CX - Sz * 0.9, CY + Sz * 0.18, Sz * 0.62, Sz * 0.44, C);
  El(CX + Sz * 0.92, CY + Sz * 0.2, Sz * 0.7, Sz * 0.46, C);
  El(CX + Sz * 0.15, CY - Sz * 0.45, Sz * 0.55, Sz * 0.42, C);
  // the curl
  SetLength(P, 24);
  for I := 0 to 23 do
  begin
    A := I / 23 * 2 * Pi * 1.3;
    P[I] := PointF(CX + Cos(A) * Sz * (0.42 - I * 0.012), CY + Sin(A) * Sz * (0.28 - I * 0.008));
  end;
  PolyLineD(P, Sz * 0.07, Alpha(cPaper, 200));
end;

procedure TUiBase.Seal(X, Y, Sz: Single; const S: string);
begin
  Shad(X, Y, Sz, Sz, 5, 2, 4, 90);
  RR(X, Y, Sz, Sz, 5, cRed);
  RRL(X + 3, Y + 3, Sz - 6, Sz - 6, 3, 1.4, cSheet);
  Txt(fkTitle, Sz * 0.36, X + Sz / 2, Y + Sz * 0.24, S, cSheet, 1);
end;

{ the mark of Virtual PLC (as VirtualPLC.ico): a PLC module - its LEDs, a display with a LAD rung, the
  terminal row - on a red sheet with a gold frame, gold circuit traces to the right; RunOn: the RUN LED lit }
procedure TUiBase.AppLogo(X, Y, Sz: Single; RunOn: Boolean);
var
  MX, MY, MW, MH, LW, YY, R: Single;
  K: Integer;
  C, cIvory, cIvoryDark, cSlate, cDisplay, cLedGreen, cLedAmber, cLedRed: TBGRAPixel;

  function MXf(F: Single): Single;
  begin
    Result := MX + MW * F;
  end;

  function MYf(F: Single): Single;
  begin
    Result := MY + MH * F;
  end;

begin
  cIvory := BGRA(250, 242, 226);
  cIvoryDark := BGRA(206, 190, 160);
  cSlate := BGRA(58, 54, 60);
  cDisplay := BGRA(34, 52, 48);
  cLedGreen := BGRA(60, 200, 110);
  cLedAmber := BGRA(240, 170, 40);
  cLedRed := BGRA(230, 60, 50);
  // the sheet
  RR(X + Sz * 0.03, Y + Sz * 0.03, Sz * 0.94, Sz * 0.94, Sz * 0.18, Mixc(cRedDark, cCharcoal, 0.25));
  RRL(X + Sz * 0.03, Y + Sz * 0.03, Sz * 0.94, Sz * 0.94, Sz * 0.18, Max(0.8, Sz * 0.02), Alpha(cSheet, 190));
  RR(X + Sz * 0.075, Y + Sz * 0.075, Sz * 0.85, Sz * 0.85, Sz * 0.14, cRed);
  RRL(X + Sz * 0.11, Y + Sz * 0.11, Sz * 0.78, Sz * 0.78, Sz * 0.1, Max(0.8, Sz * 0.02), cGold);
  // the circuit traces (virtual)
  if Sz >= 40 then
    for K := 0 to 2 do
    begin
      YY := Y + Sz * (0.40 + K * 0.12);
      Ln(X + Sz * 0.70, YY, X + Sz * (0.84 - Ord(K = 1) * 0.04), YY, Max(0.8, Sz * 0.018), cGold);
      El(X + Sz * (0.84 - Ord(K = 1) * 0.04), YY, Sz * 0.025, Sz * 0.025, cGold);
    end;
  // the module
  MX := X + Sz * 0.22;
  MY := Y + Sz * 0.20;
  MW := Sz * 0.48;
  MH := Sz * 0.60;
  RR(MX + Sz * 0.01, MY + Sz * 0.02, MW, MH, Sz * 0.05, Alpha(cCharcoal, 90));
  RR(MX, MY, MW, MH, Sz * 0.05, cIvory);
  RRL(MX, MY, MW, MH, Sz * 0.05, Max(0.6, Sz * 0.012), cIvoryDark);
  Rc(MXf(0.02), MYf(0.02), MW * 0.96, MH * 0.11, cSlate);
  // the LEDs: RUN, STOP, ERROR
  R := MW * 0.065;
  if RunOn then C := cLedGreen else C := Mixc(cLedGreen, cSlate, 0.7);
  El(MXf(0.18), MYf(0.31), R, R, C);
  if Sz >= 28 then
  begin
    El(MXf(0.18), MYf(0.47), R, R, cLedAmber);
    El(MXf(0.18), MYf(0.63), R, R, cLedRed);
  end;
  // the display with a LAD rung
  RR(MXf(0.34), MYf(0.22), MW * 0.56, MH * 0.42, Sz * 0.015, cDisplay);
  if Sz >= 28 then
  begin
    LW := Max(0.6, Sz * 0.014);
    YY := MYf(0.43);
    Ln(MXf(0.40), MYf(0.30), MXf(0.40), MYf(0.56), LW, cGold);
    Ln(MXf(0.84), MYf(0.30), MXf(0.84), MYf(0.56), LW, cGold);
    Ln(MXf(0.40), YY, MXf(0.52), YY, LW, cLedGreen);
    Ln(MXf(0.52), MYf(0.36), MXf(0.52), MYf(0.50), LW, cLedGreen);
    Ln(MXf(0.58), MYf(0.36), MXf(0.58), MYf(0.50), LW, cLedGreen);
    Ln(MXf(0.58), YY, MXf(0.67), YY, LW, cLedGreen);
    ElL(MXf(0.73), YY, MW * 0.06, MW * 0.06, LW, cLedGreen);
    Ln(MXf(0.73) + MW * 0.06, YY, MXf(0.84), YY, LW, cLedGreen);
    // the terminal row
    for K := 0 to 5 do Rc(MXf(0.10 + K * 0.14), MYf(0.76), MW * 0.09, MH * 0.14, cSlate);
  end;
end;

{ ---------- widgets ---------- }

function TUiBase.Button(X, Y, W, H: Single; const Caption: string; Id: Integer; Style: TBtnStyle;
  Enabled: Boolean; Size: Single): Boolean;
var
  IsHot, Down: Boolean;
  Bg, Fg, Bd: TBGRAPixel;
  Off: Single;
  L: TLayer;
begin
  L := D.Layer;
  IsHot := Enabled and Hot(X, Y, W, H);
  Down := IsHot and (FDownId = Id);
  case Style of
    bsPrimary: begin Bg := cRed; Fg := cSheet; Bd := cRedDark; end;
    bsToggleOn: begin Bg := cGold; Fg := cInk; Bd := cGoldDark; end;
    bsDanger: begin Bg := cRedDark; Fg := cSheet; Bd := cRedDark; end;
    bsGold: begin Bg := cGoldLight; Fg := cInk; Bd := cGoldDark; end;
    bsFlat: begin Bg := Alpha(cSheet2, 0); Fg := cRed; Bd := Alpha(cRed, 0); end;
  else
    begin Bg := cSheet2; Fg := cRedDark; Bd := Alpha(cRed, 170); end;
  end;
  if not Enabled then
  begin
    Bg := Mixc(Bg, cPaper, 0.6);
    Fg := Mixc(Fg, cPaper, 0.55);
    Bd := Mixc(Bd, cPaper, 0.6);
  end
  else if IsHot then
    Bg := Mixc(Bg, cWhite, 0.18);
  if Down then Off := 1.5 else Off := 0;
  D.Layer := lyControls;
  if Style <> bsFlat then
  begin
    if not Down then Shad(X, Y, W, H, 5, 2, 3.5, 70);
    RR(X, Y + Off, W, H, 5, Bg);
    RRL(X + 0.5, Y + 0.5 + Off, W - 1, H - 1, 5, 1, Bd);
    if Style in [bsPrimary, bsDanger] then RRL(X + 3, Y + 3 + Off, W - 6, H - 6, 3, 0.7, Alpha(cGoldLight, 160));
  end
  else if IsHot then
    RR(X, Y, W, H, 5, Alpha(cRed, 26));
  D.Layer := lyText;
  TxtFit(fkUIB, Size, X + W / 2, Y + Off + (H - Size * 1.36) / 2, W - 8, Caption, Fg, 1);
  D.Layer := L;
  if Enabled then Hit(X, Y, W, H, Id, hkClick);
  Result := IsHot;
end;

procedure TUiBase.Field(X, Y, W, H: Single; Id: Integer; const Value: string; Kind: TFontKind; Size: Single;
  Align: Integer; Enabled: Boolean; const Placeholder: string);
var
  IsHot, Ed: Boolean;
  S: string;
  TX, CX, TW: Single;
  SA, SB: Integer;
  L: TLayer;
begin
  L := D.Layer;
  Ed := (FEditId = Id) and (Id >= 0);
  IsHot := Enabled and Hot(X, Y, W, H);
  D.Layer := lyControls;
  if Ed then
  begin
    RR(X, Y, W, H, 3, cWhite);
    RRL(X, Y, W, H, 3, 1.4, cGold);
  end
  else if IsHot then
    RR(X, Y, W, H, 3, Alpha(cGoldLight, 90));
  D.Layer := lyText;
  if Ed then S := FEditText else S := Value;
  if Id = MaskId then S := StringOfChar('*', UTF8Length(S));
  ClipD(X + 1, Y, W - 2, H);
  if Ed then
  begin
    FEditKind := Kind;
    FEditSize := Size;
    TW := TxtW(Kind, Size, S);
    // the text scrolls so that the caret stays in the field
    TX := FEditTX;
    if (TX = 0) or (TX > X + 4) then TX := X + 4;
    CX := TX + TxtW(Kind, Size, UTF8Copy(S, 1, FEditCaret));
    if CX > X + W - 6 then TX := TX - (CX - (X + W - 6))
    else if CX < X + 4 then TX := TX + (X + 4 - CX);
    if (TX < X + 4) and (TX + TW < X + W - 6) then TX := Min(X + 4, X + W - 6 - TW);
    FEditTX := TX;
    CX := TX + TxtW(Kind, Size, UTF8Copy(S, 1, FEditCaret));
    // the selection behind the text
    EditSel(SA, SB);
    if SB > SA then
    begin
      D.Layer := lyControls;
      Rc(TX + TxtW(Kind, Size, UTF8Copy(S, 1, SA)), Y + 3, TxtW(Kind, Size, UTF8Copy(S, SA + 1, SB - SA)), H - 6,
        Alpha(cGold, 150));
      D.Layer := lyText;
    end;
    Txt(Kind, Size, TX, Y + (H - Size * 1.36) / 2, S, cInk);
    if (SB = SA) and (Frac(FTime * 1.6) < 0.62) then
      Rc(CX, Y + 3, 1.3, H - 6, cRed);
  end
  else if S <> '' then
  begin
    case Align of
      1: TX := X + W / 2;
      2: TX := X + W - 4;
    else
      TX := X + 4;
    end;
    if Enabled then TxtFit(Kind, Size, TX, Y + (H - Size * 1.36) / 2, W - 8, S, cInk, Align)
    else TxtFit(Kind, Size, TX, Y + (H - Size * 1.36) / 2, W - 8, S, cInkSoft, Align);
  end
  else if Placeholder <> '' then
    TxtFit(fkUI, Size, X + 4, Y + (H - Size * 1.36) / 2, W - 8, Placeholder, cInkFaint);
  UnclipD;
  D.Layer := L;
  if Enabled then
  begin
    Hit(X, Y, W, H, Id, hkField, Value);
    if (FHitN > 0) and (FHits[FHitN - 1].Id = Id) then
    begin
      FHits[FHitN - 1].FontK := Kind;
      FHits[FHitN - 1].FontS := Size;
    end;
  end;
end;

procedure TUiBase.Led(CX, CY, R: Single; C: TBGRAPixel; On: Boolean);
var
  L: TLayer;
begin
  L := D.Layer;
  D.Layer := lyControls;
  El(CX, CY + 0.8, R + 1.6, R + 1.6, Alpha(cShadow, 90));
  El(CX, CY, R + 1.4, R + 1.4, cCharcoal);
  if On then
  begin
    GlowD(CX, CY, R * 4.2, Alpha(C, 120));
    El(CX, CY, R, R, C);
    El(CX - R * 0.3, CY - R * 0.35, R * 0.38, R * 0.3, Alpha(cWhite, 200));
  end
  else
  begin
    El(CX, CY, R, R, Mixc(C, cCharcoal, 0.72));
    El(CX - R * 0.3, CY - R * 0.35, R * 0.3, R * 0.24, Alpha(cWhite, 50));
  end;
  D.Layer := L;
end;

{ an output lamp: a small paper lantern }
procedure TUiBase.Lamp(CX, CY, R: Single; C: TBGRAPixel; On: Boolean);
var
  L: TLayer;
begin
  L := D.Layer;
  D.Layer := lyControls;
  Shad(CX - R, CY - R * 0.9, R * 2, R * 1.8, R * 0.9, 2, 4, 80);
  Rc(CX - R * 0.45, CY - R * 1.05, R * 0.9, R * 0.22, cGoldDark);
  Rc(CX - R * 0.45, CY + R * 0.83, R * 0.9, R * 0.22, cGoldDark);
  if On then
  begin
    GlowD(CX, CY, R * 3.4, Alpha(Mixc(C, cWhite, 0.2), 170));
    El(CX, CY, R, R * 0.9, Darker(C, 0.95));
    El(CX, CY, R * 0.62, R * 0.9, Mixc(C, cWhite, 0.35));
    El(CX, CY, R * 0.25, R * 0.9, Mixc(C, cWhite, 0.7));
  end
  else
  begin
    El(CX, CY, R, R * 0.9, Mixc(C, cSheetDark, 0.82));
    El(CX, CY, R * 0.62, R * 0.9, Mixc(C, cSheetDark, 0.75));
  end;
  ElL(CX, CY, R, R * 0.9, 0.8, Alpha(cRedDark, 160));
  D.Layer := L;
end;

procedure TUiBase.Switch(X, Y, W, H: Single; On: Boolean; Id: Integer; Kind: THitKind);
var
  KX: Single;
  L: TLayer;
begin
  L := D.Layer;
  D.Layer := lyControls;
  if On then RR(X, Y, W, H, H / 2, cRed) else RR(X, Y, W, H, H / 2, Mixc(cCharcoal2, cSheetDark, 0.4));
  RRL(X, Y, W, H, H / 2, 0.8, Alpha(cInk, 120));
  if On then KX := X + W - H / 2 else KX := X + H / 2;
  El(KX, Y + H / 2 + 1, H / 2 - 1, H / 2 - 1, Alpha(cShadow, 110));
  El(KX, Y + H / 2, H / 2 - 2, H / 2 - 2, cSheet);
  ElL(KX, Y + H / 2, H / 2 - 2, H / 2 - 2, 0.8, cGoldDark);
  D.Layer := L;
  if Id >= 0 then Hit(X - 2, Y - 2, W + 4, H + 4, Id, Kind);
end;

procedure TUiBase.Check(X, Y, Sz: Single; On: Boolean; Id: Integer);
var
  L: TLayer;
begin
  L := D.Layer;
  D.Layer := lyControls;
  RR(X, Y, Sz, Sz, 3, cWhite);
  RRL(X, Y, Sz, Sz, 3, 1, cRed);
  if On then
    PolyLineD([PointF(X + Sz * 0.22, Y + Sz * 0.52), PointF(X + Sz * 0.43, Y + Sz * 0.74),
      PointF(X + Sz * 0.8, Y + Sz * 0.26)], Sz * 0.14, cRed);
  D.Layer := L;
  if Id >= 0 then Hit(X - 2, Y - 2, Sz + 4, Sz + 4, Id);
end;

procedure TUiBase.ProgressBar(X, Y, W, H, Frac: Single; C: TBGRAPixel);
begin
  RR(X, Y, W, H, H / 2, cSheetDark);
  if Frac > 0 then RR(X, Y, Max(H, W * EnsureRange(Frac, 0, 1)), H, H / 2, C);
  RRL(X, Y, W, H, H / 2, 0.7, Alpha(cInk, 80));
end;

{ ---------- events ---------- }

procedure TUiBase.DoClick(Id: Integer; const S: string);
begin
end;

procedure TUiBase.DoPress(Id: Integer; Down: Boolean);
begin
end;

procedure TUiBase.DoDrag(Id: Integer; X, Y: Single; const R: TRectF);
begin
end;

procedure TUiBase.DoWheel(Id: Integer; DY: Single);
begin
end;

procedure TUiBase.DoDragEnd(Id: Integer; X, Y: Single);
begin
end;

procedure TUiBase.DoRightClick(Id: Integer);
begin
end;

procedure TUiBase.MouseRightDown(X, Y: Single);
var
  Hd: THit;
begin
  MouseMove(X, Y);
  EndEdit(True);
  if HitAt(FMX, FMY, Hd) then DoRightClick(Hd.Id) else DoRightClick(-1);
end;

procedure TUiBase.DoKey(Key: TUiKey; Ch: Char; Mods: TUiMods);
begin
end;

procedure TUiBase.DoText(const S: string);
begin
end;

procedure TUiBase.CommitEdit(Id: Integer; const S: string);
begin
end;

function TUiBase.Editing: Boolean;
begin
  Result := FEditId >= 0;
end;

procedure TUiBase.StartEdit(Id: Integer; const Value: string);
begin
  FEditId := Id;
  FEditText := Value;
  FEditOrig := Value;
  FEditCaret := UTF8Length(Value);
  FEditAnchor := FEditCaret;
  FEditTX := 0;
  FEditTyping := False;
  FEditUndo := nil;
  FEditRedo := nil;
end;

{ ---------- the field as a text box ---------- }

procedure TUiBase.EditPush;
begin
  SetLength(FEditUndo, Length(FEditUndo) + 1);
  FEditUndo[High(FEditUndo)].T := FEditText;
  FEditUndo[High(FEditUndo)].C := FEditCaret;
  FEditUndo[High(FEditUndo)].A := FEditAnchor;
  FEditRedo := nil;
end;

procedure TUiBase.EditSel(out A, B: Integer);
begin
  A := Min(FEditAnchor, FEditCaret);
  B := Max(FEditAnchor, FEditCaret);
  A := EnsureRange(A, 0, UTF8Length(FEditText));
  B := EnsureRange(B, 0, UTF8Length(FEditText));
end;

function TUiBase.EditHasSel: Boolean;
begin
  Result := FEditAnchor <> FEditCaret;
end;

procedure TUiBase.EditDeleteSel;
var
  A, B: Integer;
begin
  EditSel(A, B);
  if B <= A then Exit;
  UTF8Delete(FEditText, A + 1, B - A);
  FEditCaret := A;
  FEditAnchor := A;
end;

{ the caret under the mouse (design units) }
function TUiBase.EditCaretAt(X: Single): Integer;
var
  S: string;
  N, K: Integer;
  Prev, Wd, Sz: Single;
begin
  S := FEditText;
  if FEditId = MaskId then S := StringOfChar('*', UTF8Length(S));
  N := UTF8Length(S);
  Sz := FEditSize;
  if Sz <= 0 then Sz := 12;
  Prev := 0;
  for K := 1 to N do
  begin
    Wd := TxtW(FEditKind, Sz, UTF8Copy(S, 1, K));
    if FEditTX + (Prev + Wd) / 2 > X then Exit(K - 1);
    Prev := Wd;
  end;
  Result := N;
end;

function IsWordCh(const C: string): Boolean;
begin
  Result := (C <> '') and ((Length(C) > 1) or (C[1] in ['0'..'9', 'A'..'Z', 'a'..'z', '_']));
end;

function TUiBase.EditWordStart(P: Integer): Integer;
begin
  Result := P;
  while (Result > 0) and not IsWordCh(UTF8Copy(FEditText, Result, 1)) do Dec(Result);
  while (Result > 0) and IsWordCh(UTF8Copy(FEditText, Result, 1)) do Dec(Result);
end;

function TUiBase.EditWordEnd(P: Integer): Integer;
var
  N: Integer;
begin
  N := UTF8Length(FEditText);
  Result := P;
  while (Result < N) and not IsWordCh(UTF8Copy(FEditText, Result + 1, 1)) do Inc(Result);
  while (Result < N) and IsWordCh(UTF8Copy(FEditText, Result + 1, 1)) do Inc(Result);
end;

procedure TUiBase.EndEdit(Commit: Boolean);
var
  Id: Integer;
  S: string;
begin
  if FEditId < 0 then Exit;
  Id := FEditId;
  S := FEditText;
  FEditId := -1;
  if Commit and (S <> FEditOrig) then CommitEdit(Id, S);
end;

procedure TUiBase.MouseMove(X, Y: Single);
var
  Hd: THit;
  K: Integer;
begin
  FMX := (X - FOX) / FK;
  FMY := (Y - FOY) / FK;
  FMouseIn := True;
  if FEditDragging and (FEditId >= 0) then FEditCaret := EditCaretAt(FMX);
  if FDragId >= 0 then
    for K := FLastHitN - 1 downto 0 do
      if (FLastHits[K].Id = FDragId) and (FLastHits[K].Kind = hkDrag) then
      begin
        Hd := FLastHits[K];
        DoDrag(FDragId, FMX, FMY, Hd.R);
        Break;
      end;
end;

procedure TUiBase.MouseDown(X, Y: Single);
var
  Hd: THit;
begin
  Inc(FPressNo);
  MouseMove(X, Y);
  if not HitAt(FMX, FMY, Hd) then
  begin
    EndEdit(True);
    FDownId := -1;
    Exit;
  end;
  if (Hd.Kind <> hkField) or (Hd.Id <> FEditId) then EndEdit(True);
  FDownId := Hd.Id;
  case Hd.Kind of
    hkClick: DoClick(Hd.Id, Hd.S);
    hkPress:
      begin
        FPressId := Hd.Id;
        DoPress(Hd.Id, True);
      end;
    hkDrag:
      begin
        FDragId := Hd.Id;
        DoDrag(Hd.Id, FMX, FMY, Hd.R);
      end;
    hkField:
      begin
        // a text box: a click places the caret, Shift+click selects to it, a drag selects,
        // a double click takes a word, a triple click all
        if FEditId <> Hd.Id then
        begin
          StartEdit(Hd.Id, Hd.S);
          FEditTX := Hd.R.Left + 4;
        end;
        FEditKind := Hd.FontK;
        FEditSize := Hd.FontS;
        FEditTyping := False;
        if MouseClicks >= 3 then
        begin
          FEditAnchor := 0;
          FEditCaret := UTF8Length(FEditText);
        end
        else if MouseClicks = 2 then
        begin
          FEditCaret := EditCaretAt(FMX);
          FEditAnchor := EditWordStart(Min(FEditCaret + 1, UTF8Length(FEditText)));
          if (FEditAnchor > FEditCaret) then FEditAnchor := FEditCaret;
          FEditCaret := EditWordEnd(FEditAnchor);
        end
        else
        begin
          FEditCaret := EditCaretAt(FMX);
          if not (umShift in MouseMods) then FEditAnchor := FEditCaret;
          FEditDragging := True;
        end;
      end;
  end;
end;

procedure TUiBase.MouseUp(X, Y: Single);
begin
  MouseMove(X, Y);
  FEditDragging := False;
  if FDragId >= 0 then DoDragEnd(FDragId, FMX, FMY);
  if FPressId >= 0 then DoPress(FPressId, False);
  FPressId := -1;
  FDragId := -1;
  FDownId := -1;
end;

procedure TUiBase.Wheel(DY: Single);
var
  K: Integer;
begin
  for K := FLastHitN - 1 downto 0 do
    if (FLastHits[K].Kind = hkWheel) and (FMX >= FLastHits[K].R.Left) and (FMX < FLastHits[K].R.Right) and
      (FMY >= FLastHits[K].R.Top) and (FMY < FLastHits[K].R.Bottom) then
    begin
      DoWheel(FLastHits[K].Id, DY);
      Exit;
    end;
end;

{ the keys of a text box: Shift selects, Ctrl moves by words, Ctrl+A / C / X / V / Z / Y }
procedure TUiBase.EditKey(Key: TUiKey; Ch: Char; Mods: TUiMods);
var
  N, A, B, K: Integer;
  Shift, Ctrl: Boolean;
  P: string;

  procedure MoveTo(C: Integer);
  begin
    FEditCaret := EnsureRange(C, 0, UTF8Length(FEditText));
    if not Shift then FEditAnchor := FEditCaret;
  end;

begin
  N := UTF8Length(FEditText);
  Shift := umShift in Mods;
  Ctrl := umCtrl in Mods;
  if Key <> ukChar then FEditTyping := False;
  case Key of
    ukEnter, ukTab: EndEdit(True);
    ukEsc: EndEdit(False);
    ukBack:
      begin
        EditPush;
        if EditHasSel then EditDeleteSel
        else if FEditCaret > 0 then
        begin
          if Ctrl then K := EditWordStart(FEditCaret) else K := FEditCaret - 1;
          UTF8Delete(FEditText, K + 1, FEditCaret - K);
          FEditCaret := K;
          FEditAnchor := K;
        end;
      end;
    ukDel:
      begin
        EditPush;
        if EditHasSel then EditDeleteSel
        else if FEditCaret < N then
        begin
          if Ctrl then K := EditWordEnd(FEditCaret) else K := FEditCaret + 1;
          UTF8Delete(FEditText, FEditCaret + 1, K - FEditCaret);
          FEditAnchor := FEditCaret;
        end;
      end;
    ukLeft:
      if Ctrl then MoveTo(EditWordStart(FEditCaret))
      else if EditHasSel and not Shift then
      begin
        EditSel(A, B);
        MoveTo(A);
      end
      else MoveTo(FEditCaret - 1);
    ukRight:
      if Ctrl then MoveTo(EditWordEnd(FEditCaret))
      else if EditHasSel and not Shift then
      begin
        EditSel(A, B);
        MoveTo(B);
      end
      else MoveTo(FEditCaret + 1);
    ukHome: MoveTo(0);
    ukEnd: MoveTo(N);
    ukChar:
      if Ctrl then
      begin
        FEditTyping := False;
        case UpCase(Ch) of
          'A':
            begin
              FEditAnchor := 0;
              FEditCaret := N;
            end;
          'C', 'X':
            if FEditId <> MaskId then   // a secret is not copied
            begin
              EditSel(A, B);
              if B > A then ClipboardOut := UTF8Copy(FEditText, A + 1, B - A)
              else if UpCase(Ch) = 'C' then ClipboardOut := FEditText;
              if (UpCase(Ch) = 'X') and (B > A) then
              begin
                EditPush;
                EditDeleteSel;
              end;
            end;
          'V':
            begin
              EditPush;
              EditDeleteSel;
              P := StringReplace(StringReplace(Clipboard, #13, '', [rfReplaceAll]), #10, ' ', [rfReplaceAll]);
              UTF8Insert(P, FEditText, FEditCaret + 1);
              Inc(FEditCaret, UTF8Length(P));
              FEditAnchor := FEditCaret;
            end;
          'Z':
            if Length(FEditUndo) > 0 then
            begin
              SetLength(FEditRedo, Length(FEditRedo) + 1);
              FEditRedo[High(FEditRedo)].T := FEditText;
              FEditRedo[High(FEditRedo)].C := FEditCaret;
              FEditRedo[High(FEditRedo)].A := FEditAnchor;
              FEditText := FEditUndo[High(FEditUndo)].T;
              FEditCaret := FEditUndo[High(FEditUndo)].C;
              FEditAnchor := FEditUndo[High(FEditUndo)].A;
              SetLength(FEditUndo, Length(FEditUndo) - 1);
            end;
          'Y':
            if Length(FEditRedo) > 0 then
            begin
              SetLength(FEditUndo, Length(FEditUndo) + 1);
              FEditUndo[High(FEditUndo)].T := FEditText;
              FEditUndo[High(FEditUndo)].C := FEditCaret;
              FEditUndo[High(FEditUndo)].A := FEditAnchor;
              FEditText := FEditRedo[High(FEditRedo)].T;
              FEditCaret := FEditRedo[High(FEditRedo)].C;
              FEditAnchor := FEditRedo[High(FEditRedo)].A;
              SetLength(FEditRedo, Length(FEditRedo) - 1);
            end;
        end;
      end;
  end;
end;

procedure TUiBase.KeyDown(Key: TUiKey; Ch: Char; Mods: TUiMods);
begin
  if FEditId >= 0 then
  begin
    EditKey(Key, Ch, Mods);
    Exit;
  end;
  DoKey(Key, Ch, Mods);
end;

procedure TUiBase.TextInput(const S: string);
begin
  if FEditId >= 0 then
  begin
    // typing replaces the selection; a run of typing is one undo step
    if not FEditTyping or EditHasSel then EditPush;
    FEditTyping := True;
    EditDeleteSel;
    UTF8Insert(S, FEditText, FEditCaret + 1);
    Inc(FEditCaret, UTF8Length(S));
    FEditAnchor := FEditCaret;
    Exit;
  end;
  DoText(S);
end;

initialization
  cPaper := BGRA($F6, $EE, $DE);
  cSheet := BGRA($FD, $F8, $EE);
  cSheet2 := BGRA($F3, $E6, $CC);
  cSheetDark := BGRA($E4, $D3, $B4);
  cInk := BGRA($3A, $2E, $2A);
  cInkSoft := BGRA($7A, $6A, $5E);
  cInkFaint := BGRA($B5, $A6, $93);
  cRed := BGRA($B2, $28, $22);
  cRedDark := BGRA($7E, $1A, $16);
  cRedLight := BGRA($D9, $5A, $4A);
  cGold := BGRA($DE, $AA, $32);
  cGoldDark := BGRA($A8, $7A, $1C);
  cGoldLight := BGRA($F0, $CF, $77);
  cJade := BGRA($3F, $9A, $5E);
  cJadeLight := BGRA($7C, $D3, $8E);
  cAmber := BGRA($F0, $A4, $1C);
  cCharcoal := BGRA($4B, $42, $3C);
  cCharcoal2 := BGRA($6A, $5E, $55);
  cWhite := BGRA(255, 255, 255);
  cShadow := BGRA(60, 34, 20);
end.
