@echo off
setlocal
rem ===============================================================
rem  winoc2api  ::  the ONE launcher for the opencode2api gateway
rem ---------------------------------------------------------------
rem  Double-click it for the interactive status panel and menu.
rem  Or pass a command:
rem
rem      LAUNCHER.bat start | stop | restart | status
rem      LAUNCHER.bat models | probe | logs
rem      LAUNCHER.bat open-config | open-docs
rem
rem  Every path is derived from this file's own location (%~dp0),
rem  so it works from any current directory.
rem ===============================================================
set "SKILL_ROOT=%~dp0"
set "ENGINE=%SKILL_ROOT%opencode-zen-adapter\scripts\adapter.ps1"

if not exist "%ENGINE%" (
    echo.
    echo   [FAIL] adapter.ps1 not found:
    echo       %ENGINE%
    echo.
    echo   This launcher must sit in the winoc2api skill folder,
    echo   right next to the opencode-zen-adapter repository folder.
    echo.
    pause
    exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%ENGINE%" %*
exit /b %ERRORLEVEL%
