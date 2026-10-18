{ SCL Compiler - semantic analysis, memory layout and code generation for the Virtual PLC }
unit scl_compiler;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, contnrs, Math, scl_base, scl_types, scl_lexer, scl_ast, scl_parser,
  scl_project, scl_vmformat, scl_vmmem;

const
  RK_NONE = 0;
  RK_INST = 1;      // offset in the FB instance
  RK_FRAME = 2;     // offset in the L frame
  RK_ABS = 3;       // absolute address (tag, %I0.0)
  RK_CONST = 4;     // compile time constant
  RK_DB = 5;        // a whole data block
  RK_BLOCK = 6;     // FC / FB (callee only)
  RK_PATH = 7;      // member / index / slice path

  COMPILER_VERSION = '1.0.0';

type
  TBlockState = (bsNew, bsResolving, bsDone);

  TLocalSym = class
  public
    Name: string;
    Typ: TSclType;
    Where: Integer;        // RK_INST / RK_FRAME / RK_CONST
    Ofs: Int64;            // bit offset in instance / frame
    ByRef: Boolean;
    Section: TMemberSection;
    CVal: TConstValue;
    Member: TMember;
    DeclPos: TSrcPos;
  end;

  TBlockInfo = class
  public
    U: TProgUnit;
    Kind: TUnitKind;
    Name: string;
    Number: Integer;
    Optimized: Boolean;
    State: TBlockState;
    DataType: TSclType;     // UDT type / DB layout / FB instance layout
    ParamType: TSclType;    // FC: RET_VAL + parameters
    TempType: TSclType;     // temps (OB: start info inputs first)
    TempBase: Int64;        // bit offset of the temp area in the frame
    TempBits: Int64;        // size of temp area incl. compiler temps
    RetType: TSclType;
    Locals: TStringList;    // sorted, objects = TLocalSym (owned)
    DBInstOf: TBlockInfo;
    Image: TBytes;
    RetainMap: TBytes;
    CodeIndex: Integer;
    EventClass: Integer;
    Interval: Integer;
    Calls: TStringList;
    CodeSize: Integer;
    StringTemps: array of record Ofs: Int64; MaxLen: Integer; Wide: Boolean; end;
    constructor Create;
    destructor Destroy; override;
    function FindLocal(const N: string): TLocalSym;
    function KindText: string;
    function FullName: string;
    function SizeBytes: Int64;
  end;

  TTagInfo = class
  public
    Tag: TPlcTag;
    Name: string;
    Typ: TSclType;
    Addr: Int64;
    IsConst: Boolean;
    CVal: TConstValue;
  end;

  TValSrcKind = (vsExpr, vsAddrOfs);
  TValSrc = record
    Kind: TValSrcKind;
    E: TExpr;               // vsExpr
    Typ: TSclType;          // type of the source
    BaseE: TExpr;           // vsAddrOfs: instance expression (nil = pending frame)
    BaseAddr: Int64;        // vsAddrOfs with BaseE = nil and FromFrame = False
    FromFrame: Boolean;
    Ofs: Int64;
  end;

  TGetSourceEvent = function(const FileName: string; out Text: string): Boolean of object;

  TLoopCtx = record
    BreakL, ContL: Integer;
  end;

  TSclCompiler = class
  private
    FProject: TSclProject;
    FDiags: TDiagList;
    FUnits: TSourceUnitList;
    FBlocks: TObjectList;
    FByName: TStringList;
    FTags: TStringList;
    FCpu: TCpuFamily;
    FImage: TSvImage;
    FPool: TBytes;
    FPoolStrings: TStringList;
    FSources: TStringList;
    { code generation state }
    FCur: TBlockInfo;
    FCode: TCodeBuf;
    FSvb: TSvBlock;
    FLoops: array of TLoopCtx;
    FRetLabel: Integer;
    function GetBlock(I: Integer): TBlockInfo;
    function GetBlockCount: Integer;
    function GetTagInfo(I: Integer): TTagInfo;
    function GetTagCount: Integer;
    procedure Err(const P: TSrcPos; const Msg: string);
    procedure Warn(const P: TSrcPos; const Msg: string);
    { phases }
    procedure ParseSources;
    procedure RegisterBlocks;
    procedure AssignNumbers;
    procedure RegisterTags;
    procedure ResolveBlock(B: TBlockInfo);
    procedure BuildDBImage(B: TBlockInfo);
    procedure GenerateBlock(B: TBlockInfo);
    procedure BuildImage;
    { declarations }
    function FindBlock(const N: string): TBlockInfo;
    function FindTag(const N: string): TTagInfo;
    function ResolveSpec(Spec: TTypeSpec; Ctx: TBlockInfo; AllowFB: Boolean): TSclType;
    function ResolveNamedType(const AName: string; Quoted: Boolean; const P: TSrcPos; AllowFB: Boolean): TSclType;
    function BuildStruct(Decls: TObjectList; Ctx: TBlockInfo): TSclType;
    procedure SetMemberInit(M: TMember; D: TVarDecl; Ctx: TBlockInfo);
    function EvalConstInt(E: TExpr; Ctx: TBlockInfo; out V: Integer): Boolean;
    function EvalConstFor(E: TExpr; Ctx: TBlockInfo; T: TSclType; out C: TConstValue): Boolean;
    procedure AddLocal(B: TBlockInfo; M: TMember; Where: Integer; Ofs: Int64);
    procedure ApplyDefaults(var Img: TBytes; T: TSclType; Base: Int64);
    procedure WriteConst(var Img: TBytes; Ofs: Int64; T: TSclType; const C: TConstValue);
    function StaticPath(E: TExpr; Root: TSclType; out Ofs: Int64; out T: TSclType): Boolean;
    procedure MarkRetain(B: TBlockInfo; T: TSclType; Base: Int64; Mode: TRetainMode);
    function ParseAbsAddress(const S: string; out Addr: Int64; out T: TSclType; out Msg: string): Boolean;
    { types }
    function InferType(E: TExpr): TSclType;
    function InferName(E: TNameRef): TSclType;
    function InferBinary(E: TBinary): TSclType;
    function InferCall(C: TCall): TSclType;
    function InferBuiltin(C: TCall; const AName: string; out Handled: Boolean): TSclType;
    function CommonType(A, B: TSclType; const P: TSrcPos; const OpText: string): TSclType;
    function ImplicitOK(Src, Dst: TSclType; E: TExpr; out Msg: string): Boolean;
    function CheckAssign(Src, Dst: TSclType; E: TExpr; const P: TSrcPos): Boolean;
    function IsLValue(E: TExpr): Boolean;
    function ConstFits(const C: TConstValue; T: TSclType): Boolean;
    function FoldUnary(E: TUnary): Boolean;
    function FoldBinary(E: TBinary; OT: TSclType): Boolean;
    function CallBlock(C: TCall; out IsFB: Boolean; out Inst: TExpr; out SysT: TSclType; out SysName: string): TBlockInfo;
    function ArgFor(C: TCall; const PName: string; Index: Integer; Positional: Boolean): TCallArg;
    { emission }
    procedure EmitLine(const P: TSrcPos);
    procedure EmitAddr(E: TExpr);
    procedure EmitValue(E: TExpr; Want: TSclType);
    procedure EmitConst(const C: TConstValue; T, Want: TSclType);
    procedure EmitImplicit(From, ToT: TSclType);
    procedure EmitExplicit(From, ToT: TSclType);
    procedure EmitBinary(E: TBinary);
    procedure EmitStore(Target: TExpr; const Src: TValSrc);
    procedure EmitSrcValue(const Src: TValSrc; Want: TSclType);
    function EmitCall(C: TCall; WantResult: Boolean): TSclType;
    function EmitBuiltin(C: TCall; const AName: string; WantResult: Boolean): TSclType;
    procedure EmitStmts(L: TStmtList);
    procedure EmitStmt(S: TStmt);
    procedure EmitAssign(S: TAssign);
    procedure EmitIf(S: TIfStmt);
    procedure EmitCase(S: TCaseStmt);
    procedure EmitFor(S: TForStmt);
    function AllocTemp(T: TSclType): Int64;
    function AllocStringTemp(MaxLen: Integer; Wide: Boolean): Int64;
    function ConstStringAddr(const S: string; Wide: Boolean): Int64;
    procedure FlattenVars(T: TSclType; const Prefix: string; Base: Int64; Sec: Byte; Retain: Boolean;
      const Img: TBytes; var Arr: TSvVarArray; Depth: Integer);
  public
    constructor Create(AProject: TSclProject);
    destructor Destroy; override;
    procedure Reset;
    function Compile(DoCodeGen: Boolean = True): Boolean;
    function SaveImage(const FN: string): Boolean;
    function ListingText: string;
    function MemoryMapText: string;
    property Diags: TDiagList read FDiags;
    property Units: TSourceUnitList read FUnits;
    property Blocks[I: Integer]: TBlockInfo read GetBlock;
    property BlockCount: Integer read GetBlockCount;
    property TagInfos[I: Integer]: TTagInfo read GetTagInfo;
    property TagCount: Integer read GetTagCount;
    property Image: TSvImage read FImage;
    property Project: TSclProject read FProject;
    property Cpu: TCpuFamily read FCpu;
  public
    OnGetSource: TGetSourceEvent;
    function FindBlockInfo(const N: string): TBlockInfo;
    function FindTagInfo(const N: string): TTagInfo;
  end;

function VmTypeOf(T: TSclType): Byte;
function IsBuiltinName(const N: string): Boolean;
function ReadSourceFile(const FN: string): string;

implementation

function ReadSourceFile(const FN: string): string;
var
  L: TStringList;
begin
  L := TStringList.Create;
  try
    L.LoadFromFile(FN);
    Result := L.Text;
    if Copy(Result, 1, 3) = #$EF#$BB#$BF then Delete(Result, 1, 3);
  finally
    L.Free;
  end;
end;

function VmTypeOf(T: TSclType): Byte;
begin
  if (T <> nil) and IsElementaryKind(T.Kind) then Result := Ord(T.Kind)
  else Result := 0;
end;

function AlignUpI(V, A: Int64): Int64;
begin
  Result := ((V + A - 1) div A) * A;
end;

{ TBlockInfo }

constructor TBlockInfo.Create;
begin
  inherited;
  Locals := TStringList.Create;
  Locals.Sorted := True;
  Locals.CaseSensitive := False;
  Locals.Duplicates := dupError;
  Locals.OwnsObjects := True;
  Calls := TStringList.Create;
  Calls.Sorted := True;
  Calls.Duplicates := dupIgnore;
  CodeIndex := -1;
end;

destructor TBlockInfo.Destroy;
begin
  Locals.Free;
  Calls.Free;
  inherited;
end;

function TBlockInfo.FindLocal(const N: string): TLocalSym;
var
  I: Integer;
begin
  if Locals.Find(N, I) then Result := TLocalSym(Locals.Objects[I]) else Result := nil;
end;

function TBlockInfo.KindText: string;
begin
  Result := UnitKindNames[Kind];
end;

function TBlockInfo.FullName: string;
begin
  if Kind = ukUDT then Result := '"' + Name + '"'
  else Result := Format('%s%d "%s"', [KindText, Number, Name]);
end;

function TBlockInfo.SizeBytes: Int64;
begin
  if DataType <> nil then Result := (DataType.SizeBits + 7) div 8 else Result := 0;
end;

{ TSclCompiler }

constructor TSclCompiler.Create(AProject: TSclProject);
begin
  inherited Create;
  FProject := AProject;
  FDiags := TDiagList.Create(True);
  FUnits := TSourceUnitList.Create(True);
  FBlocks := TObjectList.Create(True);
  FByName := TStringList.Create;
  FByName.Sorted := True;
  FByName.CaseSensitive := False;
  FTags := TStringList.Create;
  FTags.Sorted := True;
  FTags.CaseSensitive := False;
  FTags.OwnsObjects := True;
  FPoolStrings := TStringList.Create;
  FPoolStrings.Sorted := True;
  FPoolStrings.CaseSensitive := True;
  FSources := TStringList.Create;
  FImage := TSvImage.Create;
end;

destructor TSclCompiler.Destroy;
begin
  Reset;
  FDiags.Free;
  FUnits.Free;
  FBlocks.Free;
  FByName.Free;
  FTags.Free;
  FPoolStrings.Free;
  FSources.Free;
  FImage.Free;
  inherited;
end;

procedure TSclCompiler.Reset;
begin
  FDiags.Clear;
  FBlocks.Clear;
  FByName.Clear;
  FTags.Clear;
  FUnits.Clear;
  FPoolStrings.Clear;
  FSources.Clear;
  SetLength(FPool, 0);
  FImage.Free;
  FImage := TSvImage.Create;
  ClearTypePool;
end;

function TSclCompiler.GetBlock(I: Integer): TBlockInfo;
begin
  Result := TBlockInfo(FBlocks[I]);
end;

function TSclCompiler.GetBlockCount: Integer;
begin
  Result := FBlocks.Count;
end;

function TSclCompiler.GetTagInfo(I: Integer): TTagInfo;
begin
  Result := TTagInfo(FTags.Objects[I]);
end;

function TSclCompiler.GetTagCount: Integer;
begin
  Result := FTags.Count;
end;

procedure TSclCompiler.Err(const P: TSrcPos; const Msg: string);
begin
  FDiags.Error(P, Msg);
end;

procedure TSclCompiler.Warn(const P: TSrcPos; const Msg: string);
begin
  FDiags.Warning(P, Msg);
end;

function TSclCompiler.FindBlock(const N: string): TBlockInfo;
var
  I: Integer;
begin
  if FByName.Find(N, I) then Result := TBlockInfo(FByName.Objects[I]) else Result := nil;
end;

function TSclCompiler.FindBlockInfo(const N: string): TBlockInfo;
begin
  Result := FindBlock(N);
end;

function TSclCompiler.FindTagInfo(const N: string): TTagInfo;
begin
  Result := FindTag(N);
end;

function TSclCompiler.FindTag(const N: string): TTagInfo;
var
  I: Integer;
begin
  if FTags.Find(N, I) then Result := TTagInfo(FTags.Objects[I]) else Result := nil;
end;

{ ====================================================================== phases }

procedure TSclCompiler.ParseSources;
var
  I: Integer;
  FN, Txt: string;
begin
  for I := 0 to FProject.Sources.Count - 1 do
  begin
    FN := FProject.AbsPath(FProject.Sources[I]);
    if not FileExists(FN) then
    begin
      Err(MakePos(FN, 0, 0, 0), 'Source file not found: ' + FN);
      Continue;
    end;
    FSources.Add(FN);
    if not (Assigned(OnGetSource) and OnGetSource(FN, Txt)) then Txt := ReadSourceFile(FN);
    ParseSclSource(Txt, FN, FUnits, FDiags);
  end;
end;

procedure TSclCompiler.RegisterBlocks;
var
  I: Integer;
  U: TProgUnit;
  B: TBlockInfo;
  Opt: string;
begin
  for I := 0 to FUnits.Count - 1 do
  begin
    U := FUnits.UnitAt(I);
    if FindBlock(U.Name) <> nil then
    begin
      Err(U.Pos, Format('Duplicate block name "%s"', [U.Name]));
      Continue;
    end;
    if FindElementaryType(U.Name) <> nil then
      Err(U.Pos, Format('Block name "%s" collides with a data type', [U.Name]));
    B := TBlockInfo.Create;
    B.U := U;
    B.Kind := U.Kind;
    B.Name := U.Name;
    Opt := UpperCase(U.AttrValue('S7_Optimized_Access'));
    if FCpu in [cpuS7_300, cpuS7_400] then
    begin
      if Opt = 'TRUE' then Warn(U.Pos, 'Optimized block access is not available on ' + CpuNames[FCpu] + ' (ignored)');
      B.Optimized := False;
    end
    else
      B.Optimized := Opt <> 'FALSE';
    FBlocks.Add(B);
    FByName.AddObject(U.Name, B);
  end;
end;

function NumberFromName(const N: string; const Prefix: string): Integer;
var
  U: string;
begin
  U := UpperCase(N);
  Result := 0;
  if (Copy(U, 1, Length(Prefix)) = Prefix) and (Length(U) > Length(Prefix)) then
    Result := StrToIntDef(Copy(U, Length(Prefix) + 1, MaxInt), 0);
end;

function OBEventClass(N: Integer): Integer;
begin
  case N of
    1, 123..32767: Result := 1;
    10..17: Result := 10;
    20..23: Result := 20;
    30..38: Result := 30;
    40..47: Result := 40;
    55..57: Result := 55;
    61..65: Result := 61;
    80..88: Result := N;
    100..102: Result := 100;
    121, 122: Result := N;
  else
    Result := 0;
  end;
end;

procedure TSclCompiler.AssignNumbers;
var
  I, N, K: Integer;
  B: TBlockInfo;
  Used: array[TUnitKind] of TList;
  UK: TUnitKind;
  Pfx: string;

  function IsUsed(AK: TUnitKind; ANum: Integer): Boolean;
  begin
    Result := Used[AK].IndexOf(Pointer(PtrInt(ANum))) >= 0;
  end;

begin
  for UK := Low(TUnitKind) to High(TUnitKind) do Used[UK] := TList.Create;
  try
    { explicit numbers }
    for I := 0 to FBlocks.Count - 1 do
    begin
      B := GetBlock(I);
      case B.Kind of
        ukUDT: Pfx := 'UDT';
        ukDB: Pfx := 'DB';
        ukFC: Pfx := 'FC';
        ukFB: Pfx := 'FB';
      else
        Pfx := 'OB';
      end;
      N := FProject.BlockNumber(B.Name);
      if N = 0 then N := NumberFromName(B.Name, Pfx);
      if (N = 0) and (B.Kind = ukOB) then
      begin
        if SameText(B.Name, 'Main') or SameText(B.Name, 'Main_Program_Sweep') then N := 1
        else if SameText(B.Name, 'Startup') or SameText(B.Name, 'Complete_restart') then N := 100
        else if SameText(B.Name, 'Cyclic interrupt') or SameText(B.Name, 'Cyclic_interrupt') then N := 30
        else if SameText(B.Name, 'Time error interrupt') then N := 80
        else if SameText(B.Name, 'Diagnostic error interrupt') then N := 82
        else if SameText(B.Name, 'Programming error') then N := 121;
      end;
      if N > 0 then
      begin
        if IsUsed(B.Kind, N) then
          Err(B.U.Pos, Format('Block number %s%d is used twice', [B.KindText, N]))
        else
          Used[B.Kind].Add(Pointer(PtrInt(N)));
        B.Number := N;
      end;
    end;
    { automatic numbers }
    for I := 0 to FBlocks.Count - 1 do
    begin
      B := GetBlock(I);
      if B.Number > 0 then Continue;
      if B.Kind = ukOB then
      begin
        if FCpu in [cpuS7_300, cpuS7_400] then
        begin
          Err(B.U.Pos, Format('OB "%s": set the OB number in the project (BlockNumbers)', [B.Name]));
          K := 1;
        end
        else
          K := 123;
      end
      else
        K := 1;
      while IsUsed(B.Kind, K) do Inc(K);
      B.Number := K;
      Used[B.Kind].Add(Pointer(PtrInt(K)));
    end;
    { OB event classes }
    for I := 0 to FBlocks.Count - 1 do
    begin
      B := GetBlock(I);
      if B.Kind <> ukOB then Continue;
      B.EventClass := OBEventClass(B.Number);
      if B.EventClass = 0 then
        Err(B.U.Pos, Format('OB%d is not a supported organization block number', [B.Number]));
      if B.EventClass = 30 then
      begin
        B.Interval := StrToIntDef(FProject.CyclicIntervals.Values[B.Name], 0);
        if B.Interval <= 0 then
          case B.Number of
            30: B.Interval := 5000; 31: B.Interval := 2000; 32: B.Interval := 1000;
            33: B.Interval := 500; 34: B.Interval := 200; 35: B.Interval := 100;
            36: B.Interval := 50; 37: B.Interval := 20; 38: B.Interval := 10;
          end;
      end;
      if (FCpu = cpuS7_300) and (B.Number > 122) then
        Err(B.U.Pos, Format('OB%d does not exist on S7-300', [B.Number]));
    end;
  finally
    for UK := Low(TUnitKind) to High(TUnitKind) do Used[UK].Free;
  end;
end;

function TSclCompiler.ParseAbsAddress(const S: string; out Addr: Int64; out T: TSclType; out Msg: string): Boolean;
var
  U, Rest, DBPart: string;
  Area, DBN, P, ByteN, BitN: Integer;
  Size: Char;

  function TakeNum(var X: string; out V: Integer): Boolean;
  var
    J: Integer;
  begin
    J := 1;
    while (J <= Length(X)) and (X[J] in ['0'..'9']) do Inc(J);
    Result := J > 1;
    if Result then V := StrToInt(Copy(X, 1, J - 1)) else V := 0;
    Delete(X, 1, J - 1);
  end;

