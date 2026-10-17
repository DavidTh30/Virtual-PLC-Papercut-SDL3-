unit uPlcServer;

{ The simulated communication ports of the virtual CPU.

  S7 communication (ISO-on-TCP, RFC 1006, TCP 102), the protocol of STEP 7,
  WinCC, HMI panels, snap7, Node-RED S7 nodes ...:
    TPKT  03 00 len(2)
    COTP  CR / CC (connect: the destination TSAP holds rack * 32 + slot; the
          CPU only answers on its own slot: S7-300 slot 2, S7-400 slot 3,
          S7-1200 slot 0 or 1) and DT (data)
    S7    0x32 header; Setup communication (PDU size, max 480 bytes),
          Read Var / Write Var (areas I Q M DB T C; bit, byte, word, dword,
          int, dint, real, counter, timer), PLC Stop / PI service start,
          user data: read SZL 0x0011 (order code), 0x001C (identification),
          0x0424 (operating mode)
    S7-1200: PUT/GET must be permitted (CPU property), optimized DBs refuse
    absolute access - as on the real CPU.
  Modbus TCP server (TCP 502):
    coils = Q (coil n = Q n/8 . n mod 8), discrete inputs = I, input registers
    = IW (register n = IW 2n), holding registers = MW 2n or DBx.DBW 2n;
    function codes 1 2 3 4 5 6 15 16, exceptions 1 2 3.

  Every request goes to the PLC thread and is served at the cycle check
  point (TPlcRuntime.AreaIO), so values are consistent within a cycle.
  One thread per listener, one per connection. A traffic log and per
  connection counters feed the Ports screen and the port LEDs. }

{$mode objfpc}{$H+}

interface

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  Classes, SysUtils, Math, SyncObjs, sockets, uPlcTypes, uPlcProject, uPlcRuntime;

type
  TProto = (prS7, prModbus);

  TConnRow = record
    Id: Integer;
    Proto: TProto;
    Peer, Info: string;
    Since: TDateTime;
    Requests, BytesIn, BytesOut: Int64;
    Active: Boolean;
  end;
  TConnRows = array of TConnRow;

  TLogRow = record
    Time: TDateTime;
    Proto: TProto;
    Peer, Text: string;
    Ok: Boolean;
  end;
  TLogRows = array of TLogRow;

  TCommHub = class;

  { TListenThread }

  TListenThread = class(TThread)
  private
    FHub: TCommHub;
    FProto: TProto;
    FSock: LongInt;
  protected
    procedure Execute; override;
  public
    constructor Create(AHub: TCommHub; AProto: TProto; ASock: LongInt);
    procedure Shut;
  end;

  { TClientThread }

  TClientThread = class(TThread)
  private
    FHub: TCommHub;
    FProto: TProto;
    FSock: LongInt;
    FId: Integer;
    FPeer: string;
    FPdu: Integer;
    FConnected: Boolean;
    function RecvExact(var Buf; N: Integer): Boolean;
    function SendAll(const Buf: array of Byte): Boolean;
    procedure ServeS7;
    procedure ServeModbus;
    function S7Job(const P: array of Byte; out R: TBytes): Boolean;
  protected
    procedure Execute; override;
  public
    constructor Create(AHub: TCommHub; AProto: TProto; ASock: LongInt; const APeer: string);
    procedure Shut;
  end;

  { TCommHub }

  TCommHub = class
  private
    FRt: TPlcRuntime;
    FLock: TCriticalSection;
    FListen: array[TProto] of TListenThread;
    FPortNow: array[TProto] of Integer;
    FIpNow: array[TProto] of string;
    FClients: TList;
    FConns: TConnRows;
    FNextId: Integer;
    FLog: TLogRows;
    FLogPos, FLogCount: Integer;
    procedure StartProto(P: TProto; APort: Integer; const AIp: string);
    procedure StopProto(P: TProto);
    function AddConn(P: TProto; const APeer: string): Integer;
    procedure ConnUpdate(Id: Integer; DReq, DIn, DOut: Int64; const AInfo: string; AActive: Boolean);
  public
    Settings: TCommSettings;
    Family: TCpuFamily;
    StationName, ModuleName, OrderNo, Firmware: string;
    Status: array[TProto] of string;
    Listening: array[TProto] of Boolean;
    LastRxMs, LastTxMs: Double;
    Requests: Int64;
    constructor Create(ARt: TPlcRuntime);
    destructor Destroy; override;
    { (re)starts the listeners that changed; main thread }
    procedure Apply(const S: TCommSettings; const AModel: TCpuModel; const AStation: string);
    procedure StopAll;
    procedure Cleanup;
    procedure Log(P: TProto; const APeer, AText: string; AOk: Boolean = True);
    function ConnCopy: TConnRows;
    function LogCopy(MaxN: Integer): TLogRows;
    function ActiveCount: Integer;
    function ExpectedSlots: string;
    function SlotOk(Rack, Slot: Integer): Boolean;
    property Rt: TPlcRuntime read FRt;
  end;

const
  ProtoNames: array[TProto] of string = ('S7', 'Modbus');

function AreaName(A: TArea): string;

implementation

const
  WSAETIMEDOUT = 10060;

function AreaName(A: TArea): string;
begin
  case A of
    arI: Result := 'I';
    arQ: Result := 'Q';
    arM: Result := 'M';
    arDB: Result := 'DB';
    arT: Result := 'T';
    arC: Result := 'C';
  else
    Result := '?';
  end;
end;

procedure PutW(var B: TBytes; Ofs: Integer; V: Integer); inline;
begin
  B[Ofs] := (V shr 8) and $FF;
  B[Ofs + 1] := V and $FF;
end;

