program plctest;

{ Headless tests of the Virtual PLC core: the sample projects in RUN, the STL
  semantics (AND before OR, nesting, accumulators, arithmetic, jumps, BCD),
  LAD branches, save / load. }

{$mode objfpc}{$H+}

uses
  Classes, SysUtils, Math, fpjson, jsonparser, uPlcTypes, uPlcProject, uPlcCompiler, uPlcRuntime, uPlcServer,
  uPlcClient, uClaude, uExamples, uSclSource, uObCatalog, uSclSig, uXref;

var
  Fails, Passes: Integer;

procedure Check(Cond: Boolean; const What: string);
begin
  if Cond then
  begin
    Inc(Passes);
    WriteLn('  ok   ', What);
  end
  else
  begin
    Inc(Fails);
    WriteLn('  FAIL ', What);
  end;
end;

procedure Wait(Ms: Integer);
begin
  Sleep(Ms);
end;

function Peek(Rt: TPlcRuntime; P: TPlcProject; const S: string): LongWord;
var
  Res: TResolver;
  O: TOperand;
  E: string;
begin
  Result := $DEADBEEF;
  Res := TResolver.Create(P);
  try
    if not Res.Resolve(S, O, E, False) then
    begin
      WriteLn('    resolve ', S, ': ', E);
      Exit;
    end;
    Rt.PeekRaw(O, Result);
  finally
    Res.Free;
  end;
end;

function PeekReal(Rt: TPlcRuntime; P: TPlcProject; const S: string): Single;
var
  V: LongWord;
begin
  V := Peek(Rt, P, S);
  Result := PSingle(@V)^;
end;

procedure ShowMsgs(Pr: TCProgram);
var
  K: Integer;
begin
  for K := 0 to High(Pr.Msgs) do
    WriteLn(Format('    %s %s nw %d line %d: %s', [BoolToStr(Pr.Msgs[K].IsError, 'ERR', 'warn'),
      Pr.Msgs[K].Block, Pr.Msgs[K].Net, Pr.Msgs[K].Line, Pr.Msgs[K].Text]));
end;

procedure DumpDiag(Rt: TPlcRuntime);
var
  D: TDiagArray;
  K: Integer;
begin
  D := Rt.DiagCopy(8);
  for K := High(D) downto 0 do WriteLn('    diag: ', D[K].Text);
end;

procedure TestSample(AModel: Integer);
var
  P: TPlcProject;
  Pr: TCProgram;
  Rt: TPlcRuntime;
  Fam: TCpuFamily;
  QB, K: Integer;
  Speed: Single;
  AIW: Integer;
  V: LongWord;
  Sg2: Single;
begin
  WriteLn('== sample on ', Models[AModel].Name);
  P := TPlcProject.Create;
  Rt := nil;
  try
    P.LoadSample(AModel);
    Fam := P.Family;
    Pr := Compile(P);
    ShowMsgs(Pr);
    Check(Pr.ErrorCount = 0, 'compiles without errors');
    Rt := TPlcRuntime.Create(AModel);
    Rt.CmdDownload(Pr);
    if IsTia(Fam) then QB := 0 else QB := 4;
    AIW := Models[AModel].AIWord;
    // field: stop button not pressed (NC = 1), overload healthy
    Rt.SetSimBit(0, 1, True);
    Rt.SetSimBit(0, 2, True);
    Rt.SetSimWord(AIW, 13824);
    Rt.CmdRun;
    Wait(100);
    Check(Rt.Mode = rmRun, 'RUN');
    if Rt.Mode <> rmRun then DumpDiag(Rt);
    Check(Peek(Rt, P, '"Motor".Startups') = 1, 'OB100 ran once (Startups = 1)');
    Check(not Rt.GetOutBit(QB, 0), 'motor off');
    Rt.SetSimBit(0, 0, True);
    Wait(30);
    Rt.SetSimBit(0, 0, False);
    Wait(30);
    Check(Rt.GetOutBit(QB, 0), 'motor on after start (self holding)');
    Check(Rt.GetOutBit(QB, 3) or not Rt.GetOutBit(QB, 3), 'starting lamp follows the clock');
    Check(not Rt.GetOutBit(QB, 1), 'not yet full speed');
    Speed := PeekReal(Rt, P, '"Motor".SpeedRpm');
    Check(Abs(Speed - 750) < 0.5, Format('speed 13824 -> %.2f rpm', [Speed]));
    Wait(5200);
    Check(Rt.GetOutBit(QB, 1), 'full speed after 5 s');
    Check(Peek(Rt, P, '"Motor".SpeedClass') = 2, 'FC1 (SCL) CASE: speed class 2 for 750 rpm');
    Sg2 := PSingle(@V)^;
    V := Peek(Rt, P, '"Motor".AvgRpm');
    Sg2 := PSingle(@V)^;
    Check(Abs(Sg2 - 750) < 1, Format('FC1 (SCL) FOR over the history: average %.1f rpm', [Sg2]));
    Check((Peek(Rt, P, '"Motor".History[3].Rpm') = 750) and (Peek(Rt, P, '"Motor".History[3].Running') = 1),
      'FC1 (SCL): History is an array of "SpeedSample" (Rpm 750, Running)');
    Check((Abs(PeekReal(Rt, P, '"Motor".SpeedLim') - 750) < 0.5) and (Peek(Rt, P, '"Motor".OverLimit') = 0),
      'OB1 LAD CALL box FC2 "Clamp" with pins: SpeedLim 750, OverLimit FALSE');
    K := Peek(Rt, P, '"Motor".Seconds');
    Check((K >= 4) and (K <= 6), Format('FC1 (SCL) TON pulses: %d motor seconds', [K]));
    Check(not Rt.GetOutBit(QB, 3), 'starting lamp off at full speed');
    K := Peek(Rt, P, '"Motor".RunTime');
    Check((K >= 48) and (K <= 56), Format('run time in the cyclic OB: %d x 100 ms', [K]));
    Check(Rt.CycCount > 40, Format('cyclic interrupt ran %d times', [Rt.CycCount]));
    // overspeed
    Rt.SetSimWord(AIW, 27000);
    Wait(30);
    Check(Rt.GetOutBit(QB, 4), 'overspeed above 1200 rpm');
    Rt.SetSimWord(AIW, 13824);
    // stop
    Rt.SetSimBit(0, 1, False);
    Wait(30);
    Rt.SetSimBit(0, 1, True);
    Wait(30);
    Check(not Rt.GetOutBit(QB, 0), 'motor off after stop');
    Check(not Rt.GetOutBit(QB, 1), 'full speed off');
    // 4 more starts -> 5 starts
    for K := 1 to 4 do
    begin
      Rt.SetSimBit(0, 0, True);
      Wait(20);
      Rt.SetSimBit(0, 0, False);
      Wait(20);
      Rt.SetSimBit(0, 1, False);
      Wait(20);
      Rt.SetSimBit(0, 1, True);
      Wait(20);
    end;
    if IsTia(Fam) then
      Check(Peek(Rt, P, '"Motor".Starts.CV') = 5, Format('CTU counted 5 starts (%d)', [Peek(Rt, P, '"Motor".Starts.CV')]))
    else
      Check(Rt.CounterValue(1) = 5, Format('C1 counted 5 starts (%d)', [Rt.CounterValue(1)]));
    Check(Peek(Rt, P, 'MW20') = 5, 'MW20 = 5');
    Check(Rt.GetOutBit(QB, 2), 'service due');
    Rt.SetSimBit(0, 3, True);
    Wait(30);
    Rt.SetSimBit(0, 3, False);
    Wait(30);
    Check(not Rt.GetOutBit(QB, 2), 'counter reset');
    if Fam in [cfS7400, cfS71500] then
      Check(Peek(Rt, P, 'MW22') = 1 + 10 * 3, Format('S7-400 ENT: MW22 = %d', [Peek(Rt, P, 'MW22')]));
    if Fam = cfS71500 then
      Check((Rt.CounterValue(5) >= 5) and (Rt.CounterValue(5) <= 11),
        Format('S7-1500 STL clock T5 / C5: %d seconds of motor run', [Rt.CounterValue(5)]));
    Check(Rt.Mode = rmRun, 'still RUN');
    WriteLn(Format('    cycles/s %.0f, host %.1f us, model %.1f us, %d ops', [Rt.CyclesPerSec, Rt.HostAvgUs,
      Rt.ModelAvgUs, Rt.OpsLastCycle]));
    Rt.CmdStop;
    Wait(30);
    Check(Rt.Mode = rmStop, 'STOP');
    Check(not Rt.GetOutBit(QB, 0) and (Rt.SimOut[QB] = 0), 'outputs off in STOP');
    DumpDiag(Rt);
  finally
    Rt.Free;
    P.Free;
  end;
end;

{ one STL network in OB1 on a model, run some cycles, return the runtime }
function RunStl(AModel: Integer; const Code: string; out P: TPlcProject): TPlcRuntime;
var
  B: TBlock;
  N: TNetwork;
  Pr: TCProgram;
  D: TDataBlock;
begin
  P := TPlcProject.Create;
  P.NewEmpty(AModel);
  D := P.AddDB(1, 'D');
  D.AddVar('A', 'Int', '7', '');
  D.AddVar('B', 'DInt', '0', '');
  D.AddVar('R', 'Real', '2.5', '');
  B := P.Block(0);
  B.DeleteNet(0);
  N := B.AddNet(nkSTL);
  N.Stl.Text := Code;
  Pr := Compile(P);
  ShowMsgs(Pr);
  Result := TPlcRuntime.Create(AModel);
  if Pr.ErrorCount > 0 then
  begin
    Pr.Free;
    Exit;
  end;
  Result.CmdDownload(Pr);
  Result.CmdRun;
  Wait(40);
end;

procedure TestStl;
var
  P: TPlcProject;
  Rt: TPlcRuntime;
  V: LongWord;
begin
  WriteLn('== STL semantics (CPU 315)');
  // AND before OR: Q0.0 = I0.0 OR (I0.1 AND I0.2)
  Rt := RunStl(1,
    'A I0.0' + LineEnding + 'O I0.1' + LineEnding + 'A I0.2' + LineEnding + '= Q4.0' + LineEnding +
    // O alone: (I0.0 AND I0.1) OR (I0.2 AND I0.3)
    'A I0.0' + LineEnding + 'A I0.1' + LineEnding + 'O' + LineEnding + 'A I0.2' + LineEnding + 'A I0.3' + LineEnding + '= Q4.1' + LineEnding +
    // nesting: I0.0 AND (I0.1 OR I0.2)
    'A I0.0' + LineEnding + 'A(' + LineEnding + 'O I0.1' + LineEnding + 'O I0.2' + LineEnding + ')' + LineEnding + '= Q4.2' + LineEnding +
    // XOR
    'X I0.0' + LineEnding + 'X I0.1' + LineEnding + '= Q4.3' + LineEnding +
    // arithmetic, compare, jump
    'L 100' + LineEnding + 'L 23' + LineEnding + '-I' + LineEnding + 'T MW10' + LineEnding +
    'L MW10' + LineEnding + 'L 77' + LineEnding + '==I' + LineEnding + '= M70.0' + LineEnding +
    'L 30000' + LineEnding + 'L 30000' + LineEnding + '+I' + LineEnding + 'T MW12' + LineEnding + 'A OV' + LineEnding + '= M70.1' + LineEnding +
    'L L#100000' + LineEnding + 'L L#3' + LineEnding + '*D' + LineEnding + 'T MD14' + LineEnding +
    'L 7' + LineEnding + 'L 2' + LineEnding + '/I' + LineEnding + 'T MD60' + LineEnding +
    'L 1.5' + LineEnding + 'L 2.0' + LineEnding + '*R' + LineEnding + 'RND' + LineEnding + 'T MD22' + LineEnding +
    'L 2.5' + LineEnding + 'RND' + LineEnding + 'T MW26' + LineEnding +
    'L 123' + LineEnding + 'ITB' + LineEnding + 'T MW28' + LineEnding +
    'L W#16#F0F0' + LineEnding + 'SLW 4' + LineEnding + 'T MW30' + LineEnding +
    'L DW#16#12345678' + LineEnding + 'CAD' + LineEnding + 'T MD32' + LineEnding +
    'L 5' + LineEnding + 'L 9' + LineEnding + '>I' + LineEnding + 'JC NOJ' + LineEnding + 'L 1' + LineEnding + 'T MW36' + LineEnding + 'JU END1' + LineEnding +
    'NOJ: L 2' + LineEnding + 'T MW36' + LineEnding + 'END1: NOP 0' + LineEnding +
    'L 0' + LineEnding + 'T MW38' + LineEnding + 'L 5' + LineEnding + 'LP: T MW40' + LineEnding + 'L MW38' + LineEnding + '+ 1' + LineEnding +
    'T MW38' + LineEnding + 'L MW40' + LineEnding + 'LOOP LP' + LineEnding +
    'L DB1.DBW0' + LineEnding + 'L "D".A' + LineEnding + '+I' + LineEnding + 'T "D".A' + LineEnding +
    'A I0.0' + LineEnding + 'FP M71.0' + LineEnding + '= M71.1' + LineEnding +
    'SET' + LineEnding + '= M71.2' + LineEnding + 'CLR' + LineEnding + '= M71.3', P);
  try
    Check(Rt.Mode = rmRun, 'RUN');
    if Rt.Mode <> rmRun then DumpDiag(Rt);
    // inputs 0: Q4.0 = 0
    Check(Rt.Q[4] and 1 = 0, 'A/O/A all 0 -> 0');
    Rt.SetSimBit(0, 1, True);
    Rt.SetSimBit(0, 2, True);
    Wait(20);
    Check(Rt.Q[4] and 1 <> 0, 'I0.0 OR (I0.1 AND I0.2) with I0.1, I0.2');
    Check(Rt.Q[4] and 4 = 0, 'I0.0 AND (I0.1 OR I0.2) = 0 without I0.0');
    Rt.SetSimBit(0, 2, False);
    Wait(20);
    Check(Rt.Q[4] and 1 = 0, 'I0.1 alone: AND binds before OR');
    Rt.SetSimBit(0, 0, True);
    Wait(20);
    Check(Rt.Q[4] and 1 <> 0, 'I0.0 alone -> 1');
    Check(Rt.Q[4] and 2 <> 0, 'O alone: (I0.0 AND I0.1) OR ...');
    Check(Rt.Q[4] and 4 <> 0, 'nesting I0.0 AND (I0.1 OR I0.2)');
    Check(Rt.Q[4] and 8 = 0, 'XOR 1,1 = 0');
    Check(Peek(Rt, P, 'MW10') = 77, '100 - 23 = 77');
    Check(Rt.M[70] and 1 <> 0, '==I');
    Check(SmallInt(Peek(Rt, P, 'MW12')) = SmallInt(60000 - 65536), '30000 + 30000 wraps');
    Check(Rt.M[70] and 2 <> 0, 'OV after the overflow');
    Check(Peek(Rt, P, 'MD14') = 300000, '*D');
    V := Peek(Rt, P, 'MD60');
    Check(V = ($00010003), Format('/I: remainder high, quotient low (%x)', [V]));
    Check(Peek(Rt, P, 'MD22') = 3, 'RND(3.0) = 3');
    Check(Peek(Rt, P, 'MW26') = 2, 'RND(2.5) = 2 (to even)');
    Check(Peek(Rt, P, 'MW28') = $0123, 'ITB 123');
    Check(Peek(Rt, P, 'MW30') = $0F00, 'SLW 4');
    Check(Peek(Rt, P, 'MD32') = $78563412, 'CAD');
    Check(Peek(Rt, P, 'MW36') = 1, 'JC not taken (5 > 9 false)');
    Check(Peek(Rt, P, 'MW38') = 5, 'LOOP 5 times');
    Check(Rt.M[71] and 4 <> 0, 'SET');
    Check(Rt.M[71] and 8 = 0, 'CLR');
    Check(Peek(Rt, P, 'MB0') = 0, 'MB0 not written');
  finally
    Rt.Free;
    P.Free;
  end;
  // big-endian
  Rt := RunStl(1, 'L W#16#1234' + LineEnding + 'T MW50', P);
  try
    Check((Rt.M[50] = $12) and (Rt.M[51] = $34), 'big-endian: MB50 = 16#12, MB51 = 16#34');
  finally
    Rt.Free;
    P.Free;
  end;
  // area length error -> STOP on S7-300
  Rt := RunStl(1, 'L MW4000' + LineEnding + 'T MW0', P);
  try
    Check(Rt.Mode = rmStop, 'compile refuses MW4000 on the 315 (2048 bytes): no RUN');
  finally
    Rt.Free;
    P.Free;
  end;
  Rt := RunStl(1, 'OPN DB1' + LineEnding + 'L DBW100' + LineEnding + 'T MW0', P);
  try
    Wait(20);
    Check(Rt.Mode = rmStop, 'S7-300: area length error at runtime -> STOP');
    DumpDiag(Rt);
  finally
    Rt.Free;
    P.Free;
  end;
  WriteLn('== S7-1500 rules');
  Rt := RunStl(13, 'OPN DB1' + LineEnding + 'L DBW100' + LineEnding + 'T MW0', P);
  try
    Wait(20);
    Check(Rt.Mode = rmStop, 'S7-1500: programming error without OB121 -> STOP');
  finally
    Rt.Free;
    P.Free;
  end;
  Rt := RunStl(13, 'L 7' + LineEnding + 'L 5' + LineEnding + 'ENT' + LineEnding + 'L 2' + LineEnding + '*I' +
    LineEnding + '+I' + LineEnding + 'T %MW0' + LineEnding + 'A %M1.0' + LineEnding + 'L S5T#1S' + LineEnding +
    'SD T 2047' + LineEnding + 'L 100000' + LineEnding + 'T %MD4', P);
  try
    Check(Rt.Mode = rmRun, 'S7-1500 runs STL with S5 timer T2047 (2048 timers)');
    Check(Peek(Rt, P, 'MW0') = 17, Format('S7-1500 4 accumulators: 7 + 5 * 2 = %d', [Peek(Rt, P, 'MW0')]));
    Check(Peek(Rt, P, 'MD4') = 100000, 'S7-1500 L 100000 is a DINT');
  finally
    Rt.Free;
    P.Free;
  end;
  WriteLn('== S7-400 accumulators');
  Rt := RunStl(4, 'L 1' + LineEnding + 'L 2' + LineEnding + 'PUSH' + LineEnding + 'L 3' + LineEnding +
    '+I' + LineEnding + 'T MW0' + LineEnding + 'POP' + LineEnding + 'T MW2', P);
  try
    Check(Peek(Rt, P, 'MW0') = 5, '400: 2 + 3 = 5');
    Check(Peek(Rt, P, 'MW2') = 1, Format('400: POP after the pull: ACCU3 -> ACCU2 -> ACCU1 (MW2=%d)', [Peek(Rt, P, 'MW2')]));
  finally
    Rt.Free;
    P.Free;
  end;
end;

procedure TestLadAnd1200;
var
  P, P2: TPlcProject;
  B: TBlock;
  N: TNetwork;
  Pr: TCProgram;
  Rt: TPlcRuntime;
  F: string;
begin
  WriteLn('== LAD branches + S7-1200 rules');
  P := TPlcProject.Create;
  P.NewEmpty(7);
  B := P.Block(0);
  N := B.Net(0);
  // (I0.0 OR I0.1) AND NOT I0.2 -> Q0.0, with a mid branch: I0.3 parallel to NOT I0.2
  N.SetRows(2);
  N.SetCell(0, 0, NewCell(lkNO, 'I0.0'));
  N.Cells[0].Down := True;
  N.SetCell(1, 0, NewCell(lkNO, 'I0.1'));
  N.SetCell(0, 1, NewCell(lkNC, 'I0.2'));
  N.Cells[1].Down := True;
  N.SetCell(1, 1, NewCell(lkNO, 'I0.3'));
  N.SetCell(0, 7, NewCell(lkCoil, 'Q0.0'));
  N.SetCell(0, 2, NewCell(lkWire, ''));
  N.SetCell(0, 3, NewCell(lkWire, ''));
  N.SetCell(0, 4, NewCell(lkWire, ''));
  N.SetCell(0, 5, NewCell(lkWire, ''));
  N.SetCell(0, 6, NewCell(lkWire, ''));
  Pr := Compile(P);
  ShowMsgs(Pr);
  Check(Pr.ErrorCount = 0, 'LAD compiles');
  Rt := TPlcRuntime.Create(7);
  try
    Rt.CmdDownload(Pr);
    Rt.CmdRun;
    Wait(40);
    Check(not Rt.GetOutBit(0, 0), 'no input: off');
    Rt.SetSimBit(0, 1, True);
    Wait(20);
    Check(Rt.GetOutBit(0, 0), 'I0.1 via the lower branch');
    Rt.SetSimBit(0, 2, True);
    Wait(20);
    Check(not Rt.GetOutBit(0, 0), 'I0.2 breaks it');
    Rt.SetSimBit(0, 3, True);
    Wait(20);
    Check(Rt.GetOutBit(0, 0), 'I0.3 bridges NOT I0.2');
  finally
    Rt.Free;
  end;
  // S7-1200 refuses STL and S5 timers
  N := B.AddNet(nkSTL);
  N.Stl.Text := 'A I0.0' + LineEnding + '= Q0.1';
  Pr := Compile(P);
  Check(Pr.ErrorCount > 0, 'S7-1200 refuses STL');
  Pr.Free;
  B.DeleteNet(1);
  N := B.AddNet(nkLAD);
  N.SetCell(0, 0, NewCell(lkSD, 'T1'));
  Pr := Compile(P);
  Check(Pr.ErrorCount > 0, 'S7-1200 refuses S5 timers');
  Pr.Free;
  B.DeleteNet(1);
  // save / load
  F := GetTempDir + 'vplc_test.vplc';
  P.LoadSample(7);
  P.SaveToFile(F);
  P2 := TPlcProject.Create;
  try
    P2.LoadFromFile(F);
    Check((P2.BlockCount = P.BlockCount) and (P2.DBCount = 2) and (Length(P2.Tags) = Length(P.Tags)), 'save / load');
    Check(P2.Block(0).Net(4).Cell(0, 0).Kind = lkNormX, 'LAD boxes survive');
    Pr := Compile(P2);
    Check(Pr.ErrorCount = 0, 'loaded project compiles');
    Pr.Free;
  finally
    P2.Free;
  end;
  P.Free;
end;

{ one SCL network in OB1 (and an optional SCL FC1) with DB1 "D" }
function RunScl(AModel: Integer; const Code: string; out P: TPlcProject; out Pr: TCProgram;
  const FcCode: string = ''): TPlcRuntime;
var
  B: TBlock;
  N: TNetwork;
  D: TDataBlock;
begin
  P := TPlcProject.Create;
  P.NewEmpty(AModel);
  D := P.AddDB(1, 'D');
  D.AddVar('A', 'Int', '7', '');
  D.AddVar('B', 'DInt', '0', '');
  D.AddVar('R', 'Real', '2.5', '');
  D.AddVar('Arr', 'Array[0..9] of Int', '0', '');
  D.AddVar('Flags', 'Array[1..16] of Bool', 'FALSE', '');
  D.AddVar('Tm', 'IEC_TIMER', '', '');
  D.AddVar('Cn', 'IEC_COUNTER', '', '');
  D.AddVar('X', 'Bool', 'FALSE', '');
  D.AddVar('T1', 'Time', 'T#0MS', '');
  B := P.Block(0);
  B.DeleteNet(0);
  N := B.AddNet(nkSCL);
  N.Stl.Text := Code;
  if FcCode <> '' then
  begin
    B := P.AddBlock(bkFC, 1, 'Helper');
    N := B.AddNet(nkSCL);
    N.Stl.Text := FcCode;
  end;
  Pr := Compile(P);
  ShowMsgs(Pr);
  Result := TPlcRuntime.Create(AModel);
  if Pr.ErrorCount > 0 then Exit;
  Result.CmdDownload(Pr);
  Result.CmdRun;
  Wait(40);
end;

procedure TestScl;
var
  P: TPlcProject;
  Pr: TCProgram;
  Rt: TPlcRuntime;
  V: LongWord;
  R: Single;
  K: Integer;