begin
  Result := False;
  Msg := '';
  Addr := 0;
  T := nil;
  U := UpperCase(Trim(S));
  if (U <> '') and (U[1] = '%') then Delete(U, 1, 1);
  if Copy(U, Length(U) - 1, 2) = ':P' then
  begin
    Delete(U, Length(U) - 1, 2);
    if U[1] = 'I' then U := 'P' + U else U := 'R' + U; { internal marker }
  end;
  DBN := 0;
  if Copy(U, 1, 2) = 'DB' then
  begin
    Rest := Copy(U, 3, MaxInt);
    if not TakeNum(Rest, DBN) then begin Msg := 'DB number expected'; Exit; end;
    if Copy(Rest, 1, 3) <> '.DB' then begin Msg := '.DBX/.DBB/.DBW/.DBD expected'; Exit; end;
    Delete(Rest, 1, 3);
    Area := AREA_DB;
  end
  else
  begin
    case U[1] of
      'I', 'E': Area := AREA_I;
      'Q', 'A': Area := AREA_Q;
      'M': Area := AREA_M;
      'P': begin Area := AREA_PI; Delete(U, 1, 1); end;
      'R': begin Area := AREA_PQ; Delete(U, 1, 1); end;
    else
      Msg := 'Unknown memory area';
      Exit;
    end;
    Rest := Copy(U, 2, MaxInt);
  end;
  Size := 'X';
  if (Rest <> '') and (Rest[1] in ['X', 'B', 'W', 'D', 'L']) then
  begin
    Size := Rest[1];
    Delete(Rest, 1, 1);
  end;
  if not TakeNum(Rest, ByteN) then begin Msg := 'Byte number expected'; Exit; end;
  BitN := 0;
  if Size = 'X' then
  begin
    if (Rest = '') or (Rest[1] <> '.') then begin Msg := 'Bit number expected (e.g. 0.0)'; Exit; end;
    Delete(Rest, 1, 1);
    if not TakeNum(Rest, BitN) or (BitN > 7) then begin Msg := 'Bit number 0..7 expected'; Exit; end;
  end;
  if Rest <> '' then begin Msg := 'Invalid address'; Exit; end;
  case Size of
    'X': T := ElemType(tkBool);
    'B': T := ElemType(tkByte);
    'W': T := ElemType(tkWord);
    'D': T := ElemType(tkDWord);
    'L': T := ElemType(tkLWord);
  end;
  Addr := MakeAddr(Area, DBN, Int64(ByteN) * 8 + BitN);
  Result := True;
  if DBPart = '' then;
  P := 0;
  if P = 0 then;
end;

procedure TSclCompiler.RegisterTags;
var
  I: Integer;
  PT: TPlcTag;
  TI: TTagInfo;
  T, AT: TSclType;
  A: Int64;
  Msg: string;
  P: TSrcPos;
  E: TExpr;
  D: TDiagList;
begin
  for I := 0 to FProject.Tags.Count - 1 do
  begin
    PT := FProject.Tag(I);
    P := MakePos('PLC tags: ' + PT.TableName, I + 2, 1, 0);
    if FindTag(PT.Name) <> nil then
    begin
      Err(P, Format('Duplicate tag "%s"', [PT.Name]));
      Continue;
    end;
    TI := TTagInfo.Create;
    TI.Tag := PT;
    TI.Name := PT.Name;
    FTags.AddObject(PT.Name, TI);
    T := FindElementaryType(PT.DataType);
    if (T = nil) and SameText(PT.DataType, 'String') then T := ElemType(tkString);
    if T = nil then
    begin
      Err(P, Format('Tag "%s": unsupported data type "%s"', [PT.Name, PT.DataType]));
      T := ElemType(tkBool);
    end
    else if not TypeSupportedOn(T.Kind, FCpu) then
      Err(P, Format('Tag "%s": data type %s is not available on %s', [PT.Name, PT.DataType, CpuNames[FCpu]]));
    TI.Typ := T;
    if PT.IsConstant then
    begin
      TI.IsConst := True;
      D := TDiagList.Create(True);
      try
        E := ParseSclExpression(PT.Value, D);
        if (E <> nil) and (D.ErrorCount = 0) then
        begin
          FCur := nil;
          if not EvalConstFor(E, nil, T, TI.CVal) then
            Err(P, Format('Constant "%s": value "%s" is not a valid %s constant', [PT.Name, PT.Value, PT.DataType]));
        end
        else
          Err(P, Format('Constant "%s": invalid value "%s"', [PT.Name, PT.Value]));
        E.Free;
      finally
        D.Free;
      end;
      Continue;
    end;
    if not ParseAbsAddress(PT.Address, A, AT, Msg) then
    begin
      Err(P, Format('Tag "%s": invalid address "%s" (%s)', [PT.Name, PT.Address, Msg]));
      Continue;
    end;
    if AddrArea(A) = AREA_DB then
      Err(P, Format('Tag "%s": DB addresses are not allowed in the tag table', [PT.Name]));
    if (AT.SizeBits <> T.SizeBits) and not ((T.Kind = tkBool) and (AT.Kind = tkBool)) then
      Err(P, Format('Tag "%s": address %s (%d bit) does not match data type %s (%d bit)',
        [PT.Name, PT.Address, AT.SizeBits, PT.DataType, T.SizeBits]));
    TI.Addr := A;
  end;
end;

{ ====================================================================== declarations }

function TSclCompiler.EvalConstInt(E: TExpr; Ctx: TBlockInfo; out V: Integer): Boolean;
var
  C: TConstValue;
begin
  V := 0;
  Result := EvalConstFor(E, Ctx, ElemType(tkDInt), C);
  if Result then V := C.I;
end;

function TSclCompiler.EvalConstFor(E: TExpr; Ctx: TBlockInfo; T: TSclType; out C: TConstValue): Boolean;
var
  Old: TBlockInfo;
  ET: TSclType;
  Msg: string;
begin
  Result := False;
  C.Kind := ckNone;
  if E = nil then Exit;
  Old := FCur;
  FCur := Ctx;
  try
    ET := InferType(E);
  finally
    FCur := Old;
  end;
  if ET = nil then Exit;
  if not E.IsConst then
  begin
    Err(E.Pos, 'Constant expression expected');
    Exit;
  end;
  if T <> nil then
  begin
    if not ImplicitOK(ET, T, E, Msg) then
    begin
      Err(E.Pos, Msg);
      Exit;
    end;
    C := E.CVal;
    if IsRealKind(T.Kind) and (C.Kind = ckInt) then C := CReal(C.I);
    if (T.Kind = tkBool) then C := CBool(C.I <> 0);
    if (T.Kind = tkChar) and (C.Kind = ckString) then
    begin
      if C.S <> '' then C := CInt(Ord(C.S[1])) else C := CInt(0);
    end;
  end
  else
    C := E.CVal;
  Result := True;
end;

function TSclCompiler.ResolveNamedType(const AName: string; Quoted: Boolean; const P: TSrcPos;
  AllowFB: Boolean): TSclType;
var
  B: TBlockInfo;
  Msg: string;
begin
  Result := nil;
  if not Quoted then
  begin
    Result := FindElementaryType(AName);
    if Result <> nil then
    begin
      if Result.Kind = tkVoid then
      begin
        Err(P, 'Void is only allowed as function return type');
        Exit(nil);
      end;
      if not TypeSupportedOn(Result.Kind, FCpu) then
        Err(P, Format('Data type %s is not available on %s', [AName, CpuNames[FCpu]]));
      Exit;
    end;
    if SameText(AName, 'DTL') then
    begin
      if FCpu in [cpuS7_300, cpuS7_400] then Err(P, 'DTL is not available on ' + CpuNames[FCpu]);
      Exit(DTLType);
    end;
    if IsSysFBName(AName) then
    begin
      Result := MakeSysFBType(AName, FCpu, Msg);
      if Result = nil then Err(P, Msg)
      else if not AllowFB then
      begin
        Err(P, Format('%s instances are only allowed as static variables (or InOut)', [AName]));
      end;
      Exit;
    end;
    if SameText(AName, 'Pointer') or SameText(AName, 'Any') or SameText(AName, 'Variant') or
       SameText(AName, 'Block_DB') or SameText(AName, 'DB_ANY') then
    begin
      Err(P, Format('Data type %s is not supported by this compiler', [AName]));
      Exit;
    end;
  end;
  B := FindBlock(AName);
  if B = nil then
  begin
    Err(P, Format('Unknown data type "%s"', [AName]));
    Exit;
  end;
  case B.Kind of
    ukUDT:
      begin
        ResolveBlock(B);
        Result := B.DataType;
      end;
    ukFB:
      begin
        if not AllowFB then
        begin
          Err(P, Format('FB "%s" can only be used as a static variable (multi-instance)', [AName]));
          Exit;
        end;
        if (FCur <> nil) and (FCur = B) then
        begin
          Err(P, 'An FB cannot contain an instance of itself');
          Exit;
        end;
        ResolveBlock(B);
        Result := B.DataType;
      end;
  else
    Err(P, Format('"%s" is a %s, not a data type', [AName, B.KindText]));
  end;
  if (Result = nil) and (B.State = bsResolving) then
    Err(P, Format('Recursive data type reference "%s"', [AName]));
end;

function TSclCompiler.ResolveSpec(Spec: TTypeSpec; Ctx: TBlockInfo; AllowFB: Boolean): TSclType;
var
  I, Lo, Hi, L: Integer;
  D: TArrayDim;
  El: TSclType;
begin
  Result := nil;
  if Spec = nil then Exit;
  if Spec.Resolved <> nil then Exit(Spec.Resolved);
  case Spec.Kind of
    tsNamed:
      Result := ResolveNamedType(Spec.Name, Spec.Quoted, Spec.Pos, AllowFB);
    tsString:
      begin
        L := 254;
        if Spec.StrLen <> nil then
          if not EvalConstInt(Spec.StrLen, Ctx, L) then L := 254;
        if Spec.Wide then
        begin
          if FCpu in [cpuS7_300, cpuS7_400] then Err(Spec.Pos, 'WString is not available on ' + CpuNames[FCpu]);
          if (L < 0) or (L > 16382) then begin Err(Spec.Pos, 'WString length must be 0..16382'); L := 254; end;
        end
        else if (L < 0) or (L > 254) then
        begin
          Err(Spec.Pos, 'String length must be 0..254');
          L := 254;
        end;
        Result := NewStringType(L, Spec.Wide);
      end;
    tsArray:
      begin
        El := ResolveSpec(Spec.Elem, Ctx, AllowFB);
        if El = nil then Exit;
        for I := Spec.Dims.Count - 1 downto 0 do
        begin
          D := TArrayDim(Spec.Dims[I]);
          if D.Star then
          begin
            Err(Spec.Pos, 'Array[*] is not supported');
            Exit(nil);
          end;
          if not EvalConstInt(D.Lo, Ctx, Lo) or not EvalConstInt(D.Hi, Ctx, Hi) then Exit(nil);
          if Hi < Lo then
          begin
            Err(Spec.Pos, Format('Array bounds %d..%d are invalid', [Lo, Hi]));
            Exit(nil);
          end;
          if (FCpu in [cpuS7_300, cpuS7_400, cpuS7_1200]) and ((Lo < -32768) or (Hi > 32767)) then
            Err(Spec.Pos, 'Array limits must be within -32768..32767 on ' + CpuNames[FCpu]);
          El := NewArrayType(El, Lo, Hi);
        end;
        Result := El;
      end;
    tsStruct:
      Result := BuildStruct(Spec.Members, Ctx);
  end;
  Spec.Resolved := Result;
end;

procedure TSclCompiler.SetMemberInit(M: TMember; D: TVarDecl; Ctx: TBlockInfo);
var
  AI: TArrayInit;
  I, J, N, K, Total: Integer;
  C: TConstValue;
  ET: TSclType;
begin
  if D.Init = nil then Exit;
  if D.Init is TArrayInit then
  begin
    AI := TArrayInit(D.Init);
    if M.Typ.Kind <> tkArray then
    begin
      Err(D.Init.Pos, 'Array initializer for a non-array variable');
      Exit;
    end;
    ET := M.Typ;
    Total := 1;
    while ET.Kind = tkArray do
    begin
      Total := Total * ET.ElemCount;
      ET := ET.ElemType;
    end;
    if not IsElementaryKind(ET.Kind) and not IsStringKind(ET.Kind) then
    begin
      Err(D.Init.Pos, 'Array initializer only supported for arrays of elementary types');
      Exit;
    end;
    SetLength(M.InitList, 0);
    for I := 0 to AI.Items.Count - 1 do
    begin
      if not EvalConstFor(TExpr(AI.Items[I]), Ctx, ET, C) then Continue;
      N := AI.Repeats[I];
      for J := 1 to N do
      begin
        K := Length(M.InitList);
        SetLength(M.InitList, K + 1);
        M.InitList[K] := C;
      end;
    end;
    if Length(M.InitList) > Total then
      Err(D.Init.Pos, Format('Too many initial values (%d) for %d elements', [Length(M.InitList), Total]));
    Exit;
  end;
  if not (IsElementaryKind(M.Typ.Kind) or IsStringKind(M.Typ.Kind)) then
  begin
    Err(D.Init.Pos, 'Initial value not allowed for ' + TypeName(M.Typ));
    Exit;
  end;
  if EvalConstFor(D.Init, Ctx, M.Typ, C) then
  begin
    M.HasInit := True;
    M.Init := C;
  end;
end;

function TSclCompiler.BuildStruct(Decls: TObjectList; Ctx: TBlockInfo): TSclType;
var
  I: Integer;
  D: TVarDecl;
  T: TSclType;
  M: TMember;
begin
  Result := NewType(tkStruct);
  for I := 0 to Decls.Count - 1 do
  begin
    D := TVarDecl(Decls[I]);
    if Result.FindMember(D.Name) <> nil then
    begin
      Err(D.Pos, Format('Duplicate member "%s"', [D.Name]));
      Continue;
    end;
    T := ResolveSpec(D.Spec, Ctx, False);
    if T = nil then T := ElemType(tkBool);
    M := Result.AddMember(D.Name, T, msStatic);
    M.Comment := D.Comment;
    M.DeclPos := D.Pos;
    SetMemberInit(M, D, Ctx);
  end;
  LayoutStruct(Result);
end;

procedure TSclCompiler.AddLocal(B: TBlockInfo; M: TMember; Where: Integer; Ofs: Int64);
var
  L: TLocalSym;
begin
  if B.FindLocal(M.Name) <> nil then
  begin
    Err(M.DeclPos, Format('Duplicate declaration of "%s"', [M.Name]));
    Exit;
  end;
  L := TLocalSym.Create;
  L.Name := M.Name;
  L.Typ := M.Typ;
  L.Where := Where;
  L.Ofs := Ofs;
  L.ByRef := M.ByRef;
  L.Section := M.Section;
  L.Member := M;
  L.DeclPos := M.DeclPos;
  B.Locals.AddObject(M.Name, L);
end;

procedure TSclCompiler.ResolveBlock(B: TBlockInfo);
const
  Order: array[0..3] of TMemberSection = (msInput, msOutput, msInOut, msStatic);
var
  U: TProgUnit;
  I, J, K: Integer;
  S: TVarSection;
  D: TVarDecl;
  T: TSclType;
  M: TMember;
  L: TLocalSym;
  OldCur: TBlockInfo;
  Ret: TSclType;
  C: TConstValue;
  TB, Ti: TBlockInfo;
  Msg: string;

  function IsAggregateParam(AT: TSclType): Boolean;
  begin
    Result := AT.Kind in [tkArray, tkStruct, tkString, tkWString, tkFBInst, tkSysFB];
  end;

begin
  if B.State = bsDone then Exit;
  if B.State = bsResolving then Exit;
  B.State := bsResolving;
  U := B.U;
  OldCur := FCur;
  FCur := B;
  try
    { constants first: they may be used in array bounds }
    for I := 0 to U.Sections.Count - 1 do
    begin
      S := TVarSection(U.Sections[I]);
      if S.Kind <> msConstant then Continue;
      for J := 0 to S.Vars.Count - 1 do
      begin
        D := TVarDecl(S.Vars[J]);
        T := ResolveSpec(D.Spec, B, False);
        if T = nil then Continue;
        if B.FindLocal(D.Name) <> nil then
        begin
          Err(D.Pos, Format('Duplicate declaration of "%s"', [D.Name]));
          Continue;
        end;
        L := TLocalSym.Create;
        L.Name := D.Name;
        L.Typ := T;
        L.Where := RK_CONST;
        L.Section := msConstant;
        L.DeclPos := D.Pos;
        if D.Init = nil then Err(D.Pos, Format('Constant "%s" needs a value', [D.Name]))
        else if EvalConstFor(D.Init, B, T, C) then L.CVal := C;
        B.Locals.AddObject(D.Name, L);
      end;
    end;

    case B.Kind of
      ukUDT:
        begin
          B.DataType := ResolveSpec(U.StructSpec, B, False);
          if B.DataType = nil then B.DataType := NewType(tkStruct);
          B.DataType.Name := B.Name;
          B.DataType.IsUDT := True;
        end;

      ukDB:
        begin
          if U.DBTypeName <> '' then
          begin
            TB := FindBlock(U.DBTypeName);
            if (TB <> nil) and (TB.Kind = ukFB) then
            begin
              ResolveBlock(TB);
              B.DBInstOf := TB;
              B.DataType := TB.DataType;
            end
            else if (TB <> nil) and (TB.Kind = ukUDT) then
            begin
              ResolveBlock(TB);
              B.DataType := TB.DataType;
            end
            else if (TB = nil) and IsSysFBName(U.DBTypeName) then
            begin
              B.DataType := MakeSysFBType(U.DBTypeName, FCpu, Msg);
              if B.DataType = nil then Err(U.Pos, Msg);
            end
            else
              Err(U.Pos, Format('Unknown instance / data type "%s" for DB "%s"', [U.DBTypeName, B.Name]));
          end
          else if U.StructSpec <> nil then
            B.DataType := ResolveSpec(U.StructSpec, B, False)
          else
          begin
            T := NewType(tkStruct);
            for I := 0 to U.Sections.Count - 1 do
            begin
              S := TVarSection(U.Sections[I]);
              if S.Kind = msConstant then Continue;
              if S.Kind <> msStatic then
                Err(S.Pos, 'Only VAR sections are allowed in a global DB');
              for J := 0 to S.Vars.Count - 1 do
              begin
                D := TVarDecl(S.Vars[J]);
                if T.FindMember(D.Name) <> nil then
                begin
                  Err(D.Pos, Format('Duplicate member "%s"', [D.Name]));
                  Continue;
                end;
                M := T.AddMember(D.Name, ResolveSpec(D.Spec, B, True), msStatic);
                if M.Typ = nil then M.Typ := ElemType(tkBool);
                M.Comment := D.Comment;
                M.DeclPos := D.Pos;
                M.Retain := S.Retain;
                SetMemberInit(M, D, B);
              end;
            end;
            LayoutStruct(T);
            B.DataType := T;
          end;
          if B.DataType = nil then B.DataType := NewType(tkStruct);
          if (not B.Optimized) and (B.DataType.SizeBits > 65534 * 8) then
            Err(U.Pos, Format('DB "%s" is %d bytes; standard access DBs are limited to 65534 bytes',
              [B.Name, B.SizeBytes]));
        end;

      ukFC, ukFB, ukOB:
        begin
          Ret := nil;
          if B.Kind = ukFC then
          begin
            if U.RetSpec = nil then
              Ret := ElemType(tkVoid)
            else if (U.RetSpec.Kind = tsNamed) and SameText(U.RetSpec.Name, 'Void') and not U.RetSpec.Quoted then
              Ret := ElemType(tkVoid)
            else
              Ret := ResolveSpec(U.RetSpec, B, False);
            if Ret = nil then Ret := ElemType(tkVoid);
            if (Ret.Kind <> tkVoid) and not IsElementaryKind(Ret.Kind) then
            begin
              Err(U.RetSpec.Pos, 'Only Void and elementary return types are supported');
              Ret := ElemType(tkVoid);
            end;
          end;
          B.RetType := Ret;

          { interface struct: FB instance (Input, Output, InOut, Static) / FC parameters }
          if B.Kind = ukFB then
          begin
            T := NewType(tkFBInst);
            T.Name := B.Name;
            T.Block := B;
          end
          else
            T := NewType(tkStruct);
          if (B.Kind = ukFC) and (Ret.Kind <> tkVoid) then
          begin
            M := T.AddMember('RET_VAL', Ret, msReturn);
            M.DeclPos := U.Pos;
          end;
          for K := 0 to High(Order) do
            for I := 0 to U.Sections.Count - 1 do
            begin
              S := TVarSection(U.Sections[I]);
              if S.Kind <> Order[K] then Continue;
              if (B.Kind = ukFC) and (S.Kind = msStatic) then
              begin
                Err(S.Pos, 'An FC has no static variables (VAR); use VAR_TEMP');
                Continue;
              end;
              if (B.Kind = ukOB) and (S.Kind in [msOutput, msInOut, msStatic]) then
              begin
                Err(S.Pos, 'An OB can only declare VAR_INPUT (start information) and VAR_TEMP');
                Continue;
              end;
              if (B.Kind = ukOB) and (S.Kind = msInput) then Continue; { placed with temps }
              for J := 0 to S.Vars.Count - 1 do
              begin
                D := TVarDecl(S.Vars[J]);
                M := T.AddMember(D.Name, ResolveSpec(D.Spec, B, (S.Kind = msStatic) or (S.Kind = msInOut)), S.Kind);
                if M.Typ = nil then M.Typ := ElemType(tkBool);
                M.Comment := D.Comment;
                M.DeclPos := D.Pos;
                M.Retain := S.Retain;
                if S.Kind = msInOut then M.ByRef := True
                else if (B.Kind = ukFC) and IsAggregateParam(M.Typ) then M.ByRef := True;
                if (M.Typ.Kind in [tkFBInst, tkSysFB]) and (S.Kind <> msStatic) and not M.ByRef then
                  Err(D.Pos, 'Instances can only be declared in VAR (static) or VAR_IN_OUT');
                if S.Kind in [msInput, msStatic, msOutput] then SetMemberInit(M, D, B)
                else if D.Init <> nil then Err(D.Init.Pos, 'Initial value not allowed for InOut parameters');
              end;
            end;
          LayoutStruct(T);

          { temps (OB start info first) }
          B.TempType := NewType(tkStruct);
          for K := 0 to 1 do
            for I := 0 to U.Sections.Count - 1 do
            begin
              S := TVarSection(U.Sections[I]);
              if not (((K = 0) and (B.Kind = ukOB) and (S.Kind = msInput)) or ((K = 1) and (S.Kind = msTemp))) then
                Continue;
              for J := 0 to S.Vars.Count - 1 do
              begin
                D := TVarDecl(S.Vars[J]);
                M := B.TempType.AddMember(D.Name, ResolveSpec(D.Spec, B, False), S.Kind);
                if M.Typ = nil then M.Typ := ElemType(tkBool);
                M.Comment := D.Comment;
                M.DeclPos := D.Pos;
                if D.Init <> nil then Warn(D.Init.Pos, 'Initial values of temporary variables are ignored');
                if M.Typ.Kind in [tkFBInst, tkSysFB] then
                  Err(D.Pos, 'Instances cannot be declared as temporary variables');
              end;
            end;
          LayoutStruct(B.TempType);

          if B.Kind = ukFB then
          begin
            B.DataType := T;
            B.TempBase := 0;
            for I := 0 to T.MemberCount - 1 do
              AddLocal(B, T.Member(I), RK_INST, T.Member(I).OffsetBits);
          end
          else
          begin
            B.ParamType := T;
            if B.Kind = ukFC then
              B.TempBase := AlignUpI(T.SizeBits, 16)
            else
              B.TempBase := 0;
            for I := 0 to T.MemberCount - 1 do
              AddLocal(B, T.Member(I), RK_FRAME, T.Member(I).OffsetBits);
          end;
          B.TempBits := B.TempType.SizeBits;
          for I := 0 to B.TempType.MemberCount - 1 do
          begin
            M := B.TempType.Member(I);
            AddLocal(B, M, RK_FRAME, B.TempBase + M.OffsetBits);
            if IsStringKind(M.Typ.Kind) then
            begin
              K := Length(B.StringTemps);
              SetLength(B.StringTemps, K + 1);
              B.StringTemps[K].Ofs := B.TempBase + M.OffsetBits;
              B.StringTemps[K].MaxLen := M.Typ.MaxLen;
              B.StringTemps[K].Wide := M.Typ.Kind = tkWString;
            end;
          end;
          { the FC name itself addresses RET_VAL }
          if (B.Kind = ukFC) and (Ret.Kind <> tkVoid) and (B.FindLocal(B.Name) = nil) then
          begin
            L := TLocalSym.Create;
            L.Name := B.Name;
            L.Typ := Ret;
            L.Where := RK_FRAME;
            L.Ofs := 0;
            L.Section := msReturn;
            L.Member := T.FindMember('RET_VAL');
            L.DeclPos := U.Pos;
            B.Locals.AddObject(B.Name, L);
          end;
        end;
    end;
  finally
    FCur := OldCur;
    B.State := bsDone;
  end;
  if Ti = nil then;
