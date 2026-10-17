unit uIpcServer;

{ The IPC server: programs on this PC talk to the Virtual PLC through the Windows named pipe
  \\.\pipe\VirtualPLC, without the network (no firewall question, no port).

  The protocol is text, a line each way (UTF-8, ending in LF; CR is ignored):
    PING                       OK Virtual PLC <CPU>
    STATE                      OK RUN | OK STOP
    READ <operand>             OK <value>        e.g. READ "Motor"  ->  OK TRUE
    WRITE <operand> <value>    OK                e.g. WRITE %MW20 123, WRITE "Start_PB" TRUE
    RUN / STOP                 OK
    TAGS                       OK <n>, then n lines  name;type;address, then END
    HELP                       OK <the commands>
  An error answers  ERR <why>.

  Every client has a thread of its own; a request is answered on the main thread (OnRequest, through
  TThread.Synchronize), where the project, the resolver and the runtime live. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Windows;

const
  IpcPipeName = '\\.\pipe\VirtualPLC';

type
  TIpcRequest = function(const Line: string): string of object;

  TIpcServer = class;

  { TIpcClient: one connection }

  TIpcClient = class(TThread)
  private
    FServer: TIpcServer;
    FPipe: THandle;
    FLine, FAnswer: string;
    procedure Answer;
  protected
    procedure Execute; override;
  public
    constructor Create(AServer: TIpcServer; APipe: THandle);
  end;

  { TIpcServer: waits for clients on the pipe }

  TIpcServer = class(TThread)
  private
    FLock: TRTLCriticalSection;
    FClients: TList;
    FStopping: Boolean;
  protected
    procedure Execute; override;
  public
    OnRequest: TIpcRequest;
    Requests: Int64;           // answered so far
    LastLine: string;          // the last request (for the Ports screen)
    constructor Create(AOnRequest: TIpcRequest);
    destructor Destroy; override;
    procedure Shut;            // ends the waiting and every connection
    function ClientCount: Integer;
  end;

implementation

function CancelSynchronousIo(hThread: THandle): BOOL; stdcall; external 'kernel32.dll';

const
  PIPE_UNLIMITED_INSTANCES = 255;

{ TIpcClient }

constructor TIpcClient.Create(AServer: TIpcServer; APipe: THandle);
begin
  FServer := AServer;
  FPipe := APipe;
  FreeOnTerminate := False;
  inherited Create(False);
end;

procedure TIpcClient.Answer;
begin
  // the main thread: the project and the runtime are safe to use here
  if Assigned(FServer.OnRequest) then FAnswer := FServer.OnRequest(FLine) else FAnswer := 'ERR no server';
  Inc(FServer.Requests);
  FServer.LastLine := FLine;
end;

procedure TIpcClient.Execute;
var
  Buf: array[0..4095] of Byte;
  Got, Put: DWORD;
  Pending, Out: string;
  P: Integer;
begin
  Pending := '';
  while not Terminated do
  begin
    if not ReadFile(FPipe, Buf[0], SizeOf(Buf), Got, nil) or (Got = 0) then Break;
    SetString(Out, PChar(@Buf[0]), Got);
    Pending := Pending + Out;
    P := Pos(#10, Pending);
    while (P > 0) and not Terminated do
    begin
      FLine := Trim(StringReplace(Copy(Pending, 1, P - 1), #13, '', [rfReplaceAll]));
      Delete(Pending, 1, P);
      if FLine <> '' then
      begin
        Synchronize(@Answer);
        Out := FAnswer + #10;
        if not WriteFile(FPipe, Out[1], Length(Out), Put, nil) then Break;
      end;
      P := Pos(#10, Pending);
    end;
    if Length(Pending) > 65536 then Break;   // no line end in 64 KB: not a client of ours
  end;
  FlushFileBuffers(FPipe);
  DisconnectNamedPipe(FPipe);
  CloseHandle(FPipe);
  FPipe := 0;
end;

{ TIpcServer }

constructor TIpcServer.Create(AOnRequest: TIpcRequest);
begin
  InitCriticalSection(FLock);
  FClients := TList.Create;
  OnRequest := AOnRequest;
  FreeOnTerminate := False;
  inherited Create(False);
end;

destructor TIpcServer.Destroy;
begin
  Shut;
  FClients.Free;
  DoneCriticalSection(FLock);
  inherited Destroy;
end;

function TIpcServer.ClientCount: Integer;
var
  K: Integer;
begin
  Result := 0;
  EnterCriticalSection(FLock);
  try
    for K := 0 to FClients.Count - 1 do
      if not TIpcClient(FClients[K]).Finished then Inc(Result);
  finally
    LeaveCriticalSection(FLock);
  end;
end;

procedure TIpcServer.Execute;
var
  H: THandle;
  Ok: Boolean;
  K: Integer;
  C: TIpcClient;
begin
  while not Terminated do
  begin
    H := CreateNamedPipeW(PWideChar(UnicodeString(IpcPipeName)), PIPE_ACCESS_DUPLEX,
      PIPE_TYPE_BYTE or PIPE_READMODE_BYTE or PIPE_WAIT, PIPE_UNLIMITED_INSTANCES, 4096, 4096, 0, nil);
    if H = INVALID_HANDLE_VALUE then
    begin
      Sleep(200);
      Continue;
    end;
    Ok := ConnectNamedPipe(H, nil) or (GetLastError = ERROR_PIPE_CONNECTED);
    if Terminated or FStopping then
    begin
      CloseHandle(H);
      Break;
    end;
    if not Ok then
    begin
      CloseHandle(H);
      Continue;
    end;
    EnterCriticalSection(FLock);
    try
      // the finished connections go
      for K := FClients.Count - 1 downto 0 do
      begin
        C := TIpcClient(FClients[K]);
        if C.Finished then
        begin
          C.Free;
          FClients.Delete(K);
        end;
      end;
      FClients.Add(TIpcClient.Create(Self, H));
    finally
      LeaveCriticalSection(FLock);
    end;
  end;
end;

procedure TIpcServer.Shut;
var
  H: THandle;
  K: Integer;
  C: TIpcClient;
begin
  if FStopping then Exit;
  FStopping := True;
  Terminate;
  // the waiting ConnectNamedPipe ends when a client comes: one that leaves at once
  H := CreateFileW(PWideChar(UnicodeString(IpcPipeName)), GENERIC_READ or GENERIC_WRITE, 0, nil, OPEN_EXISTING, 0, 0);
  if H <> INVALID_HANDLE_VALUE then CloseHandle(H);
  WaitFor;
  EnterCriticalSection(FLock);
  try
    for K := 0 to FClients.Count - 1 do
    begin
      C := TIpcClient(FClients[K]);
      C.Terminate;
      // a client thread waiting in ReadFile: its read ends
      CancelSynchronousIo(C.Handle);
    end;
  finally
    LeaveCriticalSection(FLock);
  end;
  for K := 0 to FClients.Count - 1 do
  begin
    C := TIpcClient(FClients[K]);
    // a client waiting for Synchronize while the main thread waits here: give it the main thread
    while not C.Finished do
    begin
      CheckSynchronize(10);
      CancelSynchronousIo(C.Handle);
    end;
    C.Free;
  end;
  FClients.Clear;
end;

end.