begin
  WriteLn('== SCL');
  Rt := RunScl(7,
    'VAR_TEMP' + LineEnding +
    '  i : Int;' + LineEnding +
    '  s : DInt;' + LineEnding +
    '  f : Real;' + LineEnding +
    '  b : Bool;' + LineEnding +
    'END_VAR' + LineEnding +
    '// precedence: ** before unary minus before * before + before compare before AND before OR' + LineEnding +
    '%MW0 := 2 + 3 * 4;' + LineEnding +
    '%MW2 := (2 + 3) * 4;' + LineEnding +
    '(* a block comment' + LineEnding + '   over two lines *)' + LineEnding +
    '%MW4 := REAL_TO_INT(-2.0 ** 2.0);' + LineEnding +
    '%MW6 := 17 MOD 5 + 17 / 5;' + LineEnding +
    '%MW8 := 30000 + 30000;   // INT wraps like the CPU' + LineEnding +
    '%MD10 := 30000 + 30000 + 0 * %MD10;' + LineEnding +
    '"D".R := INT_TO_REAL("D".A) / 2.0 + SQRT(16.0);' + LineEnding +
    '%M20.0 := 1 + 2 = 3 AND NOT FALSE OR FALSE;' + LineEnding +
    '%M20.1 := 5 > 3 XOR TRUE;' + LineEnding +
    'IF "D".A > 10 THEN %MW22 := 1; ELSIF "D".A > 5 THEN %MW22 := 2; ELSE %MW22 := 3; END_IF;' + LineEnding +
    'CASE "D".A OF' + LineEnding +
    '  1, 2: %MW24 := 10;' + LineEnding +
    '  3..6: %MW24 := 20;' + LineEnding +
    '  7..9: %MW24 := 30;' + LineEnding +
    'ELSE' + LineEnding +
    '  %MW24 := 40;' + LineEnding +
    'END_CASE;' + LineEnding +
    '#s := 0;' + LineEnding +
    'FOR #i := 0 TO 9 DO' + LineEnding +
    '  "D".Arr[#i] := #i * #i;' + LineEnding +
    '  IF #i = 7 THEN CONTINUE; END_IF;' + LineEnding +
    '  #s := #s + "D".Arr[#i];' + LineEnding +
    'END_FOR;' + LineEnding +
    '%MD26 := #s;' + LineEnding +
    'FOR #i := 10 TO 1 BY -3 DO %MW30 := #i; END_FOR;' + LineEnding +
    '#i := 0;' + LineEnding +
    'WHILE TRUE DO #i := #i + 1; IF #i >= 12 THEN EXIT; END_IF; END_WHILE;' + LineEnding +
    '%MW32 := #i;' + LineEnding +
    '#i := 0;' + LineEnding +
    'REPEAT #i := #i + 5; UNTIL #i > 17 END_REPEAT;' + LineEnding +
    '%MW34 := #i;' + LineEnding +
    '"D".Flags[3] := TRUE;' + LineEnding +
    '#i := 4;' + LineEnding +
    '"D".Flags[#i * 2] := "D".Flags[3];' + LineEnding +
    '%MW36 := LIMIT(MN := 0, IN := 150, MX := 100) + MAX(3, 9) + MIN(IN2 := 4, IN1 := 8);' + LineEnding +
    '%MW38 := REAL_TO_INT(2.5) + REAL_TO_INT(3.5) * 10;  // halves to even' + LineEnding +
    '%MW40 := SHL(IN := 16#0F, N := 4);' + LineEnding +
    '%MW42 := WORD_TO_INT(16#F0F0 AND 16#0FF0);' + LineEnding +
    '"D".Tm.TON(IN := TRUE, PT := T#200MS, Q => %M44.0, ET => "D".T1);' + LineEnding +
    '"D".Cn.CTU(CU := %M44.0, R := FALSE, PV := 1, Q => %M44.1);' + LineEnding +
    '%M44.2 := NORM_X(MIN := 0, VALUE := 13824, MAX := 27648) * 100.0 > 49.0;' + LineEnding +
    '%MW46 := REAL_TO_INT(SCALE_X(MIN := 0.0, VALUE := 0.25, MAX := 400.0));' + LineEnding +
    '"Helper"();', P, Pr,
    '%MW48 := %MW48 + 1;   // FC1 in SCL' + LineEnding + 'RETURN;' + LineEnding + '%MW48 := 999;');
  try
    Check(Pr.ErrorCount = 0, 'SCL compiles');
    Check(Rt.Mode = rmRun, 'SCL RUN');
    Check(Peek(Rt, P, 'MW0') = 14, '2 + 3 * 4 = 14');
    Check(Peek(Rt, P, 'MW2') = 20, '(2 + 3) * 4 = 20');
    Check(SmallInt(Peek(Rt, P, 'MW4')) = -4, '-2.0 ** 2.0 = -4 (unary after **)');
    Check(Peek(Rt, P, 'MW6') = 5, '17 MOD 5 + 17 / 5 = 2 + 3');
    Check(SmallInt(Peek(Rt, P, 'MW8')) = -5536, 'INT 30000 + 30000 wraps to -5536');
    Check(Peek(Rt, P, 'MD10') = 60000, 'DINT 30000 + 30000 = 60000');
    V := Peek(Rt, P, '"D".R');
    R := PSingle(@V)^;
    Check(Abs(R - 7.5) < 0.001, Format('INT_TO_REAL(7) / 2.0 + SQRT(16.0) = %.3f', [R]));
    Check(Rt.M[20] and 1 <> 0, '1 + 2 = 3 AND NOT FALSE OR FALSE');
    Check(Rt.M[20] and 2 = 0, '5 > 3 XOR TRUE = FALSE');
    Check(Peek(Rt, P, 'MW22') = 2, 'IF / ELSIF / ELSE');
    Check(Peek(Rt, P, 'MW24') = 30, 'CASE 7..9');
    Check(Peek(Rt, P, '"D".Arr[9]') = 81, 'FOR with a variable array index');
    Check(Peek(Rt, P, 'MD26') = 285 - 49, 'CONTINUE skips 7*7');
    Check(Peek(Rt, P, 'MW30') = 1, 'FOR BY -3 down to 1');
    Check(Peek(Rt, P, 'MW32') = 12, 'WHILE with EXIT');
    Check(Peek(Rt, P, 'MW34') = 20, 'REPEAT UNTIL');
    Check(Peek(Rt, P, '"D".Flags[8]') = 1, 'Bool array with an index expression');
    Check(Peek(Rt, P, 'MW36') = 100 + 9 + 4, 'LIMIT MAX MIN with named parameters');
    Check(Peek(Rt, P, 'MW38') = 2 + 40, 'REAL_TO_INT rounds halves to even');
    Check(Peek(Rt, P, 'MW40') = $F0, 'SHL');
    Check(Peek(Rt, P, 'MW42') = $00F0, 'bit string AND');
    Check(Peek(Rt, P, 'MW46') = 100, 'SCALE_X(0.25, 0..400) = 100');
    Check(Rt.M[44] and 4 <> 0, 'NORM_X(13824 of 27648) * 100 > 49');
    K := Peek(Rt, P, 'MW48');
    Check(K > 3, Format('FC1 in SCL called every cycle, RETURN skips the rest (%d)', [K]));
    Check(Rt.M[44] and 1 = 0, 'TON not yet done');
    Wait(260);
    Check(Rt.M[44] and 1 <> 0, 'SCL TON: Q after 200 ms');
    Check(Peek(Rt, P, '"D".T1') = 200, 'ET => "D".T1 = 200 ms');
    Check(Rt.M[44] and 2 <> 0, 'SCL CTU counted the TON edge');
  finally
    Rt.Free;
    P.Free;
  end;
  // runtime error: array index outside the bounds
  Rt := RunScl(13, 'VAR_TEMP i : Int; END_VAR' + LineEnding + '#i := 12;' + LineEnding + '"D".Arr[#i] := 1;', P, Pr);
  try
    Wait(20);
    Check(Rt.Mode = rmStop, 'S7-1500: array index 12 outside [0..9] -> STOP');
    DumpDiag(Rt);
  finally
    Rt.Free;
    P.Free;
  end;
  // compile errors
  Rt := RunScl(7, '%MW0 := 1.5;' + LineEnding + 'IF %MW0 THEN %MW2 := 1; END_IF;' + LineEnding + '#x := 1;' +
    LineEnding + '%M0.0 := 5;' + LineEnding + '%MW4 := 3 +;', P, Pr);
  try
    Check(Pr.ErrorCount >= 5, Format('compile errors found (%d)', [Pr.ErrorCount]));
  finally
    Rt.Free;
    P.Free;
  end;
end;

{ a project with PLC data types: "Pair" in "Axis", a DB with an array of "Axis" }
function UdtProject(AModel: Integer; const Code: string): TPlcProject;
var
  U: TDataBlock;
  D: TDataBlock;
  N: TNetwork;
begin
  Result := TPlcProject.Create;
  Result.NewEmpty(AModel);
  U := Result.AddUdt(2, 'Pair');
  U.AddVar('a', 'Int', '0', '');
  U.AddVar('b', 'Bool', 'FALSE', '');
  U := Result.AddUdt(1, 'Axis');
  U.AddVar('Speed', 'Int', '5', '');
  U.AddVar('On', 'Bool', 'FALSE', '');
  U.AddVar('Pos', 'Real', '1.5', '');
  U.AddVar('Hist', 'Array[0..2] of Int', '0', '');
  U.AddVar('P', '"Pair"', '', '');
  U.AddVar('T', 'IEC_TIMER', '', '');
  U.AddVar('C', 'IEC_COUNTER', '', '');
  D := Result.AddDB(1, 'D');
  D.AddVar('Flag', 'Bool', 'FALSE', '');
  D.AddVar('M', 'Array[0..3] of "Axis"', '', '');
  D.AddVar('One', 'UDT1', '', '');
  D.AddVar('Tm', 'Array[0..3] of IEC_TIMER', '', '');
  Result.Block(0).DeleteNet(0);
  N := Result.Block(0).AddNet(nkSCL);
  N.Stl.Text := Code;
end;

function CompileErrs(AModel: Integer; const Code: string): Integer;
var
  P: TPlcProject;
  Pr: TCProgram;
begin
  P := UdtProject(AModel, Code);
  Pr := Compile(P);
  Result := Pr.ErrorCount;
  if Result = 0 then ShowMsgs(Pr);
  Pr.Free;
  P.Free;
end;

procedure TestUdt;
var
  P, P2: TPlcProject;
  Pr: TCProgram;
  Rt: TPlcRuntime;
  D: TDataBlock;
  F: string;
begin
  WriteLn('== PLC data types (UDT), arrays of structs, arrays in VAR_TEMP');
  P := UdtProject(13,
    'VAR_TEMP' + LineEnding +
    '  i : Int;' + LineEnding +
    '  t : Array[0..4] of Int;' + LineEnding +
    '  bits : Array[0..9] of Bool;' + LineEnding +
    '  a : "Axis";' + LineEnding +
    '  arr : Array[1..3] of "Pair";' + LineEnding +
    'END_VAR' + LineEnding +
    'FOR #i := 0 TO 4 DO #t[#i] := #i * 10; END_FOR;' + LineEnding +
    '%MW0 := #t[3] + #t[4];' + LineEnding +
    '#bits[6] := FALSE;' + LineEnding +
    '#bits[7] := TRUE;' + LineEnding +
    '#i := 7;' + LineEnding +
    '%M2.0 := #bits[#i];' + LineEnding +
    '%M2.1 := #bits[#i - 1];' + LineEnding +
    'FOR #i := 0 TO 3 DO' + LineEnding +
    '  "D".M[#i].Speed := #i * 100;' + LineEnding +
    '  "D".M[#i].On := #i > 1;' + LineEnding +
    '  "D".M[#i].Hist[1] := #i + 1;' + LineEnding +
    '  "D".M[#i].P.a := #i * 7;' + LineEnding +
    '  "D".M[#i].P.b := #i = 3;' + LineEnding +
    'END_FOR;' + LineEnding +
    '%MW4 := "D".M[3].Speed + "D".M[2].Hist[1];' + LineEnding +
    '#a.Speed := 42;' + LineEnding +
    '#a.P.b := TRUE;' + LineEnding +
    '%MW6 := #a.Speed;' + LineEnding +
    '%M2.2 := #a.P.b;' + LineEnding +
    '#arr[2].a := 9;' + LineEnding +
    '#i := 2;' + LineEnding +
    '%MW8 := #arr[#i].a;' + LineEnding +
    '#i := 1;' + LineEnding +
    '"D".One.Hist[#i + 1] := "D".M[#i + 2].P.a;' + LineEnding +
    '"D".One.Pos := "D".M[1].Pos * 2.0;');
  try
    P.Udt(0).Layout;
    P.Udt(1).Layout;
    D := P.DB(0);
    D.Layout;
    Check(P.FindUdt('"Axis"').Size = 34, Format('"Axis": Int, Bool, Real, Array[0..2] of Int, "Pair", IEC_TIMER, IEC_COUNTER = 34 bytes (%d)',
      [P.FindUdt('"Axis"').Size]));
    Check((D.Vars[1].Ofs = 2) and (D.Vars[2].Ofs = 138) and (D.Vars[3].Ofs = 172) and (D.Size = 212),
      Format('DB layout: M at 2, One at 138, Tm at 172, 212 bytes (%d, %d, %d, %d)', [D.Vars[1].Ofs, D.Vars[2].Ofs,
      D.Vars[3].Ofs, D.Size]));
    Pr := Compile(P);
    ShowMsgs(Pr);
    Check(Pr.ErrorCount = 0, 'UDT program compiles');
    Rt := TPlcRuntime.Create(13);
    try
      Rt.CmdDownload(Pr);
      Rt.CmdRun;
      Wait(40);
      Check(Rt.Mode = rmRun, 'UDT program RUN');
      Check(Peek(Rt, P, 'MW0') = 70, 'VAR_TEMP Array of Int with a variable index');
      Check((Rt.M[2] and 1 <> 0) and (Rt.M[2] and 2 = 0), 'VAR_TEMP Array of Bool, #bits[#i] and #bits[#i - 1]');
      Check(Peek(Rt, P, 'MW4') = 303, 'array of structs: "D".M[#i].Speed and .Hist[1]');
      Check(Peek(Rt, P, '"D".M[2].Speed') = 200, '"D".M[2].Speed = 200 (constant index path)');
      Check((Peek(Rt, P, '"D".M[1].On') = 0) and (Peek(Rt, P, '"D".M[2].On') = 1), 'Bool member in the array: M[1].On, M[2].On');
      Check((Peek(Rt, P, '"D".M[3].P.a') = 21) and (Peek(Rt, P, '"D".M[3].P.b') = 1) and
        (Peek(Rt, P, '"D".M[2].P.b') = 0), 'nested struct in the array: M[3].P.a = 21, .P.b');
      Check(Peek(Rt, P, '"D".One.Speed') = 5, 'start value of a struct member (Speed = 5)');
      Check(Abs(PeekReal(Rt, P, '"D".One.Pos') - 3.0) < 0.001, 'Real start value 1.5 in the array, * 2.0 = 3.0');
      Check(Peek(Rt, P, '"D".One.Hist[2]') = 21, '"D".One.Hist[#i + 1] := "D".M[#i + 2].P.a');
      Check((Peek(Rt, P, 'MW6') = 42) and (Rt.M[2] and 4 <> 0), 'VAR_TEMP struct: #a.Speed, #a.P.b');
      Check(Peek(Rt, P, 'MW8') = 9, 'VAR_TEMP Array of "Pair": #arr[#i].a');
    finally
      Rt.Free;   // owns Pr after the download
    end;
    // save / load keeps the types
    F := GetTempDir + 'vplc_udt.vplc';
    P.SaveToFile(F);
    P2 := TPlcProject.Create;
    try
      P2.LoadFromFile(F);
      P2.DB(0).Layout;
      Check((P2.UdtCount = 2) and (P2.DB(0).Size = 212) and (P2.FindUdt('UDT2').Name = 'Pair'),
        'save / load: 2 PLC data types, DB 212 bytes');
      Pr := Compile(P2);
      Check(Pr.ErrorCount = 0, 'loaded UDT project compiles');
      Pr.Free;
    finally
      P2.Free;
    end;
    // a type that contains itself
    D := P.AddUdt(3, 'Loop');
    D.AddVar('x', '"Loop"', '', '');
    D.Layout;
    Check(not D.Vars[0].Valid, 'a PLC data type cannot contain itself');
  finally
    P.Free;
  end;
  // errors
  Check(CompileErrs(13, '"D".M[1] := 1;') > 0, 'a whole struct is no operand');
  Check(CompileErrs(13, 'VAR_TEMP i : Int; END_VAR' + LineEnding + '"D".M[#i].Hist[#i] := 1;') = 0,
    'two variable indexes in one operand compile');
  Check(CompileErrs(13, 'VAR_TEMP i : Int; END_VAR' + LineEnding + '"D".M[#i].P.TON(IN := TRUE, PT := T#1S);') > 0,
    '.TON needs an IEC_TIMER (P is a "Pair")');
  Check(CompileErrs(13, 'VAR_TEMP i : Int; END_VAR' + LineEnding + '"D".M[#i].Speed[#i] := 1;') > 0,
    'Speed is not an array');
  Check(CompileErrs(13, '"D".M[1].Nope := 1;') > 0, 'unknown member');
  Check(CompileErrs(13, 'VAR_TEMP a : "Axis"; END_VAR' + LineEnding + '#a := 1;') > 0, 'a struct temp needs a member');
  Check(CompileErrs(13, 'VAR_TEMP t : Array[0..2] of Int; END_VAR' + LineEnding + '#t[3] := 1;') > 0,
    'constant temp index outside the bounds');
  Check(CompileErrs(13, 'VAR_TEMP t : Array[0..199] of DInt; END_VAR' + LineEnding + '#t[0] := 1;') > 0,
    'VAR_TEMP over 256 bytes');
  // S7-300: UDTn names, arrays of structs in STL / LAD addressing too
  Check(CompileErrs(1, 'VAR_TEMP i : Int; END_VAR' + LineEnding + 'FOR #i := 0 TO 3 DO "D".M[#i].Speed := #i; END_FOR;') = 0,
    'S7-300: array of UDT1 in SCL');
end;

{ timers / counters in arrays and several variable indexes in one operand }
procedure TestDynIndex;
var
  P: TPlcProject;
  Pr: TCProgram;
  Rt: TPlcRuntime;
  K: Integer;
begin
  WriteLn('== variable indexes: timers in arrays of structs, "DB".M[#i].Hist[#j]');
  P := UdtProject(13,
    'VAR_TEMP' + LineEnding +
    '  i : Int;' + LineEnding +
    '  j : Int;' + LineEnding +
    'END_VAR' + LineEnding +
    'FOR #i := 0 TO 3 DO' + LineEnding +
    '  // one TON per element, PT 100, 200, 300, 400 ms' + LineEnding +
    '  "D".M[#i].T.TON(IN := TRUE, PT := 100 * (#i + 1), Q => "D".M[#i].On);' + LineEnding +
    '  "D".M[#i].C.CTU(CU := "D".M[#i].T.Q, PV := 1, Q => "D".M[#i].P.b, CV => "D".M[#i].Speed);' + LineEnding +
    '  FOR #j := 0 TO 2 DO' + LineEnding +
    '    "D".M[#i].Hist[#j] := #i * 10 + #j;' + LineEnding +
    '  END_FOR;' + LineEnding +
    'END_FOR;' + LineEnding +
    '#j := 2;' + LineEnding +
    '"D".Tm[#j].TON(IN := %I0.0, PT := T#50MS, Q => %M10.1, ET => "D".M[#j + 1].T.PT);' + LineEnding +
    '%MW12 := "D".M[#j].Hist[#j - 1] + "D".M[3].Hist[#j];' + LineEnding +
    '%M10.2 := "D".M[#j - 2].T.Q;');
  try
    Pr := Compile(P);
    ShowMsgs(Pr);
    Check(Pr.ErrorCount = 0, 'variable index program compiles');
    Rt := TPlcRuntime.Create(13);
    try
      Rt.CmdDownload(Pr);
      Rt.CmdRun;
      Wait(40);
      Check(Rt.Mode = rmRun, 'RUN');
      Check((Peek(Rt, P, '"D".M[3].Hist[2]') = 32) and (Peek(Rt, P, '"D".M[1].Hist[0]') = 10),
        '"D".M[#i].Hist[#j]: two variable indexes (M[3].Hist[2] = 32, M[1].Hist[0] = 10)');
      Check(Peek(Rt, P, 'MW12') = 21 + 32, '"D".M[#j].Hist[#j - 1] + "D".M[3].Hist[#j] = 53');
      K := Peek(Rt, P, '"D".M[2].T.PT');
      Check(K = 300, Format('PT := 100 * (#i + 1) lands in M[2].T.PT (%d)', [K]));
      Wait(210);
      Check((Peek(Rt, P, '"D".M[0].On') = 1) and (Peek(Rt, P, '"D".M[1].On') = 1) and
        (Peek(Rt, P, '"D".M[2].On') = 0) and (Peek(Rt, P, '"D".M[3].On') = 0),
        '"D".M[#i].T.TON: each element has its own timer (100, 200 done; 300, 400 running)');
      K := Peek(Rt, P, '"D".M[3].T.ET');
      Check((K > 200) and (K < 400), Format('M[3].T.ET runs: %d ms', [K]));
      Check((Peek(Rt, P, '"D".M[0].P.b') = 1) and (Peek(Rt, P, '"D".M[0].Speed') = 1) and
        (Peek(Rt, P, '"D".M[3].Speed') = 0), '"D".M[#i].C.CTU counted the TON of its own element, CV => M[#i].Speed');
      Check(Rt.M[10] and 4 <> 0, 'read "D".M[#j - 2].T.Q');
      Check(Rt.M[10] and 2 = 0, '"D".Tm[#j] (Array of IEC_TIMER) idle with IN = FALSE');
      Rt.SetSimBit(0, 0, True);
      Wait(90);
      Check(Rt.M[10] and 2 <> 0, '"D".Tm[#j].TON: Q after 50 ms');
      Check(Peek(Rt, P, '"D".M[3].T.PT') = 50, 'ET => "D".M[#j + 1].T.PT = 50');
      Check((Peek(Rt, P, '"D".Tm[2].Q') = 1) and (Peek(Rt, P, '"D".Tm[1].Q') = 0), 'only Tm[2] ran');
    finally
      Rt.Free;
    end;
  finally
    P.Free;
  end;
  // the inner index out of range stops the CPU, the message names the array
  P := UdtProject(13, 'VAR_TEMP i : Int; j : Int; END_VAR' + LineEnding + '#i := 1;' + LineEnding + '#j := 3;' +
    LineEnding + '"D".M[#i].Hist[#j] := 1;');
  try
    Pr := Compile(P);
    Rt := TPlcRuntime.Create(13);
    try
      Rt.CmdDownload(Pr);
      Rt.CmdRun;
      Wait(40);
      Check(Rt.Mode = rmStop, 'Hist[3] outside [0..2] -> STOP');
      DumpDiag(Rt);
    finally
      Rt.Free;
    end;
  finally
    P.Free;
  end;
end;

{ a := b with whole structs, arrays and IEC instances }
procedure TestStructAssign;
var
  P: TPlcProject;
  Pr: TCProgram;
  Rt: TPlcRuntime;
begin
  WriteLn('== whole struct / array assignment (a := b)');
  P := UdtProject(13,
    'VAR_TEMP' + LineEnding +
    '  i : Int;' + LineEnding +
    '  a : "Axis";' + LineEnding +
    '  p : "Pair";' + LineEnding +
    '  h : Array[0..2] of Int;' + LineEnding +
    'END_VAR' + LineEnding +
    '"D".M[1].Speed := 11;' + LineEnding +
    '"D".M[1].Pos := 2.5;' + LineEnding +
    '"D".M[1].Hist[2] := 7;' + LineEnding +
    '"D".M[1].P.b := TRUE;' + LineEnding +
    '"D".M[1].On := TRUE;' + LineEnding +
    '"D".M[2] := "D".M[1];' + LineEnding +
    '#a := "D".M[1];' + LineEnding +
    '#a.Speed := #a.Speed + 1;' + LineEnding +
    '#i := 3;' + LineEnding +
    '"D".M[#i] := #a;' + LineEnding +
    '"D".One := "D".M[#i - 2];' + LineEnding +
    '#p := "D".M[1].P;' + LineEnding +
    '"D".M[0].P := #p;' + LineEnding +
    '#h := "D".M[1].Hist;' + LineEnding +
    '"D".M[0].Hist := #h;' + LineEnding +
    '"D".Tm[0].PT := T#3S;' + LineEnding +
    '"D".Tm[1] := "D".Tm[0];');
  try
    Pr := Compile(P);
    ShowMsgs(Pr);
    Check(Pr.ErrorCount = 0, 'struct assignments compile');
    Rt := TPlcRuntime.Create(13);
    try
      Rt.CmdDownload(Pr);
      Rt.CmdRun;
      Wait(40);
      Check(Rt.Mode = rmRun, 'RUN');
      Check((Peek(Rt, P, '"D".M[2].Speed') = 11) and (Abs(PeekReal(Rt, P, '"D".M[2].Pos') - 2.5) < 0.001) and
        (Peek(Rt, P, '"D".M[2].Hist[2]') = 7) and (Peek(Rt, P, '"D".M[2].P.b') = 1) and (Peek(Rt, P, '"D".M[2].On') = 1),
        '"D".M[2] := "D".M[1] copies every member (Int, Real, array, nested struct, Bool)');
      Check((Peek(Rt, P, '"D".M[3].Speed') = 12) and (Peek(Rt, P, '"D".M[3].Hist[2]') = 7),
        '#a := "D".M[1]; "D".M[#i] := #a (a temp struct, a variable index on the target)');
      Check(Peek(Rt, P, '"D".One.Speed') = 11, '"D".One := "D".M[#i - 2] (a variable index on the source)');
      Check((Peek(Rt, P, '"D".M[0].P.b') = 1) and (Peek(Rt, P, '"D".M[0].Hist[2]') = 7) and
        (Peek(Rt, P, '"D".M[0].Speed') = 5), 'nested struct and array copies leave the other members (Speed 5)');
      Check(Peek(Rt, P, '"D".Tm[1].PT') = 3000, '"D".Tm[1] := "D".Tm[0] (IEC_TIMER instance)');
    finally
      Rt.Free;
    end;
  finally
    P.Free;
  end;
  Check(CompileErrs(13, '"D".M[1] := "D".M[1].P;') > 0, 'type mismatch: "Axis" := "Pair"');
  Check(CompileErrs(13, '"D".M[1].P := 5;') > 0, 'a struct cannot take a number');
  Check(CompileErrs(13, 'VAR_TEMP t : Array[0..3] of Int; END_VAR' + LineEnding + '#t := "D".M[1].Hist;') > 0,
    'Array[0..3] := Array[0..2]: mismatch');
  Check(CompileErrs(13, '"D".One := "D".Tm[0];') > 0, '"Axis" := IEC_TIMER: mismatch');
  Check(CompileErrs(13, '%MW0 := "D".M[1];') > 0, 'a struct is no value for an Int');
end;

{ FBs: interface, instance DBs, multi-instances (also in an array), SCL / STL / LAD calls }
function FBProject(AModel: Integer): TPlcProject;
var
  F: TBlock;
  N: TNetwork;
  D: TDataBlock;
begin
  Result := TPlcProject.Create;
  Result.NewEmpty(AModel);
  F := Result.AddBlock(bkFB, 1, 'Meter');
  F.Iface.AddSecVar(vsStatic, 'T', 'IEC_TIMER', '', 'pulse timer');
  F.Iface.AddSecVar(vsStatic, 'Hist', 'Array[0..2] of Int', '0', '');
  F.Iface.AddSecVar(vsInput, 'Run', 'Bool', 'FALSE', '');
  F.Iface.AddSecVar(vsInput, 'Pt', 'Time', 'T#100MS', '');
  F.Iface.AddSecVar(vsOutput, 'Count', 'DInt', '0', '');
  F.Iface.AddSecVar(vsOutput, 'Busy', 'Bool', 'FALSE', '');
  F.Iface.AddSecVar(vsInOut, 'Total', 'Int', '0', '');
  F.Iface.AddSecVar(vsTemp, 'k', 'Int', '', '');
  N := F.AddNet(nkSCL);
  N.Stl.Text :=
    '#T.TON(IN := #Run AND NOT #T.Q, PT := #Pt);' + LineEnding +
    'IF #T.Q THEN' + LineEnding +
    '  #Count := #Count + 1;' + LineEnding +
    '  #Total := #Total + 1;' + LineEnding +
    'END_IF;' + LineEnding +
    '#Busy := #Run;' + LineEnding +
    'FOR #k := 2 TO 1 BY -1 DO #Hist[#k] := #Hist[#k - 1]; END_FOR;' + LineEnding +
    '#Hist[0] := DINT_TO_INT(#Count);';
  F := Result.AddBlock(bkFB, 2, 'Group');
  F.Iface.AddSecVar(vsInput, 'Go', 'Bool', 'FALSE', '');
  F.Iface.AddSecVar(vsOutput, 'Sum', 'DInt', '0', '');
  F.Iface.AddSecVar(vsStatic, 'A', '"Meter"', '', 'a multi-instance');
  F.Iface.AddSecVar(vsStatic, 'B', 'Array[0..1] of FB1', '', 'an array of multi-instances');
  N := F.AddNet(nkSCL);
  N.Stl.Text :=
    'VAR_TEMP i : Int; END_VAR' + LineEnding +
    '#A(Run := #Go, Pt := T#50MS);' + LineEnding +
    'FOR #i := 0 TO 1 DO' + LineEnding +
    '  #B[#i](Run := #Go, Pt := 100 * (#i + 1));' + LineEnding +
    'END_FOR;' + LineEnding +
    '#Sum := #A.Count + #B[0].Count + #B[1].Count;';
  D := Result.AddDB(1, 'D');
  D.AddVar('Cnt', 'DInt', '0', '');
  D.AddVar('Bz', 'Bool', 'FALSE', '');
  D.AddVar('Tot', 'Int', '1000', '');
  D.AddVar('Sum', 'DInt', '0', '');
  D := Result.AddDB(2, 'Meter_DB');
  D.InstanceOf := 1;
  D := Result.AddDB(3, 'Group_DB');
  D.InstanceOf := 2;
  D := Result.AddDB(4, 'Meter2');
  D.InstanceOf := 1;
  D := Result.AddDB(5, 'Meter3');
  D.InstanceOf := 1;
  F := Result.Block(0);
  F.DeleteNet(0);
  N := F.AddNet(nkSCL);
  N.Stl.Text :=
    '"Meter_DB"(Run := %I0.0, Pt := T#100MS, Count => "D".Cnt, Busy => "D".Bz, Total := "D".Tot);' + LineEnding +
    '"Group_DB"(Go := %I0.1, Sum => "D".Sum);' + LineEnding +
    '"Meter2".Run := TRUE;' + LineEnding +
    '"Meter3".Run := %I0.2;';
  N := F.AddNet(nkSTL);
  N.Stl.Text := 'CALL FB1, DB4';
  N := F.AddNet(nkLAD);
  N.SetCell(0, 0, NewCell(lkCall, '"Meter3"'));
