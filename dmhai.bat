@echo off
setlocal

set DMHAI_HOME=%~dp0
if "%DMHAI_HOME:~-1%"=="\" set DMHAI_HOME=%DMHAI_HOME:~0,-1%

REM Detect docker compose v2 vs v1
docker compose version >nul 2>&1
if %errorlevel%==0 (
    set DC_BIN=docker compose
) else (
    set DC_BIN=docker-compose
)

set DC=%DC_BIN% -f "%DMHAI_HOME%\docker-compose.yml" -p dmhai

if "%1"=="start"   goto :start
if "%1"=="stop"    goto :stop
if "%1"=="restart" goto :restart
if "%1"=="status"  goto :status

echo Usage: dmhai {start^|stop^|restart^|status}
exit /b 1

:start
echo Stopping any existing containers...
%DC% down 2>nul
%DC_BIN% -f "%DMHAI_HOME%\docker-compose.yml" -p dist down 2>nul
if not exist "%DMHAI_HOME%\user_assets" mkdir "%DMHAI_HOME%\user_assets"
if not exist "%DMHAI_HOME%\system_logs" mkdir "%DMHAI_HOME%\system_logs"
echo Starting DMH-AI...
%DC% up -d
echo Running.
echo   http://localhost:8080  -- standard
echo   https://localhost:8443 -- HTTPS (accept cert warning once; required for voice input)
goto :eof

:stop
echo Stopping DMH-AI...
%DC% down
echo Stopped.
goto :eof

:restart
call :stop
call :start
goto :eof

:status
%DC% ps
goto :eof
