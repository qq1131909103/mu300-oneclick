@echo off
rem ASCII-only launcher: the Chinese UI is produced by mu300-oneclick.ps1
rem (Windows PowerShell 5.1 reads that file as UTF-8 because it carries a BOM).
rem
rem Double-click this file, or run it from cmd.exe. No execution-policy change needed.
rem
rem   one-click-flash.cmd -CheckOnly    inspect the device only, write nothing
rem   one-click-flash.cmd -Auto         answer the safe questions automatically

setlocal
title MU300 / U30 Air - Linux installer

set "PS1=%~dp0mu300-oneclick.ps1"
if not exist "%PS1%" goto :nops1

powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %*
set "RC=%ERRORLEVEL%"

if "%RC%"=="0" goto :done
echo.
echo [NOTE] The launcher ended with exit code %RC%.
echo        Read the messages above: each failure lists what to do next.
echo.
goto :done

:nops1
echo.
echo [ERROR] mu300-oneclick.ps1 was not found next to this file.
echo         Expected: "%PS1%"
echo.
echo         Keep one-click-flash.cmd and mu300-oneclick.ps1 in the SAME folder
echo         (both come from the same download; do not move one without the other).
echo.
set "RC=1"
pause

:done
endlocal & exit /b %RC%