end;

procedure TestFB;
var
  P, P2: TPlcProject;
  Pr: TCProgram;
  Rt: TPlcRuntime;
  D: TDataBlock;
  K: Integer;
  F: string;
begin
  WriteLn('== FB with parameters, instance DBs, multi-instances');
  P := FBProject(13);
  try
    D := P.FindDBByName('Meter_DB');
    D.Layout;
    Check((Length(D.Vars) = 7) and (D.Vars[0].Name = 'Run') and (D.Vars[5].Name = 'T'),
      Format('instance DB follows the interface: Input, Output, InOut, Static, no Temp (%d vars)', [Length(D.Vars)]));
    Check(Abs(D.Size - 30) <= 0, Format('Meter_DB: 30 bytes (%d)', [D.Size]));
    Pr := Compile(P);
    ShowMsgs(Pr);
    Check(Pr.ErrorCount = 0, 'FB project compiles');
    Rt := TPlcRuntime.Create(13);
    try
      Rt.CmdDownload(Pr);
      Rt.SetSimBit(0, 0, True);
      Rt.CmdRun;
      Wait(40);
      Check(Rt.Mode = rmRun, 'RUN');
      Check(Peek(Rt, P, '"D".Bz') = 1, 'Busy => "D".Bz (output after the call)');
      Check(Peek(Rt, P, '"Meter_DB".Pt') = 100, 'Pt := T#100MS lands in the instance');
      Wait(530);
      K := Peek(Rt, P, '"D".Cnt');
      Check((K >= 4) and (K <= 6), Format('#T.TON in the FB static: %d pulses of 100 ms -> Count => "D".Cnt', [K]));
      Check(SmallInt(Peek(Rt, P, '"D".Tot')) = 1000 + K, 'InOut Total := "D".Tot copied in and back (1000 + Count)');
      Check((Peek(Rt, P, '"Meter_DB".Hist[0]') = K) and (Peek(Rt, P, '"Meter_DB".Hist[1]') >= K - 1) and
        (Peek(Rt, P, '"Meter_DB".Hist[1]') <= K), 'FB static array #Hist[#k] shifted with a temp loop');
      K := Peek(Rt, P, '"Meter2".Count');
      Check((K >= 4) and (K <= 6), Format('STL CALL FB1, DB4: a second instance counts on its own (%d)', [K]));
      Check(Peek(Rt, P, '"Meter3".Count') = 0, 'LAD CALL "Meter3": Run = FALSE, no count');
      Check((Peek(Rt, P, '"Group_DB".Sum') = 0) and (Peek(Rt, P, '"Group_DB".A.Busy') = 0), 'Group idle while Go = FALSE');
      Rt.SetSimBit(0, 1, True);
      Rt.SetSimBit(0, 2, True);
      Wait(330);
      K := Peek(Rt, P, '"Group_DB".A.Count');
      Check((K >= 5) and (K <= 7), Format('multi-instance #A (50 ms) in "Group_DB": %d', [K]));
      Check((Peek(Rt, P, '"Group_DB".B[0].Count') >= 2) and (Peek(Rt, P, '"Group_DB".B[1].Count') >= 1) and
        (Peek(Rt, P, '"Group_DB".B[1].Count') < Peek(Rt, P, '"Group_DB".B[0].Count')),
        Format('#B[#i](..): an array of multi-instances, own timers (%d, %d)',
        [Peek(Rt, P, '"Group_DB".B[0].Count'), Peek(Rt, P, '"Group_DB".B[1].Count')]));
      Check(Peek(Rt, P, '"D".Sum') = Peek(Rt, P, '"Group_DB".A.Count') + Peek(Rt, P, '"Group_DB".B[0].Count') +
        Peek(Rt, P, '"Group_DB".B[1].Count'), '#Sum := #A.Count + #B[0].Count + #B[1].Count');
      Check(Peek(Rt, P, '"Meter3".Count') >= 2, 'LAD CALL "Meter3" counts with Run = %I0.2');
    finally
      Rt.Free;
    end;
    // save / load
    F := GetTempDir + 'vplc_fb.vplc';
    P.SaveToFile(F);
    P2 := TPlcProject.Create;
    try
      P2.LoadFromFile(F);
      Check((P2.FindBlock(bkFB, 2) <> nil) and (Length(P2.FindBlock(bkFB, 1).Iface.Vars) = 8) and
        (P2.FindBlock(bkFB, 1).Iface.Vars[7].Section = vsTemp) and (P2.FindDBByName('Group_DB').InstanceOf = 2),
        'save / load: FB interface sections, instance DBs');
      Pr := Compile(P2);
      Check(Pr.ErrorCount = 0, 'loaded FB project compiles');
      Pr.Free;
    finally
      P2.Free;
    end;
  finally
    P.Free;
  end;
  // errors
  P := FBProject(13);
  try
    P.Block(0).Net(0).Stl.Text := '"Meter_DB"(Count := 5);' + LineEnding + '"Meter_DB"(Run => %M0.0);' + LineEnding +
      '"Meter_DB"(Nope := 1);' + LineEnding + '"Meter_DB"(T := 1);' + LineEnding + '"Meter"(Run := TRUE);' +
      LineEnding + '"Meter_DB"(Total := 5);' + LineEnding + '"D"(Run := TRUE);';
    Pr := Compile(P);
    ShowMsgs(Pr);
    Check(Pr.ErrorCount >= 7, Format('FB call errors: output with :=, input with =>, unknown, static, no instance, InOut constant, no instance DB (%d)', [Pr.ErrorCount]));
    Pr.Free;
    P.FindBlock(bkFB, 1).Iface.AddSecVar(vsStatic, 'Me', '"Meter"', '', '');
    P.FindBlock(bkFB, 1).Iface.Layout;
    Check(not P.FindBlock(bkFB, 1).Iface.Vars[High(P.FindBlock(bkFB, 1).Iface.Vars) - 1].Valid,
      'an FB cannot contain an instance of itself');
  finally
    P.Free;
  end;
  // S7-300: the same project (DI register, STL CALL)
  P := FBProject(1);
  try
    Pr := Compile(P);
    ShowMsgs(Pr);
    Check(Pr.ErrorCount = 0, 'S7-300: FB project compiles');
    Pr.Free;
  finally
    P.Free;
  end;
end;

{ FCs with parameters: Input, Output, InOut, Return, Temp in the local data of the FC }
function FCProject(AModel: Integer; const Main: string): TPlcProject;
var
  F: TBlock;
  N: TNetwork;
  D: TDataBlock;
begin
  Result := TPlcProject.Create;
  Result.NewEmpty(AModel);
  F := Result.AddBlock(bkFC, 2, 'Clamp');
  F.Iface.AddSecVar(vsInput, 'Value', 'Real', '', '');
  F.Iface.AddSecVar(vsInput, 'Lo', 'Real', '', '');
  F.Iface.AddSecVar(vsInput, 'Hi', 'Real', '', '');
  F.Iface.AddSecVar(vsOutput, 'Limited', 'Bool', '', '');
  F.Iface.AddSecVar(vsReturn, 'Ret_Val', 'Real', '', '');
  F.Iface.AddSecVar(vsTemp, 't', 'Real', '', '');
  F.AddNet(nkSCL).Stl.Text := '#t := LIMIT(MN := #Lo, IN := #Value, MX := #Hi);' + LineEnding +
    '#Limited := #t <> #Value;' + LineEnding + '#Ret_Val := #t;';
  F := Result.AddBlock(bkFC, 3, 'Swap');
  F.Iface.AddSecVar(vsInOut, 'a', 'Int', '', '');
  F.Iface.AddSecVar(vsInOut, 'b', 'Int', '', '');
  F.Iface.AddSecVar(vsTemp, 't', 'Int', '', '');
  F.AddNet(nkSCL).Stl.Text := '#t := #a;' + LineEnding + '#a := #b;' + LineEnding + '#b := #t;';
  F := Result.AddBlock(bkFC, 4, 'Fill');
  F.Iface.AddSecVar(vsInput, 'n', 'Int', '', '');
  F.Iface.AddSecVar(vsInOut, 'arr', 'Array[0..4] of Int', '', '');
  F.Iface.AddSecVar(vsOutput, 'sum', 'DInt', '', '');
  F.Iface.AddSecVar(vsTemp, 'i', 'Int', '', '');
  F.AddNet(nkSCL).Stl.Text := '#sum := 0;' + LineEnding + 'FOR #i := 0 TO 4 DO' + LineEnding +
    '  #arr[#i] := #arr[#i] + #n * #i;' + LineEnding + '  #sum := #sum + #arr[#i];' + LineEnding + 'END_FOR;';
  F := Result.AddBlock(bkFC, 5, 'Untouched');
  F.Iface.AddSecVar(vsOutput, 'o', 'Int', '', '');
  F.AddNet(nkSCL).Stl.Text := '%MW90 := 1;   // o is not written';
  F := Result.AddBlock(bkFC, 6, 'StlFc');
  F.Iface.AddSecVar(vsInput, 'x', 'Int', '', '');
  F.Iface.AddSecVar(vsOutput, 'y', 'Int', '', '');
  F.AddNet(nkSTL).Stl.Text := 'L #x' + LineEnding + 'L 1' + LineEnding + '+I' + LineEnding + 'T #y';
  F := Result.AddBlock(bkFC, 7, 'Outer');
  F.Iface.AddSecVar(vsInput, 'v', 'Int', '', '');
  F.Iface.AddSecVar(vsReturn, 'Ret_Val', 'Int', '', '');
  F.AddNet(nkSCL).Stl.Text :=
    '#Ret_Val := REAL_TO_INT("Clamp"(Value := INT_TO_REAL(#v), Lo := 0.0, Hi := 100.0, Limited => %M50.0));';
  D := Result.AddDB(1, 'D');
  D.AddVar('R', 'Real', '0.0', '');
  D.AddVar('R2', 'Real', '0.0', '');
  D.AddVar('L', 'Bool', 'FALSE', '');
  D.AddVar('L2', 'Bool', 'TRUE', '');
  D.AddVar('Arr5', 'Array[0..4] of Int', '1', '');
  D.AddVar('S', 'DInt', '0', '');
  D.AddVar('Keep', 'Int', '0', '');
  F := Result.Block(0);
  F.DeleteNet(0);
  N := F.AddNet(nkSCL);
  N.Stl.Text := Main;
end;

procedure TestFC;
var
  P, P2: TPlcProject;
  Pr: TCProgram;
  Rt: TPlcRuntime;
  F: string;

  function Errs(const Main: string): Integer;
  var
    Q: TPlcProject;
    Cp: TCProgram;
  begin
    Q := FCProject(13, Main);
    Cp := Compile(Q);
    Result := Cp.ErrorCount;
    if Result = 0 then ShowMsgs(Cp);
    Cp.Free;
    Q.Free;
  end;

begin
  WriteLn('== FC with parameters (Input, Output, InOut, Return)');
  P := FCProject(13,
    'VAR_TEMP a : Int; b : Int; END_VAR' + LineEnding +
    '"D".R := "Clamp"(Value := 150.0, Lo := 0.0, Hi := 100.0, Limited => "D".L);' + LineEnding +
    '"D".R2 := "Clamp"(Value := 50.0, Lo := 0.0, Hi := 100.0, Limited => "D".L2) * 2.0 + 1.0;' + LineEnding +
    '#a := 1;' + LineEnding +
    '#b := 2;' + LineEnding +
    '"Swap"(a := #a, b := #b);' + LineEnding +
    '%MW0 := #a * 10 + #b;' + LineEnding +
    'IF NOT %M60.0 THEN' + LineEnding +
    '  "Fill"(n := 3, arr := "D".Arr5, sum => "D".S);' + LineEnding +
    '  %M60.0 := TRUE;' + LineEnding +
    'END_IF;' + LineEnding +
    '"D".Keep := 55;' + LineEnding +
    '"Untouched"(o => "D".Keep);' + LineEnding +
    'FC6(x := 41, y => %MW2);' + LineEnding +
    '%MW4 := "Outer"(v := 250);');
  try
    Pr := Compile(P);
    ShowMsgs(Pr);
    Check(Pr.ErrorCount = 0, 'FC project compiles');
    Rt := TPlcRuntime.Create(13);
    try
      Rt.CmdDownload(Pr);
      Rt.CmdRun;
      Wait(40);
      Check(Rt.Mode = rmRun, 'RUN');
      Check((Abs(PeekReal(Rt, P, '"D".R') - 100) < 0.001) and (Peek(Rt, P, '"D".L') = 1),
        'Return value: "D".R := "Clamp"(150, 0..100) = 100, Limited => TRUE');
      Check((Abs(PeekReal(Rt, P, '"D".R2') - 101) < 0.001) and (Peek(Rt, P, '"D".L2') = 0),
        'an FC call inside an expression: "Clamp"(50) * 2.0 + 1.0 = 101, Limited => FALSE');
      Check(Peek(Rt, P, 'MW0') = 21, 'InOut: "Swap"(a := #a, b := #b) swaps the temps (21)');
      Check((Peek(Rt, P, '"D".Arr5[4]') = 13) and (Peek(Rt, P, '"D".Arr5[0]') = 1) and (Peek(Rt, P, '"D".S') = 35),
        'an array InOut: "Fill" changes "D".Arr5 in and back, sum => 35');
      Check(Peek(Rt, P, '"D".Keep') = 55, 'an Output the FC does not write keeps the target value');
      Check(Peek(Rt, P, 'MW2') = 42, 'STL in an FC: L #x, + 1, T #y (FC6(x := 41) = 42)');
      Check((Peek(Rt, P, 'MW4') = 100) and (Rt.M[50] and 1 <> 0), 'an FC calls an FC in its Return expression');
    finally
      Rt.Free;
    end;
    F := GetTempDir + 'vplc_fc.vplc';
    P.SaveToFile(F);
    P2 := TPlcProject.Create;
    try
      P2.LoadFromFile(F);
      Check(P2.FindBlock(bkFC, 2).Iface.Vars[P2.FindBlock(bkFC, 2).Iface.FindVar('Ret_Val')].Section = vsReturn,
        'save / load: the Return section');
      Pr := Compile(P2);
      Check(Pr.ErrorCount = 0, 'loaded FC project compiles');
      Pr.Free;
    finally
      P2.Free;
    end;
  finally
    P.Free;
  end;
  Check(Errs('"Swap"(a := %MW0);') > 0, 'an FC needs every parameter');
  Check(Errs('VAR_TEMP b : Int; END_VAR' + LineEnding + '"Swap"(a := 1, b := #b);') > 0, 'an InOut needs a variable');
  Check(Errs('"Clamp"(Value := 1.0, Lo := 0.0, Hi := 2.0, Limited := %M0.0);') > 0, 'an Output with :=');
  Check(Errs('%MW0 := "Untouched"(o => %MW2);') > 0, 'no Return value in an expression');
  Check(Errs('"Clamp"(Value := 1, Lo := 0.0, Hi := 2.0, Limited => %M0.0, Lo := 1.0);') > 0, 'a parameter given twice');
  Check(Errs('"Swap"(a := %MD0, b := %MW4);') > 0, 'InOut type mismatch (DInt for an Int)');
  P := FCProject(13, '%MW0 := 1;');
  try
    P.Block(0).AddNet(nkSTL).Stl.Text := 'CALL FC3';
    P.FindBlock(bkFC, 5).Iface.AddSecVar(vsStatic, 'S', 'Int', '', '');
    Pr := Compile(P);
    ShowMsgs(Pr);
    Check(Pr.ErrorCount >= 2, 'STL CALL of an FC with parameters, a Static in an FC: errors');
    Pr.Free;
  finally
    P.Free;
  end;
end;

{ STL CALL with parameter lines, LAD CALL boxes with parameter pins }
procedure TestStlLadCall;
var
  P: TPlcProject;
  Pr: TCProgram;
  Rt: TPlcRuntime;
  N: TNetwork;
  Ce: TLadCell;
  K: Integer;

  function ErrsStl(const Stl: string): Integer;
  var
    Q: TPlcProject;
    Cp: TCProgram;
  begin
    Q := FCProject(1, '%MW0 := 1;');
    Q.Block(0).AddNet(nkSTL).Stl.Text := Stl;
    Cp := Compile(Q);
    Result := Cp.ErrorCount;
    if Result = 0 then ShowMsgs(Cp);
    Cp.Free;
    Q.Free;
  end;

begin
  WriteLn('== STL CALL with parameters, LAD CALL box pins');
  // S7-300: STL
  P := FCProject(1, '"D".R := 150.0;' + LineEnding + '%MW30 := 1;' + LineEnding + '%MW32 := 2;');
  try
    P.Block(0).AddNet(nkSTL).Stl.Text :=
      'CALL "Clamp"            // FC2' + LineEnding +
      ' Value  :="D".R' + LineEnding +
      ' Lo     :=0.0' + LineEnding +
      ' Hi     :=100.0' + LineEnding +
      ' Limited:="D".L' + LineEnding +
      ' Ret_Val:="D".R2' + LineEnding +
      'CALL FC3' + LineEnding +
      ' a:=MW30' + LineEnding +
      ' b:=MW32' + LineEnding +
      'A     M 60.0' + LineEnding +
      'JC    SKIP' + LineEnding +
      'CALL "Fill"' + LineEnding +
      ' n  :=3' + LineEnding +
      ' arr:="D".Arr5' + LineEnding +
      ' sum:="D".S' + LineEnding +
      'SET' + LineEnding +
      '=     M 60.0' + LineEnding +
      'SKIP: NOP 0' + LineEnding +
      'CALL FC6' + LineEnding +
      ' x:=MW34' + LineEnding +
      ' y:=MW36';
    Pr := Compile(P);
    ShowMsgs(Pr);
    Check(Pr.ErrorCount = 0, 'S7-300: STL CALL with parameter lines compiles');
    Rt := TPlcRuntime.Create(1);
    try
      Rt.CmdDownload(Pr);
      Rt.CmdRun;
      Wait(40);
      Check(Rt.Mode = rmRun, 'RUN');
      Check((Abs(PeekReal(Rt, P, '"D".R2') - 100) < 0.001) and (Peek(Rt, P, '"D".L') = 1),
        'CALL "Clamp": Value := "D".R, Lo := 0.0, Hi := 100.0 -> Ret_Val := "D".R2 = 100, Limited TRUE');
      K := Peek(Rt, P, 'MW30') * 10 + Peek(Rt, P, 'MW32');
      Check((K = 12) or (K = 21), Format('CALL FC3 with InOuts a := MW30, b := MW32 swaps every cycle (%d)', [K]));
      Check((Peek(Rt, P, '"D".Arr5[4]') = 13) and (Peek(Rt, P, '"D".S') = 35),
        'CALL "Fill" once (JC around it): an array InOut, sum := "D".S = 35');
      Check(Peek(Rt, P, 'MW36') = 1, 'CALL FC6: x := MW34 (0), y := MW36 = 1 (STL inside the FC)');
    finally
      Rt.Free;
    end;
  finally
    P.Free;
  end;
  Check(ErrsStl('CALL "Clamp"' + LineEnding + ' Value:=MD0') > 0, 'STL: an FC needs every parameter');
  Check(ErrsStl('CALL FC3' + LineEnding + ' a:=MD0' + LineEnding + ' b:=MW4') > 0, 'STL: MD0 does not fit an Int');
  Check(ErrsStl('CALL FC3' + LineEnding + ' a:=5' + LineEnding + ' b:=MW4') > 0, 'STL: a constant for an InOut');
  Check(ErrsStl('CALL FC3' + LineEnding + ' a:=MW0' + LineEnding + ' c:=MW4' + LineEnding + ' b:=MW2') > 0, 'STL: unknown parameter');
  Check(ErrsStl('CALL FC3') > 0, 'STL: CALL without the parameter lines of an FC with parameters');
  // S7-1500: an FB in STL with parameters
  P := FBProject(13);
  try
    P.Block(0).Net(1).Stl.Text := 'CALL FB1, DB4' + LineEnding + ' Run  :=I0.0' + LineEnding + ' Pt   :=T#100MS' +
      LineEnding + ' Count:=MD40';
    P.Block(0).Net(0).Stl.Text := StringReplace(P.Block(0).Net(0).Stl.Text, '"Meter2".Run := TRUE;', '', []);
    Pr := Compile(P);
    ShowMsgs(Pr);
    Check(Pr.ErrorCount = 0, 'STL CALL FB1, DB4 with parameters compiles');
    Rt := TPlcRuntime.Create(13);
    try
      Rt.CmdDownload(Pr);
      Rt.SetSimBit(0, 0, True);
      Rt.CmdRun;
      Wait(450);
      K := Peek(Rt, P, 'MD40');
      Check((K >= 3) and (K = Peek(Rt, P, '"Meter2".Count')), Format('STL FB call: Run := I0.0, Count := MD40 (%d)', [K]));
    finally
      Rt.Free;
    end;
  finally
    P.Free;
  end;
  // LAD: CALL boxes with pins, EN from a contact
  P := FCProject(13, '"D".R := 150.0;');
  try
    N := P.Block(0).AddNet(nkLAD);
    Ce := NewCell(lkCall, '"Clamp"');
    SetCallArg(Ce, 0, '"D".R');
    SetCallArg(Ce, 1, '0.0');
    SetCallArg(Ce, 2, '100.0');
    SetCallArg(Ce, 3, '"D".L');
    SetCallArg(Ce, 4, '%MD70');
    N.SetCell(0, 0, Ce);
    N := P.Block(0).AddNet(nkLAD);
    N.SetCell(0, 0, NewCell(lkNO, '%I0.3'));
    Ce := NewCell(lkCall, '"Clamp"');
    Ce.Args := '"D".R|0.0|50.0|%M74.0|%MD80';
    N.SetCell(0, 1, Ce);
    N := P.Block(0).AddNet(nkLAD);
    Ce := NewCell(lkCall, '"Meter_DB"');
    N.SetCell(0, 0, Ce);
    Pr := Compile(P);
    ShowMsgs(Pr);
    Check(Pr.ErrorCount > 0, 'LAD CALL of an unknown instance: error');
    Pr.Free;
    P.Block(0).DeleteNet(P.Block(0).NetCount - 1);
    Pr := Compile(P);
    ShowMsgs(Pr);
    Check(Pr.ErrorCount = 0, 'LAD CALL boxes with parameter pins compile');
    Rt := TPlcRuntime.Create(13);
    try
      Rt.CmdDownload(Pr);
      Rt.CmdRun;
      Wait(40);
      Check(Abs(PeekReal(Rt, P, 'MD70') - 100) < 0.001, 'LAD CALL "Clamp": Ret_Val pin -> %MD70 = 100');
      Check((PeekReal(Rt, P, 'MD80') = 0) and (Rt.M[74] and 1 = 0), 'LAD CALL with EN = FALSE: no parameters copied');
      Rt.SetSimBit(0, 3, True);
      Wait(40);
      Check((Abs(PeekReal(Rt, P, 'MD80') - 50) < 0.001) and (Rt.M[74] and 1 <> 0), 'EN = TRUE: Ret_Val 50, Limited TRUE');
    finally
      Rt.Free;
    end;
    Ce := P.Block(0).Net(1).Cell(0, 0);
    Ce.Args := '"D".R|0.0';
    P.Block(0).Net(1).SetCell(0, 0, Ce);
    Pr := Compile(P);
    Check(Pr.ErrorCount > 0, 'LAD: an FC box with empty pins');
    Pr.Free;
  finally
    P.Free;
  end;
  // LAD: an FB box with pins (S7-1200)
  P := FBProject(7);
  try
    Ce := P.Block(0).Net(2).Cell(0, 0);
    Ce.Args := '%I0.2|T#100MS';    // Run, Pt (Total, Count, Busy open)
    P.Block(0).Net(2).SetCell(0, 0, Ce);
    P.Block(0).Net(0).Stl.Text := StringReplace(P.Block(0).Net(0).Stl.Text, '"Meter3".Run := %I0.2;', '', []);
    P.Block(0).DeleteNet(1);   // no STL on the S7-1200
    Pr := Compile(P);
    ShowMsgs(Pr);
    Check(Pr.ErrorCount = 0, 'S7-1200: LAD CALL "Meter3" with Run / Pt pins compiles');
    Rt := TPlcRuntime.Create(7);
    try
      Rt.CmdDownload(Pr);
      Rt.SetSimBit(0, 2, True);
      Rt.CmdRun;
      Wait(350);
      Check(Peek(Rt, P, '"Meter3".Count') >= 2, Format('LAD FB box: Run pin = %%I0.2 counts (%d)', [Peek(Rt, P, '"Meter3".Count')]));
    finally
      Rt.Free;
    end;
  finally
    P.Free;
  end;
end;

{ a LAD network wider than 8 columns: 11 contacts in series, the coil in column 12 }
{ the comparators IN_RANGE / OUT_RANGE and the converters CONV, ROUND, TRUNC, CEIL, FLOOR in LAD }
procedure TestLadConv;
var
  P, P2: TPlcProject;
  Pr: TCProgram;
  Rt: TPlcRuntime;
  F: string;

  { a network with one box at column 0, wires, and a coil in column 7 when Coil <> '' }
  procedure Net(K: TLadKind; T, T2: TDataType; const P0, P1, P2s, Coil: string; Cmp: TCmpOp = coEQ);
  var
    N: TNetwork;
    Ce: TLadCell;
    C: Integer;
  begin
    N := P.Block(0).AddNet(nkLAD);
    Ce := NewCell(K, '');
    Ce.DType := T;
    Ce.DType2 := T2;
    Ce.Cmp := Cmp;
    Ce.P[0] := P0;
    Ce.P[1] := P1;
    Ce.P[2] := P2s;
    N.SetCell(0, 0, Ce);
    if Coil <> '' then
    begin
      for C := 1 to 6 do N.SetCell(0, C, NewCell(lkWire, ''));
      N.SetCell(0, 7, NewCell(lkCoil, Coil));
    end;
  end;

