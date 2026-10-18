{ SCL Compiler - base definitions: source positions, diagnostics, helpers }
unit scl_base;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, contnrs;

type
  TCpuFamily = (cpuS7_300, cpuS7_400, cpuS7_1200, cpuS7_1500);

  TSrcPos = record
    FileName: string;
    Line, Col: Integer;
    Offset: Integer;      // 1-based char offset in the source text
  end;

  TDiagSeverity = (dsError, dsWarning, dsHint);

  TDiag = class
  public
    Severity: TDiagSeverity;
    Pos: TSrcPos;
    Msg: string;
    function ToString: string; override;
  end;

  TDiagList = class(TObjectList)
  private
    function GetDiag(I: Integer): TDiag;
  public
    function Add(ASev: TDiagSeverity; const APos: TSrcPos; const AMsg: string): TDiag; overload;
    procedure Error(const APos: TSrcPos; const AMsg: string);
    procedure Warning(const APos: TSrcPos; const AMsg: string);
    procedure Hint(const APos: TSrcPos; const AMsg: string);
    function ErrorCount: Integer;
    function WarningCount: Integer;
    property Diags[I: Integer]: TDiag read GetDiag; default;
  end;

  ESclError = class(Exception)
  public
    Pos: TSrcPos;
    constructor CreatePos(const APos: TSrcPos; const AMsg: string);
  end;

const
  CpuNames: array[TCpuFamily] of string = ('S7-300', 'S7-400', 'S7-1200', 'S7-1500');

function CpuFromName(const S: string; out Cpu: TCpuFamily): Boolean;
function MakePos(const AFile: string; ALine, ACol, AOffset: Integer): TSrcPos;
function NoPos: TSrcPos;
function SameText2(const A, B: string): Boolean; inline;

implementation

function TDiag.ToString: string;
const
  SevName: array[TDiagSeverity] of string = ('Error', 'Warning', 'Hint');
begin
  if Pos.FileName <> '' then
    Result := Format('%s(%d,%d) %s: %s', [ExtractFileName(Pos.FileName), Pos.Line, Pos.Col, SevName[Severity], Msg])
  else
    Result := Format('%s: %s', [SevName[Severity], Msg]);
end;

function TDiagList.GetDiag(I: Integer): TDiag;
begin
  Result := TDiag(Items[I]);
end;

function TDiagList.Add(ASev: TDiagSeverity; const APos: TSrcPos; const AMsg: string): TDiag;
begin
  Result := TDiag.Create;
  Result.Severity := ASev;
  Result.Pos := APos;
  Result.Msg := AMsg;
  inherited Add(Result);
end;

procedure TDiagList.Error(const APos: TSrcPos; const AMsg: string);
begin
  Add(dsError, APos, AMsg);
end;

procedure TDiagList.Warning(const APos: TSrcPos; const AMsg: string);
begin
  Add(dsWarning, APos, AMsg);
end;

procedure TDiagList.Hint(const APos: TSrcPos; const AMsg: string);
begin
  Add(dsHint, APos, AMsg);
end;

function TDiagList.ErrorCount: Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to Count - 1 do
    if Diags[I].Severity = dsError then Inc(Result);
end;

function TDiagList.WarningCount: Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to Count - 1 do
    if Diags[I].Severity = dsWarning then Inc(Result);
end;

constructor ESclError.CreatePos(const APos: TSrcPos; const AMsg: string);
begin
  inherited Create(AMsg);
  Pos := APos;
end;

function CpuFromName(const S: string; out Cpu: TCpuFamily): Boolean;
var
  C: TCpuFamily;
  U: string;
begin
  U := UpperCase(StringReplace(Trim(S), ' ', '', [rfReplaceAll]));
  for C := Low(TCpuFamily) to High(TCpuFamily) do
    if (U = UpperCase(CpuNames[C])) or (U = UpperCase(StringReplace(CpuNames[C], 'S7-', '', []))) then
    begin
      Cpu := C;
      Exit(True);
    end;
  Cpu := cpuS7_1200;
  Result := False;
end;

function MakePos(const AFile: string; ALine, ACol, AOffset: Integer): TSrcPos;
begin
  Result.FileName := AFile;
  Result.Line := ALine;
  Result.Col := ACol;
  Result.Offset := AOffset;
end;

function NoPos: TSrcPos;
begin
  Result := MakePos('', 0, 0, 0);
end;

function SameText2(const A, B: string): Boolean;
begin
  Result := CompareText(A, B) = 0;
end;

end.
