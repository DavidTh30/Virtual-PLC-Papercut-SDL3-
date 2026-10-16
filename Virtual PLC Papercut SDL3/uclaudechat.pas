unit uClaudeChat;

{ The Claude chat in a window of its own (a second SDL window, see uSDLView).

  TClaudeChatUI draws the conversation of the agent that the program editor owns (TPlcUI.Claude):
  the answers, the tool calls, Allow / Deny for a download, the quick actions, the attachments and
  the question field. It does not lay out on the 1600 x 900 design screen of the main window: one
  design unit is one point of the window (the display scale), so the text keeps its size and the
  lines get longer or shorter with the window. The question goes through OnAsk (the editor adds
  what it shows); the key is set in the main window (OnKeyDialog).

  The menu bar of the window: New chat, Auditor (Undo changes), Export (TXT, PDF, PNG).
  The conversation is laid out once into lines (cached until the chat or the width changes); the
  same lines are drawn, selected with the mouse (drag, double click a word, triple click a message,
  Ctrl+A), copied (Ctrl+C, right click menu) and exported. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, StrUtils, Types, Dialogs, Clipbrd, Graphics, BGRABitmap, BGRABitmapTypes, LazUTF8, uPaperDL, uUiBase,
  uClaude, uClaudeHttp, uChatFiles, uChatPdf, base64;

type
  TAskEvent = procedure(const S: string; const Files: TChatAttachments) of object;

  { one laid out line of the conversation (content coordinates, design units) }
  TChatLine = record
    X, Y: Single;
    Font: TFontKind;
    Size: Single;
    Text: string;
    C: TBGRAPixel;
    Entry: Integer;     // the chat entry (-1: the hint)
    Cont: Boolean;      // continues the line before it (a wrapped paragraph): copied with a space
    Fit: Boolean;       // drawn shortened to the width (tool calls)
  end;
  TChatRect = record
    X, Y, W, H: Single;
    C: TBGRAPixel;
  end;
  { the picture of an attached image: Src at most 480 x 320, Px the copy at the size it is drawn }
  TChatThumb = record
    Entry: Integer;     // the chat entry (-1: a file for the next question)
    Src, Px: TBGRABitmap;
    Name, Media, Data: string;   // the picture as it was sent (base64): for Copy and Save As
  end;
  TChatImg = record
    X, Y, W, H: Single;
    T: Integer;         // into FThumbs
  end;

  { TClaudeChatUI }

  TClaudeChatUI = class(TUiBase)
  private
    FDW, FDH: Single;          // the window in design units
    FDensity: Single;
    FChatScroll: Single;
    FChatSeen: Integer;        // chat entries when the view last scrolled down
    FAskText: string;
    FAutoFocus: Boolean;       // the question field takes the keys whenever Claude is idle
    FEnter: Boolean;           // the edit ends with Enter (sends), not with a click elsewhere
    FDoc: Boolean;             // building an export picture (no selection, no window parts)
    { the layout }
    FL: array of TChatLine;
    FLN: Integer;
    FR: array of TChatRect;
    FRN: Integer;
    FLayKey: string;
    FThumbs: array of TChatThumb;
    FPend: array of TChatThumb;   // parallel to FFiles (Src nil: not an image)
    FImgs: array of TChatImg;
    FImN: Integer;
    FLayW, FLayH: Single;
    FCX, FOY0: Single;         // where the content is drawn in the window (last frame)
    FConvTop, FConvBot: Single;
    { the selection: (char, line) }
    FSel0, FSel1: TPoint;
    FDragPress: Integer;
    FDragW0, FDragW1: TPoint;  // a double / triple click: the word / message it started on
    FDragMode: Integer;        // 1 chars, 2 words, 3 messages
    { menus: 0 none, 1 Auditor, 2 Export, 3 the right click menu }
    FMenu: Integer;
    FMenuX, FMenuY: Single;
    FCtxEntry: Integer;
    FCtxImg: Integer;          // the picture of the right click menu (into FThumbs)
    { the files for the next question; a short note at the bottom }
    FFiles: TChatAttachments;
    FNote: string;
    FNoteErr: Boolean;
    FNoteT: Double;
    procedure Wrap(const Txt0: string; Kind: TFontKind; Size, MaxW: Single; L: TStringList);
    procedure Ask(const S: string);
    procedure Layout(W: Single);
    procedure AddLine(X, Y: Single; Font: TFontKind; Size: Single; const S: string; C: TBGRAPixel; Entry: Integer;
      Cont: Boolean; Fit: Boolean = False);
    procedure AddRect(X, Y, W, H: Single; C: TBGRAPixel);
    function ScaledFor(var T: TChatThumb; PW, PH: Integer): TBGRABitmap;
    procedure ThumbSize(B: TBGRABitmap; MaxW, MaxH: Single; out W, H: Single);
    procedure FreeThumbs;
    procedure DrawContent(OX, OY, ClipTop, ClipBot, W: Single);
    procedure DrawMenuBar;
    procedure DrawDrop;
    procedure DrawFooter;
    function LineH: Single;
    function XOf(Li, K: Integer): Single;
    function PosAt(MX, MY: Single): TPoint;
    function WordAt(P: TPoint; out A, B: TPoint): Boolean;
    function EntryRange(E: Integer; out A, B: TPoint): Boolean;
    procedure SelOrdered(out A, B: TPoint);
    function HasSel: Boolean;
    procedure Note(const S: string; Err: Boolean = False);
    procedure ChooseFiles;
    procedure ChooseImageSave(T: Integer);
    procedure ChooseExport(const Ext: string);
    function DocTitle: string;
    function BuildDoc(DL: TDisplayList; DocW, Margin, AScale: Single): Single;
    function PdfItems(DocW, Margin: Single; out DocH: Single): TPdfItems;
  protected
    procedure DoClick(Id: Integer; const S: string); override;
    procedure DoWheel(Id: Integer; DY: Single); override;
    procedure DoDrag(Id: Integer; X, Y: Single; const R: TRectF); override;
    procedure DoRightClick(Id: Integer); override;
    procedure DoKey(Key: TUiKey; Ch: Char; Mods: TUiMods); override;
    procedure DoText(const S: string); override;
    procedure CommitEdit(Id: Integer; const S: string); override;
  public
    Agent: TClaudeAgent;
    OnAsk: TAskEvent;
    OnKeyDialog: TNotifyEvent;
    ProjectName: string;       // for the export title
    constructor Create(AGlyphs: TGlyphCache);
    destructor Destroy; override;
    procedure SetDensity(V: Single);
    procedure SetSize(AW, AH: Integer); override;
    procedure KeyDown(Key: TUiKey; Ch: Char; Mods: TUiMods); override;
    procedure Update(DT: Double);
    procedure Build(DL: TDisplayList);
    procedure Opened;            // the window was shown: scroll down, focus the question
    procedure ScrollTop;
    function ButtonPoint(Id: Integer): TPointF;   // the middle of a region of the last frame (pixels)
    function ContentPoint(Line, Ch: Integer): TPointF;   // a character of the conversation (pixels)
    { the selection and the clipboard }
    procedure SelectAll;
    function SelText: string;
    procedure CopySel;
    { attachments and the export (also for the script) }
    function AttachFile(const FileName: string): Boolean;
    function ExportTo(const FileName: string): Boolean;
    { a picture of the chat (I into the drawn pictures, 0 = the first): its middle, copy, save }
    function ImagePoint(I: Integer): TPointF;
    function CopyImage(T: Integer): Boolean;
    function SaveImage(T: Integer; const FileName: string): Boolean;
    property Files: TChatAttachments read FFiles;
    property NoteText: string read FNote;
  end;

const
  { the ids of the chat window }
  ciUndo = 1; ciNew = 2; ciSend = 3; ciStop = 4; ciAllow = 5; ciDeny = 6; ciKey = 7; ciAttach = 8;
  ciMenuAud = 9; ciMenuExp = 10; ciMenuClose = 11; ciExpTxt = 12; ciExpPdf = 13; ciExpPng = 14;
  ciCopy = 15; ciCopyMsg = 16; ciSelAll = 17; ciImgCopy = 18; ciImgSave = 19;
  ciAsk = 20; ciWheel = 21; ciBg = 22; ciText = 23;
  ciQuick = 30; ciChipDel = 40; ciImg = 1000;   // + the picture (into FThumbs)
  MaxChatFiles = 8;

function ChatMd(const S: string): string;

implementation

{ Claude's markdown for the chat: a table row becomes cells with dots between them, the |---| line
  goes, `code` loses its backticks, emoji that have no glyph become ones that have }
function ChatMd(const S: string): string;
var
  SL: TStringList;
  I, K: Integer;
  L, T: string;
  OnlyRule: Boolean;
begin
  Result := '';
  SL := TStringList.Create;
  try
    SL.Text := S;
    for I := 0 to SL.Count - 1 do
    begin
      L := SL[I];
      T := Trim(L);
      if (Length(T) > 1) and (T[1] = '|') then
      begin
        OnlyRule := True;
        for K := 1 to Length(T) do
          if not (T[K] in ['|', '-', ':', ' ']) then OnlyRule := False;
        if OnlyRule then Continue;
        if T[Length(T)] = '|' then Delete(T, Length(T), 1);
        Delete(T, 1, 1);
        L := StringReplace(T, '|', '  ·  ', [rfReplaceAll]);
      end;
      if Copy(T, 1, 3) <> '```' then L := StringReplace(L, '`', '', [rfReplaceAll]);   // a fence stays
      L := StringReplace(L, '✅', '✓', [rfReplaceAll]);
      L := StringReplace(L, '❌', '✕', [rfReplaceAll]);
      L := StringReplace(L, '⚠️', '!', [rfReplaceAll]);
      L := StringReplace(L, '⚠', '!', [rfReplaceAll]);
      Result := Result + L + LineEnding;
    end;
  finally
    SL.Free;
  end;
  Result := TrimRight(Result);
end;

function PickC(B: Boolean; const T, F: TBGRAPixel): TBGRAPixel;
begin
  if B then Result := T else Result := F;
end;

{ the picture of an image attachment, at most 480 x 320 (nil when it cannot be read) }
function MakeThumb(const A: TChatAttachment): TBGRABitmap;
var
  M: TStringStream;
  B: TBGRABitmap;
  K: Single;
begin
  Result := nil;
  if A.Kind <> cfImage then Exit;
  M := TStringStream.Create(DecodeStringBase64(A.Data));
  try
    try
      B := TBGRABitmap.Create(M);
    except
      Exit;
    end;
    K := Min(1, Min(480 / Max(1, B.Width), 320 / Max(1, B.Height)));
    if K < 1 then
    begin
      Result := B.Resample(Max(1, Round(B.Width * K)), Max(1, Round(B.Height * K)), rmFineResample) as TBGRABitmap;
      B.Free;
    end
    else
      Result := B;
  finally
    M.Free;
  end;
end;

function PtLess(const A, B: TPoint): Boolean;
begin
  Result := (A.Y < B.Y) or ((A.Y = B.Y) and (A.X < B.X));
end;

{ TClaudeChatUI }

constructor TClaudeChatUI.Create(AGlyphs: TGlyphCache);
begin
  FDensity := 1;
  inherited Create(AGlyphs);
  FChatSeen := -1;
  FAutoFocus := True;
  FCtxEntry := -1;
end;

destructor TClaudeChatUI.Destroy;
var
  K: Integer;
begin
  FreeThumbs;
  for K := 0 to High(FPend) do
  begin
    FPend[K].Src.Free;
    FPend[K].Px.Free;
  end;
  inherited Destroy;
end;

procedure TClaudeChatUI.FreeThumbs;
var
  K: Integer;
begin
  for K := 0 to High(FThumbs) do
  begin
    FThumbs[K].Src.Free;
    FThumbs[K].Px.Free;
  end;
  FThumbs := nil;
  FLayKey := '';
end;

{ the copy at the drawn size (the window and the export draw at other scales); only the main thread
  calls it, while no list that holds the old copy is rendered }
function TClaudeChatUI.ScaledFor(var T: TChatThumb; PW, PH: Integer): TBGRABitmap;
begin
  PW := Max(1, PW);
  PH := Max(1, PH);
  if (T.Px = nil) or (T.Px.Width <> PW) or (T.Px.Height <> PH) then
  begin
    FreeAndNil(T.Px);
    if (T.Src.Width = PW) and (T.Src.Height = PH) then T.Px := T.Src.Duplicate as TBGRABitmap
    else T.Px := T.Src.Resample(PW, PH, rmFineResample) as TBGRABitmap;
  end;
  Result := T.Px;
end;

{ a picture in the chat: its own size up to MaxW x MaxH (design units), the shape kept }
procedure TClaudeChatUI.ThumbSize(B: TBGRABitmap; MaxW, MaxH: Single; out W, H: Single);
var
  K: Single;
begin
  K := Min(1, Min(MaxW / Max(1, B.Width), MaxH / Max(1, B.Height)));
  W := Max(4, B.Width * K);
  H := Max(4, B.Height * K);
end;

procedure TClaudeChatUI.SetDensity(V: Single);
begin
  V := EnsureRange(V, 0.75, 4);
  if V = FDensity then Exit;
  FDensity := V;
  SetSize(FW, FH);
end;

procedure TClaudeChatUI.SetSize(AW, AH: Integer);
begin
  FW := Max(16, AW);
  FH := Max(16, AH);
  FK := FDensity;
  FOX := 0;
  FOY := 0;
  FDW := FW / FK;
  FDH := FH / FK;
end;

procedure TClaudeChatUI.Update(DT: Double);
begin
  FTime := FTime + DT;
end;

procedure TClaudeChatUI.Opened;
begin
  FChatSeen := -1;
  FAutoFocus := True;
end;

procedure TClaudeChatUI.ScrollTop;
begin
  if Agent <> nil then FChatSeen := Length(Agent.Chat);
  FChatScroll := 0;
end;

function TClaudeChatUI.ButtonPoint(Id: Integer): TPointF;
var
  K: Integer;
begin
  Result := PointF(-1, -1);
  for K := FLastHitN - 1 downto 0 do
    if FLastHits[K].Id = Id then
      with FLastHits[K].R do
        Exit(DesignToPixel((Left + Right) / 2, (Top + Bottom) / 2));
end;

function TClaudeChatUI.ContentPoint(Line, Ch: Integer): TPointF;
begin
  if (Line < 0) or (Line >= FLN) then Exit(PointF(-1, -1));
  Result := DesignToPixel(FCX + XOf(Line, Ch), FOY0 + FL[Line].Y + LineH / 2);
end;

procedure TClaudeChatUI.Note(const S: string; Err: Boolean);
begin
  FNote := S;
  FNoteErr := Err;
  FNoteT := FTime;
end;

function TClaudeChatUI.LineH: Single;
begin
  Result := 18;
end;

{ ---------- asking ---------- }

procedure TClaudeChatUI.Ask(const S: string);
var
  E, K: Integer;
begin
  if (Trim(S) = '') and (Length(FFiles) = 0) then Exit;
  if (Agent = nil) or Agent.Busy then Exit;
  EndEdit(False);
  if Assigned(OnAsk) then OnAsk(S, FFiles);
  // the pictures belong to the user entry the agent just added
  E := High(Agent.Chat);
  while (E >= 0) and (Agent.Chat[E].Kind <> ckUser) do Dec(E);
  for K := 0 to High(FPend) do
    if FPend[K].Src <> nil then
    begin
      if E >= 0 then
      begin
        SetLength(FThumbs, Length(FThumbs) + 1);
        FThumbs[High(FThumbs)].Entry := E;
        FThumbs[High(FThumbs)].Src := FPend[K].Src;
        FThumbs[High(FThumbs)].Px := nil;
        FThumbs[High(FThumbs)].Name := FFiles[K].Name;
        FThumbs[High(FThumbs)].Media := FFiles[K].Media;
        FThumbs[High(FThumbs)].Data := FFiles[K].Data;
      end
      else
        FPend[K].Src.Free;
      FPend[K].Px.Free;
    end;
  FPend := nil;
  FFiles := nil;
  FAskText := '';
  FChatSeen := -1;   // scroll down
  FAutoFocus := True;
end;

function TClaudeChatUI.AttachFile(const FileName: string): Boolean;
var
  A: TChatAttachment;
  Err: string;
  Total: Int64;
  K: Integer;
begin
  Result := False;
  if Length(FFiles) >= MaxChatFiles then
  begin
    Note(Format('At most %d files per question', [MaxChatFiles]), True);
    Exit;
  end;
  if not LoadChatFile(FileName, A, Err) then
  begin
    Note(ExtractFileName(FileName) + ': ' + Err, True);
    Exit;
  end;
  Total := Length(A.Data);
  for K := 0 to High(FFiles) do Inc(Total, Length(FFiles[K].Data));
  if Total > 24 * 1024 * 1024 then
  begin
    Note('The files of one question are too big together (at most 24 MB)', True);
    Exit;
  end;
  SetLength(FFiles, Length(FFiles) + 1);
  FFiles[High(FFiles)] := A;
  SetLength(FPend, Length(FFiles));
  FPend[High(FPend)].Entry := -1;
  FPend[High(FPend)].Src := MakeThumb(A);
  FPend[High(FPend)].Px := nil;
  Note('Attached: ' + A.Name);
  Result := True;
end;

procedure TClaudeChatUI.ChooseFiles;
var
  Dl: TOpenDialog;
  K: Integer;
begin
  Dl := TOpenDialog.Create(nil);
  try
    Dl.Title := 'Attach files for Claude';
    Dl.Filter := ChatFileFilter;
    Dl.Options := [ofAllowMultiSelect, ofFileMustExist, ofEnableSizing];
    if Dl.Execute then
      for K := 0 to Dl.Files.Count - 1 do AttachFile(Dl.Files[K]);
  finally
    Dl.Free;
  end;
end;

{ ---------- the pictures: copy, save ---------- }

function TClaudeChatUI.ImagePoint(I: Integer): TPointF;
begin
  if (I < 0) or (I >= FImN) then Exit(PointF(-1, -1));
  with FImgs[I] do Result := DesignToPixel(FCX + X + W / 2, FOY0 + Y + H / 2);
end;

{ the picture as sent, onto the Windows clipboard (as a bitmap, on white: no alpha) }
function TClaudeChatUI.CopyImage(T: Integer): Boolean;
var
  M: TStringStream;
  B, Flat: TBGRABitmap;
begin
  Result := False;
  if (T < 0) or (T > High(FThumbs)) then Exit;
  M := TStringStream.Create(DecodeStringBase64(FThumbs[T].Data));
  try
    try
      B := TBGRABitmap.Create(M);
      try
        Flat := TBGRABitmap.Create(B.Width, B.Height, BGRAWhite);
        try
          Flat.PutImage(0, 0, B, dmDrawWithTransparency);
          Clipbrd.Clipboard.Assign(Flat.Bitmap);
        finally
          Flat.Free;
        end;
      finally
        B.Free;
      end;
      Note('The picture is copied');
      Result := True;
    except
      on E: Exception do Note('Copy failed: ' + E.Message, True);
    end;
  finally
    M.Free;
  end;
end;

function TClaudeChatUI.SaveImage(T: Integer; const FileName: string): Boolean;
var
  S: string;
  F: TFileStream;
begin
  Result := False;
  if (T < 0) or (T > High(FThumbs)) then Exit;
  try
    S := DecodeStringBase64(FThumbs[T].Data);
    F := TFileStream.Create(FileName, fmCreate);
    try
      if S <> '' then F.WriteBuffer(S[1], Length(S));
    finally
      F.Free;
    end;
    Note('Saved: ' + FileName);
    Result := True;
  except
    on E: Exception do Note('Save failed: ' + E.Message, True);
  end;
end;

procedure TClaudeChatUI.ChooseImageSave(T: Integer);
var
  Dl: TSaveDialog;
  Ext: string;
begin
  if (T < 0) or (T > High(FThumbs)) then Exit;
  // the format it was sent in (a BMP went as PNG)
  if FThumbs[T].Media = 'image/jpeg' then Ext := 'jpg' else Ext := 'png';
  Dl := TSaveDialog.Create(nil);
  try
    Dl.Title := 'Save the picture';
    if Ext = 'jpg' then Dl.Filter := 'JPEG picture (*.jpg)|*.jpg' else Dl.Filter := 'PNG picture (*.png)|*.png';
    Dl.DefaultExt := Ext;
    Dl.InitialDir := ExtractFilePath(ParamStr(0)) + 'export';
    ForceDirectories(Dl.InitialDir);
    Dl.FileName := ChangeFileExt(FThumbs[T].Name, '.' + Ext);
    Dl.Options := [ofOverwritePrompt, ofPathMustExist, ofEnableSizing];
    if Dl.Execute then SaveImage(T, ChangeFileExt(Dl.FileName, '.' + Ext));
  finally
    Dl.Free;
  end;
end;

{ ---------- export ---------- }

function TClaudeChatUI.DocTitle: string;
begin
  Result := 'Claude chat - Virtual PLC';
  if ProjectName <> '' then Result := Result + ' - ' + ProjectName;
end;

procedure TClaudeChatUI.ChooseExport(const Ext: string);
var
  Dl: TSaveDialog;
begin
  Dl := TSaveDialog.Create(nil);
  try
    Dl.Title := 'Export the chat';
    case Ext of
      'txt': Dl.Filter := 'Text (*.txt)|*.txt';
      'pdf': Dl.Filter := 'PDF (*.pdf)|*.pdf';
    else
      Dl.Filter := 'PNG picture (*.png)|*.png';
    end;
    Dl.DefaultExt := Ext;
    Dl.InitialDir := ExtractFilePath(ParamStr(0)) + 'export';
    ForceDirectories(Dl.InitialDir);
    Dl.FileName := 'claude_chat_' + FormatDateTime('yyyymmdd_hhnn', Now) + '.' + Ext;
    Dl.Options := [ofOverwritePrompt, ofPathMustExist, ofEnableSizing];
    if Dl.Execute then ExportTo(ChangeFileExt(Dl.FileName, '.' + Ext));
  finally
    Dl.Free;
  end;
end;

{ the conversation as one tall document (export): the title, then every line; returns the height
  in design units. Draws into DL with the scale of the picture; the window's own scale comes back }
function TClaudeChatUI.BuildDoc(DL: TDisplayList; DocW, Margin, AScale: Single): Single;
var
  SK, SOX, SOY: Single;
  Src: string;
begin
  SK := FK;
  SOX := FOX;
  SOY := FOY;
  FK := AScale;
  FOX := 0;
  FOY := 0;
  FDoc := True;
  try
    D := DL;
    DL.Clear;
    FLayKey := '';
    Layout(DocW - 2 * Margin);
    D.Layer := lyText;
    Txt(fkUIB, 16, Margin, Margin, DocTitle, cRedDark);
    ClaudeApiKey(Src);
    Txt(fkUI, 10.5, Margin, Margin + 24, Format('%s    %s    %d k in / %d k out', [FormatDateTime('yyyy-mm-dd hh:nn', Now),
      ClaudeModel, Agent.InTokens div 1000, Agent.OutTokens div 1000]), cInkSoft);
    Ln(Margin, Margin + 44, DocW - Margin, Margin + 44, 0.8, Alpha(cGoldDark, 160));
    DrawContent(Margin, Margin + 54, -1E9, 1E9, DocW - 2 * Margin);
    Result := Margin + 54 + FLayH + Margin;
  finally
    FDoc := False;
    FK := SK;
    FOX := SOX;
    FOY := SOY;
    FLayKey := '';
    FHitN := 0;   // the regions the document added are not the window's
  end;
end;

function FaceOf(K: TFontKind; out Bold: Boolean): string;
begin
  Bold := K in [fkUIB, fkMonoB, fkTitle];
  case K of
    fkMono, fkMonoB: Result := 'Consolas';
    fkTitle: Result := 'Palatino Linotype';
  else
    Result := 'Segoe UI';
  end;
end;

{ the document for the PDF: the same layout as the window, at the page's width (1 unit = 1 pt) }
function TClaudeChatUI.PdfItems(DocW, Margin: Single; out DocH: Single): TPdfItems;
var
  SK, OX, OY, CW: Single;
  N, I: Integer;
  Src: string;
  It: TPdfItems;

  function Add(Kind: TPdfItemKind; X, Y, W, H: Single; C: TBGRAPixel): Integer;
  begin
    if N >= Length(It) then SetLength(It, N * 2 + 32);
    It[N] := Default(TPdfItem);
    It[N].Kind := Kind;
    It[N].X := X;
    It[N].Y := Y;
    It[N].W := W;
    It[N].H := H;
    It[N].C := C;
    Result := N;
    Inc(N);
  end;

  procedure AddText(K: TFontKind; Size, X, Y: Single; const S: string; C: TBGRAPixel; FitW: Single);
  var
    J: Integer;
    B: Boolean;
  begin
    J := Add(piText, X, Y, FitW, Size * 1.3, C);
    It[J].Face := FaceOf(K, B);
    It[J].Bold := B;
    It[J].Size := Size;
    It[J].Text := S;
    It[J].Fit := FitW > 0;
  end;

begin
  N := 0;
  It := nil;
  SK := FK;
  // the layout at a fine scale (the widths of the words), in design units
  FK := 2;
  FDoc := True;
  try
    FLayKey := '';
    CW := DocW - 2 * Margin;
    Layout(CW);
    ClaudeApiKey(Src);
    AddText(fkUIB, 16, Margin, Margin, DocTitle, cRedDark, 0);
    AddText(fkUI, 10.5, Margin, Margin + 24, Format('%s    %s    %d k in / %d k out', [FormatDateTime('yyyy-mm-dd hh:nn', Now),
      ClaudeModel, Agent.InTokens div 1000, Agent.OutTokens div 1000]), cInkSoft, 0);
    I := Add(piLine, Margin, Margin + 44, CW, 0, Alpha(cGoldDark, 160));
    It[I].Size := 0.8;
    OX := Margin;
    OY := Margin + 54;
    for I := 0 to FRN - 1 do Add(piRect, OX + FR[I].X, OY + FR[I].Y, FR[I].W, FR[I].H, FR[I].C);
    for I := 0 to FImN - 1 do
      with FImgs[I] do
        if T <= High(FThumbs) then
        begin
          It[Add(piImage, OX + X, OY + Y, W, H, BGRAWhite)].ImgData := FThumbs[T].Data;
          It[N - 1].ImgMedia := FThumbs[T].Media;
        end;
    for I := 0 to FLN - 1 do
      AddText(FL[I].Font, FL[I].Size, OX + FL[I].X, OY + FL[I].Y, FL[I].Text, FL[I].C,
        IfThen(FL[I].Fit, CW - FL[I].X, 0));
    DocH := OY + FLayH + Margin;
  finally
    FDoc := False;
    FK := SK;
    FLayKey := '';
  end;
  SetLength(It, N);
  Result := It;
end;

function TClaudeChatUI.ExportTo(const FileName: string): Boolean;
const
  PngW = 760;
  PngScale = 1.5;
  PdfW = 595;
  PdfMargin = 40;
  MaxPx = 30000;
var
  Ext, S: string;
  F: TFileStream;
  DL: TDisplayList;
  H: Single;
  B, Band: TBGRABitmap;
  WPx, HPx, Y0, BH: Integer;
  PI: TPdfItems;
begin
  Result := False;
  if (Agent = nil) or (Length(Agent.Chat) = 0) then
  begin
    Note('The chat is empty: nothing to export', True);
    Exit;
  end;
  Ext := LowerCase(ExtractFileExt(FileName));
  try
    if Ext = '.txt' then
    begin
      S := #$EF#$BB#$BF + ChatToText(Agent, DocTitle);
      F := TFileStream.Create(FileName, fmCreate);
      try
        F.WriteBuffer(S[1], Length(S));
      finally
        F.Free;
      end;
    end
    else if Ext = '.png' then
    begin
      DL := TDisplayList.Create(FGl);
      try
        H := BuildDoc(DL, PngW, 24, PngScale);
        WPx := Round(PngW * PngScale);
        HPx := Min(MaxPx, Round(H * PngScale));
        B := TBGRABitmap.Create(WPx, HPx, cSheet);
        try
          // in bands, as the renderer does
          Y0 := 0;
          while Y0 < HPx do
          begin
            BH := Min(1024, HPx - Y0);
            Band := TBGRABitmap.Create(WPx, BH, cSheet);
            try
              DL.Render(Band, Y0, AllLayers);
              B.PutImage(0, Y0, Band, dmSet);
            finally
              Band.Free;
            end;
            Inc(Y0, BH);
          end;
          B.SaveToFile(FileName);
        finally
          B.Free;
        end;
        if Round(H * PngScale) > MaxPx then Note('The picture is cut at 30000 pixels: export PDF for all of it', True);
      finally
        DL.Free;
      end;
    end
    else if Ext = '.pdf' then
    begin
      // real text (embedded fonts, shaped by Windows) and the pictures as sent
      PI := PdfItems(PdfW, PdfMargin, H);
      WriteChatPdf(FileName, DocTitle, PI, H);
    end
    else
    begin
      Note('Export: .txt, .pdf or .png', True);
      Exit;
    end;
    Note('Exported: ' + FileName);
    Result := True;
  except
    on E: Exception do Note('Export failed: ' + E.Message, True);
  end;
end;

{ ---------- the layout of the conversation ---------- }

procedure TClaudeChatUI.AddLine(X, Y: Single; Font: TFontKind; Size: Single; const S: string; C: TBGRAPixel;
  Entry: Integer; Cont: Boolean; Fit: Boolean);
begin
  if FLN >= Length(FL) then SetLength(FL, Max(64, FLN * 2));
  FL[FLN].X := X;
  FL[FLN].Y := Y;
  FL[FLN].Font := Font;
  FL[FLN].Size := Size;
  FL[FLN].Text := S;
  FL[FLN].C := C;
  FL[FLN].Entry := Entry;
  FL[FLN].Cont := Cont;
  FL[FLN].Fit := Fit;
  Inc(FLN);
end;

procedure TClaudeChatUI.AddRect(X, Y, W, H: Single; C: TBGRAPixel);
begin
  if FRN >= Length(FR) then SetLength(FR, Max(32, FRN * 2));
  FR[FRN].X := X;
  FR[FRN].Y := Y;
  FR[FRN].W := W;
  FR[FRN].H := H;
  FR[FRN].C := C;
  Inc(FRN);
end;

{ the text broken into lines that fit the width (a long word is broken too); the object of a line
  is 1 when it continues the line before it }
procedure TClaudeChatUI.Wrap(const Txt0: string; Kind: TFontKind; Size, MaxW: Single; L: TStringList);
var
  Paras: TStringList;
  P, Q, K: Integer;
  Line, Wd: string;
  First: Boolean;

  procedure Put(const S: string);
  begin
    L.AddObject(S, TObject(PtrInt(Ord(not First))));
    First := False;
  end;

begin
  Paras := TStringList.Create;
  try
    Paras.Text := Txt0;
    for P := 0 to Paras.Count - 1 do
    begin
      Line := '';
      Wd := '';
      Q := 1;
      First := True;
      while Q <= Length(Paras[P]) + 1 do
      begin
        if (Q > Length(Paras[P])) or (Paras[P][Q] = ' ') then
        begin
          if (Line <> '') and (TxtW(Kind, Size, Line + ' ' + Wd) > MaxW) then
          begin
            Put(Line);
            Line := Wd;
          end
          else if Line = '' then Line := Wd
          else Line := Line + ' ' + Wd;
          while (TxtW(Kind, Size, Line) > MaxW) and (UTF8Length(Line) > 1) do
          begin
            // a word longer than the line
            K := UTF8Length(Line);
            while (K > 1) and (TxtW(Kind, Size, UTF8Copy(Line, 1, K)) > MaxW) do Dec(K);
            Put(UTF8Copy(Line, 1, K));
            Line := UTF8Copy(Line, K + 1, MaxInt);
          end;
          Wd := '';
        end
        else
          Wd := Wd + Paras[P][Q];
        Inc(Q);
      end;
      Put(Line);
    end;
  finally
    Paras.Free;
  end;
end;

procedure TClaudeChatUI.Layout(W: Single);
var
  Key: string;
  Y, LH: Single;
  I, K: Integer;
  E: TChatEntry;
  Lines, Fls: TStringList;
  C: TBGRAPixel;
  InCode, Cont: Boolean;
  Ln1: string;
  IX, IY, RowH, TW, TH, PicH: Single;
begin
  LH := LineH;
  Key := Format('%d|%.1f|%.3f|%d', [Length(Agent.Chat), W, FK, Length(FThumbs)]);
  if Length(Agent.Chat) > 0 then
    with Agent.Chat[High(Agent.Chat)] do Key := Key + Format('|%d|%d', [Length(Text), Length(Files)]);
  if Key = FLayKey then Exit;
  FLayKey := Key;
  FLayW := W;
  FLN := 0;
  FRN := 0;
  FImN := 0;
  Y := 0;
  // pictures of entries that are gone (another chat) go too
  for I := High(FThumbs) downto 0 do
    if FThumbs[I].Entry > High(Agent.Chat) then
    begin
      FThumbs[I].Src.Free;
      FThumbs[I].Px.Free;
      Delete(FThumbs, I, 1);
    end;
  Lines := TStringList.Create;
  Fls := TStringList.Create;
  try
    if Length(Agent.Chat) = 0 then
    begin
      Wrap('Ask Claude to write, change, explain or debug the program: "add a network to OB1 that ' +
        'starts the pump with I0.5 and stops it with I0.6", "why does the motor not start?". Claude sees ' +
        'the block you have open in the program editor, the network and what you selected; it reads and ' +
        'writes the project, compiles it, presses the simulated buttons and reads live values. Attach ' +
        'pictures, PDF or text files (or drop them on this window). Auditor, Undo changes takes back ' +
        'everything of the last request.', fkUI, 12.5, W - 8, Lines);
      for I := 0 to Lines.Count - 1 do
      begin
        AddLine(0, Y, fkUI, 12.5, Lines[I], cInkSoft, -1, Lines.Objects[I] <> nil);
        Y := Y + LH;
      end;
    end;
    for I := 0 to High(Agent.Chat) do
    begin
      E := Agent.Chat[I];
      Lines.Clear;
      case E.Kind of
        ckUser:
          begin
            if E.Text <> '' then Wrap(E.Text, fkUI, 12.5, W - 60, Lines);
            Fls.Text := E.Files;
            // the pictures: in rows under the file names
            IX := 48;
            IY := Y + 1 + Fls.Count * LH + 2;
            RowH := 0;
            for K := 0 to High(FThumbs) do
              if FThumbs[K].Entry = I then
              begin
                ThumbSize(FThumbs[K].Src, Min(260, W - 64), 180, TW, TH);
                if (IX > 48) and (IX + TW > W - 8) then
                begin
                  IY := IY + RowH + 6;
                  IX := 48;
                  RowH := 0;
                end;
                if FImN >= Length(FImgs) then SetLength(FImgs, Max(8, FImN * 2));
                FImgs[FImN].X := IX;
                FImgs[FImN].Y := IY;
                FImgs[FImN].W := TW;
                FImgs[FImN].H := TH;
                FImgs[FImN].T := K;
                Inc(FImN);
                IX := IX + TW + 6;
                RowH := Max(RowH, TH);
              end;
            PicH := 0;
            if RowH > 0 then PicH := IY + RowH + 6 - (Y + 1 + Fls.Count * LH);
            AddRect(40, Y - 2, W - 40, (Lines.Count + Fls.Count) * LH + PicH + 6, Alpha(cGoldLight, 110));
            for K := 0 to Fls.Count - 1 do
              AddLine(48, Y + 1 + K * LH, fkMono, 10.5, '■ ' + Fls[K], cInkSoft, I, False, True);
            for K := 0 to Lines.Count - 1 do
              AddLine(48, Y + 1 + (Fls.Count + K) * LH + PicH, fkUI, 12.5, Lines[K], cInk, I, Lines.Objects[K] <> nil);
            Y := Y + (Lines.Count + Fls.Count) * LH + PicH + 12;
          end;
        ckTool:
          begin
            AddLine(6, Y, fkMono, 10.5, '→ ' + E.Text, cInkSoft, I, False, True);
            Y := Y + LH + 2;
          end;
      else
        begin
          Wrap(ChatMd(E.Text), fkUI, 12.5, W - 8, Lines);
          case E.Kind of
            ckError: C := cRed;
            ckInfo: C := cJade;
          else
            C := cInk;
          end;
          InCode := False;
          for K := 0 to Lines.Count - 1 do
          begin
            Ln1 := Lines[K];
            Cont := Lines.Objects[K] <> nil;
            // a little markdown: code blocks in the mono font, **bold** without the stars, # heads
            if Copy(TrimLeft(Ln1), 1, 3) = '```' then
            begin
              InCode := not InCode;
              Y := Y + 4;
              Continue;
            end;
            if InCode then
            begin
              AddRect(0, Y - 1, W, LH, Alpha(cSheet2, 200));
              AddLine(6, Y + 1, fkMono, 11, Ln1, cRedDark, I, Cont);
            end
            else if Copy(Ln1, 1, 1) = '#' then
              AddLine(0, Y, fkUIB, 13, Trim(StringReplace(Ln1, '#', '', [rfReplaceAll])), C, I, Cont)
            else
              AddLine(0, Y, fkUI, 12.5, StringReplace(Ln1, '**', '', [rfReplaceAll]), C, I, Cont);
            Y := Y + LH;
          end;
          Y := Y + 12;
        end;
      end;
    end;
  finally
    Lines.Free;
    Fls.Free;
  end;
  FLayH := Y;
  // a selection past the new end shrinks
  if FSel0.Y >= FLN then FSel0 := Point(0, 0);
  if FSel1.Y >= FLN then FSel1 := FSel0;
end;

function TClaudeChatUI.XOf(Li, K: Integer): Single;
begin
  if K <= 0 then Exit(FL[Li].X);
  Result := FL[Li].X + TxtW(FL[Li].Font, FL[Li].Size, UTF8Copy(FL[Li].Text, 1, K));
end;

procedure TClaudeChatUI.SelOrdered(out A, B: TPoint);
begin
  if PtLess(FSel1, FSel0) then
  begin
    A := FSel1;
    B := FSel0;
  end
  else
  begin
    A := FSel0;
    B := FSel1;
  end;
end;

function TClaudeChatUI.HasSel: Boolean;
begin
  Result := (FSel0.X <> FSel1.X) or (FSel0.Y <> FSel1.Y);
end;

{ the content is drawn at OX, OY (window or document design units); only the lines in the clip }
procedure TClaudeChatUI.DrawContent(OX, OY, ClipTop, ClipBot, W: Single);
var
  I, C0, C1, N: Integer;
  A, B: TPoint;
  X0, X1, LH, Y: Single;
  Sel: Boolean;
begin
  LH := LineH;
  D.Layer := lyText;
  for I := 0 to FRN - 1 do
    if (OY + FR[I].Y + FR[I].H >= ClipTop) and (OY + FR[I].Y <= ClipBot) then
      Rc(OX + FR[I].X, OY + FR[I].Y, FR[I].W, FR[I].H, FR[I].C);
  for I := 0 to FImN - 1 do
    with FImgs[I] do
      if (OY + Y + H >= ClipTop) and (OY + Y <= ClipBot) and (T <= High(FThumbs)) then
      begin
        Rc(OX + X - 1, OY + Y - 1, W + 2, H + 2, Alpha(cGoldDark, 120));
        ImgD(OX + X, OY + Y, W, H, ScaledFor(FThumbs[T], Round(PS(W)), Round(PS(H))));
        // the right button on a picture: Copy, Save As (a left click does nothing, no text selection)
        if not FDoc and (OY + Y < ClipBot) and (OY + Y + H > ClipTop) then
          Hit(OX + X, Max(ClipTop, OY + Y), W, Min(ClipBot, OY + Y + H) - Max(ClipTop, OY + Y), ciImg + T);
      end;
  Sel := HasSel and not FDoc;
  SelOrdered(A, B);
  for I := 0 to FLN - 1 do
  begin
    Y := OY + FL[I].Y;
    if (Y + LH < ClipTop) or (Y > ClipBot) then Continue;
    if Sel and (I >= A.Y) and (I <= B.Y) then
    begin
      N := UTF8Length(FL[I].Text);
      if I = A.Y then C0 := A.X else C0 := 0;
      if I = B.Y then C1 := B.X else C1 := N;
      X0 := XOf(I, C0);
      X1 := XOf(I, Min(C1, N));
      if I < B.Y then X1 := X1 + 4;   // the line break is selected too
      if X1 > X0 then Rc(OX + X0, Y - 2, X1 - X0, LH, Alpha(cGold, 120));
    end;
    if FL[I].Fit then TxtFit(FL[I].Font, FL[I].Size, OX + FL[I].X, Y, W - FL[I].X, FL[I].Text, FL[I].C)
    else Txt(FL[I].Font, FL[I].Size, OX + FL[I].X, Y, FL[I].Text, FL[I].C);
  end;
end;

{ ---------- the selection ---------- }

function TClaudeChatUI.PosAt(MX, MY: Single): TPoint;
var
  CY, RX, Prev, Wd: Single;
  I, Li, K, N: Integer;
begin
  Result := Point(0, 0);
  if FLN = 0 then Exit;
  CY := MY - FOY0;
  if CY < FL[0].Y - 2 then Exit(Point(0, 0));
  Li := FLN - 1;
  for I := 0 to FLN - 1 do
    if FL[I].Y - 2 > CY then
    begin
      Li := Max(0, I - 1);
      Break;
    end;
  // below the last line, or between messages: the end of the line above
  if CY > FL[Li].Y + LineH + 2 then Exit(Point(UTF8Length(FL[Li].Text), Li));
  RX := MX - FCX;
  N := UTF8Length(FL[Li].Text);
  if RX <= FL[Li].X then Exit(Point(0, Li));
  Prev := FL[Li].X;
  for K := 1 to N do
  begin
    Wd := XOf(Li, K);
    if (Prev + Wd) / 2 > RX then Exit(Point(K - 1, Li));
    Prev := Wd;
  end;
  Result := Point(N, Li);
end;

function TClaudeChatUI.WordAt(P: TPoint; out A, B: TPoint): Boolean;
var
  S: string;
  I0, I1, N: Integer;

  function IsSpace(K: Integer): Boolean;
  begin
    Result := UTF8Copy(S, K + 1, 1) = ' ';
  end;

begin
  Result := (P.Y >= 0) and (P.Y < FLN);
  if not Result then Exit;
  S := FL[P.Y].Text;
  N := UTF8Length(S);
  I0 := Min(P.X, N);
  I1 := I0;
  if (I0 < N) and IsSpace(I0) then
  begin
    A := Point(I0, P.Y);
    B := Point(I0 + 1, P.Y);
    Exit;
  end;
  while (I0 > 0) and not IsSpace(I0 - 1) do Dec(I0);
  while (I1 < N) and not IsSpace(I1) do Inc(I1);
  A := Point(I0, P.Y);
  B := Point(I1, P.Y);
end;

function TClaudeChatUI.EntryRange(E: Integer; out A, B: TPoint): Boolean;
var
  I, I0, I1: Integer;
begin
  I0 := -1;
  I1 := -1;
  for I := 0 to FLN - 1 do
    if FL[I].Entry = E then
    begin
      if I0 < 0 then I0 := I;
      I1 := I;
    end;
  Result := I0 >= 0;
  if not Result then Exit;
  A := Point(0, I0);
  B := Point(UTF8Length(FL[I1].Text), I1);
end;

procedure TClaudeChatUI.SelectAll;
begin
  if FLN = 0 then Exit;
  FSel0 := Point(0, 0);
  FSel1 := Point(UTF8Length(FL[FLN - 1].Text), FLN - 1);
end;

function TClaudeChatUI.SelText: string;
var
  A, B: TPoint;
  I, C0, C1: Integer;
begin
  Result := '';
  if not HasSel then Exit;
  SelOrdered(A, B);
  for I := A.Y to Min(B.Y, FLN - 1) do
  begin
    if I = A.Y then C0 := A.X else C0 := 0;
    if I = B.Y then C1 := B.X else C1 := UTF8Length(FL[I].Text);
    if I > A.Y then
    begin
      if FL[I].Entry <> FL[I - 1].Entry then Result := Result + LineEnding + LineEnding
      else if FL[I].Cont then Result := Result + ' '
      else Result := Result + LineEnding;
    end;
    Result := Result + UTF8Copy(FL[I].Text, C0 + 1, C1 - C0);
  end;
end;

procedure TClaudeChatUI.CopySel;
begin
  if not HasSel then Exit;
  ClipboardOut := SelText;
  Note('Copied');
end;

procedure TClaudeChatUI.DoDrag(Id: Integer; X, Y: Single; const R: TRectF);
var
  P, A, B: TPoint;
begin
  if Id <> ciText then Exit;
  // past the top or the bottom: scroll along
  if Y < FConvTop then FChatScroll := FChatScroll - 14
  else if Y > FConvBot then FChatScroll := FChatScroll + 14;
  P := PosAt(X, Y);
  if FPressNo <> FDragPress then
  begin
    // a new press: a click places, a double click takes the word, a triple click the message
    FDragPress := FPressNo;
    FAutoFocus := False;
    FMenu := 0;
    FDragMode := 1;
    if (MouseClicks >= 3) and (P.Y < FLN) and EntryRange(FL[P.Y].Entry, A, B) then FDragMode := 3
    else if (MouseClicks = 2) and WordAt(P, A, B) then FDragMode := 2;
    if FDragMode = 1 then
    begin
      if umShift in MouseMods then FSel1 := P
      else
      begin
        FSel0 := P;
        FSel1 := P;
      end;
    end
    else
    begin
      FDragW0 := A;
      FDragW1 := B;
      FSel0 := A;
      FSel1 := B;
    end;
    Exit;
  end;
  case FDragMode of
    2, 3:
      begin
        // grow by words / messages from the one that was clicked
        if FDragMode = 2 then WordAt(P, A, B)
        else if (P.Y < FLN) then EntryRange(FL[P.Y].Entry, A, B)
        else Exit;
        if PtLess(A, FDragW0) then
        begin
          FSel0 := FDragW1;
          FSel1 := A;
        end
        else
        begin
          FSel0 := FDragW0;
          if PtLess(FDragW1, B) then FSel1 := B else FSel1 := FDragW1;
        end;
      end;
  else
    FSel1 := P;
  end;
end;

{ ---------- events ---------- }

procedure TClaudeChatUI.DoClick(Id: Integer; const S: string);
var
  A, B: TPoint;
  I: Integer;
begin
  if Agent = nil then Exit;
  if (Id <> ciMenuAud) and (Id <> ciMenuExp) then FMenu := 0;
  case Id of
    ciNew:
      begin
        Agent.NewChat;
        FreeThumbs;
        for I := 0 to High(FPend) do
        begin
          FPend[I].Src.Free;
          FPend[I].Px.Free;
        end;
        FPend := nil;
        FFiles := nil;
        FSel0 := Point(0, 0);
        FSel1 := FSel0;
        Note('A new chat');
      end;
    ciMenuAud: if FMenu = 1 then FMenu := 0 else FMenu := 1;
    ciMenuExp: if FMenu = 2 then FMenu := 0 else FMenu := 2;
    ciMenuClose: ;
    ciUndo:
      if Agent.CanUndo then
      begin
        Agent.UndoChanges;
        Note('Claude''s changes of the last request are undone');
      end;
    ciExpTxt: ChooseExport('txt');
    ciExpPdf: ChooseExport('pdf');
    ciExpPng: ChooseExport('png');
    ciCopy: CopySel;
    ciCopyMsg:
      if (FCtxEntry >= 0) and (FCtxEntry <= High(Agent.Chat)) then
      begin
        ClipboardOut := Agent.Chat[FCtxEntry].Text;
        if EntryRange(FCtxEntry, A, B) then
        begin
          FSel0 := A;
          FSel1 := B;
        end;
        Note('The message is copied');
      end;
    ciSelAll: SelectAll;
    ciImgCopy: CopyImage(FCtxImg);
    ciImgSave: ChooseImageSave(FCtxImg);
    ciSend: Ask(FAskText);
    ciStop: Agent.Cancel;
    ciAllow: Agent.Confirm(True);
    ciDeny: Agent.Confirm(False);
    ciKey: if Assigned(OnKeyDialog) then OnKeyDialog(Self);
    ciAttach: ChooseFiles;
    ciQuick + 0: Ask('Fix the compile errors.');
    ciQuick + 1: Ask('Explain what the network I have open does, step by step.');
    ciQuick + 2: Ask('Debug the network I have open: it does not do what I expect. Read the live values, ' +
      'find out why, and tell me what to change (or change it).');
    ciBg: FAutoFocus := False;
  else
    if (Id >= ciChipDel) and (Id < ciChipDel + MaxChatFiles) and (Id - ciChipDel <= High(FFiles)) then
    begin
      I := Id - ciChipDel;
      if I <= High(FPend) then
      begin
        FPend[I].Src.Free;
        FPend[I].Px.Free;
        Delete(FPend, I, 1);
      end;
      Delete(FFiles, I, 1);
    end;
  end;
end;

procedure TClaudeChatUI.DoRightClick(Id: Integer);
var
  P: TPoint;
begin
  FMenu := 0;
  if Agent = nil then Exit;
  if (Id >= ciImg) and (Id - ciImg <= High(FThumbs)) then
  begin
    FCtxImg := Id - ciImg;
    FMenu := 4;
    FMenuX := FMX;
    FMenuY := FMY;
    Exit;
  end;
  if Id <> ciText then Exit;
  P := PosAt(FMX, FMY);
  FCtxEntry := -1;
  if (P.Y < FLN) then FCtxEntry := FL[P.Y].Entry;
  FMenu := 3;
  FMenuX := FMX;
  FMenuY := FMY;
end;

procedure TClaudeChatUI.DoWheel(Id: Integer; DY: Single);
begin
  if Id = ciWheel then FChatScroll := FChatScroll - DY * 50;
end;

procedure TClaudeChatUI.DoKey(Key: TUiKey; Ch: Char; Mods: TUiMods);
begin
  case Key of
    ukPgUp: FChatScroll := FChatScroll - 300;
    ukPgDn: FChatScroll := FChatScroll + 300;
    ukHome: if umCtrl in Mods then FChatScroll := 0;
    ukEnd: if umCtrl in Mods then FChatSeen := -1;
    ukEnter: FAutoFocus := True;
    ukEsc:
      begin
        if FMenu <> 0 then FMenu := 0
        else FSel1 := FSel0;
      end;
    ukChar:
      if umCtrl in Mods then
        case UpCase(Ch) of
          'A': SelectAll;
          'C': CopySel;
        end;
  end;
end;

procedure TClaudeChatUI.DoText(const S: string);
begin
  // typing while nothing is edited goes into the question
  if (Agent = nil) or Agent.Busy or (FMenu <> 0) then Exit;
  FAutoFocus := True;
  StartEdit(ciAsk, FAskText);
  TextInput(S);
end;

procedure TClaudeChatUI.KeyDown(Key: TUiKey; Ch: Char; Mods: TUiMods);
begin
  // Ctrl+C with selected chat text copies that, also while the question field has the keys
  if (Key = ukChar) and (umCtrl in Mods) and (UpCase(Ch) = 'C') and HasSel then
  begin
    CopySel;
    Exit;
  end;
  if (Key = ukEsc) and (FMenu <> 0) then
  begin
    FMenu := 0;
    Exit;
  end;
  FEnter := Key = ukEnter;
  try
    inherited KeyDown(Key, Ch, Mods);
  finally
    FEnter := False;
  end;
end;

procedure TClaudeChatUI.CommitEdit(Id: Integer; const S: string);
begin
  if Id = ciAsk then
  begin
    FAskText := S;
    if FEnter then Ask(S);   // Enter sends; a click elsewhere keeps the text
  end;
end;

{ ---------- drawing ---------- }

procedure TClaudeChatUI.DrawMenuBar;
const
  Names: array[0..2] of string = ('New chat', 'Auditor ▼', 'Export ▼');
  Ids: array[0..2] of Integer = (ciNew, ciMenuAud, ciMenuExp);
var
  I: Integer;
  X, Wd: Single;
  Hov, Open: Boolean;
begin
  X := FDW - 10;
  for I := 2 downto 0 do
  begin
    Wd := TxtW(fkUIB, 11.5, Names[I]) + 20;
    X := X - Wd;
    Open := ((I = 1) and (FMenu = 1)) or ((I = 2) and (FMenu = 2));
    Hov := Hot(X, 8, Wd, 24);
    if Open or Hov then RR(X, 8, Wd, 24, 4, PickC(Open, cSheet, cRedDark));
    Txt(fkUIB, 11.5, X + 10, 12, Names[I], PickC(Open, cRedDark, cSheet));
    Hit(X, 8, Wd, 24, Ids[I]);
    X := X - 4;
  end;
end;

procedure TClaudeChatUI.DrawDrop;
var
  Names: array of string;
  Ids: array of Integer;
  On: array of Boolean;
  Keys: array of string;
  X, Y, W, IY: Single;
  I: Integer;
  Hov: Boolean;
begin
  case FMenu of
    1:
      begin
        Names := ['Undo changes'];
        Ids := [ciUndo];
        On := [Agent.CanUndo];
        Keys := [''];
        X := FDW - 10 - TxtW(fkUIB, 11.5, 'Export ▼') - 24 - TxtW(fkUIB, 11.5, 'Auditor ▼') - 20;
        Y := 36;
      end;
    2:
      begin
        Names := ['Export as TXT ...', 'Export as PDF ...', 'Export as PNG ...'];
        Ids := [ciExpTxt, ciExpPdf, ciExpPng];
        On := [Length(Agent.Chat) > 0, Length(Agent.Chat) > 0, Length(Agent.Chat) > 0];
        Keys := ['', '', ''];
        X := FDW - 10 - TxtW(fkUIB, 11.5, 'Export ▼') - 20;
        Y := 36;
      end;
    3:
      begin
        Names := ['Copy', 'Copy message', 'Select all'];
        Ids := [ciCopy, ciCopyMsg, ciSelAll];
        On := [HasSel, FCtxEntry >= 0, FLN > 0];
        Keys := ['Ctrl+C', '', 'Ctrl+A'];
        X := FMenuX;
        Y := FMenuY;
      end;
    4:
      begin
        Names := ['Copy', 'Save As ...'];
        Ids := [ciImgCopy, ciImgSave];
        On := [FCtxImg <= High(FThumbs), FCtxImg <= High(FThumbs)];
        Keys := ['', ''];
        X := FMenuX;
        Y := FMenuY;
      end;
  else
    Exit;
  end;
  W := 190;
  X := Min(X, FDW - W - 6);
  Y := Min(Y, FDH - Length(Names) * 28 - 14);
  Hit(-100, -100, FDW + 200, FDH + 200, ciMenuClose);
  D.Layer := lyOverlay;
  Shad(X, Y, W, Length(Names) * 28 + 8, 5, 3, 6, 110);
  RR(X, Y, W, Length(Names) * 28 + 8, 5, cSheet);
  RRL(X, Y, W, Length(Names) * 28 + 8, 5, 1.3, cGoldDark);
  for I := 0 to High(Names) do
  begin
    IY := Y + 4 + I * 28;
    Hov := On[I] and Hot(X + 4, IY, W - 8, 26);
    if Hov then RR(X + 4, IY, W - 8, 26, 4, cRed);
    if On[I] then Txt(fkUI, 12, X + 14, IY + 4, Names[I], PickC(Hov, cSheet, cInk))
    else Txt(fkUI, 12, X + 14, IY + 4, Names[I], cInkFaint);
    if Keys[I] <> '' then Txt(fkMono, 10, X + W - 12, IY + 6, Keys[I], PickC(Hov, cGoldLight, cInkFaint), 2);
    if On[I] then Hit(X + 4, IY, W - 8, 26, Ids[I]);
  end;
end;

procedure TClaudeChatUI.DrawFooter;
const
  Quick: array[0..2] of string = ('Fix the errors', 'Explain this network', 'Debug (live values)');
var
  X, W, Y, BW, CX, CW, PX0, TW, TH: Single;
  I: Integer;
  Src, Lb: string;
  HasPic: Boolean;
begin
  X := 14;
  W := FDW - 28;
  D.Layer := lyText;
  Y := FDH - 104;
  // the files for the next question
  if Length(FFiles) > 0 then
  begin
    CX := X;
    for I := 0 to High(FFiles) do
    begin
      Lb := FFiles[I].Name;
      HasPic := (I <= High(FPend)) and (FPend[I].Src <> nil);
      CW := Min(TxtW(fkUI, 11, Lb) + 34 + IfThen(HasPic, 22, 0), 220);
      if CX + CW > X + W then Break;
      RR(CX, Y - 30, CW, 22, 11, Alpha(cGoldLight, 160));
      RRL(CX, Y - 30, CW, 22, 11, 0.8, cGoldDark);
      PX0 := CX + 10;
      if HasPic then
      begin
        ThumbSize(FPend[I].Src, 26, 16, TW, TH);
        ImgD(CX + 6 + (26 - TW) / 2, Y - 27 + (16 - TH) / 2, TW, TH, ScaledFor(FPend[I], Round(PS(TW)), Round(PS(TH))));
        PX0 := CX + 36;
      end;
      TxtFit(fkUI, 11, PX0, Y - 27, CW - (PX0 - CX) - 22, Lb, cInk);
      if Hot(CX + CW - 22, Y - 30, 20, 22) then El(CX + CW - 12, Y - 19, 8, 8, cRed);
      Txt(fkUIB, 11, CX + CW - 12, Y - 27, '×', PickC(Hot(CX + CW - 22, Y - 30, 20, 22), cSheet, cRedDark), 1);
      Hit(CX + CW - 22, Y - 30, 20, 22, ciChipDel + I);
      CX := CX + CW + 6;
    end;
  end;
  Ln(X, Y - 4, X + W, Y - 4, 0.8, Alpha(cGoldDark, 140));
  BW := (W - 12) / 3;
  for I := 0 to 2 do
    Button(X + I * (BW + 6), Y + 2, BW, 24, Quick[I], ciQuick + I, bsNormal, not Agent.Busy, 11);
  Button(X, Y + 34, 76, 30, 'Attach ...', ciAttach, bsGold, True, 11.5);
  if FAutoFocus and not Agent.Busy and not Editing and (FMenu = 0) then StartEdit(ciAsk, FAskText);
  Field(X + 82, Y + 34, W - 82 - 74, 30, ciAsk, FAskText, fkUI, 12.5, 0, not Agent.Busy, 'Ask Claude ... (Enter)');
  Button(X + W - 66, Y + 34, 66, 30, 'Send', ciSend, bsPrimary, not Agent.Busy, 12);
  if (FNote <> '') and (FTime - FNoteT < 6) then
    TxtFit(fkUI, 10, X, Y + 72, W, FNote, PickC(FNoteErr, cRed, cJade))
  else
  begin
    ClaudeApiKey(Src);
    TxtFit(fkUI, 9.5, X, Y + 72, W, 'key: ' + Src + '.  Claude can make mistakes: check its changes.', cInkFaint);
  end;
end;

procedure TClaudeChatUI.Build(DL: TDisplayList);
var
  Y, Top, Bot, X, W, MaxS: Single;
  I: Integer;
  Lines: TStringList;
begin
  BeginFrame(DL);
  try
    D.Layer := lySheets;
    Rc(0, 0, FDW, FDH, cSheet);
    Hit(0, 0, FDW, FDH, ciBg);
    if Agent = nil then Exit;
    // ---------- the head with the menu bar ----------
    D.Layer := lyControls;
    Rc(0, 0, FDW, 40, Mixc(cRed, cRedDark, 0.3));
    FretStrip(0, 40, FDW, 8, cGoldLight, cRedDark);
    D.Layer := lyText;
    Txt(fkUIB, 15, 14, 10, 'Claude', cSheet);
    TxtFit(fkUI, 10.5, 82, 14, Max(10, FDW - 82 - 280), ClaudeModel + Format('   %d k in / %d k out',
      [Agent.InTokens div 1000, Agent.OutTokens div 1000]), cGoldLight);
    DrawMenuBar;
    X := 14;
    W := FDW - 28;
    D.Layer := lyText;
    // ---------- no key yet ----------
    if not Agent.HasKey then
    begin
      Y := 66;
      Lines := TStringList.Create;
      try
        Wrap('Claude needs an Anthropic API key (console.anthropic.com). Set it in the main window: ' +
          'Program editor, AI menu, Set ANTHROPIC_API_KEY. The key stays with this Windows user, ' +
          'never in a project file. Requests are billed to that key.', fkUI, 12.5, W, Lines);
        for I := 0 to Lines.Count - 1 do
        begin
          Txt(fkUI, 12.5, X, Y, Lines[I], cInk);
          Y := Y + 19;
        end;
      finally
        Lines.Free;
      end;
      Button(X, Y + 12, 200, 30, 'Set ANTHROPIC_API_KEY ...', ciKey, bsPrimary, True, 12);
      DrawDrop;
      Exit;
    end;
    // ---------- the conversation ----------
    Top := 52;
    Bot := FDH - 112 - IfThen(Length(FFiles) > 0, 30, 0);
    if Agent.State = asConfirm then Bot := Bot - 64
    else if Agent.Busy then Bot := Bot - 30;
    Bot := Max(Bot, Top + 40);
    Layout(W - 4);
    if FChatSeen <> Length(Agent.Chat) then
    begin
      FChatScroll := Max(0, FLayH - (Bot - Top) + 8);
      FChatSeen := Length(Agent.Chat);
    end;
    MaxS := Max(0, FLayH - (Bot - Top) + 8);
    FChatScroll := EnsureRange(FChatScroll, 0, MaxS);
    FCX := X;
    FOY0 := Top + 4 - FChatScroll;
    FConvTop := Top;
    FConvBot := Bot;
    Hit(0, Top, FDW, Bot - Top, ciWheel, hkWheel);
    Hit(0, Top, FDW - 10, Bot - Top, ciText, hkDrag);
    ClipD(2, Top, FDW - 4, Bot - Top);
    DrawContent(FCX, FOY0, Top, Bot, W - 4);
    UnclipD;
    // the scroll bar
    if FLayH > Bot - Top then
    begin
      D.Layer := lyControls;
      RR(FDW - 7, Top, 4, Bot - Top, 2, Alpha(cSheetDark, 200));
      RR(FDW - 7, Top + FChatScroll / (FLayH + 8) * (Bot - Top), 4,
        Max(20, (Bot - Top) * (Bot - Top) / (FLayH + 8)), 2, cRed);
    end;
    // ---------- working / asking ----------
    D.Layer := lyText;
    Y := Bot + 6;
    if Agent.State = asConfirm then
    begin
      RR(X, Y, W, 58, 4, Alpha(cAmber, 70));
      TxtFit(fkUIB, 12, X + 10, Y + 6, W - 20, Agent.ConfirmText, cInk);
      Button(X + 10, Y + 28, 100, 24, 'Allow', ciAllow, bsPrimary, True, 11.5);
      Button(X + 118, Y + 28, 100, 24, 'Deny', ciDeny, bsNormal, True, 11.5);
    end
    else if Agent.Busy then
    begin
      Txt(fkUIB, 12, X, Y + 4, Format('Claude is working ... %d s', [Round(Agent.WaitSeconds)]), cRedDark);
      Button(X + W - 70, Y, 70, 24, 'Stop', ciStop, bsNormal, True, 11);
    end;
    DrawFooter;
    DrawDrop;
  finally
    EndFrame;
  end;
end;

end.