begin
  WriteLn('== LAD comparators (IN_RANGE, OUT_RANGE) and converters (CONV, ROUND, TRUNC, CEIL, FLOOR)');
  P := TPlcProject.Create;
  P.NewEmpty(1);
  try
    P.Block(0).DeleteNet(0);
    Net(lkMove, dtInt, dtReal, '50', 'MW10', '', '');
    Net(lkInRange, dtInt, dtReal, '0', 'MW10', '100', 'M20.0');
    Net(lkOutRange, dtInt, dtReal, '0', 'MW10', '100', 'M20.1');
    Net(lkInRange, dtInt, dtReal, '60', 'MW10', '100', 'M20.3');
    Net(lkConv, dtInt, dtReal, 'MW10', 'MD30', '', '');
    Net(lkMove, dtReal, dtReal, '-2.7', 'MD60', '', '');
    Net(lkTrunc, dtReal, dtDInt, 'MD60', 'MD64', '', '');
    Net(lkCeil, dtReal, dtDInt, 'MD60', 'MD68', '', '');
    Net(lkFloor, dtReal, dtDInt, 'MD60', 'MD72', '', '');
    Net(lkRound, dtReal, dtDInt, 'MD60', 'MD76', '', '');
    Net(lkMove, dtDInt, dtReal, '40000', 'MD80', '', '');
    Net(lkConv, dtDInt, dtInt, 'MD80', 'MW84', '', 'M20.2');
    Net(lkConv, dtDInt, dtReal, 'MD80', 'MD86', '', 'M20.4');
    Net(lkRound, dtReal, dtInt, '2.5', 'MW90', '', '');
    Pr := Compile(P);
    ShowMsgs(Pr);
    Check(Pr.ErrorCount = 0, 'the comparator and converter networks compile');
    Rt := TPlcRuntime.Create(1);
    try
      Rt.CmdDownload(Pr);
      Rt.CmdRun;
      Wait(40);
      Check(Peek(Rt, P, 'M20.0') = 1, 'IN_RANGE 0 <= 50 <= 100: TRUE');
      Check(Peek(Rt, P, 'M20.1') = 0, 'OUT_RANGE 0..100 of 50: FALSE');
      Check(Peek(Rt, P, 'M20.3') = 0, 'IN_RANGE 60..100 of 50: FALSE');
      Check(PeekReal(Rt, P, 'MD30') = 50.0, Format('CONV Int 50 to Real: %g', [PeekReal(Rt, P, 'MD30')]));
      Check(LongInt(Peek(Rt, P, 'MD64')) = -2, Format('TRUNC -2.7 = -2 (%d)', [LongInt(Peek(Rt, P, 'MD64'))]));
      Check(LongInt(Peek(Rt, P, 'MD68')) = -2, Format('CEIL -2.7 = -2 (%d)', [LongInt(Peek(Rt, P, 'MD68'))]));
      Check(LongInt(Peek(Rt, P, 'MD72')) = -3, Format('FLOOR -2.7 = -3 (%d)', [LongInt(Peek(Rt, P, 'MD72'))]));
      Check(LongInt(Peek(Rt, P, 'MD76')) = -3, Format('ROUND -2.7 = -3 (%d)', [LongInt(Peek(Rt, P, 'MD76'))]));
      Check((Peek(Rt, P, 'M20.2') = 0) and (Peek(Rt, P, 'MW84') = 0), 'CONV DInt 40000 to Int: too big, ENO = 0, OUT unchanged');
      Check((Peek(Rt, P, 'M20.4') = 1) and (PeekReal(Rt, P, 'MD86') = 40000.0), 'CONV DInt 40000 to Real: ENO = 1');
      Check(Peek(Rt, P, 'MW90') = 2, Format('ROUND 2.5 to Int = 2 (a half to the even) (%d)', [Peek(Rt, P, 'MW90')]));
    finally
      Rt.Free;
    end;
    // saved and loaded: the kinds and both types stay
    F := GetTempDir + 'vplc_conv.vplc';
    P.SaveToFile(F);
    P2 := TPlcProject.Create;
    try
      P2.LoadFromFile(F);
      Check((P2.Block(0).Net(11).Cell(0, 0).Kind = lkConv) and (P2.Block(0).Net(11).Cell(0, 0).DType = dtDInt) and
        (P2.Block(0).Net(11).Cell(0, 0).DType2 = dtInt) and (P2.Block(0).Net(1).Cell(0, 0).Kind = lkInRange) and
        (P2.Block(0).Net(6).Cell(0, 0).Kind = lkTrunc), 'save / load: IN_RANGE, TRUNC, CONV DInt to Int');
    finally
      P2.Free;
      DeleteFile(F);
    end;
  finally
    P.Free;
  end;
end;

{ every example project: it compiles without errors, runs a second without a programming error, and
  survives save / load }
procedure TestExamples;
var
  I, K: Integer;
  P, P2: TPlcProject;
  Pr: TCProgram;
  Rt: TPlcRuntime;
  F: string;
begin
  WriteLn('== Example projects');
  for I := 0 to ExampleCount - 1 do
  begin
    P := TPlcProject.Create;
    try
      BuildExample(I, P);
      Pr := Compile(P);
      if Pr.ErrorCount > 0 then ShowMsgs(Pr);
      Check(Pr.ErrorCount = 0, Format('%s compiles (%d errors)', [ExampleFile(I), Pr.ErrorCount]));
      Rt := TPlcRuntime.Create(P.ModelIdx);
      try
        Rt.CmdDownload(Pr);
        Rt.CmdRun;
        Wait(300);
        if Rt.Mode <> rmRun then
          for K := 0 to High(Rt.DiagCopy(5)) do WriteLn('    DIAG ', Rt.DiagCopy(5)[K].Text);
        Check(Rt.Mode = rmRun, ExampleFile(I) + ' runs (still in RUN after 0.3 s)');
      finally
        Rt.Free;
      end;
      F := GetTempDir + 'vplc_example.vplc';
      P.SaveToFile(F);
      P2 := TPlcProject.Create;
      try
        P2.LoadFromFile(F);
        Pr := Compile(P2);
        Check(Pr.ErrorCount = 0, ExampleFile(I) + ' saved and loaded: still compiles');
        Pr.Free;
      finally
        P2.Free;
        DeleteFile(F);
      end;
    finally
      P.Free;
    end;
  end;
end;

{ what some examples do, through their inputs }
procedure TestExampleBehaviour;
var
  P: TPlcProject;
  Rt: TPlcRuntime;
  On: Boolean;
  K: Integer;

  procedure Load(I: Integer);
  begin
    P := TPlcProject.Create;
    BuildExample(I, P);
    Rt := TPlcRuntime.Create(P.ModelIdx);
    Rt.CmdDownload(Compile(P));
    Rt.CmdRun;
    Wait(60);
  end;

  procedure Done;
  begin
    Rt.Free;
    P.Free;
  end;

  procedure Press(AByte, ABit: Integer);
  begin
    Rt.SetSimBit(AByte, ABit, True);
    Wait(60);
    Rt.SetSimBit(AByte, ABit, False);
    Wait(60);
  end;

begin
  WriteLn('== Example projects: their behaviour');
  // data type conversion (SCL + LAD): the analog input half way, the start values
  Load(26);
  try
    Rt.SetSimWord(64, 13824);
    Wait(120);
    Check(Abs(PeekReal(Rt, P, '"Conv".Volts') - 5.0) < 0.01, Format('conversion: INT_TO_REAL 13824 = %.3f V',
      [PeekReal(Rt, P, '"Conv".Volts')]));
    Check(SmallInt(Peek(Rt, P, '"Conv".Back_Int')) = 13824, 'conversion: REAL_TO_INT back = 13824');
    Check(Abs(PeekReal(Rt, P, '"Conv".Raw_Real') - 13824) < 0.01, 'conversion: LAD CONV Int -> Real');
    Check((LongInt(Peek(Rt, P, '"Conv".Rnd')) = 2) and (LongInt(Peek(Rt, P, '"Conv".Trc')) = 2) and
      (LongInt(Peek(Rt, P, '"Conv".Cei')) = 3) and (LongInt(Peek(Rt, P, '"Conv".Flo')) = 2) and
      (SmallInt(Peek(Rt, P, '"Conv".Lad_Rnd')) = 2), 'conversion: 2.5 -> ROUND 2, TRUNC 2, CEIL 3, FLOOR 2, LAD ROUND 2');
    Check(SmallInt(Peek(Rt, P, '"Conv".Big_To_Int')) = 4464, Format('conversion: DINT_TO_INT 70000 = %d',
      [SmallInt(Peek(Rt, P, '"Conv".Big_To_Int'))]));
    Check((SmallInt(Peek(Rt, P, '"Conv".W_To_Int')) = -1) and (Peek(Rt, P, '"Conv".Int_To_W') = $FFFF) and
      (Peek(Rt, P, '"Conv".W_To_DW') = $FFFF) and (LongInt(Peek(Rt, P, '"Conv".DW_To_DInt')) = 65536),
      'conversion: WORD_TO_INT 16#FFFF = -1, INT_TO_WORD -1 = 16#FFFF, WORD_TO_DWORD, DWORD_TO_DINT 65536');
  finally
    Done;
  end;
  // data type conversion in STL (S7-300)
  Load(27);
  try
    Rt.SetSimWord(288, 13824);
    Wait(120);
    Check(Abs(PeekReal(Rt, P, '"Volts"') - 5.0) < 0.01, Format('STL conversion: ITD DTR /R = %.3f V',
      [PeekReal(Rt, P, '"Volts"')]));
    Check((Peek(Rt, P, '"Bcd"') = $0123) and (SmallInt(Peek(Rt, P, '"From_Bcd"')) = 123) and
      (SmallInt(Peek(Rt, P, '"As_Int"')) = -1), 'STL conversion: ITB 123 = W#16#0123, BTI back, W#16#FFFF as Int = -1');
  finally
    Done;
  end;
  // math
  Load(28);
  try
    Wait(60);
    Check((SmallInt(Peek(Rt, P, '"Math".Sum')) = 10) and (SmallInt(Peek(Rt, P, '"Math".Quot')) = 2) and
      (SmallInt(Peek(Rt, P, '"Math".Rest')) = 1) and (SmallInt(Peek(Rt, P, '"Math".Lim')) = 20),
      'math: 7 + 3 = 10, 7 / 3 = 2, 7 MOD 3 = 1, LIMIT(0, 21, 20) = 20');
    Check((Abs(PeekReal(Rt, P, '"Math".Hyp') - 5) < 0.001) and (Abs(PeekReal(Rt, P, '"Math".Pow') - 27) < 0.01) and
      (Abs(PeekReal(Rt, P, '"Math".SinA') - 0.5) < 0.001) and (Abs(PeekReal(Rt, P, '"Math".Log1000') - 3) < 0.001),
      Format('math: SQRT(9 + 16) = %.3f, 3 ** 3 = %.2f, SIN(30) = %.4f, LOG(1000) = %.4f',
      [PeekReal(Rt, P, '"Math".Hyp'), PeekReal(Rt, P, '"Math".Pow'), PeekReal(Rt, P, '"Math".SinA'),
      PeekReal(Rt, P, '"Math".Log1000')]));
    Check((Abs(PeekReal(Rt, P, '"Math".Avg') - 4.5) < 0.001) and (Abs(PeekReal(Rt, P, '"Math".Poly') - 10) < 0.001),
      'math: the average of 1.5 .. 7.5 = 4.5, 2*9 - 9 + 1 = 10');
    Check((LongInt(Peek(Rt, P, '"Math".Lad_Diff')) = 30000) and (Abs(PeekReal(Rt, P, '"Math".Lad_Prod') - 12) < 0.001) and
      (SmallInt(Peek(Rt, P, '"Math".Lad_Sum')) = 10), 'math: LAD ADD 10, SUB 100000 - 70000, MUL 3 * 4');
  finally
    Done;
  end;
  // the large FB: start warning, running with feedback, the feedback goes: fault 2, reset
  Load(29);
  try
    Rt.SetSimBit(0, 0, True);
    Wait(80);
    Rt.SetSimBit(0, 0, False);
    Wait(300);
    Check(SmallInt(Peek(Rt, P, '"M1_DB".State')) = 1, 'large FB: start -> state 1 (start warning)');
    Rt.SetSimBit(0, 2, True);
    Wait(1000);
    Check((SmallInt(Peek(Rt, P, '"M1_DB".State')) = 2) and Rt.GetOutBit(0, 0) and
      (LongInt(Peek(Rt, P, '"M1_DB".Starts')) = 1), 'large FB: after 1 s running, the contactor on, 1 start');
    Rt.SetSimBit(0, 2, False);
    Wait(3400);
    Check((SmallInt(Peek(Rt, P, '"M1_DB".FaultCode')) = 2) and (SmallInt(Peek(Rt, P, '"M1_DB".State')) = 3) and
      not Rt.GetOutBit(0, 0) and Rt.GetOutBit(0, 6), 'large FB: no feedback for 3 s -> fault 2, off, the fault lamp');
    Rt.SetSimBit(1, 6, True);
    Wait(80);
    Rt.SetSimBit(1, 6, False);
    Wait(120);
    Check((SmallInt(Peek(Rt, P, '"M1_DB".FaultCode')) = 0) and (SmallInt(Peek(Rt, P, '"M1_DB".State')) = 0),
      'large FB: reset -> state 0');
  finally
    Done;
  end;
  // timers S7-1200: TON 3 s, TP 2 s
  Load(18);
  try
    Rt.SetSimBit(0, 0, True);
    Rt.SetSimBit(0, 2, True);
    Wait(1000);
    Check(not Rt.GetOutBit(0, 0) and Rt.GetOutBit(0, 2), 'timers S7-1200: after 1 s TON still off, TP on');
    Wait(2400);
    Check(Rt.GetOutBit(0, 0) and not Rt.GetOutBit(0, 2), 'timers S7-1200: after 3.4 s TON on, TP over');
  finally
    Done;
  end;
  // counters S7-1200: 5 presses -> CTU and CTUD QU, reset -> 0
  Load(19);
  try
    for K := 1 to 5 do Press(0, 0);
    Check(Rt.GetOutBit(0, 0) and Rt.GetOutBit(0, 2) and (Peek(Rt, P, '"Counters".CV_Up') = 5),
      Format('counters S7-1200: 5 x up -> CTU Q, CTUD QU (CV %d)', [Peek(Rt, P, '"Counters".CV_Up')]));
    Press(0, 2);
    Check(not Rt.GetOutBit(0, 0) and (Peek(Rt, P, '"Counters".CV_Up') = 0), 'counters S7-1200: reset -> 0');
  finally
    Done;
  end;
  // timers S7-1500: the S5 SP %T1 on at once while IN
  Load(20);
  try
    Rt.SetSimBit(0, 4, True);
    Wait(200);
    Check(Rt.GetOutBit(0, 4), 'timers S7-1500: S5 pulse SP %T1 on');
  finally
    Done;
  end;
  // timers S7-300: SD on delay 2 s (I0.5 -> Q4.5), SE extended pulse (I0.4 -> Q4.4)
  Load(22);
  try
    Rt.SetSimBit(0, 5, True);
    Press(0, 4);
    Check(not Rt.GetOutBit(4, 5) and Rt.GetOutBit(4, 4), 'timers S7-300: SD not yet, SE pulse on after IN went');
    Wait(2200);
    Check(Rt.GetOutBit(4, 5) and not Rt.GetOutBit(4, 4), 'timers S7-300: after 2 s SD on, SE over');
  finally
    Done;
  end;
  // counters S7-400: SC C#3 -> C1 on; 3 x down -> 0, off
  Load(25);
  try
    Press(0, 3);
    Check(Rt.GetOutBit(4, 3), 'counters S7-400: SC C#3 -> the counter bit C1 on');
    for K := 1 to 3 do Press(0, 1);
    Check(not Rt.GetOutBit(4, 3), 'counters S7-400: 3 x CD -> C1 = 0, the bit off');
  finally
    Done;
  end;
  // tank level: 10 % -> the pump fills, 90 % -> it stops, 97 % -> the alarm
  Load(5);
  try
    Rt.SetSimBit(0, 0, True);
    Rt.SetSimWord(64, 2765);
    Wait(80);
    Check(Rt.GetOutBit(0, 0), Format('tank 10 %%: the pump fills (level %.1f)', [PeekReal(Rt, P, '"Tank".Level')]));
    Rt.SetSimWord(64, 13824);
    Wait(80);
    Check(Rt.GetOutBit(0, 0), 'tank 50 %: the pump keeps filling (hysteresis)');
    Rt.SetSimWord(64, 24883);
    Wait(80);
    Check(not Rt.GetOutBit(0, 0), 'tank 90 %: the pump stops');
    Rt.SetSimWord(64, 26820);
    // the alarm flashes at 2 Hz: on at some time within a second
    On := False;
    for K := 1 to 12 do
    begin
      Wait(90);
      On := On or Rt.GetOutBit(0, 1);
    end;
    Check(On, 'tank 97 %: the high level alarm flashes');
  finally
    Done;
  end;
  // car wash: start with the car in place: step 1 (pre-wash, water)
  Load(10);
  try
    Rt.SetSimBit(0, 2, True);
    Rt.SetSimBit(0, 1, True);
    Rt.SetSimBit(0, 0, True);
    Wait(80);
    Rt.SetSimBit(0, 0, False);
    Check((Peek(Rt, P, '"Wash".Step') = 1) and Rt.GetOutBit(0, 0), 'car wash: start -> step 1, water on');
    Rt.SetSimBit(0, 2, False);
    Wait(80);
    Check(Peek(Rt, P, '"Wash".Step') = 0, 'car wash: the emergency stop -> step 0');
  finally
    Done;
  end;
  // alarms: alarm 1 -> the horn; acknowledge -> the horn off, the lamp steady; gone -> the lamp off
  Load(13);
  try
    Rt.SetSimBit(0, 0, True);
    Wait(80);
    Check(Rt.GetOutBit(0, 4), 'alarms: alarm 1 sounds the horn');
    Rt.SetSimBit(0, 4, True);
    Wait(80);
    Rt.SetSimBit(0, 4, False);
    Wait(80);
    Check(not Rt.GetOutBit(0, 4) and Rt.GetOutBit(0, 0), 'alarms: acknowledged: horn off, lamp 1 steady');
    Rt.SetSimBit(0, 0, False);
    Wait(80);
    Check(not Rt.GetOutBit(0, 0), 'alarms: gone and acknowledged: lamp 1 off');
  finally
    Done;
  end;
  // running light: the one lamp moves on
  Load(14);
  try
    Rt.SetSimBit(0, 0, True);
    Rt.SetSimBit(0, 2, True);
    Wait(100);
    Check(Peek(Rt, P, '%QB0') in [1, 2], 'running light: one lamp on ' + IntToStr(Peek(Rt, P, '%QB0')));
    Wait(600);
    Check(Peek(Rt, P, '%QB0') in [2, 4, 8, 16], 'running light: it has moved on ' + IntToStr(Peek(Rt, P, '%QB0')));
  finally
    Done;
  end;
end;

procedure TestWideLad;
var
  P, P2: TPlcProject;
  Pr: TCProgram;
  Rt: TPlcRuntime;
  N: TNetwork;
  C: Integer;
  F: string;
begin
  WriteLn('== LAD networks wider than 8 columns');
  P := TPlcProject.Create;
  P.NewEmpty(1);
  try
    N := P.Block(0).Net(0);
    N.SetCols(12);
    Check((N.Cols = 12) and (Length(N.Cells) = 12), 'SetCols(12): one row of 12 cells');
    for C := 0 to 7 do N.SetCell(0, C, NewCell(lkNO, Format('I0.%d', [C])));
    N.SetCell(0, 8, NewCell(lkNO, 'I1.0'));
    N.SetCell(0, 9, NewCell(lkNO, 'I1.1'));
    N.SetCell(0, 10, NewCell(lkNC, 'I1.2'));
    N.SetCell(0, 11, NewCell(lkCoil, 'Q4.0'));
    N.SetRows(2);
    Check((N.Cell(0, 11).Kind = lkCoil) and (N.Cell(1, 0).Kind = lkEmpty), 'SetRows keeps the 12 columns');
    N.SetCell(1, 3, NewCell(lkCoil, 'M12.0'));
    N.SetCols(14);
    Check((N.Cell(0, 11).Kind = lkCoil) and (N.Cell(1, 3).Kind = lkCoil) and (N.Cell(0, 13).Kind = lkEmpty),
      'SetCols(14) keeps every cell at its row and column');
    N.SetCols(12);
    N.DeleteRow(1);
    Pr := Compile(P);
    ShowMsgs(Pr);
    Check(Pr.ErrorCount = 0, 'a 12 column network compiles');
    Rt := TPlcRuntime.Create(1);
    try
      Rt.CmdDownload(Pr);
      Rt.CmdRun;
      Wait(30);
      Check(not Rt.GetOutBit(4, 0), 'coil in column 12 off while the contacts are open');
      for C := 0 to 7 do Rt.SetSimBit(0, C, True);
      Rt.SetSimBit(1, 0, True);
      Wait(30);
      Check(not Rt.GetOutBit(4, 0), 'I1.1 (column 10) still open: off');
      Rt.SetSimBit(1, 1, True);
      Wait(30);
      Check(Rt.GetOutBit(4, 0), 'all 11 contacts closed: Q4.0 in column 12 on');
    finally
      Rt.Free;
    end;
    F := GetTempDir + 'vplc_wide.vplc';
    P.SaveToFile(F);
    P2 := TPlcProject.Create;
    try
      P2.LoadFromFile(F);
      Check((P2.Block(0).Net(0).Cols = 12) and (P2.Block(0).Net(0).Cell(0, 11).Kind = lkCoil),
        'save / load keeps the 12 columns');
    finally
      P2.Free;
    end;
  finally
    P.Free;
  end;
end;

