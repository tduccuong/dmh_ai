@echo off
setlocal
set SCRIPT_DIR=%~dp0

echo Loading images...
docker load -i "%SCRIPT_DIR%dmh-ai.tar"
docker load -i "%SCRIPT_DIR%searxng.tar"

echo Stopping any existing containers...
docker compose -f "%SCRIPT_DIR%docker-compose.yml" down 2>nul
docker rm -f dmh-ai searxng 2>nul

if not exist "%SCRIPT_DIR%user_assets" mkdir "%SCRIPT_DIR%user_assets"
if not exist "%SCRIPT_DIR%system_logs" mkdir "%SCRIPT_DIR%system_logs"

echo Starting DMH-AI...
docker compose -f "%SCRIPT_DIR%docker-compose.yml" up -d
echo Running. Visit http://localhost:8080
