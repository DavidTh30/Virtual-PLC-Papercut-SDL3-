{ sclc - SCL command line compiler for the Virtual PLC }
program sclc;

{$mode objfpc}{$H+}

uses
  Classes, SysUtils, StrUtils, scl_base, scl_types, scl_ast, scl_lexer, scl_project, scl_vmformat, scl_vmmem,
  scl_compiler, scl_vm, scl_navigate;

procedure Usage;
begin
  WriteLn('SCL Compiler ', COMPILER_VERSION, ' - Siemens S7-300/400/1200/1500 SCL to Virtual PLC (.svpl)');
  WriteLn;
  WriteLn('Usage:');
  WriteLn('  sclc <project.sclproj> [-o <image.svpl>] [-l <listing.lst>] [--check]');
  WriteLn('  sclc --import <folder> --cpu <S7-300|S7-400|S7-1200|S7-1500> -p <project.sclproj> [--number <block>=<n> ...]');
  WriteLn('  sclc --dump <image.svpl>');
  WriteLn('  sclc --sim <image.svpl> --script <test.txt>   (run the reference Virtual PLC)');
  WriteLn;
  WriteLn('Options:');
  WriteLn('  -o <file>     output image (default: <project dir>\output\<name>.svpl)');
  WriteLn('  -l <file>     write listing (disassembly + memory map)');
  WriteLn('  --check       syntax / type check only, no output');
  WriteLn('  --cpu <cpu>   override the CPU family of the project');
  WriteLn('  --number <block>=<n>   (with --import) the number of a block, e.g. --number DB_HMI=10;');
  WriteLn('                a comment "block number = 10" before a block in its source does the same');
end;

{ the blocks of a source and a block number in the comment before each one ("block number = 10"):
  TIA external sources have no numbers, a comment is where they are noted }
