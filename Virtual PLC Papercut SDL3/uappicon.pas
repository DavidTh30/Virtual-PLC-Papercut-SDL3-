unit uAppIcon;

{ The icon of the program (VirtualPLC.ico, built into the exe as the resource MAINICON) on a window of its
  own that the LCL does not make (the SDL windows): WM_SETICON with the big and the small size. }

{$mode objfpc}{$H+}

interface

procedure SetWindowAppIcon(Handle: Pointer);

implementation

{$IFDEF WINDOWS}
uses
  Windows;

procedure SetWindowAppIcon(Handle: Pointer);
var
  Big, Small: HICON;
begin
  if Handle = nil then Exit;
  Big := LoadImage(HInstance, 'MAINICON', IMAGE_ICON, GetSystemMetrics(SM_CXICON), GetSystemMetrics(SM_CYICON), 0);
  Small := LoadImage(HInstance, 'MAINICON', IMAGE_ICON, GetSystemMetrics(SM_CXSMICON), GetSystemMetrics(SM_CYSMICON), 0);
  if Big <> 0 then SendMessage(HWND(Handle), WM_SETICON, ICON_BIG, LPARAM(Big));
  if Small <> 0 then SendMessage(HWND(Handle), WM_SETICON, ICON_SMALL, LPARAM(Small));
end;
{$ELSE}
procedure SetWindowAppIcon(Handle: Pointer);
begin
end;
{$ENDIF}

end.
