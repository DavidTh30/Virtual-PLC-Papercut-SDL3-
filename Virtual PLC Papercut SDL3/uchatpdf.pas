unit uChatPdf;

{ The chat as a real PDF: the text is text (selectable, searchable, copyable), the pictures are
  pictures.

  Text   every line is shaped by Windows (Uniscribe: ScriptItemize / ScriptShape / ScriptPlace), so
         Thai vowels and tone marks sit where they belong, and drawn glyph by glyph from the
         TrueType fonts themselves, embedded whole (Type0 / CIDFontType2, Identity-H). A character
         the line's font has not got takes another font: Thai Leelawadee UI, symbols Segoe UI
         Symbol, emoji Segoe UI Emoji. A ToUnicode map gives every glyph its characters back (copy,
         search). The font of a line is a face + bold; its size is in points (1 design unit = 1 pt).
  Pictures  a JPEG goes in as it is (DCTDecode), anything else as lossless RGB (Flate) with its
         alpha as a soft mask.
  Pages  A4; the page breaks fall between lines and never through a picture.

  Windows only (GDI, usp10.dll), main thread. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, Types, Windows, base64, zstream, BGRABitmap, BGRABitmapTypes, LazUTF8;

type
  TPdfItemKind = (piText, piRect, piLine, piImage);
  TPdfItem = record
    Kind: TPdfItemKind;
    X, Y, W, H: Single;   // design units = points, y down; a line: X, Y to X + W, Y + H
    Face: string;
    Bold: Boolean;
    Size: Single;         // text: the em size in points; a line: its width
    Text: string;         // UTF-8
    C: TBGRAPixel;        // its alpha is mixed with the white page
    Fit: Boolean;         // text: shortened with '…' to W
    ImgData, ImgMedia: string;   // a picture: base64 and image/png | image/jpeg
  end;
  TPdfItems = array of TPdfItem;

{ DocH: the height of the whole document (design units); the first page starts at 0 (its top
  margin is in the items), the others get Margin above }
procedure WriteChatPdf(const FileName, Title: string; const Items: TPdfItems; DocH: Single;
  PageW: Single = 595.28; PageH: Single = 841.89; Margin: Single = 40);

implementation

{ ---------- Uniscribe ---------- }

type
  TScriptAnalysis = record
    Bits: Word;         // eScript:10, fRTL, fLayoutRTL, fLinkBefore, fLinkAfter, fLogicalOrder, fNoGlyphIndex
    State: Word;
  end;
  PScriptAnalysis = ^TScriptAnalysis;
  TScriptItem = record
    iCharPos: Integer;
    a: TScriptAnalysis;
  end;
  PScriptItem = ^TScriptItem;
  TGOffset = record
    du, dv: LongInt;
  end;
  PGOffset = ^TGOffset;
  TAbcW = record
    A: Integer;
    B: Cardinal;
    C: Integer;
  end;

function ScriptItemize(pwcInChars: PWideChar; cInChars, cMaxItems: Integer; psControl, psState: Pointer;
  pItems: PScriptItem; pcItems: PInteger): HRESULT; stdcall; external 'usp10.dll';
function ScriptShape(dc: HDC; psc: PPointer; pwcChars: PWideChar; cChars, cMaxGlyphs: Integer;
  psa: PScriptAnalysis; pwOutGlyphs, pwLogClust: PWord; psva: PWord; pcGlyphs: PInteger): HRESULT; stdcall;
  external 'usp10.dll';
function ScriptPlace(dc: HDC; psc: PPointer; pwGlyphs: PWord; cGlyphs: Integer; psva: PWord; psa: PScriptAnalysis;
  piAdvance: PInteger; pGoffset: PGOffset; pABC: Pointer): HRESULT; stdcall; external 'usp10.dll';
function ScriptFreeCache(psc: PPointer): HRESULT; stdcall; external 'usp10.dll';
function GetGlyphIndicesW(dc: HDC; lpstr: PWideChar; c: Integer; pgi: PWord; fl: DWORD): DWORD; stdcall;
  external 'gdi32.dll';

const
  GGI_MARK_NONEXISTING_GLYPHS = 1;

function IfThenInt(B: Boolean; T, F: Integer): Integer;
begin
  if B then Result := T else Result := F;
end;

function IfThenStr(B: Boolean; const T, F: string): string;
begin
  if B then Result := T else Result := F;
end;

const
  Em = 1000;   // the fonts are made 1000 pixels high: Uniscribe's numbers are the PDF's glyph units
  E_OUTOFMEMORY_ = HRESULT($8007000E);

type
  { one embedded font }
  TPdfFont = class
    Face: string;
    Bold: Boolean;
    Font: HFONT;
    Cache: Pointer;
    Ascent, Descent, CapH: Integer;
    BBox: TRect;
    Widths: array of Integer;          // per glyph, -1 = not used
    ToUni: array of UnicodeString;     // per glyph: its characters
    Used: Boolean;
    No: Integer;                       // /F<No>
    ObjType0: Integer;
    FileData: string;
  end;

  { TPdfWriter }

  TPdfWriter = class
  private
    FDC: HDC;
    FFonts: TList;
    FOut: TFileStream;
    FOffs: array of Int64;
    FNextObj: Integer;
    function GetFont(const Face: string; Bold: Boolean): TPdfFont;
    function HasGlyph(F: TPdfFont; Ch: WideChar): Boolean;
    function FontFor(const Face: string; Bold: Boolean; const U: UnicodeString; I: Integer): TPdfFont;
    function RunWidth(F: TPdfFont; const U: UnicodeString; Size: Single): Single;
    function MapCluster(F: TPdfFont; const Chars: UnicodeString; const Gs: array of Word): Boolean;
    procedure ShapeRun(F: TPdfFont; const U: UnicodeString; Size, X, Y: Single; Content: TStringBuilder;
      var PenX: Single; Emit: Boolean);
    function TextWidth(const Face: string; Bold: Boolean; const U: UnicodeString; Size: Single): Single;
    procedure DrawText(const It: TPdfItem; X, Y: Single; Content: TStringBuilder);
    procedure W(const S: string);
    function NewObj: Integer;
    procedure BeginObj(No: Integer);
    procedure StreamObj(No: Integer; const Dict, Data: string; Compress: Boolean);
    procedure WriteFont(F: TPdfFont);
  public
    constructor Create;
    destructor Destroy; override;
    procedure Write(const FileName, Title: string; const Items: TPdfItems; DocH, PageW, PageH, Margin: Single);
  end;

function Num(V: Double): string;
begin
  Result := FormatFloat('0.###', V);
  Result := StringReplace(Result, ',', '.', []);
  if Result = '-0' then Result := '0';
end;

function Deflate(const S: string): string;
var
  M: TStringStream;
  Z: TCompressionStream;
begin
  M := TStringStream.Create('');
  try
    Z := TCompressionStream.Create(clDefault, M);
    try
      if S <> '' then Z.WriteBuffer(S[1], Length(S));
    finally
      Z.Free;
    end;
    Result := M.DataString;
  finally
    M.Free;
  end;
end;

function Hex4(V: Integer): string; inline;
begin
  Result := IntToHex(V and $FFFF, 4);
end;

{ a PDF text string: UTF-16BE with a BOM, as hex }
function PdfText(const S: string): string;
var
  U: UnicodeString;
  K: Integer;
begin
  U := UTF8Decode(S);
  Result := '<FEFF';
  for K := 1 to Length(U) do Result := Result + Hex4(Ord(U[K]));
  Result := Result + '>';
end;

function RGBOnWhite(C: TBGRAPixel): string;
var
  A: Single;
begin
  A := C.alpha / 255;
  Result := Num((C.red * A + 255 * (1 - A)) / 255) + ' ' + Num((C.green * A + 255 * (1 - A)) / 255) + ' ' +
    Num((C.blue * A + 255 * (1 - A)) / 255);
end;

function IsThai(Ch: WideChar): Boolean; inline;
begin
  Result := (Ord(Ch) >= $0E00) and (Ord(Ch) <= $0E7F);
end;

{ TPdfWriter }

constructor TPdfWriter.Create;
begin
  inherited Create;
  FDC := CreateCompatibleDC(0);
  FFonts := TList.Create;
end;

destructor TPdfWriter.Destroy;
var
  K: Integer;
  F: TPdfFont;
begin
  for K := 0 to FFonts.Count - 1 do
  begin
    F := TPdfFont(FFonts[K]);
    ScriptFreeCache(@F.Cache);
    DeleteObject(F.Font);
    F.Free;
  end;
  FFonts.Free;
  DeleteDC(FDC);
  inherited Destroy;
end;

function TPdfWriter.GetFont(const Face: string; Bold: Boolean): TPdfFont;
var
  K: Integer;
  OTM: POutlineTextMetricW;
  Sz: DWORD;
  WF: UnicodeString;
begin
  for K := 0 to FFonts.Count - 1 do
  begin
    Result := TPdfFont(FFonts[K]);
    if SameText(Result.Face, Face) and (Result.Bold = Bold) then Exit;
  end;
  Result := TPdfFont.Create;
  Result.Face := Face;
  Result.Bold := Bold;
  WF := UTF8Decode(Face);
  Result.Font := CreateFontW(-Em, 0, 0, 0, IfThenInt(Bold, FW_BOLD, FW_NORMAL), 0, 0, 0, DEFAULT_CHARSET,
    OUT_TT_ONLY_PRECIS, CLIP_DEFAULT_PRECIS, ANTIALIASED_QUALITY, DEFAULT_PITCH, PWideChar(WF));
  SetLength(Result.Widths, 65536);
  for K := 0 to High(Result.Widths) do Result.Widths[K] := -1;
  SetLength(Result.ToUni, 65536);
  SelectObject(FDC, Result.Font);
  Result.Ascent := 800;
  Result.Descent := -200;
  Result.CapH := 700;
  Result.BBox := Types.Rect(-200, -250, 1200, 1000);
  Sz := GetOutlineTextMetricsW(FDC, 0, nil);
  if Sz > 0 then
  begin
    GetMem(OTM, Sz);
    try
      if GetOutlineTextMetricsW(FDC, Sz, OTM) > 0 then
      begin
        // the cell ascent, as BGRABitmap places the text (its top at the line's Y)
        Result.Ascent := OTM^.otmTextMetrics.tmAscent;
        Result.Descent := -OTM^.otmTextMetrics.tmDescent;
        Result.CapH := OTM^.otmsCapEmHeight;
        if Result.CapH <= 0 then Result.CapH := 700;
        Result.BBox := OTM^.otmrcFontBox;
      end;
    finally
      FreeMem(OTM);
    end;
  end;
  Result.No := FFonts.Count + 1;
  FFonts.Add(Result);
end;

function TPdfWriter.HasGlyph(F: TPdfFont; Ch: WideChar): Boolean;
var
  G: Word;
begin
  SelectObject(FDC, F.Font);
  G := 0;
  Result := (GetGlyphIndicesW(FDC, @Ch, 1, @G, GGI_MARK_NONEXISTING_GLYPHS) <> GDI_ERROR) and (G <> $FFFF);
end;

{ the font for character I of U: the line's own, else one that has it }
function TPdfWriter.FontFor(const Face: string; Bold: Boolean; const U: UnicodeString; I: Integer): TPdfFont;
var
  Ch: WideChar;
begin
  Ch := U[I];
  if IsThai(Ch) then Exit(GetFont('Leelawadee UI', Bold));
  if (Ord(Ch) >= $D800) and (Ord(Ch) <= $DFFF) then Exit(GetFont('Segoe UI Emoji', False));
  Result := GetFont(Face, Bold);
  if (Ch = ' ') or HasGlyph(Result, Ch) then Exit;
  Result := GetFont('Segoe UI Symbol', False);
  if HasGlyph(Result, Ch) then Exit;
  Result := GetFont('Segoe UI', Bold);
  if HasGlyph(Result, Ch) then Exit;
  Result := GetFont(Face, Bold);
end;

{ True when the cluster's glyphs are not simply its characters' own glyphs (another form, a split
  vowel like Sara Am, a ligature): the page then gives its text as /ActualText }
function TPdfWriter.MapCluster(F: TPdfFont; const Chars: UnicodeString; const Gs: array of Word): Boolean;
var
  Own: array of Word;
  Done: array of Boolean;
  Taken: array of Boolean;
  I, J, Rest: Integer;
  Left: UnicodeString;
begin
  Result := False;
  if Length(Gs) = 0 then Exit;
  SetLength(Own, Length(Chars));
  SetLength(Done, Length(Chars));
  SetLength(Taken, Length(Gs));
  SelectObject(FDC, F.Font);
  if Length(Chars) > 0 then GetGlyphIndicesW(FDC, PWideChar(Chars), Length(Chars), @Own[0], GGI_MARK_NONEXISTING_GLYPHS);
  // a character's own glyph
  for I := 0 to High(Own) do
    for J := 0 to High(Gs) do
      if not Taken[J] and (Gs[J] = Own[I]) then
      begin
        Taken[J] := True;
        Done[I] := True;
        if F.ToUni[Gs[J]] = '' then F.ToUni[Gs[J]] := Chars[I + 1];
        Break;
      end;
  // the other glyphs (other forms, a ligature) take the characters left, in order
  Left := '';
  for I := 0 to High(Done) do
    if not Done[I] then Left := Left + Chars[I + 1];
  Result := Left <> '';
  for J := 0 to High(Taken) do
    if not Taken[J] then Result := True;
  Rest := 0;
  for J := 0 to High(Gs) do
    if not Taken[J] then
    begin
      if F.ToUni[Gs[J]] = '' then
      begin
        if Rest < Length(Left) then F.ToUni[Gs[J]] := Left[Rest + 1]
        else F.ToUni[Gs[J]] := #$200B;   // nothing left: a zero width space
      end;
      Inc(Rest);
    end;
  // more characters than glyphs: the last ones go with the first glyph of the cluster
  if (Rest < Length(Left)) and (F.ToUni[Gs[0]] <> '') and (Pos(Copy(Left, Rest + 1, MaxInt), F.ToUni[Gs[0]]) = 0) then
    F.ToUni[Gs[0]] := F.ToUni[Gs[0]] + Copy(Left, Rest + 1, MaxInt);
end;

{ one run in one font: shaped, placed; Emit draws its glyphs (else only the width) }
procedure TPdfWriter.ShapeRun(F: TPdfFont; const U: UnicodeString; Size, X, Y: Single; Content: TStringBuilder;
  var PenX: Single; Emit: Boolean);
var
  Items: array of TScriptItem;
  NItems, It, C0, C1, N, MaxG, NG, K, G, CI, CJ, G0, G1, J: Integer;
  SpanTxt: array of UnicodeString;
  SpanEnd: array of Boolean;
  AT: string;
  Glyphs, Clust, Vis: array of Word;
  Adv: array of Integer;
  Offs: array of TGOffset;
  Hr: HRESULT;
  K1: Single;
  Base, GX, GY: Single;
begin
  if U = '' then Exit;
  SelectObject(FDC, F.Font);
  SetLength(Items, Length(U) + 2);
  if ScriptItemize(PWideChar(U), Length(U), Length(U) + 1, nil, nil, @Items[0], @NItems) <> 0 then
  begin
    NItems := 1;
    Items[0].iCharPos := 0;
    Items[0].a.Bits := 0;
    Items[0].a.State := 0;
    Items[1].iCharPos := Length(U);
  end;
  K1 := Size / Em;
  Base := Y + F.Ascent * K1;
  for It := 0 to NItems - 1 do
  begin
    C0 := Items[It].iCharPos;
    C1 := Items[It + 1].iCharPos;
    N := C1 - C0;
    if N <= 0 then Continue;
    MaxG := N * 3 div 2 + 16;
    repeat
      SetLength(Glyphs, MaxG);
      SetLength(Vis, MaxG);
      SetLength(Clust, N);
      Hr := ScriptShape(FDC, @F.Cache, @U[C0 + 1], N, MaxG, @Items[It].a, @Glyphs[0], @Clust[0], @Vis[0], @NG);
      if Hr = E_OUTOFMEMORY_ then MaxG := MaxG * 2;
    until Hr <> E_OUTOFMEMORY_;
    if Hr <> 0 then
    begin
      // not shapeable in this font: as plain glyphs (no script)
      Items[It].a.Bits := Items[It].a.Bits and not $03FF;
      Hr := ScriptShape(FDC, @F.Cache, @U[C0 + 1], N, MaxG, @Items[It].a, @Glyphs[0], @Clust[0], @Vis[0], @NG);
      if Hr <> 0 then Continue;
    end;
    SetLength(Adv, NG);
    SetLength(Offs, NG);
    if ScriptPlace(FDC, @F.Cache, @Glyphs[0], NG, @Vis[0], @Items[It].a, @Adv[0], @Offs[0], nil) <> 0 then Continue;
    if Emit then
    begin
      F.Used := True;
      // the characters of every glyph (ToUnicode), cluster by cluster: a glyph that is a
      // character's own glyph gets it, the others take the rest in order, so copying gives the
      // text back (a Thai letter with its marks is one cluster of several glyphs)
      SetLength(SpanTxt, NG);
      SetLength(SpanEnd, NG);
      for K := 0 to NG - 1 do
      begin
        SpanTxt[K] := '';
        SpanEnd[K] := False;
      end;
      CI := 0;
      while CI < N do
      begin
        CJ := CI;
        while (CJ + 1 < N) and (Clust[CJ + 1] = Clust[CI]) do Inc(CJ);
        G0 := Clust[CI];
        if CJ + 1 < N then G1 := Clust[CJ + 1] - 1 else G1 := NG - 1;
        if (G1 >= G0) and MapCluster(F, Copy(U, C0 + CI + 1, CJ - CI + 1), Copy(Glyphs, G0, G1 - G0 + 1)) then
        begin
          SpanTxt[G0] := Copy(U, C0 + CI + 1, CJ - CI + 1);
          SpanEnd[G1] := True;
        end;
        CI := CJ + 1;
      end;
      for K := 0 to NG - 1 do
      begin
        G := Glyphs[K];
        if F.Widths[G] < 0 then F.Widths[G] := Adv[K];
        GX := PenX + Offs[K].du * K1;
        GY := Base - Offs[K].dv * K1;   // y down here; Uniscribe's dv is up
        if SpanTxt[K] <> '' then
        begin
          AT := '';
          for J := 1 to Length(SpanTxt[K]) do AT := AT + Hex4(Ord(SpanTxt[K][J]));
          Content.Append('/Span << /ActualText <FEFF' + AT + '> >> BDC' + #10);
        end;
        Content.Append('1 0 0 1 ' + Num(X + GX) + ' ' + Num(-GY) + ' Tm <' + Hex4(G) + '> Tj' + #10);
        if SpanEnd[K] then Content.Append('EMC' + #10);
        PenX := PenX + Adv[K] * K1;
      end;
    end
    else
      for K := 0 to NG - 1 do PenX := PenX + Adv[K] * K1;
  end;
end;

function TPdfWriter.RunWidth(F: TPdfFont; const U: UnicodeString; Size: Single): Single;
begin
  Result := 0;
  ShapeRun(F, U, Size, 0, 0, nil, Result, False);
end;

{ the width of a whole line (its runs in their fonts) }
function TPdfWriter.TextWidth(const Face: string; Bold: Boolean; const U: UnicodeString; Size: Single): Single;
var
  I, J: Integer;
  F: TPdfFont;
begin
  Result := 0;
  I := 1;
  while I <= Length(U) do
  begin
    F := FontFor(Face, Bold, U, I);
    J := I;
    while (J < Length(U)) and (FontFor(Face, Bold, U, J + 1) = F) do Inc(J);
    Result := Result + RunWidth(F, Copy(U, I, J - I + 1), Size);
    I := J + 1;
  end;
end;

procedure TPdfWriter.DrawText(const It: TPdfItem; X, Y: Single; Content: TStringBuilder);
var
  U: UnicodeString;
  I, J, Cut: Integer;
  F, Cur: TPdfFont;
  PenX: Single;
begin
  U := UTF8Decode(It.Text);
  if U = '' then Exit;
  if It.Fit and (It.W > 0) and (TextWidth(It.Face, It.Bold, U, It.Size) > It.W) then
  begin
    // shortened with an ellipsis, like the window does
    Cut := Length(U);
    while (Cut > 1) and (TextWidth(It.Face, It.Bold, Copy(U, 1, Cut) + #$2026, It.Size) > It.W) do
    begin
      Dec(Cut, Math.Max(1, (Cut div 12)));
      if (Cut > 1) and (Ord(U[Cut]) >= $D800) and (Ord(U[Cut]) <= $DBFF) then Dec(Cut);
    end;
    U := Copy(U, 1, Math.Max(1, Cut)) + #$2026;
  end;
  Content.Append('BT ' + RGBOnWhite(It.C) + ' rg' + #10);
  PenX := 0;
  Cur := nil;
  I := 1;
  while I <= Length(U) do
  begin
    F := FontFor(It.Face, It.Bold, U, I);
    J := I;
    while (J < Length(U)) and (FontFor(It.Face, It.Bold, U, J + 1) = F) do Inc(J);
    if F <> Cur then
    begin
      Content.Append('/F' + IntToStr(F.No) + ' ' + Num(It.Size) + ' Tf' + #10);
      Cur := F;
    end;
    ShapeRun(F, Copy(U, I, J - I + 1), It.Size, X, Y, Content, PenX, True);
    I := J + 1;
  end;
  Content.Append('ET' + #10);
end;

{ ---------- the file ---------- }

procedure TPdfWriter.W(const S: string);
begin
  if S <> '' then FOut.WriteBuffer(S[1], Length(S));
end;

function TPdfWriter.NewObj: Integer;
begin
  Inc(FNextObj);
  if FNextObj >= Length(FOffs) then SetLength(FOffs, FNextObj * 2 + 16);
  Result := FNextObj;
end;

procedure TPdfWriter.BeginObj(No: Integer);
begin
  FOffs[No] := FOut.Position;
  W(IntToStr(No) + ' 0 obj' + #10);
end;

procedure TPdfWriter.StreamObj(No: Integer; const Dict, Data: string; Compress: Boolean);
var
  D: string;
begin
  if Compress then D := Deflate(Data) else D := Data;
  BeginObj(No);
  if Compress then W('<< ' + Dict + ' /Filter /FlateDecode /Length ' + IntToStr(Length(D)) + ' >>' + #10)
  else W('<< ' + Dict + ' /Length ' + IntToStr(Length(D)) + ' >>' + #10);
  W('stream' + #10);
  W(D);
  W(#10 + 'endstream' + #10 + 'endobj' + #10);
end;

{ ---------- the font subset: only the glyphs the pages use ----------
  The glyph numbers stay (CIDToGIDMap /Identity): the unused glyphs become empty, the tables a PDF
  font needs are kept (head hhea hmtx maxp loca glyf cvt fpgm prep), the others go. A font without
  TrueType outlines stays whole. }

function BE16(const S: string; P: Integer): Integer; inline;   // P 0 based
begin
  Result := Byte(S[P + 1]) shl 8 or Byte(S[P + 2]);
end;

function BE32(const S: string; P: Integer): LongWord; inline;
begin
  Result := LongWord(Byte(S[P + 1])) shl 24 or LongWord(Byte(S[P + 2])) shl 16 or LongWord(Byte(S[P + 3])) shl 8 or
    LongWord(Byte(S[P + 4]));
end;

function Put16(V: Integer): string; inline;
begin
  Result := Char((V shr 8) and $FF) + Char(V and $FF);
end;

function Put32(V: LongWord): string; inline;
begin
  Result := Char((V shr 24) and $FF) + Char((V shr 16) and $FF) + Char((V shr 8) and $FF) + Char(V and $FF);
end;

function TableSum(const T: string): LongWord;
var
  K: Integer;
  P: string;
begin
  P := T + StringOfChar(#0, (4 - Length(T) mod 4) mod 4);
  Result := 0;
  K := 0;
  while K < Length(P) do
  begin
    Result := Result + BE32(P, K);
    Inc(K, 4);
  end;
end;

function SubsetTtf(const Font: string; const Widths: array of Integer): string;
const
  Keep: array[0..8] of string = ('cvt ', 'fpgm', 'glyf', 'head', 'hhea', 'hmtx', 'loca', 'maxp', 'prep');
var
  NT, K, I, NG, LocFmt, G, P, Flags, Comp: Integer;
  Tags: array of string;
  Offs, Lens: array of LongWord;
  Glyf, Loca, Head, NewGlyf, NewLoca, Data, Dir, Body: string;
  Used: array of Boolean;
  Stack: array of Integer;
  GOff: array of LongWord;
  Tabs: array of string;
  TabData: array of string;
  Off: LongWord;

  function Table(const Tag: string): string;
  var
    J: Integer;
  begin
    for J := 0 to NT - 1 do
      if Tags[J] = Tag then Exit(Copy(Font, Offs[J] + 1, Lens[J]));
    Result := '';
  end;

begin
  Result := Font;
  if (Length(Font) < 12) or (BE32(Font, 0) <> $00010000) then Exit;
  NT := BE16(Font, 4);
  SetLength(Tags, NT);
  SetLength(Offs, NT);
  SetLength(Lens, NT);
  for K := 0 to NT - 1 do
  begin
    Tags[K] := Copy(Font, 12 + K * 16 + 1, 4);
    Offs[K] := BE32(Font, 12 + K * 16 + 8);
    Lens[K] := BE32(Font, 12 + K * 16 + 12);
  end;
  Glyf := Table('glyf');
  Loca := Table('loca');
  Head := Table('head');
  if (Glyf = '') or (Loca = '') or (Length(Head) < 54) or (Length(Table('maxp')) < 6) then Exit;
  NG := BE16(Table('maxp'), 4);
  LocFmt := BE16(Head, 50);
  SetLength(GOff, NG + 1);
  for G := 0 to NG do
    if LocFmt = 0 then GOff[G] := LongWord(BE16(Loca, G * 2)) * 2 else GOff[G] := BE32(Loca, G * 4);
  // the glyphs used, and the parts of the composite ones
  SetLength(Used, NG);
  Stack := nil;
  for G := 0 to Math.Min(NG, Length(Widths)) - 1 do
    if (G = 0) or (Widths[G] >= 0) then
    begin
      Used[G] := True;
      SetLength(Stack, Length(Stack) + 1);
      Stack[High(Stack)] := G;
    end;
  while Length(Stack) > 0 do
  begin
    G := Stack[High(Stack)];
    SetLength(Stack, Length(Stack) - 1);
    if GOff[G + 1] <= GOff[G] then Continue;
    P := GOff[G];
    if SmallInt(BE16(Glyf, P)) >= 0 then Continue;
    P := P + 10;
    repeat
      Flags := BE16(Glyf, P);
      Comp := BE16(Glyf, P + 2);
      P := P + 4;
      if Flags and 1 <> 0 then P := P + 4 else P := P + 2;
      if Flags and 8 <> 0 then P := P + 2
      else if Flags and $40 <> 0 then P := P + 4
      else if Flags and $80 <> 0 then P := P + 8;
      if (Comp < NG) and not Used[Comp] then
      begin
        Used[Comp] := True;
        SetLength(Stack, Length(Stack) + 1);
        Stack[High(Stack)] := Comp;
      end;
    until Flags and $20 = 0;
  end;
  // the new glyf and loca (long offsets)
  NewGlyf := '';
  NewLoca := '';
  for G := 0 to NG - 1 do
  begin
    NewLoca := NewLoca + Put32(Length(NewGlyf));
    if Used[G] and (GOff[G + 1] > GOff[G]) then
    begin
      Data := Copy(Glyf, GOff[G] + 1, GOff[G + 1] - GOff[G]);
      NewGlyf := NewGlyf + Data + StringOfChar(#0, (4 - Length(Data) mod 4) mod 4);
    end;
  end;
  NewLoca := NewLoca + Put32(Length(NewGlyf));
  Head := Copy(Head, 1, 8) + Put32(0) + Copy(Head, 13, 38) + Put16(1) + Copy(Head, 53, MaxInt);
  // the font again: the kept tables, sorted by tag
  SetLength(Tabs, 0);
  SetLength(TabData, 0);
  for K := 0 to High(Keep) do
  begin
    case Keep[K] of
      'glyf': Data := NewGlyf;
      'loca': Data := NewLoca;
      'head': Data := Head;
    else
      Data := Table(Keep[K]);
    end;
    if Data = '' then Continue;
    SetLength(Tabs, Length(Tabs) + 1);
    SetLength(TabData, Length(TabData) + 1);
    Tabs[High(Tabs)] := Keep[K];
    TabData[High(TabData)] := Data;
  end;
  NT := Length(Tabs);
  I := 1;
  K := 0;
  while I * 2 <= NT do
  begin
    I := I * 2;
    Inc(K);
  end;
  Dir := Put32($00010000) + Put16(NT) + Put16(I * 16) + Put16(K) + Put16(NT * 16 - I * 16);
  Off := 12 + NT * 16;
  Body := '';
  for K := 0 to NT - 1 do
  begin
    Dir := Dir + Tabs[K] + Put32(TableSum(TabData[K])) + Put32(Off) + Put32(Length(TabData[K]));
    Body := Body + TabData[K] + StringOfChar(#0, (4 - Length(TabData[K]) mod 4) mod 4);
    Off := 12 + NT * 16 + Length(Body);
  end;
  Result := Dir + Body;
end;

procedure TPdfWriter.WriteFont(F: TPdfFont);
var
  Sz: DWORD;
  ObjCid, ObjDesc, ObjFile, ObjUni, K, N, Cnt: Integer;
  Wd, Cm, Entries, PsName, U16: string;
  J: Integer;
begin
  SelectObject(FDC, F.Font);
  Sz := GetFontData(FDC, 0, 0, nil, 0);
  if (Sz = GDI_ERROR) or (Sz = 0) then raise Exception.Create('the font "' + F.Face + '" cannot be embedded');
  SetLength(F.FileData, Sz);
  GetFontData(FDC, 0, 0, @F.FileData[1], Sz);
  try
    F.FileData := SubsetTtf(F.FileData, F.Widths);
  except
    // a font this cannot read goes whole
  end;
  ObjCid := NewObj;
  ObjDesc := NewObj;
  ObjFile := NewObj;
  ObjUni := NewObj;
  PsName := StringReplace(F.Face, ' ', '', [rfReplaceAll]) + IfThenStr(F.Bold, ',Bold', '');
  BeginObj(F.ObjType0);
  W('<< /Type /Font /Subtype /Type0 /BaseFont /' + PsName + ' /Encoding /Identity-H /DescendantFonts [' +
    IntToStr(ObjCid) + ' 0 R] /ToUnicode ' + IntToStr(ObjUni) + ' 0 R >>' + #10 + 'endobj' + #10);
  // the widths of the glyphs used
  Wd := '';
  for K := 0 to High(F.Widths) do
    if F.Widths[K] >= 0 then Wd := Wd + IntToStr(K) + ' [' + IntToStr(F.Widths[K]) + '] ';
  BeginObj(ObjCid);
  W('<< /Type /Font /Subtype /CIDFontType2 /BaseFont /' + PsName +
    ' /CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >> /FontDescriptor ' +
    IntToStr(ObjDesc) + ' 0 R /DW 0 /W [' + Wd + '] /CIDToGIDMap /Identity >>' + #10 + 'endobj' + #10);
  BeginObj(ObjDesc);
  W('<< /Type /FontDescriptor /FontName /' + PsName + ' /Flags 32 /FontBBox [' + IntToStr(F.BBox.Left) + ' ' +
    IntToStr(F.BBox.Bottom) + ' ' + IntToStr(F.BBox.Right) + ' ' + IntToStr(F.BBox.Top) + '] /ItalicAngle 0 /Ascent ' +
    IntToStr(F.Ascent) + ' /Descent ' + IntToStr(F.Descent) + ' /CapHeight ' + IntToStr(F.CapH) +
    ' /StemV ' + IfThenStr(F.Bold, '120', '80') + ' /FontFile2 ' + IntToStr(ObjFile) + ' 0 R >>' + #10 + 'endobj' + #10);
  StreamObj(ObjFile, '/Length1 ' + IntToStr(Length(F.FileData)), F.FileData, True);
  // ToUnicode: the characters of every glyph, in blocks of at most 100
  Cm := '/CIDInit /ProcSet findresource begin' + #10 + '12 dict begin' + #10 + 'begincmap' + #10 +
    '/CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def' + #10 +
    '/CMapName /Adobe-Identity-UCS def' + #10 + '/CMapType 2 def' + #10 +
    '1 begincodespacerange' + #10 + '<0000> <FFFF>' + #10 + 'endcodespacerange' + #10;
  Entries := '';
  Cnt := 0;
  N := 0;
  for K := 0 to High(F.ToUni) do
    if F.ToUni[K] <> '' then
    begin
      U16 := '';
      for J := 1 to Length(F.ToUni[K]) do U16 := U16 + Hex4(Ord(F.ToUni[K][J]));
      Entries := Entries + '<' + Hex4(K) + '> <' + U16 + '>' + #10;
      Inc(Cnt);
      Inc(N);
      if Cnt = 100 then
      begin
        Cm := Cm + '100 beginbfchar' + #10 + Entries + 'endbfchar' + #10;
        Entries := '';
        Cnt := 0;
      end;
    end;
  if Cnt > 0 then Cm := Cm + IntToStr(Cnt) + ' beginbfchar' + #10 + Entries + 'endbfchar' + #10;
  Cm := Cm + 'endcmap' + #10 + 'CMapName currentdict /CMap defineresource pop' + #10 + 'end' + #10 + 'end' + #10;
  StreamObj(ObjUni, '', Cm, True);
  if N = 0 then ;
end;

{ the JPEG's components (3 RGB, 1 grey, 4 CMYK), 0 when it is not a plain 8 bit JPEG }
function JpegComponents(const S: string): Integer;
var
  P, L: Integer;
  M: Byte;
begin
  Result := 0;
  if Copy(S, 1, 2) <> #$FF#$D8 then Exit;
  P := 3;
  while P + 9 <= Length(S) do
  begin
    if S[P] <> #$FF then Exit;
    M := Byte(S[P + 1]);
    L := Byte(S[P + 2]) shl 8 + Byte(S[P + 3]);
    if M in [$C0, $C1, $C2] then
    begin
      if Byte(S[P + 4]) <> 8 then Exit;
      Exit(Byte(S[P + 9]));
    end;
    P := P + 2 + L;
  end;
end;

procedure TPdfWriter.Write(const FileName, Title: string; const Items: TPdfItems; DocH, PageW, PageH, Margin: Single);
type
  TImgObj = record
    No: Integer;
    W, H: Integer;
  end;
var
  Starts: array of Single;
  Top, Bot, Best, LB, YOff, SY, EY, Y0, Y1: Single;
  K, I, P, NPages, ObjCatalog, ObjPages, ObjInfo, ObjPage, ObjCont, ObjMask: Integer;
  PageObjs: array of Integer;
  ImgObjs: array of TImgObj;
  Content: TStringBuilder;
  Contents: array of string;
  Res, Kids, Raw, RGB, Alp, Dict: string;
  B: TBGRABitmap;
  M: TStringStream;
  Px: PBGRAPixel;
  HasAlpha: Boolean;
  Comp: Integer;
  F: TPdfFont;
  PN: TPdfItem;
begin
  // ---------- the pages: breaks between lines, never through a picture ----------
  SetLength(Starts, 1);
  Starts[0] := 0;
  Top := 0;
  while Top + (PageH - Math.IfThen(Top = 0, 0, 2 * Margin) - Math.IfThen(Top = 0, Margin, 0)) < DocH do
  begin
    if Top = 0 then Bot := PageH - Margin else Bot := Top + PageH - 2 * Margin - 20;
    Best := -1;
    for K := 0 to High(Items) do
      if Items[K].Kind in [piText, piImage] then
      begin
        LB := Items[K].Y - 3;
        if (LB > Top + 40) and (LB <= Bot) then
          if (Items[K].Kind = piText) or (Items[K].Y + Items[K].H > Bot) then Best := Math.Max(Best, LB);
      end;
    // a picture across the break: the page ends before it
    if Best < 0 then Best := Bot;
    for K := 0 to High(Items) do
      if (Items[K].Kind = piImage) and (Items[K].Y < Best) and (Items[K].Y + Items[K].H > Best) and
        (Items[K].Y - 3 > Top + 40) then Best := Items[K].Y - 3;
    Top := Best;
    SetLength(Starts, Length(Starts) + 1);
    Starts[High(Starts)] := Top;
  end;
  NPages := Length(Starts);

  // ---------- the page contents (the fonts learn their glyphs) ----------
  SetLength(Contents, NPages);
  SetLength(ImgObjs, Length(Items));
  for K := 0 to High(ImgObjs) do ImgObjs[K].No := 0;
  FNextObj := 0;
  SetLength(FOffs, 64);
  ObjCatalog := NewObj;
  ObjPages := NewObj;
  Content := TStringBuilder.Create;
  try
    for P := 0 to NPages - 1 do
    begin
      Content.Clear;
      SY := Starts[P];
      if P < NPages - 1 then EY := Starts[P + 1] else EY := DocH + 1;
      if P = 0 then YOff := 0 else YOff := Margin - SY;
      // y down in the document: the page's matrix flips it
      Content.Append('1 0 0 -1 0 ' + Num(PageH) + ' cm' + #10);
      for K := 0 to High(Items) do
        with Items[K] do
          case Kind of
            piRect:
              begin
                Y0 := Math.Max(Y, SY);
                Y1 := Math.Min(Y + H, EY);
                if Y1 > Y0 then
                  Content.Append(RGBOnWhite(C) + ' rg ' + Num(X) + ' ' + Num(Y0 + YOff) + ' ' + Num(W) + ' ' +
                    Num(Y1 - Y0) + ' re f' + #10);
              end;
            piLine:
              if (Y >= SY) and (Y < EY) then
                Content.Append(Num(Size) + ' w ' + RGBOnWhite(C) + ' RG ' + Num(X) + ' ' + Num(Y + YOff) + ' m ' +
                  Num(X + W) + ' ' + Num(Y + H + YOff) + ' l S' + #10);
            piImage:
              if (Y >= SY - 1) and (Y < EY) then
              begin
                if ImgObjs[K].No = 0 then ImgObjs[K].No := NewObj;
                // the picture's own y is up: flip it back
                Content.Append('q ' + Num(W) + ' 0 0 ' + Num(-H) + ' ' + Num(X) + ' ' + Num(Y + YOff + H) +
                  ' cm /Im' + IntToStr(K) + ' Do Q' + #10);
              end;
            piText:
              if (Y >= SY - 1) and (Y < EY) then
              begin
                // text in a flipped matrix would stand on its head: the text matrix flips it again
                Content.Append('q 1 0 0 -1 0 0 cm' + #10);
                DrawText(Items[K], X, Y + YOff, Content);
                Content.Append('Q' + #10);
              end;
          end;
      // the page number, right aligned at the foot
      PN := Default(TPdfItem);
      PN.Kind := piText;
      PN.Face := 'Segoe UI';
      PN.Size := 9;
      PN.C := BGRA(140, 120, 100);
      PN.Text := Format('%d / %d', [P + 1, NPages]);
      Content.Append('q 1 0 0 -1 0 0 cm' + #10);
      DrawText(PN, PageW - Margin - TextWidth(PN.Face, False, UTF8Decode(PN.Text), PN.Size), PageH - 28, Content);
      Content.Append('Q' + #10);
      Contents[P] := Content.ToString;
    end;
  finally
    Content.Free;
  end;

  FOut := TFileStream.Create(FileName, fmCreate);
  try
    W('%PDF-1.5' + #10 + '%'#$E2#$E3#$CF#$D3 + #10);
    // the fonts get their objects now (the pages name them)
    for K := 0 to FFonts.Count - 1 do
    begin
      F := TPdfFont(FFonts[K]);
      if F.Used then F.ObjType0 := NewObj;
    end;
    Res := '/Font <<';
    for K := 0 to FFonts.Count - 1 do
    begin
      F := TPdfFont(FFonts[K]);
      if F.Used then Res := Res + ' /F' + IntToStr(F.No) + ' ' + IntToStr(F.ObjType0) + ' 0 R';
    end;
    Res := Res + ' >> /XObject <<';
    for K := 0 to High(ImgObjs) do
      if ImgObjs[K].No > 0 then Res := Res + ' /Im' + IntToStr(K) + ' ' + IntToStr(ImgObjs[K].No) + ' 0 R';
    Res := Res + ' >>';
    SetLength(PageObjs, NPages);
    Kids := '';
    for P := 0 to NPages - 1 do
    begin
      ObjPage := NewObj;
      ObjCont := NewObj;
      PageObjs[P] := ObjPage;
      Kids := Kids + IntToStr(ObjPage) + ' 0 R ';
      BeginObj(ObjPage);
      W('<< /Type /Page /Parent ' + IntToStr(ObjPages) + ' 0 R /MediaBox [0 0 ' + Num(PageW) + ' ' + Num(PageH) +
        '] /Resources << ' + Res + ' >> /Contents ' + IntToStr(ObjCont) + ' 0 R >>' + #10 + 'endobj' + #10);
      StreamObj(ObjCont, '', Contents[P], True);
    end;
    BeginObj(ObjCatalog);
    W('<< /Type /Catalog /Pages ' + IntToStr(ObjPages) + ' 0 R >>' + #10 + 'endobj' + #10);
    BeginObj(ObjPages);
    W('<< /Type /Pages /Count ' + IntToStr(NPages) + ' /Kids [' + Kids + '] >>' + #10 + 'endobj' + #10);
    // the pictures
    for K := 0 to High(Items) do
      if ImgObjs[K].No > 0 then
      begin
        Raw := DecodeStringBase64(Items[K].ImgData);
        Comp := 0;
        if Items[K].ImgMedia = 'image/jpeg' then Comp := JpegComponents(Raw);
        M := TStringStream.Create(Raw);
        try
          B := TBGRABitmap.Create(M);
        finally
          M.Free;
        end;
        try
          if Comp in [1, 3] then
          begin
            // the JPEG as it is
            BeginObj(ImgObjs[K].No);
            W('<< /Type /XObject /Subtype /Image /Width ' + IntToStr(B.Width) + ' /Height ' + IntToStr(B.Height) +
              ' /ColorSpace ' + IfThenStr(Comp = 1, '/DeviceGray', '/DeviceRGB') +
              ' /BitsPerComponent 8 /Filter /DCTDecode /Length ' + IntToStr(Length(Raw)) + ' >>' + #10 + 'stream' + #10);
            W(Raw);
            W(#10 + 'endstream' + #10 + 'endobj' + #10);
          end
          else
          begin
            // lossless: RGB rows top down, the alpha as a soft mask
            SetLength(RGB, B.Width * B.Height * 3);
            SetLength(Alp, B.Width * B.Height);
            HasAlpha := False;
            I := 1;
            for P := 0 to B.Height - 1 do
            begin
              Px := B.ScanLine[P];
              for Comp := 0 to B.Width - 1 do
              begin
                RGB[I] := Char(Px^.red);
                RGB[I + 1] := Char(Px^.green);
                RGB[I + 2] := Char(Px^.blue);
                Alp[(I + 2) div 3] := Char(Px^.alpha);
                if Px^.alpha < 255 then HasAlpha := True;
                Inc(I, 3);
                Inc(Px);
              end;
            end;
            Dict := '/Type /XObject /Subtype /Image /Width ' + IntToStr(B.Width) + ' /Height ' + IntToStr(B.Height) +
              ' /ColorSpace /DeviceRGB /BitsPerComponent 8';
            if HasAlpha then
            begin
              ObjMask := NewObj;
              Dict := Dict + ' /SMask ' + IntToStr(ObjMask) + ' 0 R';
              StreamObj(ImgObjs[K].No, Dict, RGB, True);
              StreamObj(ObjMask, '/Type /XObject /Subtype /Image /Width ' + IntToStr(B.Width) + ' /Height ' +
                IntToStr(B.Height) + ' /ColorSpace /DeviceGray /BitsPerComponent 8', Alp, True);
            end
            else
              StreamObj(ImgObjs[K].No, Dict, RGB, True);
          end;
        finally
          B.Free;
        end;
      end;
    // the fonts, with the glyphs the pages use
    for K := 0 to FFonts.Count - 1 do
    begin
      F := TPdfFont(FFonts[K]);
      if F.Used then WriteFont(F);
    end;
    ObjInfo := NewObj;
    BeginObj(ObjInfo);
    W('<< /Title ' + PdfText(Title) + ' /Producer (Virtual PLC) /CreationDate (D:' +
      FormatDateTime('yyyymmddhhnnss', Now) + ') >>' + #10 + 'endobj' + #10);
    // the cross reference
    FOffs[0] := FOut.Position;
    W('xref' + #10 + '0 ' + IntToStr(FNextObj + 1) + #10 + '0000000000 65535 f ' + #10);
    for K := 1 to FNextObj do W(Format('%.10d 00000 n ', [FOffs[K]]) + #10);
    W('trailer' + #10 + '<< /Size ' + IntToStr(FNextObj + 1) + ' /Root ' + IntToStr(ObjCatalog) + ' 0 R /Info ' +
      IntToStr(ObjInfo) + ' 0 R >>' + #10 + 'startxref' + #10 + IntToStr(FOffs[0]) + #10 + '%%EOF' + #10);
  finally
    FreeAndNil(FOut);
  end;
end;

procedure WriteChatPdf(const FileName, Title: string; const Items: TPdfItems; DocH: Single;
  PageW: Single; PageH: Single; Margin: Single);
var
  Wr: TPdfWriter;
begin
  Wr := TPdfWriter.Create;
  try
    Wr.Write(FileName, Title, Items, DocH, PageW, PageH, Margin);
  finally
    Wr.Free;
  end;
end;

end.
