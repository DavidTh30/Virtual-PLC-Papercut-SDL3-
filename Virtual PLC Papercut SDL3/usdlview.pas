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
  uClaudeChat;

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
    Add(5, 'saveask', 'change');
    Add(10, 'saveask', 'click sample');
    Add(5, 'saveask', 'answer 2');
    Add(10, 'saveask', 'check don''t save loads the sample');
    Add(5, 'saveask', 'click sample');
    Add(10, 'saveask', 'check no changes: no question');
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
    // the language help of the Elements panel: select (drag, double click, triple click), copy,
    // the right button, a word dragged into the SCL code; the STL help
    DeleteFile(FShotDir + 'help_check.txt');
    Add(10, 'sample', '13');
    Add(5, 'screen', '1');
    Add(5, 'fc1');
    Add(5, 'stlnet', 'SCL');
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
    Add(5, 'helpsel', '9,14,9,14,2');
    Add(5, 'helpcopy', 'the word to drag');
    Add(5, 'stlnet', 'SCL');
    Add(10, 'helpdrag', '9,16');
    Add(10, 'helpcheck', '');
    Add(10, 'shot', 'help_3_dropped');
    Add(5, 'ob1');
    Add(5, 'stlnet', 'STL');
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
    Add(10, 'uiclick2', 'ask:1');
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
    Add(5, 'chatselect', '1,4,3,12,1');
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
        else if S0 = 'click sample' then Pt := UI.HitPoint('sample', 13)
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
        else if Pos('no question', S0) > 0 then Ok := not UI.AskOpen
        else if Pos('runs on', S0) > 0 then Ok := FRunning and not UI.QuitRequested and not UI.AskOpen
        else Ok := UI.QuitRequested;
        Add(S0 + ': ' + BoolToStr(Ok, True) + '   (' + UI.Project.Name + ')');
        if Pos('program ends', S0) > 0 then DeleteFile(S1);
      end;
      SaveToFile(FShotDir + 'saveask_check.txt');
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
    // grab the NC contact (in the selection) and move the selection one row down
    FDragShot := CellsText(UI.Project.Block(0).Net(3));
    Pt := UI.CellPoint(3, 0, 1);
    Pp := UI.DesignToPixel(Pt.X, Pt.Y);
    UI.MouseDown(Pp.X, Pp.Y);
    Pp := UI.DesignToPixel(Pt.X, Pt.Y + 70);
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
