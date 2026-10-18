{ SCL Studio - editor tabs: SCL source, PLC tag/symbol table, declaration grid, grid views, text view }
unit sclide_editors;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, StdCtrls, ExtCtrls, ComCtrls, Grids, Dialogs, Graphics, Menus,
  LCLType, SynEdit, SynEditMarkupHighAll, SynEditHighlighter, SynHighlighterAny, SynEditTypes,
  scl_base, scl_types, scl_ast, scl_project, scl_declgen;

type
  TEditorKind = (ekSource, ekTags, ekDecl, ekView, ekText);

  TEditorTab = class(TTabSheet)
  private
    FModified: Boolean;
    procedure SetModified(V: Boolean);
  public
    Kind: TEditorKind;
    Key: string;
    BaseCaption: string;
    OnModifiedChange: TNotifyEvent;
    procedure UpdateCaption;
    function Save: Boolean; virtual;
    property Modified: Boolean read FModified write SetModified;
  end;

  { SCL source editor }
  TSourceTab = class(TEditorTab)
  private
    FPopup: TPopupMenu;
    procedure EditChange(Sender: TObject);
    procedure PopFindDecl(Sender: TObject);
    procedure PopGoBack(Sender: TObject);
    procedure PopUndo(Sender: TObject);
    procedure PopRedo(Sender: TObject);
    procedure PopCut(Sender: TObject);
    procedure PopCopy(Sender: TObject);
    procedure PopPaste(Sender: TObject);
    procedure PopSelectAll(Sender: TObject);
    procedure EditMouseUp(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
    procedure EditMouseDown(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
    procedure EditKeyDown(Sender: TObject; var AKey: Word; Shift: TShiftState);
  public
    Edit: TSynEdit;
    FileName: string;
    OnFindDeclaration: TNotifyEvent;
    OnGoBack: TNotifyEvent;
    procedure GotoPos(ALine, ACol, ALen: Integer);
    procedure InsertSnippet(const ASnippet: string);
    procedure DropSnippetAt(X, Y: Integer; const ASnippet: string);
    constructor CreateFor(APages: TPageControl; const AFile: string; HL: TSynCustomHighlighter);
    procedure LoadFile;
    function Save: Boolean; override;
    procedure GotoLine(ALine, ACol: Integer);
    procedure SetTextKeepModified(const S: string);
  end;

  { PLC tags / symbols }
  TTagsTab = class(TEditorTab)
  private
    FProject: TSclProject;
    procedure GridEdited(Sender: TObject; ACol, ARow: Integer; const Value: string);
    procedure BtnAdd(Sender: TObject);
    procedure BtnDel(Sender: TObject);
    procedure BtnSave(Sender: TObject);
  public
    Grid: TStringGrid;
    constructor CreateFor(APages: TPageControl; AProject: TSclProject; const TypeNames: TStrings);
    procedure LoadFromProject;
    function Save: Boolean; override;
  end;

  TGetTextEvent = function(const AFile: string): string of object;
  TSetTextEvent = procedure(const AFile, AText: string) of object;

  { interface / member declaration grid for UDT, DB, FB, FC, OB }
  TDeclTab = class(TEditorTab)
  private
    FInfo: TBlockKindInfo;
    FInfoLabel: TLabel;
    procedure GridEdited(Sender: TObject; ACol, ARow: Integer; const Value: string);
    procedure BtnAdd(Sender: TObject);
    procedure BtnDel(Sender: TObject);
    procedure BtnUp(Sender: TObject);
    procedure BtnDown(Sender: TObject);
    procedure BtnApply(Sender: TObject);
    procedure BtnReload(Sender: TObject);
    procedure SwapRows(A, B: Integer);
  public
    Grid: TStringGrid;
    BlockName: string;
    FileName: string;
    OnGetText: TGetTextEvent;
    OnSetText: TSetTextEvent;
    constructor CreateFor(APages: TPageControl; const ABlock, AFile: string; const TypeNames: TStrings;
      AGet: TGetTextEvent; ASet: TSetTextEvent);
    procedure Reload;
    function Save: Boolean; override;
  end;

  { read only grid with filter (All variables / All elements) }
  TGridViewTab = class(TEditorTab)
  private
    FRows: TList;           // PStringArray rows
    FFilter: TEdit;
    FCount: TLabel;
    procedure FilterChange(Sender: TObject);
    procedure GridDblClick(Sender: TObject);
  public
    Grid: TStringGrid;
    OnOpenRow: procedure(const Row: TStringArray) of object;
    constructor CreateFor(APages: TPageControl; const ACaption: string; const Headers: array of string);
    destructor Destroy; override;
    procedure ClearRows;
    procedure AddRow(const Cells: array of string);
    procedure Refill;
  end;

  TTextTab = class(TEditorTab)
  public
    Edit: TSynEdit;
    constructor CreateFor(APages: TPageControl; const ACaption: string; HL: TSynCustomHighlighter);
  end;

function CreateSclHighlighter(AOwner: TComponent): TSynAnySyn;
function ElementaryTypeNames: TStringArray;

implementation

uses Math;

function ElementaryTypeNames: TStringArray;
begin
  Result := ['Bool', 'Byte', 'Word', 'DWord', 'LWord', 'SInt', 'Int', 'DInt', 'LInt', 'USInt', 'UInt',
    'UDInt', 'ULInt', 'Real', 'LReal', 'Time', 'LTime', 'S5Time', 'Date', 'Time_Of_Day', 'LTime_Of_Day',
    'Date_And_Time', 'LDT', 'DTL', 'Char', 'WChar', 'String', 'String[20]', 'WString',
    'Array[0..9] of Int', 'Array[0..7] of Bool', 'TON_TIME', 'TOF_TIME', 'TP_TIME', 'IEC_TIMER',
    'CTU_INT', 'CTD_INT', 'CTUD_INT', 'R_TRIG', 'F_TRIG'];
end;

function CreateSclHighlighter(AOwner: TComponent): TSynAnySyn;
var
  L: TStringList;
begin
  Result := TSynAnySyn.Create(AOwner);
  Result.Comments := [csAnsiStyle, csCStyle];
  Result.StringDelim := sdSingleQuote;
  Result.IdentifierChars := '_0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ';
  Result.DetectPreprocessor := False;
  { #local, %address: '#' and '%' separate words so #Name / Name / "Name" highlight together }
  Result.WordBreakChars := Result.WordBreakChars + ['#', '%', '"'];
  L := TStringList.Create;
  try
    L.CommaText := 'IF,THEN,ELSIF,ELSE,END_IF,CASE,OF,END_CASE,FOR,TO,BY,DO,END_FOR,WHILE,END_WHILE,' +
      'REPEAT,UNTIL,END_REPEAT,EXIT,CONTINUE,RETURN,GOTO,REGION,END_REGION,AND,OR,XOR,NOT,MOD,' +
      'FUNCTION,END_FUNCTION,FUNCTION_BLOCK,END_FUNCTION_BLOCK,ORGANIZATION_BLOCK,END_ORGANIZATION_BLOCK,' +
      'DATA_BLOCK,END_DATA_BLOCK,TYPE,END_TYPE,STRUCT,END_STRUCT,VAR,VAR_INPUT,VAR_OUTPUT,VAR_IN_OUT,' +
      'VAR_TEMP,VAR_STAT,END_VAR,CONSTANT,RETAIN,NON_RETAIN,BEGIN,TITLE,VERSION,AUTHOR,FAMILY,NAME,ARRAY,' +
      'KNOW_HOW_PROTECT,DB_SPECIFIC';
    Result.KeyWords := L;
    L.CommaText := 'TRUE,FALSE,BOOL,BYTE,WORD,DWORD,LWORD,SINT,INT,DINT,LINT,USINT,UINT,UDINT,ULINT,' +
      'REAL,LREAL,TIME,LTIME,S5TIME,DATE,TIME_OF_DAY,TOD,LTOD,DATE_AND_TIME,DT,LDT,DTL,CHAR,WCHAR,STRING,' +
      'WSTRING,VOID,TON,TOF,TP,TONR,TON_TIME,TOF_TIME,TP_TIME,TONR_TIME,TON_LTIME,TOF_LTIME,TP_LTIME,' +
      'IEC_TIMER,IEC_LTIMER,CTU,CTD,CTUD,CTU_INT,CTD_INT,CTUD_INT,CTU_DINT,CTD_DINT,CTUD_DINT,' +
      'IEC_COUNTER,R_TRIG,F_TRIG,RS,SR';
    Result.Constants := L;
    L.CommaText := 'MIN,MAX,LIMIT,SEL,MUX,ABS,SQR,SQRT,EXP,LN,LOG,SIN,COS,TAN,ASIN,ACOS,ATAN,FRAC,TRUNC,' +
      'ROUND,CEIL,FLOOR,NORM_X,SCALE_X,SHL,SHR,ROL,ROR,LEN,CONCAT,LEFT,RIGHT,MID,FIND';
    Result.Objects := L;
  finally
    L.Free;
  end;
  Result.KeyAttri.Foreground := clNavy;
  Result.KeyAttri.Style := [fsBold];
  Result.ConstantAttri.Foreground := clTeal;
  Result.ObjectAttri.Foreground := clPurple;
  Result.CommentAttri.Foreground := clGreen;
  Result.CommentAttri.Style := [fsItalic];
  Result.StringAttri.Foreground := clMaroon;
  Result.NumberAttri.Foreground := clBlue;
end;

{ TEditorTab }

procedure TEditorTab.SetModified(V: Boolean);
begin
  if FModified = V then Exit;
  FModified := V;
  UpdateCaption;
  if Assigned(OnModifiedChange) then OnModifiedChange(Self);
end;

procedure TEditorTab.UpdateCaption;
begin
  if FModified then Caption := BaseCaption + ' *' else Caption := BaseCaption;
end;

function TEditorTab.Save: Boolean;
begin
  Modified := False;
  Result := True;
end;

{ TSourceTab }

constructor TSourceTab.CreateFor(APages: TPageControl; const AFile: string; HL: TSynCustomHighlighter);
var
  HiAll: TSynEditMarkupHighlightAllCaret;

  procedure AddPop(const ACap: string; AEv: TNotifyEvent);
  var
    MI: TMenuItem;
  begin
    MI := TMenuItem.Create(FPopup);
    MI.Caption := ACap;
    MI.OnClick := AEv;
    FPopup.Items.Add(MI);
  end;

begin
  inherited Create(APages);
  PageControl := APages;
  Kind := ekSource;
  FileName := AFile;
  Key := 'src:' + LowerCase(AFile);
  BaseCaption := ExtractFileName(AFile);
  Edit := TSynEdit.Create(Self);
  Edit.Parent := Self;
  Edit.Align := alClient;
  Edit.Highlighter := HL;
  Edit.Font.Name := 'Consolas';
  Edit.Font.Size := 10;
  Edit.TabWidth := 4;
  Edit.Options := Edit.Options + [eoTabsToSpaces, eoAutoIndent] - [eoSmartTabs];
  Edit.Gutter.Visible := True;
  Edit.RightEdge := 120;
  Edit.OnChange := @EditChange;
  Edit.OnMouseUp := @EditMouseUp;
  Edit.OnMouseDown := @EditMouseDown;
  Edit.OnKeyDown := @EditKeyDown;
  Edit.Options := Edit.Options + [eoRightMouseMovesCursor];
  { auto highlight of every occurrence of the identifier at the cursor }
  HiAll := TSynEditMarkupHighlightAllCaret(Edit.MarkupByClass[TSynEditMarkupHighlightAllCaret]);
  if HiAll <> nil then
  begin
    HiAll.MarkupInfo.Background := $00A0F0FF;
    HiAll.MarkupInfo.FrameColor := $0040B0E0;
    HiAll.WaitTime := 200;
    HiAll.Trim := True;
    HiAll.FullWord := True;
    HiAll.FullWordMaxLen := 0;
    HiAll.IgnoreKeywords := True;
  end;
  FPopup := TPopupMenu.Create(Self);
  AddPop('Find Declaration'#9'Alt+Up / Ctrl+Click', @PopFindDecl);
  AddPop('Go Back'#9'Alt+Left', @PopGoBack);
  AddPop('-', nil);
  AddPop('Undo', @PopUndo);
  AddPop('Redo', @PopRedo);
  AddPop('-', nil);
  AddPop('Cut', @PopCut);
  AddPop('Copy', @PopCopy);
  AddPop('Paste', @PopPaste);
  AddPop('Select All', @PopSelectAll);
  Edit.PopupMenu := FPopup;
  LoadFile;
  UpdateCaption;
end;

procedure TSourceTab.PopFindDecl(Sender: TObject);
begin
  if Assigned(OnFindDeclaration) then OnFindDeclaration(Self);
end;

procedure TSourceTab.PopGoBack(Sender: TObject);
begin
  if Assigned(OnGoBack) then OnGoBack(Self);
end;

procedure TSourceTab.PopUndo(Sender: TObject);
begin
  Edit.Undo;
end;

procedure TSourceTab.PopRedo(Sender: TObject);
begin
  Edit.Redo;
end;

procedure TSourceTab.PopCut(Sender: TObject);
begin
  Edit.CutToClipboard;
end;

procedure TSourceTab.PopCopy(Sender: TObject);
begin
  Edit.CopyToClipboard;
end;

procedure TSourceTab.PopPaste(Sender: TObject);
begin
  Edit.PasteFromClipboard;
end;

procedure TSourceTab.PopSelectAll(Sender: TObject);
begin
  Edit.SelectAll;
end;

procedure TSourceTab.EditMouseUp(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  if (Button = mbLeft) and (ssCtrl in Shift) and not Edit.SelAvail and Assigned(OnFindDeclaration) then
    OnFindDeclaration(Self);
end;

procedure TSourceTab.EditMouseDown(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
var
  P: TPoint;
begin
  { right click: put the caret on the clicked word }
  if Button <> mbRight then Exit;
  P := Edit.PixelsToRowColumn(Point(X, Y));
  Edit.CaretXY := P;
  Edit.BlockBegin := Edit.LogicalCaretXY;
  Edit.BlockEnd := Edit.LogicalCaretXY;
end;

procedure TSourceTab.EditKeyDown(Sender: TObject; var AKey: Word; Shift: TShiftState);
var
  Pt: TPoint;
begin
  if (Shift = [ssAlt]) and (AKey = VK_UP) and Assigned(OnFindDeclaration) then
  begin
    AKey := 0;
    OnFindDeclaration(Self);
  end
  else if (Shift = [ssAlt]) and (AKey = VK_LEFT) and Assigned(OnGoBack) then
  begin
    AKey := 0;
    OnGoBack(Self);
  end
  else if ((Shift = [ssShift]) and (AKey = VK_F10)) or ((Shift = []) and (AKey = VK_APPS)) then
  begin
    AKey := 0;
    Pt := Edit.ClientToScreen(Edit.RowColumnToPixels(Edit.LogicalToPhysicalPos(Edit.LogicalCaretXY)));
    FPopup.PopUp(Pt.X, Pt.Y + Edit.LineHeight);
  end;
end;

procedure TSourceTab.InsertSnippet(const ASnippet: string);
var
  P: TPoint;
  LineTxt, Indent, S, Ln: string;
  L: TStringList;
  I, K, CurLine, CurCol: Integer;
begin
  if Edit.ReadOnly then Exit;
  P := Edit.LogicalCaretXY;
  if (P.Y >= 1) and (P.Y <= Edit.Lines.Count) then LineTxt := Edit.Lines[P.Y - 1] else LineTxt := '';
  { indentation of the following lines = indentation of the caret line (or caret column on an empty line) }
  K := 1;
  while (K <= Length(LineTxt)) and (LineTxt[K] in [' ', #9]) do Inc(K);
  if Trim(LineTxt) = '' then Indent := StringOfChar(' ', Max(P.X - 1, 0))
  else Indent := Copy(LineTxt, 1, K - 1);
  L := TStringList.Create;
  try
    L.Text := ASnippet;
    S := '';
    CurLine := -1;
    CurCol := 0;
    for I := 0 to L.Count - 1 do
    begin
      Ln := L[I];
      if I > 0 then Ln := Indent + Ln;
      K := Pos(#1, Ln);
      if K > 0 then
      begin
        CurLine := I;
        CurCol := K;
        Delete(Ln, K, 1);
      end;
      if I > 0 then S := S + LineEnding;
      S := S + Ln;
    end;
  finally
    L.Free;
  end;
  { a whitespace-only snippet like ' AND ' keeps its blanks }
  if (Trim(ASnippet) <> '') and (Trim(S) = '') then S := ASnippet;
  Edit.BeginUndoBlock;
  try
    Edit.BlockBegin := P;
    Edit.BlockEnd := P;
    Edit.LogicalCaretXY := P;
    Edit.SelText := S;
    if CurLine = 0 then
      Edit.LogicalCaretXY := Point(P.X + CurCol - 1, P.Y)
    else if CurLine > 0 then
      Edit.LogicalCaretXY := Point(CurCol, P.Y + CurLine);
  finally
    Edit.EndUndoBlock;
  end;
  Modified := True;
  if Edit.CaretX < Edit.CharsInWindow then Edit.LeftChar := 1;
  if Edit.CanFocus then Edit.SetFocus;
end;

procedure TSourceTab.DropSnippetAt(X, Y: Integer; const ASnippet: string);
begin
  Edit.CaretXY := Edit.PixelsToRowColumn(Point(X, Y));
  InsertSnippet(ASnippet);
end;

procedure TSourceTab.GotoPos(ALine, ACol, ALen: Integer);
begin
  if ALine < 1 then Exit;
  if ALine > Edit.Lines.Count then ALine := Edit.Lines.Count;
  Edit.TopLine := Max(1, ALine - 5);
  Edit.LogicalCaretXY := Point(Max(ACol, 1), ALine);
  if ALen > 0 then
  begin
    Edit.BlockBegin := Point(Max(ACol, 1), ALine);
    Edit.BlockEnd := Point(Max(ACol, 1) + ALen, ALine);
  end;
  if Edit.CanFocus then Edit.SetFocus;
end;

procedure TSourceTab.EditChange(Sender: TObject);
begin
  Modified := True;
end;

procedure TSourceTab.LoadFile;
var
  S: string;
begin
  if FileExists(FileName) then
  begin
    with TStringList.Create do
    try
      LoadFromFile(FileName);
      S := Text;
    finally
      Free;
    end;
    if Copy(S, 1, 3) = #$EF#$BB#$BF then Delete(S, 1, 3);
    Edit.Lines.Text := S;
  end
  else
    Edit.Lines.Clear;
  Modified := False;
end;

function TSourceTab.Save: Boolean;
begin
  ForceDirectories(ExtractFileDir(FileName));
  Edit.Lines.SaveToFile(FileName);
  Modified := False;
  Result := True;
end;

procedure TSourceTab.GotoLine(ALine, ACol: Integer);
begin
  if ALine < 1 then Exit;
  Edit.CaretXY := Point(Max(ACol, 1), ALine);
  Edit.TopLine := Max(1, ALine - 5);
  Edit.SelectLine;
  if Edit.CanFocus then Edit.SetFocus;
end;

procedure TSourceTab.SetTextKeepModified(const S: string);
var
  OldTop: Integer;
begin
  OldTop := Edit.TopLine;
  Edit.BeginUpdate;
  try
    Edit.SelectAll;
    Edit.SelText := S;   // keeps undo history
  finally
    Edit.EndUpdate;
  end;
  Edit.TopLine := OldTop;
  Modified := True;
end;

{ helpers }

function MakeToolbar(AParent: TWinControl): TPanel;
begin
  Result := TPanel.Create(AParent);
  Result.Parent := AParent;
  Result.Align := alTop;
  Result.Height := 34;
  Result.BevelOuter := bvNone;
  Result.ChildSizing.LeftRightSpacing := 4;
  Result.ChildSizing.HorizontalSpacing := 4;
  Result.ChildSizing.TopBottomSpacing := 4;
  Result.ChildSizing.Layout := cclLeftToRightThenTopToBottom;
  Result.ChildSizing.ControlsPerLine := 100;
end;

function MakeButton(AParent: TWinControl; const ACaption: string; AClick: TNotifyEvent): TButton;
begin
  Result := TButton.Create(AParent);
  Result.Parent := AParent;
  Result.Caption := ACaption;
  Result.AutoSize := True;
  Result.OnClick := AClick;
end;

function MakeGrid(AParent: TWinControl): TStringGrid;
begin
  Result := TStringGrid.Create(AParent);
  Result.Parent := AParent;
  Result.Align := alClient;
  Result.FixedCols := 0;
  Result.FixedRows := 1;
  Result.RowCount := 1;
  Result.Options := Result.Options + [goEditing, goColSizing, goTabs, goThumbTracking, goAlwaysShowEditor] -
    [goRangeSelect];
  Result.DefaultRowHeight := 22;
  Result.AutoFillColumns := False;
end;

procedure AddCol(G: TStringGrid; const Title: string; W: Integer; const Pick: array of string);
var
  C: TGridColumn;
  I: Integer;
begin
  C := G.Columns.Add;
  C.Title.Caption := Title;
  C.Width := W;
  if Length(Pick) > 0 then
  begin
    C.ButtonStyle := cbsPickList;
    for I := Low(Pick) to High(Pick) do C.PickList.Add(Pick[I]);
  end;
end;

{ TTagsTab }

constructor TTagsTab.CreateFor(APages: TPageControl; AProject: TSclProject; const TypeNames: TStrings);
var
  TB: TPanel;
  C: TGridColumn;
begin
  inherited Create(APages);
  PageControl := APages;
  Kind := ekTags;
  Key := 'tags';
  BaseCaption := 'PLC tags / Symbols';
  FProject := AProject;
  TB := MakeToolbar(Self);
  MakeButton(TB, 'Add tag', @BtnAdd);
  MakeButton(TB, 'Delete tag', @BtnDel);
  MakeButton(TB, 'Save', @BtnSave);
  Grid := MakeGrid(Self);
  AddCol(Grid, 'Name', 170, []);
  AddCol(Grid, 'Data type', 110, ['Bool', 'Byte', 'Word', 'DWord', 'LWord', 'SInt', 'Int', 'DInt', 'LInt',
    'USInt', 'UInt', 'UDInt', 'ULInt', 'Real', 'LReal', 'Time', 'S5Time', 'Char']);
  AddCol(Grid, 'Address', 110, []);
  AddCol(Grid, 'Constant value', 110, []);
  AddCol(Grid, 'Comment', 380, []);
  AddCol(Grid, 'Tag table', 130, []);
  C := Grid.Columns[1];
  if C = nil then;
  Grid.OnSetEditText := @GridEdited;
  LoadFromProject;
  UpdateCaption;
  if TypeNames = nil then;
end;

procedure TTagsTab.LoadFromProject;
var
  I: Integer;
  T: TPlcTag;
begin
  Grid.RowCount := FProject.Tags.Count + 1;
  for I := 0 to FProject.Tags.Count - 1 do
  begin
    T := FProject.Tag(I);
    Grid.Cells[0, I + 1] := T.Name;
    Grid.Cells[1, I + 1] := T.DataType;
    Grid.Cells[2, I + 1] := T.Address;
    Grid.Cells[3, I + 1] := T.Value;
    Grid.Cells[4, I + 1] := T.Comment;
    Grid.Cells[5, I + 1] := T.TableName;
  end;
  Modified := False;
end;

procedure TTagsTab.GridEdited(Sender: TObject; ACol, ARow: Integer; const Value: string);
begin
  Modified := True;
end;

procedure TTagsTab.BtnAdd(Sender: TObject);
var
  R: Integer;
  Tbl: string;
begin
  R := Grid.RowCount;
  Grid.RowCount := R + 1;
  Grid.Cells[0, R] := 'Tag_' + IntToStr(R);
  Grid.Cells[1, R] := 'Bool';
  Grid.Cells[2, R] := '%M0.0';
  if FProject.TagFiles.Count > 0 then Tbl := ChangeFileExt(ExtractFileName(FProject.TagFiles[0]), '')
  else Tbl := 'PLC_Tags';
  Grid.Cells[5, R] := Tbl;
  Grid.Row := R;
  Grid.Col := 0;
  Modified := True;
end;

procedure TTagsTab.BtnDel(Sender: TObject);
begin
  if Grid.Row >= 1 then
  begin
    Grid.DeleteRow(Grid.Row);
    Modified := True;
  end;
end;

procedure TTagsTab.BtnSave(Sender: TObject);
begin
  Save;
end;

function TTagsTab.Save: Boolean;
var
  I, J: Integer;
  T: TPlcTag;
  Tbl: string;
  Found: Boolean;
begin
  FProject.Tags.Clear;
  for I := 1 to Grid.RowCount - 1 do
  begin
    if Trim(Grid.Cells[0, I]) = '' then Continue;
    T := TPlcTag.Create;
    T.Name := Trim(Grid.Cells[0, I]);
    T.DataType := Trim(Grid.Cells[1, I]);
    T.Address := Trim(Grid.Cells[2, I]);
    T.Value := Trim(Grid.Cells[3, I]);
    T.Comment := Grid.Cells[4, I];
    T.TableName := Trim(Grid.Cells[5, I]);
    FProject.Tags.Add(T);
  end;
  { every table name used needs a tag file }
  for I := 0 to FProject.Tags.Count - 1 do
  begin
    Tbl := FProject.Tag(I).TableName;
    if Tbl = '' then
    begin
      if FProject.TagFiles.Count > 0 then Tbl := ChangeFileExt(ExtractFileName(FProject.TagFiles[0]), '')
      else Tbl := 'PLC_Tags';
      FProject.Tag(I).TableName := Tbl;
    end;
    Found := False;
    for J := 0 to FProject.TagFiles.Count - 1 do
      if CompareText(ChangeFileExt(ExtractFileName(FProject.TagFiles[J]), ''), Tbl) = 0 then Found := True;
    if not Found then FProject.TagFiles.Add(Tbl + '.csv');
  end;
  if FProject.TagFiles.Count = 0 then FProject.TagFiles.Add('PLC_Tags.csv');
  FProject.SaveTags;
  FProject.Modified := True;
  Modified := False;
  Result := True;
end;

{ TDeclTab }

constructor TDeclTab.CreateFor(APages: TPageControl; const ABlock, AFile: string; const TypeNames: TStrings;
  AGet: TGetTextEvent; ASet: TSetTextEvent);
var
  TB: TPanel;
  Types: array of string;
  I: Integer;
begin
  inherited Create(APages);
  PageControl := APages;
  Kind := ekDecl;
  BlockName := ABlock;
  FileName := AFile;
  Key := 'decl:' + LowerCase(ABlock);
  BaseCaption := 'Interface: ' + ABlock;
  OnGetText := AGet;
  OnSetText := ASet;
  TB := MakeToolbar(Self);
  MakeButton(TB, 'Add', @BtnAdd);
  MakeButton(TB, 'Delete', @BtnDel);
  MakeButton(TB, 'Up', @BtnUp);
  MakeButton(TB, 'Down', @BtnDown);
  MakeButton(TB, 'Apply to source', @BtnApply);
  MakeButton(TB, 'Reload from source', @BtnReload);
  FInfoLabel := TLabel.Create(TB);
  FInfoLabel.Parent := TB;
  FInfoLabel.Layout := tlCenter;
  Grid := MakeGrid(Self);
  AddCol(Grid, 'Section', 90, SECTION_LIST);
  AddCol(Grid, 'Name', 170, []);
  SetLength(Types, 0);
  for I := 0 to High(ElementaryTypeNames) do
  begin
    SetLength(Types, Length(Types) + 1);
    Types[High(Types)] := ElementaryTypeNames[I];
  end;
  if TypeNames <> nil then
    for I := 0 to TypeNames.Count - 1 do
    begin
      SetLength(Types, Length(Types) + 1);
      Types[High(Types)] := '"' + TypeNames[I] + '"';
    end;
  AddCol(Grid, 'Data type', 200, Types);
  AddCol(Grid, 'Start value', 110, []);
  AddCol(Grid, 'Retain', 90, ['', 'Retain', 'Non-retain']);
  AddCol(Grid, 'Comment', 380, []);
  Grid.OnSetEditText := @GridEdited;
  Reload;
  UpdateCaption;
end;

procedure TDeclTab.Reload;
var
  Rows: TDeclRowArray;
  Msg: string;
  I: Integer;
begin
  Grid.RowCount := 1;
  if not LoadDeclRows(OnGetText(FileName), BlockName, Rows, FInfo, Msg) then
  begin
    FInfoLabel.Caption := '  ' + Msg;
    Grid.Enabled := not FInfo.IsInstanceDB;
    Modified := False;
    Exit;
  end;
  FInfoLabel.Caption := Format('  %s  (%s)', [UnitKindNames[FInfo.Kind], ExtractFileName(FileName)]);
  Grid.RowCount := Length(Rows) + 1;
  for I := 0 to High(Rows) do
  begin
    Grid.Cells[0, I + 1] := Rows[I].Section;
    Grid.Cells[1, I + 1] := Rows[I].Name;
    Grid.Cells[2, I + 1] := Rows[I].TypeText;
    Grid.Cells[3, I + 1] := Rows[I].InitText;
    Grid.Cells[4, I + 1] := Rows[I].Retain;
    Grid.Cells[5, I + 1] := Rows[I].Comment;
  end;
  Modified := False;
end;

procedure TDeclTab.GridEdited(Sender: TObject; ACol, ARow: Integer; const Value: string);
begin
  Modified := True;
end;

procedure TDeclTab.BtnAdd(Sender: TObject);
var
  R: Integer;
  Secs: TStringArray;
begin
  R := Grid.RowCount;
  Grid.RowCount := R + 1;
  Secs := AllowedSections(FInfo.Kind, FInfo.UsesStruct);
  if (Grid.Row >= 1) and (Grid.Row < R) then Grid.Cells[0, R] := Grid.Cells[0, Grid.Row]
  else Grid.Cells[0, R] := Secs[0];
  Grid.Cells[1, R] := 'NewVar' + IntToStr(R);
  Grid.Cells[2, R] := 'Int';
  Grid.Row := R;
  Grid.Col := 1;
  Modified := True;
end;

procedure TDeclTab.BtnDel(Sender: TObject);
begin
  if Grid.Row >= 1 then
  begin
    Grid.DeleteRow(Grid.Row);
    Modified := True;
  end;
end;

procedure TDeclTab.SwapRows(A, B: Integer);
var
  C: Integer;
  S: string;
begin
  for C := 0 to Grid.ColCount - 1 do
  begin
    S := Grid.Cells[C, A];
    Grid.Cells[C, A] := Grid.Cells[C, B];
    Grid.Cells[C, B] := S;
  end;
  Modified := True;
end;

procedure TDeclTab.BtnUp(Sender: TObject);
begin
  if Grid.Row > 1 then
  begin
    SwapRows(Grid.Row, Grid.Row - 1);
    Grid.Row := Grid.Row - 1;
  end;
end;

procedure TDeclTab.BtnDown(Sender: TObject);
begin
  if (Grid.Row >= 1) and (Grid.Row < Grid.RowCount - 1) then
  begin
    SwapRows(Grid.Row, Grid.Row + 1);
    Grid.Row := Grid.Row + 1;
  end;
end;

procedure TDeclTab.BtnApply(Sender: TObject);
begin
  Save;
end;

procedure TDeclTab.BtnReload(Sender: TObject);
begin
  if Modified and (MessageDlg('Discard the changes in the table?', mtConfirmation, [mbYes, mbNo], 0) <> mrYes) then
    Exit;
  Reload;
end;

function TDeclTab.Save: Boolean;
var
  Rows: TDeclRowArray;
  I, N: Integer;
  NewSrc, Msg: string;
  Secs: TStringArray;
  Ok: Boolean;
  J: Integer;
begin
  Result := False;
  SetLength(Rows, Grid.RowCount - 1);
  N := 0;
  Secs := AllowedSections(FInfo.Kind, FInfo.UsesStruct);
  for I := 1 to Grid.RowCount - 1 do
  begin
    if (Trim(Grid.Cells[1, I]) = '') and (Trim(Grid.Cells[2, I]) = '') then Continue;
    Rows[N].Section := Trim(Grid.Cells[0, I]);
    Ok := False;
    for J := 0 to High(Secs) do
      if SameText(Secs[J], Rows[N].Section) then Ok := True;
    if not Ok then
    begin
      MessageDlg(Format('Row %d: section "%s" is not allowed here (allowed: %s)',
        [I, Rows[N].Section, string.Join(', ', Secs)]), mtError, [mbOK], 0);
      Exit;
    end;
    Rows[N].Name := Trim(Grid.Cells[1, I]);
    Rows[N].TypeText := Trim(Grid.Cells[2, I]);
    Rows[N].InitText := Trim(Grid.Cells[3, I]);
    Rows[N].Retain := Trim(Grid.Cells[4, I]);
    Rows[N].Comment := Trim(Grid.Cells[5, I]);
    Inc(N);
  end;
  SetLength(Rows, N);
  if not ApplyDeclRows(OnGetText(FileName), BlockName, Rows, NewSrc, Msg) then
  begin
    MessageDlg(Msg, mtError, [mbOK], 0);
    Exit;
  end;
  OnSetText(FileName, NewSrc);
  Modified := False;
  Result := True;
end;

{ TGridViewTab }

constructor TGridViewTab.CreateFor(APages: TPageControl; const ACaption: string; const Headers: array of string);
var
  TB: TPanel;
  L: TLabel;
  I: Integer;
begin
  inherited Create(APages);
  PageControl := APages;
  Kind := ekView;
  Key := 'view:' + LowerCase(ACaption);
  BaseCaption := ACaption;
  FRows := TList.Create;
  TB := MakeToolbar(Self);
  L := TLabel.Create(TB);
  L.Parent := TB;
  L.Caption := 'Filter:';
  L.Layout := tlCenter;
  FFilter := TEdit.Create(TB);
  FFilter.Parent := TB;
  FFilter.Width := 260;
  FFilter.OnChange := @FilterChange;
  FCount := TLabel.Create(TB);
  FCount.Parent := TB;
  FCount.Layout := tlCenter;
  Grid := MakeGrid(Self);
  Grid.Options := Grid.Options - [goEditing, goAlwaysShowEditor] + [goRowSelect];
  Grid.OnDblClick := @GridDblClick;
  for I := Low(Headers) to High(Headers) do AddCol(Grid, Headers[I], 120, []);
  UpdateCaption;
end;

destructor TGridViewTab.Destroy;
begin
  ClearRows;
  FRows.Free;
  inherited;
end;

type
  TRowRec = class
    Cells: TStringArray;
  end;

procedure TGridViewTab.ClearRows;
var
  I: Integer;
begin
  for I := 0 to FRows.Count - 1 do TObject(FRows[I]).Free;
  FRows.Clear;
end;

procedure TGridViewTab.AddRow(const Cells: array of string);
var
  R: TRowRec;
  I: Integer;
begin
  R := TRowRec.Create;
  SetLength(R.Cells, Length(Cells));
  for I := 0 to High(Cells) do R.Cells[I] := Cells[I];
  FRows.Add(R);
end;

procedure TGridViewTab.Refill;
var
  I, J, N: Integer;
  F: string;
  R: TRowRec;
  Match: Boolean;
begin
  F := LowerCase(Trim(FFilter.Text));
  Grid.BeginUpdate;
  try
    Grid.RowCount := FRows.Count + 1;
    N := 0;
    for I := 0 to FRows.Count - 1 do
    begin
      R := TRowRec(FRows[I]);
      Match := F = '';
      if not Match then
        for J := 0 to High(R.Cells) do
          if Pos(F, LowerCase(R.Cells[J])) > 0 then
          begin
            Match := True;
            Break;
          end;
      if not Match then Continue;
      Inc(N);
      for J := 0 to Min(High(R.Cells), Grid.ColCount - 1) do Grid.Cells[J, N] := R.Cells[J];
      Grid.Objects[0, N] := R;
    end;
    Grid.RowCount := N + 1;
  finally
    Grid.EndUpdate;
  end;
  FCount.Caption := Format('  %d of %d', [N, FRows.Count]);
  Grid.AutoSizeColumns;
end;

procedure TGridViewTab.FilterChange(Sender: TObject);
begin
  Refill;
end;

procedure TGridViewTab.GridDblClick(Sender: TObject);
var
  R: TObject;
begin
  if (Grid.Row < 1) or not Assigned(OnOpenRow) then Exit;
  R := Grid.Objects[0, Grid.Row];
  if R is TRowRec then OnOpenRow(TRowRec(R).Cells);
end;

{ TTextTab }

constructor TTextTab.CreateFor(APages: TPageControl; const ACaption: string; HL: TSynCustomHighlighter);
begin
  inherited Create(APages);
  PageControl := APages;
  Kind := ekText;
  Key := 'text:' + LowerCase(ACaption);
  BaseCaption := ACaption;
  Edit := TSynEdit.Create(Self);
  Edit.Parent := Self;
  Edit.Align := alClient;
  Edit.ReadOnly := True;
  Edit.Font.Name := 'Consolas';
  Edit.Font.Size := 10;
  Edit.Highlighter := HL;
  UpdateCaption;
end;

end.
