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
    FC calls: "Name"(); FC1(); "F"(In := .., Out => ..) or positional "F"(1, 2, "DB".o); #<FC name> := ..
    VAR CONSTANT name : Type := value; END_VAR (#name); typed literals INT#5 UDINT#16#FF 8#17 D#.. TOD#..
      DT#.. LT#.. LTOD#.. LDT#.. CHAR#'A' STRING#'..' WSTRING#'..'; MUX; slices .%X3 .%B1 .%W0 .%D0
    system FBs as statics / DB variables: #t(IN := .., PT := ..) of TON_TIME TOF_TIME TP_TIME TONR_TIME
      TON_LTIME, CTU_INT .. CTUD_ULINT, R_TRIG F_TRIG RS SR
    String[n] WString[n] Char WChar: LEN CONCAT LEFT RIGHT MID FIND, = <> < > (a string stack of its own)
    64 bit exact (an Int64 beside the Double of each stack value): LInt ULInt LWord LReal LTime LTOD LDT
      Date_And_Time, the time arithmetic of TIA, TIME_TO_LTIME DT_TO_LDT DT_TO_DATE DT_TO_TOD ..
    operands: "Tag", "DB".Var, "DB".Arr[expression], "DB".M[i, j], %MW20, MW20, DB1.DBW2, #temp
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
  { opStrOp }
  soConcat = 1; soLeft = 2; soRight = 3; soMid = 4; soLen = 5; soFind = 6; soCmp = 7; soChr = 8; soSwap = 9;
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
    dtWord, dtInt, dtUInt, dtS5Time, dtDate, dtWChar: Result := 2;
    dtDWord, dtDInt, dtUDInt, dtTime, dtTOD: Result := 3;
    dtReal: Result := 4;
    dtLWord, dtLInt, dtULInt, dtLTime, dtLTOD, dtLDT, dtDT: Result := 5;
    dtLReal: Result := 6;
  else
    Result := 3;
  end;
end;

function SclIsBits(T: TDataType): Boolean;
begin
  Result := T in [dtByte, dtWord, dtDWord, dtLWord];
end;

function SclIsNum(T: TDataType): Boolean;
begin
  Result := T in [dtByte, dtWord, dtDWord, dtChar, dtSInt, dtUSInt, dtInt, dtUInt, dtDInt, dtUDInt, dtReal,
    dtTime, dtS5Time, dtDate, dtTOD, dtWChar, dtLWord, dtLInt, dtULInt, dtLReal, dtLTime, dtLTOD, dtLDT, dtDT];
end;

{ a time / date type: its arithmetic has rules of its own }
function SclIsTimeT(T: TDataType): Boolean;
begin
  Result := T in [dtTime, dtLTime, dtTOD, dtLTOD, dtDT, dtLDT, dtDate, dtS5Time];
end;

{ the integers (for an untyped number beside a time: TIME + 5) }
function SclIsInt(T: TDataType): Boolean;
begin
  Result := T in [dtSInt, dtUSInt, dtInt, dtUInt, dtDInt, dtUDInt, dtLInt, dtULInt];
end;

{ a String / WString: its value is on the string stack }
function SclIsStr(T: TDataType): Boolean;
begin
  Result := T in [dtString, dtWString];
end;

{ the type of a + b: REAL wins, then TIME, then the wider integer }
function SclArith(A, B: TDataType): TDataType;
begin
  if (A = dtLReal) or (B = dtLReal) then Exit(dtLReal);
  if (A = dtReal) or (B = dtReal) then
  begin
    // a 64 bit integer beside a Real: LReal
    if (A in Int64Types) or (B in Int64Types) then Exit(dtLReal);
    Exit(dtReal);
  end;
  if (A = dtLTime) or (B = dtLTime) then Exit(dtLTime);
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
  LoopDepth, CaseDepth, MuxDepth: Integer;
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
    S, W: string;
    InCmt: Boolean;
    C: Char;

    function At(K: Integer): Char;
    begin
      if K <= Len then Result := S[K] else Result := #0;
    end;

    { the literals with '-' and ':' in them }
    function DateLit(const Pfx: string): Boolean;
    begin
      Result := (Pfx = 'D') or (Pfx = 'DATE') or (Pfx = 'DT') or (Pfx = 'DATE_AND_TIME') or (Pfx = 'TOD') or
        (Pfx = 'TIME_OF_DAY') or (Pfx = 'LTOD') or (Pfx = 'LTIME_OF_DAY') or (Pfx = 'LDT');
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
          // 'text': '' and $' are quotes inside it (SclStrDecode makes the text)
          J := I + 1;
          while J <= Len do
          begin
            if S[J] = '$' then Inc(J)
            else if S[J] = '''' then
            begin
              if At(J + 1) <> '''' then Break;
              Inc(J);
            end;
            Inc(J);
          end;
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
            // T#5S, S5T#2S, TIME#.., L#10, W#16#FF, C#5, INT#-5, D#2024-01-31, TOD#12:00:00, CHAR#'A' ...
            W := UpperCase(Copy(S, I, J - I));
            Inc(J);
            if (J <= Len) and (S[J] = '''') then
            begin
              Inc(J);
              while J <= Len do
              begin
                if S[J] = '$' then Inc(J)
                else if S[J] = '''' then
                begin
                  if At(J + 1) <> '''' then Break;
                  Inc(J);
                end;
                Inc(J);
              end;
              if J <= Len then Inc(J);
            end
            else
            begin
              if (J <= Len) and (S[J] in ['-', '+']) then Inc(J);
              while (J <= Len) and ((S[J] in ['A'..'Z', 'a'..'z', '0'..'9', '_', '#', '.']) or
                ((S[J] in ['-', ':']) and DateLit(W))) do Inc(J);
            end;
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

  { a 64 bit constant: exact in KI }
  procedure EK64(V: Int64; T: TDataType);
  var
    I: Integer;
  begin
    I := E(opSPushK, tcWord, T);
    FBlock.Ops[I].K := V;
    FBlock.Ops[I].KI := V;
  end;

  { a constant of the type T: 64 bit exact }
  procedure EKT(V: Int64; T: TDataType);
  begin
    if T in Int64Types then EK64(V, T) else EK(V, T);
  end;

  function Cat(T: TDataType): TTimeCat;
  begin
    if T in RealTypes then Result := tcFloat else Result := tcFix;
  end;

  procedure SetMon(OpIx, Line: Integer);
  begin
    // SCL inside a LAD / STL network has no monitor slots of its own
    if FInline then Exit;
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
      Slice: Char;        // a slice of a bit string: X / B / W / D (#0: none), .%X3
      SliceN: Integer;
      BaseT: TDataType;   // a slice: the type of the whole variable
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
    Er, U, Disp, Cs: string;
    IxT: TDataType;
    V: TVarInfo;
    I, K, W, Wd: Integer;
  begin
    FillChar(Result, SizeOf(Result), 0);
    Result.Opd.Block := -1;
    T := Tok;
    if (T.Kind = stHash) and (FConsts.IndexOf(UpperCase(T.S)) >= 0) then
      Fail('#' + T.S + ' is a constant (VAR CONSTANT): it cannot be written');
    case T.Kind of
      stHash:
        if (FSrc <> nil) and (FSrc.Kind = bkFC) and SameText(T.S, FSrc.Name) and (FSrc.Iface.FindVar(T.S) < 0) then
        begin
          // #<FC name> := ..: the function value (TIA writes it so)
          Result.Text := '';
          for I := 0 to High(FSrc.Iface.Vars) do
            if FSrc.Iface.Vars[I].Section = vsReturn then Result.Text := '#' + FSrc.Iface.Vars[I].Name;
          if Result.Text = '' then Fail(Format('FC "%s" has no Return value', [FSrc.Name]));
        end
        else
          Result.Text := '#' + T.S;
      stQuoted: Result.Text := '"' + T.S + '"';
      stPercent, stIdent: Result.Text := T.S;
    else
      Fail('operand expected, found "' + T.S + '"');
    end;
    Disp := Result.Text;
    Next;
    while True do
    begin
      if IsSym('.') and (PeekTok(1).Kind = stPercent) then
      begin
        // a slice: .%X3 (a bit), .%B1 (a byte), .%W0 (a word), .%D0 (a double word)
        U := UpperCase(PeekTok(1).S);
        if (Length(U) < 3) or not (U[2] in ['X', 'B', 'W', 'D']) or not TryStrToInt(Copy(U, 3, MaxInt), I) or (I < 0) then
          Fail('slice expected: .%X0, .%B0, .%W0, .%D0');
        Result.Slice := U[2];
        Result.SliceN := I;
        Disp := Disp + '.' + PeekTok(1).S;
        Next;
        Next;
        Break;
      end;
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
        // constant indexes: [3], [-1], [1, 2]
        K := 0;
        Cs := '';
        while True do
        begin
          if (PeekTok(K).Kind = stSym) and (PeekTok(K).S = '-') then
          begin
            Cs := Cs + '-';
            Inc(K);
          end;
          if PeekTok(K).Kind <> stNum then
          begin
            Cs := '';
            Break;
          end;
          Cs := Cs + PeekTok(K).S;
          Inc(K);
          if (PeekTok(K).Kind = stSym) and (PeekTok(K).S = ']') then Break;
          if (PeekTok(K).Kind = stSym) and (PeekTok(K).S = ',') then
          begin
            Cs := Cs + ',';
            Inc(K);
            Continue;
          end;
          Cs := '';
          Break;
        end;
        if Cs <> '' then
        begin
          Result.Text := Result.Text + '[' + Cs + ']';
          Disp := Disp + '[' + Cs + ']';
          for I := 0 to K do Next;
          Continue;
        end;
        // a variable index: computed at run time, the operand is resolved at the first element
        if not FRes.ResolveVar(Result.Text, V, Er) then Fail(Er);
        if not V.IsArray then Fail(Disp + ' is not an array');
        if Length(V.Dims) > 1 then
        begin
          // [i, j, ..]: the element number row by row (the last index fastest)
          for K := 0 to High(V.Dims) do
          begin
            if K > 0 then
            begin
              Expect(',');
              EK(V.Dims[K].Hi - V.Dims[K].Lo + 1, dtDInt);
              E(opSBin, tcFix, dtDInt, sbMul);
            end;
            IxT := Expr;
            if not (IxT in [dtInt, dtDInt, dtSInt, dtUSInt, dtUInt, dtUDInt, dtByte, dtWord, dtDWord]) then
              Fail('array index must be an integer');
            EK(V.Dims[K].Lo, dtDInt);
            E(opSBin, tcFix, dtDInt, sbSub);
            if K > 0 then E(opSBin, tcFix, dtDInt, sbAdd);
          end;
          IxT := dtDInt;
        end
        else
        begin
          IxT := Expr;
          if not (IxT in [dtInt, dtDInt, dtSInt, dtUSInt, dtUInt, dtUDInt, dtByte, dtWord, dtDWord]) then
            Fail('array index must be an integer');
        end;
        Expect(']');
        if V.T = dtBool then I := E(opSIndex, tcFix, dtDInt, 1)
        else I := E(opSIndex, tcFix, dtDInt, ElemStride(V.T, V.Udt) * 8);
        FBlock.Ops[I].Lo := V.Lo;
        FBlock.Ops[I].Hi := V.Hi;
        FBlock.Ops[I].Ext := Ord(Result.Indexed);   // an outer index is already on the stack
        FBlock.Ops[I].Opd.Text := Disp;
        if Length(V.Dims) > 1 then
        begin
          Cs := '';
          for K := 0 to High(V.Dims) do
          begin
            if K > 0 then Cs := Cs + ',';
            Cs := Cs + IntToStr(V.Dims[K].Lo);
          end;
          Result.Text := Result.Text + '[' + Cs + ']';
        end
        else
          Result.Text := Result.Text + Format('[%d]', [V.Lo]);
        Disp := Disp + '[..]';
        Result.Indexed := True;
        Continue;
      end;
      Break;
    end;
    // a whole struct, array or IEC instance as the target or source of a := b
    if AllowBlock and (Result.Method = '') and (Result.Slice = #0) and (Result.Text[1] in ['"', '#']) and
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
    if Result.Slice <> #0 then
    begin
      Result.BaseT := Result.T;
      case Result.T of
        dtByte, dtSInt, dtUSInt, dtChar: W := 8;
        dtWord, dtInt, dtUInt: W := 16;
        dtDWord, dtDInt, dtUDInt: W := 32;
        dtLWord, dtLInt, dtULInt: W := 64;
      else
        Fail(Format('%s is %s: a slice needs a bit string or an integer', [Result.Text, DataTypeNames[Result.T]]));
      end;
      case Result.Slice of
        'X': begin Wd := 1; Result.T := dtBool; end;
        'B': begin Wd := 8; Result.T := dtByte; end;
        'W': begin Wd := 16; Result.T := dtWord; end;
      else
        begin Wd := 32; Result.T := dtDWord; end;
      end;
      if (Wd >= W) or ((Result.SliceN + 1) * Wd > W) then
        Fail(Format('%s: no %s in a %s', [Disp, '.%' + Result.Slice + IntToStr(Result.SliceN), DataTypeNames[Result.BaseT]]));
    end;
    // a string: its type (the max length) for the store
    if SclIsStr(Result.T) and FRes.ResolveVar(Result.Text, V, Er) then Result.Info := V;
  end;

  { a slice: its width in bits and its shift from bit 0 }
  function SliceW(const R: TRef): Integer;
  begin
    case R.Slice of
      'X': Result := 1;
      'B': Result := 8;
      'W': Result := 16;
    else
      Result := 32;
    end;
  end;

  function Path: TRef;
  begin
    Result := PathEx(False);
  end;

  { the type of a struct / array as TIA writes it, and the bytes it takes }
  function BlockTypeName(const V: TVarInfo): string;
  begin
    if V.T = dtStruct then Result := '"' + V.Udt.Name + '"'
    else if (SclIsStr(V.T) or (V.T in [dtIECTimer, dtIECCounter])) and (V.Udt <> nil) then Result := V.Udt.Name
    else Result := DataTypeNames[V.T];
    if V.IsArray then Result := Format('Array[%d..%d] of %s', [V.Lo, V.Hi, Result]);
  end;

  function BlockBytes(const V: TVarInfo): Integer;
  begin
    if not V.IsArray then
    begin
      if (V.T = dtStruct) or ((SclIsStr(V.T) or (V.T in [dtIECTimer, dtIECCounter])) and (V.Udt <> nil)) then
        Result := V.Udt.Size
      else
        Result := DataTypeSize(V.T);
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

  { the max length of a String variable (254 when its type is not known) }
  function StrMaxOf(const V: TVarInfo): Integer;
  begin
    if (V.Udt <> nil) and (V.Udt.StrMax > 0) then Result := V.Udt.StrMax else Result := 254;
  end;

  procedure StrPushOpd(const O: TOperand; T: TDataType; Indexed: Boolean);
  var
    I: Integer;
  begin
    I := E(opStrPush, tcWord, T, Ord(T = dtWString));
    FBlock.Ops[I].Opd := O;
    FBlock.Ops[I].Ext := Ord(Indexed);
    FBlock.Ops[I].Weight := 4;
  end;

  function StrStoreOpd(const O: TOperand; T: TDataType; AMax: Integer; Indexed: Boolean): Integer;
  begin
    Result := E(opStrStore, tcWord, T, Ord(T = dtWString));
    FBlock.Ops[Result].Opd := O;
    FBlock.Ops[Result].Ext := Ord(Indexed);
    FBlock.Ops[Result].Hi := AMax;
    FBlock.Ops[Result].Weight := 4;
  end;

  { a Char / WChar (on the value stack) where a string is wanted }
  procedure CharToStr;
  begin
    E(opStrOp, tcWord, dtString, soChr);
  end;

  procedure PushRef(const R: TRef);
  var
    I: Integer;
    ST: TDataType;
  begin
    if SclIsStr(R.T) then
    begin
      StrPushOpd(R.Opd, R.T, R.Indexed);
      Exit;
    end;
    if R.Slice <> #0 then
    begin
      // (whole shr n * width) and mask
      if R.BaseT in Int64Types then ST := dtLWord else ST := dtDWord;
      if R.Indexed then I := E(opSPushIdx, tcWord, R.BaseT) else I := E(opSPush, tcWord, R.BaseT);
      FBlock.Ops[I].Opd := R.Opd;
      EK(R.SliceN * SliceW(R), dtDInt);
      E(opSBin, tcWord, ST, sbShr);
      EKT((Int64(1) shl SliceW(R)) - 1, ST);
      E(opSBin, tcWord, ST, sbBAnd);
      Exit;
    end;
    if R.Indexed then I := E(opSPushIdx, tcWord, R.T)
    else I := E(opSPush, tcWord, R.T);
    FBlock.Ops[I].Opd := R.Opd;
  end;

  function StoreRef(const R: TRef; Line: Integer): Integer;
  var
    I: Integer;
    Mask: Int64;
    ST: TDataType;
  begin
    if SclIsStr(R.T) then
    begin
      Result := StrStoreOpd(R.Opd, R.T, StrMaxOf(R.Info), R.Indexed);
      SetMon(Result, Line);
      Exit;
    end;
    if R.Slice <> #0 then
    begin
      // read, change the slice, write back: the value waits in register 14, an index offset in 15
      if SliceW(R) = 64 then Mask := -1 else Mask := (Int64(1) shl SliceW(R)) - 1;
      if R.BaseT in Int64Types then ST := dtLWord else ST := dtDWord;
      E(opSSetReg, tcWord, ST, 14);
      if R.Indexed then
      begin
        E(opSSetReg, tcWord, dtDInt, 15);
        E(opSGetReg, tcWord, dtDInt, 15);
        I := E(opSPushIdx, tcWord, R.BaseT);
      end
      else
        I := E(opSPush, tcWord, R.BaseT);
      FBlock.Ops[I].Opd := R.Opd;
      if ST = dtLWord then EKT(not (Mask shl (R.SliceN * SliceW(R))), ST)
      else EKT(not (Mask shl (R.SliceN * SliceW(R))) and $FFFFFFFF, ST);
      E(opSBin, tcWord, ST, sbBAnd);
      E(opSGetReg, tcWord, ST, 14);
      EKT(Mask, ST);
      E(opSBin, tcWord, ST, sbBAnd);
      EK(R.SliceN * SliceW(R), dtDInt);
      E(opSBin, tcWord, ST, sbShl);
      E(opSBin, tcWord, ST, sbBOr);
      if R.Indexed then
      begin
        E(opSSetReg, tcWord, ST, 14);
        E(opSGetReg, tcWord, dtDInt, 15);
        E(opSGetReg, tcWord, ST, 14);
        Result := E(opSStoreIdx, tcWord, R.BaseT);
      end
      else
        Result := E(opSStore, tcWord, R.BaseT);
      FBlock.Ops[Result].Opd := R.Opd;
      SetMon(Result, Line);
      Exit;
    end;
    if R.Indexed then Result := E(opSStoreIdx, tcWord, R.T)
    else Result := E(opSStore, tcWord, R.T);
    FBlock.Ops[Result].Opd := R.Opd;
    SetMon(Result, Line);
  end;

  { can a value of type Src go to a variable of type Dst? }
  procedure CheckAssign(Dst, Src: TDataType; const What: string);
  begin
    if Dst = Src then Exit;
    if SclIsStr(Dst) or SclIsStr(Src) then
    begin
      // a String takes a String / WString / Char / WChar (the Char was made a string)
      if SclIsStr(Dst) and (SclIsStr(Src) or (Src in [dtChar, dtWChar])) then Exit;
      Fail(Format('type mismatch: %s := %s (%s)', [DataTypeNames[Dst], DataTypeNames[Src], What]));
    end;
    if (Dst = dtBool) <> (Src = dtBool) then
      Fail(Format('type mismatch: %s := %s (%s)', [DataTypeNames[Dst], DataTypeNames[Src], What]));
    if (Src in RealTypes) and not (Dst in RealTypes) then
      Fail(Format('%s to %s needs a conversion: %s_TO_%s(...) (%s)', [UpperCase(DataTypeNames[Src]),
        DataTypeNames[Dst], UpperCase(DataTypeNames[Src]), UpperCase(DataTypeNames[Dst]), What]));
    if (Src = dtLReal) and (Dst = dtReal) then
      Fail(Format('LREAL to Real needs a conversion: LREAL_TO_REAL(...) (%s)', [What]));
    // the 64 bit times / dates: the same type, or an untyped number
    if ((Dst in [dtLTime, dtLTOD, dtLDT, dtDT]) or (Src in [dtLTime, dtLTOD, dtLDT, dtDT])) and
      not ((Src = dtDInt) or (Dst in [dtLInt, dtULInt, dtLWord]) and SclIsTimeT(Src)) then
      Fail(Format('type mismatch: %s := %s (%s)', [DataTypeNames[Dst], DataTypeNames[Src], What]));
    if (Dst in [dtTime, dtTOD]) and not (Src in [dtTime, dtTOD, dtDInt]) and (SclRank(Src) < 3) then
      Fail(Format('type mismatch: %s := %s', [DataTypeNames[Dst], DataTypeNames[Src]]));

  end;

  { ---------- function calls ---------- }

  { the arguments in the order of Names (positional or name := value); each
    argument's code is moved into place, so the names may come in any order }
  function Args(const Names: array of string; out Types: array of TDataType; MinArgs: Integer;
    StrMask: Integer = 0): Integer;
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
      if (StrMask and (1 shl Ix) <> 0) and (T in [dtChar, dtWChar]) then
      begin
        CharToStr;
        T := dtString;
      end;
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
      dtInt, dtUInt, dtDInt, dtUDInt, dtReal, dtTime, dtS5Time, dtDate, dtTOD, dtWChar, dtLWord, dtLInt, dtULInt,
      dtLReal, dtLTime, dtLTOD, dtLDT, dtDT]);
  end;

  { the conversions between the times and dates that change the unit: TIME <-> LTIME (ms, ns), TOD <-> LTOD,
    DT <-> LDT, DT / LDT -> DATE, TOD, DATE -> DT; False for the others }
  function TimeConv(TA, TB: TDataType): Boolean;
  begin
    Result := True;
    if ((TA = dtTime) and (TB = dtLTime)) or ((TA = dtTOD) and (TB = dtLTOD)) then
    begin
      EK64(1000000, dtLInt);
      E(opSBin, tcFix, dtLInt, sbMul);
    end
    else if ((TA = dtLTime) and (TB = dtTime)) or ((TA = dtLTOD) and (TB = dtTOD)) then
    begin
      EK64(1000000, dtLInt);
      E(opSBin, tcFix, dtLInt, sbDiv);
      E(opSUn, tcWord, TB, suWrap);
    end
    else if (TA = dtDT) and (TB = dtLDT) then
    begin
      // ms since 1990 -> ns since 1970
      EK64(631152000000, dtLInt);
      E(opSBin, tcFix, dtLInt, sbAdd);
      EK64(1000000, dtLInt);
      E(opSBin, tcFix, dtLInt, sbMul);
    end
    else if (TA = dtLDT) and (TB = dtDT) then
    begin
      EK64(1000000, dtLInt);
      E(opSBin, tcFix, dtLInt, sbDiv);
      EK64(631152000000, dtLInt);
      E(opSBin, tcFix, dtLInt, sbSub);
    end
    else if (TA = dtDT) and (TB in [dtDate, dtTOD]) then
    begin
      EK64(86400000, dtLInt);
      if TB = dtDate then E(opSBin, tcFix, dtLInt, sbDiv) else E(opSBin, tcFix, dtLInt, sbMod);
      E(opSUn, tcWord, TB, suWrap);
    end
    else if (TA = dtLDT) and (TB in [dtDate, dtTOD, dtLTOD]) then
    begin
      EK64(86400000000000, dtLInt);
      if TB = dtDate then
      begin
        E(opSBin, tcFix, dtLInt, sbDiv);
        EK64(7305, dtLInt);
        E(opSBin, tcFix, dtLInt, sbSub);
      end
      else
      begin
        E(opSBin, tcFix, dtLInt, sbMod);
        if TB = dtTOD then
        begin
          EK64(1000000, dtLInt);
          E(opSBin, tcFix, dtLInt, sbDiv);
        end;
      end;
      E(opSUn, tcWord, TB, suWrap);
    end
    else if (TA = dtDate) and (TB = dtDT) then
    begin
      EK64(86400000, dtLInt);
      E(opSBin, tcFix, dtLInt, sbMul);
    end
    else
      Result := False;
  end;

  { MUX(K := k, IN0 := .., IN1 := .., .. INELSE := ..) or MUX(k, in0, in1, ..): K in a register, the
    result built up in another one: acc := SEL(K = n, acc, INn) for every input }
  function MuxCall: TDataType;
  var
    Chunks: array of TOpChunk;
    Tys: array of TDataType;
    Given: array of Boolean;
    KCh, ElseCh: TOpChunk;
    HasK, HasElse: Boolean;
    Ix, K, Pos0, RK, RA, PosN: Integer;
    Nm: string;
    T, ElseT: TDataType;
  begin
    if MuxDepth >= 2 then Fail('MUX nested too deep');
    RK := 10 + 2 * MuxDepth;
    RA := RK + 1;
    Inc(MuxDepth);
    try
      Expect('(');
      HasK := False;
      HasElse := False;
      ElseT := dtNone;
      PosN := 0;
      Chunks := nil;
      Tys := nil;
      Given := nil;
      while not IsSym(')') do
      begin
        if (Tok.Kind = stIdent) and (PeekTok(1).Kind = stSym) and (PeekTok(1).S = ':=') then
        begin
          Nm := UpperCase(Tok.S);
          if Nm = 'K' then Ix := -1
          else if Nm = 'INELSE' then Ix := -3
          else if not ((Copy(Nm, 1, 2) = 'IN') and TryStrToInt(Copy(Nm, 3, MaxInt), Ix) and (Ix >= 0) and (Ix <= 31)) then
            Fail('MUX has no parameter ' + Nm);
          Next;
          Next;
        end
        else
        begin
          if PosN = 0 then Ix := -1 else Ix := PosN - 1;
          Inc(PosN);
        end;
        Pos0 := Length(FBlock.Ops);
        T := Expr;
        if Ix = -1 then
        begin
          if not (T in [dtInt, dtDInt, dtSInt, dtUSInt, dtUInt, dtUDInt, dtByte, dtWord, dtDWord]) then
            Fail('MUX: K must be an integer');
          KCh := TakeChunk(Pos0);
          HasK := True;
        end
        else if Ix = -3 then
        begin
          ElseCh := TakeChunk(Pos0);
          ElseT := T;
          HasElse := True;
        end
        else
        begin
          if Ix > 31 then Fail('MUX: at most 32 inputs');
          if Ix > High(Chunks) then
          begin
            SetLength(Chunks, Ix + 1);
            SetLength(Tys, Ix + 1);
            SetLength(Given, Ix + 1);
          end;
          Chunks[Ix] := TakeChunk(Pos0);
          Tys[Ix] := T;
          Given[Ix] := True;
        end;
        if IsSym(',') then Next else Break;
      end;
      Expect(')');
      if not HasK then Fail('MUX: K missing');
      if Length(Chunks) < 2 then Fail('MUX needs IN0 and IN1');
      for K := 0 to High(Chunks) do
        if not Given[K] then Fail(Format('MUX: IN%d missing', [K]));
      Result := Tys[0];
      for K := 1 to High(Tys) + Ord(HasElse) do
      begin
        if K <= High(Tys) then T := Tys[K] else T := ElseT;
        if (Result = dtBool) <> (T = dtBool) then Fail('MUX: the inputs must have the same kind of type');
        if SclIsStr(Result) or SclIsStr(T) then Fail('MUX of strings is not supported');
        if Result <> dtBool then Result := SclArith(Result, T);
      end;
      PutChunk(KCh);
      E(opSSetReg, tcWord, dtDInt, RK);
      if HasElse then PutChunk(ElseCh) else EK(0, Result);
      E(opSSetReg, tcWord, Result, RA);
      for K := 0 to High(Chunks) do
      begin
        E(opSGetReg, tcWord, dtDInt, RK);
        EK(K, dtDInt);
        E(opSBin, tcFix, dtDInt, sbEq);
        E(opSGetReg, tcWord, Result, RA);
        PutChunk(Chunks[K]);
        E(opSTern, tcWord, Result, stSel);
        E(opSSetReg, tcWord, Result, RA);
      end;
      E(opSGetReg, tcWord, Result, RA);
    finally
      Dec(MuxDepth);
    end;
  end;

  function Call(const Name: string): TDataType;
  var
    U, A, B: string;
    Q, Cnt: Integer;
    Ts: array[0..31] of TDataType;
    MNames: array of string;
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
        if TimeConv(TA, TB) then Exit(TB);
        if TB = dtBool then E(opSUn, tcWord, dtBool, suBool)
        else
        begin
          if (Ts[0] in RealTypes) and not (TB in RealTypes) then E(opSUn, tcFloat, TB, suRound);
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
          // SQRT, SIN ... of an LReal: an LReal
          if Ts[0] = dtLReal then Result := dtLReal else Result := dtReal;
          E(opSUn, tcFloat, Result, Un);
          Exit;
        end;
      end;
    end;
    if U = 'MUX' then Exit(MuxCall);
    // the string functions
    case U of
      'LEN':
        begin
          Args(['IN'], Ts, 1, 1);
          if not SclIsStr(Ts[0]) then Fail('LEN: a String expected');
          E(opStrOp, tcWord, dtInt, soLen);
          Exit(dtInt);
        end;
      'CONCAT', 'FIND':
        begin
          Args(['IN1', 'IN2'], Ts, 2, 3);
          if not SclIsStr(Ts[0]) or not SclIsStr(Ts[1]) then Fail(U + ': String inputs expected');
          if U = 'FIND' then
          begin
            E(opStrOp, tcWord, dtInt, soFind);
            Exit(dtInt);
          end;
          if (Ts[0] = dtWString) or (Ts[1] = dtWString) then Result := dtWString else Result := dtString;
          E(opStrOp, tcWord, Result, soConcat);
          Exit;
        end;
      'LEFT', 'RIGHT', 'MID':
        begin
          if U = 'MID' then Args(['IN', 'L', 'P'], Ts, 3, 1) else Args(['IN', 'L'], Ts, 2, 1);
          if not SclIsStr(Ts[0]) then Fail(U + ': a String expected');
          if not (Ts[1] in [dtInt, dtDInt, dtSInt, dtUSInt, dtUInt, dtUDInt, dtByte, dtWord]) then
            Fail(U + ': L must be an integer');
          if (U = 'MID') and not (Ts[2] in [dtInt, dtDInt, dtSInt, dtUSInt, dtUInt, dtUDInt, dtByte, dtWord]) then
            Fail('MID: P must be an integer');
          case U of
            'LEFT': E(opStrOp, tcWord, Ts[0], soLeft);
            'RIGHT': E(opStrOp, tcWord, Ts[0], soRight);
          else
            E(opStrOp, tcWord, Ts[0], soMid);
          end;
          Exit(Ts[0]);
        end;
    end;
    case U of
      'MIN', 'MAX':
        begin
          // IN1 .. IN32
          SetLength(MNames, 32);
          for Q := 0 to 31 do MNames[Q] := 'IN' + IntToStr(Q + 1);
          Cnt := Args(MNames, Ts, 2);
          for Q := 0 to Cnt - 1 do
            if SclIsStr(Ts[Q]) then Fail(U + ' of strings is not supported');
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
          if not SclIsNum(Ts[0]) or not SclIsNum(Ts[1]) or not SclIsNum(Ts[2]) then Fail('LIMIT needs numbers');
          Result := SclArith(SclArith(Ts[0], Ts[1]), Ts[2]);
          E(opSTern, Cat(Result), Result, stLimit);
        end;
      'SEL':
        begin
          Args(['G', 'IN0', 'IN1'], Ts, 3);
          if Ts[0] <> dtBool then Fail('SEL: G must be BOOL');
          if SclIsStr(Ts[1]) or SclIsStr(Ts[2]) then Fail('SEL of strings is not supported');
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
    if SclIsStr(V.T) then
    begin
      // a String parameter: copied as text (the target keeps its own max length)
      if not SclIsStr(A.T) then Fail(Format('type mismatch: parameter %s is %s', [Nm, DataTypeNames[V.T]]));
      if ToMember then
      begin
        if IIdx then E(opSGetReg, tcWord, dtDInt, 9);
        PutChunk(ACh);
        PushRef(A);
        StrStoreOpd(MO, V.T, StrMaxOf(V), IIdx);
      end
      else
      begin
        PutChunk(ACh);
        if IIdx then E(opSGetReg, tcWord, dtDInt, 9);
        StrPushOpd(MO, V.T, IIdx);
        StoreRef(A, Line);
      end;
      Exit;
    end;
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
    if SclIsStr(V.T) then
    begin
      if T in [dtChar, dtWChar] then CharToStr;
      CheckAssign(V.T, T, Nm);
      StrStoreOpd(MO, V.T, StrMaxOf(V), IIdx);
      Exit;
    end;
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
    Order: array of Integer;
    PosN: Integer;
    Positional: Boolean;
    Sec: TVarSection;

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
      Result.Dims := Mv.Dims;
      Result.TypeText := Mv.TypeText;
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
    // the parameters in the order of a positional call: Input, Output, InOut
    Order := nil;
    for Sec := vsInput to vsInOut do
      for K := 0 to High(U.Vars) do
        if U.Vars[K].Section = Sec then
        begin
          SetLength(Order, Length(Order) + 1);
          Order[High(Order)] := K;
        end;
    PosN := 0;
    while not IsSym(')') do
    begin
      if (Tok.Kind = stIdent) and (PeekTok(1).Kind = stSym) and ((PeekTok(1).S = ':=') or (PeekTok(1).S = '=>')) then
      begin
        Nm := Tok.S;
        Next;
        K := U.FindVar(Nm);
        Positional := False;
      end
      else
      begin
        // "F"(2, 3, "D".o): the parameters in the order of the interface
        if PosN > High(Order) then Fail(Format('FC%d "%s": too many parameters', [Fc.Number, Fc.Name]));
        K := Order[PosN];
        Inc(PosN);
        Nm := U.Vars[K].Name;
        Positional := True;
      end;
      if (K < 0) or not (U.Vars[K].Section in [vsInput, vsOutput, vsInOut]) then
        Fail(Format('FC%d "%s" has no parameter %s', [Fc.Number, Fc.Name, Nm]));
      M := U.Vars[K];
      if not M.Valid then Fail(Format('FC%d.%s: unknown data type %s', [Fc.Number, Nm, M.TypeText]));
      if Given[K] then Fail(Nm + ' is given twice');
      Given[K] := True;
      V := ParamInfo(M);
      if (Positional and (M.Section <> vsOutput)) or (not Positional and IsSym(':=')) then
      begin
        if not Positional then Next;
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
          if not IsBlockType(V) and not Act.IsBlock and (Act.T <> V.T) and not (SclIsStr(V.T) and SclIsStr(Act.T)) then
            Fail(Format('InOut %s is %s: the variable must have the same type (%s)', [Nm, DataTypeNames[V.T], DataTypeNames[Act.T]]));
          ParamCopy(V, M.Name, False, Act, Ch, True, Line);
          P1 := Length(FBlock.Ops);
          ParamCopy(V, M.Name, False, Act, Ch, False, Line);
          SetLength(Posts, NPost + 1);
          Posts[NPost] := TakeChunk(P1);
          Inc(NPost);
        end;
      end
      else if Positional or IsSym('=>') then
      begin
        if not Positional then Next;
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
        if SclIsStr(V.T) then I := E(opStrPush, tcWord, V.T, Ord(V.T = dtWString))
        else I := E(opSPush, tcWord, V.T);
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
    Ty: TDataType;
    K: Integer;
    I64: Int64;
    Q64: QWord;
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
          // integer literals are untyped: they calculate in 32 bit, the target type wraps; above the DInt
          // range a UDInt, above it an LInt, above that a ULInt (exact)
          if TryStrToInt64(T.S, I64) then
          begin
            if I64 > 4294967295 then
            begin
              EK64(I64, dtLInt);
              Exit(dtLInt);
            end;
            if I64 > 2147483647 then Result := dtUDInt else Result := dtDInt;
            EK(I64, Result);
            Exit;
          end;
          if not TryStrToQWord(T.S, Q64) then Fail('number out of range ' + T.S);
          EK64(Int64(Q64), dtULInt);
          Exit(dtULInt);
        end;
      stTyped:
        begin
          Next;
          U := UpperCase(Copy(T.S, 1, Pos('#', T.S) - 1));
          if ((U = 'STRING') or (U = 'WSTRING')) and (Pos('''', T.S) = Pos('#', T.S) + 1) and
            (T.S[Length(T.S)] = '''') then
          begin
            // STRING#'text', WSTRING#'text'
            K := E(opStrPushK, tcWord, dtString, Ord(U = 'WSTRING'));
            FBlock.Ops[K].Opd.Text := SclStrDecode(Copy(T.S, Pos('#', T.S) + 2, Length(T.S) - Pos('#', T.S) - 2),
              U = 'WSTRING');
            if U = 'WSTRING' then Exit(dtWString);
            Exit(dtString);
          end;
          if not ParseConst(T.S, C) then
          begin
            // INT#5, 8#17, D#2024-01-31, TOD#12:00:00, LINT#.., LT#.., LDT#.. (64 bit exact)
            if not SclTypedLiteralEx(T.S, V, I64, Ty) then Fail('bad constant ' + T.S);
            if Ty in Int64Types then EK64(I64, Ty) else EK(V, Ty);
            Exit(Ty);
          end;
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
          // 'A' is a Char (it goes into a String too), 'text' a String
          U := SclStrDecode(T.S);
          if Length(UTF8Decode(U)) = 1 then
          begin
            EK(Ord(UTF8Decode(U)[1]) and $FF, dtChar);
            Exit(dtChar);
          end;
          K := E(opStrPushK, tcWord, dtString);
          FBlock.Ops[K].Opd.Text := U;
          FBlock.Ops[K].Weight := 2;
          Exit(dtString);
        end;
      stIdent:
        begin
          U := UpperCase(T.S);
          if (U = '__RLO__') and FInline then
          begin
            // the RLO of the LAD rung / STL line
            Next;
            E(opSRloPush, tcBit, dtBool);
            Exit(dtBool);
          end;
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
    if (T.Kind = stHash) and (FConsts.IndexOf(UpperCase(T.S)) >= 0) then
    begin
      // a constant of VAR CONSTANT
      K := PtrInt(FConsts.Objects[FConsts.IndexOf(UpperCase(T.S))]);
      Next;
      if FConstT[K] in Int64Types then EK64(FConstI[K], FConstT[K]) else EK(FConstV[K], FConstT[K]);
      Exit(FConstT[K]);
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
      if (Result = dtLReal) or (B = dtLReal) then Result := dtLReal else Result := dtReal;
      E(opSBin, tcFloat, Result, sbPow);
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
      if (Result in [dtTOD, dtLTOD, dtDT, dtLDT, dtDate]) or (B in [dtTOD, dtLTOD, dtDT, dtLDT, dtDate]) then
        Fail(Format('* / MOD with %s is not allowed', [DataTypeNames[Result]]));
      R := SclArith(Result, B);
      if (Op = sbMod) and (R in RealTypes) then Fail('MOD needs integers');
      // TIME * INT stays TIME
      E(opSBin, Cat(R), R, Op);
      Result := R;
    end;
  end;

  { + / - with a time or a date (as in TIA): TIME +- TIME, TOD +- TIME (within a day), DT +- TIME,
    LTOD / LDT +- LTIME, TOD - TOD = TIME, DT - DT = TIME, LTOD / LDT - LTOD / LDT = LTIME; the type of the
    result, the type to compute in (Calc) }
  function TimeArith(Op: Integer; A, B: TDataType; out Calc: TDataType): TDataType;
  var
    Ok: Boolean;
  begin
    Result := dtNone;
    if (A = dtS5Time) or (B = dtS5Time) then Fail('arithmetic with S5Time is not allowed (S5TIME_TO_TIME)');
    if ((A = dtTime) and (B = dtLTime)) or ((A = dtLTime) and (B = dtTime)) then
      Fail('TIME and LTIME: one of them needs a conversion (TIME_TO_LTIME, LTIME_TO_TIME)');
    Ok := False;
    if (A in [dtTime, dtLTime]) and ((B = A) or SclIsInt(B)) then begin Result := A; Ok := True; end
    else if (B in [dtTime, dtLTime]) and SclIsInt(A) and (Op = sbAdd) then begin Result := B; Ok := True; end
    else if (A in [dtTOD, dtDT]) and ((B = dtTime) or SclIsInt(B)) then begin Result := A; Ok := True; end
    else if (A in [dtLTOD, dtLDT]) and ((B = dtLTime) or SclIsInt(B)) then begin Result := A; Ok := True; end
    else if (Op = sbSub) and (A = B) and (A in [dtTOD, dtDT]) then begin Result := dtTime; Ok := True; end
    else if (Op = sbSub) and (A = B) and (A in [dtLTOD, dtLDT]) then begin Result := dtLTime; Ok := True; end;
    if not Ok then
      Fail(Format('%s %s %s is not allowed', [DataTypeNames[A], Copy('+-', Op + 1, 1), DataTypeNames[B]]));
    // 64 bit: in Int64; TOD: in DInt (then into the day)
    if (A in Int64Types) or (B in Int64Types) then Calc := dtLInt
    else Calc := dtDInt;
  end;

  function AddExpr: TDataType;
  var
    B, R, Cl: TDataType;
    Op: Integer;
  begin
    Result := MulExpr;
    while IsSym('+') or IsSym('-') do
    begin
      if IsSym('+') then Op := sbAdd else Op := sbSub;
      Next;
      B := MulExpr;
      if not SclIsNum(Result) or not SclIsNum(B) then Fail('+ - need numbers');
      if SclIsTimeT(Result) or SclIsTimeT(B) then
      begin
        R := TimeArith(Op, Result, B, Cl);
        E(opSBin, tcFix, Cl, Op);
        // a time of day stays inside the day
        if R = dtTOD then
        begin
          EK(86400000, dtDInt);
          E(opSBin, tcFix, dtDInt, sbAdd);
          EK(86400000, dtDInt);
          E(opSBin, tcFix, dtDInt, sbMod);
        end
        else if R = dtLTOD then
        begin
          EK64(86400000000000, dtLInt);
          E(opSBin, tcFix, dtLInt, sbAdd);
          EK64(86400000000000, dtLInt);
          E(opSBin, tcFix, dtLInt, sbMod);
        end;
        Result := R;
        Continue;
      end;
      R := SclArith(Result, B);
      E(opSBin, Cat(R), R, Op);
      Result := R;
    end;
  end;

  function Compare(Lower: Boolean): TDataType;
  var
    B, R: TDataType;
    Op, K: Integer;
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
      if SclIsStr(Result) or SclIsStr(B) then
      begin
        // strings (a Char beside a String is one): compared on the string stack
        if B in [dtChar, dtWChar] then CharToStr
        else if Result in [dtChar, dtWChar] then
        begin
          // the Char came first: its string goes under the other one
          CharToStr;
          E(opStrOp, tcWord, dtString, soSwap);
        end
        else if not SclIsStr(Result) or not SclIsStr(B) then
          Fail(Format('cannot compare %s with %s', [DataTypeNames[Result], DataTypeNames[B]]));
        K := E(opStrOp, tcWord, dtBool, soCmp);
        FBlock.Ops[K].Ext := Op;
        Result := dtBool;
        Continue;
      end;
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
    VarT: TDataType;
    Vi: TVarInfo;
  begin
    IsTimer := R.Method[1] = 'T';
    // the type of the times (TON_LTIME: LTime) / of the count (CTU_DINT: DInt)
    VarT := dtNone;
    if R.IsBlock and (R.Info.Udt <> nil) then VarT := R.Info.Udt.IecVar
    else if FRes.ResolveVar(R.Text, Vi, Er) and (Vi.Udt <> nil) then VarT := Vi.Udt.IecVar;
    if VarT = dtNone then
    begin
      if IsTimer then VarT := dtTime else VarT := dtInt;
    end;
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
        if (Nm = 'PT') and (VarT = dtLTime) and not (T in [dtLTime, dtDInt, dtLInt]) then
          Fail('PT of ' + R.Text + ' must be an LTIME (LT#5S)');
        if (Nm = 'PT') and (VarT <> dtLTime) and not (T in [dtTime, dtDInt]) then Fail('PT must be a TIME (T#5S)');
        if (Nm = 'PV') and not SclIsInt(T) then Fail('PV must be an integer');
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
    if IsTimer then OpIx := E(opSTimer, tcFix, VarT, Ord(Code)) else OpIx := E(opSCounter, tcFix, VarT, Ord(Code));
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

  { R_TRIG / F_TRIG (CLK := .., Q => ..), RS (S := .., R1 := .., Q1 => ..), SR (S1 := .., R := .., Q1 => ..):
    the inputs are written into the instance, then the output and the edge memory M computed inline }
  procedure EdgeCall(const R: TRef; Line: Integer);
  var
    Ty, Nm, OutNm, Er: string;
    Ins: array of string;
    OutC: array of TOpChunk;
    OutRef: array of TRef;
    K, Ix, Pos0, NOut: Integer;
    T: TDataType;

    function Mem(const M: string): TOperand;
    begin
      if not FRes.Resolve(R.Text + '.' + M, Result, Er, False) then Fail(Er);
    end;

    procedure PushM(const M: string);
    var
      O: TOperand;
      I: Integer;
    begin
      // E may move the ops: the index first
      O := Mem(M);
      I := E(opSPush, tcBit, dtBool);
      FBlock.Ops[I].Opd := O;
    end;

    procedure StoreM(const M: string);
    var
      I: Integer;
      O: TOperand;
    begin
      O := Mem(M);
      I := E(opSStore, tcBit, dtBool);
      FBlock.Ops[I].Opd := O;
      SetMon(I, Line);
    end;

  begin
    if R.Indexed then Fail(R.Info.Udt.Name + ' in an array: a constant index is needed');
    Ty := UpperCase(R.Info.Udt.Name);
    case Ty of
      'R_TRIG', 'F_TRIG': begin Ins := ['CLK']; OutNm := 'Q'; end;
      'RS': begin Ins := ['S', 'R1']; OutNm := 'Q1'; end;
    else
      begin Ins := ['S1', 'R']; OutNm := 'Q1'; end;
    end;
    NOut := 0;
    Expect('(');
    while not IsSym(')') do
    begin
      if Tok.Kind <> stIdent then Fail('parameter name expected (CLK := ..)');
      Nm := UpperCase(Tok.S);
      Next;
      if IsSym(':=') then
      begin
        Next;
        Ix := -1;
        for K := 0 to High(Ins) do
          if Ins[K] = Nm then Ix := K;
        if Ix < 0 then Fail(Format('%s has no input %s', [Ty, Nm]));
        T := Expr;
        if T <> dtBool then Fail(Nm + ' must be BOOL');
        StoreM(Ins[Ix]);
      end
      else if IsSym('=>') then
      begin
        Next;
        if Nm <> OutNm then Fail(Format('%s has no output %s', [Ty, Nm]));
        Pos0 := Length(FBlock.Ops);
        SetLength(OutC, NOut + 1);
        SetLength(OutRef, NOut + 1);
        OutRef[NOut] := Path;
        OutC[NOut] := TakeChunk(Pos0);
        Inc(NOut);
      end
      else
        Fail(':= or => expected after ' + Nm);
      if IsSym(',') then Next else Break;
    end;
    Expect(')');
    case Ty of
      'R_TRIG', 'F_TRIG':
        begin
          // Q := CLK AND NOT M (R_TRIG) / NOT CLK AND M (F_TRIG); M := CLK
          PushM('CLK');
          if Ty = 'F_TRIG' then E(opSUn, tcBit, dtBool, suNot);
          PushM('M');
          if Ty = 'R_TRIG' then E(opSUn, tcBit, dtBool, suNot);
          E(opSBin, tcBit, dtBool, sbAnd);
          StoreM('Q');
          PushM('CLK');
          StoreM('M');
        end;
      'RS':
        begin
          // reset wins: Q1 := (S OR Q1) AND NOT R1
          PushM('S');
          PushM('Q1');
          E(opSBin, tcBit, dtBool, sbOr);
          PushM('R1');
          E(opSUn, tcBit, dtBool, suNot);
          E(opSBin, tcBit, dtBool, sbAnd);
          StoreM('Q1');
        end;
    else
      begin
        // set wins: Q1 := S1 OR (Q1 AND NOT R)
        PushM('Q1');
        PushM('R');
        E(opSUn, tcBit, dtBool, suNot);
        E(opSBin, tcBit, dtBool, sbAnd);
        PushM('S1');
        E(opSBin, tcBit, dtBool, sbOr);
        StoreM('Q1');
      end;
    end;
    for K := 0 to NOut - 1 do
    begin
      PutChunk(OutC[K]);
      PushM(OutNm);
      CheckAssign(OutRef[K].T, dtBool, OutRef[K].Text);
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
            if not IsBlockType(V) and not Act.IsBlock and (Act.T <> V.T) and not (SclIsStr(V.T) and SclIsStr(Act.T)) then
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
    if not FInline then FLine := Line;
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
        if not FInline then FLine := Tok.Line;
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
    if (Tok.Kind = stIdent) and SameText(Tok.S, '__RLO__') and FInline then
    begin
      // __RLO__ := Q of a box: the power out
      Next;
      Expect(':=');
      T := Expr;
      if T <> dtBool then Fail('the RLO is BOOL');
      E(opSRloSet, tcBit, dtBool);
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
    // a system FB: #t(IN := .., PT := ..) of a TON_TIME, #c(CU := ..) of a CTU_INT ...
    if IsSym('(') and R.IsBlock and not R.Info.IsArray and (R.Info.T in [dtIECTimer, dtIECCounter]) then
    begin
      R.Method := SysFbMethod(R.Info.TypeText);
      if R.Method = '' then
        Fail(Format('%s is an %s: call it as %s.%s(..)', [R.Text, DataTypeNames[R.Info.T], R.Text,
          IfThen(R.Info.T = dtIECTimer, 'TON', 'CTU')]));
      TimerCall(R, Line);
      EndStmt;
      Exit;
    end;
    // R_TRIG / F_TRIG / RS / SR
    if IsSym('(') and R.IsBlock and not R.Info.IsArray and (R.Info.T = dtStruct) and IsSysFb(R.Info.Udt) then
    begin
      EdgeCall(R, Line);
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
    if SclIsStr(R.T) and (T in [dtChar, dtWChar]) then CharToStr;
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

  { VAR CONSTANT  name : Type := value;  the value: a number, a typed literal, TRUE / FALSE, 'c' }
  procedure ConstDecl(const Nm: string; T: TDataType);
  var
    Neg: Boolean;
    V: Double;
    Iv: Int64;
    Vt: TDataType;
    C: TConst;
    K: Integer;
  begin
    if not IsSym(':=') then Fail('VAR CONSTANT: ' + Nm + ' := value expected');
    Next;
    Iv := 0;
    Neg := IsSym('-');
    if Neg then Next;
    case Tok.Kind of
      stNum:
        if (Pos('.', Tok.S) > 0) or (Pos('E', UpperCase(Tok.S)) > 0) then
        begin
          if not StrToFloatDot(Tok.S, V) then Fail('bad number ' + Tok.S);
          Vt := dtReal;
        end
        else
        begin
          if not TryStrToInt64(Tok.S, Iv) then Iv := Int64(StrToQWordDef(Tok.S, 0));
          V := Iv;
          if V > 4294967295.0 then Vt := dtLInt
          else if V > 2147483647 then Vt := dtUDInt
          else Vt := dtDInt;
        end;
      stTyped:
        if ParseConst(Tok.S, C) then
        begin
          case C.Kind of
            ckTime: begin V := C.I; Vt := dtTime; end;
            ckS5Time: begin V := C.Bits; Vt := dtS5Time; end;
            ckReal: begin V := C.R; Vt := dtReal; end;
            ckHex:
              begin
                V := C.I;
                case C.Size of
                  osByte: Vt := dtByte;
                  osWord: Vt := dtWord;
                else
                  Vt := dtDWord;
                end;
              end;
          else
            begin V := C.I; Vt := dtDInt; end;
          end;
        end
        else if not SclTypedLiteralEx(Tok.S, V, Iv, Vt) then
          Fail('bad constant ' + Tok.S);
      stStr:
        begin
          if Length(Tok.S) <> 1 then Fail('only CHAR constants (one letter) are supported');
          V := Ord(Tok.S[1]);
          Vt := dtChar;
        end;
      stIdent:
        if SameText(Tok.S, 'TRUE') or SameText(Tok.S, 'FALSE') then
        begin
          V := Ord(SameText(Tok.S, 'TRUE'));
          Vt := dtBool;
        end
        else
          Fail('VAR CONSTANT: a constant value expected, found ' + Tok.S);
    else
      Fail('VAR CONSTANT: a constant value expected, found "' + Tok.S + '"');
    end;
    Next;
    if not (Vt in Int64Types) and not (Tok.Kind = stNum) then Iv := Round(V);
    if Neg then
    begin
      if not SclIsNum(Vt) then Fail('- needs a number');
      V := -V;
      Iv := -Iv;
    end;
    if (T in Int64Types) and not (Vt in Int64Types) then Iv := Round(V);
    CheckAssign(T, Vt, '#' + Nm);
    K := Length(FConstV);
    SetLength(FConstV, K + 1);
    SetLength(FConstI, K + 1);
    SetLength(FConstT, K + 1);
    FConstV[K] := V;
    FConstI[K] := Iv;
    FConstT[K] := T;
    FConsts.AddObject(UpperCase(Nm), TObject(PtrInt(K)));
  end;

  procedure TempDecl;
  var
    Nm, Ty: string;
    T: TDataType;
    Lo, Hi, Sz, Ofs: Integer;
    U: TDataBlock;
    IsConst: Boolean;
  begin
    // VAR_TEMP  name : Type;  ...  END_VAR      VAR CONSTANT  name : Type := value;  ...  END_VAR
    Next;
    IsConst := IsKw('CONSTANT');
    if IsConst then Next;
    while not IsKw('END_VAR') and (Tok.Kind <> stEOF) do
    begin
      if not FInline then FLine := Tok.Line;
      try
        if Tok.Kind <> stIdent then Fail('VAR_TEMP: name expected');
        Nm := Tok.S;
        Next;
        Expect(':');
        Ty := '';
        while not IsSym(';') and not IsSym(':=') and (Tok.Kind <> stEOF) and not IsKw('END_VAR') do
        begin
          // Array[0..3] of "Type": tokens glued again, OF kept apart
          if (Tok.Kind = stIdent) and SameText(Tok.S, 'OF') then Ty := Ty + ' of '
          else if Tok.Kind = stQuoted then Ty := Ty + '"' + Tok.S + '"'
          else Ty := Ty + Tok.S;
          Next;
        end;
        if not FProject.ParseVarType(Ty, T, Lo, Hi, U) then Fail('unknown data type ' + Ty);
        if (FTemps.IndexOfName(UpperCase(Nm)) >= 0) or (FConsts.IndexOf(UpperCase(Nm)) >= 0) then
          Fail('#' + Nm + ' is declared twice');
        if IsConst then
        begin
          if (Hi >= Lo) or not (T in [dtBool, dtByte, dtWord, dtDWord, dtChar, dtSInt, dtUSInt, dtInt, dtUInt, dtDInt,
            dtUDInt, dtReal, dtTime, dtS5Time, dtDate, dtTOD, dtWChar, dtLWord, dtLInt, dtULInt, dtLReal, dtLTime,
            dtLTOD, dtLDT, dtDT]) then
            Fail('VAR CONSTANT: an elementary data type expected');
          ConstDecl(Nm, T);
          if IsSym(';') then Next else Fail('";" expected');
          Continue;
        end;
        if IsSym(':=') then Fail('VAR_TEMP: no start value (the local data is not kept)');
        if T in [dtIECTimer, dtIECCounter] then Fail('timers / counters need a DB (they keep their state)');
        if (T = dtStruct) and IsSysFb(U) then Fail(U.Name + ' needs a DB (it keeps its state)');
        if U <> nil then U.Layout;
        if Hi >= Lo then
        begin
          // an array: on an even byte, Bool elements packed into bits
          if T = dtBool then Sz := (Hi - Lo + 1 + 7) div 8
          else Sz := (Hi - Lo + 1) * ElemStride(T, U);
          Sz := (Sz + 1) div 2 * 2;
        end
        else if (T = dtStruct) or SclIsStr(T) then
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
    if not FInline then FLine := Tok.Line;
    if IsKw('END_VAR') then Next else Msg('END_VAR missing');
    if IsSym(';') then Next;
  end;

begin
  Base := FBlock.Nets[FNet].MonBase;
  LoopDepth := 0;
  CaseDepth := 0;
  MuxDepth := 0;
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
      if not FInline then FLine := Tok.Line;
      Msg(Format('unexpected "%s"', [Tok.S]));
      Next;
    end;
    if ErrCount > 20 then Break;
  end;
  if not FInline then FLine := -1;
end;
