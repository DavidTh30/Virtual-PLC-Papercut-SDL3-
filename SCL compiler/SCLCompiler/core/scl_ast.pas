{ SCL Compiler - abstract syntax tree }
unit scl_ast;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, contnrs, scl_base, scl_types;

type
  TNode = class
  public
    Pos: TSrcPos;
  end;

  TExpr = class;
  TTypeSpec = class;

  { ---------------- declarations ---------------- }

  TArrayDim = class
  public
    Lo, Hi: TExpr;
    Star: Boolean;   // Array[*]
    destructor Destroy; override;
  end;

  TTypeSpecKind = (tsNamed, tsArray, tsStruct, tsString);

  TTypeSpec = class(TNode)
  public
    Kind: TTypeSpecKind;
    Name: string;           // tsNamed
    Quoted: Boolean;        // "UDT" / "FB"
    Dims: TObjectList;      // TArrayDim
    Elem: TTypeSpec;
    Members: TObjectList;   // TVarDecl (tsStruct)
    StrLen: TExpr;          // tsString
    Wide: Boolean;
    Resolved: TSclType;
    constructor Create(AKind: TTypeSpecKind);
    destructor Destroy; override;
    function ToText: string;
  end;

  TVarDecl = class(TNode)
  public
    Name: string;
    Spec: TTypeSpec;
    OwnsSpec: Boolean;
    Init: TExpr;            // scalar init or TArrayInit
    OwnsInit: Boolean;
    Comment: string;
    Attrs: string;
    TypeText: string;       // raw source text of the data type
    InitText: string;       // raw source text of the initial value ('' = none)
    destructor Destroy; override;
  end;

  TVarSection = class(TNode)
  public
    Kind: TMemberSection;
    Retain: TRetainMode;
    Vars: TObjectList;      // TVarDecl
    constructor Create;
    destructor Destroy; override;
  end;

  { ---------------- expressions ---------------- }

  TExpr = class(TNode)
  public
    RType: TSclType;        // filled by semantic analysis
    Checked: Boolean;       // type already inferred
    IsConst: Boolean;       // compile time constant
    CVal: TConstValue;
    RefKind: Integer;       // how a name is accessed (see scl_compiler)
    RefOfs: Int64;          // bit offset / absolute address
    RefObj: TObject;        // TMember / TBlockInfo / ...
    ByRef: Boolean;         // storage holds a pointer
  end;

  TLitKind = (lkInt, lkReal, lkBool, lkString, lkTyped);

  TLiteral = class(TExpr)
  public
    LitKind: TLitKind;
    I: Int64;
    F: Double;
    S: string;
    TypeName: string;       // lkTyped: canonical type name
    IsRealTyped: Boolean;
  end;

  TNameScope = (nsPlain, nsLocal, nsGlobal);

  TNameRef = class(TExpr)
  public
    Name: string;
    Scope: TNameScope;
  end;

  TMemberRef = class(TExpr)
  public
    Base: TExpr;
    Member: string;
    Quoted: Boolean;
    destructor Destroy; override;
  end;

  TIndexRef = class(TExpr)
  public
    Base: TExpr;
    Indices: TObjectList;   // TExpr
    constructor Create;
    destructor Destroy; override;
  end;

  TSliceRef = class(TExpr)
  public
    Base: TExpr;
    SliceKind: Char;        // X B W D
    Index: Integer;
    destructor Destroy; override;
  end;

  TAbsAddr = class(TExpr)
  public
    Text: string;           // without %
  end;

  TUnaryOp = (uoNeg, uoPlus, uoNot);

  TUnary = class(TExpr)
  public
    Op: TUnaryOp;
    Operand: TExpr;
    destructor Destroy; override;
  end;

  TBinOp = (boOr, boXor, boAnd, boEq, boNe, boLt, boLe, boGt, boGe,
    boAdd, boSub, boMul, boDiv, boMod, boPow);

  TBinary = class(TExpr)
  public
    Op: TBinOp;
    L, R: TExpr;
    destructor Destroy; override;
  end;

  TCallArg = class(TNode)
  public
    Name: string;           // '' = positional
    Value: TExpr;
    IsOut: Boolean;         // =>
    destructor Destroy; override;
  end;

  TCall = class(TExpr)
  public
    Callee: TExpr;          // TNameRef / TMemberRef
    Args: TObjectList;      // TCallArg
    constructor Create;
    destructor Destroy; override;
    function Arg(I: Integer): TCallArg;
  end;

  TArrayInit = class(TExpr)
  public
    Items: TObjectList;     // TExpr
    Repeats: array of Integer;
    constructor Create;
    destructor Destroy; override;
  end;

  { ---------------- statements ---------------- }

  TStmt = class(TNode)
  end;

  TStmtList = class(TObjectList)
  public
    function Stmt(I: Integer): TStmt;
  end;

  TAssign = class(TStmt)
  public
    Target: TExpr;
    Value: TExpr;
    destructor Destroy; override;
  end;

  TCallStmt = class(TStmt)
  public
    Call: TCall;
    destructor Destroy; override;
  end;

  TIfStmt = class(TStmt)
  public
    Conds: TObjectList;     // TExpr
    Bodies: TObjectList;    // TStmtList
    ElseBody: TStmtList;
    constructor Create;
    destructor Destroy; override;
  end;

  TCaseLabel = class
  public
    Lo, Hi: TExpr;          // Hi = nil for a single value
    destructor Destroy; override;
  end;

  TCaseItem = class(TNode)
  public
    Labels: TObjectList;    // TCaseLabel
    Body: TStmtList;
    constructor Create;
    destructor Destroy; override;
  end;

  TCaseStmt = class(TStmt)
  public
    Selector: TExpr;
    Items: TObjectList;     // TCaseItem
    ElseBody: TStmtList;
    constructor Create;
    destructor Destroy; override;
  end;

  TForStmt = class(TStmt)
  public
    VarRef: TExpr;
    FromE, ToE, ByE: TExpr;
    Body: TStmtList;
    constructor Create;
    destructor Destroy; override;
  end;

  TWhileStmt = class(TStmt)
  public
    Cond: TExpr;
    Body: TStmtList;
    constructor Create;
    destructor Destroy; override;
  end;

  TRepeatStmt = class(TStmt)
  public
    Body: TStmtList;
    Cond: TExpr;
    constructor Create;
    destructor Destroy; override;
  end;

  TExitStmt = class(TStmt) end;
  TContinueStmt = class(TStmt) end;
  TReturnStmt = class(TStmt) end;

  TRegionStmt = class(TStmt)
  public
    Name: string;
    Body: TStmtList;
    constructor Create;
    destructor Destroy; override;
  end;

  { ---------------- program units ---------------- }

  TUnitKind = (ukUDT, ukDB, ukFC, ukFB, ukOB);

  TProgUnit = class(TNode)
  public
    Kind: TUnitKind;
    Name: string;
    Title: string;
    Version: string;
    Author, Family: string;
    Attrs: TStringList;          // pragma key=value
    RetSpec: TTypeSpec;          // FC
    Sections: TObjectList;       // TVarSection (FC/FB/OB, DB with VAR)
    Body: TStmtList;             // code / DB BEGIN assignments
    StructSpec: TTypeSpec;       // UDT / DB with STRUCT
    DBTypeName: string;          // DB as instance of FB/UDT/system FB
    DBTypeQuoted: Boolean;
    Retain: TRetainMode;         // DB RETAIN / NON_RETAIN
    FileName: string;
    StartOffset: Integer;        // first char of the unit
    HeaderEndOffset: Integer;    // after the header (TITLE/VERSION/pragma lines)
    DeclEndOffset: Integer;      // first char of BEGIN / END_TYPE
    EndOffset: Integer;          // char after END_xxx
    EndLine: Integer;
    constructor Create(AKind: TUnitKind);
    destructor Destroy; override;
    function KindText: string;
    function AttrValue(const Key: string): string;
  end;

  TSourceUnitList = class(TObjectList)
  public
    function UnitAt(I: Integer): TProgUnit;
  end;

