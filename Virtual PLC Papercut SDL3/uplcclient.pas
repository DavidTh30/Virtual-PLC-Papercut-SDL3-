unit uPlcClient;

{ Minimal S7 (ISO-on-TCP) and Modbus TCP clients: the self test of the Ports
  screen and the automated tests talk to the simulated ports with them, the
  same way an HMI or snap7 does (the S7 telegrams follow snap7's layout). }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, sockets;

type

  { TTcpClient }

  TTcpClient = class
  protected
    FSock: LongInt;
    function SendAll(const B: array of Byte): Boolean;
    function RecvExact(var Buf; N: Integer): Boolean;
  public
    LastError: string;
    TimeoutMs: Integer;
    constructor Create;
    destructor Destroy; override;
    function Open(const Host: string; Port: Integer): Boolean;
    procedure Close;
  end;

  { TS7Client }

  TS7Client = class(TTcpClient)
  private
    FRef: Integer;
    function Exchange(const S7: array of Byte; out R: TBytes): Boolean;
  public
    PduSize: Integer;
    function Connect(const Host: string; Port, Rack, Slot: Integer): Boolean;
    { AreaCode $81 I, $82 Q, $83 M, $84 DB, $1C C, $1D T; Start in bytes (T / C: number) }
    function ReadArea(AreaCode, DB, Start, Amount: Integer; out Data: TBytes): Integer;
    function WriteArea(AreaCode, DB, Start: Integer; const Data: array of Byte): Integer;
    function ReadBit(AreaCode, DB, ByteOfs, Bit: Integer; out V: Boolean): Integer;
    function WriteBit(AreaCode, DB, ByteOfs, Bit: Integer; V: Boolean): Integer;
    { $08 RUN, $04 STOP, -1 error }
    function CpuState: Integer;
    function OrderCode: string;
    function PlcStop: Boolean;
    function PlcStart: Boolean;
  end;

  { TModbusClient }

  TModbusClient = class(TTcpClient)
  private
    FTid: Integer;
    function Exchange(const Pdu: array of Byte; out R: TBytes): Integer;
  public
    UnitId: Integer;
    { the result: 0 ok, > 0 Modbus exception code, -1 transport error }
    function ReadBits(Fc, Start, Qty: Integer; out Bits: TBytes): Integer;
    function ReadRegs(Fc, Start, Qty: Integer; out Regs: TBytes): Integer;
    function WriteCoil(Addr: Integer; V: Boolean): Integer;
    function WriteReg(Addr, V: Integer): Integer;
    function WriteRegs(Start: Integer; const Regs: array of Word): Integer;
  end;

implementation

const
  WSAETIMEDOUT = 10060;

procedure Add(var B: TBytes; const X: array of Byte);
var
  N: Integer;
begin
  N := Length(B);
  SetLength(B, N + Length(X));
  if Length(X) > 0 then Move(X[0], B[N], Length(X));
end;

{ TTcpClient }

constructor TTcpClient.Create;
begin
  inherited Create;
  FSock := -1;
  TimeoutMs := 1500;
end;

destructor TTcpClient.Destroy;
begin
  Close;
  inherited Destroy;
end;

function TTcpClient.Open(const Host: string; Port: Integer): Boolean;
var
  A: TInetSockAddr;
  Ms: LongInt;
begin
  Close;
  Result := False;
  FSock := fpSocket(AF_INET, SOCK_STREAM, 0);
  if FSock < 0 then
  begin
    LastError := 'socket error';
    Exit;
  end;
  Ms := TimeoutMs;
  fpSetSockOpt(FSock, SOL_SOCKET, SO_RCVTIMEO, @Ms, SizeOf(Ms));
  FillChar(A, SizeOf(A), 0);
  A.sin_family := AF_INET;
  A.sin_port := htons(Port);
  A.sin_addr := StrToNetAddr(Host);
  if fpConnect(FSock, @A, SizeOf(A)) <> 0 then
  begin
    LastError := Format('cannot connect to %s:%d (error %d)', [Host, Port, SocketError]);
    Close;
    Exit;
  end;
  Result := True;
end;

procedure TTcpClient.Close;
begin
  if FSock >= 0 then CloseSocket(FSock);
  FSock := -1;
end;

function TTcpClient.SendAll(const B: array of Byte): Boolean;
var
  Sent, R: Integer;
begin
  Result := False;
  Sent := 0;
  while Sent < Length(B) do
  begin
    R := fpSend(FSock, @B[Sent], Length(B) - Sent, 0);
    if R <= 0 then
    begin
      LastError := 'send failed';
      Exit;
    end;
    Inc(Sent, R);
  end;
  Result := True;
end;

function TTcpClient.RecvExact(var Buf; N: Integer): Boolean;
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
    if R <= 0 then
    begin
      if (R < 0) and (SocketError = WSAETIMEDOUT) then LastError := 'timeout' else LastError := 'connection closed';
      Exit;
    end;
    Inc(Got, R);
  end;
  Result := True;
end;

{ TS7Client }

function TS7Client.Connect(const Host: string; Port, Rack, Slot: Integer): Boolean;
var
  H: array[0..3] of Byte;
  B, R: TBytes;
  Len: Integer;
begin
  Result := False;
  if not Open(Host, Port) then Exit;
  // COTP connection request: local TSAP 01 00, remote TSAP 01 (rack * 32 + slot)
  SetLength(B, 0);
  Add(B, [3, 0, 0, 22, 17, $E0, 0, 0, 0, 1, 0, $C0, 1, $0A, $C1, 2, 1, 0, $C2, 2, 1, Rack * 32 + Slot]);
  if not SendAll(B) then Exit;
  if not RecvExact(H, 4) then
  begin
    LastError := 'connection refused by the CPU (' + LastError + ')';
    Exit;
  end;
  Len := (H[2] shl 8) or H[3];
  SetLength(R, Len - 4);
  if not RecvExact(R[0], Len - 4) then Exit;
  if R[1] <> $D0 then
  begin
    LastError := 'no connection confirm';
    Exit;
  end;
  // setup communication, PDU 480
  if not Exchange([$32, 1, 0, 0, 0, 0, 0, 8, 0, 0, $F0, 0, 0, 1, 0, 1, 1, $E0], R) then Exit;
  if (Length(R) < 20) or (R[10] <> 0) or (R[11] <> 0) then
  begin
    LastError := 'setup communication refused';
    Exit;
  end;
  PduSize := (R[18] shl 8) or R[19];
  Result := True;
end;

function TS7Client.Exchange(const S7: array of Byte; out R: TBytes): Boolean;
var
  B: TBytes;
  H: array[0..3] of Byte;
  Len, K: Integer;
  T: TBytes;
begin
  Result := False;
  SetLength(R, 0);
  if FSock < 0 then
  begin
    LastError := 'not connected';
    Exit;
  end;
  Inc(FRef);
  SetLength(T, Length(S7));
  if Length(S7) > 0 then Move(S7[0], T[0], Length(S7));
  if Length(T) >= 6 then
  begin
    T[4] := (FRef shr 8) and $FF;
    T[5] := FRef and $FF;
  end;
  SetLength(B, 0);
  Add(B, [3, 0, 0, 0, 2, $F0, $80]);
  Add(B, T);
  B[2] := Length(B) shr 8;
  B[3] := Length(B) and $FF;
  if not SendAll(B) then Exit;
  if not RecvExact(H, 4) then Exit;
  Len := (H[2] shl 8) or H[3];
  if Len < 7 then Exit;
  SetLength(B, Len - 4);
  if not RecvExact(B[0], Len - 4) then Exit;
  // skip the COTP DT header
  K := B[0] + 1;
  SetLength(R, Length(B) - K);
  if Length(R) > 0 then Move(B[K], R[0], Length(R));
  Result := (Length(R) >= 10) and (R[0] = $32);
  if not Result then LastError := 'bad answer';
end;

function TS7Client.ReadArea(AreaCode, DB, Start, Amount: Integer; out Data: TBytes): Integer;
var
  R: TBytes;
  Addr, Ts, PL, N: Integer;
begin
  SetLength(Data, 0);
  if AreaCode in [$1C, $1D] then
  begin
    Ts := AreaCode;
    Addr := Start;
  end
  else
  begin
    Ts := 2;
    Addr := Start * 8;
  end;
  if not Exchange([$32, 1, 0, 0, 0, 0, 0, 14, 0, 0, 4, 1, $12, $0A, $10, Ts, Amount shr 8, Amount and $FF,
    DB shr 8, DB and $FF, AreaCode, (Addr shr 16) and $FF, (Addr shr 8) and $FF, Addr and $FF], R) then Exit(-1);
  if (R[10] <> 0) or (R[11] <> 0) then
  begin
    LastError := Format('error class 0x%.2x code 0x%.2x', [R[10], R[11]]);
    Exit(-2);
  end;
  PL := (R[6] shl 8) or R[7];
  N := 12 + PL;
  if N + 4 > Length(R) then Exit(-1);
  if R[N] <> $FF then
  begin
    LastError := Format('item return code 0x%.2x', [R[N]]);
    Exit(R[N]);
  end;
  SetLength(Data, Length(R) - N - 4);
  if Length(Data) > 0 then Move(R[N + 4], Data[0], Length(Data));
  Result := 0;
end;

function TS7Client.WriteArea(AreaCode, DB, Start: Integer; const Data: array of Byte): Integer;
var
  S7, R: TBytes;
  Addr, Bits: Integer;
begin
  Addr := Start * 8;
  Bits := Length(Data) * 8;
  SetLength(S7, 0);
  Add(S7, [$32, 1, 0, 0, 0, 0, 0, 14, 0, 0, 5, 1, $12, $0A, $10, 2, Length(Data) shr 8, Length(Data) and $FF,
    DB shr 8, DB and $FF, AreaCode, (Addr shr 16) and $FF, (Addr shr 8) and $FF, Addr and $FF,
    0, 4, Bits shr 8, Bits and $FF]);
  Add(S7, Data);
  S7[8] := (Length(Data) + 4) shr 8;
  S7[9] := (Length(Data) + 4) and $FF;
  if not Exchange(S7, R) then Exit(-1);
  if (R[10] <> 0) or (R[11] <> 0) then
  begin
    LastError := Format('error class 0x%.2x code 0x%.2x', [R[10], R[11]]);
    Exit(-2);
  end;
  if Length(R) < 15 then Exit(-1);
  if R[14] <> $FF then
  begin
    LastError := Format('item return code 0x%.2x', [R[14]]);
    Exit(R[14]);
  end;
  Result := 0;
end;

function TS7Client.ReadBit(AreaCode, DB, ByteOfs, Bit: Integer; out V: Boolean): Integer;
var
  R: TBytes;
  Addr, N: Integer;
begin
  V := False;
  Addr := ByteOfs * 8 + Bit;
  if not Exchange([$32, 1, 0, 0, 0, 0, 0, 14, 0, 0, 4, 1, $12, $0A, $10, 1, 0, 1, DB shr 8, DB and $FF, AreaCode,
    (Addr shr 16) and $FF, (Addr shr 8) and $FF, Addr and $FF], R) then Exit(-1);
  if (R[10] <> 0) or (R[11] <> 0) then Exit(-2);
  N := 14;
  if R[N] <> $FF then Exit(R[N]);
  V := R[N + 4] and 1 <> 0;
  Result := 0;
end;

function TS7Client.WriteBit(AreaCode, DB, ByteOfs, Bit: Integer; V: Boolean): Integer;
var
  R: TBytes;
  Addr: Integer;
begin
  Addr := ByteOfs * 8 + Bit;
  if not Exchange([$32, 1, 0, 0, 0, 0, 0, 14, 0, 5, 5, 1, $12, $0A, $10, 1, 0, 1, DB shr 8, DB and $FF, AreaCode,
    (Addr shr 16) and $FF, (Addr shr 8) and $FF, Addr and $FF, 0, 3, 0, 1, Ord(V)], R) then Exit(-1);
  if (R[10] <> 0) or (R[11] <> 0) then Exit(-2);
  if R[14] <> $FF then Exit(R[14]);
  Result := 0;
end;

function TS7Client.CpuState: Integer;
var
  R: TBytes;
  PL: Integer;
begin
  Result := -1;
  if not Exchange([$32, 7, 0, 0, 0, 0, 0, 8, 0, 8, 0, 1, $12, 4, $11, $44, 1, 0, $FF, 9, 0, 4, 4, $24, 0, 0], R) then Exit;
  PL := (R[6] shl 8) or R[7];
  if Length(R) < 10 + PL + 16 then Exit;
  Result := R[10 + PL + 15];
end;

function TS7Client.OrderCode: string;
var
  R: TBytes;
  PL, I: Integer;
begin
  Result := '';
  if not Exchange([$32, 7, 0, 0, 0, 0, 0, 8, 0, 8, 0, 1, $12, 4, $11, $44, 1, 0, $FF, 9, 0, 4, 0, $11, 0, 0], R) then Exit;
  PL := (R[6] shl 8) or R[7];
  if Length(R) < 10 + PL + 34 then Exit;
  for I := 0 to 19 do Result := Result + Chr(R[10 + PL + 14 + I]);
  Result := Trim(Result);
end;

function TS7Client.PlcStop: Boolean;
var
  R: TBytes;
begin
  Result := Exchange([$32, 1, 0, 0, 0, 0, 0, $10, 0, 0, $29, 0, 0, 0, 0, 0, 9, $50, $5F, $50, $52, $4F, $47,
    $52, $41, $4D], R) and (R[10] = 0);
end;

function TS7Client.PlcStart: Boolean;
var
  R: TBytes;
begin
  Result := Exchange([$32, 1, 0, 0, 0, 0, 0, $14, 0, 0, $28, 0, 0, 0, 0, 0, 0, $FD, 0, 0, 9, $50, $5F, $50, $52,
    $4F, $47, $52, $41, $4D], R) and (R[10] = 0);
end;

{ TModbusClient }

function TModbusClient.Exchange(const Pdu: array of Byte; out R: TBytes): Integer;
var
  B: TBytes;
  H: array[0..6] of Byte;
  Len: Integer;
begin
  SetLength(R, 0);
  Inc(FTid);
  SetLength(B, 0);
  Add(B, [FTid shr 8, FTid and $FF, 0, 0, (Length(Pdu) + 1) shr 8, (Length(Pdu) + 1) and $FF, UnitId]);
  Add(B, Pdu);
  if not SendAll(B) then Exit(-1);
  if not RecvExact(H, 7) then Exit(-1);
  Len := (H[4] shl 8) or H[5];
  SetLength(R, Len - 1);
  if (Len < 2) or not RecvExact(R[0], Len - 1) then Exit(-1);
  if R[0] and $80 <> 0 then
  begin
    LastError := Format('exception %d', [R[1]]);
    Exit(R[1]);
  end;
  Result := 0;
end;

function TModbusClient.ReadBits(Fc, Start, Qty: Integer; out Bits: TBytes): Integer;
var
  R: TBytes;
begin
  SetLength(Bits, 0);
  Result := Exchange([Fc, Start shr 8, Start and $FF, Qty shr 8, Qty and $FF], R);
  if Result <> 0 then Exit;
  SetLength(Bits, R[1]);
  if R[1] > 0 then Move(R[2], Bits[0], R[1]);
end;

function TModbusClient.ReadRegs(Fc, Start, Qty: Integer; out Regs: TBytes): Integer;
var
  R: TBytes;
begin
  SetLength(Regs, 0);
  Result := Exchange([Fc, Start shr 8, Start and $FF, Qty shr 8, Qty and $FF], R);
  if Result <> 0 then Exit;
  SetLength(Regs, R[1]);
  if R[1] > 0 then Move(R[2], Regs[0], R[1]);
end;

function TModbusClient.WriteCoil(Addr: Integer; V: Boolean): Integer;
var
  R: TBytes;
begin
  if V then Result := Exchange([5, Addr shr 8, Addr and $FF, $FF, 0], R)
  else Result := Exchange([5, Addr shr 8, Addr and $FF, 0, 0], R);
end;

function TModbusClient.WriteReg(Addr, V: Integer): Integer;
var
  R: TBytes;
begin
  Result := Exchange([6, Addr shr 8, Addr and $FF, (V shr 8) and $FF, V and $FF], R);
end;

function TModbusClient.WriteRegs(Start: Integer; const Regs: array of Word): Integer;
var
  P, R: TBytes;
  K: Integer;
begin
  SetLength(P, 0);
  Add(P, [16, Start shr 8, Start and $FF, Length(Regs) shr 8, Length(Regs) and $FF, Length(Regs) * 2]);
  for K := 0 to High(Regs) do Add(P, [Regs[K] shr 8, Regs[K] and $FF]);
  Result := Exchange(P, R);
end;

end.
