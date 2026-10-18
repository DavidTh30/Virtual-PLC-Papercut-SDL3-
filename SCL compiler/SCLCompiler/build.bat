@echo off
rem Build SCL Compiler (command line) and SCL Studio (Lazarus GUI)
setlocal
set LAZ=C:\lazarus
set FPC=%LAZ%\fpc\3.2.2\bin\x86_64-win64\fpc.exe
cd /d "%~dp0"
if not exist bin mkdir bin
if not exist lib\cli mkdir lib\cli

echo === sclc (command line compiler)
"%FPC%" -Mobjfpc -Sh -O2 -gl -Fucore -FUlib\cli -obin\sclc.exe cli\sclc.lpr || goto :err

echo === SCL Studio (GUI)
"%LAZ%\lazbuild.exe" gui\SCLStudio.lpi || goto :err

echo.
echo Build OK: bin\sclc.exe  bin\SCLStudio.exe
exit /b 0
:err
echo BUILD FAILED
exit /b 1
