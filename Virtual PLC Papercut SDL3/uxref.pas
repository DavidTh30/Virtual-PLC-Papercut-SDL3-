unit uXref;

{ Cross reference: every place an operand is used in the project, as TIA's cross reference shows it:
  in the code (LAD cells, STL lines, SCL lines) as a decision / a value that is read (AND, OR, NOT, a
  compare, an IF condition, a call input, L) or as a destination that is written (a coil, S, R, =, T,
  := , a call output); also the watch table, the signal table and where it is declared (a tag, a DB
  variable, the interface). An operand matches by its symbol and by its address: "Motor" is Q4.0, so
  Q4.0 / %Q4.0 count, and a byte / word over the bit counts as an overlap. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, StrUtils, Math, uPlcTypes, uPlcProject, uPlcCompiler, uSclSig, uFbd;

type
  TXrefUse = (xuRead, xuWrite, xuReadWrite, xuDecl, xuTable);
  TXrefPlace = (xpCode, xpWatch, xpSignal, xpTag, xpDbVar, xpIface);

  TXref = record
    Place: TXrefPlace;
    Blk, Net, Row, Col: Integer;   // code: block index, network, LAD row / column or text line / column;
                                   // the tables and declarations: Row (Blk the DB / block)
    Use: TXrefUse;
    How: string;                   // AND, NOT, = coil, S, R, := (assignment), call input IN ..
    Written: string;               // the operand as it is written there
    Code: string;                  // the line, the cell
    Exact: Boolean;                // the same operand (else an address that overlaps it)
  end;
  TXrefs = array of TXref;

const
  XrefUseNames: array[TXrefUse] of string = ('decision / read', 'destination / write', 'read and write',
    'declaration', 'table');

{ the uses of Target (as typed: "Tag", %Q4.0, "DB".Var, #Local of the block Cur); Info: what it is }
function XrefFind(P: TPlcProject; const Target: string; Cur: TBlock; out Info: string; out R: TXrefs): Boolean;
type
  { an input / output of the project: a tag on it, or the code uses it }
  TIoUse = record
    Addr: string;            // I0.0, %QW64, PIW256
    A: TAddr;
    IsInput: Boolean;
    Symbol, TypeText, Comment: string;
    Reads, Writes, Tables: Integer;   // the uses in the code; the watch / signal table
  end;
  TIoUses = array of TIoUse;

{ every I / Q / PI / PQ address the project has: a tag on it or a use in the code, by address }
function XrefIoUsage(P: TPlcProject): TIoUses;

{ the block and the text of a reference: OB1 "Main" network 3 line 2 }
function XrefWhere(P: TPlcProject; const X: TXref): string;

implementation

type
  TRange = record
    Ok: Boolean;
    Area: TArea;
    DB: Integer;
    B0, B1: Int64;   // bits
    Num: Integer;    // a timer / counter
    Local: Boolean;  // L / DI: only within its block
  end;

function AreaClass(A: TArea): TArea;
begin
  // a peripheral access is the same address as the image
  case A of
    arPI: Result := arI;
    arPQ: Result := arQ;
  else
    Result := A;
  end;
end;

function RangeOf(R: TResolver; const S: string): TRange;
var
  V: TVarInfo;
  O: TOperand;
  E: string;
  N, Eb: Int64;
begin
  FillChar(Result, SizeOf(Result), 0);
  if Trim(S) = '' then Exit;
  if R.ResolveVar(S, V, E) then
  begin
    if V.IsArray then N := V.Hi - V.Lo + 1 else N := 1;
    if V.T = dtBool then Eb := 1
    else if (V.T in [dtStruct, dtString, dtWString, dtIECTimer, dtIECCounter]) and (V.Udt <> nil) then Eb := V.Udt.Size * 8
    else Eb := Max(1, DataTypeSize(V.T)) * 8;
    Result.Area := AreaClass(V.A.Area);
    Result.DB := V.A.DB;
    if Eb = 1 then Result.B0 := Int64(V.A.Ofs) * 8 + V.A.Bit else Result.B0 := Int64(V.A.Ofs) * 8;
    Result.B1 := Result.B0 + N * Eb - 1;
    Result.Local := V.A.Area in [arL, arDI];
    Result.Ok := True;
    Exit;
  end;
  if R.Resolve(S, O, E, False) and (O.Kind = okAddr) then
  begin
    Result.Area := AreaClass(O.A.Area);
    Result.DB := O.A.DB;
    Result.Num := O.A.Num;
    case O.A.Size of
      osBit:
        begin
          Result.B0 := Int64(O.A.Ofs) * 8 + O.A.Bit;
          Result.B1 := Result.B0;
        end;
      osByte: Eb := 8;
      osWord: Eb := 16;
    else
      Eb := 32;
    end;
    if (O.DType <> dtNone) and (DataTypeSize(O.DType) = 8) then Eb := 64;
    if O.A.Size <> osBit then
    begin
      Result.B0 := Int64(O.A.Ofs) * 8;
      Result.B1 := Result.B0 + Eb - 1;
    end;
    Result.Local := O.A.Area in [arL, arDI];
    Result.Ok := True;
  end;
end;

function Overlap(const A, B: TRange; out Exact: Boolean): Boolean;
begin
  Exact := False;
  Result := A.Ok and B.Ok and (A.Area = B.Area);
  if not Result then Exit;
  if A.Area in [arT, arC] then
  begin
    Result := A.Num = B.Num;
    Exact := Result;
    Exit;
  end;
  if (A.Area = arDB) and (A.DB <> B.DB) then Exit(False);
  Result := (A.B0 <= B.B1) and (B.B0 <= A.B1);
  Exact := Result and (A.B0 = B.B0) and (A.B1 = B.B1);
end;

{ ---------- the operands of a line of text ---------- }

type
  TTok = record
    S: string;
    P: Integer;    // 1-based byte position
  end;
  TToks = array of TTok;

const
  WordCh = ['A'..'Z', 'a'..'z', '0'..'9', '_'];

{ "Tag", "DB".Var[2].M, #Local.Member, %I0.0, I0.0 / MW10 / T1 / DB1.DBW2 (classic) }
function LineOperands(const L: string; var InCmt: Boolean): TToks;
var
  I, J, N, Depth: Integer;
  A: TAddr;
  E, W: string;

  procedure Add(AP: Integer; const AS_: string);
  begin
    N := Length(Result);
    SetLength(Result, N + 1);
    Result[N].S := AS_;
    Result[N].P := AP;
  end;

  // .member, ."quoted", [index]
  procedure Members(var K: Integer);
  begin
    repeat
      if (K <= Length(L)) and (L[K] = '.') and (K < Length(L)) and (L[K + 1] in ['A'..'Z', 'a'..'z', '_']) then
      begin
        Inc(K);
        while (K <= Length(L)) and (L[K] in WordCh) do Inc(K);
      end
      else if (K <= Length(L)) and (L[K] = '.') and (K < Length(L)) and (L[K + 1] = '"') then
      begin
        Inc(K, 2);
        while (K <= Length(L)) and (L[K] <> '"') do Inc(K);
        Inc(K);
      end
      else if (K <= Length(L)) and (L[K] = '[') then
      begin
        Depth := 0;
        repeat
          if L[K] = '[' then Inc(Depth) else if L[K] = ']' then Dec(Depth);
          Inc(K);
        until (K > Length(L)) or (Depth = 0);
      end
      else
        Break;
    until False;
  end;

begin
  Result := nil;
  I := 1;
  while I <= Length(L) do
  begin
    if InCmt then
    begin
      if (L[I] = '*') and (I < Length(L)) and (L[I + 1] = ')') then
      begin
        InCmt := False;
        Inc(I, 2);
      end
      else
        Inc(I);
      Continue;
    end;
    if (L[I] = '/') and (I < Length(L)) and (L[I + 1] = '/') then Break;
    if (L[I] = '(') and (I < Length(L)) and (L[I + 1] = '*') then
    begin
      InCmt := True;
      Inc(I, 2);
      Continue;
    end;
    if L[I] = '''' then
    begin
      Inc(I);
      while (I <= Length(L)) and (L[I] <> '''') do Inc(I);
      Inc(I);
      Continue;
    end;
    if L[I] = '"' then
    begin
      J := I + 1;
      while (J <= Length(L)) and (L[J] <> '"') do Inc(J);
      Inc(J);
      Members(J);
      Add(I, Copy(L, I, J - I));
      I := J;
      Continue;
    end;
    if (L[I] = '#') and (I < Length(L)) and (L[I + 1] in ['A'..'Z', 'a'..'z', '_']) then
    begin
      J := I + 1;
      while (J <= Length(L)) and (L[J] in WordCh) do Inc(J);
      Members(J);
      Add(I, Copy(L, I, J - I));
      I := J;
      Continue;
    end;
    if L[I] = '%' then
    begin
      J := I + 1;
      while (J <= Length(L)) and (L[J] in ['A'..'Z', 'a'..'z', '0'..'9', '.', ':', '_']) do Inc(J);
      Add(I, Copy(L, I, J - I));
      I := J;
      Continue;
    end;
    if L[I] in ['A'..'Z', 'a'..'z'] then
    begin
      J := I;
      while (J <= Length(L)) and (L[J] in ['A'..'Z', 'a'..'z', '0'..'9', '_', '.']) do Inc(J);
      W := Copy(L, I, J - I);
      // a word with a digit that is an address (classic): I0.0, MW10, T1, DB1.DBX0.0, PIW256
      if (W <> '') and (W[Length(W)] = '.') then SetLength(W, Length(W) - 1);
      if (I = 1) or not (L[I - 1] in WordCh + ['#', '.']) then
        if (Pos('#', W) = 0) and (W[Length(W)] in ['0'..'9']) and ParseAddr(W, A, E) then Add(I, W);
      I := J;
      Continue;
    end;
    Inc(I);
  end;
end;

function PrevWord(const L: string; P: Integer): string;
var
  K, E: Integer;
begin
  K := P - 1;
  while (K >= 1) and (L[K] = ' ') do Dec(K);
  E := K;
  while (K >= 1) and (L[K] in ['A'..'Z', 'a'..'z', '&']) do Dec(K);
  Result := UpperCase(Copy(L, K + 1, E - K));
  if Result = '' then
  begin
    // an operator: = <> < > <= >=
    K := E;
    while (K >= 1) and (L[K] in ['<', '>', '=', ':']) do Dec(K);
    Result := Copy(L, K + 1, E - K);
  end;
end;

function NextWord(const L: string; P: Integer): string;
var
  K, S: Integer;
begin
  K := P;
  while (K <= Length(L)) and (L[K] = ' ') do Inc(K);
  S := K;
  if (K <= Length(L)) and (L[K] in ['A'..'Z', 'a'..'z', '&']) then
    while (K <= Length(L)) and (L[K] in ['A'..'Z', 'a'..'z', '&']) do Inc(K)
  else
    while (K <= Length(L)) and (L[K] in ['<', '>', '=', ':']) do Inc(K);
  Result := UpperCase(Copy(L, S, K - S));
end;

function FirstWord(const L: string): string;
var
  K, S: Integer;
begin
  K := 1;
  while (K <= Length(L)) and (L[K] = ' ') do Inc(K);
  S := K;
  while (K <= Length(L)) and (L[K] in ['A'..'Z', 'a'..'z', '_']) do Inc(K);
  Result := UpperCase(Copy(L, S, K - S));
end;

const
  OutPins: array[0..9] of string = ('Q', 'ET', 'CV', 'QU', 'QD', 'Q1', 'RET_VAL', 'OUT', 'OUT1', 'ENO');

function IsOutPin(const Nm: string): Boolean;
var
  K: Integer;
begin
  Result := False;
  for K := 0 to High(OutPins) do
    if SameText(OutPins[K], Nm) then Exit(True);
end;

{ ---------- the search ---------- }

function XrefFind(P: TPlcProject; const Target: string; Cur: TBlock; out Info: string; out R: TXrefs): Boolean;
var
  Res: TResolver;
  Tr, Cr: TRange;
  BI, NI, K, J, Row, Col, Q, Pp: Integer;
  B: TBlock;
  N: TNetwork;
  Ce: TLadCell;
  Toks: TToks;
  InCmt, Ex, LocalT: Boolean;
  O: TOperand;
  E, T, L, U, Pw, Nw, Fw, Prm, CallTgt: string;
  Pins: TIntArray;
  Fb: TBlock;
  C: TSclCall;
  Sg: TSclSig;
  Pi_: Integer;

  procedure Put(APlace: TXrefPlace; ABlk, ANet, ARow, ACol: Integer; AUse: TXrefUse; const AHow, AWritten,
    ACode: string; AExact: Boolean);
  var
    M: Integer;
  begin
    M := Length(R);
    SetLength(R, M + 1);
    R[M].Place := APlace;
    R[M].Blk := ABlk;
    R[M].Net := ANet;
    R[M].Row := ARow;
    R[M].Col := ACol;
    R[M].Use := AUse;
    R[M].How := AHow;
    R[M].Written := AWritten;
    R[M].Code := ACode;
    R[M].Exact := AExact;
  end;

  // the operand S of block B matches the target
  function Hits(const S: string; out AExact: Boolean): Boolean;
  begin
    AExact := False;
    Result := False;
    if Trim(S) = '' then Exit;
    if LocalT or (Copy(Trim(S), 1, 1) = '#') then
    begin
      // a local: only in its own block, by its name (also a member of it)
      if not LocalT or (B <> Cur) then Exit;
      U := UpperCase(Trim(S));
      Result := (U = UpperCase(Trim(Target))) or AnsiStartsStr(UpperCase(Trim(Target)) + '.', U) or
        AnsiStartsStr(UpperCase(Trim(Target)) + '[', U);
      AExact := U = UpperCase(Trim(Target));
      Exit;
    end;
    Cr := RangeOf(Res, S);
    Result := Overlap(Tr, Cr, AExact);
    if Result and SameText(Trim(S), Trim(Target)) then AExact := True;
  end;

  procedure Cell(ARow, ACol: Integer; const S: string; AUse: TXrefUse; const AHow: string);
  begin
    if Hits(S, Ex) then Put(xpCode, BI, NI, ARow, ACol, AUse, AHow, S, LadKindNames[Ce.Kind], Ex);
  end;

  { FBD / CFC: a box (Row: its Id, Col: the input pin, 100 + the output pin, -1 the field above) }
  procedure Box(const Nd: TFbdNode; ACol: Integer; const S: string; AUse: TXrefUse; const AHow: string);
  begin
    if Hits(S, Ex) then Put(xpCode, BI, NI, Nd.Id, ACol, AUse, AHow, S, Format('#%d %s', [Nd.Id, FbdBoxDefOf(Nd.Box).Title]), Ex);
  end;

  procedure Boxes(N: TNetwork);
  var
    Q, I: Integer;
    Nd: TFbdNode;
    Bd: TFbdBoxDef;
  begin
    for Q := 0 to High(N.Nodes) do
    begin
      Nd := N.Nodes[Q];
      Bd := FbdBoxDefOf(Nd.Box);
      if Nd.Inst <> '' then
        case Nd.Box of
          'assign': Box(Nd, -1, Nd.Inst, xuWrite, '= assignment');
          'set': Box(Nd, -1, Nd.Inst, xuWrite, 'S set');
          'reset': Box(Nd, -1, Nd.Inst, xuWrite, 'R reset');
          'p', 'n': Box(Nd, -1, Nd.Inst, xuReadWrite, 'edge memory bit');
          'inc', 'dec': Box(Nd, -1, Nd.Inst, xuReadWrite, Bd.Title + ' IN_OUT');
          'call': Box(Nd, -1, Nd.Inst, xuReadWrite, 'CALL');
        else
          Box(Nd, -1, Nd.Inst, xuReadWrite, Bd.Title + ' instance');
        end;
      for I := 0 to High(Nd.Ins) do
        if (Nd.Ins[I].Src = 0) and (Nd.Ins[I].Opnd <> '') then
        begin
          if MatchStr(Nd.Box, ['and', 'or', 'xor']) then
            Box(Nd, I, Nd.Ins[I].Opnd, xuRead, Bd.Title + IfThen(Nd.Ins[I].Neg, ' NOT', '') + ' input ' + Nd.Ins[I].Name)
          else if Nd.Box = 'cmp' then Box(Nd, I, Nd.Ins[I].Opnd, xuRead, 'CMP compare ' + Nd.Ins[I].Name)
          else Box(Nd, I, Nd.Ins[I].Opnd, xuRead, Bd.Title + ' ' + Nd.Ins[I].Name);
        end;
      for I := 0 to High(Nd.Outs) do
        if Nd.Outs[I].Opnd <> '' then Box(Nd, 100 + I, Nd.Outs[I].Opnd, xuWrite, Bd.Title + ' output ' + Nd.Outs[I].Name);
    end;
  end;

  function PinUse(const Nm: string): TXrefUse;
  begin
    if SameText(Nm, 'IN_OUT') then Result := xuReadWrite
    else if IsOutPin(Nm) then Result := xuWrite
    else Result := xuRead;
  end;

begin
  R := nil;
  Info := '';
  Result := False;
  Res := TResolver.Create(P);
  try
    LocalT := Copy(Trim(Target), 1, 1) = '#';
    if LocalT then
    begin
      if Cur = nil then
      begin
        Info := 'a local variable (#..) needs its block';
        Exit;
      end;
      Res.Iface := Cur.Iface;
      // its name in the interface (a Temp too: the resolver knows those only while compiling)
      U := Copy(Trim(Target), 2, MaxInt);
      Q := Pos('.', U + '.');
      if Pos('[', U) in [1..Q - 1] then Q := Pos('[', U);
      if Cur.Iface.FindVar(Copy(U, 1, Q - 1)) < 0 then
      begin
        Info := Format('%s: not in the interface of %s', [Target, Cur.Title]);
        Exit;
      end;
      Info := Format('%s of %s', [Target, Cur.Title]);
    end
    else
    begin
      Tr := RangeOf(Res, Target);
      if not Tr.Ok then
      begin
        if Res.Resolve(Target, O, E, False) then Info := Target + ': not an address' else Info := E;
        Exit;
      end;
      Res.Resolve(Target, O, E, False);
      T := StringReplace(FormatAddr(O.A, P.Family), ' ', '', [rfReplaceAll]);
      U := Res.SymbolOf(O.A);
      if (U <> '') and not SameText(U, Trim(Target)) then Info := Format('%s = %s = %s', [Target, T, U])
      else if SameText(T, Trim(Target)) then Info := T
      else Info := Format('%s = %s', [Target, T]);
      if O.DType <> dtNone then Info := Info + '  (' + DataTypeNames[O.DType] + ')';
    end;
    Result := True;
    for BI := 0 to P.BlockCount - 1 do
    begin
      B := P.Block(BI);
      if LocalT and (B <> Cur) then Continue;
      if B.Kind in [bkFB, bkFC, bkOB] then Res.Iface := B.Iface else Res.Iface := nil;
      for NI := 0 to B.NetCount - 1 do
      begin
        N := B.Net(NI);
        if N.Kind in [nkFBD, nkCFC] then
        begin
          Boxes(N);
          Continue;
        end;
        if N.Kind = nkLAD then
        begin
          for Row := 0 to N.Rows - 1 do
            for Col := 0 to N.Cols - 1 do
            begin
              Ce := N.Cell(Row, Col);
              case Ce.Kind of
                lkNO: if Row = 0 then Cell(Row, Col, Ce.Opnd, xuRead, '-| |- AND') else Cell(Row, Col, Ce.Opnd, xuRead, '-| |- OR (branch)');
                lkNC: if Row = 0 then Cell(Row, Col, Ce.Opnd, xuRead, '-|/|- AND NOT') else Cell(Row, Col, Ce.Opnd, xuRead, '-|/|- OR NOT (branch)');
                lkPos, lkNeg:
                  begin
                    Cell(Row, Col, Ce.Opnd, xuRead, '-|P|- / -|N|- edge');
                    Cell(Row, Col, Ce.P[0], xuReadWrite, 'edge memory bit');
                  end;
                lkCoil: Cell(Row, Col, Ce.Opnd, xuWrite, '-( )- coil');
                lkCoilNeg: Cell(Row, Col, Ce.Opnd, xuWrite, '-(/)- negated coil');
                lkSet: Cell(Row, Col, Ce.Opnd, xuWrite, '-(S)- set');
                lkReset: Cell(Row, Col, Ce.Opnd, xuWrite, '-(R)- reset');
                lkSD, lkSE, lkSP, lkSS, lkSF:
                  begin
                    Cell(Row, Col, Ce.Opnd, xuWrite, LadKindNames[Ce.Kind] + ' start timer');
                    Cell(Row, Col, Ce.P[0], xuRead, 'time value');
                  end;
                lkCU, lkCD, lkSC:
                  begin
                    Cell(Row, Col, Ce.Opnd, xuWrite, LadKindNames[Ce.Kind] + ' counter');
                    Cell(Row, Col, Ce.P[0], xuRead, 'preset');
                  end;
                lkCall:
                  begin
                    Cell(Row, Col, Ce.Opnd, xuReadWrite, 'CALL');
                    Fb := nil;
                    // the parameters: by the sections of the called block
                    for K := 0 to P.BlockCount - 1 do
                      if SameText('"' + P.Block(K).Name + '"', Trim(Ce.Opnd)) or SameText(P.Block(K).Name, Trim(Ce.Opnd)) then
                        Fb := P.Block(K);
                    if (Fb = nil) and (P.FindDBByName(StringReplace(Trim(Ce.Opnd), '"', '', [rfReplaceAll])) <> nil) then
                      Fb := P.InstanceFB(P.FindDBByName(StringReplace(Trim(Ce.Opnd), '"', '', [rfReplaceAll])));
                    Pins := CallPins(Fb);
                    for K := 0 to High(Pins) do
                      case Fb.Iface.Vars[Pins[K]].Section of
                        vsInput: Cell(Row, Col, CallArg(Ce, K), xuRead, 'call input ' + Fb.Iface.Vars[Pins[K]].Name);
                        vsInOut: Cell(Row, Col, CallArg(Ce, K), xuReadWrite, 'call in/out ' + Fb.Iface.Vars[Pins[K]].Name);
                      else
                        Cell(Row, Col, CallArg(Ce, K), xuWrite, 'call output ' + Fb.Iface.Vars[Pins[K]].Name);
                      end;
                  end;
              else
                begin
                  // a box: its instance and its pins (OUT, ET, CV .. are written)
                  if LadOpndName(Ce.Kind) <> '' then Cell(Row, Col, Ce.Opnd, xuReadWrite, LadKindNames[Ce.Kind] + ' instance');
                  for K := 0 to LadParamCount(Ce.Kind) - 1 do
                  begin
                    Prm := LadParamName(Ce.Kind, K);
                    if Ce.Kind in [lkCmp, lkInRange, lkOutRange] then
                      Cell(Row, Col, Ce.P[K], xuRead, LadKindNames[Ce.Kind] + ' compare ' + Prm)
                    else
                      Cell(Row, Col, Ce.P[K], PinUse(Prm), LadKindNames[Ce.Kind] + ' ' + Prm);
                  end;
                end;
              end;
            end;
          Continue;
        end;
        // STL / SCL text
        InCmt := False;
        CallTgt := '';
        for Row := 0 to N.Stl.Count - 1 do
        begin
          L := N.Stl[Row];
          Toks := LineOperands(L, InCmt);
          Fw := FirstWord(L);
          if (N.Kind = nkSTL) and (Fw = 'CALL') then CallTgt := Trim(Copy(Trim(L), 5, MaxInt));
          for K := 0 to High(Toks) do
          begin
            if not Hits(Toks[K].S, Ex) then Continue;
            Col := Length(UTF8Decode(Copy(L, 1, Toks[K].P - 1)));
            Pw := PrevWord(L, Toks[K].P);
            Nw := NextWord(L, Toks[K].P + Length(Toks[K].S));
            if N.Kind = nkSTL then
            begin
              // the instruction of the line (a label before it: M001: A I0.0)
              U := Trim(L);
              Q := Pos(':', U);
              if (Q > 0) and (Q < Pos(' ', U + ' ')) and (Copy(U, Q, 2) <> ':=') then U := Trim(Copy(U, Q + 1, MaxInt));
              Fw := UpperCase(Copy(U, 1, Pos(' ', U + ' ') - 1));
              Pp := Pos(':=', U);
              if (CallTgt <> '') and (Pp > 0) then
              begin
                // a parameter of the CALL above: its direction from the called block
                Prm := Trim(Copy(U, 1, Pp - 1));
                Pi_ := -1;
                if SclSignature(P, B, CallTgt, Sg) then
                  for J := 0 to High(Sg.Params) do
                    if SameText(Sg.Params[J].Name, Prm) then Pi_ := J;
                if ((Pi_ >= 0) and (Sg.Params[Pi_].Dir = sdOut)) or ((Pi_ < 0) and IsOutPin(Prm)) then
                  Put(xpCode, BI, NI, Row, Col, xuWrite, 'CALL output ' + Prm, Toks[K].S, Trim(L), Ex)
                else if (Pi_ >= 0) and (Sg.Params[Pi_].Dir = sdInOut) then
                  Put(xpCode, BI, NI, Row, Col, xuReadWrite, 'CALL in/out ' + Prm, Toks[K].S, Trim(L), Ex)
                else
                  Put(xpCode, BI, NI, Row, Col, xuRead, 'CALL input ' + Prm, Toks[K].S, Trim(L), Ex);
                Continue;
              end;
              case Fw of
                'A': Put(xpCode, BI, NI, Row, Col, xuRead, 'A (AND)', Toks[K].S, Trim(L), Ex);
                'AN': Put(xpCode, BI, NI, Row, Col, xuRead, 'AN (AND NOT)', Toks[K].S, Trim(L), Ex);
                'O': Put(xpCode, BI, NI, Row, Col, xuRead, 'O (OR)', Toks[K].S, Trim(L), Ex);
                'ON': Put(xpCode, BI, NI, Row, Col, xuRead, 'ON (OR NOT)', Toks[K].S, Trim(L), Ex);
                'X': Put(xpCode, BI, NI, Row, Col, xuRead, 'X (XOR)', Toks[K].S, Trim(L), Ex);
                'XN': Put(xpCode, BI, NI, Row, Col, xuRead, 'XN (XOR NOT)', Toks[K].S, Trim(L), Ex);
                'L', 'LC', 'LAR1', 'LAR2': Put(xpCode, BI, NI, Row, Col, xuRead, Fw + ' (load)', Toks[K].S, Trim(L), Ex);
                '=': Put(xpCode, BI, NI, Row, Col, xuWrite, '= (assign the RLO)', Toks[K].S, Trim(L), Ex);
                'S': Put(xpCode, BI, NI, Row, Col, xuWrite, 'S (set)', Toks[K].S, Trim(L), Ex);
                'R': Put(xpCode, BI, NI, Row, Col, xuWrite, 'R (reset)', Toks[K].S, Trim(L), Ex);
                'T': Put(xpCode, BI, NI, Row, Col, xuWrite, 'T (transfer)', Toks[K].S, Trim(L), Ex);
                'FP', 'FN': Put(xpCode, BI, NI, Row, Col, xuReadWrite, Fw + ' (edge memory)', Toks[K].S, Trim(L), Ex);
                'SD', 'SE', 'SP', 'SS', 'SF': Put(xpCode, BI, NI, Row, Col, xuWrite, Fw + ' (start timer)', Toks[K].S, Trim(L), Ex);
                'CU', 'CD': Put(xpCode, BI, NI, Row, Col, xuWrite, Fw + ' (count)', Toks[K].S, Trim(L), Ex);
                'CALL': Put(xpCode, BI, NI, Row, Col, xuReadWrite, 'CALL', Toks[K].S, Trim(L), Ex);
              else
                Put(xpCode, BI, NI, Row, Col, xuRead, Fw, Toks[K].S, Trim(L), Ex);
              end;
              Continue;
            end;
            // SCL: the place in the statement
            Q := Toks[K].P + Length(Toks[K].S);
            if (Nw = ':=') and ((Trim(Copy(L, 1, Toks[K].P - 1)) = '') or (Pw = 'THEN') or (Pw = 'ELSE') or (Pw = 'DO') or
              AnsiEndsStr(';', Trim(Copy(L, 1, Toks[K].P - 1)))) then
            begin
              Put(xpCode, BI, NI, Row, Col, xuWrite, ':= (assignment)', Toks[K].S, Trim(L), Ex);
              Continue;
            end;
            if (Q <= Length(L)) and (L[Q] = '(') or (Nw = '(') then
            begin
              Put(xpCode, BI, NI, Row, Col, xuReadWrite, 'call (instance)', Toks[K].S, Trim(L), Ex);
              Continue;
            end;
            if (Pw = '=>') or (Pw = ':=') then
              if SclCallAt(N.Stl, Row, Toks[K].P - 1, C) then
              begin
                try
                  // a parameter of a call: its name before := / =>
                  U := TrimRight(Copy(L, 1, Toks[K].P - 1));
                  SetLength(U, Length(U) - 2);
                  U := TrimRight(U);
                  J := Length(U);
                  while (J >= 1) and (U[J] in WordCh) do Dec(J);
                  Prm := Copy(U, J + 1, MaxInt);
                  Pi_ := -1;
                  if SclSignature(P, B, C.Callee, Sg) then
                    for J := 0 to High(Sg.Params) do
                      if SameText(Sg.Params[J].Name, Prm) then Pi_ := J;
                  if Pw = '=>' then Put(xpCode, BI, NI, Row, Col, xuWrite, 'call output ' + Prm, Toks[K].S, Trim(L), Ex)
                  else if (Pi_ >= 0) and (Sg.Params[Pi_].Dir = sdInOut) then
                    Put(xpCode, BI, NI, Row, Col, xuReadWrite, 'call in/out ' + Prm, Toks[K].S, Trim(L), Ex)
                  else
                    Put(xpCode, BI, NI, Row, Col, xuRead, 'call input ' + Prm, Toks[K].S, Trim(L), Ex);
                finally
                  C.Given.Free;
                end;
                Continue;
              end;
            // a value that is read: how (NOT, AND, OR, a compare) and in what (IF, WHILE ..)
            if Pw = 'NOT' then U := 'NOT'
            else if (Pw = 'AND') or (Pw = '&') or (Pw = 'OR') or (Pw = 'XOR') then U := Pw
            else if (Nw = 'AND') or (Nw = '&') or (Nw = 'OR') or (Nw = 'XOR') then U := Nw
            else if (Pw = '=') or (Pw = '<>') or (Pw = '<') or (Pw = '>') or (Pw = '<=') or (Pw = '>=') or
              (Nw = '=') or (Nw = '<>') or (Nw = '<') or (Nw = '>') or (Nw = '<=') or (Nw = '>=') then U := 'compare'
            else U := 'read';
            Fw := FirstWord(L);
            if (Fw = 'IF') or (Fw = 'ELSIF') or (Fw = 'WHILE') or (Fw = 'UNTIL') or (Fw = 'CASE') then U := Fw + ': ' + U
            else if U = 'read' then U := 'read (value)';
            Put(xpCode, BI, NI, Row, Col, xuRead, U, Toks[K].S, Trim(L), Ex);
          end;
        end;
      end;
    end;
    // the watch table, the signal table
    B := nil;
    Res.Iface := nil;
    if not LocalT then
    begin
      for K := 0 to High(P.Watch) do
        if Hits(P.Watch[K].Address, Ex) then
          Put(xpWatch, -1, -1, K, 0, xuTable, 'watch table row ' + IntToStr(K + 1), P.Watch[K].Address,
            P.Watch[K].Address + IfThen(P.Watch[K].ModifyValue <> '', '  modify ' + P.Watch[K].ModifyValue, ''), Ex);
      for K := 0 to High(P.Signals) do
        if Hits(P.Signals[K].Address, Ex) then
          Put(xpSignal, -1, -1, K, 0, xuTable, 'signal table row ' + IntToStr(K + 1) + ' (writes the input)',
            P.Signals[K].Address, P.Signals[K].Address, Ex);
      // where it is declared: a tag on the address, a DB variable
      for K := 0 to High(P.Tags) do
        if Hits(P.Tags[K].Address, Ex) then
          Put(xpTag, -1, -1, K, 0, xuDecl, 'PLC tag "' + P.Tags[K].Name + '"', P.Tags[K].Address,
            Format('"%s" : %s  %s', [P.Tags[K].Name, P.Tags[K].TypeText, P.Tags[K].Address]), Ex);
      Q := Pos('".', Target);
      if (Copy(Trim(Target), 1, 1) = '"') and (Q > 0) and (P.FindDBByName(Copy(Trim(Target), 2, Q - 2)) <> nil) then
        with P.FindDBByName(Copy(Trim(Target), 2, Q - 2)) do
        begin
          J := FindVar(Copy(Trim(Target), Q + 2, Length(Trim(Target))));
          if J >= 0 then
            for K := 0 to P.DBCount - 1 do
              if P.DB(K).Name = Name then
                Put(xpDbVar, K, -1, J, 0, xuDecl, Format('DB%d "%s" variable', [Number, Name]), Trim(Target),
                  Format('%s : %s := %s', [Vars[J].Name, Vars[J].TypeText, Vars[J].Start]), True);
        end;
    end
    else
    begin
      U := Copy(Trim(Target), 2, MaxInt);
      Q := Pos('.', U + '.');
      if Pos('[', U) in [1..Q - 1] then Q := Pos('[', U);
      K := Cur.Iface.FindVar(Copy(U, 1, Q - 1));
      if K >= 0 then
        for J := 0 to P.BlockCount - 1 do
          if P.Block(J) = Cur then
            Put(xpIface, J, -1, K, 0, xuDecl, 'interface: ' + SectionNames[Cur.Iface.Vars[K].Section], Trim(Target),
              Format('%s : %s', [Cur.Iface.Vars[K].Name, Cur.Iface.Vars[K].TypeText]), True);
    end;
  finally
    Res.Free;
  end;
end;

function XrefIoUsage(P: TPlcProject): TIoUses;
var
  Res: TResolver;
  Keys: TStringList;
  BI, NI, Row, Col, K, J: Integer;
  B: TBlock;
  N: TNetwork;
  Ce: TLadCell;
  Toks: TToks;
  InCmt: Boolean;
  R: TXrefs;
  Info: string;
  TA: TAddr;
  E: string;
  T: TIoUse;

  procedure Take(const S: string);
  var
    O: TOperand;
    Er, Key: string;
    M: Integer;
  begin
    if Trim(S) = '' then Exit;
    if not Res.Resolve(Trim(S), O, Er, False) or (O.Kind <> okAddr) then Exit;
    if not (O.A.Area in [arI, arQ, arPI, arPQ]) then Exit;
    Key := StringReplace(FormatAddr(O.A, P.Family), ' ', '', [rfReplaceAll]);
    if Keys.IndexOf(Key) >= 0 then Exit;
    Keys.Add(Key);
    M := Length(Result);
    SetLength(Result, M + 1);
    Result[M].Addr := Key;
    Result[M].A := O.A;
    Result[M].IsInput := O.A.Area in [arI, arPI];
  end;

  function Before(const X, Y: TIoUse): Boolean;
  begin
    // the inputs first, then by byte, size, bit
    if X.IsInput <> Y.IsInput then Exit(X.IsInput);
    if X.A.Ofs <> Y.A.Ofs then Exit(X.A.Ofs < Y.A.Ofs);
    if X.A.Size <> Y.A.Size then Exit(X.A.Size < Y.A.Size);
    Result := X.A.Bit < Y.A.Bit;
  end;

begin
  Result := nil;
  Res := TResolver.Create(P);
  Keys := TStringList.Create;
  try
    for K := 0 to High(P.Tags) do Take(P.Tags[K].Address);
    for BI := 0 to P.BlockCount - 1 do
    begin
      B := P.Block(BI);
      Res.Iface := B.Iface;
      for NI := 0 to B.NetCount - 1 do
      begin
        N := B.Net(NI);
        if N.Kind in [nkFBD, nkCFC] then
        begin
          for Row := 0 to High(N.Nodes) do
          begin
            Take(N.Nodes[Row].Inst);
            for J := 0 to High(N.Nodes[Row].Ins) do Take(N.Nodes[Row].Ins[J].Opnd);
            for J := 0 to High(N.Nodes[Row].Outs) do Take(N.Nodes[Row].Outs[J].Opnd);
          end;
          Continue;
        end;
        if N.Kind = nkLAD then
        begin
          for Row := 0 to N.Rows - 1 do
            for Col := 0 to N.Cols - 1 do
            begin
              Ce := N.Cell(Row, Col);
              Take(Ce.Opnd);
              for J := 0 to 4 do Take(Ce.P[J]);
              if Ce.Args <> '' then
                for J := 0 to 31 do
                  if CallArg(Ce, J) <> '' then Take(CallArg(Ce, J));
            end;
          Continue;
        end;
        InCmt := False;
        for Row := 0 to N.Stl.Count - 1 do
        begin
          Toks := LineOperands(N.Stl[Row], InCmt);
          for J := 0 to High(Toks) do Take(Toks[J].S);
        end;
      end;
    end;
    Res.Iface := nil;
    // what it is, how it is used
    for K := 0 to High(Result) do
    begin
      Result[K].Symbol := Res.SymbolOf(Result[K].A);
      for J := 0 to High(P.Tags) do
        if ParseAddr(P.Tags[J].Address, TA, E) and SameAddr(TA, Result[K].A) then
        begin
          Result[K].TypeText := P.Tags[J].TypeText;
          Result[K].Comment := P.Tags[J].Comment;
          Break;
        end;
      if Result[K].TypeText = '' then
        case Result[K].A.Size of
          osBit: Result[K].TypeText := 'Bool';
          osByte: Result[K].TypeText := 'Byte';
          osWord: Result[K].TypeText := 'Word';
        else
          Result[K].TypeText := 'DWord';
        end;
      if XrefFind(P, Result[K].Addr, nil, Info, R) then
        for J := 0 to High(R) do
          case R[J].Use of
            xuRead: Inc(Result[K].Reads);
            xuWrite: Inc(Result[K].Writes);
            xuReadWrite:
              begin
                Inc(Result[K].Reads);
                Inc(Result[K].Writes);
              end;
            xuTable: Inc(Result[K].Tables);
          end;
    end;
    // sorted: the inputs, then the outputs, by address
    for K := 1 to High(Result) do
    begin
      T := Result[K];
      J := K - 1;
      while (J >= 0) and Before(T, Result[J]) do
      begin
        Result[J + 1] := Result[J];
        Dec(J);
      end;
      Result[J + 1] := T;
    end;
  finally
    Keys.Free;
    Res.Free;
  end;
end;

function XrefWhere(P: TPlcProject; const X: TXref): string;
begin
  case X.Place of
    xpCode:
      begin
        Result := P.Block(X.Blk).Title;
        if P.Block(X.Blk).Net(X.Net).Kind in [nkFBD, nkCFC] then
          Result := Result + Format('  nw %d  box #%d', [X.Net + 1, X.Row])
        else if P.Block(X.Blk).Net(X.Net).Kind = nkLAD then
          Result := Result + Format('  nw %d  row %d col %d', [X.Net + 1, X.Row + 1, X.Col + 1])
        else
          Result := Result + Format('  nw %d  line %d', [X.Net + 1, X.Row + 1]);
      end;
    xpWatch: Result := 'Watch table';
    xpSignal: Result := 'I/O: signal table';
    xpTag: Result := 'PLC tag table';
    xpDbVar: Result := 'Data blocks';
  else
    Result := P.Block(X.Blk).Title + '  interface';
  end;
end;

end.
