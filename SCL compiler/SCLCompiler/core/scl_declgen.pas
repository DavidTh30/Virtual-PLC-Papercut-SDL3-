{ SCL Compiler - declaration table <-> SCL source round trip and block templates (used by the IDE) }
unit scl_declgen;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, scl_base, scl_types, scl_ast, scl_parser;

type
  TDeclRow = record
    Section: string;    // Input Output InOut Static Temp Constant Member
    Name: string;
    TypeText: string;
    InitText: string;
    Retain: string;     // '' / Retain / Non-retain
    Comment: string;
  end;
  TDeclRowArray = array of TDeclRow;

  TBlockKindInfo = record
    Kind: TUnitKind;
    IsInstanceDB: Boolean;
    UsesStruct: Boolean;  // DB / UDT declared with STRUCT
  end;

const
  SECTION_LIST: array[0..6] of string = ('Input', 'Output', 'InOut', 'Static', 'Temp', 'Constant', 'Member');

function FindUnitIn(const Src, AName: string; Units: TSourceUnitList; Diags: TDiagList): TProgUnit;
function LoadDeclRows(const Src, BlockName: string; out Rows: TDeclRowArray; out Info: TBlockKindInfo;
  out Msg: string): Boolean;
function ApplyDeclRows(const Src, BlockName: string; const Rows: TDeclRowArray; out NewSrc, Msg: string): Boolean;
function NewBlockTemplate(Kind: TUnitKind; const Name, RetType, InstanceOf: string; Optimized: Boolean;
  Cpu: TCpuFamily): string;
function AllowedSections(Kind: TUnitKind; StructStyle: Boolean): TStringArray;

implementation

function SecName(K: TMemberSection): string;
begin
  case K of
    msInput: Result := 'Input';
    msOutput: Result := 'Output';
    msInOut: Result := 'InOut';
    msTemp: Result := 'Temp';
    msConstant: Result := 'Constant';
  else
    Result := 'Static';
  end;
end;

function RetainName(R: TRetainMode): string;
begin
  case R of
    rmRetain: Result := 'Retain';
    rmNonRetain: Result := 'Non-retain';
  else
    Result := '';
  end;
end;

function FindUnitIn(const Src, AName: string; Units: TSourceUnitList; Diags: TDiagList): TProgUnit;
var
  I: Integer;
begin
  ParseSclSource(Src, '', Units, Diags);
  for I := 0 to Units.Count - 1 do
    if SameText(Units.UnitAt(I).Name, AName) then Exit(Units.UnitAt(I));
  Result := nil;
end;

procedure AddRow(var Rows: TDeclRowArray; const Sec: string; D: TVarDecl; const Ret: string);
var
  K: Integer;
begin
  K := Length(Rows);
  SetLength(Rows, K + 1);
  Rows[K].Section := Sec;
  Rows[K].Name := D.Name;
  Rows[K].TypeText := D.TypeText;
  Rows[K].InitText := D.InitText;
  Rows[K].Retain := Ret;
  Rows[K].Comment := D.Comment;
end;

function LoadDeclRows(const Src, BlockName: string; out Rows: TDeclRowArray; out Info: TBlockKindInfo;
  out Msg: string): Boolean;
var
  Units: TSourceUnitList;
  Diags: TDiagList;
  U: TProgUnit;
  I, J: Integer;
  S: TVarSection;
begin
  Result := False;
  SetLength(Rows, 0);
  Msg := '';
  Info.Kind := ukFB;
  Info.IsInstanceDB := False;
  Info.UsesStruct := False;
  Units := TSourceUnitList.Create(True);
  Diags := TDiagList.Create(True);
  try
    U := FindUnitIn(Src, BlockName, Units, Diags);
    if U = nil then
    begin
      if Diags.ErrorCount > 0 then Msg := 'The source has syntax errors: ' + Diags[0].ToString
      else Msg := 'Block "' + BlockName + '" not found in the source';
      Exit;
    end;
    Info.Kind := U.Kind;
    if (U.Kind = ukDB) and (U.DBTypeName <> '') then
    begin
      Info.IsInstanceDB := True;
      Msg := Format('DB "%s" is an instance of "%s" - its interface comes from that block', [U.Name, U.DBTypeName]);
      Exit;
    end;
    if U.StructSpec <> nil then
    begin
      Info.UsesStruct := True;
      for I := 0 to U.StructSpec.Members.Count - 1 do
        AddRow(Rows, 'Member', TVarDecl(U.StructSpec.Members[I]), '');
    end
    else
      for I := 0 to U.Sections.Count - 1 do
      begin
        S := TVarSection(U.Sections[I]);
        for J := 0 to S.Vars.Count - 1 do
          AddRow(Rows, SecName(S.Kind), TVarDecl(S.Vars[J]), RetainName(S.Retain));
      end;
    Result := True;
  finally
    Units.Free;
    Diags.Free;
  end;