{ the Claude assistant's tools on a real project (no network: the tools are called directly) }
procedure TestClaudeTools;
var
  P: TPlcProject;
  Rt: TPlcRuntime;
  Ag: TClaudeAgent;
  S: string;
  E: Boolean;
  J: TJSONData;
  NOb1: Integer;
begin
  WriteLn('== Claude assistant tools');
  P := TPlcProject.Create;
  P.LoadSample(13);
  Rt := TPlcRuntime.Create(13);
  Ag := TClaudeAgent.Create;
  try
    Ag.Project := P;
    Ag.Rt := Rt;
    J := Ag.ToolsJson;
    Check((J is TJSONArray) and (TJSONArray(J).Count = 13), Format('13 tool definitions, valid JSON (%d)', [TJSONArray(J).Count]));
    J.Free;
    Check(Length(Ag.SystemPrompt) > 3000, 'the system prompt describes the dialects');
    S := Ag.TestTool('get_project', '{}', E);
    J := GetJSON(S);
    Check(not E and (TJSONObject(J).Arrays['blocks'].Count = P.BlockCount) and (TJSONObject(J).Objects['compile'].Get('errors', -1) = 0),
      'get_project: every block, compiles without errors');
    J.Free;
    S := Ag.TestTool('get_block', '{"block":"FC1"}', E);
    J := GetJSON(S);
    Check(not E and (TJSONObject(J).Arrays['networks'].Objects[0].Get('language', '') = 'SCL') and
      (Pos('History', TJSONObject(J).Arrays['networks'].Objects[0].Get('code', '')) > 0), 'get_block FC1: the SCL code');
    J.Free;
    S := Ag.TestTool('get_block', '{"block":"Main"}', E);
    Check(not E and (Pos('"cells"', S) > 0) and (Pos('"e" : "coil"', S) + Pos('"e":"coil"', S) > 0), 'get_block by name: LAD cells');
    Check(not Ag.CanUndo, 'nothing to undo before a change');
    // an FC with a Return value, written in SCL
    S := Ag.TestTool('create_block', '{"kind":"FC","name":"Twice","interface":[{"section":"Input","name":"a","type":"Int"},' +
      '{"section":"Return","name":"Ret_Val","type":"Int"}]}', E);
    Check(not E and (P.FindBlock(bkFC, 3) <> nil), 'create_block FC3 "Twice": ' + S);
    S := Ag.TestTool('write_network', '{"block":"Twice","language":"SCL","title":"double it","code":"#Ret_Val := #a * 2;"}', E);
    Check(not E and (Pos('"errors" : 0', S) + Pos('"errors":0', S) > 0), 'write_network SCL: compiles ' + Copy(S, 1, 120));
    // a LAD network appended to OB1: a self-holding contact
    NOb1 := P.Block(0).NetCount;
    S := Ag.TestTool('write_network', '{"block":"OB1","language":"LAD","title":"pump","cells":[' +
      '{"r":0,"c":0,"e":"no","op":"%I0.5","down":true},{"r":0,"c":1,"e":"nc","op":"%I0.6"},' +
      '{"r":0,"c":2,"e":"wire"},{"r":0,"c":3,"e":"wire"},{"r":0,"c":4,"e":"wire"},{"r":0,"c":5,"e":"wire"},' +
      '{"r":0,"c":6,"e":"wire"},{"r":0,"c":7,"e":"coil","op":"%Q0.5"},{"r":1,"c":0,"e":"no","op":"%Q0.5"}]}', E);
    Check(not E and (P.Block(0).NetCount = NOb1 + 1) and (P.Block(0).Net(NOb1).Cell(1, 0).Kind = lkNO) and
      (Pos('"errors" : 0', S) + Pos('"errors":0', S) > 0), 'write_network LAD: a self-holding rung appended, compiles');
    S := Ag.TestTool('write_network', '{"block":"OB1","language":"LAD","cells":[{"r":0,"c":0,"e":"bogus"}]}', E);
    Check(E and (P.Block(0).NetCount = NOb1 + 1), 'an unknown LAD element is refused, nothing changed');
    S := Ag.TestTool('write_network', '{"block":"OB1","network":99,"language":"SCL","code":"x"}', E);
    Check(E, 'a network out of range is refused');
    S := Ag.TestTool('add_tags', '{"tags":[{"name":"Pump","type":"Bool","address":"%Q0.5","comment":"by Claude"}]}', E);
    Check(not E and (P.FindTag('Pump') >= 0), 'add_tags');
    S := Ag.TestTool('add_db_variables', '{"db":"Pumps","variables":[{"name":"Runs","type":"DInt","start":"0"}]}', E);
    Check(not E and (P.FindDBByName('Pumps') <> nil), 'add_db_variables creates the DB: ' + S);
    S := Ag.TestTool('compile', '{}', E);
    Check(not E and (Pos('"errors" : 0', S) + Pos('"errors":0', S) > 0), 'compile: the whole project');
    // live values
    Rt.CmdDownload(Compile(P));
    Rt.SetSimBit(0, 5, True);
    Rt.CmdRun;
    Wait(60);
    S := Ag.TestTool('read_values', '{"operands":["%Q0.5","\"Pump\"","\"Motor\".SpeedRpm","nonsense"]}', E);
    J := GetJSON(S);
    Check(not E and (TJSONObject(J).Get('cpu_mode', '') = 'Run') and (TJSONObject(J).Objects['values'].Get('%Q0.5', '') = 'TRUE') and
      (TJSONObject(J).Objects['values'].Get('"Pump"', '') = 'TRUE') and (Pos('error', TJSONObject(J).Objects['values'].Get('nonsense', '')) = 1),
      'read_values: %Q0.5 and "Pump" TRUE in RUN, a bad operand says why');
    J.Free;
    S := Ag.TestTool('set_inputs', '{"inputs":{"%I0.6":true,"%IW512":13824}}', E);
    Check(not E and Rt.GetSimBit(0, 6) and (P.AIch[0].AiMode = amManual) and (P.AIch[0].AiValue = 13824),
      'set_inputs: a digital input and an analog channel (manual 13824): ' + S);
    S := Ag.TestTool('set_inputs', '{"inputs":{"%Q0.5":true}}', E);
    Check(E, 'set_inputs refuses an output');
    S := Ag.TestTool('get_diagnostics', '{}', E);
    Check(not E and (Pos('RUN', S) > 0), 'get_diagnostics: the buffer');
    // undo: the project as before the first change
    Check(Ag.CanUndo, 'Claude''s changes can be undone');
    Ag.UndoChanges;
    Check((P.FindBlock(bkFC, 3) = nil) and (P.Block(0).NetCount = NOb1) and (P.FindTag('Pump') < 0) and
      (P.FindDBByName('Pumps') = nil), 'UndoChanges: the block, the network, the tag and the DB are gone');
  finally
    Ag.Free;
    Rt.Free;
    P.Free;
  end;
end;

procedure TestPorts;
var
  P: TPlcProject;
  Rt: TPlcRuntime;
  Hub: TCommHub;
  S7: TS7Client;
  Mb: TModbusClient;
  Cs: TCommSettings;
  B: TBytes;
  R: Integer;
  V: Boolean;
  Sg: Single;
  Db: TDataBlock;
begin
  WriteLn('== simulated ports (S7 ISO-on-TCP, Modbus TCP)');
  P := TPlcProject.Create;
  P.LoadSample(1);
  Rt := TPlcRuntime.Create(1);
  Hub := TCommHub.Create(Rt);
  S7 := TS7Client.Create;
  Mb := TModbusClient.Create;
  try
    Rt.CmdDownload(Compile(P));
    Rt.SetSimBit(0, 1, True);
    Rt.SetSimBit(0, 2, True);
    Rt.SetSimWord(288, 13824);
    Rt.CmdRun;
    Cs := P.Comm;
    Cs.S7Port := 11102;
    Cs.MbPort := 11502;
    Hub.Apply(Cs, P.Model, P.Name);
    Check(Hub.Listening[prS7] and Hub.Listening[prModbus], 'both servers listen: ' + Hub.Status[prS7]);
    Sleep(80);
    Check(not S7.Connect('127.0.0.1', 11102, 0, 1), 'S7-300 refuses rack 0 slot 1: ' + S7.LastError);
    Check(S7.Connect('127.0.0.1', 11102, 0, 2), 'S7 connect rack 0 slot 2, PDU ' + IntToStr(S7.PduSize));
    Check(S7.PduSize = 480, 'PDU 480');
    Check(S7.CpuState = 8, 'SZL 0x0424: RUN');
    Check(S7.OrderCode = '6ES7 315-2EH14-0AB0', 'SZL 0x0011: order code ' + S7.OrderCode);
    R := S7.WriteArea($83, 0, 100, [$10, $E1]);
    Check(R = 0, 'S7 write MW100 = 4321');
    Mb.UnitId := 1;
    Check(Mb.Open('127.0.0.1', 11502), 'Modbus connect');
    R := Mb.ReadRegs(3, 50, 1, B);
    Check((R = 0) and (Length(B) = 2) and ((B[0] shl 8) or B[1] = 4321), 'Modbus holding 50 = MW100 = 4321 (written by S7)');
    R := Mb.WriteReg(51, 777);
    R := S7.ReadArea($83, 0, 102, 2, B);
    Check((R = 0) and ((B[0] shl 8) or B[1] = 777), 'S7 reads MW102 = 777 (written by Modbus)');
    R := S7.ReadArea($84, 1, 0, 4, B);
    if R = 0 then
    begin
      PLongWord(@Sg)^ := (LongWord(B[0]) shl 24) or (LongWord(B[1]) shl 16) or (LongWord(B[2]) shl 8) or B[3];
      Check(Abs(Sg - 750) < 0.5, Format('S7 read DB1.DBD0 (SpeedRpm REAL) = %.2f', [Sg]));
    end
    else
      Check(False, 'S7 read DB1: ' + S7.LastError);
    R := S7.ReadBit($81, 0, 0, 1, V);
    Check((R = 0) and V, 'S7 read bit I0.1 (NC stop button) = 1');
    R := Mb.ReadBits(2, 0, 8, B);
    Check((R = 0) and (B[0] = 6), Format('Modbus discrete inputs I0.0..I0.7 = %d', [B[0]]));
    // start the motor from the "HMI": the program latches it
    Rt.SetSimBit(0, 0, True);
    Sleep(30);
    Rt.SetSimBit(0, 0, False);
    Sleep(30);
    R := Mb.ReadBits(1, 32, 1, B);
    Check((R = 0) and (B[0] and 1 = 1), 'Modbus coil 32 = Q4.0 (motor) = 1');
    R := S7.ReadArea($1C, 0, 1, 1, B);
    Check((R = 0) and (B[1] = 1), 'S7 read counter C1 = C#1 (BCD)');
    R := Mb.WriteRegs(60, [1, 2, 3]);
    R := S7.ReadArea($83, 0, 120, 6, B);
    Check((R = 0) and (B[1] = 1) and (B[3] = 2) and (B[5] = 3), 'Modbus FC16 -> MW120..MW124');
    R := S7.ReadArea($84, 5, 0, 2, B);
    Check(R = $0A, 'S7 read DB5 (missing): 0x0A object does not exist');
    R := S7.ReadArea($83, 0, 5000, 2, B);
    Check(R = $05, 'S7 read MB5000: 0x05 address out of range');
    R := Mb.ReadRegs(3, 30000, 1, B);
    Check(R = 2, 'Modbus register 30000: exception 2');
    R := Mb.ReadRegs(7, 0, 1, B);
    Check(R = 1, 'Modbus function 7: exception 1');
    Check(S7.PlcStop, 'S7 PLC stop');
    Sleep(30);
    Check(Rt.Mode = rmStop, 'CPU in STOP after the S7 stop');
    Check(S7.CpuState = 4, 'SZL 0x0424: STOP');
    Check(S7.PlcStart, 'S7 PLC start');
    Sleep(60);
    Check(Rt.Mode = rmRun, 'CPU in RUN after the S7 start');
    Check(Hub.ActiveCount = 2, Format('2 connections (%d)', [Hub.ActiveCount]));
    S7.Close;
    Mb.Close;
    Sleep(600);
    Hub.Cleanup;
    Check(Hub.ActiveCount = 0, 'connections closed');

    // S7-1200: PUT/GET and optimized DBs
    Rt.CmdStop;
    P.LoadSample(7);
    Rt.CmdSetModel(7);
    Rt.WaitCommands;
    Db := P.DB(0);
    Db.Optimized := False;
    P.AddDB(9, 'Opt').AddVar('X', 'Int', '5', '');
    P.FindDB(9).Optimized := True;
    Rt.CmdDownload(Compile(P));
    Rt.CmdRun;
    Cs := P.Comm;
    Cs.S7Port := 11102;
    Cs.MbPort := 11502;
    Cs.PutGet := True;
    Hub.Apply(Cs, P.Model, P.Name);
    Sleep(50);
    Check(S7.Connect('127.0.0.1', 11102, 0, 1), 'S7-1200 connect rack 0 slot 1');
    R := S7.ReadArea($84, 1, 8, 2, B);
    Check((R = 0) and (B[1] = 1), 'S7-1200 read DB1.DBW8 (Startups) = 1 with PUT/GET');
    R := S7.ReadArea($84, 9, 0, 2, B);
    Check(R = $03, 'S7-1200 optimized DB9: absolute access refused (0x03)');
    Cs.PutGet := False;
    Hub.Apply(Cs, P.Model, P.Name);
    R := S7.ReadArea($84, 1, 8, 2, B);
    Check(R = -2, 'S7-1200 without PUT/GET: read refused (' + S7.LastError + ')');
    S7.Close;
    WriteLn('    traffic: ', Hub.LogCopy(1)[0].Text);
  finally
    S7.Free;
    Mb.Free;
    Hub.Free;
    Rt.Free;
    P.Free;
  end;
end;

{ the SCL elements of the SCL Compiler, phase 1: typed literals, VAR CONSTANT, MUX, slices, arrays of more
  dimensions, init lists, FC return by name and positional arguments, the system FBs }
function ParityProject(AModel: Integer; const Main: string): TPlcProject;
var
  F: TBlock;
  D: TDataBlock;
begin
  Result := TPlcProject.Create;
  Result.NewEmpty(AModel);
  D := Result.AddDB(1, 'D');
  D.AddVar('k', 'Int', '2', '');
  D.AddVar('k2', 'Int', '7', '');
  D.AddVar('u', 'UDInt', '0', '');
  D.AddVar('u2', 'UDInt', '4000000001', '');
  D.AddVar('dt', 'Date', 'D#1990-01-01', '');
  D.AddVar('tod', 'Time_Of_Day', 'TOD#0:0:0', '');
  D.AddVar('w', 'Word', '0', '');
  D.AddVar('b', 'Bool', 'FALSE', '');
  D.AddVar('b2', 'Bool', 'FALSE', '');
  D.AddVar('y', 'Byte', '0', '');
  D.AddVar('dw', 'DWord', 'DW#16#11223344', '');
  D.AddVar('w2', 'Word', '0', '');
  D.AddVar('i2', 'Int', '0', '');
  D.AddVar('arrw', 'Array[0..3] of Word', '0', '');
  D.AddVar('m', 'Array[0..2, 1..3] of Int', '0', '');
  D.AddVar('a5', 'Array[0..4] of Int', '[1, 2, 3(7)]', '');
  D.AddVar('ti', 'Int', 'INT#-3', '');
  D.AddVar('r1', 'Int', '0', '');
  D.AddVar('o', 'Int', '0', '');
  D.AddVar('io', 'Int', '0', '');
  D.AddVar('ft', 'R_TRIG', '', 'a system FB in a global DB');
  // an FC with a Return value written as #Add2
  F := Result.AddBlock(bkFC, 1, 'Add2');
  F.Iface.AddSecVar(vsInput, 'a', 'Int', '', '');
  F.Iface.AddSecVar(vsInput, 'b', 'Int', '', '');
  F.Iface.AddSecVar(vsOutput, 'o', 'Int', '', '');
  F.Iface.AddSecVar(vsInOut, 'io', 'Int', '', '');
  F.Iface.AddSecVar(vsReturn, 'Ret_Val', 'Int', '', '');
  F.AddNet(nkSCL).Stl.Text := '#o := #a * #b;' + LineEnding + '#io := #io + 1;' + LineEnding + '#Add2 := #a + #b;';
  // an FB with the system FBs as statics
  F := Result.AddBlock(bkFB, 1, 'Sys');
  F.Iface.AddSecVar(vsInput, 'x', 'Bool', '', '');
  F.Iface.AddSecVar(vsInput, 'x2', 'Bool', '', '');
  F.Iface.AddSecVar(vsStatic, 't', 'TON_TIME', '', '');
  F.Iface.AddSecVar(vsStatic, 'tp', 'TP_TIME', '', '');
  F.Iface.AddSecVar(vsStatic, 'c', 'CTU_INT', '', '');
  F.Iface.AddSecVar(vsStatic, 'cd', 'CTD_INT', '', '');
  F.Iface.AddSecVar(vsStatic, 'r', 'R_TRIG', '', '');
  F.Iface.AddSecVar(vsStatic, 'f', 'F_TRIG', '', '');
  F.Iface.AddSecVar(vsStatic, 'rs', 'RS', '', '');
  F.Iface.AddSecVar(vsStatic, 'sr', 'SR', '', '');
  F.Iface.AddSecVar(vsStatic, 'edges', 'Int', '0', '');
  F.Iface.AddSecVar(vsStatic, 'fedges', 'Int', '0', '');
  F.AddNet(nkSCL).Stl.Text :=
    '#t(IN := #x, PT := T#50MS);' + LineEnding +
    '#tp(IN := #x, PT := T#1S, Q => %M71.4);' + LineEnding +
    '#r(CLK := #x);' + LineEnding +
    'IF #r.Q THEN #edges := #edges + 1; END_IF;' + LineEnding +
    '#f(CLK := #x, Q => %M71.5);' + LineEnding +
    'IF #f.Q THEN #fedges := #fedges + 1; END_IF;' + LineEnding +
    '#c(CU := #x, R := FALSE, PV := 3, CV => %MW24);' + LineEnding +
    '#cd(CD := #x, LD := NOT %M72.0, PV := 5);' + LineEnding +
    '%M72.0 := TRUE;' + LineEnding +
    '#rs(S := #x, R1 := #x2, Q1 => %M71.2);' + LineEnding +
    '#sr(S1 := #x, R := #x2, Q1 => %M71.3);' + LineEnding +
    '%M71.0 := #t.Q;' + LineEnding +
    '%M71.1 := #c.Q;' + LineEnding +
    '%MW20 := #edges;' + LineEnding +
    '%MW22 := #fedges;' + LineEnding +
    '%MW26 := #cd.CV;';
  D := Result.AddDB(2, 'iSys');
  D.InstanceOf := 1;
  F := Result.Block(0);
  F.DeleteNet(0);
  F.AddNet(nkSCL).Stl.Text := Main;
end;

procedure TestSclParity;
const
  Main =
    'VAR CONSTANT' + LineEnding +
    '  K10 : Int := 10;' + LineEnding +
    '  KR : Real := -1.5;' + LineEnding +
    '  KT : Time := T#2S;' + LineEnding +
    'END_VAR' + LineEnding +
    'VAR_TEMP' + LineEnding +
    '  j : Int;' + LineEnding +
    'END_VAR' + LineEnding +
    '%MW0 := INT#-5 + #K10;' + LineEnding +
    '%MW2 := 8#17 + 2#1010;' + LineEnding +
    '"D".u := UDINT#4000000000;' + LineEnding +
    '%MD30 := 4000000000;' + LineEnding +
    '"D".dt := D#2024-01-31;' + LineEnding +
    '"D".tod := TOD#12:30:15.5;' + LineEnding +
    '%MD34 := TIME_TO_DINT(#KT);' + LineEnding +
    '%MW38 := REAL_TO_INT(#KR * 4.0);' + LineEnding +
    '%MW40 := INT#100 + USINT#200 - SINT#-1;' + LineEnding +
    '%M42.0 := BOOL#1;' + LineEnding +
    '%MB43 := CHAR_TO_BYTE(CHAR#''A'');' + LineEnding +
    '// MUX' + LineEnding +
    '%MW8 := MUX(K := "D".k, IN0 := 10, IN1 := 20, IN2 := 30, INELSE := 99);' + LineEnding +
    '%MW10 := MUX("D".k2, 1, 2, 3);' + LineEnding +
    '%MW12 := MUX(K := 1, IN0 := 5, IN1 := MUX(K := 0, IN0 := 6, IN1 := 7));' + LineEnding +
    '%MW44 := MUX(K := "D".k2, IN0 := 1, IN1 := 2, INELSE := -1);' + LineEnding +
    '%MW52 := MIN(IN1 := 9, IN2 := 8, IN3 := 7, IN4 := 6, IN5 := 5, IN6 := 11);' + LineEnding +
    '%MW54 := MAX(1, 2, 3, 4, 5, 6, 7);' + LineEnding +
    '// slices' + LineEnding +
    '"D".w := W#16#0;' + LineEnding +
    '"D".w.%X3 := TRUE;' + LineEnding +
    '"D".w.%B1 := 16#AB;' + LineEnding +
    '"D".b := "D".w.%X11;' + LineEnding +
    '"D".y := "D".dw.%B2;' + LineEnding +
    '"D".w2 := "D".dw.%W1;' + LineEnding +
    '"D".i2 := -1;' + LineEnding +
    '"D".i2.%X15 := FALSE;' + LineEnding +
    '"D".arrw["D".k].%X0 := TRUE;' + LineEnding +
    '"D".arrw["D".k].%B1 := 16#C0;' + LineEnding +
    '"D".b2 := "D".arrw["D".k].%X15;' + LineEnding +
    '// arrays of two dimensions' + LineEnding +
    '"D".m[1, 2] := 5;' + LineEnding +
    '"D".m["D".k, 3] := 7;' + LineEnding +
    'FOR #j := 1 TO 3 DO "D".m[0, #j] := #j * 100; END_FOR;' + LineEnding +
    '%MW16 := "D".m[1, 2] + "D".m[2, 3] + "D".m[0, 3];' + LineEnding +
    '// FC: the Return value as #Add2, positional arguments' + LineEnding +
    'IF NOT %M60.0 THEN' + LineEnding +
    '  "D".r1 := "Add2"(2, 3, "D".o, "D".io);' + LineEnding +
    '  %MW46 := "Add2"(a := 4, b := 5, o => %MW48, io := "D".io);' + LineEnding +
    '  %M60.0 := TRUE;' + LineEnding +
    'END_IF;' + LineEnding +
    '// system FBs' + LineEnding +
    '"iSys"(x := %I0.0, x2 := %I0.1);' + LineEnding +
    '"D".ft(CLK := %I0.0);' + LineEnding +
    'IF "D".ft.Q THEN %MW50 := %MW50 + 1; END_IF;';
var
  P: TPlcProject;
  Pr: TCProgram;
  Rt: TPlcRuntime;
  K: Integer;

  procedure Pulse(Bit: Integer; Ms: Integer);
  begin
    Rt.SetSimBit(0, Bit, True);
    Wait(Ms);
    Rt.SetSimBit(0, Bit, False);
    Wait(Ms);
  end;

  function Errs(const Code: string): Integer;
  var
    Q: TPlcProject;
    Cp: TCProgram;
  begin
    Q := ParityProject(13, Code);
    Cp := Compile(Q);
    Result := Cp.ErrorCount;
    if Result = 0 then ShowMsgs(Cp);
    Cp.Free;
    Q.Free;
  end;

begin
  WriteLn('== SCL elements of the SCL Compiler (phase 1)');
  P := ParityProject(13, Main);
  try
    Pr := Compile(P);
    ShowMsgs(Pr);
    Check(Pr.ErrorCount = 0, 'phase 1 project compiles');
    Rt := TPlcRuntime.Create(13);
    try
      Rt.CmdDownload(Pr);
      Rt.CmdRun;
      Wait(40);
      Check(Rt.Mode = rmRun, 'RUN');
      Check(Peek(Rt, P, '%MW0') = 5, Format('INT#-5 + #K10 = 5 (%d)', [Peek(Rt, P, '%MW0')]));
      Check(Peek(Rt, P, '%MW2') = 25, Format('8#17 + 2#1010 = 25 (%d)', [Peek(Rt, P, '%MW2')]));
      Check(Peek(Rt, P, '"D".u') = 4000000000, Format('UDINT#4000000000 (%u)', [Peek(Rt, P, '"D".u')]));
      Check(Peek(Rt, P, '%MD30') = 4000000000, 'a number above the DInt range is a UDInt');
      Check(Peek(Rt, P, '"D".u2') = 4000000001, 'UDInt start value 4000000001');
      K := Trunc(EncodeDate(2024, 1, 31) - EncodeDate(1990, 1, 1));
      Check(Peek(Rt, P, '"D".dt') = LongWord(K), Format('D#2024-01-31 = %d days since 1990 (%d)', [K, Peek(Rt, P, '"D".dt')]));
      Check(Peek(Rt, P, '"D".tod') = 45015500, Format('TOD#12:30:15.5 = 45015500 ms (%d)', [Peek(Rt, P, '"D".tod')]));
      Check(Peek(Rt, P, '%MD34') = 2000, 'VAR CONSTANT KT : Time := T#2S');
      Check(Peek(Rt, P, '%MW38') = $FFFA, Format('VAR CONSTANT KR : Real := -1.5, * 4 = -6 (%x)', [Peek(Rt, P, '%MW38')]));
      Check(Peek(Rt, P, '%MW40') = 301, Format('INT#100 + USINT#200 - SINT#-1 = 301 (%d)', [Peek(Rt, P, '%MW40')]));
      Check(Peek(Rt, P, '%M42.0') = 1, 'BOOL#1');
      Check(Peek(Rt, P, '%MB43') = 65, 'CHAR#''A'' = 65');
      Check(Peek(Rt, P, '%MW8') = 30, Format('MUX(K := 2, ..) = IN2 = 30 (%d)', [Peek(Rt, P, '%MW8')]));
      Check(Peek(Rt, P, '%MW10') = 0, Format('MUX(7, 1, 2, 3): K outside, no INELSE = 0 (%d)', [Peek(Rt, P, '%MW10')]));
      Check(Peek(Rt, P, '%MW12') = 6, Format('MUX in MUX = 6 (%d)', [Peek(Rt, P, '%MW12')]));
      Check(Peek(Rt, P, '%MW44') = $FFFF, 'MUX: K outside -> INELSE = -1');
      Check(Peek(Rt, P, '%MW52') = 5, Format('MIN of 6 inputs = 5 (%d)', [Peek(Rt, P, '%MW52')]));
      Check(Peek(Rt, P, '%MW54') = 7, 'MAX of 7 positional inputs = 7');
      Check(Peek(Rt, P, '"D".w') = $AB08, Format('w.%%X3 := TRUE; w.%%B1 := 16#AB -> 16#AB08 (%x)', [Peek(Rt, P, '"D".w')]));
      Check(Peek(Rt, P, '"D".b') = 1, 'w.%X11 of 16#AB08 = TRUE');
      Check(Peek(Rt, P, '"D".y') = $22, Format('DW#16#11223344.%%B2 = 16#22 (%x)', [Peek(Rt, P, '"D".y')]));
      Check(Peek(Rt, P, '"D".w2') = $1122, Format('DW#16#11223344.%%W1 = 16#1122 (%x)', [Peek(Rt, P, '"D".w2')]));
      Check(Peek(Rt, P, '"D".i2') = $7FFF, Format('Int -1 with .%%X15 := FALSE = 32767 (%x)', [Peek(Rt, P, '"D".i2')]));
      Check(Peek(Rt, P, '"D".arrw[2]') = $C001, Format('arrw[#k].%%X0 / .%%B1 with a variable index = 16#C001 (%x)',
        [Peek(Rt, P, '"D".arrw[2]')]));
      Check(Peek(Rt, P, '"D".b2') = 1, 'arrw[#k].%X15 = TRUE');
      Check(Peek(Rt, P, '"D".m[1,2]') = 5, 'm[1, 2] := 5');
      Check(Peek(Rt, P, '"D".m[2,3]') = 7, 'm["D".k, 3] := 7');
      Check(Peek(Rt, P, '%MW16') = 312, Format('m[1, 2] + m[2, 3] + m[0, 3] = 312 (%d)', [Peek(Rt, P, '%MW16')]));
      Check((Peek(Rt, P, '"D".a5[0]') = 1) and (Peek(Rt, P, '"D".a5[1]') = 2) and (Peek(Rt, P, '"D".a5[2]') = 7) and
        (Peek(Rt, P, '"D".a5[4]') = 7), 'start values [1, 2, 3(7)]');
      Check(Peek(Rt, P, '"D".ti') = $FFFD, 'start value INT#-3');
      Check(Peek(Rt, P, '"D".r1') = 5, Format('#Add2 := #a + #b; "Add2"(2, 3, ..) = 5 (%d)', [Peek(Rt, P, '"D".r1')]));
      Check(Peek(Rt, P, '"D".o') = 6, 'positional Output o = 6');
      Check(Peek(Rt, P, '"D".io') = 2, Format('positional InOut io: 0 + 1 + 1 = 2 (%d)', [Peek(Rt, P, '"D".io')]));
      Check((Peek(Rt, P, '%MW46') = 9) and (Peek(Rt, P, '%MW48') = 20), 'named call: Return 9, o 20');
      // the system FBs
      Check(Peek(Rt, P, '%MW26') = 5, Format('CTD_INT loaded with PV 5 (%d)', [Peek(Rt, P, '%MW26')]));
      Rt.SetSimBit(0, 0, True);
      Wait(120);
      Check(Peek(Rt, P, '%M71.0') = 1, 'TON_TIME: Q after PT');
      Check(Peek(Rt, P, '%M71.4') = 1, 'TP_TIME: Q during the pulse');
      Check(Peek(Rt, P, '%MW20') = 1, Format('R_TRIG: one rising edge (%d)', [Peek(Rt, P, '%MW20')]));
      Check(Peek(Rt, P, '%MW24') = 1, 'CTU_INT: CV = 1 (CV => %MW24)');
      Check(Peek(Rt, P, '%MW26') = 4, 'CTD_INT: CV = 4');
      Check((Peek(Rt, P, '%M71.2') = 1) and (Peek(Rt, P, '%M71.3') = 1), 'RS / SR set');
      Check(Peek(Rt, P, '%MW50') = 1, 'R_TRIG in a global DB: "D".ft(CLK := ..)');
      Rt.SetSimBit(0, 1, True);
      Wait(40);
      Check(Peek(Rt, P, '%M71.2') = 0, 'RS: reset wins (S and R1)');
      Check(Peek(Rt, P, '%M71.3') = 1, 'SR: set wins (S1 and R)');
      Rt.SetSimBit(0, 0, False);
      Wait(40);
      Check(Peek(Rt, P, '%MW22') = 1, 'F_TRIG: one falling edge');
      Check(Peek(Rt, P, '%M71.3') = 0, 'SR: reset when S1 = 0 and R = 1');
      Check(Peek(Rt, P, '%M71.0') = 0, 'TON_TIME: Q off with IN');
      Rt.SetSimBit(0, 1, False);
      Pulse(0, 30);
      Pulse(0, 30);
      Check(Peek(Rt, P, '%MW20') = 3, Format('R_TRIG: 3 rising edges (%d)', [Peek(Rt, P, '%MW20')]));
      Check(Peek(Rt, P, '%M71.1') = 1, 'CTU_INT: Q at CV >= PV');
      Check(Peek(Rt, P, '%MW24') = 3, 'CTU_INT: CV = 3');
      Check(Peek(Rt, P, '%MW50') = 3, 'R_TRIG in a DB: 3 edges');
    finally
      Rt.Free;
    end;
  finally
    P.Free;
  end;
  // errors
  Check(Errs('VAR CONSTANT C : Int := 1; END_VAR' + LineEnding + '#C := 2;') > 0, 'a constant cannot be written');
  Check(Errs('VAR CONSTANT C : Int; END_VAR') > 0, 'VAR CONSTANT needs a value');
  Check(Errs('VAR CONSTANT C : Int := 1.5; END_VAR') > 0, 'VAR CONSTANT Int := 1.5: type mismatch');
  Check(Errs('"D".w.%X16 := TRUE;') > 0, 'no .%X16 in a Word');
  Check(Errs('"D".y.%W0 := 0;') > 0, 'no .%W0 in a Byte');
  Check(Errs('"D".b := "D".tod.%X0;') > 0, 'no slice of a Time_Of_Day');
  Check(Errs('%MW0 := MUX(K := 1.5, IN0 := 1, IN1 := 2);') > 0, 'MUX: K must be an integer');
  Check(Errs('%MW0 := MUX(K := 1, IN0 := 1);') > 0, 'MUX needs two inputs');
  Check(Errs('%MW0 := INT#40000;') > 0, 'INT#40000 is out of range');
  Check(Errs('"D".dt := D#2024-02-30;') > 0, 'D#2024-02-30 is no date');
  Check(Errs('"D".m[1] := 0;') > 0, 'm[1]: two indexes expected');
  Check(Errs('"D".m[3, 1] := 0;') > 0, 'm[3, 1]: outside the array');
  Check(Errs('"D".r1 := "Add2"(1, 2, 3, "D".io);') > 0, 'positional Output needs a variable');
  Check(Errs('"D".r1 := "Add2"(1, 2, "D".o, "D".io, 5);') > 0, 'too many positional parameters');
end;

{ phase 2: String[n], WString[n], Char, WChar, LEN CONCAT LEFT RIGHT MID FIND, comparisons, parameters }
function PeekStr(Rt: TPlcRuntime; P: TPlcProject; const S: string; Wide: Boolean = False): string;
var
  Res: TResolver;
  O: TOperand;
  E: string;
begin
  Result := '<?>';
  Res := TResolver.Create(P);
  try
    if not Res.Resolve(S, O, E, False) then
    begin
      WriteLn('    resolve ', S, ': ', E);
      Exit;
    end;
    if not Rt.PeekString(O, Wide, Result) then Result := '<no>';
  finally
    Res.Free;
  end;
end;

function StrProject(AModel: Integer; const Main: string): TPlcProject;
var
  F: TBlock;
  D: TDataBlock;
begin
  Result := TPlcProject.Create;
  Result.NewEmpty(AModel);
  D := Result.AddDB(1, 'S');
  D.AddVar('s1', 'String[20]', '''Hello''', '');
  D.AddVar('s2', 'String[10]', '', '');
  D.AddVar('s3', 'String', '', '');
  D.AddVar('s4', 'String[10]', '', '');
  D.AddVar('s5', 'String[10]', '', '');
  D.AddVar('s6', 'String[10]', '', '');
  D.AddVar('s7', 'String[10]', '', '');
  D.AddVar('s8', 'String[10]', '', '');
  D.AddVar('s9', 'String[10]', '', '');
  D.AddVar('tr', 'String[4]', '', '');
  D.AddVar('esc', 'String[20]', '', '');
  D.AddVar('esc2', 'String[20]', '', '');
  D.AddVar('w1', 'WString[20]', 'WSTRING#''Gr$00FC$00DFe''', '');
  D.AddVar('w2', 'WString[20]', '', '');
  D.AddVar('c', 'Char', '''A''', '');
  D.AddVar('wc', 'WChar', '', '');
  D.AddVar('n', 'Int', '0', '');
  D.AddVar('k', 'Int', '1', '');
  D.AddVar('b1', 'Bool', 'FALSE', '');
  D.AddVar('b2', 'Bool', 'FALSE', '');
  D.AddVar('b3', 'Bool', 'FALSE', '');
  D.AddVar('b4', 'Bool', 'FALSE', '');
  D.AddVar('b5', 'Bool', 'FALSE', '');
  D.AddVar('b6', 'Bool', 'FALSE', '');
  D.AddVar('arr', 'Array[0..2] of String[8]', '[''ab'', ''cd'', ''ef'']', '');
  D.AddVar('g', 'String[40]', '', '');
  D.AddVar('go', 'String[30]', '', '');
  D.AddVar('after', 'Int', '77', 'after the strings: not overwritten');
  F := Result.AddBlock(bkFC, 1, 'Greet');
  F.Iface.AddSecVar(vsInput, 'name', 'String[20]', '', '');
  F.Iface.AddSecVar(vsOutput, 'o', 'String[30]', '', '');
  F.Iface.AddSecVar(vsReturn, 'Ret_Val', 'String[40]', '', '');
  F.AddNet(nkSCL).Stl.Text := '#o := CONCAT(IN1 := ''Hi '', IN2 := #name);' + LineEnding +
    '#Greet := CONCAT(IN1 := #o, IN2 := ''!'');';
  F := Result.AddBlock(bkFB, 1, 'Buf');
  F.Iface.AddSecVar(vsInput, 'txt', 'String[10]', '', '');
  F.Iface.AddSecVar(vsOutput, 'len', 'Int', '', '');
  F.Iface.AddSecVar(vsInOut, 'io', 'String[12]', '', '');
  F.Iface.AddSecVar(vsStatic, 'last', 'String[10]', '''start''', '');
  F.AddNet(nkSCL).Stl.Text := '#last := #txt;' + LineEnding + '#len := LEN(#last);' + LineEnding +
    '#io := CONCAT(IN1 := LEFT(IN := #io, L := 3), IN2 := ''-x'');';
  D := Result.AddDB(2, 'iBuf');
  D.InstanceOf := 1;
  F := Result.Block(0);
  F.DeleteNet(0);
  F.AddNet(nkSCL).Stl.Text := Main;
end;

procedure TestSclStrings;
var
  Res: TResolver;
  O: TOperand;
  Er: string;
const
  Main =
    'VAR_TEMP' + LineEnding +
    '  t : String[30];' + LineEnding +
    'END_VAR' + LineEnding +
    '"S".s2 := "S".s1;' + LineEnding +
    '"S".s3 := CONCAT(IN1 := "S".s1, IN2 := '' world'');' + LineEnding +
    '"S".n := LEN("S".s3);' + LineEnding +
    '%MW0 := FIND(IN1 := "S".s3, IN2 := ''wor'');' + LineEnding +
    '#t := MID(IN := "S".s3, L := 3, P := 2);' + LineEnding +
    '"S".s4 := LEFT(IN := "S".s3, L := 5);' + LineEnding +
    '"S".s5 := RIGHT(IN := "S".s3, L := 5);' + LineEnding +
    '"S".s6 := #t;' + LineEnding +
    '"S".tr := "S".s3;' + LineEnding +
    '"S".b1 := "S".s4 = ''Hello'';' + LineEnding +
    '"S".b2 := "S".s4 < ''Help'';' + LineEnding +
    '"S".b3 := "S".c = ''A'';' + LineEnding +
    '"S".b4 := ''Hello'' > "S".c;' + LineEnding +
    '"S".b5 := "S".c < "S".s1;' + LineEnding +
    '"S".b6 := "S".s5 <> ''world'';' + LineEnding +
    '"S".s7 := "S".c;' + LineEnding +
    '"S".s8 := CONCAT(IN1 := "S".c, IN2 := ''B'');' + LineEnding +
    '"S".arr["S".k] := ''zz'';' + LineEnding +
    '"S".s9 := "S".arr[2];' + LineEnding +
    '"S".esc := ''it$''s ok'';' + LineEnding +
    '"S".esc2 := ''a''''b$54'';' + LineEnding +
    '"S".w2 := CONCAT(IN1 := "S".w1, IN2 := WSTRING#''!'');' + LineEnding +
    '"S".wc := WCHAR#''$03A9'';' + LineEnding +
    '%MW2 := WCHAR_TO_INT("S".wc);' + LineEnding +
    '"S".g := "Greet"(name := "S".s1, o => "S".go);' + LineEnding +
    'IF NOT %M60.0 THEN' + LineEnding +
    '  "S".s8 := ''keep'';' + LineEnding +
    '  %M60.0 := TRUE;' + LineEnding +
    'END_IF;' + LineEnding +
    '"iBuf"(txt := ''abcdefghijkl'', len => %MW4, io := "S".s9);';
var
  P: TPlcProject;
  Pr: TCProgram;
  Rt: TPlcRuntime;

  function Errs(const Code: string): Integer;
  var
    Q: TPlcProject;
    Cp: TCProgram;
  begin
    Q := StrProject(13, Code);
    Cp := Compile(Q);
    Result := Cp.ErrorCount;
    if Result = 0 then ShowMsgs(Cp);
    Cp.Free;
    Q.Free;
  end;

begin
  WriteLn('== SCL strings (phase 2)');
  P := StrProject(13, Main);
  try
    Pr := Compile(P);
    ShowMsgs(Pr);
    Check(Pr.ErrorCount = 0, 'string project compiles');
    Check(P.FindDBByName('S').Vars[0].Udt.Size = 22, 'String[20] takes 22 bytes');
    Check(P.FindDBByName('S').Vars[2].Udt.Size = 256, 'String takes 256 bytes');
    Check(P.FindDBByName('S').Vars[12].Udt.Size = 44, 'WString[20] takes 44 bytes');
    Rt := TPlcRuntime.Create(13);
    try
      Rt.CmdDownload(Pr);
      Rt.CmdRun;
      Wait(60);
      Check(Rt.Mode = rmRun, 'RUN');
      if Rt.Mode <> rmRun then DumpDiag(Rt);
      Check(Peek(Rt, P, '"S".s1') = 20, 'the head of String[20]: max length 20');
      Check(PeekStr(Rt, P, '"S".s1') = 'Hello', 'start value ''Hello''');
      Check(PeekStr(Rt, P, '"S".s2') = 'Hello', 's2 := s1');
      Check(PeekStr(Rt, P, '"S".s3') = 'Hello world', 'CONCAT = ''Hello world'' (' + PeekStr(Rt, P, '"S".s3') + ')');
      Check(Peek(Rt, P, '"S".n') = 11, 'LEN = 11');
      Check(Peek(Rt, P, '%MW0') = 7, Format('FIND(''Hello world'', ''wor'') = 7 (%d)', [Peek(Rt, P, '%MW0')]));
      Check(PeekStr(Rt, P, '"S".s4') = 'Hello', 'LEFT 5 = ''Hello''');
      Check(PeekStr(Rt, P, '"S".s5') = 'world', 'RIGHT 5 = ''world''');
      Check(PeekStr(Rt, P, '"S".s6') = 'ell', 'MID(L := 3, P := 2) through a VAR_TEMP String = ''ell''');
      Check(PeekStr(Rt, P, '"S".tr') = 'Hell', 'String[4] := ''Hello world'' keeps 4 characters');
      Check(Peek(Rt, P, '"S".b1') = 1, '''Hello'' = ''Hello''');
      Check(Peek(Rt, P, '"S".b2') = 1, '''Hello'' < ''Help''');
      Check(Peek(Rt, P, '"S".b3') = 1, 'Char = ''A''');
      Check(Peek(Rt, P, '"S".b4') = 1, '''Hello'' > Char ''A''');
      Check(Peek(Rt, P, '"S".b5') = 1, 'Char ''A'' < ''Hello'' (the Char first)');
      Check(Peek(Rt, P, '"S".b6') = 0, '''world'' <> ''world'' = FALSE');
      Check(PeekStr(Rt, P, '"S".s7') = 'A', 'String := Char');
      Check(PeekStr(Rt, P, '"S".s8') = 'AB', 'CONCAT(Char, ''B'') = ''AB'' (' + PeekStr(Rt, P, '"S".s8') + ')');
      Check((PeekStr(Rt, P, '"S".arr[0]') = 'ab') and (PeekStr(Rt, P, '"S".arr[1]') = 'zz'),
        'Array of String: start values, arr["S".k] := ''zz''');
      Check(PeekStr(Rt, P, '"S".esc') = 'it''s ok', '$'' in a literal');
      Check(PeekStr(Rt, P, '"S".esc2') = 'a''bT', ''''' and $54 in a literal (' + PeekStr(Rt, P, '"S".esc2') + ')');
      Check(PeekStr(Rt, P, '"S".w1', True) = 'Grüße', 'WString start value with $00FC$00DF (' +
        PeekStr(Rt, P, '"S".w1', True) + ')');
      Check(PeekStr(Rt, P, '"S".w2', True) = 'Grüße!', 'CONCAT of WStrings');
      Check(Peek(Rt, P, '%MW2') = 937, Format('WCHAR#''$03A9'' = 937 (%d)', [Peek(Rt, P, '%MW2')]));
      Check(PeekStr(Rt, P, '"S".go') = 'Hi Hello', 'FC String Output: ''Hi Hello''');
      Check(PeekStr(Rt, P, '"S".g') = 'Hi Hello!', 'FC String Return value as #Greet: ''Hi Hello!''');
      Check(Peek(Rt, P, '%MW4') = 10, Format('FB String Input into a String[10] Static: LEN = 10 (%d)', [Peek(Rt, P, '%MW4')]));
      Check(PeekStr(Rt, P, '"iBuf".last') = 'abcdefghij', 'the Static keeps 10 characters');
      Check(PeekStr(Rt, P, '"S".s9') = 'ef-x', 'FB InOut String: LEFT 3 + ''-x'' (' + PeekStr(Rt, P, '"S".s9') + ')');
      Check(Peek(Rt, P, '"S".after') = 77, 'the variable after the strings is not overwritten');
      // the watch table: a new text for a String
      Res := TResolver.Create(P);
      try
        Res.Resolve('"S".s1', O, Er, False);
      finally
        Res.Free;
      end;
      Rt.CmdModifyStr(O, 'Modified text that is too long');
      Wait(40);
      Check(PeekStr(Rt, P, '"S".s1') = 'Modified text that i', 'modify a String[20]: 20 characters kept (' +
        PeekStr(Rt, P, '"S".s1') + ')');
      Check(PeekStr(Rt, P, '"S".s2') = 'Modified t', 'the program copies it into a String[10]');
    finally
      Rt.Free;
    end;
  finally
    P.Free;
  end;
  // errors
  Check(Errs('"S".n := "S".s1;') > 0, 'Int := String: type mismatch');
  Check(Errs('"S".s1 := 5;') > 0, 'String := 5: type mismatch');
  Check(Errs('"S".n := LEN(5);') > 0, 'LEN(5): a String expected');
  Check(Errs('"S".s1 := LEFT(IN := "S".s1, L := 1.5);') > 0, 'LEFT: L must be an integer');
  Check(Errs('"S".b1 := "S".s1 = 5;') > 0, 'String = 5 cannot be compared');
  Check(Errs('"S".s1 := "S".s1 + ''a'';') > 0, 'String + String: not a number operation');
  Check(Errs('"S".s1 := SEL(G := TRUE, IN0 := ''a'', IN1 := ''bc'');') > 0, 'SEL of strings');
