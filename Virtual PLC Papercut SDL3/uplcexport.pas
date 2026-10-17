unit uPlcExport;

{ Exports of single pieces of the project (right click menus, the Watch / I/O / Tags screens).

  Text   a block (OB / FC / FB: interface, every network), one network, a data block or a PLC
         data type, as a readable listing: SCL and STL as their code, LAD row by row
  JSON   the same piece as in the project file (BlockToJson, NetToJson, DataBlockToJson)
  CSV    tables (a data block with its values, the watch table, the I/O list, the tag table):
         UTF-8 with a BOM (Excel shows Thai), comma separated, quoted where needed

  The live values come from the caller (TLiveFn: the operand, as "DB".Var or "Tag", to its value
  text, '' when there is none). }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, StrUtils, fpjson, uPlcTypes, uPlcProject;

type
  TLiveFn = function(const Operand: string): string of object;

function BlockText(P: TPlcProject; B: TBlock): string;
function BlockName(B: TBlock): string;   // FC1 "SpeedStats"
function NetText(B: TBlock; NI: Integer): string;
function DataBlockText(P: TPlcProject; D: TDataBlock; Live: TLiveFn): string;
function DataBlockCsv(D: TDataBlock; Live: TLiveFn): string;
function JsonText(J: TJSONData): string;   // formatted, and frees J
type
  TCsvRow = array of string;
  TCsvRows = array of TCsvRow;

{ a CSV text (a BOM, quotes, "" in quotes; the separator , ; or a tab, from the first line) }
function CsvRows(const Text: string): TCsvRows;
function CsvColumn(const Head: TCsvRow; const Words: array of string): Integer;   // -1 none
function CsvField(const S: string): string;
function CsvLine(const Fields: array of string): string;
procedure WriteUtf8File(const FileName, S: string; Bom: Boolean);

implementation

function CsvRows(const Text: string): TCsvRows;
var
  S: string;
  P, N: Integer;
  Sep: Char;
  InQ: Boolean;
  Cell: string;
  Row: TCsvRow;
  FirstLine: string;

  procedure EndCell;
  begin
    SetLength(Row, Length(Row) + 1);
    Row[High(Row)] := Cell;
    Cell := '';
  end;

  procedure EndRow;
  var
    K: Integer;
    Empty: Boolean;
  begin
    EndCell;
    Empty := True;
    for K := 0 to High(Row) do
      if Trim(Row[K]) <> '' then Empty := False;
    if not Empty then
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := Row;
    end;
    Row := nil;
  end;

