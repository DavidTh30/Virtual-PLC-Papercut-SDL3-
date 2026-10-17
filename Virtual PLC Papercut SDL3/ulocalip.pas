unit uLocalIp;

{ The IPv4 addresses of this PC (the PROFINET interface's IP address menu): the host name resolved
  by WinSock, without 127.x (that one is offered on its own). }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils;

procedure LocalIPv4List(L: TStrings);

implementation

uses
  WinSock2;

procedure LocalIPv4List(L: TStrings);
var
  Wsa: TWSAData;
  Name: array[0..255] of AnsiChar;
  He: PHostEnt;
  P: PPAnsiChar;
  A: PInAddr;
  S: string;
begin
  L.Clear;
  if WSAStartup($0202, Wsa) <> 0 then Exit;
  try
    if gethostname(@Name[0], SizeOf(Name)) <> 0 then Exit;
    He := gethostbyname(@Name[0]);
    if (He = nil) or (He^.h_addrtype <> AF_INET) then Exit;
    P := PPAnsiChar(He^.h_addr_list);
    while (P <> nil) and (P^ <> nil) do
    begin
      A := PInAddr(P^);
      S := StrPas(inet_ntoa(A^));
      if (Copy(S, 1, 4) <> '127.') and (L.IndexOf(S) < 0) then L.Add(S);
      Inc(P);
    end;
  finally
    WSACleanup;
  end;
end;

end.
