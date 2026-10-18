{ SCL Compiler - "Find Declaration": resolve the identifier under the cursor to its declaration }
unit scl_navigate;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, scl_base, scl_types, scl_ast, scl_compiler;

type
  TDeclKind = (dkNone, dkSource, dkTag, dkBuiltin, dkSystem);

  TDeclResult = record
    Kind: TDeclKind;
    Pos: TSrcPos;      // dkSource
    Name: string;      // identifier that was resolved
    Info: string;      // human readable description
  end;

  TPathSeg = record
    Name: string;
    Local: Boolean;    // #name
    Quoted: Boolean;   // "name"
  end;
  TPathSegs = array of TPathSeg;

{ Path of the identifier at Col (1-based) in LineText, e.g. #Seq.tmReqOn.Q -> [#Seq, tmReqOn, Q].
  The last segment is the identifier under the cursor. }
function IdentPathAt(const LineText: string; Col: Integer; out Segs: TPathSegs): Boolean;
function FindDeclarationAt(C: TSclCompiler; const FileName, LineText: string; Line, Col: Integer): TDeclResult;

implementation

const
  IdChars = ['A'..'Z', 'a'..'z', '0'..'9', '_'];
  SclKeywords = ',IF,THEN,ELSIF,ELSE,END_IF,CASE,OF,END_CASE,FOR,TO,BY,DO,END_FOR,WHILE,END_WHILE,REPEAT,UNTIL,' +
    'END_REPEAT,EXIT,CONTINUE,RETURN,GOTO,REGION,END_REGION,AND,OR,XOR,NOT,MOD,FUNCTION,END_FUNCTION,' +
    'FUNCTION_BLOCK,END_FUNCTION_BLOCK,ORGANIZATION_BLOCK,END_ORGANIZATION_BLOCK,DATA_BLOCK,END_DATA_BLOCK,' +
    'TYPE,END_TYPE,STRUCT,END_STRUCT,VAR,VAR_INPUT,VAR_OUTPUT,VAR_IN_OUT,VAR_TEMP,VAR_STAT,END_VAR,CONSTANT,' +
    'RETAIN,NON_RETAIN,BEGIN,TITLE,VERSION,ARRAY,TRUE,FALSE,';

function IdentPathAt(const LineText: string; Col: Integer; out Segs: TPathSegs): Boolean;
var
  S: string;
  I, Ws, We, Q1, Q2, P, Depth: Integer;
  Seg: TPathSeg;

  procedure Prepend(const X: TPathSeg);
  var
    K: Integer;
  begin
    SetLength(Segs, Length(Segs) + 1);
    for K := High(Segs) downto 1 do Segs[K] := Segs[K - 1];
    Segs[0] := X;
  end;

  { read the segment that ends at position E (inclusive); returns its start }
  function ReadSegBackward(E: Integer; out X: TPathSeg): Integer;
  var
    B: Integer;
  begin
    X.Local := False;
    X.Quoted := False;
    X.Name := '';
    if (E >= 1) and (S[E] = '"') then
    begin
      B := E - 1;
      while (B >= 1) and (S[B] <> '"') do Dec(B);
      if B < 1 then Exit(0);
      X.Name := Copy(S, B + 1, E - B - 1);
      X.Quoted := True;
      if (B > 1) and (S[B - 1] = '#') then
      begin
        X.Local := True;
        Dec(B);
      end;
      Exit(B);
    end;
    B := E;
    while (B >= 1) and (S[B] in IdChars) do Dec(B);
    Inc(B);
    if B > E then Exit(0);
    X.Name := Copy(S, B, E - B + 1);
    if (B > 1) and (S[B - 1] = '#') then
    begin
      X.Local := True;
      Dec(B);
    end;
    Result := B;
  end;

