unit uSclSource;

{ TIA Portal SCL sources (.scl): the SCL blocks, data blocks and PLC data types of a project as text,
  and back into a project (the SCL Compiler reads and writes the same).

  Export: FUNCTION / FUNCTION_BLOCK / ORGANIZATION_BLOCK with VAR_INPUT .. VAR_TEMP, VAR CONSTANT and the
  code between BEGIN and END_..; every SCL network is a REGION with its title (the declarations at the
  top of a network, VAR_TEMP and VAR CONSTANT, go into the declaration part). LAD and STL networks have
  no SCL text: they are left out (counted). DATA_BLOCK with VAR / VAR RETAIN, an instance DB with the
  name of its FB, TYPE with STRUCT. A comment line "// FC2" before a block keeps its number.

  Import: the same, also several units in one file. A block, DB or type with the same name is replaced;
  a new one takes the number of its "// FC2" line or the next free one. A body of REGIONs only becomes
  one network per REGION. An anonymous Struct (a variable "x : Struct .. END_STRUCT") becomes a PLC
  data type of its own, "<block>_<variable>". }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, StrUtils, Math, uPlcTypes, uPlcProject, uFbd;

function SclExportBlock(P: TPlcProject; B: TBlock; out Skipped: Integer): string;
function SclExportDB(P: TPlcProject; D: TDataBlock): string;
function SclExportUdt(U: TDataBlock): string;
{ the whole project: PLC data types, FCs, FBs, DBs, OBs }
function SclExportAll(P: TPlcProject; out Report: string): string;
{ the source into the project (nothing is changed when it has an error); Report: what was made, or the error }
function SclImport(P: TPlcProject; const Src: string; out Report: string; DataOnly: Boolean = False): Boolean;

implementation

const
  NL = LineEnding;

{ ====================================================================== }
{ export                                                                 }
{ ====================================================================== }

function VarLine(const V: TDbVar; const Ind: string): string;
begin
  Result := Ind + V.Name + ' : ' + V.TypeText;
  if Trim(V.Start) <> '' then Result := Result + ' := ' + Trim(V.Start);
  Result := Result + ';';
  if V.Comment <> '' then Result := Result + '   // ' + StringReplace(V.Comment, LineEnding, ' ', [rfReplaceAll]);
end;

function Quoted(const S: string): string;
begin
  Result := '"' + S + '"';
end;

{ the declarations at the top of an SCL network (VAR_TEMP .. END_VAR, VAR CONSTANT .. END_VAR) apart from
  its code }
procedure SplitNetwork(N: TNetwork; Temps, Consts, Code: TStrings);
var
  I: Integer;
  U, S: string;
  InSec, IsConst, Top: Boolean;
begin
  InSec := False;
  IsConst := False;
  Top := True;
  for I := 0 to N.Stl.Count - 1 do
  begin
    S := N.Stl[I];
    U := UpperCase(Trim(S));
    if InSec then
    begin
      if Copy(U, 1, 7) = 'END_VAR' then
      begin
        InSec := False;
        Continue;
      end;
      if Trim(S) = '' then Continue;
      if IsConst then Consts.Add(Trim(S)) else Temps.Add(Trim(S));
      Continue;
    end;
    if Top and ((U = 'VAR_TEMP') or (U = 'VAR CONSTANT') or (U = 'VAR')) then
    begin
      InSec := True;
      IsConst := U = 'VAR CONSTANT';
      Continue;
    end;
    if Top and (U = '') then Continue;
    Top := False;
    Code.Add(S);
  end;
end;

function SclExportBlock(P: TPlcProject; B: TBlock; out Skipped: Integer): string;
const
  Kinds: array[TBlockKind] of string = ('ORGANIZATION_BLOCK', 'FUNCTION', 'FUNCTION_BLOCK');
  KindNames: array[TBlockKind] of string = ('OB', 'FC', 'FB');
var
  SL, Temps, Consts, Code: TStringList;
  I, K, Scl: Integer;
  Ret, Ttl: string;
  N: TNetwork;
  Any: Boolean;
  Nets: array of TNetwork;     // the SCL of every network (FBD / CFC: the SCL they compile to; nil: none)
  LN: TIntArray;
  Errs: TStringList;

  procedure Section(const Title: string; ASec: TVarSection; Retain: Integer);
  var
    J: Integer;
    Head: Boolean;
  begin
    Head := False;
    for J := 0 to High(B.Iface.Vars) do
      if (B.Iface.Vars[J].Section = ASec) and ((Retain < 0) or (Ord(B.Iface.Vars[J].Retain) = Retain)) then
      begin
        if not Head then SL.Add('   ' + Title);
        Head := True;
        SL.Add(VarLine(B.Iface.Vars[J], '      '));
      end;
    // the VAR_TEMP of the networks
    if (ASec = vsTemp) and (Temps.Count > 0) then
    begin
      if not Head then SL.Add('   ' + Title);
      Head := True;
      for J := 0 to Temps.Count - 1 do SL.Add('      ' + Temps[J]);
    end;
    if Head then SL.Add('   END_VAR');
  end;