procedure ScanBlocks(const FileName: string; Names: TStrings);
var
  L: TStringList;
  U, Kw, Nm, Hint: string;
  K, P, Q, Num, Last: Integer;
  Kws: array[0..4] of string = ('DATA_BLOCK', 'FUNCTION_BLOCK', 'ORGANIZATION_BLOCK', 'FUNCTION', 'TYPE');

  function Before(I: Integer): Boolean;
  begin
    // a key word at the start of a line
    Result := (I = 1) or (U[I - 1] in [#10, #13]);
  end;

begin
  L := TStringList.Create;
  try
    L.LoadFromFile(FileName);
    U := L.Text;
  finally
    L.Free;
  end;
  Last := 1;
  P := 1;
  while P <= Length(U) do
  begin
    Kw := '';
    for K := 0 to High(Kws) do
      if (UpperCase(Copy(U, P, Length(Kws[K]))) = Kws[K]) and Before(P) and
        ((P + Length(Kws[K]) > Length(U)) or (U[P + Length(Kws[K])] in [' ', #9])) then
      begin
        Kw := Kws[K];
        Break;
      end;
    if Kw = '' then
    begin
      Inc(P);
      Continue;
    end;
    // "Name" after the key word
    Q := P + Length(Kw);
    while (Q <= Length(U)) and (U[Q] in [' ', #9]) do Inc(Q);
    Nm := '';
    if (Q <= Length(U)) and (U[Q] = '"') then
    begin
      Inc(Q);
      while (Q <= Length(U)) and (U[Q] <> '"') do
      begin
        Nm := Nm + U[Q];
        Inc(Q);
      end;
    end;
    if Nm <> '' then
    begin
      // the text since the block before: "block number = 10" / "block number := 10"
      Hint := LowerCase(Copy(U, Last, P - Last));
      Num := -1;
      K := Pos('block number', Hint);
      if K > 0 then
      begin
        K := K + Length('block number');
        while (K <= Length(Hint)) and (Hint[K] in [' ', ':', '=']) do Inc(K);
        Num := 0;
        while (K <= Length(Hint)) and (Hint[K] in ['0'..'9']) do
        begin
          Num := Num * 10 + Ord(Hint[K]) - Ord('0');
          Inc(K);
        end;
        if Num = 0 then Num := -1;
      end;
      // the kind as a prefix: DB|DB_HMI
      if Kw = 'DATA_BLOCK' then Names.AddObject('DB|' + Nm, TObject(PtrInt(Num)))
      else if Kw <> 'TYPE' then Names.AddObject('-|' + Nm, TObject(PtrInt(Num)));
    end;
    Last := Q;
    P := Q + 1;
  end;
end;

function ImportFolder(const Dir, ProjFile: string; Cpu: TCpuFamily; Numbers: TStrings): Integer;
var
  P: TSclProject;
  SR: TSearchRec;
  L, Blocks: TStringList;
  I, J, N: Integer;
  Auto, Nm: string;
begin
  P := TSclProject.Create;
  L := TStringList.Create;
  try
    P.FileName := ExpandFileName(ProjFile);
    P.Name := ChangeFileExt(ExtractFileName(ProjFile), '');
    P.Cpu := Cpu;
    // the extension exactly: Windows also finds "x.sclproj" for "*.scl" (by its short name)
    if FindFirst(IncludeTrailingPathDelimiter(Dir) + '*.scl', faAnyFile, SR) = 0 then
    repeat
      if SameText(ExtractFileExt(SR.Name), '.scl') then L.Add(SR.Name);
    until FindNext(SR) <> 0;
    FindClose(SR);
    L.Sort;
    for I := 0 to L.Count - 1 do
      P.Sources.Add(P.RelPath(IncludeTrailingPathDelimiter(ExpandFileName(Dir)) + L[I]));
    // the block numbers: --number, else a "block number = n" comment, else automatic (reported)
    Blocks := TStringList.Create;
    try
      for I := 0 to L.Count - 1 do ScanBlocks(IncludeTrailingPathDelimiter(Dir) + L[I], Blocks);
      Auto := '';
      for I := 0 to Blocks.Count - 1 do
      begin
        Nm := Copy(Blocks[I], Pos('|', Blocks[I]) + 1, MaxInt);
        N := Numbers.IndexOfName(Nm);
        if N >= 0 then
        begin
          P.SetBlockNumber(Nm, StrToInt(Numbers.ValueFromIndex[N]));
          WriteLn(Format('  %s = %s (--number)', [Nm, Numbers.ValueFromIndex[N]]));
        end
        else if PtrInt(Blocks.Objects[I]) > 0 then
        begin
          P.SetBlockNumber(Nm, PtrInt(Blocks.Objects[I]));
          WriteLn(Format('  %s = %d (from the comment "block number = %d" in its source)',
            [Nm, PtrInt(Blocks.Objects[I]), PtrInt(Blocks.Objects[I])]));
        end
        else if Copy(Blocks[I], 1, 3) = 'DB|' then
        begin
          // a data block: a HMI or another program reads it by its number
          if Auto <> '' then Auto := Auto + ', ';
          Auto := Auto + Nm;
        end;
      end;
      for J := 0 to Numbers.Count - 1 do
        if (Blocks.IndexOf('DB|' + Numbers.Names[J]) < 0) and (Blocks.IndexOf('-|' + Numbers.Names[J]) < 0) then
          WriteLn(Format('  Warning: --number %s: no such block in the sources', [Numbers.Names[J]]));
      if Auto <> '' then
        WriteLn('  data blocks numbered when compiling (set [BlockNumbers] or --number if a HMI needs a fixed ' +
          'one): ' + Auto);
    finally
      Blocks.Free;
    end;
    L.Clear;
    if FindFirst(IncludeTrailingPathDelimiter(Dir) + '*.csv', faAnyFile, SR) = 0 then
    repeat
      if SameText(ExtractFileExt(SR.Name), '.csv') then L.Add(SR.Name);
    until FindNext(SR) <> 0;
    FindClose(SR);
    for I := 0 to L.Count - 1 do
      P.TagFiles.Add(P.RelPath(IncludeTrailingPathDelimiter(ExpandFileName(Dir)) + L[I]));
    P.SaveToFile(ProjFile);
    WriteLn(Format('Project %s created: %d sources, %d tag tables', [ProjFile, P.Sources.Count, P.TagFiles.Count]));
    Result := 0;
  finally
    L.Free;
    P.Free;
  end;
end;

function Dump(const FN: string): Integer;
var
  Img: TSvImage;
  I, J: Integer;
  B: TSvBlock;
  D: TSvDataBlock;
begin
  Img := TSvImage.Create;
  try
    Img.LoadFromFile(FN);
    WriteLn('Project: ', Img.ProjectName, '   CPU family code: ', Img.Cpu);
    for I := 0 to Img.Meta.Count - 1 do WriteLn('  ', Img.Meta[I]);
    WriteLn('Tags: ', Length(Img.Tags), '   Data blocks: ', Img.DataBlocks.Count, '   Code blocks: ', Img.Blocks.Count,
      '   Const pool: ', Length(Img.ConstPool), ' bytes');
    for I := 0 to Img.DataBlocks.Count - 1 do
    begin
      D := Img.DataBlock(I);
      WriteLn(Format('DB%d "%s" %d bytes, %d variables', [D.Number, D.Name, Length(D.Data), Length(D.Vars)]));
    end;
    for I := 0 to Img.Blocks.Count - 1 do
    begin
      B := Img.Block(I);
      WriteLn;
      WriteLn(Format('[%d] kind=%d %d "%s" param=%d temp=%d inst=%d event=%d code=%d',
        [I, B.Kind, B.Number, B.Name, B.ParamBytes, B.TempBytes, B.InstanceBytes, B.EventClass, Length(B.Code)]));
      Write(Disassemble(B.Code, Img));
      for J := 0 to -1 do ;
    end;
    Result := 0;
  finally
    Img.Free;
  end;
end;

function ValueText(const V: TVmValue; VT: Byte): string;
begin
  case VT of
    VT_BOOL: if V.I <> 0 then Result := 'TRUE' else Result := 'FALSE';
    VT_REAL, VT_LREAL: Result := FormatFloat('0.######', V.F);
    VT_TIME: Result := 'T#' + IntToStr(V.I) + 'MS';
  else
    Result := IntToStr(V.I);
  end;
end;

function ParseValue(const S: string; VT: Byte; out V: TVmValue): Boolean;
var
  U: string;
  Ns: Int64;
  F: Double;
  Code: Integer;
begin
  Result := True;
  U := UpperCase(Trim(S));
  if (U = 'TRUE') or (U = 'FALSE') then begin V.I := Ord(U = 'TRUE'); Exit; end;
  if (Copy(U, 1, 2) = 'T#') and ParseDurationText(Copy(U, 3, MaxInt), Ns) then
  begin
    if VT = VT_LTIME then V.I := Ns else V.I := Ns div 1000000;
    Exit;
  end;
  if VT in [VT_REAL, VT_LREAL] then
  begin
    Val(U, F, Code);
    V.F := F;
    Exit(Code = 0);
  end;
  Val(U, V.I, Code);
  Result := Code = 0;
end;

{ a String / WString variable (its type text) }
function IsStringType(const TT: string; out Wide: Boolean): Boolean;
begin
  Wide := SameText(Copy(TT, 1, 7), 'WString');
  Result := Wide or SameText(Copy(TT, 1, 6), 'String');
end;

{ a string value of the script: 'text' with '' for a quote (or the bare text) }
function ScriptString(const S: string): string;
var
  T: string;
begin
  T := Trim(S);
  if (Length(T) >= 2) and (T[1] = '''') and (T[Length(T)] = '''') then
    Result := StringReplace(Copy(T, 2, Length(T) - 2), '''''', '''', [rfReplaceAll])
  else
    Result := T;
end;

function QuoteString(const S: string): string;
begin
  Result := '''' + StringReplace(S, '''', '''''', [rfReplaceAll]) + '''';
end;

function RunScript(const ImgFile, ScriptFile: string): Integer;
var
  Img: TSvImage;
  Plc: TVirtualPlc;
  L: TStringList;
  I, Fails, Passes, CycleMs, N: Integer;
  Line, Cmd, Path, Arg: string;
  Parts: TStringArray;
  A, Ns: Int64;
  VT: Byte;
  TT: string;
  V, W: TVmValue;
  Ok: Boolean;
  Links: array of record Dst, Src: Int64; DVT, SVT: Byte; end;
  K: Integer;
  A2: Int64;
  VT2: Byte;
  Wide: Boolean;
  SV, SW: string;
  DiagShown: Integer;
  StopShown: Boolean;

  // the new entries of the diagnostic buffer; the STOP of the CPU once
  procedure ShowDiag;
  begin
    while DiagShown < Plc.Diag.Count do
    begin
      WriteLn('DIAG ', Plc.Diag[DiagShown]);
      Inc(DiagShown);
    end;
    if Plc.Stopped and not StopShown then
    begin
      WriteLn(Format('CPU STOP at t=%.2fs: %s', [Plc.StopNs / 1e9, Plc.StopReason]));
      StopShown := True;
    end;
  end;

  function SplitCmd(const S: string): TStringArray;
  var
    P: Integer;
    R, Q: string;
  begin
    SetLength(Result, 0);
    R := Trim(S);
    while R <> '' do
    begin
      if R[1] = '"' then
      begin
        { "DB".path token }
        P := Pos('"', Copy(R, 2, MaxInt)) + 1;
        Q := Copy(R, 1, P);
        Delete(R, 1, P);
        P := Pos(' ', R);
        if P = 0 then P := Length(R) + 1;
        Q := Q + Copy(R, 1, P - 1);
        Delete(R, 1, P - 1);
      end
      else
      begin
        P := Pos(' ', R);
        if P = 0 then P := Length(R) + 1;
        Q := Copy(R, 1, P - 1);
        Delete(R, 1, P - 1);
      end;
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := Q;
      R := TrimLeft(R);
    end;
  end;

begin
  Result := 0;
  Img := TSvImage.Create;
  L := TStringList.Create;
  Plc := TVirtualPlc.Create(Img, True);
  try
    Img.LoadFromFile(ImgFile);
    L.LoadFromFile(ScriptFile);
    Plc.ColdStart;
    DiagShown := 0;
    StopShown := False;
    ShowDiag;
    CycleMs := 10;
    Fails := 0;
    Passes := 0;
    for I := 0 to L.Count - 1 do
    begin
      Line := Trim(L[I]);
      if (Line = '') or (Line[1] = '#') then Continue;
      Parts := SplitCmd(Line);
      Cmd := LowerCase(Parts[0]);
      try
        if Cmd = 'cycle-ms' then
          CycleMs := StrToInt(Parts[1])
        else if Cmd = 'link' then
        begin
          if not Plc.FindVar(Parts[1], A, VT, TT) then raise Exception.Create('unknown variable ' + Parts[1]);
          if not Plc.FindVar(Parts[2], A2, VT2, TT) then raise Exception.Create('unknown variable ' + Parts[2]);
          SetLength(Links, Length(Links) + 1);
          Links[High(Links)].Dst := A; Links[High(Links)].DVT := VT;
          Links[High(Links)].Src := A2; Links[High(Links)].SVT := VT2;
        end
        else if Cmd = 'expect-mode' then
        begin
          // RUN / STOP of the CPU
          if Length(Parts) < 2 then raise Exception.Create('expect-mode RUN|STOP');
          if Plc.Stopped then SV := 'STOP' else SV := 'RUN';
          if SameText(Parts[1], SV) then
          begin
            Inc(Passes);
            WriteLn(Format('PASS line %d: CPU in %s  (t=%.2fs)', [I + 1, SV, Plc.NowNs / 1e9]));
          end
          else
          begin
            Inc(Fails);
            WriteLn(Format('FAIL line %d: CPU in %s, expected %s  (t=%.2fs)', [I + 1, SV, UpperCase(Parts[1]),
              Plc.NowNs / 1e9]));
          end;
        end
        else if Cmd = 'echo' then
          WriteLn('     ', Copy(Line, 6, MaxInt))
        else if Cmd = 'run' then
        begin
          Arg := UpperCase(Parts[1]);
          if (Length(Parts) > 2) and SameText(Parts[2], 'cycles') then N := StrToInt(Parts[1])
          else if ParseDurationText(Arg, Ns) then N := (Ns div 1000000 + CycleMs - 1) div CycleMs
          else raise Exception.Create('run <time>|<n> cycles');
          while N > 0 do
          begin
            if not Plc.Stopped then
              for K := 0 to High(Links) do
                Plc.WriteAddr(Links[K].Dst, Links[K].DVT, Plc.ReadAddr(Links[K].Src, Links[K].SVT));
            Plc.Cycle(CycleMs);
            Dec(N);
          end;
          ShowDiag;
        end
        else if (Cmd = 'set') or (Cmd = 'expect') or (Cmd = 'print') then
        begin
          Path := Parts[1];
          if not Plc.FindVar(Path, A, VT, TT) then raise Exception.Create('unknown variable ' + Path);
          if IsStringType(TT, Wide) then
          begin
            // a String: the rest of the line is the value ('text', spaces allowed)
            SV := Plc.ReadStringAt(A, Wide);
            if Cmd = 'print' then
            begin
              WriteLn(Format('     %s = %s', [Path, QuoteString(SV)]));
              Continue;
            end;
            if Length(Parts) < 3 then raise Exception.Create('value expected');
            SW := ScriptString(Copy(Line, Pos(Parts[1], Line) + Length(Parts[1]), MaxInt));
            if Cmd = 'set' then
              Plc.WriteStringAt(A, SW, Wide)
            else if SV = SW then
            begin
              Inc(Passes);
              WriteLn(Format('PASS line %d: %s = %s  (t=%.2fs)', [I + 1, Path, QuoteString(SV), Plc.NowNs / 1e9]));
            end
            else
            begin
              Inc(Fails);
              WriteLn(Format('FAIL line %d: %s = %s, expected %s  (t=%.2fs)', [I + 1, Path, QuoteString(SV),
                QuoteString(SW), Plc.NowNs / 1e9]));
            end;
            Continue;
          end;
          if Cmd = 'print' then
          begin
            V := Plc.ReadAddr(A, VT);
            WriteLn(Format('     %s = %s', [Path, ValueText(V, VT)]));
            Continue;
          end;
          if not ParseValue(Parts[2], VT, W) then raise Exception.Create('invalid value ' + Parts[2]);
          if Cmd = 'set' then
            Plc.WriteAddr(A, VT, W)
          else
          begin
            V := Plc.ReadAddr(A, VT);
            if VT in [VT_REAL, VT_LREAL] then Ok := Abs(V.F - W.F) < 1e-4 else Ok := V.I = W.I;
            if Ok then
            begin
              Inc(Passes);
              WriteLn(Format('PASS line %d: %s = %s  (t=%.2fs)', [I + 1, Path, ValueText(V, VT), Plc.NowNs / 1e9]));
            end
            else
            begin
              Inc(Fails);
              WriteLn(Format('FAIL line %d: %s = %s, expected %s  (t=%.2fs)', [I + 1, Path, ValueText(V, VT),
                Parts[2], Plc.NowNs / 1e9]));
            end;
          end;
        end
        else
          raise Exception.Create('unknown command ' + Cmd);
      except
        on E: Exception do
        begin
          Inc(Fails);
          WriteLn(Format('ERROR line %d: %s', [I + 1, E.Message]));
          if E is EVmError then Break;
        end;
      end;
    end;
    WriteLn(Format('%d passed, %d failed, %d cycles, simulated %.2f s%s', [Passes, Fails, Plc.CycleCount, Plc.NowNs / 1e9,
      IfThen(Plc.ProgErrors > 0, Format(', %d programming errors', [Plc.ProgErrors]), '') +
      IfThen(Plc.Stopped, ', CPU in STOP', '')]));
    if Fails > 0 then Result := 1;
  finally
    Plc.Free;
    L.Free;
  end;
end;

var
  I: Integer;
  ProjFile, OutFile, LstFile, ImportDir, DumpFile, CpuOverride, SimFile, ScriptFile, FindDecl: string;
  FdParts: TStringArray;
  FdLines: TStringList;
  FdRes: TDeclResult;
  FdFile: string;
  FdLine, FdCol: Integer;
  CheckOnly: Boolean;
  Cpu: TCpuFamily;
  P: TSclProject;
  C: TSclCompiler;
  T0: QWord;
  Numbers: TStringList;
begin
  Numbers := TStringList.Create;
  ProjFile := '';
  OutFile := '';
  LstFile := '';
  ImportDir := '';
  DumpFile := '';
  CpuOverride := '';
  CheckOnly := False;
  I := 1;
  while I <= ParamCount do
  begin
    if (ParamStr(I) = '-o') and (I < ParamCount) then begin Inc(I); OutFile := ParamStr(I); end
    else if (ParamStr(I) = '-l') and (I < ParamCount) then begin Inc(I); LstFile := ParamStr(I); end
    else if (ParamStr(I) = '-p') and (I < ParamCount) then begin Inc(I); ProjFile := ParamStr(I); end
    else if (ParamStr(I) = '--import') and (I < ParamCount) then begin Inc(I); ImportDir := ParamStr(I); end
    else if (ParamStr(I) = '--dump') and (I < ParamCount) then begin Inc(I); DumpFile := ParamStr(I); end
    else if (ParamStr(I) = '--cpu') and (I < ParamCount) then begin Inc(I); CpuOverride := ParamStr(I); end
    else if (ParamStr(I) = '--sim') and (I < ParamCount) then begin Inc(I); SimFile := ParamStr(I); end
    else if (ParamStr(I) = '--script') and (I < ParamCount) then begin Inc(I); ScriptFile := ParamStr(I); end
    else if (ParamStr(I) = '--find-decl') and (I < ParamCount) then begin Inc(I); FindDecl := ParamStr(I); end
    else if (ParamStr(I) = '--number') and (I < ParamCount) then
    begin
      Inc(I);
      if (Pos('=', ParamStr(I)) < 2) or (StrToIntDef(Copy(ParamStr(I), Pos('=', ParamStr(I)) + 1, MaxInt), -1) <= 0) then
      begin
        WriteLn('Error: --number <block>=<n>, e.g. --number DB_HMI=10');
        Halt(2);
      end;
      Numbers.Add(Trim(ParamStr(I)));
    end
    else if ParamStr(I) = '--check' then CheckOnly := True
    else if (ParamStr(I) = '-h') or (ParamStr(I) = '--help') then begin Usage; Halt(0); end
    else ProjFile := ParamStr(I);
    Inc(I);
  end;

  if DumpFile <> '' then Halt(Dump(DumpFile));
  if SimFile <> '' then Halt(RunScript(SimFile, ScriptFile));

  if ImportDir <> '' then
  begin
    if not CpuFromName(CpuOverride, Cpu) then
    begin
      WriteLn('Error: --cpu S7-300|S7-400|S7-1200|S7-1500 required');
      Halt(2);
    end;
    if ProjFile = '' then ProjFile := IncludeTrailingPathDelimiter(ImportDir) + 'project.sclproj';
    Halt(ImportFolder(ImportDir, ProjFile, Cpu, Numbers));
  end;

  if ProjFile = '' then
  begin
    Usage;
    Halt(2);
  end;

  P := TSclProject.Create;
  C := TSclCompiler.Create(P);
  try
    try
      P.LoadFromFile(ProjFile);
    except
      on E: Exception do
      begin
        WriteLn('Error: cannot load project: ', E.Message);
        Halt(2);
      end;
    end;
    if CpuOverride <> '' then
      if CpuFromName(CpuOverride, Cpu) then P.Cpu := Cpu;
    WriteLn('Compiling ', P.Name, ' for ', CpuNames[P.Cpu], ' (', P.Sources.Count, ' sources, ', P.Tags.Count, ' tags)');
    T0 := GetTickCount64;
    C.Compile(not CheckOnly);
    if FindDecl <> '' then
    begin
      { file:line:col  (file may contain a drive colon) }
      FdParts := FindDecl.Split([':']);
      FdCol := StrToInt(FdParts[High(FdParts)]);
      FdLine := StrToInt(FdParts[High(FdParts) - 1]);
      FdFile := P.AbsPath(Copy(FindDecl, 1, Length(FindDecl) - Length(FdParts[High(FdParts)]) - Length(FdParts[High(FdParts) - 1]) - 2));
      FdLines := TStringList.Create;
      FdLines.LoadFromFile(FdFile);
      FdRes := FindDeclarationAt(C, FdFile, FdLines[FdLine - 1], FdLine, FdCol);
      FdLines.Free;
      WriteLn(Format('%s -> kind=%d %s(%d,%d)  %s', [FdRes.Name, Ord(FdRes.Kind), ExtractFileName(FdRes.Pos.FileName), FdRes.Pos.Line, FdRes.Pos.Col, FdRes.Info]));
      Halt(0);
    end;
    for I := 0 to C.Diags.Count - 1 do WriteLn(C.Diags[I].ToString);
    WriteLn(Format('%d error(s), %d warning(s), %d ms', [C.Diags.ErrorCount, C.Diags.WarningCount, GetTickCount64 - T0]));
    if C.Diags.ErrorCount > 0 then Halt(1);
    if not CheckOnly then
    begin
      if OutFile = '' then OutFile := P.OutputFile;
      C.SaveImage(OutFile);
      WriteLn('Image written: ', OutFile, ' (', C.Image.Blocks.Count, ' code blocks, ', C.Image.DataBlocks.Count, ' data blocks)');
      if LstFile <> '' then
      begin
        with TStringList.Create do
        try
          Text := C.ListingText;
          SaveToFile(LstFile);
        finally
          Free;
        end;
        WriteLn('Listing written: ', LstFile);
      end;
    end;
  finally
    C.Free;
    P.Free;
  end;
end.
