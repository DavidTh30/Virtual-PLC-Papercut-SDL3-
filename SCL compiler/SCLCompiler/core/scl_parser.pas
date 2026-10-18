{ SCL Compiler - recursive descent parser for Siemens SCL external sources }
unit scl_parser;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, contnrs, scl_base, scl_types, scl_lexer, scl_ast;

type
  TSclParser = class
  private
    FToks: TTokenArray;
    FI: Integer;
    FDiags: TDiagList;
    FFile: string;
    FSrc: string;
    function Tok: TToken;
    function PeekTok(N: Integer): TToken;
    procedure Next;
    function IsKw(const K: string): Boolean;
    function IsKwAny(const K: array of string): Boolean;
    function Accept(K: TTokKind): Boolean;
    function AcceptKw(const K: string): Boolean;
    procedure Expect(K: TTokKind);
    procedure ExpectKw(const K: string);
    procedure Fail(const Msg: string); overload;
    procedure Fail(const P: TSrcPos; const Msg: string); overload;
    function TrailingComment(EndOffset: Integer): string;
    function RestOfLine(const T: TToken): string;
    procedure SkipToUnitEnd;
    procedure ParsePragmaInto(const Txt: string; L: TStringList);
    { units }
    function ParseUnit: TProgUnit;
    procedure ParseHeader(U: TProgUnit);
    procedure ParseVarSections(U: TProgUnit);
    function ParseVarSection: TVarSection;
    procedure ParseDecls(L: TObjectList; const EndKw: string);
    function ParseTypeSpec: TTypeSpec;
    function ParseInit: TExpr;
    { statements }
    procedure ParseStatements(L: TStmtList; const Terms: array of string);
    function ParseStatement: TStmt;
    function ParseIf: TStmt;
    function ParseCase: TStmt;
    function ParseFor: TStmt;
    function ParseWhile: TStmt;
    function ParseRepeat: TStmt;
    function ParseRegion: TStmt;
    function IsCaseLabelStart: Boolean;
    procedure SkipSemis;
    { expressions }
    function ParseOr: TExpr;
    function ParseXor: TExpr;
    function ParseAnd: TExpr;
    function ParseEquality: TExpr;
    function ParseRel: TExpr;
    function ParseAdd: TExpr;
    function ParseMul: TExpr;
    function ParsePow: TExpr;
    function ParseUnary: TExpr;
    function ParsePostfix: TExpr;
    function ParsePrimary: TExpr;
    function ParseCallArgs(Callee: TExpr): TCall;
    function MkBin(Op: TBinOp; L, R: TExpr; const P: TSrcPos): TExpr;
  public
    constructor Create(const ASrc, AFile: string; ADiags: TDiagList);
    procedure ParseFile(Units: TSourceUnitList);
    function ParseExpr: TExpr;
  end;

function ParseSclSource(const ASrc, AFile: string; Units: TSourceUnitList; Diags: TDiagList): Boolean;
function ParseSclExpression(const ASrc: string; Diags: TDiagList): TExpr;

implementation

function ParseSclSource(const ASrc, AFile: string; Units: TSourceUnitList; Diags: TDiagList): Boolean;
var
  P: TSclParser;
  E0: Integer;
begin
  E0 := Diags.ErrorCount;
  P := TSclParser.Create(ASrc, AFile, Diags);
  try
    P.ParseFile(Units);
  finally
    P.Free;
  end;
  Result := Diags.ErrorCount = E0;
end;

function ParseSclExpression(const ASrc: string; Diags: TDiagList): TExpr;
var
  P: TSclParser;
begin
  P := TSclParser.Create(ASrc, '', Diags);
  try
    try
      Result := P.ParseExpr;
    except
      on E: ESclError do
      begin
        Diags.Error(E.Pos, E.Message);
        Result := nil;
      end;
    end;
  finally
    P.Free;
  end;
end;

constructor TSclParser.Create(const ASrc, AFile: string; ADiags: TDiagList);
var
  L: TSclLexer;
begin
  inherited Create;
  FDiags := ADiags;
  FFile := AFile;
  FSrc := ASrc;
  L := TSclLexer.Create(ASrc, AFile, ADiags);
  try
    FToks := L.TokenizeAll;
  finally
    L.Free;
  end;
  FI := 0;
end;

function TSclParser.Tok: TToken;
begin
  Result := FToks[FI];
end;

function TSclParser.PeekTok(N: Integer): TToken;
begin
  if FI + N < Length(FToks) then Result := FToks[FI + N]
  else Result := FToks[High(FToks)];
end;

procedure TSclParser.Next;
begin
  if FI < High(FToks) then Inc(FI);
end;

function TSclParser.IsKw(const K: string): Boolean;
begin
  Result := (FToks[FI].Kind = tkIdent) and (FToks[FI].Up = K);
end;

function TSclParser.IsKwAny(const K: array of string): Boolean;
var
  I: Integer;
begin
  if FToks[FI].Kind <> tkIdent then Exit(False);
  for I := Low(K) to High(K) do
    if FToks[FI].Up = K[I] then Exit(True);
  Result := False;
end;

function TSclParser.Accept(K: TTokKind): Boolean;
begin
  Result := Tok.Kind = K;
  if Result then Next;
end;