function GetW(const B: array of Byte; Ofs: Integer): Integer; inline;
begin
  Result := (B[Ofs] shl 8) or B[Ofs + 1];
end;

procedure Append(var B: TBytes; const X: array of Byte);
var
  N: Integer;
begin
  if Length(X) = 0 then Exit;
  N := Length(B);
  SetLength(B, N + Length(X));
  Move(X[0], B[N], Length(X));
end;

{ ====================================================================== }
{ TCommHub                                                               }
{ ====================================================================== }

constructor TCommHub.Create(ARt: TPlcRuntime);
var
  P: TProto;
begin
  inherited Create;
  FRt := ARt;
  FLock := TCriticalSection.Create;
  FClients := TList.Create;
  SetLength(FLog, 400);
  for P := Low(TProto) to High(TProto) do Status[P] := 'off';
end;

destructor TCommHub.Destroy;
begin
  StopAll;
  Cleanup;
  FClients.Free;
  FLock.Free;
  inherited Destroy;
end;

function TCommHub.ExpectedSlots: string;
begin
  case Family of
    cfS7300: Result := 'rack 0, slot 2';
    cfS7400: Result := 'rack 0, slot 3';
  else
    Result := 'rack 0, slot 1 (or 0)';
  end;
end;

function TCommHub.SlotOk(Rack, Slot: Integer): Boolean;
begin
  if Rack <> 0 then Exit(False);
  case Family of
    cfS7300: Result := Slot = 2;
    cfS7400: Result := Slot = 3;
  else
    Result := Slot in [0, 1];
  end;
end;

procedure TCommHub.Log(P: TProto; const APeer, AText: string; AOk: Boolean);
begin
  FLock.Enter;
  try
    FLog[FLogPos].Time := Now;
    FLog[FLogPos].Proto := P;
    FLog[FLogPos].Peer := APeer;
    FLog[FLogPos].Text := AText;
    FLog[FLogPos].Ok := AOk;
    FLogPos := (FLogPos + 1) mod Length(FLog);
    if FLogCount < Length(FLog) then Inc(FLogCount);
  finally
    FLock.Leave;
  end;
end;

function TCommHub.LogCopy(MaxN: Integer): TLogRows;
var
  K, N, I: Integer;
begin
  FLock.Enter;
  try
    N := Min(MaxN, FLogCount);
    SetLength(Result, N);
    for K := 0 to N - 1 do
    begin
      I := (FLogPos - 1 - K + Length(FLog) * 2) mod Length(FLog);
      Result[K] := FLog[I];   // newest first
    end;
  finally
    FLock.Leave;
  end;
end;

function TCommHub.AddConn(P: TProto; const APeer: string): Integer;
var
  N: Integer;
begin
  FLock.Enter;
  try
    Inc(FNextId);
    Result := FNextId;
    // keep the last 32 connections (finished ones drop out first)
    if Length(FConns) >= 32 then
    begin
      for N := 0 to High(FConns) do
        if not FConns[N].Active then
        begin
          Delete(FConns, N, 1);
          Break;
        end;
    end;
    N := Length(FConns);
    SetLength(FConns, N + 1);
    FConns[N].Id := Result;
    FConns[N].Proto := P;
    FConns[N].Peer := APeer;
    FConns[N].Since := Now;
    FConns[N].Requests := 0;
    FConns[N].BytesIn := 0;
    FConns[N].BytesOut := 0;
    FConns[N].Info := '';
    FConns[N].Active := True;
  finally
    FLock.Leave;
  end;
end;

procedure TCommHub.ConnUpdate(Id: Integer; DReq, DIn, DOut: Int64; const AInfo: string; AActive: Boolean);
var
  K: Integer;
begin
  FLock.Enter;
  try
    for K := 0 to High(FConns) do
      if FConns[K].Id = Id then
      begin
        Inc(FConns[K].Requests, DReq);
        Inc(FConns[K].BytesIn, DIn);
        Inc(FConns[K].BytesOut, DOut);
        if AInfo <> '' then FConns[K].Info := AInfo;
        FConns[K].Active := AActive;
      end;
    Inc(Requests, DReq);
  finally
    FLock.Leave;
  end;
end;

function TCommHub.ConnCopy: TConnRows;
begin
  FLock.Enter;
  try
    Result := Copy(FConns);
  finally
    FLock.Leave;
  end;
end;

function TCommHub.ActiveCount: Integer;
var
  K: Integer;
begin
  Result := 0;
  FLock.Enter;
  try
    for K := 0 to High(FConns) do
      if FConns[K].Active then Inc(Result);
  finally
    FLock.Leave;
  end;
end;

procedure TCommHub.StartProto(P: TProto; APort: Integer; const AIp: string);
var
  S: LongInt;
  A: TInetSockAddr;
  One: LongInt;
begin
  StopProto(P);
  S := fpSocket(AF_INET, SOCK_STREAM, 0);
  if S < 0 then
  begin
    Status[P] := 'socket error ' + IntToStr(SocketError);
    Exit;
  end;
  // the port belongs to us alone (no second server on it by accident)
  One := 1;
  fpSetSockOpt(S, SOL_SOCKET, LongInt($FFFFFFFB) {SO_EXCLUSIVEADDRUSE}, @One, SizeOf(One));
  FillChar(A, SizeOf(A), 0);
  A.sin_family := AF_INET;
  A.sin_port := htons(APort);
  if AIp = '0.0.0.0' then A.sin_addr.s_addr := 0 else A.sin_addr := StrToNetAddr(AIp);
  if fpBind(S, @A, SizeOf(A)) <> 0 then
  begin
    FIpNow[P] := AIp;
    if (AIp <> '127.0.0.1') and (AIp <> '0.0.0.0') and (SocketError = 10049) then
      Status[P] := Format('%s is not an address of this PC (error %d)', [AIp, SocketError])
    else
      Status[P] := Format('port %d in use or not allowed (error %d)', [APort, SocketError]);
    CloseSocket(S);
    Log(P, '', Status[P], False);
    Exit;
  end;
  if fpListen(S, 8) <> 0 then
  begin
    Status[P] := Format('listen failed (error %d)', [SocketError]);
    CloseSocket(S);
    Exit;
  end;
  FListen[P] := TListenThread.Create(Self, P, S);
  FPortNow[P] := APort;
  FIpNow[P] := AIp;
  Listening[P] := True;
  if AIp = '0.0.0.0' then Status[P] := Format('listening on all interfaces, TCP %d', [APort])
  else Status[P] := Format('listening on %s, TCP %d', [AIp, APort]);
  Log(P, '', Status[P]);