end;

function LineStart(const S: string; P: Integer): Integer;
begin
  Result := P;
  while (Result > 1) and not (S[Result - 1] in [#10, #13]) do Dec(Result);
end;

function DeclLine(const R: TDeclRow; const Indent: string): string;
begin
  Result := Indent + R.Name + ' : ' + R.TypeText;
  if Trim(R.InitText) <> '' then Result := Result + ' := ' + Trim(R.InitText);
  Result := Result + ';';
  if Trim(R.Comment) <> '' then Result := Result + '   // ' + Trim(R.Comment);
  Result := Result + LineEnding;
end;

function GenSections(const Rows: TDeclRowArray; Kind: TUnitKind): string;
const
  Order: array[0..5] of string = ('Input', 'Output', 'InOut', 'Static', 'Temp', 'Constant');
  Kw: array[0..5] of string = ('VAR_INPUT', 'VAR_OUTPUT', 'VAR_IN_OUT', 'VAR', 'VAR_TEMP', 'VAR CONSTANT');
  RetModes: array[0..2] of string = ('', 'Retain', 'Non-retain');
var
  K, I, M: Integer;
  Head, Body: string;
begin
  Result := '';
  for K := 0 to High(Order) do
    for M := 0 to 2 do
    begin
      if (M > 0) and (Order[K] <> 'Static') then Continue;
      Body := '';
      for I := 0 to High(Rows) do
        if SameText(Rows[I].Section, Order[K]) and ((Order[K] <> 'Static') or SameText(Rows[I].Retain, RetModes[M])) then
          Body := Body + DeclLine(Rows[I], '      ');
      if Body = '' then Continue;
      Head := Kw[K];
      if M = 1 then Head := Head + ' RETAIN' else if M = 2 then Head := Head + ' NON_RETAIN';
      Result := Result + '   ' + Head + LineEnding + Body + '   END_VAR' + LineEnding + LineEnding;
    end;
  if Kind = ukDB then ;
end;

function ApplyDeclRows(const Src, BlockName: string; const Rows: TDeclRowArray; out NewSrc, Msg: string): Boolean;
var
  Units: TSourceUnitList;
  Diags: TDiagList;
  U: TProgUnit;
  A, B, I: Integer;
  Gen: string;
begin
  Result := False;
  NewSrc := Src;
  Msg := '';
  for I := 0 to High(Rows) do
  begin
    if Trim(Rows[I].Name) = '' then begin Msg := Format('Row %d: name is empty', [I + 1]); Exit; end;
    if Trim(Rows[I].TypeText) = '' then begin Msg := Format('Row %d (%s): data type is empty', [I + 1, Rows[I].Name]); Exit; end;
  end;
  Units := TSourceUnitList.Create(True);
  Diags := TDiagList.Create(True);
  try
    U := FindUnitIn(Src, BlockName, Units, Diags);
    if U = nil then
    begin
      Msg := 'Block "' + BlockName + '" could not be parsed - fix the source first';
      Exit;
    end;
    if (U.Kind = ukDB) and (U.DBTypeName <> '') then
    begin
      Msg := 'Instance DBs have no own declaration';
      Exit;
    end;
    A := LineStart(Src, U.HeaderEndOffset);
    B := LineStart(Src, U.DeclEndOffset);
    if B < A then B := A;
    if (U.Kind = ukUDT) or ((U.Kind = ukDB) and (U.StructSpec <> nil)) then
    begin
      Gen := '   STRUCT' + LineEnding;
      for I := 0 to High(Rows) do Gen := Gen + DeclLine(Rows[I], '      ');
      Gen := Gen + '   END_STRUCT;' + LineEnding + LineEnding;
    end
    else if U.Kind = ukDB then
    begin
      Gen := GenSections(Rows, U.Kind);
      if Gen = '' then Gen := '   VAR' + LineEnding + '   END_VAR' + LineEnding + LineEnding;
    end
    else
      Gen := GenSections(Rows, U.Kind);
    NewSrc := Copy(Src, 1, A - 1) + Gen + Copy(Src, B, MaxInt);
    Result := True;
  finally
    Units.Free;
    Diags.Free;
  end;
end;

function AllowedSections(Kind: TUnitKind; StructStyle: Boolean): TStringArray;
begin
  case Kind of
    ukUDT: Result := ['Member'];
    ukDB: if StructStyle then Result := ['Member'] else Result := ['Static', 'Constant'];
    ukFC: Result := ['Input', 'Output', 'InOut', 'Temp', 'Constant'];
    ukFB: Result := ['Input', 'Output', 'InOut', 'Static', 'Temp', 'Constant'];
  else
    Result := ['Input', 'Temp', 'Constant'];
  end;
end;

function NewBlockTemplate(Kind: TUnitKind; const Name, RetType, InstanceOf: string; Optimized: Boolean;
  Cpu: TCpuFamily): string;
var
  L: TStringList;
  Opt: string;
begin
  L := TStringList.Create;
  try
    if Cpu in [cpuS7_300, cpuS7_400] then Opt := ''
    else if Optimized then Opt := '{ S7_Optimized_Access := ''TRUE'' }'
    else Opt := '{ S7_Optimized_Access := ''FALSE'' }';
    case Kind of
      ukUDT:
        begin
          L.Add('TYPE "' + Name + '"');
          L.Add('VERSION : 0.1');
          L.Add('   STRUCT');
          L.Add('      Value : Int;');
          L.Add('   END_STRUCT;');
          L.Add('');
          L.Add('END_TYPE');
        end;
      ukDB:
        begin
          L.Add('DATA_BLOCK "' + Name + '"');
          if Opt <> '' then L.Add(Opt);
          L.Add('VERSION : 0.1');
          if InstanceOf <> '' then
          begin
            L.Add('NON_RETAIN');
            L.Add('"' + InstanceOf + '"');
          end
          else
          begin
            L.Add('   VAR');
            L.Add('      Value : Int;');
            L.Add('   END_VAR');
          end;
          L.Add('');
          L.Add('BEGIN');
          L.Add('');
          L.Add('END_DATA_BLOCK');
        end;
      ukFC:
        begin
          if RetType = '' then L.Add('FUNCTION "' + Name + '" : Void')
          else L.Add('FUNCTION "' + Name + '" : ' + RetType);
          if Opt <> '' then L.Add(Opt);
          L.Add('VERSION : 0.1');
          L.Add('   VAR_INPUT');
          L.Add('      IN : Int;');
          L.Add('   END_VAR');
          L.Add('');
          L.Add('   VAR_TEMP');
          L.Add('      tmp : Int;');
          L.Add('   END_VAR');
          L.Add('');
          L.Add('BEGIN');
          if (RetType <> '') and not SameText(RetType, 'Void') then
            L.Add('    #' + Name + ' := #IN;')
          else
            L.Add('    #tmp := #IN;');
          L.Add('');
          L.Add('END_FUNCTION');
        end;
      ukFB:
        begin
          L.Add('FUNCTION_BLOCK "' + Name + '"');
          if Opt <> '' then L.Add(Opt);
          L.Add('VERSION : 0.1');
          L.Add('   VAR_INPUT');
          L.Add('      Start : Bool;');
          L.Add('   END_VAR');
          L.Add('');
          L.Add('   VAR_OUTPUT');
          L.Add('      Running : Bool;');
          L.Add('   END_VAR');
          L.Add('');
          L.Add('   VAR');
          L.Add('      Count : DInt;');
          L.Add('   END_VAR');
          L.Add('');
          L.Add('BEGIN');
          L.Add('    #Running := #Start;');
          L.Add('    IF #Start THEN');
          L.Add('        #Count := #Count + 1;');
          L.Add('    END_IF;');
          L.Add('');
          L.Add('END_FUNCTION_BLOCK');
        end;
      ukOB:
        begin
          L.Add('ORGANIZATION_BLOCK "' + Name + '"');
          if Opt <> '' then L.Add(Opt);
          L.Add('VERSION : 0.1');
          L.Add('');
          L.Add('BEGIN');
          L.Add('');
          L.Add('END_ORGANIZATION_BLOCK');
        end;
    end;
    Result := L.Text;
  finally
    L.Free;
  end;
end;

end.
