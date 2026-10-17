unit uPaperDL;

{ Display lists and the paper painter.

  The UI is built (main thread) as a list of drawing commands in frame pixel
  coordinates: rectangles, rounded paper sheets, ellipses, polygons, lines, soft
  shadows, glows, gradients, text and clip rectangles. Every command belongs to
  a layer (paper, sheets, ornaments, controls, text, overlay) so that each
  layer can be exported on its own.

  Render draws a list into one horizontal band of the frame. It only reads the
  list and the glyph cache, so all worker threads can render their bands of the
  same list at once (each into its own band bitmap). Text is drawn from glyph
  masks cut once on the main thread (TGlyphCache): TBGRABitmap.TextOut is not
  thread safe, the masks are only read. Shadows and glows are computed per
  pixel (soft rounded rectangle shadow by distance), so they need no blur pass.

  ToSvg writes the same list as SVG elements (shadows as blur filters, text as
  <text>, clips as clipPath), so the vector export matches the picture. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, Types, Graphics, Forms, BGRABitmap, BGRABitmapTypes, LazUTF8;

type
  TLayer = (lyPaper, lySheets, lyOrnament, lyControls, lyText, lyOverlay);
  TLayerSet = set of TLayer;

const
  AllLayers = [Low(TLayer)..High(TLayer)];
  LayerNames: array[TLayer] of string = ('paper', 'sheets', 'ornaments', 'controls', 'text', 'overlay');
  MaxFonts = 384;
  MaxClusters = 2048;   // Thai clusters (a letter with its marks) per font
  ClusterBuckets = 1024;

type
  TGlyph = record
    W, H, OX, OY: Integer;   // mask size and offset from the pen (x, top of the line)
    Adv: Single;
    Made: Boolean;
    A: array of Byte;
  end;
  PGlyph = ^TGlyph;

  { TGlyphFont }

  TGlyphFont = class
  public
    Face: string;
    Px: Integer;
    Bold: Boolean;
    LineH, Ascent: Integer;
    Low: array[0..255] of TGlyph;
    Thai: array[0..127] of TGlyph;   // U+0E00..U+0E7F, cut from a font that has Thai
    ExtCodes: array of LongWord;
    Ext: array of TGlyph;
    ThaiFace: string;
    { Thai clusters, shaped by Windows as one piece (a lone mark would get a dotted circle):
      added by the main thread only, an entry is linked into its bucket when it is complete }
    ClKey: array of string;
    ClGlyph: array of TGlyph;
    ClNext: array of Integer;
    ClHead: array[0..ClusterBuckets - 1] of Integer;
    ClCount: Integer;
    function Find(Code: LongWord): PGlyph;
    function FindCluster(P: PChar; Len: Integer): PGlyph;
  end;

  { TGlyphCache: fonts are only added by the main thread, the slots never move }

  TGlyphCache = class
  private
    FFonts: array[0..MaxFonts - 1] of TGlyphFont;
    FCount: Integer;
    FScratch: TBGRABitmap;
    procedure MakeGlyph(F: TGlyphFont; Code: LongWord; var G: TGlyph; LeftRoom: Integer = 0);
    procedure MakeGlyphS(F: TGlyphFont; const S: string; var G: TGlyph; LeftRoom: Integer = 0);
  public
    constructor Create;
    destructor Destroy; override;
    function Get(const AFace: string; APx: Integer; ABold: Boolean): Integer;
    function Font(Id: Integer): TGlyphFont; inline;
    function TextWidth(Id: Integer; const S: string): Single;
    procedure Prepare(Id: Integer; const S: string);   // main thread: cut the Thai clusters of S
    function Full: Boolean;
    procedure Clear;   // only while no worker renders
    property Count: Integer read FCount;
  end;

  TCmdKind = (dkRect, dkRRect, dkRRectLine, dkEllipse, dkEllipseLine, dkPoly, dkPolyLine, dkLine,
    dkShadow, dkGlow, dkText, dkClip, dkUnclip, dkVGrad, dkImage);

  TCmd = record
    Kind: TCmdKind;
    Layer: TLayer;
    Align: ShortInt;      // text: 0 left, 1 centre, 2 right
    Font: SmallInt;
    X1, Y1, X2, Y2, R, W: Single;
    C, C2: TBGRAPixel;
    P0, PN: Integer;      // points
    Top, Bot: Integer;    // pixel rows touched
    Text: string;
    Img: TBGRABitmap;     // dkImage: not owned, only read while rendering (the owner keeps it)
  end;
  PCmd = ^TCmd;

  { TDisplayList }

  TDisplayList = class
  private
    FClip: array[0..15] of TRectF;
    FClipN: Integer;
    procedure Add(AKind: TCmdKind; X1, Y1, X2, Y2: Single; AC: TBGRAPixel; ARows0, ARows1: Single);
  public
    Cmds: array of TCmd;
    N: Integer;
    Pts: array of TPointF;
    NP: Integer;
    Layer: TLayer;
    Glyphs: TGlyphCache;
    constructor Create(AGlyphs: TGlyphCache);
    procedure Clear;
    procedure Assign(Src: TDisplayList);
    { shapes, frame pixels }
    procedure Rect(X1, Y1, X2, Y2: Single; AC: TBGRAPixel);
    procedure RRect(X1, Y1, X2, Y2, AR: Single; AC: TBGRAPixel);
    procedure RRectLine(X1, Y1, X2, Y2, AR, AW: Single; AC: TBGRAPixel);
    procedure Ellipse(CX, CY, RX, RY: Single; AC: TBGRAPixel);
    procedure EllipseLine(CX, CY, RX, RY, AW: Single; AC: TBGRAPixel);
    procedure Poly(const P: array of TPointF; AC: TBGRAPixel);
    procedure PolyLine(const P: array of TPointF; AW: Single; AC: TBGRAPixel);
    procedure Line(X1, Y1, X2, Y2, AW: Single; AC: TBGRAPixel);
    { soft shadow of a rounded rectangle (already offset), Blur = spread in px }
    procedure Shadow(X1, Y1, X2, Y2, AR, Blur: Single; AC: TBGRAPixel);
    procedure Glow(CX, CY, AR: Single; AC: TBGRAPixel);
    procedure VGrad(X1, Y1, X2, Y2: Single; C1, C2: TBGRAPixel);
    procedure Text(AFont: Integer; X, Y: Single; const S: string; AC: TBGRAPixel; AAlign: Integer = 0);
    { a picture into the rectangle (1:1 when it has that size, else stretched); the bitmap must live
      and stay unchanged until the list is rendered }
    procedure Image(X1, Y1, X2, Y2: Single; AImg: TBGRABitmap);
    procedure Clip(X1, Y1, X2, Y2: Single);
    procedure Unclip;
    { a copy of the commands I0 .. I1 - 1 moved by DX, DY with A / 255 of their alpha on ToLayer (the
      ghost of what the mouse drags); clips and images are left out }
    procedure Ghost(I0, I1: Integer; DX, DY: Single; A: Integer; ToLayer: TLayer);
    { drawing (any thread): the band's rows BandTop .. BandTop + B.Height - 1 }
    procedure Render(B: TBGRABitmap; BandTop: Integer; Layers: TLayerSet);
    procedure ToSvg(SL: TStrings; Layers: TLayerSet; var DefId: Integer);
  end;

{ the frame's paper grain: a signed offset per pixel, added to the colour }
procedure MakeGrain(var G: array of ShortInt; W, Y0, Y1: Integer);   // rows Y0 .. Y1 - 1
procedure ApplyGrain(B: TBGRABitmap; BandTop: Integer; const G: array of ShortInt; FrameW: Integer);
function RowPtr(B: TBGRABitmap; Y: Integer): PBGRAPixel; inline;
function SvgColor(C: TBGRAPixel): string;
function SvgNum(V: Single): string;
function SvgEsc(const S: string): string;

implementation

function RowPtr(B: TBGRABitmap; Y: Integer): PBGRAPixel; inline;
begin
  if B.LineOrder = riloTopToBottom then Result := B.Data + Y * B.Width
  else Result := B.Data + (B.Height - 1 - Y) * B.Width;
end;

{ a over d, with coverage A (0..255) of colour C }
procedure BlendPx(D: PBGRAPixel; const C: TBGRAPixel; A: Integer); inline;
var
  DA, W1, W2, WS: Integer;
begin
  if A <= 0 then Exit;
  if A >= 255 then
  begin
    D^.red := C.red;
    D^.green := C.green;
    D^.blue := C.blue;
    D^.alpha := 255;
    Exit;
  end;
  DA := D^.alpha;
  if DA = 255 then
  begin
    W2 := 255 - A;
    D^.red := (C.red * A + D^.red * W2 + 127) div 255;
    D^.green := (C.green * A + D^.green * W2 + 127) div 255;
    D^.blue := (C.blue * A + D^.blue * W2 + 127) div 255;
  end
  else
  begin
    W1 := A * 255;
    W2 := DA * (255 - A);
    WS := W1 + W2;
    if WS = 0 then Exit;
    D^.red := (C.red * W1 + D^.red * W2) div WS;
    D^.green := (C.green * W1 + D^.green * W2) div WS;
    D^.blue := (C.blue * W1 + D^.blue * W2) div WS;
    D^.alpha := WS div 255;
  end;
end;

function DecodeUtf8(var P: PChar; PEnd: PChar): LongWord;
var
  B: Byte;
  N, K: Integer;
begin
  B := Byte(P^);
  Inc(P);
  if B < $80 then Exit(B);
  if B and $E0 = $C0 then begin Result := B and $1F; N := 1; end
  else if B and $F0 = $E0 then begin Result := B and $0F; N := 2; end
  else if B and $F8 = $F0 then begin Result := B and $07; N := 3; end
  else Exit(Ord('?'));
  for K := 1 to N do
  begin
    if (P >= PEnd) or (Byte(P^) and $C0 <> $80) then Exit(Ord('?'));
    Result := (Result shl 6) or (Byte(P^) and $3F);
    Inc(P);
  end;
end;

function IsThaiMark(C: LongWord): Boolean; inline;
begin
  Result := (C = $0E31) or ((C >= $0E34) and (C <= $0E3A)) or ((C >= $0E47) and (C <= $0E4E));
end;

{ P is just after a Thai letter: the end of its cluster (the marks after it, and a Sara Am, whose
  ring sits over the letter), P itself when there is none }
function ThaiClusterEnd(P, PEnd: PChar): PChar;
var
  Q: PChar;
  C: LongWord;
begin
  Result := P;
  while Result < PEnd do
  begin
    Q := Result;
    C := DecodeUtf8(Q, PEnd);
    if IsThaiMark(C) or (C = $0E33) then Result := Q else Break;
    if C = $0E33 then Break;
  end;
end;

function IsThaiBase(C: LongWord): Boolean; inline;
begin
  Result := (C >= $0E01) and (C <= $0E5B) and not IsThaiMark(C);
end;

function ClHash(P: PChar; Len: Integer): Integer;
var
  H: LongWord;
  K: Integer;
begin
  H := 2166136261;
  for K := 0 to Len - 1 do H := (H xor Byte(P[K])) * 16777619;
  Result := H mod ClusterBuckets;
end;

{ ---------- glyphs ---------- }

function TGlyphFont.FindCluster(P: PChar; Len: Integer): PGlyph;
var
  K: Integer;
begin
  if ClKey = nil then Exit(nil);
  K := ClHead[ClHash(P, Len)];
  while K >= 0 do
  begin
    if (Length(ClKey[K]) = Len) and CompareMem(PChar(ClKey[K]), P, Len) then Exit(@ClGlyph[K]);
    K := ClNext[K];
  end;
  Result := nil;
end;

function TGlyphFont.Find(Code: LongWord): PGlyph;
var
  K: Integer;
begin
  if Code < 256 then
  begin
    if Low[Code].Made then Exit(@Low[Code]);
    Exit(nil);
  end;
  if (Code >= $0E00) and (Code < $0E80) then
  begin
    if Thai[Code - $0E00].Made then Exit(@Thai[Code - $0E00]);
    Exit(nil);
  end;
  for K := 0 to High(ExtCodes) do
    if ExtCodes[K] = Code then Exit(@Ext[K]);
  Result := nil;
end;

constructor TGlyphCache.Create;
begin
  inherited Create;
  FScratch := TBGRABitmap.Create(8, 8);
end;

destructor TGlyphCache.Destroy;
begin
  Clear;
  FScratch.Free;
  inherited Destroy;
end;

procedure TGlyphCache.Clear;
var
  K: Integer;
begin
  for K := 0 to FCount - 1 do FreeAndNil(FFonts[K]);
  FCount := 0;
end;

function TGlyphCache.Full: Boolean;
begin
  Result := FCount >= MaxFonts - 8;
end;

function TGlyphCache.Font(Id: Integer): TGlyphFont;
begin
  if (Id < 0) or (Id >= FCount) then Result := nil else Result := FFonts[Id];
end;

{ LeftRoom: a combining mark (Thai vowels above / below, tone marks) is drawn left of its pen position,
  over the letter before it: room on the left keeps that part, its advance stays 0 }
procedure TGlyphCache.MakeGlyph(F: TGlyphFont; Code: LongWord; var G: TGlyph; LeftRoom: Integer);
begin
  MakeGlyphS(F, UnicodeToUTF8(Code), G, LeftRoom);
end;

procedure TGlyphCache.MakeGlyphS(F: TGlyphFont; const S: string; var G: TGlyph; LeftRoom: Integer);
const
  Pad = 3;
var
  Sz: TSize;
  W, H, X, Y, X0, Y0, X1, Y1: Integer;
  P: PBGRAPixel;
begin
  Sz := FScratch.TextSize(S);
  W := Max(1, Sz.cx) + 2 * Pad + F.Px div 3 + LeftRoom;
  H := Max(F.LineH, Sz.cy) + 2 * Pad;
  FScratch.SetSize(W, H);
  FScratch.FillTransparent;
  FScratch.TextOut(Pad + LeftRoom, Pad, S, BGRAWhite);
  // the tight box of the letter
  X0 := W;
  Y0 := H;
  X1 := -1;
  Y1 := -1;
  for Y := 0 to H - 1 do
  begin
    P := RowPtr(FScratch, Y);
    for X := 0 to W - 1 do
    begin
      if P^.alpha > 0 then
      begin
        if X < X0 then X0 := X;
        if X > X1 then X1 := X;
        if Y < Y0 then Y0 := Y;
        if Y > Y1 then Y1 := Y;
      end;
      Inc(P);
    end;
  end;
  G.Adv := Sz.cx;
  if LeftRoom > 0 then G.Adv := 0;   // a combining mark takes no room of its own
  G.Made := True;
  if X1 < 0 then
  begin
    G.W := 0;
    G.H := 0;
    G.OX := 0;
    G.OY := 0;
    Exit;
  end;
  G.W := X1 - X0 + 1;
  G.H := Y1 - Y0 + 1;
  G.OX := X0 - Pad - LeftRoom;
  G.OY := Y0 - Pad;
  SetLength(G.A, G.W * G.H);
  for Y := 0 to G.H - 1 do
  begin
    P := RowPtr(FScratch, Y0 + Y) + X0;
    for X := 0 to G.W - 1 do
    begin
      G.A[Y * G.W + X] := P^.alpha;
      Inc(P);
    end;
  end;
end;

function TGlyphCache.Get(const AFace: string; APx: Integer; ABold: Boolean): Integer;
const
  Extra: array[0..23] of LongWord = ($2192, $2190, $2191, $2193, $2026, $2022, $2265, $2264, $2260,
    $2713, $25B6, $25A0, $25CF, $2715, $00B5, $2318, $25BC, $25B2, $2212, $221E, $2248, $0394, $03A3, $2014);
var
  K, C: Integer;
  F: TGlyphFont;
begin
  APx := EnsureRange(APx, 4, 400);
  for K := 0 to FCount - 1 do
    if (FFonts[K].Px = APx) and (FFonts[K].Bold = ABold) and (FFonts[K].Face = AFace) then Exit(K);
  if FCount >= MaxFonts then Exit(FCount - 1);
  F := TGlyphFont.Create;
  F.Face := AFace;
  F.Px := APx;
  F.Bold := ABold;
  FScratch.FontName := AFace;
  FScratch.FontHeight := APx;
  if ABold then FScratch.FontStyle := [fsBold] else FScratch.FontStyle := [];
  FScratch.FontQuality := fqFineAntialiasing;
  F.LineH := FScratch.TextSize('Hgjy').cy;
  F.Ascent := FScratch.FontPixelMetric.Baseline;
  if F.Ascent <= 0 then F.Ascent := Round(F.LineH * 0.78);
  for C := 32 to 126 do MakeGlyph(F, C, F.Low[C]);
  for C := 160 to 255 do MakeGlyph(F, C, F.Low[C]);
  SetLength(F.ExtCodes, Length(Extra));
  SetLength(F.Ext, Length(Extra));
  for K := 0 to High(Extra) do
  begin
    F.ExtCodes[K] := Extra[K];
    MakeGlyph(F, Extra[K], F.Ext[K]);
  end;
  // Thai (the UI font has none): Leelawadee UI is on every Windows 10 / 11, else Tahoma
  if Screen.Fonts.IndexOf('Leelawadee UI') >= 0 then F.ThaiFace := 'Leelawadee UI'
  else F.ThaiFace := 'Tahoma';
  FScratch.FontName := F.ThaiFace;
  for K := 0 to ClusterBuckets - 1 do F.ClHead[K] := -1;
  for C := $0E01 to $0E5B do
    if IsThaiMark(C) then
      MakeGlyph(F, C, F.Thai[C - $0E00], APx)    // a mark over / under the letter before it
    else
      MakeGlyph(F, C, F.Thai[C - $0E00]);
  FScratch.FontName := AFace;
  // the slot is published only when the font is complete
  FFonts[FCount] := F;
  Result := FCount;
  Inc(FCount);
end;

procedure TGlyphCache.Prepare(Id: Integer; const S: string);
var
  F: TGlyphFont;
  P, PEnd, P0, Q: PChar;
  K, B: Integer;
  Key: string;
begin
  F := Font(Id);
  if (F = nil) or (S = '') then Exit;
  P := PChar(S);
  PEnd := P + Length(S);
  while P < PEnd do
  begin
    P0 := P;
    if not IsThaiBase(DecodeUtf8(P, PEnd)) then Continue;
    Q := ThaiClusterEnd(P, PEnd);
    if Q = P then Continue;
    P := Q;
    if F.FindCluster(P0, Q - P0) <> nil then Continue;
    if F.ClKey = nil then
    begin
      SetLength(F.ClKey, MaxClusters);   // once: the slots never move
      SetLength(F.ClGlyph, MaxClusters);
      SetLength(F.ClNext, MaxClusters);
    end;
    if F.ClCount >= MaxClusters then Exit;
    K := F.ClCount;
    SetString(Key, P0, Q - P0);
    FScratch.FontName := F.ThaiFace;
    FScratch.FontHeight := F.Px;
    if F.Bold then FScratch.FontStyle := [fsBold] else FScratch.FontStyle := [];
    FScratch.FontQuality := fqFineAntialiasing;
    MakeGlyphS(F, Key, F.ClGlyph[K]);
    F.ClKey[K] := Key;
    B := ClHash(P0, Q - P0);
    F.ClNext[K] := F.ClHead[B];
    F.ClCount := K + 1;
    WriteBarrier;
    F.ClHead[B] := K;   // published: the workers can find it now
  end;
end;

function TGlyphCache.TextWidth(Id: Integer; const S: string): Single;
var
  F: TGlyphFont;
  P, PEnd, P0, Q: PChar;
  G: PGlyph;
  C: LongWord;
begin
  Result := 0;
  F := Font(Id);
  if (F = nil) or (S = '') then Exit;
  Prepare(Id, S);
  P := PChar(S);
  PEnd := P + Length(S);
  while P < PEnd do
  begin
    P0 := P;
    C := DecodeUtf8(P, PEnd);
    G := nil;
    if IsThaiBase(C) then
    begin
      Q := ThaiClusterEnd(P, PEnd);
      if Q > P then
      begin
        G := F.FindCluster(P0, Q - P0);
        if G <> nil then P := Q;
      end;
    end;
    if G = nil then G := F.Find(C);
    if G <> nil then Result := Result + G^.Adv else Result := Result + F.Px * 0.5;
  end;
end;

{ ---------- the list ---------- }

constructor TDisplayList.Create(AGlyphs: TGlyphCache);
begin
  inherited Create;
  Glyphs := AGlyphs;
  SetLength(Cmds, 1024);
  SetLength(Pts, 4096);
end;

procedure TDisplayList.Clear;
begin
  N := 0;
  NP := 0;
  FClipN := 0;
  Layer := lyPaper;
end;

procedure TDisplayList.Assign(Src: TDisplayList);
var
  K: Integer;
begin
  if Length(Cmds) < Src.N then SetLength(Cmds, Src.N + 64);
  for K := 0 to Src.N - 1 do Cmds[K] := Src.Cmds[K];
  N := Src.N;
  if Length(Pts) < Src.NP then SetLength(Pts, Src.NP + 64);
  if Src.NP > 0 then Move(Src.Pts[0], Pts[0], Src.NP * SizeOf(TPointF));
  NP := Src.NP;
end;

procedure TDisplayList.Add(AKind: TCmdKind; X1, Y1, X2, Y2: Single; AC: TBGRAPixel; ARows0, ARows1: Single);
var
  P: PCmd;
begin
  if N >= Length(Cmds) then SetLength(Cmds, Length(Cmds) * 2);
  P := @Cmds[N];
  P^.Kind := AKind;
  P^.Layer := Layer;
  P^.X1 := X1;
  P^.Y1 := Y1;
  P^.X2 := X2;
  P^.Y2 := Y2;
  P^.C := AC;
  P^.R := 0;
  P^.W := 0;
  P^.PN := 0;
  P^.Top := Floor(ARows0) - 2;
  P^.Bot := Ceil(ARows1) + 2;
  if P^.Text <> '' then P^.Text := '';
  P^.Img := nil;
  Inc(N);
end;

procedure TDisplayList.Image(X1, Y1, X2, Y2: Single; AImg: TBGRABitmap);
begin
  if (AImg = nil) or (X2 <= X1) or (Y2 <= Y1) then Exit;
  Add(dkImage, X1, Y1, X2, Y2, BGRAWhite, Y1, Y2);
  Cmds[N - 1].Img := AImg;
end;

procedure TDisplayList.Rect(X1, Y1, X2, Y2: Single; AC: TBGRAPixel);
begin
  if (X2 <= X1) or (Y2 <= Y1) or (AC.alpha = 0) then Exit;
  Add(dkRect, X1, Y1, X2, Y2, AC, Y1, Y2);
end;

procedure TDisplayList.RRect(X1, Y1, X2, Y2, AR: Single; AC: TBGRAPixel);
begin
  if (X2 <= X1) or (Y2 <= Y1) or (AC.alpha = 0) then Exit;
  Add(dkRRect, X1, Y1, X2, Y2, AC, Y1, Y2);
  Cmds[N - 1].R := Min(AR, Min(X2 - X1, Y2 - Y1) / 2);
end;

procedure TDisplayList.RRectLine(X1, Y1, X2, Y2, AR, AW: Single; AC: TBGRAPixel);
begin
  if (X2 <= X1) or (Y2 <= Y1) or (AC.alpha = 0) then Exit;
  Add(dkRRectLine, X1, Y1, X2, Y2, AC, Y1 - AW, Y2 + AW);
  Cmds[N - 1].R := Min(AR, Min(X2 - X1, Y2 - Y1) / 2);
  Cmds[N - 1].W := AW;
end;

procedure TDisplayList.Ellipse(CX, CY, RX, RY: Single; AC: TBGRAPixel);
begin
  if AC.alpha = 0 then Exit;
  Add(dkEllipse, CX, CY, RX, RY, AC, CY - RY, CY + RY);
end;

procedure TDisplayList.EllipseLine(CX, CY, RX, RY, AW: Single; AC: TBGRAPixel);
begin
  if AC.alpha = 0 then Exit;
  Add(dkEllipseLine, CX, CY, RX, RY, AC, CY - RY - AW, CY + RY + AW);
  Cmds[N - 1].W := AW;
end;

procedure TDisplayList.Poly(const P: array of TPointF; AC: TBGRAPixel);
var
  K: Integer;
  Y0, Y1: Single;
begin
  if (Length(P) < 3) or (AC.alpha = 0) then Exit;
  Y0 := P[0].Y;
  Y1 := P[0].Y;
  for K := 1 to High(P) do
  begin
    Y0 := Min(Y0, P[K].Y);
    Y1 := Max(Y1, P[K].Y);
  end;
  Add(dkPoly, 0, 0, 0, 0, AC, Y0, Y1);
  if NP + Length(P) > Length(Pts) then SetLength(Pts, (NP + Length(P)) * 2);
  Cmds[N - 1].P0 := NP;
  Cmds[N - 1].PN := Length(P);
  for K := 0 to High(P) do Pts[NP + K] := P[K];
  Inc(NP, Length(P));
end;

procedure TDisplayList.PolyLine(const P: array of TPointF; AW: Single; AC: TBGRAPixel);
var
  K: Integer;
  Y0, Y1: Single;
begin
  if (Length(P) < 2) or (AC.alpha = 0) then Exit;
  Y0 := P[0].Y;
  Y1 := P[0].Y;
  for K := 1 to High(P) do
  begin
    Y0 := Min(Y0, P[K].Y);
    Y1 := Max(Y1, P[K].Y);
  end;
  Add(dkPolyLine, 0, 0, 0, 0, AC, Y0 - AW, Y1 + AW);
  Cmds[N - 1].W := AW;
  if NP + Length(P) > Length(Pts) then SetLength(Pts, (NP + Length(P)) * 2);
  Cmds[N - 1].P0 := NP;
  Cmds[N - 1].PN := Length(P);
  for K := 0 to High(P) do Pts[NP + K] := P[K];
  Inc(NP, Length(P));
end;

procedure TDisplayList.Line(X1, Y1, X2, Y2, AW: Single; AC: TBGRAPixel);
begin
  if AC.alpha = 0 then Exit;
  Add(dkLine, X1, Y1, X2, Y2, AC, Min(Y1, Y2) - AW, Max(Y1, Y2) + AW);
  Cmds[N - 1].W := AW;
end;

procedure TDisplayList.Shadow(X1, Y1, X2, Y2, AR, Blur: Single; AC: TBGRAPixel);
begin
  if (AC.alpha = 0) or (X2 <= X1) or (Y2 <= Y1) then Exit;
  Blur := Max(0.5, Blur);
  Add(dkShadow, X1, Y1, X2, Y2, AC, Y1 - Blur, Y2 + Blur);
  Cmds[N - 1].R := Min(AR, Min(X2 - X1, Y2 - Y1) / 2);
  Cmds[N - 1].W := Blur;
end;

procedure TDisplayList.Glow(CX, CY, AR: Single; AC: TBGRAPixel);
begin
  if (AC.alpha = 0) or (AR < 1) then Exit;
  Add(dkGlow, CX, CY, 0, 0, AC, CY - AR, CY + AR);
  Cmds[N - 1].R := AR;
end;

procedure TDisplayList.VGrad(X1, Y1, X2, Y2: Single; C1, C2: TBGRAPixel);
begin
  if (X2 <= X1) or (Y2 <= Y1) then Exit;
  Add(dkVGrad, X1, Y1, X2, Y2, C1, Y1, Y2);
  Cmds[N - 1].C2 := C2;
end;

procedure TDisplayList.Text(AFont: Integer; X, Y: Single; const S: string; AC: TBGRAPixel; AAlign: Integer);
var
  F: TGlyphFont;
  W: Single;
begin
  if (S = '') or (AC.alpha = 0) then Exit;
  F := Glyphs.Font(AFont);
  if F = nil then Exit;
  if AAlign <> 0 then
  begin
    W := Glyphs.TextWidth(AFont, S);
    if AAlign = 1 then X := X - W / 2 else X := X - W;
  end
  else
    Glyphs.Prepare(AFont, S);
  Add(dkText, X, Y, 0, 0, AC, Y - F.Px * 0.3, Y + F.LineH + F.Px * 0.3);
  Cmds[N - 1].Font := AFont;
  Cmds[N - 1].Align := 0;
  Cmds[N - 1].Text := S;
end;

procedure TDisplayList.Clip(X1, Y1, X2, Y2: Single);
var
  R: TRectF;
begin
  R := RectF(X1, Y1, X2, Y2);
  if FClipN > 0 then
  begin
    R.Left := Max(R.Left, FClip[FClipN - 1].Left);
    R.Top := Max(R.Top, FClip[FClipN - 1].Top);
    R.Right := Min(R.Right, FClip[FClipN - 1].Right);
    R.Bottom := Min(R.Bottom, FClip[FClipN - 1].Bottom);
  end;
  if FClipN <= High(FClip) then
  begin
    FClip[FClipN] := R;
    Inc(FClipN);
  end;
  Add(dkClip, R.Left, R.Top, R.Right, R.Bottom, BGRABlack, -1E9, 1E9);
  Cmds[N - 1].Top := -MaxInt div 2;
  Cmds[N - 1].Bot := MaxInt div 2;
end;

procedure TDisplayList.Ghost(I0, I1: Integer; DX, DY: Single; A: Integer; ToLayer: TLayer);
var
  K, J: Integer;
  L: TLayer;
  Cm: TCmd;
begin
  // layer by layer, as the frame shows them: the text stays above its box
  for L := Low(TLayer) to High(TLayer) do
  for K := Max(0, I0) to Min(I1, N) - 1 do
  begin
    Cm := Cmds[K];
    if (Cm.Layer <> L) or (Cm.Kind in [dkClip, dkUnclip, dkImage]) then Continue;
    Cm.Layer := ToLayer;
    Cm.X1 := Cm.X1 + DX;
    Cm.Y1 := Cm.Y1 + DY;
    if Cm.Kind in [dkRect, dkRRect, dkRRectLine, dkLine, dkShadow, dkVGrad] then
    begin
      Cm.X2 := Cm.X2 + DX;
      Cm.Y2 := Cm.Y2 + DY;
    end;
    Cm.Top := Floor(Cm.Top + DY) - 1;
    Cm.Bot := Ceil(Cm.Bot + DY) + 1;
    Cm.C.alpha := Cm.C.alpha * A div 255;
    Cm.C2.alpha := Cm.C2.alpha * A div 255;
    if Cm.PN > 0 then
    begin
      if NP + Cm.PN > Length(Pts) then SetLength(Pts, (NP + Cm.PN) * 2);
      for J := 0 to Cm.PN - 1 do
        Pts[NP + J] := PointF(Pts[Cm.P0 + J].X + DX, Pts[Cm.P0 + J].Y + DY);
      Cm.P0 := NP;
      Inc(NP, Cm.PN);
    end;
    if N >= Length(Cmds) then SetLength(Cmds, Length(Cmds) * 2);
    Cmds[N] := Cm;
    Inc(N);
  end;
end;

procedure TDisplayList.Unclip;
begin
  if FClipN > 0 then Dec(FClipN);
  if FClipN > 0 then
  begin
    Add(dkClip, FClip[FClipN - 1].Left, FClip[FClipN - 1].Top, FClip[FClipN - 1].Right,
      FClip[FClipN - 1].Bottom, BGRABlack, 0, 0);
  end
  else
    Add(dkUnclip, 0, 0, 0, 0, BGRABlack, 0, 0);
  Cmds[N - 1].Top := -MaxInt div 2;
  Cmds[N - 1].Bot := MaxInt div 2;
end;

{ ---------- rendering ---------- }

procedure DrawText(B: TBGRABitmap; Gl: TGlyphCache; const Cm: TCmd; BandTop: Integer; const Clip: TRect);
var
  F: TGlyphFont;
  P, PEnd, P0, Q: PChar;
  C: LongWord;
  G: PGlyph;
  X: Single;
  GX, GY, X0, X1, Y0, Y1, XX, YY, A, CA: Integer;
  D: PBGRAPixel;
  S: PByte;
begin
  F := Gl.Font(Cm.Font);
  if F = nil then Exit;
  CA := Cm.C.alpha;
  X := Cm.X1;
  P := PChar(Cm.Text);
  PEnd := P + Length(Cm.Text);
  while P < PEnd do
  begin
    P0 := P;
    C := DecodeUtf8(P, PEnd);
    G := nil;
    if IsThaiBase(C) then
    begin
      Q := ThaiClusterEnd(P, PEnd);
      if Q > P then
      begin
        G := F.FindCluster(P0, Q - P0);   // a letter with its marks, shaped as one
        if G <> nil then P := Q;
      end;
    end;
    if G = nil then G := F.Find(C);
    if G = nil then
    begin
      X := X + F.Px * 0.5;
      Continue;
    end;
    if G^.W > 0 then
    begin
      GX := Round(X) + G^.OX;
      GY := Round(Cm.Y1) + G^.OY - BandTop;
      X0 := Max(GX, Clip.Left);
      X1 := Min(GX + G^.W, Clip.Right);
      Y0 := Max(GY, Clip.Top);
      Y1 := Min(GY + G^.H, Clip.Bottom);
      if (X1 > X0) and (Y1 > Y0) then
        for YY := Y0 to Y1 - 1 do
        begin
          D := RowPtr(B, YY) + X0;
          S := @G^.A[(YY - GY) * G^.W + (X0 - GX)];
          for XX := X0 to X1 - 1 do
          begin
            A := S^;
            if A > 0 then
            begin
              if CA < 255 then A := A * CA div 255;
              BlendPx(D, Cm.C, A);
            end;
            Inc(D);
            Inc(S);
          end;
        end;
    end;
    X := X + G^.Adv;
  end;
end;

{ signed distance to a rounded rectangle }
function RRDist(PX, PY, CX, CY, HX, HY, R: Single): Single; inline;
var
  QX, QY: Single;
begin
  QX := Abs(PX - CX) - (HX - R);
  QY := Abs(PY - CY) - (HY - R);
  if (QX > 0) and (QY > 0) then Result := Sqrt(QX * QX + QY * QY) - R
  else Result := Max(QX, QY) - R;
end;

procedure DrawShadow(B: TBGRABitmap; const Cm: TCmd; BandTop: Integer; const Clip: TRect);
var
  X0, X1, Y0, Y1, X, Y, A, IX0, IX1: Integer;
  CX, CY, HX, HY, D, T, Bl: Single;
  P: PBGRAPixel;
begin
  Bl := Cm.W;
  X0 := Max(Clip.Left, Floor(Cm.X1 - Bl));
  X1 := Min(Clip.Right, Ceil(Cm.X2 + Bl));
  Y0 := Max(Clip.Top, Floor(Cm.Y1 - Bl) - BandTop);
  Y1 := Min(Clip.Bottom, Ceil(Cm.Y2 + Bl) - BandTop);
  if (X1 <= X0) or (Y1 <= Y0) then Exit;
  CX := (Cm.X1 + Cm.X2) / 2;
  CY := (Cm.Y1 + Cm.Y2) / 2;
  HX := (Cm.X2 - Cm.X1) / 2;
  HY := (Cm.Y2 - Cm.Y1) / 2;
  for Y := Y0 to Y1 - 1 do
  begin
    P := RowPtr(B, Y) + X0;
    // the inside, away from the corners, is full shadow
    if (Y + BandTop > Cm.Y1 + Bl + Cm.R) and (Y + BandTop < Cm.Y2 - Bl - Cm.R) then
    begin
      IX0 := Ceil(Cm.X1 + Bl);
      IX1 := Floor(Cm.X2 - Bl);
    end
    else
    begin
      IX0 := MaxInt;
      IX1 := -MaxInt;
    end;
    for X := X0 to X1 - 1 do
    begin
      if (X >= IX0) and (X < IX1) then
        A := Cm.C.alpha
      else
      begin
        D := RRDist(X + 0.5, Y + BandTop + 0.5, CX, CY, HX, HY, Cm.R);
        T := 0.5 - D / (2 * Bl);
        if T <= 0 then A := 0
        else if T >= 1 then A := Cm.C.alpha
        else A := Round(Cm.C.alpha * T * T * (3 - 2 * T));
      end;
      if A > 0 then BlendPx(P, Cm.C, A);
      Inc(P);
    end;
  end;
end;

procedure DrawGlow(B: TBGRABitmap; const Cm: TCmd; BandTop: Integer; const Clip: TRect);
var
  X0, X1, Y0, Y1, X, Y, A: Integer;
  DX, DY, D, R2, T: Single;
  P: PBGRAPixel;
begin
  X0 := Max(Clip.Left, Floor(Cm.X1 - Cm.R));
  X1 := Min(Clip.Right, Ceil(Cm.X1 + Cm.R));
  Y0 := Max(Clip.Top, Floor(Cm.Y1 - Cm.R) - BandTop);
  Y1 := Min(Clip.Bottom, Ceil(Cm.Y1 + Cm.R) - BandTop);
  R2 := Cm.R * Cm.R;
  for Y := Y0 to Y1 - 1 do
  begin
    P := RowPtr(B, Y) + X0;
    DY := Y + BandTop + 0.5 - Cm.Y1;
    for X := X0 to X1 - 1 do
    begin
      DX := X + 0.5 - Cm.X1;
      D := DX * DX + DY * DY;
      if D < R2 then
      begin
        T := 1 - Sqrt(D) / Cm.R;
        A := Round(Cm.C.alpha * T * T);
        if A > 0 then BlendPx(P, Cm.C, A);
      end;
      Inc(P);
    end;
  end;
end;

procedure DrawVGrad(B: TBGRABitmap; const Cm: TCmd; BandTop: Integer; const Clip: TRect);
var
  X0, X1, Y0, Y1, X, Y: Integer;
  T: Single;
  C: TBGRAPixel;
  P: PBGRAPixel;
begin
  X0 := Max(Clip.Left, Round(Cm.X1));
  X1 := Min(Clip.Right, Round(Cm.X2));
  Y0 := Max(Clip.Top, Round(Cm.Y1) - BandTop);
  Y1 := Min(Clip.Bottom, Round(Cm.Y2) - BandTop);
  for Y := Y0 to Y1 - 1 do
  begin
    T := EnsureRange((Y + BandTop - Cm.Y1) / Max(1, Cm.Y2 - Cm.Y1), 0, 1);
    C.red := Round(Cm.C.red + (Cm.C2.red - Cm.C.red) * T);
    C.green := Round(Cm.C.green + (Cm.C2.green - Cm.C.green) * T);
    C.blue := Round(Cm.C.blue + (Cm.C2.blue - Cm.C.blue) * T);
    C.alpha := Round(Cm.C.alpha + (Cm.C2.alpha - Cm.C.alpha) * T);
    P := RowPtr(B, Y) + X0;
    for X := X0 to X1 - 1 do
    begin
      BlendPx(P, C, C.alpha);
      Inc(P);
    end;
  end;
end;

procedure TDisplayList.Render(B: TBGRABitmap; BandTop: Integer; Layers: TLayerSet);
var
  K, J, H: Integer;
  Cm: PCmd;
  T: Single;
  CR, FullR: TRect;
  Pt: array of TPointF;
begin
  H := B.Height;
  FullR := Types.Rect(0, 0, B.Width, H);
  CR := FullR;
  B.NoClip;
  T := BandTop;
  SetLength(Pt, 64);
  for K := 0 to N - 1 do
  begin
    Cm := @Cmds[K];
    if Cm^.Kind = dkClip then
    begin
      CR.Left := Max(0, Floor(Cm^.X1));
      CR.Top := Max(0, Floor(Cm^.Y1 - T));
      CR.Right := Min(B.Width, Ceil(Cm^.X2));
      CR.Bottom := Min(H, Ceil(Cm^.Y2 - T));
      if (CR.Right <= CR.Left) or (CR.Bottom <= CR.Top) then
        CR := Types.Rect(0, 0, 0, 0);
      B.ClipRect := CR;
      Continue;
    end;
    if Cm^.Kind = dkUnclip then
    begin
      CR := FullR;
      B.NoClip;
      Continue;
    end;
    if not (Cm^.Layer in Layers) then Continue;
    if (Cm^.Bot < BandTop) or (Cm^.Top >= BandTop + H) then Continue;
    if (CR.Right <= CR.Left) or (CR.Bottom <= CR.Top) then Continue;
    case Cm^.Kind of
      dkRect:
        if Cm^.C.alpha = 255 then
          B.FillRect(Round(Cm^.X1), Round(Cm^.Y1 - T), Round(Cm^.X2), Round(Cm^.Y2 - T), Cm^.C, dmSet)
        else
          B.FillRect(Round(Cm^.X1), Round(Cm^.Y1 - T), Round(Cm^.X2), Round(Cm^.Y2 - T), Cm^.C, dmDrawWithTransparency);
      dkRRect:
        B.FillRoundRectAntialias(Cm^.X1, Cm^.Y1 - T, Cm^.X2, Cm^.Y2 - T, Cm^.R, Cm^.R, Cm^.C, [], False);
      dkRRectLine:
        B.RoundRectAntialias(Cm^.X1, Cm^.Y1 - T, Cm^.X2, Cm^.Y2 - T, Cm^.R, Cm^.R, Cm^.C, Cm^.W);
      dkEllipse:
        B.FillEllipseAntialias(Cm^.X1, Cm^.Y1 - T, Cm^.X2, Cm^.Y2, Cm^.C);
      dkEllipseLine:
        B.EllipseAntialias(Cm^.X1, Cm^.Y1 - T, Cm^.X2, Cm^.Y2, Cm^.C, Cm^.W);
      dkPoly, dkPolyLine:
        begin
          if Length(Pt) < Cm^.PN then SetLength(Pt, Cm^.PN);
          for J := 0 to Cm^.PN - 1 do
          begin
            Pt[J].X := Pts[Cm^.P0 + J].X;
            Pt[J].Y := Pts[Cm^.P0 + J].Y - T;
          end;
          if Cm^.Kind = dkPoly then
            B.FillPolyAntialias(Copy(Pt, 0, Cm^.PN), Cm^.C)
          else
            B.DrawPolyLineAntialias(Copy(Pt, 0, Cm^.PN), Cm^.C, Cm^.W);
        end;
      dkLine:
        B.DrawLineAntialias(Cm^.X1, Cm^.Y1 - T, Cm^.X2, Cm^.Y2 - T, Cm^.C, Cm^.W);
      dkShadow: DrawShadow(B, Cm^, BandTop, CR);
      dkGlow: DrawGlow(B, Cm^, BandTop, CR);
      dkVGrad: DrawVGrad(B, Cm^, BandTop, CR);
      dkText: DrawText(B, Glyphs, Cm^, BandTop, CR);
      dkImage:
        if (Cm^.Img.Width = Round(Cm^.X2) - Round(Cm^.X1)) and (Cm^.Img.Height = Round(Cm^.Y2) - Round(Cm^.Y1)) then
          B.PutImage(Round(Cm^.X1), Round(Cm^.Y1) - BandTop, Cm^.Img, dmDrawWithTransparency)
        else
          B.StretchPutImage(Types.Rect(Round(Cm^.X1), Round(Cm^.Y1) - BandTop, Round(Cm^.X2), Round(Cm^.Y2) - BandTop),
            Cm^.Img, dmDrawWithTransparency);
    end;
  end;
  B.NoClip;
  B.InvalidateBitmap;
end;

{ ---------- grain ---------- }

procedure MakeGrain(var G: array of ShortInt; W, Y0, Y1: Integer);
var
  X, Y: Integer;
  Hs, H2: LongWord;
begin
  for Y := Y0 to Y1 - 1 do
    for X := 0 to W - 1 do
    begin
      Hs := (LongWord(X) * 73856093) xor (LongWord(Y) * 19349663);
      Hs := Hs * 2654435761;
      Hs := Hs xor (Hs shr 15);
      H2 := (LongWord(X div 3) * 83492791) xor (LongWord(Y div 2) * 2971215073);
      H2 := H2 * 2246822519;
      H2 := H2 xor (H2 shr 13);
      G[Y * W + X] := Integer((Hs shr 8) and 7) - 4 + Integer((H2 shr 9) and 7) - 3;
    end;
end;

procedure ApplyGrain(B: TBGRABitmap; BandTop: Integer; const G: array of ShortInt; FrameW: Integer);
var
  X, Y, V, T, W: Integer;
  P: PBGRAPixel;
  Base: Integer;
begin
  W := Min(B.Width, FrameW);
  for Y := 0 to B.Height - 1 do
  begin
    P := RowPtr(B, Y);
    Base := (BandTop + Y) * FrameW;
    if Base + W > Length(G) then Break;
    for X := 0 to W - 1 do
    begin
      if P^.alpha > 0 then
      begin
        V := G[Base + X];
        T := P^.red + V;
        if T < 0 then T := 0 else if T > 255 then T := 255;
        P^.red := T;
        T := P^.green + V;
        if T < 0 then T := 0 else if T > 255 then T := 255;
        P^.green := T;
        T := P^.blue + V;
        if T < 0 then T := 0 else if T > 255 then T := 255;
        P^.blue := T;
      end;
      Inc(P);
    end;
  end;
  B.InvalidateBitmap;
end;

{ ---------- SVG ---------- }

function SvgNum(V: Single): string;
var
  FS: TFormatSettings;
begin
  FS := DefaultFormatSettings;
  FS.DecimalSeparator := '.';
  Result := FormatFloat('0.##', V, FS);
end;

function SvgColor(C: TBGRAPixel): string;
var
  FS: TFormatSettings;
begin
  FS := DefaultFormatSettings;
  FS.DecimalSeparator := '.';
  Result := Format('fill="#%.2x%.2x%.2x"', [C.red, C.green, C.blue]);
  if C.alpha < 255 then Result := Result + ' fill-opacity="' + FormatFloat('0.###', C.alpha / 255, FS) + '"';
end;

function StrokeColor(C: TBGRAPixel; W: Single): string;
var
  FS: TFormatSettings;
begin
  FS := DefaultFormatSettings;
  FS.DecimalSeparator := '.';
  Result := Format('fill="none" stroke="#%.2x%.2x%.2x" stroke-width="%s"', [C.red, C.green, C.blue, SvgNum(W)]);
  if C.alpha < 255 then Result := Result + ' stroke-opacity="' + FormatFloat('0.###', C.alpha / 255, FS) + '"';
end;

function SvgEsc(const S: string): string;
begin
  Result := StringReplace(S, '&', '&amp;', [rfReplaceAll]);
  Result := StringReplace(Result, '<', '&lt;', [rfReplaceAll]);
  Result := StringReplace(Result, '>', '&gt;', [rfReplaceAll]);
  Result := StringReplace(Result, '"', '&quot;', [rfReplaceAll]);
end;

procedure TDisplayList.ToSvg(SL: TStrings; Layers: TLayerSet; var DefId: Integer);
var
  K, J: Integer;
  Cm: PCmd;
  S: string;
  F: TGlyphFont;
  InClip: Boolean;
  Id: string;
begin
  InClip := False;
  for K := 0 to N - 1 do
  begin
    Cm := @Cmds[K];
    case Cm^.Kind of
      dkClip:
        begin
          if InClip then SL.Add('</g>');
          Inc(DefId);
          Id := 'c' + IntToStr(DefId);
          SL.Add(Format('<clipPath id="%s"><rect x="%s" y="%s" width="%s" height="%s"/></clipPath><g clip-path="url(#%s)">',
            [Id, SvgNum(Cm^.X1), SvgNum(Cm^.Y1), SvgNum(Cm^.X2 - Cm^.X1), SvgNum(Cm^.Y2 - Cm^.Y1), Id]));
          InClip := True;
          Continue;
        end;
      dkUnclip:
        begin
          if InClip then SL.Add('</g>');
          InClip := False;
          Continue;
        end;
    end;
    if not (Cm^.Layer in Layers) then Continue;
    case Cm^.Kind of
      dkRect:
        SL.Add(Format('<rect x="%s" y="%s" width="%s" height="%s" %s/>', [SvgNum(Cm^.X1), SvgNum(Cm^.Y1),
          SvgNum(Cm^.X2 - Cm^.X1), SvgNum(Cm^.Y2 - Cm^.Y1), SvgColor(Cm^.C)]));
      dkRRect:
        SL.Add(Format('<rect x="%s" y="%s" width="%s" height="%s" rx="%s" %s/>', [SvgNum(Cm^.X1), SvgNum(Cm^.Y1),
          SvgNum(Cm^.X2 - Cm^.X1), SvgNum(Cm^.Y2 - Cm^.Y1), SvgNum(Cm^.R), SvgColor(Cm^.C)]));
      dkRRectLine:
        SL.Add(Format('<rect x="%s" y="%s" width="%s" height="%s" rx="%s" %s/>', [SvgNum(Cm^.X1), SvgNum(Cm^.Y1),
          SvgNum(Cm^.X2 - Cm^.X1), SvgNum(Cm^.Y2 - Cm^.Y1), SvgNum(Cm^.R), StrokeColor(Cm^.C, Cm^.W)]));
      dkEllipse:
        SL.Add(Format('<ellipse cx="%s" cy="%s" rx="%s" ry="%s" %s/>', [SvgNum(Cm^.X1), SvgNum(Cm^.Y1),
          SvgNum(Cm^.X2), SvgNum(Cm^.Y2), SvgColor(Cm^.C)]));
      dkEllipseLine:
        SL.Add(Format('<ellipse cx="%s" cy="%s" rx="%s" ry="%s" %s/>', [SvgNum(Cm^.X1), SvgNum(Cm^.Y1),
          SvgNum(Cm^.X2), SvgNum(Cm^.Y2), StrokeColor(Cm^.C, Cm^.W)]));
      dkPoly, dkPolyLine:
        begin
          S := '';
          for J := 0 to Cm^.PN - 1 do
            S := S + SvgNum(Pts[Cm^.P0 + J].X) + ',' + SvgNum(Pts[Cm^.P0 + J].Y) + ' ';
          if Cm^.Kind = dkPoly then
            SL.Add(Format('<polygon points="%s" %s/>', [Trim(S), SvgColor(Cm^.C)]))
          else
            SL.Add(Format('<polyline points="%s" %s stroke-linejoin="round"/>', [Trim(S), StrokeColor(Cm^.C, Cm^.W)]));
        end;
      dkLine:
        SL.Add(Format('<line x1="%s" y1="%s" x2="%s" y2="%s" %s stroke-linecap="round"/>', [SvgNum(Cm^.X1),
          SvgNum(Cm^.Y1), SvgNum(Cm^.X2), SvgNum(Cm^.Y2), StrokeColor(Cm^.C, Cm^.W)]));
      dkShadow:
        begin
          Inc(DefId);
          Id := 'b' + IntToStr(DefId);
          SL.Add(Format('<filter id="%s" x="-20%%" y="-20%%" width="140%%" height="140%%"><feGaussianBlur stdDeviation="%s"/></filter>',
            [Id, SvgNum(Cm^.W / 2)]));
          SL.Add(Format('<rect x="%s" y="%s" width="%s" height="%s" rx="%s" %s filter="url(#%s)"/>', [SvgNum(Cm^.X1),
            SvgNum(Cm^.Y1), SvgNum(Cm^.X2 - Cm^.X1), SvgNum(Cm^.Y2 - Cm^.Y1), SvgNum(Cm^.R), SvgColor(Cm^.C), Id]));
        end;
      dkGlow:
        begin
          Inc(DefId);
          Id := 'g' + IntToStr(DefId);
          SL.Add(Format('<radialGradient id="%s"><stop offset="0" stop-color="#%.2x%.2x%.2x" stop-opacity="%s"/>' +
            '<stop offset="1" stop-color="#%.2x%.2x%.2x" stop-opacity="0"/></radialGradient>',
            [Id, Cm^.C.red, Cm^.C.green, Cm^.C.blue, SvgNum(Cm^.C.alpha / 255), Cm^.C.red, Cm^.C.green, Cm^.C.blue]));
          SL.Add(Format('<circle cx="%s" cy="%s" r="%s" fill="url(#%s)"/>', [SvgNum(Cm^.X1), SvgNum(Cm^.Y1),
            SvgNum(Cm^.R), Id]));
        end;
      dkVGrad:
        begin
          Inc(DefId);
          Id := 'v' + IntToStr(DefId);
          SL.Add(Format('<linearGradient id="%s" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#%.2x%.2x%.2x" stop-opacity="%s"/>' +
            '<stop offset="1" stop-color="#%.2x%.2x%.2x" stop-opacity="%s"/></linearGradient>',
            [Id, Cm^.C.red, Cm^.C.green, Cm^.C.blue, SvgNum(Cm^.C.alpha / 255), Cm^.C2.red, Cm^.C2.green,
            Cm^.C2.blue, SvgNum(Cm^.C2.alpha / 255)]));
          SL.Add(Format('<rect x="%s" y="%s" width="%s" height="%s" fill="url(#%s)"/>', [SvgNum(Cm^.X1), SvgNum(Cm^.Y1),
            SvgNum(Cm^.X2 - Cm^.X1), SvgNum(Cm^.Y2 - Cm^.Y1), Id]));
        end;
      dkText:
        begin
          F := Glyphs.Font(Cm^.Font);
          if F = nil then Continue;
          S := Format('<text x="%s" y="%s" font-family="%s" font-size="%dpx"', [SvgNum(Cm^.X1),
            SvgNum(Cm^.Y1 + F.Ascent), F.Face, F.Px]);
          if F.Bold then S := S + ' font-weight="bold"';
          SL.Add(S + ' ' + SvgColor(Cm^.C) + ' xml:space="preserve">' + SvgEsc(Cm^.Text) + '</text>');
        end;
    end;
  end;
  if InClip then SL.Add('</g>');
end;

end.
