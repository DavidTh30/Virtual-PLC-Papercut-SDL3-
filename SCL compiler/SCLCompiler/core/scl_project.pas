{ SCL Compiler - project model: CPU, source files, PLC tags / symbols, block numbers }
unit scl_project;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, contnrs, IniFiles, scl_base;

type
  TPlcTag = class
  public
    Name: string;
    DataType: string;
    Address: string;     // %I0.0 ...  ('' = user constant)
    Value: string;       // user constant value
    Comment: string;
    TableName: string;
    function IsConstant: Boolean;
  end;

  TSclProject = class
  private
    FFileName: string;
    function GetDir: string;
  public
    Name: string;
    Cpu: TCpuFamily;
    Sources: TStringList;       // relative paths of .scl files
    TagFiles: TStringList;      // relative paths of tag CSV files
    Tags: TObjectList;          // TPlcTag
    BlockNumbers: TStringList;  // Name=Number (FB/FC/DB/OB/UDT)
    CyclicIntervals: TStringList; // OB name=interval ms
    OutputDir: string;
    Modified: Boolean;
    constructor Create;
    destructor Destroy; override;
    procedure Clear;
    procedure LoadFromFile(const FN: string);
    procedure SaveToFile(const FN: string);
    function AbsPath(const Rel: string): string;
    function RelPath(const Abs: string): string;
    function Tag(I: Integer): TPlcTag;
    function FindTag(const AName: string): TPlcTag;
    procedure LoadTagsCsv(const FN: string; const ATable: string);
    procedure SaveTagsCsv(const FN: string; const ATable: string);
    procedure ReloadTags;
    procedure SaveTags;
    function OutputFile: string;
    function BlockNumber(const AName: string): Integer;
    procedure SetBlockNumber(const AName: string; ANum: Integer);
    property FileName: string read FFileName write FFileName;
    property Dir: string read GetDir;
  end;

function SplitCsvLine(const S: string; Delim: Char): TStringArray;
function DetectCsvDelimiter(const Header: string): Char;

implementation

function TPlcTag.IsConstant: Boolean;
begin
  Result := (Trim(Address) = '') and (Trim(Value) <> '');
end;

constructor TSclProject.Create;
begin
  inherited;
  Sources := TStringList.Create;
  TagFiles := TStringList.Create;
  Tags := TObjectList.Create(True);
  BlockNumbers := TStringList.Create;
  CyclicIntervals := TStringList.Create;
  Clear;
end;

destructor TSclProject.Destroy;
begin
  Sources.Free;
  TagFiles.Free;
  Tags.Free;
  BlockNumbers.Free;
  CyclicIntervals.Free;
  inherited;
end;

procedure TSclProject.Clear;
begin
  Name := 'NewProject';
  Cpu := cpuS7_1200;
  Sources.Clear;
  TagFiles.Clear;
  Tags.Clear;
  BlockNumbers.Clear;
  CyclicIntervals.Clear;
  OutputDir := 'output';
  FFileName := '';
  Modified := False;
end;

function TSclProject.GetDir: string;
begin
  if FFileName = '' then Result := GetCurrentDir else Result := ExtractFileDir(FFileName);
end;