function TSclParser.AcceptKw(const K: string): Boolean;
begin
  Result := IsKw(K);
  if Result then Next;
end;

procedure TSclParser.Fail(const Msg: string);
begin
  raise ESclError.CreatePos(Tok.Pos, Msg);
end;

procedure TSclParser.Fail(const P: TSrcPos; const Msg: string);
begin
  raise ESclError.CreatePos(P, Msg);
end;

function TokDesc(const T: TToken): string;
begin
  case T.Kind of
    tkIdent, tkLocal, tkGlobal, tkAddress, tkIntLit, tkRealLit, tkTypedLit:
      Result := '''' + T.Text + '''';
  else
    Result := TokKindText(T.Kind);
  end;
end;

procedure TSclParser.Expect(K: TTokKind);
begin
  if Tok.Kind <> K then
    Fail(Format('''%s'' expected but %s found', [TokKindText(K), TokDesc(Tok)]));
  Next;
end;

procedure TSclParser.ExpectKw(const K: string);
begin
  if not IsKw(K) then
    Fail(Format('%s expected but %s found', [K, TokDesc(Tok)]));
  Next;
end;

function TSclParser.TrailingComment(EndOffset: Integer): string;
var
  P, E: Integer;
begin
  Result := '';
  P := EndOffset;
  E := P;
  while (E <= Length(FSrc)) and not (FSrc[E] in [#10, #13]) do Inc(E);
  P := Pos('//', Copy(FSrc, EndOffset, E - EndOffset));
  if P > 0 then
    Result := Trim(Copy(FSrc, EndOffset + P + 1, E - EndOffset - P - 1));
end;

function TSclParser.RestOfLine(const T: TToken): string;
var
  E: Integer;
begin
  E := T.Pos.Offset;
  while (E <= Length(FSrc)) and not (FSrc[E] in [#10, #13]) do Inc(E);
  Result := Trim(Copy(FSrc, T.Pos.Offset, E - T.Pos.Offset));
end;

procedure TSclParser.SkipToUnitEnd;
begin
  while Tok.Kind <> tkEOF do
  begin
    if IsKwAny(['END_TYPE', 'END_DATA_BLOCK', 'END_FUNCTION', 'END_FUNCTION_BLOCK',
      'END_ORGANIZATION_BLOCK']) then
    begin
      Next;
      Exit;
    end;
    Next;
  end;
end;

procedure TSclParser.ParsePragmaInto(const Txt: string; L: TStringList);
var
  Parts: TStringArray;
  S, K, V: string;
  P: Integer;
begin
  Parts := Txt.Split([';']);
  for S in Parts do
  begin
    P := Pos(':=', S);
    if P = 0 then Continue;
    K := Trim(Copy(S, 1, P - 1));
    V := Trim(Copy(S, P + 2, MaxInt));
    if (Length(V) >= 2) and (V[1] = '''') and (V[Length(V)] = '''') then
      V := Copy(V, 2, Length(V) - 2);
    L.Values[K] := V;
  end;
end;

{ ------------------------------------------------------------------ units }

procedure TSclParser.ParseFile(Units: TSourceUnitList);
var
  U: TProgUnit;
  Start: Integer;
begin
  while Tok.Kind <> tkEOF do
  begin
    Start := FI;
    try
      U := ParseUnit;
      if U <> nil then Units.Add(U);
    except
      on E: ESclError do
      begin
        FDiags.Error(E.Pos, E.Message);
        if FI = Start then Next;
        SkipToUnitEnd;
      end;
    end;
  end;
end;

function TSclParser.ParseUnit: TProgUnit;
var
  StartTok: TToken;
  U: TProgUnit;
  EndKw: string;
  Sp: TTypeSpec;
begin
  StartTok := Tok;
  if IsKw('TYPE') then begin U := TProgUnit.Create(ukUDT); EndKw := 'END_TYPE'; end
  else if IsKw('DATA_BLOCK') then begin U := TProgUnit.Create(ukDB); EndKw := 'END_DATA_BLOCK'; end
  else if IsKw('FUNCTION') then begin U := TProgUnit.Create(ukFC); EndKw := 'END_FUNCTION'; end
  else if IsKw('FUNCTION_BLOCK') then begin U := TProgUnit.Create(ukFB); EndKw := 'END_FUNCTION_BLOCK'; end
  else if IsKw('ORGANIZATION_BLOCK') then begin U := TProgUnit.Create(ukOB); EndKw := 'END_ORGANIZATION_BLOCK'; end
  else
  begin
    Fail('TYPE, DATA_BLOCK, FUNCTION, FUNCTION_BLOCK or ORGANIZATION_BLOCK expected but ' + TokDesc(Tok) + ' found');
    Exit(nil);
  end;
  try
    U.Pos := StartTok.Pos;
    U.FileName := FFile;
    U.StartOffset := StartTok.Pos.Offset;
    Next;
    { name }
    if Tok.Kind in [tkGlobal, tkIdent] then
    begin
      U.Name := Tok.Text;
      Next;
    end
    else
      Fail('Block name expected');

    if U.Kind = ukUDT then
    begin
      ParseHeader(U);
      Accept(tkColon);
      U.HeaderEndOffset := Tok.Pos.Offset;
      if IsKw('STRUCT') then
        U.StructSpec := ParseTypeSpec
      else
        Fail('STRUCT expected');
      SkipSemis;
      U.DeclEndOffset := Tok.Pos.Offset;
      ExpectKw(EndKw);
    end
    else if U.Kind = ukDB then
    begin
      ParseHeader(U);
      U.HeaderEndOffset := Tok.Pos.Offset;
      if IsKw('STRUCT') then
      begin
        U.StructSpec := ParseTypeSpec;
        SkipSemis;
      end
      else if IsKwAny(['VAR', 'VAR_STAT']) then
        ParseVarSections(U)
      else if Tok.Kind in [tkGlobal, tkIdent] then
      begin
        U.DBTypeName := Tok.Text;
        U.DBTypeQuoted := Tok.Kind = tkGlobal;
        Next;
        SkipSemis;
      end
      else
        Fail('STRUCT, VAR or instance type expected');
      U.DeclEndOffset := Tok.Pos.Offset;
      if AcceptKw('BEGIN') then
        ParseStatements(U.Body, [EndKw]);
      ExpectKw(EndKw);
    end
    else
    begin
      if U.Kind = ukFC then
      begin
        if Accept(tkColon) then
        begin
          Sp := ParseTypeSpec;
          U.RetSpec := Sp;
        end;
      end;
      ParseHeader(U);
      U.HeaderEndOffset := Tok.Pos.Offset;
      ParseVarSections(U);
      U.DeclEndOffset := Tok.Pos.Offset;
      ExpectKw('BEGIN');
      ParseStatements(U.Body, [EndKw]);
      ExpectKw(EndKw);
    end;
    U.EndOffset := FToks[FI - 1].EndOffset;
    U.EndLine := FToks[FI - 1].Pos.Line;
    Result := U;
  except
    U.Free;
    raise;
  end;
end;

procedure TSclParser.ParseHeader(U: TProgUnit);
var
  T: TToken;
begin
  while True do
  begin
    T := Tok;
    if T.Kind = tkPragma then
    begin
      ParsePragmaInto(T.Text, U.Attrs);
      Next;
    end
    else if IsKw('TITLE') then
    begin
      Next;
      Expect(tkEq);
      if Tok.Kind = tkStringLit then
      begin
        U.Title := Tok.S;
        Next;
      end
      else
      begin
        U.Title := RestOfLine(Tok);
        T := Tok;
        while (Tok.Kind <> tkEOF) and (Tok.Pos.Line = T.Pos.Line) do Next;
      end;
    end
    else if IsKwAny(['VERSION', 'AUTHOR', 'FAMILY', 'NAME']) then
    begin
      T := Tok;
      Next;
      Expect(tkColon);
      if T.Up = 'VERSION' then U.Version := Tok.Text
      else if T.Up = 'AUTHOR' then U.Author := Tok.Text
      else if T.Up = 'FAMILY' then U.Family := Tok.Text;
      if Tok.Kind = tkStringLit then
      begin
        if T.Up = 'AUTHOR' then U.Author := Tok.S else if T.Up = 'FAMILY' then U.Family := Tok.S;
      end;
      Next;
    end
    else if IsKw('NON_RETAIN') then
    begin
      U.Retain := rmNonRetain;
      Next;
    end
    else if IsKw('RETAIN') then
    begin
      U.Retain := rmRetain;
      Next;
    end
    else if IsKwAny(['KNOW_HOW_PROTECT', 'UNLINKED', 'READ_ONLY', 'CODE_VERSION1', 'S7_SPECIFIC']) then
      Next
    else
      Break;
  end;
end;

procedure TSclParser.ParseVarSections(U: TProgUnit);
begin
  while IsKwAny(['VAR', 'VAR_INPUT', 'VAR_OUTPUT', 'VAR_IN_OUT', 'VAR_TEMP', 'VAR_STAT']) do
    U.Sections.Add(ParseVarSection);
end;

function TSclParser.ParseVarSection: TVarSection;
var
  S: TVarSection;
  Up: string;
begin
  S := TVarSection.Create;
  try
    S.Pos := Tok.Pos;
    Up := Tok.Up;
    Next;
    if Up = 'VAR_INPUT' then S.Kind := msInput
    else if Up = 'VAR_OUTPUT' then S.Kind := msOutput
    else if Up = 'VAR_IN_OUT' then S.Kind := msInOut
    else if Up = 'VAR_TEMP' then S.Kind := msTemp
    else S.Kind := msStatic;
    while True do
    begin
      if AcceptKw('CONSTANT') then S.Kind := msConstant
      else if AcceptKw('RETAIN') then S.Retain := rmRetain
      else if AcceptKw('NON_RETAIN') then S.Retain := rmNonRetain
      else if AcceptKw('DB_SPECIFIC') then
      else Break;
    end;
    ParseDecls(S.Vars, 'END_VAR');
    ExpectKw('END_VAR');
    Accept(tkSemi);
    Result := S;
  except
    S.Free;
    raise;
  end;
end;

procedure TSclParser.ParseDecls(L: TObjectList; const EndKw: string);
var
  Names: TStringList;
  Poses: array of TSrcPos;
  Attrs: string;
  Spec: TTypeSpec;
  Init: TExpr;
  I: Integer;
  D: TVarDecl;
  LastEnd: Integer;
  Cmt, TTxt, ITxt: string;
  TStart: Integer;
begin
  Names := TStringList.Create;
  try
    while not IsKw(EndKw) do
    begin
      if Tok.Kind = tkEOF then Fail(EndKw + ' expected');
      if Tok.Kind = tkSemi then begin Next; Continue; end;
      Names.Clear;
      SetLength(Poses, 0);
      Attrs := '';
      repeat
        if not (Tok.Kind in [tkIdent, tkGlobal]) then
          Fail('Variable name expected but ' + TokDesc(Tok) + ' found');
        Names.Add(Tok.Text);
        SetLength(Poses, Length(Poses) + 1);
        Poses[High(Poses)] := Tok.Pos;
        Next;
        while Tok.Kind = tkPragma do
        begin
          Attrs := Attrs + Tok.Text;
          Next;
        end;
        if IsKw('AT') then Fail('AT (overlay) declarations are not supported');
      until not Accept(tkComma);
      Expect(tkColon);
      TStart := Tok.Pos.Offset;
      Spec := ParseTypeSpec;
      TTxt := Trim(Copy(FSrc, TStart, FToks[FI - 1].EndOffset - TStart));
      while Tok.Kind = tkPragma do
      begin
        Attrs := Attrs + Tok.Text;
        Next;
      end;
      Init := nil;
      ITxt := '';
      if Accept(tkAssign) then
      begin
        TStart := Tok.Pos.Offset;
        Init := ParseInit;
        ITxt := Trim(Copy(FSrc, TStart, FToks[FI - 1].EndOffset - TStart));
      end;
      LastEnd := Tok.EndOffset;
      Expect(tkSemi);
      Cmt := TrailingComment(LastEnd);
      for I := 0 to Names.Count - 1 do
      begin
        D := TVarDecl.Create;
        D.Pos := Poses[I];
        D.Name := Names[I];
        D.Spec := Spec;
        D.OwnsSpec := I = 0;
        D.Init := Init;
        D.OwnsInit := I = 0;
        D.Comment := Cmt;
        D.Attrs := Attrs;
        D.TypeText := TTxt;
        D.InitText := ITxt;
        L.Add(D);
      end;
    end;
  finally
    Names.Free;
  end;
end;

function TSclParser.ParseInit: TExpr;
var
  A: TArrayInit;
  N: Integer;
begin
  if Tok.Kind = tkLBrack then
  begin
    A := TArrayInit.Create;
    try
      A.Pos := Tok.Pos;
      Next;
      if Tok.Kind <> tkRBrack then
        repeat
          N := 1;
          if (Tok.Kind = tkIntLit) and (PeekTok(1).Kind = tkLParen) then
          begin
            N := Tok.I;
            Next;
            Next;
            A.Items.Add(ParseExpr);
            Expect(tkRParen);
          end
          else
            A.Items.Add(ParseExpr);
          SetLength(A.Repeats, A.Items.Count);
          A.Repeats[A.Items.Count - 1] := N;
        until not Accept(tkComma);
      Expect(tkRBrack);
      Result := A;
    except
      A.Free;
      raise;
    end;
  end
  else
    Result := ParseExpr;
end;

function TSclParser.ParseTypeSpec: TTypeSpec;
var
  S: TTypeSpec;
  D: TArrayDim;
begin
  S := nil;
  try
    if IsKw('ARRAY') then
    begin
      S := TTypeSpec.Create(tsArray);
      S.Pos := Tok.Pos;
      Next;
      Expect(tkLBrack);
      repeat
        D := TArrayDim.Create;
        S.Dims.Add(D);
        if Accept(tkStar) then
          D.Star := True
        else
        begin
          D.Lo := ParseAdd;
          Expect(tkDotDot);
          D.Hi := ParseAdd;
        end;
      until not Accept(tkComma);
      Expect(tkRBrack);
      ExpectKw('OF');
      S.Elem := ParseTypeSpec();
    end
    else if IsKw('STRUCT') then
    begin
      S := TTypeSpec.Create(tsStruct);
      S.Pos := Tok.Pos;
      Next;
      ParseDecls(S.Members, 'END_STRUCT');
      ExpectKw('END_STRUCT');
    end
    else if IsKwAny(['STRING', 'WSTRING']) then
    begin
      S := TTypeSpec.Create(tsString);
      S.Pos := Tok.Pos;
      S.Wide := Tok.Up = 'WSTRING';
      Next;
      if Accept(tkLBrack) then
      begin
        S.StrLen := ParseAdd;
        Expect(tkRBrack);
      end;
    end
    else if Tok.Kind in [tkIdent, tkGlobal] then
    begin
      S := TTypeSpec.Create(tsNamed);
      S.Pos := Tok.Pos;
      S.Name := Tok.Text;
      S.Quoted := Tok.Kind = tkGlobal;
      Next;
    end
    else
      Fail('Data type expected but ' + TokDesc(Tok) + ' found');
    Result := S;
  except
    S.Free;
    raise;
  end;
end;

{ ------------------------------------------------------------------ statements }

procedure TSclParser.SkipSemis;
begin
  while Tok.Kind = tkSemi do Next;
end;

function IsTerm(const T: TToken; const Terms: array of string): Boolean;
var
  I: Integer;
begin
  if T.Kind = tkEOF then Exit(True);
  if T.Kind <> tkIdent then Exit(False);
  for I := Low(Terms) to High(Terms) do
    if T.Up = Terms[I] then Exit(True);
  Result := False;
end;

procedure TSclParser.ParseStatements(L: TStmtList; const Terms: array of string);
var
  S: TStmt;
  Start: Integer;
begin
  while not IsTerm(Tok, Terms) do
  begin
    Start := FI;
    try
      S := ParseStatement;
      if S <> nil then L.Add(S);
    except
      on E: ESclError do
      begin
        FDiags.Error(E.Pos, E.Message);
        { recover: skip to the next ';' unless we sit on a block terminator }
        if IsKwAny(['END_FUNCTION', 'END_FUNCTION_BLOCK', 'END_ORGANIZATION_BLOCK',
          'END_DATA_BLOCK', 'END_TYPE']) then Exit;
        if (FI = Start) or not IsTerm(Tok, Terms) then
        begin
          while not (Tok.Kind in [tkSemi, tkEOF]) and not IsKwAny(['END_FUNCTION',
            'END_FUNCTION_BLOCK', 'END_ORGANIZATION_BLOCK', 'END_DATA_BLOCK']) do Next;
          Accept(tkSemi);
        end;
      end;
    end;
  end;
end;

function TSclParser.ParseStatement: TStmt;
var
  E, V: TExpr;
  A: TAssign;
  C: TCallStmt;
  P: TSrcPos;
begin
  Result := nil;
  P := Tok.Pos;
  if Tok.Kind = tkSemi then
  begin
    Next;
    Exit(nil);
  end;
  if Tok.Kind = tkIdent then
  begin
    if Tok.Up = 'IF' then Exit(ParseIf);
    if Tok.Up = 'CASE' then Exit(ParseCase);
    if Tok.Up = 'FOR' then Exit(ParseFor);
    if Tok.Up = 'WHILE' then Exit(ParseWhile);
    if Tok.Up = 'REPEAT' then Exit(ParseRepeat);
    if Tok.Up = 'REGION' then Exit(ParseRegion);
    if Tok.Up = 'EXIT' then
    begin
      Result := TExitStmt.Create; Result.Pos := P; Next; Accept(tkSemi); Exit;
    end;
    if Tok.Up = 'CONTINUE' then
    begin
      Result := TContinueStmt.Create; Result.Pos := P; Next; Accept(tkSemi); Exit;
    end;
    if Tok.Up = 'RETURN' then
    begin
      Result := TReturnStmt.Create; Result.Pos := P; Next; Accept(tkSemi); Exit;
    end;
    if Tok.Up = 'GOTO' then Fail('GOTO is not supported');
    if (Tok.Up = 'END_IF') or (Tok.Up = 'END_FOR') or (Tok.Up = 'END_WHILE') or
       (Tok.Up = 'END_CASE') or (Tok.Up = 'END_REPEAT') or (Tok.Up = 'END_REGION') or
       (Tok.Up = 'ELSE') or (Tok.Up = 'ELSIF') or (Tok.Up = 'UNTIL') then
      Fail('Unexpected ' + Tok.Text);
  end;
  E := ParsePostfix;
  try
    if Tok.Kind = tkAssign then
    begin
      Next;
      V := ParseExpr;
      A := TAssign.Create;
      A.Pos := P;
      A.Target := E;
      A.Value := V;
      E := nil;
      Result := A;
    end
    else if E is TCall then
    begin
      C := TCallStmt.Create;
      C.Pos := P;
      C.Call := TCall(E);
      E := nil;
      Result := C;
    end
    else
      Fail(''':='' expected but ' + TokDesc(Tok) + ' found');
  finally
    E.Free;
  end;
  if Tok.Kind <> tkSemi then
  begin
    Result.Free;
    Fail(''';'' expected but ' + TokDesc(Tok) + ' found');
  end;
  Next;
end;

function TSclParser.ParseIf: TStmt;
var
  S: TIfStmt;
  L: TStmtList;
begin
  S := TIfStmt.Create;
  try
    S.Pos := Tok.Pos;
    Next;
    S.Conds.Add(ParseExpr);
    ExpectKw('THEN');
    L := TStmtList.Create(True);
    S.Bodies.Add(L);
    ParseStatements(L, ['ELSIF', 'ELSE', 'END_IF']);
    while AcceptKw('ELSIF') do
    begin
      S.Conds.Add(ParseExpr);
      ExpectKw('THEN');
      L := TStmtList.Create(True);
      S.Bodies.Add(L);
      ParseStatements(L, ['ELSIF', 'ELSE', 'END_IF']);
    end;
    if AcceptKw('ELSE') then
    begin
      S.ElseBody := TStmtList.Create(True);
      ParseStatements(S.ElseBody, ['END_IF']);
    end;
    ExpectKw('END_IF');
    Accept(tkSemi);
    Result := S;
  except
    S.Free;
    raise;
  end;
end;

function TSclParser.IsCaseLabelStart: Boolean;
var
  T1: TToken;
begin
  case Tok.Kind of
    tkIntLit, tkTypedLit: Result := True;
    tkMinus: Result := PeekTok(1).Kind in [tkIntLit, tkTypedLit];
    tkIdent, tkLocal, tkGlobal:
      begin
        if (Tok.Kind = tkIdent) and ((Tok.Up = 'ELSE') or (Tok.Up = 'END_CASE')) then Exit(False);
        T1 := PeekTok(1);
        Result := T1.Kind in [tkColon, tkComma, tkDotDot];
      end;
  else
    Result := False;
  end;
end;

function TSclParser.ParseCase: TStmt;
var
  S: TCaseStmt;
  It: TCaseItem;
  Lb: TCaseLabel;
  St: TStmt;
  Start: Integer;
begin
  S := TCaseStmt.Create;
  try
    S.Pos := Tok.Pos;
    Next;
    S.Selector := ParseExpr;
    ExpectKw('OF');
    while not IsKwAny(['ELSE', 'END_CASE']) do
    begin
      if Tok.Kind = tkEOF then Fail('END_CASE expected');
      if not IsCaseLabelStart then Fail('CASE label expected but ' + TokDesc(Tok) + ' found');
      It := TCaseItem.Create;
      S.Items.Add(It);
      It.Pos := Tok.Pos;
      repeat
        Lb := TCaseLabel.Create;
        It.Labels.Add(Lb);
        Lb.Lo := ParseAdd;
        if Accept(tkDotDot) then Lb.Hi := ParseAdd;
      until not Accept(tkComma);
      Expect(tkColon);
      while not IsKwAny(['ELSE', 'END_CASE']) and not IsCaseLabelStart and (Tok.Kind <> tkEOF) do
      begin
        Start := FI;
        try
          St := ParseStatement;
          if St <> nil then It.Body.Add(St);
        except
          on E: ESclError do
          begin
            FDiags.Error(E.Pos, E.Message);
            if FI = Start then Next;
            while not (Tok.Kind in [tkSemi, tkEOF]) do Next;
            Accept(tkSemi);
          end;
        end;
      end;
    end;
    if AcceptKw('ELSE') then
    begin
      Accept(tkColon);
      S.ElseBody := TStmtList.Create(True);
      ParseStatements(S.ElseBody, ['END_CASE']);
    end;
    ExpectKw('END_CASE');
    Accept(tkSemi);
    Result := S;
  except
    S.Free;
    raise;
  end;
end;

function TSclParser.ParseFor: TStmt;
var
  S: TForStmt;
begin
  S := TForStmt.Create;
  try
    S.Pos := Tok.Pos;
    Next;
    S.VarRef := ParsePostfix;
    Expect(tkAssign);
    S.FromE := ParseExpr;
    ExpectKw('TO');
    S.ToE := ParseExpr;
    if AcceptKw('BY') then S.ByE := ParseExpr;
    ExpectKw('DO');
    ParseStatements(S.Body, ['END_FOR']);
    ExpectKw('END_FOR');
    Accept(tkSemi);
    Result := S;
  except
    S.Free;
    raise;
  end;
end;

function TSclParser.ParseWhile: TStmt;
var
  S: TWhileStmt;
begin
  S := TWhileStmt.Create;
  try
    S.Pos := Tok.Pos;
    Next;
    S.Cond := ParseExpr;
    ExpectKw('DO');
    ParseStatements(S.Body, ['END_WHILE']);
    ExpectKw('END_WHILE');
    Accept(tkSemi);
    Result := S;
  except
    S.Free;
    raise;
  end;
end;

function TSclParser.ParseRepeat: TStmt;
var
  S: TRepeatStmt;
begin
  S := TRepeatStmt.Create;
  try
    S.Pos := Tok.Pos;
    Next;
    ParseStatements(S.Body, ['UNTIL']);
    ExpectKw('UNTIL');
    S.Cond := ParseExpr;
    ExpectKw('END_REPEAT');
    Accept(tkSemi);
    Result := S;
  except
    S.Free;
    raise;
  end;
end;

function TSclParser.ParseRegion: TStmt;
var
  S: TRegionStmt;
  Line: Integer;
begin
  S := TRegionStmt.Create;
  try
    S.Pos := Tok.Pos;
    Line := Tok.Pos.Line;
    Next;
    if (Tok.Kind <> tkEOF) and (Tok.Pos.Line = Line) then
      S.Name := RestOfLine(Tok);
    while (Tok.Kind <> tkEOF) and (Tok.Pos.Line = Line) do Next;
    ParseStatements(S.Body, ['END_REGION']);
    ExpectKw('END_REGION');
    Accept(tkSemi);
    Result := S;
  except
    S.Free;
    raise;
  end;
end;

{ ------------------------------------------------------------------ expressions }

function TSclParser.MkBin(Op: TBinOp; L, R: TExpr; const P: TSrcPos): TExpr;
var
  B: TBinary;
begin
  B := TBinary.Create;
  B.Op := Op;
  B.L := L;
  B.R := R;
  B.Pos := P;
  Result := B;
end;

function TSclParser.ParseExpr: TExpr;
begin
  Result := ParseOr;
end;

function TSclParser.ParseOr: TExpr;
var
  P: TSrcPos;
  R: TExpr;
begin
  Result := ParseXor;
  while IsKw('OR') do
  begin
    P := Tok.Pos;
    Next;
    try
      R := ParseXor;
    except
      Result.Free;
      raise;
    end;
    Result := MkBin(boOr, Result, R, P);
  end;
end;

function TSclParser.ParseXor: TExpr;
var
  P: TSrcPos;
  R: TExpr;
begin
  Result := ParseAnd;
  while IsKw('XOR') do
  begin
    P := Tok.Pos;
    Next;
    try
      R := ParseAnd;
    except
      Result.Free;
      raise;
    end;
    Result := MkBin(boXor, Result, R, P);
  end;
end;

function TSclParser.ParseAnd: TExpr;
var
  P: TSrcPos;
  R: TExpr;
begin
  Result := ParseEquality;
  while IsKw('AND') or (Tok.Kind = tkAmp) do
  begin
    P := Tok.Pos;
    Next;
    try
      R := ParseEquality;
    except
      Result.Free;
      raise;
    end;
    Result := MkBin(boAnd, Result, R, P);
  end;
end;

function TSclParser.ParseEquality: TExpr;
var
  P: TSrcPos;
  Op: TBinOp;
  R: TExpr;
begin
  Result := ParseRel;
  while Tok.Kind in [tkEq, tkNe] do
  begin
    P := Tok.Pos;
    if Tok.Kind = tkEq then Op := boEq else Op := boNe;
    Next;
    try
      R := ParseRel;
    except
      Result.Free;
      raise;
    end;
    Result := MkBin(Op, Result, R, P);
  end;
end;

function TSclParser.ParseRel: TExpr;
var
  P: TSrcPos;
  Op: TBinOp;
  R: TExpr;
begin
  Result := ParseAdd;
  while Tok.Kind in [tkLt, tkLe, tkGt, tkGe] do
  begin
    P := Tok.Pos;
    case Tok.Kind of
      tkLt: Op := boLt;
      tkLe: Op := boLe;
      tkGt: Op := boGt;
    else
      Op := boGe;
    end;
    Next;
    try
      R := ParseAdd;
    except
      Result.Free;
      raise;
    end;
    Result := MkBin(Op, Result, R, P);
  end;
end;

function TSclParser.ParseAdd: TExpr;
var
  P: TSrcPos;
  Op: TBinOp;
  R: TExpr;
begin
  Result := ParseMul;
  while Tok.Kind in [tkPlus, tkMinus] do
  begin
    P := Tok.Pos;
    if Tok.Kind = tkPlus then Op := boAdd else Op := boSub;
    Next;
    try
      R := ParseMul;
    except
      Result.Free;
      raise;
    end;
    Result := MkBin(Op, Result, R, P);
  end;
end;

function TSclParser.ParseMul: TExpr;
var
  P: TSrcPos;
  Op: TBinOp;
  R: TExpr;
begin
  Result := ParsePow;
  while (Tok.Kind in [tkStar, tkSlash]) or IsKw('MOD') do
  begin
    P := Tok.Pos;
    if Tok.Kind = tkStar then Op := boMul
    else if Tok.Kind = tkSlash then Op := boDiv
    else Op := boMod;
    Next;
    try
      R := ParsePow;
    except
      Result.Free;
      raise;
    end;
    Result := MkBin(Op, Result, R, P);
  end;
end;

function TSclParser.ParsePow: TExpr;
var
  P: TSrcPos;
  R: TExpr;
begin
  Result := ParseUnary;
  while Tok.Kind = tkPower do
  begin
    P := Tok.Pos;
    Next;
    try
      R := ParseUnary;
    except
      Result.Free;
      raise;
    end;
    Result := MkBin(boPow, Result, R, P);
  end;
end;

function TSclParser.ParseUnary: TExpr;
var
  U: TUnary;
  P: TSrcPos;
  Op: TUnaryOp;
  Lit: TLiteral;
  Inner: TExpr;
begin
  P := Tok.Pos;
  if (Tok.Kind = tkMinus) or (Tok.Kind = tkPlus) or IsKw('NOT') then
  begin
    if Tok.Kind = tkMinus then Op := uoNeg
    else if Tok.Kind = tkPlus then Op := uoPlus
    else Op := uoNot;
    Next;
    Inner := ParseUnary();
    { fold "-literal" into the literal so that e.g. -32768 fits Int }
    if (Op = uoNeg) and (Inner is TLiteral) and (TLiteral(Inner).LitKind in [lkInt, lkReal]) then
    begin
      Lit := TLiteral(Inner);
      Lit.I := -Lit.I;
      Lit.F := -Lit.F;
      Lit.Pos := P;
      Exit(Lit);
    end;
    if Op = uoPlus then Exit(Inner);
    U := TUnary.Create;
    U.Pos := P;
    U.Op := Op;
    U.Operand := Inner;
    Result := U;
  end
  else
    Result := ParsePostfix;
end;

function TSclParser.ParseCallArgs(Callee: TExpr): TCall;
var
  C: TCall;
  A: TCallArg;
begin
  C := TCall.Create;
  C.Pos := Callee.Pos;
  C.Callee := Callee;
  try
    Expect(tkLParen);
    if Tok.Kind <> tkRParen then
      repeat
        A := TCallArg.Create;
        C.Args.Add(A);
        A.Pos := Tok.Pos;
        if (Tok.Kind in [tkIdent, tkLocal]) and (PeekTok(1).Kind in [tkAssign, tkOutAssign]) then
        begin
          A.Name := Tok.Text;
          Next;
          A.IsOut := Tok.Kind = tkOutAssign;
          Next;
        end;
        A.Value := ParseExpr;
      until not Accept(tkComma);
    Expect(tkRParen);
    Result := C;
  except
    C.Free;
    raise;
  end;
end;

function TSclParser.ParsePostfix: TExpr;
var
  M: TMemberRef;
  X: TIndexRef;
  Sl: TSliceRef;
  P: TSrcPos;
  T: TToken;
begin
  Result := ParsePrimary;
  try
    while True do
    begin
      P := Tok.Pos;
      if Tok.Kind = tkDot then
      begin
        Next;
        T := Tok;
        if T.Kind = tkAddress then
        begin
          { slice access: .%X0 .%B1 .%W0 .%D0 }
          if (Length(T.Text) < 2) or not (T.Text[1] in ['X', 'B', 'W', 'D']) then
            Fail('Invalid slice access %' + T.Text);
          Sl := TSliceRef.Create;
          Sl.Pos := P;
          Sl.Base := Result;
          Sl.SliceKind := T.Text[1];
          Sl.Index := StrToIntDef(Copy(T.Text, 2, MaxInt), -1);
          if Sl.Index < 0 then
          begin
            Result := Sl;
            Fail('Invalid slice index %' + T.Text);
          end;
          Result := Sl;
          Next;
        end
        else if T.Kind in [tkIdent, tkGlobal] then
        begin
          M := TMemberRef.Create;
          M.Pos := T.Pos;
          M.Base := Result;
          M.Member := T.Text;
          M.Quoted := T.Kind = tkGlobal;
          Result := M;
          Next;
        end
        else if (T.Kind = tkTypedLit) then
          Fail('Member name expected (name collides with a typed constant prefix)')
        else
          Fail('Member name expected after ''.''');
      end
      else if Tok.Kind = tkLBrack then
      begin
        Next;
        X := TIndexRef.Create;
        X.Pos := P;
        X.Base := Result;
        Result := X;
        repeat
          X.Indices.Add(ParseExpr);
        until not Accept(tkComma);
        Expect(tkRBrack);
      end
      else if Tok.Kind = tkLParen then
        Result := ParseCallArgs(Result)
      else
        Break;
    end;
  except
    Result.Free;
    raise;
  end;
end;

function TSclParser.ParsePrimary: TExpr;
var
  T: TToken;
  L: TLiteral;
  N: TNameRef;
  A: TAbsAddr;
begin
  T := Tok;
  case T.Kind of
    tkIntLit:
      begin
        L := TLiteral.Create;
        L.Pos := T.Pos;
        L.LitKind := lkInt;
        L.I := T.I;
        L.F := T.I;
        Next;
        Result := L;
      end;
    tkRealLit:
      begin
        L := TLiteral.Create;
        L.Pos := T.Pos;
        L.LitKind := lkReal;
        L.F := T.F;
        Next;
        Result := L;
      end;
    tkTypedLit:
      begin
        L := TLiteral.Create;
        L.Pos := T.Pos;
        L.LitKind := lkTyped;
        L.TypeName := T.LitType;
        L.I := T.I;
        L.F := T.F;
        L.S := T.S;
        L.IsRealTyped := (T.LitType = 'REAL') or (T.LitType = 'LREAL');
        if L.IsRealTyped and (T.F = 0) and (T.I <> 0) then L.F := T.I;
        Next;
        Result := L;
      end;
    tkStringLit:
      begin
        L := TLiteral.Create;
        L.Pos := T.Pos;
        L.LitKind := lkString;
        L.S := T.S;
        Next;
        Result := L;
      end;
    tkAddress:
      begin
        A := TAbsAddr.Create;
        A.Pos := T.Pos;
        A.Text := T.Text;
        Next;
        Result := A;
      end;
    tkLParen:
      begin
        Next;
        Result := ParseExpr;
        try
          Expect(tkRParen);
        except
          Result.Free;
          raise;
        end;
      end;
    tkLocal, tkGlobal, tkIdent:
      begin
        if (T.Kind = tkIdent) and ((T.Up = 'TRUE') or (T.Up = 'FALSE')) then
        begin
          L := TLiteral.Create;
          L.Pos := T.Pos;
          L.LitKind := lkBool;
          L.I := Ord(T.Up = 'TRUE');
          Next;
          Exit(L);
        end;
        if (T.Kind = tkIdent) and ((T.Up = 'AND') or (T.Up = 'OR') or (T.Up = 'XOR') or
          (T.Up = 'MOD') or (T.Up = 'THEN') or (T.Up = 'DO') or (T.Up = 'OF') or
          (T.Up = 'END_IF') or (T.Up = 'ELSE') or (T.Up = 'TO') or (T.Up = 'BY')) then
          Fail('Operand expected but ' + T.Text + ' found');
        N := TNameRef.Create;
        N.Pos := T.Pos;
        N.Name := T.Text;
        case T.Kind of
          tkLocal: N.Scope := nsLocal;
          tkGlobal: N.Scope := nsGlobal;
        else
          N.Scope := nsPlain;
        end;
        Next;
        Result := N;
      end;
  else
    Fail('Operand expected but ' + TokDesc(T) + ' found');
    Result := nil;
  end;
end;

end.
