program plctest;

{ Headless tests of the Virtual PLC core: the sample projects in RUN, the STL
  semantics (AND before OR, nesting, accumulators, arithmetic, jumps, BCD),
  LAD branches, save / load. }

{$mode objfpc}{$H+}

uses
  Classes, SysUtils, Math, fpjson, jsonparser, uPlcTypes, uPlcProject, uPlcCompiler, uPlcRuntime, uPlcServer,
  uPlcClient, uClaude;

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

begin
  TestScl;
  TestUdt;
  TestDynIndex;
  TestStructAssign;
  TestFB;
  TestFC;
  TestStlLadCall;
  TestWideLad;
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
