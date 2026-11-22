unit uLogoDefs;

{ The blocks of LOGO! 8 for the FBD / CFC editor: the basic functions (GF: AND with edge, NAND with edge; AND,
  OR, NOT, NAND, NOR, XOR are boxes of uFbd) and the special functions (SF). A special function is a box with an
  instance - its block number B001, B002 .. (a variable of the DB LOGO_B) - and an FB of the LOGO! library that
  this unit holds as SCL (LogoLibSource): uLogo puts the FBs a program uses into the project before it is
  compiled. The pins of a box are the inputs of its FB (Trg, R, En .. and the parameters T, On, Off ..), its
  outputs Q, Ta, AQ ..; a parameter shows its default on the pin. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils;

type
  TLogoDef = record
    Id: string;       // the box id: 'lg_ondelay'
    Title: string;    // in the box: 'On-delay'
    Fb: string;       // the FB of the library: 'LOGO_OnDelay'
    Ins, Outs: string;   // the pins as uFbd writes them: 'Trg:B,T:T'
    Defaults: string;    // the operands of new pins: 'T=T#3S,On=500'
    Descr: string;
    Src: string;         // the declarations and the body of the FB (SCL)
  end;

function LogoDefCount: Integer;
function LogoDef(I: Integer): TLogoDef;
function LogoDefIndex(const Id: string): Integer;   // -1: no LOGO! box
{ the SCL source of the FB Fb (FUNCTION_BLOCK .. END_FUNCTION_BLOCK), '' unknown }
function LogoLibSource(const Fb: string): string;

const
  LogoCatGF = 'LOGO! basic functions (GF)';
  LogoCatSF = 'LOGO! special functions (SF)';
  LogoInstDB = 'LOGO_B';    // the DB of the block instances

implementation

const
  NL = LineEnding;

var
  Defs: array of TLogoDef;

procedure D(const AId, ATitle, AFb, AIns, AOuts, ADef, ADescr, ASrc: string);
var
  N: Integer;
begin
  N := Length(Defs);
  SetLength(Defs, N + 1);
  Defs[N].Id := AId;
  Defs[N].Title := ATitle;
  Defs[N].Fb := AFb;
  Defs[N].Ins := AIns;
  Defs[N].Outs := AOuts;
  Defs[N].Defaults := ADef;
  Defs[N].Descr := ADescr;
  Defs[N].Src := ASrc;
end;

procedure Build;
begin
  if Defs <> nil then Exit;
  // ---------- the basic functions with an edge ----------
  D('lg_andedge', 'AND (edge)', 'LOGO_AndEdge', 'In1:B,In2:B?,In3:B?,In4:B?', 'Q:B', '',
    'AND with edge evaluation: Q is 1 for one cycle when all inputs become 1 (an open input counts as 1).',
    'VAR_INPUT In1 : Bool; In2 : Bool := TRUE; In3 : Bool := TRUE; In4 : Bool := TRUE; END_VAR' + NL +
    'VAR_OUTPUT Q : Bool; END_VAR' + NL + 'VAR Old : Bool; A : Bool; END_VAR' + NL + 'BEGIN' + NL +
    '#A := #In1 AND #In2 AND #In3 AND #In4;' + NL + '#Q := #A AND NOT #Old;' + NL + '#Old := #A;');
  D('lg_nandedge', 'NAND (edge)', 'LOGO_NandEdge', 'In1:B,In2:B?,In3:B?,In4:B?', 'Q:B', '',
    'NAND with edge evaluation: Q is 1 for one cycle when an input becomes 0 after all were 1.',
    'VAR_INPUT In1 : Bool; In2 : Bool := TRUE; In3 : Bool := TRUE; In4 : Bool := TRUE; END_VAR' + NL +
    'VAR_OUTPUT Q : Bool; END_VAR' + NL + 'VAR Old : Bool; A : Bool; END_VAR' + NL + 'BEGIN' + NL +
    '#A := #In1 AND #In2 AND #In3 AND #In4;' + NL + '#Q := #Old AND NOT #A;' + NL + '#Old := #A;');
  // ---------- timers ----------
  D('lg_ondelay', 'On-delay', 'LOGO_OnDelay', 'Trg:B,T:T', 'Q:B,Ta:T', 'T=T#3S',
    'On-delay: Q becomes 1 when Trg has been 1 for the time T; Trg 0 resets at once. Ta: the time run.',
    'VAR_INPUT Trg : Bool; T : Time := T#3S; END_VAR' + NL + 'VAR_OUTPUT Q : Bool; Ta : Time; END_VAR' + NL +
    'VAR Tm : TON_TIME; END_VAR' + NL + 'BEGIN' + NL + '#Tm(IN := #Trg, PT := #T);' + NL + '#Q := #Tm.Q;' + NL +
    '#Ta := #Tm.ET;');
  D('lg_offdelay', 'Off-delay', 'LOGO_OffDelay', 'Trg:B,R:B?,T:T', 'Q:B,Ta:T', 'T=T#3S',
    'Off-delay: Q is 1 with Trg and stays 1 for T after Trg went 0; R resets Q and the time.',
    'VAR_INPUT Trg : Bool; R : Bool; T : Time := T#3S; END_VAR' + NL + 'VAR_OUTPUT Q : Bool; Ta : Time; END_VAR' + NL +
    'VAR Run : Bool; Start : Time; END_VAR' + NL + 'BEGIN' + NL +
    'IF #Trg THEN' + NL + '  #Q := TRUE; #Run := FALSE; #Ta := T#0S;' + NL +
    'ELSIF #Q AND NOT #Run THEN' + NL + '  #Run := TRUE; #Start := TIME_TCK();' + NL + 'END_IF;' + NL +
    'IF #Run THEN' + NL + '  #Ta := TIME_TCK() - #Start;' + NL +
    '  IF #Ta >= #T THEN #Q := FALSE; #Run := FALSE; END_IF;' + NL + 'END_IF;' + NL +
    'IF #R THEN #Q := FALSE; #Run := FALSE; #Ta := T#0S; END_IF;');
  D('lg_onoffdelay', 'On-/Off-delay', 'LOGO_OnOffDelay', 'Trg:B,TH:T,TL:T', 'Q:B', 'TH=T#2S,TL=T#3S',
    'On-/Off-delay: Q becomes 1 TH after Trg became 1, and 0 again TL after Trg became 0.',
    'VAR_INPUT Trg : Bool; TH : Time := T#2S; TL : Time := T#3S; END_VAR' + NL + 'VAR_OUTPUT Q : Bool; END_VAR' + NL +
    'VAR TOn : TON_TIME; TOff : TON_TIME; END_VAR' + NL + 'BEGIN' + NL +
    '#TOn(IN := #Trg, PT := #TH);' + NL + 'IF #TOn.Q THEN #Q := TRUE; END_IF;' + NL +
    '#TOff(IN := NOT #Trg AND #Q, PT := #TL);' + NL + 'IF #TOff.Q THEN #Q := FALSE; END_IF;');
  D('lg_retondelay', 'Retentive on-delay', 'LOGO_RetOnDelay', 'Trg:B,R:B?,T:T', 'Q:B,Ta:T', 'T=T#3S',
    'Retentive on-delay: a pulse at Trg starts the time T; Q becomes 1 then and stays 1 until R.',
    'VAR_INPUT Trg : Bool; R : Bool; T : Time := T#3S; END_VAR' + NL + 'VAR_OUTPUT Q : Bool; Ta : Time; END_VAR' + NL +
    'VAR Run : Bool; Old : Bool; Start : Time; END_VAR' + NL + 'BEGIN' + NL +
    'IF #Trg AND NOT #Old AND NOT #Q AND NOT #Run THEN #Run := TRUE; #Start := TIME_TCK(); END_IF;' + NL +
    '#Old := #Trg;' + NL + 'IF #Run THEN' + NL + '  #Ta := TIME_TCK() - #Start;' + NL +
    '  IF #Ta >= #T THEN #Q := TRUE; #Run := FALSE; #Ta := #T; END_IF;' + NL + 'END_IF;' + NL +
    'IF #R THEN #Q := FALSE; #Run := FALSE; #Ta := T#0S; END_IF;');
  D('lg_interval', 'Interval relay', 'LOGO_Interval', 'Trg:B,R:B?,T:T', 'Q:B,Ta:T', 'T=T#3S',
    'Interval relay (pulse output): Trg 1 makes Q 1 for at most T; Q goes 0 with Trg or R.',
    'VAR_INPUT Trg : Bool; R : Bool; T : Time := T#3S; END_VAR' + NL + 'VAR_OUTPUT Q : Bool; Ta : Time; END_VAR' + NL +
    'VAR Run : Bool; Old : Bool; Start : Time; END_VAR' + NL + 'BEGIN' + NL +
    'IF #Trg AND NOT #Old THEN #Run := TRUE; #Start := TIME_TCK(); END_IF;' + NL + '#Old := #Trg;' + NL +
    'IF NOT #Trg OR #R THEN #Run := FALSE; END_IF;' + NL +
    'IF #Run THEN' + NL + '  #Ta := TIME_TCK() - #Start;' + NL + '  IF #Ta >= #T THEN #Run := FALSE; END_IF;' + NL +
    'ELSE' + NL + '  #Ta := T#0S;' + NL + 'END_IF;' + NL + '#Q := #Run;');
  D('lg_edgeinterval', 'Edge triggered interval relay', 'LOGO_EdgeInterval', 'Trg:B,R:B?,TH:T,TL:T,N:I',
    'Q:B', 'TH=T#1S,TL=T#1S,N=1',
    'Edge triggered interval relay: a pulse at Trg gives N pulses of TH at Q, with TL between them; R stops.',
    'VAR_INPUT Trg : Bool; R : Bool; TH : Time := T#1S; TL : Time := T#1S; N : Int := 1; END_VAR' + NL +
    'VAR_OUTPUT Q : Bool; END_VAR' + NL + 'VAR Old : Bool; State : Int; Count : Int; Start : Time; END_VAR' + NL +
    'BEGIN' + NL +
    'IF #Trg AND NOT #Old AND (#State = 0) THEN #State := 1; #Count := 0; #Start := TIME_TCK(); END_IF;' + NL +
    '#Old := #Trg;' + NL + 'IF #State = 1 THEN' + NL + '  IF TIME_TCK() - #Start >= #TH THEN' + NL +
    '    #Count := #Count + 1; #Start := TIME_TCK();' + NL +
    '    IF #Count >= #N THEN #State := 0; ELSE #State := 2; END_IF;' + NL + '  END_IF;' + NL +
    'ELSIF #State = 2 THEN' + NL + '  IF TIME_TCK() - #Start >= #TL THEN #State := 1; #Start := TIME_TCK(); END_IF;' + NL +
    'END_IF;' + NL + 'IF #R THEN #State := 0; END_IF;' + NL + '#Q := #State = 1;');
  D('lg_pulsegen', 'Asynchronous pulse generator', 'LOGO_PulseGen', 'En:B,Inv:B?,TH:T,TL:T', 'Q:B',
    'TH=T#500MS,TL=T#500MS',
    'Asynchronous pulse generator: while En is 1, Q is TH 1 and TL 0, again and again; Inv inverts Q.',
    'VAR_INPUT En : Bool; Inv : Bool; TH : Time := T#500MS; TL : Time := T#500MS; END_VAR' + NL +
    'VAR_OUTPUT Q : Bool; END_VAR' + NL + 'VAR High : Bool; WasEn : Bool; Start : Time; END_VAR' + NL + 'BEGIN' + NL +
    'IF #En THEN' + NL + '  IF NOT #WasEn THEN #High := TRUE; #Start := TIME_TCK(); END_IF;' + NL +
    '  IF #High THEN' + NL + '    IF TIME_TCK() - #Start >= #TH THEN #High := FALSE; #Start := TIME_TCK(); END_IF;' + NL +
    '  ELSE' + NL + '    IF TIME_TCK() - #Start >= #TL THEN #High := TRUE; #Start := TIME_TCK(); END_IF;' + NL +
    '  END_IF;' + NL + '  #Q := #High XOR #Inv;' + NL + 'ELSE' + NL + '  #High := FALSE; #Q := FALSE;' + NL + 'END_IF;' + NL +
    '#WasEn := #En;');
  D('lg_random', 'Random generator', 'LOGO_Random', 'En:B,TH:T,TL:T', 'Q:B', 'TH=T#5S,TL=T#5S',
    'Random generator: Q follows En, each change after a random time: 0 .. TH to 1, 0 .. TL to 0.',
    'VAR_INPUT En : Bool; TH : Time := T#5S; TL : Time := T#5S; END_VAR' + NL + 'VAR_OUTPUT Q : Bool; END_VAR' + NL +
    'VAR Old : Bool; Wait : Bool; Start : Time; Delay : Time; Seed : DInt := 12345; END_VAR' + NL + 'BEGIN' + NL +
    'IF #En <> #Old THEN' + NL + '  #Seed := (#Seed * 75 + 74) MOD 65537;' + NL +
    '  IF #En THEN #Delay := DINT_TO_TIME(TIME_TO_DINT(#TH) * #Seed / 65537);' + NL +
    '  ELSE #Delay := DINT_TO_TIME(TIME_TO_DINT(#TL) * #Seed / 65537); END_IF;' + NL +
    '  #Wait := TRUE; #Start := TIME_TCK();' + NL + 'END_IF;' + NL + '#Old := #En;' + NL +
    'IF #Wait AND (TIME_TCK() - #Start >= #Delay) THEN #Wait := FALSE; #Q := #En; END_IF;');
  D('lg_stairway', 'Stairway lighting switch', 'LOGO_Stairway', 'Trg:B,R:B?,T:T,TWarn:T?,TLWarn:T?', 'Q:B',
    'T=T#30S,TWarn=T#15S,TLWarn=T#1S',
    'Stairway lighting switch: Trg switches Q on; T after Trg went 0 Q goes off; TWarn before the end Q is off ' +
    'for TLWarn (the warning). A new Trg starts the time again.',
    'VAR_INPUT Trg : Bool; R : Bool; T : Time := T#30S; TWarn : Time := T#15S; TLWarn : Time := T#1S; END_VAR' + NL +
    'VAR_OUTPUT Q : Bool; END_VAR' + NL + 'VAR Old : Bool; Run : Bool; Start : Time; El : Time; END_VAR' + NL +
    'BEGIN' + NL + 'IF #Trg THEN' + NL + '  #Q := TRUE; #Run := FALSE;' + NL + 'ELSIF #Old THEN' + NL +
    '  #Run := TRUE; #Start := TIME_TCK();' + NL + 'END_IF;' + NL + '#Old := #Trg;' + NL + 'IF #Run THEN' + NL +
    '  #El := TIME_TCK() - #Start;' + NL + '  IF #El >= #T THEN' + NL + '    #Q := FALSE; #Run := FALSE;' + NL +
    '  ELSIF (#TWarn > T#0S) AND (#El >= #T - #TWarn) AND (#El < #T - #TWarn + #TLWarn) THEN' + NL +
    '    #Q := FALSE;' + NL + '  ELSE' + NL + '    #Q := TRUE;' + NL + '  END_IF;' + NL + 'END_IF;' + NL +
    'IF #R THEN #Q := FALSE; #Run := FALSE; END_IF;');
  D('lg_multiswitch', 'Multiple function switch', 'LOGO_MultiSwitch', 'Trg:B,R:B?,TH:T,TL:T', 'Q:B',
    'TH=T#30S,TL=T#2S',
    'Multiple function switch: a short press at Trg switches Q on for TH; a press of TL or longer switches it on ' +
    'for good; the next press switches it off.',
    'VAR_INPUT Trg : Bool; R : Bool; TH : Time := T#30S; TL : Time := T#2S; END_VAR' + NL +
    'VAR_OUTPUT Q : Bool; END_VAR' + NL +
    'VAR Old : Bool; Perm : Bool; Run : Bool; Skip : Bool; Press : Time; Start : Time; END_VAR' + NL + 'BEGIN' + NL +
    'IF #Trg AND NOT #Old THEN' + NL + '  #Press := TIME_TCK();' + NL +
    '  IF #Perm OR #Run THEN #Perm := FALSE; #Run := FALSE; #Q := FALSE; #Skip := TRUE; END_IF;' + NL + 'END_IF;' + NL +
    'IF #Trg AND NOT #Skip AND NOT #Perm AND (TIME_TCK() - #Press >= #TL) THEN #Perm := TRUE; #Q := TRUE; END_IF;' + NL +
    'IF NOT #Trg AND #Old THEN' + NL +
    '  IF NOT #Perm AND NOT #Skip THEN #Q := TRUE; #Run := TRUE; #Start := TIME_TCK(); END_IF;' + NL +
    '  #Skip := FALSE;' + NL + 'END_IF;' + NL + '#Old := #Trg;' + NL +
    'IF #Run AND (TIME_TCK() - #Start >= #TH) THEN #Q := FALSE; #Run := FALSE; END_IF;' + NL +
    'IF #R THEN #Q := FALSE; #Run := FALSE; #Perm := FALSE; END_IF;');
  D('lg_weekly', 'Weekly timer', 'LOGO_Weekly', 'Days:X,OnTime:I,OffTime:I', 'Q:B', 'Days=16#1F,OnTime=800,OffTime=1700',
    'Weekly timer: Q is 1 on the days of Days (bit 0 Monday .. bit 6 Sunday; 16#1F Monday to Friday) from OnTime ' +
    'to OffTime (hhmm: 800 = 08:00, 1730 = 17:30; OnTime after OffTime: over midnight). It reads the PLC clock.',
    'VAR_INPUT Days : Byte := 16#1F; OnTime : Int := 800; OffTime : Int := 1700; END_VAR' + NL +
    'VAR_OUTPUT Q : Bool; END_VAR' + NL + 'VAR Now : DTL; Ret : Int; Wd : Int; Hm : Int; DayOn : Bool; END_VAR' + NL +
    'BEGIN' + NL + '#Ret := RD_LOC_T(OUT => #Now);' + NL + '// WEEKDAY: 1 Sunday .. 7 Saturday; here 0 Monday .. 6 Sunday' + NL +
    '#Wd := USINT_TO_INT(#Now.WEEKDAY) - 2;' + NL + 'IF #Wd < 0 THEN #Wd := 6; END_IF;' + NL +
    'CASE #Wd OF' + NL + '  0: #DayOn := #Days.%X0;' + NL + '  1: #DayOn := #Days.%X1;' + NL + '  2: #DayOn := #Days.%X2;' + NL +
    '  3: #DayOn := #Days.%X3;' + NL + '  4: #DayOn := #Days.%X4;' + NL + '  5: #DayOn := #Days.%X5;' + NL +
    'ELSE' + NL + '  #DayOn := #Days.%X6;' + NL + 'END_CASE;' + NL +
    '#Hm := USINT_TO_INT(#Now.HOUR) * 100 + USINT_TO_INT(#Now.MINUTE);' + NL +
    'IF #OnTime <= #OffTime THEN' + NL + '  #Q := #DayOn AND (#Hm >= #OnTime) AND (#Hm < #OffTime);' + NL +
    'ELSE' + NL + '  #Q := #DayOn AND ((#Hm >= #OnTime) OR (#Hm < #OffTime));' + NL + 'END_IF;');
  D('lg_yearly', 'Yearly timer', 'LOGO_Yearly', 'OnDate:I,OffDate:I', 'Q:B', 'OnDate=1201,OffDate=1231',
    'Yearly timer: Q is 1 from OnDate to OffDate (mmdd: 1201 = 1 December; OnDate after OffDate: over the new year).',
    'VAR_INPUT OnDate : Int := 1201; OffDate : Int := 1231; END_VAR' + NL + 'VAR_OUTPUT Q : Bool; END_VAR' + NL +
    'VAR Now : DTL; Ret : Int; Md : Int; END_VAR' + NL + 'BEGIN' + NL + '#Ret := RD_LOC_T(OUT => #Now);' + NL +
    '#Md := USINT_TO_INT(#Now.MONTH) * 100 + USINT_TO_INT(#Now.DAY);' + NL +
    'IF #OnDate <= #OffDate THEN' + NL + '  #Q := (#Md >= #OnDate) AND (#Md <= #OffDate);' + NL + 'ELSE' + NL +
    '  #Q := (#Md >= #OnDate) OR (#Md <= #OffDate);' + NL + 'END_IF;');
  D('lg_astro', 'Astronomical clock', 'LOGO_Astro', 'Lat:R,Lon:R,Zone:I,OffRise:I?,OffSet:I?', 'Q:B,Sunrise:I,Sunset:I',
    'Lat=13.75,Lon=100.50,Zone=7,OffRise=0,OffSet=0',
    'Astronomical clock: Q is 1 from sunrise to sunset at the latitude Lat / longitude Lon (degrees, east and north ' +
    'positive) in the time zone Zone (hours from UTC), each shifted by OffRise / OffSet minutes; Sunrise, Sunset: ' +
    'hhmm of today. It reads the PLC clock (the default: Bangkok).',
    'VAR_INPUT Lat : Real := 13.75; Lon : Real := 100.5; Zone : Int := 7; OffRise : Int; OffSet : Int; END_VAR' + NL +
    'VAR_OUTPUT Q : Bool; Sunrise : Int; Sunset : Int; END_VAR' + NL +
    'VAR Now : DTL; Ret : Int; Doy : Int; Decl : Real; B : Real; Eot : Real; CosH : Real; H : Real; Noon : Real; ' +
    'RiseM : Real; SetM : Real; Mins : Int; R : Int; END_VAR' + NL + 'BEGIN' + NL + '#Ret := RD_LOC_T(OUT => #Now);' + NL +
    '// the day of the year' + NL + 'CASE USINT_TO_INT(#Now.MONTH) OF' + NL +
    '  2: #Doy := 31;' + NL + '  3: #Doy := 59;' + NL + '  4: #Doy := 90;' + NL + '  5: #Doy := 120;' + NL +
    '  6: #Doy := 151;' + NL + '  7: #Doy := 181;' + NL + '  8: #Doy := 212;' + NL + '  9: #Doy := 243;' + NL +
    '  10: #Doy := 273;' + NL + '  11: #Doy := 304;' + NL + '  12: #Doy := 334;' + NL + 'ELSE' + NL + '  #Doy := 0;' + NL +
    'END_CASE;' + NL + '#Doy := #Doy + USINT_TO_INT(#Now.DAY);' + NL +
    '// the declination of the sun, the equation of time (minutes), the hour angle of sunrise' + NL +
    '#B := 6.2832 * INT_TO_REAL(#Doy - 81) / 364.0;' + NL + '#Decl := 0.4093 * SIN(6.2832 * INT_TO_REAL(#Doy - 81) / 365.0);' + NL +
    '#Eot := 9.87 * SIN(2.0 * #B) - 7.53 * COS(#B) - 1.5 * SIN(#B);' + NL +
    '#CosH := (SIN(-0.01454) - SIN(#Lat * 0.0174533) * SIN(#Decl)) / (COS(#Lat * 0.0174533) * COS(#Decl));' + NL +
    'IF #CosH > 1.0 THEN #CosH := 1.0; ELSIF #CosH < -1.0 THEN #CosH := -1.0; END_IF;' + NL +
    '#H := ACOS(#CosH) / 0.0174533;' + NL + '#Noon := 720.0 - 4.0 * #Lon - #Eot + INT_TO_REAL(#Zone) * 60.0;' + NL +
    '#RiseM := #Noon - 4.0 * #H + INT_TO_REAL(#OffRise);' + NL + '#SetM := #Noon + 4.0 * #H + INT_TO_REAL(#OffSet);' + NL +
    '#Mins := USINT_TO_INT(#Now.HOUR) * 60 + USINT_TO_INT(#Now.MINUTE);' + NL +
    '#Q := (INT_TO_REAL(#Mins) >= #RiseM) AND (INT_TO_REAL(#Mins) < #SetM);' + NL +
    '#R := REAL_TO_INT(#RiseM);' + NL + '#Sunrise := #R / 60 * 100 + #R MOD 60;' + NL +
    '#R := REAL_TO_INT(#SetM);' + NL + '#Sunset := #R / 60 * 100 + #R MOD 60;');
  // ---------- counters ----------
  D('lg_updown', 'Up/down counter', 'LOGO_UpDown', 'R:B?,Cnt:B,Dir:B?,On:X,Off:X,StartVal:X?', 'Q:B,Cv:X',
    'On=10,Off=0',
    'Up/down counter: each pulse at Cnt counts Cv up (Dir 0) or down (Dir 1); Q is 1 from Cv >= On to Cv < Off; R ' +
    'sets Cv to StartVal.',
    'VAR_INPUT R : Bool; Cnt : Bool; Dir : Bool; On : DInt := 10; Off : DInt := 0; StartVal : DInt := 0; END_VAR' + NL +
    'VAR_OUTPUT Q : Bool; Cv : DInt; END_VAR' + NL + 'VAR Old : Bool; END_VAR' + NL + 'BEGIN' + NL +
    'IF #Cnt AND NOT #Old THEN' + NL + '  IF #Dir THEN #Cv := #Cv - 1; ELSE #Cv := #Cv + 1; END_IF;' + NL + 'END_IF;' + NL +
    '#Old := #Cnt;' + NL + 'IF #R THEN #Cv := #StartVal; END_IF;' + NL + 'IF #On >= #Off THEN' + NL +
    '  IF #Cv >= #On THEN #Q := TRUE; ELSIF #Cv < #Off THEN #Q := FALSE; END_IF;' + NL + 'ELSE' + NL +
    '  #Q := (#Cv >= #On) AND (#Cv < #Off);' + NL + 'END_IF;');
  D('lg_hours', 'Operating hours counter', 'LOGO_Hours', 'R:B?,En:B,Ral:B?,MI:I', 'Q:B,MN:X,OT:X', 'MI=100',
    'Operating hours counter: counts the time En is 1. MN: the minutes left of the service interval MI (hours); ' +
    'Q is 1 when it is over; R starts the interval again, Ral resets everything; OT: the hours in total.',
    'VAR_INPUT R : Bool; En : Bool; Ral : Bool; MI : Int := 100; END_VAR' + NL +
    'VAR_OUTPUT Q : Bool; MN : DInt; OT : DInt; END_VAR' + NL +
    'VAR WasEn : Bool; Last : Time; MsAcc : DInt; MinInt : DInt; MinTot : DInt; END_VAR' + NL + 'BEGIN' + NL +
    'IF #En AND #WasEn THEN #MsAcc := #MsAcc + TIME_TO_DINT(TIME_TCK() - #Last); END_IF;' + NL +
    '#WasEn := #En;' + NL + '#Last := TIME_TCK();' + NL + 'WHILE #MsAcc >= 60000 DO' + NL +
    '  #MsAcc := #MsAcc - 60000; #MinInt := #MinInt + 1; #MinTot := #MinTot + 1;' + NL + 'END_WHILE;' + NL +
    'IF #R THEN #MinInt := 0; END_IF;' + NL + 'IF #Ral THEN #MinInt := 0; #MinTot := 0; #MsAcc := 0; END_IF;' + NL +
    '#OT := #MinTot / 60;' + NL + '#MN := INT_TO_DINT(#MI) * 60 - #MinInt;' + NL + '#Q := #MN <= 0;');
  D('lg_freq', 'Threshold trigger (frequency)', 'LOGO_Frequency', 'Fre:B,On:I,Off:I,G_T:T', 'Q:B,Fa:I',
    'On=10,Off=5,G_T=T#1S',
    'Threshold trigger: counts the pulses at Fre in each gate time G_T (Fa); Q is 1 from Fa > On to Fa <= Off.',
    'VAR_INPUT Fre : Bool; On : Int := 10; Off : Int := 5; G_T : Time := T#1S; END_VAR' + NL +
    'VAR_OUTPUT Q : Bool; Fa : Int; END_VAR' + NL + 'VAR Old : Bool; Cnt : Int; Start : Time; END_VAR' + NL + 'BEGIN' + NL +
    'IF #Fre AND NOT #Old THEN #Cnt := #Cnt + 1; END_IF;' + NL + '#Old := #Fre;' + NL +
    'IF TIME_TCK() - #Start >= #G_T THEN #Fa := #Cnt; #Cnt := 0; #Start := TIME_TCK(); END_IF;' + NL +
    'IF #Fa > #On THEN #Q := TRUE; ELSIF #Fa <= #Off THEN #Q := FALSE; END_IF;');
  // ---------- analog ----------
  D('lg_athresh', 'Analog threshold trigger', 'LOGO_AnalogThreshold', 'Ax:I,Gain:R?,Offset:I?,On:I,Off:I', 'Q:B,Av:I',
    'On=500,Off=400',
    'Analog threshold trigger: Av = Ax * Gain + Offset; Q is 1 from Av > On to Av <= Off (On < Off: a window).',
    'VAR_INPUT Ax : Int; Gain : Real := 1.0; Offset : Int; On : Int := 500; Off : Int := 400; END_VAR' + NL +
    'VAR_OUTPUT Q : Bool; Av : Int; END_VAR' + NL + 'BEGIN' + NL +
    '#Av := REAL_TO_INT(LIMIT(MN := -32768.0, IN := INT_TO_REAL(#Ax) * #Gain, MX := 32767.0)) + #Offset;' + NL +
    'IF #On >= #Off THEN' + NL + '  IF #Av > #On THEN #Q := TRUE; ELSIF #Av <= #Off THEN #Q := FALSE; END_IF;' + NL +
    'ELSE' + NL + '  #Q := (#Av > #On) AND (#Av <= #Off);' + NL + 'END_IF;');
  D('lg_adiff', 'Analog differential trigger', 'LOGO_AnalogDiff', 'Ax:I,Gain:R?,Offset:I?,On:I,Delta:I', 'Q:B,Av:I',
    'On=500,Delta=-100',
    'Analog differential trigger: Off = On + Delta; Delta < 0: Q from Av > On to Av <= Off; Delta > 0: Q while ' +
    'On < Av <= Off.',
    'VAR_INPUT Ax : Int; Gain : Real := 1.0; Offset : Int; On : Int := 500; Delta : Int := -100; END_VAR' + NL +
    'VAR_OUTPUT Q : Bool; Av : Int; END_VAR' + NL + 'VAR Off : Int; END_VAR' + NL + 'BEGIN' + NL +
    '#Av := REAL_TO_INT(LIMIT(MN := -32768.0, IN := INT_TO_REAL(#Ax) * #Gain, MX := 32767.0)) + #Offset;' + NL +
    '#Off := #On + #Delta;' + NL + 'IF #Delta < 0 THEN' + NL +
    '  IF #Av > #On THEN #Q := TRUE; ELSIF #Av <= #Off THEN #Q := FALSE; END_IF;' + NL + 'ELSE' + NL +
    '  #Q := (#Av > #On) AND (#Av <= #Off);' + NL + 'END_IF;');
  D('lg_acompare', 'Analog comparator', 'LOGO_AnalogCompare', 'Ax:I,Ay:I,Gain:R?,Offset:I?,On:I,Off:I', 'Q:B,Ad:I',
    'On=100,Off=50',
    'Analog comparator: Ad = (Ax - Ay) * Gain + Offset; Q is 1 from Ad > On to Ad <= Off.',
    'VAR_INPUT Ax : Int; Ay : Int; Gain : Real := 1.0; Offset : Int; On : Int := 100; Off : Int := 50; END_VAR' + NL +
    'VAR_OUTPUT Q : Bool; Ad : Int; END_VAR' + NL + 'BEGIN' + NL +
    '#Ad := REAL_TO_INT(LIMIT(MN := -32768.0, IN := (INT_TO_REAL(#Ax) - INT_TO_REAL(#Ay)) * #Gain, MX := 32767.0)) + #Offset;' + NL +
    'IF #On >= #Off THEN' + NL + '  IF #Ad > #On THEN #Q := TRUE; ELSIF #Ad <= #Off THEN #Q := FALSE; END_IF;' + NL +
    'ELSE' + NL + '  #Q := (#Ad > #On) AND (#Ad <= #Off);' + NL + 'END_IF;');
  D('lg_awatch', 'Analog watchdog', 'LOGO_AnalogWatchdog', 'En:B,Ax:I,Delta1:I,Delta2:I', 'Q:B,Aen:I',
    'Delta1=100,Delta2=100',
    'Analog watchdog: En 1 stores Ax as Aen; Q is 1 while Ax leaves Aen + Delta1 .. Aen - Delta2.',
    'VAR_INPUT En : Bool; Ax : Int; Delta1 : Int := 100; Delta2 : Int := 100; END_VAR' + NL +
    'VAR_OUTPUT Q : Bool; Aen : Int; END_VAR' + NL + 'VAR Old : Bool; END_VAR' + NL + 'BEGIN' + NL +
    'IF #En AND NOT #Old THEN #Aen := #Ax; END_IF;' + NL + '#Old := #En;' + NL +
    '#Q := #En AND ((#Ax > #Aen + #Delta1) OR (#Ax < #Aen - #Delta2));');
  D('lg_aamp', 'Analog amplifier', 'LOGO_AnalogAmp', 'Ax:I,Gain:R?,Offset:I?', 'AQ:I', 'Gain=1.0,Offset=0',
    'Analog amplifier: AQ = Ax * Gain + Offset.',
    'VAR_INPUT Ax : Int; Gain : Real := 1.0; Offset : Int; END_VAR' + NL + 'VAR_OUTPUT AQ : Int; END_VAR' + NL + 'BEGIN' + NL +
    '#AQ := REAL_TO_INT(LIMIT(MN := -32768.0, IN := INT_TO_REAL(#Ax) * #Gain + INT_TO_REAL(#Offset), MX := 32767.0));');
  D('lg_amux', 'Analog multiplexer', 'LOGO_AnalogMux', 'En:B,S1:B?,S2:B?,V1:I,V2:I?,V3:I?,V4:I?', 'AQ:I',
    'V1=0,V2=250,V3=500,V4=1000',
    'Analog multiplexer: En 1: AQ = V1 (S2 S1 = 0 0), V2 (0 1), V3 (1 0), V4 (1 1); En 0: AQ = 0.',
    'VAR_INPUT En : Bool; S1 : Bool; S2 : Bool; V1 : Int; V2 : Int; V3 : Int; V4 : Int; END_VAR' + NL +
    'VAR_OUTPUT AQ : Int; END_VAR' + NL + 'BEGIN' + NL + 'IF NOT #En THEN #AQ := 0;' + NL +
    'ELSIF NOT #S2 AND NOT #S1 THEN #AQ := #V1;' + NL + 'ELSIF NOT #S2 THEN #AQ := #V2;' + NL +
    'ELSIF NOT #S1 THEN #AQ := #V3;' + NL + 'ELSE #AQ := #V4;' + NL + 'END_IF;');
  D('lg_aramp', 'Analog ramp', 'LOGO_AnalogRamp', 'En:B,Sel:B?,St:B?,L1:I,L2:I?,MaxL:I?,StSp:I?,Rate:I', 'AQ:I',
    'L1=500,L2=1000,MaxL=1000,StSp=0,Rate=100',
    'Analog ramp: En 1 runs AQ to the level L1 (Sel 0) or L2 (Sel 1) at Rate per second, at most MaxL; St runs it ' +
    'down to StSp; En 0: AQ = 0.',
    'VAR_INPUT En : Bool; Sel : Bool; St : Bool; L1 : Int := 500; L2 : Int := 1000; MaxL : Int := 1000; ' +
    'StSp : Int; Rate : Int := 100; END_VAR' + NL + 'VAR_OUTPUT AQ : Int; END_VAR' + NL +
    'VAR Val : Real; Last : Time; Dt : Real; Target : Int; END_VAR' + NL + 'BEGIN' + NL +
    '#Dt := DINT_TO_REAL(TIME_TO_DINT(TIME_TCK() - #Last)) / 1000.0;' + NL + '#Last := TIME_TCK();' + NL +
    'IF #Dt > 1.0 THEN #Dt := 0.0; END_IF;' + NL + 'IF #St THEN #Target := #StSp;' + NL +
    'ELSIF #Sel THEN #Target := #L2;' + NL + 'ELSE #Target := #L1;' + NL + 'END_IF;' + NL +
    'IF #Target > #MaxL THEN #Target := #MaxL; END_IF;' + NL + 'IF NOT #En THEN' + NL + '  #Val := 0.0;' + NL +
    'ELSIF #Val < INT_TO_REAL(#Target) THEN' + NL + '  #Val := #Val + INT_TO_REAL(#Rate) * #Dt;' + NL +
    '  IF #Val > INT_TO_REAL(#Target) THEN #Val := INT_TO_REAL(#Target); END_IF;' + NL +
    'ELSIF #Val > INT_TO_REAL(#Target) THEN' + NL + '  #Val := #Val - INT_TO_REAL(#Rate) * #Dt;' + NL +
    '  IF #Val < INT_TO_REAL(#Target) THEN #Val := INT_TO_REAL(#Target); END_IF;' + NL + 'END_IF;' + NL +
    '#AQ := REAL_TO_INT(#Val);');
  D('lg_pi', 'PI controller', 'LOGO_PI', 'AM:B,R:B?,PV:I,SP:I,Mq:I?,KC:R,TI:T,Min:I?,Max:I?,Dir:B?', 'AQ:I',
    'AM=hi,KC=1.0,TI=T#10S,Min=0,Max=1000',
    'PI controller: AM 1 (automatic) controls AQ so that PV follows SP (gain KC, integral time TI, AQ in Min .. ' +
    'Max, Dir inverts); AM 0 (manual): AQ = Mq; R sets AQ to Min.',
    'VAR_INPUT AM : Bool := TRUE; R : Bool; PV : Int; SP : Int; Mq : Int; KC : Real := 1.0; TI : Time := T#10S; ' +
    'Min : Int; Max : Int := 1000; Dir : Bool; END_VAR' + NL + 'VAR_OUTPUT AQ : Int; END_VAR' + NL +
    'VAR I : Real; Y : Real; E : Real; Dt : Real; TiS : Real; Last : Time; END_VAR' + NL + 'BEGIN' + NL +
    '#Dt := DINT_TO_REAL(TIME_TO_DINT(TIME_TCK() - #Last)) / 1000.0;' + NL + '#Last := TIME_TCK();' + NL +
    'IF #Dt > 1.0 THEN #Dt := 0.0; END_IF;' + NL + '#E := INT_TO_REAL(#SP) - INT_TO_REAL(#PV);' + NL +
    'IF #Dir THEN #E := -#E; END_IF;' + NL + '#TiS := DINT_TO_REAL(TIME_TO_DINT(#TI)) / 1000.0;' + NL +
    'IF #TiS < 0.01 THEN #TiS := 0.01; END_IF;' + NL + 'IF #R THEN' + NL + '  #I := INT_TO_REAL(#Min); #Y := #I;' + NL +
    'ELSIF #AM THEN' + NL + '  #I := #I + #KC * #E * #Dt / #TiS;' + NL +
    '  IF #I > INT_TO_REAL(#Max) THEN #I := INT_TO_REAL(#Max); END_IF;' + NL +
    '  IF #I < INT_TO_REAL(#Min) THEN #I := INT_TO_REAL(#Min); END_IF;' + NL + '  #Y := #KC * #E + #I;' + NL + 'ELSE' + NL +
    '  #Y := INT_TO_REAL(#Mq); #I := #Y - #KC * #E;' + NL + 'END_IF;' + NL +
    '#Y := LIMIT(MN := INT_TO_REAL(#Min), IN := #Y, MX := INT_TO_REAL(#Max));' + NL + '#AQ := REAL_TO_INT(#Y);');
  D('lg_pwm', 'Pulse width modulator (PWM)', 'LOGO_PWM', 'En:B,Ax:I,PT:T,Min:I?,Max:I?', 'Q:B',
    'PT=T#1S,Min=0,Max=1000',
    'PWM: while En is 1, Q is 1 for the part (Ax - Min) / (Max - Min) of every period PT.',
    'VAR_INPUT En : Bool; Ax : Int; PT : Time := T#1S; Min : Int; Max : Int := 1000; END_VAR' + NL +
    'VAR_OUTPUT Q : Bool; END_VAR' + NL + 'VAR Start : Time; El : Time; Duty : Real; END_VAR' + NL + 'BEGIN' + NL +
    'IF NOT #En THEN' + NL + '  #Q := FALSE; #Start := TIME_TCK();' + NL + 'ELSE' + NL +
    '  #El := TIME_TCK() - #Start;' + NL + '  IF #El >= #PT THEN #Start := TIME_TCK(); #El := T#0S; END_IF;' + NL +
    '  IF #Max > #Min THEN' + NL +
    '    #Duty := (INT_TO_REAL(#Ax) - INT_TO_REAL(#Min)) / (INT_TO_REAL(#Max) - INT_TO_REAL(#Min));' + NL +
    '  ELSE' + NL + '    #Duty := 0.0;' + NL + '  END_IF;' + NL + '  #Duty := LIMIT(MN := 0.0, IN := #Duty, MX := 1.0);' + NL +
    '  #Q := DINT_TO_REAL(TIME_TO_DINT(#El)) < #Duty * DINT_TO_REAL(TIME_TO_DINT(#PT));' + NL + 'END_IF;');
  D('lg_math', 'Mathematic instruction', 'LOGO_Math', 'En:B,V1:I,Op1:I?,V2:I,Op2:I?,V3:I?,Op3:I?,V4:I?', 'AQ:I,Err:B',
    'Op1=0,Op2=0,Op3=0,V3=0,V4=0',
    'Mathematic instruction: AQ = V1 Op1 V2 Op2 V3 Op3 V4, from the left (Op: 0 +, 1 -, 2 *, 3 /); Err: a division ' +
    'by 0 or an overflow. En 0: AQ stays.',
    'VAR_INPUT En : Bool; V1 : Int; Op1 : Int; V2 : Int; Op2 : Int; V3 : Int; Op3 : Int; V4 : Int; END_VAR' + NL +
    'VAR_OUTPUT AQ : Int; Err : Bool; END_VAR' + NL + 'VAR R : DInt; B : DInt; K : Int; Op : Int; END_VAR' + NL +
    'BEGIN' + NL + 'IF NOT #En THEN RETURN; END_IF;' + NL + '#Err := FALSE;' + NL + '#R := INT_TO_DINT(#V1);' + NL +
    'FOR #K := 1 TO 3 DO' + NL + '  IF #K = 1 THEN #Op := #Op1; #B := INT_TO_DINT(#V2);' + NL +
    '  ELSIF #K = 2 THEN #Op := #Op2; #B := INT_TO_DINT(#V3);' + NL + '  ELSE #Op := #Op3; #B := INT_TO_DINT(#V4);' + NL +
    '  END_IF;' + NL + '  CASE #Op OF' + NL + '    1: #R := #R - #B;' + NL + '    2: #R := #R * #B;' + NL +
    '    3: IF #B = 0 THEN #Err := TRUE; ELSE #R := #R / #B; END_IF;' + NL + '  ELSE' + NL + '    #R := #R + #B;' + NL +
    '  END_CASE;' + NL + 'END_FOR;' + NL + 'IF (#R > 32767) OR (#R < -32768) THEN #Err := TRUE; ELSE #AQ := DINT_TO_INT(#R); END_IF;');
  // ---------- others ----------
  D('lg_latch', 'Latching relay', 'LOGO_Latch', 'S:B,R:B', 'Q:B', '',
    'Latching relay: S sets Q, R resets it; R wins when both are 1.',
    'VAR_INPUT S : Bool; R : Bool; END_VAR' + NL + 'VAR_OUTPUT Q : Bool; END_VAR' + NL + 'BEGIN' + NL +
    'IF #S THEN #Q := TRUE; END_IF;' + NL + 'IF #R THEN #Q := FALSE; END_IF;');
  D('lg_pulserelay', 'Pulse relay', 'LOGO_PulseRelay', 'Trg:B,S:B?,R:B?', 'Q:B', '',
    'Pulse relay (current impulse relay): each pulse at Trg changes Q; S sets it, R resets it (R wins).',
    'VAR_INPUT Trg : Bool; S : Bool; R : Bool; END_VAR' + NL + 'VAR_OUTPUT Q : Bool; END_VAR' + NL +
    'VAR Old : Bool; END_VAR' + NL + 'BEGIN' + NL + 'IF #Trg AND NOT #Old THEN #Q := NOT #Q; END_IF;' + NL +
    '#Old := #Trg;' + NL + 'IF #S THEN #Q := TRUE; END_IF;' + NL + 'IF #R THEN #Q := FALSE; END_IF;');
  D('lg_message', 'Message text', 'LOGO_Message', 'En:B,Prio:I?,Text:X', 'Q:B', 'Prio=0,Text=''Hello''',
    'Message text: while En is 1 the LOGO! display (CPU screen) shows Text (the one of the highest Prio); Q = En.',
    'VAR_INPUT En : Bool; Prio : Int; Text : String[64] := ''Message''; END_VAR' + NL + 'VAR_OUTPUT Q : Bool; END_VAR' + NL +
    'BEGIN' + NL + '#Q := #En;');
  D('lg_softkey', 'Softkey', 'LOGO_Softkey', 'En:B,Switch:B?', 'Q:B', 'Switch=hi',
    'Softkey: a switch on the LOGO! display (CPU screen: click it); Q is 1 while En is 1 and it is on. Switch 0: ' +
    'a push button (on for one cycle).',
    'VAR_INPUT En : Bool; Switch : Bool := TRUE; END_VAR' + NL + 'VAR_OUTPUT Q : Bool; END_VAR' + NL +
    'VAR State : Bool; END_VAR' + NL + 'BEGIN' + NL + '#Q := #En AND #State;' + NL + 'IF NOT #Switch THEN #State := FALSE; END_IF;');
  D('lg_shift', 'Shift register', 'LOGO_Shift', 'In:B,Trg:B,R:B?,Dir:B?', 'Q:B,Bits:X', '',
    'Shift register: each pulse at Trg shifts the 8 bits (Dir 0: up, In into bit 1; Dir 1: down, In into bit 8); Q: ' +
    'bit 8; Bits: all of them; R clears.',
    'VAR_INPUT In : Bool; Trg : Bool; R : Bool; Dir : Bool; END_VAR' + NL + 'VAR_OUTPUT Q : Bool; Bits : Byte; END_VAR' + NL +
    'VAR Old : Bool; END_VAR' + NL + 'BEGIN' + NL + 'IF #Trg AND NOT #Old THEN' + NL + '  IF #Dir THEN' + NL +
    '    #Bits := SHR(IN := #Bits, N := 1); #Bits.%X7 := #In;' + NL + '  ELSE' + NL +
    '    #Bits := SHL(IN := #Bits, N := 1); #Bits.%X0 := #In;' + NL + '  END_IF;' + NL + 'END_IF;' + NL +
    '#Old := #Trg;' + NL + 'IF #R THEN #Bits := 16#0; END_IF;' + NL + '#Q := #Bits.%X7;');
  D('lg_stopwatch', 'Stopwatch', 'LOGO_Stopwatch', 'En:B,Lap:B?,R:B?', 'AQ:T,Lt:T', '',
    'Stopwatch: AQ counts the time En is 1; a pulse at Lap keeps the time now in Lt; R sets both to 0.',
    'VAR_INPUT En : Bool; Lap : Bool; R : Bool; END_VAR' + NL + 'VAR_OUTPUT AQ : Time; Lt : Time; END_VAR' + NL +
    'VAR WasEn : Bool; LapOld : Bool; Last : Time; END_VAR' + NL + 'BEGIN' + NL +
    'IF #En AND #WasEn THEN #AQ := #AQ + (TIME_TCK() - #Last); END_IF;' + NL + '#WasEn := #En;' + NL +
    '#Last := TIME_TCK();' + NL + 'IF #Lap AND NOT #LapOld THEN #Lt := #AQ; END_IF;' + NL + '#LapOld := #Lap;' + NL +
    'IF #R THEN #AQ := T#0S; #Lt := T#0S; END_IF;');
end;

function LogoDefCount: Integer;
begin
  Build;
  Result := Length(Defs);
end;

function LogoDef(I: Integer): TLogoDef;
begin
  Build;
  Result := Defs[I];
end;

function LogoDefIndex(const Id: string): Integer;
var
  K: Integer;
begin
  Build;
  for K := 0 to High(Defs) do
    if Defs[K].Id = Id then Exit(K);
  Result := -1;
end;

function LogoLibSource(const Fb: string): string;
var
  K, P: Integer;
  S: string;
begin
  Build;
  Result := '';
  for K := 0 to High(Defs) do
    if SameText(Defs[K].Fb, Fb) then
    begin
      // the declarations before BEGIN, then the body
      S := Defs[K].Src;
      P := Pos('BEGIN', S);
      Result := 'FUNCTION_BLOCK "' + Defs[K].Fb + '"' + NL + 'VERSION : 8.3' + NL + Copy(S, 1, P - 1) + 'BEGIN' + NL +
        Copy(S, P + Length('BEGIN' + NL), MaxInt) + NL + 'END_FUNCTION_BLOCK' + NL;
      Exit;
    end;
end;

end.