const
  UnitKindNames: array[TUnitKind] of string = ('UDT', 'DB', 'FC', 'FB', 'OB');
  SectionNames: array[TMemberSection] of string = ('', 'Input', 'Output', 'InOut', 'Static',
    'Temp', 'Return', 'Constant');

implementation

destructor TArrayDim.Destroy;
begin
  Lo.Free;
  Hi.Free;
  inherited;
end;

constructor TTypeSpec.Create(AKind: TTypeSpecKind);
begin
  inherited Create;
  Kind := AKind;
  Dims := TObjectList.Create(True);
  Members := TObjectList.Create(True);
end;

destructor TTypeSpec.Destroy;
begin
  Dims.Free;
  Members.Free;
  Elem.Free;
  StrLen.Free;
  inherited;
end;

function ExprText(E: TExpr): string;
begin
  if E = nil then Exit('');
  if E is TLiteral then
  begin
    if TLiteral(E).LitKind = lkReal then Result := FloatToStr(TLiteral(E).F)
    else Result := IntToStr(TLiteral(E).I);
  end
  else if E is TNameRef then
  begin
    case TNameRef(E).Scope of
      nsLocal: Result := '#' + TNameRef(E).Name;
      nsGlobal: Result := '"' + TNameRef(E).Name + '"';
    else
      Result := TNameRef(E).Name;
    end;
  end
  else if E is TUnary then
    Result := '-' + ExprText(TUnary(E).Operand)
  else
    Result := '?';
end;

function TTypeSpec.ToText: string;
var
  I: Integer;
  D: TArrayDim;
begin
  case Kind of
    tsNamed:
      if Quoted then Result := '"' + Name + '"' else Result := Name;
    tsString:
      begin
        if Wide then Result := 'WString' else Result := 'String';
        if StrLen <> nil then Result := Result + '[' + ExprText(StrLen) + ']';
      end;
    tsArray:
      begin
        Result := 'Array[';
        for I := 0 to Dims.Count - 1 do
        begin
          D := TArrayDim(Dims[I]);
          if I > 0 then Result := Result + ', ';
          if D.Star then Result := Result + '*'
          else Result := Result + ExprText(D.Lo) + '..' + ExprText(D.Hi);
        end;
        Result := Result + '] of ' + Elem.ToText;
      end;
    tsStruct:
      Result := 'Struct';
  end;
