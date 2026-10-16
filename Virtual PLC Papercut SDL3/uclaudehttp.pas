unit uClaudeHttp;

{ The transport for the Claude assistant: one HTTPS POST to the Messages API through WinHTTP (built
  into Windows: TLS without extra DLLs), on a worker thread so the UI keeps its 60 Hz.

  Key        ANTHROPIC_API_KEY of the process, else of the Windows user (HKCU\Environment, as setx
             writes it: a key set while the app runs counts too), else the key kept for this Windows
             user with DPAPI (CryptProtectData) in %APPDATA%\VirtualPLC\claude.key.
             VPLC_KEY_VAR (tests only) names another variable and file, so a test never touches the
             real key
  Base URL   ANTHROPIC_BASE_URL (default https://api.anthropic.com); http:// is allowed for a local
             test server
  Retries    408 / 409 / 429 / 5xx / 529 and connection errors, twice, with a growing pause }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Windows, Registry;

type
  { one request on its own thread; Done tells the UI to collect Status / Body / Error }
  TClaudeRequest = class(TThread)
  private
    FUrl, FBody, FHeaders: string;
  protected
    procedure Execute; override;
  public
    Status: Integer;
    Response: string;
    Error: string;
    Done: Boolean;
    Cancelled: Boolean;
    constructor Create(const AUrl, ABody, AHeaders: string);
  end;

function ClaudeBaseUrl: string;
function ClaudeKeyVar: string;                       // 'ANTHROPIC_API_KEY'
function ClaudeApiKey(out Source: string): string;   // '' when none
procedure ClaudeSaveKey(const Key: string);          // encrypted for this Windows user (DPAPI)
procedure ClaudeForgetKey;
function ClaudeHasSavedKey: Boolean;
{ the user's environment variable (like setx): the registry, this process and a broadcast so new
  programs see it }
procedure ClaudeSetEnvKey(const Key: string);
procedure ClaudeRemoveEnvKey;
function ClaudeHasEnvKey: Boolean;
{ a blocking POST (the worker calls it); False: no HTTP answer at all (Error says why) }
function HttpPost(const Url, Body, Headers: string; out Status: Integer; out Resp, Error: string): Boolean;

implementation

type
  HINTERNET = Pointer;
  TDataBlob = record
    cbData: DWORD;
    pbData: PByte;
  end;
  PDataBlob = ^TDataBlob;

const
  WINHTTP_ACCESS_TYPE_DEFAULT_PROXY = 0;
  WINHTTP_FLAG_SECURE = $00800000;
  WINHTTP_QUERY_STATUS_CODE = 19;
  WINHTTP_QUERY_FLAG_NUMBER = $20000000;
  CRYPTPROTECT_UI_FORBIDDEN = $1;

function WinHttpOpen(pszAgentW: PWideChar; dwAccessType: DWORD; pszProxyW, pszProxyBypassW: PWideChar;
  dwFlags: DWORD): HINTERNET; stdcall; external 'winhttp.dll';
function WinHttpConnect(hSession: HINTERNET; pswzServerName: PWideChar; nServerPort: WORD;
  dwReserved: DWORD): HINTERNET; stdcall; external 'winhttp.dll';
function WinHttpOpenRequest(hConnect: HINTERNET; pwszVerb, pwszObjectName, pwszVersion, pwszReferrer: PWideChar;
  ppwszAcceptTypes: Pointer; dwFlags: DWORD): HINTERNET; stdcall; external 'winhttp.dll';
function WinHttpSendRequest(hRequest: HINTERNET; lpszHeaders: PWideChar; dwHeadersLength: DWORD;
  lpOptional: Pointer; dwOptionalLength, dwTotalLength: DWORD; dwContext: PtrUInt): BOOL; stdcall;
  external 'winhttp.dll';
function WinHttpReceiveResponse(hRequest: HINTERNET; lpReserved: Pointer): BOOL; stdcall; external 'winhttp.dll';
function WinHttpQueryHeaders(hRequest: HINTERNET; dwInfoLevel: DWORD; pwszName: PWideChar; lpBuffer: Pointer;
  var lpdwBufferLength: DWORD; lpdwIndex: PDWORD): BOOL; stdcall; external 'winhttp.dll';
function WinHttpQueryDataAvailable(hRequest: HINTERNET; var lpdwNumberOfBytesAvailable: DWORD): BOOL; stdcall;
  external 'winhttp.dll';
function WinHttpReadData(hRequest: HINTERNET; lpBuffer: Pointer; dwNumberOfBytesToRead: DWORD;
  var lpdwNumberOfBytesRead: DWORD): BOOL; stdcall; external 'winhttp.dll';
function WinHttpCloseHandle(hInternet: HINTERNET): BOOL; stdcall; external 'winhttp.dll';
function WinHttpSetTimeouts(hInternet: HINTERNET; nResolveTimeout, nConnectTimeout, nSendTimeout,
  nReceiveTimeout: Integer): BOOL; stdcall; external 'winhttp.dll';

function CryptProtectData(pDataIn: PDataBlob; szDataDescr: PWideChar; pOptionalEntropy: PDataBlob;
  pvReserved, pPromptStruct: Pointer; dwFlags: DWORD; pDataOut: PDataBlob): BOOL; stdcall; external 'crypt32.dll';
function CryptUnprotectData(pDataIn: PDataBlob; ppszDataDescr: Pointer; pOptionalEntropy: PDataBlob;
  pvReserved, pPromptStruct: Pointer; dwFlags: DWORD; pDataOut: PDataBlob): BOOL; stdcall; external 'crypt32.dll';

function ClaudeBaseUrl: string;
begin
  Result := Trim(SysUtils.GetEnvironmentVariable('ANTHROPIC_BASE_URL'));
  if Result = '' then Result := 'https://api.anthropic.com';
  while (Result <> '') and (Result[Length(Result)] = '/') do Delete(Result, Length(Result), 1);
end;

function ClaudeKeyVar: string;
begin
  Result := Trim(SysUtils.GetEnvironmentVariable('VPLC_KEY_VAR'));
  if Result = '' then Result := 'ANTHROPIC_API_KEY';
end;

var
  CacheKey, CacheSrc: string;
  CacheTick: QWord;
  CacheOk: Boolean;

procedure DropCache;
begin
  CacheOk := False;
end;

function KeyFile: string;
begin
  Result := IncludeTrailingPathDelimiter(SysUtils.GetEnvironmentVariable('APPDATA')) + 'VirtualPLC' + PathDelim;
  if ClaudeKeyVar = 'ANTHROPIC_API_KEY' then Result := Result + 'claude.key'
  else Result := Result + 'claude-' + ClaudeKeyVar + '.key';
end;

function UserEnvKey: string;
var
  R: TRegistry;
begin
  Result := '';
  R := TRegistry.Create(KEY_READ);
  try
    R.RootKey := HKEY_CURRENT_USER;
    if R.OpenKeyReadOnly('Environment') and R.ValueExists(ClaudeKeyVar) then Result := Trim(R.ReadString(ClaudeKeyVar));
  except
    Result := '';
  end;
  R.Free;
end;

procedure BroadcastEnv;
var
  Res: DWORD_PTR;
begin
  SendMessageTimeoutW(HWND_BROADCAST, WM_SETTINGCHANGE, 0, LPARAM(PWideChar(UnicodeString('Environment'))),
    SMTO_ABORTIFHUNG, 200, @Res);
end;

procedure ClaudeSetEnvKey(const Key: string);
var
  R: TRegistry;
  S: string;
begin
  S := Trim(Key);
  if S = '' then Exit;
  R := TRegistry.Create(KEY_READ or KEY_WRITE);
  try
    R.RootKey := HKEY_CURRENT_USER;
    if not R.OpenKey('Environment', True) then raise Exception.Create('HKCU\Environment cannot be opened');
    R.WriteString(ClaudeKeyVar, S);
  finally
    R.Free;
  end;
  SetEnvironmentVariableW(PWideChar(UnicodeString(ClaudeKeyVar)), PWideChar(UnicodeString(S)));
  DropCache;
  BroadcastEnv;
end;

procedure ClaudeRemoveEnvKey;
var
  R: TRegistry;
begin
  R := TRegistry.Create(KEY_READ or KEY_WRITE);
  try
    R.RootKey := HKEY_CURRENT_USER;
    if R.OpenKey('Environment', False) and R.ValueExists(ClaudeKeyVar) then R.DeleteValue(ClaudeKeyVar);
  finally
    R.Free;
  end;
  SetEnvironmentVariableW(PWideChar(UnicodeString(ClaudeKeyVar)), nil);
  DropCache;
  BroadcastEnv;
end;

function ClaudeHasEnvKey: Boolean;
begin
  Result := UserEnvKey <> '';
end;

function ClaudeHasSavedKey: Boolean;
begin
  Result := FileExists(KeyFile);
end;

function ReadApiKey(out Source: string): string; forward;

{ the UI asks every frame: the registry and the file are read again after 2 s, or after a change }
function ClaudeApiKey(out Source: string): string;
begin
  if not CacheOk or (GetTickCount64 - CacheTick > 2000) then
  begin
    CacheKey := ReadApiKey(CacheSrc);
    CacheTick := GetTickCount64;
    CacheOk := True;
  end;
  Source := CacheSrc;
  Result := CacheKey;
end;

function ReadApiKey(out Source: string): string;
var
  F: TFileStream;
  Inp, Outp: TDataBlob;
  Buf: TBytes;
begin
  Result := Trim(SysUtils.GetEnvironmentVariable(ClaudeKeyVar));
  if Result <> '' then
  begin
    Source := ClaudeKeyVar;
    Exit;
  end;
  Result := UserEnvKey;
  if Result <> '' then
  begin
    Source := ClaudeKeyVar + ' (Windows user)';
    Exit;
  end;
  Source := '';
  if not FileExists(KeyFile) then Exit;
  try
    F := TFileStream.Create(KeyFile, fmOpenRead or fmShareDenyWrite);
    try
      SetLength(Buf, F.Size);
      if Length(Buf) > 0 then F.ReadBuffer(Buf[0], Length(Buf));
    finally
      F.Free;
    end;
    if Length(Buf) = 0 then Exit;
    Inp.cbData := Length(Buf);
    Inp.pbData := @Buf[0];
    FillChar(Outp, SizeOf(Outp), 0);
    if CryptUnprotectData(@Inp, nil, nil, nil, nil, CRYPTPROTECT_UI_FORBIDDEN, @Outp) then
    begin
      SetString(Result, PAnsiChar(Outp.pbData), Outp.cbData);
      LocalFree(HLOCAL(Outp.pbData));
      Result := Trim(Result);
      if Result <> '' then Source := 'saved for this Windows user';
    end;
  except
    Result := '';
  end;
end;

procedure ClaudeSaveKey(const Key: string);
var
  Inp, Outp: TDataBlob;
  F: TFileStream;
  S: string;
begin
  S := Trim(Key);
  if S = '' then Exit;
  Inp.cbData := Length(S);
  Inp.pbData := PByte(PAnsiChar(S));
  FillChar(Outp, SizeOf(Outp), 0);
  if not CryptProtectData(@Inp, 'Virtual PLC Claude key', nil, nil, nil, CRYPTPROTECT_UI_FORBIDDEN, @Outp) then
    raise Exception.Create('the key could not be protected (DPAPI)');
  try
    ForceDirectories(ExtractFileDir(KeyFile));
    F := TFileStream.Create(KeyFile, fmCreate);
    try
      F.WriteBuffer(Outp.pbData^, Outp.cbData);
    finally
      F.Free;
      DropCache;
    end;
  finally
    LocalFree(HLOCAL(Outp.pbData));
  end;
end;

procedure ClaudeForgetKey;
begin
  DropCache;
  if FileExists(KeyFile) then SysUtils.DeleteFile(KeyFile);
end;

function HttpPost(const Url, Body, Headers: string; out Status: Integer; out Resp, Error: string): Boolean;
var
  Secure: Boolean;
  Host, Path, Rest: string;
  Port, P: Integer;
  Ses, Con, Req: HINTERNET;
  WHost, WPath, WHead: UnicodeString;
  Code, Len, Avail, Got: DWORD;
  Chunk: array[0..16383] of Byte;
  Ms: TMemoryStream;
begin
  Result := False;
  Status := 0;
  Resp := '';
  Error := '';
  // https://host[:port]/path
  Rest := Url;
  Secure := LowerCase(Copy(Rest, 1, 8)) = 'https://';
  if Secure then Delete(Rest, 1, 8)
  else if LowerCase(Copy(Rest, 1, 7)) = 'http://' then Delete(Rest, 1, 7)
  else
  begin
    Error := 'bad URL ' + Url;
    Exit;
  end;
  P := Pos('/', Rest);
  if P = 0 then
  begin
    Host := Rest;
    Path := '/';
  end
  else
  begin
    Host := Copy(Rest, 1, P - 1);
    Path := Copy(Rest, P, MaxInt);
  end;
  if Secure then Port := 443 else Port := 80;
  P := Pos(':', Host);
  if P > 0 then
  begin
    Port := StrToIntDef(Copy(Host, P + 1, MaxInt), Port);
    Host := Copy(Host, 1, P - 1);
  end;
  WHost := UnicodeString(Host);
  WPath := UnicodeString(Path);
  WHead := UTF8Decode(Headers);
  Ses := WinHttpOpen('VirtualPLC/1.0', WINHTTP_ACCESS_TYPE_DEFAULT_PROXY, nil, nil, 0);
  if Ses = nil then
  begin
    Error := 'WinHttpOpen failed: ' + SysErrorMessage(GetLastError);
    Exit;
  end;
  Ms := TMemoryStream.Create;
  Con := nil;
  Req := nil;
  try
    // a long thinking turn can take minutes: 10 minutes to receive
    WinHttpSetTimeouts(Ses, 30000, 30000, 60000, 600000);
    Con := WinHttpConnect(Ses, PWideChar(WHost), Port, 0);
    if Con = nil then
    begin
      Error := 'cannot connect to ' + Host + ': ' + SysErrorMessage(GetLastError);
      Exit;
    end;
    if Secure then
      Req := WinHttpOpenRequest(Con, 'POST', PWideChar(WPath), nil, nil, nil, WINHTTP_FLAG_SECURE)
    else
      Req := WinHttpOpenRequest(Con, 'POST', PWideChar(WPath), nil, nil, nil, 0);
    if Req = nil then
    begin
      Error := 'WinHttpOpenRequest failed: ' + SysErrorMessage(GetLastError);
      Exit;
    end;
    if not WinHttpSendRequest(Req, PWideChar(WHead), DWORD(-1), PAnsiChar(Body), Length(Body), Length(Body), 0) or
      not WinHttpReceiveResponse(Req, nil) then
    begin
      Error := 'no answer from ' + Host + ': ' + SysErrorMessage(GetLastError);
      Exit;
    end;
    Code := 0;
    Len := SizeOf(Code);
    if WinHttpQueryHeaders(Req, WINHTTP_QUERY_STATUS_CODE or WINHTTP_QUERY_FLAG_NUMBER, nil, @Code, Len, nil) then
      Status := Code;
    repeat
      Avail := 0;
      if not WinHttpQueryDataAvailable(Req, Avail) then Break;
      if Avail = 0 then Break;
      if Avail > SizeOf(Chunk) then Avail := SizeOf(Chunk);
      Got := 0;
      if not WinHttpReadData(Req, @Chunk[0], Avail, Got) then Break;
      if Got > 0 then Ms.WriteBuffer(Chunk[0], Got);
    until Got = 0;
    SetLength(Resp, Ms.Size);
    if Ms.Size > 0 then Move(Ms.Memory^, Resp[1], Ms.Size);
    Result := True;
  finally
    Ms.Free;
    if Req <> nil then WinHttpCloseHandle(Req);
    if Con <> nil then WinHttpCloseHandle(Con);
    WinHttpCloseHandle(Ses);
  end;
end;

{ TClaudeRequest }

constructor TClaudeRequest.Create(const AUrl, ABody, AHeaders: string);
begin
  FUrl := AUrl;
  FBody := ABody;
  FHeaders := AHeaders;
  FreeOnTerminate := False;
  inherited Create(False);
end;

procedure TClaudeRequest.Execute;
var
  Try1: Integer;
  Ok: Boolean;
begin
  for Try1 := 0 to 2 do
  begin
    Ok := HttpPost(FUrl, FBody, FHeaders, Status, Response, Error);
    if Cancelled or Terminated then Break;
    // retry what is worth retrying: no connection, timeouts, rate limits, overload, server errors
    if Ok and not ((Status = 408) or (Status = 409) or (Status = 429) or (Status >= 500)) then Break;
    if Try1 < 2 then Sleep(2000 * (Try1 + 1) * (Try1 + 1));
  end;
  Done := True;
end;

end.