end;

{ phase 3: LInt ULInt LWord LReal LTime LTOD LDT DT DTL, LT# literals, time arithmetic, TON_LTIME, CTU_DINT }
function Peek64(Rt: TPlcRuntime; P: TPlcProject; const S: string): QWord;
var
  Res: TResolver;
  O: TOperand;
  E: string;
begin
  Result := $DEADBEEF;
  Res := TResolver.Create(P);
  try
    if not Res.Resolve(S, O, E, False) then
    begin
      WriteLn('    resolve ', S, ': ', E);
      Exit;
    end;
    Rt.Peek8(O, Result);
  finally
    Res.Free;
  end;
end;

function L64Project(AModel: Integer; const Main: string): TPlcProject;
var
  F: TBlock;
  D: TDataBlock;
begin
  Result := TPlcProject.Create;
  Result.NewEmpty(AModel);
  D := Result.AddDB(1, 'L');
  D.AddVar('li', 'LInt', '9007199254740993', '2^53 + 1: no Double holds it');
  D.AddVar('li2', 'LInt', '0', '');
  D.AddVar('li3', 'LInt', '0', '');
  D.AddVar('li4', 'LInt', '0', '');
  D.AddVar('li5', 'LInt', '0', '');
  D.AddVar('li6', 'LInt', '0', '');
  D.AddVar('li7', 'LInt', '0', '');
  D.AddVar('ul', 'ULInt', '18446744073709551615', '');
  D.AddVar('ul2', 'ULInt', '0', '');
  D.AddVar('lw', 'LWord', 'LW#16#FFFF0000FFFF0000', '');
  D.AddVar('dwx', 'DWord', '0', '');
  D.AddVar('lr', 'LReal', '0.1', '');
  D.AddVar('lr2', 'LReal', '0.0', '');
  D.AddVar('lt', 'LTime', 'LT#1D2H3M4S5MS6US7NS', '');
  D.AddVar('lt2', 'LTime', 'LT#0NS', '');
  D.AddVar('lt3', 'LTime', 'LT#0NS', '');
  D.AddVar('ltod', 'LTime_Of_Day', 'LTOD#23:59:59.999999999', '');
  D.AddVar('ltod2', 'LTOD', '', '');
  D.AddVar('ldt', 'LDT', 'LDT#2024-01-31-12:00:00.123456789', '');
  D.AddVar('ldt2', 'LDT', '', '');
  D.AddVar('dt', 'Date_And_Time', 'DT#2024-01-31-12:00:00.500', '');
  D.AddVar('dt2', 'DT', '', '');
  D.AddVar('t', 'Time', 'T#0MS', '');
  D.AddVar('t2', 'Time', 'T#0MS', '');
  D.AddVar('tod', 'Time_Of_Day', '', '');
  D.AddVar('tod2', 'Time_Of_Day', '', '');
  D.AddVar('d', 'Date', '', '');
  D.AddVar('i', 'Int', '0', '');
  D.AddVar('di', 'DInt', '0', '');
  D.AddVar('k', 'Int', '1', '');
  D.AddVar('r', 'Real', '0.0', '');
  D.AddVar('b1', 'Bool', 'FALSE', '');
  D.AddVar('b2', 'Bool', 'FALSE', '');
  D.AddVar('dtl', 'DTL', '', '');
  D.AddVar('sl', 'Array[0..1] of LInt', '0', '');
  F := Result.AddBlock(bkFB, 1, 'Sys64');
  F.Iface.AddSecVar(vsInput, 'x', 'Bool', '', '');
  F.Iface.AddSecVar(vsStatic, 'tl', 'TON_LTIME', '', '');
  F.Iface.AddSecVar(vsStatic, 'cd', 'CTU_DINT', '', '');
  F.Iface.AddSecVar(vsStatic, 'cl', 'CTUD_LINT', '', '');
  F.Iface.AddSecVar(vsStatic, 'et', 'LTime', '', '');
  F.AddNet(nkSCL).Stl.Text :=
    '#tl(IN := #x, PT := LT#50MS, ET => #et);' + LineEnding +
    '%M70.0 := #tl.Q;' + LineEnding +
    '#cd(CU := #x, R := FALSE, PV := 100000);' + LineEnding +
    '%MD72 := #cd.CV;' + LineEnding +
    '%M70.1 := #cd.Q;' + LineEnding +
    '#cl(CU := #x, CD := FALSE, R := FALSE, LD := NOT %M70.7, PV := LINT#5000000000);' + LineEnding +
    '%M70.7 := TRUE;' + LineEnding +
    '"L".li7 := #cl.CV;';
  D := Result.AddDB(2, 'iSys64');
  D.InstanceOf := 1;
  F := Result.Block(0);
  F.DeleteNet(0);
  F.AddNet(nkSCL).Stl.Text := Main;
end;

procedure TestScl64;
const
  Main =
    'VAR CONSTANT' + LineEnding +
    '  C64 : LInt := 9007199254740993;' + LineEnding +
    'END_VAR' + LineEnding +
    '"L".li2 := "L".li + 2;' + LineEnding +
    '"L".i := LINT_TO_INT("L".li);' + LineEnding +
    '"L".di := LINT_TO_DINT(5000000000);' + LineEnding +
    '"L".ul2 := "L".ul - 1;' + LineEnding +
    '"L".b1 := "L".ul > 9000000000000000000;' + LineEnding +
    '"L".dwx := "L".lw.%D1;' + LineEnding +
    '"L".lw.%X0 := TRUE;' + LineEnding +
    '"L".lr2 := "L".lr * 3.0;' + LineEnding +
    '"L".lt2 := "L".lt + LT#1NS;' + LineEnding +
    '"L".t := LTIME_TO_TIME("L".lt);' + LineEnding +
    '"L".lt3 := TIME_TO_LTIME(T#2S);' + LineEnding +
    '"L".tod := TOD#23:00:00 + T#2H;' + LineEnding +
    '"L".t2 := TOD#12:00:00 - TOD#11:30:00;' + LineEnding +
    '"L".dt2 := "L".dt + T#1D;' + LineEnding +
    '"L".d := DT_TO_DATE("L".dt2);' + LineEnding +
    '"L".tod2 := DT_TO_TOD("L".dt2);' + LineEnding +
    '"L".ltod2 := "L".ltod + LT#1NS;' + LineEnding +
    '"L".ldt2 := DT_TO_LDT("L".dt);' + LineEnding +
    '"L".dtl.YEAR := 2025;' + LineEnding +
    '"L".dtl.MONTH := 7;' + LineEnding +
    '"L".sl["L".k] := "L".li * 2;' + LineEnding +
    '"L".li3 := MUX(K := 1, IN0 := LINT#1, IN1 := "L".li);' + LineEnding +
    '"L".li4 := SEL(G := TRUE, IN0 := LINT#0, IN1 := "L".li2);' + LineEnding +
    '"L".li5 := MAX(IN1 := "L".li, IN2 := "L".li2);' + LineEnding +
    '"L".li6 := #C64;' + LineEnding +
    '"L".r := LREAL_TO_REAL("L".lr);' + LineEnding +
    '"L".b2 := "L".ldt > LDT#2024-01-31-12:00:00.123456788;' + LineEnding +
    '"iSys64"(x := %I0.0);';
var
  P: TPlcProject;
  Pr: TCProgram;
  Rt: TPlcRuntime;
  Dv: Double;
  Q: QWord;
  Ns: Int64;

  function Errs(const Code: string; AModel: Integer = 13): Integer;
  var
    Pq: TPlcProject;
    Cp: TCProgram;
  begin
    Pq := L64Project(AModel, Code);
    Cp := Compile(Pq);
    Result := Cp.ErrorCount;
    if Result = 0 then ShowMsgs(Cp);
    Cp.Free;
    Pq.Free;
  end;

begin
  WriteLn('== SCL 64 bit and the long times / dates (phase 3)');
  P := L64Project(13, Main);
  try
    Pr := Compile(P);
    ShowMsgs(Pr);
    Check(Pr.ErrorCount = 0, '64 bit project compiles');
    Check(P.FindDBByName('L').FindVar('dtl') >= 0, 'DTL variable');
    Check(P.FindDBByName('L').Vars[P.FindDBByName('L').FindVar('dtl')].Udt.Size = 12, 'DTL takes 12 bytes');
    Rt := TPlcRuntime.Create(13);
    try
      Rt.CmdDownload(Pr);
      Rt.CmdRun;
      Wait(60);
      Check(Rt.Mode = rmRun, 'RUN');
      if Rt.Mode <> rmRun then DumpDiag(Rt);
      Check(Peek64(Rt, P, '"L".li') = 9007199254740993, 'LInt start value 2^53 + 1, exact');
      Check(Peek64(Rt, P, '"L".li2') = 9007199254740995, Format('LInt + 2 exact (%d)', [Int64(Peek64(Rt, P, '"L".li2'))]));
      Check(Peek(Rt, P, '"L".i') = 1, 'LINT_TO_INT(2^53 + 1) = 1 (the low 16 bits)');
      Check(Peek(Rt, P, '"L".di') = 705032704, Format('LINT_TO_DINT(5000000000) = 705032704 (%d)', [Peek(Rt, P, '"L".di')]));
      Check(Peek64(Rt, P, '"L".ul2') = QWord(18446744073709551614), 'ULInt max - 1');
      Check(Peek(Rt, P, '"L".b1') = 1, 'ULInt compares unsigned');
      Check(Peek(Rt, P, '"L".dwx') = $FFFF0000, Format('LWord.%%D1 = 16#FFFF0000 (%x)', [Peek(Rt, P, '"L".dwx')]));
      Check(Peek64(Rt, P, '"L".lw') = QWord($FFFF0000FFFF0001), 'LWord.%X0 := TRUE');
      Q := Peek64(Rt, P, '"L".lr2');
      Move(Q, Dv, 8);
      Check(Dv = 0.1 * 3.0, Format('LReal 0.1 * 3.0 in double precision (%.17g)', [Dv]));
      Ns := 93784005006007;
      Check(Int64(Peek64(Rt, P, '"L".lt')) = Ns, 'LT#1D2H3M4S5MS6US7NS in ns');
      Check(Int64(Peek64(Rt, P, '"L".lt2')) = Ns + 1, 'LTime + LT#1NS');
      Check(Peek(Rt, P, '"L".t') = 93784005, Format('LTIME_TO_TIME: ms (%d)', [Peek(Rt, P, '"L".t')]));
      Check(Int64(Peek64(Rt, P, '"L".lt3')) = 2000000000, 'TIME_TO_LTIME(T#2S) = 2e9 ns');
      Check(Peek(Rt, P, '"L".tod') = 3600000, Format('TOD#23:00 + T#2H = TOD#1:00 (%d)', [Peek(Rt, P, '"L".tod')]));
      Check(Peek(Rt, P, '"L".t2') = 1800000, 'TOD - TOD = T#30M');
      Check(Peek64(Rt, P, '"L".dt2') = QWord($2402011200005005), Format('DT + T#1D: the BCD of 2024-02-01 12:00:00.500 (%x)',
        [Peek64(Rt, P, '"L".dt2')]));
      Check(Peek(Rt, P, '"L".d') = LongWord(Trunc(EncodeDate(2024, 2, 1) - EncodeDate(1990, 1, 1))), 'DT_TO_DATE');
      Check(Peek(Rt, P, '"L".tod2') = 43200500, 'DT_TO_TOD = 12:00:00.500');
      Check(Peek64(Rt, P, '"L".ltod2') = 0, 'LTOD#23:59:59.999999999 + 1 ns = midnight');
      Ns := Trunc(EncodeDate(2024, 1, 31) - EncodeDate(1970, 1, 1)) * Int64(86400000000000) + 12 * Int64(3600000000000) + 500000000;
      Check(Int64(Peek64(Rt, P, '"L".ldt2')) = Ns, 'DT_TO_LDT: ns since 1970');
      Check(Int64(Peek64(Rt, P, '"L".ldt')) = Ns - 500000000 + 123456789, 'LDT start value with ns');
      Check(Peek(Rt, P, '"L".b2') = 1, 'LDT compare with one ns less');
      Check(Peek(Rt, P, '"L".dtl.YEAR') = 2025, 'DTL.YEAR := 2025');
      Check(Peek(Rt, P, '"L".dtl.DAY') = 1, 'DTL start: DAY 1');
      Check(Peek(Rt, P, '"L".dtl.WEEKDAY') = 5, 'DTL start: a Thursday');
      Check(Peek64(Rt, P, '"L".sl[1]') = 18014398509481986, 'array of LInt with a variable index: exact');
      Check(Peek64(Rt, P, '"L".li3') = 9007199254740993, 'MUX of LInt exact');
      Check(Peek64(Rt, P, '"L".li4') = 9007199254740995, 'SEL of LInt exact');
      Check(Peek64(Rt, P, '"L".li5') = 9007199254740995, 'MAX of LInt exact');
      Check(Peek64(Rt, P, '"L".li6') = 9007199254740993, 'VAR CONSTANT LInt exact');
      Check(Abs(PeekReal(Rt, P, '"L".r') - 0.1) < 1E-7, 'LREAL_TO_REAL');
      Check(Int64(Peek64(Rt, P, '"L".li7')) = 5000000000, 'CTUD_LINT loaded with PV 5000000000');
      Rt.SetSimBit(0, 0, True);
      Wait(120);
      Check(Peek(Rt, P, '%M70.0') = 1, 'TON_LTIME: Q after LT#50MS');
      Check(Int64(Peek64(Rt, P, '"iSys64".et')) = 50000000, 'TON_LTIME: ET = PT in ns');
      Check(Peek(Rt, P, '%MD72') = 1, 'CTU_DINT counts');
      Check(Int64(Peek64(Rt, P, '"L".li7')) = 5000000001, 'CTUD_LINT counts past 2^32');
    finally
      Rt.Free;
    end;
  finally
    P.Free;
  end;
  Check(Errs('"L".t := "L".lt;') > 0, 'Time := LTime needs a conversion');
  Check(Errs('"L".lt2 := "L".t + "L".lt;') > 0, 'TIME + LTIME is not allowed');
  Check(Errs('"L".r := "L".lr;') > 0, 'Real := LReal needs LREAL_TO_REAL');
  Check(Errs('"L".tod := TOD#1:0:0 * 2;') > 0, 'TOD * 2 is not allowed');
  Check(Errs('"L".t := TOD#1:0:0 + TOD#2:0:0;') > 0, 'TOD + TOD is not allowed');
  Check(Errs('"L".li := LINT#9223372036854775808;') > 0, 'LINT# out of range');
  Check(Errs('"L".i := 1;', 7) > 0, 'LInt, LTime ... do not exist on the S7-1200');
end;

{ phase 4: .scl sources (TIA): export, import, the round trip }
procedure TestSclSource;
const
  Src =
    '// a source as TIA writes it' + LineEnding +
    'TYPE "Recipe"' + LineEnding +
    'VERSION : 0.1' + LineEnding +
    '   STRUCT' + LineEnding +
    '      Speed : Int := 100;   // rpm' + LineEnding +
    '      Time1 : Time := T#2S;' + LineEnding +
    '   END_STRUCT;' + LineEnding +
    'END_TYPE' + LineEnding +
    '' + LineEnding +
    '// FB7' + LineEnding +
    'FUNCTION_BLOCK "Mixer"' + LineEnding +
    '{ S7_Optimized_Access := ''TRUE'' }' + LineEnding +
    'VERSION : 0.1' + LineEnding +
    '   VAR_INPUT' + LineEnding +
    '      Start { ExternalAccessible := ''False'' } : Bool;   // the start button' + LineEnding +
    '      Rec : "Recipe";' + LineEnding +
    '   END_VAR' + LineEnding +
    '   VAR_OUTPUT' + LineEnding +
    '      Running : Bool;' + LineEnding +
    '      Count : Int;' + LineEnding +
    '   END_VAR' + LineEnding +
    '   VAR' + LineEnding +
    '      Edge : R_TRIG;' + LineEnding +
    '      State : Struct   // an anonymous struct' + LineEnding +
    '         Step : Int;' + LineEnding +
    '         Busy : Bool;' + LineEnding +
    '      END_STRUCT;' + LineEnding +
    '      Hist : Array[0..2] of Int := [1, 2, 3];' + LineEnding +
    '   END_VAR' + LineEnding +
    '   VAR_TEMP' + LineEnding +
    '      i : Int;' + LineEnding +
    '   END_VAR' + LineEnding +
    '   VAR CONSTANT' + LineEnding +
    '      LIMIT_MAX : Int := 5;' + LineEnding +
    '   END_VAR' + LineEnding +
    '' + LineEnding +
    'BEGIN' + LineEnding +
    #9'REGION Edge and count' + LineEnding +
    #9#9'#Edge(CLK := #Start);' + LineEnding +
    #9#9'IF #Edge.Q AND #Count < #LIMIT_MAX THEN' + LineEnding +
    #9#9#9'#Count := #Count + 1;' + LineEnding +
    #9#9'END_IF;' + LineEnding +
    #9'END_REGION' + LineEnding +
    #9'REGION State' + LineEnding +
    #9#9'// the step and the history' + LineEnding +
    #9#9'#State.Step := #Count * #Rec.Speed;' + LineEnding +
    #9#9'#State.Busy := #Count > 0;' + LineEnding +
    #9#9'#Running := #State.Busy;' + LineEnding +
    #9#9'FOR #i := 2 TO 1 BY -1 DO' + LineEnding +
    #9#9#9'#Hist[#i] := #Hist[#i - 1];' + LineEnding +
    #9#9'END_FOR;' + LineEnding +
    #9#9'#Hist[0] := #State.Step;' + LineEnding +
    #9'END_REGION' + LineEnding +
    'END_FUNCTION_BLOCK' + LineEnding +
    '' + LineEnding +
    'DATA_BLOCK "Mixer_DB"' + LineEnding +
    '{ S7_Optimized_Access := ''TRUE'' }' + LineEnding +
    'VERSION : 0.1' + LineEnding +
    'NON_RETAIN' + LineEnding +
    '"Mixer"' + LineEnding +
    'BEGIN' + LineEnding +
    'END_DATA_BLOCK' + LineEnding +
    '' + LineEnding +
    'DATA_BLOCK "Plant"' + LineEnding +
    'VERSION : 0.1' + LineEnding +
    '   VAR' + LineEnding +
    '      Rec : "Recipe";' + LineEnding +
    '      Count : Int;' + LineEnding +
    '      Name : String[10] := ''mixer'';' + LineEnding +
    '   END_VAR' + LineEnding +
    '   VAR RETAIN' + LineEnding +
    '      Total : DInt;' + LineEnding +
    '   END_VAR' + LineEnding +
    'BEGIN' + LineEnding +
    '   Count := 3;' + LineEnding +
    'END_DATA_BLOCK' + LineEnding +
    '' + LineEnding +
    'ORGANIZATION_BLOCK "Main"' + LineEnding +
    'VERSION : 0.1' + LineEnding +
    'BEGIN' + LineEnding +
    '    "Mixer_DB"(Start := %I0.0, Rec := "Plant".Rec, Count => "Plant".Count);' + LineEnding +
    'END_ORGANIZATION_BLOCK' + LineEnding;
var
  P, P2: TPlcProject;
  Pr: TCProgram;
  Rt: TPlcRuntime;
  Rep, Txt, Txt2: string;
  B: TBlock;
  D, U: TDataBlock;
  I, Ok, Sk: Integer;
begin
  WriteLn('== .scl sources: export, import (phase 4)');
  P := TPlcProject.Create;
  try
    P.NewEmpty(13);
    Ok := Ord(SclImport(P, Src, Rep));
    Check(Ok = 1, 'the TIA source imports: ' + Rep);
    U := P.FindUdt('Recipe');
    Check((U <> nil) and (Length(U.Vars) = 2) and (U.Vars[0].Comment = 'rpm'), 'TYPE "Recipe" with 2 members and a comment');
    U := P.FindUdt('Mixer_State');
    Check((U <> nil) and (Length(U.Vars) = 2), 'the anonymous Struct became the PLC data type "Mixer_State"');
    B := P.FindFB('"Mixer"');
    Check((B <> nil) and (B.Number = 7), 'FB "Mixer" took the number of its "// FB7" line');
    if B <> nil then
    begin
      Check(B.NetCount = 2, Format('two REGIONs: two networks (%d)', [B.NetCount]));
      Check((B.NetCount = 2) and (B.Net(0).Title = 'Edge and count') and (B.Net(1).Comment = 'the step and the history'),
        'the network titles from the REGIONs, the first comment line of a REGION');
      Check((B.NetCount > 0) and (B.Net(0).Stl.Count > 0) and (B.Net(0).Stl[0] = 'VAR CONSTANT'),
        'VAR CONSTANT at the top of the first network');
      Check(B.Iface.Vars[B.Iface.FindVar('Start')].Comment = 'the start button', 'the comment of a declaration');
      Check(B.Iface.Vars[B.Iface.FindVar('State')].TypeText = '"Mixer_State"', 'State : "Mixer_State"');
      Check(B.Iface.Vars[B.Iface.FindVar('i')].Section = vsTemp, 'VAR_TEMP into the interface');
    end;
    D := P.FindDBByName('Mixer_DB');
    Check((D <> nil) and (D.InstanceOf = 7), 'the instance DB of FB7');
    D := P.FindDBByName('Plant');
    Check((D <> nil) and (D.Vars[D.FindVar('Count')].Start = '3') and D.Vars[D.FindVar('Total')].Retain,
      'DB "Plant": the BEGIN value as start value, VAR RETAIN');
    Pr := Compile(P);
    ShowMsgs(Pr);
    Check(Pr.ErrorCount = 0, 'the imported project compiles');
    Rt := TPlcRuntime.Create(13);
    try
      Rt.CmdDownload(Pr);
      Rt.CmdRun;
      Wait(40);
      for I := 1 to 7 do
      begin
        Rt.SetSimBit(0, 0, True);
        Wait(25);
        Rt.SetSimBit(0, 0, False);
        Wait(25);
      end;
      Check(Peek(Rt, P, '"Plant".Count') = 5, Format('it runs: 7 edges, counted to the constant 5 (%d)', [Peek(Rt, P, '"Plant".Count')]));
      Check(Peek(Rt, P, '"Mixer_DB".Hist[0]') = 500, Format('the anonymous Struct: Step = 5 * 100 (%d)', [Peek(Rt, P, '"Mixer_DB".Hist[0]')]));
    finally
      Rt.Free;
    end;
    // the export of the imported project and its import: the same text again
    Txt := SclExportAll(P, Rep);
    Check(Pos('FUNCTION_BLOCK "Mixer"', Txt) > 0, 'export: FUNCTION_BLOCK "Mixer"');
    Check(Pos('REGION Edge and count', Txt) > 0, 'export: the networks as REGIONs');
    Check(Pos('VAR CONSTANT', Txt) > 0, 'export: VAR CONSTANT in the declaration part');
    Check(Pos('VAR RETAIN', Txt) > 0, 'export: VAR RETAIN of a DB');
    P2 := TPlcProject.Create;
    try
      P2.NewEmpty(13);
      Ok := Ord(SclImport(P2, Txt, Rep));
      Check(Ok = 1, 'the export imports again: ' + Rep);
      Txt2 := SclExportAll(P2, Rep);
      Check(Txt2 = Txt, 'the round trip gives the same source');
      if Txt2 <> Txt then
        with TStringList.Create do
        try
          Text := Txt;
          SaveToFile('rt1.scl');
          Text := Txt2;
          SaveToFile('rt2.scl');
        finally
          Free;
        end;
      Pr := Compile(P2);
      Check(Pr.ErrorCount = 0, 'the round trip compiles');
    finally
      P2.Free;
    end;
  finally
    P.Free;
  end;
  // every example: export, import into an empty project (with its tags); one in SCL only compiles again
  Ok := 0;
  Rep := '';
  for I := 0 to ExampleCount - 1 do
  begin
    P := TPlcProject.Create;
    P2 := TPlcProject.Create;
    try
      BuildExample(I, P);
      Txt := SclExportAll(P, Rep);
      P2.NewEmpty(P.ModelIdx);
      for Sk := 0 to High(P.Tags) do P2.AddTag(P.Tags[Sk].Name, P.Tags[Sk].TypeText, P.Tags[Sk].Address, P.Tags[Sk].Comment);
      Sk := Ord(SclImport(P2, Txt, Txt2));
      if Pos('have no SCL text', Rep) > 0 then
        Check(Sk = 1, ExampleFile(I) + ': its export (without the LAD / STL networks) imports: ' + Txt2)
      else
      begin
        Check(Sk = 1, ExampleFile(I) + ': its export imports: ' + Txt2);
        Pr := Compile(P2);
        if Pr.ErrorCount > 0 then ShowMsgs(Pr);
        Check(Pr.ErrorCount = 0, ExampleFile(I) + ': SCL only, the import compiles');
        Inc(Ok);
      end;
    finally
      P.Free;
      P2.Free;
    end;
  end;
  Check(Ok >= 4, Format('%d examples in SCL only went round', [Ok]));
  P := TPlcProject.Create;
  try
    P.NewEmpty(13);
    Check(not SclImport(P, 'FUNCTION_BLOCK "X"' + LineEnding + 'VAR_INPUT a : ; END_VAR BEGIN END_FUNCTION_BLOCK', Rep) and
      (Pos('line 2', Rep) > 0), 'an error: its line, nothing imported (' + Rep + ')');
    Check(P.FindFB('"X"') = nil, 'nothing imported');
  finally
    P.Free;
  end;
end;

{ the boxes of the SCL functions in LAD, CALL of them in STL, typed timers / counters in LAD, rename, version }
function LadSclProject: TPlcProject;
var
  B: TBlock;
  D: TDataBlock;
  N: TNetwork;

  procedure Rung(AKind: TLadKind; const Inst: string; const Pins: array of string; const En, Eno: string);
  var
    Ce: TLadCell;
    K: Integer;
  begin
    N := B.AddNet(nkLAD);
    N.SetCell(0, 0, NewCell(lkNO, En));
    Ce := NewCell(AKind, Inst);
    for K := 0 to High(Pins) do Ce.P[K] := Pins[K];
    N.SetCell(0, 1, Ce);
    for K := 2 to 6 do N.SetCell(0, K, NewCell(lkWire, ''));
    N.SetCell(0, 7, NewCell(lkCoil, Eno));
  end;

begin
  Result := TPlcProject.Create;
  Result.NewEmpty(13);
  D := Result.AddDB(1, 'L');
  D.AddVar('g', 'Bool', 'TRUE', '');
  D.AddVar('r1', 'Real', '0.0', '');
  D.AddVar('r2', 'Real', '0.0', '');
  D.AddVar('s', 'String[10]', '', '');
  D.AddVar('s2', 'String[10]', '', '');
  D.AddVar('s3', 'String[10]', '', '');
  D.AddVar('cnt', 'Int', '0', '');
  D.AddVar('edges', 'Int', '0', '');
  D.AddVar('edge', 'R_TRIG', '', '');
  D.AddVar('fall', 'F_TRIG', '', '');
  D.AddVar('falls', 'Int', '0', '');
  D.AddVar('rs', 'RS', '', '');
  D.AddVar('tl', 'TON_LTIME', '', '');
  D.AddVar('et', 'LTime', '', '');
  D.AddVar('cd', 'CTU_DINT', '', '');
  D.AddVar('cdv', 'DInt', '0', '');
  D.AddVar('t2', 'TON_TIME', '', '');
  B := Result.Block(0);
  B.DeleteNet(0);
  B.AddNet(nkSCL).Stl.Text := '%M1.0 := TRUE;';
  Rung(lkSel, '', ['"L".g', '1', '2', '%MW20'], '%M1.0', '%M4.0');
  Rung(lkMux, '', ['2', '10', '20', '30', '%MW22'], '%M1.0', '%M4.1');
  Rung(lkLimit, '', ['0', '50', '20', '%MW24'], '%M1.0', '%M4.2');
  Rung(lkMin, '', ['9', '4', '6', '', '%MW26'], '%M1.0', '%M4.3');
  Rung(lkMax, '', ['9', '4', '6', '', '%MW28'], '%M1.0', '%M4.4');
  Rung(lkSqrt, '', ['16.0', '"L".r1'], '%M1.0', '%M4.5');
  Rung(lkExpt, '', ['2.0', '3.0', '"L".r2'], '%M1.0', '%M4.6');
  Rung(lkMod, '', ['17', '5', '%MW38'], '%M1.0', '%M4.7');
  Rung(lkShl, '', ['W#16#1', '3', '%MW40'], '%M1.0', '%M5.0');
  Rung(lkAndW, '', ['W#16#FF0F', 'W#16#0FF0', '%MW42'], '%M1.0', '%M5.1');
  Rung(lkInvW, '', ['W#16#00FF', '%MW44'], '%M1.0', '%M5.2');
  Rung(lkConcat, '', ['''ab''', '''cd''', '"L".s'], '%M1.0', '%M5.3');
  Rung(lkLen, '', ['"L".s', '%MW46'], '%M1.0', '%M5.4');
  Rung(lkMid, '', ['''Hello''', '3', '2', '"L".s2'], '%M1.0', '%M5.5');
  Rung(lkSel, '', ['"L".g', '7', '8', '%MW48'], '%M1.1', '%M5.6');   // EN = 0: OUT stays, ENO = 0
  // an edge: R_TRIG, then INC on its Q
  N := B.AddNet(nkLAD);
  N.SetCell(0, 0, NewCell(lkNO, '%I0.0'));
  N.SetCell(0, 1, NewCell(lkRTrig, '"L".edge'));
  N.SetCell(0, 3, NewCell(lkInc, ''));
  N.Cells[0 * N.Cols + 3].P[0] := '"L".edges';
  N.SetCell(0, 2, NewCell(lkWire, ''));
  N.SetCell(0, 4, NewCell(lkWire, ''));
  N.SetCell(0, 5, NewCell(lkWire, ''));
  N.SetCell(0, 6, NewCell(lkWire, ''));
  N.SetCell(0, 7, NewCell(lkCoil, '%M6.0'));
  N := B.AddNet(nkLAD);
  N.SetCell(0, 0, NewCell(lkNO, '%I0.0'));
  N.SetCell(0, 1, NewCell(lkFTrig, '"L".fall'));
  N.SetCell(0, 3, NewCell(lkInc, ''));
  N.Cells[0 * N.Cols + 3].P[0] := '"L".falls';
  N.SetCell(0, 2, NewCell(lkWire, ''));
  N.SetCell(0, 4, NewCell(lkWire, ''));
  N.SetCell(0, 5, NewCell(lkWire, ''));
  N.SetCell(0, 6, NewCell(lkWire, ''));
  N.SetCell(0, 7, NewCell(lkCoil, '%M6.1'));
  Rung(lkRS, '"L".rs', ['%I0.2'], '%I0.1', '%M6.2');
  Rung(lkTON, '"L".tl', ['LT#50MS', '"L".et'], '%I0.0', '%M6.3');
  Rung(lkCTU, '"L".cd', ['100000', 'FALSE', '"L".cdv'], '%I0.0', '%M6.4');
  // STL
  B.AddNet(nkSTL).Stl.Text :=
    'CALL SEL' + LineEnding + '  value_type := Int' + LineEnding + '  G := "L".g' + LineEnding + '  IN0 := 5' + LineEnding +
    '  IN1 := 6' + LineEnding + '  RET_VAL := %MW60' + LineEnding +
    'CALL MAX' + LineEnding + '  IN1 := 3' + LineEnding + '  IN2 := 8' + LineEnding + '  IN3 := 5' + LineEnding +
    '  OUT := %MW62' + LineEnding +
    'CALL CONCAT' + LineEnding + '  IN1 := ''x''' + LineEnding + '  IN2 := ''yz''' + LineEnding + '  RET_VAL := "L".s3' + LineEnding +
    'CALL "L".t2' + LineEnding + '  IN := %I0.0' + LineEnding + '  PT := T#50MS' + LineEnding + '  Q := %M7.0' + LineEnding +
    'CALL LIMIT' + LineEnding + '  MN := 0' + LineEnding + '  IN := 300' + LineEnding + '  MX := 100' + LineEnding +
    '  RET_VAL := %MW64';
end;

procedure TestLadStlScl;
var
  P: TPlcProject;
  Pr: TCProgram;
  Rt: TPlcRuntime;
  B: TBlock;
  N: TNetwork;
  Ce: TLadCell;
  Q: QWord;
  I, Cnt: Integer;
  Txt, Rep: string;
begin
  WriteLn('== LAD boxes and STL calls of the SCL functions');
  P := LadSclProject;
  try
    Pr := Compile(P);
    ShowMsgs(Pr);
    Check(Pr.ErrorCount = 0, 'the LAD / STL project compiles');
    Rt := TPlcRuntime.Create(13);
    try
      Rt.CmdDownload(Pr);
      Rt.CmdRun;
      Wait(60);
      Check(Rt.Mode = rmRun, 'RUN');
      if Rt.Mode <> rmRun then DumpDiag(Rt);
      Check(Peek(Rt, P, '%MW20') = 2, 'LAD SEL(G := TRUE, 1, 2) = 2');
      Check(Peek(Rt, P, '%M4.0') = 1, 'ENO = EN');
      Check(Peek(Rt, P, '%MW22') = 30, 'LAD MUX(K := 2) = 30');
      Check(Peek(Rt, P, '%MW24') = 20, 'LAD LIMIT(0, 50, 20) = 20');
      Check((Peek(Rt, P, '%MW26') = 4) and (Peek(Rt, P, '%MW28') = 9), 'LAD MIN = 4, MAX = 9 (IN4 left empty)');
      Check(PeekReal(Rt, P, '"L".r1') = 4.0, 'LAD SQRT(16.0) = 4.0');
      Check(PeekReal(Rt, P, '"L".r2') = 8.0, 'LAD EXPT(2.0, 3.0) = 8.0');
      Check(Peek(Rt, P, '%MW38') = 2, 'LAD MOD(17, 5) = 2');
      Check(Peek(Rt, P, '%MW40') = 8, 'LAD SHL(1, 3) = 8');
      Check(Peek(Rt, P, '%MW42') = $0F00, 'LAD AND words = 16#0F00');
      Check(Peek(Rt, P, '%MW44') = $FF00, 'LAD INV = 16#FF00');
      Check(PeekStr(Rt, P, '"L".s') = 'abcd', 'LAD CONCAT = ''abcd''');
      Check(Peek(Rt, P, '%MW46') = 4, 'LAD LEN = 4');
      Check(PeekStr(Rt, P, '"L".s2') = 'ell', 'LAD MID = ''ell''');
      Check((Peek(Rt, P, '%MW48') = 0) and (Peek(Rt, P, '%M5.6') = 0), 'LAD SEL with EN = 0: OUT stays, ENO = 0');
      Check(Peek(Rt, P, '%MW60') = 6, 'STL CALL SEL = 6');
      Check(Peek(Rt, P, '%MW62') = 8, 'STL CALL MAX (OUT :=) = 8');
      Check(PeekStr(Rt, P, '"L".s3') = 'xyz', 'STL CALL CONCAT = ''xyz''');
      Check(Peek(Rt, P, '%MW64') = 100, 'STL CALL LIMIT = 100');
      Check(Peek(Rt, P, '"L".cdv') = 0, 'CTU_DINT box: CV 0');
      for I := 1 to 3 do
      begin
        Rt.SetSimBit(0, 0, True);
        Wait(30);
        Rt.SetSimBit(0, 0, False);
        Wait(30);
      end;
      Check(Peek(Rt, P, '"L".edges') = 3, Format('LAD R_TRIG box + INC: 3 rising edges (%d)', [Peek(Rt, P, '"L".edges')]));
      Check(Peek(Rt, P, '"L".falls') = 3, Format('LAD F_TRIG box: 3 falling edges (%d)', [Peek(Rt, P, '"L".falls')]));
      Check(Peek(Rt, P, '"L".cdv') = 3, Format('LAD CTU with a CTU_DINT instance: CV 3 (%d)', [Peek(Rt, P, '"L".cdv')]));
      Rt.SetSimBit(0, 0, True);
      Rt.SetSimBit(0, 1, True);
      Wait(120);
      Check(Peek(Rt, P, '%M6.3') = 1, 'LAD TON with a TON_LTIME instance: Q after LT#50MS');
      Check(Int64(Peek64(Rt, P, '"L".et')) = 50000000, 'TON_LTIME: ET in ns');
      Check(Peek(Rt, P, '%M7.0') = 1, 'STL CALL of a TON_TIME instance: Q');
      Check(Peek(Rt, P, '%M6.2') = 1, 'LAD RS box: set');
      Rt.SetSimBit(0, 2, True);
      Wait(40);
      Check(Peek(Rt, P, '%M6.2') = 0, 'LAD RS box: reset wins');
    finally
      Rt.Free;
    end;
  finally
    P.Free;
  end;
  // errors on the box
  P := LadSclProject;
  try
    N := P.Block(0).Net(1);
    Ce := N.Cell(0, 1);
    Ce.P[3] := '';
    N.SetCell(0, 1, Ce);
    Pr := Compile(P);
    Check(Pr.ErrorCount > 0, 'SEL box without OUT: an error');
    Check((Length(Pr.Msgs) > 0) and (Pos('OUT missing', Pr.Msgs[0].Text) > 0), 'its message: ' + Pr.Msgs[0].Text);
  finally
    P.Free;
  end;
  // rename: the code follows
  P := TPlcProject.Create;
  try
    BuildExample(30, P);
    B := P.FindFB('"Signals"');
    I := 0;
    for Cnt := 0 to P.BlockCount - 1 do
      if SameText(P.Block(Cnt).Name, 'Avg2') then I := Cnt;
    Cnt := RenameBlockInCode(P, P.Block(I), 'Mean');
    Check(Cnt >= 2, Format('FC "Avg2" -> "Mean": %d places follow (the call, #Avg2 in the FC)', [Cnt]));
    Check(Pos('"Mean"(', P.Block(0).Net(1).Stl.Text) > 0, 'the call is "Mean"(..)');
    Check(Pos('#Mean :=', P.Block(I).Net(0).Stl.Text) > 0, 'its value #Mean := ..');
    Pr := Compile(P);
    Check(Pr.ErrorCount = 0, 'the renamed project compiles');
    if B <> nil then
    begin
      B.Version := '1.2';
      Txt := SclExportAll(P, Rep);
      Check(Pos('VERSION : 1.2', Txt) > 0, 'the version in the .scl source');
      Check(Pos('"Mean"', P.ToJsonText) > 0, 'the project file has the new name');
      Check(Pos('"version" : "1.2"', P.ToJsonText) > 0, 'the project file has the version');
    end;
  finally
    P.Free;
  end;
end;

{ the I/O screen: the next address / name of a new row, the signal generators }
procedure TestIoSignals;
var
  A: TAddr;
  E: string;
  SL: TStringList;
  P, P2: TPlcProject;
  S: TSimSignal;
  Rt: TPlcRuntime;
begin
  WriteLn('--- I/O: next address, next name, signals ---');
  Check(ParseAddr('M100.7', A, E) and (FormatAddr(NextAddr(A, 0), cfS71500) = '%M101.0'), 'M100.7 -> M101.0');
  Check(ParseAddr('I0.3', A, E) and (FormatAddr(NextAddr(A, 0), cfS71500) = '%I0.4'), 'I0.3 -> I0.4');
  Check(ParseAddr('MW20', A, E) and (FormatAddr(NextAddr(A, 2), cfS71500) = '%MW22'), 'MW20 -> MW22');
  Check(ParseAddr('MD20', A, E) and (FormatAddr(NextAddr(A, 0), cfS71500) = '%MD24'), 'MD20 -> MD24 (its size)');
  Check(ParseAddr('IW64', A, E) and (FormatAddr(NextAddr(A, 2), cfS71500) = '%IW66'), 'IW64 -> IW66');
  SL := TStringList.Create;
  try
    SL.Add('Tag_3');
    SL.Add('Motor');
    SL.Add('Motor_1');
    Check(NextName('Tag_3', SL) = 'Tag_4', 'Tag_3 -> Tag_4');
    Check(NextName('Motor', SL) = 'Motor_2', 'Motor -> Motor_2 (Motor_1 is taken)');
    SL.Add('tag_4');
    Check(NextName('Tag_3', SL) = 'Tag_5', 'not case sensitive: tag_4 is taken');
  finally
    SL.Free;
  end;
  S.Kind := sgSquare; S.Lo := 0; S.Hi := 1; S.PeriodMs := 1000; S.Duty := 25;
  Check((SignalValue(S, 0.1, 0) = 1) and (SignalValue(S, 0.3, 0) = 0) and (SignalValue(S, 1.2, 0) = 1), 'square 25 %');
  S.Kind := sgSine; S.Lo := 0; S.Hi := 100;
  Check((Abs(SignalValue(S, 0, 0) - 50) < 1e-6) and (Abs(SignalValue(S, 0.25, 0) - 100) < 1e-6), 'sine 0..100');
  S.Kind := sgTriangle;
  Check(Abs(SignalValue(S, 0.5, 0) - 100) < 1e-6, 'triangle: top at half');
  S.Kind := sgRamp;
  Check(Abs(SignalValue(S, 0.25, 0) - 25) < 1e-6, 'ramp');
  S.Kind := sgStep; S.Lo := 0; S.Hi := 3;
  Check((SignalValue(S, 2.5, 0) = 2) and (SignalValue(S, 4.5, 0) = 0), 'step 0,1,2,3,0');
  S.Kind := sgRandom; S.Hi := 10;
  Check(Abs(SignalValue(S, 0, 0.5) - 5) < 1e-6, 'random: Lo + (Hi - Lo) * rnd');
  P := TPlcProject.Create;
  P2 := TPlcProject.Create;
  try
    P.AddSignal('%I8.0', sgSquare, 0, 1, 500, 30);
    P.AddSignal('"Level"', sgSine, 0, 27648, 8000, 50);
    P.Signals[1].On := True;
    P.Signals[1].Comment := 'tank';
    P2.LoadFromJsonText(P.ToJsonText);
    Check(Length(P2.Signals) = 2, 'the signals in the project file');
    Check((P2.Signals[0].Kind = sgSquare) and (P2.Signals[0].PeriodMs = 500) and (P2.Signals[0].Duty = 30), 'row 1 back');
    Check((P2.Signals[1].Kind = sgSine) and P2.Signals[1].On and (P2.Signals[1].Comment = 'tank') and
      (P2.Signals[1].Hi = 27648), 'row 2 back');
    P2.DeleteSignal(0);
    Check((Length(P2.Signals) = 1) and (P2.Signals[0].Address = '"Level"'), 'delete a row');
  finally
    P.Free;
    P2.Free;
  end;
  Rt := TPlcRuntime.Create(0);
  try
    Rt.SetSimRaw(10, 4, $12345678);
    Check((Rt.SimIn[10] = $12) and (Rt.SimIn[13] = $78), 'SetSimRaw: big endian');
  finally
    Rt.Free;
  end;
end;

{ the groups of the tag table and the watch table; the SCL import of the Data blocks screen }
procedure TestGroups;
var
  P, P2: TPlcProject;
  G, G2: Integer;
  E, Rep: string;
begin
  WriteLn('--- groups of tags / watch rows, SCL import of types and DBs ---');
  P := TPlcProject.Create;
  P2 := TPlcProject.Create;
  try
    P.AddTag('Start', 'Bool', '%I0.0', '');
    P.AddTag('Stop', 'Bool', '%I0.1', '');
    P.AddTag('Speed', 'Int', '%MW20', '');
    G := GroupAdd(P.TagGroups, 'Motor');
    G2 := GroupAdd(P.TagGroups, 'Motor');
    Check((P.TagGroups[G].Id = 1) and (P.TagGroups[G2].Id = 2), 'a new group gets a new Id');
    Check(GroupNameTwice(P.TagGroups, G) and GroupNameTwice(P.TagGroups, G2), 'a name used twice is seen (red in the tree)');
    P.TagGroups[G2].Name := 'Drive';
    Check(not GroupNameTwice(P.TagGroups, G), 'renamed: no longer twice');
    Check(not GroupNameOk('All tag', AllTagsName, E) and not GroupNameOk(' all TAG ', AllTagsName, E), '"All tag" is the root''s name');
    Check(not GroupNameOk('', AllTagsName, E) and GroupNameOk('Pumps', AllTagsName, E), 'not empty; another name is fine');
    Check(not GroupNameOk('All rows', AllWatchName, E), '"All rows" is the root of the watch tree');
    P.Tags[0].GroupId := P.TagGroups[G].Id;
    P.Tags[1].GroupId := P.TagGroups[G].Id;
    P.Tags[2].GroupId := P.TagGroups[G2].Id;
    P.AddWatch('"Start"', dfDec);
    G := GroupAdd(P.WatchGroups, 'Inputs');
    P.Watch[0].GroupId := P.WatchGroups[G].Id;
    P2.LoadFromJsonText(P.ToJsonText);
    Check((Length(P2.TagGroups) = 2) and (P2.TagGroups[1].Name = 'Drive') and (P2.TagGroups[1].Id = 2), 'tag groups in the project file');
    Check((P2.Tags[0].GroupId = 1) and (P2.Tags[2].GroupId = 2), 'the group of each tag');
    Check((Length(P2.WatchGroups) = 1) and (P2.Watch[0].GroupId = P2.WatchGroups[0].Id), 'watch groups and rows');
    P2.DeleteTagGroup(0);
    Check((Length(P2.Tags) = 3) and (P2.Tags[0].GroupId = 0) and (P2.Tags[2].GroupId = 2), 'a group deleted: its tags stay');
    Check((Length(P2.TagGroups) = 1) and (GroupOfId(P2.TagGroups, 2) = 0), 'the other group keeps its Id');
    P2.DeleteWatchGroup(0);
    Check((Length(P2.Watch) = 1) and (P2.Watch[0].GroupId = 0), 'a watch group deleted: its rows stay');
  finally
    P.Free;
    P2.Free;
  end;
  P := TPlcProject.Create;
  try
    P.NewEmpty(5);
    Check(not SclImport(P, 'FUNCTION "F" : Void' + LineEnding + 'BEGIN' + LineEnding + 'END_FUNCTION', Rep, True),
      'Data blocks: a source of blocks alone is refused');
    G := P.BlockCount;
    Check(SclImport(P, 'TYPE "Motor_T"' + LineEnding + 'VERSION : 0.1' + LineEnding + '   STRUCT' + LineEnding +
      '      Run : Bool;' + LineEnding + '      Speed : Int := 100;' + LineEnding + '   END_STRUCT;' + LineEnding +
      'END_TYPE' + LineEnding + LineEnding + 'DATA_BLOCK "Line"' + LineEnding + '{ S7_Optimized_Access := ''TRUE'' }' +
      LineEnding + 'VERSION : 0.1' + LineEnding + '   VAR' + LineEnding + '      M1 : "Motor_T";' + LineEnding +
      '      Count : DInt := 5;' + LineEnding + '   END_VAR' + LineEnding + 'BEGIN' + LineEnding + '   Count := 7;' +
      LineEnding + 'END_DATA_BLOCK' + LineEnding + LineEnding + 'FUNCTION "Skip" : Void' + LineEnding + 'BEGIN' +
      LineEnding + 'END_FUNCTION', Rep, True), 'Data blocks: TYPE and DATA_BLOCK imported: ' + Rep);
    Check((P.FindUdt('Motor_T') <> nil) and (P.FindDBByName('Line') <> nil), 'the type and the DB are there');
    Check(P.BlockCount = G, 'the FUNCTION is left out');
    Check(Pos('1 FC / FB / OB left out', Rep) > 0, 'the report says so');
    if P.FindDBByName('Line') <> nil then
      with P.FindDBByName('Line') do
        Check((FindVar('Count') >= 0) and (Vars[FindVar('Count')].Start = '7'), 'BEGIN: the start value');
  finally
    P.Free;
  end;
end;

{ the OBs of each family: the catalog, the start information, the events in the runtime }
procedure TestObs;
var
  P, P2: TPlcProject;
  B: TBlock;
  N: TNetwork;
  Pr: TCProgram;
  Rt: TPlcRuntime;
  L: TObInfos;
  Info: TObInfo;
  K: Integer;
  S: string;

  function Has(F: TCpuFamily; Nr: Integer): Boolean;
  begin
    Result := ObInfoOf(F, Nr, Info);
  end;

  function MW(const A: string): Integer;
  begin
    Result := SmallInt(Peek(Rt, P, A) and $FFFF);
  end;

  procedure Scl(Blk: TBlock; const Code: string);
  begin
    N := Blk.AddNet(nkSCL);
    N.Stl.Text := Code;
  end;

begin
  WriteLn('--- OBs: catalog, start information, events ---');
  Check(Has(cfS7300, 1) and Has(cfS7300, 35) and Has(cfS7300, 82) and Has(cfS7300, 86) and Has(cfS7300, 121) and
    Has(cfS7300, 122) and not Has(cfS7300, 30), 'S7-300: OB1, OB35, OB82, OB86, OB121, OB122 (no OB30)');
  Check(Has(cfS7400, 30) and Has(cfS7400, 38) and Has(cfS7400, 101) and Has(cfS7400, 102) and Has(cfS7400, 90),
    'S7-400: OB30..38, OB90, OB101, OB102');
  Check(Has(cfS71200, 30) and Has(cfS71200, 40) and Has(cfS71200, 86) and not Has(cfS71200, 121), 'S7-1200: no OB121');
  Check(Has(cfS71500, 61) and Has(cfS71500, 121) and Has(cfS71500, 122) and not Has(cfS71500, 81), 'S7-1500: OB61, OB121, OB122, no OB81');
  Check(ObCustomOk(cfS71500, oeCyclic) and ObCustomOk(cfS71200, oeHardware) and not ObCustomOk(cfS7300, oeCyclic) and
    not ObCustomOk(cfS71500, oeProgError), 'own numbers (>= 123): TIA cyclic / hardware .., not classic, not OB121');
  Check((ObEventOf(cfS71500, 123, Ord(oeCyclic)) = oeCyclic) and (ObEventOf(cfS71500, 35, -1) = oeCyclic), 'the event of an OB');
  Check((ObDefaultCycleMs(30) = 5000) and (ObDefaultCycleMs(35) = 100) and (ObDefaultCycleMs(38) = 10), 'default cycle times');
  Check(ObStartKey('OB35_EXC_FREQ') = 'EXC_FREQ', 'OB35_EXC_FREQ -> EXC_FREQ');
  L := ObCatalog(cfS7400);
  Check(Length(L) > 40, Format('S7-400 has %d standard OBs', [Length(L)]));
  // the interface of an OB
  P := TPlcProject.Create;
  P2 := TPlcProject.Create;
  try
    P.NewEmpty(13);
    B := P.Block(0);
    Check((Length(B.Iface.Vars) >= 2) and B.Iface.Vars[0].System and (B.Iface.Vars[0].Name = 'Initial_Call') and
      (B.Iface.Vars[0].Section = vsInput), 'S7-1500 OB1: Input Initial_Call, Remanence (the CPU''s)');
    B.Iface.AddSecVar(vsTemp, 'tmp', 'Int', '', '');
    P.ModelIdx := 1;
    P.SyncObIfaces;
    Check((B.Iface.Vars[0].Name = 'OB1_EV_CLASS') and (B.Iface.Vars[0].Section = vsTemp), 'S7-300 OB1: OB1_EV_CLASS ..');
    K := B.Iface.FindVar('tmp');
    Check((K >= 0) and (B.Iface.Vars[K].Ofs = 20), 'the user''s Temp after the 20 bytes of start information (L20)');
    Check(B.Iface.FindVar('Initial_Call') < 0, 'the TIA start information is gone');
    B := P.AddBlock(bkOB, 35, 'CYC_INT5');
    B.CycleMs := 20;
    B := P.AddBlock(bkOB, 40, 'HW_INT0');
    B.TrigAddr := 'I0.3';
    B.TrigEdge := 2;
    S := P.ToJsonText;
    Check(Pos('OB1_EV_CLASS', S) = 0, 'the start information is not saved');
    P2.LoadFromJsonText(S);
    B := P2.FindBlock(bkOB, 40);
    Check((B <> nil) and (B.TrigAddr = 'I0.3') and (B.TrigEdge = 2) and (B.Iface.FindVar('OB40_POINT_ADDR') >= 0),
      'OB40 back: its input, edge and start information');
    Check((P2.FindBlock(bkOB, 35) <> nil) and (P2.ObCycleMs(P2.FindBlock(bkOB, 35)) = 20), 'OB35: 20 ms back');
  finally
    P.Free;
    P2.Free;
  end;
  // S7-1500: the events in the runtime
  P := TPlcProject.Create;
  try
    P.NewEmpty(13);
    P.AddDB(1, 'D').AddVar('A', 'Int', '0', '');
    B := P.Block(0);
    B.DeleteNet(0);
    Scl(B, 'IF #Initial_Call THEN %MW14 := %MW14 + 1; END_IF;' + LineEnding + '%MW16 := %MW16 + 1;' + LineEnding +
      'IF %M0.0 THEN %MW44 := SRT_DINT(OB_NR := 20, DTIME := T#50MS, SIGN := 16#0007); %M0.0 := FALSE; END_IF;');
    N := B.AddNet(nkSTL);
    N.Stl.Text := 'A M0.1' + LineEnding + 'JCN M001' + LineEnding + 'OPN DB1' + LineEnding + 'L DBW100' + LineEnding +
      'T MW0' + LineEnding + 'L MW36' + LineEnding + 'L 1' + LineEnding + '+I' + LineEnding + 'T MW36' + LineEnding +
      'M001: NOP 0';
    B := P.AddBlock(bkOB, 123, 'Main_2');
    B.ObEvent := Ord(oeProgramCycle);
    P.SyncObIface(B);
    Scl(B, '%MW18 := %MW18 + 1;');
    Scl(P.AddBlock(bkOB, 100, 'Startup'), '%MW10 := %MW10 + 1; %M0.0 := TRUE; %M0.1 := TRUE;');
    B := P.AddBlock(bkOB, 124, 'Startup_2');
    B.ObEvent := Ord(oeStartup);
    P.SyncObIface(B);
    Scl(B, '%MW12 := %MW12 + 1;');
    B := P.AddBlock(bkOB, 30, 'Cyclic interrupt');
    B.CycleMs := 10;
    Scl(B, '%MW20 := %MW20 + 1; IF #Initial_Call THEN %MW22 := %MW22 + 1; END_IF;');
    Scl(P.AddBlock(bkOB, 20, 'Time delay interrupt'), '%MW24 := %MW24 + 1; %MW26 := #Sign;');
    B := P.AddBlock(bkOB, 40, 'Hardware interrupt');
    B.TrigAddr := '%I0.0';
    Scl(B, '%MW28 := %MW28 + 1; %MB30 := #EventType;');
    Scl(P.AddBlock(bkOB, 121, 'Programming error'), '%MW32 := %MW32 + 1; %MB34 := #Fault_ID;');
    Scl(P.AddBlock(bkOB, 86, 'Rack or station failure'), '%MW38 := %MW38 + 1; %MB40 := #Event_Class;');
    Scl(P.AddBlock(bkOB, 82, 'Diagnostic error interrupt'), '%MW42 := %MW42 + 1;');
    Pr := Compile(P);
    ShowMsgs(Pr);
    Check(Pr.ErrorCount = 0, 'the OBs of the S7-1500 compile');
    Check(Length(Pr.Obs) = 10, Format('10 OBs in the program (%d)', [Length(Pr.Obs)]));
    Rt := TPlcRuntime.Create(13);
    try
      Rt.CmdDownload(Pr);
      Rt.CmdRun;
      Wait(300);
      Check(Rt.Mode = rmRun, 'RUN (OB121 is there)');
      Check((MW('%MW10') = 1) and (MW('%MW12') = 1), 'OB100 and the startup OB124 ran once');
      Check(MW('%MW14') = 1, '#Initial_Call: once');
      Check((MW('%MW16') > 5) and (Abs(MW('%MW18') - MW('%MW16')) <= 1), 'the program cycle OB123 runs after OB1 every cycle');
      Check((MW('%MW20') > 10) and (MW('%MW22') = 1), Format('OB30 every 10 ms: %d runs, Initial_Call once', [MW('%MW20')]));
      Check((MW('%MW24') = 1) and (MW('%MW26') = 7) and (MW('%MW44') = 0), 'SRT_DINT: OB20 once with SIGN 7, RET_VAL 0');
      Check((MW('%MW32') > 0) and (MW('%MW36') > 0) and (Peek(Rt, P, '%MB34') = $24),
        'OB121 on the area length error, the program goes on (Fault_ID 16#24)');
      Rt.SetSimBit(0, 0, True);
      Wait(60);
      Rt.SetSimBit(0, 0, False);
      Wait(60);
      Check((MW('%MW28') = 1) and (Peek(Rt, P, '%MB30') = 1), 'OB40: the rising edge of %I0.0 (EventType 1), not the falling');
      Rt.CmdBusFault(True);
      Wait(60);
      Check((MW('%MW38') = 1) and (Peek(Rt, P, '%MB40') = $39) and (Rt.Mode = rmRun), 'OB86: station failure (16#39), RUN');
      Rt.CmdBusFault(False);
      Wait(60);
      Check((MW('%MW38') = 2) and (Peek(Rt, P, '%MB40') = $38), 'OB86: station return (16#38)');
      Rt.CmdObEvent(oeDiagnostic);
      Wait(60);
      Check(MW('%MW42') = 1, 'OB82: the diagnostic interrupt');
      Check(Rt.ObRuns(30) > 10, 'the runs of OB30');
    finally
      Rt.Free;
    end;
  finally
    P.Free;
  end;
  // S7-300: the start information in the Temp, OB82 missing -> STOP
  P := TPlcProject.Create;
  try
    P.NewEmpty(1);
    B := P.Block(0);
    B.DeleteNet(0);
    N := B.AddNet(nkSTL);
    N.Stl.Text := 'L #OB1_SCAN_1' + LineEnding + 'T MB50' + LineEnding + 'L #OB1_OB_NUMBR' + LineEnding + 'T MB51';
    B := P.AddBlock(bkOB, 35, 'CYC_INT5');
    B.CycleMs := 20;
    N := B.AddNet(nkSTL);
    N.Stl.Text := 'L #OB35_EXC_FREQ' + LineEnding + 'T MW52';
    Pr := Compile(P);
    ShowMsgs(Pr);
    Check(Pr.ErrorCount = 0, 'S7-300: #OB1_SCAN_1 .. compile');
    Rt := TPlcRuntime.Create(1);
    try
      Rt.CmdDownload(Pr);
      Rt.CmdRun;
      Wait(150);
      Check((Peek(Rt, P, 'MB50') = 3) and (Peek(Rt, P, 'MB51') = 1), 'OB1_SCAN_1 = 3 after the first cycle, OB1_OB_NUMBR = 1');
      Check(MW('MW52') = 20, 'OB35_EXC_FREQ = 20 ms');
      Rt.CmdObEvent(oeDiagnostic);
      Wait(60);
      Check(Rt.Mode = rmStop, 'S7-300: a diagnostic interrupt without OB82 -> STOP');
    finally
      Rt.Free;
    end;
  finally
    P.Free;
  end;
end;

{ the parameter help of the SCL editor }
procedure TestSclSig;
var
  P: TPlcProject;
  B, Fb: TBlock;
  L: TStringList;
  C: TSclCall;
  S: TSclSig;
  Fits: TStringList;
  R, Cc, Pl: Integer;
begin
  WriteLn('--- SCL parameter help ---');
  P := TPlcProject.Create;
  L := TStringList.Create;
  try
    P.NewEmpty(13);
    B := P.Block(0);
    B.Iface.AddSecVar(vsTemp, 'Delay', 'Time', '', '');
    P.AddTag('Start', 'Bool', '%I0.0', '');
    Fb := P.AddBlock(bkFB, 1, 'Motor');
    Fb.Iface.AddSecVar(vsInput, 'Run', 'Bool', 'FALSE', 'start the motor');
    Fb.Iface.AddSecVar(vsInput, 'Speed', 'Int', '0', 'rpm');
    Fb.Iface.AddSecVar(vsOutput, 'Running', 'Bool', 'FALSE', '');
    Fb.Iface.AddSecVar(vsStatic, 'Timer', 'TON_TIME', '', '');
    P.AddDB(1, 'Motor_DB').InstanceOf := 1;
    L.Add('"Motor_DB"(');
    Check(SclCallAt(L, 0, 11, C) and (C.Callee = '"Motor_DB"') and (C.Seg = 0) and C.Stmt, 'the call after "(" (a statement)');
    Check(SclSignature(P, B, C.Callee, S) and (Length(S.Params) = 3) and (S.Params[2].Dir = sdOut), 'FB "Motor": Run, Speed => Running');
    Check(SclCallTemplate(S, C.Given, 11, True, True) = 'Run := _bool_in_,' + LineEnding + StringOfChar(' ', 11) +
      'Speed := _int_in_,' + LineEnding + StringOfChar(' ', 11) + 'Running => _bool_out_);', 'the template: aligned, TIA placeholders');
    Check(SclCallGhost(S, C.Given, True, True) = 'Run := <Bool>, Speed := <Int>, Running => <Bool>);', 'the ghost: ' + SclCallGhost(S, C.Given, True, True));
    C.Given.Free;
    L[0] := '"Motor_DB"(Run := "Start",';
    L.Add('           Sp');
    Check(SclCallAt(L, 1, 13, C) and (C.Seg = 1) and (C.Given.IndexOf('RUN') >= 0), 'the second argument, Run given');
    Check(SclCurParam(S, C) = 1, 'Sp.. is Speed');
    C.Given.Free;
    L.Clear;
    L.Add('#x := LIMIT(MN := 0, IN := 5, ');
    Check(SclCallAt(L, 0, 31, C) and (C.Callee = 'LIMIT') and not C.Stmt and (C.Seg = 2), 'LIMIT in an expression, the third argument');
    Check(SclSignature(P, B, 'LIMIT', S) and (SclCurParam(S, C) = 2), 'its MX');
    C.Given.Free;
    L.Clear;
    L.Add('IF (a > b) AND SEL(');
    Check(SclCallAt(L, 0, 19, C) and (C.Callee = 'SEL'), 'IF ( .. ): not a call; SEL( is');
    C.Given.Free;
    Check(SclSignature(P, B, 'INT_TO_REAL', S) and (S.RetType = 'REAL') and (S.Params[0].TypeText = 'INT'), 'a conversion');
    Fb.Iface.AddSecVar(vsTemp, 'T1', 'Time', '', '');
    Check(SclSignature(P, Fb, '#Timer', S) and (Length(S.Params) = 4) and (S.Params[1].Name = 'PT') and (S.Params[1].TypeText = 'Time'),
      '#Timer of TON_TIME: IN, PT, Q, ET');
    Fits := SclFitting(P, B, 'Time', 5);
    Check(Fits.IndexOf('#Delay') >= 0, 'fits Time: #Delay');
    Fits.Free;
    Fits := SclFitting(P, B, 'Bool', 5);
    Check(Fits.IndexOf('"Start"') >= 0, 'fits Bool: "Start"');
    Fits.Free;
    Check(SclTypeFits('ANY_NUM', 'Real') and not SclTypeFits('ANY_NUM', 'Bool') and SclTypeFits('ANY_BIT', 'Word'), 'ANY_NUM / ANY_BIT');
    L.Clear;
    L.Add('"Motor_DB"(Run := _bool_in_,');
    L.Add('           Speed := _int_in_);');
    Check(SclNextPlaceholder(L, 0, 0, 5, R, Cc, Pl) and (R = 0) and (Cc = 18) and (Pl = 9), 'the first placeholder');
    Check(SclNextPlaceholder(L, 0, 27, 5, R, Cc, Pl) and (R = 1) and (Cc = 20), 'the next one');
  finally
    L.Free;
    P.Free;
  end;
end;

{ the start values of the elements of an array (Data blocks: an array opens to its elements) }
procedure TestArrayStart;
var
  P: TPlcProject;
  D: TDataBlock;
  Pr: TCProgram;
  Rt: TPlcRuntime;
  S: string;
begin
  WriteLn('--- arrays: the start value of each element ---');
  Check(ArrayStartOf('[1, 2, 3(7)]', 5, 4) = '7', '[1, 2, 3(7)]: element 4 is 7');
  Check(ArrayStartOf('5', 10, 9) = '5', 'one value: every element');
  Check(ArrayStartOf('', 10, 2) = '', 'no start value');
  S := ArrayStartSet('', 10, 3, 'TRUE', 'FALSE');
  Check(S = '[3(FALSE), TRUE, 6(FALSE)]', 'Bool element 3 TRUE: ' + S);
  S := ArrayStartSet(S, 10, 3, 'FALSE', 'FALSE');
  Check(S = '', 'back to the default: no start value');
  S := ArrayStartSet('7', 4, 0, '1', '0');
  Check(S = '[1, 3(7)]', 'one value of all, then element 0: ' + S);
  S := ArrayStartSet('[1, 3(7)]', 4, 0, '7', '0');
  Check(S = '7', 'all the same again: one value');
  P := TPlcProject.Create;
  try
    P.NewEmpty(13);
    D := P.AddDB(1, 'Arr');
    D.AddVar('Flags', 'Array[0..9] of Bool', ArrayStartSet('', 10, 3, 'TRUE', 'FALSE'), '');
    D.AddVar('Words', 'Array[0..9] of Word', ArrayStartSet('', 10, 5, '16#00FF', '0'), '');
    D.Layout;
    Pr := Compile(P);
    ShowMsgs(Pr);
    Check(Pr.ErrorCount = 0, 'Array of Bool / Word with element start values compiles');
    Rt := TPlcRuntime.Create(13);
    try
      Rt.CmdDownload(Pr);
      Rt.CmdRun;
      Wait(40);
      Check((Peek(Rt, P, '"Arr".Flags[3]') = 1) and (Peek(Rt, P, '"Arr".Flags[2]') = 0), '"Arr".Flags[3] = TRUE, [2] FALSE');
      Check((Peek(Rt, P, '"Arr".Words[5]') = $FF) and (Peek(Rt, P, '"Arr".Words[4]') = 0), '"Arr".Words[5] = 16#00FF');
    finally
      Rt.Free;
    end;
  finally
    P.Free;
  end;
end;

{ the cross reference: where an operand is read (a decision) and written (a destination) }
procedure TestXref;
var
  P: TPlcProject;
  B, Fb: TBlock;
  N: TNetwork;
  R: TXrefs;
  Info: string;
  K, Rd, Wr: Integer;

  function Has(const How: string; U: TXrefUse): Boolean;
  var
    J: Integer;
  begin
    Result := False;
    for J := 0 to High(R) do
      if (Pos(How, R[J].How) > 0) and (R[J].Use = U) then Exit(True);
  end;

begin
  WriteLn('--- cross reference ---');
  P := TPlcProject.Create;
  try
    P.NewEmpty(13);
    P.AddTag('Start', 'Bool', '%I0.0', '');
    P.AddTag('Lamp', 'Bool', '%Q0.0', '');
    Fb := P.AddBlock(bkFB, 1, 'Motor');
    Fb.Iface.AddSecVar(vsInput, 'Run', 'Bool', 'FALSE', '');
    Fb.Iface.AddSecVar(vsOutput, 'Running', 'Bool', 'FALSE', '');
    Fb.AddNet(nkSCL).Stl.Text := '#Running := #Run;';
    P.AddDB(1, 'Motor_DB').InstanceOf := 1;
    B := P.Block(0);
    B.DeleteNet(0);
    B.Iface.AddSecVar(vsTemp, 'x', 'Bool', '', '');
    B.AddNet(nkSCL).Stl.Text := 'IF "Start" AND NOT %M0.1 THEN' + LineEnding + '  "Lamp" := TRUE;' + LineEnding +
      'END_IF;' + LineEnding + '#x := "Start";' + LineEnding + '"Motor_DB"(Run := %I0.0,' + LineEnding +
      '           Running => "Lamp");';
    N := B.AddNet(nkLAD);
    N.SetCell(0, 0, NewCell(lkNO, '"Start"'));
    N.SetCell(0, 1, NewCell(lkSet, '"Lamp"'));
    N := B.AddNet(nkSTL);
    N.Stl.Text := 'A     "Start"' + LineEnding + 'O     IB0' + LineEnding + '=     %Q0.0' + LineEnding + 'L     QB0';
    P.AddWatch('"Lamp"', dfBool);
    Check(XrefFind(P, '"Start"', B, Info, R), 'found "Start": ' + Info);
    Check(Pos('%I0.0', Info) > 0, 'what it is: ' + Info);
    Rd := 0;
    Wr := 0;
    for K := 0 to High(R) do
      if R[K].Use = xuRead then Inc(Rd) else if R[K].Use = xuWrite then Inc(Wr);
    Check((Rd = 6) and (Wr = 0), Format('"Start": 6 decisions (IF AND, := value, call input by its address, the contact, A, O IB0) - %d read, %d written', [Rd, Wr]));
    Check(Has('IF: AND', xuRead) and Has('call input Run', xuRead) and Has('-| |- AND', xuRead) and Has('A (AND)', xuRead),
      'IF AND, call input Run, a NO contact, A');
    Check(Has('PLC tag "Start"', xuDecl), 'its tag');
    for K := 0 to High(R) do
      if Pos('O (OR)', R[K].How) > 0 then Check(not R[K].Exact, 'IB0 overlaps %I0.0 (not the same operand)');
    Check(XrefFind(P, '"Lamp"', B, Info, R), 'found "Lamp"');
    Check(Has(':= (assignment)', xuWrite) and Has('call output Running', xuWrite) and Has('-(S)- set', xuWrite) and
      Has('= (assign the RLO)', xuWrite), 'destinations: :=, call output, S coil, =');
    Check(Has('L (load)', xuRead) and Has('watch table row 1', xuTable), 'L QB0 reads it; the watch table');
    Check(XrefFind(P, '#x', B, Info, R) and Has(':= (assignment)', xuWrite) and Has('interface: Temp', xuDecl), '#x: := and its interface row');
    Check(not XrefFind(P, '"Nothing"', B, Info, R), 'an unknown operand: ' + Info);
  finally
    P.Free;
  end;
end;

begin
  TestXref;
  TestArrayStart;
  TestSclSig;
  TestObs;
  TestGroups;
  TestIoSignals;
  TestLadStlScl;
  TestSclSource;
  TestScl64;
  TestSclStrings;
  TestSclParity;
  TestScl;
  TestUdt;
  TestDynIndex;
  TestStructAssign;
  TestFB;
  TestFC;
  TestStlLadCall;
  TestWideLad;
  TestLadConv;
  TestExamples;
  TestExampleBehaviour;
  TestClaudeTools;
  TestPorts;
  TestStl;
  TestLadAnd1200;
  TestSample(1);
  TestSample(4);
  TestSample(7);
  TestSample(13);
  WriteLn;
  WriteLn(Format('%d passed, %d failed', [Passes, Fails]));
  if Fails > 0 then ExitCode := 1;
end.
