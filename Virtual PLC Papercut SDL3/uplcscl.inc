{ SCL - Structured Control Language (IEC 61131-3 Structured Text), included by uPlcCompiler.

  An SCL network is compiled into the same op code as STL and LAD, using a
  value stack (opSPush / opSStore / opSBin ...): every S7 value up to 32 bit is
  held exactly in a Double. Integer results wrap to their type (Int 16 bit,
  DInt 32 bit), REAL is rounded to single precision, like on the CPU.

  Supported:
    VAR_TEMP name : Type; ... END_VAR      locals in L (#name)
    target := expression;
    IF .. THEN .. ELSIF .. THEN .. ELSE .. END_IF;
    CASE int OF 1: ..; 2, 4..6: ..; ELSE .. END_CASE;
    FOR #i := a TO b [BY const] DO .. END_FOR;   WHILE .. DO .. END_WHILE;
    REPEAT .. UNTIL .. END_REPEAT;   EXIT;   CONTINUE;   RETURN;
    REGION / END_REGION (ignored), // and (* *) comments
    operators (priority high -> low): ( )  **  unary - NOT  * / MOD  + -
      < > <= >=  = <>  AND &  XOR  OR
    functions: ABS SQR SQRT LN LOG EXP SIN COS TAN ASIN ACOS ATAN FRAC
      TRUNC ROUND CEIL FLOOR MIN MAX LIMIT SEL NORM_X SCALE_X SHL SHR ROL ROR
      <type>_TO_<type> conversions (INT_TO_REAL, REAL_TO_INT, DINT_TO_INT ...)
    "DB".Timer.TON / TOF / TP / TONR (IN := .., PT := .., Q => .., ET => ..);
    "DB".Counter.CTU / CTD / CTUD (CU := .., R := .., PV := .., Q => .., CV => ..);
    FC calls: "Name"(); FC1();
    operands: "Tag", "DB".Var, "DB".Arr[expression], %MW20, MW20, DB1.DBW2, #temp
  Types follow TIA: implicit widening (Int -> DInt -> Real), REAL to INT
  needs a conversion, conditions must be BOOL. }

type
  TSclTok = (stEOF, stIdent, stNum, stTyped, stQuoted, stHash, stPercent, stStr, stSym);

  TSclToken = record
    Kind: TSclTok;
    S: string;
    Line: Integer;
  end;

  ESclError = class(Exception);

  TOpChunk = array of TOp;

const
  { opSBin }
  sbAdd = 0; sbSub = 1; sbMul = 2; sbDiv = 3; sbMod = 4; sbPow = 5; sbAnd = 6; sbOr = 7; sbXor = 8;
  sbBAnd = 9; sbBOr = 10; sbBXor = 11; sbEq = 12; sbNe = 13; sbLt = 14; sbGt = 15; sbLe = 16; sbGe = 17;
  sbMin = 18; sbMax = 19; sbShl = 20; sbShr = 21; sbRol = 22; sbRor = 23;
  { opSUn }
  suNeg = 0; suNot = 1; suNotBits = 2; suAbs = 3; suSqrt = 4; suSqr = 5; suLn = 6; suExp = 7; suSin = 8;
  suCos = 9; suTan = 10; suAsin = 11; suAcos = 12; suAtan = 13; suRound = 14; suTrunc = 15; suCeil = 16;
  suFloor = 17; suWrap = 18; suBool = 19; suLog = 20; suFrac = 21;
  { opSTern }
  stLimit = 0; stSel = 1; stNormX = 2; stScaleX = 3;

function SclRank(T: TDataType): Integer;
begin
  case T of
    dtBool: Result := 0;
    dtByte, dtChar, dtSInt, dtUSInt: Result := 1;
    dtWord, dtInt, dtUInt, dtS5Time, dtDate: Result := 2;
    dtDWord, dtDInt, dtUDInt, dtTime, dtTOD: Result := 3;
    dtReal: Result := 4;
  else
    Result := 3;
  end;
end;

function SclIsBits(T: TDataType): Boolean;
begin
  Result := T in [dtByte, dtWord, dtDWord];
end;

function SclIsNum(T: TDataType): Boolean;
begin
  Result := T in [dtByte, dtWord, dtDWord, dtChar, dtSInt, dtUSInt, dtInt, dtUInt, dtDInt, dtUDInt, dtReal,
    dtTime, dtS5Time, dtDate, dtTOD];
end;

{ the type of a + b: REAL wins, then TIME, then the wider integer }
function SclArith(A, B: TDataType): TDataType;
begin
  if (A = dtReal) or (B = dtReal) then Exit(dtReal);
  if (A = dtTime) or (B = dtTime) then Exit(dtTime);
  if SclRank(A) > SclRank(B) then Result := A
  else if SclRank(B) > SclRank(A) then Result := B
  else if SclIsBits(A) and not SclIsBits(B) then Result := B
  else Result := A;
  if Result = dtBool then Result := dtInt;
end;

procedure TCompiler.CompileScl(N: TNetwork);
var
  Toks: array of TSclToken;
  P: Integer;
  Base: Integer;
  LoopExits, LoopConts: array of array of Integer;
  LoopDepth, CaseDepth: Integer;
  ErrCount: Integer;

  { ---------- lexer ---------- }

  procedure AddTok(K: TSclTok; const S: string; L: Integer);
  var
    I: Integer;
  begin
    I := Length(Toks);
    SetLength(Toks, I + 1);
    Toks[I].Kind := K;
    Toks[I].S := S;
    Toks[I].Line := L;
  end;

  procedure Lex;
  var
    Li, I, J, Len: Integer;
    S: string;
    InCmt: Boolean;
    C: Char;

    function At(K: Integer): Char;
    begin
      if K <= Len then Result := S[K] else Result := #0;
    end;

  begin
    InCmt := False;
    for Li := 0 to N.Stl.Count - 1 do
    begin
      S := N.Stl[Li];
      Len := Length(S);
      I := 1;
      while I <= Len do
      begin
        C := S[I];
        if InCmt then
        begin
          if (C = '*') and (At(I + 1) = ')') then
          begin
            InCmt := False;
            Inc(I, 2);
          end
          else
            Inc(I);
          Continue;
        end;
        if C in [' ', #9] then begin Inc(I); Continue; end;
        if (C = '/') and (At(I + 1) = '/') then Break;
        if (C = '(') and (At(I + 1) = '*') then
        begin
          InCmt := True;
          Inc(I, 2);
          Continue;
        end;
        if C = '"' then
        begin
          J := I + 1;
          while (J <= Len) and (S[J] <> '"') do Inc(J);
          AddTok(stQuoted, Copy(S, I + 1, J - I - 1), Li);
          I := J + 1;
          Continue;
        end;
        if C = '''' then
        begin
          J := I + 1;
          while (J <= Len) and (S[J] <> '''') do Inc(J);
          AddTok(stStr, Copy(S, I + 1, J - I - 1), Li);
          I := J + 1;
          Continue;
        end;
        if C = '#' then
        begin
          J := I + 1;
          while (J <= Len) and (S[J] in ['A'..'Z', 'a'..'z', '0'..'9', '_']) do Inc(J);
          AddTok(stHash, Copy(S, I + 1, J - I - 1), Li);
          I := J;
          Continue;
        end;
        if C = '%' then
        begin
          J := I + 1;
          while (J <= Len) and (S[J] in ['A'..'Z', 'a'..'z', '0'..'9', '.', ':']) do
          begin
            // %MW20..: a range, not part of the address
            if (S[J] = '.') and (At(J + 1) = '.') then Break;
            Inc(J);
          end;
          AddTok(stPercent, Copy(S, I, J - I), Li);
          I := J;
          Continue;
        end;
        if C in ['0'..'9'] then
        begin
          J := I;
          while (J <= Len) and (S[J] in ['0'..'9', '_']) do Inc(J);
          if (J <= Len) and (S[J] = '#') then
          begin
            // 16#FF, 2#1010
            Inc(J);
            while (J <= Len) and (S[J] in ['0'..'9', 'A'..'F', 'a'..'f', '_']) do Inc(J);
            AddTok(stTyped, Copy(S, I, J - I), Li);
            I := J;
            Continue;
          end;
          if (J <= Len) and (S[J] = '.') and (At(J + 1) in ['0'..'9']) then
          begin
            Inc(J);
            while (J <= Len) and (S[J] in ['0'..'9', '_']) do Inc(J);
          end;
          if (J <= Len) and (S[J] in ['e', 'E']) and ((At(J + 1) in ['0'..'9']) or
            ((At(J + 1) in ['+', '-']) and (At(J + 2) in ['0'..'9']))) then
          begin
            Inc(J, 2);
            while (J <= Len) and (S[J] in ['0'..'9']) do Inc(J);
          end;
          AddTok(stNum, StringReplace(Copy(S, I, J - I), '_', '', [rfReplaceAll]), Li);
          I := J;
          Continue;
        end;
        if C in ['A'..'Z', 'a'..'z', '_'] then
        begin
          J := I;
          while (J <= Len) and (S[J] in ['A'..'Z', 'a'..'z', '0'..'9', '_']) do Inc(J);
          if (J <= Len) and (S[J] = '#') then
          begin
            // T#5S, S5T#2S, TIME#.., L#10, W#16#FF, C#5 ...
            Inc(J);
            if (J <= Len) and (S[J] = '-') then Inc(J);
            while (J <= Len) and (S[J] in ['A'..'Z', 'a'..'z', '0'..'9', '_', '#', '.']) do Inc(J);
            AddTok(stTyped, Copy(S, I, J - I), Li);
          end
          else
            AddTok(stIdent, Copy(S, I, J - I), Li);
          I := J;
          Continue;
        end;
        // symbols
        J := I + 1;
        if (C = ':') and (At(I + 1) = '=') then J := I + 2
        else if (C = '=') and (At(I + 1) = '>') then J := I + 2
        else if (C = '<') and (At(I + 1) in ['=', '>']) then J := I + 2
        else if (C = '>') and (At(I + 1) = '=') then J := I + 2
        else if (C = '*') and (At(I + 1) = '*') then J := I + 2
        else if (C = '.') and (At(I + 1) = '.') then J := I + 2;
        AddTok(stSym, Copy(S, I, J - I), Li);
        I := J;
      end;
    end;
    if Length(Toks) > 0 then AddTok(stEOF, '', Toks[High(Toks)].Line) else AddTok(stEOF, '', 0);
  end;

  { ---------- token helpers ---------- }

  function Tok: TSclToken;
  begin
    Result := Toks[P];
  end;

  function PeekTok(K: Integer): TSclToken;
  begin
    if P + K <= High(Toks) then Result := Toks[P + K] else Result := Toks[High(Toks)];
  end;

  procedure Next;
  begin
    if P < High(Toks) then Inc(P);
  end;

  function IsSym(const S: string): Boolean;
  begin
    Result := (Toks[P].Kind = stSym) and (Toks[P].S = S);
  end;

  function IsKw(const S: string): Boolean;
  begin
    Result := (Toks[P].Kind = stIdent) and SameText(Toks[P].S, S);
  end;

  procedure Fail(const S: string);
  begin
    raise ESclError.Create(S);
  end;

  procedure Expect(const S: string);
  begin
    if IsSym(S) or IsKw(S) then Next
    else if Tok.Kind = stEOF then Fail(Format('"%s" expected at the end', [S]))
    else Fail(Format('"%s" expected, found "%s"', [S, Tok.S]));
  end;

  function IsKeyword(const S: string): Boolean;
  const
    Kw: array[0..33] of string = ('IF', 'THEN', 'ELSIF', 'ELSE', 'END_IF', 'CASE', 'OF', 'END_CASE', 'FOR',
      'TO', 'BY', 'DO', 'END_FOR', 'WHILE', 'END_WHILE', 'REPEAT', 'UNTIL', 'END_REPEAT', 'EXIT', 'CONTINUE',
      'RETURN', 'AND', 'OR', 'XOR', 'NOT', 'MOD', 'TRUE', 'FALSE', 'VAR_TEMP', 'END_VAR', 'REGION',
      'END_REGION', 'VAR', 'GOTO');
  var
    K: Integer;
  begin
    for K := 0 to High(Kw) do
      if SameText(Kw[K], S) then Exit(True);
    Result := False;
  end;

  { ---------- emitting ---------- }

  function E(ACode: TOpCode; ACat: TTimeCat; AType: TDataType; ASub: Integer = 0): Integer;
  begin
    Result := Emit(ACode, ACat);
    FBlock.Ops[Result].DType := AType;
    FBlock.Ops[Result].Sub := ASub;
  end;

  procedure EK(V: Double; T: TDataType);
  var
    I: Integer;
  begin
    I := E(opSPushK, tcWord, T);
    FBlock.Ops[I].K := V;
  end;

  function Cat(T: TDataType): TTimeCat;
  begin
    if T = dtReal then Result := tcFloat else Result := tcFix;
  end;

  procedure SetMon(OpIx, Line: Integer);
  begin
    if (Line >= 0) and (Line < N.Stl.Count) then FBlock.Ops[OpIx].Mon := Base + Line;
  end;

  function TakeChunk(From: Integer): TOpChunk;
  var
    K: Integer;
  begin
    SetLength(Result, Length(FBlock.Ops) - From);
    for K := 0 to High(Result) do Result[K] := FBlock.Ops[From + K];
    SetLength(FBlock.Ops, From);
  end;

  procedure PutChunk(const C: TOpChunk);
  var
    K, B0: Integer;
  begin
    B0 := Length(FBlock.Ops);
    SetLength(FBlock.Ops, B0 + Length(C));
    for K := 0 to High(C) do FBlock.Ops[B0 + K] := C[K];
  end;

  { ---------- operands ---------- }

  type
    TRef = record
      Opd: TOperand;
      T: TDataType;
      Indexed: Boolean;   // variable indexes: their bit offset is pushed before the value
      IsBlock: Boolean;   // a whole struct / array / IEC instance (a := b copies it)
      Info: TVarInfo;     // IsBlock: its type
      Text: string;
      Method: string;     // TON / CTU ... when the path is a timer / counter call
    end;

  function TypeOfOpd(const O: TOperand): TDataType;
  begin
    Result := O.DType;
    if Result in [dtNone, dtIECTimer, dtIECCounter] then
      case O.A.Size of
        osBit: Result := dtBool;
        osByte: Result := dtByte;
        osWord: Result := dtInt;
      else
        Result := dtDInt;
      end;
    if O.A.Area in [arT, arC] then Result := dtBool;
  end;

  function Expr: TDataType; forward;

  { an operand path: "DB".Var, "DB".Arr[#i].Member, "DB".M[#i].Sub[#j], #temp[2].x, "Tag", %MW20;
    variable indexes are compiled now: each opSIndex adds its element to a bit offset on the stack,
    pushed before the value; the operand itself is resolved at the first element of every array }
  function PathEx(AllowBlock: Boolean): TRef;
  var
    T: TSclToken;
    Er, U, Disp: string;
    IxT: TDataType;
    V: TVarInfo;
    I: Integer;
  begin
    FillChar(Result, SizeOf(Result), 0);
    Result.Opd.Block := -1;
    T := Tok;
    case T.Kind of
      stHash: Result.Text := '#' + T.S;
      stQuoted: Result.Text := '"' + T.S + '"';
      stPercent, stIdent: Result.Text := T.S;
    else
      Fail('operand expected, found "' + T.S + '"');
    end;
    Disp := Result.Text;
    Next;
    while True do
    begin
      if IsSym('.') then
      begin
        U := UpperCase(PeekTok(1).S);
        if (PeekTok(1).Kind = stIdent) and ((U = 'TON') or (U = 'TOF') or (U = 'TP') or (U = 'TONR') or
          (U = 'CTU') or (U = 'CTD') or (U = 'CTUD')) and (PeekTok(2).Kind = stSym) and (PeekTok(2).S = '(') then
        begin
          Result.Method := U;
          Next;
          Next;
          Break;
        end;
        Next;
        case Tok.Kind of
          stIdent, stNum, stQuoted:
            begin
              Result.Text := Result.Text + '.' + Tok.S;
              Disp := Disp + '.' + Tok.S;
            end;
        else
          Fail('member name expected after "."');
        end;
        Next;
        Continue;
      end;
      if IsSym('[') then
      begin
        Next;
        if (Tok.Kind = stNum) and (PeekTok(1).Kind = stSym) and (PeekTok(1).S = ']') then
        begin
          Result.Text := Result.Text + '[' + Tok.S + ']';
          Disp := Disp + '[' + Tok.S + ']';
          Next;
          Next;
          Continue;
        end;
        // a variable index: computed at run time, the operand is resolved at the first element
        if not FRes.ResolveVar(Result.Text, V, Er) then Fail(Er);
        if not V.IsArray then Fail(Disp + ' is not an array');
        IxT := Expr;
        if not (IxT in [dtInt, dtDInt, dtSInt, dtUSInt, dtUInt, dtUDInt, dtByte, dtWord, dtDWord]) then
          Fail('array index must be an integer');
        Expect(']');
        if V.T = dtBool then I := E(opSIndex, tcFix, dtDInt, 1)
        else I := E(opSIndex, tcFix, dtDInt, ElemStride(V.T, V.Udt) * 8);
        FBlock.Ops[I].Lo := V.Lo;
        FBlock.Ops[I].Hi := V.Hi;
        FBlock.Ops[I].Ext := Ord(Result.Indexed);   // an outer index is already on the stack
        FBlock.Ops[I].Opd.Text := Disp;
        Result.Text := Result.Text + Format('[%d]', [V.Lo]);
        Disp := Disp + '[..]';
        Result.Indexed := True;
        Continue;
      end;
      Break;
    end;
    // a whole struct, array or IEC instance as the target or source of a := b
    if AllowBlock and (Result.Method = '') and (Result.Text[1] in ['"', '#']) and
      FRes.ResolveVar(Result.Text, V, Er) and
      (V.IsArray or (V.T in [dtStruct, dtIECTimer, dtIECCounter])) then
    begin
      Result.IsBlock := True;
      Result.Info := V;
      Result.T := V.T;
      Result.Opd.Kind := okAddr;
      Result.Opd.A := V.A;
      Result.Opd.DType := V.T;
      Result.Opd.Text := Result.Text;
      Exit;
    end;
    if not FRes.Resolve(Result.Text, Result.Opd, Er, False) then Fail(Er);
    if Result.Opd.Kind <> okAddr then Fail(Result.Text + ': variable or address expected');
    Result.T := TypeOfOpd(Result.Opd);
    if Result.Method <> '' then Result.T := Result.Opd.DType;
  end;

  function Path: TRef;
  begin
    Result := PathEx(False);
  end;

  { the type of a struct / array as TIA writes it, and the bytes it takes }
  function BlockTypeName(const V: TVarInfo): string;
  begin
    if V.T = dtStruct then Result := '"' + V.Udt.Name + '"' else Result := DataTypeNames[V.T];
    if V.IsArray then Result := Format('Array[%d..%d] of %s', [V.Lo, V.Hi, Result]);
  end;

  function BlockBytes(const V: TVarInfo): Integer;
  begin
    if not V.IsArray then
    begin
      if V.T = dtStruct then Result := V.Udt.Size else Result := DataTypeSize(V.T);
    end
    else if V.T = dtBool then
      Result := (V.Hi - V.Lo + 1 + 7) div 8
    else
      Result := (V.Hi - V.Lo + 1) * ElemStride(V.T, V.Udt);
  end;

  { a := b with a whole struct / array: the same type on both sides, copied as bytes }
  procedure BlockAssign(const R: TRef; Line: Integer);
  var
    R2: TRef;
    K, Bytes: Integer;
  begin
    if not (Tok.Kind in [stHash, stQuoted, stIdent]) then
      Fail(Format('%s is %s: a variable of the same type expected after :=', [R.Text, BlockTypeName(R.Info)]));
    R2 := PathEx(True);
    if R2.Method <> '' then Fail('a timer call gives no value');
    if not R2.IsBlock then
      Fail(Format('type mismatch: %s := %s (%s is %s)', [BlockTypeName(R.Info), DataTypeNames[R2.T], R.Text,
        BlockTypeName(R.Info)]));
    if not SameText(BlockTypeName(R.Info), BlockTypeName(R2.Info)) then
      Fail(Format('type mismatch: %s := %s', [BlockTypeName(R.Info), BlockTypeName(R2.Info)]));
    if (R.Info.A.Bit <> 0) or (R2.Info.A.Bit <> 0) then Fail('a Bool array must start on a byte');
    Bytes := BlockBytes(R.Info);
    K := E(opSCopy, tcWord, dtNone, Bytes);
    FBlock.Ops[K].Opd := R.Opd;
    FBlock.Ops[K].Ext := AddParam(R2.Opd);
    FBlock.Ops[K].Lo := Ord(R.Indexed) or 2 * Ord(R2.Indexed);
    FBlock.Ops[K].Weight := Min(255, 2 + Bytes div 4);
    SetMon(K, Line);
  end;

  procedure PushRef(const R: TRef);
  var
    I: Integer;
  begin
    if R.Indexed then I := E(opSPushIdx, tcWord, R.T)
    else I := E(opSPush, tcWord, R.T);
    FBlock.Ops[I].Opd := R.Opd;
  end;

  function StoreRef(const R: TRef; Line: Integer): Integer;
  begin
    if R.Indexed then Result := E(opSStoreIdx, tcWord, R.T)
    else Result := E(opSStore, tcWord, R.T);
    FBlock.Ops[Result].Opd := R.Opd;
    SetMon(Result, Line);
  end;

  { can a value of type Src go to a variable of type Dst? }
  procedure CheckAssign(Dst, Src: TDataType; const What: string);
  begin
    if Dst = Src then Exit;
    if (Dst = dtBool) <> (Src = dtBool) then
      Fail(Format('type mismatch: %s := %s (%s)', [DataTypeNames[Dst], DataTypeNames[Src], What]));
    if (Src = dtReal) and (Dst <> dtReal) then
      Fail(Format('REAL to %s needs a conversion: REAL_TO_%s(...) (%s)', [DataTypeNames[Dst],
        UpperCase(DataTypeNames[Dst]), What]));
    if (Dst in [dtTime, dtTOD]) and not (Src in [dtTime, dtTOD, dtDInt]) and (SclRank(Src) < 3) then
      Fail(Format('type mismatch: %s := %s', [DataTypeNames[Dst], DataTypeNames[Src]]));

  end;

  { ---------- function calls ---------- }

  { the arguments in the order of Names (positional or name := value); each
    argument's code is moved into place, so the names may come in any order }
  function Args(const Names: array of string; out Types: array of TDataType; MinArgs: Integer): Integer;
  var
    Chunks: array of TOpChunk;
    Given: array of Boolean;
    K, Pos0, Ix, Cnt: Integer;
    Nm: string;
    T: TDataType;
  begin
    SetLength(Chunks, Length(Names));
    SetLength(Given, Length(Names));
    for K := 0 to High(Names) do
    begin
      Given[K] := False;
      Types[K] := dtNone;
    end;
    Expect('(');
    Cnt := 0;
    while not IsSym(')') do
    begin
      Ix := Cnt;
      if (Tok.Kind = stIdent) and (PeekTok(1).Kind = stSym) and (PeekTok(1).S = ':=') then
      begin
        Nm := UpperCase(Tok.S);
        Ix := -1;
        for K := 0 to High(Names) do
          if Names[K] = Nm then Ix := K;
        if Ix < 0 then Fail('unknown parameter ' + Nm);
        Next;
        Next;
      end;
      if Ix > High(Names) then Fail('too many parameters');
      Pos0 := Length(FBlock.Ops);
      T := Expr;
      Chunks[Ix] := TakeChunk(Pos0);
      Types[Ix] := T;
      Given[Ix] := True;
      Inc(Cnt);
      if IsSym(',') then Next else Break;
    end;
    Expect(')');
    Result := 0;
    for K := 0 to High(Names) do
    begin
      if Given[K] then
      begin
        PutChunk(Chunks[K]);
        Inc(Result);
      end
      else if K < MinArgs then
        Fail('parameter ' + Names[K] + ' missing');
    end;
  end;

  function TypeByName(const S: string; out T: TDataType): Boolean;
  var
    Lo, Hi: Integer;
  begin
    Result := ParseDataType(S, T, Lo, Hi) and (T in [dtBool, dtByte, dtWord, dtDWord, dtChar, dtSInt, dtUSInt,
      dtInt, dtUInt, dtDInt, dtUDInt, dtReal, dtTime, dtS5Time, dtDate, dtTOD]);
    if SameText(S, 'LREAL') then
    begin
      T := dtReal;
      Result := True;
    end;
  end;

  function Call(const Name: string): TDataType;
  var
    U, A, B: string;
    Q, Cnt: Integer;
    Ts: array[0..3] of TDataType;
    TA, TB: TDataType;
    Un: Integer;
  begin
    U := UpperCase(Name);
    Q := Pos('_TO_', U);
    if Q > 0 then
    begin
      A := Copy(U, 1, Q - 1);
      B := Copy(U, Q + 4, MaxInt);
      if TypeByName(A, TA) and TypeByName(B, TB) then
      begin
        Args(['IN'], Ts, 1);
        if TB = dtBool then E(opSUn, tcWord, dtBool, suBool)
        else
        begin
          if (Ts[0] = dtReal) and (TB <> dtReal) then E(opSUn, tcFloat, TB, suRound);
          E(opSUn, tcWord, TB, suWrap);
        end;
        Exit(TB);
      end;
    end;
    Un := -1;
    case U of
      'ABS': Un := suAbs;
      'SQRT': Un := suSqrt;
      'SQR': Un := suSqr;
      'LN': Un := suLn;
      'LOG': Un := suLog;
      'EXP': Un := suExp;
      'SIN': Un := suSin;
      'COS': Un := suCos;
      'TAN': Un := suTan;
      'ASIN': Un := suAsin;
      'ACOS': Un := suAcos;
      'ATAN': Un := suAtan;
      'FRAC': Un := suFrac;
      'TRUNC': Un := suTrunc;
      'ROUND': Un := suRound;
      'CEIL': Un := suCeil;
      'FLOOR': Un := suFloor;
    end;
    if Un >= 0 then
    begin
      Args(['IN'], Ts, 1);
      if not SclIsNum(Ts[0]) then Fail(U + ': number expected');
      case Un of
        suAbs:
          begin
            E(opSUn, Cat(Ts[0]), Ts[0], suAbs);
            Exit(Ts[0]);
          end;
        suTrunc, suRound, suCeil, suFloor:
          begin
            E(opSUn, tcFloat, dtDInt, Un);
            E(opSUn, tcWord, dtDInt, suWrap);
            Exit(dtDInt);
          end;
      else
        begin
          E(opSUn, tcFloat, dtReal, Un);
          Exit(dtReal);
        end;
      end;
    end;
    case U of
      'MIN', 'MAX':
        begin
          Cnt := Args(['IN1', 'IN2', 'IN3', 'IN4'], Ts, 2);
          Result := Ts[0];
          for Q := 1 to Cnt - 1 do
          begin
            Result := SclArith(Result, Ts[Q]);
            if U = 'MIN' then E(opSBin, Cat(Result), Result, sbMin) else E(opSBin, Cat(Result), Result, sbMax);
          end;
        end;
      'LIMIT':
        begin
          Args(['MN', 'IN', 'MX'], Ts, 3);
          Result := SclArith(SclArith(Ts[0], Ts[1]), Ts[2]);
          E(opSTern, Cat(Result), Result, stLimit);
        end;
      'SEL':
        begin
          Args(['G', 'IN0', 'IN1'], Ts, 3);
          if Ts[0] <> dtBool then Fail('SEL: G must be BOOL');
          if (Ts[1] = dtBool) and (Ts[2] = dtBool) then Result := dtBool else Result := SclArith(Ts[1], Ts[2]);
          E(opSTern, tcWord, Result, stSel);
        end;
      'NORM_X':
        begin
          Args(['MIN', 'VALUE', 'MAX'], Ts, 3);
          E(opSTern, tcFloat, dtReal, stNormX);
          Result := dtReal;
        end;
      'SCALE_X':
        begin
          Args(['MIN', 'VALUE', 'MAX'], Ts, 3);
          Result := SclArith(Ts[0], Ts[2]);
          E(opSTern, tcFloat, Result, stScaleX);
        end;
      'SHL', 'SHR', 'ROL', 'ROR':
        begin
          Args(['IN', 'N'], Ts, 2);
          Result := Ts[0];
          if Result = dtBool then Fail(U + ': bit string expected');
          case U of
            'SHL': E(opSBin, tcWord, Result, sbShl);
            'SHR': E(opSBin, tcWord, Result, sbShr);
            'ROL': E(opSBin, tcWord, Result, sbRol);
          else
            E(opSBin, tcWord, Result, sbRor);
          end;
        end;
    else
      Fail('unknown function ' + Name);
    end;
  end;

  { ---------- expressions ---------- }

  { ---------- parameters of FB / FC calls ---------- }

  function IsBlockType(const V: TVarInfo): Boolean;
  begin
    Result := V.IsArray or (V.T in [dtStruct, dtIECTimer, dtIECCounter]);
  end;

  { parameter := actual (ToMember) or actual := parameter. V is the parameter (an FB instance member,
    or an FC parameter in the callee's local data); IIdx: its instance offset waits in register 9;
    ACh computes the actual's index offsets }
  procedure ParamCopy(const V: TVarInfo; const Nm: string; IIdx: Boolean; const A: TRef; const ACh: TOpChunk;
    ToMember: Boolean; Line: Integer);
  var
    MO: TOperand;
    I: Integer;
  begin
    FillChar(MO, SizeOf(MO), 0);
    MO.Kind := okAddr;
    MO.A := V.A;
    MO.DType := V.T;
    MO.Block := -1;
    MO.Text := '#' + Nm;
    if IsBlockType(V) then
    begin
      // a whole struct / array parameter
      if not A.IsBlock or not SameText(BlockTypeName(V), BlockTypeName(A.Info)) then
        Fail(Format('type mismatch: parameter %s is %s', [Nm, BlockTypeName(V)]));
      if ToMember then
      begin
        if IIdx then E(opSGetReg, tcWord, dtDInt, 9);
        PutChunk(ACh);
        I := E(opSCopy, tcWord, dtNone, BlockBytes(V));
        FBlock.Ops[I].Opd := MO;
        FBlock.Ops[I].Ext := AddParam(A.Opd);
        FBlock.Ops[I].Lo := Ord(IIdx) or 2 * Ord(A.Indexed);
      end
      else
      begin
        PutChunk(ACh);
        if IIdx then E(opSGetReg, tcWord, dtDInt, 9);
        I := E(opSCopy, tcWord, dtNone, BlockBytes(V));
        FBlock.Ops[I].Opd := A.Opd;
        FBlock.Ops[I].Ext := AddParam(MO);
        FBlock.Ops[I].Lo := Ord(A.Indexed) or 2 * Ord(IIdx);
      end;
      FBlock.Ops[I].Weight := Min(255, 2 + BlockBytes(V) div 4);
      Exit;
    end;
    if A.IsBlock then Fail(Format('type mismatch: parameter %s is %s', [Nm, DataTypeNames[V.T]]));
    if ToMember then
    begin
      if IIdx then E(opSGetReg, tcWord, dtDInt, 9);
      PutChunk(ACh);
      PushRef(A);
      CheckAssign(V.T, A.T, Nm);
      if IIdx then I := E(opSStoreIdx, tcWord, V.T) else I := E(opSStore, tcWord, V.T);
      FBlock.Ops[I].Opd := MO;
    end
    else
    begin
      PutChunk(ACh);
      if IIdx then
      begin
        E(opSGetReg, tcWord, dtDInt, 9);
        I := E(opSPushIdx, tcWord, V.T);
      end
      else
        I := E(opSPush, tcWord, V.T);
      FBlock.Ops[I].Opd := MO;
      CheckAssign(A.T, V.T, A.Text);
      StoreRef(A, Line);
    end;
  end;

  { Input := expression (a variable for a struct / array input) }
  procedure ParamInput(const V: TVarInfo; const Nm: string; IIdx: Boolean; Line: Integer);
  var
    MO: TOperand;
    T: TDataType;
    I, P1: Integer;
    Act: TRef;
  begin
    if IsBlockType(V) then
    begin
      if not (Tok.Kind in [stHash, stQuoted, stIdent]) then
        Fail(Format('parameter %s is %s: a variable of the same type expected', [Nm, BlockTypeName(V)]));
      P1 := Length(FBlock.Ops);
      Act := PathEx(True);
      ParamCopy(V, Nm, IIdx, Act, TakeChunk(P1), True, Line);
      Exit;
    end;
    FillChar(MO, SizeOf(MO), 0);
    MO.Kind := okAddr;
    MO.A := V.A;
    MO.DType := V.T;
    MO.Block := -1;
    MO.Text := '#' + Nm;
    if IIdx then E(opSGetReg, tcWord, dtDInt, 9);
    T := Expr;
    CheckAssign(V.T, T, Nm);
    if IIdx then I := E(opSStoreIdx, tcWord, V.T) else I := E(opSStore, tcWord, V.T);
    FBlock.Ops[I].Opd := MO;
  end;

  { an FC by name: "Name" or FCn }
  function FCByName(const S: string): TBlock;
  var
    I, N: Integer;
  begin
    Result := nil;
    if SameText(Copy(S, 1, 2), 'FC') and TryStrToInt(Copy(S, 3, MaxInt), N) then Exit(FProject.FindBlock(bkFC, N));
    for I := 0 to FProject.BlockCount - 1 do
      if (FProject.Block(I).Kind = bkFC) and SameText(FProject.Block(I).Name, S) then Exit(FProject.Block(I));
  end;

  { an FC call (Tok is its name): "Name"(In := x, Out => y, Io := z). The parameters go into the local
    data of the FC (the next frame of the block stack): Inputs are written before the call, Outputs and
    InOuts are copied in before and back after it (an Output the FC does not write keeps its value).
    Every parameter must be given. AsExpr: the Return value is pushed. }
  function FCCall(Fc: TBlock; AsExpr: Boolean; Line: Integer): TDataType;
  var
    U: TDataBlock;
    BI, K, P0, P1, NPost, I: Integer;
    Nm: string;
    M: TDbVar;
    Act: TRef;
    Ch: TOpChunk;
    Posts: array of TOpChunk;
    Given: array of Boolean;
    V: TVarInfo;

    function ParamInfo(const Mv: TDbVar): TVarInfo;
    begin
      FillChar(Result, SizeOf(Result), 0);
      // DB = -1: the local data of the called block
      Result.A := MakeAddr(arL, TypeOpSize(Mv.DType), Mv.Ofs, Mv.Bit, -1);
      Result.T := Mv.DType;
      Result.Udt := Mv.Udt;
      Result.IsArray := Mv.IsArray;
      Result.Lo := Mv.Lo;
      Result.Hi := Mv.Hi;
    end;

  begin
    Result := dtNone;
    BI := FProg.FindBlock(bkFC, Fc.Number);
    if BI < 0 then Fail(Format('FC%d does not exist', [Fc.Number]));
    U := Fc.Iface;
    U.Name := Fc.Name;
    U.Layout;
    Next;
    Expect('(');
    SetLength(Given, Length(U.Vars));
    SetLength(Posts, 0);
    NPost := 0;
    while not IsSym(')') do
    begin
      if Tok.Kind <> stIdent then Fail('parameter name expected (In := .., Out => ..)');
      Nm := Tok.S;
      Next;
      K := U.FindVar(Nm);
      if (K < 0) or not (U.Vars[K].Section in [vsInput, vsOutput, vsInOut]) then
        Fail(Format('FC%d "%s" has no parameter %s', [Fc.Number, Fc.Name, Nm]));
      M := U.Vars[K];
      if not M.Valid then Fail(Format('FC%d.%s: unknown data type %s', [Fc.Number, Nm, M.TypeText]));
      if Given[K] then Fail(Nm + ' is given twice');
      Given[K] := True;
      V := ParamInfo(M);
      if IsSym(':=') then
      begin
        Next;
        if M.Section = vsOutput then Fail(Format('%s is an output: %s => target', [Nm, Nm]));
        if M.Section = vsInput then
          ParamInput(V, M.Name, False, Line)
        else
        begin
          // InOut: a variable, copied in now and back after the call
          if not (Tok.Kind in [stHash, stQuoted, stIdent, stPercent]) then Fail(Nm + ' is an InOut: a variable expected');
          P0 := Length(FBlock.Ops);
          Act := PathEx(True);
          if Act.Method <> '' then Fail('a timer call gives no value');
          Ch := TakeChunk(P0);
          if not IsBlockType(V) and not Act.IsBlock and (Act.T <> V.T) then
            Fail(Format('InOut %s is %s: the variable must have the same type (%s)', [Nm, DataTypeNames[V.T], DataTypeNames[Act.T]]));
          ParamCopy(V, M.Name, False, Act, Ch, True, Line);
          P1 := Length(FBlock.Ops);
          ParamCopy(V, M.Name, False, Act, Ch, False, Line);
          SetLength(Posts, NPost + 1);
          Posts[NPost] := TakeChunk(P1);
          Inc(NPost);
        end;
      end
      else if IsSym('=>') then
      begin
        Next;
        if M.Section <> vsOutput then Fail(Format('%s is an %s: %s := ..', [Nm, SectionNames[M.Section], Nm]));
        P0 := Length(FBlock.Ops);
        Act := PathEx(True);
        if Act.Method <> '' then Fail('a timer call is no target');
        Ch := TakeChunk(P0);
        // in first: an output the FC does not write keeps the target's value (like a pointer)
        ParamCopy(V, M.Name, False, Act, Ch, True, Line);
        P1 := Length(FBlock.Ops);
        ParamCopy(V, M.Name, False, Act, Ch, False, Line);
        SetLength(Posts, NPost + 1);
        Posts[NPost] := TakeChunk(P1);
        Inc(NPost);
      end
      else
        Fail(':= or => expected after ' + Nm);
      if IsSym(',') then Next else Break;
    end;
    Expect(')');
    for K := 0 to High(U.Vars) do
      if (U.Vars[K].Section in [vsInput, vsOutput, vsInOut]) and not Given[K] then
        Fail(Format('FC%d "%s": parameter %s missing (an FC needs every parameter)', [Fc.Number, Fc.Name, U.Vars[K].Name]));
    K := Emit(opCALL, tcWord, 4);
    FBlock.Ops[K].Ext := BI;
    for K := 0 to NPost - 1 do PutChunk(Posts[K]);
    if not AsExpr then Exit;
    for K := 0 to High(U.Vars) do
      if U.Vars[K].Section = vsReturn then
      begin
        V := ParamInfo(U.Vars[K]);
        I := E(opSPush, tcWord, V.T);
        FBlock.Ops[I].Opd.Kind := okAddr;
        FBlock.Ops[I].Opd.A := V.A;
        FBlock.Ops[I].Opd.DType := V.T;
        FBlock.Ops[I].Opd.Text := '#Ret_Val';
        Exit(V.T);
      end;
    Fail(Format('FC%d "%s" has no Return value: call it as a statement', [Fc.Number, Fc.Name]));
  end;

  function Primary: TDataType;
  var
    T: TSclToken;
    C: TConst;
    V: Double;
    R: TRef;
    U: string;
  begin
    T := Tok;
    if IsSym('(') then
    begin
      Next;
      Result := Expr;
      Expect(')');
      Exit;
    end;
    // an FC with a Return value: "Name"(..), FC2(..)
    if (T.Kind in [stIdent, stQuoted]) and (PeekTok(1).Kind = stSym) and (PeekTok(1).S = '(') and
      (FCByName(T.S) <> nil) then
      Exit(FCCall(FCByName(T.S), True, T.Line));
    case T.Kind of
      stNum:
        begin
          Next;
          if (Pos('.', T.S) > 0) or (Pos('E', UpperCase(T.S)) > 0) then
          begin
            if not StrToFloatDot(T.S, V) then Fail('bad number ' + T.S);
            EK(V, dtReal);
            Exit(dtReal);
          end;
          // integer literals are untyped: they calculate in 32 bit, the target type wraps
          V := StrToInt64Def(T.S, 0);
          if Abs(V) > 2147483647 then Fail('number out of range ' + T.S);
          Result := dtDInt;
          EK(V, Result);
          Exit;
        end;
      stTyped:
        begin
          Next;
          if not ParseConst(T.S, C) then Fail('bad constant ' + T.S);
          case C.Kind of
            ckTime: begin EK(C.I, dtTime); Exit(dtTime); end;
            ckS5Time: begin EK(C.Bits, dtS5Time); Exit(dtS5Time); end;
            ckDInt: begin EK(C.I, dtDInt); Exit(dtDInt); end;
            ckCounter: begin EK(C.Bits, dtWord); Exit(dtWord); end;
            ckHex:
              begin
                case C.Size of
                  osByte: Result := dtByte;
                  osWord: Result := dtWord;
                else
                  Result := dtDWord;
                end;
                EK(C.I, Result);
                Exit;
              end;
          else
            Fail('constant not supported in SCL: ' + T.S);
          end;
        end;
      stStr:
        begin
          Next;
          if Length(T.S) <> 1 then Fail('only CHAR constants (one letter) are supported');
          EK(Ord(T.S[1]), dtChar);
          Exit(dtChar);
        end;
      stIdent:
        begin
          U := UpperCase(T.S);
          if U = 'TRUE' then begin Next; EK(1, dtBool); Exit(dtBool); end;
          if U = 'FALSE' then begin Next; EK(0, dtBool); Exit(dtBool); end;
          if IsKeyword(U) then Fail('"' + T.S + '" is not allowed here');
          if (PeekTok(1).Kind = stSym) and (PeekTok(1).S = '(') then
          begin
            Next;
            Exit(Call(T.S));
          end;
        end;
    end;
    R := Path;
    if R.Method <> '' then Fail(R.Method + ' is a statement (call it on its own line)');
    PushRef(R);
    Result := R.T;
  end;

  function PowExpr: TDataType;
  var
    B: TDataType;
  begin
    Result := Primary;
    while IsSym('**') do
    begin
      Next;
      B := Primary;
      if not SclIsNum(Result) or not SclIsNum(B) then Fail('** needs numbers');
      E(opSBin, tcFloat, dtReal, sbPow);
      Result := dtReal;
    end;
  end;

  function UnExpr: TDataType;
  begin
    if IsSym('-') then
    begin
      Next;
      Result := UnExpr();
      if not SclIsNum(Result) then Fail('- needs a number');
      E(opSUn, Cat(Result), Result, suNeg);
    end
    else if IsSym('+') then
    begin
      Next;
      Result := UnExpr();
    end
    else if IsKw('NOT') then
    begin
      Next;
      Result := UnExpr();
      if Result = dtBool then E(opSUn, tcBit, dtBool, suNot)
      else if SclIsBits(Result) or (Result in [dtInt, dtDInt, dtSInt, dtUSInt, dtUInt, dtUDInt]) then
        E(opSUn, tcWord, Result, suNotBits)
      else
        Fail('NOT needs BOOL or a bit string');
    end
    else
      Result := PowExpr;
  end;

  function MulExpr: TDataType;
  var
    B, R: TDataType;
    Op: Integer;
  begin
    Result := UnExpr;
    while IsSym('*') or IsSym('/') or IsKw('MOD') do
    begin
      if IsSym('*') then Op := sbMul else if IsSym('/') then Op := sbDiv else Op := sbMod;
      Next;
      B := UnExpr;
      if not SclIsNum(Result) or not SclIsNum(B) then Fail('* / MOD need numbers');
      R := SclArith(Result, B);
      if (Op = sbMod) and (R = dtReal) then Fail('MOD needs integers');
      // TIME * INT stays TIME
      E(opSBin, Cat(R), R, Op);
      Result := R;
    end;
  end;

  function AddExpr: TDataType;
  var
    B, R: TDataType;
    Op: Integer;
  begin
    Result := MulExpr;
    while IsSym('+') or IsSym('-') do
    begin
      if IsSym('+') then Op := sbAdd else Op := sbSub;
      Next;
      B := MulExpr;
      if not SclIsNum(Result) or not SclIsNum(B) then Fail('+ - need numbers');
      R := SclArith(Result, B);
      E(opSBin, Cat(R), R, Op);
      Result := R;
    end;
  end;

  function Compare(Lower: Boolean): TDataType;
  var
    B, R: TDataType;
    Op: Integer;
  begin
    if Lower then Result := AddExpr else Result := Compare(True);
    while (Lower and (IsSym('<') or IsSym('>') or IsSym('<=') or IsSym('>='))) or
      (not Lower and (IsSym('=') or IsSym('<>'))) do
    begin
      case Tok.S of
        '<': Op := sbLt;
        '>': Op := sbGt;
        '<=': Op := sbLe;
        '>=': Op := sbGe;
        '=': Op := sbEq;
      else
        Op := sbNe;
      end;
      Next;
      if Lower then B := AddExpr else B := Compare(True);
      if (Result = dtBool) <> (B = dtBool) then Fail('cannot compare BOOL with a number');
      if (Result = dtBool) and Lower then Fail('< > need numbers');
      R := SclArith(Result, B);
      if Result = dtBool then R := dtBool;
      E(opSBin, Cat(R), R, Op);
      Result := dtBool;
    end;
  end;

  function Logic(Level: Integer): TDataType;
  var
    B: TDataType;
    IsOp: Boolean;
  begin
    // 0 OR, 1 XOR, 2 AND
    if Level = 2 then Result := Compare(False) else Result := Logic(Level + 1);
    repeat
      case Level of
        0: IsOp := IsKw('OR');
        1: IsOp := IsKw('XOR');
      else
        IsOp := IsKw('AND') or IsSym('&');
      end;
      if not IsOp then Break;
      Next;
      if Level = 2 then B := Compare(False) else B := Logic(Level + 1);
      if (Result = dtBool) and (B = dtBool) then
        E(opSBin, tcBit, dtBool, sbOr + Ord(Level = 1) - Ord(Level = 2))
      else if (Result <> dtBool) and (B <> dtBool) and not (dtReal in [Result, B]) then
      begin
        Result := SclArith(Result, B);
        case Level of
          0: E(opSBin, tcWord, Result, sbBOr);
          1: E(opSBin, tcWord, Result, sbBXor);
        else
          E(opSBin, tcWord, Result, sbBAnd);
        end;
      end
      else
        Fail('AND / OR / XOR: both BOOL or both bit strings');
    until False;
  end;

  function Expr: TDataType;
  begin
    Result := Logic(0);
  end;

  function Cond: Integer;
  var
    T: TDataType;
    Ln0: Integer;
  begin
    Ln0 := Tok.Line;
    T := Expr;
    if T <> dtBool then Fail('a condition must be BOOL (not ' + DataTypeNames[T] + ')');
    Result := E(opSJz, tcWord, dtBool);
    SetMon(Result, Ln0);
  end;

  procedure Patch(OpIx, Target: Integer);
  begin
    FBlock.Ops[OpIx].Ext := Target;
  end;

  function Jmp: Integer;
  begin
    Result := E(opSJmp, tcWord, dtNone);
  end;

  { ---------- statements ---------- }

  procedure Statements(const Stops: array of string); forward;

  function AtStop(const Stops: array of string): Boolean;
  var
    K: Integer;
  begin
    if Tok.Kind = stEOF then Exit(True);
    for K := 0 to High(Stops) do
      if IsKw(Stops[K]) then Exit(True);
    Result := False;
  end;

  procedure EndStmt;
  begin
    if IsSym(';') then Next
    else if not AtStop(['END_IF', 'ELSE', 'ELSIF', 'END_CASE', 'END_FOR', 'END_WHILE', 'UNTIL', 'END_REPEAT']) then
      Fail(Format('";" expected, found "%s"', [Tok.S]));
  end;

  procedure TimerCall(const R: TRef; Line: Integer);
  var
    IsTimer: Boolean;
    InNames, OutNames: array of string;
    Chunks: array of TOpChunk;
    OutC: array of TOpChunk;
    OutRef: array of TRef;
    OutMem: array of string;
    Given: array of Boolean;
    K, Ix, Pos0, NOut, OpIx: Integer;
    Nm, Er: string;
    T: TDataType;
    Tg: TRef;
    MemOpd: TOperand;
    Code: TOpCode;
  begin
    IsTimer := R.Method[1] = 'T';
    if IsTimer and (R.Opd.DType <> dtIECTimer) then Fail(R.Text + ' must be an IEC_TIMER for .' + R.Method);
    if not IsTimer and (R.Opd.DType <> dtIECCounter) then Fail(R.Text + ' must be an IEC_COUNTER for .' + R.Method);
    if IsTimer then
    begin
      InNames := ['IN', 'PT', 'R'];
      OutNames := ['Q', 'ET'];
    end
    else
    begin
      InNames := ['CU', 'CD', 'R', 'LD', 'PV'];
      OutNames := ['Q', 'QU', 'QD', 'CV'];
    end;
    // an instance in an array ("DB".M[#i].T): its offset waits in register 8 during the call
    if R.Indexed then E(opSSetReg, tcWord, dtDInt, 8);
    SetLength(Chunks, Length(InNames));
    SetLength(Given, Length(InNames));
    NOut := 0;
    Expect('(');
    while not IsSym(')') do
    begin
      if Tok.Kind <> stIdent then Fail('parameter name expected (IN := ..)');
      Nm := UpperCase(Tok.S);
      Next;
      if IsSym(':=') then
      begin
        Next;
        Ix := -1;
        for K := 0 to High(InNames) do
          if InNames[K] = Nm then Ix := K;
        if Ix < 0 then Fail(Format('%s has no input %s', [R.Method, Nm]));
        Pos0 := Length(FBlock.Ops);
        T := Expr;
        if (Nm = 'PT') and not (T in [dtTime, dtDInt]) then Fail('PT must be a TIME (T#5S)');
        if (Nm = 'PV') and not (T in [dtInt, dtDInt, dtSInt, dtUSInt, dtUInt]) then Fail('PV must be an integer');
        if (Nm <> 'PT') and (Nm <> 'PV') and (T <> dtBool) then Fail(Nm + ' must be BOOL');
        Chunks[Ix] := TakeChunk(Pos0);
        Given[Ix] := True;
      end
      else if IsSym('=>') then
      begin
        Next;
        Ix := -1;
        for K := 0 to High(OutNames) do
          if OutNames[K] = Nm then Ix := K;
        if Ix < 0 then Fail(Format('%s has no output %s', [R.Method, Nm]));
        Pos0 := Length(FBlock.Ops);
        Tg := Path;
        SetLength(OutC, NOut + 1);
        SetLength(OutRef, NOut + 1);
        SetLength(OutMem, NOut + 1);
        OutC[NOut] := TakeChunk(Pos0);
        OutRef[NOut] := Tg;
        if Nm = 'Q' then
        begin
          if IsTimer then OutMem[NOut] := 'Q' else if R.Method = 'CTD' then OutMem[NOut] := 'QD' else OutMem[NOut] := 'QU';
        end
        else
          OutMem[NOut] := Nm;
        Inc(NOut);
      end
      else
        Fail(':= or => expected after ' + Nm);
      if IsSym(',') then Next else Break;
    end;
    Expect(')');
    // the inputs in their fixed order, defaults for the missing ones
    for K := 0 to High(InNames) do
      if Given[K] then PutChunk(Chunks[K])
      else
      begin
        if (InNames[K] = 'IN') or (InNames[K] = 'PT') or ((InNames[K] = 'PV') and False) then
          Fail(InNames[K] + ' missing');
        EK(0, dtBool);
      end;
    if IsTimer then
      case R.Method of
        'TON': Code := opTON;
        'TOF': Code := opTOF;
        'TP': Code := opTP;
      else
        Code := opTONR;
      end
    else
      case R.Method of
        'CTU': Code := opCTU;
        'CTD': Code := opCTD;
      else
        Code := opCTUD;
      end;
    if IsTimer then OpIx := E(opSTimer, tcFix, dtNone, Ord(Code)) else OpIx := E(opSCounter, tcFix, dtNone, Ord(Code));
    FBlock.Ops[OpIx].Opd := R.Opd;
    FBlock.Ops[OpIx].Ext := Ord(R.Indexed);
    FBlock.Ops[OpIx].Weight := 12;
    SetMon(OpIx, Line);
    // outputs: target := instance member
    for K := 0 to NOut - 1 do
    begin
      PutChunk(OutC[K]);
      if not FRes.Resolve(R.Text + '.' + OutMem[K], MemOpd, Er, False) then Fail(Er);
      if R.Indexed then
      begin
        E(opSGetReg, tcWord, dtDInt, 8);
        Ix := E(opSPushIdx, tcWord, MemOpd.DType);
      end
      else
        Ix := E(opSPush, tcWord, MemOpd.DType);
      FBlock.Ops[Ix].Opd := MemOpd;
      CheckAssign(OutRef[K].T, MemOpd.DType, OutRef[K].Text);
      StoreRef(OutRef[K], Line);
    end;
  end;

  { an FB call: "Inst_DB"(In := x, Out => y, Io := z), #inst(..), #M[#i](..).
    Inputs and InOuts are written into the instance before the call, Outputs and InOuts read after it;
    a parameter left out keeps its value in the instance. A variable index of the instance waits in
    register 9 (the call saves the registers). }
  procedure FBCall(const R: TRef; Line: Integer);
  var
    U: TDataBlock;
    BI, K, P0, P1, NPost: Integer;
    Nm: string;
    M: TDbVar;
    Act: TRef;
    Ch: TOpChunk;
    Posts: array of TOpChunk;
    V: TVarInfo;
    Er: string;
  begin
    U := R.Info.Udt;
    BI := FProg.FindBlock(bkFB, U.Number);
    if BI < 0 then Fail(Format('FB%d does not exist', [U.Number]));
    U.Layout;
    if R.Indexed then E(opSSetReg, tcWord, dtDInt, 9);
    SetLength(Posts, 0);
    NPost := 0;
    Expect('(');
    while not IsSym(')') do
    begin
      if Tok.Kind <> stIdent then Fail('parameter name expected (In := .., Out => ..)');
      Nm := Tok.S;
      Next;
      K := U.FindVar(Nm);
      if (K < 0) or (U.Vars[K].Section = vsTemp) then Fail(Format('FB%d "%s" has no parameter %s', [U.Number, U.Name, Nm]));
      M := U.Vars[K];
      if M.Section = vsStatic then Fail(Format('%s is a Static of FB%d: no parameter', [Nm, U.Number]));
      if IsSym(':=') then
      begin
        Next;
        case M.Section of
          vsOutput: Fail(Format('%s is an output: %s => target', [Nm, Nm]));
          vsInput:
            begin
              if not FRes.ResolveVar(R.Text + '.' + M.Name, V, Er) then Fail(Er);
              ParamInput(V, M.Name, R.Indexed, Line);
            end;
        else
          begin
            // InOut: a variable, copied in now and back after the call
            if not (Tok.Kind in [stHash, stQuoted, stIdent, stPercent]) then Fail(Nm + ' is an InOut: a variable expected');
            P0 := Length(FBlock.Ops);
            Act := PathEx(True);
            if Act.Method <> '' then Fail('a timer call gives no value');
            Ch := TakeChunk(P0);
            if not FRes.ResolveVar(R.Text + '.' + M.Name, V, Er) then Fail(Er);
            if not IsBlockType(V) and not Act.IsBlock and (Act.T <> V.T) then
              Fail(Format('InOut %s is %s: the variable must have the same type (%s)', [Nm, DataTypeNames[V.T], DataTypeNames[Act.T]]));
            ParamCopy(V, M.Name, R.Indexed, Act, Ch, True, Line);
            P1 := Length(FBlock.Ops);
            ParamCopy(V, M.Name, R.Indexed, Act, Ch, False, Line);
            SetLength(Posts, NPost + 1);
            Posts[NPost] := TakeChunk(P1);
            Inc(NPost);
          end;
        end;
      end
      else if IsSym('=>') then
      begin
        Next;
        if M.Section <> vsOutput then Fail(Format('%s is an %s: %s := ..', [Nm, SectionNames[M.Section], Nm]));
        P0 := Length(FBlock.Ops);
        Act := PathEx(True);
        if Act.Method <> '' then Fail('a timer call is no target');
        Ch := TakeChunk(P0);
        P1 := Length(FBlock.Ops);
        if not FRes.ResolveVar(R.Text + '.' + M.Name, V, Er) then Fail(Er);
        ParamCopy(V, M.Name, R.Indexed, Act, Ch, False, Line);
        SetLength(Posts, NPost + 1);
        Posts[NPost] := TakeChunk(P1);
        Inc(NPost);
      end
      else
        Fail(':= or => expected after ' + Nm);
      if IsSym(',') then Next else Break;
    end;
    Expect(')');
    if R.Indexed then E(opSGetReg, tcWord, dtDInt, 9);
    K := Emit(opCALLFB, tcWord, 6);
    FBlock.Ops[K].Ext := BI;
    FBlock.Ops[K].Opd := R.Opd;
    FBlock.Ops[K].Lo := Ord(R.Indexed);
    for K := 0 to NPost - 1 do PutChunk(Posts[K]);
  end;

  procedure Statement;
  var
    Line, J1, J2, Top, Cont, K, Lo, Hi, Reg, LabelLine: Integer;
    Ends: array of Integer;
    R, CtrlR: TRef;
    T: TDataType;
    BlkIx: Integer;
    Db: TDataBlock;
    ByV: Double;
    Neg: Boolean;
    First: Boolean;
    U: string;

    function CaseValue: Integer;
    var
      Ng: Boolean;
    begin
      Ng := False;
      if IsSym('-') then
      begin
        Ng := True;
        Next;
      end;
      if Tok.Kind <> stNum then Fail('CASE label: integer constant expected');
      Result := StrToIntDef(Tok.S, 0);
      if Ng then Result := -Result;
      Next;
    end;

    function IsLabelStart: Boolean;
    begin
      Result := (Tok.Kind = stNum) or (IsSym('-') and (PeekTok(1).Kind = stNum));
    end;

  begin
    Line := Tok.Line;
    FLine := Line;
    if IsSym(';') then
    begin
      Next;
      Exit;
    end;
    if IsKw('REGION') then
    begin
      // REGION <name>: the rest of the line is the name
      while (Tok.Kind <> stEOF) and (Tok.Line = Line) do Next;
      Exit;
    end;
    if IsKw('END_REGION') then
    begin
      Next;
      if IsSym(';') then Next;
      Exit;
    end;
    if IsKw('IF') then
    begin
      Next;
      SetLength(Ends, 0);
      J1 := Cond;
      Expect('THEN');
      Statements(['ELSIF', 'ELSE', 'END_IF']);
      while IsKw('ELSIF') do
      begin
        SetLength(Ends, Length(Ends) + 1);
        Ends[High(Ends)] := Jmp;
        Patch(J1, Length(FBlock.Ops));
        FLine := Tok.Line;
        Next;
        J1 := Cond;
        Expect('THEN');
        Statements(['ELSIF', 'ELSE', 'END_IF']);
      end;
      if IsKw('ELSE') then
      begin
        SetLength(Ends, Length(Ends) + 1);
        Ends[High(Ends)] := Jmp;
        Patch(J1, Length(FBlock.Ops));
        Next;
        Statements(['END_IF']);
        J1 := -1;
      end;
      Expect('END_IF');
      if J1 >= 0 then Patch(J1, Length(FBlock.Ops));
      for K := 0 to High(Ends) do Patch(Ends[K], Length(FBlock.Ops));
      EndStmt;
      Exit;
    end;
    if IsKw('CASE') then
    begin
      Next;
      if CaseDepth >= 8 then Fail('CASE nested too deep');
      Reg := CaseDepth;
      Inc(CaseDepth);
      T := Expr;
      if not (T in [dtInt, dtDInt, dtSInt, dtUSInt, dtUInt, dtUDInt, dtByte, dtWord, dtDWord, dtChar]) then
        Fail('CASE needs an integer');
      K := E(opSSetReg, tcWord, T, Reg);
      SetMon(K, Line);     // the selector value on the CASE line
      Expect('OF');
      SetLength(Ends, 0);
      while IsLabelStart do
      begin
        First := True;
        LabelLine := Tok.Line;
        repeat
          Lo := CaseValue;
          E(opSGetReg, tcWord, T, Reg);
          if IsSym('..') then
          begin
            Next;
            Hi := CaseValue;
            EK(Lo, dtDInt);
            E(opSBin, tcFix, dtDInt, sbGe);
            E(opSGetReg, tcWord, T, Reg);
            EK(Hi, dtDInt);
            E(opSBin, tcFix, dtDInt, sbLe);
            E(opSBin, tcBit, dtBool, sbAnd);
          end
          else
          begin
            EK(Lo, dtDInt);
            E(opSBin, tcFix, dtDInt, sbEq);
          end;
          if not First then E(opSBin, tcBit, dtBool, sbOr);
          First := False;
          if IsSym(',') then Next else Break;
        until False;
        Expect(':');
        J1 := E(opSJz, tcWord, dtBool);
        SetMon(J1, LabelLine);
        Statements(['ELSE', 'END_CASE']);
        SetLength(Ends, Length(Ends) + 1);
        Ends[High(Ends)] := Jmp;
        Patch(J1, Length(FBlock.Ops));
        // the next label stops the statements of this branch (Statements stops at a number)
      end;
      if IsKw('ELSE') then
      begin
        Next;
        Statements(['END_CASE']);
      end;
      Expect('END_CASE');
      for K := 0 to High(Ends) do Patch(Ends[K], Length(FBlock.Ops));
      Dec(CaseDepth);
      EndStmt;
      Exit;
    end;
    if IsKw('FOR') then
    begin
      Next;
      CtrlR := Path;
      if CtrlR.Indexed or not (CtrlR.T in [dtInt, dtDInt, dtSInt, dtUSInt, dtUInt, dtUDInt]) then
        Fail('FOR needs an integer control variable');
      Expect(':=');
      T := Expr;
      CheckAssign(CtrlR.T, T, CtrlR.Text);
      StoreRef(CtrlR, Line);
      Expect('TO');
      Top := Length(FBlock.Ops);
      PushRef(CtrlR);
      // the end value is evaluated on every pass (like the CPU)
      J2 := Length(FBlock.Ops);
      T := Expr;
      ByV := 1;
      if IsKw('BY') then
      begin
        Next;
        Neg := False;
        if IsSym('-') then
        begin
          Neg := True;
          Next;
        end;
        if Tok.Kind <> stNum then Fail('BY: integer constant expected');
        ByV := StrToIntDef(Tok.S, 1);
        if Neg then ByV := -ByV;
        if ByV = 0 then Fail('BY 0 would never end');
        Next;
      end;
      if ByV > 0 then E(opSBin, tcFix, dtDInt, sbLe) else E(opSBin, tcFix, dtDInt, sbGe);
      J1 := E(opSJz, tcWord, dtBool);
      SetMon(J1, Line);
      Expect('DO');
      Inc(LoopDepth);
      SetLength(LoopExits, LoopDepth);
      SetLength(LoopConts, LoopDepth);
      SetLength(LoopExits[LoopDepth - 1], 0);
      SetLength(LoopConts[LoopDepth - 1], 0);
      Statements(['END_FOR']);
      Expect('END_FOR');
      Cont := Length(FBlock.Ops);
      PushRef(CtrlR);
      EK(ByV, dtDInt);
      E(opSBin, tcFix, CtrlR.T, sbAdd);
      StoreRef(CtrlR, -1);
      K := Jmp;
      Patch(K, Top);
      Patch(J1, Length(FBlock.Ops));
      for K := 0 to High(LoopExits[LoopDepth - 1]) do Patch(LoopExits[LoopDepth - 1][K], Length(FBlock.Ops));
      for K := 0 to High(LoopConts[LoopDepth - 1]) do Patch(LoopConts[LoopDepth - 1][K], Cont);
      Dec(LoopDepth);
      if J2 = 0 then ;
      EndStmt;
      Exit;
    end;
    if IsKw('WHILE') then
    begin
      Next;
      Top := Length(FBlock.Ops);
      J1 := Cond;
      Expect('DO');
      Inc(LoopDepth);
      SetLength(LoopExits, LoopDepth);
      SetLength(LoopConts, LoopDepth);
      SetLength(LoopExits[LoopDepth - 1], 0);
      SetLength(LoopConts[LoopDepth - 1], 0);
      Statements(['END_WHILE']);
      Expect('END_WHILE');
      K := Jmp;
      Patch(K, Top);
      Patch(J1, Length(FBlock.Ops));
      for K := 0 to High(LoopExits[LoopDepth - 1]) do Patch(LoopExits[LoopDepth - 1][K], Length(FBlock.Ops));
      for K := 0 to High(LoopConts[LoopDepth - 1]) do Patch(LoopConts[LoopDepth - 1][K], Top);
      Dec(LoopDepth);
      EndStmt;
      Exit;
    end;
    if IsKw('REPEAT') then
    begin
      Next;
      Top := Length(FBlock.Ops);
      Inc(LoopDepth);
      SetLength(LoopExits, LoopDepth);
      SetLength(LoopConts, LoopDepth);
      SetLength(LoopExits[LoopDepth - 1], 0);
      SetLength(LoopConts[LoopDepth - 1], 0);
      Statements(['UNTIL']);
      Expect('UNTIL');
      Cont := Length(FBlock.Ops);
      J1 := Cond;   // jump back while the condition is FALSE
      Patch(J1, Top);
      Expect('END_REPEAT');
      for K := 0 to High(LoopExits[LoopDepth - 1]) do Patch(LoopExits[LoopDepth - 1][K], Length(FBlock.Ops));
      for K := 0 to High(LoopConts[LoopDepth - 1]) do Patch(LoopConts[LoopDepth - 1][K], Cont);
      Dec(LoopDepth);
      EndStmt;
      Exit;
    end;
    if IsKw('EXIT') or IsKw('CONTINUE') then
    begin
      U := UpperCase(Tok.S);
      if LoopDepth = 0 then Fail(U + ' outside a loop');
      Next;
      K := Jmp;
      if U = 'EXIT' then
      begin
        SetLength(LoopExits[LoopDepth - 1], Length(LoopExits[LoopDepth - 1]) + 1);
        LoopExits[LoopDepth - 1][High(LoopExits[LoopDepth - 1])] := K;
      end
      else
      begin
        SetLength(LoopConts[LoopDepth - 1], Length(LoopConts[LoopDepth - 1]) + 1);
        LoopConts[LoopDepth - 1][High(LoopConts[LoopDepth - 1])] := K;
      end;
      EndStmt;
      Exit;
    end;
    if IsKw('RETURN') then
    begin
      Next;
      Emit(opBEU, tcWord);
      EndStmt;
      Exit;
    end;
    if (Tok.Kind = stIdent) and IsKeyword(Tok.S) then Fail('"' + Tok.S + '" is not allowed here');
    // an FB call with an instance DB: "Inst_DB"(In := ..)
    if (Tok.Kind in [stIdent, stQuoted]) and (PeekTok(1).Kind = stSym) and (PeekTok(1).S = '(') and
      (FProject.FindDBByName(Tok.S) <> nil) and (FProject.FindDBByName(Tok.S).InstanceOf > 0) then
    begin
      Db := FProject.FindDBByName(Tok.S);
      FillChar(R, SizeOf(R), 0);
      if FProject.InstanceFB(Db) = nil then Fail(Format('DB%d is the instance of FB%d, which does not exist', [Db.Number, Db.InstanceOf]));
      R.Text := '"' + Db.Name + '"';
      R.IsBlock := True;
      R.Info.T := dtStruct;
      R.Info.Udt := FProject.InstanceFB(Db).Iface;
      R.Info.Udt.Name := FProject.InstanceFB(Db).Name;
      R.Info.Udt.Number := FProject.InstanceFB(Db).Number;
      R.Opd.Kind := okAddr;
      R.Opd.Block := -1;
      R.Opd.A := MakeAddr(arDB, osByte, 0, 0, Db.Number);
      R.Opd.Text := R.Text;
      Next;
      FBCall(R, Line);
      EndStmt;
      Exit;
    end;
    // an FC call: FC1(); "Name"();
    if (Tok.Kind in [stIdent, stQuoted]) and (PeekTok(1).Kind = stSym) and (PeekTok(1).S = '(') then
    begin
      if FCByName(Tok.S) = nil then
      begin
        if not BlockRef(Tok.S, BlkIx) then Fail('');
        Fail('block ' + Tok.S + ' cannot be called here');
      end;
      FCCall(FCByName(Tok.S), False, Line);
      EndStmt;
      Exit;
    end;
    // assignment or timer / counter call
    R := PathEx(True);
    if R.Method <> '' then
    begin
      TimerCall(R, Line);
      EndStmt;
      Exit;
    end;
    // a multi-instance call: #inst(..), #M[#i](..)
    if IsSym('(') and R.IsBlock and (R.Info.T = dtStruct) and not R.Info.IsArray and R.Info.Udt.IsIface then
    begin
      FBCall(R, Line);
      EndStmt;
      Exit;
    end;
    if R.IsBlock then
    begin
      Expect(':=');
      BlockAssign(R, Line);
      EndStmt;
      Exit;
    end;
    if R.Opd.A.Area in [arI, arPI] then Msg('writing an input: the next input image overwrites it', False);
    Expect(':=');
    T := Expr;
    CheckAssign(R.T, T, R.Text);
    StoreRef(R, Line);
    EndStmt;
  end;

  { after an error: skip the statement; IF / CASE / FOR / WHILE / REPEAT up to their END_ }
  procedure SkipStatement(From: Integer);
  var
    Depth: Integer;
    U: string;

    function Opener(const W: string): Boolean;
    begin
      Result := (W = 'IF') or (W = 'CASE') or (W = 'FOR') or (W = 'WHILE') or (W = 'REPEAT');
    end;

    function Closer(const W: string): Boolean;
    begin
      Result := (W = 'END_IF') or (W = 'END_CASE') or (W = 'END_FOR') or (W = 'END_WHILE') or (W = 'END_REPEAT');
    end;

  begin
    U := '';
    if Toks[From].Kind = stIdent then U := UpperCase(Toks[From].S);
    if Opener(U) then
    begin
      P := From + 1;
      Depth := 1;
      while (Tok.Kind <> stEOF) and (Depth > 0) do
      begin
        if Tok.Kind = stIdent then
        begin
          if Opener(UpperCase(Tok.S)) then Inc(Depth)
          else if Closer(UpperCase(Tok.S)) then Dec(Depth);
        end;
        Next;
      end;
      if IsSym(';') then Next;
      Exit;
    end;
    while (Tok.Kind <> stEOF) and not IsSym(';') do Next;
    if IsSym(';') then Next;
  end;

  procedure Statements(const Stops: array of string);
  var
    P0: Integer;
  begin
    while not AtStop(Stops) do
    begin
      // in a CASE branch the next label ends the statements
      if (CaseDepth > 0) and ((Tok.Kind = stNum) or (IsSym('-') and (PeekTok(1).Kind = stNum))) then Exit;
      P0 := P;
      try
        Statement;
      except
        on Ex: ESclError do
        begin
          if Ex.Message <> '' then Msg(Ex.Message);
          Inc(ErrCount);
          SkipStatement(P0);
        end;
      end;
      if P = P0 then Next;   // no progress: avoid a dead loop
      if ErrCount > 20 then Exit;
    end;
  end;

  procedure TempDecl;
  var
    Nm, Ty: string;
    T: TDataType;
    Lo, Hi, Sz, Ofs: Integer;
    U: TDataBlock;
  begin
    // VAR_TEMP  name : Type;  ...  END_VAR
    Next;
    while not IsKw('END_VAR') and (Tok.Kind <> stEOF) do
    begin
      FLine := Tok.Line;
      try
        if Tok.Kind <> stIdent then Fail('VAR_TEMP: name expected');
        Nm := Tok.S;
        Next;
        Expect(':');
        Ty := '';
        while not IsSym(';') and (Tok.Kind <> stEOF) and not IsKw('END_VAR') do
        begin
          // Array[0..3] of "Type": tokens glued again, OF kept apart
          if (Tok.Kind = stIdent) and SameText(Tok.S, 'OF') then Ty := Ty + ' of '
          else if Tok.Kind = stQuoted then Ty := Ty + '"' + Tok.S + '"'
          else Ty := Ty + Tok.S;
          Next;
        end;
        if not FProject.ParseVarType(Ty, T, Lo, Hi, U) then Fail('unknown data type ' + Ty);
        if T in [dtIECTimer, dtIECCounter] then Fail('timers / counters need a DB (they keep their state)');
        if FTemps.IndexOfName(UpperCase(Nm)) >= 0 then Fail('#' + Nm + ' is declared twice');
        if U <> nil then U.Layout;
        if Hi >= Lo then
        begin
          // an array: on an even byte, Bool elements packed into bits
          if T = dtBool then Sz := (Hi - Lo + 1 + 7) div 8
          else Sz := (Hi - Lo + 1) * ElemStride(T, U);
          Sz := (Sz + 1) div 2 * 2;
        end
        else if T = dtStruct then
          Sz := U.Size
        else
          Sz := DataTypeSize(T);
        if Sz = 0 then
          Ofs := FTempOfs
        else
        begin
          // bytes after bits start on the next byte, words, arrays and structs on an even byte
          Ofs := (FTempOfs + 7) div 8 * 8;
          if (Sz >= 2) or (Hi >= Lo) then Ofs := (Ofs + 15) div 16 * 16;
        end;
        if (Ofs + Max(1, Sz * 8)) div 8 > 256 then Fail('VAR_TEMP: more than 256 bytes of local data');
        FTemps.AddObject(UpperCase(Nm) + '=' + Ty, TObject(PtrInt(Ofs)));
        if Sz = 0 then FTempOfs := Ofs + 1 else FTempOfs := Ofs + Sz * 8;
        if IsSym(';') then Next;
      except
        on Ex: ESclError do
        begin
          Msg(Ex.Message);
          while (Tok.Kind <> stEOF) and not IsSym(';') and not IsKw('END_VAR') do Next;
          if IsSym(';') then Next;
        end;
      end;
    end;
    FLine := Tok.Line;
    if IsKw('END_VAR') then Next else Msg('END_VAR missing');
    if IsSym(';') then Next;
  end;

begin
  Base := FBlock.Nets[FNet].MonBase;
  LoopDepth := 0;
  CaseDepth := 0;
  ErrCount := 0;
  SetLength(Toks, 0);
  Lex;
  P := 0;
  while IsKw('VAR_TEMP') or IsKw('VAR') do TempDecl;
  while Tok.Kind <> stEOF do
  begin
    Statements([]);
    if Tok.Kind <> stEOF then
    begin
      FLine := Tok.Line;
      Msg(Format('unexpected "%s"', [Tok.S]));
      Next;
    end;
    if ErrCount > 20 then Break;
  end;
  FLine := -1;
end;
