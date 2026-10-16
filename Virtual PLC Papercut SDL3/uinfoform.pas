unit uInfoForm;

{ Developer information window (opens at startup beside the PLC window; F1
  brings it back). Built in code, no .lfm.
    Overview     what the program is, the pipeline, files, keys
    Performance  fps, vsync, frame history graph, render / build / upload times,
                 threads and bands
    PLC          the virtual CPU: mode, cycle statistics, memory, forces,
                 instruction mix, the program
    Export       PNG / GIF / MP4 / SVG of the main picture and every layer }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, StrUtils, Forms, Controls, Graphics, StdCtrls, ExtCtrls, ComCtrls, Spin,
  CheckLst, LCLIntf, BGRABitmap, BGRABitmapTypes, uRenderPool, uPaperDL, uFrame, uUi, uExport,
  uPlcTypes, uPlcProject, uPlcCompiler, uPlcRuntime, uMFVideo;

type

  { TInfoForm }

  TInfoForm = class(TForm)
  private
    FPages: TPageControl;
    FOverview, FPlcText, FExpLog: TMemo;
    FPerfBox: TPaintBox;
    FPerfText: TMemo;
    FThreadSpin, FBandSpin: TSpinEdit;
    FVSyncCheck, FGrainCheck: TCheckBox;
    FExpFolder: TEdit;
    FExpW, FExpH, FExpFrames, FExpFps, FExpKbps: TSpinEdit;
    FExpPng, FExpGif, FExpMp4, FExpSvg: TCheckBox;
    FExpTargets: TCheckListBox;
    FExpProgress: TProgressBar;
    FExpRun, FExpCancel: TButton;
    FExpCancelled, FExpBusy: Boolean;
    FTimer: TTimer;
    FUpdating: Boolean;
    FBuf: TBitmap;
    function AddTab(const ACaption: string): TTabSheet;
    function AddLabel(AParent: TWinControl; const ACaption: string; X, Y: Integer): TLabel;
    function AddSpin(AParent: TWinControl; X, Y, AMin, AMax, AValue: Integer): TSpinEdit;
    procedure TimerTick(Sender: TObject);
    procedure PerfPaint(Sender: TObject);
    procedure ThreadsChanged(Sender: TObject);
    procedure VSyncChanged(Sender: TObject);
    procedure GrainChanged(Sender: TObject);
    procedure ExpRunClick(Sender: TObject);
    procedure ExpCancelClick(Sender: TObject);
    procedure ExpProgress(const Msg: string; Done, Total: Integer; var Cancel: Boolean);
    procedure FormKey(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure FormClose(Sender: TObject; var CloseAction: TCloseAction);
    procedure FillOverview;
    procedure UpdatePlcText;
    procedure UpdatePerfText;
  public
    constructor Create(TheOwner: TComponent); override;
    destructor Destroy; override;
    procedure ShowExportTab;
  end;

var
  InfoForm: TInfoForm;

implementation

uses
  uSDLView;

constructor TInfoForm.Create(TheOwner: TComponent);
var
  T: TTabSheet;
  P: TPanel;
  Tg: TExportTarget;
begin
  inherited CreateNew(TheOwner, 0);
  Caption := 'Virtual PLC - developer information';
  Width := 560;
  Height := 760;
  Position := poDesigned;
  KeyPreview := True;
  OnKeyDown := @FormKey;
  OnClose := @FormClose;
  FBuf := TBitmap.Create;
  FPages := TPageControl.Create(Self);
  FPages.Parent := Self;
  FPages.Align := alClient;

  // ---------- overview ----------
  T := AddTab('Overview');
  FOverview := TMemo.Create(Self);
  FOverview.Parent := T;
  FOverview.Align := alClient;
  FOverview.ReadOnly := True;
  FOverview.ScrollBars := ssAutoVertical;
  FOverview.Font.Name := 'Consolas';
  FOverview.Font.Size := 9;
  FillOverview;

  // ---------- performance ----------
  T := AddTab('Performance');
  P := TPanel.Create(Self);
  P.Parent := T;
  P.Align := alTop;
  P.Height := 64;
  P.BevelOuter := bvNone;
  AddLabel(P, 'render threads', 8, 10);
  FThreadSpin := AddSpin(P, 100, 6, 1, MaxThreads, PhysicalCores);
  FThreadSpin.OnChange := @ThreadsChanged;
  AddLabel(P, 'bands / thread', 180, 10);
  FBandSpin := AddSpin(P, 270, 6, 1, 16, 2);
  FBandSpin.OnChange := @ThreadsChanged;
  FVSyncCheck := TCheckBox.Create(Self);
  FVSyncCheck.Parent := P;
  FVSyncCheck.SetBounds(350, 8, 120, 22);
  FVSyncCheck.Caption := 'vsync (60 Hz)';
  FVSyncCheck.Checked := True;
  FVSyncCheck.OnChange := @VSyncChanged;
  FGrainCheck := TCheckBox.Create(Self);
  FGrainCheck.Parent := P;
  FGrainCheck.SetBounds(350, 34, 120, 22);
  FGrainCheck.Caption := 'paper grain';
  FGrainCheck.Checked := True;
  FGrainCheck.OnChange := @GrainChanged;
  FPerfBox := TPaintBox.Create(Self);
  FPerfBox.Parent := T;
  FPerfBox.Align := alTop;
  FPerfBox.Height := 230;
  FPerfBox.OnPaint := @PerfPaint;
  FPerfText := TMemo.Create(Self);
  FPerfText.Parent := T;
  FPerfText.Align := alClient;
  FPerfText.ReadOnly := True;
  FPerfText.Font.Name := 'Consolas';
  FPerfText.Font.Size := 9;

  // ---------- PLC ----------
  T := AddTab('PLC');
  FPlcText := TMemo.Create(Self);
  FPlcText.Parent := T;
  FPlcText.Align := alClient;
  FPlcText.ReadOnly := True;
  FPlcText.ScrollBars := ssAutoVertical;
  FPlcText.Font.Name := 'Consolas';
  FPlcText.Font.Size := 9;

  // ---------- export ----------
  T := AddTab('Export');
  AddLabel(T, 'folder', 8, 12);
  FExpFolder := TEdit.Create(Self);
  FExpFolder.Parent := T;
  FExpFolder.SetBounds(70, 8, 460, 24);
  FExpFolder.Text := DefaultExportOptions.Folder;
  AddLabel(T, 'width', 8, 44);
  FExpW := AddSpin(T, 70, 40, 64, 7680, 1600);
  AddLabel(T, 'height', 160, 44);
  FExpH := AddSpin(T, 210, 40, 64, 4320, 900);
  AddLabel(T, 'frames', 300, 44);
  FExpFrames := AddSpin(T, 350, 40, 1, 2000, 40);
  AddLabel(T, 'fps', 440, 44);
  FExpFps := AddSpin(T, 470, 40, 1, 60, 20);
  AddLabel(T, 'MP4 kbit/s', 8, 76);
  FExpKbps := AddSpin(T, 90, 72, 500, 100000, 12000);
  FExpPng := TCheckBox.Create(Self);
  FExpPng.Parent := T;
  FExpPng.SetBounds(200, 74, 60, 22);
  FExpPng.Caption := 'PNG';
  FExpPng.Checked := True;
  FExpGif := TCheckBox.Create(Self);
  FExpGif.Parent := T;
  FExpGif.SetBounds(260, 74, 60, 22);
  FExpGif.Caption := 'GIF';
  FExpGif.Checked := True;
  FExpMp4 := TCheckBox.Create(Self);
  FExpMp4.Parent := T;
  FExpMp4.SetBounds(320, 74, 60, 22);
  FExpMp4.Caption := 'MP4';
  FExpMp4.Checked := True;
  FExpSvg := TCheckBox.Create(Self);
  FExpSvg.Parent := T;
  FExpSvg.SetBounds(380, 74, 60, 22);
  FExpSvg.Caption := 'SVG';
  FExpSvg.Checked := True;
  AddLabel(T, 'targets: the main picture and every layer', 8, 106);
  FExpTargets := TCheckListBox.Create(Self);
  FExpTargets.Parent := T;
  FExpTargets.SetBounds(8, 126, 522, 136);
  for Tg := Low(TExportTarget) to High(TExportTarget) do
  begin
    FExpTargets.Items.Add(TargetNames[Tg]);
    FExpTargets.Checked[Ord(Tg)] := True;
  end;
  FExpRun := TButton.Create(Self);
  FExpRun.Parent := T;
  FExpRun.SetBounds(8, 270, 160, 30);
  FExpRun.Caption := 'Export';
  FExpRun.OnClick := @ExpRunClick;
  FExpCancel := TButton.Create(Self);
  FExpCancel.Parent := T;
  FExpCancel.SetBounds(176, 270, 100, 30);
  FExpCancel.Caption := 'Cancel';
  FExpCancel.Enabled := False;
  FExpCancel.OnClick := @ExpCancelClick;
  FExpProgress := TProgressBar.Create(Self);
  FExpProgress.Parent := T;
  FExpProgress.SetBounds(290, 276, 240, 18);
  FExpLog := TMemo.Create(Self);
  FExpLog.Parent := T;
  FExpLog.SetBounds(8, 308, 522, 380);
  FExpLog.Anchors := [akLeft, akTop, akRight, akBottom];
  FExpLog.ReadOnly := True;
  FExpLog.ScrollBars := ssAutoBoth;
  FExpLog.Font.Name := 'Consolas';
  FExpLog.Font.Size := 9;

  FTimer := TTimer.Create(Self);
  FTimer.Interval := 250;
  FTimer.OnTimer := @TimerTick;
end;

destructor TInfoForm.Destroy;
begin
  FBuf.Free;
  inherited Destroy;
end;

function TInfoForm.AddTab(const ACaption: string): TTabSheet;
begin
  Result := FPages.AddTabSheet;
  Result.Caption := ACaption;
end;

function TInfoForm.AddLabel(AParent: TWinControl; const ACaption: string; X, Y: Integer): TLabel;
begin
  Result := TLabel.Create(Self);
  Result.Parent := AParent;
  Result.Left := X;
  Result.Top := Y;
  Result.Caption := ACaption;
end;

function TInfoForm.AddSpin(AParent: TWinControl; X, Y, AMin, AMax, AValue: Integer): TSpinEdit;
begin
  Result := TSpinEdit.Create(Self);
  Result.Parent := AParent;
  Result.SetBounds(X, Y, 76, 24);
  Result.MinValue := AMin;
  Result.MaxValue := AMax;
  Result.Value := AValue;
end;

procedure TInfoForm.ShowExportTab;
begin
  FPages.ActivePageIndex := 3;
end;

{ the window is the LCL main form: closing it only hides it (the SDL window ends the program) }
procedure TInfoForm.FormClose(Sender: TObject; var CloseAction: TCloseAction);
begin
  CloseAction := caHide;
end;

procedure TInfoForm.FormKey(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  if (Key >= Ord('1')) and (Key <= Ord('4')) and (ssCtrl in Shift) then FPages.ActivePageIndex := Key - Ord('1');
end;

procedure TInfoForm.FillOverview;
var
  S: TStringList;
begin
  S := TStringList.Create;
  try
    S.Add('VIRTUAL PLC  -  S7-300 / S7-400 / S7-1200 / S7-1500, papercut UI');
    S.Add('Lazarus / FPC 3.2.2, SDL3 window, BGRABitmap on all cores, vsync 60 Hz');
    S.Add('');
    S.Add('A simulated Siemens CPU: pick a model (CPU 314 .. 317, 412 .. 416,');
    S.Add('1211C .. 1217C, 1511 .. 1518) with its memory sizes, I/O areas, timers / counters,');
    S.Add('DB limits, accumulators and instruction times. The PLC runs its scan');
    S.Add('cycle in its own thread: input image, OB1 (cyclic OB35 / OB30 between');
    S.Add('networks), output image; OB100 on STOP -> RUN.');
    S.Add('');
    S.Add('Program: LAD networks (contacts, coils, S/R, P/N edges, TON TOF TP');
    S.Add('TONR, S5 timers SD SE SP SS SF, CU CD, CTU CTD CTUD, CMP, MOVE, ADD');
    S.Add('SUB MUL DIV, NORM_X, SCALE_X, CALL) and STL networks (S7-300/400:');
    S.Add('full bit logic with nesting and AND before OR, L / T, integer, DINT');
    S.Add('and REAL math, compare, word logic, shifts, BCD, jumps, LOOP, OPN,');
    S.Add('CALL, 4 accumulators on the S7-400). Monitor shows the power flow');
    S.Add('and the STL status (RLO, STA, ACCU 1, ACCU 2).');
    S.Add('');
    S.Add('Ports: S7 communication (ISO-on-TCP, TCP 102: rack 0 slot 2 / 3 / 1,');
    S.Add('read / write I Q M DB T C, STOP / start, SZL mode / order code) and');
    S.Add('Modbus TCP (502: coils Q, inputs I, input registers IW, holding MW / DB):');
    S.Add('HMIs, snap7, Node-RED and Modbus masters reach the virtual CPU.');
    S.Add('');
    S.Add('Addresses: I0.0 Q4.0 M10.1 MW20 MD4 IW64 PIW288 DB1.DBX0.0 DB1.DBW2');
    S.Add('T1 C1, S7-1200 style %I0.0 %MW20 %IW64:P, symbols "Tag" and');
    S.Add('"DB".Var / "DB".Arr[3] / "DB".Timer.ET. Big-endian like the real CPU.');
    S.Add('');
    S.Add('Pipeline per frame (main thread):');
    S.Add('  poll SDL -> wait for the workers -> upload the bands to the');
    S.Add('  texture -> UI.Update -> UI.Build (display lists: static only when');
    S.Add('  the screen changes) -> start the workers -> present (vsync)');
    S.Add('Workers: each band = copy of the static band + dynamic list + grain.');
    S.Add('Text: glyph masks cut once on the main thread, blitted by the');
    S.Add('workers (TBGRABitmap.TextOut / PutImage are not thread safe).');
    S.Add('');
    S.Add('Units');
    S.Add('  uplctypes      models, addresses, constants, S5TIME, BCD');
    S.Add('  uplcproject    blocks, networks, DBs, tags, watch table, JSON, samples');
    S.Add('  uplccompiler   STL + LAD -> op code, operand resolution, checks');
    S.Add('  uplcruntime    memory, status word, interpreter, timers, scan thread');
    S.Add('  upaperdl       display lists, glyph cache, shadows, grain, SVG');
    S.Add('  uframe         bands on the render pool, static cache');
    S.Add('  uuibase        papercut widgets, hit regions, text editing');
    S.Add('  uui            the eight screens');
    S.Add('  uplcserver     S7 (ISO-on-TCP) and Modbus TCP servers, traffic log');
    S.Add('  uplcclient     S7 / Modbus clients for the self tests');
    S.Add('  usdlview       SDL3 window and loop, --shots script, --bench');
    S.Add('  uexport        PNG / GIF / MP4 / SVG of the main picture and layers');
    S.Add('  uinfoform      this window');
    S.Add('');
    S.Add('Keys (PLC window)');
    S.Add('  F5 RUN  F6 STOP  F7 compile  F8 download  F9 monitor  F11 full screen');
    S.Add('  F12 PNG of the window  F1 this window  Ctrl+1..8 screens  Ctrl+S save');
    S.Add('  LAD: arrows, F2 NO, F3 NC, F4 wire, F7 coil, B branch, Del, Insert row');
    S.Add('  STL: type, Enter, Tab, Ctrl+V paste, Ctrl+K delete line, Esc');
    S.Add('');
    S.Add('Command line');
    S.Add('  --sample=300|400|1200   start with that sample project');
    S.Add('  --shots folder          PNG of every screen (script), then quit');
    S.Add('  --export folder [w h frames fps]   export everything, then quit');
    S.Add('  --bench=SECONDS         frame pacing report, then quit');
    S.Add('  --novsync               start without vsync');
    FOverview.Lines.Assign(S);
  finally
    S.Free;
  end;
end;

procedure TInfoForm.UpdatePerfText;
var
  S: TStringList;
  I: Integer;
  Line: string;
begin
  if View = nil then Exit;
  S := TStringList.Create;
  try
    S.Add(Format('fps %.1f   display %.0f Hz   vsync %s   missed %d', [View.Fps, View.RefreshHz,
      IfThen(View.VSync, 'on', 'off'), View.MissedFrames]));
    S.Add(Format('frame %d x %d   %d threads (%d physical, %d logical)   %d bands', [View.Renderer.Width,
      View.Renderer.Height, View.Renderer.Threads, PhysicalCores, TThread.ProcessorCount, View.Renderer.BandCount]));
    S.Add(Format('render wall %.2f ms  cpu %.2f ms  (smoothed %.2f / %.2f)', [View.Renderer.RenderWallMs,
      View.Renderer.RenderCpuMs, View.Renderer.WallSmooth, View.Renderer.CpuSmooth]));
    S.Add(Format('static re-render %.2f ms (%d times)', [View.Renderer.StaticMs, View.Renderer.StaticRenders]));
    S.Add(Format('UI build %.2f ms   upload %.2f ms   present %.2f ms   wait %.2f ms', [View.LastBuildMs,
      View.LastUploadMs, View.LastSwapMs, View.LastWaitMs]));
    S.Add(Format('display list %d commands   hit regions %d   fonts %d', [View.UI.CmdCount, View.UI.HitCount,
      View.Glyphs.Count]));
    S.Add(Format('%s   backend %s   (%s)', [View.SdlVersion, View.RenderBackend, View.RenderDrivers]));
    S.Add('');
    Line := 'band ms:';
    for I := 0 to Min(31, High(View.Renderer.BandMs)) do Line := Line + Format(' %.1f', [View.Renderer.BandMs[I]]);
    S.Add(Line);
    Line := 'worker ms:';
    for I := 0 to View.Renderer.Threads - 1 do Line := Line + Format(' %.1f', [View.Renderer.WorkerMs[I]]);
    S.Add(Line);
    if View.LastSaved <> '' then S.Add('last PNG: ' + View.LastSaved);
    FPerfText.Lines.Assign(S);
  finally
    S.Free;
  end;
end;

procedure TInfoForm.UpdatePlcText;
var
  S: TStringList;
  Rt: TPlcRuntime;
  M: TCpuModel;
  P: TCProgram;
  I: Integer;
  Mode: string;
begin
  if View = nil then Exit;
  Rt := View.UI.Rt;
  M := Rt.Model;
  S := TStringList.Create;
  try
    case Rt.Mode of
      rmRun: Mode := 'RUN';
      rmStartup: Mode := 'STARTUP';
      rmMres: Mode := 'MRES';
    else
      Mode := 'STOP';
    end;
    S.Add(Format('%s  %s  %s  %s', [FamilyNames[M.Family], M.Name, M.OrderNo, M.Firmware]));
    S.Add(Format('mode %s   %s', [Mode, Rt.StopCause]));
    S.Add(Format('cycle #%d   %.0f cycles/s   period %.3f ms', [Rt.CycleNo, Rt.CyclesPerSec, Rt.PeriodMs]));
    S.Add(Format('model cycle  %.1f us  (min %.1f max %.1f avg %.1f)', [Rt.ModelUs, IfThen(Rt.ModelMinUs > 1E8, 0,
      Rt.ModelMinUs), Rt.ModelMaxUs, Rt.ModelAvgUs]));
    S.Add(Format('host exec    %.1f us  (min %.1f max %.1f avg %.1f)', [Rt.HostUs, IfThen(Rt.HostMinUs > 1E8, 0,
      Rt.HostMinUs), Rt.HostMaxUs, Rt.HostAvgUs]));
    S.Add(Format('instructions per cycle %d   cyclic OB%d: %d runs, %d late', [Rt.OpsLastCycle, M.CyclicOB,
      Rt.CycCount, Rt.CycLate]));
    S.Add(Format('forces %d bits   bus fault %s   pacing %d', [Rt.ForceCount, BoolToStr(Rt.BusFault, 'yes', 'no'),
      Ord(Rt.Pacing)]));
    S.Add('');
    S.Add(Format('memory: I %d  Q %d  M %d bytes, T %d, C %d, L %d bytes / call, DB1..DB%d',
      [M.InBytes, M.OutBytes, M.MBytes, M.Timers, M.Counters, 256, M.MaxDB]));
    S.Add(Format('accumulators %d, instruction ns: bit %s word %s fix %s float %s, OS %s us', [M.Accus,
      FloatToStrDot(M.BitNs), FloatToStrDot(M.WordNs), FloatToStrDot(M.FixNs), FloatToStrDot(M.FloatNs),
      FloatToStrDot(M.OsUs)]));
    P := Rt.Prog;
    S.Add('');
    if P = nil then S.Add('no program loaded')
    else
    begin
      S.Add(Format('program: %d blocks, %d bytes code, %d bytes data (work memory %d bytes)', [Length(P.Blocks),
        P.CodeBytes, P.DataBytes, M.WorkMem]));
      for I := 0 to High(P.Blocks) do
        S.Add(Format('  %-6s %-20s %4d ops  %3d networks', [P.Blocks[I].Title, P.Blocks[I].Name,
          Length(P.Blocks[I].Ops), Length(P.Blocks[I].Nets)]));
      for I := 0 to High(P.DBs) do
        S.Add(Format('  DB%-4d %-20s %4d bytes%s', [P.DBs[I].Number, P.DBs[I].Name, P.DBs[I].Size,
          IfThen(P.DBs[I].Optimized, '  optimized', '')]));
    end;
    S.Add('');
    S.Add(Format('project "%s"  %s  %s', [View.UI.Project.Name, IfThen(View.UI.Dirty, 'offline changed', 'offline = online'),
      View.UI.Project.FileName]));
    FPlcText.Lines.Assign(S);
  finally
    S.Free;
  end;
end;

procedure TInfoForm.TimerTick(Sender: TObject);
begin
  if (View = nil) or not Visible or FExpBusy then Exit;
  case FPages.ActivePageIndex of
    1:
      begin
        UpdatePerfText;
        FPerfBox.Invalidate;
      end;
    2: UpdatePlcText;
  end;
end;

procedure TInfoForm.PerfPaint(Sender: TObject);
var
  C: TCanvas;
  W, H, I, K, X, Y: Integer;
  Mx, V: Double;
  Cols: array[0..3] of TColor;
  Names: array[0..3] of string;

  function Hist(N, I2: Integer): Double;
  begin
    case N of
      0: Result := View.IntervalHist[I2];
      1: Result := View.RenderHist[I2];
      2: Result := View.BuildHist[I2];
    else
      Result := View.UploadHist[I2];
    end;
  end;

begin
  if View = nil then Exit;
  W := FPerfBox.Width;
  H := FPerfBox.Height;
  FBuf.SetSize(W, H);
  C := FBuf.Canvas;
  C.Brush.Color := $00DEEEF6;
  C.FillRect(0, 0, W, H);
  Mx := 1000 / Max(1, View.RefreshHz) * 2;
  C.Pen.Color := $00A0B0C0;
  Y := H - Round((1000 / Max(1, View.RefreshHz)) / Mx * (H - 20)) - 10;
  C.Line(0, Y, W, Y);
  C.Font.Size := 8;
  C.Font.Color := $00505050;
  C.TextOut(4, Y - 14, Format('%.1f ms (%.0f Hz)', [1000 / Max(1, View.RefreshHz), View.RefreshHz]));
  Cols[0] := $002228B2;
  Cols[1] := $0032AADE;
  Cols[2] := $005E9A3F;
  Cols[3] := $00808080;
  Names[0] := 'frame interval';
  Names[1] := 'render (workers)';
  Names[2] := 'UI build';
  Names[3] := 'upload';
  for K := 0 to 3 do
  begin
    C.Pen.Color := Cols[K];
    C.Pen.Width := IfThen(K = 0, 2, 1);
    for I := 0 to HistLen - 1 do
    begin
      V := Hist(K, (View.HistPos + I) mod HistLen);
      X := Round(I * (W - 1) / (HistLen - 1));
      Y := H - 10 - Round(Min(V, Mx) / Mx * (H - 20));
      if I = 0 then C.MoveTo(X, Y) else C.LineTo(X, Y);
    end;
    C.Font.Color := Cols[K];
    C.TextOut(W - 120, 6 + K * 14, Names[K]);
  end;
  C.Pen.Width := 1;
  FPerfBox.Canvas.Draw(0, 0, FBuf);
end;

procedure TInfoForm.ThreadsChanged(Sender: TObject);
begin
  if (View = nil) or FUpdating then Exit;
  View.Renderer.SetBandsPerThread(FBandSpin.Value);
  View.SetThreads(FThreadSpin.Value);
end;

procedure TInfoForm.VSyncChanged(Sender: TObject);
begin
  if View <> nil then View.VSync := FVSyncCheck.Checked;
end;

procedure TInfoForm.GrainChanged(Sender: TObject);
begin
  if View <> nil then
  begin
    View.Renderer.Grain := FGrainCheck.Checked;
    View.UI.InvalidateStatic;
  end;
end;

procedure TInfoForm.ExpProgress(const Msg: string; Done, Total: Integer; var Cancel: Boolean);
begin
  FExpProgress.Max := Max(1, Total);
  FExpProgress.Position := Done;
  if (FExpLog.Lines.Count = 0) or (FExpLog.Lines[FExpLog.Lines.Count - 1] <> Msg) then
  begin
    if (FExpLog.Lines.Count > 0) and (Pos('frame', FExpLog.Lines[FExpLog.Lines.Count - 1]) > 0) and (Pos('frame', Msg) > 0) then
      FExpLog.Lines[FExpLog.Lines.Count - 1] := Msg
    else
      FExpLog.Lines.Add(Msg);
  end;
  if View <> nil then View.PumpEvents;
  Application.ProcessMessages;
  Cancel := FExpCancelled;
end;

procedure TInfoForm.ExpRunClick(Sender: TObject);
var
  Opt: TExportOptions;
  Tg: TExportTarget;
  Res: TStringList;
  T0: Double;
begin
  if (View = nil) or FExpBusy then Exit;
  Opt := DefaultExportOptions;
  Opt.Folder := FExpFolder.Text;
  Opt.Width := FExpW.Value;
  Opt.Height := FExpH.Value;
  Opt.Frames := FExpFrames.Value;
  Opt.Fps := FExpFps.Value;
  Opt.Kbps := FExpKbps.Value;
  Opt.Png := FExpPng.Checked;
  Opt.Gif := FExpGif.Checked;
  Opt.Mp4 := FExpMp4.Checked;
  Opt.Svg := FExpSvg.Checked;
  Opt.Targets := [];
  for Tg := Low(TExportTarget) to High(TExportTarget) do
    if FExpTargets.Checked[Ord(Tg)] then Include(Opt.Targets, Tg);
  FExpBusy := True;
  FExpCancelled := False;
  FExpRun.Enabled := False;
  FExpCancel.Enabled := True;
  FExpLog.Clear;
  View.Exporting := True;
  View.Renderer.Wait;
  T0 := HiResMs;
  try
    Res := RunExport(View.UI, View.Renderer.Pool, Opt, View.Renderer.Width, View.Renderer.Height, @ExpProgress);
    try
      FExpLog.Lines.AddStrings(Res);
      FExpLog.Lines.Add(Format('done in %.1f s', [(HiResMs - T0) / 1000]));
    finally
      Res.Free;
    end;
  finally
    View.Exporting := False;
    FExpBusy := False;
    FExpRun.Enabled := True;
    FExpCancel.Enabled := False;
  end;
end;

procedure TInfoForm.ExpCancelClick(Sender: TObject);
begin
  FExpCancelled := True;
end;

end.