end;

procedure TSclCompiler.WriteConst(var Img: TBytes; Ofs: Int64; T: TSclType; const C: TConstValue);
var
  V: TVmValue;
begin
  if C.Kind = ckNone then Exit;
  if IsStringKind(T.Kind) then
  begin
    MemWriteString(Img, Ofs, T.MaxLen, C.S, T.Kind = tkWString);
    Exit;
  end;
  if not IsElementaryKind(T.Kind) then Exit;
  if IsRealKind(T.Kind) then
  begin
    if C.Kind = ckReal then V.F := C.F else V.F := C.I;
  end
  else
    V.I := C.I;
  MemWriteBits(Img, Ofs, VmTypeOf(T), V);
end;

procedure TSclCompiler.ApplyDefaults(var Img: TBytes; T: TSclType; Base: Int64);
var
  I, K, N: Integer;
  M: TMember;
  ET: TSclType;
  Stride: Int64;

  procedure FillArray(AT: TSclType; ABase: Int64; const List: TConstArray; var Idx: Integer);
  var
    J: Integer;
    St: Int64;
  begin
    St := AT.ElemStrideBits;
    for J := 0 to AT.ElemCount - 1 do
    begin
      if AT.ElemType.Kind = tkArray then
        FillArray(AT.ElemType, ABase + J * St, List, Idx)
      else
      begin
        if Idx <= High(List) then
          WriteConst(Img, ABase + J * St, AT.ElemType, List[Idx]);
        Inc(Idx);
      end;
    end;
  end;

begin
  case T.Kind of
    tkString, tkWString:
      MemWriteString(Img, Base, T.MaxLen, '', T.Kind = tkWString);
    tkArray:
      begin
        ET := T.ElemType;
        if IsAggregate(ET) then
        begin
          Stride := T.ElemStrideBits;
          N := T.ElemCount;
          for K := 0 to N - 1 do
            ApplyDefaults(Img, ET, Base + K * Stride);
        end;
      end;
    tkStruct, tkFBInst, tkSysFB:
      for I := 0 to T.MemberCount - 1 do
      begin
        M := T.Member(I);
        if M.ByRef then Continue;
        if IsAggregate(M.Typ) then ApplyDefaults(Img, M.Typ, Base + M.OffsetBits);
        if M.HasInit then WriteConst(Img, Base + M.OffsetBits, M.Typ, M.Init);
        if Length(M.InitList) > 0 then
        begin
          K := 0;
          FillArray(M.Typ, Base + M.OffsetBits, M.InitList, K);
        end;
      end;
  end;
end;

procedure TSclCompiler.MarkRetain(B: TBlockInfo; T: TSclType; Base: Int64; Mode: TRetainMode);
var
  I: Integer;
  M: TMember;
  Md: TRetainMode;
  J, B0, B1: Int64;
begin
  if T = nil then Exit;
  if T.Kind in [tkStruct, tkFBInst] then
    for I := 0 to T.MemberCount - 1 do
    begin
      M := T.Member(I);
      Md := Mode;
      if M.Retain <> rmDefault then Md := M.Retain;
      if M.Typ.Kind in [tkStruct, tkFBInst] then
        MarkRetain(B, M.Typ, Base + M.OffsetBits, Md)
      else if Md = rmRetain then
      begin
        B0 := (Base + M.OffsetBits) div 8;
        B1 := (Base + M.OffsetBits + M.StorageBits - 1) div 8;
        for J := B0 to B1 do
          if J div 8 < Length(B.RetainMap) then
            B.RetainMap[J div 8] := B.RetainMap[J div 8] or (1 shl (J mod 8));
      end;
    end;
end;

function TSclCompiler.StaticPath(E: TExpr; Root: TSclType; out Ofs: Int64; out T: TSclType): Boolean;
var
  M: TMember;
  BO: Int64;
  BT: TSclType;
  I, V: Integer;
  X: TIndexRef;
begin
  Result := False;
  Ofs := 0;
  T := nil;
  if E is TNameRef then
  begin
    M := Root.FindMember(TNameRef(E).Name);
    if M = nil then
    begin
      Err(E.Pos, Format('Unknown member "%s"', [TNameRef(E).Name]));
      Exit;
    end;
    Ofs := M.OffsetBits;
    T := M.Typ;
    Exit(True);
  end;
  if E is TMemberRef then
  begin
    if not StaticPath(TMemberRef(E).Base, Root, BO, BT) then Exit;
    if not (BT.Kind in [tkStruct, tkFBInst, tkSysFB]) then
    begin
      Err(E.Pos, 'Structure expected before ''.''');
      Exit;
    end;
    M := BT.FindMember(TMemberRef(E).Member);
    if M = nil then
    begin
      Err(E.Pos, Format('Unknown member "%s"', [TMemberRef(E).Member]));
      Exit;
    end;
    Ofs := BO + M.OffsetBits;
    T := M.Typ;
    Exit(True);
  end;
  if E is TIndexRef then
  begin
    X := TIndexRef(E);
    if not StaticPath(X.Base, Root, BO, BT) then Exit;
    for I := 0 to X.Indices.Count - 1 do
    begin
      if BT.Kind <> tkArray then
      begin
        Err(E.Pos, 'Too many indices');
        Exit;
      end;
      if not EvalConstInt(TExpr(X.Indices[I]), FCur, V) then Exit;
      if (V < BT.Lo) or (V > BT.Hi) then
      begin
        Err(E.Pos, Format('Index %d out of range %d..%d', [V, BT.Lo, BT.Hi]));
        Exit;
      end;
      BO := BO + Int64(V - BT.Lo) * BT.ElemStrideBits;
      BT := BT.ElemType;
    end;
    Ofs := BO;
    T := BT;
    Exit(True);
  end;
  Err(E.Pos, 'Variable path expected');
end;

procedure TSclCompiler.BuildDBImage(B: TBlockInfo);
var
  I: Integer;
  S: TStmt;
  A: TAssign;
  Ofs: Int64;
  T: TSclType;
  C: TConstValue;
  Mode: TRetainMode;
begin
  if B.DataType = nil then Exit;
  SetLength(B.Image, AlignUpI((B.DataType.SizeBits + 7) div 8, 2));
  FillChar(B.Image[0], Length(B.Image), 0);
  ApplyDefaults(B.Image, B.DataType, 0);
  for I := 0 to B.U.Body.Count - 1 do
  begin
    S := B.U.Body.Stmt(I);
    if not (S is TAssign) then
    begin
      Err(S.Pos, 'Only assignments of start values are allowed in a DB');
      Continue;
    end;
    A := TAssign(S);
    if not StaticPath(A.Target, B.DataType, Ofs, T) then Continue;
    if not (IsElementaryKind(T.Kind) or IsStringKind(T.Kind)) then
    begin
      Err(A.Pos, 'Start value can only be set for elementary variables');
      Continue;
    end;
    if EvalConstFor(A.Value, B, T, C) then WriteConst(B.Image, Ofs, T, C);
  end;
  { retain map: 1 bit per byte }
  SetLength(B.RetainMap, (Length(B.Image) + 7) div 8);
  if Length(B.RetainMap) > 0 then FillChar(B.RetainMap[0], Length(B.RetainMap), 0);
  Mode := B.U.Retain;
  if Mode = rmDefault then
  begin
    if B.DBInstOf <> nil then Mode := rmNonRetain else Mode := rmRetain;
  end;
  if (Mode = rmRetain) and (B.DBInstOf = nil) and not B.Optimized then
  begin
    if Length(B.RetainMap) > 0 then FillChar(B.RetainMap[0], Length(B.RetainMap), $FF);
  end
  else if B.U.Retain <> rmNonRetain then
    MarkRetain(B, B.DataType, 0, Mode);
end;

{ ====================================================================== type inference }

function TSclCompiler.ConstFits(const C: TConstValue; T: TSclType): Boolean;
var
  Lo, Hi: Int64;
begin
  Result := True;
  if C.Kind <> ckInt then Exit;
  if T.Kind in [tkLInt, tkULInt, tkLWord, tkLTime, tkLTOD, tkLDT, tkAnyInt] then Exit;
  if IntRangeOf(T.Kind, Lo, Hi) then
    Result := (C.I >= Lo) and (C.I <= Hi);
  if T.Kind in [tkTime] then Result := (C.I >= -2147483648) and (C.I <= 2147483647);
end;

function TSclCompiler.ImplicitOK(Src, Dst: TSclType; E: TExpr; out Msg: string): Boolean;
var
  SK, DK: TTypeKind;
  IsC: Boolean;
  Strict: Boolean;
begin
  Msg := '';
  Result := True;
  if (Src = nil) or (Dst = nil) then Exit;
  SK := Src.Kind;
  DK := Dst.Kind;
  IsC := (E <> nil) and E.IsConst;
  Strict := FCpu in [cpuS7_300, cpuS7_400];
  if SK = DK then
  begin
    if SK = tkArray then Result := SameType(Src, Dst)
    else if SK in [tkStruct, tkFBInst, tkSysFB] then Result := SameType(Src, Dst) or (Src = Dst);
    if not Result then Msg := Format('Type %s is not compatible with %s', [TypeName(Src), TypeName(Dst)]);
    Exit;
  end;
  if SK = tkAnyInt then
  begin
    if IsIntKind(DK) or (DK in [tkByte, tkWord, tkDWord, tkLWord]) then
    begin
      Result := (E = nil) or not IsC or ConstFits(E.CVal, Dst);
      if not Result then Msg := Format('Constant %d is out of range for %s', [E.CVal.I, TypeName(Dst)]);
      Exit;
    end;
    if IsRealKind(DK) then Exit;
    if (DK = tkBool) and IsC and (E.CVal.I in [0, 1]) then Exit;
  end;
  if (SK = tkAnyReal) and IsRealKind(DK) then Exit;
  if SK = tkAnyString then
  begin
    if DK in [tkString, tkWString] then Exit;
    if (DK in [tkChar, tkWChar]) and IsC and (Length(E.CVal.S) = 1) then Exit;
  end;
  if (SK in [tkChar]) and (DK in [tkString, tkWString]) and IsC then Exit;
  if SK in [tkString, tkWString] then
  begin
    Result := DK in [tkString, tkWString];
    if not Result then Msg := Format('Cannot convert %s to %s', [TypeName(Src), TypeName(Dst)]);
    Exit;
  end;
  { integer widening }
  if IsIntKind(SK) and IsIntKind(DK) then
  begin
    if IsSignedKind(SK) = IsSignedKind(DK) then Result := IntRank(DK) > IntRank(SK)
    else if not IsSignedKind(SK) and IsSignedKind(DK) then Result := IntRank(DK) > IntRank(SK)
    else Result := False;
    if not Result then
      Msg := Format('Implicit conversion from %s to %s is not possible (use %s_TO_%s)',
        [TypeName(Src), TypeName(Dst), UpperCase(KindName(SK)), UpperCase(KindName(DK))]);
    Exit;
  end;
  if IsIntKind(SK) and IsRealKind(DK) then Exit;
  if (SK = tkReal) and (DK = tkLReal) then Exit;
  if IsBitKind(SK) and IsBitKind(DK) then
  begin
    Result := ElementaryBits(DK) >= ElementaryBits(SK);
    if not Result then
      Msg := Format('Implicit conversion from %s to %s is not possible', [TypeName(Src), TypeName(Dst)]);
    Exit;
  end;
  if not Strict and ((IsBitKind(SK) and (SK <> tkBool) and IsIntKind(DK)) or (IsIntKind(SK) and IsBitKind(DK) and (DK <> tkBool))) then
  begin
    Result := ElementaryBits(DK) >= ElementaryBits(SK);
    if not Result then
      Msg := Format('Implicit conversion from %s to %s is not possible', [TypeName(Src), TypeName(Dst)]);
    Exit;
  end;
  if (SK = tkChar) and (DK in [tkWChar]) then Exit;
  if (SK = tkTime) and (DK = tkLTime) then Exit;
  if (SK = tkLTime) and (DK = tkTime) and IsC then Exit;
  Result := False;
  Msg := Format('Cannot convert %s to %s', [TypeName(Src), TypeName(Dst)]);
end;

function TSclCompiler.CheckAssign(Src, Dst: TSclType; E: TExpr; const P: TSrcPos): Boolean;
var
  Msg: string;
begin
  Result := ImplicitOK(Src, Dst, E, Msg);
  if not Result then Err(P, Msg);
end;

function TSclCompiler.CommonType(A, B: TSclType; const P: TSrcPos; const OpText: string): TSclType;
var
  AK, BK: TTypeKind;
  RA, RB: Integer;
begin
  Result := nil;
  if (A = nil) or (B = nil) then Exit;
  AK := A.Kind;
  BK := B.Kind;
  if AK = BK then
  begin
    if AK = tkAnyInt then Exit(ElemType(tkAnyInt));
    if AK = tkAnyReal then Exit(ElemType(tkAnyReal));
    if AK = tkAnyString then Exit(ElemType(tkString));
    Exit(A);
  end;
  if AK = tkAnyInt then
  begin
    if IsNumericKind(BK) or IsBitKind(BK) or IsTimeKind(BK) then Exit(B);
  end;
  if BK = tkAnyInt then
  begin
    if IsNumericKind(AK) or IsBitKind(AK) or IsTimeKind(AK) then Exit(A);
  end;
  if (AK = tkAnyReal) and IsNumericKind(BK) then
  begin
    if BK = tkLReal then Exit(B) else Exit(ElemType(tkReal));
  end;
  if (BK = tkAnyReal) and IsNumericKind(AK) then
  begin
    if AK = tkLReal then Exit(A) else Exit(ElemType(tkReal));
  end;
  if IsRealKind(AK) and IsNumericKind(BK) then
  begin
    if (AK = tkLReal) or (BK = tkLReal) then Exit(ElemType(tkLReal)) else Exit(ElemType(tkReal));
  end;
  if IsRealKind(BK) and IsNumericKind(AK) then
  begin
    if (BK = tkLReal) then Exit(ElemType(tkLReal)) else Exit(ElemType(tkReal));
  end;
  if IsIntKind(AK) and IsIntKind(BK) then
  begin
    RA := IntRank(AK);
    RB := IntRank(BK);
    if IsSignedKind(AK) = IsSignedKind(BK) then
    begin
      if RA >= RB then Exit(A) else Exit(B);
    end;
    { mixed signed / unsigned: next bigger signed type }
    case Max(RA, RB) of
      1: Exit(ElemType(tkInt));
      2: Exit(ElemType(tkDInt));
    else
      Exit(ElemType(tkLInt));
    end;
  end;
  if IsBitKind(AK) and IsBitKind(BK) then
  begin
    if ElementaryBits(AK) >= ElementaryBits(BK) then Exit(A) else Exit(B);
  end;
  if not (FCpu in [cpuS7_300, cpuS7_400]) then
  begin
    if IsBitKind(AK) and (AK <> tkBool) and IsIntKind(BK) then
    begin
      if ElementaryBits(AK) >= ElementaryBits(BK) then Exit(A) else Exit(B);
    end;
    if IsBitKind(BK) and (BK <> tkBool) and IsIntKind(AK) then
    begin
      if ElementaryBits(BK) >= ElementaryBits(AK) then Exit(B) else Exit(A);
    end;
  end;
  if IsStringKind(AK) and IsStringKind(BK) then Exit(ElemType(tkString));
  if (AK = tkTime) and (BK = tkLTime) or (AK = tkLTime) and (BK = tkTime) then Exit(ElemType(tkLTime));
  Err(P, Format('Operator %s: incompatible operands %s and %s', [OpText, TypeName(A), TypeName(B)]));
end;

function BinOpText(Op: TBinOp): string;
const
  N: array[TBinOp] of string = ('OR', 'XOR', 'AND', '=', '<>', '<', '<=', '>', '>=', '+', '-', '*', '/', 'MOD', '**');
begin
  Result := N[Op];
end;

function TSclCompiler.FoldUnary(E: TUnary): Boolean;
var
  C: TConstValue;
  T: TSclType;
begin
  Result := False;
  if not E.Operand.IsConst then Exit;
  C := E.Operand.CVal;
  T := E.RType;
  case E.Op of
    uoNeg:
      if C.Kind = ckReal then C := CReal(-C.F) else if C.Kind = ckInt then C := CInt(-C.I) else Exit;
    uoNot:
      if C.Kind = ckBool then C := CBool(C.I = 0)
      else if C.Kind = ckInt then
      begin
        C := CInt(not C.I);
        if T <> nil then C.I := WrapToVT(C.I, VmTypeOf(T));
      end
      else Exit;
  else
    Exit;
  end;
  E.IsConst := True;
  E.CVal := C;
  Result := True;
end;

function TSclCompiler.FoldBinary(E: TBinary; OT: TSclType): Boolean;
var
  A, B, C: TConstValue;
  FA, FB: Double;
  IsF: Boolean;
  IsBoolRes: Boolean;
