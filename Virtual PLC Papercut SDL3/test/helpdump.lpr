program helpdump;
{ every element of the three panels: its help page as text (the check of uElemHelp): the LAD pictures parse,
  the signals of a timing diagram have the same number of steps; the pages go to helpdump.txt }
{$mode objfpc}{$H+}
uses SysUtils, Classes, uPlcTypes, uPlcProject, uSclElems, uElemHelp, uFbd;
var
  L: TSclElems;
  K, Cnt, Thin, Bad, B, R, Len, N, LadN: Integer;
  Pg: TElemHelpPage;
  Lang: Char;
  Out, Ls: TStringList;
  Net, Fn: TNetwork;
  Err: string;
begin
  Out := TStringList.Create;
  Thin := 0;
  Bad := 0;
  for Lang in ['C', 'S', 'L', 'F', 'K'] do
  begin
    case Lang of
      'C': L := SclElems(nil, nil);
      'S': L := StlElems(nil, nil);
      'F': L := FbdElems(nil, nil, False);
      'K': L := FbdElems(nil, nil, True);
    else
      L := LadElems(nil, nil);
    end;
    Cnt := 0;
    for K := 0 to High(L) do
    begin
      Pg := ElemHelpPage(Lang, L[K], cfS71500);
      Out.Add('########## ' + ElemHelpText(Pg));
      Inc(Cnt);
      for B := 0 to High(Pg.Blocks) do
        if Pg.Blocks[B].K = hbLad then
        begin
          HelpLadErr := '';
          Net := HelpLadNet(Pg.Blocks[B].S);
          LadN := 0;
          for R := 0 to High(Net.Cells) do
            if Net.Cells[R].Kind <> lkEmpty then Inc(LadN);
          if (HelpLadErr <> '') or (LadN = 0) then
          begin
            WriteLn('LAD error: ', Lang, ' ', L[K].Cap, ':', HelpLadErr, ' cells ', LadN);
            Inc(Bad);
          end;
          Net.Free;
        end
        else if Pg.Blocks[B].K in [hbFbd, hbCfc] then
        begin
          // the rung of the picture as FBD boxes
          HelpLadErr := '';
          Net := HelpLadNet(Pg.Blocks[B].S);
          Fn := LadToFbd(Net, nil, Err);
          if (Fn = nil) or (HelpLadErr <> '') or (Length(Fn.Nodes) = 0) then
          begin
            WriteLn('FBD picture: ', Lang, ' ', L[K].Cap, ': ', Err, HelpLadErr);
            Inc(Bad);
          end;
          Net.Free;
          Fn.Free;
        end
        else if Pg.Blocks[B].K = hbWave then
        begin
          Ls := TStringList.Create;
          Ls.Text := Pg.Blocks[B].S;
          Len := -1;
          for R := 0 to Ls.Count - 1 do
          begin
            if (Ls[R] = '') or (Ls[R][1] = '^') then Continue;
            if Pos('~', Ls[R]) > 0 then N := Length(Copy(Ls[R], Pos('~', Ls[R]) + 1, MaxInt).Split(','))
            else N := Length(Copy(Ls[R], Pos('=', Ls[R]) + 1, MaxInt));
            if Len < 0 then Len := N
            else if N <> Len then
            begin
              WriteLn('wave length: ', Lang, ' ', L[K].Cap, ': ', Ls[R], ' ', N, ' <> ', Len);
              Inc(Bad);
            end;
          end;
          Ls.Free;
        end;
      if Length(Pg.Blocks) < 6 then Inc(Thin);
    end;
    WriteLn(Lang, ': ', Cnt, ' elements');
  end;
  WriteLn('short pages: ', Thin, ', errors: ', Bad);
  Out.SaveToFile('helpdump.txt');
  Out.Free;
end.