end;

procedure TCommHub.StopProto(P: TProto);
var
  K: Integer;
  C: TClientThread;
begin
  if FListen[P] <> nil then
  begin
    FListen[P].Shut;
    FListen[P].WaitFor;
    FreeAndNil(FListen[P]);
    Log(P, '', 'server stopped');
  end;
  Listening[P] := False;
  FPortNow[P] := 0;
  Status[P] := 'off';
  // its connections end too
  FLock.Enter;
  try
    for K := 0 to FClients.Count - 1 do
    begin
      C := TClientThread(FClients[K]);
      if C.FProto = P then C.Shut;
    end;
  finally
    FLock.Leave;
  end;
end;

procedure TCommHub.Apply(const S: TCommSettings; const AModel: TCpuModel; const AStation: string);
begin
  Family := AModel.Family;
  ModuleName := AModel.Name;
  OrderNo := AModel.OrderNo;
  Firmware := AModel.Firmware;
  StationName := AStation;
  Settings := S;
  if S.S7On then
  begin
    if not Listening[prS7] or (FPortNow[prS7] <> S.S7Port) or (FIpNow[prS7] <> CommIp(S)) then
      StartProto(prS7, S.S7Port, CommIp(S));
  end
  else if Listening[prS7] then StopProto(prS7);
  if S.MbOn then
  begin
    if not Listening[prModbus] or (FPortNow[prModbus] <> S.MbPort) or (FIpNow[prModbus] <> CommIp(S)) then
      StartProto(prModbus, S.MbPort, CommIp(S));
  end
  else if Listening[prModbus] then StopProto(prModbus);
  Cleanup;
end;

procedure TCommHub.StopAll;
var
  P: TProto;
  K: Integer;
  L: TList;
begin
  for P := Low(TProto) to High(TProto) do StopProto(P);
  FLock.Enter;
  try
    L := TList.Create;
    L.Assign(FClients);
  finally
    FLock.Leave;
  end;
  try
    for K := 0 to L.Count - 1 do TClientThread(L[K]).Shut;
    for K := 0 to L.Count - 1 do TClientThread(L[K]).WaitFor;
  finally
    L.Free;
  end;
end;

{ frees the threads of finished connections; main thread }
procedure TCommHub.Cleanup;
var
  K: Integer;
  C: TClientThread;
  Done: TList;
begin
  Done := TList.Create;
  try
    FLock.Enter;
    try
      for K := FClients.Count - 1 downto 0 do
      begin
        C := TClientThread(FClients[K]);
        if C.Finished then
        begin
          Done.Add(C);
          FClients.Delete(K);
        end;
      end;
    finally
      FLock.Leave;
    end;
    for K := 0 to Done.Count - 1 do
    begin
      TClientThread(Done[K]).WaitFor;
      TClientThread(Done[K]).Free;
    end;
  finally
    Done.Free;
  end;
end;

{ ====================================================================== }
{ listener                                                               }
{ ====================================================================== }

constructor TListenThread.Create(AHub: TCommHub; AProto: TProto; ASock: LongInt);
begin
  FHub := AHub;
  FProto := AProto;
  FSock := ASock;
  FreeOnTerminate := False;
  inherited Create(False);
end;

procedure TListenThread.Shut;
begin
  Terminate;
  // accept() returns as soon as the socket is closed
  CloseSocket(FSock);
end;

procedure TListenThread.Execute;
var
  A: TInetSockAddr;
  L: TSockLen;
  C: LongInt;
  Peer: string;
  T: TClientThread;
begin
  while not Terminated do
  begin
    L := SizeOf(A);
    C := fpAccept(FSock, @A, @L);
    if Terminated then
    begin
      if C >= 0 then CloseSocket(C);
      Break;
    end;
    if C < 0 then
    begin
      Sleep(20);
      Continue;
    end;
    Peer := NetAddrToStr(A.sin_addr) + ':' + IntToStr(ntohs(A.sin_port));
    if FHub.ActiveCount >= 16 then
    begin
      FHub.Log(FProto, Peer, 'refused: too many connections (16)', False);
      CloseSocket(C);
      Continue;
    end;
    T := TClientThread.Create(FHub, FProto, C, Peer);
    FHub.FLock.Enter;
    try
      FHub.FClients.Add(T);
    finally
      FHub.FLock.Leave;
    end;
    T.Start;
  end;
end;

{ ====================================================================== }
{ connection                                                             }
{ ====================================================================== }

constructor TClientThread.Create(AHub: TCommHub; AProto: TProto; ASock: LongInt; const APeer: string);
begin
  FHub := AHub;
  FProto := AProto;
  FSock := ASock;
  FPeer := APeer;
  FPdu := 240;
  FreeOnTerminate := False;
  inherited Create(True);
end;