begin
  Result := False;
  if not (E.L.IsConst and E.R.IsConst) then Exit;
  A := E.L.CVal;
  B := E.R.CVal;
  if (A.Kind = ckString) or (B.Kind = ckString) then Exit;
  IsF := (A.Kind = ckReal) or (B.Kind = ckReal) or ((OT <> nil) and IsRealKind(OT.Kind));
  if A.Kind = ckReal then FA := A.F else FA := A.I;
  if B.Kind = ckReal then FB := B.F else FB := B.I;
  IsBoolRes := E.Op in [boEq, boNe, boLt, boLe, boGt, boGe];
  C.Kind := ckNone;
  case E.Op of
    boAdd: if IsF then C := CReal(FA + FB) else C := CInt(A.I + B.I);
    boSub: if IsF then C := CReal(FA - FB) else C := CInt(A.I - B.I);
    boMul: if IsF then C := CReal(FA * FB) else C := CInt(A.I * B.I);
    boDiv:
      if IsF then
      begin
        if FB = 0 then begin Err(E.Pos, 'Division by zero'); Exit; end;
        C := CReal(FA / FB);
      end
      else
      begin
        if B.I = 0 then begin Err(E.Pos, 'Division by zero'); Exit; end;
        C := CInt(A.I div B.I);
      end;
    boMod:
      begin
        if B.I = 0 then begin Err(E.Pos, 'Division by zero'); Exit; end;
        C := CInt(A.I mod B.I);
      end;
    boPow: C := CReal(Power(FA, FB));
    boAnd: if (A.Kind = ckBool) and (B.Kind = ckBool) then C := CBool((A.I and B.I) <> 0) else C := CInt(A.I and B.I);
    boOr: if (A.Kind = ckBool) and (B.Kind = ckBool) then C := CBool((A.I or B.I) <> 0) else C := CInt(A.I or B.I);
    boXor: if (A.Kind = ckBool) and (B.Kind = ckBool) then C := CBool((A.I xor B.I) <> 0) else C := CInt(A.I xor B.I);
    boEq: if IsF then C := CBool(FA = FB) else C := CBool(A.I = B.I);
    boNe: if IsF then C := CBool(FA <> FB) else C := CBool(A.I <> B.I);
    boLt: if IsF then C := CBool(FA < FB) else C := CBool(A.I < B.I);
    boLe: if IsF then C := CBool(FA <= FB) else C := CBool(A.I <= B.I);
    boGt: if IsF then C := CBool(FA > FB) else C := CBool(A.I > B.I);
    boGe: if IsF then C := CBool(FA >= FB) else C := CBool(A.I >= B.I);
  end;
  if C.Kind = ckNone then Exit;
  if (not IsBoolRes) and (C.Kind = ckInt) and (OT <> nil) and not (OT.Kind in [tkAnyInt]) then
    C.I := WrapToVT(C.I, VmTypeOf(OT));
  E.IsConst := True;
  E.CVal := C;
  Result := True;
end;

function TSclCompiler.InferName(E: TNameRef): TSclType;
var
  L: TLocalSym;
  B: TBlockInfo;
  TI: TTagInfo;
begin
  Result := nil;
  if (E.Scope <> nsGlobal) and (FCur <> nil) then
  begin
    L := FCur.FindLocal(E.Name);
    if L <> nil then
    begin
      E.RefObj := L;
      E.ByRef := L.ByRef;
      if L.Where = RK_CONST then
      begin
        E.RefKind := RK_CONST;
        E.IsConst := True;
        E.CVal := L.CVal;
      end
      else
      begin
        E.RefKind := L.Where;
        E.RefOfs := L.Ofs;
      end;
      Exit(L.Typ);
    end;
    if E.Scope = nsLocal then
    begin
      Err(E.Pos, Format('Unknown local variable #%s', [E.Name]));
      Exit;
    end;
  end;
  TI := FindTag(E.Name);
  if TI <> nil then
  begin
    if TI.IsConst then
    begin
      E.RefKind := RK_CONST;
      E.IsConst := True;
      E.CVal := TI.CVal;
    end
    else
    begin
      E.RefKind := RK_ABS;
      E.RefOfs := TI.Addr;
    end;
    E.RefObj := TI;
    Exit(TI.Typ);
  end;
  B := FindBlock(E.Name);
  if B <> nil then
  begin
    E.RefObj := B;
    if B.Kind = ukDB then
    begin
      ResolveBlock(B);
      E.RefKind := RK_DB;
      E.RefOfs := MakeAddr(AREA_DB, B.Number, 0);
      if (FCur <> nil) then FCur.Calls.Add(B.Name);
      Exit(B.DataType);
    end;
    E.RefKind := RK_BLOCK;
    Err(E.Pos, Format('%s "%s" cannot be used as a value', [B.KindText, B.Name]));
    Exit;
  end;
  if E.Scope = nsGlobal then
    Err(E.Pos, Format('Unknown tag or block "%s"', [E.Name]))
  else
    Err(E.Pos, Format('Unknown identifier "%s"', [E.Name]));
end;

function TSclCompiler.InferBinary(E: TBinary): TSclType;
var
  LT, RT, OT: TSclType;
  Txt: string;
begin
  Result := nil;
  LT := InferType(E.L);
  RT := InferType(E.R);
  if (LT = nil) or (RT = nil) then Exit;
  Txt := BinOpText(E.Op);
  OT := nil;
  case E.Op of
    boAnd, boOr, boXor:
      begin
        if (LT.Kind = tkBool) and (RT.Kind = tkBool) then OT := LT
        else if (IsBitKind(LT.Kind) or (LT.Kind = tkAnyInt)) and (IsBitKind(RT.Kind) or (RT.Kind = tkAnyInt)) then
        begin
          OT := CommonType(LT, RT, E.Pos, Txt);
          if (OT <> nil) and (OT.Kind = tkDInt) then OT := ElemType(tkDWord);
        end
        else if not (FCpu in [cpuS7_300, cpuS7_400]) and (IsIntKind(LT.Kind) and IsIntKind(RT.Kind)) then
          OT := CommonType(LT, RT, E.Pos, Txt)
        else
          Err(E.Pos, Format('Operator %s: Bool or bit string operands expected (%s, %s)', [Txt, TypeName(LT), TypeName(RT)]));
        Result := OT;
      end;
    boEq, boNe, boLt, boLe, boGt, boGe:
      begin
        if IsStringKind(LT.Kind) or IsStringKind(RT.Kind) or (LT.Kind in [tkChar, tkWChar]) and IsStringKind(RT.Kind) then
        begin
          if not (IsStringKind(LT.Kind) and IsStringKind(RT.Kind)) then
            Err(E.Pos, Format('Cannot compare %s with %s', [TypeName(LT), TypeName(RT)]));
          OT := ElemType(tkString);
        end
        else if (LT.Kind in [tkStruct, tkArray, tkFBInst, tkSysFB]) or (RT.Kind in [tkStruct, tkArray, tkFBInst, tkSysFB]) then
          Err(E.Pos, 'Structures and arrays cannot be compared')
        else if (LT.Kind = RT.Kind) then
        begin
          OT := LT;
          if LT.Kind = tkAnyInt then OT := ElemType(tkLInt);
          if LT.Kind = tkAnyReal then OT := ElemType(tkLReal);
          if (LT.Kind = tkBool) and not (E.Op in [boEq, boNe]) then OT := LT;
        end
        else if ((LT.Kind = tkAnyInt) and (RT.Kind in [tkChar, tkWChar])) or ((RT.Kind = tkAnyInt) and (LT.Kind in [tkChar, tkWChar])) then
          OT := ElemType(tkInt)
        else if (LT.Kind = tkAnyString) and (RT.Kind in [tkChar, tkWChar]) or (RT.Kind = tkAnyString) and (LT.Kind in [tkChar, tkWChar]) then
        begin
          if LT.Kind = tkAnyString then OT := RT else OT := LT;
        end
        else if IsDateTimeKind(LT.Kind) or IsDateTimeKind(RT.Kind) then
          Err(E.Pos, Format('Cannot compare %s with %s', [TypeName(LT), TypeName(RT)]))
        else
          OT := CommonType(LT, RT, E.Pos, Txt);
        if OT <> nil then Result := ElemType(tkBool);
      end;
    boAdd, boSub, boMul, boDiv, boMod, boPow:
      begin
        if IsTimeKind(LT.Kind) or IsTimeKind(RT.Kind) or (LT.Kind in [tkTOD, tkLTOD, tkDT, tkLDT, tkDate]) then
        begin
          if (E.Op in [boAdd, boSub]) and IsTimeKind(LT.Kind) and (IsTimeKind(RT.Kind) or (RT.Kind = tkAnyInt)) then
            OT := CommonType(LT, RT, E.Pos, Txt)
          else if (E.Op in [boAdd, boSub]) and (LT.Kind in [tkTOD, tkDT]) and (RT.Kind in [tkTime, tkAnyInt]) then
            OT := LT
          else if (E.Op in [boAdd, boSub]) and (LT.Kind in [tkLTOD, tkLDT]) and (RT.Kind in [tkLTime, tkAnyInt]) then
            OT := LT
          else if (E.Op = boSub) and (LT.Kind = tkTOD) and (RT.Kind = tkTOD) then
            OT := ElemType(tkTime)
          else if (E.Op in [boMul, boDiv]) and IsTimeKind(LT.Kind) and IsIntKind(RT.Kind) then
            OT := LT
          else if (E.Op = boMul) and IsIntKind(LT.Kind) and IsTimeKind(RT.Kind) then
            OT := RT
          else
            Err(E.Pos, Format('Operator %s not allowed for %s and %s', [Txt, TypeName(LT), TypeName(RT)]));
          if (OT <> nil) and (OT.Kind = tkS5Time) then
          begin
            Err(E.Pos, 'Arithmetic with S5Time is not allowed');
            OT := nil;
          end;
          Result := OT;
        end
        else if not ((IsNumericKind(LT.Kind)) and (IsNumericKind(RT.Kind))) then
          Err(E.Pos, Format('Operator %s: numeric operands expected (%s, %s)', [Txt, TypeName(LT), TypeName(RT)]))
        else if E.Op = boMod then
        begin
          if not (IsIntKind(LT.Kind) and IsIntKind(RT.Kind)) then
            Err(E.Pos, 'MOD requires integer operands')
          else
            OT := CommonType(LT, RT, E.Pos, Txt);
          Result := OT;
        end
        else if E.Op = boPow then
        begin
          if (LT.Kind = tkLReal) or (RT.Kind = tkLReal) then OT := ElemType(tkLReal) else OT := ElemType(tkReal);
          Result := OT;
        end
        else
        begin
          OT := CommonType(LT, RT, E.Pos, Txt);
          Result := OT;
        end;
      end;
  end;
  E.RefObj := OT;
  if (Result <> nil) then
  begin
    if FoldBinary(E, OT) then
    begin
      { a folded literal-only expression keeps its literal pseudo type }
      if (Result.Kind = tkDInt) and (LT.Kind = tkAnyInt) and (RT.Kind = tkAnyInt) then Result := ElemType(tkAnyInt);
      if (Result.Kind = tkLReal) and (LT.Kind in [tkAnyReal, tkAnyInt]) and (RT.Kind in [tkAnyReal, tkAnyInt]) then
        Result := ElemType(tkAnyReal);
      if (E.Op = boPow) and (LT.Kind in [tkAnyReal, tkAnyInt]) and (RT.Kind in [tkAnyReal, tkAnyInt]) then
        Result := ElemType(tkAnyReal);
      if (E.Op = boDiv) and (LT.Kind = tkAnyInt) and (RT.Kind = tkAnyInt) then Result := ElemType(tkAnyInt);
    end;
  end;
end;

function TSclCompiler.InferType(E: TExpr): TSclType;
var
  T, BT: TSclType;
  M: TMember;
  X: TIndexRef;
  I, V: Integer;
  Sl: TSliceRef;
  W: Integer;
  A: Int64;
  Msg: string;
  Lit: TLiteral;
begin
  Result := nil;
  if E = nil then Exit;
  if E.Checked then Exit(E.RType);
  E.Checked := True;
  if E is TLiteral then
  begin
    Lit := TLiteral(E);
    E.IsConst := True;
    case Lit.LitKind of
      lkInt:
        begin
          E.CVal := CInt(Lit.I);
          Result := ElemType(tkAnyInt);
        end;
      lkReal:
        begin
          E.CVal := CReal(Lit.F);
          Result := ElemType(tkAnyReal);
        end;
      lkBool:
        begin
          E.CVal := CBool(Lit.I <> 0);
          Result := ElemType(tkBool);
        end;
      lkString:
        begin
          E.CVal := CStr(Lit.S);
          Result := ElemType(tkAnyString);
        end;
      lkTyped:
        begin
          if (Lit.TypeName = 'STRING') or (Lit.TypeName = 'WSTRING') then
          begin
            E.CVal := CStr(Lit.S);
            Result := ElemType(tkAnyString);
          end
          else
          begin
            Result := FindElementaryType(Lit.TypeName);
            if Result = nil then
            begin
              Err(E.Pos, 'Unknown typed constant ' + Lit.TypeName);
              Exit;
            end;
            if not TypeSupportedOn(Result.Kind, FCpu) then
              Err(E.Pos, Format('Data type %s is not available on %s', [KindName(Result.Kind), CpuNames[FCpu]]));
            if IsRealKind(Result.Kind) then E.CVal := CReal(Lit.F)
            else if Result.Kind = tkBool then E.CVal := CBool(Lit.I <> 0)
            else
            begin
              E.CVal := CInt(Lit.I);
              if not ConstFits(E.CVal, Result) then
                Err(E.Pos, Format('Constant %d is out of range for %s', [Lit.I, KindName(Result.Kind)]));
            end;
          end;
        end;
    end;
  end
  else if E is TNameRef then
    Result := InferName(TNameRef(E))
  else if E is TMemberRef then
  begin
    BT := InferType(TMemberRef(E).Base);
    if BT <> nil then
    begin
      if not (BT.Kind in [tkStruct, tkFBInst, tkSysFB]) then
        Err(E.Pos, Format('"%s": %s has no members', [TMemberRef(E).Member, TypeName(BT)]))
      else
      begin
        M := BT.FindMember(TMemberRef(E).Member);
        if (M = nil) or M.Hidden then
          Err(E.Pos, Format('"%s" is not a member of %s', [TMemberRef(E).Member, TypeName(BT)]))
        else if M.Section = msTemp then
          Err(E.Pos, 'Temporary variables of an instance cannot be accessed')
        else
        begin
          E.RefKind := RK_PATH;
          E.RefObj := M;
          E.RefOfs := M.OffsetBits;
          E.ByRef := M.ByRef;
          Result := M.Typ;
        end;
      end;
    end;
  end
  else if E is TIndexRef then
  begin
    X := TIndexRef(E);
    BT := InferType(X.Base);
    if BT <> nil then
    begin
      Result := BT;
      for I := 0 to X.Indices.Count - 1 do
      begin
        T := InferType(TExpr(X.Indices[I]));
        if Result.Kind <> tkArray then
        begin
          Err(E.Pos, Format('%s is not an array', [TypeName(Result)]));
          Exit(nil);
        end;
        if (T <> nil) and not (IsIntKind(T.Kind) or (not (FCpu in [cpuS7_300, cpuS7_400]) and IsBitKind(T.Kind) and (T.Kind <> tkBool))) then
          Err(TExpr(X.Indices[I]).Pos, 'Array index must be an integer');
        if (T <> nil) and TExpr(X.Indices[I]).IsConst then
        begin
          V := TExpr(X.Indices[I]).CVal.I;
          if (V < Result.Lo) or (V > Result.Hi) then
            Err(TExpr(X.Indices[I]).Pos, Format('Index %d is out of range %d..%d', [V, Result.Lo, Result.Hi]));
        end
        else if FCpu in [cpuS7_300, cpuS7_400] then
          ; { indirect indexing allowed in SCL }
        Result := Result.ElemType;
      end;
      E.RefKind := RK_PATH;
    end;
  end
  else if E is TSliceRef then
  begin
    Sl := TSliceRef(E);
    BT := InferType(Sl.Base);
    if FCpu in [cpuS7_300, cpuS7_400] then
      Err(E.Pos, 'Slice access (%X, %B, %W, %D) is not available on ' + CpuNames[FCpu]);
    if BT <> nil then
    begin
      W := ElementaryBits(BT.Kind);
      if not ((IsBitKind(BT.Kind) and (BT.Kind <> tkBool)) or (IsIntKind(BT.Kind) and (BT.Kind <> tkAnyInt))) then
        Err(E.Pos, 'Slice access requires a bit string or integer variable')
      else
      begin
        case Sl.SliceKind of
          'X': begin Result := ElemType(tkBool); V := 1; end;
          'B': begin Result := ElemType(tkByte); V := 8; end;
          'W': begin Result := ElemType(tkWord); V := 16; end;
        else
          begin Result := ElemType(tkDWord); V := 32; end;
        end;
        if (Sl.Index + 1) * V > W then
        begin
          Err(E.Pos, Format('Slice %%%s%d exceeds the %d bits of %s', [Sl.SliceKind, Sl.Index, W, TypeName(BT)]));
          Result := nil;
        end;
      end;
      E.RefKind := RK_PATH;
    end;
  end
  else if E is TAbsAddr then
  begin
    if not ParseAbsAddress(TAbsAddr(E).Text, A, Result, Msg) then
    begin
      Err(E.Pos, 'Invalid absolute address %' + TAbsAddr(E).Text + ': ' + Msg);
      Result := nil;
    end
    else
    begin
      E.RefKind := RK_ABS;
      E.RefOfs := A;
      if (AddrArea(A) = AREA_DB) then
      begin
        Warn(E.Pos, 'Absolute DB access: only valid for standard access DBs');
      end;
    end;
  end
  else if E is TUnary then
  begin
    T := InferType(TUnary(E).Operand);
    if T <> nil then
    begin
      case TUnary(E).Op of
        uoNot:
          if (T.Kind = tkBool) or IsBitKind(T.Kind) then Result := T
          else if (T.Kind in [tkAnyInt]) then Result := ElemType(tkDWord)
          else if not (FCpu in [cpuS7_300, cpuS7_400]) and IsIntKind(T.Kind) then Result := T
          else Err(E.Pos, 'NOT requires a Bool or bit string operand');
        uoNeg:
          if (IsNumericKind(T.Kind) or (T.Kind in [tkTime, tkLTime])) then
          begin
            Result := T;
            if (T.Kind in [tkUSInt, tkUInt, tkUDInt, tkULInt]) then
              Warn(E.Pos, 'Negation of an unsigned value');
          end
          else Err(E.Pos, 'Negation requires a numeric operand');
      end;
      E.RType := Result;
      FoldUnary(TUnary(E));
    end;
  end
  else if E is TBinary then
    Result := InferBinary(TBinary(E))
  else if E is TCall then
    Result := InferCall(TCall(E))
  else if E is TArrayInit then
    Err(E.Pos, 'Array initializer is only allowed in declarations');
  E.RType := Result;
end;

{ ---------------------------------------------------------------- calls / builtins }

function TSclCompiler.ArgFor(C: TCall; const PName: string; Index: Integer; Positional: Boolean): TCallArg;
var
  I: Integer;
begin
  for I := 0 to C.Args.Count - 1 do
    if SameText(C.Arg(I).Name, PName) then Exit(C.Arg(I));
  if Positional and (Index >= 0) and (Index < C.Args.Count) and (C.Arg(Index).Name = '') then
    Exit(C.Arg(Index));
  Result := nil;
end;

function TSclCompiler.CallBlock(C: TCall; out IsFB: Boolean; out Inst: TExpr; out SysT: TSclType;
  out SysName: string): TBlockInfo;
var
  N: TNameRef;
  B: TBlockInfo;
  T, BT: TSclType;
  M: TMemberRef;
