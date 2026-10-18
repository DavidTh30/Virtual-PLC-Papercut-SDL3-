unit uSDLView;

{ SDL3 window with a vsync'ed render loop, driven from the LCL idle loop, so
  the SDL window and the LCL developer info window share the main thread.

  Each pass of the loop:
    1. poll SDL events (mouse, keys, text, wheel, resize, close)
    2. wait for the bands the workers rendered during the last pass
    3. upload the finished bands into one streaming texture
    4. advance the UI (generators, animations) and build the next frame's
       display lists (the static list only when the screen changed)
    5. start the workers on the new frame (all cores)
    6. draw the texture and SDL_RenderPresent: with vsync on this waits for
       the display while the workers are rendering.
  The PLC itself runs in its own thread (uPlcRuntime), independent of 60 Hz.

  --shots folder runs a script: the sample project in RUN, every screen and
  some states (start pressed, monitor on) saved as PNG, then quit.

  The Claude chat is a second SDL window (TClaudeChatUI). It is built and rendered while the
  workers of the main window are idle (after their frame, before the next one starts), on a small
  renderer of its own, and presented without vsync, so the main window keeps its rate. The events
  go to the window they belong to (windowID); closing the chat only hides it. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, StrUtils, Math, TypInfo, Forms, Controls, Clipbrd, SDL3, BGRABitmap, BGRABitmapTypes,
  uRenderPool, uPaperDL, uFrame, uUiBase, uUi, uPlcRuntime, uPlcTypes, uPlcProject, uExport, uClaude, uClaudeHttp,
  uClaudeChat, uPlcServer, uHelpForm;

const
  HistLen = 300;

type
  TShotStep = record
    Wait: Integer;     // frames before the step
    Cmd, Arg: string;
  end;

  { TSDLView }

  TSDLView = class
  private
    FWin: PSDL_Window;
    FRen: PSDL_Renderer;
    FTex: PSDL_Texture;
    FTexW, FTexH: Integer;
    FFlipV: Boolean;
    FRunning, FHaveFrame, FFresh, FVSync, FFullScreen: Boolean;
    FLastUpdate, FLastSwap: Double;
    FRefocus: Integer;
    FStatic, FDyn: TDisplayList;
    FStaticChanged: Boolean;
    FBenchSecs, FBenchT0: Double;
    FBench: array of Single;
    FShots: array of TShotStep;
    FShotPos, FShotWait: Integer;
    FShotDir: string;
    FDragShot, FDragShot2: string;
    FWaitStep: Integer;          // claudewait: the step being waited on and since when
    FWaitT0: TDateTime;
    FExportArgs: Integer;    // index of --export in the parameters, 0 = none
    FEventLog: TStringList;  // --eventlog: SDL input events, written at exit
    { the Claude chat window }
    FCWin: PSDL_Window;
    FCRen: PSDL_Renderer;
    FCTex: PSDL_Texture;
    FCTexW, FCTexH: Integer;
    FCFlip, FCShown, FCSized: Boolean;
    FCStatic, FCDyn: TDisplayList;
    FCRenderer: TFrameRenderer;
    procedure CloseRequest;
    procedure CreateChatWindow;
    procedure ChatFrame(DT: Double);
    function IsChatEvent(const E: TSDL_Event): Boolean;
    procedure SaveChatShot(const AFile: string);
    procedure UploadBands(Ren: PSDL_Renderer; FR: TFrameRenderer; var Tex: PSDL_Texture; var TW, TH: Integer;
      var Flip: Boolean);
    procedure PresentTex(Ren: PSDL_Renderer; Tex: PSDL_Texture; Flip: Boolean);
    procedure LogEvent(const S: string);
    procedure CmdLineExport;
    procedure AppIdle(Sender: TObject; var Done: Boolean);
    procedure PollEvents;
    procedure HandleKey(const E: TSDL_KeyboardEvent; Target: TUiBase);
    procedure MousePos(X, Y: Single; out PX, PY: Single; Win: PSDL_Window = nil);
    procedure ApplyVSync;
    procedure UpdateRefreshRate;
    procedure UploadFrame;
    procedure Present;
    procedure HandleRequests;
    procedure RunScript;
    procedure BenchFrame(ANow, AInterval: Double);
    procedure WriteBenchReport;
  public
    Glyphs: TGlyphCache;
    UI: TPlcUI;
    Chat: TClaudeChatUI;
    Renderer: TFrameRenderer;
    { timing history }
    IntervalHist, RenderHist, CpuHist, BuildHist, UploadHist, SwapHist: array[0..HistLen - 1] of Single;
    HistPos: Integer;
    FrameCount, MissedFrames: Int64;
    Fps, RefreshHz: Double;
    LastWaitMs, LastUploadMs, LastSwapMs, LastBuildMs, LastInterval: Double;
    SdlVersion, RenderBackend, RenderDrivers: string;
    SwapIntervalNow: Integer;
    LastSaved: string;
    Exporting: Boolean;
    constructor Create;
    destructor Destroy; override;
    procedure ShowInfo;
    procedure PlaceInfoBeside;
    procedure SaveShot(const AFile: string = '');
    procedure SetVSync(AValue: Boolean);
    procedure SetThreads(N: Integer);
    procedure ToggleFullScreen;
    procedure ResetStats;
    procedure PumpEvents;
    function Left: Integer;
    function Top: Integer;
    function Width: Integer;
    function Height: Integer;
    property VSync: Boolean read FVSync write SetVSync;
    property FullScreen: Boolean read FFullScreen;
  end;

var
  View: TSDLView;

implementation

uses
  uInfoForm;

function SDLErr: string;
begin
  Result := StrPas(SDL_GetError);
end;

constructor TSDLView.Create;
var
  R: TSDL_Rect;
  Ver, I: Integer;
  S: string;
begin
  inherited Create;
  if not SDL_Init(SDL_INIT_VIDEO) then
    raise Exception.Create('SDL_Init failed: ' + SDLErr);
  FWin := SDL_CreateWindow('Virtual PLC - S7-300 / S7-400 / S7-1200 (papercut, SDL3 + BGRABitmap all cores)',
    1440, 810, SDL_WINDOW_RESIZABLE or SDL_WINDOW_HIGH_PIXEL_DENSITY);
  if FWin = nil then raise Exception.Create('SDL_CreateWindow failed: ' + SDLErr);
  if SDL_GetDisplayUsableBounds(SDL_GetPrimaryDisplay, @R) then
    SDL_SetWindowPosition(FWin, R.x + 20, R.y + 40);
  FRen := SDL_CreateRenderer(FWin, nil);
  if FRen = nil then raise Exception.Create('SDL_CreateRenderer failed: ' + SDLErr);
  SDL_StartTextInput(FWin);
  Ver := SDL_GetVersion;
  SdlVersion := Format('SDL %d.%d.%d', [Ver div 1000000, (Ver div 1000) mod 1000, Ver mod 1000]);
  RenderBackend := StrPas(SDL_GetRendererName(FRen));
  RenderDrivers := '';
  for I := 0 to SDL_GetNumRenderDrivers - 1 do
    RenderDrivers := RenderDrivers + IfThen(I = 0, '', ', ') + StrPas(SDL_GetRenderDriver(I));
  FVSync := True;
  RefreshHz := 60;
  ApplyVSync;
  UpdateRefreshRate;

  Glyphs := TGlyphCache.Create;
  FStatic := TDisplayList.Create(Glyphs);
  FDyn := TDisplayList.Create(Glyphs);
  UI := TPlcUI.Create(Glyphs);
  Renderer := TFrameRenderer.Create(PhysicalCores, 2);
  FRunning := True;
  FLastUpdate := HiResMs;
  FLastSwap := FLastUpdate;

  for I := 1 to ParamCount do
  begin
    S := ParamStr(I);
    if Pos('--bench=', S) = 1 then FBenchSecs := StrToFloatDef(Copy(S, 9, 20), 10);
    if S = '--novsync' then SetVSync(False);
    if Pos('--sample=', S) = 1 then
      case Copy(S, 10, 10) of
        '300': UI.LoadSampleFor(1);
        '400': UI.LoadSampleFor(4);
        '1200': UI.LoadSampleFor(7);
      end;
    if (S = '--export') and (I < ParamCount) then FExportArgs := I;
    if S = '--eventlog' then FEventLog := TStringList.Create;
    if (S = '--shots') and (I < ParamCount) then FShotDir := IncludeTrailingPathDelimiter(ExpandFileName(ParamStr(I + 1)));
  end;
  if FShotDir <> '' then RunScript;
  // the start-up project goes to the CPU at once (the script loads its own)
  if FShotDir = '' then UI.Download;
  if FExportArgs > 0 then
  begin
    UI.LoadSampleFor(7);
    UI.Rt.CmdRun;
    UI.Rt.SetSimBit(0, 2, True);
    UI.Rt.SetSimBit(0, 1, True);
  end;
  Application.AddOnIdleHandler(@AppIdle);
end;

procedure TSDLView.LogEvent(const S: string);
begin
  if FEventLog <> nil then FEventLog.Add(FormatDateTime('hh:nn:ss.zzz ', SysUtils.Now) + S);
end;

destructor TSDLView.Destroy;
begin
  Application.RemoveOnIdleHandler(@AppIdle);
  if FEventLog <> nil then
  begin
    FEventLog.SaveToFile(ChangeFileExt(ParamStr(0), '-events.log'));
    FreeAndNil(FEventLog);
  end;
  FreeAndNil(Renderer);
  FreeAndNil(FCRenderer);
  FreeAndNil(Chat);
  FreeAndNil(FCStatic);
  FreeAndNil(FCDyn);
  if FCTex <> nil then SDL_DestroyTexture(FCTex);
  if FCRen <> nil then SDL_DestroyRenderer(FCRen);
  if FCWin <> nil then SDL_DestroyWindow(FCWin);
  FreeAndNil(UI);
  FreeAndNil(FStatic);
  FreeAndNil(FDyn);
  FreeAndNil(Glyphs);
  if FTex <> nil then SDL_DestroyTexture(FTex);
  if FRen <> nil then SDL_DestroyRenderer(FRen);
  if FWin <> nil then SDL_DestroyWindow(FWin);
  SDL_Quit;
  inherited Destroy;
end;

{ ---------- SDL ---------- }

procedure TSDLView.ApplyVSync;
var
  V: LongInt;
begin
  SDL_SetRenderVSync(FRen, Ord(FVSync));
  V := 0;
  SDL_GetRenderVSync(FRen, @V);
  SwapIntervalNow := V;
end;

procedure TSDLView.UpdateRefreshRate;
var
  Mode: PSDL_DisplayMode;
begin
  Mode := SDL_GetCurrentDisplayMode(SDL_GetDisplayForWindow(FWin));
  if (Mode <> nil) and (Mode^.refresh_rate > 1) then RefreshHz := Mode^.refresh_rate;
end;

procedure TSDLView.MousePos(X, Y: Single; out PX, PY: Single; Win: PSDL_Window);
var
  W, H, PW, PH: LongInt;
begin
  if Win = nil then Win := FWin;
  W := 1; H := 1; PW := 1; PH := 1;
  SDL_GetWindowSize(Win, @W, @H);
  SDL_GetWindowSizeInPixels(Win, @PW, @PH);
  PX := X * PW / Max(1, W);
  PY := Y * PH / Max(1, H);
end;

procedure TSDLView.HandleKey(const E: TSDL_KeyboardEvent; Target: TUiBase);
var
  K: TUiKey;
  Ch: Char;
  M: TUiMods;
  P: PAnsiChar;
begin
  M := [];
  if (E.mod_ and SDL_KMOD_SHIFT) <> 0 then Include(M, umShift);
  if (E.mod_ and SDL_KMOD_CTRL) <> 0 then Include(M, umCtrl);
  if (E.mod_ and SDL_KMOD_ALT) <> 0 then Include(M, umAlt);
  Ch := #0;
  K := ukNone;
  case E.key of
    SDLK_RETURN, SDLK_KP_ENTER: K := ukEnter;
    SDLK_ESCAPE: K := ukEsc;
    SDLK_BACKSPACE: K := ukBack;
    SDLK_DELETE: K := ukDel;
    SDLK_LEFT: K := ukLeft;
    SDLK_RIGHT: K := ukRight;
    SDLK_UP: K := ukUp;
    SDLK_DOWN: K := ukDown;
    SDLK_HOME: K := ukHome;
    SDLK_END: K := ukEnd;
    SDLK_PAGEUP: K := ukPgUp;
    SDLK_PAGEDOWN: K := ukPgDn;
    SDLK_TAB: K := ukTab;
    SDLK_INSERT: K := ukInsert;
    SDLK_F1: K := ukF1;
    SDLK_F2: K := ukF2;
    SDLK_F3: K := ukF3;
    SDLK_F4: K := ukF4;
    SDLK_F5: K := ukF5;
    SDLK_F6: K := ukF6;
    SDLK_F7: K := ukF7;
    SDLK_F8: K := ukF8;
    SDLK_F9: K := ukF9;
    SDLK_F10: K := ukF10;
    SDLK_F11: K := ukF11;
    SDLK_F12: K := ukF12;
  else
    if (E.key >= 32) and (E.key < 127) then
    begin
      K := ukChar;
      Ch := Chr(E.key);
    end;
  end;
  if K = ukNone then Exit;
  if (K = ukF11) and (Target = TUiBase(UI)) then
  begin
    ToggleFullScreen;
    Exit;
  end;
  if (K = ukChar) and (umCtrl in M) and (UpCase(Ch) = 'V') or (K = ukInsert) and (umShift in M) then
  begin
    P := SDL_GetClipboardText;
    if P <> nil then
    begin
      Target.Clipboard := StrPas(P);
      SDL_free(P);
    end;
  end;
  // plain letters only count as shortcuts when no text is being typed
  Target.KeyDown(K, Ch, M);
end;

function TSDLView.IsChatEvent(const E: TSDL_Event): Boolean;
begin
  // window, key, text and mouse events all start with type, reserved, timestamp, windowID
  Result := (FCWin <> nil) and (Chat <> nil) and (E.window.windowID = SDL_GetWindowID(FCWin));
end;

procedure TSDLView.PollEvents;
var
  E: TSDL_Event;
  X, Y: Single;
  T: TUiBase;
  Win: PSDL_Window;
begin
  while SDL_PollEvent(@E) do
  begin
    if IsChatEvent(E) then
    begin
      T := Chat;
      Win := FCWin;
    end
    else
    begin
      T := UI;
      Win := FWin;
    end;
    case E._type of
      SDL_EVENT_QUIT:
        if not Exporting then CloseRequest;
      SDL_EVENT_WINDOW_CLOSE_REQUESTED:
        if Win = FCWin then
          UI.ChatOpen := False   // the chat only hides; ChatFrame does it
        else if not Exporting then CloseRequest;
      SDL_EVENT_KEY_DOWN:
        begin
          LogEvent(Format('key %d mod %d', [E.key.key, E.key.mod_]));
          HandleKey(E.key, T);
        end;
      SDL_EVENT_TEXT_INPUT:
        if E.text.text <> nil then T.TextInput(StrPas(E.text.text));
      SDL_EVENT_MOUSE_BUTTON_DOWN:
        if E.button.button = SDL_BUTTON_RIGHT then
        begin
          MousePos(E.button.x, E.button.y, X, Y, Win);
          T.MouseRightDown(X, Y);
        end
        else if E.button.button = SDL_BUTTON_LEFT then
        begin
          MousePos(E.button.x, E.button.y, X, Y, Win);
          LogEvent(Format('down %.1f %.1f -> %.1f %.1f', [E.button.x, E.button.y, X, Y]));
          T.MouseClicks := E.button.clicks;
          T.MouseMods := [];
          if (SDL_GetModState and SDL_KMOD_SHIFT) <> 0 then Include(T.MouseMods, umShift);
          if (SDL_GetModState and SDL_KMOD_CTRL) <> 0 then Include(T.MouseMods, umCtrl);
          if (SDL_GetModState and SDL_KMOD_ALT) <> 0 then Include(T.MouseMods, umAlt);
          T.MouseDown(X, Y);
        end;
      SDL_EVENT_MOUSE_BUTTON_UP:
        if E.button.button = SDL_BUTTON_LEFT then
        begin
          MousePos(E.button.x, E.button.y, X, Y, Win);
          LogEvent(Format('up %.1f %.1f', [E.button.x, E.button.y]));
          T.MouseUp(X, Y);
        end;
      SDL_EVENT_MOUSE_MOTION:
        begin
          MousePos(E.motion.x, E.motion.y, X, Y, Win);
          LogEvent(Format('move %.1f %.1f', [E.motion.x, E.motion.y]));
          T.MouseMove(X, Y);
        end;
      SDL_EVENT_MOUSE_WHEEL:
        begin
          // Shift + wheel or a horizontal wheel (touchpad): sideways
          if E.wheel.x <> 0 then
          begin
            T.WheelShift := True;
            T.Wheel(-E.wheel.x);
          end;
          if E.wheel.y <> 0 then
          begin
            T.WheelShift := (SDL_GetModState and SDL_KMOD_SHIFT) <> 0;
            T.Wheel(E.wheel.y);
          end;
          T.WheelShift := False;
        end;
      SDL_EVENT_WINDOW_DISPLAY_CHANGED:
        if Win = FWin then UpdateRefreshRate;
      SDL_EVENT_DROP_FILE:
        // a file dropped on the chat window: an attachment for the next question
        if (Win = FCWin) and (E.drop.Data <> nil) then Chat.AttachFile(StrPas(E.drop.Data));
    end;
  end;
  if UI.ClipboardOut <> '' then
  begin
    SDL_SetClipboardText(PAnsiChar(UI.ClipboardOut));
    UI.ClipboardOut := '';
  end;
  if (Chat <> nil) and (Chat.ClipboardOut <> '') then
  begin
    SDL_SetClipboardText(PAnsiChar(Chat.ClipboardOut));
    Chat.ClipboardOut := '';
  end;
end;

{ the main window's close: unsaved changes are asked about first (the main window comes to the
  front with the question); without changes the program ends }
procedure TSDLView.CloseRequest;
begin
  if UI.Project.Modified then
  begin
    UI.Screen := UI.Screen;
    UI.RequestQuit;
    SDL_RaiseWindow(FWin);
  end
  else
  begin
    FRunning := False;
    Application.Terminate;
  end;
end;

procedure TSDLView.PumpEvents;
var
  E: TSDL_Event;
begin
  // during an export: keep the window alive, ignore input
  while SDL_PollEvent(@E) do ;
end;

procedure TSDLView.UploadBands(Ren: PSDL_Renderer; FR: TFrameRenderer; var Tex: PSDL_Texture; var TW, TH: Integer;
  var Flip: Boolean);
var
  I, W, H: Integer;
  B: TBGRABitmap;
  Rc: TSDL_Rect;
  Fmt: TSDL_PixelFormat;
begin
  W := FR.Width;
  H := FR.Height;
  if (Tex = nil) or (TW <> W) or (TH <> H) then
  begin
    if Tex <> nil then SDL_DestroyTexture(Tex);
    if TBGRAPixel_RGBAOrder then Fmt := SDL_PIXELFORMAT_ABGR8888 else Fmt := SDL_PIXELFORMAT_ARGB8888;
    Tex := SDL_CreateTexture(Ren, Fmt, SDL_TEXTUREACCESS_STREAMING, W, H);
    if Tex = nil then Exit;
    SDL_SetTextureScaleMode(Tex, SDL_SCALEMODE_NEAREST);
    SDL_SetTextureBlendMode(Tex, SDL_BLENDMODE_NONE);
    TW := W;
    TH := H;
  end;
  for I := 0 to FR.BandCount - 1 do
  begin
    B := FR.Bands[I];
    Flip := B.LineOrder = riloBottomToTop;
    Rc.x := 0;
    Rc.w := W;
    Rc.h := B.Height;
    if Flip then Rc.y := H - FR.BandTops[I] - B.Height else Rc.y := FR.BandTops[I];
    SDL_UpdateTexture(Tex, @Rc, B.Data, W * SizeOf(TBGRAPixel));
  end;
end;

procedure TSDLView.PresentTex(Ren: PSDL_Renderer; Tex: PSDL_Texture; Flip: Boolean);
var
  W, H: LongInt;
  Dst: TSDL_FRect;
begin
  if Tex = nil then
  begin
    SDL_SetRenderDrawColor(Ren, 246, 238, 222, 255);
    SDL_RenderClear(Ren);
  end
  else
  begin
    W := 0;
    H := 0;
    SDL_GetCurrentRenderOutputSize(Ren, @W, @H);
    Dst.x := 0;
    Dst.y := 0;
    Dst.w := W;
    Dst.h := H;
    if Flip then SDL_RenderTextureRotated(Ren, Tex, nil, @Dst, 0, nil, SDL_FLIP_VERTICAL)
    else SDL_RenderTexture(Ren, Tex, nil, @Dst);
  end;
  SDL_RenderPresent(Ren);
end;

procedure TSDLView.UploadFrame;
begin
  UploadBands(FRen, Renderer, FTex, FTexW, FTexH, FFlipV);
end;

procedure TSDLView.Present;
begin
  PresentTex(FRen, FTex, FFlipV);
end;

{ ---------- the Claude chat window ---------- }

procedure TSDLView.CreateChatWindow;
var
  X, Y, W, H: LongInt;
  R: TSDL_Rect;
begin
  FCWin := SDL_CreateWindow('Claude chat - Virtual PLC', 540, 780,
    SDL_WINDOW_RESIZABLE or SDL_WINDOW_HIGH_PIXEL_DENSITY or SDL_WINDOW_HIDDEN);
  if FCWin = nil then raise Exception.Create('SDL_CreateWindow (chat) failed: ' + SDLErr);
  // beside the main window, inside the screen
  X := 0; Y := 0; W := 0; H := 0;
  SDL_GetWindowPosition(FWin, @X, @Y);
  SDL_GetWindowSize(FWin, @W, @H);
  if SDL_GetDisplayUsableBounds(SDL_GetDisplayForWindow(FWin), @R) then
  begin
    X := Min(X + W + 10, R.x + R.w - 550);
    Y := Max(R.y + 40, Min(Y, R.y + R.h - 820));
  end
  else
    X := X + W + 10;
  SDL_SetWindowPosition(FCWin, X, Y);
  FCRen := SDL_CreateRenderer(FCWin, nil);
  if FCRen = nil then raise Exception.Create('SDL_CreateRenderer (chat) failed: ' + SDLErr);
  SDL_SetRenderVSync(FCRen, 0);   // the main window waits for the display, the chat does not
  SDL_StartTextInput(FCWin);
  FCStatic := TDisplayList.Create(Glyphs);
  FCDyn := TDisplayList.Create(Glyphs);
  FCRenderer := TFrameRenderer.Create(EnsureRange(PhysicalCores div 2, 1, 4), 1);
  Chat := TClaudeChatUI.Create(Glyphs);
  Chat.Agent := UI.Claude;
  Chat.OnAsk := @UI.AskClaudeWith;
  Chat.OnKeyDialog := @UI.KeyDialogEvent;