procedure TClientThread.Shut;
begin
  Terminate;
  fpShutdown(FSock, 2);
end;

function TClientThread.RecvExact(var Buf; N: Integer): Boolean;
var
  Got, R: Integer;
  P: PByte;
begin
  Result := False;
  P := @Buf;
  Got := 0;
  while Got < N do
  begin
    R := fpRecv(FSock, P + Got, N - Got, 0);
    if R > 0 then
    begin
      Inc(Got, R);
      Continue;
    end;
    if R = 0 then Exit;   // closed by the partner
    if (SocketError = WSAETIMEDOUT) and not Terminated then Continue;
    Exit;
  end;
  FHub.LastRxMs := PlcNowMs;
  FHub.ConnUpdate(FId, 0, N, 0, '', True);
  Result := True;
end;

function TClientThread.SendAll(const Buf: array of Byte): Boolean;
var
  Sent, R: Integer;
begin
  Result := False;
  Sent := 0;
  while Sent < Length(Buf) do
  begin
    R := fpSend(FSock, @Buf[Sent], Length(Buf) - Sent, 0);
    if R <= 0 then Exit;
    Inc(Sent, R);
  end;
  FHub.LastTxMs := PlcNowMs;
  FHub.ConnUpdate(FId, 0, 0, Length(Buf), '', True);
  Result := True;
end;

procedure TClientThread.Execute;
var
  Ms: LongInt;
  One: LongInt;
begin
  FId := FHub.AddConn(FProto, FPeer);
  Ms := 500;
  fpSetSockOpt(FSock, SOL_SOCKET, SO_RCVTIMEO, @Ms, SizeOf(Ms));
  One := 1;
  fpSetSockOpt(FSock, IPPROTO_TCP, TCP_NODELAY, @One, SizeOf(One));
  FHub.Log(FProto, FPeer, 'connection opened');
  try
    if FProto = prS7 then ServeS7 else ServeModbus;
  except
    on E: Exception do FHub.Log(FProto, FPeer, 'error: ' + E.Message, False);
  end;
  CloseSocket(FSock);
  FHub.ConnUpdate(FId, 0, 0, 0, '', False);
  FHub.Log(FProto, FPeer, 'connection closed');
end;

{ ---------- S7 communication ---------- }

const
  TsBit = $01; TsByte = $02; TsChar = $03; TsWord = $04; TsInt = $05; TsDWord = $06; TsDInt = $07;
  TsReal = $08; TsCounter = $1C; TsTimer = $1D;

function TsSize(Ts: Integer): Integer;
begin
  case Ts of
    TsBit, TsByte, TsChar: Result := 1;
    TsWord, TsInt, TsCounter, TsTimer: Result := 2;
    TsDWord, TsDInt, TsReal: Result := 4;
  else
    Result := 0;
  end;
end;

function S7Area(Code: Integer; out A: TArea): Boolean;
begin
  Result := True;
  case Code of
    $81: A := arI;
    $82: A := arQ;
    $83: A := arM;
    $84: A := arDB;
    $1C: A := arC;
    $1D: A := arT;
  else
    Result := False;
  end;
end;

function ItemText(A: TArea; DB, Addr, Ts, Count: Integer): string;
const
  Sz: array[0..3] of string = ('B', 'W', 'D', 'X');
var
  Ofs: Integer;
begin
  if A in [arT, arC] then Exit(Format('%s%d x%d', [AreaName(A), Addr, Count]));
  Ofs := Addr shr 3;
  if Ts = TsBit then
  begin
    if A = arDB then Result := Format('DB%d.DBX%d.%d', [DB, Ofs, Addr and 7])
    else Result := Format('%s%d.%d', [AreaName(A), Ofs, Addr and 7]);
    Exit;
  end;
  if A = arDB then Result := Format('DB%d.DBB%d', [DB, Ofs]) else Result := Format('%sB%d', [AreaName(A), Ofs]);
  Result := Result + Format(' x%d', [Count * TsSize(Ts)]);
end;

function ResCode(R: TAreaResult): Byte;
begin
  case R of
    arOk: Result := $FF;
    arNoObject: Result := $0A;
    arOutOfRange: Result := $05;
    arNotAllowed: Result := $03;
  else
    Result := $06;
  end;
end;

{ an S7 job / user data PDU -> the answer (False: send nothing) }
function TClientThread.S7Job(const P: array of Byte; out R: TBytes): Boolean;
var
  Ros, Ref, PLen, DLen, Func, Cnt, K, Ip, Ts, Len, DB, AreaC, Addr, NBytes, DPos, DTs, DLenI: Integer;
  A: TArea;
  Req: TAreaReq;
  Head, Par, Dat: TBytes;
  Txt, Desc: string;
  Allowed, IsBitsLen: Boolean;
  SzlId, SzlIdx, Seq: Integer;
  Rec: TBytes;
  St: Byte;
  S: string;

  procedure Ack(ErrCls, ErrCode: Integer);
  begin
    // ack_data header (12 bytes) + parameters + data
    SetLength(Head, 12);
    Head[0] := $32;
    Head[1] := 3;
    Head[2] := 0;
    Head[3] := 0;
    PutW(Head, 4, Ref);
    PutW(Head, 6, Length(Par));
    PutW(Head, 8, Length(Dat));
    Head[10] := ErrCls;
    Head[11] := ErrCode;
    R := Head;
    Append(R, Par);
    Append(R, Dat);
  end;

  procedure UserAck;
  begin
    SetLength(Head, 10);
    Head[0] := $32;
    Head[1] := 7;
    Head[2] := 0;
    Head[3] := 0;
    PutW(Head, 4, Ref);
    PutW(Head, 6, Length(Par));
    PutW(Head, 8, Length(Dat));
    R := Head;
    Append(R, Par);
    Append(R, Dat);
  end;

  procedure AddStr(var B: TBytes; const Str: string; N: Integer);
  var
    I: Integer;
    X: TBytes;
  begin
    SetLength(X, N);
    for I := 0 to N - 1 do
      if I < Length(Str) then X[I] := Ord(Str[I + 1]) else X[I] := Ord(' ');
    Append(B, X);
  end;

  function Fw(Part: Integer): Integer;
  var
    T: string;
    L: TStringList;
  begin
    // 'V3.2' -> 3, 2, 0
    T := StringReplace(FHub.Firmware, 'V', '', []);
    L := TStringList.Create;
    try
      L.Delimiter := '.';
      L.DelimitedText := T;
      if Part < L.Count then Result := StrToIntDef(L[Part], 0) else Result := 0;
    finally
      L.Free;
    end;
  end;