end;

destructor TVarDecl.Destroy;
begin
  if OwnsSpec then Spec.Free;
  if OwnsInit then Init.Free;
  inherited;
end;

constructor TVarSection.Create;
begin
  inherited;
  Vars := TObjectList.Create(True);
end;

destructor TVarSection.Destroy;
begin
  Vars.Free;
  inherited;
end;

destructor TMemberRef.Destroy;
begin
  Base.Free;
  inherited;
end;

constructor TIndexRef.Create;
begin
  inherited;
  Indices := TObjectList.Create(True);
end;

destructor TIndexRef.Destroy;
begin
  Base.Free;
  Indices.Free;
  inherited;
end;

destructor TSliceRef.Destroy;
begin
  Base.Free;
  inherited;
end;

destructor TUnary.Destroy;
begin
  Operand.Free;
  inherited;
end;

destructor TBinary.Destroy;
begin
  L.Free;
  R.Free;
  inherited;
end;

destructor TCallArg.Destroy;
begin
  Value.Free;
  inherited;
end;

constructor TCall.Create;
begin
  inherited;
  Args := TObjectList.Create(True);
end;

destructor TCall.Destroy;
begin
  Callee.Free;
  Args.Free;
  inherited;
end;

function TCall.Arg(I: Integer): TCallArg;
begin
  Result := TCallArg(Args[I]);
end;

constructor TArrayInit.Create;
begin
  inherited;
  Items := TObjectList.Create(True);
end;

destructor TArrayInit.Destroy;
begin
  Items.Free;
  inherited;
end;

function TStmtList.Stmt(I: Integer): TStmt;
begin
  Result := TStmt(Items[I]);
end;

destructor TAssign.Destroy;
begin
  Target.Free;
  Value.Free;
  inherited;
end;

destructor TCallStmt.Destroy;
begin
  Call.Free;
  inherited;
end;

constructor TIfStmt.Create;
begin
  inherited;
  Conds := TObjectList.Create(True);
  Bodies := TObjectList.Create(True);
end;

destructor TIfStmt.Destroy;
begin
  Conds.Free;
  Bodies.Free;
  ElseBody.Free;
  inherited;
end;

destructor TCaseLabel.Destroy;
begin
  Lo.Free;
  Hi.Free;
  inherited;
end;

constructor TCaseItem.Create;
begin
  inherited;
  Labels := TObjectList.Create(True);
  Body := TStmtList.Create(True);
end;

destructor TCaseItem.Destroy;
begin
  Labels.Free;
  Body.Free;
  inherited;
end;

constructor TCaseStmt.Create;
begin
  inherited;
  Items := TObjectList.Create(True);
end;

destructor TCaseStmt.Destroy;
begin
  Selector.Free;
  Items.Free;
  ElseBody.Free;
  inherited;
end;

constructor TForStmt.Create;
begin
  inherited;
  Body := TStmtList.Create(True);
end;

destructor TForStmt.Destroy;
begin
  VarRef.Free;
  FromE.Free;
  ToE.Free;
  ByE.Free;
  Body.Free;
  inherited;
end;

constructor TWhileStmt.Create;
begin
  inherited;
  Body := TStmtList.Create(True);
end;

destructor TWhileStmt.Destroy;
begin
  Cond.Free;
  Body.Free;
  inherited;
end;

constructor TRepeatStmt.Create;
begin
  inherited;
  Body := TStmtList.Create(True);
end;

destructor TRepeatStmt.Destroy;
begin
  Cond.Free;
  Body.Free;
  inherited;
end;

constructor TRegionStmt.Create;
begin
  inherited;
  Body := TStmtList.Create(True);
end;

destructor TRegionStmt.Destroy;
begin
  Body.Free;
  inherited;
end;

constructor TProgUnit.Create(AKind: TUnitKind);
begin
  inherited Create;
  Kind := AKind;
  Attrs := TStringList.Create;
  Sections := TObjectList.Create(True);
  Body := TStmtList.Create(True);
end;

destructor TProgUnit.Destroy;
begin
  Attrs.Free;
  RetSpec.Free;
  Sections.Free;
  Body.Free;
  StructSpec.Free;
  inherited;
end;

function TProgUnit.KindText: string;
begin
  Result := UnitKindNames[Kind];
end;

function TProgUnit.AttrValue(const Key: string): string;
var
  I: Integer;
begin
  for I := 0 to Attrs.Count - 1 do
    if CompareText(Attrs.Names[I], Key) = 0 then
      Exit(Attrs.ValueFromIndex[I]);
  Result := '';
end;

function TSourceUnitList.UnitAt(I: Integer): TProgUnit;
begin
  Result := TProgUnit(Items[I]);
end;

end.
