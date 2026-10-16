unit uExport;

{ PNG / GIF / MP4 / SVG export of the main picture and of every layer.

  First the frames are recorded in real time: every 1 / fps the UI is advanced
  and built into fresh display lists at the export size (the PLC keeps running
  in its own thread, so timers, lamps and analog values move as they do on
  screen). Then every target is rendered from the recorded lists on all cores:
    main     all layers with the paper grain
    a layer  only that layer on a transparent background (PNG, GIF, SVG keep
             the transparency, MP4 is flattened on white)
  PNG and SVG are written for the first frame, GIF and MP4 for all frames. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, BGRABitmap, BGRABitmapTypes, BGRAAnimatedGif, BGRAPalette, BGRAColorQuantization,
  uRenderPool, uPaperDL, uUi, uMFVideo, uPlcRuntime;

type
  TExportTarget = (etMain, etPaper, etSheets, etOrnament, etControls, etText, etOverlay);
  TExportTargets = set of TExportTarget;

  TExportOptions = record
    Folder: string;
    Width, Height, Frames, Fps, Kbps: Integer;
    Png, Gif, Mp4, Svg: Boolean;
    Targets: TExportTargets;
  end;

  TExportProgress = procedure(const Msg: string; Done, Total: Integer; var Cancel: Boolean) of object;

const
  TargetNames: array[TExportTarget] of string = ('main', 'layer_paper', 'layer_sheets', 'layer_ornaments',
    'layer_controls', 'layer_text', 'layer_overlay');

function DefaultExportOptions: TExportOptions;
function RunExport(UI: TPlcUI; Pool: TRenderPool; const Opt: TExportOptions; WinW, WinH: Integer;
  Progress: TExportProgress): TStringList;

implementation

type

  { TExportRender: one frame of display lists into a full bitmap, by bands on the pool }

  TExportRender = class
  public
    W, H, BandH: Integer;
    Bands: array of TBGRABitmap;
    Grain: array of ShortInt;
    GrainDone: Boolean;
    S, Dn: TDisplayList;
    Layers: TLayerSet;
    Opaque, UseGrain: Boolean;
    Paper: TBGRAPixel;
    constructor Create(AW, AH, ACount: Integer);
    destructor Destroy; override;
    procedure Job(AIndex, AWorker: Integer);
    procedure Render(Pool: TRenderPool; Dest: TBGRABitmap);
  end;

constructor TExportRender.Create(AW, AH, ACount: Integer);
var
  I, Top: Integer;
begin
  inherited Create;
  W := AW;
  H := AH;
  ACount := Max(1, ACount);
  BandH := Max(8, (H + ACount - 1) div ACount);
  ACount := (H + BandH - 1) div BandH;
  SetLength(Bands, ACount);
  Top := 0;
  for I := 0 to ACount - 1 do
  begin
    Bands[I] := TBGRABitmap.Create(W, Min(BandH, H - Top));
    Inc(Top, BandH);
  end;
  SetLength(Grain, W * H);
  Paper := BGRA(246, 238, 222);
end;

destructor TExportRender.Destroy;
var
  I: Integer;
begin
  for I := 0 to High(Bands) do Bands[I].Free;
  inherited Destroy;
end;

procedure TExportRender.Job(AIndex, AWorker: Integer);
var
  B: TBGRABitmap;
  Top: Integer;
begin
  B := Bands[AIndex];
  Top := AIndex * BandH;
  if not GrainDone then MakeGrain(Grain, W, Top, Top + B.Height);
  if Opaque then B.Fill(Paper) else B.FillTransparent;
  if S <> nil then S.Render(B, Top, Layers);
  if Dn <> nil then Dn.Render(B, Top, Layers);
  if UseGrain then ApplyGrain(B, Top, Grain, W);
end;

procedure TExportRender.Render(Pool: TRenderPool; Dest: TBGRABitmap);
var
  I, Y: Integer;
begin
  Pool.Run(Length(Bands), @Job);
  GrainDone := True;
  Dest.SetSize(W, H);
  for I := 0 to High(Bands) do
    for Y := 0 to Bands[I].Height - 1 do
      Move(RowPtr(Bands[I], Y)^, RowPtr(Dest, I * BandH + Y)^, W * SizeOf(TBGRAPixel));
  Dest.InvalidateBitmap;
end;

function DefaultExportOptions: TExportOptions;
begin
  Result.Folder := ExtractFilePath(ParamStr(0)) + 'export';
  Result.Width := 1600;
  Result.Height := 900;
  Result.Frames := 60;
  Result.Fps := 20;
  Result.Kbps := 12000;
  Result.Png := True;
  Result.Gif := True;
  Result.Mp4 := True;
  Result.Svg := True;
  Result.Targets := [Low(TExportTarget)..High(TExportTarget)];
end;

procedure WriteSvg(const AFile: string; S, Dn: TDisplayList; Layers: TLayerSet; W, H: Integer;
  Main: Boolean; const Title: string);
var
  SL: TStringList;
  Id: Integer;
begin
  SL := TStringList.Create;
  try
    SL.Add('<?xml version="1.0" encoding="UTF-8"?>');
    SL.Add(Format('<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 %d %d">',
      [W, H, W, H]));
    SL.Add('<title>' + SvgEsc(Title) + '</title>');
    Id := 0;
    if S <> nil then S.ToSvg(SL, Layers, Id);
    if Dn <> nil then Dn.ToSvg(SL, Layers, Id);
    if Main then
    begin
      // the paper grain as a noise filter over everything
      SL.Add('<filter id="grain" x="0" y="0" width="100%" height="100%"><feTurbulence type="fractalNoise" ' +
        'baseFrequency="0.85" numOctaves="2" seed="7"/><feColorMatrix type="saturate" values="0"/></filter>');
      SL.Add(Format('<rect x="0" y="0" width="%d" height="%d" filter="url(#grain)" opacity="0.07"/>', [W, H]));
    end;
    SL.Add('</svg>');
    SL.SaveToFile(AFile);
  finally
    SL.Free;
  end;
end;

function RunExport(UI: TPlcUI; Pool: TRenderPool; const Opt: TExportOptions; WinW, WinH: Integer;
  Progress: TExportProgress): TStringList;
var
  W, H, NF, F, Total, Done, I: Integer;
  Statics: TList;
  FrameStatic: array of TDisplayList;
  Dyns: array of TDisplayList;
  S, Dn, Last: TDisplayList;
  T0, Due: Double;
  Cancel: Boolean;
  Tg: TExportTarget;
  R: TExportRender;
  Frame, Flat: TBGRABitmap;
  Gif: TBGRAAnimatedGif;
  Mp4: TMp4Writer;
  Stem, Name, Why: string;
  Layers: TLayerSet;
  Delay: Integer;

  procedure Report(const Msg: string);
  begin
    if Assigned(Progress) then Progress(Msg, Done, Total, Cancel);
  end;

begin
  Result := TStringList.Create;
  // GIF needs a colour quantizer (more than 256 colours per frame)
  if BGRAColorQuantizerFactory = nil then BGRAColorQuantizerFactory := TBGRAColorQuantizer;
  W := Max(64, Opt.Width) div 2 * 2;
  H := Max(64, Opt.Height) div 2 * 2;
  NF := Max(1, Opt.Frames);
  ForceDirectories(Opt.Folder);
  Cancel := False;
  Done := 0;
  Total := NF;
  for Tg := Low(TExportTarget) to High(TExportTarget) do
    if Tg in Opt.Targets then Inc(Total, NF);
  Statics := TList.Create;
  SetLength(FrameStatic, NF);
  SetLength(Dyns, NF);
  Last := nil;
  R := nil;
  Frame := TBGRABitmap.Create(W, H);
  Flat := TBGRABitmap.Create(W, H);
  try
    // ---------- record ----------
    UI.SetSize(W, H);
    UI.InvalidateStatic;
    T0 := PlcNowMs;
    for F := 0 to NF - 1 do
    begin
      Due := T0 + F * 1000 / Max(1, Opt.Fps);
      while PlcNowMs < Due do
      begin
        Report(Format('recording frame %d / %d', [F + 1, NF]));
        if Cancel then Break;
        Sleep(1);
      end;
      if Cancel then Break;
      if F > 0 then UI.Update(1 / Max(1, Opt.Fps));
      S := TDisplayList.Create(UI.Glyphs);
      Dn := TDisplayList.Create(UI.Glyphs);
      if UI.Build(S, Dn) or (Last = nil) then
      begin
        Statics.Add(S);
        Last := S;
      end
      else
        S.Free;
      FrameStatic[F] := Last;
      Dyns[F] := Dn;
      Inc(Done);
    end;
    UI.SetSize(WinW, WinH);
    UI.InvalidateStatic;
    if Cancel then
    begin
      Result.Add('cancelled');
      Exit;
    end;
    Result.Add(Format('%d x %d, %d frames at %d fps recorded (%d static lists)', [W, H, NF, Opt.Fps, Statics.Count]));

    // ---------- render every target ----------
    R := TExportRender.Create(W, H, Pool.ActiveThreads * 2);
    Delay := Round(1000 / Max(1, Opt.Fps));
    for Tg := Low(TExportTarget) to High(TExportTarget) do
    begin
      if not (Tg in Opt.Targets) then Continue;
      Stem := 'vplc_' + TargetNames[Tg];
      if Tg = etMain then Layers := AllLayers else Layers := [TLayer(Ord(Tg) - 1)];
      R.Layers := Layers;
      R.Opaque := Tg = etMain;
      R.UseGrain := True;
      Gif := nil;
      Mp4 := nil;
      try
        if Opt.Gif and (NF > 1) then
        begin
          Gif := TBGRAAnimatedGif.Create;
          Gif.SetSize(W, H);
          Gif.LoopCount := 0;
        end;
        if Opt.Mp4 and (NF > 1) then
        begin
          if MP4Available(Why) then
          try
            Mp4 := TMp4Writer.Create(IncludeTrailingPathDelimiter(Opt.Folder) + Stem + '.mp4', W, H, Opt.Fps,
              Opt.Kbps, True);
          except
            on E: Exception do
            begin
              Result.Add('MP4 ' + Stem + ': ' + E.Message);
              Mp4 := nil;
            end;
          end
          else
            Result.Add('MP4 not available: ' + Why);
        end;
        for F := 0 to NF - 1 do
        begin
          R.S := FrameStatic[F];
          R.Dn := Dyns[F];
          R.Render(Pool, Frame);
          if (F = 0) and Opt.Png then
          begin
            Name := IncludeTrailingPathDelimiter(Opt.Folder) + Stem + '.png';
            Frame.SaveToFile(Name);
            Result.Add(Name);
          end;
          if (F = 0) and Opt.Svg then
          begin
            Name := IncludeTrailingPathDelimiter(Opt.Folder) + Stem + '.svg';
            WriteSvg(Name, FrameStatic[F], Dyns[F], Layers, W, H, Tg = etMain, 'Virtual PLC - ' + TargetNames[Tg]);
            Result.Add(Name);
          end;
          if Gif <> nil then Gif.AddFullFrame(Frame, Delay, True);
          if Mp4 <> nil then
          try
            Flat.Fill(BGRAWhite);
            Flat.PutImage(0, 0, Frame, dmDrawWithTransparency);
            Mp4.AddFrame(Flat);
          except
            on E: Exception do
            begin
              Result.Add('MP4 ' + Stem + ' frame ' + IntToStr(F) + ': ' + E.Message);
              FreeAndNil(Mp4);
            end;
          end;
          Inc(Done);
          Report(Format('%s  frame %d / %d', [TargetNames[Tg], F + 1, NF]));
          if Cancel then Break;
        end;
        if Gif <> nil then
        begin
          Report('writing ' + Stem + '.gif');
          Name := IncludeTrailingPathDelimiter(Opt.Folder) + Stem + '.gif';
          try
            Gif.SaveToFile(Name);
            Result.Add(Name);
          except
            on E: Exception do Result.Add('GIF ' + Stem + ': ' + E.Message);
          end;
        end;
        if Mp4 <> nil then
        try
          Mp4.Finish;
          Result.Add(IncludeTrailingPathDelimiter(Opt.Folder) + Stem + '.mp4');
        except
          on E: Exception do Result.Add('MP4 ' + Stem + ': ' + E.Message);
        end;
      finally
        Gif.Free;
        Mp4.Free;
      end;
      if Cancel then Break;
    end;
    if Cancel then Result.Add('cancelled');
  finally
    R.Free;
    Frame.Free;
    Flat.Free;
    for I := 0 to Statics.Count - 1 do TDisplayList(Statics[I]).Free;
    Statics.Free;
    for I := 0 to High(Dyns) do Dyns[I].Free;
  end;
end;

end.
