unit uLogo;

{ LOGO! 8 in the project: before every compile (TPlcProject.SyncHook) the FBs of the LOGO! library that the
  program uses are in the project (Library: not shown, not saved, made again from uLogoDefs), and the DB
  LOGO_B holds one instance per special function: its block number (B001 ..) as a variable of its FB type, so
  the box calls "LOGO_B".B003(Trg := .., T := ..) and the watch table / Mini Watch read B003.Ta, B003.Q. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, uPlcTypes, uPlcProject, uSclSource, uLogoDefs;

procedure SyncLogo(P: TPlcProject);
{ the program as a list of its blocks: per network every box with its inputs (an operand, or the output of the box
  it is wired to) and its outputs; Csv: one row per pin (Network;Block;Function;Rem;Pin;Direction;Operand) }
function LogoExport(P: TPlcProject; Csv: Boolean): string;

implementation

uses
  uFbd;

function LogoExport(P: TPlcProject; Csv: Boolean): string;
var
  SL: TStringList;
  I, J, K, Q, S: Integer;
  B: TBlock;
  N: TNetwork;
  Nd: TFbdNode;
  Bd: TFbdBoxDef;
  Nm, Op, Rem: string;

  function NodeName(const X: TFbdNode): string;
  begin
    if LogoDefIndex(X.Box) >= 0 then Result := X.Inst
    else Result := Format('#%d %s', [X.Id, FbdBoxDefOf(X.Box).Title]);
  end;

  function CsvQ(const T: string): string;
  begin
    Result := '"' + StringReplace(T, '"', '""', [rfReplaceAll]) + '"';
  end;

begin
  SL := TStringList.Create;
  try
    if Csv then SL.Add('Network;Block;Function;Rem;Pin;Direction;Operand')
    else
    begin
      SL.Add(Format('LOGO! program: %s', [P.Name]));
      SL.Add(Format('%s  %s  %s', [P.Model.Name, P.Model.OrderNo, P.Model.Firmware]));
    end;
    for I := 0 to P.BlockCount - 1 do
    begin
      B := P.Block(I);
      if B.IsLibrary then Continue;
      for J := 0 to B.NetCount - 1 do
      begin
        N := B.Net(J);
        if not (N.Kind in [nkFBD, nkCFC]) then Continue;
        if not Csv then
        begin
          SL.Add('');
          SL.Add(Format('Network %d: %s', [J + 1, N.Title]));
        end;
        for K := 0 to High(N.Nodes) do
        begin
          Nd := N.Nodes[K];
          Bd := FbdBoxDefOf(Nd.Box);
          Nm := NodeName(Nd);
          if Nd.Rem then Rem := 'Rem' else Rem := '';
          if not Csv then
          begin
            if LogoDefIndex(Nd.Box) >= 0 then SL.Add(Format('  %s  %s  %s', [Nd.Inst, Bd.Title, Rem]))
            else if Trim(Nd.Inst) <> '' then SL.Add(Format('  %s  (%s)', [Nm, Nd.Inst]))
            else SL.Add('  ' + Nm);
          end;
          for Q := 0 to High(Nd.Ins) do
          begin
            if Nd.Ins[Q].Src > 0 then
            begin
              S := N.NodeIndex(Nd.Ins[Q].Src);
              if (S >= 0) and (Nd.Ins[Q].SrcPin <= High(N.Nodes[S].Outs)) then
                Op := NodeName(N.Nodes[S]) + '.' + N.Nodes[S].Outs[Nd.Ins[Q].SrcPin].Name
              else Op := '?';
            end
            else Op := Trim(Nd.Ins[Q].Opnd);
            if Op = '' then Continue;
            if Nd.Ins[Q].Neg then Op := 'NOT ' + Op;
            if Csv then SL.Add(Format('%d;%s;%s;%s;%s;in;%s', [J + 1, CsvQ(Nm), CsvQ(Bd.Title), Rem, Nd.Ins[Q].Name, CsvQ(Op)]))
            else SL.Add(Format('      %-8s = %s', [Nd.Ins[Q].Name, Op]));
          end;
          for Q := 0 to High(Nd.Outs) do
          begin
            Op := Trim(Nd.Outs[Q].Opnd);
            if (LogoDefIndex(Nd.Box) < 0) and (Bd.Inst = fiOperand) and (Q = 0) and (Trim(Nd.Inst) <> '') then
              Op := Trim(Nd.Inst);
            if Op = '' then Continue;
            if Csv then SL.Add(Format('%d;%s;%s;%s;%s;out;%s', [J + 1, CsvQ(Nm), CsvQ(Bd.Title), Rem, Nd.Outs[Q].Name, CsvQ(Op)]))
            else SL.Add(Format('      %-8s -> %s', [Nd.Outs[Q].Name, Op]));
          end;
        end;
      end;
    end;
    // the terminal names
    if not Csv and (Length(P.Tags) > 0) then
    begin
      SL.Add('');
      SL.Add('Terminal names');
      for I := 0 to High(P.Tags) do SL.Add(Format('  %-6s %s  %s', [P.Tags[I].Address, P.Tags[I].Name, P.Tags[I].Comment]));
    end;
    Result := SL.Text;
  finally
    SL.Free;
  end;
end;

procedure ForEachBox(P: TPlcProject; L: TStrings);
var
  I, J, K: Integer;
  B: TBlock;
  N: TNetwork;
begin
  // every special function: its instance=its box id
  for I := 0 to P.BlockCount - 1 do
  begin
    B := P.Block(I);
    if B.IsLibrary then Continue;
    for J := 0 to B.NetCount - 1 do
    begin
      N := B.Net(J);
      if not (N.Kind in [nkFBD, nkCFC]) then Continue;
      for K := 0 to High(N.Nodes) do
        if (LogoDefIndex(N.Nodes[K].Box) >= 0) and (Trim(N.Nodes[K].Inst) <> '') then
          L.AddObject(Trim(N.Nodes[K].Inst) + '=' + N.Nodes[K].Box, TObject(PtrInt(Ord(N.Nodes[K].Rem))));
    end;
  end;
end;

procedure SyncLogo(P: TPlcProject);
var
  L, Fbs: TStringList;
  K, J, Ix: Integer;
  D: TDataBlock;
  Def: TLogoDef;
  Rep: string;
  B: TBlock;
begin
  if not IsLogo(P.Family) then Exit;
  L := TStringList.Create;
  Fbs := TStringList.Create;
  try
    ForEachBox(P, L);
    // the FBs of the library that are used and not there yet
    for K := 0 to L.Count - 1 do
    begin
      Def := LogoDef(LogoDefIndex(L.ValueFromIndex[K]));
      if Fbs.IndexOf(Def.Fb) < 0 then Fbs.Add(Def.Fb);
    end;
    for K := 0 to Fbs.Count - 1 do
    begin
      B := nil;
      for J := 0 to P.BlockCount - 1 do
        if (P.Block(J).Kind = bkFB) and SameText(P.Block(J).Name, Fbs[K]) then B := P.Block(J);
      if B <> nil then Continue;
      SclImport(P, LogoLibSource(Fbs[K]), Rep);
      for J := 0 to P.BlockCount - 1 do
        if (P.Block(J).Kind = bkFB) and SameText(P.Block(J).Name, Fbs[K]) then P.Block(J).IsLibrary := True;
    end;
    // the instances: the DB LOGO_B
    D := P.FindDBByName(LogoInstDB);
    if (L.Count = 0) and (D <> nil) then
    begin
      P.DeleteDB(P.DBs.IndexOf(D));
      Exit;
    end;
    if L.Count = 0 then Exit;
    if D = nil then
    begin
      D := P.AddDB(1, LogoInstDB);
      D.ProgramOf := -1;
      D.Comment := 'the LOGO! blocks: one instance per special function';
    end;
    D.Optimized := True;
    D.Vars := nil;
    for K := 0 to L.Count - 1 do
    begin
      Ix := LogoDefIndex(L.ValueFromIndex[K]);
      if D.FindVar(L.Names[K]) < 0 then
      begin
        D.AddVar(L.Names[K], LogoDef(Ix).Fb, '', LogoDef(Ix).Title);
        // Rem: the instance is retentive
        D.Vars[High(D.Vars)].Retain := PtrInt(L.Objects[K]) <> 0;
      end;
    end;
    D.Layout;
  finally
    L.Free;
    Fbs.Free;
  end;
end;

initialization
  SyncHook := @SyncLogo;
end.