end;

{ called while the workers of the main window are idle: the glyph cache is not read by them }
procedure TSDLView.ChatFrame(DT: Double);
var
  W, H: LongInt;
begin
  if UI.ChatOpen and not FCShown then
  begin
    if FCWin = nil then CreateChatWindow;
    SDL_ShowWindow(FCWin);
    FCShown := True;
    Chat.Opened;
    UI.ChatRaiseRequested := True;
  end;
  if not UI.ChatOpen and FCShown then
  begin
    SDL_HideWindow(FCWin);
    FCShown := False;
  end;
  if not FCShown then Exit;
  if UI.ChatRaiseRequested then
  begin
    UI.ChatRaiseRequested := False;
    SDL_RaiseWindow(FCWin);
  end;
  if (SDL_GetWindowFlags(FCWin) and SDL_WINDOW_MINIMIZED) <> 0 then Exit;
  Chat.Agent := UI.Claude;
  Chat.ProjectName := UI.Project.Name;
  W := 0;
  H := 0;
  SDL_GetWindowSizeInPixels(FCWin, @W, @H);
  if (W < 16) or (H < 16) then Exit;
  Chat.SetDensity(SDL_GetWindowDisplayScale(FCWin));
  if (W <> FCRenderer.Width) or (H <> FCRenderer.Height) then
  begin
    FCRenderer.SetSize(W, H);
    Chat.SetSize(W, H);
    FCSized := False;
  end;
  Chat.Update(DT);
  FCDyn.Clear;
  Chat.Build(FCDyn);
  if not FCSized then FCStatic.Clear;
  FCRenderer.Start(FCStatic, FCDyn, not FCSized);
  FCSized := True;
  FCRenderer.Wait;
  UploadBands(FCRen, FCRenderer, FCTex, FCTexW, FCTexH, FCFlip);
  PresentTex(FCRen, FCTex, FCFlip);
end;

procedure TSDLView.SaveChatShot(const AFile: string);
var
  B: TBGRABitmap;
begin
  if (FCRenderer = nil) or not FCShown then Exit;
  B := TBGRABitmap.Create(1, 1);
  try
    FCRenderer.Assemble(B);
    B.SaveToFile(AFile);
  finally
    B.Free;
  end;
end;

{ ---------- loop ---------- }

procedure TSDLView.HandleRequests;
begin
  if UI.ShotRequested then
  begin
    UI.ShotRequested := False;
    SaveShot;
  end;
  if UI.RaiseRequested then
  begin
    UI.RaiseRequested := False;
    SDL_RaiseWindow(FWin);
  end;
  if UI.InfoTopRequested then
  begin
    // on top (and shown) or a normal window again
    UI.InfoTopRequested := False;
    if InfoForm <> nil then
    begin
      if InfoForm.FormStyle = fsStayOnTop then InfoForm.FormStyle := fsNormal
      else
      begin
        InfoForm.FormStyle := fsStayOnTop;
        ShowInfo;
      end;
    end;
  end;
  if UI.InfoCloseRequested then
  begin
    UI.InfoCloseRequested := False;
    if InfoForm <> nil then InfoForm.Hide;
  end;
  if UI.InfoRequested then
  begin
    UI.InfoRequested := False;
    ShowInfo;
  end;
  if UI.ExportRequested then
  begin
    UI.ExportRequested := False;
    ShowInfo;
    if InfoForm <> nil then InfoForm.ShowExportTab;
  end;
end;

procedure TSDLView.AppIdle(Sender: TObject; var Done: Boolean);
var
  T0, Now, DT, Interval: Double;
  W, H: LongInt;
begin
  Done := False;
  if not FRunning or Exporting then
  begin
    Done := True;
    Exit;
  end;
  PollEvents;
  if not FRunning then Exit;
  if (SDL_GetWindowFlags(FWin) and SDL_WINDOW_MINIMIZED) <> 0 then
  begin
    Sleep(15);
    Exit;
  end;
  if FRefocus > 0 then
  begin
    Dec(FRefocus);
    if FRefocus = 0 then SDL_RaiseWindow(FWin);
  end;
  // the developer info window starts closed: Project screen, Developer menu (or F1)

  // 1. the frame of the workers
  if Renderer.Rendering then
  begin
    T0 := HiResMs;
    Renderer.Wait;
    LastWaitMs := HiResMs - T0;
    FHaveFrame := True;
    FFresh := True;
  end
  else
    LastWaitMs := 0;
  if FHaveFrame then HandleRequests;

  // 2. size
  W := 0;
  H := 0;
  SDL_GetWindowSizeInPixels(FWin, @W, @H);
  if (W >= 16) and (H >= 16) and ((W <> Renderer.Width) or (H <> Renderer.Height)) then
  begin
    Renderer.SetSize(W, H);
    UI.SetSize(W, H);
    UI.InvalidateStatic;
    FHaveFrame := False;
  end;
  if Glyphs.Full then
  begin
    // workers idle here: the font slots can be reused
    Glyphs.Clear;
    UI.InvalidateStatic;
  end;

  // 3. upload
  T0 := HiResMs;
  if FFresh then UploadFrame;
  FFresh := False;
  LastUploadMs := HiResMs - T0;

  // 4. script, UI and the next frame
  if FShotDir <> '' then RunScript;
  Now := HiResMs;
  DT := (Now - FLastUpdate) / 1000;
  FLastUpdate := Now;
  if DT > 0.1 then DT := 0.1;
  T0 := HiResMs;
  UI.InfoVisible := (InfoForm <> nil) and InfoForm.Visible;
  UI.InfoOnTop := (InfoForm <> nil) and (InfoForm.FormStyle = fsStayOnTop);
  UI.Update(DT);
  ChatFrame(DT);
  FStaticChanged := UI.Build(FStatic, FDyn);
  LastBuildMs := HiResMs - T0;
  Renderer.Start(FStatic, FDyn, FStaticChanged);

  // 5. present (vsync wait while the workers render)
  T0 := HiResMs;
  Present;
  LastSwapMs := HiResMs - T0;

  Now := HiResMs;
  Interval := Now - FLastSwap;
  FLastSwap := Now;
  LastInterval := Interval;
  if FrameCount > 0 then
  begin
    IntervalHist[HistPos] := Interval;
    RenderHist[HistPos] := Renderer.RenderWallMs;
    CpuHist[HistPos] := Renderer.RenderCpuMs;
    BuildHist[HistPos] := LastBuildMs;
    UploadHist[HistPos] := LastUploadMs;
    SwapHist[HistPos] := LastSwapMs;
    HistPos := (HistPos + 1) mod HistLen;
    if Interval > 0 then Fps := Fps * 0.95 + (1000 / Interval) * 0.05;
    if FVSync and (Interval > 1.5 * 1000 / RefreshHz) then Inc(MissedFrames);
    if FBenchSecs > 0 then BenchFrame(Now, Interval);
  end;
  Inc(FrameCount);
  if (FExportArgs > 0) and (FrameCount = 90) then UI.Rt.SetSimBit(0, 0, True);
  if (FExportArgs > 0) and (FrameCount = 100) then UI.Rt.SetSimBit(0, 0, False);
  if (FExportArgs > 0) and (FrameCount = 160) then CmdLineExport;
  if UI.QuitRequested then
  begin
    FRunning := False;
    Application.Terminate;
  end;
end;

{ ---------- the --shots script ---------- }

{ the cells of a LAD network as text: rows separated by /, cells by , (kind:operand) }
function CellsText(N: TNetwork): string;
var
  R, C: Integer;
begin
  Result := '';
  for R := 0 to N.Rows - 1 do
  begin
    if R > 0 then Result := Result + ' / ';
    for C := 0 to N.Cols - 1 do
    begin
      if C > 0 then Result := Result + ',';
      Result := Result + LadKindIds[N.Cell(R, C).Kind];
      if N.Cell(R, C).Opnd <> '' then Result := Result + ':' + N.Cell(R, C).Opnd;
    end;
  end;
end;

// the text of the first SCL network of the block ('#none' without one)
function FirstScl(B: TBlock): string;
var
  K: Integer;
begin
  Result := '#none';
  for K := 0 to B.NetCount - 1 do
    if B.Net(K).Kind = nkSCL then Exit(Trim(B.Net(K).Stl.Text));
end;

function RowKinds(N: TNetwork): string;
var
  C: Integer;
begin
  Result := '';
  for C := 0 to N.Cols - 1 do
    Result := Result + Copy(LadKindNames[N.Cell(0, C).Kind], 1, 4) + ' ';
end;

function BoxCount(N: TNetwork): Integer;
var
  R, C: Integer;
begin
  Result := 0;
  for R := 0 to N.Rows - 1 do
    for C := 0 to N.Cols - 1 do
      if IsBox(N.Cell(R, C).Kind) then Inc(Result);
end;

// every box has a free cell on its right: it is drawn at its full width
function BoxesWide(N: TNetwork): Boolean;
var
  R, C: Integer;
begin
  Result := True;
  for R := 0 to N.Rows - 1 do
    for C := 0 to N.Cols - 2 do
      if IsBox(N.Cell(R, C).Kind) and not N.Cell(R, C).Down and not (N.Cell(R, C + 1).Kind in [lkWire, lkEmpty]) then
        Exit(False);
end;

procedure TSDLView.RunScript;

  procedure Add(AWait: Integer; const ACmd: string; const AArg: string = '');
  var
    N: Integer;
  begin
    N := Length(FShots);
    SetLength(FShots, N + 1);
    FShots[N].Wait := AWait;
    FShots[N].Cmd := ACmd;
    FShots[N].Arg := AArg;
  end;

  procedure AddFamily(const Tag, Model: string);
  begin
    Add(20, 'sample', Model);
    Add(30, 'screen', '1');
    Add(10, 'run');
    // through the UI's hit regions, like mouse clicks
    Add(20, 'mclick', '599,36');    // the I/O tab
    Add(10, 'mclick', '53,217');    // the Overload_OK switch (I0.2)
    Add(10, 'mdown', '53,133');     // press Start_PB (I0.0, push NO)
    Add(8, 'mup', '53,133');
    Add(40, 'screen', '0');
    Add(20, 'shot', Tag + '_1_cpu');
    Add(10, 'screen', '1');
    Add(10, 'monitor', '');
    Add(30, 'shot', Tag + '_2_program_monitor');
    Add(10, 'scroll', '400');
    Add(20, 'shot', Tag + '_3_program_scrolled');
    Add(5, 'scroll', '0');
    Add(5, 'screen', '2');
    Add(60, 'shot', Tag + '_4_io');
    Add(5, 'screen', '3');
    Add(30, 'shot', Tag + '_5_watch');
    Add(5, 'screen', '4');
    Add(20, 'shot', Tag + '_6_db');
    Add(5, 'udt', '0');
    Add(20, 'shot', Tag + '_6_udt');
    Add(5, 'screen', '5');
    Add(20, 'shot', Tag + '_7_tags');
    Add(5, 'screen', '6');
    Add(10, 'selftest', '');
    Add(30, 'shot', Tag + '_8_ports');
    Add(5, 'screen', '7');
    Add(20, 'shot', Tag + '_8_project');
    Add(5, 'screen', '0');
    Add(330, 'shot', Tag + '_9_cpu_fullspeed');
  end;

var
  St: TShotStep;
  P, V: Integer;
  Pt, Pp: TPointF;
  Pc: PChar;
  S0, S1, S2, S3: string;
  Ok: Boolean;
