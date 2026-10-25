unit uSplash;

{ The loading picture of Virtual PLC: while the first frame of the program is made (the fonts of the glyph
  cache at the size of the window take a few seconds), the window shows a card with the logo, the name and a
  LAD rung whose power flows from the left rail through the contact into the coil, with a progress bar.

  The frames are drawn before the work starts (TSplashUI, a TUiBase of its own: one design unit is one point of
  the window, like the chat), each one a bitmap of the card only; the view shows them in turn on the paper
  colour of the window. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, Graphics, BGRABitmap, BGRABitmapTypes, uPaperDL, uUiBase;

const
  SplashCardW = 600;      // the card in points
  SplashCardH = 330;
  SplashFrames = 30;      // one loop of the animation (at 30 frames a second)
  SplashScale = 0.7;      // the card is drawn at 70 % of its points

type

  { TSplashUI }

  TSplashUI = class(TUiBase)
  private
    { the texts of a frame: drawn by BGRABitmap itself (only their letters), not with the glyph cache, whose
      fonts of all sizes are what takes the time at the start }
    FTexts: array of record
      Kind: TFontKind;
      Size, X, Y: Single;
      S: string;
      C: TBGRAPixel;
      Align: Integer;
    end;
    procedure STxt(Kind: TFontKind; Size, X, Y: Single; const S: string; C: TBGRAPixel; Align: Integer = 0);
    procedure BuildFrame(T: Single);
  public
    { the frames of the card at the display scale Density: SplashFrames bitmaps, the caller frees them }
    function MakeFrames(Density: Single; First: Integer = 0; Count: Integer = SplashFrames): TList;
  end;

implementation

procedure TSplashUI.STxt(Kind: TFontKind; Size, X, Y: Single; const S: string; C: TBGRAPixel; Align: Integer);
var
  N: Integer;
begin
  N := Length(FTexts);
  SetLength(FTexts, N + 1);
  FTexts[N].Kind := Kind;
  FTexts[N].Size := Size;
  FTexts[N].X := X;
  FTexts[N].Y := Y;
  FTexts[N].S := S;
  FTexts[N].C := C;
  FTexts[N].Align := Align;
end;

{ T: 0 .. 1, one loop }
procedure TSplashUI.BuildFrame(T: Single);
const
  RailL = 64; RailR = 536; RungY = 232; ContactX = 220; CoilX = 400;
var
  Flow, X: Single;
  K: Integer;
  CoilOn: Boolean;
  S: string;

  function WireC(X0: Single): TBGRAPixel;
  begin
    if Flow >= X0 then Result := cJade else Result := Alpha(cInkSoft, 160);
  end;

begin
  // the card
  D.Layer := lyPaper;
  Rc(0, 0, SplashCardW, SplashCardH, cPaper);
  D.Layer := lySheets;
  Shad(14, 12, SplashCardW - 28, SplashCardH - 26, 8, 3, 8, 90);
  RR(14, 12, SplashCardW - 28, SplashCardH - 26, 8, cSheet);
  RRL(20, 18, SplashCardW - 40, SplashCardH - 38, 6, 1, Alpha(cRed, 150));
  D.Layer := lyControls;
  Rc(15, 13, SplashCardW - 30, 10, Mixc(cRed, cRedDark, 0.3));
  FretStrip(15, 23, SplashCardW - 30, 7, cGoldLight, cRedDark);
  // the logo (its RUN LED blinks) and the name
  AppLogo(44, 54, 112, Frac(T * 2) < 0.6);
  D.Layer := lyText;
  STxt(fkTitle, 42, 178, 62, 'Virtual PLC', cRedDark);
  STxt(fkUI, 13.5, 182, 120, 'a simulated CPU, its program and its I/O', cInkSoft);
  // the rung: the power runs from the left rail; the contact closes, the coil pulls in
  Flow := RailL + (RailR - RailL) * Min(1, T * 1.25);
  CoilOn := Flow >= CoilX;
  D.Layer := lyControls;
  Ln(RailL, RungY - 30, RailL, RungY + 30, 3, cGoldDark);
  Ln(RailR, RungY - 30, RailR, RungY + 30, 3, cGoldDark);
  Ln(RailL, RungY, ContactX - 8, RungY, 2.4, WireC(ContactX - 8));
  Ln(ContactX - 8, RungY - 14, ContactX - 8, RungY + 14, 2.6, WireC(ContactX - 8));
  Ln(ContactX + 8, RungY - 14, ContactX + 8, RungY + 14, 2.6, WireC(ContactX + 8));
  Ln(ContactX + 8, RungY, CoilX - 16, RungY, 2.4, WireC(CoilX - 16));
  if CoilOn then El(CoilX, RungY, 15, 15, Alpha(cJade, 70));
  ElL(CoilX, RungY, 15, 15, 2.6, WireC(CoilX));
  Ln(CoilX + 16, RungY, RailR, RungY, 2.4, WireC(RailR));
  D.Layer := lyText;
  STxt(fkMono, 11, ContactX, RungY - 34, '"Start"', WireC(ContactX), 1);
  STxt(fkMono, 11, CoilX, RungY - 34, '"Motor"', WireC(CoilX), 1);
  // the head of the power
  if Flow < RailR then
  begin
    D.Layer := lyOverlay;
    GlowD(Flow, RungY, 12, Alpha(cGold, 150));
    El(Flow, RungY, 3.5, 3.5, cGold);
  end;
  // the progress bar: a gold piece runs along it
  D.Layer := lyControls;
  RR(64, 280, 472, 6, 3, Alpha(cGoldDark, 60));
  X := 64 + (472 - 120) * (0.5 - 0.5 * Cos(T * 2 * Pi));
  RR(X, 280, 120, 6, 3, cRed);
  D.Layer := lyText;
  S := 'Loading';
  for K := 1 to 1 + Trunc(T * 3) mod 3 do S := S + '.';
  STxt(fkUI, 11.5, 64, 292, S, cInkSoft);
end;

function TSplashUI.MakeFrames(Density: Single; First: Integer; Count: Integer): TList;
var
  K, J: Integer;
  X0: Single;
  DL: TDisplayList;
  B: TBGRABitmap;
begin
  Result := TList.Create;
  if Density < 0.5 then Density := 1;
  FK := Density;
  FOX := 0;
  FOY := 0;
  FW := Ceil(SplashCardW * Density);
  FH := Ceil(SplashCardH * Density);
  DL := TDisplayList.Create(FGl);
  try
    for K := First to First + Count - 1 do
    begin
      DL.Clear;
      SetLength(FTexts, 0);
      BeginFrame(DL);
      BuildFrame(K / SplashFrames);
      EndFrame;
      B := TBGRABitmap.Create(FW, FH, cPaper);
      DL.Render(B, 0, AllLayers);
      B.FontQuality := fqFineAntialiasing;
      for J := 0 to High(FTexts) do
        with FTexts[J] do
        begin
          B.FontName := FontFaces[Kind];
          B.FontHeight := Max(5, Round(Size * FK));
          if FontBold[Kind] then B.FontStyle := [fsBold] else B.FontStyle := [];
          X0 := X * FK;
          if Align = 1 then X0 := X0 - B.TextSize(S).cx / 2;
          B.TextOut(X0, Y * FK, S, C);
        end;
      Result.Add(B);
    end;
  finally
    DL.Free;
  end;
end;

end.
