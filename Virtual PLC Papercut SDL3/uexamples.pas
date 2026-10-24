unit uExamples;

{ The example projects (the Example Projects folder): ready programs for every CPU family, in LAD, STL
  and SCL. They are built here (so they always compile with this Virtual PLC) and written into the
  examples folder when a file is missing there; a file the user changed stays.

  Every example: tags, the I/O types of its buttons, its blocks and data, watch rows, and a comment
  that says how to try it on the I/O screen. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, StrUtils, uPlcTypes, uPlcProject, uFbd;

function ExampleCount: Integer;
function ExampleFile(I: Integer): string;            // its file name, e.g. 05_Traffic_light_S7-1200.vplc
procedure BuildExample(I: Integer; P: TPlcProject);
procedure WriteExamples(const Dir: string);          // the missing ones

implementation

const
  Files: array[0..34] of string = (
    '01_Motor_start_stop_S7-1200', '02_Motor_start_stop_S7-1500', '03_Motor_start_stop_S7-300',
    '04_Motor_start_stop_S7-400', '05_Traffic_light_S7-1200', '06_Tank_level_control_S7-1200',
    '07_Conveyor_box_counter_S7-1200', '08_Star_delta_starter_S7-300', '09_Pump_duty_standby_S7-1500',
    '10_Garage_door_S7-1200', '11_Car_wash_sequence_S7-1500', '12_Mixing_batch_recipes_S7-1500',
    '13_Parking_garage_counter_S7-1200', '14_Alarm_handling_S7-1200', '15_Running_light_S7-1200',
    '16_Temperature_control_S7-1500', '17_STL_basics_S7-300', '18_Hand_auto_mode_S7-400',
    '19_Timers_LAD_S7-1200', '20_Counters_LAD_S7-1200', '21_Timers_LAD_S7-1500', '22_Counters_LAD_S7-1500',
    '23_Timers_LAD_S7-300', '24_Counters_LAD_S7-300', '25_Timers_LAD_S7-400', '26_Counters_LAD_S7-400',
    '27_Data_type_conversion_S7-1200', '28_Data_type_conversion_STL_S7-300', '29_Math_S7-1200',
    '30_Large_FB_motor_control_S7-1500', '31_SCL_elements_S7-1500', '32_SCL_strings_S7-1500',
    '33_SCL_64_bit_dates_S7-1500', '34_LAD_STL_SCL_functions_S7-1500', '35_FBD_CFC_S7-1500');

function ExampleCount: Integer;
begin
  Result := Length(Files);
end;

function ExampleFile(I: Integer): string;
begin
  Result := Files[I] + '.vplc';
end;

function L(const Lines: array of string): string;
var
  K: Integer;
begin
  Result := '';
  for K := 0 to High(Lines) do
  begin
    if K > 0 then Result := Result + LineEnding;
    Result := Result + Lines[K];
  end;
end;

procedure BuildExample(I: Integer; P: TPlcProject);
var
  B: TBlock;
  N: TNetwork;
  D: TDataBlock;
  Ce: TLadCell;
  K: Integer;

  procedure Scl(Blk: TBlock; const Title, Comment, Code: string);
  begin
    N := Blk.AddNet(nkSCL);
    N.Title := Title;
    N.Comment := Comment;
    N.Stl.Text := Code;
  end;

  procedure Stl(Blk: TBlock; const Title, Comment, Code: string);
  begin
    N := Blk.AddNet(nkSTL);
    N.Title := Title;
    N.Comment := Comment;
    N.Stl.Text := Code;
  end;

  procedure LadNet(Blk: TBlock; const Title, Comment: string; Rows: Integer);
  begin
    N := Blk.AddNet(nkLAD);
    N.Title := Title;
    N.Comment := Comment;
    N.SetRows(Rows);
  end;

  procedure Lad(R, C: Integer; K: TLadKind; const Op: string; ADown: Boolean = False);
  begin
    Ce := NewCell(K, Op);
    Ce.Down := ADown;
    N.SetCell(R, C, Ce);
  end;

  procedure Box(R, C: Integer; K: TLadKind; const Op: string; const P0, P1, P2: string; T: TDataType = dtInt);
  begin
    Ce := NewCell(K, Op);
    Ce.P[0] := P0;
    Ce.P[1] := P1;
    Ce.P[2] := P2;
    if LadHasType(K) then Ce.DType := T;
    N.SetCell(R, C, Ce);
  end;

  // a converter box: IN of type T, OUT of type T2
  procedure Conv(R, C: Integer; K: TLadKind; T, T2: TDataType; const AIn, AOut: string);
  begin
    Ce := NewCell(K, '');
    Ce.DType := T;
    Ce.DType2 := T2;
    Ce.P[0] := AIn;
    Ce.P[1] := AOut;
    N.SetCell(R, C, Ce);
  end;

  // a box with up to 5 pins (the boxes of the SCL functions)
  procedure SBox(R, C: Integer; K: TLadKind; const Op: string; const Ps: array of string);
  var
    J: Integer;
  begin
    if C >= N.Cols then N.SetCols(C + 3);
    Ce := NewCell(K, Op);
    for J := 0 to High(Ps) do Ce.P[J] := Ps[J];
    N.SetCell(R, C, Ce);
  end;

  procedure Wires(R, C0, C1: Integer);
  var
    C: Integer;
  begin
    for C := C0 to C1 do N.SetCell(R, C, NewCell(lkWire, ''));
  end;

  { FBD / CFC: a network, a box (its index), an input (an operand, negated), a wire, an output }
  procedure FNet(Kind: TNetKind; const Title, Comment: string);
  begin
    N := P.Block(0).AddNet(Kind);
    N.Title := Title;
    N.Comment := Comment;
  end;

  function FBox(Id: Integer; const Box, Inst: string; T: TDataType = dtNone): Integer;
  begin
    SetLength(N.Nodes, Length(N.Nodes) + 1);
    Result := High(N.Nodes);
    N.Nodes[Result] := NewFbdNode(N, Box, P, Inst);
    N.Nodes[Result].Id := Id;
    N.Nodes[Result].Inst := Inst;
    if T <> dtNone then N.Nodes[Result].DType := T;
  end;

  function PinOf(K: Integer; const Pin: string; IsOut: Boolean): Integer;
  var
    J: Integer;
  begin
    Result := 0;
    if IsOut then
    begin
      for J := 0 to High(N.Nodes[K].Outs) do
        if N.Nodes[K].Outs[J].Name = Pin then Exit(J);
      Exit;
    end;
    // an input the box has not yet: added (IN3 ..)
    repeat
      for J := 0 to High(N.Nodes[K].Ins) do
        if N.Nodes[K].Ins[J].Name = Pin then Exit(J);
    until not FbdAddInput(N.Nodes[K]);
  end;

  procedure FIn(K: Integer; const Pin, Op: string; Neg: Boolean = False);
  var
    Q: Integer;
  begin
    Q := PinOf(K, Pin, False);
    N.Nodes[K].Ins[Q].Opnd := Op;
    N.Nodes[K].Ins[Q].Neg := Neg;
  end;

  procedure FWire(K: Integer; const Pin: string; Src: Integer; const SrcPin: string; Neg: Boolean = False);
  var
    Q: Integer;
  begin
    Q := PinOf(K, Pin, False);
    N.Nodes[K].Ins[Q].Src := N.Nodes[Src].Id;
    N.Nodes[K].Ins[Q].SrcPin := PinOf(Src, SrcPin, True);
    N.Nodes[K].Ins[Q].Neg := Neg;
  end;

  procedure FOut(K: Integer; const Pin, Op: string);
  begin
    N.Nodes[K].Outs[PinOf(K, Pin, True)].Opnd := Op;
  end;

  procedure Push(Bit: Integer; NC: Boolean = False);
  begin
    if NC then P.DIch[Bit].InType := itPushNC else P.DIch[Bit].InType := itPushNO;
  end;

  procedure Start(Model: Integer; const AName, AComment: string);
  begin
    P.NewEmpty(Model);
    P.Block(0).DeleteNet(0);
    P.Name := AName;
    P.Author := 'Virtual PLC examples';
    P.Comment := AComment;
    P.ClockByte := 0;   // MB0: M0.3 = 2 Hz, M0.5 = 1 Hz
    P.AddTag('Clock_2Hz', 'Bool', IfThen(IsTia(P.Family), '%M0.3', 'M0.3'), 'clock memory 2 Hz');
    P.AddTag('Clock_1Hz', 'Bool', IfThen(IsTia(P.Family), '%M0.5', 'M0.5'), 'clock memory 1 Hz');
  end;

  function InA(K: Integer): string;
  begin
    Result := Format('%sI%d.%d', [IfThen(IsTia(P.Family), '%', ''), P.Model.DIByte + K div 8, K mod 8]);
  end;

  function OutA(K: Integer): string;
  begin
    Result := Format('%sQ%d.%d', [IfThen(IsTia(P.Family), '%', ''), P.Model.DQByte + K div 8, K mod 8]);
  end;

  // S5 timers and counters: T1 / C1 (S7-300/400), %T1 / %C1 (S7-1500)
  function S5(const Area: string; No: Integer): string;
  begin
    Result := IfThen(IsTia(P.Family), '%', '') + Area + IntToStr(No);
  end;

  procedure Timers(Model: Integer);
  const
    IecK: array[0..3] of TLadKind = (lkTON, lkTOF, lkTP, lkTONR);
    IecN: array[0..3] of string = ('TON', 'TOF', 'TP', 'TONR');
    IecT: array[0..3] of string = ('T#3S', 'T#3S', 'T#2S', 'T#5S');
    IecHow: array[0..3] of string = ('on delay: Q 3 s after IN, off with IN',
      'off delay: Q with IN, off 3 s after IN went', 'pulse: Q for 2 s from the rising edge of IN',
      'accumulating on delay: the time adds up while IN is on, R resets it');
    S5K: array[0..4] of TLadKind = (lkSP, lkSE, lkSD, lkSS, lkSF);
    S5N: array[0..4] of string = ('SP', 'SE', 'SD', 'SS', 'SF');
    S5How: array[0..4] of string = ('pulse: on while IN, at most 2 s',
      'extended pulse: 2 s from the rising edge, also when IN goes',
      'on delay: on 2 s after IN, off with IN', 'retentive on delay: on 2 s after the edge, stays until R',
      'off delay: on with IN, off 2 s after IN went');
  var
    K, NIec, NS5, Io: Integer;
    Fam: string;
  begin
    Start(Model, '', '');
    Fam := FamilyNames[P.Family];
    if IsTia(P.Family) then NIec := 4 else NIec := 3;    // TONR: S7-1200 / S7-1500
    if P.Family = cfS71200 then NS5 := 0 else NS5 := 5;  // S5 timers: not on the S7-1200
    P.Name := 'Timers in LAD (' + Fam + ')';
    P.Comment := 'LAD: every timer of the ' + Fam + ' in a network of its own: an input switches it, its ' +
      'output drives a lamp. Try the inputs on the I/O screen and watch the times in the watch table. ' +
      IfThen(NS5 > 0, 'IEC timers (instances in DB1) and S5 timers T1..T5; ', 'IEC timers (instances in DB1); ') +
      'Reset_PB resets TONR' + IfThen(NS5 > 0, ' and SS.', '.');
    D := P.AddDB(1, 'Timers');
    B := P.Block(0);
    Io := 0;
    for K := 0 to NIec - 1 do
    begin
      P.AddTag('In_' + IecN[K], 'Bool', InA(Io), IecN[K] + ' input');
      P.AddTag('Out_' + IecN[K], 'Bool', OutA(Io), IecN[K] + ' output');
      if IecK[K] = lkTP then Push(Io);
      D.AddVar(IecN[K] + '_1', 'IEC_TIMER', '', 'the ' + IecN[K] + ' instance');
      D.AddVar('ET_' + IecN[K], 'Time', '', 'elapsed time of ' + IecN[K]);
      LadNet(B, IecN[K] + ' ' + IecT[K], IecHow[K], 1);
      Lad(0, 0, lkNO, '"In_' + IecN[K] + '"');
      if IecK[K] = lkTONR then
        Box(0, 1, lkTONR, '"Timers".' + IecN[K] + '_1', IecT[K], '"Reset_PB"', '"Timers".ET_' + IecN[K])
      else
        Box(0, 1, IecK[K], '"Timers".' + IecN[K] + '_1', IecT[K], '"Timers".ET_' + IecN[K], '');
      Wires(0, 2, 6);
      Lad(0, 7, lkCoil, '"Out_' + IecN[K] + '"');
      P.AddWatch('"Timers".ET_' + IecN[K], dfTime);
      Inc(Io);
    end;
    for K := 0 to NS5 - 1 do
    begin
      P.AddTag('In_' + S5N[K], 'Bool', InA(Io), 'S5 timer ' + S5N[K] + ' input');
      P.AddTag('Out_' + S5N[K], 'Bool', OutA(Io), 'S5 timer ' + S5N[K] + ' output');
      if S5K[K] in [lkSE, lkSS] then Push(Io);
      LadNet(B, S5N[K] + ' ' + S5('T', K + 1) + ' S5T#2S', S5How[K], 1);
      Lad(0, 0, lkNO, '"In_' + S5N[K] + '"');
      Wires(0, 1, 6);
      Ce := NewCell(S5K[K], S5('T', K + 1));
      Ce.P[0] := 'S5T#2S';
      N.SetCell(0, 7, Ce);
      LadNet(B, S5N[K] + ' output', 'the timer bit ' + S5('T', K + 1), 1);
      Lad(0, 0, lkNO, S5('T', K + 1));
      Wires(0, 1, 6);
      Lad(0, 7, lkCoil, '"Out_' + S5N[K] + '"');
      P.AddWatch(S5('T', K + 1), dfS5Time);
      Inc(Io);
    end;
    P.AddTag('Reset_PB', 'Bool', InA(Io), 'reset TONR' + IfThen(NS5 > 0, ' and SS', ''));
    Push(Io);
    if NS5 > 0 then
    begin
      LadNet(B, 'Reset SS', 'R on the timer ' + S5('T', 4), 1);
      Lad(0, 0, lkNO, '"Reset_PB"');
      Wires(0, 1, 6);
      Lad(0, 7, lkReset, S5('T', 4));
    end;
  end;

  procedure Counters(Model: Integer);
  var
    Fam: string;
    S5c: Boolean;
  begin
    Start(Model, '', '');
    Fam := FamilyNames[P.Family];
    S5c := P.Family <> cfS71200;   // S5 counters: not on the S7-1200
    P.Name := 'Counters in LAD (' + Fam + ')';
    P.Comment := 'LAD: CTU, CTD and CTUD (instances in DB1, preset 5)' + IfThen(S5c, ' and the S5 counter ' +
      S5('C', 1) + ' (SC sets C#3, CU / CD count, R resets)', '') + '. Count_Up / Count_Down count on every ' +
      'press, Load_PB loads the preset, Reset_PB resets. Watch the counts in the watch table.';
    P.AddTag('Count_Up', 'Bool', InA(0), 'count up');
    P.AddTag('Count_Down', 'Bool', InA(1), 'count down');
    P.AddTag('Reset_PB', 'Bool', InA(2), 'reset');
    P.AddTag('Load_PB', 'Bool', InA(3), 'load the preset');
    P.AddTag('Out_CTU', 'Bool', OutA(0), 'CTU: CV >= 5');
    P.AddTag('Out_CTD', 'Bool', OutA(1), 'CTD: CV <= 0');
    P.AddTag('Out_CTUD', 'Bool', OutA(2), 'CTUD QU: CV >= 5');
    Push(0);
    Push(1);
    Push(2);
    Push(3);
    D := P.AddDB(1, 'Counters');
    D.AddVar('CTU_1', 'IEC_COUNTER', '', 'up counter');
    D.AddVar('CTD_1', 'IEC_COUNTER', '', 'down counter');
    D.AddVar('CTUD_1', 'IEC_COUNTER', '', 'up / down counter');
    D.AddVar('CV_Up', 'Int', '0', 'count of CTU');
    D.AddVar('CV_Down', 'Int', '0', 'count of CTD');
    D.AddVar('CV_UpDown', 'Int', '0', 'count of CTUD');
    B := P.Block(0);
    LadNet(B, 'CTU', 'counts up on every rising edge of CU; Q when CV >= PV; R sets CV to 0', 1);
    Lad(0, 0, lkNO, '"Count_Up"');
    Box(0, 1, lkCTU, '"Counters".CTU_1', '5', '"Reset_PB"', '"Counters".CV_Up');
    Wires(0, 2, 6);
    Lad(0, 7, lkCoil, '"Out_CTU"');
    LadNet(B, 'CTD', 'counts down on every rising edge of CD; Q when CV <= 0; LD loads PV into CV', 1);
    Lad(0, 0, lkNO, '"Count_Down"');
    Box(0, 1, lkCTD, '"Counters".CTD_1', '5', '"Load_PB"', '"Counters".CV_Down');
    Wires(0, 2, 6);
    Lad(0, 7, lkCoil, '"Out_CTD"');
    LadNet(B, 'CTUD', 'CU up, CD down, R reset, LD load; QU when CV >= PV', 1);
    Lad(0, 0, lkNO, '"Count_Up"');
    Ce := NewCell(lkCTUD, '"Counters".CTUD_1');
    Ce.P[0] := '5';
    Ce.P[1] := '"Count_Down"';
    Ce.P[2] := '"Reset_PB"';
    Ce.P[3] := '"Load_PB"';
    Ce.P[4] := '"Counters".CV_UpDown';
    N.SetCell(0, 1, Ce);
    Wires(0, 2, 6);
    Lad(0, 7, lkCoil, '"Out_CTUD"');
    P.AddWatch('"Counters".CV_Up', dfDec);
    P.AddWatch('"Counters".CV_Down', dfDec);
    P.AddWatch('"Counters".CV_UpDown', dfDec);
    if S5c then
    begin
      P.AddTag('Out_C1', 'Bool', OutA(3), 'S5 counter ' + S5('C', 1) + ' not 0');
      LadNet(B, 'SC ' + S5('C', 1), 'set the S5 counter to 3 (rising edge)', 1);
      Lad(0, 0, lkNO, '"Load_PB"');
      Wires(0, 1, 6);
      Ce := NewCell(lkSC, S5('C', 1));
      Ce.P[0] := 'C#3';
      N.SetCell(0, 7, Ce);
      LadNet(B, 'CU ' + S5('C', 1), 'count up (rising edge, at most 999)', 1);
      Lad(0, 0, lkNO, '"Count_Up"');
      Wires(0, 1, 6);
      Lad(0, 7, lkCU, S5('C', 1));
      LadNet(B, 'CD ' + S5('C', 1), 'count down (rising edge, not below 0)', 1);
      Lad(0, 0, lkNO, '"Count_Down"');
      Wires(0, 1, 6);
      Lad(0, 7, lkCD, S5('C', 1));
      LadNet(B, 'R ' + S5('C', 1), 'reset to 0', 1);
      Lad(0, 0, lkNO, '"Reset_PB"');
      Wires(0, 1, 6);
      Lad(0, 7, lkReset, S5('C', 1));
      LadNet(B, 'Counter bit', 'the counter bit: on while the count is not 0', 1);
      Lad(0, 0, lkNO, S5('C', 1));
      Wires(0, 1, 6);
      Lad(0, 7, lkCoil, '"Out_C1"');
      P.AddWatch(S5('C', 1), dfCounter);
    end;
  end;

begin
  case I of
    0: P.LoadSample(7);
    1: P.LoadSample(13);
    2: P.LoadSample(1);
    3: P.LoadSample(5);

    4: // ---------- traffic light ----------
      begin
        Start(7, 'Traffic light with pedestrian request (S7-1200)',
          'SCL state machine with IEC timers. I/O: press Ped_Request (I0.0): the cars get yellow, then red, ' +
          'the pedestrians green for 8 s. Night_Mode (I0.1) flashes yellow.');
        P.AddTag('Ped_Request', 'Bool', '%I0.0', 'pedestrian push button');
        P.AddTag('Night_Mode', 'Bool', '%I0.1', 'switch: night mode');
        P.AddTag('Car_Red', 'Bool', '%Q0.0', 'cars red');
        P.AddTag('Car_Yellow', 'Bool', '%Q0.1', 'cars yellow');
        P.AddTag('Car_Green', 'Bool', '%Q0.2', 'cars green');
        P.AddTag('Ped_Red', 'Bool', '%Q0.3', 'pedestrians red');
        P.AddTag('Ped_Green', 'Bool', '%Q0.4', 'pedestrians green');
        P.AddTag('Wait_Lamp', 'Bool', '%Q0.5', 'request stored');
        Push(0);
        D := P.AddDB(1, 'Traffic');
        D.AddVar('Step', 'Int', '0', '0 cars green, 1 yellow, 2 red, 3 pedestrians green, 4 red+yellow');
        D.AddVar('Request', 'Bool', 'FALSE', 'a pedestrian waits');
        D.AddVar('StepTimer', 'IEC_TIMER', '', 'the time of a step');
        D.AddVar('Dur', 'Time', 'T#0MS', 'the time of the step now');
        B := P.Block(0);
        Scl(B, 'Traffic light', 'the steps advance when the step timer has run out', L([
          'IF "Ped_Request" THEN "Traffic".Request := TRUE; END_IF;',
          'CASE "Traffic".Step OF',
          '    0: "Traffic".Dur := T#5S;    // cars green at least 5 s',
          '    1: "Traffic".Dur := T#2S;    // yellow',
          '    2: "Traffic".Dur := T#1S;    // all red',
          '    3: "Traffic".Dur := T#8S;    // pedestrians green',
          '    4: "Traffic".Dur := T#1500MS; // red + yellow',
          'END_CASE;',
          '"Traffic".StepTimer.TON(IN := NOT "Night_Mode" AND NOT "Traffic".StepTimer.Q, PT := "Traffic".Dur);',
          'IF "Traffic".StepTimer.Q THEN',
          '    IF "Traffic".Step = 0 THEN',
          '        IF "Traffic".Request THEN "Traffic".Step := 1; END_IF;',
          '    ELSIF "Traffic".Step = 4 THEN',
          '        "Traffic".Step := 0;',
          '    ELSE',
          '        "Traffic".Step := "Traffic".Step + 1;',
          '        IF "Traffic".Step = 3 THEN "Traffic".Request := FALSE; END_IF;',
          '    END_IF;',
          'END_IF;',
          'IF "Night_Mode" THEN "Traffic".Step := 0; END_IF;']));
        Scl(B, 'Lamps', 'night mode: only yellow flashes', L([
          '"Car_Green" := ("Traffic".Step = 0) AND NOT "Night_Mode";',
          '"Car_Yellow" := ("Traffic".Step = 1) OR ("Traffic".Step = 4) OR ("Night_Mode" AND "Clock_1Hz");',
          '"Car_Red" := (("Traffic".Step = 2) OR ("Traffic".Step = 3) OR ("Traffic".Step = 4)) AND NOT "Night_Mode";',
          '"Ped_Green" := ("Traffic".Step = 3) AND NOT "Night_Mode";',
          '"Ped_Red" := ("Traffic".Step <> 3) AND NOT "Night_Mode";',
          '"Wait_Lamp" := "Traffic".Request AND "Clock_2Hz";']));
        P.AddWatch('"Traffic".Step', dfDec);
        P.AddWatch('"Traffic".StepTimer.ET', dfTime);
        P.AddWatch('"Ped_Request"', dfBool, 'TRUE');
      end;

    5: // ---------- tank level ----------
      begin
        Start(7, 'Tank level control with hysteresis (S7-1200)',
          'The level sensor (IW64, 0..27648) is scaled to 0..100 %. The pump fills below 20 % and stops above ' +
          '80 %; above 95 % the alarm lamp flashes. I/O: move the AI slider (or let the sine generator run).');
        P.AddTag('Level_AI', 'Int', '%IW64', 'level sensor 0..10 V');
        P.AddTag('Auto_On', 'Bool', '%I0.0', 'switch: automatic');
        P.AddTag('Pump', 'Bool', '%Q0.0', 'fill pump');
        P.AddTag('High_Alarm', 'Bool', '%Q0.1', 'level above 95 %');
        P.AddTag('Low_Lamp', 'Bool', '%Q0.2', 'level below 20 %');
        P.AIch[0].AiValue := 6000;
        D := P.AddDB(1, 'Tank');
        D.AddVar('Level', 'Real', '0.0', 'level in %');
        D.AddVar('LowLimit', 'Real', '20.0', 'the pump starts below');
        D.AddVar('HighLimit', 'Real', '80.0', 'the pump stops above');
        D.AddVar('AlarmLimit', 'Real', '95.0', 'alarm above');
        B := P.Block(0);
        Scl(B, 'Scale the level', 'NORM_X: 0..27648 to 0..1, SCALE_X: to 0..100 %', L([
          '"Tank".Level := SCALE_X(MIN := 0.0, VALUE := NORM_X(MIN := 0, VALUE := "Level_AI", MAX := 27648), MAX := 100.0);']));
        Scl(B, 'Two-point control', 'between the limits the pump keeps its state (hysteresis)', L([
          'IF NOT "Auto_On" THEN',
          '    "Pump" := FALSE;',
          'ELSIF "Tank".Level < "Tank".LowLimit THEN',
          '    "Pump" := TRUE;',
          'ELSIF "Tank".Level > "Tank".HighLimit THEN',
          '    "Pump" := FALSE;',
          'END_IF;']));
        LadNet(B, 'High level alarm', 'IN_RANGE would be the other way: here a CMP > and the 2 Hz clock', 1);
        Box(0, 0, lkCmp, '', '"Tank".Level', '"Tank".AlarmLimit', '', dtReal);
        Ce := N.Cell(0, 0);
        Ce.Cmp := coGT;
        N.SetCell(0, 0, Ce);
        Lad(0, 1, lkNO, '"Clock_2Hz"');
        Wires(0, 2, 6);
        Lad(0, 7, lkCoil, '"High_Alarm"');
        LadNet(B, 'Low level lamp', 'OUT_RANGE of 20..100 %', 1);
        Box(0, 0, lkOutRange, '', '"Tank".LowLimit', '"Tank".Level', '100.0', dtReal);
        Wires(0, 1, 6);
        Lad(0, 7, lkCoil, '"Low_Lamp"');
        P.AddWatch('"Tank".Level', dfReal);
        P.AddWatch('"Pump"', dfBool);
        P.AddWatch('"Level_AI"', dfDec);
      end;

    6: // ---------- conveyor with box counter ----------
      begin
        Start(7, 'Conveyor with a box counter (S7-1200)',
          'LAD: Start / Stop with self holding; a CTU counts the boxes (I0.2); after 10 the belt stops and ' +
          'Batch_Done is on until Reset (I0.3).');
        P.AddTag('Start_PB', 'Bool', '%I0.0', 'start');
        P.AddTag('Stop_PB', 'Bool', '%I0.1', 'stop, wired NC');
        P.AddTag('Box_Sensor', 'Bool', '%I0.2', 'a box passes');
        P.AddTag('Reset_PB', 'Bool', '%I0.3', 'new batch');
        P.AddTag('Conveyor', 'Bool', '%Q0.0', 'belt motor');
        P.AddTag('Batch_Done', 'Bool', '%Q0.1', '10 boxes');
        Push(0);
        Push(1, True);
        Push(2);
        Push(3);
        D := P.AddDB(1, 'Belt');
        D.AddVar('Boxes', 'IEC_COUNTER', '', 'the box counter');
        D.AddVar('Count', 'Int', '0', 'boxes so far');
        B := P.Block(0);
        LadNet(B, 'Belt on / off', 'self holding; the batch stops it', 2);
        Lad(0, 0, lkNO, '"Start_PB"', True);
        Lad(0, 1, lkNO, '"Stop_PB"');
        Lad(0, 2, lkNC, '"Batch_Done"');
        Wires(0, 3, 6);
        Lad(0, 7, lkCoil, '"Conveyor"');
        Lad(1, 0, lkNO, '"Conveyor"');
        LadNet(B, 'Count the boxes', 'CTU with PV 10: Q = the batch is full', 1);
        Lad(0, 0, lkNO, '"Box_Sensor"');
        Box(0, 1, lkCTU, '"Belt".Boxes', '10', '"Reset_PB"', '"Belt".Count');
        Wires(0, 2, 6);
        Lad(0, 7, lkCoil, '"Batch_Done"');
        P.AddWatch('"Belt".Count', dfDec);
        P.AddWatch('"Conveyor"', dfBool);
      end;

    7: // ---------- star-delta, S7-300 ----------
      begin
        Start(1, 'Star-delta starter (S7-300)',
          'LAD with an S5 timer (SD T1): Start (I0.0) switches Main and Star, after 5 s Star goes and Delta comes. ' +
          'Stop (I0.1, NC) and the overload (I0.2) switch off. Star and Delta lock each other.');
        P.AddTag('Start_PB', 'Bool', 'I0.0', 'start');
        P.AddTag('Stop_PB', 'Bool', 'I0.1', 'stop, wired NC');
        P.AddTag('Overload_OK', 'Bool', 'I0.2', 'thermal overload healthy');
        P.AddTag('Main_K', 'Bool', 'Q4.0', 'main contactor');
        P.AddTag('Star_K', 'Bool', 'Q4.1', 'star contactor');
        P.AddTag('Delta_K', 'Bool', 'Q4.2', 'delta contactor');
        P.AddTag('Run_Lamp', 'Bool', 'Q4.3', 'motor runs in delta');
        Push(0);
        Push(1, True);
        B := P.Block(0);
        LadNet(B, 'Main contactor', 'self holding', 2);
        Lad(0, 0, lkNO, '"Start_PB"', True);
        Lad(0, 1, lkNO, '"Stop_PB"');
        Lad(0, 2, lkNO, '"Overload_OK"');
        Wires(0, 3, 6);
        Lad(0, 7, lkCoil, '"Main_K"');
        Lad(1, 0, lkNO, '"Main_K"');
        LadNet(B, 'Star-delta time', 'SD: on delay 5 s while Main', 1);
        Lad(0, 0, lkNO, '"Main_K"');
        Wires(0, 1, 6);
        Ce := NewCell(lkSD, 'T1');
        Ce.P[0] := 'S5T#5S';
        N.SetCell(0, 7, Ce);
        LadNet(B, 'Star', 'until the time has run out, never with Delta', 1);
        Lad(0, 0, lkNO, '"Main_K"');
        Lad(0, 1, lkNC, 'T1');
        Lad(0, 2, lkNC, '"Delta_K"');
        Wires(0, 3, 6);
        Lad(0, 7, lkCoil, '"Star_K"');
        LadNet(B, 'Delta', 'after the time, never with Star', 1);
        Lad(0, 0, lkNO, '"Main_K"');
        Lad(0, 1, lkNO, 'T1');
        Lad(0, 2, lkNC, '"Star_K"');
        Wires(0, 3, 6);
        Lad(0, 7, lkCoil, '"Delta_K"');
        LadNet(B, 'Run lamp', '', 1);
        Lad(0, 0, lkNO, '"Delta_K"');
        Wires(0, 1, 6);
        Lad(0, 7, lkCoil, '"Run_Lamp"');
        P.DIch[2].InType := itToggle;
        P.AddWatch('T1', dfS5Time);
        P.AddWatch('"Main_K"', dfBool);
      end;

    8: // ---------- pump duty / standby ----------
      begin
        Start(13, 'Two pumps: duty / standby with alternation (S7-1500)',
          'SCL: on every demand (I0.0) the other pump runs (equal wear); a pump with a fault (I0.1 / I0.2) is ' +
          'replaced by the other at once. The run seconds of both are counted.');
        P.AddTag('Demand', 'Bool', '%I0.0', 'switch: water needed');
        P.AddTag('Fault_P1', 'Bool', '%I0.1', 'switch: pump 1 fault');
        P.AddTag('Fault_P2', 'Bool', '%I0.2', 'switch: pump 2 fault');
        P.AddTag('Pump1', 'Bool', '%Q0.0', 'pump 1');
        P.AddTag('Pump2', 'Bool', '%Q0.1', 'pump 2');
        P.AddTag('Fault_Lamp', 'Bool', '%Q0.2', 'a pump has a fault');
        D := P.AddDB(1, 'Pumps');
        D.AddVar('Lead', 'Int', '1', 'the pump of the next demand');
        D.AddVar('DemandOld', 'Bool', 'FALSE', 'edge memory');
        D.AddVar('Sec1', 'DInt', '0', 'run seconds pump 1');
        D.AddVar('Sec2', 'DInt', '0', 'run seconds pump 2');
        D.AddVar('Pulse', 'IEC_TIMER', '', 'one pulse per second');
        B := P.Block(0);
        Scl(B, 'Duty / standby', 'the lead pump changes on every new demand', L([
          'IF "Demand" AND NOT "Pumps".DemandOld THEN',
          '    IF "Pumps".Lead = 1 THEN "Pumps".Lead := 2; ELSE "Pumps".Lead := 1; END_IF;',
          'END_IF;',
          '"Pumps".DemandOld := "Demand";',
          '"Pump1" := "Demand" AND NOT "Fault_P1" AND (("Pumps".Lead = 1) OR "Fault_P2");',
          '"Pump2" := "Demand" AND NOT "Fault_P2" AND (("Pumps".Lead = 2) OR "Fault_P1");',
          '"Fault_Lamp" := ("Fault_P1" OR "Fault_P2") AND "Clock_1Hz";']));
        Scl(B, 'Run seconds', 'a 1 s pulse counts the seconds of the running pump', L([
          '"Pumps".Pulse.TON(IN := NOT "Pumps".Pulse.Q, PT := T#1S);',
          'IF "Pumps".Pulse.Q THEN',
          '    IF "Pump1" THEN "Pumps".Sec1 := "Pumps".Sec1 + 1; END_IF;',
          '    IF "Pump2" THEN "Pumps".Sec2 := "Pumps".Sec2 + 1; END_IF;',
          'END_IF;']));
        P.AddWatch('"Pumps".Lead', dfDec);
        P.AddWatch('"Pumps".Sec1', dfDec);
        P.AddWatch('"Pumps".Sec2', dfDec);
      end;

    9: // ---------- garage door ----------
      begin
        Start(7, 'Garage door with limit switches and light barrier (S7-1200)',
          'LAD: Open / Close / Stop push buttons, the limit switches end the run, the light barrier (NC) stops ' +
          'closing and opens again; the warning lamp flashes while the door moves.');
        P.AddTag('Open_PB', 'Bool', '%I0.0', 'open');
        P.AddTag('Close_PB', 'Bool', '%I0.1', 'close');
        P.AddTag('Stop_PB', 'Bool', '%I0.2', 'stop, wired NC');
        P.AddTag('Limit_Open', 'Bool', '%I0.3', 'switch: door fully open');
        P.AddTag('Limit_Closed', 'Bool', '%I0.4', 'switch: door closed');
        P.AddTag('Beam_Free', 'Bool', '%I0.5', 'switch: light barrier free (NC)');
        P.AddTag('Motor_Open', 'Bool', '%Q0.0', 'motor up');
        P.AddTag('Motor_Close', 'Bool', '%Q0.1', 'motor down');
        P.AddTag('Warning', 'Bool', '%Q0.2', 'flashing lamp');
        Push(0);
        Push(1);
        Push(2, True);
        B := P.Block(0);
        LadNet(B, 'Open', 'self holding until the open limit; the beam reopens a closing door', 3);
        // three parallel paths that join after column 1: the button, the self holding, the beam while closing
        Lad(0, 0, lkNO, '"Open_PB"');
        Lad(0, 1, lkWire, '', True);
        Lad(1, 0, lkNO, '"Motor_Open"');
        Lad(1, 1, lkWire, '', True);
        Lad(2, 0, lkNC, '"Beam_Free"');
        Lad(2, 1, lkNO, '"Motor_Close"');
        Lad(0, 2, lkNO, '"Stop_PB"');
        Lad(0, 3, lkNC, '"Limit_Open"');
        Wires(0, 4, 6);
        Lad(0, 7, lkCoil, '"Motor_Open"');
        LadNet(B, 'Close', 'only with the beam free', 2);
        Lad(0, 0, lkNO, '"Close_PB"', True);
        Lad(0, 1, lkNO, '"Stop_PB"');
        Lad(0, 2, lkNC, '"Limit_Closed"');
        Lad(0, 3, lkNO, '"Beam_Free"');
        Lad(0, 4, lkNC, '"Motor_Open"');
        Wires(0, 5, 6);
        Lad(0, 7, lkCoil, '"Motor_Close"');
        Lad(1, 0, lkNO, '"Motor_Close"');
        LadNet(B, 'Warning lamp', 'flashes 2 Hz while the door moves', 2);
        Lad(0, 0, lkNO, '"Motor_Open"', True);
        Lad(0, 1, lkNO, '"Clock_2Hz"');
        Wires(0, 2, 6);
        Lad(0, 7, lkCoil, '"Warning"');
        Lad(1, 0, lkNO, '"Motor_Close"');
        P.DIch[5].InType := itToggle;
        P.AddWatch('"Motor_Open"', dfBool);
        P.AddWatch('"Motor_Close"', dfBool);
      end;

    10: // ---------- car wash ----------
      begin
        Start(13, 'Car wash sequence (S7-1500)',
          'SCL step chain: Start (I0.0) with the car in place (I0.1): pre-wash 4 s, soap 6 s, brushes 8 s, rinse 5 s, ' +
          'dry 6 s, then Done. Emergency stop (I0.2, NC) aborts.');
        P.AddTag('Start_PB', 'Bool', '%I0.0', 'start');
        P.AddTag('Car_In_Place', 'Bool', '%I0.1', 'switch: car in position');
        P.AddTag('EStop_OK', 'Bool', '%I0.2', 'emergency stop, NC');
        P.AddTag('Water', 'Bool', '%Q0.0', 'water valve');
        P.AddTag('Soap', 'Bool', '%Q0.1', 'soap pump');
        P.AddTag('Brushes', 'Bool', '%Q0.2', 'brush motor');
        P.AddTag('Dryer', 'Bool', '%Q0.3', 'dryer fan');
        P.AddTag('Done_Lamp', 'Bool', '%Q0.4', 'drive out');
        P.AddTag('Busy_Lamp', 'Bool', '%Q0.5', 'washing');
        Push(0);
        Push(2, True);
        D := P.AddDB(1, 'Wash');
        D.AddVar('Step', 'Int', '0', '0 idle, 1 pre-wash, 2 soap, 3 brushes, 4 rinse, 5 dry, 6 done');
        D.AddVar('T', 'IEC_TIMER', '', 'step time');
        D.AddVar('Dur', 'Time', 'T#0MS', 'the time of the step');
        B := P.Block(0);
        Scl(B, 'Step chain', 'every step has its time', L([
          'IF NOT "EStop_OK" THEN',
          '    "Wash".Step := 0;',
          'ELSIF ("Wash".Step = 0) AND "Start_PB" AND "Car_In_Place" THEN',
          '    "Wash".Step := 1;',
          'ELSIF ("Wash".Step = 6) AND NOT "Car_In_Place" THEN',
          '    "Wash".Step := 0;',
          'END_IF;',
          'CASE "Wash".Step OF',
          '    1: "Wash".Dur := T#4S;',
          '    2: "Wash".Dur := T#6S;',
          '    3: "Wash".Dur := T#8S;',
          '    4: "Wash".Dur := T#5S;',
          '    5: "Wash".Dur := T#6S;',
          'ELSE',
          '    "Wash".Dur := T#0MS;',
          'END_CASE;',
          '"Wash".T.TON(IN := ("Wash".Step >= 1) AND ("Wash".Step <= 5) AND NOT "Wash".T.Q, PT := "Wash".Dur);',
          'IF "Wash".T.Q THEN "Wash".Step := "Wash".Step + 1; END_IF;']));
        Scl(B, 'Outputs', '', L([
          '"Water" := ("Wash".Step = 1) OR ("Wash".Step = 4);',
          '"Soap" := "Wash".Step = 2;',
          '"Brushes" := ("Wash".Step = 2) OR ("Wash".Step = 3);',
          '"Dryer" := "Wash".Step = 5;',
          '"Done_Lamp" := "Wash".Step = 6;',
          '"Busy_Lamp" := ("Wash".Step >= 1) AND ("Wash".Step <= 5) AND "Clock_1Hz";']));
        P.DIch[1].InType := itToggle;
        P.AddWatch('"Wash".Step', dfDec);
        P.AddWatch('"Wash".T.ET', dfTime);
      end;

    11: // ---------- mixing batch with recipes ----------
      begin
        Start(13, 'Mixing batch with recipes (S7-1500)',
          'A PLC data type "Recipe" and an array of three recipes; the step chain fills A, fills B, mixes and ' +
          'drains. The tank is simulated in the cyclic interrupt OB30. Choose the recipe in "Batch".Select ' +
          '(watch table), start with I0.0.');
        P.AddTag('Start_PB', 'Bool', '%I0.0', 'start a batch');
        P.AddTag('Valve_A', 'Bool', '%Q0.0', 'component A');
        P.AddTag('Valve_B', 'Bool', '%Q0.1', 'component B');
        P.AddTag('Mixer', 'Bool', '%Q0.2', 'mixer motor');
        P.AddTag('Drain', 'Bool', '%Q0.3', 'drain valve');
        P.AddTag('Ready', 'Bool', '%Q0.4', 'idle');
        Push(0);
        D := P.AddUdt(1, 'Recipe');
        D.AddVar('AmountA', 'Real', '0.0', 'litres of A');
        D.AddVar('AmountB', 'Real', '0.0', 'litres of B');
        D.AddVar('MixTime', 'Time', 'T#0MS', 'mixing time');
        D := P.AddDB(1, 'Batch');
        D.AddVar('Recipes', 'Array[1..3] of "Recipe"', '', 'the three recipes');
        D.AddVar('Select', 'Int', '1', 'the recipe of the next batch (1..3)');
        D.AddVar('Step', 'Int', '0', '0 idle, 1 fill A, 2 fill B, 3 mix, 4 drain');
        D.AddVar('Level', 'Real', '0.0', 'litres in the tank (simulated in OB30)');
        D.AddVar('Target', 'Real', '0.0', 'the level to reach');
        D.AddVar('MixT', 'IEC_TIMER', '', 'mixing');
        D.AddVar('Batches', 'DInt', '0', 'batches made');
        B := P.Block(0);
        Scl(B, 'Recipes (first cycle)', 'the recipe values: change them in the watch table or here', L([
          'IF "Batch".Recipes[1].AmountA = 0.0 THEN',
          '    "Batch".Recipes[1].AmountA := 40.0; "Batch".Recipes[1].AmountB := 20.0; "Batch".Recipes[1].MixTime := T#5S;',
          '    "Batch".Recipes[2].AmountA := 25.0; "Batch".Recipes[2].AmountB := 50.0; "Batch".Recipes[2].MixTime := T#8S;',
          '    "Batch".Recipes[3].AmountA := 60.0; "Batch".Recipes[3].AmountB := 10.0; "Batch".Recipes[3].MixTime := T#3S;',
          'END_IF;']));
        Scl(B, 'Step chain', 'with a variable index into the recipes', L([
          'VAR_TEMP',
          '    r : Int;',
          'END_VAR',
          '#r := LIMIT(MN := 1, IN := "Batch".Select, MX := 3);',
          'CASE "Batch".Step OF',
          '    0: IF "Start_PB" THEN',
          '           "Batch".Target := "Batch".Recipes[#r].AmountA;',
          '           "Batch".Step := 1;',
          '       END_IF;',
          '    1: IF "Batch".Level >= "Batch".Target THEN',
          '           "Batch".Target := "Batch".Target + "Batch".Recipes[#r].AmountB;',
          '           "Batch".Step := 2;',
          '       END_IF;',
          '    2: IF "Batch".Level >= "Batch".Target THEN "Batch".Step := 3; END_IF;',
          '    3: IF "Batch".MixT.Q THEN "Batch".Step := 4; END_IF;',
          '    4: IF "Batch".Level <= 0.0 THEN',
          '           "Batch".Step := 0;',
          '           "Batch".Batches := "Batch".Batches + 1;',
          '       END_IF;',
          'END_CASE;',
          '"Batch".MixT.TON(IN := "Batch".Step = 3, PT := "Batch".Recipes[#r].MixTime);',
          '"Valve_A" := "Batch".Step = 1;',
          '"Valve_B" := "Batch".Step = 2;',
          '"Mixer" := "Batch".Step = 3;',
          '"Drain" := "Batch".Step = 4;',
          '"Ready" := "Batch".Step = 0;']));
        B := P.AddBlock(bkOB, P.CyclicOB, 'Tank simulation');
        B.Comment := 'every 100 ms: 2 l in, 3 l out';
        Scl(B, 'The tank', 'the valves fill and drain it', L([
          'IF "Valve_A" OR "Valve_B" THEN "Batch".Level := "Batch".Level + 2.0; END_IF;',
          'IF "Drain" THEN "Batch".Level := "Batch".Level - 3.0; END_IF;',
          'IF "Batch".Level < 0.0 THEN "Batch".Level := 0.0; END_IF;']));
        P.CyclicMs := 100;
        P.AddWatch('"Batch".Select', dfDec, '2');
        P.AddWatch('"Batch".Step', dfDec);
        P.AddWatch('"Batch".Level', dfReal);
        P.AddWatch('"Batch".Batches', dfDec);
      end;

    12: // ---------- parking garage ----------
      begin
        Start(7, 'Parking garage counter (S7-1200)',
          'LAD: CTUD counts the cars in (I0.0) and out (I0.1); 20 places: Full (Q0.1) stops the barrier, ' +
          'Free (Q0.0) is on while places are left; Reset (I0.2) empties the count.');
        P.AddTag('Car_In', 'Bool', '%I0.0', 'sensor at the entrance');
        P.AddTag('Car_Out', 'Bool', '%I0.1', 'sensor at the exit');
        P.AddTag('Reset_PB', 'Bool', '%I0.2', 'reset the count');
        P.AddTag('Free_Lamp', 'Bool', '%Q0.0', 'places free');
        P.AddTag('Full_Lamp', 'Bool', '%Q0.1', 'garage full');
        P.AddTag('Barrier_Up', 'Bool', '%Q0.2', 'entrance barrier open');
        Push(0);
        Push(1);
        Push(2);
        D := P.AddDB(1, 'Garage');
        D.AddVar('Cars', 'IEC_COUNTER', '', 'up / down counter');
        D.AddVar('Count', 'Int', '0', 'cars inside');
        B := P.Block(0);
        LadNet(B, 'Count the cars', 'CTUD: CU in, CD out, PV 20 places: QU = full', 1);
        Lad(0, 0, lkNO, '"Car_In"');
        Ce := NewCell(lkCTUD, '"Garage".Cars');
        Ce.P[0] := '20';
        Ce.P[1] := '"Car_Out"';
        Ce.P[2] := '"Reset_PB"';
        Ce.P[3] := '';
        Ce.P[4] := '"Garage".Count';
        N.SetCell(0, 1, Ce);
        Wires(0, 2, 6);
        Lad(0, 7, lkCoil, '"Full_Lamp"');
        LadNet(B, 'Free places', '', 1);
        Lad(0, 0, lkNC, '"Full_Lamp"');
        Wires(0, 1, 6);
        Lad(0, 7, lkCoil, '"Free_Lamp"');
        LadNet(B, 'Barrier', 'opens for a car in while not full', 1);
        Lad(0, 0, lkNO, '"Car_In"');
        Lad(0, 1, lkNC, '"Full_Lamp"');
        Wires(0, 2, 6);
        Lad(0, 7, lkCoil, '"Barrier_Up"');
        P.AddWatch('"Garage".Count', dfDec);
      end;

    13: // ---------- alarm handling ----------
      begin
        Start(7, 'Alarm handling with acknowledge (S7-1200)',
          'SCL: four alarm inputs (I0.0..I0.3) are latched; a new alarm flashes its lamp and sounds the horn until ' +
          'Acknowledge (I0.4); an acknowledged alarm that is still there shows steady; it clears when it is gone.');
        P.AddTag('Alarm_1', 'Bool', '%I0.0', 'switch: alarm 1');
        P.AddTag('Alarm_2', 'Bool', '%I0.1', 'switch: alarm 2');
        P.AddTag('Alarm_3', 'Bool', '%I0.2', 'switch: alarm 3');
        P.AddTag('Alarm_4', 'Bool', '%I0.3', 'switch: alarm 4');
        P.AddTag('Ack_PB', 'Bool', '%I0.4', 'acknowledge');
        P.AddTag('Lamp_1', 'Bool', '%Q0.0', 'alarm lamp 1');
        P.AddTag('Lamp_2', 'Bool', '%Q0.1', 'alarm lamp 2');
        P.AddTag('Lamp_3', 'Bool', '%Q0.2', 'alarm lamp 3');
        P.AddTag('Lamp_4', 'Bool', '%Q0.3', 'alarm lamp 4');
        P.AddTag('Horn', 'Bool', '%Q0.4', 'horn');
        Push(4);
        D := P.AddDB(1, 'Alarms');
        D.AddVar('Active', 'Array[0..3] of Bool', '', 'the input is there');
        D.AddVar('Unacked', 'Array[0..3] of Bool', '', 'not acknowledged yet');
        D.AddVar('Stored', 'Array[0..3] of Bool', '', 'latched');
        D.AddVar('Lamp', 'Array[0..3] of Bool', '', 'lamp state');
        B := P.Block(0);
        Scl(B, 'Alarms', 'the inputs into an array, one loop for the four alarms, the lamps out', L([
          'VAR_TEMP',
          '    i : Int;',
          '    any : Bool;',
          'END_VAR',
          '"Alarms".Active[0] := "Alarm_1";',
          '"Alarms".Active[1] := "Alarm_2";',
          '"Alarms".Active[2] := "Alarm_3";',
          '"Alarms".Active[3] := "Alarm_4";',
          '#any := FALSE;',
          'FOR #i := 0 TO 3 DO',
          '    IF "Alarms".Active[#i] AND NOT "Alarms".Stored[#i] THEN',
          '        "Alarms".Stored[#i] := TRUE;',
          '        "Alarms".Unacked[#i] := TRUE;',
          '    END_IF;',
          '    IF "Ack_PB" THEN "Alarms".Unacked[#i] := FALSE; END_IF;',
          '    IF NOT "Alarms".Active[#i] AND NOT "Alarms".Unacked[#i] THEN "Alarms".Stored[#i] := FALSE; END_IF;',
          '    "Alarms".Lamp[#i] := ("Alarms".Unacked[#i] AND "Clock_2Hz") OR ("Alarms".Stored[#i] AND NOT "Alarms".Unacked[#i]);',
          '    #any := #any OR "Alarms".Unacked[#i];',
          'END_FOR;',
          '"Lamp_1" := "Alarms".Lamp[0];',
          '"Lamp_2" := "Alarms".Lamp[1];',
          '"Lamp_3" := "Alarms".Lamp[2];',
          '"Lamp_4" := "Alarms".Lamp[3];',
          '"Horn" := #any;']));
        P.AddWatch('"Alarms".Unacked[0]', dfBool);
        P.AddWatch('"Horn"', dfBool);
      end;

    14: // ---------- running light ----------
      begin
        Start(7, 'Running light (S7-1200)',
          'SCL: a byte of lamps (QB0) runs left or right (I0.1) with a TON as the clock; Fast (I0.2) halves the ' +
          'time; Run (I0.0) starts it.');
        P.AddTag('Run_On', 'Bool', '%I0.0', 'switch: run');
        P.AddTag('Right', 'Bool', '%I0.1', 'switch: to the right');
        P.AddTag('Fast', 'Bool', '%I0.2', 'switch: fast');
        P.AddTag('Lights', 'Byte', '%QB0', 'eight lamps Q0.0..Q0.7');
        D := P.AddDB(1, 'Chaser');
        D.AddVar('Pattern', 'Byte', '16#01', 'the lamp that is on');
        D.AddVar('Tick', 'IEC_TIMER', '', 'the step clock');
        D.AddVar('Period', 'Time', 'T#500MS', 'time of a step');
        B := P.Block(0);
        Scl(B, 'Chaser', 'ROL / ROR move the one bit around', L([
          'IF "Fast" THEN "Chaser".Period := T#250MS; ELSE "Chaser".Period := T#500MS; END_IF;',
          '"Chaser".Tick.TON(IN := "Run_On" AND NOT "Chaser".Tick.Q, PT := "Chaser".Period);',
          'IF "Chaser".Pattern = 0 THEN "Chaser".Pattern := 16#01; END_IF;',
          'IF "Chaser".Tick.Q THEN',
          '    IF "Right" THEN',
          '        "Chaser".Pattern := ROR(IN := "Chaser".Pattern, N := 1);',
          '    ELSE',
          '        "Chaser".Pattern := ROL(IN := "Chaser".Pattern, N := 1);',
          '    END_IF;',
          'END_IF;',
          'IF "Run_On" THEN "Lights" := "Chaser".Pattern; ELSE "Lights" := 0; END_IF;']));
        P.AddWatch('"Lights"', dfBin);
      end;

    15: // ---------- temperature control ----------
      begin
        Start(13, 'Temperature control with PWM heating (S7-1500)',
          'SCL: the temperature (IW4, 0..27648 = 0..150 °C) is compared with the setpoint; the heater runs as PWM ' +
          'in a 2 s period with a duty from the error (P control); above 120 °C the alarm switches the heater off.');
        P.AddTag('Temp_AI', 'Int', '%IW4', 'temperature 0..150 °C');
        P.AddTag('Enable', 'Bool', '%I0.0', 'switch: control on');
        P.AddTag('Heater', 'Bool', '%Q0.0', 'heater');
        P.AddTag('Over_Temp', 'Bool', '%Q0.1', 'temperature too high');
        P.AIch[0].AiValue := 9000;
        D := P.AddDB(1, 'Temp');
        D.AddVar('Actual', 'Real', '0.0', '°C');
        D.AddVar('Setpoint', 'Real', '60.0', '°C');
        D.AddVar('Gain', 'Real', '5.0', '% duty per °C');
        D.AddVar('Duty', 'Real', '0.0', '0..100 %');
        D.AddVar('Cycle', 'IEC_TIMER', '', 'the PWM period');
        B := P.Block(0);
        Scl(B, 'Measure and control', 'P control: duty = gain * (setpoint - actual), 0..100 %', L([
          '"Temp".Actual := SCALE_X(MIN := 0.0, VALUE := NORM_X(MIN := 0, VALUE := "Temp_AI", MAX := 27648), MAX := 150.0);',
          '"Temp".Duty := LIMIT(MN := 0.0, IN := "Temp".Gain * ("Temp".Setpoint - "Temp".Actual), MX := 100.0);',
          '"Over_Temp" := "Temp".Actual > 120.0;']));
        Scl(B, 'PWM heater', 'on for duty % of every 2 s', L([
          '"Temp".Cycle.TON(IN := NOT "Temp".Cycle.Q, PT := T#2S);',
          '"Heater" := "Enable" AND NOT "Over_Temp" AND (TIME_TO_DINT("Temp".Cycle.ET) < REAL_TO_DINT("Temp".Duty * 20.0));']));
        P.AddWatch('"Temp".Actual', dfReal);
        P.AddWatch('"Temp".Setpoint', dfReal, '80.0');
        P.AddWatch('"Temp".Duty', dfReal);
        P.AddWatch('"Heater"', dfBool);
      end;

    16: // ---------- STL basics ----------
      begin
        Start(1, 'STL basics: logic, timer, counter, math (S7-300)',
          'STL step by step: AND / OR, a pulse timer S_PULSE (SP T2), a counter C1 with compare, integer and ' +
          'real math, and a jump. I0.0..I0.3 are the inputs, see the network comments.');
        P.AddTag('In_A', 'Bool', 'I0.0', 'input A');
        P.AddTag('In_B', 'Bool', 'I0.1', 'input B');
        P.AddTag('Count_PB', 'Bool', 'I0.2', 'count');
        P.AddTag('Reset_PB', 'Bool', 'I0.3', 'reset the counter');
        P.AddTag('And_Out', 'Bool', 'Q4.0', 'A AND B');
        P.AddTag('Or_Out', 'Bool', 'Q4.1', 'A OR B');
        P.AddTag('Pulse_Out', 'Bool', 'Q4.2', '3 s pulse on A');
        P.AddTag('Five_Out', 'Bool', 'Q4.3', 'counter >= 5');
        Push(2);
        Push(3);
        B := P.Block(0);
        Stl(B, 'Bit logic', 'A, AN, O, =', L([
          'A     "In_A"',
          'A     "In_B"',
          '=     "And_Out"',
          'A     "In_A"',
          'O     "In_B"',
          '=     "Or_Out"']));
        Stl(B, 'Pulse timer', 'SP T2: 3 s pulse when A comes', L([
          'A     "In_A"',
          'L     S5T#3S',
          'SP    T     2',
          'A     T     2',
          '=     "Pulse_Out"']));
        Stl(B, 'Counter and compare', 'CU C1 on Count, R on Reset; >= 5 sets Five_Out', L([
          'A     "Count_PB"',
          'CU    C     1',
          'A     "Reset_PB"',
          'R     C     1',
          'L     C     1',
          'T     MW20',
          'L     MW20',
          'L     5',
          '>=I',
          '=     "Five_Out"']));
        Stl(B, 'Math', 'MW22 = MW20 * 10 + 7; MD24 = MW22 as REAL / 4.0', L([
          'L     MW20',
          'L     10',
          '*I',
          'L     7',
          '+I',
          'T     MW22',
          'L     MW22',
          'ITD',
          'DTR',
          'L     4.0',
          '/R',
          'T     MD24']));
        Stl(B, 'A jump', 'when A is off, MW30 is not counted', L([
          'AN    "In_A"',
          'JC    SKIP',
          'L     MW30',
          '+     1',
          'T     MW30',
          'SKIP: NOP   0']));
        P.AddWatch('C1', dfCounter);
        P.AddWatch('MW20', dfDec);
        P.AddWatch('MW22', dfDec);
        P.AddWatch('MD24', dfReal);
        P.AddWatch('MW30', dfDec);
      end;

    17: // ---------- hand / auto ----------
      begin
        Start(5, 'Hand / auto mode with jog and interlocks (S7-400)',
          'LAD and STL: a mode switch (I0.0 = auto), in hand the motor jogs while I0.1 is held, in auto it follows ' +
          'the level switch I0.2; the guard (I0.3, NC) blocks both; OB35 counts the run time in 100 ms.');
        P.AddTag('Auto_Mode', 'Bool', 'I0.0', 'switch: 1 = auto, 0 = hand');
        P.AddTag('Jog_PB', 'Bool', 'I0.1', 'jog in hand mode');
        P.AddTag('Level_Low', 'Bool', 'I0.2', 'switch: level low (auto start)');
        P.AddTag('Guard_OK', 'Bool', 'I0.3', 'guard closed, NC');
        P.AddTag('Motor', 'Bool', 'Q4.0', 'motor');
        P.AddTag('Auto_Lamp', 'Bool', 'Q4.1', 'auto mode');
        P.AddTag('Hand_Lamp', 'Bool', 'Q4.2', 'hand mode');
        Push(1);
        Push(3, True);
        B := P.Block(0);
        LadNet(B, 'Motor', 'hand: jog; auto: the level switch; the guard always', 2);
        Lad(0, 0, lkNC, '"Auto_Mode"');
        Lad(0, 1, lkNO, '"Jog_PB"', True);
        Lad(0, 2, lkNO, '"Guard_OK"');
        Wires(0, 3, 6);
        Lad(0, 7, lkCoil, '"Motor"');
        Lad(1, 0, lkNO, '"Auto_Mode"');
        Lad(1, 1, lkNO, '"Level_Low"');
        Stl(B, 'Mode lamps', '', L([
          'A     "Auto_Mode"',
          '=     "Auto_Lamp"',
          'AN    "Auto_Mode"',
          '=     "Hand_Lamp"']));
        B := P.AddBlock(bkOB, P.CyclicOB, 'Run time');
        B.Comment := 'every 100 ms';
        Stl(B, 'Run time in 100 ms', 'MD100 counts while the motor runs', L([
          'AN    "Motor"',
          'JC    END',
          'L     MD100',
          '+     L#1',
          'T     MD100',
          'END:  NOP   0']));
        P.AddWatch('MD100', dfDec);
        P.AddWatch('"Motor"', dfBool);
      end;

    18: Timers(7);
    19: Counters(7);
    20: Timers(13);
    21: Counters(13);
    22: Timers(1);
    23: Counters(1);
    24: Timers(5);
    25: Counters(5);

    26: // ---------- data type conversion (SCL + LAD) ----------
      begin
        Start(7, 'Data type conversion: Real, Int, DInt, Word, DWord (S7-1200)',
          'SCL and LAD: the analog input as Int -> Real volts and back; Real -> DInt with ROUND, TRUNC, CEIL, ' +
          'FLOOR; a DInt that does not fit an Int; Word / DWord bit patterns as Int / DInt. Change the start ' +
          'values in the watch table (Modify) and watch the results.');
        P.AddTag('AI_Raw', 'Int', '%IW64', 'analog input 0..27648 = 0..10 V');
        D := P.AddDB(1, 'Conv');
        D.AddVar('Raw', 'Int', '0', 'the analog input');
        D.AddVar('Volts', 'Real', '0.0', 'INT_TO_REAL * 10 / 27648');
        D.AddVar('Back_Int', 'Int', '0', 'REAL_TO_INT (rounds)');
        D.AddVar('Raw_Real', 'Real', '0.0', 'LAD CONV Int -> Real');
        D.AddVar('Value', 'Real', '2.5', 'try 2.5, -2.5, 2.7');
        D.AddVar('Rnd', 'DInt', '0', 'ROUND: to the nearest (a half to the even number)');
        D.AddVar('Trc', 'DInt', '0', 'TRUNC: the fraction goes');
        D.AddVar('Cei', 'DInt', '0', 'CEIL: up');
        D.AddVar('Flo', 'DInt', '0', 'FLOOR: down');
        D.AddVar('Lad_Rnd', 'Int', '0', 'LAD ROUND Real -> Int');
        D.AddVar('Big', 'DInt', '70000', 'more than an Int holds');
        D.AddVar('Big_To_Int', 'Int', '0', 'DINT_TO_INT: the low 16 bits (4464)');
        D.AddVar('Big_To_Real', 'Real', '0.0', 'DINT_TO_REAL');
        D.AddVar('W', 'Word', '16#FFFF', 'a bit pattern');
        D.AddVar('W_To_Int', 'Int', '0', 'WORD_TO_INT: 16#FFFF = -1');
        D.AddVar('Neg', 'Int', '-1', 'a negative Int');
        D.AddVar('Int_To_W', 'Word', '16#0', 'INT_TO_WORD: -1 = 16#FFFF');
        D.AddVar('W_To_DW', 'DWord', '16#0', 'WORD_TO_DWORD: 16#0000_FFFF');
        D.AddVar('DW', 'DWord', '16#10000', 'a double word');
        D.AddVar('DW_To_DInt', 'DInt', '0', 'DWORD_TO_DINT: 65536');
        D.AddVar('DInt_To_DW', 'DWord', '16#0', 'DINT_TO_DWORD of Big');
        D.AddVar('Real_To_W', 'Word', '16#0', 'REAL_TO_WORD of Volts * 1000');
        B := P.Block(0);
        Scl(B, 'Analog input: Int -> Real volts -> Int', 'INT_TO_REAL before the division, REAL_TO_INT rounds', L([
          '"Conv".Raw := "AI_Raw";',
          '"Conv".Volts := INT_TO_REAL("Conv".Raw) * 10.0 / 27648.0;',
          '"Conv".Back_Int := REAL_TO_INT("Conv".Volts * 2764.8);']));
        Scl(B, 'Real -> DInt: ROUND, TRUNC, CEIL, FLOOR',
          'Value 2.5 gives 2, 2, 3, 2 (ROUND: a half to the even); 2.7 gives 3, 2, 3, 2; -2.5 gives -2, -2, -2, -3', L([
          '"Conv".Rnd := ROUND("Conv".Value);',
          '"Conv".Trc := TRUNC("Conv".Value);',
          '"Conv".Cei := CEIL("Conv".Value);',
          '"Conv".Flo := FLOOR("Conv".Value);']));
        Scl(B, 'Integer widths: DInt -> Int, DInt -> Real', 'an Int holds -32768..32767: 70000 keeps its low 16 bits', L([
          '"Conv".Big_To_Int := DINT_TO_INT("Conv".Big);',
          '"Conv".Big_To_Real := DINT_TO_REAL("Conv".Big);']));
        Scl(B, 'Bit patterns: Word / DWord <-> Int / DInt', 'the bits stay, only their meaning changes', L([
          '"Conv".W_To_Int := WORD_TO_INT("Conv".W);',
          '"Conv".Int_To_W := INT_TO_WORD("Conv".Neg);',
          '"Conv".W_To_DW := WORD_TO_DWORD("Conv".W);',
          '"Conv".DW_To_DInt := DWORD_TO_DINT("Conv".DW);',
          '"Conv".DInt_To_DW := DINT_TO_DWORD("Conv".Big);',
          '"Conv".Real_To_W := REAL_TO_WORD("Conv".Volts * 1000.0);']));
        LadNet(B, 'LAD: CONV Int -> Real', 'the same as INT_TO_REAL', 1);
        Conv(0, 0, lkConv, dtInt, dtReal, '"Conv".Raw', '"Conv".Raw_Real');
        LadNet(B, 'LAD: ROUND Real -> Int', 'the same as REAL_TO_INT', 1);
        Conv(0, 0, lkRound, dtReal, dtInt, '"Conv".Value', '"Conv".Lad_Rnd');
        P.AddWatch('"Conv".Raw', dfDec);
        P.AddWatch('"Conv".Volts', dfReal);
        P.AddWatch('"Conv".Value', dfReal, '-2.5');
        P.AddWatch('"Conv".Rnd', dfDec);
        P.AddWatch('"Conv".Trc', dfDec);
        P.AddWatch('"Conv".Cei', dfDec);
        P.AddWatch('"Conv".Flo', dfDec);
        P.AddWatch('"Conv".Big_To_Int', dfDec);
        P.AddWatch('"Conv".W_To_Int', dfDec);
        P.AddWatch('"Conv".Int_To_W', dfHex);
        P.AddWatch('"Conv".DW_To_DInt', dfDec);
      end;

    27: // ---------- data type conversion in STL ----------
      begin
        Start(1, 'Data type conversion in STL (S7-300)',
          'STL: the accumulator converts: ITD (Int -> DInt), DTR (DInt -> Real), RND / TRUNC / RND+ / RND- ' +
          '(Real -> DInt), ITB / BTI (BCD), and a Word is an Int with the same 16 bits. The analog input PIW288 ' +
          'is the source; MD40 is a Real you can modify in the watch table.');
        P.AddTag('AI_Raw', 'Int', 'PIW288', 'analog input 0..27648');
        P.AddTag('Raw_Int', 'Int', 'MW10', 'the input');
        P.AddTag('Raw_DInt', 'DInt', 'MD12', 'ITD');
        P.AddTag('Raw_Real', 'Real', 'MD16', 'DTR');
        P.AddTag('Volts', 'Real', 'MD20', 'Real * 10 / 27648');
        P.AddTag('Value', 'Real', 'MD40', 'modify: 2.5, -2.5, 2.7');
        P.AddTag('Rnd', 'DInt', 'MD44', 'RND');
        P.AddTag('Trc', 'DInt', 'MD48', 'TRUNC');
        P.AddTag('Up', 'DInt', 'MD52', 'RND+');
        P.AddTag('Down', 'DInt', 'MD56', 'RND-');
        P.AddTag('Bcd', 'Word', 'MW60', 'ITB of 123: W#16#0123');
        P.AddTag('From_Bcd', 'Int', 'MW62', 'BTI back: 123');
        P.AddTag('Pattern', 'Word', 'MW64', 'W#16#FFFF');
        P.AddTag('As_Int', 'Int', 'MW66', 'the same bits: -1');
        B := P.Block(0);
        Stl(B, 'Int -> DInt -> Real -> volts', 'ITD widens, DTR makes a Real; the division in Real', L([
          'L     "AI_Raw"',
          'T     "Raw_Int"',
          'ITD                         // Int -> DInt',
          'T     "Raw_DInt"',
          'DTR                         // DInt -> Real',
          'T     "Raw_Real"',
          'L     1.000000e+001',
          '*R',
          'L     2.764800e+004',
          '/R',
          'T     "Volts"']));
        Stl(B, 'Real -> DInt: RND, TRUNC, RND+, RND-', 'modify "Value" (MD40) in the watch table', L([
          'L     "Value"',
          'RND                         // to the nearest (a half to the even)',
          'T     "Rnd"',
          'L     "Value"',
          'TRUNC                       // the fraction goes',
          'T     "Trc"',
          'L     "Value"',
          'RND+                        // up',
          'T     "Up"',
          'L     "Value"',
          'RND-                        // down',
          'T     "Down"']));
        Stl(B, 'BCD and bit patterns', 'ITB / BTI: Int <-> BCD (3 digits: -999..999); a Word loaded as an Int', L([
          'L     123',
          'ITB                         // Int -> BCD (W#16#0123)',
          'T     "Bcd"',
          'BTI                         // BCD -> Int',
          'T     "From_Bcd"',
          'L     W#16#FFFF',
          'T     "Pattern"',
          'L     "Pattern"',
          'T     "As_Int"                // the same 16 bits: -1']));
        P.AddWatch('"Raw_Int"', dfDec);
        P.AddWatch('"Volts"', dfReal);
        P.AddWatch('"Value"', dfReal, '-2.5');
        P.AddWatch('"Rnd"', dfDec);
        P.AddWatch('"Trc"', dfDec);
        P.AddWatch('"Up"', dfDec);
        P.AddWatch('"Down"', dfDec);
        P.AddWatch('"Bcd"', dfHex);
        P.AddWatch('"As_Int"', dfDec);
      end;

    28: // ---------- math ----------
      begin
        Start(7, 'Math: arithmetic, functions, trigonometry (S7-1200)',
          'SCL and LAD: Int division and MOD, Real arithmetic, SQRT / SQR / EXP / LN / LOG, SIN / COS / TAN in ' +
          'degrees, MIN / MAX / LIMIT / ABS, the average of an array with FOR, a polynomial, and the LAD boxes ' +
          'ADD / SUB / MUL / DIV. Modify A, B, X, Y, R, Angle in the watch table.');
        D := P.AddDB(1, 'Math');
        D.AddVar('A', 'Int', '7', 'Int operand');
        D.AddVar('B', 'Int', '3', 'Int operand');
        D.AddVar('Sum', 'Int', '0', 'A + B');
        D.AddVar('Diff', 'Int', '0', 'A - B');
        D.AddVar('Prod', 'Int', '0', 'A * B');
        D.AddVar('Quot', 'Int', '0', 'A / B: Int division (2)');
        D.AddVar('Rest', 'Int', '0', 'A MOD B (1)');
        D.AddVar('X', 'Real', '3.0', 'Real operand');
        D.AddVar('Y', 'Real', '4.0', 'Real operand');
        D.AddVar('Hyp', 'Real', '0.0', 'SQRT(X*X + Y*Y): 5');
        D.AddVar('Ratio', 'Real', '0.0', 'X / Y');
        D.AddVar('Pow', 'Real', '0.0', 'X ** 3');
        D.AddVar('R', 'Real', '2.0', 'radius');
        D.AddVar('Area', 'Real', '0.0', 'pi * R * R');
        D.AddVar('Angle', 'Real', '30.0', 'degrees');
        D.AddVar('SinA', 'Real', '0.0', 'SIN: 0.5');
        D.AddVar('CosA', 'Real', '0.0', 'COS');
        D.AddVar('TanA', 'Real', '0.0', 'TAN');
        D.AddVar('Root2', 'Real', '0.0', 'SQRT(2)');
        D.AddVar('Sq', 'Real', '0.0', 'SQR(1.5)');
        D.AddVar('E1', 'Real', '0.0', 'EXP(1)');
        D.AddVar('Ln10', 'Real', '0.0', 'LN(10)');
        D.AddVar('Log1000', 'Real', '0.0', 'LOG(1000): 3');
        D.AddVar('Frac', 'Real', '0.0', 'FRAC(X / Y)');
        D.AddVar('MinAB', 'Int', '0', 'MIN');
        D.AddVar('MaxAB', 'Int', '0', 'MAX');
        D.AddVar('Lim', 'Int', '0', 'LIMIT(0, A * B, 20)');
        D.AddVar('AbsV', 'Real', '0.0', 'ABS(X - Y)');
        D.AddVar('Vals', 'Array[1..5] of Real', '', 'five values for the average');
        D.AddVar('Avg', 'Real', '0.0', 'the average of Vals');
        D.AddVar('Poly', 'Real', '0.0', '2 X^2 - 3 X + 1');
        D.AddVar('Lad_Sum', 'Int', '0', 'LAD ADD');
        D.AddVar('Big', 'DInt', '100000', 'a DInt operand');
        D.AddVar('Lad_Diff', 'DInt', '0', 'LAD SUB: Big - 70000');
        D.AddVar('Lad_Prod', 'Real', '0.0', 'LAD MUL');
        D.AddVar('Lad_Quot', 'Real', '0.0', 'LAD DIV');
        B := P.Block(0);
        Scl(B, 'Integer arithmetic', 'Int / Int is an Int division, MOD the rest', L([
          '"Math".Sum := "Math".A + "Math".B;',
          '"Math".Diff := "Math".A - "Math".B;',
          '"Math".Prod := "Math".A * "Math".B;',
          '"Math".Quot := "Math".A / "Math".B;',
          '"Math".Rest := "Math".A MOD "Math".B;']));
        Scl(B, 'Real arithmetic and geometry', 'Pythagoras, a circle, a power', L([
          '"Math".Hyp := SQRT("Math".X * "Math".X + "Math".Y * "Math".Y);',
          '"Math".Ratio := "Math".X / "Math".Y;',
          '"Math".Pow := "Math".X ** 3.0;',
          '"Math".Area := 3.14159265 * "Math".R * "Math".R;']));
        Scl(B, 'Trigonometry in degrees', 'SIN / COS / TAN take radians', L([
          'VAR_TEMP',
          '    rad : Real;',
          'END_VAR',
          '#rad := "Math".Angle * 3.14159265 / 180.0;',
          '"Math".SinA := SIN(#rad);',
          '"Math".CosA := COS(#rad);',
          '"Math".TanA := TAN(#rad);']));
        Scl(B, 'Roots, powers, logarithms', '', L([
          '"Math".Root2 := SQRT(2.0);',
          '"Math".Sq := SQR(1.5);',
          '"Math".E1 := EXP(1.0);',
          '"Math".Ln10 := LN(10.0);',
          '"Math".Log1000 := LOG(1000.0);',
          '"Math".Frac := FRAC("Math".X / "Math".Y);']));
        Scl(B, 'MIN, MAX, LIMIT, ABS', '', L([
          '"Math".MinAB := MIN(IN1 := "Math".A, IN2 := "Math".B);',
          '"Math".MaxAB := MAX(IN1 := "Math".A, IN2 := "Math".B);',
          '"Math".Lim := LIMIT(MN := 0, IN := "Math".A * "Math".B, MX := 20);',
          '"Math".AbsV := ABS("Math".X - "Math".Y);']));
        Scl(B, 'The average of an array, a polynomial', 'FOR over Vals[1..5]; Horner: (2 X - 3) X + 1', L([
          'VAR_TEMP',
          '    i : Int;',
          '    sum : Real;',
          'END_VAR',
          'FOR #i := 1 TO 5 DO',
          '    "Math".Vals[#i] := INT_TO_REAL(#i) * 1.5;',
          'END_FOR;',
          '#sum := 0.0;',
          'FOR #i := 1 TO 5 DO',
          '    #sum := #sum + "Math".Vals[#i];',
          'END_FOR;',
          '"Math".Avg := #sum / 5.0;',
          '"Math".Poly := (2.0 * "Math".X - 3.0) * "Math".X + 1.0;']));
        LadNet(B, 'LAD: ADD Int', '', 1);
        Box(0, 0, lkAdd, '', '"Math".A', '"Math".B', '"Math".Lad_Sum', dtInt);
        LadNet(B, 'LAD: SUB DInt', '', 1);
        Box(0, 0, lkSub, '', '"Math".Big', '70000', '"Math".Lad_Diff', dtDInt);
        LadNet(B, 'LAD: MUL Real', '', 1);
        Box(0, 0, lkMul, '', '"Math".X', '"Math".Y', '"Math".Lad_Prod', dtReal);
        LadNet(B, 'LAD: DIV Real', '', 1);
        Box(0, 0, lkDiv, '', '"Math".X', '"Math".Y', '"Math".Lad_Quot', dtReal);
        P.AddWatch('"Math".A', dfDec, '17');
        P.AddWatch('"Math".Quot', dfDec);
        P.AddWatch('"Math".Rest', dfDec);
        P.AddWatch('"Math".Hyp', dfReal);
        P.AddWatch('"Math".Angle', dfReal, '45.0');
        P.AddWatch('"Math".SinA', dfReal);
        P.AddWatch('"Math".Log1000', dfReal);
        P.AddWatch('"Math".Avg', dfReal);
        P.AddWatch('"Math".Poly', dfReal);
      end;

    29: // ---------- a large FB: motor control ----------
      begin
        Start(13, 'Large FB: motor control with state machine, 3 instances (S7-1500)',
          'FB1 "MotorCtrl" (SCL, 4 networks): hand / auto, interlock, start warning time, contactor feedback ' +
          'monitoring, overload, fault codes with reset, start counter, run seconds, a lamp that tells the state. ' +
          'OB1 calls it for three motors (DB1..DB3); motor 2 needs motor 1 running, motor 3 needs motor 2. ' +
          'Hand: press Mx_Start, switch Mx_Feedback on within 3 s. Auto: Auto_Mode on, Auto_Cmd on.');
        P.AddTag('M1_Start', 'Bool', '%I0.0', 'motor 1 start (hand)');
        P.AddTag('M1_Stop', 'Bool', '%I0.1', 'motor 1 stop (hand)');
        P.AddTag('M1_Feedback', 'Bool', '%I0.2', 'motor 1 contactor feedback');
        P.AddTag('M1_Overload', 'Bool', '%I0.3', 'motor 1 overload tripped');
        P.AddTag('M2_Start', 'Bool', '%I0.4', 'motor 2 start (hand)');
        P.AddTag('M2_Stop', 'Bool', '%I0.5', 'motor 2 stop (hand)');
        P.AddTag('M2_Feedback', 'Bool', '%I0.6', 'motor 2 contactor feedback');
        P.AddTag('M2_Overload', 'Bool', '%I0.7', 'motor 2 overload tripped');
        P.AddTag('M3_Start', 'Bool', '%I1.0', 'motor 3 start (hand)');
        P.AddTag('M3_Stop', 'Bool', '%I1.1', 'motor 3 stop (hand)');
        P.AddTag('M3_Feedback', 'Bool', '%I1.2', 'motor 3 contactor feedback');
        P.AddTag('M3_Overload', 'Bool', '%I1.3', 'motor 3 overload tripped');
        P.AddTag('Auto_Mode', 'Bool', '%I1.4', 'switch: auto');
        P.AddTag('Auto_Cmd', 'Bool', '%I1.5', 'switch: the auto command');
        P.AddTag('Reset_PB', 'Bool', '%I1.6', 'fault reset');
        P.AddTag('M1_Run', 'Bool', '%Q0.0', 'motor 1 contactor');
        P.AddTag('M1_Lamp', 'Bool', '%Q0.1', 'motor 1 lamp');
        P.AddTag('M2_Run', 'Bool', '%Q0.2', 'motor 2 contactor');
        P.AddTag('M2_Lamp', 'Bool', '%Q0.3', 'motor 2 lamp');
        P.AddTag('M3_Run', 'Bool', '%Q0.4', 'motor 3 contactor');
        P.AddTag('M3_Lamp', 'Bool', '%Q0.5', 'motor 3 lamp');
        P.AddTag('Any_Fault', 'Bool', '%Q0.6', 'a motor has a fault');
        Push(0);
        Push(1);
        Push(4);
        Push(5);
        Push(8);
        Push(9);
        Push(14);
        B := P.AddBlock(bkFB, 1, 'MotorCtrl');
        B.Comment := 'one motor: demand, faults, state machine, run time';
        B.Iface.AddSecVar(vsInput, 'Auto', 'Bool', 'FALSE', 'TRUE: the auto command, FALSE: hand');
        B.Iface.AddSecVar(vsInput, 'AutoCmd', 'Bool', 'FALSE', 'run in auto');
        B.Iface.AddSecVar(vsInput, 'ManStart', 'Bool', 'FALSE', 'hand: start (push button)');
        B.Iface.AddSecVar(vsInput, 'ManStop', 'Bool', 'FALSE', 'hand: stop (push button)');
        B.Iface.AddSecVar(vsInput, 'Feedback', 'Bool', 'FALSE', 'the contactor answers');
        B.Iface.AddSecVar(vsInput, 'Overload', 'Bool', 'FALSE', 'the overload relay tripped');
        B.Iface.AddSecVar(vsInput, 'Interlock', 'Bool', 'TRUE', 'TRUE: allowed to run');
        B.Iface.AddSecVar(vsInput, 'Reset', 'Bool', 'FALSE', 'fault reset (rising edge)');
        B.Iface.AddSecVar(vsInput, 'StartDelay', 'Time', 'T#1S', 'start warning time');
        B.Iface.AddSecVar(vsInput, 'FbTimeout', 'Time', 'T#3S', 'feedback must come within');
        B.Iface.AddSecVar(vsOutput, 'Run', 'Bool', 'FALSE', 'the contactor');
        B.Iface.AddSecVar(vsOutput, 'Lamp', 'Bool', 'FALSE', 'off / 2 Hz starting / on / 1 Hz fault');
        B.Iface.AddSecVar(vsOutput, 'Fault', 'Bool', 'FALSE', 'a fault is present');
        B.Iface.AddSecVar(vsOutput, 'State', 'Int', '0', '0 stopped, 1 starting, 2 running, 3 fault');
        B.Iface.AddSecVar(vsOutput, 'FaultCode', 'Int', '0', '1 overload, 2 no feedback, 3 feedback without run');
        B.Iface.AddSecVar(vsOutput, 'Starts', 'DInt', '0', 'starts so far');
        B.Iface.AddSecVar(vsOutput, 'RunSeconds', 'DInt', '0', 'run seconds');
        B.Iface.AddSecVar(vsStatic, 'StartTmr', 'IEC_TIMER', '', 'the start warning');
        B.Iface.AddSecVar(vsStatic, 'FbTmr', 'IEC_TIMER', '', 'feedback missing');
        B.Iface.AddSecVar(vsStatic, 'GhostTmr', 'IEC_TIMER', '', 'feedback without a run command');
        B.Iface.AddSecVar(vsStatic, 'SecTmr', 'IEC_TIMER', '', 'one pulse per second');
        B.Iface.AddSecVar(vsStatic, 'ManLatch', 'Bool', 'FALSE', 'hand: start / stop latch');
        B.Iface.AddSecVar(vsStatic, 'ResetOld', 'Bool', 'FALSE', 'edge memory of Reset');
        B.Iface.AddSecVar(vsTemp, 'Want', 'Bool', '', 'the motor should run');
        Scl(B, 'Demand: hand or auto, interlock', 'hand: a latch of Start / Stop; auto: the command', L([
          'IF #ManStop OR #Auto THEN',
          '    #ManLatch := FALSE;',
          'ELSIF #ManStart THEN',
          '    #ManLatch := TRUE;',
          'END_IF;',
          'IF #Auto THEN',
          '    #Want := #AutoCmd;',
          'ELSE',
          '    #Want := #ManLatch;',
          'END_IF;',
          '#Want := #Want AND #Interlock;']));
        Scl(B, 'Faults: overload, feedback, reset', 'a fault stays until Reset (rising edge) when its cause is gone', L([
          '#FbTmr.TON(IN := #Run AND NOT #Feedback, PT := #FbTimeout);',
          '#GhostTmr.TON(IN := #Feedback AND NOT #Run, PT := #FbTimeout);',
          'IF #Overload THEN',
          '    #FaultCode := 1;',
          'ELSIF #FbTmr.Q THEN',
          '    #FaultCode := 2;',
          'ELSIF #GhostTmr.Q AND #FaultCode = 0 THEN',
          '    #FaultCode := 3;',
          'END_IF;',
          'IF #Reset AND NOT #ResetOld AND NOT #Overload THEN',
          '    #FaultCode := 0;',
          'END_IF;',
          '#ResetOld := #Reset;',
          '#Fault := #FaultCode <> 0;']));
        Scl(B, 'State machine', '0 stopped -> 1 starting (warning) -> 2 running; 3 fault', L([
          'CASE #State OF',
          '    0:  // stopped',
          '        IF #Want AND NOT #Fault THEN',
          '            #State := 1;',
          '        END_IF;',
          '    1:  // start warning',
          '        IF #Fault THEN',
          '            #State := 3;',
          '        ELSIF NOT #Want THEN',
          '            #State := 0;',
          '        ELSIF #StartTmr.Q THEN',
          '            #State := 2;',
          '            #Starts := #Starts + 1;',
          '        END_IF;',
          '    2:  // running',
          '        IF #Fault THEN',
          '            #State := 3;',
          '        ELSIF NOT #Want THEN',
          '            #State := 0;',
          '        END_IF;',
          'ELSE    // 3: fault, until it is reset',
          '    IF NOT #Fault THEN',
          '        #State := 0;',
          '        #ManLatch := FALSE;',
          '    END_IF;',
          'END_CASE;',
          '#StartTmr.TON(IN := #State = 1, PT := #StartDelay);',
          '#Run := #State = 2;']));
        Scl(B, 'Run time and lamp', 'the lamp: off, 2 Hz while starting, on while running, 1 Hz on a fault', L([
          '#SecTmr.TON(IN := #Run AND NOT #SecTmr.Q, PT := T#1S);',
          'IF #SecTmr.Q THEN',
          '    #RunSeconds := #RunSeconds + 1;',
          'END_IF;',
          'CASE #State OF',
          '    0: #Lamp := FALSE;',
          '    1: #Lamp := "Clock_2Hz";',
          '    2: #Lamp := TRUE;',
          'ELSE',
          '    #Lamp := "Clock_1Hz";',
          'END_CASE;']));
        for K := 1 to 3 do
        begin
          D := P.AddDB(K, Format('M%d_DB', [K]));
          D.InstanceOf := 1;
          D.Layout;
        end;
        B := P.Block(0);
        Scl(B, 'Three motors, one FB', 'motor 2 needs motor 1 running, motor 3 needs motor 2', L([
          '"M1_DB"(Auto := "Auto_Mode", AutoCmd := "Auto_Cmd", ManStart := "M1_Start", ManStop := "M1_Stop",',
          '        Feedback := "M1_Feedback", Overload := "M1_Overload", Interlock := TRUE, Reset := "Reset_PB",',
          '        Run => "M1_Run", Lamp => "M1_Lamp");',
          '"M2_DB"(Auto := "Auto_Mode", AutoCmd := "Auto_Cmd", ManStart := "M2_Start", ManStop := "M2_Stop",',
          '        Feedback := "M2_Feedback", Overload := "M2_Overload", Interlock := "M1_Run", Reset := "Reset_PB",',
          '        Run => "M2_Run", Lamp => "M2_Lamp");',
          '"M3_DB"(Auto := "Auto_Mode", AutoCmd := "Auto_Cmd", ManStart := "M3_Start", ManStop := "M3_Stop",',
          '        Feedback := "M3_Feedback", Overload := "M3_Overload", Interlock := "M2_Run", Reset := "Reset_PB",',
          '        Run => "M3_Run", Lamp => "M3_Lamp");']));
        LadNet(B, 'A fault lamp for all', 'the Fault outputs of the three instances', 3);
        Lad(0, 0, lkNO, '"M1_DB".Fault', True);
        Lad(1, 0, lkNO, '"M2_DB".Fault', True);
        Lad(2, 0, lkNO, '"M3_DB".Fault');
        Wires(0, 1, 6);
        Lad(0, 7, lkCoil, '"Any_Fault"');
        P.AddWatch('"M1_DB".State', dfDec);
        P.AddWatch('"M1_DB".FaultCode', dfDec);
        P.AddWatch('"M1_DB".Starts', dfDec);
        P.AddWatch('"M1_DB".RunSeconds', dfDec);
        P.AddWatch('"M2_DB".State', dfDec);
        P.AddWatch('"M3_DB".State', dfDec);
      end;
    30: // ---------- the SCL elements of the SCL Compiler ----------
      begin
        Start(13, 'SCL elements: literals, MUX, slices, 2D arrays, system FBs (S7-1500)',
          'SCL as in the SCL Compiler: typed literals (INT#, UDINT#, 8#, D#, TOD#), VAR CONSTANT, MUX, slices ' +
          '(.%X3, .%B1), a two-dimensional array with a start list, an FC that returns its value as #Name and ' +
          'is called with positional arguments, and the system FBs TON_TIME, CTU_INT, R_TRIG, F_TRIG, RS and SR ' +
          'as statics of an FB. I0.0 counts and starts the timer, I0.1 resets the RS / SR.');
        P.AddTag('Start', 'Bool', '%I0.0', 'push button: count, time, edges');
        P.AddTag('Reset', 'Bool', '%I0.1', 'push button: reset RS / SR');
        P.AddTag('Lamp_Time', 'Bool', '%Q0.0', 'TON_TIME: 2 s after Start');
        P.AddTag('Lamp_Count', 'Bool', '%Q0.1', 'CTU_INT: 3 presses');
        P.AddTag('Lamp_RS', 'Bool', '%Q0.2', 'RS: reset wins');
        P.AddTag('Lamp_SR', 'Bool', '%Q0.3', 'SR: set wins');
        Push(0);
        Push(1);
        D := P.AddDB(1, 'Elems');
        D.AddVar('Sel', 'Int', '1', 'MUX: K (0..2)');
        D.AddVar('Picked', 'Int', '0', 'MUX(K := Sel, 10, 20, 30)');
        D.AddVar('Status', 'Word', 'W#16#0', 'bits and a byte set by slices');
        D.AddVar('Bit11', 'Bool', 'FALSE', 'Status.%X11');
        D.AddVar('Big', 'UDInt', 'UDINT#4000000000', 'a UDInt literal');
        D.AddVar('Day', 'Date', 'D#2024-01-31', 'a Date literal');
        D.AddVar('Noon', 'Time_Of_Day', 'TOD#12:00:00', 'a Time_Of_Day literal');
        D.AddVar('Grid', 'Array[0..2, 1..3] of Int', '[1, 2, 3, 4(0), 9, 9]', 'two dimensions, a start list');
        D.AddVar('Sum', 'Int', '0', 'the sum of Grid');
        D.AddVar('Avg', 'Int', '0', '"Avg2"(Grid[0, 1], Grid[2, 3])');
        D.AddVar('Edges', 'Int', '0', 'rising edges of Start (R_TRIG)');
        D.AddVar('Falls', 'Int', '0', 'falling edges of Start (F_TRIG)');
        B := P.AddBlock(bkFC, 1, 'Avg2');
        B.Comment := 'the average of two Ints: the Return value is written as #Avg2';
        B.Iface.AddSecVar(vsInput, 'a', 'Int', '', '');
        B.Iface.AddSecVar(vsInput, 'b', 'Int', '', '');
        B.Iface.AddSecVar(vsReturn, 'Ret_Val', 'Int', '', 'the average');
        Scl(B, 'Average', 'TIA writes the function value as #<name of the FC>', '#Avg2 := (#a + #b) / 2;');
        B := P.AddBlock(bkFB, 1, 'Signals');
        B.Comment := 'the system FBs as statics: called as #name(..)';
        B.Iface.AddSecVar(vsInput, 'Go', 'Bool', 'FALSE', '');
        B.Iface.AddSecVar(vsInput, 'Clr', 'Bool', 'FALSE', '');
        B.Iface.AddSecVar(vsOutput, 'TimeUp', 'Bool', 'FALSE', '');
        B.Iface.AddSecVar(vsOutput, 'Counted', 'Bool', 'FALSE', '');
        B.Iface.AddSecVar(vsOutput, 'RsQ', 'Bool', 'FALSE', '');
        B.Iface.AddSecVar(vsOutput, 'SrQ', 'Bool', 'FALSE', '');
        B.Iface.AddSecVar(vsStatic, 'Delay', 'TON_TIME', '', 'on delay');
        B.Iface.AddSecVar(vsStatic, 'Presses', 'CTU_INT', '', 'counts up');
        B.Iface.AddSecVar(vsStatic, 'Up', 'R_TRIG', '', 'rising edge');
        B.Iface.AddSecVar(vsStatic, 'Down', 'F_TRIG', '', 'falling edge');
        B.Iface.AddSecVar(vsStatic, 'Rs', 'RS', '', 'reset dominant');
        B.Iface.AddSecVar(vsStatic, 'Sr', 'SR', '', 'set dominant');
        Scl(B, 'System FBs', 'TON_TIME, CTU_INT, R_TRIG, F_TRIG, RS, SR', L([
          '#Delay(IN := #Go, PT := T#2S, Q => #TimeUp);',
          '#Up(CLK := #Go);',
          '#Down(CLK := #Go);',
          'IF #Up.Q THEN "Elems".Edges := "Elems".Edges + 1; END_IF;',
          'IF #Down.Q THEN "Elems".Falls := "Elems".Falls + 1; END_IF;',
          '#Presses(CU := #Go, R := #Clr, PV := 3, Q => #Counted);',
          '#Rs(S := #Go, R1 := #Clr, Q1 => #RsQ);',
          '#Sr(S1 := #Go, R := #Clr, Q1 => #SrQ);']));
        D := P.AddDB(2, 'Signals_DB');
        D.InstanceOf := 1;
        B := P.Block(0);
        Scl(B, 'Literals, constants, MUX, slices', 'VAR CONSTANT, typed literals, MUX, .%X / .%B', L([
          'VAR CONSTANT',
          '    BASE : Int := 10;',
          'END_VAR',
          '"Elems".Picked := MUX(K := "Elems".Sel, IN0 := #BASE, IN1 := INT#2 * #BASE, IN2 := 8#36, INELSE := -1);',
          '"Elems".Status.%X3 := "Start";',
          '"Elems".Status.%B1 := 16#A5;',
          '"Elems".Bit11 := "Elems".Status.%X11;']));
        Scl(B, 'Two dimensions, FC', 'Grid[i, j] in loops, an FC with positional arguments', L([
          'VAR_TEMP',
          '    i : Int;',
          '    j : Int;',
          'END_VAR',
          '"Elems".Sum := 0;',
          'FOR #i := 0 TO 2 DO',
          '    FOR #j := 1 TO 3 DO',
          '        "Elems".Sum := "Elems".Sum + "Elems".Grid[#i, #j];',
          '    END_FOR;',
          'END_FOR;',
          '"Elems".Avg := "Avg2"("Elems".Grid[0, 1], "Elems".Grid[2, 3]);']));
        Scl(B, 'System FBs', 'the FB with the system FBs', L([
          '"Signals_DB"(Go := "Start", Clr := "Reset", TimeUp => "Lamp_Time", Counted => "Lamp_Count",',
          '             RsQ => "Lamp_RS", SrQ => "Lamp_SR");']));
        P.AddWatch('"Elems".Sel', dfDec);
        P.AddWatch('"Elems".Picked', dfDec);
        P.AddWatch('"Elems".Status', dfHex);
        P.AddWatch('"Elems".Sum', dfDec);
        P.AddWatch('"Elems".Avg', dfDec);
        P.AddWatch('"Elems".Edges', dfDec);
        P.AddWatch('"Signals_DB".Presses.CV', dfDec);
      end;
    31: // ---------- strings ----------
      begin
        Start(13, 'SCL strings: String, WString, Char (S7-1500)',
          'SCL strings as in the SCL Compiler: String[n] and WString[n] with LEN, CONCAT, LEFT, RIGHT, MID, FIND, ' +
          'comparisons, Char, an array of strings, an FC with a String Return value and an FB with a String ' +
          'Static. Modify "Text".Name in the watch table; I0.0 picks the next word of the list.');
        P.AddTag('Next', 'Bool', '%I0.0', 'push button: the next word');
        Push(0);
        D := P.AddDB(1, 'Text');
        D.AddVar('Name', 'String[20]', '''Siemens''', 'modify me');
        D.AddVar('Greeting', 'String[40]', '', '"Hello"(Name)');
        D.AddVar('Len', 'Int', '0', 'LEN(Greeting)');
        D.AddVar('Pos', 'Int', '0', 'FIND(Greeting, Name)');
        D.AddVar('First3', 'String[3]', '', 'LEFT(Name, 3)');
        D.AddVar('Last3', 'String[3]', '', 'RIGHT(Name, 3)');
        D.AddVar('Middle', 'String[10]', '', 'MID(Name, 3, 2)');
        D.AddVar('IsPlc', 'Bool', 'FALSE', 'Name = ''PLC''');
        D.AddVar('Initial', 'Char', '''?''', 'the first letter');
        D.AddVar('Words', 'Array[0..3] of String[8]', '[''red'', ''green'', ''blue'', ''yellow'']', 'a list');
        D.AddVar('Index', 'Int', '0', 'the word shown');
        D.AddVar('Word', 'String[8]', '', 'Words[Index]');
        D.AddVar('Wide', 'WString[20]', 'WSTRING#''Gr$00FC$00DFe''', 'a WString');
        D.AddVar('WideLen', 'Int', '0', 'LEN(Wide)');
        D.AddVar('Old', 'Bool', 'FALSE', 'the edge memory of Next');
        B := P.AddBlock(bkFC, 1, 'Hello');
        B.Comment := 'a greeting: a String Input and a String Return value';
        B.Iface.AddSecVar(vsInput, 'Who', 'String[20]', '', '');
        B.Iface.AddSecVar(vsReturn, 'Ret_Val', 'String[40]', '', '');
        Scl(B, 'Greeting', 'CONCAT of three strings', '#Hello := CONCAT(IN1 := CONCAT(IN1 := ''Hello '', IN2 := #Who), IN2 := ''!'');');
        B := P.Block(0);
        Scl(B, 'String functions', 'LEN, FIND, LEFT, RIGHT, MID, compare, Char', L([
          '"Text".Greeting := "Hello"(Who := "Text".Name);',
          '"Text".Len := LEN("Text".Greeting);',
          '"Text".Pos := FIND(IN1 := "Text".Greeting, IN2 := "Text".Name);',
          '"Text".First3 := LEFT(IN := "Text".Name, L := 3);',
          '"Text".Last3 := RIGHT(IN := "Text".Name, L := 3);',
          '"Text".Middle := MID(IN := "Text".Name, L := 3, P := 2);',
          '"Text".IsPlc := "Text".Name = ''PLC'';',
          '"Text".WideLen := LEN("Text".Wide);']));
        Scl(B, 'A list of words', 'I0.0 shows the next word of the array', L([
          'IF "Next" AND NOT "Text".Old THEN',
          '    "Text".Index := ("Text".Index + 1) MOD 4;',
          'END_IF;',
          '"Text".Old := "Next";',
          '"Text".Word := "Text".Words["Text".Index];']));
        P.AddWatch('"Text".Name', dfDec);
        P.AddWatch('"Text".Greeting', dfDec);
        P.AddWatch('"Text".Len', dfDec);
        P.AddWatch('"Text".Word', dfDec);
        P.AddWatch('"Text".Wide', dfDec);
      end;
    32: // ---------- 64 bit, long times and dates ----------
      begin
        Start(13, 'SCL 64 bit: LInt, LReal, LTime, LDT, DT, DTL (S7-1500)',
          'SCL with the 64 bit types of the S7-1500, exact beyond 2^53: an LInt cycle counter, LReal arithmetic, ' +
          'an LTime from TON_LTIME, LDT and DT plus a time, DT_TO_DATE / DT_TO_TOD, a DTL struct, an LWord ' +
          'with slices and a CTU_DINT. I0.0 runs the LTime timer and counts.');
        P.AddTag('Run', 'Bool', '%I0.0', 'switch: the timer runs, the counter counts');
        P.AddTag('Done', 'Bool', '%Q0.0', 'TON_LTIME: Q after LT#3S');
        D := P.AddDB(1, 'Long');
        D.AddVar('Cycles', 'ULInt', '0', 'cycles since the start');
        D.AddVar('Big', 'LInt', '9007199254740993', '2^53 + 1: no Double holds it');
        D.AddVar('BigPlus', 'LInt', '0', 'Big + Cycles, exact');
        D.AddVar('Third', 'LReal', '0.0', '1.0 / 3.0 in 64 bit');
        D.AddVar('Elapsed', 'LTime', 'LT#0NS', 'ET of TON_LTIME (ns)');
        D.AddVar('Start', 'LDT', 'LDT#2024-01-31-12:00:00', 'a date and time in ns');
        D.AddVar('Later', 'LDT', '', 'Start + Elapsed');
        D.AddVar('Stamp', 'Date_And_Time', 'DT#2024-01-31-23:30:00', 'a DT (BCD)');
        D.AddVar('Stamp2', 'Date_And_Time', '', 'Stamp + T#1H: the next day');
        D.AddVar('Day', 'Date', '', 'DT_TO_DATE(Stamp2)');
        D.AddVar('Clock', 'Time_Of_Day', '', 'DT_TO_TOD(Stamp2)');
        D.AddVar('Local', 'DTL', '', 'a DTL: YEAR, MONTH, DAY, ...');
        D.AddVar('Mask', 'LWord', 'LW#16#FFFF0000FFFF0000', 'an LWord, bits set by slices');
        D.AddVar('Count', 'DInt', '0', 'CTU_DINT.CV');
        B := P.AddBlock(bkFB, 1, 'Runner');
        B.Comment := 'TON_LTIME and CTU_DINT as statics';
        B.Iface.AddSecVar(vsInput, 'Go', 'Bool', 'FALSE', '');
        B.Iface.AddSecVar(vsOutput, 'Q', 'Bool', 'FALSE', '');
        B.Iface.AddSecVar(vsOutput, 'Et', 'LTime', '', '');
        B.Iface.AddSecVar(vsOutput, 'Cv', 'DInt', '0', '');
        B.Iface.AddSecVar(vsStatic, 'Timer', 'TON_LTIME', '', 'an LTime timer');
        B.Iface.AddSecVar(vsStatic, 'Counter', 'CTU_DINT', '', 'a DInt counter');
        Scl(B, 'Timer and counter', 'LT#3S, PV 100000', L([
          '#Timer(IN := #Go, PT := LT#3S, Q => #Q, ET => #Et);',
          '#Counter(CU := #Go, R := FALSE, PV := 100000, CV => #Cv);']));
        D := P.AddDB(2, 'Runner_DB');
        D.InstanceOf := 1;
        B := P.Block(0);
        Scl(B, '64 bit arithmetic', 'exact LInt / ULInt, LReal', L([
          '"Long".Cycles := "Long".Cycles + 1;',
          '"Long".BigPlus := "Long".Big + ULINT_TO_LINT("Long".Cycles);',
          '"Long".Third := 1.0 / LREAL#3.0;',
          '"Long".Mask.%X0 := "Run";']));
        Scl(B, 'Long times and dates', 'LDT + LTime, DT + TIME, DT_TO_DATE / DT_TO_TOD, DTL', L([
          '"Runner_DB"(Go := "Run", Q => "Done", Et => "Long".Elapsed, Cv => "Long".Count);',
          '"Long".Later := "Long".Start + "Long".Elapsed;',
          '"Long".Stamp2 := "Long".Stamp + T#1H;',
          '"Long".Day := DT_TO_DATE("Long".Stamp2);',
          '"Long".Clock := DT_TO_TOD("Long".Stamp2);',
          '"Long".Local.YEAR := 2024;',
          '"Long".Local.MONTH := 2;',
          '"Long".Local.DAY := 1;']));
        P.AddWatch('"Long".Cycles', dfDec);
        P.AddWatch('"Long".BigPlus', dfDec);
        P.AddWatch('"Long".Elapsed', dfDec);
        P.AddWatch('"Long".Later', dfDec);
        P.AddWatch('"Long".Stamp2', dfDec);
      end;
    33: // ---------- LAD and STL with the SCL functions ----------
      begin
        Start(13, 'LAD and STL: the SCL functions as boxes and CALLs (S7-1500)',
          'The functions of SCL in LAD boxes (SEL, MUX, LIMIT, MIN, MAX, SQRT, EXPT, SHL, AND, CONCAT, LEN, MID, ' +
          'R_TRIG with INC, a TON_LTIME and a CTU_DINT instance) and in STL as CALL SEL / CALL CONCAT / CALL of a ' +
          'TON_TIME instance with parameter lines. I0.0 counts edges and runs the timers; modify "Box".Sel.');
        P.AddTag('Go', 'Bool', '%I0.0', 'push button: edges, timers, counter');
        P.AddTag('Enable', 'Bool', '%M10.0', 'the boxes run (set by network 1)');
        P.AddTag('Lamp', 'Bool', '%Q0.0', 'TON_LTIME: Q');
        P.AddTag('Lamp_STL', 'Bool', '%Q0.1', 'TON_TIME in STL: Q');
        Push(0);
        D := P.AddDB(1, 'Box');
        D.AddVar('Sel', 'Bool', 'TRUE', 'SEL: G');
        D.AddVar('Picked', 'Int', '0', 'SEL(G, 10, 20)');
        D.AddVar('K', 'Int', '2', 'MUX: K');
        D.AddVar('FromMux', 'Int', '0', 'MUX(K, 100, 200, 300)');
        D.AddVar('Limited', 'Int', '0', 'LIMIT(0, 150, 100)');
        D.AddVar('Smallest', 'Int', '0', 'MIN(9, 4, 6)');
        D.AddVar('Root', 'Real', '0.0', 'SQRT(2.0)');
        D.AddVar('Cube', 'Real', '0.0', 'EXPT(1.5, 3.0)');
        D.AddVar('Shifted', 'Word', 'W#16#0', 'SHL(16#0001, 4)');
        D.AddVar('Masked', 'Word', 'W#16#0', 'AND(16#F0F0, 16#FF00)');
        D.AddVar('Text', 'String[20]', '', 'CONCAT(''PLC '', ''box'')');
        D.AddVar('TextLen', 'Int', '0', 'LEN(Text)');
        D.AddVar('Part', 'String[10]', '', 'MID(Text, 3, 5)');
        D.AddVar('Edge', 'R_TRIG', '', 'the rising edges of Go');
        D.AddVar('Edges', 'Int', '0', 'INC on each edge');
        D.AddVar('Long', 'TON_LTIME', '', 'an LTime timer box');
        D.AddVar('LongEt', 'LTime', '', 'its ET');
        D.AddVar('Count', 'CTU_DINT', '', 'a DInt counter box');
        D.AddVar('CountCv', 'DInt', '0', 'its CV');
        D.AddVar('StlSel', 'Int', '0', 'STL: CALL SEL');
        D.AddVar('StlText', 'String[20]', '', 'STL: CALL CONCAT');
        D.AddVar('StlTimer', 'TON_TIME', '', 'STL: CALL "Box".StlTimer');
        B := P.Block(0);
        Scl(B, 'Enable', 'the boxes below run while Enable is 1', '"Enable" := TRUE;');
        LadNet(B, 'SEL and MUX', 'EN is the rung, ENO = EN', 2);
        Lad(0, 0, lkNO, '"Enable"');
        SBox(0, 1, lkSel, '', ['"Box".Sel', '10', '20', '"Box".Picked']);
        Wires(0, 2, 3);
        SBox(0, 4, lkMux, '', ['"Box".K', '100', '200', '300', '"Box".FromMux']);
        Wires(0, 5, 7);
        LadNet(B, 'LIMIT and MIN', '', 1);
        Lad(0, 0, lkNO, '"Enable"');
        SBox(0, 1, lkLimit, '', ['0', '150', '100', '"Box".Limited']);
        Wires(0, 2, 3);
        SBox(0, 4, lkMin, '', ['9', '4', '6', '', '"Box".Smallest']);
        Wires(0, 5, 7);
        LadNet(B, 'SQRT and EXPT', 'Real functions', 1);
        Lad(0, 0, lkNO, '"Enable"');
        SBox(0, 1, lkSqrt, '', ['2.0', '"Box".Root']);
        Wires(0, 2, 3);
        SBox(0, 4, lkExpt, '', ['1.5', '3.0', '"Box".Cube']);
        Wires(0, 5, 7);
        LadNet(B, 'SHL and AND', 'bit strings', 1);
        Lad(0, 0, lkNO, '"Enable"');
        SBox(0, 1, lkShl, '', ['W#16#0001', '4', '"Box".Shifted']);
        Wires(0, 2, 3);
        SBox(0, 4, lkAndW, '', ['W#16#F0F0', 'W#16#FF00', '"Box".Masked']);
        Wires(0, 5, 7);
        LadNet(B, 'Strings', 'CONCAT, LEN, MID in a row', 1);
        Lad(0, 0, lkNO, '"Enable"');
        SBox(0, 1, lkConcat, '', ['''PLC ''', '''box''', '"Box".Text']);
        Wires(0, 2, 3);
        SBox(0, 4, lkLen, '', ['"Box".Text', '"Box".TextLen']);
        Wires(0, 5, 6);
        SBox(0, 7, lkMid, '', ['"Box".Text', '3', '5', '"Box".Part']);
        Wires(0, 8, 9);
        LadNet(B, 'R_TRIG and INC', 'counts the rising edges of Go', 1);
        Lad(0, 0, lkNO, '"Go"');
        SBox(0, 1, lkRTrig, '"Box".Edge', []);
        Wires(0, 2, 3);
        SBox(0, 4, lkInc, '', ['"Box".Edges']);
        Wires(0, 5, 7);
        LadNet(B, 'TON_LTIME and CTU_DINT', 'a TON box and a CTU box with the instances of TIA', 1);
        Lad(0, 0, lkNO, '"Go"');
        SBox(0, 1, lkTON, '"Box".Long', ['LT#3S', '"Box".LongEt']);
        Wires(0, 2, 6);
        Lad(0, 7, lkCoil, '"Lamp"');
        LadNet(B, 'CTU_DINT', '', 1);
        Lad(0, 0, lkNO, '"Go"');
        SBox(0, 1, lkCTU, '"Box".Count', ['100000', 'FALSE', '"Box".CountCv']);
        Wires(0, 2, 7);
        Stl(B, 'STL: CALL of the SCL functions', 'one parameter per line, RET_VAL is the result', L([
          'CALL SEL',
          '  value_type := Int',
          '  G := "Box".Sel',
          '  IN0 := 1',
          '  IN1 := 2',
          '  RET_VAL := "Box".StlSel',
          'CALL CONCAT',
          '  IN1 := ''from ''',
          '  IN2 := ''STL''',
          '  RET_VAL := "Box".StlText',
          'CALL "Box".StlTimer',
          '  IN := "Go"',
          '  PT := T#2S',
          '  Q := "Lamp_STL"']));
        P.AddWatch('"Box".Picked', dfDec);
        P.AddWatch('"Box".FromMux', dfDec);
        P.AddWatch('"Box".Text', dfDec);
        P.AddWatch('"Box".Edges', dfDec);
        P.AddWatch('"Box".LongEt', dfDec);
        P.AddWatch('"Box".StlText', dfDec);
      end;
    34: // ---------- FBD and CFC ----------
      begin
        Start(13, 'FBD and CFC: motor, start warning, tank level, box counter (S7-1500)',
          'The same logic as boxes: FBD networks (trees from the left) and CFC charts (free blocks with wires, run in ' +
          'the order of the data flow). I0.0 starts the motor (a 3 s horn first), I0.1 stops it, I0.2 is the ' +
          'overload; the AI slider is the tank level; I0.3 counts boxes, 10 make a batch, I0.4 resets. Monitor (F9) ' +
          'shows the values at the pins.');
        P.AddTag('Start_PB', 'Bool', '%I0.0', 'start button');
        P.AddTag('Stop_PB', 'Bool', '%I0.1', 'stop button');
        P.AddTag('Overload', 'Bool', '%I0.2', 'overload relay');
        P.AddTag('Box_Sensor', 'Bool', '%I0.3', 'a box passes');
        P.AddTag('Reset_PB', 'Bool', '%I0.4', 'reset the box counter');
        P.AddTag('Level_AI', 'Int', '%IW64', 'level sensor 0..10 V');
        P.AddTag('Motor', 'Bool', '%Q0.0', 'conveyor motor');
        P.AddTag('Horn', 'Bool', '%Q0.1', 'start warning');
        P.AddTag('High_Alarm', 'Bool', '%Q0.2', 'level above 80 %');
        P.AddTag('Low_Alarm', 'Bool', '%Q0.3', 'level below 20 %');
        P.AddTag('Batch_Done', 'Bool', '%Q0.4', '10 boxes');
        P.AddTag('Level_pct', 'Real', '%MD10', 'level 0..100 %');
        P.AddTag('Boxes', 'Int', '%MW20', 'boxes counted');
        P.AddTag('Edge_M', 'Bool', '%M30.0', 'edge memory of Box_Sensor');
        Push(0);
        Push(1);
        Push(3);
        Push(4);
        P.AIch[0].AiValue := 6000;
        D := P.AddDB(1, 'Ctrl');
        D.AddVar('Warn', 'IEC_TIMER', '', 'start warning time');
        D.AddVar('Count', 'IEC_COUNTER', '', 'the boxes of a batch');
        // FBD: self holding: (Start OR Motor) AND NOT Stop AND NOT Overload
        FNet(nkFBD, 'Motor: start / stop', 'OR: the start or the motor itself (self holding); AND with the negated stop and overload');
        K := FBox(1, 'or', '');
        FIn(K, 'IN1', '"Start_PB"');
        FIn(K, 'IN2', '"Motor"');
        K := FBox(2, 'and', '');
        FWire(K, 'IN1', 0, 'Q');
        FIn(K, 'IN2', '"Stop_PB"', True);
        FIn(K, 'IN3', '"Overload"', True);
        K := FBox(3, 'assign', '"Motor"');
        FWire(K, 'IN', 1, 'Q');
        // FBD: a horn while the start button is held, for at most 3 s
        FNet(nkFBD, 'Start warning', 'TON: the horn sounds while the start button is held, at most 3 s');
        K := FBox(1, 'ton', '"Ctrl".Warn');
        FIn(K, 'IN', '"Start_PB"');
        FIn(K, 'PT', 'T#3S');
        K := FBox(2, 'and', '');
        FIn(K, 'IN1', '"Start_PB"');
        FWire(K, 'IN2', 0, 'Q', True);
        K := FBox(3, 'assign', '"Horn"');
        FWire(K, 'IN', 1, 'Q');
        // CFC: the level scaled, two limits
        FNet(nkCFC, 'Tank level', 'NORM_X and SCALE_X: 0..27648 to 0..100 %; the alarms at 80 % and 20 %');
        K := FBox(1, 'normx', '', dtInt);
        FIn(K, 'MIN', '0');
        FIn(K, 'VALUE', '"Level_AI"');
        FIn(K, 'MAX', '27648');
        K := FBox(2, 'scalex', '', dtReal);
        FIn(K, 'MIN', '0.0');
        FWire(K, 'VALUE', 0, 'OUT');
        FIn(K, 'MAX', '100.0');
        FOut(K, 'OUT', '"Level_pct"');
        K := FBox(3, 'cmp', '', dtReal);
        N.Nodes[K].Cmp := coGE;
        FWire(K, 'IN1', 1, 'OUT');
        FIn(K, 'IN2', '80.0');
        K := FBox(4, 'assign', '"High_Alarm"');
        FWire(K, 'IN', 2, 'Q');
        K := FBox(5, 'cmp', '', dtReal);
        N.Nodes[K].Cmp := coLE;
        FWire(K, 'IN1', 1, 'OUT');
        FIn(K, 'IN2', '20.0');
        K := FBox(6, 'assign', '"Low_Alarm"');
        FWire(K, 'IN', 4, 'Q');
        CfcAutoPlace(N);
        // CFC: the edges of the sensor counted
        FNet(nkCFC, 'Box counter', 'P: one pulse per box; CTU: 10 boxes make a batch; Reset_PB starts again');
        K := FBox(1, 'p', '"Edge_M"');
        FIn(K, 'IN', '"Box_Sensor"');
        K := FBox(2, 'ctu', '"Ctrl".Count');
        FWire(K, 'CU', 0, 'Q');
        FIn(K, 'R', '"Reset_PB"');
        FIn(K, 'PV', '10');
        FOut(K, 'CV', '"Boxes"');
        K := FBox(3, 'assign', '"Batch_Done"');
        FWire(K, 'IN', 1, 'Q');
        CfcAutoPlace(N);
        P.AddWatch('"Level_pct"', dfReal);
        P.AddWatch('"Boxes"', dfDec);
        P.AddWatch('"Ctrl".Warn.ET', dfTime);
      end;
  end;
  if I > 3 then
  begin
    P.Comm.PutGet := True;
    P.Modified := False;
  end;
end;

procedure WriteExamples(const Dir: string);
var
  I: Integer;
  P: TPlcProject;
begin
  ForceDirectories(Dir);
  for I := 0 to ExampleCount - 1 do
    if not FileExists(IncludeTrailingPathDelimiter(Dir) + ExampleFile(I)) then
    begin
      P := TPlcProject.Create;
      try
        BuildExample(I, P);
        P.SaveToFile(IncludeTrailingPathDelimiter(Dir) + ExampleFile(I));
      finally
        P.Free;
      end;
    end;
end;

end.
