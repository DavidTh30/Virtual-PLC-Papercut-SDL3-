{ SCL Studio - main window }
unit sclide_main;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, contnrs, IniFiles, Forms, Controls, Graphics, Dialogs, Menus, ComCtrls, ExtCtrls, StdCtrls,
  LCLType, LCLIntf, SynEdit, SynEditTypes, SynHighlighterAny,
  scl_base, scl_types, scl_ast, scl_project, scl_vmformat, scl_compiler, scl_declgen, scl_navigate,
  sclide_editors, sclide_newblock, sclide_elements;

type
  TNodeKind = (nkProject, nkTagsRoot, nkTagTable, nkTypesRoot, nkBlocksRoot, nkBlock, nkSourcesRoot, nkSource);

  TNodeInfo = class
  public
    Kind: TNodeKind;
    FileName: string;
    BlockName: string;
    Line: Integer;
    UKind: TUnitKind;
  end;

  TMsgInfo = class
  public
    FileName: string;
    Line, Col: Integer;
  end;

  TMainForm = class(TForm)
  private
    FProject: TSclProject;
    FCompiler: TSclCompiler;
    FHL: TSynAnySyn;
    FTree: TTreeView;
    FPages: TPageControl;
    FMsgs: TListBox;
    FStatus: TStatusBar;
    FCpuBox: TComboBox;
    FNodeInfos: TObjectList;
    FMsgInfos: TObjectList;
    FTreeMenu: TPopupMenu;
    FFind: TFindDialog;
    FLastCompileOk: Boolean;
    FNavHistory: TStringList;
    FRecentProj, FRecentFiles: TStringList;
    FMiRecentProj, FMiRecentFiles: TMenuItem;
    procedure LoadRecent;
    procedure SaveRecent;
    procedure AddRecent(L: TStringList; const FN: string);
    procedure RebuildRecentMenus;
    procedure RecentProjClick(Sender: TObject);
    procedure RecentFileClick(Sender: TObject);
    procedure ClearRecentClick(Sender: TObject);
  private
    FLeftPanel: TPanel;
    FLeftSplit: TSplitter;
    FElements: TElementsPanel;
    FRightSplit: TSplitter;
    FMiTree, FMiElems: TMenuItem;
    procedure FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure MToggleTree(Sender: TObject);
    procedure MToggleElements(Sender: TObject);
    procedure ShowTreePanel(AShow: Boolean);
    procedure ShowElementsPanel(AShow: Boolean);
    procedure ElementsClosed(Sender: TObject);
    procedure TreeClosed(Sender: TObject);
    procedure InsertSnippetAtCaret(const Snippet: string);
    procedure EditorDragOver(Sender, Source: TObject; X, Y: Integer; State: TDragState; var Accept: Boolean);
    procedure EditorDragDrop(Sender, Source: TObject; X, Y: Integer);
    procedure SelectTreeFile(const AFile: string);
    procedure SelectTreeTags;
    procedure SrcFindDeclaration(Sender: TObject);
    procedure SrcGoBack(Sender: TObject);
    procedure MFindDeclaration(Sender: TObject);
    procedure MGoBack(Sender: TObject);
    procedure PushNav(T: TSourceTab);
    procedure SelectTagRow(const AName: string);
    procedure BuildUI;
    procedure BuildMenu;
    procedure BuildToolbar(AParent: TWinControl);
    function AddItem(AParent: TMenuItem; const ACaption: string; AClick: TNotifyEvent; AKey: TShortCut = 0): TMenuItem;
    { project }
    procedure LoadProject(const FN: string);
    function SaveAll: Boolean;
    function ConfirmSave: Boolean;
    procedure UpdateTitle;
    procedure RebuildTree;
    function RunCompile(WriteOutput: Boolean): Boolean;
    procedure ShowDiags;
    procedure SetStatus(const S: string);
    function TypeNameList: TStringList;
    { editors }
    function FindTab(const AKey: string): TEditorTab;
    function OpenSource(const FN: string): TSourceTab;
    procedure OpenTags;
    procedure OpenDecl(const ABlock, AFile: string);
    function CurrentSource: TSourceTab;
    function GetSourceText(const AFile: string): string;
    procedure SetSourceText(const AFile, AText: string);
    function CompilerGetSource(const FileName: string; out AText: string): Boolean;
    procedure TabModified(Sender: TObject);
    procedure OpenVarRow(const Row: TStringArray);
    procedure OpenElementRow(const Row: TStringArray);
    procedure GotoBlock(const AName: string);
    { events }
    procedure MNewProject(Sender: TObject);
    procedure MOpenProject(Sender: TObject);
    procedure MSaveAll(Sender: TObject);
    procedure MAddSource(Sender: TObject);
    procedure MNewSource(Sender: TObject);
    procedure MImportTags(Sender: TObject);
    procedure MNewBlock(Sender: TObject);
    procedure MExit(Sender: TObject);
    procedure MCloseTab(Sender: TObject);
    procedure MFind(Sender: TObject);
    procedure MFindNext(Sender: TObject);
    procedure MUndo(Sender: TObject);
    procedure MRedo(Sender: TObject);
    procedure MCompile(Sender: TObject);
    procedure MBuild(Sender: TObject);
    procedure MOpenOutput(Sender: TObject);
    procedure MViewTags(Sender: TObject);
    procedure MViewVars(Sender: TObject);
    procedure MViewElements(Sender: TObject);
    procedure MViewListing(Sender: TObject);
    procedure MBlockNumbers(Sender: TObject);
    procedure MAbout(Sender: TObject);
    procedure CpuChange(Sender: TObject);
    procedure TreeDblClick(Sender: TObject);
    procedure TreeOpenInterface(Sender: TObject);
    procedure TreeSetNumber(Sender: TObject);
    procedure TreeRemoveSource(Sender: TObject);
    procedure TreeMenuPopup(Sender: TObject);
    procedure TreeKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure MsgDblClick(Sender: TObject);
    procedure PagesCloseTab(Sender: TObject);
    procedure FindDialogFind(Sender: TObject);
    procedure FormCloseQuery(Sender: TObject; var CanClose: Boolean);
    procedure FormDropFiles(Sender: TObject; const FileNames: array of string);
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
  end;

var
  MainForm: TMainForm;

implementation

const
  APP_NAME = 'SCL Studio';

{ ---------------------------------------------------------------- construction }

constructor TMainForm.Create(AOwner: TComponent);
begin
  inherited CreateNew(AOwner, 0);
  FProject := TSclProject.Create;
  FCompiler := TSclCompiler.Create(FProject);
  FCompiler.OnGetSource := @CompilerGetSource;
  FNodeInfos := TObjectList.Create(True);
  FMsgInfos := TObjectList.Create(True);
  FNavHistory := TStringList.Create;
  FRecentProj := TStringList.Create;
  FRecentFiles := TStringList.Create;
  FHL := CreateSclHighlighter(Self);
  Caption := APP_NAME;
  Width := 1280;
  Height := 820;
  Position := poScreenCenter;
  AllowDropFiles := True;
  OnDropFiles := @FormDropFiles;
  OnCloseQuery := @FormCloseQuery;
  KeyPreview := True;
  Application.AddOnKeyDownBeforeHandler(@FormKeyDown);
  BuildUI;
  BuildMenu;
  LoadRecent;
  ActiveControl := FTree;
  UpdateTitle;
  RebuildTree;
  if (ParamCount > 0) and FileExists(ParamStr(1)) then LoadProject(ParamStr(1));
end;

destructor TMainForm.Destroy;
begin
  Application.RemoveOnKeyDownBeforeHandler(@FormKeyDown);
  FCompiler.Free;
  FProject.Free;
  FNodeInfos.Free;
  FMsgInfos.Free;
  FNavHistory.Free;
  FRecentProj.Free;
  FRecentFiles.Free;
  inherited Destroy;
end;

function TMainForm.AddItem(AParent: TMenuItem; const ACaption: string; AClick: TNotifyEvent;
  AKey: TShortCut): TMenuItem;
begin
  Result := TMenuItem.Create(Self);
  Result.Caption := ACaption;
  Result.OnClick := AClick;
  Result.ShortCut := AKey;
  AParent.Add(Result);
end;

procedure TMainForm.BuildMenu;
var
  M: TMainMenu;
  F, E, P, B, V, H: TMenuItem;