function TSclProject.AbsPath(const Rel: string): string;
begin
  if (Rel <> '') and ((Pos(':', Rel) > 0) or (Rel[1] in ['\', '/'])) then Result := Rel
  else Result := ExpandFileName(IncludeTrailingPathDelimiter(Dir) + Rel);
end;

function TSclProject.RelPath(const Abs: string): string;
begin
  Result := ExtractRelativePath(IncludeTrailingPathDelimiter(Dir), Abs);
end;

function TSclProject.Tag(I: Integer): TPlcTag;
begin
  Result := TPlcTag(Tags[I]);
end;

function TSclProject.FindTag(const AName: string): TPlcTag;
var
  I: Integer;
begin
  for I := 0 to Tags.Count - 1 do
    if CompareText(Tag(I).Name, AName) = 0 then Exit(Tag(I));
  Result := nil;
end;

procedure TSclProject.LoadFromFile(const FN: string);
var
  Ini: TIniFile;
  L: TStringList;
  I: Integer;
begin
  Clear;
  FFileName := ExpandFileName(FN);
  Ini := TIniFile.Create(FFileName);
  L := TStringList.Create;
  try
    Name := Ini.ReadString('Project', 'Name', ChangeFileExt(ExtractFileName(FN), ''));
    CpuFromName(Ini.ReadString('Project', 'CPU', 'S7-1200'), Cpu);
    OutputDir := Ini.ReadString('Project', 'OutputDir', 'output');
    Ini.ReadSectionValues('Sources', L);
    for I := 0 to L.Count - 1 do Sources.Add(L.ValueFromIndex[I]);
    L.Clear;
    Ini.ReadSectionValues('Tags', L);
    for I := 0 to L.Count - 1 do TagFiles.Add(L.ValueFromIndex[I]);
    Ini.ReadSectionValues('BlockNumbers', BlockNumbers);
    Ini.ReadSectionValues('CyclicInterval', CyclicIntervals);
  finally
    L.Free;
    Ini.Free;
  end;
  ReloadTags;
  Modified := False;
end;

procedure TSclProject.SaveToFile(const FN: string);
var
  L: TStringList;
  I: Integer;
begin
  FFileName := ExpandFileName(FN);
  L := TStringList.Create;
  try
    L.Add('[Project]');
    L.Add('Name=' + Name);
    L.Add('CPU=' + CpuNames[Cpu]);
    L.Add('OutputDir=' + OutputDir);
    L.Add('');
    L.Add('[Sources]');
    for I := 0 to Sources.Count - 1 do L.Add(Format('File%d=%s', [I + 1, Sources[I]]));
    L.Add('');
    L.Add('[Tags]');
    for I := 0 to TagFiles.Count - 1 do L.Add(Format('File%d=%s', [I + 1, TagFiles[I]]));
    L.Add('');
    L.Add('[BlockNumbers]');
    for I := 0 to BlockNumbers.Count - 1 do L.Add(BlockNumbers[I]);
    L.Add('');
    L.Add('[CyclicInterval]');
    for I := 0 to CyclicIntervals.Count - 1 do L.Add(CyclicIntervals[I]);
    L.SaveToFile(FFileName);
  finally
    L.Free;
  end;
  Modified := False;
end;

function DetectCsvDelimiter(const Header: string): Char;
begin
  if Pos(';', Header) > 0 then Result := ';'
  else if Pos(#9, Header) > 0 then Result := #9
  else Result := ',';
end;

function SplitCsvLine(const S: string; Delim: Char): TStringArray;
var
  I, N: Integer;
  Cur: string;
  InQ: Boolean;
begin
  SetLength(Result, 0);
  Cur := '';
  InQ := False;
  I := 1;
  while I <= Length(S) do
  begin
    if InQ then
    begin
      if S[I] = '"' then
      begin
        if (I < Length(S)) and (S[I + 1] = '"') then begin Cur := Cur + '"'; Inc(I); end
        else InQ := False;
      end
      else Cur := Cur + S[I];
    end
    else if S[I] = '"' then InQ := True
    else if S[I] = Delim then
    begin
      N := Length(Result);
      SetLength(Result, N + 1);
      Result[N] := Cur;
      Cur := '';
    end
    else Cur := Cur + S[I];
    Inc(I);
  end;
  N := Length(Result);
  SetLength(Result, N + 1);
  Result[N] := Cur;
end;

procedure TSclProject.LoadTagsCsv(const FN: string; const ATable: string);
var
  L: TStringList;
  H, F: TStringArray;
  D: Char;
  I, J, CName, CType, CAddr, CCmt, CVal: Integer;
  T: TPlcTag;
  Hd: string;

  function Col(Idx: Integer): string;
  begin
    if (Idx >= 0) and (Idx <= High(F)) then Result := Trim(F[Idx]) else Result := '';
  end;

begin
  if not FileExists(FN) then Exit;
  L := TStringList.Create;
  try
    L.LoadFromFile(FN);
    if L.Count = 0 then Exit;
    D := DetectCsvDelimiter(L[0]);
    H := SplitCsvLine(L[0], D);
    CName := 0; CType := 2; CAddr := 3; CCmt := 4; CVal := -1;
    for J := 0 to High(H) do
    begin
      Hd := LowerCase(Trim(H[J]));
      if Hd = 'name' then CName := J
      else if (Hd = 'data type') or (Hd = 'datatype') or (Hd = 'type') then CType := J
      else if (Hd = 'logical address') or (Hd = 'address') then CAddr := J
      else if Hd = 'comment' then CCmt := J
      else if Hd = 'value' then CVal := J;
    end;
    for I := 1 to L.Count - 1 do
    begin
      if Trim(L[I]) = '' then Continue;
      F := SplitCsvLine(L[I], D);
      if Col(CName) = '' then Continue;
      T := TPlcTag.Create;
      T.Name := Col(CName);
      T.DataType := Col(CType);
      T.Address := Col(CAddr);
      T.Comment := Col(CCmt);
      T.Value := Col(CVal);
      T.TableName := ATable;
      Tags.Add(T);
    end;
  finally
    L.Free;
  end;
end;

function CsvQuote(const S: string): string;
begin
  if (Pos(';', S) > 0) or (Pos('"', S) > 0) then
    Result := '"' + StringReplace(S, '"', '""', [rfReplaceAll]) + '"'
  else
    Result := S;
end;

procedure TSclProject.SaveTagsCsv(const FN: string; const ATable: string);
var
  L: TStringList;
  I: Integer;
  T: TPlcTag;
begin
  L := TStringList.Create;
  try
    L.Add('Name;Path;Data Type;Logical Address;Comment;Value');
    for I := 0 to Tags.Count - 1 do
    begin
      T := Tag(I);
      if (ATable <> '') and (CompareText(T.TableName, ATable) <> 0) then Continue;
      L.Add(CsvQuote(T.Name) + ';' + CsvQuote(T.TableName) + ';' + CsvQuote(T.DataType) + ';' +
        CsvQuote(T.Address) + ';' + CsvQuote(T.Comment) + ';' + CsvQuote(T.Value));
    end;
    L.SaveToFile(FN);
  finally
    L.Free;
  end;
end;

procedure TSclProject.ReloadTags;
var
  I: Integer;
begin
  Tags.Clear;
  for I := 0 to TagFiles.Count - 1 do
    LoadTagsCsv(AbsPath(TagFiles[I]), ChangeFileExt(ExtractFileName(TagFiles[I]), ''));
end;

procedure TSclProject.SaveTags;
var
  I: Integer;
begin
  for I := 0 to TagFiles.Count - 1 do
    SaveTagsCsv(AbsPath(TagFiles[I]), ChangeFileExt(ExtractFileName(TagFiles[I]), ''));
end;

function TSclProject.OutputFile: string;
begin
  Result := IncludeTrailingPathDelimiter(AbsPath(OutputDir)) + Name + '.svpl';
end;

function TSclProject.BlockNumber(const AName: string): Integer;
begin
  Result := StrToIntDef(BlockNumbers.Values[AName], 0);
end;

procedure TSclProject.SetBlockNumber(const AName: string; ANum: Integer);
begin
  if ANum <= 0 then BlockNumbers.Values[AName] := ''
  else BlockNumbers.Values[AName] := IntToStr(ANum);
  Modified := True;
end;

end.