begin
  Result := False;
  SetLength(R, 0);
  SetLength(Par, 0);
  SetLength(Dat, 0);
  if (Length(P) < 10) or (P[0] <> $32) then Exit;
  Ros := P[1];
  Ref := GetW(P, 4);
  PLen := GetW(P, 6);
  DLen := GetW(P, 8);
  if Length(P) < 10 + PLen + DLen then Exit;
  Allowed := not IsTia(FHub.Family) or FHub.Settings.PutGet;

  // ---------- user data: read SZL ----------
  if Ros = 7 then
  begin
    Ip := 10;
    Seq := 0;
    if PLen >= 8 then Seq := P[Ip + 7];
    if (PLen >= 8) and ((P[Ip + 5] and $0F) = 4) and (P[Ip + 6] = 1) and (DLen >= 8) then
    begin
      DPos := 10 + PLen;
      SzlId := GetW(P, DPos + 4);
      SzlIdx := GetW(P, DPos + 6);
      SetLength(Rec, 0);
      case SzlId of
        $0011, $0111:
          begin
            // module identification: MLFB of the CPU, hardware, firmware
            S := FHub.OrderNo;
            Append(Rec, [0, 1]);
            AddStr(Rec, S, 20);
            Append(Rec, [0, 0, 0, 1, 0, 1]);
            Append(Rec, [0, 6]);
            AddStr(Rec, S, 20);
            Append(Rec, [0, 0, 0, 1, 0, 1]);
            Append(Rec, [0, 7]);
            AddStr(Rec, '', 20);
            Append(Rec, [0, 0, Ord('V'), Fw(0), Fw(1), Fw(2)]);
            SetLength(Dat, 0);
            Append(Dat, [$FF, 9, 0, 0, SzlId shr 8, SzlId and $FF, SzlIdx shr 8, SzlIdx and $FF, 0, 28, 0, 3]);
            Append(Dat, Rec);
            Desc := 'read SZL 0x0011 (order code)';
          end;
        $001C:
          begin
            // component identification: station, module, plant, copyright, serial, module type
            for K := 1 to 7 do
            begin
              if K = 6 then Continue;
              Append(Rec, [0, K]);
              case K of
                1: AddStr(Rec, FHub.StationName, 32);
                2: AddStr(Rec, FHub.ModuleName, 32);
                3: AddStr(Rec, 'Virtual PLC', 32);
                4: AddStr(Rec, 'Virtual PLC (simulated CPU)', 32);
                5: AddStr(Rec, 'VPLC-0000001', 32);
              else
                AddStr(Rec, FHub.ModuleName, 32);
              end;
            end;
            SetLength(Dat, 0);
            Append(Dat, [$FF, 9, 0, 0, 0, $1C, SzlIdx shr 8, SzlIdx and $FF, 0, 34, 0, 6]);
            Append(Dat, Rec);
            Desc := 'read SZL 0x001C (identification)';
          end;
        $0424:
          begin
            // operating mode: 0x08 RUN, 0x04 STOP (snap7 Cli_GetPlcStatus)
            if FHub.Rt.Mode = rmRun then St := $08 else St := $04;
            SetLength(Dat, 0);
            Append(Dat, [$FF, 9, 0, 0, 4, $24, SzlIdx shr 8, SzlIdx and $FF, 0, 20, 0, 1,
              $51, $44, $FF, St, 0, 0, 0, 0, 0, 0, 0, 0, $14, $08, $20, $12, $05, $28, $34, $94]);
            if St = 8 then Desc := 'read SZL 0x0424 (mode RUN)' else Desc := 'read SZL 0x0424 (mode STOP)';
          end;
      else
        begin
          SetLength(Dat, 0);
          Append(Dat, [$0A, 0, 0, 0]);
          Desc := Format('read SZL 0x%.4x: not supported', [SzlId]);
        end;
      end;
      if Length(Dat) >= 4 then PutW(Dat, 2, Length(Dat) - 4);
      if Dat[0] = $0A then PutW(Dat, 2, 0);
      SetLength(Par, 0);
      Append(Par, [0, 1, $12, 8, $12, $84, 1, Seq, 0, 0, 0, 0]);
      if Dat[0] = $0A then begin Par[10] := $D4; Par[11] := $01; end;
      UserAck;
      FHub.Log(prS7, FPeer, Desc, Dat[0] <> $0A);
      Exit(True);
    end;
    SetLength(Par, 0);
    Append(Par, [0, 1, $12, 8, $12, $80 or (P[Ip + 5] and $0F), P[Ip + 6], Seq, 0, 0, $81, $04]);
    SetLength(Dat, 0);
    Append(Dat, [$0A, 0, 0, 0]);
    UserAck;
    FHub.Log(prS7, FPeer, 'user data function not supported', False);
    Exit(True);
  end;
  if Ros <> 1 then Exit;
  Func := P[10];
  case Func of
    $F0:
      begin
        // setup communication: the PDU size is the smaller of both
        if PLen >= 8 then FPdu := EnsureRange(GetW(P, 16), 240, 480) else FPdu := 240;
        SetLength(Par, 8);
        Par[0] := $F0;
        Par[1] := 0;
        Par[2] := P[12];
        Par[3] := P[13];
        Par[4] := P[14];
        Par[5] := P[15];
        PutW(Par, 6, FPdu);
        Ack(0, 0);
        FHub.Log(prS7, FPeer, Format('setup communication, PDU %d bytes', [FPdu]));
        FHub.ConnUpdate(FId, 0, 0, 0, Format('S7, PDU %d', [FPdu]), True);
        Exit(True);
      end;
    $04, $05:
      begin
        if not Allowed then
        begin
          SetLength(Par, 2);
          Par[0] := Func;
          Par[1] := 0;
          Ack($81, $04);
          FHub.Log(prS7, FPeer, 'refused: PUT/GET access is not permitted on this S7-1200', False);
          Exit(True);
        end;
        Cnt := P[11];
        SetLength(Par, 2);
        Par[0] := Func;
        Par[1] := Cnt;
        SetLength(Dat, 0);
        Ip := 12;
        DPos := 10 + PLen;
        Txt := '';
        for K := 0 to Cnt - 1 do
        begin
          if (Ip + 12 > 10 + PLen) or (P[Ip] <> $12) then Break;
          Ts := P[Ip + 3];
          Len := GetW(P, Ip + 4);
          DB := GetW(P, Ip + 6);
          AreaC := P[Ip + 8];
          Addr := (P[Ip + 9] shl 16) or (P[Ip + 10] shl 8) or P[Ip + 11];
          Inc(Ip, 12);
          FillChar(Req, SizeOf(Req), 0);
          Req.Res := arOk;
          if not S7Area(AreaC, A) then Req.Res := arNoObject
          else if TsSize(Ts) = 0 then Req.Res := arTypeNotSupported
          else
          begin
            Req.Area := A;
            Req.DB := DB;
            if A in [arT, arC] then
            begin
              Req.Ofs := Addr;
              Req.Len := Len;
            end
            else if Ts = TsBit then
            begin
              Req.Bits := True;
              Req.Ofs := Addr;
              Req.Len := 1;
            end
            else
            begin
              Req.Ofs := Addr shr 3;
              Req.Len := Len * TsSize(Ts);
            end;
          end;
          if Txt <> '' then Txt := Txt + ', ';
          if S7Area(AreaC, A) then Txt := Txt + ItemText(A, DB, Addr, Ts, Len) else Txt := Txt + Format('area 0x%.2x', [AreaC]);
          if Func = $05 then
          begin
            // the data of this item
            if DPos + 4 > Length(P) then Break;
            DTs := P[DPos + 1];
            DLenI := GetW(P, DPos + 2);
            IsBitsLen := DTs in [3, 4, 5];
            if IsBitsLen and (DTs <> 3) then NBytes := DLenI div 8
            else if DTs = 3 then NBytes := 1
            else NBytes := DLenI;
            if DPos + 4 + NBytes > Length(P) then Break;
            if Req.Res = arOk then
            begin
              Req.Write := True;
              SetLength(Req.Data, NBytes);
              if NBytes > 0 then Move(P[DPos + 4], Req.Data[0], NBytes);
              if (not Req.Bits) and not (Req.Area in [arT, arC]) then Req.Len := NBytes;
              if Req.Bits then Req.Data[0] := Req.Data[0] and 1;
            end;
            Inc(DPos, 4 + NBytes);
            if Odd(NBytes) and (K < Cnt - 1) then Inc(DPos);
          end;
          if Req.Res = arOk then FHub.Rt.AreaIO(Req);
          if Func = $04 then
          begin
            if Req.Res = arOk then
            begin
              NBytes := Length(Req.Data);
              if Length(Dat) + 4 + NBytes + 14 > FPdu then
              begin
                Append(Dat, [$05, 0, 0, 0]);
              end
              else
              begin
                if Req.Bits then Append(Dat, [$FF, 3, 0, 1])
                else if Req.Area in [arT, arC] then Append(Dat, [$FF, 9, NBytes shr 8, NBytes and $FF])
                else if Ts = TsReal then Append(Dat, [$FF, 7, NBytes shr 8, NBytes and $FF])
                else Append(Dat, [$FF, 4, (NBytes * 8) shr 8, (NBytes * 8) and $FF]);
                Append(Dat, Req.Data);
                if Odd(NBytes) and (K < Cnt - 1) then Append(Dat, [0]);
              end;
            end
            else
              Append(Dat, [ResCode(Req.Res), 0, 0, 0]);
          end
          else
            Append(Dat, [ResCode(Req.Res)]);
          if Req.Res <> arOk then
            case Req.Res of
              arNoObject: Txt := Txt + ' (object does not exist)';
              arOutOfRange: Txt := Txt + ' (address out of range)';
              arNotAllowed: Txt := Txt + ' (optimized DB: no absolute access)';
            else
              Txt := Txt + ' (type not supported)';
            end;
        end;
        Ack(0, 0);
        if Func = $04 then FHub.Log(prS7, FPeer, 'read ' + Txt, Pos(' (', Txt) = 0)
        else FHub.Log(prS7, FPeer, 'write ' + Txt, Pos(' (', Txt) = 0);
        FHub.ConnUpdate(FId, 1, 0, 0, '', True);
        Exit(True);
      end;
    $29:
      begin
        // PLC stop
        SetLength(Par, 1);
        Par[0] := $29;
        if FHub.Rt.Mode = rmStop then
        begin
          SetLength(Par, 2);
          Par[1] := $07;
        end;
        FHub.Rt.CmdStop;
        Ack(0, 0);
        FHub.Log(prS7, FPeer, 'PLC STOP requested by the partner');
        Exit(True);
      end;
    $28:
      begin
        // PI service (P_PROGRAM = start)
        SetLength(Par, 1);
        Par[0] := $28;
        if FHub.Rt.Mode = rmRun then
        begin
          SetLength(Par, 2);
          Par[1] := $03;
        end;
        FHub.Rt.CmdRun;
        Ack(0, 0);
        FHub.Log(prS7, FPeer, 'PI service: PLC start (P_PROGRAM)');
        Exit(True);
      end;
  else
    begin
      SetLength(Par, 2);
      Par[0] := Func;
      Par[1] := 0;
      Ack($81, $04);
      FHub.Log(prS7, FPeer, Format('function 0x%.2x not supported', [Func]), False);
      Exit(True);
    end;
  end;
