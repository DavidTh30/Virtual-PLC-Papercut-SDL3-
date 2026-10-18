@echo off
rem Compile the example projects and run the scripted tests on the reference Virtual PLC
setlocal
cd /d "%~dp0"
set SCLC=%~dp0bin\sclc.exe
set FAIL=0

echo === FluffSilo (S7-1200) - commissioning checklist
pushd examples\FluffSilo
"%SCLC%" FluffSilo.sclproj -l output\FluffSilo.lst || set FAIL=1
"%SCLC%" --sim output\FluffSilo.svpl --script tests\sequence.txt | findstr /R "passed FAIL ERROR" || set FAIL=1
popd

echo === FeatureTest (S7-1500) - language features
pushd examples\FeatureTest
"%SCLC%" FeatureTest.sclproj -l output\FeatureTest.lst || set FAIL=1
"%SCLC%" --sim output\FeatureTest.svpl --script tests\features.txt | findstr /R "passed FAIL ERROR" || set FAIL=1
popd

echo === ErrorTest - every marked line must report an error (exit code 1 expected)
"%SCLC%" examples\ErrorTest\ErrorTest.sclproj --check
if %ERRORLEVEL%==0 set FAIL=1

echo.
if %FAIL%==0 (echo ALL TESTS OK) else (echo SOME TESTS FAILED)
exit /b %FAIL%
