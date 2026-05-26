@echo off
REM make.cmd - Batch wrapper for make.ps1
REM Allows Windows users to run: make <target>
REM Instead of: PowerShell -ExecutionPolicy Bypass -File make.ps1 <target>

setlocal enabledelayedexpansion

REM Get the directory where this script is located
set SCRIPT_DIR=%~dp0
set TARGET=%1
set ARGS=%2 %3 %4 %5 %6 %7 %8 %9

REM Default to help if no target specified
if "%TARGET%"=="" (
    set TARGET=help
)

REM Run make.ps1 via PowerShell
REM Using -NoProfile to skip profile loading (faster)
REM Using -ExecutionPolicy Bypass to allow script execution on Windows
PowerShell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%make.ps1" "%TARGET%" %ARGS%

endlocal
exit /b %ERRORLEVEL%
