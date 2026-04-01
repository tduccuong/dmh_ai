@echo off
setlocal

set IMAGE_NAME=dmh-ai
set SCRIPT_DIR=%~dp0
set DIST_DIR=%SCRIPT_DIR%dist

echo Building Docker image...
docker build -t %IMAGE_NAME% "%SCRIPT_DIR%code"

echo Exporting image to dist\...
if not exist "%DIST_DIR%" mkdir "%DIST_DIR%"
docker save %IMAGE_NAME% -o "%DIST_DIR%\dmh-ai.tar"

echo Pulling and exporting SearXNG image...
docker pull searxng/searxng
docker save searxng/searxng -o "%DIST_DIR%\searxng.tar"

echo Assembling deployment package...
copy /Y "%SCRIPT_DIR%code\searxng-settings.yml" "%DIST_DIR%\searxng-settings.yml"
copy /Y "%SCRIPT_DIR%code\docker-compose.yml"   "%DIST_DIR%\docker-compose.yml"
copy /Y "%SCRIPT_DIR%code\run.bat"              "%DIST_DIR%\run.bat"
if not exist "%DIST_DIR%\db" mkdir "%DIST_DIR%\db"
if not exist "%DIST_DIR%\user_assets" mkdir "%DIST_DIR%\user_assets"
if not exist "%DIST_DIR%\system_logs" mkdir "%DIST_DIR%\system_logs"

echo.
echo Done. Deployable artifact: dist\
echo   dmh-ai.tar
echo   searxng.tar
echo   docker-compose.yml
echo   run.bat
echo   searxng-settings.yml