begin
  Result := nil;
  S := Text;
  if Copy(S, 1, 3) = #$EF#$BB#$BF then Delete(S, 1, 3);
  // the separator: the one the first line has most of
  P := Pos(#10, S);
  if P = 0 then FirstLine := S else FirstLine := Copy(S, 1, P - 1);
  Sep := ',';
  N := 0;
  for P := 1 to Length(FirstLine) do if FirstLine[P] = ',' then Inc(N);
  if Length(FirstLine) - Length(StringReplace(FirstLine, ';', '', [rfReplaceAll])) > N then Sep := ';';
  if Length(FirstLine) - Length(StringReplace(FirstLine, #9, '', [rfReplaceAll])) >
    Length(FirstLine) - Length(StringReplace(FirstLine, string(Sep), '', [rfReplaceAll])) then Sep := #9;
  Cell := '';
  Row := nil;
  InQ := False;
  P := 1;
  while P <= Length(S) do
  begin
    if InQ then
    begin
      if S[P] = '"' then
      begin
        if (P < Length(S)) and (S[P + 1] = '"') then
        begin
          Cell := Cell + '"';
          Inc(P);
        end
        else
          InQ := False;
      end
      else
        Cell := Cell + S[P];
    end
    else if S[P] = '"' then InQ := True
    else if S[P] = Sep then EndCell
    else if S[P] = #10 then EndRow
    else if S[P] <> #13 then Cell := Cell + S[P];
    Inc(P);
  end;
  if (Cell <> '') or (Length(Row) > 0) then EndRow;
end;

function CsvColumn(const Head: TCsvRow; const Words: array of string): Integer;
var
  K, W: Integer;
begin
  for W := 0 to High(Words) do
    for K := 0 to High(Head) do
      if Pos(LowerCase(Words[W]), LowerCase(Trim(Head[K]))) > 0 then Exit(K);
  Result := -1;
end;

function CsvField(const S: string): string;
begin
  if (Pos(',', S) > 0) or (Pos('"', S) > 0) or (Pos(#10, S) > 0) or (Pos(#13, S) > 0) or (Pos(';', S) > 0) then
    Result := '"' + StringReplace(S, '"', '""', [rfReplaceAll]) + '"'
  else
    Result := S;
end;

function CsvLine(const Fields: array of string): string;
var
  K: Integer;
begin
  Result := '';
  for K := 0 to High(Fields) do
  begin
    if K > 0 then Result := Result + ',';
    Result := Result + CsvField(Fields[K]);
  end;
  Result := Result + #13#10;
end;

procedure WriteUtf8File(const FileName, S: string; Bom: Boolean);
var
  F: TFileStream;
  B: string;
begin
  F := TFileStream.Create(FileName, fmCreate);
  try
    if Bom then
    begin
      B := #$EF#$BB#$BF;
      F.WriteBuffer(B[1], 3);
    end;
    if S <> '' then F.WriteBuffer(S[1], Length(S));
  finally
    F.Free;
  end;
end;

function JsonText(J: TJSONData): string;
begin
  try
    Result := J.FormatJSON + LineEnding;
  finally
    J.Free;
  end;
end;

function Pad(const S: string; N: Integer): string;
begin
  Result := S;
  while Length(Result) < N do Result := Result + ' ';
  Result := Result + ' ';
end;

{ a LAD cell as text: the element, its operand, its parameters, a branch down }
function CellText(const Ce: TLadCell): string;
var
  K: Integer;
  Ps: string;
begin
  Result := LadKindIds[Ce.Kind];
  if LadHasType(Ce.Kind) then Result := Result + ' ' + DataTypeNames[Ce.DType];
  if LadHasType2(Ce.Kind) then Result := Result + ' to ' + DataTypeNames[Ce.DType2];
  if Ce.Kind = lkCmp then Result := Result + ' ' + CmpOpNames[Ce.Cmp];
  if Ce.Opnd <> '' then Result := Result + ' ' + Ce.Opnd;
  Ps := '';
  for K := 0 to LadParamCount(Ce.Kind) - 1 do
    if Ce.P[K] <> '' then Ps := Ps + IfThen(Ps <> '', ', ', '') + Ce.P[K];
  if (Ce.Kind = lkCall) and (Ce.Args <> '') then Ps := Ps + IfThen(Ps <> '', ', ', '') +
    StringReplace(Ce.Args, '|', ', ', [rfReplaceAll]);
  if Ps <> '' then Result := Result + ' (' + Ps + ')';
end;

function NetText(B: TBlock; NI: Integer): string;
var
  N: TNetwork;
  SL: TStringList;
  K, R, C: Integer;
  Ce: TLadCell;
  Row: string;
begin
  N := B.Net(NI);
  SL := TStringList.Create;
  try
    case N.Kind of
      nkSTL: SL.Add(Format('Network %d (STL): %s', [NI + 1, N.Title]));
      nkSCL: SL.Add(Format('Network %d (SCL): %s', [NI + 1, N.Title]));
    else
      SL.Add(Format('Network %d (LAD): %s', [NI + 1, N.Title]));
    end;
    if N.Comment <> '' then SL.Add('// ' + N.Comment);
    if N.Kind in [nkSTL, nkSCL] then
      for K := 0 to N.Stl.Count - 1 do SL.Add('  ' + N.Stl[K])
    else
      for R := 0 to N.Rows - 1 do
      begin
        // the elements of the row with their columns; a wire is only a line, ↓ a branch down
        Row := '';
        for C := 0 to N.Cols - 1 do
        begin
          Ce := N.Cell(R, C);
          if (Ce.Kind in [lkEmpty, lkWire]) and not Ce.Down then Continue;
          if Row <> '' then Row := Row + '  |  ';
          if Ce.Kind in [lkEmpty, lkWire] then Row := Row + Format('c%d ↓', [C])
          else Row := Row + Format('c%d %s', [C, CellText(Ce)]) + IfThen(Ce.Down, ' ↓', '');
        end;
        if Row <> '' then SL.Add(Format('  row %d:  %s', [R, Row]));
      end;
    Result := SL.Text;
  finally
    SL.Free;
  end;
end;

function BlockName(B: TBlock): string;
begin
  Result := Format('%s "%s"', [B.Title, B.Name]);
end;

{ the value of a variable: elementary types as they are, an IEC timer / counter by its outputs;
  structs and arrays have none }
function VarLive(const D: TDataBlock; const V: TDbVar; Live: TLiveFn): string;
var
  Op, Q, X: string;
begin
  Result := '';
  if not Assigned(Live) or V.IsArray or (V.DType = dtStruct) then Exit;
  Op := Format('"%s".%s', [D.Name, V.Name]);
  case V.DType of
    dtIECTimer:
      begin
        Q := Live(Op + '.Q');
        X := Live(Op + '.ET');
        if (Q <> '') or (X <> '') then Result := 'Q=' + Q + ' ET=' + X;
      end;
    dtIECCounter:
      begin
        X := Live(Op + '.CV');
        if X <> '' then Result := 'CV=' + X;
      end;
  else
    Result := Live(Op);
  end;
end;

function BlockText(P: TPlcProject; B: TBlock): string;
var
  SL: TStringList;
  K: Integer;
  V: TDbVar;
begin
  SL := TStringList.Create;
  try
    SL.Add(BlockName(B));
    SL.Add(StringOfChar('=', Length(BlockName(B))));
    SL.Add(Format('CPU: %s (%s)    project: %s', [P.Model.Name, FamilyNames[P.Family], P.Name]));
    if B.Comment <> '' then SL.Add('Comment: ' + B.Comment);
    if Length(B.Iface.Vars) > 0 then
    begin
      SL.Add('');
      SL.Add('Interface');
      SL.Add('  ' + Pad('Section', 8) + Pad('Name', 22) + Pad('Data type', 22) + Pad('Default', 12) + 'Comment');
      for K := 0 to High(B.Iface.Vars) do
      begin
        V := B.Iface.Vars[K];
        SL.Add('  ' + Pad(SectionNames[V.Section], 8) + Pad(V.Name, 22) + Pad(V.TypeText, 22) + Pad(V.Start, 12) + V.Comment);
      end;
    end;
    for K := 0 to B.NetCount - 1 do
    begin
      SL.Add('');
      SL.Text := SL.Text + NetText(B, K);
    end;
    Result := SL.Text;
  finally
    SL.Free;
  end;
end;

function DataBlockText(P: TPlcProject; D: TDataBlock; Live: TLiveFn): string;
var
  SL: TStringList;
  K: Integer;
  V: TDbVar;
  Lv: string;
begin
  SL := TStringList.Create;
  try
    if D.IsUdt then SL.Add(Format('PLC data type UDT%d "%s"', [D.Number, D.Name]))
    else if D.InstanceOf > 0 then SL.Add(Format('DB%d "%s"  (instance of FB%d)', [D.Number, D.Name, D.InstanceOf]))
    else SL.Add(Format('DB%d "%s"', [D.Number, D.Name]));
    SL.Add(StringOfChar('=', Length(SL[0])));
    D.Layout;
    SL.Add(Format('CPU: %s    %d bytes%s', [P.Model.Name, D.Size, IfThen(not D.IsUdt and D.Optimized, ', optimized', '')]));
    if D.Comment <> '' then SL.Add('Comment: ' + D.Comment);
    SL.Add('');
    if D.IsUdt then
      SL.Add(Pad('Offset', 8) + Pad('Name', 22) + Pad('Data type', 22) + Pad('Default', 14) + 'Comment')
    else
      SL.Add(Pad('Offset', 8) + Pad('Name', 22) + Pad('Data type', 22) + Pad('Start', 14) + Pad('Value', 16) + 'Comment');
    for K := 0 to High(D.Vars) do
    begin
      V := D.Vars[K];
      if D.IsUdt then Lv := '' else Lv := VarLive(D, V, Live);
      if V.DType = dtBool then
        SL.Add(Pad(Format('%d.%d', [V.Ofs, V.Bit]), 8) + Pad(V.Name, 22) + Pad(V.TypeText, 22) + Pad(V.Start, 14) +
          IfThen(D.IsUdt, '', Pad(Lv, 16)) + V.Comment)
      else
        SL.Add(Pad(Format('%d.0', [V.Ofs]), 8) + Pad(V.Name, 22) + Pad(V.TypeText, 22) + Pad(V.Start, 14) +
          IfThen(D.IsUdt, '', Pad(Lv, 16)) + V.Comment);
    end;
    Result := SL.Text;
  finally
    SL.Free;
  end;
end;

function DataBlockCsv(D: TDataBlock; Live: TLiveFn): string;
var
  K: Integer;
  V: TDbVar;
  Lv, Ofs: string;
begin
  D.Layout;
  if D.IsUdt then Result := CsvLine(['Offset', 'Name', 'Data type', 'Default', 'Comment'])
  else Result := CsvLine(['Offset', 'Name', 'Data type', 'Start value', 'Monitor value', 'Retain', 'Comment']);
  for K := 0 to High(D.Vars) do
  begin
    V := D.Vars[K];
    if V.DType = dtBool then Ofs := Format('%d.%d', [V.Ofs, V.Bit]) else Ofs := Format('%d.0', [V.Ofs]);
    if D.IsUdt then
      Result := Result + CsvLine([Ofs, V.Name, V.TypeText, V.Start, V.Comment])
    else
    begin
      Lv := VarLive(D, V, Live);
      Result := Result + CsvLine([Ofs, V.Name, V.TypeText, V.Start, Lv, IfThen(V.Retain, 'yes', ''), V.Comment]);
    end;
  end;
end;

end.
