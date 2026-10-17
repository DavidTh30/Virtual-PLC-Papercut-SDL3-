program VirtualPLC_test;

{ Virtual PLC - a simulated Siemens S7-300 / S7-400 / S7-1200 CPU with a
  papercut UI: front panel with LEDs and mode selector, LAD / STL program
  editor with monitor, I/O simulation, watch and force table, data blocks,
  tag table, projects (JSON). SDL3 window, BGRABitmap on all CPU cores,
  vsync 60 Hz; the PLC scan cycle runs in its own thread.

  uplctypes / uplcproject / uplccompiler / uplcruntime   the PLC
  upaperdl / uframe / urenderpool                        the paper painter
  uuibase / uui                                          the screens
  usdlview                                               SDL3 window and loop
  uinfoform                                              developer information window
  uexport / umfvideo                                     PNG GIF MP4 SVG export

  Command line
    --sample=300|400|1200          start with that sample project
    --shots folder                 PNG of every screen (scripted), then quit
    --export folder [w h frames fps]  main picture + every layer, then quit
    --bench=SECONDS                frame pacing report, then quit
    --novsync                      start without vsync
  Needs SDL3.dll next to the program. }

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Interfaces,
  Classes, Forms, SysUtils, uSDLView, uInfoForm;

{$R *.res}

begin
  RequireDerivedFormResource := False;  // forms are built in code
  Application.Scaled := True;
  Application.Title := 'Virtual PLC';
  Application.Initialize;
  try
    View := TSDLView.Create;
  except
    on E: Exception do
    begin
      Application.MessageBox(PChar(E.Message), 'Virtual PLC', 0);
      Exit;
    end;
  end;
  Application.ShowMainForm := False;
  Application.CreateForm(TInfoForm, InfoForm);
  Application.Run;
  FreeAndNil(View);
end.
