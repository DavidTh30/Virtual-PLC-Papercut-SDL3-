unit uTables;

{ A table (rows of cells, the first row is the head) as a file: CSV (UTF-8 with a BOM, for Excel), XLSX (an
  Excel workbook: one sheet, the head bold and frozen, every cell text so a value comes back as it was) or XML
  (an element per row, the columns as attributes). The kind of file goes by its extension. Reading takes the
  three back: an XLSX of Excel too (shared strings, numbers, booleans), an XML with the columns as attributes
  or as child elements.
  And what the tables of the Virtual PLC are: the variables of a data block / the members of a data type
  (merged into it by their names) and the rows of the watch table (added). }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, StrUtils, Math, zipper, DOM, XMLRead, uPlcTypes, uPlcProject, uPlcExport;

type
  TTableKind = (tkCsv, tkXlsx, tkXml);

function TableKindOf(const FileName: string): TTableKind;
{ Title: the name of the sheet / of the root element's table attribute; Name: what the table is of (a DB name) }
procedure WriteTable(const FileName: string; const Rows: TCsvRows; const Title, Name: string);
function ReadTable(const FileName: string; out Rows: TCsvRows; out Err: string): Boolean;
{ the column whose head is one of Words (spaces, '/' and case do not count: "Data type" = DataType); -1 none }
function TableColumn(const Head: TCsvRow; const Words: array of string): Integer;
{ the variables of the table into the data block / data type: a name there is changed (type, start value,
  retain, comment), a new one added at the end; '' or the problem; Added / Changed: how many }
function ImportDbRows(D: TDataBlock; const Rows: TCsvRows; out Added, Changed: Integer): string;
{ the rows of the table added to the watch table: their address, format, modify value; the number added
  (-1: no address column) }
function ImportWatchRows(P: TPlcProject; const Rows: TCsvRows): Integer;
{ the PLC tags (this program's export or TIA's PLC tags: Name, Path, Data type, (Logical) Address, Comment; no head:
  Name, Data type, Address, Comment): a tag of the same name is updated, a new one added, Path its group }
procedure ImportTagRows(P: TPlcProject; const Rows: TCsvRows; out Added, Updated: Integer);
{ XML names for the columns: Data type -> DataType, # -> No }
function XmlName(const Head: string): string;

implementation

function TableKindOf(const FileName: string): TTableKind;
begin
  case LowerCase(ExtractFileExt(FileName)) of
    '.xlsx', '.xlsm': Result := tkXlsx;
    '.xml': Result := tkXml;
  else
    Result := tkCsv;
  end;
end;

function Esc(const S: string): string;
var
  K: Integer;
begin
  Result := '';
  for K := 1 to Length(S) do
    case S[K] of
      '&': Result := Result + '&amp;';
      '<': Result := Result + '&lt;';
      '>': Result := Result + '&gt;';
      '"': Result := Result + '&quot;';
      #9: Result := Result + '&#9;';
      #10: Result := Result + '&#10;';
      #13: ;
      #0..#8, #11, #12, #14..#31: ;
    else
      Result := Result + S[K];
    end;
end;

function XmlName(const Head: string): string;
var
  K: Integer;
  Up: Boolean;
begin
  // the words joined, each with a capital: "Address / symbol" -> AddressSymbol
  Result := '';
  Up := True;
  for K := 1 to Length(Head) do
    if Head[K] in ['A'..'Z', 'a'..'z', '0'..'9', '_'] then
    begin
      if Up then Result := Result + UpCase(Head[K]) else Result := Result + Head[K];
      Up := False;
    end
    else Up := True;
  if Result = '' then Result := 'No';
  if Result[1] in ['0'..'9'] then Result := 'C' + Result;
end;

function Norm(const S: string): string;
var
  K: Integer;
begin
  Result := '';
  for K := 1 to Length(S) do
    if S[K] in ['A'..'Z', 'a'..'z', '0'..'9'] then Result := Result + LowerCase(S[K]);
end;

function TableColumn(const Head: TCsvRow; const Words: array of string): Integer;
var
  K, W: Integer;
begin
  for W := 0 to High(Words) do
    for K := 0 to High(Head) do
      if Norm(Head[K]) = Norm(Words[W]) then Exit(K);
  Result := -1;
end;

{ ---------- XLSX ---------- }

function ColName(C: Integer): string;
begin
  Result := '';
  Inc(C);
  while C > 0 do
  begin
    Result := Chr(Ord('A') + (C - 1) mod 26) + Result;
    C := (C - 1) div 26;
  end;
end;

procedure WriteXlsx(const FileName: string; const Rows: TCsvRows; const Title: string);
const
  CT = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
    '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">' +
    '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>' +
    '<Default Extension="xml" ContentType="application/xml"/>' +
    '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>' +
    '<Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>' +
    '<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>' +
    '<Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>' +
    '</Types>';
  Rels = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
    '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' +
    '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>' +
    '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>' +
    '</Relationships>';
  WbRels = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
    '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' +
    '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>' +
    '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>' +
    '</Relationships>';
  Styles = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
    '<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">' +
    '<fonts count="2"><font><sz val="11"/><name val="Calibri"/></font><font><b/><sz val="11"/><name val="Calibri"/></font></fonts>' +
    '<fills count="3"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill>' +
    '<fill><patternFill patternType="solid"><fgColor rgb="FFF3E2B8"/><bgColor indexed="64"/></patternFill></fill></fills>' +
    '<borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>' +
    '<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>' +
    '<cellXfs count="2"><xf numFmtId="49" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>' +
    '<xf numFmtId="49" fontId="1" fillId="2" borderId="0" xfId="0" applyNumberFormat="1" applyFont="1" applyFill="1"/></cellXfs>' +
    '<cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>' +
    '</styleSheet>';
var
  Z: TZipper;
  Sheet, Wb, Core, Cols, Nm: string;
  R, C, NC: Integer;
  W: array of Integer;
  Parts: array[0..6] of TStringStream;
  K: Integer;
begin
  // the widest text of each column (in characters) for its width
  NC := 0;
  for R := 0 to High(Rows) do
    if Length(Rows[R]) > NC then NC := Length(Rows[R]);
  SetLength(W, NC);
  for R := 0 to High(Rows) do
    for C := 0 to High(Rows[R]) do
      if Length(Rows[R][C]) > W[C] then W[C] := Length(Rows[R][C]);
  Cols := '';
  for C := 0 to NC - 1 do
    Cols := Cols + Format('<col min="%d" max="%d" width="%d" customWidth="1"/>', [C + 1, C + 1, Min(60, Max(8, W[C] + 2))]);
  Sheet := '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
    '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">' +
    '<sheetViews><sheetView workbookViewId="0"><pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/>' +
    '</sheetView></sheetViews>';
  if Cols <> '' then Sheet := Sheet + '<cols>' + Cols + '</cols>';
  Sheet := Sheet + '<sheetData>';
  for R := 0 to High(Rows) do
  begin
    Sheet := Sheet + Format('<row r="%d">', [R + 1]);
    for C := 0 to High(Rows[R]) do
      Sheet := Sheet + Format('<c r="%s%d" t="inlineStr" s="%d"><is><t xml:space="preserve">%s</t></is></c>',
        [ColName(C), R + 1, Ord(R = 0), Esc(Rows[R][C])]);
    Sheet := Sheet + '</row>';
  end;
  Sheet := Sheet + '</sheetData></worksheet>';
  // a sheet name: at most 31 characters, none of \ / ? * [ ] :
  Nm := Title;
  for K := 1 to Length(Nm) do
    if Nm[K] in ['\', '/', '?', '*', '[', ']', ':'] then Nm[K] := '_';
  if Nm = '' then Nm := 'Sheet1';
  if Length(Nm) > 31 then Nm := Copy(Nm, 1, 31);
  Wb := '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
    '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" ' +
    'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">' +
    '<sheets><sheet name="' + Esc(Nm) + '" sheetId="1" r:id="rId1"/></sheets></workbook>';
  Core := '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
    '<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" ' +
    'xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" ' +
    'xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">' +
    '<dc:title>' + Esc(Title) + '</dc:title><dc:creator>Virtual PLC</dc:creator></cp:coreProperties>';
  Parts[0] := TStringStream.Create(CT);
  Parts[1] := TStringStream.Create(Rels);
  Parts[2] := TStringStream.Create(Wb);
  Parts[3] := TStringStream.Create(WbRels);
  Parts[4] := TStringStream.Create(Styles);
  Parts[5] := TStringStream.Create(Sheet);
  Parts[6] := TStringStream.Create(Core);
  Z := TZipper.Create;
  try
    Z.FileName := FileName;
    Z.Entries.AddFileEntry(Parts[0], '[Content_Types].xml');
    Z.Entries.AddFileEntry(Parts[1], '_rels/.rels');
    Z.Entries.AddFileEntry(Parts[2], 'xl/workbook.xml');
    Z.Entries.AddFileEntry(Parts[3], 'xl/_rels/workbook.xml.rels');
    Z.Entries.AddFileEntry(Parts[4], 'xl/styles.xml');
    Z.Entries.AddFileEntry(Parts[5], 'xl/worksheets/sheet1.xml');
    Z.Entries.AddFileEntry(Parts[6], 'docProps/core.xml');
    Z.ZipAllFiles;
  finally
    Z.Free;
    for K := 0 to High(Parts) do Parts[K].Free;
  end;
end;

type
  { the files of a zip into memory }
  TZipMem = class
  public
    Names: TStringList;
    constructor Create;
    destructor Destroy; override;
    procedure DoCreate(Sender: TObject; var AStream: TStream; AItem: TFullZipFileEntry);
    procedure DoDone(Sender: TObject; var AStream: TStream; AItem: TFullZipFileEntry);
    function Get(const Name: string): TStream;
  end;

constructor TZipMem.Create;
begin
  inherited Create;
  Names := TStringList.Create;
  Names.OwnsObjects := True;
  Names.CaseSensitive := False;
end;

destructor TZipMem.Destroy;
begin
  Names.Free;
  inherited Destroy;
end;

procedure TZipMem.DoCreate(Sender: TObject; var AStream: TStream; AItem: TFullZipFileEntry);
begin
  AStream := TMemoryStream.Create;
end;

procedure TZipMem.DoDone(Sender: TObject; var AStream: TStream; AItem: TFullZipFileEntry);
begin
  AStream.Position := 0;
  Names.AddObject(StringReplace(AItem.ArchiveFileName, '\', '/', [rfReplaceAll]), AStream);
  AStream := nil;
end;

function TZipMem.Get(const Name: string): TStream;
var
  K: Integer;
begin
  K := Names.IndexOf(Name);
  if K < 0 then Exit(nil);
  Result := TStream(Names.Objects[K]);
  Result.Position := 0;
end;

function LocalName(N: TDOMNode): string;
begin
  Result := UTF8Encode(N.NodeName);
  if Pos(':', Result) > 0 then Result := Copy(Result, Pos(':', Result) + 1, MaxInt);
end;

function Txt(N: TDOMNode): string;
begin
  Result := UTF8Encode(N.TextContent);
end;

function Attr(N: TDOMNode; const Name: string): string;
var
  K: Integer;
begin
  Result := '';
  if (N = nil) or (N.Attributes = nil) then Exit;
  for K := 0 to N.Attributes.Length - 1 do
    if LocalName(N.Attributes[K]) = Name then Exit(UTF8Encode(N.Attributes[K].NodeValue));
end;

{ the elements of a local name under N (any depth) }
procedure Collect(N: TDOMNode; const Name: string; L: TFPList);
var
  C: TDOMNode;
begin
  C := N.FirstChild;
  while C <> nil do
  begin
    if C.NodeType = ELEMENT_NODE then
    begin
      if LocalName(C) = Name then L.Add(C) else Collect(C, Name, L);
    end;
    C := C.NextSibling;
  end;
end;

{ the text of the <t> elements under N (a rich text has several runs) }
function TextOf(N: TDOMNode): string;
var
  L: TFPList;
  K: Integer;
begin
  Result := '';
  L := TFPList.Create;
  try
    Collect(N, 't', L);
    for K := 0 to L.Count - 1 do Result := Result + Txt(TDOMNode(L[K]));
  finally
    L.Free;
  end;
end;

function ColIndex(const Ref: string): Integer;
var
  K: Integer;
begin
  Result := 0;
  for K := 1 to Length(Ref) do
    if Ref[K] in ['A'..'Z'] then Result := Result * 26 + Ord(Ref[K]) - Ord('A') + 1
    else if Ref[K] in ['a'..'z'] then Result := Result * 26 + Ord(Ref[K]) - Ord('a') + 1
    else Break;
  Dec(Result);
end;

function ReadXlsx(const FileName: string; out Rows: TCsvRows; out Err: string): Boolean;
var
  U: TUnZipper;
  M: TZipMem;
  Doc: TXMLDocument;
  Shared: TStringList;
  L, Cs: TFPList;
  S: TStream;
  Path, Rid, V, T, Base: string;
  K, J, R, C, Last: Integer;
  N: TDOMNode;
begin
  Result := False;
  Rows := nil;
  Err := '';
  M := TZipMem.Create;
  Shared := TStringList.Create;
  U := TUnZipper.Create;
  try
    try
      U.FileName := FileName;
      U.OnCreateStream := @M.DoCreate;
      U.OnDoneStream := @M.DoDone;
      U.UnZipAllFiles;
    except
      on E: Exception do
      begin
        Err := 'not an Excel workbook (' + E.Message + ')';
        Exit;
      end;
    end;
    // the first sheet: from the workbook and its relations, else sheet1
    Path := 'xl/worksheets/sheet1.xml';
    S := M.Get('xl/workbook.xml');
    if S <> nil then
    begin
      ReadXMLFile(Doc, S);
      try
        L := TFPList.Create;
        try
          Collect(Doc, 'sheet', L);
          Rid := '';
          if L.Count > 0 then Rid := Attr(TDOMNode(L[0]), 'id');
        finally
          L.Free;
        end;
      finally
        Doc.Free;
      end;
      S := M.Get('xl/_rels/workbook.xml.rels');
      if (S <> nil) and (Rid <> '') then
      begin
        ReadXMLFile(Doc, S);
        try
          L := TFPList.Create;
          try
            Collect(Doc, 'Relationship', L);
            for K := 0 to L.Count - 1 do
              if Attr(TDOMNode(L[K]), 'Id') = Rid then
              begin
                T := Attr(TDOMNode(L[K]), 'Target');
                if Copy(T, 1, 1) = '/' then Path := Copy(T, 2, MaxInt)
                else Path := 'xl/' + T;
              end;
          finally
            L.Free;
          end;
        finally
          Doc.Free;
        end;
      end;
    end;
    // the shared strings
    S := M.Get('xl/sharedStrings.xml');
    if S <> nil then
    begin
      ReadXMLFile(Doc, S);
      try
        L := TFPList.Create;
        try
          Collect(Doc, 'si', L);
          for K := 0 to L.Count - 1 do Shared.Add(TextOf(TDOMNode(L[K])));
        finally
          L.Free;
        end;
      finally
        Doc.Free;
      end;
    end;
    S := M.Get(Path);
    if S = nil then
    begin
      Err := 'the workbook has no sheet ' + Path;
      Exit;
    end;
    ReadXMLFile(Doc, S);
    try
      L := TFPList.Create;
      Cs := TFPList.Create;
      try
        Collect(Doc, 'row', L);
        Last := -1;
        for K := 0 to L.Count - 1 do
        begin
          // a row number: the empty rows before it stay (as empty rows)
          R := StrToIntDef(Attr(TDOMNode(L[K]), 'r'), Last + 2) - 1;
          if R <= Last then R := Last + 1;
          while Length(Rows) < R do
          begin
            SetLength(Rows, Length(Rows) + 1);
            Rows[High(Rows)] := nil;
          end;
          SetLength(Rows, R + 1);
          Rows[R] := nil;
          Last := R;
          Cs.Clear;
          Collect(TDOMNode(L[K]), 'c', Cs);
          C := -1;
          for J := 0 to Cs.Count - 1 do
          begin
            N := TDOMNode(Cs[J]);
            if Attr(N, 'r') <> '' then C := ColIndex(Attr(N, 'r')) else Inc(C);
            T := Attr(N, 't');
            if T = 'inlineStr' then V := TextOf(N)
            else
            begin
              V := '';
              Base := '';
              if TDOMElement(N).FindNode('v') <> nil then V := Txt(TDOMElement(N).FindNode('v'))
              else if N.FirstChild <> nil then
              begin
                // a prefixed <x:v>
                N := N.FirstChild;
                while (N <> nil) and (LocalName(N) <> 'v') do N := N.NextSibling;
                if N <> nil then V := Txt(N);
              end;
              if T = 's' then
              begin
                if (StrToIntDef(V, -1) >= 0) and (StrToIntDef(V, -1) < Shared.Count) then V := Shared[StrToInt(V)]
                else V := '';
              end
              else if T = 'b' then
              begin
                if V = '1' then V := 'TRUE' else V := 'FALSE';
              end;
              if Base = '' then ;
            end;
            if C < 0 then Continue;
            while Length(Rows[R]) <= C do
            begin
              SetLength(Rows[R], Length(Rows[R]) + 1);
              Rows[R][High(Rows[R])] := '';
            end;
            Rows[R][C] := V;
          end;
        end;
      finally
        L.Free;
        Cs.Free;
      end;
    finally
      Doc.Free;
    end;
    Result := True;
  finally
    U.Free;
    Shared.Free;
    M.Free;
  end;
end;

{ ---------- XML ---------- }

procedure WriteXml(const FileName: string; const Rows: TCsvRows; const Title, Name: string);
var
  S: string;
  R, C: Integer;
  Names: array of string;
begin
  SetLength(Names, 0);
  if Length(Rows) > 0 then
  begin
    SetLength(Names, Length(Rows[0]));
    for C := 0 to High(Rows[0]) do Names[C] := XmlName(Rows[0][C]);
  end;
  S := '<?xml version="1.0" encoding="UTF-8"?>' + LineEnding;
  S := S + Format('<VirtualPLC table="%s" name="%s">', [Esc(Title), Esc(Name)]) + LineEnding;
  for R := 1 to High(Rows) do
  begin
    S := S + '  <Row';
    for C := 0 to Min(High(Rows[R]), High(Names)) do S := S + Format(' %s="%s"', [Names[C], Esc(Rows[R][C])]);
    S := S + '/>' + LineEnding;
  end;
  S := S + '</VirtualPLC>' + LineEnding;
  WriteUtf8File(FileName, S, False);
end;

function ReadXmlTable(const FileName: string; out Rows: TCsvRows; out Err: string): Boolean;
var
  Doc: TXMLDocument;
  E, C: TDOMNode;
  Head: TStringList;
  Vals: TStringList;
  K, R, Ix: Integer;
begin
  Result := False;
  Rows := nil;
  Err := '';
  try
    ReadXMLFile(Doc, FileName);
  except
    on Ex: Exception do
    begin
      Err := 'not an XML file (' + Ex.Message + ')';
      Exit;
    end;
  end;
  Head := TStringList.Create;
  Vals := TStringList.Create;
  try
    if Doc.DocumentElement = nil then
    begin
      Err := 'the XML file is empty';
      Exit;
    end;
    // the rows: the elements under the root; their columns: the attributes (or the child elements)
    SetLength(Rows, 1);
    E := Doc.DocumentElement.FirstChild;
    while E <> nil do
    begin
      if E.NodeType = ELEMENT_NODE then
      begin
        Vals.Clear;
        if (E.Attributes <> nil) and (E.Attributes.Length > 0) then
          for K := 0 to E.Attributes.Length - 1 do
            Vals.Values[LocalName(E.Attributes[K])] := '#' + UTF8Encode(E.Attributes[K].NodeValue)
        else
        begin
          C := E.FirstChild;
          while C <> nil do
          begin
            if C.NodeType = ELEMENT_NODE then Vals.Values[LocalName(C)] := '#' + Txt(C);
            C := C.NextSibling;
          end;
        end;
        R := Length(Rows);
        SetLength(Rows, R + 1);
        Rows[R] := nil;
        for K := 0 to Vals.Count - 1 do
        begin
          Ix := Head.IndexOf(Vals.Names[K]);
          if Ix < 0 then Ix := Head.Add(Vals.Names[K]);
          while Length(Rows[R]) <= Ix do
          begin
            SetLength(Rows[R], Length(Rows[R]) + 1);
            Rows[R][High(Rows[R])] := '';
          end;
          Rows[R][Ix] := Copy(Vals.ValueFromIndex[K], 2, MaxInt);
        end;
      end;
      E := E.NextSibling;
    end;
    SetLength(Rows[0], Head.Count);
    for K := 0 to Head.Count - 1 do Rows[0][K] := Head[K];
    Result := True;
  finally
    Head.Free;
    Vals.Free;
    Doc.Free;
  end;
end;

{ ---------- the file ---------- }

procedure WriteTable(const FileName: string; const Rows: TCsvRows; const Title, Name: string);
var
  S: string;
  R: Integer;
begin
  case TableKindOf(FileName) of
    tkXlsx: WriteXlsx(FileName, Rows, Title);
    tkXml: WriteXml(FileName, Rows, Title, Name);
  else
    begin
      S := '';
      for R := 0 to High(Rows) do S := S + CsvLine(Rows[R]);
      WriteUtf8File(FileName, S, True);
    end;
  end;
end;

function ReadTable(const FileName: string; out Rows: TCsvRows; out Err: string): Boolean;
var
  L: TStringList;
  S: string;
begin
  Rows := nil;
  Err := '';
  if not FileExists(FileName) then
  begin
    Err := 'no such file';
    Exit(False);
  end;
  case TableKindOf(FileName) of
    tkXlsx: Result := ReadXlsx(FileName, Rows, Err);
    tkXml: Result := ReadXmlTable(FileName, Rows, Err);
  else
    begin
      L := TStringList.Create;
      try
        L.LoadFromFile(FileName);
        S := L.Text;
      finally
        L.Free;
      end;
      // the BOM of a UTF-8 file
      if Copy(S, 1, 3) = #$EF#$BB#$BF then Delete(S, 1, 3);
      Rows := CsvRows(S);
      Result := True;
    end;
  end;
  if Result and (Length(Rows) = 0) then
  begin
    Err := 'the file is empty';
    Result := False;
  end;
end;

{ ---------- the tables of the Virtual PLC ---------- }

function ImportDbRows(D: TDataBlock; const Rows: TCsvRows; out Added, Changed: Integer): string;
var
  CN, CT, CS, CR, CC, R, K: Integer;
  Nm: string;

  function Cell(C: Integer): string;
  begin
    if (C >= 0) and (C <= High(Rows[R])) then Result := Trim(Rows[R][C]) else Result := '';
  end;

begin
  Result := '';
  Added := 0;
  Changed := 0;
  if D.InstanceOf > 0 then Exit('an instance DB has the variables of its FB: change the FB interface');
  if Length(Rows) = 0 then Exit('the file is empty');
  CN := TableColumn(Rows[0], ['Name', 'Variable', 'Member', 'Symbol']);
  CT := TableColumn(Rows[0], ['Data type', 'Type', 'DataType']);
  CS := TableColumn(Rows[0], ['Start value', 'Default', 'Default value', 'Start', 'Initial value']);
  CR := TableColumn(Rows[0], ['Retain', 'Retentive', 'Remanence']);
  CC := TableColumn(Rows[0], ['Comment', 'Description']);
  if (CN < 0) or (CT < 0) then Exit('the table needs the columns Name and Data type');
  for R := 1 to High(Rows) do
  begin
    Nm := Cell(CN);
    if Nm = '' then Continue;
    // the type as written (an unknown one: the Data blocks screen marks it)
    K := D.FindVar(Nm);
    if K < 0 then
    begin
      D.AddVar(Nm, Cell(CT), Cell(CS), Cell(CC));
      K := High(D.Vars);
      Inc(Added);
    end
    else
    begin
      D.Vars[K].TypeText := Cell(CT);
      if CS >= 0 then D.Vars[K].Start := Cell(CS);
      if CC >= 0 then D.Vars[K].Comment := Cell(CC);
      Inc(Changed);
    end;
    if CR >= 0 then
      D.Vars[K].Retain := MatchText(Cell(CR), ['yes', 'true', '1', 'x', 'retain', 'ja']);
  end;
  D.Layout;
end;

procedure ImportTagRows(P: TPlcProject; const Rows: TCsvRows; out Added, Updated: Integer);
var
  CN, CT, CA, CC, CP, I, J, K, G, First: Integer;
  Nm, Gn: string;

  function Cell(R, C: Integer): string;
  begin
    if (C >= 0) and (C <= High(Rows[R])) then Result := Trim(Rows[R][C]) else Result := '';
  end;

begin
  Added := 0;
  Updated := 0;
  if Length(Rows) = 0 then Exit;
  CN := TableColumn(Rows[0], ['Name', 'Symbol']);
  CT := TableColumn(Rows[0], ['Data type', 'Type']);
  CA := TableColumn(Rows[0], ['Logical address', 'Address']);
  CC := TableColumn(Rows[0], ['Comment']);
  CP := TableColumn(Rows[0], ['Path', 'Group', 'Tag table']);
  First := 1;
  if (CN < 0) or (CA < 0) then
  begin
    // no head line: Name, Data type, Address, Comment
    CN := 0;
    CT := 1;
    CA := 2;
    CC := 3;
    CP := -1;
    First := 0;
  end;
  for I := First to High(Rows) do
  begin
    Nm := Cell(I, CN);
    if Nm = '' then Continue;
    K := P.FindTag(Nm);
    if K >= 0 then
    begin
      if Cell(I, CT) <> '' then P.Tags[K].TypeText := Cell(I, CT);
      if Cell(I, CA) <> '' then P.Tags[K].Address := Cell(I, CA);
      if CC >= 0 then P.Tags[K].Comment := Cell(I, CC);
      Inc(Updated);
    end
    else
    begin
      if Cell(I, CT) <> '' then P.AddTag(Nm, Cell(I, CT), Cell(I, CA), Cell(I, CC))
      else P.AddTag(Nm, 'Bool', Cell(I, CA), Cell(I, CC));
      K := High(P.Tags);
      Inc(Added);
    end;
    // Path / Group: into that group (made when it is new); TIA's default table and the root: none
    Gn := Cell(I, CP);
    if (CP >= 0) and (Gn <> '') and not SameText(Gn, AllTagsName) and not SameText(Gn, 'Default tag table') then
    begin
      G := -1;
      for J := 0 to High(P.TagGroups) do
        if (G < 0) and SameText(P.TagGroups[J].Name, Gn) then G := J;
      if G < 0 then G := GroupAdd(P.TagGroups, Gn);
      P.Tags[K].GroupId := P.TagGroups[G].Id;
    end;
  end;
  if Added + Updated > 0 then P.Modified := True;
end;

function ImportWatchRows(P: TPlcProject; const Rows: TCsvRows): Integer;
var
  CA, CF, CM, CO, I, First: Integer;
  F: TDispFmt;
  A: string;

  function Cell(R, C: Integer): string;
  begin
    if (C >= 0) and (C <= High(Rows[R])) then Result := Trim(Rows[R][C]) else Result := '';
  end;

begin
  Result := 0;
  if Length(Rows) = 0 then Exit;
  CA := TableColumn(Rows[0], ['Address / symbol', 'Address', 'Operand', 'Name', 'Symbol']);
  CF := TableColumn(Rows[0], ['Format', 'Display', 'Display format']);
  CM := TableColumn(Rows[0], ['Modify value', 'Modify']);
  CO := TableColumn(Rows[0], ['Modify on', 'Mod']);
  if (CM >= 0) and (CO = CM) then CO := -1;
  if CO < 0 then
    for I := 0 to High(Rows[0]) do
      if (I <> CM) and SameText(Trim(Rows[0][I]), 'Modify') then CO := I;
  First := 1;
  if CA < 0 then
  begin
    // no head: the first column, every row
    CA := 0;
    First := 0;
  end;
  for I := First to High(Rows) do
  begin
    A := Cell(I, CA);
    if A = '' then Continue;
    P.AddWatch(A, dfDec, Cell(I, CM));
    P.Watch[High(P.Watch)].Fmt := dfDec;
    for F := Low(TDispFmt) to High(TDispFmt) do
      if SameText(DispFmtNames[F], Cell(I, CF)) then P.Watch[High(P.Watch)].Fmt := F;
    if CO >= 0 then P.Watch[High(P.Watch)].ModifyOn := MatchText(Cell(I, CO), ['yes', 'true', '1', 'x']);
    Inc(Result);
  end;
  if Result > 0 then P.Modified := True;
end;

end.