begin
  Result := False;
  SetLength(Segs, 0);
  S := LineText;
  if (Col < 1) or (S = '') then Exit;
  if Col > Length(S) then Col := Length(S);
  { inside "quoted name"? }
  Q1 := 0;
  Q2 := 0;
  I := 1;
  while I <= Length(S) do
  begin
    if S[I] = '''' then
    begin
      { skip string literal }
      Inc(I);
      while (I <= Length(S)) and (S[I] <> '''') do Inc(I);
    end
    else if S[I] = '"' then
    begin
      P := I + 1;
      while (P <= Length(S)) and (S[P] <> '"') do Inc(P);
      if (Col >= I) and (Col <= P) then
      begin
        Q1 := I;
        Q2 := P;
        Break;
      end;
      I := P;
    end
    else if (S[I] = '/') and (I < Length(S)) and (S[I + 1] = '/') then
    begin
      if Col >= I then Exit;   // cursor in a comment
      Break;
    end;
    Inc(I);
  end;
  if Q1 > 0 then
  begin
    if Q2 > Length(S) then Exit;
    Ws := Q1;
    We := Q2;
    Seg.Name := Copy(S, Q1 + 1, Q2 - Q1 - 1);
    Seg.Quoted := True;
    Seg.Local := (Q1 > 1) and (S[Q1 - 1] = '#');
    if Seg.Local then Ws := Q1 - 1;
  end
  else
  begin
    if not (S[Col] in IdChars) then
    begin
      if (Col > 1) and (S[Col - 1] in IdChars) then Dec(Col)
      else if (S[Col] = '#') and (Col < Length(S)) and (S[Col + 1] in IdChars) then Inc(Col)
      else Exit;
    end;
    Ws := Col;
    while (Ws > 1) and (S[Ws - 1] in IdChars) do Dec(Ws);
    We := Col;
    while (We < Length(S)) and (S[We + 1] in IdChars) do Inc(We);
    Seg.Name := Copy(S, Ws, We - Ws + 1);
    Seg.Quoted := False;
    Seg.Local := (Ws > 1) and (S[Ws - 1] = '#');
    if Seg.Local then Dec(Ws);
    if (Seg.Name <> '') and (Seg.Name[1] in ['0'..'9']) then Exit;
    { typed constant prefix T#5S etc. }
    if (We < Length(S)) and (S[We + 1] = '#') then Exit;
  end;
  if Seg.Name = '' then Exit;
  Prepend(Seg);
  { walk left over ".member" / "[index]" }
  P := Ws - 1;
  while (P >= 1) and (S[P] = '.') do
  begin
    Dec(P);
    { skip index brackets }
    while (P >= 1) and (S[P] = ']') do
    begin
      Depth := 0;
      repeat
        if S[P] = ']' then Inc(Depth)
        else if S[P] = '[' then Dec(Depth);
        Dec(P);
      until (P < 1) or (Depth = 0);
    end;
    if P < 1 then Break;
    I := ReadSegBackward(P, Seg);
    if I = 0 then Break;
    Prepend(Seg);
    P := I - 1;
  end;
  Result := True;
end;

function PosText(const P: TSrcPos): string;
begin
  Result := Format('%s(%d)', [ExtractFileName(P.FileName), P.Line]);
end;

function FindDeclarationAt(C: TSclCompiler; const FileName, LineText: string; Line, Col: Integer): TDeclResult;
var
  Segs: TPathSegs;
  I, K: Integer;
  B, Ctx, Blk: TBlockInfo;
  L: TLocalSym;
  T: TSclType;
  M: TMember;
  Tg: TTagInfo;
  N: string;

  procedure SetSrc(const P: TSrcPos; const AInfo: string);
  begin
    if P.Line > 0 then
    begin
      Result.Kind := dkSource;
      Result.Pos := P;
    end
    else
      Result.Kind := dkSystem;
    Result.Info := AInfo;
  end;

begin
  Result.Kind := dkNone;
  Result.Name := '';
  Result.Info := '';
  Result.Pos := NoPos;
  if not IdentPathAt(LineText, Col, Segs) then
  begin
    Result.Info := 'No identifier at the cursor';
    Exit;
  end;
  Result.Name := Segs[High(Segs)].Name;
  if (Length(Segs) = 1) and not Segs[0].Local and not Segs[0].Quoted and
     (Pos(',' + UpperCase(Segs[0].Name) + ',', SclKeywords) > 0) then
  begin
    Result.Kind := dkSystem;
    Result.Info := UpperCase(Segs[0].Name) + ' is an SCL keyword';
    Exit;
  end;
  { block that contains the cursor }
  Ctx := nil;
  for I := 0 to C.BlockCount - 1 do
  begin
    B := C.Blocks[I];
    if (B.U <> nil) and SameText(ExpandFileName(B.U.FileName), ExpandFileName(FileName)) and
       (Line >= B.U.Pos.Line) and (Line <= B.U.EndLine) then
    begin
      Ctx := B;
      Break;
    end;
  end;

  { ---- first segment ---- }
  N := Segs[0].Name;
  T := nil;
  if (Ctx <> nil) and not Segs[0].Quoted or ((Ctx <> nil) and Segs[0].Local) then
  begin
    L := Ctx.FindLocal(N);
    if L <> nil then
    begin
      T := L.Typ;
      SetSrc(L.DeclPos, Format('#%s : %s  (%s of %s)', [L.Name, TypeName(L.Typ), SectionNames[L.Section],
        Ctx.FullName]));
    end
    else if (Ctx.Kind in [ukDB, ukUDT]) and (Ctx.DataType <> nil) and (Ctx.DataType.FindMember(N) <> nil) then
    begin
      M := Ctx.DataType.FindMember(N);
      T := M.Typ;
      SetSrc(M.DeclPos, Format('%s : %s  (%s)', [M.Name, TypeName(M.Typ), Ctx.FullName]));
    end
    else if Segs[0].Local then
    begin
      Result.Info := Format('Local variable #%s is not declared in %s', [N, Ctx.FullName]);
      Exit;
    end;
  end;
  if Result.Kind = dkNone then
  begin
    Tg := C.FindTagInfo(N);
    Blk := C.FindBlockInfo(N);
    if (Tg <> nil) and (Length(Segs) = 1) then
    begin
      Result.Kind := dkTag;
      if Tg.IsConst then
        Result.Info := Format('User constant "%s" : %s = %s', [Tg.Name, TypeName(Tg.Typ), Tg.Tag.Value])
      else
        Result.Info := Format('PLC tag "%s" : %s  %s', [Tg.Name, TypeName(Tg.Typ), Tg.Tag.Address]);
      Result.Name := Tg.Name;
      Exit;
    end;
    if Blk <> nil then
    begin
      T := Blk.DataType;
      SetSrc(Blk.U.Pos, Blk.FullName);
    end
    else if (Length(Segs) = 1) and IsBuiltinName(N) then
    begin
      Result.Kind := dkBuiltin;
      Result.Info := UpperCase(N) + ' is a built-in function';
      Exit;
    end
    else if (Length(Segs) = 1) and (IsSysFBName(N) or (FindElementaryType(N) <> nil) or SameText(N, 'DTL')) then
    begin
      Result.Kind := dkSystem;
      Result.Info := UpperCase(N) + ' is a system data type / function block';
      Exit;
    end
    else
    begin
      Result.Info := Format('Declaration of "%s" not found', [N]);
      Exit;
    end;
  end;

  { ---- member path ---- }
  for K := 1 to High(Segs) do
  begin
    while (T <> nil) and (T.Kind = tkArray) do T := T.ElemType;
    if (T = nil) or not (T.Kind in [tkStruct, tkFBInst, tkSysFB]) then
    begin
      Result.Kind := dkNone;
      Result.Info := Format('"%s": the type of "%s" has no members', [Segs[K].Name, Segs[K - 1].Name]);
      Exit;
    end;
    M := T.FindMember(Segs[K].Name);
    if M = nil then
    begin
      if T.Kind = tkSysFB then
      begin
        Result.Kind := dkSystem;
        Result.Info := Format('%s.%s belongs to the system type %s', [Segs[K - 1].Name, Segs[K].Name, T.Name]);
      end
      else
      begin
        Result.Kind := dkNone;
        Result.Info := Format('"%s" is not a member of %s', [Segs[K].Name, TypeName(T)]);
      end;
      Exit;
    end;
    if T.Kind = tkSysFB then
    begin
      Result.Kind := dkSystem;
      Result.Info := Format('%s.%s : %s  (system type %s)', [Segs[K - 1].Name, M.Name, TypeName(M.Typ), T.Name]);
      T := M.Typ;
      Continue;
    end;
    SetSrc(M.DeclPos, Format('%s : %s  (member of %s)', [M.Name, TypeName(M.Typ), TypeName(T)]));
    T := M.Typ;
  end;
  if (Result.Kind = dkSource) and (Result.Info = '') then Result.Info := PosText(Result.Pos);
end;

end.