end;

procedure TClientThread.ServeS7;
var
  Hdr: array[0..3] of Byte;
  Body, R, OutB: TBytes;
  Len, LI, K, Pc, PL, Rack, Slot, SrcRef: Integer;
  Tsap: array of Byte;
  Tpdu: Integer;
  S7: TBytes;
begin
  while not Terminated do
  begin
    if not RecvExact(Hdr, 4) then Exit;
    if Hdr[0] <> 3 then
    begin
      FHub.Log(prS7, FPeer, 'not ISO-on-TCP (TPKT): closed', False);
      Exit;
    end;
    Len := (Hdr[2] shl 8) or Hdr[3];
    if (Len < 7) or (Len > 4096) then Exit;
    SetLength(Body, Len - 4);
    if not RecvExact(Body[0], Len - 4) then Exit;
    LI := Body[0];
    case Body[1] of
      $E0:
        begin
          // COTP connection request: the destination TSAP is the CPU (rack / slot)
          SrcRef := GetW(Body, 4);
          SetLength(Tsap, 0);
          Rack := -1;
          Slot := -1;
          Tpdu := $0A;
          K := 7;
          while K + 1 < Min(Length(Body), LI + 1) do
          begin
            Pc := Body[K];
            PL := Body[K + 1];
            if (Pc = $C2) and (PL >= 2) then
            begin
              Rack := Body[K + 3] shr 5;
              Slot := Body[K + 3] and $1F;
            end;
            if Pc = $C0 then Tpdu := Body[K + 2];
            Inc(K, 2 + PL);
          end;
          if not FHub.SlotOk(Rack, Slot) then
          begin
            FHub.Log(prS7, FPeer, Format('connect refused: rack %d slot %d, this CPU is %s', [Rack, Slot,
              FHub.ExpectedSlots]), False);
            Exit;
          end;
          // connection confirm: the CR's parameters back
          SetLength(OutB, 0);
          Append(OutB, [3, 0, 0, 0, LI, $D0, SrcRef shr 8, SrcRef and $FF, 0, 1, 0]);
          SetLength(R, LI + 1 - 7);
          if Length(R) > 0 then Move(Body[7], R[0], Length(R));
          Append(OutB, R);
          PutW(OutB, 2, Length(OutB));
          if not SendAll(OutB) then Exit;
          FConnected := True;
          FHub.Log(prS7, FPeer, Format('connected: rack %d slot %d, TPDU 0x%.2x', [Rack, Slot, Tpdu]));
          FHub.ConnUpdate(FId, 0, 0, 0, Format('S7, rack %d slot %d', [Rack, Slot]), True);
        end;
      $F0:
        begin
          if not FConnected then Exit;
          SetLength(S7, Length(Body) - (LI + 1));
          if Length(S7) > 0 then Move(Body[LI + 1], S7[0], Length(S7));
          if S7Job(S7, R) then
          begin
            SetLength(OutB, 0);
            Append(OutB, [3, 0, 0, 0, 2, $F0, $80]);
            Append(OutB, R);
            PutW(OutB, 2, Length(OutB));
            if not SendAll(OutB) then Exit;
          end;
        end;
      $80:
        Exit;   // disconnect request
    end;
  end;
