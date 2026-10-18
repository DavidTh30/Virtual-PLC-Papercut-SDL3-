program SCLStudio;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Interfaces, Forms, sclide_main;

{$R *.res}

begin
  RequireDerivedFormResource := False;
  Application.Title := 'SCL Studio';
  Application.Scaled := True;
  Application.Initialize;
  Application.CreateForm(TMainForm, MainForm);
  Application.Run;
end.
