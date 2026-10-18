{ sclc - SCL command line compiler for the Virtual PLC }
program sclc;

{$mode objfpc}{$H+}

uses
  Classes, SysUtils, scl_base, scl_types, scl_ast, scl_lexer, scl_project, scl_vmformat, scl_vmmem,
  scl_compiler, scl_vm, scl_navigate;

procedure Usage;
begin
  WriteLn('SCL Compiler ', COMPILER_VERSION, ' - Siemens S7-300/400/1200/1500 SCL to Virtual PLC (.svpl)');
  WriteLn;
  WriteLn('Usage:');
  WriteLn('  sclc <project.sclproj> [-o <image.svpl>] [-l <listing.lst>] [--check]');
  WriteLn('  sclc --import <folder> --cpu <S7-300|S7-400|S7-1200|S7-1500> -p <project.sclproj>');
  WriteLn('  sclc --dump <image.svpl>');
  WriteLn('  sclc --sim <image.svpl> --script <test.txt>   (run the reference Virtual PLC)');
  WriteLn;
  WriteLn('Options:');
  WriteLn('  -o <file>     output image (default: <project dir>\output\<name>.svpl)');
  WriteLn('  -l <file>     write listing (disassembly + memory map)');
  WriteLn('  --check       syntax / type check only, no output');
  WriteLn('  --cpu <cpu>   override the CPU family of the project');
end;

function ImportFolder(const Dir, ProjFile: string; Cpu: TCpuFamily): Integer;
var
  P: TSclProject;
  SR: TSearchRec;
  L: TStringList;
  I: Integer;
begin
  P := TSclProject.Create;
  L := TStringList.Create;
  try
    P.FileName := ExpandFileName(ProjFile);
    P.Name := ChangeFileExt(ExtractFileName(ProjFile), '');
    P.Cpu := Cpu;
    if FindFirst(IncludeTrailingPathDelimiter(Dir) + '*.scl', faAnyFile, SR) = 0 then
    repeat
      L.Add(SR.Name);
    until FindNext(SR) <> 0;
    FindClose(SR);
    L.Sort;
    for I := 0 to L.Count - 1 do
      P.Sources.Add(P.RelPath(IncludeTrailingPathDelimiter(ExpandFileName(Dir)) + L[I]));
    L.Clear;
    if FindFirst(IncludeTrailingPathDelimiter(Dir) + '*.csv', faAnyFile, SR) = 0 then
    repeat
      L.Add(SR.Name);
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
            for K := 0 to High(Links) do
              Plc.WriteAddr(Links[K].Dst, Links[K].DVT, Plc.ReadAddr(Links[K].Src, Links[K].SVT));
            Plc.Cycle(CycleMs);
            Dec(N);
          end;
        end
        else if (Cmd = 'set') or (Cmd = 'expect') or (Cmd = 'print') then
        begin
          Path := Parts[1];
          if not Plc.FindVar(Path, A, VT, TT) then raise Exception.Create('unknown variable ' + Path);
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
    WriteLn(Format('%d passed, %d failed, %d cycles, simulated %.2f s', [Passes, Fails, Plc.CycleCount, Plc.NowNs / 1e9]));
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
begin
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
    Halt(ImportFolder(ImportDir, ProjFile, Cpu));
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
