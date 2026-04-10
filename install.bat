@echo off
setlocal enabledelayedexpansion

set SCRIPT_DIR=%~dp0
if "%SCRIPT_DIR:~-1%"=="\" set SCRIPT_DIR=%SCRIPT_DIR:~0,-1%
set DIST_DIR=%SCRIPT_DIR%\dist
set DMHAI_HOME=%USERPROFILE%\.dmhai

REM ── Preflight ──────────────────────────────────────────────────────────────────
if not exist "%DIST_DIR%" (
    echo Error: dist\ not found. Run build.bat first. >&2
    exit /b 1
)

docker version >nul 2>&1
if %errorlevel% neq 0 (
    echo Error: docker not found or not running. >&2
    exit /b 1
)

REM ── Install directory ──────────────────────────────────────────────────────────
if not exist "%DMHAI_HOME%" mkdir "%DMHAI_HOME%"

REM ── Load docker images (only if tars are present) ─────────────────────────────
if exist "%DIST_DIR%\dmh-ai.tar" if exist "%DIST_DIR%\searxng.tar" (
    echo Loading docker images...
    docker load -i "%DIST_DIR%\dmh-ai.tar"
    docker load -i "%DIST_DIR%\searxng.tar"
)

REM ── Copy config files (always overwrite — idempotent) ─────────────────────────
if exist "%DMHAI_HOME%\docker-compose.yml" del /f /q "%DMHAI_HOME%\docker-compose.yml"
if exist "%DMHAI_HOME%\searxng-settings.yml" del /f /q "%DMHAI_HOME%\searxng-settings.yml"
copy /Y "%DIST_DIR%\docker-compose.yml"   "%DMHAI_HOME%\docker-compose.yml"   >nul
copy /Y "%DIST_DIR%\searxng-settings.yml" "%DMHAI_HOME%\searxng-settings.yml" >nul

REM ── Data directories: migrate per-file from dist only if file absent in dest ───
call :migrate_dir db
call :migrate_dir user_assets
call :migrate_dir system_logs

REM ── Copy dmhai.bat to DMHAI_HOME ──────────────────────────────────────────────
copy /Y "%SCRIPT_DIR%\dmhai.bat" "%DMHAI_HOME%\dmhai.bat" >nul

REM ── Add DMHAI_HOME to user PATH if not already present ────────────────────────
echo Checking PATH...
powershell -NoProfile -Command ^
    "$p = [Environment]::GetEnvironmentVariable('PATH','User'); ^
     if ($p -notlike '*%DMHAI_HOME%*') { ^
         [Environment]::SetEnvironmentVariable('PATH', $p + ';%DMHAI_HOME%', 'User'); ^
         Write-Host 'Added %DMHAI_HOME% to your user PATH.'; ^
         Write-Host 'Re-open your Command Prompt for the change to take effect.'; ^
     } else { ^
         Write-Host '%DMHAI_HOME% is already in your PATH.'; ^
     }"

REM ── Done ───────────────────────────────────────────────────────────────────────
echo.
echo Installed to %DMHAI_HOME%
echo.
echo Usage: dmhai {start^|stop^|restart^|status}
echo.
echo (If dmhai is not recognised yet, re-open your Command Prompt first.)
exit /b 0

REM ── Helper: migrate files from dist\<name> to DMHAI_HOME\<name> ────────────────
:migrate_dir
set _name=%1
set _src=%DIST_DIR%\%_name%
set _dst=%DMHAI_HOME%\%_name%
if not exist "%_dst%" mkdir "%_dst%"
if not exist "%_src%" goto :eof
for %%F in ("%_src%\*") do (
    if not exist "%_dst%\%%~nxF" (
        xcopy /E /I /Q "%%F" "%_dst%\%%~nxF" >nul 2>&1
        echo   Migrated %_name%\%%~nxF
    ) else (
        echo   %_name%\%%~nxF already exists -- skipping.
    )
)
goto :eof