begin
  if (Length(FShots) = 0) and (GetEnvironmentVariable('VPLC_THAI_TEST') <> '') then
  begin
    // the Claude panel with the chat of the real run (shots\claude_live.txt): Thai text, tables
    Add(10, 'sample', '13');
    Add(5, 'claudeopen');
    Add(5, 'chatload');
    Add(20, 'chatshot', 'claude_thai_1');
    Add(5, 'chattop');
    Add(20, 'chatshot', 'claude_thai_2');
    Add(5, 'chatexport', 'claude_thai.pdf');
    Add(5, 'chatexport', 'claude_thai.png');
    Add(5, 'chatexport', 'claude_thai.txt');
    Add(5, 'chatattach', 'test/attach_test.jpg');
    Add(5, 'chatattach', 'shots/claude_chat.pdf');
    Add(5, 'chatattach', 'README.md');
    Add(10, 'chatshot', 'claude_thai_3_files');
    Add(5, 'quit');
    FShotPos := 0;
    FShotWait := FShots[0].Wait;
    Exit;
  end;
  if (Length(FShots) = 0) and (GetEnvironmentVariable('VPLC_IPC_TEST') <> '') then
  begin
    // IPC on (test\ipcclient.py talks through the pipe meanwhile), its help and the PDF; the imports of
    // tags and watch rows; the Explorer (VPLC_NO_SHELL: only noted)
    DeleteFile(FShotDir + 'ipc_check.txt');
    Add(10, 'sample', '13');
    Add(10, 'run');
    Add(5, 'screen', '6');
    Add(10, 'uiclick2', 'ipcon:0');
    Add(10, 'ipc', 'check on');
    Add(400, 'ipc', 'wait client');
    Add(10, 'shot', 'ipc_1_ports');
    Add(5, 'uiclick2', 'ipchelp:0');
    Add(30, 'ipc', 'helpform');
    Add(20, 'ipc', 'helpsmall');
    Add(5, 'ipc', 'pdf');
    Add(5, 'ipc', 'helpclose');
    Add(5, 'uiclick2', 'ipcon:0');
    Add(20, 'ipc', 'check off');
    Add(5, 'screen', '5');
    Add(5, 'ipc', 'import tags');
    Add(10, 'shot', 'ipc_3_tags_imported');
    Add(5, 'screen', '3');
    Add(5, 'ipc', 'import watch');
    Add(10, 'shot', 'ipc_4_watch_imported');
    Add(5, 'screen', '7');
    Add(5, 'ipc', 'refresh');
    Add(10, 'uiclick2', 'explorer:0');
    Add(5, 'ipc', 'explorer');
    Add(5, 'uirclick', 'file:0');
    Add(10, 'shot', 'ipc_5_file_menu');
    Add(5, 'uiclick2', 'ctx:1');
    Add(5, 'ipc', 'explorer');
    Add(5, 'quit');
    FShotPos := 0;
    FShotWait := FShots[0].Wait;
    Exit;
  end;
  if (Length(FShots) = 0) and (GetEnvironmentVariable('VPLC_LADPAL_TEST') <> '') then
  begin
    // the LAD palette (groups, its scroll bar, a comparator, a converter), the box's type lists,
    // the data type lists of a tag and of a DB variable
    DeleteFile(FShotDir + 'ladpal_check.txt');
    Add(10, 'sample', '13');
    Add(5, 'screen', '1');
    Add(5, 'ob1');
    Add(5, 'mk', 'newlad');
    Add(10, 'shot', 'ladpal_1_palette');
    // the LAD elements list: categories, a double click puts the element into the selected cell
    Add(5, 'elem', 'showcat Comparison / selection');
    Add(5, 'elem', 'open Comparison / selection');
    Add(5, 'elem', 'show CMP >=');
    Add(10, 'shot', 'ladpal_2_scrolled');
    Add(5, 'elem', 'dbl CMP >=');
    Add(5, 'ladins', 'esc');
    Add(10, 'pal', 'check cmp');
    Add(5, 'mk', 'nextcell');
    Add(5, 'elem', 'showcat Comparison / selection');
    Add(5, 'elem', 'open Comparison / selection');
    Add(5, 'elem', 'showcat Move / conversion');
    Add(5, 'elem', 'open Move / conversion');
    Add(5, 'elem', 'show CONV');
    Add(5, 'elem', 'dbl CONV');
    Add(5, 'ladins', 'esc');
    Add(10, 'pal', 'check conv');
    Add(5, 'uiclick2', 'dtype2:0');
    Add(10, 'shot', 'ladpal_3_conv_out_types');
    Add(5, 'uiclick2', 'ctx:7');
    Add(10, 'pal', 'check out');
    Add(10, 'shot', 'ladpal_4_conv_box');
    Add(5, 'screen', '5');
    Add(10, 'uiclick2', 'tagtype:11');
    Add(10, 'shot', 'ladpal_5_tag_types');
    Add(5, 'uiclick2', 'ctx:11');
    Add(10, 'pal', 'check tag');
    Add(5, 'screen', '4');
    Add(10, 'uiclick2', 'vartype:1');
    Add(10, 'shot', 'ladpal_6_var_types');
    Add(5, 'uiclick2', 'ctx:9');
    Add(10, 'pal', 'check var');
    Add(5, 'quit');
    FShotPos := 0;
    FShotWait := FShots[0].Wait;
    Exit;
  end;
  if (Length(FShots) = 0) and (GetEnvironmentVariable('VPLC_CARET_TEST') <> '') then
  begin
    // the keyboard moves the caret: the editor scrolls so that it stays inside the frame
    DeleteFile(FShotDir + 'caret_check.txt');
    Add(10, 'sample', '13');
    Add(5, 'screen', '1');
    Add(5, 'fc1');
    Add(5, 'stlnet', 'SCL');
    Add(5, 'caret', 'home');
    for V := 1 to 45 do Add(3, 'caret', 'down');
    Add(5, 'shot', 'caret_1_scl_down');
    for V := 1 to 45 do Add(3, 'caret', 'up');
    Add(5, 'shot', 'caret_2_scl_up');
    Add(5, 'ob1');
    Add(5, 'mk', 'ladsel');
    for V := 1 to 30 do Add(3, 'caret', 'down');
    Add(5, 'shot', 'caret_3_lad_down');
    for V := 1 to 30 do Add(3, 'caret', 'up');
    Add(5, 'shot', 'caret_4_lad_up');
    Add(5, 'quit');
    FShotPos := 0;
    FShotWait := FShots[0].Wait;
    Exit;
  end;
  if (Length(FShots) = 0) and (GetEnvironmentVariable('VPLC_BATCH_TEST') <> '') then
  begin
    // scroll bars of every list, the tag checks, a field as a text box, the IP address
    DeleteFile(FShotDir + 'vscroll_check.txt');
    DeleteFile(FShotDir + 'batch_check.txt');
    Add(10, 'sample', '13');
    Add(5, 'mk', 'blocks');
    Add(5, 'screen', '1');
    Add(10, 'vs', 'drag 2 0.05 0.9');
    Add(10, 'shot', 'batch_1_blocks');
    Add(5, 'mk', 'tags');
    Add(5, 'screen', '5');
    Add(10, 'mk', 'tagcheck');
    Add(5, 'shot', 'batch_2_tags_red');
    Add(5, 'vs', 'drag 3 0.05 0.8');
    Add(10, 'shot', 'batch_3_tags_scrolled');
    Add(5, 'mk', 'dbs');
    Add(5, 'screen', '4');
    Add(10, 'vs', 'drag 4 0.05 0.7');
    Add(5, 'vs', 'drag 5 0.05 0.6');
    Add(10, 'shot', 'batch_4_dbs');
    Add(5, 'mk', 'watch');
    Add(5, 'screen', '3');
    Add(10, 'vs', 'drag 6 0.05 0.9');
    Add(10, 'shot', 'batch_5_watch');
    Add(5, 'mk', 'files');
    Add(5, 'screen', '7');
    Add(10, 'vs', 'drag 7 0.05 0.9');
    Add(10, 'shot', 'batch_6_files');
    Add(5, 'mk', 'saveas');
    Add(10, 'shot', 'batch_7_saveas');
    Add(5, 'mk', 'saveas2');
    Add(5, 'mk', 'rmfiles');
    Add(5, 'screen', '6');
    Add(10, 'mk', 'ip');
    Add(20, 'mk', 'ipcheck');
    Add(5, 'shot', 'batch_8_ip_not_local');
    Add(5, 'mk', 'ipmenu');
    Add(10, 'shot', 'batch_9_ip_menu');
    Add(5, 'uiclick2', 'ctx:0');
    Add(20, 'mk', 'ipcheck');
    Add(5, 'quit');
    FShotPos := 0;
    FShotWait := FShots[0].Wait;
    Exit;
  end;
  if (Length(FShots) = 0) and (GetEnvironmentVariable('VPLC_VSCROLL_TEST') <> '') then
  begin
    // the vertical scroll bars of the program editor: the thumb dragged, a click on the track
    DeleteFile(FShotDir + 'vscroll_check.txt');
    Add(10, 'sample', '13');
    Add(5, 'screen', '1');
    Add(5, 'ob1');
    Add(10, 'vs', 'drag 0 0.02 0.5');
    Add(10, 'shot', 'vscroll_1_dragged');
    Add(5, 'vs', 'drag 0 0.5 0.0');
    Add(5, 'vs', 'click 0 0.97');
    Add(10, 'shot', 'vscroll_2_track');
    Add(5, 'testmsgs', '20');
    Add(10, 'vs', 'drag 1 0.05 0.6');
    Add(10, 'shot', 'vscroll_3_messages');
    Add(5, 'vs', 'click 1 0.98');
    Add(5, 'quit');
    FShotPos := 0;
    FShotWait := FShots[0].Wait;
    Exit;
  end;
  if (Length(FShots) = 0) and (GetEnvironmentVariable('VPLC_STARTUP_TEST') <> '') then
  begin
    // the project the program starts with (no sample loaded by the script)
    Add(20, 'startcheck');
    Add(5, 'shot', 'startup_0');
    Add(5, 'screen', '1');
    Add(10, 'shot', 'startup_1_program');
    Add(5, 'quit');
    FShotPos := 0;
    FShotWait := FShots[0].Wait;
    Exit;
  end;
  if (Length(FShots) = 0) and (GetEnvironmentVariable('VPLC_IOIMPORT_TEST') <> '') then
  begin
    // the I/O import (test\import_io.csv) and its help: a window (HTML, select, copy), a PDF
    DeleteFile(FShotDir + 'ipc_check.txt');
    Add(10, 'sample', '7');
    Add(5, 'screen', '2');
    Add(10, 'ipc', 'import io');
    Add(20, 'shot', 'ioimport_1_io_screen');
    Add(5, 'uiclick2', 'iohelp:0');
    Add(30, 'ipc', 'iohelpform');
    Add(5, 'ipc', 'iohelppdf');
    Add(5, 'ipc', 'iohelpclose');
    Add(5, 'quit');
    FShotPos := 0;
    FShotWait := FShots[0].Wait;
    Exit;
  end;
  if (Length(FShots) = 0) and (GetEnvironmentVariable('VPLC_GROUPS_TEST') <> '') then
  begin
    // the trees of groups of the tag table and the watch table, sorting; Import SCL on the Data blocks
    DeleteFile(FShotDir + 'grp_check.txt');
    Add(10, 'ipc', 'ex 33');
    Add(5, 'io', 'tags');
    Add(5, 'screen', '5');
    Add(10, 'uiclick2', 'grpadd:0');
    Add(5, 'grp', 'type Motor');
    Add(5, 'uiclick2', 'grpadd:0');
    Add(5, 'grp', 'type Lamps');
    Add(10, 'uiclick2', 'grpsel:0');
    Add(10, 'uiclick2', 'taggrp:2');
    Add(5, 'uiclick2', 'ctx:1');
    Add(10, 'uiclick2', 'taggrp:3');
    Add(5, 'uiclick2', 'ctx:1');
    Add(10, 'uiclick2', 'taggrp:4');
    Add(5, 'uiclick2', 'ctx:2');
    Add(10, 'uiclick2', 'taggrp:5');
    Add(5, 'uiclick2', 'ctx:2');
    Add(10, 'uiclick2', 'grpopen:1');
    Add(30, 'shot', 'groups_1_all_tag');
    Add(5, 'grp', 'dump all');
    Add(5, 'uiclick2', 'grpsel:1');
    Add(10, 'uiclick2', 'tagadd:0');
    Add(5, 'grp', 'commit');
    Add(5, 'grp', 'dump motor');
    Add(30, 'shot', 'groups_2_motor');
    Add(5, 'grp', 'rename 0 1 all TAG');
    Add(5, 'grp', 'rename 0 1 Motor');
    Add(5, 'grp', 'dump renamed');
    Add(10, 'uiclick2', 'grpsel:2');
    Add(30, 'shot', 'groups_3_name_twice');
    Add(5, 'grp', 'rename 0 1 Lamps');
    Add(5, 'uiclick2', 'grpsel:0');
    Add(10, 'uiclick2', 'sorttag:2');
    Add(30, 'shot', 'groups_4_sorted_address');
    Add(5, 'grp', 'dump address');
    Add(10, 'uiclick2', 'sorttag:2');
    Add(5, 'grp', 'dump address down');
    Add(10, 'uiclick2', 'sorttag:1');
    Add(5, 'grp', 'dump name');
    Add(10, 'uiclick2', 'sorttag:3');
    Add(5, 'grp', 'dump type');
    Add(10, 'uiclick2', 'grpsel:1');
    Add(10, 'uiclick2', 'grpdel:0');
    Add(5, 'grp', 'dump deleted');
    Add(5, 'screen', '3');
    Add(10, 'uiclick2', 'grpadd:1');
    Add(5, 'grp', 'type Box values');
    Add(10, 'uiclick2', 'grpsel:16384');
    Add(10, 'uiclick2', 'watchrow:0');
    Add(10, 'uiclick2', 'watchgrp:0');
    Add(5, 'uiclick2', 'ctx:1');
    Add(5, 'grp', 'dump watch after row 0');
    Add(10, 'uiclick2', 'watchrow:2');
    Add(10, 'uiclick2', 'watchgrp:0');
    Add(5, 'uiclick2', 'ctx:1');
    Add(5, 'grp', 'dump watch after row 2');
    Add(10, 'uiclick2', 'grpopen:16385');
    Add(10, 'uiclick2', 'grpsel:16385');
    Add(10, 'uiclick2', 'watchadd:0');
    Add(5, 'grp', 'commit');
    Add(30, 'shot', 'groups_5_watch_group');
    Add(5, 'grp', 'dump watch group');
    Add(10, 'uiclick2', 'grpsel:16384');
    Add(10, 'uiclick2', 'sortwatch:1');
    Add(30, 'shot', 'groups_6_watch_sorted');
    Add(5, 'grp', 'dump watch name');
    Add(10, 'uiclick2', 'sortwatch:3');
    Add(5, 'grp', 'dump watch type');
    Add(5, 'screen', '4');
    Add(10, 'grp', 'dbimport test/types_dbs.scl');
    Add(30, 'shot', 'groups_7_db_import');
    Add(5, 'grp', 'projfile');
    Add(5, 'quit');
    FShotPos := 0;
    FShotWait := FShots[0].Wait;
    Exit;
  end;
  if (Length(FShots) = 0) and (GetEnvironmentVariable('VPLC_IOVIEW_TEST') <> '') then
  begin
    // the 3 views of the I/O screen, the signal table running; + Row in Watch, + Tag in the tags
    DeleteFile(FShotDir + 'io_check.txt');
    Add(10, 'ipc', 'ex 33');
    Add(10, 'fkey', '5');
    Add(5, 'io', 'tags');
    Add(5, 'screen', '2');
    Add(30, 'shot', 'ioview_1_model');
    Add(5, 'uiclick2', 'ioview:1');
    Add(10, 'io', 'door');
    Add(30, 'shot', 'ioview_2_tags');
    Add(5, 'uiclick2', 'ioview:2');
    Add(10, 'uiclick2', 'sigtags:0');
    Add(10, 'uiclick2', 'sigadd:0');
    Add(10, 'io', 'sigbad');
    Add(10, 'uiclick2', 'sigall:1');
    Add(60, 'shot', 'ioview_3_signals');
    Add(5, 'io', 'dump signals');
    Add(5, 'uiclick2', 'ioview:1');
    Add(30, 'shot', 'ioview_4_tags_driven');
    Add(5, 'screen', '3');
    Add(5, 'io', 'watchmw');
    Add(10, 'uiclick2', 'watchadd:0');
    Add(10, 'uiclick2', 'watchadd:0');
    Add(5, 'io', 'watchbad');
    Add(10, 'uiclick2', 'watchadd:0');
    Add(20, 'shot', 'ioview_5_watch');
    Add(5, 'io', 'dump watch');
    Add(5, 'screen', '5');
    Add(10, 'uiclick2', 'tagadd:0');
    Add(10, 'uiclick2', 'tagadd:0');
    Add(5, 'io', 'tagbad');
    Add(30, 'shot', 'ioview_6_tags');
    Add(5, 'io', 'dump tags');
    Add(5, 'quit');
    FShotPos := 0;
    FShotWait := FShots[0].Wait;
    Exit;
  end;
  if (Length(FShots) = 0) and (GetEnvironmentVariable('VPLC_LADSTL_TEST') <> '') then
  begin
    // the LAD boxes and STL CALLs of the SCL functions running; the STL elements; rename / version in the head
    DeleteFile(FShotDir + 'ide_check.txt');
    Add(10, 'ipc', 'ex 33');
    Add(10, 'fkey', '8');
    Add(30, 'fkey', '5');
    Add(5, 'screen', '1');
    Add(5, 'fkey', '9');
    Add(40, 'shot', 'ladstl_1_monitor');
    Add(5, 'scroll', '900');
    Add(30, 'shot', 'ladstl_2_monitor_more');
    Add(5, 'fkey', '9');
    Add(5, 'stlnet', 'STL');
    Add(20, 'shot', 'ladstl_3_stl_elements');
    Add(5, 'elem', 'showcat SCL functions (CALL)');
    Add(5, 'elem', 'open SCL functions (CALL)');
    Add(5, 'elem', 'show CALL MUX');
    Add(10, 'elem', 'hover CALL MUX');
    Add(20, 'shot', 'ladstl_4_stl_call');
    Add(10, 'ipc', 'ex 30');
    Add(5, 'screen', '1');
    Add(5, 'uiclick2', 'block:1');
    Add(10, 'ide', 'head Mean 1.1');
    Add(10, 'ide', 'code 0 1');
    Add(10, 'ide', 'code 1 0');
    Add(20, 'shot', 'ladstl_5_renamed');
    Add(5, 'quit');
    FShotPos := 0;
    FShotWait := FShots[0].Wait;
    Exit;
  end;
  if (Length(FShots) = 0) and (GetEnvironmentVariable('VPLC_IDE_TEST') <> '') then
  begin
    // auto highlight, Find Declaration (Alt+Up, Ctrl+Click), All variables / All elements, .scl export / import
    DeleteFile(FShotDir + 'ide_check.txt');
    Add(10, 'ipc', 'ex 30');
    Add(5, 'screen', '1');
    Add(10, 'ide', 'caret 0 3 BASE');
    Add(20, 'shot', 'ide_1_highlight');
    Add(5, 'ide', 'decl');
    Add(10, 'ide', 'check #BASE: its VAR CONSTANT line (network 1, line 2)');
    Add(5, 'ide', 'caret 0 3 Picked');
    Add(5, 'ide', 'decl');
    Add(10, 'ide', 'check "Elems".Picked: the DB screen, DB1, variable 2');
    Add(10, 'shot', 'ide_2_decl_db');
    Add(5, 'screen', '1');
    Add(5, 'ide', 'caret 0 4 Start');
    Add(5, 'ide', 'ctrlclick');
    Add(10, 'ide', 'check Ctrl+Click on "Start": the tags, tag 3');
    Add(5, 'screen', '1');
    Add(5, 'ide', 'caret 1 10 Avg2');
    Add(5, 'ide', 'decl');
    Add(10, 'ide', 'check "Avg2": the block FC1');
    Add(5, 'ide', 'view 0');
    Add(30, 'ide', 'viewshot ide_3_all_variables.png');
    Add(5, 'ide', 'view 1');
    Add(30, 'ide', 'viewshot ide_4_all_elements.png');
    Add(5, 'ide', 'viewclose');
    Add(5, 'ide', 'export ide_export.scl');
    Add(5, 'ide', 'import test/tia_source.scl');
    Add(10, 'ide', 'check after the import');
    Add(5, 'screen', '1');
    Add(5, 'uiclick2', 'block:3');
    Add(20, 'shot', 'ide_5_imported');
    Add(5, 'uiclick2', 'sclsrc:0');
    Add(10, 'shot', 'ide_6_menu');
    Add(5, 'quit');
    FShotPos := 0;
    FShotWait := FShots[0].Wait;
    Exit;
  end;
  if (Length(FShots) = 0) and (GetEnvironmentVariable('VPLC_STRINGS_TEST') <> '') then
  begin
    // the examples of the SCL elements and of strings, running: the DB values, the watch table, the monitor
    Add(10, 'ipc', 'ex 31');
    Add(10, 'fkey', '8');
    Add(30, 'fkey', '5');
    Add(30, 'screen', '4');
    Add(20, 'shot', 'strings_1_db');
    Add(5, 'screen', '3');
    Add(20, 'shot', 'strings_2_watch');
    Add(5, 'screen', '1');
    Add(5, 'fkey', '9');
    Add(30, 'shot', 'strings_3_monitor');
    Add(5, 'fkey', '9');
    Add(10, 'ipc', 'ex 30');
    Add(10, 'fkey', '8');
    Add(30, 'fkey', '5');
    Add(30, 'screen', '4');
    Add(20, 'shot', 'elements_1_db');
    Add(5, 'screen', '1');
    Add(5, 'fkey', '9');
    Add(30, 'shot', 'elements_2_monitor');
    Add(5, 'fkey', '9');
    Add(10, 'ipc', 'ex 32');
    Add(10, 'fkey', '8');
    Add(30, 'fkey', '5');
    Add(60, 'screen', '4');
    Add(20, 'shot', 'long_1_db');
    Add(5, 'screen', '3');
    Add(20, 'shot', 'long_2_watch');
    Add(5, 'quit');
    FShotPos := 0;
    FShotWait := FShots[0].Wait;
    Exit;
  end;
  if (Length(FShots) = 0) and (GetEnvironmentVariable('VPLC_ELEMS_TEST') <> '') then
  begin
    // the SCL elements panel: categories, a double click at the caret, a drag into the code, the menu,
    // the project's elements
    DeleteFile(FShotDir + 'elems_check.txt');
    Add(10, 'ipc', 'ex 15');
    Add(5, 'screen', '1');
    Add(10, 'uiclick2', 'net:0');
    Add(5, 'uiclick2', 'addscl:0');
    Add(5, 'uiclick2', 'ctx:1');
    Add(10, 'elem', 'caret 1 0 0');
    Add(10, 'shot', 'elems_1_panel');
    Add(5, 'elem', 'show IF ... THEN');
    Add(5, 'elem', 'dbl IF ... THEN');
    Add(5, 'elem', 'type "Start"');
    Add(5, 'elem', 'check a double click on IF ... THEN, then typed "Start" at the caret');
    Add(5, 'elem', 'showcat Program control');
    Add(5, 'elem', 'open Program control');
    Add(5, 'elem', 'showcat Comparison / selection');
    Add(5, 'elem', 'open Comparison / selection');
    Add(5, 'elem', 'show MUX');
    Add(10, 'elem', 'hover MUX');
    Add(10, 'shot', 'elems_2_hover');
    Add(5, 'elem', 'caret 1 1 4');
    Add(5, 'elem', 'show MUX');
    Add(10, 'elem', 'drag MUX');
    Add(10, 'elem', 'check MUX dragged onto the caret in line 2');
    Add(10, 'shot', 'elems_3_dropped');
    Add(5, 'elem', 'show SEL');
    Add(5, 'elem', 'rclick SEL');
    Add(10, 'shot', 'elems_4_menu');
    Add(5, 'uiclick2', 'ctx:1');
    Add(5, 'elem', 'check the menu: Copy of SEL');
    Add(5, 'elem', 'showcat Comparison / selection');
    Add(5, 'elem', 'open Comparison / selection');
    Add(5, 'elem', 'showcat Project: Data blocks');
    Add(5, 'elem', 'open Project: Data blocks');
    Add(5, 'elem', 'show "Temp".Setpoint');
    Add(10, 'elem', 'hover "Temp".Setpoint');
    Add(10, 'shot', 'elems_5_project');
    Add(5, 'quit');
    FShotPos := 0;
    FShotWait := FShots[0].Wait;
    Exit;
  end;
  if (Length(FShots) = 0) and (GetEnvironmentVariable('VPLC_MENUS_TEST') <> '') then
  begin
    // + network: above / below the selected network; the right button on a network head and on a text
    DeleteFile(FShotDir + 'insert_check.txt');
    Add(10, 'ipc', 'ex 19');
    Add(5, 'screen', '1');
    Add(10, 'uiclick2', 'net:1');
    Add(5, 'uiclick2', 'addscl:0');
    Add(10, 'shot', 'menus_1_add_above_below');
    Add(5, 'uiclick2', 'ctx:0');
    Add(10, 'ladins', 'check SCL above network 2: it is network 2 now');
    Add(5, 'ladins', 'type 1');
    Add(10, 'uirclick', 'stl:1');
    Add(10, 'shot', 'menus_2_text_menu');
    Add(5, 'uiclick2', 'ctx:6');
    Add(5, 'uirclick', 'stl:1');
    Add(5, 'uiclick2', 'ctx:3');
    Add(10, 'ladins', 'check select all + copy: the clipboard has the text');
    Add(5, 'uirclick', 'stl:1');
    Add(5, 'uiclick2', 'ctx:5');
    Add(10, 'ladins', 'check delete: the text is gone');
    Add(5, 'uirclick', 'stl:1');
    Add(5, 'uiclick2', 'ctx:4');
    Add(10, 'ladins', 'check paste: the text is back');
    Add(5, 'ladins', 'esc');
    Add(5, 'uirclick', 'net:0');
    Add(10, 'shot', 'menus_3_network_menu');
    Add(5, 'uiclick2', 'ctx:1');
    Add(10, 'ladins', 'check LAD below network 1: it is network 2');
    Add(5, 'quit');
    FShotPos := 0;
    FShotWait := FShots[0].Wait;
    Exit;
  end;
  if (Length(FShots) = 0) and (GetEnvironmentVariable('VPLC_XNET_TEST') <> '') then
  begin
    // a drop needs a wire under it; elements go from one network into another
    DeleteFile(FShotDir + 'insert_check.txt');
    Add(10, 'ipc', 'ex 6');
    Add(5, 'screen', '1');
    Add(20, 'ladins', 'xhold 0 0 2 0 1 3');
    Add(10, 'shot', 'xnet_0_no_wire');
    Add(5, 'ladins', 'xdrop 0 1 3');
    Add(10, 'ladins', 'check onto empty cells: refused');
    Add(5, 'ladins', 'xhold 0 0 1 1 0 4');
    Add(10, 'shot', 'xnet_1_over_other_network');
    Add(5, 'ladins', 'xdrop 1 0 4');
    Add(10, 'ladins', 'check into the other network onto a wire');
    Add(5, 'ladins', 'xdrag 1 0 0 0 0 2');
    Add(10, 'ladins', 'check back onto an element: inserted');
    Add(10, 'shot', 'xnet_2_after');
    Add(5, 'ladins', 'undo');
    Add(10, 'ladins', 'check undo of the move between networks');
    Add(5, 'quit');
    FShotPos := 0;
    FShotWait := FShots[0].Wait;
    Exit;
  end;
  if (Length(FShots) = 0) and (GetEnvironmentVariable('VPLC_NETKIND_TEST') <> '') then
  begin
    // the language of a network switches only while it is empty
    DeleteFile(FShotDir + 'insert_check.txt');
    Add(10, 'ipc', 'ex 19');
    Add(5, 'screen', '1');
    Add(10, 'uiclick2', 'netkind:0');
    Add(10, 'ladins', 'check LAD with code stays LAD');
    Add(5, 'uiclick2', 'addlad:0');
    Add(5, 'uiclick2', 'ctx:1');
    Add(10, 'uiclick2', 'netkind:1');
    Add(10, 'ladins', 'check empty LAD switches to SCL');
    Add(5, 'ladins', 'type 1');
    Add(10, 'uiclick2', 'netkind:1');
    Add(10, 'ladins', 'check SCL with code stays SCL');
    Add(10, 'shot', 'netkind_1_locked');
    Add(5, 'quit');
    FShotPos := 0;
    FShotWait := FShots[0].Wait;
    Exit;
  end;
  if (Length(FShots) = 0) and (GetEnvironmentVariable('VPLC_DELWIRE_TEST') <> '') then
  begin
    // a deleted LAD element leaves a wire where the rung goes through it
    DeleteFile(FShotDir + 'insert_check.txt');
    Add(10, 'ipc', 'ex 6');
    Add(5, 'screen', '1');
    Add(20, 'shot', 'delwire_0_before');
    Add(5, 'ladins', 'click 0 0 1');
    Add(5, 'ladins', 'del');
    Add(10, 'ladins', 'check del in the rung: wire');
    Add(5, 'ladins', 'click 0 1 0');
    Add(5, 'ladins', 'del');
    Add(10, 'ladins', 'check del of the only contact of a branch: open, no wire');
    Add(5, 'ladins', 'click 0 0 2');
    Add(5, 'ladins', 'ctrlx');
    Add(10, 'ladins', 'check cut in the rung: wire');
    Add(5, 'ladins', 'click 0 0 7');
    Add(5, 'ladins', 'del');
    Add(10, 'ladins', 'check del of the coil at the end: empty');
    Add(10, 'shot', 'delwire_1_after');
    Add(5, 'quit');
    FShotPos := 0;
    FShotWait := FShots[0].Wait;
    Exit;
  end;
  if (Length(FShots) = 0) and (GetEnvironmentVariable('VPLC_INSERT_TEST') <> '') then
  begin
    // LAD drag and drop onto an element: it is inserted there, the others slide (no overwrite)
    DeleteFile(FShotDir + 'insert_check.txt');
    Add(10, 'ipc', 'ex 19');
    Add(5, 'screen', '1');
    Add(20, 'shot', 'insert_0_before');
    Add(5, 'ladins', 'hold 2 0 0 0 4');
    Add(10, 'shot', 'insert_0b_ghost_contact');
    Add(5, 'ladins', 'let go');
    Add(5, 'ladins', 'drag 0 0 0 0 1');
    Add(10, 'ladins', 'check swap: CTU 0, NO 2 (the box keeps its width), coil 7');
    Add(10, 'shot', 'insert_1_swap');
    Add(5, 'ladins', 'drag 0 0 7 0 3');
    Add(10, 'ladins', 'check coil to 3: wires slide right');
    Add(5, 'ladins', 'drag 1 0 0 0 5');
    Add(10, 'ladins', 'check NO of network 2 to 5: CTD slides left');
    Add(10, 'shot', 'insert_2_moved');
    Add(5, 'ladins', 'undo');
    Add(10, 'ladins', 'check undo: network 2 back');
    Add(5, 'ladins', 'click 0 0 0');
    Add(5, 'ladins', 'ctrlc');
    Add(5, 'ladins', 'click 0 0 1');
    Add(5, 'ladins', 'ctrlv');
    Add(10, 'ladins', 'click 0 0 1');
    Add(5, 'ladins', 'ctrlv');
    Add(10, 'ladins', 'check pasted boxes keep their width');
    Add(10, 'shot', 'insert_3_boxes');
    Add(5, 'ladins', 'drag 0 0 4 0 1');
    Add(10, 'ladins', 'check box onto box: every box keeps its width');
    Add(10, 'shot', 'insert_4_box_drop');
    Add(5, 'quit');
    FShotPos := 0;
    FShotWait := FShots[0].Wait;
    Exit;
  end;
  if (Length(FShots) = 0) and (GetEnvironmentVariable('VPLC_UNDO_TEST') <> '') then
  begin
    // a click on the wide part of a LAD box leaves it in place; undo / redo of LAD, networks and text
    DeleteFile(FShotDir + 'undo_check.txt');
    Add(10, 'ipc', 'ex 19');
    Add(5, 'screen', '1');
    Add(20, 'undo', 'press');
    Add(3, 'undo', 'release');
    Add(5, 'undo', 'check box stays (click)');
    Add(5, 'undo', 'press');
    Add(3, 'undo', 'jitter');
    Add(3, 'undo', 'release');
    Add(5, 'undo', 'check box stays (a few pixels)');
    Add(5, 'undo', 'press');
    Add(3, 'undo', 'move 2');
    Add(10, 'shot', 'undo_1_dragging');
    Add(3, 'undo', 'release far');
    Add(5, 'undo', 'check box moved 2 right');
    Add(5, 'uiclick2', 'addlad:0');
    Add(5, 'uiclick2', 'ctx:1');
    Add(5, 'undo', 'check 4 networks');
    Add(10, 'shot', 'undo_2_toolbar');
    Add(5, 'uiclick2', 'undo:0');
    Add(5, 'undo', 'check 3 networks');
    Add(5, 'uiclick2', 'undo:0');
    Add(5, 'undo', 'check box back');
    Add(5, 'uiclick2', 'redo:0');
    Add(5, 'undo', 'check box moved 2 right');
    Add(5, 'uiclick2', 'redo:0');
    Add(5, 'undo', 'check 4 networks');
    Add(5, 'uiclick2', 'addscl:0');
    Add(5, 'uiclick2', 'ctx:1');
    Add(5, 'undo', 'type');
    Add(10, 'undo', 'check text typed');
    Add(10, 'shot', 'undo_3_text');
    Add(5, 'undo', 'ctrlz');
    Add(5, 'undo', 'check text gone, SCL network there');
    Add(5, 'undo', 'ctrlz');
    Add(5, 'undo', 'check 4 networks');
    Add(5, 'undo', 'ctrly');
    Add(5, 'undo', 'ctrly');
    Add(10, 'undo', 'check text typed');
    Add(5, 'quit');
    FShotPos := 0;
    FShotWait := FShots[0].Wait;
    Exit;
  end;
  if (Length(FShots) = 0) and (GetEnvironmentVariable('VPLC_TIMERS_TEST') <> '') then
  begin
    // the timer / counter examples in the program editor, running
    Add(10, 'ipc', 'ex 22');
    Add(5, 'run');
    Add(5, 'screen', '1');
    Add(5, 'ipc', 'in on');
    Add(200, 'shot', 'tc_1_timers_s7-300');
    Add(10, 'ipc', 'ex 20');
    Add(5, 'run');
    Add(5, 'screen', '1');
    Add(5, 'ipc', 'in on');
    Add(200, 'shot', 'tc_2_timers_s7-1500');
    Add(10, 'ipc', 'ex 23');
    Add(5, 'run');
    Add(5, 'screen', '1');
    Add(30, 'shot', 'tc_3_counters_s7-300');
    Add(10, 'ipc', 'ex 25');
    Add(5, 'screen', '7');
    Add(10, 'shot', 'tc_4_examples_list');
    Add(5, 'quit');
    FShotPos := 0;
    FShotWait := FShots[0].Wait;
    Exit;
  end;
  if (Length(FShots) = 0) and (GetEnvironmentVariable('VPLC_SAVEASK_TEST') <> '') then
  begin
    // unsaved changes: New, Load sample, a project file and the window's close ask Save / Don't save / Cancel
    DeleteFile(FShotDir + 'saveask_check.txt');
    Add(10, 'sample', '13');
    Add(5, 'screen', '7');
    Add(5, 'saveask', 'change');
    Add(10, 'saveask', 'click new');
    Add(10, 'shot', 'saveask_1_new');
    Add(5, 'saveask', 'answer 0');
    Add(5, 'saveask', 'check cancel keeps the changed project');
    Add(10, 'saveask', 'click new');
    Add(5, 'saveask', 'answer 1');
    Add(10, 'saveask', 'check save writes the file, then New');
    Add(5, 'ipc', 'refresh');
    Add(5, 'uiclick2', 'folder:0');
    Add(10, 'shot', 'saveask_1a_folder_menu');
    Add(5, 'uiclick2', 'ctx:1');
    Add(5, 'saveask', 'change');
    Add(10, 'saveask', 'click example');
    Add(10, 'shot', 'saveask_1b_example');
    Add(5, 'saveask', 'answer 2');
    Add(10, 'saveask', 'check don''t save loads the sample');
    Add(5, 'saveask', 'check the example file stays: no file name');
    Add(5, 'saveask', 'click example');
    Add(10, 'saveask', 'check no changes: only the load question');
    Add(5, 'saveask', 'answer 1');
    Add(10, 'saveask', 'check don''t save loads the sample');
    Add(5, 'ipc', 'folder 0');
    Add(5, 'saveask', 'change');
    Add(10, 'saveask', 'click file');
    Add(10, 'shot', 'saveask_2_file');
    Add(5, 'saveask', 'answer 0');
    Add(5, 'saveask', 'check cancel keeps the changed project');
    Add(5, 'saveask', 'close');
    Add(10, 'shot', 'saveask_3_close');
    Add(5, 'saveask', 'answer 0');
    Add(5, 'saveask', 'check cancel: the program runs on');
    Add(5, 'saveask', 'close');
    Add(5, 'saveask', 'answer 2');
    Add(5, 'saveask', 'check don''t save: the program ends');
    Add(30, 'quit');
    FShotPos := 0;
    FShotWait := FShots[0].Wait;
    Exit;
  end;
  if (Length(FShots) = 0) and (GetEnvironmentVariable('VPLC_HELP_TEST') <> '') then
  begin
    // the STL help of the Elements panel: select (drag, double click, triple click), copy, the right
    // button (SCL has the elements list: VPLC_ELEMS_TEST)
    DeleteFile(FShotDir + 'help_check.txt');
    Add(10, 'sample', '13');
    Add(5, 'screen', '1');
    Add(5, 'ob1');
    Add(5, 'stlnet', 'STL');
    Add(10, 'helpsel', '2,0,2,3,1');
    Add(5, 'helpcopy', 'drag 2,0..2,3');
    Add(10, 'shot', 'help_1_selected');
    Add(5, 'helpsel', '8,17,8,17,2');
    Add(5, 'helpcopy', 'double click 8,17');
    Add(5, 'helpsel', '13,4,13,4,3');
    Add(5, 'helpcopy', 'triple click 13');
    Add(5, 'helpsel', '0,0,2,4,1');
    Add(5, 'helpcopy', 'drag over 3 lines');
    Add(5, 'helprclick', '9,3');
    Add(10, 'shot', 'help_2_menu');
    Add(5, 'esc');
    Add(10, 'helpsel', '4,0,4,8,1');
    Add(5, 'helpcopy', 'STL drag 4,0..4,8');
    Add(10, 'shot', 'help_4_stl');
    Add(5, 'quit');
    FShotPos := 0;
    FShotWait := FShots[0].Wait;
    Exit;
  end;
  if (Length(FShots) = 0) and (GetEnvironmentVariable('VPLC_EXPORT_TEST') <> '') then
  begin
    // the right click menus and the exports of every kind (into shots\export), the watch table's
    // Save / Open, the question before a project file is loaded
    Add(10, 'sample', '13');
    Add(5, 'screen', '1');
    Add(10, 'uirclick', 'block:3');
    Add(10, 'shot', 'exp_1_block_menu');
    Add(5, 'esc');
    Add(10, 'uirclick', 'net:0');
    Add(10, 'shot', 'exp_2_net_menu');
    Add(5, 'esc');
    Add(5, 'screen', '4');
    Add(10, 'uirclick', 'db:0');
    Add(10, 'shot', 'exp_3_db_menu');
    Add(5, 'esc');
    Add(10, 'uirclick', 'udt:0');
    Add(10, 'shot', 'exp_4_udt_menu');
    Add(5, 'esc');
    Add(5, 'run');
    Add(5, 'set', '2=1');
    Add(5, 'press', '0');
    Add(60, 'release', '0');
    Add(5, 'screen', '1');
    Add(5, 'ob1');
    Add(10, 'exportall');
    Add(5, 'screen', '3');
    Add(10, 'uiclick2', 'watchmenu:0');
    Add(10, 'shot', 'exp_5_watch_menu');
    Add(5, 'esc');
    Add(5, 'watchfile', 'save');
    Add(5, 'watchfile', 'clear');
    Add(5, 'watchfile', 'open');
    Add(10, 'shot', 'exp_6_watch_opened');
    Add(5, 'screen', '2');
    Add(20, 'shot', 'exp_7_io');
    Add(5, 'screen', '5');
    Add(10, 'shot', 'exp_8_tags');
    Add(5, 'projfile', 'save');
    Add(5, 'screen', '7');
    Add(10, 'projfile', 'click');
    Add(10, 'shot', 'exp_9_ask_load');
    Add(5, 'uiclick2', 'ask:0');
    Add(10, 'projfile', 'check:cancel keeps the project');
    Add(5, 'projfile', 'click');
    Add(10, 'uiclick2', 'ask:2');   // the project has changes: Don't save, then the file loads
    Add(20, 'projfile', 'check:OK loads the file');
    Add(5, 'projfile', 'delete');
    Add(5, 'quit');
    FShotPos := 0;
    FShotWait := FShots[0].Wait;
    Exit;
  end;
  if (Length(FShots) = 0) and (GetEnvironmentVariable('VPLC_DEV_MENU_TEST') <> '') then
  begin
    // Project screen > Developer menu: show, on top, on top off, close
    DeleteFile(FShotDir + 'dev_menu.txt');
    Add(10, 'sample', '13');
    Add(5, 'screen', '7');
    Add(10, 'uiclick', 'dev:-1');
    Add(10, 'shot', 'dev_menu_1');
    Add(5, 'uiclick', 'dev:0');
    Add(20, 'infocheck', 'show');
    Add(5, 'uiclick', 'dev:-1');
    Add(5, 'uiclick', 'dev:1');
    Add(20, 'infocheck', 'on top');
    Add(5, 'uiclick', 'dev:-1');
    Add(10, 'shot', 'dev_menu_2_checked');
    Add(5, 'uiclick', 'dev:1');
    Add(20, 'infocheck', 'on top off');
    Add(5, 'uiclick', 'dev:-1');
    Add(5, 'uiclick', 'dev:2');
    Add(20, 'infocheck', 'close');
    Add(5, 'uiclick', 'dev:0');
    Add(20, 'infox');
    Add(20, 'infocheck', 'X button (the app runs on)');
    Add(5, 'uiclick', 'dev:-1');
    Add(10, 'shot', 'dev_menu_3_closed');
    Add(5, 'esc');
    Add(5, 'quit');
    FShotPos := 0;
    FShotWait := FShots[0].Wait;
    Exit;
  end;
  if (Length(FShots) = 0) and (GetEnvironmentVariable('VPLC_KEY_UI_TEST') <> '') then
  begin
    // AI menu > Set ANTHROPIC_API_KEY, through the mouse of the UI: save as the variable, check,
    // remove; save encrypted, check, delete. Only with VPLC_KEY_VAR (a test variable and file): the
    // real key is never touched
    Add(10, 'sample', '13');
    Add(5, 'screen', '1');
    if ClaudeKeyVar = 'ANTHROPIC_API_KEY' then
    begin
      Add(5, 'quit');
      FShotPos := 0;
      FShotWait := FShots[0].Wait;
      Exit;
    end;
    Add(10, 'uiclick', 'menu:-1');
    Add(10, 'shot', 'claude_key_0_menu');
    Add(5, 'uiclick', 'menu:1');
    Add(10, 'keytype', 'dummy-ui-value');
    Add(10, 'shot', 'claude_key_1_typed');
    Add(5, 'uiclick', 'key:0');
    Add(10, 'keycheck', 'var');
    Add(10, 'shot', 'claude_key_2_saved');
    Add(5, 'uiclick', 'key:2');
    Add(10, 'keycheck', 'removed');
    Add(5, 'keytype', 'dummy-encrypted');
    Add(5, 'uiclick', 'key:1');
    Add(10, 'keycheck', 'file');
    Add(5, 'uiclick', 'key:3');
    Add(10, 'keycheck', 'deleted');
    Add(5, 'uiclick', 'key:4');
    Add(10, 'keycheck', 'closed');
    // Remove ANTHROPIC_API_KEY: both kinds saved, Cancel keeps them, Remove takes both
    Add(5, 'uiclick', 'menu:-1');
    Add(5, 'uiclick', 'menu:1');
    Add(5, 'keytype', 'dummy-ui-value');
    Add(5, 'uiclick', 'key:0');
    Add(5, 'keytype', 'dummy-encrypted');
    Add(5, 'uiclick', 'key:1');
    Add(5, 'uiclick', 'key:4');
    Add(10, 'uiclick', 'menu:-1');
    Add(10, 'shot', 'claude_key_5_ai_menu');
    Add(5, 'uiclick', 'menu:2');
    Add(10, 'shot', 'claude_key_6_remove_ask');
    Add(5, 'uiclick', 'rm:0');
    Add(10, 'keycheck', 'cancel');
    Add(5, 'uiclick', 'menu:-1');
    Add(5, 'uiclick', 'menu:2');
    Add(5, 'uiclick', 'rm:1');
    Add(10, 'keycheck', 'removeall');
    Add(5, 'uiclick', 'menu:-1');
    Add(10, 'shot', 'claude_key_7_nothing_to_remove');
    Add(5, 'esc');
    Add(5, 'uiclick', 'menu:-1');
    Add(5, 'uiclick', 'menu:0');
    Add(20, 'chatshot', 'claude_key_3_chat_nokey');
    Add(5, 'chatclick', '7');
    Add(10, 'keycheck', 'fromchat');
    Add(10, 'shot', 'claude_key_4_dialog_from_chat');
    Add(5, 'quit');
    FShotPos := 0;
    FShotWait := FShots[0].Wait;
    Exit;
  end;
  if (Length(FShots) = 0) and (GetEnvironmentVariable('VPLC_CLAUDE_LIVE') <> '') then
  begin
    // a real request to Claude (the key from ANTHROPIC_API_KEY or the saved one): the prompt in
    // VPLC_CLAUDE_PROMPT, waits until Claude is done, allows its download, writes the chat
    Add(10, 'sample', '13');
    Add(20, 'run');
    Add(5, 'ob1');
    Add(5, 'claudeopen');
    // a prompt in a UTF-8 file (an environment variable goes through the ANSI code page)
    FDragShot := GetEnvironmentVariable('VPLC_CLAUDE_PROMPT');
    if FileExists(GetEnvironmentVariable('VPLC_CLAUDE_PROMPT_FILE')) then
      with TStringList.Create do
      try
        LoadFromFile(GetEnvironmentVariable('VPLC_CLAUDE_PROMPT_FILE'));
        FDragShot := TrimRight(Text);
      finally
        Free;
      end;
    Add(5, 'claudeask', FDragShot);
    Add(30, 'claudewait', 'allow:1200');
    Add(20, 'shot', 'claude_live_1');
    Add(5, 'claudedump', '');
    Add(10, 'quit');
    FWaitStep := -1;
    FShotPos := 0;
    FShotWait := FShots[0].Wait;
    Exit;
  end;
  if (Length(FShots) = 0) and (GetEnvironmentVariable('VPLC_CLAUDE_MOCK') <> '') then
  begin
    // only the Claude panel, against test\claudemock.py (ANTHROPIC_BASE_URL=http://127.0.0.1:8765)
    Add(10, 'sample', '13');
    Add(20, 'run');
    Add(5, 'fc1');
    Add(5, 'claudeopen');
    Add(10, 'chatattach', 'test/attach_test.txt');
    Add(5, 'chatattach', 'test/attach_test.bmp');
    Add(5, 'chatattach', 'test/attach_test.jpg');
    Add(10, 'chatshot', 'claude_0_files');
    Add(5, 'chattype', 'Count %MW100 up every cycle in OB1 and check that it runs.');
    Add(150, 'chatshot', 'claude_1_confirm');
    Add(5, 'chatclick', '5');
    Add(150, 'chatshot', 'claude_2_done');
    // select and copy: a drag over two lines, a double click (a word), a triple click (a message)
    Add(5, 'chattop');
    Add(10, 'chatselect', '1,4,3,12,1');
    Add(5, 'chatcopy', 'chat_copy_drag.txt');
    Add(10, 'chatshot', 'claude_2b_selected');
    Add(5, 'chatselect', '0,2,0,2,2');
    Add(5, 'chatcopy', 'chat_copy_word.txt');
    Add(5, 'chatselect', '0,2,0,2,3');
    Add(5, 'chatcopy', 'chat_copy_message.txt');
    Add(5, 'chatimgmenu');
    Add(10, 'chatshot', 'claude_2e_image_menu');
    Add(5, 'esc');
    Add(5, 'chatimgsave', 'chat_image_saved.png');
    Add(5, 'chatexport', 'claude_chat.txt');
    Add(5, 'chatexport', 'claude_chat.pdf');
    Add(5, 'chatexport', 'claude_chat.png');
    Add(5, 'chatmenu', '10');
    Add(10, 'chatshot', 'claude_2c_export_menu');
    Add(5, 'chatmenu', '10');
    Add(5, 'chatmenu', '9');
    Add(10, 'chatshot', 'claude_2d_auditor_menu');
    Add(5, 'chatclick', '1');
    Add(30, 'chatshot', 'claude_3_undone');
    Add(5, 'shot', 'claude_3_main');
    Add(10, 'quit');
    FShotPos := 0;
    FShotWait := FShots[0].Wait;
    Exit;
  end;
  if Length(FShots) = 0 then
  begin
    ForceDirectories(FShotDir);
    AddFamily('s71200', '7');
    AddFamily('s7300', '1');
    Add(5, 'screen', '1');
    Add(5, 'stlclick', '');
    Add(5, 'type', '');
    Add(5, 'compile', '');
    Add(20, 'shot', 's7300_10_stl_edit');
    Add(5, 'esc', '');
    Add(5, 'screen', '0');
    Add(5, 'busfault', '');
    Add(40, 'shot', 's7300_11_busfault_stop');
    Add(5, 'busfault', '');
    Add(10, 'sample', '1');
    Add(20, 'run');
    Add(10, 'set', '2=1');
    Add(5, 'press', '0');
    Add(8, 'release', '0');
    Add(5, 'fc1', '');
    Add(5, 'monitor', '');
    Add(150, 'shot', 's7300_12_scl_monitor');
    Add(5, 'fb1', '');
    Add(5, 'monitor', '');
    Add(40, 'shot', 's7300_14_fb_monitor');
    Add(5, 'focus0', '');
    Add(5, 'vardrag', '');
    Add(20, 'shot', 's7300_15_var_drag');
    Add(5, 'ob1', '');
    Add(5, 'cell', '3,0,0');
    Add(10, 'ladband', '');
    Add(20, 'shot', 's7300_16_lad_band');
    Add(5, 'ladmove', '');
    Add(20, 'shot', 's7300_17_lad_moved');
    Add(5, 'ladundo', '');
    Add(20, 'shot', 's7300_18_lad_undo');
    Add(5, 'cell', '3,0,7');
    Add(10, 'ladgrow', '');
    Add(20, 'shot', 's7300_19_lad_grow');
    Add(5, 'ladhwheel', '');
    Add(20, 'shot', 's7300_20_lad_hscroll');
    Add(5, 'ladmenu', '');
    Add(20, 'shot', 's7300_21_lad_menu');
    Add(5, 'ladmenucopy', '');
    Add(5, 'ladmenu2', '');
    Add(20, 'shot', 's7300_22_lad_menu_paste');
    Add(5, 'ladmenupaste', '');
    Add(20, 'shot', 's7300_23_lad_pasted');
    AddFamily('s7400', '4');
    AddFamily('s71500', '13');
    Add(5, 'screen', '1');
    Add(5, 'monitor', '');
    Add(5, 'scroll', '2000');
    Add(40, 'shot', 's71500_10_stl_monitor');
    Add(5, 'cell', '-1,0,1');
    Add(20, 'shot', 's71500_17_lad_call_pins');
    Add(5, 'screen', '0');
    Add(20, 'shot', 's71500_11_display');
    Add(5, 'fc1', '');
    Add(5, 'monitor', '');
    Add(60, 'shot', 's71500_12_scl_monitor');
    Add(5, 'fb1', '');
    Add(5, 'monitor', '');
    Add(40, 'shot', 's71500_14_fb_monitor');
    Add(5, 'fc2', '');
    Add(5, 'monitor', '');
    Add(40, 'shot', 's71500_16_fc_monitor');
    Add(5, 'db', '1');
    Add(20, 'shot', 's71500_15_instance_db');
    Add(5, 'fc1', '');
    Add(5, 'scltype', '');
    Add(5, 'compile', '');
    Add(20, 'shot', 's71500_13_scl_edit');
    Add(5, 'fc1', '');
    Add(5, 'edsel', '');
    Add(20, 'shot', 's71500_18_edit_select');
    Add(5, 'edcol', '');
    Add(20, 'shot', 's71500_19_edit_column');
    Add(5, 'edfind', '');
    Add(20, 'shot', 's71500_20_edit_find');
    Add(5, 'edcomp', '');
    Add(20, 'shot', 's71500_21_edit_complete');
    Add(5, 'edfocus', '');
    Add(5, 'eddrag', '');
    Add(20, 'shot', 's71500_22_edit_drag');
    Add(5, 'eddbl', '');
    Add(20, 'shot', 's71500_23_edit_dblclick');
    Add(5, 'uiclick', 'menu:-1');
    Add(10, 'shot', 's71500_24_claude_menu');
    Add(5, 'uiclick', 'menu:0');
    Add(30, 'chatshot', 's71500_25_claude_chat');
    Add(5, 'claudeclose', '');
    Add(5, 'edundo', '');
    Add(10, 'quit');
    FShotPos := 0;
    FShotWait := FShots[0].Wait;
    Exit;
  end;
  if FShotPos > High(FShots) then Exit;
  if FShotWait > 0 then
  begin
    Dec(FShotWait);
    Exit;
  end;
  St := FShots[FShotPos];
  Inc(FShotPos);
  if FShotPos <= High(FShots) then FShotWait := FShots[FShotPos].Wait;
  if (St.Cmd = 'mclick') or (St.Cmd = 'mdown') or (St.Cmd = 'mup') then
  begin
    Pt := UI.DesignToPixel(StrToFloat(Copy(St.Arg, 1, Pos(',', St.Arg) - 1)),
      StrToFloat(Copy(St.Arg, Pos(',', St.Arg) + 1, 20)));
    UI.MouseMove(Pt.X, Pt.Y);
    if St.Cmd <> 'mup' then UI.MouseDown(Pt.X, Pt.Y);
    if St.Cmd <> 'mdown' then UI.MouseUp(Pt.X, Pt.Y);
  end;
  case St.Cmd of
    'sample': UI.LoadSampleFor(StrToInt(St.Arg));
    'screen': UI.Screen := TScreen(StrToInt(St.Arg));
    'run': UI.Rt.CmdRun;
    'stop': UI.Rt.CmdStop;
    'set':
      begin
        P := StrToInt(Copy(St.Arg, 1, Pos('=', St.Arg) - 1));
        V := StrToInt(Copy(St.Arg, Pos('=', St.Arg) + 1, 9));
        UI.Rt.SetSimBit(UI.Rt.Model.DIByte + P div 8, P mod 8, V <> 0);
      end;
    'press': UI.Rt.SetSimBit(UI.Rt.Model.DIByte, StrToInt(St.Arg), True);
    'release': UI.Rt.SetSimBit(UI.Rt.Model.DIByte, StrToInt(St.Arg), False);
    'monitor': UI.Monitor := True;
    'scroll': UI.KeyDown(ukNone, #0, []);
    'busfault': UI.Rt.CmdBusFault(not UI.Rt.BusFault);
    'esc': UI.KeyDown(ukEsc, #0, []);
    'shot': SaveShot(FShotDir + St.Arg + '.png');
    'chatshot': SaveChatShot(FShotDir + St.Arg + '.png');
    'quit':
      begin
        FRunning := False;
        Application.Terminate;
      end;
  end;
  if St.Cmd = 'scroll' then
  begin
    UI.MouseMove(Renderer.Width * 0.5, Renderer.Height * 0.5);
    UI.Wheel(-StrToFloat(St.Arg) / 60);
    if St.Arg = '0' then UI.Wheel(1000);
  end;
  if St.Cmd = 'stlclick' then UI.FocusStl(0, 2, 6);
  if St.Cmd = 'fc1' then UI.ShowBlock(bkFC, 1);
  if St.Cmd = 'fb1' then UI.ShowBlock(bkFB, 1);
  if St.Cmd = 'cell' then
    UI.SelectCell(StrToInt(Copy(St.Arg, 1, Pos(',', St.Arg) - 1)),
      StrToInt(Copy(St.Arg, Pos(',', St.Arg) + 1, 1)), StrToInt(Copy(St.Arg, Length(St.Arg), 1)));
  if St.Cmd = 'fc2' then UI.ShowBlock(bkFC, 2);
  if St.Cmd = 'db' then UI.ShowDataType(StrToInt(St.Arg) - UI.Project.DBCount);
  if St.Cmd = 'udt' then UI.ShowDataType(StrToInt(St.Arg));
  if St.Cmd = 'scltype' then
  begin
    // a new line with an error, typed like the keyboard does it (auto indent after THEN)
    UI.FocusStl(0, 37, 0);
    UI.KeyDown(ukEnd, #0, []);
    UI.KeyDown(ukEnter, #0, []);
    UI.TextInput('"Motor".SpeedClass := "Motor".AvgRpm;  // REAL into INT');
  end;
  if St.Cmd = 'edsel' then
  begin
    // Notepad++ keys: a word selection over two lines; the selected word shows everywhere
    UI.FocusStl(0, 10, 12);
    UI.KeyDown(ukRight, #0, [umShift, umCtrl]);
    UI.KeyDown(ukRight, #0, [umShift, umCtrl]);
    UI.KeyDown(ukDown, #0, [umShift]);
  end;
  if St.Cmd = 'edcol' then
  begin
    // Alt+Shift+arrows: a column, then typing on every row of it
    UI.FocusStl(0, 26, 12);
    UI.KeyDown(ukDown, #0, [umShift, umAlt]);
    UI.KeyDown(ukDown, #0, [umShift, umAlt]);
    UI.KeyDown(ukDown, #0, [umShift, umAlt]);
    UI.KeyDown(ukDown, #0, [umShift, umAlt]);
    UI.TextInput('(* ');
  end;
  if St.Cmd = 'edfind' then
  begin
    UI.FocusStl(0, 0, 0);
    UI.KeyDown(ukChar, 'h', [umCtrl]);
    UI.TextInput('History');
    UI.KeyDown(ukEnter, #0, []);
    UI.KeyDown(ukF3, #0, []);
  end;
  if St.Cmd = 'edfocus' then
  begin
    UI.KeyDown(ukEsc, #0, []);
    UI.KeyDown(ukEsc, #0, []);
    UI.FocusStl(0, 8, 0);
  end;
  if St.Cmd = 'eddrag' then
  begin
    // the mouse through the UI (posted clicks would go to the real cursor): drag over 3 lines
    Pt := UI.CaretPoint;
    Pp := UI.DesignToPixel(Pt.X + 130, Pt.Y + 8);
    UI.MouseClicks := 1;
    UI.MouseMods := [];
    UI.MouseDown(Pp.X, Pp.Y);
    Pp := UI.DesignToPixel(Pt.X + 250, Pt.Y + 2 * 19 + 8);
    UI.MouseMove(Pp.X, Pp.Y);
    UI.MouseUp(Pp.X, Pp.Y);
  end;
  if St.Cmd = 'eddbl' then
  begin
    // a double click on a word: the word, and its other places light up
    Pt := UI.CaretPoint;
    // on "History" of line 13 (the caret is on line 11; the text starts at x 332)
    Pp := UI.DesignToPixel(332 + 19 * 8.7, Pt.Y + 2 * 19 + 8);
    UI.MouseClicks := 2;
    UI.MouseDown(Pp.X, Pp.Y);
    UI.MouseUp(Pp.X, Pp.Y);
    UI.MouseClicks := 1;
  end;
  if St.Cmd = 'ob1' then UI.ShowBlock(bkOB, 1);
  if St.Cmd = 'claudeopen' then UI.OpenClaude;
  if St.Cmd = 'keytype' then UI.TypeKeyField(St.Arg);
  if St.Cmd = 'chatload' then
    with TStringList.Create do
    try
      // the entries of the real run's chat, as they were
      LoadFromFile(FShotDir + 'claude_live.txt');
      FDragShot := '';
      for P := 0 to Count - 1 do
      begin
        if Copy(Strings[P], 1, 10) = 'tokens: ' + Copy(Strings[P], 9, 2) then Break;
        if (Copy(Strings[P], 1, 1) = '[') and (Pos('] ', Strings[P]) > 0) then
        begin
          SetLength(UI.Claude.Chat, Length(UI.Claude.Chat) + 1);
          case Copy(Strings[P], 2, Pos(']', Strings[P]) - 2) of
            'User': UI.Claude.Chat[High(UI.Claude.Chat)].Kind := ckUser;
            'Tool': UI.Claude.Chat[High(UI.Claude.Chat)].Kind := ckTool;
          else
            UI.Claude.Chat[High(UI.Claude.Chat)].Kind := ckAssistant;
          end;
          UI.Claude.Chat[High(UI.Claude.Chat)].Text := Copy(Strings[P], Pos('] ', Strings[P]) + 2, MaxInt);
        end
        else if Copy(Strings[P], 1, 8) = 'tokens: ' then
          Break
        else if Length(UI.Claude.Chat) > 0 then
          UI.Claude.Chat[High(UI.Claude.Chat)].Text := UI.Claude.Chat[High(UI.Claude.Chat)].Text + LineEnding + Strings[P];
      end;
    finally
      Free;
    end;
  if (St.Cmd = 'chattop') and (Chat <> nil) then Chat.ScrollTop;
  if St.Cmd = 'uiclick' then
  begin
    // a click through the UI's own mouse (posted clicks would go to the real cursor)
    V := StrToInt(Copy(St.Arg, Pos(':', St.Arg) + 1, 9));
    if Copy(St.Arg, 1, 4) = 'menu' then Pt := UI.ClaudeMenuPoint(V)
    else if Copy(St.Arg, 1, 3) = 'dev' then Pt := UI.DevMenuPoint(V)
    else if Copy(St.Arg, 1, 2) = 'rm' then Pt := UI.KeyRmPoint(V)
    else Pt := UI.KeyDlgPoint(V);
    UI.MouseClicks := 1;
    UI.MouseMods := [];
    UI.MouseMove(Pt.X, Pt.Y);
    UI.MouseDown(Pt.X, Pt.Y);
    UI.MouseUp(Pt.X, Pt.Y);
  end;
  if (St.Cmd = 'infox') and (InfoForm <> nil) then InfoForm.Close;   // as the X of the window
  if St.Cmd = 'testmsgs' then UI.TestMessages(StrToInt(St.Arg));
  if St.Cmd = 'ipc' then
    with TStringList.Create do
    try
      if FileExists(FShotDir + 'ipc_check.txt') then LoadFromFile(FShotDir + 'ipc_check.txt');
      case St.Arg of
        'check on', 'check off':
          Add(Format('%s: IPC on %s', [St.Arg, BoolToStr(UI.Project.Comm.IpcOn, True)]));
        'wait client':
          Add('the answers of the client: ' + UI.IpcAnswer('PING') + ' | ' + UI.IpcAnswer('READ %MW100'));
        'pdf': Add('help as PDF: ' + BoolToStr(UI.ExportIpcHelp(FShotDir + 'ipc_help.pdf'), True));
        'import tags':
          begin
            Add('import tags: ' + UI.ImportTags(ExpandFileName('test\import_tags.csv')));
            P := UI.Project.FindTag('New_Lamp');
            if P >= 0 then
              Add(Format('  New_Lamp %s %s "%s"', [UI.Project.Tags[P].TypeText, UI.Project.Tags[P].Address,
                UI.Project.Tags[P].Comment]));
            P := UI.Project.FindTag('Motor');
            Add('  Motor comment: ' + UI.Project.Tags[P].Comment);
          end;
        'import watch':
          begin
            V := Length(UI.Project.Watch);
            Add('import watch: ' + UI.ImportWatch(ExpandFileName('test\import_watch.csv')));
            for P := V to High(UI.Project.Watch) do
              Add(Format('  row %d: %s %s modify "%s"', [P + 1, UI.Project.Watch[P].Address,
                DispFmtNames[UI.Project.Watch[P].Fmt], UI.Project.Watch[P].ModifyValue]));
          end;
        'explorer': Add('explorer: ' + UI.LastShell);
        'helpform':
          if UI.HelpForm = nil then Add('help window: FAIL not there')
          else
          begin
            UI.HelpForm.SetBounds(UI.HelpForm.Left, 40, 940, 760);
            UI.HelpForm.SaveShot(FShotDir + 'ipc_2_help.png');
            S0 := UI.HelpForm.CopyAll;
            Add(Format('help window: open %s, sizeable %s, text select %s, copied %d chars, has "\.\pipe\VirtualPLC" %s, has "NamedPipeClientStream" %s',
              [BoolToStr(UI.IpcHelpOpen, True), BoolToStr(UI.HelpForm.BorderStyle = bsSizeable, True),
              BoolToStr(UI.HelpForm.Viewer.AllowTextSelect, True), Length(S0),
              BoolToStr(Pos('\.\pipe\VirtualPLC', S0) > 0, True), BoolToStr(Pos('NamedPipeClientStream', S0) > 0, True)]));
            with TStringList.Create do
            try
              Text := S0;
              SaveToFile(FShotDir + 'ipc_help_copied.txt');
            finally
              Free;
            end;
          end;
        'helpsmall':
          if UI.HelpForm <> nil then
          begin
            UI.HelpForm.SetBounds(UI.HelpForm.Left, 40, 520, 360);
            UI.HelpForm.SaveShot(FShotDir + 'ipc_2b_help_small.png');
            Add(Format('help window resized to %d x %d (%s)', [UI.HelpForm.Width, UI.HelpForm.Height, UI.HelpForm.ShotInfo]));
          end;
        'import io':
          begin
            Add('import io: ' + UI.ImportIo(ExpandFileName('test\import_io.csv')));
            for P := 0 to High(UI.Project.Tags) do
              if Pos(UI.Project.Tags[P].Name + ',', 'New_Sensor,Jog_PB,New_Lamp,Level,Start_PB,') > 0 then
                Add(Format('  %s %s %s "%s"', [UI.Project.Tags[P].Name, UI.Project.Tags[P].TypeText,
                  UI.Project.Tags[P].Address, UI.Project.Tags[P].Comment]));
            Add(Format('  I0.5 %s %s, I0.6 %s %s, AI0 %s %d, AI1 %s', [InTypeNames[UI.Project.DIch[5].InType],
              BoolToStr(UI.Rt.GetSimBit(0, 5), True), InTypeNames[UI.Project.DIch[6].InType],
              BoolToStr(UI.Rt.GetSimBit(0, 6), True), AiModeNames[UI.Project.AIch[0].AiMode],
              UI.Project.AIch[0].AiValue, AiModeNames[UI.Project.AIch[1].AiMode]]));
          end;
        'iohelpform':
          if UI.IoHelpForm = nil then Add('io help window: FAIL not there')
          else
          begin
            UI.IoHelpForm.SetBounds(UI.IoHelpForm.Left, 40, 940, 760);
            UI.IoHelpForm.SaveShot(FShotDir + 'ioimport_2_help.png');
            S0 := UI.IoHelpForm.CopyAll;
            Add(Format('io help window: open %s, copied %d chars, has "Address" %s, has "push NC" %s, has the Python %s',
              [BoolToStr(UI.IoHelpForm.Visible, True), Length(S0), BoolToStr(Pos('Address', S0) > 0, True),
              BoolToStr(Pos('push NC', S0) > 0, True), BoolToStr(Pos('csv.writer', S0) > 0, True)]));
          end;
        'iohelppdf':
          Add('io help as PDF: ' + BoolToStr(UI.ExportHelpDoc(FShotDir + 'io_import_help.pdf', 'The I/O import file',
            'For developers.', IoImportHelpDoc), True));
        'iohelpclose':
          if UI.IoHelpForm <> nil then UI.IoHelpForm.Hide;
        'helpclose':
          begin
            UI.HelpForm.Hide;
            Add('help window closed: ' + BoolToStr(not UI.IpcHelpOpen, True));
          end;
        'refresh': UI.RefreshProjectFiles;
        'folder 0': UI.FileFolder := 0;
        'folder 1': UI.FileFolder := 1;
        'ex 6', 'ex 15', 'ex 30', 'ex 31', 'ex 32', 'ex 33', 'ex 19', 'ex 20', 'ex 22', 'ex 23', 'ex 25': UI.LoadExampleNow(StrToInt(Copy(St.Arg, 4, 2)));
        'in on': UI.Rt.SetSimBit(0, 0, True);
      end;
      SaveToFile(FShotDir + 'ipc_check.txt');
    finally
      Free;
    end;
  if St.Cmd = 'pal' then
    with TStringList.Create do
    try
      // a palette button through the UI's mouse, or a check of the cell / tag / variable
      if FileExists(FShotDir + 'ladpal_check.txt') then LoadFromFile(FShotDir + 'ladpal_check.txt');
      if Copy(St.Arg, 1, 6) <> 'check ' then
      begin
        if St.Arg = 'cmp>=' then V := Ord(lkCmp) + 256 * (Ord(coGE) + 1) else V := Ord(lkConv);
        Pt := UI.HitPoint('pal', V);
        Add(Format('palette button %s at %.0f, %.0f', [St.Arg, Pt.X, Pt.Y]));
        UI.MouseMove(Pt.X, Pt.Y);
        UI.MouseDown(Pt.X, Pt.Y);
        UI.MouseUp(Pt.X, Pt.Y);
        UI.KeyDown(ukEsc, #0, []);
      end
      else
        with UI.Project.Block(0).Net(UI.Project.Block(0).NetCount - 1) do
          case St.Arg of
            'check cmp': Add('CMP >= placed: ' + BoolToStr((Cell(0, 0).Kind = lkCmp) and (Cell(0, 0).Cmp = coGE), True));
            'check conv': Add('CONV placed: ' + BoolToStr((Cell(0, 3).Kind = lkConv) and (Cell(0, 3).DType = dtInt) and
              (Cell(0, 3).DType2 = dtReal), True));
            'check out': Add('CONV OUT picked from the list: ' + DataTypeNames[Cell(0, 3).DType2] + ' ' +
              BoolToStr(Cell(0, 3).DType2 = dtDInt, True));
            'check tag': Add(Format('tag 12 "%s" type from the list: %s %s', [UI.Project.Tags[11].Name,
              UI.Project.Tags[11].TypeText, BoolToStr(UI.Project.Tags[11].TypeText = 'Real', True)]));
            'check var': Add(Format('DB1 variable 2 "%s" type from the list: %s %s', [UI.Project.DB(0).Vars[1].Name,
              UI.Project.DB(0).Vars[1].TypeText, BoolToStr(UI.Project.DB(0).Vars[1].TypeText = 'DInt', True)]));
          end;
      SaveToFile(FShotDir + 'ladpal_check.txt');
    finally
      Free;
    end;
  if St.Cmd = 'caret' then
    with TStringList.Create do
    try
      // the key, then (the frame before) where the caret is: a line per key that leaves it outside
      if FileExists(FShotDir + 'caret_check.txt') then LoadFromFile(FShotDir + 'caret_check.txt');
      Ok := UI.CaretInView(S0);
      if Count = 0 then Add('caret checks (OUTSIDE lines are the problems)');
      if not Ok then Add('OUTSIDE  ' + S0);
      case St.Arg of
        'down': UI.KeyDown(ukDown, #0, []);
        'up': UI.KeyDown(ukUp, #0, []);
        'home': UI.KeyDown(ukHome, #0, [umCtrl]);
      end;
      SaveToFile(FShotDir + 'caret_check.txt');
    finally
      Free;
    end;
  if St.Cmd = 'mk' then
    with TStringList.Create do
    try
      if FileExists(FShotDir + 'batch_check.txt') then LoadFromFile(FShotDir + 'batch_check.txt');
      S1 := ExtractFilePath(ParamStr(0)) + 'projects' + PathDelim;
      case St.Arg of
        'blocks': for P := 10 to 21 do UI.Project.AddBlock(bkFC, P, Format('Test%d', [P])).AddNet(nkSCL);
        'tags':
          begin
            for P := 0 to 24 do UI.Project.AddTag(Format('T%d', [P]), 'Int', Format('%%MW%d', [200 + P * 2]), 'filler');
            UI.Project.AddTag('Dup', 'Bool', '%M50.0', 'the same name twice');
            UI.Project.AddTag('Dup', 'Bool', '%M50.1', 'the same name twice');
            UI.Project.AddTag('SameAddr', 'Bool', '%Q0.0', 'the address of "Motor"');
            UI.Project.AddTag('IntOnBit', 'Int', '%M60.0', 'Int on a bit');
            UI.Project.AddTag('BoolOnWord', 'Bool', '%MW62', 'Bool on a word');
            UI.Project.AddTag('Overlap', 'Byte', '%MB201', 'inside T0 MW200');
            UI.Project.AddTag('RealOnWord', 'Real', '%MW70', 'Real needs a double word');
            UI.Project.AddTag('Fine', 'Real', '%MD80', 'fine');
          end;
        'tagcheck':
          for P := 0 to High(UI.Project.Tags) do
            if Pos('T', UI.Project.Tags[P].Name) <> 1 then
              Add(Format('tag %s %s %s: [%s]', [UI.Project.Tags[P].Name, UI.Project.Tags[P].TypeText,
                UI.Project.Tags[P].Address, UI.TagError(P)]));
        'dbs':
          begin
            for P := 10 to 21 do UI.Project.AddDB(P, Format('TestDB%d', [P]));
            for P := 0 to 29 do UI.Project.DB(0).AddVar(Format('Extra%d', [P]), 'Int', '0', 'scroll test');
          end;
        'watch': for P := 0 to 19 do UI.Project.AddWatch(Format('%%MW%d', [300 + P * 2]), dfDec);
        'files':
          begin
            for P := 0 to 15 do UI.Project.SaveToFile(S1 + Format('zz_scroll_test_%.2d.vplc', [P]));
            UI.Project.FileName := '';
            UI.RefreshProjectFiles;
          end;
        'rmfiles':
          begin
            for P := 0 to 15 do DeleteFile(S1 + Format('zz_scroll_test_%.2d.vplc', [P]));
            UI.RefreshProjectFiles;
          end;
        'saveas':
          begin
            // the Save As field as a text box: typing, Ctrl+Shift+Left selects a word, typing replaces it,
            // Ctrl+A, Ctrl+Z, a drag over all of it with the mouse
            Pt := UI.HitPoint('saveas', 0);
            UI.MouseClicks := 1;
            UI.MouseMods := [];
            UI.MouseMove(Pt.X, Pt.Y);
            UI.MouseDown(Pt.X, Pt.Y);
            UI.MouseUp(Pt.X, Pt.Y);
            UI.TextInput('hello world');
            UI.KeyDown(ukLeft, #0, [umCtrl, umShift]);
            UI.TextInput('there');
            UI.KeyDown(ukChar, 'a', [umCtrl]);
            UI.TextInput('abc');
            UI.KeyDown(ukChar, 'z', [umCtrl]);
            UI.KeyDown(ukHome, #0, []);
            UI.KeyDown(ukRight, #0, [umShift]);
            UI.KeyDown(ukRight, #0, [umShift]);
            UI.KeyDown(ukChar, 'x', [umCtrl]);
            Add('cut: [' + UI.ClipboardOut + ']');
            UI.KeyDown(ukEnd, #0, []);
            UI.Clipboard := '_v2';
            UI.KeyDown(ukChar, 'v', [umCtrl]);
            UI.KeyDown(ukEnter, #0, []);
            Add('save as field after typing, word select, Ctrl+A, Ctrl+Z, cut, paste: [' + UI.SaveAsText + ']');
          end;
        'saveas2':
          begin
            // the mouse: a drag from the left over the whole text selects it, typing replaces it
            Pt := UI.HitPoint('saveas', 0);
            UI.MouseClicks := 1;
            UI.MouseMods := [];
            UI.MouseMove(Pt.X - 134, Pt.Y);
            UI.MouseDown(Pt.X - 134, Pt.Y);
            UI.MouseMove(Pt.X + 125, Pt.Y);
            UI.MouseUp(Pt.X + 125, Pt.Y);
            UI.TextInput('my_line_2');
            UI.KeyDown(ukEnter, #0, []);
            Add('save as field after a mouse drag over all and typing: [' + UI.SaveAsText + ']');
          end;
        'ip':
          begin
            // an address that is not this PC's (never 0.0.0.0 in a test: Windows would ask about the firewall)
            Pt := UI.HitPoint('ip', 0);
            UI.MouseClicks := 3;
            UI.MouseMove(Pt.X, Pt.Y);
            UI.MouseDown(Pt.X, Pt.Y);
            UI.MouseUp(Pt.X, Pt.Y);
            UI.MouseClicks := 1;
            UI.TextInput('300.1.2.3');
            UI.KeyDown(ukEnter, #0, []);
            Add('ip after "300.1.2.3" (refused): ' + CommIp(UI.Project.Comm));
            UI.MouseClicks := 3;
            UI.MouseDown(Pt.X, Pt.Y);
            UI.MouseUp(Pt.X, Pt.Y);
            UI.MouseClicks := 1;
            UI.TextInput('10.255.255.1');
            UI.KeyDown(ukEnter, #0, []);
            Add('ip after "10.255.255.1": ' + CommIp(UI.Project.Comm));
          end;
        'ipcheck': Add('S7 server: ' + UI.Hub.Status[prS7] + '  |  Modbus: ' + UI.Hub.Status[prModbus]);
        'ladsel': UI.SelectCell(0, 0, 0);
        'newlad':
          begin
            UI.Project.Block(0).AddNet(nkLAD);
            UI.SelectCell(-1, 0, 0);
          end;
        'nextcell': UI.SelectCell(-1, 0, 3);
        'ipmenu':
          begin
            Pt := UI.HitPoint('ipmenu', 0);
            UI.MouseMove(Pt.X, Pt.Y);
            UI.MouseDown(Pt.X, Pt.Y);
            UI.MouseUp(Pt.X, Pt.Y);
          end;
      end;
      SaveToFile(FShotDir + 'batch_check.txt');
    finally
      Free;
    end;
  if St.Cmd = 'vs' then
    with TStringList.Create do
    try
      // drag <bar> <from> <to> (0 top .. 1 bottom of the bar), or click <bar> <at>
      if FileExists(FShotDir + 'vscroll_check.txt') then LoadFromFile(FShotDir + 'vscroll_check.txt');
      V := StrToInt(ExtractWord(2, St.Arg, [' ']));
      Pt := UI.VScrollPoint(V, StrToFloat(ExtractWord(3, St.Arg, [' ']), DefaultFormatSettings));
      if ExtractWord(1, St.Arg, [' ']) = 'drag' then
        Pp := UI.VScrollPoint(V, StrToFloat(ExtractWord(4, St.Arg, [' ']), DefaultFormatSettings))
      else
        Pp := Pt;
      S0 := FormatFloat('0.0', UI.VScrollPos(V));
      UI.MouseClicks := 1;
      UI.MouseMods := [];
      UI.MouseMove(Pt.X, Pt.Y);
      UI.MouseDown(Pt.X, Pt.Y);
      for P := 1 to 8 do UI.MouseMove(Pt.X, Pt.Y + (Pp.Y - Pt.Y) * P / 8);
      UI.MouseUp(Pp.X, Pp.Y);
      Add(Format('%s: position %s -> %s', [St.Arg, S0, FormatFloat('0.0', UI.VScrollPos(V))]));
      SaveToFile(FShotDir + 'vscroll_check.txt');
    finally
      Free;
    end;
  if St.Cmd = 'startcheck' then
    with TStringList.Create do
    try
      Add(Format('project "%s", CPU %s (%s), %d blocks, %d DBs, %d tags, modified %s', [UI.Project.Name,
        UI.Project.Model.Name, FamilyNames[UI.Project.Family], UI.Project.BlockCount, UI.Project.DBCount,
        Length(UI.Project.Tags), BoolToStr(UI.Project.Modified, True)]));
      Add(Format('runtime CPU %s, mode %s', [UI.Rt.Model.Name, GetEnumName(TypeInfo(TRunMode), Ord(UI.Rt.Mode))]));
      SaveToFile(FShotDir + 'startup_check.txt');
    finally
      Free;
    end;
  if St.Cmd = 'saveask' then
    with TStringList.Create do
    try
      if FileExists(FShotDir + 'saveask_check.txt') then LoadFromFile(FShotDir + 'saveask_check.txt');
      S1 := ExtractFilePath(ParamStr(0)) + 'projects' + PathDelim + 'zz_saveask_test.vplc';
      S0 := St.Arg;
      if S0 = 'change' then
      begin
        // a change that is not saved, under a name of the test (its file goes at the end)
        UI.Project.Name := 'zz saveask test';
        UI.Project.FileName := '';
        UI.Project.Modified := True;
      end
      else if Copy(S0, 1, 6) = 'click ' then
      begin
        if S0 = 'click new' then Pt := UI.HitPoint('new', 7)
        else if S0 = 'click example' then Pt := UI.HitPoint('example', 4)
        else Pt := UI.HitPoint('file', 0);
        UI.MouseMove(Pt.X, Pt.Y);
        UI.MouseDown(Pt.X, Pt.Y);
        UI.MouseUp(Pt.X, Pt.Y);
        Add(S0 + ': question ' + BoolToStr(UI.AskOpen, True));
      end
      else if S0 = 'close' then
      begin
        CloseRequest;
        Add('close: question ' + BoolToStr(UI.AskOpen, True) + ', running ' + BoolToStr(FRunning, True));
      end
      else if Copy(S0, 1, 7) = 'answer ' then
      begin
        Pt := UI.HitPoint('ask', StrToInt(Copy(S0, 8, 1)));
        UI.MouseMove(Pt.X, Pt.Y);
        UI.MouseDown(Pt.X, Pt.Y);
        UI.MouseUp(Pt.X, Pt.Y);
        if UI.QuitRequested then
        begin
          // the program ends with this frame: the check and the clean up now
          Add('don''t save at the close: the program ends: True   (' + UI.Project.Name + ')');
          DeleteFile(S1);
        end;
      end
      else
      begin
        S0 := Copy(S0, 7, MaxInt);
        if Pos('cancel keeps', S0) > 0 then Ok := (UI.Project.Name = 'zz saveask test') and UI.Project.Modified and not UI.AskOpen
        else if Pos('save writes', S0) > 0 then Ok := FileExists(S1) and (UI.Project.Name <> 'zz saveask test') and not UI.AskOpen
        else if Pos('loads the sample', S0) > 0 then Ok := (UI.Project.Name <> 'zz saveask test') and not UI.Project.Modified
        else if Pos('no file name', S0) > 0 then Ok := (UI.Project.FileName = '') and (Pos('Traffic', UI.Project.Name) > 0)
        else if Pos('only the load question', S0) > 0 then Ok := UI.AskOpen and (UI.AskTitle = 'Load example project')
        else if Pos('runs on', S0) > 0 then Ok := FRunning and not UI.QuitRequested and not UI.AskOpen
        else Ok := UI.QuitRequested;
        Add(S0 + ': ' + BoolToStr(Ok, True) + '   (' + UI.Project.Name + ')');
        if Pos('program ends', S0) > 0 then DeleteFile(S1);
      end;
      SaveToFile(FShotDir + 'saveask_check.txt');
    finally
      Free;
    end;
  if St.Cmd = 'ladins' then
    with TStringList.Create do
    try
      if FileExists(FShotDir + 'insert_check.txt') then LoadFromFile(FShotDir + 'insert_check.txt');
      S0 := St.Arg;
      if Copy(S0, 1, 5) = 'drag ' then
      begin
        // drag net r c -> r2 c2 (the middle of the cells)
        V := StrToInt(ExtractWord(2, S0, [' ']));
        Pt := UI.CellPoint(V, StrToInt(ExtractWord(3, S0, [' '])), StrToInt(ExtractWord(4, S0, [' '])));
        Pp := UI.CellPoint(V, StrToInt(ExtractWord(5, S0, [' '])), StrToInt(ExtractWord(6, S0, [' '])));
        Pt := UI.DesignToPixel(Pt.X, Pt.Y);
        Pp := UI.DesignToPixel(Pp.X, Pp.Y);
        UI.MouseMove(Pt.X, Pt.Y);
        UI.MouseDown(Pt.X, Pt.Y);
        UI.MouseMove((Pt.X + Pp.X) / 2, (Pt.Y + Pp.Y) / 2);
        UI.MouseMove(Pp.X, Pp.Y);
        UI.MouseUp(Pp.X, Pp.Y);
      end
      else if (Copy(S0, 1, 6) = 'xhold ') or (Copy(S0, 1, 6) = 'xdrag ') then
      begin
        // from net r c to net2 r2 c2 (xhold: the button stays down)
        Pt := UI.CellPoint(StrToInt(ExtractWord(2, S0, [' '])), StrToInt(ExtractWord(3, S0, [' '])),
          StrToInt(ExtractWord(4, S0, [' '])));
        Pp := UI.CellPoint(StrToInt(ExtractWord(5, S0, [' '])), StrToInt(ExtractWord(6, S0, [' '])),
          StrToInt(ExtractWord(7, S0, [' '])));
        Pt := UI.DesignToPixel(Pt.X, Pt.Y);
        Pp := UI.DesignToPixel(Pp.X, Pp.Y);
        UI.MouseMove(Pt.X, Pt.Y);
        UI.MouseDown(Pt.X, Pt.Y);
        UI.MouseMove((Pt.X + Pp.X) / 2, (Pt.Y + Pp.Y) / 2);
        UI.MouseMove(Pp.X, Pp.Y);
        if Copy(S0, 1, 6) = 'xdrag ' then UI.MouseUp(Pp.X, Pp.Y);
      end
      else if Copy(S0, 1, 6) = 'xdrop ' then
      begin
        Pp := UI.CellPoint(StrToInt(ExtractWord(2, S0, [' '])), StrToInt(ExtractWord(3, S0, [' '])),
          StrToInt(ExtractWord(4, S0, [' '])));
        Pp := UI.DesignToPixel(Pp.X, Pp.Y);
        UI.MouseMove(Pp.X, Pp.Y);
        UI.MouseUp(Pp.X, Pp.Y);
      end
      else if Copy(S0, 1, 5) = 'hold ' then
      begin
        // the same as drag, but the button stays down: the ghost shows
        V := StrToInt(ExtractWord(2, S0, [' ']));
        Pt := UI.CellPoint(V, StrToInt(ExtractWord(3, S0, [' '])), StrToInt(ExtractWord(4, S0, [' '])));
        Pp := UI.CellPoint(V, StrToInt(ExtractWord(5, S0, [' '])), StrToInt(ExtractWord(6, S0, [' '])));
        Pt := UI.DesignToPixel(Pt.X, Pt.Y);
        Pp := UI.DesignToPixel(Pp.X - 20, Pp.Y + 14);
        UI.MouseMove(Pt.X, Pt.Y);
        UI.MouseDown(Pt.X, Pt.Y);
        UI.MouseMove((Pt.X + Pp.X) / 2, (Pt.Y + Pp.Y) / 2);
        UI.MouseMove(Pp.X, Pp.Y);
      end
      else if S0 = 'let go' then
      begin
        // back to where it was taken: nothing moves
        Pt := UI.CellPoint(2, 0, 0);
        Pt := UI.DesignToPixel(Pt.X, Pt.Y);
        UI.MouseMove(Pt.X, Pt.Y);
        UI.MouseUp(Pt.X, Pt.Y);
      end
      else if S0 = 'undo' then UI.UndoPublic(False)
      else if S0 = 'ctrlc' then UI.KeyDown(ukChar, 'c', [umCtrl])
      else if S0 = 'ctrlv' then UI.KeyDown(ukChar, 'v', [umCtrl])
      else if S0 = 'ctrlx' then UI.KeyDown(ukChar, 'x', [umCtrl])
      else if S0 = 'del' then UI.KeyDown(ukDel, #0, [])
      else if S0 = 'esc' then UI.KeyDown(ukEsc, #0, [])
      else if Copy(S0, 1, 5) = 'type ' then
      begin
        UI.FocusStl(StrToInt(Copy(S0, 6, 3)), 0, 0);
        UI.TextInput('#x := 1;');
        UI.KeyDown(ukEsc, #0, []);
      end
      else if Copy(S0, 1, 6) = 'click ' then
      begin
        Pt := UI.CellPoint(StrToInt(ExtractWord(2, S0, [' '])), StrToInt(ExtractWord(3, S0, [' '])),
          StrToInt(ExtractWord(4, S0, [' '])));
        Pt := UI.DesignToPixel(Pt.X, Pt.Y);
        UI.MouseMove(Pt.X, Pt.Y);
        UI.MouseDown(Pt.X, Pt.Y);
        UI.MouseUp(Pt.X, Pt.Y);
      end
      else
      begin
        S0 := Copy(S0, 7, MaxInt);
        with UI.CurBlockPublic do
          if Pos('swap', S0) > 0 then
            Ok := (Net(0).Cell(0, 0).Kind = lkCTU) and (Net(0).Cell(0, 1).Kind = lkWire) and (Net(0).Cell(0, 2).Kind = lkNO) and
              (Net(0).Cell(0, 7).Kind = lkCoil)
          else if Pos('coil to 3', S0) > 0 then
            Ok := (Net(0).Cell(0, 3).Kind = lkCoil) and (Net(0).Cell(0, 4).Kind = lkWire) and (Net(0).Cell(0, 7).Kind = lkWire) and
              (Net(0).Cell(0, 2).Kind = lkNO)
          else if Pos('SCL above network 2', S0) > 0 then
            Ok := (NetCount = 4) and (Net(1).Kind = nkSCL) and (Net(2).Kind = nkLAD) and (UI.NetSel = 1)
          else if Pos('the clipboard has', S0) > 0 then Ok := Trim(Clipboard.AsText) = '#x := 1;'
          else if Pos('the text is gone', S0) > 0 then Ok := Trim(Net(1).Stl.Text) = ''
          else if Pos('the text is back', S0) > 0 then Ok := Trim(Net(1).Stl.Text) = '#x := 1;'
          else if Pos('LAD below network 1', S0) > 0 then
            Ok := (NetCount = 5) and (Net(1).Kind = nkLAD) and not UI.NetHasCodePublic(Net(1)) and (Net(2).Kind = nkSCL)
          else if Pos('onto empty cells', S0) > 0 then
            Ok := (Net(0).Cell(0, 2).Kind = lkNC) and (Net(0).Cell(1, 3).Kind = lkEmpty) and (UI.UndoCount = 0)
          else if Pos('onto a wire', S0) > 0 then
            Ok := (Net(1).Cell(0, 4).Kind = lkNO) and (Net(1).Cell(0, 4).Opnd = '"Stop_PB"') and
              (Net(0).Cell(0, 1).Kind = lkWire) and (Net(1).Cell(0, 1).Kind = lkCTU)
          else if Pos('onto an element', S0) > 0 then
            Ok := (Net(0).Cell(0, 2).Kind = lkNO) and (Net(0).Cell(0, 2).Opnd = '"Box_Sensor"') and
              (Net(0).Cell(0, 3).Kind = lkNC) and (Net(1).Cell(0, 0).Kind = lkWire) and (Net(1).Cell(0, 1).Kind = lkCTU)
          else if Pos('undo of the move between', S0) > 0 then
            Ok := (Net(1).Cell(0, 0).Kind = lkNO) and (Net(0).Cell(0, 2).Kind = lkNC) and (Net(1).Cell(0, 4).Kind = lkNO)
          else if Pos('LAD with code stays', S0) > 0 then Ok := Net(0).Kind = nkLAD
          else if Pos('empty LAD switches', S0) > 0 then Ok := (NetCount = 4) and (Net(1).Kind = nkSCL)
          else if Pos('SCL with code stays', S0) > 0 then
            Ok := (Net(1).Kind = nkSCL) and (Trim(Net(1).Stl.Text) = '#x := 1;')
          else if Pos('del in the rung', S0) > 0 then
            Ok := (Net(0).Cell(0, 1).Kind = lkWire) and (Net(0).Cell(0, 0).Kind = lkNO)
          else if Pos('only contact of a branch', S0) > 0 then
            Ok := (Net(0).Cell(1, 0).Kind = lkEmpty) and Net(0).Cell(0, 0).Down
          else if Pos('cut in the rung', S0) > 0 then
            Ok := Net(0).Cell(0, 2).Kind = lkWire
          else if Pos('coil at the end', S0) > 0 then
            Ok := (Net(0).Cell(0, 7).Kind = lkEmpty) and (Net(0).Cell(0, 6).Kind = lkWire)
          else if Pos('keep', S0) > 0 then
            Ok := (BoxCount(Net(0)) >= 3) and BoxesWide(Net(0)) and BoxesWide(Net(1)) and BoxesWide(Net(2))
          else if Pos('network 2 to 5', S0) > 0 then
            Ok := (Net(1).Cell(0, 0).Kind = lkCTD) and (Net(1).Cell(0, 5).Kind = lkNO) and (Net(1).Cell(0, 7).Kind = lkCoil)
          else if Pos('back', S0) > 0 then
            Ok := (Net(1).Cell(0, 0).Kind = lkNO) and (Net(1).Cell(0, 1).Kind = lkCTD) and (Net(0).Cell(0, 3).Kind = lkCoil)
          else Ok := False;
        Add(Format('%s: %s   (net 1: %s | net 2: %s)', [S0, BoolToStr(Ok, True), RowKinds(UI.CurBlockPublic.Net(0)),
          RowKinds(UI.CurBlockPublic.Net(1))]));
        if Pos('keep', S0) > 0 then Add('  net 1 now: ' + RowKinds(UI.CurBlockPublic.Net(0)));
      end;
      SaveToFile(FShotDir + 'insert_check.txt');
    finally
      Free;
    end;
  if St.Cmd = 'undo' then
    with TStringList.Create do
    try
      if FileExists(FShotDir + 'undo_check.txt') then LoadFromFile(FShotDir + 'undo_check.txt');
      // the right part of the CTU box in network 1: over column 3 of the grid
      Pt := UI.CellPoint(0, 0, 2);
      Pp := UI.CellPoint(0, 0, 1);
      Pt := UI.DesignToPixel(Pt.X - (Pt.X - Pp.X) * 0.3, Pt.Y + 8);
      Pp := UI.CellPoint(0, 0, 1);
      S0 := St.Arg;
      if S0 = 'press' then
      begin
        UI.MouseMove(Pt.X, Pt.Y);
        UI.MouseDown(Pt.X, Pt.Y);
      end
      else if S0 = 'jitter' then UI.MouseMove(Pt.X + 4, Pt.Y + 2)
      else if S0 = 'move 2' then
      begin
        Pp := UI.CellPoint(0, 0, 4);
        Pp := UI.DesignToPixel(Pp.X - (Pp.X - UI.CellPoint(0, 0, 3).X) * 0.3, Pp.Y + 8);
        UI.MouseMove((Pt.X + Pp.X) / 2, Pt.Y);
        UI.MouseMove(Pp.X, Pp.Y);
      end
      else if S0 = 'release' then UI.MouseUp(Pt.X, Pt.Y)
      else if S0 = 'release far' then
      begin
        Pp := UI.CellPoint(0, 0, 4);
        Pp := UI.DesignToPixel(Pp.X - (Pp.X - UI.CellPoint(0, 0, 3).X) * 0.3, Pp.Y + 8);
        UI.MouseUp(Pp.X, Pp.Y);
      end
      else if S0 = 'type' then
      begin
        UI.FocusStl(UI.NetSel, 0, 0);
        UI.TextInput('#x := 1;');
      end
      else if S0 = 'ctrlz' then UI.KeyDown(ukChar, 'z', [umCtrl])
      else if S0 = 'ctrly' then UI.KeyDown(ukChar, 'y', [umCtrl])
      else
      begin
        S0 := Copy(S0, 7, MaxInt);
        V := UI.CurBlockPublic.NetCount;
        if Pos('box stays', S0) > 0 then
          Ok := (UI.CurBlockPublic.Net(0).Cell(0, 1).Kind = lkCTU) and (UI.UndoCount = 0)
        else if Pos('moved 2', S0) > 0 then
          Ok := (UI.CurBlockPublic.Net(0).Cell(0, 3).Kind = lkCTU) and (UI.CurBlockPublic.Net(0).Cell(0, 1).Kind <> lkCTU)
        else if Pos('box back', S0) > 0 then
          Ok := (UI.CurBlockPublic.Net(0).Cell(0, 1).Kind = lkCTU) and (UI.UndoCount = 0) and (UI.RedoCount = 2)
        else if Pos('4 networks', S0) > 0 then Ok := V = 4
        else if Pos('3 networks', S0) > 0 then Ok := V = 3
        else if Pos('text typed', S0) > 0 then
          Ok := (V = 5) and (FirstScl(UI.CurBlockPublic) = '#x := 1;')
        else if Pos('text gone', S0) > 0 then
          Ok := (V = 5) and (FirstScl(UI.CurBlockPublic) = '')
        else Ok := False;
        Add(Format('%s: %s   (networks %d, undo %d, redo %d)', [S0, BoolToStr(Ok, True), V, UI.UndoCount,
          UI.RedoCount]));
      end;
      SaveToFile(FShotDir + 'undo_check.txt');
    finally
      Free;
    end;
  if St.Cmd = 'stlnet' then
  begin
    // the first SCL / STL network of the open block gets the text caret (row 1 or the end)
    for P := 0 to UI.Project.Block(0).NetCount - 1 do ;
    V := -1;
    for P := UI.CurBlockPublic.NetCount - 1 downto 0 do
      if ((St.Arg = 'SCL') and (UI.CurBlockPublic.Net(P).Kind = nkSCL)) or
        ((St.Arg = 'STL') and (UI.CurBlockPublic.Net(P).Kind = nkSTL)) then V := P;
    if V >= 0 then UI.FocusStl(V, 8, 0);
    FWaitStep := V;
  end;
  if St.Cmd = 'helpsel' then
  begin
    // from line a char b to line c char d, with n clicks (2 a word, 3 the line)
    S0 := St.Arg;
    Pt := UI.HelpPoint(StrToInt(ExtractWord(1, S0, [','])), StrToInt(ExtractWord(2, S0, [','])));
    Pp := UI.HelpPoint(StrToInt(ExtractWord(3, S0, [','])), StrToInt(ExtractWord(4, S0, [','])));
    UI.MouseClicks := StrToInt(ExtractWord(5, S0, [',']));
    UI.MouseMods := [];
    UI.MouseMove(Pt.X, Pt.Y);
    UI.MouseDown(Pt.X, Pt.Y);
    if UI.MouseClicks = 1 then UI.MouseMove(Pp.X, Pp.Y);
    UI.MouseUp(Pp.X, Pp.Y);
    UI.MouseClicks := 1;
  end;
  if St.Cmd = 'helprclick' then
  begin
    Pt := UI.HelpPoint(StrToInt(ExtractWord(1, St.Arg, [','])), StrToInt(ExtractWord(2, St.Arg, [','])));
    UI.MouseMove(Pt.X, Pt.Y);
    UI.MouseRightDown(Pt.X, Pt.Y);
  end;
  if St.Cmd = 'helpcopy' then
    with TStringList.Create do
    try
      // Ctrl+C: what goes to the clipboard
      if FileExists(FShotDir + 'help_check.txt') then LoadFromFile(FShotDir + 'help_check.txt');
      UI.ClipboardOut := '';
      UI.KeyDown(ukChar, 'c', [umCtrl]);
      Add(St.Arg + ': [' + StringReplace(UI.ClipboardOut, LineEnding, '|', [rfReplaceAll]) + ']');
      SaveToFile(FShotDir + 'help_check.txt');
    finally
      Free;
    end;
  if St.Cmd = 'helpdrag' then
  begin
    // the selection dragged from line a char b to the caret of the code (row 9 of the SCL network)
    Pp := UI.DesignToPixel(UI.CaretPoint.X, UI.CaretPoint.Y + 8);
    Pt := UI.HelpPoint(StrToInt(ExtractWord(1, St.Arg, [','])), StrToInt(ExtractWord(2, St.Arg, [','])));
    UI.MouseClicks := 1;
    UI.MouseMods := [];
    UI.MouseMove(Pt.X, Pt.Y);
    UI.MouseDown(Pt.X, Pt.Y);
    for P := 1 to 10 do UI.MouseMove(Pt.X + (Pp.X - Pt.X) * P / 10, Pt.Y + (Pp.Y - Pt.Y) * P / 10);
    UI.MouseUp(Pp.X, Pp.Y);
  end;
  if St.Cmd = 'helpcheck' then
    with TStringList.Create do
    try
      if FileExists(FShotDir + 'help_check.txt') then LoadFromFile(FShotDir + 'help_check.txt');
      if (FWaitStep >= 0) and (UI.CurBlockPublic <> nil) then
        Add('line 9 of the SCL network after the drop: [' + UI.CurBlockPublic.Net(FWaitStep).Stl[8] + ']');
      SaveToFile(FShotDir + 'help_check.txt');
    finally
      Free;
    end;
  if St.Cmd = 'ide' then
    with TStringList.Create do
    try
      // Find Declaration, the views, .scl sources: caret n r <word>, decl, view k, viewshot file, link url,
      // export file, import file, check <what>
      if FileExists(FShotDir + 'ide_check.txt') then LoadFromFile(FShotDir + 'ide_check.txt');
      S0 := ExtractWord(1, St.Arg, [' ']);
      S1 := Trim(Copy(St.Arg, Length(S0) + 2, MaxInt));
      if S0 = 'caret' then
      begin
        V := StrToInt(ExtractWord(1, S1, [' ']));
        P := StrToInt(ExtractWord(2, S1, [' ']));
        S2 := ExtractWord(3, S1, [' ']);
        S3 := UI.CurBlockPublic.Net(V).Stl[P];
        UI.FocusStl(V, P, Pos(S2, S3) + 1);
      end
      else if S0 = 'decl' then UI.KeyDown(ukUp, #0, [umAlt])
      else if S0 = 'ctrlclick' then
      begin
        // a Ctrl+Click on the caret
        Pt := UI.DesignToPixel(UI.CaretPoint.X + 3, UI.CaretPoint.Y + 8);
        UI.MouseMods := [umCtrl];
        UI.MouseClicks := 1;
        UI.MouseMove(Pt.X, Pt.Y);
        UI.MouseDown(Pt.X, Pt.Y);
        UI.MouseUp(Pt.X, Pt.Y);
        UI.MouseMods := [];
      end
      else if S0 = 'view' then UI.ShowViewPublic(StrToInt(S1))
      else if S0 = 'viewshot' then
      begin
        if UI.ViewForm <> nil then
        begin
          UI.ViewForm.SetBounds(UI.ViewForm.Left, 40, 1100, 700);
          UI.ViewForm.SaveShot(FShotDir + S1);
          Add(Format('%s: the view shows %d characters', [S1, Length(UI.ViewForm.CopyAll)]));
        end;
        SaveToFile(FShotDir + 'ide_check.txt');
      end
      else if S0 = 'head' then
        // the name and the version of the block at the top right
        UI.SetBlockHead(ExtractWord(1, S1, [' ']), ExtractWord(2, S1, [' ']))
      else if S0 = 'code' then
      begin
        // the text of network n of block b
        V := StrToInt(ExtractWord(1, S1, [' ']));
        P := StrToInt(ExtractWord(2, S1, [' ']));
        Add(Format('block %d network %d: %s', [V, P, StringReplace(UI.Project.Block(V).Net(P).Stl.Text, LineEnding, ' | ',
          [rfReplaceAll])]));
        Add(Format('block %d: %s version %s', [V, UI.Project.Block(V).Name, UI.Project.Block(V).Version]));
        SaveToFile(FShotDir + 'ide_check.txt');
      end
      else if S0 = 'viewclose' then
      begin
        if UI.ViewForm <> nil then UI.ViewForm.Hide;
      end
      else if S0 = 'export' then
      begin
        Add('export: ' + UI.ExportSclFile(FShotDir + S1, True));
        SaveToFile(FShotDir + 'ide_check.txt');
      end
      else if S0 = 'import' then
      begin
        Add('import of ' + ExpandFileName(S1));
        SaveToFile(FShotDir + 'ide_check.txt');
        Add('import: ' + UI.ImportSclFile(ExpandFileName(S1)));
        SaveToFile(FShotDir + 'ide_check.txt');
      end
      else if S0 = 'check' then
      begin
        Add(Format('%s: screen %d, block %d, network %d, caret %.0f,%.0f, DB %d var %d, tag %d, interface row %d, blocks %d, '
          + 'types %d', [S1, Ord(UI.Screen), UI.BlockSel, UI.NetSel, UI.CaretPoint.X, UI.CaretPoint.Y, UI.DBSel,
          UI.VarSel, UI.TagSel, UI.IfSel, UI.Project.BlockCount, UI.Project.UdtCount]));
        SaveToFile(FShotDir + 'ide_check.txt');
      end;
    finally
      Free;
    end;
  if St.Cmd = 'elem' then
    with TStringList.Create do
    try
      // the SCL elements panel: open <category>, dbl / hover / rclick / drag <caption>, caret n r c,
      // type <text>, check <what> (the lines of the SCL network n, the clipboard)
      if FileExists(FShotDir + 'elems_check.txt') then LoadFromFile(FShotDir + 'elems_check.txt');
      S0 := ExtractWord(1, St.Arg, [' ']);
      S1 := Trim(Copy(St.Arg, Length(S0) + 2, MaxInt));
      if S0 = 'caret' then
        UI.FocusStl(StrToInt(ExtractWord(1, S1, [' '])), StrToInt(ExtractWord(2, S1, [' '])),
          StrToInt(ExtractWord(3, S1, [' '])))
      else if S0 = 'type' then UI.TextInput(S1)
      else if S0 = 'check' then
      begin
        Add('== ' + S1);
        if (UI.CurBlockPublic <> nil) and (UI.NetSel >= 0) and (UI.NetSel < UI.CurBlockPublic.NetCount) then
          for P := 0 to UI.CurBlockPublic.Net(UI.NetSel).Stl.Count - 1 do
            Add(Format('  %d [%s]', [P + 1, UI.CurBlockPublic.Net(UI.NetSel).Stl[P]]));
        Pc := SDL_GetClipboardText;
        if Pc <> nil then
        begin
          Add('  clipboard [' + StringReplace(StrPas(Pc), LineEnding, '|', [rfReplaceAll]) + ']');
          SDL_free(Pc);
        end;
        Add('  project: ' + UI.Project.Name);
        SaveToFile(FShotDir + 'elems_check.txt');
      end
      else
      begin
        // the element is brought into view now, its place is taken from the next frame
        V := UI.ElemFind(S1, (S0 = 'open') or (S0 = 'showcat'));
        if V < 0 then
        begin
          Add('== ' + St.Arg + ': not found');
          SaveToFile(FShotDir + 'elems_check.txt');
        end
        else if (S0 <> 'show') and (S0 <> 'showcat') then
        begin
          if S0 = 'open' then Pt := UI.HitPoint('elemcat', V) else Pt := UI.HitPoint('elem', V);
          UI.MouseMods := [];
          UI.MouseClicks := 1;
          UI.MouseMove(Pt.X, Pt.Y);
          if S0 = 'open' then
          begin
            UI.MouseDown(Pt.X, Pt.Y);
            UI.MouseUp(Pt.X, Pt.Y);
          end
          else if S0 = 'dbl' then
          begin
            UI.MouseDown(Pt.X, Pt.Y);
            UI.MouseUp(Pt.X, Pt.Y);
            UI.MouseClicks := 2;
            UI.MouseDown(Pt.X, Pt.Y);
            UI.MouseUp(Pt.X, Pt.Y);
            UI.MouseClicks := 1;
          end
          else if S0 = 'rclick' then UI.MouseRightDown(Pt.X, Pt.Y)
          else if S0 = 'drag' then
          begin
            // onto the caret of the code
            Pp := UI.DesignToPixel(UI.CaretPoint.X + 2, UI.CaretPoint.Y + 8);
            UI.MouseDown(Pt.X, Pt.Y);
            for P := 1 to 10 do UI.MouseMove(Pt.X + (Pp.X - Pt.X) * P / 10, Pt.Y + (Pp.Y - Pt.Y) * P / 10);
            UI.MouseUp(Pp.X, Pp.Y);
          end;
        end;
      end;
    finally
      Free;
    end;
  if (St.Cmd = 'uirclick') or (St.Cmd = 'uiclick2') then
  begin
    // the right button (uirclick) or a click (uiclick2) on a region of the UI: what:par
    S0 := Copy(St.Arg, 1, Pos(':', St.Arg) - 1);
    V := StrToInt(Copy(St.Arg, Pos(':', St.Arg) + 1, 9));
    if S0 = 'udt' then
    begin
      S0 := 'db';
      V := V + UI.Project.DBCount;
    end;
    Pt := UI.HitPoint(S0, V);
    UI.MouseClicks := 1;
    UI.MouseMods := [];
    UI.MouseMove(Pt.X, Pt.Y);
    if St.Cmd = 'uirclick' then UI.MouseRightDown(Pt.X, Pt.Y)
    else
    begin
      UI.MouseDown(Pt.X, Pt.Y);
      UI.MouseUp(Pt.X, Pt.Y);
    end;
  end;
  if St.Cmd = 'grp' then
    with TStringList.Create do
    try
      // the group test: typing a name, the views, the SCL import of types / DBs, into grp_check.txt
      if FileExists(FShotDir + 'grp_check.txt') then LoadFromFile(FShotDir + 'grp_check.txt');
      if Copy(St.Arg, 1, 5) = 'type ' then
      begin
        UI.TextInput(Copy(St.Arg, 6, MaxInt));
        UI.EndEdit(True);
      end
      else if St.Arg = 'commit' then UI.EndEdit(True)
      else if Copy(St.Arg, 1, 7) = 'rename ' then
      begin
        S1 := Copy(St.Arg, 8, MaxInt);   // K G name
        V := StrToInt(Copy(S1, 1, 1));
        S2 := Copy(S1, 3, MaxInt);
        UI.TestGroupName(V, StrToInt(Copy(S2, 1, Pos(' ', S2) - 1)), Copy(S2, Pos(' ', S2) + 1, MaxInt));
        if V = 0 then
          Add(Format('rename to "%s": the group is "%s"', [Copy(S2, Pos(' ', S2) + 1, MaxInt),
            UI.Project.TagGroups[StrToInt(Copy(S2, 1, Pos(' ', S2) - 1))].Name]));
      end
      else if Copy(St.Arg, 1, 9) = 'dbimport ' then
        Add('import: ' + UI.ImportSclFile(ExtractFilePath(ParamStr(0)) + Copy(St.Arg, 10, MaxInt), True))
      else if St.Arg = 'projfile' then
      begin
        S1 := UI.Project.ToJsonText;
        Add(Format('project file: tagGroups %s, watchGroups %s', [BoolToStr(Pos('"tagGroups"', S1) > 0, True),
          BoolToStr(Pos('"watchGroups"', S1) > 0, True)]));
      end
      else if Copy(St.Arg, 1, 10) = 'dump watch' then
      begin
        S1 := '';
        for V := 0 to High(UI.Project.Watch) do S1 := S1 + IntToStr(UI.Project.Watch[V].GroupId);
        Add(St.Arg + ': ' + UI.ViewText(1) + '   (the groups of the rows: ' + S1 + ')');
      end
      else if Copy(St.Arg, 1, 5) = 'dump ' then
      begin
        S1 := '';
        for V := 0 to High(UI.Project.TagGroups) do
          S1 := S1 + Format('%d:%s ', [UI.Project.TagGroups[V].Id, UI.Project.TagGroups[V].Name]);
        Add(St.Arg + ': groups [' + Trim(S1) + '] shown: ' + UI.ViewText(0));
      end;
      SaveToFile(FShotDir + 'grp_check.txt');
    finally
      Free;
    end;
  if St.Cmd = 'io' then
    with TStringList.Create do
    try
      // the I/O test: tags beyond the CPU's channels, bad rows, the tables into io_check.txt
      if FileExists(FShotDir + 'io_check.txt') then LoadFromFile(FShotDir + 'io_check.txt');
      if St.Arg = 'tags' then
      begin
        UI.Project.AddTag('Door', 'Bool', '%I8.0', 'beyond the inputs of the CPU');
        UI.Project.AddTag('Level', 'Int', '%IW100', 'an analog value');
        UI.Project.AddTag('Flow', 'Real', '%ID104', 'a Real input');
        UI.Project.AddTag('Count', 'DInt', '%ID108', '');
        UI.Project.AddTag('Horn', 'Bool', '%Q8.0', 'an output beyond the CPU');
        UI.Project.AddTag('Valve', 'Int', '%QW100', 'an analog output');
      end
      else if St.Arg = 'door' then
      begin
        Pt := UI.HitPoint('tagio', 0);
        Add('before ' + BoolToStr(UI.Rt.GetSimBit(8, 0), True));
        UI.MouseMove(Pt.X, Pt.Y);
        UI.MouseDown(Pt.X, Pt.Y);
        Add('after down ' + BoolToStr(UI.Rt.GetSimBit(8, 0), True));
        UI.MouseUp(Pt.X, Pt.Y);
        Add(Format('Door switch clicked at %.0f,%.0f: I8.0 = %s', [Pt.X, Pt.Y, BoolToStr(UI.Rt.GetSimBit(8, 0), True)]));
      end
      else if St.Arg = 'sigbad' then
        UI.Project.AddSignal('%Q0.0', sgSquare, 0, 1, 1000, 50)
      else if St.Arg = 'watchmw' then
        UI.Project.AddWatch('%MW20', dfDec)
      else if St.Arg = 'watchbad' then
        UI.Project.AddWatch('"NoSuchTag"', dfDec)
      else if St.Arg = 'tagbad' then
        UI.Project.AddTag('Broken', 'Int', '%XW1', 'not an address: red, the message beside the buttons')
      else if St.Arg = 'dump signals' then
      begin
        Add('signals:');
        for V := 0 to High(UI.Project.Signals) do
          with UI.Project.Signals[V] do
            Add(Format('  %s %s %g..%g %g ms on=%s', [Address, SigKindNames[Kind], Lo, Hi, PeriodMs, BoolToStr(On, True)]));
        Add(Format('  Door (I8.0) after the run: %s, Level IW100 = %d', [BoolToStr(UI.Rt.GetSimBit(8, 0), True),
          SmallInt(UI.Rt.SimIn[100] shl 8 or UI.Rt.SimIn[101])]));
      end
      else if St.Arg = 'dump watch' then
      begin
        Add('watch:');
        for V := 0 to High(UI.Project.Watch) do Add('  ' + UI.Project.Watch[V].Address);
      end
      else if St.Arg = 'dump tags' then
      begin
        Add('tags:');
        for V := 0 to High(UI.Project.Tags) do
          Add(Format('  %s %s %s', [UI.Project.Tags[V].Name, UI.Project.Tags[V].TypeText, UI.Project.Tags[V].Address]));
      end;
      SaveToFile(FShotDir + 'io_check.txt');
    finally
      Free;
    end;
  if St.Cmd = 'exportall' then
    with TStringList.Create do
    try
      // every piece in every format: a line per file, True when it was written
      ForceDirectories(FShotDir + 'export');
      S1 := FShotDir + 'export' + PathDelim;
      for P := 0 to UI.Project.BlockCount - 1 do
      begin
        Add(Format('block%d.txt %s', [P, BoolToStr(UI.ExportPiece(0, 0, P, S1 + Format('block%d.txt', [P])), True)]));
        Add(Format('block%d.json %s', [P, BoolToStr(UI.ExportPiece(0, 1, P, S1 + Format('block%d.json', [P])), True)]));
      end;
      for P := 0 to UI.Project.Block(0).NetCount - 1 do
      begin
        Add(Format('ob1_net%d.txt %s', [P, BoolToStr(UI.ExportPiece(1, 0, P, S1 + Format('ob1_net%d.txt', [P])), True)]));
        Add(Format('ob1_net%d.json %s', [P, BoolToStr(UI.ExportPiece(1, 1, P, S1 + Format('ob1_net%d.json', [P])), True)]));
      end;
      for P := 0 to UI.Project.DBCount - 1 do
      begin
        Add(Format('db%d.csv %s', [P, BoolToStr(UI.ExportPiece(2, 0, P, S1 + Format('db%d.csv', [P])), True)]));
        Add(Format('db%d.txt %s', [P, BoolToStr(UI.ExportPiece(2, 1, P, S1 + Format('db%d.txt', [P])), True)]));
        Add(Format('db%d.json %s', [P, BoolToStr(UI.ExportPiece(2, 2, P, S1 + Format('db%d.json', [P])), True)]));
      end;
      for P := 0 to UI.Project.UdtCount - 1 do
      begin
        Add(Format('udt%d.txt %s', [P, BoolToStr(UI.ExportPiece(3, 0, P, S1 + Format('udt%d.txt', [P])), True)]));
        Add(Format('udt%d.csv %s', [P, BoolToStr(UI.ExportPiece(3, 1, P, S1 + Format('udt%d.csv', [P])), True)]));
        Add(Format('udt%d.json %s', [P, BoolToStr(UI.ExportPiece(3, 2, P, S1 + Format('udt%d.json', [P])), True)]));
      end;
      Add('watch.csv ' + BoolToStr(UI.ExportPiece(4, 0, 0, S1 + 'watch.csv'), True));
      Add('io.csv ' + BoolToStr(UI.ExportPiece(5, 0, 0, S1 + 'io.csv'), True));
      Add('tags.csv ' + BoolToStr(UI.ExportPiece(6, 0, 0, S1 + 'tags.csv'), True));
      SaveToFile(FShotDir + 'export_check.txt');
    finally
      Free;
    end;
  if St.Cmd = 'watchfile' then
    with TStringList.Create do
    try
      // Save the table to its own file, empty it, Open the file again
      if FileExists(FShotDir + 'export_check.txt') then LoadFromFile(FShotDir + 'export_check.txt');
      S1 := FShotDir + 'export' + PathDelim + 'test.watch';
      case St.Arg of
        'save':
          begin
            FWaitStep := Length(UI.Project.Watch);
            Add(Format('watch save: %s (%d rows)', [BoolToStr(UI.WatchSaveTo(S1), True), FWaitStep]));
          end;
        'clear': SetLength(UI.Project.Watch, 0);
        'open': Add(Format('watch open: %s, the same %d rows: %s', [BoolToStr(UI.WatchOpenFrom(S1), True),
          Length(UI.Project.Watch), BoolToStr(Length(UI.Project.Watch) = FWaitStep, True)]));
      end;
      SaveToFile(FShotDir + 'export_check.txt');
    finally
      Free;
    end;
  if St.Cmd = 'projfile' then
    with TStringList.Create do
    try
      // a project file to load: Cancel keeps the project, OK loads it; the file goes again
      if FileExists(FShotDir + 'export_check.txt') then LoadFromFile(FShotDir + 'export_check.txt');
      S1 := ExtractFilePath(ParamStr(0)) + 'projects' + PathDelim;
      if St.Arg = 'save' then
      begin
        ForceDirectories(S1);
        S2 := UI.Project.Name;
        UI.Project.Name := 'zz_export_test';
        UI.Project.SaveToFile(S1 + 'zz_export_test.vplc');
        UI.Project.Name := S2;
        UI.Project.Modified := True;
        UI.RefreshProjectFiles;
      end
      else if St.Arg = 'click' then
      begin
        UI.ShowProjectFile(UI.ProjectFileIndex('zz_export_test.vplc'));
        UI.Build(FStatic, FDyn);   // the list scrolled to it: its regions now
        Pt := UI.HitPoint('file', UI.ProjectFileIndex('zz_export_test.vplc'));
        UI.MouseMove(Pt.X, Pt.Y);
        UI.MouseDown(Pt.X, Pt.Y);
        UI.MouseUp(Pt.X, Pt.Y);
        Add('question shown: ' + BoolToStr(UI.AskOpen, True));
      end
      else if St.Arg = 'delete' then
      begin
        DeleteFile(S1 + 'zz_export_test.vplc');
        UI.RefreshProjectFiles;
      end
      else
        Add(Copy(St.Arg, 7, MaxInt) + ': ' + UI.Project.Name + '  ' +
          BoolToStr((Pos('cancel', St.Arg) > 0) = (UI.Project.Name <> 'zz_export_test'), True));
      SaveToFile(FShotDir + 'export_check.txt');
    finally
      Free;
    end;
  if St.Cmd = 'infocheck' then
    with TStringList.Create do
    try
      // the developer info window: shown / on top, after a step of the Developer menu
      if FileExists(FShotDir + 'dev_menu.txt') then LoadFromFile(FShotDir + 'dev_menu.txt');
      Add(Format('%s: visible %s, on top %s', [St.Arg, BoolToStr((InfoForm <> nil) and InfoForm.Visible, True),
        BoolToStr((InfoForm <> nil) and (InfoForm.FormStyle = fsStayOnTop), True)]));
      SaveToFile(FShotDir + 'dev_menu.txt');
    finally
      Free;
    end;
  if (St.Cmd = 'chatclick') and (Chat <> nil) then
  begin
    Pt := Chat.ButtonPoint(StrToInt(St.Arg));
    Chat.MouseClicks := 1;
    Chat.MouseMods := [];
    Chat.MouseMove(Pt.X, Pt.Y);
    Chat.MouseDown(Pt.X, Pt.Y);
    Chat.MouseUp(Pt.X, Pt.Y);
  end;
  if (St.Cmd = 'chatattach') and (Chat <> nil) then
    with TStringList.Create do
    try
      // the note of every attachment, for the test
      if FileExists(FShotDir + 'chat_attach.txt') then LoadFromFile(FShotDir + 'chat_attach.txt');
      Add(St.Arg + ': ' + BoolToStr(Chat.AttachFile(ExpandFileName(St.Arg)), True) + '  ' + Chat.NoteText);
      SaveToFile(FShotDir + 'chat_attach.txt');
    finally
      Free;
    end;
  if (St.Cmd = 'chatexport') and (Chat <> nil) then Chat.ExportTo(FShotDir + St.Arg);
  if (St.Cmd = 'chatselect') and (Chat <> nil) then
  begin
    // drag over the conversation through the UI's mouse: from line a char b to line c char d
    S0 := St.Arg;
    Pt := Chat.ContentPoint(StrToInt(ExtractWord(1, S0, [','])), StrToInt(ExtractWord(2, S0, [','])));
    Pp := Chat.ContentPoint(StrToInt(ExtractWord(3, S0, [','])), StrToInt(ExtractWord(4, S0, [','])));
    Chat.MouseClicks := StrToIntDef(ExtractWord(5, S0, [',']), 1);
    Chat.MouseMods := [];
    Chat.MouseMove(Pt.X, Pt.Y);
    Chat.MouseDown(Pt.X, Pt.Y);
    if Chat.MouseClicks = 1 then Chat.MouseMove(Pp.X, Pp.Y);
    Chat.MouseUp(Pp.X, Pp.Y);
    Chat.MouseClicks := 1;
  end;
  if (St.Cmd = 'chatimgmenu') and (Chat <> nil) then
  begin
    // the right button on the first picture of the chat
    Pt := Chat.ImagePoint(0);
    Chat.MouseRightDown(Pt.X, Pt.Y);
  end;
  if (St.Cmd = 'chatimgsave') and (Chat <> nil) then
    with TStringList.Create do
    try
      // Save As of the menu (the file name instead of the dialog), Copy, and what the clipboard has
      Add('save: ' + BoolToStr(Chat.SaveImage(0, FShotDir + St.Arg), True));
      Add('copy: ' + BoolToStr(Chat.CopyImage(0), True));
      Add('clipboard has a picture: ' + BoolToStr(Clipbrd.Clipboard.HasPictureFormat, True));
      SaveToFile(FShotDir + 'chat_image.txt');
    finally
      Free;
    end;
  if (St.Cmd = 'chatcopy') and (Chat <> nil) then
  begin
    // Ctrl+C in the chat window: what goes to the clipboard, into a file
    Chat.ClipboardOut := '';
    Chat.KeyDown(ukChar, 'c', [umCtrl]);
    with TStringList.Create do
    try
      Text := Chat.ClipboardOut;
      SaveToFile(FShotDir + St.Arg);
    finally
      Free;
    end;
  end;
  if (St.Cmd = 'chatmenu') and (Chat <> nil) then
  begin
    // a menu of the chat window: the bar item (9 Auditor, 10 Export), then an item of it
    V := StrToInt(ExtractWord(1, St.Arg, [',']));
    Pt := Chat.ButtonPoint(V);
    Chat.MouseMove(Pt.X, Pt.Y);
    Chat.MouseDown(Pt.X, Pt.Y);
    Chat.MouseUp(Pt.X, Pt.Y);
  end;
  if (St.Cmd = 'chattype') and (Chat <> nil) then
  begin
    // the question typed into the chat window's field and Enter
    Chat.TextInput(St.Arg);
    Chat.KeyDown(ukEnter, #0, []);
  end;
  if St.Cmd = 'keycheck' then
    with TStringList.Create do
    try
      if FileExists(FShotDir + 'key_ui.txt') and (St.Arg <> 'var') then LoadFromFile(FShotDir + 'key_ui.txt');
      S0 := ClaudeApiKey(S1);
      case St.Arg of
        'var': Add('var: ' + BoolToStr((S0 = 'dummy-ui-value') and ClaudeHasEnvKey and
          (SysUtils.GetEnvironmentVariable(ClaudeKeyVar) = 'dummy-ui-value'), True) + '  (' + S1 + ')');
        'removed': Add('removed: ' + BoolToStr((S0 = '') and not ClaudeHasEnvKey, True));
        'file': Add('file: ' + BoolToStr((S0 = 'dummy-encrypted') and ClaudeHasSavedKey, True) + '  (' + S1 + ')');
        'deleted': Add('deleted: ' + BoolToStr((S0 = '') and not ClaudeHasSavedKey, True));
        'closed': Add('closed: ' + BoolToStr(not UI.KeyDialogOpen, True));
        'fromchat': Add('dialog from the chat: ' + BoolToStr(UI.KeyDialogOpen, True));
        'cancel': Add('cancel keeps both: ' + BoolToStr(ClaudeHasEnvKey and ClaudeHasSavedKey and (S0 = 'dummy-ui-value'), True));
        'removeall': Add('remove takes both: ' + BoolToStr((S0 = '') and not ClaudeHasEnvKey and not ClaudeHasSavedKey and
          (SysUtils.GetEnvironmentVariable(ClaudeKeyVar) = ''), True));
      end;
      SaveToFile(FShotDir + 'key_ui.txt');
    finally
      Free;
    end;
  if St.Cmd = 'claudewait' then
  begin
    // the same step again until Claude is done (or the time is up); "allow" answers its download
    if FWaitStep <> FShotPos then
    begin
      FWaitStep := FShotPos;
      FWaitT0 := Now;
    end;
    if (UI.Claude.State = asConfirm) and (Pos('allow', St.Arg) > 0) then UI.Claude.Confirm(True);
    if UI.Claude.Busy and ((Now - FWaitT0) * 86400 < StrToIntDef(Copy(St.Arg, Pos(':', St.Arg) + 1, 9), 600)) then
    begin
      Dec(FShotPos);
      FShotWait := 30;
    end;
  end;
  if St.Cmd = 'claudedump' then
    with TStringList.Create do
    try
      for P := 0 to High(UI.Claude.Chat) do
        Add(Format('[%s] %s', [Copy(GetEnumName(TypeInfo(TChatKind), Ord(UI.Claude.Chat[P].Kind)), 3, 20),
          UI.Claude.Chat[P].Text]));
      Add(Format('tokens: %d in, %d out', [UI.Claude.InTokens, UI.Claude.OutTokens]));
      Add('');
      Add('---------- the blocks after the request ----------');
      for P := 0 to UI.Project.BlockCount - 1 do
      begin
        Add(Format('== %s "%s"', [UI.Project.Block(P).Title, UI.Project.Block(P).Name]));
        for V := 0 to UI.Project.Block(P).NetCount - 1 do
          if UI.Project.Block(P).Net(V).Kind <> nkLAD then
          begin
            Add(Format('-- network %d %s', [V + 1, UI.Project.Block(P).Net(V).Title]));
            Add(UI.Project.Block(P).Net(V).Stl.Text);
          end
          else
            Add(Format('-- network %d %s (LAD %d x %d)', [V + 1, UI.Project.Block(P).Net(V).Title,
              UI.Project.Block(P).Net(V).Rows, UI.Project.Block(P).Net(V).Cols]));
      end;
      SaveToFile(FShotDir + 'claude_live.txt');
    finally
      Free;
    end;
  if St.Cmd = 'claudeclose' then UI.CloseClaude;
  if St.Cmd = 'claudeask' then UI.AskClaude(St.Arg);
  if St.Cmd = 'claudeallow' then UI.Claude.Confirm(True);
  if St.Cmd = 'claudeundo' then UI.Claude.UndoChanges;
  if St.Cmd = 'ladmenu' then
  begin
    // the right button on the NC contact (column 2): it is selected, the menu opens
    Pt := UI.CellPoint(3, 0, 1);
    Pp := UI.DesignToPixel(Pt.X, Pt.Y);
    UI.MouseRightDown(Pp.X, Pp.Y);
  end;
  if St.Cmd = 'ladmenucopy' then
  begin
    // "Copy" is the first item, 36 below where the menu opened
    Pt := UI.CellPoint(3, 0, 1);
    // the menu stays on the screen: its top is at most 730
    Pp := UI.DesignToPixel(Pt.X + 50, Min(Pt.Y, 730) + 36);
    UI.MouseClicks := 1;
    UI.MouseDown(Pp.X, Pp.Y);
    UI.MouseUp(Pp.X, Pp.Y);
  end;
  if St.Cmd = 'ladmenu2' then
  begin
    FDragShot := CellsText(UI.Project.Block(0).Net(3));
    Pt := UI.CellPoint(3, 0, 3);
    Pp := UI.DesignToPixel(Pt.X, Pt.Y);
    UI.MouseRightDown(Pp.X, Pp.Y);
  end;
  if St.Cmd = 'ladmenupaste' then
  begin
    // "Paste (insert)" is the third item
    Pt := UI.CellPoint(3, 0, 3);
    Pp := UI.DesignToPixel(Pt.X + 50, Min(Pt.Y, 730) + 24 + 2 * 26 + 12);
    UI.MouseDown(Pp.X, Pp.Y);
    UI.MouseUp(Pp.X, Pp.Y);
    with TStringList.Create do
    try
      Add('before: ' + FDragShot);
      Add('paste:  ' + CellsText(UI.Project.Block(0).Net(3)));
      SaveToFile(FShotDir + 'lad_menu.txt');
    finally
      Free;
    end;
  end;
  if St.Cmd = 'ladgrow' then
  begin
    // past the coil in the last column: the rung grows; F2 puts a contact there, it grows again
    UI.KeyDown(ukRight, #0, []);
    UI.KeyDown(ukF2, #0, []);
    UI.TextInput('"Start_PB"');
    UI.KeyDown(ukEnter, #0, []);
  end;
  if St.Cmd = 'ladhwheel' then
  begin
    // Shift + wheel over the network: back to the left
    Pt := UI.CellPoint(3, 0, 3);
    Pp := UI.DesignToPixel(Pt.X, Pt.Y);
    UI.MouseMove(Pp.X, Pp.Y);
    UI.WheelShift := True;
    UI.Wheel(3);
    UI.WheelShift := False;
  end;
  if St.Cmd = 'focus0' then UI.FocusStl(0, 0, 0);
  if St.Cmd = 'vardrag' then
  begin
    // the grip of interface row 0 (Run) onto line 1 of the code, after "#Pulse"
    Pt := UI.IfacePoint(0);
    Pp := UI.DesignToPixel(Pt.X, Pt.Y);
    UI.MouseClicks := 1;
    UI.MouseMods := [];
    UI.MouseDown(Pp.X, Pp.Y);
    Pt := UI.CaretPoint;
    Pp := UI.DesignToPixel(Pt.X + 40, Pt.Y + 30);
    UI.MouseMove(Pp.X, Pp.Y);
    Pp := UI.DesignToPixel(Pt.X + 2, Pt.Y + 8);
    UI.MouseMove(Pp.X, Pp.Y);
    FDragShot := UI.Project.FindBlock(bkFB, 1).Net(0).Stl[0];
    UI.MouseUp(Pp.X, Pp.Y);
    with TStringList.Create do
    try
      Add('line 1 before: ' + FDragShot);
      Add('line 1 after:  ' + UI.Project.FindBlock(bkFB, 1).Net(0).Stl[0]);
      SaveToFile(FShotDir + 'var_drag.txt');
    finally
      Free;
    end;
  end;
  if St.Cmd = 'ladband' then
  begin
    // a rubber band from the wire in column 5 to the NC contact in column 2
    Pt := UI.CellPoint(3, 0, 4);
    Pp := UI.DesignToPixel(Pt.X, Pt.Y);
    UI.MouseClicks := 1;
    UI.MouseMods := [];
    UI.MouseDown(Pp.X, Pp.Y);
    Pt := UI.CellPoint(3, 0, 1);
    Pp := UI.DesignToPixel(Pt.X, Pt.Y);
    UI.MouseMove(Pp.X, Pp.Y);
    UI.MouseUp(Pp.X, Pp.Y);
  end;
  if St.Cmd = 'ladmove' then
  begin
    // grab the NC contact (in the selection) and move the selection one column to the right (onto the
    // wire there: a drop needs a wire)
    FDragShot := CellsText(UI.Project.Block(0).Net(3));
    Pt := UI.CellPoint(3, 0, 1);
    Pp := UI.DesignToPixel(Pt.X, Pt.Y);
    UI.MouseDown(Pp.X, Pp.Y);
    Pp := UI.DesignToPixel(UI.CellPoint(3, 0, 2).X, Pt.Y);
    UI.MouseMove(Pp.X, Pp.Y);
    UI.MouseUp(Pp.X, Pp.Y);
    FDragShot2 := CellsText(UI.Project.Block(0).Net(3));
  end;
  if St.Cmd = 'ladundo' then
  begin
    UI.KeyDown(ukChar, 'z', [umCtrl]);
    with TStringList.Create do
    try
      Add('before: ' + FDragShot);
      Add('moved:  ' + FDragShot2);
      Add('undo:   ' + CellsText(UI.Project.Block(0).Net(3)));
      Add('undo gives the start back: ' + BoolToStr(CellsText(UI.Project.Block(0).Net(3)) = FDragShot, True));
      SaveToFile(FShotDir + 'lad_edit.txt');
    finally
      Free;
    end;
  end;
  if St.Cmd = 'edundo' then
  begin
    // undo / redo through the keys; the result for the test log
    S0 := UI.Project.FindBlock(bkFC, 1).Net(0).Stl.Text;
    UI.FocusStl(0, 12, 4);
    UI.KeyDown(ukChar, 'd', [umCtrl]);
    UI.KeyDown(ukChar, 'l', [umCtrl]);
    UI.KeyDown(ukChar, 'l', [umCtrl]);
    UI.TextInput('abc');
    S1 := UI.Project.FindBlock(bkFC, 1).Net(0).Stl.Text;
    UI.KeyDown(ukChar, 'z', [umCtrl]);
    UI.KeyDown(ukChar, 'z', [umCtrl]);
    UI.KeyDown(ukChar, 'z', [umCtrl]);
    UI.KeyDown(ukChar, 'z', [umCtrl]);
    S2 := UI.Project.FindBlock(bkFC, 1).Net(0).Stl.Text;
    UI.KeyDown(ukChar, 'y', [umCtrl]);
    UI.KeyDown(ukChar, 'y', [umCtrl]);
    UI.KeyDown(ukChar, 'y', [umCtrl]);
    UI.KeyDown(ukChar, 'y', [umCtrl]);
    S3 := UI.Project.FindBlock(bkFC, 1).Net(0).Stl.Text;
    with TStringList.Create do
    try
      Add('changed: ' + BoolToStr(S1 <> S0, True));
      Add('undo x4 back to the start: ' + BoolToStr(S2 = S0, True));
      Add('redo x4 back to the edit: ' + BoolToStr(S3 = S1, True));
      SaveToFile(FShotDir + 'edit_undo.txt');
    finally
      Free;
    end;
  end;
  if St.Cmd = 'edcomp' then
  begin
    UI.KeyDown(ukEsc, #0, []);
    UI.FocusStl(0, 14, 0);
    UI.KeyDown(ukEnd, #0, []);
    UI.KeyDown(ukEnter, #0, []);
    UI.TextInput('#su');
    UI.KeyDown(ukChar, ' ', [umCtrl]);
  end;
  if St.Cmd = 'type' then
  begin
    // a new line after line 7, typed like the keyboard does it; one wrong instruction
    UI.FocusStl(0, 6, 0);
    UI.KeyDown(ukEnd, #0, []);
    UI.KeyDown(ukEnter, #0, []);
    UI.TextInput('A');
    UI.KeyDown(ukTab, #0, []);
    UI.TextInput('M 0.5    // typed');
    UI.KeyDown(ukEnter, #0, []);
    UI.TextInput('XYZ M0.0');
  end;
  if St.Cmd = 'compile' then UI.KeyDown(ukF7, #0, []);
  if St.Cmd = 'fkey' then
    case St.Arg of
      '5': UI.KeyDown(ukF5, #0, []);
      '8': UI.KeyDown(ukF8, #0, []);
      '9': UI.KeyDown(ukF9, #0, []);
    end;
  if St.Cmd = 'selftest' then
  begin
    UI.SelfTestModbus;
    UI.SelfTestS7;
  end;
end;

{ ---------- --export folder [w h frames fps] ---------- }

procedure TSDLView.CmdLineExport;
var
  Opt: TExportOptions;
  Res: TStringList;
  A: Integer;
begin
  A := FExportArgs;
  Opt := DefaultExportOptions;
  Opt.Folder := ExpandFileName(ParamStr(A + 1));
  Opt.Width := StrToIntDef(ParamStr(A + 2), 1600);
  Opt.Height := StrToIntDef(ParamStr(A + 3), 900);
  Opt.Frames := StrToIntDef(ParamStr(A + 4), 40);
  Opt.Fps := StrToIntDef(ParamStr(A + 5), 20);
  Exporting := True;
  Renderer.Wait;
  Res := RunExport(UI, Renderer.Pool, Opt, Renderer.Width, Renderer.Height, nil);
  try
    Res.SaveToFile(IncludeTrailingPathDelimiter(Opt.Folder) + 'export.txt');
  finally
    Res.Free;
  end;
  Exporting := False;
  FRunning := False;
  Application.Terminate;
end;

{ ---------- --bench ---------- }

procedure TSDLView.BenchFrame(ANow, AInterval: Double);
begin
  if FBenchT0 = 0 then FBenchT0 := ANow + 2000;
  if ANow < FBenchT0 then Exit;
  SetLength(FBench, Length(FBench) + 1);
  FBench[High(FBench)] := AInterval;
  if ANow - FBenchT0 >= FBenchSecs * 1000 then
  begin
    WriteBenchReport;
    FRunning := False;
    Application.Terminate;
  end;
end;

procedure TSDLView.WriteBenchReport;
var
  SL: TStringList;
  Sorted: array of Single;
  I, J, N, Missed: Integer;
  Sum, Budget: Double;
  T: Single;
begin
  N := Length(FBench);
  if N = 0 then Exit;
  Sorted := Copy(FBench);
  for I := 1 to N - 1 do
  begin
    T := Sorted[I];
    J := I - 1;
    while (J >= 0) and (Sorted[J] > T) do
    begin
      Sorted[J + 1] := Sorted[J];
      Dec(J);
    end;
    Sorted[J + 1] := T;
  end;
  Sum := 0;
  for I := 0 to N - 1 do Sum := Sum + FBench[I];
  Budget := 1000 / Max(1, RefreshHz);
  Missed := 0;
  for I := 0 to N - 1 do
    if FBench[I] > Budget * 1.5 then Inc(Missed);
  SL := TStringList.Create;
  try
    SL.Add('Virtual PLC frame pacing  ' + FormatDateTime('yyyy-mm-dd hh:nn:ss', SysUtils.Now));
    SL.Add(Format('%s, backend %s, vsync %s, display %s Hz', [SdlVersion, RenderBackend,
      IfThen(FVSync, 'on', 'off'), FormatFloat('0', RefreshHz)]));
    SL.Add(Format('frame %d x %d, %d threads, %d bands', [Renderer.Width, Renderer.Height, Renderer.Threads,
      Renderer.BandCount]));
    SL.Add(Format('presents %d in %.1f s  ->  %.2f fps', [N, Sum / 1000, N * 1000 / Sum]));
    SL.Add(Format('interval ms: mean %.2f  median %.2f  p99 %.2f  max %.2f', [Sum / N, Sorted[N div 2],
      Sorted[Min(N - 1, Round(N * 0.99))], Sorted[N - 1]]));
    SL.Add(Format('missed vblank: %d (%.2f %%)', [Missed, Missed * 100 / N]));
    SL.Add(Format('render wall %.2f ms, cpu %.2f ms (smoothed), build %.2f ms, upload %.2f ms',
      [Renderer.WallSmooth, Renderer.CpuSmooth, LastBuildMs, LastUploadMs]));
    SL.Add(Format('PLC: %s, %.0f cycles/s, model cycle %.3f ms', [UI.Rt.Model.Name, UI.Rt.CyclesPerSec,
      UI.Rt.ModelUs / 1000]));
    SL.SaveToFile(ChangeFileExt(ParamStr(0), '-bench.txt'));
  finally
    SL.Free;
  end;
end;

{ ---------- controls ---------- }

procedure TSDLView.SetVSync(AValue: Boolean);
begin
  FVSync := AValue;
  ApplyVSync;
end;

procedure TSDLView.SetThreads(N: Integer);
begin
  Renderer.SetThreads(N);
  FHaveFrame := False;
  UI.InvalidateStatic;
  ResetStats;
end;

procedure TSDLView.ResetStats;
begin
  FillChar(IntervalHist, SizeOf(IntervalHist), 0);
  FillChar(RenderHist, SizeOf(RenderHist), 0);
  FillChar(CpuHist, SizeOf(CpuHist), 0);
  FillChar(BuildHist, SizeOf(BuildHist), 0);
  FillChar(UploadHist, SizeOf(UploadHist), 0);
  FillChar(SwapHist, SizeOf(SwapHist), 0);
  MissedFrames := 0;
end;

procedure TSDLView.ToggleFullScreen;
begin
  FFullScreen := not FFullScreen;
  SDL_SetWindowFullscreen(FWin, FFullScreen);
  if InfoForm <> nil then
    if FFullScreen then InfoForm.FormStyle := fsStayOnTop else InfoForm.FormStyle := fsNormal;
end;

procedure TSDLView.SaveShot(const AFile: string);
var
  B: TBGRABitmap;
  F: string;
begin
  B := TBGRABitmap.Create(1, 1);
  try
    Renderer.Assemble(B);
    F := AFile;
    if F = '' then
    begin
      ForceDirectories(ExtractFilePath(ParamStr(0)) + 'export');
      F := ExtractFilePath(ParamStr(0)) + 'export' + PathDelim + 'vplc_' +
        FormatDateTime('yyyymmdd_hhnnss', SysUtils.Now) + '.png';
    end;
    B.SaveToFile(F);
    LastSaved := F;
  finally
    B.Free;
  end;
end;

procedure TSDLView.PlaceInfoBeside;
const
  Gap = 12;
var
  WA: TRect;
  L, T, W: Integer;
begin
  if FFullScreen or (InfoForm = nil) then Exit;
  WA := Screen.WorkAreaRect;
  L := Left;
  T := Top;
  W := Width;
  if L + W + Gap + InfoForm.Width <= WA.Right then
    InfoForm.SetBounds(L + W + Gap, T - 30, InfoForm.Width, InfoForm.Height)
  else if L - Gap - InfoForm.Width >= WA.Left then
    InfoForm.SetBounds(L - Gap - InfoForm.Width, T - 30, InfoForm.Width, InfoForm.Height)
  else
    InfoForm.SetBounds(WA.Right - InfoForm.Width - 8, Max(WA.Top, T + 60), InfoForm.Width,
      Min(InfoForm.Height, WA.Bottom - T - 60));
end;

procedure TSDLView.ShowInfo;
begin
  if InfoForm = nil then Exit;
  if not InfoForm.Visible then
  begin
    PlaceInfoBeside;
    InfoForm.Show;
  end;
  InfoForm.BringToFront;
end;

function TSDLView.Left: Integer;
var
  X, Y: LongInt;
begin
  SDL_GetWindowPosition(FWin, @X, @Y);
  Result := X;
end;

function TSDLView.Top: Integer;
var
  X, Y: LongInt;
begin
  SDL_GetWindowPosition(FWin, @X, @Y);
  Result := Y;
end;

function TSDLView.Width: Integer;
var
  W, H: LongInt;
begin
  SDL_GetWindowSize(FWin, @W, @H);
  Result := W;
end;

function TSDLView.Height: Integer;
var
  W, H: LongInt;
begin
  SDL_GetWindowSize(FWin, @W, @H);
  Result := H;
end;

end.
