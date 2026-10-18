unit uHelpForm;

{ The help of the IPC server in a window of its own: HTML (the TurboPower Ipro viewer), text that the
  mouse selects and Ctrl+C / the right button copies like on a web page, scroll bars on both sides
  when the window is smaller than the page, and a window that the user sizes. The buttons: Export to
  PDF (the main window does it), Open in the browser, Copy, Close. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, StdCtrls, ExtCtrls, Menus, Graphics, LCLType, Clipbrd, IpHtml;

type
  THelpPdfEvent = procedure(Sender: TObject) of object;
  THelpLinkEvent = procedure(Sender: TObject; const URL: string) of object;

  { a help page as data: the window shows it as HTML, the PDF export lays out the same items.
    K: hkHead a heading, hkText a paragraph, hkCode a line of code (lines in a row are one block),
    hkRow a table row (cells split by |, the first row of a table is its head), hkBullet a point.
    In text, `code` is shown as code }
  THelpKind = (hkHead, hkText, hkCode, hkRow, hkBullet);
  THelpItem = record
    K: THelpKind;
    S: string;
  end;
  THelpDoc = array of THelpItem;

  { THelpForm }

  THelpForm = class(TForm)
  private
    FBar: TPanel;
    FHtml: TIpHtmlPanel;
    FMenu: TPopupMenu;
    FSource: string;
    FOnLink: THelpLinkEvent;
    procedure HotClick(Sender: TObject);
    procedure PdfClick(Sender: TObject);
    procedure BrowserClick(Sender: TObject);
    procedure CopyClick(Sender: TObject);
    procedure SelectAllClick(Sender: TObject);
    procedure CloseClick(Sender: TObject);
    procedure FormKey(Sender: TObject; var Key: Word; Shift: TShiftState);
    function AddButton(const ACaption: string; AWidth, ARight: Integer; AClick: TNotifyEvent): TButton;
  public
    OnPdf: THelpPdfEvent;
    LastBrowser: string;
    ShotInfo: string;       // the file the browser was given (VPLC_NO_SHELL: only noted)
    constructor CreateHelp(AOwner: TComponent; const ATitle, AHtml: string);
    function CopyAll: string;  // selects everything, copies it, the text that went to the clipboard
    procedure SaveShot(const FileName: string);   // the window as it is on the screen (PNG)
    property Viewer: TIpHtmlPanel read FHtml;
    procedure SetPage(const AHtml: string);   // another page in the same window (its position stays)
    { a click on a link: the link (no web page is opened) }
    property OnLink: THelpLinkEvent read FOnLink write FOnLink;
  end;

function IpcHelpHtml(const Cpu: string): string;
function HelpDocHtml(const Title, Intro: string; const Doc: THelpDoc): string;
function HelpCells(const S: string): TStringList;   // the cells of a table row (the caller frees it); also splits words
function IoImportHelpDoc: THelpDoc;   // the I/O import file, for developers

implementation

uses
  Windows, ShellApi;

function IpcHelpHtml(const Cpu: string): string;

  function Pre(const S: string): string;
  begin
    Result := '<table width="100%" cellpadding="8" cellspacing="0"><tr><td bgcolor="#F1E6D0"><pre>' + S +
      '</pre></td></tr></table>';
  end;

begin
  Result :=
    '<html><head><title>Virtual PLC - IPC help</title></head>' +
    '<body bgcolor="#FBF6EC" text="#3A2A1E" link="#B22822">' +
    '<font face="Segoe UI">' +
    '<h2><font color="#8E1C17">Connect programs on this PC through IPC</font></h2>' +
    '<p>The IPC server is the Windows named pipe <b><tt>\\.\pipe\VirtualPLC</tt></b>. Turn it on with the ' +
    '<b>IPC server</b> switch on the Ports screen. It needs no network, no port and no firewall question: ' +
    'Python, C#, PowerShell, Node-RED or a test script on the same PC read and write the PLC''s tags, ' +
    'addresses and data blocks. CPU now: <b>' + Cpu + '</b>.</p>' +
    '<h3><font color="#8E1C17">The protocol</font></h3>' +
    '<p>A text line each way (UTF-8, ending in LF). Every answer starts with <b>OK</b> or <b>ERR</b>.</p>' +
    '<table border="1" cellpadding="5" cellspacing="0" bordercolor="#D9C6A0">' +
    '<tr bgcolor="#E8D8B8"><td><b>Request</b></td><td><b>Answer</b></td><td><b>Example</b></td></tr>' +
    '<tr><td><tt>PING</tt></td><td><tt>OK Virtual PLC &lt;CPU&gt;</tt></td><td>is it there?</td></tr>' +
    '<tr><td><tt>STATE</tt></td><td><tt>OK RUN</tt> | <tt>OK STOP</tt></td><td>the CPU mode</td></tr>' +
    '<tr><td><tt>RUN</tt> / <tt>STOP</tt></td><td><tt>OK</tt></td><td>switch the CPU</td></tr>' +
    '<tr><td><tt>READ &lt;operand&gt;</tt></td><td><tt>OK &lt;value&gt;</tt></td><td><tt>READ "Motor"</tt> -&gt; <tt>OK TRUE</tt></td></tr>' +
    '<tr><td><tt>WRITE &lt;operand&gt; &lt;value&gt;</tt></td><td><tt>OK</tt></td><td><tt>WRITE %MW20 123</tt>, <tt>WRITE "Start_PB" TRUE</tt></td></tr>' +
    '<tr><td><tt>TAGS</tt></td><td><tt>OK &lt;n&gt;</tt>, n lines <tt>name;type;address</tt>, <tt>END</tt></td><td>the tag table</td></tr>' +
    '<tr><td><tt>HELP</tt></td><td><tt>OK &lt;the commands&gt;</tt></td><td></td></tr>' +
    '<tr><td>a wrong request</td><td><tt>ERR &lt;why&gt;</tt></td><td><tt>READ "Nope"</tt> -&gt; <tt>ERR unknown symbol</tt></td></tr>' +
    '</table>' +
    '<p><b>Operands</b> as in the program: <tt>"Tag"</tt>, <tt>%I0.0</tt> / <tt>%MW20</tt> / <tt>%MD100</tt> ' +
    '(<tt>I0.0</tt>, <tt>MW20</tt> on the S7-300/400), <tt>"DB".Var</tt>, <tt>"DB".Arr[2].Member</tt>.<br>' +
    '<b>Values</b> as in the watch table: <tt>TRUE</tt> / <tt>FALSE</tt>, <tt>123</tt>, <tt>-5</tt>, ' +
    '<tt>1.5</tt>, <tt>T#2S</tt>, <tt>16#FF</tt>. A digital input written by WRITE is the simulated switch ' +
    '(like on the I/O screen); other values are written at the cycle check point.</p>' +
    '<h3><font color="#8E1C17">Python</font></h3>' +
    Pre('f = open(r"\\.\pipe\VirtualPLC", "r+b", buffering=0)' + LineEnding +
      LineEnding +
      'def plc(cmd):' + LineEnding +
      '    f.write((cmd + "\n").encode())' + LineEnding +
      '    line = b""' + LineEnding +
      '    while not line.endswith(b"\n"):' + LineEnding +
      '        line += f.read(1)' + LineEnding +
      '    return line.decode().strip()' + LineEnding +
      LineEnding +
      'print(plc(''READ "Motor"''))           # OK FALSE' + LineEnding +
      'print(plc(''WRITE "Start_PB" TRUE''))  # OK' + LineEnding +
      'print(plc("READ %MW20"))              # OK 0') +
    '<h3><font color="#8E1C17">PowerShell</font></h3>' +
    Pre('$p = New-Object System.IO.Pipes.NamedPipeClientStream(".", "VirtualPLC", "InOut")' + LineEnding +
      '$p.Connect(2000)' + LineEnding +
      '$w = New-Object System.IO.StreamWriter($p); $w.AutoFlush = $true' + LineEnding +
      '$r = New-Object System.IO.StreamReader($p)' + LineEnding +
      '$w.Write("READ %MW20`n"); $r.ReadLine()') +
    '<h3><font color="#8E1C17">C#</font></h3>' +
    Pre('using System.IO.Pipes;' + LineEnding +
      'using var p = new NamedPipeClientStream(".", "VirtualPLC", PipeDirection.InOut);' + LineEnding +
      'p.Connect(2000);' + LineEnding +
      'var w = new StreamWriter(p) { AutoFlush = true, NewLine = "\n" };' + LineEnding +
      'var r = new StreamReader(p);' + LineEnding +
      'w.WriteLine("WRITE %MW20 123");' + LineEnding +
      'Console.WriteLine(r.ReadLine());   // OK') +
    '<h3><font color="#8E1C17">Node-RED and others</font></h3>' +
    '<p>Anything that opens a Windows named pipe works: write a line, read a line. For tools on other PCs ' +
    'use the S7 server (snap7, HMI, SCADA) or Modbus TCP on the same Ports screen.</p>' +
    '<h3><font color="#8E1C17">Good to know</font></h3>' +
    '<ul><li>Many clients at once are fine; each has its own connection.</li>' +
    '<li>The pipe is there while the switch is on and the Virtual PLC runs; the switch is saved with the project.</li>' +
    '<li>Download the program first: READ / WRITE of <tt>"DB".Var</tt> need the DB in the CPU.</li>' +
    '<li>The requests are counted on the Ports screen.</li></ul>' +
    '</font></body></html>';
  // code in a line: coloured, not a font of its own (the viewer's copy breaks the line at a font of
  // another height)
  Result := StringReplace(StringReplace(Result, '<tt>', '<font color="#9A3412">', [rfReplaceAll]), '</tt>',
    '</font>', [rfReplaceAll]);
end;

function HtmlEsc(const S: string): string;
begin
  Result := StringReplace(StringReplace(StringReplace(S, '&', '&amp;', [rfReplaceAll]), '<', '&lt;',
    [rfReplaceAll]), '>', '&gt;', [rfReplaceAll]);
end;

// `code` in a text: coloured (not a font of its own: the viewer's copy breaks the line at a font of
// another height)
function HtmlInline(const S: string): string;
var
  K: Integer;
  Code: Boolean;
  Part: string;
begin
  Result := '';
  Code := False;
  Part := '';
  for K := 1 to Length(S) do
    if S[K] = '`' then
    begin
      if Code then Result := Result + '<font color="#9A3412">' + HtmlEsc(Part) + '</font>'
      else Result := Result + HtmlEsc(Part);
      Part := '';
      Code := not Code;
    end
    else
      Part := Part + S[K];
  Result := Result + HtmlEsc(Part);
end;

function HelpCells(const S: string): TStringList;
var
  P, Q: Integer;
begin
  // split at | (no quote handling: the cells keep their quotes)
  Result := TStringList.Create;
  Q := 1;
  for P := 1 to Length(S) + 1 do
    if (P > Length(S)) or (S[P] = '|') then
    begin
      Result.Add(Copy(S, Q, P - Q));
      Q := P + 1;
    end;
end;

function HelpDocHtml(const Title, Intro: string; const Doc: THelpDoc): string;
var
  I, C: Integer;
  Cells: TStringList;
  InCode, InTable, InList, Head: Boolean;

  procedure Close;
  begin
    if InCode then Result := Result + '</pre></td></tr></table>';
    if InTable then Result := Result + '</table>';
    if InList then Result := Result + '</ul>';
    InCode := False;
    InTable := False;
    InList := False;
  end;

begin
  Result := '<html><head><title>' + HtmlEsc(Title) + '</title></head>' +
    '<body bgcolor="#FBF6EC" text="#3A2A1E" link="#B22822"><font face="Segoe UI">' +
    '<h2><font color="#8E1C17">' + HtmlEsc(Title) + '</font></h2>';
  if Intro <> '' then Result := Result + '<p>' + HtmlInline(Intro) + '</p>';
  InCode := False;
  InTable := False;
  InList := False;
  for I := 0 to High(Doc) do
  begin
    if ((Doc[I].K <> hkCode) and InCode) or ((Doc[I].K <> hkRow) and InTable) or
      ((Doc[I].K <> hkBullet) and InList) then
      Close;
    case Doc[I].K of
      hkHead: Result := Result + '<h3><font color="#8E1C17">' + HtmlEsc(Doc[I].S) + '</font></h3>';
      hkText: Result := Result + '<p>' + HtmlInline(Doc[I].S) + '</p>';
      hkCode:
        begin
          if not InCode then
            Result := Result + '<table width="100%" cellpadding="8" cellspacing="0"><tr><td bgcolor="#F1E6D0"><pre>'
          else
            Result := Result + LineEnding;
          InCode := True;
          Result := Result + HtmlEsc(Doc[I].S);
        end;
      hkRow:
        begin
          Head := not InTable;
          if not InTable then
            Result := Result + '<table border="1" cellpadding="5" cellspacing="0" bordercolor="#D9C6A0">';
          InTable := True;
          Cells := HelpCells(Doc[I].S);
          try
            if Head then Result := Result + '<tr bgcolor="#E8D8B8">' else Result := Result + '<tr>';
            for C := 0 to Cells.Count - 1 do
              if Head then Result := Result + '<td><b>' + HtmlInline(Trim(Cells[C])) + '</b></td>'
              else Result := Result + '<td>' + HtmlInline(Trim(Cells[C])) + '</td>';
            Result := Result + '</tr>';
          finally
            Cells.Free;
          end;
        end;
    else
      begin
        if not InList then Result := Result + '<ul>';
        InList := True;
        Result := Result + '<li>' + HtmlInline(Doc[I].S) + '</li>';
      end;
    end;
  end;
  Close;
  Result := Result + '</font></body></html>';
end;

function IoImportHelpDoc: THelpDoc;
var
  N: Integer;

  procedure A(K: THelpKind; const S: string);
  begin
    SetLength(Result, N + 1);
    Result[N].K := K;
    Result[N].S := S;
    Inc(N);
  end;

begin
  N := 0;
  Result := nil;
  A(hkHead, 'What the import does');
  A(hkText, 'The I/O import reads a CSV file with one line per I/O point of the CPU (the on-board / default ' +
    'I/O of the I/O screen). For every line it can: give the point a tag (a new entry in the PLC tag table), ' +
    'set how a digital input behaves (switch, push button NO / NC), set the generator of an analog input ' +
    '(manual, sine, ramp) and set the simulated value of an input. Nothing in the program changes.');
  A(hkText, 'The file that `Export I/O list (CSV) ...` writes is a valid import file: export, edit it in Excel ' +
    'or a text editor, import it again. A file made by another program (the I/O list of an electrical CAD, a ' +
    'script) needs only the columns below.');
  A(hkHead, 'The file');
  A(hkBullet, 'Text, UTF-8 (with or without BOM; ANSI is read as well).');
  A(hkBullet, 'The separator is found by itself: `;` (Excel in many countries), `,` or a tab.');
  A(hkBullet, 'A field with the separator, a quote or a line break is in double quotes; a quote inside is ' +
    'doubled: `"Motor ""A"""`.');
  A(hkBullet, 'The first line names the columns (any order, upper / lower case alike). Without a head line the ' +
    'columns are taken in the order of the export: Kind, Address, Tag, Input / range, Value.');
  A(hkBullet, 'Empty lines and lines without an address are skipped.');
  A(hkHead, 'The columns');
  A(hkRow, 'Column (head)|Needed|Content');
  A(hkRow, '`Address`|yes|the I/O point: `%I0.3`, `I0.3`, `%Q4.1`, `%IW64`, `IW64`, `PIW288`, `%QW80`, `PQW304`');
  A(hkRow, '`Kind`|no|`DI`, `DQ`, `AI`, `AQ`: only for the reader, the address decides');
  A(hkRow, '`Tag` (or `Name`, `Symbol`)|no|the tag name for the point, e.g. `Start_PB`');
  A(hkRow, '`Comment`|no|the comment of a new tag');
  A(hkRow, '`Input / range` (or `Input`, `Mode`)|no|DI: `switch`, `push NO`, `push NC`; AI: `manual`, `sine`, `ramp`');
  A(hkRow, '`Value`|no|DI: `TRUE` / `FALSE` (`1` / `0`, `on` / `off`); AI: the raw value -32768..32767 ' +
    '(0..27648 = 0..10 V)');
  A(hkRow, '`Engineering`, `Forced`|no|written by the export, ignored by the import');
  A(hkHead, 'Addresses');
  A(hkText, 'Only the I/O of the CPU on the I/O screen can be imported; a line with another address is counted as ' +
    'skipped. The addresses of the default I/O:');
  A(hkRow, 'CPU|DI|DQ|AI|AQ');
  A(hkRow, 'S7-300|`I0.0` .. `I3.7`|`Q4.0` .. `Q7.7`|`PIW288` .. `PIW302`|`PQW304` .. `PQW310`');
  A(hkRow, 'S7-400|`I0.0` .. `I3.7`|`Q4.0` .. `Q7.7`|`PIW512` .. `PIW526`|`PQW512` .. `PQW526`');
  A(hkRow, 'S7-1200|`%I0.0` .. `%I1.5` (1211C: `%I0.5`)|`%Q0.0` .. `%Q1.1` (1211C: `%Q0.3`)|`%IW64`, `%IW66`|' +
    '1215C / 1217C: `%QW64`, `%QW66`');
  A(hkRow, 'S7-1500|`%I0.0` .. `%I3.7`|`%Q0.0` .. `%Q3.7`|`%IW4` .. `%IW18`|`%QW4` .. `%QW10`');
  A(hkText, 'The `%` and the `P` of the S7-300 / 400 are optional: `IW288` and `PIW288` are the same point.');
  A(hkHead, 'The rules for the tags');
  A(hkBullet, 'The address has no tag yet and the name is free: a new tag (Bool for DI / DQ, Int for AI / AQ) ' +
    'with the comment.');
  A(hkBullet, 'The address has a tag with this name: its comment is updated (when the column is there).');
  A(hkBullet, 'The address has a tag with another name: it stays (the program uses the name); counted as kept.');
  A(hkBullet, 'The name belongs to another address: the line''s tag is skipped (two tags would have one name).');
  A(hkHead, 'Inputs and outputs');
  A(hkBullet, 'Input / range and Value act on inputs only: DQ / AQ lines give tags, their values are the ' +
    'program''s.');
  A(hkBullet, 'A DI value is the simulated switch, as a click on the I/O screen; a push button returns to its ' +
    'rest position when the mouse lets it go.');
  A(hkBullet, 'An AI value switches the channel to manual with this raw value.');
  A(hkBullet, 'The project is changed (tags, input kinds and generators are saved with it); Undo in the program ' +
    'editor takes the import back.');
  A(hkHead, 'An example');
  A(hkCode, 'Kind;Address;Tag;Input / range;Value;Comment');
  A(hkCode, 'DI;%I0.0;Start_PB;push NO;;start button');
  A(hkCode, 'DI;%I0.1;Stop_PB;push NC;;stop button, wired NC');
  A(hkCode, 'DI;%I0.2;Overload_OK;switch;TRUE;thermal overload healthy');
  A(hkCode, 'DQ;%Q0.0;Motor;;;motor contactor');
  A(hkCode, 'AI;%IW64;Tank_Level;sine;;level 0..10 V');
  A(hkCode, 'AI;%IW66;Setpoint;manual;13824;5 V');
  A(hkHead, 'Made by a program (Python)');
  A(hkCode, 'import csv');
  A(hkCode, 'rows = [("DI", "%I0.{}".format(b), "Sensor_{}".format(b), "switch", "FALSE") for b in range(8)]');
  A(hkCode, 'with open("io.csv", "w", newline="", encoding="utf-8") as f:');
  A(hkCode, '    w = csv.writer(f, delimiter=";")');
  A(hkCode, '    w.writerow(["Kind", "Address", "Tag", "Input / range", "Value"])');
  A(hkCode, '    w.writerows(rows)');
  A(hkHead, 'The answer');
  A(hkText, 'After the import a message counts what happened: `tags added`, `updated`, `kept`, `inputs set`, ' +
    '`values set`, `skipped`. The new tags are in the PLC tag table, the input kinds and values on the I/O ' +
    'screen; programs on this PC read them through the IPC server (`TAGS`, `READ`).');
end;

{ THelpForm }

constructor THelpForm.CreateHelp(AOwner: TComponent; const ATitle, AHtml: string);
var
  It: TMenuItem;
begin
  inherited CreateNew(AOwner, 0);
  Caption := ATitle;
  BorderStyle := bsSizeable;
  Position := poScreenCenter;
  Width := 940;
  Height := 760;
  Constraints.MinWidth := 520;
  Constraints.MinHeight := 240;
  KeyPreview := True;
  OnKeyDown := @FormKey;
  FSource := AHtml;
  FBar := TPanel.Create(Self);
  FBar.Parent := Self;
  FBar.Align := alBottom;
  FBar.Height := 44;
  FBar.BevelOuter := bvNone;
  FBar.Color := RGBToColor(242, 232, 212);
  FBar.Width := ClientWidth;
  // from the right: Close, Copy, Open in the browser, Export to PDF
  AddButton('Close', 90, 10, @CloseClick);
  AddButton('Copy', 90, 108, @CopyClick);
  AddButton('Open in the browser', 160, 206, @BrowserClick);
  AddButton('Export to PDF ...', 140, 374, @PdfClick);
  FMenu := TPopupMenu.Create(Self);
  It := TMenuItem.Create(FMenu);
  It.Caption := 'Copy';
  It.ShortCut := ShortCut(VK_C, [ssCtrl]);
  It.OnClick := @CopyClick;
  FMenu.Items.Add(It);
  It := TMenuItem.Create(FMenu);
  It.Caption := 'Select all';
  It.ShortCut := ShortCut(VK_A, [ssCtrl]);
  It.OnClick := @SelectAllClick;
  FMenu.Items.Add(It);
  FHtml := TIpHtmlPanel.Create(Self);
  FHtml.Parent := Self;
  FHtml.Align := alClient;
  FHtml.AllowTextSelect := True;
  FHtml.DefaultTypeFace := 'Segoe UI';
  FHtml.DefaultFontSize := 10;
  FHtml.PopupMenu := FMenu;
  FHtml.OnHotClick := @HotClick;
  FHtml.SetHtmlFromStr(AHtml);
end;

function THelpForm.AddButton(const ACaption: string; AWidth, ARight: Integer; AClick: TNotifyEvent): TButton;
begin
  Result := TButton.Create(Self);
  Result.Parent := FBar;
  Result.Caption := ACaption;
  Result.Width := AWidth;
  Result.Height := 30;
  Result.Top := 7;
  Result.Left := FBar.ClientWidth - ARight - AWidth;
  Result.Anchors := [akTop, akRight];
  Result.OnClick := AClick;
end;

procedure THelpForm.HotClick(Sender: TObject);
begin
  if Assigned(FOnLink) then FOnLink(Self, FHtml.HotURL);
end;

procedure THelpForm.SetPage(const AHtml: string);
begin
  FSource := AHtml;
  FHtml.SetHtmlFromStr(AHtml);
end;

procedure THelpForm.PdfClick(Sender: TObject);
begin
  if Assigned(OnPdf) then OnPdf(Self);
end;

procedure THelpForm.BrowserClick(Sender: TObject);
var
  F: string;
  K: Integer;
  SL: TStringList;
begin
  // the same page in the web browser (a file in the temp folder)
  F := '';
  for K := 1 to Length(Caption) do
    if Caption[K] in ['A'..'Z', 'a'..'z', '0'..'9'] then F := F + Caption[K] else F := F + '_';
  F := GetTempDir + F + '.html';
  SL := TStringList.Create;
  try
    SL.Text := StringReplace(FSource, '<head>', '<head><meta charset="utf-8">', []);
    SL.SaveToFile(F);
  finally
    SL.Free;
  end;
  LastBrowser := F;
  if SysUtils.GetEnvironmentVariable('VPLC_NO_SHELL') <> '' then Exit;
  ShellExecuteW(0, 'open', PWideChar(UnicodeString(F)), nil, nil, 1);
end;

procedure THelpForm.CopyClick(Sender: TObject);
begin
  if FHtml.HaveSelection then FHtml.CopyToClipboard;
end;

procedure THelpForm.SelectAllClick(Sender: TObject);
begin
  FHtml.SelectAll;
end;

procedure THelpForm.CloseClick(Sender: TObject);
begin
  Hide;
end;

procedure THelpForm.FormKey(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  if (ssCtrl in Shift) and (Key = VK_C) then
  begin
    CopyClick(Self);
    Key := 0;
  end
  else if (ssCtrl in Shift) and (Key = VK_A) then
  begin
    SelectAllClick(Self);
    Key := 0;
  end
  else if Key = VK_ESCAPE then
  begin
    Hide;
    Key := 0;
  end;
end;

function THelpForm.CopyAll: string;
begin
  FHtml.SelectAll;
  FHtml.CopyToClipboard;
  Result := Clipboard.AsText;
end;

function PrintWindow(Wnd: HWND; Dc: HDC; Flags: UINT): BOOL; stdcall; external 'user32.dll';

procedure THelpForm.SaveShot(const FileName: string);
var
  Png: TPortableNetworkGraphic;
  R: TRect;
  Scr, Mem: HDC;
  Hb, Old: HBITMAP;
  W, H: Integer;
  Ok: Boolean;
begin
  // the window with its frame, also when another window lies over it (PrintWindow, full content)
  Repaint;
  Application.ProcessMessages;
  Windows.GetWindowRect(Handle, R);
  W := R.Right - R.Left;
  H := R.Bottom - R.Top;
  Scr := GetDC(0);
  Mem := CreateCompatibleDC(Scr);
  Hb := CreateCompatibleBitmap(Scr, W, H);
  Old := SelectObject(Mem, Hb);
  Ok := PrintWindow(Handle, Mem, 2);
  if not Ok then BitBlt(Mem, 0, 0, W, H, Scr, R.Left, R.Top, SRCCOPY);
  SelectObject(Mem, Old);
  DeleteDC(Mem);
  ReleaseDC(0, Scr);
  ShotInfo := Format('%dx%d print %s', [W, H, BoolToStr(Ok, True)]);
  Png := TPortableNetworkGraphic.Create;
  try
    Png.LoadFromBitmapHandles(Hb, 0);
    Png.SaveToFile(FileName);
  finally
    Png.Free;
    DeleteObject(Hb);
  end;
end;

end.
