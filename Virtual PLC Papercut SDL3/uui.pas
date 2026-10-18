unit uUi;

{ The Virtual PLC screens, all drawn as papercut on the display lists.

  CPU       front panel (S7-300 / S7-400 module with LEDs and mode selector, or
            S7-1200 compact CPU with its I/O LEDs), CPU model, cycle time,
            diagnostic buffer
  Program   blocks, networks (LAD grid / STL text), element palette, operands,
            compile messages, monitor (power flow, STL status RLO STA ACCU1 ACCU2)
  I/O       input switches / push buttons, output lamps, analog sliders and
            generators, analog outputs, fault injection
  Watch     watch and force table
  DBs       data blocks with typed variables
  Tags      PLC tag table
  Project   new / samples / save / load, settings

  Static parts (backdrop, header, cards of the screen) go to the static list,
  which is rebuilt only when FStaticKey changes; everything else is drawn
  every frame into the dynamic list. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, Types, StrUtils, DateUtils, TypInfo, LazUTF8, BGRABitmap, BGRABitmapTypes,
  uPaperDL, uUiBase, uPlcTypes, uPlcProject, uPlcCompiler, uPlcRuntime, uPlcServer, uPlcClient, uTextEdit,
  uClaude, uClaudeHttp, uPlcExport, Dialogs, fpjson, uLocalIp, uIpcServer, uChatPdf, ShellApi, uHelpForm, uExamples, Clipbrd, uSclElems, uSclSource;

type
  TScreen = (scCpu, scProgram, scIO, scWatch, scDB, scTags, scPorts, scProject);

const
  ScreenNames: array[TScreen] of string = ('CPU', 'Program', 'I/O', 'Watch', 'Data blocks', 'Tags', 'Ports',
    'Project');

type

  { an undo step of the program: the whole project (compact JSON) and where the user was }
  TProgSnap = record
    Json: string;
    Scr: TScreen;
    Blk, Net, StlNet, StlRow, StlCol: Integer;
  end;

  { TPlcUI }

  TPlcUI = class(TUiBase)
  private
    FStaticKey: string;
    FRes: TResolver;
    { program screen }
    FBlockSel, FNetSel, FCellR, FCellC: Integer;
    FProgScroll, FProgContent: Single;
    FScrollToCaret: Boolean;   // bring the edited line / the message's network into view
    FIfaceShut: Boolean;       // the FB interface panel is folded
    { the STL / SCL text editor (Notepad++ style) }
    FEd: TTextEdit;
    FEdNet: TNetwork;          // the network FEd's selection belongs to
    FFindMode: Integer;        // 0 closed, 1 find, 2 replace, 3 go to line
    FFindText, FReplText, FGotoText, FFindMsg: string;
    FFindCase, FFindWord: Boolean;
    FFindAt: Double;           // the time of the last search from the find field
    FCompOpen: Boolean;        // the word completion list (Ctrl+Space)
    FComp: TStringList;
    FCompSel, FCompC1: Integer;
    FCaretX, FCaretY: Single;  // where the caret was drawn (the completion list opens there)
    FDragPress, FDragMode, FDragLine0: Integer;
    FDragW1, FDragW2: TTextPos;  // the word of a double click (a drag goes on by words)
    { LAD: a rectangle of selected cells (FLsNet: its network; else the focus cell alone) }
    FLsNet: Integer;
    FLsA, FLsB: TPoint;        // X = column, Y = row: the corner where it started, the other corner
    FLadMode: Integer;         // a drag: 1 the rubber band, 2 moving the selection
    FLadPress, FLadOff: TPoint;
    FLadGrab: TPoint;
    FLadPressM: TPointF;       // where the mouse took the cells (their ghost follows it)
    FLadDropNet: Integer;      // the drag is over: -1 its own network, -2 no network, else another network
    FLadDropAt: TPoint;        // ... in that other network: the cell where the pressed cell goes
    FLadSeen: array of Double; // FTime of the frame each LAD network was drawn in (where the mouse can find it)
    FGhostOn: Boolean;         // the ghost of the dragged cells, drawn over all networks
    FGhostI: array of TPoint;
    FGhostR: TRectF;
    FGhostExtra: Integer;      // a box reaches over its right neighbour: so many cells more
    FDropOn, FDropOk: Boolean; // the frame of where the cells go (red: a wire / element holds them; grey: no)
    FDropR: TRectF;
    { undo / redo: a snapshot of the project after every change (MarkDirty); typing on one line
      within 3 s is one step }
    FPUndo, FPRedo: array of TProgSnap;
    FPBase: TProgSnap;         // the project as it is now ('' : taken at the next frame)
    FPPending: Boolean;        // MarkDirty since the last snapshot
    FPKind, FPLastKind: Integer;   // 1 typing, 2 deleting a character, 0 anything else
    FPNet: TNetwork;
    FPRow, FPLastRow: Integer;
    FPLastNet: TNetwork;
    FPTime: Double;          // the cell under the mouse at the press, from the grabbed cell (a wide box)
    FLadX0: array of Single;   // per network: x of column 0 (with its horizontal scroll)
    FLadCW: Single;
    FHScroll: array of record Net: TNetwork; X: Single; end;   // the horizontal scroll of each LAD network
    FLadFollow: Boolean;       // keep the focus cell in view (after a key)
    FHsGrab: Single;           // where the scroll bar thumb was grabbed
    FMenuOpen: Boolean;        // the LAD popup menu (right button)
    { Claude in the program editor }
    FClaude: TClaudeAgent;
    FChatOpen: Boolean;        // the chat window is shown (the view opens / hides it)
    FClaudeMenu: Boolean;      // the AI menu under its button
    FKeyRmDlg: Boolean;        // Remove ANTHROPIC_API_KEY: are you sure?
    { a right click menu of the main window (blocks, networks, data blocks, the watch table) }
    FCtxOn: Boolean;
    FCtxX, FCtxY: Single;
    FCtxNames: array of string;
    FCtxActs: array of Integer;
    FCtxEn: array of Boolean;
    { are you sure? (loading a project file) }
    FAskOn: Boolean;
    FAskTitle, FAskOk: string;
    FAskLines: array of string;
    FAskAct: Integer;
    FAskSave: Boolean;         // the question is: save the changes first? (Save / Don't save / Cancel)
    FWatchFile: string;        // the watch table's own file (Save / Open)
    FHelpKind: TNetKind;       // the help shown (SCL / STL) and its selection (char, line)
    FHelp0, FHelp1, FHelpW0, FHelpW1: TPoint;
    FHelpX0, FHelpY0: Single;
    FHelpMode: Integer;        // the press: 1 selects, 2 drags the selection, 3 words
    FHelpFocus: Boolean;       // Ctrl+C / Ctrl+A go to the help
    FElems: TSclElems;         // the SCL elements panel: the list, its open categories, scroll, hover, press
    FElemOpen: TStringList;
    FElemScroll, FElemH: Single;
    FElemHover, FElemPress: Integer;
    FElemLang: Char;           // the list shown: 'C' SCL, 'S' STL, 'L' LAD
    FElemViewH: Single;        // its height
    FAutoWord: string;         // the name at the caret: highlighted in the code of the block
    FIoView: Integer;          // the I/O screen: 0 the PLC's own I/O, 1 the tags outside it, 2 the signal table
    FIoScroll: array[0..4] of Single;   // AI, AQ, tag inputs, tag outputs, signals
    FIoH: array[0..4] of Single;
    FDIPage, FDQPage: Integer; // more than 32 channels: the first column shown
    FSigSel: Integer;
    FSigRnd: array of Double;  // the random value of a Random signal in its period
    FSigRndK: array of Int64;
    FTagIo: array of Integer;  // the tags of the Tag I/O view (inputs first, FTagIoOut of them inputs)
    FTagIoIn: Integer;
    { the trees of groups: 0 the tag table, 1 the watch table }
    FTagGrpSel, FWatchGrpSel: Integer;     // the group shown (-1: the root, every row)
    FGrpOpen: array[0..1] of array of Integer;   // the Ids of the groups opened in the tree
    FGrpRootShut: array[0..1] of Boolean;
    FGrpScroll: array[0..1] of Single;
    FTagSort, FWatchSort: Integer;         // 0 the order of the table, 1 alphabet, 2 address, 3 data type
    FTagDesc, FWatchDesc: Boolean;
    FTagView, FWatchView: array of Integer;   // the rows shown (indexes of Project.Tags / Watch)
    FViewForm: THelpForm;      // All variables / All elements
    FViewKind: Integer;
    { vertical scroll bars that the mouse drags: 0 the program editor, 1 the compiler messages,
      2 the blocks, 3 the tag table, 4 the data blocks list, 5 the variables, 6 the watch table,
      7 the project files, 8 the LAD elements, 9 the example projects }
    FVs: array[0..17] of record X, Top, H, Range, View: Single; end;
    FPalScroll, FPalH: Single;   // the LAD elements palette
    FLadTypes: array of TDataType;   // the data type list of a LAD box (FLadTypeWhich 1 IN / 2 OUT)
    FBlockScroll, FDBListScroll, FFileScroll: Single;
    FTagErr: array of string;  // what is wrong with a tag ('' fine)
    FIpChoices: array of string;
    FTypeChoices: array of string;   // the data type list (a tag or a variable)
    FIpc: TIpcServer;                // the IPC server while it is on
    FHelpForm: THelpForm;            // the IPC help: an HTML window of its own
    FIoHelpForm: THelpForm;          // the help of the I/O import file
    FFileCtx: Integer;               // the project file of the right click menu
    FFileCtxEx: Boolean;             // ... of the example projects
    FExamples: TStringList;          // the files in examples\
    FExScroll: Single;
    FFolder: Integer;                // the project files list shows 0 Projects, 1 Example Projects
    FTypeFor: Integer;               // the field it fills: fdTagType / fdVarType shl 16 + the row
    FVsGrab: Single;           // where the thumb was grabbed (from its top)
    FVsDrag: Integer;          // the bar being dragged, -1 none
    FDevMenu: Boolean;         // the Developer menu of the Project screen
    FKeyDlg: Boolean;          // the Set ANTHROPIC_API_KEY dialog
    FKeyText, FKeyMsg: string;
    FKeyMsgErr: Boolean;
    FMenuX, FMenuY: Single;
    FLadTops: array of array of Single;   // per network: the top of every row (+ the bottom)
    FLadClip: array of array of TLadCell; // copied cells [row][column]
    { an interface variable dragged into the code }
    FVarDrag: string;
    FVarDragOn: Boolean;
    FVarX0, FVarY0: Single;
    FDropKind, FDropNet, FDropRow, FDropCol: Integer;   // 1 a text line, 2 a LAD cell
    FDropX, FDropY, FDropW, FDropH: Single;
    FDropCell: Boolean;        // a LAD element of the list is dragged: any cell takes it
    FIfGripX, FIfGripY: Single;   // the grip of interface row 0 (the script needs it)
    FIfSel: Integer;           // the selected interface row
    FMonitor: Boolean;
    FStlNet, FStlRow, FStlCol: Integer;
    FMsgs: array of TCompileMsg;
    FMsgErrors: Integer;
    FMsgScroll: Single;
    FDirty: Boolean;
    FEverDownloaded: Boolean;
    { cpu screen }
    FFamView: TCpuFamily;
    FModelSel: Integer;
    FSwitchPos: Integer;
    FMresT: Double;
    { other screens }
    FWatchSel, FDBSel, FVarSel, FTagSel: Integer;
    FWatchScroll, FVarScroll, FTagScroll, FDiagScroll: Single;
    FFiles: TStringList;
    FSaveAsName: string;
    FToast: string;
    FToastT: Double;
    FToastErr: Boolean;
    FDIPressed: array[0..63] of Boolean;
    FAIt: Double;
    procedure Toast(const S: string; Err: Boolean = False);
    procedure MarkDirty;
    function ProgSnap: TProgSnap;
    procedure ProgCommit;           // a change since the last snapshot: the snapshot before it goes to undo
    procedure ProgUndo(Redo: Boolean);
    procedure ProgUndoReset;        // another project: no steps
    function CurBlock: TBlock;
    function CurNet: TNetwork;
    function CompiledBlock: TCBlock;
    function MonitorOk: Boolean;
    procedure ResetResolver;
    { building }
    procedure BuildStatic;
    procedure BuildHeader;
    procedure BuildFooter;
    procedure BuildCpu;
    procedure BuildProgram;
    procedure BuildIO;
    procedure BuildWatch;
    procedure BuildDB;
    function IfaceHeight(B: TBlock): Single;
    procedure DrawIface(B: TBlock; X, Y, W: Single);
    function FirstInstance(B: TBlock): TDataBlock;
    function CurDB: TDataBlock;        // the selected DB or PLC data type (FDBSel past the DBs)
    function SelIsUdt: Boolean;
    function StructLive(const Prefix: string; U: TDataBlock): string;
    procedure BuildTags;
    procedure BuildProject;
    procedure BuildPorts;
    procedure DrawPortLeds(X, Y: Single; Link: Boolean);
    function PortActive: Boolean;
    procedure DrawCpuModule(X, Y: Single);
    procedure Draw1200Module(X, Y: Single);
    procedure Draw1500Module(X, Y: Single);
    procedure DrawNetwork(NI: Integer; N: TNetwork; X, Y, W: Single; out H: Single);
    procedure DrawLad(NI: Integer; N: TNetwork; X, Y, W: Single);
    procedure DrawCell(NI: Integer; N: TNetwork; R, C: Integer; X, Y, CW, RH: Single; Span: Integer;
      PowIn, PowOut: Integer; Sel: Boolean);
    procedure DrawStl(NI: Integer; N: TNetwork; X, Y, W: Single);
    procedure DrawScl(NI: Integer; N: TNetwork; X, Y, W: Single);
    procedure DrawPalette(X, Y, W: Single);
    procedure DrawProps(X, Y, W, H: Single);
    function NetHeight(N: TNetwork): Single;
    function RowHeight(N: TNetwork; R: Integer): Single;
    function BoxSpan(N: TNetwork; R, C: Integer): Integer;
    procedure LadKeepBoxes(N: TNetwork);   // every box keeps a free cell on its right (its full width)
    function CallBlockOf(const Opnd: string): TBlock;    // the FC / FB a CALL box calls
    function PinsOf(const Ce: TLadCell): Integer;
    function OperandValue(const S: string; F: TDispFmt; out AText: string): Boolean;
    function LiveText(const O: TOperand; const Fallback: string): string;
    function CellPower(NI, Cell, Which: Integer): Integer;  // -1 unknown, 0, 1
    function DiagColor(K: TDiagKind): TBGRAPixel;
    function LedColorStr(const Name: string): TBGRAPixel;
    procedure ActStl(const Key: TUiKey; Ch: Char; Mods: TUiMods);
    function EdBegin: TNetwork;
    procedure EdEnd(N: TNetwork);
    procedure EdUndoPoint(N: TNetwork; Kind: Integer);
    procedure EdUndo(Redo: Boolean);
    function FindNet(Net: TNetwork; out BI, NI: Integer): Boolean;
    function EdFind(Back: Boolean; Quiet: Boolean = False): Boolean;
    procedure EdReplace(All: Boolean);
    procedure EdGoto;
    procedure EdOpenFind(Mode: Integer);
    procedure DrawEdBack(NI: Integer; N: TNetwork; X, TX, Y, W, CharW, MaxX: Single);
    procedure DrawEdCaret(NI: Integer; N: TNetwork; TX, Y, CharW: Single);
    procedure DrawFindBar(X, Y, W: Single);
    procedure CompStart;
    procedure CompFilter;
    procedure CompAccept;
    procedure DrawComp;
    procedure DoDragEnd(Id: Integer; X, Y: Single); override;
    function LadSel(out R1, C1, R2, C2: Integer): Boolean;   // False: only the focus cell
    function LadInSel(NI, R, C: Integer): Boolean;
    procedure LadCollapse;
    procedure CellAt(NI: Integer; X, Y: Single; out R, C: Integer);
    procedure LadUndoPoint(N: TNetwork);
    procedure LadUndo(Redo: Boolean);
    procedure LadCopy(Cut: Boolean);
    procedure LadPaste;
    procedure LadDeleteSel;
    function LadNetAt(Y: Single): Integer;                      // the LAD network whose rows are at Y
    function LadTarget(out TN, TR, TC: Integer): Boolean;       // where the dragged cells go (top left)
    function LadDropOk(TN, TR, TC: Integer): Boolean;           // every cell there is a wire or an element
    procedure LadMoveTo(TN, TR, TC: Integer);                   // the selection into another network
    procedure DrawLadGhost;
    function NetHasCode(N: TNetwork): Boolean;
    function StlMenu(Id: Integer): Boolean;   // the right button on a text: the caret goes there (not into a selection)   // something written in it: its language stays
    procedure LadFillWires(N: TNetwork; R1, C1, R2, C2: Integer);   // deleted cells where the rung goes on: wire
    procedure LadMove(DC, DR: Integer);
    procedure DrawDrag;
    function GetHS(N: TNetwork): Single;
    procedure SetHS(N: TNetwork; V: Single);
    procedure LadGrow(N: TNetwork; ToCols: Integer);
    procedure DoRightClick(Id: Integer); override;
    procedure DrawClaudeMenu;
    procedure DrawDevMenu;
    procedure DrawKeyDlg;
    procedure DrawKeyRmDlg;
    procedure DrawCtx;
    { the language help of the Elements panel (SCL / STL): select, copy, drag into the code }
    function HelpCount: Integer;
    function StrLive(const O: TOperand; out AText: string): Boolean;
    function HelpLine(I: Integer): string;
    function HelpCharW: Single;
    function HelpPosAt(X, Y: Single): TPoint;
    procedure HelpOrdered(out A, B: TPoint);
    function HelpHasSel: Boolean;
    function HelpSelText: string;
    function HelpInSel(P: TPoint): Boolean;
    procedure HelpWord(P: TPoint; out A, B: TPoint);
    procedure HelpCopy;
    procedure DrawHelp(K: TNetKind; X, Y, W: Single);
    procedure DrawElems(X, Y, W, ViewH: Single; Lang: Char);
    procedure ElemPut(const Snip: string);
    procedure ElemInsert(K: Integer);
    procedure BuildIoModel;
    procedure BuildIoTags;
    procedure BuildIoSignals;
    procedure CollectTagIo;
    procedure ApplySignals;
    function NextWatchAddress: string;
    procedure MakeTagView;
    procedure MakeWatchView;
    procedure BuildGroupTree(K: Integer; X, Y, W, H: Single);
    function GrpSel(K: Integer): Integer;
    procedure SetGrpSel(K, V: Integer);
    function GrpIdSel(K: Integer): Integer;
    function GrpIsOpen(K, Id: Integer): Boolean;
    procedure GroupAction(Code, Par: Integer);
    procedure DbSclMenu(Par: Integer);
    function IoListScroll(L: Integer; X, Y, W, H, RowH: Single; N: Integer; out First, Last: Integer): Single;
    procedure FindDeclaration;
    function GotoName(const Q: string): Boolean;
    function GotoLocal(const W: string): Boolean;
    procedure ShowView(Kind: Integer);
    procedure ViewLink(Sender: TObject; const URL: string);
    function AllVarsHtml: string;
    function AllElemsHtml: string;
    procedure SclSourceMenu(Par: Integer);
    procedure DropTrack(X, Y: Single; Lad: Boolean);
    procedure CheckTags;
    procedure TypeMenu(ForVar: Boolean; Row: Integer; X, Y: Single);
    procedure ApplyIpc;
    function IpcRequest(const Line: string): string;
    procedure ShowInExplorer(const APath: string; Select: Boolean);
    function TestIp: string;
    procedure VScrollBar(Bar: Integer; X, Top, H, Range, View, Pos: Single);
    function VsPos(Bar: Integer): Single;
    procedure SetVsPos(Bar: Integer; V: Single);
    procedure DrawAsk;
    procedure OpenCtx(X, Y: Single; const Names: array of string; const Acts: array of Integer;
      const En: array of Boolean);
    procedure Ask(const Title: string; const Lines: array of string; const OkLabel: string; AAct: Integer);
    { AAct after the project's changes are saved (or not): asks only when there are changes }
    procedure AskSaveFirst(const What: string; AAct: Integer);
    function LiveOf(const Operand: string): string;
    function IoTagFor(const A: string): string;
    function ExportName(Kind, Fmt, Index: Integer; out Filter, Ext: string): string;
    procedure ChooseExport(Kind, Fmt, Index: Integer);
    procedure WatchMenu(Item: Integer);
    procedure SaveKey(Encrypted: Boolean);
    function ClaudeContext: string;
    procedure ClaudeAsk(const S: string; const Files: TChatAttachments);
    procedure ClaudeChanged;
    procedure ClaudeReloaded;
    procedure ClaudeCompiled(P: TCProgram);
    function ClaudeDirty: Boolean;
    procedure DrawMenu;
    procedure StlInsert(const S: string);
    procedure PlaceElement(K: TLadKind);
    procedure RefreshFiles;
    function ProjectsDir: string;
    function ExamplesDir: string;
    procedure HelpPdf(Sender: TObject);
    procedure IoHelpPdf(Sender: TObject);
    procedure FileList(L: TStringList; ACode, ABar, AWheel: Integer; var AScroll: Single);
    procedure ApplyModel(AIdx: Integer);
    procedure ApplyInputRest;
    procedure SyncModel;
  protected
    procedure DoClick(Id: Integer; const S: string); override;
    procedure DoPress(Id: Integer; Down: Boolean); override;
    procedure DoDrag(Id: Integer; X, Y: Single; const R: TRectF); override;
    procedure DoWheel(Id: Integer; DY: Single); override;
    procedure DoKey(Key: TUiKey; Ch: Char; Mods: TUiMods); override;
    procedure DoText(const S: string); override;
    procedure CommitEdit(Id: Integer; const S: string); override;
  public
    Project: TPlcProject;
    Rt: TPlcRuntime;
    Hub: TCommHub;
    Screen: TScreen;
    QuitRequested, ShotRequested, InfoRequested, ExportRequested: Boolean;
    InfoCloseRequested, InfoTopRequested: Boolean;   // the Developer menu: hide the info window, toggle on top
    InfoVisible, InfoOnTop: Boolean;                 // set by the view every frame (the menu shows them)
    BuildMs: Double;
    CmdCount: Integer;
    procedure ApplyComm;
    procedure SelfTestS7;
    procedure SelfTestModbus;
    constructor Create(AGlyphs: TGlyphCache);
    destructor Destroy; override;
    procedure Update(DT: Double);
    { StaticDL is written only when the static part changed (then Result = True) }
    function Build(StaticDL, DynDL: TDisplayList): Boolean;
    procedure InvalidateStatic;
    procedure Download;
    procedure CompileOnly;
    procedure LoadSampleFor(AModel: Integer);
    procedure LoadProjectFile(const AFile: string);
    procedure SaveProject;
    function SaveProjectOk: Boolean;
    function HitCount: Integer;
    procedure FocusStl(ANet, ARow, ACol: Integer);
    procedure ShowBlock(AKind: TBlockKind; ANumber: Integer);
    procedure ShowDataType(I: Integer);   // the Data blocks screen with PLC data type I selected
    procedure SelectCell(ANet, R, C: Integer);   // a LAD cell of the current block (ANet < 0: the last network)
    function CaretPoint: TPointF;                 // design coordinates of the text caret (last frame)
    function CellPoint(NI, R, C: Integer): TPointF;  // the middle of a LAD cell (last frame)
  public
    ChatRaiseRequested: Boolean;   // the view brings the chat window to the front
    RaiseRequested: Boolean;       // the view brings the main window to the front
  public
    procedure OpenClaude;                         // the chat window
    procedure CloseClaude;
    procedure OpenKeyDialog;                      // Set ANTHROPIC_API_KEY
    procedure KeyDialogEvent(Sender: TObject);    // the chat window asks for the dialog
    procedure TypeKeyField(const S: string);      // the script: text into the key field (editing)
    function KeyDlgPoint(I: Integer): TPointF;    // the script: the middle of dialog button I (pixels)
    function ClaudeMenuPoint(I: Integer): TPointF;   // the script: the AI button (-1) or menu item I
    function KeyRmPoint(I: Integer): TPointF;        // the script: Remove the key dialog, 0 Cancel, 1 Remove
    { exports: Kind 0 block, 1 network (of the open block), 2 data block, 3 data type, 4 watch table,
      5 I/O list, 6 tag table; Fmt 0 text / CSV, 1 JSON / text, 2 JSON (see ExportName) }
    function ExportPiece(Kind, Fmt, Index: Integer; const FileName: string): Boolean;
    function WatchSaveTo(const FileName: string): Boolean;
    function WatchOpenFrom(const FileName: string): Boolean;
    { the script: the middle of a region of the last frame ('block', 'net', 'db', 'file', 'watchmenu',
      'ioexport', 'tagexport', 'ctx' item, 'ask' 1 OK / 0 Cancel) }
    function HitPoint(const What: string; Par: Integer): TPointF;
    function ProjectFileIndex(const AName: string): Integer;
    procedure RefreshProjectFiles;
    procedure ShowProjectFile(I: Integer);   // the files list scrolls to file I
    property AskOpen: Boolean read FAskOn;
    procedure RequestQuit;     // the window's close: asks to save the changes first
    property CtxOpen: Boolean read FCtxOn;
    property WatchFile: string read FWatchFile;
    function HelpPoint(Line, Ch: Integer): TPointF;   // the script: a character of the help (pixels)
    function HelpSelection: string;
    function VScrollPoint(Bar: Integer; Frac: Single): TPointF;   // the script: a place on a bar (0 top .. 1 bottom)
    function VScrollPos(Bar: Integer): Single;
    procedure TestMessages(N: Integer);   // the script: N compiler messages (a long list)
    function TagError(I: Integer): string;
  public
    LastShell: string;    // the script: what was given to the Explorer (VPLC_NO_SHELL: only this)
  public
    function ImportTags(const FileName: string): string;    // the CSV of a tag table: added / updated
    function ImportWatch(const FileName: string): string;   // the CSV of a watch table: rows added
    function ExportIpcHelp(const FileName: string): Boolean;   // the IPC help as a PDF
    function ImportIo(const FileName: string): string;        // the CSV of an I/O list: tags, input kinds, values
    function ExportHelpDoc(const FileName, Title, Intro: string; const Doc: THelpDoc): Boolean;   // a help page as PDF
    property IoHelpForm: THelpForm read FIoHelpForm;
    function IpcAnswer(const Line: string): string;
    function ViewText(K: Integer): string;   // the test: the rows shown (tags: names, watch: addresses)
    procedure TestGroupName(K, G: Integer; const S: string);   // the test: a group name typed and committed
    function IpcHelpOpen: Boolean;
    property HelpForm: THelpForm read FHelpForm;
    property AskTitle: string read FAskTitle;
    property NetSel: Integer read FNetSel;
    function NetHasCodePublic(N: TNetwork): Boolean;
    property Examples: TStringList read FExamples;
    property FileFolder: Integer read FFolder write FFolder;
    function UndoCount: Integer;
    function RedoCount: Integer;
    procedure UndoPublic(Redo: Boolean);   // the script
    procedure LoadExampleNow(I: Integer);   // the script: example I of the list, without a question
    function SaveAsText: string;
    function CaretInView(out Info: string): Boolean;   // the script: the keyboard caret inside the editor frame
    function CurBlockPublic: TBlock;
    { the script: the element (or the category title, IsCat) with the caption, brought into view }
    function ElemFind(const Cap: string; IsCat: Boolean): Integer;
    function ElemSnippet(I: Integer): string;
    { the script: .scl sources without the file dialogs, the views, Find Declaration }
    function ImportSclFile(const FileName: string; DataOnly: Boolean = False): string;
    function ExportSclFile(const FileName: string; All: Boolean): string;
    property ViewForm: THelpForm read FViewForm;
    procedure ShowViewPublic(Kind: Integer);
    procedure FindDeclarationPublic;
    procedure SetBlockHead(const AName, AVersion: string);   // the script: as typed into the fields
    property TagSel: Integer read FTagSel;
    property DBSel: Integer read FDBSel;
    property VarSel: Integer read FVarSel;
    property IfSel: Integer read FIfSel;
    property BlockSel: Integer read FBlockSel;
    property IoView: Integer read FIoView write FIoView;
    property TagGrpSel: Integer read FTagGrpSel write FTagGrpSel;
    property WatchGrpSel: Integer read FWatchGrpSel write FWatchGrpSel;
    property TagSort: Integer read FTagSort write FTagSort;
    property WatchSort: Integer read FWatchSort write FWatchSort;
    function DevMenuPoint(I: Integer): TPointF;      // the script: the Developer button (-1) or menu item I
    procedure AskClaude(const S: string);
    procedure AskClaudeWith(const S: string; const Files: TChatAttachments);   // the chat window
    procedure KeyDown(Key: TUiKey; Ch: Char; Mods: TUiMods); override;
    property Claude: TClaudeAgent read FClaude;
    property ChatOpen: Boolean read FChatOpen write FChatOpen;
    property KeyDialogOpen: Boolean read FKeyDlg;
    property ClaudeMenuOpen: Boolean read FClaudeMenu;
    function IfacePoint(I: Integer): TPointF;        // the grip of interface row I (last frame)
    property Dirty: Boolean read FDirty;
    property Monitor: Boolean read FMonitor write FMonitor;
  end;

implementation

const
  { action codes: Id = Code shl 16 + Param }
  acTab = 1; acRun = 2; acStop = 3; acMres = 4; acDownload = 5; acCompile = 6; acMonitor = 7;
  acModelSel = 8; acModelApply = 9; acFamView = 10; acPacing = 11; acDiagClear = 12; acSwitch = 13;
  acBlockSel = 20; acAddFC = 21; acAddCyc = 22; acAddStartup = 23; acDelBlock = 24; acNetSel = 25;
  acAddLad = 26; acAddStl = 27; acDelNet = 28; acNetUp = 29; acNetDown = 30; acCell = 31; acPal = 32;
  acBranch = 33; acCellDel = 34; acRowIns = 35; acRowDel = 36; acDType = 37; acCmpOp = 38;
  acNetKind = 39; acStlLine = 40; acMsg = 41; acAddOB1 = 42; acAddScl = 43;
  acDI = 50; acDIType = 51; acAI = 52; acAIMode = 53; acBusFault = 54; acAllOff = 55;
  acWatchRow = 60; acWatchFmt = 61; acWatchModOn = 62; acWatchAdd = 63; acWatchDel = 64;
  acModifyNow = 65; acForce = 66; acUnforce = 67; acUnforceAll = 68;
  acDBSel = 70; acDBAdd = 71; acDBDel = 72; acDBOpt = 73; acVarSel = 74; acVarAdd = 75; acVarDel = 76;
  acVarRetain = 77; acUdtAdd = 78;
  acFindNext = 113; acFindPrev = 114; acFindClose = 115; acFindCase = 116; acFindWord = 117;
  acReplOne = 118; acReplAll = 119; acGotoGo = 120; acComp = 121; acIfDrag = 122;
  acColAdd = 123; acColDel = 124; acHScroll = 125; acMenu = 126; acMenuClose = 127;
  acClaude = 200; acClaudeClose = 201; acClaudeUndo = 202; acClaudeNew = 203; acClaudeSend = 204;
  acClaudeStop = 205; acClaudeAllow = 206; acClaudeDeny = 207; acClaudeQuick = 208; acClaudeKeySave = 209;
  acClaudeKeyForget = 210; acClaudeBg = 211;
  fdClaudeKey = 213; acClaudeMenu = 214; acClaudeMenuClose = 215; acDevMenu = 216; acDevMenuClose = 217;
  acKeyRemove = 218; acCtx = 219; acCtxClose = 220; acAskOk = 221; acAskCancel = 222; acWatchMenu = 223;
  acNetHead = 226; acExportPc = 227; acLoadNow = 228; acWatchFile = 229; acHelp = 230; acHelpCopy = 231;
  acHelpAll = 232; acVScroll = 237; acAskDont = 233; acNewNow = 234; acSampleNow = 235; acQuitNow = 236;
  whLad = 1000;   // + network index: the wheel over a LAD network
  whBlocks = 8; whDBList = 9; whFiles = 10; whPal = 11;
  acDType2 = 243; acLadTypePick = 244;
  fdIp = 154; fdMask = 155; acIpMenu = 238; acIpPick = 239; acTagTypeMenu = 240; acVarTypeMenu = 241;
  acTypePick = 242; acIpcOn = 245; acIpcHelp = 246; acIpcHelpClose = 247; acIpcHelpPdf = 248; acExplorer = 249;
  acFileCtx = 250; acTagImport = 251; acLoadEx = 252; acLoadExNow = 253; acExplorerEx = 254;
  acFolder = 255; acFolderPick = 256; acUndo = 257; acRedo = 258; acStlCtx = 259; acAddMenu = 260;
  acAddNet = 261; acIoImport = 262; acIoHelp = 263; acIoHelpPdf = 264;
  acElem = 265; acElemCat = 266; acElemIns = 267; acElemCopy = 268; whElem = 13; acSclSrc = 269; acSclSrcMenu = 270;
  acIoView = 271; acTagIo = 272; acTagIoAi = 273; acSigAdd = 274; acSigDel = 275; acSigAll = 276; acSigOn = 277;
  acSigKind = 278; acSigKindPick = 279; acSigRow = 280; acSigTags = 281; acIoPage = 282;
  fdTagIoVal = 190; fdSigAddr = 191; fdSigLo = 192; fdSigHi = 193; fdSigPer = 194; fdSigDuty = 195; fdSigCmt = 196;
  whIo = 20;   // + list: the wheel over a list of the I/O screen
  { the trees of groups (tag table, watch table): Par = K * 16384 + the row; sorting; SCL of the Data blocks }
  acGrpSel = 283; acGrpOpen = 284; acGrpItem = 285; acGrpAdd = 286; acGrpDel = 287; acTagGrpMenu = 288;
  acTagGrpPick = 289; acSortTag = 290; acSortWatch = 291; acWatchGrpMenu = 292; acWatchGrpPick = 293;
  acDbScl = 294; fdGrpName = 197; whGrpTree = 14;
  IoHelpTitle = 'The I/O import file';
  IoHelpIntro = 'For developers: the CSV file that `Import I/O list (CSV) ...` on the I/O screen reads, its columns, ' +
    'addresses and rules, an example and a script that makes one.';
  whExamples = 12;
  fdFind = 166; fdRepl = 167; fdGoto = 168;
  acAddFB = 106; acIfToggle = 107; acIfSel = 108; acIfAdd = 109; acIfDel = 110; acIfSec = 111; acIfInst = 112;
  fdIfName = 160; fdIfType = 161; fdIfStart = 162; fdIfComment = 163; fdDBInst = 164; fdCallArg = 165;
  acTagSel = 80; acTagAdd = 81; acTagDel = 82;
  acNew = 90; acSample = 91; acSave = 92; acSaveAs = 93; acLoad = 94; acShot = 95; acInfo = 96;
  acExport = 97; acRefresh = 98;
  acS7On = 100; acMbOn = 101; acPutGet = 102; acIface = 103; acTestS7 = 104; acTestMb = 105;
  fdS7Port = 150; fdMbPort = 151; fdMbUnit = 152; fdMbHold = 153;
  { fields }
  fdNetTitle = 120; fdNetComment = 121; fdOpnd = 122; fdPar = 123; fdWatchAddr = 124; fdWatchMod = 125;
  fdDBName = 126; fdDBNum = 127; fdVarName = 128; fdVarType = 129; fdVarStart = 130; fdVarComment = 131;
  fdTagName = 132; fdTagType = 133; fdTagAddr = 134; fdTagComment = 135; fdProjName = 136;
  fdProjAuthor = 137; fdProjComment = 138; fdSaveAs = 139; fdCyclicMs = 140; fdClockByte = 141;
  fdBlockName = 142; fdAIValue = 143; fdDBComment = 144; fdBlockVer = 189;
  { wheel areas }
  whProg = 1; whMsgs = 2; whWatch = 3; whVars = 4; whTags = 5; whDiag = 6; whTraffic = 7;

{ a PLC data type was renamed: every DB variable and member that uses it follows }
procedure RenameUdtRefs(P: TPlcProject; const OldRef, NewRef: string);

  procedure Fix(D: TDataBlock);
  var
    K, Q: Integer;
    T: string;
  begin
    for K := 0 to High(D.Vars) do
    begin
      T := D.Vars[K].TypeText;
      Q := Pos(UpperCase(OldRef), UpperCase(T));
      // the whole type, or the element type after "of"
      if (Q > 0) and (Q + Length(OldRef) - 1 = Length(T)) and ((Q = 1) or (T[Q - 1] = ' ')) then
        D.Vars[K].TypeText := Copy(T, 1, Q - 1) + NewRef;
    end;
  end;

var
  I: Integer;
begin
  for I := 0 to P.DBCount - 1 do Fix(P.DB(I));
  for I := 0 to P.UdtCount - 1 do Fix(P.Udt(I));
  for I := 0 to P.BlockCount - 1 do Fix(P.Block(I).Iface);
end;

function Act(Code, Param: Integer): Integer; inline;
begin
  Result := Code shl 16 + (Param and $FFFF);
end;

{ TPlcUI }

constructor TPlcUI.Create(AGlyphs: TGlyphCache);
begin
  inherited Create(AGlyphs);
  Project := TPlcProject.Create;
  Project.NewEmpty(7);   // the start-up project: an empty S7-1200 (CPU 1214C), OB1 with one LAD network
  Rt := TPlcRuntime.Create(Project.ModelIdx);
  FFiles := TStringList.Create;
  FExamples := TStringList.Create;
  FElemOpen := TStringList.Create;
  FElemOpen.Add('CProgram control');
  FElemOpen.Add('SBit logic');
  FElemOpen.Add('LBit logic');
  FElemHover := -1;
  FElemPress := -1;
  // the example projects: written next to the exe when they are missing (a changed one stays)
  try
    WriteExamples(ExamplesDir);
  except
  end;
  FEd := TTextEdit.Create;
  FComp := TStringList.Create;
  FClaude := TClaudeAgent.Create;
  FClaude.Project := Project;
  FClaude.Rt := Rt;
  FClaude.OnChanged := @ClaudeChanged;
  FClaude.OnReloaded := @ClaudeReloaded;
  FClaude.OnDownload := @Download;
  FClaude.OnCompiled := @ClaudeCompiled;
  FClaude.IsDirty := @ClaudeDirty;
  MaskId := Act(fdClaudeKey, 0);
  FDragPress := -1;
  FVsDrag := -1;
  FVs[0].X := 0;
  FLsNet := -1;
  FStlNet := -1;
  FNetSel := 0;
  FCellR := 0;
  FCellC := 0;
  FWatchSel := 0;
  FModelSel := Project.ModelIdx;
  FFamView := Project.Family;
  FSwitchPos := 1;
  Screen := scCpu;
  ResetResolver;
  ApplyInputRest;
  Hub := TCommHub.Create(Rt);
  ApplyComm;
end;

destructor TPlcUI.Destroy;
begin
  // the servers first: their threads talk to the runtime
  FreeAndNil(FIpc);
  FreeAndNil(Hub);
  FreeAndNil(Rt);
  FRes.Free;
  Project.Free;
  FFiles.Free;
  FExamples.Free;
  FElemOpen.Free;
  FreeAndNil(FHelpForm);
  FreeAndNil(FViewForm);
  FreeAndNil(FIoHelpForm);
  FEd.Free;
  FComp.Free;
  FClaude.Free;
  inherited Destroy;
end;

function TPlcUI.HitCount: Integer;
begin
  Result := FLastHitN;
end;

procedure TPlcUI.ShowBlock(AKind: TBlockKind; ANumber: Integer);
var
  I: Integer;
begin
  Screen := scProgram;
  for I := 0 to Project.BlockCount - 1 do
    if (Project.Block(I).Kind = AKind) and (Project.Block(I).Number = ANumber) then FBlockSel := I;
  FNetSel := 0;
  FStlNet := -1;
  FProgScroll := 0;
end;

function TPlcUI.CellPoint(NI, R, C: Integer): TPointF;
begin
  Result := PointF(0, 0);
  if (NI < 0) or (NI >= Length(FLadTops)) or (R + 1 > High(FLadTops[NI])) or (NI >= Length(FLadX0)) then Exit;
  Result := PointF(FLadX0[NI] + (C + 0.5) * FLadCW, (FLadTops[NI][R] + FLadTops[NI][R + 1]) / 2);
end;

function TPlcUI.IfacePoint(I: Integer): TPointF;
begin
  Result := PointF(FIfGripX, FIfGripY + I * 26);
end;

function TPlcUI.CaretPoint: TPointF;
begin
  Result := PointF(FCaretX, FCaretY);
end;

procedure TPlcUI.SelectCell(ANet, R, C: Integer);
begin
  if CurBlock = nil then Exit;
  if ANet < 0 then ANet := CurBlock.NetCount - 1;
  FNetSel := ANet;
  FStlNet := -1;
  FCellR := R;
  FCellC := C;
  LadCollapse;
  FScrollToCaret := True;
end;

procedure TPlcUI.ShowDataType(I: Integer);
begin
  Screen := scDB;
  FDBSel := Project.DBCount + I;
  FVarSel := 0;
  FVarScroll := 0;
end;

procedure TPlcUI.FocusStl(ANet, ARow, ACol: Integer);
begin
  Screen := scProgram;
  FNetSel := ANet;
  if (CurNet = nil) or not (CurNet.Kind in [nkSTL, nkSCL]) then Exit;
  FStlNet := ANet;
  FStlRow := ARow;
  FStlCol := ACol;
end;

procedure TPlcUI.ResetResolver;
begin
  FreeAndNil(FRes);
  FRes := TResolver.Create(Project);
end;

procedure TPlcUI.InvalidateStatic;
begin
  FStaticKey := '';
end;

procedure TPlcUI.Toast(const S: string; Err: Boolean);
begin
  FToast := S;
  FToastT := FTime;
  FToastErr := Err;
end;

procedure TPlcUI.MarkDirty;
begin
  FPPending := True;
  FDirty := True;
  Project.Modified := True;
  if FMonitor then
  begin
    FMonitor := False;
    Rt.MonBlock := -1;
  end;
end;

function TPlcUI.CurBlock: TBlock;
begin
  if (FBlockSel < 0) or (FBlockSel >= Project.BlockCount) then FBlockSel := 0;
  if Project.BlockCount = 0 then Exit(nil);
  Result := Project.Block(FBlockSel);
end;

function TPlcUI.CurNet: TNetwork;
var
  B: TBlock;
begin
  Result := nil;
  B := CurBlock;
  if (B = nil) or (FNetSel < 0) or (FNetSel >= B.NetCount) then Exit;
  Result := B.Net(FNetSel);
end;

function TPlcUI.CompiledBlock: TCBlock;
var
  B: TBlock;
  I: Integer;
begin
  Result := nil;
  B := CurBlock;
  if (B = nil) or (Rt.Prog = nil) then Exit;
  I := Rt.Prog.FindBlock(B.Kind, B.Number);
  if I >= 0 then Result := Rt.Prog.Blocks[I];
end;

function TPlcUI.MonitorOk: Boolean;
begin
  Result := FMonitor and not FDirty and (Rt.Prog <> nil) and (CompiledBlock <> nil);
end;

procedure TPlcUI.CompileOnly;
var
  P: TCProgram;
begin
  P := Compile(Project);
  try
    FMsgs := Copy(P.Msgs);
    FMsgErrors := P.ErrorCount;
    FMsgScroll := 0;
    if P.ErrorCount = 0 then
      Toast(Format('Compiled: %d blocks, %d bytes code, %d bytes data, %d warnings', [Length(P.Blocks),
        P.CodeBytes, P.DataBytes, P.WarnCount]))
    else
      Toast(Format('Compile: %d errors', [P.ErrorCount]), True);
  finally
    P.Free;
  end;
end;

procedure TPlcUI.Download;
var
  P: TCProgram;
begin
  EndEdit(True);
  P := Compile(Project);
  FMsgs := Copy(P.Msgs);
  FMsgErrors := P.ErrorCount;
  FMsgScroll := 0;
  if P.ErrorCount > 0 then
  begin
    Toast(Format('Download refused: %d compile errors (see Program)', [P.ErrorCount]), True);
    P.Free;
    Exit;
  end;
  Rt.CmdDownload(P);
  FDirty := False;
  FEverDownloaded := True;
  Toast(Format('Downloaded to %s: %d blocks, %d DBs', [Project.Model.Name, Length(P.Blocks), Length(P.DBs)]));
end;

procedure TPlcUI.ApplyInputRest;
var
  I: Integer;
begin
  // switches off, push buttons released (a NC button gives 1)
  for I := 0 to Min(Rt.Model.DI, 64) - 1 do
  begin
    FDIPressed[I] := False;
    Rt.SetSimBit(Rt.Model.DIByte + I div 8, I mod 8, Project.DIch[I].InType = itPushNC);
  end;
end;

procedure TPlcUI.SyncModel;
begin
  if Rt.ModelIdx <> Project.ModelIdx then Rt.CmdSetModel(Project.ModelIdx);
  // the memory is re-allocated by the PLC thread: wait for it before touching it
  Rt.WaitCommands(2000);
  ApplyInputRest;
  ApplyComm;
end;

procedure TPlcUI.ApplyComm;
begin
  if Hub <> nil then Hub.Apply(Project.Comm, Project.Model, Project.Name);
  ApplyIpc;
end;

{ ---------- IPC: the named pipe for programs on this PC ---------- }

procedure TPlcUI.ApplyIpc;
begin
  if Project.Comm.IpcOn and (FIpc = nil) then FIpc := TIpcServer.Create(@IpcRequest)
  else if not Project.Comm.IpcOn and (FIpc <> nil) then FreeAndNil(FIpc);
end;

function TPlcUI.IpcAnswer(const Line: string): string;
begin
  Result := IpcRequest(Line);
end;

{ a request of an IPC client (the main thread): READ, WRITE, STATE, RUN, STOP, TAGS, PING, HELP }
function TPlcUI.IpcRequest(const Line: string): string;
var
  Cmd, Rest, Opd, Val, E: string;
  P, K: Integer;
  O: TOperand;
  V: LongWord;
begin
  P := Pos(' ', Line);
  if P = 0 then
  begin
    Cmd := UpperCase(Line);
    Rest := '';
  end
  else
  begin
    Cmd := UpperCase(Copy(Line, 1, P - 1));
    Rest := Trim(Copy(Line, P + 1, MaxInt));
  end;
  case Cmd of
    'PING': Result := 'OK Virtual PLC ' + Project.Model.Name;
    'STATE':
      if Rt.Mode = rmRun then Result := 'OK RUN' else Result := 'OK STOP';
    'RUN':
      begin
        Rt.CmdRun;
        Result := 'OK';
      end;
    'STOP':
      begin
        Rt.CmdStop;
        Result := 'OK';
      end;
    'READ':
      if Rest = '' then Result := 'ERR READ <operand>'
      else if not FRes.Resolve(Rest, O, E, False) then Result := 'ERR ' + E
      else if O.Kind <> okAddr then Result := 'ERR not an address: ' + Rest
      else
      begin
        Result := LiveText(O, '');
        if Result = '' then Result := 'ERR no value' else Result := 'OK ' + Result;
      end;
    'WRITE':
      begin
        // the operand, then the value (a symbol in quotes may hold spaces)
        if (Rest <> '') and (Rest[1] = '"') and (Pos('"', Copy(Rest, 2, MaxInt)) > 0) then
        begin
          P := Pos('"', Copy(Rest, 2, MaxInt)) + 1;
          while (P < Length(Rest)) and (Rest[P + 1] <> ' ') do Inc(P);
        end
        else
          P := Pos(' ', Rest) - 1;
        if P <= 0 then Exit('ERR WRITE <operand> <value>');
        Opd := Trim(Copy(Rest, 1, P));
        Val := Trim(Copy(Rest, P + 1, MaxInt));
        if Val = '' then Exit('ERR WRITE <operand> <value>');
        if not FRes.Resolve(Opd, O, E, False) then Exit('ERR ' + E);
        if O.Kind <> okAddr then Exit('ERR not an address: ' + Opd);
        if not ParseValueText(Val, O.A.Size, DefaultFmt(O), V) then Exit('ERR the value does not fit ' + Opd + ': ' + Val);
        // an input bit: the simulated switch (the CPU reads it into the process image)
        if (O.A.Area = arI) and (O.A.Size = osBit) then Rt.SetSimBit(O.A.Ofs, O.A.Bit, V <> 0)
        else Rt.CmdModify(O, V);
        Result := 'OK';
      end;
    'TAGS':
      begin
        Result := Format('OK %d', [Length(Project.Tags)]);
        for K := 0 to High(Project.Tags) do
          Result := Result + #10 + Project.Tags[K].Name + ';' + Project.Tags[K].TypeText + ';' + Project.Tags[K].Address;
        Result := Result + #10 + 'END';
      end;
    'HELP': Result := 'OK PING | STATE | RUN | STOP | READ <operand> | WRITE <operand> <value> | TAGS';
  else
    Result := 'ERR unknown command ' + Cmd + ' (HELP lists them)';
  end;
end;

type
  THelpLine = record
    K: Integer;     // 0 a head, 1 text, 2 code
    S: string;
  end;

const
  IpcHelp: array[0..41] of THelpLine = (
    (K: 0; S: 'IPC: programs on this PC talk to the Virtual PLC'),
    (K: 1; S: 'The IPC server is the Windows named pipe  \\.\pipe\VirtualPLC. Turn it on on the Ports screen.'),
    (K: 1; S: 'It needs no network, no port and no firewall question: Python, C#, PowerShell, Node-RED, a test'),
    (K: 1; S: 'script ... on the same PC read and write the PLC''s tags, addresses and data blocks.'),
    (K: 0; S: 'The protocol: a text line each way (UTF-8, ending in LF)'),
    (K: 2; S: 'PING                      ->  OK Virtual PLC <CPU>'),
    (K: 2; S: 'STATE                     ->  OK RUN | OK STOP'),
    (K: 2; S: 'RUN / STOP                ->  OK'),
    (K: 2; S: 'READ <operand>            ->  OK <value>      READ "Motor"  ->  OK TRUE'),
    (K: 2; S: 'WRITE <operand> <value>   ->  OK              WRITE %MW20 123,  WRITE "Start_PB" TRUE'),
    (K: 2; S: 'TAGS                      ->  OK <n>, n lines  name;type;address, END'),
    (K: 2; S: 'an error                  ->  ERR <why>'),
    (K: 1; S: 'Operands as in the program: "Tag", %I0.0 / %MW20 / %MD100, "DB".Var, "DB".Arr[2].Member.'),
    (K: 1; S: 'Values as in the watch table: TRUE / FALSE, 123, -5, 1.5, T#2S, 16#FF. A digital input written'),
    (K: 1; S: 'by WRITE is the simulated switch (like the I/O screen); other values are written at the cycle.'),
    (K: 0; S: 'Python'),
    (K: 2; S: 'f = open(r"\\.\pipe\VirtualPLC", "r+b", buffering=0)'),
    (K: 2; S: 'def plc(cmd):'),
    (K: 2; S: '    f.write((cmd + "\n").encode()); line = b""'),
    (K: 2; S: '    while not line.endswith(b"\n"): line += f.read(1)'),
    (K: 2; S: '    return line.decode().strip()'),
    (K: 2; S: 'print(plc("READ "Motor""))          # OK FALSE'),
    (K: 2; S: 'print(plc("WRITE "Start_PB" TRUE"))  # OK'),
    (K: 0; S: 'PowerShell'),
    (K: 2; S: '$p = New-Object System.IO.Pipes.NamedPipeClientStream(".", "VirtualPLC", "InOut")'),
    (K: 2; S: '$p.Connect(2000); $w = New-Object System.IO.StreamWriter($p); $w.AutoFlush = $true'),
    (K: 2; S: '$r = New-Object System.IO.StreamReader($p)'),
    (K: 2; S: '$w.Write("READ %MW20`n"); $r.ReadLine()'),
    (K: 0; S: 'C#'),
    (K: 2; S: 'using var p = new NamedPipeClientStream(".", "VirtualPLC", PipeDirection.InOut);'),
    (K: 2; S: 'p.Connect(2000);'),
    (K: 2; S: 'var w = new StreamWriter(p) { AutoFlush = true, NewLine = "\n" }; var r = new StreamReader(p);'),
    (K: 2; S: 'w.WriteLine("WRITE %MW20 123"); Console.WriteLine(r.ReadLine());'),
    (K: 0; S: 'Node-RED, others'),
    (K: 1; S: 'Anything that opens a Windows named pipe works: write a line, read a line. For tools on other'),
    (K: 1; S: 'PCs use the S7 server (snap7, HMI, SCADA) or Modbus TCP on the same Ports screen.'),
    (K: 0; S: 'Good to know'),
    (K: 1; S: 'Many clients at once are fine; each has its own connection. The pipe is there while the switch'),
    (K: 1; S: 'is on and the Virtual PLC runs; the switch is saved with the project. Download the program'),
    (K: 1; S: 'first: READ / WRITE of "DB".Var need the DB in the CPU. Traffic: the requests are counted on'),
    (K: 1; S: 'the Ports screen.'),
    (K: 1; S: ''));

procedure TPlcUI.LoadExampleNow(I: Integer);
begin
  RefreshFiles;
  FFolder := 1;
  DoClick(Act(acLoadExNow, I), '');
end;

function TPlcUI.IpcHelpOpen: Boolean;
begin
  Result := Assigned(FHelpForm) and FHelpForm.Visible;
end;

procedure TPlcUI.HelpPdf(Sender: TObject);
begin
  DoClick(Act(acIpcHelpPdf, 0), '');
end;

procedure TPlcUI.IoHelpPdf(Sender: TObject);
begin
  DoClick(Act(acIoHelpPdf, 0), '');
end;

function TPlcUI.ExportIpcHelp(const FileName: string): Boolean;
var
  It: TPdfItems;
  I, N: Integer;
  Y: Single;

  procedure Add(X, AY: Single; const S, Face: string; Bold: Boolean; Size: Single; C: TBGRAPixel);
  begin
    SetLength(It, N + 1);
    It[N] := Default(TPdfItem);
    It[N].Kind := piText;
    It[N].X := X;
    It[N].Y := AY;
    It[N].Face := Face;
    It[N].Bold := Bold;
    It[N].Size := Size;
    It[N].Text := S;
    It[N].C := C;
    Inc(N);
  end;

begin
  Result := False;
  N := 0;
  It := nil;
  Add(40, 40, 'Virtual PLC: connect programs on this PC through IPC', 'Segoe UI', True, 16, cRedDark);
  Add(40, 64, Format('%s    %s', [FormatDateTime('yyyy-mm-dd', Now), Project.Model.Name]), 'Segoe UI', False, 9.5, cInkSoft);
  Y := 90;
  for I := 0 to High(IpcHelp) do
    case IpcHelp[I].K of
      0:
        begin
          Y := Y + 8;
          Add(40, Y, IpcHelp[I].S, 'Segoe UI', True, 12.5, cRedDark);
          Y := Y + 20;
        end;
      2:
        begin
          SetLength(It, N + 1);
          It[N] := Default(TPdfItem);
          It[N].Kind := piRect;
          It[N].X := 40;
          It[N].Y := Y - 2;
          It[N].W := 515;
          It[N].H := 14;
          It[N].C := Alpha(cSheet2, 200);
          Inc(N);
          Add(46, Y, IpcHelp[I].S, 'Consolas', False, 8.5, cInk);
          It[N - 1].W := 505;
          It[N - 1].Fit := True;
          Y := Y + 14;
        end;
    else
      begin
        Add(40, Y, IpcHelp[I].S, 'Segoe UI', False, 10, cInk);
        Y := Y + 15;
      end;
    end;
  try
    WriteChatPdf(FileName, 'Virtual PLC - IPC help', It, Y + 40);
    Toast('Exported ' + ExtractFileName(FileName));
    Result := True;
  except
    on Ex: Exception do Toast('Export failed: ' + Ex.Message, True);
  end;
end;

{ the Explorer: a folder, or a file selected in its folder (VPLC_NO_SHELL: only noted, for a test) }
procedure TPlcUI.ShowInExplorer(const APath: string; Select: Boolean);
var
  Args: UnicodeString;
begin
  if Select then Args := '/select,"' + UTF8Decode(APath) + '"' else Args := '"' + UTF8Decode(APath) + '"';
  LastShell := 'explorer.exe ' + UTF8Encode(Args);
  if SysUtils.GetEnvironmentVariable('VPLC_NO_SHELL') <> '' then Exit;
  ShellExecuteW(0, 'open', 'explorer.exe', PWideChar(Args), nil, 1);   // SW_SHOWNORMAL
end;

{ ---------- imports ---------- }

function ReadTextFile(const FileName: string): string;
var
  F: TFileStream;
begin
  F := TFileStream.Create(FileName, fmOpenRead or fmShareDenyWrite);
  try
    SetLength(Result, F.Size);
    if F.Size > 0 then F.ReadBuffer(Result[1], F.Size);
  finally
    F.Free;
  end;
end;

{ a tag table as CSV (this program's export, or TIA's PLC tags saved as CSV): a tag of the same name
  is updated, a new one added }
function TPlcUI.ImportTags(const FileName: string): string;
var
  Rows: TCsvRows;
  CN, CT, CA, CC, CP, I, J, K, G, Added, Updated, First: Integer;
  Nm, Gn: string;

  function Cell(R, C: Integer): string;
  begin
    if (C >= 0) and (C <= High(Rows[R])) then Result := Trim(Rows[R][C]) else Result := '';
  end;

begin
  Rows := CsvRows(ReadTextFile(FileName));
  if Length(Rows) = 0 then Exit('the file is empty');
  CN := CsvColumn(Rows[0], ['name']);
  CT := CsvColumn(Rows[0], ['data type', 'datatype', 'type']);
  CA := CsvColumn(Rows[0], ['logical address', 'address']);
  CC := CsvColumn(Rows[0], ['comment']);
  CP := CsvColumn(Rows[0], ['path', 'group', 'tag table']);
  First := 1;
  if (CN < 0) or (CA < 0) then
  begin
    // no head line: Name, Data type, Address, Comment
    CN := 0;
    CT := 1;
    CA := 2;
    CC := 3;
    First := 0;
  end;
  Added := 0;
  Updated := 0;
  for I := First to High(Rows) do
  begin
    Nm := Cell(I, CN);
    if Nm = '' then Continue;
    K := Project.FindTag(Nm);
    if K >= 0 then
    begin
      if Cell(I, CT) <> '' then Project.Tags[K].TypeText := Cell(I, CT);
      if Cell(I, CA) <> '' then Project.Tags[K].Address := Cell(I, CA);
      if CC >= 0 then Project.Tags[K].Comment := Cell(I, CC);
      Inc(Updated);
    end
    else
    begin
      if Cell(I, CT) <> '' then Project.AddTag(Nm, Cell(I, CT), Cell(I, CA), Cell(I, CC))
      else Project.AddTag(Nm, 'Bool', Cell(I, CA), Cell(I, CC));
      K := High(Project.Tags);
      Inc(Added);
    end;
    // Path / Group: into that group (made when it is new); TIA's default table and the root: none
    Gn := Cell(I, CP);
    if (CP >= 0) and (Gn <> '') and not SameText(Gn, AllTagsName) and not SameText(Gn, 'Default tag table') then
    begin
      G := -1;
      for J := 0 to High(Project.TagGroups) do
        if (G < 0) and SameText(Project.TagGroups[J].Name, Gn) then G := J;
      if G < 0 then G := GroupAdd(Project.TagGroups, Gn);
      Project.Tags[K].GroupId := Project.TagGroups[G].Id;
    end;
  end;
  if Added + Updated > 0 then
  begin
    Project.Modified := True;
    ResetResolver;
    FDirty := True;
  end;
  Result := Format('%d tags added, %d updated', [Added, Updated]);
end;

{ an I/O list as CSV (this program's export, or any file with an Address column): tags for the points,
  the kinds of the digital inputs, the generators of the analog inputs, the simulated input values }
function TPlcUI.ImportIo(const FileName: string): string;
var
  Rows: TCsvRows;
  CA, CT, CI, CV, CC, I, K, Idx, Byt, Bit, Num, V, First: Integer;
  Added, Updated, Kept, Inputs, Values, Skipped: Integer;
  M: TCpuModel;
  A, U, Nm, Tg, Inp, Val, Addr: string;
  Kind: Integer;   // 0 DI, 1 DQ, 2 AI, 3 AQ
  It: TInType;
  Am: TAiMode;
  Tia: Boolean;

  function Cell(R, C: Integer): string;
  begin
    if (C >= 0) and (C <= High(Rows[R])) then Result := Trim(Rows[R][C]) else Result := '';
  end;

  // I0.3 / Q4.1: the byte and the bit
  function BitAddr(const S: string; out B, Bi: Integer): Boolean;
  var
    P: Integer;
  begin
    P := Pos('.', S);
    Result := (P > 0) and TryStrToInt(Copy(S, 1, P - 1), B) and TryStrToInt(Copy(S, P + 1, MaxInt), Bi) and
      (Bi >= 0) and (Bi <= 7);
  end;

begin
  Rows := CsvRows(ReadTextFile(FileName));
  if Length(Rows) = 0 then Exit('the file is empty');
  CA := CsvColumn(Rows[0], ['address', 'logical address', 'operand']);
  CT := CsvColumn(Rows[0], ['tag', 'name', 'symbol']);
  CI := CsvColumn(Rows[0], ['input / range', 'input', 'mode', 'type']);
  CV := CsvColumn(Rows[0], ['value']);
  CC := CsvColumn(Rows[0], ['comment']);
  First := 1;
  if CA < 0 then
  begin
    // no head line: the order of the export
    CA := 1;
    CT := 2;
    CI := 3;
    CV := 4;
    CC := -1;
    First := 0;
  end;
  M := Rt.Model;
  Tia := IsTia(M.Family);
  Added := 0;
  Updated := 0;
  Kept := 0;
  Inputs := 0;
  Values := 0;
  Skipped := 0;
  for I := First to High(Rows) do
  begin
    A := Cell(I, CA);
    if A = '' then Continue;
    // the point: %I0.3, I0.3, %IW64, PIW288 ...
    U := UpperCase(StringReplace(A, ' ', '', [rfReplaceAll]));
    if (U <> '') and (U[1] = '%') then Delete(U, 1, 1);
    if (Copy(U, 1, 3) = 'PIW') or (Copy(U, 1, 3) = 'PQW') then Delete(U, 1, 1);
    Kind := -1;
    Idx := -1;
    Num := 0;
    if (Copy(U, 1, 2) = 'IW') and TryStrToInt(Copy(U, 3, MaxInt), Num) then
    begin
      Kind := 2;
      if ((Num - M.AIWord) mod 2 = 0) and (Num >= M.AIWord) then Idx := (Num - M.AIWord) div 2;
      if Idx >= M.AI then Idx := -1;
    end
    else if (Copy(U, 1, 2) = 'QW') and TryStrToInt(Copy(U, 3, MaxInt), Num) then
    begin
      Kind := 3;
      if ((Num - M.AQWord) mod 2 = 0) and (Num >= M.AQWord) then Idx := (Num - M.AQWord) div 2;
      if Idx >= M.AQ then Idx := -1;
    end
    else if (Copy(U, 1, 1) = 'I') and BitAddr(Copy(U, 2, MaxInt), Byt, Bit) then
    begin
      Kind := 0;
      Idx := (Byt - M.DIByte) * 8 + Bit;
      if (Byt < M.DIByte) or (Idx >= M.DI) then Idx := -1;
    end
    else if (Copy(U, 1, 1) = 'Q') and BitAddr(Copy(U, 2, MaxInt), Byt, Bit) then
    begin
      Kind := 1;
      Idx := (Byt - M.DQByte) * 8 + Bit;
      if (Byt < M.DQByte) or (Idx >= M.DQ) then Idx := -1;
    end;
    if (Kind < 0) or (Idx < 0) then
    begin
      Inc(Skipped);
      Continue;
    end;
    // the address as this CPU writes it
    case Kind of
      0, 1: Addr := U;
    else
      if Tia then Addr := U else Addr := 'P' + U;
    end;
    if Tia then Addr := '%' + Addr;
    // the tag
    Nm := Cell(I, CT);
    if Nm <> '' then
    begin
      Tg := IoTagFor(U);
      if (Tg = '') and (Kind >= 2) then Tg := IoTagFor('P' + U);
      if Tg = '' then
      begin
        if Project.FindTag(Nm) >= 0 then Inc(Skipped)
        else
        begin
          if Kind <= 1 then Project.AddTag(Nm, 'Bool', Addr, Cell(I, CC))
          else Project.AddTag(Nm, 'Int', Addr, Cell(I, CC));
          Inc(Added);
        end;
      end
      else if SameText(Tg, Nm) then
      begin
        K := Project.FindTag(Tg);
        if (K >= 0) and (CC >= 0) and (Cell(I, CC) <> '') then Project.Tags[K].Comment := Cell(I, CC);
        Inc(Updated);
      end
      else
        Inc(Kept);
    end;
    // the kind of an input, its value
    Inp := LowerCase(Cell(I, CI));
    Val := UpperCase(Cell(I, CV));
    if Kind = 0 then
    begin
      for It := Low(TInType) to High(TInType) do
        if (Inp = LowerCase(InTypeNames[It])) or ((It = itToggle) and (Inp = 'toggle')) or
          ((It = itPushNO) and (Inp = 'no')) or ((It = itPushNC) and (Inp = 'nc')) then
        begin
          if Project.DIch[Idx].InType <> It then
          begin
            Project.DIch[Idx].InType := It;
            // a push button rests released (a NC one gives 1)
            Rt.SetSimBit(M.DIByte + Idx div 8, Idx mod 8, It = itPushNC);
          end;
          Inc(Inputs);
          Break;
        end;
      if (Val = 'TRUE') or (Val = '1') or (Val = 'ON') then
      begin
        Rt.SetSimBit(M.DIByte + Idx div 8, Idx mod 8, True);
        Inc(Values);
      end
      else if (Val = 'FALSE') or (Val = '0') or (Val = 'OFF') then
      begin
        Rt.SetSimBit(M.DIByte + Idx div 8, Idx mod 8, False);
        Inc(Values);
      end;
    end
    else if Kind = 2 then
    begin
      for Am := Low(TAiMode) to High(TAiMode) do
        if Pos(AiModeNames[Am], Inp) > 0 then
        begin
          Project.AIch[Idx].AiMode := Am;
          Inc(Inputs);
          Break;
        end;
      if TryStrToInt(Val, V) then
      begin
        Project.AIch[Idx].AiMode := amManual;
        Project.AIch[Idx].AiValue := EnsureRange(V, -32768, 32767);
        Inc(Values);
      end;
    end;
  end;
  if Added + Updated + Inputs + Values > 0 then
  begin
    MarkDirty;
    ResetResolver;
  end;
  Result := Format('%d tags added, %d updated, %d kept, %d inputs set, %d values set, %d skipped',
    [Added, Updated, Kept, Inputs, Values, Skipped]);
end;

{ a help page (THelpDoc) as a PDF: the same items as the HTML window, laid out on A4 }
function TPlcUI.ExportHelpDoc(const FileName, Title, Intro: string; const Doc: THelpDoc): Boolean;
var
  It: TPdfItems;
  I, J, K, N, Cols, Lines, MaxL: Integer;
  Y, X, H: Single;
  Cells: TStringList;
  Wid: array of Single;
  Len: array of Integer;
  SL: TStringList;

  procedure Add(AX, AY: Single; const S, Face: string; Bold: Boolean; Size: Single; C: TBGRAPixel);
  begin
    SetLength(It, N + 1);
    It[N] := Default(TPdfItem);
    It[N].Kind := piText;
    It[N].X := AX;
    It[N].Y := AY;
    It[N].Face := Face;
    It[N].Bold := Bold;
    It[N].Size := Size;
    It[N].Text := S;
    It[N].C := C;
    Inc(N);
  end;

  procedure Box(AX, AY, AW, AH: Single; C: TBGRAPixel);
  begin
    SetLength(It, N + 1);
    It[N] := Default(TPdfItem);
    It[N].Kind := piRect;
    It[N].X := AX;
    It[N].Y := AY;
    It[N].W := AW;
    It[N].H := AH;
    It[N].C := C;
    Inc(N);
  end;

  procedure Line(AX, AY, AW, AH: Single);
  begin
    SetLength(It, N + 1);
    It[N] := Default(TPdfItem);
    It[N].Kind := piLine;
    It[N].X := AX;
    It[N].Y := AY;
    It[N].W := AW;
    It[N].H := AH;
    It[N].Size := 0.6;
    It[N].C := BGRA(217, 198, 160);
    Inc(N);
  end;

  function Plain(const S: string): string;
  begin
    Result := StringReplace(S, '`', '', [rfReplaceAll]);
  end;

  // the words of S in lines of at most W characters
  function Wrap(const S: string; W: Integer): TStringList;
  var
    Words: TStringList;
    L: string;
    P: Integer;
  begin
    Result := TStringList.Create;
    // the words (quotes stay as they are)
    Words := TStringList.Create;
    try
      L := '';
      for P := 1 to Length(S) do
        if S[P] = ' ' then
        begin
          if L <> '' then Words.Add(L);
          L := '';
        end
        else
          L := L + S[P];
      if L <> '' then Words.Add(L);
      L := '';
      for P := 0 to Words.Count - 1 do
        if (L <> '') and (UTF8Length(L) + 1 + UTF8Length(Words[P]) > W) then
        begin
          Result.Add(L);
          L := Words[P];
        end
        else if L = '' then L := Words[P]
        else L := L + ' ' + Words[P];
      if L <> '' then Result.Add(L);
    finally
      Words.Free;
    end;
  end;

  procedure Para(AX: Single; const S: string; W: Integer);
  var
    P: Integer;
  begin
    SL := Wrap(Plain(S), W);
    try
      for P := 0 to SL.Count - 1 do
      begin
        Add(AX, Y, SL[P], 'Segoe UI', False, 10, cInk);
        Y := Y + 14;
      end;
    finally
      SL.Free;
    end;
  end;

begin
  Result := False;
  N := 0;
  It := nil;
  Add(40, 40, Title, 'Segoe UI', True, 16, cRedDark);
  Add(40, 64, Format('Virtual PLC    %s    %s', [FormatDateTime('yyyy-mm-dd', Now), Project.Model.Name]), 'Segoe UI',
    False, 9.5, cInkSoft);
  Y := 90;
  if Intro <> '' then
  begin
    Para(40, Intro, 104);
    Y := Y + 4;
  end;
  I := 0;
  while I <= High(Doc) do
  begin
    case Doc[I].K of
      hkHead:
        begin
          Y := Y + 8;
          Add(40, Y, Doc[I].S, 'Segoe UI', True, 12.5, cRedDark);
          Y := Y + 22;
        end;
      hkText:
        begin
          Para(40, Doc[I].S, 104);
          Y := Y + 4;
        end;
      hkBullet:
        begin
          Add(44, Y, #$E2#$80#$A2, 'Segoe UI', False, 10, cRed);
          Para(56, Doc[I].S, 100);
          Y := Y + 2;
        end;
      hkCode:
        begin
          Box(40, Y - 2, 515, 14, Alpha(cSheet2, 200));
          Add(46, Y, Doc[I].S, 'Consolas', False, 8.5, cInk);
          It[N - 1].W := 505;
          It[N - 1].Fit := True;
          Y := Y + 14;
          if (I = High(Doc)) or (Doc[I + 1].K <> hkCode) then Y := Y + 6;
        end;
    else
      begin
        // a table: the rows in a row; the columns as wide as their longest text needs
        J := I;
        while (J <= High(Doc)) and (Doc[J].K = hkRow) do Inc(J);
        Cols := 0;
        for K := I to J - 1 do
        begin
          Cells := HelpCells(Doc[K].S);
          Cols := Max(Cols, Cells.Count);
          Cells.Free;
        end;
        SetLength(Len, Cols);
        SetLength(Wid, Cols);
        for K := 0 to Cols - 1 do Len[K] := 9;
        for K := I to J - 1 do
        begin
          Cells := HelpCells(Doc[K].S);
          for MaxL := 0 to Cells.Count - 1 do
            Len[MaxL] := Max(Len[MaxL], Min(60, UTF8Length(Plain(Cells[MaxL]))));
          Cells.Free;
        end;
        MaxL := 0;
        for K := 0 to Cols - 1 do MaxL := MaxL + Len[K];
        for K := 0 to Cols - 1 do Wid[K] := 515 * Len[K] / MaxL;
        for K := I to J - 1 do
        begin
          Cells := HelpCells(Doc[K].S);
          try
            // the row is as high as its longest cell
            Lines := 1;
            for MaxL := 0 to Cells.Count - 1 do
            begin
              SL := Wrap(Plain(Trim(Cells[MaxL])), Max(6, Round(Wid[MaxL] / 4.7)));
              Lines := Max(Lines, SL.Count);
              SL.Free;
            end;
            H := Lines * 11.5 + 7;
            if K = I then Box(40, Y, 515, H, BGRA(232, 216, 184));
            Line(40, Y, 515, 0);
            X := 40;
            for MaxL := 0 to Cells.Count - 1 do
            begin
              SL := Wrap(Plain(Trim(Cells[MaxL])), Max(6, Round(Wid[MaxL] / 4.7)));
              for Lines := 0 to SL.Count - 1 do
                Add(X + 4, Y + 4 + Lines * 11.5, SL[Lines], 'Segoe UI', K = I, 8.5, cInk);
              SL.Free;
              Line(X, Y, 0, H);
              X := X + Wid[MaxL];
            end;
            Line(40 + 515, Y, 0, H);
            Y := Y + H;
          finally
            Cells.Free;
          end;
        end;
        Line(40, Y, 515, 0);
        Y := Y + 10;
        I := J - 1;
      end;
    end;
    Inc(I);
  end;
  try
    WriteChatPdf(FileName, Title, It, Y + 40);
    Toast('Exported ' + ExtractFileName(FileName));
    Result := True;
  except
    on Ex: Exception do Toast('Export failed: ' + Ex.Message, True);
  end;
end;

{ a watch table as CSV (this program's export, or a column of addresses): the rows go after the table's }
function TPlcUI.ImportWatch(const FileName: string): string;
var
  Rows: TCsvRows;
  CA, CF, CM, I, Added, First: Integer;
  F: TDispFmt;
  A: string;

  function Cell(R, C: Integer): string;
  begin
    if (C >= 0) and (C <= High(Rows[R])) then Result := Trim(Rows[R][C]) else Result := '';
  end;

begin
  Rows := CsvRows(ReadTextFile(FileName));
  if Length(Rows) = 0 then Exit('the file is empty');
  CA := CsvColumn(Rows[0], ['address / symbol', 'address', 'operand', 'name']);
  CF := CsvColumn(Rows[0], ['format', 'display']);
  CM := CsvColumn(Rows[0], ['modify value', 'modify']);
  First := 1;
  if CA < 0 then
  begin
    CA := 0;
    First := 0;
  end;
  Added := 0;
  for I := First to High(Rows) do
  begin
    A := Cell(I, CA);
    if A = '' then Continue;
    Project.AddWatch(A, dfDec, Cell(I, CM));
    // the format: as written, else what fits the operand
    Project.Watch[High(Project.Watch)].Fmt := dfDec;
    for F := Low(TDispFmt) to High(TDispFmt) do
      if SameText(DispFmtNames[F], Cell(I, CF)) then Project.Watch[High(Project.Watch)].Fmt := F;
    Inc(Added);
  end;
  if Added > 0 then Project.Modified := True;
  Result := Format('%d rows added', [Added]);
end;

procedure TPlcUI.ApplyModel(AIdx: Integer);
begin
  if AIdx = Project.ModelIdx then Exit;
  Project.ModelIdx := AIdx;
  Rt.CmdSetModel(AIdx);
  Rt.WaitCommands(2000);
  ApplyInputRest;
  ApplyComm;
  FMonitor := False;
  FEverDownloaded := False;
  FDirty := True;
  Project.Modified := True;
  ResetResolver;
  InvalidateStatic;
  CompileOnly;
  Toast('CPU changed to ' + Models[AIdx].Name + ': compile and download the program again');
end;

procedure TPlcUI.LoadSampleFor(AModel: Integer);
begin
  Rt.CmdStop;
  Project.LoadSample(AModel);
  ProgUndoReset;
  Rt.CmdUnforceAll;
  SyncModel;
  FBlockSel := 0;
  FDBSel := 0;
  FVarSel := 0;
  FVarScroll := 0;
  FNetSel := 0;
  FCellR := 0;
  FCellC := 0;
  FStlNet := -1;
  FProgScroll := 0;
  FModelSel := AModel;
  FFamView := Project.Family;
  ResetResolver;
  InvalidateStatic;
  Download;
  Toast('Sample loaded and downloaded: ' + Project.Name);
end;

procedure TPlcUI.LoadProjectFile(const AFile: string);
var
  P: TPlcProject;
begin
  P := TPlcProject.Create;
  try
    P.LoadFromFile(AFile);
  except
    on E: Exception do
    begin
      Toast('Load failed: ' + E.Message, True);
      P.Free;
      Exit;
    end;
  end;
  Rt.CmdStop;
  Project.Free;
  Project := P;
  ProgUndoReset;
  Rt.CmdUnforceAll;
  SyncModel;
  FBlockSel := 0;
  FDBSel := 0;
  FVarSel := 0;
  FVarScroll := 0;
  FNetSel := 0;
  FStlNet := -1;
  FProgScroll := 0;
  FModelSel := Project.ModelIdx;
  FFamView := Project.Family;
  ResetResolver;
  InvalidateStatic;
  Download;
  Toast('Loaded ' + ExtractFileName(AFile));
end;

function TPlcUI.ProjectsDir: string;
begin
  Result := ExtractFilePath(ParamStr(0)) + 'projects' + PathDelim;
end;

function TPlcUI.ExamplesDir: string;
begin
  Result := ExtractFilePath(ParamStr(0)) + 'examples' + PathDelim;
end;

procedure TPlcUI.SaveProject;
begin
  SaveProjectOk;
end;

function TPlcUI.SaveProjectOk: Boolean;
var
  F: string;
begin
  Result := False;
  EndEdit(True);
  F := Project.FileName;
  if F = '' then
  begin
    ForceDirectories(ProjectsDir);
    F := ProjectsDir + StringReplace(StringReplace(Trim(Project.Name), ' ', '_', [rfReplaceAll]), '/', '-',
      [rfReplaceAll]) + '.vplc';
  end;
  try
    Project.SaveToFile(F);
    Toast('Saved ' + F);
    Result := True;
  except
    on E: Exception do Toast('Save failed: ' + E.Message, True);
  end;
  RefreshFiles;
end;

procedure TPlcUI.RefreshFiles;

  procedure Fill(L: TStringList; const Dir: string);
  var
    SR: TSearchRec;
  begin
    L.Clear;
    ForceDirectories(Dir);
    if FindFirst(Dir + '*.vplc', faAnyFile, SR) = 0 then
    begin
      repeat
        L.Add(SR.Name);
      until FindNext(SR) <> 0;
      FindClose(SR);
    end;
    L.Sort;
  end;

begin
  Fill(FFiles, ProjectsDir);
  Fill(FExamples, ExamplesDir);
end;

{ ---------- per frame ---------- }

procedure TPlcUI.Update(DT: Double);
var
  M: TCpuModel;
  I, V: Integer;
  T: Double;
begin
  FTime := FTime + DT;
  FAIt := FAIt + DT;
  ProgCommit;
  Rt.FreeRetired;
  if (Hub <> nil) and (Frac(FTime) < DT * 1.01) then Hub.Cleanup;
  M := Rt.Model;
  // analog generators
  for I := 0 to Min(M.AI, 16) - 1 do
  begin
    case Project.AIch[I].AiMode of
      amSine: V := Round(13824 + 13824 * Sin(2 * Pi * FAIt / 8 + I * 0.9));
      amRamp:
        begin
          T := Frac(FAIt / 10 + I * 0.13);
          V := Round(27648 * T);
        end;
    else
      V := Project.AIch[I].AiValue;
    end;
    if M.AIWord + I * 2 + 1 < Length(Rt.SimIn) then Rt.SetSimWord(M.AIWord + I * 2, V);
  end;
  // the signal table
  ApplySignals;
  // the monitor: the runtime records the status of the shown block
  if (Screen = scProgram) and MonitorOk then
    Rt.MonBlock := Rt.Prog.FindBlock(CurBlock.Kind, CurBlock.Number)
  else
    Rt.MonBlock := -1;
  // MRES on the key switch springs back to STOP
  if (FSwitchPos = 2) and (FTime - FMresT > 1.6) then FSwitchPos := 1;
  if Rt.Mode = rmRun then FSwitchPos := Min(FSwitchPos, 0) else if FSwitchPos = 0 then FSwitchPos := 1;
  if Rt.Mode in [rmRun, rmStartup] then FSwitchPos := 0;
end;

{ ---------- helpers ---------- }

function TPlcUI.OperandValue(const S: string; F: TDispFmt; out AText: string): Boolean;
var
  O: TOperand;
  E: string;
  V: LongWord;
begin
  AText := '';
  Result := False;
  if Trim(S) = '' then Exit;
  if not FRes.Resolve(S, O, E, False) then
  begin
    AText := E;
    Exit;
  end;
  if O.Kind <> okAddr then Exit;
  if StrLive(O, AText) then Exit(True);
  if not Rt.PeekRaw(O, V) then Exit;
  AText := FormatRaw(V, O.A.Size, F);
  Result := True;
end;

{ a String / WString operand: its text in quotes }
function TPlcUI.StrLive(const O: TOperand; out AText: string): Boolean;
var
  S: string;
  Q: QWord;
begin
  AText := '';
  Result := (O.Kind = okAddr) and (O.DType in [dtString, dtWString]) and Rt.PeekString(O, O.DType = dtWString, S);
  if Result then AText := '''' + S + ''''
  else if (O.Kind = okAddr) and (DataTypeSize(O.DType) = 8) and Rt.Peek8(O, Q) then
  begin
    // the 64 bit types: LInt, LReal, LTime, LDT, DT ...
    AText := Format64(O.DType, Q);
    Result := True;
  end;
end;

function TPlcUI.LiveText(const O: TOperand; const Fallback: string): string;
var
  V: LongWord;
begin
  Result := Fallback;
  if O.Kind <> okAddr then Exit;
  if StrLive(O, Result) then Exit;
  Result := Fallback;
  if not Rt.PeekRaw(O, V) then Exit;
  // the types with a format of their own: a date, a time of day, the unsigned integers
  case O.DType of
    dtDate: Exit('D#' + FormatDateTime('yyyy-mm-dd', EncodeDate(1990, 1, 1) + (V and $FFFF)));
    dtTOD:
      begin
        V := V mod 86400000;
        Result := Format('TOD#%.2d:%.2d:%.2d', [V div 3600000, V div 60000 mod 60, V div 1000 mod 60]);
        if V mod 1000 <> 0 then Result := Result + Format('.%.3d', [V mod 1000]);
        Exit;
      end;
    dtUSInt, dtUInt, dtUDInt: if DefaultFmt(O) = dfDec then Exit(IntToStr(V));
  end;
  Result := FormatRaw(V, O.A.Size, DefaultFmt(O));
end;

{ the index of element K (from 0 when it has more dimensions) of an array variable: "3" or "1,2" }
function ElemIdx(const V: TDbVar; K: Integer): string;
var
  J, N: Integer;
begin
  if Length(V.Dims) <= 1 then Exit(IntToStr(K));
  Result := '';
  for J := High(V.Dims) downto 0 do
  begin
    N := V.Dims[J].Hi - V.Dims[J].Lo + 1;
    if Result <> '' then Result := ',' + Result;
    Result := IntToStr(V.Dims[J].Lo + K mod N) + Result;
    K := K div N;
  end;
end;

function TPlcUI.CellPower(NI, Cell, Which: Integer): Integer;
var
  CB: TCBlock;
  Slot: Integer;
begin
  Result := -1;
  if not MonitorOk then Exit;
  CB := CompiledBlock;
  if (NI < 0) or (NI > High(CB.Nets)) or (CB.Nets[NI].Kind <> nkLAD) then Exit;
  Slot := CB.Nets[NI].MonBase + Cell * 2 + Which;
  if (Slot < 0) or (Slot > High(CB.Mon)) then Exit;
  if (CB.Mon[Slot].Stamp = 0) or (Rt.CycleNo - CB.Mon[Slot].Stamp > 50) then Exit(0);
  Result := CB.Mon[Slot].Status and 1;
end;

function TPlcUI.DiagColor(K: TDiagKind): TBGRAPixel;
begin
  case K of
    dkError: Result := cRed;
    dkWarn: Result := cGoldDark;
    dkMode: Result := cJade;
  else
    Result := cInkSoft;
  end;
end;

function TPlcUI.LedColorStr(const Name: string): TBGRAPixel;
begin
  if (Name = 'RUN') or (Name = 'DC5V') or (Name = 'LINK') then Result := cJadeLight
  else if (Name = 'STOP') or (Name = 'MAINT') or (Name = 'FRCE') then Result := cAmber
  else Result := BGRA($FF, $4A, $3A);
end;

{ ====================================================================== }
{ build                                                                  }
{ ====================================================================== }

function TPlcUI.Build(StaticDL, DynDL: TDisplayList): Boolean;
var
  Key: string;
  T0: Double;
begin
  T0 := PlcNowMs;
  Key := Format('%d|%dx%d|%d|%d|%d', [Ord(Screen), FW, FH, Project.ModelIdx, Ord(Rt.Model.Family), FIoView]);
  Result := Key <> FStaticKey;
  if Result then
  begin
    FStaticKey := Key;
    StaticDL.Clear;
    D := StaticDL;
    BuildStatic;
  end;
  BeginFrame(DynDL);
  DynDL.Clear;
  // Claude's answers and tool calls (the project may have been replaced by Open)
  FClaude.Project := Project;
  FClaude.Rt := Rt;
  FClaude.Poll;
  BuildHeader;
  case Screen of
    scCpu: BuildCpu;
    scProgram: BuildProgram;
    scIO: BuildIO;
    scWatch: BuildWatch;
    scDB: BuildDB;
    scTags: BuildTags;
    scPorts: BuildPorts;
    scProject: BuildProject;
  end;
  BuildFooter;
  DrawClaudeMenu;
  DrawDevMenu;
  DrawKeyDlg;
  DrawKeyRmDlg;
  DrawCtx;
  DrawAsk;
  EndFrame;
  CmdCount := DynDL.N;
  BuildMs := PlcNowMs - T0;
end;

procedure TPlcUI.BuildStatic;
var
  M: TCpuModel;
  Sub: string;
  I: Integer;
begin
  M := Project.Model;
  D.Layer := lyPaper;
  D.Rect(0, 0, FW, FH, cPaper);
  // cut paper clouds in the backdrop
  CloudMotif(120, 830, 46, Alpha(cSheetDark, 120));
  CloudMotif(1480, 800, 58, Alpha(cSheetDark, 110));
  CloudMotif(820, 875, 40, Alpha(cSheetDark, 90));
  // the header: a red sheet with a gold key fret border
  D.Layer := lySheets;
  Shad(-10, -10, DesignW + 20, 78, 0, 4, 10, 110);
  Rc(-10, -10, DesignW + 20, 78, cRed);
  D.Layer := lyOrnament;
  FretStrip(0, 56, DesignW, 12, cGoldLight, cRedDark);
  for I := 0 to 7 do El(200 * I + 100, 22, 1.6, 1.6, Alpha(cGoldLight, 120));
  D.Layer := lyControls;
  Seal(14, 7, 44, 'S7');
  D.Layer := lyText;
  Txt(fkTitle, 23, 68, 3, 'Virtual PLC', cSheet);
  Sub := FamilyNames[M.Family] + '  ' + M.Name;
  Txt(fkUI, 12, 70, 34, Sub, cGoldLight);
  // the footer
  D.Layer := lySheets;
  Shad(0, 870, DesignW, 40, 0, -2, 6, 60);
  Rc(0, 870, DesignW, 40, cSheet2);
  D.Layer := lyOrnament;
  Ln(0, 870.5, DesignW, 870.5, 1, Alpha(cRed, 160));
  Ln(0, 873, DesignW, 873, 0.6, Alpha(cGoldDark, 140));
  // the cards of the screen
  case Screen of
    scCpu:
      begin
        Card(20, 88, 430, 772, 'CPU front panel');
        Card(466, 88, 560, 396, 'CPU model');
        Card(1042, 88, 538, 396, 'Cycle time');
        Card(466, 504, 1114, 356, 'Diagnostic buffer');
      end;
    scProgram:
      begin
        Card(20, 88, 220, 772, 'Blocks');
        Card(256, 88, 1040, 772, 'Program editor');
        Card(1312, 88, 268, 772, 'Elements');
      end;
    scIO:
      if FIoView = 1 then
      begin
        Card(20, 122, 772, 738, 'Input tags outside the PLC I/O');
        Card(808, 122, 772, 738, 'Output tags outside the PLC I/O');
      end
      else if FIoView = 2 then
        Card(20, 122, 1560, 738, 'Signal simulation table')
      else
      begin
        Card(20, 122, 772, 354, Format('Digital inputs  DI%d', [M.DI]));
        Card(808, 122, 772, 354, Format('Digital outputs  DQ%d', [M.DQ]));
        if M.AQ > 0 then
        begin
          Card(20, 496, 980, 364, Format('Analog inputs  AI%d', [M.AI]));
          Card(1016, 496, 564, 180, Format('Analog outputs  AQ%d', [M.AQ]));
          Card(1016, 696, 564, 164, 'Fault injection');
        end
        else
        begin
          Card(20, 496, 980, 364, Format('Analog inputs  AI%d', [M.AI]));
          Card(1016, 496, 564, 364, 'Fault injection');
        end;
      end;
    scWatch:
      begin
        Card(20, 88, 1180, 772, 'Watch and force table');
        Card(1216, 88, 364, 456, 'Watch groups');
        Card(1216, 560, 364, 300, 'Forces');
      end;
    scDB:
      begin
        Card(20, 88, 300, 772, 'Data blocks');
        Card(336, 88, 1244, 772, 'Variables');
      end;
    scTags:
      begin
        Card(20, 88, 290, 772, 'Tag groups');
        Card(326, 88, 1254, 772, 'PLC tag table');
      end;
    scPorts:
      begin
        Card(20, 88, 500, 300, 'PROFINET interface');
        Card(536, 88, 520, 300, 'S7 communication  ISO-on-TCP');
        Card(1072, 88, 508, 300, 'Modbus TCP server');
        Card(20, 408, 760, 452, 'Connections');
        Card(796, 408, 784, 452, 'Traffic');
      end;
    scProject:
      begin
        Card(20, 88, 640, 388, 'Project');
        Card(20, 496, 640, 364, 'Settings');
        Card(676, 88, 904, 388, 'New project / Device');
        Card(676, 496, 904, 364, 'Project files');
      end;
  end;
end;

procedure TPlcUI.BuildHeader;
var
  S: TScreen;
  X, W, Sw: Single;
  Act0: Boolean;
  ModeS: string;
  ModeC: TBGRAPixel;
  Blink: Boolean;
begin
  X := 322;
  W := 92;
  for S := Low(TScreen) to High(TScreen) do
  begin
    Act0 := S = Screen;
    D.Layer := lySheets;
    if Act0 then
    begin
      Shad(X, 14, W, 46, 6, 3, 6, 110);
      RR(X, 14, W, 46, 6, cSheet);
      D.Layer := lyOrnament;
      RRL(X + 4, 18, W - 8, 38, 4, 0.8, cGold);
      Rc(X + 18, 52, W - 36, 2.2, cRed);
    end
    else
    begin
      if Hot(X, 16, W, 36) then RR(X, 16, W, 36, 6, Mixc(cSheet2, cWhite, 0.25))
      else RR(X, 16, W, 36, 6, Alpha(cSheet2, 225));
    end;
    D.Layer := lyText;
    if Act0 then Txt(fkUIB, 14, X + W / 2, 25, ScreenNames[S], cRedDark, 1)
    else Txt(fkUIB, 13, X + W / 2, 24, ScreenNames[S], cRed, 1);
    Hit(X, 14, W, 44, Act(acTab, Ord(S)));
    X := X + W + 6;
  end;
  // mode pill
  Blink := Frac(FTime * 2) < 0.5;
  case Rt.Mode of
    rmRun: begin ModeS := 'RUN'; ModeC := cJade; end;
    rmStartup: begin ModeS := 'STARTUP'; if Blink then ModeC := cJade else ModeC := cJadeLight; end;
    rmMres: begin ModeS := 'MRES'; if Blink then ModeC := cAmber else ModeC := cGoldDark; end;
  else
    begin ModeS := 'STOP'; ModeC := cAmber; end;
  end;
  X := 1112;
  D.Layer := lyControls;
  Shad(X, 13, 96, 36, 18, 2, 4, 90);
  RR(X, 13, 96, 36, 18, ModeC);
  RRL(X + 3, 16, 90, 30, 15, 1, Alpha(cSheet, 200));
  D.Layer := lyText;
  Txt(fkUIB, 15, X + 48, 21, ModeS, cWhite, 1);
  Txt(fkUI, 10.5, X + 104, 12, 'cycle (model)', cGoldLight);
  if Rt.Mode = rmRun then
    Txt(fkMonoB, 13, X + 104, 27, Format('%.3f ms', [Rt.ModelUs / 1000]), cSheet)
  else
    Txt(fkMonoB, 13, X + 104, 27, '--', cSheet);
  Button(1300, 14, 62, 34, 'RUN', Act(acRun, 0), bsGold, Rt.Mode = rmStop, 12);
  Button(1368, 14, 62, 34, 'STOP', Act(acStop, 0), bsNormal, Rt.Mode <> rmStop, 12);
  if FDirty then
    Button(1436, 14, 150, 34, 'Download  *', Act(acDownload, 0), bsGold, True, 13)
  else
    Button(1436, 14, 150, 34, 'Download', Act(acDownload, 0), bsNormal, True, 13);
  // swaying lanterns
  D.Layer := lyOrnament;
  Sw := Sin(FTime * 1.7) * 3;
  Ln(300, 0, 300 + Sw, 24, 1, cGoldLight);
  El(300 + Sw, 33, 8, 10, cRedLight);
  ElL(300 + Sw, 33, 8, 10, 1, cGoldLight);
  Rc(296 + Sw, 43, 8, 2.5, cGoldLight);
  Ln(300 + Sw, 45, 300 + Sw * 1.3, 53, 1, cGoldLight);
end;

procedure TPlcUI.BuildFooter;
var
  S: string;
  C: TBGRAPixel;
  A: Integer;
begin
  D.Layer := lyText;
  if (FToast <> '') and (FTime - FToastT < 8) then
  begin
    A := Round(255 * EnsureRange((8 - (FTime - FToastT)) / 1.5, 0, 1));
    if FToastErr then C := Alpha(cRed, A) else C := Alpha(cInk, A);
    TxtFit(fkUIB, 12, 16, 878, 980, FToast, C);
  end
  else
  begin
    if Rt.StopCause <> '' then S := 'Last STOP: ' + Rt.StopCause else S := 'Ready';
    TxtFit(fkUI, 12, 16, 878, 980, S, cInkSoft);
  end;
  S := 'F5 RUN  F6 STOP  F7 compile  F8 download  Ctrl+S save  F9 monitor  F12 PNG  F1 info';
  Txt(fkUI, 11, 1586, 879, S, cInkSoft, 2);
end;

{ ====================================================================== }
{ CPU screen                                                             }
{ ====================================================================== }

procedure TPlcUI.DrawCpuModule(X, Y: Single);
const
  Leds300: array[0..7] of string = ('SF', 'BF1', 'BF2', 'MAINT', 'DC5V', 'FRCE', 'RUN', 'STOP');
  Leds400: array[0..7] of string = ('INTF', 'EXTF', 'BUS1F', 'BUS5F', 'MAINT', 'FRCE', 'RUN', 'STOP');
var
  M: TCpuModel;
  I: Integer;
  Nm: string;
  On, Blink2, Blink05: Boolean;
  LY, SX, SY, A: Single;
  Pos: array[0..2] of string;
  NowMs: Double;
begin
  M := Rt.Model;
  NowMs := PlcNowMs;
  Blink2 := Frac(FTime * 2) < 0.5;
  Blink05 := Frac(FTime * 0.5) < 0.5;
  // the module: a charcoal paper plate with a lighter front cover
  D.Layer := lySheets;
  Sheet(X, Y, 330, 560, 8, cCharcoal, 1.2);
  RR(X + 8, Y + 8, 314, 544, 6, cCharcoal2);
  RR(X + 14, Y + 14, 302, 64, 4, cCharcoal);
  D.Layer := lyText;
  Txt(fkUIB, 15, X + 26, Y + 20, 'VIRTUAL ' + FamilyNames[M.Family], cGoldLight);
  Txt(fkUI, 12, X + 26, Y + 44, M.Name + '   ' + M.Firmware, cSheet);
  D.Layer := lyOrnament;
  Ln(X + 26, Y + 66, X + 300, Y + 66, 1, Alpha(cGold, 160));
  // LEDs
  for I := 0 to 7 do
  begin
    if M.Family = cfS7400 then Nm := Leds400[I] else Nm := Leds300[I];
    LY := Y + 104 + I * 34;
    On := False;
    if (Nm = 'SF') or (Nm = 'INTF') then On := Rt.SysFault or Rt.BusFault;
    if Nm = 'EXTF' then On := Rt.BusFault;
    if (Nm = 'BF2') or (Nm = 'BUS5F') then On := Rt.BusFault and Blink2;
    if Nm = 'DC5V' then On := True;
    if Nm = 'FRCE' then On := Rt.ForceCount > 0;
    if Nm = 'RUN' then On := (Rt.Mode = rmRun) or ((Rt.Mode = rmStartup) and Blink2);
    if Nm = 'STOP' then
      On := ((Rt.Mode = rmStop) and not (FSwitchPos = 2)) or ((Rt.Mode = rmMres) and Blink2) or
        ((Rt.Mode = rmStartup) and not Blink2) or ((FSwitchPos = 2) and (Rt.Mode = rmStop) and Blink05);
    Led(X + 40, LY, 6, LedColorStr(Nm), On);
    D.Layer := lyText;
    Txt(fkUIB, 11, X + 56, LY - 8, Nm, cSheet);
  end;
  // the mode selector: a three position key switch
  SX := X + 220;
  SY := Y + 170;
  Pos[0] := 'RUN';
  Pos[1] := 'STOP';
  Pos[2] := 'MRES';
  D.Layer := lyControls;
  El(SX, SY, 38, 38, cCharcoal);
  ElL(SX, SY, 38, 38, 2, cGoldDark);
  El(SX, SY, 28, 28, cSheet2);
  // the key points at the position's label
  A := ArcTan2(-44 + FSwitchPos * 30, 44);
  Ln(SX - Cos(A) * 14, SY - Sin(A) * 14, SX + Cos(A) * 22, SY + Sin(A) * 22, 8, cRedDark);
  El(SX + Cos(A) * 20, SY + Sin(A) * 20, 4, 4, cGoldLight);
  El(SX, SY, 5, 5, cGold);
  for I := 0 to 2 do
  begin
    A := (-60 + I * 45) * Pi / 180;
    D.Layer := lyText;
    if I = FSwitchPos then
      Txt(fkUIB, 12, SX + 50, SY - 52 + I * 30, Pos[I], cGoldLight)
    else
      Txt(fkUIB, 12, SX + 50, SY - 52 + I * 30, Pos[I], cSheetDark);
    D.Layer := lyControls;
    El(SX + 44, SY - 44 + I * 30, 2.4, 2.4, cGold);
    Hit(SX + 40, SY - 56 + I * 30, 60, 26, Act(acSwitch, I));
  end;
  Hit(SX - 38, SY - 38, 76, 76, Act(acSwitch, 3));
  // memory card slot and ports
  D.Layer := lyControls;
  RR(X + 170, Y + 260, 140, 34, 3, cCharcoal);
  RR(X + 176, Y + 268, 128, 18, 2, Mixc(cGoldDark, cCharcoal, 0.4));
  D.Layer := lyText;
  Txt(fkUI, 10, X + 240, Y + 298, 'Micro Memory Card', cSheetDark, 1);
  D.Layer := lyControls;
  for I := 0 to 1 do
  begin
    RR(X + 180 + I * 66, Y + 340, 54, 40, 3, cCharcoal);
    RR(X + 188 + I * 66, Y + 350, 38, 22, 2, BGRA(30, 26, 24));
    // port 1 carries the simulated network: link = a server listens, amber = traffic
    DrawPortLeds(X + 192 + I * 66, Y + 390, (I = 0) and (Hub <> nil) and (Hub.Listening[prS7] or Hub.Listening[prModbus]));
  end;
  D.Layer := lyText;
  Txt(fkUI, 10, X + 207, Y + 398, 'X2 P1', cSheetDark, 1);
  Txt(fkUI, 10, X + 273, Y + 398, 'X2 P2', cSheetDark, 1);
  D.Layer := lyControls;
  RR(X + 180, Y + 430, 120, 44, 3, cCharcoal);
  for I := 0 to 8 do El(X + 196 + (I mod 5) * 22 + (I div 5) * 11, Y + 444 + (I div 5) * 14, 2.6, 2.6, cSheetDark);
  D.Layer := lyText;
  Txt(fkUI, 10, X + 240, Y + 478, 'X1 MPI/DP', cSheetDark, 1);
  Txt(fkMono, 10, X + 26, Y + 520, M.OrderNo, cSheetDark);
end;

{ the S7-1500: status LEDs on top, the display with its keys, the RUN / STOP
  switch behind the front flap, memory card and PROFINET ports }
procedure TPlcUI.Draw1500Module(X, Y: Single);
var
  M: TCpuModel;
  Blink2, Link: Boolean;
  RunC, Scr, ScrInk: TBGRAPixel;
  I: Integer;
  SX, SY, KY: Single;
  ModeS, S: string;
  Ports: array[0..2] of string;
begin
  M := Rt.Model;
  Blink2 := Frac(FTime * 2) < 0.5;
  D.Layer := lySheets;
  Sheet(X, Y, 330, 560, 8, cCharcoal, 1.2);
  RR(X + 8, Y + 8, 314, 544, 6, cCharcoal2);
  // status LEDs: RUN/STOP, ERROR, MAINT
  case Rt.Mode of
    rmRun: RunC := cJadeLight;
    rmStartup: if Blink2 then RunC := cJadeLight else RunC := cAmber;
  else
    RunC := cAmber;
  end;
  Led(X + 44, Y + 26, 5, RunC, (Rt.Mode <> rmMres) or Blink2);
  Led(X + 144, Y + 26, 5, BGRA($FF, $4A, $3A), (Rt.SysFault or (Rt.ErrorUntilMs > PlcNowMs) or Rt.BusFault) and Blink2);
  Led(X + 236, Y + 26, 5, cAmber, Rt.ForceCount > 0);
  D.Layer := lyText;
  Txt(fkUIB, 10, X + 54, Y + 18, 'RUN/STOP', cSheet);
  Txt(fkUIB, 10, X + 154, Y + 18, 'ERROR', cSheet);
  Txt(fkUIB, 10, X + 246, Y + 18, 'MAINT', cSheet);
  // the display
  SX := X + 34;
  SY := Y + 48;
  Scr := BGRA(30, 40, 56);
  ScrInk := BGRA(206, 224, 240);
  D.Layer := lyControls;
  RR(SX, SY, 262, 214, 8, BGRA(20, 20, 24));
  RR(SX + 10, SY + 10, 242, 150, 4, Scr);
  for I := 0 to 4 do
  begin
    if I = 0 then RR(SX + 16 + I * 47, SY + 16, 40, 16, 3, Alpha(cGold, 220))
    else RR(SX + 16 + I * 47, SY + 16, 40, 16, 3, Alpha(ScrInk, 60));
  end;
  D.Layer := lyText;
  Txt(fkUIB, 8.5, SX + 36, SY + 18, 'Home', cInk, 1);
  Txt(fkUI, 8.5, SX + 83, SY + 18, 'Diag', ScrInk, 1);
  Txt(fkUI, 8.5, SX + 130, SY + 18, 'Setup', ScrInk, 1);
  Txt(fkUI, 8.5, SX + 177, SY + 18, 'Module', ScrInk, 1);
  Txt(fkUI, 8.5, SX + 224, SY + 18, 'Screen', ScrInk, 1);
  TxtFit(fkUIB, 11.5, SX + 18, SY + 38, 226, M.Name, ScrInk);
  case Rt.Mode of
    rmRun: begin ModeS := 'RUN'; RunC := cJadeLight; end;
    rmStartup: begin ModeS := 'STARTUP'; RunC := cJadeLight; end;
    rmMres: begin ModeS := 'MEMORY RESET'; RunC := cAmber; end;
  else
    begin ModeS := 'STOP'; RunC := cAmber; end;
  end;
  Txt(fkUIB, 20, SX + 18, SY + 56, ModeS, RunC);
  if Rt.Mode = rmRun then S := Format('Cycle  %.3f ms', [Rt.ModelUs / 1000])
  else if Rt.StopCause <> '' then S := Rt.StopCause
  else S := 'Cycle  --';
  TxtFit(fkUI, 10.5, SX + 18, SY + 88, 226, S, ScrInk);
  TxtFit(fkUI, 10.5, SX + 18, SY + 104, 226, Format('Diagnostics  %d entries   Forces  %d', [Rt.DiagCount,
    Rt.ForceCount]), ScrInk);
  Link := (Hub <> nil) and (Hub.Listening[prS7] or Hub.Listening[prModbus]);
  if Link then
    S := Format('X1  S7 %d  Modbus %d  (%d conn.)', [Project.Comm.S7Port, Project.Comm.MbPort, Hub.ActiveCount])
  else
    S := 'X1  no communication server';
  TxtFit(fkUI, 10.5, SX + 18, SY + 120, 226, S, ScrInk);
  TxtFit(fkMono, 9.5, SX + 18, SY + 138, 226, M.OrderNo + '  ' + M.Firmware, Alpha(ScrInk, 170));
  // display keys
  D.Layer := lyControls;
  KY := SY + 172;
  RR(SX + 14, KY, 40, 26, 4, cCharcoal2);
  RR(SX + 208, KY, 40, 26, 4, cCharcoal2);
  for I := 0 to 3 do RR(SX + 68 + I * 33, KY, 28, 26, 4, cCharcoal2);
  D.Layer := lyText;
  Txt(fkUIB, 9, SX + 34, KY + 6, 'ESC', cSheet, 1);
  Txt(fkUIB, 9, SX + 228, KY + 6, 'OK', cSheet, 1);
  Txt(fkUIB, 11, SX + 82, KY + 4, '←', cSheet, 1);
  Txt(fkUIB, 11, SX + 115, KY + 4, '↑', cSheet, 1);
  Txt(fkUIB, 11, SX + 148, KY + 4, '↓', cSheet, 1);
  Txt(fkUIB, 11, SX + 181, KY + 4, '→', cSheet, 1);
  // front flap
  Txt(fkUIB, 15, X + 165, Y + 276, 'VIRTUAL S7-1500', cGoldLight, 1);
  D.Layer := lyOrnament;
  Ln(X + 40, Y + 300, X + 290, Y + 300, 1, Alpha(cGold, 160));
  // the mode switch: RUN / STOP (memory reset from the display / the operator panel)
  D.Layer := lyControls;
  RR(X + 44, Y + 318, 26, 70, 13, BGRA(30, 26, 24));
  if FSwitchPos = 0 then KY := Y + 332 else KY := Y + 374;
  El(X + 57, KY + 1.5, 10, 10, Alpha(cShadow, 120));
  El(X + 57, KY, 10, 10, cSheet2);
  ElL(X + 57, KY, 10, 10, 1, cGoldDark);
  D.Layer := lyText;
  if FSwitchPos = 0 then
  begin
    Txt(fkUIB, 12, X + 80, Y + 324, 'RUN', cGoldLight);
    Txt(fkUIB, 12, X + 80, Y + 366, 'STOP', cSheetDark);
  end
  else
  begin
    Txt(fkUIB, 12, X + 80, Y + 324, 'RUN', cSheetDark);
    Txt(fkUIB, 12, X + 80, Y + 366, 'STOP', cGoldLight);
  end;
  Hit(X + 40, Y + 314, 90, 38, Act(acSwitch, 0));
  Hit(X + 40, Y + 354, 90, 38, Act(acSwitch, 1));
  // memory card
  D.Layer := lyControls;
  RR(X + 150, Y + 326, 150, 30, 3, cCharcoal);
  RR(X + 156, Y + 333, 138, 16, 2, Mixc(cGoldDark, cCharcoal, 0.4));
  D.Layer := lyText;
  Txt(fkUI, 10, X + 225, Y + 360, 'memory card', cSheetDark, 1);
  // PROFINET ports
  Ports[0] := 'X1 P1R';
  Ports[1] := 'X1 P2R';
  Ports[2] := 'X2 P1';
  for I := 0 to 2 do
  begin
    D.Layer := lyControls;
    RR(X + 40 + I * 88, Y + 410, 70, 46, 3, cCharcoal);
    RR(X + 50 + I * 88, Y + 420, 50, 26, 2, BGRA(30, 26, 24));
    DrawPortLeds(X + 52 + I * 88, Y + 468, (I = 0) and Link);
    D.Layer := lyText;
    Txt(fkUI, 10, X + 75 + I * 88, Y + 478, Ports[I], cSheetDark, 1);
  end;
  Txt(fkMono, 10, X + 26, Y + 520, M.OrderNo, cSheetDark);
end;

procedure TPlcUI.Draw1200Module(X, Y: Single);
var
  M: TCpuModel;
  I, B, Bit, N: Integer;
  On, Blink2: Boolean;
  CX: Single;
  RunC: TBGRAPixel;
begin
  M := Rt.Model;
  Blink2 := Frac(FTime * 2) < 0.5;
  D.Layer := lySheets;
  Sheet(X, Y, 360, 330, 8, cCharcoal, 1.2);
  RR(X + 8, Y + 8, 344, 314, 6, cCharcoal2);
  // I/O terminal covers
  RR(X + 14, Y + 14, 332, 56, 4, cCharcoal);
  RR(X + 14, Y + 260, 332, 56, 4, cCharcoal);
  D.Layer := lyText;
  Txt(fkUIB, 15, X + 110, Y + 92, 'VIRTUAL S7-1200', cGoldLight);
  Txt(fkUI, 12, X + 110, Y + 114, M.Name, cSheet);
  Txt(fkMono, 10, X + 110, Y + 134, M.OrderNo + '  ' + M.Firmware, cSheetDark);
  // status LEDs
  if Rt.Mode = rmRun then RunC := cJadeLight
  else if Rt.Mode = rmStartup then
  begin
    if Blink2 then RunC := cJadeLight else RunC := cAmber;
  end
  else RunC := cAmber;
  Led(X + 36, Y + 100, 6, RunC, True);
  Led(X + 36, Y + 128, 6, BGRA($FF, $4A, $3A), Rt.SysFault or ((Rt.ErrorUntilMs > PlcNowMs) or Rt.BusFault) and Blink2);
  Led(X + 36, Y + 156, 6, cAmber, (Rt.ForceCount > 0) or ((Rt.Mode = rmMres) and Blink2));
  D.Layer := lyText;
  Txt(fkUIB, 10, X + 50, Y + 92, 'RUN/STOP', cSheet);
  Txt(fkUIB, 10, X + 50, Y + 120, 'ERROR', cSheet);
  Txt(fkUIB, 10, X + 50, Y + 148, 'MAINT', cSheet);
  // on-board I/O LEDs
  N := M.DI;
  for I := 0 to N - 1 do
  begin
    B := M.DIByte + I div 8;
    Bit := I mod 8;
    CX := X + 30 + I * 21;
    On := (B < Length(Rt.I)) and ((Rt.I[B] shr Bit) and 1 <> 0);
    Led(CX, Y + 36, 3.6, cJadeLight, On);
    D.Layer := lyText;
    Txt(fkMono, 8.5, CX, Y + 48, Format('%d.%d', [B, Bit]), cSheetDark, 1);
  end;
  N := M.DQ;
  for I := 0 to N - 1 do
  begin
    B := M.DQByte + I div 8;
    Bit := I mod 8;
    CX := X + 30 + I * 21;
    On := Rt.GetOutBit(B, Bit);
    Led(CX, Y + 282, 3.6, cJadeLight, On);
    D.Layer := lyText;
    Txt(fkMono, 8.5, CX, Y + 294, Format('%d.%d', [B, Bit]), cSheetDark, 1);
  end;
  D.Layer := lyText;
  Txt(fkUI, 9, X + 340, Y + 16, Format('DI %d x 24 V DC', [M.DI]), cSheetDark, 2);
  Txt(fkUI, 9, X + 340, Y + 262, Format('DQ %d x 24 V DC', [M.DQ]), cSheetDark, 2);
  // PROFINET port
  D.Layer := lyControls;
  RR(X + 260, Y + 170, 70, 52, 3, cCharcoal);
  RR(X + 268, Y + 180, 54, 30, 2, BGRA(30, 26, 24));
  Led(X + 272, Y + 228, 3, cJadeLight, (Hub <> nil) and (Hub.Listening[prS7] or Hub.Listening[prModbus]));
  Led(X + 318, Y + 228, 3, cAmber, PortActive);
  D.Layer := lyText;
  Txt(fkUI, 9, X + 295, Y + 234, 'X1 P1 LINK  Rx/Tx', cSheetDark, 1);
  Txt(fkUI, 9, X + 36, Y + 200, Format('AI %d  0..10 V', [M.AI]), cSheetDark);
  if M.AQ > 0 then Txt(fkUI, 9, X + 36, Y + 214, Format('AQ %d  0..20 mA', [M.AQ]), cSheetDark);
end;

procedure TPlcUI.BuildCpu;
var
  M, SM: TCpuModel;
  F: TCpuFamily;
  I, J, N, Row: Integer;
  Y, X, V, Mx, BarW, Tw: Single;
  Diag: TDiagArray;
  P: array of TPointF;
  ModeS: string;
  Used: Integer;
  Fr: Single;
begin
  M := Rt.Model;
  // ---------- front panel ----------
  if M.Family = cfS71200 then Draw1200Module(55, 130)
  else if M.Family = cfS71500 then Draw1500Module(70, 120)
  else DrawCpuModule(70, 120);
  Y := 700;
  if M.Family = cfS71200 then Y := 490;
  D.Layer := lyText;
  Txt(fkUIB, 13, 50, Y, 'Operator panel', cRedDark);
  D.Layer := lyOrnament;
  Ln(50, Y + 22, 420, Y + 22, 0.8, Alpha(cGoldDark, 160));
  Button(50, Y + 32, 112, 34, 'RUN', Act(acRun, 0), bsGold, Rt.Mode = rmStop);
  Button(172, Y + 32, 112, 34, 'STOP', Act(acStop, 0), bsNormal, Rt.Mode <> rmStop);
  Button(294, Y + 32, 112, 34, 'MRES', Act(acMres, 0), bsDanger, Rt.Mode <> rmMres);
  if M.Family = cfS71200 then
  begin
    D.Layer := lyText;
    case Rt.Mode of
      rmRun: ModeS := 'RUN';
      rmStartup: ModeS := 'STARTUP';
      rmMres: ModeS := 'memory reset';
    else
      ModeS := 'STOP';
    end;
    Txt(fkUI, 13, 50, Y + 84, 'Operating mode: ' + ModeS, cInk);
    if Rt.StopCause <> '' then TxtFit(fkUI, 12, 50, Y + 106, 370, 'Cause: ' + Rt.StopCause, cInkSoft);
    Txt(fkUI, 12, 50, Y + 128, Format('Forces: %d bits   Bus: %s', [Rt.ForceCount,
      IfThen(Rt.BusFault, 'station failure', 'ok')]), cInkSoft);
    Txt(fkUI, 11, 50, Y + 156, 'The S7-1200 has no mode selector: RUN / STOP', cInkFaint);
    Txt(fkUI, 11, 50, Y + 172, 'come from the online operator panel, like TIA Portal.', cInkFaint);
    Txt(fkUI, 11, 50, Y + 196, 'Programming errors: the CPU stays in RUN, ERROR', cInkFaint);
    Txt(fkUI, 11, 50, Y + 212, 'flashes, the diagnostic buffer gets an entry.', cInkFaint);
    Txt(fkUI, 11, 50, Y + 236, 'Retentive memory: only DB variables marked Retain.', cInkFaint);
  end
  else if M.Family = cfS71500 then
  begin
    D.Layer := lyText;
    TxtFit(fkUI, 11, 50, Y + 76, 370, 'RUN / STOP switch on the module (click); MRES from the display.', cInkFaint);
    if Rt.StopCause <> '' then TxtFit(fkUI, 12, 50, Y + 96, 370, 'Last STOP: ' + Rt.StopCause, cInkSoft);
    Txt(fkUI, 11, 50, Y + 118, 'No OB121: STOP on a programming error; station', cInkFaint);
    Txt(fkUI, 11, 50, Y + 134, 'failure keeps RUN. Retentive: Retain variables.', cInkFaint);
  end
  else
  begin
    D.Layer := lyText;
    TxtFit(fkUI, 11, 50, Y + 76, 370, 'Mode selector RUN / STOP / MRES on the module (click).', cInkFaint);
    if Rt.StopCause <> '' then TxtFit(fkUI, 12, 50, Y + 96, 370, 'Last STOP: ' + Rt.StopCause, cInkSoft);
    Txt(fkUI, 11, 50, Y + 118, 'Retentive: MB0..MB15, C0..C7, all DBs.', cInkFaint);
  end;

  // ---------- CPU model ----------
  for F := Low(TCpuFamily) to High(TCpuFamily) do
    if F = FFamView then Button(490 + Ord(F) * 120, 112, 112, 30, FamilyNames[F], Act(acFamView, Ord(F)), bsPrimary)
    else Button(490 + Ord(F) * 120, 112, 112, 30, FamilyNames[F], Act(acFamView, Ord(F)));
  Row := 0;
  for I := 0 to ModelCount - 1 do
  begin
    if Models[I].Family <> FFamView then Continue;
    Y := 156 + Row * 40;
    D.Layer := lyControls;
    if I = FModelSel then
    begin
      RR(490, Y, 250, 34, 5, Alpha(cGold, 110));
      RRL(490, Y, 250, 34, 5, 1, cGoldDark);
    end
    else if Hot(490, Y, 250, 34) then RR(490, Y, 250, 34, 5, Alpha(cGoldLight, 70));
    D.Layer := lyText;
    Txt(fkUIB, 13, 500, Y + 2, Models[I].Name, cInk);
    Txt(fkUI, 10, 500, Y + 19, Models[I].OrderNo, cInkSoft);
    if I = Project.ModelIdx then
    begin
      D.Layer := lyControls;
      RR(690, Y + 8, 44, 18, 9, cRed);
      D.Layer := lyText;
      Txt(fkUIB, 10, 712, Y + 9, 'in use', cSheet, 1);
    end;
    Hit(490, Y, 250, 34, Act(acModelSel, I));
    Inc(Row);
  end;
  SM := Models[FModelSel];
  X := 760;
  D.Layer := lyText;
  Txt(fkUIB, 14, X, 156, SM.Name, cRedDark);
  Y := 182;
  for J := 0 to 11 do
  begin
    case J of
      0: begin ModeS := 'Order no.'; Txt(fkMono, 11, X + 120, Y, SM.OrderNo + ' ' + SM.Firmware, cInk); end;
      1: begin ModeS := 'Work memory'; Txt(fkMono, 11, X + 120, Y, Format('%d KB', [SM.WorkMem div 1024]), cInk); end;
      2: begin ModeS := 'Load memory'; Txt(fkMono, 11, X + 120, Y, Format('%d MB', [SM.LoadMem div (1024 * 1024)]), cInk); end;
      3: begin ModeS := 'I / Q bytes'; Txt(fkMono, 11, X + 120, Y, Format('%d / %d', [SM.InBytes, SM.OutBytes]), cInk); end;
      4: begin ModeS := 'Bit memory M'; Txt(fkMono, 11, X + 120, Y, Format('%d bytes', [SM.MBytes]), cInk); end;
      5:
        begin
          ModeS := 'Timers / counters';
          if SM.Timers > 0 then Txt(fkMono, 11, X + 120, Y, Format('%d S5 / %d S5', [SM.Timers, SM.Counters]), cInk)
          else Txt(fkMono, 11, X + 120, Y, 'IEC (TON, CTU) in DBs', cInk);
        end;
      6: begin ModeS := 'Data blocks'; Txt(fkMono, 11, X + 120, Y, Format('DB1..DB%d, %d KB', [SM.MaxDB, SM.MaxDBSize div 1024]), cInk); end;
      7: begin ModeS := 'Accumulators'; Txt(fkMono, 11, X + 120, Y, IntToStr(SM.Accus), cInk); end;
      8: begin ModeS := 'Bit / word op'; Txt(fkMono, 11, X + 120, Y, Format('%s / %s us', [FloatToStrDot(SM.BitNs / 1000), FloatToStrDot(SM.WordNs / 1000)]), cInk); end;
      9: begin ModeS := 'Fixed / float'; Txt(fkMono, 11, X + 120, Y, Format('%s / %s us', [FloatToStrDot(SM.FixNs / 1000), FloatToStrDot(SM.FloatNs / 1000)]), cInk); end;
      10:
        begin
          ModeS := 'Languages';
          if SM.Family = cfS71200 then Txt(fkMono, 11, X + 120, Y, 'LAD (no STL)', cInk)
          else if SM.Family = cfS71500 then Txt(fkMono, 11, X + 120, Y, 'LAD, STL (4 ACCUs)', cInk)
          else Txt(fkMono, 11, X + 120, Y, 'LAD, STL', cInk);
        end;
      11: begin ModeS := 'Cyclic OB / I/O'; Txt(fkMono, 11, X + 120, Y, Format('OB%d / DI%d DQ%d AI%d AQ%d', [SM.CyclicOB, SM.DI, SM.DQ, SM.AI, SM.AQ]), cInk); end;
    end;
    Txt(fkUI, 11, X, Y, ModeS, cInkSoft);
    Y := Y + 19;
  end;
  if FModelSel <> Project.ModelIdx then
    Button(X, 420, 240, 32, 'Use this CPU in the project', Act(acModelApply, FModelSel), bsPrimary);
  // memory use
  if Rt.Prog <> nil then Used := Rt.Prog.CodeBytes + Rt.Prog.DataBytes else Used := 0;
  D.Layer := lyText;
  Txt(fkUI, 11, 490, 412, Format('Work memory used: %d of %d bytes (%.1f %%)', [Used, M.WorkMem,
    Used * 100 / Max(1, M.WorkMem)]), cInkSoft);
  ProgressBar(490, 432, 250, 10, Used / Max(1, M.WorkMem), cRed);
  Txt(fkUI, 11, 490, 448, Format('Process image: I %d  Q %d bytes', [M.InBytes, M.OutBytes]), cInkSoft);

  // ---------- cycle time ----------
  X := 1066;
  D.Layer := lyText;
  Txt(fkUI, 12, X, 112, 'CPU cycle (model of the ' + M.Name + ')', cInkSoft);
  if Rt.Mode = rmRun then
    Txt(fkTitle, 34, X, 128, Format('%.3f ms', [Rt.ModelUs / 1000]), cRedDark)
  else
    Txt(fkTitle, 34, X, 128, '--', cRedDark);
  Txt(fkMono, 11, X, 178, Format('min %.3f   max %.3f   avg %.3f ms', [IfThen(Rt.ModelMinUs > 1E8, 0, Rt.ModelMinUs) / 1000,
    Rt.ModelMaxUs / 1000, Rt.ModelAvgUs / 1000]), cInk);
  Txt(fkMono, 11, X, 196, Format('host execution %.1f us  (max %.1f)', [Rt.HostUs, Rt.HostMaxUs]), cInk);
  Txt(fkMono, 11, X, 214, Format('scan period %.2f ms   %.0f cycles/s', [Rt.PeriodMs, Rt.CyclesPerSec]), cInk);
  Txt(fkMono, 11, X, 232, Format('OB%d every %d ms: %d runs, %d late', [M.CyclicOB, Project.CyclicMs,
    Rt.CycCount, Rt.CycLate]), cInk);
  Txt(fkMono, 11, X, 250, Format('instructions / cycle %d   watchdog %d ms', [Rt.OpsLastCycle, M.WatchdogMs]), cInk);
  // history chart
  Y := 278;
  D.Layer := lyControls;
  RR(X, Y, 490, 120, 4, Alpha(cSheet2, 200));
  RRL(X, Y, 490, 120, 4, 0.7, Alpha(cGoldDark, 160));
  Mx := 1;
  for I := 0 to HistCycles - 1 do Mx := Max(Mx, Max(Rt.ModelHist[I], Rt.HostHist[I]));
  Mx := Mx * 1.15;
  SetLength(P, HistCycles);
  for J := 0 to 1 do
  begin
    for I := 0 to HistCycles - 1 do
    begin
      if J = 0 then V := Rt.ModelHist[(Rt.HistPos + I) mod HistCycles]
      else V := Rt.HostHist[(Rt.HistPos + I) mod HistCycles];
      P[I] := PointF(X + 6 + I * 478 / (HistCycles - 1), Y + 114 - V / Mx * 104);
    end;
    if J = 0 then PolyLineD(P, 1.4, cRed) else PolyLineD(P, 1.1, cGoldDark);
  end;
  D.Layer := lyText;
  Txt(fkUI, 10, X + 8, Y + 4, Format('%.0f us', [Mx]), cInkSoft);
  Txt(fkUIB, 10, X + 482, Y + 4, 'model', cRed, 2);
  Txt(fkUIB, 10, X + 482, Y + 18, 'host', cGoldDark, 2);
  Txt(fkUI, 11, X, 410, 'Pacing', cInkSoft);
  Button(X + 52, 404, 110, 28, 'free run', Act(acPacing, 0), bsNormal);
  Button(X + 168, 404, 110, 28, 'min 1 ms', Act(acPacing, 1), bsNormal);
  Button(X + 284, 404, 130, 28, 'model cycle', Act(acPacing, 2), bsNormal);
  // highlight the active pacing
  D.Layer := lyOrnament;
  case Rt.Pacing of
    pcFree: RRL(X + 50, 402, 114, 32, 6, 2, cGold);
    pcMin1ms: RRL(X + 166, 402, 114, 32, 6, 2, cGold);
    pcModel: RRL(X + 282, 402, 134, 32, 6, 2, cGold);
  end;
  D.Layer := lyText;
  Txt(fkUI, 10, X, 444, 'free run: as fast as the PC can; min 1 ms: one cycle per ms;', cInkFaint);
  Txt(fkUI, 10, X, 458, 'model cycle: as long as the real CPU would need.', cInkFaint);

  // ---------- diagnostic buffer ----------
  Button(1460, 520, 100, 26, 'Clear', Act(acDiagClear, 0));
  Diag := Rt.DiagCopy(100);
  D.Layer := lyText;
  Txt(fkUIB, 11, 494, 526, 'No.', cInkSoft);
  Txt(fkUIB, 11, 540, 526, 'Time', cInkSoft);
  Txt(fkUIB, 11, 650, 526, 'Event', cInkSoft);
  N := Length(Diag);
  FDiagScroll := EnsureRange(FDiagScroll, 0, Max(0, N - 13));
  ClipD(480, 546, 1090, 300);
  for I := 0 to 13 do
  begin
    J := I + Round(FDiagScroll);
    if J >= N then Break;
    Y := 550 + I * 21.5;
    D.Layer := lyControls;
    if Odd(I) then Rc(484, Y - 2, 1082, 21.5, Alpha(cSheet2, 140));
    El(530, Y + 8, 3.5, 3.5, DiagColor(Diag[J].Kind));
    D.Layer := lyText;
    Txt(fkMono, 11, 494, Y, IntToStr(J + 1), cInkSoft);
    Txt(fkMono, 11, 540, Y, FormatDateTime('hh:nn:ss.zzz', Diag[J].Time), cInk);
    TxtFit(fkUI, 12, 650, Y - 1, 910, Diag[J].Text, DiagColor(Diag[J].Kind));
  end;
  UnclipD;
  Hit(480, 546, 1090, 300, whDiag, hkWheel);
  if Tw = 0 then ;
  if BarW = 0 then ;
  if Fr = 0 then ;
end;

{ ====================================================================== }
{ Program screen                                                         }
{ ====================================================================== }

function BoxPins(K: TLadKind): Integer;
begin
  case K of
    lkCall: Result := 0;
  else
    Result := LadParamCount(K);
  end;
end;

function TPlcUI.CallBlockOf(const Opnd: string): TBlock;
var
  T, U: string;
  I, Nr: Integer;
  Dbk: TDataBlock;
begin
  Result := nil;
  T := Trim(Opnd);
  if T = '' then Exit;
  // FB1, DB10 / "Inst_DB" / DB10: the FB of the instance
  I := Pos(',', T);
  if I > 0 then Exit(Project.FindFB(Trim(Copy(T, 1, I - 1))));
  U := StringReplace(T, '"', '', [rfReplaceAll]);
  Dbk := Project.FindDBByName(U);
  if (Dbk = nil) and SameText(Copy(U, 1, 2), 'DB') and TryStrToInt(Copy(U, 3, MaxInt), Nr) then Dbk := Project.FindDB(Nr);
  if Dbk <> nil then Exit(Project.InstanceFB(Dbk));
  if SameText(Copy(U, 1, 2), 'FC') and TryStrToInt(Copy(U, 3, MaxInt), Nr) then Exit(Project.FindBlock(bkFC, Nr));
  for I := 0 to Project.BlockCount - 1 do
    if (Project.Block(I).Kind = bkFC) and SameText(Project.Block(I).Name, U) then Exit(Project.Block(I));
end;

function TPlcUI.PinsOf(const Ce: TLadCell): Integer;
begin
  if Ce.Kind = lkCall then Result := Length(CallPins(CallBlockOf(Ce.Opnd)))
  else Result := BoxPins(Ce.Kind);
end;

function TPlcUI.RowHeight(N: TNetwork; R: Integer): Single;
var
  C, P: Integer;
begin
  Result := 66;
  for C := 0 to N.Cols - 1 do
    if IsBox(N.Cell(R, C).Kind) then
    begin
      P := PinsOf(N.Cell(R, C));
      Result := Max(Result, 30 + 22 + P * 15 + 6 + 10);
    end
    else if N.Cell(R, C).Kind in [lkPos, lkNeg] then
      Result := Max(Result, 74);
end;

function TPlcUI.BoxSpan(N: TNetwork; R, C: Integer): Integer;
begin
  Result := 1;
  if not IsBox(N.Cell(R, C).Kind) then Exit;
  if (C + 1 < N.Cols) and (N.Cell(R, C + 1).Kind in [lkWire, lkEmpty]) and not N.Cell(R, C).Down then
    Result := 2;
end;

{ a box is drawn over two cells when the cell on its right is free; after a move, a paste or a new element
  a box whose right neighbour holds an element would shrink: it gets room. First from a wire further on
  in its row (the elements between move one cell right; only where no branch line is touched), else a
  column is inserted after the box in the whole network (the other rows get a wire where the rung goes
  through) }
procedure TPlcUI.LadKeepBoxes(N: TNetwork);
var
  R, C, W, K, Guard: Integer;
  Found, Through: Boolean;
  Ce: TLadCell;

  function Linked(Row, Col: Integer): Boolean;
  begin
    // a branch line at this cell: its own, or one coming down from the row above
    Result := N.Cell(Row, Col).Down or ((Row > 0) and N.Cell(Row - 1, Col).Down);
  end;

begin
  if (N = nil) or (N.Kind <> nkLAD) then Exit;
  for Guard := 1 to 64 do
  begin
    Found := False;
    for R := 0 to N.Rows - 1 do
    begin
      for C := 0 to N.Cols - 2 do
        if IsBox(N.Cell(R, C).Kind) and not N.Cell(R, C).Down and
          not (N.Cell(R, C + 1).Kind in [lkWire, lkEmpty]) then
        begin
          Found := True;
          Break;
        end;
      if Found then Break;
    end;
    if not Found then Exit;
    // a wire further on in the row, no branch line on the way
    W := -1;
    for K := C + 1 to N.Cols - 1 do
    begin
      if Linked(R, K) then Break;
      if N.Cell(R, K).Kind = lkWire then
      begin
        W := K;
        Break;
      end;
    end;
    if W > 0 then
    begin
      for K := W downto C + 2 do N.SetCell(R, K, N.Cell(R, K - 1));
      N.SetCell(R, C + 1, NewCell(lkWire, ''));
      Continue;
    end;
    // a new column after the box
    if N.LastUsedCol >= N.Cols - 1 then
    begin
      if N.Cols >= MaxLadCols then
      begin
        Toast(Format('no room for the box: a network has at most %d columns', [MaxLadCols]), True);
        Exit;
      end;
      N.SetCols(N.Cols + 1);
    end;
    for K := 0 to N.Rows - 1 do
    begin
      Through := (N.Cell(K, C).Kind <> lkEmpty) and (N.Cell(K, C + 1).Kind <> lkEmpty) and not N.Cell(K, C).Down;
      for W := N.Cols - 1 downto C + 2 do N.SetCell(K, W, N.Cell(K, W - 1));
      if (K = R) or Through then Ce := NewCell(lkWire, '') else Ce := EmptyCell;
      N.SetCell(K, C + 1, Ce);
    end;
  end;
end;

function TPlcUI.NetHeight(N: TNetwork): Single;
var
  R: Integer;
begin
  Result := 62;
  if N.Kind in [nkSTL, nkSCL] then
    Result := Result + Max(1, N.Stl.Count) * 19 + 18
  else
  begin
    for R := 0 to N.Rows - 1 do Result := Result + RowHeight(N, R);
    Result := Result + 12;
    if N.Cols > LadCols then Result := Result + 14;   // the horizontal scroll bar
  end;
end;

procedure TPlcUI.DrawCell(NI: Integer; N: TNetwork; R, C: Integer; X, Y, CW, RH: Single; Span: Integer;
  PowIn, PowOut: Integer; Sel: Boolean);
var
  CallB: TBlock;
  Pins: TIntArray;
  O2: TOperand;
  Ce: TLadCell;
  RY, MX, W, BX, BW, BY, BH, PY0: Single;
  LineC, ElC: TBGRAPixel;
  LW: Single;
  Sym, Abs1, S, Live: string;
  O: TOperand;
  E: string;
  V: Boolean;
  I, NP: Integer;
  Mon: Boolean;
  Title: string;
  Vi: TVarInfo;
  CB: TCBlock;
  Cell: Integer;
  HasOps: Boolean;

  procedure Wire(X1, X2: Single; Pow: Integer);
  begin
    if Pow = 1 then Ln(X1, RY, X2, RY, 2.6, cRed)
    else if Pow = 0 then DashLn(X1, RY, X2, RY, 1.3, 4, cInkSoft)
    else Ln(X1, RY, X2, RY, 1.4, cInk);
  end;

  procedure OperandLabels(const Txt0: string; Opd: TOperand; YTop: Single);
  var
    SymS, AbsS: string;
  begin
    SymS := '';
    AbsS := '';
    if Opd.Kind = okAddr then
    begin
      AbsS := FormatAddr(Opd.A, Project.Family);
      if (Txt0 <> '') and (Txt0[1] = '"') then SymS := Txt0
      else SymS := FRes.SymbolOf(Opd.A);
    end
    else
      SymS := Txt0;
    D.Layer := lyText;
    if SymS <> '' then TxtFit(fkUI, 10.5, MX, YTop, W - 6, SymS, cInk, 1);
    if AbsS <> '' then TxtFit(fkMono, 9.5, MX, YTop + 13, W - 6, AbsS, cInkSoft, 1)
    else if Txt0 = '' then TxtFit(fkUI, 10, MX, YTop + 6, W - 6, '<operand>', cRedLight, 1);
  end;

begin
  Ce := N.Cell(R, C);
  W := CW * Span;
  MX := X + W / 2;
  RY := Y + 42;
  Mon := PowIn >= 0;
  Cell := R * N.Cols + C;
  // the resolved operands (for symbols and live values)
  HasOps := False;
  FillChar(O, SizeOf(O), 0);
  if Ce.Opnd <> '' then FRes.Resolve(Ce.Opnd, O, E, False);
  D.Layer := lyControls;
  if Sel then
  begin
    RR(X + 1, Y + 1, W - 2, RH - 2, 4, Alpha(cGoldLight, 70));
    RRL(X + 1, Y + 1, W - 2, RH - 2, 4, 1.4, cGold);
  end;
  if Ce.Kind = lkEmpty then
  begin
    if not Mon then El(MX, RY, 1.4, 1.4, Alpha(cInkFaint, 160));
    Exit;
  end;
  if (PowOut = 1) then ElC := cRed else ElC := cInk;
  case Ce.Kind of
    lkWire: Wire(X, X + W, PowIn);
    lkNO, lkNC, lkPos, lkNeg:
      begin
        Wire(X, MX - 9, PowIn);
        Wire(MX + 9, X + W, PowOut);
        V := False;
        if Mon and (O.Kind = okAddr) then Rt.PeekBit(O, V);
        if Mon and V then
        begin
          // the operand is TRUE: the contact gap is filled
          RR(MX - 9, RY - 12, 18, 24, 2, Alpha(cRed, 60));
        end;
        LineC := cInk;
        if Mon and (PowOut = 1) then LineC := cRed;
        Ln(MX - 8, RY - 13, MX - 8, RY + 13, 2.2, LineC);
        Ln(MX + 8, RY - 13, MX + 8, RY + 13, 2.2, LineC);
        if Ce.Kind = lkNC then Ln(MX - 11, RY + 12, MX + 11, RY - 12, 1.6, LineC);
        D.Layer := lyText;
        if Ce.Kind = lkPos then Txt(fkUIB, 11, MX, RY - 8, 'P', LineC, 1);
        if Ce.Kind = lkNeg then Txt(fkUIB, 11, MX, RY - 8, 'N', LineC, 1);
        OperandLabels(Ce.Opnd, O, Y + 4);
        if Ce.Kind in [lkPos, lkNeg] then
        begin
          D.Layer := lyText;
          TxtFit(fkMono, 9.5, MX, RY + 16, W - 6, Ce.P[0], cInkSoft, 1);
        end;
      end;
    lkNot:
      begin
        Wire(X, MX - 14, PowIn);
        Wire(MX + 14, X + W, PowOut);
        RRL(MX - 14, RY - 10, 28, 20, 3, 1.4, ElC);
        D.Layer := lyText;
        Txt(fkUIB, 9.5, MX, RY - 7, 'NOT', ElC, 1);
      end;
    lkCoil, lkCoilNeg, lkSet, lkReset, lkSD, lkSE, lkSP, lkSS, lkSF, lkCU, lkCD, lkSC:
      begin
        Wire(X, MX - 13, PowIn);
        Wire(MX + 13, X + W, PowOut);
        LineC := cInk;
        if Mon and (PowIn = 1) then LineC := cRed;
        // ( )
        PolyLineD([PointF(MX - 6, RY - 13), PointF(MX - 11, RY - 7), PointF(MX - 12.5, RY),
          PointF(MX - 11, RY + 7), PointF(MX - 6, RY + 13)], 2, LineC);
        PolyLineD([PointF(MX + 6, RY - 13), PointF(MX + 11, RY - 7), PointF(MX + 12.5, RY),
          PointF(MX + 11, RY + 7), PointF(MX + 6, RY + 13)], 2, LineC);
        case Ce.Kind of
          lkCoilNeg: S := '/';
          lkSet: S := 'S';
          lkReset: S := 'R';
          lkSD: S := 'SD';
          lkSE: S := 'SE';
          lkSP: S := 'SP';
          lkSS: S := 'SS';
          lkSF: S := 'SF';
          lkCU: S := 'CU';
          lkCD: S := 'CD';
          lkSC: S := 'SC';
        else
          S := '';
        end;
        D.Layer := lyText;
        if S <> '' then Txt(fkUIB, 9.5, MX, RY - 7, S, LineC, 1);
        OperandLabels(Ce.Opnd, O, Y + 4);
        if Ce.Kind in [lkSD, lkSE, lkSP, lkSS, lkSF, lkSC] then
          TxtFit(fkMono, 9.5, MX, RY + 16, W - 6, Ce.P[0], cInkSoft, 1);
        if Mon and (O.Kind = okAddr) and (O.A.Area = arT) then
          TxtFit(fkMono, 9.5, MX, RY + 28, W - 6, FormatS5Time(MsToS5Time(Round(Rt.TimerRemainMs(O.A.Num)))), cRed, 1);
        if Mon and (O.Kind = okAddr) and (O.A.Area = arC) then
          TxtFit(fkMono, 9.5, MX, RY + 28, W - 6, 'C#' + IntToStr(Rt.CounterValue(O.A.Num)), cRed, 1);
      end;
  else
    begin
      // boxes
      NP := PinsOf(Ce);
      CallB := nil;
      if Ce.Kind = lkCall then CallB := CallBlockOf(Ce.Opnd);
      BX := X + 8;
      BW := W - 16;
      BY := Y + 30;
      BH := 22 + NP * 15 + 6;
      Wire(X, BX, PowIn);
      Wire(BX + BW, X + W, PowOut);
      D.Layer := lyControls;
      Shad(BX, BY, BW, BH, 3, 1.5, 3, 60);
      RR(BX, BY, BW, BH, 3, cSheet);
      if Mon and (PowIn = 1) then RRL(BX, BY, BW, BH, 3, 1.6, cRed)
      else RRL(BX, BY, BW, BH, 3, 1.3, cInk);
      Rc(BX + 1, BY + 1, BW - 2, 18, Alpha(cGoldLight, 110));
      Title := LadKindNames[Ce.Kind];
      case Ce.Kind of
        lkTON, lkTOF, lkTP, lkTONR, lkCTU, lkCTD, lkCTUD:
          begin
            // the type of the times / of the count: from the instance (TON_LTIME: LTime, CTU_DINT: DInt)
            if FRes.ResolveVar(Trim(Ce.Opnd), Vi, E) and (Vi.Udt <> nil) and (Vi.Udt.IecVar <> dtNone) then
              Title := Title + '  ' + DataTypeNames[Vi.Udt.IecVar]
            else if Ce.Kind in [lkTON, lkTOF, lkTP, lkTONR] then Title := Title + '  Time'
            else Title := Title + '  Int';
          end;
        lkCmp: Title := 'CMP ' + CmpOpNames[Ce.Cmp] + '  ' + DataTypeNames[Ce.DType];
        lkMove, lkAdd, lkSub, lkMul, lkDiv, lkNormX, lkScaleX, lkInRange, lkOutRange:
          Title := Title + '  ' + DataTypeNames[Ce.DType];
        lkConv, lkRound, lkTrunc, lkCeil, lkFloor:
          Title := Title + '  ' + DataTypeNames[Ce.DType] + ' to ' + DataTypeNames[Ce.DType2];
        lkCall: if CallB <> nil then Title := 'CALL ' + CallB.Title else Title := 'CALL';
      end;
      D.Layer := lyText;
      TxtFit(fkUIB, 10.5, BX + BW / 2, BY + 2, BW - 6, Title, cRedDark, 1);
      // the instance / block above the box
      if Ce.Opnd <> '' then TxtFit(fkUI, 10.5, MX, Y + 12, W - 6, Ce.Opnd, cInk, 1)
      else if Ce.Kind in [lkTON, lkTOF, lkTP, lkTONR, lkCTU, lkCTD, lkCTUD, lkCall] then
        TxtFit(fkUI, 10.5, MX, Y + 12, W - 6, '<instance>', cRedLight, 1);
      CB := nil;
      if Mon then CB := CompiledBlock;
      for I := 0 to NP - 1 do
      begin
        PY0 := BY + 22 + I * 15;
        S := Ce.P[I];
        Live := '';
        if Mon and (CB <> nil) and (NI <= High(CB.Nets)) and (Cell <= High(CB.Nets[NI].CellOps)) then
          Live := LiveText(CB.Nets[NI].CellOps[Cell][I + 1], '');
        // the instance values of IEC timers / counters
        if Mon and (Live = '') and (O.Kind = okAddr) then
        begin
          if (Ce.Kind in [lkTON, lkTOF, lkTP]) and (I = 1) or (Ce.Kind = lkTONR) and (I = 2) then
          begin
            FRes.Resolve(Ce.Opnd + '.ET', O, E, False);
            Live := LiveText(O, '');
            FRes.Resolve(Ce.Opnd, O, E, False);
          end;
          if (Ce.Kind in [lkCTU, lkCTD]) and (I = 2) or (Ce.Kind = lkCTUD) and (I = 4) then
          begin
            FRes.Resolve(Ce.Opnd + '.CV', O, E, False);
            Live := LiveText(O, '');
            FRes.Resolve(Ce.Opnd, O, E, False);
          end;
        end;
        if CallB <> nil then
        begin
          // a CALL box: the pins are the block's parameters
          Pins := CallPins(CallB);
          S := CallArg(Ce, I);
          Live := '';
          if Mon and (S <> '') and FRes.Resolve(S, O2, E, False) and (O2.Kind = okAddr) then Live := LiveText(O2, '');
          if CallB.Iface.Vars[Pins[I]].Section in [vsOutput, vsReturn] then
            Txt(fkUIB, 9.5, BX + 4, PY0, CallB.Iface.Vars[Pins[I]].Name + ' =>', cInkSoft)
          else
            Txt(fkUIB, 9.5, BX + 4, PY0, CallB.Iface.Vars[Pins[I]].Name, cInkSoft);
          if S = '' then S := '...';
        end
        else
          Txt(fkUIB, 9.5, BX + 4, PY0, LadParamName(Ce.Kind, I), cInkSoft);
        if Live <> '' then
          TxtFit(fkMono, 9.5, BX + BW - 4, PY0, BW - 40, Live, cRed, 2)
        else
          TxtFit(fkMono, 9.5, BX + BW - 4, PY0, BW - 40, S, cInk, 2);
      end;
      if Mon and (O.Kind = okAddr) and (Ce.Kind in [lkTON, lkTOF, lkTP, lkTONR]) then
      begin
        // the Q of the instance
        FRes.Resolve(Ce.Opnd + '.Q', O, E, False);
        V := False;
        Rt.PeekBit(O, V);
        if V then Txt(fkUIB, 9, BX + BW - 3, BY + BH - 13, 'Q', cRed, 2);
      end;
    end;
  end;
  if HasOps then ;
  if Sym = '' then ;
  if Abs1 = '' then ;
end;

procedure TPlcUI.DrawLad(NI: Integer; N: TNetwork; X, Y, W: Single);
var
  K: Integer;
  VisW, HS, XC, HX1, HX2, TY, TW, TX0: Single;
  R1, C1, R2, C2: Integer;
  R, C, Span, Cell, PIn, POut: Integer;
  CW, RY, Y0, RH, Y1, Y2: Single;
  Mon: Boolean;
  Rows: array of Single;
  Skip: array of Boolean;
  Pw: Integer;
  Ghost: Boolean;
  GR1, GC1, GR2, GC2, G0, GEnd: Integer;
  GI: array of TPoint;   // the display list commands of the dragged cells
  TR, TC: Integer;
begin
  if NI >= Length(FLadSeen) then SetLength(FLadSeen, NI + 1);
  FLadSeen[NI] := FTime;
  // the cells the mouse drags: their ghost follows it until the button goes up
  Ghost := (NI = FNetSel) and (FStlNet < 0) and (FLadMode = 2) and
    (Abs(FMX - FLadPressM.X) + Abs(FMY - FLadPressM.Y) > 4);
  GI := nil;
  if Ghost then LadSel(GR1, GC1, GR2, GC2);
  GEnd := GC2 + 1;   // a box reaches over its right neighbour
  // 8 columns show; a wider network scrolls sideways
  CW := (W - 26) / LadCols;
  VisW := W - 26;
  Mon := MonitorOk;
  HS := EnsureRange(GetHS(N), 0, Max(0, N.Cols * CW - VisW));
  if FLadFollow and (NI = FNetSel) and (FStlNet < 0) then
  begin
    // the focus cell into view
    if FCellC * CW < HS then HS := FCellC * CW
    else if (FCellC + 1) * CW > HS + VisW then HS := (FCellC + 1) * CW - VisW;
    FLadFollow := False;
  end;
  SetHS(N, HS);
  XC := X + 12 - HS;
  SetLength(Rows, N.Rows + 1);
  Y0 := Y;
  for R := 0 to N.Rows - 1 do
  begin
    Rows[R] := Y0;
    Y0 := Y0 + RowHeight(N, R);
  end;
  Rows[N.Rows] := Y0;
  // the left power rail
  D.Layer := lyControls;
  if Mon then Ln(X + 12, Y + 18, X + 12, Rows[N.Rows - 1] + 60, 3, cRed)
  else Ln(X + 12, Y + 18, X + 12, Rows[N.Rows - 1] + 60, 2.4, cInk);
  ClipD(X + 12, Y - 4, VisW + 2, Rows[N.Rows] - Y + 70);
  for R := 0 to N.Rows - 1 do
  begin
    SetLength(Skip, N.Cols);
    for C := 0 to N.Cols - 1 do Skip[C] := False;
    for C := 0 to N.Cols - 1 do
    begin
      if Skip[C] then Continue;
      Cell := R * N.Cols + C;
      Span := BoxSpan(N, R, C);
      if Span = 2 then Skip[C + 1] := True;
      if Mon then
      begin
        PIn := CellPower(NI, Cell, 0);
        POut := CellPower(NI, Cell, 1);
        if N.Cell(R, C).Kind = lkEmpty then begin PIn := 0; POut := 0; end;
      end
      else
      begin
        PIn := -1;
        POut := -1;
      end;
      // only what shows: the cells left / right of the view are not drawn and get no mouse region
      if (XC + (C + Span) * CW < X + 12) or (XC + C * CW > X + 12 + VisW) then Continue;
      G0 := D.N;
      DrawCell(NI, N, R, C, XC + C * CW, Rows[R], CW, Rows[R + 1] - Rows[R], Span, PIn, POut,
        (NI = FNetSel) and (FStlNet < 0) and (R = FCellR) and (C >= FCellC) and (C < FCellC + 1) and
        (Screen = scProgram));
      if Ghost and (R >= GR1) and (R <= GR2) and (C >= GC1) and (C <= GC2) then
      begin
        SetLength(GI, Length(GI) + 1);
        GI[High(GI)] := Point(G0, D.N);
        GEnd := Max(GEnd, C + Span);
      end;
      HX1 := Max(XC + C * CW, X + 12);
      HX2 := Min(XC + (C + Span) * CW, X + 12 + VisW);
      Hit(HX1, Rows[R], HX2 - HX1, Rows[R + 1] - Rows[R], Act(acCell, NI * 256 + Cell), hkDrag);
    end;
    // branch links on the right edges
    for C := 0 to N.Cols - 1 do
      if N.Cell(R, C).Down and (R + 1 < N.Rows) then
      begin
        RY := Rows[R] + 42;
        Y2 := Rows[R + 1] + 42;
        Pw := -1;
        if Mon then Pw := Max(CellPower(NI, R * N.Cols + C, 1), CellPower(NI, (R + 1) * N.Cols + C, 1));
        D.Layer := lyControls;
        if Pw = 1 then Ln(XC + (C + 1) * CW, RY, XC + (C + 1) * CW, Y2, 2.6, cRed)
        else Ln(XC + (C + 1) * CW, RY, XC + (C + 1) * CW, Y2, 1.5, cInk);
        El(XC + (C + 1) * CW, RY, 2.4, 2.4, cInk);
        El(XC + (C + 1) * CW, Y2, 2.4, 2.4, cInk);
      end;
  end;
  // the geometry for the mouse (rubber band, moving) and the selection
  if NI >= Length(FLadTops) then SetLength(FLadTops, NI + 1);
  if NI >= Length(FLadX0) then SetLength(FLadX0, NI + 1);
  FLadTops[NI] := Copy(Rows);
  FLadX0[NI] := XC;
  FLadCW := CW;
  if Ghost and (Length(GI) > 0) then
  begin
    // the ghost is drawn after every network (it may go over another one)
    FGhostOn := True;
    FGhostI := GI;
    FGhostR := RectF(XC + GC1 * CW, Rows[GR1], XC + GEnd * CW, Rows[GR2 + 1]);
    FGhostExtra := GEnd - GC2 - 1;
  end;
  if (NI = FNetSel) and (FStlNet < 0) and (LadSel(R1, C1, R2, C2) or (FLadMode = 2)) then
  begin
    D.Layer := lyOverlay;
    Rc(XC + C1 * CW, Rows[R1], (C2 - C1 + 1) * CW, Rows[R2 + 1] - Rows[R1], Alpha(cGold, 45));
    RRL(XC + C1 * CW, Rows[R1], (C2 - C1 + 1) * CW, Rows[R2 + 1] - Rows[R1], 3, 1.6, cGoldDark);
  end;
  // where the dragged cells go when the button goes up: red on wires / elements, grey where there is
  // nothing to hold them (no drop there)
  if (FLadMode = 2) and (FStlNet < 0) and LadTarget(K, TR, TC) and (K = NI) then
  begin
    LadSel(R1, C1, R2, C2);
    if (K <> FNetSel) or (TR <> R1) or (TC <> C1) then
    begin
      Y1 := Rows[EnsureRange(TR, 0, N.Rows)];
      Y2 := Rows[EnsureRange(TR + R2 - R1 + 1, 0, N.Rows)];
      if TR + R2 - R1 + 1 > N.Rows then Y2 := Y2 + (TR + R2 - R1 + 1 - N.Rows) * 66;
      GEnd := TC + C2 - C1 + 1 + FGhostExtra;
      // drawn over the ghost, after every network
      FDropOn := True;
      FDropOk := LadDropOk(K, TR, TC);
      FDropR := RectF(XC + TC * CW, Y1, XC + GEnd * CW, Y2);
    end;
  end;
  UnclipD;
  // more to the right / left: a soft edge, and the scroll bar under the rows
  if N.Cols > LadCols then
  begin
    D.Layer := lyOverlay;
    if HS > 0 then
      for K := 0 to 5 do Rc(X + 12 + K * 3, Y, 3, Rows[N.Rows] - Y, Alpha(cSheet, 150 - K * 25));
    if HS < N.Cols * CW - VisW - 0.5 then
      for K := 0 to 5 do Rc(X + 12 + VisW - (K + 1) * 3, Y, 3, Rows[N.Rows] - Y, Alpha(cSheet, 150 - K * 25));
    TY := Rows[N.Rows] + 4;
    D.Layer := lyControls;
    // the track leaves room for the column count on its right
    RR(X + 12, TY, VisW - 78, 8, 4, Alpha(cSheetDark, 200));
    TW := Max(30, (VisW - 78) * VisW / (N.Cols * CW));
    TX0 := X + 12 + HS / (N.Cols * CW - VisW) * (VisW - 78 - TW);
    RR(TX0, TY, TW, 8, 4, cRed);
    Hit(X + 12, TY - 3, VisW - 78, 14, Act(acHScroll, NI), hkDrag);
    D.Layer := lyText;
    Txt(fkUI, 9.5, X + 12 + VisW, TY - 3, Format('%d columns', [N.Cols]), cInkFaint, 2);
  end;
  // the wheel over the network: Shift (or a sideways wheel) scrolls it, else the editor
  Hit(X, Y, W, Rows[N.Rows] - Y + 20, whLad + NI, hkWheel);
  if RH = 0 then ;
end;

function SclValText(V: Double; DT: TDataType): string;
begin
  case DT of
    dtBool: if V <> 0 then Result := 'TRUE' else Result := 'FALSE';
    dtStruct: Result := Format('%d bytes copied', [Round(V)]);
    dtString, dtWString: Result := Format('%d characters', [Round(V)]);
    dtWChar: Result := 'WCHAR#16#' + IntToHex(Round(V) and $FFFF, 4);
    dtReal: Result := FloatToStrDot(V);
    dtTime: Result := FormatTime(Round(V));
    dtS5Time: Result := FormatS5Time(Round(V) and $FFFF);
    dtByte: Result := '16#' + IntToHex(Round(V) and $FF, 2);
    dtWord: Result := '16#' + IntToHex(Round(V) and $FFFF, 4);
    dtDWord: Result := '16#' + IntToHex(Int64(Round(V)) and $FFFFFFFF, 8);
    dtChar: Result := '''' + Chr(Round(V) and $7F) + '''';
  else
    Result := IntToStr(Int64(Round(V)));
  end;
end;

{ SCL: keywords, functions, symbols, #temps, literals and comments in their
  colours; with the monitor the value written / the condition of every line }
procedure TPlcUI.DrawScl(NI: Integer; N: TNetwork; X, Y, W: Single);
const
  Kws: array[0..36] of string = ('IF', 'THEN', 'ELSIF', 'ELSE', 'END_IF', 'CASE', 'OF', 'END_CASE', 'FOR',
    'TO', 'BY', 'DO', 'END_FOR', 'WHILE', 'END_WHILE', 'REPEAT', 'UNTIL', 'END_REPEAT', 'EXIT', 'CONTINUE',
    'RETURN', 'AND', 'OR', 'XOR', 'NOT', 'MOD', 'TRUE', 'FALSE', 'VAR_TEMP', 'END_VAR', 'REGION', 'END_REGION',
    'VAR', 'TON', 'CTU', 'TOF', 'CONSTANT');
var
  I, P, Q, NL, SlotI, Len, K: Integer;
  LY, CharW, TX, MonX: Single;
  S, Seg, U: string;
  CB: TCBlock;
  Slot: TMonSlot;
  Mon, Ed, InCmt, Bold, IsKwd: Boolean;
  C: TBGRAPixel;

  procedure Put(Col: Integer; const Txt0: string; AColor: TBGRAPixel; ABold: Boolean);
  begin
    if Txt0 = '' then Exit;
    if ABold then Txt(fkMonoB, 13, TX + Col * CharW, LY, Txt0, AColor)
    else Txt(fkMono, 13, TX + Col * CharW, LY, Txt0, AColor);
  end;

begin
  CharW := TxtW(fkMono, 13, 'M');
  TX := X + 44;
  Mon := MonitorOk;
  CB := nil;
  if Mon then CB := CompiledBlock;
  MonX := X + W - 230;
  NL := Max(1, N.Stl.Count);
  Ed := FStlNet = NI;
  D.Layer := lyControls;
  RR(X + 4, Y, W - 8, NL * 19 + 10, 4, Alpha(cWhite, 150));
  if Ed then RRL(X + 4, Y, W - 8, NL * 19 + 10, 4, 1.2, cGold);
  if Mon then DrawEdBack(NI, N, X, TX, Y, W, CharW, MonX - 10)
  else DrawEdBack(NI, N, X, TX, Y, W, CharW, X + W - 10);
  if Mon then
  begin
    D.Layer := lyText;
    Txt(fkUIB, 10, MonX, Y - 14, 'value / condition', cInkSoft);
  end;
  InCmt := False;
  for I := 0 to NL - 1 do
  begin
    LY := Y + 5 + I * 19;
    if I < N.Stl.Count then S := N.Stl[I] else S := '';
    D.Layer := lyText;
    Txt(fkMono, 11, X + 34, LY + 1.5, IntToStr(I + 1), cInkFaint, 2);
    if (N.Stl.Count = 0) and not Ed then
      Txt(fkUI, 12, TX, LY, 'click here and type SCL ...', cInkFaint);
    if Mon then ClipD(X, LY - 2, MonX - X - 10, 20);
    Len := Length(S);
    P := 1;
    while P <= Len do
    begin
      if InCmt then
      begin
        Q := P;
        while (Q < Len) and not ((S[Q] = '*') and (S[Q + 1] = ')')) do Inc(Q);
        if (Q < Len) then
        begin
          InCmt := False;
          Inc(Q, 2);
        end
        else
          Q := Len + 1;
        Put(P - 1, Copy(S, P, Q - P), Mixc(cJade, cInkSoft, 0.4), False);
        P := Q;
        Continue;
      end;
      if (S[P] = '/') and (P < Len) and (S[P + 1] = '/') then
      begin
        Put(P - 1, Copy(S, P, MaxInt), Mixc(cJade, cInkSoft, 0.4), False);
        Break;
      end;
      if (S[P] = '(') and (P < Len) and (S[P + 1] = '*') then
      begin
        InCmt := True;
        Continue;
      end;
      Q := P;
      Bold := False;
      if S[P] = '"' then
      begin
        Inc(Q);
        while (Q <= Len) and (S[Q] <> '"') do Inc(Q);
        Inc(Q);
        C := cInk;
      end
      else if S[P] = '#' then
      begin
        Inc(Q);
        while (Q <= Len) and (S[Q] in ['A'..'Z', 'a'..'z', '0'..'9', '_']) do Inc(Q);
        C := cGoldDark;
        Bold := True;
      end
      else if S[P] = '%' then
      begin
        Inc(Q);
        while (Q <= Len) and (S[Q] in ['A'..'Z', 'a'..'z', '0'..'9', '.', ':']) do Inc(Q);
        C := cInk;
      end
      else if S[P] in ['0'..'9'] then
      begin
        while (Q <= Len) and (S[Q] in ['0'..'9', '.', '_', '#', 'A'..'F', 'a'..'f']) do
        begin
          if (S[Q] = '.') and (Q < Len) and (S[Q + 1] = '.') then Break;
          Inc(Q);
        end;
        C := Mixc(cJade, cInk, 0.35);
      end
      else if S[P] in ['A'..'Z', 'a'..'z', '_'] then
      begin
        while (Q <= Len) and (S[Q] in ['A'..'Z', 'a'..'z', '0'..'9', '_']) do Inc(Q);
        if (Q <= Len) and (S[Q] = '#') then
        begin
          // T#5S, 16#..
          while (Q <= Len) and (S[Q] in ['A'..'Z', 'a'..'z', '0'..'9', '_', '#', '.', '-']) do Inc(Q);
          C := Mixc(cJade, cInk, 0.35);
        end
        else
        begin
          U := UpperCase(Copy(S, P, Q - P));
          IsKwd := False;
          for K := 0 to High(Kws) do
            if Kws[K] = U then IsKwd := True;
          if IsKwd then
          begin
            C := cRedDark;
            Bold := True;
          end
          else if (Q <= Len) and (S[Q] = '(') then
            C := cRed       // a function
          else
            C := cInk;
        end;
      end
      else
      begin
        while (Q <= Len) and not (S[Q] in ['"', '#', '%', '0'..'9', 'A'..'Z', 'a'..'z', '_', '/', '(']) do Inc(Q);
        if Q = P then Inc(Q);
        C := cInkSoft;
      end;
      Seg := Copy(S, P, Q - P);
      Put(P - 1, Seg, C, Bold);
      P := Q;
    end;
    if Mon then UnclipD;
    // the monitor: the value written / the condition tested on the line
    if Mon and (CB <> nil) and (NI <= High(CB.Nets)) and (CB.Nets[NI].Kind = nkSCL) and (I < CB.Nets[NI].Lines) then
    begin
      SlotI := CB.Nets[NI].MonBase + I;
      if (SlotI >= 0) and (SlotI <= High(CB.Mon)) then
      begin
        Slot := CB.Mon[SlotI];
        if (Slot.Stamp <> 0) and (Rt.CycleNo - Slot.Stamp < 50) then
        begin
          D.Layer := lyControls;
          Rc(MonX - 6, LY - 1, 230, 18, Alpha(cGoldLight, 70));
          D.Layer := lyText;
          if Slot.DT = dtBool then
          begin
            if Slot.Val <> 0 then Txt(fkMonoB, 12, MonX + 4, LY, 'TRUE', cRed)
            else Txt(fkMono, 12, MonX + 4, LY, 'FALSE', cInkSoft);
          end
          else
            TxtFit(fkMono, 12, MonX + 4, LY, 220, SclValText(Slot.Val, Slot.DT), cInk);
        end;
      end;
    end;
    Hit(X, LY - 2, W, 19, Act(acStlLine, NI * 1024 + I), hkDrag);
  end;
  DrawEdCaret(NI, N, TX, Y, CharW);
end;

procedure TPlcUI.DrawStl(NI: Integer; N: TNetwork; X, Y, W: Single);
var
  I, P, Q, NL: Integer;
  LY, CharW, TX, MonX: Single;
  S, Code, Cmt, Mn, Rest, Lbl: string;
  CB: TCBlock;
  Slot: TMonSlot;
  SlotI: Integer;
  Mon, Ed: Boolean;
  InQ: Boolean;
begin
  CharW := TxtW(fkMono, 13, 'M');
  TX := X + 44;
  Mon := MonitorOk;
  CB := nil;
  if Mon then CB := CompiledBlock;
  MonX := X + W - 330;
  NL := Max(1, N.Stl.Count);
  Ed := FStlNet = NI;
  D.Layer := lyControls;
  RR(X + 4, Y, W - 8, NL * 19 + 10, 4, Alpha(cWhite, 150));
  if Ed then RRL(X + 4, Y, W - 8, NL * 19 + 10, 4, 1.2, cGold);
  if Mon then DrawEdBack(NI, N, X, TX, Y, W, CharW, MonX - 10)
  else DrawEdBack(NI, N, X, TX, Y, W, CharW, X + W - 10);
  if Mon then
  begin
    D.Layer := lyText;
    Txt(fkUIB, 10, MonX, Y - 14, 'RLO', cInkSoft);
    Txt(fkUIB, 10, MonX + 34, Y - 14, 'STA', cInkSoft);
    Txt(fkUIB, 10, MonX + 70, Y - 14, 'STANDARD (ACCU 1)', cInkSoft);
    Txt(fkUIB, 10, MonX + 200, Y - 14, 'ACCU 2', cInkSoft);
  end;
  for I := 0 to NL - 1 do
  begin
    LY := Y + 5 + I * 19;
    if I < N.Stl.Count then S := N.Stl[I] else S := '';
    D.Layer := lyText;
    Txt(fkMono, 11, X + 34, LY + 1.5, IntToStr(I + 1), cInkFaint, 2);
    if (N.Stl.Count = 0) and not Ed then
      Txt(fkUI, 12, TX, LY, 'click here and type STL ...', cInkFaint);
    // split: label, mnemonic, operand, comment
    InQ := False;
    Cmt := '';
    Code := S;
    for P := 1 to Length(S) - 1 do
    begin
      if S[P] = '"' then InQ := not InQ;
      if not InQ and (S[P] = '/') and (S[P + 1] = '/') then
      begin
        Code := Copy(S, 1, P - 1);
        Cmt := Copy(S, P, MaxInt);
        Break;
      end;
    end;
    Lbl := '';
    Q := Pos(':', Code);
    if (Q > 1) and (Pos(' ', Trim(Copy(Code, 1, Q - 1))) = 0) and (Pos('"', Copy(Code, 1, Q)) = 0) and
      (Pos('#', Copy(Code, 1, Q)) = 0) and not (Code[1] in ['0'..'9', ' ']) then
    begin
      Lbl := Copy(Code, 1, Q);
      Code := Copy(Code, Q + 1, MaxInt);
    end;
    P := 1;
    while (P <= Length(Code)) and (Code[P] = ' ') do Inc(P);
    Q := P;
    while (Q <= Length(Code)) and (Code[Q] <> ' ') do Inc(Q);
    Mn := Copy(Code, 1, Q - 1);
    Rest := Copy(Code, Q, MaxInt);
    // the code stops before the status columns of the monitor
    if Mon then ClipD(X, LY - 2, MonX - X - 10, 20);
    if Lbl <> '' then Txt(fkMonoB, 13, TX, LY, Lbl, cGoldDark);
    Txt(fkMonoB, 13, TX + UTF8Length(Lbl) * CharW, LY, Mn, cRedDark);
    Txt(fkMono, 13, TX + (UTF8Length(Lbl) + UTF8Length(Mn)) * CharW, LY, Rest, cInk);
    if Cmt <> '' then
      Txt(fkMono, 13, TX + (UTF8Length(S) - UTF8Length(Cmt)) * CharW, LY, Cmt, Mixc(cJade, cInkSoft, 0.4));
    if Mon then UnclipD;
    // status columns
    if Mon and (CB <> nil) and (NI <= High(CB.Nets)) and (CB.Nets[NI].Kind = nkSTL) and (I < CB.Nets[NI].Lines) then
    begin
      SlotI := CB.Nets[NI].MonBase + I;
      if (SlotI >= 0) and (SlotI <= High(CB.Mon)) then
      begin
        Slot := CB.Mon[SlotI];
        if (Slot.Stamp <> 0) and (Rt.CycleNo - Slot.Stamp < 50) and (Trim(Code) <> '') then
        begin
          D.Layer := lyControls;
          Rc(MonX - 6, LY - 1, 330, 18, Alpha(cGoldLight, 70));
          D.Layer := lyText;
          if Slot.Status and 1 <> 0 then Txt(fkMonoB, 12, MonX + 8, LY, '1', cRed, 1)
          else Txt(fkMono, 12, MonX + 8, LY, '0', cInkSoft, 1);
          if Slot.Status and 2 <> 0 then Txt(fkMonoB, 12, MonX + 44, LY, '1', cRed, 1)
          else Txt(fkMono, 12, MonX + 44, LY, '0', cInkSoft, 1);
          Txt(fkMono, 12, MonX + 70, LY, IntToStr(SmallInt(Slot.Accu1 and $FFFF)) +
            IfThen(Slot.Accu1 > $FFFF, Format('  (%d)', [LongInt(Slot.Accu1)]), ''), cInk);
          Txt(fkMono, 12, MonX + 200, LY, IntToStr(SmallInt(Slot.Accu2 and $FFFF)), cInkSoft);
        end;
      end;
    end;
    Hit(X, LY - 2, W, 19, Act(acStlLine, NI * 1024 + I), hkDrag);
  end;
  DrawEdCaret(NI, N, TX, Y, CharW);
end;

{ the words that auto highlight leaves alone }
function AutoKw(const W: string): Boolean;
const
  Kws: array[0..41] of string = ('IF', 'THEN', 'ELSIF', 'ELSE', 'END_IF', 'CASE', 'OF', 'END_CASE', 'FOR', 'TO',
    'BY', 'DO', 'END_FOR', 'WHILE', 'END_WHILE', 'REPEAT', 'UNTIL', 'END_REPEAT', 'EXIT', 'CONTINUE', 'RETURN',
    'AND', 'OR', 'XOR', 'NOT', 'MOD', 'TRUE', 'FALSE', 'VAR_TEMP', 'VAR', 'END_VAR', 'CONSTANT', 'REGION',
    'END_REGION', 'A', 'AN', 'O', 'ON', 'L', 'T', 'S', 'R');
var
  K: Integer;
begin
  for K := 0 to High(Kws) do
    if SameText(Kws[K], W) then Exit(True);
  Result := False;
end;

{ behind the text: the current line, the selection (also a column selection), the other places of
  the selected word (or of the name at the caret), the find matches and the bracket pair at the caret }
procedure TPlcUI.DrawEdBack(NI: Integer; N: TNetwork; X, TX, Y, W, CharW, MaxX: Single);
var
  R, C1, C2, R1, R2, K: Integer;
  A, B, P1, P2, At, M: TTextPos;
  Sel, Wd, L, Lw: string;
  Mine: Boolean;
  Tmp: TTextEdit;

  procedure Box(Row, Col1, Col2: Integer; Cl: TBGRAPixel; Extra: Single = 0);
  var
    X1, X2: Single;
  begin
    X1 := TX + Col1 * CharW;
    X2 := Min(MaxX, TX + Col2 * CharW + Extra);
    if X2 > X1 then Rc(X1, Y + 4 + Row * 19, X2 - X1, 19, Cl);
  end;

begin
  if N.Stl.Count = 0 then Exit;
  Mine := (FStlNet = NI) and (FEdNet = N);
  D.Layer := lyControls;
  // the current line
  if (FStlNet = NI) and (FStlRow < N.Stl.Count) then Rc(X + 26, Y + 4 + FStlRow * 19, MaxX - X - 26, 19, Alpha(cGoldLight, 60));
  Sel := '';
  if Mine and FEd.HasSel then
  begin
    if FEd.Block then
    begin
      FEd.BlockRange(R1, R2, C1, C2);
      for R := R1 to Min(R2, N.Stl.Count - 1) do Box(R, C1, C2, Alpha(cGold, 175), IfThen(C1 = C2, 2, 0));
    end
    else
    begin
      FEd.SelRange(A, B);
      for R := A.Row to Min(B.Row, N.Stl.Count - 1) do
      begin
        if R = A.Row then C1 := A.Col else C1 := 0;
        if R = B.Row then C2 := B.Col else C2 := UTF8Length(N.Stl[R]);
        if R < B.Row then Box(R, C1, C2, Alpha(cGold, 175), CharW * 0.6) else Box(R, C1, C2, Alpha(cGold, 175));
      end;
      if A.Row = B.Row then Sel := FEd.SelText;
    end;
  end;
  // smart highlighting: the selected word everywhere in this network
  if (Sel = '') and (FEdNet <> nil) and FEd.HasSel and not FEd.Block and (FEd.Caret.Row = FEd.Anchor.Row) then
    Sel := FEd.SelText;
  Wd := '';
  if Sel <> '' then
  begin
    Wd := Sel;
    for K := 1 to UTF8Length(Sel) do
      if not IsWordCh(UTF8Copy(Sel, K, 1)) then Wd := '';
  end;
  // auto highlight: the name at the caret everywhere in the code of the block (not a keyword, not a number)
  if (FStlNet = NI) and not (Mine and FEd.HasSel) and (FStlRow < N.Stl.Count) then
  begin
    Tmp := TTextEdit.Create;
    try
      Tmp.Lines := N.Stl;
      Tmp.WordAt(Tmp.TP(FStlRow, FStlCol), C1, C2);
      Lw := UTF8Copy(N.Stl[FStlRow], C1 + 1, C2 - C1);
    finally
      Tmp.Free;
    end;
    Tmp := nil;
    if (UTF8Length(Lw) < 2) or (Lw[1] in ['0'..'9']) or AutoKw(Lw) then Lw := '';
    FAutoWord := Lw;
  end;
  if (Wd = '') and (FStlNet >= 0) and not (Mine and FEd.HasSel) then Wd := FAutoWord;
  Tmp := nil;
  if (Wd <> '') or (FFindMode in [1, 2]) and (FFindText <> '') then
  begin
    Tmp := TTextEdit.Create;
    Tmp.Lines := N.Stl;
  end;
  try
    if Wd <> '' then
    begin
      P2 := Tmp.TP(0, 0);
      while Tmp.Find(Wd, P2, False, True, True, P1, P2) do
        if not (Mine and (PosEq(P1, A) or PosEq(P1, B) or PosEq(P2, A) or PosEq(P2, B))) then
          Box(P1.Row, P1.Col, P2.Col, Alpha(cJade, 60));
    end;
    if (FFindMode in [1, 2]) and (FFindText <> '') then
    begin
      P2 := Tmp.TP(0, 0);
      K := 0;
      while Tmp.Find(FFindText, P2, False, FFindCase, FFindWord, P1, P2) and (K < 500) do
      begin
        Box(P1.Row, P1.Col, P2.Col, Alpha(cAmber, 65));
        Inc(K);
      end;
    end;
  finally
    Tmp.Free;
  end;
  // the bracket pair at the caret
  if Mine and not FEd.HasSel and FEd.MatchBracket(FEd.Caret, At, M) then
  begin
    Box(At.Row, At.Col, At.Col + 1, Alpha(cRed, 70));
    Box(M.Row, M.Col, M.Col + 1, Alpha(cRed, 70));
  end;
  if L = '' then ;
  if Lw = '' then ;
end;

procedure TPlcUI.DrawEdCaret(NI: Integer; N: TNetwork; TX, Y, CharW: Single);
var
  R, R1, R2, C1, C2: Integer;

  procedure One(Row, Col: Integer);
  var
    LY: Single;
  begin
    LY := Y + 5 + Row * 19;
    if FEd.Overwrite then Rc(TX + Col * CharW, LY + 13, CharW, 3, cRed)
    else Rc(TX + Col * CharW - 0.5, LY, 1.5, 17, cRed);
  end;

begin
  if FStlNet <> NI then Exit;
  FCaretX := TX + FStlCol * CharW;
  FCaretY := Y + 5 + FStlRow * 19;
  if Frac(FTime * 1.6) >= 0.62 then Exit;
  D.Layer := lyOverlay;
  if (FEdNet = N) and FEd.Block then
  begin
    // a column selection: a caret on every row
    FEd.BlockRange(R1, R2, C1, C2);
    for R := R1 to Min(R2, Max(0, N.Stl.Count - 1)) do One(R, FEd.Caret.Col);
  end
  else
    One(FStlRow, FStlCol);
end;

{ under the networks: Find / Replace / Go to line }
procedure TPlcUI.DrawFindBar(X, Y, W: Single);
var
  CX: Single;
begin
  D.Layer := lySheets;
  Shad(X, Y, W, 38, 5, 2, 4, 70);
  RR(X, Y, W, 38, 5, Mixc(cSheet, cGoldLight, 0.25));
  D.Layer := lyOrnament;
  RRL(X + 0.5, Y + 0.5, W - 1, 37, 5, 1.2, cGoldDark);
  D.Layer := lyText;
  CX := X + 12;
  if FFindMode = 3 then
  begin
    Txt(fkUIB, 12, CX, Y + 10, 'Go to line', cRedDark);
    Field(CX + 84, Y + 7, 90, 24, Act(fdGoto, 0), FGotoText, fkMono, 12, 0, True, 'line');
    Button(CX + 184, Y + 7, 60, 24, 'Go', Act(acGotoGo, 0), bsPrimary, True, 11);
    D.Layer := lyText;
    if (FStlNet >= 0) and (CurNet <> nil) then
      Txt(fkUI, 11, CX + 256, Y + 11, Format('1 .. %d in network %d', [CurNet.Stl.Count, FStlNet + 1]), cInkSoft);
  end
  else
  begin
    Txt(fkUIB, 12, CX, Y + 10, 'Find', cRedDark);
    Field(CX + 42, Y + 7, 200, 24, Act(fdFind, 0), FFindText, fkMono, 12, 0, True, 'text');
    CX := CX + 250;
    if FFindMode = 2 then
    begin
      D.Layer := lyText;
      Txt(fkUIB, 12, CX, Y + 10, 'Replace', cRedDark);
      Field(CX + 62, Y + 7, 170, 24, Act(fdRepl, 0), FReplText, fkMono, 12, 0, True, 'with');
      CX := CX + 240;
    end;
    Button(CX, Y + 7, 56, 24, 'Prev', Act(acFindPrev, 0), bsNormal, FFindText <> '', 11);
    Button(CX + 60, Y + 7, 60, 24, 'Next', Act(acFindNext, 0), bsPrimary, FFindText <> '', 11);
    CX := CX + 128;
    if FFindMode = 2 then
    begin
      Button(CX, Y + 7, 64, 24, 'Replace', Act(acReplOne, 0), bsNormal, FFindText <> '', 11);
      Button(CX + 68, Y + 7, 84, 24, 'Replace all', Act(acReplAll, 0), bsNormal, FFindText <> '', 11);
      CX := CX + 160;
    end;
    Check(CX, Y + 11, 15, FFindCase, Act(acFindCase, 0));
    D.Layer := lyText;
    Txt(fkUI, 11, CX + 20, Y + 11, 'Aa', cInk);
    Check(CX + 46, Y + 11, 15, FFindWord, Act(acFindWord, 0));
    D.Layer := lyText;
    Txt(fkUI, 11, CX + 66, Y + 11, 'word', cInk);
    CX := CX + 104;
    TxtFit(fkUI, 11, CX, Y + 11, X + W - CX - 40, FFindMsg, cRed);
  end;
  Button(X + W - 32, Y + 7, 24, 24, '×', Act(acFindClose, 0), bsFlat, True, 13);
end;

{ ---------- word completion (Ctrl+Space) ---------- }

const
  SclWords: array[0..108] of string = ('IF', 'THEN', 'ELSIF', 'ELSE', 'END_IF', 'CASE', 'OF', 'END_CASE', 'FOR',
    'TO', 'BY', 'DO', 'END_FOR', 'WHILE', 'END_WHILE', 'REPEAT', 'UNTIL', 'END_REPEAT', 'EXIT', 'CONTINUE',
    'RETURN', 'AND', 'OR', 'XOR', 'NOT', 'MOD', 'TRUE', 'FALSE', 'VAR_TEMP', 'END_VAR', 'REGION', 'END_REGION',
    'ABS', 'SQRT', 'SQR', 'LN', 'LOG', 'EXP', 'SIN', 'COS', 'TAN', 'TRUNC', 'ROUND', 'MIN', 'MAX', 'LIMIT', 'SEL',
    'NORM_X', 'SCALE_X', 'SHL', 'SHR', 'ROL', 'ROR', 'TON', 'TOF', 'TP', 'TONR', 'CTU', 'CTD', 'CTUD',
    'INT_TO_REAL', 'REAL_TO_INT', 'DINT_TO_REAL', 'REAL_TO_DINT', 'INT_TO_DINT', 'DINT_TO_INT', 'Bool', 'Int',
    'DInt', 'Real', 'CONSTANT', 'MUX', 'LEN', 'CONCAT', 'LEFT', 'RIGHT', 'MID', 'FIND', 'String', 'WString', 'Char',
    'WChar', 'LInt', 'ULInt', 'LWord', 'LReal', 'LTime', 'LTime_Of_Day', 'LDT', 'Date_And_Time', 'DTL', 'TON_TIME',
    'TOF_TIME', 'TP_TIME', 'TONR_TIME', 'TON_LTIME', 'CTU_INT', 'CTD_INT', 'CTUD_INT', 'CTU_DINT', 'R_TRIG', 'F_TRIG',
    'TIME_TO_LTIME', 'LTIME_TO_TIME', 'DT_TO_DATE', 'DT_TO_TOD', 'DT_TO_LDT', 'LREAL_TO_REAL', 'REAL_TO_LREAL');
  StlWords: array[0..43] of string = ('A', 'AN', 'O', 'ON', 'X', 'XN', 'S', 'R', 'NOT', 'SET', 'CLR', 'FP', 'FN',
    'L', 'T', 'CALL', 'JU', 'JC', 'JCN', 'JZ', 'JN', 'JP', 'JM', 'LOOP', 'BE', 'BEC', 'BEU', 'NOP', 'OPN', 'ITD',
    'DTR', 'RND', 'TRUNC', 'SD', 'SE', 'SP', 'SS', 'SF', 'CU', 'CD', 'TAK', 'PUSH', 'POP', 'SLW');

procedure TPlcUI.CompStart;
begin
  FCompOpen := True;
  FCompSel := 0;
  CompFilter;
end;

{ the candidates for the word before the caret: keywords, the words of the block, symbols }
procedure TPlcUI.CompFilter;
var
  Pre, U, W: string;
  I, J, K, P: Integer;
  B: TBlock;
  N: TNetwork;
  All: TStringList;
  Db: TDataBlock;

  procedure Add(const S: string);
  begin
    if (S <> '') and (UTF8Length(S) > UTF8Length(Pre)) and SameText(UTF8Copy(S, 1, UTF8Length(Pre)), Pre) then
      All.Add(S);
  end;

begin
  FComp.Clear;
  if FEdNet = nil then
  begin
    FCompOpen := False;
    Exit;
  end;
  Pre := FEd.WordBefore(FCompC1);
  All := TStringList.Create;
  try
    All.Sorted := True;
    All.Duplicates := dupIgnore;
    All.CaseSensitive := False;
    if FEdNet.Kind = nkSCL then
      for I := 0 to High(SclWords) do Add(SclWords[I])
    else
      for I := 0 to High(StlWords) do Add(StlWords[I]);
    B := CurBlock;
    if B <> nil then
    begin
      for I := 0 to B.NetCount - 1 do
      begin
        N := B.Net(I);
        if not (N.Kind in [nkSTL, nkSCL]) then Continue;
        for J := 0 to N.Stl.Count - 1 do
        begin
          U := N.Stl[J];
          P := 1;
          while P <= Length(U) do
          begin
            if U[P] in ['A'..'Z', 'a'..'z', '_'] then
            begin
              K := P;
              while (K <= Length(U)) and (U[K] in ['A'..'Z', 'a'..'z', '0'..'9', '_']) do Inc(K);
              W := Copy(U, P, K - P);
              // not the word being typed itself
              if not ((N = FEdNet) and (J = FEd.Caret.Row) and (K - 1 = FEd.Caret.Col)) then Add(W);
              P := K;
            end
            else
              Inc(P);
          end;
        end;
      end;
      for I := 0 to High(B.Iface.Vars) do Add(B.Iface.Vars[I].Name);
    end;
    for I := 0 to High(Project.Tags) do Add(Project.Tags[I].Name);
    for I := 0 to Project.DBCount - 1 do
    begin
      Db := Project.DB(I);
      Add(Db.Name);
      for J := 0 to High(Db.Vars) do Add(Db.Vars[J].Name);
    end;
    for I := 0 to Min(All.Count - 1, 199) do FComp.Add(All[I]);
  finally
    All.Free;
  end;
  if FComp.Count = 0 then FCompOpen := False;
  FCompSel := EnsureRange(FCompSel, 0, Max(0, FComp.Count - 1));
end;

procedure TPlcUI.CompAccept;
var
  N: TNetwork;
begin
  if not FCompOpen or (FCompSel >= FComp.Count) then Exit;
  N := EdBegin;
  if N = nil then Exit;
  EdUndoPoint(N, 0);
  FEd.Anchor := FEd.TP(FEd.Caret.Row, FCompC1);
  FEd.InsertText(FComp[FCompSel]);
  FCompOpen := False;
  EdEnd(N);
end;

procedure TPlcUI.DrawComp;
var
  I, First, NV: Integer;
  X, Y, W: Single;
begin
  if not FCompOpen or (FComp.Count = 0) or (FStlNet < 0) then Exit;
  NV := Min(8, FComp.Count);
  First := EnsureRange(FCompSel - NV + 1, 0, Max(0, FComp.Count - NV));
  W := 220;
  X := Min(FCaretX, 1280 - W);
  Y := FCaretY + 20;
  if Y + NV * 20 + 8 > 850 then Y := FCaretY - NV * 20 - 10;
  D.Layer := lyOverlay;
  Shad(X, Y, W, NV * 20 + 8, 4, 2, 5, 90);
  RR(X, Y, W, NV * 20 + 8, 4, cSheet);
  RRL(X, Y, W, NV * 20 + 8, 4, 1.2, cGoldDark);
  for I := First to First + NV - 1 do
  begin
    if I = FCompSel then RR(X + 3, Y + 4 + (I - First) * 20, W - 6, 20, 3, cRed);
    if I = FCompSel then Txt(fkMono, 12, X + 10, Y + 6 + (I - First) * 20, FComp[I], cSheet)
    else Txt(fkMono, 12, X + 10, Y + 6 + (I - First) * 20, FComp[I], cInk);
    Hit(X, Y + 4 + (I - First) * 20, W, 20, Act(acComp, I));
  end;
  if FComp.Count > NV then
    Txt(fkUI, 9.5, X + W - 6, Y + NV * 20 - 6, Format('%d / %d', [FCompSel + 1, FComp.Count]), cInkFaint, 2);
end;

procedure TPlcUI.DrawNetwork(NI: Integer; N: TNetwork; X, Y, W: Single; out H: Single);
var
  Sel, En: Boolean;
  Hd: string;
begin
  H := NetHeight(N);
  Sel := NI = FNetSel;
  D.Layer := lySheets;
  Shad(X, Y, W, H - 8, 6, 2, 5, 60);
  if Sel then RR(X, Y, W, H - 8, 6, cSheet) else RR(X, Y, W, H - 8, 6, Mixc(cSheet, cSheet2, 0.45));
  D.Layer := lyOrnament;
  if Sel then RRL(X + 0.5, Y + 0.5, W - 1, H - 9, 6, 1.4, cGold)
  else RRL(X + 0.5, Y + 0.5, W - 1, H - 9, 6, 0.8, Alpha(cRed, 90));
  Rc(X + 1, Y + 1, 5, H - 10, Alpha(cRed, 160));
  D.Layer := lyText;
  Hd := Format('Network %d:', [NI + 1]);
  Hit(X, Y, W, 52, Act(acNetHead, NI));   // under the fields and buttons: a click selects, the right button exports
  Txt(fkUIB, 13, X + 14, Y + 6, Hd, cRedDark);
  if N.Kind = nkLAD then
  begin
    Field(X + 14 + TxtW(fkUIB, 13, Hd) + 6, Y + 4, W - 480, 22, Act(fdNetTitle, NI), N.Title, fkUIB, 13, 0, True,
      'network title');
    // the network grows to the right; the last column goes when it is empty
    Button(X + W - 308, Y + 6, 54, 22, '- Col', Act(acColDel, NI), bsFlat, N.Cols > LadCols, 11);
    Button(X + W - 250, Y + 6, 54, 22, '+ Col', Act(acColAdd, NI), bsNormal, N.Cols < MaxLadCols, 11);
  end
  else
    Field(X + 14 + TxtW(fkUIB, 13, Hd) + 6, Y + 4, W - 360, 22, Act(fdNetTitle, NI), N.Title, fkUIB, 13, 0, True,
      'network title');
  Field(X + 14, Y + 28, W - 200, 20, Act(fdNetComment, NI), N.Comment, fkUI, 11, 0, True, 'comment');
  // the language switches only while the network is empty: code of one language is not another's
  En := not NetHasCode(N);
  case N.Kind of
    nkLAD: Button(X + W - 190, Y + 6, 52, 22, 'LAD', Act(acNetKind, NI), bsToggleOn, En, 11);
    nkSTL: Button(X + W - 190, Y + 6, 52, 22, 'STL', Act(acNetKind, NI), bsGold, En, 11);
  else
    Button(X + W - 190, Y + 6, 52, 22, 'SCL', Act(acNetKind, NI), bsPrimary, En, 11);
  end;
  Button(X + W - 132, Y + 6, 30, 22, '↑', Act(acNetUp, NI), bsNormal, NI > 0, 12);
  Button(X + W - 98, Y + 6, 30, 22, '↓', Act(acNetDown, NI), bsNormal, NI < CurBlock.NetCount - 1, 12);
  Button(X + W - 64, Y + 6, 52, 22, 'Delete', Act(acDelNet, NI), bsFlat, True, 11);
  Hit(X, Y, 12, H - 8, Act(acNetSel, NI));
  case N.Kind of
    nkSTL: DrawStl(NI, N, X + 12, Y + 54, W - 20);
    nkSCL: DrawScl(NI, N, X + 12, Y + 54, W - 20);
  else
    DrawLad(NI, N, X + 14, Y + 52, W - 24);
  end;
end;

type
  TPalItem = record
    G: Integer;          // the group
    L: string;           // the label of its button
    K: TLadKind;
    C: Integer;          // a comparator: its operator + 1
  end;

const
  PalGroups: array[0..5] of string = ('Bit logic', 'Timers / counters', 'Comparator', 'Math / move', 'Converter',
    'Program control');
  PalItems: array[0..47] of TPalItem = (
    (G: 0; L: '-| |-'; K: lkNO; C: 0), (G: 0; L: '-|/|-'; K: lkNC; C: 0), (G: 0; L: '-|P|-'; K: lkPos; C: 0),
    (G: 0; L: '-|N|-'; K: lkNeg; C: 0), (G: 0; L: 'NOT'; K: lkNot; C: 0), (G: 0; L: 'wire'; K: lkWire; C: 0),
    (G: 0; L: '-( )-'; K: lkCoil; C: 0), (G: 0; L: '-(/)-'; K: lkCoilNeg; C: 0), (G: 0; L: '-(S)-'; K: lkSet; C: 0),
    (G: 0; L: '-(R)-'; K: lkReset; C: 0),
    (G: 1; L: 'TON'; K: lkTON; C: 0), (G: 1; L: 'TOF'; K: lkTOF; C: 0), (G: 1; L: 'TP'; K: lkTP; C: 0),
    (G: 1; L: 'TONR'; K: lkTONR; C: 0), (G: 1; L: 'CTU'; K: lkCTU; C: 0), (G: 1; L: 'CTD'; K: lkCTD; C: 0),
    (G: 1; L: 'CTUD'; K: lkCTUD; C: 0), (G: 1; L: '(SD)'; K: lkSD; C: 0), (G: 1; L: '(SE)'; K: lkSE; C: 0),
    (G: 1; L: '(SP)'; K: lkSP; C: 0), (G: 1; L: '(SS)'; K: lkSS; C: 0), (G: 1; L: '(SF)'; K: lkSF; C: 0),
    (G: 1; L: '(CU)'; K: lkCU; C: 0), (G: 1; L: '(CD)'; K: lkCD; C: 0), (G: 1; L: '(SC)'; K: lkSC; C: 0),
    (G: 2; L: 'CMP =='; K: lkCmp; C: 1), (G: 2; L: 'CMP <>'; K: lkCmp; C: 2), (G: 2; L: 'CMP >'; K: lkCmp; C: 3),
    (G: 2; L: 'CMP <'; K: lkCmp; C: 4), (G: 2; L: 'CMP >='; K: lkCmp; C: 5), (G: 2; L: 'CMP <='; K: lkCmp; C: 6),
    (G: 2; L: 'IN_RANGE'; K: lkInRange; C: 0), (G: 2; L: 'OUT_RANGE'; K: lkOutRange; C: 0),
    (G: 3; L: 'MOVE'; K: lkMove; C: 0), (G: 3; L: 'ADD'; K: lkAdd; C: 0), (G: 3; L: 'SUB'; K: lkSub; C: 0),
    (G: 3; L: 'MUL'; K: lkMul; C: 0), (G: 3; L: 'DIV'; K: lkDiv; C: 0),
    (G: 4; L: 'CONV'; K: lkConv; C: 0), (G: 4; L: 'ROUND'; K: lkRound; C: 0), (G: 4; L: 'TRUNC'; K: lkTrunc; C: 0),
    (G: 4; L: 'CEIL'; K: lkCeil; C: 0), (G: 4; L: 'FLOOR'; K: lkFloor; C: 0), (G: 4; L: 'NORM_X'; K: lkNormX; C: 0),
    (G: 4; L: 'SCALE_X'; K: lkScaleX; C: 0),
    (G: 5; L: 'CALL'; K: lkCall; C: 0), (G: 5; L: ''; K: lkEmpty; C: 0), (G: 5; L: ''; K: lkEmpty; C: 0));
  PalViewH = 326;

{ the LAD elements in groups (only what the CPU family has); more than fit scroll }
procedure TPlcUI.DrawPalette(X, Y, W: Single);
var
  I, Col, G: Integer;
  K: TLadKind;
  BX, BY, BW, YY: Single;
  Fam: TCpuFamily;
  Ok: Boolean;
begin
  Fam := Project.Family;
  BW := (W - 12) / 3;
  ClipD(X - 4, Y, W + 8, PalViewH);
  Hit(X - 4, Y, W + 8, PalViewH, whPal, hkWheel);
  YY := Y - FPalScroll;
  G := -1;
  Col := 0;
  for I := 0 to High(PalItems) do
  begin
    K := PalItems[I].K;
    if K = lkEmpty then Continue;
    Ok := True;
    if (Fam = cfS71200) and (K in [lkSD, lkSE, lkSP, lkSS, lkSF, lkCU, lkCD, lkSC]) then Ok := False;
    if not IsTia(Fam) and (K = lkTONR) then Ok := False;
    if not Ok then Continue;
    if PalItems[I].G <> G then
    begin
      // a new group: its title on a line of its own
      if Col > 0 then YY := YY + 26;
      if G >= 0 then YY := YY + 4;
      G := PalItems[I].G;
      D.Layer := lyText;
      Txt(fkUIB, 10, X, YY, PalGroups[G], cRedDark);
      D.Layer := lyOrnament;
      Ln(X + TxtW(fkUIB, 10, PalGroups[G]) + 6, YY + 8, X + W, YY + 8, 0.6, Alpha(cGoldDark, 140));
      YY := YY + 17;
      Col := 0;
    end;
    BX := X + Col * (BW + 6);
    BY := YY;
    Button(BX, BY, BW, 22, PalItems[I].L, Act(acPal, Ord(K) + 256 * PalItems[I].C), bsNormal, True, 10);
    Inc(Col);
    if Col = 3 then
    begin
      Col := 0;
      YY := YY + 26;
    end;
  end;
  if Col > 0 then YY := YY + 26;
  UnclipD;
  // the scroll bar when the groups are longer than the place
  FPalH := YY + FPalScroll - Y;
  FPalScroll := EnsureRange(FPalScroll, 0, Max(0, FPalH - PalViewH));
  if FPalH > PalViewH then VScrollBar(8, X + W + 4, Y, PalViewH, FPalH, PalViewH, FPalScroll)
  else FVs[8].Range := 0;
end;

const
  ElemViewH = 392;
  ElemRowH = 16;
  ElemCatH = 19;
  SclHelp: array[0..26] of string = (
    'IF c THEN .. ELSIF .. ELSE .. END_IF;',
    'CASE x OF 1: ..; 2..5: ..; ELSE END_CASE;',
    'FOR #i := 0 TO 9 BY 1 DO .. END_FOR;',
    'WHILE c DO .. END_WHILE;',
    'REPEAT .. UNTIL c END_REPEAT;',
    'EXIT;  CONTINUE;  RETURN;',
    'VAR_TEMP i : Int; END_VAR  -> #i',
    ':=  + - * / MOD **  ( )',
    '= <> < > <= >=  AND OR XOR NOT',
    'INT_TO_REAL  REAL_TO_INT ...',
    'ABS SQRT LN EXP SIN COS ROUND',
    'MIN MAX LIMIT SEL NORM_X SCALE_X',
    'SHL SHR ROL ROR (IN :=, N :=)',
    '"DB".T.TON(IN := x, PT := T#5S,',
    '          Q => y, ET => t);',
    '"DB".C.CTU(CU := x, PV := 5);',
    '"DB".Arr[#i]  %MW20  "Tag"  FC1();',
    'REGION name .. END_REGION  // (* *)',
    'VAR_TEMP t : Array[0..9] of Int;',
    '"DB".Arr[#i].Member  #s.x (PLC types)',
    '"DB".M[#i].T.TON(..)  .Hist[#j]',
    'Ctrl+Z/Y undo/redo  Ctrl+D duplicate',
    'Ctrl+L delete line  Ctrl+Q comment',
    'Ctrl+Shift+Up/Down move lines',
    'Ctrl+F find  Ctrl+H replace  F3',
    'Ctrl+G line  Ctrl+Space complete',
    'Alt+drag / Alt+Shift+arrows column');
  StlHelp: array[0..19] of string = (
    'A O X AN ON XN  bit logic',
    'A( O( )  O   nesting, AND before OR',
    '= S R  FP FN  NOT SET CLR',
    'L T LC  ACCU1 <- / -> memory',
    '+I -I *I /I  +D -D  +R -R *R /R',
    '==I <>I >I <I >=I <=I  (D, R)',
    'SD SE SP SS SF T n  S5 timers',
    'CU CD S R C n   S5 counters',
    'JU JC JCN JZ JN JP JM LOOP',
    'ITD DTR RND TRUNC ITB BTI',
    'AW OW XOW  SLW SRW RLD',
    'OPN DB n  DB1.DBW2  "DB".Var',
    'CALL FCn + lines  a := MW0  BE  NOP 0',
    'TAK PUSH POP  ENT LEAVE (400)',
    'Ctrl+Z/Y undo/redo  Ctrl+D duplicate',
    'Ctrl+L delete line  Ctrl+Q comment',
    'Ctrl+Shift+Up/Down move lines',
    'Ctrl+F find  Ctrl+H replace  F3',
    'Ctrl+G line  Ctrl+Space complete',
    'Alt+drag / Alt+Shift+arrows column');
  HelpLH = 16;
  HelpSize = 10;

function TPlcUI.HelpCount: Integer;
begin
  if FHelpKind = nkSTL then Result := Length(StlHelp) else Result := Length(SclHelp);
end;

function TPlcUI.HelpLine(I: Integer): string;
begin
  Result := '';
  if (I < 0) or (I >= HelpCount) then Exit;
  if FHelpKind = nkSTL then Result := StlHelp[I] else Result := SclHelp[I];
end;

function TPlcUI.HelpCharW: Single;
begin
  Result := Max(1, TxtW(fkMono, HelpSize, 'M'));
end;

{ the help position under the mouse: (char, line) }
function TPlcUI.HelpPosAt(X, Y: Single): TPoint;
var
  L: Integer;
begin
  L := EnsureRange(Floor((Y - FHelpY0) / HelpLH), 0, HelpCount - 1);
  Result := Point(EnsureRange(Round((X - FHelpX0) / HelpCharW), 0, Length(HelpLine(L))), L);
end;

procedure TPlcUI.HelpOrdered(out A, B: TPoint);
begin
  if (FHelp1.Y < FHelp0.Y) or ((FHelp1.Y = FHelp0.Y) and (FHelp1.X < FHelp0.X)) then
  begin
    A := FHelp1;
    B := FHelp0;
  end
  else
  begin
    A := FHelp0;
    B := FHelp1;
  end;
end;

function TPlcUI.HelpHasSel: Boolean;
begin
  Result := (FHelp0.X <> FHelp1.X) or (FHelp0.Y <> FHelp1.Y);
end;

function TPlcUI.HelpSelText: string;
var
  A, B: TPoint;
  I, C0, C1: Integer;
begin
  Result := '';
  if not HelpHasSel then Exit;
  HelpOrdered(A, B);
  for I := A.Y to B.Y do
  begin
    if I = A.Y then C0 := A.X else C0 := 0;
    if I = B.Y then C1 := B.X else C1 := Length(HelpLine(I));
    if I > A.Y then Result := Result + LineEnding;
    Result := Result + Copy(HelpLine(I), C0 + 1, C1 - C0);
  end;
end;

function TPlcUI.HelpInSel(P: TPoint): Boolean;
var
  A, B: TPoint;
begin
  Result := False;
  if not HelpHasSel then Exit;
  HelpOrdered(A, B);
  Result := ((P.Y > A.Y) or ((P.Y = A.Y) and (P.X >= A.X))) and ((P.Y < B.Y) or ((P.Y = B.Y) and (P.X < B.X)));
end;

procedure TPlcUI.HelpWord(P: TPoint; out A, B: TPoint);
var
  S: string;
  I0, I1: Integer;
begin
  S := HelpLine(P.Y);
  I0 := Min(P.X, Length(S));
  I1 := I0;
  while (I0 > 0) and (S[I0] <> ' ') do Dec(I0);
  while (I1 < Length(S)) and (S[I1 + 1] <> ' ') do Inc(I1);
  A := Point(I0, P.Y);
  B := Point(I1, P.Y);
end;

procedure TPlcUI.HelpCopy;
begin
  if not HelpHasSel then Exit;
  ClipboardOut := HelpSelText;
  Toast('Copied');
end;

procedure TPlcUI.DrawHelp(K: TNetKind; X, Y, W: Single);
var
  I, C0, C1: Integer;
  A, B: TPoint;
  CW, YY, X1: Single;
begin
  if K <> FHelpKind then
  begin
    // another language: its own lines, no selection
    FHelpKind := K;
    FHelp0 := Point(0, 0);
    FHelp1 := FHelp0;
  end;
  FHelpX0 := X;
  FHelpY0 := Y - 1;
  CW := HelpCharW;
  HelpOrdered(A, B);
  for I := 0 to HelpCount - 1 do
  begin
    YY := Y + I * HelpLH;
    if HelpHasSel and (I >= A.Y) and (I <= B.Y) then
    begin
      if I = A.Y then C0 := A.X else C0 := 0;
      if I = B.Y then C1 := B.X else C1 := Length(HelpLine(I));
      X1 := X + C1 * CW;
      if I < B.Y then X1 := X1 + 3;
      D.Layer := lyControls;
      if X1 > X + C0 * CW then Rc(X + C0 * CW, YY - 1, X1 - (X + C0 * CW), HelpLH, Alpha(cGold, 130));
    end;
    D.Layer := lyText;
    TxtFit(fkMono, HelpSize, X, YY, W, HelpLine(I), cInk);
    Hit(X - 4, YY - 1, W + 8, HelpLH, Act(acHelp, I), hkDrag);
  end;
  YY := Y + HelpCount * HelpLH + 6;
  TxtFit(fkUI, 9.5, X, YY, W, 'Drag selects, a double click takes a word.', cInkFaint);
  TxtFit(fkUI, 9.5, X, YY + 13, W, 'Ctrl+C or the right button: Copy.', cInkFaint);
  TxtFit(fkUI, 9.5, X, YY + 26, W, 'Drag the selection into the code.', cInkFaint);
end;

{ the SCL elements in categories that open and close (a click on the title); a double click puts the
  element's code at the caret, a drag into the code where it is dropped; the description of the element
  under the mouse below the list }
procedure TPlcUI.DrawElems(X, Y, W, ViewH: Single; Lang: Char);
var
  I, J, N: Integer;
  Cat: string;
  YY, TY: Single;
  Open, Vis: Boolean;
  Ls: TStringList;

  { the words of S in lines of the width W }
  procedure Wrap(const S: string; Kind: TFontKind; Size: Single);
  var
    Words: TStringArray;
    Par: TStringList;
    K, P: Integer;
    Cur: string;
  begin
    Par := TStringList.Create;
    try
      Par.Text := S;
      for P := 0 to Par.Count - 1 do
      begin
        Words := Par[P].Split(' ');
        Cur := '';
        for K := 0 to High(Words) do
        begin
          if (Cur <> '') and (TxtW(Kind, Size, Cur + ' ' + Words[K]) > W) then
          begin
            Ls.Add(Cur);
            Cur := Words[K];
          end
          else if Cur = '' then Cur := Words[K]
          else Cur := Cur + ' ' + Words[K];
        end;
        Ls.Add(Cur);
      end;
    finally
      Par.Free;
    end;
  end;

begin
  if Lang <> FElemLang then FElemScroll := 0;
  FElemLang := Lang;
  FElemViewH := ViewH;
  case Lang of
    'L': FElems := LadElems(Project, CurBlock);
    'S': FElems := StlElems(Project, CurBlock);
  else
    FElems := SclElems(Project, CurBlock);
  end;
  FElemHover := -1;
  ClipD(X - 4, Y, W + 8, ViewH);
  Hit(X - 4, Y, W + 8, ViewH, whElem, hkWheel);
  YY := Y - FElemScroll;
  Cat := #0;
  Open := False;
  for I := 0 to High(FElems) do
  begin
    if FElems[I].Cat <> Cat then
    begin
      // a category: its title with the number of elements, a click opens / closes it
      Cat := FElems[I].Cat;
      Open := FElemOpen.IndexOf(Lang + Cat) >= 0;
      N := 0;
      J := I;
      while (J <= High(FElems)) and (FElems[J].Cat = Cat) do
      begin
        Inc(N);
        Inc(J);
      end;
      if (YY + ElemCatH > Y) and (YY < Y + ViewH) then
      begin
        if Hot(X - 4, YY, W + 8, ElemCatH) and (FMY >= Y) and (FMY < Y + ViewH) then
        begin
          D.Layer := lyControls;
          Rc(X - 2, YY + 1, W + 4, ElemCatH - 2, Alpha(cGold, 70));
        end;
        D.Layer := lyText;
        if Open then
          PolyD([PointF(X + 1, YY + 7), PointF(X + 9, YY + 7), PointF(X + 5, YY + 12)], cRedDark)
        else
          PolyD([PointF(X + 3, YY + 5), PointF(X + 8, YY + 9.5), PointF(X + 3, YY + 14)], cRedDark);
        if Copy(Cat, 1, Length(ElemProject)) = ElemProject then
          TxtFit(fkUIB, 10, X + 13, YY + 3, W - 14, Format('%s (%d)', [Cat, N]), cJade)
        else
          TxtFit(fkUIB, 10, X + 13, YY + 3, W - 14, Format('%s (%d)', [Cat, N]), cRedDark);
        Hit(X - 4, YY, W + 8, ElemCatH, Act(acElemCat, I), hkClick);
      end;
      YY := YY + ElemCatH;
    end;
    if not Open then Continue;
    Vis := (YY + ElemRowH > Y) and (YY < Y + ViewH);
    if Vis then
    begin
      if Hot(X - 4, YY, W + 8, ElemRowH) and (FMY >= Y) and (FMY < Y + ViewH) and not FVarDragOn then
        FElemHover := I;
      if (FElemHover = I) or (FElemPress = I) then
      begin
        D.Layer := lyControls;
        Rc(X + 8, YY, W - 8, ElemRowH, Alpha(cGold, 110));
      end;
      D.Layer := lyText;
      if (FElems[I].Snip <> '') or (FElems[I].Kind >= 0) then
      begin
        // the grip: the element can be dragged into the code
        for J := 0 to 2 do
        begin
          El(X + 12, YY + 4 + J * 4, 0.9, 0.9, cInkFaint);
          El(X + 15, YY + 4 + J * 4, 0.9, 0.9, cInkFaint);
        end;
        TxtFit(fkMono, 10, X + 20, YY + 2, W - 22, FElems[I].Cap, cInk);
      end
      else
        TxtFit(fkMono, 10, X + 20, YY + 2, W - 22, FElems[I].Cap, cInkSoft);
      Hit(X - 4, YY, W + 8, ElemRowH, Act(acElem, I), hkDrag);
    end;
    YY := YY + ElemRowH;
  end;
  UnclipD;
  FElemH := YY + FElemScroll - Y + 4;
  FElemScroll := EnsureRange(FElemScroll, 0, Max(0, FElemH - ViewH));
  if FElemH > ViewH then VScrollBar(10, X + W + 4, Y, ViewH, FElemH, ViewH, FElemScroll)
  else FVs[10].Range := 0;
  // the description of the element under the mouse
  TY := Y + ViewH + 4;
  D.Layer := lyOrnament;
  Ln(X, TY, X + W, TY, 0.6, Alpha(cGoldDark, 140));
  D.Layer := lyText;
  Ls := TStringList.Create;
  try
    I := FElemHover;
    if I < 0 then I := FElemPress;
    if (I >= 0) and (I <= High(FElems)) then
    begin
      TxtFit(fkMonoB, 10, X, TY + 5, W, FElems[I].Cap, cRedDark);
      Wrap(FElems[I].Descr, fkUI, 9.5);
      for J := 0 to Min(Ls.Count, IfThen(ViewH > 300, 5, 3)) - 1 do TxtFit(fkUI, 9.5, X, TY + 21 + J * 13, W, Ls[J], cInkSoft);
    end
    else
    begin
      TxtFit(fkUI, 9.5, X, TY + 5, W, 'A click on a title opens the category.', cInkFaint);
      if Lang = 'L' then
      begin
        TxtFit(fkUI, 9.5, X, TY + 18, W, 'Double click: into the selected cell.', cInkFaint);
        TxtFit(fkUI, 9.5, X, TY + 31, W, 'Drag by the grip onto a cell.', cInkFaint);
      end
      else
      begin
        TxtFit(fkUI, 9.5, X, TY + 18, W, 'Double click: the code at the caret.', cInkFaint);
        TxtFit(fkUI, 9.5, X, TY + 31, W, 'Drag by the grip into the code.', cInkFaint);
      end;
      if ViewH > 300 then
      begin
        TxtFit(fkUI, 9.5, X, TY + 44, W, 'Right button: Insert / Copy.', cInkFaint);
        TxtFit(fkUI, 9.5, X, TY + 57, W, 'The mouse on an element: what it does.', cInkFaint);
      end;
    end;
  finally
    Ls.Free;
  end;
end;

{ the code of an element into the editor at the caret: its lines indented like the caret's line, the
  caret where the element marks it }
procedure TPlcUI.ElemPut(const Snip: string);
var
  L, Ind, S: string;
  P, R, C, K: Integer;
begin
  L := FEd.Line(FEd.Caret.Row);
  K := 0;
  while (K < Length(L)) and (L[K + 1] = ' ') do Inc(K);
  Ind := StringOfChar(' ', K);
  S := StringReplace(Snip, LineEnding, LineEnding + Ind, [rfReplaceAll]);
  P := Pos(ElemCur, S);
  if P = 0 then
  begin
    FEd.InsertText(S);
    Exit;
  end;
  if P > 1 then FEd.InsertText(Copy(S, 1, P - 1));
  R := FEd.Caret.Row;
  C := FEd.Caret.Col;
  if P < Length(S) then FEd.InsertText(Copy(S, P + 1, MaxInt));
  FEd.Caret := FEd.TP(R, C);
  FEd.Collapse;
  FEd.WantCol := C;
end;

{ ---------- Find Declaration (Alt+Up, Ctrl+Click), the views, .scl sources ---------- }

{ #name: a VAR_TEMP / VAR CONSTANT at the top of a network of the block, or its interface }
function TPlcUI.GotoLocal(const W: string): Boolean;
var
  B: TBlock;
  N: TNetwork;
  I, J, K, P: Integer;
  S, U: string;
  InSec: Boolean;
begin
  Result := False;
  B := CurBlock;
  if B = nil then Exit;
  for I := 0 to B.NetCount - 1 do
  begin
    N := B.Net(I);
    if N.Kind <> nkSCL then Continue;
    InSec := False;
    for J := 0 to N.Stl.Count - 1 do
    begin
      U := UpperCase(Trim(N.Stl[J]));
      if (U = 'VAR_TEMP') or (U = 'VAR CONSTANT') or (U = 'VAR') then
      begin
        InSec := True;
        Continue;
      end;
      if Copy(U, 1, 7) = 'END_VAR' then
      begin
        InSec := False;
        Continue;
      end;
      if not InSec then Continue;
      // "name : Type": the line of the declaration (several in a line: "a : Int; b : Int;")
      S := N.Stl[J];
      for K := 1 to Length(S) - Length(W) + 1 do
        if SameText(Copy(S, K, Length(W)), W) and ((K = 1) or not (S[K - 1] in ['A'..'Z', 'a'..'z', '0'..'9', '_'])) then
        begin
          P := K + Length(W);
          while (P <= Length(S)) and (S[P] = ' ') do Inc(P);
          if (P <= Length(S)) and (S[P] = ':') and ((P = Length(S)) or (S[P + 1] <> '=')) then
          begin
            FocusStl(I, J, K - 1);
            FScrollToCaret := True;
            Toast(Format('#%s: declared in network %d, line %d', [W, I + 1, J + 1]));
            Exit(True);
          end;
        end;
    end;
  end;
  K := B.Iface.FindVar(W);
  // #<FC name>: the Return value
  if (K < 0) and (B.Kind = bkFC) and SameText(W, B.Name) then
    for I := 0 to High(B.Iface.Vars) do
      if B.Iface.Vars[I].Section = vsReturn then K := I;
  if K >= 0 then
  begin
    FIfaceShut := False;
    FIfSel := K;
    FStlNet := -1;
    FProgScroll := 0;
    Toast(Format('#%s: %s of %s (%s)', [W, SectionNames[B.Iface.Vars[K].Section], B.Title,
      B.Iface.Vars[K].TypeText]));
    Exit(True);
  end;
end;

{ "Name": a tag, a DB, a block or a PLC data type }
function TPlcUI.GotoName(const Q: string): Boolean;
var
  K: Integer;
  Db: TDataBlock;
begin
  Result := True;
  K := Project.FindTag(Q);
  if K >= 0 then
  begin
    Screen := scTags;
    FTagSel := K;
    FTagScroll := Max(0, K - 5);
    Toast(Format('"%s": PLC tag %s : %s', [Q, Project.Tags[K].Address, Project.Tags[K].TypeText]));
    Exit;
  end;
  Db := Project.FindDBByName(Q);
  if Db <> nil then
  begin
    Screen := scDB;
    FDBSel := Project.DBs.IndexOf(Db);
    FVarSel := 0;
    FVarScroll := 0;
    Toast(Format('"%s": DB%d', [Q, Db.Number]));
    Exit;
  end;
  for K := 0 to Project.BlockCount - 1 do
    if SameText(Project.Block(K).Name, Q) then
    begin
      Screen := scProgram;
      DoClick(Act(acBlockSel, K), '');
      Toast(Format('"%s": %s', [Q, Project.Block(K).Title]));
      Exit;
    end;
  for K := 0 to Project.UdtCount - 1 do
    if SameText(Project.Udt(K).Name, Q) then
    begin
      ShowDataType(K);
      Toast(Format('"%s": a PLC data type', [Q]));
      Exit;
    end;
  Result := False;
end;

procedure TPlcUI.FindDeclaration;
var
  N: TNetwork;
  L, W, Prev: string;
  C1, C2, K, Nm: Integer;
  Before, After: Char;
  Db: TDataBlock;
  B: TBlock;
begin
  N := CurNet;
  if (N = nil) or not (N.Kind in [nkSCL, nkSTL]) then Exit;
  N := EdBegin;
  if N = nil then Exit;
  L := FEd.Line(FEd.Caret.Row);
  FEd.WordAt(FEd.Caret, C1, C2);
  W := UTF8Copy(L, C1 + 1, C2 - C1);
  if W = '' then
  begin
    Toast('no name at the caret', True);
    Exit;
  end;
  // the characters around the name (the lines are ASCII where names are)
  if C1 >= 1 then Before := UTF8Copy(L, C1, 1)[1] else Before := ' ';
  if C2 < UTF8Length(L) then After := UTF8Copy(L, C2 + 1, 1)[1] else After := ' ';
  if Before = '#' then
  begin
    if not GotoLocal(W) then Toast('#' + W + ' is not declared in ' + CurBlock.Title, True);
    Exit;
  end;
  if Before = '.' then
  begin
    // "DB".Name: the variable of the DB
    Prev := UTF8Copy(L, 1, C1 - 1);
    if (Length(Prev) >= 2) and (Prev[Length(Prev)] = '"') then
    begin
      K := RPos('"', Copy(Prev, 1, Length(Prev) - 1));
      Db := Project.FindDBByName(Copy(Prev, K + 1, Length(Prev) - K - 1));
      if Db <> nil then
      begin
        Db.Layout;
        Screen := scDB;
        FDBSel := Project.DBs.IndexOf(Db);
        FVarSel := Max(0, Db.FindVar(W));
        FVarScroll := Max(0, FVarSel - 5);
        if Db.FindVar(W) >= 0 then
          Toast(Format('"%s".%s: DB%d, %s', [Db.Name, W, Db.Number, Db.Vars[FVarSel].TypeText]))
        else
          Toast(Format('"%s" has no variable %s', [Db.Name, W]), True);
        Exit;
      end;
    end;
    Toast('the declaration of .' + W + ' is in its struct', True);
    Exit;
  end;
  if (Before = '"') and (After = '"') then
  begin
    if not GotoName(W) then Toast('"' + W + '" is not declared in the project', True);
    Exit;
  end;
  // FC2, FB1, DB3, OB1, UDT4
  B := nil;
  if TryStrToInt(Copy(W, 3, MaxInt), Nm) then
  begin
    case UpperCase(Copy(W, 1, 2)) of
      'FC': B := Project.FindBlock(bkFC, Nm);
      'FB': B := Project.FindBlock(bkFB, Nm);
      'OB': B := Project.FindBlock(bkOB, Nm);
      'DB':
        if Project.FindDB(Nm) <> nil then
        begin
          GotoName(Project.FindDB(Nm).Name);
          Exit;
        end;
    end;
    if B <> nil then
    begin
      GotoName(B.Name);
      Exit;
    end;
  end;
  if GotoName(W) then Exit;
  if GotoLocal(W) then Exit;
  Toast(W + ': no declaration (a keyword, a function or an instruction)', True);
end;

procedure TPlcUI.FindDeclarationPublic;
begin
  FindDeclaration;
end;

procedure TPlcUI.SetBlockHead(const AName, AVersion: string);
begin
  if AName <> '' then CommitEdit(Act(fdBlockName, 1), AName);
  if AVersion <> '' then CommitEdit(Act(fdBlockVer, 0), AVersion);
end;

function FileSafe(const S: string): string;
var
  K: Integer;
begin
  Result := S;
  for K := 1 to Length(Result) do
    if Result[K] in ['\', '/', ':', '*', '?', '"', '<', '>', '|'] then Result[K] := '_';
end;

function HtmlE(const S: string): string;
begin
  Result := StringReplace(StringReplace(StringReplace(S, '&', '&amp;', [rfReplaceAll]), '<', '&lt;', [rfReplaceAll]),
    '>', '&gt;', [rfReplaceAll]);
end;

function ViewPage(const Title, Intro: string; const Heads: array of string; Rows: TStringList): string;
var
  K: Integer;
begin
  Result := '<html><head><title>' + HtmlE(Title) + '</title></head><body bgcolor="#FBF7EE">' +
    '<font face="Segoe UI" size="2"><h2><font color="#8B1A1A">' + HtmlE(Title) + '</font></h2><p>' + HtmlE(Intro) +
    '</p><table border="1" cellspacing="0" cellpadding="3" bordercolor="#C9A961"><tr bgcolor="#F2E2C2">';
  for K := 0 to High(Heads) do Result := Result + '<th align="left">' + HtmlE(Heads[K]) + '</th>';
  Result := Result + '</tr>';
  for K := 0 to Rows.Count - 1 do Result := Result + Rows[K];
  Result := Result + '</table></font></body></html>';
end;

function Cells(const A: array of string; Link: Integer; const Url: string): string;
var
  K: Integer;
begin
  Result := '<tr>';
  for K := 0 to High(A) do
    if (K = Link) and (Url <> '') then
      Result := Result + '<td><a href="' + Url + '">' + HtmlE(A[K]) + '</a></td>'
    else
      Result := Result + '<td>' + HtmlE(A[K]) + '&nbsp;</td>';
  Result := Result + '</tr>';
end;

function TPlcUI.AllVarsHtml: string;
var
  Rows: TStringList;
  I, J, K: Integer;
  Db: TDataBlock;
  B: TBlock;
  N: TNetwork;
  Elt, Sec, U: string;
  InSec, Cn: Boolean;
begin
  Rows := TStringList.Create;
  try
    for I := 0 to High(Project.Tags) do
      Rows.Add(Cells(['PLC tags', Project.Tags[I].Name, Project.Tags[I].TypeText, Project.Tags[I].Address, 'Tag', '', '',
        Project.Tags[I].Comment], 1, 'tag:' + Project.Tags[I].Name));
    for I := 0 to Project.DBCount - 1 do
    begin
      Db := Project.DB(I);
      Db.Layout;
      Elt := Format('DB%d "%s"', [Db.Number, Db.Name]);
      for J := 0 to High(Db.Vars) do
        Rows.Add(Cells([Elt, Db.Vars[J].Name, Db.Vars[J].TypeText, Format('%d.%d', [Db.Vars[J].Ofs, Db.Vars[J].Bit]),
          IfThen(Db.InstanceOf > 0, SectionNames[Db.Vars[J].Section], 'Static'), Db.Vars[J].Start,
          IfThen(Db.Vars[J].Retain, 'Retain', ''), Db.Vars[J].Comment], 1, 'db:' + Db.Name + ':' + Db.Vars[J].Name));
    end;
    for I := 0 to Project.UdtCount - 1 do
    begin
      Db := Project.Udt(I);
      Db.Layout;
      for J := 0 to High(Db.Vars) do
        Rows.Add(Cells(['type "' + Db.Name + '"', Db.Vars[J].Name, Db.Vars[J].TypeText, Format('+%d.%d', [Db.Vars[J].Ofs,
          Db.Vars[J].Bit]), 'Member', Db.Vars[J].Start, '', Db.Vars[J].Comment], 0, 'udt:' + Db.Name));
    end;
    for I := 0 to Project.BlockCount - 1 do
    begin
      B := Project.Block(I);
      B.Iface.Layout;
      for J := 0 to High(B.Iface.Vars) do
      begin
        if (B.Iface.Vars[J].Section = vsTemp) or (B.Kind = bkFC) then U := Format('L %d.%d', [B.Iface.Vars[J].Ofs, B.Iface.Vars[J].Bit])
        else U := Format('+%d.%d', [B.Iface.Vars[J].Ofs, B.Iface.Vars[J].Bit]);
        Rows.Add(Cells([B.Title, B.Iface.Vars[J].Name, B.Iface.Vars[J].TypeText, U, SectionNames[B.Iface.Vars[J].Section],
          B.Iface.Vars[J].Start, IfThen(B.Iface.Vars[J].Retain, 'Retain', ''), B.Iface.Vars[J].Comment], 0,
          'block:' + B.Name + ':' + B.Iface.Vars[J].Name));
      end;
      // VAR_TEMP / VAR CONSTANT at the top of the SCL networks
      for K := 0 to B.NetCount - 1 do
      begin
        N := B.Net(K);
        if N.Kind <> nkSCL then Continue;
        InSec := False;
        Cn := False;
        for J := 0 to N.Stl.Count - 1 do
        begin
          U := UpperCase(Trim(N.Stl[J]));
          if (U = 'VAR_TEMP') or (U = 'VAR CONSTANT') or (U = 'VAR') then
          begin
            InSec := True;
            Cn := U = 'VAR CONSTANT';
            Continue;
          end;
          if Copy(U, 1, 7) = 'END_VAR' then
          begin
            InSec := False;
            Continue;
          end;
          if not InSec or (Pos(':', N.Stl[J]) = 0) then Continue;
          if Cn then Sec := 'Constant' else Sec := 'Temp';
          Elt := Trim(Copy(N.Stl[J], Pos(':', N.Stl[J]) + 1, MaxInt));
          if Pos(';', Elt) > 0 then Elt := Copy(Elt, 1, Pos(';', Elt) - 1);
          Rows.Add(Cells([B.Title, Trim(Copy(N.Stl[J], 1, Pos(':', N.Stl[J]) - 1)), Trim(Elt), Format('network %d', [K + 1]),
            Sec, '', '', ''], 0, 'block:' + B.Name + ':'));
        end;
      end;
    end;
    Result := ViewPage('All variables', Format('Every variable of the project %s: the PLC tags, the data blocks, the ' +
      'PLC data types and the interfaces of the blocks (also the VAR_TEMP / VAR CONSTANT of the SCL networks). ' +
      'A click on a name opens it.', [Project.Name]),
      ['Element', 'Variable', 'Data type', 'Address / offset', 'Section', 'Start value', 'Retain', 'Comment'], Rows);
  finally
    Rows.Free;
  end;
end;

{ the elements a block uses: the quoted names in its networks (calls, instance DBs, DBs, types) }
function UsesOf(P: TPlcProject; B: TBlock): TStringList;
var
  I, J, K: Integer;
  N: TNetwork;
  S: string;

  procedure Look(const Nm: string; const Disp: string);
  begin
    if (Nm <> '') and (Pos('"' + UpperCase(Nm) + '"', S) > 0) and (Result.IndexOf(Disp) < 0) then Result.Add(Disp);
  end;

begin
  Result := TStringList.Create;
  S := '';
  for I := 0 to B.NetCount - 1 do
  begin
    N := B.Net(I);
    S := S + UpperCase(N.Stl.Text);
    for J := 0 to N.Rows - 1 do
      for K := 0 to N.Cols - 1 do S := S + UpperCase(N.Cell(J, K).Opnd) + ' ';
  end;
  for I := 0 to High(B.Iface.Vars) do S := S + UpperCase(B.Iface.Vars[I].TypeText) + ' ';
  for I := 0 to P.BlockCount - 1 do
    if P.Block(I) <> B then
    begin
      Look(P.Block(I).Name, P.Block(I).Title);
      if Pos(UpperCase(Format('%s%d', [Copy(P.Block(I).Title, 1, 2), P.Block(I).Number])) + ' ', S + ' ') > 0 then ;
    end;
  for I := 0 to P.DBCount - 1 do Look(P.DB(I).Name, Format('DB%d "%s"', [P.DB(I).Number, P.DB(I).Name]));
  for I := 0 to P.UdtCount - 1 do Look(P.Udt(I).Name, '"' + P.Udt(I).Name + '"');
end;

function JoinList(L: TStrings): string;
var
  K: Integer;
begin
  Result := '';
  for K := 0 to L.Count - 1 do
  begin
    if K > 0 then Result := Result + ', ';
    Result := Result + L[K];
  end;
end;

function TPlcUI.AllElemsHtml: string;
var
  Rows: TStringList;
  Us: array of TStringList;
  I, J, NL, NS, NC: Integer;
  B: TBlock;
  Db: TDataBlock;
  By, Lang: string;

  function UsedBy(const Disp: string): string;
  var
    K: Integer;
  begin
    Result := '';
    for K := 0 to Project.BlockCount - 1 do
      if Us[K].IndexOf(Disp) >= 0 then
      begin
        if Result <> '' then Result := Result + ', ';
        Result := Result + Project.Block(K).Title;
      end;
  end;

begin
  Rows := TStringList.Create;
  SetLength(Us, Project.BlockCount);
  try
    for I := 0 to Project.BlockCount - 1 do Us[I] := UsesOf(Project, Project.Block(I));
    Rows.Add(Cells(['Tag table', '', 'PLC tags', '', Format('%d tags', [Length(Project.Tags)]), '', '', ''], 2, 'tags:'));
    for I := 0 to Project.BlockCount - 1 do
    begin
      B := Project.Block(I);
      B.Iface.Layout;
      NL := 0;
      NS := 0;
      NC := 0;
      for J := 0 to B.NetCount - 1 do
        case B.Net(J).Kind of
          nkLAD: Inc(NL);
          nkSTL: Inc(NS);
        else
          Inc(NC);
        end;
      Lang := '';
      if NL > 0 then Lang := Lang + Format('%d LAD ', [NL]);
      if NS > 0 then Lang := Lang + Format('%d STL ', [NS]);
      if NC > 0 then Lang := Lang + Format('%d SCL', [NC]);
      By := UsedBy(B.Title);
      Rows.Add(Cells([Copy(B.Title, 1, 2), IntToStr(B.Number), B.Name, Trim(Lang),
        IfThen(B.Kind = bkFB, Format('%d (instance)', [B.Iface.Size]), Format('%d (local)', [B.Iface.TempSize])),
        JoinList(Us[I]), By, B.Comment], 2, 'block:' + B.Name + ':'));
    end;
    for I := 0 to Project.DBCount - 1 do
    begin
      Db := Project.DB(I);
      Db.Layout;
      By := UsedBy(Format('DB%d "%s"', [Db.Number, Db.Name]));
      if Db.InstanceOf > 0 then Lang := Format('instance of FB%d', [Db.InstanceOf]) else Lang := IfThen(Db.Optimized, 'optimized', 'standard');
      Rows.Add(Cells(['DB', IntToStr(Db.Number), Db.Name, Lang, IntToStr(Db.Size), '', By, Db.Comment], 2, 'db:' + Db.Name + ':'));
    end;
    for I := 0 to Project.UdtCount - 1 do
    begin
      Db := Project.Udt(I);
      Db.Layout;
      Rows.Add(Cells(['UDT', IntToStr(Db.Number), Db.Name, Format('%d members', [Length(Db.Vars)]), IntToStr(Db.Size), '',
        UsedBy('"' + Db.Name + '"'), Db.Comment], 2, 'udt:' + Db.Name));
    end;
    Result := ViewPage('All elements', Format('Every element of the project %s: the blocks with their languages, the ' +
      'data blocks and the PLC data types, their sizes, what they use and who uses them. A click on a name opens it.',
      [Project.Name]), ['Type', 'Number', 'Name', 'Language / kind', 'Data size (bytes)', 'Uses / calls', 'Used by',
      'Comment'], Rows);
  finally
    for I := 0 to High(Us) do Us[I].Free;
    Rows.Free;
  end;
end;

procedure TPlcUI.ShowView(Kind: Integer);
var
  Ttl, Html: string;
begin
  if Kind = 0 then
  begin
    Ttl := 'Virtual PLC - All variables';
    Html := AllVarsHtml;
  end
  else
  begin
    Ttl := 'Virtual PLC - All elements';
    Html := AllElemsHtml;
  end;
  if FViewForm = nil then
  begin
    FViewForm := THelpForm.CreateHelp(nil, Ttl, Html);
    FViewForm.OnPdf := @HelpPdf;
    FViewForm.OnLink := @ViewLink;
  end
  else
  begin
    FViewForm.Caption := Ttl;
    FViewForm.SetPage(Html);
  end;
  FViewKind := Kind;
  FViewForm.Show;
  FViewForm.BringToFront;
end;

procedure TPlcUI.ShowViewPublic(Kind: Integer);
begin
  ShowView(Kind);
end;

{ a link of the views: tag:Name, db:Name:Var, block:Name:Var, udt:Name, tags: }
procedure TPlcUI.ViewLink(Sender: TObject; const URL: string);
var
  Kind, A, B: string;
  P, K: Integer;
  Db: TDataBlock;
  Bk: TBlock;
begin
  P := Pos(':', URL);
  Kind := Copy(URL, 1, P - 1);
  A := Copy(URL, P + 1, MaxInt);
  B := '';
  P := Pos(':', A);
  if P > 0 then
  begin
    B := Copy(A, P + 1, MaxInt);
    A := Copy(A, 1, P - 1);
  end;
  case Kind of
    'tags': Screen := scTags;
    'tag': GotoName(A);
    'udt': GotoName(A);
    'db':
      begin
        Db := Project.FindDBByName(A);
        if Db <> nil then
        begin
          GotoName(A);
          if B <> '' then FVarSel := Max(0, Db.FindVar(B));
          FVarScroll := Max(0, FVarSel - 5);
        end;
      end;
    'block':
      for K := 0 to Project.BlockCount - 1 do
        if SameText(Project.Block(K).Name, A) then
        begin
          Bk := Project.Block(K);
          GotoName(A);
          if (B <> '') and (Bk.Iface.FindVar(B) >= 0) then
          begin
            FIfaceShut := False;
            FIfSel := Bk.Iface.FindVar(B);
          end;
          Break;
        end;
  end;
end;

function TPlcUI.ImportSclFile(const FileName: string; DataOnly: Boolean): string;
var
  SL: TStringList;
begin
  SL := TStringList.Create;
  try
    SL.LoadFromFile(FileName);
    if SclImport(Project, SL.Text, Result, DataOnly) then
    begin
      ResetResolver;
      MarkDirty;
      FBlockSel := Min(FBlockSel, Project.BlockCount - 1);
    end;
  finally
    SL.Free;
  end;
end;

function TPlcUI.ExportSclFile(const FileName: string; All: Boolean): string;
var
  SL: TStringList;
  Sk: Integer;
begin
  SL := TStringList.Create;
  try
    if All then SL.Text := SclExportAll(Project, Result)
    else if CurBlock <> nil then
    begin
      SL.Text := SclExportBlock(Project, CurBlock, Sk);
      Result := CurBlock.Title;
      if Sk > 0 then Result := Result + Format('; %d LAD / STL networks have no SCL text (left out)', [Sk]);
    end
    else
      Exit('no block');
    SL.WriteBOM := False;
    SL.SaveToFile(FileName);
  finally
    SL.Free;
  end;
end;

procedure TPlcUI.SclSourceMenu(Par: Integer);
var
  Od: TOpenDialog;
  Sd: TSaveDialog;
  R: string;
begin
  case Par of
    0:
      begin
        Od := TOpenDialog.Create(nil);
        try
          Od.Title := 'Import an SCL source (TIA Portal .scl)';
          Od.Filter := 'SCL sources (*.scl)|*.scl|All files (*.*)|*.*';
          if not Od.Execute then Exit;
          R := ImportSclFile(Od.FileName);
          Toast(R, Pos('error', R) > 0);
        finally
          Od.Free;
        end;
      end;
    1, 2:
      begin
        if (Par = 1) and (CurBlock = nil) then Exit;
        Sd := TSaveDialog.Create(nil);
        try
          Sd.Title := 'Export as an SCL source (TIA Portal .scl)';
          Sd.Filter := 'SCL sources (*.scl)|*.scl';
          Sd.DefaultExt := 'scl';
          Sd.Options := Sd.Options + [ofOverwritePrompt];
          if Par = 1 then Sd.FileName := FileSafe(CurBlock.Name) + '.scl'
          else Sd.FileName := FileSafe(Project.Name) + '.scl';
          if not Sd.Execute then Exit;
          R := ExportSclFile(Sd.FileName, Par = 2);
          Toast('Exported: ' + R);
        finally
          Sd.Free;
        end;
      end;
    3: ShowView(0);
    4: ShowView(1);
  end;
end;

{ the Data blocks screen: 0 import the TYPEs and DATA_BLOCKs of an .scl source, 1 export the selected DB / type }
procedure TPlcUI.DbSclMenu(Par: Integer);
var
  Od: TOpenDialog;
  Sd: TSaveDialog;
  R: string;
  SL: TStringList;
begin
  if Par = 0 then
  begin
    Od := TOpenDialog.Create(nil);
    try
      Od.Title := 'Import PLC data types and data blocks (TIA Portal .scl / .udt / .db)';
      Od.Filter := 'SCL sources (*.scl;*.udt;*.db)|*.scl;*.udt;*.db|All files (*.*)|*.*';
      if not Od.Execute then Exit;
      R := ImportSclFile(Od.FileName, True);
      Toast(R, Pos('error', R) + Pos('no TYPE', R) > 0);
    finally
      Od.Free;
    end;
    Exit;
  end;
  if CurDB = nil then Exit;
  Sd := TSaveDialog.Create(nil);
  SL := TStringList.Create;
  try
    Sd.Title := 'Export as an SCL source (TIA Portal)';
    if CurDB.IsUdt then
    begin
      Sd.Filter := 'PLC data type (*.udt)|*.udt|SCL sources (*.scl)|*.scl';
      Sd.DefaultExt := 'udt';
      SL.Text := SclExportUdt(CurDB);
    end
    else
    begin
      Sd.Filter := 'Data block (*.db)|*.db|SCL sources (*.scl)|*.scl';
      Sd.DefaultExt := 'db';
      SL.Text := SclExportDB(Project, CurDB);
    end;
    Sd.Options := Sd.Options + [ofOverwritePrompt];
    Sd.FileName := FileSafe(CurDB.Name) + '.' + Sd.DefaultExt;
    if not Sd.Execute then Exit;
    SL.WriteBOM := False;
    SL.SaveToFile(Sd.FileName, TEncoding.UTF8);
    Toast('Exported: ' + ExtractFileName(Sd.FileName));
  finally
    SL.Free;
    Sd.Free;
  end;
end;

procedure TPlcUI.ElemInsert(K: Integer);
var
  N: TNetwork;
  Ce: TLadCell;
begin
  if (K < 0) or (K > High(FElems)) then Exit;
  N := CurNet;
  if (N <> nil) and (N.Kind = nkLAD) and (FElemLang = 'L') then
  begin
    // LAD: an element into the selected cell (a CALL with its block), a name as the operand of the element
    if FElems[K].Kind >= 0 then
    begin
      DoClick(Act(acPal, FElems[K].Kind), '');
      if FElems[K].Snip <> '' then
      begin
        Ce := N.Cell(FCellR, FCellC);
        Ce.Opnd := FElems[K].Snip;
        N.SetCell(FCellR, FCellC, Ce);
        MarkDirty;
      end;
    end
    else if FElems[K].Snip <> '' then
    begin
      Ce := N.Cell(FCellR, FCellC);
      if LadOpndName(Ce.Kind) = '' then
      begin
        Toast('the selected element has no operand: select a contact, a coil or a box', True);
        Exit;
      end;
      Ce.Opnd := ElemText(FElems[K].Snip);
      N.SetCell(FCellR, FCellC, Ce);
      MarkDirty;
    end;
    Exit;
  end;
  if FElems[K].Snip = '' then Exit;
  if (N = nil) or not (N.Kind in [nkSCL, nkSTL]) then
  begin
    Toast('select a text network first', True);
    Exit;
  end;
  FStlNet := FNetSel;
  N := EdBegin;
  if N = nil then Exit;
  EdUndoPoint(N, 0);
  ElemPut(FElems[K].Snip);
  EdEnd(N);
  FScrollToCaret := True;
end;

{ the drop place under the mouse while a name or a piece of help text is dragged }
procedure TPlcUI.DropTrack(X, Y: Single; Lad: Boolean);
var
  Hd: THit;
  CharW: Single;
begin
  if Y > 836 then FProgScroll := FProgScroll + 12;
  if Y < 160 then FProgScroll := FProgScroll - 12;
  // the place under the mouse: a text line, or a LAD element with an operand
  FDropKind := 0;
  if (CurBlock = nil) or not HitAt(X, Y, Hd) then Exit;
  if Hd.Id shr 16 = acStlLine then
  begin
    CharW := Max(1, TxtW(fkMono, 13, 'M'));
    FDropKind := 1;
    FDropNet := (Hd.Id and $FFFF) div 1024;
    FDropRow := (Hd.Id and $FFFF) mod 1024;
    FDropCol := Max(0, Round((X - (Hd.R.Left + 44)) / CharW));
    if (FDropNet < CurBlock.NetCount) and (FDropRow < CurBlock.Net(FDropNet).Stl.Count) then
      FDropCol := Min(FDropCol, UTF8Length(CurBlock.Net(FDropNet).Stl[FDropRow]))
    else
      FDropCol := 0;
    FDropX := Hd.R.Left + 44 + FDropCol * CharW;
    FDropY := Hd.R.Top + 2;
  end
  else if Lad and (Hd.Id shr 16 = acCell) then
  begin
    FDropNet := (Hd.Id and $FFFF) div 256;
    if FDropNet < CurBlock.NetCount then
    begin
      FDropRow := ((Hd.Id and $FFFF) mod 256) div CurBlock.Net(FDropNet).Cols;
      FDropCol := ((Hd.Id and $FFFF) mod 256) mod CurBlock.Net(FDropNet).Cols;
    end;
    if FDropCell and (FDropNet < CurBlock.NetCount) then
    begin
      // an element of the list onto any cell
      FDropKind := 3;
      FDropX := Hd.R.Left + 2;
      FDropY := Hd.R.Top + 2;
      FDropW := Hd.R.Right - Hd.R.Left - 4;
      FDropH := Hd.R.Bottom - Hd.R.Top - 4;
    end
    else if (FDropNet < CurBlock.NetCount) and (LadOpndName(CurBlock.Net(FDropNet).Cell(FDropRow, FDropCol).Kind) <> '') then
    begin
      FDropKind := 2;
      FDropX := Hd.R.Left + 2;
      FDropY := Hd.R.Top + 2;
      FDropW := Hd.R.Right - Hd.R.Left - 4;
      FDropH := Hd.R.Bottom - Hd.R.Top - 4;
    end;
  end;
end;

{ a vertical scroll bar: the track, the thumb (Pos of Range, View in sight), its region; DoDrag
  moves it }
procedure TPlcUI.VScrollBar(Bar: Integer; X, Top, H, Range, View, Pos: Single);
var
  TT, TH: Single;
  On: Boolean;
begin
  FVs[Bar].X := X;
  FVs[Bar].Top := Top;
  FVs[Bar].H := H;
  FVs[Bar].Range := Range;
  FVs[Bar].View := View;
  TH := EnsureRange(H * View / Max(1, Range), 24, H);
  TT := Top + EnsureRange(Pos / Max(1, Range - View), 0, 1) * (H - TH);
  On := (FVsDrag = Bar) or Hot(X - 3, TT, 14, TH);
  D.Layer := lyControls;
  RR(X + 1, Top, 6, H, 3, Alpha(cSheetDark, 200));
  if On then RR(X, TT, 8, TH, 4, cRedDark) else RR(X + 1, TT, 6, TH, 3, cRed);
  Hit(X - 4, Top, 16, H, Act(acVScroll, Bar), hkDrag);
end;

function TPlcUI.VsPos(Bar: Integer): Single;
begin
  case Bar of
    0: Result := FProgScroll;
    1: Result := FMsgScroll;
    2: Result := FBlockScroll;
    3: Result := FTagScroll;
    4: Result := FDBListScroll;
    5: Result := FVarScroll;
    6: Result := FWatchScroll;
    7: Result := FFileScroll;
    9: Result := FExScroll;
    10: Result := FElemScroll;
    11..15: Result := FIoScroll[Bar - 11];
    16, 17: Result := FGrpScroll[Bar - 16];
  else
    Result := FPalScroll;
  end;
end;

procedure TPlcUI.SetVsPos(Bar: Integer; V: Single);
begin
  V := EnsureRange(V, 0, Max(0, FVs[Bar].Range - FVs[Bar].View));
  case Bar of
    0:
      begin
        FProgScroll := V;
        FScrollToCaret := False;
      end;
    1: FMsgScroll := V;
    2: FBlockScroll := V;
    3: FTagScroll := V;
    4: FDBListScroll := V;
    5: FVarScroll := V;
    6: FWatchScroll := V;
    7: FFileScroll := V;
    9: FExScroll := V;
    10: FElemScroll := V;
    11..15: FIoScroll[Bar - 11] := V;
    16, 17: FGrpScroll[Bar - 16] := V;
  else
    FPalScroll := V;
  end;
end;

function TPlcUI.VScrollPoint(Bar: Integer; Frac: Single): TPointF;
begin
  Result := DesignToPixel(FVs[Bar].X + 4, FVs[Bar].Top + Frac * FVs[Bar].H);
end;

function TPlcUI.TagError(I: Integer): string;
begin
  CheckTags;
  if (I >= 0) and (I <= High(FTagErr)) then Result := FTagErr[I] else Result := '';
end;

function TPlcUI.CaretInView(out Info: string): Boolean;
var
  Y0, Y1: Single;
  P: TPointF;
begin
  // the editor frame: 150 .. 850 (design units)
  if (CurNet <> nil) and (CurNet.Kind = nkLAD) and (FStlNet < 0) then
  begin
    P := CellPoint(FNetSel, FCellR, FCellC);
    if (FNetSel < Length(FLadTops)) and (FCellR + 1 <= High(FLadTops[FNetSel])) then
    begin
      Y0 := FLadTops[FNetSel][FCellR];
      Y1 := FLadTops[FNetSel][FCellR + 1];
    end
    else
    begin
      Y0 := -1;
      Y1 := -1;
    end;
    Info := Format('LAD net %d row %d col %d: cell %.0f..%.0f', [FNetSel + 1, FCellR + 1, FCellC + 1, Y0, Y1]);
  end
  else
  begin
    Y0 := FCaretY;
    Y1 := FCaretY + 19;
    Info := Format('text net %d line %d: caret %.0f..%.0f', [FNetSel + 1, FStlRow + 1, Y0, Y1]);
  end;
  Result := (Y0 >= 150) and (Y1 <= 850);
  if P.X = 0 then ;
end;

function TPlcUI.SaveAsText: string;
begin
  Result := FSaveAsName;
end;

procedure TPlcUI.TestMessages(N: Integer);
var
  K: Integer;
begin
  SetLength(FMsgs, N);
  for K := 0 to N - 1 do
  begin
    FMsgs[K].Block := 'OB1';
    FMsgs[K].Net := K + 1;
    FMsgs[K].Line := 1;
    FMsgs[K].Text := Format('message %d (a test of the scroll bar)', [K + 1]);
    FMsgs[K].IsError := Odd(K);
  end;
  FMsgErrors := N div 2;
  FMsgScroll := 0;
end;

function TPlcUI.VScrollPos(Bar: Integer): Single;
begin
  Result := VsPos(Bar);
end;

function TPlcUI.HelpPoint(Line, Ch: Integer): TPointF;
begin
  Result := DesignToPixel(FHelpX0 + Ch * HelpCharW, FHelpY0 + Line * HelpLH + HelpLH / 2);
end;

function TPlcUI.CurBlockPublic: TBlock;
begin
  Result := CurBlock;
end;

function TPlcUI.ElemFind(const Cap: string; IsCat: Boolean): Integer;
var
  I: Integer;
  Cat: string;
  YY: Single;
begin
  Result := -1;
  YY := 0;
  Cat := #0;
  for I := 0 to High(FElems) do
  begin
    if FElems[I].Cat <> Cat then
    begin
      Cat := FElems[I].Cat;
      if IsCat and (Cat = Cap) then
      begin
        Result := I;
        Break;
      end;
      YY := YY + ElemCatH;
    end;
    if FElemOpen.IndexOf(FElemLang + Cat) < 0 then Continue;
    if not IsCat and (FElems[I].Cap = Cap) then
    begin
      Result := I;
      Break;
    end;
    YY := YY + ElemRowH;
  end;
  // into the view, a few rows from the top
  if Result >= 0 then FElemScroll := Max(0, Min(FElemScroll, YY - 40)) else Exit;
  if YY - FElemScroll > FElemViewH - 40 then FElemScroll := YY - FElemViewH + 60;
end;

function TPlcUI.ElemSnippet(I: Integer): string;
begin
  Result := '';
  if (I >= 0) and (I <= High(FElems)) then Result := ElemText(FElems[I].Snip);
end;

function TPlcUI.HelpSelection: string;
begin
  Result := HelpSelText;
end;

procedure TPlcUI.DrawProps(X, Y, W, H: Single);
var
  CallB: TBlock;
  Pins: TIntArray;
  N: TNetwork;
  Ce: TLadCell;
  I: Integer;
  YY: Single;
  O: TOperand;
  E: string;
begin
  N := CurNet;
  D.Layer := lyText;
  if N = nil then Exit;
  if N.Kind in [nkSCL, nkSTL] then
  begin
    // the language help: text to select, copy and drag into the code
    if N.Kind = nkSCL then
    begin
      // SCL: the elements of SCL Studio and of the project
      Txt(fkUIB, 12, X, Y, 'SCL elements', cRedDark);
      DrawElems(X, Y + 22, W, ElemViewH, 'C');
      Exit;
    end;
    Txt(fkUIB, 12, X, Y, 'STL elements', cRedDark);
    DrawElems(X, Y + 22, W, ElemViewH, 'S');
    Exit;
  end;
  Ce := N.Cell(FCellR, FCellC);
  Txt(fkUIB, 12, X, Y, Format('Row %d  column %d', [FCellR + 1, FCellC + 1]), cRedDark);
  if Ce.Kind = lkEmpty then
  begin
    Txt(fkUI, 11, X, Y + 20, 'empty: pick an element above', cInkSoft);
    YY := Y + 40;
  end
  else
  begin
    Txt(fkUIB, 12, X, Y + 20, LadKindNames[Ce.Kind], cInk);
    YY := Y + 40;
    if LadOpndName(Ce.Kind) <> '' then
    begin
      Txt(fkUI, 10, X, YY, LadOpndName(Ce.Kind), cInkSoft);
      Field(X, YY + 14, W, 22, Act(fdOpnd, 0), Ce.Opnd, fkMono, 12);
      if Ce.Kind = lkCall then
      begin
        if CallBlockOf(Ce.Opnd) <> nil then
          TxtFit(fkUI, 9.5, X, YY + 38, W, CallBlockOf(Ce.Opnd).Title + '  "' + CallBlockOf(Ce.Opnd).Name + '"', cInkSoft)
        else if Ce.Opnd <> '' then
          TxtFit(fkUI, 9.5, X, YY + 38, W, 'no FC / FB instance DB ' + Ce.Opnd, cRed);
      end
      else if (Ce.Opnd <> '') and not FRes.Resolve(Ce.Opnd, O, E, False) then
        TxtFit(fkUI, 9.5, X, YY + 38, W, E, cRed)
      else if (Ce.Opnd <> '') and (O.Kind = okAddr) then
        TxtFit(fkMono, 9.5, X, YY + 38, W, FormatAddr(O.A, Project.Family) + '  ' + DataTypeNames[O.DType], cInkSoft);
      YY := YY + 54;
    end;
    for I := 0 to LadParamCount(Ce.Kind) - 1 do
    begin
      Txt(fkUI, 10, X, YY, LadParamName(Ce.Kind, I), cInkSoft);
      Field(X + 70, YY - 3, W - 70, 22, Act(fdPar, I), Ce.P[I], fkMono, 12);
      YY := YY + 26;
    end;
    if Ce.Kind = lkCall then
    begin
      CallB := CallBlockOf(Ce.Opnd);
      if CallB = nil then
      begin
        TxtFit(fkUI, 10, X, YY, W, 'FCn / "FC name", or an instance DB of an FB', cInkFaint);
        YY := YY + 20;
      end
      else
      begin
        Pins := CallPins(CallB);
        if Length(Pins) = 0 then
        begin
          TxtFit(fkUI, 10, X, YY, W, CallB.Title + ': no parameters', cInkFaint);
          YY := YY + 20;
        end;
        for I := 0 to High(Pins) do
        begin
          TxtFit(fkUI, 9.5, X, YY - 2, 66, CallB.Iface.Vars[Pins[I]].Name, cInkSoft);
          TxtFit(fkUI, 7.5, X, YY + 8, 66, SectionNames[CallB.Iface.Vars[Pins[I]].Section] + ' ' +
            CallB.Iface.Vars[Pins[I]].TypeText, cInkFaint);
          Field(X + 70, YY - 3, W - 70, 20, Act(fdCallArg, I), CallArg(Ce, I), fkMono, 11.5);
          YY := YY + 21;
        end;
      end;
    end;
    if LadHasType(Ce.Kind) then
    begin
      // the data types: a list each (a converter: the IN and the OUT type)
      if Ce.Kind in [lkRound, lkTrunc, lkCeil, lkFloor] then
        Button(X, YY, (W - 6) / 2, 24, 'IN Real', Act(acDType, 0), bsFlat, False, 11)
      else if LadHasType2(Ce.Kind) then
        Button(X, YY, (W - 6) / 2, 24, 'IN ' + DataTypeNames[Ce.DType] + ' ▼', Act(acDType, 0), bsGold, True, 11)
      else
        Button(X, YY, (W - 6) / 2, 24, 'type ' + DataTypeNames[Ce.DType] + ' ▼', Act(acDType, 0), bsGold, True, 11);
      if LadHasType2(Ce.Kind) then
        Button(X + (W + 6) / 2, YY, (W - 6) / 2, 24, 'OUT ' + DataTypeNames[Ce.DType2] + ' ▼', Act(acDType2, 0), bsGold,
          True, 11)
      else if Ce.Kind = lkCmp then
        Button(X + (W + 6) / 2, YY, (W - 6) / 2, 24, 'compare ' + CmpOpNames[Ce.Cmp], Act(acCmpOp, 0), bsGold, True, 11);
      YY := YY + 30;
    end;
  end;
  // one row: the panel keeps room for the pins of a CALL box
  Button(X, YY, (W - 15) / 4, 24, IfThen(Ce.Down, 'Branch', 'Branch ↓'), Act(acBranch, 0),
    TBtnStyle(IfThen(Ce.Down, Ord(bsToggleOn), Ord(bsNormal))), FCellR + 1 < N.Rows, 10);
  Button(X + (W + 5) / 4, YY, (W - 15) / 4, 24, 'Delete', Act(acCellDel, 0), bsNormal, Ce.Kind <> lkEmpty, 10);
  Button(X + (W + 5) / 2, YY, (W - 15) / 4, 24, '+ Row', Act(acRowIns, 0), bsNormal, N.Rows < MaxLadRows, 10);
  Button(X + 3 * (W + 5) / 4, YY, (W - 15) / 4, 24, '- Row', Act(acRowDel, 0), bsNormal, N.Rows > 1, 10);
end;

{ ---------- the FB interface (Input, Output, InOut, Static, Temp) ---------- }

function TPlcUI.IfaceHeight(B: TBlock): Single;
begin
  if B.Kind = bkOB then Exit(0);
  if FIfaceShut then Exit(48);
  if Length(B.Iface.Vars) = 0 then Exit(48 + 38);
  Result := 48 + 22 + Length(B.Iface.Vars) * 26 + 44;
end;

function TPlcUI.FirstInstance(B: TBlock): TDataBlock;
var
  I: Integer;
begin
  for I := 0 to Project.DBCount - 1 do
    if (Project.DB(I).InstanceOf = B.Number) and (B.Kind = bkFB) then Exit(Project.DB(I));
  Result := nil;
end;

procedure TPlcUI.DrawIface(B: TBlock; X, Y, W: Single);
const
  SecBtn: array[TVarSection] of TBtnStyle = (bsToggleOn, bsGold, bsPrimary, bsNormal, bsFlat, bsDanger);
var
  I, K, NSec: Integer;
  H, RY, CX: Single;
  V: TDbVar;
  Inst: TDataBlock;
  S, E, Live: string;
  O: TOperand;
  Sc: TVarSection;
  Cnt: array[TVarSection] of Integer;
begin
  H := IfaceHeight(B);
  B.Iface.Name := B.Name;
  B.Iface.Number := B.Number;
  B.Iface.Layout;
  Inst := FirstInstance(B);
  D.Layer := lySheets;
  Shad(X, Y, W, H - 8, 6, 2, 5, 60);
  RR(X, Y, W, H - 8, 6, Mixc(cSheet, cGoldLight, 0.18));
  D.Layer := lyOrnament;
  RRL(X + 0.5, Y + 0.5, W - 1, H - 9, 6, 1.2, cGoldDark);
  Rc(X + 1, Y + 1, 5, H - 10, Alpha(cGoldDark, 200));
  D.Layer := lyText;
  Txt(fkUIB, 13, X + 14, Y + 8, 'Interface', cRedDark);
  for Sc := Low(TVarSection) to High(TVarSection) do Cnt[Sc] := 0;
  for I := 0 to High(B.Iface.Vars) do Inc(Cnt[B.Iface.Vars[I].Section]);
  S := '';
  for Sc := Low(TVarSection) to High(TVarSection) do
    if Cnt[Sc] > 0 then S := S + Format('%d %s, ', [Cnt[Sc], SectionNames[Sc]]);
  if B.Kind = bkFC then
    S := S + Format('local data %d bytes (parameters and Temp)', [B.Iface.TempSize])
  else
  begin
    S := S + Format('instance %d bytes', [B.Iface.Size]);
    if B.Iface.TempSize > 0 then S := S + Format(', Temp %d bytes', [B.Iface.TempSize]);
    if Inst <> nil then S := S + Format('   monitor: DB%d "%s"', [Inst.Number, Inst.Name])
    else S := S + '   no instance DB yet';
  end;
  TxtFit(fkUI, 11, X + 100, Y + 11, W - 420, S, cInkSoft);
  if B.Kind = bkFB then Button(X + W - 300, Y + 6, 130, 24, '+ Instance DB', Act(acIfInst, 0), bsNormal, True, 11);
  if FIfaceShut then Button(X + W - 160, Y + 6, 148, 24, 'Show interface', Act(acIfToggle, 0), bsGold, True, 11)
  else Button(X + W - 160, Y + 6, 148, 24, 'Hide interface', Act(acIfToggle, 0), bsNormal, True, 11);
  if FIfaceShut then Exit;
  // column heads
  RY := Y + 42;
  if Length(B.Iface.Vars) = 0 then RY := Y - 1000;   // nothing yet: only the add buttons
  Txt(fkUIB, 10.5, X + 16, RY, 'Section', cInkSoft);
  Txt(fkUIB, 10.5, X + 102, RY, 'Name', cInkSoft);
  Txt(fkUIB, 10.5, X + 272, RY, 'Data type', cInkSoft);
  Txt(fkUIB, 10.5, X + 468, RY, 'Default', cInkSoft);
  Txt(fkUIB, 10.5, X + 594, RY, 'Offset', cInkSoft);
  if B.Kind = bkFB then Txt(fkUIB, 10.5, X + 652, RY, 'Monitor value', cInkSoft);
  Txt(fkUIB, 10.5, X + 830, RY, 'Comment', cInkSoft);

  FIfSel := EnsureRange(FIfSel, 0, Max(0, High(B.Iface.Vars)));
  for I := 0 to High(B.Iface.Vars) do
  begin
    V := B.Iface.Vars[I];
    RY := Y + 64 + I * 26;
    D.Layer := lyControls;
    if I = FIfSel then RR(X + 10, RY - 2, W - 20, 25, 4, Alpha(cGold, 70))
    else if Odd(I) then Rc(X + 10, RY - 2, W - 20, 25, Alpha(cSheet2, 120));
    Hit(X + 10, RY - 2, W - 20, 25, Act(acIfDrag, I), hkDrag);
    // the grip: drag the row into the code (#Name)
    if I = 0 then
    begin
      FIfGripX := X + 17;
      FIfGripY := RY + 10;
    end;
    for K := 0 to 2 do
    begin
      El(X + 15, RY + 5 + K * 5, 1.3, 1.3, cInkSoft);
      El(X + 19, RY + 5 + K * 5, 1.3, 1.3, cInkSoft);
    end;
    Button(X + 24, RY, 70, 21, SectionNames[V.Section], Act(acIfSec, I), SecBtn[V.Section], True, 10.5);
    Field(X + 98, RY, 166, 21, Act(fdIfName, I), V.Name, fkUI, 11.5);
    Field(X + 268, RY, 190, 21, Act(fdIfType, I), V.TypeText, fkMono, 11.5);
    D.Layer := lyText;
    if V.Valid and (V.DType in [dtStruct, dtIECTimer, dtIECCounter]) then
      Txt(fkUI, 10, X + 468, RY + 4, '(instance)', cInkFaint)
    else
      Field(X + 464, RY, 120, 21, Act(fdIfStart, I), V.Start, fkMono, 11.5);
    D.Layer := lyText;
    if not V.Valid then Txt(fkUI, 10, X + 594, RY + 4, 'type?', cRed)
    else if (V.Section = vsTemp) or (B.Kind = bkFC) then Txt(fkMono, 10.5, X + 594, RY + 4, Format('L%d.%d', [V.Ofs, V.Bit]), cInkSoft)
    else Txt(fkMono, 10.5, X + 594, RY + 4, Format('%d.%d', [V.Ofs, V.Bit]), cInkSoft);
    // the live value in the first instance DB
    Live := '';
    if V.Valid and (Inst <> nil) and (Rt.Prog <> nil) and (V.Section <> vsTemp) then
    begin
      if V.DType = dtStruct then
      begin
        if V.IsArray then Live := Format('[%d]: ', [V.Lo]) + StructLive(Format('"%s".%s[%s]', [Inst.Name, V.Name, ElemIdx(V, V.Lo)]), V.Udt)
        else Live := StructLive(Format('"%s".%s', [Inst.Name, V.Name]), V.Udt);
      end
      else if V.DType = dtIECTimer then
      begin
        if FRes.Resolve(Format('"%s".%s.ET', [Inst.Name, V.Name]), O, E, False) then Live := 'ET ' + LiveText(O, '?');
        if FRes.Resolve(Format('"%s".%s.Q', [Inst.Name, V.Name]), O, E, False) then Live := Live + '  Q ' + LiveText(O, '?');
      end
      else if V.DType = dtIECCounter then
      begin
        if FRes.Resolve(Format('"%s".%s.CV', [Inst.Name, V.Name]), O, E, False) then Live := 'CV ' + LiveText(O, '?');
      end
      else if V.IsArray then
      begin
        S := '';
        for K := V.Lo to Min(V.Hi, V.Lo + 3) do
          if FRes.Resolve(Format('"%s".%s[%s]', [Inst.Name, V.Name, ElemIdx(V, K)]), O, E, False) then
          begin
            if S <> '' then S := S + ', ';
            S := S + LiveText(O, '?');
          end;
        if V.Hi > V.Lo + 3 then S := S + ', …';
        Live := '[' + S + ']';
      end
      else if FRes.Resolve(Format('"%s".%s', [Inst.Name, V.Name]), O, E, False) then
        Live := LiveText(O, '?');
    end;
    TxtFit(fkMonoB, 11, X + 652, RY + 4, 170, Live, cRedDark);
    Field(X + 826, RY, W - 842, 21, Act(fdIfComment, I), V.Comment, fkUI, 11);
  end;
  // add / delete
  if Length(B.Iface.Vars) = 0 then RY := Y + 40 else RY := Y + 64 + Length(B.Iface.Vars) * 26 + 8;
  CX := X + 14;
  for Sc := Low(TVarSection) to High(TVarSection) do
  begin
    // an FC: no Static (no instance); an FB: no Return value
    if (B.Kind = bkFC) and (Sc = vsStatic) or (B.Kind = bkFB) and (Sc = vsReturn) then Continue;
    Button(CX, RY, 92, 24, '+ ' + SectionNames[Sc], Act(acIfAdd, Ord(Sc)), bsNormal, True, 11);
    CX := CX + 98;
  end;
  Button(CX + 10, RY, 110, 24, 'Delete row', Act(acIfDel, 0), bsFlat, Length(B.Iface.Vars) > 0, 11);
  NSec := 0;
  if NSec = 0 then ;
  D.Layer := lyText;
  TxtFit(fkUI, 10.5, CX + 132, RY + 5, X + W - CX - 146, 'drag a row by its grip into the code: #Name  (or onto a LAD element)', cInkFaint);
end;

{ ---------- dragging an interface variable ---------- }

procedure TPlcUI.DrawDrag;
var
  W: Single;
  Lb: string;
begin
  if not FVarDragOn then Exit;
  D.Layer := lyOverlay;
  if FDropKind = 1 then
  begin
    // where the name goes in the text
    Rc(FDropX - 1, FDropY, 2.5, 17, cRed);
    El(FDropX, FDropY - 1, 3, 3, cRed);
  end
  else if FDropKind = 2 then
    RRL(FDropX, FDropY, FDropW, FDropH, 4, 2.4, cRed);
  // several lines: the first one and how many more
  Lb := FVarDrag;
  if Pos(#10, Lb) > 0 then
    Lb := TrimRight(Copy(Lb, 1, Pos(#10, Lb) - 1)) + Format('  (+%d lines)', [WordCount(FVarDrag, [#10])  - 1]);
  if Length(Lb) > 60 then Lb := Copy(Lb, 1, 57) + '...';
  W := TxtW(fkMonoB, 12, Lb) + 16;
  Shad(FMX + 14, FMY + 10, W, 24, 4, 2, 4, 80);
  RR(FMX + 14, FMY + 10, W, 24, 4, cRed);
  Txt(fkMonoB, 12, FMX + 22, FMY + 14, Lb, cSheet);
end;

{ ---------- Claude ---------- }

procedure TPlcUI.ClaudeChanged;
begin
  // the networks Claude wrote are new objects: the text editor lets go of the old one
  FEdNet := nil;
  FStlNet := -1;
  MarkDirty;
end;

procedure TPlcUI.ClaudeReloaded;
begin
  // the whole project came back from the snapshot: no pointer into the old one stays
  FEdNet := nil;
  FStlNet := -1;
  SetLength(FHScroll, 0);
  FBlockSel := EnsureRange(FBlockSel, 0, Max(0, Project.BlockCount - 1));
  FNetSel := 0;
  FLsNet := -1;
  ResetResolver;
  MarkDirty;
end;

procedure TPlcUI.ClaudeCompiled(P: TCProgram);
begin
  FMsgs := Copy(P.Msgs);
  FMsgErrors := P.ErrorCount;
  FMsgScroll := 0;
end;

procedure TPlcUI.OpenClaude;
begin
  FChatOpen := True;
  ChatRaiseRequested := True;
  FClaudeMenu := False;
end;

procedure TPlcUI.CloseClaude;
begin
  FChatOpen := False;
end;

procedure TPlcUI.OpenKeyDialog;
begin
  FClaudeMenu := False;
  FMenuOpen := False;
  FKeyDlg := True;
  FKeyText := '';
  FKeyMsg := '';
  StartEdit(Act(fdClaudeKey, 0), '');
end;

procedure TPlcUI.KeyDialogEvent(Sender: TObject);
begin
  OpenKeyDialog;
  RaiseRequested := True;
end;

procedure TPlcUI.TypeKeyField(const S: string);
begin
  if not FKeyDlg then OpenKeyDialog;
  StartEdit(Act(fdClaudeKey, 0), '');
  TextInput(S);
end;

{ the buttons of DrawKeyDlg: 0 save as variable, 1 save encrypted, 2 remove the variable,
  3 delete the saved key, 4 close }
function TPlcUI.KeyDlgPoint(I: Integer): TPointF;
begin
  case I of
    0: Result := DesignToPixel(530 + 120, 552 + 15);
    1: Result := DesignToPixel(778 + 100, 552 + 15);
    2: Result := DesignToPixel(530 + 85, 612 + 12);
    3: Result := DesignToPixel(708 + 85, 612 + 12);
  else
    Result := DesignToPixel(1000 + 35, 612 + 12);
  end;
end;

function TPlcUI.ClaudeMenuPoint(I: Integer): TPointF;
begin
  if I < 0 then Result := DesignToPixel(820 + 30, 112 + 14)
  else Result := DesignToPixel(820 + 110, 146 + I * 30 + 14);
end;

function TPlcUI.KeyRmPoint(I: Integer): TPointF;
begin
  if I = 1 then Result := DesignToPixel(560 + 480 - 200 + 50, 340 + 150 + 15)
  else Result := DesignToPixel(560 + 480 - 92 + 38, 340 + 150 + 15);
end;

function TPlcUI.DevMenuPoint(I: Integer): TPointF;
begin
  if I < 0 then Result := DesignToPixel(252 + 100, 352 + 15)
  else Result := DesignToPixel(252 + 120, 386 + I * 30 + 14);
end;

procedure TPlcUI.KeyDown(Key: TUiKey; Ch: Char; Mods: TUiMods);
var
  EnterInKey: Boolean;
begin
  // Enter in the key field saves it as the variable (a click elsewhere only ends the edit)
  EnterInKey := (Key = ukEnter) and (FEditId = Act(fdClaudeKey, 0));
  if FKeyRmDlg and (Key = ukEsc) then
  begin
    FKeyRmDlg := False;
    Exit;
  end;
  if (FAskOn or FCtxOn) and (Key = ukEsc) then
  begin
    FAskOn := False;
    FCtxOn := False;
    Exit;
  end;
  if FAskOn and (Key = ukEnter) and (FEditId < 0) then
  begin
    DoClick(Act(acAskOk, 0), '');
    Exit;
  end;
  if FKeyDlg and (Key = ukEsc) and not EnterInKey and (FEditId < 0) then
  begin
    DoClick(Act(acClaudeClose, 0), '');
    Exit;
  end;
  if (FClaudeMenu or FDevMenu) and (Key = ukEsc) then
  begin
    FClaudeMenu := False;
    FDevMenu := False;
    Exit;
  end;
  inherited KeyDown(Key, Ch, Mods);
  if EnterInKey and FKeyDlg then SaveKey(False);
end;

procedure TPlcUI.SaveKey(Encrypted: Boolean);
begin
  EndEdit(True);
  if Trim(FKeyText) = '' then
  begin
    FKeyMsg := 'Paste the key into the field first.';
    FKeyMsgErr := True;
    StartEdit(Act(fdClaudeKey, 0), '');
    Exit;
  end;
  try
    if Encrypted then
    begin
      ClaudeSaveKey(FKeyText);
      FKeyMsg := 'Saved encrypted for this Windows user (DPAPI).';
    end
    else
    begin
      ClaudeSetEnvKey(FKeyText);
      FKeyMsg := 'Saved as the Windows user variable ' + ClaudeKeyVar + ' (like setx).';
    end;
    FKeyMsgErr := False;
    Toast('The Claude key is saved');
  except
    on Ex: Exception do
    begin
      FKeyMsg := Ex.Message;
      FKeyMsgErr := True;
    end;
  end;
  FKeyText := '';
end;

procedure TPlcUI.AskClaudeWith(const S: string; const Files: TChatAttachments);
begin
  ClaudeAsk(S, Files);
end;

procedure TPlcUI.AskClaude(const S: string);
begin
  ClaudeAsk(S, nil);
end;

function TPlcUI.ClaudeDirty: Boolean;
begin
  Result := FDirty or (Rt.Prog = nil);
end;

{ what the editor shows, for Claude: the CPU, the block, the network, the selection }
function TPlcUI.ClaudeContext: string;
var
  B: TBlock;
  N: TNetwork;
  Sel: string;
begin
  Result := Format('CPU %s (%s), %s', [Project.Model.Name, FamilyNames[Project.Family],
    Copy(GetEnumName(TypeInfo(TRunMode), Ord(Rt.Mode)), 3, 20)]);
  if ClaudeDirty then Result := Result + ', the offline program is not downloaded yet';
  if FMsgErrors > 0 then Result := Result + Format(', %d compile errors', [FMsgErrors]);
  B := CurBlock;
  if B = nil then Exit;
  Result := Result + Format('; the editor shows %s "%s"', [B.Title, B.Name]);
  N := CurNet;
  if N = nil then Exit;
  case N.Kind of
    nkSCL: Result := Result + Format(', network %d (SCL)', [FNetSel + 1]);
    nkSTL: Result := Result + Format(', network %d (STL)', [FNetSel + 1]);
  else
    Result := Result + Format(', network %d (LAD), cell row %d column %d', [FNetSel + 1, FCellR, FCellC]);
  end;
  if (N.Kind in [nkSTL, nkSCL]) and (FStlNet = FNetSel) then
  begin
    Result := Result + Format(', caret on line %d', [FStlRow + 1]);
    if (FEdNet = N) and FEd.HasSel then
    begin
      Sel := FEd.SelText;
      if Length(Sel) > 600 then Sel := Copy(Sel, 1, 600) + '...';
      Result := Result + ', the user selected: ' + Sel;
    end;
  end;
end;

procedure TPlcUI.ClaudeAsk(const S: string; const Files: TChatAttachments);
begin
  if (Trim(S) = '') and (Length(Files) = 0) then Exit;
  EndEdit(True);
  FClaude.Project := Project;
  FClaude.Rt := Rt;
  FClaude.Context := ClaudeContext;
  FClaude.Ask(S, Files);
end;

function PickC(B: Boolean; const T, F: TBGRAPixel): TBGRAPixel;
begin
  if B then Result := T else Result := F;
end;

{ ---------- right click menus, the question, the exports ---------- }

procedure TPlcUI.OpenCtx(X, Y: Single; const Names: array of string; const Acts: array of Integer;
  const En: array of Boolean);
var
  K: Integer;
begin
  SetLength(FCtxNames, Length(Names));
  SetLength(FCtxActs, Length(Names));
  SetLength(FCtxEn, Length(Names));
  for K := 0 to High(Names) do
  begin
    FCtxNames[K] := Names[K];
    FCtxActs[K] := Acts[K];
    FCtxEn[K] := En[K];
  end;
  FCtxX := X;
  FCtxY := Y;
  FCtxOn := True;
end;

procedure TPlcUI.DrawCtx;
var
  I, Rows, Cols: Integer;
  X, Y, W, H, IY, X0, CW: Single;
  Hov: Boolean;
  C: TBGRAPixel;
begin
  if not FCtxOn then Exit;
  CW := 250;
  for I := 0 to High(FCtxNames) do CW := Max(CW, TxtW(fkUI, 12, StringReplace(FCtxNames[I], #9, '      ', [])) + 40);
  // a long menu (the data types) in columns that fit the height
  Rows := Max(1, Min(Length(FCtxNames), Trunc((DesignH - 24) / 28)));
  Cols := (Length(FCtxNames) + Rows - 1) div Rows;
  if Cols > 1 then CW := Min(CW, 220);
  W := Cols * CW;
  H := Rows * 28 + 8;
  X := Max(8, Min(FCtxX, DesignW - W - 8));
  Y := Max(8, Min(FCtxY, DesignH - H - 8));
  Hit(-1000, -1000, DesignW + 2000, DesignH + 2000, Act(acCtxClose, 0));
  D.Layer := lyOverlay;
  Shad(X, Y, W, H, 5, 3, 6, 110);
  RR(X, Y, W, H, 5, cSheet);
  RRL(X, Y, W, H, 5, 1.3, cGoldDark);
  X0 := X;
  for I := 0 to High(FCtxNames) do
  begin
    X := X0 + (I div Rows) * CW;
    W := CW;
    IY := Y + 4 + (I mod Rows) * 28;
    Hov := FCtxEn[I] and Hot(X + 4, IY, W - 8, 26);
    if Hov then RR(X + 4, IY, W - 8, 26, 4, cRed);
    // "name<Tab>shortcut": the shortcut on the right
    if FCtxEn[I] then C := PickC(Hov, cSheet, cInk) else C := cInkFaint;
    if Pos(#9, FCtxNames[I]) > 0 then
    begin
      Txt(fkUI, 12, X + 14, IY + 4, Copy(FCtxNames[I], 1, Pos(#9, FCtxNames[I]) - 1), C);
      Txt(fkUI, 11, X + W - 14, IY + 5, Copy(FCtxNames[I], Pos(#9, FCtxNames[I]) + 1, MaxInt),
        PickC(FCtxEn[I] and not Hov, cInkSoft, C), 2);
    end
    else
      Txt(fkUI, 12, X + 14, IY + 4, FCtxNames[I], C);
    if FCtxEn[I] then Hit(X + 4, IY, W - 8, 26, Act(acCtx, I));
  end;
end;

procedure TPlcUI.Ask(const Title: string; const Lines: array of string; const OkLabel: string; AAct: Integer);
var
  K: Integer;
begin
  FAskTitle := Title;
  SetLength(FAskLines, Length(Lines));
  for K := 0 to High(Lines) do FAskLines[K] := Lines[K];
  FAskOk := OkLabel;
  FAskAct := AAct;
  FAskSave := False;
  FAskOn := True;
end;

procedure TPlcUI.AskSaveFirst(const What: string; AAct: Integer);
begin
  if not Project.Modified then
  begin
    DoClick(AAct, '');
    Exit;
  end;
  EndEdit(True);
  FCtxOn := False;
  if Project.FileName <> '' then
    Ask(What, [Format('The project "%s" has changes that are not saved.', [Project.Name]),
      'Save them first (to ' + ExtractFileName(Project.FileName) + ')?'], 'Save', AAct)
  else
    Ask(What, [Format('The project "%s" has changes that are not saved.', [Project.Name]),
      'Save them first (as projects\' + StringReplace(Trim(Project.Name), ' ', '_', [rfReplaceAll]) + '.vplc)?'],
      'Save', AAct);
  FAskSave := True;
end;

procedure TPlcUI.RequestQuit;
begin
  if FAskOn then Exit;   // the question is open already
  AskSaveFirst('Close the Virtual PLC', Act(acQuitNow, 0));
end;

procedure TPlcUI.DrawAsk;
const
  X = 540;
  W = 520;
var
  Y, H: Single;
  K: Integer;
begin
  if not FAskOn then Exit;
  H := 112 + Length(FAskLines) * 20;
  Y := 330;
  Hit(-1000, -1000, DesignW + 2000, DesignH + 2000, Act(acClaudeBg, 0));
  D.Layer := lyOverlay;
  Rc(-1000, -1000, DesignW + 2000, DesignH + 2000, Alpha(cCharcoal, 70));
  Shad(X, Y, W, H, 6, 4, 10, 130);
  RR(X, Y, W, H, 6, cSheet);
  RRL(X + 0.5, Y + 0.5, W - 1, H - 1, 6, 1.4, cGoldDark);
  Rc(X + 1, Y + 1, W - 2, 38, Mixc(cRed, cRedDark, 0.3));
  Txt(fkUIB, 14.5, X + 16, Y + 10, FAskTitle, cSheet);
  for K := 0 to High(FAskLines) do
    TxtFit(fkUI, 12, X + 20, Y + 54 + K * 20, W - 40, FAskLines[K], PickC(K = 3, cRed, cInk));
  Button(X + W - 200, Y + H - 44, 100, 30, FAskOk, Act(acAskOk, 0), bsPrimary, True, 12);
  if FAskSave then Button(X + W - 314, Y + H - 44, 106, 30, 'Don''t save', Act(acAskDont, 0), bsNormal, True, 12);
  Button(X + W - 92, Y + H - 44, 76, 30, 'Cancel', Act(acAskCancel, 0), bsNormal, True, 12);
end;

function TPlcUI.HitPoint(const What: string; Par: Integer): TPointF;
var
  Id, K: Integer;
begin
  case What of
    'block': Id := Act(acBlockSel, Par);
    'net': Id := Act(acNetHead, Par);
    'db': Id := Act(acDBSel, Par);
    'file': Id := Act(acLoad, Par);
    'watchmenu': Id := Act(acWatchMenu, 0);
    'ioexport': Id := Act(acExportPc, 5 * 4096);
    'tagexport': Id := Act(acExportPc, 6 * 4096);
    'ctx': Id := Act(acCtx, Par);
    'ask':
      case Par of
        1: Id := Act(acAskOk, 0);
        2: Id := Act(acAskDont, 0);
      else
        Id := Act(acAskCancel, 0);
      end;
    'new': Id := Act(acNew, Par);
    'saveas': Id := Act(fdSaveAs, 0);
    'ip': Id := Act(fdIp, 0);
    'ipmenu': Id := Act(acIpMenu, 0);
    'tagtype': Id := Act(acTagTypeMenu, Par);
    'ipcon': Id := Act(acIpcOn, 0);
    'ipchelp': Id := Act(acIpcHelp, 0);
    'explorer': Id := Act(acExplorer, 0);
    'tagimport': Id := Act(acTagImport, 0);
    'pal': Id := Act(acPal, Par);
    'dtype': Id := Act(acDType, 0);
    'dtype2': Id := Act(acDType2, 0);
    'vartype': Id := Act(acVarTypeMenu, Par);
    'sample': Id := Act(acSample, Par);
    'example': Id := Act(acLoadEx, Par);
    'explorerex': Id := Act(acExplorerEx, 0);
    'folder': Id := Act(acFolder, 0);
    'undo': Id := Act(acUndo, 0);
    'addlad': Id := Act(acAddMenu, 0);
    'netkind': Id := Act(acNetKind, Par);
    'stl': Id := Act(acStlLine, Par * 1024);
    'ioimport': Id := Act(acIoImport, 0);
    'iohelp': Id := Act(acIoHelp, 0);
    'addscl': Id := Act(acAddMenu, 2);
    'redo': Id := Act(acRedo, 0);
    'elem': Id := Act(acElem, Par);
    'sclsrc': Id := Act(acSclSrcMenu, 0);
    'elemcat': Id := Act(acElemCat, Par);
    'ioview': Id := Act(acIoView, Par);
    'grpadd': Id := Act(acGrpAdd, Par * 16384);
    'grpdel': Id := Act(acGrpDel, Par * 16384);
    'grpsel': Id := Act(acGrpSel, Par);
    'grpopen': Id := Act(acGrpOpen, Par);
    'sorttag': Id := Act(acSortTag, Par);
    'sortwatch': Id := Act(acSortWatch, Par);
    'taggrp': Id := Act(acTagGrpMenu, Par);
    'watchrow': Id := Act(acWatchRow, Par);
    'watchgrp': Id := Act(acWatchGrpMenu, 0);
    'dbscl': Id := Act(acDbScl, Par);
    'sigadd': Id := Act(acSigAdd, 0);
    'sigtags': Id := Act(acSigTags, 0);
    'sigall': Id := Act(acSigAll, Par);
    'tagio': Id := Act(acTagIo, Par);
    'watchadd': Id := Act(acWatchAdd, 0);
    'tagadd': Id := Act(acTagAdd, 0);
  else
    Id := -1;
  end;
  Result := PointF(-1, -1);
  for K := FLastHitN - 1 downto 0 do
    if FLastHits[K].Id = Id then
      with FLastHits[K].R do
        // the network head: left of its fields
        if What = 'net' then Exit(DesignToPixel(Left + 40, Top + 12))
        else if What = 'watchrow' then Exit(DesignToPixel(Left + 16, Top + 12))   // the # column: no button
        else Exit(DesignToPixel((Left + Right) / 2, (Top + Bottom) / 2));
end;

procedure TPlcUI.ShowProjectFile(I: Integer);
begin
  if I >= 0 then
  begin
    FFolder := 0;
    FFileScroll := Max(0, I div 2 - 3);
  end;
end;

procedure TPlcUI.RefreshProjectFiles;
begin
  RefreshFiles;
end;

function TPlcUI.ProjectFileIndex(const AName: string): Integer;
begin
  Result := FFiles.IndexOf(AName);
end;

function TPlcUI.LiveOf(const Operand: string): string;
var
  O: TOperand;
  E: string;
begin
  Result := '';
  if FRes.Resolve(Operand, O, E, False) and (O.Kind = okAddr) then Result := LiveText(O, '');
end;

function TPlcUI.IoTagFor(const A: string): string;
var
  K: Integer;
  TA, TB: TAddr;
  E: string;
begin
  Result := '';
  if not ParseAddr(A, TA, E) then Exit;
  for K := 0 to High(Project.Tags) do
    if ParseAddr(Project.Tags[K].Address, TB, E) and SameAddr(TA, TB) then Exit(Project.Tags[K].Name);
end;

function SafeName(const S: string): string;
var
  K: Integer;
begin
  Result := S;
  for K := 1 to Length(Result) do
    if Result[K] in ['\', '/', ':', '*', '?', '"', '<', '>', '|', ' '] then Result[K] := '_';
end;

{ the file name the dialog proposes, its filter and extension }
function TPlcUI.ExportName(Kind, Fmt, Index: Integer; out Filter, Ext: string): string;
var
  B: TBlock;
begin
  Result := 'export';
  case Kind of
    0, 1:
      begin
        if Fmt = 0 then Ext := 'txt' else Ext := 'json';
        if Kind = 0 then B := Project.Block(Index) else B := CurBlock;
        if B <> nil then Result := SafeName(B.Title + '_' + B.Name);
        if Kind = 1 then Result := Result + Format('_network%d', [Index + 1]);
      end;
    2, 3:
      begin
        case Fmt of
          0: if Kind = 2 then Ext := 'csv' else Ext := 'txt';
          1: if Kind = 2 then Ext := 'txt' else Ext := 'csv';
        else
          Ext := 'json';
        end;
        if Kind = 2 then Result := SafeName(Format('DB%d_%s', [Project.DB(Index).Number, Project.DB(Index).Name]))
        else Result := SafeName(Format('UDT%d_%s', [Project.Udt(Index).Number, Project.Udt(Index).Name]));
      end;
    4: begin Ext := 'csv'; Result := 'watch_table'; end;
    5: begin Ext := 'csv'; Result := 'io_list'; end;
  else
    begin Ext := 'csv'; Result := 'tag_table'; end;
  end;
  case Ext of
    'txt': Filter := 'Text (*.txt)|*.txt';
    'json': Filter := 'JSON (*.json)|*.json';
  else
    Filter := 'CSV for Excel (*.csv)|*.csv';
  end;
  Result := Result + '.' + Ext;
end;

procedure TPlcUI.ChooseExport(Kind, Fmt, Index: Integer);
var
  Dl: TSaveDialog;
  Filter, Ext, Nm: string;
begin
  Nm := ExportName(Kind, Fmt, Index, Filter, Ext);
  Dl := TSaveDialog.Create(nil);
  try
    Dl.Title := 'Export';
    Dl.Filter := Filter;
    Dl.DefaultExt := Ext;
    Dl.InitialDir := ExtractFilePath(ParamStr(0)) + 'export';
    ForceDirectories(Dl.InitialDir);
    Dl.FileName := Nm;
    Dl.Options := [ofOverwritePrompt, ofPathMustExist, ofEnableSizing];
    if Dl.Execute then ExportPiece(Kind, Fmt, Index, Dl.FileName);
  finally
    Dl.Free;
  end;
end;

function TPlcUI.ExportPiece(Kind, Fmt, Index: Integer; const FileName: string): Boolean;
var
  S, Ext, Filter, A, Tg, V, Fc: string;
  M: TCpuModel;
  I, B, Bit, Raw, Gk9: Integer;
  O: TOperand;
  E: string;
  Ok: Boolean;
begin
  Result := False;
  ExportName(Kind, Fmt, Index, Filter, Ext);
  try
    case Kind of
      0:
        begin
          if (Index < 0) or (Index >= Project.BlockCount) then Exit;
          if Fmt = 0 then WriteUtf8File(FileName, BlockText(Project, Project.Block(Index)), True)
          else WriteUtf8File(FileName, JsonText(BlockToJson(Project.Block(Index))), False);
        end;
      1:
        begin
          if (CurBlock = nil) or (Index < 0) or (Index >= CurBlock.NetCount) then Exit;
          if Fmt = 0 then WriteUtf8File(FileName, BlockName(CurBlock) + LineEnding + NetText(CurBlock, Index), True)
          else WriteUtf8File(FileName, JsonText(NetToJson(CurBlock.Net(Index))), False);
        end;
      2, 3:
        begin
          if Kind = 2 then
          begin
            if (Index < 0) or (Index >= Project.DBCount) then Exit;
            case Fmt of
              0: WriteUtf8File(FileName, DataBlockCsv(Project.DB(Index), @LiveOf), True);
              1: WriteUtf8File(FileName, DataBlockText(Project, Project.DB(Index), @LiveOf), True);
            else
              WriteUtf8File(FileName, JsonText(DataBlockToJson(Project.DB(Index), False)), False);
            end;
          end
          else
          begin
            if (Index < 0) or (Index >= Project.UdtCount) then Exit;
            case Fmt of
              0: WriteUtf8File(FileName, DataBlockText(Project, Project.Udt(Index), nil), True);
              1: WriteUtf8File(FileName, DataBlockCsv(Project.Udt(Index), nil), True);
            else
              WriteUtf8File(FileName, JsonText(DataBlockToJson(Project.Udt(Index), True)), False);
            end;
          end;
        end;
      4:
        begin
          // the watch table with what it shows now
          S := CsvLine(['#', 'Address / symbol', 'Absolute / symbol', 'Format', 'Monitor value', 'Modify value',
            'Modify', 'Forced']);
          for I := 0 to High(Project.Watch) do
          begin
            Ok := FRes.Resolve(Project.Watch[I].Address, O, E, False) and (O.Kind = okAddr);
            if Ok then
            begin
              A := FRes.SymbolOf(O.A);
              if (A = '') or ((Project.Watch[I].Address <> '') and (Project.Watch[I].Address[1] = '"')) then
                A := FormatAddr(O.A, Project.Family);
              if not OperandValue(Project.Watch[I].Address, Project.Watch[I].Fmt, V) then V := '';
              Fc := IfThen(Rt.IsForced(O), 'forced', '');
            end
            else
            begin
              A := E;
              V := '';
              Fc := '';
            end;
            S := S + CsvLine([IntToStr(I + 1), Project.Watch[I].Address, A, DispFmtNames[Project.Watch[I].Fmt], V,
              Project.Watch[I].ModifyValue, IfThen(Project.Watch[I].ModifyOn, 'yes', ''), Fc]);
          end;
          WriteUtf8File(FileName, S, True);
        end;
      5:
        begin
          // every I/O point: its address, tag, kind and what it is now
          M := Rt.Model;
          S := CsvLine(['Kind', 'Address', 'Tag', 'Input / range', 'Value', 'Engineering', 'Forced']);
          for I := 0 to M.DI - 1 do
          begin
            B := M.DIByte + I div 8;
            Bit := I mod 8;
            A := Format('I%d.%d', [B, Bit]);
            FillChar(O, SizeOf(O), 0);
            O.Kind := okAddr;
            O.A := MakeAddr(arI, osBit, B, Bit);
            S := S + CsvLine(['DI', IfThen(IsTia(M.Family), '%', '') + A, IoTagFor(A),
              InTypeNames[Project.DIch[I].InType], IfThen(Rt.GetSimBit(B, Bit), 'TRUE', 'FALSE'), '',
              IfThen(Rt.IsForced(O), 'forced', '')]);
          end;
          for I := 0 to M.DQ - 1 do
          begin
            B := M.DQByte + I div 8;
            Bit := I mod 8;
            A := Format('Q%d.%d', [B, Bit]);
            FillChar(O, SizeOf(O), 0);
            O.Kind := okAddr;
            O.A := MakeAddr(arQ, osBit, B, Bit);
            S := S + CsvLine(['DQ', IfThen(IsTia(M.Family), '%', '') + A, IoTagFor(A), '',
              IfThen(Rt.GetOutBit(B, Bit), 'TRUE', 'FALSE'), '', IfThen(Rt.IsForced(O), 'forced', '')]);
          end;
          for I := 0 to M.AI - 1 do
          begin
            Raw := SmallInt((Word(Rt.SimIn[M.AIWord + I * 2]) shl 8) or Rt.SimIn[M.AIWord + I * 2 + 1]);
            A := Format('IW%d', [M.AIWord + I * 2]);
            Tg := IoTagFor(A);
            if Tg = '' then Tg := IoTagFor('P' + A);
            S := S + CsvLine(['AI', IfThen(IsTia(M.Family), '%' + A, 'P' + A), Tg,
              '0..27648 = 0..10 V, ' + AiModeNames[Project.AIch[I].AiMode], IntToStr(Raw),
              FormatFloat('0.00', Raw * 10 / 27648) + ' V', '']);
          end;
          for I := 0 to M.AQ - 1 do
          begin
            Raw := Rt.GetOutWord(M.AQWord + I * 2);
            A := Format('QW%d', [M.AQWord + I * 2]);
            Tg := IoTagFor(A);
            if Tg = '' then Tg := IoTagFor('P' + A);
            S := S + CsvLine(['AQ', IfThen(IsTia(M.Family), '%' + A, 'P' + A), Tg, '0..27648 = 0..20 mA',
              IntToStr(Raw), FormatFloat('0.00', Raw * 20 / 27648) + ' mA', '']);
          end;
          WriteUtf8File(FileName, S, True);
        end;
    else
      begin
        // the tag table with the values now
        S := CsvLine(['Name', 'Path', 'Data type', 'Address', 'Monitor value', 'Comment']);
        for I := 0 to High(Project.Tags) do
        begin
          // Path: the group (as the tag table of TIA)
          Gk9 := GroupOfId(Project.TagGroups, Project.Tags[I].GroupId);
          if Gk9 >= 0 then A := Project.TagGroups[Gk9].Name else A := '';
          S := S + CsvLine([Project.Tags[I].Name, A, Project.Tags[I].TypeText, Project.Tags[I].Address,
            LiveOf('"' + Project.Tags[I].Name + '"'), Project.Tags[I].Comment]);
        end;
        WriteUtf8File(FileName, S, True);
      end;
    end;
    Toast('Exported ' + ExtractFileName(FileName));
    Result := True;
  except
    on Ex: Exception do Toast('Export failed: ' + Ex.Message, True);
  end;
end;

function TPlcUI.WatchSaveTo(const FileName: string): Boolean;
begin
  Result := False;
  try
    Project.SaveWatchFile(FileName);
    FWatchFile := FileName;
    Toast('Saved the watch table ' + ExtractFileName(FileName));
    Result := True;
  except
    on Ex: Exception do Toast('Save failed: ' + Ex.Message, True);
  end;
end;

function TPlcUI.WatchOpenFrom(const FileName: string): Boolean;
begin
  Result := False;
  try
    Project.LoadWatchFile(FileName);
    Project.Modified := True;
    FWatchFile := FileName;
    FWatchSel := 0;
    FWatchScroll := 0;
    Toast(Format('Opened the watch table %s (%d rows)', [ExtractFileName(FileName), Length(Project.Watch)]));
    Result := True;
  except
    on Ex: Exception do Toast('Open failed: ' + Ex.Message, True);
  end;
end;

{ Table menu: 0 Save, 1 Open, 2 Save As, 3 Export }
procedure TPlcUI.WatchMenu(Item: Integer);
var
  Sd: TSaveDialog;
  Od: TOpenDialog;
begin
  if (Item = 0) and (FWatchFile <> '') then
  begin
    WatchSaveTo(FWatchFile);
    Exit;
  end;
  if Item = 3 then
  begin
    ChooseExport(4, 0, 0);
    Exit;
  end;
  if Item = 4 then
  begin
    Od := TOpenDialog.Create(nil);
    try
      Od.Title := 'Import watch rows';
      Od.Filter := 'CSV (*.csv;*.txt)|*.csv;*.txt|All files (*.*)|*.*';
      Od.InitialDir := ExtractFilePath(ParamStr(0)) + 'export';
      Od.Options := [ofFileMustExist, ofEnableSizing];
      if Od.Execute then Toast('Import: ' + ImportWatch(Od.FileName));
    finally
      Od.Free;
    end;
    Exit;
  end;
  if Item = 1 then
  begin
    Od := TOpenDialog.Create(nil);
    try
      Od.Title := 'Open a watch table';
      Od.Filter := 'Watch table (*.watch)|*.watch|All files (*.*)|*.*';
      Od.InitialDir := ProjectsDir;
      ForceDirectories(Od.InitialDir);
      Od.Options := [ofFileMustExist, ofEnableSizing];
      if Od.Execute then WatchOpenFrom(Od.FileName);
    finally
      Od.Free;
    end;
    Exit;
  end;
  // Save without a file yet, Save As
  Sd := TSaveDialog.Create(nil);
  try
    Sd.Title := 'Save the watch table';
    Sd.Filter := 'Watch table (*.watch)|*.watch';
    Sd.DefaultExt := 'watch';
    if FWatchFile <> '' then Sd.InitialDir := ExtractFilePath(FWatchFile) else Sd.InitialDir := ProjectsDir;
    ForceDirectories(Sd.InitialDir);
    if FWatchFile <> '' then Sd.FileName := ExtractFileName(FWatchFile)
    else Sd.FileName := SafeName(Project.Name) + '.watch';
    Sd.Options := [ofOverwritePrompt, ofPathMustExist, ofEnableSizing];
    if Sd.Execute then WatchSaveTo(Sd.FileName);
  finally
    Sd.Free;
  end;
end;

function KeyToRemove: Boolean;
begin
  Result := ClaudeHasEnvKey or ClaudeHasSavedKey or (Trim(SysUtils.GetEnvironmentVariable(ClaudeKeyVar)) <> '');
end;

{ the AI menu under its button in the program editor }
procedure TPlcUI.DrawClaudeMenu;
const
  Names: array[0..2] of string = ('Claude chat', 'Set ANTHROPIC_API_KEY ...', 'Remove ANTHROPIC_API_KEY ...');
var
  I: Integer;
  X, Y, W, IY: Single;
  Src: string;
  On, En: Boolean;
begin
  if not FClaudeMenu then Exit;
  if Screen <> scProgram then
  begin
    FClaudeMenu := False;
    Exit;
  end;
  X := 820;
  Y := 142;
  W := 260;
  Hit(-1000, -1000, DesignW + 2000, DesignH + 2000, Act(acClaudeMenuClose, 0));
  D.Layer := lyOverlay;
  Shad(X, Y, W, 122, 5, 3, 6, 110);
  RR(X, Y, W, 122, 5, cSheet);
  RRL(X, Y, W, 122, 5, 1.3, cGoldDark);
  for I := 0 to 2 do
  begin
    IY := Y + 4 + I * 30;
    En := (I <> 2) or KeyToRemove;   // nothing to remove: grey
    On := En and Hot(X + 4, IY, W - 8, 28);
    if On then RR(X + 4, IY, W - 8, 28, 4, cRed);
    if En then Txt(fkUI, 12.5, X + 14, IY + 5, Names[I], PickC(On, cSheet, cInk))
    else Txt(fkUI, 12.5, X + 14, IY + 5, Names[I], cInkFaint);
    if (I = 0) and FChatOpen then Txt(fkUI, 12, X + W - 14, IY + 6, '✓', PickC(On, cSheet, cJade), 2);
    if En then Hit(X + 4, IY, W - 8, 28, Act(acClaudeMenu, I));
  end;
  ClaudeApiKey(Src);
  if Src = '' then Src := 'no key yet';
  Ln(X + 8, Y + 98, X + W - 8, Y + 98, 0.8, Alpha(cGoldDark, 140));
  TxtFit(fkUI, 10, X + 14, Y + 102, W - 28, 'key: ' + Src, cInkFaint);
end;

{ Remove ANTHROPIC_API_KEY: what goes, then Remove / Cancel }
procedure TPlcUI.DrawKeyRmDlg;
const
  X = 560;
  Y = 340;
  W = 480;
  H = 200;
var
  TY: Single;
  Env, Fil, Proc: Boolean;
begin
  if not FKeyRmDlg then Exit;
  Hit(-1000, -1000, DesignW + 2000, DesignH + 2000, Act(acClaudeBg, 0));
  D.Layer := lyOverlay;
  Rc(-1000, -1000, DesignW + 2000, DesignH + 2000, Alpha(cCharcoal, 70));
  Shad(X, Y, W, H, 6, 4, 10, 130);
  RR(X, Y, W, H, 6, cSheet);
  RRL(X + 0.5, Y + 0.5, W - 1, H - 1, 6, 1.4, cGoldDark);
  Rc(X + 1, Y + 1, W - 2, 38, Mixc(cRed, cRedDark, 0.3));
  Txt(fkUIB, 14.5, X + 16, Y + 10, 'Remove ' + ClaudeKeyVar, cSheet);
  Env := ClaudeHasEnvKey;
  Fil := ClaudeHasSavedKey;
  Proc := Trim(SysUtils.GetEnvironmentVariable(ClaudeKeyVar)) <> '';
  TY := Y + 54;
  Txt(fkUI, 12, X + 20, TY, 'Claude can not be used until a key is set again. This removes:', cInk);
  TY := TY + 24;
  if Env then
  begin
    Txt(fkUI, 12, X + 30, TY, '•  the Windows user variable ' + ClaudeKeyVar + ' (as setx made it)', cInk);
    TY := TY + 20;
  end;
  if Fil then
  begin
    Txt(fkUI, 12, X + 30, TY, '•  the encrypted key file of this app (DPAPI)', cInk);
    TY := TY + 20;
  end;
  if Proc and not Env then
    Txt(fkUI, 11, X + 30, TY, '•  the variable of this program only (it came from where the app was started)', cInkSoft);
  Button(X + W - 200, Y + 150, 100, 30, 'Remove', Act(acKeyRemove, 1), bsDanger, True, 12);
  Button(X + W - 92, Y + 150, 76, 30, 'Cancel', Act(acKeyRemove, 0), bsNormal, True, 12);
end;

{ the Developer menu under its button on the Project screen: the developer info window (LCL) }
procedure TPlcUI.DrawDevMenu;
const
  Names: array[0..2] of string = ('Show Developer info', 'Developer info on top', 'Close Developer info');
  Keys: array[0..2] of string = ('F1', '', '');
var
  I: Integer;
  X, Y, W, IY: Single;
  On, Hov: Boolean;
begin
  if not FDevMenu then Exit;
  if Screen <> scProject then
  begin
    FDevMenu := False;
    Exit;
  end;
  X := 252;
  Y := 384;
  W := 240;
  Hit(-1000, -1000, DesignW + 2000, DesignH + 2000, Act(acDevMenuClose, 0));
  D.Layer := lyOverlay;
  Shad(X, Y, W, 3 * 30 + 8, 5, 3, 6, 110);
  RR(X, Y, W, 3 * 30 + 8, 5, cSheet);
  RRL(X, Y, W, 3 * 30 + 8, 5, 1.3, cGoldDark);
  for I := 0 to 2 do
  begin
    IY := Y + 4 + I * 30;
    On := (I <> 2) or InfoVisible;   // nothing to close when it is not shown
    Hov := On and Hot(X + 4, IY, W - 8, 28);
    if Hov then RR(X + 4, IY, W - 8, 28, 4, cRed);
    if On then Txt(fkUI, 12.5, X + 14, IY + 5, Names[I], PickC(Hov, cSheet, cInk))
    else Txt(fkUI, 12.5, X + 14, IY + 5, Names[I], cInkFaint);
    if Keys[I] <> '' then Txt(fkMono, 10.5, X + W - 14, IY + 7, Keys[I], PickC(Hov, cGoldLight, cInkFaint), 2);
    if (I = 1) and InfoOnTop then Txt(fkUI, 12, X + W - 14, IY + 6, '✓', PickC(Hov, cSheet, cJade), 2);
    if On then Hit(X + 4, IY, W - 8, 28, Act(acDevMenu, I));
  end;
end;

{ Set ANTHROPIC_API_KEY: the key as the Windows user variable (like setx), or encrypted with DPAPI }
procedure TPlcUI.DrawKeyDlg;
const
  X = 510;
  Y = 300;
  W = 580;
  H = 350;
var
  Src: string;
  TY: Single;
  HasEnv, HasFile: Boolean;
begin
  if not FKeyDlg then Exit;
  // modal: a click outside does nothing
  Hit(-1000, -1000, DesignW + 2000, DesignH + 2000, Act(acClaudeBg, 0));
  D.Layer := lyOverlay;
  Rc(-1000, -1000, DesignW + 2000, DesignH + 2000, Alpha(cCharcoal, 70));
  Shad(X, Y, W, H, 6, 4, 10, 130);
  RR(X, Y, W, H, 6, cSheet);
  RRL(X + 0.5, Y + 0.5, W - 1, H - 1, 6, 1.4, cGoldDark);
  Rc(X + 1, Y + 1, W - 2, 38, Mixc(cRed, cRedDark, 0.3));
  Txt(fkUIB, 14.5, X + 16, Y + 10, 'Set ' + ClaudeKeyVar, cSheet);
  ClaudeApiKey(Src);
  HasEnv := ClaudeHasEnvKey;
  HasFile := ClaudeHasSavedKey;
  if Src = '' then Src := 'none';
  TY := Y + 54;
  Txt(fkUI, 12, X + 20, TY, 'The key of your Anthropic account (console.anthropic.com); requests are billed to it.', cInk);
  Txt(fkUI, 12, X + 20, TY + 20, 'It never goes into a project file and is not shown again after saving.', cInk);
  Txt(fkUIB, 12, X + 20, TY + 48, 'Claude uses now:', cInkSoft);
  TxtFit(fkUI, 12, X + 130, TY + 48, W - 150, Src, PickC(Src = 'none', cRed, cJade));
  Txt(fkUI, 11, X + 20, TY + 68, Format('user variable %s: %s     encrypted key file: %s',
    [ClaudeKeyVar, IfThen(HasEnv, 'set', 'not set'), IfThen(HasFile, 'saved', 'none')]), cInkSoft);
  Txt(fkUI, 10.5, X + 20, 446, 'key', cInkSoft);
  Field(X + 20, 462, W - 40, 30, Act(fdClaudeKey, 0), FKeyText, fkMono, 12.5, 0, True, 'sk-ant-...  (paste with Ctrl+V)');
  if FKeyMsg <> '' then TxtFit(fkUI, 11.5, X + 20, 498, W - 40, FKeyMsg, PickC(FKeyMsgErr, cRed, cJade));
  Txt(fkUI, 10.5, X + 20, 524, 'As a variable: like setx, other programs see it too.  Encrypted: only this app.', cInkFaint);
  Button(X + 20, 552, 240, 30, 'Save as ' + ClaudeKeyVar, Act(acClaudeKeySave, 0), bsPrimary, True, 12);
  Button(X + 268, 552, 200, 30, 'Save encrypted (DPAPI)', Act(acClaudeKeySave, 1), bsGold, True, 12);
  Button(X + 20, 612, 170, 24, 'Remove the variable', Act(acClaudeKeyForget, 0), bsFlat, HasEnv, 11);
  Button(X + 198, 612, 170, 24, 'Delete the saved key', Act(acClaudeKeyForget, 1), bsFlat, HasFile, 11);
  Button(X + W - 90, 612, 70, 24, 'Close', Act(acClaudeClose, 0), bsNormal, True, 11.5);
end;

{ ---------- the LAD popup menu (right button on a cell) ---------- }

procedure TPlcUI.DoRightClick(Id: Integer);
var
  NI, Cl: Integer;
  N: TNetwork;
begin
  FMenuOpen := False;
  FCtxOn := False;
  if Id >= 0 then
    case Id shr 16 of
      acElem:
        if ((Id and $FFFF) <= High(FElems)) and (FElems[Id and $FFFF].Snip <> '') then
        begin
          FElemPress := Id and $FFFF;
          OpenCtx(FMX, FMY, ['Insert at the caret', 'Copy'], [Act(acElemIns, Id and $FFFF),
            Act(acElemCopy, Id and $FFFF)], [(CurNet <> nil) and (CurNet.Kind = nkSCL), True]);
          Exit;
        end;
      acHelp:
        begin
          FHelpFocus := True;
          if not HelpHasSel then HelpWord(HelpPosAt(FMX, FMY), FHelp0, FHelp1);
          OpenCtx(FMX, FMY, ['Copy', 'Select all'], [Act(acHelpCopy, 0), Act(acHelpAll, 0)], [HelpHasSel, True]);
          Exit;
        end;
      acLoad, acLoadEx:
        if ((Id shr 16 = acLoad) and ((Id and $FFFF) < FFiles.Count)) or
          ((Id shr 16 = acLoadEx) and ((Id and $FFFF) < FExamples.Count)) then
        begin
          FFileCtx := Id and $FFFF;
          FFileCtxEx := Id shr 16 = acLoadEx;
          OpenCtx(FMX, FMY, ['Load ...', 'Show in Explorer'], [Act(acFileCtx, 0), Act(acFileCtx, 1)], [True, True]);
          Exit;
        end;
      acBlockSel:
        if (Id and $FFFF) < Project.BlockCount then
        begin
          DoClick(Id, '');
          OpenCtx(FMX, FMY, ['Export block as text ...', 'Export block as JSON ...', 'Export block as .scl source ...'],
            [Act(acExportPc, 0 * 4096 + 0 * 1024 + (Id and $FFFF)), Act(acExportPc, 0 * 4096 + 1 * 1024 + (Id and $FFFF)),
            Act(acSclSrc, 1)], [True, True, True]);
          Exit;
        end;
      acNetSel, acNetHead, fdNetTitle, fdNetComment:
        if (CurBlock <> nil) and ((Id and $FFFF) < CurBlock.NetCount) then
        begin
          FNetSel := Id and $FFFF;
          OpenCtx(FMX, FMY, ['Add LAD network above', 'Add LAD network below', 'Add STL network above',
            'Add STL network below', 'Add SCL network above', 'Add SCL network below',
            'Export network as text ...', 'Export network as JSON ...'],
            [Act(acAddNet, 0), Act(acAddNet, 1), Act(acAddNet, 2), Act(acAddNet, 3), Act(acAddNet, 4), Act(acAddNet, 5),
            Act(acExportPc, 1 * 4096 + 0 * 1024 + (Id and $FFFF)), Act(acExportPc, 1 * 4096 + 1 * 1024 + (Id and $FFFF))],
            [True, True, HasStl(Project.Family), HasStl(Project.Family), True, True, True, True]);
          Exit;
        end;
      acStlLine:
        if StlMenu(Id) then
        begin
          N := CurNet;
          OpenCtx(FMX, FMY, ['Undo'#9'Ctrl+Z', 'Redo'#9'Ctrl+Y', 'Cut'#9'Ctrl+X', 'Copy'#9'Ctrl+C',
            'Paste'#9'Ctrl+V', 'Delete'#9'Del', 'Select all'#9'Ctrl+A', 'Comment / uncomment'#9'Ctrl+Q',
            'Find ...'#9'Ctrl+F', 'Find declaration'#9'Alt+Up / Ctrl+Click', 'All variables ...', 'All elements ...'],
            [Act(acStlCtx, 0), Act(acStlCtx, 1), Act(acStlCtx, 2), Act(acStlCtx, 3), Act(acStlCtx, 4),
            Act(acStlCtx, 5), Act(acStlCtx, 6), Act(acStlCtx, 7), Act(acStlCtx, 8), Act(acStlCtx, 9),
            Act(acStlCtx, 10), Act(acStlCtx, 11)],
            [(Length(FPUndo) > 0) or FPPending, Length(FPRedo) > 0, True, True, Clipbrd.Clipboard.AsText <> '', FEd.HasSel, True,
            True, True, True, True, True]);
          Exit;
        end;
      acDBSel:
        begin
          DoClick(Id, '');
          if (Id and $FFFF) < Project.DBCount then
            OpenCtx(FMX, FMY, ['Export data block as CSV ...', 'Export data block as text ...',
              'Export data block as JSON ...'],
              [Act(acExportPc, 2 * 4096 + 0 * 1024 + (Id and $FFFF)), Act(acExportPc, 2 * 4096 + 1 * 1024 + (Id and $FFFF)),
              Act(acExportPc, 2 * 4096 + 2 * 1024 + (Id and $FFFF))], [True, True, True])
          else
            OpenCtx(FMX, FMY, ['Export data type as text ...', 'Export data type as CSV ...',
              'Export data type as JSON ...'],
              [Act(acExportPc, 3 * 4096 + 0 * 1024 + (Id and $FFFF) - Project.DBCount),
              Act(acExportPc, 3 * 4096 + 1 * 1024 + (Id and $FFFF) - Project.DBCount),
              Act(acExportPc, 3 * 4096 + 2 * 1024 + (Id and $FFFF) - Project.DBCount)], [True, True, True]);
          Exit;
        end;
    end;
  if (Screen <> scProgram) or (Id < 0) or (Id shr 16 <> acCell) then Exit;
  NI := (Id and $FFFF) div 256;
  Cl := (Id and $FFFF) mod 256;
  if (CurBlock = nil) or (NI >= CurBlock.NetCount) then Exit;
  N := CurBlock.Net(NI);
  if N.Kind <> nkLAD then Exit;
  FNetSel := NI;
  FStlNet := -1;
  FCompOpen := False;
  // a cell outside the selection: it is the selection now (like Explorer / TIA)
  if not LadInSel(NI, Cl div N.Cols, Cl mod N.Cols) then
  begin
    FCellR := Cl div N.Cols;
    FCellC := Cl mod N.Cols;
    LadCollapse;
  end;
  FMenuOpen := True;
  FMenuX := FMX;
  FMenuY := FMY;
end;

procedure TPlcUI.DrawMenu;
const
  Names: array[0..4] of string = ('Copy', 'Cut', 'Paste (insert)', 'Delete', 'Select all');
  Keys: array[0..4] of string = ('Ctrl+C', 'Ctrl+X', 'Ctrl+V', 'Del', 'Ctrl+A');
var
  I: Integer;
  X, Y, W, IY: Single;
  On: Boolean;
  R1, C1, R2, C2: Integer;
begin
  if not FMenuOpen then Exit;
  if (CurNet = nil) or (CurNet.Kind <> nkLAD) or (Screen <> scProgram) then
  begin
    FMenuOpen := False;
    Exit;
  end;
  W := 210;
  X := Min(FMenuX, 1590 - W);
  Y := Min(FMenuY, 890 - (5 * 26 + 30));
  // a click anywhere else only closes the menu
  Hit(0, 0, DesignW, DesignH, Act(acMenuClose, 0));
  D.Layer := lyOverlay;
  Shad(X, Y, W, 5 * 26 + 30, 5, 3, 6, 110);
  RR(X, Y, W, 5 * 26 + 30, 5, cSheet);
  RRL(X, Y, W, 5 * 26 + 30, 5, 1.3, cGoldDark);
  LadSel(R1, C1, R2, C2);
  Txt(fkUIB, 10.5, X + 12, Y + 6, Format('%d x %d cells', [C2 - C1 + 1, R2 - R1 + 1]), cInkSoft);
  for I := 0 to 4 do
  begin
    IY := Y + 24 + I * 26 + Ord(I = 4) * 6;
    On := (I <> 2) or (Length(FLadClip) > 0);
    if I = 4 then Ln(X + 8, IY - 4, X + W - 8, IY - 4, 0.8, Alpha(cGoldDark, 140));
    if On and Hot(X + 4, IY, W - 8, 24) then RR(X + 4, IY, W - 8, 24, 4, cRed);
    if On and Hot(X + 4, IY, W - 8, 24) then
    begin
      Txt(fkUI, 12, X + 14, IY + 4, Names[I], cSheet);
      Txt(fkMono, 10.5, X + W - 12, IY + 5, Keys[I], cGoldLight, 2);
    end
    else if On then
    begin
      Txt(fkUI, 12, X + 14, IY + 4, Names[I], cInk);
      Txt(fkMono, 10.5, X + W - 12, IY + 5, Keys[I], cInkFaint, 2);
    end
    else
      Txt(fkUI, 12, X + 14, IY + 4, Names[I] + '  (nothing copied)', cInkFaint);
    if On then Hit(X + 4, IY, W - 8, 24, Act(acMenu, I));
  end;
end;

function TPlcUI.GetHS(N: TNetwork): Single;
var
  K: Integer;
begin
  for K := 0 to High(FHScroll) do
    if FHScroll[K].Net = N then Exit(FHScroll[K].X);
  Result := 0;
end;

procedure TPlcUI.SetHS(N: TNetwork; V: Single);
var
  K: Integer;
begin
  for K := 0 to High(FHScroll) do
    if FHScroll[K].Net = N then
    begin
      FHScroll[K].X := V;
      Exit;
    end;
  if V = 0 then Exit;
  SetLength(FHScroll, Length(FHScroll) + 1);
  FHScroll[High(FHScroll)].Net := N;
  FHScroll[High(FHScroll)].X := V;
end;

{ more columns (up to MaxLadCols); the view follows the focus }
procedure TPlcUI.LadGrow(N: TNetwork; ToCols: Integer);
begin
  if ToCols <= N.Cols then Exit;
  N.SetCols(Min(ToCols, MaxLadCols));
  FLadFollow := True;
  MarkDirty;
end;

{ ---------- LAD: the selected rectangle of cells ---------- }

function TPlcUI.LadSel(out R1, C1, R2, C2: Integer): Boolean;
begin
  if FLsNet = FNetSel then
  begin
    R1 := Min(FLsA.Y, FLsB.Y);
    R2 := Max(FLsA.Y, FLsB.Y);
    C1 := Min(FLsA.X, FLsB.X);
    C2 := Max(FLsA.X, FLsB.X);
    if (CurNet <> nil) and (CurNet.Kind = nkLAD) then
    begin
      R1 := EnsureRange(R1, 0, CurNet.Rows - 1);
      R2 := EnsureRange(R2, 0, CurNet.Rows - 1);
      C1 := EnsureRange(C1, 0, CurNet.Cols - 1);
      C2 := EnsureRange(C2, 0, CurNet.Cols - 1);
    end;
    Result := (R1 <> R2) or (C1 <> C2) or (FLadMode = 1);
  end
  else
  begin
    R1 := FCellR;
    R2 := FCellR;
    C1 := FCellC;
    C2 := FCellC;
    Result := False;
  end;
end;

function TPlcUI.LadInSel(NI, R, C: Integer): Boolean;
var
  R1, C1, R2, C2: Integer;
begin
  if NI <> FNetSel then Exit(False);
  LadSel(R1, C1, R2, C2);
  Result := (R >= R1) and (R <= R2) and (C >= C1) and (C <= C2);
end;

procedure TPlcUI.LadCollapse;
begin
  FLsNet := FNetSel;
  FLsA := Point(FCellC, FCellR);
  FLsB := FLsA;
end;

{ the cell under a point of network NI (outside: the nearest one) }
procedure TPlcUI.CellAt(NI: Integer; X, Y: Single; out R, C: Integer);
var
  K: Integer;
begin
  C := 0;
  R := 0;
  if (NI < 0) or (NI >= Length(FLadTops)) or (Length(FLadTops[NI]) < 2) or (NI >= Length(FLadX0)) then Exit;
  // right of the last column: a new column (moving cells there adds it)
  C := EnsureRange(Floor((X - FLadX0[NI]) / Max(1, FLadCW)), 0, CurBlock.Net(NI).Cols);
  for K := 0 to High(FLadTops[NI]) - 1 do
    if Y >= FLadTops[NI][K] then R := K;
  // below the last row: a new row (moving cells there adds it)
  if Y >= FLadTops[NI][High(FLadTops[NI])] then R := High(FLadTops[NI]);
end;

procedure TPlcUI.LadUndoPoint(N: TNetwork);
begin
  // the change that comes is a step of its own
  FPKind := 0;
end;

procedure TPlcUI.LadUndo(Redo: Boolean);
begin
  ProgUndo(Redo);
end;

function TPlcUI.UndoCount: Integer;
begin
  Result := Length(FPUndo);
end;

function TPlcUI.RedoCount: Integer;
begin
  Result := Length(FPRedo);
end;

procedure TPlcUI.UndoPublic(Redo: Boolean);
begin
  ProgUndo(Redo);
end;

function TPlcUI.ProgSnap: TProgSnap;
begin
  Result.Json := Project.ToJsonText(False);
  Result.Scr := Screen;
  Result.Blk := FBlockSel;
  Result.Net := FNetSel;
  Result.StlNet := FStlNet;
  if (FStlNet >= 0) and (FEdNet <> nil) then
  begin
    Result.StlRow := FEd.Caret.Row;
    Result.StlCol := FEd.Caret.Col;
  end
  else
  begin
    Result.StlRow := FStlRow;
    Result.StlCol := FStlCol;
  end;
end;

procedure TPlcUI.ProgUndoReset;
begin
  SetLength(FPUndo, 0);
  SetLength(FPRedo, 0);
  FPBase.Json := '';
  FPPending := False;
  FPLastKind := 0;
  FPKind := 0;
end;

procedure TPlcUI.ProgCommit;
var
  Now: TProgSnap;
  Join: Boolean;
  K: Integer;
begin
  if FPBase.Json = '' then
  begin
    FPBase := ProgSnap;
    FPPending := False;
    Exit;
  end;
  if not FPPending then Exit;
  FPPending := False;
  Now := ProgSnap;
  if Now.Json = FPBase.Json then Exit;
  // typing on the same line within 3 s joins the step before it (like a typed word)
  Join := (FPKind > 0) and (FPKind = FPLastKind) and (FPNet = FPLastNet) and (FPRow = FPLastRow) and
    (FTime - FPTime < 3) and (Length(FPUndo) > 0);
  if not Join then
  begin
    if Length(FPUndo) >= 200 then
    begin
      for K := 0 to High(FPUndo) - 1 do FPUndo[K] := FPUndo[K + 1];
      SetLength(FPUndo, High(FPUndo));
    end;
    SetLength(FPUndo, Length(FPUndo) + 1);
    FPUndo[High(FPUndo)] := FPBase;
    FPUndo[High(FPUndo)].Scr := Screen;   // where the change was made: undo shows it there
  end;
  SetLength(FPRedo, 0);
  FPLastKind := FPKind;
  FPLastNet := FPNet;
  FPLastRow := FPRow;
  FPTime := FTime;
  FPKind := 0;
  FPBase := Now;
end;

procedure TPlcUI.ProgUndo(Redo: Boolean);
var
  E: TProgSnap;
  Cm: TCommSettings;
  Fn: string;
  Mi: Integer;
begin
  EndEdit(True);
  ProgCommit;
  if Redo then
  begin
    if Length(FPRedo) = 0 then Exit;
    E := FPRedo[High(FPRedo)];
    SetLength(FPRedo, High(FPRedo));
    SetLength(FPUndo, Length(FPUndo) + 1);
    FPUndo[High(FPUndo)] := FPBase;
    FPUndo[High(FPUndo)].Scr := E.Scr;
  end
  else
  begin
    if Length(FPUndo) = 0 then Exit;
    E := FPUndo[High(FPUndo)];
    SetLength(FPUndo, High(FPUndo));
    SetLength(FPRedo, Length(FPRedo) + 1);
    FPRedo[High(FPRedo)] := FPBase;
    FPRedo[High(FPRedo)].Scr := E.Scr;
  end;
  // the project comes back; its file and the ports (switched on the Ports screen) stay as they are
  Fn := Project.FileName;
  Cm := Project.Comm;
  Mi := Project.ModelIdx;
  try
    Project.LoadFromJsonText(E.Json);
  except
    on Ex: Exception do
    begin
      Toast('Undo failed: ' + Ex.Message, True);
      Exit;
    end;
  end;
  Project.FileName := Fn;
  Project.Comm := Cm;
  if Project.ModelIdx <> Mi then SyncModel;
  // no pointer into the old blocks stays
  FEdNet := nil;
  FCompOpen := False;
  SetLength(FHScroll, 0);
  FLsNet := -1;
  FLadMode := 0;
  FLadOff := Point(0, 0);
  FBlockSel := EnsureRange(E.Blk, 0, Max(0, Project.BlockCount - 1));
  if Project.BlockCount > 0 then
    FNetSel := EnsureRange(E.Net, 0, Max(0, Project.Block(FBlockSel).NetCount - 1))
  else
    FNetSel := 0;
  FStlNet := E.StlNet;
  if (FStlNet >= 0) and ((Project.BlockCount = 0) or (FStlNet >= Project.Block(FBlockSel).NetCount)) then FStlNet := -1;
  FStlRow := E.StlRow;
  FStlCol := E.StlCol;
  FCellR := 0;
  FCellC := 0;
  FScrollToCaret := FStlNet >= 0;
  if E.Scr <> Screen then Screen := E.Scr;
  ResetResolver;
  InvalidateStatic;
  MarkDirty;
  FPPending := False;
  FPBase := E;
  FPLastKind := 0;
  if Redo then Toast('Redo') else Toast('Undo');
end;

procedure TPlcUI.LadCopy(Cut: Boolean);
var
  N: TNetwork;
  R, C, R1, C1, R2, C2: Integer;
begin
  N := CurNet;
  if (N = nil) or (N.Kind <> nkLAD) then Exit;
  LadSel(R1, C1, R2, C2);
  SetLength(FLadClip, R2 - R1 + 1, C2 - C1 + 1);
  for R := R1 to R2 do
    for C := C1 to C2 do FLadClip[R - R1][C - C1] := N.Cell(R, C);
  if Cut then
  begin
    LadUndoPoint(N);
    for R := R1 to R2 do
      for C := C1 to C2 do N.SetCell(R, C, EmptyCell);
    LadFillWires(N, R1, C1, R2, C2);
    MarkDirty;
  end;
  Toast(Format('%d x %d cells %s', [C2 - C1 + 1, R2 - R1 + 1, IfThen(Cut, 'cut', 'copied')]));
end;

{ Paste inserts: in every row of the pasted block the cells from the paste column on move right by
  its width, then the copied cells fill the gap; the network gets the columns / rows it needs }
procedure TPlcUI.LadPaste;
var
  N: TNetwork;
  R, C, R0, C0, H, W, R1, C1, R2, C2, Need, Last: Integer;
begin
  N := CurNet;
  if (N = nil) or (N.Kind <> nkLAD) or (Length(FLadClip) = 0) then Exit;
  // at the top left of the selection (or the focus cell)
  LadSel(R1, C1, R2, C2);
  R0 := R1;
  C0 := C1;
  H := Length(FLadClip);
  W := Length(FLadClip[0]);
  if R0 + H > MaxLadRows then
  begin
    Toast(Format('a network has at most %d rows', [MaxLadRows]), True);
    Exit;
  end;
  // the columns it needs: the moved cells of every row, the block, one free column on the right
  Need := C0 + W;
  for R := R0 to Min(R0 + H, N.Rows) - 1 do
  begin
    Last := -1;
    for C := C0 to N.Cols - 1 do
      if (N.Cell(R, C).Kind <> lkEmpty) or N.Cell(R, C).Down then Last := C;
    if Last >= 0 then Need := Max(Need, Last + W + 1);
  end;
  if Need > MaxLadCols then
  begin
    Toast(Format('no room: a network has at most %d columns', [MaxLadCols]), True);
    Exit;
  end;
  LadUndoPoint(N);
  if R0 + H > N.Rows then N.SetRows(R0 + H);
  if Need + 1 > N.Cols then N.SetCols(Min(MaxLadCols, Need + 1));
  for R := 0 to H - 1 do
  begin
    for C := N.Cols - 1 downto C0 + W do N.SetCell(R0 + R, C, N.Cell(R0 + R, C - W));
    for C := 0 to W - 1 do N.SetCell(R0 + R, C0 + C, FLadClip[R][C]);
  end;
  FLsNet := FNetSel;
  FLsA := Point(C0, R0);
  FLsB := Point(C0 + W - 1, R0 + H - 1);
  FCellR := R0;
  FCellC := C0;
  FLadFollow := True;
  LadKeepBoxes(N);
  MarkDirty;
end;

function TPlcUI.LadNetAt(Y: Single): Integer;
var
  K: Integer;
begin
  Result := -1;
  if CurBlock = nil then Exit;
  for K := 0 to Min(High(FLadTops), High(FLadSeen)) do
    if (FLadSeen[K] = FTime) and (K < CurBlock.NetCount) and (CurBlock.Net(K).Kind = nkLAD) and
      (Length(FLadTops[K]) >= 2) and (Y >= FLadTops[K][0]) and (Y < FLadTops[K][High(FLadTops[K])]) then
      Exit(K);
end;

function TPlcUI.LadTarget(out TN, TR, TC: Integer): Boolean;
var
  R1, C1, R2, C2: Integer;
begin
  TN := FNetSel;
  TR := 0;
  TC := 0;
  Result := False;
  if (FLadMode <> 2) or (FLadDropNet = -2) or (CurNet = nil) or (CurNet.Kind <> nkLAD) then Exit;
  LadSel(R1, C1, R2, C2);
  if FLadDropNet < 0 then
  begin
    TR := R1 + FLadOff.Y;
    TC := C1 + FLadOff.X;
  end
  else
  begin
    TN := FLadDropNet;
    TR := FLadDropAt.Y - (FLadPress.Y - R1);
    TC := FLadDropAt.X - (FLadPress.X - C1);
  end;
  Result := (CurBlock <> nil) and (TN >= 0) and (TN < CurBlock.NetCount);
end;

function TPlcUI.LadDropOk(TN, TR, TC: Integer): Boolean;
var
  T: TNetwork;
  R, C, R1, C1, R2, C2, Row, Col: Integer;
begin
  Result := False;
  if (CurBlock = nil) or (TN < 0) or (TN >= CurBlock.NetCount) then Exit;
  T := CurBlock.Net(TN);
  if T.Kind <> nkLAD then Exit;
  LadSel(R1, C1, R2, C2);
  for R := 0 to R2 - R1 do
    for C := 0 to C2 - C1 do
    begin
      Row := TR + R;
      Col := TC + C;
      if (Row < 0) or (Row >= T.Rows) or (Col < 0) or (Col >= T.Cols) then Exit;
      // its own cells move away (in its own network)
      if (TN = FNetSel) and (Row >= R1) and (Row <= R2) and (Col >= C1) and (Col <= C2) then Continue;
      if T.Cell(Row, Col).Kind = lkEmpty then Exit;
    end;
  Result := True;
end;

{ the selection goes into another network of the block: where it lands only on wires they are
  replaced, else the cells there move right to make room (an insert); in its own network the cells
  it left become wires where the rung goes through them (like a delete) }
procedure TPlcUI.LadMoveTo(TN, TR, TC: Integer);
var
  S, T: TNetwork;
  R, C, K, R1, C1, R2, C2, H, W, Last, Room: Integer;
  Buf: array of array of TLadCell;
  Wires: array of Boolean;
  Ce: TLadCell;
begin
  S := CurNet;
  if (S = nil) or (CurBlock = nil) or (TN < 0) or (TN >= CurBlock.NetCount) then Exit;
  T := CurBlock.Net(TN);
  LadSel(R1, C1, R2, C2);
  H := R2 - R1 + 1;
  W := C2 - C1 + 1;
  SetLength(Wires, H);
  for R := 0 to H - 1 do
  begin
    Wires[R] := True;
    for C := 0 to W - 1 do
      if T.Cell(TR + R, TC + C).Kind <> lkWire then Wires[R] := False;
    if not Wires[R] then
    begin
      Last := -1;
      for C := 0 to T.Cols - 1 do
        if (T.Cell(TR + R, C).Kind <> lkEmpty) or T.Cell(TR + R, C).Down then Last := C;
      if Last + W + 1 > MaxLadCols then
      begin
        Toast(Format('no room: a network has at most %d columns', [MaxLadCols]), True);
        Exit;
      end;
    end;
  end;
  LadUndoPoint(S);
  SetLength(Buf, H, W);
  for R := 0 to H - 1 do
    for C := 0 to W - 1 do Buf[R][C] := S.Cell(R1 + R, C1 + C);
  // out of its own network (its branch lines stay there)
  for R := R1 to R2 do
    for C := C1 to C2 do
    begin
      Ce := EmptyCell;
      Ce.Down := S.Cell(R, C).Down;
      S.SetCell(R, C, Ce);
    end;
  LadFillWires(S, R1, C1, R2, C2);
  // into the other one
  for R := 0 to H - 1 do
  begin
    if not Wires[R] then
      for K := 1 to W do
      begin
        // room for one cell at TC: a wire further on in the row takes it (the cells between move one
        // right), else the whole rest of the row moves right
        Room := -1;
        for C := TC to T.Cols - 1 do
        begin
          if T.Cell(TR + R, C).Down or ((TR + R > 0) and T.Cell(TR + R - 1, C).Down) then Break;
          if T.Cell(TR + R, C).Kind = lkWire then
          begin
            Room := C;
            Break;
          end;
        end;
        if Room < 0 then
        begin
          Last := -1;
          for C := 0 to T.Cols - 1 do
            if (T.Cell(TR + R, C).Kind <> lkEmpty) or T.Cell(TR + R, C).Down then Last := C;
          if Last + 2 > T.Cols then T.SetCols(Min(MaxLadCols, Last + 2));
          Room := T.Cols - 1;
        end;
        for C := Room downto TC + 1 do T.SetCell(TR + R, C, T.Cell(TR + R, C - 1));
        T.SetCell(TR + R, TC, EmptyCell);
      end;
    for C := 0 to W - 1 do
    begin
      Ce := Buf[R][C];
      // one row: the branch lines of the place stay; a block brings its own
      if H = 1 then Ce.Down := Wires[R] and T.Cell(TR + R, TC + C).Down;
      T.SetCell(TR + R, TC + C, Ce);
    end;
  end;
  LadKeepBoxes(S);
  LadKeepBoxes(T);
  FNetSel := TN;
  FStlNet := -1;
  FLsNet := TN;
  FLsA := Point(TC, TR);
  FLsB := Point(TC + W - 1, TR + H - 1);
  FCellR := TR;
  FCellC := TC;
  MarkDirty;
end;

procedure TPlcUI.DrawLadGhost;
var
  K: Integer;
  GX, GY: Single;
  DropC: TBGRAPixel;
begin
  if FLadMode <> 2 then Exit;
  if FGhostOn then
  begin
    // a shadow, the cells at 60 %, a frame, where the mouse is now
    GX := FMX - FLadPressM.X;
    GY := FMY - FLadPressM.Y;
    D.Layer := lyOverlay;
    with FGhostR do
    begin
      Shad(Left + GX, Top + GY, Right - Left, Bottom - Top, 5, 4, 10, 60);
      RR(Left + GX, Top + GY, Right - Left, Bottom - Top, 5, Alpha(cSheet, 150));
    end;
    for K := 0 to High(FGhostI) do
      D.Ghost(FGhostI[K].X, FGhostI[K].Y, PX(FMX) - PX(FLadPressM.X), PY(FMY) - PY(FLadPressM.Y), 160, lyOverlay);
    D.Layer := lyOverlay;
    with FGhostR do
      RRL(Left + GX, Top + GY, Right - Left, Bottom - Top, 5, 1.4, Alpha(cGoldDark, 200));
  end;
  if FDropOn then
    with FDropR do
    begin
      if FDropOk then DropC := cRed else DropC := cInkSoft;
      D.Layer := lyOverlay;
      Rc(Left, Top, Right - Left, Bottom - Top, Alpha(DropC, 30));
      DashLn(Left, Top, Right, Top, 1.6, 5, DropC);
      DashLn(Left, Bottom, Right, Bottom, 1.6, 5, DropC);
      DashLn(Left, Top, Left, Bottom, 1.6, 5, DropC);
      DashLn(Right, Top, Right, Bottom, 1.6, 5, DropC);
      if not FDropOk then Txt(fkUIB, 10.5, Left + 6, Bottom - 18, 'no wire here', cRedDark);
    end;
end;

function TPlcUI.StlMenu(Id: Integer): Boolean;
var
  K, NI, Row0, Row, Col: Integer;
  N: TNetwork;
  P, A, B: TTextPos;
  R: TRectF;
  CharW: Single;
begin
  Result := False;
  NI := (Id and $FFFF) div 1024;
  Row0 := (Id and $FFFF) mod 1024;
  if (CurBlock = nil) or (NI >= CurBlock.NetCount) or not (CurBlock.Net(NI).Kind in [nkSTL, nkSCL]) then Exit;
  R := RectF(0, 0, 0, 0);
  for K := FLastHitN - 1 downto 0 do
    if FLastHits[K].Id = Id then
    begin
      R := FLastHits[K].R;
      Break;
    end;
  // the place of the mouse in the text, as a click finds it
  CharW := Max(1, TxtW(fkMono, 13, 'M'));
  Row := Row0 + Floor((FMY - R.Top) / 19);
  Col := Max(0, Round((FMX - R.Left - 44) / CharW));
  FCompOpen := False;
  FHelpFocus := False;
  FNetSel := NI;
  N := CurNet;
  Row := EnsureRange(Row, 0, Max(0, N.Stl.Count - 1));
  // right of the line end: at its end
  if Row < N.Stl.Count then Col := Min(Col, UTF8Length(N.Stl[Row])) else Col := 0;
  P := FEd.TP(Row, Col);
  // inside the selection it stays (Copy / Cut take it), elsewhere the caret goes to the mouse
  if (FEdNet = N) and (FStlNet = NI) and FEd.HasSel then
  begin
    A := FEd.Anchor;
    B := FEd.Caret;
    if (B.Row < A.Row) or ((B.Row = A.Row) and (B.Col < A.Col)) then
    begin
      A := FEd.Caret;
      B := FEd.Anchor;
    end;
    if ((P.Row > A.Row) or ((P.Row = A.Row) and (P.Col >= A.Col))) and
      ((P.Row < B.Row) or ((P.Row = B.Row) and (P.Col <= B.Col))) then
      Exit(True);
  end;
  FStlNet := NI;
  FStlRow := EnsureRange(Row, 0, Max(0, N.Stl.Count - 1));
  FStlCol := Col;
  N := EdBegin;
  if N <> nil then
  begin
    FEd.Caret := FEd.TP(FStlRow, FStlCol);
    FEd.Collapse;
    EdEnd(N);
  end;
  Result := True;
end;

function TPlcUI.NetHasCodePublic(N: TNetwork): Boolean;
begin
  Result := NetHasCode(N);
end;

function TPlcUI.NetHasCode(N: TNetwork): Boolean;
var
  R, C: Integer;
begin
  Result := False;
  if N = nil then Exit;
  if N.Kind = nkLAD then
  begin
    for R := 0 to N.Rows - 1 do
      for C := 0 to N.Cols - 1 do
        if (N.Cell(R, C).Kind <> lkEmpty) or N.Cell(R, C).Down then Exit(True);
  end
  else
    Result := Trim(N.Stl.Text) <> '';
end;

procedure TPlcUI.LadDeleteSel;
var
  N: TNetwork;
  R, C, R1, C1, R2, C2: Integer;
  Ce: TLadCell;
begin
  N := CurNet;
  if (N = nil) or (N.Kind <> nkLAD) then Exit;
  LadSel(R1, C1, R2, C2);
  LadUndoPoint(N);
  for R := R1 to R2 do
    for C := C1 to C2 do
    begin
      // the branch link stays (like deleting one element)
      Ce := EmptyCell;
      Ce.Down := N.Cell(R, C).Down;
      N.SetCell(R, C, Ce);
    end;
  LadFillWires(N, R1, C1, R2, C2);
  MarkDirty;
end;

{ after a delete / cut: an emptied cell becomes a wire where the rung goes through it, so the elements
  left and right stay connected. Not where nothing follows on the right (the end of a rung), and not in
  a branch whose only element went (a wire there would short the contact it parallels: it stays open) }
procedure TPlcUI.LadFillWires(N: TNetwork; R1, C1, R2, C2: Integer);
var
  R, C, K: Integer;
  Left, Right: Boolean;
  Ce: TLadCell;

  function Link(Row, Col: Integer): Boolean;
  begin
    // a branch line at the right edge of the cell: its own, or one from the row above
    Result := (Col >= 0) and (N.Cell(Row, Col).Down or ((Row > 0) and N.Cell(Row - 1, Col).Down));
  end;

  function Element(Row, A, B: Integer): Boolean;
  var
    J: Integer;
  begin
    Result := False;
    for J := Max(0, A) to Min(N.Cols - 1, B) do
      if not (N.Cell(Row, J).Kind in [lkEmpty, lkWire]) then Exit(True);
  end;

begin
  for R := R1 to Min(R2, N.Rows - 1) do
    for C := C1 to Min(C2, N.Cols - 1) do
    begin
      if N.Cell(R, C).Kind <> lkEmpty then Continue;
      // power from the left: the rail, a cell, or a branch line
      Left := (C = 0) or (N.Cell(R, C - 1).Kind <> lkEmpty) or Link(R, C - 1);
      // and on the right: more of the rung, or a branch line that closes after an element of this row
      Right := False;
      for K := C + 1 to N.Cols - 1 do
        if N.Cell(R, K).Kind <> lkEmpty then
        begin
          Right := True;
          Break;
        end;
      if not Right and Link(R, C) then Right := Element(R, 0, C - 1);
      if Right and not Element(R, 0, N.Cols - 1) and (R > 0) then Right := False;
      if Left and Right then
      begin
        Ce := NewCell(lkWire, '');
        Ce.Down := N.Cell(R, C).Down;
        N.SetCell(R, C, Ce);
      end;
    end;
end;

{ the selection moves DC columns, DR rows (the button went up); the place must be free }
procedure TPlcUI.LadMove(DC, DR: Integer);
var
  N: TNetwork;
  R, C, R1, C1, R2, C2: Integer;
  KeepDown: Boolean;

  // the cells from A to B go D places along the line; the ones they land on slide into the place they
  // left (an insert, like moving an item in a list; next to each other it is a swap). One row
  // selected: the branch lines (Down) stay where they are, so the rung keeps its shape; a block of
  // rows takes its lines with it
  procedure Slide(Horiz: Boolean; Line, A, B, D: Integer);
  var
    L: array of TLadCell;
    K, S, E, M: Integer;
    Ce: TLadCell;

    function Get(P: Integer): TLadCell;
    begin
      if Horiz then Result := N.Cell(Line, P) else Result := N.Cell(P, Line);
    end;

  begin
    if D > 0 then
    begin
      S := A;
      E := B + D;
    end
    else
    begin
      S := A + D;
      E := B;
    end;
    SetLength(L, E - S + 1);
    M := 0;
    if D > 0 then
    begin
      for K := B + 1 to E do begin L[M] := Get(K); Inc(M); end;
      for K := A to B do begin L[M] := Get(K); Inc(M); end;
    end
    else
    begin
      for K := A to B do begin L[M] := Get(K); Inc(M); end;
      for K := S to A - 1 do begin L[M] := Get(K); Inc(M); end;
    end;
    for K := S to E do
    begin
      Ce := L[K - S];
      if KeepDown then Ce.Down := Get(K).Down;
      if Horiz then N.SetCell(Line, K, Ce) else N.SetCell(K, Line, Ce);
    end;
  end;

begin
  N := CurNet;
  if (N = nil) or (N.Kind <> nkLAD) then Exit;
  LadSel(R1, C1, R2, C2);
  if (C1 + DC < 0) or (C2 + DC >= MaxLadCols) or (R1 + DR < 0) or (R2 + DR >= MaxLadRows) then
  begin
    Toast('outside the network', True);
    Exit;
  end;
  LadUndoPoint(N);
  if R2 + DR >= N.Rows then N.SetRows(R2 + DR + 1);
  // to the right: more columns, one more stays free
  if C2 + DC + 1 >= N.Cols then N.SetCols(Min(MaxLadCols, C2 + DC + 2));
  KeepDown := R1 = R2;
  // along the rows first, then (in the new columns) along the columns
  if DC <> 0 then
    for R := R1 to R2 do Slide(True, R, C1, C2, DC);
  if DR <> 0 then
    for C := C1 + DC to C2 + DC do Slide(False, C, R1, R2, DR);
  LadKeepBoxes(N);
  FLsNet := FNetSel;
  FLsA := Point(C1 + DC, R1 + DR);
  FLsB := Point(C2 + DC, R2 + DR);
  FCellR := FCellR + DR;
  FCellC := FCellC + DC;
  MarkDirty;
end;

procedure TPlcUI.DoDragEnd(Id: Integer; X, Y: Single);
var
  N: TNetwork;
  Ce: TLadCell;
  TN, TR, TC, R1, C1, R2, C2: Integer;
begin
  FVsDrag := -1;
  if Id shr 16 = acCell then
  begin
    if (FLadMode = 2) and LadTarget(TN, TR, TC) then
    begin
      LadSel(R1, C1, R2, C2);
      if (TN <> FNetSel) or (TR <> R1) or (TC <> C1) then
      begin
        // a drop needs a wire (or an element of a rung) under every cell it brings
        if not LadDropOk(TN, TR, TC) then
          Toast('no wire there: drop onto a wire or an element of a rung', True)
        else if TN = FNetSel then LadMove(TC - C1, TR - R1)
        else LadMoveTo(TN, TR, TC);
      end;
    end;
    FLadMode := 0;
    FLadOff := Point(0, 0);
    FLadDropNet := -1;
    Exit;
  end;
  if (Id shr 16 = acHelp) and (FHelpMode = 2) and not FVarDragOn then
  begin
    FHelp0 := HelpPosAt(X, Y);
    FHelp1 := FHelp0;
  end;
  if Id shr 16 = acElem then
  begin
    if not FVarDragOn then FElemPress := -1;
  end
  else if (Id shr 16 <> acIfDrag) and not ((Id shr 16 = acHelp) and (FHelpMode = 2)) then Exit;
  if FVarDragOn then
  begin
    if FDropKind = 1 then
    begin
      // the name goes into the text where it was dropped
      FNetSel := FDropNet;
      FStlNet := FDropNet;
      N := CurNet;
      if (N <> nil) and (N.Kind in [nkSTL, nkSCL]) then
      begin
        FStlRow := Min(FDropRow, Max(0, N.Stl.Count - 1));
        FStlCol := FDropCol;
        N := EdBegin;
        if N <> nil then
        begin
          FEd.Caret.Col := Min(FDropCol, FEd.LineLen(FEd.Caret.Row));
          FEd.Collapse;
          EdUndoPoint(N, 0);
          if (Id shr 16 = acElem) and (FElemPress >= 0) and (FElemPress <= High(FElems)) then
            ElemPut(FElems[FElemPress].Snip)
          else
            FEd.InsertText(FVarDrag);
          EdEnd(N);
        end;
      end;
    end
    else if FDropKind = 2 then
    begin
      // onto a LAD element: its operand
      FNetSel := FDropNet;
      FStlNet := -1;
      N := CurNet;
      if (N <> nil) and (N.Kind = nkLAD) then
      begin
        LadUndoPoint(N);
        Ce := N.Cell(FDropRow, FDropCol);
        Ce.Opnd := FVarDrag;
        N.SetCell(FDropRow, FDropCol, Ce);
        FCellR := FDropRow;
        FCellC := FDropCol;
        LadCollapse;
        MarkDirty;
      end;
    end
    else if (FDropKind = 3) and (Id shr 16 = acElem) then
    begin
      // an element of the LAD list into the cell where it was dropped
      FNetSel := FDropNet;
      FStlNet := -1;
      N := CurNet;
      if (N <> nil) and (N.Kind = nkLAD) then
      begin
        FCellR := FDropRow;
        FCellC := FDropCol;
        LadCollapse;
        ElemInsert(FElemPress);
      end;
    end;
  end;
  FVarDragOn := False;
  FDropKind := 0;
end;

procedure TPlcUI.BuildProgram;
var
  B: TBlock;
  I: Integer;
  Y, H, Top, ViewH, BH, CT, CB: Single;
  Sel: Boolean;
  S, St: string;
  C: TBGRAPixel;
begin
  // ---------- blocks: the list and its buttons scroll when they do not fit ----------
  BH := Project.BlockCount * 48 + 8 + 3 * 34 + 28 + 6;
  if Project.FindBlock(bkOB, 1) = nil then BH := BH + 34;
  if Project.FindBlock(bkOB, Project.CyclicOB) = nil then BH := BH + 34;
  if Project.FindBlock(bkOB, 100) = nil then BH := BH + 34;
  FBlockScroll := EnsureRange(FBlockScroll, 0, Max(0, BH - 666));
  ClipD(28, 112, 210, 668);
  Hit(28, 112, 210, 668, whBlocks, hkWheel);
  for I := 0 to Project.BlockCount - 1 do
  begin
    B := Project.Block(I);
    Y := 118 + I * 48 - FBlockScroll;
    Sel := I = FBlockSel;
    D.Layer := lySheets;
    if Sel then
    begin
      Shad(36, Y, 188, 42, 5, 2, 4, 80);
      RR(36, Y, 188, 42, 5, cRed);
      D.Layer := lyOrnament;
      RRL(39, Y + 3, 182, 36, 4, 0.8, cGoldLight);
    end
    else if Hot(36, Y, 188, 42) then RR(36, Y, 188, 42, 5, Mixc(cSheet2, cWhite, 0.3))
    else RR(36, Y, 188, 42, 5, cSheet2);
    D.Layer := lyText;
    if Sel then C := cSheet else C := cRedDark;
    Txt(fkUIB, 14, 48, Y + 3, B.Title, C);
    if Sel then C := cGoldLight else C := cInkSoft;
    TxtFit(fkUI, 11, 48, Y + 22, 170, B.Name + Format('  (%d nw)', [B.NetCount]), C);
    Hit(36, Y, 188, 42, Act(acBlockSel, I));
  end;
  Y := 118 + Project.BlockCount * 48 + 8 - FBlockScroll;
  if Project.FindBlock(bkOB, 1) = nil then
  begin
    Button(36, Y, 188, 28, '+ OB1 Main', Act(acAddOB1, 0), bsPrimary, True, 12);
    Y := Y + 34;
  end;
  Button(36, Y, 188, 28, '+ FC (function)', Act(acAddFC, 0), bsNormal, True, 12);
  Y := Y + 34;
  Button(36, Y, 188, 28, '+ FB (function block)', Act(acAddFB, 0), bsNormal, True, 12);
  Y := Y + 34;
  if Project.FindBlock(bkOB, Project.CyclicOB) = nil then
  begin
    Button(36, Y, 188, 28, Format('+ OB%d cyclic', [Project.CyclicOB]), Act(acAddCyc, 0), bsNormal, True, 12);
    Y := Y + 34;
  end;
  if Project.FindBlock(bkOB, 100) = nil then
  begin
    Button(36, Y, 188, 28, '+ OB100 startup', Act(acAddStartup, 0), bsNormal, True, 12);
    Y := Y + 34;
  end;
  Button(36, Y, 188, 28, 'Delete block', Act(acDelBlock, 0), bsFlat, Project.BlockCount > 0, 12);
  Y := Y + 40;
  // .scl sources (TIA), the views of the project
  Button(36, Y, 188, 28, 'SCL source ▼', Act(acSclSrcMenu, 0), bsGold, True, 12);
  UnclipD;
  if BH > 668 then VScrollBar(2, 228, 112, 668, BH, 668, FBlockScroll) else FVs[2].Range := 0;
  B := CurBlock;
  if B <> nil then
  begin
    D.Layer := lyText;
    Txt(fkUI, 10, 36, 790, 'block name', cInkSoft);
    Field(36, 806, 188, 24, Act(fdBlockName, 0), B.Name, fkUI, 12);
  end;

  // ---------- editor ----------
  if B = nil then
  begin
    Txt(fkUI, 14, 290, 140, 'No block. Add OB1 on the left.', cInkSoft);
    Exit;
  end;
  // a new network goes above or below the selected one (the menu asks)
  Button(280, 112, 92, 28, '+ LAD network', Act(acAddMenu, 0), bsNormal, True, 11);
  Button(376, 112, 92, 28, '+ STL network', Act(acAddMenu, 1), bsNormal, Project.Family <> cfS71200, 11);
  Button(472, 112, 92, 28, '+ SCL network', Act(acAddMenu, 2), bsNormal, True, 11);
  if FMonitor then Button(568, 112, 86, 28, 'Monitor: on', Act(acMonitor, 0), bsToggleOn, True, 11)
  else Button(568, 112, 86, 28, 'Monitor', Act(acMonitor, 0), bsNormal, True, 11);
  Button(658, 112, 70, 28, 'Compile', Act(acCompile, 0), bsNormal, True, 11);
  Button(732, 112, 84, 28, 'Download', Act(acDownload, 0), bsPrimary, True, 11);
  if FClaudeMenu or FChatOpen then Button(820, 112, 60, 28, 'AI ▼', Act(acClaude, 0), bsToggleOn, True, 11)
  else Button(820, 112, 60, 28, 'AI ▼', Act(acClaude, 0), bsGold, True, 11);
  // undo / redo of every change (Ctrl+Z, Ctrl+Y)
  Button(886, 112, 58, 28, 'Undo', Act(acUndo, 0), bsNormal, Length(FPUndo) > 0, 11);
  Button(948, 112, 58, 28, 'Redo', Act(acRedo, 0), bsNormal, Length(FPRedo) > 0, 11);
  D.Layer := lyText;
  if FDirty then
  begin
    if FMonitor then St := 'changed: download to monitor' else St := 'offline changed: download';
    C := cRed;
  end
  else if Rt.Prog = nil then
  begin
    St := 'not downloaded';
    C := cRed;
  end
  else
  begin
    St := 'offline = online';
    C := cJade;
  end;
  D.Layer := lyControls;
  El(1018, 126, 5, 5, C);
  D.Layer := lyText;
  // "offline changed: download" in two short lines
  if Pos(': ', St) > 0 then
  begin
    TxtFit(fkUIB, 10.5, 1028, 110, 104, Copy(St, 1, Pos(': ', St) - 1), C);
    TxtFit(fkUI, 10.5, 1028, 124, 104, Copy(St, Pos(': ', St) + 2, MaxInt), C);
  end
  else
    TxtFit(fkUIB, 10.5, 1028, 117, 104, St, C);
  // the block at the top right: its name and its version (as in the SCL source), both edited here
  TxtFit(fkUIB, 12, 1136, 104, 34, B.Title, cRedDark);
  Field(1172, 101, 112, 21, Act(fdBlockName, 1), B.Name, fkUIB, 11.5);
  Txt(fkUI, 9.5, 1136, 126, 'Version', cInkSoft);
  Field(1180, 124, 50, 18, Act(fdBlockVer, 0), B.Version, fkMono, 10);
  // networks
  Top := 150;
  ViewH := 700;
  if (FFindMode > 0) and (FStlNet >= 0) then ViewH := 654;
  FProgContent := IfaceHeight(B);
  for I := 0 to B.NetCount - 1 do FProgContent := FProgContent + NetHeight(B.Net(I));
  if FScrollToCaret and (FNetSel >= 0) and (FNetSel < B.NetCount) then
  begin
    // the caret line (text networks) or the network head into view
    H := IfaceHeight(B);
    for I := 0 to FNetSel - 1 do H := H + NetHeight(B.Net(I));
    if (FStlNet = FNetSel) and (B.Net(FNetSel).Kind in [nkSTL, nkSCL]) then H := H + 54 + 5 + FStlRow * 19 + 8;
    if H - FProgScroll < 20 then FProgScroll := H - 20
    else if (B.Net(FNetSel).Kind = nkLAD) and (FStlNet < 0) and (H + NetHeight(B.Net(FNetSel)) - FProgScroll > ViewH - 10) then
      // a LAD network: all of it (as far as the head stays in view)
      FProgScroll := Min(H - 20, H + NetHeight(B.Net(FNetSel)) - ViewH + 40)
    else if H - FProgScroll > ViewH - 50 then FProgScroll := H - ViewH + 60;
    if (B.Net(FNetSel).Kind = nkLAD) and (FStlNet < 0) then
    begin
      // the selected cell itself: its row between the frame's top and bottom
      CT := H + 52;
      for I := 0 to Min(FCellR, B.Net(FNetSel).Rows) - 1 do CT := CT + RowHeight(B.Net(FNetSel), I);
      CB := CT + RowHeight(B.Net(FNetSel), Min(FCellR, B.Net(FNetSel).Rows - 1));
      if CB - FProgScroll > ViewH - 16 then FProgScroll := CB - ViewH + 16;
      if CT - FProgScroll < 4 then FProgScroll := CT - 4;
    end;
    FScrollToCaret := False;
  end;
  FProgScroll := EnsureRange(FProgScroll, 0, Max(0, FProgContent - ViewH + 40));
  ClipD(270, Top, 1014, ViewH);
  Hit(270, Top, 1014, ViewH, whProg, hkWheel);
  Y := Top + 8 - FProgScroll;
  if B.Kind <> bkOB then
  begin
    if (Y + IfaceHeight(B) > Top - 10) and (Y < Top + ViewH + 10) then DrawIface(B, 276, Y, 1002);
    Y := Y + IfaceHeight(B);
  end;
  FGhostOn := False;
  FDropOn := False;
  for I := 0 to B.NetCount - 1 do
  begin
    H := NetHeight(B.Net(I));
    if (Y + H > Top - 10) and (Y < Top + ViewH + 10) then
      DrawNetwork(I, B.Net(I), 276, Y, 1002, H)
    else
      ;
    Y := Y + H;
  end;
  if B.NetCount = 0 then
  begin
    D.Layer := lyText;
    Txt(fkUI, 14, 300, Top + 30, 'No networks: add a LAD or STL network above.', cInkSoft);
  end;
  DrawLadGhost;
  UnclipD;
  if (FFindMode > 0) and (FStlNet >= 0) then DrawFindBar(276, Top + ViewH + 6, 1002);
  DrawComp;
  DrawDrag;
  DrawMenu;
  // scroll bar: the thumb drags, a click on the track brings the thumb there
  if FProgContent + 40 > ViewH then VScrollBar(0, 1283, Top, ViewH, FProgContent + 40, ViewH, FProgScroll)
  else FVs[0].Range := 0;

  // ---------- palette and properties ----------
  if (CurNet <> nil) and (CurNet.Kind = nkLAD) then
  begin
    // the LAD elements: the same list as SCL / STL, the properties of the cell below it
    D.Layer := lyText;
    Txt(fkUIB, 12, 1328, 104, 'LAD elements', cRedDark);
    DrawElems(1328, 124, 236, 238, 'L');
  end
  else
  begin
    D.Layer := lyText;
    Txt(fkUI, 11, 1328, 116, 'Select a LAD network to place', cInkSoft);
    Txt(fkUI, 11, 1328, 132, 'contacts, coils and boxes.', cInkSoft);
  end;
  if (CurNet <> nil) and (CurNet.Kind in [nkSTL, nkSCL]) then DrawProps(1328, 160, 236, 200)
  else DrawProps(1328, 446, 236, 200);
  // compile messages
  D.Layer := lyOrnament;
  Ln(1328, 668, 1564, 668, 0.8, Alpha(cGoldDark, 160));
  D.Layer := lyText;
  if Length(FMsgs) = 0 then Txt(fkUIB, 11, 1328, 674, 'Compiler: no messages', cInkSoft)
  else if FMsgErrors > 0 then
    Txt(fkUIB, 11, 1328, 674, Format('Compiler: %d errors, %d messages', [FMsgErrors, Length(FMsgs)]), cRed)
  else
    Txt(fkUIB, 11, 1328, 674, Format('Compiler: 0 errors, %d messages', [Length(FMsgs)]), cJade);
  ClipD(1324, 692, 248, 160);
  Hit(1324, 692, 248, 160, whMsgs, hkWheel);
  FMsgScroll := EnsureRange(FMsgScroll, 0, Max(0, Length(FMsgs) - 5));
  // more than fit: a scroll bar on the right (rows)
  if Length(FMsgs) > 5 then
  begin
    UnclipD;
    VScrollBar(1, 1562, 692, 160, Length(FMsgs), 5.9, FMsgScroll);
    ClipD(1324, 692, 236, 160);
  end
  else
    FVs[1].Range := 0;
  for I := 0 to 5 do
  begin
    if I + Round(FMsgScroll) > High(FMsgs) then Break;
    with FMsgs[I + Round(FMsgScroll)] do
    begin
      S := Block;
      if Net > 0 then S := S + Format(' nw%d', [Net]);
      if Line > 0 then S := S + Format(':%d', [Line]);
      if IsError then C := cRed else C := cGoldDark;
      TxtFit(fkUIB, 9.5, 1328, 694 + I * 27, IfThen(Length(FMsgs) > 5, 228, 240), S, C);
      TxtFit(fkUI, 9.5, 1328, 706 + I * 27, IfThen(Length(FMsgs) > 5, 228, 240), Text, cInk);
    end;
    // with the scroll bar the rows end before it
    Hit(1324, 692 + I * 27, IfThen(Length(FMsgs) > 5, 232, 248), 26, Act(acMsg, I + Round(FMsgScroll)));
  end;
  UnclipD;
end;

{ ====================================================================== }
{ I/O screen                                                             }
{ ====================================================================== }

procedure TPlcUI.BuildIO;
const
  Names: array[0..2] of string = ('PLC I/O (the model)', 'Tag I/O (outside the PLC)', 'Signal table (simulation)');
var
  K: Integer;
begin
  // the three views of the I/O screen
  for K := 0 to 2 do
    if FIoView = K then Button(36 + K * 230, 88, 222, 26, Names[K], Act(acIoView, K), bsToggleOn, True, 11.5)
    else Button(36 + K * 230, 88, 222, 26, Names[K], Act(acIoView, K), bsNormal, True, 11.5);
  D.Layer := lyText;
  case FIoView of
    1: Txt(fkUI, 11, 740, 94, 'the I / Q tags of the tag table beyond the channels of the CPU: switches, values, lamps', cInkFaint);
    2: Txt(fkUI, 11, 740, 94, 'generators for the inputs (the CPU''s and the tags''): square, sine, triangle, ramp, random, step', cInkFaint);
  else
    Txt(fkUI, 11, 740, 94, Format('%s: DI%d DQ%d AI%d AQ%d on the CPU', [Rt.Model.Name, Rt.Model.DI, Rt.Model.DQ, Rt.Model.AI,
      Rt.Model.AQ]), cInkFaint);
  end;
  case FIoView of
    1: BuildIoTags;
    2: BuildIoSignals;
  else
    BuildIoModel;
  end;
end;

{ a list of the I/O screen that scrolls (the wheel, a scroll bar when it is longer than H): the rows shown }
function TPlcUI.IoListScroll(L: Integer; X, Y, W, H, RowH: Single; N: Integer; out First, Last: Integer): Single;
var
  Vis: Integer;
begin
  Vis := Max(1, Trunc(H / RowH));
  FIoScroll[L] := EnsureRange(FIoScroll[L], 0, Max(0, N - Vis));
  Hit(X, Y, W, H, whIo + L, hkWheel);
  First := Round(FIoScroll[L]);
  Last := Min(N - 1, First + Vis - 1);
  if N > Vis then VScrollBar(11 + L, X + W - 10, Y, H, N, Vis, FIoScroll[L]) else FVs[11 + L].Range := 0;
  Result := Y - First * RowH;
end;

procedure TPlcUI.BuildIoModel;
var
  M: TCpuModel;
  I, B, Bit, Cols, Col, Row, Ch, Raw, NRows, F0, F1: Integer;
  X, Y, CW, SX, SW, Y0: Single;
  On, OutOn: Boolean;
  Tg, S: string;
  O: TOperand;
  E: string;
  Frac2: Single;
  AM: TAiMode;

  function TagFor(const A: string): string;
  var
    K: Integer;
    TA, TB: TAddr;
  begin
    Result := '';
    if not ParseAddr(A, TA, E) then Exit;
    for K := 0 to High(Project.Tags) do
      if ParseAddr(Project.Tags[K].Address, TB, E) and SameAddr(TA, TB) then Exit(Project.Tags[K].Name);
  end;

begin
  M := Rt.Model;
  // ---------- digital inputs: columns of 8, four at a time (more: pages) ----------
  NRows := 8;
  Cols := (M.DI + 7) div 8;
  CW := 744 / Max(1, Min(Cols, 4));
  if Cols <= 2 then CW := 372;
  FDIPage := EnsureRange(FDIPage, 0, Max(0, Cols - 4));
  if Cols > 4 then
  begin
    Button(640, 128, 30, 20, '◀', Act(acIoPage, 0), bsNormal, FDIPage > 0, 10);
    Button(674, 128, 30, 20, '▶', Act(acIoPage, 1), bsNormal, FDIPage < Cols - 4, 10);
    D.Layer := lyText;
    Txt(fkUI, 10, 710, 130, Format('%d / %d', [FDIPage + 1, Cols - 3]), cInkSoft);
  end;
  for I := FDIPage * 8 to Min(M.DI, (FDIPage + 4) * 8) - 1 do
  begin
    Col := I div 8 - FDIPage;
    Row := I mod 8;
    B := M.DIByte + I div 8;
    Bit := I mod 8;
    X := 36 + Col * CW;
    Y := 154 + Row * 37;
    On := Rt.GetSimBit(B, Bit);
    Ch := I;
    case Project.DIch[Ch].InType of
      itPushNO, itPushNC:
        begin
          // a push button
          D.Layer := lyControls;
          if FDIPressed[Ch] then
          begin
            El(X + 16, Y + 15, 13, 13, cRedDark);
            El(X + 16, Y + 16, 11, 11, cRed);
          end
          else
          begin
            El(X + 16, Y + 17, 13, 13, Alpha(cShadow, 110));
            El(X + 16, Y + 14, 13, 13, cRedDark);
            if Project.DIch[Ch].InType = itPushNC then El(X + 16, Y + 13, 11, 11, cCharcoal2)
            else El(X + 16, Y + 13, 11, 11, cRedLight);
          end;
          Hit(X, Y - 2, 34, 34, Act(acDI, Ch), hkPress);
        end;
    else
      Switch(X, Y + 6, 34, 18, On, Act(acDI, Ch));
    end;
    Led(X + 46, Y + 15, 4.5, cJadeLight, On);
    D.Layer := lyText;
    S := Format('I%d.%d', [B, Bit]);
    Txt(fkMonoB, 12, X + 58, Y + 4, IfThen(IsTia(M.Family), '%', '') + S, cInk);
    Tg := TagFor(S);
    if Tg <> '' then TxtFit(fkUI, 10.5, X + 58, Y + 19, CW - 120, Tg, cInkSoft);
    Button(X + CW - 74, Y + 6, 64, 20, InTypeNames[Project.DIch[Ch].InType], Act(acDIType, Ch), bsFlat, True, 9.5);
  end;
  D.Layer := lyText;
  Txt(fkUI, 10.5, 56, 454, 'switch: click toggles   push NO: 1 while held   push NC: 0 while held (e.g. a stop button)', cInkFaint);

  // ---------- digital outputs ----------
  Cols := (M.DQ + 7) div 8;
  CW := 744 / Max(1, Min(Cols, 4));
  if Cols <= 2 then CW := 372;
  FDQPage := EnsureRange(FDQPage, 0, Max(0, Cols - 4));
  if Cols > 4 then
  begin
    Button(1428, 128, 30, 20, '◀', Act(acIoPage, 2), bsNormal, FDQPage > 0, 10);
    Button(1462, 128, 30, 20, '▶', Act(acIoPage, 3), bsNormal, FDQPage < Cols - 4, 10);
  end;
  for I := FDQPage * 8 to Min(M.DQ, (FDQPage + 4) * 8) - 1 do
  begin
    Col := I div 8 - FDQPage;
    Row := I mod 8;
    B := M.DQByte + I div 8;
    Bit := I mod 8;
    X := 824 + Col * CW;
    Y := 154 + Row * 37;
    OutOn := Rt.GetOutBit(B, Bit);
    Led(X + 16, Y + 15, 8, BGRA($3C, $E0, $5C), OutOn);   // every output a green LED
    D.Layer := lyText;
    S := Format('Q%d.%d', [B, Bit]);
    Txt(fkMonoB, 12, X + 40, Y + 4, IfThen(IsTia(M.Family), '%', '') + S, cInk);
    Tg := TagFor(S);
    if Tg <> '' then TxtFit(fkUI, 10.5, X + 40, Y + 19, CW - 60, Tg, cInkSoft);
    FillChar(O, SizeOf(O), 0);
    O.Kind := okAddr;
    O.A := MakeAddr(arQ, osBit, B, Bit);
    if Rt.IsForced(O) then
    begin
      D.Layer := lyControls;
      RR(X + CW - 40, Y + 6, 22, 18, 3, cRed);
      D.Layer := lyText;
      Txt(fkUIB, 10, X + CW - 29, Y + 7, 'F', cSheet, 1);
    end;
  end;

  // ---------- analog inputs: a list that scrolls ----------
  Y0 := IoListScroll(0, 24, 522, 966, 300, 36, M.AI, F0, F1);
  if M.AI <= 4 then Y0 := 528 - F0 * 40;
  for I := F0 to F1 do
  begin
    if M.AI <= 4 then Y := Y0 + I * 40 else Y := Y0 + I * 36;
    Raw := SmallInt((Word(Rt.SimIn[M.AIWord + I * 2]) shl 8) or Rt.SimIn[M.AIWord + I * 2 + 1]);
    D.Layer := lyText;
    if IsTia(M.Family) then S := Format('%%IW%d', [M.AIWord + I * 2])
    else S := Format('PIW%d', [M.AIWord + I * 2]);
    Txt(fkMonoB, 12, 40, Y + 4, S, cInk);
    Tg := TagFor(Format('IW%d', [M.AIWord + I * 2]));
    if Tg = '' then Tg := TagFor(Format('PIW%d', [M.AIWord + I * 2]));
    if Tg <> '' then TxtFit(fkUI, 10, 40, Y + 20, 110, Tg, cInkSoft);
    SX := 160;
    SW := 420;
    Frac2 := EnsureRange(Raw / 27648, 0, 1);
    D.Layer := lyControls;
    RR(SX, Y + 11, SW, 8, 4, cSheetDark);
    RR(SX, Y + 11, SW * Frac2 + 4, 8, 4, cRed);
    RRL(SX, Y + 11, SW, 8, 4, 0.6, Alpha(cInk, 90));
    Shad(SX + SW * Frac2 - 9, Y + 6, 18, 18, 9, 1.5, 3, 90);
    El(SX + SW * Frac2, Y + 15, 9, 9, cGold);
    ElL(SX + SW * Frac2, Y + 15, 9, 9, 1, cGoldDark);
    Hit(SX - 10, Y, SW + 20, 30, Act(acAI, I), hkDrag);
    D.Layer := lyText;
    Txt(fkMono, 12, 600, Y + 4, Format('%6d', [Raw]), cInk);
    Txt(fkMono, 11, 660, Y + 5, Format('%5.2f V  %5.1f %%', [Raw * 10 / 27648, Raw * 100 / 27648]), cInkSoft);
    for AM := Low(TAiMode) to High(TAiMode) do
      if Project.AIch[I].AiMode = AM then
        Button(800 + Ord(AM) * 62, Y + 4, 58, 22, AiModeNames[AM], Act(acAIMode, I * 4 + Ord(AM)), bsToggleOn, True, 10)
      else
        Button(800 + Ord(AM) * 62, Y + 4, 58, 22, AiModeNames[AM], Act(acAIMode, I * 4 + Ord(AM)), bsNormal, True, 10);
  end;
  D.Layer := lyText;
  Txt(fkUI, 10.5, 56, 832, 'Nominal range 0..27648 (0..10 V). Drag the knob, or let a sine / ramp generator run.', cInkFaint);

  // ---------- analog outputs: a list that scrolls (the S7-400 has eight) ----------
  if M.AQ > 0 then
  begin
    Y0 := IoListScroll(1, 1020, 532, 556, 132, 32, M.AQ, F0, F1);
    for I := F0 to F1 do
    begin
      Raw := Rt.GetOutWord(M.AQWord + I * 2);
      Y := Y0 + I * 32;
      D.Layer := lyText;
      if IsTia(M.Family) then S := Format('%%QW%d', [M.AQWord + I * 2]) else S := Format('PQW%d', [M.AQWord + I * 2]);
      Txt(fkMonoB, 12, 1036, Y + 4, S, cInk);
      Tg := TagFor(Copy(S, Pos('W', S) - 1, MaxInt));
      if Tg <> '' then TxtFit(fkUI, 9.5, 1036, Y + 18, 90, Tg, cInkSoft);
      ProgressBar(1130, Y + 9, 290, 10, Raw / 27648, cGold);
      Txt(fkMono, 11, 1430, Y + 5, Format('%6d  %5.2f mA', [Raw, Raw * 20 / 27648]), cInkSoft);
    end;
  end;

  // ---------- fault injection ----------
  if M.AQ > 0 then Y := 726 else Y := 528;
  D.Layer := lyText;
  Txt(fkUIB, 12, 1036, Y, 'PROFINET IO station failure', cInk);
  Switch(1036, Y + 24, 46, 22, Rt.BusFault, Act(acBusFault, 0));
  D.Layer := lyText;
  if IsTia(M.Family) then
    TxtFit(fkUI, 10.5, 1094, Y + 26, 470, FamilyNames[M.Family] + ': ERROR flashes, the CPU stays in RUN', cInkSoft)
  else
    TxtFit(fkUI, 10.5, 1094, Y + 26, 470, 'S7-300/400: BF / SF, STOP (OB86 not loaded)', cInkSoft);
  Button(1036, Y + 62, 160, 28, 'All inputs off', Act(acAllOff, 0), bsNormal, True, 12);
  Button(1204, Y + 62, 190, 28, 'Export I/O list (CSV) ...', Act(acExportPc, 5 * 4096), bsGold, True, 12);
  // the import: tags, input kinds, values from a CSV; its help for developers (a window, HTML, PDF)
  Button(1204, Y + 96, 190, 28, 'Import I/O list (CSV) ...', Act(acIoImport, 0), bsGold, True, 12);
  Button(1400, Y + 96, 150, 28, 'Help: import file ...', Act(acIoHelp, 0), bsNormal, True, 12);
  if M.AQ = 0 then
  begin
    D.Layer := lyText;
    Txt(fkUI, 11, 1036, Y + 144, 'Field side: the switches write the input modules;', cInkFaint);
    Txt(fkUI, 11, 1036, Y + 160, 'the CPU copies them into the process image (I) at', cInkFaint);
    Txt(fkUI, 11, 1036, Y + 176, 'the start of every cycle, forces are applied there.', cInkFaint);
    Txt(fkUI, 11, 1036, Y + 192, 'The lamps show the output modules (after the PIQ).', cInkFaint);
  end;
  if NRows = 0 then ;
  if E = '' then ;
end;

{ ---------- the tags outside the PLC's own I/O ---------- }

{ the bytes of the value of a type (Bool: 0, a bit) }
function TypeBytes(const TypeText: string): Integer;
var
  T: TDataType;
  Lo, Hi: Integer;
begin
  if not ParseDataType(TypeText, T, Lo, Hi) then Exit(2);
  Result := DataTypeSize(T);
end;

{ is the address one of the CPU's own channels (DI / DQ bits, AI / AQ words)? }
function InModelIo(const M: TCpuModel; const A: TAddr; Bytes: Integer): Boolean;
var
  K, B0, B1, Ch: Integer;
begin
  Result := False;
  if A.Area in [arI, arPI] then
  begin
    if A.Size = osBit then
    begin
      Ch := (A.Ofs - M.DIByte) * 8 + A.Bit;
      Exit((A.Ofs >= M.DIByte) and (Ch < M.DI));
    end;
    B0 := A.Ofs;
    B1 := A.Ofs + Max(1, Bytes) - 1;
    // over the digital bytes or the analog words
    if (B1 >= M.DIByte) and (B0 <= M.DIByte + (M.DI - 1) div 8) and (M.DI > 0) then Exit(True);
    for K := 0 to M.AI - 1 do
      if (B1 >= M.AIWord + 2 * K) and (B0 <= M.AIWord + 2 * K + 1) then Exit(True);
  end
  else if A.Area in [arQ, arPQ] then
  begin
    if A.Size = osBit then
    begin
      Ch := (A.Ofs - M.DQByte) * 8 + A.Bit;
      Exit((A.Ofs >= M.DQByte) and (Ch < M.DQ));
    end;
    B0 := A.Ofs;
    B1 := A.Ofs + Max(1, Bytes) - 1;
    if (B1 >= M.DQByte) and (B0 <= M.DQByte + (M.DQ - 1) div 8) and (M.DQ > 0) then Exit(True);
    for K := 0 to M.AQ - 1 do
      if (B1 >= M.AQWord + 2 * K) and (B0 <= M.AQWord + 2 * K + 1) then Exit(True);
  end;
end;

{ the raw value (big endian) of Bytes bytes as text of the type }
function RawAsText(const TypeText: string; Raw: LongWord; Bytes: Integer): string;
var
  T: TDataType;
  Lo, Hi: Integer;
  Sg: Single;
begin
  if not ParseDataType(TypeText, T, Lo, Hi) then T := dtWord;
  case T of
    dtInt: Result := IntToStr(SmallInt(Raw and $FFFF));
    dtSInt: Result := IntToStr(ShortInt(Raw and $FF));
    dtDInt: Result := IntToStr(LongInt(Raw));
    dtReal:
      begin
        Move(Raw, Sg, 4);
        Result := FloatToStrDot(Sg);
      end;
    dtTime: Result := FormatTime(LongInt(Raw));
    dtByte, dtWord, dtDWord: Result := '16#' + IntToHex(Raw, Bytes * 2);
  else
    Result := IntToStr(Raw);
  end;
end;

{ the I / Q tags beyond the CPU's channels: the inputs first }
procedure TPlcUI.CollectTagIo;
var
  K, Pass: Integer;
  A: TAddr;
  E: string;
  M: TCpuModel;
begin
  M := Rt.Model;
  SetLength(FTagIo, 0);
  FTagIoIn := 0;
  for Pass := 0 to 1 do
    for K := 0 to High(Project.Tags) do
      if ParseAddr(Project.Tags[K].Address, A, E) and
        (((Pass = 0) and (A.Area in [arI, arPI])) or ((Pass = 1) and (A.Area in [arQ, arPQ]))) and
        not InModelIo(M, A, TypeBytes(Project.Tags[K].TypeText)) then
      begin
        SetLength(FTagIo, Length(FTagIo) + 1);
        FTagIo[High(FTagIo)] := K;
        if Pass = 0 then Inc(FTagIoIn);
      end;
end;

procedure TPlcUI.BuildIoTags;
var
  K, J, F0, F1, Bytes, NOut: Integer;
  X, Y, Y0, Fr: Single;
  A: TAddr;
  E, S: string;
  Raw: LongWord;
  On, Ana: Boolean;
  Tg: TTag;
begin
  CollectTagIo;
  NOut := Length(FTagIo) - FTagIoIn;
  D.Layer := lyText;
  // ---------- inputs ----------
  if FTagIoIn = 0 then
  begin
    Txt(fkUI, 12, 44, 170, 'No input tag outside the CPU''s own inputs.', cInkSoft);
    Txt(fkUI, 11, 44, 192, Format('Add tags with I addresses beyond %s in the tag table (Tags):', [
      FormatAddr(MakeAddr(arI, osBit, Rt.Model.DIByte + Max(0, Rt.Model.DI - 1) div 8, Max(0, Rt.Model.DI - 1) mod 8),
      Project.Family)]), cInkFaint);
    Txt(fkUI, 11, 44, 210, 'a Bool gets a switch here, an Int / Word a slider and a value, others a value.', cInkFaint);
  end;
  Y0 := IoListScroll(2, 24, 156, 764, 690, 40, FTagIoIn, F0, F1);
  ClipD(24, 156, 754, 690);
  for J := F0 to F1 do
  begin
    Tg := Project.Tags[FTagIo[J]];
    Y := Y0 + J * 40;
    X := 40;
    if not ParseAddr(Tg.Address, A, E) then Continue;
    Bytes := TypeBytes(Tg.TypeText);
    D.Layer := lyControls;
    if Odd(J) then Rc(28, Y - 2, 746, 38, Alpha(cSheet2, 120));
    if A.Size = osBit then
    begin
      On := Rt.GetSimBit(A.Ofs, A.Bit);
      Switch(X, Y + 8, 34, 18, On, Act(acTagIo, J));
      Led(X + 46, Y + 17, 4.5, cJadeLight, On);
    end;
    D.Layer := lyText;
    TxtFit(fkMonoB, 12, X + 58, Y + 4, 150, FormatAddr(A, Project.Family), cInk);
    TxtFit(fkUI, 10.5, X + 58, Y + 20, 150, Tg.Name, cInkSoft);
    TxtFit(fkMono, 10.5, X + 214, Y + 11, 70, Tg.TypeText, cInkFaint);
    if A.Size <> osBit then
    begin
      Bytes := Max(1, Min(4, Bytes));
      Raw := 0;
      for K := 0 to Bytes - 1 do
        if A.Ofs + K < Length(Rt.SimIn) then Raw := Raw shl 8 or Rt.SimIn[A.Ofs + K];
      S := RawAsText(Tg.TypeText, Raw, Bytes);
      Ana := SameText(Tg.TypeText, 'Int') or SameText(Tg.TypeText, 'Word') or SameText(Tg.TypeText, 'UInt');
      if Ana then
      begin
        // like an analog input: 0..27648 with the slider
        Fr := EnsureRange(SmallInt(Raw and $FFFF) / 27648, 0, 1);
        D.Layer := lyControls;
        RR(X + 290, Y + 14, 260, 8, 4, cSheetDark);
        RR(X + 290, Y + 14, 260 * Fr + 4, 8, 4, cRed);
        El(X + 290 + 260 * Fr, Y + 18, 8, 8, cGold);
        ElL(X + 290 + 260 * Fr, Y + 18, 8, 8, 1, cGoldDark);
        Hit(X + 280, Y + 4, 280, 28, Act(acTagIoAi, J), hkDrag);
      end;
      Field(X + 570, Y + 6, 150, 24, Act(fdTagIoVal, J), S, fkMono, 11.5, 2);
    end;
  end;
  UnclipD;
  // ---------- outputs ----------
  D.Layer := lyText;
  if NOut = 0 then
  begin
    Txt(fkUI, 12, 832, 170, 'No output tag outside the CPU''s own outputs.', cInkSoft);
    Txt(fkUI, 11, 832, 192, 'Tags with Q addresses beyond the CPU''s outputs show here: a lamp, or the value.', cInkFaint);
  end;
  Y0 := IoListScroll(3, 812, 156, 764, 690, 40, NOut, F0, F1);
  ClipD(812, 156, 754, 690);
  for J := F0 to F1 do
  begin
    Tg := Project.Tags[FTagIo[FTagIoIn + J]];
    Y := Y0 + J * 40;
    X := 828;
    if not ParseAddr(Tg.Address, A, E) then Continue;
    Bytes := Max(1, Min(4, TypeBytes(Tg.TypeText)));
    D.Layer := lyControls;
    if Odd(J) then Rc(816, Y - 2, 746, 38, Alpha(cSheet2, 120));
    if A.Size = osBit then Led(X + 16, Y + 17, 8, BGRA($3C, $E0, $5C), Rt.GetOutBit(A.Ofs, A.Bit));
    D.Layer := lyText;
    TxtFit(fkMonoB, 12, X + 40, Y + 4, 150, FormatAddr(A, Project.Family), cInk);
    TxtFit(fkUI, 10.5, X + 40, Y + 20, 150, Tg.Name, cInkSoft);
    TxtFit(fkMono, 10.5, X + 200, Y + 11, 70, Tg.TypeText, cInkFaint);
    if A.Size <> osBit then
    begin
      Raw := Rt.GetOutRaw(A.Ofs, Bytes);
      if SameText(Tg.TypeText, 'Int') or SameText(Tg.TypeText, 'Word') then
        ProgressBar(X + 290, Y + 14, 250, 10, SmallInt(Raw and $FFFF) / 27648, cGold);
      TxtFit(fkMonoB, 12, X + 700, Y + 10, 140, RawAsText(Tg.TypeText, Raw, Bytes), cInk, 2);
    end;
  end;
  UnclipD;
end;

{ ---------- the signal table ---------- }

procedure TPlcUI.BuildIoSignals;
const
  ColX: array[0..10] of Single = (36, 66, 100, 326, 450, 556, 640, 724, 816, 890, 1010);
var
  J, I, F0, F1, K, N, Bytes: Integer;
  Y, Y0, Cx9, Cy9: Single;
  O: TOperand;
  E, S: string;
  Ok: Boolean;
  Sg: TSimSignal;
  Pts: array of TPointF;
  Per, V, Ph: Double;
  Raw: LongWord;
begin
  N := Length(Project.Signals);
  Button(36, 146, 90, 26, '+ Row', Act(acSigAdd, 0), bsNormal, True, 11.5);
  Button(132, 146, 110, 26, 'Delete row', Act(acSigDel, 0), bsNormal, N > 0, 11.5);
  Button(248, 146, 90, 26, 'All on', Act(acSigAll, 1), bsPrimary, N > 0, 11.5);
  Button(344, 146, 90, 26, 'All off', Act(acSigAll, 0), bsNormal, N > 0, 11.5);
  Button(440, 146, 220, 26, '+ A row for every input tag', Act(acSigTags, 0), bsGold, True, 11.5);
  D.Layer := lyText;
  Txt(fkUI, 10.5, 672, 151, 'A row drives an input (I / PI, an address or a tag) while On: Bool from Low / High, a number scaled ' +
    'Low .. High; Period in ms, Duty: % at High (Square).', cInkFaint);
  Txt(fkUIB, 11, ColX[0], 184, '#', cInkSoft);
  Txt(fkUIB, 11, ColX[1], 184, 'On', cInkSoft);
  Txt(fkUIB, 11, ColX[2], 184, 'Address / symbol', cInkSoft);
  Txt(fkUIB, 11, ColX[3], 184, 'Absolute', cInkSoft);
  Txt(fkUIB, 11, ColX[4], 184, 'Signal', cInkSoft);
  Txt(fkUIB, 11, ColX[5], 184, 'Low', cInkSoft);
  Txt(fkUIB, 11, ColX[6], 184, 'High', cInkSoft);
  Txt(fkUIB, 11, ColX[7], 184, 'Period ms', cInkSoft);
  Txt(fkUIB, 11, ColX[8], 184, 'Duty %', cInkSoft);
  Txt(fkUIB, 11, ColX[9], 184, 'Input now', cInkSoft);
  Txt(fkUIB, 11, ColX[10], 184, 'Curve (two periods)', cInkSoft);
  Txt(fkUIB, 11, 1290, 184, 'Comment', cInkSoft);
  D.Layer := lyOrnament;
  Ln(36, 202, 1560, 202, 0.8, Alpha(cGoldDark, 160));
  if N = 0 then
  begin
    D.Layer := lyText;
    Txt(fkUI, 12, 66, 216, 'No signal yet: + Row (the next input after the last row), or a row for every input tag.', cInkSoft);
  end;
  Y0 := IoListScroll(4, 28, 206, 1546, 642, 31, N, F0, F1);
  ClipD(28, 206, 1536, 642);
  for J := F0 to F1 do
  begin
    Sg := Project.Signals[J];
    Y := Y0 + J * 31 + 2;
    Ok := FRes.Resolve(Sg.Address, O, E, False) and (O.Kind = okAddr) and (O.A.Area in [arI, arPI]);
    if FRes.Resolve(Sg.Address, O, E, False) and (O.Kind = okAddr) and not (O.A.Area in [arI, arPI]) then
      E := 'an input is simulated (I / PI), not ' + AreaNames[O.A.Area];
    D.Layer := lyControls;
    if not Ok and (Sg.Address <> '') then
    begin
      RR(30, Y - 2, 1532, 29, 4, Alpha(cRed, IfThen(J = FSigSel, 95, 60)));
      RRL(30, Y - 2, 1532, 29, 4, 1, Alpha(cRed, 200));
    end
    else if J = FSigSel then RR(30, Y - 2, 1532, 29, 4, Alpha(cGold, 70))
    else if Odd(J) then Rc(30, Y - 2, 1532, 29, Alpha(cSheet2, 130));
    Hit(30, Y - 2, 1532, 29, Act(acSigRow, J));
    D.Layer := lyText;
    Txt(fkMono, 11, ColX[0], Y + 4, IntToStr(J + 1), cInkSoft);
    Check(ColX[1] + 2, Y + 4, 16, Sg.On, Act(acSigOn, J));
    Field(ColX[2] - 4, Y, 220, 24, Act(fdSigAddr, J), Sg.Address, fkMono, 11.5, 0, True, 'address');
    D.Layer := lyText;
    if Ok then TxtFit(fkMono, 10.5, ColX[3], Y + 5, 118, FormatAddr(O.A, Project.Family), cInkSoft)
    else if Sg.Address <> '' then TxtFit(fkUI, 9.5, ColX[3], Y + 5, 118, E, cRedDark);
    Button(ColX[4], Y + 1, 98, 22, SigKindNames[Sg.Kind] + ' ▼', Act(acSigKind, J), bsGold, True, 10);
    Field(ColX[5] - 4, Y, 78, 24, Act(fdSigLo, J), FloatToStrDot(Sg.Lo), fkMono, 11, 2);
    Field(ColX[6] - 4, Y, 78, 24, Act(fdSigHi, J), FloatToStrDot(Sg.Hi), fkMono, 11, 2);
    Field(ColX[7] - 4, Y, 86, 24, Act(fdSigPer, J), FloatToStrDot(Sg.PeriodMs), fkMono, 11, 2);
    Field(ColX[8] - 4, Y, 64, 24, Act(fdSigDuty, J), FloatToStrDot(Sg.Duty), fkMono, 11, 2, Sg.Kind = sgSquare);
    // the input as it is now
    if Ok then
    begin
      D.Layer := lyText;
      if O.A.Size = osBit then
      begin
        if Rt.GetSimBit(O.A.Ofs, O.A.Bit) then TxtFit(fkMonoB, 12, ColX[9], Y + 4, 110, 'TRUE', cRed)
        else TxtFit(fkMonoB, 12, ColX[9], Y + 4, 110, 'FALSE', cInk);
      end
      else
      begin
        case O.A.Size of
          osByte: Bytes := 1;
          osWord: Bytes := 2;
        else
          Bytes := 4;
        end;
        Raw := 0;
        for K := 0 to Bytes - 1 do
          if O.A.Ofs + K < Length(Rt.SimIn) then Raw := Raw shl 8 or Rt.SimIn[O.A.Ofs + K];
        if O.DType = dtNone then S := IntToStr(Raw) else S := RawAsText(DataTypeNames[O.DType], Raw, Bytes);
        TxtFit(fkMonoB, 12, ColX[9], Y + 4, 110, S, cInk);
      end;
    end;
    // the curve of two periods, the place of now
    SetLength(Pts, 61);
    Per := Max(1, Sg.PeriodMs) / 1000;
    for I := 0 to 60 do
    begin
      V := SignalValue(Sg, I / 30 * Per, Frac(Sin(I * 12.9898 + J) * 43758.5453));
      if Sg.Hi <> Sg.Lo then V := (V - Sg.Lo) / (Sg.Hi - Sg.Lo) else V := 0.5;
      Pts[I] := PointF(ColX[10] + I * 4, Y + 21 - EnsureRange(V, 0, 1) * 18);
    end;
    D.Layer := lyControls;
    Rc(ColX[10] - 2, Y, 246, 24, Alpha(cSheetDark, 70));
    if Sg.On then PolyLineD(Pts, 1.6, cRed) else PolyLineD(Pts, 1.2, Alpha(cInkSoft, 200));
    Ph := Frac(FTime / (2 * Per));
    Cx9 := ColX[10] + Ph * 240;
    Cy9 := Y + 2;
    if Sg.On then Ln(Cx9, Cy9, Cx9, Cy9 + 20, 1.2, cJade);
    Field(1286, Y, 270, 24, Act(fdSigCmt, J), Sg.Comment, fkUI, 11);
  end;
  UnclipD;
end;

{ every frame: the rows that are On write their inputs (after the generators of the analog inputs) }
procedure TPlcUI.ApplySignals;
var
  J, Bytes: Integer;
  O: TOperand;
  E: string;
  V, Per: Double;
  K: Int64;
  Sg: Single;
  Raw: LongWord;
begin
  if Length(FSigRnd) <> Length(Project.Signals) then
  begin
    SetLength(FSigRnd, Length(Project.Signals));
    SetLength(FSigRndK, Length(Project.Signals));
    for J := 0 to High(FSigRndK) do FSigRndK[J] := -1;
  end;
  for J := 0 to High(Project.Signals) do
  begin
    if not Project.Signals[J].On then Continue;
    if not FRes.Resolve(Project.Signals[J].Address, O, E, False) or (O.Kind <> okAddr) or
      not (O.A.Area in [arI, arPI]) then Continue;
    Per := Max(1, Project.Signals[J].PeriodMs) / 1000;
    K := Trunc(FTime / Per);
    if FSigRndK[J] <> K then
    begin
      FSigRndK[J] := K;
      FSigRnd[J] := Random;
    end;
    V := SignalValue(Project.Signals[J], FTime, FSigRnd[J]);
    case O.A.Size of
      osBit:
        begin
          Rt.SetSimBit(O.A.Ofs, O.A.Bit, V >= 0.5);
          Continue;
        end;
      osByte: Bytes := 1;
      osWord: Bytes := 2;
    else
      Bytes := 4;
    end;
    if O.DType = dtReal then
    begin
      Sg := V;
      Move(Sg, Raw, 4);
    end
    else
      Raw := LongWord(Int64(Round(EnsureRange(V, -2147483648.0, 4294967295.0))) and $FFFFFFFF);
    Rt.SetSimRaw(O.A.Ofs, Bytes, Raw);
  end;
end;

{ the address after the last watch row: the next variable of its DB, the next address (its symbol when
  the row had one) }
function TPlcUI.NextWatchAddress: string;
var
  Prev, Db, Vn: string;
  O: TOperand;
  E: string;
  A2: TAddr;
  D0: TDataBlock;
  K, Q: Integer;
begin
  Result := '';
  // the last row that resolves (a red row is skipped), of the group shown when it has one
  K := High(Project.Watch);
  while (K >= 0) and not ((Trim(Project.Watch[K].Address) <> '') and
    ((FWatchGrpSel < 0) or (Project.Watch[K].GroupId = GrpIdSel(1))) and
    FRes.Resolve(Trim(Project.Watch[K].Address), O, E, False) and (O.Kind = okAddr)) do Dec(K);
  if K < 0 then
  begin
    K := High(Project.Watch);
    while (K >= 0) and not ((Trim(Project.Watch[K].Address) <> '') and
      FRes.Resolve(Trim(Project.Watch[K].Address), O, E, False) and (O.Kind = okAddr)) do Dec(K);
  end;
  if K < 0 then Exit;
  Prev := Trim(Project.Watch[K].Address);
  // "DB".Var: the next variable of the DB
  if (Prev[1] = '"') and (Pos('".', Prev) > 1) then
  begin
    Q := Pos('".', Prev);
    Db := Copy(Prev, 2, Q - 2);
    Vn := Copy(Prev, Q + 2, MaxInt);
    D0 := Project.FindDBByName(Db);
    if (D0 <> nil) and (Pos('.', Vn) = 0) and (Pos('[', Vn) = 0) then
    begin
      D0.Layout;
      K := D0.FindVar(Vn);
      if (K >= 0) and (K < High(D0.Vars)) then Exit('"' + Db + '".' + D0.Vars[K + 1].Name);
    end;
  end;
  A2 := NextAddr(O.A, DataTypeSize(O.DType));
  if Prev[1] = '"' then Result := FRes.SymbolOf(A2);
  if Result = '' then Result := StringReplace(FormatAddr(A2, Project.Family), ' ', '', [rfReplaceAll]);
  // past the end of the DB (or the area): an empty row to type into
  if not FRes.Resolve(Result, O, E, False) then Result := '';
end;

{ ====================================================================== }
{ Watch screen                                                           }
{ ====================================================================== }

procedure TPlcUI.BuildWatch;
const
  ColX: array[0..7] of Single = (36, 76, 360, 560, 660, 900, 1100, 1146);
  SortNames: array[1..3] of string = ('Address / symbol', 'Absolute / symbol', 'Type');
  SortX: array[1..3] of Single = (76, 360, 500);
var
  I, J, FC, K, N: Integer;
  S: string;
  Y: Single;
  O: TOperand;
  E, Mv, SymS: string;
  V: LongWord;
  Ok, Forced: Boolean;
  C: TBGRAPixel;
  F: TCpuFamily;
begin
  BuildGroupTree(1, 1230, 112, 340, 420);
  MakeWatchView;
  N := Length(FWatchView);
  Button(36, 112, 90, 28, '+ Row', Act(acWatchAdd, 0), bsNormal, True, 12);
  Button(132, 112, 110, 28, 'Delete row', Act(acWatchDel, 0), bsNormal, Length(Project.Watch) > 0, 12);
  Button(260, 112, 140, 28, 'Modify now', Act(acModifyNow, 0), bsPrimary, True, 12);
  Button(406, 112, 130, 28, 'Force row', Act(acForce, 0), bsDanger, Length(Project.Watch) > 0, 12);
  Button(542, 112, 130, 28, 'Unforce row', Act(acUnforce, 0), bsNormal, Length(Project.Watch) > 0, 12);
  Button(678, 112, 130, 28, 'Unforce all', Act(acUnforceAll, 0), bsNormal, Rt.ForceCount > 0, 12);
  Button(814, 112, 100, 28, 'Table ▼', Act(acWatchMenu, 0), bsGold, True, 12);
  Button(920, 112, 110, 28, 'Group ▼', Act(acWatchGrpMenu, 0), bsGold, Length(Project.Watch) > 0, 12);
  D.Layer := lyText;
  if FWatchFile <> '' then TxtFit(fkUI, 11, 1040, 118, 150, ExtractFileName(FWatchFile), cInkSoft)
  else TxtFit(fkUI, 11, 1040, 118, 150, 'in the project', cInkFaint);
  D.Layer := lyText;
  Txt(fkUIB, 11, ColX[0], 152, '#', cInkSoft);
  // the heads: a click sorts (alphabet, address, data type), again the other way, a third time as entered
  for K := 1 to 3 do
  begin
    S := SortNames[K];
    if FWatchSort = K then
      if FWatchDesc then S := S + '  ▼' else S := S + '  ▲';
    if FWatchSort = K then Txt(fkUIB, 11, SortX[K], 152, S, cRed)
    else if Hot(SortX[K] - 4, 146, IfThen(K = 3, 56, 130), 22) then Txt(fkUIB, 11, SortX[K], 152, S, cRedDark)
    else Txt(fkUIB, 11, SortX[K], 152, S, cInkSoft);
    Hit(SortX[K] - 4, 146, IfThen(K = 3, 56, 130), 22, Act(acSortWatch, K));
  end;
  Txt(fkUIB, 11, ColX[3], 152, 'Format', cInkSoft);
  Txt(fkUIB, 11, ColX[4], 152, 'Monitor value', cInkSoft);
  Txt(fkUIB, 11, ColX[5], 152, 'Modify value', cInkSoft);
  Txt(fkUIB, 11, ColX[6], 152, 'Mod', cInkSoft);
  Txt(fkUIB, 11, ColX[7], 152, 'Force', cInkSoft);
  D.Layer := lyOrnament;
  Ln(36, 170, 1184, 170, 0.8, Alpha(cGoldDark, 160));
  if (FWatchGrpSel >= 0) and (N = 0) then
  begin
    D.Layer := lyText;
    Txt(fkUI, 12, ColX[1], 184, 'No row in this group: + Row, or Group ▼ on a selected row.', cInkSoft);
  end;
  FWatchScroll := EnsureRange(FWatchScroll, 0, Max(0, N - 21));
  ClipD(30, 172, 1160, 680);
  Hit(30, 172, 1160, 680, whWatch, hkWheel);
  for J := 0 to 21 do
  begin
    if J + Round(FWatchScroll) >= N then Break;
    I := FWatchView[J + Round(FWatchScroll)];
    Y := 176 + J * 31;
    D.Layer := lyControls;
    // an address / symbol that does not resolve: the row is red
    if (Trim(Project.Watch[I].Address) <> '') and not (FRes.Resolve(Project.Watch[I].Address, O, E, False) and
      (O.Kind = okAddr)) then
    begin
      RR(32, Y - 2, 1156, 29, 4, Alpha(cRed, IfThen(I = FWatchSel, 95, 60)));
      RRL(32, Y - 2, 1156, 29, 4, 1, Alpha(cRed, 200));
    end
    else if I = FWatchSel then RR(32, Y - 2, 1156, 29, 4, Alpha(cGold, 70))
    else if Odd(J) then Rc(32, Y - 2, 1156, 29, Alpha(cSheet2, 130));
    Hit(32, Y - 2, 1156, 29, Act(acWatchRow, I));
    D.Layer := lyText;
    Txt(fkMono, 11, ColX[0], Y + 4, IntToStr(J + Round(FWatchScroll) + 1), cInkSoft);
    Field(ColX[1] - 4, Y, 270, 24, Act(fdWatchAddr, I), Project.Watch[I].Address, fkMono, 12, 0, True, 'address');
    Ok := FRes.Resolve(Project.Watch[I].Address, O, E, False) and (O.Kind = okAddr);
    D.Layer := lyText;
    if Ok then
    begin
      if (Project.Watch[I].Address <> '') and (Project.Watch[I].Address[1] = '"') then
        SymS := FormatAddr(O.A, Project.Family)
      else
      begin
        SymS := FRes.SymbolOf(O.A);
        if SymS = '' then SymS := FormatAddr(O.A, Project.Family);
      end;
      TxtFit(fkMono, 11, ColX[2], Y + 4, 134, SymS, cInkSoft);
      // its data type
      if O.DType <> dtNone then S := DataTypeNames[O.DType]
      else
        case O.A.Size of
          osBit: S := 'Bool';
          osByte: S := 'Byte';
          osWord: S := 'Word';
        else
          S := 'DWord';
        end;
      TxtFit(fkMono, 10, SortX[3], Y + 5, 56, S, cInkFaint);
    end
    else if Project.Watch[I].Address <> '' then
      TxtFit(fkUI, 10, ColX[2], Y + 5, 190, E, cRed);
    Button(ColX[3], Y + 1, 86, 22, DispFmtNames[Project.Watch[I].Fmt], Act(acWatchFmt, I), bsGold, True, 10);
    Forced := Ok and Rt.IsForced(O);
    if Ok and Rt.PeekRaw(O, V) then
    begin
      Mv := FormatRaw(V, O.A.Size, Project.Watch[I].Fmt);
      if (O.DType in [dtString, dtWString]) or (DataTypeSize(O.DType) = 8) then StrLive(O, Mv);
      if (O.A.Size = osBit) and (V <> 0) then C := cRed else C := cInk;
      if (O.A.Size = osBit) then
      begin
        D.Layer := lyControls;
        if V <> 0 then RR(ColX[4] - 4, Y + 1, 70, 22, 4, Alpha(cRed, 40));
      end;
      D.Layer := lyText;
      TxtFit(fkMonoB, 12, ColX[4], Y + 4, 230, Mv, C);
    end;
    Field(ColX[5] - 4, Y, 190, 24, Act(fdWatchMod, I), Project.Watch[I].ModifyValue, fkMono, 12, 0, True, '');
    Check(ColX[6] + 4, Y + 4, 16, Project.Watch[I].ModifyOn, Act(acWatchModOn, I));
    if Forced then
    begin
      D.Layer := lyControls;
      RR(ColX[7] + 4, Y + 2, 26, 20, 4, cRed);
      D.Layer := lyText;
      Txt(fkUIB, 11, ColX[7] + 17, Y + 4, 'F', cSheet, 1);
    end;
  end;
  UnclipD;
  if N > 21 then VScrollBar(6, 1176, 172, 680, N, 21, FWatchScroll)
  else FVs[6].Range := 0;
  // ---------- forces ----------
  F := Project.Family;
  D.Layer := lyText;
  if Rt.ForceCount > 0 then Txt(fkUIB, 12, 1236, 588, Format('%d bits forced', [Rt.ForceCount]), cRed)
  else Txt(fkUIB, 12, 1236, 588, 'no forces', cJade);
  case F of
    cfS7300: E := 'S7-300: I, Q (and PI / PQ)';
    cfS7400: E := 'S7-400: I, Q, M (and PI / PQ)';
  else
    E := FamilyNames[F] + ': peripheral I:P and Q:P';
  end;
  Txt(fkUI, 11, 1236, 612, 'Forceable: ' + E, cInkSoft);
  Txt(fkUI, 10.5, 1236, 634, 'A forced input is fixed in the input', cInkFaint);
  Txt(fkUI, 10.5, 1236, 648, 'image every cycle; a forced output is', cInkFaint);
  Txt(fkUI, 10.5, 1236, 662, 'fixed on the module, also in STOP.', cInkFaint);
  if IsTia(F) then Txt(fkUI, 10.5, 1236, 676, 'MAINT shows forces on the ' + FamilyNames[F] + '.', cInkFaint)
  else Txt(fkUI, 10.5, 1236, 676, 'The FRCE LED shows active forces.', cInkFaint);
  Txt(fkUI, 10.5, 1236, 696, 'Modify now writes every row with Mod', cInkFaint);
  Txt(fkUI, 10.5, 1236, 710, 'checked once, at the cycle check point.', cInkFaint);
  FC := 0;
  for I := 0 to High(Project.Watch) do
    if FRes.Resolve(Project.Watch[I].Address, O, E, False) and (O.Kind = okAddr) and Rt.IsForced(O) then
    begin
      Y := 736 + FC * 24;
      if Y > 826 then Break;
      D.Layer := lyControls;
      RR(1236, Y, 22, 20, 4, cRed);
      D.Layer := lyText;
      Txt(fkUIB, 11, 1247, Y + 2, 'F', cSheet, 1);
      TxtFit(fkMono, 11, 1266, Y + 3, 290, Project.Watch[I].Address + ' = ' + Project.Watch[I].ModifyValue, cInk);
      Inc(FC);
    end;
end;

{ ====================================================================== }
{ Data blocks                                                            }
{ ====================================================================== }

procedure TPlcUI.BuildDB;
const
  ColX: array[0..7] of Single = (372, 396, 600, 796, 864, 1012, 1190, 1250);
var
  I, J, K, N: Integer;
  Db: TDataBlock;
  Y: Single;
  V: TDbVar;
  S, E, Live: string;
  O: TOperand;
  Sel: Boolean;
  C: TBGRAPixel;
  Opt: Boolean;
  LH: Single;
begin
  // the list of data blocks and data types scrolls when it does not fit
  LH := Project.DBCount * 46 + 6 + 28 + 48 + 28 + Project.UdtCount * 46 + 28 + 6 + 36;
  FDBListScroll := EnsureRange(FDBListScroll, 0, Max(0, LH - 740));
  ClipD(28, 112, 290, 742);
  Hit(28, 112, 290, 742, whDBList, hkWheel);
  for I := 0 to Project.DBCount - 1 do
  begin
    Db := Project.DB(I);
    Y := 118 + I * 46 - FDBListScroll;
    Sel := I = FDBSel;
    D.Layer := lySheets;
    if Sel then
    begin
      Shad(36, Y, 268, 40, 5, 2, 4, 80);
      RR(36, Y, 268, 40, 5, cRed);
    end
    else if Hot(36, Y, 268, 40) then RR(36, Y, 268, 40, 5, Mixc(cSheet2, cWhite, 0.3))
    else RR(36, Y, 268, 40, 5, cSheet2);
    D.Layer := lyText;
    if Sel then C := cSheet else C := cRedDark;
    Txt(fkUIB, 14, 48, Y + 3, Format('DB%d', [Db.Number]), C);
    if Sel then C := cGoldLight else C := cInkSoft;
    if Db.InstanceOf > 0 then TxtFit(fkUI, 11, 48, Y + 21, 250, Format('"%s"  %d bytes, instance of FB%d', [Db.Name, Db.Size, Db.InstanceOf]), C)
    else TxtFit(fkUI, 11, 48, Y + 21, 250, Format('"%s"  %d bytes', [Db.Name, Db.Size]), C);
    Hit(36, Y, 268, 40, Act(acDBSel, I));
  end;
  Y := 118 + Project.DBCount * 46 + 6 - FDBListScroll;
  Button(36, Y, 130, 28, '+ DB', Act(acDBAdd, 0), bsNormal, True, 12);
  Button(174, Y, 130, 28, 'Delete DB', Act(acDBDel, 0), bsFlat, (Project.DBCount > 0) and not SelIsUdt, 12);
  // PLC data types
  Y := Y + 48;
  D.Layer := lyText;
  if IsTia(Project.Family) then Txt(fkUIB, 12, 40, Y, 'PLC data types', cRedDark)
  else Txt(fkUIB, 12, 40, Y, 'Data types (UDT)', cRedDark);
  D.Layer := lyOrnament;
  Ln(40, Y + 20, 300, Y + 20, 0.8, Alpha(cGoldDark, 160));
  Y := Y + 28;
  for I := 0 to Project.UdtCount - 1 do
  begin
    Db := Project.Udt(I);
    Sel := Project.DBCount + I = FDBSel;
    D.Layer := lySheets;
    if Sel then
    begin
      Shad(36, Y, 268, 40, 5, 2, 4, 80);
      RR(36, Y, 268, 40, 5, cRed);
    end
    else if Hot(36, Y, 268, 40) then RR(36, Y, 268, 40, 5, Mixc(cSheet2, cWhite, 0.3))
    else RR(36, Y, 268, 40, 5, cSheet2);
    D.Layer := lyText;
    if Sel then C := cSheet else C := cRedDark;
    Db.Layout;
    if IsTia(Project.Family) then TxtFit(fkUIB, 14, 48, Y + 3, 250, '"' + Db.Name + '"', C)
    else TxtFit(fkUIB, 14, 48, Y + 3, 250, Format('UDT%d  "%s"', [Db.Number, Db.Name]), C);
    if Sel then C := cGoldLight else C := cInkSoft;
    TxtFit(fkUI, 11, 48, Y + 21, 250, Format('struct, %d members, %d bytes', [Length(Db.Vars), Db.Size]), C);
    Hit(36, Y, 268, 40, Act(acDBSel, Project.DBCount + I));
    Y := Y + 46;
  end;
  Button(36, Y, 130, 28, '+ Data type', Act(acUdtAdd, 0), bsNormal, True, 12);
  Button(174, Y, 130, 28, 'Delete type', Act(acDBDel, 0), bsFlat, SelIsUdt, 12);
  // the SCL source of TIA Portal: TYPE .. END_TYPE, DATA_BLOCK .. END_DATA_BLOCK
  Button(36, Y + 36, 130, 28, 'Import SCL ...', Act(acDbScl, 0), bsGold, True, 12);
  Button(174, Y + 36, 130, 28, 'Export SCL ...', Act(acDbScl, 1), bsGold, CurDB <> nil, 12);
  UnclipD;
  if LH > 742 then VScrollBar(4, 308, 112, 742, LH, 742, FDBListScroll) else FVs[4].Range := 0;
  Db := CurDB;
  if Db = nil then
  begin
    D.Layer := lyText;
    Txt(fkUI, 14, 380, 140, 'No data block. Add one on the left.', cInkSoft);
    Exit;
  end;
  Db.Layout;
  // DB header
  D.Layer := lyText;
  if Db.IsUdt then Txt(fkUI, 10, 372, 110, 'UDT number', cInkSoft)
  else Txt(fkUI, 10, 372, 110, 'number', cInkSoft);
  Field(372, 124, 70, 24, Act(fdDBNum, 0), IntToStr(Db.Number), fkMono, 12);
  Txt(fkUI, 10, 452, 110, 'name', cInkSoft);
  Field(452, 124, 220, 24, Act(fdDBName, 0), Db.Name, fkUI, 12);
  Txt(fkUI, 10, 682, 110, 'comment', cInkSoft);
  if Db.IsUdt then Field(682, 124, 344, 24, Act(fdDBComment, 0), Db.Comment, fkUI, 12)
  else
  begin
    Field(682, 124, 250, 24, Act(fdDBComment, 0), Db.Comment, fkUI, 12);
    D.Layer := lyText;
    Txt(fkUI, 10, 944, 110, 'instance of FB', cInkSoft);
    Field(944, 124, 80, 24, Act(fdDBInst, 0), IfThen(Db.InstanceOf > 0, IntToStr(Db.InstanceOf), '0'), fkMono, 12);
  end;
  Opt := Db.Optimized and (IsTia(Project.Family));
  if Db.IsUdt then
  begin
    D.Layer := lyText;
    Txt(fkUI, 11, 1040, 120, Format('struct, %d bytes; use as type', [Db.Size]), cInkSoft);
    Txt(fkMonoB, 11.5, 1040, 136, Project.UdtTypeName(Db), cRedDark);
  end
  else if IsTia(Project.Family) then
  begin
    Check(1040, 128, 16, Opt, Act(acDBOpt, 0));
    D.Layer := lyText;
    Txt(fkUI, 11, 1062, 128, 'optimized block access', cInk);
  end
  else
    Txt(fkUI, 11, 1040, 128, 'standard DB, retentive', cInkSoft);
  Button(1254, 122, 140, 28, IfThen(Db.IsUdt, '+ Member', '+ Variable'), Act(acVarAdd, 0), bsNormal, Db.InstanceOf = 0, 12);
  Button(1400, 122, 150, 28, IfThen(Db.IsUdt, 'Delete member', 'Delete variable'), Act(acVarDel, 0), bsNormal,
    (Length(Db.Vars) > 0) and (Db.InstanceOf = 0), 12);
  if Db.InstanceOf > 0 then
  begin
    D.Layer := lyText;
    if Project.InstanceFB(Db) <> nil then
      Txt(fkUI, 11, 1254, 154, Format('variables of FB%d "%s": edit its interface', [Db.InstanceOf, Project.InstanceFB(Db).Name]), cJade)
    else
      Txt(fkUI, 11, 1254, 154, Format('FB%d does not exist', [Db.InstanceOf]), cRed);
  end;
  D.Layer := lyText;
  Txt(fkUIB, 11, ColX[0], 164, '#', cInkSoft);
  Txt(fkUIB, 11, ColX[1], 164, 'Name', cInkSoft);
  Txt(fkUIB, 11, ColX[2], 164, 'Data type', cInkSoft);
  Txt(fkUIB, 11, ColX[3], 164, 'Offset', cInkSoft);
  if Db.IsUdt then Txt(fkUIB, 11, ColX[4], 164, 'Default value', cInkSoft)
  else Txt(fkUIB, 11, ColX[4], 164, 'Start value', cInkSoft);
  if not Db.IsUdt then Txt(fkUIB, 11, ColX[5], 164, 'Monitor value', cInkSoft);
  if IsTia(Project.Family) and not Db.IsUdt then Txt(fkUIB, 11, ColX[6], 164, 'Retain', cInkSoft);
  Txt(fkUIB, 11, ColX[7], 164, 'Comment', cInkSoft);
  D.Layer := lyOrnament;
  Ln(366, 182, 1560, 182, 0.8, Alpha(cGoldDark, 160));
  N := Length(Db.Vars);
  FVarScroll := EnsureRange(FVarScroll, 0, Max(0, N - 20));
  ClipD(360, 184, 1212, 640);
  Hit(360, 184, 1212, 640, whVars, hkWheel);
  for J := 0 to 20 do
  begin
    I := J + Round(FVarScroll);
    if I >= N then Break;
    V := Db.Vars[I];
    Y := 188 + J * 30;
    D.Layer := lyControls;
    if I = FVarSel then RR(362, Y - 2, 1208, 28, 4, Alpha(cGold, 70))
    else if Odd(J) then Rc(362, Y - 2, 1208, 28, Alpha(cSheet2, 130));
    Hit(362, Y - 2, 1208, 28, Act(acVarSel, I));
    D.Layer := lyText;
    Txt(fkMono, 11, ColX[0], Y + 4, IntToStr(I + 1), cInkSoft);
    if Db.InstanceOf > 0 then
    begin
      // an instance DB: the FB interface, read only here
      D.Layer := lyText;
      TxtFit(fkUI, 12, ColX[1], Y + 3, 190, V.Name, cInk);
      TxtFit(fkMono, 11.5, ColX[2], Y + 4, 186, V.TypeText, cInkSoft);
      TxtFit(fkUI, 9.5, ColX[0] + 4, Y + 15, 30, Copy(SectionNames[V.Section], 1, 3), cInkFaint);
    end
    else
    begin
      Field(ColX[1] - 4, Y, 200, 24, Act(fdVarName, I), V.Name, fkUI, 12);
      Field(ColX[2] - 4, Y, 164, 24, Act(fdVarType, I), V.TypeText, fkMono, 12);
      Button(ColX[2] + 162, Y, 24, 24, '▼', Act(acVarTypeMenu, I), bsGold, True, 9.5);
    end;
    D.Layer := lyText;
    if not V.Valid then
      Txt(fkUI, 10, ColX[3], Y + 5, 'type?', cRed)
    else if (V.DType = dtBool) and not V.IsArray then
      Txt(fkMono, 11, ColX[3], Y + 4, Format('%d.%d', [V.Ofs, V.Bit]), cInkSoft)
    else
      Txt(fkMono, 11, ColX[3], Y + 4, Format('%d.0', [V.Ofs]), cInkSoft);
    if V.DType = dtStruct then
      Txt(fkUI, 10, ColX[4], Y + 5, '(struct defaults)', cInkFaint)
    else if Db.InstanceOf > 0 then
      Txt(fkMono, 11.5, ColX[4], Y + 4, V.Start, cInkSoft)
    else if not (V.DType in [dtIECTimer, dtIECCounter]) then
      Field(ColX[4] - 4, Y, 140, 24, Act(fdVarStart, I), V.Start, fkMono, 12)
    else
      Txt(fkUI, 10, ColX[4], Y + 5, '(instance)', cInkFaint);
    // live value
    Live := '';
    if V.Valid and (Rt.Prog <> nil) and not Db.IsUdt then
    begin
      if (V.DType = dtStruct) and V.IsArray then
        Live := Format('[%d]: ', [V.Lo]) + StructLive(Format('"%s".%s[%s]', [Db.Name, V.Name, ElemIdx(V, V.Lo)]), V.Udt)
      else if V.DType = dtStruct then
        Live := StructLive(Format('"%s".%s', [Db.Name, V.Name]), V.Udt)
      else if V.IsArray then
      begin
        S := '';
        for K := V.Lo to Min(V.Hi, V.Lo + 5) do
          if FRes.Resolve(Format('"%s".%s[%s]', [Db.Name, V.Name, ElemIdx(V, K)]), O, E, False) then
          begin
            if S <> '' then S := S + ', ';
            S := S + LiveText(O, '?');
          end;
        if V.Hi > V.Lo + 5 then S := S + ', …';
        Live := '[' + S + ']';
      end
      else if V.DType = dtIECTimer then
      begin
        FRes.Resolve(Format('"%s".%s.ET', [Db.Name, V.Name]), O, E, False);
        Live := 'ET ' + LiveText(O, '?');
        FRes.Resolve(Format('"%s".%s.Q', [Db.Name, V.Name]), O, E, False);
        Live := Live + '  Q ' + LiveText(O, '?');
      end
      else if V.DType = dtIECCounter then
      begin
        FRes.Resolve(Format('"%s".%s.CV', [Db.Name, V.Name]), O, E, False);
        Live := 'CV ' + LiveText(O, '?');
        FRes.Resolve(Format('"%s".%s.QU', [Db.Name, V.Name]), O, E, False);
        Live := Live + '  Q ' + LiveText(O, '?');
      end
      else if FRes.Resolve(Format('"%s".%s', [Db.Name, V.Name]), O, E, False) then
        Live := LiveText(O, '?');
    end;
    D.Layer := lyText;
    TxtFit(fkMonoB, 11.5, ColX[5], Y + 4, 176, Live, cRedDark);
    if IsTia(Project.Family) and not Db.IsUdt and (Db.InstanceOf = 0) then Check(ColX[6] + 10, Y + 4, 16, V.Retain, Act(acVarRetain, I));
    Field(ColX[7] - 4, Y, 1550 - ColX[7], 24, Act(fdVarComment, I), V.Comment, fkUI, 11);
  end;
  UnclipD;
  if N > 20 then VScrollBar(5, 1560, 184, 640, N, 20, FVarScroll) else FVs[5].Range := 0;
  D.Layer := lyText;
  Txt(fkUI, 10.5, 380, 818, 'Types: Bool Byte Word DWord Char Int DInt Real Time S5Time Date Time_Of_Day String[n] IEC_TIMER ' +
    IfThen(IsTia(Project.Family), 'SInt USInt UInt UDInt LReal WChar WString DTL TON_TIME CTU_INT R_TRIG  ', '') +
    IfThen(Project.Family = cfS71500, 'LInt ULInt LWord LTime LTOD LDT  ', '') +
    'Array[lo..hi, ..] of <type>.  Download to apply.', cInkFaint);
  Txt(fkUI, 10.5, 380, 834, 'PLC data types: ' + IfThen(IsTia(Project.Family), '"Name"', 'UDTn or "Name"') +
    ', also Array[0..3] of ' + IfThen(IsTia(Project.Family), '"Name"', 'UDTn') +
    '.  Access: "DB".Arr[2].Member  ("DB".Arr[#i].Member in SCL).', cInkFaint);
end;

function TPlcUI.CurDB: TDataBlock;
begin
  Result := nil;
  if Project.DBCount + Project.UdtCount = 0 then Exit;
  FDBSel := EnsureRange(FDBSel, 0, Project.DBCount + Project.UdtCount - 1);
  if FDBSel < Project.DBCount then Result := Project.DB(FDBSel)
  else Result := Project.Udt(FDBSel - Project.DBCount);
end;

function TPlcUI.SelIsUdt: Boolean;
begin
  Result := (CurDB <> nil) and CurDB.IsUdt;
end;

{ the first members of a struct: Speed 5, On FALSE, ... }
function TPlcUI.StructLive(const Prefix: string; U: TDataBlock): string;
var
  K, N: Integer;
  O: TOperand;
  E: string;
begin
  Result := '';
  if U = nil then Exit;
  N := 0;
  for K := 0 to High(U.Vars) do
  begin
    if not U.Vars[K].Valid or U.Vars[K].IsArray or (U.Vars[K].DType in [dtStruct, dtIECTimer, dtIECCounter]) then
      Continue;
    if N = 3 then
    begin
      Result := Result + ', …';
      Break;
    end;
    if FRes.Resolve(Prefix + '.' + U.Vars[K].Name, O, E, False) then
    begin
      if Result <> '' then Result := Result + ', ';
      Result := Result + U.Vars[K].Name + ' ' + LiveText(O, '?');
      Inc(N);
    end;
  end;
  Result := '{' + Result + '}';
end;

{ ====================================================================== }
{ Tags                                                                   }
{ ====================================================================== }

procedure TPlcUI.BuildTags;
const
  ColX: array[0..6] of Single = (344, 374, 576, 714, 856, 1006, 1244);
  SortNames: array[1..3] of string = ('Name', 'Address', 'Data type');   // 1 alphabet, 2 address, 3 data type
var
  I, J, N, K, G: Integer;
  Y: Single;
  O: TOperand;
  E, Live, S: string;
  Ok: Boolean;
begin
  BuildGroupTree(0, 34, 112, 262, 736);
  MakeTagView;
  G := FTagGrpSel;
  Button(ColX[0] - 2, 112, 110, 28, '+ Tag', Act(acTagAdd, 0), bsNormal, True, 12);
  Button(ColX[0] + 114, 112, 110, 28, 'Delete tag', Act(acTagDel, 0), bsNormal, Length(Project.Tags) > 0, 12);
  Button(1404, 112, 160, 28, 'Export (CSV) ...', Act(acExportPc, 6 * 4096), bsGold, Length(Project.Tags) > 0, 12);
  Button(1236, 112, 160, 28, 'Import (CSV) ...', Act(acTagImport, 0), bsGold, True, 12);
  D.Layer := lyText;
  if G >= 0 then
    TxtFit(fkUI, 11, 576, 118, 320, Format('Group "%s": %d tags; + Tag adds into it', [Project.TagGroups[G].Name,
      Length(FTagView)]), cInkSoft)
  else if IsTia(Project.Family) then
    TxtFit(fkUI, 11, 576, 118, 320, 'TIA style: tags are used as "Name", addresses show as %I0.0', cInkSoft)
  else
    TxtFit(fkUI, 11, 576, 118, 320, 'Symbol table: use "Name" in LAD and STL', cInkSoft);
  // the heads: a click sorts (alphabet, address, data type), again the other way, a third time as entered
  Txt(fkUIB, 11, ColX[0], 152, '#', cInkSoft);
  for K := 1 to 3 do
  begin
    case K of
      1: I := 1;
      2: I := 4;
    else
      I := 2;
    end;
    S := SortNames[K];
    if FTagSort = K then
      if FTagDesc then S := S + '  ▼' else S := S + '  ▲';
    if FTagSort = K then Txt(fkUIB, 11, ColX[I], 152, S, cRed)
    else if Hot(ColX[I] - 4, 146, 120, 22) then Txt(fkUIB, 11, ColX[I], 152, S, cRedDark)
    else Txt(fkUIB, 11, ColX[I], 152, S, cInkSoft);
    Hit(ColX[I] - 4, 146, 120, 22, Act(acSortTag, K));
  end;
  Txt(fkUIB, 11, ColX[3], 152, 'Group', cInkSoft);
  Txt(fkUIB, 11, ColX[5], 152, 'Monitor value', cInkSoft);
  Txt(fkUIB, 11, ColX[6], 152, 'Comment', cInkSoft);
  D.Layer := lyOrnament;
  Ln(340, 170, 1564, 170, 0.8, Alpha(cGoldDark, 160));
  N := Length(FTagView);
  CheckTags;
  J := 0;
  for I := 0 to High(Project.Tags) do
    if FTagErr[I] <> '' then Inc(J);
  D.Layer := lyText;
  // left of the buttons, never over them
  if J > 0 then TxtFit(fkUIB, 11.5, 1226, 118, 320, Format('%d tag(s) in red: see the Monitor value column', [J]), cRed, 2);
  if (G >= 0) and (N = 0) then
    Txt(fkUI, 12, ColX[1], 184, 'No tag in this group: + Tag, or choose this group in the Group column of a tag.',
      cInkSoft);
  FTagScroll := EnsureRange(FTagScroll, 0, Max(0, N - 21));
  ClipD(336, 172, 1228, 680);
  Hit(336, 172, 1228, 680, whTags, hkWheel);
  for J := 0 to 21 do
  begin
    if J + Round(FTagScroll) >= N then Break;
    I := FTagView[J + Round(FTagScroll)];
    Y := 176 + J * 31;
    D.Layer := lyControls;
    // a tag with a problem (its name or address used twice, ..): the row is red
    if FTagErr[I] <> '' then
    begin
      RR(338, Y - 2, 1224, 29, 4, Alpha(cRed, IfThen(I = FTagSel, 95, 60)));
      RRL(338, Y - 2, 1224, 29, 4, 1, Alpha(cRed, 200));
    end
    else if I = FTagSel then RR(338, Y - 2, 1224, 29, 4, Alpha(cGold, 70))
    else if Odd(J) then Rc(338, Y - 2, 1224, 29, Alpha(cSheet2, 130));
    Hit(338, Y - 2, 1224, 29, Act(acTagSel, I));
    D.Layer := lyText;
    Txt(fkMono, 11, ColX[0], Y + 4, IntToStr(I + 1), cInkSoft);
    Field(ColX[1] - 4, Y, 196, 24, Act(fdTagName, I), Project.Tags[I].Name, fkUI, 12);
    Field(ColX[2] - 4, Y, 108, 24, Act(fdTagType, I), Project.Tags[I].TypeText, fkMono, 12);
    Button(ColX[2] + 106, Y, 24, 24, '▼', Act(acTagTypeMenu, I), bsGold, True, 9.5);
    K := GroupOfId(Project.TagGroups, Project.Tags[I].GroupId);
    if K >= 0 then S := Project.TagGroups[K].Name + ' ▼' else S := '— ▼';
    Button(ColX[3] - 2, Y + 1, 134, 22, S, Act(acTagGrpMenu, I), bsFlat, True, 10);
    Field(ColX[4] - 4, Y, 144, 24, Act(fdTagAddr, I), Project.Tags[I].Address, fkMono, 12);
    Ok := FRes.Resolve('"' + Project.Tags[I].Name + '"', O, E, False) and (O.Kind = okAddr);
    D.Layer := lyText;
    if FTagErr[I] <> '' then
      TxtFit(fkUIB, 10.5, ColX[5], Y + 5, 232, FTagErr[I], cRedDark)
    else if Ok then
    begin
      Live := LiveText(O, '?');
      if Live = 'TRUE' then TxtFit(fkMonoB, 12, ColX[5], Y + 4, 150, Live, cRed)
      else TxtFit(fkMonoB, 12, ColX[5], Y + 4, 150, Live, cInk);
      TxtFit(fkMono, 10, ColX[5] + 152, Y + 5, 78, FormatAddr(O.A, Project.Family), cInkFaint);
    end
    else
      TxtFit(fkUI, 10, ColX[5], Y + 5, 232, E, cRed);
    Field(ColX[6] - 4, Y, 316, 24, Act(fdTagComment, I), Project.Tags[I].Comment, fkUI, 11);
  end;
  UnclipD;
  if N > 21 then VScrollBar(3, 1562, 172, 680, N, 21, FTagScroll) else FVs[3].Range := 0;
end;

{ ---------- the groups (the tag table: K = 0, the watch table: K = 1) ---------- }

{ the rows sorted by their keys (stable: the same key keeps the order of the table) }
procedure SortRows(var Idx: array of Integer; const Keys: array of string; Desc: Boolean);
var
  Tmp: array of Integer;
  W, L, M, R, I, J, K, N, C: Integer;
begin
  N := Length(Idx);
  SetLength(Tmp, N);
  W := 1;
  while W < N do
  begin
    L := 0;
    while L < N do
    begin
      M := Min(L + W, N);
      R := Min(L + 2 * W, N);
      I := L;
      J := M;
      K := L;
      while (I < M) and (J < R) do
      begin
        C := CompareStr(Keys[Idx[I]], Keys[Idx[J]]);
        if Desc then C := -C;
        if C <= 0 then
        begin
          Tmp[K] := Idx[I];
          Inc(I);
        end
        else
        begin
          Tmp[K] := Idx[J];
          Inc(J);
        end;
        Inc(K);
      end;
      while I < M do
      begin
        Tmp[K] := Idx[I];
        Inc(I);
        Inc(K);
      end;
      while J < R do
      begin
        Tmp[K] := Idx[J];
        Inc(J);
        Inc(K);
      end;
      L := R;
    end;
    for I := 0 to N - 1 do Idx[I] := Tmp[I];
    W := W * 2;
  end;
end;

{ an address as a key that sorts by area, DB, byte, bit (not an address: after them, by its text) }
function AddrSortKey(const A: TAddr): string;
begin
  Result := Format('%.2d%.5d%.7d%d%.5d', [Ord(A.Area), A.DB, A.Ofs, A.Bit, A.Num]);
end;

function TPlcUI.GrpSel(K: Integer): Integer;
begin
  if K = 0 then Result := FTagGrpSel else Result := FWatchGrpSel;
end;

procedure TPlcUI.SetGrpSel(K, V: Integer);
begin
  if K = 0 then
  begin
    FTagGrpSel := V;
    FTagScroll := 0;
  end
  else
  begin
    FWatchGrpSel := V;
    FWatchScroll := 0;
  end;
end;

{ the Id of the group shown (0: the root) }
function TPlcUI.GrpIdSel(K: Integer): Integer;
begin
  Result := 0;
  if (K = 0) and (FTagGrpSel >= 0) and (FTagGrpSel <= High(Project.TagGroups)) then
    Result := Project.TagGroups[FTagGrpSel].Id
  else if (K = 1) and (FWatchGrpSel >= 0) and (FWatchGrpSel <= High(Project.WatchGroups)) then
    Result := Project.WatchGroups[FWatchGrpSel].Id;
end;

function TPlcUI.GrpIsOpen(K, Id: Integer): Boolean;
var
  J: Integer;
begin
  Result := False;
  for J := 0 to High(FGrpOpen[K]) do
    if FGrpOpen[K][J] = Id then Exit(True);
end;

procedure TPlcUI.MakeTagView;
var
  I, N, Id: Integer;
  Keys: array of string;
  A: TAddr;
  E: string;
begin
  if FTagGrpSel > High(Project.TagGroups) then FTagGrpSel := -1;
  Id := GrpIdSel(0);
  SetLength(FTagView, Length(Project.Tags));
  N := 0;
  for I := 0 to High(Project.Tags) do
    if (FTagGrpSel < 0) or (Project.Tags[I].GroupId = Id) then
    begin
      FTagView[N] := I;
      Inc(N);
    end;
  SetLength(FTagView, N);
  if FTagSort = 0 then Exit;
  SetLength(Keys, Length(Project.Tags));
  for I := 0 to High(Project.Tags) do
    with Project.Tags[I] do
      case FTagSort of
        1: Keys[I] := UpperCase(Name);
        2:
          if ParseAddr(Address, A, E) then Keys[I] := AddrSortKey(A)
          else Keys[I] := '~' + UpperCase(Address);
      else
        Keys[I] := UpperCase(TypeText) + #1 + UpperCase(Name);
      end;
  SortRows(FTagView, Keys, FTagDesc);
end;

procedure TPlcUI.MakeWatchView;
var
  I, N, Id: Integer;
  Keys: array of string;
  O: TOperand;
  E: string;
  Ok: Boolean;
begin
  if FWatchGrpSel > High(Project.WatchGroups) then FWatchGrpSel := -1;
  Id := GrpIdSel(1);
  SetLength(FWatchView, Length(Project.Watch));
  N := 0;
  for I := 0 to High(Project.Watch) do
    if (FWatchGrpSel < 0) or (Project.Watch[I].GroupId = Id) then
    begin
      FWatchView[N] := I;
      Inc(N);
    end;
  SetLength(FWatchView, N);
  if FWatchSort = 0 then Exit;
  SetLength(Keys, Length(Project.Watch));
  for I := 0 to High(Project.Watch) do
  begin
    Ok := FRes.Resolve(Project.Watch[I].Address, O, E, False) and (O.Kind = okAddr);
    case FWatchSort of
      1: Keys[I] := UpperCase(Project.Watch[I].Address);
      2:
        if Ok then Keys[I] := AddrSortKey(O.A) else Keys[I] := '~' + UpperCase(Project.Watch[I].Address);
    else
      if not Ok then Keys[I] := '~'
      else if O.DType <> dtNone then Keys[I] := UpperCase(DataTypeNames[O.DType])
      else
        case O.A.Size of
          osBit: Keys[I] := 'BOOL';
          osByte: Keys[I] := 'BYTE';
          osWord: Keys[I] := 'WORD';
        else
          Keys[I] := 'DWORD';
        end;
      Keys[I] := Keys[I] + #1 + UpperCase(Project.Watch[I].Address);
    end;
  end;
  SortRows(FWatchView, Keys, FWatchDesc);
end;

{ the tree: the root ("All tag" / "All rows": every row, cannot be renamed or deleted), its groups (a
  click shows the group's rows, the name of the selected one is a field: rename; a name used twice is
  red), the rows of an open group (a click selects the row) }
procedure TPlcUI.BuildGroupTree(K: Integer; X, Y, W, H: Single);
const
  RowH = 26;
var
  G: TItemGroups;
  RK, RI: array of Integer;   // 0 root, 1 group, 2 row; the group / the row
  N, I, J, Cnt, Sel, Vis, F0: Integer;
  Y0, AreaH, Ry, Ind: Single;
  Root, Lb: string;
  Dup, IsSel, Dup2: Boolean;
  C: TBGRAPixel;

  procedure Add(AKind, AIdx: Integer);
  begin
    SetLength(RK, N + 1);
    SetLength(RI, N + 1);
    RK[N] := AKind;
    RI[N] := AIdx;
    Inc(N);
  end;

  function ItemGroup(I: Integer): Integer;
  begin
    if K = 0 then Result := Project.Tags[I].GroupId else Result := Project.Watch[I].GroupId;
  end;

  function ItemCount: Integer;
  begin
    if K = 0 then Result := Length(Project.Tags) else Result := Length(Project.Watch);
  end;

  function Members(Id: Integer): Integer;
  var
    Q: Integer;
  begin
    Result := 0;
    for Q := 0 to ItemCount - 1 do
      if ItemGroup(Q) = Id then Inc(Result);
  end;

  procedure Folder(FX, FY: Single; Open: Boolean);
  begin
    D.Layer := lyControls;
    RR(FX, FY + 2, 7, 4, 1.5, cGoldDark);
    if Open then RR(FX, FY + 4, 16, 11, 2, cGold) else RR(FX, FY + 4, 16, 11, 2, cGoldDark);
    RRL(FX, FY + 4, 16, 11, 2, 0.8, Alpha(cInk, 90));
  end;

begin
  if K = 0 then
  begin
    G := Project.TagGroups;
    Root := AllTagsName;
  end
  else
  begin
    G := Project.WatchGroups;
    Root := AllWatchName;
  end;
  Sel := GrpSel(K);
  if Sel > High(G) then Sel := -1;
  Button(X, Y, 112, 26, '+ Group', Act(acGrpAdd, K * 16384), bsNormal, True, 11.5);
  Button(X + 118, Y, 126, 26, 'Delete group', Act(acGrpDel, K * 16384), bsNormal, Sel >= 0, 11.5);
  // the rows of the tree
  N := 0;
  Add(0, 0);
  if not FGrpRootShut[K] then
    for I := 0 to High(G) do
    begin
      Add(1, I);
      if GrpIsOpen(K, G[I].Id) then
        for J := 0 to ItemCount - 1 do
          if ItemGroup(J) = G[I].Id then Add(2, J);
    end;
  Y0 := Y + 36;
  AreaH := H - 36;
  Vis := Trunc(AreaH / RowH);
  FGrpScroll[K] := EnsureRange(FGrpScroll[K], 0, Max(0, N - Vis));
  F0 := Round(FGrpScroll[K]);
  ClipD(X - 4, Y0, W + 4, AreaH);
  Hit(X - 4, Y0, W + 4, AreaH, whGrpTree + K, hkWheel);
  for J := F0 to Min(N - 1, F0 + Vis) do
  begin
    Ry := Y0 + (J - F0) * RowH;
    I := RI[J];
    case RK[J] of
      0: Ind := 0;
      1: Ind := 18;
    else
      Ind := 40;
    end;
    Dup := (RK[J] = 1) and GroupNameTwice(G, I);
    IsSel := ((RK[J] = 0) and (Sel < 0)) or ((RK[J] = 1) and (Sel = I)) or
      ((RK[J] = 2) and (((K = 0) and (I = FTagSel)) or ((K = 1) and (I = FWatchSel))));
    D.Layer := lySheets;
    if Dup then
    begin
      RR(X, Ry + 1, W - 12, RowH - 2, 4, Alpha(cRed, IfThen(IsSel, 110, 60)));
      RRL(X, Ry + 1, W - 12, RowH - 2, 4, 1, Alpha(cRed, 200));
    end
    else if IsSel and (RK[J] < 2) then RR(X, Ry + 1, W - 12, RowH - 2, 4, cRed)
    else if IsSel then RR(X, Ry + 1, W - 12, RowH - 2, 4, Alpha(cGold, 90))
    else if Hot(X, Ry + 1, W - 12, RowH - 2) then RR(X, Ry + 1, W - 12, RowH - 2, 4, Mixc(cSheet2, cWhite, 0.3));
    if RK[J] = 2 then Hit(X, Ry + 1, W - 12, RowH - 2, Act(acGrpItem, K * 16384 + I))
    else Hit(X, Ry + 1, W - 12, RowH - 2, Act(acGrpSel, K * 16384 + IfThen(RK[J] = 0, 0, I + 1)));
    if IsSel and (RK[J] < 2) and not Dup then C := cSheet
    else if Dup then C := cRedDark
    else C := cInk;
    D.Layer := lyText;
    if RK[J] < 2 then
    begin
      // the open / shut mark: a triangle down / right
      if RK[J] = 0 then Dup2 := not FGrpRootShut[K] else Dup2 := GrpIsOpen(K, G[I].Id);
      D.Layer := lyControls;
      if Dup2 then PolyD([PointF(X + Ind + 5, Ry + 10), PointF(X + Ind + 15, Ry + 10), PointF(X + Ind + 10, Ry + 16)], C)
      else PolyD([PointF(X + Ind + 7, Ry + 8), PointF(X + Ind + 13, Ry + 13), PointF(X + Ind + 7, Ry + 18)], C);
      D.Layer := lyText;
      Hit(X + Ind, Ry + 1, 18, RowH - 2, Act(acGrpOpen, K * 16384 + IfThen(RK[J] = 0, 0, I + 1)));
      Folder(X + Ind + 20, Ry + 3, (RK[J] = 0) or GrpIsOpen(K, G[I].Id));
      D.Layer := lyText;
      if RK[J] = 0 then
      begin
        Cnt := ItemCount;
        TxtFit(fkUIB, 12, X + Ind + 42, Ry + 5, W - Ind - 100, Root, C);
      end
      else
      begin
        Cnt := Members(G[I].Id);
        if IsSel then
        begin
          // the name to edit: a light box on the red row
          D.Layer := lyControls;
          RR(X + Ind + 38, Ry + 3, W - Ind - 100, RowH - 6, 3, cSheet);
          Field(X + Ind + 40, Ry + 2, W - Ind - 104, RowH - 4, Act(fdGrpName, K * 16384 + I), G[I].Name, fkUI, 11.5);
        end
        else
          TxtFit(fkUI, 12, X + Ind + 42, Ry + 5, W - Ind - 100, G[I].Name, C);
      end;
      D.Layer := lyText;
      if IsSel and not Dup then C := cGoldLight else C := cInkSoft;
      TxtFit(fkMono, 10.5, X + W - 58, Ry + 6, 40, IntToStr(Cnt), C, 2);
    end
    else
    begin
      D.Layer := lyText;
      if K = 0 then Lb := Project.Tags[I].Name else Lb := Project.Watch[I].Address;
      if Lb = '' then Lb := '(empty)';
      if (K = 0) and (I <= High(FTagErr)) and (FTagErr[I] <> '') then C := cRed else C := cInkSoft;
      D.Layer := lyControls;
      El(X + Ind - 4, Ry + 13, 2.5, 2.5, cGoldDark);
      D.Layer := lyText;
      TxtFit(fkMono, 11.5, X + Ind + 4, Ry + 5, W - Ind - 22, Lb, C);
    end;
  end;
  UnclipD;
  if N > Vis then VScrollBar(16 + K, X + W - 8, Y0, AreaH, N, Vis, FGrpScroll[K]) else FVs[16 + K].Range := 0;
  D.Layer := lyText;
  if Length(G) = 0 then
  begin
    TxtFit(fkUI, 10.5, X + 4, Y0 + RowH + 6, W - 12, '+ Group: a group of its own;', cInkFaint);
    TxtFit(fkUI, 10.5, X + 4, Y0 + RowH + 21, W - 12, 'every row stays in "' + Root + '".', cInkFaint);
  end;
end;

function TPlcUI.ViewText(K: Integer): string;
var
  I: Integer;
begin
  Result := '';
  if K = 0 then
  begin
    MakeTagView;
    for I := 0 to High(FTagView) do Result := Result + Project.Tags[FTagView[I]].Name + ' ';
  end
  else
  begin
    MakeWatchView;
    for I := 0 to High(FWatchView) do Result := Result + Project.Watch[FWatchView[I]].Address + ' ';
  end;
  Result := Trim(Result);
end;

procedure TPlcUI.TestGroupName(K, G: Integer; const S: string);
begin
  StartEdit(Act(fdGrpName, K * 16384 + G), '');
  TextInput(S);
  EndEdit(True);
end;

procedure TPlcUI.GroupAction(Code, Par: Integer);
var
  K, V, I, J, Id: Integer;
  SL: TStringList;
  Nm: string;
  Names: array of string;
  Acts: array of Integer;
  Ens: array of Boolean;

  procedure Cycle(var Sort: Integer; var Desc: Boolean; P: Integer);
  begin
    if Sort <> P then
    begin
      Sort := P;
      Desc := False;
    end
    else if not Desc then Desc := True
    else Sort := 0;
  end;

  // the menu of the groups for a row: (no group) and every group, the current one checked
  procedure GroupMenu(const G: TItemGroups; Cur, PickAct: Integer);
  var
    Q: Integer;
  begin
    SetLength(Names, Length(G) + 1);
    SetLength(Acts, Length(G) + 1);
    SetLength(Ens, Length(G) + 1);
    Names[0] := '(no group)';
    if Cur = 0 then Names[0] := Names[0] + '   ✓';
    Acts[0] := Act(PickAct, 0);
    Ens[0] := True;
    for Q := 0 to High(G) do
    begin
      Names[Q + 1] := G[Q].Name;
      if G[Q].Id = Cur then Names[Q + 1] := Names[Q + 1] + '   ✓';
      Acts[Q + 1] := Act(PickAct, Q + 1);
      Ens[Q + 1] := True;
    end;
    OpenCtx(FMX, FMY, Names, Acts, Ens);
  end;

begin
  K := Par div 16384;
  V := Par mod 16384;
  case Code of
    acGrpSel:
      begin
        EndEdit(True);
        SetGrpSel(K, V - 1);
      end;
    acGrpOpen:
      if V = 0 then FGrpRootShut[K] := not FGrpRootShut[K]
      else
      begin
        if K = 0 then Id := Project.TagGroups[V - 1].Id else Id := Project.WatchGroups[V - 1].Id;
        if GrpIsOpen(K, Id) then
        begin
          J := 0;
          for I := 0 to High(FGrpOpen[K]) do
            if FGrpOpen[K][I] <> Id then
            begin
              FGrpOpen[K][J] := FGrpOpen[K][I];
              Inc(J);
            end;
          SetLength(FGrpOpen[K], J);
        end
        else
        begin
          SetLength(FGrpOpen[K], Length(FGrpOpen[K]) + 1);
          FGrpOpen[K][High(FGrpOpen[K])] := Id;
        end;
      end;
    acGrpItem:
      begin
        // a row of a group: its group shown, the row selected and scrolled to
        if K = 0 then
        begin
          FTagGrpSel := GroupOfId(Project.TagGroups, Project.Tags[V].GroupId);
          FTagSel := V;
          MakeTagView;
          for I := 0 to High(FTagView) do
            if FTagView[I] = V then FTagScroll := Max(0, I - 3);
        end
        else
        begin
          FWatchGrpSel := GroupOfId(Project.WatchGroups, Project.Watch[V].GroupId);
          FWatchSel := V;
          MakeWatchView;
          for I := 0 to High(FWatchView) do
            if FWatchView[I] = V then FWatchScroll := Max(0, I - 3);
        end;
      end;
    acGrpAdd:
      begin
        // a new group with the next free name, shown and its name to type
        SL := TStringList.Create;
        try
          if K = 0 then
            for I := 0 to High(Project.TagGroups) do SL.Add(Project.TagGroups[I].Name)
          else
            for I := 0 to High(Project.WatchGroups) do SL.Add(Project.WatchGroups[I].Name);
          Nm := NextName('Group_0', SL);
        finally
          SL.Free;
        end;
        if K = 0 then I := GroupAdd(Project.TagGroups, Nm) else I := GroupAdd(Project.WatchGroups, Nm);
        SetGrpSel(K, I);
        FGrpRootShut[K] := False;
        Project.Modified := True;
        StartEdit(Act(fdGrpName, K * 16384 + I), Nm);
        FEditAnchor := 0;
      end;
    acGrpDel:
      begin
        I := GrpSel(K);
        EndEdit(False);
        if K = 0 then
        begin
          if (I < 0) or (I > High(Project.TagGroups)) then Exit;
          Nm := Project.TagGroups[I].Name;
          J := 0;
          for V := 0 to High(Project.Tags) do
            if Project.Tags[V].GroupId = Project.TagGroups[I].Id then Inc(J);
          Project.DeleteTagGroup(I);
          Toast(Format('Group "%s" deleted: its %d tag(s) stay in "%s"', [Nm, J, AllTagsName]));
        end
        else
        begin
          if (I < 0) or (I > High(Project.WatchGroups)) then Exit;
          Nm := Project.WatchGroups[I].Name;
          J := 0;
          for V := 0 to High(Project.Watch) do
            if Project.Watch[V].GroupId = Project.WatchGroups[I].Id then Inc(J);
          Project.DeleteWatchGroup(I);
          Toast(Format('Group "%s" deleted: its %d row(s) stay in "%s"', [Nm, J, AllWatchName]));
        end;
        SetGrpSel(K, -1);
        Project.Modified := True;
      end;
    acTagGrpMenu:
      if Par <= High(Project.Tags) then
      begin
        FTagSel := Par;
        GroupMenu(Project.TagGroups, Project.Tags[Par].GroupId, acTagGrpPick);
      end;
    acTagGrpPick:
      if FTagSel <= High(Project.Tags) then
      begin
        if Par = 0 then Project.Tags[FTagSel].GroupId := 0
        else if Par - 1 <= High(Project.TagGroups) then Project.Tags[FTagSel].GroupId := Project.TagGroups[Par - 1].Id;
        Project.Modified := True;
      end;
    acWatchGrpMenu:
      if (FWatchSel >= 0) and (FWatchSel <= High(Project.Watch)) then
        GroupMenu(Project.WatchGroups, Project.Watch[FWatchSel].GroupId, acWatchGrpPick);
    acWatchGrpPick:
      if (FWatchSel >= 0) and (FWatchSel <= High(Project.Watch)) then
      begin
        if Par = 0 then Project.Watch[FWatchSel].GroupId := 0
        else if Par - 1 <= High(Project.WatchGroups) then
          Project.Watch[FWatchSel].GroupId := Project.WatchGroups[Par - 1].Id;
        Project.Modified := True;
      end;
    acSortTag: Cycle(FTagSort, FTagDesc, Par);
    acSortWatch: Cycle(FWatchSort, FWatchDesc, Par);
    acDbScl: DbSclMenu(Par);
  end;
end;

{ the data types to choose from: the elementary ones of the family; a variable also the IEC timer /
  counter, the PLC data types and an array to edit }
procedure TPlcUI.TypeMenu(ForVar: Boolean; Row: Integer; X, Y: Single);
var
  L: TStringList;
  Names: array of string;
  Acts: array of Integer;
  Ens: array of Boolean;
  K: Integer;
  Cur: string;
begin
  EndEdit(True);
  L := TStringList.Create;
  try
    L.Add('Bool');
    L.Add('Byte');
    L.Add('Word');
    L.Add('DWord');
    L.Add('Char');
    if IsTia(Project.Family) then L.Add('SInt');
    if IsTia(Project.Family) then L.Add('USInt');
    L.Add('Int');
    if IsTia(Project.Family) then L.Add('UInt');
    L.Add('DInt');
    if IsTia(Project.Family) then L.Add('UDInt');
    L.Add('Real');
    L.Add('Time');
    L.Add('S5Time');
    L.Add('Date');
    L.Add('Time_Of_Day');
    L.Add('String[20]');
    if IsTia(Project.Family) then L.Add('WChar');
    if IsTia(Project.Family) then L.Add('WString[20]');
    if IsTia(Project.Family) then L.Add('LReal');
    if Project.Family = cfS71500 then
    begin
      L.Add('LInt');
      L.Add('ULInt');
      L.Add('LWord');
      L.Add('LTime');
      L.Add('LTime_Of_Day');
      L.Add('LDT');
    end;
    if Project.Family <> cfS71200 then L.Add('Date_And_Time');
    if ForVar and IsTia(Project.Family) then L.Add('DTL');
    if ForVar then
    begin
      L.Add('IEC_TIMER');
      L.Add('IEC_COUNTER');
      if IsTia(Project.Family) then
      begin
        L.Add('TON_TIME');
        L.Add('TOF_TIME');
        L.Add('TP_TIME');
        L.Add('TONR_TIME');
        L.Add('CTU_INT');
        L.Add('CTD_INT');
        L.Add('CTUD_INT');
        L.Add('CTU_DINT');
        if Project.Family = cfS71500 then L.Add('TON_LTIME');
      end;
      L.Add('R_TRIG');
      L.Add('F_TRIG');
      L.Add('RS');
      L.Add('SR');
      for K := 0 to Project.UdtCount - 1 do L.Add('"' + Project.Udt(K).Name + '"');
      L.Add('Array[0..9] of Int');
      L.Add('Array[0..2, 0..3] of Int');
    end;
    if ForVar then
    begin
      if (CurDB = nil) or (Row > High(CurDB.Vars)) then Exit;
      Cur := CurDB.Vars[Row].TypeText;
      FTypeFor := Act(fdVarType, Row);
      FVarSel := Row;
    end
    else
    begin
      if Row > High(Project.Tags) then Exit;
      Cur := Project.Tags[Row].TypeText;
      FTypeFor := Act(fdTagType, Row);
      FTagSel := Row;
    end;
    SetLength(FTypeChoices, L.Count);
    SetLength(Names, L.Count);
    SetLength(Acts, L.Count);
    SetLength(Ens, L.Count);
    for K := 0 to L.Count - 1 do
    begin
      FTypeChoices[K] := L[K];
      if SameText(L[K], Cur) then Names[K] := L[K] + '   ✓' else Names[K] := L[K];
      Acts[K] := Act(acTypePick, K);
      Ens[K] := True;
    end;
  finally
    L.Free;
  end;
  OpenCtx(X, Y, Names, Acts, Ens);
end;

{ every tag: a name used twice, an address used twice (or overlapping), a data type that does not
  fit the address: what is wrong goes into FTagErr }
procedure TPlcUI.CheckTags;
var
  I, J, N, Sz, Lo1, Hi1, Lo2, Hi2: Integer;
  A: array of TAddr;
  AOk: array of Boolean;
  T: TDataType;
  ALo, AHi: Integer;
  E, Need: string;

  procedure Range(const X: TAddr; out L, H: Integer);
  begin
    L := X.Ofs;
    case X.Size of
      osWord: H := X.Ofs + 1;
      osDWord: H := X.Ofs + 3;
    else
      H := X.Ofs;
    end;
  end;

begin
  N := Length(Project.Tags);
  SetLength(FTagErr, N);
  SetLength(A, N);
  SetLength(AOk, N);
  for I := 0 to N - 1 do
  begin
    FTagErr[I] := '';
    AOk[I] := ParseAddr(Project.Tags[I].Address, A[I], E);
    if Trim(Project.Tags[I].Name) = '' then FTagErr[I] := 'no name'
    else if not AOk[I] then FTagErr[I] := 'address: ' + E
    else if not (A[I].Area in [arI, arQ, arM, arPI, arPQ]) then FTagErr[I] := 'a tag is I, Q or M (or PI / PQ)'
    else if not ParseDataType(Project.Tags[I].TypeText, T, ALo, AHi) or (T in [dtNone, dtStruct, dtIECTimer, dtIECCounter])
      or (AHi >= ALo) then   // an array is no tag
      FTagErr[I] := 'data type: ' + Project.Tags[I].TypeText + ' cannot be a tag'
    else if TypeOpSize(T) <> A[I].Size then
    begin
      Sz := DataTypeSize(T);
      case Sz of
        0: Need := 'a bit address (e.g. %M10.0)';
        1: Need := 'a byte (MB, IB, QB)';
        2: Need := 'a word (MW, IW, QW)';
      else
        Need := 'a double word (MD, ID, QD)';
      end;
      FTagErr[I] := Project.Tags[I].TypeText + ' needs ' + Need;
    end;
  end;
  // the same name, the same or an overlapping address
  for I := 0 to N - 1 do
    for J := 0 to N - 1 do
    begin
      if (I = J) or (FTagErr[I] <> '') then Continue;
      if (Trim(Project.Tags[I].Name) <> '') and SameText(Trim(Project.Tags[I].Name), Trim(Project.Tags[J].Name)) then
      begin
        FTagErr[I] := Format('the name is used twice (row %d)', [J + 1]);
        Continue;
      end;
      if AOk[I] and AOk[J] and (A[I].Area = A[J].Area) then
      begin
        Range(A[I], Lo1, Hi1);
        Range(A[J], Lo2, Hi2);
        if (Lo1 <= Hi2) and (Lo2 <= Hi1) then
          if (A[I].Size = osBit) and (A[J].Size = osBit) then
          begin
            if A[I].Bit = A[J].Bit then FTagErr[I] := Format('the address of "%s" too', [Project.Tags[J].Name]);
          end
          else if SameAddr(A[I], A[J]) then FTagErr[I] := Format('the address of "%s" too', [Project.Tags[J].Name])
          else FTagErr[I] := Format('overlaps "%s" (%s)', [Project.Tags[J].Name, Project.Tags[J].Address]);
      end;
    end;
end;

{ ====================================================================== }
{ Project                                                                }
{ ====================================================================== }

procedure TPlcUI.BuildProject;
var
  I, K: Integer;
  X, Y: Single;
  F: TCpuFamily;
begin
  D.Layer := lyText;
  Txt(fkUI, 10, 54, 112, 'name', cInkSoft);
  Field(44, 126, 590, 26, Act(fdProjName, 0), Project.Name, fkUIB, 14);
  Txt(fkUI, 10, 44, 160, 'author', cInkSoft);
  Field(44, 174, 590, 24, Act(fdProjAuthor, 0), Project.Author, fkUI, 12);
  Txt(fkUI, 10, 44, 206, 'comment', cInkSoft);
  Field(44, 220, 590, 24, Act(fdProjComment, 0), Project.Comment, fkUI, 12);
  D.Layer := lyText;
  if Project.FileName <> '' then TxtFit(fkMono, 10.5, 44, 256, 590, Project.FileName, cInkSoft)
  else Txt(fkUI, 11, 44, 256, 'not saved yet', cInkSoft);
  Txt(fkUI, 11, 44, 276, Format('%s  %s   %d blocks  %d DBs  %d tags  %s', [FamilyNames[Project.Family],
    Project.Model.Name, Project.BlockCount, Project.DBCount, Length(Project.Tags),
    IfThen(Project.Modified, 'modified', 'saved')]), cInk);
  Button(44, 304, 140, 32, 'Save', Act(acSave, 0), bsPrimary, True, 13);
  D.Layer := lyText;
  Txt(fkUI, 10, 200, 296, 'save as (file name in projects)', cInkSoft);
  Field(200, 310, 300, 26, Act(fdSaveAs, 0), FSaveAsName, fkMono, 12, 0, True, 'my_project');
  Button(508, 308, 126, 30, 'Save as', Act(acSaveAs, 0), bsNormal, FSaveAsName <> '', 12);
  Button(44, 352, 200, 30, 'Screenshot (PNG)  F12', Act(acShot, 0), bsNormal, True, 12);
  if FDevMenu or InfoVisible then Button(252, 352, 200, 30, 'Developer ▼', Act(acInfo, 0), bsToggleOn, True, 12)
  else Button(252, 352, 200, 30, 'Developer ▼', Act(acInfo, 0), bsNormal, True, 12);
  Button(460, 352, 174, 30, 'Export ...', Act(acExport, 0), bsGold, True, 12);
  D.Layer := lyText;
  Txt(fkUI, 10.5, 44, 400, 'Export: PNG / GIF / MP4 / SVG of the main picture and of every layer', cInkFaint);
  Txt(fkUI, 10.5, 44, 416, '(paper, sheets, ornaments, controls, text, overlay) in the info window.', cInkFaint);

  // settings
  Txt(fkUIB, 12, 54, 520, 'Cyclic interrupt OB' + IntToStr(Project.CyclicOB), cInk);
  Txt(fkUI, 10, 44, 540, 'interval in ms', cInkSoft);
  Field(44, 554, 120, 24, Act(fdCyclicMs, 0), IntToStr(Project.CyclicMs), fkMono, 12);
  Txt(fkUIB, 12, 44, 594, 'Clock memory byte', cInk);
  Txt(fkUI, 10, 44, 614, 'MB number, -1 = off (bit 5 = 1 Hz, bit 3 = 2 Hz, bit 7 = 0.5 Hz)', cInkSoft);
  Field(44, 628, 120, 24, Act(fdClockByte, 0), IntToStr(Project.ClockByte), fkMono, 12);
  Txt(fkUIB, 12, 44, 670, 'Keyboard', cInk);
  Txt(fkUI, 11, 44, 690, 'LAD: arrows move, F2 NO, F3 NC, F7 coil, B branch, Del delete, Enter operand', cInkSoft);
  Txt(fkUI, 11, 44, 708, 'STL: type directly, Enter new line, Tab aligns, Ctrl+V paste, Esc leaves', cInkSoft);
  Txt(fkUI, 11, 44, 726, 'Screens: Ctrl+1 .. Ctrl+8   CPU: F5 RUN, F6 STOP', cInkSoft);
  Txt(fkUI, 11, 44, 744, 'Changes take effect after Download (F8).', cInkSoft);

  // new project: every CPU of the four families
  D.Layer := lyText;
  for I := 0 to 3 do
  begin
    F := TCpuFamily(I);
    X := 700 + I * 220;
    Y := 112;
    D.Layer := lySheets;
    Shad(X, Y, 208, 250, 6, 2, 5, 70);
    RR(X, Y, 208, 250, 6, cSheet2);
    D.Layer := lyOrnament;
    RRL(X + 4, Y + 4, 200, 242, 4, 0.8, Alpha(cRed, 150));
    D.Layer := lyText;
    Txt(fkUIB, 15, X + 14, Y + 10, FamilyNames[F], cRedDark);
    case F of
      cfS7300: Txt(fkUI, 10, X + 14, Y + 32, 'STL + LAD, S5 timers, 2 ACCUs', cInkSoft);
      cfS7400: Txt(fkUI, 10, X + 14, Y + 32, 'STL + LAD, 4 ACCUs (ENT)', cInkSoft);
      cfS71500: Txt(fkUI, 10, X + 14, Y + 32, 'LAD + SCL + STL, IEC timers', cInkSoft);
    else
      Txt(fkUI, 10, X + 14, Y + 32, 'LAD + SCL, TON / CTU, NORM_X', cInkSoft);
    end;
    Y := Y + 56;
    for K := 0 to ModelCount - 1 do
      if Models[K].Family = F then
      begin
        if K = Project.ModelIdx then
          Button(X + 12, Y, 184, 30, Models[K].Name, Act(acNew, K), bsToggleOn, True, 11)
        else
          Button(X + 12, Y, 184, 30, Models[K].Name, Act(acNew, K), bsNormal, True, 11);
        Y := Y + 36;
      end;
  end;
  D.Layer := lyText;
  Txt(fkUI, 11, 700, 376, 'A click makes a new empty project for that CPU (OB1 with one network); the CPU goes to STOP.', cInkSoft);
  Txt(fkUI, 11, 700, 394, 'Finished programs to learn from and to try: the Example Projects below (motor, traffic light,', cInkSoft);
  Txt(fkUI, 11, 700, 412, 'tank, conveyor, star-delta, car wash, batch, alarms, ...). Load one, press RUN, use the I/O screen.', cInkSoft);
  Txt(fkUI, 11, 700, 430, 'Save keeps your copy in Projects; the example itself stays as it is.', cInkSoft);

  // files: a list box picks the folder (Projects / Example Projects), one list shows its files
  D.Layer := lyText;
  Txt(fkUI, 11, 700, 540, 'folder', cInkSoft);
  if FFolder = 0 then
    Button(744, 532, 300, 30, Format('Projects  (%d)  ▼', [FFiles.Count]), Act(acFolder, 0), bsGold, True, 12.5)
  else
    Button(744, 532, 300, 30, Format('Example Projects  (%d)  ▼', [FExamples.Count]), Act(acFolder, 0), bsGold,
      True, 12.5);
  Button(1272, 534, 160, 26, 'Go to Explorer', Act(IfThen(FFolder = 0, acExplorer, acExplorerEx), 0), bsGold, True, 11);
  Button(1440, 534, 120, 26, 'Refresh', Act(acRefresh, 0), bsNormal, True, 11);
  D.Layer := lyText;
  if FFolder = 0 then
  begin
    TxtFit(fkMono, 10, 1056, 540, 206, ProjectsDir, cInkFaint);
    if FFiles.Count = 0 then Txt(fkUI, 11, 704, 586, 'No project files yet: Save puts the project here.', cInkSoft);
    FileList(FFiles, acLoad, 7, whFiles, FFileScroll);
    FVs[9].Range := 0;
  end
  else
  begin
    TxtFit(fkMono, 10, 1056, 540, 206, ExamplesDir, cInkFaint);
    FileList(FExamples, acLoadEx, 9, whExamples, FExScroll);
    FVs[7].Range := 0;
  end;
end;

procedure TPlcUI.FileList(L: TStringList; ACode, ABar, AWheel: Integer; var AScroll: Single);
const
  Top = 574;
  Rows = 6;
var
  I: Integer;
  X, Y: Single;
  S: string;
begin
  // two in a row, six rows in sight; more scroll
  AScroll := EnsureRange(AScroll, 0, Max(0, (L.Count + 1) div 2 - Rows));
  ClipD(696, Top, 880, Rows * 42);
  Hit(696, Top, 880, Rows * 42, AWheel, hkWheel);
  for I := Round(AScroll) * 2 to Min(L.Count, (Round(AScroll) + Rows + 1) * 2) - 1 do
  begin
    X := 700 + (I mod 2) * 434;
    Y := Top + 4 + (I div 2 - Round(AScroll)) * 42;
    D.Layer := lyControls;
    if Hot(X, Y, 424, 36) then RR(X, Y, 424, 36, 5, Alpha(cGoldLight, 110))
    else RR(X, Y, 424, 36, 5, Alpha(cSheet2, 220));
    RRL(X, Y, 424, 36, 5, 0.8, Alpha(cRed, 120));
    D.Layer := lyText;
    S := ChangeFileExt(L[I], '');
    if ACode = acLoadEx then S := StringReplace(S, '_', ' ', [rfReplaceAll]);
    TxtFit(fkUIB, 12, X + 12, Y + 9, 400, S, cInk);
    Hit(X, Y, 424, 36, Act(ACode, I));
  end;
  UnclipD;
  if (L.Count + 1) div 2 > Rows then VScrollBar(ABar, 1564, Top, Rows * 42, (L.Count + 1) div 2, Rows, AScroll)
  else FVs[ABar].Range := 0;
end;

{ ====================================================================== }
{ Ports                                                                  }
{ ====================================================================== }

function TPlcUI.PortActive: Boolean;
var
  T: Double;
begin
  // the activity LED flickers while telegrams come and go
  Result := False;
  if Hub = nil then Exit;
  T := PlcNowMs;
  Result := ((T - Hub.LastRxMs < 90) or (T - Hub.LastTxMs < 90)) and (Frac(FTime * 12) < 0.6);
end;

procedure TPlcUI.DrawPortLeds(X, Y: Single; Link: Boolean);
begin
  Led(X, Y, 3, cJadeLight, Link);
  Led(X + 30, Y, 3, cAmber, Link and PortActive);
end;

{ where a test on this PC reaches the servers }
function TPlcUI.TestIp: string;
begin
  Result := CommIp(Project.Comm);
  if Result = '0.0.0.0' then Result := '127.0.0.1';
end;

procedure TPlcUI.SelfTestS7;
var
  C: TS7Client;
  St, R, Slot: Integer;
  B: TBytes;
  S, Oc: string;
  V: Integer;
begin
  if not Hub.Listening[prS7] then
  begin
    Toast('S7 self test: the S7 server is off', True);
    Exit;
  end;
  case Project.Family of
    cfS7300: Slot := 2;
    cfS7400: Slot := 3;
  else
    Slot := 1;
  end;
  C := TS7Client.Create;
  try
    if not C.Connect(TestIp, Project.Comm.S7Port, 0, Slot) then
    begin
      Toast('S7 self test: ' + C.LastError, True);
      Exit;
    end;
    St := C.CpuState;
    Oc := C.OrderCode;
    V := 4321 + Random(1000);
    R := C.WriteArea($83, 0, 100, [V shr 8, V and $FF]);
    if R = 0 then R := C.ReadArea($83, 0, 100, 2, B);
    if St = 8 then S := 'RUN' else if St = 4 then S := 'STOP' else S := '?';
    if R = 0 then
      Toast(Format('S7 self test ok: rack 0 slot %d, PDU %d, CPU %s, %s, wrote and read back MW100 = %d',
        [Slot, C.PduSize, S, Oc, (B[0] shl 8) or B[1]]))
    else
      Toast(Format('S7 self test: connected (CPU %s), but read / write refused: %s', [S, C.LastError]), True);
  finally
    C.Free;
  end;
end;

procedure TPlcUI.SelfTestModbus;
var
  C: TModbusClient;
  R, V: Integer;
  B, Q: TBytes;
begin
  if not Hub.Listening[prModbus] then
  begin
    Toast('Modbus self test: the Modbus server is off', True);
    Exit;
  end;
  C := TModbusClient.Create;
  try
    C.UnitId := Project.Comm.MbUnit;
    if not C.Open(TestIp, Project.Comm.MbPort) then
    begin
      Toast('Modbus self test: ' + C.LastError, True);
      Exit;
    end;
    V := 1234 + Random(1000);
    R := C.WriteReg(50, V);
    if R = 0 then R := C.ReadRegs(3, 50, 1, B);
    if R = 0 then R := C.ReadBits(1, 0, 16, Q);
    if R = 0 then
      Toast(Format('Modbus self test ok: holding register 50 (%s) = %d, coils 0..15 = %s', [
        IfThen(Project.Comm.MbHRArea = arDB, Format('DB%d.DBW100', [Project.Comm.MbHRDB]), 'MW100'),
        (B[0] shl 8) or B[1], IntToHex(Q[0] or (Q[1] shl 8), 4)]))
    else
      Toast(Format('Modbus self test: error %d %s', [R, C.LastError]), True);
  finally
    C.Free;
  end;
end;

procedure TPlcUI.BuildPorts;
var
  M: TCpuModel;
  X, Y: Single;
  Conns: TConnRows;
  Lg: TLogRows;
  I, N: Integer;
  C: TBGRAPixel;
  S: string;
  Link: Boolean;
begin
  M := Project.Model;
  Link := Hub.Listening[prS7] or Hub.Listening[prModbus];
  // ---------- the interface ----------
  D.Layer := lyControls;
  for I := 0 to 1 do
  begin
    X := 50 + I * 120;
    Shad(X, 120, 96, 70, 6, 2, 4, 80);
    RR(X, 120, 96, 70, 6, cCharcoal);
    RR(X + 18, 132, 60, 36, 3, BGRA(30, 26, 24));
    for N := 0 to 7 do Rc(X + 24 + N * 6.5, 133, 3.4, 8, cGoldDark);
    DrawPortLeds(X + 26, 180, (I = 0) and Link);
    D.Layer := lyText;
    if M.Family = cfS71200 then S := Format('X1 P%d', [I + 1])
    else if M.Family = cfS71500 then S := Format('X1 P%dR', [I + 1])
    else S := Format('X2 P%d', [I + 1]);
    Txt(fkUIB, 11, X + 48, 196, S, cInk, 1);
    D.Layer := lyControls;
  end;
  D.Layer := lyText;
  Txt(fkUIB, 12, 300, 118, 'Station', cInkSoft);
  TxtFit(fkUI, 12, 300, 134, 210, Project.Name, cInk);
  Txt(fkUIB, 12, 300, 156, 'Module', cInkSoft);
  TxtFit(fkUI, 12, 300, 172, 210, M.Name, cInk);
  // the IP address: typed (a.b.c.d) or chosen from this PC's addresses
  Txt(fkUIB, 12, 50, 214, 'IP address', cInk);
  Field(50, 234, 160, 28, Act(fdIp, 0), CommIp(Project.Comm), fkMono, 13);
  Button(214, 234, 30, 28, '▼', Act(acIpMenu, 0), bsGold, True, 11);
  D.Layer := lyText;
  Txt(fkUIB, 12, 270, 214, 'Subnet mask', cInk);
  Field(270, 234, 160, 28, Act(fdMask, 0), Project.Comm.Mask, fkMono, 13);
  D.Layer := lyText;
  if ((Hub.Status[prS7] <> '') and (Pos('not an address of this PC', Hub.Status[prS7]) > 0)) or
    ((Hub.Status[prModbus] <> '') and (Pos('not an address of this PC', Hub.Status[prModbus]) > 0)) then
    TxtFit(fkUIB, 10.5, 50, 268, 460, CommIp(Project.Comm) + ' is not an address of this PC: the servers cannot listen', cRed)
  else
    TxtFit(fkUI, 10.5, 50, 268, 460, Format('S7: %s.  Modbus: %s', [Hub.Status[prS7], Hub.Status[prModbus]]), cInkFaint);
  Txt(fkUI, 10.5, 50, 284, 'The servers listen on it. 127.0.0.1: tools on this PC only.', cInkSoft);
  Txt(fkUI, 10.5, 50, 300, '0.0.0.0: every interface: HMI / SCADA on the network reach the', cInkSoft);
  Txt(fkUI, 10.5, 50, 316, 'CPU at this PC''s address (Windows may ask to allow it). ▼ lists them.', cInkSoft);
  // IPC: the named pipe for programs on this PC
  Switch(50, 334, 46, 22, Project.Comm.IpcOn, Act(acIpcOn, 0));
  D.Layer := lyText;
  Txt(fkUIB, 12, 104, 335, 'IPC server', cInk);
  Txt(fkMono, 10.5, 186, 337, IpcPipeName, cInkSoft);
  Button(366, 332, 110, 26, 'Help ...', Act(acIpcHelp, 0), bsGold, True, 11);
  D.Layer := lyText;
  if FIpc <> nil then
    TxtFit(fkUI, 10, 50, 362, 430, Format('on: programs on this PC connect (%d now, %d requests)',
      [FIpc.ClientCount, FIpc.Requests]), cJade)
  else
    TxtFit(fkUI, 10, 50, 362, 430, 'off: Python, C#, PowerShell on this PC talk to the PLC through a pipe', cInkFaint);

  // ---------- S7 ----------
  X := 560;
  Switch(X, 118, 46, 22, Project.Comm.S7On, Act(acS7On, 0));
  D.Layer := lyText;
  Txt(fkUIB, 13, X + 56, 119, 'S7 server (PUT / GET, HMI, snap7)', cInk);
  Txt(fkUI, 10, X, 152, 'TCP port', cInkSoft);
  Field(X, 166, 80, 24, Act(fdS7Port, 0), IntToStr(Project.Comm.S7Port), fkMono, 12);
  D.Layer := lyText;
  if Hub.Listening[prS7] then C := cJade else if Project.Comm.S7On then C := cRed else C := cInkSoft;
  D.Layer := lyControls;
  El(X + 100, 178, 5, 5, C);
  D.Layer := lyText;
  TxtFit(fkUI, 11, X + 112, 170, 360, Hub.Status[prS7], C);
  Txt(fkUIB, 11, X, 204, 'Connect to', cInkSoft);
  Txt(fkMono, 11, X + 90, 204, Hub.ExpectedSlots + '  (TSAP 01.0' + IfThen(M.Family = cfS7300, '2',
    IfThen(M.Family = cfS7400, '3', '1')) + ')', cInk);
  if IsTia(M.Family) then
  begin
    Check(X, 228, 16, Project.Comm.PutGet, Act(acPutGet, 0));
    D.Layer := lyText;
    Txt(fkUI, 11.5, X + 24, 228, 'Permit access with PUT/GET from remote partners', cInk);
    Txt(fkUI, 10.5, X + 24, 246, 'off on a new CPU: reads and writes are refused.', cInkSoft);
    Txt(fkUI, 10.5, X + 24, 262, 'Optimized DBs never allow absolute access (DB1.DBW2).', cInkSoft);
  end
  else
  begin
    Txt(fkUI, 11, X, 230, FamilyNames[M.Family] + ': PUT / GET always allowed.', cInk);
    Txt(fkUI, 10.5, X, 248, 'Wrong slot in the connection request: the CPU does not answer.', cInkSoft);
  end;
  Txt(fkUI, 10.5, X, 284, 'Areas I Q M DB T C, bit to real, PDU up to 480 bytes, STOP / start,', cInkSoft);
  Txt(fkUI, 10.5, X, 300, 'SZL 0x0424 mode, 0x0011 order code, 0x001C identification.', cInkSoft);
  Button(X, 326, 150, 30, 'S7 self test', Act(acTestS7, 0), bsPrimary, Hub.Listening[prS7], 12);
  D.Layer := lyText;
  Txt(fkUI, 10.5, X + 160, 334, 'connects to ' + TestIp + ', writes / reads MW100', cInkFaint);

  // ---------- Modbus ----------
  X := 1096;
  Switch(X, 118, 46, 22, Project.Comm.MbOn, Act(acMbOn, 0));
  D.Layer := lyText;
  Txt(fkUIB, 13, X + 56, 119, 'Modbus TCP server', cInk);
  Txt(fkUI, 10, X, 152, 'TCP port', cInkSoft);
  Field(X, 166, 80, 24, Act(fdMbPort, 0), IntToStr(Project.Comm.MbPort), fkMono, 12);
  Txt(fkUI, 10, X + 92, 152, 'unit id', cInkSoft);
  Field(X + 92, 166, 56, 24, Act(fdMbUnit, 0), IntToStr(Project.Comm.MbUnit), fkMono, 12);
  Txt(fkUI, 10, X + 160, 152, 'holding registers', cInkSoft);
  Field(X + 160, 166, 80, 24, Act(fdMbHold, 0), HoldingText(Project.Comm), fkMono, 12);
  if Hub.Listening[prModbus] then C := cJade else if Project.Comm.MbOn then C := cRed else C := cInkSoft;
  D.Layer := lyControls;
  El(X + 4, 206, 5, 5, C);
  D.Layer := lyText;
  TxtFit(fkUI, 11, X + 16, 198, 460, Hub.Status[prModbus], C);
  Txt(fkMono, 10.5, X, 222, 'coil n            = Q n/8 . n mod 8   (FC 1 5 15)', cInk);
  Txt(fkMono, 10.5, X, 238, 'discrete input n  = I n/8 . n mod 8   (FC 2)', cInk);
  Txt(fkMono, 10.5, X, 254, 'input register n  = IW 2n             (FC 4)', cInk);
  if Project.Comm.MbHRArea = arDB then
    Txt(fkMono, 10.5, X, 270, Format('holding reg. n    = DB%d.DBW 2n       (FC 3 6 16)', [Project.Comm.MbHRDB]), cInk)
  else
    Txt(fkMono, 10.5, X, 270, 'holding reg. n    = MW 2n             (FC 3 6 16)', cInk);
  Txt(fkUI, 10.5, X, 290, Format('e.g. %%IW%d = input register %d, MW20 = holding register 10', [M.AIWord, M.AIWord div 2]),
    cInkSoft);
  Button(X, 326, 170, 30, 'Modbus self test', Act(acTestMb, 0), bsPrimary, Hub.Listening[prModbus], 12);
  D.Layer := lyText;
  Txt(fkUI, 10.5, X + 180, 334, 'writes / reads register 50', cInkFaint);

  // ---------- connections ----------
  Conns := Hub.ConnCopy;
  D.Layer := lyText;
  Txt(fkUIB, 11, 44, 432, 'Protocol', cInkSoft);
  Txt(fkUIB, 11, 120, 432, 'Partner', cInkSoft);
  Txt(fkUIB, 11, 290, 432, 'Since', cInkSoft);
  Txt(fkUIB, 11, 380, 432, 'Requests', cInkSoft);
  Txt(fkUIB, 11, 460, 432, 'In / out bytes', cInkSoft);
  Txt(fkUIB, 11, 580, 432, 'Details', cInkSoft);
  D.Layer := lyOrnament;
  Ln(40, 450, 764, 450, 0.8, Alpha(cGoldDark, 160));
  N := 0;
  for I := High(Conns) downto 0 do
  begin
    if N > 14 then Break;
    Y := 456 + N * 26;
    D.Layer := lyControls;
    if Odd(N) then Rc(36, Y - 2, 732, 25, Alpha(cSheet2, 130));
    if Conns[I].Active then El(52, Y + 10, 4.5, 4.5, cJade) else El(52, Y + 10, 4.5, 4.5, cInkFaint);
    D.Layer := lyText;
    if Conns[I].Active then C := cInk else C := cInkSoft;
    Txt(fkUIB, 11.5, 62, Y + 2, ProtoNames[Conns[I].Proto], C);
    TxtFit(fkMono, 11, 120, Y + 3, 166, Conns[I].Peer, C);
    Txt(fkMono, 11, 290, Y + 3, FormatDateTime('hh:nn:ss', Conns[I].Since), C);
    Txt(fkMono, 11, 380, Y + 3, IntToStr(Conns[I].Requests), C);
    Txt(fkMono, 11, 460, Y + 3, Format('%d / %d', [Conns[I].BytesIn, Conns[I].BytesOut]), C);
    TxtFit(fkUI, 11, 580, Y + 2, 186, Conns[I].Info, C);
    Inc(N);
  end;
  if N = 0 then
  begin
    D.Layer := lyText;
    Txt(fkUI, 12, 44, 460, 'No partner yet. Connect an HMI, snap7, Node-RED, a Modbus master ...', cInkSoft);
    Txt(fkUI, 12, 44, 480, 'or press a self test above.', cInkSoft);
    Txt(fkMono, 10.5, 44, 512, 'python-snap7:  c = snap7.client.Client()', cInkFaint);
    Txt(fkMono, 10.5, 44, 528, Format('               c.connect("%s", 0, %s, %d)', [TestIp,
      IfThen(M.Family = cfS7300, '2', IfThen(M.Family = cfS7400, '3', '1')), Project.Comm.S7Port]), cInkFaint);
    Txt(fkMono, 10.5, 44, 544, '               c.db_read(1, 0, 4);  c.get_cpu_state()', cInkFaint);
  end;
  D.Layer := lyText;
  Txt(fkUI, 11, 60, 828, Format('%d active, %d requests in total', [Hub.ActiveCount, Hub.Requests]), cInkSoft);

  // ---------- traffic ----------
  Lg := Hub.LogCopy(17);
  D.Layer := lyText;
  for I := 0 to High(Lg) do
  begin
    Y := 432 + I * 24;
    if Lg[I].Ok then C := cInk else C := cRed;
    Txt(fkMono, 10.5, 820, Y, FormatDateTime('hh:nn:ss.zzz', Lg[I].Time), cInkSoft);
    Txt(fkUIB, 10.5, 916, Y - 1, ProtoNames[Lg[I].Proto], cRedDark);
    TxtFit(fkUI, 11, 970, Y - 1, 590, IfThen(Lg[I].Peer <> '', Lg[I].Peer + '  ', '') + Lg[I].Text, C);
  end;
  if Length(Lg) = 0 then Txt(fkUI, 12, 820, 432, 'No traffic yet.', cInkSoft);
end;

{ ====================================================================== }
{ events                                                                 }
{ ====================================================================== }

procedure TPlcUI.PlaceElement(K: TLadKind);
var
  N: TNetwork;
  Ce: TLadCell;
  Down: Boolean;
begin
  N := CurNet;
  if (N = nil) or (N.Kind <> nkLAD) then Exit;
  Down := N.Cell(FCellR, FCellC).Down;
  Ce := NewCell(K, '');
  Ce.Down := Down;
  if K = lkWire then
  begin
    N.SetCell(FCellR, FCellC, Ce);
    if FCellC >= N.Cols - 1 then LadGrow(N, N.Cols + 1);
    if FCellC < N.Cols - 1 then Inc(FCellC);
    FLadFollow := True;
  end
  else
  begin
    // keep the operand when only the kind of contact / coil changes
    if (N.Cell(FCellR, FCellC).Kind in [lkNO, lkNC, lkCoil, lkCoilNeg, lkSet, lkReset, lkPos, lkNeg]) and
      (K in [lkNO, lkNC, lkCoil, lkCoilNeg, lkSet, lkReset, lkPos, lkNeg]) then
      Ce.Opnd := N.Cell(FCellR, FCellC).Opnd;
    N.SetCell(FCellR, FCellC, Ce);
    if not (K in [lkNot]) and (LadOpndName(K) <> '') then StartEdit(Act(fdOpnd, 0), Ce.Opnd)
    else if LadParamCount(K) > 0 then StartEdit(Act(fdPar, 0), Ce.P[0]);
  end;
  // an element in the last column: one more column, the rung can go on to the right
  if (K <> lkWire) and (FCellC >= N.Cols - 1) then LadGrow(N, N.Cols + 1);
  LadKeepBoxes(N);
  MarkDirty;
end;

procedure TPlcUI.DoClick(Id: Integer; const S: string);
var
  A9: TAddr;
  O9: TOperand;
  E9: string;
  Ok9: Boolean;
  Code9: Integer;
  Sd: TSaveDialog;
  Od: TOpenDialog;
  T: TDataType;
  SL: TStringList;
  Names: array of string;
  Acts: array of Integer;
  Ens: array of Boolean;
  Code, Par, I, N2: Integer;
  Q8: QWord;
  Nm: string;
  B: TBlock;
  N: TNetwork;
  Ce: TLadCell;
  Db: TDataBlock;
  O: TOperand;
  E: string;
  V: LongWord;
  F: TDispFmt;
  Ok: Boolean;
  Tmp: Pointer;
begin
  Code := Id shr 16;
  Par := Id and $FFFF;
  case Code of
    acTab:
      begin
        Screen := TScreen(Par);
        FStlNet := -1;
        if Screen = scProject then RefreshFiles;
      end;
    acRun: Rt.CmdRun;
    acStop: Rt.CmdStop;
    acMres:
      begin
        Rt.CmdMres;
        FSwitchPos := 2;
        FMresT := FTime;
      end;
    acSwitch:
      case Par of
        0: Rt.CmdRun;
        1: Rt.CmdStop;
        2:
          begin
            Rt.CmdMres;
            FSwitchPos := 2;
            FMresT := FTime;
          end;
        3:
          if FSwitchPos = 0 then Rt.CmdStop else Rt.CmdRun;
      end;
    acDownload: Download;
    acCompile: CompileOnly;
    acMonitor:
      begin
        FMonitor := not FMonitor;
        if FMonitor and FDirty then Toast('Monitor: download the changed program first (F8)', True);
      end;
    acModelSel: FModelSel := Par;
    acModelApply: ApplyModel(Par);
    acFamView:
      begin
        FFamView := TCpuFamily(Par);
        for I := 0 to ModelCount - 1 do
          if Models[I].Family = FFamView then
          begin
            FModelSel := I;
            if I = Project.ModelIdx then Break;
          end;
        if Project.Family = FFamView then FModelSel := Project.ModelIdx;
      end;
    acPacing: Rt.CmdPacing(TPacing(Par));
    acDiagClear: Rt.CmdClearDiag;
    { program }
    acBlockSel:
      begin
        FBlockSel := Par;
        FNetSel := 0;
        FCellR := 0;
        FCellC := 0;
        FStlNet := -1;
        FProgScroll := 0;
      end;
    acAddOB1:
      begin
        B := Project.AddBlock(bkOB, 1, 'Main');
        B.AddNet(nkLAD);
        FBlockSel := Project.Blocks.IndexOf(B);
        MarkDirty;
      end;
    acAddFC:
      begin
        N2 := 1;
        while Project.FindBlock(bkFC, N2) <> nil do Inc(N2);
        B := Project.AddBlock(bkFC, N2, 'Function ' + IntToStr(N2));
        B.AddNet(nkLAD);
        FBlockSel := Project.Blocks.IndexOf(B);
        FNetSel := 0;
        MarkDirty;
      end;
    acAddFB:
      begin
        N2 := 1;
        while Project.FindBlock(bkFB, N2) <> nil do Inc(N2);
        B := Project.AddBlock(bkFB, N2, 'Block_' + IntToStr(N2));
        B.Iface.AddSecVar(vsInput, 'Enable', 'Bool', 'FALSE', '');
        B.Iface.AddSecVar(vsOutput, 'Done', 'Bool', 'FALSE', '');
        B.AddNet(nkSCL).Stl.Text := '#Done := #Enable;';
        FBlockSel := Project.Blocks.IndexOf(B);
        FNetSel := 0;
        FIfaceShut := False;
        FIfSel := 0;
        MarkDirty;
      end;
    acIfToggle: FIfaceShut := not FIfaceShut;
    acIfSel: FIfSel := Par;
    acIfAdd:
      if (CurBlock <> nil) and (CurBlock.Kind <> bkOB) then
      begin
        B := CurBlock;
        if TVarSection(Par) = vsReturn then
        begin
          for I := 0 to High(B.Iface.Vars) do
            if B.Iface.Vars[I].Section = vsReturn then
            begin
              Toast('an FC has one Return value', True);
              Exit;
            end;
          FIfSel := B.Iface.AddSecVar(vsReturn, 'Ret_Val', 'Int', '', 'the function value: #Ret_Val := ..');
          StartEdit(Act(fdIfType, FIfSel), 'Int');
          MarkDirty;
          Exit;
        end;
        case TVarSection(Par) of
          vsInput: Nm := 'In';
          vsOutput: Nm := 'Out';
          vsInOut: Nm := 'InOut';
          vsStatic: Nm := 'Stat';
        else
          Nm := 'Tmp';
        end;
        N2 := 1;
        while B.Iface.FindVar(Nm + IntToStr(N2)) >= 0 do Inc(N2);
        if TVarSection(Par) in [vsInput, vsOutput] then
          FIfSel := B.Iface.AddSecVar(TVarSection(Par), Nm + IntToStr(N2), 'Bool', 'FALSE', '')
        else
          FIfSel := B.Iface.AddSecVar(TVarSection(Par), Nm + IntToStr(N2), 'Int', '0', '');
        StartEdit(Act(fdIfName, FIfSel), B.Iface.Vars[FIfSel].Name);
        MarkDirty;
      end;
    acIfDel:
      if (CurBlock <> nil) and (Length(CurBlock.Iface.Vars) > 0) then
      begin
        CurBlock.Iface.DeleteVar(FIfSel);
        FIfSel := Max(0, Min(FIfSel, High(CurBlock.Iface.Vars)));
        MarkDirty;
      end;
    acIfSec:
      if CurBlock <> nil then
      begin
        B := CurBlock;
        if Par > High(B.Iface.Vars) then Exit;
        Nm := B.Iface.Vars[Par].Name;
        // the next section this block has (an FC: no Static); Return only from its own button
        repeat
          if B.Iface.Vars[Par].Section = High(TVarSection) then B.Iface.Vars[Par].Section := Low(TVarSection)
          else B.Iface.Vars[Par].Section := Succ(B.Iface.Vars[Par].Section);
        until not ((B.Kind = bkFC) and (B.Iface.Vars[Par].Section = vsStatic) or
          (B.Iface.Vars[Par].Section = vsReturn));
        B.Iface.SortSections;
        B.Iface.Layout;
        FIfSel := Max(0, B.Iface.FindVar(Nm));
        MarkDirty;
      end;
    acIfInst:
      if (CurBlock <> nil) and (CurBlock.Kind = bkFB) then
      begin
        B := CurBlock;
        N2 := 1;
        while Project.FindDB(N2) <> nil do Inc(N2);
        Nm := B.Name + '_DB';
        if Project.FindDBByName(Nm) <> nil then Nm := Nm + IntToStr(N2);
        Db := Project.AddDB(N2, Nm);
        Db.InstanceOf := B.Number;
        Db.Optimized := IsTia(Project.Family);
        Db.Layout;
        Toast(Format('DB%d "%s": instance of %s', [N2, Nm, B.Title]));
        MarkDirty;
      end;
    acAddCyc:
      begin
        B := Project.AddBlock(bkOB, Project.CyclicOB, 'Cyclic interrupt');
        B.AddNet(nkLAD);
        FBlockSel := Project.Blocks.IndexOf(B);
        MarkDirty;
      end;
    acAddStartup:
      begin
        B := Project.AddBlock(bkOB, 100, 'Startup');
        B.AddNet(nkLAD);
        FBlockSel := Project.Blocks.IndexOf(B);
        MarkDirty;
      end;
    acDelBlock:
      if Project.BlockCount > 0 then
      begin
        Project.DeleteBlock(FBlockSel);
        FBlockSel := Max(0, FBlockSel - 1);
        FNetSel := 0;
        FStlNet := -1;
        MarkDirty;
      end;
    acNetSel:
      begin
        FNetSel := Par;
        FStlNet := -1;
      end;
    acAddLad, acAddStl, acAddScl:
      begin
        B := CurBlock;
        if B = nil then Exit;
        case Code of
          acAddLad: N := B.AddNet(nkLAD);
          acAddStl: N := B.AddNet(nkSTL);
        else
          N := B.AddNet(nkSCL);
        end;
        FNetSel := B.NetCount - 1;
        FCellR := 0;
        FCellC := 0;
        if Code <> acAddLad then
        begin
          FStlNet := FNetSel;
          FStlRow := 0;
          FStlCol := 0;
        end
        else
          FStlNet := -1;
        FProgScroll := 1E6;
        MarkDirty;
        if N = nil then ;
      end;
    acDelNet:
      begin
        B := CurBlock;
        B.DeleteNet(Par);
        FNetSel := Min(FNetSel, B.NetCount - 1);
        FStlNet := -1;
        MarkDirty;
      end;
    acAddMenu:
      if CurBlock <> nil then
      begin
        // no network yet: it is the first; else above / below the selected one
        if CurBlock.NetCount = 0 then DoClick(Act(acAddNet, Par * 2 + 1), '')
        else
          OpenCtx(280 + Par * 96, 142, [Format('Above network %d', [FNetSel + 1]),
            Format('Below network %d', [FNetSel + 1])], [Act(acAddNet, Par * 2), Act(acAddNet, Par * 2 + 1)],
            [True, True]);
      end;
    acAddNet:
      if CurBlock <> nil then
      begin
        // Par: the kind * 2 (0 LAD, 1 STL, 2 SCL) + 1 below the selected network
        B := CurBlock;
        if B.NetCount = 0 then I := 0
        else I := EnsureRange(FNetSel, 0, B.NetCount - 1) + Par mod 2;
        case Par div 2 of
          0: N := B.AddNet(nkLAD);
          1: N := B.AddNet(nkSTL);
        else
          N := B.AddNet(nkSCL);
        end;
        if I < B.NetCount - 1 then B.Networks.Move(B.NetCount - 1, I);
        FNetSel := I;
        FCellR := 0;
        FCellC := 0;
        LadCollapse;
        if N.Kind = nkLAD then FStlNet := -1
        else
        begin
          FStlNet := I;
          FStlRow := 0;
          FStlCol := 0;
          FEdNet := nil;
        end;
        FScrollToCaret := True;
        MarkDirty;
      end;
    acStlCtx:
      if FStlNet >= 0 then
        // the text menu: the same as the keys
        case Par of
          0: KeyDown(ukChar, 'z', [umCtrl]);
          1: KeyDown(ukChar, 'y', [umCtrl]);
          2: KeyDown(ukChar, 'x', [umCtrl]);
          3: KeyDown(ukChar, 'c', [umCtrl]);
          4:
            begin
              // the view reads the clipboard only with the keys: here from Windows
              Clipboard := Clipbrd.Clipboard.AsText;
              KeyDown(ukChar, 'v', [umCtrl]);
            end;
          5: KeyDown(ukDel, #0, []);
          6: KeyDown(ukChar, 'a', [umCtrl]);
          7: KeyDown(ukChar, 'q', [umCtrl]);
          8: KeyDown(ukChar, 'f', [umCtrl]);
          9: FindDeclaration;
          10: ShowView(0);
          11: ShowView(1);
        end;
    acNetUp, acNetDown:
      begin
        B := CurBlock;
        if Code = acNetUp then I := Par - 1 else I := Par + 1;
        if (I >= 0) and (I < B.NetCount) then
        begin
          Tmp := B.Networks[I];
          B.Networks[I] := B.Networks[Par];
          B.Networks[Par] := Tmp;
          FNetSel := I;
          FStlNet := -1;
          MarkDirty;
        end;
      end;
    acNetKind:
      begin
        // LAD -> STL -> SCL -> LAD (the S7-1200 has no STL); only an empty network
        N := CurBlock.Net(Par);
        if NetHasCode(N) then
          Toast('the network has code: its language stays (a new network for another language)', True)
        else
        begin
          case N.Kind of
            nkLAD: if HasStl(Project.Family) then N.Kind := nkSTL else N.Kind := nkSCL;
            nkSTL: N.Kind := nkSCL;
          else
            N.Kind := nkLAD;
          end;
          FNetSel := Par;
          FStlNet := -1;
          MarkDirty;
        end;
      end;
    acCell:
      begin
        FNetSel := Par div 256;
        if CurNet <> nil then
        begin
          FCellR := (Par mod 256) div CurNet.Cols;
          FCellC := (Par mod 256) mod CurNet.Cols;
        end;
        FStlNet := -1;
      end;
    acMenuClose: FMenuOpen := False;
    acClaude: FClaudeMenu := not FClaudeMenu;
    acClaudeMenuClose: FClaudeMenu := False;
    acClaudeMenu:
      begin
        FClaudeMenu := False;
        case Par of
          0: OpenClaude;   // open the chat window (or bring it to the front)
          1: OpenKeyDialog;
          2: if KeyToRemove then FKeyRmDlg := True;
        end;
      end;
    acKeyRemove:
      begin
        FKeyRmDlg := False;
        if Par = 1 then
        begin
          ClaudeRemoveEnvKey;   // the user variable and this process's
          ClaudeForgetKey;      // the encrypted file
          Toast(ClaudeKeyVar + ' is removed');
        end;
      end;
    acClaudeClose:
      begin
        EndEdit(False);
        FKeyDlg := False;
        FKeyText := '';
      end;
    acClaudeBg: ;
    acClaudeKeySave: SaveKey(Par = 1);
    acClaudeKeyForget:
      begin
        if Par = 0 then
        begin
          ClaudeRemoveEnvKey;
          FKeyMsg := 'The user variable ' + ClaudeKeyVar + ' is removed.';
        end
        else
        begin
          ClaudeForgetKey;
          FKeyMsg := 'The encrypted key file is deleted.';
        end;
        FKeyMsgErr := False;
      end;
    acMenu:
      begin
        FMenuOpen := False;
        case Par of
          0: LadCopy(False);
          1: LadCopy(True);
          2: LadPaste;
          3: LadDeleteSel;
          4: DoKey(ukChar, 'a', [umCtrl]);
        end;
      end;
    acColAdd:
      if (CurBlock <> nil) and (Par < CurBlock.NetCount) then
      begin
        FNetSel := Par;
        N := CurBlock.Net(Par);
        LadUndoPoint(N);
        LadGrow(N, N.Cols + 1);
        SetHS(N, 1E9);    // the new column into view
      end;
    acColDel:
      if (CurBlock <> nil) and (Par < CurBlock.NetCount) then
      begin
        N := CurBlock.Net(Par);
        if N.LastUsedCol >= N.Cols - 1 then
          Toast('the last column is not empty', True)
        else
        begin
          LadUndoPoint(N);
          N.SetCols(N.Cols - 1);
          FCellC := Min(FCellC, N.Cols - 1);
          MarkDirty;
        end;
      end;
    acFindNext:
      if FFindAt <> FTime then EdFind(False);
    acFindPrev: EdFind(True);
    acFindClose: FFindMode := 0;
    acFindCase: FFindCase := not FFindCase;
    acFindWord: FFindWord := not FFindWord;
    acReplOne: EdReplace(False);
    acReplAll: EdReplace(True);
    acGotoGo: if FFindAt <> FTime then EdGoto;
    acComp:
      begin
        FCompSel := Par;
        CompAccept;
      end;
    acStlLine:
      begin
        FNetSel := Par div 1024;
        N := CurNet;
        if (N = nil) or not (N.Kind in [nkSTL, nkSCL]) then Exit;
        FStlNet := FNetSel;
        FStlRow := Min(Par mod 1024, Max(0, N.Stl.Count - 1));
        if N.Stl.Count = 0 then FStlRow := 0;
        I := Round((FMX - (276 + 12 + 44)) / Max(1, TxtW(fkMono, 13, 'M')));
        if FStlRow < N.Stl.Count then FStlCol := EnsureRange(I, 0, UTF8Length(N.Stl[FStlRow]))
        else FStlCol := 0;
      end;
    acPal:
      begin
        PlaceElement(TLadKind(Par and $FF));
        N := CurNet;
        if (Par shr 8 > 0) and (N <> nil) and (N.Kind = nkLAD) and (N.Cell(FCellR, FCellC).Kind = lkCmp) then
        begin
          Ce := N.Cell(FCellR, FCellC);
          Ce.Cmp := TCmpOp((Par shr 8) - 1);
          N.SetCell(FCellR, FCellC, Ce);
        end;
      end;
    acBranch:
      begin
        N := CurNet;
        if (N = nil) or (FCellR + 1 >= N.Rows) then Exit;
        Ce := N.Cell(FCellR, FCellC);
        Ce.Down := not Ce.Down;
        N.SetCell(FCellR, FCellC, Ce);
        MarkDirty;
      end;
    acCellDel: LadDeleteSel;
    acRowIns:
      begin
        N := CurNet;
        if N = nil then Exit;
        N.InsertRow(FCellR + 1);
        Inc(FCellR);
        MarkDirty;
      end;
    acRowDel:
      begin
        N := CurNet;
        if N = nil then Exit;
        N.DeleteRow(FCellR);
        FCellR := Min(FCellR, N.Rows - 1);
        MarkDirty;
      end;
    acDType, acDType2:
      begin
        // the types of the box as a list
        N := CurNet;
        if (N = nil) or (N.Kind <> nkLAD) then Exit;
        Ce := N.Cell(FCellR, FCellC);
        SetLength(FLadTypes, 0);
        for T := Low(TDataType) to High(TDataType) do
          if (T in [dtInt, dtDInt, dtReal, dtByte, dtWord, dtDWord]) or
            (IsTia(Project.Family) and (T in [dtSInt, dtUSInt, dtUInt, dtUDInt])) then
            // ROUND, TRUNC, CEIL, FLOOR: OUT is an integer
            if not ((Code = acDType2) and (Ce.Kind <> lkConv) and (T = dtReal)) then
            begin
              SetLength(FLadTypes, Length(FLadTypes) + 1);
              FLadTypes[High(FLadTypes)] := T;
            end;
        SetLength(Names, Length(FLadTypes));
        SetLength(Acts, Length(FLadTypes));
        SetLength(Ens, Length(FLadTypes));
        for I := 0 to High(FLadTypes) do
        begin
          Names[I] := DataTypeNames[FLadTypes[I]];
          if ((Code = acDType) and (FLadTypes[I] = Ce.DType)) or ((Code = acDType2) and (FLadTypes[I] = Ce.DType2)) then
            Names[I] := Names[I] + '   ✓';
          Acts[I] := Act(acLadTypePick, Ord(Code = acDType2) * 256 + I);
          Ens[I] := True;
        end;
        OpenCtx(FMX, FMY + 14, Names, Acts, Ens);
      end;
    acLadTypePick:
      begin
        N := CurNet;
        if (N = nil) or (N.Kind <> nkLAD) or ((Par and $FF) > High(FLadTypes)) then Exit;
        LadUndoPoint(N);
        Ce := N.Cell(FCellR, FCellC);
        if Par shr 8 = 1 then Ce.DType2 := FLadTypes[Par and $FF] else Ce.DType := FLadTypes[Par and $FF];
        N.SetCell(FCellR, FCellC, Ce);
        MarkDirty;
      end;
    acCmpOp:
      begin
        N := CurNet;
        if N = nil then Exit;
        Ce := N.Cell(FCellR, FCellC);
        if Ce.Cmp = High(TCmpOp) then Ce.Cmp := Low(TCmpOp) else Ce.Cmp := Succ(Ce.Cmp);
        N.SetCell(FCellR, FCellC, Ce);
        MarkDirty;
      end;
    acMsg:
      if (Par <= High(FMsgs)) then
      begin
        for I := 0 to Project.BlockCount - 1 do
          if Project.Block(I).Title = FMsgs[Par].Block then
          begin
            FBlockSel := I;
            if FMsgs[Par].Net > 0 then FNetSel := FMsgs[Par].Net - 1;
            Screen := scProgram;
            // a text network: the caret goes to the line of the message
            FStlNet := -1;
            if (FNetSel < Project.Block(I).NetCount) and (Project.Block(I).Net(FNetSel).Kind in [nkSTL, nkSCL]) and
              (FMsgs[Par].Line > 0) then
            begin
              FStlNet := FNetSel;
              FStlRow := FMsgs[Par].Line - 1;
              FStlCol := 0;
            end;
            FScrollToCaret := True;
          end;
      end;
    { I/O }
    acDI:
      begin
        I := Par;
        Rt.SetSimBit(Rt.Model.DIByte + I div 8, I mod 8, not Rt.GetSimBit(Rt.Model.DIByte + I div 8, I mod 8));
      end;
    acDIType:
      begin
        I := Par;
        if Project.DIch[I].InType = High(TInType) then Project.DIch[I].InType := Low(TInType)
        else Project.DIch[I].InType := Succ(Project.DIch[I].InType);
        // the rest state of a push button
        Rt.SetSimBit(Rt.Model.DIByte + I div 8, I mod 8, Project.DIch[I].InType = itPushNC);
        Project.Modified := True;
      end;
    acAIMode:
      begin
        Project.AIch[Par div 4].AiMode := TAiMode(Par mod 4);
        Project.Modified := True;
      end;
    acBusFault: Rt.CmdBusFault(not Rt.BusFault);
    acAllOff:
      begin
        for I := 0 to Rt.Model.DI - 1 do
          Rt.SetSimBit(Rt.Model.DIByte + I div 8, I mod 8, Project.DIch[I].InType = itPushNC);
      end;
    { watch }
    acWatchRow: FWatchSel := Par;
    acWatchFmt:
      begin
        F := Project.Watch[Par].Fmt;
        if F = High(TDispFmt) then F := Low(TDispFmt) else F := Succ(F);
        Project.Watch[Par].Fmt := F;
        Project.Modified := True;
      end;
    acWatchModOn:
      Project.Watch[Par].ModifyOn := not Project.Watch[Par].ModifyOn;
    acWatchAdd:
      begin
        // the address after the one of the last row (its format too)
        Nm := NextWatchAddress;
        if Length(Project.Watch) > 0 then Project.AddWatch(Nm, Project.Watch[High(Project.Watch)].Fmt)
        else Project.AddWatch(Nm, dfDec);
        FWatchSel := High(Project.Watch);
        Project.Watch[FWatchSel].GroupId := GrpIdSel(1);
        StartEdit(Act(fdWatchAddr, FWatchSel), Nm);
      end;
    acWatchDel:
      begin
        Project.DeleteWatch(FWatchSel);
        FWatchSel := Max(0, Min(FWatchSel, High(Project.Watch)));
      end;
    acModifyNow:
      begin
        N2 := 0;
        for I := 0 to High(Project.Watch) do
          if Project.Watch[I].ModifyOn then
          begin
            if FRes.Resolve(Project.Watch[I].Address, O, E, False) and (O.Kind = okAddr) and
              (DataTypeSize(O.DType) = 8) then
            begin
              // a 64 bit variable: a number or a literal (LT#.., LDT#.., 1.5)
              if Parse64(O.DType, Project.Watch[I].ModifyValue, Q8) then
              begin
                Rt.CmdModifyStr(O, UIntToStr(Q8));
                Inc(N2);
              end
              else
                Toast(Format('Row %d: value "%s" does not fit %s', [I + 1, Project.Watch[I].ModifyValue,
                  Project.Watch[I].Address]), True);
            end
            else if FRes.Resolve(Project.Watch[I].Address, O, E, False) and (O.Kind = okAddr) and
              (O.DType in [dtString, dtWString]) then
            begin
              // a string: 'text' (or the text without quotes)
              E := Trim(Project.Watch[I].ModifyValue);
              if (Length(E) >= 2) and (E[1] = '''') and (E[Length(E)] = '''') then
                E := SclStrDecode(Copy(E, 2, Length(E) - 2), O.DType = dtWString);
              Rt.CmdModifyStr(O, E);
              Inc(N2);
            end
            else if FRes.Resolve(Project.Watch[I].Address, O, E, False) and (O.Kind = okAddr) and
              ParseValueText(Project.Watch[I].ModifyValue, O.A.Size, Project.Watch[I].Fmt, V) then
            begin
              Rt.CmdModify(O, V);
              Inc(N2);
            end
            else
              Toast(Format('Row %d: value "%s" does not fit %s', [I + 1, Project.Watch[I].ModifyValue,
                Project.Watch[I].Address]), True);
          end;
        if N2 > 0 then Toast(Format('Modified %d values', [N2]))
        else if N2 = 0 then Toast('Tick "Mod" for the rows to write', True);
      end;
    acForce, acUnforce:
      if (FWatchSel >= 0) and (FWatchSel <= High(Project.Watch)) then
      begin
        if not (FRes.Resolve(Project.Watch[FWatchSel].Address, O, E, False) and (O.Kind = okAddr)) then
        begin
          Toast('Force: ' + E, True);
          Exit;
        end;
        Ok := O.A.Area in [arI, arQ, arPI, arPQ];
        if (Project.Family = cfS7400) and (O.A.Area = arM) then Ok := True;
        if not Ok then
        begin
          Toast(Format('%s: only %s can be forced on the %s', [Project.Watch[FWatchSel].Address,
            IfThen(Project.Family = cfS7400, 'I, Q, M', 'I, Q'), FamilyNames[Project.Family]]), True);
          Exit;
        end;
        if Code = acUnforce then
        begin
          Rt.CmdUnforce(O);
          Project.Watch[FWatchSel].ForceOn := False;
        end
        else if ParseValueText(Project.Watch[FWatchSel].ModifyValue, O.A.Size, Project.Watch[FWatchSel].Fmt, V) then
        begin
          Rt.CmdForce(O, V);
          Project.Watch[FWatchSel].ForceOn := True;
          if IsTia(Project.Family) then Toast('Forced at the peripheral (:P): ' + Project.Watch[FWatchSel].Address)
          else Toast('Forced: ' + Project.Watch[FWatchSel].Address);
        end
        else
          Toast('Force: enter a value in "Modify value" first', True);
      end;
    acUnforceAll:
      begin
        Rt.CmdUnforceAll;
        for I := 0 to High(Project.Watch) do Project.Watch[I].ForceOn := False;
      end;
    { DBs }
    acDBSel:
      begin
        FDBSel := Par;
        FVarSel := 0;
        FVarScroll := 0;
      end;
    acDBAdd:
      begin
        N2 := 1;
        while Project.FindDB(N2) <> nil do Inc(N2);
        Db := Project.AddDB(N2, 'Data_' + IntToStr(N2));
        Db.Optimized := IsTia(Project.Family);
        Db.AddVar('Value', 'Int', '0', '');
        FDBSel := Project.DBs.IndexOf(Db);
        MarkDirty;
        ResetResolver;
      end;
    acUdtAdd:
      begin
        N2 := 1;
        while Project.FindUdt('UDT' + IntToStr(N2)) <> nil do Inc(N2);
        Db := Project.AddUdt(N2, 'Type_' + IntToStr(N2));
        Db.AddVar('Value', 'Int', '0', '');
        Db.AddVar('Active', 'Bool', 'FALSE', '');
        FDBSel := Project.DBCount + Project.Udts.IndexOf(Db);
        FVarSel := 0;
        MarkDirty;
      end;
    acDBDel:
      if CurDB <> nil then
      begin
        if SelIsUdt then Project.DeleteUdt(FDBSel - Project.DBCount)
        else Project.DeleteDB(FDBSel);
        FDBSel := Max(0, FDBSel - 1);
        MarkDirty;
      end;
    acDBOpt:
      begin
        Db := CurDB;
        Db.Optimized := not Db.Optimized;
        MarkDirty;
      end;
    acVarSel: FVarSel := Par;
    acVarAdd:
      begin
        Db := CurDB;
        if Db = nil then Exit;
        Db.AddVar('Var' + IntToStr(Length(Db.Vars) + 1), 'Int', '0', '');
        FVarSel := High(Db.Vars);
        StartEdit(Act(fdVarName, FVarSel), Db.Vars[FVarSel].Name);
        MarkDirty;
      end;
    acVarDel:
      begin
        Db := CurDB;
        if Db = nil then Exit;
        Db.DeleteVar(FVarSel);
        FVarSel := Max(0, Min(FVarSel, High(Db.Vars)));
        MarkDirty;
      end;
    acVarRetain:
      begin
        Db := CurDB;
        Db.Vars[Par].Retain := not Db.Vars[Par].Retain;
        MarkDirty;
      end;
    { tags }
    acTagSel: FTagSel := Par;
    acTagAdd:
      begin
        // the next name and the next address after the last tag (its type)
        SL := TStringList.Create;
        try
          for I := 0 to High(Project.Tags) do SL.Add(Project.Tags[I].Name);
          // the last tag of the group shown (of the table when the group has none)
          Code9 := High(Project.Tags);
          for I := 0 to High(Project.Tags) do
            if (FTagGrpSel >= 0) and (Project.Tags[I].GroupId = GrpIdSel(0)) then Code9 := I;
          if Length(Project.Tags) = 0 then
            Project.AddTag(NextName('Tag_0', SL), 'Bool', IfThen(IsTia(Project.Family), '%M100.0', 'M100.0'), '')
          else
            with Project.Tags[Code9] do
            begin
              Nm := NextName(Name, SL);
              if ParseAddr(Address, A9, E9) then
                E9 := StringReplace(FormatAddr(NextAddr(A9, TypeBytes(TypeText)), Project.Family), ' ', '', [rfReplaceAll])
              else
                E9 := Address;
              Project.AddTag(Nm, TypeText, E9, '');
            end;
        finally
          SL.Free;
        end;
        FTagSel := High(Project.Tags);
        Project.Tags[FTagSel].GroupId := GrpIdSel(0);
        StartEdit(Act(fdTagName, FTagSel), Project.Tags[FTagSel].Name);
        MarkDirty;
      end;
    acTagDel:
      begin
        Project.DeleteTag(FTagSel);
        FTagSel := Max(0, Min(FTagSel, High(Project.Tags)));
        MarkDirty;
      end;
    { project }
    acNew: AskSaveFirst('New project', Act(acNewNow, Par));
    acSample: AskSaveFirst('Load sample', Act(acSampleNow, Par));
    acQuitNow: QuitRequested := True;
    acAskDont:
      begin
        FAskOn := False;
        DoClick(FAskAct, '');
      end;
    acNewNow:
      begin
        Rt.CmdStop;
        Project.NewEmpty(Par);
        ProgUndoReset;
        Rt.CmdUnforceAll;
        SyncModel;
        FBlockSel := 0;
        FDBSel := 0;
        FVarSel := 0;
        FVarScroll := 0;
        FNetSel := 0;
        FStlNet := -1;
        FModelSel := Par;
        FFamView := Project.Family;
        ResetResolver;
        InvalidateStatic;
        Download;
        Toast('New empty project for ' + Models[Par].Name);
      end;
    acSampleNow: LoadSampleFor(Par);
    acSave: SaveProject;
    acSaveAs:
      if FSaveAsName <> '' then
      begin
        ForceDirectories(ProjectsDir);
        E := FSaveAsName;
        if LowerCase(ExtractFileExt(E)) <> '.vplc' then E := E + '.vplc';
        Project.FileName := ProjectsDir + ExtractFileName(E);
        SaveProject;
      end;
    acLoad:
      if Par < FFiles.Count then
      begin
        if Project.Modified then
          AskSaveFirst(Format('Load "%s"', [FFiles[Par]]), Act(acLoadNow, Par))
        else
          Ask('Load project', [Format('Load "%s"?', [FFiles[Par]]), Format('The project that is open now ("%s") is replaced,',
            [Project.Name]), 'the CPU goes to STOP.'], 'Load', Act(acLoadNow, Par));
      end;
    acLoadNow: if Par < FFiles.Count then LoadProjectFile(ProjectsDir + FFiles[Par]);
    acLoadEx:
      if Par < FExamples.Count then
      begin
        if Project.Modified then
          AskSaveFirst(Format('Load the example "%s"', [ChangeFileExt(FExamples[Par], '')]), Act(acLoadExNow, Par))
        else
          Ask('Load example project', [Format('Load the example "%s"?', [ChangeFileExt(FExamples[Par], '')]),
            Format('The project that is open now ("%s") is replaced,', [Project.Name]),
            'the CPU goes to STOP. Save keeps a copy in Projects.'], 'Load', Act(acLoadExNow, Par));
      end;
    acLoadExNow:
      if Par < FExamples.Count then
      begin
        LoadProjectFile(ExamplesDir + FExamples[Par]);
        // the example stays as it is: Save writes the copy to Projects
        if SameText(ExtractFileName(Project.FileName), FExamples[Par]) then Project.FileName := '';
      end;
    acAskOk:
      begin
        FAskOn := False;
        // Save first: when the save fails, nothing else happens
        if not FAskSave or SaveProjectOk then DoClick(FAskAct, '');
      end;
    acAskCancel: FAskOn := False;
    acCtx:
      begin
        FCtxOn := False;
        if (Par <= High(FCtxActs)) and FCtxEn[Par] then DoClick(FCtxActs[Par], '');
      end;
    acCtxClose: FCtxOn := False;
    acExportPc: ChooseExport(Par div 4096, (Par mod 4096) div 1024, Par mod 1024);
    acNetHead: DoClick(Act(acNetSel, Par), '');
    acWatchMenu:
      OpenCtx(830, 142, ['Save', 'Open ...', 'Save As ...', 'Export (CSV) ...', 'Import (CSV) ...'],
        [Act(acWatchFile, 0), Act(acWatchFile, 1), Act(acWatchFile, 2), Act(acWatchFile, 3), Act(acWatchFile, 4)],
        [Length(Project.Watch) > 0, True, Length(Project.Watch) > 0, Length(Project.Watch) > 0, True]);
    acWatchFile: WatchMenu(Par);
    acSclSrcMenu:
      OpenCtx(FMX, FMY, ['Import .scl source ...', 'Export this block as .scl ...', 'Export the project as .scl ...',
        'All variables ...', 'All elements ...'], [Act(acSclSrc, 0), Act(acSclSrc, 1), Act(acSclSrc, 2),
        Act(acSclSrc, 3), Act(acSclSrc, 4)], [True, CurBlock <> nil, True, True, True]);
    acSclSrc: SclSourceMenu(Par);
    acGrpSel..acDbScl: GroupAction(Code, Par);
    acIoView: FIoView := Par;
    acIoPage:
      case Par of
        0: Dec(FDIPage);
        1: Inc(FDIPage);
        2: Dec(FDQPage);
      else
        Inc(FDQPage);
      end;
    acTagIo:
      if Par <= High(FTagIo) then
      begin
        if ParseAddr(Project.Tags[FTagIo[Par]].Address, A9, E9) and (A9.Size = osBit) then
          Rt.SetSimBit(A9.Ofs, A9.Bit, not Rt.GetSimBit(A9.Ofs, A9.Bit));
      end;
    acSigRow: FSigSel := Par;
    acSigAdd:
      begin
        // the next input after the last row, its kind and values
        if Length(Project.Signals) = 0 then
          I := Project.AddSignal(StringReplace(FormatAddr(MakeAddr(arI, osBit, Rt.Model.DIByte, 0), Project.Family), ' ', '',
            [rfReplaceAll]), sgSquare, 0, 1, 1000, 50)
        else
        begin
          with Project.Signals[High(Project.Signals)] do
          begin
            I := Project.AddSignal('', Kind, Lo, Hi, PeriodMs, Duty);
            if FRes.Resolve(Address, O9, E9, False) and (O9.Kind = okAddr) then
            begin
              A9 := NextAddr(O9.A, DataTypeSize(O9.DType));
              E9 := '';
              if (Address <> '') and (Address[1] = '"') then E9 := FRes.SymbolOf(A9);
              if E9 = '' then E9 := StringReplace(FormatAddr(A9, Project.Family), ' ', '', [rfReplaceAll]);
              Project.Signals[I].Address := E9;
            end;
          end;
        end;
        FSigSel := I;
        MarkDirty;
      end;
    acSigDel:
      begin
        Project.DeleteSignal(FSigSel);
        FSigSel := Max(0, Min(FSigSel, High(Project.Signals)));
        MarkDirty;
      end;
    acSigAll:
      begin
        for I := 0 to High(Project.Signals) do Project.Signals[I].On := Par = 1;
        MarkDirty;
      end;
    acSigOn:
      if Par <= High(Project.Signals) then
      begin
        Project.Signals[Par].On := not Project.Signals[Par].On;
        MarkDirty;
      end;
    acSigKind:
      if Par <= High(Project.Signals) then
      begin
        FSigSel := Par;
        OpenCtx(FMX, FMY, SigKindNames, [Act(acSigKindPick, 0), Act(acSigKindPick, 1), Act(acSigKindPick, 2),
          Act(acSigKindPick, 3), Act(acSigKindPick, 4), Act(acSigKindPick, 5), Act(acSigKindPick, 6)],
          [True, True, True, True, True, True, True]);
      end;
    acSigKindPick:
      if FSigSel <= High(Project.Signals) then
      begin
        Project.Signals[FSigSel].Kind := TSigKind(Par);
        MarkDirty;
      end;
    acSigTags:
      begin
        // a row for every input tag that has none
        N2 := 0;
        for I := 0 to High(Project.Tags) do
          if ParseAddr(Project.Tags[I].Address, A9, E9) and (A9.Area in [arI, arPI]) then
          begin
            Nm := '"' + Project.Tags[I].Name + '"';
            Ok9 := False;
            for Code9 := 0 to High(Project.Signals) do
              if SameText(Project.Signals[Code9].Address, Nm) then Ok9 := True;
            if Ok9 then Continue;
            if A9.Size = osBit then Project.AddSignal(Nm, sgSquare, 0, 1, 1000 + 250 * N2, 50)
            else if SameText(Project.Tags[I].TypeText, 'Real') then Project.AddSignal(Nm, sgSine, 0, 100, 8000, 50)
            else Project.AddSignal(Nm, sgSine, 0, 27648, 8000, 50);
            Inc(N2);
          end;
        Toast(Format('%d rows added', [N2]));
        MarkDirty;
      end;
    acElemCat:
      if Par <= High(FElems) then
      begin
        if FElemOpen.IndexOf(FElemLang + FElems[Par].Cat) >= 0 then
          FElemOpen.Delete(FElemOpen.IndexOf(FElemLang + FElems[Par].Cat))
        else
          FElemOpen.Add(FElemLang + FElems[Par].Cat);
      end;
    acElemIns:
      begin
        ElemInsert(Par);
        FElemPress := -1;
      end;
    acElemCopy:
      if Par <= High(FElems) then
      begin
        ClipboardOut := ElemText(FElems[Par].Snip);
        Toast('Copied');
        FElemPress := -1;
      end;
    acHelpCopy: HelpCopy;
    acHelpAll:
      begin
        FHelp0 := Point(0, 0);
        FHelp1 := Point(Length(HelpLine(HelpCount - 1)), HelpCount - 1);
        FHelpFocus := True;
      end;
    acRefresh: RefreshFiles;
    acS7On:
      begin
        Project.Comm.S7On := not Project.Comm.S7On;
        Project.Modified := True;
        ApplyComm;
      end;
    acMbOn:
      begin
        Project.Comm.MbOn := not Project.Comm.MbOn;
        Project.Modified := True;
        ApplyComm;
      end;
    acPutGet:
      begin
        Project.Comm.PutGet := not Project.Comm.PutGet;
        Project.Modified := True;
        ApplyComm;
      end;
    acIface:
      begin
        Project.Comm.AllIfaces := Par = 1;
        if Par = 1 then Project.Comm.IpAddr := '0.0.0.0' else Project.Comm.IpAddr := '127.0.0.1';
        Project.Modified := True;
        ApplyComm;
      end;
    acIpMenu:
      begin
        // this PC only, every interface, and the addresses of this PC
        SL := TStringList.Create;
        try
          LocalIPv4List(SL);
          SetLength(FIpChoices, SL.Count + 2);
          FIpChoices[0] := '127.0.0.1';
          FIpChoices[1] := '0.0.0.0';
          for I := 0 to SL.Count - 1 do FIpChoices[I + 2] := SL[I];
        finally
          SL.Free;
        end;
        SetLength(Names, Length(FIpChoices));
        SetLength(Acts, Length(FIpChoices));
        SetLength(Ens, Length(FIpChoices));
        for I := 0 to High(FIpChoices) do
        begin
          case I of
            0: Names[I] := '127.0.0.1   (this PC only)';
            1: Names[I] := '0.0.0.0   (every interface)';
          else
            Names[I] := FIpChoices[I] + '   (this PC on the network)';
          end;
          Acts[I] := Act(acIpPick, I);
          Ens[I] := True;
        end;
        OpenCtx(50, 264, Names, Acts, Ens);
      end;
    acTagTypeMenu: TypeMenu(False, Par, 376, FMY + 12);
    acVarTypeMenu: TypeMenu(True, Par, 596, FMY + 12);
    acTypePick:
      if Par <= High(FTypeChoices) then
      begin
        CommitEdit(FTypeFor, FTypeChoices[Par]);
        if FTypeFor shr 16 = fdVarType then FVarSel := FTypeFor and $FFFF else FTagSel := FTypeFor and $FFFF;
      end;
    acIpcOn:
      begin
        Project.Comm.IpcOn := not Project.Comm.IpcOn;
        Project.Modified := True;
        ApplyIpc;
        if Project.Comm.IpcOn then Toast('IPC server on: ' + IpcPipeName) else Toast('IPC server off');
      end;
    acIpcHelp:
      begin
        if FHelpForm = nil then
        begin
          FHelpForm := THelpForm.CreateHelp(nil, 'Virtual PLC - Help: connect programs on this PC through IPC',
            IpcHelpHtml(Project.Model.Name));
          FHelpForm.OnPdf := @HelpPdf;
        end;
        FHelpForm.Show;
        FHelpForm.BringToFront;
      end;
    acIpcHelpClose: if Assigned(FHelpForm) then FHelpForm.Hide;
    acIpcHelpPdf:
      begin
        Sd := TSaveDialog.Create(nil);
        try
          Sd.Title := 'Export the IPC help';
          Sd.Filter := 'PDF (*.pdf)|*.pdf';
          Sd.DefaultExt := 'pdf';
          Sd.InitialDir := ExtractFilePath(ParamStr(0)) + 'export';
          ForceDirectories(Sd.InitialDir);
          Sd.FileName := 'VirtualPLC_IPC_help.pdf';
          Sd.Options := [ofOverwritePrompt, ofPathMustExist, ofEnableSizing];
          if Sd.Execute then ExportIpcHelp(Sd.FileName);
        finally
          Sd.Free;
        end;
      end;
    acIoImport:
      begin
        Od := TOpenDialog.Create(nil);
        try
          Od.Title := 'Import an I/O list';
          Od.Filter := 'CSV (*.csv;*.txt)|*.csv;*.txt|All files (*.*)|*.*';
          Od.InitialDir := ExtractFilePath(ParamStr(0)) + 'export';
          Od.Options := [ofFileMustExist, ofEnableSizing];
          if Od.Execute then Toast('I/O import: ' + ImportIo(Od.FileName));
        finally
          Od.Free;
        end;
      end;
    acIoHelp:
      begin
        if FIoHelpForm = nil then
        begin
          FIoHelpForm := THelpForm.CreateHelp(nil, 'Virtual PLC - Help: ' + IoHelpTitle,
            HelpDocHtml(IoHelpTitle, IoHelpIntro, IoImportHelpDoc));
          FIoHelpForm.OnPdf := @IoHelpPdf;
        end;
        FIoHelpForm.Show;
        FIoHelpForm.BringToFront;
      end;
    acIoHelpPdf:
      begin
        Sd := TSaveDialog.Create(nil);
        try
          Sd.Title := 'Export the help of the I/O import';
          Sd.Filter := 'PDF (*.pdf)|*.pdf';
          Sd.DefaultExt := 'pdf';
          Sd.InitialDir := ExtractFilePath(ParamStr(0)) + 'export';
          ForceDirectories(Sd.InitialDir);
          Sd.FileName := 'VirtualPLC_IO_import_help.pdf';
          Sd.Options := [ofOverwritePrompt, ofPathMustExist, ofEnableSizing];
          if Sd.Execute then ExportHelpDoc(Sd.FileName, IoHelpTitle, IoHelpIntro, IoImportHelpDoc);
        finally
          Sd.Free;
        end;
      end;
    acExplorer: ShowInExplorer(ExcludeTrailingPathDelimiter(ProjectsDir), False);
    acExplorerEx: ShowInExplorer(ExcludeTrailingPathDelimiter(ExamplesDir), False);
    acFolder:
      OpenCtx(744, 564, [Format('Projects  (%d)   %s', [FFiles.Count, 'projects' + PathDelim]),
        Format('Example Projects  (%d)   %s', [FExamples.Count, 'examples' + PathDelim])],
        [Act(acFolderPick, 0), Act(acFolderPick, 1)], [True, True]);
    acFolderPick: FFolder := Par;
    acUndo: ProgUndo(False);
    acRedo: ProgUndo(True);
    acFileCtx:
      if FFileCtxEx then
      begin
        if FFileCtx < FExamples.Count then
          case Par of
            0: DoClick(Act(acLoadEx, FFileCtx), '');
            1: ShowInExplorer(ExamplesDir + FExamples[FFileCtx], True);
          end;
      end
      else if FFileCtx < FFiles.Count then
        case Par of
          0: DoClick(Act(acLoad, FFileCtx), '');
          1: ShowInExplorer(ProjectsDir + FFiles[FFileCtx], True);
        end;
    acTagImport:
      begin
        Od := TOpenDialog.Create(nil);
        try
          Od.Title := 'Import tags';
          Od.Filter := 'CSV (*.csv;*.txt)|*.csv;*.txt|All files (*.*)|*.*';
          Od.InitialDir := ExtractFilePath(ParamStr(0)) + 'export';
          Od.Options := [ofFileMustExist, ofEnableSizing];
          if Od.Execute then Toast('Import: ' + ImportTags(Od.FileName));
        finally
          Od.Free;
        end;
      end;
    acIpPick:
      if Par <= High(FIpChoices) then CommitEdit(Act(fdIp, 0), FIpChoices[Par]);
    acTestS7: SelfTestS7;
    acTestMb: SelfTestModbus;
    acShot: ShotRequested := True;
    acInfo: FDevMenu := not FDevMenu;
    acDevMenuClose: FDevMenu := False;
    acDevMenu:
      begin
        FDevMenu := False;
        case Par of
          0: InfoRequested := True;
          1: InfoTopRequested := True;
          2: InfoCloseRequested := True;
        end;
      end;
    acExport: ExportRequested := True;
  end;
end;

procedure TPlcUI.DoPress(Id: Integer; Down: Boolean);
var
  I: Integer;
  V: Boolean;
begin
  if Id shr 16 <> acDI then Exit;
  I := Id and $FFFF;
  FDIPressed[I] := Down;
  V := Down;
  if Project.DIch[I].InType = itPushNC then V := not Down;
  Rt.SetSimBit(Rt.Model.DIByte + I div 8, I mod 8, V);
end;

procedure TPlcUI.DoDrag(Id: Integer; X, Y: Single; const R: TRectF);
var
  P9: TAddr;
  E9: string;
  P2, P3: TPoint;
  I, K, NI, Row0, Row, Col, Cl: Integer;
  F, CharW, TX: Single;
  N: TNetwork;
  P: TTextPos;
  Hd: THit;
begin
  if Id shr 16 = acHScroll then
  begin
    NI := Id and $FFFF;
    if (CurBlock = nil) or (NI >= CurBlock.NetCount) then Exit;
    N := CurBlock.Net(NI);
    F := N.Cols * FLadCW - LadCols * FLadCW;       // how far it can scroll (8 columns show)
    TX := Max(30, (R.Right - R.Left) * LadCols / N.Cols);   // the thumb
    if FDragPress <> FPressNo then
    begin
      FDragPress := FPressNo;
      CharW := R.Left + GetHS(N) / Max(1, F) * (R.Right - R.Left - TX);   // the thumb's left now
      if (X >= CharW) and (X <= CharW + TX) then FHsGrab := X - CharW else FHsGrab := TX / 2;
    end;
    SetHS(N, EnsureRange((X - FHsGrab - R.Left) / Max(1, R.Right - R.Left - TX) * F, 0, Max(0, F)));
    Exit;
  end;
  if Id shr 16 = acCell then
  begin
    NI := (Id and $FFFF) div 256;
    Cl := (Id and $FFFF) mod 256;
    if FDragPress <> FPressNo then
    begin
      // a press: select the cell (Shift: from the corner), grab the selection or an element, or start a band
      FDragPress := FPressNo;
      FCompOpen := False;
      FStlNet := -1;
      FNetSel := NI;
      N := CurNet;
      if (N = nil) or (N.Kind <> nkLAD) then Exit;
      FLadPress := Point(Cl mod N.Cols, Cl div N.Cols);
      FLadOff := Point(0, 0);
      FLadDropNet := -1;
      FLadPressM := PointF(X, Y);
      // a box is wider than its cell: a press on its right part lies over the next cell; the move
      // counts from there, so a click without a move leaves the box where it is
      CellAt(NI, X, Y, Row, Col);
      FLadGrab := Point(Col - FLadPress.X, Row - FLadPress.Y);
      if (umShift in MouseMods) and (FLsNet = NI) then
      begin
        FLsB := FLadPress;
        FLadMode := 1;
      end
      else if LadInSel(NI, FLadPress.Y, FLadPress.X) and
        ((FLsNet = NI) and ((FLsA.X <> FLsB.X) or (FLsA.Y <> FLsB.Y)) or
        not (N.Cell(FLadPress.Y, FLadPress.X).Kind in [lkEmpty, lkWire])) then
        FLadMode := 2
      else
      begin
        FLsNet := NI;
        FLsA := FLadPress;
        FLsB := FLadPress;
        // an element is grabbed; on an empty cell or a wire a rubber band starts
        if not (N.Cell(FLadPress.Y, FLadPress.X).Kind in [lkEmpty, lkWire]) then FLadMode := 2 else FLadMode := 1;
      end;
      FCellR := FLadPress.Y;
      FCellC := FLadPress.X;
      Exit;
    end;
    // dragging (near the edge the editor scrolls, near the side the network)
    if Y > 836 then FProgScroll := FProgScroll + 12;
    if Y < 160 then FProgScroll := FProgScroll - 12;
    if (CurBlock <> nil) and (NI < CurBlock.NetCount) then
    begin
      if X > 1262 then SetHS(CurBlock.Net(NI), GetHS(CurBlock.Net(NI)) + 14);
      if X < 300 then SetHS(CurBlock.Net(NI), Max(0, GetHS(CurBlock.Net(NI)) - 14));
    end;
    if FLadMode = 1 then
    begin
      CellAt(NI, X, Y, Row, Col);
      FLsNet := NI;
      FLsB := Point(Col, Row);
    end
    else if FLadMode = 2 then
    begin
      // over its own network, another LAD network of the block, or none
      I := LadNetAt(Y);
      if I = NI then
      begin
        FLadDropNet := -1;
        CellAt(NI, X, Y, Row, Col);
        FLadOff := Point(Col - FLadPress.X - FLadGrab.X, Row - FLadPress.Y - FLadGrab.Y);
      end
      else if I >= 0 then
      begin
        FLadDropNet := I;
        CellAt(I, X, Y, Row, Col);
        FLadDropAt := Point(Col - FLadGrab.X, Row - FLadGrab.Y);
      end
      else
        FLadDropNet := -2;
    end;
    Exit;
  end;
  if Id shr 16 = acIfDrag then
  begin
    I := Id and $FFFF;
    if FDragPress <> FPressNo then
    begin
      FDragPress := FPressNo;
      FIfSel := I;
      FVarDragOn := False;
      FDropKind := 0;
      if (CurBlock = nil) or (I > High(CurBlock.Iface.Vars)) then Exit;
      FVarDrag := '#' + CurBlock.Iface.Vars[I].Name;
      FVarX0 := X;
      FVarY0 := Y;
      Exit;
    end;
    if not FVarDragOn and (Abs(X - FVarX0) + Abs(Y - FVarY0) < 6) then Exit;
    FVarDragOn := True;
    DropTrack(X, Y, True);
    Exit;
  end;
  if Id shr 16 = acVScroll then
  begin
    I := Id and $FFFF;
    if (I > High(FVs)) or (FVs[I].Range <= FVs[I].View) then Exit;
    with FVs[I] do
    begin
      F := EnsureRange(H * View / Range, 24, H);                          // the thumb's height
      CharW := Top + EnsureRange(VsPos(I) / (Range - View), 0, 1) * (H - F); // its top
      if FDragPress <> FPressNo then
      begin
        // a press on the thumb holds it where it was taken; on the track the thumb comes to the mouse
        FDragPress := FPressNo;
        FVsDrag := I;
        if (Y >= CharW) and (Y <= CharW + F) then FVsGrab := Y - CharW else FVsGrab := F / 2;
      end;
      if H > F then SetVsPos(I, (Y - FVsGrab - Top) / (H - F) * (Range - View));
    end;
    Exit;
  end;
  if Id shr 16 = acElem then
  begin
    K := Id and $FFFF;
    if FDragPress <> FPressNo then
    begin
      // a press on an element: a double click puts it at the caret, a drag takes it into the code
      FDragPress := FPressNo;
      FHelpFocus := False;
      FCtxOn := False;
      FVarDragOn := False;
      FDropKind := 0;
      FElemPress := -1;
      if (K <= High(FElems)) and ((FElems[K].Snip <> '') or (FElems[K].Kind >= 0)) then
      begin
        if MouseClicks >= 2 then ElemInsert(K)
        else
        begin
          FElemPress := K;
          FVarDrag := ElemText(FElems[K].Snip);
          FVarX0 := X;
          FVarY0 := Y;
        end;
      end;
      Exit;
    end;
    if FElemPress < 0 then Exit;
    if not FVarDragOn and (Abs(X - FVarX0) + Abs(Y - FVarY0) < 6) then Exit;
    FVarDragOn := True;
    // LAD: onto a cell (an element into it, a name onto an element with an operand)
    FDropCell := (FElemLang = 'L') and (FElemPress <= High(FElems)) and (FElems[FElemPress].Kind >= 0);
    DropTrack(X, Y, FElemLang = 'L');
    FDropCell := False;
    Exit;
  end;
  if Id shr 16 = acHelp then
  begin
    if FDragPress <> FPressNo then
    begin
      // a press on the help: a click places, Shift extends, a double click takes the word,
      // a triple click the line; a press inside the selection drags it
      FDragPress := FPressNo;
      FHelpFocus := True;
      FCtxOn := False;
      FVarDragOn := False;
      FDropKind := 0;
      FStlNet := -1;
      P2 := HelpPosAt(X, Y);
      if MouseClicks >= 3 then
      begin
        FHelp0 := Point(0, P2.Y);
        FHelp1 := Point(Length(HelpLine(P2.Y)), P2.Y);
        FHelpMode := 0;
      end
      else if MouseClicks = 2 then
      begin
        HelpWord(P2, FHelpW0, FHelpW1);
        FHelp0 := FHelpW0;
        FHelp1 := FHelpW1;
        FHelpMode := 3;
      end
      else if HelpInSel(P2) and not (umShift in MouseMods) then
      begin
        FHelpMode := 2;
        FVarDrag := HelpSelText;
        FVarX0 := X;
        FVarY0 := Y;
      end
      else
      begin
        if not (umShift in MouseMods) then FHelp0 := P2;
        FHelp1 := P2;
        FHelpMode := 1;
      end;
      Exit;
    end;
    case FHelpMode of
      1: FHelp1 := HelpPosAt(X, Y);
      3:
        begin
          // by words from the one that was double clicked
          HelpWord(HelpPosAt(X, Y), P2, P3);
          if (P2.Y < FHelpW0.Y) or ((P2.Y = FHelpW0.Y) and (P2.X < FHelpW0.X)) then
          begin
            FHelp0 := FHelpW1;
            FHelp1 := P2;
          end
          else
          begin
            FHelp0 := FHelpW0;
            FHelp1 := P3;
          end;
        end;
      2:
        begin
          if not FVarDragOn and (Abs(X - FVarX0) + Abs(Y - FVarY0) < 6) then Exit;
          FVarDragOn := True;
          DropTrack(X, Y, False);
        end;
    end;
    Exit;
  end;
  if Id shr 16 = acStlLine then
  begin
    FHelpFocus := False;
    // a text line: click, Shift+click, drag, double / triple click, Alt+drag (a column), the line numbers
    NI := (Id and $FFFF) div 1024;
    Row0 := (Id and $FFFF) mod 1024;
    CharW := Max(1, TxtW(fkMono, 13, 'M'));
    TX := R.Left + 44;
    Row := Row0 + Floor((Y - R.Top) / 19);
    Col := Max(0, Round((X - TX) / CharW));
    if FDragPress <> FPressNo then
    begin
      FDragPress := FPressNo;
      FCompOpen := False;
      FNetSel := NI;
      N := CurNet;
      if (N = nil) or not (N.Kind in [nkSTL, nkSCL]) then Exit;
      FStlNet := NI;
      FStlRow := Min(Row0, Max(0, N.Stl.Count - 1));
      N := EdBegin;
      if N = nil then Exit;
      P := FEd.TP(EnsureRange(Row0, 0, N.Stl.Count - 1), Col);
      if X < TX - 4 then
      begin
        FDragMode := 3;
        FDragLine0 := P.Row;
        FEd.SelectLines(P.Row, P.Row);
      end
      else if MouseClicks = 2 then
      begin
        FDragMode := 2;
        FEd.SelectWord(P);
        FDragW1 := FEd.Anchor;
        FDragW2 := FEd.Caret;
      end
      else if MouseClicks >= 3 then
      begin
        FDragMode := 3;
        FDragLine0 := P.Row;
        FEd.SelectLines(P.Row, P.Row);
      end
      else
      begin
        FDragMode := 1;
        if umShift in MouseMods then FEd.MoveTo(P, True)
        else
        begin
          FEd.Block := False;
          FEd.MoveTo(P, False);
          if umAlt in MouseMods then FEd.Block := True;
        end;
      end;
      EdEnd(N);
      FScrollToCaret := False;
      // Ctrl+Click on a name: its declaration
      if (umCtrl in MouseMods) and not (umShift in MouseMods) and (MouseClicks = 1) and (X >= TX - 4) then
      begin
        FDragMode := 0;
        FindDeclaration;
      end;
      Exit;
    end;
    // dragging
    N := EdBegin;
    if N = nil then Exit;
    Row := EnsureRange(Row, 0, N.Stl.Count - 1);
    case FDragMode of
      3: FEd.SelectLines(FDragLine0, Row);
      2:
        begin
          // by words, the double clicked word stays selected
          P := FEd.TP(Row, Min(Col, FEd.LineLen(Row)));
          if PosLess(P, FDragW1) then
          begin
            FEd.Anchor := FDragW2;
            FEd.WordAt(P, I, NI);
            FEd.Caret := FEd.TP(Row, I);
          end
          else
          begin
            FEd.Anchor := FDragW1;
            FEd.WordAt(P, I, NI);
            FEd.Caret := FEd.TP(Row, NI);
            if PosLess(FEd.Caret, FDragW2) then FEd.Caret := FDragW2;
          end;
          FEd.WantCol := FEd.Caret.Col;
        end;
      1:
        begin
          FEd.Caret := FEd.TP(Row, Col);
          if not FEd.Block then FEd.Caret.Col := Min(Col, FEd.LineLen(Row));
          FEd.WantCol := FEd.Caret.Col;
        end;
    end;
    EdEnd(N);
    FScrollToCaret := False;
    Exit;
  end;
  if (Id shr 16 = acTagIoAi) and ((Id and $FFFF) <= High(FTagIo)) then
  begin
    I := Id and $FFFF;
    F := EnsureRange((X - (R.Left + 10)) / Max(1, R.Right - R.Left - 20), 0, 1);
    if ParseAddr(Project.Tags[FTagIo[I]].Address, P9, E9) then Rt.SetSimWord(P9.Ofs, Round(F * 27648));
    Exit;
  end;
  if Id shr 16 <> acAI then Exit;
  I := Id and $FFFF;
  F := EnsureRange((X - (R.Left + 10)) / Max(1, R.Right - R.Left - 20), 0, 1);
  Project.AIch[I].AiMode := amManual;
  Project.AIch[I].AiValue := Round(F * 27648);
end;

procedure TPlcUI.DoWheel(Id: Integer; DY: Single);
begin
  if Id >= whLad then
  begin
    // over a LAD network: Shift or a sideways wheel scrolls it, a plain wheel the editor
    if WheelShift and (CurBlock <> nil) and (Id - whLad < CurBlock.NetCount) then
      SetHS(CurBlock.Net(Id - whLad), Max(0, GetHS(CurBlock.Net(Id - whLad)) - DY * FLadCW))
    else
      FProgScroll := FProgScroll - DY * 60;
    Exit;
  end;
  case Id of
    whProg: FProgScroll := FProgScroll - DY * 60;
    whMsgs: FMsgScroll := FMsgScroll - DY;
    whWatch: FWatchScroll := FWatchScroll - DY;
    whBlocks: FBlockScroll := FBlockScroll - DY * 48;
    whDBList: FDBListScroll := FDBListScroll - DY * 46;
    whFiles: FFileScroll := FFileScroll - DY;
    whExamples: FExScroll := FExScroll - DY;
    whPal: FPalScroll := FPalScroll - DY * 26;
    whElem: FElemScroll := FElemScroll - DY * 48;
    whIo..whIo + 4: FIoScroll[Id - whIo] := FIoScroll[Id - whIo] - DY;
    whGrpTree, whGrpTree + 1: FGrpScroll[Id - whGrpTree] := FGrpScroll[Id - whGrpTree] - DY;
    whVars: FVarScroll := FVarScroll - DY;
    whTags: FTagScroll := FTagScroll - DY;
    whDiag: FDiagScroll := FDiagScroll - DY;
  end;
end;

procedure TPlcUI.StlInsert(const S: string);
var
  N: TNetwork;
begin
  FScrollToCaret := True;
  N := EdBegin;
  if N = nil then Exit;
  EdUndoPoint(N, 1);
  FEd.TypeText(S);
  EdEnd(N);
  if FCompOpen then
  begin
    if IsWordCh(S) then CompFilter else FCompOpen := False;
  end;
end;

{ ---------- the text editor: FEd works on the text of the network being edited ---------- }

function TPlcUI.EdBegin: TNetwork;
begin
  Result := CurNet;
  if (Result = nil) or not (Result.Kind in [nkSTL, nkSCL]) then Exit(nil);
  if Result.Stl.Count = 0 then Result.Stl.Add('');
  FEd.Lines := Result.Stl;
  FEd.Scl := Result.Kind = nkSCL;
  if FEd.Scl then FEd.TabW := 4 else FEd.TabW := 6;
  // the caret was moved from outside (a click, a message, another network): no selection
  if (FEdNet <> Result) or (FEd.Caret.Row <> FStlRow) or (FEd.Caret.Col <> FStlCol) then
  begin
    FEd.Caret := FEd.TP(FStlRow, FStlCol);
    FEd.Collapse;
    FEd.WantCol := FStlCol;
  end;
  FEdNet := Result;
  FEd.Changed := False;
  FEd.Clamp;
end;

procedure TPlcUI.EdEnd(N: TNetwork);
begin
  if N = nil then Exit;
  FStlRow := FEd.Caret.Row;
  FStlCol := FEd.Caret.Col;
  if FEd.Changed then MarkDirty;
  FEd.Changed := False;
end;

{ before a change: the text as it was. Kind 1 (typing) and 2 (deleting a character) join the step
  before them on the same line within 3 s, like Notepad++ joins a typed word }
procedure TPlcUI.EdUndoPoint(N: TNetwork; Kind: Integer);
begin
  // what the change that comes is: typing / deleting on a line joins the step before it
  FPKind := Kind;
  FPNet := N;
  FPRow := FEd.Caret.Row;
end;

function TPlcUI.FindNet(Net: TNetwork; out BI, NI: Integer): Boolean;
var
  I, J: Integer;
begin
  Result := False;
  for I := 0 to Project.BlockCount - 1 do
    for J := 0 to Project.Block(I).NetCount - 1 do
      if Project.Block(I).Net(J) = Net then
      begin
        BI := I;
        NI := J;
        Exit(True);
      end;
end;

procedure TPlcUI.EdUndo(Redo: Boolean);
begin
  ProgUndo(Redo);
end;

{ the next / previous match from the caret over the text networks of the block, round at the end }
function TPlcUI.EdFind(Back: Boolean; Quiet: Boolean): Boolean;
var
  B: TBlock;
  N: TNetwork;
  K, NI, Start: Integer;
  From, A, P2: TTextPos;
  Tmp: TTextEdit;
  Sel1, Sel2: TTextPos;
begin
  Result := False;
  B := CurBlock;
  if (B = nil) or (FFindText = '') then Exit;
  if FStlNet >= 0 then Start := FStlNet else Start := Max(0, FNetSel);
  Tmp := TTextEdit.Create;
  try
    for K := 0 to B.NetCount do
    begin
      if Back then NI := ((Start - K) mod B.NetCount + B.NetCount) mod B.NetCount
      else NI := (Start + K) mod B.NetCount;
      N := B.Net(NI);
      if not (N.Kind in [nkSTL, nkSCL]) or (N.Stl.Count = 0) then Continue;
      Tmp.Lines := N.Stl;
      if (K = 0) and (N = FEdNet) and (NI = FStlNet) then
      begin
        FEd.SelRange(Sel1, Sel2);
        if Back then From := Sel1 else From := Sel2;
      end
      else if (K = 0) and (NI = Start) and (FStlNet = NI) then
        From := Tmp.TP(FStlRow, FStlCol)
      else if Back then
        From := Tmp.TP(N.Stl.Count - 1, Tmp.LineLen(N.Stl.Count - 1))
      else
        From := Tmp.TP(0, 0);
      if (K = B.NetCount) and not ((N = FEdNet) and (NI = Start)) then Continue;
      if Tmp.Find(FFindText, From, Back, FFindCase, FFindWord, A, P2) then
      begin
        FNetSel := NI;
        FStlNet := NI;
        FEd.Lines := N.Stl;
        FEd.Scl := N.Kind = nkSCL;
        FEd.Block := False;
        FEd.Anchor := A;
        FEd.Caret := P2;
        FEd.WantCol := P2.Col;
        FEdNet := N;
        FStlRow := P2.Row;
        FStlCol := P2.Col;
        FScrollToCaret := True;
        if K > 0 then FFindMsg := '' else FFindMsg := '';
        if (Back and (NI > Start)) or (not Back and (NI < Start)) or (K = B.NetCount) then FFindMsg := 'wrapped round';
        Exit(True);
      end;
    end;
  finally
    Tmp.Free;
  end;
  if not Quiet then FFindMsg := Format('"%s" not found', [FFindText]);
end;

procedure TPlcUI.EdReplace(All: Boolean);
var
  B: TBlock;
  N: TNetwork;
  I, Cnt: Integer;
  P1, P2, From: TTextPos;
  Tmp: TTextEdit;
  Sel, F: string;
  Pushed: Boolean;
begin
  B := CurBlock;
  if (B = nil) or (FFindText = '') then Exit;
  if not All then
  begin
    // the selection is the match: replace it, then on to the next
    N := EdBegin;
    if N <> nil then
    begin
      Sel := FEd.SelText;
      F := FFindText;
      if not FFindCase then
      begin
        Sel := UTF8LowerCase(Sel);
        F := UTF8LowerCase(F);
      end;
      if FEd.HasSel and not FEd.Block and (Sel = F) then
      begin
        EdUndoPoint(N, 0);
        FEd.InsertText(FReplText);
        EdEnd(N);
      end;
    end;
    EdFind(False);
    Exit;
  end;
  Cnt := 0;
  Tmp := TTextEdit.Create;
  try
    for I := 0 to B.NetCount - 1 do
    begin
      N := B.Net(I);
      if not (N.Kind in [nkSTL, nkSCL]) then Continue;
      Tmp.Lines := N.Stl;
      From := Tmp.TP(0, 0);
      Pushed := False;
      while Tmp.Find(FFindText, From, False, FFindCase, FFindWord, P1, P2) do
      begin
        if not Pushed then
        begin
          // one undo step for the network
          FEd.Lines := N.Stl;
          FEd.Caret := P1;
          FEd.Anchor := P1;
          EdUndoPoint(N, 0);
          Pushed := True;
        end;
        Tmp.Block := False;
        Tmp.Anchor := P1;
        Tmp.Caret := P2;
        Tmp.InsertText(FReplText);
        From := Tmp.Caret;
        Inc(Cnt);
        if Cnt > 5000 then Break;
      end;
    end;
  finally
    Tmp.Free;
  end;
  FEdNet := nil;
  if Cnt > 0 then MarkDirty;
  FFindMsg := Format('%d replaced', [Cnt]);
end;

procedure TPlcUI.EdGoto;
var
  N: TNetwork;
  V: Integer;
begin
  N := EdBegin;
  if (N = nil) or not TryStrToInt(Trim(FGotoText), V) then Exit;
  FEd.MoveTo(FEd.TP(EnsureRange(V - 1, 0, N.Stl.Count - 1), 0), False);
  FEd.Home(False);
  EdEnd(N);
  FScrollToCaret := True;
  FFindMode := 0;
end;

procedure TPlcUI.EdOpenFind(Mode: Integer);
var
  S: string;
begin
  FFindMode := Mode;
  FFindMsg := '';
  if Mode = 3 then
  begin
    FGotoText := IntToStr(FStlRow + 1);
    StartEdit(Act(fdGoto, 0), FGotoText);
    Exit;
  end;
  // the selected text (one line) is what to look for
  if (FEdNet <> nil) and FEd.HasSel and not FEd.Block and (FEd.Caret.Row = FEd.Anchor.Row) then
  begin
    S := FEd.SelText;
    if S <> '' then FFindText := S;
  end;
  StartEdit(Act(fdFind, 0), FFindText);
end;

procedure TPlcUI.ActStl(const Key: TUiKey; Ch: Char; Mods: TUiMods);
var
  N, N2: TNetwork;
  Sh, Ct, Al: Boolean;
  S: string;
  C1, C2: Integer;
  At, M: TTextPos;
begin
  FScrollToCaret := True;
  N := EdBegin;
  if N = nil then
  begin
    FStlNet := -1;
    Exit;
  end;
  Sh := umShift in Mods;
  Ct := umCtrl in Mods;
  Al := umAlt in Mods;
  // the completion list takes the keys it needs
  if FCompOpen then
    case Key of
      ukUp:
        begin
          FCompSel := Max(0, FCompSel - 1);
          Exit;
        end;
      ukDown:
        begin
          FCompSel := Min(FComp.Count - 1, FCompSel + 1);
          Exit;
        end;
      ukPgUp:
        begin
          FCompSel := Max(0, FCompSel - 8);
          Exit;
        end;
      ukPgDn:
        begin
          FCompSel := Min(FComp.Count - 1, FCompSel + 8);
          Exit;
        end;
      ukEnter, ukTab:
        begin
          CompAccept;
          Exit;
        end;
      ukEsc:
        begin
          FCompOpen := False;
          Exit;
        end;
      ukBack:
        begin
          EdUndoPoint(N, 2);
          FEd.Backspace(False);
          EdEnd(N);
          CompFilter;
          Exit;
        end;
    else
      FCompOpen := False;
    end;
  // Alt+Up: Find Declaration (as in SCL Studio)
  if Al and not Sh and not Ct and (Key = ukUp) then
  begin
    EdEnd(N);
    FindDeclaration;
    Exit;
  end;
  // Alt+Shift+arrows: a column selection
  if Al and Sh and (Key in [ukLeft, ukRight, ukUp, ukDown]) then
  begin
    if not FEd.Block then
    begin
      FEd.Block := True;
      if not FEd.HasSel then FEd.Anchor := FEd.Caret;
    end;
    case Key of
      ukLeft:
        if FEd.Caret.Col > 0 then Dec(FEd.Caret.Col);
      ukRight: Inc(FEd.Caret.Col);
      ukUp: FEd.Caret.Row := Max(0, FEd.Caret.Row - 1);
      ukDown: FEd.Caret.Row := Min(N.Stl.Count - 1, FEd.Caret.Row + 1);
    end;
    FEd.WantCol := FEd.Caret.Col;
    EdEnd(N);
    Exit;
  end;
  case Key of
    ukEsc:
      if FFindMode > 0 then FFindMode := 0
      else if FEd.HasSel then FEd.Collapse
      else FStlNet := -1;
    ukEnter:
      begin
        EdUndoPoint(N, 0);
        FEd.NewLine;
      end;
    ukBack:
      begin
        if Ct or FEd.HasSel then EdUndoPoint(N, 0) else EdUndoPoint(N, 2);
        FEd.Backspace(Ct);
      end;
    ukDel:
      if Sh and not Ct then
      begin
        // Shift+Del: cut
        DoKey(ukChar, 'x', [umCtrl]);
        Exit;
      end
      else
      begin
        if Ct or FEd.HasSel then EdUndoPoint(N, 0) else EdUndoPoint(N, 2);
        FEd.Del(Ct);
      end;
    ukLeft: FEd.Left(Sh, Ct);
    ukRight: FEd.Right(Sh, Ct);
    ukUp:
      if Ct and Sh then
      begin
        EdUndoPoint(N, 0);
        FEd.MoveLines(-1);
      end
      else if (FEd.Caret.Row = 0) and not Sh and (FNetSel > 0) then
      begin
        // on into the network above
        Dec(FNetSel);
        if CurNet.Kind in [nkSTL, nkSCL] then
        begin
          FStlNet := FNetSel;
          FStlRow := Max(0, CurNet.Stl.Count - 1);
          FStlCol := Min(FEd.WantCol, UTF8Length(CurNet.Stl[FStlRow]));
        end
        else
          FStlNet := -1;
        Exit;
      end
      else
        FEd.Up(Sh);
    ukDown:
      if Ct and Sh then
      begin
        EdUndoPoint(N, 0);
        FEd.MoveLines(1);
      end
      else if (FEd.Caret.Row = N.Stl.Count - 1) and not Sh and (FNetSel < CurBlock.NetCount - 1) and
        (CurBlock.Net(FNetSel + 1).Kind in [nkSTL, nkSCL]) then
      begin
        // on into the network below
        Inc(FNetSel);
        N2 := CurNet;
        FStlNet := FNetSel;
        FStlRow := 0;
        if N2.Stl.Count > 0 then FStlCol := Min(FEd.WantCol, UTF8Length(N2.Stl[0])) else FStlCol := 0;
        Exit;
      end
      else
        FEd.Down(Sh);
    ukHome: if Ct then FEd.DocHome(Sh) else FEd.Home(Sh);
    ukEnd: if Ct then FEd.DocEnd(Sh) else FEd.EndKey(Sh);
    ukPgUp: FEd.Up(Sh, 15);
    ukPgDn: FEd.Down(Sh, 15);
    ukTab:
      begin
        EdUndoPoint(N, 0);
        FEd.Indent(Sh);
      end;
    ukInsert:
      if Sh then
      begin
        DoKey(ukChar, 'v', [umCtrl]);
        Exit;
      end
      else if Ct then
      begin
        DoKey(ukChar, 'c', [umCtrl]);
        Exit;
      end
      else
        FEd.Overwrite := not FEd.Overwrite;
    ukF3:
      begin
        if Ct then
        begin
          // Ctrl+F3: the word at the caret
          S := FEd.WordAt(FEd.Caret, C1, C2);
          if S <> '' then
          begin
            FFindText := S;
            FFindWord := True;
            FEd.Anchor := FEd.TP(FEd.Caret.Row, C1);
            FEd.Caret := FEd.TP(FEd.Caret.Row, C2);
          end;
        end;
        EdEnd(N);
        EdFind(Sh);
        Exit;
      end;
    ukChar:
      if Ct then
        case UpCase(Ch) of
          'A': FEd.SelectAll;
          'C':
            if FEd.HasSel then ClipboardOut := FEd.SelText
            else ClipboardOut := FEd.Line(FEd.Caret.Row) + LineEnding;   // no selection: the line
          'X':
            begin
              EdUndoPoint(N, 0);
              if FEd.HasSel then
              begin
                ClipboardOut := FEd.SelText;
                FEd.DeleteSel;
                FEd.Changed := True;
              end
              else
              begin
                ClipboardOut := FEd.Line(FEd.Caret.Row) + LineEnding;
                FEd.DeleteLines;
              end;
            end;
          'V':
            if Clipboard <> '' then
            begin
              EdUndoPoint(N, 0);
              FEd.InsertText(StringReplace(Clipboard, #9, StringOfChar(' ', FEd.TabW), [rfReplaceAll]));
            end;
          'Z':
            begin
              EdEnd(N);
              EdUndo(Sh);
              Exit;
            end;
          'Y':
            begin
              EdEnd(N);
              EdUndo(True);
              Exit;
            end;
          'D':
            begin
              EdUndoPoint(N, 0);
              FEd.DuplicateLines;
            end;
          'L':
            begin
              EdUndoPoint(N, 0);
              FEd.DeleteLines;
            end;
          'K':
            begin
              EdUndoPoint(N, 0);
              if Sh then FEd.Comment(-1) else FEd.Comment(1);
            end;
          'Q':
            begin
              EdUndoPoint(N, 0);
              FEd.Comment(0);
            end;
          'U':
            begin
              EdUndoPoint(N, 0);
              FEd.ChangeCase(Sh);
            end;
          'J':
            begin
              EdUndoPoint(N, 0);
              FEd.JoinLines;
            end;
          'T':
            begin
              // Notepad++: swap the line with the one above
              EdUndoPoint(N, 0);
              FEd.MoveLines(-1);
              FEd.Down(False);
            end;
          'B':
            if FEd.MatchBracket(FEd.Caret, At, M) then
            begin
              if Sh then FEd.MoveTo(M, True) else FEd.MoveTo(M, False);
            end;
          'F':
            begin
              EdEnd(N);
              EdOpenFind(1);
              Exit;
            end;
          'H':
            begin
              EdEnd(N);
              EdOpenFind(2);
              Exit;
            end;
          'G':
            begin
              EdEnd(N);
              EdOpenFind(3);
              Exit;
            end;
          ' ':
            begin
              EdEnd(N);
              CompStart;
              Exit;
            end;
        end;
  end;
  EdEnd(N);
end;

procedure TPlcUI.DoKey(Key: TUiKey; Ch: Char; Mods: TUiMods);
var
  N: TNetwork;
  Ce: TLadCell;
begin
  // global keys
  case Key of
    ukF5: begin Rt.CmdRun; Exit; end;
    ukF6: begin Rt.CmdStop; Exit; end;
    ukF7: begin CompileOnly; Exit; end;
    ukF8: begin Download; Exit; end;
    ukF9: begin DoClick(Act(acMonitor, 0), ''); Exit; end;
    ukF12: begin ShotRequested := True; Exit; end;
    ukF1: begin InfoRequested := True; Exit; end;
  end;
  if (Key = ukChar) and (umCtrl in Mods) and (UpCase(Ch) = 'S') then
  begin
    SaveProject;
    Exit;
  end;
  if FHelpFocus and (Screen = scProgram) and (FStlNet < 0) and (Key = ukChar) and (umCtrl in Mods) then
    case UpCase(Ch) of
      'C':
        begin
          HelpCopy;
          Exit;
        end;
      'A':
        begin
          FHelp0 := Point(0, 0);
          FHelp1 := Point(Length(HelpLine(HelpCount - 1)), HelpCount - 1);
          Exit;
        end;
    end;
  // the text editor has the keys while a network text is edited (Notepad++: Ctrl+D duplicates)
  if (Screen = scProgram) and (FStlNet >= 0) and not ((Key = ukChar) and (umCtrl in Mods) and (Ch in ['1'..'8'])) then
  begin
    ActStl(Key, Ch, Mods);
    Exit;
  end;
  if (Key = ukChar) and (umCtrl in Mods) then
    case UpCase(Ch) of
      'D': begin Download; Exit; end;
      '1'..'8':
        begin
          DoClick(Act(acTab, Ord(Ch) - Ord('1')), '');
          Exit;
        end;
    end;
  if (Screen = scProgram) and (FStlNet >= 0) then
  begin
    ActStl(Key, Ch, Mods);
    Exit;
  end;
  if Screen <> scProgram then Exit;
  N := CurNet;
  // Ctrl+Z / Ctrl+Y (Ctrl+Shift+Z) everywhere in the program editor
  if (Key = ukChar) and (umCtrl in Mods) and (UpCase(Ch) in ['Z', 'Y']) and ((N = nil) or (N.Kind <> nkLAD)) then
  begin
    ProgUndo((UpCase(Ch) = 'Y') or (umShift in Mods));
    Exit;
  end;
  if (N = nil) or (N.Kind <> nkLAD) then Exit;
  if FMenuOpen then
  begin
    FMenuOpen := False;
    if Key = ukEsc then Exit;
  end;
  // the selected cells: Ctrl+C / X / V, Delete, Ctrl+A, Ctrl+Z / Y, Shift+arrows, Esc
  if (Key = ukChar) and (umCtrl in Mods) then
  begin
    case UpCase(Ch) of
      'C': LadCopy(False);
      'X': LadCopy(True);
      'V': LadPaste;
      'A':
        begin
          FLsNet := FNetSel;
          FLsA := Point(0, 0);
          FLsB := Point(N.Cols - 1, N.Rows - 1);
        end;
      'Z': LadUndo(umShift in Mods);
      'Y': LadUndo(True);
    end;
    Exit;
  end;
  // the keyboard moves the selected cell: the editor keeps it inside the frame
  if Key in [ukLeft, ukRight, ukUp, ukDown, ukHome, ukEnd] then FScrollToCaret := True;
  if (Key in [ukLeft, ukRight, ukUp, ukDown]) and (umShift in Mods) then
  begin
    if FLsNet <> FNetSel then LadCollapse;
    case Key of
      ukLeft: FLsB.X := Max(0, FLsB.X - 1);
      ukRight: FLsB.X := Min(N.Cols - 1, FLsB.X + 1);
      ukUp: FLsB.Y := Max(0, FLsB.Y - 1);
      ukDown: FLsB.Y := Min(N.Rows - 1, FLsB.Y + 1);
    end;
    FCellR := FLsB.Y;
    FCellC := FLsB.X;
    Exit;
  end;
  if Key = ukEsc then
  begin
    LadCollapse;
    Exit;
  end;
  if Key = ukDel then
  begin
    LadDeleteSel;
    Exit;
  end;
  try
  case Key of
    ukLeft: FCellC := Max(0, FCellC - 1);
    ukRight:
      begin
        // past the last column the network grows
        if FCellC >= N.Cols - 1 then LadGrow(N, N.Cols + 1);
        FCellC := Min(N.Cols - 1, FCellC + 1);
      end;
    ukUp:
      if FCellR > 0 then Dec(FCellR)
      else if FNetSel > 0 then
      begin
        Dec(FNetSel);
        FCellR := 0;
      end;
    ukDown:
      if FCellR < N.Rows - 1 then Inc(FCellR)
      else if FNetSel < CurBlock.NetCount - 1 then
      begin
        Inc(FNetSel);
        FCellR := 0;
      end;
    ukDel: DoClick(Act(acCellDel, 0), '');
    ukInsert: DoClick(Act(acRowIns, 0), '');
    ukF2: PlaceElement(lkNO);
    ukF3: PlaceElement(lkNC);
    ukF4: PlaceElement(lkWire);
    ukF7: PlaceElement(lkCoil);
    ukEnter:
      begin
        Ce := N.Cell(FCellR, FCellC);
        if LadOpndName(Ce.Kind) <> '' then StartEdit(Act(fdOpnd, 0), Ce.Opnd)
        else if LadParamCount(Ce.Kind) > 0 then StartEdit(Act(fdPar, 0), Ce.P[0]);
      end;
    ukChar:
      case UpCase(Ch) of
        'B': DoClick(Act(acBranch, 0), '');
        'W': PlaceElement(lkWire);
      end;
  end;
  finally
    // a plain key: the selection is the focus cell again, the view follows it
    if Key in [ukLeft, ukRight, ukUp, ukDown, ukHome, ukEnd] then
    begin
      LadCollapse;
      FLadFollow := True;
    end;
  end;
end;

procedure TPlcUI.DoText(const S: string);
begin
  if (Screen = scProgram) and (FStlNet >= 0) then StlInsert(S);
end;

procedure TPlcUI.CommitEdit(Id: Integer; const S: string);
var
  Kg9, Gi9: Integer;
  Nm9: string;
  A9: TAddr;
  E9: string;
  C9: TConst;
  Bits9: LongWord;
  Sg9: Single;
  F9: Double;
  Code, Par, V, N2: Integer;
  N: TNetwork;
  Ce: TLadCell;
  Db: TDataBlock;
  B: TBlock;
begin
  Code := Id shr 16;
  Par := Id and $FFFF;
  case Code of
    fdClaudeKey: FKeyText := S;   // Enter saves (KeyDown), a button saves its way
    fdFind:
      begin
        FFindText := S;
        FFindAt := FTime;
        EdFind(False);
      end;
    fdRepl: FReplText := S;
    fdGoto:
      begin
        FGotoText := S;
        FFindAt := FTime;
        EdGoto;
      end;
    fdNetTitle:
      if Par < CurBlock.NetCount then
      begin
        CurBlock.Net(Par).Title := S;
        Project.Modified := True;
      end;
    fdNetComment:
      if Par < CurBlock.NetCount then
      begin
        CurBlock.Net(Par).Comment := S;
        Project.Modified := True;
      end;
    fdOpnd, fdPar, fdCallArg:
      begin
        N := CurNet;
        if N = nil then Exit;
        Ce := N.Cell(FCellR, FCellC);
        if Code = fdOpnd then Ce.Opnd := Trim(S)
        else if Code = fdCallArg then SetCallArg(Ce, Par, Trim(S))
        else Ce.P[Par] := Trim(S);
        N.SetCell(FCellR, FCellC, Ce);
        MarkDirty;
      end;
    fdBlockName:
      begin
        B := CurBlock;
        if (B <> nil) and (Trim(S) <> '') and (Trim(S) <> B.Name) then
        begin
          // the code follows: "Old" -> "New" everywhere (calls, operands, the FB types of multi-instances)
          N2 := RenameBlockInCode(Project, B, Trim(S));
          ResetResolver;
          if N2 > 0 then Toast(Format('renamed: %d places in the code follow', [N2]))
          else Toast('renamed');
        end;
        MarkDirty;
      end;
    fdGrpName:
      begin
        // not empty, not the root's name; a name used twice is allowed (red in the tree)
        Kg9 := Par div 16384;
        Gi9 := Par mod 16384;
        if Kg9 = 0 then Nm9 := AllTagsName else Nm9 := AllWatchName;
        if not GroupNameOk(S, Nm9, E9) then Toast(E9, True)
        else if (Kg9 = 0) and (Gi9 <= High(Project.TagGroups)) then Project.TagGroups[Gi9].Name := Trim(S)
        else if (Kg9 = 1) and (Gi9 <= High(Project.WatchGroups)) then Project.WatchGroups[Gi9].Name := Trim(S);
        Project.Modified := True;
      end;
    fdTagIoVal:
      if Par <= High(FTagIo) then
      begin
        // a value for an input tag: the number (Real, Time ..) into its bytes
        with Project.Tags[FTagIo[Par]] do
          if ParseAddr(Address, A9, E9) and ParseStartValue(S, C9) then
          begin
            N2 := Max(1, Min(4, TypeBytes(TypeText)));
            Bits9 := C9.Bits;
            if SameText(TypeText, 'Real') and (C9.Kind in [ckInt, ckDInt]) then
            begin
              Sg9 := C9.I;
              Move(Sg9, Bits9, 4);
            end;
            Rt.SetSimRaw(A9.Ofs, N2, Bits9);
          end
          else
            Toast('not a value for ' + TypeText + ': ' + S, True);
      end;
    fdSigAddr, fdSigLo, fdSigHi, fdSigPer, fdSigDuty, fdSigCmt:
      if Par <= High(Project.Signals) then
      begin
        case Code of
          fdSigAddr: Project.Signals[Par].Address := Trim(S);
          fdSigCmt: Project.Signals[Par].Comment := S;
        else
          if StrToFloatDot(Trim(S), F9) then
            case Code of
              fdSigLo: Project.Signals[Par].Lo := F9;
              fdSigHi: Project.Signals[Par].Hi := F9;
              fdSigPer: Project.Signals[Par].PeriodMs := Max(1, F9);
            else
              Project.Signals[Par].Duty := EnsureRange(F9, 0, 100);
            end
          else
            Toast('a number expected: ' + S, True);
        end;
        MarkDirty;
      end;
    fdBlockVer:
      begin
        B := CurBlock;
        if B <> nil then B.Version := Trim(S);
        MarkDirty;
      end;
    fdIfName, fdIfType, fdIfStart, fdIfComment:
      begin
        B := CurBlock;
        if (B = nil) or (Par > High(B.Iface.Vars)) then Exit;
        case Code of
          fdIfName: B.Iface.Vars[Par].Name := Trim(S);
          fdIfType: B.Iface.Vars[Par].TypeText := Trim(S);
          fdIfStart: B.Iface.Vars[Par].Start := Trim(S);
          fdIfComment: B.Iface.Vars[Par].Comment := S;
        end;
        B.Iface.Layout;
        MarkDirty;
      end;
    fdDBInst:
      if (CurDB <> nil) and not SelIsUdt and TryStrToInt(Trim(S), V) and (V >= 0) then
      begin
        if (V > 0) and (Project.FindBlock(bkFB, V) = nil) then
          Toast(Format('FB%d does not exist', [V]), True)
        else
        begin
          CurDB.InstanceOf := V;
          CurDB.Layout;
          MarkDirty;
        end;
      end;
    fdWatchAddr:
      if Par <= High(Project.Watch) then
      begin
        Project.Watch[Par].Address := Trim(S);
        Project.Modified := True;
      end;
    fdWatchMod:
      if Par <= High(Project.Watch) then
      begin
        Project.Watch[Par].ModifyValue := Trim(S);
        Project.Watch[Par].ModifyOn := Trim(S) <> '';
        Project.Modified := True;
      end;
    fdDBNum:
      if TryStrToInt(Trim(S), V) and (V > 0) and (CurDB <> nil) then
      begin
        if SelIsUdt then
        begin
          if Project.FindUdt('UDT' + IntToStr(V)) <> nil then
            Toast(Format('UDT%d exists already', [V]), True)
          else
          begin
            RenameUdtRefs(Project, Format('UDT%d', [CurDB.Number]), Format('UDT%d', [V]));
            CurDB.Number := V;
            MarkDirty;
          end;
        end
        else if Project.FindDB(V) <> nil then
          Toast(Format('DB%d exists already', [V]), True)
        else
        begin
          CurDB.Number := V;
          MarkDirty;
        end;
      end;
    fdDBName:
      if CurDB <> nil then
      begin
        if SelIsUdt and (Trim(S) <> '') then
        begin
          if (Project.FindUdt('"' + Trim(S) + '"') <> nil) and (Project.FindUdt('"' + Trim(S) + '"') <> CurDB) then
          begin
            Toast('a data type "' + Trim(S) + '" exists already', True);
            Exit;
          end;
          RenameUdtRefs(Project, '"' + CurDB.Name + '"', '"' + Trim(S) + '"');
        end;
        CurDB.Name := Trim(S);
        MarkDirty;
      end;
    fdDBComment:
      if CurDB <> nil then
      begin
        CurDB.Comment := S;
        Project.Modified := True;
      end;
    fdVarName, fdVarType, fdVarStart, fdVarComment:
      begin
        Db := CurDB;
        if (Db = nil) or (Par > High(Db.Vars)) then Exit;
        case Code of
          fdVarName: Db.Vars[Par].Name := Trim(S);
          fdVarType: Db.Vars[Par].TypeText := Trim(S);
          fdVarStart: Db.Vars[Par].Start := Trim(S);
          fdVarComment: Db.Vars[Par].Comment := S;
        end;
        Db.Layout;
        MarkDirty;
      end;
    fdTagName, fdTagType, fdTagAddr, fdTagComment:
      begin
        if Par > High(Project.Tags) then Exit;
        case Code of
          fdTagName: Project.Tags[Par].Name := Trim(StringReplace(S, '"', '', [rfReplaceAll]));
          fdTagType: Project.Tags[Par].TypeText := Trim(S);
          fdTagAddr: Project.Tags[Par].Address := Trim(S);
          fdTagComment: Project.Tags[Par].Comment := S;
        end;
        MarkDirty;
      end;
    fdProjName: begin Project.Name := S; Project.Modified := True; end;
    fdProjAuthor: begin Project.Author := S; Project.Modified := True; end;
    fdProjComment: begin Project.Comment := S; Project.Modified := True; end;
    fdSaveAs: FSaveAsName := Trim(S);
    fdIp:
      if IsIPv4(S) then
      begin
        Project.Comm.IpAddr := Trim(S);
        Project.Comm.AllIfaces := Project.Comm.IpAddr = '0.0.0.0';
        Project.Modified := True;
        ApplyComm;
        Toast('The servers listen on ' + Project.Comm.IpAddr);
      end
      else
        Toast('Not an IP address: four numbers 0..255 with dots, e.g. 192.168.0.10', True);
    fdMask:
      if IsIPv4(S) then
      begin
        Project.Comm.Mask := Trim(S);
        Project.Modified := True;
      end
      else
        Toast('Not a subnet mask: four numbers 0..255 with dots, e.g. 255.255.255.0', True);
    fdS7Port, fdMbPort, fdMbUnit:
      if TryStrToInt(Trim(S), V) and (V >= Ord(Code = fdMbUnit) * 0) and (V <= 65535) and
        ((Code <> fdMbUnit) or (V <= 255)) and ((Code = fdMbUnit) or (V >= 1)) then
      begin
        case Code of
          fdS7Port: Project.Comm.S7Port := V;
          fdMbPort: Project.Comm.MbPort := V;
        else
          Project.Comm.MbUnit := V;
        end;
        Project.Modified := True;
        ApplyComm;
      end
      else
        Toast('Port 1 .. 65535, unit id 0 .. 255', True);
    fdMbHold:
      if SetHolding(Project.Comm, S) then
      begin
        Project.Modified := True;
        ApplyComm;
      end
      else
        Toast('Holding registers: M (MW 2n) or DBn (DBn.DBW 2n)', True);
    fdCyclicMs:
      if TryStrToInt(Trim(S), V) and (V >= 1) and (V <= 60000) then
      begin
        Project.CyclicMs := V;
        MarkDirty;
      end
      else
        Toast('Cyclic interval: 1 .. 60000 ms', True);
    fdClockByte:
      if TryStrToInt(Trim(S), V) and (V >= -1) and (V < Project.Model.MBytes) then
      begin
        Project.ClockByte := V;
        MarkDirty;
      end
      else
        Toast('Clock memory byte: -1 or 0 .. ' + IntToStr(Project.Model.MBytes - 1), True);
  end;
end;

end.