begin
  M := TMainMenu.Create(Self);
  Menu := M;
  F := TMenuItem.Create(Self); F.Caption := '&File'; M.Items.Add(F);
  AddItem(F, '&New project...', @MNewProject);
  AddItem(F, '&Open project...', @MOpenProject, ShortCut(VK_O, [ssCtrl]));
  AddItem(F, '&Save all', @MSaveAll, ShortCut(VK_S, [ssCtrl]));
  AddItem(F, '-', nil);
  FMiRecentProj := AddItem(F, 'Recent &projects', nil);
  FMiRecentFiles := AddItem(F, 'Recent &files', nil);
  AddItem(F, '-', nil);
  AddItem(F, 'New SCL source file...', @MNewSource);
  AddItem(F, 'Add existing SCL source...', @MAddSource);
  AddItem(F, 'Import tag table (CSV)...', @MImportTags);
  AddItem(F, '-', nil);
  AddItem(F, 'Close tab', @MCloseTab, ShortCut(VK_W, [ssCtrl]));
  AddItem(F, 'E&xit', @MExit);

  E := TMenuItem.Create(Self); E.Caption := '&Edit'; M.Items.Add(E);
  AddItem(E, '&Undo', @MUndo, ShortCut(VK_Z, [ssCtrl]));
  AddItem(E, '&Redo', @MRedo, ShortCut(VK_Y, [ssCtrl]));
  AddItem(E, '-', nil);
  AddItem(E, '&Find...', @MFind, ShortCut(VK_F, [ssCtrl]));
  AddItem(E, 'Find &next', @MFindNext, ShortCut(VK_F3, []));
  AddItem(E, '-', nil);
  AddItem(E, 'Find &Declaration  (Alt+Up / Ctrl+Click)', @MFindDeclaration);
  AddItem(E, '&Go Back  (Alt+Left)', @MGoBack);

  P := TMenuItem.Create(Self); P.Caption := '&PLC'; M.Items.Add(P);
  AddItem(P, 'Add new &block...', @MNewBlock, ShortCut(VK_N, [ssCtrl]));
  AddItem(P, 'PLC &tags / symbols', @MViewTags, ShortCut(VK_T, [ssCtrl]));
  AddItem(P, 'Block &numbers...', @MBlockNumbers);

  B := TMenuItem.Create(Self); B.Caption := '&Build'; M.Items.Add(B);
  AddItem(B, '&Compile (check)', @MCompile, ShortCut(VK_F7, []));
  AddItem(B, '&Build image for Virtual PLC', @MBuild, ShortCut(VK_F9, []));
  AddItem(B, '&Open output folder', @MOpenOutput);

  V := TMenuItem.Create(Self); V.Caption := '&View'; M.Items.Add(V);
  AddItem(V, 'All &variables', @MViewVars, ShortCut(VK_F11, []));
  AddItem(V, 'All &elements', @MViewElements, ShortCut(VK_F12, []));
  AddItem(V, '&Listing (bytecode + memory map)', @MViewListing);
  AddItem(V, '-', nil);
  FMiTree := AddItem(V, '&Project tree panel'#9'Alt+1', @MToggleTree);
  FMiTree.Checked := True;
  FMiElems := AddItem(V, '&SCL elements panel'#9'Alt+2', @MToggleElements);
  FMiElems.Checked := True;

  H := TMenuItem.Create(Self); H.Caption := '&Help'; M.Items.Add(H);
  AddItem(H, '&About', @MAbout);
end;

procedure TMainForm.BuildToolbar(AParent: TWinControl);
var
  TB: TPanel;
  L: TLabel;

  procedure Btn(const C, Hint: string; Ev: TNotifyEvent);
  var
    B: TButton;
  begin
    B := TButton.Create(TB);
    B.Parent := TB;
    B.Caption := C;
    B.Hint := Hint;
    B.ShowHint := True;
    B.AutoSize := True;
    B.OnClick := Ev;
  end;

begin
  TB := TPanel.Create(Self);
  TB.Parent := AParent;
  TB.Align := alTop;
  TB.Height := 36;
  TB.BevelOuter := bvNone;
  TB.ChildSizing.LeftRightSpacing := 6;
  TB.ChildSizing.TopBottomSpacing := 5;
  TB.ChildSizing.HorizontalSpacing := 4;
  TB.ChildSizing.Layout := cclLeftToRightThenTopToBottom;
  TB.ChildSizing.ControlsPerLine := 100;
  Btn('New project', 'Create a new SCL project', @MNewProject);
  Btn('Open', 'Open a project (Ctrl+O)', @MOpenProject);
  Btn('Save all', 'Save all files (Ctrl+S)', @MSaveAll);
  Btn('New block', 'Add OB / FB / FC / DB / UDT (Ctrl+N)', @MNewBlock);
  Btn('Tags', 'PLC tags / symbol table (Ctrl+T)', @MViewTags);
  Btn('Compile', 'Check syntax and types (F7)', @MCompile);
  Btn('Build', 'Compile and write the Virtual PLC image (F9)', @MBuild);
  Btn('Variables', 'All variables (F11)', @MViewVars);
  Btn('All elements', 'All elements (F12)', @MViewElements);
  Btn('Project tree', 'Show / hide the project tree panel (Alt+1)', @MToggleTree);
  Btn('SCL elements', 'Show / hide the SCL elements panel (Alt+2)', @MToggleElements);
  L := TLabel.Create(TB);
  L.Parent := TB;
  L.Caption := '   CPU:';
  L.Layout := tlCenter;
  FCpuBox := TComboBox.Create(TB);
  FCpuBox.Parent := TB;
  FCpuBox.Style := csDropDownList;
  FCpuBox.Items.Add('S7-300');
  FCpuBox.Items.Add('S7-400');
  FCpuBox.Items.Add('S7-1200');
  FCpuBox.Items.Add('S7-1500');
  FCpuBox.ItemIndex := 2;
  FCpuBox.Width := 100;
  FCpuBox.OnChange := @CpuChange;
end;

procedure TMainForm.BuildUI;
var
  PLeft, PCenter, Head: TPanel;
  HL: TLabel;
  HB: TButton;
  Sp1, Sp2: TSplitter;
  MI: TMenuItem;
begin
  BuildToolbar(Self);
  FStatus := TStatusBar.Create(Self);
  FStatus.Parent := Self;
  FStatus.SimplePanel := True;

  PLeft := TPanel.Create(Self);
  PLeft.Parent := Self;
  PLeft.Align := alLeft;
  PLeft.Width := 290;
  PLeft.BevelOuter := bvNone;
  FLeftPanel := PLeft;
  Head := TPanel.Create(Self);
  Head.Parent := PLeft;
  Head.Align := alTop;
  Head.Height := 26;
  Head.BevelOuter := bvNone;
  Head.Color := clBtnShadow;
  Head.ParentBackground := False;
  HL := TLabel.Create(Head);
  HL.Parent := Head;
  HL.Align := alClient;
  HL.Layout := tlCenter;
  HL.Caption := '  Project';
  HL.Font.Style := [fsBold];
  HL.Font.Color := clWhite;
  HB := TButton.Create(Head);
  HB.Parent := Head;
  HB.Align := alRight;
  HB.Width := 26;
  HB.Caption := 'x';
  HB.Hint := 'Close panel (Alt+1)';
  HB.ShowHint := True;
  HB.OnClick := @TreeClosed;
  FTree := TTreeView.Create(Self);
  FTree.Parent := PLeft;
  FTree.Align := alClient;
  FTree.ReadOnly := True;
  FTree.OnDblClick := @TreeDblClick;
  FTree.OnKeyDown := @TreeKeyDown;
  FTree.HideSelection := False;
  FTree.RightClickSelect := True;
  { strong selection colour also when the tree has no focus (Find Declaration across files) }
  FTree.Options := FTree.Options - [tvoThemedDraw];
  FTree.SelectionColor := clHighlight;
  FTree.SelectionFontColor := clHighlightText;
  FTree.SelectionFontColorUsed := True;
  FTreeMenu := TPopupMenu.Create(Self);
  FTreeMenu.OnPopup := @TreeMenuPopup;
  MI := TMenuItem.Create(Self); MI.Caption := 'Open'; MI.OnClick := @TreeDblClick; FTreeMenu.Items.Add(MI);
  MI := TMenuItem.Create(Self); MI.Caption := 'Edit interface / members'; MI.OnClick := @TreeOpenInterface; FTreeMenu.Items.Add(MI);
  MI := TMenuItem.Create(Self); MI.Caption := 'Set block number...'; MI.OnClick := @TreeSetNumber; FTreeMenu.Items.Add(MI);
  MI := TMenuItem.Create(Self); MI.Caption := 'Remove source from project'; MI.OnClick := @TreeRemoveSource; FTreeMenu.Items.Add(MI);
  MI := TMenuItem.Create(Self); MI.Caption := '-'; FTreeMenu.Items.Add(MI);
  MI := TMenuItem.Create(Self); MI.Caption := 'Add new block...'; MI.OnClick := @MNewBlock; FTreeMenu.Items.Add(MI);
  FTree.PopupMenu := FTreeMenu;

  Sp1 := TSplitter.Create(Self);
  Sp1.Parent := Self;
  Sp1.Align := alLeft;
  Sp1.Left := PLeft.Width + 1;
  FLeftSplit := Sp1;

  FElements := TElementsPanel.Create(Self);
  FElements.Parent := Self;
  FElements.Align := alRight;
  FElements.OnInsertSnippet := @InsertSnippetAtCaret;
  FElements.OnClosePanel := @ElementsClosed;
  FRightSplit := TSplitter.Create(Self);
  FRightSplit.Parent := Self;
  FRightSplit.Align := alRight;
  FRightSplit.Left := FElements.Left - 1;

  PCenter := TPanel.Create(Self);
  PCenter.Parent := Self;
  PCenter.Align := alClient;
  PCenter.BevelOuter := bvNone;

  FMsgs := TListBox.Create(Self);
  FMsgs.Parent := PCenter;
  FMsgs.Align := alBottom;
  FMsgs.Height := 150;
  FMsgs.OnDblClick := @MsgDblClick;
  FMsgs.Font.Name := 'Consolas';

  Sp2 := TSplitter.Create(Self);
  Sp2.Parent := PCenter;
  Sp2.Align := alBottom;
  Sp2.Top := 0;

  FPages := TPageControl.Create(Self);
  FPages.Parent := PCenter;
  FPages.Align := alClient;
  FPages.Options := FPages.Options + [nboShowCloseButtons];
  FPages.OnCloseTabClicked := @PagesCloseTab;

  FFind := TFindDialog.Create(Self);
  FFind.OnFind := @FindDialogFind;
end;

{ ---------------------------------------------------------------- helpers }

procedure TMainForm.SetStatus(const S: string);
begin
  FStatus.SimpleText := S;
end;

procedure TMainForm.UpdateTitle;
begin
  if FProject.FileName = '' then
    Caption := APP_NAME + ' - (no project)'
  else
    Caption := Format('%s - %s [%s]  %s', [APP_NAME, FProject.Name, CpuNames[FProject.Cpu], FProject.FileName]);
  FCpuBox.ItemIndex := Ord(FProject.Cpu);
end;

function TMainForm.FindTab(const AKey: string): TEditorTab;
var
  I: Integer;
begin
  for I := 0 to FPages.PageCount - 1 do
    if (FPages.Pages[I] is TEditorTab) and (TEditorTab(FPages.Pages[I]).Key = AKey) then
      Exit(TEditorTab(FPages.Pages[I]));
  Result := nil;
end;

function TMainForm.OpenSource(const FN: string): TSourceTab;
var
  T: TEditorTab;
begin
  T := FindTab('src:' + LowerCase(ExpandFileName(FN)));
  if T = nil then
  begin
    T := TSourceTab.CreateFor(FPages, ExpandFileName(FN), FHL);
    T.OnModifiedChange := @TabModified;
    TSourceTab(T).OnFindDeclaration := @SrcFindDeclaration;
    TSourceTab(T).OnGoBack := @SrcGoBack;
    TSourceTab(T).Edit.OnDragOver := @EditorDragOver;
    TSourceTab(T).Edit.OnDragDrop := @EditorDragDrop;
    if FileExists(FN) then AddRecent(FRecentFiles, ExpandFileName(FN));
  end;
  FPages.ActivePage := T;
  Result := TSourceTab(T);
end;

procedure TMainForm.OpenTags;
var
  T: TEditorTab;
  L: TStringList;
begin
  T := FindTab('tags');
  if T = nil then
  begin
    L := TypeNameList;
    try
      T := TTagsTab.CreateFor(FPages, FProject, L);
    finally
      L.Free;
    end;
    T.OnModifiedChange := @TabModified;
  end;
  FPages.ActivePage := T;
end;

procedure TMainForm.OpenDecl(const ABlock, AFile: string);
var
  T: TEditorTab;
  L: TStringList;
begin
  T := FindTab('decl:' + LowerCase(ABlock));
  if T = nil then
  begin
    L := TypeNameList;
    try
      T := TDeclTab.CreateFor(FPages, ABlock, AFile, L, @GetSourceText, @SetSourceText);
    finally
      L.Free;
    end;
    T.OnModifiedChange := @TabModified;
  end
  else
    TDeclTab(T).Reload;
  FPages.ActivePage := T;
end;

function TMainForm.CurrentSource: TSourceTab;
begin
  if FPages.ActivePage is TSourceTab then Result := TSourceTab(FPages.ActivePage) else Result := nil;
end;

function TMainForm.GetSourceText(const AFile: string): string;
var
  T: TEditorTab;
begin
  T := FindTab('src:' + LowerCase(ExpandFileName(AFile)));
  if T <> nil then Exit(TSourceTab(T).Edit.Lines.Text);
  if FileExists(AFile) then Result := ReadSourceFile(AFile) else Result := '';
end;

procedure TMainForm.SetSourceText(const AFile, AText: string);
var
  T: TSourceTab;
  Act: TTabSheet;
begin
  Act := FPages.ActivePage;
  T := OpenSource(AFile);
  T.SetTextKeepModified(AText);
  FPages.ActivePage := Act;
  SetStatus('Declaration applied to ' + ExtractFileName(AFile) + ' (not saved yet)');
end;

function TMainForm.CompilerGetSource(const FileName: string; out AText: string): Boolean;
var
  T: TEditorTab;
begin
  T := FindTab('src:' + LowerCase(ExpandFileName(FileName)));
  Result := T <> nil;
  if Result then AText := TSourceTab(T).Edit.Lines.Text else AText := '';
end;

procedure TMainForm.TabModified(Sender: TObject);
begin
  { caption already updated by the tab }
end;

function TMainForm.TypeNameList: TStringList;
var
  I: Integer;
  B: TBlockInfo;
begin
  Result := TStringList.Create;
  for I := 0 to FCompiler.BlockCount - 1 do
  begin
    B := FCompiler.Blocks[I];
    if B.Kind in [ukUDT, ukFB] then Result.Add(B.Name);
  end;
end;

{ ---------------------------------------------------------------- project }

function TMainForm.ConfirmSave: Boolean;
var
  I: Integer;
  Any: Boolean;
  R: TModalResult;
begin
  Any := FProject.Modified;
  for I := 0 to FPages.PageCount - 1 do
    if (FPages.Pages[I] is TEditorTab) and TEditorTab(FPages.Pages[I]).Modified then Any := True;
  if not Any then Exit(True);
  R := MessageDlg('Save changes?', mtConfirmation, [mbYes, mbNo, mbCancel], 0);
  if R = mrCancel then Exit(False);
  if R = mrYes then Exit(SaveAll);
  Result := True;
end;

procedure TMainForm.LoadProject(const FN: string);
begin
  while FPages.PageCount > 0 do FPages.Pages[0].Free;
  try
    FProject.LoadFromFile(FN);
  except
    on E: Exception do
    begin
      MessageDlg('Cannot open project: ' + E.Message, mtError, [mbOK], 0);
      Exit;
    end;
  end;
  UpdateTitle;
  AddRecent(FRecentProj, FProject.FileName);
  RunCompile(False);
  SetStatus('Project loaded: ' + FProject.FileName);
end;

function TMainForm.SaveAll: Boolean;
var
  I: Integer;
  T: TEditorTab;
begin
  Result := True;
  for I := 0 to FPages.PageCount - 1 do
    if FPages.Pages[I] is TEditorTab then
    begin
      T := TEditorTab(FPages.Pages[I]);
      if T.Modified and (T.Kind in [ekSource, ekTags]) then
        if not T.Save then Result := False;
    end;
  if FProject.FileName <> '' then FProject.SaveToFile(FProject.FileName);
  for I := 0 to FPages.PageCount - 1 do
    if (FPages.Pages[I] is TEditorTab) and TEditorTab(FPages.Pages[I]).Modified and
       (TEditorTab(FPages.Pages[I]).Kind = ekDecl) then
      SetStatus('Note: an interface table has changes that are not applied to the source');
end;

procedure TMainForm.RebuildTree;
const
  KindOrder: array[0..4] of TUnitKind = (ukOB, ukFB, ukFC, ukDB, ukUDT);
var
  K0: Integer;
  Root, Tags, Types, Blocks, Srcs, N: TTreeNode;
  I, K: Integer;
  B: TBlockInfo;
  Info: TNodeInfo;
  Tbls: TStringList;
  Order: TList;
  S: string;
  UK: TUnitKind;

  function NewInfo(AKind: TNodeKind): TNodeInfo;
  begin
    Result := TNodeInfo.Create;
    Result.Kind := AKind;
    FNodeInfos.Add(Result);
  end;

begin
  FTree.Items.BeginUpdate;
  try
    FTree.Items.Clear;
    FNodeInfos.Clear;
    if FProject.FileName = '' then
    begin
      FTree.Items.Add(nil, '(no project - File > New / Open)');
      Exit;
    end;
    Root := FTree.Items.AddObject(nil, Format('%s  [%s]', [FProject.Name, CpuNames[FProject.Cpu]]), NewInfo(nkProject));
    Tags := FTree.Items.AddChildObject(Root, Format('PLC tags / Symbols (%d)', [FProject.Tags.Count]), NewInfo(nkTagsRoot));
    Tbls := TStringList.Create;
    try
      Tbls.Sorted := True;
      Tbls.Duplicates := dupIgnore;
      for I := 0 to FProject.Tags.Count - 1 do Tbls.Add(FProject.Tag(I).TableName);
      for I := 0 to Tbls.Count - 1 do
        FTree.Items.AddChildObject(Tags, Tbls[I], NewInfo(nkTagTable));
    finally
      Tbls.Free;
    end;
    Types := FTree.Items.AddChildObject(Root, 'PLC data types (UDT)', NewInfo(nkTypesRoot));
    Blocks := FTree.Items.AddChildObject(Root, 'Program blocks', NewInfo(nkBlocksRoot));
    Order := TList.Create;
    try
      for K0 := 0 to 4 do
      begin
        UK := KindOrder[K0];
        Order.Clear;
        for I := 0 to FCompiler.BlockCount - 1 do
          if FCompiler.Blocks[I].Kind = UK then Order.Add(FCompiler.Blocks[I]);
        { sort by number }
        for I := 0 to Order.Count - 2 do
          for K := I + 1 to Order.Count - 1 do
            if TBlockInfo(Order[K]).Number < TBlockInfo(Order[I]).Number then Order.Exchange(I, K);
        for I := 0 to Order.Count - 1 do
        begin
          B := TBlockInfo(Order[I]);
          Info := NewInfo(nkBlock);
          Info.FileName := B.U.FileName;
          Info.BlockName := B.Name;
          Info.Line := B.U.Pos.Line;
          Info.UKind := B.Kind;
          if B.Kind = ukUDT then
            N := FTree.Items.AddChildObject(Types, '"' + B.Name + '"', Info)
          else
          begin
            S := Format('%s%d  %s', [B.KindText, B.Number, B.Name]);
            if (B.Kind = ukDB) and (B.DBInstOf <> nil) then S := S + '  [' + B.DBInstOf.Name + ']';
            N := FTree.Items.AddChildObject(Blocks, S, Info);
          end;
          if N = nil then;
        end;
      end;
    finally
      Order.Free;
    end;
    Srcs := FTree.Items.AddChildObject(Root, Format('Source files (%d)', [FProject.Sources.Count]), NewInfo(nkSourcesRoot));
    for I := 0 to FProject.Sources.Count - 1 do
    begin
      Info := NewInfo(nkSource);
      Info.FileName := FProject.AbsPath(FProject.Sources[I]);
      FTree.Items.AddChildObject(Srcs, FProject.Sources[I], Info);
    end;
    Root.Expand(False);
    Blocks.Expand(False);
    Types.Expand(False);
    Tags.Expand(False);
  finally
    FTree.Items.EndUpdate;
  end;
end;

procedure TMainForm.ShowDiags;
var
  I: Integer;
  D: TDiag;
  MI: TMsgInfo;
begin
  FMsgs.Items.BeginUpdate;
  try
    FMsgs.Clear;
    FMsgInfos.Clear;
    for I := 0 to FCompiler.Diags.Count - 1 do
    begin
      D := FCompiler.Diags[I];
      MI := TMsgInfo.Create;
      MI.FileName := D.Pos.FileName;
      MI.Line := D.Pos.Line;
      MI.Col := D.Pos.Col;
      FMsgInfos.Add(MI);
      FMsgs.Items.AddObject(D.ToString, MI);
    end;
    FMsgs.Items.Add(Format('--- %d error(s), %d warning(s)  [%s]', [FCompiler.Diags.ErrorCount,
      FCompiler.Diags.WarningCount, FormatDateTime('hh:nn:ss', Now)]));
  finally
    FMsgs.Items.EndUpdate;
  end;
  FMsgs.TopIndex := 0;
end;

function TMainForm.RunCompile(WriteOutput: Boolean): Boolean;
var
  FN, Base: string;
  L: TStringList;
begin
  Result := False;
  if FProject.FileName = '' then
  begin
    RebuildTree;
    Exit;
  end;
  Screen.Cursor := crHourGlass;
  try
    try
      Result := FCompiler.Compile(True);
    except
      on E: Exception do
      begin
        FCompiler.Diags.Error(NoPos, 'Internal compiler error: ' + E.Message);
        Result := False;
      end;
    end;
    ShowDiags;
    RebuildTree;
    FElements.UpdateProject(FCompiler);
    FLastCompileOk := Result;
    if WriteOutput and Result then
    begin
      FN := FProject.OutputFile;
      FCompiler.SaveImage(FN);
      Base := ChangeFileExt(FN, '');
      L := TStringList.Create;
      try
        L.Text := FCompiler.ListingText;
        L.SaveToFile(Base + '.lst');
        L.Text := FCompiler.MemoryMapText;
        L.SaveToFile(Base + '.map.txt');
      finally
        L.Free;
      end;
      FMsgs.Items.Add(Format('Image written: %s  (%d code blocks, %d data blocks)', [FN,
        FCompiler.Image.Blocks.Count, FCompiler.Image.DataBlocks.Count]));
      SetStatus('Build OK: ' + FN);
    end
    else if Result then
      SetStatus('Compile OK - no errors')
    else
      SetStatus(Format('Compile failed: %d error(s)', [FCompiler.Diags.ErrorCount]));
  finally
    Screen.Cursor := crDefault;
  end;
end;

procedure TMainForm.GotoBlock(const AName: string);
var
  B: TBlockInfo;
begin
  B := FCompiler.FindBlockInfo(AName);
  if (B = nil) or (B.U = nil) then Exit;
  OpenSource(B.U.FileName).GotoLine(B.U.Pos.Line, 1);
end;

{ ---------------------------------------------------------------- recent projects / files }

const
  MAX_RECENT = 10;

function RecentIniName: string;
begin
  Result := IncludeTrailingPathDelimiter(GetAppConfigDir(False)) + 'sclstudio.ini';
end;

procedure TMainForm.LoadRecent;
var
  Ini: TIniFile;
  I: Integer;
  S: string;
begin
  FRecentProj.Clear;
  FRecentFiles.Clear;
  try
    Ini := TIniFile.Create(RecentIniName);
    try
      for I := 1 to MAX_RECENT do
      begin
        S := Ini.ReadString('RecentProjects', 'File' + IntToStr(I), '');
        if S <> '' then FRecentProj.Add(S);
        S := Ini.ReadString('RecentFiles', 'File' + IntToStr(I), '');
        if S <> '' then FRecentFiles.Add(S);
      end;
    finally
      Ini.Free;
    end;
  except
    { no config yet }
  end;
  RebuildRecentMenus;
end;

procedure TMainForm.SaveRecent;
var
  Ini: TIniFile;
  I: Integer;
begin
  try
    ForceDirectories(ExtractFileDir(RecentIniName));
    Ini := TIniFile.Create(RecentIniName);
    try
      Ini.EraseSection('RecentProjects');
      Ini.EraseSection('RecentFiles');
      for I := 0 to FRecentProj.Count - 1 do Ini.WriteString('RecentProjects', 'File' + IntToStr(I + 1), FRecentProj[I]);
      for I := 0 to FRecentFiles.Count - 1 do Ini.WriteString('RecentFiles', 'File' + IntToStr(I + 1), FRecentFiles[I]);
    finally
      Ini.Free;
    end;
  except
    on E: Exception do SetStatus('Cannot save recent list: ' + E.Message);
  end;
end;

procedure TMainForm.AddRecent(L: TStringList; const FN: string);
var
  I: Integer;
begin
  if FN = '' then Exit;
  for I := L.Count - 1 downto 0 do
    if SameText(L[I], FN) then L.Delete(I);
  L.Insert(0, FN);
  while L.Count > MAX_RECENT do L.Delete(L.Count - 1);
  SaveRecent;
  RebuildRecentMenus;
end;

procedure TMainForm.RebuildRecentMenus;

  procedure Fill(Root: TMenuItem; L: TStringList; Click: TNotifyEvent);
  var
    I: Integer;
    MI: TMenuItem;
  begin
    Root.Clear;
    for I := 0 to L.Count - 1 do
    begin
      MI := TMenuItem.Create(Self);
      MI.Caption := Format('&%d  %s', [(I + 1) mod 10, StringReplace(L[I], '&', '&&', [rfReplaceAll])]);
      MI.Tag := I;
      MI.OnClick := Click;
      if not FileExists(L[I]) then MI.Caption := MI.Caption + '   (missing)';
      Root.Add(MI);
    end;
    if L.Count = 0 then
    begin
      MI := TMenuItem.Create(Self);
      MI.Caption := '(empty)';
      MI.Enabled := False;
      Root.Add(MI);
    end
    else
    begin
      MI := TMenuItem.Create(Self);
      MI.Caption := '-';
      Root.Add(MI);
      MI := TMenuItem.Create(Self);
      MI.Caption := 'Clear list';
      if L = FRecentProj then MI.Tag := 1 else MI.Tag := 2;
      MI.OnClick := @ClearRecentClick;
      Root.Add(MI);
    end;
  end;

begin
  if FMiRecentProj = nil then Exit;
  Fill(FMiRecentProj, FRecentProj, @RecentProjClick);
  Fill(FMiRecentFiles, FRecentFiles, @RecentFileClick);
end;

procedure TMainForm.RecentProjClick(Sender: TObject);
var
  FN: string;
begin
  FN := FRecentProj[TMenuItem(Sender).Tag];
  if not FileExists(FN) then
  begin
    if MessageDlg('Project not found:' + LineEnding + FN + LineEnding + LineEnding + 'Remove it from the list?',
      mtWarning, [mbYes, mbNo], 0) = mrYes then
    begin
      FRecentProj.Delete(TMenuItem(Sender).Tag);
      SaveRecent;
      RebuildRecentMenus;
    end;
    Exit;
  end;
  if SameText(FN, FProject.FileName) then Exit;
  if ConfirmSave then LoadProject(FN);
end;

procedure TMainForm.RecentFileClick(Sender: TObject);
var
  FN, Proj: string;
  SR: TSearchRec;
  I: Integer;
  InProj: Boolean;
begin
  FN := FRecentFiles[TMenuItem(Sender).Tag];
  if not FileExists(FN) then
  begin
    if MessageDlg('File not found:' + LineEnding + FN + LineEnding + LineEnding + 'Remove it from the list?',
      mtWarning, [mbYes, mbNo], 0) = mrYes then
    begin
      FRecentFiles.Delete(TMenuItem(Sender).Tag);
      SaveRecent;
      RebuildRecentMenus;
    end;
    Exit;
  end;
  { the file belongs to another project: open the project that lives next to it (if there is exactly one) }
  InProj := False;
  for I := 0 to FProject.Sources.Count - 1 do
    if SameText(FProject.AbsPath(FProject.Sources[I]), FN) then InProj := True;
  if not InProj then
  begin
    Proj := '';
    if FindFirst(IncludeTrailingPathDelimiter(ExtractFileDir(FN)) + '*.sclproj', faAnyFile, SR) = 0 then
    begin
      Proj := IncludeTrailingPathDelimiter(ExtractFileDir(FN)) + SR.Name;
      if FindNext(SR) = 0 then Proj := '';
    end;
    FindClose(SR);
    if (Proj <> '') and not SameText(Proj, FProject.FileName) then
    begin
      if FProject.FileName = '' then
        LoadProject(Proj)
      else if MessageDlg(Format('"%s" belongs to project %s.' + LineEnding + 'Open that project?',
        [ExtractFileName(FN), ExtractFileName(Proj)]), mtConfirmation, [mbYes, mbNo], 0) = mrYes then
      begin
        if not ConfirmSave then Exit;
        LoadProject(Proj);
      end;
    end;
  end;
  OpenSource(FN);
  if FProject.FileName <> '' then SelectTreeFile(FN);
end;

procedure TMainForm.ClearRecentClick(Sender: TObject);
begin
  if TMenuItem(Sender).Tag = 1 then FRecentProj.Clear else FRecentFiles.Clear;
  SaveRecent;
  RebuildRecentMenus;
end;

{ ---------------------------------------------------------------- panels / elements }

procedure TMainForm.ShowTreePanel(AShow: Boolean);
begin
  FLeftPanel.Visible := AShow;
  FLeftSplit.Visible := AShow;
  if AShow then FLeftSplit.Left := FLeftPanel.Left + FLeftPanel.Width + 1;
  FMiTree.Checked := AShow;
end;

procedure TMainForm.ShowElementsPanel(AShow: Boolean);
begin
  FElements.Visible := AShow;
  FRightSplit.Visible := AShow;
  if AShow then FRightSplit.Left := FElements.Left - FRightSplit.Width - 1;
  FMiElems.Checked := AShow;
end;

procedure TMainForm.FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  if Screen.ActiveForm <> Self then Exit;
  if Shift = [ssAlt] then
    if (Key = VK_1) or (Key = VK_NUMPAD1) then
    begin
      MToggleTree(Self);
      Key := 0;
    end
    else if (Key = VK_2) or (Key = VK_NUMPAD2) then
    begin
      MToggleElements(Self);
      Key := 0;
    end;
end;

procedure TMainForm.MToggleTree(Sender: TObject);
begin
  ShowTreePanel(not FLeftPanel.Visible);
end;

procedure TMainForm.MToggleElements(Sender: TObject);
begin
  ShowElementsPanel(not FElements.Visible);
end;

procedure TMainForm.ElementsClosed(Sender: TObject);
begin
  ShowElementsPanel(False);
end;

procedure TMainForm.TreeClosed(Sender: TObject);
begin
  ShowTreePanel(False);
end;

procedure TMainForm.InsertSnippetAtCaret(const Snippet: string);
begin
  if CurrentSource = nil then
  begin
    SetStatus('Open an SCL source first (double click a block in the project tree)');
    Exit;
  end;
  CurrentSource.InsertSnippet(Snippet);
end;

procedure TMainForm.EditorDragOver(Sender, Source: TObject; X, Y: Integer; State: TDragState; var Accept: Boolean);
begin
  Accept := FElements.IsElementDrag(Source) and (Sender is TSynEdit) and not TSynEdit(Sender).ReadOnly;
  if Accept then
  begin
    { show the drop position with the caret }
    TSynEdit(Sender).CaretXY := TSynEdit(Sender).PixelsToRowColumn(Point(X, Y));
    if TSynEdit(Sender).CanFocus then TSynEdit(Sender).SetFocus;
  end;
end;

procedure TMainForm.EditorDragDrop(Sender, Source: TObject; X, Y: Integer);
var
  Ed: TSynEdit;
begin
  if not (FElements.IsElementDrag(Source) and (Sender is TSynEdit)) then Exit;
  Ed := TSynEdit(Sender);
  if Ed.Owner is TSourceTab then
  begin
    TSourceTab(Ed.Owner).DropSnippetAt(X, Y, FElements.DraggedSnippet);
    SetStatus('Inserted: ' + FElements.Tree.Selected.Text);
  end;
end;

procedure TMainForm.SelectTreeFile(const AFile: string);
var
  N: TTreeNode;
begin
  N := FTree.Items.GetFirstNode;
  while N <> nil do
  begin
    if (TObject(N.Data) is TNodeInfo) and (TNodeInfo(N.Data).Kind = nkSource) and
       SameText(ExpandFileName(TNodeInfo(N.Data).FileName), ExpandFileName(AFile)) then
    begin
      N.MakeVisible;
      FTree.Selected := N;
      FTree.Invalidate;
      Exit;
    end;
    N := N.GetNext;
  end;
end;

procedure TMainForm.SelectTreeTags;
var
  N: TTreeNode;
begin
  N := FTree.Items.GetFirstNode;
  while N <> nil do
  begin
    if (TObject(N.Data) is TNodeInfo) and (TNodeInfo(N.Data).Kind = nkTagsRoot) then
    begin
      N.MakeVisible;
      FTree.Selected := N;
      Exit;
    end;
    N := N.GetNext;
  end;
end;

{ ---------------------------------------------------------------- find declaration }

procedure TMainForm.PushNav(T: TSourceTab);
var
  P: TPoint;
begin
  P := T.Edit.LogicalCaretXY;
  FNavHistory.Add(Format('%d|%d|%s', [P.Y, P.X, T.FileName]));
  while FNavHistory.Count > 100 do FNavHistory.Delete(0);
end;

procedure TMainForm.SelectTagRow(const AName: string);
var
  T: TEditorTab;
  R: Integer;
begin
  OpenTags;
  T := FindTab('tags');
  if T = nil then Exit;
  with TTagsTab(T).Grid do
    for R := 1 to RowCount - 1 do
      if SameText(Cells[0, R], AName) then
      begin
        Row := R;
        Col := 0;
        if CanFocus then SetFocus;
        Break;
      end;
end;

procedure TMainForm.SrcFindDeclaration(Sender: TObject);
var
  T, Dst: TSourceTab;
  P: TPoint;
  R: TDeclResult;
  LineTxt: string;
  Col, K: Integer;
begin
  if not (Sender is TSourceTab) or (FProject.FileName = '') then Exit;
  T := TSourceTab(Sender);
  P := T.Edit.LogicalCaretXY;
  if (P.Y < 1) or (P.Y > T.Edit.Lines.Count) then Exit;
  LineTxt := T.Edit.Lines[P.Y - 1];
  try
    FCompiler.Compile(True);
  except
    on E: Exception do
    begin
      SetStatus('Find Declaration: ' + E.Message);
      Exit;
    end;
  end;
  R := FindDeclarationAt(FCompiler, T.FileName, LineTxt, P.Y, P.X);
  if (R.Kind in [dkSource, dkSystem]) and (R.Pos.Line > 0) and FileExists(R.Pos.FileName) then
  begin
    PushNav(T);
    if not SameText(ExpandFileName(R.Pos.FileName), ExpandFileName(T.FileName)) then
      SelectTreeFile(R.Pos.FileName);
    Dst := OpenSource(R.Pos.FileName);
    Col := Max(R.Pos.Col, 1);
    K := 0;
    if R.Pos.Line <= Dst.Edit.Lines.Count then
    begin
      LineTxt := Dst.Edit.Lines[R.Pos.Line - 1];
      K := Pos(LowerCase(R.Name), LowerCase(Copy(LineTxt, Col, MaxInt)));
      if (R.Kind = dkSystem) or (K = 0) then K := 0 else Col := Col + K - 1;
    end;
    if K > 0 then Dst.GotoPos(R.Pos.Line, Col, Length(R.Name)) else Dst.GotoPos(R.Pos.Line, Col, 0);
    SetStatus('Declaration: ' + R.Info);
  end
  else if R.Kind = dkTag then
  begin
    PushNav(T);
    SelectTreeTags;
    SelectTagRow(R.Name);
    SetStatus('Declaration: ' + R.Info);
  end
  else if R.Info <> '' then
  begin
    SetStatus(R.Info);
    if R.Kind = dkNone then Beep;
  end;
end;

procedure TMainForm.SrcGoBack(Sender: TObject);
var
  S: string;
  Parts: TStringArray;
begin
  if FNavHistory.Count = 0 then
  begin
    SetStatus('Navigation history is empty');
    Exit;
  end;
  S := FNavHistory[FNavHistory.Count - 1];
  FNavHistory.Delete(FNavHistory.Count - 1);
  Parts := S.Split(['|'], 3);
  if (Length(Parts) = 3) and FileExists(Parts[2]) then
  begin
    if (CurrentSource = nil) or not SameText(CurrentSource.FileName, Parts[2]) then SelectTreeFile(Parts[2]);
    OpenSource(Parts[2]).GotoPos(StrToIntDef(Parts[0], 1), StrToIntDef(Parts[1], 1), 0);
  end;
end;

procedure TMainForm.MFindDeclaration(Sender: TObject);
begin
  if CurrentSource <> nil then SrcFindDeclaration(CurrentSource);
end;

procedure TMainForm.MGoBack(Sender: TObject);
begin
  SrcGoBack(Sender);
end;

{ ---------------------------------------------------------------- menu: file }

procedure TMainForm.MNewProject(Sender: TObject);
var
  D: TSaveDialog;
  Dir, Main, Tags: string;
  L: TStringList;
begin
  if not ConfirmSave then Exit;
  D := TSaveDialog.Create(Self);
  try
    D.Title := 'New SCL project';
    D.Filter := 'SCL project (*.sclproj)|*.sclproj';
    D.DefaultExt := 'sclproj';
    D.Options := D.Options + [ofOverwritePrompt];
    if not D.Execute then Exit;
    while FPages.PageCount > 0 do FPages.Pages[0].Free;
    FProject.Clear;
    FProject.FileName := D.FileName;
    FProject.Name := ChangeFileExt(ExtractFileName(D.FileName), '');
    FProject.Cpu := TCpuFamily(FCpuBox.ItemIndex);
    Dir := ExtractFileDir(D.FileName);
    Tags := IncludeTrailingPathDelimiter(Dir) + 'PLC_Tags.csv';
    if not FileExists(Tags) then
    begin
      L := TStringList.Create;
      try
        L.Add('Name;Path;Data Type;Logical Address;Comment;Value');
        L.Add('Start_PB;PLC_Tags;Bool;%I0.0;Start push button;');
        L.Add('Motor_Run;PLC_Tags;Bool;%Q0.0;Motor contactor;');
        L.SaveToFile(Tags);
      finally
        L.Free;
      end;
    end;
    FProject.TagFiles.Add('PLC_Tags.csv');
    Main := IncludeTrailingPathDelimiter(Dir) + 'Main.scl';
    if not FileExists(Main) then
    begin
      L := TStringList.Create;
      try
        L.Text := NewBlockTemplate(ukOB, 'Main', '', '', True, FProject.Cpu);
        L.Insert(L.IndexOf('BEGIN') + 1, '    "Motor_Run" := "Start_PB";');
        L.SaveToFile(Main);
      finally
        L.Free;
      end;
    end;
    FProject.Sources.Add('Main.scl');
    FProject.SaveToFile(D.FileName);
    LoadProject(D.FileName);
    OpenSource(Main);
  finally
    D.Free;
  end;
end;

procedure TMainForm.MOpenProject(Sender: TObject);
var
  D: TOpenDialog;
begin
  if not ConfirmSave then Exit;
  D := TOpenDialog.Create(Self);
  try
    D.Filter := 'SCL project (*.sclproj)|*.sclproj|All files|*.*';
    if D.Execute then LoadProject(D.FileName);
  finally
    D.Free;
  end;
end;

procedure TMainForm.MSaveAll(Sender: TObject);
begin
  SaveAll;
  SetStatus('All files saved');
  RunCompile(False);
end;

procedure TMainForm.MAddSource(Sender: TObject);
var
  D: TOpenDialog;
  I: Integer;
  R: string;
begin
  if FProject.FileName = '' then Exit;
  D := TOpenDialog.Create(Self);
  try
    D.Filter := 'SCL source (*.scl)|*.scl|All files|*.*';
    D.Options := D.Options + [ofAllowMultiSelect];
    if not D.Execute then Exit;
    for I := 0 to D.Files.Count - 1 do
    begin
      R := FProject.RelPath(D.Files[I]);
      if FProject.Sources.IndexOf(R) < 0 then FProject.Sources.Add(R);
    end;
    FProject.Modified := True;
    FProject.SaveToFile(FProject.FileName);
    RunCompile(False);
  finally
    D.Free;
  end;
end;

procedure TMainForm.MNewSource(Sender: TObject);
var
  N, FN: string;
begin
  if FProject.FileName = '' then Exit;
  N := 'NewSource';
  if not InputQuery('New SCL source file', 'File name (without .scl):', N) then Exit;
  FN := IncludeTrailingPathDelimiter(FProject.Dir) + ChangeFileExt(N, '.scl');
  if not FileExists(FN) then
    with TStringList.Create do
    try
      Add('// ' + ExtractFileName(FN));
      SaveToFile(FN);
    finally
      Free;
    end;
  if FProject.Sources.IndexOf(FProject.RelPath(FN)) < 0 then FProject.Sources.Add(FProject.RelPath(FN));
  FProject.SaveToFile(FProject.FileName);
  RebuildTree;
  OpenSource(FN);
end;

procedure TMainForm.MImportTags(Sender: TObject);
var
  D: TOpenDialog;
  R: string;
begin
  if FProject.FileName = '' then Exit;
  D := TOpenDialog.Create(Self);
  try
    D.Filter := 'Tag table (*.csv)|*.csv|All files|*.*';
    if not D.Execute then Exit;
    R := FProject.RelPath(D.FileName);
    if FProject.TagFiles.IndexOf(R) < 0 then FProject.TagFiles.Add(R);
    FProject.ReloadTags;
    FProject.SaveToFile(FProject.FileName);
    if FindTab('tags') <> nil then TTagsTab(FindTab('tags')).LoadFromProject;
    RunCompile(False);
  finally
    D.Free;
  end;
end;

procedure TMainForm.MNewBlock(Sender: TObject);
var
  R: TNewBlockResult;
  FBs: TStringList;
  I: Integer;
  FN, Txt: string;
begin
  if FProject.FileName = '' then
  begin
    MessageDlg('Create or open a project first', mtInformation, [mbOK], 0);
    Exit;
  end;
  FBs := TStringList.Create;
  try
    for I := 0 to FCompiler.BlockCount - 1 do
      if FCompiler.Blocks[I].Kind = ukFB then FBs.Add(FCompiler.Blocks[I].Name);
    if not ExecuteNewBlockDialog(FBs, FProject.Cpu in [cpuS7_300, cpuS7_400], R) then Exit;
  finally
    FBs.Free;
  end;
  if FCompiler.FindBlockInfo(R.Name) <> nil then
  begin
    MessageDlg('A block named "' + R.Name + '" already exists', mtError, [mbOK], 0);
    Exit;
  end;
  Txt := NewBlockTemplate(R.Kind, R.Name, R.RetType, R.InstanceOf, R.Optimized, FProject.Cpu);
  FN := IncludeTrailingPathDelimiter(FProject.Dir) + StringReplace(R.Name, ' ', '_', [rfReplaceAll]) + '.scl';
  if FileExists(FN) then
  begin
    MessageDlg('File already exists: ' + FN, mtError, [mbOK], 0);
    Exit;
  end;
  with TStringList.Create do
  try
    Text := Txt;
    SaveToFile(FN);
  finally
    Free;
  end;
  FProject.Sources.Add(FProject.RelPath(FN));
  if R.Number > 0 then FProject.SetBlockNumber(R.Name, R.Number);
  FProject.SaveToFile(FProject.FileName);
  RunCompile(False);
  OpenSource(FN);
end;

procedure TMainForm.MExit(Sender: TObject);
begin
  Close;
end;

procedure TMainForm.MCloseTab(Sender: TObject);
begin
  if FPages.ActivePage <> nil then PagesCloseTab(FPages.ActivePage);
end;

procedure TMainForm.PagesCloseTab(Sender: TObject);
var
  T: TEditorTab;
  R: TModalResult;
begin
  if not (Sender is TEditorTab) then Exit;
  T := TEditorTab(Sender);
  if T.Modified then
  begin
    R := MessageDlg('Save changes of "' + T.BaseCaption + '"?', mtConfirmation, [mbYes, mbNo, mbCancel], 0);
    if R = mrCancel then Exit;
    if R = mrYes then T.Save;
  end;
  T.Free;
end;

{ ---------------------------------------------------------------- menu: edit }

procedure TMainForm.MUndo(Sender: TObject);
begin
  if CurrentSource <> nil then CurrentSource.Edit.Undo;
end;

procedure TMainForm.MRedo(Sender: TObject);
begin
  if CurrentSource <> nil then CurrentSource.Edit.Redo;
end;

procedure TMainForm.MFind(Sender: TObject);
begin
  if CurrentSource = nil then Exit;
  if CurrentSource.Edit.SelAvail then FFind.FindText := CurrentSource.Edit.SelText;
  FFind.Execute;
end;

procedure TMainForm.MFindNext(Sender: TObject);
begin
  if FFind.FindText <> '' then FindDialogFind(FFind) else MFind(Sender);
end;

procedure TMainForm.FindDialogFind(Sender: TObject);
var
  Opt: TSynSearchOptions;
begin
  if CurrentSource = nil then Exit;
  Opt := [];
  if frMatchCase in FFind.Options then Include(Opt, ssoMatchCase);
  if frWholeWord in FFind.Options then Include(Opt, ssoWholeWord);
  if not (frDown in FFind.Options) then Include(Opt, ssoBackwards);
  if CurrentSource.Edit.SearchReplace(FFind.FindText, '', Opt) = 0 then
    SetStatus('"' + FFind.FindText + '" not found');
end;

{ ---------------------------------------------------------------- menu: build / view }

procedure TMainForm.MCompile(Sender: TObject);
begin
  RunCompile(False);
end;

procedure TMainForm.MBuild(Sender: TObject);
begin
  if FProject.FileName = '' then Exit;
  SaveAll;
  RunCompile(True);
end;

procedure TMainForm.MOpenOutput(Sender: TObject);
begin
  if FProject.FileName = '' then Exit;
  ForceDirectories(ExtractFileDir(FProject.OutputFile));
  OpenDocument(ExtractFileDir(FProject.OutputFile));
end;

procedure TMainForm.MViewTags(Sender: TObject);
begin
  if FProject.FileName = '' then Exit;
  OpenTags;
end;

function AddrText(const D: TSvDataBlock; const V: TSvVar): string;
var
  B: Int64;
begin
  B := V.BitOff;
  if D.Flags and BF_OPTIMIZED <> 0 then
    Exit(Format('%%DB%d (optimized) +%d.%d', [D.Number, B div 8, B mod 8]));
  if V.VmType = VT_BOOL then Result := Format('%%DB%d.DBX%d.%d', [D.Number, B div 8, B mod 8])
  else if V.VmType = 0 then Result := Format('%%DB%d.DBB%d', [D.Number, B div 8])
  else case VmTypeBytes(V.VmType) of
    1: Result := Format('%%DB%d.DBB%d', [D.Number, B div 8]);
    2: Result := Format('%%DB%d.DBW%d', [D.Number, B div 8]);
    4: Result := Format('%%DB%d.DBD%d', [D.Number, B div 8]);
  else
    Result := Format('%%DB%d.DBB%d (%d bytes)', [D.Number, B div 8, V.SizeBits div 8]);
  end;
end;

function SecText(S: Byte): string;
begin
  if S <= Ord(High(TMemberSection)) then Result := SectionNames[TMemberSection(S)] else Result := '';
end;

procedure TMainForm.MViewVars(Sender: TObject);
var
  T: TEditorTab;
  G: TGridViewTab;
  I, J: Integer;
  Img: TSvImage;
  D: TSvDataBlock;
  B: TSvBlock;
  PT: TPlcTag;
  El, Ret: string;
begin
  if FProject.FileName = '' then Exit;
  RunCompile(False);
  T := FindTab('view:all variables');
  if T = nil then
  begin
    G := TGridViewTab.CreateFor(FPages, 'All variables', ['Element', 'Variable', 'Data type', 'Address / offset',
      'Section', 'Start value', 'Retain', 'Comment']);
    G.OnOpenRow := @OpenVarRow;
  end
  else
    G := TGridViewTab(T);
  G.ClearRows;
  for I := 0 to FProject.Tags.Count - 1 do
  begin
    PT := FProject.Tag(I);
    if PT.IsConstant then
      G.AddRow(['Constants: ' + PT.TableName, PT.Name, PT.DataType, '', 'Constant', PT.Value, '', PT.Comment])
    else
      G.AddRow(['PLC tags: ' + PT.TableName, PT.Name, PT.DataType, PT.Address, 'Tag', '', '', PT.Comment]);
  end;
  Img := FCompiler.Image;
  for I := 0 to Img.DataBlocks.Count - 1 do
  begin
    D := Img.DataBlock(I);
    El := Format('DB%d "%s"', [D.Number, D.Name]);
    for J := 0 to High(D.Vars) do
    begin
      if D.Vars[J].Flags and VF_RETAIN <> 0 then Ret := 'Retain' else Ret := '';
      G.AddRow([El, D.Vars[J].Path, D.Vars[J].TypeText, AddrText(D, D.Vars[J]), SecText(D.Vars[J].Section),
        D.Vars[J].InitText, Ret, D.Vars[J].Comment]);
    end;
  end;
  for I := 0 to Img.Blocks.Count - 1 do
  begin
    B := Img.Block(I);
    case B.Kind of
      BK_OB: El := Format('OB%d "%s"', [B.Number, B.Name]);
      BK_FB: El := Format('FB%d "%s"', [B.Number, B.Name]);
    else
      El := Format('FC%d "%s"', [B.Number, B.Name]);
    end;
    for J := 0 to High(B.Vars) do
    begin
      if B.Vars[J].Flags and VF_BYREF <> 0 then Ret := 'pointer' else Ret := '';
      G.AddRow([El, B.Vars[J].Path, B.Vars[J].TypeText, Format('+%d.%d', [B.Vars[J].BitOff div 8, B.Vars[J].BitOff mod 8]),
        SecText(B.Vars[J].Section), B.Vars[J].InitText, Ret, B.Vars[J].Comment]);
    end;
  end;
  G.Refill;
  FPages.ActivePage := G;
end;

procedure TMainForm.OpenVarRow(const Row: TStringArray);
var
  S: string;
  P1, P2: Integer;
begin
  if Length(Row) = 0 then Exit;
  S := Row[0];
  if Copy(S, 1, 9) = 'PLC tags:' then
  begin
    OpenTags;
    Exit;
  end;
  P1 := Pos('"', S);
  P2 := Pos('"', Copy(S, P1 + 1, MaxInt));
  if (P1 > 0) and (P2 > 0) then GotoBlock(Copy(S, P1 + 1, P2 - 1));
end;

procedure TMainForm.OpenElementRow(const Row: TStringArray);
begin
  if Length(Row) < 3 then Exit;
  if Row[0] = 'Tag table' then OpenTags else GotoBlock(Row[2]);
end;

procedure TMainForm.MViewElements(Sender: TObject);
var
  T: TEditorTab;
  G: TGridViewTab;
  I, J, Cnt: Integer;
  B, C: TBlockInfo;
  CalledBy, Opt, Size, Code: string;
  Tbls: TStringList;
begin
  if FProject.FileName = '' then Exit;
  RunCompile(False);
  T := FindTab('view:all elements');
  if T = nil then
  begin
    G := TGridViewTab.CreateFor(FPages, 'All elements', ['Type', 'Number', 'Name', 'Source file', 'Line',
      'Access', 'Data size (byte)', 'Code size (byte)', 'Uses / calls', 'Used by']);
    G.OnOpenRow := @OpenElementRow;
  end
  else
    G := TGridViewTab(T);
  G.ClearRows;
  Tbls := TStringList.Create;
  try
    Tbls.Sorted := True;
    Tbls.Duplicates := dupIgnore;
    for I := 0 to FProject.Tags.Count - 1 do Tbls.Add(FProject.Tag(I).TableName);
    for I := 0 to Tbls.Count - 1 do
    begin
      Cnt := 0;
      for J := 0 to FProject.Tags.Count - 1 do
        if FProject.Tag(J).TableName = Tbls[I] then Inc(Cnt);
      G.AddRow(['Tag table', '', Tbls[I], Tbls[I] + '.csv', '', '', IntToStr(Cnt) + ' tags', '', '', '']);
    end;
  finally
    Tbls.Free;
  end;
  for I := 0 to FCompiler.BlockCount - 1 do
  begin
    B := FCompiler.Blocks[I];
    CalledBy := '';
    for J := 0 to FCompiler.BlockCount - 1 do
    begin
      C := FCompiler.Blocks[J];
      if C.Calls.IndexOf(B.Name) >= 0 then
      begin
        if CalledBy <> '' then CalledBy := CalledBy + ', ';
        CalledBy := CalledBy + C.Name;
      end;
    end;
    if B.Kind = ukUDT then Opt := '' else if B.Optimized then Opt := 'optimized' else Opt := 'standard';
    Size := '';
    Code := '';
    case B.Kind of
      ukUDT, ukDB: if B.DataType <> nil then Size := IntToStr(B.SizeBytes);
      ukFB: if B.DataType <> nil then Size := IntToStr(B.SizeBytes) + ' (instance)';
      ukFC: if B.ParamType <> nil then Size := IntToStr((B.ParamType.SizeBits + 7) div 8) + ' (param)';
    end;
    if B.CodeIndex >= 0 then Code := IntToStr(B.CodeSize);
    if B.Kind = ukUDT then
      G.AddRow(['UDT', '', B.Name, ExtractFileName(B.U.FileName), IntToStr(B.U.Pos.Line), Opt, Size, Code,
        B.Calls.CommaText, CalledBy])
    else
      G.AddRow([B.KindText, IntToStr(B.Number), B.Name, ExtractFileName(B.U.FileName), IntToStr(B.U.Pos.Line),
        Opt, Size, Code, B.Calls.CommaText, CalledBy]);
  end;
  G.Refill;
  FPages.ActivePage := G;
end;

procedure TMainForm.MViewListing(Sender: TObject);
var
  T: TEditorTab;
begin
  if FProject.FileName = '' then Exit;
  if not RunCompile(False) then
  begin
    MessageDlg('Fix the compile errors first', mtWarning, [mbOK], 0);
    Exit;
  end;
  T := FindTab('text:listing');
  if T = nil then T := TTextTab.CreateFor(FPages, 'Listing', nil);
  TTextTab(T).Edit.Lines.Text := FCompiler.ListingText;
  FPages.ActivePage := T;
end;

procedure TMainForm.MBlockNumbers(Sender: TObject);
var
  S: string;
  I: Integer;
  B: TBlockInfo;
begin
  if FProject.FileName = '' then Exit;
  S := '';
  for I := 0 to FCompiler.BlockCount - 1 do
  begin
    B := FCompiler.Blocks[I];
    if B.Kind = ukUDT then Continue;
    S := S + Format('%s%d  %s', [B.KindText, B.Number, B.Name]);
    if FProject.BlockNumber(B.Name) > 0 then S := S + '   (fixed)' else S := S + '   (auto)';
    S := S + LineEnding;
  end;
  MessageDlg('Block numbers' + LineEnding + LineEnding + S + LineEnding +
    'Right-click a block in the project tree > "Set block number..." to fix a number.', mtInformation, [mbOK], 0);
end;

procedure TMainForm.MAbout(Sender: TObject);
begin
  MessageDlg(APP_NAME + ' ' + COMPILER_VERSION + LineEnding +
    'SCL compiler for Siemens S7-300 / S7-400 / S7-1200 / S7-1500 sources.' + LineEnding +
    'Output: Virtual PLC image (*.svpl) + listing (*.lst) + memory map.' + LineEnding + LineEnding +
    'Built with Lazarus / Free Pascal.', mtInformation, [mbOK], 0);
end;

procedure TMainForm.CpuChange(Sender: TObject);
begin
  if FProject.FileName = '' then Exit;
  if FCpuBox.ItemIndex = Ord(FProject.Cpu) then Exit;
  if MessageDlg(Format('Change the CPU family of the project from %s to %s?', [CpuNames[FProject.Cpu],
    FCpuBox.Text]), mtConfirmation, [mbYes, mbNo], 0) <> mrYes then
  begin
    FCpuBox.ItemIndex := Ord(FProject.Cpu);
    Exit;
  end;
  FProject.Cpu := TCpuFamily(FCpuBox.ItemIndex);
  FProject.Modified := True;
  FProject.SaveToFile(FProject.FileName);
  UpdateTitle;
  RunCompile(False);
end;

{ ---------------------------------------------------------------- tree / messages }

procedure TMainForm.TreeDblClick(Sender: TObject);
var
  N: TTreeNode;
  Info: TNodeInfo;
begin
  N := FTree.Selected;
  if (N = nil) or not (TObject(N.Data) is TNodeInfo) then Exit;
  Info := TNodeInfo(N.Data);
  case Info.Kind of
    nkTagsRoot, nkTagTable: OpenTags;
    nkBlock: OpenSource(Info.FileName).GotoLine(Info.Line, 1);
    nkSource: OpenSource(Info.FileName);
  end;
end;

procedure TMainForm.TreeKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  if Key = VK_RETURN then
  begin
    if ssCtrl in Shift then TreeOpenInterface(Sender) else TreeDblClick(Sender);
    Key := 0;
  end;
end;

procedure TMainForm.TreeMenuPopup(Sender: TObject);
var
  N: TTreeNode;
  Info: TNodeInfo;
begin
  N := FTree.Selected;
  Info := nil;
  if (N <> nil) and (TObject(N.Data) is TNodeInfo) then Info := TNodeInfo(N.Data);
  FTreeMenu.Items[1].Enabled := (Info <> nil) and (Info.Kind = nkBlock);
  FTreeMenu.Items[2].Enabled := (Info <> nil) and (Info.Kind = nkBlock) and (Info.UKind <> ukUDT);
  FTreeMenu.Items[3].Enabled := (Info <> nil) and (Info.Kind = nkSource);
end;

procedure TMainForm.TreeOpenInterface(Sender: TObject);
var
  N: TTreeNode;
  Info: TNodeInfo;
begin
  N := FTree.Selected;
  if (N = nil) or not (TObject(N.Data) is TNodeInfo) then Exit;
  Info := TNodeInfo(N.Data);
  if Info.Kind = nkBlock then OpenDecl(Info.BlockName, Info.FileName);
end;

procedure TMainForm.TreeSetNumber(Sender: TObject);
var
  N: TTreeNode;
  Info: TNodeInfo;
  S: string;
  B: TBlockInfo;
begin
  N := FTree.Selected;
  if (N = nil) or not (TObject(N.Data) is TNodeInfo) then Exit;
  Info := TNodeInfo(N.Data);
  if Info.Kind <> nkBlock then Exit;
  B := FCompiler.FindBlockInfo(Info.BlockName);
  if B <> nil then S := IntToStr(B.Number) else S := '0';
  if not InputQuery('Block number', Format('Number of %s "%s" (0 = automatic):',
    [UnitKindNames[Info.UKind], Info.BlockName]), S) then Exit;
  FProject.SetBlockNumber(Info.BlockName, StrToIntDef(S, 0));
  FProject.SaveToFile(FProject.FileName);
  RunCompile(False);
end;

procedure TMainForm.TreeRemoveSource(Sender: TObject);
var
  N: TTreeNode;
  Info: TNodeInfo;
  I: Integer;
begin
  N := FTree.Selected;
  if (N = nil) or not (TObject(N.Data) is TNodeInfo) then Exit;
  Info := TNodeInfo(N.Data);
  if Info.Kind <> nkSource then Exit;
  if MessageDlg('Remove "' + ExtractFileName(Info.FileName) + '" from the project? (the file is not deleted)',
    mtConfirmation, [mbYes, mbNo], 0) <> mrYes then Exit;
  for I := FProject.Sources.Count - 1 downto 0 do
    if SameText(FProject.AbsPath(FProject.Sources[I]), Info.FileName) then FProject.Sources.Delete(I);
  FProject.SaveToFile(FProject.FileName);
  RunCompile(False);
end;

procedure TMainForm.MsgDblClick(Sender: TObject);
var
  I: Integer;
  MI: TMsgInfo;
begin
  I := FMsgs.ItemIndex;
  if (I < 0) or not (FMsgs.Items.Objects[I] is TMsgInfo) then Exit;
  MI := TMsgInfo(FMsgs.Items.Objects[I]);
  if (MI.FileName = '') or (MI.Line <= 0) then Exit;
  if Copy(MI.FileName, 1, 9) = 'PLC tags:' then
  begin
    OpenTags;
    if FindTab('tags') <> nil then
      with TTagsTab(FindTab('tags')).Grid do
        if MI.Line - 1 < RowCount then Row := MI.Line - 1;
    Exit;
  end;
  if FileExists(MI.FileName) then OpenSource(MI.FileName).GotoLine(MI.Line, MI.Col);
end;

procedure TMainForm.FormCloseQuery(Sender: TObject; var CanClose: Boolean);
begin
  CanClose := ConfirmSave;
end;

procedure TMainForm.FormDropFiles(Sender: TObject; const FileNames: array of string);
var
  I: Integer;
begin
  for I := Low(FileNames) to High(FileNames) do
    if SameText(ExtractFileExt(FileNames[I]), '.sclproj') then
    begin
      if ConfirmSave then LoadProject(FileNames[I]);
      Exit;
    end
    else if SameText(ExtractFileExt(FileNames[I]), '.scl') then
      OpenSource(FileNames[I]);
end;

end.