end;

{ ---------- Modbus TCP ---------- }

procedure TClientThread.ServeModbus;
var
  Mb: array[0..6] of Byte;
  Pdu, R: TBytes;
  Len, Fc, Adr, Qty, K, Unit_: Integer;
  Req: TAreaReq;
  Ex: Integer;
  Txt: string;
  Hr: TArea;
  HrDB: Integer;

  procedure Reply(const Data: array of Byte);
  var
    O: TBytes;
  begin
    SetLength(O, 0);
    Append(O, [Mb[0], Mb[1], 0, 0, 0, 0, Mb[6]]);
    PutW(O, 4, Length(Data) + 1);
    Append(O, Data);
    SendAll(O);
  end;

  function Io(A: TArea; DB, Ofs, Len: Integer; Bits, Wr: Boolean; const Data: TBytes): Boolean;
  begin
    FillChar(Req, SizeOf(Req), 0);
    Req.Area := A;
    Req.DB := DB;
    Req.Ofs := Ofs;
    Req.Len := Len;
    Req.Bits := Bits;
    Req.Write := Wr;
    Req.Data := Copy(Data);
    FHub.Rt.AreaIO(Req);
    Result := Req.Res = arOk;
    if not Result then Ex := 2;
  end;

  function RegName(A: TArea; DB, R0: Integer): string;
  begin
    if A = arDB then Result := Format('DB%d.DBW%d', [DB, R0 * 2])
    else Result := Format('%sW%d', [AreaName(A), R0 * 2]);
  end;