begin
  Result := nil;
  IsFB := False;
  Inst := nil;
  SysT := nil;
  SysName := '';
  if C.Callee is TNameRef then
  begin
    N := TNameRef(C.Callee);
    if N.Scope <> nsLocal then
    begin
      if (FCur = nil) or (FCur.FindLocal(N.Name) = nil) or (N.Scope = nsGlobal) then
      begin
        B := FindBlock(N.Name);
        if B <> nil then
        begin
          ResolveBlock(B);
          case B.Kind of
            ukFC: Exit(B);
            ukDB:
              if B.DBInstOf <> nil then
              begin
                InferType(C.Callee);
                IsFB := True;
                Inst := C.Callee;
                Exit(B.DBInstOf);
              end
              else if (B.DataType <> nil) and (B.DataType.Kind = tkSysFB) and not SysFBCallable(B.DataType, 'TON') then
              begin
                InferType(C.Callee);
                SysT := B.DataType;
                SysName := B.DataType.SysFB;
                Inst := C.Callee;
                Exit(nil);
              end;
            ukFB:
              begin
                Err(C.Pos, Format('FB "%s" must be called with an instance', [B.Name]));
                Exit(nil);
              end;
          end;
        end;
      end;
    end;
  end;
  { system FB through IEC_TIMER container: #t.TON(...) }
  if C.Callee is TMemberRef then
  begin
    M := TMemberRef(C.Callee);
    BT := InferType(M.Base);
    if (BT <> nil) and (BT.Kind = tkSysFB) and SysFBCallable(BT, M.Member) then
    begin
      SysT := BT;
      SysName := UpperCase(M.Member);
      Inst := M.Base;
      Exit(nil);
    end;
  end;
  T := InferType(C.Callee);
  if T = nil then Exit(nil);
  if T.Kind = tkFBInst then
  begin
    IsFB := True;
    Inst := C.Callee;
    Exit(TBlockInfo(T.Block));
  end;
  if T.Kind = tkSysFB then
  begin
    if SysFBCallable(T, 'TON') or SysFBCallable(T, 'CTU') then
    begin
      Err(C.Pos, Format('%s must be called with a function name, e.g. #t.TON(...)', [T.Name]));
      Exit(nil);
    end;
    SysT := T;
    SysName := T.SysFB;
    Inst := C.Callee;
    Exit(nil);
  end;
  Err(C.Pos, 'Not callable: ' + TypeName(T));
end;

function IsBuiltinName(const N: string): Boolean;
var
  U: string;
begin
  U := UpperCase(N);
  Result := (Pos('_TO_', U) > 0) or
    (U = 'ABS') or (U = 'SQR') or (U = 'SQRT') or (U = 'EXP') or (U = 'LN') or (U = 'LOG') or
    (U = 'SIN') or (U = 'COS') or (U = 'TAN') or (U = 'ASIN') or (U = 'ACOS') or (U = 'ATAN') or
    (U = 'FRAC') or (U = 'TRUNC') or (U = 'ROUND') or (U = 'CEIL') or (U = 'FLOOR') or
    (U = 'MIN') or (U = 'MAX') or (U = 'LIMIT') or (U = 'SEL') or (U = 'MUX') or
    (U = 'NORM_X') or (U = 'SCALE_X') or (U = 'SHL') or (U = 'SHR') or (U = 'ROL') or (U = 'ROR') or
    (U = 'LEN') or (U = 'CONCAT') or (U = 'LEFT') or (U = 'RIGHT') or (U = 'MID') or (U = 'FIND');
end;

function TSclCompiler.InferBuiltin(C: TCall; const AName: string; out Handled: Boolean): TSclType;
var
  U, SrcN, DstN: string;
  P, I: Integer;
  ST, DT, T, AT: TSclType;
  A: TCallArg;

  function ArgN(const PN: string; Idx: Integer): TExpr;
  var
    X: TCallArg;
  begin
    X := ArgFor(C, PN, Idx, True);
    if X = nil then
    begin
      Err(C.Pos, Format('%s: parameter %s is missing', [U, PN]));
      Result := nil;
    end
    else
      Result := X.Value;
  end;

  function TypeOfArg(const PN: string; Idx: Integer): TSclType;
  var
    X: TExpr;
  begin
    X := ArgN(PN, Idx);
    if X = nil then Exit(nil);
    Result := InferType(X);
  end;

  function NeedNumeric(T0: TSclType; const PN: string): Boolean;
  begin
    Result := (T0 <> nil) and IsNumericKind(T0.Kind);
    if (T0 <> nil) and not Result then
      Err(C.Pos, Format('%s: parameter %s must be numeric (%s)', [U, PN, TypeName(T0)]));
  end;

  function RealOf(T0: TSclType): TSclType;
  begin
    if (T0 <> nil) and (T0.Kind = tkLReal) then Result := ElemType(tkLReal) else Result := ElemType(tkReal);
  end;

  function Concrete(T0: TSclType): TSclType;
  begin
    { literal pseudo types stay (they adapt to the assignment target) }
    Result := T0;
    if T0 = nil then Exit;
    if T0.Kind = tkAnyString then Result := ElemType(tkString);
  end;

begin
  Result := nil;
  Handled := True;
  U := UpperCase(AName);
  P := Pos('_TO_', U);
  if P > 0 then
  begin
    SrcN := Copy(U, 1, P - 1);
    DstN := Copy(U, P + 4, MaxInt);
    ST := FindElementaryType(SrcN);
    DT := FindElementaryType(DstN);
    if (ST = nil) or (DT = nil) or (ST.Kind = tkVoid) or (DT.Kind = tkVoid) then
    begin
      if (SrcN = 'STRING') or (DstN = 'STRING') or (SrcN = 'WSTRING') or (DstN = 'WSTRING') then
        Err(C.Pos, Format('%s is not supported by this compiler', [U]))
      else
        Err(C.Pos, Format('Unknown conversion function %s', [U]));
      Exit;
    end;
    if not TypeSupportedOn(ST.Kind, FCpu) or not TypeSupportedOn(DT.Kind, FCpu) then
      Err(C.Pos, Format('%s is not available on %s', [U, CpuNames[FCpu]]));
    if IsDateTimeKind(ST.Kind) and not (DT.Kind in [tkDInt, tkUDInt, tkUInt, tkInt, tkLInt, tkULInt]) or
       IsDateTimeKind(DT.Kind) and not (ST.Kind in [tkDInt, tkUDInt, tkUInt, tkInt, tkLInt, tkULInt]) then
      Err(C.Pos, Format('%s is not supported', [U]));
    if (ST.Kind = tkS5Time) and (DT.Kind <> tkTime) or (DT.Kind = tkS5Time) and (ST.Kind <> tkTime) then
      Err(C.Pos, Format('%s is not supported (use S5TIME_TO_TIME / TIME_TO_S5TIME)', [U]));
    T := TypeOfArg('IN', 0);
    if T <> nil then CheckAssign(T, ST, ArgN('IN', 0), C.Pos);
    C.RefObj := ST;
    Exit(DT);
  end;
  if (U = 'TRUNC') or (U = 'ROUND') or (U = 'CEIL') or (U = 'FLOOR') then
  begin
    T := TypeOfArg('IN', 0);
    if (T <> nil) and not IsRealKind(T.Kind) then Err(C.Pos, U + ': Real or LReal expected');
    Exit(ElemType(tkDInt));
  end;
  if U = 'ABS' then
  begin
    T := TypeOfArg('IN', 0);
    if NeedNumeric(T, 'IN') then Exit(Concrete(T));
    Exit;
  end;
  if (U = 'SQR') or (U = 'SQRT') or (U = 'EXP') or (U = 'LN') or (U = 'LOG') or (U = 'SIN') or
     (U = 'COS') or (U = 'TAN') or (U = 'ASIN') or (U = 'ACOS') or (U = 'ATAN') or (U = 'FRAC') then
  begin
    T := TypeOfArg('IN', 0);
    if NeedNumeric(T, 'IN') then Exit(RealOf(T));
    Exit;
  end;
  if (U = 'MIN') or (U = 'MAX') then
  begin
    if C.Args.Count < 2 then begin Err(C.Pos, U + ' needs at least 2 inputs'); Exit; end;
    Result := nil;
    for I := 0 to C.Args.Count - 1 do
    begin
      A := C.Arg(I);
      AT := InferType(A.Value);
      if AT = nil then Exit(nil);
      if not (IsNumericKind(AT.Kind) or IsTimeKind(AT.Kind) or IsBitKind(AT.Kind) and (AT.Kind <> tkBool)) then
      begin
        Err(A.Pos, U + ': numeric inputs expected');
        Exit(nil);
      end;
      if Result = nil then Result := AT else Result := CommonType(Result, AT, A.Pos, U);
      if Result = nil then Exit;
    end;
    Result := Concrete(Result);
    C.RefObj := Result;
    Exit;
  end;
  if U = 'LIMIT' then
  begin
    T := TypeOfArg('MN', 0);
    AT := TypeOfArg('IN', 1);
    ST := TypeOfArg('MX', 2);
    if (T = nil) or (AT = nil) or (ST = nil) then Exit;
    Result := CommonType(CommonType(T, AT, C.Pos, U), ST, C.Pos, U);
    Result := Concrete(Result);
    C.RefObj := Result;
    Exit;
  end;
  if U = 'SEL' then
  begin
    T := TypeOfArg('G', 0);
    if (T <> nil) and (T.Kind <> tkBool) then Err(C.Pos, 'SEL: G must be Bool');
    AT := TypeOfArg('IN0', 1);
    ST := TypeOfArg('IN1', 2);
    if (AT = nil) or (ST = nil) then Exit;
    Result := Concrete(CommonType(AT, ST, C.Pos, U));
    if (Result <> nil) and not (IsElementaryKind(Result.Kind) or (Result.Kind in [tkAnyInt, tkAnyReal])) then
    begin
      Err(C.Pos, 'SEL: elementary inputs expected');
      Exit(nil);
    end;
    C.RefObj := Result;
    Exit;
  end;
  if U = 'MUX' then
  begin
    T := TypeOfArg('K', 0);
    if (T <> nil) and not IsIntKind(T.Kind) then Err(C.Pos, 'MUX: K must be an integer');
    if C.Args.Count < 3 then begin Err(C.Pos, 'MUX needs K and at least 2 inputs'); Exit; end;
    Result := nil;
    for I := 1 to C.Args.Count - 1 do
    begin
      if SameText(C.Arg(I).Name, 'K') then Continue;
      AT := InferType(C.Arg(I).Value);
      if AT = nil then Exit(nil);
      if Result = nil then Result := AT else Result := CommonType(Result, AT, C.Arg(I).Pos, U);
      if Result = nil then Exit;
    end;
    Result := Concrete(Result);
    if not (IsElementaryKind(Result.Kind) or (Result.Kind in [tkAnyInt, tkAnyReal])) then begin Err(C.Pos, 'MUX: elementary inputs expected'); Exit(nil); end;
    C.RefObj := Result;
    Exit;
  end;
  if (U = 'NORM_X') or (U = 'SCALE_X') then
  begin
    T := TypeOfArg('MIN', 0);
    AT := TypeOfArg('VALUE', 1);
    ST := TypeOfArg('MAX', 2);
    if not (NeedNumeric(T, 'MIN') and NeedNumeric(AT, 'VALUE') and NeedNumeric(ST, 'MAX')) then Exit;
    if U = 'NORM_X' then
    begin
      if (T.Kind = tkLReal) or (AT.Kind = tkLReal) or (ST.Kind = tkLReal) then Result := ElemType(tkLReal)
      else Result := ElemType(tkReal);
    end
    else
    begin
      if not IsRealKind(AT.Kind) then Err(C.Pos, 'SCALE_X: VALUE must be Real or LReal');
      Result := Concrete(CommonType(T, ST, C.Pos, U));
    end;
    C.RefObj := Result;
    Exit;
  end;
  if (U = 'SHL') or (U = 'SHR') or (U = 'ROL') or (U = 'ROR') then
  begin
    T := TypeOfArg('IN', 0);
    AT := TypeOfArg('N', 1);
    if T = nil then Exit;
    if not ((IsBitKind(T.Kind) and (T.Kind <> tkBool)) or (IsIntKind(T.Kind) and (T.Kind <> tkAnyInt))) then
    begin
      Err(C.Pos, U + ': IN must be a bit string or integer variable');
      Exit;
    end;
    if (AT <> nil) and not IsIntKind(AT.Kind) then Err(C.Pos, U + ': N must be an integer');
    Exit(T);
  end;
  if U = 'LEN' then
  begin
    T := TypeOfArg('IN', 0);
    if (T <> nil) and not IsStringKind(T.Kind) then Err(C.Pos, 'LEN: String expected');
    Exit(ElemType(tkInt));
  end;
  if (U = 'CONCAT') or (U = 'LEFT') or (U = 'RIGHT') or (U = 'MID') or (U = 'FIND') then
  begin
    if (U = 'CONCAT') or (U = 'FIND') then
    begin
      T := TypeOfArg('IN1', 0);
      AT := TypeOfArg('IN2', 1);
      if ((T <> nil) and not IsStringKind(T.Kind)) or ((AT <> nil) and not IsStringKind(AT.Kind)) then
        Err(C.Pos, U + ': String inputs expected');
    end
    else
    begin
      T := TypeOfArg('IN', 0);
      if (T <> nil) and not IsStringKind(T.Kind) then Err(C.Pos, U + ': String expected');
      AT := TypeOfArg('L', 1);
      if (AT <> nil) and not IsIntKind(AT.Kind) then Err(C.Pos, U + ': L must be an integer');
      if U = 'MID' then
      begin
        AT := TypeOfArg('P', 2);
        if (AT <> nil) and not IsIntKind(AT.Kind) then Err(C.Pos, 'MID: P must be an integer');
      end;
    end;
    if U = 'FIND' then Exit(ElemType(tkInt));
    if (T <> nil) and (T.Kind = tkWString) then Exit(NewStringType(254, True));
    Exit(NewStringType(254, False));
  end;
  Handled := False;
end;

function TSclCompiler.InferCall(C: TCall): TSclType;
var
  B: TBlockInfo;
  IsFB, Positional: Boolean;
  Inst: TExpr;
  SysT, PT: TSclType;
  SysName: string;
  I, J: Integer;
  A: TCallArg;
  M: TMember;
  Params: TSclType;
  Handled: Boolean;
  AT: TSclType;
begin
  Result := nil;
  { builtins (plain names, not shadowed by a local) }
  if (C.Callee is TNameRef) and (TNameRef(C.Callee).Scope = nsPlain) and
     IsBuiltinName(TNameRef(C.Callee).Name) and
     ((FCur = nil) or (FCur.FindLocal(TNameRef(C.Callee).Name) = nil) or
      not (FCur.FindLocal(TNameRef(C.Callee).Name).Typ.Kind in [tkFBInst, tkSysFB])) and
     (FindBlock(TNameRef(C.Callee).Name) = nil) then
  begin
    Result := InferBuiltin(C, TNameRef(C.Callee).Name, Handled);
    C.RefKind := 100;
    if Handled then Exit;
  end;
  B := CallBlock(C, IsFB, Inst, SysT, SysName);
  if (B = nil) and (SysT = nil) then
  begin
    if (C.Callee is TNameRef) and (FindBlock(TNameRef(C.Callee).Name) = nil) and
       ((FCur = nil) or (FCur.FindLocal(TNameRef(C.Callee).Name) = nil)) and (FindTag(TNameRef(C.Callee).Name) = nil) and
       not C.Callee.Checked then
      Err(C.Pos, Format('Unknown function or block "%s"', [TNameRef(C.Callee).Name]));
    Exit;
  end;
  if B <> nil then
  begin
    if FCur <> nil then FCur.Calls.Add(B.Name);
    if (FCur <> nil) and (B = FCur) then
      Err(C.Pos, 'Recursive calls are not allowed');
    if IsFB then Params := B.DataType else Params := B.ParamType;
    if Params = nil then Exit;
    { validate arguments }
    Positional := (C.Args.Count > 0) and (C.Arg(0).Name = '');
    if Positional and not IsFB then
    begin
      { positional FC call: inputs, in-outs, outputs in declaration order }
      J := 0;
      for I := 0 to Params.MemberCount - 1 do
        if Params.Member(I).Section <> msReturn then Inc(J);
      if C.Args.Count <> J then
        Err(C.Pos, Format('"%s" expects %d parameters', [B.Name, J]));
    end;
    for I := 0 to C.Args.Count - 1 do
    begin
      A := C.Arg(I);
      if SameText(A.Name, 'EN') or SameText(A.Name, 'ENO') then
      begin
        InferType(A.Value);
        Continue;
      end;
      if A.Name = '' then
      begin
        if IsFB or not Positional then
        begin
          Err(A.Pos, 'Parameter name expected (Name := value)');
          Continue;
        end;
        InferType(A.Value);
        Continue;
      end;
      M := Params.FindMember(A.Name);
      if (M = nil) or (M.Section in [msStatic, msTemp, msReturn]) then
      begin
        Err(A.Pos, Format('"%s" has no parameter "%s"', [B.Name, A.Name]));
        InferType(A.Value);
        Continue;
      end;
      AT := InferType(A.Value);
      if AT = nil then Continue;
      if M.Section = msOutput then
      begin
        if not A.IsOut then
          Err(A.Pos, Format('Output "%s" must be assigned with =>', [A.Name]))
        else if not IsLValue(A.Value) then
          Err(A.Pos, 'Variable expected for output ' + A.Name)
        else
          CheckAssign(M.Typ, AT, nil, A.Pos);
      end
      else
      begin
        if A.IsOut then Err(A.Pos, Format('"%s" is not an output (use :=)', [A.Name]));
        if M.Section = msInOut then
        begin
          if not IsLValue(A.Value) then Err(A.Pos, 'Variable expected for InOut parameter ' + A.Name)
          else if not SameType(AT, M.Typ) and not ((AT.Kind = M.Typ.Kind) and IsElementaryKind(AT.Kind)) then
            Err(A.Pos, Format('InOut "%s": type %s expected, %s given', [A.Name, TypeName(M.Typ), TypeName(AT)]));
        end
        else if M.ByRef and not (IsLValue(A.Value) or (AT.Kind = tkAnyString)) then
          Err(A.Pos, Format('Parameter "%s" (%s) needs a variable', [A.Name, TypeName(M.Typ)]))
        else
          CheckAssign(AT, M.Typ, A.Value, A.Pos);
      end;
    end;
    if not IsFB and not Positional then
      for I := 0 to Params.MemberCount - 1 do
      begin
        M := Params.Member(I);
        if (M.Section in [msInput, msInOut]) and (ArgFor(C, M.Name, -1, False) = nil) then
          Err(C.Pos, Format('Parameter "%s" of "%s" must be assigned', [M.Name, B.Name]));
      end;
    if IsFB then
      for I := 0 to Params.MemberCount - 1 do
      begin
        M := Params.Member(I);
        if (M.Section = msInOut) and (ArgFor(C, M.Name, -1, False) = nil) then
          Err(C.Pos, Format('InOut parameter "%s" of "%s" must be assigned', [M.Name, B.Name]));
      end;
    if IsFB then Result := ElemType(tkVoid) else Result := B.RetType;
    Exit;
  end;
  { system FB }
  Params := SysT;
  for I := 0 to C.Args.Count - 1 do
  begin
    A := C.Arg(I);
    if A.Name = '' then
    begin
      Err(A.Pos, 'Parameter name expected (Name := value)');
      Continue;
    end;
    M := Params.FindMember(A.Name);
    if (M = nil) or M.Hidden then
    begin
      Err(A.Pos, Format('%s has no parameter "%s"', [SysName, A.Name]));
      Continue;
    end;
    AT := InferType(A.Value);
    if AT = nil then Continue;
    if M.Section = msOutput then
    begin
      if not A.IsOut then Err(A.Pos, Format('Output "%s" must be assigned with =>', [A.Name]))
      else if not IsLValue(A.Value) then Err(A.Pos, 'Variable expected for output ' + A.Name)
      else CheckAssign(M.Typ, AT, nil, A.Pos);
    end
    else
      CheckAssign(AT, M.Typ, A.Value, A.Pos);
  end;
  PT := nil;
  if PT = nil then;
  Result := ElemType(tkVoid);
  C.RefObj := SysT;
end;

function TSclCompiler.IsLValue(E: TExpr): Boolean;
begin
  if E = nil then Exit(False);
  if E.IsConst then Exit(False);
  if E is TNameRef then
    Result := E.RefKind in [RK_INST, RK_FRAME, RK_ABS, RK_DB]
  else if (E is TMemberRef) then
    Result := IsLValue(TMemberRef(E).Base)
  else if (E is TIndexRef) then
    Result := IsLValue(TIndexRef(E).Base)
  else if (E is TSliceRef) then
    Result := IsLValue(TSliceRef(E).Base)
  else
    Result := E is TAbsAddr;
end;

{ ====================================================================== emission }

procedure TSclCompiler.EmitLine(const P: TSrcPos);
begin
  if (FSvb <> nil) and (P.Line > 0) then FSvb.AddLine(FCode.Size, P.Line);
end;

function TSclCompiler.AllocTemp(T: TSclType): Int64;
var
  A: Int64;
begin
  A := AlignBitsFor(T);
  if A < 16 then A := 16;
  FCur.TempBits := AlignUpI(FCur.TempBits, A);
  Result := FCur.TempBase + FCur.TempBits;
  Inc(FCur.TempBits, AlignUpI(T.SizeBits, 16));
end;

function TSclCompiler.AllocStringTemp(MaxLen: Integer; Wide: Boolean): Int64;
var
  K: Integer;
begin
  Result := AllocTemp(NewStringType(MaxLen, Wide));
  K := Length(FCur.StringTemps);
  SetLength(FCur.StringTemps, K + 1);
  FCur.StringTemps[K].Ofs := Result;
  FCur.StringTemps[K].MaxLen := MaxLen;
  FCur.StringTemps[K].Wide := Wide;
end;

function TSclCompiler.ConstStringAddr(const S: string; Wide: Boolean): Int64;
var
  I, Ofs, N: Integer;
  Key: string;
begin
  if Wide then Key := 'W' + S else Key := 'S' + S;
  if FPoolStrings.Find(Key, I) then
    Exit(MakeAddr(AREA_C, 0, Int64(PtrInt(FPoolStrings.Objects[I])) * 8));
  Ofs := Length(FPool);
  if Ofs mod 2 <> 0 then Inc(Ofs);
  if Wide then N := 4 + Length(S) * 2 else N := 2 + Length(S);
  SetLength(FPool, AlignUpI(Ofs + N, 2));
  MemWriteString(FPool, Int64(Ofs) * 8, Length(S), S, Wide);
  FPoolStrings.AddObject(Key, TObject(PtrInt(Ofs)));
  Result := MakeAddr(AREA_C, 0, Int64(Ofs) * 8);
end;

procedure TSclCompiler.EmitAddr(E: TExpr);
var
  X: TIndexRef;
  I: Integer;
  T, IT: TSclType;
  IE: TExpr;
  V: Int64;
begin
  if E is TNameRef then
  begin
    case E.RefKind of
      RK_INST: FCode.OpU(opAddrInst, E.RefOfs);
      RK_FRAME: FCode.OpU(opAddrLocal, E.RefOfs);
      RK_ABS, RK_DB: FCode.OpQ(opPushAddr, E.RefOfs);
    else
      Err(E.Pos, 'Variable expected');
      FCode.OpQ(opPushAddr, 0);
      Exit;
    end;
    if E.ByRef then FCode.Op(opLoadPtr);
  end
  else if E is TMemberRef then
  begin
    EmitAddr(TMemberRef(E).Base);
    if E.RefOfs <> 0 then FCode.OpU(opAddrAdd, E.RefOfs);
    if E.ByRef then FCode.Op(opLoadPtr);
  end
  else if E is TIndexRef then
  begin
    X := TIndexRef(E);
    EmitAddr(X.Base);
    T := X.Base.RType;
    for I := 0 to X.Indices.Count - 1 do
    begin
      IE := TExpr(X.Indices[I]);
      if IE.IsConst then
      begin
        V := (IE.CVal.I - T.Lo) * T.ElemStrideBits;
        if V <> 0 then FCode.OpU(opAddrAdd, V);
      end
      else
      begin
        IT := IE.RType;
        EmitValue(IE, nil);
        if (IT <> nil) and IsRealKind(IT.Kind) then FCode.Op(opF2IRound);
        FCode.EmitByte(Ord(opAddrIndex));
        FCode.EmitI32(T.Lo);
        FCode.EmitU32(T.ElemStrideBits);
        FCode.EmitU32(T.ElemCount);
      end;
      T := T.ElemType;
    end;
  end
  else if E is TAbsAddr then
    FCode.OpQ(opPushAddr, E.RefOfs)
  else if (E is TLiteral) and (E.RType <> nil) and (E.RType.Kind = tkAnyString) then
    FCode.OpQ(opPushAddr, ConstStringAddr(E.CVal.S, False))
  else
  begin
    Err(E.Pos, 'Variable expected');
    FCode.OpQ(opPushAddr, 0);
  end;
end;

procedure TSclCompiler.EmitConst(const C: TConstValue; T, Want: TSclType);
var
  Tg: TSclType;
  F: Double;
  S: Single;
begin
  Tg := Want;
  if Tg = nil then Tg := T;
  if (Tg <> nil) and IsStringKind(Tg.Kind) then
  begin
    if C.Kind = ckString then
      FCode.OpQ(opPushAddr, ConstStringAddr(C.S, Tg.Kind = tkWString))
    else
      FCode.OpQ(opPushAddr, ConstStringAddr(Chr(C.I and $FF), Tg.Kind = tkWString));
    Exit;
  end;
  if (C.Kind = ckString) then
  begin
    if C.S <> '' then FCode.OpQ(opPushI, Ord(C.S[1])) else FCode.OpQ(opPushI, 0);
    Exit;
  end;
  if (Tg <> nil) and IsRealKind(Tg.Kind) then
  begin
    if C.Kind = ckReal then F := C.F else F := C.I;
    if Tg.Kind = tkReal then
    begin
      S := F;
      F := S;
    end;
    FCode.EmitByte(Ord(opPushF));
    FCode.EmitF64(F);
    Exit;
  end;
  if C.Kind = ckReal then
    FCode.OpQ(opPushI, Round(C.F))
  else
    FCode.OpQ(opPushI, C.I);
end;

procedure TSclCompiler.EmitImplicit(From, ToT: TSclType);
var
  FK, TK: TTypeKind;
begin
  if (From = nil) or (ToT = nil) then Exit;
  FK := From.Kind;
  TK := ToT.Kind;
  if FK = TK then Exit;
  if IsRealKind(TK) and not IsRealKind(FK) then
  begin
    if FK in [tkULInt, tkLWord] then FCode.Op(opU2F) else FCode.Op(opI2F);
    if TK = tkReal then FCode.Op(opF2F32);
    Exit;
  end;
  if (TK = tkReal) and (FK = tkLReal) then
  begin
    FCode.Op(opF2F32);
    Exit;
  end;
  if (FK = tkTime) and (TK = tkLTime) then
  begin
    FCode.OpQ(opPushI, 1000000);
    FCode.Op(opMulI);
    Exit;
  end;
  if (FK = tkLTime) and (TK = tkTime) then
  begin
    FCode.OpQ(opPushI, 1000000);
    FCode.Op(opDivI);
    FCode.OpB(opWrap, VT_TIME);
    Exit;
  end;
  { integer re-interpretation (e.g. Word -> Int of the same width) }
  if IsElementaryKind(FK) and IsElementaryKind(TK) and (ElementaryBits(TK) <= ElementaryBits(FK)) and
     (IsSignedKind(TK) <> IsSignedKind(FK)) then
    FCode.OpB(opWrap, Ord(TK));
end;

procedure TSclCompiler.EmitExplicit(From, ToT: TSclType);
var
  FK, TK: TTypeKind;
begin
  FK := From.Kind;
  TK := ToT.Kind;
  if FK = TK then Exit;
  if IsRealKind(FK) then
  begin
    if IsRealKind(TK) then
    begin
      if TK = tkReal then FCode.Op(opF2F32);
    end
    else
    begin
      FCode.Op(opF2IRound);
      FCode.OpB(opWrap, Ord(TK));
    end;
    Exit;
  end;
  if IsRealKind(TK) then
  begin
    EmitImplicit(From, ToT);
    Exit;
  end;
  if TK = tkBool then
  begin
    FCode.OpQ(opPushI, 1);
    FCode.Op(opAnd);
    Exit;
  end;
  if (FK = tkTime) and (TK = tkLTime) or (FK = tkLTime) and (TK = tkTime) then
  begin
    EmitImplicit(From, ToT);
    Exit;
  end;
  FCode.OpB(opWrap, Ord(TK));
end;

procedure TSclCompiler.EmitValue(E: TExpr; Want: TSclType);
var
  T: TSclType;
  Sl: TSliceRef;
  W: Integer;
begin
  T := E.RType;
  if T = nil then
  begin
    FCode.OpQ(opPushI, 0);
    Exit;
  end;
  if E.IsConst then
  begin
    EmitConst(E.CVal, T, Want);
    Exit;
  end;
  if (E is TNameRef) or (E is TMemberRef) or (E is TIndexRef) or (E is TAbsAddr) then
  begin
    EmitAddr(E);
    if IsElementaryKind(T.Kind) then
      FCode.OpB(opLoad, VmTypeOf(T));
  end
  else if E is TSliceRef then
  begin
    Sl := TSliceRef(E);
    EmitValue(Sl.Base, nil);
    case Sl.SliceKind of
      'X': FCode.OpB(opGetBit, Sl.Index);
      'B': W := 8;
      'W': W := 16;
    else
      W := 32;
    end;
    if Sl.SliceKind <> 'X' then
    begin
      FCode.EmitByte(Ord(opGetField));
      FCode.EmitByte(Sl.Index * W);
      FCode.EmitByte(W);
    end;
  end
  else if E is TUnary then
  begin
    EmitValue(TUnary(E).Operand, T);
    case TUnary(E).Op of
      uoNeg:
        if IsRealKind(T.Kind) then FCode.Op(opNegF)
        else
        begin
          FCode.Op(opNegI);
          FCode.OpB(opWrap, VmTypeOf(T));
        end;
      uoNot:
        if T.Kind = tkBool then
        begin
          FCode.OpQ(opPushI, 1);
          FCode.Op(opXor);
        end
        else
        begin
          FCode.Op(opNot);
          FCode.OpB(opWrap, VmTypeOf(T));
        end;
    end;
  end
  else if E is TBinary then
    EmitBinary(TBinary(E))
  else if E is TCall then
  begin
    EmitCall(TCall(E), True);
  end
  else
    FCode.OpQ(opPushI, 0);
  if (Want <> nil) and IsElementaryKind(T.Kind) then EmitImplicit(T, Want);
end;

procedure TSclCompiler.EmitBinary(E: TBinary);
var
  OT, LT, RT: TSclType;
  F, U: Boolean;
  VT: Byte;
  Wide: Boolean;
begin
  OT := TSclType(E.RefObj);
  if OT = nil then
  begin
    FCode.OpQ(opPushI, 0);
    Exit;
  end;
  LT := E.L.RType;
  RT := E.R.RType;
  F := IsRealKind(OT.Kind);
  U := OT.Kind in [tkULInt, tkLWord];
  VT := VmTypeOf(OT);
  { strings }
  if IsStringKind(OT.Kind) then
  begin
    Wide := (LT.Kind = tkWString) or (RT.Kind = tkWString);
    EmitValue(E.L, OT);
    EmitValue(E.R, OT);
    FCode.OpB(opStrCmp, Ord(Wide));
    FCode.OpQ(opPushI, 0);
    case E.Op of
      boEq: FCode.Op(opEqI);
      boNe: FCode.Op(opNeI);
      boLt: FCode.Op(opLtI);
      boLe: FCode.Op(opLeI);
      boGt: FCode.Op(opGtI);
      boGe: FCode.Op(opGeI);
    end;
    Exit;
  end;
  { time * int, time / int }
  if (E.Op in [boMul, boDiv]) and IsTimeKind(OT.Kind) then
  begin
    if IsTimeKind(LT.Kind) then
    begin
      EmitValue(E.L, OT);
      EmitValue(E.R, ElemType(tkLInt));
    end
    else
    begin
      EmitValue(E.L, ElemType(tkLInt));
      EmitValue(E.R, OT);
    end;
    if E.Op = boMul then FCode.Op(opMulI) else FCode.Op(opDivI);
    FCode.OpB(opWrap, VT);
    Exit;
  end;
  if (E.Op in [boAdd, boSub]) and (OT.Kind in [tkTOD, tkDT, tkLTOD, tkLDT]) then
  begin
    EmitValue(E.L, nil);
    EmitValue(E.R, nil);
    if E.Op = boAdd then FCode.Op(opAddI) else FCode.Op(opSubI);
    if OT.Kind = tkTOD then
    begin
      FCode.OpQ(opPushI, 86400000);
      FCode.Op(opAddI);
      FCode.OpQ(opPushI, 86400000);
      FCode.Op(opModI);
    end;
    Exit;
  end;
  if (E.Op = boSub) and (LT.Kind = tkTOD) and (RT.Kind = tkTOD) then
  begin
    EmitValue(E.L, nil);
    EmitValue(E.R, nil);
    FCode.Op(opSubI);
    Exit;
  end;
  if E.Op = boPow then
  begin
    EmitValue(E.L, OT);
    EmitValue(E.R, OT);
    FCode.Op(opExptF);
    if OT.Kind = tkReal then FCode.Op(opF2F32);
    Exit;
  end;
  EmitValue(E.L, OT);
  EmitValue(E.R, OT);
  case E.Op of
    boAnd: FCode.Op(opAnd);
    boOr: FCode.Op(opOr);
    boXor: FCode.Op(opXor);
    boAdd: if F then FCode.Op(opAddF) else FCode.Op(opAddI);
    boSub: if F then FCode.Op(opSubF) else FCode.Op(opSubI);
    boMul: if F then FCode.Op(opMulF) else FCode.Op(opMulI);
    boDiv: if F then FCode.Op(opDivF) else FCode.Op(opDivI);
    boMod: FCode.Op(opModI);
    boEq: if F then FCode.Op(opEqF) else FCode.Op(opEqI);
    boNe: if F then FCode.Op(opNeF) else FCode.Op(opNeI);
    boLt: if F then FCode.Op(opLtF) else if U then FCode.Op(opLtU) else FCode.Op(opLtI);
    boLe: if F then FCode.Op(opLeF) else if U then FCode.Op(opLeU) else FCode.Op(opLeI);
    boGt: if F then FCode.Op(opGtF) else if U then FCode.Op(opGtU) else FCode.Op(opGtI);
    boGe: if F then FCode.Op(opGeF) else if U then FCode.Op(opGeU) else FCode.Op(opGeI);
  end;
  if E.Op in [boAdd, boSub, boMul, boDiv, boMod] then
  begin
    if F then
    begin
      if OT.Kind = tkReal then FCode.Op(opF2F32);
    end
    else
      FCode.OpB(opWrap, VT);
  end;
end;

procedure TSclCompiler.EmitSrcValue(const Src: TValSrc; Want: TSclType);
begin
  if Src.Kind = vsExpr then
  begin
    EmitValue(Src.E, Want);
    Exit;
  end;
  if Src.FromFrame then FCode.OpU(opAddrNewFrame, Src.Ofs)
  else
  begin
    if Src.BaseE <> nil then EmitAddr(Src.BaseE) else FCode.OpQ(opPushAddr, Src.BaseAddr);
    if Src.Ofs <> 0 then FCode.OpU(opAddrAdd, Src.Ofs);
  end;
  if IsElementaryKind(Src.Typ.Kind) then
  begin
    FCode.OpB(opLoad, VmTypeOf(Src.Typ));
    EmitImplicit(Src.Typ, Want);
  end;
end;

procedure TSclCompiler.EmitStore(Target: TExpr; const Src: TValSrc);
var
  TT: TSclType;
  Sl: TSliceRef;
  W: Integer;
  BT: TSclType;
begin
  TT := Target.RType;
  if TT = nil then Exit;
  if Target is TSliceRef then
  begin
    Sl := TSliceRef(Target);
    BT := Sl.Base.RType;
    if Sl.Base is TSliceRef then
    begin
      Err(Target.Pos, 'Nested slice access cannot be written');
      Exit;
    end;
    EmitAddr(Sl.Base);
    FCode.Op(opDup);
    FCode.OpB(opLoad, VmTypeOf(BT));
    EmitSrcValue(Src, TT);
    case Sl.SliceKind of
      'X': FCode.OpB(opSetBit, Sl.Index);
      'B': W := 8;
      'W': W := 16;
    else
      W := 32;
    end;
    if Sl.SliceKind <> 'X' then
    begin
      FCode.EmitByte(Ord(opSetField));
      FCode.EmitByte(Sl.Index * W);
      FCode.EmitByte(W);
    end;
    FCode.OpB(opStore, VmTypeOf(BT));
    Exit;
  end;
  if IsElementaryKind(TT.Kind) then
  begin
    EmitAddr(Target);
    EmitSrcValue(Src, TT);
    FCode.OpB(opStore, VmTypeOf(TT));
  end
  else if IsStringKind(TT.Kind) then
  begin
    EmitAddr(Target);
    EmitSrcValue(Src, TT);
    FCode.OpB(opStrCpy, Ord(TT.Kind = tkWString));
  end
  else
  begin
    EmitAddr(Target);
    if Src.Kind = vsExpr then EmitAddr(Src.E) else EmitSrcValue(Src, nil);
    FCode.OpU(opMemCpy, TT.SizeBits);
  end;
end;

function ExprSrc(E: TExpr): TValSrc;
begin
  Result.Kind := vsExpr;
  Result.E := E;
  Result.Typ := E.RType;
  Result.BaseE := nil;
  Result.BaseAddr := 0;
  Result.FromFrame := False;
  Result.Ofs := 0;
end;

function FrameSrc(Ofs: Int64; T: TSclType): TValSrc;
begin
  Result.Kind := vsAddrOfs;
  Result.E := nil;
  Result.Typ := T;
  Result.BaseE := nil;
  Result.BaseAddr := 0;
  Result.FromFrame := True;
  Result.Ofs := Ofs;
end;

function InstSrc(BaseE: TExpr; Ofs: Int64; T: TSclType): TValSrc;
begin
  Result.Kind := vsAddrOfs;
  Result.E := nil;
  Result.Typ := T;
  Result.BaseE := BaseE;
  Result.BaseAddr := 0;
  Result.FromFrame := False;
  Result.Ofs := Ofs;
end;

function SysFBId(const N: string; T: TSclType): Integer;
var
  L: Boolean;
  U: string;
begin
  U := UpperCase(N);
  L := (T <> nil) and ((Pos('LTIME', T.SysFB) > 0) or (T.SysFB = 'IEC_LTIMER'));
  if Copy(U, 1, 4) = 'TONR' then Result := SFB_TONR
  else if Copy(U, 1, 3) = 'TON' then Result := SFB_TON
  else if Copy(U, 1, 3) = 'TOF' then Result := SFB_TOF
  else if Copy(U, 1, 2) = 'TP' then Result := SFB_TP
  else if Copy(U, 1, 4) = 'CTUD' then Exit(SFB_CTUD)
  else if Copy(U, 1, 3) = 'CTU' then Exit(SFB_CTU)
  else if Copy(U, 1, 3) = 'CTD' then Exit(SFB_CTD)
  else if U = 'R_TRIG' then Exit(SFB_RTRIG)
  else if U = 'F_TRIG' then Exit(SFB_FTRIG)
  else if U = 'RS' then Exit(SFB_RS)
  else if U = 'SR' then Exit(SFB_SR)
  else Exit(0);
  if L then Inc(Result, 10);
end;

function TSclCompiler.EmitCall(C: TCall; WantResult: Boolean): TSclType;
var
  B: TBlockInfo;
  IsFB, Positional: Boolean;
  Inst: TExpr;
  SysT: TSclType;
  SysName: string;
  Params: TSclType;
  I, PI: Integer;
  M: TMember;
  A: TCallArg;
  AT: TSclType;
  CntT: TMember;

  procedure StoreInput(const M0: TMember; AV: TExpr; InFrame: Boolean; InstE: TExpr);
  var
    AT0: TSclType;
  begin
    AT0 := AV.RType;
    if InFrame then FCode.OpU(opAddrNewFrame, M0.OffsetBits)
    else
    begin
      EmitAddr(InstE);
      if M0.OffsetBits <> 0 then FCode.OpU(opAddrAdd, M0.OffsetBits);
    end;
    if M0.ByRef then
    begin
      EmitAddr(AV);
      FCode.OpB(opStore, VT_PTR);
    end
    else if IsElementaryKind(M0.Typ.Kind) then
    begin
      EmitValue(AV, M0.Typ);
      FCode.OpB(opStore, VmTypeOf(M0.Typ));
    end
    else if IsStringKind(M0.Typ.Kind) then
    begin
      EmitValue(AV, M0.Typ);
      FCode.OpB(opStrCpy, Ord(M0.Typ.Kind = tkWString));
    end
    else
    begin
      EmitAddr(AV);
      FCode.OpU(opMemCpy, M0.Typ.SizeBits);
    end;
    if AT0 = nil then;
  end;

begin
  Result := C.RType;
  { builtin }
  if C.RefKind = 100 then
  begin
    Result := EmitBuiltin(C, TNameRef(C.Callee).Name, WantResult);
    Exit;
  end;
  B := CallBlock(C, IsFB, Inst, SysT, SysName);
  if (B = nil) and (SysT = nil) then Exit;
  if B <> nil then
  begin
    if B.CodeIndex < 0 then Exit;
    if IsFB then
    begin
      Params := B.DataType;
      for I := 0 to C.Args.Count - 1 do
      begin
        A := C.Arg(I);
        M := Params.FindMember(A.Name);
        if (M = nil) or (M.Section = msOutput) or (A.Value.RType = nil) then Continue;
        StoreInput(M, A.Value, False, Inst);
      end;
      EmitAddr(Inst);
      FCode.OpW(opCallFB, B.CodeIndex);
      for I := 0 to C.Args.Count - 1 do
      begin
        A := C.Arg(I);
        M := Params.FindMember(A.Name);
        if (M = nil) or (M.Section <> msOutput) or (A.Value.RType = nil) then Continue;
        EmitStore(A.Value, InstSrc(Inst, M.OffsetBits, M.Typ));
      end;
      Exit(ElemType(tkVoid));
    end;
    { FC }
    Params := B.ParamType;
    Positional := (C.Args.Count > 0) and (C.Arg(0).Name = '');
    FCode.OpU(opFrameAlloc, AlignUpI((Params.SizeBits + 7) div 8, 2));
    PI := 0;
    for I := 0 to Params.MemberCount - 1 do
    begin
      M := Params.Member(I);
      if M.Section = msReturn then Continue;
      if Positional then
      begin
        if PI < C.Args.Count then A := C.Arg(PI) else A := nil;
        Inc(PI);
      end
      else
        A := ArgFor(C, M.Name, -1, False);
      if (A = nil) or (A.Value.RType = nil) then Continue;
      if (M.Section = msOutput) then
      begin
        if M.ByRef then
        begin
          FCode.OpU(opAddrNewFrame, M.OffsetBits);
          EmitAddr(A.Value);
          FCode.OpB(opStore, VT_PTR);
        end;
        Continue;
      end;
      StoreInput(M, A.Value, True, nil);
    end;
    FCode.OpW(opCall, B.CodeIndex);
    PI := 0;
    for I := 0 to Params.MemberCount - 1 do
    begin
      M := Params.Member(I);
      if M.Section = msReturn then Continue;
      if Positional then
      begin
        if PI < C.Args.Count then A := C.Arg(PI) else A := nil;
        Inc(PI);
      end
      else
        A := ArgFor(C, M.Name, -1, False);
      if (A = nil) or (A.Value.RType = nil) or (M.Section <> msOutput) or M.ByRef then Continue;
      EmitStore(A.Value, FrameSrc(M.OffsetBits, M.Typ));
    end;
    if WantResult and (B.RetType <> nil) and (B.RetType.Kind <> tkVoid) then
    begin
      FCode.OpU(opAddrNewFrame, 0);
      FCode.OpB(opLoad, VmTypeOf(B.RetType));
    end
    else if WantResult then
      Err(C.Pos, Format('FC "%s" does not return a value', [B.Name]));
    FCode.Op(opFrameFree);
    Exit(B.RetType);
  end;
  { system FB }
  for I := 0 to C.Args.Count - 1 do
  begin
    A := C.Arg(I);
    M := SysT.FindMember(A.Name);
    if (M = nil) or (M.Section = msOutput) or (A.Value.RType = nil) then Continue;
    StoreInput(M, A.Value, False, Inst);
  end;
  EmitAddr(Inst);
  CntT := SysT.FindMember('CV');
  FCode.EmitByte(Ord(opSysFB));
  FCode.EmitWord(SysFBId(SysName, SysT));
  if CntT <> nil then FCode.EmitByte(VmTypeOf(CntT.Typ)) else FCode.EmitByte(0);
  for I := 0 to C.Args.Count - 1 do
  begin
    A := C.Arg(I);
    M := SysT.FindMember(A.Name);
    if (M = nil) or (M.Section <> msOutput) or (A.Value.RType = nil) then Continue;
    EmitStore(A.Value, InstSrc(Inst, M.OffsetBits, M.Typ));
  end;
  AT := nil;
  if AT = nil then;
  Result := ElemType(tkVoid);
end;

function TSclCompiler.EmitBuiltin(C: TCall; const AName: string; WantResult: Boolean): TSclType;
var
  U: string;
  T, ST, AT: TSclType;
  I, N, Bits: Integer;
  X: TExpr;
  Wide: Boolean;
  Tmp: Int64;
  Op: TOpcode;

  function Arg(const PN: string; Idx: Integer): TExpr;
  var
    A: TCallArg;
  begin
    A := ArgFor(C, PN, Idx, True);
    if A = nil then Result := nil else Result := A.Value;
  end;

  procedure PushF(E: TExpr);
  begin
    EmitValue(E, ElemType(tkLReal));
  end;

begin
  U := UpperCase(AName);
  Result := C.RType;
  T := C.RType;
  if not WantResult then
    Warn(C.Pos, Format('Result of %s is not used', [U]));
  if Pos('_TO_', U) > 0 then
  begin
    ST := TSclType(C.RefObj);
    X := Arg('IN', 0);
    if (X = nil) or (ST = nil) or (T = nil) then Exit;
    EmitValue(X, ST);
    if (ST.Kind = tkS5Time) or (T.Kind = tkS5Time) then
      { S5Time is kept as milliseconds on the stack }
    else
      EmitExplicit(ST, T);
  end
  else if (U = 'TRUNC') or (U = 'ROUND') or (U = 'CEIL') or (U = 'FLOOR') then
  begin
    PushF(Arg('IN', 0));
    if U = 'TRUNC' then FCode.Op(opF2ITrunc)
    else if U = 'ROUND' then FCode.Op(opF2IRound)
    else if U = 'CEIL' then FCode.Op(opF2ICeil)
    else FCode.Op(opF2IFloor);
    FCode.OpB(opWrap, VT_DINT);
  end
  else if U = 'ABS' then
  begin
    EmitValue(Arg('IN', 0), T);
    if IsRealKind(T.Kind) then FCode.Op(opAbsF)
    else
    begin
      FCode.Op(opAbsI);
      FCode.OpB(opWrap, VmTypeOf(T));
    end;
  end
  else if U = 'SQR' then
  begin
    EmitValue(Arg('IN', 0), T);
    FCode.Op(opDup);
    FCode.Op(opMulF);
    if T.Kind = tkReal then FCode.Op(opF2F32);
  end
  else if (U = 'SQRT') or (U = 'EXP') or (U = 'LN') or (U = 'LOG') or (U = 'SIN') or (U = 'COS') or
    (U = 'TAN') or (U = 'ASIN') or (U = 'ACOS') or (U = 'ATAN') or (U = 'FRAC') then
  begin
    EmitValue(Arg('IN', 0), T);
    if U = 'SQRT' then N := BI_SQRT else if U = 'EXP' then N := BI_EXP else if U = 'LN' then N := BI_LN
    else if U = 'LOG' then N := BI_LOG else if U = 'SIN' then N := BI_SIN else if U = 'COS' then N := BI_COS
    else if U = 'TAN' then N := BI_TAN else if U = 'ASIN' then N := BI_ASIN else if U = 'ACOS' then N := BI_ACOS
    else if U = 'ATAN' then N := BI_ATAN else N := BI_FRAC;
    FCode.OpW(opBuiltin, N);
    if T.Kind = tkReal then FCode.Op(opF2F32);
  end
  else if (U = 'MIN') or (U = 'MAX') then
  begin
    T := TSclType(C.RefObj);
    for I := 0 to C.Args.Count - 1 do
    begin
      EmitValue(C.Arg(I).Value, T);
      if I > 0 then
      begin
        if IsRealKind(T.Kind) then
        begin
          if U = 'MIN' then FCode.Op(opMinF) else FCode.Op(opMaxF);
        end
        else if U = 'MIN' then FCode.Op(opMinI) else FCode.Op(opMaxI);
      end;
    end;
    Result := T;
  end
  else if U = 'LIMIT' then
  begin
    T := TSclType(C.RefObj);
    EmitValue(Arg('IN', 1), T);
    EmitValue(Arg('MN', 0), T);
    if IsRealKind(T.Kind) then FCode.Op(opMaxF) else FCode.Op(opMaxI);
    EmitValue(Arg('MX', 2), T);
    if IsRealKind(T.Kind) then FCode.Op(opMinF) else FCode.Op(opMinI);
    Result := T;
  end
  else if U = 'SEL' then
  begin
    T := TSclType(C.RefObj);
    EmitValue(Arg('G', 0), ElemType(tkBool));
    EmitValue(Arg('IN0', 1), T);
    EmitValue(Arg('IN1', 2), T);
    FCode.Op(opSel);
    Result := T;
  end
  else if U = 'MUX' then
  begin
    T := TSclType(C.RefObj);
    N := 0;
    for I := 0 to C.Args.Count - 1 do
    begin
      if SameText(C.Arg(I).Name, 'K') or ((I = 0) and (C.Arg(I).Name = '')) then Continue;
      EmitValue(C.Arg(I).Value, T);
      Inc(N);
    end;
    EmitValue(Arg('K', 0), ElemType(tkDInt));
    FCode.OpB(opMuxPick, N);
    Result := T;
  end
  else if U = 'NORM_X' then
  begin
    PushF(Arg('VALUE', 1));
    PushF(Arg('MIN', 0));
    FCode.Op(opSubF);
    PushF(Arg('MAX', 2));
    PushF(Arg('MIN', 0));
    FCode.Op(opSubF);
    FCode.Op(opDivF);
    if T.Kind = tkReal then FCode.Op(opF2F32);
  end
  else if U = 'SCALE_X' then
  begin
    PushF(Arg('VALUE', 1));
    PushF(Arg('MAX', 2));
    PushF(Arg('MIN', 0));
    FCode.Op(opSubF);
    FCode.Op(opMulF);
    PushF(Arg('MIN', 0));
    FCode.Op(opAddF);
    if IsRealKind(T.Kind) then
    begin
      if T.Kind = tkReal then FCode.Op(opF2F32);
    end
    else
    begin
      FCode.Op(opF2IRound);
      FCode.OpB(opWrap, VmTypeOf(T));
    end;
  end
  else if (U = 'SHL') or (U = 'SHR') or (U = 'ROL') or (U = 'ROR') then
  begin
    EmitValue(Arg('IN', 0), T);
    EmitValue(Arg('N', 1), ElemType(tkDInt));
    Bits := ElementaryBits(T.Kind);
    if U = 'SHL' then Op := opShl else if U = 'SHR' then Op := opShr
    else if U = 'ROL' then Op := opRol else Op := opRor;
    FCode.OpB(Op, Bits);
    FCode.OpB(opWrap, VmTypeOf(T));
  end
  else if U = 'LEN' then
  begin
    X := Arg('IN', 0);
    EmitValue(X, nil);
    FCode.OpB(opStrLen, Ord(X.RType.Kind = tkWString));
  end
  else if U = 'FIND' then
  begin
    X := Arg('IN1', 0);
    Wide := X.RType.Kind = tkWString;
    EmitValue(X, nil);
    EmitValue(Arg('IN2', 1), nil);
    FCode.OpB(opStrFind, Ord(Wide));
  end
  else if (U = 'CONCAT') or (U = 'LEFT') or (U = 'RIGHT') or (U = 'MID') then
  begin
    Wide := T.Kind = tkWString;
    Tmp := AllocStringTemp(254, Wide);
    FCode.OpU(opAddrLocal, Tmp);
    if U = 'CONCAT' then
    begin
      EmitValue(Arg('IN1', 0), T);
      EmitValue(Arg('IN2', 1), T);
      FCode.OpB(opStrConcat, Ord(Wide));
    end
    else
    begin
      EmitValue(Arg('IN', 0), T);
      EmitValue(Arg('L', 1), ElemType(tkDInt));
      if U = 'MID' then
      begin
        EmitValue(Arg('P', 2), ElemType(tkDInt));
        FCode.OpB(opStrMid, Ord(Wide));
      end
      else if U = 'LEFT' then FCode.OpB(opStrLeft, Ord(Wide))
      else FCode.OpB(opStrRight, Ord(Wide));
    end;
  end;
  if not WantResult and (T <> nil) and (T.Kind <> tkVoid) then FCode.Op(opDrop);
  AT := nil;
  if AT = nil then;
end;

{ ---------------------------------------------------------------- statements }

procedure TSclCompiler.EmitStmts(L: TStmtList);
var
  I: Integer;
begin
  if L = nil then Exit;
  for I := 0 to L.Count - 1 do EmitStmt(L.Stmt(I));
end;

procedure TSclCompiler.EmitAssign(S: TAssign);
var
  TT, VT: TSclType;
  L: TLocalSym;
begin
  TT := InferType(S.Target);
  VT := InferType(S.Value);
  if (TT = nil) or (VT = nil) then Exit;
  if not IsLValue(S.Target) then
  begin
    Err(S.Target.Pos, 'Assignment target must be a variable');
    Exit;
  end;
  if (S.Target is TNameRef) and (S.Target.RefKind = RK_DB) then
  begin
    Err(S.Target.Pos, 'A whole data block cannot be assigned');
    Exit;
  end;
  if (S.Target is TNameRef) and (S.Target.RefObj is TLocalSym) then
  begin
    L := TLocalSym(S.Target.RefObj);
    if (L.Section = msInput) and (FCur.Kind = ukFC) and (FCpu in [cpuS7_300, cpuS7_400]) then
      Warn(S.Target.Pos, Format('Writing to input parameter #%s', [L.Name]));
  end;
  if VT.Kind = tkVoid then
  begin
    Err(S.Value.Pos, 'Expression has no value');
    Exit;
  end;
  if not CheckAssign(VT, TT, S.Value, S.Value.Pos) then Exit;
  if (TT.Kind in [tkArray, tkStruct, tkFBInst, tkSysFB]) and not IsLValue(S.Value) then
  begin
    Err(S.Value.Pos, 'Variable expected');
    Exit;
  end;
  if FDiags.ErrorCount > 0 then Exit;
  EmitStore(S.Target, ExprSrc(S.Value));
end;

procedure TSclCompiler.EmitIf(S: TIfStmt);
var
  I: Integer;
  LEnd, LNext: Integer;
  T: TSclType;
  Cd: TExpr;
begin
  LEnd := FCode.NewLabel;
  for I := 0 to S.Conds.Count - 1 do
  begin
    Cd := TExpr(S.Conds[I]);
    T := InferType(Cd);
    if (T <> nil) and (T.Kind <> tkBool) then
      Err(Cd.Pos, 'Condition must be of type Bool (' + TypeName(T) + ')');
    LNext := FCode.NewLabel;
    EmitLine(Cd.Pos);
    EmitValue(Cd, nil);
    FCode.Jump(opJz, LNext);
    EmitStmts(TStmtList(S.Bodies[I]));
    FCode.Jump(opJmp, LEnd);
    FCode.SetLabel(LNext);
  end;
  EmitStmts(S.ElseBody);
  FCode.SetLabel(LEnd);
end;

procedure TSclCompiler.EmitCase(S: TCaseStmt);
var
  T, LT: TSclType;
  Tmp: Int64;
  I, J, K: Integer;
  It: TCaseItem;
  Lb: TCaseLabel;
  LEnd: Integer;
  Bodies: array of Integer;
  VTp: Byte;
  Seen: TList;
  V, VLo, VHi: Int64;
begin
  T := InferType(S.Selector);
  if T = nil then Exit;
  if not (IsIntKind(T.Kind) or (IsBitKind(T.Kind) and (T.Kind <> tkBool)) or (T.Kind in [tkChar])) then
  begin
    Err(S.Selector.Pos, 'CASE selector must be an integer (' + TypeName(T) + ')');
    Exit;
  end;
  if T.Kind = tkAnyInt then T := ElemType(tkDInt);
  VTp := VmTypeOf(T);
  Tmp := AllocTemp(T);
  EmitLine(S.Pos);
  FCode.OpU(opAddrLocal, Tmp);
  EmitValue(S.Selector, T);
  FCode.OpB(opStore, VTp);
  LEnd := FCode.NewLabel;
  SetLength(Bodies, S.Items.Count);
  Seen := TList.Create;
  try
    for I := 0 to S.Items.Count - 1 do
    begin
      It := TCaseItem(S.Items[I]);
      Bodies[I] := FCode.NewLabel;
      for J := 0 to It.Labels.Count - 1 do
      begin
        Lb := TCaseLabel(It.Labels[J]);
        LT := InferType(Lb.Lo);
        if (LT = nil) then Continue;
        if not Lb.Lo.IsConst then
        begin
          Err(Lb.Lo.Pos, 'CASE label must be a constant');
          Continue;
        end;
        VLo := Lb.Lo.CVal.I;
        VHi := VLo;
        if Lb.Hi <> nil then
        begin
          InferType(Lb.Hi);
          if not Lb.Hi.IsConst then
          begin
            Err(Lb.Hi.Pos, 'CASE label must be a constant');
            Continue;
          end;
          VHi := Lb.Hi.CVal.I;
          if VHi < VLo then Err(Lb.Hi.Pos, 'Empty CASE range');
        end;
        if VHi - VLo < 1000 then
          for V := VLo to VHi do
          begin
            if Seen.IndexOf(Pointer(PtrInt(V))) >= 0 then
              Warn(Lb.Lo.Pos, Format('CASE value %d is used more than once', [V]))
            else
              Seen.Add(Pointer(PtrInt(V)));
          end;
        FCode.OpU(opAddrLocal, Tmp);
        FCode.OpB(opLoad, VTp);
        if Lb.Hi = nil then
        begin
          FCode.OpQ(opPushI, VLo);
          FCode.Op(opEqI);
        end
        else
        begin
          FCode.OpQ(opPushI, VLo);
          FCode.Op(opGeI);
          FCode.OpU(opAddrLocal, Tmp);
          FCode.OpB(opLoad, VTp);
          FCode.OpQ(opPushI, VHi);
          FCode.Op(opLeI);
          FCode.Op(opAnd);
        end;
        FCode.Jump(opJnz, Bodies[I]);
      end;
    end;
  finally
    Seen.Free;
  end;
  EmitStmts(S.ElseBody);
  FCode.Jump(opJmp, LEnd);
  for I := 0 to S.Items.Count - 1 do
  begin
    It := TCaseItem(S.Items[I]);
    FCode.SetLabel(Bodies[I]);
    EmitStmts(It.Body);
    FCode.Jump(opJmp, LEnd);
  end;
  FCode.SetLabel(LEnd);
  K := 0;
  if K = 0 then;
end;

procedure TSclCompiler.EmitFor(S: TForStmt);
var
  VT, FT, TT, BT: TSclType;
  TmpEnd, TmpStep: Int64;
  LTop, LCont, LEnd, LNeg, LCheckDone: Integer;
  StepConst: Boolean;
  StepVal: Int64;
  VTp: Byte;
  K: Integer;
begin
  VT := InferType(S.VarRef);
  FT := InferType(S.FromE);
  TT := InferType(S.ToE);
  BT := nil;
  if S.ByE <> nil then BT := InferType(S.ByE);
  if VT = nil then Exit;
  if not (IsIntKind(VT.Kind) and (VT.Kind <> tkAnyInt)) then
  begin
    Err(S.VarRef.Pos, 'FOR control variable must be an integer variable');
    Exit;
  end;
  if not IsLValue(S.VarRef) or not (S.VarRef is TNameRef) then
  begin
    Err(S.VarRef.Pos, 'FOR control variable must be a simple variable');
    Exit;
  end;
  if (FT = nil) or (TT = nil) then Exit;
  CheckAssign(FT, VT, S.FromE, S.FromE.Pos);
  CheckAssign(TT, VT, S.ToE, S.ToE.Pos);
  if BT <> nil then CheckAssign(BT, VT, S.ByE, S.ByE.Pos);
  StepConst := (S.ByE = nil) or S.ByE.IsConst;
  if S.ByE = nil then StepVal := 1 else if StepConst then StepVal := S.ByE.CVal.I else StepVal := 0;
  if StepConst and (StepVal = 0) then
  begin
    Err(S.ByE.Pos, 'FOR step must not be 0');
    Exit;
  end;
  VTp := VmTypeOf(VT);
  EmitLine(S.Pos);
  { var := from }
  EmitAddr(S.VarRef);
  EmitValue(S.FromE, VT);
  FCode.OpB(opStore, VTp);
  TmpEnd := AllocTemp(ElemType(tkLInt));
  FCode.OpU(opAddrLocal, TmpEnd);
  EmitValue(S.ToE, VT);
  FCode.OpB(opStore, VT_LINT);
  TmpStep := 0;
  if not StepConst then
  begin
    TmpStep := AllocTemp(ElemType(tkLInt));
    FCode.OpU(opAddrLocal, TmpStep);
    EmitValue(S.ByE, VT);
    FCode.OpB(opStore, VT_LINT);
  end;
  LTop := FCode.NewLabel;
  LCont := FCode.NewLabel;
  LEnd := FCode.NewLabel;
  FCode.SetLabel(LTop);
  EmitValue(S.VarRef, nil);
  FCode.OpU(opAddrLocal, TmpEnd);
  FCode.OpB(opLoad, VT_LINT);
  if StepConst then
  begin
    if StepVal > 0 then FCode.Op(opGtI) else FCode.Op(opLtI);
    FCode.Jump(opJnz, LEnd);
  end
  else
  begin
    LNeg := FCode.NewLabel;
    LCheckDone := FCode.NewLabel;
    FCode.OpU(opAddrLocal, TmpStep);
    FCode.OpB(opLoad, VT_LINT);
    FCode.OpQ(opPushI, 0);
    FCode.Op(opLtI);
    FCode.Jump(opJnz, LNeg);
    FCode.Op(opGtI);
    FCode.Jump(opJmp, LCheckDone);
    FCode.SetLabel(LNeg);
    FCode.Op(opLtI);
    FCode.SetLabel(LCheckDone);
    FCode.Jump(opJnz, LEnd);
  end;
  K := Length(FLoops);
  SetLength(FLoops, K + 1);
  FLoops[K].BreakL := LEnd;
  FLoops[K].ContL := LCont;
  EmitStmts(S.Body);
  SetLength(FLoops, K);
  FCode.SetLabel(LCont);
  { var := var + step (stop when the addition would overflow the type) }
  EmitAddr(S.VarRef);
  EmitValue(S.VarRef, nil);
  if StepConst then FCode.OpQ(opPushI, StepVal)
  else
  begin
    FCode.OpU(opAddrLocal, TmpStep);
    FCode.OpB(opLoad, VT_LINT);
  end;
  FCode.Op(opAddI);
  FCode.Op(opDup);
  FCode.OpB(opWrap, VTp);
  FCode.Op(opEqI);
  FCode.Jump(opJz, LEnd);
  EmitAddr(S.VarRef);
  EmitValue(S.VarRef, nil);
  if StepConst then FCode.OpQ(opPushI, StepVal)
  else
  begin
    FCode.OpU(opAddrLocal, TmpStep);
    FCode.OpB(opLoad, VT_LINT);
  end;
  FCode.Op(opAddI);
  FCode.OpB(opStore, VTp);
  FCode.Op(opDrop);
  FCode.Jump(opJmp, LTop);
  FCode.SetLabel(LEnd);
end;

procedure TSclCompiler.EmitStmt(S: TStmt);
var
  T: TSclType;
  K, LTop, LEnd: Integer;
  C: TCall;
begin
  if S = nil then Exit;
  if not (S is TRegionStmt) and not (S is TIfStmt) and not (S is TForStmt) and not (S is TCaseStmt) then
    EmitLine(S.Pos);
  if S is TAssign then
    EmitAssign(TAssign(S))
  else if S is TCallStmt then
  begin
    C := TCallStmt(S).Call;
    T := InferType(C);
    if (C.RefKind = 100) or (T <> nil) then
      if FDiags.ErrorCount = 0 then
        EmitCall(C, False);
    if (T <> nil) and (T.Kind <> tkVoid) and (C.RefKind <> 100) then
      FCode.Op(opNop);
  end
  else if S is TIfStmt then
    EmitIf(TIfStmt(S))
  else if S is TCaseStmt then
    EmitCase(TCaseStmt(S))
  else if S is TForStmt then
    EmitFor(TForStmt(S))
  else if S is TWhileStmt then
  begin
    T := InferType(TWhileStmt(S).Cond);
    if (T <> nil) and (T.Kind <> tkBool) then Err(TWhileStmt(S).Cond.Pos, 'Condition must be of type Bool');
    LTop := FCode.NewLabel;
    LEnd := FCode.NewLabel;
    FCode.SetLabel(LTop);
    EmitValue(TWhileStmt(S).Cond, nil);
    FCode.Jump(opJz, LEnd);
    K := Length(FLoops);
    SetLength(FLoops, K + 1);
    FLoops[K].BreakL := LEnd;
    FLoops[K].ContL := LTop;
    EmitStmts(TWhileStmt(S).Body);
    SetLength(FLoops, K);
    FCode.Jump(opJmp, LTop);
    FCode.SetLabel(LEnd);
  end
  else if S is TRepeatStmt then
  begin
    LTop := FCode.NewLabel;
    LEnd := FCode.NewLabel;
    K := FCode.NewLabel;
    FCode.SetLabel(LTop);
    SetLength(FLoops, Length(FLoops) + 1);
    FLoops[High(FLoops)].BreakL := LEnd;
    FLoops[High(FLoops)].ContL := K;
    EmitStmts(TRepeatStmt(S).Body);
    SetLength(FLoops, Length(FLoops) - 1);
    FCode.SetLabel(K);
    T := InferType(TRepeatStmt(S).Cond);
    if (T <> nil) and (T.Kind <> tkBool) then Err(TRepeatStmt(S).Cond.Pos, 'Condition must be of type Bool');
    EmitValue(TRepeatStmt(S).Cond, nil);
    FCode.Jump(opJz, LTop);
    FCode.SetLabel(LEnd);
  end
  else if S is TExitStmt then
  begin
    if Length(FLoops) = 0 then Err(S.Pos, 'EXIT outside of a loop')
    else FCode.Jump(opJmp, FLoops[High(FLoops)].BreakL);
  end
  else if S is TContinueStmt then
  begin
    if Length(FLoops) = 0 then Err(S.Pos, 'CONTINUE outside of a loop')
    else FCode.Jump(opJmp, FLoops[High(FLoops)].ContL);
  end
  else if S is TReturnStmt then
    FCode.Jump(opJmp, FRetLabel)
  else if S is TRegionStmt then
    EmitStmts(TRegionStmt(S).Body);
end;

procedure TSclCompiler.GenerateBlock(B: TBlockInfo);
var
  LInit, LBody, I: Integer;
  E0: Integer;
begin
  FCur := B;
  FCode := TCodeBuf.Create;
  FSvb := TSvBlock(FImage.Blocks[B.CodeIndex]);
  SetLength(FLoops, 0);
  E0 := FDiags.ErrorCount;
  try
    LInit := FCode.NewLabel;
    LBody := FCode.NewLabel;
    FRetLabel := FCode.NewLabel;
    FCode.Jump(opJmp, LInit);
    FCode.SetLabel(LBody);
    EmitStmts(B.U.Body);
    FCode.SetLabel(FRetLabel);
    FCode.Op(opRet);
    { prologue: string temps need their max length header }
    FCode.SetLabel(LInit);
    for I := 0 to High(B.StringTemps) do
    begin
      FCode.OpU(opAddrLocal, B.StringTemps[I].Ofs);
      FCode.OpQ(opPushI, B.StringTemps[I].MaxLen);
      if B.StringTemps[I].Wide then FCode.OpB(opStore, VT_WORD) else FCode.OpB(opStore, VT_BYTE);
    end;
    FCode.Jump(opJmp, LBody);
    if FDiags.ErrorCount = E0 then
    begin
      FCode.Resolve;
      FSvb.Code := FCode.Bytes;
    end;
    B.CodeSize := FCode.Size;
  finally
    FreeAndNil(FCode);
    FCur := nil;
    FSvb := nil;
  end;
end;

{ ====================================================================== image }

function MemberSectionCode(S: TMemberSection): Byte;
begin
  Result := Ord(S);
end;

procedure TSclCompiler.FlattenVars(T: TSclType; const Prefix: string; Base: Int64; Sec: Byte; Retain: Boolean;
  const Img: TBytes; var Arr: TSvVarArray; Depth: Integer);
var
  I, J, N: Integer;
  M: TMember;
  V: TSvVar;
  ET: TSclType;
  Path: string;
  R: Boolean;

  procedure AddVar(const APath: string; AT: TSclType; AOfs: Int64; ASec: Byte; AFlags: Byte;
    const AInit, ACmt: string);
  var
    K: Integer;
  begin
    V.Path := APath;
    V.TypeText := TypeName(AT);
    V.VmType := VmTypeOf(AT);
    V.Section := ASec;
    V.Flags := AFlags;
    V.BitOff := AOfs;
    V.SizeBits := AT.SizeBits;
    V.InitText := AInit;
    V.Comment := ACmt;
    K := Length(Arr);
    SetLength(Arr, K + 1);
    Arr[K] := V;
  end;

  function InitFromImage(AT: TSclType; AOfs: Int64; M0: TMember): string;
  var
    VV: TVmValue;
    C: TConstValue;
  begin
    Result := '';
    if Length(Img) > 0 then
    begin
      if IsElementaryKind(AT.Kind) then
      begin
        VV := MemReadBits(Img, AOfs, VmTypeOf(AT));
        if IsRealKind(AT.Kind) then C := CReal(VV.F)
        else if AT.Kind = tkBool then C := CBool(VV.I <> 0)
        else C := CInt(VV.I);
        Result := ConstToStr(C, AT.Kind);
      end
      else if IsStringKind(AT.Kind) then
        Result := ConstToStr(CStr(MemReadString(Img, AOfs, AT.Kind = tkWString)), AT.Kind);
    end
    else if (M0 <> nil) and M0.HasInit then
      Result := ConstToStr(M0.Init, AT.Kind);
  end;

  procedure Walk(AT: TSclType; const APath: string; AOfs: Int64; ASec: Byte; ARet: Boolean; M0: TMember; ADepth: Integer);
  var
    F: Byte;
    K, Cnt: Integer;
    Elem: TSclType;
    Cm: string;
  begin
    F := 0;
    if ARet then F := F or VF_RETAIN;
    if (M0 <> nil) and M0.ByRef then F := F or VF_BYREF;
    if (M0 <> nil) and M0.Hidden then F := F or VF_HIDDEN;
    if AT.Kind = tkArray then F := F or VF_ARRAY;
    if AT.Kind in [tkStruct, tkFBInst, tkSysFB] then F := F or VF_STRUCT;
    if M0 <> nil then Cm := M0.Comment else Cm := '';
    AddVar(APath, AT, AOfs, ASec, F, InitFromImage(AT, AOfs, M0), Cm);
    if (M0 <> nil) and M0.ByRef then Exit;
    if ADepth > 12 then Exit;
    if AT.Kind = tkArray then
    begin
      Cnt := AT.ElemCount;
      Elem := AT.ElemType;
      if Cnt <= 256 then
        for K := 0 to Cnt - 1 do
          Walk(Elem, Format('%s[%d]', [APath, AT.Lo + K]), AOfs + K * AT.ElemStrideBits, ASec, ARet, nil, ADepth + 1);
    end
    else if AT.Kind in [tkStruct, tkFBInst, tkSysFB] then
      FlattenVars(AT, APath, AOfs, ASec, ARet, Img, Arr, ADepth + 1);
  end;

begin
  if T = nil then Exit;
  for I := 0 to T.MemberCount - 1 do
  begin
    M := T.Member(I);
    if M.Hidden then Continue;
    if Prefix = '' then Path := M.Name else Path := Prefix + '.' + M.Name;
    if (Sec = 0) or (Depth = 0) then N := MemberSectionCode(M.Section) else N := Sec;
    R := Retain or (M.Retain = rmRetain);
    Walk(M.Typ, Path, Base + M.OffsetBits, N, R, M, Depth);
  end;
  ET := nil;
  J := 0;
  if (ET = nil) and (J = 0) then;
end;

procedure TSclCompiler.BuildImage;
var
  I, J: Integer;
  B: TBlockInfo;
  SB: TSvBlock;
  SD: TSvDataBlock;
  TI: TTagInfo;
  ST: TSvTag;
  Arr: TSvVarArray;
  K: Integer;
begin
  FImage.Cpu := Ord(FCpu);
  FImage.ProjectName := FProject.Name;
  FImage.Meta.Clear;
  FImage.Meta.Add('Compiler=SCL Compiler ' + COMPILER_VERSION);
  FImage.Meta.Add('CPU=' + CpuNames[FCpu]);
  FImage.Meta.Add('Created=' + FormatDateTime('yyyy-mm-dd hh:nn:ss', Now));
  for I := 0 to FBlocks.Count - 1 do
  begin
    B := GetBlock(I);
    if B.CodeIndex < 0 then Continue;
    SB := FImage.Block(B.CodeIndex);
    if B.Kind = ukFC then
      SB.ParamBytes := AlignUpI((B.ParamType.SizeBits + 7) div 8, 2)
    else
      SB.ParamBytes := 0;
    SB.TempBytes := AlignUpI((B.TempBits + 7) div 8, 2);
    if B.Kind = ukFB then SB.InstanceBytes := AlignUpI((B.DataType.SizeBits + 7) div 8, 2);
    { interface table }
    SetLength(Arr, 0);
    if B.Kind = ukFB then FlattenVars(B.DataType, '', 0, 0, False, nil, Arr, 0)
    else if B.ParamType <> nil then FlattenVars(B.ParamType, '', 0, 0, False, nil, Arr, 0);
    if B.TempType <> nil then
    begin
      K := Length(Arr);
      FlattenVars(B.TempType, '', B.TempBase, 0, False, nil, Arr, 0);
      for J := K to High(Arr) do
        if Arr[J].Section = Ord(msInput) then Arr[J].Section := Ord(msTemp);
    end;
    SB.Vars := Arr;
  end;
  for I := 0 to FBlocks.Count - 1 do
  begin
    B := GetBlock(I);
    if (B.Kind <> ukDB) or (B.DataType = nil) then Continue;
    SD := TSvDataBlock.Create;
    FImage.DataBlocks.Add(SD);
    SD.Number := B.Number;
    SD.Name := B.Name;
    SD.Flags := 0;
    if B.Optimized then SD.Flags := SD.Flags or BF_OPTIMIZED;
    if B.DBInstOf <> nil then
    begin
      SD.Flags := SD.Flags or BF_INSTANCE;
      SD.InstanceOf := B.DBInstOf.Name;
    end
    else if B.U.DBTypeName <> '' then
      SD.InstanceOf := B.U.DBTypeName;
    SD.Data := Copy(B.Image);
    SD.RetainMap := Copy(B.RetainMap);
    if (Length(B.RetainMap) > 0) and (B.RetainMap[0] <> 0) then SD.Flags := SD.Flags or BF_RETAIN;
    SetLength(Arr, 0);
    if B.DataType.Kind in [tkStruct, tkFBInst, tkSysFB] then
      FlattenVars(B.DataType, '', 0, Ord(msStatic), False, B.Image, Arr, 0);
    for J := 0 to High(Arr) do
      if (Arr[J].BitOff div 8 div 8 < Length(B.RetainMap)) and
         (B.RetainMap[Arr[J].BitOff div 8 div 8] and (1 shl ((Arr[J].BitOff div 8) mod 8)) <> 0) then
        Arr[J].Flags := Arr[J].Flags or VF_RETAIN;
    SD.Vars := Arr;
  end;
  SetLength(FImage.Tags, 0);
  for I := 0 to FTags.Count - 1 do
  begin
    TI := GetTagInfo(I);
    if TI.IsConst then Continue;
    ST.Name := TI.Name;
    ST.TypeText := TypeName(TI.Typ);
    ST.Area := AddrArea(TI.Addr);
    ST.VmType := VmTypeOf(TI.Typ);
    ST.BitOff := AddrBit(TI.Addr);
    ST.Comment := TI.Tag.Comment;
    FImage.AddTag(ST);
  end;
  FImage.ConstPool := Copy(FPool);
end;

function TSclCompiler.Compile(DoCodeGen: Boolean): Boolean;
var
  I: Integer;
  B: TBlockInfo;
  SB: TSvBlock;
begin
  Reset;
  FCpu := FProject.Cpu;
  ParseSources;
  RegisterBlocks;
  AssignNumbers;
  RegisterTags;
  for I := 0 to FBlocks.Count - 1 do ResolveBlock(GetBlock(I));
  for I := 0 to FBlocks.Count - 1 do
  begin
    B := GetBlock(I);
    if B.Kind = ukDB then
    begin
      FCur := B;
      BuildDBImage(B);
      FCur := nil;
    end;
  end;
  { code block table: OBs first, then FBs and FCs }
  for I := 0 to FBlocks.Count - 1 do
  begin
    B := GetBlock(I);
    if not (B.Kind in [ukOB, ukFB, ukFC]) then Continue;
    SB := TSvBlock.Create;
    case B.Kind of
      ukOB: SB.Kind := BK_OB;
      ukFB: SB.Kind := BK_FB;
    else
      SB.Kind := BK_FC;
    end;
    SB.Number := B.Number;
    SB.Name := B.Name;
    SB.SourceFile := ExtractFileName(B.U.FileName);
    if B.Optimized then SB.Flags := BF_OPTIMIZED;
    SB.EventClass := B.EventClass;
    SB.Interval := B.Interval;
    B.CodeIndex := FImage.Blocks.Add(SB);
  end;
  if DoCodeGen then
  begin
    for I := 0 to FBlocks.Count - 1 do
    begin
      B := GetBlock(I);
      if B.CodeIndex >= 0 then GenerateBlock(B);
    end;
  end
  else
  begin
    { type check only }
    for I := 0 to FBlocks.Count - 1 do
    begin
      B := GetBlock(I);
      if B.CodeIndex >= 0 then GenerateBlock(B);
    end;
  end;
  if FImage.Blocks.Count > 0 then
  begin
    I := 0;
    while (I < FBlocks.Count) and not ((GetBlock(I).Kind = ukOB) and (GetBlock(I).EventClass = 1)) do Inc(I);
    if I >= FBlocks.Count then
      FDiags.Warning(NoPos, 'The program has no program cycle OB (OB1)');
  end;
  BuildImage;
  Result := FDiags.ErrorCount = 0;
end;

function TSclCompiler.SaveImage(const FN: string): Boolean;
begin
  Result := False;
  if FDiags.ErrorCount > 0 then Exit;
  ForceDirectories(ExtractFileDir(FN));
  FImage.SaveToFile(FN);
  Result := True;
end;

function SectionText(S: Byte): string;
begin
  if S <= Ord(High(TMemberSection)) then Result := SectionNames[TMemberSection(S)] else Result := '';
end;

function VarsText(const V: TSvVarArray; IsDB: Boolean; DBNum: Integer; Std: Boolean): string;
var
  I: Integer;
  SB: TStringBuilder;
  Adr: string;
begin
  SB := TStringBuilder.Create;
  try
    for I := 0 to High(V) do
    begin
      if IsDB and Std then
      begin
        if V[I].VmType = VT_BOOL then Adr := Format('DBX%d.%d', [V[I].BitOff div 8, V[I].BitOff mod 8])
        else if VmTypeBytes(V[I].VmType) = 2 then Adr := Format('DBW%d', [V[I].BitOff div 8])
        else if (VmTypeBytes(V[I].VmType) = 4) and (V[I].VmType <> 0) then Adr := Format('DBD%d', [V[I].BitOff div 8])
        else Adr := Format('DBB%d', [V[I].BitOff div 8]);
      end
      else
        Adr := Format('%d.%d', [V[I].BitOff div 8, V[I].BitOff mod 8]);
      SB.Append(Format('    %-10s %-8s %-40s %-26s %s', [Adr, SectionText(V[I].Section), V[I].Path,
        V[I].TypeText, V[I].InitText]));
      if V[I].Flags and VF_RETAIN <> 0 then SB.Append('  [retain]');
      if V[I].Flags and VF_BYREF <> 0 then SB.Append('  [pointer]');
      SB.Append(LineEnding);
    end;
    Result := SB.ToString;
  finally
    SB.Free;
  end;
  if DBNum = 0 then;
end;

function TSclCompiler.MemoryMapText: string;
var
  I: Integer;
  SB: TStringBuilder;
  D: TSvDataBlock;
  B: TSvBlock;
  T: TSvTag;
begin
  SB := TStringBuilder.Create;
  try
    SB.Append('PLC tags').Append(LineEnding);
    for I := 0 to High(FImage.Tags) do
    begin
      T := FImage.Tags[I];
      SB.Append(Format('    %-14s %-24s %-8s %s', [AddrToText(MakeAddr(T.Area, 0, T.BitOff)), T.Name, T.TypeText, T.Comment]));
      SB.Append(LineEnding);
    end;
    for I := 0 to FImage.DataBlocks.Count - 1 do
    begin
      D := FImage.DataBlock(I);
      SB.Append(LineEnding).Append(Format('DB%d "%s"  %d bytes', [D.Number, D.Name, Length(D.Data)]));
      if D.InstanceOf <> '' then SB.Append('  instance of "' + D.InstanceOf + '"');
      if D.Flags and BF_OPTIMIZED <> 0 then SB.Append('  optimized') else SB.Append('  standard access');
      SB.Append(LineEnding);
      SB.Append(VarsText(D.Vars, True, D.Number, D.Flags and BF_OPTIMIZED = 0));
    end;
    for I := 0 to FImage.Blocks.Count - 1 do
    begin
      B := FImage.Block(I);
      SB.Append(LineEnding);
      case B.Kind of
        BK_OB: SB.Append(Format('OB%d "%s"  event class %d', [B.Number, B.Name, B.EventClass]));
        BK_FB: SB.Append(Format('FB%d "%s"  instance %d bytes', [B.Number, B.Name, B.InstanceBytes]));
      else
        SB.Append(Format('FC%d "%s"  parameters %d bytes', [B.Number, B.Name, B.ParamBytes]));
      end;
      SB.Append(Format('  temp %d bytes  code %d bytes', [B.TempBytes, Length(B.Code)])).Append(LineEnding);
      SB.Append(VarsText(B.Vars, False, 0, False));
    end;
    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

function TSclCompiler.ListingText: string;
var
  I, J: Integer;
  SB: TStringBuilder;
  B: TSvBlock;
begin
  SB := TStringBuilder.Create;
  try
    SB.Append('; SCL Compiler ' + COMPILER_VERSION + ' listing - project ' + FProject.Name + ' - ' + CpuNames[FCpu]).Append(LineEnding);
    for I := 0 to FImage.Blocks.Count - 1 do
    begin
      B := FImage.Block(I);
      SB.Append(LineEnding).Append(Format('; ===== [%d] %s%d "%s" (%s) =====',
        [I, Copy('??OBFCFB', B.Kind * 2 + 1, 2), B.Number, B.Name, B.SourceFile])).Append(LineEnding);
      SB.Append('; line table: ');
      for J := 0 to High(B.Lines) do SB.Append(Format('%d@%d ', [B.Lines[J].Line, B.Lines[J].CodeOffset]));
      SB.Append(LineEnding);
      SB.Append(Disassemble(B.Code, FImage));
    end;
    SB.Append(LineEnding).Append('; ===== memory map =====').Append(LineEnding);
    SB.Append(MemoryMapText);
    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

end.
