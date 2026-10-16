unit uFrame;

{ Renders a frame on all cores.

  The frame is cut into horizontal bands (BandsPerThread x threads); the
  workers of the pool take the bands one after the other. Every band has two
  bitmaps:
    Static  the paper backdrop and the fixed cards of the screen, rendered from
            the static display list only when it changed (screen switch, resize)
    Band    each frame: a copy of Static, the dynamic display list on top, then
            the paper grain
  Bands stay separate bitmaps: the SDL window uploads them straight into its
  streaming texture; Assemble glues them for a PNG.

  Start / Wait split the frame so the main thread can upload the last frame and
  wait for vsync while the workers render the next one. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, BGRABitmap, BGRABitmapTypes, uRenderPool, uPaperDL;

const
  MaxThreads = 32;

type

  { TFrameRenderer }

  TFrameRenderer = class
  private
    FPool: TRenderPool;
    FBands, FStatic: array of TBGRABitmap;
    FBandTop: array of Integer;
    FWidth, FHeight, FBandsPerThread: Integer;
    FRendering, FStaticDirty, FGrainDirty: Boolean;
    FGrain: array of ShortInt;
    FStaticList, FDynList: TDisplayList;
    FKick: Double;
    FPaper: TBGRAPixel;
    procedure BandJob(AIndex, AWorker: Integer);
    procedure BuildBands;
    procedure FreeBands;
    function GetBand(I: Integer): TBGRABitmap;
    function GetBandTop(I: Integer): Integer;
    function GetBandCount: Integer;
    function GetThreads: Integer;
  public
    RenderWallMs, RenderCpuMs, WallSmooth, CpuSmooth: Double;
    StaticMs: Double;            // last static re-render (wall)
    StaticRenders: Integer;
    BandMs: array of Double;
    BandWorker: array of Integer;
    WorkerMs: array of Double;
    Frames: Int64;
    Grain: Boolean;
    constructor Create(AThreads, ABandsPerThread: Integer);
    destructor Destroy; override;
    procedure SetSize(AWidth, AHeight: Integer);
    procedure SetThreads(AThreads: Integer);
    procedure SetBandsPerThread(AValue: Integer);
    { the static list is rendered again when StaticChanged }
    procedure Start(AStatic, ADyn: TDisplayList; StaticChanged: Boolean);
    procedure Wait;
    procedure Assemble(Dest: TBGRABitmap);
    property Pool: TRenderPool read FPool;
    property Width: Integer read FWidth;
    property Height: Integer read FHeight;
    property Threads: Integer read GetThreads;
    property BandsPerThread: Integer read FBandsPerThread;
    property BandCount: Integer read GetBandCount;
    property Bands[I: Integer]: TBGRABitmap read GetBand;
    property BandTops[I: Integer]: Integer read GetBandTop;
    property Rendering: Boolean read FRendering;
    property Paper: TBGRAPixel read FPaper write FPaper;
  end;

implementation

constructor TFrameRenderer.Create(AThreads, ABandsPerThread: Integer);
begin
  inherited Create;
  FBandsPerThread := Max(1, ABandsPerThread);
  FPool := TRenderPool.Create(MaxThreads);
  FPool.ActiveThreads := EnsureRange(AThreads, 1, MaxThreads);
  SetLength(WorkerMs, MaxThreads);
  FPaper := BGRA(246, 238, 222);
  Grain := True;
end;

destructor TFrameRenderer.Destroy;
begin
  Wait;
  FPool.Free;
  FreeBands;
  inherited Destroy;
end;

procedure TFrameRenderer.FreeBands;
var
  I: Integer;
begin
  for I := 0 to High(FBands) do
  begin
    FBands[I].Free;
    FStatic[I].Free;
  end;
  SetLength(FBands, 0);
  SetLength(FStatic, 0);
  SetLength(FBandTop, 0);
end;

procedure TFrameRenderer.BuildBands;
var
  Count, I, Top, BH: Integer;
begin
  FreeBands;
  if (FWidth < 1) or (FHeight < 1) then Exit;
  Count := Max(1, FPool.ActiveThreads * FBandsPerThread);
  BH := Max(8, ((FHeight + Count - 1) div Count + 3) div 4 * 4);
  Count := (FHeight + BH - 1) div BH;
  SetLength(FBands, Count);
  SetLength(FStatic, Count);
  SetLength(FBandTop, Count);
  Top := 0;
  for I := 0 to Count - 1 do
  begin
    FBandTop[I] := Top;
    FBands[I] := TBGRABitmap.Create(FWidth, Min(BH, FHeight - Top));
    FStatic[I] := TBGRABitmap.Create(FWidth, Min(BH, FHeight - Top));
    Inc(Top, BH);
  end;
  SetLength(BandMs, Count);
  SetLength(BandWorker, Count);
  FStaticDirty := True;
end;

procedure TFrameRenderer.SetSize(AWidth, AHeight: Integer);
begin
  Wait;
  AWidth := Max(1, AWidth);
  AHeight := Max(1, AHeight);
  if (AWidth = FWidth) and (AHeight = FHeight) then Exit;
  FWidth := AWidth;
  FHeight := AHeight;
  SetLength(FGrain, 0);
  SetLength(FGrain, FWidth * FHeight);
  FGrainDirty := True;
  BuildBands;
end;

procedure TFrameRenderer.SetThreads(AThreads: Integer);
begin
  Wait;
  AThreads := EnsureRange(AThreads, 1, MaxThreads);
  if AThreads = FPool.ActiveThreads then Exit;
  FPool.ActiveThreads := AThreads;
  BuildBands;
end;

procedure TFrameRenderer.SetBandsPerThread(AValue: Integer);
begin
  Wait;
  AValue := EnsureRange(AValue, 1, 16);
  if AValue = FBandsPerThread then Exit;
  FBandsPerThread := AValue;
  BuildBands;
end;

procedure TFrameRenderer.BandJob(AIndex, AWorker: Integer);
var
  B, S: TBGRABitmap;
  Top: Integer;
begin
  B := FBands[AIndex];
  S := FStatic[AIndex];
  Top := FBandTop[AIndex];
  if FGrainDirty then MakeGrain(FGrain, FWidth, Top, Top + B.Height);
  if FStaticDirty then
  begin
    S.Fill(FPaper);
    if FStaticList <> nil then FStaticList.Render(S, Top, AllLayers);
  end;
  Move(S.Data^, B.Data^, S.NbPixels * SizeOf(TBGRAPixel));
  B.InvalidateBitmap;
  if FDynList <> nil then FDynList.Render(B, Top, AllLayers);
  if Grain then ApplyGrain(B, Top, FGrain, FWidth);
end;

procedure TFrameRenderer.Start(AStatic, ADyn: TDisplayList; StaticChanged: Boolean);
begin
  Wait;
  if (FWidth < 1) or (Length(FBands) = 0) then Exit;
  FStaticList := AStatic;
  FDynList := ADyn;
  if StaticChanged then FStaticDirty := True;
  FKick := HiResMs;
  FRendering := True;
  FPool.Start(Length(FBands), @BandJob);
end;

procedure TFrameRenderer.Wait;
var
  I: Integer;
begin
  if not FRendering then Exit;
  FPool.Wait;
  FRendering := False;
  Inc(Frames);
  RenderWallMs := FPool.FinishTime - FKick;
  if FStaticDirty then
  begin
    StaticMs := RenderWallMs;
    Inc(StaticRenders);
  end;
  FStaticDirty := False;
  FGrainDirty := False;
  RenderCpuMs := 0;
  for I := 0 to FPool.ActiveThreads - 1 do
  begin
    WorkerMs[I] := FPool.WorkerMs[I];
    RenderCpuMs := RenderCpuMs + WorkerMs[I];
  end;
  for I := 0 to High(BandMs) do
  begin
    BandMs[I] := FPool.JobMs[I];
    BandWorker[I] := FPool.JobWorker[I];
  end;
  WallSmooth := WallSmooth * 0.9 + RenderWallMs * 0.1;
  CpuSmooth := CpuSmooth * 0.9 + RenderCpuMs * 0.1;
end;

procedure TFrameRenderer.Assemble(Dest: TBGRABitmap);
var
  I, Y: Integer;
begin
  Wait;
  Dest.SetSize(FWidth, FHeight);
  for I := 0 to High(FBands) do
    for Y := 0 to FBands[I].Height - 1 do
      Move(RowPtr(FBands[I], Y)^, RowPtr(Dest, FBandTop[I] + Y)^, FWidth * SizeOf(TBGRAPixel));
  Dest.InvalidateBitmap;
end;

function TFrameRenderer.GetBand(I: Integer): TBGRABitmap;
begin
  Result := FBands[I];
end;

function TFrameRenderer.GetBandTop(I: Integer): Integer;
begin
  Result := FBandTop[I];
end;

function TFrameRenderer.GetBandCount: Integer;
begin
  Result := Length(FBands);
end;

function TFrameRenderer.GetThreads: Integer;
begin
  Result := FPool.ActiveThreads;
end;

end.