begin
  while not Terminated do
  begin
    if not RecvExact(Mb, 7) then Exit;
    Len := (Mb[4] shl 8) or Mb[5];
    if (Mb[2] <> 0) or (Mb[3] <> 0) or (Len < 2) or (Len > 260) then
    begin
      FHub.Log(prModbus, FPeer, 'not Modbus TCP: closed', False);
      Exit;
    end;
    SetLength(Pdu, Len - 1);
    if not RecvExact(Pdu[0], Len - 1) then Exit;
    Unit_ := Mb[6];
    Fc := Pdu[0];
    Ex := 0;
    Txt := '';
    Hr := FHub.Settings.MbHRArea;
    HrDB := FHub.Settings.MbHRDB;
    SetLength(R, 0);
    if (Unit_ <> FHub.Settings.MbUnit) and (Unit_ <> 0) and (Unit_ <> 255) then
    begin
      FHub.Log(prModbus, FPeer, Format('unit %d ignored (this server is unit %d)', [Unit_, FHub.Settings.MbUnit]), False);
      Continue;
    end;
    if Length(Pdu) >= 5 then
    begin
      Adr := GetW(Pdu, 1);
      Qty := GetW(Pdu, 3);
    end
    else
    begin
      Adr := 0;
      Qty := 0;
    end;
    case Fc of
      1, 2:
        if (Qty < 1) or (Qty > 2000) then Ex := 3
        else
        begin
          if Fc = 1 then Txt := Format('read coils %d x%d (Q%d.%d ..)', [Adr, Qty, Adr div 8, Adr mod 8])
          else Txt := Format('read inputs %d x%d (I%d.%d ..)', [Adr, Qty, Adr div 8, Adr mod 8]);
          if Fc = 1 then Io(arQ, 0, Adr, Qty, True, False, nil) else Io(arI, 0, Adr, Qty, True, False, nil);
          if Ex = 0 then
          begin
            Append(R, [Fc, Length(Req.Data)]);
            Append(R, Req.Data);
          end;
        end;
      3, 4:
        if (Qty < 1) or (Qty > 125) then Ex := 3
        else
        begin
          if Fc = 3 then
          begin
            Txt := Format('read holding %d x%d (%s ..)', [Adr, Qty, RegName(Hr, HrDB, Adr)]);
            Io(Hr, HrDB, Adr * 2, Qty * 2, False, False, nil);
          end
          else
          begin
            Txt := Format('read input registers %d x%d (IW%d ..)', [Adr, Qty, Adr * 2]);
            Io(arI, 0, Adr * 2, Qty * 2, False, False, nil);
          end;
          if Ex = 0 then
          begin
            Append(R, [Fc, Qty * 2]);
            Append(R, Req.Data);
          end;
        end;
      5:
        if (Qty <> 0) and (Qty <> $FF00) then Ex := 3
        else
        begin
          Txt := Format('write coil %d = %d (Q%d.%d)', [Adr, Ord(Qty = $FF00), Adr div 8, Adr mod 8]);
          SetLength(R, 1);
          R[0] := Ord(Qty = $FF00);
          Io(arQ, 0, Adr, 1, True, True, R);
          SetLength(R, 0);
          if Ex = 0 then Append(R, [5, Pdu[1], Pdu[2], Pdu[3], Pdu[4]]);
        end;
      6:
        begin
          Txt := Format('write holding %d = %d (%s)', [Adr, SmallInt(Qty), RegName(Hr, HrDB, Adr)]);
          SetLength(R, 2);
          R[0] := Pdu[3];
          R[1] := Pdu[4];
          Io(Hr, HrDB, Adr * 2, 2, False, True, R);
          SetLength(R, 0);
          if Ex = 0 then Append(R, [6, Pdu[1], Pdu[2], Pdu[3], Pdu[4]]);
        end;
      15, 16:
        if (Length(Pdu) < 6) or (Length(Pdu) < 6 + Pdu[5]) or (Qty < 1) or
          ((Fc = 15) and ((Qty > 1968) or (Pdu[5] < (Qty + 7) div 8))) or
          ((Fc = 16) and ((Qty > 123) or (Pdu[5] < Qty * 2))) then Ex := 3
        else
        begin
          SetLength(R, Pdu[5]);
          Move(Pdu[6], R[0], Pdu[5]);
          if Fc = 15 then
          begin
            Txt := Format('write coils %d x%d (Q%d.%d ..)', [Adr, Qty, Adr div 8, Adr mod 8]);
            Io(arQ, 0, Adr, Qty, True, True, R);
          end
          else
          begin
            Txt := Format('write holding %d x%d (%s ..)', [Adr, Qty, RegName(Hr, HrDB, Adr)]);
            Io(Hr, HrDB, Adr * 2, Qty * 2, False, True, R);
          end;
          SetLength(R, 0);
          if Ex = 0 then Append(R, [Fc, Pdu[1], Pdu[2], Pdu[3], Pdu[4]]);
        end;
    else
      begin
        Ex := 1;
        Txt := Format('function %d', [Fc]);
      end;
    end;
    if Ex <> 0 then
    begin
      SetLength(R, 0);
      Append(R, [Fc or $80, Ex]);
      case Ex of
        1: Txt := Txt + ' (illegal function)';
        2: Txt := Txt + ' (illegal data address)';
      else
        Txt := Txt + ' (illegal data value)';
      end;
    end;
    Reply(R);
    FHub.Log(prModbus, FPeer, Txt, Ex = 0);
    FHub.ConnUpdate(FId, 1, 0, 0, Format('Modbus, unit %d', [Unit_]), True);
  end;
end;

end.