begin
  Skipped := 0;
  SL := TStringList.Create;
  Temps := TStringList.Create;
  Consts := TStringList.Create;
  Code := TStringList.Create;
  SetLength(Nets, B.NetCount);
  Errs := TStringList.Create;
  try
    for I := 0 to B.NetCount - 1 do
      if B.Net(I).Kind = nkSCL then Nets[I] := B.Net(I)
      else if B.Net(I).Kind in [nkFBD, nkCFC] then
      begin
        Nets[I] := TNetwork.Create(nkSCL);
        FbdToScl(B.Net(I), P, Nets[I].Stl, LN, Errs, B, I + 1);
        Nets[I].Title := B.Net(I).Title;
        Nets[I].Comment := Trim(B.Net(I).Comment + ' (' + NetLangName(B.Net(I).Kind) + ' as SCL)');
      end
      else Nets[I] := nil;
    // the declarations of the networks first: they go into the declaration part
    Scl := 0;
    for I := 0 to B.NetCount - 1 do
      if Nets[I] <> nil then
      begin
        Inc(Scl);
        SplitNetwork(Nets[I], Temps, Consts, Code);
      end;
    Ret := '';
    for I := 0 to High(B.Iface.Vars) do
      if B.Iface.Vars[I].Section = vsReturn then Ret := B.Iface.Vars[I].TypeText;
    SL.Add(Format('// %s%d', [KindNames[B.Kind], B.Number]));
    if B.Comment <> '' then
      for I := 0 to WordCount(B.Comment, [#10]) - 1 do SL.Add('// ' + Trim(ExtractWord(I + 1, B.Comment, [#10, #13])));
    if B.Kind = bkFC then
    begin
      if Ret = '' then Ret := 'Void';
      SL.Add(Format('FUNCTION %s : %s', [Quoted(B.Name), Ret]));
    end
    else
      SL.Add(Kinds[B.Kind] + ' ' + Quoted(B.Name));
    if IsTia(P.Family) then SL.Add('{ S7_Optimized_Access := ''TRUE'' }');
    if Trim(B.Version) = '' then SL.Add('VERSION : 0.1') else SL.Add('VERSION : ' + Trim(B.Version));
    Section('VAR_INPUT', vsInput, -1);
    Section('VAR_OUTPUT', vsOutput, -1);
    Section('VAR_IN_OUT', vsInOut, -1);
    if B.Kind = bkFB then
    begin
      Section('VAR', vsStatic, 0);
      Section('VAR RETAIN', vsStatic, 1);
    end;
    Section('VAR_TEMP', vsTemp, -1);
    if Consts.Count > 0 then
    begin
      SL.Add('   VAR CONSTANT');
      for I := 0 to Consts.Count - 1 do SL.Add('      ' + Consts[I]);
      SL.Add('   END_VAR');
    end;
    SL.Add('');
    SL.Add('BEGIN');
    Any := False;
    for I := 0 to B.NetCount - 1 do
    begin
      N := Nets[I];
      if N = nil then
      begin
        N := B.Net(I);
        Inc(Skipped);
        if N.Kind = nkLAD then SL.Add(Format('    // network %d (LAD) has no SCL text: not exported', [I + 1]))
        else SL.Add(Format('    // network %d (STL) has no SCL text: not exported', [I + 1]));
        Continue;
      end;
      Code.Clear;
      Temps.Clear;
      Consts.Clear;
      SplitNetwork(N, Temps, Consts, Code);
      Ttl := Trim(N.Title);
      if (Scl = 1) and (Ttl = '') and (Trim(N.Comment) = '') then
      begin
        // one network without a title: the code as it is
        for K := 0 to Code.Count - 1 do SL.Add('    ' + Code[K]);
      end
      else
      begin
        if Ttl = '' then Ttl := Format('Network %d', [I + 1]);
        SL.Add('    REGION ' + Ttl);
        if Trim(N.Comment) <> '' then SL.Add('        // ' + StringReplace(Trim(N.Comment), LineEnding, ' ', [rfReplaceAll]));
        for K := 0 to Code.Count - 1 do SL.Add('        ' + Code[K]);
        SL.Add('    END_REGION');
      end;
      Any := True;
    end;
    if not Any then SL.Add('    ;');
    SL.Add('END_' + Kinds[B.Kind]);
    SL.Add('');
    Result := SL.Text;
  finally
    SL.Free;
    Temps.Free;
    Consts.Free;
    Code.Free;
    Errs.Free;
    for I := 0 to High(Nets) do
      if (Nets[I] <> nil) and (Nets[I] <> B.Net(I)) then Nets[I].Free;
  end;
end;

function SclExportDB(P: TPlcProject; D: TDataBlock): string;
var
  SL: TStringList;
  I, Rt: Integer;
  Fb: TBlock;
  Head: Boolean;
begin
  SL := TStringList.Create;
  try
    SL.Add(Format('// DB%d', [D.Number]));
    if D.Comment <> '' then SL.Add('// ' + StringReplace(D.Comment, LineEnding, ' ', [rfReplaceAll]));
    SL.Add('DATA_BLOCK ' + Quoted(D.Name));
    if IsTia(P.Family) then
    begin
      if D.Optimized then SL.Add('{ S7_Optimized_Access := ''TRUE'' }') else SL.Add('{ S7_Optimized_Access := ''FALSE'' }');
    end;
    SL.Add('VERSION : 0.1');
    SL.Add('NON_RETAIN');
    if D.InstanceOf > 0 then
    begin
      // an instance DB: the name of its FB
      Fb := P.InstanceFB(D);
      if Fb <> nil then SL.Add(Quoted(Fb.Name)) else SL.Add(Format('FB%d', [D.InstanceOf]));
    end
    else
      for Rt := 0 to 1 do
      begin
        Head := False;
        for I := 0 to High(D.Vars) do
          if Ord(D.Vars[I].Retain) = Rt then
          begin
            if not Head then
            begin
              if Rt = 1 then SL.Add('   VAR RETAIN') else SL.Add('   VAR');
            end;
            Head := True;
            SL.Add(VarLine(D.Vars[I], '      '));
          end;
        if Head then SL.Add('   END_VAR');
      end;
    SL.Add('');
    SL.Add('BEGIN');
    SL.Add('');
    SL.Add('END_DATA_BLOCK');
    SL.Add('');
    Result := SL.Text;
  finally
    SL.Free;
  end;
end;

function SclExportUdt(U: TDataBlock): string;
var
  SL: TStringList;
  I: Integer;
begin
  SL := TStringList.Create;
  try
    if U.Comment <> '' then SL.Add('// ' + StringReplace(U.Comment, LineEnding, ' ', [rfReplaceAll]));
    SL.Add('TYPE ' + Quoted(U.Name));
    SL.Add('VERSION : 0.1');
    SL.Add('   STRUCT');
    for I := 0 to High(U.Vars) do SL.Add(VarLine(U.Vars[I], '      '));
    SL.Add('   END_STRUCT;');
    SL.Add('');
    SL.Add('END_TYPE');
    SL.Add('');
    Result := SL.Text;
  finally
    SL.Free;
  end;
end;

function SclExportAll(P: TPlcProject; out Report: string): string;
var
  I, J, K, Sk, NSk: Integer;
  Done: TList;
  U: TDataBlock;
  Ok: Boolean;
const
  Order: array[0..2] of TBlockKind = (bkFC, bkFB, bkOB);
begin
  Result := '';
  NSk := 0;
  // the PLC data types: one that uses another after it
  Done := TList.Create;
  try
    for K := 0 to P.UdtCount do
      for I := 0 to P.UdtCount - 1 do
      begin
        U := P.Udt(I);
        if Done.IndexOf(U) >= 0 then Continue;
        Ok := True;
        for J := 0 to High(U.Vars) do
          if (U.Vars[J].Udt <> nil) and (U.Vars[J].Udt <> U) and (P.Udts.IndexOf(U.Vars[J].Udt) >= 0) and
            (Done.IndexOf(U.Vars[J].Udt) < 0) then Ok := False;
        if Ok or (K = P.UdtCount) then
        begin
          U.Layout;
          Result := Result + SclExportUdt(U);
          Done.Add(U);
        end;
      end;
  finally
    Done.Free;
  end;
  for K := 0 to High(Order) do
    for I := 0 to P.BlockCount - 1 do
      if P.Block(I).Kind = Order[K] then
      begin
        Result := Result + SclExportBlock(P, P.Block(I), Sk);
        Inc(NSk, Sk);
        if K = 1 then
          // the instance DBs of the FBs after them
          for J := 0 to P.DBCount - 1 do
            if P.DB(J).InstanceOf = P.Block(I).Number then Result := Result + SclExportDB(P, P.DB(J));
      end;
  for J := 0 to P.DBCount - 1 do
    if (P.DB(J).InstanceOf = 0) or (P.InstanceFB(P.DB(J)) = nil) then Result := Result + SclExportDB(P, P.DB(J));
  Report := Format('%d blocks, %d data blocks, %d PLC data types', [P.BlockCount, P.DBCount, P.UdtCount]);
  if NSk > 0 then Report := Report + Format('; %d LAD / STL networks have no SCL text (left out)', [NSk]);
end;

{ ====================================================================== }
{ import                                                                 }
{ ====================================================================== }

type
  TSrcKind = (skFC, skFB, skOB, skDB, skUDT);

  TSrcVar = record
    Name, TypeText, Init, Comment: string;
    Sec: TVarSection;
    Retain, IsConst: Boolean;
  end;

  TSrcUnit = class
    Kind: TSrcKind;
    Name, RetType, InstOf, Comment, Version: string;
    Number: Integer;
    Vars: array of TSrcVar;
    Body: string;
    Assigns: TStringList;
    constructor Create;
    destructor Destroy; override;
    procedure AddVar(const V: TSrcVar);
  end;

  ESrcError = class(Exception);

  { the tokens of a source: words, "names", 'strings', numbers and literals, symbols }
  TSrcScanner = class
    S: string;
    P, Line: Integer;
    TokS: string;          // the token
    TokKind: Char;         // w word, q "quoted", s 'string', n number / literal, y symbol, e end
    TokStart, TokEnd: Integer;
    TokLine: Integer;
    LastCmt: string;       // the // comment after the token before (on its line)
    LastCmtLine: Integer;
    CmtLines: TStringList; // the // comment lines since the last unit (for "// FC2" and comments)
    constructor Create(const ASrc: string);
    destructor Destroy; override;
    procedure Next;
    function IsW(const W: string): Boolean;
    function IsY(const Y: string): Boolean;
    procedure Fail(const Msg: string);
    procedure ExpectY(const Y: string);
  end;

constructor TSrcUnit.Create;
begin
  Assigns := TStringList.Create;
end;

destructor TSrcUnit.Destroy;
begin
  Assigns.Free;
  inherited Destroy;
end;

procedure TSrcUnit.AddVar(const V: TSrcVar);
begin
  SetLength(Vars, Length(Vars) + 1);
  Vars[High(Vars)] := V;
end;

constructor TSrcScanner.Create(const ASrc: string);
begin
  S := ASrc;
  P := 1;
  Line := 1;
  CmtLines := TStringList.Create;
  Next;
end;

destructor TSrcScanner.Destroy;
begin
  CmtLines.Free;
  inherited Destroy;
end;

procedure TSrcScanner.Fail(const Msg: string);
begin
  raise ESrcError.CreateFmt('line %d: %s', [TokLine, Msg]);
end;

function TSrcScanner.IsW(const W: string): Boolean;
begin
  Result := (TokKind = 'w') and SameText(TokS, W);
end;

function TSrcScanner.IsY(const Y: string): Boolean;
begin
  Result := (TokKind = 'y') and (TokS = Y);
end;

procedure TSrcScanner.ExpectY(const Y: string);
begin
  if not IsY(Y) then Fail(Format('"%s" expected, found "%s"', [Y, TokS]));
  Next;
end;

procedure TSrcScanner.Next;
var
  C: Char;
  Q, Depth: Integer;

  function At(K: Integer): Char;
  begin
    if K <= Length(S) then Result := S[K] else Result := #0;
  end;

begin
  // blanks, comments and attributes
  while P <= Length(S) do
  begin
    C := S[P];
    if C = #10 then
    begin
      Inc(Line);
      Inc(P);
    end
    else if C in [' ', #9, #13] then Inc(P)
    else if (C = '/') and (At(P + 1) = '/') then
    begin
      Q := P + 2;
      while (Q <= Length(S)) and not (S[Q] in [#10, #13]) do Inc(Q);
      LastCmt := Trim(Copy(S, P + 2, Q - P - 2));
      LastCmtLine := Line;
      CmtLines.Add(LastCmt);
      P := Q;
    end
    else if (C = '(') and (At(P + 1) = '*') then
    begin
      Q := P + 2;
      while (Q <= Length(S)) and not ((S[Q] = '*') and (At(Q + 1) = ')')) do
      begin
        if S[Q] = #10 then Inc(Line);
        Inc(Q);
      end;
      P := Q + 2;
    end
    else if C = '{' then
    begin
      // an attribute: { S7_Optimized_Access := 'TRUE' }
      Depth := 0;
      repeat
        if S[P] = '{' then Inc(Depth) else if S[P] = '}' then Dec(Depth);
        if S[P] = #10 then Inc(Line);
        Inc(P);
      until (P > Length(S)) or (Depth = 0);
    end
    else
      Break;
  end;
  TokStart := P;
  TokLine := Line;
  if P > Length(S) then
  begin
    TokKind := 'e';
    TokS := '';
    TokEnd := P;
    Exit;
  end;
  C := S[P];
  if C = '"' then
  begin
    Q := P + 1;
    while (Q <= Length(S)) and (S[Q] <> '"') do Inc(Q);
    TokKind := 'q';
    TokS := Copy(S, P + 1, Q - P - 1);
    P := Q + 1;
  end
  else if C = '''' then
  begin
    Q := P + 1;
    while Q <= Length(S) do
    begin
      if S[Q] = '$' then Inc(Q)
      else if S[Q] = '''' then
      begin
        if At(Q + 1) <> '''' then Break;
        Inc(Q);
      end;
      Inc(Q);
    end;
    TokKind := 's';
    TokS := Copy(S, P, Q - P + 1);
    P := Q + 1;
  end
  else if C in ['A'..'Z', 'a'..'z', '_', '0'..'9', '#', '%'] then
  begin
    // a word or a literal: T#5S, 16#FF, 1.5, DT#2024-01-01-12:00:00
    Q := P;
    while (Q <= Length(S)) and (S[Q] in ['A'..'Z', 'a'..'z', '_', '0'..'9', '#', '%']) do Inc(Q);
    if (Q <= Length(S)) and (Pos('#', Copy(S, P, Q - P)) > 0) then
      while (Q <= Length(S)) and (S[Q] in ['A'..'Z', 'a'..'z', '_', '0'..'9', '#', '.', '-', ':', '+']) do Inc(Q)
    else if C in ['0'..'9'] then
      while (Q <= Length(S)) and ((S[Q] in ['0'..'9', '_', 'E', 'e']) or (S[Q] = '.') and (At(Q + 1) in ['0'..'9'])) do Inc(Q);
    TokS := Copy(S, P, Q - P);
    if C in ['0'..'9'] then TokKind := 'n' else TokKind := 'w';
    if Pos('#', TokS) > 0 then TokKind := 'n';
    P := Q;
  end
  else
  begin
    TokKind := 'y';
    if (C = ':') and (At(P + 1) = '=') then TokS := ':='
    else if (C = '.') and (At(P + 1) = '.') then TokS := '..'
    else if (C = '=') and (At(P + 1) = '>') then TokS := '=>'
    else TokS := C;
    Inc(P, Length(TokS));
  end;
  TokEnd := P;
end;

{ the importer }
type
  TImporter = class
    Sc: TSrcScanner;
    Units: TList;        // of TSrcUnit, the generated types first
    Gen: TStringList;    // the names of the generated types
    Proj: TPlcProject;
    constructor Create(P: TPlcProject; const Src: string);
    destructor Destroy; override;
    procedure Parse;
    procedure ParseUnit;
    procedure ParseVars(U: TSrcUnit; ASec: TVarSection; ARetain, AConst: Boolean; const EndW: string;
      EatSemi: Boolean = True);
    function ParseType(const Owner, VarName: string; OneLine: Boolean = False): string;
    function GenName(const Base: string): string;
  end;

constructor TImporter.Create(P: TPlcProject; const Src: string);
begin
  Proj := P;
  Units := TList.Create;
  Gen := TStringList.Create;
  Sc := TSrcScanner.Create(Src);
end;

destructor TImporter.Destroy;
var
  I: Integer;
begin
  for I := 0 to Units.Count - 1 do TSrcUnit(Units[I]).Free;
  Units.Free;
  Gen.Free;
  Sc.Free;
  inherited Destroy;
end;

function TImporter.GenName(const Base: string): string;
var
  K: Integer;
begin
  Result := Base;
  K := 2;
  while (Gen.IndexOf(UpperCase(Result)) >= 0) or (Proj.FindUdt(Result) <> nil) do
  begin
    Result := Base + '_' + IntToStr(K);
    Inc(K);
  end;
  Gen.Add(UpperCase(Result));
end;

{ the type of a declaration up to := or ; an anonymous Struct becomes a PLC data type of its own }
function TImporter.ParseType(const Owner, VarName: string; OneLine: Boolean): string;
var
  St, Depth, Ln, Last: Integer;
  U: TSrcUnit;
  Pre: string;
begin
  Pre := '';
  if Sc.IsW('ARRAY') then
  begin
    // Array[..] of: the part to OF
    St := Sc.TokStart;
    while not Sc.IsW('OF') and (Sc.TokKind <> 'e') do Sc.Next;
    if Sc.TokKind = 'e' then Sc.Fail('OF expected');
    Pre := Trim(Copy(Sc.S, St, Sc.TokStart - St)) + ' of ';
    Sc.Next;
  end;
  if Sc.IsW('STRUCT') then
  begin
    Sc.Next;
    U := TSrcUnit.Create;
    U.Kind := skUDT;
    U.Name := GenName(Owner + '_' + VarName);
    U.Comment := Format('the anonymous Struct of %s.%s (made by the import of an .scl source)', [Owner, VarName]);
    // the ; after END_STRUCT ends the declaration of the variable
    ParseVars(U, vsStatic, False, False, 'END_STRUCT', False);
    Units.Insert(0, U);
    Exit(Pre + '"' + U.Name + '"');
  end;
  St := Sc.TokStart;
  Ln := Sc.TokLine;
  Depth := 0;
  Last := St;
  // the return type of a FUNCTION: the rest of its line
  while (Sc.TokKind <> 'e') and not ((Depth = 0) and (Sc.IsY(':=') or Sc.IsY(';'))) and
    not (OneLine and (Sc.TokLine <> Ln)) do
  begin
    if Sc.IsY('[') then Inc(Depth) else if Sc.IsY(']') then Dec(Depth);
    Last := Sc.TokEnd;
    Sc.Next;
  end;
  // up to the end of its last token (no comment or attribute after it)
  Result := Pre + Trim(DelSpace1(StringReplace(Copy(Sc.S, St, Last - St), LineEnding, ' ', [rfReplaceAll])));
  if Result = '' then Sc.Fail('data type expected');
end;

procedure TImporter.ParseVars(U: TSrcUnit; ASec: TVarSection; ARetain, AConst: Boolean; const EndW: string;
  EatSemi: Boolean);
var
  V: TSrcVar;
  St, Ln, Depth, Last: Integer;
begin
  while not Sc.IsW(EndW) do
  begin
    if Sc.TokKind = 'e' then Sc.Fail(EndW + ' missing');
    if not (Sc.TokKind in ['w', 'q']) then Sc.Fail('a name expected, found "' + Sc.TokS + '"');
    FillChar(V, SizeOf(V), 0);
    V.Name := Sc.TokS;
    V.Sec := ASec;
    V.Retain := ARetain;
    V.IsConst := AConst;
    Sc.Next;
    Sc.ExpectY(':');
    V.TypeText := ParseType(U.Name, V.Name);
    if Sc.IsY(':=') then
    begin
      Sc.Next;
      St := Sc.TokStart;
      Depth := 0;
      Last := St;
      while (Sc.TokKind <> 'e') and not ((Depth = 0) and Sc.IsY(';')) do
      begin
        if Sc.IsY('[') or Sc.IsY('(') then Inc(Depth) else if Sc.IsY(']') or Sc.IsY(')') then Dec(Depth);
        Last := Sc.TokEnd;
        Sc.Next;
      end;
      V.Init := Trim(Copy(Sc.S, St, Last - St));
    end;
    Ln := Sc.TokLine;
    Sc.ExpectY(';');
    // a comment on the line of the declaration
    if Sc.LastCmtLine = Ln then V.Comment := Sc.LastCmt;
    Sc.LastCmtLine := -1;
    U.AddVar(V);
  end;
  Sc.Next;
  if EatSemi and Sc.IsY(';') then Sc.Next;   // END_STRUCT;
end;

procedure TImporter.ParseUnit;
var
  U: TSrcUnit;
  W, EndW, Mark: string;
  K, N: Integer;
  B0: Integer;
begin
  U := TSrcUnit.Create;
  Units.Add(U);
  W := UpperCase(Sc.TokS);
  case W of
    'FUNCTION': begin U.Kind := skFC; EndW := 'END_FUNCTION'; end;
    'FUNCTION_BLOCK': begin U.Kind := skFB; EndW := 'END_FUNCTION_BLOCK'; end;
    'ORGANIZATION_BLOCK': begin U.Kind := skOB; EndW := 'END_ORGANIZATION_BLOCK'; end;
    'DATA_BLOCK': begin U.Kind := skDB; EndW := 'END_DATA_BLOCK'; end;
  else
    begin U.Kind := skUDT; EndW := 'END_TYPE'; end;
  end;
  // "// FC2" before the unit: its number; the other comment lines: its comment
  for K := 0 to Sc.CmtLines.Count - 1 do
  begin
    Mark := UpperCase(Trim(Sc.CmtLines[K]));
    if (Length(Mark) > 2) and ((Copy(Mark, 1, 2) = 'OB') or (Copy(Mark, 1, 2) = 'FC') or (Copy(Mark, 1, 2) = 'FB') or
      (Copy(Mark, 1, 2) = 'DB')) and TryStrToInt(Copy(Mark, 3, MaxInt), N) then
      U.Number := N
    else if Trim(Sc.CmtLines[K]) <> '' then
    begin
      if U.Comment <> '' then U.Comment := U.Comment + LineEnding;
      U.Comment := U.Comment + Trim(Sc.CmtLines[K]);
    end;
  end;
  Sc.CmtLines.Clear;
  Sc.Next;
  if not (Sc.TokKind in ['w', 'q']) then Sc.Fail('the name of the ' + LowerCase(W) + ' expected');
  U.Name := Sc.TokS;
  Sc.Next;
  if U.Kind = skFC then
  begin
    if Sc.IsY(':') then
    begin
      Sc.Next;
      U.RetType := ParseType(U.Name, 'Ret_Val', True);
      if SameText(U.RetType, 'Void') then U.RetType := '';
    end;
  end;
  // the head: TITLE, VERSION, AUTHOR, NON_RETAIN ..., an instance DB's FB, the sections
  while not Sc.IsW(EndW) do
  begin
    if Sc.TokKind = 'e' then Sc.Fail(EndW + ' missing');
    W := UpperCase(Sc.TokS);
    if Sc.TokKind = 'q' then
    begin
      // DATA_BLOCK "iDB" "FB": the instance DB of an FB (or a DB of a PLC data type)
      U.InstOf := Sc.TokS;
      Sc.Next;
      if Sc.IsY(';') then Sc.Next;
      Continue;
    end;
    if (W = 'TITLE') or (W = 'VERSION') or (W = 'AUTHOR') or (W = 'FAMILY') or (W = 'NAME') then
    begin
      // to the end of the line (VERSION : 0.1 is kept)
      K := Sc.TokLine;
      Sc.Next;
      if (W = 'VERSION') and Sc.IsY(':') then
      begin
        Sc.Next;
        if Sc.TokLine = K then U.Version := Sc.TokS;
      end;
      while (Sc.TokKind <> 'e') and (Sc.TokLine = K) do Sc.Next;
      Continue;
    end;
    if (W = 'NON_RETAIN') or (W = 'KNOW_HOW_PROTECT') or (W = 'READ_ONLY') or (W = 'UNLINKED') or (W = 'DB_SPECIFIC') then
    begin
      Sc.Next;
      Continue;
    end;
    if (W = 'VAR_INPUT') or (W = 'VAR_OUTPUT') or (W = 'VAR_IN_OUT') or (W = 'VAR_TEMP') or (W = 'VAR_STAT') or (W = 'VAR') then
    begin
      Sc.Next;
      case W of
        'VAR_INPUT': ParseVars(U, vsInput, False, False, 'END_VAR');
        'VAR_OUTPUT': ParseVars(U, vsOutput, False, False, 'END_VAR');
        'VAR_IN_OUT': ParseVars(U, vsInOut, False, False, 'END_VAR');
        'VAR_TEMP': ParseVars(U, vsTemp, False, False, 'END_VAR');
      else
        begin
          // VAR, VAR RETAIN, VAR NON_RETAIN, VAR CONSTANT
          if Sc.IsW('CONSTANT') then
          begin
            Sc.Next;
            ParseVars(U, vsStatic, False, True, 'END_VAR');
          end
          else if Sc.IsW('RETAIN') then
          begin
            Sc.Next;
            ParseVars(U, vsStatic, True, False, 'END_VAR');
          end
          else
          begin
            if Sc.IsW('NON_RETAIN') then Sc.Next;
            ParseVars(U, vsStatic, False, False, 'END_VAR');
          end;
        end;
      end;
      if Sc.IsY(';') then Sc.Next;
      Continue;
    end;
    if W = 'STRUCT' then
    begin
      Sc.Next;
      ParseVars(U, vsStatic, False, False, 'END_STRUCT');
      Continue;
    end;
    if W = 'BEGIN' then
    begin
      B0 := Sc.TokEnd;
      Sc.Next;
      if U.Kind = skDB then
      begin
        // the actual values: name := value;
        while not Sc.IsW(EndW) and (Sc.TokKind <> 'e') do
        begin
          W := Sc.TokS;
          Sc.Next;
          if Sc.IsY(':=') then
          begin
            Sc.Next;
            K := Sc.TokStart;
            while not Sc.IsY(';') and (Sc.TokKind <> 'e') do Sc.Next;
            U.Assigns.Values[W] := Trim(Copy(Sc.S, K, Sc.TokStart - K));
          end;
          if Sc.IsY(';') then Sc.Next;
        end;
      end
      else
      begin
        // the code: as it is, up to END_..
        while not Sc.IsW(EndW) and (Sc.TokKind <> 'e') do Sc.Next;
        U.Body := Copy(Sc.S, B0, Sc.TokStart - B0);
      end;
      Continue;
    end;
    Sc.Fail(Format('"%s" not expected here', [Sc.TokS]));
  end;
  // the comments after END_.. belong to the next unit ("// FB7")
  Sc.CmtLines.Clear;
  Sc.Next;
  if Sc.IsY(';') then Sc.Next;
end;

procedure TImporter.Parse;
begin
  while Sc.TokKind <> 'e' do
  begin
    if Sc.IsW('FUNCTION') or Sc.IsW('FUNCTION_BLOCK') or Sc.IsW('ORGANIZATION_BLOCK') or Sc.IsW('DATA_BLOCK') or
      Sc.IsW('TYPE') then
      ParseUnit
    else
      Sc.Fail(Format('FUNCTION, FUNCTION_BLOCK, ORGANIZATION_BLOCK, DATA_BLOCK or TYPE expected, found "%s"', [Sc.TokS]));
  end;
end;

{ the lines of a body without the indent they all have }
procedure BodyLines(const Body: string; L: TStringList);
var
  I, K, Ind: Integer;
  S: string;
begin
  L.Text := StringReplace(Body, #9, '    ', [rfReplaceAll]);
  while (L.Count > 0) and (Trim(L[0]) = '') do L.Delete(0);
  while (L.Count > 0) and (Trim(L[L.Count - 1]) = '') do L.Delete(L.Count - 1);
  Ind := MaxInt;
  for I := 0 to L.Count - 1 do
    if Trim(L[I]) <> '' then
    begin
      S := L[I];
      K := 0;
      while (K < Length(S)) and (S[K + 1] = ' ') do Inc(K);
      Ind := Min(Ind, K);
    end;
  if Ind = MaxInt then Ind := 0;
  for I := 0 to L.Count - 1 do L[I] := TrimRight(Copy(L[I], Ind + 1, MaxInt));
end;

{ the networks of a body: one per REGION when the body is REGIONs only, else one }
procedure BodyNetworks(B: TBlock; const Body: string; const Consts: TStringList);
var
  L, Cur: TStringList;
  I, Depth: Integer;
  U, Ttl: string;
  OnlyRegions: Boolean;
  N: TNetwork;

  procedure Put(const ATitle: string; Lines: TStringList);
  var
    K: Integer;
  begin
    N := B.AddNet(nkSCL);
    N.Title := ATitle;
    BodyLines(Lines.Text, Lines);
    // a "// comment" first line of a REGION: the comment of the network
    if (Lines.Count > 0) and (Copy(Trim(Lines[0]), 1, 2) = '//') and (ATitle <> '') then
    begin
      N.Comment := Trim(Copy(Trim(Lines[0]), 3, MaxInt));
      Lines.Delete(0);
    end;
    if (B.NetCount = 1) and (Consts.Count > 0) then
    begin
      // the constants of the block at the top of the first network
      N.Stl.Add('VAR CONSTANT');
      for K := 0 to Consts.Count - 1 do N.Stl.Add('    ' + Consts[K]);
      N.Stl.Add('END_VAR');
    end;
    N.Stl.AddStrings(Lines);
  end;

begin
  L := TStringList.Create;
  Cur := TStringList.Create;
  try
    BodyLines(Body, L);
    // only REGIONs (and blank / comment lines between them) at the top level?
    OnlyRegions := L.Count > 0;
    Depth := 0;
    for I := 0 to L.Count - 1 do
    begin
      U := UpperCase(Trim(L[I]));
      if (Depth = 0) and (U <> '') and (Copy(U, 1, 2) <> '//') and (Copy(U, 1, 7) <> 'REGION ') and (U <> 'REGION') then
        OnlyRegions := False;
      if (Copy(U, 1, 7) = 'REGION ') or (U = 'REGION') then Inc(Depth)
      else if Copy(U, 1, 10) = 'END_REGION' then Dec(Depth);
    end;
    if not OnlyRegions then
    begin
      Put('', L);
      Exit;
    end;
    Depth := 0;
    Ttl := '';
    for I := 0 to L.Count - 1 do
    begin
      U := UpperCase(Trim(L[I]));
      if ((Copy(U, 1, 7) = 'REGION ') or (U = 'REGION')) and (Depth = 0) then
      begin
        Ttl := Trim(Copy(Trim(L[I]), 7, MaxInt));
        Cur.Clear;
        Inc(Depth);
        Continue;
      end;
      if (Copy(U, 1, 7) = 'REGION ') or (U = 'REGION') then Inc(Depth)
      else if Copy(U, 1, 10) = 'END_REGION' then
      begin
        Dec(Depth);
        if Depth = 0 then
        begin
          Put(Ttl, Cur);
          Cur.Clear;
          Continue;
        end;
      end;
      if Depth > 0 then Cur.Add(L[I]);
    end;
  finally
    L.Free;
    Cur.Free;
  end;
end;

function SclImport(P: TPlcProject; const Src: string; out Report: string; DataOnly: Boolean): Boolean;
var
  Skipped: Integer;
  Im: TImporter;
  I, J, K, N: Integer;
  U: TSrcUnit;
  B, Old: TBlock;
  D: TDataBlock;
  Consts: TStringList;
  Made: TStringList;
  Bk: TBlockKind;
  Fb: TBlock;
begin
  Result := False;
  Report := '';
  Made := TStringList.Create;
  Consts := TStringList.Create;
  Im := TImporter.Create(P, Src);
  try
    try
      Im.Parse;
    except
      on E: ESrcError do
      begin
        Report := 'the source has an error, nothing was imported: ' + E.Message;
        Exit;
      end;
    end;
    if Im.Units.Count = 0 then
    begin
      Report := 'no FUNCTION, FUNCTION_BLOCK, ORGANIZATION_BLOCK, DATA_BLOCK or TYPE in the source';
      Exit;
    end;
    // the PLC data types first (also the anonymous Structs), then the blocks, then the DBs
    for I := 0 to Im.Units.Count - 1 do
    begin
      U := TSrcUnit(Im.Units[I]);
      if U.Kind <> skUDT then Continue;
      D := P.FindUdt(U.Name);
      if (D <> nil) and (P.Udts.IndexOf(D) >= 0) then
        SetLength(D.Vars, 0)
      else
      begin
        N := 1;
        while (P.UdtCount > 0) and (P.FindUdt(Format('UDT%d', [N])) <> nil) do Inc(N);
        D := P.AddUdt(N, U.Name);
      end;
      D.Comment := U.Comment;
      for J := 0 to High(U.Vars) do D.AddVar(U.Vars[J].Name, U.Vars[J].TypeText, U.Vars[J].Init, U.Vars[J].Comment);
      Made.Add('type "' + U.Name + '"');
    end;
    // the Data blocks screen: the PLC data types and DBs alone
    Skipped := 0;
    if DataOnly then
    begin
      for I := 0 to Im.Units.Count - 1 do
        if TSrcUnit(Im.Units[I]).Kind in [skFC, skFB, skOB] then Inc(Skipped);
      if Skipped = Im.Units.Count then
      begin
        Report := 'no TYPE or DATA_BLOCK in the source (its blocks are imported on the Program screen)';
        Exit;
      end;
    end;
    for I := 0 to Im.Units.Count - 1 do
    begin
      U := TSrcUnit(Im.Units[I]);
      if DataOnly or not (U.Kind in [skFC, skFB, skOB]) then Continue;
      case U.Kind of
        skFC: Bk := bkFC;
        skFB: Bk := bkFB;
      else
        Bk := bkOB;
      end;
      // the same name: replaced (it keeps its number)
      Old := nil;
      for J := 0 to P.BlockCount - 1 do
        if (P.Block(J).Kind = Bk) and SameText(P.Block(J).Name, U.Name) then Old := P.Block(J);
      N := U.Number;
      if Old <> nil then N := Old.Number
      else if (N <= 0) or (P.FindBlock(Bk, N) <> nil) then
      begin
        if Bk = bkOB then
        begin
          if SameText(U.Name, 'Main') then N := 1
          else if SameText(U.Name, 'Startup') then N := 100
          else N := 123;
        end
        else
          N := 1;
        while P.FindBlock(Bk, N) <> nil do Inc(N);
      end;
      if Old <> nil then P.DeleteBlock(P.Blocks.IndexOf(Old));
      B := P.AddBlock(Bk, N, U.Name);
      B.Comment := U.Comment;
      if U.Version <> '' then B.Version := U.Version;
      Consts.Clear;
      for J := 0 to High(U.Vars) do
        if U.Vars[J].IsConst then
          Consts.Add(Format('%s : %s := %s;', [U.Vars[J].Name, U.Vars[J].TypeText, U.Vars[J].Init]))
        else
        begin
          K := B.Iface.AddSecVar(U.Vars[J].Sec, U.Vars[J].Name, U.Vars[J].TypeText, U.Vars[J].Init, U.Vars[J].Comment);
          if (K >= 0) and (K <= High(B.Iface.Vars)) then B.Iface.Vars[K].Retain := U.Vars[J].Retain;
        end;
      if U.RetType <> '' then B.Iface.AddSecVar(vsReturn, 'Ret_Val', U.RetType, '', 'the function value');
      BodyNetworks(B, U.Body, Consts);
      if B.NetCount = 0 then B.AddNet(nkSCL);
      Made.Add(Format('%s "%s" (%d networks)', [B.Title, B.Name, B.NetCount]));
    end;
    for I := 0 to Im.Units.Count - 1 do
    begin
      U := TSrcUnit(Im.Units[I]);
      if U.Kind <> skDB then Continue;
      D := P.FindDBByName(U.Name);
      if D <> nil then
      begin
        N := D.Number;
        P.DeleteDB(P.DBs.IndexOf(D));
      end
      else
      begin
        N := U.Number;
        if (N <= 0) or (P.FindDB(N) <> nil) then
        begin
          N := 1;
          while P.FindDB(N) <> nil do Inc(N);
        end;
      end;
      D := P.AddDB(N, U.Name);
      D.Comment := U.Comment;
      D.Optimized := IsTia(P.Family);
      if U.InstOf <> '' then
      begin
        Fb := P.FindFB('"' + U.InstOf + '"');
        if Fb = nil then Fb := P.FindFB(U.InstOf);
        if Fb <> nil then D.InstanceOf := Fb.Number
        else if P.FindUdt(U.InstOf) <> nil then
        begin
          // a DB of a PLC data type: its members
          for J := 0 to High(P.FindUdt(U.InstOf).Vars) do
            with P.FindUdt(U.InstOf).Vars[J] do D.AddVar(Name, TypeText, Start, Comment);
        end
        else
          Made.Add(Format('DB "%s": FB / type "%s" not found', [U.Name, U.InstOf]));
      end;
      for J := 0 to High(U.Vars) do
      begin
        D.AddVar(U.Vars[J].Name, U.Vars[J].TypeText, U.Vars[J].Init, U.Vars[J].Comment);
        D.Vars[High(D.Vars)].Retain := U.Vars[J].Retain;
      end;
      // BEGIN: the actual values become the start values
      for J := 0 to U.Assigns.Count - 1 do
      begin
        K := D.FindVar(U.Assigns.Names[J]);
        if K >= 0 then D.Vars[K].Start := U.Assigns.ValueFromIndex[J];
      end;
      D.Layout;
      Made.Add(Format('DB%d "%s"', [D.Number, D.Name]));
    end;
    P.SortBlocks;
    P.SyncObIfaces;   // an OB's VAR_INPUT / start Temps of the source: the start information of the family
    Report := 'imported: ';
    for I := 0 to Made.Count - 1 do
    begin
      if I > 0 then Report := Report + ', ';
      Report := Report + Made[I];
    end;
    if Skipped > 0 then Report := Report + Format('; %d FC / FB / OB left out (Program screen: SCL source)', [Skipped]);
    Result := True;
  finally
    Im.Free;
    Made.Free;
    Consts.Free;
  end;
end;

end.
